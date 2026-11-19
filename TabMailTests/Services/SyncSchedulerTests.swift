/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SyncScheduler Constants")
struct SyncSchedulerConstantsTests {

    @Test("Background task identifier matches expected value")
    @MainActor
    func backgroundTaskIdentifier() {
        #expect(SyncScheduler.backgroundTaskIdentifier == "ai.tabmail.sync")
    }

    @Test("Background AI task identifier matches expected value")
    @MainActor
    func backgroundAITaskIdentifier() {
        #expect(SyncScheduler.backgroundAITaskIdentifier == "ai.tabmail.ai-processing")
    }

    @Test("WiFi only key is stable")
    @MainActor
    func wifiOnlyKey() {
        #expect(SyncScheduler.wifiOnlyKey == "backgroundSyncWiFiOnly")
    }

    /// The foreground worker's walk decision from one power and network snapshot
    /// (#1063): Low Power Mode off power, a battery below 20% off power, and the
    /// Wi-Fi-only setting on an expensive network each hold the walk; fast sync
    /// lifts the power gates; everything else lets it run. The scan runs in every
    /// row (the per-provider `scanRunsUnderEveryDownloadGate` cases).
    @Test("The worker's walk decision: every gate holds the walk only")
    func backfillWalkAllowedTruthTable() {
        func walk(fast: Bool = false, lpm: Bool = false, power: Bool = false, level: Float = 0.8,
                  wifiOnly: Bool = false, expensive: Bool = false) -> Bool? {
            SyncEngine.backfillWalkAllowed(fastSync: fast, lowPowerMode: lpm, onPower: power, batteryLevel: level,
                                           wifiOnly: wifiOnly, expensive: expensive)
        }
        #expect(walk() == true)
        #expect(walk(lpm: true) == false, "Low Power Mode off power holds the walk")
        #expect(walk(level: 0.15) == false, "a battery below 20% off power holds the walk")
        #expect(walk(wifiOnly: true, expensive: true) == false, "Wi-Fi-only on an expensive network holds the walk")
        #expect(walk(lpm: true, power: true) == true, "Low Power Mode on power")
        #expect(walk(power: true, level: 0.15) == true, "a low battery on power")
        #expect(walk(level: -1) == true, "an unknown battery level")
        #expect(walk(wifiOnly: true) == true, "Wi-Fi-only on a non-expensive network")
        #expect(walk(expensive: true) == true, "an expensive network with Wi-Fi-only off")
        #expect(walk(fast: true, lpm: true, level: 0.15) == true, "fast sync lifts the power gates")
        #expect(walk(fast: true, wifiOnly: true, expensive: true) == false, "fast sync keeps the Wi-Fi-only rule")
    }

    /// The background job's walk decision (#1063): Low Power Mode and Wi-Fi-only
    /// off Wi-Fi hold the walk; the job runs the scan in every row.
    @Test("The job's walk decision: Low Power Mode and Wi-Fi-only off Wi-Fi hold the walk only")
    func backgroundBackfillPlanTruthTable() {
        typealias S = SyncScheduler
        #expect(S.backgroundBackfillPlan(isLowPowerMode: true, wifiOnly: true, onWiFi: false) == false)
        #expect(S.backgroundBackfillPlan(isLowPowerMode: true, wifiOnly: false, onWiFi: true) == false)
        #expect(S.backgroundBackfillPlan(isLowPowerMode: false, wifiOnly: true, onWiFi: false) == false)
        #expect(S.backgroundBackfillPlan(isLowPowerMode: false, wifiOnly: true, onWiFi: true) == true)
        #expect(S.backgroundBackfillPlan(isLowPowerMode: false, wifiOnly: false, onWiFi: false) == true)
    }

    /// The Wi-Fi-only setting: both read sites read the key the Settings toggle
    /// writes (`SyncScheduler.wifiOnlyKey`), and an unset key reads as on.
    @Test("Both Wi-Fi-only read sites read the toggle's key, and an unset key reads as on")
    func wifiOnlySettingGuard() throws {
        let files = try DiagnosticPrintGateTests.appTargetSources()
        func source(_ path: String) throws -> String {
            try #require(files.first { $0.relativePath == path }, "missing \(path)").source
        }
        let toggle = try source("TabMail/Views/Settings/SettingsView.swift")
        #expect(toggle.contains("@AppStorage(SyncScheduler.wifiOnlyKey)"), "the toggle writes the key")
        let read = "UserDefaults.standard.object(forKey: SyncScheduler.wifiOnlyKey) as? Bool ?? true"
        let jobRead = "UserDefaults.standard.object(forKey: Self.wifiOnlyKey) as? Bool ?? true"
        #expect(try source("TabMail/Services/Sync/SyncEngineBackfill.swift").contains(read),
                "the worker reads the toggle's key, unset = on")
        #expect(try source("TabMail/Services/SyncScheduler.swift").contains(jobRead),
                "the job reads the toggle's key, unset = on")
        for path in ["TabMail/Services/Sync/SyncEngineBackfill.swift", "TabMail/Services/SyncScheduler.swift"] {
            let literals = try source(path).components(separatedBy: "\"backgroundSyncWiFiOnly\"").count - 1
            #expect(literals <= (path.hasSuffix("SyncScheduler.swift") ? 1 : 0), "\(path) spells the key as a literal")
        }
    }

    @Test("Sync disabled kill switch is off")
    @MainActor
    func syncDisabledOff() {
        // syncDisabled is a TEMP kill switch that should be false in production
        #expect(SyncScheduler.syncDisabled == false)
    }
}
