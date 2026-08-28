/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Security

/// Session-specific Keychain storage shared by the app and notification extension.
/// The small pointer is the sole activation authority; refreshes only update the
/// generation they captured before their network request.
final class TabMailSessionStore: @unchecked Sendable {
    static let shared = TabMailSessionStore()

    static let service = "ai.tabmail.ios"
    static let accessGroup = BodyAssetConfig.appGroup
    static let pointerAccount = "tabmail_session"
    static let generationPrefix = "tabmail_session_generation:"
    static let cleanupPendingKey = "tabmail.sessionCleanupPending.v1"

    static func isSessionAccount(_ account: String) -> Bool {
        account == pointerAccount || account.hasPrefix(generationPrefix)
    }

    struct ActiveSession: Sendable, Equatable {
        enum Location: Sendable, Equatable {
            case generation(String)
            case legacy
        }

        let data: Data
        let location: Location

        var generation: String? {
            guard case .generation(let generation) = location else { return nil }
            return generation
        }
    }

    enum StoreError: Error, Equatable {
        case cleanupPending
        case keychain(OSStatus)
        case verificationFailed
        case ambiguousLegacy
    }

    enum UpdateResult: Sendable, Equatable {
        case updated
        case inactive
        case failed(OSStatus)
    }

    private struct Pointer: Codable, Equatable {
        let format: String
        let generation: String

        init(generation: String) {
            format = "tabmail.session.pointer.v1"
            self.generation = generation
        }

        var isValid: Bool {
            format == "tabmail.session.pointer.v1" &&
                !generation.isEmpty &&
                !generation.contains(":") &&
                UUID(uuidString: generation) != nil
        }
    }

    private let backend: any TabMailSessionKeychainBackend
    private let cleanupDefaults: UserDefaults
    private let makeGeneration: @Sendable () -> String

    init(
        backend: any TabMailSessionKeychainBackend = SecurityTabMailSessionBackend(),
        cleanupDefaults: UserDefaults = UserDefaults(suiteName: BodyAssetConfig.appGroup) ?? .standard,
        makeGeneration: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.backend = backend
        self.cleanupDefaults = cleanupDefaults
        self.makeGeneration = makeGeneration
    }

    var isCleanupPending: Bool {
        cleanupDefaults.bool(forKey: Self.cleanupPendingKey)
    }

    func markCleanupPending() {
        cleanupDefaults.set(true, forKey: Self.cleanupPendingKey)
    }

    func clearCleanupPending() {
        cleanupDefaults.removeObject(forKey: Self.cleanupPendingKey)
    }

    /// Authorization read. Ambiguous storage fails closed; it is never evidence
    /// that deletion is safe.
    func loadActiveSession() -> ActiveSession? {
        guard !isCleanupPending else { return nil }
        switch backend.readShared(account: Self.pointerAccount) {
        case .notFound, .failed:
            return nil
        case .found(let item):
            if let pointer = decodePointer(item.data) {
                let account = Self.generationPrefix + pointer.generation
                guard case .found(let generation) = backend.readShared(account: account) else {
                    return nil
                }
                return ActiveSession(data: generation.data, location: .generation(pointer.generation))
            }
            // The pre-upgrade flat value stays readable until the main app can
            // copy-and-activate it. Callers still validate the existing session JSON.
            return ActiveSession(data: item.data, location: .legacy)
        }
    }

    @MainActor
    @discardableResult
    func installNewSession(_ data: Data) throws -> ActiveSession {
        guard !isCleanupPending else { throw StoreError.cleanupPending }

        let previousPointer = backend.readShared(account: Self.pointerAccount)
        let oldGeneration: String?
        switch previousPointer {
        case .found(let item): oldGeneration = decodePointer(item.data)?.generation
        case .notFound: oldGeneration = nil
        case .failed(let status): throw StoreError.keychain(status)
        }
        let generation = makeGeneration()
        let generationAccount = Self.generationPrefix + generation
        try requireSuccess(backend.addShared(account: generationAccount, data: data))

        let pointerData = try JSONEncoder().encode(Pointer(generation: generation))
        let activation: TabMailSessionWriteResult
        switch previousPointer {
        case .found:
            activation = backend.updateShared(account: Self.pointerAccount, data: pointerData)
        case .notFound:
            activation = backend.addShared(account: Self.pointerAccount, data: pointerData)
        case .failed(let status):
            throw StoreError.keychain(status)
        }
        try requireSuccess(activation)

        guard case .found(let verifiedPointer) = backend.readShared(account: Self.pointerAccount),
              decodePointer(verifiedPointer.data)?.generation == generation,
              case .found(let verifiedGeneration) = backend.readShared(account: generationAccount),
              verifiedGeneration.data == data else {
            // Pointer mutation is MainActor-serialized. Restore exactly the
            // prior activation state if verification could not confirm the swap.
            switch previousPointer {
            case .found(let item):
                _ = backend.updateShared(account: Self.pointerAccount, data: item.data)
            case .notFound:
                _ = backend.deleteShared(account: Self.pointerAccount)
            case .failed:
                break
            }
            throw StoreError.verificationFailed
        }

        if let oldGeneration, oldGeneration != generation {
            _ = backend.deleteShared(account: Self.generationPrefix + oldGeneration)
        }
        sweepInactiveGenerations()
        return ActiveSession(data: data, location: .generation(generation))
    }

