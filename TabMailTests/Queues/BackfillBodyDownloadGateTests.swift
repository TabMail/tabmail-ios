/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// #1064: older-mail body downloads (BackfillBodyQueue) follow the backfill walk's
/// download gates (Wi-Fi-only on an expensive network, battery below 20% off
/// power, Low Power Mode off power; in the background job, the body gate and the
/// job's walk decide with the job's one Wi-Fi measurement; outside the job, a
/// network NetworkMonitor has not reported yet holds). ActiveBodyQueue (new mail) and a message the user opens are not
/// gated. The observables are the provider (a held download never reaches it)
/// and the queue's pending items.
///
/// The helpers that take a closure (`withAccount`, `eventually`, `pollUntil`) are
/// `nonisolated(nonsending)`: they run on the caller's actor, so the `@MainActor`
/// job tests can pass them non-Sendable closures without sending them off the actor.
@Suite("Older-mail body downloads follow the walk gate", .serialized, .processGlobalState)
struct BackfillBodyDownloadGateTests {
    private static let settle: Duration = .milliseconds(600)
    /// Bound on every wait for the queue to act on its own: longer than the
    /// queue's gate re-check interval (`SyncConfig.backfillBodyGateRecheckSeconds`)
    /// plus a dispatch, so a lifted gate is seen within it.
    private static let deadline: Duration = .seconds(20)
    private static let openPower: (fastSync: Bool, lowPowerMode: Bool, onPower: Bool, batteryLevel: Float) =
        (fastSync: false, lowPowerMode: false, onPower: false, batteryLevel: 0.8)

    /// Installs `provider` as the account's provider in AccountManager (where the
    /// body queues resolve it), runs `body` under `gate`, then removes it.
    private nonisolated(nonsending) func withAccount(
        _ accountId: String, provider: MockEmailProvider, gate: DownloadGate?,
        _ body: () async throws -> Void
    ) async throws {
        try await withAccount(accountId, provider: provider,
                              power: gate.map(DownloadGateHarness.power) ?? Self.openPower,
                              expensive: gate == .expensiveNetwork, body)
    }

    private nonisolated(nonsending) func withAccount(
        _ accountId: String, provider: MockEmailProvider,
        power: (fastSync: Bool, lowPowerMode: Bool, onPower: Bool, batteryLevel: Float), expensive: Bool,
        wifiOnly: Bool = true, path: NetworkPathFacts? = nil, _ body: () async throws -> Void
    ) async throws {
        await AccountManager.shared.installBodyGateTestProvider(
            accountId: accountId, provider: provider, queue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
        SyncEngine.backfillPowerStateForTesting.withLock { $0 = power }
        defer { SyncEngine.backfillPowerStateForTesting.withLock { $0 = nil } }
        // A body may set the job's measured answer; it never outlives the test,
        // or it would override the next test's path facts.
        let savedJobMeasurement = SyncScheduler.jobOnWiFiMeasurementForTesting.withLock { $0 }
        defer { SyncScheduler.jobOnWiFiMeasurementForTesting.withLock { $0 = savedJobMeasurement } }
        NetworkMonitor.setConnectedForTesting(true)
        do {
            let facts = path ?? (expensive ? DownloadGateHarness.cellular : DownloadGateHarness.unmeteredWiFi)
            try await DownloadGateHarness.withPath(facts, wifiOnly: wifiOnly) { try await body() }
        } catch {
            await AccountManager.shared.removeBodyGateTestProvider(accountId: accountId)
            throw error
        }
        await AccountManager.shared.removeBodyGateTestProvider(accountId: accountId)
    }

    /// Opens every gate: power off charger with a healthy battery, not Low Power
    /// Mode, and an unmetered network.
    private func openGate() {
        SyncEngine.backfillPowerStateForTesting.withLock { $0 = Self.openPower }
        NetworkMonitor.setExpensiveForTesting(false)
    }

    private func fetchCount(_ provider: MockEmailProvider) async -> Int {
        await provider.callLog.filter { $0.hasPrefix("fetchMessage(") }.count
    }

    /// Polls `condition` until it holds or `Self.deadline` passes.
    private nonisolated(nonsending) func eventually(_ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: Self.deadline)
        while clock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    /// `eventually` for closures that cannot capture the suite (the job's work hook).
    private nonisolated(nonsending) static func pollUntil(_ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        while clock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    /// Runs `awaitDrain` bounded by `Self.deadline`; true when it returned in time.
    private func drains(_ queue: BackfillBodyQueue) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await queue.awaitDrain(); return true }
            group.addTask { try? await Task.sleep(for: Self.deadline); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func backfillItem(_ accountId: String, messageId: String = "7") -> BackfillBodyQueue.Item {
        BackfillBodyQueue.Item(
            headerId: "\(accountId):Archive:\(messageId)", accountId: accountId,
            folderPath: "Archive", messageId: messageId, isInInbox: false)
    }

    @Test("a refused older-mail body stays pending and downloads once the gate opens, without another enqueue",
          arguments: DownloadGate.allCases)
    func heldThenDownloadedWhenTheGateOpens(_ gate: DownloadGate) async throws {
        let accountId = "gate1064-held-\(gate.rawValue)"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        try await withAccount(accountId, provider: provider, gate: gate) {
            await queue.enqueue([backfillItem(accountId)])
            #expect(await eventually { await queue.heldByDownloadGate }, "precondition: the dispatch was not refused under \(gate)")
            try await Task.sleep(for: Self.settle)
            #expect(await fetchCount(provider) == 0, "the body was downloaded under \(gate)")
            #expect(await queue.queuedItemsForTesting.map(\.messageId) == ["7"], "the held item must stay pending")
            // awaitDrain must not hang on held work (the background job awaits it).
            #expect(await drains(queue), "awaitDrain hung on a held queue under \(gate)")

            openGate()
            #expect(await eventually { await fetchCount(provider) > 0 },
                    "the held body was not downloaded after \(gate) lifted")
        }
        await queue.cancelAllInFlight()
    }

    @Test("awaitDrain on a queue held earlier waits for the body once the gate is open (stale held flag)")
    func staleHeldFlagWithGateOpenWaitsForBody() async throws {
        let accountId = "gate1064-stale-held"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        try await withAccount(accountId, provider: provider, gate: .lowPowerMode) {
            await queue.enqueue([backfillItem(accountId)])
            try await Task.sleep(for: Self.settle)
            #expect(await queue.heldByDownloadGate, "precondition: the queue is held")
            #expect(await fetchCount(provider) == 0, "precondition: nothing downloaded while held")

            // The gate opens (as when a background job starts later) before the
            // queue's own re-check runs; the held flag is now stale. The resumed
            // fetch is parked, so the waiter must stay pending until it ends.
            let release = TestLatch()
            await provider.setFetchMessageHook { await release.wait() }
            openGate()
            let drained = TestBox(false)
            let drain = Task { () -> Bool in
                let returned = await drains(queue)
                drained.value.withLock { $0 = true }
                return returned
            }
            #expect(await eventually { await fetchCount(provider) > 0 },
                    "the body was not fetched once the gate opened under a stale held flag")
            try await Task.sleep(for: Self.settle)
            #expect(!drained.value.withLock { $0 }, "awaitDrain returned on a stale held flag while the body was still fetching")

            await release.open()
            #expect(await drain.value, "awaitDrain did not return after the resumed fetch ended")
        }
        await queue.cancelAllInFlight()
    }

