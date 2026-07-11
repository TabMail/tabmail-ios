/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Pins `NotificationActionRouter.execute` (the AppDelegate notification-action
/// dispatch fix): ARCHIVE/DELETE/MARK_READ notification-button taps used to
/// INSERT raw SQL into a column (`messageIds`) that doesn't exist in the
/// `pendingOperation` schema (the column is `messageIdsJSON`) and omitted the
/// NOT-NULL `folderPath`/`createdAt` columns — the INSERT always threw,
/// silently dropping the user's tap. Even a successful insert would have been
/// inert: `.archive`/`.delete` are legacy no-op `OperationType`s in the drain
/// (`AccountManagerQueue.executeOperation`).
///
/// Five properties are pinned:
/// 1. A durable header + ARCHIVE routes through the coordinated move path —
///    the row moves to the Archive folder, exactly one `.move`
///    PendingOperation is queued with the ORIGINAL folder as its source, and
///    the overlay refcount drains to zero.
/// 2. No header anywhere (cold background launch, staged cache empty) +
///    ARCHIVE falls back to directly queuing a `.move` PendingOperation with
///    folderPath == inbox path, destinationPath == archive path, messageIds
///    == [messageId].
/// 3. No header anywhere + MARK_READ falls back to a `.markRead` op with
///    folderPath == inbox path.
/// 4. A durable header + DELETE routes through the coordinated move path —
///    the row moves to Trash and exactly one `.move` op targets Trash.
/// 5. Same UID in two folders (IMAP UIDs are folder-scoped): ARCHIVE acts on
///    the INBOX row only — the other folder's unrelated row is untouched
///    (the round-3 `isInInbox = 1` scoping regression pin).
///
/// `.serialized`: tests swap `AppDatabase.shared` and drive `AccountManager
/// .shared`'s write paths — mirrors `CoordinatedToolActionTests`.
@Suite("NotificationActionRouter — notification-action dispatch fix", .serialized)
struct NotificationActionRouterTests {

    // MARK: - Harness (mirrors CoordinatedToolActionTests.swift)

    private func makeTestDB() throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, trash: Folder, dir: URL, previous: AppDatabase?) {
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
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let i = inbox; try i.insert(db)
            let a = archive; try a.insert(db)
            let t = trash; try t.insert(db)
        }
        return (pool, inbox, archive, trash, dir, previous)
    }

    /// A durable, query-visible header (`headerComplete = true`) for a folder.
    private func makeDurableHeader(folder: Folder, messageId: String) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path,
            isInInbox: folder.role == .inbox
        )
        h.headerComplete = true
        return h
    }

    /// Teardown shared by every test. Mirrors `CoordinatedToolActionTests.restoreTestDB`:
    /// production paths driven here (drainPendingQueue, unread recounts) fire
    /// unstructured background Tasks the drain barrier cannot join, so they can run
    /// AFTER the defers — leave the test DB alive when there's no previous one to
    /// restore, rather than let `AppDatabase.rawPool`'s force-unwrap crash the process.
    private func restoreTestDB(previous: AppDatabase?, dir: URL) {
        if previous != nil {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Cold-path tests must not accidentally resolve via a staged row left
    /// over from another test — the message ids used below are unique to this
    /// suite, but clearing the global keeps the "no header anywhere" premise
    /// explicit and mirrors `InboxGestureActionTests.resetStagedGlobal`.
    private func resetStagedGlobal() {
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
    }

    // MARK: - (1) Durable header + ARCHIVE

    @Test("durable header + ARCHIVE routes through AccountManager.archive: row moves to Archive, ONE .move PendingOperation is queued with the original folder as source")
    func durableHeaderArchiveRoutesThroughManager() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        let header = makeDurableHeader(folder: inbox, messageId: "m-archive-durable")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await NotificationActionRouter.execute(actionId: "ARCHIVE", messageId: "m-archive-durable", accountId: "acc1")

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id)
        #expect(final?.folderPath == archive.path)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == inbox.path, "source folderPath must be the ORIGINAL (inbox) path")
        #expect(ops[0].destinationPath == archive.path)
        #expect(ops[0].messageIds == ["m-archive-durable"])

        // ARCHIVE now dispatches via `performCoordinatedRoleMove`, which awaits
        // durable completion — by the time `execute` returns, its retain/release
        // must have fully drained (no stranded overlay entry).
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "overlay refcount must drain to zero once performCoordinatedRoleMove's queued closure completes")
    }

    // MARK: - (2) No header anywhere + ARCHIVE

    @Test("no header anywhere (cold background launch) + ARCHIVE queues a .move PendingOperation directly: folderPath == inbox path, destinationPath == archive path, messageIds == [messageId]")
    func noHeaderArchiveQueuesColdMoveOp() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        // HONESTY NOTE: `NotificationActionRouter.execute` runs one
        // `NSEMergeCoordinator.shared.merge()` pass before falling back to
        // `queueColdPendingOperation` (see the enum doc comment in
        // AppDelegate.swift) — in a real cold-background-launch, that merge
        // pass can pull an already-staged (App Group) row durable and the
        // retried lookup succeeds, dispatching through the coordinated
        // move path instead of the cold fallback. In the TEST HOST, `merge()`
        // no-ops (no app-group container), so this test can only ever reach
        // the cold-fallback branch — it pins the full-cold-miss contract
        // below; the merge-succeeds recovery branch is structurally
        // unreachable in this harness (same convention as
        // InboxGestureActionTests.swift's staged-row HONESTY NOTE, ~line 1467).
        await NotificationActionRouter.execute(actionId: "ARCHIVE", messageId: "m-cold-archive", accountId: "acc1")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == inbox.path)
        #expect(ops[0].destinationPath == archive.path)
        #expect(ops[0].messageIds == ["m-cold-archive"])
        #expect(ops[0].accountId == "acc1")

        let headerCount = try await pool.read { db in try MessageHeader.fetchCount(db) }
        #expect(headerCount == 0, "no header was ever created — the cold path never synthesizes one")
    }

    // MARK: - (3) No header anywhere + MARK_READ

    @Test("no header anywhere + MARK_READ queues a .markRead PendingOperation directly against the inbox path")
    func noHeaderMarkReadQueuesColdMarkReadOp() async throws {
        let (pool, inbox, _, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        // HONESTY NOTE (see the identical note on noHeaderArchiveQueuesColdMoveOp
        // above): the test host's `NSEMergeCoordinator.merge()` no-ops (no
        // app-group container), so this test pins only the full-cold-miss
        // contract — the merge-succeeds recovery branch (a staged row becomes
        // durable and the retried lookup finds it) is structurally
        // unreachable in this harness.
        await NotificationActionRouter.execute(actionId: "MARK_READ", messageId: "m-cold-markread", accountId: "acc1")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .markRead)
        #expect(ops[0].folderPath == inbox.path)
        #expect(ops[0].destinationPath == nil)
        #expect(ops[0].messageIds == ["m-cold-markread"])
    }

    // MARK: - (4) Durable header + DELETE

    @Test("durable header + DELETE routes through AccountManager.delete: row moves to Trash, ONE .move PendingOperation targets Trash")
    func durableHeaderDeleteRoutesThroughManager() async throws {
        let (pool, inbox, _, trash, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        let header = makeDurableHeader(folder: inbox, messageId: "m-delete-durable")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await NotificationActionRouter.execute(actionId: "DELETE", messageId: "m-delete-durable", accountId: "acc1")

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == trash.id)
        #expect(final?.folderPath == trash.path)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == inbox.path)
        #expect(ops[0].destinationPath == trash.path)
        #expect(ops[0].messageIds == ["m-delete-durable"])

        // DELETE now dispatches via `performCoordinatedRoleMove` — same drain
        // guarantee as the ARCHIVE case above.
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "overlay refcount must drain to zero once performCoordinatedRoleMove's queued closure completes")
    }

    // MARK: - (5) Same UID across two folders (FIX 1 regression)

    @Test("same messageId (UID) exists in both the inbox and archive folders — IMAP UIDs are folder-scoped, so ARCHIVE must act on the INBOX row ONLY; the pre-existing archive-folder row with the same UID is untouched")
    func sameUidTwoFoldersArchiveActsOnInboxRowOnly() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        // Insert the ARCHIVE-folder row FIRST (lower rowid) — an unfiltered
        // `fetchOne` (no ORDER BY, no folder predicate) tends to return rows
        // in insertion order, so this ordering is the one most likely to
        // surface the wrong-folder bug if the `isInInbox = 1` filter were
        // ever dropped.
        let archiveRow = makeDurableHeader(folder: archive, messageId: "same-uid-42")
        let inboxRow = makeDurableHeader(folder: inbox, messageId: "same-uid-42")
        #expect(archiveRow.id != inboxRow.id, "same UID in two folders must produce distinct composite ids (MessageIdentity.headerId embeds folderPath)")
        try await pool.writeWithoutTransaction { db in
            try archiveRow.insert(db)
            try inboxRow.insert(db)
        }

        await NotificationActionRouter.execute(actionId: "ARCHIVE", messageId: "same-uid-42", accountId: "acc1")

        let finalInboxRow = try await pool.read { db in try MessageHeader.fetchOne(db, key: inboxRow.id) }
        #expect(finalInboxRow?.folderId == archive.id, "the INBOX row (and only the inbox row) must have moved to Archive")
        #expect(finalInboxRow?.folderPath == archive.path)

        let finalArchiveRow = try await pool.read { db in try MessageHeader.fetchOne(db, key: archiveRow.id) }
        #expect(finalArchiveRow?.folderId == archive.id, "the pre-existing archive-folder row must be untouched — still in its original folder")
        #expect(finalArchiveRow?.folderPath == archive.path)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "exactly one .move op — only the inbox row was ever acted on")
        guard ops.count == 1 else { return }
        #expect(ops[0].folderPath == inbox.path, "source folderPath must be the inbox path, not the archive row's")
        #expect(ops[0].destinationPath == archive.path)
    }
}