    /// Update-only persistence. It can neither create a deleted generation nor
    /// write the active pointer.
    func updateCapturedGeneration(_ generation: String, data: Data) -> UpdateResult {
        switch backend.updateShared(account: Self.generationPrefix + generation, data: data) {
        case .success:
            return .updated
        case .notFound:
            return .inactive
        case .failed(let status):
            return .failed(status)
        }
    }

    /// Ordinary sign-out. Historical flat shadows are removed and verified
    /// before the shared pointer is touched.
    @MainActor
    func deactivate() throws {
        let capturedGeneration = pointerSnapshot()
        try deleteHistoricalPointerShadows()

        switch backend.deleteShared(account: Self.pointerAccount) {
        case .success, .notFound:
            break
        case .failed(let status):
            throw StoreError.keychain(status)
        }

        if let capturedGeneration {
            _ = backend.deleteShared(account: Self.generationPrefix + capturedGeneration)
        }
        sweepInactiveGenerations()
    }

    /// Strong fresh-install/factory-reset cleanup. The shared pointer is removed
    /// only after historical shadows; success means the whole namespace verifies empty.
    @MainActor
    func deleteAllSessionStorage() throws {
        try deleteHistoricalPointerShadows()
        switch backend.deleteShared(account: Self.pointerAccount) {
        case .success, .notFound:
            break
        case .failed(let status):
            throw StoreError.keychain(status)
        }

        let items = try enumeratedItems()
        for item in items where item.account.hasPrefix(Self.generationPrefix) {
            try delete(item)
        }
        let residue = try enumeratedItems().filter { Self.isSessionAccount($0.account) }
        guard residue.isEmpty else { throw StoreError.verificationFailed }
    }

    /// Synchronous main-app upgrade. The validation closure is the existing
    /// TabMailSession decoder, keeping session-schema ownership in the app.
    @MainActor
    func migrateLegacySession(validate: (Data) -> Bool) throws {
        guard !isCleanupPending else { throw StoreError.cleanupPending }

        switch backend.readShared(account: Self.pointerAccount) {
        case .failed(let status):
            throw StoreError.keychain(status)
        case .found(let shared):
            if decodePointer(shared.data) != nil {
                try? deleteHistoricalPointerShadows()
                sweepInactiveGenerations()
                return
            }
            guard validate(shared.data) else {
                try? deleteHistoricalPointerShadows()
                return
            }
            try migrate(data: shared.data, source: nil, pointerAlreadyExists: true)
            try? deleteHistoricalPointerShadows()
        case .notFound:
            let historical = try enumeratedItems().filter {
                $0.account == Self.pointerAccount && $0.accessGroup != Self.accessGroup && validate($0.data)
            }
            guard historical.count <= 1 else { throw StoreError.ambiguousLegacy }
            guard let source = historical.first else {
                sweepInactiveGenerations()
                return
            }
            try migrate(data: source.data, source: source, pointerAlreadyExists: false)
        }
        sweepInactiveGenerations()
    }

    @MainActor
    func sweepInactiveGenerations() {
        let keep: String?
        switch backend.readShared(account: Self.pointerAccount) {
        case .notFound:
            keep = nil
        case .found(let item):
            guard let pointer = decodePointer(item.data) else { return }
            keep = Self.generationPrefix + pointer.generation
        case .failed:
            return
        }

        guard case .success(let items) = backend.enumerateServiceItems() else { return }
        for item in items where item.accessGroup == Self.accessGroup &&
            item.account.hasPrefix(Self.generationPrefix) && item.account != keep {
            _ = backend.deletePersistentReference(item.persistentReference)
        }
    }

    private func migrate(
        data: Data,
        source: TabMailSessionKeychainItem?,
        pointerAlreadyExists: Bool
    ) throws {
        let generation = makeGeneration()
        let generationAccount = Self.generationPrefix + generation
        try requireSuccess(backend.addShared(account: generationAccount, data: data))
        let pointerData = try JSONEncoder().encode(Pointer(generation: generation))
        let activation = pointerAlreadyExists
            ? backend.updateShared(account: Self.pointerAccount, data: pointerData)
            : backend.addShared(account: Self.pointerAccount, data: pointerData)
        try requireSuccess(activation)

        guard case .found(let pointerItem) = backend.readShared(account: Self.pointerAccount),
              decodePointer(pointerItem.data)?.generation == generation,
              case .found(let generationItem) = backend.readShared(account: generationAccount),
              generationItem.data == data else {
            throw StoreError.verificationFailed
        }

        if let source {
            try delete(source)
            let shadows = try enumeratedItems().filter {
                $0.account == Self.pointerAccount && $0.accessGroup != Self.accessGroup
            }
            guard shadows.isEmpty else { throw StoreError.verificationFailed }
        }
    }

