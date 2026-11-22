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
/// The fixture is OFFLINE (`NetworkMonitor.setConnectedForTesting(false)`), so
/// every forward move stays queued and never attempted: Undo then cancels it
/// (the annihilation exit) instead of queueing a reverse move, which is what
/// these tests check.
///
/// `.serialized`/`.processGlobalState`: these swap `AppDatabase.shared` and use
/// `AccountManager.shared`'s overlay, FIFO write queue and `UndoService.shared`
/// — the same isolation `InboxGestureActionTests` documents — and set the
/// process-wide connectivity flag and the mark-read setting.
@Suite("Thread actions across accounts — each member goes to its own account's folder", .serialized, .processGlobalState)
@MainActor
struct InboxThreadAcrossAccountsTests {

    enum RoleAction: String, CaseIterable, CustomTestStringConvertible {
        case archive, delete
        var testDescription: String { rawValue }
    }

    enum RekeyMoment: String, CaseIterable, CustomTestStringConvertible {
        /// The forward move finished while the entry was still on the stack.
        case beforeUndo
        /// It finished after Undo was asked for, while its part waits in the FIFO.
        case whileUndoIsQueued
        var testDescription: String { rawValue }
    }

    private struct Fixture {
        let pool: DatabasePool
        let dir: URL
        let previous: AppDatabase?
        let wasConnected: Bool
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

        func inbox(_ account: String) -> Folder {
            account == gmailInbox.accountId ? gmailInbox : outlookInbox
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
        let wasConnected = NetworkMonitor.checkConnected()
        NetworkMonitor.setConnectedForTesting(false)
        // Different paths on purpose: a member sent to the other account's
        // folder is then visible in its row and in its queued operation.
        let fixture = Fixture(
            pool: pool, dir: dir, previous: previous, wasConnected: wasConnected,
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

    private func makeHeader(folder: Folder, messageId: String, isRead: Bool = true) -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "Lunch on Friday", from: "Sender",
            fromAddress: "sender@example.com", to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path,
            isInInbox: folder.role == .inbox)
        header.headerComplete = true
        header.isRead = isRead
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
        UserDefaults.standard.removeObject(forKey: AccountManager.markReadOnArchiveDeleteKey)
        NetworkMonitor.setConnectedForTesting(fixture.wasConnected)
        InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.dir)
    }

