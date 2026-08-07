/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import UIKit
import UserNotifications

// MARK: - T4.V7: AI-write identity guard
//
// `MessageHeader.id` (`accountId:folderPath:messageId`) is an ADDRESS, not an
// IDENTITY. Every automatic-AI write captures a target, performs slow async work
// (an LLM round trip up to `SyncConfig.llmJobDeadlineSeconds`), then re-reads the
// row at that composite key to write the result back. Between capture and write
// the row at that key can become a DIFFERENT physical message — an IMAP
// UIDVALIDITY turnover reassigns the UID space, and the purge-and-resync reaction
// (`AccountManager.runUidValidityResetReaction`) deletes the old rows and inserts
// new-epoch rows under the same `accountId:folderPath:uid` addresses. Writing
// then binds message X's summary / action tag / reply draft / `notified` stamp
// onto message Y — a wrong-message BIND, which the hard invariant C3 forbids.
//
// `AIWriteTarget` is captured ONCE at job start and every downstream header write
// re-resolves through it, dropping cleanly (no mutation, no success side effect)
// when the captured identity no longer holds. Dropping is safe here in a way it
// is NOT for user gestures: these nine sites write DERIVED AI METADATA, which is
// recomputable — the queue's own GRDB arbiter (`ActiveAIQueue.readJobOutcome`)
// sees the field still empty and re-drives the job. This leniency does NOT
// generalize to any user-intention path (see `Core Philosophy: Never Drop User
// Intention`).

/// Outcome of a guarded AI header write. `Sendable` because it is produced inside
/// an async `dbPool.write` and returned across the await boundary.
enum AIWriteOutcome: Sendable, Equatable { case written, dropped }

/// Snapshot of WHICH physical message an AI job captured, taken once at job start
/// from a row the caller already holds. `resolveCurrentHeader` returns the current
/// row for that captured identity ONLY if it is still the same physical message;
/// otherwise `nil` → the caller drops the write.
///
/// PORT of `v2final`'s `AIWriteTarget`, with two deliberate subtractions:
///
///  - **SUBTRACT the rfc-less capture refusal, and the RFC match's NECESSITY —
///    but not the RFC id itself.** The reference stores a normalized RFC 822
///    Message-ID, refuses to capture at
///    all when `normalizedRfc == nil && observedUidValidity == nil`, and requires
///    an RFC match in `resolveCurrentHeader`. A `nil` capture makes the WHOLE AI
///    job a no-op, and on v3 that harm is reachable, not theoretical: the epoch
///    side of that condition is nil in three states enumerated by
///    `AccountManager.newGestureRefusedForUnknownEpoch`'s own comment block — the
///    entire first-sync window of any IMAP/iCloud folder, PERMANENTLY for the demo
///    account (`DemoSeed.seedAccount` stores `provider: .imap` while `DemoProvider`
///    serves it, so no SELECT ever runs and nothing can stamp the column), and
///    `ScreenshotMode`'s raw-SQL folders, which insert without the column at all.
///    An rfc-less message in any of those states would be permanently un-writable
///    by AI — no summary, no action tag, no reply, no `notified` stamp, ever, with
///    no error and no retry. That is a silent product break, not a fail-closed
///    safety win. So v3 keeps the CAPTURE unconditional and demotes the RFC match
///    from a NECESSARY condition to a SUFFICIENT one: `resolveCurrentHeader` arm 6
///    admits on a positive RFC agreement, and rows without one fall through to the
///    epoch arms instead of being refused outright.
///
///    ⚠ AUDIT ROUND 4 (`IOS-ROUND3-D6`): that is a statement about CAPTURE, which
///    stays unconditional, and it must not be read as a promise about the WRITE.
///    The epoch arms a witnessless row falls through to now demand POSITIVE
///    evidence (arm 7 as amended), so such a row is carried only while its
///    folder's numbering is known. Two of the three states enumerated just above
///    never reach those arms at all: the demo account, and `ScreenshotMode`'s only
///    account that is given messages (`.gmail`), both exit at arm 4.
///
///    ⚠ AUDIT ROUND 2 restored the field after round 1 had dropped it entirely.
///    Dropping it left the guard with epoch evidence only, and an epoch proves
///    NUMBERING, not IDENTITY — there was then no instrument at all that could tell
///    the captured message apart from a replacement seated at the same UID under
///    the same epoch state. See arm 6.
///  - **SUBTRACT `observedLastUidValidityResetAt`.** The reference's epoch tuple is
///    `(lastKnownUidValidity, lastUidValidityResetAt)`. v3's `Folder` has no
///    `lastUidValidityResetAt` — its omission is deliberate and documented on
///    `Folder.uidValidityResetPendingAt`. The v3 tuple is
///    `(lastKnownUidValidity, uidValidityResetPendingAt)`.
///
/// ⚑ ONE deliberate DIFFERENCE, not a subtraction: `observedUidValidity` here is
/// the CAPTURED HEADER ROW's own `MessageHeader.observedUidValidity` — the epoch
/// the exact SELECT/FETCH that supplied this row's UID reported — where the
/// reference had to snapshot the FOLDER's `lastKnownUidValidity` because
/// `v2final`'s `MessageHeader` carries no epoch of its own. This is the same
/// v3-native substitution `AttachmentCacheIdentity.stamp(for:)` documents. It is
/// STRICTLY the operand a turnover moves: after a reset the impostor row at the
/// same address carries the NEW epoch, so comparing the impostor's live stamp
/// against the live folder epoch would agree and admit the wrong write — the
/// captured stamp is what disagrees.
struct AIWriteTarget: Sendable, Equatable {
    let headerId: String
    let accountId: String
    let folderId: String
    let messageId: String
    let provider: AccountProvider
    /// The captured row's own `MessageHeader.observedUidValidity`. `nil` for a
    /// stable-provider row (never stamped by design), for a row whose address was
    /// invalidated by a move or a re-key (`AccountManagerActions
    /// .optimisticMoveToFolder`, `SyncEngineDeltaSync`, `SyncEngineFullSync`,
    /// `BackfillBodyQueue` all null it), and for any row predating the column.
    ///
    /// ⚠ A nil here is an ORDINARY state, not a signal: far more production
    /// statements write only `nil` to this column than write a proven epoch.
    /// **That ratio is the ARGUMENT — invert it and this conclusion inverts — so it
    /// has ONE owner and this is not it.** See `AIWriteTarget.resolveCurrentHeader`
    /// below, whose own note routes to the doc comment on
    /// `SearchView.resolveLocalResultHeaderId` ("THE COUNT, WITH ITS PREDICATE AND
    /// ITS MEMBERS") for the predicate, the members by enclosing symbol, and the
    /// exclusive/inclusive split. **Re-derive there and update there; do not
    /// restate a bare integer here.** This sentence carried "15 … against only 4"
    /// until R14-F5, which was the figure `e4751e438` introduced and the correcting
    /// pass never reached — the same staleness `resolveCurrentHeader` had already
    /// recorded for its own copy, in the same file, one screen down (`MIS-031`: a
    /// fix's scope is every sentence that describes the thing, not the one the
    /// finding named). So a nil is neither evidence
    /// of a turnover NOR, on its own, grounds to admit. It is simply the absence of
    /// a numbering proof, and `resolveCurrentHeader` treats it as exactly that: the
    /// numbering arm (8) needs a positive stamp, and a row that has none must be
    /// carried by the content witness (arm 6) instead.
    let observedUidValidity: Int?

