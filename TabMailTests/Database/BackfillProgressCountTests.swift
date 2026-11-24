/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// The statements a connection ran, expanded. `trace` fires on the database's own queue, hence the `Mutex`.
final class BackfillCountTape: Sendable {
    private let statements = Mutex<[String]>([])
    func record(_ sql: String) { statements.withLock { $0.append(sql) } }
    var all: [String] { statements.withLock { $0 } }
}

/// #1401: `SyncEngine.backfillProgressCounts` publishes three counts for an account on
/// every backfill progress update: every stored header, `MessageHeader.bodySettledRequest`
/// and `MessageHeader.pendingBodyRequest`. Each must read index entries only, never a
/// header row. Before the deferred index `messageHeader_backfillProgress` the settled
/// count read every header row of the account and the pending count read every pending
/// row of every account.
///
/// The plan test traces the statements the production read really runs, on a database
/// built by the production migrations plus the production deferred-index DDL, and plans
/// each one in three statistics states: the statistics the migration chain leaves, none
/// at all, and a fresh `ANALYZE`. Its control drops the index and shows both body counts
/// reading rows again, the plans the issue measured.
///
/// The differential tests keep the old statements as the oracle: the same production
/// read with the index dropped inside a rolled-back transaction, which is exactly what
/// ran before. The counts must be equal on an empty database, one row in every flag
/// combination, rows whose index keys all tie, several accounts (one of them empty) and
/// about 100,000 rows, in every statistics state. A count has no row order, so "same
/// rows in the same order" is "same three numbers".
@Suite("Backfill progress counts read index entries, never header rows")
struct BackfillProgressCountTests {

    /// The index the two body counts read.
    private static let index = "messageHeader_backfillProgress"

    /// The three published numbers, comparable.
    struct Counts: Equatable, CustomStringConvertible {
        let total: Int
        let settled: Int
        let pending: Int
        var description: String { "total \(total), settled \(settled), pending \(pending)" }
    }

    /// The statistics a device can hold when the counts run. Each can be applied in any
    /// order: the first is restored from a copy taken when the database was built.
    enum Statistics: String, CaseIterable {
        /// What `AppDatabase.runMigrations` leaves: no row for the deferred index.
        case migrationLeft
        /// An empty `sqlite_stat1`, reloaded.
        case none
        /// A whole-database `ANALYZE` over the rows the test wrote.
        case fresh
    }

    // MARK: - Fixtures

    /// The production migrations, then the production deferred-index DDL, then a copy of
    /// the statistics the migrations left, kept in a connection-local temporary table.
    private static func makeDatabase(accounts: [String]) throws -> DatabaseQueue {
        let queue = try TestDatabase.make()
        try queue.write { conn in
            try SyncEngine.createDeferredIndexes(conn)
            try conn.execute(sql: "CREATE TEMP TABLE migrationStatistics AS SELECT * FROM main.sqlite_stat1")
        }
        for (offset, id) in accounts.enumerated() {
            try TestDatabase.insertAccount(queue, id: id, email: "user\(offset)@example.com")
        }
        return queue
    }

    /// SQL expressions over the row number `n` for the columns a fill sets.
    struct Fill {
        let accountId: String
        let headerComplete: String
        let bodyComplete: String
        let bodyEmptyConfirmed: String
        let bodyMetadataOversized: String
    }

