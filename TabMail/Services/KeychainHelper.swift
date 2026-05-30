/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Security

enum KeychainHelper {
    private static let service = "ai.tabmail.ios"
    private static let accessGroup = "group.ai.tabmail"

    static func save(_ data: Data, for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        // Try to update existing item first (also upgrade accessibility for background sync)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // Accessible after first unlock — allows background sync when device is locked
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            // Handle race: another thread added between our update check and add
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw KeychainError.saveFailed(retryStatus)
                }
            } else if addStatus != errSecSuccess {
                throw KeychainError.saveFailed(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.saveFailed(updateStatus)
        }
    }

    static func save(_ string: String, for key: String) throws {
        guard let data = string.data(using: .utf8) else { return }
        try save(data, for: key)
    }

    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func loadString(key: String) -> String? {
        guard let data = load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: Error {
    case saveFailed(OSStatus)
}

// Key naming conventions for accounts
extension KeychainHelper {
    static func passwordKey(accountId: String) -> String { "password:\(accountId)" }
    static func accessTokenKey(accountId: String) -> String { "accessToken:\(accountId)" }
    static func refreshTokenKey(accountId: String) -> String { "refreshToken:\(accountId)" }

    // MARK: - BYOK (Bring Your Own Key) — device-local, NSE-readable storage
    //
    // BYOK API keys live in a separate Keychain service (`byokService`) but
    // use the SAME shared access group as OAuth tokens (`group.ai.tabmail`)
    // because the Notification Service Extension needs read access — NSE runs
    // background AI on incoming pushes (ADR-IOS-037), and BYOK users expect
    // their key to drive that processing.
    //
    // ONE key per provider. The same OpenAI key services any tier routed
    // through OpenAI; per-tier model preference is stored separately in
    // UserDefaults. This matches the user's mental model ("I have an OpenAI
    // key" — singular, not per-feature).
    //
    // Privacy guarantee comes from `kSecAttrAccessibleAfterFirstUnlockThis-
    // DeviceOnly` + `kSecAttrSynchronizable=false`: the key never leaves the
    // physical device — no iCloud Keychain sync, no other-device leakage.
    // NSE is the user's own app's extension, so its access is part of the
    // app, not a third party.
    private static let byokService = "ai.tabmail.ios.byok"

    static func saveBYOK(_ apiKey: String, provider: String) throws {
        guard let data = apiKey.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: byokService,
            kSecAttrAccount as String: provider,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                guard retryStatus == errSecSuccess else { throw KeychainError.saveFailed(retryStatus) }
            } else if addStatus != errSecSuccess {
                throw KeychainError.saveFailed(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.saveFailed(updateStatus)
        }
    }

    static func loadBYOK(provider: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: byokService,
            kSecAttrAccount as String: provider,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteBYOK(provider: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: byokService,
            kSecAttrAccount as String: provider,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Upgrade ALL items in our service to `kSecAttrAccessibleAfterFirstUnlock`
    /// and migrate to shared access group for NSE access.
    /// Older items may have been saved without an access group or with
    /// `kSecAttrAccessibleWhenUnlocked`, which blocks keychain reads
    /// when the device is locked (background sync, NSE).
    /// Call once on app launch (device unlocked) so the old items are still readable.
    static func migrateAccessibility() {
        // First: migrate items without access group to shared access group.
        // Read all items from old (no access group) keychain
        let oldQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var oldItems: AnyObject?
        let oldStatus = SecItemCopyMatching(oldQuery as CFDictionary, &oldItems)
        if oldStatus == errSecSuccess, let items = oldItems as? [[String: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data else { continue }

                // Check if item already exists in shared access group
                let checkQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrAccessGroup as String: accessGroup,
                ]
                let checkStatus = SecItemCopyMatching(checkQuery as CFDictionary, nil)
                if checkStatus == errSecSuccess { continue } // Already migrated

                // Add to shared access group
                let newItem: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrAccessGroup as String: accessGroup,
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                ]
                let addStatus = SecItemAdd(newItem as CFDictionary, nil)
                if addStatus == errSecSuccess {
                    print("[Keychain] Migrated \(account) to shared access group")
                }
            }
        }

        // Second: ensure all items in shared group have AfterFirstUnlock accessibility
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            print("[Keychain] Migrated all items to AfterFirstUnlock + shared access group")
        } else if status != errSecItemNotFound {
            print("[Keychain] Accessibility migration status: \(status)")
        }
    }
}
