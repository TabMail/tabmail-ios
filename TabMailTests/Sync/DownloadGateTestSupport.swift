/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// The download gates a folder scan never waits for (#1063): an expensive network
/// with the Wi-Fi-only setting on, a battery below 20% off power, and Low Power
/// Mode off power. Each holds back the older-mail walk (a download) only.
enum DownloadGate: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case expensiveNetwork, lowBattery, lowPowerMode
    var testDescription: String { rawValue }
}

/// The two callers of the backfill: the foreground worker's cycle and the
/// background processing job.
enum BackfillRunner: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case worker, job
    var testDescription: String { rawValue }
}

enum DownloadGateHarness {
    /// Satisfied paths as iOS reports them (the facts carry no interface: the
    /// Wi-Fi-only rule asks only whether the network is metered): unmetered
    /// Wi-Fi, wired Ethernet, cellular, and a Personal Hotspot (Wi-Fi that iOS
    /// marks expensive).
    static let unmeteredWiFi = NetworkPathFacts(satisfied: true, isExpensive: false)
    static let wired = NetworkPathFacts(satisfied: true, isExpensive: false)
    static let cellular = NetworkPathFacts(satisfied: true, isExpensive: true)
    static let personalHotspot = NetworkPathFacts(satisfied: true, isExpensive: true)

    /// `withPath` on cellular when `expensive`, else unmetered Wi-Fi.
    nonisolated(nonsending) static func withNetwork(
        expensive: Bool, wifiOnly: Bool = true, _ body: () async throws -> Void
    ) async rethrows {
        try await withPath(expensive ? cellular : unmeteredWiFi, wifiOnly: wifiOnly, body)
    }

    /// Runs `body` with one network path seen by both readers, NetworkMonitor's
    /// cached path (the foreground gate) and the background job's measurement
    /// (classified by the production rule, `SyncEngine.onUnmeteredNetwork`), and the
    /// Wi-Fi-only setting set, restoring all of them, so a test never depends on
    /// the network of the machine it runs on.
    nonisolated(nonsending) static func withPath(
        _ facts: NetworkPathFacts, wifiOnly: Bool = true, _ body: () async throws -> Void
    ) async rethrows {
        let key = SyncScheduler.wifiOnlyKey
        let savedSetting = UserDefaults.standard.object(forKey: key)
        let savedFacts = NetworkMonitor.checkPathFactsIfKnown()
        let savedJobFacts = SyncScheduler.jobPathFactsForTesting.withLock { $0 }
        UserDefaults.standard.set(wifiOnly, forKey: key)
        NetworkMonitor.setPathFactsForTesting(facts)
        SyncScheduler.jobPathFactsForTesting.withLock { $0 = facts }
        defer {
            UserDefaults.standard.set(savedSetting, forKey: key)
            NetworkMonitor.setPathFactsForTesting(savedFacts)
            SyncScheduler.jobPathFactsForTesting.withLock { $0 = savedJobFacts }
        }
        try await body()
    }

    /// The worker's power snapshot under `gate`: off power, battery 80% unless the
    /// gate is a low battery (15%), Low Power Mode only under its gate.
    static func power(_ gate: DownloadGate) -> (fastSync: Bool, lowPowerMode: Bool, onPower: Bool, batteryLevel: Float) {
        (fastSync: false, lowPowerMode: gate == .lowPowerMode, onPower: false, batteryLevel: gate == .lowBattery ? 0.15 : 0.8)
    }

    /// One backfill by `runner` under `gate`, through the production entry: the
    /// worker's loop (`SyncEngine.startBackfill`, its first cycle, stopped at its
    /// first wait) or the job's backfill stage (`SyncScheduler.runBackgroundBackfill`
    /// with the job's deadline). The engine must have the account's provider
    /// registered.
    static func runOnce(_ engine: SyncEngine, account: Account, gate: DownloadGate, runner: BackfillRunner) async throws {
        let expensive = gate == .expensiveNetwork
        try await withNetwork(expensive: expensive) { () async throws in
            switch runner {
            case .worker:
                try await withWorker(engine, account: account, power: power(gate)) { sleeps async throws in
                    #expect(await sleeps.waitFor(count: 1), "the worker's first cycle never ended")
                }
            case .job:
                // The job's reading, from the production measurement of the path.
                let onWiFi = await SyncScheduler.measureJobOnWiFi()
                await SyncScheduler.runBackgroundBackfill(
                    accounts: [account], isLowPowerMode: gate == .lowPowerMode, wifiOnly: true, onWiFi: onWiFi,
                    budget: SyncConfig.backgroundBackfillDeadlineSeconds,
                    awaitOnWiFi: { onWiFi }
                ) { account, walkAllowed, deadline in
                    _ = await engine.performBackfill(account: account, deadline: deadline, walkAllowed: walkAllowed)
                }
            }
        }
    }

    /// Runs the real backfill worker for `account` with `power` as its power
    /// snapshot and its waits between cycles handed to a `WorkerSleeps`, then
    /// stops it (the account is removed from the engine).
    nonisolated(nonsending) static func withWorker(
        _ engine: SyncEngine, account: Account,
        power: (fastSync: Bool, lowPowerMode: Bool, onPower: Bool, batteryLevel: Float),
        _ body: (WorkerSleeps) async throws -> Void
    ) async throws {
        let sleeps = WorkerSleeps()
        SyncEngine.backfillPowerStateForTesting.withLock { $0 = power }
        SyncEngine.backfillSleepForTesting.withLock { $0 = { await sleeps.sleep($0) } }
        defer {
            SyncEngine.backfillPowerStateForTesting.withLock { $0 = nil }
            SyncEngine.backfillSleepForTesting.withLock { $0 = nil }
        }
        await engine.startBackfill(account: account)
        do {
            try await body(sleeps)
        } catch {
            await engine.remove(accountId: account.id)
            throw error
        }
        await engine.remove(accountId: account.id)
    }

    /// Whether `runner` lets the walk run under `gate`: never, except the job under
    /// a low battery, because the job has no battery gate.
    static func walkExpected(_ gate: DownloadGate, _ runner: BackfillRunner) -> Bool {
        runner == .job && gate == .lowBattery
    }
}

/// The backfill worker's waits between cycles, under a test's control: each wait
/// records its length and lasts until the test releases it (or the worker is
/// cancelled), so no test waits out a real pause and no cycle starts early.
final class WorkerSleeps: Sendable {
    private let lengths = Mutex<[TimeInterval]>([])
    private let released = Mutex(0)

    /// The lengths of the waits so far, in order.
    var recorded: [TimeInterval] { lengths.withLock { $0 } }

    func sleep(_ seconds: TimeInterval) async {
        let index = lengths.withLock { $0.append(seconds); return $0.count - 1 }
        while !Task.isCancelled, released.withLock({ $0 }) <= index {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Ends the waits recorded so far.
    func release() { released.withLock { $0 = lengths.withLock { $0.count } } }

    /// True once `count` waits have begun, within `seconds`.
    func waitFor(count: Int, seconds: Double = 30) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if recorded.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return recorded.count >= count
    }
}
