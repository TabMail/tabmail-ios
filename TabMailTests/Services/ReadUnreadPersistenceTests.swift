/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// Regression coverage for keeping read/unread state outside Undo while still
/// persisting the user's intent.
///
/// The contract:
///   1. `UndoableAction`/`UndoAccountCommand`/`UndoMember` (ADR-IOS-060) model
///      ONLY an inverse move — there is no discriminated action-type enum for
///      read/unread to piggyback onto, so "read/unread creates an Undo entry"
///      is now structurally impossible rather than a runtime invariant to pin
///      (the prior `UndoableActionType` exhaustive-switch compile check was
///      deleted with that enum). The behavioral half of the contract —
///      `markRead`/`markUnread` never push to `UndoService` — is still
///      covered below (`markReadPersists`/`markUnreadPersists` assert
///      `undoStack.count` is unchanged).
///   2. `markRead` / `markUnread` still flip `MessageHeader.isRead` in GRDB and
///      insert a `PendingOperation`, so sync happens asynchronously and the
///      user's intent survives crash/kill/disconnection.
@Suite("Read/unread persistence after undo-stack removal", .serialized, .processGlobalState)
struct ReadUnreadPersistenceTests {

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

            let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
            try folder.insert(db)
        }
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        return (pool, folder, dir, previous)
    }

    /// Teardown shared by every test. Ports `InboxGestureActionTests` /
    /// `CoordinatedToolActionTests`' guarded restore: the REAL
    /// `markRead`/`markUnread` paths driven here spawn unstructured
    /// recount/drain Tasks (drainPendingQueue, `UnreadCountManager` recounts)
    /// that outlive the test body — they can run AFTER the defers. Restoring
    /// a nil `previous` would let a post-defer recount hit
    /// `AppDatabase.rawPool`'s force-unwrap and kill the whole test process,
    /// so when there is no previous AppDatabase, leave the test one (and its
    /// files) alive rather than tear it down.
    private func restoreTestDB(previous: AppDatabase?, dir: URL) {
        if previous != nil {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @MainActor
    private func insertMessage(
        _ pool: DatabasePool,
        messageId: String,
        isRead: Bool,
        rfc822MessageId: String? = nil,
        folderPath: String = "INBOX"
    ) throws -> MessageHeader {
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
            folderPath: folderPath,
            isInInbox: true
        )
        header.rfc822MessageId = rfc822MessageId ?? "rfc-\(messageId)@example.com"
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
        defer { restoreTestDB(previous: previous, dir: dir) }

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

        // PendingOperation inserted with the normalized RFC identity, never
        // the Gmail/Graph transport ID.
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .markRead)
        #expect(ops[0].messageIds == ["rfc-rru-1@example.com"])
        #expect(ops[0].accountId == "acc1")
        #expect(ops[0].folderPath == "INBOX")

        // Undo stack MUST NOT receive a toggleRead entry — commit b804a42.
        #expect(UndoService.shared.undoStack.count == stackBefore)
    }

    @Test("markUnread persists isRead=false in GRDB and inserts a PendingOperation(.markUnread)")
    @MainActor
    func markUnreadPersists() async throws {
        let (pool, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

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
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .markUnread)
        #expect(ops[0].messageIds == ["rfc-rru-2@example.com"])

        #expect(UndoService.shared.undoStack.count == stackBefore)
    }

    @Test("Round-trip: markRead then markUnread leaves isRead=false and two pending ops (latest wins remotely)")
    @MainActor
    func roundTripPersistsBothOps() async throws {
        let (pool, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

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
        guard ops.count == 2 else { return }
        #expect(ops[0].type == .markRead)
        #expect(ops[1].type == .markUnread)
    }

    @Test("markRead admits a missing-RFC row as a provider-ID token member (hybrid identity)")
    @MainActor
    func markReadMissingRfcAdmitsProviderToken() async throws {
        let (pool, _, dir, previous) = try makeTestDB()
        let cleared = Mutex<[(String, String)]>([])
        NSEDataBridge.clearNotificationRecorderForTesting.withLock { recorder in
            recorder = { accountId, messageId in
                cleared.withLock { $0.append((accountId, messageId)) }
            }
        }
        defer {
            NSEDataBridge.clearNotificationRecorderForTesting.withLock { $0 = nil }
            restoreTestDB(previous: previous, dir: dir)
        }

        let header = try insertMessage(
            pool,
            messageId: "provider-only-id",
            isRead: false,
            rfc822MessageId: ""
        )

        await AccountManager.shared.markRead([header])

        let result = try await pool.read { db -> (Bool?, [PendingOperation]) in
            let row = try MessageHeader.fetchOne(db, key: header.id)
            return (row?.isRead, try PendingOperation.fetchAll(db))
        }
        // Hybrid identity (PLAN_IDENTITY_HYBRID §2): the provider ID admits
        // as an opaque token — the optimistic flip lands, one durable row
        // carries the raw token, and the delivered notification clears.
        #expect(result.0 == true)
        #expect(result.1.count == 1)
        if result.1.count == 1 {
            #expect(result.1[0].type == .markRead)
            #expect(result.1[0].messageIds == ["provider-only-id"])
        }
        #expect(cleared.withLock { $0 }.count == 1)
    }

    @Test("markRead admits a malformed-RFC row as a provider-ID token member (hybrid identity)")
    @MainActor
    func markReadMalformedRfcAdmitsProviderToken() async throws {
        let (pool, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        let header = try insertMessage(
            pool,
            messageId: "transport-malformed",
            isRead: false,
            rfc822MessageId: "<missing-close@example.com"
        )

        await AccountManager.shared.markRead([header])

        let result = try await pool.read { db -> (Bool?, [PendingOperation]) in
            let row = try MessageHeader.fetchOne(db, key: header.id)
            return (row?.isRead, try PendingOperation.fetchAll(db))
        }
        #expect(result.0 == true)
        #expect(result.1.count == 1)
        if result.1.count == 1 {
            #expect(result.1[0].messageIds == ["transport-malformed"], "byte-exact provider-ID token, never the malformed RFC string")
        }
    }

    @Test("markUnread admits an invalid-RFC row as a provider-ID token member (hybrid identity)")
    @MainActor
    func markUnreadInvalidRfcDoesNotMutateOrQueue() async throws {
        let (pool, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        let header = try insertMessage(
            pool,
            messageId: "transport-unread-invalid",
            isRead: true,
            rfc822MessageId: "<missing-close@example.com"
        )

        await AccountManager.shared.markUnread([header])

        let result = try await pool.read { db -> (Bool?, [PendingOperation]) in
            let row = try MessageHeader.fetchOne(db, key: header.id)
            return (row?.isRead, try PendingOperation.fetchAll(db))
        }
        #expect(result.0 == false)
        #expect(result.1.count == 1)
        if result.1.count == 1 {
            #expect(result.1[0].type == .markUnread)
            #expect(result.1[0].messageIds == ["transport-unread-invalid"])
        }
    }

    @Test("markFlagged admits a missing-RFC row as a provider-ID token member (hybrid identity)")
    @MainActor
    func markFlaggedMissingRfcDoesNotMutateOrQueue() async throws {
        let (pool, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        let header = try insertMessage(
            pool,
            messageId: "transport-flag-invalid",
            isRead: true,
            rfc822MessageId: ""
        )

        await AccountManager.shared.markFlagged([header], flagged: true)

        let result = try await pool.read { db -> (Bool?, [PendingOperation]) in
            let row = try MessageHeader.fetchOne(db, key: header.id)
            return (row?.isFlagged, try PendingOperation.fetchAll(db))
        }
        #expect(result.0 == true)
        #expect(result.1.count == 1)
        if result.1.count == 1 {
            #expect(result.1[0].type == .markFlagged)
            #expect(result.1[0].messageIds == ["transport-flag-invalid"])
        }
    }

    @Test("markRead refuses a whitespace-only source before optimistic mutation")
    @MainActor
    func markReadBlankSourceDoesNotMutateOrQueue() async throws {
        let (pool, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        let header = try insertMessage(
            pool,
            messageId: "transport-blank-source",
            isRead: false,
            rfc822MessageId: "valid-source-test@example.com",
            folderPath: "   "
        )

        await AccountManager.shared.markRead([header])

        let result = try await pool.read { db -> (Bool?, [PendingOperation]) in
            let row = try MessageHeader.fetchOne(db, key: header.id)
            return (row?.isRead, try PendingOperation.fetchAll(db))
        }
        #expect(result.0 == false)
        #expect(result.1.isEmpty)
    }

    @Test("markRead mixed batch mutates and queues BOTH shapes: normalized RFC + provider-ID token")
    @MainActor
    func markReadMixedBatchQueuesBothShapes() async throws {
        let (pool, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        let valid = try insertMessage(
            pool,
            messageId: "transport-valid",
            isRead: false,
            rfc822MessageId: "<Durable.Valid@Example.COM>"
        )
        let refused = try insertMessage(
            pool,
            messageId: "transport-refused",
            isRead: false,
            rfc822MessageId: ""
        )

        await AccountManager.shared.markRead([valid, refused])

        let result = try await pool.read { db -> ([String: Bool], [PendingOperation]) in
            let rows = try MessageHeader.fetchAll(db)
            return (
                Dictionary(uniqueKeysWithValues: rows.map { ($0.messageId, $0.isRead) }),
                try PendingOperation.fetchAll(db)
            )
        }
        #expect(result.0[valid.messageId] == true)
        #expect(result.0[refused.messageId] == true, "the token member's optimistic flip lands too (hybrid identity)")
        #expect(result.1.count == 1)
        guard result.1.count == 1 else { return }
        #expect(Set(result.1[0].messageIds) == ["Durable.Valid@Example.COM", "transport-refused"],
                "one batch row carries the normalized RFC member and the byte-exact token")
    }

    // MARK: - rfc822 sibling expansion (real path)

    /// Real-path pin for `AccountManager.markRead`'s sibling contract
    /// (`AccountManagerActions.expandWithSiblingsByRfc822` + per-folder-group
    /// `PendingOperation` emission). The only prior coverage was a mirror
    /// reimplementation in `AccountManagerActionsTests` (simulateMarkRead)
    /// that cannot fail on a production change — this drives the REAL
    /// `AccountManager.shared.markRead` on just the inbox copy of a
    /// self-send and asserts the Sent-folder sibling (same accountId +
    /// rfc822MessageId, different folder) flips too, with one `.markRead`
    /// PendingOperation per folder group and both folders' unreadCount
    /// decremented by exactly the newly-read count.
    @Test("markRead on the inbox copy expands to the rfc822 sibling in Sent: both rows flip, one .markRead PendingOperation per folder group, both folders' unreadCount decremented")
    @MainActor
    func markReadExpandsToRfc822SiblingAcrossFolders() async throws {
        let (pool, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        // Second folder: Sent — the sibling's home.
        let sent = Folder(name: "Sent", path: "Sent", role: .sent, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in
            let s = sent
            try s.insert(db)
        }

        // The self-send pair: one underlying message materialized as two
        // MessageHeader rows (INBOX + Sent) sharing (accountId,
        // rfc822MessageId). Both unread. Plus one unrelated unread filler per
        // folder, so the unreadCount assertion distinguishes "decremented by
        // exactly the newly-read siblings" (2 → 1) from "recounted/zeroed" —
        // stable whichever of the optimistic decrement or the async recount
        // lands last (both agree on 1).
        let sharedRfc = "sibling-\(UUID().uuidString)@example.com"
        func makeHeader(folder: Folder, messageId: String, rfc822: String?) -> MessageHeader {
            var h = MessageHeader(
                messageId: messageId, subject: "Subject", from: "Sender",
                fromAddress: "sender@example.com", to: "me@example.com",
                date: Date(), snippet: "body",
                folderId: folder.id, accountId: folder.accountId,
                folderPath: folder.path, isInInbox: folder.role == .inbox
            )
            h.rfc822MessageId = rfc822
            h.headerComplete = true
            h.isRead = false
            return h
        }
        let inboxFolder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let inboxSibling = makeHeader(folder: inboxFolder, messageId: "rru-sib-inbox", rfc822: sharedRfc)
        let sentSibling = makeHeader(folder: sent, messageId: "rru-sib-sent", rfc822: sharedRfc)
        let inboxFiller = makeHeader(folder: inboxFolder, messageId: "rru-filler-inbox", rfc822: nil)
        let sentFiller = makeHeader(folder: sent, messageId: "rru-filler-sent", rfc822: nil)
        try await pool.writeWithoutTransaction { db in
            try inboxSibling.insert(db)
            try sentSibling.insert(db)
            try inboxFiller.insert(db)
            try sentFiller.insert(db)
            // 2 unread per folder — matches row truth so the optimistic
            // decrement and the async recount agree on the final value.
            try db.execute(sql: "UPDATE folder SET unreadCount = 2 WHERE id IN (?, ?)",
                           arguments: [inboxFolder.id, sent.id])
        }

        // REAL path — mark ONLY the inbox row read.
        await AccountManager.shared.markRead([inboxSibling])

        // Both sibling rows flipped; fillers untouched.
        let isReadById = try await pool.read { db -> [String: Bool] in
            let rows = try MessageHeader.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.isRead) })
        }
        #expect(isReadById[inboxSibling.id] == true, "the acted-on inbox row must be read")
        #expect(isReadById[sentSibling.id] == true, "the rfc822 sibling in Sent must flip too — sibling expansion")
        #expect(isReadById[inboxFiller.id] == false, "unrelated rows are untouched")
        #expect(isReadById[sentFiller.id] == false, "unrelated rows are untouched")

        // Exactly TWO .markRead PendingOperations — one per folder group,
        // each carrying that folder's own row.
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 2, "one PendingOperation per (accountId, folderPath) group")
        guard ops.count == 2 else { return }
        #expect(ops.allSatisfy { $0.type == .markRead })
        let inboxOp = ops.first { $0.folderPath == "INBOX" }
        let sentOp = ops.first { $0.folderPath == "Sent" }
        #expect(inboxOp != nil, "an op must target the INBOX group")
        #expect(sentOp != nil, "an op must target the Sent group")
        #expect(inboxOp?.messageIds == [sharedRfc])
        #expect(sentOp?.messageIds == [sharedRfc])

        // Both folders' unreadCount decremented by exactly one (2 → 1).
        let unreadByFolder = try await pool.read { db -> [String: Int] in
            let folders = try Folder.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.unreadCount) })
        }
        #expect(unreadByFolder[inboxFolder.id] == 1, "INBOX unreadCount must drop by exactly the newly-read count")
        #expect(unreadByFolder[sent.id] == 1, "Sent unreadCount must drop by exactly the newly-read count")
    }
}
