/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("PushConfig")
struct PushConfigTests {

    @Test("baseURL is https")
    func baseURLIsHTTPS() {
        #expect(PushConfig.baseURL.hasPrefix("https://"))
    }

    @Test("baseURL contains tabmail.ai domain")
    func baseURLDomain() {
        #expect(PushConfig.baseURL.contains("tabmail.ai"))
    }

    @Test("silentPushDeadlineSeconds is under iOS 30s limit")
    func deadlineUnder30s() {
        #expect(PushConfig.silentPushDeadlineSeconds < 30)
        #expect(PushConfig.silentPushDeadlineSeconds > 0)
    }

    @Test("silentPushDeadlineSeconds is 25 (5s headroom)")
    func deadlineIs25() {
        #expect(PushConfig.silentPushDeadlineSeconds == 25)
    }

    @Test("UserDefaults keys are unique")
    func uniqueKeys() {
        let keys = [PushConfig.deviceIdKey, PushConfig.lastDeviceTokenKey, PushConfig.registeredEmailsKey]
        #expect(Set(keys).count == keys.count)
    }

    @Test("UserDefaults keys have push_ prefix")
    func keyPrefix() {
        #expect(PushConfig.deviceIdKey.hasPrefix("push_"))
        #expect(PushConfig.lastDeviceTokenKey.hasPrefix("push_"))
        #expect(PushConfig.registeredEmailsKey.hasPrefix("push_"))
    }
}
