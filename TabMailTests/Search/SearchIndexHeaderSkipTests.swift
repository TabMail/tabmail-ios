/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import SQLite3
import Synchronization
@testable import TabMail

/// The bulk index walk leaves alone what it would not change (#1431).
///
/// The walk re-indexes every header of an account, page by page (`SyncEngine.bulkIndexWritePage`). It
/// used to rewrite every search entry and mark every header complete, though nearly all of them were
/// indexed and marked already. Now an entry that already holds every value the write would set is not
/// written (`SearchIndex.indexHeaders(_:skippingUnchanged:)`), and a header already marked is not written.
///
/// - The differential test runs the old page write and the new one over the same walk, on two copies
///   of the same fixture, and compares every row of both databases byte for byte: the end state must be
///   exactly the old one, for entries that differ in each way and for one that differs only by its
///   missing identity version.
/// - The cost test: over entries held unchanged and headers already complete, the walk writes no
///   search entry and no header page.
/// - The fence: every column the upsert sets is a column the unchanged check compares.
///
/// Each test uses its own search index and its own header database in a temporary folder. The fixtures
/// hold only example.com data.
@Suite("SearchIndex - bulk index walk skips unchanged entries")
struct SearchIndexHeaderSkipTests {

    private static let accountId = "skip1"
    private static let inbox = MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX")
    private static let archive = MessageIdentity.folderId(accountId: accountId, folderPath: "Archive")

