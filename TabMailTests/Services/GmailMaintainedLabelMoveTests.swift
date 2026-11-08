/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Gmail keeps the `SENT` and `DRAFT` labels itself: its labels guide marks
/// both as not manually applicable, and `messages.modify` naming either is
/// refused with `400 "Invalid label"`. `StatefulGmailActionServer` refuses them
/// the same way, so every test here runs against that refusal.
///
/// THE PROPERTIES:
///  1. No move request ever names a label Gmail keeps.
///  2. A delete from Sent or Drafts, and the Undo of a delete from Sent, land
///     on the SERVER (asserted as the server's labels, not the queue's).
///  3. A refused action is never recorded as done: an op Gmail refuses stays
///     queued.
///  4. A user move INTO Sent or Drafts is refused before anything is queued,
///     on Gmail only.
@Suite("Gmail moves never name the labels Gmail keeps", .serialized, .processGlobalState)
struct GmailMaintainedLabelMoveTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    @MainActor
    private func fixture(accountId: String, provider: AccountProvider = .gmail) throws -> Fixture {
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
        let epoch: Int? = provider == .gmail ? nil : 10
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "Labels", provider: provider)
            account.id = accountId
            try account.insert(db)
            let folders: [(String, FolderRole)] = [
                ("INBOX", .inbox), ("SENT", .sent), ("DRAFT", .drafts),
                ("TRASH", .trash), ("Label_7", .custom),
            ]
            for (path, role) in folders {
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

    private func seedHeader(
        _ fixture: Fixture, providerId: String, folderPath: String, epoch: Int? = nil
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: providerId,
            subject: "labels \(providerId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "labels",
            folderId: MessageIdentity.folderId(accountId: fixture.accountId, folderPath: folderPath),
            accountId: fixture.accountId,
            folderPath: folderPath,
            isInInbox: folderPath == "INBOX")
        header.rfc822MessageId = "\(providerId)@example.com"
        header.headerComplete = true
        header.observedUidValidity = epoch
        let seeded = header
        try fixture.pool.writeWithoutTransaction { db in try seeded.insert(db) }
        return seeded
    }

    private static func server(providerId: String, labels: Set<String>) -> StatefulGmailActionServer {
        StatefulGmailActionServer(messages: [.init(
            rfc822MessageId: "\(providerId)@example.com",
            providerMessageId: providerId,
            labels: labels
        )], userLabels: ["Label_7": "Projects"])
    }

    @MainActor
    private func drainToQuiescence(_ fixture: Fixture) async throws {
        for _ in 0..<300 {
            let isEmpty = try await fixture.pool.read { db in
                try PendingOperation.fetchCount(db) == 0
            }
            let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if isEmpty && isQuiescent { return }
            if isQuiescent && !isEmpty {
                await AccountManager.shared.drainPendingQueue()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func pushUndo(_ header: MessageHeader, to destinationPath: String) {
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: header.folderPath, toPath: destinationPath),
            messages: [header],
            originalFolderId: header.folderId,
            originalFolderPath: header.folderPath,
            accountId: header.accountId,
            timestamp: Date()))
    }

    private static func namesAMaintainedLabel(_ log: [StatefulGmailActionServer.ModifyCall]) -> Bool {
        log.contains { call in
            (call.addLabelIds + call.removeLabelIds).contains {
                GmailProvider.gmailMaintainedLabelIds.contains($0)
            }
        }
    }

    // MARK: - 1. No request names a label Gmail keeps, for any source and destination

    /// Every folder a Gmail message can be in, as a source and as a destination.
    private static let paths = ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "Label_7", GmailProvider.archivePath]

    @Test("No Gmail move, from any folder to any other, sends a request naming SENT or DRAFT")
    func noMoveNamesAMaintainedLabel() async throws {
        for source in Self.paths {
            for destination in Self.paths where destination != source {
                // The id must not carry the synthetic All Mail path, which the
                // provider's boundary guard refuses in any request path.
                let id = "matrix-\(source.hasPrefix("__") ? "ALLMAIL" : source)-\(destination.hasPrefix("__") ? "ALLMAIL" : destination)"
                let labels: Set<String> = source == GmailProvider.archivePath ? [] : [source]
                let server = Self.server(providerId: id, labels: labels)
                defer { server.close() }
                var thrown: (any Error)?
                do {
                    try await server.provider().move(ids: [id], from: source, to: destination)
                } catch {
                    thrown = error
                }
                #expect(thrown == nil, "move \(source) -> \(destination) failed: \(String(describing: thrown))")
                #expect(!Self.namesAMaintainedLabel(server.modifyLog()),
                        "move \(source) -> \(destination) named a label Gmail keeps: \(server.modifyLog())")
            }
        }
    }

    @Test("Between Trash and Sent or Drafts the message only enters and leaves Trash, keeping its own label")
    func trashAndItsUndoKeepTheMaintainedLabel() async throws {
        for kept in ["SENT", "DRAFT"] {
            let id = "trash-\(kept)"
            let server = Self.server(providerId: id, labels: [kept])
            defer { server.close() }
            let provider = server.provider()

            try await provider.move(ids: [id], from: kept, to: "TRASH")
            #expect(server.snapshot(providerMessageId: id)?.labels == [kept, "TRASH"])

            try await provider.move(ids: [id], from: "TRASH", to: kept)
            #expect(server.snapshot(providerMessageId: id)?.labels == [kept])
        }
    }

    // MARK: - 2. The user's actions land on the server

    /// RED on the code before this fix: the delete asked Gmail to remove SENT,
    /// Gmail refused it, and the queue retired the refusal as done, so the
    /// message never reached Trash.
    @Test("Deleting a sent message puts it in Trash on the server, and Undo takes it back to Sent")
    @MainActor
    func deleteFromSentAndItsUndoLand() async throws {
        let id = "sent-delete-1"
        let server = Self.server(providerId: id, labels: ["SENT"])
        defer { server.close() }
        let f = try fixture(accountId: "gmail-sent-delete")
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())
        let seeded = try seedHeader(f, providerId: id, folderPath: "SENT")

        pushUndo(seeded, to: "TRASH")
        await AccountManager.shared.move([seeded], to: "TRASH")
        try await drainToQuiescence(f)
        #expect(server.snapshot(providerMessageId: id)?.labels == ["SENT", "TRASH"],
                "the delete did not reach Trash on the server: \(String(describing: server.snapshot(providerMessageId: id)))")

        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        try await drainToQuiescence(f)
        #expect(server.snapshot(providerMessageId: id)?.labels == ["SENT"],
                "the Undo did not take the message out of Trash: \(String(describing: server.snapshot(providerMessageId: id)))")
        #expect(!Self.namesAMaintainedLabel(server.modifyLog()))
        await finish(f)
    }

    /// The agent's delete of a draft goes through `performCoordinatedRoleMove`
    /// and an ordinary move, not the Drafts list's draft-delete route. RED on
    /// the code before this fix: Gmail refused removing DRAFT and the queue
    /// retired the refusal as done.
    @Test("The agent's delete of a Gmail draft puts the draft's message in Trash on the server")
    @MainActor
    func agentDraftDeleteLands() async throws {
        let id = "draft-delete-1"
        let server = Self.server(providerId: id, labels: ["DRAFT"])
        defer { server.close() }
        let f = try fixture(accountId: "gmail-draft-delete")
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())
        let seeded = try seedHeader(f, providerId: id, folderPath: "DRAFT")

        await AccountManager.shared.performCoordinatedRoleMove(
            ids: [seeded.id], role: .trash, expectedIdentities: [:])
        try await drainToQuiescence(f)
        #expect(server.snapshot(providerMessageId: id)?.labels.contains("TRASH") == true,
                "the draft never reached Trash: \(String(describing: server.snapshot(providerMessageId: id)))")
        #expect(!Self.namesAMaintainedLabel(server.modifyLog()))
        await finish(f)
    }

    // MARK: - 3. A refused action is never recorded as done

    /// RED on the code before this fix: `"Invalid label"` was read as
    /// provider-authoritative, so the op was deleted as completed after one
    /// refused attempt, with the message still in the inbox.
    @Test("A move Gmail refuses with Invalid label stays queued rather than being recorded as done")
    @MainActor
    func refusedMoveStaysQueued() async throws {
        let id = "refused-move-1"
        let server = Self.server(providerId: id, labels: ["INBOX"])
        defer { server.close() }
        server.markLabelDeleted("Label_7")
        let f = try fixture(accountId: "gmail-refused-move")
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())
        let seeded = try seedHeader(f, providerId: id, folderPath: "INBOX")

        await AccountManager.shared.move([seeded], to: "Label_7")
        // `move` starts its own drain, so a drain called here can return at once;
        // wait for the refusal itself and for the queue to settle after it.
        await AccountManager.shared.drainPendingQueue()
        for _ in 0..<300 {
            let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if !server.modifyLog().isEmpty && isQuiescent { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!server.modifyLog().isEmpty, "the move never reached Gmail, so nothing was refused")
        #expect(server.snapshot(providerMessageId: id)?.labels == ["INBOX"])
        let remaining = try await f.pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(remaining.count == 1, "a refused move was recorded as done: \(remaining.count) ops left")
        await finish(f)
    }

    // MARK: - 4. A user move into Sent or Drafts is refused before it is queued

    @Test("A Gmail move into Sent or Drafts is refused: nothing is queued and the message stays put")
    @MainActor
    func moveIntoAMaintainedLabelIsRefusedOnGmail() async throws {
        for destination in ["SENT", "DRAFT"] {
            let f = try fixture(accountId: "gmail-refuse-\(destination)")
            let seeded = try seedHeader(f, providerId: "refuse-\(destination)", folderPath: "INBOX")

            let admission = await AccountManager.shared.move([seeded], to: destination)

            #expect(admission.perID[seeded.id] == .terminalStale)
            let ops = try await f.pool.read { db in try PendingOperation.fetchCount(db) }
            #expect(ops == 0, "a move into \(destination) was queued")
            let row = try await f.pool.read { db in try MessageHeader.fetchOne(db, key: seeded.id) }
            #expect(row?.folderPath == "INBOX", "the message left the inbox locally")
            await finish(f)
        }
    }

    /// Control: the refusal is Gmail's alone. On IMAP, Sent is an ordinary
    /// mailbox and a move into it is queued.
    @Test("An IMAP move into a folder at the same path is still queued")
    @MainActor
    func moveIntoSentIsQueuedOnIMAP() async throws {
        let f = try fixture(accountId: "imap-sent-move", provider: .imap)
        let seeded = try seedHeader(f, providerId: "41", folderPath: "INBOX", epoch: 10)

        let admission = await AccountManager.shared.move([seeded], to: "SENT")

        #expect(admission.perID[seeded.id] == .durablyAdmitted)
        let ops = try await f.pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(ops == 1)
        await finish(f)
    }
}
