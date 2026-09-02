/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Shared SQL

/// The BODY-FETCH ADMISSION queries — taken from the PRODUCTION symbols, not transcribed.
/// `ActiveBodyQueue.admissionSQL` and `BackfillBodyQueue.admissionSQL` are each the sole
/// source used by that queue's `repopulateFromDatabase` and `repopulateOnDrain`, so the
/// plan asserted below is the plan production runs. These used to be hand-copied string
/// literals: a transcription cannot fail when production changes, so the gate silently
/// stopped measuring anything the moment the two drifted.
///
/// The behavioural claim (a flagged row leaves background admission) is pinned separately
/// against the REAL queues in `OversizedBodyQuarantineDatabaseTests`, which drives
/// `repopulateFromDatabase()` itself.
private enum AdmissionSQL {
    static let activeRepopulate = ActiveBodyQueue.admissionSQL
    static let backfillRepopulate = BackfillBodyQueue.admissionSQL

    /// The same query WITHOUT the new conjunct — the negative control. Without it the
    /// gate cannot tell "the index is used because we added the clause" from "the index
    /// would have been used anyway". Derived from the production string by deleting the
    /// conjunct, so it cannot drift away from the query it is a control for. Line-based
    /// rather than a literal `replacingOccurrences` so it survives the indentation Swift
    /// strips from a multi-line literal.
    static let withoutConjunct = backfillRepopulate
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.contains("bodyMetadataOversized") }
        .joined(separator: "\n")

    static let all: [(name: String, sql: String)] = [
        ("ActiveBodyQueue.repopulateFromDatabase / .repopulateOnDrain", activeRepopulate),
        ("BackfillBodyQueue.repopulateFromDatabase / .repopulateOnDrain", backfillRepopulate),
    ]
}

/// ⚠️ `EXPLAIN QUERY PLAN` returns (id, parent, notused, detail). Fetching the FIRST
/// column yields the row id — a plausible-looking string that contains none of the plan
/// text, so every `contains` assertion against it fails for the wrong reason. The plan
/// lives in `detail`.
private func queryPlan(_ db: DatabaseQueue, _ sql: String) throws -> String {
    try db.read { conn in
        try Row.fetchAll(conn, sql: "EXPLAIN QUERY PLAN " + sql)
            .compactMap { $0["detail"] as String? }
            .joined(separator: " | ")
    }
}

// MARK: -

/// The acceptance criterion for this change is that the admission query is provably
/// optimal under the new index. That makes this a PLAN-SHAPE gate,
/// not a timing benchmark — simulator timings understate device by 2-4x, so a duration
/// assertion would prove nothing.
///
/// ⚠️ A PARTIAL index was tried first and REJECTED BY MEASUREMENT: with
/// `messageHeader_bodyRepopulate` (v40) already present, the planner never chose a
/// partial `(isInInbox, date)` index, so it would have been pure write amplification.
/// Extending v40's proven column list by one equality column is what actually moves the
/// plan. Do not re-propose the partial index without re-running EXPLAIN QUERY PLAN.
@Suite("The body-queue index serves every admission query optimally")
struct OversizedDurableFlagIndexTests {

    private static let indexName = "messageHeader_bodyRepopulateV2"

