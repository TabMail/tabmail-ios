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
///  - **SUBTRACT `normalizedRfc822MessageId` and the rfc-less capture refusal.**
///    The reference stores a normalized RFC 822 Message-ID, refuses to capture at
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
///    safety win: the C3 hazard these sites face is closed by the epoch arm alone.
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
    /// invalidated by a move, and for any row predating the column — all of which
    /// are an ABSENCE of evidence and therefore PROCEED, never a mismatch.
    let observedUidValidity: Int?

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
            observedUidValidity: message.observedUidValidity
        )
    }

    /// The current row for the captured identity iff it is STILL the same physical
    /// message; `nil` on any disagreement (⇒ the caller drops the write, and the
    /// next recompute heals).
    ///
    /// **The governing rule: only a POSITIVE, PROVEN disagreement authorizes
    /// dropping.** An absence of evidence — a nil epoch on either side — is never
    /// laundered into a mismatch.
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
    ///  6. **either epoch nil** ⇒ PROCEED. `lastKnownUidValidity == nil` is the
    ///     T1.3 first-sync window / demo / screenshot state; a nil header stamp is
    ///     an unproven address. Dropping on either would permanently disable AI for
    ///     the demo and screenshot accounts (see the SUBTRACT note above).
    ///  7. **captured stamp != live folder epoch** ⇒ `nil`. **The only
    ///     positive-evidence exit**: the server reported a UIDVALIDITY that
    ///     disagrees with the one this row's UID was proven under, i.e. a proven
    ///     turnover. Same shape as the single terminal arm of
    ///     `AccountManagerActions.roleMoveRejectDispositions`.
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
        guard let capturedEpoch = observedUidValidity,
              let liveEpoch = folder?.lastKnownUidValidity else { return header }
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
