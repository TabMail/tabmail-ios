/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// Opening the search index reads no table that grows with the user's mail (#1371). It used to count every indexed
/// email for a debug log line on every open: at app launch and at any other process start.
///
/// The statements checked are the ones the index really ran, recorded with `Database.trace` through its test seam
/// (`SearchIndex(directoryForTesting:statementTraceForTesting:)`) on a database of its own in a temporary folder,
/// opened a second time as on every launch after the first. Each read is planned with `EXPLAIN QUERY PLAN` on a
/// separate connection, and only the schema table may be scanned. `theRemovedCountIsAScan` is the negative control:
/// the count this fix removed plans as a scan under the same predicate, so the check cannot pass by never matching.
@Suite("Search index open: no scan of a table that grows with the mail")
struct SearchIndexOpenScanTests {

    /// The SQL the index's connections ran. `trace` fires on the database's own queue, hence the `Mutex`.
    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        var all: [String] { statements.withLock { $0 } }
    }

    /// Tables whose size is the schema's, not the mail's.
    private static let schemaTables: Set<String> = ["sqlite_master", "sqlite_schema", "sqlite_temp_master"]

    private static func isRead(_ sql: String) -> Bool {
        let head = sql.drop(while: { $0.isWhitespace }).prefix(6).uppercased()
        return head.hasPrefix("SELECT") || head.hasPrefix("WITH")
    }

    /// The tables, other than the schema, that a SCAN line of `sql`'s plan reads.
    private static func scannedTables(_ sql: String, in probe: DatabaseQueue) throws -> [String] {
        try probe.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).compactMap { row -> String? in
                let detail: String = row["detail"]
                guard detail.hasPrefix("SCAN ") else { return nil }
                var rest = detail.dropFirst("SCAN ".count)
                if rest.hasPrefix("TABLE ") { rest = rest.dropFirst("TABLE ".count) }
                let table = rest.split(separator: " ").first.map(String.init) ?? ""
                if table.hasPrefix("(") || table == "CONSTANT" || schemaTables.contains(table) { return nil }
                return table
            }
        }
    }

    /// A search database the index created and migrated, then closed: what every launch after the first opens.
    private static func makeExistingIndexDatabase() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-open-\(UUID().uuidString)", isDirectory: true)
        let first = SearchIndex(directoryForTesting: directory, statementTraceForTesting: { _ in })
        try await first.initialize()
        await first.closeForNuke()
        return directory
    }

    @Test("Opening the search index scans no table but the schema")
    func openingScansNoMailTable() async throws {
        let directory = try await Self.makeExistingIndexDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tape = SQLTape()
        let index = SearchIndex(directoryForTesting: directory, statementTraceForTesting: { tape.record($0) })
        try await index.initialize()

        let reads = tape.all.filter(Self.isRead)
        let readsTheSchema = reads.contains { $0.contains("sqlite_master") }
        #expect(readsTheSchema, "precondition: the trace recorded the open's reads (\(tape.all.count) statements)")

        let probe = try DatabaseQueue(path: directory.appendingPathComponent("fts.db").path)
        var scans: [String] = []
        for sql in reads {
            let tables = try Self.scannedTables(sql, in: probe)
            if !tables.isEmpty { scans.append("\(tables) by \(sql)") }
        }
        #expect(scans.isEmpty, "opening the search index scanned a table that grows with the mail: \(scans)")

        try probe.close()
        await index.closeForNuke()
    }

    @Test("Negative control: the count this fix removed plans as a scan under the same predicate")
    func theRemovedCountIsAScan() async throws {
        let directory = try await Self.makeExistingIndexDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let probe = try DatabaseQueue(path: directory.appendingPathComponent("fts.db").path)
        let tables = try Self.scannedTables("SELECT COUNT(*) FROM message_meta", in: probe)
        #expect(tables == ["message_meta"], "the predicate must catch the removed count's scan; it saw \(tables)")
        try probe.close()
    }
}
