/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import UserNotifications

/// T4.S6 — the UIDVALIDITY purge-and-resync reaction.
///
/// Triggered by `AccountManager.fireUidValidityChangeHandler` (the merge pass's
/// in-transaction epoch guard, delta sync's STATUS observation, the deletion
/// reconcile walk's per-chunk mismatch) and RE-DRIVEN by `SyncEngine.fullSync`'s
/// per-folder loop for a folder left quarantined by an interrupted prior attempt.
/// IMAP/iCloud only — the triggers themselves only ever fire for those providers.
///
/// PORTED from `v2final:TabMail/Services/Account/AccountManagerUidValidityReset.swift`
/// (`extension AccountManager`; there is no `AccountManagerUidValidityReset` TYPE
/// to cite, in either tree). What matters here is not any single function but the
/// ORDER and the release/abort discipline:
///
///  - the reaction takes **NOTHING from the trigger but the folder**. Every value
///    it acts on — stored epoch, live epoch, quarantine state — is a FRESH read.
///    A stale or racing trigger payload is eliminated by construction rather than
///    validated;
///  - **the durable flag stays SET on every abort leg**, so the folder is
///    retryable, never half-reset. `releaseUidValidityReaction` drops only the
///    in-memory single-flight entry;
///  - **the purge happens BEFORE the stamp**, and a purge that could not run
///    ABORTS (reference commit `cddee072a`, "Make an asset purge that could not
///    run ABORT the UIDVALIDITY reset"). Clearing the flag over undeleted
///    old-epoch FTS rows or body assets would leave no re-drive and no second line
///    of defence against a reused UID serving one message's content as another's;
///  - **`PendingOperation` and `OutboxMessage` rows are NEVER touched by the
///    purge** (Law 5 — the queue row IS the user's intention). `messageAICache` is
///    likewise never touched; resynced rows re-associate through the existing
///    cache-key lookup.
///
/// DELIBERATE OMISSIONS FROM THE REFERENCE, each a decision and not a diff:
///  - the epoch ledger MIRROR (`uidValidityLedgerBox`, `recordObservedUidValidity`,
///    `stampUidValidityLedgerAfterReset`): every v3 consumer holds a `Database` and
///    reads `Folder.lastKnownUidValidity` directly, so there is no synchronous
///    compare that needs a memory-side copy — see `AccountManager
///    .uidValidityChangeHandlerBox`'s doc comment;
///  - `Folder.lastUidValidityResetAt`: its only job in the reference is to be the
///    monotonic authority sidecar producers compare against, and v3 has no such
///    producer (0 references in the tree);
///  - the NSE staging purges (`NSEDataBridge.purgeInboxRemovalMarkersForAccount`,
///    `.purgeStagedStateForFolder`): v3 exposes no per-folder or per-account
///    staging-DB purge, and adding one is a separate item. RESIDUAL, stated: a
///    staged old-epoch row merged after this reaction re-inserts a header the purge
///    removed. It is bounded — the NSE stages only inbox arrivals, and the next
///    ordinary sync pass stale-sweeps a UID the server no longer returns;
///  - `redriveDurableQueue` / `redriveParkedOutboxFlags` / the intention journal
///    barrier: none exist in v3 (its queue is the simpler provider-id action
///    queue). The barrier below uses the v3 write-queue drain instead;
///  - the `ChatIdTranslator` in-memory companion clear and the body queues'
///    oversized-deferred clear: neither `purgeMappingsForFolder` nor
///    `clearOversizedDeferred` exists in v3.
extension AccountManager {

    #if DEBUG
    /// Deterministic injection points that make the reaction's abort legs
    /// PROVABLE. Both sit strictly BETWEEN two steps of one already-armed,
    /// already-drained run, which no other seam can reach. The hook is removed
    /// BEFORE it is awaited, so a re-driven reaction can never consume the same
    /// registration twice.
    enum UidValidityResetCheckpointForTesting: Hashable, Sendable {
        /// After every purge has completed, BEFORE the fresh-epoch stamp: folder
        /// rows are gone, `uidValidityResetPendingAt` is still SET, and
        /// `lastKnownUidValidity` still holds the OLD epoch.
        case afterPurgeBeforeStamp(folderId: String)
        /// After the epoch is stamped and the flag clears, BEFORE the resync:
        /// folder rows are still gone, but the epoch is NEW and the folder no
        /// longer reads as quarantined.
        case afterStampBeforeResync(folderId: String)
    }

