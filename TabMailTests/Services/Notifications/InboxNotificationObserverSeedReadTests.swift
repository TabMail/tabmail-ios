/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// The mail a differential case holds. File scope: a test's arguments cannot name a member of the suite type they
/// are attached to.
enum InboxSeedDataShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case empty
    case oneRow
    /// One message id in two folders of one account and in another account's inbox, and inbox rows sharing one
    /// date: ties on the keys of both the replaced index and the new one.
    case ties
    case severalAccounts
    /// About 100,000 rows over three accounts, two of three in the inbox.
    case large

    var testDescription: String { rawValue }
}

/// The planner statistics a differential case runs under.
enum InboxSeedStatistics: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// No `sqlite_stat1` at all.
    case unanalyzed
    /// The maintenance pass's `ANALYZE` ran with the mail present (an upgraded device).
    case analyzedWithMail
    /// The pass's `ANALYZE` ran on an empty table and the mail arrived afterwards (a fresh install).
    case analyzedBeforeMail

    var testDescription: String { rawValue }
}

/// The launch seed of `InboxNotificationObserver` (#1385). It runs at every database open, inside the write that
/// registers the observer, and reads `rowid, accountId, messageId` of every inbox row. Through the plain
/// `(isInInbox, date)` index that is one index entry plus one table row per inbox message. The deferred index
/// `messageHeader_inboxMembers` (`SyncEngine.deferredIndexes`) holds exactly the inbox rows and carries both columns,
/// so once the background maintenance pass has built it and refreshed the planner statistics, the seed reads that
/// index alone.
///
/// The seed's statement is not pinned with `INDEXED BY` (the index is absent until the pass runs), so the planner
/// must choose the index. These tests record the statements the real `seed` runs, with `Database.trace` on a database
/// built by the production migrations, and plan each one.
///
/// - The plan tests reproduce the pass by its two steps (the production DDL `SyncEngine.createDeferredIndexes`, then a
///   whole-database `ANALYZE`) in three states, and fail on the code before #1385 (no such index).
/// - The real-pass test drives `SyncEngine.runWALMaintenance` itself, so the seed's plan depends on the production
///   pass really building the index and really refreshing the statistics, and a second pass doing neither again.
/// - The differential test keeps the replaced read as an oracle: the seed's statement through
///   `messageHeader_isInInbox_date`, the plan every launch before #1385 had, and requires the same rows from the seed's
///   statement as it runs now, over five shapes of mail and three statistics states.
///
/// Serialized and process-global: the real pass refreshes the statistics under a process-wide single-flight latch
/// and records it in the standard defaults.
@Suite("The inbox notification seed reads only the inbox-members index once the maintenance pass has run",
       .serialized, .processGlobalState)
struct InboxNotificationObserverSeedReadTests {