    /// The captured row's RFC 2822 Message-ID, verbatim from the column — the
    /// content's own device-independent name, and the ONLY captured field that
    /// identifies the MESSAGE rather than its address. `nil`/empty for mail that
    /// carried no `Message-ID` header; such a row is not refused, it just has no
    /// content witness and must satisfy `resolveCurrentHeader`'s epoch arms.
    ///
    /// Not normalized: both sides of the comparison are read from this same column
    /// (capture reads the row, resolve reads whatever row now occupies the address),
    /// so normalizing would add a transform without adding agreement.
    let rfc822MessageId: String?

    /// Whether this target's address space can be RENUMBERED under it. Account-side
    /// mirror of `staleWindowMode == .uid`, matching
    /// `AccountManagerActions.admittedOrdinaryActionTargets`: `.icloud` is IMAP, and
    /// the demo account is stored as `.imap` but served by `DemoProvider`, so it has
    /// no server, no SELECT and no epoch, ever.
    private var isEpochAddressed: Bool {
        accountId != DemoSeed.demoAccountId && (provider == .imap || provider == .icloud)
    }

    /// Capture once, before any await. Returns `nil` ONLY when the account row is
    /// missing (the provider cannot be determined). That arm cannot silently
    /// disable AI for a live message: `AccountManager.removeAccountRowsTxn`
    /// cascades account → folders → messageHeaders, so an absent account row
    /// implies the header row is gone too and every write would be a no-op anyway.
    static func capture(message: MessageHeader, db: Database) throws -> AIWriteTarget? {
        guard let account = try Account.fetchOne(db, key: message.accountId) else { return nil }
        return AIWriteTarget(
            headerId: message.id,
            accountId: message.accountId,
            folderId: message.folderId,
            messageId: message.messageId,
            provider: account.provider,
            observedUidValidity: message.observedUidValidity,
            rfc822MessageId: message.rfc822MessageId
        )
    }

