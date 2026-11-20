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
/// power, Low Power Mode off power; in the background job, the body gate tests
/// for a not-expensive network while the job's walk tests isOnWiFi, both
/// refusing cellular). ActiveBodyQueue (new mail) and a message the user opens are not
/// gated. The observables are the provider (a held download never reaches it)
/// and the queue's pending items.
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
    private func withAccount(
        _ accountId: String, provider: MockEmailProvider, gate: DownloadGate?,
        _ body: () async throws -> Void
    ) async throws {
        try await withAccount(accountId, provider: provider,
                              power: gate.map(DownloadGateHarness.power) ?? Self.openPower,
                              expensive: gate == .expensiveNetwork, body)
    }

    private func withAccount(
        _ accountId: String, provider: MockEmailProvider,
        power: (fastSync: Bool, lowPowerMode: Bool, onPower: Bool, batteryLevel: Float), expensive: Bool,
        _ body: () async throws -> Void
    ) async throws {
        await AccountManager.shared.installBodyGateTestProvider(
            accountId: accountId, provider: provider, queue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
        SyncEngine.backfillPowerStateForTesting.withLock { $0 = power }
        defer { SyncEngine.backfillPowerStateForTesting.withLock { $0 = nil } }
        NetworkMonitor.setConnectedForTesting(true)
        do {
            try await DownloadGateHarness.withNetwork(expensive: expensive) { try await body() }
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
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: Self.deadline)
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

            let drained = TestBox(false)
            let drain = Task { await queue.awaitDrain(); drained.value.withLock { $0 = true } }
            try await Task.sleep(for: Self.settle)
            #expect(!drained.value.withLock { $0 }, "awaitDrain returned while a batch was still running")
            #expect(!(await queue.isIdle))

            await release.open()
            #expect(await eventually { drained.value.withLock { $0 } }, "awaitDrain did not return after the batch ended")
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
            try await Task.sleep(for: Self.settle)
            #expect(await fetchCount(provider) == 0, "the body was downloaded under Low Power Mode")
            await queue.cancelAllInFlight()
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

    @Test("in the background job, Wi-Fi-only on an expensive network holds older-mail bodies until the network is unmetered")
    @MainActor
    func backgroundJobWifiOnlyExpensiveHoldsThenResumes() async throws {
        let accountId = "gate1064-job-wifi"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        let item = backfillItem(accountId)
        let fetchesWhileExpensive = TestBox<Int?>(nil)
        let pendingWhileExpensive = TestBox<[String]?>(nil)
        let resumedInJob = TestBox(false)
        let deadline = Self.deadline
        // The job sets fast sync; Low Power Mode off; the harness keeps Wi-Fi-only on.
        let jobPower = (fastSync: true, lowPowerMode: false, onPower: true, batteryLevel: Float(1))
        try await withAccount(accountId, provider: provider, power: jobPower, expensive: true) {
            let context = BGTaskContext(label: "gate1064-job-wifi", completion: { _ in })
            let scheduler = SyncScheduler(
                backgroundReadiness: { true },
                backgroundWork: { _ in
                    await queue.enqueue([item])
                    try? await Task.sleep(for: Self.settle)
                    let count = await provider.callLog.filter { $0.hasPrefix("fetchMessage(") }.count
                    fetchesWhileExpensive.value.withLock { $0 = count }
                    let pending = await queue.queuedItemsForTesting.map(\.messageId)
                    pendingWhileExpensive.value.withLock { $0 = pending }

                    // Still inside the job: the network becomes unmetered.
                    NetworkMonitor.setExpensiveForTesting(false)
                    let clock = ContinuousClock()
                    let end = clock.now.advanced(by: deadline)
                    while clock.now < end {
                        if await provider.callLog.contains(where: { $0.hasPrefix("fetchMessage(") }) {
                            resumedInJob.value.withLock { $0 = true }
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                },
                processingHasWork: { false },
                backgroundSchedule: { _ in },
                refreshNetworkAvailable: true
            )
            scheduler.handleBackgroundAIProcessing(context: context) { _ in }
            await context.waitForTaskForTesting()
        }
        await queue.cancelAllInFlight()
        #expect(fetchesWhileExpensive.value.withLock { $0 } == 0,
                "an older-mail body downloaded in the job on an expensive network with Wi-Fi-only on")
        #expect(pendingWhileExpensive.value.withLock { $0 } == ["7"], "the held item must stay pending in the job")
        #expect(resumedInJob.value.withLock { $0 }, "the download did not resume in the job once the network was unmetered")
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
