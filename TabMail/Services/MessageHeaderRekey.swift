/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

// MARK: - The destination address the wire already gave us

/// One member's destination address, exactly as the server itself named it in
/// its answer to the move THIS operation issued.
///
/// THE ADDRESS PROBLEM, closed where it is created. A `PendingOperation` names
/// its members by their address in the SOURCE folder, and on IMAP an address is
/// `(folder, UID, UIDVALIDITY)`. **A move changes that address**, and the server
/// hands us the new one in `COPYUID` — which `IMAPProvider.copyProvenSourceUIDs`
/// reads only to VALIDATE and then discards. This type is that discarded half,
/// carried to the drain so the move can be finished LOCALLY instead of being
/// repaired later by sync on weaker (RFC 822) evidence.
///
/// 🚨 **PROVIDER-NEUTRAL, because the discard was never IMAP-specific.** The
/// identical sentence is true of Microsoft Graph: `POST /messages/{id}/move`
/// answers with the moved message **carrying its new `id`**, Graph ids churn on
/// every folder move by default (no `Prefer: IdType="ImmutableId"` is sent
/// anywhere in this app), and `ExchangeProvider.moveMessage` bound that response
/// to `_`. The two address spaces differ only in what an address IS — a UID
/// inside an epoch on IMAP, an opaque resource id with NO epoch space on Graph —
/// so the id is a `String` and the epoch is OPTIONAL. `KNOWN_ISSUES.md`
/// `IOS-GRAPH-002`, `MIS-IOS-003` instance 5, `MIS-006` instance 5.
///
/// ⚠ NOT an rfc822 Message-ID, and never derived from one. ADR-IOS-068 / D4
/// forbids the Message-ID as mutation authority and forbids a `SEARCH` result
/// from ever being a mutation target. The authority here is the wire's own
/// answer to the move THIS operation issued — attempt-correlated by
/// construction, and strictly stronger than any identity probe.
struct ProvenDestinationAddress: Sendable, Equatable {
    /// The provider id the operation named — the SOURCE UID as a string on
    /// IMAP, the source Graph resource id on Exchange.
    let sourceProviderId: String
    /// The provider id the server assigned to the copy it created in the
    /// destination — the destination UID as a string on IMAP, the `id` of the
    /// message resource Graph returned from `/move` on Exchange.
    let destinationProviderId: String
    /// The destination address space's epoch, when the provider HAS one: the
    /// destination mailbox's UIDVALIDITY, stamped on the same `COPYUID`.
    ///
    /// **`nil` means the provider has no epoch space at all** (Graph), NOT that
    /// an epoch was expected and went missing — `IMAPProvider.move` refuses
    /// before any wire mutation when a destination epoch is unreadable, so it
    /// never reaches this type unset. `finishMove`'s G2 leaves the row's stamp
    /// unread for a `nil` epoch, which is both the correct value and the safe
    /// one (see G2).
    let destinationUidValidity: UInt32?
}

/// What one provider move attempt DISPOSITIONED, and where the server said the
/// copies landed.
///
/// Top-level rather than nested in `IMAPProvider` because it has TWO producers:
/// `IMAPProvider.move(ids:from:to:admittedUidValidity:)` and
/// `ExchangeProvider.moveProvingDestinations(ids:from:to:)`. Both feed the same
/// consumer — `AccountManager.executeOperation`'s `.move` case — so one
/// type keeps the two arms from drifting.
struct MoveOutcome: Sendable {
    /// The subset of the requested ids this attempt DISPOSITIONED (per-member
    /// retirement, B-2).
    let provenIds: [String]
    /// Per-member destination addresses the server itself named. Never a
    /// superset of `provenIds`; frequently empty.
    let provenDestinations: [ProvenDestinationAddress]
    /// The wire reported that MOVE may have changed only part of the source
    /// mailbox before ending with tagged NO/BAD. Retrying the original source
    /// identifiers is unsafe; the queue must refresh the source as well as the
    /// destination after retiring this attempt.
    let requiresSourceReconciliation: Bool

    init(
        provenIds: [String],
        provenDestinations: [ProvenDestinationAddress],
        requiresSourceReconciliation: Bool = false
    ) {
        self.provenIds = provenIds
        self.provenDestinations = provenDestinations
        self.requiresSourceReconciliation = requiresSourceReconciliation
    }
}

/// One applied re-key. The local row that used to live at `oldHeaderId` now
/// lives at `newHeaderId` and carries `newProviderMessageId`.
///
/// For provider-proven move results, consumed OUTSIDE the GRDB write by the
/// stores that key by `messageHeader.id`, through
/// `AccountManager.publishMoveFinish`. Sync's weaker RFC-corroborated UID
/// remap also uses this value for active view-local identity only; its FTS
/// carrier remains `SyncMessagesResult.ftsRekeys`, and it never publishes a
/// provider-address handoff or a destination epoch.
///
/// ⚠ A consumer tally in prose has no compiler and no test behind it, so it is
/// correct only until the next consumer appears. The census is regenerated
/// from the callers of this type
/// (`rg 'HeaderRekeyRecord|applyRekeys|rekeyHeaders|rekeyContentKey'` over
/// `TabMail/ Shared/`), never read off this sentence — re-run it before
/// restating the count, and add move-owned stores to `publishMoveFinish` rather
/// than to a second move mirror point.
struct HeaderRekeyRecord: Sendable, Equatable {
    let oldHeaderId: String
    let newHeaderId: String
    let newProviderMessageId: String
    /// Destination-folder epoch proven by the provider and corroborated by
    /// the local folder row. `nil` means no UID epoch is conveyed; providers
    /// without an epoch space can still carry provider-address authority.
    let newObservedUidValidity: Int?
    /// Whether the provider itself proved the destination address. Sync's
    /// RFC-corroborated UID repair sets this false: active snapshots may follow
    /// the committed row, but optimistic action/dismissal state must not treat
    /// that weaker correlation as mutation authority.
    let carriesProviderAuthority: Bool

