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
/// the deferred index `messageHeader_ftsSelfHealWindow` lets the planner read them
/// newest first and stop at the 2,000th. These tests hold the read with the index to
/// the read without it (what every device ran before, and runs until the maintenance
/// pass builds the index) on databases built by the production migrations, with no
/// statistics and with the app's ANALYZE statistics, and hold its cost to the window:
/// the planner takes the index unaided, no sort, and no more work for a larger mailbox.
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
    static let indexName = "messageHeader_ftsSelfHealWindow"

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
    /// given order, with every account and folder they name.
    static func makeDatabase(_ headers: [Header]) throws -> (pool: DatabasePool, dir: URL, app: AppDatabase) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path, configuration: config)
        let app = try AppDatabase(dbPool: pool)
        for account in accounts {
            _ = try FolderEpochTestFixture.makeAccount(id: account, provider: .imap, pool: pool)
            for path in paths {
                try FolderEpochTestFixture.insertFolder(
                    accountId: account, path: path, role: path == "INBOX" ? .inbox : .archive, pool: pool)
            }
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
        return (pool, dir, app)
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

    @Test("With its index built, the candidate read returns the answer it returned without it, with and without statistics",
          arguments: Mailbox.allCases)
    func candidateReadMatchesTheReplacedRead(mailbox: Mailbox) async throws {
        let headers = Self.headers(mailbox)
        let (pool, dir, app) = try Self.makeDatabase(headers)
        defer { withExtendedLifetime(app) {}; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let dates = Dictionary(uniqueKeysWithValues: headers.map { ($0.id, $0.date) })
        let complete = headers.filter { $0.bodyComplete && $0.headerComplete }
        let candidates = SyncEngine.ftsBodyMembershipCandidateSQL

        // No statistics: the replaced read before the maintenance pass builds the
        // index, then the read once it has.
        let builtByMigrations = try await Self.indexExists(pool)
        #expect(!builtByMigrations, "precondition: the migrations alone do not build the index")
        let oracleUnanalyzed = try await pool.read { try String.fetchAll($0, sql: Self.replacedSQL) }
        try await pool.write { try SyncEngine.createDeferredIndexes($0) }
        let builtByPass = try await Self.indexExists(pool)
        #expect(builtByPass, "precondition: the deferred indexes include \(Self.indexName)")
        let readUnanalyzed = try await pool.read { try String.fetchAll($0, sql: candidates) }
        // The app's statistics: the read with the index, then the replaced read once it is dropped.
        try await pool.write { try $0.execute(sql: "ANALYZE") }
        let readAnalyzed = try await pool.read { try String.fetchAll($0, sql: candidates) }
        try await pool.write { try $0.execute(sql: "DROP INDEX IF EXISTS \(Self.indexName)") }
        let oracleAnalyzed = try await pool.read { try String.fetchAll($0, sql: Self.replacedSQL) }

        for (analyzed, read, oracle) in [(false, readUnanalyzed, oracleUnanalyzed), (true, readAnalyzed, oracleAnalyzed)] {
            let found = Self.differences(read, oracle, dates: dates)
            #expect(found.isEmpty, "\(mailbox), analyzed \(analyzed): \(found)")
            #expect(oracle.count == min(complete.count, Self.window), "precondition: the oracle read the window")
        }

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

    static func cost(of sql: String, in pool: DatabasePool) async throws -> Cost {
        try await pool.read { db in
            let statement = try db.makeStatement(sql: sql)
            let rows = try String.fetchAll(statement).count
            let vmSteps = Int(sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_VM_STEP, 0))
            let sorts = Int(sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_SORT, 0))
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
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

    @Test("With its index built, the planner takes it unaided and the candidate read stops at its window: no sort, and no more work for a mailbox twice as large",
          arguments: [false, true])
    func candidateReadStopsAtTheWindow(analyzed: Bool) async throws {
        let (smallPool, smallDir, smallApp) = try Self.makeDatabase(Self.denseHeaders(8_000))
        let (largePool, largeDir, largeApp) = try Self.makeDatabase(Self.denseHeaders(16_000))
        defer {
            withExtendedLifetime((smallApp, largeApp)) {}
            TestDatabaseTeardown.retire(pool: smallPool, directory: smallDir)
            TestDatabaseTeardown.retire(pool: largePool, directory: largeDir)
        }
        for pool in [smallPool, largePool] {
            try await pool.write { db in
                try SyncEngine.createDeferredIndexes(db)
                if analyzed { try db.execute(sql: "ANALYZE") }
            }
        }
        let small = try await Self.cost(of: SyncEngine.ftsBodyMembershipCandidateSQL, in: smallPool)
        let large = try await Self.cost(of: SyncEngine.ftsBodyMembershipCandidateSQL, in: largePool)
        #expect(small.rows == Self.window && large.rows == Self.window, "precondition: both fill the window")
        let takesIndex = large.plan.contains { $0.contains("COVERING INDEX \(Self.indexName)") }
        #expect(takesIndex, "analyzed \(analyzed): the planner does not take \(Self.indexName): \(large.plan)")
        let broken = Self.costViolations(small: small, large: large)
        #expect(broken.isEmpty, "analyzed \(analyzed): \(broken); plan \(large.plan)")

        // Negative control: without the index (before the pass builds it, and on every
        // device before this change) the same read breaks the same rule on the same mailboxes.
        for pool in [smallPool, largePool] {
            try await pool.write { try $0.execute(sql: "DROP INDEX IF EXISTS \(Self.indexName)") }
        }
        let replacedSmall = try await Self.cost(of: Self.replacedSQL, in: smallPool)
        let replacedLarge = try await Self.cost(of: Self.replacedSQL, in: largePool)
        let replacedBroken = Self.costViolations(small: replacedSmall, large: replacedLarge)
        #expect(!replacedBroken.isEmpty, "analyzed \(analyzed): the rule must catch the replaced read")
    }
}
