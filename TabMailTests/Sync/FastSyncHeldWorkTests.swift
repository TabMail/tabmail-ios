/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import UIKit
import Synchronization
import Testing
@testable import TabMail

/// #1098: Fast Sync's screen lock counts only work that can make progress now.
/// When everything left is held by the download gates (the older-mail walk gate,
/// #1063, and BackfillBodyQueue's gate, #1064), the lock releases and the
/// "~X remaining" line reads "Waiting for Wi-Fi"; the moment anything can move,
/// the lock is held again and the caption goes. The lock's inputs are the walk
/// and the two body queues only: AI queues and catch-up scans never hold it.
/// Driven through the screen's own
/// poll (`FastSyncView.pollKeepAwakeInputs`, real folder rows, the real shared
/// body queues, the real gate decision) and its decisions (`holdAwake`,
/// `waitingForWiFi`), on the foreground path and inside the BGProcessing job.
@Suite("Fast Sync lock and caption follow held work", .serialized, .processGlobalState)
@MainActor
struct FastSyncHeldWorkTests {
    private static let deadline: Duration = .seconds(20)
    private static let openPower: (fastSync: Bool, lowPowerMode: Bool, onPower: Bool, batteryLevel: Float) =
        (fastSync: false, lowPowerMode: false, onPower: false, batteryLevel: 0.8)

