/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Pins `AccountManager.performCoordinatedRoleMove` (F4 — PLAN_OVERLAY_CALLSITE_AUDIT.md
/// §6): the coordinated path agent tools (`EmailArchiveTool`/`EmailDeleteTool`) use in
/// place of a direct `archive(resolved)`/`delete(resolved)` call on a confirmation-time
/// header snapshot. Three properties are pinned:
/// 1. Basic archive: row moves, a `.move` PendingOperation is queued, the overlay
///    refcount/entry fully drain.
/// 2. Staleness (Trace-A regression): the write acts on FRESH row truth at execution
///    time, not a snapshot captured before an unbounded user-confirmation wait — a
///    message the user separately moved to Trash while confirmation was pending must
///    have its coordinated-archive PendingOperation record the CURRENT (Trash) source
///    path, not a stale one.
/// 3. FIFO/union: a coordinated move queued behind an in-flight gesture intent cycle
///    for the SAME id executes strictly after it (same FIFO write queue), and both
///    complete with the overlay/refcount/intent-cycle registers fully drained.
///
/// `.serialized`: tests touch `AccountManager.shared`'s process-wide optimistic
/// overlay + FIFO write queue — mirrors `InboxGestureActionTests`.
@Suite("performCoordinatedRoleMove — agent-tool overlay + fresh-resolve (F4)", .serialized, .processGlobalState)
struct CoordinatedToolActionTests {

    // MARK: - Harness (mirrors InboxGestureActionTests.swift)

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
    private func makeDurableHeader(
        folder: Folder,
        messageId: String,
        isRead: Bool = false,
        actionTag: ActionTag? = nil
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path,
            isInInbox: folder.role == .inbox
        )
        h.headerComplete = true
        h.isRead = isRead
        h.actionTag = actionTag
        if let actionTag { h.tagSortOrder = actionTag.sortOrder }
        return h
    }

    /// Teardown shared by every test. Mirrors `InboxGestureActionTests.restoreTestDB`:
    /// production paths driven here (drainPendingQueue, unread recounts) fire
    /// unstructured background Tasks the drain barrier cannot join, so they can run
    /// AFTER the defers. Restore a real predecessor when present, but retain this
    /// fixture until process exit in either case so escaped work never reaches a
    /// closed pool.
    private func restoreTestDB(pool: DatabasePool, previous: AppDatabase?, dir: URL) {
        InstalledTestDatabaseLifetime.finish(
            previous: previous,
            pool: pool,
            directory: dir
        )
    }

    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    /// FIFO barrier — see `InboxGestureActionTests.drainWriteQueue`. `AccountManager`
    /// is an actor and this call is from a non-actor test context, so (unlike the
    /// production `awaitWriteQueueDrain()`, itself an actor method) this hops via
    /// `Task` before calling `enqueueWrite`.
    private func drainWriteQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { await AccountManager.shared.enqueueWrite { cont.resume() } }
        }
    }

    // MARK: - (1) Basic archive

    @Test("performCoordinatedRoleMove archives a message: row moves to Archive, ONE .move PendingOperation is queued, and the overlay refcount/entry fully drain")
    func basicArchiveMovesRowAndDrainsOverlay() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-basic-archive", actionTag: .reply)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await AccountManager.shared.performCoordinatedRoleMove(ids: [id], role: .archive)

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id)
        #expect(final?.folderPath == archive.path)
        #expect(final?.isInInbox == false)
        #expect(final?.actionTag == nil, "F6: actionTag clears locally in the same write that leaves the inbox")
        #expect(final?.tagSortOrder == 99, "F6: tagSortOrder resets to the sweepStaleActionTags sentinel")

        // F6 removed the legacy `.removeTag` PendingOperation enqueue — tags
        // are local-only (ADR-IOS-036) and clear in the move's own write, so
        // only the `.move` op is queued.
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].destinationPath == archive.path)

        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount stranded after performCoordinatedRoleMove completed")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after performCoordinatedRoleMove completed")
    }

    // MARK: - (2) Staleness pin (Trace-A regression)

    @Test("staleness regression: a message moved to Trash AFTER the tool captured its id (during the confirmation wait) — the coordinated archive re-resolves FRESH row truth, so its PendingOperation records the CURRENT (Trash) source path, not a stale Inbox path")
    func staleSnapshotDoesNotCorruptSourcePath() async throws {
        let (pool, inbox, archive, trash, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-stale-pin")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // Simulate the user's later action DURING what would have been the tool's
        // unbounded confirmation wait: move the row to Trash directly (bypassing
        // the coordinated helper — this is the "later user action" the stale
        // snapshot must not reverse). `move()` awaits its own dbPool.write, so the
        // row and its PendingOperation are durably committed before this returns —
        // optimisticMoveToFolder's updateAll only touches folderId/folderPath/
        // isInInbox, never the PK, so `id` stays valid for the lookup below.
        await AccountManager.shared.move([header], to: trash.path)

        let afterFirstMove = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(afterFirstMove?.folderId == trash.id, "setup: row must be in Trash before the coordinated archive runs")

        // The coordinated helper takes ONLY the id (never a pre-resolved header),
        // so it re-resolves fresh row truth (Trash) both for the overlay lookup
        // AND inside the queued write closure — there is no stale snapshot to
        // corrupt the resulting PendingOperation's source folderPath.
        await AccountManager.shared.performCoordinatedRoleMove(ids: [id], role: .archive)

        let ops = try await pool.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }
        #expect(ops.count == 2, "one PendingOperation for the Trash move, one for the coordinated archive")
        guard ops.count == 2 else { return }
        // Match by destination rather than positional index — both ops can share
        // a `createdAt` millisecond in a fast test run, so ordering ties aren't
        // load-bearing here; content is.
        guard let archiveOp = ops.first(where: { $0.destinationPath == archive.path }) else {
            Issue.record("no PendingOperation targeting Archive was queued")
            return
        }
        #expect(ops.contains { $0.destinationPath == trash.path }, "the original move-to-Trash op must still be present")
        #expect(archiveOp.type == .move)
        #expect(archiveOp.folderPath == trash.path, "source folderPath must be the CURRENT (Trash) path, not the stale pre-confirmation Inbox path")

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id, "final row must land in Archive (archive-from-Trash is legitimate)")

        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
    }

    // MARK: - (3) FIFO ordering with an in-flight gesture intent cycle

    @Test("FIFO/union: a coordinated archive queued behind an in-flight gesture intent cycle for the SAME id executes strictly after it — both complete, the row ends up read AND archived, and the overlay/refcount/intent-cycle registers all drain to empty")
    func coordinatedMoveOrdersAfterOpenIntentCycle() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-fifo-union", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // Gate the FIFO write queue BEFORE the gesture: with an empty queue the
        // intent cycle's executor can drain (and release its retain) before an
        // ungated intermediate assertion runs — the mid-state is only
        // deterministically observable while the gate blocks the drain
        // (pattern: InboxGestureActionTests).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // Opens an intent cycle for id (retain #1) and enqueues ITS executor
        // closure onto the FIFO write queue (behind the gate) via an
        // unstructured Task.
        AccountManager.shared.registerGestureIntent(id: id, .isRead(target: true, baseline: false))
        // Settle: let the cycle's Task actually append its closure to the queue
        // BEFORE the coordinated call below enqueues its own — establishes
        // deterministic FIFO order (mirrors InboxGestureActionTests' 50ms settle).
        try await Task.sleep(for: .milliseconds(50))

        // Deterministic while gated: the executor cannot run, so its retain is
        // still outstanding.
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == 1, "the intent cycle holds its own retain before the coordinated call joins in")

        // Release the gate, then run the coordinated move: it takes its OWN
        // retain and enqueues its closure BEHIND the already-queued
        // intent-cycle executor; it awaits durable completion, so by the time
        // this returns, BOTH closures have run in FIFO order (strict serial
        // drain — the coordinated write executes strictly after the cycle's).
        gate.finish()
        await AccountManager.shared.performCoordinatedRoleMove(ids: [id], role: .archive)

        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.isRead == true, "the intent cycle's markRead must have executed")
        #expect(final?.folderId == archive.id, "the coordinated archive must have executed")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        let opTypes = Set(ops.map(\.type))
        #expect(opTypes.contains(.markRead), "the intent cycle's write must have produced a PendingOperation")
        #expect(opTypes.contains(.move), "the coordinated archive's write must have produced a PendingOperation")

        #expect(AccountManager.shared.pendingIntentCyclesForTesting()[id] == nil, "intent cycle stranded")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount stranded")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded")
    }

    // MARK: - (4) Cross-account batch (audit round 6)

    @Test("cross-account archive batch: each account's message lands in ITS OWN archive folder — the destination is resolved per account, never from the batch's first member")
    func crossAccountArchiveResolvesDestinationPerAccount() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        // Second account with a DIFFERENT archive path — the pre-fix code
        // resolved the path from movable.first's account only and applied it
        // to every account in the batch, mis-filing acc2's row into a folder
        // path that doesn't exist for acc2.
        try await pool.writeWithoutTransaction { db in
            var acc2 = Account(emailAddress: "second@example.com", displayName: "Second", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2").insert(db)
            try Folder(name: "Archived Mail", path: "Archived Mail", role: .archive, accountId: "acc2").insert(db)
        }
        let inbox2 = try await pool.read { db in
            try Folder.filter(Column("accountId") == "acc2" && Column("role") == FolderRole.inbox.rawValue).fetchOne(db)
        }
        let archive2 = try await pool.read { db in
            try Folder.filter(Column("accountId") == "acc2" && Column("role") == FolderRole.archive.rawValue).fetchOne(db)
        }
        #expect(inbox2 != nil); #expect(archive2 != nil)
        guard let inbox2, let archive2 else { return }

        let h1 = makeDurableHeader(folder: inbox, messageId: "m-xacct-1")
        let h2 = makeDurableHeader(folder: inbox2, messageId: "m-xacct-2")
        try await pool.writeWithoutTransaction { db in try h1.insert(db); try h2.insert(db) }

        await AccountManager.shared.performCoordinatedRoleMove(ids: [h1.id, h2.id], role: .archive)

        let f1 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h1.id) }
        let f2 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h2.id) }
        #expect(f1?.folderPath == archive.path, "acc1's row must land in acc1's archive")
        #expect(f2?.folderPath == archive2.path, "acc2's row must land in acc2's OWN archive path, not acc1's")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        let destByAccount = Dictionary(uniqueKeysWithValues: ops.map { ($0.accountId, $0.destinationPath) })
        #expect(destByAccount["acc1"] == archive.path)
        #expect(destByAccount["acc2"] == archive2.path, "acc2's op must carry acc2's destination, not acc1's")

        for id in [h1.id, h2.id] {
            #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount stranded for \(id)")
            #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded for \(id)")
        }
    }

    // MARK: - (5) Mixed batch: one account missing its role folder entirely (round-8 note (a))

    @Test("mixed multi-account batch: acc2 has NO archive folder at all — acc1's message archives normally (ONE .move op), acc2's message is skipped entirely (zero ops, untouched), and neither the acted-on nor the skipped id strands an overlay/refcount entry")
    func mixedBatchAccountMissingRoleFolderSkipsCleanly() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        // acc2 has ONLY an inbox — no archive folder anywhere for this account.
        // performCoordinatedRoleMove's own "no role folder for account" skip
        // (mirrors archive()/delete()'s moveToRoleFolderPerAccount skip) must
        // drop h2 from `actionable` BEFORE any retainOverlayEntry call for it —
        // otherwise h2's retain would never be released (no queued closure
        // ever runs for an id filtered out before the retain loop).
        try await pool.writeWithoutTransaction { db in
            var acc2 = Account(emailAddress: "second@example.com", displayName: "Second", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2").insert(db)
        }
        let inbox2 = try await pool.read { db in
            try Folder.filter(Column("accountId") == "acc2" && Column("role") == FolderRole.inbox.rawValue).fetchOne(db)
        }
        #expect(inbox2 != nil)
        guard let inbox2 else { return }

        let h1 = makeDurableHeader(folder: inbox, messageId: "m-missing-role-1")
        let h2 = makeDurableHeader(folder: inbox2, messageId: "m-missing-role-2")
        try await pool.writeWithoutTransaction { db in try h1.insert(db); try h2.insert(db) }

        await AccountManager.shared.performCoordinatedRoleMove(ids: [h1.id, h2.id], role: .archive)

        let f1 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h1.id) }
        #expect(f1?.folderId == archive.id, "acc1's row must still archive normally")
        #expect(f1?.folderPath == archive.path)

        let f2 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h2.id) }
        #expect(f2?.folderId == inbox2.id, "acc2's row is untouched — still in acc2's inbox")
        #expect(f2?.folderPath == inbox2.path)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "exactly one .move op — only acc1's actionable message")
        guard ops.count == 1 else { return }
        #expect(ops[0].accountId == "acc1")
        #expect(ops[0].type == .move)
        #expect(ops[0].destinationPath == archive.path)

        for id in [h1.id, h2.id] {
            #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount stranded for \(id) — this must hold for BOTH the acted-on id (h1) and the skipped id (h2)")
            #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded for \(id)")
        }
    }
}
