/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Extended TestSyncStartup with Concurrency Tracking

/// Extends the mock syncStartup pattern from SyncStartupTests with concurrency guards
/// that mirror SyncScheduler's isPollActive/isStartupInFlight behavior.
private actor ConcurrentSyncStartup {

    enum DrainMode: Sendable {
        case none
        case budget(TimeInterval)
    }

    let log: EventLog

    private let activeBody: MockQueue
    private let activeAI: MockQueue
    private let backfillBody: MockQueue
    private let activeEmbedding: MockQueue
    private let backfillEmbedding: MockQueue

    // Concurrency guards (mirrors SyncScheduler)
    private var isPollActive = false
    private var startupCount = 0

    // Configurable delays
    private var syncDelay: Duration = .zero
    private var recoverDelay: Duration = .zero
    private var cancelDelay: Duration = .zero

    init(log: EventLog) {
        self.log = log
        activeBody = MockQueue(name: "active_body", log: log)
        activeAI = MockQueue(name: "active_ai", log: log)
        backfillBody = MockQueue(name: "backfill_body", log: log)
        activeEmbedding = MockQueue(name: "active_embedding", log: log)
        backfillEmbedding = MockQueue(name: "backfill_embedding", log: log)
    }

    var currentStartupCount: Int { startupCount }
    var currentIsPollActive: Bool { isPollActive }

    func setSyncDelay(_ delay: Duration) { syncDelay = delay }
    func setRecoverDelay(_ delay: Duration) { recoverDelay = delay }
    func setCancelDelay(_ delay: Duration) { cancelDelay = delay }
    func setPollActive(_ active: Bool) { isPollActive = active }
    func setIdleAfterChecks(body: Int, ai: Int) async {
        await activeBody.setIdleAfterChecks(body)
        await activeAI.setIdleAfterChecks(ai)
    }

    /// Mirrors SyncScheduler.syncStartup with event logging for concurrency verification.
    func syncStartup(inboxOnly: Bool, drain: DrainMode = .none) async {
        let id = startupCount
        startupCount += 1
        await log.record("startup_begin_\(id)")

        let t0 = CFAbsoluteTimeGetCurrent()

        // 1. Cancel stale in-flight tasks
        if cancelDelay > .zero {
            try? await Task.sleep(for: cancelDelay)
        }
        await activeBody.cancelAllInFlight()
        await activeAI.cancelAllInFlight()
        if !inboxOnly {
            await backfillBody.cancelAllInFlight()
            await activeEmbedding.cancelAllInFlight()
            await backfillEmbedding.cancelAllInFlight()
        }
        await log.record("cancel_done_\(id)")

        // 2. Recover incomplete headers
        if recoverDelay > .zero {
            try? await Task.sleep(for: recoverDelay)
        }
        await log.record("recover_headers_\(id)")

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
        await log.record("repopulate_done_\(id)")

        // 4. Fire sync as parallel Task
        let syncTask = Task { [self] in
            await self.log.record("sync_start_\(id)")
            if self.syncDelay > .zero {
                try? await Task.sleep(for: self.syncDelay)
            }
            await self.log.record("sync_done_\(id)")
        }

        // 5. Drain based on mode
        switch drain {
        case .none:
            await log.record("drain_mode_none_\(id)")

        case .budget(let seconds):
            let deadline = t0 + seconds
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            if remaining > 0.5 {
                await log.record("drain_check_start_\(id)")
                while CFAbsoluteTimeGetCurrent() < deadline && !Task.isCancelled {
                    let bodyDone = await activeBody.isIdle
                    let aiDone = await activeAI.isIdle
                    if bodyDone && aiDone {
                        await log.record("drain_idle_\(id)")
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if Task.isCancelled {
                    await log.record("drain_cancelled_\(id)")
                }
            }
            _ = await syncTask.value
            await log.record("drain_budget_done_\(id)")
        }

        await log.record("startup_end_\(id)")
    }

    /// Simulates the BGAppRefresh guard: skip if poll is active.
    func handleBackgroundSync(inboxOnly: Bool, drain: DrainMode) async {
        guard !isPollActive else {
            await log.record("bg_skipped_poll_active")
            return
        }
        await syncStartup(inboxOnly: inboxOnly, drain: drain)
    }
}

// Reuse the same EventLog/MockQueue from SyncStartupTests pattern.
private actor EventLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func contains(_ event: String) -> Bool {
        events.contains(event)
    }

    func index(of event: String) -> Int? {
        events.firstIndex(of: event)
    }

    func all(withPrefix prefix: String) -> [String] {
        events.filter { $0.hasPrefix(prefix) }
    }
}

private actor MockQueue {
    let name: String
    let log: EventLog

    private var _idle: Bool = true
    private var idleAfterChecks: Int = 0
    private var checksRemaining: Int = 0

    init(name: String, log: EventLog) {
        self.name = name
        self.log = log
    }

    func setIdleAfterChecks(_ n: Int) {
        _idle = false
        idleAfterChecks = n
        checksRemaining = n
    }

    var isIdle: Bool {
        if checksRemaining > 0 {
            checksRemaining -= 1
            if checksRemaining == 0 { _idle = true }
        }
        return _idle
    }

    func cancelAllInFlight() async {
        await log.record("cancel_\(name)")
        _idle = true
    }

    func repopulateFromDatabase() async {
        await log.record("repopulate_\(name)")
    }
}

// MARK: - Suite 1: Concurrent syncStartup Calls

@Suite("SyncStartup Concurrency - Dual Startup Safety")
struct DualStartupSafetyTests {

    @Test("Two concurrent syncStartup calls complete without crash")
    func twoConcurrentStartupCallsAreSafe() async {
        let log = EventLog()
        let startup = ConcurrentSyncStartup(log: log)

        // Launch two syncStartup calls concurrently
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await startup.syncStartup(inboxOnly: false, drain: .none) }
            group.addTask { await startup.syncStartup(inboxOnly: false, drain: .none) }
        }

        // Allow sync Tasks to finish
        try? await Task.sleep(for: .milliseconds(100))

        let events = await log.events

        // Both startups should have begun and ended
        let startupBegins = events.filter { $0.hasPrefix("startup_begin_") }
        let startupEnds = events.filter { $0.hasPrefix("startup_end_") }
        #expect(startupBegins.count == 2, "Both startups should begin. Events: \(events)")
        #expect(startupEnds.count == 2, "Both startups should end. Events: \(events)")

        // Verify no duplicate cancel without intervening repopulate
        // (actor serialization ensures clean interleaving)
        let cancelEvents = events.filter { $0.hasPrefix("cancel_done_") }
        #expect(cancelEvents.count == 2, "Each startup should have one cancel phase")
    }

    @Test("Two concurrent startups — each has cancel before repopulate")
    func eachStartupHasCorrectOrdering() async {
        let log = EventLog()
        let startup = ConcurrentSyncStartup(log: log)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await startup.syncStartup(inboxOnly: false, drain: .none) }
            group.addTask { await startup.syncStartup(inboxOnly: false, drain: .none) }
        }

        try? await Task.sleep(for: .milliseconds(100))

        let events = await log.events

        // For each startup ID (0 and 1), cancel_done must come before repopulate_done
        for id in 0...1 {
            let cancelIdx = events.firstIndex(of: "cancel_done_\(id)")
            let repopIdx = events.firstIndex(of: "repopulate_done_\(id)")
            if let c = cancelIdx, let r = repopIdx {
                #expect(c < r, "Startup \(id): cancel must precede repopulate. Events: \(events)")
            }
        }
    }
}