    /// What remains for the account.
    enum Remaining: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The header walk is unfinished (walk phase); no body is queued.
        case walk
        /// The walk is done; one older-mail body is queued (indexing phase).
        case bodies
        var testDescription: String { rawValue }
    }

    struct Decision: Sendable {
        let holdAwake: Bool
        let waitingForWiFi: Bool
    }

    // MARK: - Fixture

    /// One account whose folder walk is done or not, with a real app DB, the
    /// account's provider installed for the body queues, and both shared queues
    /// emptied before and after.
    private static func withAccount(
        _ id: String, walkDone: Bool, _ body: (Account, MockEmailProvider) async throws -> Void
    ) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let provider = MockEmailProvider()
        await ActiveBodyQueue.shared.emptyForTesting()
        await BackfillBodyQueue.shared.emptyForTesting()
        await Self.emptyAIQueues()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let account = try FolderEpochTestFixture.makeAccount(id: id, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: id, path: "INBOX", role: .inbox, pool: pool)
        try FastSyncWakeLockTests.setWalkComplete(walkDone, accountId: id, path: "INBOX", pool: pool)
        await AccountManager.shared.installHeldWorkTestProvider(
            accountId: id, provider: provider, queue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
        let savedConnected = NetworkMonitor.checkConnected()
        NetworkMonitor.setConnectedForTesting(true)
        defer { NetworkMonitor.setConnectedForTesting(savedConnected) }
        do {
            try await body(account, provider)
        } catch {
            await Self.cleanUp(id)
            throw error
        }
        await Self.cleanUp(id)
    }

    private static func cleanUp(_ id: String) async {
        await ActiveBodyQueue.shared.emptyForTesting()
        await BackfillBodyQueue.shared.emptyForTesting()
        await Self.emptyAIQueues()
        SyncEngine.backfillWalkStartedHookForTesting.withLock { $0 = nil }
        await AccountManager.shared.removeHeldWorkTestProvider(accountId: id)
    }

    private static func emptyAIQueues() async {
        await ActiveAIQueue.shared.clearForTesting()
        await ActiveAIQueue.shared.setDispatchSuppressedForTesting(false)
    }

    /// Queues one older-mail body on the shared queue and, when the gate is
    /// shut, waits until its dispatch was refused.
    private static func queueBody(_ accountId: String, expectHeld: Bool) async {
        await BackfillBodyQueue.shared.enqueue([BackfillBodyQueue.Item(
            headerId: "\(accountId):Archive:7", accountId: accountId,
            folderPath: "Archive", messageId: "7", isInInbox: false)])
        if expectHeld {
            #expect(await pollUntil { await BackfillBodyQueue.shared.heldByDownloadGate },
                    "precondition: the older-mail body was not refused by the gate")
        }
    }

    /// One poll then both decisions, as the screen does on each timer tick.
    private static func decide(_ accounts: [Account], engine: SyncEngine = SyncEngine()) async -> Decision {
        let poll = await FastSyncView.pollKeepAwakeInputs(accounts: accounts, engine: engine)
        return Decision(holdAwake: FastSyncView.holdAwake(accounts: accounts, poll: poll),
                        waitingForWiFi: FastSyncView.waitingForWiFi(accounts: accounts, poll: poll))
    }

    private static func pollUntil(_ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        while clock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    private static func withPower(
        _ power: (fastSync: Bool, lowPowerMode: Bool, onPower: Bool, batteryLevel: Float),
        _ body: () async throws -> Void
    ) async rethrows {
        let saved = SyncEngine.backfillPowerStateForTesting.withLock { $0 }
        SyncEngine.backfillPowerStateForTesting.withLock { $0 = power }
        defer { SyncEngine.backfillPowerStateForTesting.withLock { $0 = saved } }
        try await body()
    }

    /// Opens every gate on the foreground path.
    private static func openGate() {
        SyncEngine.backfillPowerStateForTesting.withLock { $0 = openPower }
        NetworkMonitor.setExpensiveForTesting(false)
    }

    // MARK: - Foreground

    @Test("foreground: only held work left releases the lock and shows Waiting for Wi-Fi; once the gate opens the lock holds and the caption goes",
          arguments: DownloadGate.allCases, Remaining.allCases)
    func foregroundHeldThenMoving(_ gate: DownloadGate, _ remaining: Remaining) async throws {
        try await Self.withAccount("held1098-fg-\(gate.rawValue)-\(remaining.rawValue)", walkDone: remaining == .bodies) { account, _ in
            await Self.withPower(DownloadGateHarness.power(gate)) {
                await DownloadGateHarness.withNetwork(expensive: gate == .expensiveNetwork) {
                    if remaining == .bodies { await Self.queueBody(account.id, expectHeld: true) }
                    let held = await Self.decide([account])
                    #expect(!held.holdAwake, "only held \(remaining) left under \(gate): the screen may lock")
                    #expect(held.waitingForWiFi, "only held \(remaining) left under \(gate): the caption reads Waiting for Wi-Fi")

                    // The gate opens: the work can move before the queue's own
                    // re-check has dispatched anything.
                    Self.openGate()
                    let moving = await Self.decide([account])
                    #expect(moving.holdAwake, "\(remaining) can move: the screen stays awake")
                    #expect(!moving.waitingForWiFi, "\(remaining) can move: the caption is the estimate again")
                }
            }
        }
    }

    @Test("foreground: held older-mail bodies with an unfinished walk that can move keep the screen awake and show no caption")
    func heldBodiesButWalkMovingHolds() async throws {
        try await Self.withAccount("held1098-fg-walk-moving", walkDone: false) { account, _ in
            await Self.withPower(Self.openPower) {
                await DownloadGateHarness.withNetwork(expensive: false) {
                    // Hold the body queue under Wi-Fi-only on cellular, then the
                    // network turns unmetered: the queue still reads held until its
                    // re-check, but the walk can move now.
                    NetworkMonitor.setExpensiveForTesting(true)
                    await Self.queueBody(account.id, expectHeld: true)
                    NetworkMonitor.setExpensiveForTesting(false)
                    let decision = await Self.decide([account])
                    #expect(decision.holdAwake, "the walk can move: the screen stays awake")
                    #expect(!decision.waitingForWiFi)
                }
            }
        }
    }

    @Test("foreground: new-mail bodies in the active queue keep the screen awake while everything else is held",
          arguments: Remaining.allCases)
    func activeQueueWorkHoldsWhileOlderWorkHeld(_ remaining: Remaining) async throws {
        try await Self.withAccount("held1098-fg-active-\(remaining.rawValue)", walkDone: remaining == .bodies) { account, _ in
            await Self.withPower(Self.openPower) {
                await DownloadGateHarness.withNetwork(expensive: true) {
                    if remaining == .bodies { await Self.queueBody(account.id, expectHeld: true) }
                    let item = ActiveBodyQueue.Item(
                        headerId: "\(account.id):INBOX:9", accountId: account.id,
                        folderPath: "INBOX", messageId: "9", isInInbox: true)
                    #expect(await ActiveBodyQueue.shared.admit(item), "precondition: the new-mail body was admitted")
                    let decision = await Self.decide([account])
                    #expect(decision.holdAwake, "new-mail bodies are never gated: the screen stays awake")
                    #expect(!decision.waitingForWiFi, "not everything left is held: no Waiting for Wi-Fi")
                }
            }
        }
    }

    @Test("foreground: nothing left releases the lock without the Waiting for Wi-Fi caption")
    func nothingLeftShowsNoCaption() async throws {
        try await Self.withAccount("held1098-fg-done", walkDone: true) { account, _ in
            await Self.withPower(DownloadGateHarness.power(.lowPowerMode)) {
                await DownloadGateHarness.withNetwork(expensive: true) {
                    let decision = await Self.decide([account])
                    #expect(!decision.holdAwake)
                    #expect(!decision.waitingForWiFi, "nothing is held when nothing is left")
                }
            }
        }
    }

    // MARK: - BGProcessing job

    @Test("job: Wi-Fi-only on the job's measured cellular releases the lock with only held work left; a job on Wi-Fi keeps it",
          arguments: Remaining.allCases)
    func jobHeldThenMoving(_ remaining: Remaining) async throws {
        try await Self.withAccount("held1098-job-\(remaining.rawValue)", walkDone: remaining == .bodies) { account, provider in
            // The job lifts the power gates (it sets fast sync and runs on power);
            // NetworkMonitor says unmetered, the job's own measurement decides.
            let jobPower = (fastSync: true, lowPowerMode: false, onPower: true, batteryLevel: Float(1))
            await Self.withPower(jobPower) {
                await DownloadGateHarness.withNetwork(expensive: false) {
                    let onCellular = await Self.decideInJob(onWiFi: false) {
                        if remaining == .bodies { await Self.queueBody(account.id, expectHeld: true) }
                        return await Self.decide([account])
                    }
                    #expect(onCellular?.holdAwake == false, "job on cellular, only held \(remaining) left: the screen may lock")
                    #expect(onCellular?.waitingForWiFi == true, "job on cellular: the caption reads Waiting for Wi-Fi")

                    await BackfillBodyQueue.shared.emptyForTesting()
                    // The Wi-Fi body's fetch is latched, so the decision is taken
                    // while the body is genuinely downloading.
                    let fetch = HeldWorkLatch()
                    await provider.setFetchMessageHook { await fetch.wait() }
                    let onWiFi = await Self.decideInJob(onWiFi: true) {
                        if remaining == .bodies {
                            await Self.queueBody(account.id, expectHeld: false)
                            #expect(await Self.pollUntil { await Self.fetchStarted(provider) },
                                    "precondition: the job on Wi-Fi did not start the body fetch")
                        }
                        return await Self.decide([account])
                    }
                    await fetch.open()
                    #expect(onWiFi?.holdAwake == true, "job on Wi-Fi: the \(remaining) can move, the screen stays awake")
                    #expect(onWiFi?.waitingForWiFi == false, "job on Wi-Fi: nothing is held")
                }
            }
        }
    }

    // MARK: - Work beside held work

    private static func fetchStarted(_ provider: MockEmailProvider) async -> Bool {
        await provider.callLog.contains { $0.hasPrefix("fetchMessage(") }
    }

    /// Registers `account` on `engine` with a one-slot provider queue whose slot
    /// is taken, so a catch-up run's slice parks on it. Returns the queue and
    /// what frees the slot.
    private static func occupiedSlot(
        _ account: Account, provider: MockEmailProvider, engine: SyncEngine
    ) async -> (queue: ProviderWorkQueue, free: @Sendable () async -> Void) {
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 1)
        await engine.register(accountId: account.id, provider: provider, workQueue: queue)
        let entered = HeldWorkLatch()
        let slot = HeldWorkLatch()
        let occupier = Task { await queue.execute(priority: .headerFetch) { await entered.open(); await slot.wait() } }
        await entered.wait()
        return (queue, { await slot.open(); await occupier.value })
    }

    /// Work beside held work, each read from its own owner.
    enum Beside: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// A catch-up run (`SyncEngine.runCatchUpRun`) parked on its provider slot.
        case catchUp
        /// A header walk (`SyncEngine.runBackfillWalk`) parked after it started.
        case headerWalk
        var testDescription: String { rawValue }
    }

    /// Latches `kind` running on `engine` and returns what finishes it.
    private static func latch(
        _ kind: Beside, account: Account, provider: MockEmailProvider, engine: SyncEngine
    ) async -> @Sendable () async -> Void {
        switch kind {
        case .catchUp:
            let (queue, free) = await occupiedSlot(account, provider: provider, engine: engine)
            let run = Task { await engine.runCatchUpRun(account: account, run: .snapshot(deadline: nil)) }
            #expect(await pollUntil { await queue.waitingCount == 1 }, "precondition: the catch-up run waits on its provider slot")
            return {
                await free()
                _ = await run.value
            }
        case .headerWalk:
            let entered = HeldWorkLatch()
            let gate = HeldWorkLatch()
            SyncEngine.backfillWalkStartedHookForTesting.withLock { $0 = { await entered.open(); await gate.wait() } }
            let walk = Task { await engine.runBackfillWalk(account: account) }
            await entered.wait()
            return {
                await gate.open()
                _ = await walk.value
                SyncEngine.backfillWalkStartedHookForTesting.withLock { $0 = nil }
            }
        }
    }

    @Test("foreground: a running header walk beside held work keeps the screen awake with no caption; a running catch-up scan does not, the lock stays released and the caption shown; after either ends the lock is released and the caption shown",
          arguments: Beside.allCases, Remaining.allCases)
    func onlyARunningWalkHoldsBesideHeldWork(_ kind: Beside, _ remaining: Remaining) async throws {
        try await Self.withAccount("held1098-run-\(kind.rawValue)-\(remaining.rawValue)", walkDone: remaining == .bodies) { account, provider in
            await Self.withPower(Self.openPower) {
                await DownloadGateHarness.withNetwork(expensive: true) {
                    if remaining == .bodies { await Self.queueBody(account.id, expectHeld: true) }
                    let engine = SyncEngine()
                    let finish = await Self.latch(kind, account: account, provider: provider, engine: engine)
                    let running = await Self.decide([account], engine: engine)
                    if kind == .headerWalk {
                        #expect(running.holdAwake, "a header walk is progressing beside held \(remaining): the screen stays awake")
                        #expect(!running.waitingForWiFi, "a header walk is progressing: no Waiting for Wi-Fi")
                    } else {
                        #expect(!running.holdAwake, "a catch-up scan beside held \(remaining) never holds the screen awake")
                        #expect(running.waitingForWiFi, "a catch-up scan beside held \(remaining): the caption reads Waiting for Wi-Fi")
                    }

                    await finish()
                    #expect(await Self.pollUntil {
                        let after = await Self.decide([account], engine: engine)
                        return !after.holdAwake && after.waitingForWiFi
                    }, "\(kind) finished, only held \(remaining) left: the lock is released and the caption shows")
                }
            }
        }
    }

    @Test("foreground: a pending AI job beside held work leaves the lock released and the caption shown",
          arguments: Remaining.allCases)
    func aiJobBesideHeldWorkReleases(_ remaining: Remaining) async throws {
        try await Self.withAccount("held1098-ai-\(remaining.rawValue)", walkDone: remaining == .bodies) { account, _ in
            await Self.withPower(Self.openPower) {
                await DownloadGateHarness.withNetwork(expensive: true) {
                    if remaining == .bodies { await Self.queueBody(account.id, expectHeld: true) }
                    // Dispatch suppressed: the job stays queued, as one waiting out
                    // a retry backoff or an offline spell does.
                    await ActiveAIQueue.shared.setDispatchSuppressedForTesting(true)
                    await ActiveAIQueue.shared.enqueue(headerId: "\(account.id):INBOX:11", accountId: account.id, windowExempt: true)
                    #expect(!(await ActiveAIQueue.shared.isIdle), "precondition: the AI job is queued")
                    let decision = await Self.decide([account])
                    #expect(!decision.holdAwake, "an AI job never holds the screen awake beside held \(remaining)")
                    #expect(decision.waitingForWiFi, "an AI job beside held \(remaining): the caption reads Waiting for Wi-Fi")
                }
            }
        }
    }

    @Test("foreground: a held state stays steady across a full worker cycle that runs a catch-up: the lock stays released and the caption shown during and after it",
          arguments: Remaining.allCases)
    func heldStateSteadyAcrossWorkerCycle(_ remaining: Remaining) async throws {
        try await Self.withAccount("held1098-cycle-\(remaining.rawValue)", walkDone: remaining == .bodies) { account, provider in
            try await Self.withPower(Self.openPower) {
                try await DownloadGateHarness.withNetwork(expensive: true) {
                    if remaining == .bodies { await Self.queueBody(account.id, expectHeld: true) }
                    let engine = SyncEngine()
                    let (queue, free) = await Self.occupiedSlot(account, provider: provider, engine: engine)
                    try await DownloadGateHarness.withWorker(engine, account: account, power: Self.openPower) { sleeps in
                        let before = await Self.decide([account], engine: engine)
                        #expect(!before.holdAwake && before.waitingForWiFi, "before the cycle's catch-up: released, caption shown")

                        #expect(await Self.pollUntil { await queue.waitingCount == 1 },
                                "precondition: the cycle's catch-up waits on its provider slot")
                        let during = await Self.decide([account], engine: engine)
                        #expect(!during.holdAwake, "the cycle's catch-up runs: the lock stays released")
                        #expect(during.waitingForWiFi, "the cycle's catch-up runs: the caption stays")

                        await free()
                        // The cycle ends at the worker's wait (walk unfinished) or at
                        // its exit (walk done, the cycle did no work).
                        #expect(await Self.pollUntil {
                            let exited = await engine.headerBackfillTasks[account.id] == nil
                            return !sleeps.recorded.isEmpty || exited
                        }, "the worker's cycle never ended")
                        let after = await Self.decide([account], engine: engine)
                        #expect(!after.holdAwake, "the cycle ended: the lock stays released")
                        #expect(after.waitingForWiFi, "the cycle ended: the caption stays")
                    }
                }
            }
        }
    }

    /// Two runs of the same kind on one engine at once, as the job runs accounts concurrently.
    private static func latchTwo(
        _ kind: Beside, account: Account, provider: MockEmailProvider, engine: SyncEngine
    ) async -> [@Sendable () async -> Void] {
        switch kind {
        case .headerWalk:
            let gates = [HeldWorkLatch(), HeldWorkLatch()]
            let entered = [HeldWorkLatch(), HeldWorkLatch()]
            let order = HeldWorkCounter()
            SyncEngine.backfillWalkStartedHookForTesting.withLock {
                $0 = {
                    let index = order.next()
                    await entered[index].open()
                    await gates[index].wait()
                }
            }
            var finishers: [@Sendable () async -> Void] = []
            for index in 0..<2 {
                let walk = Task { await engine.runBackfillWalk(account: account) }
                await entered[index].wait()
                finishers.append {
                    await gates[index].open()
                    _ = await walk.value
                }
            }
            return finishers
        case .catchUp:
            // Each run's account has its own provider slot, taken by an occupier.
            var finishers: [@Sendable () async -> Void] = []
            for index in 0..<2 {
                var runAccount = account
                runAccount.id = "\(account.id)-run\(index)"
                let (queue, free) = await occupiedSlot(runAccount, provider: provider, engine: engine)
                let run = Task { await engine.runCatchUpRun(account: runAccount, run: .snapshot(deadline: nil)) }
                #expect(await pollUntil { await queue.waitingCount == 1 }, "precondition: catch-up run \(index) waits on its provider slot")
                finishers.append {
                    await free()
                    _ = await run.value
                }
            }
            return finishers
        }
    }

    @Test("foreground: two overlapping walks keep the screen awake until the second ends; two overlapping catch-up runs never do; once both end the lock is released and the caption shown",
          arguments: Beside.allCases, Remaining.allCases)
    func overlappingRunsOnlyWalksHold(_ kind: Beside, _ remaining: Remaining) async throws {
        try await Self.withAccount("held1098-overlap-\(kind.rawValue)-\(remaining.rawValue)", walkDone: remaining == .bodies) { account, provider in
            await Self.withPower(Self.openPower) {
                await DownloadGateHarness.withNetwork(expensive: true) {
                    if remaining == .bodies { await Self.queueBody(account.id, expectHeld: true) }
                    let engine = SyncEngine()
                    let finishers = await Self.latchTwo(kind, account: account, provider: provider, engine: engine)
                    guard finishers.count == 2 else { return }
                    let holds = kind == .headerWalk

                    let both = await Self.decide([account], engine: engine)
                    #expect(both.holdAwake == holds, "two \(kind) runs: the screen stays awake only for walks")
                    #expect(both.waitingForWiFi == !holds)

                    await finishers[0]()
                    let one = await Self.decide([account], engine: engine)
                    #expect(one.holdAwake == holds, "one \(kind) run left: the screen stays awake only for a walk")
                    #expect(one.waitingForWiFi == !holds)

                    await finishers[1]()
                    SyncEngine.backfillWalkStartedHookForTesting.withLock { $0 = nil }
                    #expect(await Self.pollUntil {
                        let after = await Self.decide([account], engine: engine)
                        return !after.holdAwake && after.waitingForWiFi
                    }, "both \(kind) runs ended, only held \(remaining) left: the lock is released and the caption shows")
                }
            }
        }
    }

    @Test("foreground: a header walk admitted before the gate closed keeps the screen awake until it ends")
    func admittedWalkHoldsAfterGateCloses() async throws {
        try await Self.withAccount("held1098-fg-admitted-walk", walkDone: false) { account, _ in
            await Self.withPower(Self.openPower) {
                await DownloadGateHarness.withNetwork(expensive: false) {
                    let engine = SyncEngine()
                    let entered = HeldWorkLatch()
                    let gate = HeldWorkLatch()
                    SyncEngine.backfillWalkStartedHookForTesting.withLock { $0 = { await entered.open(); await gate.wait() } }
                    // The cycle's walk decision is taken with the gate open.
                    let cycle = Task { await engine.runBackfillCycle(account: account, walkAllowed: true) }
                    await entered.wait()
                    NetworkMonitor.setExpensiveForTesting(true)

                    let during = await Self.decide([account], engine: engine)
                    #expect(during.holdAwake, "the admitted walk is still running: the screen stays awake")
                    #expect(!during.waitingForWiFi, "the admitted walk is still running: no Waiting for Wi-Fi")

                    await gate.open()
                    _ = await cycle.value
                    SyncEngine.backfillWalkStartedHookForTesting.withLock { $0 = nil }
                    let after = await Self.decide([account], engine: engine)
                    #expect(!after.holdAwake, "the walk ended and the rest is held: the screen may lock")
                    #expect(after.waitingForWiFi)
                }
            }
        }
    }

    @Test("job: a header walk admitted before Low Power Mode closed the gate keeps the screen awake until it ends")
    func jobAdmittedWalkHoldsAfterGateCloses() async throws {
        try await Self.withAccount("held1098-job-admitted-walk", walkDone: false) { account, _ in
            let jobPower = (fastSync: true, lowPowerMode: false, onPower: true, batteryLevel: Float(1))
            await Self.withPower(jobPower) {
                await DownloadGateHarness.withNetwork(expensive: false) {
                    let engine = SyncEngine()
                    let after = DecisionBox()
                    let during = await Self.decideInJob(onWiFi: true) {
                        let entered = HeldWorkLatch()
                        let gate = HeldWorkLatch()
                        SyncEngine.backfillWalkStartedHookForTesting.withLock { $0 = { await entered.open(); await gate.wait() } }
                        let backfill = Task { await engine.performBackfill(account: account, walkAllowed: true) }
                        await entered.wait()
                        SyncEngine.backfillPowerStateForTesting.withLock {
                            $0 = (fastSync: true, lowPowerMode: true, onPower: true, batteryLevel: Float(1))
                        }
                        let decision = await Self.decide([account], engine: engine)
                        await gate.open()
                        _ = await backfill.value
                        SyncEngine.backfillWalkStartedHookForTesting.withLock { $0 = nil }
                        let ended = await Self.decide([account], engine: engine)
                        after.value.withLock { $0 = ended }
                        return decision
                    }
                    #expect(during?.holdAwake == true, "the job's admitted walk is still running: the screen stays awake")
                    #expect(during?.waitingForWiFi == false)
                    let ended = after.value.withLock { $0 }
                    #expect(ended?.holdAwake == false, "the job's walk ended and the rest is held: the screen may lock")
                    #expect(ended?.waitingForWiFi == true)
                }
            }
        }
    }

    @Test("foreground: an older-mail body batch still downloading beside a refused pending body keeps the screen awake; once it ends the lock releases")
    func activeOlderBodyBatchBesideRefusedItemHolds() async throws {
        try await Self.withAccount("held1098-fg-active-batch", walkDone: true) { account, provider in
            await Self.withPower(Self.openPower) {
                await DownloadGateHarness.withNetwork(expensive: false) {
                    let fetch = HeldWorkLatch()
                    await provider.setFetchMessageHook { await fetch.wait() }
                    await Self.queueBody(account.id, expectHeld: false)
                    #expect(await Self.pollUntil { await Self.fetchStarted(provider) }, "precondition: the first body is downloading")

                    // The gate closes; a second body's dispatch is refused while
                    // the first batch is still running.
                    NetworkMonitor.setExpensiveForTesting(true)
                    await BackfillBodyQueue.shared.enqueue([BackfillBodyQueue.Item(
                        headerId: "\(account.id):Sent:8", accountId: account.id,
                        folderPath: "Sent", messageId: "8", isInInbox: false)])
                    #expect(await Self.pollUntil { await BackfillBodyQueue.shared.heldByDownloadGate },
                            "precondition: the second body was refused by the gate")

                    let during = await Self.decide([account])
                    #expect(during.holdAwake, "a body batch is downloading: the screen stays awake")
                    #expect(!during.waitingForWiFi, "a body batch is downloading: no Waiting for Wi-Fi")

                    await fetch.open()
                    #expect(await Self.pollUntil {
                        let after = await Self.decide([account])
                        return !after.holdAwake && after.waitingForWiFi
                    }, "the batch ended, only the refused body is left: the lock releases and the caption shows")
                }
            }
        }
    }

    @Test("a Wi-Fi-only change while a poll is suspended: both decisions keep the poll's starting value; the next poll uses the new one")
    func wifiOnlyChangeMidPollKeepsSnapshot() async throws {
        try await Self.withAccount("held1098-snapshot", walkDone: false) { account, _ in
            await Self.withPower(Self.openPower) {
                await DownloadGateHarness.withNetwork(expensive: true, wifiOnly: true) {
                    let flipped = HeldWorkFlag()
                    SyncEngine.backfillPowerReadHookForTesting.withLock {
                        $0 = {
                            guard !flipped.set() else { return }
                            UserDefaults.standard.set(false, forKey: SyncScheduler.wifiOnlyKey)
                        }
                    }
                    let during = await Self.decide([account])
                    SyncEngine.backfillPowerReadHookForTesting.withLock { $0 = nil }
                    #expect(flipped.isSet, "precondition: Wi-Fi-only changed while the poll was suspended")
                    #expect(!during.holdAwake, "the poll started with Wi-Fi-only on cellular: the walk is held")
                    #expect(during.waitingForWiFi, "the caption follows the same snapshot as the lock")

                    let next = await Self.decide([account])
                    #expect(next.holdAwake, "the next poll sees Wi-Fi-only off: the walk can move")
                    #expect(!next.waitingForWiFi)
                }
            }
        }
    }

    // MARK: - Presentation (T2)

    private static func progress(_ id: String, phase: FastSyncView.ProgressPhase) -> [String: BackfillProgress] {
        var p = BackfillProgress(
            accountId: id, email: "user@example.com", startedAt: Date(), isPaused: false,
            headersDone: phase == .indexing, totalEmails: 100, ftsIndexed: 10)
        if phase == .walk {
            p.uidTotal = 100
            p.uidWalked = 10
        }
        p.pendingBodyCount = 90
        p.emaRate = 1
        return [id: p]
    }

    /// Everything left is held (`held`) or the same work can move.
    private static func poll(_ id: String, phase: FastSyncView.ProgressPhase, held: Bool) -> FastSyncView.KeepAwakePoll {
        FastSyncView.KeepAwakePoll(
            activeBodyIdle: true,
            backfillBodyIdle: phase == .walk,
            backfillBodyHeld: phase == .indexing && held,
            downloadsHeld: held,
            walkRunning: false,
            walkDoneByAccount: [id: phase == .indexing])
    }

    @Test("presentation: while held, exactly one Waiting for Wi-Fi replaces the estimate, the lock is released and nothing completes; when runnable the estimate returns",
          arguments: [FastSyncView.ProgressPhase.walk, .indexing])
    func presentationFollowsHeldWork(_ phase: FastSyncView.ProgressPhase) async throws {
        try await Self.withAccount("held1098-ui-\(phase)", walkDone: phase == .indexing) { account, _ in
            let progress = Self.progress(account.id, phase: phase)
            let estimate = "~\(FastSyncView.formatETA(90)) remaining"

            let held = FastSyncView.presentation(accounts: [account], progress: progress, poll: Self.poll(account.id, phase: phase, held: true))
            #expect(held.phase == phase)
            #expect(held.statusLine == "Waiting for Wi-Fi", "held: the line reads Waiting for Wi-Fi")
            #expect(held.statusLine != estimate, "held: the estimate is not shown beside it")
            #expect(!held.syncComplete, "held work never shows Sync Complete")
            #expect(!held.holdAwake)

            let moving = FastSyncView.presentation(accounts: [account], progress: progress, poll: Self.poll(account.id, phase: phase, held: false))
            #expect(moving.phase == phase)
            #expect(moving.statusLine == estimate, "runnable: the estimate is back")
            #expect(!moving.syncComplete)
            #expect(moving.holdAwake)

            // The keep-awake effect, through the screen's own modifier.
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: KeepAwakeProbe(active: moving.holdAwake))
            window.rootViewController = host
            window.isHidden = false
            #expect(await Self.pollUntil { UIApplication.shared.isIdleTimerDisabled }, "runnable: the idle timer is off")
            host.rootView = KeepAwakeProbe(active: held.holdAwake)
            #expect(await Self.pollUntil { !UIApplication.shared.isIdleTimerDisabled }, "held: the idle timer is back on")
            window.isHidden = true
        }
    }

    @Test("presentation: Done closes the sheet and stops Fast Sync while work is held")
    func doneClosesWhileHeld() async {
        let dismissed = HeldWorkFlag()
        let stopped = HeldWorkLatch()
        FastSyncView.close(stopFastSync: { await stopped.open() }, dismiss: { _ = dismissed.set() })
        #expect(dismissed.isSet, "Done dismisses the sheet")
        await stopped.wait()
    }

    @Test("presentation: Done and Stop Fast Sync both close the sheet through close, the only dismissal path")
    func doneAndStopGoThroughClose() throws {
        let source = try UserLabelProviderBoundaryFenceTests.code(of:
            UserLabelProviderBoundaryFenceTests.load("TabMail/Views/Settings/FastSyncView.swift"))
        for anchor in ["Button(\"Done\")", "Button(role: .destructive)"] {
            guard let start = source.range(of: anchor) else {
                Issue.record("\(anchor) not found in FastSyncView")
                continue
            }
            let action = source[start.upperBound...].prefix(200)
            #expect(action.contains("Self.close("), "\(anchor) does not close through FastSyncView.close")
        }
        let dismissCalls = source.components(separatedBy: "dismiss()").count - 1
        let throughClose = source.components(separatedBy: "dismiss: { dismiss() }").count - 1
        // close's own body calls its parameter once; every other call is a handed-in closure.
        #expect(throughClose == 2, "Done and Stop each hand dismiss to close")
        #expect(dismissCalls == throughClose + 1, "a dismiss() outside close closes the sheet another way")
    }

    /// Runs `body` inside a real BGProcessing job whose Wi-Fi measurement is `onWiFi`.
    private static func decideInJob(onWiFi: Bool, _ body: @escaping @Sendable () async -> Decision) async -> Decision? {
        let savedMeasurement = SyncScheduler.jobOnWiFiMeasurementForTesting.withLock { $0 }
        SyncScheduler.jobOnWiFiMeasurementForTesting.withLock { $0 = onWiFi }
        defer { SyncScheduler.jobOnWiFiMeasurementForTesting.withLock { $0 = savedMeasurement } }
        let result = Mutex<Decision?>(nil)
        let context = BGTaskContext(label: "held1098-job-\(onWiFi)", completion: { _ in })
        let scheduler = SyncScheduler(
            backgroundReadiness: { true },
            backgroundWork: { _ in
                let decision = await body()
                result.withLock { $0 = decision }
            },
            processingHasWork: { false },
            backgroundSchedule: { _ in },
            refreshNetworkAvailable: true
        )
        scheduler.handleBackgroundAIProcessing(context: context) { _ in }
        await context.waitForTaskForTesting()
        return result.withLock { $0 }
    }
}

