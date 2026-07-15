/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Round D-0 (2026-07-14, supersedes the 2026-07-10 F6 destructive clear
/// pinned by `PLAN_OVERLAY_CALLSITE_AUDIT.md` §6): `actionTag` is RETAINED
/// across a folder move (archive/delete/move-out) in the SAME write as the
/// folder move — it is inbox-scoped PRESENTATION (display gates on
/// `isInInbox`), not an inbox-scoped invariant. No `.removeTag`
/// PendingOperation is queued either way (tags are local-only, ADR-IOS-036).
/// These tests drive the real `AccountManager.archive`/`move` production
/// methods against a swapped `AppDatabase.shared` — mirrors
/// `CoordinatedToolActionTests`.
///
/// `.serialized`: tests swap the process-wide `AppDatabase.shared` singleton
/// and touch `AccountManager.shared`'s optimistic overlay — mirrors
/// `InboxGestureActionTests` / `CoordinatedToolActionTests`.
@Suite("AccountManagerActions — actionTag is retained across a folder move (Round D-0)", .serialized, .processGlobalState)
struct AccountManagerActionsTagClearTests {

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

    /// A durable, query-visible header (`headerComplete = true`) carrying an
    /// optional actionTag (with its matching tagSortOrder — mirrors how a real
    /// tagged row looks, since `applyManualTag` keeps both in sync).
    private func makeDurableHeader(
        folder: Folder,
        messageId: String,
        actionTag: ActionTag? = nil
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path,
            isInInbox: folder.role == .inbox
        )
        h.headerComplete = true
        h.rfc822MessageId = "rfc-\(messageId)@example.com"
        h.actionTag = actionTag
        if let actionTag { h.tagSortOrder = actionTag.sortOrder }
        return h
    }

    /// Mirrors `CoordinatedToolActionTests.restoreTestDB` — leave the test DB
    /// alive (rather than force-unwrap crash the process) when there's no
    /// previous `AppDatabase` to restore.
    private func restoreTestDB(previous: AppDatabase?, dir: URL) {
        if previous != nil {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func clearOverlay() {
        AccountManager.shared.intentionJournal.resetForTesting()
    }

    // MARK: - Admission and forward execution

    @Test("move admits a missing-RFC row as a provider-ID token member (hybrid identity) — optimistic move, count, and queue all land")
    func moveMissingRfcAdmitsProviderToken() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        var header = makeDurableHeader(
            folder: inbox,
            messageId: "provider-only-move",
            actionTag: .reply
        )
        header.rfc822MessageId = nil
        header.isRead = false
        let refusedHeader = header
        try await pool.writeWithoutTransaction { db in
            try refusedHeader.insert(db)
            try db.execute(
                sql: "UPDATE folder SET unreadCount = 1 WHERE id = ?",
                arguments: [inbox.id]
            )
        }

        await AccountManager.shared.move([refusedHeader], to: archive.path)

        let result = try await pool.read { db -> (MessageHeader?, Int?, Int?, [PendingOperation]) in
            (
                try MessageHeader.fetchOne(db, key: refusedHeader.id),
                try Folder.fetchOne(db, key: inbox.id)?.unreadCount,
                try Folder.fetchOne(db, key: archive.id)?.unreadCount,
                try PendingOperation.fetchAll(db)
            )
        }
        // Hybrid identity (PLAN_IDENTITY_HYBRID §2): the identity-less row is
        // no longer refused — its provider ID admits as an opaque token, the
        // optimistic move lands (tag retained per Round D-0), the unread
        // count transfers, and one durable row carries the raw token.
        #expect(result.0?.folderId == archive.id)
        #expect(result.0?.actionTag == .reply)
        #expect(result.1 == 0)
        #expect(result.2 == 1)
        #expect(result.3.count == 1)
        if result.3.count == 1 {
            #expect(result.3[0].type == .move)
            #expect(result.3[0].messageIds == ["provider-only-move"])
        }
    }

    @Test("archive() (real production path): actionTag is RETAINED (Round D-0) with a consistent tagSortOrder, isInInbox flips to false, and NO .removeTag PendingOperation is queued — only .move")
    func archiveRetainsActionTagNoRemoveTagOp() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-archive-tag", actionTag: .reply)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await AccountManager.shared.archive([header])

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id, "message moved to Archive")
        #expect(final?.isInInbox == false)
        #expect(final?.actionTag == .reply, "Round D-0: the tag is retained across an inbox-leaving move — no longer destructively cleared")
        #expect(final?.tagSortOrder == ActionTag.reply.sortOrder, "tagSortOrder stays paired with the retained tag, not reset to the no-tag sentinel")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "only the .move op — tags never queue provider work (ADR-IOS-036)")
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
    }

    @Test("move() back to the inbox after archive (real production path, two separately-drained operations): the retained tag is there and displayed once isInInbox is true again")
    func moveBackToInboxRedisplaysRetainedTag() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-move-back-tag", actionTag: .reply)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await AccountManager.shared.archive([header])
        let afterArchive = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(afterArchive?.folderId == archive.id)
        #expect(afterArchive?.isInInbox == false)
        #expect(afterArchive?.actionTag == .reply, "setup: archive retains the tag")
        guard let afterArchive else { return }

        await AccountManager.shared.move([afterArchive], to: inbox.path)

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == inbox.id, "message moved back to the Inbox")
        #expect(final?.isInInbox == true)
        // The model state every tag renderer gates display on.
        #expect(final?.actionTag != nil && final?.isInInbox == true,
                "the tag is there and displayed once back in the inbox")
        #expect(final?.actionTag == .reply)
        #expect(final?.tagSortOrder == ActionTag.reply.sortOrder, "tagSortOrder stays paired with the retained tag")
    }

    @Test("move() between two non-inbox folders (Archive -> Trash, real production path): actionTag is NOT cleared — leavingInbox is false")
    func moveBetweenNonInboxFoldersDoesNotClearTag() async throws {
        let (pool, _, archive, trash, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: archive, messageId: "m-nonInbox-move", actionTag: .reply)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await AccountManager.shared.move([header], to: trash.path)

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == trash.id, "message moved to the new destination")
        #expect(final?.actionTag == .reply, "tag survives a move that never touches the inbox")
        #expect(final?.tagSortOrder == ActionTag.reply.sortOrder, "tagSortOrder untouched when the tag isn't cleared")
    }

    @Test("move() re-resolves fresh headers by id: a stale caller snapshot (still pointing at INBOX) is superseded by the row's CURRENT folder (Archive, landed by an earlier committed move) — the queued PendingOperation's source folderPath is the FRESH location, not the stale one")
    func moveReResolvesFreshHeaderOverStaleCallerSnapshot() async throws {
        let (pool, inbox, archive, trash, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-stale-move")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id
        // Caller's snapshot — captured BEFORE the "earlier committed move" below,
        // still says INBOX. Mirrors a gesture path's `lookupMessage` snapshot
        // captured at tap time and passed into a queued closure that runs late.
        let staleSnapshot = header

        // Simulate an earlier committed move: a prior queued closure already
        // ran and moved the row to Archive before this move() call executes.
        try await pool.writeWithoutTransaction { db in
            _ = try MessageHeader.filter(Column("id") == id).updateAll(db,
                Column("folderId").set(to: archive.id),
                Column("folderPath").set(to: archive.path),
                Column("isInInbox").set(to: false)
            )
        }

        await AccountManager.shared.move([staleSnapshot], to: trash.path)

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == trash.id, "row lands in Trash — the FRESH (Archive) source resolved correctly")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == archive.path, "queued op's source folderPath is the FRESH (Archive) location, not the stale caller snapshot's INBOX")
        #expect(ops[0].destinationPath == trash.path)
    }

    // MARK: - Derived overlay display

    @Test("AccountManager.overlayAdjustedSnapshot applies a queued gesture's actionTag to the display snapshot")
    func overlayAdjustedSnapshotPicksUpQueuedTagIntent() async throws {
        let (pool, inbox, _, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-overlay-snapshot")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }

        AccountManager.shared.intentionJournal.seedDisplayForTesting(
            id: header.id,
            mutation: .init(actionTag: .some(ActionTag.reply))
        )

        let dbTruth = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(dbTruth?.actionTag == nil, "setup: DB row is untouched while the display intent is queued")

        let snapshot = AccountManager.shared.overlayAdjustedSnapshot(header)
        #expect(snapshot.actionTag == .reply, "the display snapshot carries the queued intent")
        #expect(snapshot.tagSortOrder == ActionTag.reply.sortOrder,
                "the derived sort order remains paired with the overlaid tag")
    }
}

