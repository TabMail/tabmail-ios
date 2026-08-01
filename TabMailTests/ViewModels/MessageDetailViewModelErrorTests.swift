/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests that MessageDetailViewModel correctly suppresses connection errors
/// from surfacing to the user, while still showing non-connection errors.
@Suite("MessageDetailViewModel error suppression")
struct MessageDetailViewModelErrorTests {

    // MARK: - Helpers

    /// Creates a temp file-backed DatabasePool with migrations applied,
    /// inserts a test account/folder/message, and returns a configured VM.
    @MainActor
    private func makeVM(
        fetchBodyOverride: @escaping (MessageHeader) async throws -> Void
    ) throws -> (MessageDetailViewModel, DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        try AppDatabase.runMigrations(on: pool)

        // Insert account, folder, and a message header (no body — forces fetch path)
        try pool.write { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)

            let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
            try folder.insert(db)

            var header = MessageHeader(
                messageId: "100",
                subject: "Test",
                from: "sender@example.com",
                fromAddress: "sender@example.com",
                to: "to@example.com",
                date: Date(),
                snippet: "snippet",
                folderId: "acc1:INBOX",
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            header.isRead = true // avoid markRead path touching AccountManager
            try header.insert(db)
        }

        let headerId = try pool.read { db in
            try MessageHeader.fetchOne(db, sql: "SELECT * FROM messageHeader WHERE messageId = '100'")!.id
        }

        let vm = MessageDetailViewModel(
            messageId: headerId,
            dbPool: pool,
            fetchBodyOverride: fetchBodyOverride
        )
        return (vm, pool, dir)
    }

    private func cleanup(_ pool: DatabasePool, _ dir: URL) {
        TestDatabaseTeardown.retire(pool: pool, directory: dir)
    }

    // MARK: - loadBody

    @Test("loadBody suppresses NIOConnectionError — error stays nil")
    @MainActor
    func loadBodySuppressesNIOConnectionError() async throws {
        let (vm, pool, dir) = try makeVM { _ in
            throw TestConnectionError(description: "NIOPosix.NIOConnectionError error 1")
        }
        defer { cleanup(pool, dir) }

        await vm.loadBody()

        #expect(vm.error == nil, "Connection errors must not surface to the user")
    }

    @Test("loadBody suppresses 'Connection reset' — error stays nil")
    @MainActor
    func loadBodySuppressesConnectionReset() async throws {
        let (vm, pool, dir) = try makeVM { _ in
            throw TestConnectionError(description: "Connection reset by peer")
        }
        defer { cleanup(pool, dir) }

        await vm.loadBody()

        #expect(vm.error == nil, "Connection errors must not surface to the user")
    }

    @Test("loadBody suppresses 'broken pipe' — error stays nil")
    @MainActor
    func loadBodySuppressesBrokenPipe() async throws {
        let (vm, pool, dir) = try makeVM { _ in
            throw TestConnectionError(description: "Write failed: broken pipe")
        }
        defer { cleanup(pool, dir) }

        await vm.loadBody()

        #expect(vm.error == nil, "Connection errors must not surface to the user")
    }

    @Test("loadBody shows non-connection error to user")
    @MainActor
    func loadBodyShowsNonConnectionError() async throws {
        let (vm, pool, dir) = try makeVM { _ in
            throw ProviderError.messageNotFound
        }
        defer { cleanup(pool, dir) }

        await vm.loadBody()

        #expect(vm.error != nil, "Non-connection errors must surface to the user")
    }

    @Test("loadBody shows authentication error to user")
    @MainActor
    func loadBodyShowsAuthError() async throws {
        let (vm, pool, dir) = try makeVM { _ in
            throw ProviderError.authenticationFailed
        }
        defer { cleanup(pool, dir) }

        await vm.loadBody()

        #expect(vm.error != nil, "Auth errors must surface to the user")
    }

    // MARK: - refetchBody

    @Test("refetchBody suppresses NIOConnectionError — error stays nil")
    @MainActor
    func refetchBodySuppressesNIOConnectionError() async throws {
        let (vm, pool, dir) = try makeVM { _ in
            throw TestConnectionError(description: "NIOPosix.NIOConnectionError error 1")
        }
        defer { cleanup(pool, dir) }

        await vm.refetchBody()

        #expect(vm.error == nil, "Connection errors must not surface to the user on refetch")
    }