    static let uidValidityResetCheckpointHooksForTesting = Mutex<[
        UidValidityResetCheckpointForTesting: @Sendable () async throws -> Void
    ]>([:])

    /// PROPAGATES. A `try?` here would convert an injected failure into an
    /// unexercised cell — the hook's error would vanish and a test's own
    /// simulated mid-checkpoint failure could never be observed. Each call site
    /// catches this and aborts the reaction the SAME way every other step failure
    /// does (log + release + return).
    func runUidValidityResetCheckpointForTesting(
        _ checkpoint: UidValidityResetCheckpointForTesting
    ) async throws {
        let hook = Self.uidValidityResetCheckpointHooksForTesting.withLock {
            $0.removeValue(forKey: checkpoint)
        }
        if let hook {
            try await hook()
        }
    }
    #endif

    /// Entry point. Single-flight per `(accountId, folderPath)`: a trigger arriving
    /// while this folder's reaction is already running is RECORDED, not dropped,
    /// and re-checked at release.
    func runUidValidityResetReaction(accountId: String, folderPath: String) async {
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)

        // Synchronous check-and-insert — no `await` between the check and the
        // insert, so actor reentrancy cannot race it.
        guard uidValidityReactionInFlight.insert(folderId).inserted else {
            uidValidityReactionRecheckRequested.insert(folderId)
            return
        }

        // Lifecycle bracket: the WHOLE reaction runs inside begin/end so a
        // suspension never lands mid-purge-txn. `endBackgroundWork` is dispatched
        // via an unstructured Task — this codebase's established `defer { Task
        // { … } }` idiom for async cleanup in a `defer` — and a few event-loop
        // turns of delay before the quiesce window re-arms is harmless.
        let backgroundWorkLabel = "uidvalidity-reset:\(folderId)"
        await MainActor.run { DatabaseSuspension.shared.beginBackgroundWork(backgroundWorkLabel) }
        defer {
            Task { @MainActor in DatabaseSuspension.shared.endBackgroundWork(backgroundWorkLabel) }
        }

        // IMAP/iCloud only (defensive — the triggers can only fire for these
        // providers; Gmail/Graph never populate `lastKnownUidValidity`).
        guard let account = try? await dbPool.read({ db in try Account.fetchOne(db, key: accountId) }),
              account.provider == .imap || account.provider == .icloud else {
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }
        guard let provider = providers[accountId] as? IMAPProvider else {
            if DebugModeManager.isLoggingEnabled() {
                print("[UIDValidity] no connected IMAP provider for \(accountId.prefix(8)) — cannot react to \(folderId) yet; recomputable, retries on next trigger/re-drive")
            }
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }
        guard let folder = try? await dbPool.read({ db in try Folder.fetchOne(db, key: folderId) }) else {
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }

        // TRIGGER VALIDATION. A folder ALREADY quarantined is unambiguous evidence
        // a reaction is due (a re-drive of an interrupted attempt, or a concurrent
        // trigger already armed it) — always proceed. Otherwise confirm the premise
        // still holds via a FRESH observation before arming the destructive path:
        //  - a NEVER-OBSERVED folder (`lastKnownUidValidity == nil`) has no epoch to
        //    reset FROM, so there is nothing this reaction can be right about. It
        //    REFUSES TO START. ⚑ This leaves the "nil epoch over pre-existing
        //    headers" case open, and porting the reaction does NOT close it — the
        //    reference has the identical refusal and its `recordObservedUidValidity`
        //    stamps a nil row without ever asking whether headers already exist. It
        //    is a separate, documented residual (see `Folder.lastKnownUidValidity`);
        //  - a stored epoch that already AGREES with a fresh live read means the
        //    trigger was stale (already resolved, or a queued refusal that lost the
        //    race) — no-op rather than purging a healthy folder.
        if folder.uidValidityResetPendingAt == nil {
            guard let storedEpoch = folder.lastKnownUidValidity.flatMap({ UInt32(exactly: $0) }) else {
                releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
                return
            }
            guard let liveEpoch = await observeFreshUidValidity(provider: provider, folderPath: folderPath),
                  liveEpoch != storedEpoch else {
                releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
                return
            }
        }

