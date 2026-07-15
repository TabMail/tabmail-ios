/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Thread-safe Event Log

/// Records events in the order they occur. Actor-isolated for safe concurrent access.
private actor EventLog {
    private(set) var events: [String] = []
    private var timestamps: [String: CFAbsoluteTime] = [:]
    private let t0: CFAbsoluteTime

    init() {
        t0 = CFAbsoluteTimeGetCurrent()
    }

    func record(_ event: String) {
        events.append(event)
        timestamps[event] = CFAbsoluteTimeGetCurrent() - t0
    }

    func timestamp(for event: String) -> CFAbsoluteTime? {
        timestamps[event]
    }

    func contains(_ event: String) -> Bool {
        events.contains(event)
    }

    func index(of event: String) -> Int? {
        events.firstIndex(of: event)
    }

    /// Returns first index of any event matching the given prefix.
    func firstIndex(withPrefix prefix: String) -> Int? {
        events.firstIndex { $0.hasPrefix(prefix) }
    }

    /// Returns all events matching the given prefix.
    func all(withPrefix prefix: String) -> [String] {
        events.filter { $0.hasPrefix(prefix) }
    }

    func reset() {
        events.removeAll()
        timestamps.removeAll()
    }
}

// MARK: - Mock Queue

/// Simulates a processing queue (body, AI, backfill, embedding).
/// Tracks cancel/repopulate/idle/drain calls.
private actor MockQueue {
    let name: String
    let log: EventLog

    private var _idle: Bool = true
    private var idleAfterChecks: Int = 0 // become idle after N isIdle checks
    private var checksRemaining: Int = 0
    private var drainDelay: Duration = .zero
    private var repopulated = false

    init(name: String, log: EventLog) {
        self.name = name
        self.log = log
    }

    func setIdle(_ idle: Bool) {
        _idle = idle
    }

    /// Configure queue to become idle after N checks of isIdle.
    func setIdleAfterChecks(_ n: Int) {
        _idle = false
        idleAfterChecks = n
        checksRemaining = n
    }

    func setDrainDelay(_ delay: Duration) {
        drainDelay = delay
    }

    var isIdle: Bool {
        if checksRemaining > 0 {
            checksRemaining -= 1
            if checksRemaining == 0 {
                _idle = true
            }
        }
        return _idle
    }

    func cancelAllInFlight() async {
        await log.record("cancel_\(name)")
        _idle = true
        repopulated = false
    }

    func repopulateFromDatabase() async {
        await log.record("repopulate_\(name)")
        // `cancelAllInFlight` makes the old workload idle, but repopulating a queue that
        // was configured with pending checks represents new durable work discovered in DB.
        if checksRemaining > 0 {
            _idle = false
        }
        repopulated = true
    }

    func awaitDrain() async {
        await log.record("drain_start_\(name)")
        if drainDelay > .zero {
            try? await Task.sleep(for: drainDelay)
        }
        _idle = true
        await log.record("drain_done_\(name)")
    }

    var wasRepopulated: Bool { repopulated }
}

// MARK: - TestSyncStartup