    @Test("refused dispatches beyond the retry limit keep the item pending and spend no retry")
    func repeatedRefusalsSpendNoRetry() async throws {
        let accountId = "gate1064-retries"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        let held = backfillItem(accountId)
        try await withAccount(accountId, provider: provider, gate: .lowPowerMode) {
            await queue.enqueue([held])
            #expect(await eventually { await queue.heldByDownloadGate }, "precondition: the first dispatch was not refused")
            try await Task.sleep(for: Self.settle)
            // Each new item triggers a fresh dispatch that collects and refuses the held one too.
            for round in 0...SyncConfig.maxQueueRetries {
                await queue.enqueue([backfillItem(accountId, messageId: "\(100 + round)")])
                try await Task.sleep(for: Self.settle)
            }
            #expect(await fetchCount(provider) == 0, "a body was downloaded under Low Power Mode")
            #expect(await queue.queuedItemsForTesting.map(\.messageId).contains("7"),
                    "repeated refusals dropped the item past the retry limit")

            openGate()
            #expect(await eventually {
                await provider.callLog.contains { $0.hasPrefix("fetchMessage(id:7,") }
            }, "the repeatedly refused item was not admitted after the gate lifted")
        }
        await queue.cancelAllInFlight()
    }

    @Test("Wi-Fi-only off: an older-mail body downloads on an expensive network")
    func wifiOnlyOffDownloadsOnExpensiveNetwork() async throws {
        let accountId = "gate1064-wifi-off"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        try await withAccount(accountId, provider: provider, power: Self.openPower, expensive: true, wifiOnly: false) {
            await queue.enqueue([backfillItem(accountId)])
            #expect(await eventually { await fetchCount(provider) > 0 },
                    "the body was held on an expensive network with Wi-Fi-only off")
        }
        await queue.cancelAllInFlight()
    }

    @Test("a Wi-Fi-only change during a parked decision applies to the next decision, not the parked one")
    func wifiOnlyChangeMidDecisionKeepsSnapshot() async throws {
        let accountId = "gate1064-wifi-snapshot"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        let parked = TestBox(false)
        let admit = TestLatch()
        SyncEngine.backfillPowerReadHookForTesting.withLock {
            $0 = {
                parked.value.withLock { $0 = true }
                await admit.wait()
            }
        }
        defer { SyncEngine.backfillPowerReadHookForTesting.withLock { $0 = nil } }
        try await withAccount(accountId, provider: provider, power: Self.openPower, expensive: true, wifiOnly: false) {
            await queue.enqueue([backfillItem(accountId)])
            #expect(await eventually { parked.value.withLock { $0 } }, "the admission never reached the power read")
            // The Settings toggle writes the preference to UserDefaults.
            UserDefaults.standard.set(true, forKey: SyncScheduler.wifiOnlyKey)
            await admit.open()
            #expect(await eventually { await fetchCount(provider) > 0 },
                    "the parked decision read the new Wi-Fi-only value instead of its snapshot")
            #expect(!(await SyncEngine.backfillDownloadsAllowedNow()),
                    "a new decision did not see Wi-Fi-only turned on")
        }
        await admit.open()
        await queue.cancelAllInFlight()
    }

    @Test("a held older-mail body stays held across full gate re-checks, then downloads when the gate opens",
          arguments: DownloadGate.allCases)
    func heldAcrossRechecksThenDownloaded(_ gate: DownloadGate) async throws {
        let accountId = "gate1064-rechecks-\(gate.rawValue)"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        // Two full re-check intervals, so a watcher that checks once and exits is caught.
        let refusedSpan: Duration = .seconds(SyncConfig.backfillBodyGateRecheckSeconds * 2)
        try await withAccount(accountId, provider: provider, gate: gate) {
            await queue.enqueue([backfillItem(accountId)])
            #expect(await eventually { await queue.heldByDownloadGate }, "precondition: the dispatch was not refused under \(gate)")
            try await Task.sleep(for: Self.settle + refusedSpan)
            #expect(await fetchCount(provider) == 0, "the body was downloaded under \(gate) during a re-check")
            #expect(await queue.queuedItemsForTesting.map(\.messageId) == ["7"],
                    "the held item must stay pending across re-checks")

            openGate()
            #expect(await eventually { await fetchCount(provider) > 0 },
                    "the held body was not downloaded after \(gate) lifted past the first re-check")
        }
        await queue.cancelAllInFlight()
    }

    @Test("with no gate shut, the older-mail body downloads (the harness is live)")
    func downloadsWithNoGate() async throws {
        let accountId = "gate1064-open"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        try await withAccount(accountId, provider: provider, gate: nil) {
            await queue.enqueue([backfillItem(accountId)])
            #expect(await eventually { await fetchCount(provider) > 0 })
        }
        await queue.cancelAllInFlight()
    }

    @Test("a batch already running when the gate shuts finishes before awaitDrain returns")
    func runningBatchFinishesBeforeDrain() async throws {
        let accountId = "gate1064-running"
        let provider = MockEmailProvider()
        let release = TestLatch()
        await provider.setFetchMessageHook { await release.wait() }
        let queue = BackfillBodyQueue()
        try await withAccount(accountId, provider: provider, gate: nil) {
            await queue.enqueue([backfillItem(accountId)])
            #expect(await eventually { await fetchCount(provider) > 0 }, "the batch never started")
            SyncEngine.backfillPowerStateForTesting.withLock { $0 = DownloadGateHarness.power(.lowPowerMode) }

            // A second item arrives after the gate shut: its dispatch is refused
            // and the queue is held while the first batch is still fetching.
            await queue.enqueue([backfillItem(accountId, messageId: "8")])
            #expect(await eventually { await queue.heldByDownloadGate },
                    "precondition: the second item's dispatch was not refused while the first batch ran")
            #expect(await fetchCount(provider) == 1, "precondition: only the first body is fetching")
            #expect(!(await queue.isIdle), "precondition: the first batch is still active")

            let drained = TestBox(false)
            let drain = Task { await queue.awaitDrain(); drained.value.withLock { $0 = true } }
            try await Task.sleep(for: Self.settle)
            #expect(!drained.value.withLock { $0 }, "awaitDrain returned on a held queue while a batch was still running")
            #expect(!(await queue.isIdle))

            await release.open()
            #expect(await eventually { drained.value.withLock { $0 } }, "awaitDrain did not return after the batch ended")
            // "7" is back for a retry: this suite seeds no header rows, so its fetch fails.
            #expect(Set(await queue.queuedItemsForTesting.map(\.messageId)) == ["7", "8"],
                    "the refused second item must stay pending")
            #expect(!(await provider.callLog.contains { $0.hasPrefix("fetchMessage(") && $0.contains("id:8,") }),
                    "the refused second body was downloaded under Low Power Mode")
            #expect(await fetchCount(provider) == 1, "a body beyond the running batch was downloaded")
            drain.cancel()
        }
        await release.open()
        await queue.cancelAllInFlight()
    }

    @Test("awaitDrain returns when its caller is cancelled while a batch runs")
    func drainEndsOnCancellation() async throws {
        let accountId = "gate1064-cancel-drain"
        let provider = MockEmailProvider()
        let release = TestLatch()
        await provider.setFetchMessageHook { await release.wait() }
        let queue = BackfillBodyQueue()
        try await withAccount(accountId, provider: provider, gate: nil) {
            await queue.enqueue([backfillItem(accountId)])
            #expect(await eventually { await fetchCount(provider) > 0 }, "the batch never started")
            let drain = Task { await queue.awaitDrain() }
            drain.cancel()
            let ended = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await drain.value; return true }
                group.addTask { try? await Task.sleep(for: Self.deadline); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            #expect(ended, "a cancelled awaitDrain kept waiting")
        }
        await release.open()
        await queue.cancelAllInFlight()
    }

    @Test("cancelling a held queue stops its gate re-check: no download after the gate opens")
    func cancelStopsTheGateWatch() async throws {
        let accountId = "gate1064-cancel-watch"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        try await withAccount(accountId, provider: provider, gate: .lowPowerMode) {
            await queue.enqueue([backfillItem(accountId)])
            #expect(await eventually { await queue.heldByDownloadGate }, "precondition: the dispatch was not refused")
            try await Task.sleep(for: Self.settle)
            #expect(await fetchCount(provider) == 0, "the body was downloaded under Low Power Mode")

            // Count power reads with the gate kept closed. The re-check span covers
            // several watcher intervals.
            let reads = TestBox(0)
            SyncEngine.backfillPowerReadHookForTesting.withLock { $0 = { reads.value.withLock { $0 += 1 } } }
            defer { SyncEngine.backfillPowerReadHookForTesting.withLock { $0 = nil } }
            let span: Duration = .seconds(SyncConfig.backfillBodyGateRecheckSeconds * 3) + Self.settle
            // Positive control: the live watcher keeps reading the gate.
            try await Task.sleep(for: span)
            #expect(reads.value.withLock { $0 } > 0, "the live gate watcher never re-checked")

            await queue.cancelAllInFlight()
            try await Task.sleep(for: Self.settle)
            let afterCancel = reads.value.withLock { $0 }
            try await Task.sleep(for: span)
            #expect(reads.value.withLock { $0 } == afterCancel, "a cancelled queue's gate watcher kept polling")
            SyncEngine.backfillPowerReadHookForTesting.withLock { $0 = nil }
            openGate()
            try await Task.sleep(for: Self.deadline)
            #expect(await fetchCount(provider) == 0, "a cancelled queue downloaded once the gate opened")
        }
        await queue.cancelAllInFlight()
    }

    @Test("the gate shutting while a dispatch waits on the priority gate starts no batch")
    func gateShutDuringDispatchWaitStartsNoBatch() async throws {
        let accountId = "gate1064-dispatch-wait"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        try await withAccount(accountId, provider: provider, gate: nil) {
            // Park the dispatch at its PriorityGate wait with every gate open.
            await PriorityGate.shared.begin()
            await queue.enqueue([backfillItem(accountId)])
            try await Task.sleep(for: Self.settle)
            SyncEngine.backfillPowerStateForTesting.withLock { $0 = DownloadGateHarness.power(.lowPowerMode) }
            await PriorityGate.shared.end()
            #expect(await eventually { await queue.heldByDownloadGate }, "precondition: the parked dispatch was not refused")
            try await Task.sleep(for: Self.settle)
            #expect(await fetchCount(provider) == 0, "a batch started after the gate shut")
            #expect(await queue.queuedItemsForTesting.map(\.messageId) == ["7"], "the refused item must stay pending")

            openGate()
            #expect(await eventually { await fetchCount(provider) > 0 },
                    "the refused body was not downloaded after the gate opened")
        }
        await queue.cancelAllInFlight()
    }

    @Test("in the background job, Low Power Mode on power holds older-mail bodies, as it holds the job's walk")
    @MainActor
    func backgroundJobUnderLowPowerModeOnPowerStartsNoBatch() async throws {
        let accountId = "gate1064-job-lpm"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        let item = backfillItem(accountId)
        let fetchesDuringJob = TestBox<Int?>(nil)
        // The job sets fast sync, so the power snapshot reads fast sync on.
        let jobPower = (fastSync: true, lowPowerMode: true, onPower: true, batteryLevel: Float(1))
        try await withAccount(accountId, provider: provider, power: jobPower, expensive: false) {
            let context = BGTaskContext(label: "gate1064-job", completion: { _ in })
            let scheduler = SyncScheduler(
                backgroundReadiness: { true },
                backgroundWork: { _ in
                    await queue.enqueue([item])
                    _ = await Self.pollUntil { await queue.heldByDownloadGate }
                    try? await Task.sleep(for: Self.settle)
                    let count = await provider.callLog.filter { $0.hasPrefix("fetchMessage(") }.count
                    fetchesDuringJob.value.withLock { $0 = count }
                },
                processingHasWork: { false },
                backgroundSchedule: { _ in },
                refreshNetworkAvailable: true
            )
            scheduler.handleBackgroundAIProcessing(context: context) { _ in }
            await context.waitForTaskForTesting()
        }
        await queue.cancelAllInFlight()
        #expect(fetchesDuringJob.value.withLock { $0 } == 0, "an older-mail body downloaded in the job under Low Power Mode")
    }

    @Test("an admission parked across the power read while the background job starts under Low Power Mode starts no batch")
    @MainActor
    func admissionSpanningJobEntryUnderLowPowerModeStartsNoBatch() async throws {
        let accountId = "gate1064-job-entry"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        let item = backfillItem(accountId)
        let parked = TestBox(false)
        let admit = TestLatch()
        let fetchesDuringJob = TestBox<Int?>(nil)
        let pendingDuringJob = TestBox<[String]?>(nil)
        let settle = Self.settle
        // Before the job: no Fast Sync, Low Power Mode, on battery (refused).
        let foregroundPower = (fastSync: false, lowPowerMode: true, onPower: false, batteryLevel: Float(0.8))
        // In the job: the job's synthetic Fast Sync, still Low Power Mode on battery.
        let jobPower = (fastSync: true, lowPowerMode: true, onPower: false, batteryLevel: Float(0.8))
        SyncEngine.backfillPowerReadHookForTesting.withLock {
            $0 = {
                parked.value.withLock { $0 = true }
                await admit.wait()
            }
        }
        defer { SyncEngine.backfillPowerReadHookForTesting.withLock { $0 = nil } }
        try await withAccount(accountId, provider: provider, power: foregroundPower, expensive: false) {
            // The admission decision starts outside the job and parks in its power read.
            await queue.enqueue([item])
            #expect(await eventually { parked.value.withLock { $0 } }, "the admission never reached the power read")

            let context = BGTaskContext(label: "gate1064-job-entry", completion: { _ in })
            let scheduler = SyncScheduler(
                backgroundReadiness: { true },
                backgroundWork: { _ in
                    // Inside the real job: the power read now sees the job's Fast Sync.
                    SyncEngine.backfillPowerStateForTesting.withLock { $0 = jobPower }
                    await admit.open()
                    _ = await Self.pollUntil { await queue.heldByDownloadGate }
                    try? await Task.sleep(for: settle)
                    let count = await provider.callLog.filter { $0.hasPrefix("fetchMessage(") }.count
                    fetchesDuringJob.value.withLock { $0 = count }
                    let pending = await queue.queuedItemsForTesting.map(\.messageId)
                    pendingDuringJob.value.withLock { $0 = pending }
                },
                processingHasWork: { false },
                backgroundSchedule: { _ in },
                refreshNetworkAvailable: true
            )
            scheduler.handleBackgroundAIProcessing(context: context) { _ in }
            await context.waitForTaskForTesting()
        }
        await admit.open()
        await queue.cancelAllInFlight()
        #expect(fetchesDuringJob.value.withLock { $0 } == 0,
                "an admission that spanned job entry downloaded an older-mail body under Low Power Mode")
        #expect(pendingDuringJob.value.withLock { $0 } == ["7"], "the refused item must stay pending")
    }

    @Test("a decision that read power inside the job and is used after the job ends starts no batch under Low Power Mode")
    @MainActor
    func decisionSpanningJobExitUnderLowPowerModeStartsNoBatch() async throws {
        let accountId = "gate1064-job-exit"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        let item = backfillItem(accountId)
        let parked = TestBox(false)
        let decide = TestLatch()
        let deadline = Self.deadline
        // Device readings only: no user Fast Sync, Low Power Mode, on battery. The
        // job's own Fast Sync comes from the real handler.
        let power = (fastSync: false, lowPowerMode: true, onPower: false, batteryLevel: Float(0.8))
        SyncEngine.backfillAdmissionDecisionHookForTesting.withLock {
            $0 = {
                parked.value.withLock { $0 = true }
                await decide.wait()
            }
        }
        defer { SyncEngine.backfillAdmissionDecisionHookForTesting.withLock { $0 = nil } }
        try await withAccount(accountId, provider: provider, power: power, expensive: false) {
            let context = BGTaskContext(label: "gate1064-job-exit", completion: { _ in })
            let scheduler = SyncScheduler(
                backgroundReadiness: { true },
                backgroundWork: { _ in
                    // The decision reads power and the job flag inside the job, then parks.
                    await queue.enqueue([item])
                    let clock = ContinuousClock()
                    let end = clock.now.advanced(by: deadline)
                    while clock.now < end, !parked.value.withLock({ $0 }) {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                },
                processingHasWork: { false },
                backgroundSchedule: { _ in },
                refreshNetworkAvailable: true
            )
            scheduler.handleBackgroundAIProcessing(context: context) { _ in }
            await context.waitForTaskForTesting()
            #expect(parked.value.withLock { $0 }, "the decision never parked inside the job")
            #expect(!SyncEngine.backgroundProcessingJobActive.withLock { $0 }, "precondition: the job has ended")

            // The job has ended; the parked decision now completes.
            await decide.open()
            #expect(await eventually { await queue.heldByDownloadGate }, "precondition: the parked decision was not refused")
            try await Task.sleep(for: Self.settle)
            #expect(await fetchCount(provider) == 0,
                    "a decision spanning job exit downloaded an older-mail body under Low Power Mode")
            #expect(await queue.queuedItemsForTesting.map(\.messageId) == ["7"], "the refused item must stay pending")
        }
        await decide.open()
        await queue.cancelAllInFlight()
    }

    @Test("in the background job, Wi-Fi-only holds older-mail bodies when the job measured cellular, whatever NetworkMonitor says; a later job that measures Wi-Fi downloads them")
    @MainActor
    func backgroundJobWifiOnlyExpensiveHoldsThenResumes() async throws {
        let accountId = "gate1064-job-wifi"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        let item = backfillItem(accountId)
        let fetchesOnCellular = TestBox<Int?>(nil)
        let pendingOnCellular = TestBox<[String]?>(nil)
        let resumedInSecondJob = TestBox(false)
        // The job sets fast sync; Low Power Mode off; the harness keeps Wi-Fi-only on.
        let jobPower = (fastSync: true, lowPowerMode: false, onPower: true, batteryLevel: Float(1))
        try await withAccount(accountId, provider: provider, power: jobPower, expensive: false) {
            // NetworkMonitor reports an unmetered network, but the job's own
            // measurement says cellular: the job's measurement decides.
            SyncScheduler.jobOnWiFiMeasurementForTesting.withLock { $0 = false }
            let first = BGTaskContext(label: "gate1064-job-wifi-1", completion: { _ in })
            let onCellular = SyncScheduler(
                backgroundReadiness: { true },
                backgroundWork: { _ in
                    await queue.enqueue([item])
                    _ = await Self.pollUntil { await queue.heldByDownloadGate }
                    try? await Task.sleep(for: Self.settle)
                    let count = await provider.callLog.filter { $0.hasPrefix("fetchMessage(") }.count
                    fetchesOnCellular.value.withLock { $0 = count }
                    let pending = await queue.queuedItemsForTesting.map(\.messageId)
                    pendingOnCellular.value.withLock { $0 = pending }
                    // Still inside the job: the monitor becomes unknown, so the
                    // queue's watcher cannot download between the two jobs.
                    NetworkMonitor.setExpensiveForTesting(nil)
                },
                processingHasWork: { false },
                backgroundSchedule: { _ in },
                refreshNetworkAvailable: true
            )
            onCellular.handleBackgroundAIProcessing(context: first) { _ in }
            await first.waitForTaskForTesting()

            // The next job measures Wi-Fi; NetworkMonitor stays unknown.
            SyncScheduler.jobOnWiFiMeasurementForTesting.withLock { $0 = true }
            let second = BGTaskContext(label: "gate1064-job-wifi-2", completion: { _ in })
            let onWiFi = SyncScheduler(
                backgroundReadiness: { true },
                backgroundWork: { _ in
                    let resumed = await Self.pollUntil {
                        await provider.callLog.contains { $0.hasPrefix("fetchMessage(") }
                    }
                    resumedInSecondJob.value.withLock { $0 = resumed }
                },
                processingHasWork: { false },
                backgroundSchedule: { _ in },
                refreshNetworkAvailable: true
            )
            onWiFi.handleBackgroundAIProcessing(context: second) { _ in }
            await second.waitForTaskForTesting()
        }
        await queue.cancelAllInFlight()
        #expect(fetchesOnCellular.value.withLock { $0 } == 0,
                "an older-mail body downloaded in a job that measured cellular with Wi-Fi-only on")
        #expect(pendingOnCellular.value.withLock { $0 } == ["7"], "the held item must stay pending in the job")
        #expect(resumedInSecondJob.value.withLock { $0 }, "the download did not resume in a job that measured Wi-Fi")
    }

    @Test("in the background job, the work (its scans) starts while the Wi-Fi reading is still unknown; older-mail bodies hold until it lands, then follow it")
    @MainActor
    func backgroundJobWorkStartsBeforeTheWiFiReadingAndBodiesWaitForIt() async throws {
        let accountId = "gate1064-job-held-reading"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        let item = backfillItem(accountId)
        let released = TestBox(false)
        let workStartedWhileUnknown = TestBox(false)
        let fetchesWhileUnknown = TestBox<Int?>(nil)
        let downloadedAfterLanding = TestBox(false)
        let jobPower = (fastSync: true, lowPowerMode: false, onPower: true, batteryLevel: Float(1))
        try await withAccount(accountId, provider: provider, power: jobPower, expensive: false) {
            SyncScheduler.jobOnWiFiMeasurementHoldForTesting.withLock {
                $0 = {
                    while !released.value.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(50)) }
                    return true
                }
            }
            defer { SyncScheduler.jobOnWiFiMeasurementHoldForTesting.withLock { $0 = nil } }
            let context = BGTaskContext(label: "gate1064-job-held-reading", completion: { _ in })
            let scheduler = SyncScheduler(
                backgroundReadiness: { true },
                backgroundWork: { _ in
                    // The work (syncStartup and its scans in production) runs now,
                    // with the job active and its reading unknown.
                    let state = await SyncEngine.currentBackfillPowerAndJobState()
                    workStartedWhileUnknown.value.withLock { $0 = state.jobActive && state.jobOnWiFi == nil }
                    await queue.enqueue([item])
                    _ = await Self.pollUntil { await queue.heldByDownloadGate }
                    try? await Task.sleep(for: Self.settle)
                    let count = await provider.callLog.filter { $0.hasPrefix("fetchMessage(") }.count
                    fetchesWhileUnknown.value.withLock { $0 = count }
                    // The reading lands on Wi-Fi; the gate watcher's re-check lifts the hold.
                    released.value.withLock { $0 = true }
                    let resumed = await Self.pollUntil {
                        await provider.callLog.contains { $0.hasPrefix("fetchMessage(") }
                    }
                    downloadedAfterLanding.value.withLock { $0 = resumed }
                },
                processingHasWork: { false },
                backgroundSchedule: { _ in },
                refreshNetworkAvailable: true
            )
            scheduler.handleBackgroundAIProcessing(context: context) { _ in }
            await context.waitForTaskForTesting()
        }
        await queue.cancelAllInFlight()
        #expect(workStartedWhileUnknown.value.withLock { $0 }, "the job's work waited for the Wi-Fi reading")
        #expect(fetchesWhileUnknown.value.withLock { $0 } == 0, "an older-mail body downloaded before the job's Wi-Fi reading landed")
        #expect(downloadedAfterLanding.value.withLock { $0 }, "the body did not download once the reading landed on Wi-Fi")
        #expect(SyncEngine.backgroundProcessingJobOnWiFi.withLock { $0 } == nil, "the job's reading must be cleared at job end")
    }

    @Test("in the background job, the backfill's scans run while the Wi-Fi reading is unknown; the walk waits for the reading and follows it",
          arguments: [true, false])
    @MainActor
    func backgroundJobWalkWaitsForTheReadingButScansDoNot(_ landsOnWiFi: Bool) async throws {
        let released = TestBox(false)
        let calls = TestBox<[Bool]>([])
        let callsWhileUnknown = TestBox<[Bool]?>(nil)
        let account = Account(emailAddress: "user@example.com", displayName: "Walk", provider: .imap)
        SyncScheduler.jobOnWiFiMeasurementHoldForTesting.withLock {
            $0 = {
                while !released.value.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(50)) }
                return landsOnWiFi
            }
        }
        SyncEngine.backfillSleepForTesting.withLock { $0 = { _ in try? await Task.sleep(for: .milliseconds(50)) } }
        defer {
            SyncScheduler.jobOnWiFiMeasurementHoldForTesting.withLock { $0 = nil }
            SyncEngine.backfillSleepForTesting.withLock { $0 = nil }
        }
        let context = BGTaskContext(label: "gate1064-job-walk", completion: { _ in })
        let scheduler = SyncScheduler(
            backgroundReadiness: { true },
            backgroundWork: { _ in
                let onWiFi = SyncEngine.backgroundProcessingJobOnWiFi.withLock { $0 }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await SyncScheduler.runBackgroundBackfill(
                            accounts: [account], isLowPowerMode: false, wifiOnly: true, onWiFi: onWiFi,
                            budget: SyncConfig.backgroundBackfillDeadlineSeconds,
                            awaitOnWiFi: { await SyncEngine.awaitBackgroundProcessingJobOnWiFi() }
                        ) { _, walkAllowed, _ in
                            calls.value.withLock { $0.append(walkAllowed) }
                        }
                    }
                    group.addTask {
                        _ = await Self.pollUntil { !calls.value.withLock { $0 }.isEmpty }
                        try? await Task.sleep(for: Self.settle)
                        callsWhileUnknown.value.withLock { $0 = calls.value.withLock { $0 } }
                        released.value.withLock { $0 = true }
                    }
                }
            },
            processingHasWork: { false },
            backgroundSchedule: { _ in },
            refreshNetworkAvailable: true
        )
        scheduler.handleBackgroundAIProcessing(context: context) { _ in }
        await context.waitForTaskForTesting()
        #expect(callsWhileUnknown.value.withLock { $0 } == [false],
                "while the reading is unknown the backfill (its scans) must run at once with the walk held")
        #expect(calls.value.withLock { $0 } == [false, landsOnWiFi],
                "once the reading lands the account runs as with a known reading: the walk follows it with Wi-Fi-only on")
    }

    /// The facts of a network path, classified by the production rule
    /// (`SyncEngine.onUnmeteredNetwork`), with what every Wi-Fi-only download
    /// decision must do on it.
    struct PathCase: Sendable, CustomTestStringConvertible {
        let name: String
        let facts: NetworkPathFacts
        let downloads: Bool
        var testDescription: String { name }

        static let all: [PathCase] = [
            PathCase(name: "personal-hotspot", facts: DownloadGateHarness.personalHotspot, downloads: false),
            PathCase(name: "unmetered-wifi", facts: DownloadGateHarness.unmeteredWiFi, downloads: true),
            PathCase(name: "wired", facts: DownloadGateHarness.wired, downloads: true),
            PathCase(name: "cellular", facts: DownloadGateHarness.cellular, downloads: false),
            PathCase(name: "unsatisfied",
                     facts: NetworkPathFacts(satisfied: false, isExpensive: false), downloads: false),
        ]
    }

    @Test("with Wi-Fi-only on, \"on Wi-Fi\" means an unmetered network for all three decisions: the foreground gate, the job's bodies and the job's walk",
          arguments: PathCase.all)
    @MainActor
    func pathFactsDecideEveryWiFiOnlyDownload(_ input: PathCase) async throws {
        let accountId = "gate1064-path-\(input.name)"
        let provider = MockEmailProvider()
        let foregroundQueue = BackfillBodyQueue()
        let jobQueue = BackfillBodyQueue()
        let account = Account(emailAddress: "user@example.com", displayName: "Path", provider: .imap)
        let foregroundWalk = TestBox<Bool?>(nil)
        let foregroundFetched = TestBox<Int?>(nil)
        let jobFetched = TestBox<Int?>(nil)
        let jobWalk = TestBox<[Bool]>([])
        let settle = Self.settle
        try await withAccount(accountId, provider: provider, power: Self.openPower, expensive: false, path: input.facts) {
            // Foreground: the walk's decision and a real body dispatch.
            foregroundWalk.value.withLock { $0 = SyncEngine.backfillDownloadsAllowed(power: Self.openPower, wifiOnly: true) }
            await foregroundQueue.enqueue([backfillItem(accountId, messageId: "7")])
            if input.downloads {
                _ = await eventually { await fetchCount(provider) > 0 }
            } else {
                _ = await eventually { await foregroundQueue.heldByDownloadGate }
                try await Task.sleep(for: settle)
            }
            let afterForeground = await fetchCount(provider)
            foregroundFetched.value.withLock { $0 = afterForeground }
            await foregroundQueue.cancelAllInFlight()

            // The job: its own measurement of the same path decides its bodies and its walk.
            let context = BGTaskContext(label: "gate1064-path", completion: { _ in })
            let scheduler = SyncScheduler(
                backgroundReadiness: { true },
                backgroundWork: { _ in
                    _ = await SyncEngine.awaitBackgroundProcessingJobOnWiFi()
                    let before = await provider.callLog.filter { $0.hasPrefix("fetchMessage(") }.count
                    await jobQueue.enqueue([BackfillBodyQueue.Item(
                        headerId: "\(accountId):Archive:8", accountId: accountId,
                        folderPath: "Archive", messageId: "8", isInInbox: false)])
                    if input.downloads {
                        _ = await Self.pollUntil { await provider.callLog.filter { $0.hasPrefix("fetchMessage(") }.count > before }
                    } else {
                        _ = await Self.pollUntil { await jobQueue.heldByDownloadGate }
                        try? await Task.sleep(for: settle)
                    }
                    let after = await provider.callLog.filter { $0.hasPrefix("fetchMessage(") }.count
                    jobFetched.value.withLock { $0 = after - before }
                    await SyncScheduler.runBackgroundBackfill(
                        accounts: [account], isLowPowerMode: false, wifiOnly: true,
                        onWiFi: SyncEngine.backgroundProcessingJobOnWiFi.withLock { $0 },
                        budget: SyncConfig.backgroundBackfillDeadlineSeconds,
                        awaitOnWiFi: { await SyncEngine.awaitBackgroundProcessingJobOnWiFi() }
                    ) { _, walkAllowed, _ in
                        jobWalk.value.withLock { $0.append(walkAllowed) }
                    }
                },
                processingHasWork: { false },
                backgroundSchedule: { _ in },
                refreshNetworkAvailable: true
            )
            scheduler.handleBackgroundAIProcessing(context: context) { _ in }
            await context.waitForTaskForTesting()
        }
        await jobQueue.cancelAllInFlight()
        #expect(foregroundWalk.value.withLock { $0 } == input.downloads, "foreground walk on \(input.name)")
        let foreground = try #require(foregroundFetched.value.withLock { $0 })
        #expect((foreground > 0) == input.downloads, "foreground older-mail body on \(input.name): \(foreground) fetches")
        let job = try #require(jobFetched.value.withLock { $0 }, "the job's work never ran")
        #expect((job > 0) == input.downloads, "job older-mail body on \(input.name): \(job) fetches")
        #expect(jobWalk.value.withLock { $0 } == [input.downloads], "job walk on \(input.name)")
    }

    /// One background-job input set for the body gate (#1064): Low Power Mode,
    /// the Wi-Fi-only setting, the job's own Wi-Fi measurement, and what
    /// NetworkMonitor holds (nil: never started, as in a job that launched the app
    /// from terminated).
    struct JobNetworkCase: Sendable, CustomTestStringConvertible {
        let lowPowerMode: Bool
        let wifiOnly: Bool
        let jobOnWiFi: Bool
        let monitorExpensive: Bool?

        var label: String {
            let monitor = monitorExpensive.map { $0 ? "expensive" : "unmetered" } ?? "unknown"
            return "lpm-\(lowPowerMode)-wifiOnly-\(wifiOnly)-jobOnWiFi-\(jobOnWiFi)-monitor-\(monitor)"
        }
        var testDescription: String { label }

        static let all: [JobNetworkCase] = {
            let monitors: [Bool?] = [nil, false]
            var cases: [JobNetworkCase] = []
            for lowPowerMode in [false, true] {
                for wifiOnly in [false, true] {
                    for jobOnWiFi in [false, true] {
                        for monitor in monitors {
                            cases.append(JobNetworkCase(
                                lowPowerMode: lowPowerMode, wifiOnly: wifiOnly,
                                jobOnWiFi: jobOnWiFi, monitorExpensive: monitor))
                        }
                    }
                }
            }
            return cases
        }()
    }

    private struct JobOutcome: Sendable {
        let fetched: Int
        let held: Bool
        let pending: [String]
    }

    @Test("in the background job, older-mail bodies are held exactly when the job's walk is held, from the job's own Wi-Fi measurement",
          arguments: JobNetworkCase.all)
    @MainActor
    func backgroundJobBodiesFollowTheJobWalkDecision(_ input: JobNetworkCase) async throws {
        let accountId = "gate1064-jobnet-\(input.label)"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        let item = backfillItem(accountId)
        // The job's walk decision for these inputs: its rule, fed the job's measurement.
        let walkAllowed = SyncScheduler.backgroundBackfillPlan(
            isLowPowerMode: input.lowPowerMode, wifiOnly: input.wifiOnly, onWiFi: input.jobOnWiFi)
        let outcome = TestBox<JobOutcome?>(nil)
        let settle = Self.settle
        // Device readings: on battery with a healthy level; the job adds its Fast Sync.
        let power = (fastSync: false, lowPowerMode: input.lowPowerMode, onPower: false, batteryLevel: Float(0.8))
        try await withAccount(accountId, provider: provider, power: power, expensive: false, wifiOnly: input.wifiOnly) {
            NetworkMonitor.setExpensiveForTesting(input.monitorExpensive)
            SyncScheduler.jobOnWiFiMeasurementForTesting.withLock { $0 = input.jobOnWiFi }
            let context = BGTaskContext(label: "gate1064-jobnet", completion: { _ in })
            let scheduler = SyncScheduler(
                backgroundReadiness: { true },
                backgroundWork: { _ in
                    await queue.enqueue([item])
                    if walkAllowed {
                        _ = await Self.pollUntil { await provider.callLog.contains { $0.hasPrefix("fetchMessage(") } }
                    } else {
                        _ = await Self.pollUntil { await queue.heldByDownloadGate }
                        try? await Task.sleep(for: settle)
                    }
                    let fetched = await provider.callLog.filter { $0.hasPrefix("fetchMessage(") }.count
                    let held = await queue.heldByDownloadGate
                    let pending = await queue.queuedItemsForTesting.map(\.messageId)
                    outcome.value.withLock { $0 = JobOutcome(fetched: fetched, held: held, pending: pending) }
                },
                processingHasWork: { false },
                backgroundSchedule: { _ in },
                refreshNetworkAvailable: true
            )
            scheduler.handleBackgroundAIProcessing(context: context) { _ in }
            await context.waitForTaskForTesting()
        }
        await queue.cancelAllInFlight()
        let result = try #require(outcome.value.withLock { $0 }, "the job's work never ran")
        if walkAllowed {
            #expect(result.fetched > 0, "the job's walk runs but the older-mail body was held (\(input.label))")
        } else {
            #expect(result.held, "the job's walk is held but the body dispatch was not refused (\(input.label))")
            #expect(result.fetched == 0, "the job's walk is held but an older-mail body downloaded (\(input.label))")
            #expect(result.pending == ["7"], "the held item must stay pending (\(input.label))")
        }
    }

    @Test("outside the job, a network NetworkMonitor has not reported yet holds older-mail bodies until a path update reports it unmetered")
    func unknownNetworkHoldsUntilUnmeteredPathUpdate() async throws {
        let accountId = "gate1064-unknown-network"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        try await withAccount(accountId, provider: provider, power: Self.openPower, expensive: false) {
            // No path update yet (the monitor is not started).
            NetworkMonitor.setExpensiveForTesting(nil)
            await queue.enqueue([backfillItem(accountId)])
            #expect(await eventually { await queue.heldByDownloadGate },
                    "the dispatch was not refused on a network the monitor has not reported")
            try await Task.sleep(for: Self.settle)
            #expect(await fetchCount(provider) == 0, "an older-mail body downloaded on an unknown network with Wi-Fi-only on")
            #expect(await queue.queuedItemsForTesting.map(\.messageId) == ["7"], "the held item must stay pending")

            // The first path update reports an unmetered network.
            NetworkMonitor.setExpensiveForTesting(false)
            #expect(await eventually { await fetchCount(provider) > 0 },
                    "the held body was not downloaded once the network was reported unmetered")
        }
        await queue.cancelAllInFlight()
    }

    @Test("a user's Fast Sync still lifts Low Power Mode for older-mail bodies outside the job")
    func foregroundFastSyncStillDownloads() async throws {
        let accountId = "gate1064-fast-sync"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        let power = (fastSync: true, lowPowerMode: true, onPower: false, batteryLevel: Float(0.8))
        try await withAccount(accountId, provider: provider, power: power, expensive: false) {
            await queue.enqueue([backfillItem(accountId)])
            #expect(await eventually { await fetchCount(provider) > 0 })
        }
        await queue.cancelAllInFlight()
    }

    @Test("ActiveBodyQueue is not gated", arguments: DownloadGate.allCases)
    func activeQueueUngated(_ gate: DownloadGate) async throws {
        let accountId = "gate1064-active-\(gate.rawValue)"
        let provider = MockEmailProvider()
        let queue = ActiveBodyQueue()
        try await withAccount(accountId, provider: provider, gate: gate) {
            await queue.enqueue(header: MessageHeader(
                messageId: "9", subject: "gate", from: "Sender", fromAddress: "sender@example.com",
                to: "user@example.com", date: Date(), snippet: "",
                folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX"),
                accountId: accountId, folderPath: "INBOX", isInInbox: true))
            #expect(await eventually { await fetchCount(provider) > 0 }, "the inbox body was held under \(gate)")
        }
        await queue.cancelAllInFlight()
    }

    @Test("opening an older non-Inbox message downloads its body while older-mail downloads are held",
          arguments: DownloadGate.allCases)
    func openedOlderMessageDownloadsUnderEveryGate(_ gate: DownloadGate) async throws {
        let accountId = "gate1064-open-\(gate.rawValue)"
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        let uidValidity = 202
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool, lastKnownUidValidity: uidValidity)
        let olderDate = try #require(Calendar.current.date(byAdding: .year, value: -2, to: Date()))
        var header = MessageHeader(
            messageId: "7", subject: "older", from: "Sender", fromAddress: "sender@example.com",
            to: "user@example.com", date: olderDate, snippet: "",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "Archive"),
            accountId: accountId, folderPath: "Archive", isInInbox: false)
        header.rfc822MessageId = "older@example.com"
        header.observedUidValidity = uidValidity
        header.headerComplete = true
        let toInsert = header
        try await pool.write { db in try toInsert.insert(db) }

        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        try await withAccount(accountId, provider: provider, gate: gate) {
            await queue.enqueue([backfillItem(accountId)])
            try await Task.sleep(for: Self.settle)
            #expect(await fetchCount(provider) == 0, "precondition: older-mail downloads are held under \(gate)")

            // MessageDetailViewModel.loadBody -> AccountManager.fetchBody.
            do { try await AccountManager.shared.fetchBody(for: header) } catch {
                // The mock has no message to return; reaching the provider is the observable.
            }
            #expect(await fetchCount(provider) > 0, "the opened message's body was held under \(gate)")
        }
        await queue.cancelAllInFlight()
    }
}

/// A shared value a test reads after concurrent work wrote it.
private final class TestBox<Value: Sendable>: Sendable {
    let value: Mutex<Value>
    init(_ initial: Value) { value = Mutex(initial) }
}

/// A one-shot gate a test opens to let parked work continue.
private actor TestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resume = waiters
        waiters.removeAll()
        for waiter in resume { waiter.resume() }
    }
}

private extension AccountManager {
    func installBodyGateTestProvider(accountId: String, provider: any EmailProvider, queue: ProviderWorkQueue) {
        providers[accountId] = provider
        workQueues[accountId] = queue
    }

    func removeBodyGateTestProvider(accountId: String) {
        providers.removeValue(forKey: accountId)
        workQueues.removeValue(forKey: accountId)
    }
}
