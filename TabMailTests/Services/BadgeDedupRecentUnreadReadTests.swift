/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The badge dedup read (`UnreadCountManager.recentUnreadCountedIds`): the newest unread inbox headers, at most
/// `SyncConfig.nseBadgeDedupRecentLimit`, newest first. The replaced statement (no index hint) is kept here as the
/// oracle. On databases built by the production migrations and deferred-index build, with no planner statistics and
/// after the app's `ANALYZE`, the read returns the oracle's ids in the oracle's order wherever the dates are distinct.
/// On equal dates it returns everything the oracle's statement defines, which is less: the statement has no order
/// among equal dates, and which of the rows sharing the last date make the limit is not defined either, so there the
/// read has the same dates in the same order, the same ids dated after the last date, and at the last date the same
/// number of that date's unread rows. That is all the caller needs: it adds the ids to a set (`NSEBadge.markCounted`).
/// With two or more inbox folders the read's plan walks `messageHeader_folderId_isRead_date`, where the oracle's walks
/// `messageHeader_folderId_isRead`, which has no date, and sorts every unread inbox header.
@Suite("Badge dedup read: the replaced read's ids, through the date index")
struct BadgeDedupRecentUnreadReadTests {

    static let limit = SyncConfig.nseBadgeDedupRecentLimit
    static let dateIndex = "messageHeader_folderId_isRead_date"

    // MARK: - Oracle

    /// The replaced read, verbatim but for the hint it lacked.
    static func oracleSQL(inboxFolderCount: Int) -> String {
        let placeholders = Array(repeating: "?", count: inboxFolderCount).joined(separator: ", ")
        return """
            SELECT accountId, messageId, rfc822MessageId
            FROM messageHeader
            WHERE folderId IN (\(placeholders)) AND isRead = 0
            ORDER BY date DESC
            LIMIT \(SyncConfig.nseBadgeDedupRecentLimit)
            """
    }

    static func oracle(_ db: Database) throws -> [String] {
        let inboxFolderIds = try inboxFolderIds(db)
        guard !inboxFolderIds.isEmpty else { return [] }
        let rows = try Row.fetchAll(db, sql: oracleSQL(inboxFolderCount: inboxFolderIds.count),
                                    arguments: StatementArguments(inboxFolderIds))
        return rows.map { countedId($0) }
    }

    static func inboxFolderIds(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT id FROM folder WHERE role = ?", arguments: [FolderRole.inbox.rawValue])
    }

    private static func countedId(_ row: Row) -> String {
        NSEBadge.countedId(accountId: row["accountId"], messageId: row["messageId"], rfc822MessageId: row["rfc822MessageId"])
    }

