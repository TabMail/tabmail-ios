/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
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
///    header has no `rfc822MessageId` — which native IMAP actions address
///    directly. Stamp an epoch the local rows do not belong to and the
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

        try await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: imap
        ) {
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
    }

    @Test("The crawl never re-stamps a folder that HOLDS ROWS of the stored epoch")
    @MainActor
    func backfillEpochWriteNeverOverwritesAStoredEpoch() async throws {
        // The safety property the ADR-IOS-051 deletion-reconcile walk depends on: a
        // populated `lastKnownUidValidity` ARMS its abort guard, and a live epoch
        // stamped over the one the local UIDs belong to DISARMS it, turning the walk
        // into a mass-deleter. A new writer that fixed the brick by writing
        // unconditionally would trade a silent no-op for silent data loss.
        //
        // ⚠ ROUND 10 — this test used to run with an EMPTY folder, which made it
        // pin the MECHANISM ("the epoch column is never re-written") instead of the
        // invariant ("no row is ever left under a stamp it does not belong to").
        // Those are not the same claim, and the difference is a permanent brick:
        // an empty folder holds no row for the stamp to be wrong about, so its
        // stale stamp can and must be dropped (see
        // `aTurnoverMidWalkNeverMixesEpochsIntoTheFolder`, whose SECOND
        // `runBackfill` call asserts exactly that). The folder here therefore
        // HOLDS a row from the stored epoch — the state the mechanism actually
        // exists to protect.
        //
        // ⚠ NB2 (round 12): this citation used to name
        // `anEmptyFolderIsNeverPermanentlyRefusedAfterATurnover`, which is not a
        // symbol anywhere in the tree — `rg -n` for it returned exactly one hit,
        // the citation itself.
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
        // A row written under `storedEpoch`. Its bare UID is what the stamp is a
        // claim ABOUT, and re-stamping would make that claim false.
        try Self.insertHeader(
            accountId: accountId, path: "Receipts", uid: "3", pool: pool, rfc822MessageId: nil)

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
        #expect(try Self.headers(pool, folderId: "\(accountId):Receipts").count == 1,
                "a folder the crawl declined must not have gained rows from the declining pass")
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
        // and native IMAP actions will address it directly.
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
        await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: imap
        ) {
            server.expectMutation(rfc822MessageId: victimRfc)
            await AccountManager.shared.markRead([victim])
            await AccountManager.shared.drainPendingQueue()
        }

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

        // ── ROUND 10, BLOCKER 1: THE SECOND CALL ──────────────────────────
        //
        // The state the first call leaves behind is the brick, and stopping the
        // test here is what hid it for two rounds: the folder is EMPTY, still
        // incomplete, carries the cursor its fresh-cursor transaction planted, and
        // is durably stamped with the epoch that transaction observed — while the
        // server is now on a different one. Every later `runBackfill` re-reads
        // that mismatch and declines the folder again, and no epoch writer can
        // move a stamp once set, so the refusal never lifts. (The per-call decline
        // SET really is transient — function-local, gone when the call returns.
        // The durable stamp is what re-inserts the folder into it on every call.
        // A transient container plus a durable re-entry condition is a PERMANENT
        // refusal.)
        //
        // THE INVARIANT: **a folder holding zero headers is never permanently
        // refused by the crawl.** It is asserted on mail arriving and on that mail
        // being actionable — never on the decline set being empty, which is the
        // mechanism and which stays "correct" on a bricked system.
        #expect(try Self.headers(pool, folderId: "\(accountId):Receipts").isEmpty,
                "precondition for the brick: the interrupted pass inserted nothing")
        #expect(folderAfter?.backfillUidCursor != nil,
                "precondition for the brick: the pass left a cursor behind")
        #expect(folderAfter?.lastKnownUidValidity == oldEpoch,
                "precondition for the brick: the folder is durably stamped with the pre-turnover epoch")

        _ = await engine.runBackfill(account: account)

        let recovered = try Self.headers(pool, folderId: "\(accountId):Receipts")
        let recoveredRfcs = Set(recovered.compactMap(\.rfc822MessageId))
        #expect(recoveredRfcs.contains(replacementRfc),
                """
                a SECOND crawl of an EMPTY folder whose stamp predates a turnover fetched \
                nothing — the folder is permanently refused: its stored epoch can never agree \
                with the live one again, and no writer may advance it. Rows: \
                \(recovered.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)
        #expect(!recoveredRfcs.contains(originalRfc),
                "the recovered crawl must not resurrect a pre-turnover message")

        let folderRecovered = try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Receipts", pool: pool)
        #expect(folderRecovered?.lastKnownUidValidity == newEpoch,
                """
                the recovered folder is stamped \(String(describing: folderRecovered?.lastKnownUidValidity)), \
                not the epoch its rows were fetched under — every row in a folder and the \
                folder's stamp must come from ONE epoch
                """)

        // …and the mail is actionable, which is the whole point of the stamp.
        guard let crawled = recovered.first else { return }
        await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: imap
        ) {
            server.expectMutation(rfc822MessageId: replacementRfc)
            await AccountManager.shared.markRead([crawled])
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(try Self.headers(pool, folderId: "\(accountId):Receipts").first?.isRead == true,
                "a gesture on the recovered folder's mail is still refused — the folder is unusable")
        #expect(server.wrongMessageViolations().isEmpty,
                "the recovered folder's gesture mutated a message it never targeted: \(server.wrongMessageViolations())")
    }

    // MARK: - Round 10, blocker 2 — an unobservable epoch disables every check

    /// 🚨 A pass that could not observe the epoch of a folder that HAS one must
    /// not walk it.
    ///
    /// `crawlEpochAgrees` admitted any nil, so a nil `walkEpoch` reached
    /// `expectedEpoch` and made BOTH per-chunk checks return true
    /// unconditionally — the walk then inserted whatever the server served into a
    /// folder stamped with an epoch nothing in the pass had confirmed. Those rows
    /// carry bare UIDs of a numbering the stamp does not describe, and because the
    /// stamp is non-nil `AccountManager.newGestureRefusedForUnknownEpoch` keeps
    /// admitting gestures on them: an old UID resolves against whatever now
    /// occupies that number (C3).
    ///
    /// THE INVARIANT: **no row enters a folder under a stamp the inserting pass
    /// could not verify.** Asserted on the folder's durable population, not on
    /// which branch the code took.
    ///
    /// The fixture drives the "server reports no UIDVALIDITY on SELECT" cause,
    /// because it is the one a fake server can produce deterministically
    /// (`suppressSelectUidValidity`); the transient-failure cause the blocker is
    /// really about arrives at the same `walkEpoch == nil` through
    /// `getUidNextWithEpoch` throwing under `try?`, and both are refused by the
    /// same gate. A folder with a stored epoch proves the server DOES report one,
    /// which is exactly what makes refusing here safe for the epochless-server
    /// account the old comment protected — that account's folders have a nil
    /// stored epoch and are untouched (`anEpochlessServerIsStillCrawled`).
    @Test("A folder with a stored epoch is never walked under an epoch this pass could not observe")
    @MainActor
    func aFolderWithAStoredEpochIsNeverWalkedUnderAnUnobservedOne() async throws {
        let storedEpoch = 913_501
        let serverRfc = "unobserved-epoch@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: [
                "INBOX": [],
                "Receipts": [Self.message(uid: 7, id: serverRfc, subject: "server side")],
            ])
        // The SELECT omits `* OK [UIDVALIDITY n]` entirely, so every observation
        // this pass can make is nil.
        //
        // ⚠ RETRACTED (round 12) — this comment used to read "RFC 3501 §6.3.1
        // makes it a SHOULD". That is FALSE, and the same commit asserted the
        // opposite in `KNOWN_ISSUES.md` (IOS-EPOCH-001: "core IMAP4rev1 … every
        // server reports it on SELECT"). §6.3.1 lists UIDVALIDITY among the
        // REQUIRED OK untagged responses of SELECT — UNSEEN, PERMANENTFLAGS,
        // UIDNEXT, UIDVALIDITY — and says that if it is missing, the server does
        // not support unique identifiers; RFC 9051 §6.3.2 requires it too. So
        // this fixture models a NONCONFORMING server, and it is used here only
        // because it is the one deterministic way to drive `walkEpoch == nil`
        // from the wire. The gate refuses it for the reason `crawlEpochGate`
        // now states: a server with no UIDs is one this app cannot serve.
        server.suppressSelectUidValidity(for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-unobserved-epoch"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        // Stamped and resuming — the folder's rows belong to `storedEpoch`, so the
        // server demonstrably does report UIDVALIDITY for this account.
        try Self.insertBackfillOnlyFolder(
            accountId: accountId, path: "Receipts", pool: pool, cursor: 60, epoch: storedEpoch)
        try Self.insertHeader(
            accountId: accountId, path: "Receipts", uid: "4", pool: pool, rfc822MessageId: nil)

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        _ = await engine.runBackfill(account: account)

        #expect(imap.lastObservedUidValidity(folderPath: "Receipts") == nil,
                "precondition: this pass could observe no epoch at all")

        let rows = try Self.headers(pool, folderId: "\(accountId):Receipts")
        #expect(rows.count == 1 && !rows.contains { $0.rfc822MessageId == serverRfc },
                """
                the crawl inserted rows into a folder stamped UIDVALIDITY \(storedEpoch) without \
                confirming that epoch even once this pass — every per-chunk check was a no-op, so \
                nothing binds these UIDs to the stamp that keeps their gestures admitted. \
                Rows: \(rows.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(after?.backfillComplete == false,
                "a pass that could not verify the folder's epoch must not stamp the crawl complete")

        // ── ROUND 12, NB4(b): THE SECOND CALL, AND THE THIRD ─────────────────
        //
        // Running ONE crawl pins only "this pass refused", which stays green on a
        // system where the refusal never lifts. `.refuseUnobservedEpoch` MUTATES
        // NOTHING, so the state `stored = E, walk = nil` is re-created on every
        // later call: a per-call decline container with a DURABLE re-entry
        // condition, which is the shape that means PERMANENT, not "indefinite but
        // self-healing". Round 11 disclosed it as the latter. Both halves are
        // asserted here so the disclosure can never drift again:
        //   (1) while the server keeps omitting UIDVALIDITY from SELECT, the
        //       refusal RECURS — this is accepted, fail-closed, C6-legal, and it
        //       only happens on a server that is nonconforming (RFC 3501 §6.3.1
        //       lists UIDVALIDITY among SELECT's REQUIRED OK untagged responses,
        //       and says a server omitting it does not support unique
        //       identifiers), i.e. one this app cannot serve at all;
        //   (2) one conformant SELECT clears it — so the refusal is a property of
        //       the server's behaviour, never a durable local latch.
        _ = await engine.runBackfill(account: account)
        let afterSecond = try Self.headers(pool, folderId: "\(accountId):Receipts")
        #expect(afterSecond.count == 1 && !afterSecond.contains { $0.rfc822MessageId == serverRfc },
                """
                a SECOND pass under the same suppressed SELECT inserted rows the first pass \
                refused — the refusal is not a property of what the pass could observe. \
                Rows: \(afterSecond.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)

        server.restoreSelectUidValidity(for: "Receipts")
        server.setUidValidity(storedEpoch, for: "Receipts")
        _ = await engine.runBackfill(account: account)
        let afterRestore = try Self.headers(pool, folderId: "\(accountId):Receipts")
        #expect(afterRestore.contains { $0.rfc822MessageId == serverRfc },
                """
                the folder is STILL refused after the server started reporting its epoch again — \
                the refusal has become a durable local latch rather than a statement about what \
                this pass could observe, and no later pass can ever crawl this folder. \
                Rows: \(afterRestore.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)
    }

    /// The negative case for the refusal above: the account the round-8 comment
    /// protected is one whose server never reports UIDVALIDITY at all, so its
    /// folders have a NIL stored epoch — and those must still be crawled, or the
    /// fix trades one brick for a bigger one.
    @Test("A server that never reports UIDVALIDITY is still crawled")
    @MainActor
    func anEpochlessServerIsStillCrawled() async throws {
        let serverRfc = "epochless-server@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: [
                "INBOX": [],
                "Receipts": [Self.message(uid: 4, id: serverRfc, subject: "epochless")],
            ])
        server.suppressSelectUidValidity(for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-epochless"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(accountId: accountId, path: "Receipts", pool: pool, cursor: nil)

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        _ = await engine.runBackfill(account: account)

        let rows = try Self.headers(pool, folderId: "\(accountId):Receipts")
        #expect(rows.contains { $0.rfc822MessageId == serverRfc },
                """
                the crawl refused an account whose server reports no UIDVALIDITY at all — the \
                refusal must key off "the folder HAS a stored epoch this pass could not confirm", \
                never off "no epoch was observed"
                """)
        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(after?.lastKnownUidValidity == nil,
                "nothing can be stamped from an epochless server — IOS-EPOCH-001 still applies")
    }

    // MARK: - Round 10, blocker 4 — a transient bootstrap write failure

    /// 🚨 A transient failure of the crawl's epoch-bootstrap WRITE must not
    /// durably prevent the folder from ever being stamped.
    ///
    /// Round 8 caught the throw, set a flag, and CONTINUED the walk — inserting
    /// headers — then withheld `backfillComplete` "so this pass is retried". The
    /// retry could not work, because the pass it had already run made its own
    /// precondition false: with headers now present,
    /// `bootstrapCrawledFolderUidValidity` returns FALSE rather than throwing, a
    /// `false` was read as success, and the folder was marked complete with a NIL
    /// stamp. Completion excludes it from every later crawl and Smart Reindex
    /// keeps the headers, so the count gate refuses forever after.
    ///
    /// THE INVARIANT: **a folder whose epoch bootstrap failed once is stamped by a
    /// later pass.** It is asserted on the durable stamp and on the mail being
    /// actionable, not on which flag the failing pass set — a mechanism-pinning
    /// assertion ("`epochBootstrapWriteFailed` was true") stays green on exactly
    /// the broken system this test exists to reject.
    @Test("A transient epoch-bootstrap write failure never leaves the folder unstampable")
    @MainActor
    func aTransientBootstrapWriteFailureIsRecoveredByTheNextPass() async throws {
        let liveEpoch = 913_601
        let crawledRfc = "bootstrap-retry@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: [
                "INBOX": [],
                "Receipts": [Self.message(uid: 6, id: crawledRfc, subject: "retryable")],
            ])
        server.setUidValidity(liveEpoch, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-bootstrap-retry"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        // A RESUMED cursor with a nil stamp: legitimate — an earlier pass planted
        // the cursor while the server reported UIDVALIDITY 0, so nothing was
        // stamped. The folder holds no headers yet, so the bootstrap CAN succeed.
        try Self.insertBackfillOnlyFolder(
            accountId: accountId, path: "Receipts", pool: pool, cursor: 20, epoch: nil)

        let folderId = "\(accountId):Receipts"
        SyncEngine.epochBootstrapWriteFailureIdsForTesting.withLock { _ = $0.insert(folderId) }
        defer { SyncEngine.epochBootstrapWriteFailureIdsForTesting.withLock { _ = $0.remove(folderId) } }

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)

        // Pass 1 — the bootstrap write throws once.
        _ = await engine.runBackfill(account: account)
        // Pass 2 — the seam is consumed; an ordinary pass.
        _ = await engine.runBackfill(account: account)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(after?.lastKnownUidValidity == liveEpoch,
                """
                the folder is stamped \(String(describing: after?.lastKnownUidValidity)) after a \
                transient bootstrap write failure — a ONE-OFF write error left it durably \
                unstampable, so every gesture on its mail is a silent no-op with no way back
                """)

        let rows = try Self.headers(pool, folderId: folderId)
        #expect(rows.contains { $0.rfc822MessageId == crawledRfc },
                "the recovered pass must also have crawled the folder's mail")
    }

    // MARK: - Round 12 — every bookkeeping write, driven END TO END

    /// ⚠ **NB4(a): the test this replaces could not have caught round 12's
    /// blocker A, and that is why it is gone.**
    /// `crawlWalkWriteAllowedReReadsInsideTheTransaction` called the helper
    /// DIRECTLY inside a `pool.read`. It pinned the helper's return value, which
    /// stays correct for any number of UNGUARDED call sites — and there were two,
    /// both in `runBackfill`'s `case .fresh` arm, in the very commit that claimed
    /// *"`crawlWalkWriteAllowed` re-reads the folder row inside every bookkeeping
    /// transaction"*. That is the mechanism-not-invariant shape the same commit
    /// said it was hunting, reproduced in the test written to close that round.
    /// Every test below drives `SyncEngine.runBackfill` end to end and asserts a
    /// DURABLE END STATE, so an unguarded call site cannot hide behind a correct
    /// helper.
    ///
    /// THE INVARIANT HERE: **a pass whose premise about the folder's epoch has
    /// been overtaken never declares the folder fully crawled** — because
    /// completion is the one bookkeeping value no later crawl cycle can undo
    /// (`runBackfill` selects on `backfillComplete == false`), so a wrong `true`
    /// permanently removes that folder's mail from automatic backfill. Asserted
    /// on the mail arriving, not on which branch ran.
    ///
    /// ⚑ R0: `v2final` guards its counterpart write with
    /// `uidValidityWalkWriteAllowed` and logs *"skipping fully-crawled write —
    /// UIDVALIDITY quarantine"*. This is a port gap being closed, not a new idea.
    @Test("A pass whose epoch premise was overtaken never declares the folder fully crawled")
    @MainActor
    func aStalePassNeverDeclaresAReStampedFolderFullyCrawled() async throws {
        let staleEpoch = 913_801   // what this pass's walk-start SELECT observes
        let liveEpoch = 913_802    // what a sibling stamps while it is on the network
        let laterRfc = "post-restamp@example.com"

        // EMPTY mailbox ⇒ UIDNEXT 1 ⇒ `initialCursor < 1` ⇒ the completion write.
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [], "Receipts": []])
        server.setUidValidity(staleEpoch, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-stale-completion"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(accountId: accountId, path: "Receipts", pool: pool, cursor: nil)
        let folderId = "\(accountId):Receipts"

        // The sibling pass, landing in the window between this pass's walk-start
        // SELECT and its bookkeeping write: it stamps the epoch the mailbox has
        // actually moved to, and the mailbox gains mail under it.
        SyncEngine.backfillWalkCheckpointHooksForTesting.withLock {
            $0[.beforeFreshBookkeepingWrite(folderId: folderId)] = {
                try? await pool.write { db in
                    _ = try Folder.filter(Column("id") == folderId)
                        .updateAll(db, Column("lastKnownUidValidity").set(to: liveEpoch))
                }
                server.setUidValidity(liveEpoch, for: "Receipts")
                server.setMessages(
                    [Self.message(uid: 11, id: laterRfc, subject: "arrived under the live epoch")],
                    in: "Receipts")
            }
        }
        defer { SyncEngine.backfillWalkCheckpointHooksForTesting.withLock { $0.removeAll() } }

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)

        _ = await engine.runBackfill(account: account)   // the overtaken pass
        _ = await engine.runBackfill(account: account)   // the pass that must still crawl

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(after?.lastKnownUidValidity == liveEpoch,
                "precondition: the sibling's stamp is what the folder holds")

        let rows = try Self.headers(pool, folderId: folderId)
        #expect(rows.contains { $0.rfc822MessageId == laterRfc },
                """
                a pass that observed UIDVALIDITY \(staleEpoch) wrote `backfillComplete = true` after \
                the folder had already moved to \(liveEpoch) — every later crawl cycle selects on \
                `backfillComplete == false`, so this folder's mail is permanently outside automatic \
                backfill and reachable only if the user opens the folder. \
                Rows: \(rows.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)
    }

    /// THE INVARIANT: **every header row in a folder, and the folder's stamp,
    /// come from ONE epoch** — the property `aTurnoverMidWalkNeverMixesEpochsIntoTheFolder`
    /// pins for a turnover the walk SEES, asserted here for one it cannot: the
    /// stamp moving under the walk from another writer.
    ///
    /// The walk-start gate reads the folder row BEFORE its SELECT round trip, so
    /// a folder that was unstamped at gate time can be stamped by the time the
    /// initial-cursor transaction runs. Unguarded, that transaction plants a
    /// cursor and `lastKnownUidNext` in the epoch THIS pass observed onto a
    /// folder now stamped with a DIFFERENT one; the walk then runs with
    /// `expectedEpoch` set to its own observation and the per-chunk check
    /// compares the provider MIRROR against that — never against the stored
    /// stamp — so it agrees, and rows of one numbering land under a stamp
    /// describing another. `AccountManager.newGestureRefusedForUnknownEpoch`
    /// tests only `== nil`, so a non-nil wrong stamp ADMITS every bare-UID
    /// gesture on them (C3).
    ///
    /// ⚑ R0: `v2final` guards its counterpart with `uidValidityWalkWriteAllowed`
    /// (log: *"skipping initial cursor write — UIDVALIDITY quarantine"*) AND
    /// re-checks the STORED epoch inside `insertBackfillBatch`'s own transaction.
    /// v3 has neither; the walk-start guard is the port of the first.
    @Test("A folder stamped mid-pass never gains rows fetched under a different epoch")
    @MainActor
    func aFolderStampedMidPassNeverGainsRowsFromADifferentEpoch() async throws {
        let siblingEpoch = 913_901   // what a sibling stamps mid-pass
        let liveEpoch = 913_902      // what this pass's SELECT observed
        let decoyRfc = "live-epoch-decoy@example.com"

        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: [
                "INBOX": [],
                "Receipts": [Self.message(uid: 42, id: decoyRfc, subject: "decoy")],
            ])
        server.setUidValidity(liveEpoch, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-plant-restamp"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(accountId: accountId, path: "Receipts", pool: pool, cursor: nil)
        let folderId = "\(accountId):Receipts"
        // A leftover row of the sibling's epoch, bare UID and no RFC Message-ID.
        // It is what makes the sibling's stamp CORRECT and this pass's
        // observation wrong for these rows — and it keeps
        // `bootstrapCrawledFolderUidValidity` from stamping anything itself.
        try Self.insertHeader(
            accountId: accountId, path: "Receipts", uid: "7", pool: pool, rfc822MessageId: nil)

        SyncEngine.backfillWalkCheckpointHooksForTesting.withLock {
            $0[.beforeFreshBookkeepingWrite(folderId: folderId)] = {
                try? await pool.write { db in
                    _ = try Folder.filter(Column("id") == folderId)
                        .updateAll(db, Column("lastKnownUidValidity").set(to: siblingEpoch))
                }
            }
        }
        defer { SyncEngine.backfillWalkCheckpointHooksForTesting.withLock { $0.removeAll() } }

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        _ = await engine.runBackfill(account: account)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(after?.lastKnownUidValidity == siblingEpoch,
                "precondition: the folder holds the sibling's stamp, not this pass's observation")

        let rows = try Self.headers(pool, folderId: folderId)
        #expect(!rows.contains { $0.rfc822MessageId == decoyRfc },
                """
                a row fetched under UIDVALIDITY \(liveEpoch) was inserted into a folder stamped \
                \(siblingEpoch) — the folder now holds UIDs from two numberings under one stamp, \
                and because that stamp is non-nil every bare-UID gesture on all of them is \
                ADMITTED. Rows: \(rows.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)
        // The same write plants the cursor. A cursor is a position in a UID
        // SPACE, so one taken from \(liveEpoch) written onto a folder whose rows
        // belong to \(siblingEpoch) is a silent completeness gap for whichever
        // epoch eventually wins — the failure `v2final`'s §5.5 comment names.
        #expect(after?.backfillUidCursor == nil,
                """
                the pass planted a cursor derived from UIDNEXT in epoch \(liveEpoch) onto a folder \
                stamped \(siblingEpoch): cursor = \(String(describing: after?.backfillUidCursor))
                """)
    }

    /// The same invariant, one window later — and the one the walk-start guard
    /// alone CANNOT close.
    ///
    /// The walk's own per-chunk check (`epochStillAgrees()`) compares the
    /// provider's epoch MIRROR against the epoch the WALK started in. No term in
    /// it reads the folder row, so it is structurally blind to the folder's STAMP
    /// moving after the walk began — which is reachable whenever the crawl cannot
    /// stamp the folder itself (it holds rows of unproven epoch, so
    /// `bootstrapCrawledFolderUidValidity` refuses) and a sibling pass stamps it:
    /// full sync's STATUS-sourced folder-list upsert, `runSyncMessages`'
    /// SELECT-sourced bootstrap, or deletion-reconcile's. The rows then land under
    /// a stamp describing a different numbering, and the stamp being non-nil keeps
    /// every bare-UID gesture on them ADMITTED (C3).
    ///
    /// ⚑ R0: `v2final` closes this INSIDE `insertBackfillBatch`, comparing its
    /// caller's observation against the STORED epoch in the insert's own
    /// transaction and returning `refused` so the range is failed, never
    /// confirmed. v3 had no in-transaction insert guard at all — a port gap. The
    /// guard is now the CAS against the pass's premise, which is the same
    /// comparison in v3's terms.
    @Test("A stamp that moves mid-walk stops the insert, not just the bookkeeping")
    @MainActor
    func aStampMovingMidWalkRefusesTheInsertItself() async throws {
        let siblingEpoch = 914_201   // stamped by a sibling AFTER the walk started
        let liveEpoch = 914_202      // what every SELECT of this walk reports
        let decoyRfc = "insert-guard-decoy@example.com"

        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: [
                "INBOX": [],
                "Receipts": [Self.message(uid: 42, id: decoyRfc, subject: "decoy")],
            ])
        server.setUidValidity(liveEpoch, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-insert-guard"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(accountId: accountId, path: "Receipts", pool: pool, cursor: nil)
        let folderId = "\(accountId):Receipts"
        // A pre-existing row keeps `bootstrapCrawledFolderUidValidity` from
        // stamping, so the pass's premise stays "unstamped" for its whole
        // duration — the state a bare `UInt32?` premise would silently un-guard.
        try Self.insertHeader(
            accountId: accountId, path: "Receipts", uid: "7", pool: pool, rfc822MessageId: nil)

        // The sibling lands AFTER the walk-start bookkeeping has already been
        // authorised and the chunk has already been fetched — the window the
        // walk-start guard cannot reach.
        SyncEngine.backfillWalkCheckpointHooksForTesting.withLock {
            $0[.beforeInsertingFetchedChunk(folderId: folderId)] = {
                try? await pool.write { db in
                    _ = try Folder.filter(Column("id") == folderId)
                        .updateAll(db, Column("lastKnownUidValidity").set(to: siblingEpoch))
                }
            }
        }
        defer { SyncEngine.backfillWalkCheckpointHooksForTesting.withLock { $0.removeAll() } }

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        _ = await engine.runBackfill(account: account)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(after?.lastKnownUidValidity == siblingEpoch,
                "precondition: the sibling's stamp is what the folder holds by insert time")

        let rows = try Self.headers(pool, folderId: folderId)
        #expect(!rows.contains { $0.rfc822MessageId == decoyRfc },
                """
                a chunk fetched under UIDVALIDITY \(liveEpoch) was inserted after the folder had \
                been stamped \(siblingEpoch) — the walk's per-chunk check reads only the provider \
                mirror, so nothing in it can see the stamp move, and these rows' bare UIDs now sit \
                under a stamp that admits every gesture on them. \
                Rows: \(rows.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)
        #expect(after?.backfillComplete == false,
                "a pass whose insert was refused must not claim the folder is fully crawled")
    }

    /// 🚨 **BLOCKER B — TWO OVERLAPPING `runBackfill` CALLS.** No test overlapped
    /// two of them before round 12, which is how a TOCTOU across the reset
    /// survived: `resetEmptyFolderCrawlEpoch` checked only `headerCount == 0` and
    /// then updated BY FOLDER ID, acting on a mismatch decided BEFORE a network
    /// round trip.
    ///
    /// The overlap is real, not hypothetical. `runBackfill` is reached from the
    /// persistent worker `SyncEngine.startBackfill` launches (in
    /// `SyncEngineBackfill.swift`, itself started from `SyncEngine.sync`) and,
    /// independently, from `SyncScheduler`'s BGProcessing pass through
    /// `AccountManager.runBackfill` → `SyncEngine.performBackfill`. `SyncEngine`
    /// is an actor, so the two interleave at every suspension point.
    ///
    /// THE INVARIANT: **a folder that holds rows is never left unstamped** (and,
    /// worse, never left unstamped AND complete). That end state is durable and
    /// unrecoverable by the crawl: completion excludes the folder from every
    /// later cycle, and Smart Reindex (`SyncEngine.resetCrawlState`) reopens the
    /// crawl but cannot re-stamp, because `bootstrapCrawledFolderUidValidity`'s
    /// header-count gate now refuses. It is asserted on the stamp AND on the mail
    /// being actionable through the wire oracle — never on which branch declined.
    ///
    /// The interleaving is driven by two one-shot checkpoints and a signal gate,
    /// so it is deterministic: walk A parks having decided its reset from the
    /// pre-turnover snapshot; walk B then resets, re-stamps the live epoch, plants
    /// a cursor and FETCHES a batch — which sits outside SQLite, invisible to the
    /// header count — and parks; A's stale reset is released only then.
    ///
    /// ⚠ **THIS INVARIANT IS CLOSED BY TWO GUARDS JOINTLY, and the red proof was
    /// run against the state in which BOTH are absent — which is the parent
    /// commit's state, and the only state in which the claim above is true.**
    /// Inverting `resetEmptyFolderCrawlEpoch`'s CAS ALONE does not reproduce the
    /// durable end state: `insertBackfillBatch`'s in-transaction guard then
    /// refuses walk B's already-fetched chunk (B premised `liveEpoch`, A's reset
    /// left `nil`), so the folder ends EMPTY, unstamped and incomplete — wasted
    /// round trips and a rewound cursor, recovered by the next cycle. That is a
    /// TRANSIENT failure, and saying otherwise would be the overstatement this
    /// round exists to stop. What the CAS alone owns is that transient half; what
    /// the pair owns is the durable half asserted below. Removing EITHER
    /// regresses this test, which is what makes it a test of the property rather
    /// than of one mechanism.
    @Test("Two overlapping crawls never leave a populated folder unstamped")
    @MainActor
    func twoOverlappingCrawlsNeverLeaveAPopulatedFolderUnstamped() async throws {
        let staleEpoch = 914_101   // what both walks' snapshots read from the row
        let liveEpoch = 914_102    // what the server is actually on
        let crawledRfc = "overlap-crawled@example.com"

        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: [
                "INBOX": [],
                "Receipts": [Self.message(uid: 9, id: crawledRfc, subject: "live epoch mail")],
            ])
        server.setUidValidity(liveEpoch, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-overlapping-walks"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        // EMPTY, incomplete, stamped with the pre-turnover epoch, cursor-bearing:
        // exactly the state `resetEmptyFolderCrawlEpoch` exists to discharge.
        try Self.insertBackfillOnlyFolder(
            accountId: accountId, path: "Receipts", pool: pool, cursor: 60, epoch: staleEpoch)
        let folderId = "\(accountId):Receipts"

        let gate = BackfillWalkHandshake()
        SyncEngine.backfillWalkCheckpointHooksForTesting.withLock {
            $0[.beforeEmptyFolderCrawlEpochReset(folderId: folderId)] = {
                gate.signal("A-parked")
                await gate.wait("A-may-reset")
            }
            $0[.beforeInsertingFetchedChunk(folderId: folderId)] = {
                gate.signal("B-fetched")
                await gate.wait("A-done")
            }
        }
        defer { SyncEngine.backfillWalkCheckpointHooksForTesting.withLock { $0.removeAll() } }

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)

        // Walk A carries a deadline so that, once its stale reset has run, it
        // STOPS rather than crawling on and re-deriving the folder itself — which
        // would mask the very state under test. The deadline is checked at the top
        // of the folder loop, i.e. immediately after the reset's `continue`. It is
        // deterministic, not a race: A cannot advance at all while parked, and the
        // release below happens strictly after the deadline has passed.
        let walkADeadline = Date(timeIntervalSinceNow: 0.2)
        let walkA = Task { _ = await engine.runBackfill(account: account, deadline: walkADeadline) }
        await gate.wait("A-parked")
        let walkB = Task { _ = await engine.runBackfill(account: account) }
        await gate.wait("B-fetched")
        while Date() < walkADeadline { try await Task.sleep(for: .milliseconds(20)) }
        gate.signal("A-may-reset")
        _ = await walkA.value
        gate.signal("A-done")
        _ = await walkB.value

        let rows = try Self.headers(pool, folderId: folderId)
        #expect(rows.contains { $0.rfc822MessageId == crawledRfc },
                """
                precondition: the overlapping pair must have crawled the folder's mail. \
                Rows: \(rows.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(after?.lastKnownUidValidity != nil,
                """
                a folder holding \(rows.count) row(s) was left with NO epoch stamp — a stale reset \
                decision cleared the stamp a sibling walk had just re-derived, and the sibling's \
                already-fetched batch then landed under the nil. Every gesture on that mail is now \
                a silent no-op, and the crawl can never re-stamp it: \
                `bootstrapCrawledFolderUidValidity`'s header-count gate refuses a populated folder, \
                so not even Smart Reindex recovers it. complete=\(String(describing: after?.backfillComplete))
                """)

        // …and the mail is actionable, on the right message. A nil stamp makes
        // `newGestureRefusedForUnknownEpoch` refuse, so this is the user-visible
        // half of the same invariant, checked against the wire oracle.
        guard let crawled = rows.first(where: { $0.rfc822MessageId == crawledRfc }) else { return }
        await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: imap
        ) {
            server.expectMutation(rfc822MessageId: crawledRfc)
            await AccountManager.shared.markRead([crawled])
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(try Self.headers(pool, folderId: folderId)
                    .first(where: { $0.rfc822MessageId == crawledRfc })?.isRead == true,
                "a gesture on the overlapping pair's crawled mail is refused — the folder is unusable")
        #expect(server.wrongMessageViolations().isEmpty,
                "the gesture mutated a message it never targeted: \(server.wrongMessageViolations())")
    }

    /// 🚨 **BLOCKER C — the fourth instance of the spin family, sitting between
    /// two that `9e0c4797e` fixed.** The `case .fresh` initial-cursor transaction
    /// was a bare `try await` with no `do`/`catch` and no decline. A throw reached
    /// the folder loop's outer `catch`, which for a non-connection, non-auth error
    /// only logs; the folder was still incomplete, still cursor-less and never
    /// added to the decline set, so the loop's fresh re-read handed back the SAME
    /// folder, issued another walk-start SELECT and retried the identical failing
    /// write — with `previousFolderId` already equal to it, so `interFolderDelay`
    /// was skipped too.
    ///
    /// THE INVARIANT: **a pass that cannot persist its bookkeeping stops asking
    /// the server.** Asserted on the wire — how many walk-start SELECTs of this
    /// folder one `runBackfill` call issues — not on the decline set, which is the
    /// mechanism and which "looks right" on a spinning system.
    ///
    /// The seam is PERSISTENT on purpose (`freshCursorWriteFailureIdsForTesting`
    /// does not consume its ids): the models are GRDB suspension (ADR-IOS-046 /
    /// `0xdead10cc`), `SQLITE_FULL` and corruption, all of which fail every
    /// attempt. A deadline is passed because on the pre-fix code this call has no
    /// other exit.
    ///
    /// ⚑ R0 — DIVERGENCE FROM THE REFERENCE, DELIBERATE. `v2final`'s counterpart
    /// write is ALSO a bare `try await` with no decline, so this is not a port
    /// regression; the reference shares the shape and it is fixed anyway.
    @Test("A persistent bookkeeping write failure never re-walks the folder at network rate")
    @MainActor
    func aPersistentFreshCursorWriteFailureNeverSpinsTheCrawl() async throws {
        let liveEpoch = 914_001
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: [
                "INBOX": [],
                "Receipts": [Self.message(uid: 5, id: "spin@example.com", subject: "unreachable")],
            ])
        server.setUidValidity(liveEpoch, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-persistent-write-failure"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(accountId: accountId, path: "Receipts", pool: pool, cursor: nil)
        let folderId = "\(accountId):Receipts"

        SyncEngine.freshCursorWriteFailureIdsForTesting.withLock { _ = $0.insert(folderId) }
        defer { SyncEngine.freshCursorWriteFailureIdsForTesting.withLock { _ = $0.remove(folderId) } }

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)

        _ = await engine.runBackfill(account: account, deadline: Date(timeIntervalSinceNow: 1.5))

        let selects = server.recordedCommands().filter {
            $0.hasPrefix("SELECT") && $0.contains("Receipts")
        }
        #expect(selects.count <= 4,
                """
                one `runBackfill` call issued \(selects.count) SELECTs of this folder while its \
                bookkeeping write failed every time — the folder is handed straight back by the \
                loop's fresh re-read with no decline and no inter-folder delay, so a persistent \
                write failure (GRDB suspension, SQLITE_FULL, corruption) becomes an unbounded \
                network-rate loop for the whole call
                """)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(after?.backfillComplete == false && after?.backfillUidCursor == nil,
                "a pass whose bookkeeping write failed must leave the folder exactly as it found it")
    }

    // MARK: - Absence of a UIDNEXT is not a report of an empty mailbox

    /// 🚨 `MIS-IOS-004`, the most repeated defect in this codebase: "could not
    /// determine" treated as an authoritative answer.
    ///
    /// `Mailbox.Selection.uidNext` is non-optional with a `UID(0)` default and
    /// `SelectHandler` assigns it only when the wire carried `* OK [UIDNEXT n]`,
    /// so a SELECT that never mentioned UIDNEXT reached the crawl as the number
    /// **0**. The `.fresh` branch computed `initialCursor = uidNext - 1 == -1`,
    /// took the `initialCursor < 1` early-out — which exists for UIDNEXT **1**,
    /// the one value that PROVES the mailbox never held a message (RFC 3501
    /// §2.3.1.1: UIDs are assigned strictly increasing from 1) — and wrote
    /// `backfillComplete = true`. Completion removes the folder from
    /// `remaining` on every later pass, so nothing ever revisited it.
    ///
    /// THE INVARIANT, asserted as a system property rather than on which flag
    /// the refusing pass set: **a folder whose UIDNEXT the server never
    /// reported is never marked fully crawled, and its mail still arrives once
    /// a SELECT does report one.** The second half is what makes the refusal a
    /// deferral rather than a new dead end, and it is asserted on the MAIL, so
    /// a "fix" that merely withholds the flag while still never crawling the
    /// folder stays red.
    @Test("A folder whose UIDNEXT the server never reported is never marked fully crawled")
    @MainActor
    func aFolderWithNoReportedUidNextIsNeverMarkedFullyCrawled() async throws {
        let crawledRfc = "no-uidnext@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: [
                "INBOX": [],
                "Receipts": [Self.message(uid: 9, id: crawledRfc, subject: "reachable")],
            ])
        server.suppressSelectUidNext(for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-no-uidnext"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(accountId: accountId, path: "Receipts", pool: pool, cursor: nil)

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        _ = await engine.runBackfill(account: account)

        let afterRefusal = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(afterRefusal?.backfillComplete == false,
                """
                a SELECT that reported no UIDNEXT marked the folder fully crawled — absence of \
                evidence took the branch written for UIDNEXT 1, which is EVIDENCE of an empty \
                mailbox; completion then excluded the folder from every later crawl
                """)
        #expect(afterRefusal?.backfillUidCursor == nil,
                "a cursor was planted from a UIDNEXT the server never reported")

        // THE RECOVERY, asserted on the mail: one conformant SELECT and the
        // folder crawls normally. Pre-fix this is unreachable — the folder was
        // already `backfillComplete`, so `remaining` never hands it back.
        server.restoreSelectUidNext(for: "Receipts")
        _ = await engine.runBackfill(account: account)

        let rows = try Self.headers(pool, folderId: "\(accountId):Receipts")
        #expect(rows.contains { $0.rfc822MessageId == crawledRfc },
                """
                the folder never recovered once the server reported a UIDNEXT — the refusal has \
                to be a deferral, not a second permanent dead end
                """)
        let afterRecovery = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(afterRecovery?.backfillComplete == true,
                "the recovered crawl never settled — the folder would be re-walked forever")
    }

    /// The negative case, and the two-sided non-vacuity anchor for the test
    /// above: it must stay GREEN with that fix inverted. A genuinely empty
    /// mailbox reports `UIDNEXT 1` — positive evidence — and MUST still settle,
    /// or the refusal has simply been widened into the mirror-image defect
    /// (`MIS-005`): an unbounded re-crawl of every empty folder, forever.
    @Test("A genuinely empty mailbox (UIDNEXT 1) still settles as fully crawled, and stays settled")
    @MainActor
    func aGenuinelyEmptyMailboxStillSettles() async throws {
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [], "Receipts": []])
        server.setUidValidity(770_101, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-empty-settles"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(accountId: accountId, path: "Receipts", pool: pool, cursor: nil)

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        _ = await engine.runBackfill(account: account)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(after?.backfillComplete == true,
                "an empty mailbox reporting UIDNEXT 1 must settle — it is proven empty, not unknown")
        #expect(after?.lastKnownUidNext == 1)
        // NB3's requirement survives: the completion write stamps the epoch in
        // the same transaction, so an empty folder is still gestureable.
        #expect(after?.lastKnownUidValidity == 770_101,
                "the empty-mailbox completion stopped stamping the epoch (NB3)")

        // Still settled on a second pass — it is excluded from `remaining`, so
        // nothing re-walks it.
        _ = await engine.runBackfill(account: account)
        let again = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(again?.backfillComplete == true, "a settled empty folder was re-opened by a later pass")
    }

    // MARK: - Round 15 — the reset window the epoch CAS cannot see

    /// THE INVARIANT: **mail that arrives under a folder's NEW numbering space is
    /// still reached by automatic backfill after the reset that created it.**
    ///
    /// The CAS in `crawlWalkWriteAllowed` cannot enforce that on its own, and the
    /// reason is structural rather than a race the CAS merely loses. The reset
    /// reaction (`AccountManagerUidValidityReset`) arms `uidValidityResetPendingAt`,
    /// purges the folder's headers and clears its crawl state, and DELIBERATELY
    /// leaves `lastKnownUidValidity` at the OLD value until the very last step. So
    /// for the whole reset window an old-epoch walk's premise still equals the
    /// stored stamp: the CAS AGREES, and the walk is free to write
    /// `backfillComplete = true` onto a folder that was just emptied.
    ///
    /// That end state is not recoverable by the crawl. `runBackfill` selects on
    /// `backfillComplete == false`, and `resetEmptyFolderCrawlEpoch` — the one
    /// clearer that could reopen it — requires ZERO local headers, which stops
    /// being true the moment the post-reset sync inserts its first row. So the
    /// folder's remaining mail is permanently outside automatic backfill.
    ///
    /// Asserted on the MAIL arriving after the reset completes, not on which branch
    /// declined: `backfillComplete` is only the mechanism by which the mail is lost.
    @Test("Mail under a folder's new numbering space is still crawled after a reset that overlapped a walk")
    @MainActor
    func aCrawlWriteIsRefusedWhileAUidValidityResetIsPending() async throws {
        let oldEpoch = 951_001   // what the folder is stamped with, and what the walk premises
        let newEpoch = 951_002   // what the reset will stamp once it finishes
        let postResetRfc = "arrived-after-the-reset@example.com"

        // EMPTY mailbox ⇒ UIDNEXT 1 ⇒ `initialCursor < 1` ⇒ the completion write.
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [], "Receipts": []])
        server.setUidValidity(oldEpoch, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t15-reset-window"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(
            accountId: accountId, path: "Receipts", pool: pool, cursor: nil, epoch: oldEpoch)
        let folderId = "\(accountId):Receipts"

        // The reset reaction, landing in the window between this pass's walk-start
        // SELECT and its bookkeeping write. It arms the durable flag and clears the
        // crawl state — and leaves `lastKnownUidValidity` alone, exactly as
        // `uidValidityResetArmFlag` + the purge do, so the CAS below still agrees.
        SyncEngine.backfillWalkCheckpointHooksForTesting.withLock {
            $0[.beforeFreshBookkeepingWrite(folderId: folderId)] = {
                try? await pool.write { db in
                    _ = try Folder.filter(Column("id") == folderId)
                        .updateAll(db,
                            Column("uidValidityResetPendingAt").set(to: Date()),
                            Column("backfillComplete").set(to: false),
                            Column("backfillUidCursor").set(to: nil as Int?))
                }
            }
        }
        defer { SyncEngine.backfillWalkCheckpointHooksForTesting.withLock { $0.removeAll() } }

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)

        _ = await engine.runBackfill(account: account)   // the pass the reset overtook

        let mid = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(mid?.uidValidityResetPendingAt != nil,
                "precondition: the reset is still in flight when the overtaken pass tries to write")

        // The reset finishes: fresh epoch stamped, flag cleared
        // (`uidValidityResetStampFreshEpoch`), and the mailbox now holds mail under
        // the new numbering space.
        try await pool.write { db in
            _ = try Folder.filter(Column("id") == folderId)
                .updateAll(db,
                    Column("lastKnownUidValidity").set(to: newEpoch),
                    Column("uidValidityResetPendingAt").set(to: nil as Date?))
        }
        server.setUidValidity(newEpoch, for: "Receipts")
        server.setMessages(
            [Self.message(uid: 4, id: postResetRfc, subject: "arrived under the new epoch")],
            in: "Receipts")

        _ = await engine.runBackfill(account: account)   // the pass that must still crawl

        let rows = try Self.headers(pool, folderId: folderId)
        #expect(rows.contains { $0.rfc822MessageId == postResetRfc },
                """
                a walk premised on UIDVALIDITY \(oldEpoch) wrote `backfillComplete = true` while the \
                folder's reset to \(newEpoch) was still in flight — the CAS agreed because the reset \
                deliberately retains the OLD stamp until it finishes. Every later crawl cycle selects \
                on `backfillComplete == false`, and `resetEmptyFolderCrawlEpoch` needs zero headers, \
                so this folder's mail is permanently outside automatic backfill. \
                Rows: \(rows.map { "\($0.messageId)=\($0.rfc822MessageId ?? "-")" })
                """)
    }

    /// THE MIRROR IMAGE of the test above, and mandatory: a guard that refused
    /// unconditionally would satisfy it while permanently disabling the crawl. The
    /// flag is re-drive state, not admission arbitration — with no reset in flight,
    /// an ordinary matching-epoch bookkeeping write must still land.
    @Test("With no reset in flight, a matching-epoch crawl write is still admitted")
    @MainActor
    func aMatchingEpochCrawlWriteIsStillAdmittedWhenNoResetIsPending() async throws {
        let epoch = 951_101

        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [], "Receipts": []])
        server.setUidValidity(epoch, for: "Receipts")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t15-no-reset"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(
            accountId: accountId, path: "Receipts", pool: pool, cursor: nil, epoch: epoch)

        let imap = Self.provider(for: server)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = await Self.makeEngine(accountId: accountId, provider: imap)
        _ = await engine.runBackfill(account: account)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Receipts", pool: pool)
        #expect(after?.backfillComplete == true,
                """
                a folder with a matching epoch and NO reset in flight was refused its completion \
                write — the quarantine term must gate only the reset window, or every empty folder \
                is re-crawled forever and the fix is strictly worse than the bug
                """)
        #expect(after?.lastKnownUidNext == 1,
                "the same admitted transaction must still record the observed UIDNEXT")
    }
}

/// Signal gate for the two-walk interleaving above. Polled with a bounded
/// ceiling rather than built on continuations so a test that mis-sequences its
/// signals FAILS instead of hanging the whole suite. `Mutex` per the project's
/// resilience rule 5 (never `nonisolated(unsafe)`).
private final class BackfillWalkHandshake: Sendable {
    private let signalled = Mutex<Set<String>>([])

    func signal(_ name: String) {
        signalled.withLock { _ = $0.insert(name) }
    }

    /// Returns as soon as `name` is signalled, or after ~10s. The waits here are
    /// sub-second in practice; the ceiling exists only so a mis-sequenced test
    /// surfaces as an assertion failure rather than a hung run.
    func wait(_ name: String) async {
        for _ in 0..<1_000 {
            if signalled.withLock({ $0.contains(name) }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