    /// Holds the FIFO write queue until the returned continuation finishes, so
    /// what a gesture shows on screen can be read before its queued write runs.
    private func gateWriteQueue() async -> AsyncStream<Void>.Continuation {
        let (stream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        return gate
    }

    private func header(_ id: String, in pool: DatabasePool) async throws -> MessageHeader? {
        try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
    }

    private func folderId(of id: String, in pool: DatabasePool) async throws -> String? {
        try await header(id, in: pool)?.folderId
    }

    /// Every durable operation in the order the executor claims them.
    private func operations(in pool: DatabasePool) async throws -> [PendingOperation] {
        try await pool.read { db in
            try PendingOperation.order(Column("queuePosition").asc).fetchAll(db)
        }
    }

    /// Every queued move as (account, source folder, destination folder,
    /// members), one entry per operation.
    private func queuedMoves(in pool: DatabasePool) async throws -> [[String]] {
        try await operations(in: pool)
            .filter { $0.type == .move }
            .map { [$0.accountId, $0.folderPath, $0.destinationPath ?? "<nil>",
                    $0.messageIds.sorted().joined(separator: ",")] }
            .sorted { $0.joined(separator: "|") < $1.joined(separator: "|") }
    }

    private func act(_ action: RoleAction, on ids: [String], with vm: InboxViewModel) async -> [String] {
        switch action {
        case .archive: return vm.archiveThread(ids)
        case .delete: return await vm.deleteThread(ids)
        }
    }

    // MARK: - Archive and delete

    @Test("archiving or deleting a thread whose members are on two accounts shows and sends each member to its own account's folder, and one Undo cancels exactly those moves and brings each member back", arguments: RoleAction.allCases)
    func eachMemberGoesToItsOwnAccount(action: RoleAction) async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()

        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member")
        let onOutlook = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-member")
        let bystander = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-bystander")
        try await insert([onGmail, onOutlook, bystander], into: fixture.pool)
        let gmailDestination = fixture.destination(action, account: "gmail1")
        let outlookDestination = fixture.destination(action, account: "outlook1")
        // Another message's queued move to the same folder: Undo must leave it.
        let unrelated = try await fixture.pool.write { db -> PendingOperation in
            var operation = PendingOperation(
                type: .move, messageIds: [bystander.messageId], accountId: "outlook1",
                folderPath: fixture.outlookInbox.path, destinationPath: outlookDestination.path)
            try operation.insert(db)
            return operation
        }

        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        let gate = await gateWriteQueue()
        let skipped = await act(action, on: [onGmail.id, onOutlook.id], with: vm)
        #expect(skipped.isEmpty, "both members are acted on: \(skipped)")

        // On screen at once, before the queued write runs: each member shows
        // in its own account's folder, out of the inbox.
        let overlay = AccountManager.shared.snapshotOverlay()
        for (member, destination) in [(onGmail, gmailDestination), (onOutlook, outlookDestination)] {
            let entry = overlay[member.id]
            #expect(entry?.folderId == destination.id, "\(member.messageId) shows in \(destination.path)")
            #expect(entry?.folderPath == destination.path, "\(member.messageId) shows in \(destination.path)")
            #expect(entry?.isInInbox == false, "\(member.messageId) shows out of the inbox")
        }
        gate.finish()

        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == gmailDestination.id)
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == outlookDestination.id,
                "the Outlook member must land in Outlook's own folder, never in a Gmail path")
        let forwards = try await operations(in: fixture.pool).filter { $0.id != unrelated.id }
        let forwardsWaitUnattempted = forwards.allSatisfy {
            $0.status == PendingStatus.queued.rawValue && !$0.everAttempted
        }
        #expect(try await queuedMoves(in: fixture.pool) == [
            ["gmail1", fixture.gmailInbox.path, gmailDestination.path, onGmail.messageId],
            ["outlook1", fixture.outlookInbox.path, outlookDestination.path, bystander.messageId],
            ["outlook1", fixture.outlookInbox.path, outlookDestination.path, onOutlook.messageId],
        ], "each account's operation names that account's own folder and only its own member")
        #expect(forwards.count == 2 && forwardsWaitUnattempted,
                "setup: offline, so both forward moves are still queued and never attempted")

        #expect(UndoService.shared.undoStack.count == 1, "the whole thread is one undo entry")
        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoFailureMessage == nil, "Undo must not be refused")
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == fixture.outlookInbox.id)
        #expect(try await operations(in: fixture.pool).map(\.id) == [unrelated.id],
                "Undo cancels exactly the thread's own queued moves and queues no reverse move")
    }

    @Test("archiving or deleting a thread across two accounts records each account's read before that account's move, for the acted-on unread members only", arguments: RoleAction.allCases)
    func eachAccountReadsBeforeItsMove(action: RoleAction) async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()
        UserDefaults.standard.set(true, forKey: AccountManager.markReadOnArchiveDeleteKey)

        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member", isRead: false)
        let onOutlook = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-member", isRead: false)
        // Already where the action would send it: left out, so it stays unread.
        let settled = makeHeader(
            folder: fixture.destination(action, account: "outlook1"),
            messageId: "outlook-settled", isRead: false)
        try await insert([onGmail, onOutlook, settled], into: fixture.pool)

        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        let skipped = await act(action, on: [onGmail.id, onOutlook.id, settled.id], with: vm)
        #expect(skipped == [settled.id])
        await AccountManager.shared.awaitWriteQueueDrain()

        let operations = try await operations(in: fixture.pool)
        let reads = operations.filter { $0.type == .markRead }
        let readPayloads = Set(reads.map { [$0.accountId, $0.folderPath] + $0.messageIds.sorted() })
        #expect(readPayloads == [
            ["gmail1", fixture.gmailInbox.path, onGmail.messageId],
            ["outlook1", fixture.outlookInbox.path, onOutlook.messageId],
        ], "one read per account, in its SOURCE folder, naming only its acted-on member")
        for account in ["gmail1", "outlook1"] {
            let read = reads.first { $0.accountId == account }
            let move = operations.first { $0.type == .move && $0.accountId == account }
            #expect(read != nil && move != nil, "\(account) has a read and a move")
            if let read, let move {
                #expect(read.queuePosition < move.queuePosition,
                        "\(account)'s read must be claimed before its move: a move changes the address the read names")
            }
        }
        #expect(try await header(onGmail.id, in: fixture.pool)?.isRead == true)
        #expect(try await header(onOutlook.id, in: fixture.pool)?.isRead == true)
        #expect(try await header(settled.id, in: fixture.pool)?.isRead == false,
                "a member the action left out is not marked read")
    }

    @Test("a thread member whose account has no folder for the action is reported skipped, while the member on the other account still goes to its own folder, whichever account misses it", arguments: RoleAction.allCases, ["gmail1", "outlook1"])
    func memberWithoutTheFolderIsSkipped(action: RoleAction, missingAccount: String) async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()
        let missing = fixture.destination(action, account: missingAccount)
        try await fixture.pool.writeWithoutTransaction { db in
            _ = try Folder.filter(Column("id") == missing.id).deleteAll(db)
        }

        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member")
        let onOutlook = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-member")
        try await insert([onGmail, onOutlook], into: fixture.pool)
        let (absent, present) = missingAccount == "gmail1" ? (onGmail, onOutlook) : (onOutlook, onGmail)
        let presentDestination = fixture.destination(action, account: present.accountId)

        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        let skipped = await act(action, on: [onGmail.id, onOutlook.id], with: vm)
        #expect(skipped == [absent.id], "only the member with nowhere to go comes back on screen")
        #expect(AccountManager.shared.snapshotOverlay()[absent.id] == nil)

        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(try await folderId(of: absent.id, in: fixture.pool) == absent.folderId)
        #expect(try await folderId(of: present.id, in: fixture.pool) == presentDestination.id)
        #expect(try await queuedMoves(in: fixture.pool) == [
            [present.accountId, fixture.inbox(present.accountId).path, presentDestination.path, present.messageId],
        ])
    }

    @Test("when both accounts name the folder alike, a move write refused for one account leaves the other account's move in place and reports only the refused member, and Undo brings back the moved one")
    func refusedWriteOnOneAccountLeavesTheOther() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()
        // Both accounts call their archive folder "Archive".
        let gmailArchive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "gmail1")
        let outlookArchive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "outlook1")
        try await fixture.pool.writeWithoutTransaction { db in
            _ = try Folder.filter([fixture.gmailArchive.id, fixture.outlookArchive.id].contains(Column("id"))).deleteAll(db)
            try gmailArchive.insert(db)
            try outlookArchive.insert(db)
        }
        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member")
        let onOutlook = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-member")
        try await insert([onGmail, onOutlook], into: fixture.pool)
        // Only Gmail's move insert fails, so only a transaction holding it rolls back.
        try await fixture.pool.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER failGmailMoveInsert BEFORE INSERT ON \(PendingOperation.databaseTableName)
                WHEN NEW.type = '\(OperationType.move.rawValue)' AND NEW.accountId = 'gmail1'
                BEGIN SELECT RAISE(ABORT, 'test: Gmail move insert fails'); END
                """)
        }

        let tap = MoveRefusalTap(watching: [onGmail.id, onOutlook.id])
        defer { tap.stop() }
        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        #expect(vm.archiveThread([onGmail.id, onOutlook.id]).isEmpty)
        await AccountManager.shared.awaitWriteQueueDrain()

        #expect(tap.snapshot == [onGmail.id], "only the refused member is reported, so only its row is shown again")
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == outlookArchive.id,
                "the other account's move stands")
        #expect(try await queuedMoves(in: fixture.pool) == [
            ["outlook1", fixture.outlookInbox.path, outlookArchive.path, onOutlook.messageId],
        ])

        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == fixture.outlookInbox.id)
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
        #expect(try await queuedMoves(in: fixture.pool).isEmpty)
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
        #expect(try await queuedMoves(in: fixture.pool).isEmpty, "both queued moves are cancelled")
    }

    // MARK: - Undo notice

    @Test("an Undo that brings back one account's member and is refused for the other's says some messages were not moved back; refused for both, it says nothing was", arguments: [false, true])
    func undoNoticeSaysWhatCameBack(bothRefused: Bool) async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()

        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member")
        let onOutlook = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-member")
        try await insert([onGmail, onOutlook], into: fixture.pool)
        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        #expect(vm.archiveThread([onGmail.id, onOutlook.id]).isEmpty)
        await AccountManager.shared.awaitWriteQueueDrain()

        // Sync removed the archived Gmail row (and, in the second case, the
        // Outlook one) before the user asked for Undo.
        let gone = bothRefused ? [onGmail.id, onOutlook.id] : [onGmail.id]
        try await fixture.pool.writeWithoutTransaction { db in
            for id in gone { _ = try MessageHeader.deleteOne(db, key: id) }
        }

        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        if bothRefused {
            #expect(UndoService.shared.undoFailureMessage == UndoService.moveUndoRefusedMessage)
        } else {
            #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == fixture.outlookInbox.id,
                    "setup: the Outlook member is moved back")
            #expect(UndoService.shared.undoFailureMessage == UndoService.moveUndoPartlyRefusedMessage,
                    "a partial Undo must not say that nothing was moved back")
        }
    }

    // MARK: - Address changes and pruning across the parts of one entry

    @Test("a member of the entry's second account whose address changed when its move finished is followed, and Undo brings it back under its new address", arguments: RekeyMoment.allCases)
    func undoFollowsAnAddressChangeInALaterPart(moment: RekeyMoment) async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()

        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member")
        let onOutlook = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-member")
        try await insert([onGmail, onOutlook], into: fixture.pool)
        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        #expect(vm.archiveThread([onGmail.id, onOutlook.id]).isEmpty)
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.currentAction?.commands.map(\.accountId) == ["gmail1", "outlook1"],
                "setup: the Outlook member is in the entry's second part")

        // The Outlook move finished and its provider gave the message a new
        // id in the archive: the operation is gone and the row is re-keyed.
        let newMessageId = "outlook-member-in-archive"
        let newHeaderId = MessageIdentity.headerId(
            accountId: "outlook1", folderPath: fixture.outlookArchive.path, messageId: newMessageId)
        func finishOutlookMove() async throws {
            try await fixture.pool.writeWithoutTransaction { db in
                _ = try PendingOperation
                    .filter(Column("type") == OperationType.move.rawValue)
                    .filter(Column("accountId") == "outlook1")
                    .deleteAll(db)
                try db.execute(
                    sql: "UPDATE messageHeader SET id = ?, messageId = ? WHERE id = ?",
                    arguments: [newHeaderId, newMessageId, onOutlook.id])
            }
            UndoService.shared.applyRekeys([HeaderRekeyRecord(
                oldHeaderId: onOutlook.id, newHeaderId: newHeaderId,
                newProviderMessageId: newMessageId)])
        }

        switch moment {
        case .beforeUndo:
            try await finishOutlookMove()
            await UndoService.shared.undo()
        case .whileUndoIsQueued:
            let gate = await gateWriteQueue()
            await UndoService.shared.undo()
            try await finishOutlookMove()
            gate.finish()
        }
        await AccountManager.shared.awaitWriteQueueDrain()

        #expect(UndoService.shared.undoFailureMessage == nil, "Undo must not be refused")
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
        #expect(try await folderId(of: newHeaderId, in: fixture.pool) == fixture.outlookInbox.id,
                "the Outlook member comes back under the address its provider gave it")
        #expect(try await queuedMoves(in: fixture.pool) == [
            ["outlook1", fixture.outlookArchive.path, fixture.outlookInbox.path, newMessageId],
        ], "the finished Outlook move gets one reverse move naming its new address; the queued Gmail move is cancelled")
    }

    @Test("dropping the member of the entry's second part whose address cannot be followed keeps the first part, which Undo still brings back")
    func droppingOnePartKeepsTheOthers() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()

        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member")
        let onOutlook = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-member")
        try await insert([onGmail, onOutlook], into: fixture.pool)
        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        #expect(vm.archiveThread([onGmail.id, onOutlook.id]).isEmpty)
        await AccountManager.shared.awaitWriteQueueDrain()
        let offered = UndoService.shared.currentAction
        #expect(offered?.commands.map(\.accountId) == ["gmail1", "outlook1"],
                "setup: the Outlook member is in the entry's second part")

        UndoService.shared.discardMembers(namedByOldHeaderIds: [onOutlook.id])
        let kept = UndoService.shared.currentAction
        #expect(kept?.commands.map(\.accountId) == ["gmail1"], "only the Outlook part is dropped")
        #expect(kept?.commands.flatMap(\.members).map(\.originalHeaderId) == [onGmail.id])
        #expect(kept?.id != offered?.id, "the smaller entry is a different offer")

        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoFailureMessage == nil)
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == fixture.outlookArchive.id,
                "the dropped member stays where its move put it")
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
        let gate = await gateWriteQueue()
        let skipped = vm.moveThread(
            [onGmail.id, onOutlook.id], toFolderPath: fixture.outlookProjects.path,
            accountId: fixture.outlookProjects.accountId)
        #expect(skipped == [onGmail.id], "a message cannot move to another account's folder")
        let overlay = AccountManager.shared.snapshotOverlay()
        #expect(overlay[onGmail.id] == nil)
        #expect(overlay[onOutlook.id]?.folderId == fixture.outlookProjects.id)
        gate.finish()

        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == fixture.outlookProjects.id)
        #expect(try await queuedMoves(in: fixture.pool) == [
            ["outlook1", fixture.outlookInbox.path, fixture.outlookProjects.path, onOutlook.messageId],
        ])

        #expect(UndoService.shared.undoStack.count == 1)
        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoFailureMessage == nil, "Undo must not be refused")
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == fixture.outlookInbox.id)
        #expect(try await queuedMoves(in: fixture.pool).isEmpty)
    }

    @Test("moving a thread into a folder one of its members is already in leaves that member out: it is reported skipped and has no part in the Undo, which returns the moved member and queues no move for the other")
    func moveLeavesOutAMemberAlreadyThere() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()

        let inInbox = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-inbox-member")
        let inProjects = makeHeader(folder: fixture.outlookProjects, messageId: "outlook-projects-member")
        try await insert([inInbox, inProjects], into: fixture.pool)

        let vm = InboxViewModel(folders: [fixture.outlookInbox, fixture.outlookProjects])
        let skipped = vm.moveThread(
            [inInbox.id, inProjects.id], toFolderPath: fixture.outlookProjects.path,
            accountId: fixture.outlookProjects.accountId)
        #expect(skipped == [inProjects.id], "the member already in the folder is not moved")
        #expect(AccountManager.shared.snapshotOverlay()[inProjects.id] == nil)
        #expect(UndoService.shared.currentAction?.commands.flatMap(\.members).map(\.originalHeaderId) == [inInbox.id],
                "only the moved member has a part in the Undo")

        await AccountManager.shared.awaitWriteQueueDrain()
        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoFailureMessage == nil, "Undo must not be refused")
        #expect(try await folderId(of: inInbox.id, in: fixture.pool) == fixture.outlookInbox.id)
        #expect(try await folderId(of: inProjects.id, in: fixture.pool) == fixture.outlookProjects.id)
        #expect(try await queuedMoves(in: fixture.pool).isEmpty,
                "Undo cancels the queued move and queues no move for the member that never moved")
    }
}