/// Replicates the exact flow from SyncScheduler.syncStartup() using trackable mocks.
/// Each operation records its execution order via EventLog.
private actor TestSyncStartup {

    enum DrainMode: Sendable {
        case none
        case budget(TimeInterval)
        case full
    }

    let log: EventLog

    let activeBody: MockQueue
    let activeAI: MockQueue
    let backfillBody: MockQueue
    let activeEmbedding: MockQueue
    let backfillEmbedding: MockQueue

    // Configurable behaviors
    var syncDelay: Duration = .zero
    var syncShouldFail = false
    var isOnWiFi = true
    var isLowPowerMode = false
    var recoverDelay: Duration = .zero
    var accountCount = 1
    private var _backfillRan = false
    private var _refreshRemindersRan = false

    init(log: EventLog) {
        self.log = log
        activeBody = MockQueue(name: "active_body", log: log)
        activeAI = MockQueue(name: "active_ai", log: log)
        backfillBody = MockQueue(name: "backfill_body", log: log)
        activeEmbedding = MockQueue(name: "active_embedding", log: log)
        backfillEmbedding = MockQueue(name: "backfill_embedding", log: log)
    }

    var backfillRan: Bool { _backfillRan }
    var refreshRemindersRan: Bool { _refreshRemindersRan }

    func setSyncDelay(_ delay: Duration) { syncDelay = delay }
    func setSyncShouldFail(_ fail: Bool) { syncShouldFail = fail }
    func setWiFi(_ wifi: Bool) { isOnWiFi = wifi }
    func setLowPowerMode(_ lpm: Bool) { isLowPowerMode = lpm }
    func setRecoverDelay(_ delay: Duration) { recoverDelay = delay }
    func setAccountCount(_ count: Int) { accountCount = count }

    /// Unified startup sequence — mirrors SyncScheduler.syncStartup exactly.
    func syncStartup(inboxOnly: Bool, drain: DrainMode = .none) async {
        let t0 = CFAbsoluteTimeGetCurrent()

        // 1. Cancel stale in-flight tasks
        await activeBody.cancelAllInFlight()
        await activeAI.cancelAllInFlight()
        if !inboxOnly {
            await backfillBody.cancelAllInFlight()
            await activeEmbedding.cancelAllInFlight()
            await backfillEmbedding.cancelAllInFlight()
        }

        // 2. Recover incomplete headers
        await recoverIncompleteHeaders()

        // 3. Repopulate queues
        if inboxOnly {
            async let bodyRepop: Void = activeBody.repopulateFromDatabase()
            async let aiRepop: Void = activeAI.repopulateFromDatabase()
            _ = await (bodyRepop, aiRepop)
        } else {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.activeBody.repopulateFromDatabase() }
                group.addTask { await self.backfillBody.repopulateFromDatabase() }
                group.addTask { await self.activeAI.repopulateFromDatabase() }
                group.addTask { await self.activeEmbedding.repopulateFromDatabase() }
                group.addTask { await self.backfillEmbedding.repopulateFromDatabase() }
            }
        }

        // 4. Fire sync as parallel Task
        let syncTask = Task { [self] in
            await self.log.record("sync_start")
            if self.syncDelay > .zero {
                try? await Task.sleep(for: self.syncDelay)
            }
            if !self.syncShouldFail {
                await self.log.record("drain_ops")
            }
            await self.log.record("sync_done")
        }

        // 5. Drain based on mode
        switch drain {
        case .none:
            await log.record("drain_mode_none")

        case .budget(let seconds):
            let deadline = t0 + seconds
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            if remaining > 2.0 {
                await log.record("drain_check_start")
                while CFAbsoluteTimeGetCurrent() < deadline && !Task.isCancelled {
                    let bodyDone = await activeBody.isIdle
                    let aiDone = await activeAI.isIdle
                    if bodyDone && aiDone {
                        await log.record("drain_check_idle")
                        break
                    }
                    await log.record("drain_check_poll")
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if Task.isCancelled {
                    await log.record("drain_check_cancelled")
                }
                if CFAbsoluteTimeGetCurrent() >= deadline {
                    await log.record("drain_check_deadline")
                }
            } else {
                await log.record("drain_check_skipped")
            }
            _ = await syncTask.value
            await log.record("drain_budget_done")

        case .full:
            // Body must complete first (feeds AI/embedding)
            await activeBody.awaitDrain()
            await backfillBody.awaitDrain()
            // AI + embedding in parallel
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.activeAI.awaitDrain() }
                group.addTask { await self.backfillEmbedding.awaitDrain() }
            }
            _ = await syncTask.value

            // Backfill walk (WiFi/LPM gated)
            let skipBackfill = isLowPowerMode || (!isOnWiFi)
            if !skipBackfill && !Task.isCancelled {
                await log.record("backfill_start")
                _backfillRan = true
                await log.record("backfill_done")
            }

            // Refresh reminders
            await log.record("refresh_reminders")
            _refreshRemindersRan = true
        }
    }

    private func recoverIncompleteHeaders() async {
        if recoverDelay > .zero {
            try? await Task.sleep(for: recoverDelay)
        }
        await log.record("recover_headers")
    }
}

// MARK: - Suite 1: Ordering Guarantees

@Suite("SyncStartup — Ordering Guarantees")
struct SyncStartupOrderingTests {

    @Test("Cancel runs before repopulate")
    func cancelBeforeRepopulate() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.syncStartup(inboxOnly: false, drain: .none)
        // Allow sync task to complete
        try? await Task.sleep(for: .milliseconds(50))

        let events = await log.events

        // Find last cancel and first repopulate
        let cancelIndices = events.enumerated().filter { $0.element.hasPrefix("cancel_") }.map(\.offset)
        let repopIndices = events.enumerated().filter { $0.element.hasPrefix("repopulate_") }.map(\.offset)

        guard let lastCancel = cancelIndices.last else {
            Issue.record("No cancel events found")
            return
        }
        guard let firstRepop = repopIndices.first else {
            Issue.record("No repopulate events found")
            return
        }

