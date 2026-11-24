/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SQLite3
import Synchronization
import Testing
@testable import TabMail

/// `ReadCostMeter`: made only while debug logging is on, its counts are
/// SQLite's own for the statements the read ran, and its line holds counts
/// only.
///
/// `.serialized, .processGlobalState`: these tests set the process-global
/// `DebugModeManager.loggingEnabledOverrideForTesting` and `AppLogStore.fileURLOverride`.
@Suite("The read cost meter is made only while debug logging is on and counts what a read ran", .serialized, .processGlobalState)
struct ReadCostMeterTests {

    /// Every statement the connection runs, in order.
    private final class StatementTape: Sendable {
        private let statements = Mutex<[String]>([])

        func record(_ sql: String) {
            statements.withLock { $0.append(sql) }
        }

        /// The statements recorded since the last call, which it clears.
        func take() -> [String] {
            statements.withLock { recorded in
                let taken = recorded
                recorded = []
                return taken
            }
        }
    }

    private static let tag: StaticString = "ReadCostTest"
    private static let rowCount = 40
    private static let subject = "Distinct subject 6b2e"
    /// Text in the database and in the read's arguments that a line must never hold.
    private static let names = ["acc1", "INBOX", "Distinct subject", "sender@example.com", "recipient@example.com"]