    init(
        oldHeaderId: String,
        newHeaderId: String,
        newProviderMessageId: String,
        newObservedUidValidity: Int? = nil,
        carriesProviderAuthority: Bool = true
    ) {
        self.oldHeaderId = oldHeaderId
        self.newHeaderId = newHeaderId
        self.newProviderMessageId = newProviderMessageId
        self.newObservedUidValidity = newObservedUidValidity
        self.carriesProviderAuthority = carriesProviderAuthority
    }
}

/// Every local disposition produced while retiring an address-changing move.
/// Applied and removed old ids are disjoint. `unsafeUndoOldHeaderIds` is an
/// authority disposition rather than a row disposition: it includes both an
/// exact optimistic row retained without a safe destination address and an old
/// key now occupied by a row this operation no longer owns. Neither case may
/// retain undo authority for the completed source-address move.
struct MoveFinishResult: Sendable, Equatable {
    var applied: [HeaderRekeyRecord] = []
    var unsafeUndoOldHeaderIds: [String] = []
    var removedOldHeaderIds: [String] = []
    /// Ids of the QUEUED/IN-FLIGHT `PendingOperation` rows whose members this
    /// retirement re-addressed to the destination ids the wire just proved
    /// (`IOS-GRAPH-005`). Reported so the caller can log the handoff — the
    /// `IOS-QUEUE-008` lesson is that a serialization fact nobody can read back
    /// out of an exported log gets misdiagnosed for a month.
    var readdressedOperationIds: [String] = []

    static let empty = MoveFinishResult()
}

// MARK: - The re-key itself

enum MessageHeaderRekey {
    private struct AddressHandoffState: Sendable {
        var aliases: [String: String] = [:]
        var insertionOrder: [String] = []
    }

    /// A process-local bridge across the only gap where the durable row has
    /// its provider-proven destination key but slower in-memory mirrors have
    /// not caught up yet. A gesture Task admitted under the old key can run in
    /// that gap. Process death also kills that Task, so this is intentionally
    /// not durable state.
    private static let addressHandoffs = Mutex(AddressHandoffState())
    private static let addressHandoffLimit = 512

    /// Register from inside the transaction that performs the re-key. GRDB runs
    /// the commit callback on its serialized writer queue, after a successful
    /// commit and before the async write continuation resumes. A rollback
    /// publishes nothing.
    static func publishAddressHandoffsAfterCommit(
        _ records: [HeaderRekeyRecord],
        in db: Database
    ) {
        guard !records.isEmpty else { return }
        db.afterNextTransaction { _ in
            publishAddressHandoffs(records)
        }
    }

    private static func publishAddressHandoffs(_ records: [HeaderRekeyRecord]) {
        guard !records.isEmpty else { return }
        addressHandoffs.withLock { state in
            for record in records {
                if state.aliases.updateValue(
                    record.newHeaderId, forKey: record.oldHeaderId) == nil {
                    state.insertionOrder.append(record.oldHeaderId)
                }
            }
            let overflow = state.insertionOrder.count - addressHandoffLimit
            guard overflow > 0 else { return }
            for oldId in state.insertionOrder.prefix(overflow) {
                state.aliases.removeValue(forKey: oldId)
            }
            state.insertionOrder.removeFirst(overflow)
        }
    }

    /// Resolve only a chain the provider itself proved. Exact durable lookup
    /// still wins at the call site, so a later address reuse is never replaced
    /// by stale process-local history.
    static func currentHeaderId(afterHandoffFrom id: String) -> String {
        addressHandoffs.withLock { state in
            var current = id
            var visited: Set<String> = [id]
            while let next = state.aliases[current],
                  visited.insert(next).inserted {
                current = next
            }
            return current
        }
    }

    /// Old provider-proven addresses that now lead to `id`, nearest handoff
    /// first. This lets short-lived optimistic state follow the same exact
    /// move as the durable row during the commit-to-mirror gap. The set is
    /// bounded with `addressHandoffs`; it is never a database lookup key or a
    /// durable identity claim.
    static func predecessorHeaderIds(leadingTo id: String) -> [String] {
        addressHandoffs.withLock { state in
            state.insertionOrder.reversed().filter { candidate in
                var current = candidate
                var visited: Set<String> = [candidate]
                while let next = state.aliases[current],
                      visited.insert(next).inserted {
                    current = next
                }
                return current == id
            }
        }
    }

    #if DEBUG
    static func clearAddressHandoffsForTesting() {
        addressHandoffs.withLock { state in
            state.aliases.removeAll()
            state.insertionOrder.removeAll()
        }
    }
    #endif

