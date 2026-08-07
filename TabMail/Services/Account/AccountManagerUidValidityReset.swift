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
///  - `redriveDurableQueue` / `redriveParkedOutboxFlags` / the intention journal
///    barrier: none exist in v3 (its queue is the simpler provider-id action
///    queue). The barrier below uses the v3 write-queue drain instead.
///
/// LANDED AFTER THE PORT (T4.S4 / T4.V11), each previously listed above as an
/// omission and now present:
///  - the NSE staging purges (`NSEDataBridge.purgeStagedStateForFolder`,
///    `.purgeInboxRemovalMarkersForAccount`). Both REPORT whether they committed and
///    both ABORT the reaction when they did not (audit round 1 / C-4). They were
///    documented here as BEST-EFFORT — "neither may abort" — on the premise that a
///    missed staged row degrades to "the next ordinary sync pass stale-sweeps a UID
///    the server no longer returns". That premise does not hold for the only event
///    this function reacts to: the new epoch RE-ISSUES the same UIDs and returns
///    them, so a surviving old-epoch instruction is executed against the new epoch's
///    occupant (populate/update, or an `nse_inbox_removal` DELETE). The corrected
///    rule is at the step-4 comment;
///  - the `ChatIdTranslator` companion purge
///    (`ChatIdTranslator.purgeMappingsForFolder`), which pairs with — and does not
///    replace — the `chatIdMapping` DELETE already inside the step-3 transaction;
///  - the body queues' oversized-deferred RELEASE
///    (`ActiveBodyQueue`/`BackfillBodyQueue.clearOversizedDeferred`). Both methods
///    now exist in v3, and this reaction is their ONLY caller: without it the
///    oversized quarantine never lifts for a renumbered folder, which turns a
///    bounded, retryable deferral into a permanent discard — the thing the absolute
///    rule forbids. Best-effort like the NSE purges, and for a stronger reason: they
///    release a deferral rather than delete anything.
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
        // Read from the SAME snapshot the validation above used, before anything
        // this reaction does can change it. Consumed by the `nse_inbox_removal`
        // purge, which is account-wide and therefore inbox-role-only.
        let isInboxRole = folder.role == .inbox

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

        // Step 3b — the COMPANION to step 3's `chatIdMapping` DELETE, not a
        // replacement for it. That statement matches by the exact
        // `messageHeader.folderId` relation INSIDE the transaction, which by
        // construction cannot see a mapping whose header row was already gone; this
        // one matches by the composite `accountId:folderPath:` prefix over the
        // translator's own (DB-superset) map, and drops the in-memory pill caches so
        // nothing serves impostor content from memory either. Porting only one half
        // leaves the other's misses behind.
        await ChatIdTranslator.shared.purgeMappingsForFolder(accountId: accountId, folderPath: folderPath)

        // Step 3c — `nse_inbox_removal` is (account, UID)-keyed with NO folderPath
        // column, so it can only be purged account-wide, and is therefore purged ONLY
        // when the folder being reset IS this account's inbox-role folder: for any
        // other folder's reset these markers are not ours to delete. Adjacent to (not
        // inside) the transaction above — the staging DB is a separate file.
        //
        // 🚨 ABORTS ON FAILURE (audit round 1 / C-4). A surviving marker is an
        // executable DELETE naming a bare UID in the numbering the server just
        // discarded. If this reaction went on to stamp E2 and clear the quarantine,
        // step 6's resync would seat a DIFFERENT message at that reused UID and the
        // next NSE merge would delete it — the wrong message, destroyed. So the
        // durable epoch is NOT advanced over a purge whose result is unknown: the
        // flag stays set, the folder stays quarantined and retryable, and the
        // re-drive tries again. See the failure-policy paragraph at step 4.
        if isInboxRole,
           !NSEDataBridge.purgeInboxRemovalMarkersForAccount(accountId: accountId) {
            BackgroundSyncLogger.log("[UIDValidity] step 3c (NSE inbox-removal purge) could not commit for \(folderId) — aborting, flag stays set; re-drive will retry")
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }

        // Step 4: out-of-transaction purges, in order and with DIFFERING failure
        // policies. The ones that ABORT are the FTS purge and the two NSE staging
        // purges (this one and step 3c's). The delivered-notification clear cannot
        // fail (UNUserNotificationCenter's removal API is fire-and-forget) and the
        // orphan-file prune is a best-effort disk sweep on its own schedule.
        //
        // FTS: letting step 5 clear the flag over a search index that still answers
        // with old-epoch rows would leave no re-drive, and FTS is the one surface a
        // user can still SEE and act on after the headers are gone.
        //
        // 🚨 NSE STAGING (audit round 1 / C-4 — THIS POLICY WAS REVERSED). The text
        // that stood here called the staging purge non-aborting "deliberately rather
        // than by omission", on the grounds that a missed staged row degrades to an
        // already-accepted residual because "the next ordinary sync pass stale-sweeps
        // a UID the server no longer returns". THAT PREMISE IS FALSE FOR A UIDVALIDITY
        // TURNOVER, which is the only situation this function runs in: the new epoch
        // re-issues the same UID space and legitimately RETURNS those UIDs, so the
        // stale-sweep never fires. A surviving old-epoch instruction is then executed
        // against a NEW-epoch occupant — an `nse_processed_message` row re-populates
        // or updates it, and an `nse_inbox_removal` marker DELETES it. Both are C3
        // wrong-message mutations, and the deletion is unrecoverable.
        //
        // The rule this now follows: once E1→E2 has been detected, no E1 staging
        // instruction may reach an E2 occupant. The reaction guarantees that by
        // refusing to CREATE an E2 occupant while any such instruction may survive —
        // it does not stamp the fresh epoch, does not clear the quarantine, and does
        // not resync. Quarantine is bounded, visible and retryable; a deleted message
        // is not. The cost of the trade (a folder that stays quarantined with its
        // rows already purged while the staging DB is unwritable) is the same cost
        // the FTS abort leg has always accepted.
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
        guard NSEDataBridge.purgeStagedStateForFolder(accountId: accountId, folderPath: folderPath) else {
            BackgroundSyncLogger.log("[UIDValidity] step 4 (NSE staged-state purge) could not commit for \(folderId) — aborting, flag stays set; re-drive will retry")
            releaseUidValidityReaction(accountId: accountId, folderPath: folderPath, folderId: folderId)
            return
        }
        clearDeliveredNotificationsForPurgedMessages(accountId: accountId, messageIds: purgeResult.purgedMessageIds)
        // LAST — a manifest-QUERY delete, never the captured id list: recomputable
        // on a crash re-drive even though the headers are already gone.
        purgeBodyAssetsForFolder(accountId: accountId, folderPath: folderPath)
        BodyAssetStore.pruneOrphanFiles()

        // Step 4b — RELEASE the body queues' oversized quarantine for this folder.
        // PORTED from the reference, which calls the same two methods from this same
        // step ("post-purge, pre-resync").
        //
        // ⚠ WITHOUT THIS THE QUARANTINE IS A PERMANENT DISCARD BY ANOTHER NAME, which
        // the absolute rule forbids. Both sets key by headerId —
        // `accountId:folderPath:UID`, a mutable ADDRESS. A UIDVALIDITY turnover
        // renumbers the mailbox, so step 6's resync inserts fresh-epoch rows that MAY
        // reuse a deferred header's UID; the stale key then makes `admit()` reject a
        // message that was never oversized, starving it of its body until relaunch.
        // The renumber is precisely the moment the deferral stops being about the
        // message it was recorded for, so it is the correct invalidation point.
        //
        // PLACED HERE, at the END of step 4, rather than at the reference's exact line:
        // every abort-capable purge above has already succeeded, so a release can no
        // longer be spent on a reaction that goes on to abort. That is the reference's
        // STATED intent ("post-purge") rather than its literal position, and it keeps
        // the one ordering rule this function has — purge first, stamp last.
        //
        // BEST-EFFORT, like the NSE staging purges and for a stronger reason: these
        // calls RELEASE a deferral, they never delete user data. Both are non-throwing,
        // so there is no failure to abort on; the worst case of a release that turns out
        // to be premature is one extra fetch attempt that fails identically and
        // re-quarantines. Their own generation guard closes the converse race — a batch
        // that captured the pre-clear generation cannot re-quarantine a renumbered UID
        // after the clear.
        await ActiveBodyQueue.shared.clearOversizedDeferred(accountId: accountId, folderPath: folderPath)
        await BackfillBodyQueue.shared.clearOversizedDeferred(accountId: accountId, folderPath: folderPath)

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

    /// Step 3 — ONE write transaction: (i) pre-delete capture, (ii) exact relational
    /// deletion of the folder's `messageBody` and `chatIdMapping` sidecars, (iii)
    /// `messageHeader` (explicit — there is no folder→header foreign key;
    /// references/label associations cascade off the header), (iv) `pendingRender`,
    /// (v) the folder's own sync-state reset.
    ///
    /// The sidecars are deleted BEFORE their owning headers, using the exact
    /// `messageHeader.folderId` relation inside this same transaction. This avoids
    /// both the colon-tail/child-folder ambiguity of a composite-id prefix and the
    /// quarantine no-op that routing bodies through `MessageContentStore` would
    /// create here. `ContentKey.forHeader` is byte-identical to `MessageHeader.id`
    /// at the current stage; the later content-key mint owns revisiting this site.
    ///
    /// ⚑ The quarantine flag stays SET — this is not step 5.
    /// ⚑ `pendingOperation` and `outboxMessage` rows are NEVER touched (Law 5).
    /// ⚑ `messageAICache` is NEVER touched (hard requirement — resynced rows
    ///   re-associate through their existing cache key).
    func uidValidityResetPurgeTxn(
        accountId: String, folderPath: String, folderId: String
    ) async -> UidValidityResetPurgeResult? {
        do {
            return try await dbPool.write { db -> UidValidityResetPurgeResult in
                // (i) Pre-delete capture.
                //
                // ⚑ ONE COLUMN, NOT 48. Only `messageId` is consumed, and this runs
                // INSIDE the write transaction — so materializing every column of
                // every row in the folder holds SQLite's single writer for the whole
                // decode. A `UIDVALIDITY` reset purges an ENTIRE folder, which is the
                // largest row set this app ever deletes at once, so the row width is
                // paid at the worst possible cardinality. Precedent for the shape:
                // `SyncEngine`'s
                // `MessageHeader.select(Column("messageId")).filter(Column("folderId") == folderId)`.
                let purgedMessageIds = try String.fetchAll(
                    db,
                    MessageHeader.select(Column("messageId")).filter(Column("folderId") == folderId)
                )

                // (ii) Sidecars — exact relational ownership, while the owning
                // headers still exist. The subqueries avoid a parameter-count cap.
                // ⚑ NO REFERENCE — INVENTED: v2final has no explicit body delete
                // (its FK cascaded) and prefix-deletes chat mappings instead.
                try db.execute(
                    sql: """
                        DELETE FROM messageBody
                        WHERE id IN (SELECT id FROM messageHeader WHERE folderId = ?)
                        """,
                    arguments: [folderId]
                )
                try db.execute(
                    sql: """
                        DELETE FROM chatIdMapping
                        WHERE realId IN (SELECT id FROM messageHeader WHERE folderId = ?)
                        """,
                    arguments: [folderId]
                )

                // (iii) messageHeader — explicit delete.
                try MessageHeader.filter(Column("folderId") == folderId).deleteAll(db)

                // (iv) pendingRender.
                try db.execute(
                    sql: "DELETE FROM pendingRender WHERE accountId = ? AND folderPath = ?",
                    arguments: [accountId, folderPath]
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
        // Folder scoping works on the key's PREFIX (`accountId:folderPath:`), which is
        // unchanged by where the tail comes from — so this filter stays correct at E1.
        let victims = BodyAssetStore.allManifestContentKeys().filter {
            MessageIdentity.headerIdBelongsToFolder($0.rawValue, accountId: accountId, folderPath: folderPath)
        }
        for contentKey in victims {
            _ = BodyAssetStore.deleteAllAssets(forContentKey: contentKey)
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
    ///  - a legacy op whose `messageIds` carry an RFC identity may survive this
    ///    address-only classifier, but it is not executable mutation authority:
    ///    Checkpoint A drops unstamped or stale IMAP action rows before provider
    ///    I/O. No action executor resolves it by SEARCH;
    ///    ⚠ SURVIVING THIS SWEEP IS NOT THE SAME AS BEING SAFE TO EXECUTE, and
    ///    reading it that way was a confirmed C3 defect (2026-07-31). "Carries a
    ///    non-numeric id" is a property of the ROW, not authority. `.deleteDraft`
    ///    also needs its typed address/identity bundle, and `executeOperation`
    ///    used to pass `messageIds.first`, the UID, alone to
    ///    `provider.deleteDraft` — which would execute against a bare UID in the
    ///    discarded numbering.
    ///    ⚠ CORRECTED 2026-08-05 — this used to say *"`queueDraftDelete` records
    ///    `[uid, rfc822]` … such an op is NOT address-only, survives here"*. It
    ///    does not and it is not. The producer inserts a ONE-element
    ///    `messageIds: [encodedId]`, and on the `.imap` arm `encodedId` is
    ///    `String(uid)` — a canonical bare UID. So `opIsAddressOnly` returns
    ///    TRUE for an IMAP `.deleteDraft` op and, once `opIsProvenInvalidatedByReset`'s
    ///    second conjunct also holds (the op recorded a positive
    ///    `observedUidValidity` that disagrees with `fresh`), the op **IS swept
    ///    here** rather than surviving. The drift was in the safe direction — the
    ///    op is dropped at the reset boundary, which is exit 4 and correct — but
    ///    a reviewer who trusted the old sentence would conclude `.deleteDraft`
    ///    ops reach the executor after a reset, and design the next guard for a
    ///    population that does not exist.
    ///    The closure is `PendingOperation.observedUidValidity`, compared in
    ///    `AccountManager.drainPendingQueue`'s claim transaction — a per-op record
    ///    of the epoch it was recorded under, which cannot be defeated by a future
    ///    op shape this classifier misreads.
    ///    ⚑ UPDATE (2026-08-01, CORRECTED R14-F7): the EXECUTOR half is closed too —
    ///    `IMAPProvider.deleteDraft` resolves the draft by the UID carried in its
    ///    typed identity, inside a SELECT whose live UIDVALIDITY equals the epoch
    ///    the op recorded its UID as MINTED under
    ///    (`PendingOperation.draftServerUidValidity`, v72). A bare UID with no
    ///    recorded epoch is refused outright, so no numbering is ever assumed.
    ///    ⚠ **THERE IS NO RFC LEG, and this sentence claimed one.** It read
    ///    *"resolves EITHER by a wire-verified rfc822 Message-ID OR … by that UID"*.
    ///    `IMAPProvider.deleteDraft` opens with
    ///    `guard case .imap(let folder, let uidValidity, let uid) = identity` and
    ///    throws `actionIdentityResolutionFailed` on anything else — that guard is
    ///    the whole of its identity handling — and `DraftDeleteIdentity` has no
    ///    RFC-bearing case at all (`gmail`, `gmailContainedMessage`, `outlook`,
    ///    `imap`, `demo`). `deleteDraftStrong`'s own doc states the subtraction
    ///    outright: it "omit[s] optional RFC corroboration because v3's typed
    ///    identity has no RFC leg". A reader who trusted the old sentence would
    ///    believe a second, CONTENT-named route exists beside the address-named one
    ///    and would design the next guard around a fallback that is not there —
    ///    which is the same failure mode as the corrected sentence two paragraphs
    ///    up. The stamp stays: it is provider-agnostic and stops the op before it
    ///    reaches any executor;
    ///  - an op every one of whose `messageIds` is a CANONICAL BARE UID **and whose
    ///    own recorded `observedUidValidity` is a positive epoch that DISAGREES
    ///    with the fresh one** has no identity beyond an ADDRESS in a numbering the
    ///    server has demonstrably discarded. Executing it would mutate an unrelated
    ///    message. C5 states that dropping intention at an identity-reset boundary
    ///    is correct — sync reconciles and the user redoes it — and it is the only
    ///    alternative to a C3 violation or a permanent park.
    ///    ⚠ BOTH CONJUNCTS ARE REQUIRED (audit round 2). This used to delete on the
    ///    id SHAPE alone, so an op with NO recorded epoch — an absence of evidence —
    ///    was destroyed as though a turnover had been proven for it. See
    ///    `opIsProvenInvalidatedByReset`, which is now the only predicate allowed to
    ///    authorize a deletion here, and which states why refusing more cannot stall
    ///    the reaction;
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
                for op in ops where Self.opIsProvenInvalidatedByReset(op, fresh: fresh) {
                    _ = try PendingOperation.deleteOne(db, key: op.id)
                    BackgroundSyncLogger.log("[UIDValidity] dropped address-only op \(op.type.rawValue) \(op.id.prefix(8)) on \(folderId) — recorded under UIDVALIDITY \(op.observedUidValidity.map(String.init) ?? "?"), server now \(fresh); its UIDs belong to the epoch the server discarded (exit 4)")
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

    /// True when EVERY id this op targets is a CANONICAL, non-zero bare UID — i.e.
    /// the op carries no durable identity that could be re-resolved under a new
    /// epoch.
    ///
    /// An op with NO ids at all is not address-only — there is nothing to be wrong
    /// about, and deleting it would drop intention for free.
    ///
    /// ⚠️ THIS PARAGRAPH USED TO READ *"The discriminator mirrors
    /// `MessageHeader.stableId`, which is what the admission sites store: an rfc822
    /// Message-ID when one exists, the raw UID otherwise"* — **describing a regime
    /// that was WITHDRAWN** (R16-7, corrected 2026-08-06). It is dangerous
    /// specifically because `stableId` the property still has that RFC-first shape,
    /// so the sentence reads as verifiable while the thing it describes — RFC as a
    /// live durable action key — is gone. ADR-IOS-068/D4 removed RFC as mutation
    /// authority; the drain's Checkpoint A refuses to CLAIM any IMAP non-draft op
    /// unless `idsAreCanonicalUIDs` holds, i.e. every id is a canonical non-zero
    /// bare UID. So the ops this predicate can ever see on IMAP already carry bare
    /// UIDs, and the discriminator's real job is to separate an ADDRESS from
    /// everything that is not one — draft UUIDs, encoded composite ids, `"0"`,
    /// `"001"` — not to pick the raw-UID branch of a two-branch admission format.
    ///
    /// THE ONE PLACE AN rfc822 id STILL REACHES `PendingOperation`, named so this
    /// correction does not read as "RFC ids no longer exist": the ReplyDetect
    /// `reply→none` producers, all of type `.setTag`. Predicate, comments excluded:
    ///   `rg -n --pcre2 '^(?!\s*(///|//)).*messageIds: \[\w+\.stableId\]'
    ///    TabMail/ Shared/ TabMailNotificationService/` → **7**
    ///   (`SyncEngine`, `SyncEngineFullSync` ×2, `SyncEngineDeltaSync` ×2,
    ///   `SyncEngineBackfillDeep`, `AccountManagerOutbox`).
    /// `.setTag` is DELIBERATELY absent from Checkpoint A's `nonDraftTypes` for
    /// exactly this reason — see the comment above that set: adding it would make
    /// all seven a deterministic IMAP drop, and leaving them in while the exit-4 arm
    /// stopped deleting would accumulate unclaimable rows forever. Neither happens.
    ///
    /// ⚠ SHAPE ONLY — NOT AUTHORITY TO RETIRE. This answers "could these ids mean
    /// anything under a different numbering?", which is a necessary condition and
    /// not a sufficient one. The sufficient one is
    /// `opIsProvenInvalidatedByReset(_:fresh:)`; call that, not this.
    ///
    /// ⚠ CANONICAL AND NON-ZERO (audit round 2). `UInt32(id) != nil` alone accepted
    /// `"0"` — which RFC 3501 §2.3.1.1 types as impossible, so it is a malformed id,
    /// not a UID in the discarded epoch — and `"001"`, which no admission site ever
    /// writes and which therefore came from somewhere unaccounted for. Both are
    /// unknowns, and an unknown may never authorize destroying a user intention.
    /// Same predicate the drain's checkpoint A uses (`idsAreCanonicalUIDs`).
    nonisolated static func opIsAddressOnly(_ op: PendingOperation) -> Bool {
        let ids = op.messageIds
        guard !ids.isEmpty else { return false }
        return ids.allSatisfy { id in
            guard let uid = UInt32(id), uid > 0 else { return false }
            return id == String(uid)
        }
    }

    /// 🚨 THE ONLY PREDICATE THAT MAY RETIRE AN OP AT A RESET BOUNDARY.
    ///
    /// Exit 4 of `Companion/Rules/Active/never-drop-user-intention.md` — invalidation
    /// by a PROVEN id reset in the operation's OWN source address space — and it
    /// demands the same positive proof everywhere it is claimed: **two positive,
    /// non-zero epochs that disagree**. The op's own recorded
    /// `observedUidValidity` is one; the epoch the server just reported is the
    /// other. Missing, zero, non-canonical or unreadable on either side ⇒ `false` ⇒
    /// the op stays durably queued.
    ///
    /// ⚠ AUDIT ROUND 2. The sweep used to delete on `opIsAddressOnly` ALONE — on the
    /// SHAPE of the ids, never comparing the op's own epoch at all. So a legacy op
    /// with `observedUidValidity == nil` was destroyed on an ABSENCE of evidence:
    /// the one conflation this codebase's history says is its most repeated defect,
    /// sitting inside the very reaction whose normative document asserts the
    /// closure. Exit 4 fires on a POSITIVE fact; clause 2's *unknown* epoch is its
    /// opposite and stays retryable forever. The two are disjoint and nothing may
    /// blur them.
    ///
    /// ⚠ THE OPPOSITE FAILURE — "now nothing is ever retired and the reaction cannot
    /// converge" — is NOT reachable here, and this is why:
    ///  - the sweep is not load-bearing for convergence.
    ///    `uidValidityResetStampFreshEpoch` writes `lastKnownUidValidity = fresh`
    ///    and clears `uidValidityResetPendingAt` UNCONDITIONALLY after the loop, and
    ///    returns `true` on that, not on how many rows it deleted. A reaction that
    ///    sweeps nothing still stamps, still unquarantines, still resyncs;
    ///  - a provably-stale op is still retired, one step later. Once the fresh epoch
    ///    is stamped, the drain's checkpoint A sees `stamped != live` in its claim
    ///    transaction and takes exit 4 there, BEFORE any provider I/O. The queue
    ///    converges whether or not this sweep ran;
    ///  - an op this predicate refuses is one checkpoint A also refuses to claim, so
    ///    it never reaches an executor and can never mutate a message under a
    ///    numbering it did not observe. It parks — unclaimable, visible in
    ///    `[QueueDiag]`, costing nothing but a row. That is the accepted
    ///    `IOS-EPOCH-001` posture, not a livelock: nothing retries it, nothing
    ///    spins, and the reaction never waits on it.
    nonisolated static func opIsProvenInvalidatedByReset(
        _ op: PendingOperation, fresh: UInt32
    ) -> Bool {
        guard opIsAddressOnly(op) else { return false }
        guard fresh > 0 else { return false }
        guard let recorded = op.observedUidValidity,
              let recordedUInt = UInt32(exactly: recorded), recordedUInt > 0 else { return false }
        return recordedUInt != fresh
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
