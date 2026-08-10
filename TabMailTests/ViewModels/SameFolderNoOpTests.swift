/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Same-folder actions must be no-ops: archive-from-Archive and
/// delete-from-Trash produce no undo entry, no overlay mutation, no queued
/// PendingOperation, and (at the view layer, via `archiveIsNoOp` /
/// `deleteIsNoOp`) no row dismissal. Previously the swipe made the
/// email/thread disappear from the folder list and queued a same-folder move.
@Suite("Same-Folder Action No-Op", .serialized, .processGlobalState)
struct SameFolderNoOpTests {

    // MARK: - Helpers

    /// Test DB with INBOX, Archive, and Trash folders for acc1.
    @MainActor
    private func makeTestDB() throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, trash: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)

        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }

        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }

        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let i = inbox
            try i.insert(db)
            let a = archive
            try a.insert(db)
            let t = trash
            try t.insert(db)
        }

        return (pool, inbox, archive, trash, dir, previous)
    }

    /// Insert a message into `folder`. Returns the stored composite id.
    @MainActor
    private func insertMessage(
        _ pool: DatabasePool,
        messageId: String,
        folder: Folder,
        date: Date,
        computedThreadId: String = ""
    ) throws -> String {
        var header = MessageHeader(
            messageId: messageId,
            subject: "Subject \(messageId)",
            from: "alice@test.com",
            fromAddress: "alice@test.com",
            to: "test@example.com",
            date: date,
            snippet: "Snippet for \(messageId)",
            folderId: folder.id,
            accountId: "acc1",
            folderPath: folder.path,
            isInInbox: folder.role == .inbox
        )
        header.computedThreadId = computedThreadId
        header.headerComplete = true
        try pool.writeWithoutTransaction { db in
            try header.insert(db)
        }
        let stored = try pool.read { db in
            try MessageHeader
                .filter(Column("messageId") == messageId && Column("accountId") == "acc1")
                .fetchOne(db)
        }
        return stored!.id
    }

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - archiveIsNoOp / deleteIsNoOp predicates

    @Test("archiveIsNoOp is true in the archive folder, false in the inbox")
    @MainActor func archiveIsNoOpPredicate() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let archivedId = try insertMessage(pool, messageId: "a1", folder: archive, date: baseDate)
        let inboxId = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)

        let vm = InboxViewModel(folders: [archive], selection: .folder(archive))
        #expect(vm.archiveIsNoOp(archivedId) == true)
        #expect(vm.archiveIsNoOp(inboxId) == false)
        #expect(vm.archiveIsNoOp("nonexistent") == false)
    }

    @Test("deleteIsNoOp is true in the trash folder, false in the inbox")
    @MainActor func deleteIsNoOpPredicate() async throws {
        let (pool, inbox, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let trashedId = try insertMessage(pool, messageId: "t1", folder: trash, date: baseDate)
        let inboxId = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)

        let vm = InboxViewModel(folders: [trash], selection: .folder(trash))
        #expect(vm.deleteIsNoOp(trashedId) == true)
        #expect(vm.deleteIsNoOp(inboxId) == false)
        #expect(vm.deleteIsNoOp("nonexistent") == false)
    }

    @Test("delete no-op follows the visual Undo location while the durable row catches up")
    @MainActor func deleteIsNoOpFollowsVisualUndoLocation() async throws {
        let (pool, inbox, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id = try insertMessage(pool, messageId: "t1", folder: trash, date: baseDate)
        defer { AccountManager.shared.removeOverlayEntries(ids: [id]) }

        let vm = InboxViewModel(folders: [inbox, trash])
        AccountManager.shared.registerMutation(
            id: id,
            mutation: .init(
                folderId: inbox.id,
                folderPath: inbox.path,
                isInInbox: true
            )
        )

        // Slow IMAP case from logmain.log: Undo has restored the row on screen,
        // while the provider/DB move still names Trash. A new Delete is a valid
        // opposite intent and must reach the existing move coalescer.
        #expect(vm.deleteIsNoOp(id) == false)

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }
        #expect(await vm.delete(id) == true)
        #expect(UndoService.shared.undoStack.last?.originalFolderPath == inbox.path)
        #expect(AccountManager.shared.snapshotOverlay()[id]?.folderPath == trash.path)
    }

    @Test("delete no-op rejects the visual trash location before the durable row catches up")
    @MainActor func deleteIsNoOpRejectsVisualTrashLocation() async throws {
        let (pool, inbox, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)
        defer { AccountManager.shared.removeOverlayEntries(ids: [id]) }

        let vm = InboxViewModel(folders: [inbox, trash])
        AccountManager.shared.registerMutation(
            id: id,
            mutation: .init(
                folderId: trash.id,
                folderPath: trash.path,
                isInInbox: false
            )
        )

        #expect(vm.deleteIsNoOp(id) == true)
    }

    // MARK: - InboxViewModel.archive / archiveThread guards

    @Test("archive() from the archive folder is a no-op — no undo, no overlay")
    @MainActor func archiveFromArchiveIsNoOp() async throws {
        let (pool, _, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id = try insertMessage(pool, messageId: "a1", folder: archive, date: baseDate)

        let vm = InboxViewModel(folders: [archive], selection: .folder(archive))
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 1)

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        vm.archive(id)

        // No undo entry, no overlay mutation, message untouched.
        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        let stored = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(stored?.folderId == archive.id)
    }

    @Test("archiveThread() from the archive folder is a no-op — no undo, no overlay")
    @MainActor func archiveThreadFromArchiveIsNoOp() async throws {
        let (pool, _, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id1 = try insertMessage(pool, messageId: "t1", folder: archive, date: baseDate, computedThreadId: "thread-1")
        let id2 = try insertMessage(pool, messageId: "t2", folder: archive, date: baseDate.addingTimeInterval(60), computedThreadId: "thread-1")

        let vm = InboxViewModel(folders: [archive], selection: .folder(archive))
        vm.start()
        vm.loadInitialPage()

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        vm.archiveThread([id1, id2])

        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[id1] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[id2] == nil)
    }

    @Test("archive() from the inbox still archives — undo entry + overlay registered")
    @MainActor func archiveFromInboxStillWorks() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        // The RECORDED side of the un-hide contract: the caller hid this row
        // optimistically, and a `true` return is what lets it stay hidden.
        #expect(vm.archive(id) == true)

        #expect(UndoService.shared.undoStack.count == 1)
        #expect(AccountManager.shared.snapshotOverlay()[id]?.folderId == archive.id)
        // Clean up the overlay entry so later tests in this process aren't affected.
        AccountManager.shared.removeOverlayEntries(ids: [id])
    }

    // MARK: - InboxViewModel.delete / deleteThread guards

    @Test("delete() from the trash folder is a no-op — no undo, no overlay")
    @MainActor func deleteFromTrashIsNoOp() async throws {
        let (pool, _, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id = try insertMessage(pool, messageId: "t1", folder: trash, date: baseDate)

        let vm = InboxViewModel(folders: [trash], selection: .folder(trash))
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 1)

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        await vm.delete(id)

        // No undo entry, no overlay mutation, message untouched.
        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        let stored = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(stored?.folderId == trash.id)
    }

    @Test("deleteThread() from the trash folder is a no-op — no undo, no overlay")
    @MainActor func deleteThreadFromTrashIsNoOp() async throws {
        let (pool, _, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id1 = try insertMessage(pool, messageId: "t1", folder: trash, date: baseDate, computedThreadId: "thread-1")
        let id2 = try insertMessage(pool, messageId: "t2", folder: trash, date: baseDate.addingTimeInterval(60), computedThreadId: "thread-1")

        let vm = InboxViewModel(folders: [trash], selection: .folder(trash))
        vm.start()
        vm.loadInitialPage()

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        await vm.deleteThread([id1, id2])

        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[id1] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[id2] == nil)
    }

    @Test("delete() from the inbox still deletes — undo entry + overlay registered")
    @MainActor func deleteFromInboxStillWorks() async throws {
        let (pool, inbox, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        // The RECORDED side of the un-hide contract — see archiveFromInboxStillWorks.
        #expect(await vm.delete(id) == true)

        #expect(UndoService.shared.undoStack.count == 1)
        #expect(AccountManager.shared.snapshotOverlay()[id]?.folderId == trash.id)
        // Clean up the overlay entry so later tests in this process aren't affected.
        AccountManager.shared.removeOverlayEntries(ids: [id])
    }

    // MARK: - Duplicate-role folders (iCloud "Trash" + "Deleted Messages")

    /// An account can carry MORE THAN ONE folder per role; the canonical
    /// `lookupFolderPath`/`lookupFolder` resolution is `fetchOne`-arbitrary
    /// among them, so a path-only comparison can miss the folder the user is
    /// actually viewing. The role-based check must make delete a no-op in
    /// EVERY trash-role folder.
    @Test("delete is a no-op in every trash-role folder when duplicates exist")
    @MainActor func deleteInDuplicateTrashIsNoOp() async throws {
        let (pool, _, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // Second trash-role folder, mirroring the known iCloud situation.
        let deletedMessages = Folder(name: "Deleted Messages", path: "Deleted Messages", role: .trash, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in
            let f = deletedMessages
            try f.insert(db)
        }

        let inTrash = try insertMessage(pool, messageId: "t1", folder: trash, date: baseDate)
        let inDeleted = try insertMessage(pool, messageId: "d1", folder: deletedMessages, date: baseDate)

        let vm = InboxViewModel(folders: [trash, deletedMessages], selection: .folder(trash))
        // Whichever folder the canonical fetchOne returns, BOTH must be no-ops.
        #expect(vm.deleteIsNoOp(inTrash) == true)
        #expect(vm.deleteIsNoOp(inDeleted) == true)

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        await vm.delete(inTrash)
        await vm.delete(inDeleted)
        await vm.deleteThread([inTrash, inDeleted])

        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[inTrash] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[inDeleted] == nil)
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty)
    }

    @Test("AccountManager.delete drops messages already in any trash-role folder")
    @MainActor func managerDeleteDropsDuplicateTrash() async throws {
        let (pool, _, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let deletedMessages = Folder(name: "Deleted Messages", path: "Deleted Messages", role: .trash, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in
            let f = deletedMessages
            try f.insert(db)
        }

        let inTrash = try insertMessage(pool, messageId: "t1", folder: trash, date: baseDate)
        let inDeleted = try insertMessage(pool, messageId: "d1", folder: deletedMessages, date: baseDate)
        let msgs = try await pool.read { db in
            try MessageHeader.filter([inTrash, inDeleted].contains(Column("id"))).fetchAll(db)
        }
        #expect(msgs.count == 2)

        await AccountManager.shared.delete(msgs)

        // Both messages already sit in trash-role folders — nothing queued,
        // nothing moved (no cross-trash "Trash" → "Deleted Messages" hop).
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty)
        let stored = try await pool.read { db in
            try MessageHeader.filter([inTrash, inDeleted].contains(Column("id"))).fetchAll(db)
        }
        #expect(Set(stored.map(\.folderId)) == Set([trash.id, deletedMessages.id]))
    }

    // MARK: - AccountManager.move same-folder filter

    @Test("AccountManager.move drops same-folder messages — no PendingOperation")
    @MainActor func moveSameFolderIsDropped() async throws {
        let (pool, _, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id = try insertMessage(pool, messageId: "a1", folder: archive, date: baseDate)
        let msg = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }!

        await AccountManager.shared.move([msg], to: archive.path)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty)
        let stored = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(stored?.folderId == archive.id)
    }

    @Test("AccountManager.move with a mixed batch moves only the non-same-folder messages")
    @MainActor func moveMixedBatchFiltersSameFolder() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let archivedId = try insertMessage(pool, messageId: "a1", folder: archive, date: baseDate)
        let inboxId = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)
        let archivedMsg = try await pool.read { db in try MessageHeader.fetchOne(db, key: archivedId) }!
        let inboxMsg = try await pool.read { db in try MessageHeader.fetchOne(db, key: inboxId) }!

        await AccountManager.shared.move([archivedMsg, inboxMsg], to: archive.path)

        // Only the inbox message produced an operation; the archived one was dropped.
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].messageIds == [inboxMsg.stableId])

        // The inbox message moved optimistically; the archived one is untouched.
        let movedInbox = try await pool.read { db in
            try MessageHeader.filter(Column("messageId") == "i1").fetchOne(db)
        }
        #expect(movedInbox?.folderId == archive.id)
        let untouched = try await pool.read { db in
            try MessageHeader.filter(Column("messageId") == "a1").fetchOne(db)
        }
        #expect(untouched?.folderId == archive.id)
    }

    // MARK: - Un-hide contract (T4.V1): a NOT-RECORDED action must not leave
    // the row hidden. The swipe/dismiss sites insert the id into
    // `dismissedMessages` BEFORE calling the ViewModel, so a call that records
    // nothing and reports nothing back makes the message vanish from the list
    // forever with no undo entry to bring it back. These pin the report, which
    // is the only signal the View has.

    /// Drop `folder`'s row so the account genuinely has no folder of that role.
    /// This is the un-hide contract's live (non-racy) trigger: `archiveIsNoOp` /
    /// `deleteIsNoOp` both return FALSE with no destination folder, so the
    /// View's pre-check PASSES and the row is hidden — only the return value
    /// can bring it back.
    @MainActor
    private func dropFolder(_ pool: DatabasePool, _ folder: Folder) throws {
        try pool.writeWithoutTransaction { db in
            _ = try Folder.filter(Column("id") == folder.id).deleteAll(db)
        }
    }

    @Test("archive() reports NOT-recorded when the account has no archive folder — the hidden row must come back, and no undo entry is stranded")
    @MainActor func archiveWithNoArchiveFolderReportsNotRecorded() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        try dropFolder(pool, archive)

        let id = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        // Non-vacuity: the View's own pre-check does NOT suppress this gesture,
        // so the row IS hidden before the ViewModel call runs.
        #expect(vm.archiveIsNoOp(id) == false)

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        #expect(vm.archive(id) == false)

        // Nothing recorded: no undo entry to strand, no overlay mutation, and
        // the message is exactly where it was.
        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        let stored = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(stored?.folderId == inbox.id)
    }

    @Test("delete() reports NOT-recorded when the account has no trash folder — the hidden row must come back, and no undo entry is stranded")
    @MainActor func deleteWithNoTrashFolderReportsNotRecorded() async throws {
        let (pool, inbox, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        try dropFolder(pool, trash)

        let id = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        #expect(vm.deleteIsNoOp(id) == false)

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        #expect(await vm.delete(id) == false)

        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        let stored = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(stored?.folderId == inbox.id)
    }

    @Test("archiveThread reports EVERY member skipped when the account has no archive folder — every hidden row comes back, none stranded")
    @MainActor func archiveThreadWithNoArchiveFolderReportsAllSkipped() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        try dropFolder(pool, archive)

        let id1 = try insertMessage(pool, messageId: "t1", folder: inbox, date: baseDate, computedThreadId: "thread-1")
        let id2 = try insertMessage(pool, messageId: "t2", folder: inbox, date: baseDate.addingTimeInterval(60), computedThreadId: "thread-1")

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        // Non-vacuity: both members classify as actionable, so both are hidden.
        #expect(vm.actionableArchiveIds([id1, id2]) == [id1, id2])

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        let skipped = vm.archiveThread([id1, id2])

        #expect(Set(skipped) == Set([id1, id2]))
        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[id1] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[id2] == nil)
    }

    @Test("deleteThread reports EVERY member skipped when the account has no trash folder — every hidden row comes back, none stranded")
    @MainActor func deleteThreadWithNoTrashFolderReportsAllSkipped() async throws {
        let (pool, inbox, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        try dropFolder(pool, trash)

        let id1 = try insertMessage(pool, messageId: "t1", folder: inbox, date: baseDate, computedThreadId: "thread-1")
        let id2 = try insertMessage(pool, messageId: "t2", folder: inbox, date: baseDate.addingTimeInterval(60), computedThreadId: "thread-1")

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        #expect(vm.actionableDeleteIds([id1, id2]) == [id1, id2])

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        let skipped = await vm.deleteThread([id1, id2])

        #expect(Set(skipped) == Set([id1, id2]))
        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[id1] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[id2] == nil)
    }

    @Test("archiveThread reports NOTHING skipped when every member is actionable — the hidden rows legitimately stay hidden under one undo entry")
    @MainActor func archiveThreadReportsNothingSkippedWhenRecorded() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id1 = try insertMessage(pool, messageId: "t1", folder: inbox, date: baseDate, computedThreadId: "thread-1")
        let id2 = try insertMessage(pool, messageId: "t2", folder: inbox, date: baseDate.addingTimeInterval(60), computedThreadId: "thread-1")

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }
        defer { AccountManager.shared.removeOverlayEntries(ids: [id1, id2]) }

        let skipped = vm.archiveThread([id1, id2])

        // Two-sided against the "always report skipped" degenerate fix: an
        // un-hide-everything implementation fails HERE.
        #expect(skipped.isEmpty)
        #expect(UndoService.shared.undoStack.count == 1)
        #expect(AccountManager.shared.snapshotOverlay()[id1]?.folderId == archive.id)
        #expect(AccountManager.shared.snapshotOverlay()[id2]?.folderId == archive.id)
    }

    @Test("archiveThread reports an unresolvable member skipped while still recording the resolvable one")
    @MainActor func archiveThreadReportsUnresolvableMemberSkipped() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let realId = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate, computedThreadId: "thread-1")
        let ghostId = "acc1:INBOX:does-not-exist"

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        // Non-vacuity: an unresolvable id is NOT a no-op, so the View hides it
        // too — only the skipped report can bring that row back.
        #expect(vm.actionableArchiveIds([realId, ghostId]) == [realId, ghostId])

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }
        defer { AccountManager.shared.removeOverlayEntries(ids: [realId]) }

        let skipped = vm.archiveThread([realId, ghostId])

        #expect(skipped == [ghostId])
        #expect(UndoService.shared.undoStack.count == 1)
        #expect(AccountManager.shared.snapshotOverlay()[realId]?.folderId == archive.id)
    }

    // MARK: - Per-member thread classification (T4.V16)
    //
    // A thread can span folders of different roles. Deciding the whole thread
    // from the REPRESENTATIVE's folder role turned a mixed [Archive, Inbox]
    // thread into a whole-thread NO-OP, silently dropping the inbox member's
    // archive/delete intention. Classification is per member; a settled member
    // stays VISIBLE and is never mutated (C3).

    @Test("a thread spanning Inbox and Archive archives its inbox member instead of no-opping the whole thread — and never touches the archived member")
    @MainActor func mixedInboxArchiveThreadArchivesItsInboxMember() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // The ARCHIVE-resident member is first, i.e. the thread representative —
        // exactly the shape the old whole-thread guard short-circuited on.
        let archivedId = try insertMessage(pool, messageId: "a1", folder: archive, date: baseDate.addingTimeInterval(60), computedThreadId: "thread-1")
        let inboxId = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate, computedThreadId: "thread-1")

        let vm = InboxViewModel(folders: [inbox, archive])
        vm.start()
        vm.loadInitialPage()

        // The pre-fix whole-thread guard consulted exactly this predicate on the
        // representative and returned early for the WHOLE thread.
        #expect(vm.archiveIsNoOp(archivedId) == true)

        // Per-member: only the inbox member is actionable, and it is the only
        // row the caller hides.
        let actionable = vm.actionableArchiveIds([archivedId, inboxId])
        #expect(actionable == [inboxId])
        guard actionable == [inboxId] else { return }

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }
        defer { AccountManager.shared.removeOverlayEntries(ids: [inboxId]) }

        let skipped = vm.archiveThread(actionable)

        // The inbox member's intention SURVIVES the mixed thread.
        #expect(skipped.isEmpty)
        #expect(UndoService.shared.undoStack.count == 1)
        guard UndoService.shared.undoStack.count == 1 else { return }
        #expect(UndoService.shared.undoStack[0].messages.map(\.id) == [inboxId])
        #expect(AccountManager.shared.snapshotOverlay()[inboxId]?.folderId == archive.id)

        // C3: the settled member was never classified, never hidden, never
        // mutated — no overlay entry and no folder change.
        #expect(AccountManager.shared.snapshotOverlay()[archivedId] == nil)
        let untouched = try await pool.read { db in try MessageHeader.fetchOne(db, key: archivedId) }
        #expect(untouched?.folderId == archive.id)
    }

    @Test("a thread whose every member is already archived stays a whole-thread archive no-op — nothing is classified actionable, nothing is recorded")
    @MainActor func fullyArchivedThreadStaysAWholeThreadNoOp() async throws {
        let (pool, _, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id1 = try insertMessage(pool, messageId: "a1", folder: archive, date: baseDate, computedThreadId: "thread-1")
        let id2 = try insertMessage(pool, messageId: "a2", folder: archive, date: baseDate.addingTimeInterval(60), computedThreadId: "thread-1")

        let vm = InboxViewModel(folders: [archive], selection: .folder(archive))
        vm.start()
        vm.loadInitialPage()

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        // The CONTROL for the mixed-thread case: an empty actionable set is the
        // caller's "hide nothing, do nothing" signal.
        #expect(vm.actionableArchiveIds([id1, id2]).isEmpty)
        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[id1] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[id2] == nil)
    }

    @Test("a thread spanning Inbox and Trash deletes its inbox member instead of no-opping the whole thread — and never touches the trashed member")
    @MainActor func mixedInboxTrashThreadDeletesItsInboxMember() async throws {
        let (pool, inbox, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let trashedId = try insertMessage(pool, messageId: "t1", folder: trash, date: baseDate.addingTimeInterval(60), computedThreadId: "thread-1")
        let inboxId = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate, computedThreadId: "thread-1")

        let vm = InboxViewModel(folders: [inbox, trash])
        vm.start()
        vm.loadInitialPage()

        #expect(vm.deleteIsNoOp(trashedId) == true)

        let actionable = vm.actionableDeleteIds([trashedId, inboxId])
        #expect(actionable == [inboxId])
        guard actionable == [inboxId] else { return }

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }
        defer { AccountManager.shared.removeOverlayEntries(ids: [inboxId]) }

        let skipped = await vm.deleteThread(actionable)

        #expect(skipped.isEmpty)
        #expect(UndoService.shared.undoStack.count == 1)
        guard UndoService.shared.undoStack.count == 1 else { return }
        #expect(UndoService.shared.undoStack[0].messages.map(\.id) == [inboxId])
        #expect(AccountManager.shared.snapshotOverlay()[inboxId]?.folderId == trash.id)

        // C3: the trash-resident member is untouched.
        #expect(AccountManager.shared.snapshotOverlay()[trashedId] == nil)
        let untouched = try await pool.read { db in try MessageHeader.fetchOne(db, key: trashedId) }
        #expect(untouched?.folderId == trash.id)
    }

    @Test("a thread whose every member is already in trash stays a whole-thread delete no-op — nothing is classified actionable, nothing is recorded")
    @MainActor func fullyTrashedThreadStaysAWholeThreadNoOp() async throws {
        let (pool, _, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id1 = try insertMessage(pool, messageId: "t1", folder: trash, date: baseDate, computedThreadId: "thread-1")
        let id2 = try insertMessage(pool, messageId: "t2", folder: trash, date: baseDate.addingTimeInterval(60), computedThreadId: "thread-1")

        let vm = InboxViewModel(folders: [trash], selection: .folder(trash))
        vm.start()
        vm.loadInitialPage()

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        #expect(vm.actionableDeleteIds([id1, id2]).isEmpty)
        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[id1] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[id2] == nil)
    }

    // MARK: - Un-hide contract on the MOVE path
    //
    // The same defect class the archive/delete un-hide contract above closes,
    // on the move-sheet path: `InboxView.performSingleMove` /
    // `performThreadMove` hide the row(s) BEFORE calling the ViewModel, and the
    // ViewModel used to return Void — so a call that recorded nothing left the
    // message vanished from the list forever with no undo entry to bring it
    // back. Unlike archive/delete the move sheet has NO no-op pre-check at all,
    // so the return value is the ONLY signal the View has.

    @Test("move() reports NOT-recorded when the message no longer resolves — the hidden row must come back, and no undo entry is stranded")
    @MainActor func moveWithUnresolvableMessageReportsNotRecorded() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // A real sibling keeps the list state realistic; the gesture targets an
        // id that vanished between the picker opening and the tap — the live
        // (non-racy) trigger for this path.
        _ = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)
        let ghostId = "acc1:INBOX:does-not-exist"

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        // Non-vacuity: nothing suppresses this gesture at the View layer, so
        // the row IS hidden before the ViewModel call runs.
        #expect(vm.lookupMessage(ghostId) == nil)

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        #expect(vm.move(ghostId, toFolderPath: archive.path) == false)

        // Nothing recorded: no undo entry to strand and no overlay mutation.
        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[ghostId] == nil)
    }

    @Test("move() reports RECORDED for a resolvable message — the hidden row legitimately stays hidden and an undo entry exists")
    @MainActor func moveReportsRecordedForResolvableMessage() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let id = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }
        defer { AccountManager.shared.removeOverlayEntries(ids: [id]) }

        // Two-sided against the degenerate "always report not-recorded"
        // (un-hide always) fix: that implementation fails HERE, and it would
        // also strand the undo entry this asserts against a visible row.
        #expect(vm.move(id, toFolderPath: archive.path) == true)
        #expect(UndoService.shared.undoStack.count == 1)
        #expect(AccountManager.shared.snapshotOverlay()[id]?.folderId == archive.id)
    }

    @Test("moveThread reports an unresolvable member skipped while still recording the resolvable one — and never touches the skipped member")
    @MainActor func moveThreadReportsUnresolvableMemberSkipped() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let realId = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate, computedThreadId: "thread-1")
        let ghostId = "acc1:INBOX:does-not-exist"

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        // Non-vacuity: `performThreadMove` hides EVERY member unconditionally,
        // so the unresolvable one is hidden too — only the skipped report can
        // bring that row back.
        #expect(vm.lookupMessage(ghostId) == nil)

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }
        defer { AccountManager.shared.removeOverlayEntries(ids: [realId]) }

        let skipped = vm.moveThread([realId, ghostId], toFolderPath: archive.path)

        // EXACTLY the un-recorded member is reported (so exactly its row
        // un-hides); the recorded one legitimately stays hidden under an undo
        // entry — the mixed case is two-sided on its own.
        #expect(skipped == [ghostId])
        #expect(UndoService.shared.undoStack.count == 1)
        guard UndoService.shared.undoStack.count == 1 else { return }
        #expect(UndoService.shared.undoStack[0].messages.map(\.id) == [realId])
        #expect(AccountManager.shared.snapshotOverlay()[realId]?.folderId == archive.id)
        // C3: the skipped member was never mutated.
        #expect(AccountManager.shared.snapshotOverlay()[ghostId] == nil)
    }

    @Test("moveThread reports EVERY member skipped when nothing resolves — every hidden row comes back, none stranded")
    @MainActor func moveThreadWithNothingResolvableReportsAllSkipped() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ghost1 = "acc1:INBOX:gone-1"
        let ghost2 = "acc1:INBOX:gone-2"

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        // The whole-call abort leg: `guard let first = messages.first` used to
        // `return` with the caller holding every id hidden.
        let skipped = vm.moveThread([ghost1, ghost2], toFolderPath: archive.path)

        #expect(Set(skipped) == Set([ghost1, ghost2]))
        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[ghost1] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[ghost2] == nil)
    }
}
