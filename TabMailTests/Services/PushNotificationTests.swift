/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("PushConfig Constants")
struct PushConfigConstantsTests {

    @Test("Device ID key is stable")
    func deviceIdKey() {
        #expect(PushConfig.deviceIdKey == "push_device_id")
    }

    @Test("Last device token key is stable")
    func lastDeviceTokenKey() {
        #expect(PushConfig.lastDeviceTokenKey == "push_last_device_token")
    }

    @Test("Registered emails key is stable")
    func registeredEmailsKey() {
        #expect(PushConfig.registeredEmailsKey == "push_registered_emails")
    }

    @Test("Silent push deadline is 25 seconds")
    func silentPushDeadline() {
        #expect(PushConfig.silentPushDeadlineSeconds == 25)
    }

    @Test("Silent push deadline leaves headroom under iOS 30s limit")
    func silentPushDeadlineHeadroom() {
        // iOS kills after ~30s. We must return before that.
        #expect(PushConfig.silentPushDeadlineSeconds < 30)
        // But not too early — we want to use most of the budget
        #expect(PushConfig.silentPushDeadlineSeconds >= 20)
    }

    @Test("Base URL is HTTPS")
    func baseURLIsHTTPS() {
        #expect(PushConfig.baseURL.hasPrefix("https://"))
    }

    @Test("Base URL contains tabmail.ai domain")
    func baseURLDomain() {
        #expect(PushConfig.baseURL.contains("tabmail.ai"))
    }
}

@Suite("Push Device Token Formatting")
struct PushDeviceTokenFormattingTests {

    @Test("Token data converts to hex string correctly")
    func tokenToHex() {
        // Simulate APNs token data → hex conversion (same logic as didReceiveDeviceToken)
        let tokenData = Data([0xAB, 0xCD, 0xEF, 0x01, 0x23])
        let tokenHex = tokenData.map { String(format: "%02x", $0) }.joined()
        #expect(tokenHex == "abcdef0123")
    }

    @Test("Empty token data produces empty hex string")
    func emptyToken() {
        let tokenData = Data()
        let tokenHex = tokenData.map { String(format: "%02x", $0) }.joined()
        #expect(tokenHex == "")
    }

    @Test("32-byte token produces 64-char hex string")
    func fullLengthToken() {
        let tokenData = Data(repeating: 0xFF, count: 32)
        let tokenHex = tokenData.map { String(format: "%02x", $0) }.joined()
        #expect(tokenHex.count == 64)
        #expect(tokenHex == String(repeating: "ff", count: 32))
    }

    @Test("Zero bytes produce '00' hex pairs")
    func zeroBytes() {
        let tokenData = Data([0x00, 0x00, 0x00])
        let tokenHex = tokenData.map { String(format: "%02x", $0) }.joined()
        #expect(tokenHex == "000000")
    }
}