    @Test("refetchBody shows non-connection error to user")
    @MainActor
    func refetchBodyShowsNonConnectionError() async throws {
        let (vm, pool, dir) = try makeVM { _ in
            throw ProviderError.messageNotFound
        }
        defer { cleanup(pool, dir) }

        await vm.refetchBody()

        #expect(vm.error != nil, "Non-connection errors must surface to the user on refetch")
    }

    // MARK: - isLoading default and lifecycle

    @Test("isLoading defaults to true — spinner shows from first frame")
    @MainActor
    func isLoadingDefaultsToTrue() throws {
        let (vm, pool, dir) = try makeVM { _ in }
        defer { cleanup(pool, dir) }

        #expect(vm.isLoading == true, "isLoading must default to true so the spinner shows immediately")
    }

    @Test("loadBody clears isLoading when body found in DB")
    @MainActor
    func loadBodyClearsIsLoadingWhenBodyExists() async throws {
        let (vm, pool, dir) = try makeVM { _ in }
        defer { cleanup(pool, dir) }

        // Insert body into DB before loadBody runs
        try await vm._dbPoolOverride!.write { db in
            let headerId = try MessageHeader.fetchOne(db, sql: "SELECT * FROM messageHeader LIMIT 1")!.id
            let body = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: "<p>Hello</p>")
            try body.insert(db)
        }

        #expect(vm.isLoading == true, "Should start loading")
        await vm.loadBody()
        #expect(vm.isLoading == false, "Must clear after body found in DB")
        #expect(vm.messageBody != nil, "Body should be loaded from DB")
    }

    @Test("loadBody clears isLoading when message not found")
    @MainActor
    func loadBodyClearsIsLoadingWhenMessageNotFound() async throws {
        // Create VM with a non-existent messageId
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        try AppDatabase.runMigrations(on: pool)

        let vm = MessageDetailViewModel(
            messageId: "nonexistent:INBOX:999",
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        defer { TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        #expect(vm.isLoading == true)
        await vm.loadBody()
        #expect(vm.isLoading == false, "Must clear isLoading even when message not found")
        #expect(vm.messageNotFound == true)
    }

    @Test("loadBody clears isLoading after connection error")
    @MainActor
    func loadBodyClearsIsLoadingAfterConnectionError() async throws {
        let (vm, pool, dir) = try makeVM { _ in
            throw TestConnectionError(description: "NIOPosix.NIOConnectionError error 1")
        }
        defer { cleanup(pool, dir) }

        #expect(vm.isLoading == true)
        await vm.loadBody()
        #expect(vm.isLoading == false, "Must clear isLoading after connection error")
        #expect(vm.messageBody == nil, "Body should be nil after failed fetch")
    }

    @Test("loadBody starts body poll when fetch fails with connection error")
    @MainActor
    func loadBodyStartsPollOnConnectionError() async throws {
        let (vm, pool, dir) = try makeVM { _ in
            throw TestConnectionError(description: "Connection reset by peer")
        }
        defer { cleanup(pool, dir) }

        await vm.loadBody()

        // Body is nil and error is nil (connection errors suppressed) — poll must start.
        // We verify indirectly: messageBody is nil but the VM is not in an error state,
        // meaning the poll safety net was activated.
        #expect(vm.messageBody == nil)
        #expect(vm.error == nil, "Connection errors must not surface")
        #expect(vm.isLoading == false)
        // The poll task is private, but we can verify the VM isn't stuck by
        // inserting a body into DB and checking if the poll picks it up.
        let vmPool = vm._dbPoolOverride!
        let headerId = try await vmPool.read { db in
            try MessageHeader.fetchOne(db, sql: "SELECT * FROM messageHeader LIMIT 1")!.id
        }
        try await vmPool.write { db in
            let body = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: "<p>Poll test</p>")
            try body.insert(db)
        }
        // Poll checks every 2s — wait for it to pick up the body
        try await Task.sleep(for: .seconds(3))
        #expect(vm.messageBody != nil, "Poll should have picked up the body from DB")
        #expect(vm.messageBody?.htmlContent == "<p>Poll test</p>")
    }
}

// MARK: - Test Helpers

/// Simple error type whose description contains a connection-error pattern.
private struct TestConnectionError: Error, CustomStringConvertible {
    let description: String
}
