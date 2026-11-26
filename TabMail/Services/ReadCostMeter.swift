/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SQLite3

/// What one database read cost, for the debug log only: its wall time, the
/// rows its statements visited and the pages its connection fetched. A read is
/// one or more statements; each is prepared through `statement(_:sql:meter:)`,
/// which the meter keeps, and `reading()` reads from SQLite:
///
/// - `statements`: the statements that ran (a prepared statement the read
///   never stepped costs nothing and is not counted);
/// - `vmSteps`: virtual machine steps (`SQLITE_STMTSTATUS_VM_STEP`), which
///   grow with every row a statement visits, whether it returns it or not;
/// - `fullScanSteps`: steps of a full table scan (`SQLITE_STMTSTATUS_FULLSCAN_STEP`);
/// - `sorts`: sorts (`SQLITE_STMTSTATUS_SORT`), each of which reads every row
///   it sorts before returning the first;
/// - `pageHits` and `pageMisses`: the connection's page cache hits and misses
///   (`SQLITE_DBSTATUS_CACHE_HIT`, `_MISS`) during the read, so together the
///   pages the read touched, and the misses the pages SQLite had to read.
///
/// Made only while debug logging is on (`start` returns nil otherwise): with
/// no meter a read prepares the same uncached statements and counts nothing.
/// The line is built inside the read (`line`) and logged by the caller AFTER
/// the read returns (`log`), never from inside it: `BackgroundSyncLogger.logDebug`
/// is never called inside a database closure.
final class ReadCostMeter {
    private let connection: OpaquePointer?
    private let started: ContinuousClock.Instant
    private let startHits: Int
    private let startMisses: Int
    private var statements: [Statement] = []

    /// A meter for the read about to start, or nil when debug logging is off.
    static func start(_ db: Database) -> ReadCostMeter? {
        guard DebugModeManager.isLoggingEnabled() else { return nil }
        return ReadCostMeter(db)
    }

    init(_ db: Database) {
        connection = db.sqliteConnection
        let cache = Self.cacheCounts(connection)
        startHits = cache.hits
        startMisses = cache.misses
        started = ContinuousClock.now
    }

    /// `sql` prepared as `Row.fetchCursor(db, sql:)` prepares it (a new,
    /// uncached statement), and kept by `meter` so `reading()` can count it.
    static func statement(_ db: Database, sql: String, meter: ReadCostMeter?) throws -> Statement {
        let statement = try db.makeStatement(sql: sql)
        meter?.statements.append(statement)
        return statement
    }

    /// The counts since `init`, summed over every statement prepared through
    /// this meter.
    struct Reading {
        let milliseconds: Double
        let statements: Int
        let vmSteps: Int
        let fullScanSteps: Int
        let sorts: Int
        let pageHits: Int
        let pageMisses: Int
    }

    func reading() -> Reading {
        let milliseconds = (ContinuousClock.now - started) / .milliseconds(1)
        let cache = Self.cacheCounts(connection)
        func sum(_ counter: Int32) -> Int {
            statements.reduce(0) { $0 + Int(sqlite3_stmt_status($1.sqliteStatement, counter, 0)) }
        }
        // Every program's first step runs at least its first instruction, so a
        // statement that ran has a VM step and one never stepped has none.
        let ran = statements.filter { sqlite3_stmt_status($0.sqliteStatement, SQLITE_STMTSTATUS_VM_STEP, 0) > 0 }
        return Reading(
            milliseconds: milliseconds,
            statements: ran.count,
            vmSteps: sum(SQLITE_STMTSTATUS_VM_STEP),
            fullScanSteps: sum(SQLITE_STMTSTATUS_FULLSCAN_STEP),
            sorts: sum(SQLITE_STMTSTATUS_SORT),
            pageHits: cache.hits - startHits,
            pageMisses: cache.misses - startMisses)
    }

    /// The log line for this read: `[tag]`, then the read's own `shape` (its
    /// page size, rows returned, filters on or off, and the like), then the
    /// counts. The shape is integers only, so the line holds no account,
    /// folder, label, message or search text.
    func line(_ tag: StaticString, _ shape: KeyValuePairs<String, Int>) -> String {
        let r = reading()
        var parts = ["[\(tag)]"]
        parts += shape.map { "\($0.key)=\($0.value)" }
        parts += [
            "ms=\(String(format: "%.2f", r.milliseconds))", "statements=\(r.statements)",
            "vmSteps=\(r.vmSteps)", "fullScanSteps=\(r.fullScanSteps)", "sorts=\(r.sorts)",
            "pageHits=\(r.pageHits)", "pageMisses=\(r.pageMisses)",
        ]
        return parts.joined(separator: " ")
    }

    /// Logs `lines` to the debug log. Call it after the read has returned,
    /// outside any database closure.
    static func log(_ lines: [String]) {
        for line in lines { BackgroundSyncLogger.logDebug(line) }
    }

    private static func cacheCounts(_ connection: OpaquePointer?) -> (hits: Int, misses: Int) {
        var hits: Int32 = 0
        var misses: Int32 = 0
        var highwater: Int32 = 0
        sqlite3_db_status(connection, SQLITE_DBSTATUS_CACHE_HIT, &hits, &highwater, 0)
        sqlite3_db_status(connection, SQLITE_DBSTATUS_CACHE_MISS, &misses, &highwater, 0)
        return (Int(hits), Int(misses))
    }
}
