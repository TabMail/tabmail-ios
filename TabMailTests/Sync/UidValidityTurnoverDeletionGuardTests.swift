/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// **THE INVARIANT: a UIDVALIDITY turnover deletes no local mail.**
///
/// Every assertion here is on the SYSTEM PROPERTY — pre-turnover messages still
/// exist — never on the mechanism that delivers it ("the column was not
/// written"). A mechanism test inherits the spec's error; this one cannot.
///
/// ## Why the existing reconcile tests could not see this
///
/// Every case in `SyncEngineDeletionReconcileTests` calls
/// `SyncEngine.runDeletionReconcileWalk` as a pure function and passes
/// `storedUidValidity:` **as a parameter** (`:146, :157, :191, :206, …`). The
/// regression lived in who WRITES that value, so a suite that supplies it by
/// hand is structurally blind to it — which is exactly how 7,750 green tests sat
/// on top of a mass-deletion defect. These tests therefore drive the REAL
/// entry points end-to-end: a real `SyncEngine`, a real GRDB `folder` row, a real
/// `IMAPProvider` over a socket to `FakeIMAPServer`, and the production
/// `reconcileExternallyDeletedMessages` call that `performDeltaSync` / `fullSync`
/// make themselves. Nothing about the epoch is injected.
///
/// ## Red-first evidence — MEASURED, not predicted (2026-07-30)
///
/// The bootstrap-only rule was reverted in place (`uidValidityBootstrapWrite`
/// made unconditional, and the `lastKnownUidValidity IS NULL` predicate dropped
/// from both conditional UPDATEs), reproducing the uncommitted T1.2 shape where
/// every sync path keeps the column synced to the LIVE server epoch. Verbatim
/// from that run:
///
/// ```
/// [BGSyncLog] reconcileWalk: INBOX deleted=2100 failed=0 aborted=false
/// ✘ Test "A UIDVALIDITY turnover deletes no local mail (delta sync)" recorded an
///   issue at UidValidityTurnoverDeletionGuardTests.swift:223:9: Expectation
///   failed: try Self.survivingPreTurnoverCount(...) == Self.localHeaderCount
///   ↳ a UIDVALIDITY turnover must delete NO local mail: every local UID belongs
///     to the old numbering …
/// ✘ Test "… (delta sync)" failed after 1.544 seconds with 1 issue.
///
/// [BGSyncLog] reconcileWalk: INBOX deleted=2100 failed=0 aborted=false
/// ✘ Test "A UIDVALIDITY turnover deletes no local mail (full sync)" recorded an
///   issue at UidValidityTurnoverDeletionGuardTests.swift:260:9: Expectation
///   failed: try Self.survivingPreTurnoverCount(...) == Self.localHeaderCount
/// ✘ Test "… (full sync)" failed after 1.391 seconds with 1 issue.
///
/// ✘ Test run with 3 tests in 1 suite failed after 4.007 seconds with 3 issues
///   (including 1 known issue).
/// ```
///
/// `deleted=2100 … aborted=false` is the whole defect in one line: the walk did
/// not abort, and every pre-turnover header in the folder was destroyed — the
/// stored epoch had been overwritten to the live one, so its
/// stored-vs-live comparison was vacuously equal.
///
/// With the fix the stored epoch stays `111111`, the walk aborts on its first
/// chunk, and `survivors == 2100`.
///
/// ## Fixture shape — and why it is NOT "10 messages at the top of the window"
///
/// The turnover must be isolated from a SECOND, independent deletion path that
/// would otherwise mask it: `runSyncMessages`'s windowed stale sweep. That sweep
/// has **no UIDVALIDITY guard at all** and its complete-knowledge branch
/// (`selectStaleHeaders`, `fetched.count < limit`) deletes *every* local row not
/// in the fetch — so any fixture where the server returns fewer than
/// `SyncConfig.syncMessageLimit` messages loses all the local mail BEFORE the
/// reconcile walk runs, on the pre-fix AND post-fix tree alike, and can prove
/// nothing about the walk. (That sweep is a separate pre-existing turnover
/// hazard; see this task's report.) The fixture therefore pins the sweep out:
///
/// - the fake serves **60** messages (> `syncMessageLimit` = 50) so the fetch
///   fills its window and the complete-knowledge branch is unreachable;
/// - every server UID (5000+) is ABOVE every local UID (1000-3099), so the
///   windowed branch's UID floor excludes all pre-turnover rows;
/// - the folder holds **2100** rows (> `SyncConfig.staleDetectionMaxFullScan` =
///   2000), so even a short/partial fetch cannot reach the complete-knowledge
///   branch. Belt AND braces: a parse hiccup in the fetch cannot turn this test
///   into a false red.
///
/// What remains is exactly one deleter: the deletion-reconcile walk.
///
/// ⚠ **Read the scope of THIS fixture honestly.** Because it pins the windowed
/// sweep out, a green run here proves only that *the reconcile walk* deletes
/// nothing on a turnover. The sweep is the second, independent deleter.
///
/// 🚨 **THE SWEEP IS NOT CLOSED. It is an OPEN, pre-existing data-loss hazard.**
/// `runSyncMessages` deletes stale rows with no UIDVALIDITY guard on HEAD, and this
/// item deliberately left that path byte-equivalent to HEAD rather than widening it
/// — so the hazard is an unclosed *residual*, not a regression introduced here. It
/// is pinned executably, NOT fixed, by
/// `SyncFullSyncFolderEpochTests.turnoverFetchIsAnUnguardedDeleter`
/// (`withKnownIssue` — it will flip to a hard failure the day the guard lands),
/// with the paired control `sameEpochStillLetsTheStaleSweepDelete` proving a future
/// guard must not become a global off-switch. Two deleters, two suites; neither
/// alone certifies the invariant, and **today neither certifies the sweep at all.**
///
/// Closing it means porting `v2final`'s §5.5 universal in-txn merge guard
/// (`git show v2final:TabMail/Services/Sync/SyncEngineFullSync.swift`, ~1046-1072,
/// `uidValidityWriteAllowed`) into `runSyncMessages` — but **that guard must not
/// ship alone.** Ported by itself under bootstrap-only semantics it correctly
/// refuses the old-epoch merge while nothing ever stamps the new epoch, so the
/// folder never recovers: a deletion bug becomes a permanent-stall bug. It is the
/// *stop* half of a stop-and-recover pair whose *recover* half is the D5
/// purge-and-resync reaction (plan item T4.S6). Land them together.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared` and binds a
/// listening socket.
@Suite("UIDVALIDITY turnover deletes no local mail", .serialized, .processGlobalState)
struct UidValidityTurnoverDeletionGuardTests {