        // Step 1: enter reset state. Authoritative — if this fails to persist, the
        // drain-park and admission guards never arm, so the reaction must not
        // proceed to the purge.
        guard await uidValidityResetArmFlag(folderId: folderId) else {
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }

        // Step 2.5: write barrier — BOUNDED. Never proceed to purge with local
        // writes still queued; a re-drive re-enters here.
        guard await uidValidityResetDrainBounded() else {
            BackgroundSyncLogger.log("[UIDValidity] write barrier exhausted (\(SyncConfig.uidValidityResetBarrierMaxAttempts) attempts) for \(folderId) — aborting this attempt, flag stays set; re-drive will retry")
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }

        // Step 3: the purge transaction.
        guard let purgeResult = await uidValidityResetPurgeTxn(
            accountId: accountId, folderPath: folderPath, folderId: folderId
        ) else {
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }

        // Step 4: out-of-transaction purges, in order and with DIFFERING failure
        // policies. Exactly ONE of them aborts: the FTS purge. Letting step 5 clear
        // the flag over a search index that still answers with old-epoch rows would
        // leave no re-drive, and FTS is the one surface a user can still SEE and act
        // on after the headers are gone. The delivered-notification clear cannot fail
        // (UNUserNotificationCenter's removal API is fire-and-forget) and the
        // orphan-file prune is a best-effort disk sweep on its own schedule.
        //
        // DEVIATION from the reference, deliberate: there the body-asset purge is a
        // THROWING folder-scoped call and aborts like the FTS one. v3 has no
        // folder-scoped variant — only `deleteAllAssets(forHeaderId:)`, which returns
        // BYTES RECLAIMED and swallows its own errors, so 0 means "nothing there" and
        // "it failed" indistinguishably; there is no failure signal to abort on
        // without changing a `BodyAssetStore` the NSE also links. Accepting that is
        // safe HERE and is not a general "every purge must succeed" rule: a surviving
        // manifest row is disk garbage, not a wrong-message hazard. Assets are
        // addressed by ASSET ID from the body HTML, never by headerId, so a new-epoch
        // message that recycles the old UID (and therefore the old headerId) cannot
        // be served an old asset — it references its own. The residue is reclaimed by
        // `pruneOrphanFiles()` and by the next re-drive's manifest query.
        do {
            try await SearchIndex.shared.removeMessagesForFolder(accountId: accountId, folderPath: folderPath)
        } catch {
            BackgroundSyncLogger.log("[UIDValidity] step 4 (FTS purge) failed for \(folderId): \(error) — aborting, flag stays set; re-drive will retry")
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }
        clearDeliveredNotificationsForPurgedMessages(accountId: accountId, messageIds: purgeResult.purgedMessageIds)
        // LAST — a manifest-QUERY delete, never the captured id list: recomputable
        // on a crash re-drive even though the headers are already gone.
        purgeBodyAssetsForFolder(accountId: accountId, folderPath: folderPath)
        BodyAssetStore.pruneOrphanFiles()

        // Display: reload after the purge (rows vanish honestly).
        Task { @MainActor in
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }

        // Connection hygiene — BEFORE the stamp, so no stale pre-reset session
        // outlives the reaction and the fresh observation below comes from a
        // genuinely new connection. `disconnect()` is chosen over `markDirty()`
        // because it AWAITS every folder-pinned and action connection's LOGOUT
        // inline. TWO DOCUMENTED CARVE-OUTS from "provably gone":
        //  1. the IDLE lane — `disconnect()`'s own `stopIdle()` synchronously
        //     cancels the listener task and nils the idle server, but fires the
        //     DONE→LOGOUT handshake on its OWN detached Task. This line returning
        //     proves no further IDLE event can reach any consumer and the slot is
        //     free, NOT that the socket's LOGOUT completed;
        //  2. an in-flight `createFolderConnection` for THIS folder, already past
        //     LOGIN when this runs, survives by design and plants into the pool
        //     AFTER `disconnect()` returned.
        // Neither is consequence-free by accident: step 5's observation below is a
        // FRESH checkout, and the purge has already removed every row a survivor
        // could address.
        //
        // DEVIATION (documented, same as the reference): the "restart IDLE" half is
        // deliberately NOT done inline. The only restart seam is whole-account and
        // `@MainActor`, so calling it here launches an untracked background Task
        // with no lifecycle tie to this reaction. Teardown alone satisfies the
        // correctness half; the restart is picked up by the next ordinary IDLE
        // lifecycle event (foreground, BGAppRefresh, push wakeup, network change).
        // Net effect: this account may poll instead of push for at most one such
        // interval — bounded and self-healing.
        try? await provider.disconnect()

