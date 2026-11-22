/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A conversation that reached two of the user's accounts is one thread in the
/// unified inbox. Archiving, deleting or moving it acts on every member, and
/// each member lives in its own account: its row must land in a folder of ITS
/// account, its queued operation must name a folder its own provider has, and
/// Undo must bring it back to its own account and folder.
///
/// The defect this pins: the thread actions took the destination from the
/// first member's account and applied it to every member, and the one undo
/// entry named only that account. An Outlook member of a thread whose first
/// member was on Gmail was queued to move into Gmail's synthetic All Mail
/// path, which Outlook refuses; Undo then refused the whole thread, because
/// the Outlook row is not in the account the entry named.
///
/// `.serialized`/`.processGlobalState`: these swap `AppDatabase.shared` and use
/// `AccountManager.shared`'s overlay, FIFO write queue and `UndoService.shared`
/// — the same isolation `InboxGestureActionTests` documents.
@Suite("Thread actions across accounts — each member goes to its own account's folder", .serialized, .processGlobalState)
@MainActor
struct InboxThreadAcrossAccountsTests {

    enum RoleAction: String, CaseIterable, CustomTestStringConvertible {
        case archive, delete
        var testDescription: String { rawValue }
    }

    private struct Fixture {
        let pool: DatabasePool
        let dir: URL
        let previous: AppDatabase?
        let gmailInbox: Folder
        let gmailArchive: Folder
        let gmailTrash: Folder
        let outlookInbox: Folder
        let outlookArchive: Folder
        let outlookTrash: Folder
        let outlookProjects: Folder

        func destination(_ action: RoleAction, account: String) -> Folder {
            switch (action, account) {
            case (.archive, gmailInbox.accountId): return gmailArchive
            case (.delete, gmailInbox.accountId): return gmailTrash
            case (.archive, _): return outlookArchive
            case (.delete, _): return outlookTrash
            }
        }
    }

    // MARK: - Harness (mirrors InboxGestureActionTests.swift)

