/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// The SQL a connection ran. `trace` fires on the database's own queue, hence the `Mutex`.
private final class ArchiveOldSQLTape: Sendable {
    private let statements = Mutex<[String]>([])
    func record(_ sql: String) { statements.withLock { $0.append(sql) } }
    var all: [String] { statements.withLock { $0 } }
    var count: Int { statements.withLock { $0.count } }
    func since(_ start: Int) -> [String] { statements.withLock { Array($0.dropFirst(start)) } }
    func clear() { statements.withLock { $0.removeAll() } }
}

/// The plan rule every page of the read keeps, shared by both suites below.
private enum ArchiveOldPlanRule {
    static let pinnedIndex = "messageHeader_folderId_date"

    /// The seek a first page must plan: the folder and the cutoff bound the index walk.
    static let firstPageSeek = "SEARCH messageHeader USING INDEX \(pinnedIndex) (folderId=? AND date<?)"
    /// The seek a continued page must plan: the folder, the cursor and the cutoff all bound the walk, so a page
    /// starts at the cursor instead of walking past the rows already read.
    static let continuedPageSeek =
        "SEARCH messageHeader USING INDEX \(pinnedIndex) (folderId=? AND (date,rowid)>(?,?) AND date<?)"

    /// Whether `sql` is a continued page (it carries the cursor).
    static func isContinued(_ sql: String) -> Bool { sql.contains("(date, rowid) >") }

    /// What breaks the rule in `sql`'s plan: a scan, a temporary B-tree, or a plan without the exact bounded seek its
    /// page needs. Empty when the plan keeps the rule.
    static func violations<Reader: DatabaseReader>(_ sql: String, continued: Bool, in reader: Reader) throws -> [String] {
        let plan = try reader.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
        }
        var broken = plan.filter { $0.contains("TEMP B-TREE") || $0.hasPrefix("SCAN ") }
        let seek = continued ? continuedPageSeek : firstPageSeek
        if !plan.contains(seek) {
            broken.append("no `\(seek)` in \(plan)")
        }
        return broken
    }
}

/// The read of Settings "Archive old messages" (#1387, `SettingsView.oldInboxMessages`). It used to read every old
/// inbox message in one statement over all inbox folders, sorted across them in a temporary B-tree, and a device's
/// planner chose the plain `date` index for it, walking every folder's mail older than the cutoff to return the
/// inbox's. It now reads one inbox folder at a time in pages through `messageHeader_folderId_date`, pinned with
/// `INDEXED BY`.
///
/// The plan test records the statements the read really runs, with `Database.trace` on a database built by the
/// production migrations, and plans each one: the exact bounded seek on the pinned index, no scan, no temporary
/// B-tree. The order tests pin what the read returns, including page boundaries inside a run of equal dates and dates
/// stored in other forms than the one GRDB writes.
@Suite("Archive old messages reads each inbox folder in pages through its date index")
struct ArchiveOldSweepReadTests {

    private static let day: TimeInterval = 86_400

