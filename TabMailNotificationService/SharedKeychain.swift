/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Security
#if TABMAIL_TESTS
@testable import TabMail
#endif

enum SharedKeychain {
    private static let service = "ai.tabmail.ios"
    private static let accessGroup = SharedNSEData.appGroupIdentifier

    static func getAccessToken(for accountId: String) -> String? {
        ProviderCredentialStore.shared.current(accountId: accountId)?.accessToken
    }

    static func getRefreshToken(for accountId: String) -> String? {
        ProviderCredentialStore.shared.current(accountId: accountId)?.refreshToken
    }

    static func getPassword(for accountId: String) -> String? {
        load(key: "password:\(accountId)")
    }

    static func getDeviceToken() -> String? {
        // Device token stored in UserDefaults by PushNotificationService, mirrored to shared
        SharedNSEData.suite.string(forKey: "nse.deviceToken")
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

}