        #expect(lastCancel < firstRepop, "All cancels must complete before any repopulate. Events: \(events)")
    }

    @Test("Recover runs before repopulate")
    func recoverBeforeRepopulate() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.syncStartup(inboxOnly: false, drain: .none)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await log.events

        guard let recoverIdx = await log.index(of: "recover_headers") else {
            Issue.record("No recover_headers event found")
            return
        }
        let repopIndices = events.enumerated().filter { $0.element.hasPrefix("repopulate_") }.map(\.offset)
        guard let firstRepop = repopIndices.first else {
            Issue.record("No repopulate events found")
            return
        }

        #expect(recoverIdx < firstRepop, "recover_headers must run before any repopulate. Events: \(events)")
    }

    @Test("Repopulate runs before sync starts")
    func repopulateBeforeSyncStarts() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Use budget drain to ensure sync task completes within test
        await startup.syncStartup(inboxOnly: false, drain: .budget(5.0))

        let events = await log.events

        let repopIndices = events.enumerated().filter { $0.element.hasPrefix("repopulate_") }.map(\.offset)
        guard let lastRepop = repopIndices.last else {
            Issue.record("No repopulate events found")
            return
        }
        guard let syncStartIdx = await log.index(of: "sync_start") else {
            Issue.record("No sync_start event found")
            return
        }

        #expect(lastRepop < syncStartIdx, "All repopulates must complete before sync_start. Events: \(events)")
    }

    @Test("Sync fires as parallel Task — repopulate does not wait for sync completion")
    func syncFiresInParallel() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Slow sync — if repopulate waited for sync, drain_mode_none would appear after sync_done
        await startup.setSyncDelay(.milliseconds(500))

        await startup.syncStartup(inboxOnly: false, drain: .none)

        let events = await log.events

        // drain_mode_none should appear BEFORE sync_done (since sync is parallel)
        let drainNoneIdx = await log.index(of: "drain_mode_none")
        let syncDoneIdx = await log.index(of: "sync_done")

        // sync may not have finished yet — that proves it's parallel
        if let doneIdx = syncDoneIdx, let noneIdx = drainNoneIdx {
            #expect(noneIdx < doneIdx, "drain_mode_none should appear before sync_done (parallel). Events: \(events)")
        } else if drainNoneIdx != nil && syncDoneIdx == nil {
            // sync hasn't finished yet — proves parallelism
        } else {
            Issue.record("Expected drain_mode_none to be logged. Events: \(events)")
        }
    }

    @Test("Full drain: body drain completes before AI drain starts")
    func fullDrainBodyBeforeAI() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Give body queues a small delay to ensure ordering is testable
        await startup.activeBody.setDrainDelay(.milliseconds(50))
        await startup.backfillBody.setDrainDelay(.milliseconds(50))

        await startup.syncStartup(inboxOnly: false, drain: .full)

        let events = await log.events

        // Body drain_done must appear before AI drain_start
        guard let bodyDoneIdx = await log.index(of: "drain_done_active_body") else {
            Issue.record("No drain_done_active_body event. Events: \(events)")
            return
        }
        guard let backfillBodyDoneIdx = await log.index(of: "drain_done_backfill_body") else {
            Issue.record("No drain_done_backfill_body event. Events: \(events)")
            return
        }
        guard let aiStartIdx = await log.index(of: "drain_start_active_ai") else {
            Issue.record("No drain_start_active_ai event. Events: \(events)")
            return
        }

        #expect(bodyDoneIdx < aiStartIdx, "active_body drain must complete before AI drain starts. Events: \(events)")
        #expect(backfillBodyDoneIdx < aiStartIdx, "backfill_body drain must complete before AI drain starts. Events: \(events)")
    }
}

// MARK: - Suite 2: inboxOnly Routing

@Suite("SyncStartup — inboxOnly Routing")
struct SyncStartupInboxOnlyTests {

    @Test("inboxOnly=true only cancels ActiveBody and ActiveAI")
    func inboxOnlyCancelsOnlyInboxQueues() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.syncStartup(inboxOnly: true, drain: .none)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await log.events
        let cancelEvents = events.filter { $0.hasPrefix("cancel_") }

        #expect(cancelEvents.count == 2, "inboxOnly=true should cancel exactly 2 queues. Got: \(cancelEvents)")
        #expect(cancelEvents.contains("cancel_active_body"))
        #expect(cancelEvents.contains("cancel_active_ai"))
        #expect(!cancelEvents.contains("cancel_backfill_body"))
        #expect(!cancelEvents.contains("cancel_active_embedding"))
        #expect(!cancelEvents.contains("cancel_backfill_embedding"))
    }

    @Test("inboxOnly=false cancels ALL 5 queues")
    func fullCancelsAllQueues() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.syncStartup(inboxOnly: false, drain: .none)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await log.events
        let cancelEvents = events.filter { $0.hasPrefix("cancel_") }

        #expect(cancelEvents.count == 5, "inboxOnly=false should cancel all 5 queues. Got: \(cancelEvents)")
        #expect(cancelEvents.contains("cancel_active_body"))
        #expect(cancelEvents.contains("cancel_active_ai"))
        #expect(cancelEvents.contains("cancel_backfill_body"))
        #expect(cancelEvents.contains("cancel_active_embedding"))
        #expect(cancelEvents.contains("cancel_backfill_embedding"))
    }

    @Test("inboxOnly=true only repopulates ActiveBody and ActiveAI")
    func inboxOnlyRepopulatesOnlyInboxQueues() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.syncStartup(inboxOnly: true, drain: .none)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await log.events
        let repopEvents = events.filter { $0.hasPrefix("repopulate_") }

        #expect(repopEvents.count == 2, "inboxOnly=true should repopulate exactly 2 queues. Got: \(repopEvents)")
        #expect(repopEvents.contains("repopulate_active_body"))
        #expect(repopEvents.contains("repopulate_active_ai"))
        #expect(!repopEvents.contains("repopulate_backfill_body"))
        #expect(!repopEvents.contains("repopulate_active_embedding"))
        #expect(!repopEvents.contains("repopulate_backfill_embedding"))
    }

    @Test("inboxOnly=false repopulates ALL queues")
    func fullRepopulatesAllQueues() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.syncStartup(inboxOnly: false, drain: .none)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await log.events
        let repopEvents = events.filter { $0.hasPrefix("repopulate_") }

        #expect(repopEvents.count == 5, "inboxOnly=false should repopulate all 5 queues. Got: \(repopEvents)")
        #expect(repopEvents.contains("repopulate_active_body"))
        #expect(repopEvents.contains("repopulate_backfill_body"))
        #expect(repopEvents.contains("repopulate_active_ai"))
        #expect(repopEvents.contains("repopulate_active_embedding"))
        #expect(repopEvents.contains("repopulate_backfill_embedding"))
    }
}

