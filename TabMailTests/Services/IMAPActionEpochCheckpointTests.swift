/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// T2.6/T2.7 — observable claim-time and live-SELECT epoch checkpoints.
///
/// PORT: v2final `claimFrontierOperation` A4, `requireSameUidValidity`,
/// `withActionConnectionSelection`, and the move reassertions in `e70f674f3`
/// / `dad1b52f6`. SUBTRACT: RFC/hybrid compatibility, nil fail-open, demotion,
/// global FIFO, and ambient expectation state. ⚑ NO REFERENCE — INVENTED:
/// v3's provider/account classification and whole-op fail-closed adaptation.
@Suite("T2.6/T2.7 — IMAP action epoch checkpoints", .serialized, .processGlobalState)
struct IMAPActionEpochCheckpointTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    @MainActor
    private func fixture(
        accountId: String = "checkpoint-imap",
        folders: [(String, FolderRole, Int?)] = [("INBOX", .inbox, 10), ("Drafts", .drafts, 10)]
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "checkpoint@example.com", displayName: "Checkpoint", provider: .imap)
            account.id = accountId
            try account.insert(db)
            for (path, role, epoch) in folders {
                var folder = Folder(name: path, path: path, role: role, accountId: accountId)
                folder.lastKnownUidValidity = epoch
                try folder.insert(db)
            }
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    @MainActor
    private func finish(_ fixture: Fixture) async {
        await AccountManager.shared.unregisterProviderForTesting(accountId: fixture.accountId)
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func insert(_ operations: [PendingOperation], into pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in
            for operation in operations { try operation.insert(db) }
        }
    }

    private func operations(_ pool: DatabasePool) throws -> [PendingOperation] {
        try pool.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }
    }

    private static func rfc822(messageId: String) -> String {
        """
        From: Sender <sender@example.com>\r
        To: Receiver <receiver@example.com>\r
        Subject: checkpoint\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        checkpoint body\r

        """
    }

    private static func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: id))
    }

    private static func provider(_ server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
    }

    @MainActor
    private func registeredProvider(
        server: FakeIMAPServer, fixture: Fixture
    ) async throws -> IMAPProvider {
        let provider = Self.provider(server)
        try await provider.connect()
        await AccountManager.shared.registerProviderForTesting(
            accountId: fixture.accountId, provider: provider)
        return provider
    }

    private func mutatingStoreCommands(_ server: FakeIMAPServer) -> [String] {
        server.recordedCommands().filter {
            let upper = $0.uppercased()
            return upper.contains("UID STORE") || upper.hasPrefix("STORE ")
        }
    }

    @Test("A native IMAP action with missing, zero, or mismatched admitted UIDVALIDITY is dropped before provider I/O")
    @MainActor
    func invalidAdmissionStampDropsBeforeProvider() async throws {
        let f = try fixture()
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: provider)
        let ops = [
            PendingOperation(type: .markRead, messageIds: ["1"], accountId: f.accountId, folderPath: "INBOX"),
            PendingOperation(type: .markRead, messageIds: ["2"], accountId: f.accountId, folderPath: "INBOX", observedUidValidity: 0),
            PendingOperation(type: .markRead, messageIds: ["3"], accountId: f.accountId, folderPath: "INBOX", observedUidValidity: 9),
        ]
        try insert(ops, into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(await provider.callLog.isEmpty)
        #expect(try operations(f.pool).isEmpty)
        await finish(f)
    }

    @Test("A mixed native and RFC IMAP payload is dropped whole without splitting or provider I/O")
    @MainActor
    func mixedPayloadDropsWhole() async throws {
        let f = try fixture()
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: provider)
        let op = PendingOperation(
            type: .markRead, messageIds: ["1", "message@example.com"],
            accountId: f.accountId, folderPath: "INBOX", observedUidValidity: 10)
        try insert([op], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(await provider.callLog.isEmpty)
        #expect(try operations(f.pool).isEmpty)
        await finish(f)
    }

    @Test("RFC-only nil-epoch IMAP replied, forwarded, add-label, and remove-label operations drop whole before duplicate-RFC provider I/O")
    @MainActor
    func rfcOnlyMutatingBypassesDropWhole() async throws {
        let duplicateRFC = "duplicate-action@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [
                Self.message(uid: 31, id: duplicateRFC),
                Self.message(uid: 32, id: duplicateRFC),
            ],
        ])
        server.setUidValidity(10, for: "INBOX")
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        let bypassTypes: [OperationType] = [
            .markReplied, .markForwarded, .addUserLabel, .removeUserLabel,
        ]
        let queued = bypassTypes.map { type in
            PendingOperation(
                type: type,
                messageIds: [duplicateRFC],
                accountId: f.accountId,
                folderPath: "INBOX",
                userLabelId: type == .addUserLabel || type == .removeUserLabel
                    ? "test-label"
                    : nil)
        }
        try insert(queued, into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        let forbiddenCommands = server.recordedCommands().filter { command in
            let upper = command.uppercased()
            return upper.contains("SEARCH") || upper.contains("STORE")
                || upper.contains(" MOVE ") || upper.contains("EXPUNGE")
        }
        #expect(forbiddenCommands.isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
        #expect(try operations(f.pool).isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A matching native IMAP action passes checkpoint A and reaches checkpoint B")
    @MainActor
    func matchingActionReachesLiveSelect() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": [Self.message(uid: 1, id: "target@example.com")]])
        server.setUidValidity(10, for: "INBOX")
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .markRead, messageIds: ["1"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(server.recordedCommands().contains { $0.uppercased().contains("SELECT") })
        #expect(mutatingStoreCommands(server).count == 1)
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A newly admitted saveDraft op is not consumed by generic checkpoint A")
    @MainActor
    func saveDraftBypassesGenericCheckpoint() async throws {
        let server = FakeIMAPServer(mailboxes: ["Drafts": []])
        server.setUidValidity(10, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        var draft = Draft(
            id: "draft-checkpoint", accountId: f.accountId,
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]", subject: "Draft", body: "Body",
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
        draft.instanceEpoch = "instance-1"
        let persistedDraft = draft
        try await f.pool.writeWithoutTransaction { db in try persistedDraft.insert(db) }
        try insert([PendingOperation(
            type: .saveDraft,
            messageIds: [draft.id, PendingOperation.draftPlaceholderMessageId(draftId: draft.id, instanceEpoch: draft.instanceEpoch)],
            accountId: f.accountId, folderPath: "Drafts",
            instanceEpoch: draft.instanceEpoch, draftId: draft.id)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(server.recordedCommands().contains { $0.uppercased().contains("APPEND") })
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A newly admitted deleteDraft op is not consumed by generic checkpoint A")
    @MainActor
    func deleteDraftBypassesGenericCheckpoint() async throws {
        let server = FakeIMAPServer(mailboxes: [
            "Drafts": [Self.message(uid: 5, id: "draft-target@example.com")],
        ])
        server.setUidValidity(10, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .deleteDraft, messageIds: ["5"],
            accountId: f.accountId, folderPath: "Drafts",
            draftServerUidValidity: 10,
            draftDeleteAddressKind: .providerResource)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(server.recordedCommands().contains {
            let upper = $0.uppercased()
            return upper.contains("UID STORE") || upper.contains("UID EXPUNGE")
        })
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A UIDVALIDITY change after claim but before mutation produces zero provider writes")
    @MainActor
    func liveEpochChangeRefusesMutation() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": [Self.message(uid: 1, id: "new-occupant@example.com")]])
        server.setUidValidity(11, for: "INBOX")
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .markRead, messageIds: ["1"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(mutatingStoreCommands(server).isEmpty)
        #expect(!server.flags(in: "INBOX", uid: 1).contains("\\Seen"))
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A UIDVALIDITY bump between the wrapper SELECT and inner action SELECT produces zero mutation")
    @MainActor
    func epochBumpBetweenSelectsRefusesMutation() async throws {
        let original = Self.message(uid: 1, id: "target@example.com")
        let decoy = Self.message(uid: 1, id: "decoy@example.com")
        let server = FakeIMAPServer(mailboxes: ["INBOX": [original]])
        server.setUidValidity(10, for: "INBOX")
        server.expectMutation(rfc822MessageId: "target@example.com")
        server.resetMailboxAfterNextSuccessfulResponse(
            containing: "SELECT", mailbox: "INBOX", uidValidity: 11, messages: [decoy])
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .markRead, messageIds: ["1"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(mutatingStoreCommands(server).isEmpty)
        #expect(!server.flags(in: "INBOX", uid: 1).contains("\\Seen"))
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A matching admitted and live UIDVALIDITY performs exactly one targeted STORE without RFC SEARCH")
    @MainActor
    func matchingEpochUsesOneNativeStore() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": [Self.message(uid: 7, id: "target@example.com")]])
        server.setUidValidity(10, for: "INBOX")
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .markRead, messageIds: ["7"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(mutatingStoreCommands(server).count == 1)
        #expect(server.flags(in: "INBOX", uid: 7).contains("\\Seen"))
        #expect(!server.recordedCommands().contains { $0.uppercased().contains("SEARCH") })
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("Concurrent IMAP lanes cannot overwrite one another's admitted UIDVALIDITY")
    @MainActor
    func concurrentLanesKeepPerCallEpochs() async throws {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 1, id: "inbox@example.com")],
            "Other": [Self.message(uid: 2, id: "other@example.com")],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(21, for: "Other")
        try server.start()
        defer { server.stop() }
        let f = try fixture(folders: [("INBOX", .inbox, 10), ("Other", .custom, 20)])
        let provider = try await registeredProvider(server: server, fixture: f)
        try insert([
            PendingOperation(type: .markRead, messageIds: ["1"], accountId: f.accountId, folderPath: "INBOX", observedUidValidity: 10),
            PendingOperation(type: .markRead, messageIds: ["2"], accountId: f.accountId, folderPath: "Other", observedUidValidity: 20),
        ], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(server.flags(in: "INBOX", uid: 1).contains("\\Seen"))
        #expect(!server.flags(in: "Other", uid: 2).contains("\\Seen"))
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("An epoch refusal drops the whole batch and never creates split child operations")
    @MainActor
    func refusalNeverSplits() async throws {
        let f = try fixture()
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: provider)
        let op = PendingOperation(
            type: .markRead, messageIds: ["1", "rfc@example.com"],
            accountId: f.accountId, folderPath: "INBOX", observedUidValidity: 10)
        try insert([op], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(await provider.callLog.isEmpty)
        #expect(try operations(f.pool).isEmpty)
        await finish(f)
    }
}
