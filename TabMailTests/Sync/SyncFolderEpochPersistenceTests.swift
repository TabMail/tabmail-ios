/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// T1.2 (E2) — the red-first proof that a folder's IMAP UIDVALIDITY epoch is
/// **durable**, not merely observable, and that making it durable never turns
/// the column into a mirror of the live server epoch.
///
/// Before this item `Folder.lastKnownUidValidity` (migration v63) had exactly
/// ONE writer: the deletion-reconcile walk, which only runs when a STATUS count
/// mismatch produces evidence of ghost rows. Its own doc comment said "Nil until
/// the first walk runs" — so a folder that had never been reconciled had no
/// epoch at all, which is precisely the folder a stamping or compare step cannot
/// handle. `tabmail-ios/PROJECT_MEMORY.md` already named the fix: *"proper fix =
/// capture UIDVALIDITY during normal sync SELECTs too, not just the walk."*
///
/// **The persist rule is BOOTSTRAP-ONLY, and that is a data-safety rule.** The
/// column is the deletion-reconcile walk's ABORT GUARD (ADR-IOS-051): its
/// meaning is *the epoch the LOCAL UIDs belong to*, never *the epoch the server
/// last reported*. A sync path that keeps it synced to the live epoch makes the
/// walk's `stored == live` comparison always true, so a real turnover stops
/// aborting and starts DELETING every local header as a ghost. See
/// `UidValidityTurnoverDeletionGuardTests` for the end-to-end proof of that
/// invariant; the tests here pin the persistence contract that delivers it:
///
/// | stored | observed | result |
/// |---|---|---|
/// | nil | known | bootstrap (this item's whole purpose) |
/// | nil | nil / `0` | write nothing — `0` is "not reported", never an epoch |
/// | known | same | no write (WAL etiquette) |
/// | known | DIFFERENT | **no write** — the resync machinery owns a new epoch |
/// | known | nil / `0` | no write — an unknown must never erase a known epoch |
///
/// REFERENCE (`v2final`, tag `e28dd4edb`): this is the contract of that line's
/// single epoch-persist API, `AccountManager.recordObservedUidValidity`
/// (`AccountManager.swift:838`) — *"First observation … persist. Same value: no
/// write (WAL etiquette). CHANGED value: does NOT overwrite the stored value (a
/// later stage's reaction owns stamping the new epoch, as part of the purge).
/// `observed == 0`: unreported (ADR-IOS-051 convention), never recorded, never
/// compared."* Its test suite (`UIDValidityEpochLedgerTests`) pins the same
/// branches; these are the v3 equivalents at the two sync writers v3 has.
///
/// **This item changes WHAT IS STORED, and nothing else.** It deliberately adds
/// no new consumer of the epoch, because every consumer is a potential deleter:
///
/// - The `Folder.lastKnownHighestModSeq` cursor is *"only comparable WITHIN one
///   UIDVALIDITY epoch"*, but it is deliberately NOT nulled on a turnover. Under
///   bootstrap-only the stored epoch stays behind until an advancement protocol
///   exists, so a null-on-mismatch rule would fire every cycle and destroy the
///   CONDSTORE signal for that folder forever. `v2final` has no such reset either
///   and keeps the base comment — *"A UIDVALIDITY change moves uidNext/count (→
///   this path re-runs), so a stale-epoch modseq self-corrects on the following
///   cycle"* — verbatim.
/// - An epoch term in the CONDSTORE **fetch-skip** gate was tried and REVERTED.
///   "Blocking a skip only causes more fetching, which is the safe direction" is
///   FALSE here: the fetch path itself deletes (`runSyncMessages` has no epoch
///   guard), so forcing a fetch across a turnover destroys mail that HEAD's skip
///   leaves alone. See `turnoverFetchIsAnUnguardedDeleter` below — that hazard is
///   pre-existing, is NOT this item's to fix, and must not be WIDENED by it.
///
/// ## Red-first evidence (recorded 2026-07-30)
///
/// With all persist sites reverted to their pre-item shape (the two
/// `SyncEngineFullSync` upsert arms, and both the unchanged-branch and
/// changed-branch writes in `SyncEngineDeltaSync`), **6 of the original 8
/// integration tests fail** — `Test run with 8 tests in 2 suites failed ... with
/// 7 issues`. The recorded expectations, verbatim:
///
/// ```
/// ✘ "A folder that was never deletion-reconciled still ends up with a readable epoch"
///     Expectation failed: (after?.lastKnownUidValidity → nil) == 424242
/// ✘ "A folder first seen by full sync is inserted carrying its epoch"
///     Expectation failed: (after?.lastKnownUidValidity → nil) == 424243
/// ✘ "An epoch turnover resets the CONDSTORE cursor in the same write"
///     Expectation failed: (after?.lastKnownUidValidity → 111) == 222
///     Expectation failed: (after?.lastKnownHighestModSeq → 12) == nil
/// ✘ "A folder delta sync finds unchanged still refreshes its epoch"
///     Expectation failed: (after?.lastKnownUidValidity → nil) == (777_001 → 777001)
/// ✘ "A folder delta sync finds changed persists its epoch alongside the other cursors"
///     Expectation failed: (after?.lastKnownUidValidity → nil) == (777_002 → 777002)
/// ```
///
/// ⚠ **The third of those recorded expectations asserted the defect.** It
/// demanded that a turnover REPLACE the stored `111` with `222` — exactly the
/// overwrite that disarms the walk's abort guard — and was retired on
/// 2026-07-30 by `epochTurnoverNeverOverwritesTheStoredEpoch` below, which
/// asserts the opposite. Its second half (the cursor null) is retired for the
/// reason given above, and the fetch-skip expectation from that run is retired
/// with the gate it pinned. Everything else in that run stands.
///
/// ## Red-first evidence for the BOOTSTRAP-ONLY rule — MEASURED (2026-07-30)
///
/// The three tests that pin "no overwrite" were then re-proved against a tree
/// with the rule reverted in place (`uidValidityBootstrapWrite` made
/// unconditional, and the `lastKnownUidValidity IS NULL` predicate dropped from
/// both conditional UPDATEs) — i.e. the shape T1.2 originally shipped. Verbatim:
///
/// ```
/// ✘ Test "An epoch turnover never overwrites the epoch the local UIDs belong to"
///   recorded an issue at SyncFolderEpochPersistenceTests.swift:253:9:
///   Expectation failed: (after?.lastKnownUidValidity → 222) == 111
/// ✘ Test "A quiet folder whose epoch turned over keeps the epoch its local UIDs
///   belong to" recorded an issue at SyncFolderEpochPersistenceTests.swift:547:9:
///   Expectation failed: (after?.lastKnownUidValidity → 777222) == (777_111 → 777111)
/// ✘ Test "The persist decision is bootstrap-only" recorded an issue at :600:9:
///   Expectation failed: (SyncEngine.uidValidityBootstrapWrite(observed: 100, stored: 100) → 100) == nil
/// ✘ Test "The persist decision is bootstrap-only" recorded an issue at :601:9:
///   Expectation failed: (SyncEngine.uidValidityBootstrapWrite(observed: 222, stored: 111) → 222) == nil
/// ✘ Test run with 15 tests in 3 suites failed after 0.918 seconds with 4 issues.
/// ```
///
/// `→ 222` / `→ 777222` are the live server epoch landing on top of the epoch the
/// local UIDs belong to. The other 11 tests in those suites — the bootstrap cases
/// and both deliberate controls — stayed green in the same run, which is what
/// makes this a targeted red rather than a broken fixture.
///
/// The two tests green on BOTH shapes are the deliberate controls:
/// `sameEpochKeepsRefreshingTheModseqCursor` (the pre-change code already
/// refreshed a same-epoch cursor, so it must NOT start failing — it guards
/// against over-resetting) and `sameEpochIsNotAFetchSkipRegression` (proves the
/// CONDSTORE skip the test above measures is a real, still-working mechanism
/// that the epoch guard narrowed rather than disabled).
///
/// Each suite runs against its OWN `AppDatabase` (T0.4's `TestDatabaseTeardown`
/// machinery) swapped into the shared slot inside a `defer`, so a throwing
/// `try` can never strand fixture rows in an ambient pool.
///
/// `.serialized, .processGlobalState` — these suites replace `AppDatabase.shared`
/// and drive the shared `SyncEngine` statics (`fullSyncSkipStreak`), and the
/// delta suite binds a listening socket via `FakeIMAPServer`.

