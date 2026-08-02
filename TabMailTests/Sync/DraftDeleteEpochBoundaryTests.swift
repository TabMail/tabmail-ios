/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// PORT — v2final's claim-time UIDVALIDITY refusal, adapted to the reduced
/// provider-native `.imap(folder:uidValidity:uid:)` delete tuple. Compatibility
/// and RFC fallback cases are SUBTRACTED.
@Suite("Draft delete epoch boundary", .serialized, .processGlobalState)
@MainActor
struct DraftDeleteEpochBoundaryTests {
    private static let e1 = 810_001
    private static let e2 = 810_002

    private func fixture(
        accountId: String
    ) throws -> (pool: DatabasePool, directory: URL, previous: AppDatabase?) {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        _ = try FolderEpochTestFixture.makeAccount(
            id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Drafts", role: .drafts, pool: pool,
            lastKnownUidValidity: Self.e1)
        return (pool, directory, previous)
    }

    private func finish(
        _ fixture: (pool: DatabasePool, directory: URL, previous: AppDatabase?)
    ) {
        AppDatabase.shared.withLock { $0 = fixture.previous }
        TestDatabaseTeardown.retire(
            pool: fixture.pool, directory: fixture.directory)
    }

    private func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: draft\r
        Message-ID: <\(id)>\r
        Content-Type: text/plain\r
        \r
        body\r

        """)
    }

    private func provider(_ server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
    }

    private func drainUntilSettled(_ pool: DatabasePool) async {
        for _ in 0..<60 {
            await AccountManager.shared.drainPendingQueue()
            let remaining = (try? await pool.read {
                try PendingOperation.fetchCount($0)
            }) ?? 1
            let quiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if remaining == 0, quiescent { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A queued E1 IMAP delete never reaches the provider after E2 turnover")
    func staleQueuedDeleteIsDroppedBeforeProvider() async throws {
        let accountId = "draft-delete-stale"
        let fixture = try fixture(accountId: accountId)
        defer { finish(fixture) }
        let stranger = "stranger@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Drafts": [message(uid: 5150, id: stranger)],
        ])
        server.setUidValidity(Self.e2, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        #expect(await AccountManager.shared.queueDraftDelete(
            identity: .imap(folder: "Drafts", uidValidity: Self.e1, uid: 5150),
            accountId: accountId,
            folderPath: "Drafts"))
        #expect(try await fixture.pool.read {
            try PendingOperation.fetchCount($0)
        } == 1)
        let liveEpoch = Self.e2
        try await fixture.pool.write { db in
            try db.execute(
                sql: "UPDATE folder SET lastKnownUidValidity = ? WHERE id = ?",
                arguments: [liveEpoch, "\(accountId):Drafts"])
        }

        let commandsBeforeDrain = server.recordedCommands()
        await AccountManager.shared.registerProviderForTesting(
            accountId: accountId, provider: provider)
        await drainUntilSettled(fixture.pool)
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)

        #expect(server.messageIDs(in: "Drafts") == ["<\(stranger)>"])
        #expect(server.recordedCommands() == commandsBeforeDrain)
        #expect(server.wrongMessageViolations().isEmpty)
        #expect(try await fixture.pool.read {
            try PendingOperation.fetchCount($0)
        } == 0)
    }

    @Test("An unchanged IMAP epoch still executes the addressed delete")
    func unchangedEpochExecutesDelete() async throws {
        let accountId = "draft-delete-live"
        let fixture = try fixture(accountId: accountId)
        defer { finish(fixture) }
        let target = "target@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Drafts": [message(uid: 5151, id: target)],
        ])
        server.setUidValidity(Self.e1, for: "Drafts")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        #expect(await AccountManager.shared.queueDraftDelete(
            identity: .imap(folder: "Drafts", uidValidity: Self.e1, uid: 5151),
            accountId: accountId,
            folderPath: "Drafts"))
        await AccountManager.shared.registerProviderForTesting(
            accountId: accountId, provider: provider)
        await drainUntilSettled(fixture.pool)
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)

        #expect(server.messageIDs(in: "Drafts").isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
        #expect(try await fixture.pool.read {
            try PendingOperation.fetchCount($0)
        } == 0)
    }
}
