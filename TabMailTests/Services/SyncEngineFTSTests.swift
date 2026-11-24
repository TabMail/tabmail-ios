/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import SQLite3
import Synchronization
@testable import TabMail

/// Tests for FTS header record mapping logic used by SyncEngineFTS.
/// The mapping from MessageHeader to FTSHeaderRecord is a pure transformation
/// that can be tested without SearchIndex or IMAP connections.
@Suite("SyncEngineFTS - Header to FTSRecord Mapping")
struct SyncEngineFTSTests {

    // MARK: - FTSHeaderRecord construction from MessageHeader fields

    @Test("FTSHeaderRecord maps all fields correctly")
    func ftsRecordFieldMapping() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: "acc1:INBOX:42"),
            headerId: "acc1:INBOX:42",
            messageId: "42",
            subject: "Important Email",
            from: "Alice <alice@example.com>",
            to: "bob@example.com",
            cc: "carol@example.com",
            bcc: "dave@example.com",
            dateMs: Int64(date.timeIntervalSince1970 * 1000)
        )

        #expect(record.headerId == "acc1:INBOX:42")
        #expect(record.messageId == "42")
        #expect(record.subject == "Important Email")
        #expect(record.from == "Alice <alice@example.com>")
        #expect(record.to == "bob@example.com")
        #expect(record.cc == "carol@example.com")
        #expect(record.bcc == "dave@example.com")
        #expect(record.dateMs == 1700000000000)
    }

    @Test("FTSHeaderRecord from field uses display name and address format")
    func ftsRecordFromFormat() {
        // SyncEngineFTS builds the 'from' field as "\(header.from) <\(header.fromAddress)>"
        let headerFrom = "Alice Smith"
        let headerFromAddress = "alice@example.com"
        let ftsFrom = "\(headerFrom) <\(headerFromAddress)>"

        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: "test"),
            headerId: "test",
            messageId: "1",
            subject: "Test",
            from: ftsFrom,
            to: "",
            dateMs: 0
        )

        #expect(record.from == "Alice Smith <alice@example.com>")
    }

    @Test("FTSHeaderRecord handles empty cc and bcc with defaults")
    func ftsRecordEmptyCcBcc() {
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: "test"),
            headerId: "test",
            messageId: "1",
            subject: "Test",
            from: "sender",
            to: "recipient",
            dateMs: 0
        )

        #expect(record.cc == "")
        #expect(record.bcc == "")
    }

    @Test("FTSHeaderRecord dateMs conversion preserves millisecond precision")
    func ftsRecordDateMsPrecision() {
        // A date with sub-second precision
        let date = Date(timeIntervalSince1970: 1700000000.123)
        let dateMs = Int64(date.timeIntervalSince1970 * 1000)

        #expect(dateMs == 1700000000123)
    }

    @Test("Batch mapping produces correct count of records")
    func batchMappingCount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let headers = try (1...5).map { i in
            try TestDatabase.insertMessageHeader(
                db,
                messageId: "\(i)",
                subject: "Subject \(i)",
                from: "Sender \(i)",
                fromAddress: "sender\(i)@example.com",
                to: "recipient@example.com",
                date: Date(),
                snippet: "Snippet \(i)"
            )
        }

        // Replicate the mapping from SyncEngine.indexHeadersForFTS
        let records = headers.map { header in
            FTSHeaderRecord( contentKey: ContentKey(rawValue: header.id),
                headerId: header.id,
                messageId: header.messageId,
                subject: header.subject,
                from: "\(header.from) <\(header.fromAddress)>",
                to: header.to,
                cc: header.cc,
                bcc: header.bcc,
                dateMs: Int64(header.date.timeIntervalSince1970 * 1000)
            )
        }

        #expect(records.count == 5)
        for (i, record) in records.enumerated() {
            #expect(record.messageId == "\(i + 1)")
            #expect(record.subject == "Subject \(i + 1)")
        }
    }

    @Test("FTSHeaderRecord maps special characters in subject and from")
    func ftsRecordSpecialCharacters() {
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: "test"),
            headerId: "test",
            messageId: "1",
            subject: "Re: [URGENT] Price <$100 & free shipping!",
            from: "O'Brien, James <james@example.com>",
            to: "\"Doe, Jane\" <jane@example.com>",
            dateMs: 0
        )

        #expect(record.subject == "Re: [URGENT] Price <$100 & free shipping!")
        #expect(record.from == "O'Brien, James <james@example.com>")
    }

    @Test("FTSHeaderRecord handles empty subject")
    func ftsRecordEmptySubject() {
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: "test"),
            headerId: "test",
            messageId: "1",
            subject: "",
            from: "sender",
            to: "recipient",
            dateMs: 0
        )

        #expect(record.subject == "")
    }

    @Test("Date epoch zero maps to dateMs zero")
    func ftsRecordEpochZero() {
        let date = Date(timeIntervalSince1970: 0)
        let dateMs = Int64(date.timeIntervalSince1970 * 1000)
        #expect(dateMs == 0)
    }

    @Test("Negative epoch date maps to negative dateMs")
    func ftsRecordNegativeEpoch() {
        // Dates before 1970
        let date = Date(timeIntervalSince1970: -86400)
        let dateMs = Int64(date.timeIntervalSince1970 * 1000)
        #expect(dateMs == -86400000)
    }
}

