/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import UIKit

actor SyncEngine {
    private(set) var providers: [String: any EmailProvider] = [:]
    private(set) var workQueues: [String: ProviderWorkQueue] = [:]

    /// Roles to sync messages for (inbox gets most, others get fewer)
    let primaryRoles: Set<FolderRole> = [.inbox]
    let secondaryRoles: Set<FolderRole> = [.sent, .drafts, .trash, .archive, .spam]

    var headerBackfillTasks: [String: Task<Void, Never>] = [:]

    /// Cached server-reported total message count for Gmail/Exchange accounts.
    /// Used as progress denominator instead of FTS row count (which grows with crawl).
    var serverMessageTotal: [String: Int] = [:]

    /// Generation counter per account — prevents stale task defer from clearing
    /// a replacement task's dictionary entry after resetCrawlState.
    var backfillGeneration: [String: Int] = [:]

    /// FTS bulk-indexing tasks, keyed by account ID (one per account).
    var bulkIndexTasks: [String: Task<Void, Never>] = [:]

    /// In-flight guard for the one-time FTS reconciliation. `syncStartup` can
    /// spawn multiple +5s heal tasks (foreground return, push, BGRefresh) and
    /// the UserDefaults gate is only written on completion, so two overlapping
    /// reconciliations were possible — idempotent but wasteful. Actor-isolated;
    /// the check-and-set in `oneTimeFTSReconciliation` is synchronous (no
    /// suspension point), so it is race-free under actor reentrancy.
    var ftsReconcileInFlight = false

    /// Folder ids with a deletion-reconcile walk in flight (ADR-IOS-051).
    /// Prevents overlapping walks for the same folder when full sync and a
    /// delta poll both trip the count-mismatch trigger on a slow server.
    /// Actor-isolated; the check-and-insert in
    /// `reconcileExternallyDeletedMessages` is synchronous, so it is
    /// race-free under actor reentrancy. Duplicate walks would be idempotent
    /// (delete-twice is a no-op) but waste a full-folder SEARCH pass.
    var deletionReconcileInFlight: Set<String> = []

    /// Embedding rebuild task (one at a time).

    /// One-shot flag so the `recoverIncompleteHeaders` EXPLAIN QUERY PLAN probe
    /// only logs once per process lifetime. Diagnosing the persistent 3-5s cost
    /// we see even when the query returns 0 rows.
    var recoverIncompleteExplainLogged = false

    /// GRDB DatabasePool for foreground SYNC — full / delta / pull-down / on-demand /
    /// pagination — at `.normal` (`AppDatabase.syncPool`), so it beats the deep
    /// background FILLING queues in `DatabaseWriteQueue` but still yields to the merge
    /// and to a live user action (`.priority`). `.normal` comes from the POOL (not a
    /// `PriorityGate.normal { }` override), so it survives the `Task.detached` the
    /// per-folder fullSync writes run in. Backfill / FTS self-heal / maintenance write
    /// via `AppDatabase.backgroundPool` directly (`.background`).
    ///
    /// ⚑ HOW THE MAINTENANCE HALF OF THAT SENTENCE IS TRUE, since it is not a property
    /// this file can enforce: `runWALMaintenance` takes its pool as a PARAMETER, so the
    /// tier is whatever each CALLER hands it. It holds because both production callers
    /// name `AppDatabase.backgroundPool` — `scheduleMaintenanceInBackground` (the
    /// foreground poll) and `SyncScheduler`'s `.full` BGProcessing drain. It was FALSE
    /// until 2026-08-05, when the BGProcessing caller still passed `AppDatabase.dbPool`
    /// (the default `.priority` tier) and the pass's trailing whole-database `ANALYZE`
    /// could therefore take SQLite's single writer ahead of a queued user action.
    /// A third caller re-breaks it silently, so the property is pinned at the call
    /// sites by `everyWALMaintenanceCallSitePassesABackgroundPool`, not here.
    var dbPool: PrioritizedDatabase { AppDatabase.syncPool }

    /// Read current fast sync mode state from AccountManager (MainActor hop).
    func getIsFastSync() async -> Bool {
        await MainActor.run { AccountManagerState.shared.fastSyncModeActive }
    }

    /// Compute current backfill profile from device power state.
    /// Four tiers:
    ///   .turbo      — user-triggered fast sync. Max throughput, UI may lag.
    ///   .aggressive — plugged in. Full throughput, UI stays responsive (priority lock).
    ///   .normal     — on battery. Moderate progress, reasonable drain.
    ///   .low        — thermal throttling. Minimal resource usage.
    /// Note: Low Power Mode and battery < 20% pause backfill entirely (getShouldPauseBackfill).
    /// Reads UIDevice state via MainActor hop — always returns latest power state.
    func getBackfillProfile() async -> BackfillProfile {
        await MainActor.run {
            let isFastSync = AccountManagerState.shared.fastSyncModeActive
            if isFastSync { return .turbo }
            let isOnPower = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
            let isThermallyThrottled = ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.thermalState == .serious
            if isOnPower && !isThermallyThrottled {
                return .aggressive
            }
            if isThermallyThrottled {
                return .low
            }
            return .normal
        }
    }

    /// Whether backfill should be paused entirely.
    /// Pauses when: battery < 20% (not charging), or Low Power Mode enabled.
    /// Fast sync mode bypasses this gate entirely.
    /// Reads UIDevice state via MainActor hop.
    func getShouldPauseBackfill() async -> Bool {
        await MainActor.run {
            let isFastSync = AccountManagerState.shared.fastSyncModeActive
            if isFastSync { return false }
            let isOnPower = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
            if ProcessInfo.processInfo.isLowPowerModeEnabled && !isOnPower { return true }
            let level = UIDevice.current.batteryLevel
            // batteryLevel returns -1 if monitoring not enabled (shouldn't happen — set in TabMailApp.init)
            return !isOnPower && level >= 0 && level < 0.20
        }
    }

    func register(accountId: String, provider: any EmailProvider, workQueue: ProviderWorkQueue) {
        providers[accountId] = provider
        workQueues[accountId] = workQueue
    }

    /// Cancel all FTS-related tasks across all accounts. Called before index rebuild
    /// to prevent stale tasks from blocking new bulk index via the per-account guard.
    func cancelAllFTSTasks() {
        for (_, task) in bulkIndexTasks { task.cancel() }
        bulkIndexTasks.removeAll()
        // Also cancel backfill workers since they write to FTS
        for (_, task) in headerBackfillTasks { task.cancel() }
        headerBackfillTasks.removeAll()
    }

    /// Reset backfill state for a single account (e.g., Settings reset).
    /// Cancels the worker and clears completion flag so backfill re-launches.
    func resetBackfill(accountId: String) {
        headerBackfillTasks[accountId]?.cancel()
        headerBackfillTasks.removeValue(forKey: accountId)
    }

    func remove(accountId: String) async {
        providers.removeValue(forKey: accountId)
        workQueues.removeValue(forKey: accountId)

        // Cancel and await background tasks to ensure no stale references remain active
        if let backfillTask = headerBackfillTasks.removeValue(forKey: accountId) {
            backfillTask.cancel()
            await backfillTask.value // wait for cancellation to propagate
        }
        if let indexTask = bulkIndexTasks.removeValue(forKey: accountId) {
            indexTask.cancel()
            await indexTask.value // wait for cancellation to propagate
        }
    }

    // MARK: - Background Maintenance

    private var maintenanceTask: Task<Void, Never>?

    /// Run evict/purge/prune off the main thread. These use synchronous GRDB
    /// operations that would block the main actor if called inline.
    /// Captures all MainActor-isolated state before detaching.
    /// Foreground maintenance pass — runs BOTH the WAL housekeeping (storage prune,
    /// body-TTL evict, AI-cache purge, chat-session evict) and the NON-WAL
    /// BodyAssetStore housekeeping (attachment evict + orphan sweep). Triggered once
    /// per foreground poll. Off the main thread (these are synchronous GRDB calls).
    ///
    /// The two halves have OPPOSITE background safety, so they are split and gated
    /// differently (see `runWALMaintenance` / `runBodyAssetMaintenance`):
    /// - WAL steps abort benignly under suspension → may run anywhere; the `.full`
    ///   BGProcessing drain calls `runWALMaintenance` directly.
    /// - BodyAssetStore steps read a NON-WAL App-Group `DatabaseQueue` whose read lock
    ///   cannot be aborted at process suspension (`0xdead10cc`) → foreground-only.
    /// See ADR-IOS-046.
    func scheduleMaintenanceInBackground(includePrune: Bool = false) {
        maintenanceTask?.cancel()
        let pool = AppDatabase.backgroundPool
        maintenanceTask = Task.detached(priority: .utility) {
            // Capture undo-protected IDs via MainActor hop (UndoService is @MainActor)
            let undoProtectedBodyIds = await MainActor.run {
                Set(UndoService.shared.undoStack.flatMap { $0.messages.map(\.id) })
            }
            await SyncEngine.runWALMaintenance(
                dbPool: pool, includePrune: includePrune,
                undoProtectedBodyIds: undoProtectedBodyIds
            )
            await SyncEngine.checkpointWALThrottled(truncate: includePrune)
            await SyncEngine.runBodyAssetMaintenance()
        }
    }

    /// Cancel any in-flight foreground maintenance task. Called on background entry
    /// (`SyncScheduler.stopPolling`) so a foreground-started `.utility` task can't be
    /// resumed by the cooperative pool inside a later BGTask window and run its
    /// NON-WAL BodyAssetStore read while the process is being suspended (the exact
    /// `0xdead10cc` this prevents). The per-step `isAppActive` gate in
    /// `runBodyAssetMaintenance` is the hard guarantee; this is the matching lifecycle
    /// cleanup. See ADR-IOS-046.
    func cancelMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = nil
    }

    /// WAL-only maintenance (AppDatabase + SearchIndex). A WAL access at the suspension
    /// instant throws a benign `SQLITE_ABORT`, never `0xdead10cc`, so this runs from
    /// BOTH the foreground poll and the `.full` BGProcessing drain — foreground is
    /// reliable, BGProcessing is opportunistic (iOS does not guarantee it runs), and we
    /// want maintenance to happen whenever EITHER fires. Abandons on suspend at each
    /// step (ADR-IOS-046).
    ///
    /// `async` ONLY because its last step is: the deferred `ANALYZE` has to reach
    /// the priority write queue, and a non-async caller binds `PriorityGate`'s
    /// pass-through synchronous `write` overload instead. Every other step here is
    /// unchanged and still synchronous. Both callers already run inside detached
    /// tasks, so this adds no new concurrency.
    nonisolated static func runWALMaintenance(
        dbPool: PrioritizedDatabase,
        includePrune: Bool,
        undoProtectedBodyIds: Set<String>
    ) async {
        func shouldRun() -> Bool { !Task.isCancelled && !DatabaseSuspension.isSuspended }
        let t0 = CFAbsoluteTimeGetCurrent()
        if includePrune && shouldRun() {
            runPruneIfOverBudget(dbPool: dbPool)
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        if shouldRun() {
            runEvictStaleBodies(dbPool: dbPool, undoProtectedBodyIds: undoProtectedBodyIds)
        }
        let t2 = CFAbsoluteTimeGetCurrent()
        if shouldRun() {
            runPurgeExpiredAICache(dbPool: dbPool)
        }
        let t3 = CFAbsoluteTimeGetCurrent()
        if shouldRun() {
            runEvictChatSessions(dbPool: dbPool)
        }
        let t4 = CFAbsoluteTimeGetCurrent()
        // LAST on purpose. It is the only step here that can cost seconds, it runs at
        // most once per schema change, and nothing above depends on it — so putting it
        // last means a suspension mid-`ANALYZE` costs the cheap reclaim steps nothing.
        // It is on THIS side of the maintenance split because `ANALYZE` is a main-DB
        // WAL write (see `runRefreshPlannerStatisticsIfStale`, and ADR-IOS-046 for why
        // the `runBodyAssetMaintenance` side would be a `0xdead10cc` bug).
        if shouldRun() {
            await runRefreshPlannerStatisticsIfStale(dbPool: dbPool)
        }
        let t5 = CFAbsoluteTimeGetCurrent()
        if includePrune {
            print("[Sync] WAL maintenance: prune=\(Int((t1-t0)*1000))ms evict=\(Int((t2-t1)*1000))ms purge=\(Int((t3-t2)*1000))ms chatEvict=\(Int((t4-t3)*1000))ms analyze=\(Int((t5-t4)*1000))ms")
        } else {
            print("[Sync] WAL maintenance: evict=\(Int((t2-t1)*1000))ms purge=\(Int((t3-t2)*1000))ms chatEvict=\(Int((t4-t3)*1000))ms analyze=\(Int((t5-t4)*1000))ms")
        }
    }

    private static let walCheckpointState = Mutex<Double>(0)

    /// Throttled PASSIVE (or TRUNCATE) WAL checkpoint. Safe to call from ANY `.normal` /
    /// `.background` job — full/delta sync, header/body/embedding backfill, maintenance —
    /// which is where every caller is. Self-throttles to at most once per
    /// `SyncConfig.walCheckpointMinIntervalSeconds`, so a high-frequency caller (the
    /// embedding queue drains every ~260ms) can't over-checkpoint. SQLite autocheckpoint is
    /// OFF (`AppDatabase.makePool`), so THIS is what bounds the WAL — and it always runs on
    /// `.background` (via `backgroundPool`), NEVER on a foreground/`.priority` write, so the
    /// merge / a user action can't inherit a checkpoint stall (the ~1-2s "tic"). Hanging it
    /// off the constantly-running backfill — not just the sparse per-poll maintenance, which
    /// ran 0x in a 44-min capture — is what bounds the WAL reliably.
    nonisolated static func checkpointWALThrottled(truncate: Bool = false) async {
        let now = CFAbsoluteTimeGetCurrent()
        let go = walCheckpointState.withLock { last -> Bool in
            guard now - last >= SyncConfig.walCheckpointMinIntervalSeconds else { return false }
            last = now
            return true
        }
        guard go, !DatabaseSuspension.isSuspended else { return }
        let sql = truncate ? "PRAGMA wal_checkpoint(TRUNCATE)" : "PRAGMA wal_checkpoint(PASSIVE)"
        let t0 = CFAbsoluteTimeGetCurrent()
        let frames = try? await AppDatabase.backgroundPool.writeWithoutTransaction { db -> (log: Int, ckpt: Int) in
            guard let row = try Row.fetchOne(db, sql: sql) else { return (-1, -1) }
            let log: Int = row[1] ?? -1
            let ckpt: Int = row[2] ?? -1
            return (log, ckpt)
        }
        // DIAGNOSTIC (debug-gated, task a): WAL frame count + checkpoint cost, so a merge
        // "tic" that ever lines up with a big background checkpoint stays visible.
        if let f = frames, f.log > 0 {
            BootProfiler.mark("WAL checkpoint(\(truncate ? "TRUNCATE" : "PASSIVE")): \(f.ckpt)/\(f.log) frames in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
        }
    }

    /// NON-WAL BodyAssetStore maintenance: evict attachments over the user's cap, then
    /// sweep cross-DB/filesystem orphans (NSE-written assets whose push got dropped,
    /// eviction crashes, etc.). Both are no-ops on cold/empty state and idempotent;
    /// order matters (evict first so the sweep skips freshly-evicted files).
    ///
    /// FOREGROUND-ONLY. The manifest is a non-WAL `DatabaseQueue` in the App-Group
    /// container (shared with the NSE); its read holds a SQLite lock that RunningBoard
    /// kills as `0xdead10cc` if the process suspends mid-read, and GRDB's
    /// `Database.suspendNotification` cannot abort it (it's blocked in `pread`). WAL is
    /// the only suspension-exempt access and we keep this DB non-WAL for App-Group
    /// sharing safety, so these reads must only START while `isAppActive` (iOS never
    /// freezes a foreground process). The foreground poll fires every interval the app
    /// is open, so eviction is NOT starved by the unguaranteed BGProcessing task.
    /// See ADR-IOS-046.
    nonisolated static func runBodyAssetMaintenance() async {
        func shouldRun() -> Bool {
            !Task.isCancelled
                && !DatabaseSuspension.isSuspended
                && DatabaseSuspension.isAppActive
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        if shouldRun() {
            await BodyAssetMaintenance.evictIfOverCap()
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        if shouldRun() {
            await BodyAssetMaintenance.pruneOrphans()
        }
        let t2 = CFAbsoluteTimeGetCurrent()
        print("[Sync] BodyAsset maintenance: assetEvict=\(Int((t1-t0)*1000))ms assetSweep=\(Int((t2-t1)*1000))ms")
    }

    /// Two-tier sync: tries delta sync first (fast), falls back to full sync (robust).
    /// Delta sync runs on frequent polls (every 60s) — checks only what changed.
    // MARK: - Background-Safe Delta Sync

    /// Lightweight delta-only sync for background execution (BGAppRefreshTask, silent push).
    /// Only fetches new headers and enqueues to body/AI/embedding queues.
    /// Does NOT start backfill, bulk index, embedding rebuild, or full sync fallback.
    /// Designed to complete well within iOS's ~30s background budget.
    /// Returns (changed, reason) where reason describes what happened for diagnostics.
    @discardableResult
    func backgroundDeltaSync(account: Account, inboxOnly: Bool = false) async throws -> (changed: Bool, reason: String) {
        guard let queue = workQueues[account.id] else {
            print("[Sync:bg] No provider for \(account.emailAddress) — skipping")
            BackgroundSyncLogger.log("bgDelta: \(account.emailAddress) noProvider")
            return (false, "noProvider")
        }
        let provider = queue.provider

        // No syncing guard here — background delta syncs run concurrently with
        // foreground syncs. Delta operations are idempotent (upserts, no-op deletes),
        // and historyId/deltaToken writes are monotonically increasing, so concurrent
        // execution is safe and prevents pushes from being blocked by slow foreground polls.

        // Pool creates connections on demand via checkout — no explicit connect needed.
        // Callers (AccountManager.backgroundSyncOne) already call ensureConnected() upstream.

        // Only attempt delta — never fall through to full sync in background.
        // Full sync is too heavy for the 30s budget and will run on next foreground poll.
        // Each provider's delta sync already checks its own cursor validity:
        // - Gmail: returns (false, false) if lastHistoryId is nil
        // - Outlook: returns (false, false) if delta token is missing
        // - IMAP/iCloud: stateless STATUS commands, always works
        // No time-based guard needed here.

        // Publish sync phase so push-triggered/background syncs show "Checking..."
        // in the subtitle, not just the foreground path. Defer clears on return.
        let accountId = account.id
        defer {
            Task { @MainActor in AccountManagerState.shared.setSyncPhase(nil, forAccount: accountId) }
        }
        Task { @MainActor in AccountManagerState.shared.setSyncPhase(.checking, forAccount: accountId) }

        do {
            let result = try await queue.execute(priority: .headerFetch) {
                try await self.performDeltaSync(account: account, provider: provider, inboxOnly: inboxOnly)
            }
            if result.succeeded {
                try await dbPool.write { db in
                    _ = try Account.filter(Column("id") == account.id)
                        .updateAll(db, Column("lastSyncedAt").set(to: Date()))
                }
                print("[Sync:bg] Delta sync completed for \(account.emailAddress) (changes: \(result.hadChanges))")
                await Self.checkpointWALThrottled()
                return (result.hadChanges, result.hadChanges ? "deltaChanges" : "deltaNoChanges")
            } else {
                print("[Sync:bg] Delta not ready for \(account.emailAddress) (no cursor or expired) — will full-sync on foreground")
                BackgroundSyncLogger.log("bgDelta: \(account.emailAddress) noCursor")
                return (false, "noCursor")
            }
        } catch {
            if Self.isConnectionError(error) {
                // Pool self-heals: dead connections discarded on checkin(healthy: false),
                // next checkout creates a fresh one. Retry without disconnect/reconnect.
                print("[Sync:bg] Connection error for \(account.emailAddress): \(error) — retrying")
                let retry = try await queue.execute(priority: .headerFetch) {
                    try await self.performDeltaSync(account: account, provider: provider, inboxOnly: inboxOnly)
                }
                if retry.succeeded {
                    try await dbPool.write { db in
                        _ = try Account.filter(Column("id") == account.id)
                            .updateAll(db, Column("lastSyncedAt").set(to: Date()))
                    }
                    print("[Sync:bg] Delta sync completed for \(account.emailAddress) after retry (changes: \(retry.hadChanges))")
                    return (retry.hadChanges, retry.hadChanges ? "deltaChanges(retry)" : "deltaNoChanges(retry)")
                }
            }
            print("[Sync:bg] Delta sync failed for \(account.emailAddress): \(error) — will full-sync on foreground")
            BackgroundSyncLogger.log("bgDelta: \(account.emailAddress) ERROR: \(error)")
            if !(error is CancellationError) && !Self.isConnectionError(error) {
                BackgroundSyncLogger.logError("\(error)", source: "deltaSync:\(account.emailAddress)")
            }
            let errorDesc = String(describing: error).prefix(100)
            return (false, "error(\(errorDesc))")
        }
    }

    // MARK: - Foreground Sync

    private let fullSyncInterval: TimeInterval = 900 // 15 minutes

    /// Foreground sync: always tries delta first, then runs full sync separately
    /// if it's been >15 min since the last one (self-healing safety net).
    /// Pull-to-refresh also uses this — delta is always the fast path.
    @discardableResult
    func sync(account: Account) async throws -> Bool {
        guard let queue = workQueues[account.id] else {
            print("[Sync] No provider registered for \(account.emailAddress) — skipping")
            return false
        }
        let provider = queue.provider

        // Skip if this account was synced very recently — prevents redundant syncs
        // from overlapping callers (RootView.task, SyncScheduler, InboxViewModel).
        if let lastSync = account.lastSyncedAt, Date().timeIntervalSince(lastSync) < 15 {
            print("[Sync] Skipping \(account.emailAddress) — synced \(Int(Date().timeIntervalSince(lastSync)))s ago")
            return false
        }

        // No per-account sync guard — ProviderWorkQueue handles concurrency.
        // Duplicate foreground syncs for the same account serialize through the work queue.
        let accountId = account.id
        defer {
            Task { @MainActor in AccountManagerState.shared.setSyncPhase(nil, forAccount: accountId) }
        }

        Task { @MainActor in AccountManagerState.shared.setSyncPhase(.checking, forAccount: accountId) }

        // Pool creates connections on demand via checkout — no explicit connect needed.

        // 1. Always try delta sync first — this is the fast path for every poll/pull-to-refresh.
        var hadChanges = false
        var deltaSyncSucceeded = false
        var deltaSyncError: (any Error)?
        do {
            let deltaResult = try await queue.execute(priority: .headerFetch) {
                try await self.performDeltaSync(account: account, provider: provider)
            }
            if deltaResult.succeeded {
                deltaSyncSucceeded = true
                try await dbPool.write { db in
                    _ = try Account.filter(Column("id") == account.id)
                        .updateAll(db, Column("lastSyncedAt").set(to: Date()))
                }
                hadChanges = deltaResult.hadChanges
                print("[Sync] Delta sync completed for \(account.emailAddress) (changes: \(hadChanges))")
            }
        } catch {
            deltaSyncError = error
            if Self.isConnectionError(error) {
                // Pool self-heals: dead connections discarded on checkin(healthy: false),
                // next checkout creates a fresh one. Retry without disconnect/reconnect.
                print("[Sync] Delta sync connection error for \(account.emailAddress): \(error) — retrying")
                do {
                    let retryResult = try await queue.execute(priority: .headerFetch) {
                        try await self.performDeltaSync(account: account, provider: provider)
                    }
                    if retryResult.succeeded {
                        deltaSyncSucceeded = true
                        deltaSyncError = nil
                        try await dbPool.write { db in
                            _ = try Account.filter(Column("id") == account.id)
                                .updateAll(db, Column("lastSyncedAt").set(to: Date()))
                        }
                        hadChanges = retryResult.hadChanges
                        print("[Sync] Delta sync completed for \(account.emailAddress) (after retry, changes: \(hadChanges))")
                    }
                } catch {
                    deltaSyncError = error
                    print("[Sync] Delta sync retry also failed for \(account.emailAddress): \(error)")
                    if !(error is CancellationError) && !Self.isConnectionError(error) {
                        BackgroundSyncLogger.logError("\(error)", source: "deltaSync:\(account.emailAddress)")
                    }
                }
            } else {
                print("[Sync] Delta sync failed for \(account.emailAddress): \(error)")
                if !(error is CancellationError) {
                    BackgroundSyncLogger.logError("\(error)", source: "deltaSync:\(account.emailAddress)")
                }
            }
        }

        // 2. Full sync runs separately on its own schedule (~15 min) as a self-healing safety net.
        //    NOT a fallback from delta — runs independently regardless of delta success/failure.
        let timeSinceFullSync = account.lastFullSyncAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if timeSinceFullSync >= fullSyncInterval {
            print("[Sync] Full sync due for \(account.emailAddress) (last: \(timeSinceFullSync.isFinite ? "\(Int(timeSinceFullSync))s" : "never"))...")
            do {
                try await queue.execute(priority: .headerFetch) {
                    try await self.fullSync(account: account, provider: provider)
                }
            } catch {
                if Self.isConnectionError(error) {
                    // Pool self-heals: dead connections discarded on checkin(healthy: false),
                    // next checkout creates a fresh one. Retry without disconnect/reconnect.
                    print("[Sync] Connection lost during full sync, retrying...")
                    try await queue.execute(priority: .headerFetch) {
                        try await self.fullSync(account: account, provider: provider)
                    }
                } else {
                    if !(error is CancellationError) {
                        BackgroundSyncLogger.logError("\(error)", source: "fullSync:\(account.emailAddress)")
                    }
                    throw error
                }
            }

            await queue.execute(priority: .headerFetch) {
                await self.captureSyncCursors(account: account, provider: provider)
            }

            let now = Date()
            try await dbPool.write { db in
                _ = try Account.filter(Column("id") == account.id)
                    .updateAll(db,
                        Column("lastSyncedAt").set(to: now),
                        Column("lastFullSyncAt").set(to: now)
                    )
            }
            print("[Sync] Full sync completed for \(account.emailAddress)")
            hadChanges = true

            // Post-full-sync maintenance
            await queue.execute(priority: .bodyFetch) {
                await self.sweepStaleActionTags(account: account, provider: provider)
            }
            await queue.execute(priority: .bodyFetch) {
                await self.selfHealRecentMessages(account: account)
            }
        }

        // If delta sync failed and full sync didn't run (not due yet), no server contact
        // succeeded — propagate the error so the caller knows sync failed. Without this,
        // the caller reports success and updates lastSyncCompletedAt, showing "Updated less
        // than a minute ago" even when offline.
        if !deltaSyncSucceeded, timeSinceFullSync < fullSyncInterval, let error = deltaSyncError {
            throw error
        }

        // 3. Background work — runs after every sync (delta or full)
        print("[Sync] \(account.emailAddress) calling startBackfill")
        startBackfill(account: account)
        bulkIndexIfNeeded(account: account)
        backfillFolderIdsIfNeeded()

        return hadChanges
    }

    // MARK: - Infinite Scroll (Fetch Older Messages)

    /// Fetch older messages for the given folders (infinite scroll).
    ///
    /// - Returns: `inserted` — new rows materialised across all folders — and
    ///   `mayHaveMore`, the scroller's continuation signal.
    ///
    /// 🚨 **`mayHaveMore` IS A STATEMENT ABOUT SERVER COVERAGE, NEVER ABOUT HOW
    /// MANY ROWS WE CHOSE TO MATERIALISE.** A record the server reports `\Deleted`
    /// consumes a slot in the page (`IMAPProvider.fetchOlderMessagesWithObservedEpoch`
    /// takes its `prefix(limit)` before any flag is known) and is then deliberately
    /// NOT inserted below (IOS-IMAP-001 / D3), so `inserted < found` is routine and
    /// says nothing about whether the folder is exhausted. Deriving exhaustion from
    /// `inserted` strands every message older than the first soft-deleted one.
    /// The backfill crawl makes the same distinction — `UIDWalkCursor`'s
    /// `confirmedCursor` advances through `confirmRange`, which fires once a UID
    /// range is ACCOUNTED FOR (SEARCH reported it empty, or its FETCH+insert leg
    /// completed), so a range that inserts zero rows still advances it — and this
    /// is the same rule for the paging pull.
    ///
    /// ⚠️ An earlier revision of this comment cited `deepBackfillFolder`'s
    /// `found == 0` termination here instead. That function has ZERO callers
    /// (`rg -n 'deepBackfillFolder' TabMail/` finds one declaration and comments
    /// only), as does its callee `backfillWindow` outside it, so it proved
    /// nothing about the shipping crawl. Do not restore that citation, and do
    /// not delete the dead functions as a side effect of reading this — that is
    /// its own decision.
    ///
    /// **AND `found` IS THE PROVIDER'S OWN COVERAGE REPORT, NOT THE ARRAY'S COUNT.**
    /// Every `fetchOlderMessages` implementation ends in a `compactMap` that drops
    /// records it cannot parse, so the returned array's count is a SURVIVOR count.
    /// `FetchCoverage.serverRecordCount` is computed at the fetch site from what the
    /// server named (for IMAP, the UID batch `searchDateRange` returned) — see
    /// `FetchCoverage`.
    ///
    /// **TERMINATION.** Continuing requires BOTH halves, per folder:
    /// 1. *coverage* — the server named a page as large as the one we asked for
    ///    (`found >= SyncConfig.infiniteScrollFetchLimit`), so older mail may exist
    ///    beyond it; a short page means the server showed us everything it had; and
    /// 2. *progress* — that folder materialised at least one new row. This pull's
    ///    cursor IS the folder's oldest local row (`oldestDate` below), so a round
    ///    that inserts nothing would re-ask the identical window forever. Requiring
    ///    an insert makes every continuing round strictly grow the local folder,
    ///    which is bounded by the server's finite message count.
    ///
    /// A full page in which nothing could be materialised therefore stops paging
    /// (fail closed). **Registered as `IOS-SCROLL-001`** — the reachable instance is
    /// a page whose every record the server reports `\Deleted`, which happens on a
    /// server without UIDPLUS where each completed move leaves a soft-deleted source
    /// copy behind. It is an ACCEPTED limitation, not an oversight: the progress
    /// half is a termination guard, not a coverage claim, and removing it would make
    /// the scroller re-ask the identical window forever. That is recoverable without
    /// any user gesture, by
    /// `SyncEngine.runBackfill`'s UID-range walk — whose cursor advances on
    /// COVERAGE (a confirmed range) and never on inserts — so the mail beyond it
    /// still arrives locally and the next reset re-arms the scroller. What
    /// INVOKES that walk, because "covered by X" is a claim about the path that
    /// reaches X: `SyncEngine.startBackfill`'s per-account crawl loop (started
    /// from `sync` after every sync) and `SyncScheduler`'s BGProcessing pass via
    /// `AccountManager.runBackfill` → `SyncEngine.performBackfill`.
    ///
    /// Negative case: `runBackfill` only walks folders with
    /// `backfillComplete == false`. A completed folder is never re-walked — but
    /// its UID space was already covered down to UID 1, so no older mail is left
    /// unreached. The exception is a folder wrongly marked complete by the
    /// `.fresh` branch when the server reports no UIDNEXT; that is registered and
    /// is not recoverable by ordinary sync.
    func fetchOlderMessages(folders: [Folder]) async throws -> (inserted: Int, mayHaveMore: Bool) {
        var totalNew = 0
        var mayHaveMore = false
        for folder in folders {
            guard let queue = workQueues[folder.accountId] else { continue }
            let provider = queue.provider

            // Find oldest date
            let oldestDate: Date = try await dbPool.read { db in
                try MessageHeader
                    .filter(Column("folderId") == folder.id)
                    .order(Column("date").asc)
                    .limit(1)
                    .fetchOne(db)?.date ?? Date()
            }

            let pageLimit = SyncConfig.infiniteScrollFetchLimit
            let fetched: (headers: [MessageHeaderInfo], observedEpoch: UInt32?, coverage: FetchCoverage)
            do {
                fetched = try await queue.execute(priority: .userAction) {
                    if let imapProvider = provider as? IMAPProvider {
                        let result = try await imapProvider.fetchOlderMessagesWithObservedEpoch(
                            folder: folder.path, before: oldestDate, limit: pageLimit)
                        return (result.messages, result.observedEpoch, result.coverage)
                    } else if let gmailProvider = provider as? GmailProvider {
                        let result = try await gmailProvider.fetchOlderMessagesWithCoverage(
                            folder: folder.path, before: oldestDate, limit: pageLimit)
                        return (result.messages, nil, result.coverage)
                    } else if let exchangeProvider = provider as? ExchangeProvider {
                        let result = try await exchangeProvider.fetchOlderMessagesWithCoverage(
                            folder: folder.path, before: oldestDate, limit: pageLimit)
                        return (result.messages, nil, result.coverage)
                    }
                    // No known provider: we asked nothing, so we proved nothing.
                    return ([], nil, .unproven)
                }
            } catch {
                if SyncEngine.isSelectFailedError(error) {
                    // Gated: on a device `stdout` is discarded, so this print is not
                    // the production-observability channel — the `logError` below is
                    // (file-backed, exported by `DebugLogView`), and it is unchanged.
                    if DebugModeManager.isLoggingEnabled() {
                        print("[InfiniteScroll] SELECT failed for \(folder.name) — skipping")
                    }
                    BackgroundSyncLogger.logError("SELECT failed for \(folder.name): \(error)", source: "infiniteScroll")
                    continue
                }
                throw error
            }
            let headers = fetched.headers
            // COVERAGE — what the SERVER named for the window we asked about,
            // counted at the fetch site BEFORE any client-side narrowing
            // (`FetchCoverage.serverRecordCount`; for IMAP it is the size of the
            // UID batch `searchDateRange` returned, taken before the FETCH).
            //
            // 🚨 This used to read `headers.count` under this same "what the SERVER
            // returned" comment, and that was FALSE: `headers` is the provider's
            // post-`compactMap` survivor array, so a record whose date failed to
            // parse shrank the number the continuation decision is made from. The
            // `\Deleted` records the insert loop below deliberately skips ARE
            // counted here — exactly as the backfill walk confirms a UID range
            // whose inserts were all skipped. Never narrow this to the insert
            // count, and never back to the materialised count. (An earlier
            // revision cited `backfillWindow`'s `found` here; that function is
            // unreachable in production — see the `deepBackfillFolder` note on
            // `fetchOlderMessages` above.)
            let found = fetched.coverage.serverRecordCount
            let sourceBoundEpoch = fetched.observedEpoch.flatMap { epoch in
                epoch > 0 ? Int(exactly: epoch) : nil
            }

            // Deduplicate and insert
            let writeResult: (inserted: [MessageHeader], discoveredParents: [String]) = try await dbPool.write { db in
                var inserted: [MessageHeader] = []
                for info in headers {
                    // IOS-IMAP-001 / D3 — a message the server reports with `\Deleted`
                    // is NOT PRESENT for display (RFC 3501 §2.3.2). The merge enforces
                    // that at `selectStaleHeaders` and `runSyncMessages`; this "load
                    // older" pull materialises a `MessageHeader` from the same
                    // `MessageHeaderInfo`s and never read the flag, so scrolling past
                    // the end of a folder re-materialised the soft-deleted source copy
                    // of a move the merge had already removed. Skipping the insert
                    // reaches the merge's own end state — no local row. Nothing is
                    // queued on this path, so no user intention is involved; and it is
                    // insert-prevention only, so an existing row is left for the merge's
                    // stale channel rather than deleted as a side effect of paging.
                    if info.isDeletedOnServer { continue }
                    let exists = try MessageHeader
                        .filter(Column("messageId") == info.messageId && Column("folderId") == folder.id)
                        .fetchCount(db) > 0
                    if exists { continue }

                    var header = MessageHeader(
                        messageId: info.messageId,
                        subject: info.subject,
                        from: info.from,
                        fromAddress: info.fromAddress,
                        to: info.to,
                        date: info.date,
                        snippet: EmailFilter.cleanSnippet(info.snippet),
                        folderId: folder.id,
                        accountId: folder.accountId,
                        folderPath: folder.path,
                        isInInbox: folder.role == .inbox
                    )
                    header.rfc822MessageId = info.rfc822MessageId
                    header.observedUidValidity = sourceBoundEpoch
                    header.inReplyTo = info.inReplyTo
                    header.referencesJSON = MessageHeader.encodeReferences(info.references)
                    header.threadId = info.threadId ?? ThreadUtils.computeSubjectThreadId(accountId: folder.accountId, subject: header.subject)
                    try ThreadUtils.assignComputedThreadId(to: &header, nativeThreadId: info.threadId, db: db)
                    header.replyTo = info.replyTo
                    header.cc = info.cc
                    header.bcc = info.bcc
                    header.isRead = info.isRead
                    header.isFlagged = info.isFlagged
                    header.hasAttachments = info.hasAttachments
                    header.isReplied = info.isReplied
                    header.isForwarded = info.isForwarded
                    header.actionTag = info.actionTag
                    header.tagSortOrder = info.actionTag?.sortOrder ?? 99
                    try MessageAICache.restoreIfCached(
                        into: &header,
                        accountId: folder.accountId,
                        folderPath: folder.path,
                        db: db
                    )
                    // ReplyDetect: if message is already replied and tagged as "reply", override to "none"
                    // AI cache keeps original LLM value — only MessageHeader + IMAP tag change
                    if header.isReplied && header.actionTag == .reply {
                        header.actionTag = ActionTag.none
                        header.tagSortOrder = ActionTag.none.sortOrder
                        let tagOp = PendingOperation(
                            type: .setTag,
                            messageIds: [header.stableId],
                            accountId: folder.accountId,
                            folderPath: folder.path,
                            tagValue: ActionTag.none.rawValue
                        )
                        try tagOp.insert(db)
                        print("[ReplyDetect] Scroll insert: reply→none for \(header.messageId) (already replied)")
                    }
                    try header.save(db)
                    try ThreadUtils.insertMessageReferences(for: header, db: db)
                    inserted.append(header)
                }

                // Sent-folder reply discovery — no-op when folder.role != .sent.
                let discovered = try ReplyParentResolver.markParentsReplied(
                    inReplyTos: headers.map(\.inReplyTo),
                    folderRole: folder.role,
                    accountId: folder.accountId,
                    db: db
                )

                return (inserted, discovered)
            }
            let newHeaders = writeResult.inserted
            ReplyParentResolver.postParentNotifications(writeResult.discoveredParents)

            // 🚨 THE GATE IS IN THE BODY, NEVER IN THE BRANCH CONDITION. The second
            // arm used to read `else if found > 0, DebugModeManager.isLoggingEnabled()`,
            // which makes a debug unlock decide WHICH BRANCH IS TAKEN rather than
            // merely whether a line is printed — so debug and release builds no longer
            // share one control-flow graph, and any future non-logging statement added
            // to that arm would silently not run in production. Nothing here has a
            // non-logging effect today, which is why the hoist is behaviour-preserving;
            // it is written this way so it stays that way (global CLAUDE.md rule 12).
            if !newHeaders.isEmpty {
                await indexHeadersForFTS(newHeaders)
                if DebugModeManager.isLoggingEnabled() {
                    print("[InfiniteScroll] \(folder.name): +\(newHeaders.count) of \(found) older messages")
                }
            } else if found > 0 {
                if DebugModeManager.isLoggingEnabled() {
                    print("[InfiniteScroll] \(folder.name): server returned \(found) records, none materialised — this pull's cursor cannot advance, so paging stops")
                }
            }
            totalNew += newHeaders.count

            // COVERAGE (`found` — what the server returned, including the
            // `\Deleted` records the loop above deliberately skipped) AND PROGRESS
            // (this folder materialised something, so the cursor moves). See the
            // termination note on this function; neither half alone is sound.
            if found >= pageLimit && !newHeaders.isEmpty {
                mayHaveMore = true
            }
        }
        return (totalNew, mayHaveMore)
    }

    /// Apply snippet updates directly to GRDB — no background queue needed.
    /// Also marks bodyComplete = true since FTS body was written in the same batch.
    func applySnippetUpdates(_ updates: [(headerId: String, snippet: String)]) {
        guard !updates.isEmpty else { return }
        do {
            try dbPool.write { db in
                for (headerId, snippet) in updates {
                    try MessageHeader.filter(Column("id") == headerId)
                        .updateAll(db,
                                   Column("snippet").set(to: snippet),
                                   Column("bodyComplete").set(to: true))
                }
            }
        } catch {
            print("[SnippetFill] Update failed: \(error)")
            BackgroundSyncLogger.logError("Snippet update failed: \(error)", source: "snippetFill")
        }
    }

    /// Detect SELECT failures (server returned BAD/NO to SELECT command).
    /// This means the folder is inaccessible — renamed, deleted, or the server rejects it.
    /// Not a connection error — the connection is fine, just this folder can't be opened.
    /// Callers should skip the folder and continue with the next one.
    nonisolated static func isSelectFailedError(_ error: Error) -> Bool {
        let msg = "\(error)"
        return msg.contains("Select mailbox failed")
    }

    /// Detect connection-related errors (stale socket, server disconnect, parser corruption, etc.)
    /// Used by sync and backfill paths to decide whether to reconnect.
    /// IMAPDecoderError = NIO parser buffer is corrupted (leftover bytes from previous response).
    /// Once this happens the connection is permanently broken — must disconnect and reconnect.
    /// NOTE: ProviderError.networkError (HTTP 4xx/5xx) is NOT a connection error — the request
    /// completed and the server responded. Only transport-level failures warrant reconnection.
    nonisolated static func isConnectionError(_ error: Error) -> Bool {
        if case ProviderError.notConnected = error { return true }
        // URLError from URLSession (Gmail/Exchange HTTP): airplane mode, DNS failure, connection lost, etc.
        if error is URLError { return true }
        // NIOCore.ChannelError — raw NIO transport failure that escaped SwiftMail's IMAPError wrapping
        // (e.g. writeAndFlush on an already-closed channel during auth/IDLE/command paths). The case
        // name (`alreadyClosed`, `ioOnClosedChannel`, `connectPending`, …) does not match any of the
        // substrings below, and `error.localizedDescription` becomes the bridged NSError form
        // ("The operation couldn't be completed. (NIOCore.ChannelError error N.)") which leaks to the
        // UI when this predicate misses it. Domain check covers every case without importing NIO.
        if (error as NSError).domain == "NIOCore.ChannelError" { return true }
        // NIOCore.IOError — raw syscall failure (read/write/connect errno) that escaped SwiftMail's
        // IMAPError wrapping, same leak class as ChannelError above. Its description embeds strerror
        // text for an arbitrary errno (e.g. "Operation not permitted (errno: 1)"), which the substrings
        // below cannot enumerate, and the bridged NSError form is
        // "The operation couldn't be completed. (NIOCore.IOError error 1.)" (structs always bridge
        // code 1). Seen surfacing verbatim in the inbox error banner during a foreground poll (2026-07-04).
        if (error as NSError).domain == "NIOCore.IOError" { return true }
        let msg = "\(error)"
        return msg.contains("notConnected") || msg.contains("not connected")
            || msg.contains("Connection reset") || msg.contains("command failed")
            || msg.contains("broken pipe") || msg.contains("connection closed") || msg.contains("Connection closed")
            || msg.contains("Connection failed") // IMAPError.connectionFailed — covers all inner reasons
            || msg.contains("closed channel") || msg.contains("I/O on closed")
            || msg.contains("bad(Error in IMAP")
            || msg.contains("EPIPE") || msg.contains("timed out")
            || msg.contains("IMAPDecoderError") || msg.contains("IMAPDecodeError")
            || msg.contains("NIOConnectionError") // NIOPosix.NIOConnectionError — TCP connection failed
            || msg.contains("ChannelError") // NIOCore.ChannelError (already-bridged string form)
            || msg.contains("NIOCore.IOError") // NIOCore.IOError (already-bridged string form)
            || msg.contains("DNS error") // NIO DNS resolution failure (no internet, DNS unreachable)
            || msg.contains("connection appears to be offline") // URLSession offline description
            || msg.contains("max_userip_connections") // Server rejected — too many IMAP connections (handled by adaptive concurrency)
    }

    /// True when `error` is a *transient* HTTP response from a reachable provider —
    /// HTTP 5xx (500/502/503/504/…) or 429 (rate limited). Unlike `isConnectionError`
    /// (transport-level failure), here the request completed and the server answered,
    /// just with a status that will likely clear on its own (e.g. Microsoft Graph
    /// returning 503 "Error making HTTP request" during connect). These are NOT a real
    /// sync failure — the next sync cycle retries — so callers use this to keep momentary
    /// provider blips from surfacing as a failed-sync indicator or error banner in the UI.
    ///
    /// Matches both wrapping shapes used in the codebase: `ProviderError.networkError`
    /// around our `HTTPError.networkError(statusCode:)` enum, and around the
    /// `NSError(domain: "Gmail"/"Exchange", code: statusCode)` form that the HTTP
    /// providers throw (mirrors the unwrap in `isHttpGoneStatus`).
    nonisolated static func isTransientError(_ error: Error) -> Bool {
        guard case ProviderError.networkError(let underlying) = error else { return false }
        let status: Int
        if case HTTPError.networkError(let statusCode) = underlying {
            status = statusCode
        } else {
            status = (underlying as NSError).code
        }
        return status == 429 || (status >= 500 && status <= 599)
    }
}
