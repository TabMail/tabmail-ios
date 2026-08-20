/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftMail
import UIKit
@preconcurrency import BackgroundTasks
import Network
import Synchronization

/// Thread-safe context shared between a BGTask's processing body and its
/// expiration handler. `@unchecked Sendable` lets it be freely captured across
/// isolation domains without triggering Swift 6 region-based sending errors.
/// NSLock provides the actual thread safety.
private final class BGTaskContext: @unchecked Sendable {
    private var _expired = false
    private var _task: Task<Void, Never>?
    private let lock = NSLock()
    let label: String

    init(label: String) {
        self.label = label
        print("[BGTaskCtx:\(label)] created on thread \(Thread.current)")
    }

    var expired: Bool {
        lock.withLock { _expired }
    }

    /// Mark as expired and cancel the processing task (if registered).
    func expire() {
        print("[BGTaskCtx:\(label)] expire() called on thread \(Thread.current), isMainThread=\(Thread.isMainThread)")
        lock.lock()
        _expired = true
        let task = _task
        lock.unlock()
        if let task {
            print("[BGTaskCtx:\(label)] cancelling processing task")
            task.cancel()
        } else {
            print("[BGTaskCtx:\(label)] expire() but processing task not yet registered")
        }
    }

    /// Register the processing task. If already expired, cancels immediately.
    func setTask(_ task: Task<Void, Never>) {
        lock.lock()
        _task = task
        let isExpired = _expired
        lock.unlock()
        print("[BGTaskCtx:\(label)] setTask() called, alreadyExpired=\(isExpired)")
        if isExpired { task.cancel() }
    }
}

/// Manages periodic foreground polling and background app refresh for email sync.
/// Tier 1: Foreground timer (60s) — near-real-time while app is open.
/// Tier 2: BGAppRefreshTask — periodic updates when app is backgrounded.
@MainActor
final class SyncScheduler {
    static let shared = SyncScheduler()

    /// Key for WiFi-only background backfill setting (default: true).
    /// Only gates the backward crawl (history backfill). Sync, body fetch,
    /// AI processing, and embeddings always run regardless of network type.
    static let wifiOnlyKey = "backgroundSyncWiFiOnly"

    private var timer: Timer?
    private let foregroundInterval: TimeInterval = SyncConfig.foregroundPollIntervalSeconds
    private let manager = AccountManager.shared

    var lastPollTime: Date?
    /// Whether a foreground poll is currently running. Used only to skip duplicate polls
    /// and to let BGAppRefresh defer when foreground is already syncing.
    private var isPollActive = false
    /// Whether the startup Task from startForegroundPolling is in-flight.
    /// Prevents duplicate subscribe/sync work when iOS delivers multiple .active transitions.
    private var isStartupInFlight = false

    /// Did the app enter the background (→ possible iOS suspension → stale TCP/HTTP
    /// connections + frozen in-flight queue tasks) since the last suspension-recovery
    /// cancel ran? Starts `true`: a cold launch must recover once before any fast-path
    /// skip is allowed. Set by the `didEnterBackgroundNotification` observer (a @Sendable
    /// block, hence a static `Mutex`); cleared by `syncStartup` after it runs recovery.
    ///
    /// This is the authoritative "we might have suspended" signal that gates the
    /// foreground fast-path: a foreground new-mail push may skip the recovery cancel
    /// ONLY when this is `false` AND the app is currently active. Bias is asymmetric on
    /// purpose — over-cancelling wastes a little recompute; under-cancelling leaves frozen
    /// tasks on dead sockets (hang) or races GRDB suspension (0xdead10cc crash). Every
    /// uncertain case must cancel.
    private nonisolated static let didBackgroundSinceRecovery = Mutex<Bool>(true)

    // Startup data resets (StartupMigrations) now run synchronously inside
    // AppDatabase.init — before the pool is exposed — so there is no longer an
    // async gate to wait on here. Ordering (resets → NSE merge → sync) is
    // guaranteed by construction: nothing can touch the DB before init returns.

    // MARK: - Pending Sync Queue
    // Persists account emails that received a push but failed to sync (e.g., network dropped mid-sync).
    // Drained on next BGAppRefresh or foreground return. UserDefaults survives app restarts.
    private static let pendingSyncKey = "pending_sync_accounts"

    /// Record that an account needs sync (push arrived but sync may not complete).
    func enqueuePendingSync(email: String) {
        var pending = UserDefaults.standard.stringArray(forKey: Self.pendingSyncKey) ?? []
        guard !pending.contains(email) else { return }
        pending.append(email)
        UserDefaults.standard.set(pending, forKey: Self.pendingSyncKey)
    }

    /// Mark an account's sync as completed — remove from pending queue.
    func completePendingSync(email: String) {
        var pending = UserDefaults.standard.stringArray(forKey: Self.pendingSyncKey) ?? []
        pending.removeAll { $0 == email }
        UserDefaults.standard.set(pending, forKey: Self.pendingSyncKey)
    }

    /// Drain all pending syncs. Called by BGAppRefresh and foreground return.
    /// Returns true if any account had changes.
    private func drainPendingSyncs() async -> Bool {
        let pending = UserDefaults.standard.stringArray(forKey: Self.pendingSyncKey) ?? []
        guard !pending.isEmpty else {
            BackgroundSyncLogger.log("drainPendingSyncs: no pending entries")
            return false
        }
        guard NetworkMonitor.checkConnected() else {
            BackgroundSyncLogger.log("drainPendingSyncs: SKIPPED — no network (\(pending.count) pending: \(pending))")
            return false
        }
        BackgroundSyncLogger.log("drainPendingSyncs: START draining \(pending.count) pending: \(pending)")
        print("[SyncScheduler] Draining \(pending.count) pending sync(s): \(pending)")
        var anyChanges = false
        for email in pending {
            // Re-check connectivity before each sync — network may drop mid-drain
            guard NetworkMonitor.checkConnected() else {
                BackgroundSyncLogger.log("drainPendingSyncs: ABORTED mid-drain — network lost at \(email)")
                break
            }
            let changed = await manager.backgroundSyncForAccount(email: email)
            if changed { anyChanges = true }
            // Only dequeue if network still connected after sync (sync likely completed).
            // If network dropped mid-sync, item stays in queue for next drain.
            if NetworkMonitor.checkConnected() {
                completePendingSync(email: email)
            }
        }
        BackgroundSyncLogger.log("drainPendingSyncs: END (anyChanges=\(anyChanges))")
        return anyChanges
    }

    private var dbPool: PrioritizedDatabase { AppDatabase.dbPool }