/// Owner feature (2026-07-15): "Mark as Read on Archive & Delete" toggle
/// (Settings → TabMail Settings → User Interface,
/// `AccountManager.markReadOnArchiveDeleteKey`). Pins the UserDefaults
/// contract in isolation from the composition behavior (covered end-to-end in
/// `InboxGestureActionTests`, `MessageDetailViewModelMoveTests`, and
/// `CoordinatedToolActionTests`): default ON (a never-set key defaults to
/// true — same missing-key handling as `ProactiveNotifyService.isEnabled`),
/// and an explicit persisted change is honored on the next read of the
/// SAME key (there is only one `UserDefaults.standard` per process, so
/// "fresh store read" here means re-evaluating the computed property after
/// the value changed underneath it, not a distinct store instance).
///
/// `.serialized`/`.processGlobalState`: mutates the process-wide
/// `UserDefaults.standard` key every archive/delete entry point reads —
/// mirrors the isolation every sibling suite in this feature applies.
@Suite("AccountManager.markReadOnArchiveDeleteEnabled — setting contract", .serialized, .processGlobalState)
struct MarkReadOnArchiveDeleteSettingTests {
    @Test("key is the documented literal, default is ON when the key has never been set, and an explicit persisted change is honored on the next read")
    func settingRoundTrip() {
        let key = AccountManager.markReadOnArchiveDeleteKey
        #expect(key == "markReadOnArchiveDelete")

        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        #expect(AccountManager.markReadOnArchiveDeleteEnabled == true, "a never-set key defaults to ON")

        defaults.set(false, forKey: key)
        #expect(AccountManager.markReadOnArchiveDeleteEnabled == false, "a persisted false is honored on the next read")

        defaults.set(true, forKey: key)
        #expect(AccountManager.markReadOnArchiveDeleteEnabled == true, "a persisted true is honored on the next read")
    }
}