    /// Re-key ONE local header row to a new primary key, carrying every child
    /// row the delete would otherwise destroy.
    ///
    /// **EXTRACTED, NOT INVENTED.** This is the sequence
    /// `SyncEngine.runSyncMessages` has always run for a UID remap (the block
    /// that logs `[Sync] UID remap:`), lifted here so the drain can run the
    /// IDENTICAL re-key EARLIER, authorized by the server's own `COPYUID`
    /// rather than by an RFC 822 match. Both callers share this body, so the
    /// two paths cannot drift.
    ///
    /// **ORDERING IS LOAD-BEARING.** The body fetch, the user-label capture and
    /// BOTH deletes must precede EVERY exit — including the collision return —
    /// or the leg that skips the re-insert still leaves the orphan behind. The
    /// `messageBody` FK cascade that used to reclaim the body row is gone as of
    /// Stage D, so the delete is explicit.
    ///
    /// **THE TWO CHILD TABLES THAT CASCADE**, both declared
    /// `.references("messageHeader", onDelete: .cascade)` in `AppDatabase`, and
    /// both silently destroyed by the delete unless handled here:
    ///  - `messageReference` (threading references) is **REBUILT** from the
    ///    migrated header's own `References` / `In-Reply-To` content, so the
    ///    rebuild is exact — the header carries its own source of truth.
    ///  - `messageUserLabel` (user-assigned labels) has **NO rebuild source**;
    ///    nothing else in the database knows which labels the user applied. It
    ///    is therefore **CAPTURED before the delete and re-inserted under the
    ///    new id**, the same shape as the body. Losing it is silent loss of
    ///    user state, which is why this one is carry-forward and not rebuild.
    ///
    /// **NOT FK-BOUND TO `messageHeader`, so the delete above does not touch
    /// them.** This list used to read *"`bodyAsset`, `pendingRender`,
    /// `chatIdMapping` … each is swept by its own headerId-prefix maintenance
    /// path"*, and by R13-U8 only the third of those three was still true:
    ///  - **`bodyAsset` is NO LONGER out of scope.** R12-T7: once the drain
    ///    began finishing moves locally, `BodyAssetMaintenance.pruneOrphans`
    ///    reclassified a live message's cached bodies and attachments as
    ///    orphans and DELETED them, because its only recovery leg
    ///    (`MessageContentStore.recoverMovedContentKey`) matches an UNCHANGED
    ///    `providerMessageId` — and a re-key is exactly the shape that changes
    ///    it. It is now mirrored outside this write by
    ///    `AccountManager.publishMoveFinish` → `BodyAssetStore.rekeyContentKey`.
    ///    ⚠ A caller of `apply` that does not route through `publishMoveFinish`
    ///    still owes that mirror; this function cannot do it (different pool,
    ///    and it must not run inside the GRDB write).
    ///
    ///    🚨 **AND SOME IN-TREE CALLERS DO NOT MEET IT — stated as the negative
    ///    case, because the sentence above stated an obligation and left a
    ///    reader to assume it was met (`MIS-019`: an absolute like "all other
    ///    callers route through `publishMoveFinish`" is exactly the shape that
    ///    produced this gap).** They are NAMED rather than counted, so the
    ///    sentence cannot go stale as an integer (`MIS-007`). ⚠ Re-derive the
    ///    roster with an instrument this doc block cannot itself enter — a bare
    ///    `rg 'MessageHeaderRekey.apply'` matches the bullets below and counts
    ///    its own recording (`MIS-033`; `IOS-DOC-002` requires the predicate):
    ///    ```
    ///    rg -n --pcre2 '^(?!\s*(///|//)).*MessageHeaderRekey\.apply\(' \
    ///       TabMail/ Shared/ TabMailNotificationService/
    ///    ```
    ///    → 5 at R17-1 (was 3), and **still 5 at R18-D5**. Check each hit
    ///    against `AccountManager.publishMoveFinish`; the ones that do NOT
    ///    reach it are:
    ///     * the **UID-remap block in `SyncEngineFullSync`** — the
    ///       `guard try MessageHeaderRekey.apply(…)` inside the stale-message
    ///       loop;
    ///     * **`SyncEngine.canonicalizeLocalRows`** — the `willRekey`
    ///       leg, which became a caller in R17-1 (it hand-rolled the identical
    ///       delete+reinsert before that, destroying both children outright, so
    ///       adopting this carrier strictly reduced its loss);
    ///     * **`DemoProvider.move`**, also R17-1 — demo mode only, and demo has
    ///       no `publishMoveFinish` path at all;
    ///     * 🚨 **`DraftStore.migrateExactPlaceholder` — ADDED R18-D5. The
    ///       roster said THREE and the predicate returns FIVE, and the arithmetic
    ///       is the whole point: this bullet list is the "does not reach
    ///       `publishMoveFinish` AND still owes a leg" set, so it is NOT simply
    ///       `5 − 2`.** `BackfillBodyQueue.rekeyRemappedHeader` also never
    ///       reaches `publishMoveFinish` and is correctly absent, because it
    ///       DISCHARGES BOTH MIRRORS INLINE — `SearchIndex.rekeyHeaders` and
    ///       `BodyAssetStore.rekeyContentKey` / `deleteAllAssets` on the
    ///       `.migrated` / `.duplicateDropped` split. `migrateExactPlaceholder`
    ///       discharges only the FTS leg (its caller runs
    ///       `SearchIndex.rekeyHeaders` on the `rekeyed == true` branch, and
    ///       `MessageContentStore.releaseUnowned(stores: [.searchIndex, .body])`
    ///       on the false branch), and does NOT call `rekeyContentKey`. ⚠ The
    ///       false completeness claim being corrected is `f8a437125`'s commit
    ///       body, which said it was "naming all three".
    ///       **`bodyAsset` leg — NOT discharged, and the population it would
    ///       carry is provably EMPTY, which is why this is a doc correction and
    ///       not a fix.** Verified rather than assumed, by censusing the
    ///       manifest's row-CREATING entry points (`prepare`/`publish` have no
    ///       callers outside `BodyAssetStore.write`, so the class is exactly
    ///       `writeInlineImage` / `writeAttachment` / `makeInlineImageWriter`):
    ///       ```
    ///       rg -n 'BodyAssetStore\.(writeInlineImage|writeAttachment|prepare|publish|makeInlineImageWriter)\(' \
    ///          TabMail/ Shared/ TabMailNotificationService/
    ///       ```
    ///       → 5 non-comment sites at R18-D5: `GmailAPI`, `GraphAPI`,
    ///       `IMAPFetchMapping`, `BodyFetchProcessor` (all four take their
    ///       content key from a header being fetched FROM the provider) and
    ///       `AttachmentListView` (reached only AFTER
    ///       `manager.fetchAttachment(for:section:)` returns bytes). A draft
    ///       placeholder's `messageId` is
    ///       `PendingOperation.draftPlaceholderMessageId` — `draft-<draftId>…`,
    ///       not an address any provider can fetch — so none of the five can
    ///       ever produce a row under a placeholder content key. Independently:
    ///       `AccountManagerActions` creates the placeholder header and its
    ///       `MessageBody` in the SAME write, with
    ///       `MessageBody.plainTextToHTML(draft.body)` — no `cid:` inline images
    ///       and no attachment sections — so there is nothing for a render path
    ///       to write even if one ran.
    ///       **`UndoService` leg** — inherits the same disposition as the two
    ///       `SyncEngineFullSync` callers below: an undo entry naming the old id
    ///       resolves nothing and fails closed, bounded by the undo stack's
    ///       lifetime.
    ///       ⚠ **What would falsify this and make it a real loss path:** a draft
    ///       placeholder gaining attachment sections or `cid:` inline images in
    ///       its locally-composed body, or any new `BodyAssetStore` write site
    ///       keyed by a header id that was not fetched from a provider. Re-run
    ///       the predicate above before assuming the population is still empty.
    ///    Leg by leg, for the two `SyncEngineFullSync` callers:
    ///     * **FTS — DISCHARGED, by the caller itself, not by `publishMoveFinish`.**
    ///       The UID-remap block appends to `ftsRekeys` directly; the
    ///       canonicalizer returns its pair in the `ftsRekey` tuple, which
    ///       `runSyncMessages` folds into the same `ftsRekeys`. Both end at the
    ///       same `SearchIndex.rekeyHeaders`, and both deliberately keep the
    ///       re-keyed old id OFF the `staleIds` channel (`uidMigratedSet` is
    ///       filtered out of `staleFiltered`) because the FTS entry must MOVE,
    ///       not be removed. So the obligation is not "all three legs" for every
    ///       caller — assuming that is how a reader concludes the sync path is
    ///       broken in a way it is not. `DemoProvider.move` has no FTS mirror at
    ///       all, which is a demo-only cost and is not this function's to close.
    ///     * **`UndoService.applyRekeys` — NOT discharged.** An undo entry that
    ///       names the old header id keeps naming it, so the undo resolves
    ///       nothing and fails closed. Bounded by the undo stack's lifetime.
    ///     * **`BodyAssetStore.rekeyContentKey` — NOT discharged, and the
    ///       consequence is not merely a cache miss.** The old key's assets
    ///       become orphans while the carried-forward `messageBody` row at the
    ///       NEW key still references them through `tabmail-asset://` — the
    ///       R12-T7 mechanism `publishMoveFinish` calls *"A REGRESSION, NOT MERELY
    ///       AN EDGE"*. The old id rides neither the re-key channel nor the
    ///       `staleIds` removal (which does clear `stores: [.searchIndex, .body]`).
    ///
    ///    **Why it is accepted under THE MANTRA rather than fixed, and the
    ///    load-bearing half re-verified at `07a4bb703` rather than inherited.**
    ///    `git show 07a4bb703:` that file: the UID-remap block already did
    ///    collision-skip → `migrated.insert(db)` → `body.id = newId;
    ///    body.insert(db)`, already fed `ftsRekeys`, and already kept the
    ///    re-keyed id off `staleIds` — this `apply` is that sequence extracted
    ///    verbatim. And `git ls-tree 07a4bb703` shows `BodyAssetStore` and
    ///    `BodyAssetMaintenance.pruneOrphans` present while `publishMoveFinish`,
    ///    `UndoService.applyRekeys` and `BodyAssetStore.rekeyContentKey` are
    ///    **absent entirely**. So the sync path's exposure is byte-identical to
    ///    shipped: v3 built the mirror for the DRAIN, whose re-key was a v3
    ///    regression against an ordinary primary path, and did not extend it to
    ///    a path v3 never changed. It self-heals at
    ///    `SyncConfig.bodyCacheTTLHours`, so the recoverability test says fail
    ///    closed and let it be. Registered, not mechanised.
    ///  - **`pendingRender` is a DEAD TABLE.** `v32` created it for durable
    ///    body staging; nothing has INSERTed, SELECTed or UPDATEd it since. The
    ///    only surviving statements are two DELETEs — `SettingsView`'s reset
    ///    list and `AccountManagerUidValidityReset`'s step (iv). It has no rows
    ///    to orphan and no headerId-prefix sweep of its own, so naming it here
    ///    described a hazard that does not exist. ⚠ The retention REASON given
    ///    here was wrong and is corrected: *"a registered migration is
    ///    immutable"* freezes `v32`'s NAME and BODY (Data Integrity rule 5), and
    ///    says nothing about whether a NEW `v84` may `DROP TABLE pendingRender`
    ///    — it may. The actual reason is the launch path: a drop can only be
    ///    reached through a registered migration, the blocking chain was just
    ///    cut 27,601 ms → ~3,241 ms by moving work OFF it, and dropping a table
    ///    that is provably empty in every database reclaims nothing. The two
    ///    surviving DELETEs are kept for a second, independent reason — both
    ///    are members of safety ENUMERATIONS, so removing them is fail-dangerous
    ///    if body staging is ever revived. Adjudicated in `KNOWN_ISSUES.md`
    ///    `IOS-MIGRATION-005`; the conclusion (do not "clean it up" with a DROP)
    ///    is unchanged.
    ///  - **`chatIdMapping`** is the one the original sentence still fits:
    ///    swept by `ChatIdTranslator.purgeMappingsForFolder`, which matches
    ///    `realId` with `MessageIdentity.headerIdBelongsToFolder`. Pre-existing
    ///    and unchanged by this helper — sync's UID-remap path has re-keyed
    ///    headers out from under it since long before the drain did.
    ///
    /// - Returns: `true` when `migrated` was inserted. `false` when a row
    ///   already occupies the new id — in which case the old row is still gone,
    ///   which is the pre-existing behaviour of the sync path's `continue`
    ///   (the new id is the survivor and the old id's FTS entry is dropped by
    ///   the caller's ordinary stale handling rather than re-keyed).
    @discardableResult
    static func apply(from old: MessageHeader, to migrated: MessageHeader, db: Database) throws -> Bool {
        let oldId = old.id
        let newId = migrated.id
        // Everything the delete destroys is read FIRST — see "ORDERING IS
        // LOAD-BEARING" above. Both deletes then run unconditionally, so the
        // collision return below cannot leave a duplicate plus a leak.
        let oldBody = try MessageBody.fetchOne(db, key: ContentKey(rawValue: oldId))
        let carriedLabels = try MessageUserLabel
            .filter(Column("messageId") == oldId)
            .fetchAll(db)
        try old.delete(db)
        _ = try MessageBody.deleteOne(db, key: ContentKey(rawValue: oldId))
        // Defensive — if a concurrent path already inserted this id, skip
        // instead of throwing UNIQUE.
        guard try MessageHeader.fetchOne(db, key: newId) == nil else { return false }
        try migrated.insert(db)
        if var body = oldBody {
            body.id = ContentKey(rawValue: newId)
            try body.insert(db)
        }
        for label in carriedLabels {
            var carried = label
            carried.messageId = newId
            try carried.insert(db)
        }
        try ThreadUtils.insertMessageReferences(for: migrated, db: db)
        return true
    }