    private func pointerSnapshot() -> String? {
        switch backend.readShared(account: Self.pointerAccount) {
        case .notFound:
            return nil
        case .found(let item):
            return decodePointer(item.data)?.generation
        case .failed:
            return nil
        }
    }

    private func deleteHistoricalPointerShadows() throws {
        let shadows = try enumeratedItems().filter {
            $0.account == Self.pointerAccount && $0.accessGroup != Self.accessGroup
        }
        for item in shadows { try delete(item) }
        let remaining = try enumeratedItems().filter {
            $0.account == Self.pointerAccount && $0.accessGroup != Self.accessGroup
        }
        guard remaining.isEmpty else { throw StoreError.verificationFailed }
    }

    private func enumeratedItems() throws -> [TabMailSessionKeychainItem] {
        switch backend.enumerateServiceItems() {
        case .success(let items): return items
        case .notFound: return []
        case .failed(let status): throw StoreError.keychain(status)
        }
    }

    private func delete(_ item: TabMailSessionKeychainItem) throws {
        switch backend.deletePersistentReference(item.persistentReference) {
        case .success, .notFound: return
        case .failed(let status): throw StoreError.keychain(status)
        }
    }

    private func requireSuccess(_ result: TabMailSessionWriteResult) throws {
        switch result {
        case .success: return
        case .notFound: throw StoreError.keychain(errSecItemNotFound)
        case .failed(let status): throw StoreError.keychain(status)
        }
    }

    private func decodePointer(_ data: Data) -> Pointer? {
        guard let pointer = try? JSONDecoder().decode(Pointer.self, from: data), pointer.isValid else {
            return nil
        }
        return pointer
    }

}

struct TabMailSessionKeychainItem: Sendable, Equatable {
    let account: String
    let accessGroup: String?
    let accessible: String?
    let data: Data
    let persistentReference: Data
}

enum TabMailSessionReadResult: Sendable, Equatable {
    case found(TabMailSessionKeychainItem)
    case notFound
    case failed(OSStatus)
}

enum TabMailSessionEnumerationResult: Sendable, Equatable {
    case success([TabMailSessionKeychainItem])
    case notFound
    case failed(OSStatus)
}

enum TabMailSessionWriteResult: Sendable, Equatable {
    case success
    case notFound
    case failed(OSStatus)
}

protocol TabMailSessionKeychainBackend: Sendable {
    func readShared(account: String) -> TabMailSessionReadResult
    func addShared(account: String, data: Data) -> TabMailSessionWriteResult
    func updateShared(account: String, data: Data) -> TabMailSessionWriteResult
    func deleteShared(account: String) -> TabMailSessionWriteResult
    func enumerateServiceItems() -> TabMailSessionEnumerationResult
    func deletePersistentReference(_ reference: Data) -> TabMailSessionWriteResult
}

struct SecurityTabMailSessionBackend: TabMailSessionKeychainBackend {
    func readShared(account: String) -> TabMailSessionReadResult {
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let item = item(from: attributes) else {
            return .failed(status == errSecSuccess ? errSecDecode : status)
        }
        return .found(item)
    }

    func addShared(account: String, data: Data) -> TabMailSessionWriteResult {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return writeResult(SecItemAdd(query as CFDictionary, nil))
    }

    func updateShared(account: String, data: Data) -> TabMailSessionWriteResult {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return writeResult(SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary))
    }

    func deleteShared(account: String) -> TabMailSessionWriteResult {
        writeResult(SecItemDelete(baseQuery(account: account) as CFDictionary))
    }

    func enumerateServiceItems() -> TabMailSessionEnumerationResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TabMailSessionStore.service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else {
            return .failed(status == errSecSuccess ? errSecDecode : status)
        }
        let items = rows.compactMap(item(from:))
        guard items.count == rows.count else { return .failed(errSecDecode) }
        return .success(items)
    }

    func deletePersistentReference(_ reference: Data) -> TabMailSessionWriteResult {
        let query: [String: Any] = [kSecValuePersistentRef as String: reference]
        return writeResult(SecItemDelete(query as CFDictionary))
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TabMailSessionStore.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: TabMailSessionStore.accessGroup,
        ]
    }

    private func item(from attributes: [String: Any]) -> TabMailSessionKeychainItem? {
        guard let account = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data,
              let reference = attributes[kSecValuePersistentRef as String] as? Data else {
            return nil
        }
        return TabMailSessionKeychainItem(
            account: account,
            accessGroup: attributes[kSecAttrAccessGroup as String] as? String,
            accessible: attributes[kSecAttrAccessible as String] as? String,
            data: data,
            persistentReference: reference
        )
    }

    private func writeResult(_ status: OSStatus) -> TabMailSessionWriteResult {
        if status == errSecSuccess { return .success }
        if status == errSecItemNotFound { return .notFound }
        return .failed(status)
    }
}
