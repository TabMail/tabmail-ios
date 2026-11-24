/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// #1402: the storage prune's reads grew with the folder. The body pass paged a
/// folder with `LIMIT 50 OFFSET n` after counting the whole folder, so each page
/// stepped over every row before it; the header pass counted the whole folder
/// before every chunk of 50 headers it deleted. The body pass now pages after a
/// cursor in (prune key, `rowid`) order, and both passes ask only whether more than
/// the floor's rows are left, reading at most `floor + 1` index entries.
///
/// Pinned here:
/// - the same pages, in the same order, and the same stops as the former walk,
///   compared against that walk run on the same rows (ties in the prune key across
///   page boundaries, both orders, the storage check stopping after each page);
/// - the check's answer is a count of the rows after the cursor, for every cursor;
/// - every read seeks its order's index and never sorts, in the three statistics
///   states a device can hold;
/// - what a read costs, as pages fetched (pager cache hits plus misses, which is
///   deterministic): a page costs the same at the end of a large folder as at its
///   start, and the check costs the same in a large folder as in a small one. Each
///   cost test first shows the meter sees the former statement's cost grow.
///
/// The pass itself, `SyncEngine.runPruneIfOverBudget`, is pinned on its reads by
/// `StoragePrunePassReadTests`.
@Suite("Storage prune paging: the former pages and stops, each read bounded", .timeLimit(.minutes(2)))
struct StoragePrunePagingTests {
    private typealias Hold = StaleBodyEvictWriterHoldTests

    static let floor = StorageEstimator.floorPerFolder
    static let chunk = SyncConfig.pruneChunkSize

    /// Rows in the large folder of the cost tests: enough that the former walk's
    /// last page stepped over far more index pages than the slack below.
    static let largeFolder = 12_000

    /// Pages a read may vary by between the start and the end of a folder, or
    /// between a small folder and a large one (a range of index entries can
    /// straddle one more leaf). The former walk's last page in `largeFolder` rows
    /// stepped over about a hundred index pages more than its first.
    static let pageSlack = 10

    /// How much more a read that grows with the folder must cost in `largeFolder`
    /// rows (at the folder's end, or against a folder of 200 rows) for the meter to
    /// count as seeing the growth: three times the slack the bounded reads get.
    static let growthMargin = 3 * pageSlack

    /// The index each order seeks.
    static func indexName(_ mode: StaleWindowMode) -> String {
        switch mode {
        case .uid: return "messageHeader_folderId_uidInt"
        case .date: return "messageHeader_folderId_date"
        }
    }

    // MARK: - Fixture

    /// The pages each statement fetched on a reader connection, in the order they
    /// ran. The prune's reads run on the pool's readers, so the writer's deletes
    /// are not counted. A statement's pages are those its connection fetched since
    /// its previous statement ended (`.profile` fires when a statement ends).
    final class ReaderStatementMeter: Sendable {
        struct StatementPages: Sendable {
            let sql: String
            /// The statement with its arguments bound, to tell which folder it read.
            let expandedSQL: String
            let pages: Int

            /// A read of `messageHeader`: a page or a check (the pass's only reads).
            var readsHeaders: Bool { sql.lowercased().contains("messageheader") }
            var isCount: Bool { sql.lowercased().contains("count(") }
        }

        private struct State {
            var pagesAtLastStatement: [UInt: Int] = [:]
            var recorded: [StatementPages] = []
            var recording = false
        }

        private let state = Mutex(State())

        func install(on db: Database) {
            guard db.configuration.readonly, let handle = db.sqliteConnection else { return }
            let bits = UInt(bitPattern: handle)
            let opened = Hold.pagesSoFar(handle)
            state.withLock { $0.pagesAtLastStatement[bits] = opened }
            db.trace(options: .profile) { [self] event in
                guard case let .profile(statement, _) = event,
                      let handle = OpaquePointer(bitPattern: bits) else { return }
                let now = Hold.pagesSoFar(handle)
                let sql = statement.sql
                let expandedSQL = statement.expandedSQL
                state.withLock { state in
                    let pages = now - (state.pagesAtLastStatement[bits] ?? now)
                    state.pagesAtLastStatement[bits] = now
                    if state.recording {
                        state.recorded.append(StatementPages(sql: sql, expandedSQL: expandedSQL, pages: pages))
                    }
                }
            }
        }