// MARK: - Shared fixtures

enum FolderEpochTestFixture {

    /// Real `DatabasePool`-backed `AppDatabase` (runs all migrations) swapped into
    /// the shared slot so `SyncEngine.dbPool` / `AppDatabase.dbPool` hit the test DB.
    /// Idiom copied from the sibling `StaleProtectionTests.makeAppDB`.
    static func makeAppDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        return (pool, dir, previous)
    }

    static func makeAccount(id: String, provider: AccountProvider, pool: DatabasePool) throws -> Account {
        var account = Account(emailAddress: "\(id)@example.com", displayName: "T1.2 fixture", provider: provider)
        account.id = id
        let toInsert = account
        try pool.write { db in try toInsert.insert(db) }
        return account
    }

    static func insertFolder(
        accountId: String,
        path: String,
        role: FolderRole,
        pool: DatabasePool,
        totalCount: Int = 0,
        lastKnownUidNext: Int? = nil,
        lastKnownUidValidity: Int? = nil,
        lastKnownHighestModSeq: Int? = nil
    ) throws {
        try pool.write { db in
            var folder = Folder(name: path, path: path, role: role, accountId: accountId)
            folder.totalCount = totalCount
            folder.lastKnownUidNext = lastKnownUidNext
            folder.lastKnownUidValidity = lastKnownUidValidity
            folder.lastKnownHighestModSeq = lastKnownHighestModSeq
            try folder.insert(db)
        }
    }

    static func readFolder(accountId: String, path: String, pool: DatabasePool) throws -> Folder? {
        try pool.read { db in try Folder.fetchOne(db, key: "\(accountId):\(path)") }
    }

    /// Seed real `messageHeader` rows so a test can assert on MAIL SURVIVING a
    /// sync pass rather than on which provider calls the pass happened to make.
    /// `messageId` IS the IMAP UID.
    static func insertHeaders(accountId: String, path: String, uids: [Int], pool: DatabasePool) throws {
        let folderId = "\(accountId):\(path)"
        try pool.write { db in
            for uid in uids {
                var header = MessageHeader(
                    messageId: "\(uid)", subject: "epoch fixture \(uid)", from: "Sender",
                    fromAddress: "sender@example.com", to: "recipient@example.com",
                    date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "epoch fixture",
                    folderId: folderId, accountId: accountId, folderPath: path,
                    isInInbox: false
                )
                header.rfc822MessageId = "epoch-fixture-\(uid)@example.com"
                header.headerComplete = true
                try header.insert(db)
            }
        }
    }

    static func headerCount(accountId: String, path: String, pool: DatabasePool) throws -> Int {
        let folderId = "\(accountId):\(path)"
        return try pool.read { db in
            try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db)
        }
    }
}

