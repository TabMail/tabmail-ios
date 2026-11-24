/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import SQLite3
@testable import TabMail

/// #1397: at every launch and foreground the search self-check
/// (`SyncEngine.selfHealFTSBodyMembership`) asks the search index about the newest
/// 2,000 headers whose body is complete. Its statement read and sorted every such
/// header of every account before it returned the first. The statement is unchanged;
/// the deferred partial index `messageHeader_completeByDate` (the `date, id` of the
/// complete headers) lets the planner read them newest first and stop at the 2,000th.
/// These tests hold the read with the index to the read without it (what every device
/// ran before, and runs until the maintenance pass builds the index) on databases built
/// by the production migrations, in each statistics state a device can be in
/// (`Statistics`). Once statistics are taken the planner takes the index unaided: no
/// sort, and no more work for a larger mailbox. With the statistics deleted it keeps the
/// plan it had without the index. The start-up recovery read and the one-time sweep page,
/// which filter on the same columns, keep their own indexes.
@Suite("FTS self-heal candidate read")
struct FTSSelfHealCandidateReadTests {

    /// The statement as it ran before this change, kept as the oracle; it runs on the
    /// database without the new index.
    static let replacedSQL = """
        SELECT id FROM messageHeader
        WHERE bodyComplete = 1 AND headerComplete = 1
        ORDER BY date DESC
        LIMIT 2000
        """
    static let window = 2000
    static let indexName = "messageHeader_completeByDate"

    /// The planner statistics a device can hold when the read runs with the index built.
    enum Statistics: String, CaseIterable, CustomTestStringConvertible {
        /// None: `sqlite_stat1` and `sqlite_stat4` emptied once the index is built, as in
        /// the proof harness's no-statistics state (`DBProof.apply(.none, to:)`).
        case emptied
        /// Taken on an empty mailbox: a fresh install whose first maintenance pass builds
        /// the index and analyzes in one write (as `runRefreshPlannerStatisticsIfStale`
        /// does) before its first sync stores a header. They stay until the next schema
        /// change re-arms the pass.
        case emptyMailbox
        /// Taken once the headers exist: the maintenance pass on a synced mailbox.
        case analyzed
        var testDescription: String { rawValue }
    }

    /// The maintenance pass's write: the missing deferred indexes, then the statistics
    /// over them, in one transaction.
    static func buildAndAnalyze(_ db: Database) throws {
        try SyncEngine.createDeferredIndexes(db)
        try db.execute(sql: "ANALYZE")
    }

    static func indexExists(_ pool: DatabasePool) async throws -> Bool {
        try await pool.read {
            try Int.fetchOne($0, sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
                             arguments: [Self.indexName]) != nil
        }
    }

    struct Header {
        let id: String
        let accountId: String
        let path: String
        let date: Date
        let isInInbox: Bool
        let bodyComplete: Bool
        let headerComplete: Bool
        let bodyEmptyConfirmed: Bool
    }

    /// The mailboxes the read is compared on. Each holds headers in every
    /// combination of the columns an index over the body state could split on
    /// (inbox or not, body empty or not), complete and incomplete rows
    /// interleaved, inserted in an order that is not their date order.
    enum Mailbox: String, CaseIterable, CustomTestStringConvertible {
        case empty, oneRow, onlyIncomplete, ties, severalAccounts, large, largeSparse
        var testDescription: String { rawValue }
    }

    static let accounts = ["fsc-a", "fsc-b", "fsc-c"]
    static let paths = ["INBOX", "Archive"]

