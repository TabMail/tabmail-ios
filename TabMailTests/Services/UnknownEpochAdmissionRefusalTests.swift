/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// T1.3 — a durable IMAP action admission FAILS CLOSED on an unknown folder epoch.
///
/// The SYSTEM PROPERTY under test (never the guard's mechanism): when a NEW user
/// gesture targets an IMAP folder whose `Folder.lastKnownUidValidity` is nil,
/// **no `PendingOperation` row exists afterwards AND no optimistic local mutation
/// landed** — the two must fail together, atomically. A local move/flag the queue
/// will never execute is worse than doing nothing.
///
/// 🚨 The anti-brick cases are the reason this suite exists in this shape.
/// `Folder.lastKnownUidValidity` is nil FOREVER on Gmail and Exchange — UIDVALIDITY
/// is an IMAP concept and neither the Gmail nor the Graph provider ever populates
/// `FolderInfo.uidValidity`. A refusal that keyed off "the column is nil" rather
/// than off the account's provider would therefore silently no-op every action on
/// every Gmail and Exchange account, permanently. `gmailNilEpoch…` and
/// `exchangeNilEpoch…` below fail loudly if the guard ever loses its provider
/// scoping, and must never be weakened to accommodate a guard that has.
@Suite("T1.3 — durable IMAP admission fails closed on an unknown folder epoch", .serialized, .processGlobalState)
struct UnknownEpochAdmissionRefusalTests {

    // MARK: - Harness

