/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// A deferred index and its planner statistics commit together, so every connection plans
/// the same way once the maintenance pass that builds it has finished.
///
/// THE PROPERTY. A connection loads `sqlite_stat1` when it (re)loads the schema, and it
/// reloads only when `schema_version` has moved since its last read. `CREATE INDEX` moves
/// it; `ANALYZE` does not (unless it has to create `sqlite_stat1`). So if the index
/// committed in one write and its statistics in a later one, a connection that read in
/// between would load the new index with no statistics for it, beside the old statistics
/// of every other index, and keep planning from that mix until it is closed. Built and
/// analyzed in ONE write, there is no such moment: every connection, whenever it last
/// read, plans like a fresh connection after the pass.
///
/// THE CENSUS. Two test-only indexes of different shapes (a four-column index over the
/// completeness flags, and a partial index over inbox members), each under five statistics
/// regimes a device can be in when a new deferred index arrives, across fourteen
/// statements the app runs against `messageHeader`. Three extra connections per case:
/// one opened before the pass that reads again inside the pass's write slot (the window),
/// one first opened inside that slot, and a control that reads only before and after.
/// After the pass, each must plan every statement exactly as a fresh connection does.
///
/// `.serialized` and `.processGlobalState`: the refresh carries a process-wide
/// single-flight latch, the write-queue observer is a process-wide singleton, and the
/// write gives up while `DatabaseSuspension.isSuspended`, which `DatabaseSuspensionTests`
/// holds.
@Suite("Deferred index statistics: one write, every connection converges", .serialized, .processGlobalState)
struct DeferredIndexStatisticsTests {

    /// Rows per fixture. Large enough that the planner's choices depend on the
    /// statistics, small enough for 10 cases in one run.
    private static let rowCount = 5_000
    private static let accountCount = 3
    private static let seed: UInt64 = 2026
    /// The write label `runRefreshPlannerStatisticsIfStale` submits; the window opens when
    /// the write queue hands it the writer.
    private static let refreshWriteLabel = "AnalyzePlannerStatistics"

    enum TestIndex: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case completenessWindow
        case inboxMembers

        var index: SyncEngine.DeferredIndex {
            switch self {
            case .completenessWindow:
                return SyncEngine.DeferredIndex(
                    name: "messageHeader_testCompletenessWindow",
                    sql: """
                    CREATE INDEX IF NOT EXISTS messageHeader_testCompletenessWindow \
                    ON messageHeader(headerComplete, bodyComplete, date, id)
                    """)
            case .inboxMembers:
                return SyncEngine.DeferredIndex(
                    name: "messageHeader_testInboxMembers",
                    sql: """
                    CREATE INDEX IF NOT EXISTS messageHeader_testInboxMembers \
                    ON messageHeader(accountId, messageId) WHERE isInInbox = 1
                    """)
            }
        }