    /// Seconds since 1970, whole, so that equal dates stay equal once stored.
    static func now() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    static func headers(_ mailbox: Mailbox) -> [Header] {
        let now = now()
        var random = SplitMix64(seed: 1397)
        func make(_ n: Int, completeShare: Int, accounts: [String], dateStep: (Int) -> Int) -> [Header] {
            var made: [Header] = []
            made.reserveCapacity(n)
            for i in 0..<n {
                let account = accounts[i % accounts.count]
                let path = paths[random.pick(paths.count)]
                let complete = random.pick(1000) < completeShare
                made.append(Header(
                    id: "\(account):\(path):\(i)", accountId: account, path: path,
                    date: now.addingTimeInterval(-37 * Double(dateStep(i))),
                    isInInbox: path == "INBOX",
                    bodyComplete: complete,
                    headerComplete: complete || random.pick(2) == 0,
                    bodyEmptyConfirmed: random.pick(10) == 0))
            }
            made.shuffle(using: &random)
            return made
        }
        switch mailbox {
        case .empty:
            return []
        case .oneRow:
            return make(1, completeShare: 1000, accounts: [accounts[0]], dateStep: { $0 })
        case .onlyIncomplete:
            return make(50, completeShare: 0, accounts: accounts, dateStep: { $0 })
                .filter { !$0.bodyComplete || !$0.headerComplete }
        case .ties:
            // Runs of seven equal dates, so the window of 2,000 cuts a run.
            return make(3_400, completeShare: 900, accounts: accounts, dateStep: { $0 / 7 })
        case .severalAccounts:
            return make(4_500, completeShare: 700, accounts: accounts, dateStep: { $0 })
        case .large:
            return make(100_000, completeShare: 950, accounts: accounts, dateStep: { $0 })
        case .largeSparse:
            return make(100_000, completeShare: 15, accounts: accounts, dateStep: { $0 })
        }
    }

