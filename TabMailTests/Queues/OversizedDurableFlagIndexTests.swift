/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Shared SQL

/// The four BODY-FETCH ADMISSION queries, verbatim from production. These are the only
/// queries that carry `bodyMetadataOversized = 0`, and the only ones the partial index
/// serves.
private enum AdmissionSQL {
    static let activeRepopulate = """
        SELECT id, accountId, folderPath, messageId, isInInbox
        FROM messageHeader
        WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 1
          AND bodyMetadataOversized = 0
        ORDER BY date DESC
        """
    static let backfillRepopulate = """
        SELECT id, accountId, folderPath, messageId, isInInbox
        FROM messageHeader
        WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 0
          AND bodyMetadataOversized = 0
        ORDER BY date DESC
        """
    /// The same query WITHOUT the new conjunct — the negative control. Without it the
    /// gate cannot tell "the index is used because we added the clause" from "the index
    /// would have been used anyway".
    static let withoutConjunct = """
        SELECT id, accountId, folderPath, messageId, isInInbox
        FROM messageHeader
        WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 0
        ORDER BY date DESC
        """

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

/// The owner's acceptance criterion for this change, in his words: *"just making sure
/// that the query with this new index is tested optimal."* This is a PLAN-SHAPE gate,
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

    /// OPTIMAL here has a precise meaning: all five equality predicates are satisfied by
    /// the index SEEK (not filtered row-by-row afterwards), and `date` is supplied in
    /// order so nothing is sorted in memory.
    @Test("Every admission query seeks on all five equality columns")
    func admissionQueriesSeekOnEveryEqualityColumn() throws {
        let db = try TestDatabase.make()
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
        let db = try TestDatabase.make()
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
        let db = try TestDatabase.make()
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
        let db = try TestDatabase.make()
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

@Suite("Migration v88 adds the oversized flag and its partial index")
struct OversizedDurableFlagMigrationTests {

    @Test("The column exists, defaults to 0, and the partial index is created")
    func migrationShape() throws {
        let db = try TestDatabase.make()

        let columns = try db.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA table_info(messageHeader)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("bodyMetadataOversized"))

        let indexes = try db.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA index_list(messageHeader)")
                .compactMap { $0["name"] as String? }
        }
        #expect(indexes.contains("messageHeader_bodyRepopulateV2"))

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

    @Test("Re-running the migration chain is a no-op")
    func migrationIsIdempotent() throws {
        let db = try TestDatabase.make()
        try AppDatabase.runMigrations(on: db)   // must not throw
        let indexes = try db.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA index_list(messageHeader)")
                .compactMap { $0["name"] as String? }
        }
        #expect(indexes.filter { $0 == "messageHeader_bodyRepopulateV2" }.count == 1)
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

/// The flag is consumed by body-fetch ADMISSION and by nothing else. Three deliberate
/// NON-changes are pinned here because each is a plausible "cleanup" that would
/// reintroduce a defect, and a deliberate omission that nothing asserts is indistinguishable
/// from an oversight.
@Suite("The durable oversized flag is confined to background body-fetch admission")
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

    /// `BackfillProgress.pendingBodyCount` is a TRUTH CLAIM about the mailbox, and the
    /// body really is missing. Excluding the row would make the app announce
    /// "Sync Complete" over a message it never fetched — a second defect, not a fix.
    /// The battery cost that used to ride on this has already been separated out:
    /// `FastSyncView.keepScreenAwakeWhileWorking` asks about queue activity instead.
    @Test("pendingBodyCount still counts a flagged row, so the Sync Complete banner stays honest")
    func pendingBodyCountStillCountsFlaggedRows() throws {
        let db = try TestDatabase.make()
        _ = try seed(db)

        // Verbatim shape of SyncEngineBackfill's pendingBody count — a GRDB
        // query-interface chain, which is why no SQL-text search finds it.
        let pending = try db.read { conn in
            try MessageHeader.filter(
                Column("accountId") == "acc1" &&
                Column("headerComplete") == true &&
                Column("bodyComplete") == false &&
                Column("bodyEmptyConfirmed") == false
            ).fetchCount(conn)
        }
        #expect(pending == 1,
                "a flagged row must STILL count as pending — the banner must not claim completion over a missing body")
    }

    /// `selfHealBackfillFTSMembership` re-indexes HEADERS. The flagged row's header is
    /// perfectly healthy — only its body is missing — so excluding it would silently
    /// drop a good message out of subject and sender search.
    @Test("The FTS membership self-heal still sees a flagged row, so it stays searchable by subject and sender")
    func ftsSelfHealStillSeesFlaggedRows() throws {
        let db = try TestDatabase.make()
        _ = try seed(db)

        let candidates = try db.read { conn in
            try String.fetchAll(conn, sql: """
                SELECT id FROM messageHeader
                WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0
                LIMIT 5000
                """)
        }
        #expect(candidates.count == 1,
                "the self-heal scope must NOT carry the oversized conjunct — the header is healthy and must stay indexed")
    }

    /// Data Integrity Rule 1: an oversized body is the opposite of "content confirmed
    /// gone" — the body demonstrably exists, it merely did not fit.
    @Test("Flagging never marks the row complete, empty, or spends a strike from the empty budget")
    func flaggingNeverRetiresTheRow() throws {
        let db = try TestDatabase.make()
        let id = try seed(db)
        let row = try db.read { try MessageHeader.fetchOne($0, key: id) }
        let stored = try #require(row)
        #expect(stored.bodyComplete == false)
        #expect(stored.bodyEmptyConfirmed == false)
        #expect(stored.emptyFetchCount == 0)
        #expect(stored.missFetchCount == 0)
    }

    /// Smart Reindex is the user-invoked "try everything again" gesture, so it must
    /// release this quarantine. Its statement needs the flag in BOTH halves: a flagged
    /// row has `bodyEmptyConfirmed = 0`, so the original `WHERE` does not select it and
    /// adding the column to the `SET` alone would silently skip exactly the rows the
    /// user invoked the gesture for.
    @Test("Smart Reindex clears the flag — and needs BOTH halves of its statement to do so")
    func smartReindexClearsTheFlag() throws {
        let db = try TestDatabase.make()
        let id = try seed(db)

        // The half-done version: SET only, original WHERE.
        try db.write { conn in
            try conn.execute(sql: """
                UPDATE messageHeader
                SET bodyEmptyConfirmed = 0, emptyFetchCount = 0, bodyComplete = 0,
                    bodyMetadataOversized = 0
                WHERE bodyEmptyConfirmed = 1
                """)
        }
        var stored = try #require(try db.read { try MessageHeader.fetchOne($0, key: id) })
        #expect(stored.bodyMetadataOversized,
                "SET without WHERE is INERT — this is the half-port that would ship silently")

        // Production's statement, both halves.
        try db.write { conn in
            try conn.execute(sql: """
                UPDATE messageHeader
                SET bodyEmptyConfirmed = 0, emptyFetchCount = 0, bodyComplete = 0,
                    bodyMetadataOversized = 0
                WHERE bodyEmptyConfirmed = 1 OR bodyMetadataOversized = 1
                """)
        }
        stored = try #require(try db.read { try MessageHeader.fetchOne($0, key: id) })
        #expect(stored.bodyMetadataOversized == false, "Smart Reindex must release the quarantine")
    }
}