    /// The SQL the connection ran. `trace` fires on the queue's own thread, hence the `Mutex`.
    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        var all: [String] { statements.withLock { $0 } }
        func clear() { statements.withLock { $0.removeAll() } }
    }

    /// Records each cleared `accountId/messageId`.
    private final class ClearRecorder: Sendable {
        private let calls = Mutex<[String]>([])
        func record(_ accountId: String, _ messageId: String) { calls.withLock { $0.append("\(accountId)/\(messageId)") } }
        var all: [String] { calls.withLock { $0 } }
    }

    /// When the maintenance pass ran relative to the mail.
    enum Regime: String, CaseIterable, CustomTestStringConvertible {
        /// An upgraded device: the mail is there when the pass builds the index and analyzes it.
        case upgraded
        /// A fresh install: the pass runs on an empty table, and the mail arrives afterwards.
        case freshInstall
        /// Every message is in an inbox, so the index holds the whole table.
        case everythingInInbox

        var testDescription: String { rawValue }
    }

    private static let index = "messageHeader_inboxMembers"

    /// The seed's read as every launch before #1385 ran it: the same statement through the plain `(isInInbox, date)`
    /// index. The differential test's oracle.
    private static let replacedSeedRead = """
        SELECT rowid, accountId, messageId
        FROM messageHeader INDEXED BY messageHeader_isInInbox_date
        WHERE isInInbox = 1
        """

    private static let largeCount = 100_000

    /// A database built by the production migrations (so it carries the statistics the migration chain leaves),
    /// traced into `tape`.
    private static func makeDatabase(trace tape: SQLTape) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
        }
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.runMigrations(on: queue)
        try TestDatabase.insertAccount(queue, id: "acc1", email: "one@example.com")
        try TestDatabase.insertAccount(queue, id: "acc2", email: "two@example.com")
        return queue
    }

    /// The same, on disk: `PrioritizedDatabase` wraps a `DatabasePool`, and a pool needs a file. Three accounts.
    private static func makePool(trace tape: SQLTape) throws -> (pool: DatabasePool, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inboxSeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
        }
        let pool = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path, configuration: config)
        try AppDatabase.runMigrations(on: pool)
        try pool.write { db in
            for (id, email) in [("acc1", "one@example.com"), ("acc2", "two@example.com"), ("acc3", "three@example.com")] {
                var account = Account(emailAddress: email, displayName: "Test", provider: .gmail)
                account.id = id
                try account.insert(db)
            }
        }
        return (pool, directory)
    }

    /// Two accounts' mail, in the inbox and (unless `allInInbox`) in another folder. Returns the
    /// `accountId/messageId` of every inbox row.
    private static func insertMail(_ queue: DatabaseQueue, allInInbox: Bool) throws -> Set<String> {
        var inbox: Set<String> = []
        for (account, messageId, path) in [
            ("acc1", "1", "INBOX"), ("acc1", "2", "INBOX"), ("acc1", "3", "Archive"),
            ("acc2", "1", "INBOX"), ("acc2", "7", "Archive"), ("acc2", "8", "INBOX"),
        ] {
            let folder = allInInbox ? "INBOX" : path
            try TestDatabase.insertMessageHeader(
                queue, messageId: messageId, folderId: "\(account):\(folder)", accountId: account,
                folderPath: folder, isInInbox: folder == "INBOX")
            if folder == "INBOX" { inbox.insert("\(account)/\(messageId)") }
        }
        return inbox
    }

    private static func insertHeader(_ db: Database, account: String, messageId: String, folder: String, date: Date) throws {
        let header = MessageHeader(
            messageId: messageId, subject: "Seed", from: "sender@example.com", fromAddress: "sender@example.com",
            to: "recipient@example.com", date: date, snippet: "",
            folderId: "\(account):\(folder)", accountId: account, folderPath: folder, isInInbox: folder == "INBOX")
        try header.insert(db)
    }

    /// The folder of generated row `n`: two of every three in the inbox.
    private static func generatedFolder(_ n: Int) -> String { (n / 3) % 3 == 2 ? "Archive" : "INBOX" }

    /// `count` headers written by one statement from a template row: accounts `acc1` to `acc3` in turn, folders by
    /// `generatedFolder`, and dates in runs of five, so the replaced index's `(isInInbox, date)` key ties.
    private static func insertGenerated(_ db: Database, count: Int) throws {
        try insertHeader(db, account: "acc1", messageId: "template", folder: "Archive", date: Date())
        let template = db.lastInsertedRowID
        let generated: [String: String] = [
            "id": "g.a || ':' || g.f || ':' || g.m",
            "messageId": "g.m",
            "accountId": "g.a",
            "folderId": "g.a || ':' || g.f",
            "folderPath": "g.f",
            "isInInbox": "g.f = 'INBOX'",
            "date": "strftime('%Y-%m-%d %H:%M:%f', t.date, '-' || (g.n / 5) || ' minutes')",
        ]
        let columns = try db.columns(in: MessageHeader.databaseTableName).map(\.name)
        let names = columns.map { "\"\($0)\"" }.joined(separator: ", ")
        let values = columns.map { generated[$0] ?? "t.\"\($0)\"" }.joined(separator: ", ")
        try db.execute(
            sql: """
            WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < ?),
            g AS (
                SELECT n, 'acc' || (1 + n % 3) AS a,
                       CASE WHEN (n / 3) % 3 = 2 THEN 'Archive' ELSE 'INBOX' END AS f,
                       'g' || n AS m
                FROM seq
            )
            INSERT INTO messageHeader (\(names))
            SELECT \(values) FROM messageHeader AS t, g WHERE t.rowid = ?
            """,
            arguments: [count, template])
        try db.execute(sql: "DELETE FROM messageHeader WHERE rowid = ?", arguments: [template])
    }

    /// Writes `shape`'s mail. Returns how many inbox rows it wrote.
    private static func insertMail(_ pool: DatabasePool, shape: InboxSeedDataShape) throws -> Int {
        let now = Date()
        switch shape {
        case .empty:
            return 0
        case .oneRow:
            try pool.write { db in try insertHeader(db, account: "acc1", messageId: "1", folder: "INBOX", date: now) }
            return 1
        case .ties:
            let rows = [
                ("acc1", "1", "INBOX"), ("acc1", "1", "Archive"), ("acc2", "1", "INBOX"),
                ("acc1", "2", "INBOX"), ("acc2", "2", "Archive"), ("acc3", "2", "INBOX"),
            ]
            try pool.write { db in
                for (account, messageId, folder) in rows {
                    try insertHeader(db, account: account, messageId: messageId, folder: folder, date: now)
                }
            }
            return rows.filter { $0.2 == "INBOX" }.count
        case .severalAccounts:
            var inbox = 0
            try pool.write { db in
                for (offset, account) in ["acc1", "acc2", "acc3"].enumerated() {
                    for message in 1...6 {
                        let folder = message % 3 == 0 ? "Archive" : "INBOX"
                        let date = now.addingTimeInterval(-Double(offset * 100 + message) * 60)
                        try insertHeader(db, account: account, messageId: "\(message)", folder: folder, date: date)
                        if folder == "INBOX" { inbox += 1 }
                    }
                }
            }
            return inbox
        case .large:
            try pool.write { db in try insertGenerated(db, count: largeCount) }
            return (1...largeCount).filter { generatedFolder($0) == "INBOX" }.count
        }
    }

    /// The maintenance pass's two steps, in its order: build the deferred indexes, then analyze.
    private static func runMaintenancePass(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try SyncEngine.createDeferredIndexes(db)
            try db.execute(sql: "ANALYZE")
        }
    }

    /// Seeds an observer on `writer` and registers it, as `AppDatabase` does at every open.
    private static func wire(_ writer: some DatabaseWriter, recorder: ClearRecorder) throws -> InboxNotificationObserver {
        let observer = InboxNotificationObserver(clear: { accountId, messageId in recorder.record(accountId, messageId) })
        try writer.write { db in
            try observer.seed(db)
            db.add(transactionObserver: observer)
        }
        return observer
    }

    /// The statements on `messageHeader` the seed ran: everything `tape` recorded from a clear to the seed's end.
    private static func seedStatements(_ tape: SQLTape) -> [String] {
        tape.all.filter { $0.localizedCaseInsensitiveContains("messageHeader") }
    }

    private static func plan(_ sql: String, in reader: some DatabaseReader) throws -> [String] {
        try reader.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
        }
    }

    /// What breaks the rule in `sql`'s plan: anything but a covering read of the inbox-members index.
    /// Empty when the plan keeps the rule.
    private static func violations(_ sql: String, in reader: some DatabaseReader) throws -> [String] {
        let plan = try plan(sql, in: reader)
        let covering = "USING COVERING INDEX \(index)"
        var broken = plan.filter { !$0.contains(covering) }
        if !plan.contains(where: { $0.contains(covering) }) {
            broken.append("no covering read of \(index) in \(plan)")
        }
        return broken
    }

    private static func indexExists(_ reader: some DatabaseReader) throws -> Bool {
        try reader.read { db in
            try Row.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
                             arguments: [index]) != nil
        }
    }

    /// `rowid/accountId/messageId` of every row `sql` returns, by rowid: the seed keeps its rows in a map keyed by
    /// rowid, and its statement has no ORDER BY, so the rows, not their order, are what it holds.
    private static func seededRows(_ sql: String, in reader: some DatabaseReader) throws -> [String] {
        try reader.read { db in
            try Row.fetchAll(db, sql: sql)
                .map { row -> (Int64, String) in
                    let rowid: Int64 = row["rowid"]
                    let accountId: String = row["accountId"]
                    let messageId: String = row["messageId"]
                    return (rowid, "\(rowid)/\(accountId)/\(messageId)")
                }
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    @Test("After the maintenance pass the seed's every statement is a covering read of the inbox-members index",
          arguments: Regime.allCases)
    func seedReadsOnlyTheInboxMembersIndex(regime: Regime) throws {
        let tape = SQLTape()
        let queue = try Self.makeDatabase(trace: tape)
        let inbox: Set<String>
        switch regime {
        case .upgraded:
            inbox = try Self.insertMail(queue, allInInbox: false)
            try Self.runMaintenancePass(queue)
        case .freshInstall:
            try Self.runMaintenancePass(queue)
            inbox = try Self.insertMail(queue, allInInbox: false)
        case .everythingInInbox:
            inbox = try Self.insertMail(queue, allInInbox: true)
            try Self.runMaintenancePass(queue)
        }
        let built = try Self.indexExists(queue)
        #expect(built, "precondition: the pass built \(Self.index)")
        tape.clear()

        let recorder = ClearRecorder()
        let observer = try Self.wire(queue, recorder: recorder)
        let reads = Self.seedStatements(tape)
        #expect(reads.count == 1, "precondition: the seed ran one statement on messageHeader (\(tape.all))")

        var broken: [String] = []
        for sql in reads {
            let lines = try Self.violations(sql, in: queue)
            if !lines.isEmpty { broken.append("\(lines) by \(sql)") }
        }
        #expect(broken.isEmpty, "\(regime): the seed read more than the inbox-members index: \(broken)")

        // The rows it read are the inbox: each is cleared once when it leaves, and nothing else is.
        try queue.write { db in try db.execute(sql: "DELETE FROM messageHeader") }
        #expect(Set(recorder.all) == inbox, "\(regime): the seed's map is not the inbox: \(recorder.all)")
        #expect(recorder.all.count == inbox.count, "\(regime): an inbox row was cleared twice: \(recorder.all)")
        withExtendedLifetime(observer) {}
    }

    @Test("Negative control: before the pass, the same seed statement breaks the rule and still reads the inbox")
    func beforeThePassTheSeedBreaksTheRule() throws {
        let tape = SQLTape()
        let queue = try Self.makeDatabase(trace: tape)
        let inbox = try Self.insertMail(queue, allInInbox: false)
        let built = try Self.indexExists(queue)
        #expect(!built, "precondition: the migration chain alone does not build \(Self.index)")
        tape.clear()

        let recorder = ClearRecorder()
        let observer = try Self.wire(queue, recorder: recorder)
        let reads = Self.seedStatements(tape)
        #expect(reads.count == 1, "precondition: the seed ran one statement on messageHeader (\(tape.all))")
        for sql in reads {
            let lines = try Self.violations(sql, in: queue)
            #expect(!lines.isEmpty, "the rule must catch the seed's plan without the index; it broke nothing: \(sql)")
        }

        // The window the deferral accepts is slower, not different: the seed still holds exactly the inbox.
        try queue.write { db in try db.execute(sql: "UPDATE messageHeader SET isInInbox = 0") }
        #expect(Set(recorder.all) == inbox, "the seed before the pass did not see exactly the inbox: \(recorder.all)")
        withExtendedLifetime(observer) {}
    }

    @Test("The real maintenance pass builds the index and refreshes the statistics, so the seed reads only the index; a second pass does neither again")
    func theRealMaintenancePassGivesTheSeedItsIndex() async throws {
        let tape = SQLTape()
        let (pool, directory) = try Self.makePool(trace: tape)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: directory) }
        let inboxCount = try Self.insertMail(pool, shape: .severalAccounts)
        let builtBefore = try Self.indexExists(pool)
        #expect(!builtBefore, "precondition: the migration chain alone does not build \(Self.index)")
        let running = !DatabaseSuspension.isSuspended
        try #require(running, "precondition: the pass runs only while the database is not suspended")

        // The pass records its statistics refresh in the standard defaults. Start it stale, and leave it as found.
        let defaults = UserDefaults.standard
        let markerKey = SyncEngine.plannerStatisticsSchemaVersionKey
        let savedMarker = defaults.object(forKey: markerKey)
        defaults.removeObject(forKey: markerKey)
        defer {
            if let savedMarker { defaults.set(savedMarker, forKey: markerKey) } else { defaults.removeObject(forKey: markerKey) }
        }
        let dbPool = PrioritizedDatabase(pool: pool, priority: .background)

        await SyncEngine.runWALMaintenance(dbPool: dbPool, includePrune: false, undoProtectedBodyIds: [], pruneOrder: [:])

        let builtAfter = try Self.indexExists(pool)
        #expect(builtAfter, "the pass did not build \(Self.index)")
        let (schemaVersion, analyzedRows) = try await pool.read { db -> (Int?, Int) in
            let version = try Int.fetchOne(db, sql: "PRAGMA schema_version")
            let rows = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM sqlite_stat1 WHERE idx = ?", arguments: [Self.index]) ?? 0
            return (version, rows)
        }
        let marker = defaults.object(forKey: markerKey) as? Int
        #expect(marker != nil && marker == schemaVersion,
                "the pass's statistics refresh did not settle on the schema with the index (marker \(String(describing: marker)), schema \(String(describing: schemaVersion)))")
        #expect(analyzedRows == 1, "the pass's ANALYZE did not record \(Self.index) (\(analyzedRows) rows)")

        tape.clear()
        let recorder = ClearRecorder()
        let observer = try Self.wire(pool, recorder: recorder)
        let reads = Self.seedStatements(tape)
        #expect(reads.count == 1, "precondition: the seed ran one statement on messageHeader (\(tape.all))")
        var broken: [String] = []
        for sql in reads {
            let lines = try Self.violations(sql, in: pool)
            if !lines.isEmpty { broken.append("\(lines) by \(sql)") }
        }
        #expect(broken.isEmpty, "after the real pass the seed read more than the inbox-members index: \(broken)")
        guard let seedRead = reads.first else { return }
        let rows = try Self.seededRows(seedRead, in: pool)
        #expect(rows.count == inboxCount, "the seed's statement read \(rows.count) rows for \(inboxCount) inbox messages")

        // The pass converged: a second one builds nothing and analyzes nothing.
        tape.clear()
        await SyncEngine.runWALMaintenance(dbPool: dbPool, includePrune: false, undoProtectedBodyIds: [], pruneOrder: [:])
        let second = tape.all
        let rebuilt = second.filter { $0.uppercased().contains("CREATE INDEX") }
        let reanalyzed = second.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("ANALYZE") }
        #expect(rebuilt.isEmpty, "the second pass built an index again: \(rebuilt)")
        #expect(reanalyzed.isEmpty, "the second pass ran ANALYZE again: \(reanalyzed)")
        withExtendedLifetime(observer) {}
    }

    @Test("Differential: the seed's statement returns exactly the rows the replaced read returns",
          arguments: InboxSeedDataShape.allCases, InboxSeedStatistics.allCases)
    func seedReturnsTheReplacedReadsRows(shape: InboxSeedDataShape, statistics: InboxSeedStatistics) async throws {
        let tape = SQLTape()
        let (pool, directory) = try Self.makePool(trace: tape)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: directory) }
        let dbPool = PrioritizedDatabase(pool: pool, priority: .background)
        let markerKey = "inboxSeedDifferential-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: markerKey) }

        // The production build step, and the production statistics refresh under a private marker.
        let inboxCount: Int
        switch statistics {
        case .unanalyzed:
            inboxCount = try Self.insertMail(pool, shape: shape)
            let build = await SyncEngine.runBuildDeferredIndexesIfMissing(dbPool: dbPool)
            #expect(build == .built, "precondition: the build step built the deferred indexes (\(build))")
            try await pool.write { db in try db.execute(sql: "DROP TABLE IF EXISTS sqlite_stat1") }
        case .analyzedWithMail:
            inboxCount = try Self.insertMail(pool, shape: shape)
            let build = await SyncEngine.runBuildDeferredIndexesIfMissing(dbPool: dbPool)
            #expect(build == .built, "precondition: the build step built the deferred indexes (\(build))")
            let refresh = await SyncEngine.runRefreshPlannerStatisticsIfStale(dbPool: dbPool, markerKey: markerKey)
            #expect(refresh == .refreshed, "precondition: the statistics refresh ran (\(refresh))")
        case .analyzedBeforeMail:
            let build = await SyncEngine.runBuildDeferredIndexesIfMissing(dbPool: dbPool)
            #expect(build == .built, "precondition: the build step built the deferred indexes (\(build))")
            let refresh = await SyncEngine.runRefreshPlannerStatisticsIfStale(dbPool: dbPool, markerKey: markerKey)
            #expect(refresh == .refreshed, "precondition: the statistics refresh ran (\(refresh))")
            inboxCount = try Self.insertMail(pool, shape: shape)
        }
        let built = try Self.indexExists(pool)
        #expect(built, "precondition: the build step built \(Self.index)")
        let hasStatistics = try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE name = 'sqlite_stat1'") != nil
        }
        #expect(hasStatistics == (statistics != .unanalyzed), "precondition: sqlite_stat1 present only when analyzed")

        tape.clear()
        let recorder = ClearRecorder()
        let observer = try Self.wire(pool, recorder: recorder)
        let reads = Self.seedStatements(tape)
        #expect(reads.count == 1, "precondition: the seed ran one statement on messageHeader (\(tape.all))")
        guard let seedRead = reads.first else { return }

        let seeded = try Self.seededRows(seedRead, in: pool)
        let oracle = try Self.seededRows(Self.replacedSeedRead, in: pool)
        #expect(oracle.count == inboxCount, "precondition: the oracle read \(oracle.count) rows for \(inboxCount) inbox messages")
        #expect(seeded == oracle, "\(shape), \(statistics): the seed's rows differ from the replaced read's (\(seeded.count) vs \(oracle.count))")

        // The oracle really is the replaced plan, so the comparison is between two different reads where the
        // optimization applies: an upgraded or fresh-install mailbox of realistic size, analyzed by the pass.
        let oraclePlan = try Self.plan(Self.replacedSeedRead, in: pool)
        #expect(oraclePlan.contains { $0.contains("messageHeader_isInInbox_date") },
                "precondition: the oracle reads the replaced index: \(oraclePlan)")
        if shape == .large && statistics != .unanalyzed {
            let lines = try Self.violations(seedRead, in: pool)
            #expect(lines.isEmpty, "\(statistics): the seed's statement did not read only \(Self.index): \(lines)")
        }
        withExtendedLifetime(observer) {}
    }
}
