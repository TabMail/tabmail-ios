/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The chat's whole-thread actions, as ONE action — one undo entry, never a loop of single-email
/// actions — where one Undo puts each email back in its own folder: Archive takes the chat's Inbox
/// copies, Move the copies in the folder the chat was opened from, and Delete every email (sent
/// copies and drafts stay put); and the read swipes set each email's read state.
@Suite("Detail view acts on a whole chat as one action", .serialized, .processGlobalState)
struct MessageDetailThreadActionTests {
    private static let inboxPath = "INBOX"
    /// One date for every seeded email, taken from today: the emails of a chat tie on date as before,
    /// and no test depends on a fixed calendar day.
    private static let seededDate = Date()
    private static let archivePath = "Archive"
    private static let trashPath = "Trash"
    private static let projectsPath = "Projects"
    private static let clientsPath = "Clients"
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
            try Folder(name: "Clients", path: Self.clientsPath, role: .custom, accountId: "acc1").insert(db)
            try Folder(name: "Sent", path: Self.sentPath, role: .sent, accountId: "acc1").insert(db)
            try Folder(name: "Drafts", path: Self.draftsPath, role: .drafts, accountId: "acc1").insert(db)
        }
        return (pool, dir, previous)
    }

    @MainActor
    private func insertHeader(_ pool: DatabasePool, messageId: String, folderPath: String = inboxPath,
                              isRead: Bool = false, accountId: String = "acc1",
                              observedUidValidity: Int? = nil) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "Test",
            from: "sender@example.com", fromAddress: "sender@example.com",
            to: "me@example.com", date: Self.seededDate,
            snippet: "body",
            folderId: "\(accountId):\(folderPath)", accountId: accountId,
            folderPath: folderPath, isInInbox: folderPath == Self.inboxPath
        )
        header.isRead = isRead
        header.headerComplete = true
        header.observedUidValidity = observedUidValidity
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

    @Test("A chat's Archive or Delete uses the mark-as-read setting as it was when the action started, even if it changes before the queued work runs",
          arguments: [true, false], [true, false])
    @MainActor
    func markReadSettingIsTheOneAtTheStart(archive: Bool, onAtStart: Bool) async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()
        UserDefaults.standard.set(onAtStart, forKey: AccountManager.markReadOnArchiveDeleteKey)

        // Two source folders, so the action queues one move per folder.
        let a = try insertHeader(pool, messageId: "snap-a")
        let b = try insertHeader(pool, messageId: "snap-b", folderPath: Self.projectsPath)
        let ids = [a.id, b.id]
        let vm = openChat(pool, focused: b, others: [a])

        // Hold the write queue so the action's queued work runs only after the setting changes.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        defer { gate.finish() }
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        // Archive takes the Inbox email; Delete takes both.
        let moved = archive ? [a.id] : ids
        #expect(!(archive ? vm.archiveChat([b, a]) : vm.deleteChat([b, a])).isEmpty)
        #expect(vm.threadMessages.first?.isRead == onAtStart, "the card shows the setting as it was at the start")
        UserDefaults.standard.set(!onAtStart, forKey: AccountManager.markReadOnArchiveDeleteKey)
        gate.finish()

        let destination = archive ? Self.archivePath : Self.trashPath
        try await settle(pool, ids: moved, in: destination)
        let done = try await rows(pool, moved)
        #expect(done.count == moved.count)
        #expect(done.allSatisfy { $0.folderPath == destination && $0.isRead == onAtStart },
                "every email's read state follows the setting as it was when the action started")
        let reads = try await opsInDrainOrder(pool).filter { $0.type == .markRead }
        #expect(reads.isEmpty == !onAtStart)
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
    private func mixedChat(_ pool: DatabasePool, _ tag: String) throws
        -> (all: [MessageHeader], inbox: MessageHeader, archived: MessageHeader, filed: MessageHeader,
            sent: MessageHeader, draft: MessageHeader) {
        let inbox = try insertHeader(pool, messageId: "\(tag)-inbox")
        let archived = try insertHeader(pool, messageId: "\(tag)-archived", folderPath: Self.archivePath, isRead: true)
        let filed = try insertHeader(pool, messageId: "\(tag)-filed", folderPath: Self.projectsPath, isRead: true)
        let sent = try insertHeader(pool, messageId: "\(tag)-sent", folderPath: Self.sentPath, isRead: true)
        let draft = try insertHeader(pool, messageId: "\(tag)-draft", folderPath: Self.draftsPath, isRead: true)
        return ([inbox, archived, filed, sent, draft], inbox, archived, filed, sent, draft)
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

        #expect(!vm.deleteChat(chat.all).isEmpty)
        #expect(UndoService.shared.undoStack.count == 1, "one undo entry for the whole chat")

        var deleted = before
        for id in ids where id != chat.sent.id && id != chat.draft.id { deleted[id] = Self.trashPath }
        try await settle(pool, deleted)
        #expect(try await folders(pool, ids) == deleted, "every email but the sent copy and the draft is in Trash")

        await UndoService.shared.undo()
        try await settle(pool, before)
        #expect(try await folders(pool, ids) == before, "one Undo puts each email back where it was")
    }

    @Test("Archiving a chat filed in several folders archives its Inbox email and leaves the filed ones where they are, and one Undo puts it back")
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

        #expect(vm.archiveChat(chat.all) == [chat.inbox.id], "Archive takes only the Inbox email")
        #expect(UndoService.shared.undoStack.count == 1)

        var archived = before
        archived[chat.inbox.id] = Self.archivePath
        try await settle(pool, archived)
        #expect(try await folders(pool, ids) == archived)

        await UndoService.shared.undo()
        try await settle(pool, before)
        #expect(try await folders(pool, ids) == before)
    }

    /// Undo moves a command's members back to ONE source under ONE epoch (`AccountManager.undoMove`
    /// refuses a mixed command), so one folder's emails seen under different epochs must undo as
    /// one command each. On IMAP an email whose epoch is not known yet is not moved (an unknown
    /// epoch is an absence of evidence, retried later) while its stamped neighbour is; grouping by
    /// folder alone puts both in one command, Undo refuses it, and the moved email stays archived.
    @Test("Archiving a chat whose Inbox emails were seen under two epochs records one undo entry with one command per epoch, and one Undo leaves both in the Inbox")
    @MainActor
    func archiveChatUndoSplitsByEpoch() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        // An IMAP account whose Inbox's epoch is known. No provider is registered for it, so its
        // queued move stays queued and Undo takes it back before it runs.
        let accountId = "imap-epochs"
        try await pool.write { db in
            var account = Account(emailAddress: "imap@example.com", displayName: "IMAP", provider: .imap)
            account.id = accountId
            try account.insert(db)
            var inbox = Folder(name: "INBOX", path: Self.inboxPath, role: .inbox, accountId: accountId)
            inbox.lastKnownUidValidity = 7
            try inbox.insert(db)
            var archive = Folder(name: "Archive", path: Self.archivePath, role: .archive, accountId: accountId)
            archive.lastKnownUidValidity = 9
            try archive.insert(db)
        }
        let unknown = try insertHeader(pool, messageId: "101", accountId: accountId)
        let stamped = try insertHeader(pool, messageId: "102", accountId: accountId, observedUidValidity: 7)
        let ids = [unknown.id, stamped.id]
        let vm = openChat(pool, focused: stamped, others: [unknown])

        #expect(!vm.archiveChat([stamped, unknown]).isEmpty)
        #expect(UndoService.shared.undoStack.count == 1, "one undo entry for the whole chat")
        let commands = UndoService.shared.undoStack.first?.commands ?? []
        #expect(commands.count == 2, "one command per source epoch: \(commands.map { $0.members.map(\.originalHeaderId) })")
        #expect(commands.allSatisfy { Set($0.members.map(\.sourceObservedUidValidity)).count == 1 },
                "no command mixes epochs")

        try await settle(pool, ids: [stamped.id], in: Self.archivePath)
        let archived = try await rows(pool, ids)
        #expect(archived.first { $0.id == stamped.id }?.folderPath == Self.archivePath,
                "control: the email of the known epoch was archived")
        #expect(archived.first { $0.id == unknown.id }?.folderPath == Self.inboxPath,
                "control: the email of the unknown epoch was not moved")

        await UndoService.shared.undo()
        try await settle(pool, ids: ids, in: Self.inboxPath)
        let restored = try await rows(pool, ids)
        #expect(restored.count == 2)
        #expect(restored.allSatisfy { $0.folderPath == Self.inboxPath }, "one Undo leaves both emails in the Inbox")
    }

    enum OpenedFrom: String, CaseIterable, Sendable {
        case inbox, archive, label
    }

    @Test("Moving a chat takes the emails in the folder it was opened from and leaves the rest where they are, and one Undo puts them back",
          arguments: OpenedFrom.allCases)
    @MainActor
    func moveChatTakesTheOpenedFolder(from openedFrom: OpenedFrom) async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let chat = try mixedChat(pool, "mixmov-\(openedFrom.rawValue)")
        // A second email in the opened folder, so the move takes more than the opened one.
        let sibling: MessageHeader
        let opened: MessageHeader
        let destination: String
        switch openedFrom {
        case .inbox:
            opened = chat.inbox
            sibling = try insertHeader(pool, messageId: "mixmov-inbox-2")
            destination = Self.clientsPath
        case .archive:
            opened = chat.archived
            sibling = try insertHeader(pool, messageId: "mixmov-archive-2", folderPath: Self.archivePath, isRead: true)
            destination = Self.inboxPath
        case .label:
            opened = chat.filed
            sibling = try insertHeader(pool, messageId: "mixmov-label-2", folderPath: Self.projectsPath, isRead: true)
            destination = Self.clientsPath
        }
        let all = chat.all + [sibling]
        let ids = all.map(\.id)
        let before = try await folders(pool, ids)
        let vm = openChat(pool, focused: opened, others: all.filter { $0.id != opened.id })

        #expect(vm.moveChat(all, toFolderPath: destination) == [opened.id, sibling.id],
                "the move takes the emails in the folder the chat was opened from")
        #expect(UndoService.shared.undoStack.count == 1)

        var moved = before
        moved[opened.id] = destination
        moved[sibling.id] = destination
        try await settle(pool, moved)
        #expect(try await folders(pool, ids) == moved, "every other email stays where it is")
        if openedFrom == .inbox {
            #expect(try await folders(pool, [chat.filed.id])[chat.filed.id] == Self.projectsPath,
                    "the copy under the Projects label keeps its label")
        }

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
            #expect(!vm.archiveChat([opened, other]).isEmpty)
            after = [opened.id: Self.archivePath, other.id: Self.otherArchivePath]
        case .delete:
            #expect(!vm.deleteChat([opened, other]).isEmpty)
            after = [opened.id: Self.trashPath, other.id: Self.otherTrashPath]
        case .move:
            #expect(!vm.moveChat([opened, other], toFolderPath: Self.projectsPath).isEmpty)
            after = [opened.id: Self.projectsPath, other.id: Self.projectsPath]
        case .moveWithNoSuchFolder:
            #expect(!vm.moveChat([opened, other], toFolderPath: Self.projectsPath).isEmpty)
            after[opened.id] = Self.projectsPath
        }
        #expect(UndoService.shared.undoStack.count == 1)
        try await settle(pool, after)
        #expect(try await folders(pool, ids) == after, "each email went to its own account's folder")

        await UndoService.shared.undo()
        try await settle(pool, before)
        #expect(try await folders(pool, ids) == before, "one Undo puts every email back")
    }

    /// A second account whose system folders have other names, with a user folder named "Sent" and
    /// one named "Projects" like the first account's.
    @MainActor
    private func addRenamedAccount(_ pool: DatabasePool) async throws {
        try await pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "other@example.com", displayName: "Other", provider: .gmail)
            acc.id = "acc2"
            try acc.insert(db)
            try Folder(name: "INBOX", path: Self.inboxPath, role: .inbox, accountId: "acc2").insert(db)
            try Folder(name: "Archive", path: Self.otherArchivePath, role: .archive, accountId: "acc2").insert(db)
            try Folder(name: "Trash", path: Self.otherTrashPath, role: .trash, accountId: "acc2").insert(db)
            try Folder(name: "Sent Items", path: Self.otherSentPath, role: .sent, accountId: "acc2").insert(db)
            try Folder(name: "Sent", path: Self.sentPath, role: .custom, accountId: "acc2").insert(db)
            try Folder(name: "Projects", path: Self.projectsPath, role: .custom, accountId: "acc2").insert(db)
            try Folder(name: "Clients", path: Self.clientsPath, role: .custom, accountId: "acc2").insert(db)
        }
    }

    private static let otherSentPath = "Sent Items"

    @Test("A chat's system folders are known by their role in each account, whatever their names")
    @MainActor
    func systemFoldersByRoleAcrossAccounts() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()
        try await addRenamedAccount(pool)

        let archived = try insertHeader(pool, messageId: "role-archived", folderPath: Self.archivePath, isRead: true)
        let otherArchived = try insertHeader(pool, messageId: "role-other-archived", folderPath: Self.otherArchivePath, isRead: true, accountId: "acc2")
        let sent = try insertHeader(pool, messageId: "role-sent", folderPath: Self.sentPath, isRead: true)
        let otherSent = try insertHeader(pool, messageId: "role-other-sent", folderPath: Self.otherSentPath, isRead: true, accountId: "acc2")
        let userSent = try insertHeader(pool, messageId: "role-user-sent", folderPath: Self.sentPath, isRead: true, accountId: "acc2")
        let all = [archived, otherArchived, sent, otherSent, userSent]
        let ids = all.map(\.id)
        let before = try await folders(pool, ids)

        // Moved from Archive: the other account's Archive, under its own name, goes too.
        let vm = openChat(pool, focused: archived, others: Array(all.dropFirst()))
        #expect(vm.moveChat(all, toFolderPath: Self.clientsPath) == [archived.id, otherArchived.id])
        var moved = before
        moved[archived.id] = Self.clientsPath
        moved[otherArchived.id] = Self.clientsPath
        try await settle(pool, moved)
        #expect(try await folders(pool, ids) == moved)
        await UndoService.shared.undo()
        try await settle(pool, before)

        // Deleted: each account's sent copies stay, whatever the folder's name; a user folder named
        // "Sent" is no sent folder.
        #expect(vm.deleteChat(all) == [archived.id, otherArchived.id, userSent.id])
        var deleted = before
        deleted[archived.id] = Self.trashPath
        deleted[otherArchived.id] = Self.otherTrashPath
        deleted[userSent.id] = Self.otherTrashPath
        try await settle(pool, deleted)
        #expect(try await folders(pool, ids) == deleted)
    }

    @Test("Moving a chat from a user folder leaves the other account's folder of the same name untouched")
    @MainActor
    func sameNamedFolderInAnotherAccountStays() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()
        try await addRenamedAccount(pool)

        let filed = try insertHeader(pool, messageId: "same-name-own", folderPath: Self.projectsPath, isRead: true)
        let foreign = try insertHeader(pool, messageId: "same-name-foreign", folderPath: Self.projectsPath, isRead: true, accountId: "acc2")
        let ids = [filed.id, foreign.id]
        let before = try await folders(pool, ids)
        let vm = openChat(pool, focused: filed, others: [foreign])

        #expect(vm.moveChat([filed, foreign], toFolderPath: Self.clientsPath) == [filed.id])
        var moved = before
        moved[filed.id] = Self.clientsPath
        try await settle(pool, moved)
        #expect(try await folders(pool, ids) == moved, "the other account's Projects is another folder")
    }

    @Test("A row whose folder role cannot be read is never moved, an unknown opened folder moves nothing, and one Undo restores only what moved")
    @MainActor
    func unknownRoleFailsClosed() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        // "Sent Mail" has no Folder row: its role cannot be read, so it may be a sent folder.
        let unknownPath = "Sent Mail"
        let inbox = try insertHeader(pool, messageId: "unknown-inbox")
        let filed = try insertHeader(pool, messageId: "unknown-filed", folderPath: Self.projectsPath, isRead: true)
        let unknown = try insertHeader(pool, messageId: "unknown-role", folderPath: unknownPath, isRead: true)
        let outside = try insertHeader(pool, messageId: "unknown-outside")
        let chat = [inbox, filed, unknown]
        let ids = (chat + [outside]).map(\.id)
        let before = try await folders(pool, ids)

        // Opened from the folder with no role: nothing to go by, so nothing moves.
        let fromUnknown = openChat(pool, focused: unknown, others: [inbox, filed])
        #expect(fromUnknown.moveChat(chat, toFolderPath: Self.clientsPath).isEmpty)
        #expect(UndoService.shared.undoStack.isEmpty)

        let vm = openChat(pool, focused: inbox, others: [filed, unknown])
        #expect(vm.deleteChat(chat) == [inbox.id, filed.id], "the row with no readable role stays")
        var deleted = before
        deleted[inbox.id] = Self.trashPath
        deleted[filed.id] = Self.trashPath
        try await settle(pool, deleted)
        #expect(try await folders(pool, ids) == deleted)

        await UndoService.shared.undo()
        try await settle(pool, before)
        #expect(try await folders(pool, ids) == before, "one Undo puts back what moved, and nothing else")
        #expect(try await opsInDrainOrder(pool).allSatisfy { op in
            !op.messageIds.contains(unknown.messageId) && !op.messageIds.contains(outside.messageId)
        }, "no queued work names the row with no role or the email outside the chat")
    }

    @Test("When the folder roles cannot be read at all, a whole-chat action moves nothing and records no Undo")
    @MainActor
    func unreadableRolesMoveNothing() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let inbox = try insertHeader(pool, messageId: "unreadable-inbox")
        let filed = try insertHeader(pool, messageId: "unreadable-filed", folderPath: Self.projectsPath, isRead: true)
        let chat = [inbox, filed]
        let ids = chat.map(\.id)
        let before = try await folders(pool, ids)
        let vm = openChat(pool, focused: inbox, others: [filed])

        // Every folder read fails, as it does on a database error.
        try await pool.write { try $0.execute(sql: "ALTER TABLE folder RENAME TO folderUnreadable") }
        #expect(vm.archiveChat(chat).isEmpty)
        #expect(vm.deleteChat(chat).isEmpty)
        #expect(vm.moveChat(chat, toFolderPath: Self.clientsPath).isEmpty)
        #expect(UndoService.shared.undoStack.isEmpty, "nothing to undo")
        #expect(AccountManager.shared.snapshotOverlay()[inbox.id] == nil && AccountManager.shared.snapshotOverlay()[filed.id] == nil,
                "no email is shown moved")
        try await pool.write { try $0.execute(sql: "ALTER TABLE folderUnreadable RENAME TO folder") }
        #expect(try await folders(pool, ids) == before, "every email is where it was")
        #expect(try await opsInDrainOrder(pool).isEmpty, "no work is queued")

        // Control: with the roles readable again, the same Delete takes the chat.
        #expect(vm.deleteChat(chat) == Set(ids), "control: a readable chat moves")
        var deleted = before
        deleted[inbox.id] = Self.trashPath
        deleted[filed.id] = Self.trashPath
        try await settle(pool, deleted)
    }

    @Test("A chat offers Archive when any email it loaded is in an Inbox, wherever that email is in the chat, and not when none is or the roles cannot be read")
    @MainActor
    func inboxCopyDecidesArchive() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }

        let filed = try insertHeader(pool, messageId: "offer-filed", folderPath: Self.projectsPath, isRead: true)
        let sent = try insertHeader(pool, messageId: "offer-sent", folderPath: Self.sentPath, isRead: true)
        let inbox = try insertHeader(pool, messageId: "offer-inbox")
        // The Inbox email is the chat's last row, after two that are not in an Inbox.
        let offered = openChat(pool, focused: filed, others: [sent, inbox])
        #expect(offered.chatRows.map(\.id) == [filed.id, sent.id, inbox.id], "control: the chat loaded all three")
        #expect(offered.chatHasInboxCopy, "an Inbox email anywhere in the chat offers Archive")

        let notOffered = openChat(pool, focused: filed, others: [sent])
        #expect(!notOffered.chatHasInboxCopy, "a chat with no Inbox email offers no Archive")

        // Every folder read fails, as it does on a database error: no Archive is offered.
        try await pool.write { try $0.execute(sql: "ALTER TABLE folder RENAME TO folderUnreadable") }
        #expect(!offered.chatHasInboxCopy, "unreadable roles offer no Archive")
        try await pool.write { try $0.execute(sql: "ALTER TABLE folderUnreadable RENAME TO folder") }
        #expect(offered.chatHasInboxCopy, "control: readable roles offer it again")
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

        #expect(vm.archiveChat([sent, draft]).isEmpty)
        #expect(vm.deleteChat([sent, draft, binned]).isEmpty)
        #expect(vm.moveChat([sent, draft], toFolderPath: Self.projectsPath).isEmpty)
        #expect(vm.archiveChat([]).isEmpty)
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

    // MARK: - The tag a whole-chat action records

    private typealias Gate = MessageDetailDisplayOrderTests.Gate
    /// A flag set from a whole-chat action's read (another thread) and checked on the main actor.
    private final class ReadFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        /// Sets the flag; returns whether this call was the first.
        func setFirst() -> Bool { lock.withLock { defer { value = true }; return !value } }
        var on: Bool { lock.withLock { value } }
    }

    /// Runs `work` on another thread and waits for it: from `_chatRowsReadHook`, it lands inside
    /// the action's read, after the read's database snapshot is fixed, as a write that commits on
    /// the write queue's thread while the read is still running.
    nonisolated private static func landDuringTheRead(_ work: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            work()
            done.signal()
        }
        done.wait()
    }

    /// An action tag with its sort order, as a row stores them and an undo member records them.
    private struct TagPair: Equatable, CustomStringConvertible {
        let tag: ActionTag?
        let sortOrder: Int
        init(_ tag: ActionTag?) {
            self.tag = tag
            sortOrder = tag?.sortOrder ?? 99
        }
        init(of header: MessageHeader) {
            tag = header.actionTag
            sortOrder = header.tagSortOrder
        }
        init(tag: ActionTag?, sortOrder: Int) {
            self.tag = tag
            self.sortOrder = sortOrder
        }
        var description: String { "(\(tag?.rawValue ?? "nil"), \(sortOrder))" }
    }

    /// Waits until `condition` holds or the deadline passes; the caller expects the condition after.
    @MainActor
    private func waitUntil(seconds: Double = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// An Inbox row (not stored) with Message-ID `rfc`, tagged `tag`.
    private func inboxRow(messageId: String, rfc: String, tag: ActionTag?) -> MessageHeader {
        var row = MessageHeader(
            messageId: messageId, subject: "Test",
            from: "sender@example.com", fromAddress: "sender@example.com",
            to: "me@example.com", date: Self.seededDate, snippet: "body",
            folderId: "acc1:\(Self.inboxPath)", accountId: "acc1",
            folderPath: Self.inboxPath, isInInbox: true
        )
        row.headerComplete = true
        row.rfc822MessageId = rfc
        row.setActionTag(tag)
        return row
    }

    /// Opens a chat on `labeled` (a Projects copy) whose hidden Inbox copy carries the same
    /// Message-ID, through the real thread load, and waits until the load published it. With
    /// `withMember`, the labeled copy references `member`, an Inbox email the chat shows. Both Inbox
    /// rows start tagged `tag`.
    @MainActor
    private func openChatWithHiddenInboxCopy(
        _ pool: DatabasePool, tag: ActionTag?, withMember: Bool = false
    ) async throws -> (vm: MessageDetailViewModel, copy: MessageHeader, member: MessageHeader?) {
        let rfc = "<hidden-copy@example.com>"
        let memberRfc = "<chat-member@example.com>"
        let member = withMember ? inboxRow(messageId: "member-1", rfc: memberRfc, tag: tag) : nil
        if let member { try await insertCopy(pool, member) }
        var labeled = try insertHeader(pool, messageId: "labeled-1", folderPath: Self.projectsPath)
        labeled.rfc822MessageId = rfc
        if withMember { labeled.referencesJSON = MessageHeader.encodeReferences([memberRfc]) }
        let labeledRow = labeled
        try await pool.write { db in try labeledRow.update(db) }
        let copy = inboxRow(messageId: "inbox-1", rfc: rfc, tag: tag)
        try await insertCopy(pool, copy)
        let vm = MessageDetailViewModel(messageId: labeled.id, dbPool: pool, fetchBodyOverride: { _ in },
                                        observeNotifications: true)
        vm._testSeedMessage(labeled)
        vm.reloadThread()
        let copyId = copy.id
        let memberId = member?.id
        await waitUntil {
            vm.hasLoadedThread && vm.displayTurnIsIdleForTesting
                && vm.threadCopies.contains(where: { $0.id == copyId })
                && (memberId.map { id in vm.threadMessages.contains(where: { $0.id == id }) } ?? true)
        }
        return (vm, copy, member)
    }

    /// Whether the chat loaded the hidden copy (only) and shows the member.
    @MainActor
    private func chatLoaded(_ vm: MessageDetailViewModel, copy copyId: String, member memberId: String) -> Bool {
        vm.threadCopies.map(\.id) == [copyId] && vm.threadMessages.map(\.id) == [memberId]
    }

    /// Stores a row, as a sync insert does.
    private func insertCopy(_ pool: DatabasePool, _ row: MessageHeader) async throws {
        try await pool.write { db in try row.insert(db) }
    }

    /// Stores each row's tag with its sort order in one write, as a tag writer does. With `post`,
    /// posts each row's change; `post: false` is a writer that posts no per-row change (a bulk
    /// write past the per-row post limit).
    @MainActor
    private func writeTags(_ pool: DatabasePool, _ tags: [String: ActionTag?], post: Bool = true) async throws {
        try await pool.write { db in
            for (id, tag) in tags {
                guard var row = try MessageHeader.fetchOne(db, key: id) else { continue }
                row.setActionTag(tag)
                try row.update(db)
            }
        }
        guard post else { return }
        for id in tags.keys { NotificationCenter.default.post(name: .messageDataDidChange, object: id) }
    }

    /// The tag pair the chat holds for `id`, on the email it shows or on a hidden copy.
    @MainActor
    private func heldTag(_ vm: MessageDetailViewModel, _ id: String) -> TagPair? {
        (vm.threadMessages + vm.threadCopies).first(where: { $0.id == id }).map { TagPair(of: $0) }
    }

    /// The tag pair the last action recorded for `id`, in its snapshot and in the undo member that
    /// Undo restores from.
    @MainActor
    private func recordedTag(_ id: String) -> (snapshot: TagPair?, member: TagPair?) {
        let entry = UndoService.shared.undoStack.last
        let row = entry?.messages.first(where: { $0.id == id })
        let member = entry?.commands.flatMap(\.members).first(where: { $0.originalHeaderId == id })
        return (row.map { TagPair(of: $0) },
                member.map { TagPair(tag: $0.sourceActionTag, sortOrder: $0.sourceTagSortOrder) })
    }

    /// Archives every row the chat loaded and expects it to take exactly `ids` and to record
    /// `pair` for each.
    @MainActor
    private func expectArchiveRecords(_ vm: MessageDetailViewModel, _ ids: [String], _ pair: TagPair,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(vm.archiveChat(vm.chatRows) == Set(ids), "Archive takes the chat's Inbox rows", sourceLocation: sourceLocation)
        for id in ids {
            let recorded = recordedTag(id)
            #expect(recorded.snapshot == pair, "the undo snapshot of \(id) holds \(pair), not \(String(describing: recorded.snapshot))",
                    sourceLocation: sourceLocation)
            #expect(recorded.member == pair, "the undo member of \(id) holds \(pair), not \(String(describing: recorded.member))",
                    sourceLocation: sourceLocation)
        }
    }

    /// Expects the action to have landed (each row stored in `movedTo`, its tag cleared as it left
    /// the Inbox), undoes it, and expects each row back in the Inbox with `pair`.
    /// `restoredTo` is the folder Undo returns the rows to (the Inbox unless the action took filed rows).
    @MainActor
    private func expectUndoRestores(_ pool: DatabasePool, _ ids: [String], _ pair: TagPair,
                                    movedTo movedPath: String = archivePath,
                                    restoredTo restoredPath: String = inboxPath,
                                    sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await settle(pool, ids: ids, in: movedPath)
        await AccountManager.shared.awaitWriteQueueDrain()
        let moved = try await rows(pool, ids)
        #expect(moved.count == ids.count, sourceLocation: sourceLocation)
        for row in moved {
            #expect(row.folderPath == movedPath, "control: the action moved \(row.id)", sourceLocation: sourceLocation)
            #expect(TagPair(of: row) == TagPair(nil), "control: \(row.id) left the Inbox with its tag cleared",
                    sourceLocation: sourceLocation)
        }
        await UndoService.shared.undo()
        try await settle(pool, ids: ids, in: restoredPath)
        await AccountManager.shared.awaitWriteQueueDrain()
        let restored = try await rows(pool, ids)
        #expect(restored.count == ids.count, sourceLocation: sourceLocation)
        for row in restored {
            #expect(row.folderPath == restoredPath, "control: Undo put \(row.id) back", sourceLocation: sourceLocation)
            #expect(TagPair(of: row) == pair, "Undo restores \(pair) on \(row.id), not \(TagPair(of: row))",
                    sourceLocation: sourceLocation)
        }
    }

    @Test("The tag written last to a chat's hidden Inbox copy and to the email it shows is the one a whole-chat Archive records and its Undo restores")
    @MainActor
    func archiveUndoKeepsTheLatestTag() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let (vm, copy, member) = try await openChatWithHiddenInboxCopy(pool, tag: .archive, withMember: true)
        guard let member, chatLoaded(vm, copy: copy.id, member: member.id) else {
            Issue.record("control: the load published the hidden Inbox copy and the shown email"); return
        }
        let ids = [copy.id, member.id]
        #expect(heldTag(vm, copy.id) == TagPair(.archive), "control: the older pair")

        try await writeTags(pool, [copy.id: .reply, member.id: .reply])
        // The shown email's row change reaches the chat while it stays open; the hidden copy is
        // not refreshed and still holds the older tag.
        await waitUntil { heldTag(vm, member.id) == TagPair(.reply) && vm.displayTurnIsIdleForTesting }
        #expect(heldTag(vm, member.id) == TagPair(.reply), "control: the chat shows the latest tag")
        #expect(heldTag(vm, copy.id) == TagPair(.archive), "control: the hidden copy holds the older tag")

        expectArchiveRecords(vm, ids, TagPair(.reply))
        try await expectUndoRestores(pool, ids, TagPair(.reply))
    }

    @Test("A tag written while a chat swipe holds the screen still is the one a whole-chat Archive records and its Undo restores")
    @MainActor
    func archiveDuringASwipeRecordsTheLatestTag() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        let holdId = "latest-tag-swipe"
        defer { ChatSwipeHold.shared.releaseNow(holdId) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let (vm, copy, member) = try await openChatWithHiddenInboxCopy(pool, tag: .archive, withMember: true)
        guard let member, chatLoaded(vm, copy: copy.id, member: member.id) else {
            Issue.record("control: the load published the hidden Inbox copy and the shown email"); return
        }
        let ids = [copy.id, member.id]

        // A swipe takes the finger: row changes wait until it lets go and settles.
        ChatSwipeHold.shared.begin(holdId)
        #expect(PreviewFreezeGate.shared.isFrozen, "control: the swipe holds the screen still")
        try await writeTags(pool, [copy.id: .reply, member.id: .reply])
        // Both row changes reached the chat and were held back by the swipe.
        await waitUntil { Set(ids).isSubset(of: vm.pendingRefreshIdsForTesting) }
        #expect(Set(ids).isSubset(of: vm.pendingRefreshIdsForTesting), "control: the swipe holds both row changes")
        #expect(ids.allSatisfy { heldTag(vm, $0) == TagPair(.archive) }, "control: the chat still holds the older tag")

        // The swipe's Archive, before it lets go.
        expectArchiveRecords(vm, ids, TagPair(.reply))

        ChatSwipeHold.shared.release(holdId, after: .zero)
        await waitUntil { !PreviewFreezeGate.shared.isFrozen && vm.pendingRefreshIdsForTesting.isEmpty }
        #expect(!PreviewFreezeGate.shared.isFrozen, "control: the swipe let go")
        #expect(vm.pendingRefreshIdsForTesting.isEmpty, "control: the held row changes were taken for replay")
        try await expectUndoRestores(pool, ids, TagPair(.reply))
    }

    @Test("A tag written while its row change waits behind a held display turn is the one a whole-chat Archive records and its Undo restores")
    @MainActor
    func archiveWhileARefreshWaitsRecordsTheLatestTag() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let (vm, copy, member) = try await openChatWithHiddenInboxCopy(pool, tag: .archive, withMember: true)
        guard let member, chatLoaded(vm, copy: copy.id, member: member.id) else {
            Issue.record("control: the load published the hidden Inbox copy and the shown email"); return
        }
        let ids = [copy.id, member.id]

        // A thread load reads the rows, still tagged Archive, and is held before it publishes.
        let gate = Gate()
        defer { gate.open() }
        vm._displayReadHook = { point in
            if point == .threadScan, !gate.reached { await gate.hold() }
        }
        vm.reloadThread()
        await waitUntil { gate.reached }
        guard gate.reached else { Issue.record("control: the load read the rows and is held"); return }

        // The newer tags are stored; their row changes wait behind the held load.
        try await writeTags(pool, [copy.id: .reply, member.id: .reply])
        await waitUntil { vm.displayTurnWaitersForTesting >= 2 }
        #expect(vm.displayTurnWaitersForTesting >= 2, "control: both row changes wait behind the held load")
        #expect(ids.allSatisfy { heldTag(vm, $0) == TagPair(.archive) }, "control: the chat still holds the older tag")

        expectArchiveRecords(vm, ids, TagPair(.reply))

        gate.open()
        await waitUntil { gate.passed && vm.displayTurnIsIdleForTesting }
        #expect(vm.displayTurnIsIdleForTesting)
        try await expectUndoRestores(pool, ids, TagPair(.reply))
    }

    @Test("A tag written with no per-row change posted is the one a whole-chat Archive records and its Undo restores")
    @MainActor
    func archiveAfterAnUnpostedTagWriteRecordsTheStoredTag() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let (vm, copy, member) = try await openChatWithHiddenInboxCopy(pool, tag: .reply, withMember: true)
        guard let member, chatLoaded(vm, copy: copy.id, member: member.id) else {
            Issue.record("control: the load published the hidden Inbox copy and the shown email"); return
        }
        let ids = [copy.id, member.id]

        try await writeTags(pool, [copy.id: ActionTag.none, member.id: ActionTag.none], post: false)
        #expect(ids.allSatisfy { heldTag(vm, $0) == TagPair(.reply) }, "control: nothing told the chat")

        expectArchiveRecords(vm, ids, TagPair(ActionTag.none))
        try await expectUndoRestores(pool, ids, TagPair(ActionTag.none))
    }

    @Test("A whole-chat Archive records a pending tag change on top of the stored tag, and not its own tag clear")
    @MainActor
    func archiveRecordsAPendingTagChange() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let (vm, copy, member) = try await openChatWithHiddenInboxCopy(pool, tag: .archive, withMember: true)
        guard let member, chatLoaded(vm, copy: copy.id, member: member.id) else {
            Issue.record("control: the load published the hidden Inbox copy and the shown email"); return
        }

        // A retag of the copy is pending: its intent is registered, its write has not landed.
        AccountManager.shared.registerMutation(id: copy.id, mutation: .init(actionTag: .some(.delete)))

        #expect(vm.archiveChat(vm.chatRows) == [copy.id, member.id], "Archive takes the chat's Inbox rows")
        #expect(recordedTag(copy.id).member == TagPair(.delete), "the pending tag is the one Undo restores")
        #expect(recordedTag(copy.id).snapshot == TagPair(.delete))
        #expect(recordedTag(member.id).member == TagPair(.archive), "a row with nothing pending records its stored tag")
        #expect(recordedTag(member.id).snapshot == TagPair(.archive))
        try await settle(pool, ids: [copy.id, member.id], in: Self.archivePath)
    }

    @Test("A whole-chat Archive leaves out a row the store no longer holds, and records no undo for it")
    @MainActor
    func archiveLeavesOutARowNoLongerStored() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let (vm, copy, member) = try await openChatWithHiddenInboxCopy(pool, tag: .archive, withMember: true)
        guard let member, chatLoaded(vm, copy: copy.id, member: member.id) else {
            Issue.record("control: the load published the hidden Inbox copy and the shown email"); return
        }
        let copyId = copy.id
        // The copy's row goes (another device removed it), and the chat still holds it.
        try await pool.write { db in _ = try MessageHeader.deleteOne(db, key: copyId) }
        #expect(vm.chatRows.contains(where: { $0.id == copyId }), "control: the chat still holds the copy")

        #expect(vm.archiveChat(vm.chatRows) == [member.id], "Archive takes only the stored row")
        let entry = UndoService.shared.undoStack.last
        #expect(entry?.messages.map(\.id) == [member.id], "the undo snapshot names only the stored row")
        #expect(entry?.commands.flatMap(\.members).map(\.originalHeaderId) == [member.id],
                "the undo members name only the stored row")
        try await settle(pool, ids: [member.id], in: Self.archivePath)
    }


    @Test("A whole-chat Archive records a pending tag clear on top of the stored tag, and its Undo restores no tag")
    @MainActor
    func archiveRecordsAPendingTagClear() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let (vm, copy, member) = try await openChatWithHiddenInboxCopy(pool, tag: .reply, withMember: true)
        guard let member, chatLoaded(vm, copy: copy.id, member: member.id) else {
            Issue.record("control: the load published the hidden Inbox copy and the shown email"); return
        }
        let ids = [copy.id, member.id]

        // A tag clear of both rows is pending: its intent is registered, its write has not landed.
        for id in ids {
            AccountManager.shared.registerMutation(id: id, mutation: .init(actionTag: .some(nil)))
        }
        #expect(ids.allSatisfy { heldTag(vm, $0) == TagPair(.reply) }, "control: the chat holds the stored tag")

        expectArchiveRecords(vm, ids, TagPair(nil))
        try await expectUndoRestores(pool, ids, TagPair(nil))
    }

    @Test("A whole-chat Archive records a pending None tag on top of the stored tag as None, not as no tag, and its Undo restores None")
    @MainActor
    func archiveRecordsAPendingNoneTag() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let (vm, copy, member) = try await openChatWithHiddenInboxCopy(pool, tag: .reply, withMember: true)
        guard let member, chatLoaded(vm, copy: copy.id, member: member.id) else {
            Issue.record("control: the load published the hidden Inbox copy and the shown email"); return
        }
        let ids = [copy.id, member.id]

        // A retag of both rows to None is pending: its intent is registered, its write has not landed.
        for id in ids {
            AccountManager.shared.registerMutation(id: id, mutation: .init(actionTag: .some(ActionTag.none)))
        }
        #expect(ids.allSatisfy { heldTag(vm, $0) == TagPair(.reply) }, "control: the chat holds the stored tag")
        #expect(TagPair(ActionTag.none) != TagPair(nil), "control: None and no tag are different pairs")

        expectArchiveRecords(vm, ids, TagPair(ActionTag.none))
        try await expectUndoRestores(pool, ids, TagPair(ActionTag.none))
    }

    @Test("A tag whose write lands while a whole-chat Archive reads its rows is the one the Archive records and its Undo restores")
    @MainActor
    func archiveRecordsATagThatLandsDuringItsRead() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let (vm, copy, member) = try await openChatWithHiddenInboxCopy(pool, tag: .archive, withMember: true)
        guard let member, chatLoaded(vm, copy: copy.id, member: member.id) else {
            Issue.record("control: the load published the hidden Inbox copy and the shown email"); return
        }
        let ids = [copy.id, member.id]

        // A retag of both rows is pending when the Archive starts.
        for id in ids {
            AccountManager.shared.registerMutation(id: id, mutation: .init(actionTag: .some(.reply)))
        }
        // While the Archive reads the rows (its snapshot already fixed, without the retag), the
        // retag's write lands and its overlay entry retires, as the write queue does on another
        // thread. Only an overlay snapshot taken before the read still holds the retag.
        let landed = ReadFlag()
        let wrote = ReadFlag()
        let retired = ReadFlag()
        vm._chatRowsReadHook = {
            guard landed.setFirst() else { return }
            Self.landDuringTheRead {
                // A failed write leaves `wrote` unset, which the control below reports (this
                // thread has no test context to record an issue in).
                let committed: Void? = try? pool.writeWithoutTransaction { db in
                    for id in ids {
                        guard var row = try MessageHeader.fetchOne(db, key: id) else { continue }
                        row.setActionTag(.reply)
                        try row.update(db)
                    }
                }
                if committed != nil { _ = wrote.setFirst() }
                AccountManager.shared.removeOverlayEntries(ids: ids)
                // Checked here, before the Archive registers its own tag clear for these rows.
                let overlay = AccountManager.shared.snapshotOverlay()
                if ids.allSatisfy({ overlay[$0] == nil }) { _ = retired.setFirst() }
            }
        }

        expectArchiveRecords(vm, ids, TagPair(.reply))
        #expect(landed.on, "control: the retag landed during the Archive's read")
        #expect(wrote.on, "control: the retag's write committed")
        #expect(retired.on, "control: the retag's overlay entry retired during the read")
        try await expectUndoRestores(pool, ids, TagPair(.reply))
    }

    enum WholeChatAction: String, CaseIterable, Sendable {
        case trash, move
    }

    @Test("A whole-chat Trash or Move records every row's stored tag, the opened email's included, and its Undo restores it",
          arguments: WholeChatAction.allCases)
    @MainActor
    func trashAndMoveRecordTheStoredTagOnEveryRow(action: WholeChatAction) async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let opener = try insertHeader(pool, messageId: "every-row-opener-\(action.rawValue)")
        let member = try insertHeader(pool, messageId: "every-row-member-\(action.rawValue)")
        let ids = [opener.id, member.id]
        try await writeTags(pool, [opener.id: .archive, member.id: .archive], post: false)
        var shownOpener = opener
        shownOpener.setActionTag(.archive)
        var shownMember = member
        shownMember.setActionTag(.archive)
        let vm = openChat(pool, focused: shownOpener, others: [shownMember])

        // A newer tag is stored and nothing tells the chat.
        try await writeTags(pool, [opener.id: .reply, member.id: .reply], post: false)
        #expect(ids.allSatisfy { id in vm.chatRows.first(where: { $0.id == id }).map { TagPair(of: $0) } == TagPair(.archive) },
                "control: the chat holds the older tag")

        let movedPath: String
        switch action {
        case .trash:
            movedPath = Self.trashPath
            #expect(vm.deleteChat(vm.chatRows) == Set(ids), "Trash takes every row")
        case .move:
            movedPath = Self.clientsPath
            #expect(vm.moveChat(vm.chatRows, toFolderPath: Self.clientsPath) == Set(ids),
                    "Move takes the rows in the opened folder")
        }
        for id in ids {
            let recorded = recordedTag(id)
            #expect(recorded.snapshot == TagPair(.reply), "the undo snapshot of \(id) holds the stored tag")
            #expect(recorded.member == TagPair(.reply), "the undo member of \(id) holds the stored tag")
        }
        try await expectUndoRestores(pool, ids, TagPair(.reply), movedTo: movedPath)
    }

    @Test("A whole-chat Trash or Move of filed rows records each row's stored tag, not the older one the chat holds, and its Undo restores it in that folder",
          arguments: WholeChatAction.allCases)
    @MainActor
    func trashAndMoveRecordTheStoredTagOnFiledRows(action: WholeChatAction) async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        // Two filed emails the chat loaded while they still carried a tag.
        let opener = try insertHeader(pool, messageId: "filed-opener-\(action.rawValue)", folderPath: Self.projectsPath)
        let member = try insertHeader(pool, messageId: "filed-member-\(action.rawValue)", folderPath: Self.projectsPath)
        let ids = [opener.id, member.id]
        try await writeTags(pool, [opener.id: .reply, member.id: .reply], post: false)
        var shownOpener = opener
        shownOpener.setActionTag(.reply)
        var shownMember = member
        shownMember.setActionTag(.reply)
        let vm = openChat(pool, focused: shownOpener, others: [shownMember])

        // The tag is cleared off the filed rows (tags belong to the Inbox) and nothing tells the chat.
        try await writeTags(pool, [opener.id: nil, member.id: nil], post: false)
        #expect(ids.allSatisfy { id in vm.chatRows.first(where: { $0.id == id }).map { TagPair(of: $0) } == TagPair(.reply) },
                "control: the chat holds the older tag")

        let movedPath: String
        switch action {
        case .trash:
            movedPath = Self.trashPath
            #expect(vm.deleteChat(vm.chatRows) == Set(ids), "Trash takes every row")
        case .move:
            movedPath = Self.clientsPath
            #expect(vm.moveChat(vm.chatRows, toFolderPath: Self.clientsPath) == Set(ids),
                    "Move takes the rows in the opened folder")
        }
        for id in ids {
            let recorded = recordedTag(id)
            #expect(recorded.snapshot == TagPair(nil), "the undo snapshot of \(id) holds the stored pair")
            #expect(recorded.member == TagPair(nil), "the undo member of \(id) holds the stored pair")
        }
        try await expectUndoRestores(pool, ids, TagPair(nil), movedTo: movedPath, restoredTo: Self.projectsPath)
    }

    @Test("A whole-chat Archive records each row's folder as the chat holds it, while its tag is the stored one")
    @MainActor
    func archiveRecordsTheFolderTheChatHolds() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let opener = try insertHeader(pool, messageId: "held-folder-opener")
        let member = try insertHeader(pool, messageId: "held-folder-member")
        let vm = openChat(pool, focused: opener, others: [member])

        // The member's stored row is rewritten in place, under the same id, in another folder and
        // with a tag, as a move's local write does before its row is re-keyed.
        let memberId = member.id
        try await pool.write { db in
            guard var row = try MessageHeader.fetchOne(db, key: memberId) else { return }
            row.folderPath = Self.clientsPath
            row.folderId = "acc1:\(Self.clientsPath)"
            row.isInInbox = false
            row.setActionTag(.reply)
            try row.update(db)
        }
        #expect(vm.chatRows.first(where: { $0.id == memberId })?.folderPath == Self.inboxPath,
                "control: the chat holds the member in the Inbox")
        let storedBefore = try await rows(pool, [memberId])
        #expect(storedBefore.first?.folderPath == Self.clientsPath,
                "control: the store holds the member in Clients when the Archive reads it")

        #expect(vm.archiveChat(vm.chatRows) == [opener.id, memberId], "Archive takes the chat's Inbox rows")
        let entry = UndoService.shared.undoStack.last
        let snapshot = entry?.messages.first(where: { $0.id == memberId })
        let undoMember = entry?.commands.flatMap(\.members).first(where: { $0.originalHeaderId == memberId })
        #expect(snapshot?.folderPath == Self.inboxPath, "the undo snapshot holds the folder the chat shows")
        #expect(snapshot?.folderId == "acc1:\(Self.inboxPath)")
        #expect(snapshot?.isInInbox == true, "the undo snapshot holds the Inbox flag the chat shows")
        #expect(undoMember?.sourceFolderPath == Self.inboxPath, "the undo member's source is the folder the chat shows")
        #expect(undoMember?.sourceIsInInbox == true, "the undo member's source is Inbox mail, as the chat shows")
        #expect(recordedTag(memberId).member == TagPair(.reply), "control: the tag is the stored one")

        // The recording is the rule here. The forward move reads each row where the store holds it
        // (Inbox and Clients), so Undo of this mixed-source command is refused by `undoMove`'s
        // exact-bundle guard; Undo's own round trip is covered by the tests above.
        try await settle(pool, ids: [opener.id, memberId], in: Self.archivePath)
    }

    @Test("A whole-chat Archive takes a chat's email that a notification opened while it is still staged, and its Undo restores it")
    @MainActor
    func archiveTakesAStagedOpener() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        defer { NSEDataBridge.latestStagedRows.withLock { $0 = [] } }
        clearOverlay()
        UndoService.shared.dismissAll()

        // The opened email is staged only: a notification opened it before it was stored.
        let staged = StagedInboxRow(
            accountId: "acc1", folderPath: Self.inboxPath, messageId: "staged-opener",
            rfc822MessageId: "<staged-opener@example.com>", threadId: nil, inReplyTo: nil, references: [],
            subject: "Test", senderName: "Sender", senderAddress: "sender@example.com", to: "me@example.com",
            snippet: "body", date: Self.seededDate, isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: ActionTag.reply.rawValue, summaryBlurb: nil)
        NSEDataBridge.latestStagedRows.withLock { $0 = [staged] }
        let opener = staged.toMessageHeader()
        let member = try insertHeader(pool, messageId: "staged-member")
        try await writeTags(pool, [member.id: .reply], post: false)
        // The chat shows an older tag on both: the staged and stored tag is newer.
        var shownOpener = opener
        shownOpener.setActionTag(.archive)
        var shownMember = member
        shownMember.setActionTag(.archive)
        let vm = openChat(pool, focused: shownOpener, others: [shownMember])
        let ids = [opener.id, member.id]
        #expect(try await rows(pool, [opener.id]).isEmpty, "control: the opened email is not stored")
        #expect(ids.allSatisfy { id in vm.chatRows.first(where: { $0.id == id }).map { TagPair(of: $0) } == TagPair(.archive) },
                "control: the chat shows the older tag")

        // While the Archive reads the store (its snapshot already fixed, without the email), a
        // merge stores the email and drops it from the staged rows. Only a staged read taken
        // before the store read still holds it.
        let merged = ReadFlag()
        let stored = ReadFlag()
        vm._chatRowsReadHook = {
            guard merged.setFirst() else { return }
            Self.landDuringTheRead {
                // A failed insert leaves `stored` unset, which the control below reports.
                let committed: Void? = try? pool.writeWithoutTransaction { db in try opener.insert(db) }
                if committed != nil { _ = stored.setFirst() }
                NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            }
        }

        expectArchiveRecords(vm, ids, TagPair(.reply))
        #expect(merged.on, "control: the merge landed during the Archive's read")
        #expect(stored.on, "control: the merge stored the email")
        #expect(NSEDataBridge.latestStagedRows.withLock { $0.isEmpty }, "control: the merge unstaged the email")
        try await expectUndoRestores(pool, ids, TagPair(.reply))
    }

    @Test("An email both stored and still staged, with different tags, is recorded with its stored tag by a whole-chat Archive, and its Undo restores it")
    @MainActor
    func archiveTakesTheStoredRowOverItsStagedCopy() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        defer { NSEDataBridge.latestStagedRows.withLock { $0 = [] } }
        clearOverlay()
        UndoService.shared.dismissAll()

        // The stored row is tagged Reply; its staged copy (not yet unstaged) still says Archive,
        // and the chat shows Delete.
        let opener = try insertHeader(pool, messageId: "stored-and-staged")
        try await writeTags(pool, [opener.id: .reply], post: false)
        let staged = StagedInboxRow(
            accountId: "acc1", folderPath: Self.inboxPath, messageId: "stored-and-staged",
            rfc822MessageId: "<stored-and-staged@example.com>", threadId: nil, inReplyTo: nil, references: [],
            subject: "Test", senderName: "Sender", senderAddress: "sender@example.com", to: "me@example.com",
            snippet: "body", date: Self.seededDate, isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: ActionTag.archive.rawValue, summaryBlurb: nil)
        #expect(staged.headerId == opener.id, "control: the staged copy is the same email")
        NSEDataBridge.latestStagedRows.withLock { $0 = [staged] }
        var shown = opener
        shown.setActionTag(.delete)
        let vm = openChat(pool, focused: shown, others: [])

        expectArchiveRecords(vm, [opener.id], TagPair(.reply))
        try await expectUndoRestores(pool, [opener.id], TagPair(.reply))
    }

    @Test("An email stored with no tag while its staged copy carries one is recorded with no tag by a whole-chat Archive, and its Undo restores no tag")
    @MainActor
    func archiveTakesAStoredRowWithNoTagOverItsTaggedStagedCopy() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        defer { NSEDataBridge.latestStagedRows.withLock { $0 = [] } }
        clearOverlay()
        UndoService.shared.dismissAll()

        // The stored row has no tag yet (a header stored without its AI fields); its staged copy,
        // which the chat shows, is tagged Reply.
        let opener = try insertHeader(pool, messageId: "untagged-stored-tagged-staged")
        let staged = StagedInboxRow(
            accountId: "acc1", folderPath: Self.inboxPath, messageId: "untagged-stored-tagged-staged",
            rfc822MessageId: "<untagged-stored-tagged-staged@example.com>", threadId: nil, inReplyTo: nil, references: [],
            subject: "Test", senderName: "Sender", senderAddress: "sender@example.com", to: "me@example.com",
            snippet: "body", date: Self.seededDate, isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: ActionTag.reply.rawValue, summaryBlurb: nil)
        #expect(staged.headerId == opener.id, "control: the staged copy is the same email")
        // The stored row carries the email's Message-ID, as its staged copy does: Undo checks the
        // Message-ID it recorded (from the row the chat shows) against the stored row's.
        let openerId = opener.id
        let stagedRfc = staged.rfc822MessageId
        try await pool.write { db in
            guard var row = try MessageHeader.fetchOne(db, key: openerId) else { return }
            row.rfc822MessageId = stagedRfc
            try row.update(db)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [staged] }
        let stored = try await rows(pool, [opener.id])
        #expect(stored.count == 1)
        guard stored.count == 1 else { return }
        #expect(TagPair(of: stored[0]) == TagPair(nil), "control: the stored row has no tag")
        #expect(stored[0].rfc822MessageId == staged.rfc822MessageId, "control: the stored row and its staged copy have one Message-ID")
        let vm = openChat(pool, focused: staged.toMessageHeader(), others: [])
        #expect(vm.chatRows.first.map { TagPair(of: $0) } == TagPair(.reply), "control: the chat shows the staged tag")

        expectArchiveRecords(vm, [opener.id], TagPair(nil))
        try await expectUndoRestores(pool, [opener.id], TagPair(nil))
    }

    @Test("The move resolver returns stored rows and staged-only rows together, in the order asked, with a stored row over its staged copy, and drops an id it cannot find")
    @MainActor
    func resolverTakesStoredAndStagedRowsInTheOrderAsked() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        defer { NSEDataBridge.latestStagedRows.withLock { $0 = [] } }

        func stagedRow(_ messageId: String, tag: ActionTag) -> StagedInboxRow {
            StagedInboxRow(
                accountId: "acc1", folderPath: Self.inboxPath, messageId: messageId,
                rfc822MessageId: "<\(messageId)@example.com>", threadId: nil, inReplyTo: nil, references: [],
                subject: "Test", senderName: "Sender", senderAddress: "sender@example.com", to: "me@example.com",
                snippet: "body", date: Self.seededDate, isRead: false, isFlagged: false, hasAttachments: false,
                isReplied: false, isForwarded: false, actionTag: tag.rawValue, summaryBlurb: nil)
        }
        // One email stored (tagged Reply) with a staged copy tagged Archive, one only staged, and
        // one id neither stored nor staged.
        let stored = try insertHeader(pool, messageId: "resolve-stored")
        try await writeTags(pool, [stored.id: .reply], post: false)
        let storedCopy = stagedRow("resolve-stored", tag: .archive)
        let stagedOnly = stagedRow("resolve-staged-only", tag: .delete)
        #expect(storedCopy.headerId == stored.id, "control: the staged copy is the stored email")
        NSEDataBridge.latestStagedRows.withLock { $0 = [storedCopy, stagedOnly] }
        let missingId = "acc1:\(Self.inboxPath):resolve-missing"
        #expect(try await rows(pool, [stagedOnly.headerId, missingId]).isEmpty, "control: only one email is stored")

        let resolved = await AccountManager.shared.resolveHeadersForAction(
            ids: [stagedOnly.headerId, missingId, stored.id])
        #expect(resolved.map(\.id) == [stagedOnly.headerId, stored.id],
                "the stored and the staged-only rows, in the order asked, without the missing id")
        guard resolved.count == 2 else { return }
        #expect(TagPair(of: resolved[0]) == TagPair(.delete), "the staged-only row as staged")
        #expect(TagPair(of: resolved[1]) == TagPair(.reply), "the stored row over its staged copy")
    }

    @Test("When the chat's rows cannot be read, a whole-chat action moves nothing and records no Undo")
    @MainActor
    func unreadableRowsMoveNothing() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()

        let inbox = try insertHeader(pool, messageId: "unreadable-rows-inbox")
        let filed = try insertHeader(pool, messageId: "unreadable-rows-filed", folderPath: Self.projectsPath, isRead: true)
        let chat = [inbox, filed]
        let ids = chat.map(\.id)
        let before = try await folders(pool, ids)
        // A staged email the chat also shows: it could be taken without the store.
        let staged = StagedInboxRow(
            accountId: "acc1", folderPath: Self.inboxPath, messageId: "unreadable-rows-staged",
            rfc822MessageId: "<unreadable-rows-staged@example.com>", threadId: nil, inReplyTo: nil, references: [],
            subject: "Test", senderName: "Sender", senderAddress: "sender@example.com", to: "me@example.com",
            snippet: "body", date: Self.seededDate, isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil, summaryBlurb: nil)
        NSEDataBridge.latestStagedRows.withLock { $0 = [staged] }
        defer { NSEDataBridge.latestStagedRows.withLock { $0 = [] } }
        let stagedRow = staged.toMessageHeader()
        let shown = chat + [stagedRow]
        let vm = openChat(pool, focused: inbox, others: [filed, stagedRow])

        // Every email read fails, as it does on a database error, while the folder roles read.
        try await pool.write { try $0.execute(sql: "ALTER TABLE messageHeader RENAME TO messageHeaderUnreadable") }
        #expect(vm.chatHasInboxCopy, "control: the folder roles still read")
        #expect(vm.archiveChat(shown).isEmpty)
        #expect(vm.deleteChat(shown).isEmpty)
        #expect(vm.moveChat(shown, toFolderPath: Self.clientsPath).isEmpty)
        #expect(UndoService.shared.undoStack.isEmpty, "nothing to undo")
        #expect(shown.allSatisfy { AccountManager.shared.snapshotOverlay()[$0.id] == nil }, "no email is shown moved")
        try await pool.write { try $0.execute(sql: "ALTER TABLE messageHeaderUnreadable RENAME TO messageHeader") }
        #expect(try await folders(pool, ids) == before, "every email is where it was")
        #expect(try await opsInDrainOrder(pool).isEmpty, "no work is queued")

        // Control: with the rows readable again and nothing staged, the same Delete takes the chat.
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        #expect(vm.deleteChat(chat) == Set(ids), "control: a readable chat moves")
        var deleted = before
        deleted[inbox.id] = Self.trashPath
        deleted[filed.id] = Self.trashPath
        try await settle(pool, deleted)
    }


    @Test("A whole-chat Archive across two accounts records each row's stored tag, also for the same message id in the same mailbox, and one Undo restores each")
    @MainActor
    func archiveRecordsTheStoredTagInEveryAccount() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer { teardown(previous: previous, pool: pool, dir: dir) }
        clearOverlay()
        UndoService.shared.dismissAll()
        try await addRenamedAccount(pool)

        // The same mailbox path and the same provider message id in both accounts (two IMAP
        // accounts can hold the same Inbox UID): only the account tells the rows apart.
        let opener = try insertHeader(pool, messageId: "tag-two-acc-same-uid")
        let other = try insertHeader(pool, messageId: "tag-two-acc-same-uid", accountId: "acc2")
        #expect(opener.id != other.id && opener.messageId == other.messageId && opener.folderPath == other.folderPath,
                "control: two rows that differ only by account")
        try await writeTags(pool, [opener.id: .archive, other.id: .archive], post: false)
        var shownOpener = opener
        shownOpener.setActionTag(.archive)
        var shownOther = other
        shownOther.setActionTag(.archive)
        let vm = openChat(pool, focused: shownOpener, others: [shownOther])

        // Each account's row gets its own newer tag, and nothing tells the chat.
        try await writeTags(pool, [opener.id: .reply, other.id: .delete], post: false)
        let expected = [opener.id: TagPair(.reply), other.id: TagPair(.delete)]

        #expect(vm.archiveChat(vm.chatRows) == [opener.id, other.id], "Archive takes the Inbox row in each account")
        #expect(UndoService.shared.undoStack.count == 1, "one Undo entry for both accounts")
        for (id, pair) in expected {
            #expect(recordedTag(id).snapshot == pair, "the undo snapshot of \(id) holds \(pair)")
            #expect(recordedTag(id).member == pair, "the undo member of \(id) holds \(pair)")
        }

        let archived = [opener.id: Self.archivePath, other.id: Self.otherArchivePath]
        try await settle(pool, archived)
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(try await folders(pool, [opener.id, other.id]) == archived, "control: each went to its own Archive")
        await UndoService.shared.undo()
        try await settle(pool, [opener.id: Self.inboxPath, other.id: Self.inboxPath])
        await AccountManager.shared.awaitWriteQueueDrain()
        let restored = try await rows(pool, [opener.id, other.id])
        #expect(restored.count == 2)
        for row in restored {
            #expect(row.folderPath == Self.inboxPath, "control: Undo put \(row.id) back")
            #expect(TagPair(of: row) == expected[row.id], "Undo restores \(row.id)'s own newer tag, not \(TagPair(of: row))")
        }
    }
}