    /// The index is NOT built by the migration — it lives in
    /// `SyncEngine.deferredIndexes` (in `SyncEngineMaintenance.swift`) so it stays off the blocking launch path
    /// (ADR-IOS-029). Tests reach it through the PRODUCTION DDL rather than re-typing the
    /// `CREATE INDEX`, exactly as `createDeferredIndexes`' own doc comment requires: a
    /// re-typed copy is a test that passes against a statement the app does not run.
    private static func makeDBWithDeferredIndexes() throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        try db.write { try SyncEngine.createDeferredIndexes($0) }
        return db
    }

    /// OPTIMAL here has a precise meaning: all five equality predicates are satisfied by
    /// the index SEEK (not filtered row-by-row afterwards), and `date` is supplied in
    /// order so nothing is sorted in memory.
    @Test("Every admission query seeks on all five equality columns")
    func admissionQueriesSeekOnEveryEqualityColumn() throws {
        let db = try Self.makeDBWithDeferredIndexes()
        for q in AdmissionSQL.all {
            let plan = try queryPlan(db, q.sql)
            #expect(plan.contains(Self.indexName),
                    "\(q.name) must ride the extended index — plan was: \(plan)")
            #expect(!plan.contains("SCAN messageHeader"),
                    "\(q.name) must not fall back to a full table scan — plan was: \(plan)")
            for column in ["isInInbox", "headerComplete", "bodyComplete",
                           "bodyEmptyConfirmed", "bodyMetadataOversized"] {
                #expect(plan.contains("\(column)=?"),
                        "\(column) must be part of the index SEEK, not a per-row filter — plan was: \(plan)")
            }
        }
    }

    /// `date` is the index's last column, so the seek and the ordering are served by one
    /// index. If it led on the wrong column SQLite would still "use" the index and then
    /// sort in memory on every drain — the expensive failure this column order avoids.
    @Test("The index also satisfies ORDER BY date DESC — no temporary B-tree sort")
    func admissionQueriesNeedNoTempBTree() throws {
        let db = try Self.makeDBWithDeferredIndexes()
        for q in AdmissionSQL.all {
            let plan = try queryPlan(db, q.sql)
            #expect(!plan.uppercased().contains("TEMP B-TREE"),
                    "\(q.name) must not sort in memory — plan was: \(plan)")
        }
    }

    /// THE NEGATIVE CONTROL. Without it the assertions above could pass on a build where
    /// this index is irrelevant.
    ///
    /// ⚠️ Note what "degrades" means here, because it is NOT a scan. `messageHeader
    /// _bodyRepopulate` (v40) still exists and still covers four of the five equality
    /// columns, so dropping the new index leaves a working — but strictly weaker — plan
    /// in which `bodyMetadataOversized` is filtered per row. That is exactly the
    /// difference this migration buys, so that is what the control measures.
    @Test("Negative control: without the extended index the fifth predicate drops out of the seek")
    func withoutTheIndexTheFifthPredicateLeavesTheSeek() throws {
        let db = try Self.makeDBWithDeferredIndexes()
        let before = try queryPlan(db, AdmissionSQL.backfillRepopulate)
        #expect(before.contains("bodyMetadataOversized=?"), "precondition — plan was: \(before)")

        try db.write { conn in
            try conn.execute(sql: "DROP INDEX \(Self.indexName)")
        }
        let after = try queryPlan(db, AdmissionSQL.backfillRepopulate)
        #expect(!after.contains("bodyMetadataOversized=?"),
                "with the extended index gone the fifth predicate must fall out of the seek — otherwise the migration bought nothing; plan was: \(after)")
        #expect(after.contains("messageHeader_bodyRepopulate"),
                "and the v40 index must still be there to catch the query — ADR-IOS-029 forbids dropping it; plan was: \(after)")
    }

    /// The column order is the whole design. `date` must come LAST so every equality
    /// column forms an unbroken prefix; a `date` in the middle would end the usable
    /// prefix and silently reintroduce the in-memory sort.
    @Test("The index puts every equality column before date")
    func indexColumnOrderPutsDateLast() throws {
        let db = try Self.makeDBWithDeferredIndexes()
        let ddl: String? = try db.read { conn in
            try String.fetchOne(conn, sql: """
                SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?
                """, arguments: [Self.indexName])
        }
        let sql = try #require(ddl, "the extended index must exist")
        let dateAt = try #require(sql.range(of: "date")?.lowerBound)
        for column in ["isInInbox", "headerComplete", "bodyComplete",
                       "bodyEmptyConfirmed", "bodyMetadataOversized"] {
            let at = try #require(sql.range(of: column)?.lowerBound)
            #expect(at < dateAt, "\(column) must precede date in the index — DDL was: \(sql)")
        }
    }

    /// A query missing the conjunct still returns the flagged row. This pins that the
    /// new clause — and not some other predicate — is what performs the exclusion, so a
    /// future edit that drops it from one of the four queries is visible.
    @Test("A query without the conjunct returns the flagged row — the clause is load-bearing, not decorative")
    func withoutTheConjunctTheFlaggedRowComesBack() throws {
        // The control is DERIVED from the production string — if the derivation ever
        // no-ops, the two are identical and every assertion below becomes vacuous.
        #expect(AdmissionSQL.withoutConjunct != AdmissionSQL.backfillRepopulate,
                "the negative control must actually differ from the production query")
        let db = try TestDatabase.make()
        try seedFlaggedRow(db)

        let excluded = try db.read { try Row.fetchAll($0, sql: AdmissionSQL.backfillRepopulate) }
        #expect(excluded.isEmpty, "the admission query must not return a flagged row")

        let included = try db.read { try Row.fetchAll($0, sql: AdmissionSQL.withoutConjunct) }
        #expect(included.count == 1,
                "the same query without the conjunct still returns it — so the clause, not some other predicate, is what excludes it")
    }

    private func seedFlaggedRow(_ db: DatabaseQueue) throws {
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let h = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )
        try db.write { conn in
            try conn.execute(
                sql: "UPDATE messageHeader SET headerComplete = 1, bodyMetadataOversized = 1 WHERE id = ?",
                arguments: [h.id]
            )
        }
    }
}