// MARK: - Bulk Index Walk Tests

/// The statistics a device may hold when the bulk index walks a folder: none
/// (before its first `ANALYZE`), stale (taken when the table was nearly empty),
/// or fresh.
enum BulkIndexWalkStatistics: String, CaseIterable, Sendable {
    case none, stale, fresh
}

/// The bulk index's walk, `SyncEngine.bulkIndexWalk`, run for real on a migrated
/// on-disk database: which headers it hands on, in what order, and what each page
/// reads. The fixtures hold only example.com data.
@Suite("SyncEngineFTS - Bulk Index Walk")
struct SyncEngineFTSBulkIndexTests {

    private static let accountId = "acc1"
    private static let inbox = "acc1:INBOX"
    private static let sent = "acc1:Sent"
    /// More pages than any fixture here needs: a walk past it is stuck, not slow.
    private static let pageCap = 40

    /// Every statement the pool ran, with its bound values inlined so it can be
    /// planned and run again (`expandedDescription`; see `SearchScopedPageTests.SQLTape`).
    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        @discardableResult
        func drain() -> [String] {
            statements.withLock { buffer in
                let all = buffer
                buffer = []
                return all
            }
        }
    }

    private struct Env {
        let pool: DatabasePool
        let directory: URL
        let tape: SQLTape
        var database: PrioritizedDatabase { PrioritizedDatabase(pool: pool, priority: .background) }
    }

    private struct WalkPastPageCap: Error {}

    private func makeEnv() throws -> Env {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-index-walk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tape = SQLTape()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
        }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        try AppDatabase.runMigrations(on: pool)
        try pool.write { db in
            var account = Account(emailAddress: "user@example.com", displayName: "User", provider: .imap)
            account.id = Self.accountId
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.accountId).insert(db)
            try Folder(name: "Sent", path: "Sent", role: .sent, accountId: Self.accountId).insert(db)
        }
        return Env(pool: pool, directory: directory, tape: tape)
    }

    private func finish(_ env: Env) {
        TestDatabaseTeardown.closeThenUnlinkNow(pool: env.pool, directory: env.directory)
    }

    /// Inserts one header per `(messageId, date)`, in order, so each gets a higher
    /// rowid than the one before it, and returns their ids.
    @discardableResult
    private func insert(_ env: Env, folderPath: String, _ entries: [(String, Date)]) throws -> [String] {
        try env.pool.write { db in
            try entries.map { messageId, date in
                let header = MessageHeader(
                    messageId: messageId, subject: "s", from: "a@example.com",
                    fromAddress: "a@example.com", to: "user@example.com", date: date,
                    snippet: "", folderId: "\(Self.accountId):\(folderPath)",
                    accountId: Self.accountId, folderPath: folderPath,
                    isInInbox: folderPath == "INBOX")
                try header.insert(db)
                return header.id
            }
        }
    }

    /// Runs the production walk and returns the header ids of every page it handed
    /// on. `afterPage` runs after each page is handed on, before the next is read.
    private func walk(
        _ env: Env, folderIds: [String], limit: Int,
        afterPage: (Int) throws -> Void = { _ in }
    ) async throws -> (pages: [[String]], finished: Bool) {
        var pages: [[String]] = []
        let finished = try await SyncEngine.bulkIndexWalk(
            folderIds: folderIds, dbPool: env.database, limit: limit
        ) { headers, pageNumber in
            pages.append(headers.map(\.id))
            guard pageNumber <= Self.pageCap else { throw WalkPastPageCap() }
            try afterPage(pageNumber)
        }
        return (pages, finished)
    }

    /// A whole second, so dates built from it by whole milliseconds keep their order once stored.
    private func wholeSecondNow() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    @Test("The walk hands on every header of each folder once, newest first, equal dates across pages included")
    func walkVisitsEveryHeaderOnce() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let now = wholeSecondNow()
        let hour: TimeInterval = 3600
        // INBOX, in insertion order. Three headers share one date and straddle the
        // first page boundary. "9", "12" and "13" fall in one second; "12" and "13"
        // share one millisecond and straddle the second page boundary.
        let inbox = try insert(env, folderPath: "INBOX", [
            ("7", now),
            ("30", now - hour), ("4", now - hour), ("100", now - hour),
            ("9", now - 2 * hour + 0.004),
            ("12", now - 2 * hour + 0.002), ("13", now - 2 * hour + 0.002),
            ("5", now - 3 * hour),
        ])
        // Sent is walked after INBOX and holds a header newer than any in INBOX: a
        // cursor carried over from INBOX would skip it.
        let sent = try insert(env, folderPath: "Sent", [
            ("8", now + hour), ("6", now - 4 * hour), ("2", now - 5 * hour),
        ])

        let result = try await walk(env, folderIds: [Self.inbox, Self.sent], limit: 3)

        // Newest first; among equal dates, the later insert (the higher rowid) first.
        let expected: [[String]] = [
            [inbox[0], inbox[3], inbox[2]],
            [inbox[1], inbox[4], inbox[6]],
            [inbox[5], inbox[7]],
            [sent[0], sent[1], sent[2]],
        ]
        #expect(result.finished)
        #expect(result.pages == expected)
    }

    @Test("Headers deleted or added between pages neither skip nor repeat the rest of the folder")
    func walkIsNotShiftedByChangesBetweenPages() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let now = wholeSecondNow()
        let entries: [(String, Date)] = (0..<6).map { ("\(10 + $0)", now - Double($0) * 60) }
        let ids = try insert(env, folderPath: "INBOX", entries)

        // After page 1 its first header is deleted: an OFFSET walk would then skip
        // a header. After page 2 a header newer than all is added: an OFFSET walk
        // would then read a header twice.
        let result = try await walk(env, folderIds: [Self.inbox], limit: 2) { pageNumber in
            switch pageNumber {
            case 1:
                try env.pool.write { db in
                    try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [ids[0]])
                }
            case 2:
                try self.insert(env, folderPath: "INBOX", [("99", now + 60)])
            default:
                break
            }
        }

        #expect(result.finished)
        #expect(result.pages == [[ids[0], ids[1]], [ids[2], ids[3]], [ids[4], ids[5]]])
    }

    @Test(
        "Every page reads through the folder's date index and costs what the first page costs, inside a long run of equal dates too",
        arguments: BulkIndexWalkStatistics.allCases)
    func everyPageReadsOnlyItsOwnRows(statistics: BulkIndexWalkStatistics) async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let now = wholeSecondNow()
        let tieSize = 2_000
        let limit = 200
        let olderCount = 50
        let day: TimeInterval = 86_400

        let older: [(String, Date)] = (0..<olderCount).map { ("old-\($0)", now - Double($0 + 1) * day) }
        try insert(env, folderPath: "INBOX", older)
        if statistics == .stale {
            try env.pool.write { db in try db.execute(sql: "ANALYZE") }
        }
        // A long run of headers that share one date, and a newer folder that a walk
        // of `messageHeader_date` would read before reaching any of them.
        let tie: [(String, Date)] = (0..<tieSize).map { ("tie-\($0)", now) }
        let tieIds = try insert(env, folderPath: "INBOX", tie)
        let newer: [(String, Date)] = (0..<300).map { ("sent-\($0)", now + 60) }
        try insert(env, folderPath: "Sent", newer)
        try env.pool.write { db in
            switch statistics {
            case .none:
                if try db.tableExists("sqlite_stat1") {
                    try db.execute(sql: "DELETE FROM sqlite_stat1")
                    try db.execute(sql: "ANALYZE sqlite_master")
                }
            case .stale:
                break
            case .fresh:
                try db.execute(sql: "ANALYZE")
            }
        }

        env.tape.drain()
        let result = try await walk(env, folderIds: [Self.inbox], limit: limit)
        let pageStatements = env.tape.drain().filter { $0.contains("bulkIndexRowID") }

        #expect(result.finished)
        let visited = result.pages.flatMap { $0 }
        #expect(visited.count == tieSize + olderCount)
        #expect(Set(visited).count == visited.count)
        // Every page handed on, then the empty read that ends the folder.
        #expect(pageStatements.count == result.pages.count + 1)

        // Each page statement exactly as it ran, planned and run again on the
        // writer, which holds this regime's statistics.
        let measured: [(plan: String, steps: Int32)] = try env.pool.write { db in
            try pageStatements.map { sql in
                let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql)
                    .map { $0["detail"] as String }
                    .joined(separator: " | ")
                let statement = try db.makeStatement(sql: sql)
                let rows = try Row.fetchCursor(statement)
                while try rows.next() != nil {}
                return (plan: plan, steps: sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_VM_STEP, 0))
            }
        }
        // Control: the statement these pages replaced, whose tie-break on `id` is not
        // in the index, at a cursor in the middle of the run, through the same measure.
        let middle = tieIds.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }[tieSize / 2]
        let control: Int32 = try env.pool.write { db in
            let statement = try db.makeStatement(sql: """
                SELECT * FROM messageHeader
                WHERE folderId = ? AND date <= ? AND (date < ? OR (date = ? AND id > ?))
                ORDER BY date DESC, id ASC LIMIT \(limit)
                """)
            statement.arguments = [Self.inbox, now, now, now, middle]
            let rows = try Row.fetchCursor(statement)
            while try rows.next() != nil {}
            return sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_VM_STEP, 0)
        }

        guard let first = measured.first else {
            Issue.record("no page statement was recorded")
            return
        }
        for (index, page) in measured.enumerated() {
            let pageNumber = index + 1
            #expect(page.plan.contains("USING INDEX messageHeader_folderId_date"), "page \(pageNumber): \(page.plan)")
            #expect(!page.plan.contains("SCAN"), "page \(pageNumber) scans: \(page.plan)")
            #expect(!page.plan.contains("TEMP B-TREE"), "page \(pageNumber) sorts: \(page.plan)")
            #expect(page.steps <= 2 * first.steps,
                    "page \(pageNumber) took \(page.steps) VM steps, the first page \(first.steps)")
        }
        #expect(control > 4 * first.steps,
                "the measure cannot see a page that re-reads a run of equal dates: \(control) vs \(first.steps)")
    }
}