    private init() {
        // Authoritative pre-suspension signal. iOS posts didEnterBackgroundNotification
        // before it ever suspends the process, so once it fires the next syncStartup MUST
        // run suspension recovery — even on a foreground fast-path. queue: .main keeps the
        // block on the main thread; it only touches the Sendable static Mutex (no self,
        // no MainActor hop), so it is safe under Swift 6 strict concurrency.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            SyncScheduler.didBackgroundSinceRecovery.withLock { $0 = true }
        }
    }

    /// Pure suspension-recovery decision — no UIKit / global state, so it is unit-testable.
    /// `true` = run recovery (cancel in-flight queues + mark providers dirty).
    ///
    /// Non-foreground callers (`foregroundFastPath == false`) ALWAYS recover — this is the
    /// safe default for every genuine resume (foreground return, BGAppRefresh, BGProcessing).
    /// A foreground new-mail push (`foregroundFastPath == true`) may SKIP recovery ONLY when
    /// the app is currently active AND has not backgrounded since the last recovery — i.e. it
    /// is provably continuous-foreground, so connections are live and tasks are healthy.
    /// Over-cancelling is safe; under-cancelling crashes — so every uncertain case returns true.
    nonisolated static func shouldRunResumeRecovery(
        foregroundFastPath: Bool, appIsActive: Bool, backgroundedSinceRecovery: Bool
    ) -> Bool {
        guard foregroundFastPath else { return true }
        return !appIsActive || backgroundedSinceRecovery
    }

    /// Conservative oracle for "could connections be stale / tasks be frozen?" — the
    /// foreground fast-path's recovery decision, read against live app + flag state.
    /// A foreground new-mail push may skip recovery ONLY when this returns `false`.
    func mayHaveStaleConnections() -> Bool {
        Self.shouldRunResumeRecovery(
            foregroundFastPath: true,
            appIsActive: UIApplication.shared.applicationState == .active,
            backgroundedSinceRecovery: Self.didBackgroundSinceRecovery.withLock { $0 }
        )
    }

    // MARK: - Unified Sync Startup

    enum DrainMode {
        case none              // Foreground: repopulate + let queues run, don't wait
        case budget(TimeInterval) // BGAppRefresh/push: drain until budget exhausted
        case full              // BGProcessing: drain until idle + backfill
    }

    /// Pure drain-mode decision for a silent push (ADR-IOS-056). No UIKit /
    /// global state, so it is unit-testable.
    ///
    /// `PushConfig.silentPushDeadlineSeconds` is a BACKGROUND-ENVELOPE watchdog
    /// — it exists because a background wake (silent push delivered while
    /// suspended, BGAppRefresh) gets only ~30s of iOS runtime before the
    /// process is killed, so `syncStartup` must poll-wait for the active
    /// queues up to that budget or lose the work entirely. A silent push
    /// delivered while the app is FOREGROUND-ACTIVE has no such envelope: the
    /// active body/AI queues now self-drain at `.normal` (ADR-IOS-056 part A —
    /// higher than backfill, still yields to the merge/user actions), so
    /// nothing needs to hold the push handler open polling a budget that
    /// exists to protect a background wake that never happened. Mirrors the
    /// foreground boot path, which already passes `.none`
    /// (`startForegroundPolling` → `syncStartup(drain: .none)`, see below).
    nonisolated static func drainModeForSilentPush(isForegroundActive: Bool) -> DrainMode {
        isForegroundActive ? .none : .budget(PushConfig.silentPushDeadlineSeconds)
    }

    /// Unified startup sequence for all sync entry points.
    /// - inboxOnly: true for BGAppRefresh/push (limited budget), false for foreground/BGProcessing
    /// - drain: how long to wait for queue drain after repopulate
    /// - foregroundFastPath: pass `true` ONLY from in-foreground new-mail triggers
    ///   (`willPresent`, foreground silent push). It REQUESTS skipping the suspension
    ///   recovery (the in-flight cancel + provider re-dirty), but the request is honored
    ///   only when `mayHaveStaleConnections()` independently confirms the app never left
    ///   the foreground since the last recovery. Default `false` = always recover, so every
    ///   genuine resume path (foreground return, BGAppRefresh, BGProcessing) is unchanged.
    func syncStartup(inboxOnly: Bool, drain: DrainMode = .none, foregroundFastPath: Bool = false) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        func stepLog(_ label: String) {
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            BackgroundSyncLogger.log("syncStartup[+\(ms)ms]: \(label)")
        }
        stepLog("ENTER (inboxOnly=\(inboxOnly))")

        // Decide whether to run suspension recovery. DEFAULT: yes. Skip ONLY when a
        // foreground caller requested the fast-path AND the app is provably continuous-
        // foreground (no suspension → connections live, tasks healthy). Over-cancelling is
        // safe; under-cancelling crashes — so the decision errs toward true.
        let runResumeRecovery = Self.shouldRunResumeRecovery(
            foregroundFastPath: foregroundFastPath,
            appIsActive: UIApplication.shared.applicationState == .active,
            backgroundedSinceRecovery: Self.didBackgroundSinceRecovery.withLock { $0 }
        )

        // Pause sync while demo mode is active — real accounts must not sync or
        // merge NSE data underneath the demo (incl. debug-menu demo while logged in).
        if DemoModeStore.shared.isActive {
            stepLog("SKIPPED — demo mode active")
            return
        }

        // 0. Merge NSE staging data FIRST — before any sync or AI processing.
        // This imports AI results computed by the NSE so the main app doesn't re-process them.
        // Also mirror lastHistoryIds so subsequent NSE invocations have fresh cursors.
        await NSEDataBridge.mergeNSEStagingData()
        NSEDataBridge.mirrorLastHistoryIds()
        stepLog("step0 NSE merge + mirror")

        // 1. Cancel stale in-flight tasks from previous cycles (parallel — independent
        // actors). cancelAllInFlight releases tasks frozen by iOS suspension (stale
        // TCP/HTTP) — required on every genuine resume. A foreground new-mail push is NOT
        // a suspension boundary: connections are live and in-flight AI LLM calls are
        // healthy, so cancelling them just discards calls already dispatched to the backend
        // and forces recompute (observed: foreground pushes during triage nuked the AI
        // queue every ~30–90s). New mail still arrives via sync→enqueueBatch (dedup-safe).
        if runResumeRecovery {
            await Self.cancelAllInFlightQueues(inboxOnly: inboxOnly)
            // Connections are now fresh — allow the next continuous-foreground push to skip.
            Self.didBackgroundSinceRecovery.withLock { $0 = false }
            stepLog("step1 cancelAllInFlight")
        } else {
            stepLog("step1 cancelAllInFlight SKIPPED (verified continuous-foreground)")
        }

        // 2. Recover incomplete headers (headerComplete=0 → FTS index → set flag).
        // Kept on the critical path: crash-recovery for rows GRDB has but FTS doesn't.
        await manager.syncEngine.recoverIncompleteHeaders()
        stepLog("step2 recoverIncompleteHeaders")
        BootProfiler.mark("syncStartup: recoverIncompleteHeaders done (critical-path scan)")

        // 3. Repopulate queues — detached so sync starts immediately.
        // Sync never reads from the queues (only enqueues, dedup-safe), so repopulate
        // has no dependency on sync and vice-versa. `.budget`/`.full` drain paths await
        // this task before awaitDrain / isIdle checks so they don't see a false-empty
        // queue just because repopulate hasn't run yet.
        let repopulateT0 = CFAbsoluteTimeGetCurrent()
        let repopulateTask = Task {
            if inboxOnly {
                async let bodyRepop: Void = ActiveBodyQueue.shared.repopulateFromDatabase()
                async let aiRepop: Void = ActiveAIQueue.shared.repopulateFromDatabase()
                // Memory embedding queue: repopulate even on inbox-only cycles so
                // newly-indexed turns get their embeddings. Cheap — partial index
                // on embeddingComplete=0 keeps this O(pending).
                async let memRepop: Void = BackfillMemoryEmbeddingQueue.shared.repopulateFromDatabase()
                _ = await (bodyRepop, aiRepop, memRepop)
            } else {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await ActiveBodyQueue.shared.repopulateFromDatabase() }
                    group.addTask { await BackfillBodyQueue.shared.repopulateFromDatabase() }
                    group.addTask { await ActiveAIQueue.shared.repopulateFromDatabase() }
                    group.addTask { await BackfillEmbeddingQueue.shared.repopulateFromDatabase() }
                    group.addTask { await BackfillAIQueue.shared.repopulateFromDatabase() }
                    // Memory self-heal: Stage A (per-turn FTS+meta set-diff, both
                    // A−B missing and B−A orphans) + Stage B (embedding queue
                    // repopulate). Non-throwing — logs internally.
                    // See ADR-IOS-034.
                    group.addTask { await MemorySelfHealDriver.runStageAPlusB() }
                }
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - repopulateT0) * 1000)
            BackgroundSyncLogger.log("syncStartup: repopulate done in \(ms)ms (inboxOnly=\(inboxOnly))")
        }
        stepLog("step3 spawned repopulateTask")

        // 3b. Delayed FTS self-heal — moved off the critical path (each call fetches
        // thousands of MessageHeader rows + probes the FTS sidecar DB). These only
        // repair historical orphans from old migration bugs; in steady state they find
        // 0 rows but the scan still costs. Sleeping 5s lets the UI settle and first
        // sync burst land before we do the expensive maintenance scan.
        // Caveat: if an FTS orphan exists and the body queue dispatches it BEFORE the
        // heal completes, that dispatch will no-op and re-queue on the next cycle.
        // Acceptable since orphans are rare.
        let healTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            let hT0 = CFAbsoluteTimeGetCurrent()
            await manager.syncEngine.selfHealFTSBodyMembership()
            let hT1 = CFAbsoluteTimeGetCurrent()
            await manager.syncEngine.selfHealBackfillFTSMembership()
            let hT2 = CFAbsoluteTimeGetCurrent()
            // One-time FTS↔GRDB reconciliation: orphan prune + full-history
            // membership heal (UserDefaults-gated; no-op after its first
            // clean completion).
            await manager.syncEngine.oneTimeFTSReconciliation()
            let hT3 = CFAbsoluteTimeGetCurrent()
            // One-time reverse heal: pending rows whose FTS body already exists
            // (pre-fix asset-eviction victims) flip back to bodyComplete=1
            // without refetching (UserDefaults-gated).
            await manager.syncEngine.oneTimeBodyCompleteRestore()
            let hT4 = CFAbsoluteTimeGetCurrent()
            BackgroundSyncLogger.log("syncStartup: delayed self-heal done — 2b=\(Int((hT1-hT0)*1000))ms 2c=\(Int((hT2-hT1)*1000))ms prune=\(Int((hT3-hT2)*1000))ms restore=\(Int((hT4-hT3)*1000))ms")
        }
        _ = healTask // fire-and-forget; no waiters
        stepLog("step3b spawned delayed selfHeal (+5s)")

        // 4. Fire sync as independent parallel work — NEVER blocks queue drain.
        // Sync discovers new messages and enqueues them via enqueueBatch.
        // If offline, sync returns quickly. If slow server, drain still proceeds.
        let syncTask = Task { [self] in
            let syncT0 = CFAbsoluteTimeGetCurrent()
            // Same gate as step1. In continuous-foreground, connections are live: marking
            // providers dirty drains IMAP pools, kills IDLE, and force-reconnects the
            // DeviceSync WebSocket — all wasted, and the source of the spurious
            // "[DeviceSync] Force reconnect — network interface changed" storms on a stable
            // foreground network. Genuine WiFi↔cellular reconnects are NetworkMonitor's job.
            if runResumeRecovery {
                await manager.markAllProvidersDirty()
                BackgroundSyncLogger.log("syncTask[+\(Int((CFAbsoluteTimeGetCurrent() - syncT0)*1000))ms]: markAllProvidersDirty done")
            } else {
                BackgroundSyncLogger.log("syncTask: markAllProvidersDirty SKIPPED (foreground — connections live)")
            }
            async let pendingDrain: Void = { _ = await self.drainPendingSyncs() }()
            async let syncAll: Void = { await self.backgroundPoll(inboxOnly: inboxOnly) }()
            _ = await (pendingDrain, syncAll)
            let syncMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            BackgroundSyncLogger.log("syncStartup: sync done in \(syncMs)ms (inboxOnly=\(inboxOnly))")
            BootProfiler.mark("syncStartup: backgroundPoll (sync all accounts) done in \(syncMs)ms")

            // Re-mirror historyIds after sync advances cursors — NSE needs fresh values
            NSEDataBridge.mirrorLastHistoryIds()

            // Drain pending ops + outbox + calendar (needs connections from markDirty)
            await manager.drainPendingQueue()
            await manager.drainOutbox()
            await manager.drainCalendarQueue()
        }
        stepLog("step4 spawned syncTask — RETURNING")

        // 5. Drain based on mode — runs in PARALLEL with sync (step 4).
        // Sync never blocks drain. If offline, sync returns fast. If slow, drain still proceeds.
        // As sync discovers new messages, it enqueues them and queues pick them up.
        switch drain {
        case .none:
            // Foreground: sync + queues run independently, return immediately.
            break

        case .budget(let seconds):
            // BG/push: drain until budget exhausted. Sync runs alongside.
            // Await repopulate first so isIdle doesn't lie about empty queues.
            _ = await repopulateTask.value
            let deadline = t0 + seconds
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            if remaining > 2.0 {
                BackgroundSyncLogger.log("syncStartup: draining body/AI with \(Int(remaining))s budget")
                while CFAbsoluteTimeGetCurrent() < deadline && !Task.isCancelled {
                    let bodyDone = await ActiveBodyQueue.shared.isIdle
                    let aiDone = await ActiveAIQueue.shared.isIdle
                    if bodyDone && aiDone { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            // Wait for sync to finish within budget (don't orphan it)
            _ = await syncTask.value

        case .full:
            // BGProcessing: wait for everything. Sync runs alongside queue drain.
            // Await repopulate first so awaitDrain doesn't return against an unloaded queue.
            _ = await repopulateTask.value
            // Body must complete first (feeds AI/embedding)
            await ActiveBodyQueue.shared.awaitDrain()
            await BackfillBodyQueue.shared.awaitDrain()
            // AI + embedding in parallel
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await ActiveAIQueue.shared.awaitDrain() }
                group.addTask { await BackfillEmbeddingQueue.shared.awaitDrain() }
                // Memory embedding queue — same parallel slot as email.
                // See ADR-IOS-034.
                group.addTask { await BackfillMemoryEmbeddingQueue.shared.awaitDrain() }
            }
            // Background AI refinements (teach events, KB refine) — runs after
            // user-visible inbox AI so it doesn't steal the BG budget from it.
            // BackendClient's 32-slot LLM semaphore has capacity for parallelism,
            // but sequential-after guarantees completion priority.
            await BackfillAIQueue.shared.awaitDrain()
            // Ensure sync completed
            _ = await syncTask.value

            // Backfill walk (WiFi/LPM gated)
            let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            let wifiOnly = UserDefaults.standard.object(forKey: Self.wifiOnlyKey) as? Bool ?? true
            var skipBackfill = isLowPowerMode
            if !skipBackfill && wifiOnly {
                let onWiFi = await Self.isOnWiFi()
                if !onWiFi { skipBackfill = true }
            }
            if !skipBackfill && !Task.isCancelled {
                let accounts = (try? await dbPool.read { db in
                    try Account.filter(Column("isActive") == true).fetchAll(db)
                }) ?? []
                let backfillDeadline = Date(timeIntervalSinceNow: 5 * 60)
                await withTaskGroup(of: Void.self) { group in
                    for account in accounts {
                        group.addTask { _ = await self.manager.runBackfill(account: account, deadline: backfillDeadline) }
                    }
                }
            }

            // Refresh notification dedup TTL
            await ProactiveNotifyService.shared.refreshActiveReminders()

            // Storage maintenance (WAL-only here — BodyAssetStore is foreground-only,
            // ADR-IOS-046). BGProcessing is opportunistic and not guaranteed to run, so
            // the foreground poll runs this same WAL pass too; both converge here. Runs
            // off-main and abandons on suspend at each step.
            if !Task.isCancelled {
                let undoIds = Set(UndoService.shared.undoStack.flatMap { $0.messages.map(\.id) })
                await Task.detached(priority: .utility) {
                    // `.background`, matching the foreground caller
                    // (`SyncEngine.scheduleMaintenanceInBackground`). The pass ends in
                    // a whole-database `ANALYZE` that takes SQLite's single writer, so
                    // the DEFAULT pool (`AppDatabase.dbPool`, `.priority`) would let a
                    // BGProcessing housekeeping write be taken ahead of a user-action
                    // write already queued in `DatabaseWriteQueue`.
                    await SyncEngine.runWALMaintenance(
                        dbPool: AppDatabase.backgroundPool, includePrune: true,
                        undoProtectedBodyIds: undoIds
                    )
                }.value
            }
        }
    }

    // MARK: - Tier 1: Foreground Polling

    /// One-shot guard for the first-foreground settle (see `startForegroundPolling`).
    /// Reset only by a process restart, so exactly the first foreground after a
    /// cold launch pays the settle; warm returns within the same process skip it.
    private var didFirstForegroundSettle = false

    func startForegroundPolling() {
        // On return from background (or fresh launch after iOS killed the process),
        // reconnect providers (TCP sockets go stale during device sleep) and do an
        // immediate sync so new messages are visible right away.
        // poll() has an isPollActive guard so this is safe even if RootView.task's
        // initial sync is still running — one will no-op.
        BackgroundSyncLogger.log("startForegroundPolling: ENTER (pollActive=\(isPollActive), startupInFlight=\(isStartupInFlight))")
        // Mark EVERY foreground call (not just the ones that pass the herd gate) so a
        // wifi-off capture shows how often a foreground lands while a slow sync still
        // holds the gate — the exact window the ungated merge below now covers.
        BootProfiler.mark("⟳ startForegroundPolling CALLED (herdInFlight=\(isStartupInFlight), pollActive=\(isPollActive))")

        // ── ALWAYS, UNGATED: surface already-available mail on EVERY foreground ──
        // The NSE merge + inbox reload signal must NOT live behind the heavy herd's
        // `isStartupInFlight` gate. On a slow (mobile) network `poll()` holds that
        // gate for 60s+ (boot logs: poll() = 63s, fullSync = 70s), and a foreground
        // arriving in that window used to fall straight through to the timer guard —
        // NO merge, NO reload — so newly-pushed (NSE-staged) mail stayed hidden and
        // "Updated … ago" stayed stale until the in-flight sync finished. The merge
        // is the PRIVILEGED single-flight (NSEMergeCoordinator serializes it), so
        // running it concurrently with an in-flight poll is safe. This realizes the
        // rule: the update signal goes right after the merge, independent of the herd.
        Task {
            // Instant once the inbox has painted (warm foreground); on a cold-launch
            // first foreground this waits for first paint, same as the herd gate.
            await AppStartup.shared.awaitLaunchReady(background: false)
            // Emits its OWN immediate `.inboxDataDidChange` (debounce-bypass flag)
            // when it stages new mail.
            await NSEDataBridge.mergeNSEStagingData()
            // Generic debounced repaint from whatever is already in GRDB (e.g. a
            // background-cycle merge that wrote while we were off-screen). Coalesces
            // with the merge's immediate post via the inbox single-flight reload.
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }

        // ── GATED: the heavy herd (sync / push resub / poll) — one cycle at a time ──
        if !isStartupInFlight {
            isStartupInFlight = true
            Task {
                defer { isStartupInFlight = false }
                let fgT0 = CFAbsoluteTimeGetCurrent()
                func fgStep(_ label: String) {
                    let ms = Int((CFAbsoluteTimeGetCurrent() - fgT0) * 1000)
                    BackgroundSyncLogger.log("fgReturn[+\(ms)ms]: \(label)")
                }
                fgStep("Task body start")
                BootProfiler.mark("startForegroundPolling enter (firstForeground=\(!didFirstForegroundSettle))")
                // On the FIRST foreground after a cold launch, BLOCK the herd (sync,
                // queue repopulation, push resub, poll) on the REAL first-paint signal
                // — not a fixed timer. The quick merge above already ran ungated; this
                // gate only holds back the heavy network work. Warm returns skip it.
                if !didFirstForegroundSettle {
                    didFirstForegroundSettle = true
                    await AppStartup.shared.awaitLaunchReady(background: false)
                    fgStep("first-paint gate cleared")
                    BootProfiler.mark("startForegroundPolling: first paint reached — herd starting")
                }
                await syncStartup(inboxOnly: false, drain: .none)
                fgStep("syncStartup returned")
                BootProfiler.mark("startForegroundPolling: syncStartup returned (herd spawned)")
                // Re-subscribe push on foreground return.
                // subscribeAllAccounts() calls registerDeviceWithWorker() internally at the end,
                // so no separate registerDeviceWithWorker() call needed here.
                // This also keeps the nse-vs-silent registration in sync with iOS
                // notification settings: subscribeAccount reads visualAlertsEnabled()
                // live, and settings can only change while the app is backgrounded,
                // so this foreground resub always re-registers with the current
                // capability (worker upserts idempotently). See PLAN_NSE_ENHANCE §3.3.
                await PushNotificationService.shared.subscribeAllAccounts()
                // Non-interactive check: does the push worker have a pending
                // classification error for any of our Gmail/Outlook accounts?
                // Posts `.pushConsentErrorsDetected` if so; UI surfaces
                // banner.
                Task {
                    await PushNotificationService.shared.checkPushConsentStatusForForeground()
                }
                await poll()
                BootProfiler.mark("startForegroundPolling: poll() done (foreground sync pass complete)")
            }
        } else {
            // A previous foreground's herd is still grinding through its sync/poll.
            // We DON'T start a second one — but the ungated merge above already ran,
            // so a foreground during a slow sync still surfaces freshly-staged mail.
            BootProfiler.mark("startForegroundPolling: herd SKIPPED (sync already in flight) — ungated merge still ran")
        }

        guard timer == nil else { return }
        print("[SyncScheduler] Starting foreground polling (every \(Int(foregroundInterval))s)")
        timer = Timer.scheduledTimer(withTimeInterval: foregroundInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.poll()
            }
        }

        // Re-schedule BGTasks on every foreground launch in case iOS purged them
        ensureBackgroundTasksScheduled()
        // IMAP IDLE is managed by IMAPProvider on the primary connection.
        // Tell all IMAP providers to start IDLE on foreground.
        startImapIdle()
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        stopImapIdle()
        // Cancel the foreground maintenance task so its detached `.utility` body can't
        // be resumed by the cooperative pool inside a later BGTask window and run its
        // NON-WAL BodyAssetStore read while the process suspends (0xdead10cc). The
        // `isAppActive` gate in `runBodyAssetMaintenance` is the hard guarantee; this
        // frees the task promptly. ADR-IOS-046.
        Task { await manager.syncEngine.cancelMaintenance() }
        BackgroundSyncLogger.log("stopPolling: app going to background (pollActive=\(isPollActive))")
        print("[SyncScheduler] Stopped polling")
    }

    // MARK: - IMAP IDLE (Foreground Only)

    /// Start IMAP IDLE on all IMAP/iCloud providers' primary connections.
    /// IDLE runs on the primary (action) connection — no extra connections needed.
    func startImapIdle() {
        Task {
            let accounts: [Account]
            do {
                accounts = try await AppDatabase.dbPool.read { db in
                    try Account
                        .filter(Column("isActive") == true)
                        .filter(["imap", "icloud"].contains(Column("provider")))
                        .fetchAll(db)
                }
            } catch {
                print("[SyncScheduler:IDLE] Failed to load IMAP accounts: \(error)")
                return
            }
            for account in accounts {
                guard let provider = await manager.provider(for: account) as? IMAPProvider else { continue }
                await provider.startIdle { [weak self] event, email in
                    guard let self else { return }
                    switch event {
                    case .vanished(let uidSet):
                        // RFC 7162: the server NAMES the deleted UIDs — consume
                        // them for targeted deletes (ADR-IOS-051 Phase 1), then
                        // still poll so counts/flags refresh through the normal
                        // sync path.
                        let uids = uidSet.toArray().map { UInt32($0.value) }
                        if DebugModeManager.isLoggingEnabled() {
                            print("[SyncScheduler:IDLE] \(email) event: vanished (\(uids.count) UIDs) — targeted delete + syncing")
                        }
                        await self.manager.syncEngine.handleVanishedUIDs(accountEmail: email, uids: uids)
                        await self.backgroundPoll(accountEmail: email)
                    case .exists, .expunge:
                        // .expunge carries a SEQUENCE number, not a UID — it
                        // cannot be mapped to a local row safely; keep it as a
                        // generic poll trigger (ADR-IOS-051).
                        print("[SyncScheduler:IDLE] \(email) event: \(event) — syncing")
                        await self.backgroundPoll(accountEmail: email)
                    default:
                        break
                    }
                }
            }
            if !accounts.isEmpty {
                print("[SyncScheduler:IDLE] Started IDLE for \(accounts.count) IMAP account(s)")
            }
        }
    }

    /// Stop IMAP IDLE on all IMAP/iCloud providers.
    func stopImapIdle() {
        Task {
            let accounts: [Account]
            do {
                accounts = try await AppDatabase.dbPool.read { db in
                    try Account
                        .filter(Column("isActive") == true)
                        .filter(["imap", "icloud"].contains(Column("provider")))
                        .fetchAll(db)
                }
            } catch { return }
            for account in accounts {
                guard let provider = await manager.provider(for: account) as? IMAPProvider else { continue }
                await provider.stopIdle()
            }
            print("[SyncScheduler:IDLE] Stopped all IDLE sessions")
        }
    }

    // MARK: - Unified In-Flight Cancellation

    /// Cancel in-flight Tasks across all body/AI/embedding queues. Single
    /// canonical wind-down used by:
    /// - `syncStartup` — clear stale frozen tasks at the start of a new cycle.
    /// - `BGAppRefresh` / `BGProcessing` expiration handlers — iOS warned us;
    ///   stop in-flight LLM and SQLite work before suspension to avoid
    ///   RUNNINGBOARD 0xdead10cc and to be a "nicely behaving" background app.
    /// - `ActiveAIQueue.executeJob` per-job bgTask expiration — same idea
    ///   scoped to a single AI job's grace window.
    ///
    /// `inboxOnly` mirrors `syncStartup`'s axis: BGAppRefresh / push paths only
    /// touch inbox-scope queues, so we skip backfill and embedding queues.
    /// Static so it's reachable from BGTask expiration handlers without
    /// captures.
    static func cancelAllInFlightQueues(inboxOnly: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await ActiveBodyQueue.shared.cancelAllInFlight() }
            group.addTask { await ActiveAIQueue.shared.cancelAllInFlight() }
            if !inboxOnly {
                group.addTask { await BackfillBodyQueue.shared.cancelAllInFlight() }
                group.addTask { await ActiveEmbeddingQueue.shared.cancelAllInFlight() }
                group.addTask { await BackfillEmbeddingQueue.shared.cancelAllInFlight() }
                group.addTask { await BackfillAIQueue.shared.cancelAllInFlight() }
                group.addTask { await BackfillMemoryEmbeddingQueue.shared.cancelAllInFlight() }
            }
        }
    }

    // MARK: - Background Grace Period

    /// Request a background grace period via `beginBackgroundTask` so in-flight work
    /// can finish when the app transitions to background.
    ///
    /// After in-flight work completes, holds the app alive for an additional 3s
    /// "self-notification catch" window. During this window, any push notifications
    /// triggered by the app's own actions (archive, delete, etc.) arrive and are
    /// handled by `willPresent` (which suppresses them), preventing the NSE from
    /// showing spurious "Inbox updated" passive notifications.
    ///
    /// Budget management: monitors `backgroundTimeRemaining` to ensure we never
    /// exceed iOS's budget. Stops work when remaining < 5s, holds until remaining < 2s.
    func requestBackgroundGracePeriod() {
        // Don't waste background task budget if no work is in-flight
        let hasWork = isPollActive
        guard hasWork else {
            print("[SyncScheduler] Grace period skipped — no in-flight work")
            return
        }
        BackgroundSyncLogger.log("Grace period REQUESTED")
        let ended = Mutex(false)
        let bgTaskId = Mutex<UIBackgroundTaskIdentifier>(.invalid)
        let taskId = UIApplication.shared.beginBackgroundTask(withName: "backfill-grace") {
            // Expiration handler — end immediately to avoid iOS killing the app
            if !ended.withLock({ let was = $0; $0 = true; return was }) {
                let id = bgTaskId.withLock { $0 }
                UIApplication.shared.endBackgroundTask(id)
                print("[SyncScheduler] Grace expiration handler fired")
            }
        }
        bgTaskId.withLock { $0 = taskId }
        guard bgTaskId.withLock({ $0 }) != .invalid else {
            print("[SyncScheduler] Failed to begin background task for grace period")
            return
        }
        let taskIdValue = bgTaskId.withLock { $0 }.rawValue
        print("[SyncScheduler] Background grace period started, bgTaskId=\(taskIdValue)")

        Task { @MainActor in
            // Phase 1: Let in-flight work finish. Poll every 1s until work is done
            // or we're running low on time (< 7s remaining = 5s catch + 2s safety).
            while isPollActive {
                let remaining = UIApplication.shared.backgroundTimeRemaining
                if remaining < 7 {
                    print("[SyncScheduler] Grace: stopping early, remaining=\(Int(remaining))s")
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }

            // Phase 2: Self-notification catch window.
            // Hold app alive for 5s so that push notifications from our own
            // actions (Pub/Sub → 3s debounce → push) arrive at willPresent and are
            // suppressed, instead of hitting the NSE after we suspend.
            // 5s = 3s debounce + ~2s network round-trip.
            let catchDuration = 5.0
            let holdUntil = CFAbsoluteTimeGetCurrent() + catchDuration
            while CFAbsoluteTimeGetCurrent() < holdUntil {
                let remaining = UIApplication.shared.backgroundTimeRemaining
                if remaining < 2 {
                    print("[SyncScheduler] Grace: catch window cut short, remaining=\(Int(remaining))s")
                    break
                }
                try? await Task.sleep(for: .seconds(0.5))
            }

            if !ended.withLock({ let was = $0; $0 = true; return was }) {
                let id = bgTaskId.withLock { $0 }
                UIApplication.shared.endBackgroundTask(id)
                print("[SyncScheduler] Background grace period ended, bgTaskId=\(id.rawValue)")
            }
        }
    }

    /// Re-schedule both BGTasks in case iOS purged them.
    /// Called on each foreground return to ensure continuous background execution.
    /// Re-submitting replaces any existing pending request (safe to call repeatedly).
    func ensureBackgroundTasksScheduled() {
        BackgroundSyncLogger.log("ensureBackgroundTasksScheduled: re-submitting BGAppRefresh + BGProcessing")
        scheduleBackgroundSync()
        scheduleBackgroundProcessing()
    }

    /// Manual trigger (e.g., from background task or on-demand)
    func pollNow() async {
        await poll()
    }

    /// Lightweight background sync: delta-syncs active accounts in parallel.
    /// Each account handles its own connection (ensureConnected: seed pool if needed, no-op HTTP).
    /// - Parameter inboxOnly: When true, IMAP accounts only check inbox folder (BGAppRefresh path).
    /// - Parameter scheduleProcessing: When false, skip scheduling BGProcessingTask (Phase 4 safety-net).
    /// - Parameter accountEmail: When set, only sync this specific account (push path).
    /// Returns true if the sync actually executed (not skipped due to no network or overlap).
    /// Callers use this to decide whether to dequeue pending sync entries.
    @discardableResult
    func backgroundPoll(inboxOnly: Bool = false, scheduleProcessing: Bool = true, accountEmail: String? = nil) async -> Bool {
        // No overlap guards — delta syncs are idempotent and ProviderWorkQueue
        // handles per-account concurrency. Two concurrent syncs for the same account
        // just queue through the work queue.
        guard NetworkMonitor.checkConnected() else {
            BackgroundSyncLogger.log("backgroundPoll: SKIPPED reason=noNetwork (account=\(accountEmail ?? "all"))")
            return false
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let anyChanges: Bool
        if let email = accountEmail {
            anyChanges = await manager.backgroundSyncForAccount(email: email)
        } else {
            anyChanges = await manager.backgroundSyncAll(inboxOnly: inboxOnly)
        }

        lastPollTime = Date()

        // Always notify inbox UI after background sync completes.
        // Even when anyChanges=false (e.g. delta sync timed out after inserting messages),
        // the push itself implies new data. InboxViewModel's 500ms throttle prevents spam.
        NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)

        // Only schedule BGProcessingTask when there's actual work to do.
        // Prevents the infinite reschedule loop (BGProcessingTask Phase 4 → backgroundPoll → schedule → repeat).
        if scheduleProcessing {
            let bodyIdle = await ActiveBodyQueue.shared.isIdle
            let aiIdle = await ActiveAIQueue.shared.isIdle
            if anyChanges || !bodyIdle || !aiIdle {
                scheduleBackgroundProcessing()
            }
        }

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        BackgroundSyncLogger.log("backgroundPoll: done in \(elapsed)ms (changes=\(anyChanges), account=\(accountEmail ?? "all"))")

        // Re-mirror historyIds after sync advances cursors — NSE needs fresh values
        if anyChanges { NSEDataBridge.mirrorLastHistoryIds() }

        // Revalidate AI subscription gate if closed
        await Self.revalidateAISubscriptionGate()

        // Stamp the sync-status timestamp so the "Updated N min ago" subtitle
        // reflects background / push / startup (NSE-coalesce) delta syncs too —
        // not just pull-to-refresh (InboxViewModel.performSync) and the
        // foreground poll tier (poll()). This is the only sync tier that never
        // stamped, which left the subtitle stale after a silent-push / NSE wake.
        // Stamp on completion-with-connectivity even when nothing changed (the
        // no-network case returns false earlier and is correctly skipped).
        AccountManagerState.shared.lastSyncFailed = false
        AccountManagerState.shared.lastSyncCompletedAt = Date()

        return true
    }

    /// TEMP: Kill switch to verify sync polling is the source of swipe lag. Remove after testing.
    static let syncDisabled = false

    private func poll() async {
        if Self.syncDisabled { return }
        // Pause all sync while demo mode is active — the user's real accounts must
        // not sync or churn the DB/UI underneath the demo (incl. demo entered from
        // the debug menu while logged in). Resumes on the next poll after exit.
        if DemoModeStore.shared.isActive {
            BackgroundSyncLogger.log("poll: SKIPPED — demo mode active")
            return
        }
        guard !isPollActive else {
            BackgroundSyncLogger.log("poll: SKIPPED — already polling")
            return
        }
        isPollActive = true
        defer { isPollActive = false }
        BackgroundSyncLogger.log("poll: START (foreground)")

        // During fast sync mode, skip delta syncs — they hold the IMAP lock for
        // STATUS checks across all folders, causing pauses in backfill. Still drain
        // pending ops and outbox so user actions are processed.
        var anyChanges = false
        if !AccountManagerState.shared.fastSyncModeActive {
            // Header sync — phase updates published per-account by foregroundSyncOne.
            let result = await manager.foregroundSyncAll()
            anyChanges = result.hadChanges
            AccountManagerState.shared.lastSyncFailed = result.failed
            if !result.failed {
                AccountManagerState.shared.lastSyncCompletedAt = Date()
            }
            // Clear phases after a short delay so the terminal per-account phase
            // emission has a chance to render through the subtitle's throttle
            // before being wiped. Without this the phase lifetime is sub-ms.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                AccountManagerState.shared.clearSyncPhases()
            }
        }

        // Run maintenance once per poll cycle (not per account).
        await manager.syncEngine.scheduleMaintenanceInBackground(includePrune: true)

        let pd0 = CFAbsoluteTimeGetCurrent()
        await manager.drainPendingQueue()
        let pd1 = CFAbsoluteTimeGetCurrent()
        await manager.drainOutbox()
        let pd2 = CFAbsoluteTimeGetCurrent()
        await manager.drainCalendarQueue()
        let pd3 = CFAbsoluteTimeGetCurrent()
        lastPollTime = Date()
        // Badge + unread counts already updated by UnreadCountManager during sync.
        print("[SyncScheduler] Post-sync: drain=\(Int((pd1-pd0)*1000))ms outbox=\(Int((pd2-pd1)*1000))ms calendar=\(Int((pd3-pd2)*1000))ms")
        print("[SyncScheduler] Poll completed at \(Date()) (changes: \(anyChanges))")
        BackgroundSyncLogger.log("poll: END (foreground, changes=\(anyChanges))")

        // Revalidate AI subscription gate if closed
        await Self.revalidateAISubscriptionGate()
    }

    // MARK: - Tier 2: Background App Refresh

    nonisolated static let backgroundTaskIdentifier = "ai.tabmail.sync"
    nonisolated static let backgroundAITaskIdentifier = "ai.tabmail.ai-processing"

    /// Schedule BGAppRefresh unconditionally (replaces any existing pending request).
    /// Used by: BGAppRefresh completion, foreground return, no-network skip, NetworkMonitor restore.
    func scheduleBackgroundSync() {
        submitBGAppRefreshRequest(caller: "schedule")
    }

    /// Schedule BGAppRefresh only if no request is already pending.
    /// Used by: push handler — avoids resetting the timer on every push,
    /// which would perpetually push BGAppRefresh forward if pushes arrive frequently.
    func scheduleBackgroundSyncIfNeeded() {
        BGTaskScheduler.shared.getPendingTaskRequests { [weak self] requests in
            let hasPending = requests.contains { $0.identifier == Self.backgroundTaskIdentifier }
            if !hasPending {
                Task { @MainActor in
                    self?.submitBGAppRefreshRequest(caller: "scheduleIfNeeded")
                }
            } else {
                BackgroundSyncLogger.log("BGAppRefresh scheduleIfNeeded: already pending, skipping")
            }
        }
    }

    private func submitBGAppRefreshRequest(caller: String) {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        let intervalMin = Int(SyncConfig.bgAppRefreshIntervalSeconds / 60)
        request.earliestBeginDate = Date(timeIntervalSinceNow: SyncConfig.bgAppRefreshIntervalSeconds)
        do {
            try BGTaskScheduler.shared.submit(request)
            BackgroundSyncLogger.log("BGAppRefresh SCHEDULED (earliest: +\(intervalMin)min, caller=\(caller))")
            BackgroundSyncLogger.logBGAppRefresh("SCHEDULED (earliest: +\(intervalMin)min, caller=\(caller))")
            print("[SyncScheduler] Background sync scheduled (\(caller))")

            // Verify iOS actually has the task pending
            BGTaskScheduler.shared.getPendingTaskRequests { requests in
                let ids = requests.map(\.identifier)
                let hasBGRefresh = ids.contains(Self.backgroundTaskIdentifier)
                let hasBGProcessing = ids.contains(Self.backgroundAITaskIdentifier)
                BackgroundSyncLogger.log("BGTask pending verify: refresh=\(hasBGRefresh) processing=\(hasBGProcessing) total=\(ids.count)")
            }
        } catch {
            BackgroundSyncLogger.log("BGAppRefresh SCHEDULE FAILED: \(error) (caller=\(caller))")
            BackgroundSyncLogger.logBGAppRefresh("SCHEDULE FAILED: \(error)")
            print("[SyncScheduler] Failed to schedule background sync: \(error)")
        }
    }

    // BGTask handler methods are `nonisolated` because the expiration handler runs
    // on an arbitrary Apple-internal queue. In Swift 6, ALL locals in a @MainActor
    // method are main-actor-isolated — accessing them from the @Sendable expiration
    // handler triggers a dynamic isolation trap (EXC_BREAKPOINT). Making the method
    // nonisolated removes actor isolation from locals. BGTaskContext (@unchecked
    // Sendable class) holds shared state so it can be captured across isolation
    // domains without triggering region-based sending errors. The actual work runs
    // in Task { @MainActor in }.

    /// Self-imposed BGAppRefresh budget. We terminate our own work before iOS
    /// fires the expiration handler, so iOS sees us as well-behaved.
    /// iOS budget is ~30s; we leave 5s margin for cleanup + setTaskCompleted.
    private static let bgAppRefreshBudgetSeconds: TimeInterval = 25

    nonisolated func handleBackgroundSync(_ task: BGAppRefreshTask) {
        let networkConnected = NetworkMonitor.checkConnected()
        print("[SyncScheduler] handleBackgroundSync() enter, thread=\(Thread.current), isMainThread=\(Thread.isMainThread)")
        BackgroundSyncLogger.log("BGAppRefresh STARTED (network=\(networkConnected))")
        BackgroundSyncLogger.logBGAppRefresh("STARTED (network=\(networkConnected))")

        // Opportunistic delivered-notification cleanup.
        Task { await NotificationCleanupService.sweepExpired() }

        let ctx = BGTaskContext(label: "sync")

        // Set expiration handler BEFORE creating the Task so `task` is
        // used (property set) then sent (captured in Task) — satisfies
        // Swift 6 region-based "no use after send" rule.
        task.expirationHandler = {
            print("[SyncScheduler] SYNC expiration handler fired, thread=\(Thread.current), isMainThread=\(Thread.isMainThread)")
            BackgroundSyncLogger.log("BGAppRefresh EXPIRED (iOS killed)")
            BackgroundSyncLogger.logBGAppRefresh("EXPIRED (iOS killed)")
            ctx.expire()
            // Wind down in-flight LLM/SQLite work in the inbox-scope queues so
            // suspension doesn't catch a SQLite write mid-flight (RUNNINGBOARD
            // 0xdead10cc). ctx.expire() already cancels the syncStartup Task,
            // but actor-owned inFlightTasks aren't its children — cancel them
            // explicitly via the unified helper.
            Task { await SyncScheduler.cancelAllInFlightQueues(inboxOnly: true) }
            // Mechanical 0xdead10cc backstop (ADR-IOS-041): suspend GRDB
            // databases NOW — cooperative cancellation above is asynchronous
            // and can't guarantee no lock is held when the process freezes.
            // Stragglers get SQLITE_ABORT and retry on next wake.
            DatabaseSuspension.postSuspendImmediately(reason: "BGAppRefresh expired")
            // Safety net: complete the task and reschedule even if the sync Task
            // never executed. Without this, iOS counts incomplete tasks as failures
            // and permanently throttles BGAppRefresh.
            task.setTaskCompleted(success: false)
            Task { @MainActor in
                SyncScheduler.shared.scheduleBackgroundSync()
                // The success path always schedules BGProcessing (drains queued
                // work + finishes the FTS tokenizer migration); expiration must
                // too, or repeated expirations orphan that follow-up work.
                SyncScheduler.shared.scheduleBackgroundProcessing()
            }
            print("[SyncScheduler] SYNC expiration handler done")
        }
        print("[SyncScheduler] SYNC expirationHandler set")

        // BGAppRefreshTask: unified sync startup with budget-limited drain.
        let syncTask = Task { @MainActor in
            // Resume databases (may be suspended from a previous quiesce) for
            // the duration of this BGTask; re-arm quiesce on exit (ADR-IOS-041).
            DatabaseSuspension.shared.beginBackgroundWork("bg-app-refresh")
            defer { DatabaseSuspension.shared.endBackgroundWork("bg-app-refresh") }
            // A BGTask can cold-launch a terminated app into the BACKGROUND,
            // where the SwiftUI scene `.task` never runs — so the DB may not be
            // built yet. Build/await it before any `AppDatabase.dbPool` access
            // (which force-unwraps `AppDatabase.shared`) → otherwise crash.
            await AppStartup.shared.awaitLaunchReady(background: true)
            print("[SyncScheduler] SYNC Task body start")
            let pollActive = self.isPollActive
            BackgroundSyncLogger.logBGAppRefresh("Task body start (pollActive=\(pollActive), network=\(NetworkMonitor.checkConnected()))")

            // Skip background sync if a foreground poll is already running.
            if pollActive {
                BackgroundSyncLogger.log("BGAppRefresh SKIPPED (foreground poll active)")
                BackgroundSyncLogger.logBGAppRefresh("SKIPPED (foreground poll active)")
                print("[SyncScheduler] SYNC skipped — foreground poll active")
                task.setTaskCompleted(success: true)
                self.scheduleBackgroundSync()
                return
            }

            // No network → skip sync but always reschedule. Can't rely solely on
            // NetworkMonitor restore — its handler runs in Task { @MainActor in }
            // which may not execute if the app is suspended before MainActor drains.
            guard NetworkMonitor.checkConnected() else {
                BackgroundSyncLogger.log("BGAppRefresh SKIPPED (no network)")
                BackgroundSyncLogger.logBGAppRefresh("SKIPPED (no network)")
                print("[SyncScheduler] SYNC skipped — no network")
                task.setTaskCompleted(success: true)
                self.scheduleBackgroundSync()
                return
            }

            await self.syncStartup(inboxOnly: true, drain: .budget(Self.bgAppRefreshBudgetSeconds))

            // One-time FTS tokenizer migration (ADR-024) — small post-sync slice
            // only, so the refresh window's primary purpose (sync) is never
            // starved. No-op when nothing is stale; cancellation/expiration
            // winds down at a shard boundary.
            await SearchIndex.shared.rebuildStaleTokenizerShards(
                deadline: Date().addingTimeInterval(SearchConfig.retokenizeShortWindowBudgetSec))

            let success = !ctx.expired
            BackgroundSyncLogger.log("BGAppRefresh COMPLETED (success=\(success))")
            BackgroundSyncLogger.logBGAppRefresh("COMPLETED (success=\(success))")
            print("[SyncScheduler] SYNC completing: expired=\(ctx.expired), success=\(success)")
            // Only complete if expiration handler hasn't already done it
            if !ctx.expired {
                task.setTaskCompleted(success: true)
            }
            self.scheduleBackgroundSync() // Re-schedule for next cycle
            self.scheduleBackgroundProcessing() // Always schedule BGProcessing
            print("[SyncScheduler] SYNC Task body done")
        }
        ctx.setTask(syncTask)
        print("[SyncScheduler] handleBackgroundSync() exit")
    }

    // MARK: - Tier 3: Background Processing (long-running)

    /// Schedule BGProcessingTask to drain body/AI/embedding queues + backfill.
    /// Called immediately after BGAppRefreshTask or silent push completes,
    /// so queued work from the delta sync gets processed promptly.
    /// Also called on app background as a periodic fallback.
    func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundAITaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        // No artificial delay — run as soon as iOS allows.
        // When triggered after a BGAppRefreshTask/push, iOS typically runs it
        // promptly since the app is already awake.
        request.earliestBeginDate = nil
        do {
            try BGTaskScheduler.shared.submit(request)
            BackgroundSyncLogger.log("BGProcessing SCHEDULED")
            BackgroundSyncLogger.logBGProcessing("SCHEDULED")
            print("[SyncScheduler] Background processing scheduled")
        } catch {
            BackgroundSyncLogger.log("BGProcessing SCHEDULE FAILED: \(error.localizedDescription)")
            BackgroundSyncLogger.logBGProcessing("SCHEDULE FAILED: \(error.localizedDescription)")
            print("[SyncScheduler] Failed to schedule background processing: \(error)")
        }
    }

    /// Legacy name alias for call sites that haven't been updated yet.
    func scheduleBackgroundAIProcessing() {
        scheduleBackgroundProcessing()
    }

    nonisolated func handleBackgroundAIProcessing(_ task: BGProcessingTask) {
        print("[SyncScheduler] handleBackgroundProcessing() enter, thread=\(Thread.current), isMainThread=\(Thread.isMainThread)")
        BackgroundSyncLogger.log("BGProcessing STARTED")
        BackgroundSyncLogger.logBGProcessing("STARTED")
        let ctx = BGTaskContext(label: "processing")

        task.expirationHandler = {
            print("[SyncScheduler] PROCESSING expiration handler fired, thread=\(Thread.current), isMainThread=\(Thread.isMainThread)")
            BackgroundSyncLogger.log("BGProcessing EXPIRED (iOS killed)")
            BackgroundSyncLogger.logBGProcessing("EXPIRED (iOS killed)")
            ctx.expire()
            // Same wind-down rationale as the BGAppRefresh handler — but the
            // BGProcessing path runs the full backfill+embedding fan-out, so
            // cancel inboxOnly: false to also reach BackfillAIQueue / embedding
            // queues whose actor-owned Tasks ctx.expire() doesn't reach.
            Task { await SyncScheduler.cancelAllInFlightQueues(inboxOnly: false) }
            // Mechanical 0xdead10cc backstop (ADR-IOS-041) — see the
            // BGAppRefresh expiration handler for rationale.
            DatabaseSuspension.postSuspendImmediately(reason: "BGProcessing expired")
            task.setTaskCompleted(success: false)
            // Expiration means work remained (queues and/or tokenizer-migration
            // shards) — reschedule so it gets another window. The success path
            // reschedules conditionally; expiration is unconditional by definition.
            Task { @MainActor in
                SyncScheduler.shared.scheduleBackgroundProcessing()
            }
            print("[SyncScheduler] PROCESSING expiration handler done")
        }
        print("[SyncScheduler] PROCESSING expirationHandler set")

        // BGProcessingTask = heavy work. Drains body/AI/embedding queues populated
        // by the preceding BGAppRefreshTask or silent push delta sync.
        // Has minutes of execution time (vs 30s for BGAppRefreshTask).
        let processingTask = Task { @MainActor in
            // Resume databases (may be suspended from a previous quiesce) for
            // the duration of this BGTask; re-arm quiesce on exit (ADR-IOS-041).
            DatabaseSuspension.shared.beginBackgroundWork("bg-processing")
            defer { DatabaseSuspension.shared.endBackgroundWork("bg-processing") }
            // A BGTask can cold-launch a terminated app into the BACKGROUND,
            // where the SwiftUI scene `.task` never runs — so the DB may not be
            // built yet. Build/await it before any `AppDatabase.dbPool` access
            // (which force-unwraps `AppDatabase.shared`) → otherwise crash.
            await AppStartup.shared.awaitLaunchReady(background: true)
            let taskT0 = CFAbsoluteTimeGetCurrent()
            print("[SyncScheduler] PROCESSING Task body start")
            BackgroundSyncLogger.logBGProcessing("Task body start")

            // Enable turbo/fast-sync mode — BGProcessing has minutes of budget,
            // maximize throughput by skipping delta sync pauses and using aggressive backfill.
            AccountManagerState.shared.fastSyncModeActive = true
            defer { Task { @MainActor in AccountManagerState.shared.fastSyncModeActive = false } }

            // Full startup: sync + drain all queues + backfill + notification refresh
            await self.syncStartup(inboxOnly: false, drain: .full)

            // One-time FTS tokenizer migration (ADR-024) — AFTER sync so it never
            // steals resources from push/sync work. No-op when no stale shards
            // remain; resumes at the next unconverted shard; ctx.expire()
            // cancellation winds it down at a shard boundary (each shard is one
            // transaction). No deadline — BGProcessing has minutes of budget.
            await SearchIndex.shared.rebuildStaleTokenizerShards()

            let totalElapsed = Int((CFAbsoluteTimeGetCurrent() - taskT0) * 1000)
            let success = !ctx.expired
            BackgroundSyncLogger.log("BGProcessing COMPLETED in \(totalElapsed)ms (success=\(success))")
            BackgroundSyncLogger.logBGProcessing("COMPLETED in \(totalElapsed)ms (success=\(success))")
            print("[SyncScheduler] PROCESSING completing in \(totalElapsed)ms: expired=\(ctx.expired), success=\(success)")
            // Only complete if expiration handler hasn't already done it
            if !ctx.expired {
                task.setTaskCompleted(success: true)
            }
            // Only reschedule if queues still have work — prevents unconditional
            // rescheduling. Pending tokenizer-shard conversions count as work so
            // an interrupted migration gets another BG window.
            let bodyIdle = await ActiveBodyQueue.shared.isIdle
            let aiIdle = await ActiveAIQueue.shared.isIdle
            let staleShards = await SearchIndex.shared.hasStaleTokenizerShards()
            if !bodyIdle || !aiIdle || staleShards {
                self.scheduleBackgroundProcessing()
            }
            print("[SyncScheduler] PROCESSING Task body done")
        }
        ctx.setTask(processingTask)
        print("[SyncScheduler] handleBackgroundProcessing() exit")
    }

    /// Check if the device is currently on WiFi.
    /// NWPathMonitor.pathUpdateHandler can fire multiple times (races with cancel()),
    /// so guard the continuation with a Mutex to prevent double-resume (EXC_BREAKPOINT).
    nonisolated static func isOnWiFi() async -> Bool {
        print("[SyncScheduler] isOnWiFi() enter")
        let result: Bool
        do {
            result = try await withTimeout(seconds: SyncConfig.wifiCheckTimeoutSeconds) {
                await withCheckedContinuation { continuation in
                    let resumed = Mutex(false)
                    let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
                    monitor.pathUpdateHandler = { path in
                        let status = path.status
                        print("[SyncScheduler] WiFi pathUpdate: status=\(status), thread=\(Thread.current)")
                        monitor.cancel()
                        if !resumed.withLock({ let was = $0; $0 = true; return was }) {
                            print("[SyncScheduler] WiFi resuming continuation: satisfied=\(status == .satisfied)")
                            continuation.resume(returning: status == .satisfied)
                        } else {
                            print("[SyncScheduler] WiFi DUPLICATE callback suppressed")
                        }
                    }
                    monitor.start(queue: DispatchQueue(label: "wifi-check"))
                }
            }
        } catch {
            print("[SyncScheduler] WiFi check timed out after \(SyncConfig.wifiCheckTimeoutSeconds)s — assuming not on WiFi")
            return false
        }
        print("[SyncScheduler] isOnWiFi() = \(result)")
        return result
    }

    // MARK: - AI Subscription Gate

    /// Revalidate AI subscription gate via whoami if closed.
    private static func revalidateAISubscriptionGate() async {
        let gate = AISubscriptionGate.shared
        guard !gate.isActive else { return }
        // Capture the sign-in epoch BEFORE the network await: a response that
        // lands after a sign-out belongs to the previous account and must not
        // open the gate — or stamp routing authority — for the next one.
        let generation = gate.signInGeneration
        do {
            let info = try await BackendClient().fetchAccountInfo()
            if info.hasSubscription == true {
                // Open-only by design: this path exists to reopen a closed gate,
                // never to close one. Routing the OPEN direction through `apply`
                // additionally stamps the trial flag from the same authoritative
                // body, and cannot change the open-only semantics — the negative
                // branch still makes no call at all. With an active subscription
                // the derivation can only report "trial not ended", which is
                // exactly what this response says.
                gate.applyIfCurrentEpoch(info, fetchedInGeneration: generation)
            }
        } catch {
            print("[AISubscriptionGate] Revalidation failed: \(error)")
        }
    }
}