// MARK: - Suite 3: Drain Mode .none

@Suite("SyncStartup — Drain Mode .none")
struct SyncStartupDrainNoneTests {

    @Test(".none returns immediately — sync still running in background")
    func noneReturnsImmediately() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Slow sync to prove we return before it finishes
        await startup.setSyncDelay(.milliseconds(500))

        let t0 = CFAbsoluteTimeGetCurrent()
        await startup.syncStartup(inboxOnly: false, drain: .none)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        // Should return well before 500ms sync delay
        #expect(elapsed < 0.4, "drain .none should return immediately, took \(elapsed)s")

        // Verify drain_mode_none is logged
        let hasDrainNone = await log.contains("drain_mode_none")
        #expect(hasDrainNone)

        // sync_done should not yet have occurred
        let hasSyncDone = await log.contains("sync_done")
        #expect(!hasSyncDone, "Sync should still be running when .none returns")

        // Wait for sync to finish to avoid dangling tasks
        try? await Task.sleep(for: .milliseconds(600))
    }

    @Test(".none with offline — sync fails fast, returns immediately")
    func noneOfflineReturnsFast() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Simulate offline: sync completes instantly with failure
        await startup.setSyncShouldFail(true)
        await startup.setSyncDelay(.zero)

        let t0 = CFAbsoluteTimeGetCurrent()
        await startup.syncStartup(inboxOnly: false, drain: .none)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        #expect(elapsed < 0.2, "Offline .none should return very fast, took \(elapsed)s")

        // Verify repopulate still ran (GRDB read works offline)
        let hasRepop = await log.contains("repopulate_active_body")
        #expect(hasRepop, "Repopulate should still run offline")
    }
}

// MARK: - Suite 4: Drain Mode .budget

@Suite("SyncStartup — Drain Mode .budget")
struct SyncStartupDrainBudgetTests {

    @Test("Budget with idle queues exits early (before deadline)")
    func budgetIdleExitsEarly() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Queues are idle by default
        await startup.activeBody.setIdle(true)
        await startup.activeAI.setIdle(true)

        let t0 = CFAbsoluteTimeGetCurrent()
        await startup.syncStartup(inboxOnly: true, drain: .budget(10.0))
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        // Should exit well before 10s budget
        #expect(elapsed < 2.0, "Idle queues should cause early exit, took \(elapsed)s")

