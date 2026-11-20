/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// #1098: Fast Sync's screen lock counts only work that can make progress now.
/// When everything left is held by the download gates (the older-mail walk gate,
/// #1063, and BackfillBodyQueue's gate, #1064), the lock releases and the
/// "~X remaining" line reads "Waiting for Wi-Fi"; the moment anything can move,
/// the lock is held again and the caption goes. Driven through the screen's own
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
        _ id: String, walkDone: Bool, _ body: (Account) async throws -> Void
    ) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let provider = MockEmailProvider()
        await ActiveBodyQueue.shared.emptyForTesting()
        await BackfillBodyQueue.shared.emptyForTesting()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let account = try FolderEpochTestFixture.makeAccount(id: id, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: id, path: "INBOX", role: .inbox, pool: pool)
        try FastSyncWakeLockTests.setWalkComplete(walkDone, accountId: id, path: "INBOX", pool: pool)
        await AccountManager.shared.installHeldWorkTestProvider(
            accountId: id, provider: provider, queue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
        NetworkMonitor.setConnectedForTesting(true)
        do {
            try await body(account)
        } catch {
            await Self.cleanUp(id)
            throw error
        }
        await Self.cleanUp(id)
    }

    private static func cleanUp(_ id: String) async {
        await ActiveBodyQueue.shared.emptyForTesting()
        await BackfillBodyQueue.shared.emptyForTesting()
        await AccountManager.shared.removeHeldWorkTestProvider(accountId: id)
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
    private static func decide(_ accounts: [Account]) async -> Decision {
        let poll = await FastSyncView.pollKeepAwakeInputs(accounts: accounts, engine: SyncEngine())
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
        SyncEngine.backfillPowerStateForTesting.withLock { $0 = power }
        defer { SyncEngine.backfillPowerStateForTesting.withLock { $0 = nil } }
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
        try await Self.withAccount("held1098-fg-\(gate.rawValue)-\(remaining.rawValue)", walkDone: remaining == .bodies) { account in
            try await Self.withPower(DownloadGateHarness.power(gate)) {
                try await DownloadGateHarness.withNetwork(expensive: gate == .expensiveNetwork) {
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
        try await Self.withAccount("held1098-fg-walk-moving", walkDone: false) { account in
            try await Self.withPower(Self.openPower) {
                try await DownloadGateHarness.withNetwork(expensive: false) {
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
        try await Self.withAccount("held1098-fg-active-\(remaining.rawValue)", walkDone: remaining == .bodies) { account in
            try await Self.withPower(Self.openPower) {
                try await DownloadGateHarness.withNetwork(expensive: true) {
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
        try await Self.withAccount("held1098-fg-done", walkDone: true) { account in
            try await Self.withPower(DownloadGateHarness.power(.lowPowerMode)) {
                try await DownloadGateHarness.withNetwork(expensive: true) {
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
        try await Self.withAccount("held1098-job-\(remaining.rawValue)", walkDone: remaining == .bodies) { account in
            // The job lifts the power gates (it sets fast sync and runs on power);
            // NetworkMonitor says unmetered, the job's own measurement decides.
            let jobPower = (fastSync: true, lowPowerMode: false, onPower: true, batteryLevel: Float(1))
            try await Self.withPower(jobPower) {
                try await DownloadGateHarness.withNetwork(expensive: false) {
                    let onCellular = await Self.decideInJob(onWiFi: false) {
                        if remaining == .bodies { await Self.queueBody(account.id, expectHeld: true) }
                        return await Self.decide([account])
                    }
                    #expect(onCellular?.holdAwake == false, "job on cellular, only held \(remaining) left: the screen may lock")
                    #expect(onCellular?.waitingForWiFi == true, "job on cellular: the caption reads Waiting for Wi-Fi")

                    await BackfillBodyQueue.shared.emptyForTesting()
                    let onWiFi = await Self.decideInJob(onWiFi: true) {
                        if remaining == .bodies {
                            await Self.queueBody(account.id, expectHeld: false)
                            // Decide before the body finishes downloading.
                            return await Self.decide([account])
                        }
                        return await Self.decide([account])
                    }
                    if remaining == .walk {
                        #expect(onWiFi?.holdAwake == true, "job on Wi-Fi: the walk can move, the screen stays awake")
                    }
                    #expect(onWiFi?.waitingForWiFi == false, "job on Wi-Fi: nothing is held")
                }
            }
        }
    }

    /// Runs `body` inside a real BGProcessing job whose Wi-Fi measurement is `onWiFi`.
    private static func decideInJob(onWiFi: Bool, _ body: @escaping @Sendable () async -> Decision) async -> Decision? {
        SyncScheduler.jobOnWiFiMeasurementForTesting.withLock { $0 = onWiFi }
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