// MARK: - Body Backfill Query Tests

@Suite("SyncEngineFTS - Body Backfill Queries")
struct SyncEngineFTSBodyBackfillTests {

    @Test("Body backfill JOIN query returns matching headers with bodies")
    func bodyBackfillJoinQuery() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert 3 headers, but only 2 have bodies
        let h1 = try TestDatabase.insertMessageHeader(db, messageId: "1", subject: "With Body 1", snippet: "s")
        let h2 = try TestDatabase.insertMessageHeader(db, messageId: "2", subject: "With Body 2", snippet: "s")
        try TestDatabase.insertMessageHeader(db, messageId: "3", subject: "No Body", snippet: "s")

        try TestDatabase.insertMessageBody(db, headerId: h1.id, htmlContent: "<p>Hello</p>")
        try TestDatabase.insertMessageBody(db, headerId: h2.id, htmlContent: "<p>World</p>")

        // Run the same JOIN query used by bulkIndexIfNeeded Phase 2
        let bodyHeaders: [(id: String, html: String?)] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT mh.id, mb.htmlContent
                FROM messageHeader mh
                JOIN messageBody mb ON mb.id = mh.id
                WHERE mh.folderId = ?
                LIMIT ?
                """, arguments: ["acc1:INBOX", 100])
                .map { ($0["id"] as String, $0["htmlContent"] as String?) }
        }

        #expect(bodyHeaders.count == 2)
        let ids = bodyHeaders.map(\.id)
        #expect(ids.contains(h1.id))
        #expect(ids.contains(h2.id))

        // Verify HTML content is returned
        for (headerId, html) in bodyHeaders {
            #expect(html != nil)
            if headerId == h1.id {
                #expect(html == "<p>Hello</p>")
            } else if headerId == h2.id {
                #expect(html == "<p>World</p>")
            }
        }
    }

    @Test("Body backfill skips nil or empty htmlContent")
    func bodyBackfillSkipsEmptyHTML() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let h1 = try TestDatabase.insertMessageHeader(db, messageId: "1", subject: "Valid Body", snippet: "s")
        let h2 = try TestDatabase.insertMessageHeader(db, messageId: "2", subject: "Nil Body", snippet: "s")
        let h3 = try TestDatabase.insertMessageHeader(db, messageId: "3", subject: "Empty Body", snippet: "s")

        try TestDatabase.insertMessageBody(db, headerId: h1.id, htmlContent: "<p>Content</p>")
        try TestDatabase.insertMessageBody(db, headerId: h2.id, htmlContent: nil)
        try TestDatabase.insertMessageBody(db, headerId: h3.id, htmlContent: "")

        let bodyHeaders: [(id: String, html: String?)] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT mh.id, mb.htmlContent
                FROM messageHeader mh
                JOIN messageBody mb ON mb.id = mh.id
                WHERE mh.folderId = ?
                LIMIT ?
                """, arguments: ["acc1:INBOX", 100])
                .map { ($0["id"] as String, $0["htmlContent"] as String?) }
        }

        // All 3 have MessageBody rows, so JOIN returns all 3
        #expect(bodyHeaders.count == 3)

        // Replicate the skip logic from SyncEngineFTS
        var processedCount = 0
        for (_, htmlContent) in bodyHeaders {
            guard let html = htmlContent, !html.isEmpty else { continue }
            processedCount += 1
            #expect(!html.isEmpty)
        }

        // Only 1 should pass the guard (h1 with actual content)
        #expect(processedCount == 1)
    }

    @Test("Body backfill JOIN respects folder filter")
    func bodyBackfillFolderFilter() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        let h1 = try TestDatabase.insertMessageHeader(db, messageId: "1", subject: "Inbox Msg", snippet: "s", folderId: "acc1:INBOX")
        let h2 = try TestDatabase.insertMessageHeader(db, messageId: "2", subject: "Sent Msg", snippet: "s", folderId: "acc1:Sent")

        try TestDatabase.insertMessageBody(db, headerId: h1.id, htmlContent: "<p>Inbox body</p>")
        try TestDatabase.insertMessageBody(db, headerId: h2.id, htmlContent: "<p>Sent body</p>")

        // Query only INBOX
        let inboxBodies: [(id: String, html: String?)] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT mh.id, mb.htmlContent
                FROM messageHeader mh
                JOIN messageBody mb ON mb.id = mh.id
                WHERE mh.folderId = ?
                LIMIT ?
                """, arguments: ["acc1:INBOX", 100])
                .map { ($0["id"] as String, $0["htmlContent"] as String?) }
        }

        #expect(inboxBodies.count == 1)
        #expect(inboxBodies[0].id == h1.id)

        // Query only Sent
        let sentBodies: [(id: String, html: String?)] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT mh.id, mb.htmlContent
                FROM messageHeader mh
                JOIN messageBody mb ON mb.id = mh.id
                WHERE mh.folderId = ?
                LIMIT ?
                """, arguments: ["acc1:Sent", 100])
                .map { ($0["id"] as String, $0["htmlContent"] as String?) }
        }

        #expect(sentBodies.count == 1)
        #expect(sentBodies[0].id == h2.id)
    }
}

