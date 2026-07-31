/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// T1.3 anti-brick — a **custom NON-FAVOURITE folder** must not be permanently
/// ungesturable.
///
/// THE SYSTEM PROPERTY (not the mechanism): after the account's crawler has
/// visited such a folder, a user gesture on a message in it is **ADMITTED** — an
/// op row exists and the optimistic local mutation lands. The test deliberately
/// asserts admission, never "the column is non-nil": a mechanism assertion would
/// stay green if the stamp landed but the guard read something else, which is the
/// exact failure mode that produced two regressions earlier in this audit train.
///
/// Why this folder class and no other. `syncableFolders` — built identically in
/// full sync, delta sync and self-heal — is `primaryRoles ∪ secondaryRoles ∪
/// favourites`, so a custom non-favourite folder is never handed to
/// `runSyncMessages` and its T1.2b SELECT-sourced bootstrap never runs for it.
/// Its only other epoch source is `fetchFolders`' STATUS, and SwiftMail requests
/// the `UIDVALIDITY` STATUS attribute **only when the server advertises UIDPLUS**
/// (`IMAPServer+Mailbox.swift`, `mailboxStatus`), so on the server modelled here
/// STATUS contributes nothing. `runBackfill` nonetheless crawls the folder and
/// makes its mail searchable account-wide — so before this fix every gesture on
/// that mail was refused FOREVER. That is a brick, not the bounded first-sync
/// window `IOS-EPOCH-001` describes, and the owner's rule is explicit: a
/// permanent refusal is a product bug; a transient one that self-heals is fine.
///
/// The mailbox is deliberately EMPTY and the folder starts with a
/// `backfillUidCursor` already set. That combination drives exactly the code
/// under test — pinned-connection SELECT → UID SEARCH → cursor confirm → epoch
/// bootstrap — while touching none of the process-global singletons a populated
/// crawl would (`SearchIndex.shared`, `BackfillBodyQueue.shared`). An empty
/// mailbox with NO cursor would take `runBackfill`'s `UIDNEXT == 1` early-out and
/// never reach the walk at all.
///
/// ⚑ R0: `v2final` solves the same problem differently and its solution does not
/// transfer. There, `IMAPProvider.selectMailboxTracked` is the single chokepoint
/// EVERY `selectMailbox` call site routes through, and it fires
/// `onUidValidityObserved` → `AccountManager.recordObservedUidValidity`, which
/// persists to the `Folder` row — so a backfill SELECT persisted for free. v3
/// narrowed that chokepoint on purpose (see the "SECOND DEVIATION" note on its
/// own `selectMailboxTracked`: the reference's width exists to carry a Stage-2
/// refusal v3 does not have, and a mirror written by every action SELECT has more
/// ways to be overwritten between a pass's fetch and its read). What is ported is
/// the PERSIST STEP, onto the observation v3's narrower chokepoint already makes.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`, drives
/// `AccountManager.shared`, and binds a listening socket via `FakeIMAPServer`.
@Suite("T1.3 anti-brick — a backfill-only folder becomes gesturable", .serialized, .processGlobalState)
struct BackfillOnlyFolderEpochTests {

    // MARK: - Fixtures

    /// `FakeIMAPServer.defaultCapabilities` minus `UIDPLUS`, so no epoch can reach
    /// the column from STATUS and the one that does can only have come from the
    /// crawl's own SELECT.
    private static let nonUidplusCapabilities =
        ["IMAP4rev1", "AUTH=PLAIN", "LITERAL+", "ID", "NAMESPACE", "MOVE", "IDLE"]