extension MockEmailProvider {
    /// Read-only snapshot of the actor's recorded calls. The skip tests below
    /// assert on WHICH provider calls a full sync made, which is the only
    /// externally visible evidence that a folder was or was not fetched.
    func callLogSnapshot() -> [String] { callLog }
}

// MARK: - Full-sync / folder-list path

@Suite("T1.2 — the folder-list sync bootstraps the epoch", .serialized, .processGlobalState)
struct SyncFullSyncFolderEpochTests {

    @Test("A folder that was never deletion-reconciled still ends up with a readable epoch")
    func neverReconciledFolderBecomesEpochReadable() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12-fullsync-existing"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 3)

        // Precondition — this is exactly the folder the old code could not
        // answer for: present locally, never walked, so no epoch at all.
        let before = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(before?.lastKnownUidValidity == nil,
                "precondition: a never-reconciled folder has no epoch")

        let mock = MockEmailProvider()
        await mock.setFetchFoldersResult([
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0,
                       totalCount: 3, uidNext: 42, uidValidity: 424242)
        ])
        await mock.setFetchMessagesResult([])

        try await SyncEngine().fullSync(account: account, provider: mock)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == 424242,
                "a folder-list sync must leave the folder's current epoch readable from the DB")
    }

    @Test("A folder first seen by full sync is inserted carrying its epoch")
    func folderFirstSeenByFullSyncIsInsertedWithItsEpoch() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12-fullsync-new"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)

        let before = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(before == nil, "precondition: the folder does not exist locally yet")

        let mock = MockEmailProvider()
        await mock.setFetchFoldersResult([
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0,
                       totalCount: 0, uidNext: 1, uidValidity: 424243)
        ])
        await mock.setFetchMessagesResult([])

        try await SyncEngine().fullSync(account: account, provider: mock)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after != nil, "the folder must have been inserted")
        #expect(after?.lastKnownUidValidity == 424243,
                "a newly discovered folder must be born with its epoch, not with nil")
    }

    /// Replaces the retired "An epoch turnover resets the CONDSTORE cursor in the
    /// same write", which asserted the overwrite this test forbids.
    @Test("An epoch turnover never overwrites the epoch the local UIDs belong to")
    func epochTurnoverNeverOverwritesTheStoredEpoch() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12-fullsync-epoch-turnover"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 3,
            lastKnownUidValidity: 111, lastKnownHighestModSeq: 9000)

        let mock = MockEmailProvider()
        // The mailbox was recreated: a NEW epoch, and the server's modseq
        // restarted low.
        await mock.setFetchFoldersResult([
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0,
                       totalCount: 3, uidNext: 4, highestModSeq: 12, uidValidity: 222)
        ])
        await mock.setFetchMessagesResult([])

        try await SyncEngine().fullSync(account: account, provider: mock)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == 111,
                """
                the stored epoch describes the LOCAL UIDs, not the live server: advancing it \
                here would make the deletion-reconcile walk's stored-vs-live comparison equal \
                and delete every local header as a ghost (ADR-IOS-051)
                """)
        #expect(after?.lastKnownHighestModSeq == 12,
                """
                the cursor still refreshes — a stale-epoch modseq self-corrects on the \
                following cycle, whereas nulling it on a permanently-behind stored epoch \
                would destroy the CONDSTORE signal for this folder forever
                """)
    }

    @Test("A stable epoch keeps refreshing the CONDSTORE cursor (no over-reset)")
    func sameEpochKeepsRefreshingTheModseqCursor() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12-fullsync-epoch-stable"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 3,
            lastKnownUidValidity: 111, lastKnownHighestModSeq: 9000)

        let mock = MockEmailProvider()
        await mock.setFetchFoldersResult([
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0,
                       totalCount: 3, uidNext: 4, highestModSeq: 9500, uidValidity: 111)
        ])
        await mock.setFetchMessagesResult([])

        try await SyncEngine().fullSync(account: account, provider: mock)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == 111)
        #expect(after?.lastKnownHighestModSeq == 9500,
                "within one epoch the cursor must still advance")
    }

    /// **KNOWN OPEN DEFECT — the merge pass is a SECOND, unguarded deleter.**
    ///
    /// This is NOT introduced by T1.2 and is NOT closed by it; it is pinned here
    /// because T1.2 is the item that established the epoch is durably readable,
    /// which is the precondition for ever closing it. `runSyncMessages` has no
    /// UIDVALIDITY guard: `selectStaleHeaders`'s complete-knowledge branch
    /// (`fetched.count < limit`) classifies every local row the fetch did not
    /// return as deleted-on-the-server. On a re-created mailbox that is true of
    /// EVERY row — the new numbering restarts beneath them all — so a folder that
    /// is fetched across a turnover loses its mail without the ADR-IOS-051
    /// reconcile walk ever being consulted.
    ///
    /// `v2final` closes it with the §5.5 universal in-txn guard
    /// (`SyncEngineFullSync.swift:1045-1070` at tag `e28dd4edb`): re-read the
    /// folder row INSIDE the merge transaction and abandon the entire pass —
    /// before any deletion or upsert — when the epoch captured at fetch time
    /// disagrees with the stored one. Porting that is its own item.
    ///
    /// ⚠ An earlier draft of T1.2 tried to make a turnover BLOCK the CONDSTORE
    /// fetch-skip, on the reasoning that "more fetching is the conservative
    /// direction". It is not, and this test is the reason: forcing the fetch is
    /// precisely what hands the folder to the deleter above, so that change turned
    /// a folder HEAD leaves untouched into one that loses its mail. It was
    /// reverted. Do not reintroduce an epoch term in `shouldSkipFolderFetch`'s
    /// caller until the merge pass is guarded.
    @Test("OPEN: a turnover that gets fetched loses its mail to the unguarded merge pass")
    func turnoverFetchIsAnUnguardedDeleter() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12-fullsync-skip-turnover"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool, totalCount: 3,
            lastKnownUidValidity: 111, lastKnownHighestModSeq: 9000)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive", uids: [1, 2, 3], pool: pool)

        let mock = MockEmailProvider()
        // The mailbox was recreated (epoch 111 → 222). The modseq also moved, so
        // nothing skips this folder — it is fetched, which is the ordinary case.
        await mock.setFetchFoldersResult([
            FolderInfo(name: "Archive", path: "Archive", role: .archive, unreadCount: 0,
                       totalCount: 3, uidNext: 4, highestModSeq: 9500, uidValidity: 222)
        ])
        await mock.setFetchMessagesResult([])

        try await SyncEngine().fullSync(account: account, provider: mock)

        let calls = await mock.callLogSnapshot()
        #expect(calls.contains { $0.hasPrefix("fetchMessages(folder:Archive") },
                "precondition: the folder must actually be fetched; call log was \(calls)")
        #expect(try FolderEpochTestFixture.readFolder(
            accountId: accountId, path: "Archive", pool: pool)?.lastKnownUidValidity == 111,
                "bootstrap-only holds: the stored epoch still describes the LOCAL rows")

        let survivors = try FolderEpochTestFixture.headerCount(
            accountId: accountId, path: "Archive", pool: pool)
        withKnownIssue("runSyncMessages has no UIDVALIDITY guard — needs the v2final §5.5 in-txn merge guard") {
            #expect(survivors == 3,
                    "a UIDVALIDITY turnover must delete NO local mail (ADR-IOS-051)")
        }
    }

    /// The CONTROL for the test above: same fixture, same empty fetch, but the
    /// epoch AGREES. It must delete all 3 — which proves the sweep is a genuinely
    /// live deleter in this exact fixture, and therefore that the known issue above
    /// is a real exposure rather than an inert test that would "fail" for some
    /// unrelated reason. It is also the guard-rail for the future §5.5 port: a
    /// guard that accidentally switched the sweep OFF everywhere would turn this
    /// control red, where a correct one leaves it green.
    @Test("Control: within ONE epoch the windowed sweep still deletes (the future guard must not be a global off-switch)")
    func sameEpochStillLetsTheStaleSweepDelete() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12-fullsync-sweep-control"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool, totalCount: 0,
            lastKnownUidValidity: 111, lastKnownHighestModSeq: 9000)
        try FolderEpochTestFixture.insertHeaders(
            accountId: accountId, path: "Archive", uids: [1, 2, 3], pool: pool)

        let mock = MockEmailProvider()
        // Same epoch (111 → 111), modseq moved, so the folder is fetched for a
        // reason unrelated to UIDVALIDITY — the ordinary "these were deleted on
        // another client" case the sweep exists to serve.
        await mock.setFetchFoldersResult([
            FolderInfo(name: "Archive", path: "Archive", role: .archive, unreadCount: 0,
                       totalCount: 0, uidNext: 4, highestModSeq: 9500, uidValidity: 111)
        ])
        await mock.setFetchMessagesResult([])

        try await SyncEngine().fullSync(account: account, provider: mock)

        #expect(try FolderEpochTestFixture.headerCount(
            accountId: accountId, path: "Archive", pool: pool) == 0,
                """
                within one epoch an empty fetch IS complete knowledge, so the sweep must \
                still remove the rows — the §5.5 guard narrows it to epoch agreement, it \
                does not switch it off
                """)
    }

    @Test("A stable epoch still lets an unchanged modseq skip the fetch (control)")
    func sameEpochIsNotAFetchSkipRegression() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12-fullsync-skip-stable"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool, totalCount: 3,
            lastKnownUidValidity: 111, lastKnownHighestModSeq: 9000)

        let mock = MockEmailProvider()
        await mock.setFetchFoldersResult([
            FolderInfo(name: "Archive", path: "Archive", role: .archive, unreadCount: 0,
                       totalCount: 3, uidNext: 4, highestModSeq: 9000, uidValidity: 111)
        ])
        await mock.setFetchMessagesResult([])

        try await SyncEngine().fullSync(account: account, provider: mock)

        let calls = await mock.callLogSnapshot()
        #expect(!calls.contains { $0.hasPrefix("fetchMessages(folder:Archive") },
                "within one epoch an unchanged HIGHESTMODSEQ must still skip the fetch; call log was \(calls)")
    }

    @Test("An UNREPORTED epoch never erases a stored one")
    func nilObservationNeverErasesAStoredEpoch() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12-fullsync-nil-observation"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 3,
            lastKnownUidValidity: 111)

        let mock = MockEmailProvider()
        // A server that does not advertise UIDPLUS reports no UIDVALIDITY on
        // STATUS at all — the whole folder listing carries nil.
        await mock.setFetchFoldersResult([
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0,
                       totalCount: 3, uidNext: 4, uidValidity: nil)
        ])
        await mock.setFetchMessagesResult([])

        try await SyncEngine().fullSync(account: account, provider: mock)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == 111,
                "an unknown observation is not evidence of anything and must never clear a known epoch")
    }

    @Test("The 0 sentinel is never persisted and never overwrites a known epoch")
    func zeroIsNeverPersisted() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12-fullsync-zero"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        // Three shapes in one pass: a never-stamped folder, a stamped folder,
        // and a folder that does not exist locally yet (the insert arm).
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 0)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool, totalCount: 0,
            lastKnownUidValidity: 111)

        let mock = MockEmailProvider()
        // RFC 3501 types UIDVALIDITY as nz-number, so 0 can only ever mean "not
        // reported" — the shape `Mailbox.Selection.uidValidity` defaults to.
        await mock.setFetchFoldersResult([
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0,
                       totalCount: 0, uidNext: 1, uidValidity: 0),
            FolderInfo(name: "Archive", path: "Archive", role: .archive, unreadCount: 0,
                       totalCount: 0, uidNext: 1, uidValidity: 0),
            FolderInfo(name: "Sent", path: "Sent", role: .sent, unreadCount: 0,
                       totalCount: 0, uidNext: 1, uidValidity: 0)
        ])
        await mock.setFetchMessagesResult([])

        try await SyncEngine().fullSync(account: account, provider: mock)

        let inbox = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        let archive = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Archive", pool: pool)
        let sent = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Sent", pool: pool)
        #expect(inbox?.lastKnownUidValidity == nil,
                "0 is 'the server did not report a value' — persisting it makes every later epoch compare 0 == 0, i.e. vacuous")
        #expect(archive?.lastKnownUidValidity == 111,
                "an unreported epoch must never overwrite a known-good one")
        #expect(sent != nil, "the new folder must have been inserted")
        #expect(sent?.lastKnownUidValidity == nil,
                "a folder born from a 0-reporting listing must be born with nil, not with 0")
    }
}

