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
/// (`SearchIndex(directoryForTesting:statementTraceForTesting:)`) on a database of its own in a temporary folder. The
/// database holds one indexed email, so its year shard exists and the open takes the path every user with mail takes,
/// and it is opened a second time, as on every launch after the first.
///
/// EVERY recorded statement is classified (`violation(of:)`), none is skipped: a statement that can read rows
/// (`SELECT`, `WITH`, `INSERT`, `UPDATE`, `DELETE`, `REPLACE`) is planned with `EXPLAIN QUERY PLAN` on a separate
/// connection, and only the schema and an FTS shard's settings table may be scanned; transaction control and
/// settings pragmas are allowed by name; schema statements are allowed only when they read no rows (an index that
/// already exists, a new empty table); anything else (`ANALYZE`, `VACUUM`, `ALTER`, an unlisted pragma) fails.
/// The negative controls run statements that do scan through the same classification, so the check cannot pass by
/// never matching.
@Suite("Search index open: no scan of a table that grows with the mail")
struct SearchIndexOpenScanTests {

    /// The SQL the index's connections ran. `trace` fires on the database's own queue, hence the `Mutex`.
    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        var all: [String] { statements.withLock { $0 } }
    }

    /// Tables whose size is the schema's, not the mail's: SQLite's catalog, and an FTS5 shard's settings table (a
    /// fixed handful of rows such as `automerge`), which FTS5 reads when it opens a shard.
    private static func isSchemaSized(_ table: String) -> Bool {
        if ["sqlite_master", "sqlite_schema", "sqlite_temp_master"].contains(table) { return true }
        guard table.hasPrefix("messages_fts_"), table.hasSuffix("_config") else { return false }
        let year = table.dropFirst("messages_fts_".count).dropLast("_config".count)
        return Int(year) != nil
    }

    /// Statement verbs that begin or end a transaction or savepoint: they read no rows.
    private static let transactionVerbs: Set<String> = ["BEGIN", "COMMIT", "END", "ROLLBACK", "SAVEPOINT", "RELEASE"]

    /// Pragmas that set or report a connection setting or the schema, and read no table rows. Not listed, and so
    /// failing: `integrity_check`, `quick_check`, `foreign_key_check`, `optimize`, and every other pragma.
    private static let settingsPragmas: Set<String> = [
        "journal_mode", "synchronous", "temp_store", "cache_size", "mmap_size", "busy_timeout", "foreign_keys",
        "query_only", "schema_version", "user_version", "data_version", "application_id", "page_size",
        "wal_autocheckpoint", "table_info", "table_xinfo", "index_list", "index_info", "index_xinfo",
        "foreign_key_list",
    ]

    /// Statement verbs whose plan says what they read.
    private static let plannedVerbs: Set<String> = ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "REPLACE"]

    /// `sql` with leading whitespace and SQL comments (`-- …` lines, `/* … */` blocks) removed.
    private static func stripLeadingComments(_ sql: String) -> Substring {
        var rest = Substring(sql)
        while true {
            rest = rest.drop(while: { $0.isWhitespace })
            if rest.hasPrefix("--") {
                rest = rest.drop(while: { $0 != "\n" })
            } else if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return "" }
                rest = rest[end.upperBound...]
            } else {
                return rest
            }
        }
    }

    /// The words of `sql` after its leading comments, upper-cased; `(` and `)` end a word.
    private static func words(_ sql: String) -> [String] {
        stripLeadingComments(sql)
            .split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "=" || $0 == ";" })
            .map { $0.uppercased() }
    }

    /// The object a `CREATE … [IF NOT EXISTS] name` or `DROP … [IF EXISTS] name` statement names, lower-cased and
    /// unquoted, without a `main.` prefix.
    private static func objectName(_ words: [String], after kind: String) -> String? {
        guard let kindAt = words.firstIndex(of: kind) else { return nil }
        var at = kindAt + 1
        if words.count > at + 2, words[at] == "IF", words[at + 1] == "NOT", words[at + 2] == "EXISTS" { at += 3 }
        if words.count > at + 1, words[at] == "IF", words[at + 1] == "EXISTS" { at += 2 }
        guard words.count > at else { return nil }
        var name = words[at].lowercased()
        if name.hasPrefix("main.") { name = String(name.dropFirst("main.".count)) }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`[]"))
    }

    /// Why `sql` could read a table that grows with the mail, or nil if it cannot. `existing` holds the names of the
    /// tables and indexes the database had before the open, lower-cased.
    private static func violation(of sql: String, existing: Set<String>, in probe: DatabaseQueue) -> String? {
        let words = Self.words(sql)
        guard let verb = words.first else { return "a statement with no SQL after its comments: \(sql)" }

        if transactionVerbs.contains(verb) { return nil }

        if verb == "PRAGMA" {
            guard words.count > 1 else { return "a bare PRAGMA: \(sql)" }
            var name = words[1].lowercased()
            if name.hasPrefix("main.") { name = String(name.dropFirst("main.".count)) }
            return settingsPragmas.contains(name) ? nil : "PRAGMA \(name) is not a settings pragma: \(sql)"
        }

        if verb == "CREATE" {
            if words.contains("INDEX") {
                // An index that already exists is a no-op; a new one reads every row of its table.
                guard let name = objectName(words, after: "INDEX") else { return "an unparsed CREATE INDEX: \(sql)" }
                return existing.contains(name) ? nil : "CREATE INDEX \(name) builds a new index: \(sql)"
            }
            if words.contains("AS") && words.contains("SELECT") && !words.contains("VIEW") && !words.contains("TRIGGER") {
                return "CREATE TABLE … AS SELECT copies rows: \(sql)"
            }
            return nil // a new empty table, a table that exists, a view or a trigger: no rows read
        }

        if verb == "DROP" {
            // Dropping an existing table deletes every row of it; an index, a view, a trigger, or a table made
            // during this open (GRDB's WAL setup table) reads nothing.
            guard words.count > 1, words[1] == "TABLE" else { return nil }
            guard let name = objectName(words, after: "TABLE") else { return "an unparsed DROP TABLE: \(sql)" }
            return existing.contains(name) ? "DROP TABLE \(name) deletes an existing table: \(sql)" : nil
        }

        if plannedVerbs.contains(verb) {
            if verb == "DELETE", !words.contains("WHERE") {
                return "DELETE with no WHERE empties a whole table: \(sql)"
            }
            do {
                let scanned = try scannedTables(sql, in: probe)
                return scanned.isEmpty ? nil : "scans \(scanned): \(sql)"
            } catch {
                return "could not plan (\(error)): \(sql)"
            }
        }

        return "\(verb) is not allowed when an existing index opens: \(sql)"
    }

    /// The tables, other than schema-sized ones, that a SCAN line of `sql`'s plan reads.
    private static func scannedTables(_ sql: String, in probe: DatabaseQueue) throws -> [String] {
        try probe.inDatabase { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).compactMap { row -> String? in
                let detail: String = row["detail"]
                guard detail.hasPrefix("SCAN ") else { return nil }
                var rest = detail.dropFirst("SCAN ".count)
                if rest.hasPrefix("TABLE ") { rest = rest.dropFirst("TABLE ".count) }
                let table = rest.split(separator: " ").first.map(String.init) ?? ""
                if table.hasPrefix("(") || table == "CONSTANT" || isSchemaSized(table) { return nil }
                return table
            }
        }
    }

    /// The names of the tables and indexes in `probe`'s database, lower-cased.
    private static func schemaObjects(in probe: DatabaseQueue) throws -> Set<String> {
        try probe.inDatabase { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'index')")
                .map { $0.lowercased() })
        }
    }

    /// The one email the fixture indexes: dated now, so its shard is this year's.
    private static let seededKey = ContentKey(rawValue: "openscan:INBOX:1")
    private static let seededWord = "openscanmarker"

    /// A search database the index created, migrated and indexed one email into, then closed: what every launch
    /// after the first opens.
    private static func makeExistingIndexDatabase() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-open-\(UUID().uuidString)", isDirectory: true)
        let first = SearchIndex(directoryForTesting: directory, statementTraceForTesting: { _ in })
        try await first.initialize()
        let record = FTSHeaderRecord(
            contentKey: seededKey, headerId: seededKey.rawValue, messageId: "1",
            subject: "\(seededWord) weekly notes", from: "a@example.com", to: "b@example.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000), folderId: "openscan:INBOX"
        )
        let inserted = try await first.indexHeaders([record])
        #expect(inserted == 1, "precondition: the fixture indexed its email (\(inserted))")
        await first.closeForNuke()
        return directory
    }

    @Test("Opening the search index scans no table but the schema")
    func openingScansNoMailTable() async throws {
        let directory = try await Self.makeExistingIndexDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = try DatabaseQueue(path: directory.appendingPathComponent("fts.db").path)
        let existing = try Self.schemaObjects(in: probe)

        let tape = SQLTape()
        let index = SearchIndex(directoryForTesting: directory, statementTraceForTesting: { tape.record($0) })
        try await index.initialize()
        let opened = tape.all

        // The open took the path of a database with mail: it found the shard by name and read its columns.
        let foundTheShards = opened.contains { $0.contains("messages\\_fts\\_") }
        let readTheShard = opened.contains { $0.contains("table_info(messages_fts_") }
        #expect(foundTheShards, "precondition: the trace recorded the shard lookup (\(opened))")
        #expect(readTheShard, "precondition: the open read the seeded shard's columns (\(opened))")

        var broken: [String] = []
        for sql in opened {
            if let why = Self.violation(of: sql, existing: existing, in: probe) { broken.append(why) }
        }
        #expect(broken.isEmpty, "opening the search index could read a table that grows with the mail: \(broken)")

        // The reopened index still knows the shard and finds the email in it.
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Date()).year
        let years = await index.sortedShardYears
        let knowsTheShard = year.map { years.contains($0) } ?? false
        #expect(knowsTheShard, "the reopened index lost the seeded shard: \(years)")
        let results = try await index.search(query: Self.seededWord, sort: .dateDesc)
        let found = results.map(\.contentKey)
        #expect(found == [Self.seededKey], "the reopened index lost the seeded email: \(found)")

        try probe.close()
        await index.closeForNuke()
    }

    @Test("Negative controls: statements that read the mail fail the same classification", arguments: [
        "SELECT COUNT(*) FROM message_meta",
        "/* diagnostic */ SELECT COUNT(*) FROM message_meta",
        "-- diagnostic\nSELECT COUNT(*) FROM message_meta",
        "UPDATE message_meta SET headerId = headerId WHERE length(headerId) < 0",
        "DELETE FROM message_ids",
        "CREATE INDEX IF NOT EXISTS idx_meta_openscan ON message_meta(dateMs)",
        "DROP TABLE IF EXISTS message_ids",
        "PRAGMA quick_check",
        "ANALYZE",
        "VACUUM",
    ])
    func mailReadsAreCaught(sql: String) async throws {
        let directory = try await Self.makeExistingIndexDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = try DatabaseQueue(path: directory.appendingPathComponent("fts.db").path)
        let existing = try Self.schemaObjects(in: probe)

        let why = Self.violation(of: sql, existing: existing, in: probe)
        #expect(why != nil, "the classification let a read of the mail through: \(sql)")
        try probe.close()
    }

    @Test("Positive controls: what an open of an existing index runs passes the same classification", arguments: [
        "SELECT * FROM sqlite_master LIMIT 1",
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'messages\\_fts\\_%' ESCAPE '\\'",
        "PRAGMA table_info(message_meta)",
        "PRAGMA journal_mode = WAL",
        "BEGIN DEFERRED TRANSACTION",
        "RELEASE SAVEPOINT grdb",
        "CREATE INDEX IF NOT EXISTS idx_meta_headerId ON message_meta(headerId)",
        "CREATE TABLE IF NOT EXISTS message_ids (headerId TEXT PRIMARY KEY)",
        "CREATE TABLE grdb_issue_102 (id INTEGER PRIMARY KEY)",
        "DROP TABLE grdb_issue_102",
    ])
    func openStatementsPass(sql: String) async throws {
        let directory = try await Self.makeExistingIndexDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = try DatabaseQueue(path: directory.appendingPathComponent("fts.db").path)
        let existing = try Self.schemaObjects(in: probe)

        let why = Self.violation(of: sql, existing: existing, in: probe)
        #expect(why == nil, "the classification refused a statement that reads no mail: \(why ?? "")")
        try probe.close()
    }
}