    /// The current row for the captured identity iff it is STILL the same physical
    /// message; `nil` on any disagreement (⇒ the caller drops the write, and the
    /// next recompute heals).
    ///
    /// **The governing rule: a WRITE needs positive evidence, and this function
    /// returns a row only when the captured identity is still positively
    /// established.** This is the C3 direction, and it is the OPPOSITE of the
    /// never-drop direction that governs a durable `PendingOperation`: there, an
    /// unknown epoch must never retire the user's intention; here, an unknown epoch
    /// must never authorize a mutation. An AI write-back is recomputable derived
    /// metadata — refusing costs one recompute, admitting on an unproven identity
    /// binds message X's summary to message Y and cannot be undone. The two rules
    /// point in opposite directions because the cost of being wrong does.
    ///
    /// The earlier text here said "only a POSITIVE, PROVEN disagreement authorizes
    /// dropping" and arm 6 implemented it literally, admitting the write whenever
    /// the CAPTURED epoch was nil. That is the defect corrected below (arm 6):
    /// it is exactly backwards for a mutation path.
    ///
    /// Arms, in evaluation order:
    ///  1. **row gone** ⇒ `nil`. Structural: there is no row bearing the captured
    ///     address, so there is nothing to mutate. Not an "unknown".
    ///  2. **`(accountId, folderId, messageId)` drift** ⇒ `nil`. Also structural —
    ///     the row occupying the key demonstrably does not bear the captured
    ///     address. Defense-in-depth: `headerId` is a concatenation of exactly
    ///     these three, so a disagreement means a malformed row.
    ///  3. **account gone / provider changed** ⇒ `nil`. Defense-in-depth against a
    ///     changed row; unreachable as a cause of a false permanent drop, per the
    ///     cascade argument on `capture`.
    ///  4. **not epoch-addressed** (Gmail / Outlook / CalDAV / demo) ⇒ PROCEED.
    ///     Those id spaces are never renumbered, so the address IS the identity.
    ///  5. **`uidValidityResetPendingAt != nil`** ⇒ `nil`. The folder is mid
    ///     purge-and-resync (T4.S6): its rows either belong to an epoch the server
    ///     abandoned or have been purged and not yet resynced. TRANSIENT — the next
    ///     job recomputes.
    ///  6. **CONTENT PROOF — captured `rfc822MessageId` non-empty and EQUAL to the
    ///     current row's** ⇒ PROCEED, whatever the epochs say. Arms 1–3 proved only
    ///     that the row bears the captured composite ADDRESS, and on IMAP
    ///     `messageId` IS the UID — an address, not an identity. This arm supplies
    ///     the identity: an RFC 2822 Message-ID is device-independent and is the
    ///     content's own name, so the same non-empty id in the same account+folder
    ///     is the same email regardless of what UID it now occupies or which
    ///     numbering seated it. That is why the write is safe here even with a nil
    ///     stamp on both sides, and it is the architecturally correct instrument:
    ///     an AI summary is DERIVED CONTENT, and derived content keys by RFC id
    ///     (the same scheme `MessageAICache` and the FTS/body stores use), while
    ///     provider ids key the ACTION queue because actions must distinguish
    ///     physical copies. A replacement is a different email and therefore
    ///     carries a different Message-ID, so this witness cannot admit one.
    ///  7. **NO CONTENT WITNESS ⇒ the folder must be PRESENT and its numbering
    ///     POSITIVELY OBSERVED.** An ABSENT `Folder` row ⇒ `nil`; a present one
    ///     whose `lastKnownUidValidity` is nil ⇒ `nil`. Both are the ABSENCE of a
    ///     numbering proof, and the governing rule at the head of this comment
    ///     says an unknown epoch must never authorize a mutation.
    ///
    ///     ⚠ THIS ARM USED TO BE `guard let liveEpoch = folder?
    ///     .lastKnownUidValidity else { return header }` — an ADMIT, and
    ///     optional-chaining made a MISSING folder satisfy it as readily as a
    ///     never-observed one (the `uidValidityResetPendingAt` arm above is
    ///     likewise vacuous on a missing row). Its premise — *"no SELECT has ever
    ///     reported an epoch here, so no turnover can have been observed either,
    ///     and there is nothing this address could have been re-seated FROM"* —
    ///     is sound for a folder row that EXISTS with a nil column and FALSE for
    ///     an ABSENT one, where nothing was looked up at all. It is also false for
    ///     the present-but-nil row once arm 6 has failed by POSITIVE
    ///     DISAGREEMENT (both RFC ids present and different), which is precisely
    ///     the replacement this guard exists to catch. Registered as
    ///     `IOS-ROUND3-D6`.
    ///
    ///     The reachable chain, each step verified in code: an RFC-less header
    ///     survives its folder's deletion — `SyncEngine.fullSync`'s
    ///     vanished-folder cleanup deletes the `Folder` row and migration
    ///     `v2_dropMessageHeaderFolderFK` left `messageHeader.folderId` a plain
    ///     column with NO foreign key, so only `accountId` cascades; the path
    ///     re-appears at a new epoch and re-adopts those orphans under the
    ///     deterministic `"\(accountId):\(path)"` id with a NIL stamp, because
    ///     `uidValidityBootstrapWrite(observed:stored:folderHoldsRows:)` refuses
    ///     to stamp a folder that already holds rows and
    ///     `SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch` returns
    ///     `.unobservable` on an all-RFC-less population; and the merge then
    ///     seats a DIFFERENT message at the same canonical address, which
    ///     `SyncEngine.providerAddressOwnershipProven` admits on the canonical-PK
    ///     hit. Arm 7 then bound X's summary / action tag / reply / `notified`
    ///     stamp onto Y — misattribution, which C3 forbids as squarely as a
    ///     wrong-message mutation.
    ///
    ///     **The cost, stated plainly, because it is real and is why the arm
    ///     existed:** an epoch-addressed row with no content witness gets no AI
    ///     write until its folder's numbering is observed. That is exactly the
    ///     posture the durable-gesture path already takes on the SAME two states —
    ///     `AccountManager.newGestureRefusedForUnknownEpoch` refuses on both an
    ///     absent `Folder` row and a nil `lastKnownUidValidity` (`IOS-EPOCH-001`) —
    ///     so the two consumers of one question now agree instead of answering it
    ///     in opposite directions. It is recoverable: `runSyncMessages` stamps a
    ///     folder inside the same write transaction that first populates it, a
    ///     folder that is already populated earns its epoch through the verified
    ///     door, and a refused AI write leaves `summaryBlurb` nil so the queue's
    ///     own arbiter re-drives the job. `ScreenshotMode` is NOT affected — the
    ///     only account it gives messages to is `.gmail`, so arm 4 returns first —
    ///     and neither is the demo account, Outlook or CalDAV.
    ///  8. **NUMBERING PROOF — the fallback when there is no content witness.**
    ///     Requires all three of: a non-nil CAPTURED stamp, the CURRENT ROW's own
    ///     stamp equal to it, and the folder's live epoch equal to it. Anything
    ///     less ⇒ `nil`.
    ///
    ///     ⚠ AUDIT ROUND 2. This replaces a pair (6a/6b) that compared the CAPTURED
    ///     stamp against FOLDER state and **never read the current row's stamp at
    ///     all**. That conflation was wrong in BOTH directions at once. It admitted
    ///     a replacement bearing a `nil` stamp while the folder stayed on the
    ///     captured epoch — arms 6a, 6b and 7 all passed on a row that was not the
    ///     captured message, binding X's summary onto Y (a C3 hole). And it refused
    ///     an UNREPLACED row whose stamp was merely absent — **production writes of
    ///     `nil` to that column outnumber writes of a proven epoch by a wide margin
    ///     (the enumeration, with its predicate and its members, is owned by
    ///     `SearchView.resolveLocalResultHeaderId`)**, so absence is the ORDINARY
    ///     state, not evidence of a turnover — which left `summaryBlurb`/`actionTag`
    ///     nil, so `needsSummary`/`needsAction` stayed true, so the next open
    ///     re-ran the LLM and dropped it again: a paid API call repeated forever
    ///     for a summary that could never land.
    ///
    ///     ⚠️ **That ratio is the ARGUMENT, not decoration — invert it and this
    ///     conclusion inverts — so it has ONE owner and this is not it.** The
    ///     figure said "15 against 4"; it entered at `e4751e438` and the
    ///     correcting pass landed in `SearchView.swift` only, leaving this
    ///     sibling stale for a whole train. The predicate, the members by
    ///     enclosing symbol, and the exclusive/inclusive split live in the
    ///     doc comment on `SearchView.resolveLocalResultHeaderId`
    ///     ("THE COUNT, WITH ITS PREDICATE AND ITS MEMBERS"). **Re-derive there
    ///     and update there; do not restate a bare integer here.** ⚠️ **This
    ///     paragraph DID restate them — "18 … (20 …) against 5" — two paragraphs
    ///     below its own prohibition, and the restatement was removed 2026-08-06
    ///     when the owning census grew a member.** The DIRECTION is what this arm
    ///     depends on and it is stated above; the integers are not, and a second
    ///     copy of them is a second thing to keep true. That is the whole reason
    ///     the prohibition exists — the "15 against 4" instance it was written
    ///     about failed exactly this way.
    ///
    ///     Reading the row's own stamp closes the first half. It does NOT close the
    ///     second, and must not be mistaken for doing so: captured-nil against
    ///     row-nil is an absence matching an absence, which a replacement seated at
    ///     the same UID satisfies just as easily as the original. Only arm 6's
    ///     positive content witness distinguishes those, which is why the epoch
    ///     arms here demand a POSITIVE stamp and refuse on nil.
    func resolveCurrentHeader(db: Database) throws -> MessageHeader? {
        guard let header = try MessageHeader.fetchOne(db, key: headerId) else { return nil }
        guard header.accountId == accountId,
              header.folderId == folderId,
              header.messageId == messageId else { return nil }
        guard let account = try Account.fetchOne(db, key: accountId),
              account.provider == provider else { return nil }

        guard isEpochAddressed else { return header }

        let folder = try Folder.fetchOne(db, key: folderId)
        guard folder?.uidValidityResetPendingAt == nil else { return nil }
        // 6 — CONTENT PROOF.
        if let capturedRfc = rfc822MessageId, !capturedRfc.isEmpty,
           capturedRfc == header.rfc822MessageId {
            return header
        }
        // 7 — no content witness ⇒ the folder must be PRESENT and OBSERVED.
        //     Absent folder, or a present folder whose numbering was never
        //     observed, is an ABSENCE of evidence — and this is a write.
        guard let folder,
              let liveEpoch = SyncEngine.knownUidValidity(folder.lastKnownUidValidity)
        else { return nil }
        // 8 — NUMBERING PROOF. All three must agree, and all must be positive.
        guard let capturedEpoch = SyncEngine.knownUidValidity(observedUidValidity) else { return nil }
        guard header.observedUidValidity == capturedEpoch else { return nil }
        guard capturedEpoch == liveEpoch else { return nil }
        return header
    }
}