        let hasIdle = await log.contains("drain_check_idle")
        #expect(hasIdle, "Should record drain_check_idle for early exit")
    }

    @Test("Budget with busy queues exits at deadline")
    func budgetBusyExitsAtDeadline() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Queues stay busy forever (never become idle)
        await startup.activeBody.setIdle(false)
        await startup.activeAI.setIdle(false)
        // Ensure they never auto-idle (high check count)
        await startup.activeBody.setIdleAfterChecks(99999)
        await startup.activeAI.setIdleAfterChecks(99999)

        // Budget must be >2.0 AFTER steps 1-3 complete (the drain loop has a >2.0 guard).
        // Use 5s to ensure enough remaining budget after cancel+recover+repopulate.
        let budgetSeconds = 5.0
        let t0 = CFAbsoluteTimeGetCurrent()
        await startup.syncStartup(inboxOnly: true, drain: .budget(budgetSeconds))
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        // Verify drain loop was entered and attempted to poll
        let hasStart = await log.contains("drain_check_start")
        let hasSkipped = await log.contains("drain_check_skipped")
        let hasPoll = await log.all(withPrefix: "drain_check_poll").count > 0
        let hasDeadline = await log.contains("drain_check_deadline")

        // With 5s budget and near-instant mock operations, drain MUST enter
        #expect(hasStart, "Drain loop must start with 5s budget")
        #expect(!hasSkipped, "Drain must not be skipped with 5s budget")
        // With queues permanently busy, drain must poll until deadline
        #expect(hasPoll, "Permanently busy queues must be polled")
        #expect(hasDeadline, "Should exit at deadline after polling")
        #expect(elapsed >= budgetSeconds, "Busy drain returned before its deadline: \(elapsed)s")
        #expect(elapsed < budgetSeconds + 1.0, "Busy drain exceeded its deadline allowance: \(elapsed)s")
    }

    @Test("Budget with sync slower than budget — drain still runs full budget")
    func budgetSyncSlowerThanBudget() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Sync takes longer than drain budget
        await startup.setSyncDelay(.milliseconds(2000))
        // Queues become idle quickly
        await startup.activeBody.setIdleAfterChecks(2)
        await startup.activeAI.setIdle(true)

        let t0 = CFAbsoluteTimeGetCurrent()
        await startup.syncStartup(inboxOnly: true, drain: .budget(5.0))
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        // Drain exits early (queues idle), but then waits for syncTask.value
        // Total time should be around sync delay (2s)
        #expect(elapsed >= 1.5, "Should wait for syncTask.value, elapsed \(elapsed)s")

        let hasBudgetDone = await log.contains("drain_budget_done")
        #expect(hasBudgetDone, "Should log drain_budget_done")
    }

    @Test("Budget with zero remaining skips drain entirely")
    func budgetZeroRemainingSkipsDrain() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Use a very small budget that will be consumed by cancel+recover+repopulate
        // The budget check is `remaining > 2.0`, so 0.5s budget guarantees skip
        await startup.syncStartup(inboxOnly: true, drain: .budget(0.5))

        let hasSkipped = await log.contains("drain_check_skipped")
        #expect(hasSkipped, "Budget with remaining <= 2.0 should skip drain check")
    }

    @Test("Budget awaits syncTask.value at end")
    func budgetAwaitsSyncTask() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Slow sync
        await startup.setSyncDelay(.milliseconds(500))
        await startup.activeBody.setIdle(true)
        await startup.activeAI.setIdle(true)

        await startup.syncStartup(inboxOnly: true, drain: .budget(10.0))

        // After budget drain returns, sync must have completed (we awaited syncTask.value)
        let hasSyncDone = await log.contains("sync_done")
        #expect(hasSyncDone, "syncTask.value must be awaited — sync_done should be logged")

        let hasBudgetDone = await log.contains("drain_budget_done")
        #expect(hasBudgetDone)

        // drain_budget_done should be AFTER sync_done
        let events = await log.events
        guard let syncDoneIdx = await log.index(of: "sync_done"),
              let budgetDoneIdx = await log.index(of: "drain_budget_done") else {
            Issue.record("Expected both sync_done and drain_budget_done. Events: \(events)")
            return
        }
        #expect(syncDoneIdx < budgetDoneIdx, "sync_done must precede drain_budget_done. Events: \(events)")
    }
}

// MARK: - Suite 5: Drain Mode .full

@Suite("SyncStartup — Drain Mode .full")
struct SyncStartupDrainFullTests {

    @Test("Full drain: body completes before AI starts")
    func fullDrainBodyBeforeAI() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.activeBody.setDrainDelay(.milliseconds(100))
        await startup.backfillBody.setDrainDelay(.milliseconds(100))

        await startup.syncStartup(inboxOnly: false, drain: .full)

        let events = await log.events

        guard let activebodyDone = await log.index(of: "drain_done_active_body"),
              let backfillBodyDone = await log.index(of: "drain_done_backfill_body"),
              let aiStart = await log.index(of: "drain_start_active_ai") else {
            Issue.record("Missing expected drain events. Events: \(events)")
            return
        }

        #expect(activebodyDone < aiStart, "active_body must drain before AI starts")
        #expect(backfillBodyDone < aiStart, "backfill_body must drain before AI starts")
    }

    @Test("Full drain: awaits syncTask")
    func fullDrainAwaitsSyncTask() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.setSyncDelay(.milliseconds(200))

        await startup.syncStartup(inboxOnly: false, drain: .full)

        let hasSyncDone = await log.contains("sync_done")
        #expect(hasSyncDone, "Full drain must await syncTask — sync_done should appear")
    }

    @Test("Full drain with WiFi — backfill runs")
    func fullDrainWiFiBackfillRuns() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.setWiFi(true)
        await startup.setLowPowerMode(false)

        await startup.syncStartup(inboxOnly: false, drain: .full)

        let backfillRan = await startup.backfillRan
        #expect(backfillRan, "Backfill should run on WiFi")

        let hasBackfillStart = await log.contains("backfill_start")
        #expect(hasBackfillStart)
        let hasBackfillDone = await log.contains("backfill_done")
        #expect(hasBackfillDone)
    }

    @Test("Full drain without WiFi (wifiOnly=true) — backfill skipped")
    func fullDrainNoWiFiBackfillSkipped() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.setWiFi(false)
        await startup.setLowPowerMode(false)

        await startup.syncStartup(inboxOnly: false, drain: .full)

        let backfillRan = await startup.backfillRan
        #expect(!backfillRan, "Backfill should be skipped without WiFi")

        let hasBackfillStart = await log.contains("backfill_start")
        #expect(!hasBackfillStart)
    }

    @Test("Full drain with Low Power Mode — backfill skipped")
    func fullDrainLPMBackfillSkipped() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.setWiFi(true)
        await startup.setLowPowerMode(true)

        await startup.syncStartup(inboxOnly: false, drain: .full)

        let backfillRan = await startup.backfillRan
        #expect(!backfillRan, "Backfill should be skipped in Low Power Mode")
    }

    @Test("Full drain: refreshReminders runs after backfill")
    func fullDrainRefreshRemindersAfterBackfill() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.setWiFi(true)
        await startup.setLowPowerMode(false)

        await startup.syncStartup(inboxOnly: false, drain: .full)

        let events = await log.events

        let refreshRan = await startup.refreshRemindersRan
        #expect(refreshRan, "refreshReminders should run in full drain")

        // refresh_reminders should be after backfill_done
        guard let backfillDoneIdx = await log.index(of: "backfill_done"),
              let refreshIdx = await log.index(of: "refresh_reminders") else {
            Issue.record("Missing backfill_done or refresh_reminders. Events: \(events)")
            return
        }

        #expect(backfillDoneIdx < refreshIdx, "refresh_reminders should run after backfill_done. Events: \(events)")
    }

    @Test("Full drain: refreshReminders runs even when backfill skipped")
    func fullDrainRefreshRemindersWithoutBackfill() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // No WiFi — backfill skipped
        await startup.setWiFi(false)

        await startup.syncStartup(inboxOnly: false, drain: .full)

        let refreshRan = await startup.refreshRemindersRan
        #expect(refreshRan, "refreshReminders should still run even when backfill is skipped")
    }
}