    private static func provider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
    }

    private static func makeEngine(accountId: String, provider: IMAPProvider) async -> SyncEngine {
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        return engine
    }

    /// A custom, NON-favourite folder with a live backfill cursor — the exact
    /// shape `syncableFolders` excludes and `runBackfill` includes.
    private static func insertBackfillOnlyFolder(
        accountId: String, path: String, pool: DatabasePool,
        cursor: Int, epoch: Int? = nil
    ) throws {
        try pool.write { db in
            var folder = Folder(name: path, path: path, role: .custom, accountId: accountId)
            folder.isFavorite = false
            folder.backfillComplete = false
            folder.backfillUidCursor = cursor
            folder.lastKnownUidValidity = epoch
            try folder.insert(db)
        }
    }

    private static func insertHeader(
        accountId: String, path: String, uid: String, pool: DatabasePool
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "backfill-only fixture \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "snippet",
            folderId: "\(accountId):\(path)", accountId: accountId, folderPath: path,
            isInInbox: false
        )
        header.headerComplete = true
        header.rfc822MessageId = "backfill-only-\(uid)@example.com"
        let toInsert = header
        try pool.write { db in try toInsert.insert(db) }
        return try #require(try pool.read { db in try MessageHeader.fetchOne(db, key: toInsert.id) })
    }

    private static func ops(_ pool: DatabasePool) throws -> [PendingOperation] {
        try pool.read { db in try PendingOperation.fetchAll(db) }
    }

    // MARK: - The property

    @Test("A gesture on a message in a custom non-favourite folder is ADMITTED once backfill has crawled it")
    @MainActor
    func backfillOnlyFolderStopsRefusingGesturesAfterACrawl() async throws {
        let liveEpoch = 913_101
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [], "Receipts": []])
        server.setUidValidity(liveEpoch, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-backfill-only"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(accountId: accountId, path: "Receipts", pool: pool, cursor: 5)
        let msg = try Self.insertHeader(accountId: accountId, path: "Receipts", uid: "1", pool: pool)

        // PRECONDITION — this is the brick. The folder holds mail that account-wide
        // search can reach, and every gesture on it is a silent no-op.
        await AccountManager.shared.markRead([msg])
        #expect(try Self.ops(pool).isEmpty,
                "precondition: with no known epoch the gesture is refused")
        let readBefore = try await pool.read { db in try MessageHeader.fetchOne(db, key: msg.id) }?.isRead
        #expect(readBefore == false,
                "precondition: the optimistic flip is refused with the op")

        // The crawl — the only pass that ever visits this folder.
        let imap = Self.provider(for: server)
        try await imap.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        _ = await engine.runBackfill(account: account)
        try? await imap.disconnect()

        // THE PROPERTY. The same gesture, on the same message, is now admitted —
        // op row AND local mutation together.
        await AccountManager.shared.markRead([msg])
        let rows = try Self.ops(pool)
        #expect(rows.count == 1,
                """
                a gesture on a backfill-crawled custom folder is still refused after the crawl — \
                that refusal is PERMANENT, because no other pass ever SELECTs this folder
                """)
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .markRead)
        let readAfter = try await pool.read { db in try MessageHeader.fetchOne(db, key: msg.id) }?.isRead
        #expect(readAfter == true,
                "an admitted gesture must land its optimistic mutation")
    }

    @Test("The crawl's epoch write is BOOTSTRAP-ONLY — it never overwrites a stored epoch")
    @MainActor
    func backfillEpochWriteNeverOverwritesAStoredEpoch() async throws {
        // The safety property the ADR-IOS-051 deletion-reconcile walk depends on: a
        // populated `lastKnownUidValidity` ARMS its abort guard, and a live epoch
        // stamped over the one the local UIDs belong to DISARMS it, turning the walk
        // into a mass-deleter. A new writer that fixed the brick by writing
        // unconditionally would trade a silent no-op for silent data loss.
        let storedEpoch = 913_201
        let liveEpoch = 913_202
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [], "Receipts": []])
        server.setUidValidity(liveEpoch, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-backfill-bootstrap"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(
            accountId: accountId, path: "Receipts", pool: pool, cursor: 5, epoch: storedEpoch)

        let imap = Self.provider(for: server)
        try await imap.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        _ = await engine.runBackfill(account: account)
        try? await imap.disconnect()

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(after?.lastKnownUidValidity == storedEpoch,
                """
                the crawl overwrote the epoch the LOCAL UIDs belong to with the live one \
                (\(String(describing: after?.lastKnownUidValidity)) vs stored \(storedEpoch)) — \
                that disarms the deletion-reconcile walk's abort guard
                """)
    }
}