        /// Runs `body` and returns the header reads it made on the readers.
        func headerReads<T>(_ body: () throws -> T) rethrows -> (result: T, reads: [StatementPages]) {
            state.withLock { $0.recording = true; $0.recorded = [] }
            defer { state.withLock { $0.recording = false } }
            let result = try body()
            return (result, state.withLock { $0.recorded }.filter(\.readsHeaders))
        }
    }

    struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let meter: ReaderStatementMeter
        let accountId = "prune-paging"

        func folderId(_ path: String) -> String {
            MessageIdentity.folderId(accountId: accountId, folderPath: path)
        }

        var database: PrioritizedDatabase { PrioritizedDatabase(pool: pool, priority: .background) }
    }

    /// A migrated pool with the deferred indexes, one account, an INBOX and an
    /// Archive, and a copy of the statistics the migrations left (kept in a
    /// temporary table on the writer). Readers stay open and are metered.
    static func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let meter = ReaderStatementMeter()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.automaticMemoryManagement = false
        configuration.persistentReadOnlyConnections = true
        configuration.prepareDatabase { db in meter.install(on: db) }
        let pool: DatabasePool
        do {
            pool = try DatabasePool(
                path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let fixture = Fixture(pool: pool, directory: directory, meter: meter)
        do {
            try AppDatabase.runMigrations(on: pool)
            try pool.write { db in
                var account = Account(
                    emailAddress: "\(fixture.accountId)@example.com", displayName: "T", provider: .imap)
                account.id = fixture.accountId
                try account.insert(db)
                try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: fixture.accountId).insert(db)
                try Folder(name: "Archive", path: "Archive", role: .archive, accountId: fixture.accountId).insert(db)
                try SyncEngine.createDeferredIndexes(db)
            }
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "CREATE TEMP TABLE migrationStatistics AS SELECT * FROM main.sqlite_stat1")
            }
        } catch {
            TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: directory)
            throw error
        }
        return fixture
    }

    /// Writes one header per row, in the order given, so `rowid` follows that
    /// order. Every other column is copied from one helper-written header, which
    /// is removed afterwards.
    static func seedHeaders(_ fixture: Fixture, path: String, rows: [(messageId: String, date: DatabaseValue)]) throws {
        try fixture.pool.write { db in
            let template = MessageHeader(
                messageId: "template", subject: "s", from: "sender@example.com",
                fromAddress: "sender@example.com", to: "user@example.com", date: Date(), snippet: "",
                folderId: fixture.folderId(path), accountId: fixture.accountId, folderPath: path,
                isInInbox: path == "INBOX")
            try template.insert(db)
            let columns = try db.columns(in: MessageHeader.databaseTableName).map(\.name)
            let computed: Set<String> = ["id", "messageId", "date"]
            let names = columns.map { "\"\($0)\"" }.joined(separator: ", ")
            let values = columns.map { computed.contains($0) ? ":\($0)" : "t.\"\($0)\"" }.joined(separator: ", ")
            let insert = try db.makeStatement(sql: """
                INSERT INTO messageHeader (\(names)) SELECT \(values) FROM messageHeader AS t WHERE t.id = :template
                """)
            for (index, row) in rows.enumerated() {
                try insert.execute(arguments: [
                    "id": "\(path)-\(index)-\(row.messageId)", "messageId": row.messageId,
                    "date": row.date, "template": template.id,
                ])
            }
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [template.id])
        }
    }

    /// A body for every header whose `rowid` is not a multiple of 5 (so a page's
    /// deletions are not simply its size), every earlier body removed.
    static func resetBodies(_ fixture: Fixture) throws {
        try fixture.pool.write { db in
            try db.execute(sql: "DELETE FROM messageBody")
            try db.execute(sql: """
                INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText)
                SELECT id, '<p>body</p>', NULL, ?, NULL FROM messageHeader WHERE rowid % 5 != 0
                """, arguments: [Date()])
        }
    }

    static func bodyIds(_ fixture: Fixture) throws -> Set<String> {
        try fixture.pool.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM messageBody")) }
    }

    /// A folder's rows, described in prune-key order and written in another order.
    struct Shape: Sendable, CustomTestStringConvertible {
        let mode: StaleWindowMode
        let count: Int
        /// Key positions that share one key (the first position's).
        let ties: [Range<Int>]
        /// The pages the former walk takes with the storage check always over.
        let pages: Int

        var testDescription: String {
            "\(mode), \(count) rows" + (ties.isEmpty ? "" : ", ties at \(ties.map { "\($0.lowerBound)..<\($0.upperBound)" }.joined(separator: " "))")
        }

        /// Whether some tie spans a page boundary.
        var tieSpansAPageBoundary: Bool {
            ties.contains { tie in (1..<max(pages, 1)).contains { tie.contains($0 * StoragePrunePagingTests.chunk - 1) && tie.contains($0 * StoragePrunePagingTests.chunk) } }
        }

        /// The rows, written with a stride coprime to `count`, so `rowid` order is
        /// not key order. The other order's column is shuffled as well.
        func rows(now: Date = Date()) -> [(messageId: String, date: DatabaseValue)] {
            guard count > 0 else { return [] }
            var keyed: [(messageId: String, date: DatabaseValue)] = []
            for position in 0..<count {
                let tie = ties.first { $0.contains(position) }
                let keyPosition = tie?.lowerBound ?? position
                let shuffled = (position * 37) % count
                switch mode {
                case .uid:
                    // `CAST(messageId AS INTEGER)` reads the leading digits, so a
                    // tie's members share a UID key under distinct message ids.
                    let messageId = tie == nil ? "\(1_000 + position)" : "\(1_000 + keyPosition)t\(position)"
                    keyed.append((messageId, now.addingTimeInterval(-Double(shuffled) * 60).databaseValue))
                case .date:
                    keyed.append(("g\(shuffled)", now.addingTimeInterval(-Double(count - keyPosition) * 60).databaseValue))
                }
            }
            return (0..<count).map { keyed[($0 * 7_919) % count] }
        }

        static let all: [Shape] = {
            let floor = StoragePrunePagingTests.floor
            let chunk = StoragePrunePagingTests.chunk
            return [
                Shape(mode: .uid, count: 0, ties: [], pages: 0),
                Shape(mode: .uid, count: floor, ties: [], pages: 0),
                // One page: the last page is whole, inside the floor.
                Shape(mode: .uid, count: floor + 1, ties: [], pages: 1),
                Shape(mode: .date, count: floor + 1, ties: [], pages: 1),
                Shape(mode: .uid, count: 3 * chunk + 17, ties: [(chunk - 4)..<(chunk + 3), (2 * chunk - 2)..<(2 * chunk + 3)], pages: 3),
                Shape(mode: .date, count: 3 * chunk + 17, ties: [(chunk - 4)..<(chunk + 3), (2 * chunk - 5)..<(2 * chunk + 6)], pages: 3),
                // Every row shares one date: every page boundary is inside the tie.
                Shape(mode: .date, count: 3 * chunk + 1, ties: [0..<(3 * chunk + 1)], pages: 3),
            ]
        }()
    }

    /// A storage check that is over the budget for its first `allowed` calls.
    final class ScriptedBudget {
        let allowed: Int
        private(set) var calls = 0

        init(allowed: Int) { self.allowed = allowed }

        func isOverBudget() -> Bool {
            calls += 1
            return calls <= allowed
        }
    }

    /// The body pass as it was before #1402, reading only: the pages it deleted the
    /// bodies of, in order. It deleted bodies alone, never headers, so its reads
    /// never depended on its own deletes.
    static func formerPages(
        _ db: Database, folderId: String, mode: StaleWindowMode, isOverBudget: () -> Bool
    ) throws -> [[String]] {
        let total = try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db)
        guard total > floor else { return [] }
        let pruneCount = total - floor
        var offset = 0
        var pages: [[String]] = []
        while offset < pruneCount, isOverBudget() {
            let ids = try String.fetchAll(db,
                MessageHeader
                    .select(Column("id"))
                    .filter(Column("folderId") == folderId)
                    .order(sql: SyncEngine.pruneOrderSQL(mode))
                    .limit(chunk, offset: offset)
            )
            guard !ids.isEmpty else { break }
            pages.append(ids)
            offset += ids.count
        }
        return pages
    }

    /// The folder's rows as cursors, in (prune key, `rowid`) order.
    static func cursors(_ db: Database, folderId: String, mode: StaleWindowMode) throws -> [SyncEngine.PruneCursor] {
        let key = SyncEngine.pruneKeySQL(mode)
        return try Row.fetchAll(
            db, sql: "SELECT rowid AS r, \(key) AS k FROM messageHeader WHERE folderId = ? ORDER BY \(key), rowid",
            arguments: [folderId]
        ).map { row in
            let key: DatabaseValue = row["k"]
            let rowId: Int64 = row["r"]
            return SyncEngine.PruneCursor(key: key, rowId: rowId)
        }
    }

    // MARK: - The former pages and stops

    @Test("The body pass deletes the former walk's bodies page by page and stops where it stopped",
          arguments: Shape.all)
    func theBodyPassTakesTheFormerPages(_ shape: Shape) throws {
        let fixture = try Self.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        try Self.seedHeaders(fixture, path: "Archive", rows: shape.rows())
        // Another folder of the account: the pass leaves its bodies alone.
        try Self.seedHeaders(fixture, path: "INBOX", rows: Shape(mode: shape.mode, count: 120, ties: [], pages: 2).rows())
        let folderId = fixture.folderId("Archive")

        let allPages = try fixture.pool.read { db in
            try Self.formerPages(db, folderId: folderId, mode: shape.mode, isOverBudget: { true })
        }
        #expect(allPages.count == shape.pages, "setup: the former walk takes \(allPages.count) pages, not \(shape.pages)")
        if !shape.ties.isEmpty {
            #expect(shape.tieSpansAPageBoundary, "setup: no tie spans a page boundary")
        }

        for allowed in 0...(allPages.count + 1) {
            try Self.resetBodies(fixture)
            let before = try Self.bodyIds(fixture)
            let formerBudget = ScriptedBudget(allowed: allowed)
            let pages = try fixture.pool.read { db in
                try Self.formerPages(db, folderId: folderId, mode: shape.mode, isOverBudget: formerBudget.isOverBudget)
            }
            let expectedDeleted = before.intersection(pages.flatMap { $0 })

            let budget = ScriptedBudget(allowed: allowed)
            let removed = SyncEngine.pruneFolderBodies(
                dbPool: fixture.database, folderId: folderId, mode: shape.mode,
                floor: Self.floor, chunkSize: Self.chunk, isOverBudget: budget.isOverBudget)
            let after = try Self.bodyIds(fixture)

            #expect(budget.calls == formerBudget.calls,
                    "over budget for \(allowed) checks: asked \(budget.calls) times, the former walk \(formerBudget.calls)")
            #expect(removed == expectedDeleted.count,
                    "over budget for \(allowed) checks: removed \(removed), the former walk \(expectedDeleted.count)")
            #expect(after == before.subtracting(expectedDeleted),
                    "over budget for \(allowed) checks: kept \(after.subtracting(before.subtracting(expectedDeleted)).count) the former walk deleted, deleted \(before.subtracting(expectedDeleted).subtracting(after).count) it kept")
        }
    }

    @Test("The check answers whether more than the floor's rows lie after the cursor, for every cursor",
          arguments: Shape.all)
    func theCheckCountsTheRowsAfterTheCursor(_ shape: Shape) throws {
        let fixture = try Self.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        try Self.seedHeaders(fixture, path: "Archive", rows: shape.rows())
        try Self.seedHeaders(fixture, path: "INBOX", rows: Shape(mode: shape.mode, count: 120, ties: [], pages: 2).rows())
        let folderId = fixture.folderId("Archive")

        let mismatches = try fixture.pool.read { db -> [String] in
            let cursors = try Self.cursors(db, folderId: folderId, mode: shape.mode)
            var mismatches: [String] = []
            if cursors.count != shape.count { mismatches.append("setup: \(cursors.count) rows, not \(shape.count)") }
            for floor in [0, 1, Self.floor] {
                let answer = try SyncEngine.pruneRowsBeyondFloor(
                    db, folderId: folderId, mode: shape.mode, after: nil, floor: floor)
                if answer != (cursors.count > floor) {
                    mismatches.append("floor \(floor), no cursor: \(answer)")
                }
                for (position, cursor) in cursors.enumerated() {
                    let answer = try SyncEngine.pruneRowsBeyondFloor(
                        db, folderId: folderId, mode: shape.mode, after: cursor, floor: floor)
                    if answer != (cursors.count - position - 1 > floor) {
                        mismatches.append("floor \(floor), cursor at \(position): \(answer)")
                    }
                }
            }
            return mismatches
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) wrong answers: \(mismatches.prefix(10))")
    }

    // MARK: - Plans

    /// The statistics a device can hold when the prune runs.
    enum Statistics: String, CaseIterable, Sendable {
        /// What `AppDatabase.runMigrations` leaves.
        case migrationLeft
        /// An empty `sqlite_stat1`, reloaded.
        case none
        /// A whole-database `ANALYZE` over the rows the test wrote.
        case fresh
    }

    static func apply(_ statistics: Statistics, to db: Database) throws {
        switch statistics {
        case .migrationLeft:
            try db.execute(sql: "DELETE FROM main.sqlite_stat1")
            try db.execute(sql: "INSERT INTO main.sqlite_stat1 SELECT * FROM temp.migrationStatistics")
            // Reloads the planner's statistics from the table.
            try db.execute(sql: "ANALYZE sqlite_schema")
        case .none:
            try db.execute(sql: "DELETE FROM main.sqlite_stat1")
            try db.execute(sql: "ANALYZE sqlite_schema")
        case .fresh:
            try db.execute(sql: "ANALYZE main")
        }
    }

    static func planLines(_ db: Database, sql: String, arguments: StatementArguments) throws -> [String] {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] as String }
    }

    @Test("Every prune read seeks its order's index and never sorts, in each statistics state",
          arguments: [StaleWindowMode.uid, .date], Statistics.allCases)
    func everyReadSeeksItsIndex(_ mode: StaleWindowMode, _ statistics: Statistics) throws {
        let fixture = try Self.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        try Self.seedHeaders(fixture, path: "Archive", rows: Shape(mode: mode, count: 5_000, ties: [], pages: 0).rows())
        try Self.seedHeaders(fixture, path: "INBOX", rows: Shape(mode: mode, count: 600, ties: [], pages: 0).rows())
        let folderId = fixture.folderId("Archive")
        let index = Self.indexName(mode)

        let plans = try fixture.pool.writeWithoutTransaction { db -> (statRows: Int, plans: [(String, [String])]) in
            try Self.apply(statistics, to: db)
            let statRows = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM main.sqlite_stat1 WHERE idx = ?", arguments: [index]) ?? -1
            let cursors = try Self.cursors(db, folderId: folderId, mode: mode)
            guard !cursors.isEmpty else { return (statRows, []) }
            let cursor = cursors[cursors.count / 2]
            var plans: [(String, [String])] = []
            for afterCursor in [false, true] {
                let pageArguments = SyncEngine.pruneArguments(
                    mode, folderId: folderId, cursor: afterCursor ? cursor : nil, limit: Self.chunk)
                let checkArguments = SyncEngine.pruneArguments(
                    mode, folderId: folderId, cursor: afterCursor ? cursor : nil, limit: Self.floor + 1)
                let label = afterCursor ? "after the cursor" : "first"
                plans.append(("page, \(label)", try Self.planLines(
                    db, sql: SyncEngine.prunePageSQL(mode, afterCursor: afterCursor), arguments: pageArguments)))
                plans.append(("check, \(label)", try Self.planLines(
                    db, sql: SyncEngine.pruneRemainderSQL(mode, afterCursor: afterCursor), arguments: checkArguments)))
            }
            return (statRows, plans)
        }

        switch statistics {
        case .fresh: #expect(plans.statRows == 1, "setup: ANALYZE wrote no row for \(index)")
        case .none: #expect(plans.statRows == 0, "setup: statistics left for \(index)")
        case .migrationLeft: break
        }
        let seek: String
        switch mode {
        case .uid: seek = "<expr>>?"
        case .date: seek = "(date,rowid)>(?,?)"
        }
        #expect(plans.plans.count == 4, "setup: \(plans.plans.count) plans read")
        for (name, lines) in plans.plans {
            let plan = lines.joined(separator: " | ")
            let headerLines = lines.filter { $0.contains("messageHeader") }
            let seeksIndex = headerLines.allSatisfy { $0.hasPrefix("SEARCH messageHeader USING") && $0.contains(index) }
            #expect(headerLines.count == 1, "\(name): \(plan)")
            #expect(seeksIndex, "\(name): not a seek on \(index): \(plan)")
            #expect(!plan.contains("TEMP B-TREE"), "\(name): sorts: \(plan)")
            if name.hasPrefix("check") {
                #expect(plan.contains("COVERING INDEX \(index)"), "\(name): reads header rows: \(plan)")
            }
            if name.hasSuffix("after the cursor") {
                #expect(plan.contains(seek), "\(name): does not seek past the cursor: \(plan)")
            }
        }
    }

    // MARK: - What a read costs

    static func average(_ values: some Collection<Int>) -> Double {
        values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
    }

    @Test("A body-pass page costs the same at the end of a large folder as at its start, and each check is bounded",
          arguments: [StaleWindowMode.uid, .date])
    func aPageCostsTheSameWhereverItLies(_ mode: StaleWindowMode) throws {
        let fixture = try Self.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        try Self.seedHeaders(fixture, path: "Archive", rows: Shape(mode: mode, count: Self.largeFolder, ties: [], pages: 0).rows())
        try Self.seedHeaders(fixture, path: "INBOX", rows: Shape(mode: mode, count: 200, ties: [], pages: 0).rows())

        // The same check in a small folder, once to open and warm the reader.
        let small: () throws -> (result: Bool, reads: [ReaderStatementMeter.StatementPages]) = {
            try fixture.meter.headerReads {
                try fixture.pool.read { db in
                    try SyncEngine.pruneRowsBeyondFloor(
                        db, folderId: fixture.folderId("INBOX"), mode: mode, after: nil, floor: Self.floor)
                }
            }
        }
        _ = try small()
        let smallCheck = try small()
        let smallCheckPages = smallCheck.reads.map(\.pages).reduce(0, +)

        // Non-vacuity: the meter sees a read that grows with the folder. The page
        // the pass read before #1402 (`LIMIT ? OFFSET ?`) costs more at the
        // folder's end than at its start, because it steps over every row before it.
        func formerPage(offset: Int) throws -> Int {
            try fixture.meter.headerReads {
                try fixture.pool.read { db in
                    try String.fetchAll(db,
                        MessageHeader
                            .select(Column("id"))
                            .filter(Column("folderId") == fixture.folderId("Archive"))
                            .order(sql: SyncEngine.pruneOrderSQL(mode))
                            .limit(Self.chunk, offset: offset)
                    )
                }
            }.reads.map(\.pages).reduce(0, +)
        }
        let formerFirst = try formerPage(offset: 0)
        let formerLast = try formerPage(offset: Self.largeFolder - Self.chunk)
        #expect(formerLast - formerFirst > Self.growthMargin,
                "setup: the meter does not see the former page grow: \(formerFirst) pages at the folder's start, \(formerLast) at its end")

        let run = fixture.meter.headerReads {
            SyncEngine.pruneFolderBodies(
                dbPool: fixture.database, folderId: fixture.folderId("Archive"), mode: mode,
                floor: Self.floor, chunkSize: Self.chunk, isOverBudget: { true })
        }
        let pages = run.reads.filter { !$0.isCount }.map(\.pages)
        let checks = run.reads.filter(\.isCount).map(\.pages)

        let expectedPages = (Self.largeFolder - Self.floor + Self.chunk - 1) / Self.chunk
        #expect(smallCheck.result && smallCheck.reads.count == 1, "setup: the small folder's check: \(smallCheck)")
        #expect(pages.count == expectedPages, "the pass read \(pages.count) pages, not \(expectedPages)")
        guard pages.count >= 20 else { return }
        let first = Self.average(pages.prefix(10))
        let last = Self.average(pages.suffix(10))
        #expect(last - first <= Double(Self.pageSlack),
                "a page at the folder's end fetched \(last) pages on average, at its start \(first)")
        let costliestCheck = checks.max() ?? 0
        #expect(!checks.isEmpty, "setup: the pass made no check")
        #expect(costliestCheck <= smallCheckPages + Self.pageSlack,
                "a check fetched up to \(costliestCheck) pages; in a folder of 200 rows it fetches \(smallCheckPages)")
    }

    /// The check alone. That the header pass asks it before each chunk, and reads
    /// nothing else that grows, is pinned on the pass itself by
    /// `StoragePrunePassReadTests`.
    @Test("The remainder check costs the same in a large folder as in a small one",
          arguments: [StaleWindowMode.uid, .date])
    func theCheckCostsTheSameWhateverTheFolderSize(_ mode: StaleWindowMode) throws {
        let fixture = try Self.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        try Self.seedHeaders(fixture, path: "Archive", rows: Shape(mode: mode, count: Self.largeFolder, ties: [], pages: 0).rows())
        try Self.seedHeaders(fixture, path: "INBOX", rows: Shape(mode: mode, count: 200, ties: [], pages: 0).rows())

        func check(_ path: String) throws -> (answer: Bool, pages: Int, reads: Int) {
            let measured = try fixture.meter.headerReads {
                try fixture.pool.read { db in
                    try SyncEngine.pruneRowsBeyondFloor(
                        db, folderId: fixture.folderId(path), mode: mode, after: nil, floor: Self.floor)
                }
            }
            return (measured.result, measured.reads.map(\.pages).reduce(0, +), measured.reads.count)
        }
        _ = try check("INBOX")
        let small = try check("INBOX")
        let large = try check("Archive")

        // Non-vacuity: the meter sees a read that grows with the folder. The count
        // the pass made before #1402 reads every entry of the folder.
        func formerCount(_ path: String) throws -> Int {
            try fixture.meter.headerReads {
                try fixture.pool.read { db in
                    try MessageHeader.filter(Column("folderId") == fixture.folderId(path)).fetchCount(db)
                }
            }.reads.map(\.pages).reduce(0, +)
        }
        let formerSmall = try formerCount("INBOX")
        let formerLarge = try formerCount("Archive")
        #expect(formerLarge - formerSmall > Self.growthMargin,
                "setup: the meter does not see the former count grow: \(formerLarge) pages in \(Self.largeFolder) rows, \(formerSmall) in 200")

        #expect(small.answer && large.answer && small.reads == 1 && large.reads == 1,
                "setup: small \(small), large \(large)")
        #expect(large.pages <= small.pages + Self.pageSlack,
                "the check fetched \(large.pages) pages in \(Self.largeFolder) rows, \(small.pages) in 200")
    }
}