    /// The SQL the search index's connections ran, as the trace seam reports it (values filled in).
    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        func drain() -> [String] {
            statements.withLock { buffer in
                let all = buffer
                buffer = []
                return all
            }
        }
    }

    /// One search index and one header database, each in a temporary folder of its own.
    private struct Env {
        let index: SearchIndex
        let indexDirectory: URL
        let tape: SQLTape
        let pool: DatabasePool
        let poolDirectory: URL
        var headerDatabase: PrioritizedDatabase { PrioritizedDatabase(pool: pool, priority: .background) }
    }

    private func makeEnv() async throws -> Env {
        let indexDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("header-skip-index-\(UUID().uuidString)", isDirectory: true)
        let tape = SQLTape()
        let index = SearchIndex(directoryForTesting: indexDirectory, statementTraceForTesting: { tape.record($0) })
        try await index.initialize()

        let poolDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("header-skip-headers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: poolDirectory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: poolDirectory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        try AppDatabase.runMigrations(on: pool)
        try await pool.write { db in
            var account = Account(emailAddress: "user@example.com", displayName: "User", provider: .imap)
            account.id = Self.accountId
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.accountId).insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: Self.accountId).insert(db)
        }
        return Env(index: index, indexDirectory: indexDirectory, tape: tape, pool: pool, poolDirectory: poolDirectory)
    }

    private func finish(_ env: Env) async {
        await env.index.closeForNuke()
        try? FileManager.default.removeItem(at: env.indexDirectory)
        TestDatabaseTeardown.closeThenUnlinkNow(pool: env.pool, directory: env.poolDirectory)
    }

    /// Noon on June 15 of the current year in UTC, so every fixture date nearby lies in one year shard.
    private static func midYear() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let year = calendar.component(.year, from: Date())
        return calendar.date(from: DateComponents(year: year, month: 6, day: 15, hour: 12))!
    }

    private static func year(of dateMs: Int64) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.year, from: Date(timeIntervalSince1970: Double(dateMs) / 1000))
    }

    /// Inserts one header per entry (whole-second dates, so a header read back gives the same
    /// milliseconds), marks each complete or not, and returns them as read back from the database.
    private func insertHeaders(
        _ env: Env, _ entries: [(messageId: String, folderPath: String, subject: String, to: String, date: Date, complete: Bool)]
    ) async throws -> [String: MessageHeader] {
        try await env.pool.write { db in
            var headers: [String: MessageHeader] = [:]
            for entry in entries {
                let header = MessageHeader(
                    messageId: entry.messageId, subject: entry.subject, from: "Sender",
                    fromAddress: "sender@example.com", to: entry.to, date: entry.date, snippet: "",
                    folderId: MessageIdentity.folderId(accountId: Self.accountId, folderPath: entry.folderPath),
                    accountId: Self.accountId, folderPath: entry.folderPath,
                    isInInbox: entry.folderPath == "INBOX")
                try header.insert(db)
                try db.execute(sql: "UPDATE messageHeader SET headerComplete = ? WHERE id = ?",
                               arguments: [entry.complete, header.id])
                headers[entry.messageId] = try MessageHeader.fetchOne(db, key: header.id)
            }
            return headers
        }
    }

    /// `record` with the given fields replaced.
    private static func record(
        _ record: FTSHeaderRecord, subject: String? = nil, from: String? = nil, dateMs: Int64? = nil,
        folderId: String? = nil, rfc822MessageId: String? = nil, uidValidity: Int? = nil,
        resetAtMs: Int64? = nil, contentKeySpace: ContentKeySpace? = nil
    ) -> FTSHeaderRecord {
        FTSHeaderRecord(
            contentKey: record.contentKey, headerId: record.headerId, messageId: record.messageId,
            subject: subject ?? record.subject, from: from ?? record.from, to: record.to,
            cc: record.cc, bcc: record.bcc, dateMs: dateMs ?? record.dateMs,
            folderId: folderId ?? record.folderId, rfc822MessageId: rfc822MessageId,
            uidValidity: uidValidity, resetAtMs: resetAtMs, contentKeySpace: contentKeySpace)
    }

    // MARK: - The old page write

    /// The walk's page write before #1431, kept as the oracle: every header re-indexed through the full
    /// upsert, every header marked complete.
    private static func oldPageWrite(_ headers: [MessageHeader], env: Env) async throws {
        _ = try await env.index.indexHeaders(SyncEngine.bulkIndexRecords(headers))
        let headerIds = headers.map(\.id)
        try await env.pool.write { db in
            for hid in headerIds {
                try db.execute(sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?", arguments: [hid])
            }
        }
    }

    private static func newPageWrite(_ headers: [MessageHeader], env: Env) async throws {
        _ = try await SyncEngine.bulkIndexWritePage(headers, searchIndex: env.index, headerDatabase: env.headerDatabase)
    }

    /// Walks both folders with `write` as the page write, a few headers per page.
    private static func walk(
        _ env: Env, write: (_ headers: [MessageHeader], _ env: Env) async throws -> Void
    ) async throws {
        let finished = try await SyncEngine.bulkIndexWalk(
            folderIds: [inbox, archive], dbPool: env.headerDatabase, limit: 4
        ) { headers, _ in
            try await write(headers, env)
        }
        #expect(finished, "precondition: the walk ran to its end")
    }

    // MARK: - Reading back every row

    /// A stored value as SQLite holds it: text and blobs by their bytes.
    private enum Cell: Hashable, CustomStringConvertible {
        case null
        case integer(Int64)
        case real(Double)
        case text([UInt8])
        case blob(Data)

        init(_ value: DatabaseValue) {
            switch value.storage {
            case .null: self = .null
            case .int64(let int): self = .integer(int)
            case .double(let double): self = .real(double)
            case .string(let string): self = .text(Array(string.utf8))
            case .blob(let data): self = .blob(data)
            }
        }

        var description: String {
            switch self {
            case .null: "NULL"
            case .integer(let int): "\(int)"
            case .real(let double): "\(double)"
            case .text(let bytes): "'\(String(decoding: bytes, as: UTF8.self))'[\(bytes.map { String($0, radix: 16) }.joined())]"
            case .blob(let data): "x'\(data.map { String(format: "%02x", $0) }.joined())'"
            }
        }
    }

    /// Every row of every table of the database at `path`, by table, each row as its exact cells and
    /// in a stable order. A table with rowids carries them. An FTS5 table is read through its own
    /// columns; its two index tables (`_data`, `_idx`) are left out, since a rewritten row is indexed
    /// again into new segments, and FTS5's own integrity check proves the index matches the rows.
    /// A virtual table of another module is read through its own tables.
    private static func dump(_ path: String) throws -> [String: [[Cell]]] {
        let queue = try DatabaseQueue(path: path)
        defer { try? queue.close() }
        return try queue.write { db in
            var tables: [String: [[Cell]]] = [:]
            let schema = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'table'")
            for entry in schema {
                let name: String = entry["name"]
                let sql: String = entry["sql"] ?? ""
                if name.range(of: #"^messages_fts_\d+_(data|idx)$"#, options: .regularExpression) != nil { continue }
                let isVirtual = sql.uppercased().hasPrefix("CREATE VIRTUAL TABLE")
                if isVirtual {
                    guard sql.range(of: "fts5", options: .caseInsensitive) != nil else { continue }
                    try db.execute(sql: "INSERT INTO \"\(name)\"(\"\(name)\") VALUES('integrity-check')")
                }
                let rows: [Row]
                do {
                    rows = try Row.fetchAll(db, sql: "SELECT rowid AS dump_rowid, * FROM \"\(name)\"")
                } catch {
                    rows = try Row.fetchAll(db, sql: "SELECT * FROM \"\(name)\"")
                }
                tables[name] = rows
                    .map { $0.databaseValues.map(Cell.init) }
                    .sorted { $0.description < $1.description }
            }
            return tables
        }
    }

    /// The tables of `lhs` and `rhs` whose rows differ, with both sides' rows.
    private static func differences(_ lhs: [String: [[Cell]]], _ rhs: [String: [[Cell]]]) -> [String] {
        Set(lhs.keys).union(rhs.keys).sorted().compactMap { table in
            lhs[table] == rhs[table] ? nil : "\(table):\n  old: \(lhs[table] ?? [])\n  new: \(rhs[table] ?? [])"
        }
    }

    // MARK: - Counting writes

    /// One SQL text per statement, whatever its line breaks and indentation.
    private static func normalized(_ sql: String) -> String {
        sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The search entry writes among `statements`: an UPDATE of a year shard or of `message_meta`, and
    /// an INSERT into a year shard. FTS5's own statements on its tables are named differently.
    private static func entryWrites(_ traced: [String]) -> (shardUpdates: Int, shardInserts: Int, metaUpdates: Int) {
        let statements = traced.map(normalized)
        let shardUpdates = statements.filter { $0.range(of: #"^UPDATE messages_fts_\d+ SET "#, options: .regularExpression) != nil }
        let shardInserts = statements.filter { $0.range(of: #"^INSERT OR REPLACE INTO messages_fts_\d+ \("#, options: .regularExpression) != nil }
        let metaUpdates = statements.filter { $0.hasPrefix("UPDATE message_meta SET ") }
        return (shardUpdates.count, shardInserts.count, metaUpdates.count)
    }

    /// The pages the header database's writer connection has written so far, and the rows it changed.
    private static func headerWriterCounts(_ pool: DatabasePool) async throws -> (pagesWritten: Int32, rowsChanged: Int) {
        try await pool.write { db in
            var current: Int32 = 0
            var highwater: Int32 = 0
            sqlite3_db_status(db.sqliteConnection, SQLITE_DBSTATUS_CACHE_WRITE, &current, &highwater, 0)
            return (current, db.totalChangesCount)
        }
    }

    // MARK: - Fixture: entries the walk finds in every state

    /// The message ids of the differential fixture and what each one's stored entry is.
    private enum Case: String, CaseIterable {
        /// Indexed from its own header, with a body and an embedding; header complete.
        case same
        /// Indexed from its own header; header not complete.
        case sameNotComplete
        case staleSubject
        case staleSender
        case staleFolder
        case staleDateSameYear
        case staleDateOtherYear
        /// Indexed by an earlier version: no identity version, every other value equal.
        case noIdentityVersion
        /// Carries identity stamps the walk does not state.
        case stamped
        /// Carries a reset marker, so the walk's write is refused.
        case resetMarker
        /// The same subject in another Unicode form (decomposed where the header is composed).
        case otherUnicodeForm
        /// No entry yet.
        case missing
    }

    /// Seeds `env` with one header per case and its stored entry. Run on two environments, it gives
    /// both the same rows with the same rowids.
    private func seedDifferentialFixture(_ env: Env) async throws {
        let base = Self.midYear()
        let entries = Case.allCases.enumerated().map { offset, kind in
            (messageId: kind.rawValue,
             folderPath: offset.isMultiple(of: 3) ? "Archive" : "INBOX",
             subject: kind == .otherUnicodeForm ? "Caf\u{e9} notes" : "Subject \(kind.rawValue)",
             to: kind == .noIdentityVersion ? "" : "user@example.com",
             date: base - Double(offset) * 60,
             complete: kind != .sameNotComplete)
        }
        let headers = try await insertHeaders(env, entries)
        func own(_ kind: Case) -> FTSHeaderRecord {
            SyncEngine.bulkIndexRecords([headers[kind.rawValue]!])[0]
        }
        let dayMs: Int64 = 86_400_000
        let body = "Body text kept across the walk"
        for kind in Case.allCases {
            let mine = own(kind)
            let stored: FTSHeaderRecord?
            switch kind {
            case .same, .sameNotComplete: stored = mine
            case .staleSubject: stored = Self.record(mine, subject: "Old subject")
            case .staleSender: stored = Self.record(mine, from: "Other <other@example.com>")
            case .staleFolder: stored = Self.record(mine, folderId: Self.archive == mine.folderId ? Self.inbox : Self.archive)
            case .staleDateSameYear: stored = Self.record(mine, dateMs: mine.dateMs - 60_000)
            case .staleDateOtherYear: stored = Self.record(mine, dateMs: mine.dateMs - 400 * dayMs)
            case .noIdentityVersion: stored = nil
            case .stamped:
                stored = Self.record(mine, rfc822MessageId: "<stamped@example.com>", uidValidity: 7,
                                     contentKeySpace: .uidAddressed)
            case .resetMarker: stored = Self.record(mine, resetAtMs: mine.dateMs)
            case .otherUnicodeForm: stored = Self.record(mine, subject: "Cafe\u{301} notes")
            case .missing: stored = nil
            }
            if let stored {
                let inserted = try await env.index.indexHeaders([stored])
                #expect(inserted == 1, "precondition: \(kind) was indexed")
                if kind != .resetMarker {
                    try await env.index.updateBody(contentKey: stored.contentKey, body: "\(body) \(kind.rawValue)")
                }
            }
            if kind == .noIdentityVersion {
                // An entry an earlier version wrote: no identity columns at all. Its folder is set the
                // way the folder backfill sets it, so only the missing version differs.
                _ = try await env.index.testSeedLegacyShard(
                    year: Self.year(of: mine.dateMs), tokenize: SearchConfig.ftsTokenize,
                    contentKey: mine.contentKey, msgId: mine.messageId, subject: mine.subject,
                    from: mine.from, body: "\(body) \(kind.rawValue)", dateMs: mine.dateMs)
                try await env.index.updateFolderIds(contentKeys: [mine.contentKey], newFolderId: mine.folderId)
            }
        }
        let embedding = (0..<SearchConfig.embeddingDims).map { Float($0 % 7) / 7 }
        try await env.index.storeEmbeddings([
            (contentKey: own(.same).contentKey, embedding: embedding),
            (contentKey: own(.staleSubject).contentKey, embedding: embedding),
        ])
    }

    // MARK: - Tests

    @Test("The walk's new page write leaves both databases exactly as the old one: every entry that differs is rewritten, the rest left alone")
    func newWalkEndsInTheOldWalksState() async throws {
        let old = try await makeEnv()
        let new = try await makeEnv()
        try await seedDifferentialFixture(old)
        try await seedDifferentialFixture(new)
        let seededOld = try Self.dump(old.indexDirectory.appendingPathComponent("fts.db").path)
        let seededNew = try Self.dump(new.indexDirectory.appendingPathComponent("fts.db").path)
        #expect(Self.differences(seededOld, seededNew).isEmpty, "precondition: both fixtures are identical")
        _ = old.tape.drain()
        _ = new.tape.drain()

        try await Self.walk(old, write: Self.oldPageWrite)
        try await Self.walk(new, write: Self.newPageWrite)
        let oldWrites = Self.entryWrites(old.tape.drain())
        let newWrites = Self.entryWrites(new.tape.drain())

        await old.index.closeForNuke()
        await new.index.closeForNuke()
        let oldIndex = try Self.dump(old.indexDirectory.appendingPathComponent("fts.db").path)
        let newIndex = try Self.dump(new.indexDirectory.appendingPathComponent("fts.db").path)
        let oldHeaders = try await old.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messageHeader ORDER BY id").map { $0.databaseValues.map(Cell.init) }
        }
        let newHeaders = try await new.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messageHeader ORDER BY id").map { $0.databaseValues.map(Cell.init) }
        }
        let completeAfter = try await new.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE headerComplete = 1") ?? 0
        }
        await finish(old)
        await finish(new)

        let indexDifferences = Self.differences(oldIndex, newIndex)
        #expect(indexDifferences.isEmpty, "the search index differs from the old walk's:\n\(indexDifferences.joined(separator: "\n"))")
        #expect(oldHeaders == newHeaders, "the headers differ from the old walk's")
        #expect(completeAfter == Case.allCases.count, "every header is marked complete (\(completeAfter))")
        #expect(oldIndex.keys.contains { $0.hasPrefix("messages_fts_") } && oldIndex["message_meta"]?.count == Case.allCases.count,
                "precondition: the dump read the shards and every entry (\(oldIndex.keys.sorted()))")

        // The old walk rewrote every held entry it was not refused (all but the reset marker and the
        // missing one); the new one only the eight that differ. One of those moved to another year's
        // shard, so it was inserted there rather than updated.
        let held = Case.allCases.count - 2
        let differing = 8
        #expect(oldWrites.metaUpdates == held, "old walk: \(oldWrites)")
        #expect(newWrites.metaUpdates == differing, "new walk: \(newWrites)")
        #expect(newWrites.shardUpdates == differing - 1, "new walk: \(newWrites)")
        // The year move, and the missing entry's first insert.
        #expect(newWrites.shardInserts == 2, "new walk: \(newWrites)")
    }

    @Test("A walk over entries held unchanged and headers already complete writes no search entry and no header page")
    func walkOverHeldEntriesWritesNothing() async throws {
        let env = try await makeEnv()
        let base = Self.midYear()
        let count = 30
        let headers = try await insertHeaders(env, (0..<count).map { n in
            (messageId: "\(n + 1)", folderPath: n.isMultiple(of: 3) ? "Archive" : "INBOX",
             subject: "Subject \(n)", to: "user@example.com", date: base - Double(n) * 60, complete: false)
        })
        // The first walk indexes every header and marks it complete.
        try await Self.walk(env, write: Self.newPageWrite)
        let indexed = try await env.index.documentCountForAccount(accountId: Self.accountId)
        #expect(indexed == count, "precondition: the first walk indexed every header (\(indexed))")
        _ = env.tape.drain()
        let before = try await Self.headerWriterCounts(env.pool)

        try await Self.walk(env, write: Self.newPageWrite)

        let writes = Self.entryWrites(env.tape.drain())
        let after = try await Self.headerWriterCounts(env.pool)
        let complete = try await env.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE headerComplete = 1") ?? 0
        }
        await finish(env)

        #expect(headers.count == count)
        #expect(writes.shardUpdates == 0 && writes.shardInserts == 0 && writes.metaUpdates == 0,
                "the second walk rewrote search entries: \(writes)")
        #expect(after.rowsChanged - before.rowsChanged == 0, "the second walk changed header rows")
        #expect(after.pagesWritten - before.pagesWritten == 0, "the second walk wrote header pages")
        #expect(complete == count)
    }

    /// The columns `sql`'s SET list or INSERT column list writes, for a statement that writes a year
    /// shard or `message_meta`, with the table kind; nil for any other statement.
    private static func writtenColumns(_ traced: String) -> (table: String, columns: [String])? {
        let sql = normalized(traced)
        let update = #"^UPDATE (messages_fts_\d+|message_meta) SET (.+) WHERE rowid = "#
        if let match = sql.range(of: update, options: .regularExpression) {
            let statement = String(sql[match])
            let table = statement.hasPrefix("UPDATE message_meta") ? "message_meta" : "shard"
            let set = statement
                .replacingOccurrences(of: #"^UPDATE \S+ SET "#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #" WHERE rowid = $"#, with: "", options: .regularExpression)
            let columns = set.components(separatedBy: ", ").compactMap { $0.components(separatedBy: " = ").first }
            return (table, columns)
        }
        let insert = #"^INSERT OR REPLACE INTO (messages_fts_\d+|message_meta) ?\(([^)]*)\)"#
        if let match = sql.range(of: insert, options: .regularExpression) {
            let statement = String(sql[match])
            let table = statement.contains("message_meta") ? "message_meta" : "shard"
            let list = statement.drop { $0 != "(" }.dropFirst().dropLast()
            let columns = list.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0 != "rowid" }
            return (table, columns)
        }
        return nil
    }

    /// The columns among `statements`' writes that the unchanged check does not compare.
    private static func uncomparedColumns(_ statements: [String]) -> [String] {
        let compared = SearchIndex.unchangedCheckColumnsForTesting
        return statements.compactMap(writtenColumns).flatMap { write in
            let checked = write.table == "message_meta" ? compared.meta : compared.shard
            return write.columns.filter { !checked.contains($0) }.map { "\(write.table).\($0)" }
        }
    }

    @Test("Every column the upsert sets on a held entry is a column the unchanged check compares")
    func upsertWritesOnlyComparedColumns() async throws {
        let env = try await makeEnv()
        let key = ContentKey(rawValue: "\(Self.accountId):INBOX:1")
        let dateMs = Int64(Self.midYear().timeIntervalSince1970 * 1000)
        let first = FTSHeaderRecord(
            contentKey: key, headerId: key.rawValue, messageId: "1", subject: "first", from: "a@example.com",
            to: "b@example.com", cc: "c@example.com", bcc: "d@example.com", dateMs: dateMs, folderId: Self.inbox,
            rfc822MessageId: "<first@example.com>", uidValidity: 3, contentKeySpace: .uidAddressed)
        _ = try await env.index.indexHeaders([first])
        try await env.index.updateBody(contentKey: key, body: "kept body")
        _ = env.tape.drain()

        // Every value differs, in the same year's shard, then in another year's.
        let sameYear = FTSHeaderRecord(
            contentKey: key, headerId: key.rawValue, messageId: "2", subject: "second", from: "e@example.com",
            to: "f@example.com", cc: "g@example.com", bcc: "h@example.com", dateMs: dateMs - 60_000,
            folderId: Self.archive)
        _ = try await env.index.indexHeaders([sameYear], skippingUnchanged: true)
        let otherYear = Self.record(sameYear, dateMs: dateMs - 400 * 86_400_000)
        _ = try await env.index.indexHeaders([otherYear], skippingUnchanged: true)
        let statements = env.tape.drain()
        await finish(env)

        let writes = statements.compactMap(Self.writtenColumns)
        let compared = SearchIndex.unchangedCheckColumnsForTesting
        let written = Set(writes.flatMap { write in write.columns.map { "\(write.table).\($0)" } })
        let checked = Set(compared.shard.map { "shard.\($0)" } + compared.meta.map { "message_meta.\($0)" })
        #expect(writes.contains { $0.table == "shard" } && writes.contains { $0.table == "message_meta" },
                "precondition: the trace recorded the shard and meta writes (\(statements))")
        #expect(Self.uncomparedColumns(statements).isEmpty,
                "the upsert writes columns the unchanged check does not compare: \(Self.uncomparedColumns(statements))")
        #expect(written == checked, "the unchanged check compares columns the upsert does not write: \(checked.subtracting(written))")

        // The fence catches a write of a column outside the check, in either form.
        let extra = Self.uncomparedColumns([
            "UPDATE message_meta SET hasBody = 0 WHERE rowid = 1",
            "INSERT OR REPLACE INTO messages_fts_2000 (rowid, msgId, extra) VALUES (1, '1', 'x')",
        ])
        #expect(extra == ["message_meta.hasBody", "shard.extra"], "\(extra)")
    }
}