    /// The date of every unread inbox header, by its counted id.
    private static func unreadDates(_ db: Database) throws -> [String: Double] {
        let folders = try inboxFolderIds(db)
        guard !folders.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: folders.count).joined(separator: ", ")
        let rows = try Row.fetchAll(db, sql: """
            SELECT accountId, messageId, rfc822MessageId, date FROM messageHeader
            WHERE folderId IN (\(placeholders)) AND isRead = 0
            """, arguments: StatementArguments(folders))
        var dates: [String: Double] = [:]
        for row in rows {
            let date: Date = row["date"]
            dates[countedId(row)] = date.timeIntervalSinceReferenceDate
        }
        return dates
    }

    /// Everything the oracle's statement defines: the same dates in the same order; the same ids, as a multiset,
    /// dated after the last date returned; and at that last date the same number of ids, each an unread inbox
    /// header of that date. With distinct dates this is the same ids in the same order, which `exact` also asserts.
    private static func expectSameRead(_ db: Database, exact: Bool, _ context: String) throws {
        let expected = try oracle(db)
        let actual = try UnreadCountManager.recentUnreadCountedIds(db).ids
        if exact {
            #expect(actual == expected, "\(context): ids or order differ")
        }
        let dates = try unreadDates(db)
        let expectedDates = expected.map { dates[$0] }
        let actualDates = actual.map { dates[$0] }
        #expect(!actualDates.contains(nil), "\(context): an id that is no unread inbox header")
        #expect(actualDates == expectedDates, "\(context): the dates differ")
        guard let boundary = expectedDates.last ?? nil else {
            #expect(actual.isEmpty, "\(context): ids where the oracle has none")
            return
        }
        let expectedAbove = expected.filter { dates[$0]! > boundary }.sorted()
        let actualAbove = actual.filter { (dates[$0] ?? -.infinity) > boundary }.sorted()
        #expect(actualAbove == expectedAbove, "\(context): the ids above the last date differ")
        let atBoundary = actual.filter { dates[$0] == boundary }
        #expect(Set(atBoundary).count == atBoundary.count, "\(context): an id twice")
        #expect(atBoundary.count == expected.filter { dates[$0] == boundary }.count, "\(context): the last date's count differs")
    }

    // MARK: - Fixtures

    enum Fixture: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// An account with an Archive folder and no inbox-role folder.
        case noInboxFolder
        /// Inbox folders whose rows are all read, and unread Archive rows.
        case noUnreadInboxRow
        case oneRow
        /// One inbox with 260 unread rows: the limit applies, and the planner already walks the date index.
        case oneInboxOverTheLimit
        /// Three inboxes (150, 120 and 90 unread rows, read rows between them, unread Archive rows), dates
        /// interleaved across the accounts and all distinct; a third of the rows have no RFC 822 Message-ID.
        case severalAccounts
        /// Three inboxes whose dates repeat in runs of 5 across the accounts, so equal dates cross the limit.
        case tiesAcrossTheLimit

        var testDescription: String { rawValue }
        var distinctDates: Bool { self != .tiesAcrossTheLimit }
    }

    private static func scratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("badge-dedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The fixture on disk, built by the production migrations and deferred-index build, in `statistics`.
    private static func makeDatabase(_ fixture: Fixture, statistics: DBProof.Statistics, in directory: URL) throws -> URL {
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
        switch fixture {
        case .noInboxFolder:
            let account = DBProof.accountId(0)
            try insertAccount(db, id: account, withInbox: false)
            try insertRows(db, accountId: account, path: "Archive", count: 30, unread: { _ in true }) {
                anchor.addingTimeInterval(-Double($0) * 60)
            }
        case .noUnreadInboxRow:
            for index in 0..<2 {
                let account = DBProof.accountId(index)
                try insertAccount(db, id: account)
                try insertRows(db, accountId: account, path: "INBOX", count: 40, unread: { _ in false }) {
                    anchor.addingTimeInterval(-Double($0 * 2 + index) * 60)
                }
                try insertRows(db, accountId: account, path: "Archive", count: 30, unread: { _ in true }) {
                    anchor.addingTimeInterval(-Double($0 * 2 + index) * 60 + 30)
                }
            }
        case .oneRow:
            let account = DBProof.accountId(0)
            try insertAccount(db, id: account)
            try insertRows(db, accountId: account, path: "INBOX", count: 1, unread: { _ in true }) { _ in anchor }
            try insertRows(db, accountId: account, path: "Archive", count: 10, unread: { _ in true }) {
                anchor.addingTimeInterval(-Double($0 + 1) * 60)
            }
        case .oneInboxOverTheLimit:
            let account = DBProof.accountId(0)
            try insertAccount(db, id: account)
            try insertRows(db, accountId: account, path: "INBOX", count: 300, unread: { $0 % 7 != 3 }) {
                anchor.addingTimeInterval(-Double($0) * 60)
            }
        case .severalAccounts, .tiesAcrossTheLimit:
            // Unread rows per account: 150, 120 and 90, with every fifth row read.
            let unreadCounts = [150, 120, 90]
            for (index, unread) in unreadCounts.enumerated() {
                let account = DBProof.accountId(index)
                try insertAccount(db, id: account)
                let count = unread * 5 / 4
                try insertRows(db, accountId: account, path: "INBOX", count: count, unread: { $0 % 5 != 4 }) { row in
                    let slot = row * unreadCounts.count + index
                    let step = fixture == .tiesAcrossTheLimit ? 5 : 1
                    return anchor.addingTimeInterval(-Double(slot / step) * 60)
                }
                try insertRows(db, accountId: account, path: "Archive", count: 40, unread: { _ in true }) {
                    anchor.addingTimeInterval(-Double($0) * 45 + 20)
                }
            }
        }
    }

    private static func insertAccount(_ db: Database, id: String, withInbox: Bool = true) throws {
        var account = Account(emailAddress: "user-\(id.suffix(4))@example.com", displayName: "Test", provider: .imap)
        account.id = id
        try account.insert(db)
        if withInbox {
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: id).insert(db)
        }
        try Folder(name: "Archive", path: "Archive", role: .archive, accountId: id).insert(db)
    }

    /// `count` rows in `path`; row `i` is unread when `unread(i)` and dated `date(i)`; every third row has no
    /// RFC 822 Message-ID.
    private static func insertRows(
        _ db: Database, accountId: String, path: String, count: Int, unread: (Int) -> Bool, date: (Int) -> Date
    ) throws {
        for index in 0..<count {
            var header = MessageHeader(
                messageId: "\(path == "INBOX" ? "i" : "a")\(index)",
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
            header.isRead = !unread(index)
            header.rfc822MessageId = index % 3 == 2 ? nil : "<\(accountId.suffix(6))-\(path)-\(index)@example.com>"
            try header.insert(db)
        }
    }

    private static func read<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read(body)
    }

    private static func plan(_ db: Database, sql: String, folders: Int) throws -> [String] {
        let arguments = StatementArguments((0..<folders).map { DBProof.accountId($0) + ":INBOX" })
        return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] as String }
    }

    // MARK: - Differential

    @Test("The replaced read's ids, in its order where dates are distinct, and all it defines on equal dates",
          arguments: Fixture.allCases, DBProof.Statistics.allCases)
    func sameIdsAsTheReplacedRead(fixture: Fixture, statistics: DBProof.Statistics) throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Self.makeDatabase(fixture, statistics: statistics, in: directory)
        try Self.read(url) { db in
            try Self.expectSameRead(db, exact: fixture.distinctDates, "\(fixture), \(statistics.label)")
        }
    }

    @Test("Each fixture holds the case it is named for")
    func fixturesAreWhatTheyClaim() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func ids(_ fixture: Fixture) throws -> (folders: Int, ids: [String]) {
            let url = try Self.makeDatabase(fixture, statistics: .none, in: directory)
            return try Self.read(url) { db in (try Self.inboxFolderIds(db).count, try Self.oracle(db)) }
        }
        let noFolder = try ids(.noInboxFolder)
        #expect(noFolder.folders == 0 && noFolder.ids.isEmpty)
        let noUnread = try ids(.noUnreadInboxRow)
        #expect(noUnread.folders == 2 && noUnread.ids.isEmpty)
        let oneRow = try ids(.oneRow)
        #expect(oneRow.folders == 1 && oneRow.ids.count == 1)
        let oneInbox = try ids(.oneInboxOverTheLimit)
        #expect(oneInbox.folders == 1 && oneInbox.ids.count == Self.limit)
        let several = try ids(.severalAccounts)
        #expect(several.folders == 3 && several.ids.count == Self.limit)
        let accountsListed = Set(several.ids.map { id in String(id.prefix { $0 != ":" }) })
        #expect(accountsListed.count == 3, "the limit's rows come from every account")
        let ties = try ids(.tiesAcrossTheLimit)
        #expect(ties.folders == 3 && ties.ids.count == Self.limit)
        // The limit cuts a run of equal dates: the last date returned has more unread rows than were returned.
        let url = try Self.makeDatabase(.tiesAcrossTheLimit, statistics: .none, in: directory)
        let cut = try Self.read(url) { db -> (returned: Int, atDate: Int) in
            let dates = try Self.unreadDates(db)
            let returned = try Self.oracle(db).compactMap { dates[$0] }
            guard let boundary = returned.last else { return (0, 0) }
            return (returned.filter { $0 == boundary }.count, dates.values.filter { $0 == boundary }.count)
        }
        #expect(cut.returned > 0 && cut.atDate > cut.returned, "the limit cuts no run of equal dates: \(cut)")
    }

    /// About 100,000 headers in four accounts (`DBProof.Shape.large`: four inboxes, about 7,400 unread inbox rows,
    /// distinct dates), in both statistics states: the same ids in the same order, and the date index's plan.
    @Test("On a database of about 100,000 headers: the replaced read's ids in its order, through the date index")
    func largeDatabase() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.appendingPathComponent("large.sqlite")
        try DBProof.build(at: base, shape: .large, anchor: Date())
        for statistics in DBProof.Statistics.allCases {
            let url = directory.appendingPathComponent("large-\(statistics.rawValue).sqlite")
            try DBProof.prepareVariantFile(base: base, setupSQL: [], statistics: statistics, at: url)
            try Self.read(url) { db in
                let folders = try Self.inboxFolderIds(db).count
                let unread = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM messageHeader WHERE isRead = 0
                      AND folderId IN (SELECT id FROM folder WHERE role = ?)
                    """, arguments: [FolderRole.inbox.rawValue]) ?? 0
                #expect(folders >= 2 && unread > Self.limit * folders, "precondition: \(folders) inboxes, \(unread) unread")
                try Self.expectSameRead(db, exact: true, "large, \(statistics.label)")
                let hinted = try Self.plan(db, sql: UnreadCountManager.recentUnreadForNSESQL(inboxFolderCount: folders), folders: folders)
                #expect(hinted.contains { $0.contains("USING INDEX \(Self.dateIndex) ") }, "large, \(statistics.label): \(hinted)")
                let replaced = try Self.plan(db, sql: Self.oracleSQL(inboxFolderCount: folders), folders: folders)
                #expect(!replaced.contains { $0.contains(Self.dateIndex) }, "large, \(statistics.label): the replaced read already walked the date index: \(replaced)")
            }
        }
    }

    // MARK: - Plan

    /// With two or more inbox folders the read walks the date index; the replaced statement, which is the read's
    /// statement without its hint, does not. With one folder both walk it.
    @Test("Two or more inboxes: the read walks the date index, which the replaced statement does not",
          arguments: [Fixture.severalAccounts, .tiesAcrossTheLimit, .oneInboxOverTheLimit], DBProof.Statistics.allCases)
    func readWalksTheDateIndex(fixture: Fixture, statistics: DBProof.Statistics) throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Self.makeDatabase(fixture, statistics: statistics, in: directory)
        try Self.read(url) { db in
            let folders = try Self.inboxFolderIds(db).count
            let sql = UnreadCountManager.recentUnreadForNSESQL(inboxFolderCount: folders)
            let hinted = try Self.plan(db, sql: sql, folders: folders)
            let context = "\(fixture), \(statistics.label)"
            #expect(hinted.contains { $0.contains("SEARCH messageHeader USING INDEX \(Self.dateIndex) (folderId=? AND isRead=?)") },
                    "\(context): \(hinted)")
            #expect(!hinted.contains { $0.contains("SCAN") }, "\(context): \(hinted)")
            // The read's statement is the replaced one plus the hint, and nothing else.
            let unhinted = sql.replacingOccurrences(of: " INDEXED BY \(Self.dateIndex)", with: "")
            #expect(unhinted != sql, "the read's statement names no hint")
            #expect(unhinted == Self.oracleSQL(inboxFolderCount: folders), "the read's statement differs from the replaced one beyond the hint")
            let replaced = try Self.plan(db, sql: unhinted, folders: folders)
            if folders >= 2 {
                #expect(!replaced.contains { $0.contains(Self.dateIndex) }, "\(context): the replaced statement already walked the date index: \(replaced)")
            }
        }
    }

    /// `INDEXED BY` errors when the named index is missing, so the date index is built by the migrations and never
    /// deferred.
    @Test("The hinted index is built by the migrations and is not a deferred index")
    func hintedIndexIsBuiltByTheMigrations() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.runMigrations(on: queue)
        let exists = try queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?", arguments: [Self.dateIndex]) ?? false
        }
        #expect(exists, "\(Self.dateIndex) is missing after the migrations")
        let deferred = SyncEngine.deferredIndexes.map(\.name)
        #expect(!deferred.contains(Self.dateIndex), "\(Self.dateIndex) is deferred: \(deferred)")
    }
}

/// The badge dedup read's debug cost line (`UnreadCountManager.recentUnreadCountedIdsWithCost`): with debug logging
/// off no meter is made and no line is built; with it on the line is the tag, then the inbox folder count, the rows
/// returned and the limit as integers, then only the meter's counts, and none of the account, folder or message text
/// in the database.
///
/// `.serialized, .processGlobalState`: these tests set the process-global
/// `DebugModeManager.loggingEnabledOverrideForTesting`.
@Suite("Badge dedup read: the debug cost line is made only while debug logging is on and holds integers only", .serialized, .processGlobalState)
struct BadgeDedupRecentUnreadCostLineTests {

    private static let names = ["acc-badge-", "INBOX", "Subject", "sender", "example.com", "Snippet"]
    private static let shapeKeys = ["folders", "rows", "limit"]
    private static let meterKeys: Set<String> = [
        "ms", "statements", "vmSteps", "fullScanSteps", "sorts", "pageHits", "pageMisses",
    ]

    private func makeDatabase() throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        let anchor = Date()
        for account in 0..<2 {
            let accountId = "acc-badge-\(account)"
            try TestDatabase.insertAccount(db, id: accountId)
            try TestDatabase.insertFolder(db, accountId: accountId)
            for index in 0..<30 {
                try TestDatabase.insertMessageHeader(
                    db, messageId: "\(100 + index)", subject: "Subject \(account)-\(index)",
                    from: "sender\(index)@example.com", fromAddress: "sender\(index)@example.com",
                    date: anchor.addingTimeInterval(-Double(index * 2 + account) * 60), snippet: "Snippet \(index)",
                    folderId: "\(accountId):INBOX", accountId: accountId,
                    rfc822MessageId: "<badge-\(account)-\(index)@example.com>")
            }
        }
        return db
    }

    private func withLogging<T>(_ loggingEnabled: Bool, _ body: () throws -> T) rethrows -> T {
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = loggingEnabled }
        defer { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } }
        return try body()
    }

    @Test("With debug logging off no meter is made and no line is built; the ids are the read's")
    func noLineWithLoggingOff() throws {
        let db = try makeDatabase()
        let read = try withLogging(false) { try db.read { try UnreadCountManager.recentUnreadCountedIdsWithCost($0) } }
        #expect(read.costLine == nil, "a cost line was built with debug logging off: \(read.costLine ?? "")")
        let plain = try db.read { try UnreadCountManager.recentUnreadCountedIds($0).ids }
        #expect(read.ids == plain)
        #expect(read.ids.count == 60)
    }

    @Test("With debug logging on the line holds the folder count, rows and limit as integers, then counts only")
    func theLineHoldsIntegersOnly() throws {
        let db = try makeDatabase()
        let read = try withLogging(true) { try db.read { try UnreadCountManager.recentUnreadCountedIdsWithCost($0) } }
        guard let line = read.costLine else {
            Issue.record("no cost line was built with debug logging on")
            return
        }
        var tokens = line.split(separator: " ").map { String($0) }
        #expect(tokens.first == "[BadgeDedupRead]", "the line does not start with its tag: \(line)")
        guard tokens.count > 1 + Self.shapeKeys.count else {
            Issue.record("the line is too short: \(line)")
            return
        }
        tokens.removeFirst()
        let shape = Array(tokens.prefix(Self.shapeKeys.count))
        let expectedShape = ["folders=2", "rows=\(read.ids.count)", "limit=\(SyncConfig.nseBadgeDedupRecentLimit)"]
        #expect(shape == expectedShape, "the line's own fields: \(line)")
        let countKeys = Set(tokens.dropFirst(Self.shapeKeys.count).map { token in String(token.prefix { $0 != "=" }) })
        #expect(countKeys == Self.meterKeys, "the line's counts: \(line)")
        for token in tokens {
            let parts = token.split(separator: "=", omittingEmptySubsequences: false)
            let isNumber = parts.count == 2 && Double(parts[1]) != nil
            #expect(isNumber, "a field is not key=number: \(token) in \(line)")
        }
        for name in Self.names {
            #expect(!line.contains(name), "the line holds \(name): \(line)")
        }
    }
}