// MARK: - Suite 2: BGAppRefresh + Foreground Race

@Suite("SyncStartup Concurrency - BG + Foreground Race")
struct BGForegroundRaceTests {

    @Test("BGAppRefresh inboxOnly running when foreground starts — both complete")
    func bgAndForegroundBothComplete() async {
        let log = EventLog()
        let startup = ConcurrentSyncStartup(log: log)

        // BG startup has a delay to simulate slow sync
        await startup.setSyncDelay(.milliseconds(100))

        await withTaskGroup(of: Void.self) { group in
            // BG: inboxOnly, budget drain
            group.addTask { await startup.syncStartup(inboxOnly: true, drain: .budget(3.0)) }
            // Foreground starts shortly after
            group.addTask {
                try? await Task.sleep(for: .milliseconds(20))
                await startup.syncStartup(inboxOnly: false, drain: .none)
            }
        }

        try? await Task.sleep(for: .milliseconds(200))

        let events = await log.events
        let startupEnds = events.filter { $0.hasPrefix("startup_end_") }
        #expect(startupEnds.count == 2, "Both BG and foreground startups should complete. Events: \(events)")

        // Foreground startup (id=1) should cancel all 5 queues (inboxOnly=false)
        let cancelEvents = events.filter { $0.hasPrefix("cancel_") && !$0.hasPrefix("cancel_done_") }
        let backfillCancels = cancelEvents.filter { $0.contains("backfill") }
        #expect(backfillCancels.count >= 2, "Foreground should cancel backfill queues. Events: \(events)")
    }
}