// MARK: - Delta-sync path

@Suite("T1.2 — IMAP delta sync bootstraps the epoch", .serialized, .processGlobalState)
struct SyncDeltaFolderEpochTests {

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: t1.2-fixture\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        t1.2 fixture body.\r

        """
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

    /// THE headline case. A quiet folder takes delta sync's unchanged early
    /// return, which persisted nothing at all — so the folder that is least
    /// likely to be touched by any other writer was also the folder guaranteed
    /// never to acquire an epoch.
    @Test("A folder delta sync finds unchanged still bootstraps its epoch")
    func quietFolderStillBootstrapsItsEpoch() async throws {
        let message = FakeIMAPServer.makeMessage(
            uid: 1, rfc822Text: Self.rfc822(messageId: "t12-delta-quiet@example.com"))
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message]])
        server.setUidValidity(777_001, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12-delta-quiet"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        // Matched to the fake exactly so BOTH change signals read "unchanged":
        // UIDNEXT is (max uid 1) + 1 = 2, and the message count is 1.
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidNext: 2)

        let before = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(before?.lastKnownUidValidity == nil, "precondition: no epoch stored yet")

        let provider = Self.provider(for: server)
        try await provider.connect()
        let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)
        try? await provider.disconnect()

        #expect(outcome.succeeded == true)
        #expect(outcome.hadChanges == false,
                "precondition: the folder must have taken the UNCHANGED branch — that is the branch under test")

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == 777_001,
                "a quiet folder must still leave its current epoch readable from the DB")
    }

    @Test("A folder delta sync finds changed bootstraps its epoch alongside the other cursors")
    func changedFolderBootstrapsItsEpoch() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": []])
        server.setUidValidity(777_002, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12-delta-changed"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        // UIDNEXT matches the empty fake (0 + 1 = 1) but the cached count does
        // not — so the count signal alone drives this down the CHANGED branch.
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 7, lastKnownUidNext: 1)

        let provider = Self.provider(for: server)
        try await provider.connect()
        let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)
        try? await provider.disconnect()

        #expect(outcome.succeeded == true)
        #expect(outcome.hadChanges == true,
                "precondition: the folder must have taken the CHANGED branch — that is the branch under test")

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == 777_002,
                "the changed-folder cursor write must carry the epoch too")
    }

    @Test("A quiet folder whose epoch turned over keeps the epoch its local UIDs belong to")
    func quietFolderNeverOverwritesADifferingStoredEpoch() async throws {
        let message = FakeIMAPServer.makeMessage(
            uid: 1, rfc822Text: Self.rfc822(messageId: "t12-delta-turnover@example.com"))
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message]])
        server.setUidValidity(777_222, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountId = "t12-delta-turnover"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidNext: 2, lastKnownUidValidity: 777_111)

        let provider = Self.provider(for: server)
        try await provider.connect()
        let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)
        try? await provider.disconnect()

        #expect(outcome.succeeded == true)

        let after = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(after?.lastKnownUidValidity == 777_111,
                """
                the quiet branch may BOOTSTRAP an empty column but must never restamp one: \
                overwriting 777111 with the live 777222 is what disarms the deletion-reconcile \
                walk's abort guard
                """)
    }
}

// MARK: - The pure epoch decisions

@Suite("T1.2 — the epoch decision functions")
struct UidValidityEpochDecisionTests {

    @Test("0 is 'not reported', never an epoch")
    func zeroIsNotAnEpoch() {
        #expect(SyncEngine.knownUidValidity(0) == nil)
        #expect(SyncEngine.knownUidValidity(nil) == nil)
        #expect(SyncEngine.knownUidValidity(-1) == nil, "RFC 3501 types UIDVALIDITY as nz-number")
        #expect(SyncEngine.knownUidValidity(1) == 1)
        // The 0 must be filtered at the NORMALIZER, not at each comparison site:
        // a stored 0 would make every later `stored == live` epoch check vacuously
        // true, silently disarming the guards built on it.
        #expect(SyncEngine.uidValidityBootstrapWrite(observed: 0, stored: nil) == nil)
    }

    @Test("The persist decision is bootstrap-only")
    func bootstrapWriteContract() {
        // Empty column + a real observation ⇒ bootstrap (the item's purpose).
        #expect(SyncEngine.uidValidityBootstrapWrite(observed: 100, stored: nil) == 100)
        // Empty column + an unknown observation ⇒ write nothing.
        #expect(SyncEngine.uidValidityBootstrapWrite(observed: nil, stored: nil) == nil)
        #expect(SyncEngine.uidValidityBootstrapWrite(observed: 0, stored: nil) == nil)
        // Already stamped ⇒ never written again, whatever is observed. The
        // DIFFERENT case is the data-safety one: the column means "the epoch the
        // local UIDs belong to", and only a purge-and-resync may advance it.
        #expect(SyncEngine.uidValidityBootstrapWrite(observed: 100, stored: 100) == nil)
        #expect(SyncEngine.uidValidityBootstrapWrite(observed: 222, stored: 111) == nil)
        #expect(SyncEngine.uidValidityBootstrapWrite(observed: nil, stored: 111) == nil)
        #expect(SyncEngine.uidValidityBootstrapWrite(observed: 0, stored: 111) == nil)
    }
}