        #if DEBUG
        do {
            try await runUidValidityResetCheckpointForTesting(.afterPurgeBeforeStamp(folderId: folderId))
        } catch {
            BackgroundSyncLogger.log("[UIDValidity] checkpoint (afterPurgeBeforeStamp) hook failed for \(folderId): \(error) — aborting, flag stays set; re-drive will retry")
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }
        #endif

        // Step 5: the fresh-observation stamp — a NON-REFUSING read.
        guard let fresh = await observeFreshUidValidity(provider: provider, folderPath: folderPath) else {
            BackgroundSyncLogger.log("[UIDValidity] could not obtain a fresh observation for \(folderId) after purge — aborting, flag stays set; re-drive will retry")
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }
        guard await uidValidityResetStampFreshEpoch(
            accountId: accountId, folderPath: folderPath, folderId: folderId, fresh: fresh
        ) else {
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }

        #if DEBUG
        do {
            try await runUidValidityResetCheckpointForTesting(.afterStampBeforeResync(folderId: folderId))
        } catch {
            BackgroundSyncLogger.log("[UIDValidity] checkpoint (afterStampBeforeResync) hook failed for \(folderId): \(error) — aborting; the epoch is already stamped (no quarantine remains) but this attempt skips resync")
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }
        #endif

        // Release the single-flight entry HERE — BEFORE the resync. A trigger
        // arriving during step 6 is not "arriving while held": it is a fresh
        // admission, and if it fires it is because the resync's own SELECT noticed
        // a FURTHER epoch change, which deserves its own independent reaction.
        releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)

        // Step 6: resync through the NORMAL sync path.
        await uidValidityResetResyncFolder(
            accountId: accountId, folderPath: folderPath, folderId: folderId, provider: provider
        )
    }

    /// Release the single-flight entry for `folderId`. If a trigger arrived while
    /// held, spawn a FRESH attempt rather than dropping it — the fresh call's own
    /// trigger validation decides whether anything is still warranted, so no
    /// separate "revalidate inline" logic is needed here.
    ///
    /// ⚠ This releases ONLY the in-memory admission gate. The durable
    /// `uidValidityResetPendingAt` flag is deliberately left alone: every caller
    /// below an abort leg depends on it staying SET so the folder is re-driven.
    func releaseUidValidityReaction(accountId: String, folderPath: String, folderId: String) {
        uidValidityReactionInFlight.remove(folderId)
        guard uidValidityReactionRecheckRequested.remove(folderId) != nil else { return }
        Task { await self.runUidValidityResetReaction(accountId: accountId, folderPath: folderPath) }
    }

    /// Non-refusing fresh UIDVALIDITY observation. Primary path is STATUS (no
    /// SELECT). A server that omits UIDVALIDITY from STATUS — SwiftMail only asks
    /// for that attribute on a UIDPLUS server — falls back to a SELECT
    /// (`getUidNextWithEpoch`, side-effect-free beyond the SELECT itself), whose
    /// returned epoch IS the fresh observation. v3's `selectMailboxTracked` carries
    /// no refusal, so unlike the reference this fallback cannot throw
    /// `uidValidityChanged`; there is nothing to catch and re-read.
    func observeFreshUidValidity(provider: IMAPProvider, folderPath: String) async -> UInt32? {
        if let status = try? await provider.folderStatus(path: folderPath),
           let uidValidity = status.uidValidity, uidValidity > 0,
           let value = UInt32(exactly: uidValidity) {
            return value
        }
        guard let result = try? await provider.getUidNextWithEpoch(folder: folderPath) else { return nil }
        return result.observedEpoch
    }

    /// Step 1 — idempotent (re-arming an already-quarantined folder is a no-op
    /// write). The closure returns a `Bool` so a VANISHED `Folder` row is a
    /// distinguishable, reported failure rather than a silent success: nothing
    /// would have been armed, and the caller could not tell.
    func uidValidityResetArmFlag(folderId: String) async -> Bool {
        do {
            let armed = try await dbPool.write { db -> Bool in
                guard var folder = try Folder.fetchOne(db, key: folderId) else { return false }
                guard folder.uidValidityResetPendingAt == nil else { return true }
                folder.uidValidityResetPendingAt = Date()
                try folder.update(db)
                return true
            }
            if !armed {
                BackgroundSyncLogger.log("[UIDValidity] step 1 (arm reset flag): Folder row \(folderId) not found — aborting, re-drive will retry")
            }
            return armed
        } catch {
            BackgroundSyncLogger.log("[UIDValidity] step 1 (arm reset flag) failed for \(folderId): \(error) — aborting, re-drive will retry")
            return false
        }
    }

    /// Step 2.5 — the FIFO write barrier, looped until the local write queue and
    /// the durable-op drain are both quiescent. UNLIKE
    /// `awaitWriteQueueDrainOrTimeout` (which races a wall clock and is ALLOWED to
    /// resume with work still queued), this is bounded by an ITERATION cap and
    /// returns `false` on exhaustion — never "proceed anyway".
    ///
    /// The quiescence read comes FIRST, before the drain barrier is awaited: the
    /// inverse ordering is a self-re-arm bug (see
    /// `AccountManager.pendingQueueIsQuiescentForTesting`'s doc comment).
    func uidValidityResetDrainBounded() async -> Bool {
        for attempt in 0..<SyncConfig.uidValidityResetBarrierMaxAttempts {
            let queueQuiescent = !isDraining && !needsRedrain
            await awaitWriteQueueDrain()
            if queueQuiescent { return true }
            if attempt < SyncConfig.uidValidityResetBarrierMaxAttempts - 1 {
                try? await Task.sleep(nanoseconds: UInt64(SyncConfig.uidValidityResetBarrierPollSeconds * 1_000_000_000))
            }
        }
        return false
    }

    /// Result of the step-3 purge, captured INSIDE the transaction (a consistent
    /// pre-delete read).
    struct UidValidityResetPurgeResult: Sendable {
        /// Provider message ids (UIDs) of every header this folder held — used to
        /// clear already-delivered notifications.
        let purgedMessageIds: [String]
    }

    /// Step 3 — ONE write transaction: (i) pre-delete capture, (ii) `messageHeader`
    /// (explicit — there is no folder→header foreign key; body/references/label
    /// associations cascade off the header), (iii) `pendingRender`, (iv)
    /// `chatIdMapping` (LIKE-escaped prefix plus the colon-hierarchy guard, so a
    /// nested sibling under a ':'-delimiter IMAP server is not swept), (v) the
    /// folder's own sync-state reset.
    ///
    /// ⚑ The quarantine flag stays SET — this is not step 5.
    /// ⚑ `pendingOperation` and `outboxMessage` rows are NEVER touched (Law 5).
    /// ⚑ `messageAICache` is NEVER touched (hard requirement — resynced rows
    ///   re-associate through their existing cache key).
    func uidValidityResetPurgeTxn(
        accountId: String, folderPath: String, folderId: String
    ) async -> UidValidityResetPurgeResult? {
        let chatLikePrefix = MessageIdentity.escapedHeaderIdLikePrefix(accountId: accountId, folderPath: folderPath) + "%"
        let chatRawPrefix = MessageIdentity.headerIdPrefix(accountId: accountId, folderPath: folderPath)
        let chatNoDeeperColonSQL = MessageIdentity.headerIdLikeNoDeeperColonSQLFragment(column: "realId")
        do {
            return try await dbPool.write { db -> UidValidityResetPurgeResult in
                // (i) Pre-delete capture.
                let headers = try MessageHeader.filter(Column("folderId") == folderId).fetchAll(db)
                let purgedMessageIds = headers.map(\.messageId)

                // (ii) messageHeader — explicit delete.
                try MessageHeader.filter(Column("folderId") == folderId).deleteAll(db)

                // (iii) pendingRender.
                try db.execute(
                    sql: "DELETE FROM pendingRender WHERE accountId = ? AND folderPath = ?",
                    arguments: [accountId, folderPath]
                )

                // (iv) chatIdMapping — a stale mapping would resolve a chat pill to
                // a reused UID under the new epoch, i.e. show one message as
                // another.
                try db.execute(
                    sql: "DELETE FROM chatIdMapping WHERE realId LIKE ? ESCAPE '\\' AND \(chatNoDeeperColonSQL)",
                    arguments: [chatLikePrefix, chatRawPrefix]
                )

                // (v) Folder sync-state reset, scoped to THIS folder only.
                // `lastKnownUidValidity` is deliberately left at the OLD value —
                // step 5 owns advancing it, and leaving it here is what makes an
                // abort between the two re-drivable.
                if var folder = try Folder.fetchOne(db, key: folderId) {
                    folder.lastKnownUidNext = nil
                    folder.lastKnownHighestModSeq = nil
                    folder.backfillComplete = false
                    folder.backfillUidCursor = nil
                    folder.backfillPageToken = nil
                    folder.oldestSyncedDate = Date()
                    folder.unreadCount = 0
                    folder.totalCount = 0
                    try folder.update(db)
                }

                return UidValidityResetPurgeResult(purgedMessageIds: purgedMessageIds)
            }
        } catch {
            BackgroundSyncLogger.log("[UIDValidity] step 3 (purge txn) failed for \(folderId): \(error) — aborting, flag stays set, re-drive will retry")
            return nil
        }
    }

    /// Step 4 — body assets, by MANIFEST QUERY rather than by the captured header
    /// ids. Recomputable on a re-drive whose purge transaction found no headers
    /// left to capture.
    func purgeBodyAssetsForFolder(accountId: String, folderPath: String) {
        let victims = BodyAssetStore.allManifestHeaderIds().filter {
            MessageIdentity.headerIdBelongsToFolder($0, accountId: accountId, folderPath: folderPath)
        }
        for headerId in victims {
            _ = BodyAssetStore.deleteAllAssets(forHeaderId: headerId)
        }
    }

    /// Delivered-notification clears for the captured purged message ids.
    func clearDeliveredNotificationsForPurgedMessages(accountId: String, messageIds: [String]) {
        guard !messageIds.isEmpty else { return }
        let identifiers = messageIds.map { EmailNotificationBuilder.identifier(accountId: accountId, messageId: $0) }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Step 5 — the ONE write that stamps the new epoch, exits reset state, and
    /// invalidates this folder's address-only durable intentions. All three land
    /// together or not at all.
    ///
    /// The ordering is the point, and it is the mirror-image trap this whole family
    /// of bugs lives in. If the address-only ops were dropped in a SEPARATE write
    /// AFTER the flag cleared, the drain would be un-parked for the window between
    /// the two commits and could execute a bare UID from the invalidated epoch
    /// against whichever message now occupies it — C3, reintroduced by the fix.
    ///
    /// WHAT SURVIVES AND WHAT DOES NOT (Law 5 / project constraint C5):
    ///  - an op whose `messageIds` carry a durable rfc822 identity SURVIVES
    ///    untouched. `IMAPProvider.idempotentMove` and its siblings resolve a
    ///    non-numeric id by SEARCH, so the user's intention lands on the RIGHT
    ///    message under the new numbering. This is the common case;
    ///    ⚠ SURVIVING THIS SWEEP IS NOT THE SAME AS BEING SAFE TO EXECUTE, and
    ///    reading it that way was a confirmed C3 defect (2026-07-31). "Carries a
    ///    non-numeric id" is a property of the ROW; "resolves by SEARCH" is a
    ///    property of the EXECUTOR, and `.deleteDraft` breaks the correspondence:
    ///    `AccountManager.queueDraftDelete` records `[uid, rfc822]` — the rfc822
    ///    is there for the sync filter — while `executeOperation` passes
    ///    `messageIds.first`, the UID, to `provider.deleteDraft`. Such an op is
    ///    NOT address-only, survives here, and would then execute against a bare
    ///    UID in the discarded numbering. The closure is `PendingOperation
    ///    .observedUidValidity`, compared in `AccountManager.drainPendingQueue`'s
    ///    claim transaction — a per-op record of the epoch it was recorded under,
    ///    which cannot be defeated by a future op shape this classifier misreads;
    ///  - an op every one of whose `messageIds` is a BARE NUMERIC UID has no
    ///    identity beyond an ADDRESS in a numbering the server has just discarded.
    ///    Executing it would mutate an unrelated message. C5 states that dropping
    ///    intention at an identity-reset boundary is correct — sync reconciles and
    ///    the user redoes it — and it is the only alternative to a C3 violation or
    ///    a permanent park;
    ///  - ops for ANY OTHER folder are never considered.
    ///
    /// The write closure returns a `Bool` so a vanished `Folder` row stays a
    /// distinguishable failure. A nil pending flag is the idempotent re-drive
    /// window where a previous attempt already stamped: succeed only when the
    /// durable epoch already equals `fresh`.
    func uidValidityResetStampFreshEpoch(
        accountId: String, folderPath: String, folderId: String, fresh: UInt32
    ) async -> Bool {
        do {
            let stamped = try await dbPool.write { db -> Bool in
                guard var folder = try Folder.fetchOne(db, key: folderId) else { return false }
                guard folder.uidValidityResetPendingAt != nil else {
                    return folder.lastKnownUidValidity == Int(fresh)
                }
                let ops = try PendingOperation
                    .filter(Column("accountId") == accountId && Column("folderPath") == folderPath)
                    .fetchAll(db)
                for op in ops where Self.opIsAddressOnly(op) {
                    _ = try PendingOperation.deleteOne(db, key: op.id)
                    BackgroundSyncLogger.log("[UIDValidity] dropped address-only op \(op.type.rawValue) \(op.id.prefix(8)) on \(folderId) — its UIDs belong to the epoch the server discarded (C5)")
                }
                folder.lastKnownUidValidity = Int(fresh)
                folder.uidValidityResetPendingAt = nil
                try folder.update(db)
                return true
            }
            if !stamped {
                BackgroundSyncLogger.log("[UIDValidity] step 5 (stamp fresh epoch): Folder row \(folderId) vanished or disagreed with the fresh epoch — aborting; re-drive will retry")
            }
            return stamped
        } catch {
            BackgroundSyncLogger.log("[UIDValidity] step 5 (stamp fresh epoch, clear flag) failed for \(folderId): \(error) — aborting, flag stays set, re-drive will retry")
            return false
        }
    }

    /// True when EVERY id this op targets is a bare numeric UID — i.e. the op
    /// carries no durable identity that could be re-resolved under a new epoch.
    ///
    /// The discriminator mirrors `MessageHeader.stableId`, which is what the
    /// admission sites store: an rfc822 Message-ID when one exists, the raw UID
    /// otherwise. An op with NO ids at all is not address-only — there is nothing
    /// to be wrong about, and deleting it would drop intention for free.
    nonisolated static func opIsAddressOnly(_ op: PendingOperation) -> Bool {
        let ids = op.messageIds
        guard !ids.isEmpty else { return false }
        return ids.allSatisfy { UInt32($0) != nil }
    }

    /// Step 6 — the identical code path account-add uses for a folder's initial
    /// sync. A further epoch change during this call is caught by the next pass's
    /// own guard and re-triggers on its own.
    func uidValidityResetResyncFolder(
        accountId: String, folderPath: String, folderId: String, provider: IMAPProvider
    ) async {
        if let folder = try? await dbPool.read({ db in try Folder.fetchOne(db, key: folderId) }) {
            do {
                try await syncEngine.syncFolderMessages(folder: folder, provider: provider)
            } catch {
                BackgroundSyncLogger.log("[UIDValidity] step 6 resync for \(folderId) ended with: \(error) (a further epoch change re-triggers on the next pass's own guard)")
            }
        }
        await UnreadCountManager.shared.requestRecount(folderId: folderId, notifyImmediately: true)
        Task { @MainActor in
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
    }
}
