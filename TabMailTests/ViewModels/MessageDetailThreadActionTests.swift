/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The chat's whole-thread actions (S2.1, S3.1): Archive, Delete and Move act on every email the
/// chat shows, wherever it is filed (sent copies and drafts stay put), as ONE action — one undo
/// entry, never a loop of single-email actions — and one Undo puts each email back in its own
/// folder; and the read swipes set each email's read state.
@Suite("Detail view acts on a whole chat as one action", .serialized, .processGlobalState)
struct MessageDetailThreadActionTests {
    private static let inboxPath = "INBOX"
    private static let archivePath = "Archive"
    private static let trashPath = "Trash"
    private static let projectsPath = "Projects"
    private static let sentPath = "Sent"
    private static let draftsPath = "Drafts"

    @MainActor
    private func makeEnv() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
            try Folder(name: "INBOX", path: Self.inboxPath, role: .inbox, accountId: "acc1").insert(db)
            try Folder(name: "Archive", path: Self.archivePath, role: .archive, accountId: "acc1").insert(db)
            try Folder(name: "Trash", path: Self.trashPath, role: .trash, accountId: "acc1").insert(db)
            try Folder(name: "Projects", path: Self.projectsPath, role: .custom, accountId: "acc1").insert(db)
            try Folder(name: "Sent", path: Self.sentPath, role: .sent, accountId: "acc1").insert(db)
            try Folder(name: "Drafts", path: Self.draftsPath, role: .drafts, accountId: "acc1").insert(db)
        }
        return (pool, dir, previous)
    }

    @MainActor
    private func insertHeader(_ pool: DatabasePool, messageId: String, folderPath: String = inboxPath,
                              isRead: Bool = false) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "Test",
            from: "sender@example.com", fromAddress: "sender@example.com",
            to: "me@example.com", date: Date(timeIntervalSince1970: 1_800_000_000),
            snippet: "body",
            folderId: "acc1:\(folderPath)", accountId: "acc1",
            folderPath: folderPath, isInInbox: folderPath == Self.inboxPath
        )
        header.isRead = isRead
        header.headerComplete = true
        let seeded = header
        try pool.writeWithoutTransaction { try seeded.insert($0) }
        return seeded
    }

    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    @MainActor
    private func teardown(previous: AppDatabase?, pool: DatabasePool, dir: URL) {
        UserDefaults.standard.removeObject(forKey: AccountManager.markReadOnArchiveDeleteKey)
        UndoService.shared.dismissAll()
        clearOverlay()
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }

    private func drainWriteQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { await AccountManager.shared.enqueueWrite { cont.resume() } }
        }
    }

    /// Waits on the rows' FOLDER (bounded), then takes the write-queue barrier — see
    /// `MessageDetailMarkReadOnArchiveDeleteTests.settleMove` for why the barrier alone is not one.
    private func settle(_ pool: DatabasePool, ids: [String], in folderPath: String) async throws {
        for _ in 0..<400 {
            let landed = try await pool.read { db in
                try ids.allSatisfy { try MessageHeader.fetchOne(db, key: $0)?.folderPath == folderPath }
            }
            if landed { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await drainWriteQueue()
    }

    private func rows(_ pool: DatabasePool, _ ids: [String]) async throws -> [MessageHeader] {
        try await pool.read { db in try ids.compactMap { try MessageHeader.fetchOne(db, key: $0) } }
    }

    private func opsInDrainOrder(_ pool: DatabasePool) async throws -> [PendingOperation] {
        try await pool.read { db in try PendingOperation.order(Column("createdAt").asc).fetchAll(db) }
    }

    /// Opens the chat on `focused` with `others` as its thread.
    @MainActor
    private func openChat(_ pool: DatabasePool, focused: MessageHeader, others: [MessageHeader]) -> MessageDetailViewModel {
        let vm = MessageDetailViewModel(messageId: focused.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(focused)
        vm.threadMessages = others
        return vm
    }

    @Test("Archiving a chat archives every email as one undo entry and one queued move, and one undo brings them all back")
    @MainActor
    func archiveChatIsOneAction() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()
        UserDefaults.standard.set(true, forKey: AccountManager.markReadOnArchiveDeleteKey)

        let a = try insertHeader(pool, messageId: "chat-a")
        let b = try insertHeader(pool, messageId: "chat-b")
        let c = try insertHeader(pool, messageId: "chat-c")
        let ids = [a.id, b.id, c.id]
        let vm = openChat(pool, focused: c, others: [a, b])

        #expect(vm.archiveMessages([c, a, b]))

        #expect(UndoService.shared.undoStack.count == 1, "one undo entry for the whole chat")
        #expect(Set(UndoService.shared.undoStack.first?.messages.map(\.id) ?? []) == Set(ids))
        #expect(vm.threadMessages.allSatisfy { $0.folderPath == Self.archivePath && $0.isRead },
                "every card shows its new place and read at once")

        try await settle(pool, ids: ids, in: Self.archivePath)
        let archived = try await rows(pool, ids)
        #expect(archived.count == 3)
        #expect(archived.allSatisfy { $0.folderPath == Self.archivePath && $0.isRead })

        let ops = try await opsInDrainOrder(pool)
        #expect(ops.map(\.type) == [.markRead, .move], "one read op, then ONE move: \(ops.map(\.type.rawValue))")
        guard ops.count == 2 else { return }
        #expect(Set(ops[1].messageIds) == Set([a.messageId, b.messageId, c.messageId]),
                "the one move carries every email")

        await UndoService.shared.undo()
        try await settle(pool, ids: ids, in: Self.inboxPath)
        let restored = try await rows(pool, ids)
        #expect(restored.count == 3)
        #expect(restored.allSatisfy { $0.folderPath == Self.inboxPath }, "one undo restores the whole chat")
    }

    @Test("Deleting a chat moves every email to Trash as one undo entry and one queued move")
    @MainActor
    func deleteChatIsOneAction() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let a = try insertHeader(pool, messageId: "del-a", isRead: true)
        let b = try insertHeader(pool, messageId: "del-b", isRead: true)
        let vm = openChat(pool, focused: b, others: [a])

        #expect(vm.deleteMessages([b, a]))

        #expect(UndoService.shared.undoStack.count == 1)
        #expect(UndoService.shared.undoStack.first?.messages.count == 2)
        try await settle(pool, ids: [a.id, b.id], in: Self.trashPath)
        let deleted = try await rows(pool, [a.id, b.id])
        #expect(deleted.count == 2)
        #expect(deleted.allSatisfy { $0.folderPath == Self.trashPath })
        let moves = try await opsInDrainOrder(pool).filter { $0.type == .move }
        #expect(moves.count == 1)
        #expect(moves.first?.messageIds.count == 2)
    }

    /// Waits until each row is in its folder (bounded), then takes the write-queue barrier.
    private func settle(_ pool: DatabasePool, _ places: [String: String]) async throws {
        for _ in 0..<400 {
            let landed = try await pool.read { db in
                try places.allSatisfy { try MessageHeader.fetchOne(db, key: $0.key)?.folderPath == $0.value }
            }
            if landed { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await drainWriteQueue()
    }

    private func folders(_ pool: DatabasePool, _ ids: [String]) async throws -> [String: String] {
        try await pool.read { db in
            Dictionary(uniqueKeysWithValues: try ids.map { ($0, try MessageHeader.fetchOne(db, key: $0)?.folderPath ?? "<gone>") })
        }
    }

    /// A chat whose emails are filed in five places: the Inbox, Archive, a custom folder, Sent and Drafts.
    @MainActor
    private func mixedChat(_ pool: DatabasePool, _ tag: String) throws -> (all: [MessageHeader], sent: MessageHeader, draft: MessageHeader) {
        let inbox = try insertHeader(pool, messageId: "\(tag)-inbox")
        let archived = try insertHeader(pool, messageId: "\(tag)-archived", folderPath: Self.archivePath, isRead: true)
        let filed = try insertHeader(pool, messageId: "\(tag)-filed", folderPath: Self.projectsPath, isRead: true)
        let sent = try insertHeader(pool, messageId: "\(tag)-sent", folderPath: Self.sentPath, isRead: true)
        let draft = try insertHeader(pool, messageId: "\(tag)-draft", folderPath: Self.draftsPath, isRead: true)
        return ([inbox, archived, filed, sent, draft], sent, draft)
    }

    @Test("Deleting a chat filed in several folders deletes every email but sent copies and drafts, and one Undo puts each back in its own folder")
    @MainActor
    func deleteChatAcrossFolders() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let chat = try mixedChat(pool, "mixdel")
        let ids = chat.all.map(\.id)
        let before = try await folders(pool, ids)
        let vm = openChat(pool, focused: chat.all[0], others: Array(chat.all.dropFirst()))

        #expect(vm.deleteChat(chat.all))
        #expect(UndoService.shared.undoStack.count == 1, "one undo entry for the whole chat")

        var deleted = before
        for id in ids where id != chat.sent.id && id != chat.draft.id { deleted[id] = Self.trashPath }
        try await settle(pool, deleted)
        #expect(try await folders(pool, ids) == deleted, "every email but the sent copy and the draft is in Trash")

        await UndoService.shared.undo()
        try await settle(pool, before)
        #expect(try await folders(pool, ids) == before, "one Undo puts each email back where it was")
    }

    @Test("Archiving a chat filed in several folders archives the rest, and one Undo puts each back in its own folder")
    @MainActor
    func archiveChatAcrossFolders() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let chat = try mixedChat(pool, "mixarc")
        let ids = chat.all.map(\.id)
        let before = try await folders(pool, ids)
        let vm = openChat(pool, focused: chat.all[0], others: Array(chat.all.dropFirst()))

        #expect(vm.archiveChat(chat.all))
        #expect(UndoService.shared.undoStack.count == 1)

        var archived = before
        for id in ids where id != chat.sent.id && id != chat.draft.id { archived[id] = Self.archivePath }
        try await settle(pool, archived)
        #expect(try await folders(pool, ids) == archived)

        await UndoService.shared.undo()
        try await settle(pool, before)
        #expect(try await folders(pool, ids) == before)
    }

    @Test("Moving a chat filed in several folders moves every email but sent copies and drafts, and one Undo puts each back")
    @MainActor
    func moveChatAcrossFolders() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let chat = try mixedChat(pool, "mixmov")
        let ids = chat.all.map(\.id)
        let before = try await folders(pool, ids)
        let vm = openChat(pool, focused: chat.all[0], others: Array(chat.all.dropFirst()))

        #expect(vm.moveChat(chat.all, toFolderPath: Self.projectsPath))
        #expect(UndoService.shared.undoStack.count == 1)

        var moved = before
        for id in ids where id != chat.sent.id && id != chat.draft.id { moved[id] = Self.projectsPath }
        try await settle(pool, moved)
        #expect(try await folders(pool, ids) == moved)

        await UndoService.shared.undo()
        try await settle(pool, before)
        #expect(try await folders(pool, ids) == before)
    }

    enum TwoAccountAction: String, CaseIterable, Sendable {
        case archive, delete, move, moveWithNoSuchFolder
    }

    /// The other account files its Archive and Trash under other names, so a move that sent both
    /// emails to the opened account's folder names would leave the other email where it was.
    private static let otherArchivePath = "Other Archive"
    private static let otherTrashPath = "Other Trash"

    @Test("A chat with emails in two accounts moves each to its own account's folder; one Undo puts both back",
          arguments: TwoAccountAction.allCases)
    @MainActor
    func chatInTwoAccountsMovesEachInItsAccount(action: TwoAccountAction) async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()
        try await pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "other@example.com", displayName: "Other", provider: .gmail)
            acc.id = "acc2"
            try acc.insert(db)
            try Folder(name: "INBOX", path: Self.inboxPath, role: .inbox, accountId: "acc2").insert(db)
            try Folder(name: "Archive", path: Self.otherArchivePath, role: .archive, accountId: "acc2").insert(db)
            try Folder(name: "Trash", path: Self.otherTrashPath, role: .trash, accountId: "acc2").insert(db)
            if action == .move {
                try Folder(name: "Projects", path: Self.projectsPath, role: .custom, accountId: "acc2").insert(db)
            }
        }
        let opened = try insertHeader(pool, messageId: "two-acc-own")
        var other = MessageHeader(
            messageId: "two-acc-other", subject: "Test", from: "sender@example.com", fromAddress: "sender@example.com",
            to: "other@example.com", date: Date(), snippet: "body", folderId: "acc2:\(Self.inboxPath)",
            accountId: "acc2", folderPath: Self.inboxPath, isInInbox: true)
        other.headerComplete = true
        let seeded = other
        try await pool.writeWithoutTransaction { try seeded.insert($0) }
        let ids = [opened.id, other.id]
        let before = try await folders(pool, ids)
        let vm = openChat(pool, focused: opened, others: [other])

        var after = before
        switch action {
        case .archive:
            #expect(vm.archiveChat([opened, other]))
            after = [opened.id: Self.archivePath, other.id: Self.otherArchivePath]
        case .delete:
            #expect(vm.deleteChat([opened, other]))
            after = [opened.id: Self.trashPath, other.id: Self.otherTrashPath]
        case .move:
            #expect(vm.moveChat([opened, other], toFolderPath: Self.projectsPath))
            after = [opened.id: Self.projectsPath, other.id: Self.projectsPath]
        case .moveWithNoSuchFolder:
            #expect(vm.moveChat([opened, other], toFolderPath: Self.projectsPath))
            after[opened.id] = Self.projectsPath
        }
        #expect(UndoService.shared.undoStack.count == 1)
        try await settle(pool, after)
        #expect(try await folders(pool, ids) == after, "each email went to its own account's folder")

        await UndoService.shared.undo()
        try await settle(pool, before)
        #expect(try await folders(pool, ids) == before, "one Undo puts every email back")
    }

    @Test("A chat of only sent copies and drafts, or already all in Trash, records nothing")
    @MainActor
    func chatWithNothingToMove() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let sent = try insertHeader(pool, messageId: "only-sent", folderPath: Self.sentPath, isRead: true)
        let draft = try insertHeader(pool, messageId: "only-draft", folderPath: Self.draftsPath, isRead: true)
        let binned = try insertHeader(pool, messageId: "only-bin", folderPath: Self.trashPath, isRead: true)
        let vm = openChat(pool, focused: sent, others: [draft, binned])

        #expect(vm.archiveChat([sent, draft]) == false)
        #expect(vm.deleteChat([sent, draft, binned]) == false)
        #expect(vm.moveChat([sent, draft], toFolderPath: Self.projectsPath) == false)
        #expect(vm.archiveChat([]) == false)
        #expect(UndoService.shared.undoStack.isEmpty)
    }

    @Test("Moving a chat to a chosen folder moves every email as one action and leaves the read state alone")
    @MainActor
    func moveChatIsOneAction() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()
        UserDefaults.standard.set(true, forKey: AccountManager.markReadOnArchiveDeleteKey)

        let a = try insertHeader(pool, messageId: "move-a")
        let b = try insertHeader(pool, messageId: "move-b")
        let vm = openChat(pool, focused: b, others: [a])

        #expect(vm.moveMessages([b, a], toFolderPath: Self.projectsPath))

        #expect(UndoService.shared.undoStack.count == 1)
        #expect(UndoService.shared.undoStack.first?.messages.count == 2)
        #expect(vm.threadMessages.first?.folderPath == Self.projectsPath)
        #expect(vm.threadMessages.first?.isInInbox == false)
        try await settle(pool, ids: [a.id, b.id], in: Self.projectsPath)
        let moved = try await rows(pool, [a.id, b.id])
        #expect(moved.count == 2)
        #expect(moved.allSatisfy { $0.folderPath == Self.projectsPath && !$0.isRead },
                "a chosen-folder move is not in mark-read-on-archive/delete")
        let ops = try await opsInDrainOrder(pool)
        #expect(ops.map(\.type) == [.move])
    }

    @Test("Moving a chat into the Inbox relabels its cards as inbox mail")
    @MainActor
    func moveChatIntoInbox() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let a = try insertHeader(pool, messageId: "back-a", folderPath: Self.archivePath)
        let b = try insertHeader(pool, messageId: "back-b", folderPath: Self.archivePath)
        let vm = openChat(pool, focused: b, others: [a])

        #expect(vm.moveMessages([b, a], toFolderPath: Self.inboxPath))
        #expect(vm.threadMessages.first?.isInInbox == true)
        try await settle(pool, ids: [a.id, b.id], in: Self.inboxPath)
    }

    @Test("Archiving a chat already in Archive, or no emails, records nothing")
    @MainActor
    func archiveNoOps() throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let a = try insertHeader(pool, messageId: "done-a", folderPath: Self.archivePath)
        let b = try insertHeader(pool, messageId: "done-b", folderPath: Self.archivePath)
        let vm = openChat(pool, focused: b, others: [a])

        #expect(vm.archiveMessages([b, a]) == false)
        #expect(vm.archiveMessages([]) == false)
        #expect(vm.deleteMessages([]) == false)
        #expect(vm.moveMessages([], toFolderPath: Self.projectsPath) == false)
        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[a.id] == nil)
        #expect(vm.threadMessages.first?.folderPath == Self.archivePath)
    }

    @Test("Deleting a chat already in Trash records nothing")
    @MainActor
    func deleteFromTrashNoOp() throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let a = try insertHeader(pool, messageId: "bin-a", folderPath: Self.trashPath)
        let vm = openChat(pool, focused: a, others: [])

        #expect(vm.deleteMessages([a]) == false)
        #expect(UndoService.shared.undoStack.isEmpty)
    }

    @Test("setRead flips the opened email and thread cards on screen and durably, and skips emails already there")
    @MainActor
    func setReadMarksEachEmail() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()

        let a = try insertHeader(pool, messageId: "read-a", isRead: true)
        let b = try insertHeader(pool, messageId: "read-b", isRead: true)
        let c = try insertHeader(pool, messageId: "read-c", isRead: false)
        let vm = openChat(pool, focused: b, others: [a, c])

        vm.setRead([b, c, a], isRead: false)

        #expect(vm.message?.isRead == false, "the opened email shows unread at once")
        #expect(vm.threadMessages.allSatisfy { !$0.isRead }, "each thread card shows unread at once")
        await drainWriteQueue()
        for _ in 0..<400 {
            let done = try await rows(pool, [a.id, b.id]).allSatisfy { !$0.isRead }
            if done { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let stored = try await rows(pool, [a.id, b.id, c.id])
        #expect(stored.count == 3)
        #expect(stored.allSatisfy { !$0.isRead }, "the read state lands in the database")
        let reads = try await opsInDrainOrder(pool).filter { $0.type == .markUnread || $0.type == .markRead }
        #expect(Set(reads.flatMap(\.messageIds)) == Set([a.messageId, b.messageId]),
                "the already-unread email gets no op")
    }
}
