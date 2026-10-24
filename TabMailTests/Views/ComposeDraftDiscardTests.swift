/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Compose's Discard and cleared-draft Delete, run against a real database and,
/// for a server draft, the fake IMAP server (#254). The "Save Draft?" Discard
/// keeps a draft that is on the server exactly as last saved; the cleared-draft
/// Delete removes it here and on the server; a draft that never reached the
/// server is deleted by either. Every refusal leaves the draft untouched.
@Suite("Compose draft discard", .serialized, .processGlobalState)
@MainActor
struct ComposeDraftDiscardTests {
    nonisolated private static let accountId = "compose-discard"
    nonisolated private static let epoch = 820_001
    nonisolated private static let generation = "generation"
    nonisolated private static let draftId = "reply:compose-discard:parent@example.com"
    nonisolated private static let serverMessageId = "saved-draft@example.com"
    nonisolated private static let savedBody = "Last saved text"
    nonisolated private static let attachmentBytes = Data("saved attachment".utf8)

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let attachmentDirectory: String
    }

    private struct DraftState: Equatable {
        let body: String?
        let updatedAt: Double?
        let serverDraftId: String?
        let hasServerHeader: Bool
        let pendingOperations: Int
        let outboxMessages: Int
    }

    /// One saved draft with an attachment. `serverUid` makes it a server draft in
    /// Drafts under `rowUidValidity`; nil leaves it local only.
    private func fixture(
        serverUid: Int?,
        rowUidValidity: Int? = Self.epoch,
        folderUidValidity: Int = Self.epoch
    ) throws -> Fixture {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        _ = try FolderEpochTestFixture.makeAccount(
            id: Self.accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: Self.accountId, path: "Drafts", role: .drafts, pool: pool,
            lastKnownUidValidity: folderUidValidity)
        let attachmentDirectory = DraftAttachmentStorage.newStagingDirName()
        try DraftAttachmentStorage.saveAttachments([
            DraftAttachment(filename: "draft.txt", mimeType: "text/plain", data: Self.attachmentBytes)
        ], dirName: attachmentDirectory)
        let now = Date().timeIntervalSince1970
        try pool.write { db in
            var draft = Draft(
                id: Self.draftId, accountId: Self.accountId,
                toJSON: "[\"recipient@example.com\"]", ccJSON: "[]", bccJSON: "[]",
                subject: "Re: thread", body: Self.savedBody, replyToId: nil,
                isForward: false, editHistoryJSON: nil, createdAt: now, updatedAt: now,
                serverDraftId: serverUid.map(String.init),
                serverPushStatus: serverUid == nil ? nil : "pushed",
                rfc822MessageId: nil, attachmentsDirName: attachmentDirectory)
            draft.instanceEpoch = Self.generation
            if let serverUid {
                draft.serverDraftFolderPath = "Drafts"
                draft.serverDraftUidValidity = rowUidValidity
                try MessageHeader(
                    messageId: String(serverUid), subject: "Re: thread", from: "Me",
                    fromAddress: "me@example.com", to: "recipient@example.com",
                    date: Date(), snippet: Self.savedBody, folderId: "\(Self.accountId):Drafts",
                    accountId: Self.accountId, folderPath: "Drafts", isInInbox: false).insert(db)
            }
            try draft.insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous,
                       attachmentDirectory: attachmentDirectory)
    }

    private func finish(_ fixture: Fixture) {
        DraftAttachmentStorage.deleteAttachments(dirName: fixture.attachmentDirectory)
        AppDatabase.shared.withLock { $0 = fixture.previous }
        TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory)
    }

    private func state(_ fixture: Fixture) async throws -> DraftState {
        try await fixture.pool.read { db in
            let draft = try Draft.fetchOne(db, key: Self.draftId)
            return DraftState(
                body: draft?.body, updatedAt: draft?.updatedAt,
                serverDraftId: draft?.serverDraftId,
                hasServerHeader: try MessageHeader
                    .filter(Column("folderId") == "\(Self.accountId):Drafts").fetchCount(db) > 0,
                pendingOperations: try PendingOperation.fetchCount(db),
                outboxMessages: try OutboxMessage.fetchCount(db))
        }
    }

    private func attachmentsIntact(_ fixture: Fixture) throws -> Bool {
        try DraftAttachmentStorage.loadAttachments(dirName: fixture.attachmentDirectory)
            .map(\.data) == [Self.attachmentBytes]
    }

    private func attachmentsGone(_ fixture: Fixture) -> Bool {
        !FileManager.default.fileExists(
            atPath: DraftAttachmentStorage.dirURL(for: fixture.attachmentDirectory).path)
    }

    private func discard(
        _ scope: ComposeDraftGuards.DiscardScope,
        epoch: String = Self.generation,
        readState: ComposeDraftGuards.ReadState = .loaded,
        isSavingDraft: Bool = false,
        isSending: Bool = false,
        fence: ComposeAgentSendFence = ComposeAgentSendFence()
    ) async -> ComposeDraftDiscard.Outcome {
        await ComposeDraftDiscard.run(
            scope, draftId: Self.draftId, epoch: epoch, readState: readState,
            isSavingDraft: isSavingDraft, isSending: isSending, agentSendFence: fence)
    }

    private func server(uid: Int) throws -> FakeIMAPServer {
        let server = FakeIMAPServer(mailboxes: [
            "Drafts": [FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
            From: Me <me@example.com>\r
            To: Recipient <recipient@example.com>\r
            Subject: Re: thread\r
            Message-ID: <\(Self.serverMessageId)>\r
            Content-Type: text/plain\r
            \r
            \(Self.savedBody)\r

            """)],
        ])
        server.setUidValidity(Self.epoch, for: "Drafts")
        try server.start()
        return server
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

    @Test("Discarding unsaved edits keeps a server draft, its attachments and its server copy")
    func unsavedEditsKeepServerDraft() async throws {
        let fixture = try fixture(serverUid: 42)
        defer { finish(fixture) }
        let server = try server(uid: 42)
        defer { server.stop() }
        await AccountManager.shared.registerProviderForTesting(
            accountId: Self.accountId, provider: provider(server))
        let before = try await state(fixture)

        #expect(await discard(.unsavedEdits) == .dismiss)
        await drainUntilSettled(fixture.pool)
        await AccountManager.shared.unregisterProviderForTesting(accountId: Self.accountId)

        let after = try await state(fixture)
        #expect(after == before)
        #expect(after.body == Self.savedBody)
        #expect(after.hasServerHeader)
        #expect(after.pendingOperations == 0)
        #expect(after.outboxMessages == 0)
        #expect(try attachmentsIntact(fixture))
        #expect(server.messageIDs(in: "Drafts") == ["<\(Self.serverMessageId)>"])
    }

    @Test("Deleting a cleared draft deletes it here and on the server")
    func wholeDraftDeletesServerDraft() async throws {
        let fixture = try fixture(serverUid: 42)
        defer { finish(fixture) }
        let server = try server(uid: 42)
        defer { server.stop() }
        server.expectMutation(rfc822MessageId: Self.serverMessageId)
        await AccountManager.shared.registerProviderForTesting(
            accountId: Self.accountId, provider: provider(server))

        #expect(await discard(.wholeDraft) == .dismiss)
        let queued = try await state(fixture)
        await drainUntilSettled(fixture.pool)
        await AccountManager.shared.unregisterProviderForTesting(accountId: Self.accountId)

        #expect(queued.body == nil)
        #expect(!queued.hasServerHeader)
        #expect(attachmentsGone(fixture))
        #expect(server.messageIDs(in: "Drafts").isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
        #expect(try await state(fixture).pendingOperations == 0)
    }

    @Test("A draft that never reached the server is deleted by either discard",
          arguments: [ComposeDraftGuards.DiscardScope.unsavedEdits, .wholeDraft])
    func localDraftIsDeleted(scope: ComposeDraftGuards.DiscardScope) async throws {
        let fixture = try fixture(serverUid: nil)
        defer { finish(fixture) }

        #expect(await discard(scope) == .dismiss)

        let after = try await state(fixture)
        #expect(after.body == nil)
        #expect(after.pendingOperations == 0)
        #expect(after.outboxMessages == 0)
        #expect(attachmentsGone(fixture))
    }

    @Test("A compose whose draft row is already gone closes without writing anything")
    func missingDraftCloses() async throws {
        let fixture = try fixture(serverUid: nil)
        defer { finish(fixture) }
        try await fixture.pool.write { db in _ = try Draft.deleteOne(db, key: Self.draftId) }

        #expect(await discard(.wholeDraft) == .dismiss)
        let after = try await state(fixture)
        #expect(after.pendingOperations == 0)
        #expect(after.outboxMessages == 0)
        #expect(try attachmentsIntact(fixture))
    }

    enum Refusal: String, CaseIterable {
        case saving, sending, agentEditing, loadFailed, readFails, otherGeneration
    }

    @Test("A discard that may not run leaves the draft untouched and restores agent admission",
          arguments: Refusal.allCases, [ComposeDraftGuards.DiscardScope.unsavedEdits, .wholeDraft])
    func refusalKeepsDraft(_ refusal: Refusal, scope: ComposeDraftGuards.DiscardScope) async throws {
        let fixture = try fixture(serverUid: nil)
        defer { finish(fixture) }
        let before = try await state(fixture)
        let fence = ComposeAgentSendFence()
        if refusal == .agentEditing { #expect(fence.beginAgent()) }
        if refusal == .readFails {
            try await fixture.pool.write { try $0.execute(sql: "ALTER TABLE draft RENAME TO draft_unreadable") }
        }

        let outcome = await discard(
            scope,
            epoch: refusal == .otherGeneration ? "other-generation" : Self.generation,
            readState: refusal == .loadFailed ? .error : .loaded,
            isSavingDraft: refusal == .saving,
            isSending: refusal == .sending,
            fence: fence)

        if refusal == .readFails {
            try await fixture.pool.write { try $0.execute(sql: "ALTER TABLE draft_unreadable RENAME TO draft") }
        }
        switch refusal {
        case .saving, .sending:
            #expect(outcome == .ignored)
        case .agentEditing, .loadFailed, .readFails, .otherGeneration:
            guard case .refused = outcome else {
                Issue.record("expected a refusal, got \(outcome)")
                return
            }
        }
        #expect(try await state(fixture) == before)
        #expect(try attachmentsIntact(fixture))
        if refusal == .agentEditing { fence.finishAgent() }
        #expect(fence.claimExclusiveDisposition(), "a refused discard must release the compose")
    }

    enum UnqueueableDelete: String, CaseIterable {
        /// The row lost the UIDVALIDITY its server UID was minted under.
        case unidentified
        /// Drafts was renumbered after the draft was saved.
        case staleEpoch
    }

    @Test("A cleared-draft Delete whose server delete cannot be queued keeps the draft",
          arguments: UnqueueableDelete.allCases)
    func unqueueableServerDeleteKeepsDraft(_ reason: UnqueueableDelete) async throws {
        let fixture = try fixture(
            serverUid: 42,
            rowUidValidity: reason == .unidentified ? nil : Self.epoch,
            folderUidValidity: reason == .staleEpoch ? Self.epoch + 1 : Self.epoch)
        defer { finish(fixture) }
        let server = try server(uid: 42)
        defer { server.stop() }
        await AccountManager.shared.registerProviderForTesting(
            accountId: Self.accountId, provider: provider(server))
        let before = try await state(fixture)

        let outcome = await discard(.wholeDraft)
        await AccountManager.shared.unregisterProviderForTesting(accountId: Self.accountId)

        guard case .refused = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(try await state(fixture) == before)
        #expect(try attachmentsIntact(fixture))
        #expect(server.messageIDs(in: "Drafts") == ["<\(Self.serverMessageId)>"])
    }
}
