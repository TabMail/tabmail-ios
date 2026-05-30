/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Security

enum SharedKeychain {
    private static let service = "ai.tabmail.ios"
    private static let accessGroup = SharedNSEData.appGroupIdentifier

    static func getAccessToken(for accountId: String) -> String? {
        load(key: "accessToken:\(accountId)")
    }

    static func getRefreshToken(for accountId: String) -> String? {
        load(key: "refreshToken:\(accountId)")
    }

    static func getPassword(for accountId: String) -> String? {
        load(key: "password:\(accountId)")
    }

    static func getSession() -> String? {
        load(key: "tabmail_session")
    }

    static func getDeviceToken() -> String? {
        // Device token stored in UserDefaults by PushNotificationService, mirrored to shared
        SharedNSEData.suite.string(forKey: "nse.deviceToken")
    }

    static func setAccessToken(_ token: String, for accountId: String) {
        save(key: "accessToken:\(accountId)", value: token)
    }

    static func setSession(_ sessionJSON: String) {
        save(key: "tabmail_session", value: sessionJSON)
    }

    // MARK: - Private

    private static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem.merge(update) { _, new in new }
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }
}