extension AccountManager {

    /// The ONE central guarded AI header write. Call INSIDE a `dbPool.write`.
    /// Re-resolves the captured identity and runs `mutate` — which mutates the
    /// RE-RESOLVED row and writes any `MessageAICache` keyed off it — only when the
    /// row at the captured `headerId` is still the same physical message. Returns
    /// `.dropped` WITHOUT mutating on identity drift / vanished row / mid-reset, and
    /// the caller then fires NO success side effect. A thrown DB error PROPAGATES
    /// (distinct from `.dropped`) so it is never swallowed into a fake success.
    ///
    /// PORT of `v2final`'s `AccountManager.aiGuardedHeaderWrite`. SUBTRACT: the
    /// reference's `#if DEBUG aiGuardBypassResolveForTesting` mutex seam, which
    /// existed to make each site flip from `.dropped` to `.written` under test. v3
    /// proves the same two-sidedness without production surface — the tests perform
    /// a BARE `MessageHeader.fetchOne` + `save` on the impostor row to establish it
    /// really is present and really is writable, then show the guarded write refuses
    /// it while an unchanged target still lands.
    nonisolated static func aiGuardedHeaderWrite(
        _ db: Database,
        target: AIWriteTarget,
        _ mutate: (_ msg: inout MessageHeader, _ db: Database) throws -> Void
    ) throws -> AIWriteOutcome {
        guard let resolved = try target.resolveCurrentHeader(db: db) else {
            if DebugModeManager.isLoggingEnabled() {
                print("[AI] T4.V7 dropping guarded write for \(target.headerId) — captured identity no longer resolves")
            }
            return .dropped
        }
        var msg = resolved
        try mutate(&msg, db)
        return .written
    }
}

extension AccountManager {

    // MARK: - Direct Path (User-Opened Messages)