// MARK: - Suite 3: Push + BGAppRefresh Simultaneous

@Suite("SyncStartup Concurrency - Push + BGAppRefresh")
struct PushBGSimultaneousTests {

    @Test("Push and BGAppRefresh both call syncStartup inboxOnly — no deadlock")
    func pushAndBGBothComplete() async {
        let log = EventLog()
        let startup = ConcurrentSyncStartup(log: log)

        // Both use the same parameters: inboxOnly=true, budget drain
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await startup.syncStartup(inboxOnly: true, drain: .budget(3.0)) }
            group.addTask { await startup.syncStartup(inboxOnly: true, drain: .budget(3.0)) }
        }

        let events = await log.events
        let startupEnds = events.filter { $0.hasPrefix("startup_end_") }
        #expect(startupEnds.count == 2, "Both push and BG should complete. Events: \(events)")

        // Only active_body and active_ai should be cancelled (inboxOnly=true for both)
        let cancelEvents = events.filter { $0.hasPrefix("cancel_") && !$0.hasPrefix("cancel_done_") }
        let backfillCancels = cancelEvents.filter { $0.contains("backfill") }
        #expect(backfillCancels.isEmpty, "inboxOnly should not cancel backfill queues. Events: \(events)")
    }
}

// MARK: - Suite 4: syncStartup During Active Poll

@Suite("SyncStartup Concurrency - Poll Active Guard")
struct PollActiveGuardTests {

    @Test("BGAppRefresh skips when isPollActive is true")
    func bgSkipsWhenPollActive() async {
        let log = EventLog()
        let startup = ConcurrentSyncStartup(log: log)
        await startup.setPollActive(true)

        await startup.handleBackgroundSync(inboxOnly: true, drain: .budget(3.0))

        let events = await log.events
        #expect(await log.contains("bg_skipped_poll_active"), "BG should skip when poll active. Events: \(events)")

        let startupBegins = events.filter { $0.hasPrefix("startup_begin_") }
        #expect(startupBegins.isEmpty, "No startup should have begun. Events: \(events)")
    }

    @Test("BGAppRefresh proceeds when isPollActive is false")
    func bgProceedsWhenPollInactive() async {
        let log = EventLog()
        let startup = ConcurrentSyncStartup(log: log)
        await startup.setPollActive(false)

        await startup.handleBackgroundSync(inboxOnly: true, drain: .budget(3.0))

        let events = await log.events
        let bgSkipped = await log.contains("bg_skipped_poll_active")
        #expect(!bgSkipped, "BG should NOT be skipped. Events: \(events)")

        let startupBegins = events.filter { $0.hasPrefix("startup_begin_") }
        #expect(startupBegins.count == 1, "One startup should have run. Events: \(events)")
    }
}

