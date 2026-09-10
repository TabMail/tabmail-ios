/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Darwin

enum CredentialRefreshError: Error {
    case unavailable, inactive, requiresAuthorization, busy, rejected
}

/// The lock covers only synchronous storage operations, never a network await.
/// Files are a fixed set of stripes: unlinking a live lock would split its owners.
struct CredentialStorageLock: Sendable {
    let directory: URL?

    init(directory: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: BodyAssetConfig.appGroup
    )?.appendingPathComponent("credential-refresh-locks", isDirectory: true)) {
        self.directory = directory
    }

    func withLock<T>(_ identity: String, _ operation: () throws -> T) throws -> T {
        guard let directory else { throw CredentialRefreshError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        #endif
        var hash: UInt64 = 14695981039346656037
        for byte in identity.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let url = directory.appendingPathComponent(String(hash % 64))
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CredentialRefreshError.unavailable }
        defer { close(fd) }
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CredentialRefreshError.busy }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
}

/// A received token pair may replace only the snapshot that requested it.
/// Network work is bounded by each transport and never holds a storage lock.
/// Duplicate requests are allowed; a failed or vanished owner cannot disable
/// the next foreground retry of otherwise valid authorization.
final class CredentialRefreshGate: @unchecked Sendable {
    let backend: any TabMailSessionKeychainBackend
    let storageLock: CredentialStorageLock

    init(backend: any TabMailSessionKeychainBackend, storageLock: CredentialStorageLock = .init()) {
        self.backend = backend
        self.storageLock = storageLock
    }

    func read(_ account: String) throws -> Data {
        switch backend.readShared(account: account) {
        case .found(let item): return item.data
        case .notFound: throw CredentialRefreshError.inactive
        case .failed: throw CredentialRefreshError.unavailable
        }
    }

    struct Result: Sendable { let data: Data; let persisted: Bool }

    func refresh(
        account: String,
        captured: Data,
        exchange: @Sendable (Data) async throws -> Data
    ) async throws -> Result {
        try Task.checkCancellation()
        let current = try read(account)
        guard try Self.canonical(current) == Self.canonical(captured) else {
            return Result(data: current, persisted: true)
        }
        let response: Data
        do { response = try await exchange(current) }
        catch CredentialRefreshError.rejected { throw CredentialRefreshError.requiresAuthorization }
        // Save a received rotation even if its caller was canceled. Deletion is
        // independent of this lock: update-only persistence cannot recreate it.
        do {
            return try storageLock.withLock(account) {
                let latest = try read(account)
                guard try Self.canonical(latest) == Self.canonical(current) else {
                    return Result(data: latest, persisted: true)
                }
                let data = try Self.canonical(response)
                guard backend.updateShared(account: account, data: data) == .success else {
                    throw CredentialRefreshError.unavailable
                }
                return Result(data: data, persisted: true)
            }
        } catch {
            return Result(data: response, persisted: false)
        }
    }

    func delete(_ account: String) throws {
        switch backend.deleteShared(account: account) {
        case .success, .notFound: return
        case .failed: throw CredentialRefreshError.unavailable
        }
    }

    private static func canonical(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialRefreshError.unavailable
        }
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
}