    /// Direct priority path for user-opened messages (matches TB's onMessagesDisplayed).
    /// Called when the user opens a message in MessageDetailView — bypasses the queue
    /// and processes AI immediately, mirroring how TB processes the displayed email
    /// inline rather than through the background drain loop.
    func processOpenedMessage(_ message: MessageHeader) async {
        guard message.isInInbox else { return }
        // T4.V7: co-read the body AND capture the AI-write identity in ONE read.
        // The target is captured from the CURRENT row at `message.id`, never from
        // the caller's (possibly stale) snapshot — the caller's `observedUidValidity`
        // could predate a resync. Zero extra round trips: the body read was already
        // here.
        let opened: (body: MessageBody, target: AIWriteTarget)? =
            (try? await dbPool.read { db -> (body: MessageBody, target: AIWriteTarget)? in
            guard let body = try MessageBody.fetchOne(db, key: message.id),
                  let current = try MessageHeader.fetchOne(db, key: message.id),
                  let target = try AIWriteTarget.capture(message: current, db: db) else { return nil }
            return (body, target)
        }) ?? nil
        // body not yet fetched — fetchBody will trigger processMessage
        guard let opened else { return }
        let body = opened.body
        let target = opened.target

        // No-content message: set action=delete, summary directly (no AI needed)
        let bodyEmpty = body.htmlContent == nil || body.htmlContent?.isEmpty == true
        let hasAttachments = !body.attachments.isEmpty
        let needsSummary = message.summaryBlurb == nil || message.summaryBlurb?.isEmpty == true
        let needsAction = message.actionTag == nil
        if bodyEmpty && !hasAttachments && (needsSummary || needsAction) {
            // T4.V7 site 8. A thrown DB error maps to `.dropped` here (the local
            // no-content shortcut has no failure-signal path) — either way NO
            // success side effect fires.
            let outcome = (try? await dbPool.write { db in
                try AccountManager.aiGuardedHeaderWrite(db, target: target) { msg, db in
                    msg.summaryBlurb = "This message has no content."
                    msg.setActionTag(.delete)
                    try msg.save(db)
                }
            }) ?? .dropped
            if outcome == .written {
                NotificationCenter.default.post(name: .messageDataDidChange, object: message.id)
            }
            return
        }

        let needsReply = message.cachedReply == nil
        guard needsSummary || needsAction || needsReply else { return } // already fully processed

        let aiDisabled = AIService.optOutStore.bool(forKey: AIService.optOutAllAIKey)
        let deviceSyncEnabled = UserDefaults.standard.object(forKey: "device_sync_auto_enabled") as? Bool ?? true
        let hasSession = KeychainHelper.load(key: "tabmail_session") != nil
        guard hasSession && (!aiDisabled || deviceSyncEnabled) else { return }

        guard let account = try? await dbPool.read({ db in try Account.fetchOne(db, key: message.accountId) }) else {
            NotificationCenter.default.post(name: .aiDidFailForMessage, object: message.id)
            return
        }
        print("[AI] Priority direct path for opened message \(message.messageId)")
        await processMessage(message, account: account, target: target)
    }