    /// Writes `count` headers, row `n` taking the values `fill` computes from `n`, every
    /// other column copied from one helper-written header that is removed afterwards.
    private static func fill(_ queue: DatabaseQueue, count: Int, templateAccount: String, _ fill: Fill) throws {
        let template = try TestDatabase.insertMessageHeader(
            queue, messageId: "template", folderId: "\(templateAccount):INBOX", accountId: templateAccount)
        try queue.write { conn in
            let columns = try conn.columns(in: MessageHeader.databaseTableName).map(\.name)
            let computed: [String: String] = [
                "id": "'bp-' || n",
                "messageId": "CAST(n AS TEXT)",
                "accountId": fill.accountId,
                "folderId": "(\(fill.accountId)) || ':INBOX'",
                "headerComplete": fill.headerComplete,
                "bodyComplete": fill.bodyComplete,
                "bodyEmptyConfirmed": fill.bodyEmptyConfirmed,
                "bodyMetadataOversized": fill.bodyMetadataOversized,
            ]
            #expect(Set(computed.keys).isSubset(of: Set(columns)), "every computed column exists: \(columns)")
            let names = columns.map { "\"\($0)\"" }.joined(separator: ", ")
            let values = columns.map { computed[$0] ?? "t.\"\($0)\"" }.joined(separator: ", ")
            try conn.execute(sql: """
                WITH RECURSIVE seq(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n + 1 < ?)
                INSERT INTO messageHeader (\(names))
                SELECT \(values) FROM seq, messageHeader AS t WHERE t.id = ?
                """, arguments: [count, template.id])
            try conn.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [template.id])
            let written = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader NOT INDEXED") ?? -1
            #expect(written == count, "the fill wrote \(written) rows, not \(count)")
        }
    }

    private static func apply(_ statistics: Statistics, to queue: DatabaseQueue) throws {
        try queue.writeWithoutTransaction { conn in
            switch statistics {
            case .migrationLeft:
                try conn.execute(sql: "DELETE FROM main.sqlite_stat1")
                try conn.execute(sql: "INSERT INTO main.sqlite_stat1 SELECT * FROM temp.migrationStatistics")
                // Reloads the planner's statistics from the table.
                try conn.execute(sql: "ANALYZE sqlite_schema")
            case .none:
                try conn.execute(sql: "DELETE FROM main.sqlite_stat1")
                try conn.execute(sql: "ANALYZE sqlite_schema")
            case .fresh:
                try conn.execute(sql: "ANALYZE main")
            }
        }
    }

    private static func indexStatRows(_ queue: DatabaseQueue) throws -> Int {
        try queue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM main.sqlite_stat1 WHERE idx = ?", arguments: [index]) ?? -1
        }
    }

    // MARK: - The read, its plans, and the oracle

    private static func counts(_ conn: Database, _ accountId: String) throws -> Counts {
        let read = try SyncEngine.backfillProgressCounts(conn, accountId: accountId)
        return Counts(total: read.total, settled: read.settled, pending: read.pending)
    }

    /// The plan of each COUNT `backfillProgressCounts` runs, in its order (total,
    /// settled, pending), taken from the statements traced while it runs.
    ///
    /// The traced statements carry their bound values inlined. No index on
    /// `messageHeader` is partial on a term these predicates contain, so an inlined
    /// literal and a bound parameter plan the same here.
    private static func plans(_ conn: Database, _ accountId: String) throws -> [String] {
        let tape = BackfillCountTape()
        conn.trace(options: .statement) { event in tape.record(event.expandedDescription) }
        _ = try counts(conn, accountId)
        conn.trace()
        let statements = tape.all.filter { $0.uppercased().contains("COUNT(") }
        #expect(statements.count == 3, "the read runs three counts: \(tape.all)")
        return try statements.map { sql in
            try Row.fetchAll(conn, sql: "EXPLAIN QUERY PLAN " + sql)
                .compactMap { $0["detail"] as String? }
                .joined(separator: " | ")
        }
    }

    /// True when every step of `plan` that touches `messageHeader` seeks a covering index:
    /// the step reads index entries and never a row.
    private static func readsIndexEntriesOnly(_ plan: String) -> Bool {
        let steps = plan.components(separatedBy: " | ").filter { $0.contains("messageHeader") }
        return !steps.isEmpty && steps.allSatisfy {
            $0.hasPrefix("SEARCH messageHeader USING COVERING INDEX ")
        }
    }

    /// The oracle: the same production read with the index dropped, i.e. the statements
    /// as they ran before it existed. Rolled back, so the database keeps the index.
    private static func oldCounts(_ queue: DatabaseQueue, _ accountIds: [String]) throws -> (counts: [String: Counts], plans: [String]) {
        try queue.writeWithoutTransaction { conn in
            var result: [String: Counts] = [:]
            var oldPlans: [String] = []
            try conn.inTransaction {
                try conn.execute(sql: "DROP INDEX \(index)")
                oldPlans = try plans(conn, accountIds[0])
                for id in accountIds { result[id] = try counts(conn, id) }
                return .rollback
            }
            return (result, oldPlans)
        }
    }

    /// Counts every account with the index and with the oracle, and checks they agree.
    private static func expectSameCounts(_ queue: DatabaseQueue, _ accountIds: [String], _ label: String) throws -> [String: Counts] {
        let new = try queue.read { conn in
            try Dictionary(uniqueKeysWithValues: accountIds.map { ($0, try counts(conn, $0)) })
        }
        let newPlans = try queue.read { try plans($0, accountIds[0]) }
        let old = try oldCounts(queue, accountIds)
        // Non-vacuity: the two sides really ran different plans.
        let oldPlans = old.plans.joined(separator: " || ")
        #expect(newPlans.count == 3, "\(label): three plans: \(newPlans)")
        if newPlans.count == 3 {
            #expect(newPlans[1].contains(index), "\(label): the settled count must read the index: \(newPlans[1])")
            #expect(newPlans[2].contains(index), "\(label): the pending count must read the index: \(newPlans[2])")
        }
        #expect(!oldPlans.contains(index), "\(label): the oracle must run without the index: \(oldPlans)")
        for id in accountIds {
            #expect(new[id] == old.counts[id], "\(label) \(id): index \(String(describing: new[id])), oracle \(String(describing: old.counts[id]))")
        }
        return new
    }

    // MARK: - Plans

    /// Red on the code before #1401: without the index the settled count reads every
    /// header row of the account and the pending count reads pending rows of every account.
    @Test("Each count seeks a covering index in every statistics state; without the index the body counts read rows")
    func countsReadIndexEntriesOnly() throws {
        let accounts = ["acc-a", "acc-b"]
        let queue = try Self.makeDatabase(accounts: accounts)
        try Self.fill(queue, count: 5_000, templateAccount: "acc-a", Fill(
            accountId: "CASE WHEN n % 4 = 0 THEN 'acc-b' ELSE 'acc-a' END",
            headerComplete: "(n % 7) <> 0",
            bodyComplete: "(n % 3) <> 0",
            bodyEmptyConfirmed: "(n % 11) = 0",
            bodyMetadataOversized: "(n % 13) = 0"))

        for statistics in Statistics.allCases {
            try Self.apply(statistics, to: queue)
            let statRows = try Self.indexStatRows(queue)
            if statistics == .fresh {
                #expect(statRows > 0, "the fresh state is vacuous unless ANALYZE wrote the index's row")
            } else {
                #expect(statRows == 0, "\(statistics.rawValue): the index has no statistics yet")
            }
            let plans = try queue.read { try Self.plans($0, "acc-a") }
            guard plans.count == 3 else { continue }
            for (label, plan) in zip(["total", "settled", "pending"], plans) {
                #expect(Self.readsIndexEntriesOnly(plan),
                        "\(statistics.rawValue) \(label): must read index entries only, never a row: \(plan)")
            }
            #expect(plans[1].contains("COVERING INDEX \(Self.index) (accountId=?)"),
                    "\(statistics.rawValue) settled: must seek the account in the index: \(plans[1])")
            #expect(plans[2].contains("COVERING INDEX \(Self.index) "),
                    "\(statistics.rawValue) pending: must seek the index: \(plans[2])")
            for column in ["accountId", "headerComplete", "bodyComplete", "bodyEmptyConfirmed", "bodyMetadataOversized"] {
                #expect(plans[2].contains("\(column)=?"),
                        "\(statistics.rawValue) pending: \(column) must be part of the seek, not a per-row test: \(plans[2])")
            }

            // Control: the same statements without the index read rows, as the issue measured.
            let old = try Self.oldCounts(queue, ["acc-a"]).plans
            guard old.count == 3 else { continue }
            #expect(!Self.readsIndexEntriesOnly(old[1]),
                    "\(statistics.rawValue) control: without the index the settled count must read rows, or this test pins nothing: \(old[1])")
            #expect(!Self.readsIndexEntriesOnly(old[2]),
                    "\(statistics.rawValue) control: without the index the pending count must read rows, or this test pins nothing: \(old[2])")
        }
    }

    /// Headers for the embedding plan test: a full chunk in every state, and a small
    /// mailbox for the fresh state to analyze. A fresh `ANALYZE` of these rows does not
    /// tip the read without its index name to the skip-scan on the simulator's SQLite;
    /// the large mailbox's statistics below do.
    private static let embeddingPlanRows = 20_000

    /// `sqlite_stat1` for `messageHeader` from a full `ANALYZE` of the 105,000-header proof
    /// database with this index present (four accounts, 82,382 headers owing an embedding,
    /// some bodies confirmed empty or oversized), taken with the Mac's sqlite3 and
    /// identical to the simulator's `ANALYZE` of it. That is the database on which the
    /// proof saw the read without its index name skip-scan this index. A plain `ANALYZE`
    /// with no analysis limit, which is what the app runs, counts the rows of every key
    /// prefix exactly, so these are the rows the app's own `ANALYZE` writes on that data.
    /// The app's SQLite keeps no `sqlite_stat4`, so they are all the planner knows about
    /// the table: written over the test's rows, they give it a large mailbox's estimates.
    /// The test checks at setup that they name every index of the table and no other, and
    /// that under them the read without its index name plans that skip-scan.
    private static let largeMailboxStatistics: [String: String] = [
        "idx_messageHeader_bodyStatus": "105000 52500 35000 26250 13125",
        "messageHeader_accountId_bodyComplete": "105000 26250 13125",
        "messageHeader_accountId_messageId": "105000 26250 2",
        "messageHeader_aiIncomplete": "19833 1",
        "messageHeader_backfillProgress": "105000 26250 13125 8750 6563 5250",
        "messageHeader_bodyRepopulate": "105000 52500 26250 17500 13125 1",
        "messageHeader_bodyRepopulateV2": "105000 52500 26250 17500 13125 10500 1",
        "messageHeader_completeByDate": "84951 1 1",
        "messageHeader_computedThreadId": "105000 105000",
        "messageHeader_date": "105000 1",
        "messageHeader_embeddingIncomplete": "82382 41191 1",
        "messageHeader_folderId": "105000 6563",
        "messageHeader_folderId_date": "105000 6563 1",
        "messageHeader_folderId_isRead": "105000 6563 3388",
        "messageHeader_folderId_isRead_date": "105000 6563 3388 1",
        "messageHeader_folderId_messageId": "105000 6563 1",
        "messageHeader_folderId_providerDate": "105000 6563 1",
        "messageHeader_folderId_uidInt": "105000 6563 1",
        "messageHeader_headerIncomplete": "5213 1",
        "messageHeader_inReplyTo": "105000 105000",
        "messageHeader_inbox_display": "105000 6563 3282 1",
        "messageHeader_isInInbox_date": "105000 52500 1",
        "messageHeader_messageId_accountId": "105000 3 2",
        "messageHeader_reminderLookup": "0 0 0",
        "messageHeader_rfc822MessageId": "105000 1",
        "messageHeader_rfc822MessageId_date": "105000 1 1",
        "messageHeader_threadId": "105000 105000",
        "messageHeader_triage_display": "105000 6563 3282 1020 1",
        "messageHeader_unreadSweep": "9066 605 1",
        "sqlite_autoindex_messageHeader_1": "105000 1",
    ]

    /// Replaces the statistics with `largeMailboxStatistics` and reloads them.
    private static func applyLargeMailboxStatistics(to queue: DatabaseQueue) throws {
        try queue.writeWithoutTransaction { conn in
            try conn.execute(sql: "DELETE FROM main.sqlite_stat1")
            for (name, stat) in largeMailboxStatistics {
                try conn.execute(
                    sql: "INSERT INTO main.sqlite_stat1 (tbl, idx, stat) VALUES ('messageHeader', ?, ?)",
                    arguments: [name, stat])
            }
            try conn.execute(sql: "ANALYZE sqlite_schema")
        }
    }

    /// #1401: with this index present and the app's `ANALYZE` run, SQLite planned the
    /// embedding repopulate read as a skip-scan of this index by account plus a sort of
    /// the whole backlog: 10,831 pages instead of 511 on 105,000 headers. The read names
    /// `messageHeader_embeddingIncomplete`, so in every statistics state, and under a
    /// large mailbox's statistics, it stays one ordered scan of that index, with no sort,
    /// stopping at its limit. Red when the statement does not name the index: the large
    /// mailbox's statistics then plan the skip-scan.
    @Test("With this index present, the embedding repopulate read keeps its ordered scan of its own index")
    func embeddingRepopulateKeepsItsIndex() throws {
        let accounts = ["acc-a", "acc-b", "acc-c", "acc-d"]
        let queue = try Self.makeDatabase(accounts: accounts)
        // Four accounts; four of every five headers have a body and no embedding, so
        // they are in the embedding read's partial index.
        try Self.fill(queue, count: Self.embeddingPlanRows, templateAccount: "acc-a", Fill(
            accountId: "'acc-' || char(97 + n % 4)",
            headerComplete: "1",
            bodyComplete: "(n % 5) <> 0",
            bodyEmptyConfirmed: "0",
            bodyMetadataOversized: "0"))
        let sql = BackfillEmbeddingQueue.repopulateSQL(limit: SyncConfig.embeddingRepopulateChunk)

        func expectOrderedScan(_ state: String) throws {
            let (plan, rows) = try queue.read { conn in
                (try Row.fetchAll(conn, sql: "EXPLAIN QUERY PLAN " + sql)
                    .compactMap { $0["detail"] as String? }
                    .joined(separator: " | "),
                 try String.fetchAll(conn, sql: sql).count)
            }
            #expect(plan == "SCAN messageHeader USING INDEX messageHeader_embeddingIncomplete",
                    "\(state): the embedding read must scan its own index in order, no sort: \(plan)")
            #expect(rows == SyncConfig.embeddingRepopulateChunk,
                    "\(state): setup: the read returns a full chunk: \(rows)")
        }

        for statistics in Statistics.allCases {
            try Self.apply(statistics, to: queue)
            if statistics == .fresh {
                let statRows = try Self.indexStatRows(queue)
                #expect(statRows > 0, "setup: the fresh state is vacuous unless ANALYZE wrote this index's row")
            }
            try expectOrderedScan(statistics.rawValue)
        }

        let indexes = try queue.read { conn in
            try String.fetchAll(conn, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'messageHeader'")
        }
        let measured = Set(Self.largeMailboxStatistics.keys)
        #expect(Set(indexes) == measured,
                "setup: the large mailbox's statistics name every index of the table and no other, so the planner estimates none by default: \(indexes.sorted())")
        try Self.applyLargeMailboxStatistics(to: queue)
        // The control: under these statistics the same read without its index name is
        // the skip-scan the name exists to prevent, so this state is the one that matters
        // and statistics that do not plan it fail here.
        let unnamed = sql.replacingOccurrences(of: " INDEXED BY messageHeader_embeddingIncomplete", with: "")
        let unnamedPlan = try queue.read { conn in
            try Row.fetchAll(conn, sql: "EXPLAIN QUERY PLAN " + unnamed)
                .compactMap { $0["detail"] as String? }
                .joined(separator: " | ")
        }
        #expect(unnamedPlan == "SEARCH messageHeader USING INDEX messageHeader_backfillProgress (ANY(accountId) AND bodyComplete=? AND bodyEmptyConfirmed=?) | USE TEMP B-TREE FOR ORDER BY",
                "setup: under the large mailbox's statistics the read without its index name must plan the skip-scan, or this state pins nothing: \(unnamedPlan)")
        try expectOrderedScan("large mailbox")
    }

    /// Headers for the body admission plan test: thousands waiting for a body in each
    /// queue's scope, far more than one window.
    private static let bodyAdmissionPlanRows = 20_000

    /// #1400: each body queue's refill runs its admission read, which stops at
    /// `SyncConfig.bodyFetchRepopulateLimit`. The limit bounds the read only while the
    /// plan walks `messageHeader_bodyRepopulateV2` in `date` order: a plan that sorts
    /// reads every pending row before it returns the first. So in every statistics
    /// state, and under a large mailbox's statistics, both reads seek that index on all
    /// five equality columns with no sort, and return exactly one window. Red when a
    /// read loses its limit: it then returns every pending row.
    @Test("Each body queue's admission read seeks its index in date order, with no sort, and stops at one window")
    func bodyAdmissionSeeksItsIndexAndStopsAtOneWindow() throws {
        let queue = try Self.makeDatabase(accounts: ["acc-a", "acc-b"])
        // Four of every five headers wait for a body; half of all headers are in the
        // inbox (the active queue's scope), half elsewhere (the backfill queue's).
        try Self.fill(queue, count: Self.bodyAdmissionPlanRows, templateAccount: "acc-a", Fill(
            accountId: "'acc-' || char(97 + n % 2)",
            headerComplete: "1",
            bodyComplete: "(n % 5) = 0",
            bodyEmptyConfirmed: "0",
            bodyMetadataOversized: "0"))
        try queue.write { conn in
            try conn.execute(sql: "UPDATE messageHeader SET isInInbox = rowid % 2")
        }
        let seek = "SEARCH messageHeader USING INDEX messageHeader_bodyRepopulateV2 (isInInbox=? AND headerComplete=? AND bodyComplete=? AND bodyEmptyConfirmed=? AND bodyMetadataOversized=?)"
        let reads = [("ActiveBodyQueue", ActiveBodyQueue.admissionSQL),
                     ("BackfillBodyQueue", BackfillBodyQueue.admissionSQL)]

        func expectWindowSeek(_ state: String) throws {
            for (name, sql) in reads {
                let (plan, rows) = try queue.read { conn in
                    (try Row.fetchAll(conn, sql: "EXPLAIN QUERY PLAN " + sql)
                        .compactMap { $0["detail"] as String? }
                        .joined(separator: " | "),
                     try Row.fetchAll(conn, sql: sql).count)
                }
                #expect(plan == seek,
                        "\(state), \(name): the admission read must seek its index in date order, no sort: \(plan)")
                #expect(rows == SyncConfig.bodyFetchRepopulateLimit,
                        "\(state), \(name): the read returns one window, not every pending row: \(rows)")
            }
        }

        for statistics in Statistics.allCases {
            try Self.apply(statistics, to: queue)
            if statistics == .fresh {
                let statRows = try queue.read { conn in
                    try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM main.sqlite_stat1 WHERE idx = 'messageHeader_bodyRepopulateV2'") ?? -1
                }
                #expect(statRows > 0, "setup: the fresh state is vacuous unless ANALYZE wrote the body index's row")
            }
            try expectWindowSeek(statistics.rawValue)
        }
        try Self.applyLargeMailboxStatistics(to: queue)
        try expectWindowSeek("large mailbox")
    }

    // MARK: - Same counts as the old statements

    @Test("Same counts as the old statements on an empty database and on one row in every flag combination")
    func emptyAndOneRow() throws {
        let accounts = ["acc-a", "acc-b"]
        let queue = try Self.makeDatabase(accounts: accounts)
        for statistics in Statistics.allCases {
            try Self.apply(statistics, to: queue)
            let counts = try Self.expectSameCounts(queue, accounts, "empty, \(statistics.rawValue)")
            #expect(counts["acc-a"] == Counts(total: 0, settled: 0, pending: 0))
        }

        try Self.fill(queue, count: 1, templateAccount: "acc-a", Fill(
            accountId: "'acc-a'", headerComplete: "0", bodyComplete: "0",
            bodyEmptyConfirmed: "0", bodyMetadataOversized: "0"))
        var seen: Set<String> = []
        for combination in 0..<16 {
            let flags = (0..<4).map { (combination >> $0) & 1 }
            try queue.write { conn in
                try conn.execute(sql: """
                    UPDATE messageHeader SET headerComplete = ?, bodyComplete = ?,
                        bodyEmptyConfirmed = ?, bodyMetadataOversized = ?
                    """, arguments: [flags[0], flags[1], flags[2], flags[3]])
            }
            for statistics in Statistics.allCases {
                try Self.apply(statistics, to: queue)
                let counts = try Self.expectSameCounts(queue, accounts, "one row \(flags), \(statistics.rawValue)")
                if let a = counts["acc-a"] { seen.insert(a.description) }
                #expect(counts["acc-b"] == Counts(total: 0, settled: 0, pending: 0), "the other account counts nothing")
            }
        }
        // Non-vacuity: the sixteen rows reach every outcome one row can have.
        #expect(seen == [
            Counts(total: 1, settled: 0, pending: 0).description,
            Counts(total: 1, settled: 1, pending: 0).description,
            Counts(total: 1, settled: 0, pending: 1).description,
        ], "outcomes: \(seen)")
    }

    @Test("Same counts as the old statements when every index key ties")
    func tiedIndexKeys() throws {
        let accounts = ["acc-a", "acc-b"]
        let queue = try Self.makeDatabase(accounts: accounts)
        // acc-a: 1,500 rows owing a body, all one key; acc-b: 500 settled rows, all one key.
        try Self.fill(queue, count: 2_000, templateAccount: "acc-a", Fill(
            accountId: "CASE WHEN n < 1500 THEN 'acc-a' ELSE 'acc-b' END",
            headerComplete: "1",
            bodyComplete: "CASE WHEN n < 1500 THEN 0 ELSE 1 END",
            bodyEmptyConfirmed: "0",
            bodyMetadataOversized: "0"))
        for statistics in Statistics.allCases {
            try Self.apply(statistics, to: queue)
            let counts = try Self.expectSameCounts(queue, accounts, "ties, \(statistics.rawValue)")
            #expect(counts["acc-a"] == Counts(total: 1_500, settled: 0, pending: 1_500))
            #expect(counts["acc-b"] == Counts(total: 500, settled: 500, pending: 0))
        }
    }

    @Test("Same counts as the old statements on about 100,000 rows in several accounts, one of them empty")
    func largeDatabaseSeveralAccounts() throws {
        let accounts = ["acc-a", "acc-b", "acc-c", "acc-empty"]
        let rows = 100_000
        let queue = try Self.makeDatabase(accounts: accounts)
        // Sixty, thirty and ten percent of the rows; the flag periods are prime to the
        // account period, so every account holds every flag combination.
        try Self.fill(queue, count: rows, templateAccount: "acc-a", Fill(
            accountId: "CASE WHEN n % 10 < 6 THEN 'acc-a' WHEN n % 10 < 9 THEN 'acc-b' ELSE 'acc-c' END",
            headerComplete: "(n % 7) <> 0",
            bodyComplete: "(n % 3) = 0",
            bodyEmptyConfirmed: "(n % 11) = 0",
            bodyMetadataOversized: "(n % 13) = 0"))

        // An independent oracle for the data shape: the documented predicates over the fill's own rules.
        var expected: [String: Counts] = [:]
        var tally: [String: (total: Int, settled: Int, pending: Int)] = [:]
        for n in 0..<rows {
            let account = n % 10 < 6 ? "acc-a" : (n % 10 < 9 ? "acc-b" : "acc-c")
            let headerComplete = n % 7 != 0
            let bodyComplete = n % 3 == 0
            let emptyConfirmed = n % 11 == 0
            let oversized = n % 13 == 0
            var entry = tally[account] ?? (0, 0, 0)
            entry.total += 1
            if bodyComplete || emptyConfirmed || oversized { entry.settled += 1 }
            if headerComplete && !bodyComplete && !emptyConfirmed && !oversized { entry.pending += 1 }
            tally[account] = entry
        }
        for (account, entry) in tally {
            expected[account] = Counts(total: entry.total, settled: entry.settled, pending: entry.pending)
        }
        expected["acc-empty"] = Counts(total: 0, settled: 0, pending: 0)

        for statistics in Statistics.allCases {
            try Self.apply(statistics, to: queue)
            let counts = try Self.expectSameCounts(queue, accounts, "100k, \(statistics.rawValue)")
            #expect(counts == expected, "\(statistics.rawValue): \(counts) against \(expected)")
        }
        // Non-vacuity: each account with rows has settled, pending and neither.
        for account in ["acc-a", "acc-b", "acc-c"] {
            let e = expected[account] ?? Counts(total: 0, settled: 0, pending: 0)
            #expect(e.settled > 0 && e.pending > 0 && e.settled + e.pending < e.total, "\(account): \(e)")
        }
    }
}