    private func makeDatabase() throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, accountId: "acc1")
        let now = Date()
        for index in 0..<Self.rowCount {
            try TestDatabase.insertMessageHeader(
                db, messageId: "\(1_000 + index)", subject: "\(Self.subject) \(index)",
                date: now.addingTimeInterval(-Double(index) * 60), snippet: "snippet \(Self.rowCount - index)")
        }
        return db
    }

    /// One read as a caller makes it: the meter started inside the read, its
    /// statement prepared through the meter, the line built inside the read.
    /// The caller logs the line after the read returns.
    private func meteredRead(_ db: DatabaseQueue) throws -> (meterMade: Bool, rows: Int, line: String?) {
        try db.read { dbConn in
            let meter = ReadCostMeter.start(dbConn)
            let statement = try ReadCostMeter.statement(
                dbConn, sql: "SELECT id FROM messageHeader WHERE folderId = ? ORDER BY date DESC", meter: meter)
            let rows = try String.fetchAll(statement, arguments: ["acc1:INBOX"]).count
            return (meter != nil, rows, meter?.line(Self.tag, ["rows": rows, "target": 50]))
        }
    }

    /// The debug log's lines that carry this suite's tag.
    private static func taggedLines() -> [String] {
        AppLogStore.read(channel: .debug).components(separatedBy: "\n").filter { $0.contains("[\(tag)]") }
    }

    /// Runs `body` with debug logging held at `loggingEnabled` and the log in
    /// a fresh file, restoring both after.
    private func withLogging(_ loggingEnabled: Bool, _ body: () throws -> Void) rethrows {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("readcost_\(UUID().uuidString).log")
        AppLogStore.fileURLOverride.withLock { $0 = url }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = loggingEnabled }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        try body()
    }

    @Test("With debug logging off no meter is made, the read returns its rows, and nothing is logged")
    func nothingIsMadeOrLoggedWithLoggingOff() throws {
        let db = try makeDatabase()
        try withLogging(false) {
            let read = try meteredRead(db)
            #expect(!read.meterMade, "a meter was made with debug logging off")
            #expect(read.line == nil)
            #expect(read.rows == Self.rowCount, "the read lost rows: \(read.rows)")
            // Even a line handed to the meter's log is not written while logging is off.
            ReadCostMeter.log(["[\(Self.tag)] rows=1"])
            #expect(Self.taggedLines().isEmpty, "a line was logged with debug logging off: \(Self.taggedLines())")
        }
    }

    @Test("With debug logging on a meter is made, and the read logs one line with its shape and counts and no name")
    func oneCountOnlyLineWithLoggingOn() throws {
        let db = try makeDatabase()
        try withLogging(true) {
            let read = try meteredRead(db)
            #expect(read.meterMade, "no meter was made with debug logging on")
            #expect(read.rows == Self.rowCount, "the read lost rows: \(read.rows)")
            guard let line = read.line else {
                Issue.record("no line was built with debug logging on")
                return
            }
            #expect(line.hasPrefix("[\(Self.tag)] rows=\(Self.rowCount) target=50 "), "the line does not start with its tag and shape: \(line)")
            for key in ["ms=", "statements=1", "vmSteps=", "fullScanSteps=", "sorts=", "pageHits=", "pageMisses="] {
                #expect(line.contains(key), "the line lacks \(key): \(line)")
            }
            ReadCostMeter.log([line])
            let logged = Self.taggedLines()
            #expect(logged.count == 1, "expected one logged line, got \(logged.count): \(logged)")
            for text in [line] + logged {
                for name in Self.names {
                    #expect(!text.contains(name), "the line holds \(name): \(text)")
                }
            }
        }
    }

    @Test("The counts are SQLite's own: the statements that ran, the rows they visited, full scans, sorts and pages")
    func theCountsAreSQLitesOwn() throws {
        let db = try makeDatabase()
        let tape = StatementTape()
        try db.write { dbConn in
            dbConn.trace(options: .statement) { event in tape.record(event.expandedDescription) }
        }
        typealias Measured = (reading: ReadCostMeter.Reading, pages: Int, traced: Int)
        // `sql` prepared through a fresh meter; each statement is stepped to its
        // end when `step` is true, never stepped otherwise.
        func measure(_ sql: [String], step: Bool) throws -> Measured {
            _ = tape.take()
            let measured = try db.read { dbConn -> (reading: ReadCostMeter.Reading, pages: Int) in
                let handle = try #require(dbConn.sqliteConnection)
                let before = Self.pagesSoFar(handle)
                let meter = ReadCostMeter(dbConn)
                for text in sql {
                    let statement = try ReadCostMeter.statement(dbConn, sql: text, meter: meter)
                    if step {
                        _ = try Row.fetchAll(statement)
                    }
                }
                return (meter.reading(), Self.pagesSoFar(handle) - before)
            }
            let traced = tape.take().filter { $0.hasPrefix("SELECT") }.count
            return (measured.reading, measured.pages, traced)
        }

        // Every row, sorted on a column no index holds: a full scan and a sort.
        let scan = try measure(["SELECT id FROM messageHeader ORDER BY snippet"], step: true)
        // One row by its key: a seek, no scan, no sort.
        let firstId = try db.read { try String.fetchOne($0, sql: "SELECT id FROM messageHeader LIMIT 1") }
        let oneId = try #require(firstId)
        let seekSQL = "SELECT id FROM messageHeader WHERE id = '\(oneId)'"
        let seek = try measure([seekSQL], step: true)
        // Both, plus one statement prepared and never stepped.
        let both = try measure(["SELECT id FROM messageHeader ORDER BY snippet", seekSQL], step: true)
        let neverStepped = try measure(["SELECT id FROM messageHeader ORDER BY snippet"], step: false)

        for (name, measured) in [("scan", scan), ("seek", seek), ("both", both), ("never stepped", neverStepped)] {
            #expect(measured.reading.statements == measured.traced,
                    "\(name): the meter counted \(measured.reading.statements) statements, the connection ran \(measured.traced)")
            #expect(measured.reading.pageHits + measured.reading.pageMisses == measured.pages,
                    "\(name): the meter counted \(measured.reading.pageHits)+\(measured.reading.pageMisses) pages, the connection \(measured.pages)")
            #expect(measured.reading.milliseconds >= 0, "\(name): negative time")
        }
        #expect(scan.reading.statements == 1 && seek.reading.statements == 1 && both.reading.statements == 2)
        #expect(scan.reading.fullScanSteps >= Self.rowCount - 1, "the scan's full-scan steps: \(scan.reading.fullScanSteps)")
        #expect(scan.reading.sorts == 1, "the scan's sorts: \(scan.reading.sorts)")
        #expect(seek.reading.fullScanSteps == 0 && seek.reading.sorts == 0,
                "the seek scanned or sorted: \(seek.reading.fullScanSteps) \(seek.reading.sorts)")
        #expect(scan.reading.vmSteps > seek.reading.vmSteps * 4,
                "visiting every row cost no more steps than one row: \(scan.reading.vmSteps) against \(seek.reading.vmSteps)")
        #expect(both.reading.vmSteps == scan.reading.vmSteps + seek.reading.vmSteps,
                "the steps of two statements are not their sum: \(both.reading.vmSteps)")
        // A statement that never ran costs nothing and is not counted.
        #expect(neverStepped.reading.statements == 0 && neverStepped.reading.vmSteps == 0
                && neverStepped.reading.sorts == 0 && neverStepped.reading.fullScanSteps == 0,
                "a statement never stepped was counted: \(neverStepped.reading)")
    }

    /// The pages the connection has fetched so far (page cache hits plus misses).
    private static func pagesSoFar(_ handle: OpaquePointer) -> Int {
        var hits: Int32 = 0
        var misses: Int32 = 0
        var highwater: Int32 = 0
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_HIT, &hits, &highwater, 0)
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_MISS, &misses, &highwater, 0)
        return Int(hits) + Int(misses)
    }
}