    /// Process a single message after its body is fetched (priority path for user-opened messages).
    /// Handles AI summary + action classification, matching TB's processMessage().
    /// `target` is the T4.V7 identity captured at the direct-path entry; every
    /// header write below re-resolves through it.
    func processMessage(_ message: MessageHeader, account: Account, target: AIWriteTarget) async {
        let body = try? await dbPool.read { db in try MessageBody.fetchOne(db, key: message.id) }
        guard let body, let bodyHtml = body.htmlContent, !bodyHtml.isEmpty else {
            NotificationCenter.default.post(name: .aiDidFailForMessage, object: message.id)
            return
        }

        let plainText = EmailFilter.htmlToPlainText(bodyHtml)

        let headerId = message.id
        let messageId = message.messageId
        let rfc822MessageId = message.rfc822MessageId
        let accountEmail = account.emailAddress
        let subject = message.subject
        let from = message.from
        let fromAddress = message.fromAddress
        let date = message.date
        let htmlContent = body.htmlContent
        let hasExistingAction = message.actionTag != nil
        let hasSummary = message.summaryBlurb != nil && message.summaryBlurb?.isEmpty == false
        let hasReply = message.cachedReply != nil
        let toRecipients = message.to
        // T4.V7: the `folderPath` job-start snapshot is GONE — every AI-cache
        // write-through below keys off the RE-RESOLVED row (`msg.folderPath`), so a
        // snapshot copy would only be a way to key X's result under a stale path.
        let userName = account.displayName
        // "cc" needs positive evidence: the RECEIVING account's address in the
        // Cc header (claim set). All registered accounts feed the suppress set
        // only — a cross-account To/From hit prevents a claim, never makes one.
        let allAccountEmails = (try? await dbPool.read { db in
            try Account.fetchAll(db).map(\.emailAddress)
        }) ?? []
        let recipientStatus = PromptVariables.classifyRecipientStatus(
            toField: toRecipients, ccField: message.cc, fromField: message.fromAddress,
            claimEmails: [account.emailAddress], suppressEmails: allAccountEmails
        )
        let kbText = PromptStore.kbTextSnapshot()
        let actionPrompt = PromptStore.actionMarkdownSnapshot()
        let compositionPrompt = await MainActor.run { PromptStore.shared.compositionMarkdown() }
        let accountId = account.id

        Task { @Sendable in
            // Request extended background execution time for in-flight AI call
            let bgTaskId = Mutex<UIBackgroundTaskIdentifier>(.invalid)
            let taskId = await MainActor.run {
                UIApplication.shared.beginBackgroundTask(withName: "ai-priority-\(messageId)") {
                    let id = bgTaskId.withLock { $0 }
                    UIApplication.shared.endBackgroundTask(id)
                }
            }
            bgTaskId.withLock { $0 = taskId }
            defer {
                let id = bgTaskId.withLock { $0 }
                if id != .invalid {
                    Task { @MainActor in UIApplication.shared.endBackgroundTask(id) }
                }
            }

            let dbPool = self.dbPool

            // Double-check: fully processed by another path?
            if let msg = try? await dbPool.read({ db in try MessageHeader.fetchOne(db, key: headerId) }),
               msg.summaryBlurb != nil, msg.summaryBlurb?.isEmpty == false,
               msg.actionTag != nil, msg.cachedReply != nil {
                return
            }

            let aiService = AIService.shared
            let needsSA = !hasSummary || !hasExistingAction

            // Launch SA and R in parallel — R does not depend on summary/action output.
            // Queue dedup prevents the queue from re-processing what the direct path
            // already did (because GRDB fields will be non-nil after we write them).
            async let saTask: Void = {
                guard needsSA else { return }

                if !hasSummary {
                    // Full processing: summary + action
                    do {
                        guard let (summary, action, peerReply) = try await aiService.process(
                            messageId: messageId,
                            rfc822MessageId: rfc822MessageId,
                            accountEmail: accountEmail,
                            subject: subject,
                            from: from,
                            fromAddress: fromAddress,
                            date: date,
                            bodyText: plainText,
                            htmlContent: htmlContent,
                            hasExistingAction: hasExistingAction,
                            userName: userName,
                            kbText: kbText,
                            actionPrompt: actionPrompt,
                            recipientStatus: recipientStatus
                        ) else {
                            return // in-flight dedup (AIService level)
                        }

                        guard let blurb = summary.blurb, !blurb.isEmpty else {
                            print("[AI] No blurb for direct path \(messageId)")
                            NotificationCenter.default.post(name: .aiDidFailForMessage, object: headerId)
                            return
                        }

                        // T4.V7 site 5. The AI-cache write-through is keyed off the
                        // RE-RESOLVED row's `folderPath`/`rfc822MessageId`, not the
                        // job-start snapshot's, so a dropped write cannot leak X's
                        // result into Y's cache key either.
                        let outcome = (try? await dbPool.write { db in
                            try AccountManager.aiGuardedHeaderWrite(db, target: target) { msg, db in
                                msg.summaryBlurb = blurb
                                msg.summaryTodos = summary.todos
                                msg.reminderDate = summary.reminderDate
                                msg.reminderTime = summary.reminderTime
                                msg.reminderContent = summary.reminderContent

                                var cacheActionTag: ActionTag?
                                if let action, !hasExistingAction {
                                    let effectiveAction = (action == .reply && msg.isReplied) ? ActionTag.none : action
                                    msg.setActionTag(effectiveAction)
                                    cacheActionTag = action
                                    if effectiveAction != action {
                                        if DebugModeManager.isLoggingEnabled() {
                                            print("[ReplyDetect] AI direct: reply→none for \(messageId)")
                                        }
                                    }
                                }

                                if let peerReply, !peerReply.isEmpty, msg.cachedReply == nil {
                                    msg.cachedReply = peerReply
                                    if DebugModeManager.isLoggingEnabled() {
                                        print("[AI] Device Sync reply applied for direct path \(messageId)")
                                    }
                                }

                                try msg.save(db)

                                try MessageAICache.writeThrough(
                                    accountId: accountId,
                                    folderPath: msg.folderPath,
                                    rfc822MessageId: msg.rfc822MessageId,
                                    summaryBlurb: blurb,
                                    summaryTodos: summary.todos,
                                    reminderDate: summary.reminderDate,
                                    reminderTime: summary.reminderTime,
                                    reminderContent: summary.reminderContent,
                                    actionTag: cacheActionTag,
                                    cachedReply: msg.cachedReply,
                                    db: db
                                )
                            }
                        }) ?? .dropped
                        guard outcome == .written else {
                            if DebugModeManager.isLoggingEnabled() {
                                print("[AI] T4.V7 direct combined write dropped for \(messageId)")
                            }
                            return
                        }

                        NotificationCenter.default.post(name: .messageDataDidChange, object: headerId)

                        // Post active local notification when this message is reply-tagged
                        // (if not already notified by NSE). Gate lives inside via
                        // `EmailNotificationBuilder.isImportant` — matches the NSE rule.
                        Task { @MainActor in
                            guard UIApplication.shared.applicationState != .active else { return }
                            try? await self.postReplyNotificationIfNeeded(target: target)
                        }

                        print("[AI] Processed single message \(messageId)")
                    } catch {
                        print("[AI] Single message failed for \(messageId): \(error)")
                        NotificationCenter.default.post(name: .aiDidFailForMessage, object: headerId)
                    }
                } else if !hasExistingAction {
                    // Action-only: summary exists but action missing
                    do {
                        let msg = try? await dbPool.read({ db in try MessageHeader.fetchOne(db, key: headerId) })
                        let existingSummary = SummaryResult(
                            blurb: msg?.summaryBlurb,
                            todos: msg?.summaryTodos,
                            reminderDate: msg?.reminderDate,
                            reminderTime: msg?.reminderTime,
                            reminderContent: msg?.reminderContent
                        )
                        let action = try await aiService.classifyAction(
                            subject: subject,
                            from: from,
                            fromAddress: fromAddress,
                            bodyText: plainText,
                            htmlContent: htmlContent,
                            summary: existingSummary,
                            userName: userName,
                            actionPrompt: actionPrompt
                        )
                        if let action {
                            // T4.V7 site 6. The `?? action` false-success is REMOVED:
                            // a `.dropped` (or a thrown write) must fire NO side
                            // effect, and reporting the requested tag as if it had
                            // landed is exactly the misattribution this guards.
                            let written: (outcome: AIWriteOutcome, effective: ActionTag)? =
                                try? await dbPool.write { db in
                                    var effective = action
                                    let outcome = try AccountManager.aiGuardedHeaderWrite(db, target: target) { msg, db in
                                        let resolved = (action == .reply && msg.isReplied) ? ActionTag.none : action
                                        effective = resolved
                                        msg.setActionTag(resolved)
                                        try msg.save(db)
                                        try MessageAICache.writeThrough(
                                            accountId: accountId,
                                            folderPath: msg.folderPath,
                                            rfc822MessageId: msg.rfc822MessageId,
                                            actionTag: action,
                                            db: db
                                        )
                                    }
                                    return (outcome, effective)
                                }
                            guard let written, written.outcome == .written else {
                                if DebugModeManager.isLoggingEnabled() {
                                    print("[AI] T4.V7 direct action-only write dropped for \(messageId)")
                                }
                                return
                            }
                            let effectiveAction = written.effective
                            if effectiveAction != action {
                                print("[ReplyDetect] AI direct action-only: reply→none for \(messageId)")
                            }
                            NotificationCenter.default.post(name: .messageDataDidChange, object: headerId)
                            print("[AI] Action-only for single message \(messageId): \(effectiveAction.displayName)")
                        }
                    } catch {
                        print("[AI] Action-only failed for single message \(messageId): \(error)")
                    }
                }
            }()

            async let rTask: Void = {
                guard !hasReply else { return }

                // Re-read model to check if another path populated the reply
                let msg = try? await dbPool.read({ db in try MessageHeader.fetchOne(db, key: headerId) })
                if let msg, msg.cachedReply == nil {
                    do {
                        let reply = try await aiService.processReply(
                            messageId: messageId,
                            rfc822MessageId: rfc822MessageId,
                            accountEmail: accountEmail,
                            subject: subject,
                            from: from,
                            fromAddress: fromAddress,
                            to: toRecipients,
                            date: date,
                            bodyText: plainText,
                            htmlContent: htmlContent,
                            userName: userName,
                            kbText: kbText,
                            compositionPrompt: compositionPrompt
                        )
                        if let reply {
                            // T4.V7 site 7.
                            let outcome = (try? await dbPool.write { db in
                                try AccountManager.aiGuardedHeaderWrite(db, target: target) { msg, db in
                                    msg.cachedReply = reply
                                    try msg.save(db)
                                    if !reply.isEmpty {
                                        try MessageAICache.writeThrough(
                                            accountId: accountId,
                                            folderPath: msg.folderPath,
                                            rfc822MessageId: msg.rfc822MessageId,
                                            cachedReply: reply,
                                            replyGeneratedAt: Date(),
                                            db: db
                                        )
                                        if DebugModeManager.isLoggingEnabled() {
                                            print("[AI] Reply precomputed for direct path \(messageId)")
                                        }
                                    } else {
                                        if DebugModeManager.isLoggingEnabled() {
                                            print("[AI] Reply filtered (sentinel) for direct path \(messageId)")
                                        }
                                    }
                                }
                            }) ?? .dropped
                            guard outcome == .written else {
                                if DebugModeManager.isLoggingEnabled() {
                                    print("[AI] T4.V7 direct reply write dropped for \(messageId)")
                                }
                                return
                            }
                            NotificationCenter.default.post(name: .messageDataDidChange, object: headerId)
                        }
                    } catch {
                        print("[AI] Reply precompute failed for direct path \(messageId): \(error)")
                    }
                }
            }()

            // Wait for both SA and R to complete
            _ = await (saTask, rTask)
        }
    }

