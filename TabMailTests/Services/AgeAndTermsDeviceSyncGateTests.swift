/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Age and terms screen (owner 2026-10-08). INVARIANT: Device Sync does not
/// start a connection for an account that has not passed the age and terms
/// screen — the device-sync worker refuses it (`consent_required`). With the
/// screen passed the same call starts connecting, so the refusal is not vacuous.
@Suite("Device Sync waits for the age and terms screen", .serialized, .processGlobalState)
@MainActor
struct AgeAndTermsDeviceSyncGateTests {
    @Test func connectStartsOnlyAfterTheScreenIsPassed() {
        let standard = UserDefaults.standard
        let keys = [AgeAndTermsConsent.completedKey, "device_sync_auto_enabled"]
        let previous = keys.map { standard.object(forKey: $0) }
        let previousDemo = DemoModeStore.shared.isActive
        let sync = DeviceSyncService.shared
        defer {
            sync.disconnect()
            DemoModeStore.shared.isActive = previousDemo
            for (key, value) in zip(keys, previous) {
                if let value { standard.set(value, forKey: key) } else { standard.removeObject(forKey: key) }
            }
        }
        DemoModeStore.shared.isActive = false
        standard.set(true, forKey: "device_sync_auto_enabled")
        sync.disconnect()

        standard.set(false, forKey: AgeAndTermsConsent.completedKey)
        sync.connect()
        #expect(!sync.isConnecting, "no connection before the age and terms screen")
        sync.reconnectIfNeeded()
        #expect(!sync.isConnecting, "the foreground reconnect is refused too")

        standard.set(true, forKey: AgeAndTermsConsent.completedKey)
        sync.connect()
        #expect(sync.isConnecting, "control: with the screen passed the same call starts connecting")
    }
}