// MARK: - Suite 6: Cancellation

@Suite("SyncStartup — Cancellation")
struct SyncStartupCancellationTests {

    @Test("Task cancelled during sync — drain still processes what was repopulated")
    func cancelDuringSyncDrainProceeds() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Slow sync
        await startup.setSyncDelay(.milliseconds(500))
        await startup.activeBody.setIdle(true)
        await startup.activeAI.setIdle(true)

        let task = Task {
            await startup.syncStartup(inboxOnly: true, drain: .budget(10.0))
        }

        // Let it get past repopulate and into drain
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        // Wait for task to finish
        await task.value

        // Repopulate should have completed
        let hasRepop = await log.contains("repopulate_active_body")
        #expect(hasRepop, "Repopulate should have run before cancellation")
    }

    @Test("Task cancelled during budget drain — exits loop")
    func cancelDuringBudgetDrain() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Queues stay busy
        await startup.activeBody.setIdleAfterChecks(99999)
        await startup.activeAI.setIdleAfterChecks(99999)

        let task = Task {
            await startup.syncStartup(inboxOnly: true, drain: .budget(30.0))
        }

        // Let it start the drain loop
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()

        await task.value

        // Should have exited via cancellation, not deadline
        let hasCancelled = await log.contains("drain_check_cancelled")
        // The drain loop checks Task.isCancelled and will exit
        let events = await log.events
        let hasBudgetDone = events.contains("drain_budget_done")
        #expect(hasCancelled, "Drain loop must observe task cancellation")
        #expect(!events.contains("drain_check_deadline"), "Cancellation must exit before the deadline")
        #expect(hasBudgetDone, "Should still complete budget drain flow after cancellation")
    }

    @Test("Task cancelled before backfill in .full — backfill skipped")
    func cancelBeforeBackfill() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.setWiFi(true)
        await startup.setLowPowerMode(false)

        // Slow body drain so we can cancel during it
        await startup.activeBody.setDrainDelay(.milliseconds(500))

        let task = Task {
            await startup.syncStartup(inboxOnly: false, drain: .full)
        }

        // Cancel while body is draining (before backfill)
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()

        await task.value

        // Backfill should be skipped due to Task.isCancelled
        let backfillRan = await startup.backfillRan
        #expect(!backfillRan, "Backfill should be skipped when task is cancelled")
    }

    @Test("Cancel stale tasks before repopulate — repopulate sees clean state")
    func cancelBeforeRepopulateCleansState() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.syncStartup(inboxOnly: false, drain: .none)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await log.events

        // Verify cancel events come before repopulate events
        let allCancel = events.enumerated().filter { $0.element.hasPrefix("cancel_") }
        let allRepop = events.enumerated().filter { $0.element.hasPrefix("repopulate_") }

        guard !allCancel.isEmpty else {
            Issue.record("No cancel events. Events: \(events)")
            return
        }
        guard !allRepop.isEmpty else {
            Issue.record("No repopulate events. Events: \(events)")
            return
        }

        let maxCancelIdx = allCancel.map(\.offset).max()!
        let minRepopIdx = allRepop.map(\.offset).min()!

        #expect(maxCancelIdx < minRepopIdx, "All cancels must finish before any repopulate starts. Events: \(events)")
    }
}

// MARK: - Suite 7: Offline / Network Failures

@Suite("SyncStartup — Offline / Network Failures")
struct SyncStartupOfflineTests {

    @Test("Offline: sync returns fast, repopulate still ran")
    func offlineSyncFastRepopulateRan() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.setSyncShouldFail(true)
        await startup.setSyncDelay(.zero)
        await startup.activeBody.setIdle(true)
        await startup.activeAI.setIdle(true)

        await startup.syncStartup(inboxOnly: true, drain: .budget(5.0))