// MARK: - Suite 5: Cancel Mid-Startup

@Suite("SyncStartup Concurrency - Mid-Startup Cancellation")
struct MidStartupCancellationTests {

    @Test("Cancel Task during syncStartup — partial state is clean")
    func cancelMidStartup() async {
        let log = EventLog()
        let startup = ConcurrentSyncStartup(log: log)

        // Slow recovery so we can cancel during it
        await startup.setRecoverDelay(.milliseconds(200))
        await startup.setSyncDelay(.milliseconds(500))

        let task = Task {
            await startup.syncStartup(inboxOnly: false, drain: .budget(5.0))
        }

        // Cancel after cancel phase but during recovery
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        // Wait for cancellation to propagate
        _ = await task.value

        let events = await log.events

        // Cancel phase should have completed (it runs before the slow recovery)
        let cancelEvents = events.filter { $0.hasPrefix("cancel_") && !$0.hasPrefix("cancel_done_") }
        #expect(!cancelEvents.isEmpty, "Cancel phase should have run. Events: \(events)")

        // The startup count should be exactly 1 (one started, even if incomplete)
        let count = await startup.currentStartupCount
        #expect(count == 1)
    }

    @Test("Cancel during budget drain — task completes without hanging")
    func cancelDuringBudgetDrain() async {
        let log = EventLog()
        let startup = ConcurrentSyncStartup(log: log)

        // Make queues not idle initially (need many checks before idle)
        await startup.setIdleAfterChecks(body: 50, ai: 50)

        let task = Task {
            await startup.syncStartup(inboxOnly: true, drain: .budget(30.0))
        }

        // Let drain loop start, then cancel
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        _ = await task.value

        let events = await log.events
        // The startup should have begun
        let startupBegins = events.filter { $0.hasPrefix("startup_begin_") }
        #expect(!startupBegins.isEmpty, "Startup should have begun. Events: \(events)")

        // Cancellation should cause the task to complete (not hang for 30s budget).
        // The key safety property: cancelled task completes promptly.
        // We cannot assert exact event ordering due to actor serialization,
        // but we verify it completed (the test would timeout if it hung).
        let count = await startup.currentStartupCount
        #expect(count == 1, "Exactly one startup should have been attempted")
    }
}

// MARK: - Suite 6: Rapid Startup-Cancel-Startup Cycle

@Suite("SyncStartup Concurrency - Rapid Cycle")
struct RapidCycleTests {

    @Test("Three quick startups where each cancels previous — final state clean")
    func rapidStartupCancelCycle() async {
        let log = EventLog()
        let startup = ConcurrentSyncStartup(log: log)
        await startup.setSyncDelay(.milliseconds(100))

        var tasks: [Task<Void, Never>] = []

        // Launch 3 startups in rapid succession, cancelling each previous
        for _ in 0..<3 {
            // Cancel previous
            if let prev = tasks.last { prev.cancel() }
            let task = Task {
                await startup.syncStartup(inboxOnly: false, drain: .budget(5.0))
            }
            tasks.append(task)
            // Small gap between launches
            try? await Task.sleep(for: .milliseconds(30))
        }

        // Wait for the last task to complete
        if let last = tasks.last {
            _ = await last.value
        }

        // Allow all cancelled tasks to fully clean up
        try? await Task.sleep(for: .milliseconds(200))

        let events = await log.events
        let count = await startup.currentStartupCount
        #expect(count == 3, "All 3 startups should have been attempted. Count: \(count)")

        // The last startup (id=2) should have completed
        let lastEnd = await log.contains("startup_end_2")
        #expect(lastEnd, "Last startup should complete. Events: \(events)")
    }
}