// MARK: - Array.chunked Extension Tests

@Suite("SyncEngineFTS - Array.chunked Extension")
struct SyncEngineFTSArrayChunkedTests {

    @Test("Chunked with remainder produces correct chunks")
    func chunkedWithRemainder() {
        let result = [1, 2, 3, 4, 5].chunked(into: 2)
        #expect(result.count == 3)
        #expect(result[0] == [1, 2])
        #expect(result[1] == [3, 4])
        #expect(result[2] == [5])
    }

    @Test("Chunked with exact division produces even chunks")
    func chunkedExactDivision() {
        let result = [1, 2, 3, 4].chunked(into: 2)
        #expect(result.count == 2)
        #expect(result[0] == [1, 2])
        #expect(result[1] == [3, 4])
    }

    @Test("Chunked with size larger than array returns single chunk")
    func chunkedLargerSize() {
        let result = [1, 2, 3].chunked(into: 10)
        #expect(result.count == 1)
        #expect(result[0] == [1, 2, 3])
    }

    @Test("Chunked with empty array returns empty")
    func chunkedEmptyArray() {
        let result: [[Int]] = [Int]().chunked(into: 2)
        #expect(result.isEmpty)
    }

    @Test("Chunked with size equal to array length returns single chunk")
    func chunkedSizeEqualsLength() {
        let result = [1, 2, 3].chunked(into: 3)
        #expect(result.count == 1)
        #expect(result[0] == [1, 2, 3])
    }

    @Test("Chunked with size 1 returns individual elements")
    func chunkedSizeOne() {
        let result = [10, 20, 30].chunked(into: 1)
        #expect(result.count == 3)
        #expect(result[0] == [10])
        #expect(result[1] == [20])
        #expect(result[2] == [30])
    }
}