    // MARK: - Manual Tag Teaching (port of TB contextMenus.js applyManualTags)

    /// Apply a manual tag override from the user (long-press context menu).
    /// Matches TB addon's "Tag as Reply/None/Archive/Delete" flow:
    /// 1. Update GRDB state (optimistic UI)
    /// 2. Write tag to IMAP/Gmail
    /// 3. Update persistent AI cache
    /// 4. Fire-and-forget: auto-update user_action.md via LLM patch
    func applyManualTag(_ message: MessageHeader, tag: ActionTag?) async {
        // Block self-sent tagging (matches TB's isInternalSender check)
        guard let account = try? await dbPool.read({ db in try Account.fetchOne(db, key: message.accountId) }) else {
            print("[ManualTag] No account for message \(message.messageId)")
            return
        }

        if message.fromAddress.lowercased() == account.emailAddress.lowercased() {
            print("[ManualTag] Blocking manual tag on self-sent message \(message.messageId)")
            return
        }

        let previousTag = message.actionTag
        let accountId = message.accountId
        let messageId = message.messageId
        let folderPath = message.folderPath
        let rfc822MessageId = message.rfc822MessageId

        // Capture data for auto-update prompt BEFORE changing the tag
        let subject = message.subject
        let from = message.from
        let summaryBlurb = message.summaryBlurb
        let summaryTodos = message.summaryTodos
        let originalAction = previousTag?.rawValue ?? ""
        let userManualTag = tag?.rawValue ?? ""

        if DebugModeManager.isLoggingEnabled() { print("[ManualTag] START messageId=\(messageId) previousTag=\(previousTag?.rawValue ?? "nil") newTag=\(tag?.rawValue ?? "nil") subject=\(subject.prefix(60)) from=\(from.prefix(40))") }
        if DebugModeManager.isLoggingEnabled() { print("[ManualTag] summaryBlurb=\(summaryBlurb?.prefix(80) ?? "nil") summaryTodos=\(summaryTodos?.prefix(80) ?? "nil")") }

        // A staged-only row (ADR-IOS-049) isn't in GRDB yet — Step 1's
        // fetchOne-guarded write would silently no-op and the user's tag
        // would vanish with no error and no retry (round-2 audit). Force the
        // row durable first, mirroring markRead/markUnread/markFlagged/move.
        await ensureDurable([message])

        // Step 1: Update GRDB state immediately (optimistic UI)
        try? await dbPool.write { db in
            guard var msg = try MessageHeader.fetchOne(db, key: message.id) else { return }
            msg.setActionTag(tag)
            try msg.save(db)
        }

        Task { @MainActor in NotificationCenter.default.post(name: .inboxDataDidChange, object: nil) }

        // Steps 3-4 run asynchronously
        Task {
            // Step 3: Update persistent AI cache
            try? await dbPool.write { db in
                try MessageAICache.writeThrough(
                    accountId: accountId,
                    folderPath: folderPath,
                    rfc822MessageId: rfc822MessageId,
                    actionTag: tag,
                    db: db
                )
            }
            print("[ManualTag] Applied \(tag?.displayName ?? "remove") to \(messageId)")

            // Step 4: Enqueue auto-update user_action.md for durable retry via BackfillAIQueue.
            // Previously a fire-and-forget LLM call — now persisted to GRDB first so it
            // survives app kill / suspend / network drop. The queue drains on BGProcessing
            // and foreground. `currentUserActionMd` is read live at drain time.
            if tag != nil, originalAction != userManualTag {
                // Re-tag enqueue counts against the
                // demo budget, but the consume happens at *drain* time (in
                // BackfillAIQueue) so it reflects an actual outgoing call.
                // Here we only short-circuit when the budget is already at
                // zero — no point queueing what can't drain.
                let isDemo = await MainActor.run { DemoModeStore.shared.isActive }
                let exhausted = await MainActor.run { DemoModeStore.shared.isCallBudgetExhausted }
                if isDemo && exhausted {
                    print("[ManualTag] Step 4: skip enqueue — demo budget exhausted")
                } else {
                    print("[ManualTag] Step 4: enqueuing actionRefine original=\(originalAction) userTag=\(userManualTag)")
                    let snapshot = ActionRefineSnapshot(
                        messageStableId: message.stableId,
                        accountId: accountId,
                        subject: subject,
                        from: from,
                        summaryBlurb: summaryBlurb,
                        summaryTodos: summaryTodos,
                        originalAction: originalAction,
                        userManualTag: userManualTag
                    )
                    await BackfillAIQueue.shared.enqueueActionRefine(snapshot)
                    print("[ManualTag] Step 4: actionRefine enqueued")
                }
            } else {
                print("[ManualTag] Step 4: skipped actionRefine — tag=\(tag?.rawValue ?? "nil") original=\(originalAction) userTag=\(userManualTag)")
            }
        }
    }

