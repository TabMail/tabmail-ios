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
        // `anEmptyFolderIsNeverPermanentlyRefusedAfterATurnover`). The folder here
        // therefore HOLDS a row from the stored epoch — the state the mechanism
        // actually exists to protect.
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
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: imap)
        defer { Task { await AccountManager.shared.unregisterProviderForTesting(accountId: accountId) } }
        guard let crawled = recovered.first else { return }
        server.expectMutation(rfc822MessageId: replacementRfc)
        await AccountManager.shared.markRead([crawled])
        await AccountManager.shared.drainPendingQueue()

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
        // The SELECT omits `* OK [UIDVALIDITY n]` entirely — RFC 3501 §6.3.1
        // makes it a SHOULD — so every observation this pass can make is nil.
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

    // MARK: - Round 10, NB4 — the walk's writes are judged at write time

    /// The walk reads the folder row ONCE per iteration, BEFORE its walk-start
    /// network round trip, and every bookkeeping write it makes lands after that —
    /// some from a parallel worker minutes later. NB4: judging those writes on the
    /// pre-network snapshot is fail-OPEN, because the one reachable skew is
    /// "snapshot said nil, the row is stamped by now" and a nil stored epoch
    /// ADMITS. `crawlWalkWriteAllowed` re-reads inside the write's own transaction.
    @Test("A walk bookkeeping write is judged against the folder row at WRITE time")
    func crawlWalkWriteAllowedReReadsInsideTheTransaction() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t13-inTxnGuard"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.insertBackfillOnlyFolder(
            accountId: accountId, path: "Receipts", pool: pool, cursor: 10, epoch: nil)
        let folderId = "\(accountId):Receipts"

        // The pre-network snapshot every caller took: nil.
        let snapshotEpoch = try #require(try await pool.read { db in
            try Folder.fetchOne(db, key: folderId)
        }).lastKnownUidValidity
        #expect(snapshotEpoch == nil)

        // Another writer stamps the folder while the walk is out on the network.
        try await pool.write { db in
            try SyncEngine.bootstrapFolderUidValidity(db, folderId: folderId, observed: 913_701)
        }

        // A write from a pass walking under a DIFFERENT epoch must now be refused,
        // even though the snapshot it gated on said "unstamped, anything goes".
        let allowedForOtherEpoch = try await pool.read { db in
            try SyncEngine.crawlWalkWriteAllowed(db, folderId: folderId, walkEpoch: 913_702)
        }
        #expect(!allowedForOtherEpoch,
                """
                the walk's bookkeeping write was authorised against a stale pre-network snapshot: \
                the folder has since been stamped 913701 and this pass is walking 913702, so its \
                cursor/completeness describe a UID space the folder's rows do not belong to
                """)

        // …and the ordinary case still passes, or the guard would stall every crawl.
        let allowedForSameEpoch = try await pool.read { db in
            try SyncEngine.crawlWalkWriteAllowed(db, folderId: folderId, walkEpoch: 913_701)
        }
        #expect(allowedForSameEpoch, "a pass walking the folder's own epoch must still write")
    }
}
