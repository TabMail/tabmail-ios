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
    /// (`sqlite_stat1` says `messageHeader` is empty, because `ANALYZE` runs only
    /// inside migration bodies and a fresh install runs them against an empty table):
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
    @Test("markAllAsRead's three statements sort from the v83 index, never a temp B-tree")
    func markAllAsReadSweepUsesUnreadSweepIndex() throws {
        let db = try TestDatabase.make()

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
