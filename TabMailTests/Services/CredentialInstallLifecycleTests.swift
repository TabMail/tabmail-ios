/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Security
import Synchronization
import Testing
@testable import TabMail

@Suite("Initial credential installation lifecycle", .serialized, .processGlobalState)
struct CredentialInstallLifecycleTests {
    @Test("A retained accessor created after the account commit recovers when its credentials arrive")
    func accessorBeforeCredentialInstall() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path)
        defer { TestDatabaseTeardown.retire(pool: pool, directory: directory) }
        try AppDatabase.runMigrations(on: pool)
        let account = Account(emailAddress: "user@example.com", displayName: "Test", provider: .gmail)
        let h = CredentialTestHarness(), calls = Mutex(0)
        let stored = try await AccountManager.persistNewOAuthAccount(account, database: .init(pool: pool)) { committed in
            let owner = try await pool.read { try Account.fetchOne($0, key: committed.id) }
            #expect(owner?.id == account.id)
            let store = h.provider
            let accessor = await AccountManager.shared.makeOAuthAccessor(accountId: committed.id, email: committed.emailAddress,
                store: store, refreshCoordinator: OAuthRefreshCoordinator(store: store)) { refresh in
                    calls.withLock { $0 += 1 }
                    #expect(refresh == "usable-refresh")
                    return OAuthTokens(accessToken: "refreshed", refreshToken: "next", expiresAt: Date().addingTimeInterval(3600), idToken: nil)
                }
            await #expect(throws: ProviderError.self) { try await accessor(false) }
            #expect(calls.withLock { $0 } == 0)
            try store.install(accountId: committed.id, tokens: .init(accessToken: "usable-access", refreshToken: "usable-refresh",
                                                                   expiresAt: Date().addingTimeInterval(3600)))
            #expect(try await accessor(false) == "usable-access")
            #expect(try await accessor(true) == "refreshed")
            #expect(calls.withLock { $0 } == 1)
            #expect(store.current(accountId: committed.id)?.accessToken == "refreshed")
            #expect(store.current(accountId: committed.id)?.refreshToken == "next")
        }
        #expect(stored.id == account.id)
    }

    @Test("An older interactive login cannot overwrite or reconnect a newer login", arguments: [false, true], [false, true])
    func interactiveCompletionOrdering(outlook: Bool, existingActivation: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-reauth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path)
        defer { TestDatabaseTeardown.retire(pool: pool, directory: directory) }
        try AppDatabase.runMigrations(on: pool)
        let account = Account(emailAddress: "reauth@example.com", displayName: "Synthetic", provider: outlook ? .outlook : .gmail)
        let store = ProviderCredentialStore.shared
        defer { try? store.remove(accountId: account.id) }
        // Use the actual row-before-credential writer, including its no-activation interval.
        _ = try await AccountManager.persistNewOAuthAccount(account, database: .init(pool: pool)) { _ in }
        if existingActivation {
            try await AccountManager.shared.installOAuthCredentials(accountId: account.id,
                tokens: OAuthTokens(accessToken: "initial-access", refreshToken: "initial-grant", expiresAt: nil, idToken: nil))
        }
        let started = CredentialTestLatch(), release = CredentialTestLatch()
        let exchanges = Mutex(0), reconnects = Mutex<[String]>([])
        let authenticate: @Sendable () async throws -> OAuthTokens = {
            exchanges.withLock { $0 += 1 }
            await started.signal(); await release.wait()
            return OAuthTokens(accessToken: "delayed-access", refreshToken: "delayed-grant", expiresAt: nil, idToken: nil)
        }
        let reconnect: @Sendable (Account) async throws -> Void = { account in
            reconnects.withLock { $0.append(account.id) }
        }
        let old = Task {
            if outlook {
                try await AccountManager.shared.reauthenticateMicrosoft(for: account, authenticate: authenticate, reconnect: reconnect)
            } else {
                try await AccountManager.shared.reauthenticateGmail(for: account, authenticate: authenticate, reconnect: reconnect)
            }
        }
        await started.wait()
        try await AccountManager.shared.installOAuthCredentials(accountId: account.id,
            tokens: OAuthTokens(accessToken: "newer-access", refreshToken: "newer-grant", expiresAt: nil, idToken: nil))
        let newer = try #require(store.activation(accountId: account.id))
        await release.signal()
        await #expect(throws: (any Error).self) { try await old.value }
        #expect(exchanges.withLock { $0 } == 1)
        #expect(reconnects.withLock { $0 }.isEmpty)
        #expect(store.activation(accountId: account.id) == newer)
        #expect(store.current(accountId: account.id)?.accessToken == "newer-access")
        #expect(store.current(accountId: account.id)?.refreshToken == "newer-grant")
        let coordinator = OAuthRefreshCoordinator(store: store)
        let next = try await coordinator.refresh(accountId: account.id, email: account.emailAddress) { grant in
            #expect(grant == "newer-grant")
            return OAuthTokens(accessToken: "usable-next", refreshToken: "usable-next-grant", expiresAt: nil, idToken: nil)
        }
        #expect(next == "usable-next")
        #expect(store.current(accountId: account.id)?.refreshToken == "usable-next-grant")
        // A current, uncontested response must still install and request reconnection.
        let current: @Sendable () async throws -> OAuthTokens = {
            OAuthTokens(accessToken: "current-interactive", refreshToken: "current-grant", expiresAt: nil, idToken: nil)
        }
        if outlook {
            try await AccountManager.shared.reauthenticateMicrosoft(for: account, authenticate: current, reconnect: reconnect)
        } else {
            try await AccountManager.shared.reauthenticateGmail(for: account, authenticate: current, reconnect: reconnect)
        }
        #expect(reconnects.withLock { $0 } == [account.id])
        #expect(store.current(accountId: account.id)?.accessToken == "current-interactive")
        #expect(store.current(accountId: account.id)?.refreshToken == "current-grant")
    }

    enum Failure: CaseIterable, Sendable { case pointerAdd, verification, pointerRollback, grantRollback, rollback, interruption, database }

    @Test("Every partial credential write retains a durable retry and cleanup owner", arguments: Failure.allCases)
    func durableOwner(failure: Failure) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: path)
        defer { TestDatabaseTeardown.retire(pool: pool, directory: directory) }
        try AppDatabase.runMigrations(on: pool)
        if failure == .database {
            try await pool.write { db in
                try db.execute(sql: "CREATE TRIGGER reject_account BEFORE INSERT ON account BEGIN SELECT RAISE(ABORT, 'synthetic insert failure'); END")
            }
        }
        let account = Account(emailAddress: "user@example.com", displayName: "Test", provider: .gmail)
        let h = CredentialTestHarness(), calls = Mutex(0)
        let failedReferences = Mutex<[Data]>([])
        let writtenItems = Mutex<[TabMailSessionKeychainItem]>([])
        let rollbackFailure = [.pointerRollback, .grantRollback, .rollback].contains(failure)
        if failure == .pointerAdd {
            h.backend.failNextAdd(account: ProviderCredentialStore.pointerPrefix + account.id, status: errSecNotAvailable)
        }
        if failure == .verification || rollbackFailure {
            let reads = Mutex(0)
            h.backend.observeReads { key in
                guard key == ProviderCredentialStore.pointerPrefix + account.id else { return }
                let count = reads.withLock { $0 += 1; return $0 }
                if count == 1 { h.backend.failNextSharedRead(status: errSecNotAvailable) }
                if count == 2 && rollbackFailure,
                   case .success(let items) = h.backend.enumerateServiceItems() {
                    writtenItems.withLock { $0 = items }
                    for item in items where failure == .rollback ||
                        (failure == .pointerRollback ? item.account == ProviderCredentialStore.pointerPrefix + account.id : item.account != ProviderCredentialStore.pointerPrefix + account.id) {
                        h.backend.failDelete(reference: item.persistentReference)
                        failedReferences.withLock { $0.append(item.persistentReference) }
                    }
                }
            }
        }
        await #expect(throws: (any Error).self) {
            try await AccountManager.persistNewOAuthAccount(account, database: .init(pool: pool)) { stored in
                calls.withLock { $0 += 1 }
                // A separate connection must see the committed owner before
                // the first secret write, including the interruption boundary.
                let reader = try DatabaseQueue(path: path)
                defer { try? reader.close() }
                let owner = try await reader.read { try Account.fetchOne($0, key: stored.id) }
                #expect(owner?.id == account.id)
                #expect(owner?.isPrimary == true)
                try h.provider.install(accountId: stored.id, tokens: CredentialTestHarness.tokens())
                if failure == .interruption { throw CancellationError() }
            }
        }
        h.backend.observeReads(nil)
        #expect(calls.withLock { $0 } == (failure == .database ? 0 : 1))
        let reader = try DatabaseQueue(path: path)
        defer { try? reader.close() }
        let owner = try await reader.read { try Account.existing(forEmail: "USER@example.com", provider: .gmail, in: $0) }
        #expect(owner?.id == (failure == .database ? nil : account.id))
        let retained: [TabMailSessionKeychainItem]
        if case .success(let items) = h.backend.enumerateServiceItems() { retained = items }
        else { retained = [] }
        let expectedRetained = failure == .rollback || failure == .interruption ? 2 : (rollbackFailure ? 1 : 0)
        #expect(retained.count == expectedRetained)
        if rollbackFailure {
            let written = writtenItems.withLock { $0 }
            #expect(written.count == 2)
            let denied = failedReferences.withLock { $0 }
            for item in written {
                #expect(h.backend.item(reference: item.persistentReference) == (denied.contains(item.persistentReference) ? item : nil))
            }
        }
        for reference in failedReferences.withLock({ $0 }) { h.backend.allowDelete(reference: reference) }
        // A fresh store on relaunch can address the exact same account and
        // clean up even if the original invocation never returned normally.
        try h.provider.remove(accountId: account.id)
        switch h.backend.enumerateServiceItems() {
        case .notFound: break
        case .success(let items): #expect(items.isEmpty)
        case .failed: Issue.record("Cleanup namespace could not be read")
        }
        #expect(h.provider.current(accountId: account.id) == nil)
    }
}