    /// Installs a temp `AppDatabase` holding one account of `provider`, an INBOX
    /// whose stored epoch is `inboxEpoch`, and an Archive whose epoch is ALWAYS
    /// nil. Archive staying nil is deliberate: the move tests then prove the
    /// refusal reads the **source** folder's epoch (where UIDs are resolved),
    /// not the destination's.
    @MainActor
    private func makeTestDB(
        provider: AccountProvider,
        inboxEpoch: Int?
    ) throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }

        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "user@example.com", displayName: "Test", provider: provider)
            acc.id = "acc1"
            try acc.insert(db)

            var inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
            inbox.lastKnownUidValidity = inboxEpoch
            try inbox.insert(db)

            // Destination epoch is intentionally left nil — see doc above.
            let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
            try archive.insert(db)
        }
        return (pool, dir, previous)
    }

    private func restoreTestDB(pool: DatabasePool, previous: AppDatabase?, dir: URL) {
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }

    /// Inserts a durable header and returns the stored row.
    /// `messageId` is numeric (an IMAP UID) and `rfc822MessageId` is supplied, so
    /// `stableId` resolves to the RFC id — the ordinary shape for a synced message.
    @MainActor
    private func insertMessage(
        _ pool: DatabasePool,
        messageId: String,
        folderPath: String = "INBOX",
        rfc822MessageId: String? = "rfc-\(UUID().uuidString)@example.com"
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: "Subject \(messageId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "snippet",
            folderId: "acc1:\(folderPath)",
            accountId: "acc1",
            folderPath: folderPath,
            isInInbox: folderPath == "INBOX"
        )
        header.headerComplete = true
        header.rfc822MessageId = rfc822MessageId
        try pool.writeWithoutTransaction { db in try header.insert(db) }
        let stored = try pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        return try #require(stored)
    }

    private func ops(_ pool: DatabasePool) async throws -> [PendingOperation] {
        try await pool.read { db in try PendingOperation.fetchAll(db) }
    }

    private func header(_ pool: DatabasePool, _ id: String) async throws -> MessageHeader? {
        try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
    }

    // MARK: - 1. IMAP + nil epoch + new user gesture → refused, atomically

    @Test("IMAP, nil epoch: markRead admits no op AND leaves isRead untouched")
    @MainActor
    func imapNilEpochRefusesMarkRead() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "101")
        #expect(msg.isRead == false)

        await AccountManager.shared.markRead([msg])

        #expect(try await ops(pool).isEmpty, "a nil-epoch IMAP folder must admit no durable op")
        #expect(try await header(pool, msg.id)?.isRead == false,
                "the optimistic local mutation must NOT land when the op is refused")
    }

    @Test("IMAP, nil epoch: markFlagged admits no op AND leaves isFlagged untouched")
    @MainActor
    func imapNilEpochRefusesMarkFlagged() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "102")

        await AccountManager.shared.markFlagged([msg], flagged: true)

        #expect(try await ops(pool).isEmpty)
        #expect(try await header(pool, msg.id)?.isFlagged == false,
                "the optimistic local mutation must NOT land when the op is refused")
    }

    @Test("IMAP, nil epoch: move admits no op AND leaves the message in its source folder")
    @MainActor
    func imapNilEpochRefusesMove() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "103")

        await AccountManager.shared.move([msg], to: "Archive")

        #expect(try await ops(pool).isEmpty)
        let stored = try await header(pool, msg.id)
        #expect(stored?.folderId == "acc1:INBOX",
                "a refused move must not relocate the row locally")
        #expect(stored?.folderPath == "INBOX")
    }

    @Test("iCloud is an IMAP account — nil epoch refuses just like .imap")
    @MainActor
    func icloudNilEpochRefusesMarkRead() async throws {
        // Guards the known `.imap`-only predicate trap: several sync sites test
        // `provider == .imap` alone and silently exclude iCloud, which IS IMAP.
        let (pool, dir, previous) = try makeTestDB(provider: .icloud, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "104")

        await AccountManager.shared.markRead([msg])

        #expect(try await ops(pool).isEmpty)
        #expect(try await header(pool, msg.id)?.isRead == false)
    }

    // MARK: - 2. IMAP + known epoch → admitted exactly as before (regression guard)

    @Test("IMAP, known epoch: markRead is admitted exactly as today")
    @MainActor
    func imapKnownEpochAdmitsMarkRead() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "201")

        await AccountManager.shared.markRead([msg])

        let rows = try await ops(pool)
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .markRead)
        #expect(rows[0].messageIds == [msg.stableId])
        #expect(rows[0].folderPath == "INBOX")
        #expect(try await header(pool, msg.id)?.isRead == true)
    }

    @Test("IMAP, known SOURCE epoch and nil DESTINATION epoch: move is admitted")
    @MainActor
    func imapKnownEpochAdmitsMoveDespiteNilDestinationEpoch() async throws {
        // The Archive folder's epoch is nil in this fixture. UID resolution for a
        // move happens in the SOURCE mailbox, so the destination's unknown epoch
        // must not refuse the gesture. If this test ever fails, the guard has been
        // wired to the wrong folder.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let archiveEpoch = try await pool.read { db in
            try Folder.fetchOne(db, key: "acc1:Archive")?.lastKnownUidValidity
        }
        #expect(archiveEpoch == nil, "fixture precondition: destination epoch is unknown")

        let msg = try insertMessage(pool, messageId: "202")

        await AccountManager.shared.move([msg], to: "Archive")

        let rows = try await ops(pool)
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .move)
        #expect(rows[0].folderPath == "INBOX")
        #expect(rows[0].destinationPath == "Archive")
        #expect(try await header(pool, msg.id)?.folderId == "acc1:Archive")
    }

    // MARK: - 3 & 4. ANTI-BRICK — Gmail and Exchange are nil FOREVER, must admit

    @Test("ANTI-BRICK: Gmail account with a nil epoch is ADMITTED, not refused")
    @MainActor
    func gmailNilEpochAdmitsMarkRead() async throws {
        // Gmail never populates FolderInfo.uidValidity, so this column is nil for
        // the life of the account. A refusal here is a permanently bricked account.
        let (pool, dir, previous) = try makeTestDB(provider: .gmail, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "gmail-301", rfc822MessageId: nil)

        await AccountManager.shared.markRead([msg])

        let rows = try await ops(pool)
        #expect(rows.count == 1, "Gmail's permanently-nil epoch must never refuse an action")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .markRead)
        #expect(try await header(pool, msg.id)?.isRead == true)
    }

    @Test("ANTI-BRICK: Gmail account with a nil epoch admits a move")
    @MainActor
    func gmailNilEpochAdmitsMove() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .gmail, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "gmail-302", rfc822MessageId: nil)

        await AccountManager.shared.move([msg], to: "Archive")

        let rows = try await ops(pool)
        #expect(rows.count == 1, "Gmail's permanently-nil epoch must never refuse a move")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .move)
        #expect(try await header(pool, msg.id)?.folderId == "acc1:Archive")
    }

    @Test("ANTI-BRICK: Exchange account with a nil epoch is ADMITTED, not refused")
    @MainActor
    func exchangeNilEpochAdmitsMarkRead() async throws {
        // Same reasoning as Gmail: the Graph provider never reports UIDVALIDITY.
        let (pool, dir, previous) = try makeTestDB(provider: .outlook, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "graph-401", rfc822MessageId: nil)

        await AccountManager.shared.markRead([msg])

        let rows = try await ops(pool)
        #expect(rows.count == 1, "Exchange's permanently-nil epoch must never refuse an action")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .markRead)
        #expect(try await header(pool, msg.id)?.isRead == true)
    }

    @Test("ANTI-BRICK: Exchange account with a nil epoch admits a move")
    @MainActor
    func exchangeNilEpochAdmitsMove() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .outlook, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "graph-402", rfc822MessageId: nil)

        await AccountManager.shared.move([msg], to: "Archive")

        let rows = try await ops(pool)
        #expect(rows.count == 1, "Exchange's permanently-nil epoch must never refuse a move")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .move)
        #expect(try await header(pool, msg.id)?.folderId == "acc1:Archive")
    }

    // MARK: - 5. System-generated ops are NOT governed by T1.3 — still admitted

    @Test("System op: undo's compensating move-back is admitted under a nil epoch")
    @MainActor
    func imapNilEpochStillAdmitsUndoMoveBack() async throws {
        // Owner decision §9 D6: T1.3 governs only NEW gestures. The move-back is a
        // compensating op for work the server has already done, and on IMAP it is
        // addressed by rfc822MessageId — a Message-ID SEARCH, which is immune to a
        // UIDVALIDITY change. Refusing it would strand the message, not protect it.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "501", folderPath: "Archive",
                                    rfc822MessageId: "rfc-501@example.com")

        await AccountManager.shared.undoDestructiveAction(
            [msg],
            accountId: "acc1",
            originalOpType: .move,
            fromFolderPath: "Archive",
            toFolderPath: "INBOX",
            toFolderId: "acc1:INBOX"
        )

        let rows = try await ops(pool)
        #expect(rows.count == 1, "a system-generated compensating move must still be admitted")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .move)
        #expect(rows[0].messageIds == ["rfc-501@example.com"])
    }

    @Test("System op: a local-only tag write is admitted under a nil epoch")
    @MainActor
    func imapNilEpochStillAdmitsTagWrite() async throws {
        // Action tags are local-only (ADR-IOS-036) and `.setTag` drains to a
        // provider no-op, so a tag op can never mutate a message on the server —
        // there is nothing for an unknown epoch to endanger. Guarding it would
        // drop user intent for zero safety gain.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "502", rfc822MessageId: "rfc-502@example.com")

        AccountManager.queueTagWrite(
            accountId: "acc1",
            messageId: msg.messageId,
            rfc822MessageId: msg.rfc822MessageId,
            tag: ActionTag.reply,
            folder: "INBOX"
        )

        let rows = try await ops(pool)
        #expect(rows.count == 1, "a local-only tag write is not an epoch-sensitive action")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .setTag)
    }
}