    /// A database built by the production migrations, holding `headers` in the
    /// given order, with every account and folder they name. With `statistics`, the
    /// deferred indexes are built and the database is in that statistics state; without,
    /// it is as the migrations leave it, without the index.
    static func makeDatabase(_ headers: [Header], statistics: Statistics? = nil) throws
        -> (pool: DatabasePool, dir: URL, app: AppDatabase) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path, configuration: config)
        let app = try AppDatabase(dbPool: pool)
        let builtByMigrations = try pool.read {
            try Int.fetchOne($0, sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
                             arguments: [Self.indexName]) != nil
        }
        #expect(!builtByMigrations, "precondition: the migrations alone do not build \(Self.indexName)")
        for account in accounts {
            _ = try FolderEpochTestFixture.makeAccount(id: account, provider: .imap, pool: pool)
            for path in paths {
                try FolderEpochTestFixture.insertFolder(
                    accountId: account, path: path, role: path == "INBOX" ? .inbox : .archive, pool: pool)
            }
        }
        if statistics == .emptyMailbox {
            try pool.write { try Self.buildAndAnalyze($0) }
        }
        try pool.write { db in
            let insert = try db.makeStatement(sql: """
                INSERT INTO messageHeader (id, folderId, accountId, folderPath, messageId, subject, "from",
                    fromAddress, "to", date, isInInbox, bodyComplete, headerComplete, bodyEmptyConfirmed)
                VALUES (?, ?, ?, ?, ?, 'subject', 'Sender', 'sender@example.com', 'recipient@example.com', ?, ?, ?, ?, ?)
                """)
            for h in headers {
                try insert.execute(arguments: [
                    h.id, "\(h.accountId):\(h.path)", h.accountId, h.path, h.id, h.date,
                    h.isInInbox, h.bodyComplete, h.headerComplete, h.bodyEmptyConfirmed,
                ])
            }
        }
        switch statistics {
        case .analyzed?:
            try pool.write { try Self.buildAndAnalyze($0) }
        case .emptied?:
            try pool.write { db in
                try SyncEngine.createDeferredIndexes(db)
                try DBProof.apply(.none, to: db)
            }
        case .emptyMailbox?, nil:
            break
        }
        if let statistics {
            try Self.expectState(statistics, of: pool, complete: headers.filter { $0.bodyComplete && $0.headerComplete }.count)
        }
        return (pool, dir, app)
    }

    /// The database is in the state it claims: the index exists, and its own statistics
    /// row counts no header when taken on an empty mailbox and every complete header when
    /// taken after the sync; with the statistics emptied there is no row at all. The
    /// creating write bumps the schema version, so every connection reloads these rows.
    static func expectState(_ statistics: Statistics, of pool: DatabasePool, complete: Int) throws {
        let (exists, stat, statRows) = try pool.read { db -> (Bool, String?, Int) in
            let exists = try Int.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
                                          arguments: [Self.indexName]) != nil
            let stat = try String.fetchOne(db, sql: "SELECT stat FROM sqlite_stat1 WHERE idx = ?",
                                           arguments: [Self.indexName])
            let statRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_stat1") ?? 0
            return (exists, stat, statRows)
        }
        #expect(exists, "precondition: the deferred indexes include \(Self.indexName)")
        let counted = stat?.split(separator: " ").first.flatMap { Int($0) }
        switch statistics {
        case .emptied:
            #expect(statRows == 0, "precondition: no statistics, found \(statRows) rows")
        case .emptyMailbox:
            #expect(counted == 0, "precondition: statistics taken on an empty mailbox, found \(stat ?? "no row")")
        case .analyzed:
            #expect(counted == complete, "precondition: statistics over \(complete) complete headers, found \(stat ?? "no row")")
        }
    }

    /// Where `read` differs from `oracle` as an answer to "the newest 2,000 headers
    /// whose body is complete": the same dates in the same order, and inside every run
    /// of equal dates the window holds whole, the same headers. In a run the window
    /// cuts, both return the same number of headers of that date (implied by equal
    /// dates); which of them the replaced statement returned depended on the order its
    /// sort received them in, so neither choice is the old answer more than the other.
    static func differences(_ read: [String], _ oracle: [String], dates: [String: Date]) -> [String] {
        var found: [String] = []
        if Set(read).count != read.count { found.append("the read returned a header twice") }
        let readDates = read.map { dates[$0] }
        let oracleDates = oracle.map { dates[$0] }
        if readDates != oracleDates {
            let shared = min(readDates.count, oracleDates.count)
            let at = (0..<shared).first { readDates[$0] != oracleDates[$0] } ?? shared
            found.append("dates differ from position \(at) (counts \(read.count) and \(oracle.count))")
            return found
        }
        var start = 0
        while start < read.count {
            var end = start
            while end < read.count, readDates[end] == readDates[start] { end += 1 }
            let cut = end == read.count && read.count == window
            if !cut, Set(read[start..<end]) != Set(oracle[start..<end]) {
                found.append("the run of equal dates at positions \(start)..<\(end) holds other headers")
            }
            start = end
        }
        return found
    }

    @Test("With its index built, the candidate read returns the answer the replaced read returns without it, in every statistics state",
          arguments: Mailbox.allCases, Statistics.allCases)
    func candidateReadMatchesTheReplacedRead(mailbox: Mailbox, statistics: Statistics) async throws {
        let headers = Self.headers(mailbox)
        let (pool, dir, app) = try Self.makeDatabase(headers, statistics: statistics)
        defer { withExtendedLifetime(app) {}; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let dates = Dictionary(uniqueKeysWithValues: headers.map { ($0.id, $0.date) })
        let complete = headers.filter { $0.bodyComplete && $0.headerComplete }

        // The read with the index, then the replaced read on the same database once the
        // index is dropped (what a device runs before the maintenance pass builds it).
        let read = try await pool.read { try String.fetchAll($0, sql: SyncEngine.ftsBodyMembershipCandidateSQL) }
        try await pool.write { try $0.execute(sql: "DROP INDEX IF EXISTS \(Self.indexName)") }
        let dropped = try await Self.indexExists(pool)
        #expect(!dropped, "precondition: the oracle runs without \(Self.indexName)")
        let oracle = try await pool.read { try String.fetchAll($0, sql: Self.replacedSQL) }

        let found = Self.differences(read, oracle, dates: dates)
        #expect(found.isEmpty, "\(mailbox), \(statistics): \(found)")
        #expect(oracle.count == min(complete.count, Self.window), "precondition: the oracle read the window")

        // The mailboxes exercise what they are named for.
        switch mailbox {
        case .ties:
            let cutDate = try #require(complete.map(\.date).sorted(by: >).dropFirst(Self.window - 1).first)
            let inCutRun = complete.filter { $0.date == cutDate }.count
            let cutRunInWindow = complete.map(\.date).sorted(by: >).prefix(Self.window).filter { $0 == cutDate }.count
            #expect(inCutRun > cutRunInWindow, "precondition: the window cuts a run of equal dates")
        case .severalAccounts, .large:
            let accountsInWindow = Set(complete.sorted { $0.date > $1.date }.prefix(Self.window).map(\.accountId))
            #expect(accountsInWindow.count == Self.accounts.count, "precondition: every account is in the window")
        case .largeSparse:
            #expect(complete.count < Self.window, "precondition: the window holds every complete header")
        case .empty, .oneRow, .onlyIncomplete:
            break
        }
    }

    /// What one run of `sql` cost: the rows it returned, its virtual machine steps
    /// (which grow with every row it visits, returned or not), its sorts, and its plan.
    struct Cost: Sendable {
        let rows: Int
        let vmSteps: Int
        let sorts: Int
        let plan: [String]
    }

    static func cost(of sql: String, arguments: StatementArguments = StatementArguments(),
                     in pool: DatabasePool) async throws -> Cost {
        try await pool.read { db in
            let statement = try db.makeStatement(sql: sql)
            let rows = try Row.fetchAll(statement, arguments: arguments).count
            let vmSteps = Int(sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_VM_STEP, 0))
            let sorts = Int(sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_SORT, 0))
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
                .map { $0["detail"] as String }
            return Cost(rows: rows, vmSteps: vmSteps, sorts: sorts, plan: plan)
        }
    }

    /// A mailbox of `n` headers, nine in ten complete, across every account.
    static func denseHeaders(_ n: Int) -> [Header] {
        let now = now()
        return (0..<n).map { i in
            let account = accounts[i % accounts.count]
            let path = paths[(i / 3) % paths.count]
            return Header(
                id: "\(account):\(path):\(i)", accountId: account, path: path,
                date: now.addingTimeInterval(-37 * Double(i)), isInInbox: path == "INBOX",
                bodyComplete: i % 10 != 0, headerComplete: true, bodyEmptyConfirmed: i % 7 == 0)
        }
    }

    /// Why a read's cost on a mailbox of `small` and one twice as large breaks the
    /// rule: a sort (it read everything it sorted before returning the first row), or
    /// more work for the larger mailbox (it visited rows outside the window).
    static func costViolations(small: Cost, large: Cost) -> [String] {
        var broken: [String] = []
        if small.sorts > 0 || large.sorts > 0 { broken.append("sorted (\(small.sorts), \(large.sorts))") }
        if large.plan.contains(where: { $0.contains("USE TEMP B-TREE FOR ORDER BY") }) {
            broken.append("plans a sort: \(large.plan)")
        }
        // Twice the mailbox may cost a few steps more (a deeper B-tree), never a share of it.
        if Double(large.vmSteps) > Double(small.vmSteps) * 1.1 {
            broken.append("VM steps grew with the mailbox: \(small.vmSteps) -> \(large.vmSteps)")
        }
        return broken
    }

    @Test("With its index built and statistics taken, on an empty mailbox or a synced one, the planner takes it unaided and the candidate read stops at its window: no sort, and no more work for a mailbox twice as large",
          arguments: [Statistics.emptyMailbox, .analyzed])
    func candidateReadStopsAtTheWindow(statistics: Statistics) async throws {
        let (smallPool, smallDir, smallApp) = try Self.makeDatabase(Self.denseHeaders(8_000), statistics: statistics)
        let (largePool, largeDir, largeApp) = try Self.makeDatabase(Self.denseHeaders(16_000), statistics: statistics)
        defer {
            withExtendedLifetime((smallApp, largeApp)) {}
            TestDatabaseTeardown.retire(pool: smallPool, directory: smallDir)
            TestDatabaseTeardown.retire(pool: largePool, directory: largeDir)
        }
        let small = try await Self.cost(of: SyncEngine.ftsBodyMembershipCandidateSQL, in: smallPool)
        let large = try await Self.cost(of: SyncEngine.ftsBodyMembershipCandidateSQL, in: largePool)
        #expect(small.rows == Self.window && large.rows == Self.window, "precondition: both fill the window")
        let takesIndex = large.plan.contains { $0.contains("COVERING INDEX \(Self.indexName)") }
        #expect(takesIndex, "\(statistics): the planner does not take \(Self.indexName): \(large.plan)")
        let broken = Self.costViolations(small: small, large: large)
        #expect(broken.isEmpty, "\(statistics): \(broken); plan \(large.plan)")

        // Negative control: without the index (before the pass builds it, and on every
        // device before this change) the same read breaks the same rule on the same mailboxes.
        for pool in [smallPool, largePool] {
            try await pool.write { try $0.execute(sql: "DROP INDEX IF EXISTS \(Self.indexName)") }
        }
        let replacedSmall = try await Self.cost(of: Self.replacedSQL, in: smallPool)
        let replacedLarge = try await Self.cost(of: Self.replacedSQL, in: largePool)
        let replacedBroken = Self.costViolations(small: replacedSmall, large: replacedLarge)
        #expect(!replacedBroken.isEmpty, "\(statistics): the rule must catch the replaced read")
    }

    @Test("With its index built and the statistics deleted, the candidate read keeps the plan it had without the index and costs no more")
    func candidateReadWithoutStatisticsKeepsTheReplacedPlan() async throws {
        let (pool, dir, app) = try Self.makeDatabase(Self.denseHeaders(16_000), statistics: .emptied)
        defer { withExtendedLifetime(app) {}; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let read = try await Self.cost(of: SyncEngine.ftsBodyMembershipCandidateSQL, in: pool)
        try await pool.write { try $0.execute(sql: "DROP INDEX IF EXISTS \(Self.indexName)") }
        let replaced = try await Self.cost(of: Self.replacedSQL, in: pool)
        #expect(read.rows == replaced.rows, "precondition: both read the window")
        #expect(read.plan == replaced.plan, "the plan changed: \(read.plan) against \(replaced.plan)")
        #expect(read.vmSteps <= replaced.vmSteps, "more work than without the index: \(read.vmSteps) > \(replaced.vmSteps)")
    }

    /// `SyncEngine.healAllFTSBodyMembership`'s page, as it runs it: the one-time sweep of
    /// every complete header in rowid order.
    static let sweepPageSQL = """
        SELECT rowid, id FROM messageHeader
        WHERE rowid > ? AND bodyComplete = 1 AND headerComplete = 1
        ORDER BY rowid LIMIT ?
        """

    @Test("The two other reads on the same columns keep their own indexes: the start-up recovery read in every statistics state, and the one-time sweep page once statistics are taken on a synced mailbox or deleted",
          arguments: Statistics.allCases)
    func otherReadsKeepTheirIndexes(statistics: Statistics) async throws {
        let (pool, dir, app) = try Self.makeDatabase(Self.headers(.large), statistics: statistics)
        defer { withExtendedLifetime(app) {}; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let (recoverySQL, recoveryArguments) = try await pool.read { db -> (String, StatementArguments) in
            let statement = try FTSSelfHealCandidateProofTests.incompleteHeadersRequest()
                .makePreparedRequest(db, forSingleResult: false).statement
            return (statement.sql, statement.arguments)
        }
        let recovery = try await Self.cost(of: recoverySQL, arguments: recoveryArguments, in: pool)
        let sweep = try await Self.cost(of: Self.sweepPageSQL, arguments: [0, SyncConfig.ftsOrphanPruneChunk], in: pool)
        let recoveryTakesIndex = recovery.plan.contains { $0.contains(Self.indexName) }
        #expect(!recoveryTakesIndex, "\(statistics): the recovery read takes \(Self.indexName): \(recovery.plan)")
        // On statistics taken on an empty mailbox the planner may take the index for the
        // sweep page: that sweep runs once per device, seconds after the first launch,
        // when such a mailbox is still nearly empty, and before this change the page
        // already sorted every complete header in that state.
        if statistics != .emptyMailbox {
            let sweepTakesIndex = sweep.plan.contains { $0.contains(Self.indexName) }
            #expect(!sweepTakesIndex, "\(statistics): the sweep page takes \(Self.indexName): \(sweep.plan)")
        }
    }
}
