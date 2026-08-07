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
/// (`AccountManager.executeOperation`).
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
/// 6. A THROWN durable read is uncertainty, not absence: the tap survives as
///    durable intention, is never dispatched against a staged row the failed
///    read could not corroborate, is scoped to the folder the row was actually
///    OBSERVED in, and recovers to the normal dispatch path when the retry
///    succeeds.
///
/// `.serialized`: tests swap `AppDatabase.shared` and drive `AccountManager
/// .shared`'s write paths — mirrors `CoordinatedToolActionTests`.
@Suite("NotificationActionRouter — notification-action dispatch fix", .serialized, .processGlobalState)
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
        // "Mark as read on archive & delete" (Settings → User Interface) ships
        // default ON, which composes an extra `.markRead` op ahead of every
        // archive/delete move. The op-count assertions below predate that
        // feature and pin the MOVE dispatch itself, so this harness forces the
        // setting OFF to keep exercising exactly that behaviour. The test that
        // covers the new feature flips it back ON via the same key after
        // calling this helper.
        UserDefaults.standard.set(false, forKey: AccountManager.markReadOnArchiveDeleteKey)
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
    /// AFTER the defers. Restore a real predecessor when present, but retain this
    /// fixture until process exit in either case so escaped work never reaches a
    /// closed pool.
    private func restoreTestDB(pool: DatabasePool, previous: AppDatabase?, dir: URL) {
        UserDefaults.standard.removeObject(forKey: AccountManager.markReadOnArchiveDeleteKey)
        InstalledTestDatabaseLifetime.finish(
            previous: previous,
            pool: pool,
            directory: dir
        )
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
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

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

    // MARK: - (1b) Mark-as-read on archive & delete — the notification button
    //
    // The notification action buttons are one of the entry points the setting
    // covers (Settings → User Interface → "Mark as Read on Archive & Delete",
    // default ON). They reach it structurally: `NotificationActionRouter`
    // dispatches ARCHIVE/DELETE through `performCoordinatedRoleMove`, which
    // composes the read intent itself. This test pins that the button really
    // does inherit it — a future refactor that routes the notification path
    // around the coordinator would otherwise silently lose the behaviour with
    // every other suite still green. `makeTestDB` forces the setting OFF for
    // this suite's other tests (see its comment); this one flips it back ON.

    @Test("mark-read-on-archive ON: a notification ARCHIVE button tap on an UNREAD message ends read AND archived, with the read op recorded BEFORE the move")
    func notificationArchiveComposesReadWhenSettingOn() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        UserDefaults.standard.set(true, forKey: AccountManager.markReadOnArchiveDeleteKey)

        let header = makeDurableHeader(folder: inbox, messageId: "m-notif-markread")
        #expect(header.isRead == false, "premise: the notification's message is unread")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await NotificationActionRouter.execute(actionId: "ARCHIVE", messageId: "m-notif-markread", accountId: "acc1")

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.isRead == true, "a notification-button archive marks the message read")
        #expect(final?.folderId == archive.id)

        // ORDERING: the read op must be RECORDED first — a move changes the
        // address the read op would have to name (THE ADDRESS PROBLEM).
        let ops = try await pool.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }
        #expect(ops.map(\.type) == [.markRead, .move], "read intent must precede the move: \(ops.map(\.type.rawValue))")
        guard ops.count == 2 else { return }
        #expect(ops[0].folderPath == inbox.path, "the read op names the SOURCE folder")
        #expect(ops[1].destinationPath == archive.path)
    }

    // MARK: - (2) No header anywhere + ARCHIVE

    @Test("no header anywhere (cold background launch) + ARCHIVE queues a .move PendingOperation directly: folderPath == inbox path, destinationPath == archive path, messageIds == [messageId]")
    func noHeaderArchiveQueuesColdMoveOp() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); resetStagedGlobal() }
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
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); resetStagedGlobal() }
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
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

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
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

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

    // MARK: - (6) A thrown durable read is uncertainty, never absence (T4.V6)

    /// The property pinned is the SYSTEM END STATE, not the enum's shape: after
    /// a database read that THREW, (a) the user's tap still exists as durable
    /// intention, and (b) nothing was mutated on the strength of a row the
    /// failed read could not confirm. A fix that merely renames the result but
    /// still laundders a throw into "absent" does not turn these green.
    private func resetDurableLookupFault() {
        NotificationActionRouter.armDurableLookupFailuresForTesting(0)
    }

    @Test("a thrown durable read is not absence — the ARCHIVE tap survives as exactly one durable .move operation, and the fault counter proves both the initial read and the post-merge retry actually ran")
    func thrownDurableReadRetainsTheActionDurably() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); resetStagedGlobal(); resetDurableLookupFault() }
        resetStagedGlobal()

        // Both the initial lookup and the post-merge retry throw: the router
        // never learns whether the message is local.
        NotificationActionRouter.armDurableLookupFailuresForTesting(2)

        await NotificationActionRouter.execute(actionId: "ARCHIVE", messageId: "m-thrown-read", accountId: "acc1")

        // (a) durable end state: the intention survives.
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "a thrown read must never drop the user's action")
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == inbox.path, "no observed source evidence → the canonical inbox")
        #expect(ops[0].destinationPath == archive.path)
        #expect(ops[0].messageIds == ["m-thrown-read"])

        // (b) non-vacuity, wire side: the injected faults were actually consumed,
        // so the durable tier really was attempted twice (initial + retry).
        #expect(
            NotificationActionRouter.durableLookupAttemptsForTesting == 2,
            "the thrown-read path must run one real merge + retry, not give up on the first throw"
        )
    }

    @Test("a thrown durable read never dispatches a staged row, and retains the action against the folder that row was OBSERVED in — never a bare UID against the canonical inbox")
    func thrownDurableReadScopesRetentionToTheObservedFolder() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); resetStagedGlobal(); resetDurableLookupFault() }
        resetStagedGlobal()

        // The NSE staged this message in a mailbox whose path is NOT the
        // account's inbox-role path. The durable read — the only tier that
        // could have shown a contradicting row — throws on both attempts, so
        // the staged row is source EVIDENCE, never a dispatch target.
        let observedPath = "INBOX.Priority"
        let staged = StagedInboxRow(
            accountId: "acc1", folderPath: observedPath, messageId: "m-thrown-staged",
            rfc822MessageId: "<staged-observed@example.com>", threadId: nil, inReplyTo: nil, references: [],
            subject: "Observed elsewhere", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
        NSEDataBridge.latestStagedRows.withLock { $0 = [staged] }
        NotificationActionRouter.armDurableLookupFailuresForTesting(2)

        await NotificationActionRouter.execute(actionId: "ARCHIVE", messageId: "m-thrown-staged", accountId: "acc1")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "the tap must survive as exactly one durable operation")
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(
            ops[0].folderPath == observedPath,
            "the op carries a bare UID, so it must address the mailbox the UID was OBSERVED in"
        )
        #expect(ops[0].folderPath != inbox.path, "never the merely-assumed canonical inbox path")
        #expect(ops[0].destinationPath == archive.path)
        #expect(ops[0].messageIds == ["m-thrown-staged"])

        // No local mutation happened on the strength of an unreadable database:
        // the staged row was never synthesized into a durable header, and
        // nothing was moved.
        let headerCount = try await pool.read { db in try MessageHeader.fetchCount(db) }
        #expect(headerCount == 0, "a thrown read must not dispatch a mutation against the staged row")
    }

    @Test("one thrown read is not sticky — when the post-merge retry succeeds, the resolved header dispatches normally and no cold operation is manufactured")
    func thrownDurableReadRecoversOnRetry() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); resetStagedGlobal(); resetDurableLookupFault() }
        resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-thrown-recovers")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // ONLY the first attempt throws.
        NotificationActionRouter.armDurableLookupFailuresForTesting(1)

        await NotificationActionRouter.execute(actionId: "ARCHIVE", messageId: "m-thrown-recovers", accountId: "acc1")

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id, "the recovered header must dispatch through the normal action path")
        #expect(final?.folderPath == archive.path)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "exactly one op — the recovery must not ALSO manufacture a cold retention op")
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == inbox.path, "source folderPath is the resolved header's own folder")
        #expect(ops[0].destinationPath == archive.path)
        #expect(
            NotificationActionRouter.durableLookupAttemptsForTesting == 2,
            "one throw + one healthy retry"
        )
    }

    @Test("a thrown durable read retains MARK_READ too — the read failure never converts a read intent into silence")
    func thrownDurableReadRetainsMarkRead() async throws {
        let (pool, inbox, _, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); resetStagedGlobal(); resetDurableLookupFault() }
        resetStagedGlobal()

        NotificationActionRouter.armDurableLookupFailuresForTesting(2)

        await NotificationActionRouter.execute(actionId: "MARK_READ", messageId: "m-thrown-markread", accountId: "acc1")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .markRead)
        #expect(ops[0].folderPath == inbox.path)
        #expect(ops[0].destinationPath == nil)
        #expect(ops[0].messageIds == ["m-thrown-markread"])
        #expect(NotificationActionRouter.durableLookupAttemptsForTesting == 2)
    }

    // MARK: - (7) C3 — the notification tap carries a content witness

    /// Pins the SYSTEM PROPERTY, not the mechanism: **no mutation dispatched by a
    /// notification-action tap may land on a message whose identity differs from
    /// the one the router resolved.** Deliberately NOT written as "the router
    /// passes `expectedIdentities`" — a mechanism-pinning assertion stays green
    /// on a system that re-broke some other way (global Testing rule 12,
    /// `MIS-015`).
    ///
    /// The window under test is the one `performCoordinatedRoleMove`'s SECOND
    /// identity pass exists for: the FIFO write queue can hold an unbounded
    /// amount of other work between the pre-resolve and the write, which is wide
    /// enough for a UIDVALIDITY turnover to purge the row and re-seat a
    /// different physical message under the same composite address. The epoch
    /// guards cannot see it — the impostor's epoch is fresh too — so the content
    /// witness is the only thing that can refuse.
    ///
    /// RED before the fix: with `expectedIdentities` omitted at the ARCHIVE call
    /// site, both refusals were witness-gated and therefore inert, and the
    /// impostor was moved to Archive. Registered as `IOS-NOTIFY-001`.
    @Test("""
    C3 — a UIDVALIDITY turnover re-seats the tapped address onto a DIFFERENT message after \
    the router resolved it and before the coordinated write runs: the ARCHIVE tap moves \
    nothing and queues no durable operation
    """)
    func notificationArchiveRefusesAReseatedAddress() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); resetStagedGlobal() }
        resetStagedGlobal()

        // `let` bindings, not `var`: these are captured by the @Sendable write
        // closures below, and Swift 6 rejects a captured `var`.
        let captured: MessageHeader = {
            var h = makeDurableHeader(folder: inbox, messageId: "m-c3-reseat")
            h.rfc822MessageId = "<captured-notify@example.com>"
            return h
        }()
        try await pool.writeWithoutTransaction { db in try captured.insert(db) }
        let id = captured.id

        // Hold the FIFO write queue so the coordinated closure cannot run until
        // the address has been re-seated. Safe to block a process-wide queue
        // here because `.processGlobalState` excludes every other suite that
        // touches `AccountManager.shared`.
        let gate = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            for await _ in gate.stream { break }
        }

        let tap = Task {
            await NotificationActionRouter.execute(
                actionId: "ARCHIVE", messageId: "m-c3-reseat", accountId: "acc1")
        }

        // The overlay entry appears after the pre-resolve and before the
        // enqueue, so it is the observable "pass 1 admitted this id" edge.
        var admittedByPassOne = false
        for _ in 0..<400 {
            if AccountManager.shared.snapshotOverlay()[id] != nil { admittedByPassOne = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(admittedByPassOne, """
            pass 1 never admitted the id, so this test would pass for the wrong reason — \
            it must exercise the window AFTER a successful pre-resolve.
            """)

        // The turnover: same composite address and primary key, different email.
        let impostor: MessageHeader = {
            var h = makeDurableHeader(folder: inbox, messageId: "m-c3-reseat")
            h.rfc822MessageId = "<impostor-notify@example.com>"
            return h
        }()
        #expect(impostor.id == id, "fixture must re-seat the SAME address, or nothing is being tested")
        try await pool.writeWithoutTransaction { db in
            try captured.delete(db)
            try impostor.insert(db)
        }

        gate.continuation.finish()
        await tap.value

        // The system end state, which is what actually matters.
        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.rfc822MessageId == "<impostor-notify@example.com>",
                "non-vacuity: the impostor really is the row sitting at that address")
        #expect(final?.folderId == inbox.id,
                "a message the notification was never about must not be archived")
        #expect(final?.folderPath == inbox.path)
        #expect(final?.folderId != archive.id)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty, "a refused notification archive must queue no durable operation at all")

        #expect(AccountManager.shared.overlayOpRefCountForTesting()[id] == nil, "refcount stranded")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded")
    }
}