// MARK: -

@Suite("Migration v88 adds the oversized flag; its index is deferred off the launch path")
struct OversizedDurableFlagMigrationTests {

    /// ⛔ THE MIGRATION MUST NOT BUILD THE INDEX. ADR-IOS-029's amendment keeps startup
    /// migrations to what is "absolutely necessary and blocking", and this index fails
    /// that test: without it the admission queries still seek on four of five equality
    /// columns in date order with no temp B-tree, so its absence degrades PERFORMANCE
    /// AND NOTHING ELSE. The precedent is `v83_markAllAsReadUnreadSweepIndex`, whose
    /// body is intentionally empty for the same reason after 5,050 ms of blocking launch
    /// was attributed to it. This test is what stops a future edit from moving the
    /// `CREATE INDEX` back into the migration, where it is invisible until a user with a
    /// large mailbox upgrades.
    @Test("The column exists and defaults to 0, and the migration does NOT build the index")
    func migrationShape() throws {
        let db = try TestDatabase.make()

        let columns = try db.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA table_info(messageHeader)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("bodyMetadataOversized"))

        let afterMigrations = try db.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA index_list(messageHeader)")
                .compactMap { $0["name"] as String? }
        }
        #expect(!afterMigrations.contains("messageHeader_bodyRepopulateV2"),
                "the migration chain must leave this index unbuilt — it belongs to the deferred pass")

        // …and the deferred pass DOES build it, from the production DDL. Two-sided: an
        // index that no mechanism ever creates would satisfy the assertion above alone.
        try db.write { try SyncEngine.createDeferredIndexes($0) }
        let afterDeferred = try db.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA index_list(messageHeader)")
                .compactMap { $0["name"] as String? }
        }
        #expect(afterDeferred.contains("messageHeader_bodyRepopulateV2"),
                "the deferred pass is what builds it")

        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let h = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )
        let flag: Bool? = try db.read { conn in
            try Bool.fetchOne(conn, sql: "SELECT bodyMetadataOversized FROM messageHeader WHERE id = ?",
                              arguments: [h.id])
        }
        #expect(flag == false, "an ordinary new row must not be born quarantined")
    }

    @Test("Re-running the migration chain, and the deferred pass, are both no-ops")
    func migrationIsIdempotent() throws {
        let db = try TestDatabase.make()
        try AppDatabase.runMigrations(on: db)   // must not throw
        try db.write { try SyncEngine.createDeferredIndexes($0) }
        try db.write { try SyncEngine.createDeferredIndexes($0) }   // must not throw
        let indexes = try db.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA index_list(messageHeader)")
                .compactMap { $0["name"] as String? }
        }
        #expect(indexes.filter { $0 == "messageHeader_bodyRepopulateV2" }.count == 1,
                "CREATE INDEX IF NOT EXISTS — the pass re-arms on every launch and must converge")
        #expect(indexes.contains("messageHeader_bodyRepopulate"),
                "ADR-IOS-029: the v40 index it extends is never dropped")
    }

    /// The recovery path the dedicated column exists to make possible: when a raised
    /// parser bound ships, ONE statement releases exactly the rows this code flagged —
    /// no re-crawl, no Smart Reindex, no user gesture. It is exact by construction
    /// because nothing else ever writes this column.
    @Test("The upstream-recovery sweep releases exactly the flagged rows")
    func upstreamSweepReleasesExactlyTheFlaggedRows() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let flagged = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false)
        let untouched = try TestDatabase.insertMessageHeader(
            db, messageId: "2", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false)
        try db.write { conn in
            try conn.execute(sql: "UPDATE messageHeader SET headerComplete = 1")
            try conn.execute(sql: "UPDATE messageHeader SET bodyMetadataOversized = 1 WHERE id = ?",
                             arguments: [flagged.id])
            try conn.execute(sql: "UPDATE messageHeader SET bodyEmptyConfirmed = 1 WHERE id = ?",
                             arguments: [untouched.id])
        }

        try db.write { conn in
            try conn.execute(sql: "UPDATE messageHeader SET bodyMetadataOversized = 0 WHERE bodyMetadataOversized = 1")
        }

        let stillFlagged: Int = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE bodyMetadataOversized = 1") ?? -1
        }
        #expect(stillFlagged == 0, "the sweep releases every flagged row")

        let stillEmptyConfirmed: Int = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE bodyEmptyConfirmed = 1") ?? -1
        }
        #expect(stillEmptyConfirmed == 1,
                "and touches nothing else — a confirmed-empty row is a different disposition and must survive the sweep")
    }
}

