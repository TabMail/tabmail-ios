/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("BackendConfig", .serialized, .processGlobalState)
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
    @Test("Unlocked debug builds default to PROD; dev endpoints require the explicit override")
    func unlockedDefaultsToProdDevRequiresOverride() {
        // Since bfc7b70 ("prod-default backend for debug builds"), ALL builds
        // default to production endpoints — unlocking the debug menu no longer
        // silently flips DEBUG builds to dev. Dev requires the explicit
        // `debug_use_dev_servers` override on top of the unlock.
        let previousUnlocked = UserDefaults.standard.object(forKey: "debug_mode_unlocked") as? Bool
        let previousOverride = UserDefaults.standard.object(forKey: "debug_use_dev_servers") as? Bool
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
        UserDefaults.standard.set(true, forKey: "debug_mode_unlocked")
        // Unlocked, no explicit override → PROD default.
        UserDefaults.standard.removeObject(forKey: "debug_use_dev_servers")
        #expect(BackendConfig.apiBaseURL.host == "api.tabmail.ai")
        // Unlocked + explicit override → dev.
        UserDefaults.standard.set(true, forKey: "debug_use_dev_servers")
        #expect(BackendConfig.apiBaseURL.host == "dev.tabmail.ai")
        // Locked → always PROD, even with the override still set.
        UserDefaults.standard.set(false, forKey: "debug_mode_unlocked")
        #expect(BackendConfig.apiBaseURL.host == "api.tabmail.ai")
    }
    #endif
}