    // MARK: - Fixture

    private static let oldEpoch = 111_111
    private static let newEpoch = 222_222
    private static let localHeaderCount = 2100
    private static let firstLocalUID = 1000
    private static let serverMessageCount = 60
    private static let firstServerUID = 5000

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: turnover-fixture\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        turnover fixture body.\r

        """
    }

    /// The mailbox as it exists AFTER the turnover: a fresh numbering, high UIDs,
    /// and more messages than one fetch window holds.
    private static func postTurnoverMessages() -> [FakeIMAPServer.Message] {
        (0..<serverMessageCount).map { i in
            FakeIMAPServer.makeMessage(
                uid: firstServerUID + i,
                rfc822Text: rfc822(messageId: "post-turnover-\(firstServerUID + i)@example.com"))
        }
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

    /// Account + folder + `localHeaderCount` headers carrying the OLD epoch's UIDs.
    /// `storedEpoch` is what the folder row claims its local UIDs belong to.
    private static func seed(
        pool: DatabasePool, accountId: String, folderPath: String, role: FolderRole,
        storedEpoch: Int?, totalCount: Int, lastKnownUidNext: Int?
    ) throws -> Account {
        var account = Account(emailAddress: "\(accountId)@example.com", displayName: "turnover fixture", provider: .imap)
        account.id = accountId
        let toInsert = account
        let folderId = "\(accountId):\(folderPath)"
        try pool.write { db in
            try toInsert.insert(db)
            var folder = Folder(name: folderPath, path: folderPath, role: role, accountId: accountId)
            folder.totalCount = totalCount
            folder.lastKnownUidNext = lastKnownUidNext
            folder.lastKnownUidValidity = storedEpoch
            try folder.insert(db)
            for i in 0..<localHeaderCount {
                let uid = firstLocalUID + i
                var header = MessageHeader(
                    messageId: "\(uid)", subject: "pre-turnover \(uid)", from: "Sender",
                    fromAddress: "sender@example.com", to: "recipient@example.com",
                    date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "pre-turnover",
                    folderId: folderId, accountId: accountId, folderPath: folderPath,
                    isInInbox: role == .inbox
                )
                header.rfc822MessageId = "pre-turnover-\(uid)@example.com"
                header.headerComplete = true
                try header.insert(db)
            }
        }
        return account
    }

    /// The only assertion that matters: how much pre-turnover mail is still here.
    private static func survivingPreTurnoverCount(pool: DatabasePool, folderId: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageHeader
                WHERE folderId = ? AND CAST(messageId AS INTEGER) < ?
                """, arguments: [folderId, firstServerUID]) ?? -1
        }
    }

    private static func postTurnoverCount(pool: DatabasePool, folderId: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageHeader
                WHERE folderId = ? AND CAST(messageId AS INTEGER) >= ?
                """, arguments: [folderId, firstServerUID]) ?? -1
        }
    }

    private static func makeEngine(accountId: String, provider: IMAPProvider) async -> SyncEngine {
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        return engine
    }

    // MARK: - The blocker

    @Test("A UIDVALIDITY turnover deletes no local mail (delta sync)")
    func turnoverThroughDeltaSyncDeletesNoLocalMail() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.postTurnoverMessages()])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "turnover-delta"
        let folderId = "\(accountId):INBOX"
        // The folder as the last pre-turnover sync left it: its rows, its UIDNEXT,
        // and the epoch those rows belong to.
        let account = try Self.seed(
            pool: pool, accountId: accountId, folderPath: "INBOX", role: .inbox,
            storedEpoch: Self.oldEpoch, totalCount: Self.localHeaderCount,
            lastKnownUidNext: Self.firstLocalUID + Self.localHeaderCount)

        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == Self.localHeaderCount,
                "precondition: the folder starts with all its pre-turnover mail")

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        let outcome = try await engine.performDeltaSync(account: account, provider: provider)
        try? await provider.disconnect()

        #expect(outcome.succeeded == true)
        #expect(try Self.postTurnoverCount(pool: pool, folderId: folderId) > 0,
                """
                precondition: the sync must have really run end-to-end (fetched the new \
                epoch's messages), otherwise the reconcile trigger below never fires and \
                this test proves nothing
                """)

        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == Self.localHeaderCount,
                """
                a UIDVALIDITY turnover must delete NO local mail: every local UID belongs to \
                the old numbering, so 'the server does not have UID n' is not evidence that \
                message n is gone (ADR-IOS-051 — never delete on uncertainty)
                """)
    }

    @Test("A UIDVALIDITY turnover deletes no local mail (full sync)")
    func turnoverThroughFullSyncDeletesNoLocalMail() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.postTurnoverMessages()])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "turnover-fullsync"
        let folderId = "\(accountId):INBOX"
        let account = try Self.seed(
            pool: pool, accountId: accountId, folderPath: "INBOX", role: .inbox,
            storedEpoch: Self.oldEpoch, totalCount: Self.localHeaderCount,
            lastKnownUidNext: Self.firstLocalUID + Self.localHeaderCount)

        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == Self.localHeaderCount,
                "precondition: the folder starts with all its pre-turnover mail")

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        try await engine.fullSync(account: account, provider: provider)
        try? await provider.disconnect()

        #expect(try Self.postTurnoverCount(pool: pool, folderId: folderId) > 0,
                "precondition: the full sync must have really fetched the new epoch's messages")

        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == Self.localHeaderCount,
                """
                a UIDVALIDITY turnover must delete NO local mail, whichever sync path \
                observed the new epoch
                """)
    }

    // MARK: - The OPEN hole the bootstrap rule does NOT close

    /// **KNOWN OPEN DEFECT — recorded, not blessed.** `withKnownIssue` keeps this
    /// executable and honest: it documents the hole in code instead of prose, and
    /// it will start FAILING ("known issue was not recorded") the moment the hole
    /// is closed, forcing this test to be promoted rather than forgotten.
    ///
    /// The bootstrap rule protects a folder whose epoch is KNOWN. It cannot
    /// protect one whose epoch is nil, because nil is ambiguous: it means both
    /// "brand-new folder" and "folder full of old-epoch mail we never stamped".
    /// This lifecycle manufactures the second meaning through production code
    /// only:
    ///
    /// 1. Archive syncs normally at epoch E1 → row + headers, epoch stamped E1.
    /// 2. The mailbox disappears server-side. Full sync deletes the `folder` row —
    ///    and its headers SURVIVE, orphaned: migration `v2_dropMessageHeaderFolderFK`
    ///    removed the `messageHeader.folderId → folder` foreign key, so there is no
    ///    cascade (the comment at the deletion site claiming one is stale).
    /// 3. The same path reappears at epoch E2. `Folder.id` is the deterministic
    ///    `"\(accountId):\(path)"`, so the freshly inserted row — with a **nil**
    ///    epoch — re-adopts the orphaned E1 headers.
    /// 4. Bootstrap stamps E2 onto that row, the walk reads E2, the live SELECT
    ///    reports E2, the guard compares equal, and the E1 mail is deleted.
    ///
    /// Closing it requires a whole-folder epoch-ADVANCEMENT protocol (the
    /// `v2final` line's ADR-IOS-061 quarantine → purge → stamp → resync), or a
    /// decision about what a nil epoch over a non-empty folder may assert. That is
    /// an owner-level design call, deliberately not made inside this fix.
    /// **KNOWN OPEN DEFECT — residual path (a), the OTHER way a nil epoch arises.**
    ///
    /// The delete/re-create test below covers path (b): a folder row deleted and
    /// re-created, re-adopting orphaned headers. This one covers path (a): a folder
    /// that was POPULATED BEFORE ITS EPOCH WAS EVER OBSERVED — the state of every
    /// folder that existed before migration v63 added the column, and of any folder
    /// whose mail arrived through a path that never recorded an epoch.
    ///
    /// The two are genuinely independent, and that is the whole point of pinning
    /// them separately: a narrow fix aimed at orphan re-adoption (path b) would make
    /// the other test start passing while THIS exposure is untouched — a green suite
    /// certifying a still-broken invariant. Neither test may be retired until a
    /// whole-folder epoch-ADVANCEMENT protocol makes `nil` mean something provable.
    ///
    /// The sequence uses production code only: a non-empty folder with a nil epoch
    /// is handed a live epoch by the bootstrap, which ASSERTS that the rows already
    /// present belong to it. They do not — they predate any observation — and the
    /// walk then deletes them as ghosts.
    @Test("OPEN: a folder populated before its first epoch observation loses that mail")
    func nilEpochOverPrePopulatedFolderStillLosesMail() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": Self.postTurnoverMessages()])
        server.setUidValidity(Self.newEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "turnover-prepopulated"
        let folderId = "\(accountId):INBOX"
        // The pre-v63 shape: rows present, epoch NEVER observed (nil ≠ "fresh folder").
        let account = try Self.seed(
            pool: pool, accountId: accountId, folderPath: "INBOX", role: .inbox,
            storedEpoch: nil, totalCount: Self.localHeaderCount,
            lastKnownUidNext: Self.firstLocalUID + Self.localHeaderCount)

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        _ = try await engine.performDeltaSync(account: account, provider: provider)
        try? await provider.disconnect()

        let survivors = try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId)
        withKnownIssue("a nil epoch over a NON-EMPTY folder is unprovable — needs an epoch-advancement protocol") {
            #expect(survivors == Self.localHeaderCount,
                    "mail that predates any epoch observation must not be asserted into the observed epoch")
        }
    }

    @Test("OPEN: a delete/re-create lifecycle still loses the orphaned mail")
    func deleteRecreateLifecycleStillLosesOrphanedMail() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": [], "Archive": Self.postTurnoverMessages()])
        server.setUidValidity(Self.oldEpoch, for: "Archive")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "turnover-lifecycle"
        let folderId = "\(accountId):Archive"
        // Step 1 — a folder that has synced normally at E1: its rows and a stamped
        // epoch. (Seeded directly; the point under test is steps 2-4.)
        let account = try Self.seed(
            pool: pool, accountId: accountId, folderPath: "Archive", role: .archive,
            storedEpoch: Self.oldEpoch, totalCount: Self.localHeaderCount,
            lastKnownUidNext: Self.firstLocalUID + Self.localHeaderCount)

        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)

        // Step 2 — the mailbox disappears. Full sync deletes the folder ROW; the
        // headers are orphaned, not cascaded.
        server.markMailboxDeleted("Archive", includeNonexistentCode: true)
        try await engine.fullSync(account: account, provider: provider)
        let folderRowGone = try await pool.read { db in try Folder.fetchOne(db, key: folderId) == nil }
        #expect(folderRowGone, "precondition: the vanished folder's row is deleted")
        #expect(try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId) == Self.localHeaderCount,
                "precondition: its headers survive orphaned — there is no FK cascade")

        // Step 3/4 — the same path reappears under a NEW epoch. The re-created row
        // is born with a nil epoch and re-adopts the orphaned E1 headers.
        server.markMailboxRestored("Archive")
        server.setUidValidity(Self.newEpoch, for: "Archive")
        try await engine.fullSync(account: account, provider: provider)
        try? await provider.disconnect()

        let survivors = try Self.survivingPreTurnoverCount(pool: pool, folderId: folderId)
        withKnownIssue("nil epoch over a non-empty folder cannot be proven — needs an epoch-advancement protocol") {
            #expect(survivors == Self.localHeaderCount,
                    "orphaned old-epoch mail must survive a folder re-create under a new epoch")
        }
    }
}
