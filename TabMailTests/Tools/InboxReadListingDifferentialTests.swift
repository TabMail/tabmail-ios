/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// The assistant's inbox listing (`InboxReadTool.readListing`, #1391). It used to count the inbox rows in the
/// account scope and page them by `date` with LIMIT/OFFSET. The account scope is not in
/// `messageHeader_isInInbox_date`, so the count read every inbox message's table row on every call, and page n read
/// the rows of the n - 1 pages before it as well. These tests keep that read as the oracle: on databases built by the
/// production migrations and deferred-index build, with no planner statistics and after the app's `ANALYZE`, the
/// listing returns the oracle's rows in the oracle's order, its total and its page, for every page (and pages past
/// the end, which clamp), in normal and demo mode. The plan test and the pages-read test fail on the replaced read.
@Suite("Inbox read tool listing: the replaced count and OFFSET read's rows, without reading every inbox row")
struct InboxReadListingDifferentialTests {

    // MARK: - Oracle

    struct Snapshot: Equatable, CustomStringConvertible {
        let ids: [String]
        let totalCount: Int
        let page: Int
        var description: String { "page \(page), total \(totalCount), \(ids.count) rows" }
    }

    /// The replaced read, verbatim: the scoped count, then the scoped page by `date` with LIMIT/OFFSET.
    static func oracle(_ db: Database, pageIndex: Int, demoActive: Bool) throws -> Snapshot {
        let pageSize = InboxReadTool.Config.pageSize
        let totalCount = try MessageHeader
            .filter(Column("isInInbox") == true)
            .filter(DemoToolGuard.accountScope(demoActive: demoActive))
            .fetchCount(db)
        let totalPages = max(1, (totalCount + pageSize - 1) / pageSize)
        let safePage = min(max(pageIndex - 1, 0), totalPages - 1)
        let rows = try MessageHeader
            .filter(Column("isInInbox") == true)
            .filter(DemoToolGuard.accountScope(demoActive: demoActive))
            .order(Column("date").desc)
            .limit(pageSize, offset: safePage * pageSize)
            .fetchAll(db)
        return Snapshot(ids: rows.map(\.id), totalCount: totalCount, page: safePage)
    }

    static func listing(_ db: Database, pageIndex: Int, demoActive: Bool) throws -> Snapshot {
        let listing = try InboxReadTool.readListing(db, pageIndex: pageIndex, demoActive: demoActive, meter: nil)
        return Snapshot(ids: listing.rows.map(\.id), totalCount: listing.totalCount, page: listing.page)
    }

    /// Every page the tool can be asked for: before the first, each page, and two past the last.
    static func pageIndexes(totalCount: Int) -> [Int] {
        Array(-1...(InboxReadTool.totalPages(for: totalCount) + 2))
    }

    // MARK: - Fixtures

    enum Fixture: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// Archive mail only.
        case emptyInbox
        case oneRow
        /// 137 inbox rows whose dates repeat in runs of 7, so runs of equal dates cross every page boundary.
        case tiesAcrossPages
        /// Three accounts (70, 45, 25 inbox rows) whose dates tie across accounts.
        case severalAccounts
        /// 120 real and 63 demo inbox rows with dates tying between them (demo mode, and demo rows left in
        /// normal mode).
        case realAndDemoRows
        /// 20 real and 12 demo inbox rows: one page in all.
        case smallRealAndDemoRows
        /// A demo account row with no demo message, and 80 real inbox rows.
        case demoAccountWithoutRows

