/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// T1.3 anti-brick, and the round-8 correction to it — the crawl may unlock a
/// folder's gestures ONLY with an epoch that provably describes the UIDs it is
/// unlocking.
///
/// TWO SYSTEM PROPERTIES, in tension, and both are asserted here:
///
/// 1. **A folder that only the crawler visits must not stay ungesturable.**
///    `syncableFolders` — built identically in full sync, delta sync and
///    self-heal — is `primaryRoles ∪ secondaryRoles ∪ favourites`, so no
///    SCHEDULED pass hands a custom non-favourite folder to `runSyncMessages`,
///    while `runBackfill` crawls it and makes its mail searchable account-wide.
///    On a non-UIDPLUS server `fetchFolders`' STATUS contributes no epoch
///    either (SwiftMail requests the `UIDVALIDITY` attribute only when the
///    server advertises UIDPLUS), so without the crawl's own bootstrap the
///    column stays nil and every gesture on that mail is a silent no-op.
///
///    ⚠ **The round-7 claim that this refusal was PERMANENT is retracted.**
///    On-demand navigation reaches ANY folder: `InboxView.onAppear` →
///    `InboxViewModel.startSync()` → `performSync()` →
///    `AccountManager.syncFolders(_:)` (in the FILE `AccountManagerFetch.swift`
///    — its filter is `!folder.path.isEmpty` and nothing else) →
///    `SyncEngine.syncFolderMessages` → `syncMessages` → `runSyncMessages`,
///    which carries T1.2b's SELECT-sourced bootstrap. The window was
///    INDEFINITE — until the user opens that folder — not forever. It is still
///    worth closing, because search reaches the mail long before the user opens
///    the folder.
///
/// 2. **The epoch stamped must belong to the UIDs it unlocks.**
///    `AccountManager.newGestureRefusedForUnknownEpoch` tests only for nil; it
///    never compares stored against live. So ANY value unlocks everything, and
///    `MessageHeader.stableId` falls back to a bare numeric UID whenever a
///    header has no `rfc822MessageId` — which `IMAPProvider.resolveUID` treats
///    as a literal UID. Stamp an epoch the local rows do not belong to and the
///    next gesture mutates whatever message now occupies that number.
///    Constraint C3, the one hard invariant.
///
/// Property 2 is what round 7 got wrong and round 8 fixes: it sampled the
/// provider's epoch mirror ONCE after the walk, and backfill's own SELECTs were
/// raw, so the mirror held the epoch observed when the pinned connection was
/// CREATED. `resumedCrawlNeverStampsAnEpochItsExistingHeadersDoNotBelongTo` is
/// the adversarial test for it, and it drives a real gesture through a real
/// `IMAPProvider` against the `FakeIMAPServer` **wrong-message wire oracle** —
/// the invariant harness — rather than asserting a column value.
///
/// ⚑ R0: `v2final` binds the epoch the same way — every backfill SELECT routed
/// through `IMAPProvider.selectMailboxTracked`, a walk-scoped epoch captured
/// once at walk start, a per-chunk capture that refuses (never confirms) a
/// disagreeing range. What does NOT transfer is its recovery: `v2final` carries
/// the ADR-IOS-061 reset reaction (quarantine → purge the old epoch's rows →
/// stamp → resync), so a folder holding rows of a superseded epoch heals. v3
/// has none of that, so a folder that already holds rows of unproven epoch
/// simply is not stamped — fail-closed (C6).
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared`, drives
/// `AccountManager.shared`, and binds a listening socket via `FakeIMAPServer`.
@Suite("T1.3 anti-brick — the crawl unlocks a folder only with ITS OWN epoch", .serialized, .processGlobalState)
struct BackfillOnlyFolderEpochTests {

    // MARK: - Fixtures

    /// `FakeIMAPServer.defaultCapabilities` minus `UIDPLUS`, so no epoch can reach
    /// the column from STATUS and the one that does can only have come from the
    /// crawl's own SELECT.
    private static let nonUidplusCapabilities =
        ["IMAP4rev1", "AUTH=PLAIN", "LITERAL+", "ID", "NAMESPACE", "MOVE", "IDLE"]

    private static func rfc822(messageId: String, subject: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: \(subject)\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        backfill epoch fixture body.\r

        """
    }

    private static func message(uid: Int, id: String, subject: String = "crawled") -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: id, subject: subject))
    }

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

    /// A custom, NON-favourite folder — the exact shape `syncableFolders`
    /// excludes and `runBackfill` includes. `cursor: nil` is a FRESH crawl;
    /// a value is a crawl RESUMING from an earlier pass.
    private static func insertBackfillOnlyFolder(
        accountId: String, path: String, pool: DatabasePool,
        cursor: Int?, epoch: Int? = nil
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

    /// A LOCAL header row with a bare numeric `messageId` (the IMAP UID) and —
    /// when `rfc822MessageId` is nil — no durable identity of its own, so
    /// `MessageHeader.stableId` falls back to that bare UID. That fallback is
    /// the entire reason the epoch matters, and the round-7 test's header
    /// carried an RFC Message-ID, which made its queued op epoch-IMMUNE and the
    /// test blind to the defect it was meant to pin.
    @discardableResult
    private static func insertHeader(
        accountId: String, path: String, uid: String, pool: DatabasePool,
        rfc822MessageId: String?
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "pre-existing fixture \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "snippet",
            folderId: "\(accountId):\(path)", accountId: accountId, folderPath: path,
            isInInbox: false
        )
        header.headerComplete = true
        header.rfc822MessageId = rfc822MessageId
        let toInsert = header
        try pool.write { db in try toInsert.insert(db) }
        return try #require(try pool.read { db in try MessageHeader.fetchOne(db, key: toInsert.id) })
    }

    private static func ops(_ pool: DatabasePool) throws -> [PendingOperation] {
        try pool.read { db in try PendingOperation.fetchAll(db) }
    }

    private static func headers(_ pool: DatabasePool, folderId: String) throws -> [MessageHeader] {
        try pool.read { db in
            try MessageHeader.filter(Column("folderId") == folderId)
                .order(Column("messageId"))
                .fetchAll(db)
        }
    }

    // MARK: - Property 1 — the crawl unlocks the folder

    /// The crawl FETCHES the mail from the server in this test rather than
    /// finding it pre-inserted: the property is "mail the crawler put here is
    /// gesturable", and a locally-seeded row cannot demonstrate that the epoch
    /// the crawl stamped is the epoch the crawl's own inserts belong to.
    @Test("A gesture on a message the crawl itself fetched is ADMITTED, and lands on that message")
    @MainActor
    func backfillOnlyFolderStopsRefusingGesturesAfterACrawl() async throws {
        let liveEpoch = 913_101
        let crawledRfc = "crawled-receipt@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: [
                "INBOX": [],
                "Receipts": [Self.message(uid: 7, id: crawledRfc)],
            ])
        server.setUidValidity(liveEpoch, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-backfill-only"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(accountId: accountId, path: "Receipts", pool: pool, cursor: nil)

        // PRECONDITION — the brick. Nothing local yet, and nothing can gesture.
        #expect(try Self.headers(pool, folderId: "\(accountId):Receipts").isEmpty)

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        _ = await engine.runBackfill(account: account)

        let crawled = try Self.headers(pool, folderId: "\(accountId):Receipts")
        #expect(crawled.count == 1, "precondition: the crawl inserted the server's message")
        guard crawled.count == 1 else { return }

        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: imap)
        defer { Task { await AccountManager.shared.unregisterProviderForTesting(accountId: accountId) } }
        server.expectMutation(rfc822MessageId: crawledRfc)
        await AccountManager.shared.markRead([crawled[0]])

        // THE PROPERTY, part 1 — ADMITTED, asserted on the DURABLE effect rather
        // than on the queue row. `PendingOperation` is transient: the drain loop
        // deletes it on success, and it can do so before the assertion runs (it
        // did, the moment this suite was run alongside another). The optimistic
        // local mutation is not transient, and a REFUSED gesture provably does
        // not perform it — that is exactly what `imapNilEpochRefusesMarkRead`
        // pins from the other side.
        let afterGesture = try #require(try Self.headers(pool, folderId: "\(accountId):Receipts").first)
        #expect(afterGesture.isRead,
                """
                a gesture on a crawled custom folder is still refused after the crawl — \
                the folder's mail is account-wide searchable and cannot be acted on
                """)

        // THE PROPERTY, part 2 — it reached the WIRE, on the RIGHT message. Both
        // halves are needed: a refusal makes no provider call at all (so the
        // STORE proves admission independently of the DB), and the oracle proves
        // the call landed on the message the gesture named.
        //
        // Drained in a bounded loop rather than once: the queue drain is a single
        // shared serialized loop, so a call made while another suite's drain is
        // still running returns immediately without touching this op. The loop
        // exits on the first STORE (one iteration, in practice) and cannot hang.
        var stores: [String] = []
        for _ in 0..<100 {
            await AccountManager.shared.drainPendingQueue()
            stores = server.recordedCommands().filter { $0.contains("STORE") }
            if !stores.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!stores.isEmpty,
                "the admitted gesture never reached the server: \(server.recordedCommands())")
        #expect(server.wrongMessageViolations().isEmpty,
                "the admitted gesture mutated a message it never targeted: \(server.wrongMessageViolations())")
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

    // MARK: - Property 2 — the epoch must belong to the UIDs it unlocks

    /// 🚨 THE ADVERSARIAL TEST FOR THE ROUND-7 BLOCKER.
    ///
    /// The scenario, exactly as the audit stated it: a custom folder has
    /// `lastKnownUidValidity == nil` and PARTIALLY-BACKFILLED epoch-E1 headers,
    /// including a bare UID with no RFC Message-ID. The mailbox then rolls to
    /// E2 and REUSES that UID for a different message. The crawl resumes, its
    /// fresh connection observes E2 — and round 7 stamped E2 while the E1
    /// header still sat in the database.
    ///
    /// THE INVARIANT, asserted on the WIRE and not on a column: no mutation may
    /// land on a message the user's gesture did not target. The `FakeIMAPServer`
    /// wrong-message oracle resolves every `UID STORE`/`MOVE`/`COPY`/`EXPUNGE`
    /// to the mailbox's CURRENT occupant, pre-mutation, and records a violation
    /// when that occupant is not one the test declared. Here the test declares
    /// the E1 message the user is acting on; the decoy that now occupies its UID
    /// is declared by nobody, so any command that touches it is a violation by
    /// construction — and no production change can make that declaration
    /// correct.
    ///
    /// The refusal is the accepted outcome (C6/C3): the folder keeps its nil
    /// epoch because nothing can prove which epoch its existing rows belong to.
    /// That is a silent no-op; the alternative is silent corruption.
    @Test("A resumed crawl never stamps an epoch its EXISTING headers do not belong to")
    @MainActor
    func resumedCrawlNeverStampsAnEpochItsExistingHeadersDoNotBelongTo() async throws {
        // The folder's stored epoch is nil — the E1 the local header belongs to is
        // precisely what nothing on the device can name. Only the NEW one exists
        // anywhere observable, which is what makes stamping it so tempting.
        let newEpoch = 913_302
        let victimRfc = "e1-victim@example.com"
        let decoyRfc = "e2-decoy@example.com"
        // The mailbox is ALREADY in its new epoch when the crawl resumes: UID 42
        // now names a completely different message.
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: [
                "INBOX": [],
                "Receipts": [Self.message(uid: 42, id: decoyRfc, subject: "decoy")],
            ])
        server.setUidValidity(newEpoch, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-resumed-turnover"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(accountId: accountId, path: "Receipts", pool: pool, cursor: 60)
        // The E1 leftover: bare UID 42, NO rfc822MessageId, so `stableId` is "42"
        // and `IMAPProvider.resolveUID` will treat it as a literal UID.
        let victim = try Self.insertHeader(
            accountId: accountId, path: "Receipts", uid: "42", pool: pool, rfc822MessageId: nil)
        #expect(victim.stableId == "42",
                "fixture precondition: the header's durable identity IS the bare UID")

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        _ = await engine.runBackfill(account: account)

        // The crawl saw epoch \(newEpoch) on every SELECT it made. It must not
        // assert that of a row it did not write.
        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(after?.lastKnownUidValidity == nil,
                """
                the crawl stamped \(String(describing: after?.lastKnownUidValidity)) on a folder \
                holding headers from a DIFFERENT epoch — that epoch describes none of them, and \
                it unlocks every bare-UID gesture on all of them
                """)

        // THE WIRE INVARIANT. Declare the message the user is acting on; the
        // decoy now occupying UID 42 is declared by nobody.
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: imap)
        defer { Task { await AccountManager.shared.unregisterProviderForTesting(accountId: accountId) } }
        server.expectMutation(rfc822MessageId: victimRfc)
        await AccountManager.shared.markRead([victim])
        await AccountManager.shared.drainPendingQueue()

        #expect(server.wrongMessageViolations().isEmpty,
                """
                a gesture on an old-epoch header mutated the message that inherited its UID: \
                \(server.wrongMessageViolations())
                """)
        #expect(try Self.ops(pool).isEmpty,
                "the gesture must be REFUSED — nothing can prove which epoch this header's UID belongs to")
        #expect(try Self.headers(pool, folderId: "\(accountId):Receipts").first?.isRead == false,
                "a refused gesture must not perform its optimistic local mutation either")
    }

    /// A turnover DURING the walk must not leave the folder holding UIDs from
    /// two different numberings under one stamp.
    ///
    /// THE INVARIANT: every header row in the folder, plus the stamp on the
    /// folder, come from ONE epoch. A mixed population is what makes a bare-UID
    /// gesture unsafe — half the rows resolve against a numbering that no longer
    /// exists — and round 7's post-walk sample produced exactly that: it
    /// inserted the pre-turnover chunk's rows AND the post-turnover chunk's,
    /// then stamped whichever epoch the mirror happened to hold last.
    ///
    /// `resetMailboxAfterNextSuccessfulResponse` applies a complete epoch
    /// replacement — UIDVALIDITY, message list and flags — immediately after the
    /// first `UID SEARCH` response is written, i.e. between the walk's own
    /// SEARCH and its FETCH.
    @Test("A UIDVALIDITY turnover mid-walk never mixes two epochs into one folder")
    @MainActor
    func aTurnoverMidWalkNeverMixesEpochsIntoTheFolder() async throws {
        let oldEpoch = 913_401
        let newEpoch = 913_402
        let originalRfc = "pre-turnover@example.com"
        let replacementRfc = "post-turnover@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: [
                "INBOX": [],
                "Receipts": [Self.message(uid: 9, id: originalRfc, subject: "pre")],
            ])
        server.setUidValidity(oldEpoch, for: "Receipts")
        // The mailbox is re-created the instant the walk's first UID SEARCH is
        // answered — the same UID, a different message, a new epoch.
        server.resetMailboxAfterNextSuccessfulResponse(
            containing: "UID SEARCH",
            mailbox: "Receipts",
            uidValidity: newEpoch,
            messages: [Self.message(uid: 9, id: replacementRfc, subject: "post")])
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-midwalk-turnover"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(accountId: accountId, path: "Receipts", pool: pool, cursor: nil)

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        _ = await engine.runBackfill(account: account)

        let stored = try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Receipts", pool: pool)?.lastKnownUidValidity
        let rows = try Self.headers(pool, folderId: "\(accountId):Receipts")
        let insertedRfcs = Set(rows.compactMap(\.rfc822MessageId))

        // The stamp was taken at walk START, before anything was inserted, so it
        // can only ever be the OLD epoch (or nothing at all).
        #expect(stored == nil || stored == oldEpoch,
                """
                the folder is stamped \(String(describing: stored)), which is neither unknown nor \
                the epoch this walk started in — a post-walk sample of the live mirror
                """)
        // …and NOTHING fetched after the turnover may have been inserted under it.
        #expect(!insertedRfcs.contains(replacementRfc),
                """
                a header fetched AFTER the mailbox was re-created was inserted into a folder \
                stamped with the pre-turnover epoch — the folder now holds UIDs from two \
                numberings and half of them resolve against a mailbox that no longer exists. \
                Rows: \(rows.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)
        // Fail-closed, not silently-complete: a pass that saw the mailbox move
        // must not claim the folder is fully crawled.
        let folderAfter = try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Receipts", pool: pool)
        #expect(folderAfter?.backfillComplete == false,
                "a pass whose UID space was invalidated must not stamp the crawl complete")
    }
}
