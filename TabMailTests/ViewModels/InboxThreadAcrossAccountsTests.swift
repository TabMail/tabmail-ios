/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Observation
import Synchronization
import Testing
import UIKit
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

    enum RefusedPart: String, CaseIterable, CustomTestStringConvertible {
        /// The entry's first part (Gmail) is refused; the second comes back.
        case first
        /// The first part comes back; the second (Outlook) is refused.
        case second
        case both
        var testDescription: String { rawValue }
    }

    enum ImapMove: String, CaseIterable, CustomTestStringConvertible {
        /// The IMAP move is still queued and was never attempted.
        case queued
        /// The executor has sent it; the server has not answered yet.
        case onTheWire
        var testDescription: String { rawValue }
    }

    /// The IMAP account's folder epochs and the member's UID before and after
    /// its move. Test data, named once.
    private static let imapInboxEpoch = 41
    private static let imapArchiveEpoch = 52
    private static let imapUid = "101"
    private static let imapUidInArchive = "901"

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

    /// Ends a refused Undo's notice the way the user does. The test host's
    /// RootView shows the notice as a "Couldn't undo" alert; clearing the notice
    /// in code while that alert is still appearing can leave the alert up in the
    /// host's window, where a later suite's alert checks find it. So this waits
    /// for the alert to finish appearing and dismisses it through UIKit, as its
    /// OK does, which ends the notice; then it waits for both to be gone. With
    /// no alert up (no active scene), it ends the notice in code.
    private func dismissUndoFailureAlert() async {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        func presentedAlert() -> UIAlertController? {
            var controller = window?.rootViewController?.presentedViewController
            while let current = controller {
                if let alert = current as? UIAlertController, alert.title == "Couldn't undo" { return alert }
                controller = current.presentedViewController
            }
            return nil
        }
        func eventually(_ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(5)
            while !condition() {
                if Date() >= end { return false }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return true
        }
        let up = await eventually { presentedAlert().map { !$0.isBeingPresented } ?? false }
        if up, let alert = presentedAlert() {
            alert.dismiss(animated: false)
        } else {
            UndoService.shared.dismissUndoFailure()
        }
        let gone = await eventually { UndoService.shared.undoFailureMessage == nil && presentedAlert() == nil }
        #expect(gone, "control: the notice and its alert are gone before the next step")
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

    /// Every acted-on member's on-screen state and its hold are gone once the
    /// writes that took them have run: the list shows the database again.
    private func expectOverlayReleased(
        _ ids: [String], after phase: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let overlay = AccountManager.shared.snapshotOverlay()
        let retains = AccountManager.shared.overlayOpRefCountForTesting()
        for id in ids {
            #expect(overlay[id] == nil, "\(id) still shows what \(phase) gave it", sourceLocation: sourceLocation)
            #expect(retains[id] == nil, "\(id) is still held after \(phase)", sourceLocation: sourceLocation)
        }
    }

    private func folder(
        _ name: String, path: String, role: FolderRole, account: String, epoch: Int
    ) -> Folder {
        var folder = Folder(name: name, path: path, role: role, accountId: account)
        folder.lastKnownUidValidity = epoch
        return folder
    }

    /// A third account, on IMAP: its addresses carry a folder epoch, which
    /// its queued moves name and its Undo must give back.
    private func addImapAccount(to fixture: Fixture) async throws -> (inbox: Folder, archive: Folder) {
        let inbox = folder("INBOX", path: "INBOX", role: .inbox, account: "imap1", epoch: Self.imapInboxEpoch)
        let archive = folder("Archive", path: "Archive", role: .archive, account: "imap1", epoch: Self.imapArchiveEpoch)
        try await fixture.pool.writeWithoutTransaction { db in
            var account = Account(emailAddress: "third@example.com", displayName: "Third", provider: .imap)
            account.id = "imap1"
            try account.insert(db)
            try inbox.insert(db)
            try archive.insert(db)
        }
        return (inbox, archive)
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
        expectOverlayReleased([onGmail.id, onOutlook.id], after: "the forward moves")

        #expect(UndoService.shared.undoStack.count == 1, "the whole thread is one undo entry")
        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoFailureMessage == nil, "Undo must not be refused")
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == fixture.outlookInbox.id)
        #expect(try await operations(in: fixture.pool).map(\.id) == [unrelated.id],
                "Undo cancels exactly the thread's own queued moves and queues no reverse move")
        expectOverlayReleased([onGmail.id, onOutlook.id], after: "Undo")
    }

    @Test("archiving or deleting a thread of unread, tagged members on two accounts shows each one in its own folder, untagged, and read only when that setting is on, before its write runs; an Undo after the moves shows every member back in its own inbox with its tag, in one notice naming them all, before its writes run, and brings the tags back", arguments: RoleAction.allCases, [true, false])
    func eachMemberShowsAtOnceBothWays(action: RoleAction, markRead: Bool) async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()
        UserDefaults.standard.set(markRead, forKey: AccountManager.markReadOnArchiveDeleteKey)

        var onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member", isRead: false)
        onGmail.actionTag = .reply
        var onOutlook = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-member", isRead: false)
        onOutlook.actionTag = .archive
        let members = [onGmail, onOutlook]
        try await insert(members, into: fixture.pool)
        let memberIds = members.map(\.id)
        let expectedRead: Bool? = markRead ? true : nil
        let cleared: ActionTag?? = .some(nil)

        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        let forwardGate = await gateWriteQueue()
        let skipped = await act(action, on: memberIds, with: vm)
        #expect(skipped.isEmpty, "both members are acted on: \(skipped)")
        let shown = AccountManager.shared.snapshotOverlay()
        for member in members {
            let destination = fixture.destination(action, account: member.accountId)
            #expect(shown[member.id]?.folderId == destination.id, "\(member.messageId) shows in \(destination.path)")
            #expect(shown[member.id]?.isRead == expectedRead,
                    "\(member.messageId) shows read exactly when the setting is on")
            #expect(shown[member.id]?.actionTag == cleared,
                    "\(member.messageId) shows without its tag once it leaves the inbox")
        }
        forwardGate.finish()
        await AccountManager.shared.awaitWriteQueueDrain()

        for member in members {
            let row = try await header(member.id, in: fixture.pool)
            #expect(row?.folderId == fixture.destination(action, account: member.accountId).id)
            #expect(row?.isRead == markRead, "\(member.messageId) is read in the database exactly when the setting is on")
            #expect(row?.actionTag == nil, "\(member.messageId) loses its tag as it leaves the inbox")
        }
        expectOverlayReleased(memberIds, after: "the forward moves")

        // Undo once the moves are done: what it shows comes before its writes.
        let undone = UndoneTap()
        defer { undone.stop() }
        let undoGate = await gateWriteQueue()
        await UndoService.shared.undo()
        let notices = undone.snapshot
        #expect(notices == [memberIds], "one notice to the list names the members of every part")
        let back = AccountManager.shared.snapshotOverlay()
        for member in members {
            let restoredTag: ActionTag?? = .some(member.actionTag)
            #expect(back[member.id]?.folderId == member.folderId, "\(member.messageId) shows back in its own inbox")
            #expect(back[member.id]?.folderPath == member.folderPath)
            #expect(back[member.id]?.isInInbox == true)
            #expect(back[member.id]?.actionTag == restoredTag, "\(member.messageId) shows its tag again")
            let stored = try await folderId(of: member.id, in: fixture.pool)
            #expect(stored == fixture.destination(action, account: member.accountId).id,
                    "setup: \(member.messageId)'s Undo write has not run yet")
        }
        undoGate.finish()
        await AccountManager.shared.awaitWriteQueueDrain()

        #expect(UndoService.shared.undoFailureMessage == nil, "Undo must not be refused")
        for member in members {
            let row = try await header(member.id, in: fixture.pool)
            #expect(row?.folderId == member.folderId)
            #expect(row?.actionTag == member.actionTag, "Undo brings back \(member.messageId)'s tag")
            #expect(row?.isRead == markRead, "Undo leaves the read state as it is")
        }
        expectOverlayReleased(memberIds, after: "Undo")
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

        let queued = try await operations(in: fixture.pool)
        let reads = queued.filter { $0.type == .markRead }
        let readPayloads = Set(reads.map { [$0.accountId, $0.folderPath] + $0.messageIds.sorted() })
        #expect(readPayloads == [
            ["gmail1", fixture.gmailInbox.path, onGmail.messageId],
            ["outlook1", fixture.outlookInbox.path, onOutlook.messageId],
        ], "one read per account, in its SOURCE folder, naming only its acted-on member")
        for account in ["gmail1", "outlook1"] {
            let read = reads.first { $0.accountId == account }
            let move = queued.first { $0.type == .move && $0.accountId == account }
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

    @Test("archiving or deleting a thread across two accounts when one account's read write is refused keeps the other account's read, which still comes before its move", arguments: RoleAction.allCases)
    func refusedReadOnOneAccountLeavesTheOthersRead(action: RoleAction) async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()
        UserDefaults.standard.set(true, forKey: AccountManager.markReadOnArchiveDeleteKey)

        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member", isRead: false)
        let onOutlook = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-member", isRead: false)
        try await insert([onGmail, onOutlook], into: fixture.pool)
        // Only Gmail's read insert fails, so only a transaction holding it rolls back.
        try await fixture.pool.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER failGmailReadInsert BEFORE INSERT ON \(PendingOperation.databaseTableName)
                WHEN NEW.type = '\(OperationType.markRead.rawValue)' AND NEW.accountId = 'gmail1'
                BEGIN SELECT RAISE(ABORT, 'test: Gmail read insert fails'); END
                """)
        }

        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        let skipped = await act(action, on: [onGmail.id, onOutlook.id], with: vm)
        #expect(skipped.isEmpty)
        await AccountManager.shared.awaitWriteQueueDrain()

        let queued = try await operations(in: fixture.pool)
        let reads = queued.filter { $0.type == .markRead }
        let readPayloads = reads.map { [$0.accountId, $0.folderPath] + $0.messageIds.sorted() }
        #expect(readPayloads == [["outlook1", fixture.outlookInbox.path, onOutlook.messageId]],
                "Gmail's refused read must not take the Outlook read with it")
        #expect(try await header(onOutlook.id, in: fixture.pool)?.isRead == true,
                "the Outlook member is read in the database")
        let outlookMove = queued.first { $0.type == .move && $0.accountId == "outlook1" }
        #expect(reads.count == 1 && outlookMove != nil, "Outlook has its read and its move")
        if let read = reads.first, let outlookMove {
            #expect(read.queuePosition < outlookMove.queuePosition,
                    "Outlook's read is claimed before its move")
        }
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

    @Test("a thread member already in another folder of the action's kind (a second archive or trash folder of its account) is reported skipped like one in the main folder, while the member in the inbox still goes, and Undo brings it back", arguments: RoleAction.allCases)
    func memberInAnotherFolderOfTheKindIsSkipped(action: RoleAction) async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()
        let usual = fixture.destination(action, account: "outlook1")
        let other = Folder(
            name: "Old \(usual.name)", path: "\(usual.path)-old",
            role: action == .archive ? .archive : .trash, accountId: "outlook1")
        try await fixture.pool.writeWithoutTransaction { db in try other.insert(db) }

        let inInbox = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-inbox-member")
        let inUsual = makeHeader(folder: usual, messageId: "outlook-usual-member")
        let inOther = makeHeader(folder: other, messageId: "outlook-other-member")
        try await insert([inInbox, inUsual, inOther], into: fixture.pool)

        let vm = InboxViewModel(folders: [fixture.outlookInbox])
        let skipped = await act(action, on: [inInbox.id, inUsual.id, inOther.id], with: vm)
        #expect(skipped == [inUsual.id, inOther.id],
                "a member already in a folder of that kind stays, whichever of the two it is")
        await AccountManager.shared.awaitWriteQueueDrain()

        // The account has two folders of the kind; the inbox member goes to
        // the one its account's lookup names, whichever that is.
        let landed = try await header(inInbox.id, in: fixture.pool)?.folderPath
        #expect(landed == usual.path || landed == other.path, "the inbox member went: \(landed ?? "nowhere")")
        #expect(try await queuedMoves(in: fixture.pool) == [
            ["outlook1", fixture.outlookInbox.path, landed ?? "<none>", inInbox.messageId],
        ], "only the inbox member is moved")
        #expect(try await folderId(of: inUsual.id, in: fixture.pool) == usual.id)
        #expect(try await folderId(of: inOther.id, in: fixture.pool) == other.id)

        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoFailureMessage == nil, "Undo must not be refused")
        #expect(try await folderId(of: inInbox.id, in: fixture.pool) == fixture.outlookInbox.id)
        #expect(try await queuedMoves(in: fixture.pool).isEmpty)
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
        expectOverlayReleased([onGmail.id, onOutlook.id], after: "the forward moves")

        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == fixture.outlookInbox.id)
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
        #expect(try await queuedMoves(in: fixture.pool).isEmpty)
        expectOverlayReleased([onGmail.id, onOutlook.id], after: "Undo")
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

    @Test("an Undo refused for some parts of a thread entry says so once, after its last part ran: some messages were not moved back when another part came back, in either order, and nothing was moved back when none did", arguments: RefusedPart.allCases)
    func undoNoticeSaysWhatCameBack(refused: RefusedPart) async throws {
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
                "setup: Gmail's part runs first, Outlook's last")

        // Sync removed the archived rows of the refused parts before the user
        // asked for Undo.
        let gone: [String] = switch refused {
        case .first: [onGmail.id]
        case .second: [onOutlook.id]
        case .both: [onGmail.id, onOutlook.id]
        }
        try await fixture.pool.writeWithoutTransaction { db in
            for id in gone { _ = try MessageHeader.deleteOne(db, key: id) }
        }

        let pool = fixture.pool
        let outlookId = onOutlook.id
        let outlookInboxId = fixture.outlookInbox.id
        let probe = UndoNoticeProbe(lastPartIds: [outlookId]) {
            (try? pool.read { db in try MessageHeader.fetchOne(db, key: outlookId)?.folderId }) == outlookInboxId
        }
        defer { probe.stop() }
        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()

        let lastPartHadRun = probe.lastPartHadRunAtFirstNotice
        #expect(lastPartHadRun == true,
                "the notice is decided once, after the entry's last part ran, never after an earlier part")
        switch refused {
        case .first:
            #expect(try await folderId(of: onOutlook.id, in: fixture.pool) == fixture.outlookInbox.id,
                    "setup: the Outlook member is moved back")
            #expect(UndoService.shared.undoFailureMessage == "Some messages were not moved back.",
                    "a partial Undo must not say that nothing was moved back")
        case .second:
            #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id,
                    "setup: the Gmail member is moved back")
            #expect(UndoService.shared.undoFailureMessage == "Some messages were not moved back.",
                    "a part that came back before the refused one still counts")
        case .both:
            #expect(UndoService.shared.undoFailureMessage == "Nothing was moved back.")
        }
        await dismissUndoFailureAlert()
    }

    @Test("each Undo's notice is decided by that entry alone: a partly refused Undo says some messages were not moved back, the next one, which brings everything back, says nothing, and the one after, which brings nothing back, says nothing was moved back")
    func undoNoticeIsDecidedPerEntry() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()

        // Three threads across both accounts, one entry each. Undo takes the
        // newest first: the partly refused one, then the one that comes back
        // whole, then the one that does not come back at all.
        let threads = ["refused", "whole", "partly"].map { name in
            [makeHeader(folder: fixture.gmailInbox, messageId: "\(name)-gmail"),
             makeHeader(folder: fixture.outlookInbox, messageId: "\(name)-outlook")]
        }
        let (refused, whole, partly) = (threads[0], threads[1], threads[2])
        try await insert(threads.flatMap { $0 }, into: fixture.pool)
        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        for thread in threads {
            let skipped = vm.archiveThread(thread.map(\.id))
            #expect(skipped.isEmpty, "setup: the whole thread is archived: \(skipped)")
        }
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoStack.count == 3, "setup: one entry per thread")
        // Sync removed the archived rows that cannot come back: the partly
        // refused entry's Gmail member and both members of the last one.
        let gone = [partly[0].id] + refused.map(\.id)
        try await fixture.pool.writeWithoutTransaction { db in
            for id in gone { _ = try MessageHeader.deleteOne(db, key: id) }
        }

        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        let partlyBack = try await folderId(of: partly[1].id, in: fixture.pool)
        #expect(partlyBack == fixture.outlookInbox.id, "setup: the partly refused entry's Outlook member is back")
        #expect(UndoService.shared.undoFailureMessage == "Some messages were not moved back.")
        await dismissUndoFailureAlert()

        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        for member in whole {
            let back = try await folderId(of: member.id, in: fixture.pool)
            #expect(back == member.folderId, "setup: \(member.messageId) is back")
        }
        #expect(UndoService.shared.undoFailureMessage == nil,
                "an Undo that brought everything back says nothing, whatever the one before it refused")

        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoFailureMessage == "Nothing was moved back.",
                "an Undo that brought nothing back says so, whatever the ones before it brought back")
        #expect(UndoService.shared.undoStack.isEmpty)
        await dismissUndoFailureAlert()
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
            UndoService.shared.applyRekeys(MailPointerMoves([.row(HeaderRekeyRecord(
                oldHeaderId: onOutlook.id, newHeaderId: newHeaderId,
                newProviderMessageId: newMessageId))]))
        }

        switch moment {
        case .beforeUndo:
            try await finishOutlookMove()
            // The entry's message list (it keeps an undoable message's body
            // from storage pruning) names the new address too.
            let listed = Set(UndoService.shared.currentAction?.messages.map(\.id) ?? [])
            #expect(listed == [onGmail.id, newHeaderId],
                    "the entry's message list follows the address change")
            await UndoService.shared.undo()
        case .whileUndoIsQueued:
            let gate = await gateWriteQueue()
            await UndoService.shared.undo()
            // Release and drain the shared queue on every exit: a throw here
            // must not leave it held when the fixture is taken down.
            var finishError: (any Error)?
            do { try await finishOutlookMove() } catch { finishError = error }
            gate.finish()
            await AccountManager.shared.awaitWriteQueueDrain()
            if let finishError { throw finishError }
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

    @Test("Undo of a thread whose second part is an IMAP member cancels that member's queued move and gives back its folder epoch, or, when its move is already on the wire, queues one reverse move naming the address the server gave it; the Gmail part is cancelled either way", arguments: ImapMove.allCases)
    func undoBringsBackAnImapMemberOfALaterPart(imapMove: ImapMove) async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        defer { MessageHeaderRekey.clearAddressHandoffsForTesting() }
        clearSharedState()
        MessageHeaderRekey.clearAddressHandoffsForTesting()
        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()
        let imap = try await addImapAccount(to: fixture)

        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member")
        var onImap = makeHeader(folder: imap.inbox, messageId: Self.imapUid)
        onImap.observedUidValidity = Self.imapInboxEpoch
        onImap.rfc822MessageId = "imap-member@example.com"
        try await insert([onGmail, onImap], into: fixture.pool)

        let vm = InboxViewModel(folders: [fixture.gmailInbox, imap.inbox])
        #expect(vm.archiveThread([onGmail.id, onImap.id]).isEmpty)
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.currentAction?.commands.map(\.accountId) == ["gmail1", "imap1"],
                "setup: the IMAP member is in the entry's second part")
        let imapMoves = try await operations(in: fixture.pool).filter { $0.type == .move && $0.accountId == "imap1" }
        #expect(imapMoves.map(\.observedUidValidity) == [Self.imapInboxEpoch],
                "setup: the IMAP move names the epoch of its source folder")
        guard imapMoves.count == 1 else { return }

        let imapForward: PendingOperation
        switch imapMove {
        case .queued:
            imapForward = imapMoves[0]
        case .onTheWire:
            let forwardId = imapMoves[0].id
            let claimed = try await fixture.pool.write { db -> PendingOperation? in
                _ = try PendingOperation.filter(Column("id") == forwardId).updateAll(
                    db,
                    Column("status").set(to: PendingStatus.inFlight.rawValue),
                    Column("everAttempted").set(to: true))
                return try PendingOperation.fetchOne(db, key: forwardId)
            }
            imapForward = try #require(claimed)
        }

        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoFailureMessage == nil, "Undo must not be refused")
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)

        switch imapMove {
        case .queued:
            let row = try await header(onImap.id, in: fixture.pool)
            #expect(row?.folderId == imap.inbox.id)
            #expect(row?.observedUidValidity == Self.imapInboxEpoch,
                    "the cancelled move gives back the epoch the member's address was proven under")
            #expect(try await operations(in: fixture.pool).isEmpty, "both queued moves are cancelled")
        case .onTheWire:
            #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 1,
                    "setup: the IMAP part waits for the address its move is given")
            // The server finished the move and named the message's new UID.
            // Built here: the suite's statics belong to the main actor, which
            // the database writer's closure does not run on.
            let proven = ProvenDestinationAddress(
                sourceProviderId: Self.imapUid,
                destinationProviderId: Self.imapUidInArchive,
                destinationUidValidity: UInt32(Self.imapArchiveEpoch))
            let finished = try await fixture.pool.write { db in
                let result = try MessageHeaderRekey.finishMove(
                    imapForward,
                    destinations: [proven],
                    addressChangesOnMove: true,
                    accountScopedIds: false,
                    copiedNothing: false,
                    db: db)
                _ = try PendingOperation.deleteOne(db, key: imapForward.id)
                MessageHeaderRekey.publishAddressHandoffsAfterCommit(result.applied, in: db)
                return result
            }
            await AccountManager.shared.materializeDeferredMoveSuccessors(after: imapForward, result: finished)
            await AccountManager.shared.awaitWriteQueueDrain()

            let newHeaderId = MessageIdentity.headerId(
                accountId: "imap1", folderPath: imap.archive.path, messageId: Self.imapUidInArchive)
            #expect(try await header(newHeaderId, in: fixture.pool)?.folderPath == imap.inbox.path,
                    "the IMAP member shows back in its inbox under its new address")
            let remaining = try await operations(in: fixture.pool)
            let remainingPayloads = remaining.map {
                [$0.accountId, $0.folderPath, $0.destinationPath ?? "<nil>"] + $0.messageIds
            }
            #expect(remainingPayloads == [
                ["imap1", imap.archive.path, imap.inbox.path, Self.imapUidInArchive],
            ], "one reverse move naming the UID the server gave; the queued Gmail move is cancelled")
            #expect(remaining.map(\.observedUidValidity) == [Self.imapArchiveEpoch])
            #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 0)
        }
        expectOverlayReleased([onGmail.id, onImap.id], after: "Undo")
    }

    // MARK: - Move

    @Test("moving a thread whose members are on two accounts moves only the members of the account whose folder was picked, from each folder they are in, even when the other account has a folder of the same name; the other member is reported skipped and left where it is, and one Undo returns each moved member to its own folder")
    func moveActsOnlyOnThePickedAccount() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        clearSharedState()
        // The other account has a folder of the same name: a message still
        // cannot move between accounts.
        let gmailProjects = Folder(
            name: "Projects", path: fixture.outlookProjects.path, role: .custom, accountId: "gmail1")
        try await fixture.pool.writeWithoutTransaction { db in try gmailProjects.insert(db) }

        let onGmail = makeHeader(folder: fixture.gmailInbox, messageId: "gmail-member")
        let inInbox = makeHeader(folder: fixture.outlookInbox, messageId: "outlook-inbox-member")
        let inArchive = makeHeader(folder: fixture.outlookArchive, messageId: "outlook-archive-member")
        try await insert([onGmail, inInbox, inArchive], into: fixture.pool)

        let vm = InboxViewModel(folders: [fixture.gmailInbox, fixture.outlookInbox])
        let gate = await gateWriteQueue()
        let skipped = vm.moveThread(
            [onGmail.id, inInbox.id, inArchive.id], toFolderPath: fixture.outlookProjects.path,
            accountId: fixture.outlookProjects.accountId)
        #expect(skipped == [onGmail.id], "a message cannot move to another account's folder")
        let overlay = AccountManager.shared.snapshotOverlay()
        #expect(overlay[onGmail.id] == nil)
        #expect(overlay[inInbox.id]?.folderId == fixture.outlookProjects.id)
        #expect(overlay[inArchive.id]?.folderId == fixture.outlookProjects.id)
        gate.finish()

        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
        #expect(try await folderId(of: inInbox.id, in: fixture.pool) == fixture.outlookProjects.id)
        #expect(try await folderId(of: inArchive.id, in: fixture.pool) == fixture.outlookProjects.id)
        #expect(try await queuedMoves(in: fixture.pool) == [
            ["outlook1", fixture.outlookArchive.path, fixture.outlookProjects.path, inArchive.messageId],
            ["outlook1", fixture.outlookInbox.path, fixture.outlookProjects.path, inInbox.messageId],
        ], "one move per source folder, each naming the picked account's folder, none for the Gmail member")
        expectOverlayReleased([inInbox.id, inArchive.id], after: "the forward moves")

        #expect(UndoService.shared.undoStack.count == 1)
        await UndoService.shared.undo()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(UndoService.shared.undoFailureMessage == nil, "Undo must not be refused")
        #expect(try await folderId(of: inInbox.id, in: fixture.pool) == fixture.outlookInbox.id)
        #expect(try await folderId(of: inArchive.id, in: fixture.pool) == fixture.outlookArchive.id)
        #expect(try await folderId(of: onGmail.id, in: fixture.pool) == fixture.gmailInbox.id)
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

/// Records the ids each `.messagesUndone` notice names, in order: the list
/// puts back every row a notice names (`InboxView`), so one Undo must name the
/// members of all its parts.
private final class UndoneTap: @unchecked Sendable {
    private let received = Mutex<[[String]]>([])
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .messagesUndone, object: nil, queue: nil
        ) { [self] notification in
            let ids = notification.object as? [String] ?? []
            received.withLock { $0.append(ids) }
        }
    }

    var snapshot: [[String]] { received.withLock { $0 } }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// Watches one Undo of an entry with several parts and records, at the moment
/// the Undo notice is FIRST about to change, whether the entry's last part had
/// already run. A refused part posts `.inboxDataDidChange` naming its members
/// before it is counted; a part that came back shows in the database
/// (`lastPartIsBack`). Observation calls `onChange` synchronously, before the
/// new value is set, on the actor that sets it.
private final class UndoNoticeProbe: @unchecked Sendable {
    private let lastPartRefused = Mutex(false)
    private let firstNotice = Mutex<Bool?>(nil)
    private let lastPartIsBack: @Sendable () -> Bool
    private var observer: NSObjectProtocol?

    @MainActor
    init(lastPartIds: [String], lastPartIsBack: @escaping @Sendable () -> Bool) {
        self.lastPartIsBack = lastPartIsBack
        observer = NotificationCenter.default.addObserver(
            forName: .inboxDataDidChange, object: nil, queue: nil
        ) { [self] notification in
            guard notification.object as? [String] == lastPartIds else { return }
            lastPartRefused.withLock { $0 = true }
        }
        withObservationTracking {
            _ = UndoService.shared.undoFailureMessage
        } onChange: { [self] in
            let lastPartRan = lastPartRefused.withLock { $0 } || self.lastPartIsBack()
            firstNotice.withLock { recorded in
                if recorded == nil { recorded = lastPartRan }
            }
        }
    }

    /// Whether the entry's last part had run when the notice first changed;
    /// `nil` when the notice never changed.
    var lastPartHadRunAtFirstNotice: Bool? { firstNotice.withLock { $0 } }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