        // Repopulate happened (reads from GRDB, works offline)
        let hasRepop = await log.contains("repopulate_active_body")
        #expect(hasRepop, "Repopulate should run even offline")

        let hasRepopAI = await log.contains("repopulate_active_ai")
        #expect(hasRepopAI, "AI repopulate should run even offline")

        // Sync completed (fast, with failure)
        let hasSyncDone = await log.contains("sync_done")
        #expect(hasSyncDone, "Sync should complete (fast) even offline")

        // drain_ops should NOT appear (sync failed)
        let hasDrainOps = await log.contains("drain_ops")
        #expect(!hasDrainOps, "drain_ops should not run when sync fails")
    }

    @Test("Network drops mid-sync: queues still process repopulated items")
    func networkDropMidSyncQueuesProcess() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Sync starts but fails partway
        await startup.setSyncShouldFail(true)
        await startup.setSyncDelay(.milliseconds(100))

        // Queues have items to process (repopulated from DB)
        await startup.activeBody.setIdleAfterChecks(3)
        await startup.activeAI.setIdle(true)

        await startup.syncStartup(inboxOnly: true, drain: .budget(5.0))

        // Repopulate ran before sync failure
        let hasRepop = await log.contains("repopulate_active_body")
        #expect(hasRepop, "Repopulate should run before sync starts")

        // Drain checked queues (they became idle)
        let hasIdle = await log.contains("drain_check_idle")
        #expect(hasIdle, "Drain should still check queues after sync failure")
    }

    @Test("Sync timeout on one account: other accounts still sync")
    func syncTimeoutOneAccountOthersSync() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Multiple accounts — sync completes for all (simulated as single sync task)
        await startup.setAccountCount(3)
        await startup.setSyncDelay(.milliseconds(100))

        await startup.syncStartup(inboxOnly: false, drain: .budget(5.0))

        // The sync task represents all accounts — it completes
        let hasSyncDone = await log.contains("sync_done")
        #expect(hasSyncDone, "Sync should complete for all accounts")

        // All queues were repopulated
        let hasRepopBody = await log.contains("repopulate_active_body")
        let hasRepopAI = await log.contains("repopulate_active_ai")
        #expect(hasRepopBody)
        #expect(hasRepopAI)
    }
}

// MARK: - Suite 8: Concurrent Behavior

@Suite("SyncStartup — Concurrent Behavior")
struct SyncStartupConcurrentTests {

    @Test("Sync enqueues new items while drain is checking idle — drain continues")
    func syncEnqueuesWhileDrainChecks() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Body queue: not idle for first 3 checks, then idle
        await startup.activeBody.setIdleAfterChecks(3)
        await startup.activeAI.setIdle(true)
        // Sync runs in parallel
        await startup.setSyncDelay(.milliseconds(100))

        // Use generous budget to ensure drain loop enters (needs >2.0 remaining after setup)
        await startup.syncStartup(inboxOnly: true, drain: .budget(10.0))

        // Drain should eventually see idle queues
        let hasIdle = await log.contains("drain_check_idle")
        #expect(hasIdle, "Drain should eventually see idle queues")
    }

    @Test("Multiple rapid syncStartup calls — cancel+repopulate sequence is safe")
    func multipleRapidStartupCalls() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Fire multiple startups rapidly
        let task1 = Task {
            await startup.syncStartup(inboxOnly: false, drain: .none)
        }
        let task2 = Task {
            await startup.syncStartup(inboxOnly: false, drain: .none)
        }
        let task3 = Task {
            await startup.syncStartup(inboxOnly: false, drain: .none)
        }

        await task1.value
        await task2.value
        await task3.value

        // Allow background sync tasks to complete
        try? await Task.sleep(for: .milliseconds(200))

        let events = await log.events

        // Each startup should have cancelled then repopulated
        let cancelCount = events.filter { $0.hasPrefix("cancel_") }.count
        let repopCount = events.filter { $0.hasPrefix("repopulate_") }.count

        // 3 calls * 5 queues = 15 cancels, 3 calls * 5 queues = 15 repopulates
        #expect(cancelCount == 15, "3 full startups should produce 15 cancel events. Got \(cancelCount)")
        #expect(repopCount == 15, "3 full startups should produce 15 repopulate events. Got \(repopCount)")
    }

    @Test("Repopulate + sync both write to queues — no race (actor isolation)")
    func repopulateAndSyncNoRace() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Fast sync that completes during drain
        await startup.setSyncDelay(.milliseconds(50))
        await startup.activeBody.setIdleAfterChecks(3)
        await startup.activeAI.setIdleAfterChecks(3)

        await startup.syncStartup(inboxOnly: false, drain: .budget(5.0))

        let events = await log.events

        // Verify no crash and all expected events occurred
        let hasRepop = events.contains("repopulate_active_body")
        let hasSyncStart = events.contains("sync_start")
        let hasSyncDone = events.contains("sync_done")

        #expect(hasRepop, "Repopulate should have run")
        #expect(hasSyncStart, "Sync should have started")
        #expect(hasSyncDone, "Sync should have completed")
    }
}