    private func makeFixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        // Different paths on purpose: a member sent to the other account's
        // folder is then visible in its row and in its queued operation.
        let fixture = Fixture(
            pool: pool, dir: dir, previous: previous,
            gmailInbox: Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "gmail1"),
            gmailArchive: Folder(name: "All Mail", path: GmailProvider.archivePath, role: .archive, accountId: "gmail1"),
            gmailTrash: Folder(name: "Trash", path: "TRASH", role: .trash, accountId: "gmail1"),
            outlookInbox: Folder(name: "Inbox", path: "outlook-inbox", role: .inbox, accountId: "outlook1"),
            outlookArchive: Folder(name: "Archive", path: "outlook-archive", role: .archive, accountId: "outlook1"),
            outlookTrash: Folder(name: "Deleted Items", path: "outlook-deleted", role: .trash, accountId: "outlook1"),
            outlookProjects: Folder(name: "Projects", path: "outlook-projects", role: .custom, accountId: "outlook1"))
        try pool.writeWithoutTransaction { db in
            var gmail = Account(emailAddress: "first@example.com", displayName: "First", provider: .gmail)
            gmail.id = "gmail1"
            try gmail.insert(db)
            var outlook = Account(emailAddress: "second@example.com", displayName: "Second", provider: .outlook)
            outlook.id = "outlook1"
            try outlook.insert(db)
            for folder in [fixture.gmailInbox, fixture.gmailArchive, fixture.gmailTrash,
                           fixture.outlookInbox, fixture.outlookArchive, fixture.outlookTrash,
                           fixture.outlookProjects] {
                try folder.insert(db)
            }
        }
        return fixture
    }

    private func makeHeader(folder: Folder, messageId: String) -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "Lunch on Friday", from: "Sender",
            fromAddress: "sender@example.com", to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path,
            isInInbox: folder.role == .inbox)
        header.headerComplete = true
        header.isRead = true
        return header
    }

    private func insert(_ headers: [MessageHeader], into pool: DatabasePool) async throws {
        try await pool.writeWithoutTransaction { db in
            for header in headers { try header.insert(db) }
        }
    }

    private func clearSharedState() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
        UndoService.shared.dismissAll()
        UndoService.shared.dismissUndoFailure()
    }

    private func finish(_ fixture: Fixture) {
        clearSharedState()
        InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.dir)
    }

    private func folderId(of id: String, in pool: DatabasePool) async throws -> String? {
        try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.folderId }
    }

    /// Every queued move as (account, source folder, destination folder).
    private func queuedMoves(in pool: DatabasePool) async throws -> Set<[String]> {
        let ops = try await pool.read { db in
            try PendingOperation.filter(Column("type") == OperationType.move.rawValue).fetchAll(db)
        }
        return Set(ops.map { [$0.accountId, $0.folderPath, $0.destinationPath ?? "<nil>"] })
    }

    private func act(_ action: RoleAction, on ids: [String], with vm: InboxViewModel) async -> [String] {
        switch action {
        case .archive: return vm.archiveThread(ids)
        case .delete: return await vm.deleteThread(ids)
        }
    }

    // MARK: - Archive and delete

    @Test("archiving or deleting a thread whose members are on two accounts sends each member to its own account's folder, and one Undo brings each back to its own account and folder", arguments: RoleAction.allCases)
    func eachMemberGoesToItsOwnAccount(action: RoleAction) async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()

        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member")
        let onOutlook = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-member")
        try await insert([onGmail, onOutlook], into: fixture.pool)
        let gmailDestination = fixture.destination(action, account: "gmail1")
        let outlookDestination = fixture.destination(action, account: "outlook1")

        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        let skipped = await act(action, on: [onGmail.id, onOutlook.id], with: vm)
        #expect(skipped.isEmpty, "both members are acted on: \(skipped)")

        // On screen at once: each member shows in its own account's folder.
        #expect(AccountManager.shared.snapshotOverlay()[onGmail.id]?.folderId == gmailDestination.id)
        #expect(AccountManager.shared.snapshotOverlay()[onOutlook.id]?.folderId == outlookDestination.id)

        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == gmailDestination.id)
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == outlookDestination.id,
                "the Outlook member must land in Outlook's own folder, never in a Gmail path")
        #expect(try await queuedMoves(in: fixture.pool) == [
            ["gmail1", fixture.gmailInbox.path, gmailDestination.path],
            ["outlook1", fixture.outlookInbox.path, outlookDestination.path],
        ], "each account's operation names that account's own folder")

        #expect(UndoService.shared.undoStack.count == 1, "the whole thread is one undo entry")
        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoFailureMessage == nil, "Undo must not be refused")
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == fixture.outlookInbox.id)
    }

    @Test("a thread member whose account has no folder for the action is reported skipped, while the member on the other account still goes to its own folder", arguments: RoleAction.allCases)
    func memberWithoutTheFolderIsSkipped(action: RoleAction) async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()
        let missing = fixture.destination(action, account: "gmail1")
        try await fixture.pool.writeWithoutTransaction { db in
            _ = try Folder.filter(Column("id") == missing.id).deleteAll(db)
        }

        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member")
        let onOutlook = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-member")
        try await insert([onGmail, onOutlook], into: fixture.pool)
        let outlookDestination = fixture.destination(action, account: "outlook1")

        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        let skipped = await act(action, on: [onGmail.id, onOutlook.id], with: vm)
        #expect(skipped == [onGmail.id], "only the member with nowhere to go comes back on screen")
        #expect(AccountManager.shared.snapshotOverlay()[onGmail.id] == nil)

        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == outlookDestination.id)
        #expect(try await queuedMoves(in: fixture.pool) == [
            ["outlook1", fixture.outlookInbox.path, outlookDestination.path],
        ])
    }

    @Test("Undo of a thread archived from two folders of one account returns each member to the folder it came from")
    func undoReturnsEachMemberToItsOwnFolder() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()

        let inInbox = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-inbox-member")
        let inProjects = makeHeader(folder: fixture.outlookProjects, messageId: "outlook-projects-member")
        try await insert([inInbox, inProjects], into: fixture.pool)

        let vm = InboxViewModel(folders: [fixture.outlookInbox, fixture.outlookProjects])
        #expect(vm.archiveThread([inInbox.id, inProjects.id]).isEmpty)
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(try await folderId(of: inInbox.id, in: fixture.pool) == fixture.outlookArchive.id)
        #expect(try await folderId(of: inProjects.id, in: fixture.pool) == fixture.outlookArchive.id)

        #expect(UndoService.shared.undoStack.count == 1, "the whole thread is one undo entry")
        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoFailureMessage == nil, "Undo must not be refused")
        #expect(try await folderId(of: inInbox.id, in: fixture.pool) == fixture.outlookInbox.id)
        #expect(try await folderId(of: inProjects.id, in: fixture.pool) == fixture.outlookProjects.id)
    }

    // MARK: - Move

    @Test("moving a thread whose members are on two accounts moves only the members of the account whose folder was picked; the other member is reported skipped and left where it is, and Undo returns the moved one")
    func moveActsOnlyOnThePickedAccount() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()

        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member")
        let onOutlook = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-member")
        try await insert([onGmail, onOutlook], into: fixture.pool)

        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        let skipped = vm.moveThread(
            [onGmail.id, onOutlook.id], toFolderPath: fixture.outlookProjects.path,
            accountId: fixture.outlookProjects.accountId)
        #expect(skipped == [onGmail.id], "a message cannot move to another account's folder")
        #expect(AccountManager.shared.snapshotOverlay()[onGmail.id] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[onOutlook.id]?.folderId == fixture.outlookProjects.id)

        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == fixture.outlookProjects.id)
        #expect(try await queuedMoves(in: fixture.pool) == [
            ["outlook1", fixture.outlookInbox.path, fixture.outlookProjects.path],
        ])

        #expect(UndoService.shared.undoStack.count == 1)
        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoFailureMessage == nil, "Undo must not be refused")
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == fixture.outlookInbox.id)
    }
}