    /// A migrated database, traced into `tape` when one is given.
    private static func makeDatabase(trace tape: ArchiveOldSQLTape? = nil) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        if let tape {
            config.prepareDatabase { db in
                db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
            }
        }
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.runMigrations(on: queue)
        return queue
    }

    /// Two inbox folders and an archive folder. Returns the cutoff and the ids the read must return, in order:
    /// the first inbox's five old rows (three of them share one date), then the second inbox's three.
    private static func seed(_ queue: DatabaseQueue) throws -> (cutoff: Date, expected: [String]) {
        try TestDatabase.insertAccount(queue, id: "acc1", email: "one@example.com")
        try TestDatabase.insertAccount(queue, id: "acc2", email: "two@example.com")
        let now = Date()
        let cutoff = now.addingTimeInterval(-14 * day)
        let tied = now.addingTimeInterval(-30 * day)
        func insert(_ messageId: String, account: String, path: String, age days: Double) throws -> String {
            try TestDatabase.insertMessageHeader(
                queue, messageId: messageId, date: now.addingTimeInterval(-days * day),
                folderId: "\(account):\(path)", accountId: account, folderPath: path, isInInbox: path == "INBOX"
            ).id
        }
        func insertTied(_ messageId: String) throws -> String {
            try TestDatabase.insertMessageHeader(
                queue, messageId: messageId, date: tied, folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX"
            ).id
        }
        // Inserted out of date order, so rowid order is not date order.
        let mid = try insert("5", account: "acc1", path: "INBOX", age: 20)
        let oldest = try insert("1", account: "acc1", path: "INBOX", age: 40)
        let tiedFirst = try insertTied("2")
        let tiedSecond = try insertTied("3")
        let tiedThird = try insertTied("4")
        _ = try insert("6", account: "acc1", path: "INBOX", age: 1)       // newer than the cutoff
        _ = try insert("7", account: "acc1", path: "Archive", age: 60)    // old, but not in an inbox
        let secondInboxNewer = try insert("2", account: "acc2", path: "INBOX", age: 15)
        let secondInboxOlder = try insert("1", account: "acc2", path: "INBOX", age: 50)
        let secondInboxMiddle = try insert("3", account: "acc2", path: "INBOX", age: 45)
        let expected = [oldest, tiedFirst, tiedSecond, tiedThird, mid,
                        secondInboxOlder, secondInboxMiddle, secondInboxNewer]
        return (cutoff, expected)
    }

    @Test("Every page is one folder's oldest rows after the last one read, with page breaks inside equal dates",
          arguments: [1, 2, 3, 1_000])
    func readReturnsEachInboxOldestFirst(pageSize: Int) throws {
        let queue = try Self.makeDatabase()
        let (cutoff, expected) = try Self.seed(queue)

        let read = try queue.read { db in
            try SettingsView.oldInboxMessages(
                db, folderIds: ["acc2:INBOX", "acc1:INBOX"], cutoff: cutoff, pageSize: pageSize)
        }
        let ids = read.map(\.id)
        #expect(ids == expected, "page size \(pageSize): \(ids)")
    }

    @Test("Every statement of the read is the exact bounded seek of the pinned folder-date index, in every folder")
    func eachPagePlansOnTheFolderDateIndex() throws {
        let tape = ArchiveOldSQLTape()
        let queue = try Self.makeDatabase(trace: tape)
        let (cutoff, expected) = try Self.seed(queue)
        tape.clear()

        let read = try queue.read { db in
            try SettingsView.oldInboxMessages(
                db, folderIds: ["acc1:INBOX", "acc2:INBOX"], cutoff: cutoff, pageSize: 2)
        }
        #expect(read.count == expected.count, "precondition: the read returned every old row (\(read.count))")

        let pages = tape.all.filter { $0.contains("INDEXED BY \(ArchiveOldPlanRule.pinnedIndex)") }
        // Five old rows in the first inbox are pages of 2, 2 and 1; three in the second are 2 and 1. Neither count is
        // a multiple of the page size, so every continued page returns rows.
        for (folder, continuedPages) in [("'acc1:INBOX'", 2), ("'acc2:INBOX'", 1)] {
            let folderPages = pages.filter { $0.contains(folder) }
            let first = folderPages.filter { !ArchiveOldPlanRule.isContinued($0) }.count
            let continued = folderPages.filter { ArchiveOldPlanRule.isContinued($0) }.count
            #expect(first == 1, "precondition: one first page of \(folder) (\(tape.all))")
            #expect(continued == continuedPages, "precondition: \(continuedPages) continued pages of \(folder) (\(tape.all))")
        }

        var broken: [String] = []
        for sql in pages {
            let lines = try ArchiveOldPlanRule.violations(sql, continued: ArchiveOldPlanRule.isContinued(sql), in: queue)
            if !lines.isEmpty { broken.append("\(lines) by \(sql)") }
        }
        #expect(broken.isEmpty, "a page of the read did not seek its bounds: \(broken)")
    }

    @Test("Negative control: the statement this fix replaced breaks the same rule")
    func theReplacedReadBreaksTheRule() throws {
        let queue = try Self.makeDatabase()
        let replaced = """
            SELECT * FROM messageHeader WHERE folderId IN ('acc1:INBOX', 'acc2:INBOX') AND date < '9999-12-31'
            ORDER BY date ASC
            """
        let lines = try ArchiveOldPlanRule.violations(replaced, continued: false, in: queue)
        #expect(!lines.isEmpty, "the rule must catch the replaced read; its plan broke nothing")
    }

    @Test("Negative control: a continued page whose cursor does not bound the seek breaks the same rule")
    func aResidualCursorBreaksTheRule() throws {
        let queue = try Self.makeDatabase()
        let residual = """
            SELECT *, rowid AS sweepRowid FROM messageHeader INDEXED BY \(ArchiveOldPlanRule.pinnedIndex)
            WHERE folderId = 'acc1:INBOX' AND date < '9999-12-31' AND ((date, rowid) > ('2000-01-01', 1) OR 0)
            ORDER BY date, rowid LIMIT 2
            """
        let lines = try ArchiveOldPlanRule.violations(residual, continued: true, in: queue)
        #expect(!lines.isEmpty, "the rule must catch a cursor that only filters; its plan broke nothing")
    }

    /// `date` in a format GRDB does not write: text without the fractional seconds, `days` before now, UTC.
    private static func secondsText(daysAgo days: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date().addingTimeInterval(-days * day))
    }

    @Test("The cursor carries the stored date as read: numeric and second-precision dates, ties at page breaks",
          arguments: [1, 2, 1_000])
    func storedDateFormsKeepTheReplacedSelectionAndOrder(pageSize: Int) throws {
        let queue = try Self.makeDatabase()
        try TestDatabase.insertAccount(queue, id: "acc1", email: "one@example.com")
        try TestDatabase.insertAccount(queue, id: "acc2", email: "two@example.com")
        let now = Date()
        let cutoff = now.addingTimeInterval(-14 * day)
        // (account, messageId, stored date). A stored date GRDB did not write is set with a raw UPDATE.
        let numericOld = (now.addingTimeInterval(-40 * day)).timeIntervalSince1970
        let numericTied = (now.addingTimeInterval(-35 * day)).timeIntervalSince1970
        let textTied = Self.secondsText(daysAgo: 30)
        let rows: [(String, String, DatabaseValue)] = [
            ("acc1", "1", numericTied.databaseValue), ("acc1", "2", textTied.databaseValue),
            ("acc1", "3", numericOld.databaseValue), ("acc1", "4", numericTied.databaseValue),
            ("acc1", "5", textTied.databaseValue), ("acc1", "6", Self.secondsText(daysAgo: 25).databaseValue),
            ("acc1", "7", now.addingTimeInterval(-20 * day).databaseValue),
            ("acc2", "1", textTied.databaseValue), ("acc2", "2", numericTied.databaseValue),
            ("acc2", "3", textTied.databaseValue), ("acc2", "4", numericTied.databaseValue),
        ]
        for (account, messageId, stored) in rows {
            let id = try TestDatabase.insertMessageHeader(
                queue, messageId: messageId, folderId: "\(account):INBOX", accountId: account, folderPath: "INBOX").id
            try queue.write { db in
                try db.execute(sql: "UPDATE messageHeader SET date = ? WHERE id = ?", arguments: [stored, id])
            }
        }
        _ = try TestDatabase.insertMessageHeader(
            queue, messageId: "9", date: now.addingTimeInterval(-1 * day), folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX")                                         // newer than the cutoff

        // The replaced statement's selection and order, one folder after another in the read's folder order.
        let folders = ["acc1:INBOX", "acc2:INBOX"]
        let replaced = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, folderId FROM messageHeader WHERE folderId IN (?, ?) AND date < ? ORDER BY date, rowid
                """, arguments: [folders[0], folders[1], cutoff])
        }
        let expected = folders.flatMap { folder in
            replaced.filter { ($0["folderId"] as String) == folder }.map { $0["id"] as String }
        }
        #expect(expected.count == rows.count, "precondition: the replaced statement selects every old row (\(expected))")

        let read = try queue.read { db in
            try SettingsView.oldInboxMessages(db, folderIds: Set(folders), cutoff: cutoff, pageSize: pageSize)
        }
        let ids = read.map(\.id)
        #expect(ids == expected, "page size \(pageSize): \(ids), the replaced statement read \(expected)")
    }
}

/// The real sweep (`SettingsView.archiveOldMessages`) reads through the paged read: every statement it runs on
/// `messageHeader` between its stamp and its move is the bounded seek, and it selects every old inbox row, one Undo
/// entry per account, oldest first. Each inbox holds more than one production-sized page
/// (`SyncConfig.archiveOldReadPageSize`), with a run of equal dates across a page break.
@Suite("Archive old messages: the sweep itself reads in bounded pages", .serialized, .processGlobalState)
@MainActor
struct ArchiveOldSweepEntryPointReadTests {

    nonisolated private static let day: TimeInterval = 86_400

    /// One account's inbox mail for the sweep: `count` old rows dated in runs of `run` equal dates. The newest run is
    /// inserted first, so rowid order is not date order. Returns the ids in the order the sweep must select them.
    nonisolated private static func insertOldInbox(
        _ db: Database, account: String, count: Int, run: Int, now: Date
    ) throws -> [String] {
        var inserted: [(id: String, group: Int, rowOrder: Int)] = []
        for position in 0..<count {
            let group = position / run
            var header = MessageHeader(
                messageId: String(position + 1), subject: "old \(position)", from: "Sender",
                fromAddress: "sender@example.com", to: "recipient@example.com",
                date: now.addingTimeInterval(-Double(30 + group) * day), snippet: "old",
                folderId: "\(account):INBOX", accountId: account, folderPath: "INBOX", isInInbox: true)
            header.headerComplete = true
            try header.insert(db)
            inserted.append((header.id, group, position))
        }
        // Oldest first (the largest age group), then insertion order (rowid) within a run of equal dates.
        return inserted.sorted { ($0.group, -$0.rowOrder) > ($1.group, -$1.rowOrder) }.map(\.id)
    }

    @Test("The sweep's every messageHeader read is the bounded seek, and it selects every old inbox row in order")
    func sweepReadsInBoundedPagesAndSelectsEveryOldInboxRow() async throws {
        let pageSize = SyncConfig.archiveOldReadPageSize
        let tape = ArchiveOldSQLTape()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
        }
        let pool = try DatabasePool(path: directory.appendingPathComponent("t.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        UserDefaults.standard.set(false, forKey: AccountManager.markReadOnArchiveDeleteKey)
        UndoService.shared.dismissAll()

        // Two accounts, each with an inbox of two (first) and one (second) full pages plus a few rows, and an archive.
        let now = Date()
        // A run of equal dates crosses the first page break in each inbox (6 + 7k and 3 + 5k never equal 500).
        let shapes: [(account: String, count: Int, run: Int)] = [
            ("sweep-a", 2 * pageSize + 7, 7), ("sweep-b", pageSize + 3, 5),
        ]
        for shape in shapes {
            _ = try FolderEpochTestFixture.makeAccount(id: shape.account, provider: .imap, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: shape.account, path: "INBOX", role: .inbox, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: shape.account, path: "Archive", role: .archive, pool: pool)
        }
        let expected = try await pool.write { db -> [String: [String]] in
            var expected: [String: [String]] = [:]
            for shape in shapes {
                expected[shape.account] = try Self.insertOldInbox(
                    db, account: shape.account, count: shape.count, run: shape.run, now: now)
            }
            // Not swept: a new inbox row, and an old row outside the inbox.
            for (messageId, path, age) in [("90001", "INBOX", 1.0), ("90002", "Archive", 60.0)] {
                let header = MessageHeader(
                    messageId: messageId, subject: "kept", from: "Sender", fromAddress: "sender@example.com",
                    to: "recipient@example.com", date: now.addingTimeInterval(-age * Self.day), snippet: "kept",
                    folderId: "sweep-a:\(path)", accountId: "sweep-a", folderPath: path, isInInbox: path == "INBOX")
                try header.insert(db)
            }
            return expected
        }
        let inboxFolderIds = Set(shapes.map { "\($0.account):INBOX" })

        var readStart = 0
        var readWindow: [String] = []
        let swept = await SettingsView.archiveOldMessages(
            inboxFolderIds: inboxFolderIds, archiveCutoff: now.addingTimeInterval(-14 * Self.day),
            beforeRead: { readStart = tape.count },
            afterRead: { readWindow = tape.since(readStart) })

        let total = shapes.reduce(0) { $0 + $1.count }
        #expect(swept == total, "the sweep asked to move \(String(describing: swept)) rows, not \(total)")

        // What it selected: one Undo entry per account, holding that account's old inbox rows oldest first.
        let entries = UndoService.shared.undoStack
        var selected: [String: [String]] = [:]
        for entry in entries { selected[entry.accountId] = entry.messages.map(\.id) }
        #expect(entries.count == shapes.count, "one Undo entry per account (\(entries.count))")
        for shape in shapes {
            let got = selected[shape.account] ?? []
            #expect(got == expected[shape.account], "\(shape.account): selected \(got.count) rows out of order or not all")
        }

        // How it read them: every messageHeader statement in the read window is the bounded seek of its page.
        let reads = readWindow.filter { $0.localizedCaseInsensitiveContains("FROM messageHeader") }
        for shape in shapes {
            let folder = "'\(shape.account):INBOX'"
            let folderReads = reads.filter { $0.contains(folder) }
            let continued = folderReads.filter { ArchiveOldPlanRule.isContinued($0) }.count
            #expect(folderReads.count - continued == 1, "precondition: one first page of \(folder)")
            #expect(continued == shape.count / pageSize, "precondition: a continued page per full page of \(folder)")
        }
        var broken: [String] = []
        for sql in reads {
            let lines = try ArchiveOldPlanRule.violations(sql, continued: ArchiveOldPlanRule.isContinued(sql), in: pool)
            if !lines.isEmpty { broken.append("\(lines) by \(sql.prefix(300))") }
        }
        #expect(!reads.isEmpty, "precondition: the trace recorded the sweep's read")
        #expect(broken.isEmpty, "the sweep read messageHeader without the bounded seek: \(broken)")

        await AccountManager.shared.awaitWriteQueueDrain()
        UndoService.shared.dismissAll()
        AccountManager.shared.removeOverlayEntries(ids: Array(AccountManager.shared.snapshotOverlay().keys))
        UserDefaults.standard.removeObject(forKey: AccountManager.markReadOnArchiveDeleteKey)
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
    }
}