private extension AccountManager {
    func installHeldWorkTestProvider(accountId: String, provider: any EmailProvider, queue: ProviderWorkQueue) {
        providers[accountId] = provider
        workQueues[accountId] = queue
    }

    func removeHeldWorkTestProvider(accountId: String) {
        providers.removeValue(forKey: accountId)
        workQueues.removeValue(forKey: accountId)
    }
}

/// A one-shot gate a test opens to let parked work continue.
private actor HeldWorkLatch {
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

/// A flag set once from any context.
private final class HeldWorkFlag: Sendable {
    private let value = Mutex(false)
    /// Sets the flag; returns whether it was already set.
    func set() -> Bool { value.withLock { let was = $0; $0 = true; return was } }
    var isSet: Bool { value.withLock { $0 } }
}

/// Hands out 0, 1, 2, ... from any context.
private final class HeldWorkCounter: Sendable {
    private let value = Mutex(0)
    func next() -> Int { value.withLock { let current = $0; $0 += 1; return current } }
}

private final class DecisionBox: Sendable {
    let value = Mutex<FastSyncHeldWorkTests.Decision?>(nil)
}

/// Hosts the screen's keep-awake modifier alone.
private struct KeepAwakeProbe: View {
    let active: Bool
    var body: some View { Color.clear.keepScreenAwake(while: active) }
}
