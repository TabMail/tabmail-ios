/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("KeychainHelper Key Naming")
struct KeychainHelperKeyNamingTests {

    @Test("passwordKey includes account ID")
    func passwordKey() {
        let key = KeychainHelper.passwordKey(accountId: "acc1")
        #expect(key == "password:acc1")
    }

    @Test("accessTokenKey includes account ID")
    func accessTokenKey() {
        let key = KeychainHelper.accessTokenKey(accountId: "user@example.com")
        #expect(key == "accessToken:user@example.com")
    }

    @Test("refreshTokenKey includes account ID")
    func refreshTokenKey() {
        let key = KeychainHelper.refreshTokenKey(accountId: "user@example.com")
        #expect(key == "refreshToken:user@example.com")
    }

    @Test("Different accounts produce different keys")
    func uniqueKeys() {
        let key1 = KeychainHelper.passwordKey(accountId: "acc1")
        let key2 = KeychainHelper.passwordKey(accountId: "acc2")
        #expect(key1 != key2)
    }

    @Test("Key types are distinct for same account")
    func keyTypesDistinct() {
        let accountId = "acc1"
        let password = KeychainHelper.passwordKey(accountId: accountId)
        let access = KeychainHelper.accessTokenKey(accountId: accountId)
        let refresh = KeychainHelper.refreshTokenKey(accountId: accountId)
        #expect(password != access)
        #expect(access != refresh)
        #expect(password != refresh)
    }
}

@Suite("KeychainError")
struct KeychainErrorTests {

    @Test("KeychainError.saveFailed stores OSStatus")
    func saveFailedStoresStatus() {
        let error = KeychainError.saveFailed(-25299) // errSecDuplicateItem
        if case .saveFailed(let status) = error {
            #expect(status == -25299)
        } else {
            Issue.record("Expected saveFailed case")
        }
    }
}

@Suite("BYOK Keychain isolation")
struct BYOKKeychainTests {
    private static let testProvider = "openai_test_\(UUID().uuidString.prefix(8))"

    @Test("Round-trip: save then load returns the same key")
    func roundTrip() throws {
        let secret = "sk-test-roundtrip-\(UUID().uuidString)"
        try KeychainHelper.saveBYOK(secret, provider: Self.testProvider)
        defer { KeychainHelper.deleteBYOK(provider: Self.testProvider) }

        let loaded = KeychainHelper.loadBYOK(provider: Self.testProvider)
        #expect(loaded == secret)
    }

    @Test("Overwrite: second save replaces the first")
    func overwrite() throws {
        try KeychainHelper.saveBYOK("first", provider: Self.testProvider)
        try KeychainHelper.saveBYOK("second", provider: Self.testProvider)
        defer { KeychainHelper.deleteBYOK(provider: Self.testProvider) }

        #expect(KeychainHelper.loadBYOK(provider: Self.testProvider) == "second")
    }

    @Test("Delete removes the entry")
    func deleteRemoves() throws {
        try KeychainHelper.saveBYOK("doomed", provider: Self.testProvider)
        KeychainHelper.deleteBYOK(provider: Self.testProvider)
        #expect(KeychainHelper.loadBYOK(provider: Self.testProvider) == nil)
    }

    @Test("BYOK key IS reachable via the shared NSE access group (required for background AI)")
    func readableViaNSEAccessGroup() throws {
        // NSE runs background AI on incoming pushes (ADR-IOS-037). If the user
        // has BYOK configured, NSE needs to read the key to drive that
        // processing. This test pins that requirement — if BYOK ever moves
        // off the shared access group, NSE background AI for BYOK users will
        // silently fall through to the pool. Privacy is preserved by
        // ThisDeviceOnly + Synchronizable=false (no iCloud sync).
        let secret = "sk-test-nse-access-\(UUID().uuidString)"
        try KeychainHelper.saveBYOK(secret, provider: Self.testProvider)
        defer { KeychainHelper.deleteBYOK(provider: Self.testProvider) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ai.tabmail.ios.byok",
            kSecAttrAccount as String: Self.testProvider,
            kSecAttrAccessGroup as String: "group.ai.tabmail",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(status == errSecSuccess, "BYOK key must be reachable via the NSE access group; NSE needs it for background AI on push")
        if let data = result as? Data, let loaded = String(data: data, encoding: .utf8) {
            #expect(loaded == secret)
        }
    }

    @Test("Different providers store independently")
    func providersIndependent() throws {
        // One key per provider, shared across tiers. Deleting one provider's
        // key must not affect the others.
        let providerA = "openai_test_\(UUID().uuidString.prefix(8))"
        let providerB = "anthropic_test_\(UUID().uuidString.prefix(8))"
        let providerC = "google_test_\(UUID().uuidString.prefix(8))"
        try KeychainHelper.saveBYOK("openai-key", provider: providerA)
        try KeychainHelper.saveBYOK("anthropic-key", provider: providerB)
        try KeychainHelper.saveBYOK("google-key", provider: providerC)
        defer {
            KeychainHelper.deleteBYOK(provider: providerA)
            KeychainHelper.deleteBYOK(provider: providerB)
            KeychainHelper.deleteBYOK(provider: providerC)
        }

        #expect(KeychainHelper.loadBYOK(provider: providerA) == "openai-key")
        #expect(KeychainHelper.loadBYOK(provider: providerB) == "anthropic-key")
        #expect(KeychainHelper.loadBYOK(provider: providerC) == "google-key")

        KeychainHelper.deleteBYOK(provider: providerA)
        #expect(KeychainHelper.loadBYOK(provider: providerA) == nil)
        #expect(KeychainHelper.loadBYOK(provider: providerB) == "anthropic-key")
        #expect(KeychainHelper.loadBYOK(provider: providerC) == "google-key")
    }
}