    // MARK: - Reply-based Local Notification

    /// Post an active local notification when a newly-processed message is
    /// reply-tagged (`EmailNotificationBuilder.isImportant`). Gate matches
    /// the NSE — reply is the single source of "important enough to ping".
    /// Reminder fields flesh out the body when present but do not drive the
    /// active/passive decision.
    ///
    /// Skips when the NSE has already notified for this message
    /// (`header.notified == true`).
    ///
    /// T4.V7 site 9: the header is RE-RESOLVED through `target` before the banner is
    /// built, and `notified` is stamped only inside the identity-verified guarded
    /// write. If identity moves between the `add` and the write, the banner already
    /// added carries the OLD message's payload — so we remove ONLY the exact request
    /// THIS call added (safe: it is the identifier this call created) and do NOT
    /// stamp. Stamping the impostor would suppress ITS own future notification.
    @MainActor
    private func postReplyNotificationIfNeeded(target: AIWriteTarget) async throws {
        guard let header = try await dbPool.read({ db in try target.resolveCurrentHeader(db: db) }),
              !header.notified else { return }
        let signal = EmailNotificationBuilder.Signal(
            senderName: header.from,
            senderEmail: header.fromAddress,
            subject: header.subject,
            summaryBlurb: header.summaryBlurb,
            actionTag: header.actionTag?.rawValue,
            reminderContent: header.reminderContent,
            dueDate: header.reminderDate,
            dueTime: header.reminderTime
        )
        guard EmailNotificationBuilder.isImportant(signal) else { return }

        let notificationId = EmailNotificationBuilder.identifier(
            accountId: header.accountId, messageId: header.messageId
        )

        // Remove any existing passive notification (from NSE metadata-only)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationId])

        let content = UNMutableNotificationContent()
        EmailNotificationBuilder.fill(
            content, signal: signal,
            accountId: header.accountId, messageId: header.messageId
        )

        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notificationId, content: content, trigger: nil))

        let outcome = try await dbPool.write { db in
            try AccountManager.aiGuardedHeaderWrite(db, target: target) { msg, db in
                msg.notified = true
                try msg.save(db)
            }
        }
        if outcome == .dropped {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationId])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationId])
            if DebugModeManager.isLoggingEnabled() {
                print("[AI] Reply notification dropped (identity moved) for \(target.headerId)")
            }
            return
        }
        if DebugModeManager.isLoggingEnabled() {
            print("[AI] Posted reminder notification for \(target.headerId)")
        }
    }
}