    /// FINISH THE MOVE LOCALLY: re-key each member for which the provider
    /// returned one unambiguous destination address, from its source address to
    /// the destination address the server itself assigned.
    ///
    /// Called from inside the SAME write transaction that deletes the completed
    /// `PendingOperation`, so the crash window is no worse than today's: either
    /// the op is retired and the rows are re-keyed, or neither happened and the
    /// op re-executes (idempotently).
    ///
    /// WHY THIS EXISTS. `AccountManager.optimisticMoveToFolder` moves the
    /// row's `folderId`/`folderPath` to the destination, NILS
    /// `observedUidValidity`, and leaves the primary key and `messageId` at
    /// their SOURCE values. Until something repairs that, the row is refused by
    /// `admittedOrdinaryActionTargets` (which requires a live epoch and a
    /// parseable UID), so **the user's next gesture on a just-moved message is
    /// a silent dead no-op** — swipe-archive, then swipe-delete from Archive,
    /// and nothing happens at all. Sync's UID-remap path repairs it eventually,
    /// but only if the remnant is selected as stale (which compares a SOURCE UID
    /// against the DESTINATION folder's UID floor — two different address
    /// spaces) AND its rfc822 Message-ID matches a new remote message. Either
    /// can fail permanently.
    ///
    /// **THE FOUR GUARDS**, each closing a specific hazard:
    ///
    /// **G1 — pairing.** `IMAPProvider.copyProvenDestinations` rejects a
    /// non-corresponding `COPYUID` response as a whole. This seam adds a final
    /// provider-independent check: a source and destination id must each occur
    /// exactly once inside this operation before either can authorize a re-key.
    ///
    /// **G2 — epoch corroboration is the MIRROR-IMAGE guard.** When both the
    /// provider and the destination `Folder` report positive epochs and they
    /// disagree, neither the destination id nor its stamp is adopted. The
    /// optimistic source-address row survives with a nil stamp, which keeps
    /// later gestures retryable and fail-closed until destination sync repairs
    /// it. When the positive epochs agree, the new row carries that epoch.
    ///
    /// **A provider with NO epoch space still re-keys.** Graph has no
    /// UIDVALIDITY, so both the evidence and the moved row legitimately retain
    /// a nil epoch. Nil is absence of an epoch domain, not contrary evidence.
    ///
    /// **G3 — collision and TOCTOU.** The row must still be the exact optimistic
    /// row THIS operation moved (same account, same provider id, still sitting
    /// in this op's destination folder). A different or already-repaired row is
    /// untouched. A vanished old row, or a collision that deletes the old row
    /// while preserving an existing destination row, is classified for cleanup
    /// of mirrors that still name the old id. GRDB's single writer serializes
    /// this against concurrent sync.
    ///
    /// **G4 — missing evidence is provider-sensitive.** An address-changing
    /// provider with no safe destination evidence retains the optimistic row;
    /// its stale-address undo member is separately discarded so it can never
    /// mutate a bystander. Gmail's label-based move keeps a stable provider id,
    /// so `addressChangesOnMove == false` bypasses address repair entirely.
    ///
    /// **`accountScopedIds` SELECTS THE ADDRESS SPACE, and it is not cosmetic.**
    /// It is the same fact the drain's lane key uses
    /// (`AccountManager.accountScopedIdAccountIds`): one provider id names one
    /// message per ACCOUNT, not one per FOLDER. It turns on two behaviours that
    /// would be WRONG on IMAP:
    ///  1. the member's row is located by `(accountId, messageId)` and re-keyed
    ///     in whatever folder it currently occupies, instead of by primary key
    ///     at `op.destinationPath` (§3.3 — the row-built gesture after an undo);
    ///  2. every other non-cancelled operation of this account that still names
    ///     a source id is re-addressed to the proven destination id in this same
    ///     transaction (`readdressQueuedOperations`).
    /// On IMAP a UID is mailbox-local, so both would be wrong-message mutations
    /// (C3): a different message can legitimately carry the same numeric UID in
    /// another folder. The flag is therefore NOT defaulted — every caller states
    /// which address space its account is in, and a new call site cannot inherit
    /// the wrong one by omission.
    ///
    /// - Returns: applied re-keys, old ids whose completed source-address undo
    ///   authority is unsafe, removed old ids, and the ids of the queued
    ///   operations re-addressed by this retirement. Callers publish those
    ///   dispositions to undo, FTS, and body assets.
    static func finishMove(
        _ op: PendingOperation,
        destinations: [ProvenDestinationAddress],
        addressChangesOnMove: Bool,
        accountScopedIds: Bool,
        db: Database
    ) throws -> MoveFinishResult {
        guard op.type == .move, addressChangesOnMove,
              let destinationPath = op.destinationPath,
              destinationPath != op.folderPath
        else { return .empty }

        let destinationFolderId = MessageIdentity.folderId(
            accountId: op.accountId, folderPath: destinationPath)
        // G2 — read the folder's OWN epoch; the stamp is admitted only if the
        // server's reported epoch agrees with it.
        let folderEpoch = try Folder.fetchOne(db, key: destinationFolderId)?.lastKnownUidValidity
        let memberIds = Set(op.messageIds)
        let inScope = destinations.filter { memberIds.contains($0.sourceProviderId) }
        let sourceCounts = Dictionary(
            grouping: inScope, by: \.sourceProviderId).mapValues(\.count)
        let destinationCounts = Dictionary(
            grouping: inScope, by: \.destinationProviderId).mapValues(\.count)
        let safeDestinationPairs: [(String, ProvenDestinationAddress)] = inScope.compactMap {
            destination in
                guard sourceCounts[destination.sourceProviderId] == 1,
                      destinationCounts[destination.destinationProviderId] == 1
                else { return nil }
                return (destination.sourceProviderId, destination)
            }
        let safeDestinations = Dictionary(uniqueKeysWithValues: safeDestinationPairs)

        var result = MoveFinishResult.empty
        var visited: Set<String> = []
        for sourceProviderId in op.messageIds where visited.insert(sourceProviderId).inserted {
            // The address this member had when the gesture was issued. On IMAP it
            // IS the optimistic row's primary key. On an account-scoped provider
            // it is only a REPORTING id for the "no row" and "ambiguous" arms,
            // because the row is allowed to have moved on since (see below).
            let sourceShapedOldId = MessageIdentity.headerId(
                accountId: op.accountId, folderPath: op.folderPath,
                messageId: sourceProviderId)
            // The three facts the re-key needs: the row, its CURRENT primary key,
            // and the folder it currently sits in.
            let row: MessageHeader
            let oldId: String
            let landingFolderPath: String

            if accountScopedIds {
                // 🚨 FOLLOW THE ROW — DO NOT ASSUME IT IS STILL AT `destinationPath`.
                // On an account-scoped provider the id names ONE message per
                // account, so the row that carries it is the right row wherever it
                // is. It legitimately is NOT at `destinationPath` in the sequence
                // this branch exists for (`IOS-QUEUE-008`, `IOS-GRAPH-005`):
                // delete → undo → re-delete. The undo is an ordinary reverse move,
                // so when IT retires the row is back in INBOX while this op's
                // `destinationPath` is INBOX too — but after a further move the row
                // is somewhere else again. A primary-key lookup at
                // `destinationPath` would miss it, G3 would decline, the row would
                // keep the id the wire has just invalidated, and the NEXT gesture
                // the user builds FROM THAT ROW would name a dead id, 404, and be
                // deleted by the conflict arm. That is the user's LATEST intention
                // lost, which is a red line — and no sync pass recovers it, because
                // the intention was never on the server to re-derive.
                //
                // Exactly one row may match, and the requirement is fail-closed on
                // both sides: zero matches is the ordinary "the row is already gone"
                // case (unchanged semantics), and two or more means this build
                // cannot tell which message the id names, so it re-keys nothing.
                let candidates = try MessageHeader
                    .filter(Column("accountId") == op.accountId
                        && Column("messageId") == sourceProviderId)
                    .fetchAll(db)
                guard candidates.count == 1, let located = candidates.first else {
                    if candidates.isEmpty {
                        result.removedOldHeaderIds.append(sourceShapedOldId)
                    } else {
                        result.unsafeUndoOldHeaderIds.append(sourceShapedOldId)
                    }
                    continue
                }
                row = located
                oldId = located.id
                landingFolderPath = located.folderPath
            } else {
                guard let located = try MessageHeader.fetchOne(db, key: sourceShapedOldId) else {
                    result.removedOldHeaderIds.append(sourceShapedOldId)
                    continue
                }
                // G3 — only the exact row this operation optimistically moved. A
                // later gesture or a sync-owned replacement is outside this
                // operation and must not be re-keyed or removed.
                //
                // ⚠️ THE FOLDER CLAUSE IS IMAP-SPECIFIC, which is why it is inside
                // this arm. A UID is mailbox-local, so "the row is not where this
                // op put it" genuinely means "this is not the row this op moved".
                // The same clause on an account-scoped provider would decline a row
                // that is unambiguously the right one — see the arm above.
                guard located.accountId == op.accountId,
                      located.messageId == sourceProviderId,
                      located.folderPath == destinationPath,
                      located.folderId == destinationFolderId
                else {
                    // The remote move succeeded, so the source-address undo member
                    // is invalid even though this local row is outside the op's
                    // authority. Retain the row and every external mirror, but
                    // explicitly revoke the stale undo target.
                    result.unsafeUndoOldHeaderIds.append(sourceShapedOldId)
                    continue
                }
                row = located
                oldId = sourceShapedOldId
                landingFolderPath = destinationPath
            }

            guard let destination = safeDestinations[sourceProviderId] else {
                result.unsafeUndoOldHeaderIds.append(oldId)
                continue
            }

            // A positive disagreement means the destination address belongs to
            // an epoch the local folder has not corroborated. Retain the
            // fail-closed optimistic row; nil on either side is not a mismatch
            // (Graph has no epoch space at all).
            if let provenEpoch = destination.destinationUidValidity,
               let folderEpoch, folderEpoch > 0,
               folderEpoch != Int(provenEpoch) {
                result.unsafeUndoOldHeaderIds.append(oldId)
                continue
            }

            let newMessageId = destination.destinationProviderId
            // The row keeps the folder it is in; only its ADDRESS changes. On IMAP
            // `landingFolderPath` is `destinationPath` by G3's folder clause, so
            // this is the same key it always built.
            let newId = MessageIdentity.headerId(
                accountId: op.accountId, folderPath: landingFolderPath,
                messageId: newMessageId)
            guard newId != oldId else {
                result.unsafeUndoOldHeaderIds.append(oldId)
                continue
            }

            var migrated = row
            migrated.id = newId
            migrated.messageId = newMessageId
            // G2 — see the discussion above. Fresher-than-the-folder is worse
            // than unknown, because only the former is terminal. A provider
            // with no epoch space reports `nil` and takes the same arm.
            if let provenEpoch = destination.destinationUidValidity,
               folderEpoch == Int(provenEpoch) {
                migrated.observedUidValidity = Int(provenEpoch)
            } else {
                migrated.observedUidValidity = nil
            }

            guard try apply(from: row, to: migrated, db: db) else {
                // The new id was already occupied, so `apply` deleted the old
                // row and inserted nothing. `oldId` now names no header at all
                // — report it so the caller can drop it from the stores that
                // key by header id and live outside this database.
                result.removedOldHeaderIds.append(oldId)
                continue
            }
            result.applied.append(HeaderRekeyRecord(
                oldHeaderId: oldId, newHeaderId: newId,
                newProviderMessageId: newMessageId,
                newObservedUidValidity: migrated.observedUidValidity))
        }
        result.readdressedOperationIds = try readdressQueuedOperations(
            op, accountScopedIds: accountScopedIds,
            safeDestinations: safeDestinations, db: db)
        return result
    }