// MARK: -

/// Where the flag reaches, and — just as importantly — where it deliberately does NOT.
/// Each non-change pinned here is a plausible "cleanup" that would reintroduce a defect,
/// and a deliberate omission that nothing asserts is indistinguishable from an oversight.
@Suite("The durable oversized flag reaches admission and progress, and stops there")
struct OversizedDurableFlagConfinementTests {

    private func seed(_ db: DatabaseQueue) throws -> String {
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let h = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false)
        try db.write { conn in
            try conn.execute(
                sql: "UPDATE messageHeader SET headerComplete = 1, bodyMetadataOversized = 1 WHERE id = ?",
                arguments: [h.id])
        }
        return h.id
    }

    /// INVARIANT (owner decision 2026-09-01): a message this build cannot fetch must not
    /// hold the account's sync open forever. `BackfillProgress.isFullyComplete` gates on
    /// `pendingBodyCount == 0`, so a flagged row left in that count means the sync banner
    /// never clears, the progress bar parks one short of 100%, and Fast Sync keeps the
    /// device awake — indefinitely, over work that cannot be done. The user still learns
    /// the truth about the individual message: opening it reports "unable to load".
    ///
    /// This test previously asserted the OPPOSITE, on the reasoning that `pendingBodyCount`
    /// is a truth claim about the mailbox. That reasoning was sound and was overruled on
    /// product grounds; the reversal is recorded rather than erased so nobody re-derives
    /// the old position from the old comment.
    /// 🚨 **THE `headerComplete` CONJUNCT, from both sides.** Every other fixture that
    /// measures either request sets `headerComplete = 1` — `seed` does it, the partition
    /// test does it on all ten of its rows and says so in its own doc, and
    /// `OversizedBodyQuarantineTests`' Fast Sync fixture does it on both. So the term was
    /// satisfied by construction everywhere, and BOTH of the following edits left the
    /// entire suite green:
    ///
    ///   - deleting `Column("headerComplete") == true` from `pendingBodyRequest`; and
    ///   - "restoring symmetry" by ADDING it to `bodySettledRequest`, which deliberately
    ///     omits it.
    ///
    /// Neither is hypothetical. `headerComplete = 0` rows are durably reachable:
    /// `NSEDataBridge` stages headers with `headerComplete = false` and flips the flag in a
    /// SEPARATE statement (ADR-IOS-047's two-phase merge — it carries both a
    /// `… AND headerComplete = 0` count and a post-transaction
    /// `UPDATE … SET headerComplete = 1 … AND headerComplete = 0`), so an extension wake
    /// terminated between the staging write and the flush leaves such a row behind.
    ///
    /// The consequences are mirror images, and both are the failure this branch exists to
    /// remove. Deleting the term from `pendingBodyRequest` puts a staged row into
    /// `pendingBodyCount`, so `BackfillProgress.isFullyComplete` is never true: the banner
    /// never clears and Fast Sync holds the screen awake indefinitely. Adding it to
    /// `bodySettledRequest` drops staged-but-settled rows from `ftsIndexed` while
    /// `totalEmails` still counts every row for the account, so the "N / M indexed" readout
    /// sits permanently below its denominator.
    ///
    /// Two-sided in one test: each assertion is paired with a header-complete control of the
    /// same shape, so neither can be satisfied by an empty result. (Found by audit.)
    @Test("The headerComplete conjunct is pinned on both requests — present on pending, absent from settled")
    func headerCompleteConjunctIsPinnedOnBothRequests() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        // A STAGED row: header not yet flipped, no disposition settled. `insertMessageHeader`
        // does not touch `headerComplete` and the model defaults it to false, so this row is
        // staged simply by NOT running the `UPDATE` every other fixture here runs.
        let staged = try TestDatabase.insertMessageHeader(
            db, messageId: "staged", folderId: "acc1:Archive",
            folderPath: "Archive", isInInbox: false)
        // A STAGED-BUT-SETTLED row: still not header-complete, but its body did land.
        let stagedSettled = try TestDatabase.insertMessageHeader(
            db, messageId: "staged-settled", folderId: "acc1:Archive",
            folderPath: "Archive", isInInbox: false)
        // The CONTROLS, header-complete, one of each shape.
        let pendingControl = try TestDatabase.insertMessageHeader(
            db, messageId: "pending-control", folderId: "acc1:Archive",
            folderPath: "Archive", isInInbox: false)
        let settledControl = try TestDatabase.insertMessageHeader(
            db, messageId: "settled-control", folderId: "acc1:Archive",
            folderPath: "Archive", isInInbox: false)
        try db.write { conn in
            try conn.execute(sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                             arguments: [stagedSettled.id])
            try conn.execute(sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                             arguments: [pendingControl.id])
            try conn.execute(sql: "UPDATE messageHeader SET headerComplete = 1, bodyComplete = 1 WHERE id = ?",
                             arguments: [settledControl.id])
        }

        let pending = try db.read { conn in
            try MessageHeader.pendingBodyRequest(accountId: "acc1").fetchAll(conn).map(\.id)
        }
        let settled = try db.read { conn in
            try MessageHeader.bodySettledRequest(accountId: "acc1").fetchAll(conn).map(\.id)
        }

        // PENDING keeps the conjunct: a row whose header has not landed is outside the body
        // question entirely, and counting it holds the sync banner open forever.
        #expect(!pending.contains(staged.id),
                "a staged (headerComplete = 0) row must NOT be pending — it would make BackfillProgress.isFullyComplete unreachable and hold Fast Sync's wake lock open")
        #expect(pending.contains(pendingControl.id),
                "control: an otherwise identical header-complete row IS pending, so the assertion above is not satisfied by an empty result")

        // SETTLED deliberately omits it: dropping staged-but-settled rows from the numerator
        // while the denominator still counts them parks "N / M indexed" below M forever.
        #expect(settled.contains(stagedSettled.id),
                "a staged row whose body DID land must still count as settled — adding headerComplete here would strand the indexed numerator below its denominator")
        #expect(settled.contains(settledControl.id),
                "control: the header-complete twin is settled too, so the assertion above is about the conjunct and not about bodyComplete")
        #expect(!settled.contains(staged.id),
                "a row with no settled disposition is not settled, whatever its headerComplete value")
    }

    @Test("pendingBodyCount excludes a flagged row, so an unfetchable body cannot hold sync open forever")
    func pendingBodyCountExcludesFlaggedRows() throws {
        let db = try TestDatabase.make()
        _ = try seed(db)

        // THE PRODUCTION REQUEST ITSELF, not a hand-copied replica — a replica of a
        // predicate cannot go red when the predicate changes, which is exactly how a
        // test blesses the regression it was written to prevent.
        let pending = try db.read { conn in
            try MessageHeader.pendingBodyRequest(accountId: "acc1").fetchCount(conn)
        }
        #expect(pending == 0,
                "a flagged row must NOT count as pending — otherwise pendingBodyCount never reaches 0 and the banner never clears")

        // Non-vacuity, from the other side: the SAME row without the flag IS pending, so
        // the zero above comes from the conjunct and not from an empty fixture.
        try db.write { conn in
            try conn.execute(sql: "UPDATE messageHeader SET bodyMetadataOversized = 0")
        }
        let pendingUnflagged = try db.read { conn in
            try MessageHeader.pendingBodyRequest(accountId: "acc1").fetchCount(conn)
        }
        #expect(pendingUnflagged == 1,
                "control: an identical unflagged row is still pending, so the fixture is real")
    }

    /// Companion to the above: the row must ALSO be counted as resolved by the
    /// `indexed` numerator, or the progress bar reads "9,999 / 10,000 indexed (99%)"
    /// beside a green completion check — the same nag in a different widget.
    @Test("A flagged row counts as resolved in the indexed numerator, so the bar and the check agree")
    func indexedNumeratorCountsFlaggedRows() throws {
        let db = try TestDatabase.make()
        _ = try seed(db)

        // Again the production request, for the same reason.
        let indexed = try db.read { conn in
            try MessageHeader.bodySettledRequest(accountId: "acc1").fetchCount(conn)
        }
        let total = try db.read { conn in
            try MessageHeader.filter(Column("accountId") == "acc1").fetchCount(conn)
        }
        #expect(indexed == total,
                "indexed must reach total once the only outstanding row is unfetchable")
    }

    /// 🚨 THE PARTITION PROPERTY, over the WHOLE truth table rather than the one row the
    /// two tests above happen to seed.
    ///
    /// `pendingBodyCount` and the "N / M indexed" readout are the same question asked
    /// from opposite sides, and the stop-gap added a THIRD settled disposition to a pair
    /// that previously had two. If a disposition is settled on one side and still pending
    /// on the other, the progress bar parks below 100% beside a green completion check;
    /// if it lands on both, the numerator can exceed the denominator. Neither is visible
    /// from a single-row fixture — only from every combination at once.
    ///
    /// Scoped to header-complete rows on purpose: a row whose HEADER has not landed is
    /// outside the body question entirely, and `pendingBodyRequest` says so with its
    /// `headerComplete` conjunct.
    @Test("Pending and settled partition every header-complete row — disjoint and exhaustive across the whole disposition table")
    func pendingAndSettledPartitionEveryHeaderCompleteRow() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        // A SECOND ACCOUNT, and it is what makes `Column("accountId") == accountId` mean
        // anything here. Every fixture in this suite seeded one account, so that conjunct
        // was satisfied vacuously and could be DELETED from either request with the whole
        // suite green. On a multi-account device that deletion makes
        // `updateBackfillProgressForAccount` compute `totalEmails` account-scoped while the
        // numerator and pending count absorb every account's rows: `ftsIndexed` exceeds its
        // denominator, and no account ever reaches `isFullyComplete` while any OTHER account
        // has an outstanding body — the exact failure this change exists to remove, now
        // global. Two rows, one shaped pending and one shaped settled, so dropping the
        // conjunct from EITHER request pulls a foreign row into that request's result.
        // (Found by audit — the same vacuity the durable clear's scoping test closes.)
        try TestDatabase.insertAccount(db, id: "acc2", email: "second@example.com")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc2")
        var foreignIds: [String] = []
        for (n, (complete, empty, oversized)) in [(false, false, false), (true, false, false)].enumerated() {
            let h = try TestDatabase.insertMessageHeader(
                db, messageId: "foreign-\(n)", folderId: "acc2:Archive",
                accountId: "acc2", folderPath: "Archive", isInInbox: false)
            try db.write { conn in
                try conn.execute(sql: """
                    UPDATE messageHeader
                    SET headerComplete = 1, bodyComplete = ?, bodyEmptyConfirmed = ?, bodyMetadataOversized = ?
                    WHERE id = ?
                    """, arguments: [complete, empty, oversized, h.id])
            }
            foreignIds.append(h.id)
        }

        // All 8 combinations of the three dispositions, each on its own row.
        var ids: [String] = []
        for (n, (complete, empty, oversized)) in [
            (false, false, false), (true, false, false), (false, true, false), (false, false, true),
            (true, true, false), (true, false, true), (false, true, true), (true, true, true),
        ].enumerated() {
            let h = try TestDatabase.insertMessageHeader(
                db, messageId: "\(n)", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false)
            try db.write { conn in
                try conn.execute(sql: """
                    UPDATE messageHeader
                    SET headerComplete = 1, bodyComplete = ?, bodyEmptyConfirmed = ?, bodyMetadataOversized = ?
                    WHERE id = ?
                    """, arguments: [complete, empty, oversized, h.id])
            }
            ids.append(h.id)
        }
        #expect(ids.count == 8, "precondition — one row per disposition combination")

        let pending = try db.read { conn in
            try MessageHeader.pendingBodyRequest(accountId: "acc1").fetchAll(conn).map(\.id)
        }
        let settled = try db.read { conn in
            try MessageHeader.bodySettledRequest(accountId: "acc1").fetchAll(conn).map(\.id)
        }

        #expect(Set(pending).isDisjoint(with: Set(settled)),
                "no row may be both outstanding and resolved — that makes the indexed numerator exceed its denominator; overlap was \(Set(pending).intersection(Set(settled)))")
        #expect(Set(pending).union(Set(settled)) == Set(ids),
                "and none may be neither — an uncounted row parks the bar below 100% forever; missing was \(Set(ids).subtracting(Set(pending).union(Set(settled))))")
        // Non-vacuity: the split is real, not "everything landed on one side".
        #expect(pending.count == 1, "exactly one combination — all three dispositions false — is outstanding")
        #expect(settled.count == 7, "and the other seven are settled")
        // ACCOUNT SCOPE, stated as the property the arithmetic depends on rather than as a
        // restatement of the request's text: neither request may see a row belonging to
        // another account, in EITHER direction. Both foreign rows are header-complete, so
        // nothing else in this fixture excludes them.
        #expect(Set(pending).isDisjoint(with: Set(foreignIds)),
                "a second account's outstanding row must not count as THIS account's pending work")
        #expect(Set(settled).isDisjoint(with: Set(foreignIds)),
                "…nor its settled row as this account's indexed numerator")
    }

    /// `selfHealBackfillFTSMembership` re-indexes HEADERS. The flagged row's header is
    /// perfectly healthy — only its body is missing — so excluding it would silently
    /// drop a good message out of subject and sender search.
    @Test("The FTS membership self-heal still sees a flagged row, so it stays searchable by subject and sender")
    func ftsSelfHealStillSeesFlaggedRows() throws {
        let db = try TestDatabase.make()
        _ = try seed(db)

        // THE PRODUCTION SCOPE ITSELF. Transcribing it here would make this test
        // permanently green: a copy cannot notice when production adds the conjunct,
        // which is the single regression this test exists to catch.
        let candidates = try db.read { conn in
            try String.fetchAll(conn, sql: SyncEngine.backfillFTSSelfHealCandidateSQL)
        }
        #expect(candidates.count == 1,
                "the self-heal scope must NOT carry the oversized conjunct — the header is healthy and must stay indexed")
        #expect(!SyncEngine.backfillFTSSelfHealCandidateSQL.contains("bodyMetadataOversized"),
                "and it must not mention the flag at all — a future re-merge of the two predicates is the failure this pins")
    }

    // `flaggingNeverRetiresTheRow` lived here and was DELETED as vacuous: its fixture set
    // the flag with a direct `UPDATE`, so it only ever asserted that a statement which
    // touches one column leaves the others alone. The real claim — that the PRODUCTION
    // mark (`markOversizedDurably`) retires nothing — is asserted against both queues in
    // `OversizedBodyQuarantineDatabaseTests.activeOversizedNeverMarksRowFetched` and
    // `.backfillOversizedNeverMarksRowFetched`, where the flag is set by the code
    // under test.

    /// NEGATIVE CONTROL for the half-port. Smart Reindex's statement needs the flag in
    /// BOTH halves: a flagged row has `bodyEmptyConfirmed = 0`, so the ORIGINAL `WHERE`
    /// does not select it, and adding the column to the `SET` alone is completely inert
    /// against exactly the rows the user invoked the gesture for. This pins that the
    /// half-port is inert; the positive side — that the REAL
    /// `SyncEngine.resetCrawlState()` releases the quarantine — is asserted against the
    /// production method in `OversizedBodyQuarantineDatabaseTests
    /// .smartReindexReleasesTheQuarantineThroughTheRealMethod`, because a second
    /// hand-copied replica here could not go red if production's statement regressed.
    @Test("NEGATIVE CONTROL: a SET-only Smart Reindex statement is inert against a flagged row")
    func setOnlySmartReindexStatementIsInert() throws {
        let db = try TestDatabase.make()
        let id = try seed(db)

        try db.write { conn in
            try conn.execute(sql: """
                UPDATE messageHeader
                SET bodyEmptyConfirmed = 0, emptyFetchCount = 0, bodyComplete = 0,
                    bodyMetadataOversized = 0
                WHERE bodyEmptyConfirmed = 1
                """)
        }
        let stored = try #require(try db.read { try MessageHeader.fetchOne($0, key: id) })
        #expect(stored.bodyMetadataOversized,
                "SET without WHERE is INERT — this is the half-port that would ship silently")
    }
}
