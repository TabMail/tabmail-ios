/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
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
    /// Runs `body` with NetworkMonitor's cached expensive flag and the Wi-Fi-only
    /// setting set, restoring both, so a test never depends on the network of the
    /// machine it runs on.
    static func withNetwork(
        expensive: Bool, wifiOnly: Bool = true, _ body: () async throws -> Void
    ) async rethrows {
        let key = SyncScheduler.wifiOnlyKey
        let savedSetting = UserDefaults.standard.object(forKey: key)
        let savedExpensive = NetworkMonitor.checkExpensive()
        UserDefaults.standard.set(wifiOnly, forKey: key)
        NetworkMonitor.setExpensiveForTesting(expensive)
        defer {
            UserDefaults.standard.set(savedSetting, forKey: key)
            NetworkMonitor.setExpensiveForTesting(savedExpensive)
        }
        try await body()
    }

    /// One backfill call by `runner` under `gate`, with the walk decided exactly as
    /// that runner decides it from the gate's snapshot: the worker one cycle
    /// (`SyncEngine.backfillWalkAllowed`, then `runBackfillCycle`), the job its
    /// production entry (`SyncScheduler.backgroundBackfillPlan`, then
    /// `performBackfill` with the job's deadline). Returns the walk decision, or nil
    /// when the runner ran nothing at all (the scan waited too).
    static func runOnce(_ engine: SyncEngine, account: Account, gate: DownloadGate, runner: BackfillRunner) async -> Bool? {
        let expensive = gate == .expensiveNetwork
        let decision: Bool?
        switch runner {
        case .worker:
            decision = SyncEngine.backfillWalkAllowed(
                fastSync: false, lowPowerMode: gate == .lowPowerMode, onPower: false,
                batteryLevel: gate == .lowBattery ? 0.15 : 0.8, wifiOnly: true, expensive: expensive)
        case .job:
            decision = SyncScheduler.backgroundBackfillPlan(
                isLowPowerMode: gate == .lowPowerMode, wifiOnly: true, onWiFi: !expensive)
        }
        guard let walkAllowed = decision else { return nil }
        await withNetwork(expensive: expensive) {
            switch runner {
            case .worker:
                _ = await engine.runBackfillCycle(account: account, walkAllowed: walkAllowed)
            case .job:
                let deadline = Date().addingTimeInterval(SyncConfig.backgroundBackfillDeadlineSeconds)
                _ = await engine.performBackfill(account: account, deadline: deadline, walkAllowed: walkAllowed)
            }
        }
        return walkAllowed
    }

    /// Whether `runner` lets the walk run under `gate`: never, except the job under
    /// a low battery, because the job has no battery gate.
    static func walkExpected(_ gate: DownloadGate, _ runner: BackfillRunner) -> Bool {
        runner == .job && gate == .lowBattery
    }
}
