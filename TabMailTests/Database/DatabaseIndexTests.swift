/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database Index Verification")
struct DatabaseIndexTests {

    @Test("Composite indexes exist for common queries")
    func compositeIndexesExist() throws {
        let db = try TestDatabase.make()
        let indexes = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index'")
                .map { $0["name"] as String }
        }
        // The DB should have indexes for the most common query patterns
        // Exact index names may vary, but we verify the query doesn't full-scan
        #expect(!indexes.isEmpty)
        // v64: BOTH messageId composites are REQUIRED — without them the on-device
        // planner folder/account-scans the per-message lookups on huge folders/accounts
        // (Gmail All Mail: ~94ms/lookup, boot_logs 7).
        #expect(indexes.contains("messageHeader_folderId_messageId"),
                "v64 (folderId, messageId) composite missing — folderId+messageId lookups will folder-scan")
        #expect(indexes.contains("messageHeader_accountId_messageId"),
                "v64 (accountId, messageId) composite missing — accountId+messageId lookups (NSE merge / AppDelegate) will account-scan")
        #expect(indexes.contains("messageHeader_rfc822MessageId"),
                "v1 RFC index missing — live INDEXED BY identity lookups will throw")
        // v64 drops the now-redundant single-column accountId index (the composite's
        // leading column serves accountId-only queries).
        #expect(!indexes.contains("messageHeader_accountId"),
                "messageHeader_accountId should be dropped by v64 (superseded by the accountId,messageId composite)")
        // v66: expression index for the IMAP UID-window stale slice.
        #expect(indexes.contains("messageHeader_folderId_uidInt"),
                "v66 (folderId, CAST(messageId AS INTEGER)) expression index missing — the stale slice will folder-scan")
    }

    @Test("UID-window stale slice seeks via the CAST expression index, not a folder scan")
    func uidWindowUsesExpressionIndex() throws {
        // SyncEngineFullSync :737 — WHERE folderId=? AND CAST(messageId AS INTEGER) >= ?.
        // v66 adds an expression index on (folderId, CAST(messageId AS INTEGER)). INDEXED BY
        // forces it: SQLite errors ("no query solution") if it can't serve the query, so a
        // USING-INDEX plan proves seekability independent of table size (a plain EXPLAIN
        // would SCAN this tiny test table regardless).
        let db = try TestDatabase.make()
        let plan: String = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM messageHeader INDEXED BY messageHeader_folderId_uidInt
                WHERE folderId = 'acc1:INBOX' AND CAST(messageId AS INTEGER) >= 100
                """).map { $0["detail"] as String }.joined(separator: " | ")
        }
        #expect(plan.contains("USING INDEX messageHeader_folderId_uidInt"),
                "the CAST-range stale slice must seek via the v66 expression index: \(plan)")
    }

    /// 🚨 v83 — `InboxViewModel.markAllAsRead`'s three statements must each seek via
    /// `messageHeader_unreadSweep` AND sort from the index, never through a temp
    /// B-tree.
    ///
    /// **This asserts the INVARIANT the regression violated, not the index's
    /// existence.** The defect was never "an index is missing" — it was that every
    /// pre-existing candidate orders by `date` while all three statements order by
    /// `id`, so SQLite satisfied the WHERE from an index and then SORTED the whole
    /// remaining unread set once per 50-row page. Measured on a production-shaped
    /// 360k-row database carrying the statistics a shipped device actually has
    /// (`sqlite_stat1` says `messageHeader` is empty, because in every shipped build
    /// `ANALYZE` ran only inside migration bodies and a fresh install runs them
    /// against an empty table — the ADR-IOS-029 2026-08-05 amendment adds a
    /// background refresh, which makes the stale regime recoverable but does not
    /// change what this test pins):
    /// 100,000 unread swept in **199,425 ms** without this index and **6,300 ms**
    /// with it. So `USE TEMP B-TREE FOR ORDER BY` is the thing that must stay absent,
    /// and it is what these expectations pin.
    ///
    /// `INDEXED BY` is NOT used here, deliberately — the point is that the planner
    /// CHOOSES this index for these predicates. Forcing it would prove only that the
    /// index is capable, which is the weaker claim and would stay green on the exact
    /// regression (the planner preferring a `date`-ordered index) this pins.
    /// The test database is tiny, so the sort-elimination assertion carries the
    /// weight; a `SCAN`-vs-`SEARCH` assertion alone would be size-dependent.
    ///
    /// ⚠️ THE INDEX NO LONGER EXISTS AFTER MIGRATION — it is built by the background
    /// maintenance pass (2026-08-06), so this test runs the PRODUCTION DDL via
    /// `SyncEngine.createDeferredIndexes` first. It is called rather than re-typed on
    /// purpose: a re-typed `CREATE INDEX` would let this test keep passing against a
    /// statement the app no longer runs.
    @Test("markAllAsRead's three statements sort from the v83 index, never a temp B-tree")
    func markAllAsReadSweepUsesUnreadSweepIndex() throws {
        let db = try TestDatabase.make()
        try db.write { try SyncEngine.createDeferredIndexes($0) }

        // Verbatim from `InboxViewModel.markAllAsRead` — the frozen upper-bound
        // probe, the first page, and the cursor page.
        let upperBoundProbe = """
            SELECT id FROM messageHeader
            WHERE folderId = 'acc1:INBOX' AND isRead = 0
            ORDER BY id COLLATE BINARY DESC
            LIMIT 1
            """
        let firstPage = """
            SELECT * FROM messageHeader
            WHERE folderId = 'acc1:INBOX' AND isRead = 0
              AND id COLLATE BINARY <= 'zzz' COLLATE BINARY
            ORDER BY id COLLATE BINARY ASC
            LIMIT 50
            """
        let cursorPage = """
            SELECT * FROM messageHeader
            WHERE folderId = 'acc1:INBOX' AND isRead = 0
              AND id COLLATE BINARY > 'aaa' COLLATE BINARY
              AND id COLLATE BINARY <= 'zzz' COLLATE BINARY
            ORDER BY id COLLATE BINARY ASC
            LIMIT 50
            """

        for (label, sql) in [("upper-bound probe", upperBoundProbe),
                             ("first page", firstPage),
                             ("cursor page", cursorPage)] {
            let plan: String = try db.read { dbConn in
                try Row.fetchAll(dbConn, sql: "EXPLAIN QUERY PLAN \(sql)")
                    .map { $0["detail"] as String }
                    .joined(separator: " | ")
            }
            #expect(plan.contains("messageHeader_unreadSweep"),
                    "\(label): planner did not choose the v83 partial index: \(plan)")
            #expect(!plan.contains("TEMP B-TREE"),
                    "\(label): sort not eliminated — this is the O(U²/50) regression: \(plan)")
        }
    }

    /// Two-sided control for the test above (MIS-026): the assertions must be capable
    /// of failing. The same sweep shape ordered by `date` instead of `id` — which is
    /// what every OTHER `messageHeader` index supports — must NOT choose
    /// `messageHeader_unreadSweep`. If this ever starts matching, the test above has
    /// stopped discriminating and is passing for the wrong reason.
    @Test("The v83 index is not chosen for the date-ordered inbox display query")
    func unreadSweepIndexIsNotChosenForDateOrderedReads() throws {
        let db = try TestDatabase.make()
        // Build it, so "not chosen" means the planner REJECTED an index that was
        // available — not that it was absent and could not have been chosen. Without
        // this line the control passes vacuously.
        try db.write { try SyncEngine.createDeferredIndexes($0) }
        let plan: String = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM messageHeader
                WHERE folderId = 'acc1:INBOX' AND isRead = 0
                ORDER BY date DESC
                LIMIT 50
                """).map { $0["detail"] as String }.joined(separator: " | ")
        }
        #expect(!plan.contains("messageHeader_unreadSweep"),
                "date-ordered display must not be served by the id-ordered v83 index: \(plan)")
    }

    @Test("Canonicalize upsert lookup (messageId + folderId) uses an index, not a scan")
    func canonicalizeLookupUsesIndex() throws {
        // canonicalizeLocalRows runs once per remote message in every folder
        // sync — it MUST seek via messageHeader_messageId_accountId (v40),
        // never scan (ADR-IOS-029).
        let db = try TestDatabase.make()
        let details: [String] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM messageHeader WHERE messageId = 'x' AND folderId = 'acc1:INBOX'
                """).map { row in row["detail"] as String }
        }
        let plan = details.joined(separator: " | ")
        #expect(plan.contains("USING INDEX"), "expected index seek, got: \(plan)")
        #expect(!plan.contains("SCAN messageHeader"), "full scan on hot upsert path: \(plan)")
        // KEY assertion (boot_logs 7): the seek must key on messageId. A plan that keys
        // on folderId alone and post-filters messageId is a covering-index FOLDER SCAN —
        // "USING INDEX / not SCAN" passes, yet it's ~94ms/lookup on Gmail All Mail. The
        // v64 (folderId, messageId) composite makes it a direct 2-column seek.
        #expect(plan.contains("messageId=?"),
                "lookup must SEEK on messageId, not folder-scan-and-filter it: \(plan)")
    }

    @Test("Account-scoped lookup (accountId + messageId) seeks on messageId, not account-scans")
    func accountLookupUsesIndex() throws {
        // NSE merge (:801/1024/1560/2364) + AppDelegate (:143) + Search/Undo look up by
        // (accountId, messageId) — searching by ACCOUNT to catch UID-remapped moves.
        // Same covering-scan trap as the folderId path (boot_logs 7): the seek must key
        // on messageId, else it account-scans (Gmail account = thousands of rows). The
        // v64 (accountId, messageId) composite makes it a direct 2-column seek.
        let db = try TestDatabase.make()
        let details: [String] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM messageHeader WHERE accountId = 'acc1' AND messageId = 'x'
                """).map { row in row["detail"] as String }
        }
        let plan = details.joined(separator: " | ")
        #expect(plan.contains("USING INDEX"), "expected index seek, got: \(plan)")
        #expect(!plan.contains("SCAN messageHeader"), "full scan on hot merge path: \(plan)")
        #expect(plan.contains("messageId=?"),
                "lookup must SEEK on messageId, not account-scan-and-filter it: \(plan)")
    }

    @Test("Query by folderId + isRead uses index effectively")
    func queryByFolderIdAndIsRead() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert many messages
        for i in 0..<50 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", isRead: i % 2 == 0)
        }

        // This query pattern should be efficient due to indexes
        let unreadCount = try db.read {
            try MessageHeader.filter(
                Column("folderId") == "acc1:INBOX" && Column("isRead") == false
            ).fetchCount($0)
        }
        #expect(unreadCount == 25)
    }

    @Test("Query messages by accountId is efficient")
    func queryByAccountId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "a1", email: "a@b.com", provider: .gmail)
        try TestDatabase.insertAccount(db, id: "a2", email: "c@d.com", provider: .imap)
        try TestDatabase.insertFolder(db, accountId: "a1")
        try TestDatabase.insertFolder(db, accountId: "a2")

        for i in 0..<10 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", folderId: "a1:INBOX", accountId: "a1")
        }
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", folderId: "a2:INBOX", accountId: "a2")
        }

        let a1Count = try db.read {
            try MessageHeader.filter(Column("accountId") == "a1").fetchCount($0)
        }
        let a2Count = try db.read {
            try MessageHeader.filter(Column("accountId") == "a2").fetchCount($0)
        }
        #expect(a1Count == 10)
        #expect(a2Count == 5)

        // DROP SAFETY (v64 removed the single-column messageHeader_accountId): prove the
        // (accountId, messageId) composite's LEADING column can still serve an
        // account-only `WHERE accountId=?` query. `INDEXED BY` FORCES the index — SQLite
        // raises "no query solution" (→ this read throws → test fails) if the index
        // can't satisfy the predicate. This is table-size-INDEPENDENT: a plain EXPLAIN
        // would SCAN on this 15-row table regardless (accountId matches most rows, so a
        // scan is genuinely cheaper there), which is exactly why a naive plan assertion
        // would false-fail. A successful USING-INDEX plan here proves seekability on a
        // real (large) device table.
        let forcedPlan = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM messageHeader INDEXED BY messageHeader_accountId_messageId
                WHERE accountId = 'a1'
                """).map { $0["detail"] as String }.joined(separator: " | ")
        }
        #expect(forcedPlan.contains("USING INDEX messageHeader_accountId_messageId"),
                "the composite's leading accountId column must serve account-only queries (drop safety): \(forcedPlan)")
    }

    // MARK: - R13-U12 — the two plans this range regressed

    /// `EXPLAIN QUERY PLAN` for `sql`, as one line. SQLite still binds
    /// placeholders when explaining, so every `?` gets a throwaway value; the
    /// plan does not depend on them (no partial indexes are involved here).
    private func plan(_ db: DatabaseQueue, _ sql: String) throws -> String {
        let arguments = StatementArguments(Array(repeating: "x", count: sql.filter { $0 == "?" }.count))
        return try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
                .map { $0["detail"] as String }
                .joined(separator: " | ")
        }
    }

    /// 🚨 R13-U6 — INVARIANT: **the triage first page never sorts the whole
    /// folder.** Not "it uses index X" — the mechanism is a hint and a hint is
    /// replaceable; what must stay true is that the `ORDER BY` is satisfied
    /// from an index prefix and only a bounded block is sorted. `USE TEMP
    /// B-TREE FOR ORDER BY` (no `LAST n TERMS`) is SQLite saying it sorted
    /// everything the WHERE admitted, which for a triage inbox is the folder.
    ///
    /// Asserted against `InboxListReader.durableQuerySQL` — production's own
    /// statement builder, not a copy — so a change to the predicate, the
    /// `ORDER BY` or the hint is seen here (`MessageContentStore.ownersSQL`
    /// precedent).
    ///
    /// The empty schema is enough: the regression reproduces in EVERY
    /// statistics regime, which is the finding. Measured at 100k rows the same
    /// two plans cost 18.28 ms and 1.91 ms.
    @Test("R13-U6 — the triage first page satisfies its ORDER BY from an index, never by sorting the folder")
    func triageFirstPageDoesNotSortTheWholeFolder() throws {
        let db = try TestDatabase.make()
        let query = InboxListQuery(
            displayedFolderIds: ["acc1:INBOX"], filterUnread: false, filterLabelIds: [],
            mode: .triage, targetCount: 50, before: nil)
        let production = InboxListReader.durableQuerySQL(folderId: "acc1:INBOX", query: query).sql

        let p = try plan(db, production)
        #expect(!p.contains("USE TEMP B-TREE FOR ORDER BY"),
                "the triage first page sorted the whole folder — an 8× regression on a @MainActor blocking read that runs once per displayed folder on every paint and every scroll page: \(p)")
        #expect(p.contains("SEARCH"), "the triage first page must seek, not scan: \(p)")

        // TWO-SIDED (MIS-030). Without the hint — the exact pre-fix statement —
        // SQLite abandons the triage index and sorts everything. Without this,
        // the assertion above is satisfiable by a planner that never sorts at
        // all and pins nothing.
        let preFix = production.replacingOccurrences(
            of: " INDEXED BY messageHeader_triage_display", with: "")
        #expect(preFix != production, "the production statement no longer carries the hint this test exists to pin")
        let pre = try plan(db, preFix)
        #expect(pre.contains("USE TEMP B-TREE FOR ORDER BY"),
                "the un-hinted form must still exhibit the regression, or the assertion above proves nothing: \(pre)")
    }

    /// 🚨 R13-U6, THE HELD SIDE — the hint is deliberately absent when the
    /// unread filter is on, and that absence is load-bearing, not an
    /// oversight. `messageHeader_folderId_isRead`'s selectivity is the whole
    /// point of that mode; measured on a 100k folder with three unread rows,
    /// forcing the triage index costs **18.891 ms vs 0.022 ms**. Adding the
    /// hint there would be the mirror image of the defect (`MIS-005`), so this
    /// test fails if someone "completes" the fix by applying it uniformly.
    @Test("R13-U6 — the unread-filtered triage page keeps the planner's selective index, hint withheld on purpose")
    func unreadFilteredTriagePageIsNotForcedOntoTheTriageIndex() throws {
        let db = try TestDatabase.make()
        let query = InboxListQuery(
            displayedFolderIds: ["acc1:INBOX"], filterUnread: true, filterLabelIds: [],
            mode: .triage, targetCount: 50, before: nil)
        let production = InboxListReader.durableQuerySQL(folderId: "acc1:INBOX", query: query).sql
        #expect(!production.contains("INDEXED BY"),
                "forcing an index here removes the unread predicate's selectivity: 0.022 ms → 18.891 ms on a 100k folder with three unread rows")
        let p = try plan(db, production)
        #expect(p.contains("isRead=?"),
                "the unread predicate must still be the seek, not a residual filter: \(p)")
    }

    /// 🚨 R13-U11 — INVARIANT: **the chat stable-id resolve seeks the RFC id,
    /// it does not walk the account.** The `accountId` scope added by this
    /// range is correct and stays; what regressed is that with no stat row for
    /// a full index — the ordinary state of a fresh install — SQLite preferred
    /// `messageHeader_accountId_messageId (accountId=?)`. Measured at 90k rows
    /// in the account: 13.161 ms vs 0.013 ms.
    ///
    /// Reachable stats-poor: `evictMessageDetailSessionsImpl` loops every
    /// `msg:%` session inside `dbPool.write`, and `runWALMaintenance` runs chat
    /// eviction BEFORE its one-shot whole-DB `ANALYZE`.
    @Test("R13-U11 — findByStableId seeks rfc822MessageId, it does not walk the account")
    func findByStableIdSeeksTheRfcIdNotTheAccount() throws {
        let db = try TestDatabase.make()
        let p = try plan(db, ChatStore.findByStableIdSQL)
        #expect(p.contains("rfc822MessageId=?"),
                "the resolve must seek the RFC id: \(p)")
        #expect(!p.contains("messageHeader_accountId_messageId"),
                "the resolve walked the account instead of seeking the RFC id: \(p)")

        // TWO-SIDED (MIS-030): the pre-fix query-interface form, verbatim.
        let pre = try plan(db, """
            SELECT * FROM "messageHeader"
            WHERE ("accountId" = ?) AND ("rfc822MessageId" = ?)
            ORDER BY "isInInbox" DESC, "id" ASC LIMIT 1
            """)
        #expect(pre.contains("messageHeader_accountId_messageId"),
                "the un-hinted form must still exhibit the regression, or the assertions above prove nothing: \(pre)")
    }

    /// IOS-PERF-012 — both hot durable-identity lookups must seek the stable RFC
    /// id even in the statistics-poor state left by the production migration
    /// chain. A wall-clock threshold would be device-dependent; the account walk
    /// is the invariant that caused the measured 15–26 ms tail.
    @Test("IOS-PERF-012 — durable identity lookups seek the RFC id with stale and fresh statistics")
    func durableIdentityLookupsSeekRfcIdAcrossStatisticsRegimes() throws {
        let db = try TestDatabase.make()
        #expect(try Self.fullIndexStatRows(db).isEmpty,
                "the stale-plan witness requires migration-left statistics with no stat row for any FULL index on messageHeader")
        // (label, production SQL, the low-selectivity index the UNHINTED form takes
        // in this regime). The measured competing index differs by query scope.
        let productionStatements: [(String, String, String)] = [
            ("durable fallback", DurableIdentityLookup.rfc822FallbackSQL,
             "messageHeader_accountId_messageId"),
            ("moved-inbox AI target", AccountManager.inboxEntryAITargetSQL,
             "messageHeader_accountId_messageId"),
            ("optimistic dedup", SyncEngine.optimisticDedupSQL,
             "messageHeader_folderId_uidInt"),
            ("reply parent lookup", ReplyParentResolver.parentLookupSQL(count: 3),
             "messageHeader_accountId_messageId"),
            ("reply target lookup", Draft.replyTargetLookupSQL,
             "messageHeader_accountId_messageId"),
            ("agent-toast stable-id lookup", InboxView.stableIdRfcLookupSQL,
             "messageHeader_accountId_messageId"),
            ("optimistic sent existence probe", AccountManager.optimisticSentDedupSQL,
             "messageHeader_folderId_uidInt"),
        ]

        for (label, production, staleIndex) in productionStatements {
            let stalePlan = try plan(db, production)
            #expect(stalePlan.contains("USING INDEX messageHeader_rfc822MessageId"),
                    "\(label) must seek the RFC index with migration-left statistics: \(stalePlan)")
            #expect(stalePlan.contains("rfc822MessageId=?"),
                    "\(label) must seek the RFC value, not merely scan its index: \(stalePlan)")
            #expect(!stalePlan.contains(staleIndex),
                    "\(label) took \(staleIndex) with migration-left statistics: \(stalePlan)")

            // TWO-SIDED (MIS-030): remove exactly the production hint. If this
            // control stops reproducing the account walk, the positive assertion
            // above no longer proves the planner defect or its fix.
            let unhinted = production.replacingOccurrences(
                of: " INDEXED BY messageHeader_rfc822MessageId", with: "")
            #expect(unhinted != production,
                    "\(label) production SQL no longer carries the hint this test pins")
            let unhintedPlan = try plan(db, unhinted)
            #expect(unhintedPlan.contains(staleIndex),
                    "\(label) unhinted control no longer reproduces the stale-statistics \(staleIndex) walk: \(unhintedPlan)")
            #expect(!unhintedPlan.contains("USING INDEX messageHeader_rfc822MessageId"),
                    "\(label) unhinted control already seeks the RFC index, so the hint pins nothing: \(unhintedPlan)")
        }

        // Populate through the shared helper, then refresh real planner statistics
        // rather than hand-building a schema or editing sqlite_stat1. The hint must
        // remain a valid RFC seek after the planner has current cardinalities too.
        try TestDatabase.insertAccount(db, id: "stats-a", email: "a@example.com")
        try TestDatabase.insertAccount(db, id: "stats-b", email: "b@example.com")
        try TestDatabase.insertFolder(db, accountId: "stats-a")
        try TestDatabase.insertFolder(db, accountId: "stats-b")
        for i in 0..<20 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "a-\(i)", folderId: "stats-a:INBOX", accountId: "stats-a",
                rfc822MessageId: "<a-\(i)@example.com>")
            try TestDatabase.insertMessageHeader(
                db, messageId: "b-\(i)", folderId: "stats-b:INBOX", accountId: "stats-b",
                rfc822MessageId: "<b-\(i)@example.com>")
        }
        try db.write { try $0.execute(sql: "ANALYZE") }
        #expect(try !Self.fullIndexStatRows(db).isEmpty,
                "the fresh-statistics half is vacuous unless ANALYZE actually wrote full-index stat rows")

        for (label, production, staleIndex) in productionStatements {
            let freshPlan = try plan(db, production)
            #expect(freshPlan.contains("USING INDEX messageHeader_rfc822MessageId"),
                    "\(label) must keep seeking the RFC index with fresh statistics: \(freshPlan)")
            #expect(freshPlan.contains("rfc822MessageId=?"),
                    "\(label) must keep seeking the RFC value with fresh statistics: \(freshPlan)")
            #expect(!freshPlan.contains(staleIndex),
                    "\(label) took \(staleIndex) with fresh statistics: \(freshPlan)")
        }
    }

    /// The stale-statistics regime is "no stat row for a FULL index", not an
    /// empty sqlite_stat1: ANALYZE on an empty table still records partial indexes.
    private static func fullIndexStatRows(_ db: DatabaseQueue) throws -> [Row] {
        try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT s.idx AS idx FROM sqlite_stat1 s
                JOIN sqlite_master m ON m.name = s.idx AND m.type = 'index'
                WHERE s.tbl = 'messageHeader' AND m.sql NOT LIKE '% WHERE %'
                """)
        }
    }

    @Test("MessageHeader ordered by date DESC for inbox view")
    func messageHeaderOrderByDate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let dates = [
            Date().addingTimeInterval(-3600),
            Date().addingTimeInterval(-7200),
            Date(),
        ]
        for (i, date) in dates.enumerated() {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", date: date)
        }

        let ordered = try db.read {
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX")
                .order(Column("date").desc)
                .fetchAll($0)
        }
        #expect(ordered.count == 3)
        #expect(ordered[0].date >= ordered[1].date)
        #expect(ordered[1].date >= ordered[2].date)
    }
}

