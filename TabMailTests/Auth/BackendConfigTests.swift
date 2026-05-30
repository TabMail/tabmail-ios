/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("BackendConfig")
struct BackendConfigTests {

    @Test("apiBaseURL is valid HTTPS URL")
    func apiBaseURLValid() {
        #expect(BackendConfig.apiBaseURL.scheme == "https")
        #expect(BackendConfig.apiBaseURL.host?.contains("tabmail.ai") == true)
    }

    @Test("syncBaseURL is valid HTTPS string")
    func syncBaseURLValid() {
        #expect(BackendConfig.syncBaseURL.hasPrefix("https://"))
        #expect(BackendConfig.syncBaseURL.contains("tabmail.ai"))
    }

    @Test("syncWebSocketURL is valid WSS string")
    func syncWebSocketURLValid() {
        #expect(BackendConfig.syncWebSocketURL.hasPrefix("wss://"))
        #expect(BackendConfig.syncWebSocketURL.contains("tabmail.ai"))
        #expect(BackendConfig.syncWebSocketURL.hasSuffix("/ws"))
    }

    @Test("templatesBaseURL is valid HTTPS URL")
    func templatesBaseURLValid() {
        #expect(BackendConfig.templatesBaseURL.scheme == "https")
        #expect(BackendConfig.templatesBaseURL.host?.contains("tabmail.ai") == true)
    }

    @Test("billingBaseURL is valid HTTPS URL")
    func billingBaseURLValid() {
        #expect(BackendConfig.billingBaseURL.scheme == "https")
        #expect(BackendConfig.billingBaseURL.host?.contains("tabmail.ai") == true)
    }

    #if DEBUG
    @Test("Debug builds use dev endpoints when debug mode unlocked")
    func debugUsesDevEndpoints() {
        // useDevServers requires debug_mode_unlocked to be true in UserDefaults
        let previousUnlocked = UserDefaults.standard.object(forKey: "debug_mode_unlocked") as? Bool
        let previousOverride = UserDefaults.standard.object(forKey: "debug_use_dev_servers") as? Bool
        UserDefaults.standard.set(true, forKey: "debug_mode_unlocked")
        // Remove any explicit override so the DEBUG default (true) takes effect
        UserDefaults.standard.removeObject(forKey: "debug_use_dev_servers")
        defer {
            if let prev = previousUnlocked {
                UserDefaults.standard.set(prev, forKey: "debug_mode_unlocked")
            } else {
                UserDefaults.standard.removeObject(forKey: "debug_mode_unlocked")
            }
            if let prev = previousOverride {
                UserDefaults.standard.set(prev, forKey: "debug_use_dev_servers")
            } else {
                UserDefaults.standard.removeObject(forKey: "debug_use_dev_servers")
            }
        }
        #expect(BackendConfig.apiBaseURL.host?.contains("dev") == true)
    }
    #endif
}
