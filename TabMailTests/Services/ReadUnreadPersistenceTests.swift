/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Regression tests for commit b804a42: "Remove read/unread toggling from the
/// undo stack." The commit deleted ~199 test lines that previously exercised
/// `.toggleRead` in UndoService and needs replacement coverage proving the new
/// path still persists the user's intent.
///
/// The contract after b804a42:
///   1. `UndoableActionType` has no `.toggleRead` case — read/unread never
///      pushes to the 20-entry undo stack. Shake-to-undo reaches the last
///      destructive action instead.
///   2. `markRead` / `markUnread` still flip `MessageHeader.isRead` in GRDB and
///      insert a `PendingOperation`, so sync happens asynchronously and the
///      user's intent survives crash/kill/disconnection.
@Suite("Read/unread persistence after undo-stack removal", .serialized)
struct ReadUnreadPersistenceTests {

    // MARK: - Compile-time invariant: .toggleRead does not exist

    @Test("UndoableActionType has no .toggleRead case — only .move is undoable")
    func noToggleReadCase() {
        // Exhaustive switch over UndoableActionType. If a future refactor adds
        // `.toggleRead(wasRead: Bool)` back, this switch stops compiling and
        // forces a reviewer to revisit the b804a42 decision.
        let action = UndoableActionType.move(fromPath: "INBOX", toPath: "Archive")
        switch action {
        case .move(let from, let to):
            #expect(from == "INBOX")
            #expect(to == "Archive")
        }
    }

    // MARK: - Persistence path: DB + PendingOperation

    @MainActor
    private func makeTestDB() throws -> (pool: DatabasePool, folder: Folder, dir: URL, previous: AppDatabase?) {
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

            var folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
            try folder.insert(db)
        }
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        return (pool, folder, dir, previous)
    }

    /// Teardown shared by every test. Ports `InboxGestureActionTests` /
    /// `CoordinatedToolActionTests`' guarded restore: the REAL
    /// `markRead`/`markUnread` paths driven here spawn unstructured
    /// recount/drain Tasks (drainPendingQueue, `UnreadCountManager` recounts)
    /// that outlive the test body — they can run AFTER the defers. Restore a
    /// real predecessor when present, but retain this installed
    /// fixture until process exit in either case so post-defer work never
    /// reaches a closed pool.
    private func restoreTestDB(pool: DatabasePool, previous: AppDatabase?, dir: URL) {
        InstalledTestDatabaseLifetime.finish(
            previous: previous,
            pool: pool,
            directory: dir
        )
    }

    @MainActor
    private func insertMessage(_ pool: DatabasePool, messageId: String, isRead: Bool) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: "Subject",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "me@example.com",
            date: Date(timeIntervalSince1970: 1_800_000_000),
            snippet: "body",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.isRead = isRead
        header.headerComplete = true
        try pool.writeWithoutTransaction { db in try header.insert(db) }
        let stored = try pool.read { db in
            try MessageHeader
                .filter(Column("messageId") == messageId && Column("accountId") == "acc1")
                .fetchOne(db)
        }
        return stored!
    }

    @Test("markRead persists isRead=true in GRDB and inserts a PendingOperation(.markRead)")
    @MainActor
    func markReadPersists() async throws {
        let (pool, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let header = try insertMessage(pool, messageId: "rru-1", isRead: false)
        #expect(header.isRead == false)

        // Call the real async extension that toggleRead invokes. Use a fresh
        // stackBefore snapshot so we can assert no undo push occurred.
        let stackBefore = UndoService.shared.undoStack.count
        await AccountManager.shared.markRead([header])

        // DB state: isRead flipped.
        let refetched = try await pool.read { db in
            try MessageHeader.filter(Column("id") == header.id).fetchOne(db)
        }
        #expect(refetched?.isRead == true)

        // PendingOperation inserted with the correct type + stableId.
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .markRead)
        #expect(ops[0].messageIds == [header.stableId])
        #expect(ops[0].accountId == "acc1")
        #expect(ops[0].folderPath == "INBOX")

        // Undo stack MUST NOT receive a toggleRead entry — commit b804a42.
        #expect(UndoService.shared.undoStack.count == stackBefore)
    }

    @Test("markUnread persists isRead=false in GRDB and inserts a PendingOperation(.markUnread)")
    @MainActor
    func markUnreadPersists() async throws {
        let (pool, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let header = try insertMessage(pool, messageId: "rru-2", isRead: true)
        #expect(header.isRead == true)

        let stackBefore = UndoService.shared.undoStack.count
        await AccountManager.shared.markUnread([header])

        let refetched = try await pool.read { db in
            try MessageHeader.filter(Column("id") == header.id).fetchOne(db)
        }
        #expect(refetched?.isRead == false)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .markUnread)
        #expect(ops[0].messageIds == [header.stableId])

        #expect(UndoService.shared.undoStack.count == stackBefore)
    }

    @Test("Round-trip: markRead then markUnread leaves isRead=false and two pending ops (latest wins remotely)")
    @MainActor
    func roundTripPersistsBothOps() async throws {
        let (pool, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let header = try insertMessage(pool, messageId: "rru-3", isRead: false)

        await AccountManager.shared.markRead([header])
        // Re-read so the second call sees isRead=true as the "before" state.
        let afterRead = try await pool.read { db in
            try MessageHeader.filter(Column("id") == header.id).fetchOne(db)
        }
        #expect(afterRead?.isRead == true)

        await AccountManager.shared.markUnread([afterRead!])

        let final = try await pool.read { db in
            try MessageHeader.filter(Column("id") == header.id).fetchOne(db)
        }
        #expect(final?.isRead == false)

        // Both ops queued in order — drain will execute them FIFO, and the
        // remote-wins contract means the final state remote reaches is
        // "unread" (the user's last intent).
        let ops = try await pool.read { db in
            try PendingOperation.order(Column("createdAt")).fetchAll(db)
        }
        #expect(ops.count == 2)
        #expect(ops[0].type == .markRead)
        #expect(ops[1].type == .markUnread)
    }
}