/// `v83`'s index build moved out of the blocking migration chain and into the
/// background WAL maintenance pass (2026-08-06; ADR-IOS-029's 2026-08-05 deferred-
/// timing amendment, extended from the `ANALYZE` to the `CREATE INDEX`). On the
/// owner's device the migration cost **5,050 ms** before any UI appeared.
///
/// 🚨 THE PROPERTY PINNED HERE IS CONVERGENCE, NOT THE MOVE. Emptying an
/// already-applied migration's body is normally forbidden (Data Integrity rule 5),
/// and it is admissible ONLY because every population reaches the same schema
/// anyway. So these tests assert, in order: the migration chain alone does NOT
/// produce the index (otherwise the deferral is fiction and every other assertion
/// here is vacuous); the pass DOES; the pass is idempotent; and a second pass over
/// the converged state does nothing.
///
/// `.serialized` because `runRefreshPlannerStatisticsIfStale` carries a
/// process-wide single-flight latch, and the ordering test drives it.
@Suite("Deferred index builds — v83 moved off the launch path", .serialized)
struct DeferredIndexBuildTests {

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
    }

    /// On disk, not in memory: `PrioritizedDatabase` wraps a `DatabasePool`, and a
    /// pool needs a file.
    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        try AppDatabase.runMigrations(on: pool)
        return Fixture(pool: pool, directory: directory)
    }

    private func indexExists(_ pool: DatabasePool, _ name: String) throws -> Bool {
        try pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
                arguments: [name]) != nil
        }
    }

    /// 🚨 NON-VACUITY, and it is the first test on purpose. If the migration chain
    /// still built the index, every "the pass builds it" assertion below would pass
    /// without the pass doing anything at all — and the 5,050 ms would still be on
    /// the launch path. This is the test that fails if somebody "restores" `v83`'s
    /// body, which is exactly the change the migration's comment warns against.
    @Test("The migration chain alone does not build the deferred index")
    func migrationChainDoesNotBuildTheDeferredIndex() throws {
        let fixture = try makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }

        for index in SyncEngine.deferredIndexes {
            #expect(try indexExists(fixture.pool, index.name) == false,
                    """
                    \(index.name) exists straight after the migration chain — the \
                    deferral is not in effect and its cost is still paid before first \
                    paint. Did v83's body get restored?
                    """)
        }
        #expect(!SyncEngine.deferredIndexes.isEmpty,
                "an empty deferred set would make the loop above assert nothing")
    }

    /// The other half: it must actually arrive, or `markAllAsRead` never gets its
    /// index and the deferral is a silent regression rather than a deferral.
    @Test("The background maintenance pass builds it, and is idempotent")
    func maintenancePassBuildsTheDeferredIndexAndConverges() async throws {
        let fixture = try makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let dbPool = PrioritizedDatabase(pool: fixture.pool, priority: .background)

        #expect(await SyncEngine.runBuildDeferredIndexesIfMissing(dbPool: dbPool) == .built)
        for index in SyncEngine.deferredIndexes {
            #expect(try indexExists(fixture.pool, index.name),
                    "\(index.name) missing after the pass reported .built")
        }

        // Idempotent, and it reports so. A pass that rebuilt every time would burn
        // the 5,050 ms on every foreground poll — a worse defect than the one this
        // change fixes, and invisible without this assertion.
        #expect(await SyncEngine.runBuildDeferredIndexesIfMissing(dbPool: dbPool) == .alreadyPresent)
        for index in SyncEngine.deferredIndexes {
            #expect(try indexExists(fixture.pool, index.name))
        }
    }

    /// 🚨 ONE PASS CONVERGES — the reason the index build runs BEFORE the `ANALYZE`
    /// in `runWALMaintenance`. `CREATE INDEX` is DDL and bumps `schema_version`,
    /// which is the marker the statistics refresh latches on. Built first, the
    /// analysis records the POST-index version and the next pass is `.alreadyFresh`.
    /// Built after, the analysis would record a version the index immediately
    /// invalidates and the NEXT pass would pay a second whole-database `ANALYZE`.
    ///
    /// This asserts the SYSTEM PROPERTY (the second pass is a no-op on both steps),
    /// not the call order, so it stays honest if the steps are ever restructured.
    @Test("Index build then ANALYZE converges in a single maintenance pass")
    func indexBuildBeforeAnalyzeConvergesInOnePass() async throws {
        let fixture = try makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let dbPool = PrioritizedDatabase(pool: fixture.pool, priority: .background)
        let defaults = UserDefaults.standard
        let key = "analyzeMarker-\(UUID().uuidString)"
        defer { defaults.removeObject(forKey: key) }

        // Pass 1, in production order.
        #expect(await SyncEngine.runBuildDeferredIndexesIfMissing(dbPool: dbPool) == .built)
        #expect(await SyncEngine.runRefreshPlannerStatisticsIfStale(
            dbPool: dbPool, defaults: defaults, markerKey: key) == .refreshed)

        // Pass 2 must do nothing at all. `.alreadyFresh` here is the whole claim: the
        // marker settled ON the post-index schema version.
        #expect(await SyncEngine.runBuildDeferredIndexesIfMissing(dbPool: dbPool) == .alreadyPresent)
        #expect(await SyncEngine.runRefreshPlannerStatisticsIfStale(
            dbPool: dbPool, defaults: defaults, markerKey: key) == .alreadyFresh,
                """
                a second maintenance pass re-ran the whole-database ANALYZE — the \
                index build's schema_version bump landed after the marker settled, \
                which is the two-pass shape the ordering exists to prevent
                """)
    }
}