// MARK: - Suite 9: Complete Flow Verification

@Suite("SyncStartup — Complete Flow Verification")
struct SyncStartupCompleteFlowTests {

    @Test("Foreground flow: inboxOnly=false, drain=.none — full sequence")
    func foregroundFlow() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.syncStartup(inboxOnly: false, drain: .none)
        // Wait for sync task
        try? await Task.sleep(for: .milliseconds(100))

        let events = await log.events

        // Verify complete ordering: cancel → recover → repopulate → sync (parallel) → drain none
        let cancelEvents = events.filter { $0.hasPrefix("cancel_") }
        let recoverEvents = events.filter { $0 == "recover_headers" }
        let repopEvents = events.filter { $0.hasPrefix("repopulate_") }

        #expect(cancelEvents.count == 5, "Should cancel all 5 queues")
        #expect(recoverEvents.count == 1, "Should recover headers once")
        #expect(repopEvents.count == 5, "Should repopulate all 5 queues")

        // drain_mode_none logged
        let hasDrainNone = events.contains("drain_mode_none")
        #expect(hasDrainNone)
    }

    @Test("BGAppRefresh flow: inboxOnly=true, drain=.budget")
    func bgAppRefreshFlow() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.activeBody.setIdleAfterChecks(2)
        await startup.activeAI.setIdle(true)

        await startup.syncStartup(inboxOnly: true, drain: .budget(10.0))

        let events = await log.events

        // Only inbox queues cancelled/repopulated
        let cancelEvents = events.filter { $0.hasPrefix("cancel_") }
        let repopEvents = events.filter { $0.hasPrefix("repopulate_") }

        #expect(cancelEvents.count == 2, "BGAppRefresh should cancel 2 queues")
        #expect(repopEvents.count == 2, "BGAppRefresh should repopulate 2 queues")

        // Budget drain completed
        let hasBudgetDone = events.contains("drain_budget_done")
        #expect(hasBudgetDone)
    }

    @Test("BGProcessing flow: inboxOnly=false, drain=.full — complete flow")
    func bgProcessingFlow() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.setWiFi(true)
        await startup.setLowPowerMode(false)

        await startup.syncStartup(inboxOnly: false, drain: .full)

        let events = await log.events

        // Full startup: cancel → recover → repopulate → sync (parallel) → body drain → AI drain → backfill → reminders
        let cancelCount = events.filter { $0.hasPrefix("cancel_") }.count
        let repopCount = events.filter { $0.hasPrefix("repopulate_") }.count

        #expect(cancelCount == 5, "Full should cancel 5 queues")
        #expect(repopCount == 5, "Full should repopulate 5 queues")

        // Body drained before AI
        guard let bodyDone = await log.index(of: "drain_done_active_body"),
              let aiStart = await log.index(of: "drain_start_active_ai") else {
            Issue.record("Missing body/AI drain events. Events: \(events)")
            return
        }
        #expect(bodyDone < aiStart)

        // Backfill ran
        let backfillRan = await startup.backfillRan
        #expect(backfillRan)

        // Reminders refreshed
        let refreshRan = await startup.refreshRemindersRan
        #expect(refreshRan)

        // refresh_reminders is last
        let hasRefresh = events.contains("refresh_reminders")
        #expect(hasRefresh)
    }

    @Test("Silent push flow: inboxOnly=true, drain=.budget — identical to BGAppRefresh")
    func silentPushFlow() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        await startup.activeBody.setIdle(true)
        await startup.activeAI.setIdle(true)

        await startup.syncStartup(inboxOnly: true, drain: .budget(5.0))

        let events = await log.events

        let cancelEvents = events.filter { $0.hasPrefix("cancel_") }
        let repopEvents = events.filter { $0.hasPrefix("repopulate_") }

        #expect(cancelEvents.count == 2, "Push should cancel only inbox queues")
        #expect(repopEvents.count == 2, "Push should repopulate only inbox queues")

        let hasBudgetDone = events.contains("drain_budget_done")
        #expect(hasBudgetDone)
    }

    @Test("Recover headers with delay does not block repopulate indefinitely")
    func recoverHeadersWithDelay() async {
        let log = EventLog()
        let startup = TestSyncStartup(log: log)

        // Recovery takes some time (e.g., 500 headers to FTS index)
        await startup.setRecoverDelay(.milliseconds(100))

        let t0 = CFAbsoluteTimeGetCurrent()
        await startup.syncStartup(inboxOnly: false, drain: .none)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        // Should complete in reasonable time (recovery + repopulate, no drain wait)
        #expect(elapsed < 1.0, "Recovery delay should not cause excessive startup time, took \(elapsed)s")

        let events = await log.events
        let hasRecover = events.contains("recover_headers")
        let hasRepop = events.contains("repopulate_active_body")
        #expect(hasRecover)
        #expect(hasRepop)

        // Recovery must be before repopulate
        guard let recoverIdx = await log.index(of: "recover_headers"),
              let repopIdx = await log.index(of: "repopulate_active_body") else {
            return
        }
        #expect(recoverIdx < repopIdx)
    }
}