        var testDescription: String { rawValue }
    }

    /// What `sqlite_stat1` holds when the new deferred index arrives.
    enum Regime: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// No statistics table at all.
        case noStatistics
        /// Analyzed while the mailbox was empty: a fresh install whose first maintenance
        /// pass ran before any mail synced.
        case empty
        /// Analyzed at 1% of today's rows.
        case small
        /// Analyzed at half of today's rows.
        case half
        /// Analyzed over today's rows.
        case current

        /// The share of the rows present when the regime's own `ANALYZE` ran.
        var analyzedShare: Double? {
            switch self {
            case .noStatistics: return nil
            case .empty: return 0
            case .small: return 0.01
            case .half: return 0.5
            case .current: return 1
            }
        }

        var testDescription: String { rawValue }
    }

    // MARK: - The statements

    private struct Probe {
        let name: String
        let sql: String
        let arguments: StatementArguments
    }

    /// The `messageHeader` reads the new index could change the plan of: the body,
    /// self-heal and embedding work lists, the per-account counts, the inbox pages and
    /// the inbox member seed.
    private static func probes() -> [Probe] {
        let folder = "acc0:INBOX"
        let account = "acc0"
        return [
            Probe(name: "ftsCandidate", sql: """
                SELECT id FROM messageHeader WHERE bodyComplete = 1 AND headerComplete = 1 ORDER BY date DESC LIMIT 2000
                """, arguments: []),
            Probe(name: "backfillFTSSelfHeal", sql: """
                SELECT id FROM messageHeader WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 LIMIT 5000
                """, arguments: []),
            Probe(name: "bodyCompleteRestore", sql: """
                SELECT id FROM messageHeader WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0
                """, arguments: []),
            Probe(name: "healAllSweep", sql: """
                SELECT rowid, id FROM messageHeader WHERE rowid > ? AND bodyComplete = 1 AND headerComplete = 1 \
                ORDER BY rowid LIMIT 500
                """, arguments: [0]),
            Probe(name: "activeBodyAdmission", sql: """
                SELECT id, accountId, folderPath, messageId, isInInbox FROM messageHeader \
                WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 1 \
                AND bodyMetadataOversized = 0 ORDER BY date DESC
                """, arguments: []),
            Probe(name: "backfillBodyAdmission", sql: """
                SELECT id, accountId, folderPath, messageId, isInInbox FROM messageHeader \
                WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 0 \
                AND bodyMetadataOversized = 0 ORDER BY date DESC
                """, arguments: []),
            Probe(name: "embeddingRepopulate", sql: """
                SELECT id FROM messageHeader WHERE bodyComplete = 1 AND embeddingComplete = 0 AND bodyEmptyConfirmed = 0 \
                ORDER BY isInInbox DESC, date DESC LIMIT 500
                """, arguments: []),
            Probe(name: "pendingBodyCount", sql: """
                SELECT COUNT(*) FROM messageHeader WHERE accountId = ? AND headerComplete = 1 AND bodyComplete = 0 \
                AND bodyEmptyConfirmed = 0 AND bodyMetadataOversized = 0
                """, arguments: [account]),
            Probe(name: "bodySettledCount", sql: """
                SELECT COUNT(*) FROM messageHeader WHERE accountId = ? \
                AND (bodyComplete = 1 OR bodyEmptyConfirmed = 1 OR bodyMetadataOversized = 1)
                """, arguments: [account]),
            Probe(name: "recoverIncomplete", sql: """
                SELECT * FROM messageHeader WHERE headerComplete = 0 LIMIT 500
                """, arguments: []),
            Probe(name: "inboxDefault", sql: """
                SELECT * FROM messageHeader WHERE folderId = ? AND headerComplete = 1 ORDER BY date DESC LIMIT 50
                """, arguments: [folder]),
            Probe(name: "inboxUnread", sql: """
                SELECT * FROM messageHeader WHERE folderId = ? AND headerComplete = 1 AND isRead = 0 \
                ORDER BY date DESC LIMIT 50
                """, arguments: [folder]),
            Probe(name: "aiRecentInbox", sql: """
                WITH recentInbox AS (SELECT id, accountId, bodyComplete, summaryBlurb, actionTag, cachedReply, date \
                FROM messageHeader WHERE isInInbox = 1 ORDER BY date DESC, id DESC LIMIT 100) \
                SELECT id, accountId FROM recentInbox WHERE bodyComplete = 1 \
                AND (summaryBlurb IS NULL OR summaryBlurb = '' OR actionTag IS NULL OR cachedReply IS NULL) \
                ORDER BY date DESC, id DESC
                """, arguments: []),
            Probe(name: "inboxSeed", sql: """
                SELECT rowid, accountId, messageId FROM messageHeader WHERE isInInbox = 1
                """, arguments: []),
        ]
    }

    /// Every probe's plan on `db`, keyed by probe name.
    ///
    /// The plain read first is load-bearing: `EXPLAIN QUERY PLAN` compiles against the
    /// schema the connection already holds and never checks `schema_version` itself. A
    /// real read in the same transaction does, so the plans below reflect whatever this
    /// connection reloads at this moment, exactly as the app's next statement would.
    private static func plans(_ db: Database) throws -> [String: String] {
        _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (SELECT 1 FROM messageHeader LIMIT 1)")
        var out: [String: String] = [:]
        for probe in probes() {
            let rows = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + probe.sql, arguments: probe.arguments)
            out[probe.name] = rows.map { $0["detail"] as String }.joined(separator: " | ")
        }
        return out
    }

    private static func plans(_ queue: DatabaseQueue) throws -> [String: String] {
        try queue.read { db in try plans(db) }
    }

    private static func openReader(_ path: String) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: path, configuration: configuration)
    }

    // MARK: - The mailbox

    /// SplitMix64, so the mailbox is the same on every run and every regime.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    }

    /// A mailbox with the proportions of a synced one: a fifth of the mail in the inbox,
    /// most of it read, nearly every header and most bodies complete, most bodies embedded.
    private static func mailbox() -> [MessageHeader] {
        var rng = SplitMix64(state: seed)
        let now = Date()
        let span: TimeInterval = 900 * 86_400
        return (0..<rowCount).map { i in
            let account = "acc\(i % accountCount)"
            let inbox = rng.unit() < 0.20
            let path = inbox ? "INBOX" : "Archive"
            var header = MessageHeader(
                messageId: "\(i)",
                subject: "s",
                from: "f@example.com",
                fromAddress: "f@example.com",
                to: "t@example.com",
                date: now.addingTimeInterval(-rng.unit() * span),
                snippet: "",
                folderId: "\(account):\(path)",
                accountId: account,
                folderPath: path,
                isInInbox: inbox)
            header.id = "\(account):\(path):\(i)"
            header.isRead = rng.unit() < (inbox ? 0.70 : 0.98)
            header.headerComplete = rng.unit() < 0.999
            header.bodyComplete = rng.unit() < 0.95
            header.bodyEmptyConfirmed = rng.unit() < 0.03
            header.embeddingComplete = rng.unit() < 0.80
            header.bodyMetadataOversized = rng.unit() < 0.005
            return header
        }
    }

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let path: String
    }

    /// The migrated schema with today's deferred indexes, the mailbox, and `regime`'s
    /// statistics. Foreign keys off: the planner does not read the account and folder
    /// rows, so the fixture does not create them.
    private static func makeFixture(_ regime: Regime) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("test.sqlite").path
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let pool = try DatabasePool(path: path, configuration: configuration)
        try AppDatabase.runMigrations(on: pool)
        try pool.write { db in try SyncEngine.createDeferredIndexes(db) }

        let rows = mailbox()
        let analyzedAt = regime.analyzedShare.map { Int((Double(rows.count) * $0).rounded()) } ?? rows.count
        try pool.write { db in
            for header in rows[..<analyzedAt] { try header.insert(db) }
        }
        if regime.analyzedShare != nil {
            try pool.write { db in try db.execute(sql: "ANALYZE") }
        }
        try pool.write { db in
            for header in rows[analyzedAt...] { try header.insert(db) }
            if regime == .noStatistics {
                try db.execute(sql: "DROP TABLE IF EXISTS sqlite_stat1")
                try db.execute(sql: "DROP TABLE IF EXISTS sqlite_stat4")
            }
        }
        return Fixture(pool: pool, directory: directory, path: path)
    }

    // MARK: - The window

    /// Reads on the window connections the moment the write queue hands the refresh its
    /// writer, i.e. after every earlier write committed and before the refresh's own write.
    private final class WindowProbe: Sendable {
        let path: String
        let reader: DatabaseQueue
        let opened = Mutex<DatabaseQueue?>(nil)
        let fired = Mutex<Int>(0)
        let failure = Mutex<String?>(nil)

        init(path: String, reader: DatabaseQueue) {
            self.path = path
            self.reader = reader
        }

        func readInWindow() {
            let first = fired.withLock { count in
                count += 1
                return count == 1
            }
            guard first else { return }
            do {
                _ = try DeferredIndexStatisticsTests.plans(reader)
                let queue = try DeferredIndexStatisticsTests.openReader(path)
                _ = try DeferredIndexStatisticsTests.plans(queue)
                opened.withLock { $0 = queue }
            } catch {
                failure.withLock { $0 = "\(error)" }
            }
        }
    }

    private static func indexStatistics(_ pool: DatabasePool, _ name: String) throws -> [String] {
        try pool.read { db in
            guard try db.tableExists("sqlite_stat1") else { return [] }
            return try String.fetchAll(db, sql: "SELECT stat FROM sqlite_stat1 WHERE idx = ?", arguments: [name])
        }
    }

    private static func indexExists(_ pool: DatabasePool, _ name: String) throws -> Bool {
        try pool.read { db in
            try Row.fetchOne(
                db, sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?", arguments: [name]) != nil
        }
    }

    private static func divergence(_ got: [String: String], _ converged: [String: String]) -> [String] {
        probes().map(\.name).filter { got[$0] != converged[$0] }.map { name in
            "\(name): \(got[name] ?? "nil") (converged: \(converged[name] ?? "nil"))"
        }
    }

    // MARK: - The census

    @Test("After the pass that builds a deferred index, every connection plans like a fresh one",
          arguments: TestIndex.allCases, Regime.allCases)
    func everyConnectionConverges(testIndex: TestIndex, regime: Regime) async throws {
        let fixture = try Self.makeFixture(regime)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let index = testIndex.index
        let markerKey = "deferredIndexStatistics-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: markerKey) }
        let dbPool = PrioritizedDatabase(pool: fixture.pool, priority: .background)

        // Both readers load the pre-pass schema and statistics now.
        let windowReader = try Self.openReader(fixture.path)
        let control = try Self.openReader(fixture.path)
        let window = WindowProbe(path: fixture.path, reader: windowReader)
        defer {
            try? window.opened.withLock { $0 }?.close()
            try? windowReader.close()
            try? control.close()
        }
        let before = try Self.plans(control)
        _ = try Self.plans(windowReader)
        let builtBeforePass = try Self.indexExists(fixture.pool, index.name)
        #expect(!builtBeforePass, "setup: the test index is not built yet")

        let label = Self.refreshWriteLabel
        await DatabaseWriteQueue.shared.setTestObserverForTesting { _, writeLabel in
            if writeLabel == label { window.readInWindow() }
        }
        let result = await SyncEngine.runRefreshPlannerStatisticsIfStale(
            dbPool: dbPool, markerKey: markerKey, indexes: SyncEngine.deferredIndexes + [index])
        await DatabaseWriteQueue.shared.setTestObserverForTesting(nil)

        let windowFailure = window.failure.withLock { $0 }
        let windowReads = window.fired.withLock { $0 }
        let windowConnection = window.opened.withLock { $0 }
        let built = try Self.indexExists(fixture.pool, index.name)
        let builtStatistics = try Self.indexStatistics(fixture.pool, index.name)
        #expect(result == .refreshed)
        #expect(windowFailure == nil, "the window read failed: \(windowFailure ?? "")")
        // Non-vacuity: the window connections did read inside the pass.
        #expect(windowReads >= 1, "the refresh's write never reached the write queue's observer")
        let openedInWindow = try #require(windowConnection, "no connection was opened in the window")
        #expect(built, "the pass did not build \(index.name)")
        #expect(!builtStatistics.isEmpty, "\(index.name) has no planner statistics after the pass")

        let fresh = try Self.openReader(fixture.path)
        defer { try? fresh.close() }
        let converged = try Self.plans(fresh)
        let connections: [(String, DatabaseQueue)] = [
            ("reader that read in the window", windowReader),
            ("connection opened in the window", openedInWindow),
            ("control reader", control),
        ]
        for (name, connection) in connections {
            let planned = try Self.plans(connection)
            let diverged = Self.divergence(planned, converged)
            #expect(diverged.isEmpty, """
                \(testIndex) / \(regime): the \(name) plans differently from a fresh connection after the pass:
                \(diverged.joined(separator: "\n"))
                """)
        }
        // Recorded for the report: which plans the new index and its statistics changed.
        let changed = Self.divergence(before, converged)
        print("[DeferredIndexStatisticsTests] \(testIndex) / \(regime): plans changed by the pass: \(changed.count)")
    }
}
