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

    @Test("Sync disabled kill switch is off")
    @MainActor
    func syncDisabledOff() {
        // syncDisabled is a TEMP kill switch that should be false in production
        #expect(SyncScheduler.syncDisabled == false)
    }
}