    /// CARRY THE HANDOFF INTO THE QUEUE: every other non-cancelled operation of
    /// this account that still names one of the ids the wire just re-addressed is
    /// rewritten to the destination id, in THIS transaction — the one that also
    /// re-keys the header and retires the move.
    ///
    /// WHY IT EXISTS (`IOS-GRAPH-005`). Microsoft Graph REALLOCATES a message's
    /// default id on every move and this tree sends no
    /// `Prefer: IdType="ImmutableId"` (`IOS-GRAPH-002`). Outlook is on
    /// account-qualified drain lanes (`IOS-QUEUE-008`'s amendment), which
    /// GUARANTEES that an op sharing a message with an in-flight move runs AFTER
    /// it. Without this rewrite that guarantee is the defect rather than the fix:
    /// the follower would go to the wire naming the id the move had just
    /// invalidated, Graph would answer 404, and `executeSingleOp`'s single-message
    /// conflict arm would DELETE it — the user's latest intention lost
    /// deterministically instead of merely raced. Serialization is only safe
    /// because the address travels with it.
    ///
    /// WHY DURABLE, NOT A DRAIN-SCOPED MAP: the follower may be claimed in a LATER
    /// drain entirely (an undo issues its inverse and requests a re-drain; an
    /// offline follower is claimed in a pass that never saw the move's response),
    /// and a process-local map cannot survive either. The table is the only truth;
    /// the lane loop re-reads it before executing (`AccountManager.liveOperation`).
    ///
    /// WHY `status != cancelled` RATHER THAN `status == queued`: under
    /// account-qualified lanes every op sharing an id with the retiring op was
    /// claimed in the same pass — `buildLanes` is a connected-component grouping —
    /// so it is `inFlight`, waiting behind this op in the SAME lane task. Those are
    /// exactly the ops that must be re-addressed. An op inserted mid-pass is
    /// `queued` and is covered too. Nothing else can hold the id: an op in another
    /// lane cannot share a member, by construction.
    ///
    /// WHY THE `accountScopedIds` GATE IS LOAD-BEARING (C3): on IMAP a UID is
    /// mailbox-local. `NSEDataBridge.queueSetTagPendingOp` inserts rows keyed by a
    /// bare numeric id against a hard-coded `INBOX`, and any pre-move op can
    /// legitimately name the same number for a DIFFERENT message in another
    /// folder. Re-addressing those by `COPYUID` would mutate the wrong message.
    /// IMAP has no legitimate follower to re-address anyway — the optimistic row
    /// has a nil epoch and `admittedOrdinaryActionTargets` refuses it, which is the
    /// reason `DeferredMoveSuccessor` exists.
    ///
    /// ⚠️ ACCEPTED LIMITATION — THE CRASH WINDOW (owner-accepted 2026-09-04).
    /// If the process dies AFTER Graph returns 2xx for the move and BEFORE this
    /// transaction commits, that move's queued followers keep the dead id. On
    /// relaunch `reconcilePendingOperations` drops the interrupted `.move` (it
    /// cannot tell a completed move from an uncommitted one, and prefers a dropped
    /// move to a duplicate — tracked separately as `TabMail/tabmail-ios#116`), the
    /// header row converges by sync, but the FOLLOWER's intention does not: its
    /// next attempt 404s and the conflict arm deletes it. Nothing can re-associate
    /// it without the response that was lost, and RFC identity may NOT be used as a
    /// mutation authority to bridge the gap (banned, ADR-IOS-068 D4). The window is
    /// bounded to ONE process death inside ONE write, and it is strictly NARROWER
    /// than what it replaces: before this handoff existed, the same follower was
    /// lost on every such move with no crash at all. It is not closable in this
    /// design; the structural fix is to make Graph ids immutable
    /// (`Prefer: IdType="ImmutableId"`), tracked in `TabMail/tabmail-ios#117`.
    /// Do not "fix" it here with an in-memory map, a receipt table, or an identity
    /// lookup.
    ///
    /// - Returns: the ids of the operations whose members were rewritten.
    private static func readdressQueuedOperations(
        _ op: PendingOperation,
        accountScopedIds: Bool,
        safeDestinations: [String: ProvenDestinationAddress],
        db: Database
    ) throws -> [String] {
        guard accountScopedIds, !safeDestinations.isEmpty else { return [] }
        let followers = try PendingOperation
            .filter(Column("accountId") == op.accountId
                && Column("id") != op.id
                && Column("status") != PendingStatus.cancelled.rawValue)
            .fetchAll(db)
        var readdressed: [String] = []
        for follower in followers {
            // Per-id, so a follower `[X, Y]` whose predecessor moved only `X`
            // becomes `[X', Y]`, and a chain converges because each retirement maps
            // against the ids the row carries RIGHT NOW.
            var members = follower.messageIds
            var changed = false
            for index in members.indices {
                guard let destination = safeDestinations[members[index]] else { continue }
                members[index] = destination.destinationProviderId
                changed = true
            }
            guard changed else { continue }
            var updated = follower
            updated.messageIds = members
            // Column-scoped: this transaction learned the ADDRESS and nothing else,
            // so the address is the only thing it may write. A whole-row `save` of a
            // struct fetched here would still be safe, but writing one column keeps
            // the rule identical to `PendingOperation.markQueued`'s.
            try db.execute(
                sql: "UPDATE pendingOperation SET messageIdsJSON = ? WHERE id = ?",
                arguments: [updated.messageIdsJSON, follower.id])
            readdressed.append(follower.id)
        }
        return readdressed
    }
}