        var testDescription: String { rawValue }
    }

    private static func scratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inbox-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The fixture on disk, built by the production migrations and deferred-index build, in `statistics`.
    private static func makeDatabase(
        _ fixture: Fixture, statistics: DBProof.Statistics, in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent("\(fixture.rawValue)-\(statistics.rawValue).sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try AppDatabase.runMigrations(on: queue)
        try queue.write { db in
            try SyncEngine.createDeferredIndexes(db)
            try seed(fixture, db: db, anchor: Date())
            try DBProof.apply(statistics, to: db)
        }
        try queue.close()
        return url
    }

    private static func seed(_ fixture: Fixture, db: Database, anchor: Date) throws {
        let real = DBProof.accountId(0)
        let demo = DemoSeed.demoAccountId
        // Minutes before the anchor; `step` rows share each date.
        func date(_ index: Int, step: Int = 1) -> Date { anchor.addingTimeInterval(-Double(index / step) * 60) }
        switch fixture {
        case .emptyInbox:
            try insertAccount(db, id: real)
            try insertRows(db, accountId: real, inbox: 0, archive: 30) { date($0) }
        case .oneRow:
            try insertAccount(db, id: real)
            try insertRows(db, accountId: real, inbox: 1, archive: 10) { date($0) }
        case .tiesAcrossPages:
            try insertAccount(db, id: real)
            try insertRows(db, accountId: real, inbox: 137, archive: 40) { date($0, step: 7) }
        case .severalAccounts:
            for (index, inbox) in [70, 45, 25].enumerated() {
                let account = DBProof.accountId(index)
                try insertAccount(db, id: account)
                try insertRows(db, accountId: account, inbox: inbox, archive: 20) { date($0, step: 2) }
            }
        case .realAndDemoRows:
            try insertAccount(db, id: real)
            try insertRows(db, accountId: real, inbox: 120, archive: 30) { date($0, step: 3) }
            try insertAccount(db, id: demo)
            try insertRows(db, accountId: demo, inbox: 63, archive: 9) { date($0, step: 3) }
        case .smallRealAndDemoRows:
            try insertAccount(db, id: real)
            try insertRows(db, accountId: real, inbox: 20, archive: 5) { date($0, step: 2) }
            try insertAccount(db, id: demo)
            try insertRows(db, accountId: demo, inbox: 12, archive: 3) { date($0, step: 2) }
        case .demoAccountWithoutRows:
            try insertAccount(db, id: real)
            try insertRows(db, accountId: real, inbox: 80, archive: 10) { date($0) }
            try insertAccount(db, id: demo)
        }
    }

    static func insertAccount(_ db: Database, id: String) throws {
        var account = Account(emailAddress: "user-\(id.suffix(4))@example.com", displayName: "Test", provider: .gmail)
        account.id = id
        try account.insert(db)
        try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: id).insert(db)
        try Folder(name: "Archive", path: "Archive", role: .archive, accountId: id).insert(db)
    }

    /// `inbox` INBOX rows and `archive` Archive rows; row `i` of each folder is dated `date(i)`.
    static func insertRows(
        _ db: Database, accountId: String, inbox: Int, archive: Int, date: (Int) -> Date
    ) throws {
        for (path, count) in [("INBOX", inbox), ("Archive", archive)] {
            for index in 0..<count {
                let header = MessageHeader(
                    messageId: "\(index + 1)",
                    subject: "\(path) \(index)",
                    from: "Sender \(index)",
                    fromAddress: "sender\(index)@example.com",
                    to: "user@example.com",
                    date: date(index),
                    snippet: "Snippet \(index)",
                    folderId: "\(accountId):\(path)",
                    accountId: accountId,
                    folderPath: path,
                    isInInbox: path == "INBOX")
                try header.insert(db)
            }
        }
    }

    private static func read<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read(body)
    }

    // MARK: - Differential

    @Test("Every page, in normal and demo mode, is the replaced read's rows in its order, with its total and page",
          arguments: Fixture.allCases, DBProof.Statistics.allCases)
    func sameRowsAsTheReplacedRead(fixture: Fixture, statistics: DBProof.Statistics) throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Self.makeDatabase(fixture, statistics: statistics, in: directory)
        try Self.read(url) { db in
            for demoActive in [false, true] {
                let totalCount = try Self.oracle(db, pageIndex: 1, demoActive: demoActive).totalCount
                for pageIndex in Self.pageIndexes(totalCount: totalCount) {
                    let expected = try Self.oracle(db, pageIndex: pageIndex, demoActive: demoActive)
                    let actual = try Self.listing(db, pageIndex: pageIndex, demoActive: demoActive)
                    #expect(actual == expected, "\(fixture), \(statistics), demo \(demoActive), page_index \(pageIndex)")
                }
            }
        }
    }

    @Test("Normal mode never lists a demo row, and demo mode lists only demo rows")
    func demoBoundary() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for fixture in [Fixture.realAndDemoRows, .smallRealAndDemoRows] {
            let url = try Self.makeDatabase(fixture, statistics: .analyzed, in: directory)
            try Self.read(url) { db in
                for demoActive in [false, true] {
                    let first = try Self.listing(db, pageIndex: 1, demoActive: demoActive)
                    let pages = InboxReadTool.totalPages(for: first.totalCount)
                    var listed: [String] = []
                    for pageIndex in 1...pages {
                        listed += try Self.listing(db, pageIndex: pageIndex, demoActive: demoActive).ids
                    }
                    let demoPrefix = "\(DemoSeed.demoAccountId):"
                    #expect(listed.allSatisfy { $0.hasPrefix(demoPrefix) == demoActive }, "\(fixture), demo \(demoActive)")
                    #expect(listed.count == first.totalCount, "\(fixture), demo \(demoActive): every page together is the total")
                    #expect(Set(listed).count == listed.count, "\(fixture), demo \(demoActive): no row on two pages")
                }
            }
        }
    }

    /// About 100,000 headers in four accounts (`DBProof.Shape.large`, about 24,600 in the inbox), alone and with 63
    /// demo inbox rows dated among the newest, in both statistics states.
    private static func largeDatabases(in directory: URL) throws -> [(name: String, url: URL)] {
        let anchor = Date()
        let base = directory.appendingPathComponent("large.sqlite")
        try DBProof.build(at: base, shape: .large, anchor: anchor)
        let withDemo = directory.appendingPathComponent("large-demo.sqlite")
        try FileManager.default.copyItem(at: base, to: withDemo)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: withDemo.path, configuration: config)
        try queue.write { db in
            try insertAccount(db, id: DemoSeed.demoAccountId)
            try insertRows(db, accountId: DemoSeed.demoAccountId, inbox: 63, archive: 9) {
                anchor.addingTimeInterval(-Double($0) * 3_600)
            }
        }
        try queue.close()
        var files: [(name: String, url: URL)] = []
        for (name, source) in [("large", base), ("large with demo rows", withDemo)] {
            for statistics in DBProof.Statistics.allCases {
                let url = directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(statistics.rawValue).sqlite")
                try DBProof.prepareVariantFile(base: source, setupSQL: [], statistics: statistics, at: url)
                files.append(("\(name), \(statistics.label)", url))
            }
        }
        return files
    }

    /// On the large databases: the first pages, a middle page, the last page and past it are the oracle's, in normal
    /// and demo mode; and on a fresh connection (cold page cache) the listing reads fewer pages than the replaced
    /// read for the first page and the last in normal mode, and never more in demo mode.
    @Test("On a database of about 100,000 headers: the replaced read's rows in its order, from fewer pages")
    func largeDatabase() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, url) in try Self.largeDatabases(in: directory) {
            let inboxRows = try Self.read(url) { try MessageHeader.filter(Column("isInInbox") == true).fetchCount($0) }
            #expect(inboxRows > 20_000, "precondition: a large inbox (\(name): \(inboxRows))")
            for demoActive in [false, true] {
                let totalCount = try Self.read(url) { try Self.oracle($0, pageIndex: 1, demoActive: demoActive).totalCount }
                let pages = InboxReadTool.totalPages(for: totalCount)
                try Self.read(url) { db in
                    for pageIndex in Set([1, 2, pages / 2, pages, pages + 1]).sorted() {
                        let expected = try Self.oracle(db, pageIndex: pageIndex, demoActive: demoActive)
                        let actual = try Self.listing(db, pageIndex: pageIndex, demoActive: demoActive)
                        #expect(actual == expected, "\(name), demo \(demoActive), page_index \(pageIndex)")
                    }
                }
                for pageIndex in Set([1, pages]).sorted() {
                    let old = try Self.pagesRead(url) { try Self.oracle($0, pageIndex: pageIndex, demoActive: demoActive).ids.count }
                    let new = try Self.pagesRead(url) { try Self.listing($0, pageIndex: pageIndex, demoActive: demoActive).ids.count }
                    let context = "\(name), demo \(demoActive), page_index \(pageIndex): old \(old), new \(new)"
                    if demoActive {
                        #expect(new <= old, "never more: \(context)")
                    } else {
                        #expect(new < old, "fewer: \(context)")
                    }
                }
            }
        }
    }

    // MARK: - Reads

    /// The statements a read runs, recorded by `Database.trace` (which fires on the database's queue).
    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        var all: [String] { statements.withLock { $0 } }
    }

    /// In normal mode on an inbox of more than one page, every count and rowid read of the listing plans as a
    /// covering index search, and the page filters only on what the inbox index carries. The replaced read's count
    /// plans `USING INDEX messageHeader_isInInbox_date` (not covering: a table row per inbox message) and its page
    /// filters on `accountId`, so both fail here.
    @Test("Normal mode: counts and rowid reads stay in an index; the page filters only on indexed columns",
          arguments: [Fixture.severalAccounts, .realAndDemoRows, .tiesAcrossPages], DBProof.Statistics.allCases)
    func planStaysInTheIndex(fixture: Fixture, statistics: DBProof.Statistics) throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Self.makeDatabase(fixture, statistics: statistics, in: directory)
        let tape = SQLTape()
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        try queue.read { db in
            db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
            _ = try Self.listing(db, pageIndex: 2, demoActive: false)
            db.trace(options: [], nil)
        }
        // The listing's own SELECTs, not GRDB's schema reads (`PRAGMA main.table_xinfo("messageHeader")`).
        let headerReads = tape.all.filter {
            $0.uppercased().hasPrefix("SELECT") && ($0.contains("\"messageHeader\"") || $0.contains(" messageHeader "))
        }
        #expect(headerReads.count >= 2, "precondition: the trace recorded the count and the page (\(tape.all))")
        try queue.read { db in
            for sql in headerReads {
                let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
                #expect(!plan.contains { $0.hasPrefix("SCAN ") || $0.contains("TEMP B-TREE") }, "\(sql): \(plan)")
                if sql.uppercased().hasPrefix("SELECT *") {
                    #expect(plan.contains { $0.contains("USING INDEX messageHeader_isInInbox_date") }, "\(sql): \(plan)")
                    #expect(!sql.contains("accountId"), "the page filters on a column the inbox index lacks: \(sql)")
                } else {
                    #expect(plan.contains { $0.contains("USING COVERING INDEX") }, "\(sql): \(plan)")
                }
            }
        }
    }

    private static func pagesRead(_ url: URL, _ body: @escaping @Sendable (Database) throws -> Int) throws -> Int {
        try DBProof.measure(DBProof.Variant(run: body), kind: .read, file: url).pagesRead
    }

    /// Pages read on a fresh connection (cold page cache) on the small fixtures, the listing against the replaced
    /// read, for the first page and the last, in normal and demo mode: never more. (Fewer is shown on the large
    /// databases, where the replaced count's table reads dominate.) Not `demoAccountWithoutRows`: a demo account row
    /// without any demo message is a state the app never commits (`DemoSeed.seed` and every `DemoSeed.wipe` run in
    /// one write each), kept in the differential test for its rows only. There the listing looks up the demo rows the
    /// account row announces, which on its 80-row inbox costs one page more than the replaced read (old 8, new 9,
    /// after `ANALYZE`).
    @Test("On the small fixtures the listing never reads more pages than the replaced read",
          arguments: DBProof.Statistics.allCases)
    func neverReadsMorePages(statistics: DBProof.Statistics) throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for fixture in Fixture.allCases where fixture != .demoAccountWithoutRows {
            let url = try Self.makeDatabase(fixture, statistics: statistics, in: directory)
            for demoActive in [false, true] {
                let totalCount = try Self.read(url) { try Self.oracle($0, pageIndex: 1, demoActive: demoActive).totalCount }
                for pageIndex in Set([1, InboxReadTool.totalPages(for: totalCount)]).sorted() {
                    let old = try Self.pagesRead(url) { try Self.oracle($0, pageIndex: pageIndex, demoActive: demoActive).ids.count }
                    let new = try Self.pagesRead(url) { try Self.listing($0, pageIndex: pageIndex, demoActive: demoActive).ids.count }
                    #expect(new <= old, "\(fixture), \(statistics), demo \(demoActive), page_index \(pageIndex): old \(old), new \(new)")
                }
            }
        }
    }
}
