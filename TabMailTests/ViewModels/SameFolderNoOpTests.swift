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
        header.rfc822MessageId = "<\(messageId)@same-folder.example.com>"
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

    /// Escaped-write hygiene barrier (ADR-IOS-058, PROJECT_MEMORY "drain-before-
    /// return" rule): enqueue a no-op onto `AccountManager.shared`'s FIFO write
    /// queue and await it — since the queue is strictly FIFO, every fold
    /// closure enqueued BEFORE this call is guaranteed to have executed by the
    /// time this returns. MUST run before a test's own `resetForTesting()`
    /// cleanup, or an escaped fold closure executes against the NEXT test's
    /// freshly-installed DB (composite ids reuse the same values across
    /// tests). Mirrors `InboxGestureActionTests.drainWriteQueue`.
    /// Round-2 audit: a single FIFO enqueue+await only guarantees closures
    /// already enqueued BEFORE this call have run — it does NOT guarantee the
    /// journal is empty. Two independently-created Tasks (a gesture site's
    /// `record()`, which spawns its own fold-executor Task, and this drain
    /// call) can reach the shared FIFO in EITHER order, so a fold closure the
    /// gesture just triggered may land AFTER this barrier's no-op closure and
    /// still be pending when the barrier returns — closing this window is the
    /// likely fix for the plan's known settle-flake. Loop the barrier until
    /// the journal reports fully drained (no pending records, no in-flight
    /// display holds/seqs); bounded so a genuine stuck-drain bug fails the
    /// test instead of hanging it forever.
    private func drainWriteQueue() async {
        var iterations = 0
        repeat {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                Task { await AccountManager.shared.enqueueWrite { cont.resume() } }
            }
            iterations += 1
        } while !AccountManager.shared.intentionJournal.isFullyDrainedForTesting() && iterations < 200
    }

    // MARK: - archiveIsNoOp / deleteIsNoOp predicates

    @Test("archiveIsNoOp is true in the archive folder, false in the inbox")
    @MainActor func archiveIsNoOpPredicate() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
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
            try? FileManager.default.removeItem(at: dir)
        }

        let trashedId = try insertMessage(pool, messageId: "t1", folder: trash, date: baseDate)
        let inboxId = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)

        let vm = InboxViewModel(folders: [trash], selection: .folder(trash))
        #expect(vm.deleteIsNoOp(trashedId) == true)
        #expect(vm.deleteIsNoOp(inboxId) == false)
        #expect(vm.deleteIsNoOp("nonexistent") == false)
    }

    @Test("blank role-folder paths refuse archive and delete before Undo or optimistic mutation")
    @MainActor func blankRoleFolderPathsAreSideEffectFree() async throws {
        let (pool, inbox, _, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            AccountManager.shared.intentionJournal.resetForTesting()
            UndoService.shared.dismissAll()
        }
        AccountManager.shared.intentionJournal.resetForTesting()
        UndoService.shared.dismissAll()

        let id = try insertMessage(pool, messageId: "blank-role-path", folder: inbox, date: baseDate)
        try await pool.writeWithoutTransaction { db in
            try db.execute(
                sql: "UPDATE folder SET path = '   ' WHERE accountId = ? AND role IN (?, ?)",
                arguments: ["acc1", FolderRole.archive.rawValue, FolderRole.trash.rawValue]
            )
        }

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.archiveIsNoOp(id))
        #expect(vm.deleteIsNoOp(id))
        #expect(!vm.deleteActionIsAdmissible(id))
        #expect(!vm.archive(id))
        #expect(vm.archiveThread([id]) == [id])
        let deleteResult = await vm.delete(id)
        let deleteThreadResult = await vm.deleteThread([id])
        #expect(!deleteResult)
        #expect(deleteThreadResult == [id])

        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay().isEmpty)
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().isEmpty)
        let operations = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(operations.isEmpty)
        let stored = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(stored?.folderId == inbox.id)
        #expect(stored?.folderPath == inbox.path)
    }

    // MARK: - InboxViewModel.archive / archiveThread guards

    @Test("archive() from the archive folder is a no-op — no undo, no overlay")
    @MainActor func archiveFromArchiveIsNoOp() async throws {
        let (pool, _, archive, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
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
            try? FileManager.default.removeItem(at: dir)
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
            try? FileManager.default.removeItem(at: dir)
        }

        let id = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        vm.archive(id)

        #expect(UndoService.shared.undoStack.count == 1)
        #expect(AccountManager.shared.snapshotOverlay()[id]?.folderId == archive.id)
        // Drain the FIFO before the cleanup below — see drainWriteQueue doc.
        await drainWriteQueue()
        // Clean up the overlay entry so later tests in this process aren't affected.
        AccountManager.shared.intentionJournal.resetForTesting()
    }

    // MARK: - InboxViewModel.delete / deleteThread guards

    @Test("delete() from the trash folder is a no-op — no undo, no overlay")
    @MainActor func deleteFromTrashIsNoOp() async throws {
        let (pool, _, _, trash, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
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
            try? FileManager.default.removeItem(at: dir)
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
            try? FileManager.default.removeItem(at: dir)
        }

        let id = try insertMessage(pool, messageId: "i1", folder: inbox, date: baseDate)

        let vm = InboxViewModel(folders: [inbox])
        vm.start()
        vm.loadInitialPage()

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        await vm.delete(id)

        #expect(UndoService.shared.undoStack.count == 1)
        #expect(AccountManager.shared.snapshotOverlay()[id]?.folderId == trash.id)
        // Drain the FIFO before the cleanup below — see drainWriteQueue doc.
        await drainWriteQueue()
        // Clean up the overlay entry so later tests in this process aren't affected.
        AccountManager.shared.intentionJournal.resetForTesting()
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
            try? FileManager.default.removeItem(at: dir)
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
            try? FileManager.default.removeItem(at: dir)
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
            try? FileManager.default.removeItem(at: dir)
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
            try? FileManager.default.removeItem(at: dir)
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
        #expect(ops[0].messageIds == ["i1@same-folder.example.com"])

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
}
