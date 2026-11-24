/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// The read of Settings "Archive old messages" (#1387, `SettingsView.oldInboxMessages`). It used to read every old
/// inbox message in one statement over all inbox folders, sorted across them in a temporary B-tree, and a device's
/// planner chose the plain `date` index for it, walking every folder's mail older than the cutoff to return the
/// inbox's. It now reads one inbox folder at a time in pages through `messageHeader_folderId_date`, pinned with
/// `INDEXED BY`.
///
/// The plan test records the statements the read really runs, with `Database.trace` on a database built by the
/// production migrations, and plans each one: a seek on the pinned index, no scan, no temporary B-tree. The order test
/// pins what the read returns, including page boundaries inside a run of equal dates.
@Suite("Archive old messages reads each inbox folder in pages through its date index")
struct ArchiveOldSweepReadTests {

    /// The SQL the connection ran. `trace` fires on the queue's own thread, hence the `Mutex`.
    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        var all: [String] { statements.withLock { $0 } }
        func clear() { statements.withLock { $0.removeAll() } }
    }

    private static let pinnedIndex = "messageHeader_folderId_date"
    private static let day: TimeInterval = 86_400

    /// A migrated database, traced into `tape` when one is given.
    private static func makeDatabase(trace tape: SQLTape? = nil) throws -> DatabaseQueue {
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
    /// the first inbox's old rows (three of them share one date), then the second inbox's.
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
        let expected = [oldest, tiedFirst, tiedSecond, tiedThird, mid, secondInboxOlder, secondInboxNewer]
        return (cutoff, expected)
    }

    /// What breaks the rule in `sql`'s plan: no seek of the pinned index by folder, a scan, or a temporary B-tree.
    /// Empty when the plan keeps the rule.
    private static func violations(_ sql: String, in queue: DatabaseQueue) throws -> [String] {
        let plan = try queue.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
        }
        var broken = plan.filter { $0.contains("TEMP B-TREE") || $0.hasPrefix("SCAN ") }
        if !plan.contains(where: { $0.hasPrefix("SEARCH messageHeader USING INDEX \(pinnedIndex) (folderId=?") }) {
            broken.append("no seek of \(pinnedIndex) by folder in \(plan)")
        }
        return broken
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

    @Test("Every statement of the read seeks the pinned folder-date index: no scan, no temporary B-tree")
    func eachPagePlansOnTheFolderDateIndex() throws {
        let tape = SQLTape()
        let queue = try Self.makeDatabase(trace: tape)
        let (cutoff, expected) = try Self.seed(queue)
        tape.clear()

        let read = try queue.read { db in
            try SettingsView.oldInboxMessages(
                db, folderIds: ["acc1:INBOX", "acc2:INBOX"], cutoff: cutoff, pageSize: 2)
        }
        #expect(read.count == expected.count, "precondition: the read returned every old row (\(read.count))")

        let pages = tape.all.filter { $0.contains("INDEXED BY \(Self.pinnedIndex)") }
        let firstPages = pages.filter { !$0.contains("(date, rowid) >") }
        let laterPages = pages.filter { $0.contains("(date, rowid) >") }
        #expect(firstPages.count == 2, "precondition: one first page per folder (\(tape.all))")
        #expect(!laterPages.isEmpty, "precondition: the trace recorded a continued page (\(tape.all))")

        var broken: [String] = []
        for sql in pages {
            let lines = try Self.violations(sql, in: queue)
            if !lines.isEmpty { broken.append("\(lines) by \(sql)") }
        }
        #expect(broken.isEmpty, "a page of the read scanned or sorted: \(broken)")
    }

    @Test("Negative control: the statement this fix replaced breaks the same rule")
    func theReplacedReadBreaksTheRule() throws {
        let queue = try Self.makeDatabase()
        let replaced = """
            SELECT * FROM messageHeader WHERE folderId IN ('acc1:INBOX', 'acc2:INBOX') AND date < '9999-12-31'
            ORDER BY date ASC
            """
        let lines = try Self.violations(replaced, in: queue)
        #expect(!lines.isEmpty, "the rule must catch the replaced read; its plan broke nothing")
    }
}
