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
/// on-disk database: which headers it hands on, in what order, what each page
/// reads (every statement the database ran, with its cost, as SQLite reports it),
/// how it ends on cancellation and on failure, and, against the OFFSET read it
/// replaced, that its pages are the same pages in the same order. The fixtures
/// hold only example.com data.
@Suite("SyncEngineFTS - Bulk Index Walk")
struct SyncEngineFTSBulkIndexTests {

    private static let accountId = "acc1"
    private static let inbox = "acc1:INBOX"
    private static let sent = "acc1:Sent"
    /// More pages than any fixture here needs: a walk past it is stuck, not slow.
    private static let pageCap = 40

    /// Every statement the pool's connections ran, as SQLite itself reports it when
    /// the statement finishes: its SQL as prepared, with the values it ran with, and
    /// the virtual-machine steps that run took. Recorded on readers and the writer
    /// alike, so it sees exactly what the walk read, whichever connection read it.
    private final class StatementProfile: Sendable {
        struct Run: Sendable {
            let sql: String
            let expanded: String
            let steps: Int32
        }
        private let runs = Mutex<[Run]>([])
        func record(_ run: Run) { runs.withLock { $0.append(run) } }
        @discardableResult
        func drain() -> [Run] {
            runs.withLock { buffer in
                let all = buffer
                buffer = []
                return all
            }
        }

        /// Installs SQLite's profile callback on `connection`, reporting to `profile`.
        static func install(on connection: OpaquePointer, reportingTo profile: StatementProfile) {
            sqlite3_trace_v2(connection, UInt32(SQLITE_TRACE_PROFILE), { _, context, statementPointer, _ in
                guard let context, let statementPointer else { return 0 }
                let statement = OpaquePointer(statementPointer)
                let steps = sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1)
                let sql = sqlite3_sql(statement).map { String(cString: $0) } ?? ""
                var expanded = sql
                if let text = sqlite3_expanded_sql(statement) {
                    expanded = String(cString: text)
                    sqlite3_free(text)
                }
                Unmanaged<StatementProfile>.fromOpaque(context).takeUnretainedValue()
                    .record(Run(sql: sql, expanded: expanded, steps: steps))
                return 0
            }, Unmanaged.passUnretained(profile).toOpaque())
        }
    }

    private struct Env {
        let pool: DatabasePool
        let directory: URL
        let profile: StatementProfile
        var database: PrioritizedDatabase { PrioritizedDatabase(pool: pool, priority: .background) }
    }

    private struct WalkPastPageCap: Error {}
    private struct IndexWriteFailed: Error {}

    private func makeEnv() throws -> Env {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-index-walk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = StatementProfile()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            if let connection = db.sqliteConnection {
                StatementProfile.install(on: connection, reportingTo: profile)
            }
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
        return Env(pool: pool, directory: directory, profile: profile)
    }

    /// One SQL text per statement, whatever its line breaks and indentation.
    private static func normalized(_ sql: String) -> String {
        sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The plan of `sql` with `arguments` bound, one line per plan row.
    private static func plan(_ db: Database, _ sql: String, _ arguments: StatementArguments) throws -> String {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
            .map { $0["detail"] as String }
            .joined(separator: " | ")
    }

    private func finish(_ env: Env) {
        TestDatabaseTeardown.closeThenUnlinkNow(pool: env.pool, directory: env.directory)
    }

    /// Inserts one header per `(messageId, date)` into the account's folder, in
    /// order, so each gets a higher rowid than the one before it, and returns their ids.
    @discardableResult
    private func insert(
        _ env: Env, accountId: String = SyncEngineFTSBulkIndexTests.accountId,
        folderPath: String, _ entries: [(String, Date)]
    ) throws -> [String] {
        try env.pool.write { db in
            try entries.map { messageId, date in
                let header = MessageHeader(
                    messageId: messageId, subject: "s", from: "a@example.com",
                    fromAddress: "a@example.com", to: "user@example.com", date: date,
                    snippet: "", folderId: "\(accountId):\(folderPath)",
                    accountId: accountId, folderPath: folderPath,
                    isInInbox: folderPath == "INBOX")
                try header.insert(db)
                return header.id
            }
        }
    }

    /// Adds an account with one folder per path (`env` holds `accountId` already).
    private func addAccount(_ env: Env, _ accountId: String, folders: [String]) throws {
        try env.pool.write { db in
            if try Account.fetchOne(db, key: accountId) == nil {
                var account = Account(emailAddress: "\(accountId)@example.com", displayName: "User", provider: .imap)
                account.id = accountId
                try account.insert(db)
            }
            for path in folders {
                try Folder(name: path, path: path, role: path == "INBOX" ? .inbox : .archive, accountId: accountId)
                    .insert(db)
            }
        }
    }

    /// The header reads among `runs`: every statement that names the header table,
    /// pragmas aside.
    private static func headerReads(_ runs: [StatementProfile.Run]) -> [StatementProfile.Run] {
        runs.filter { run in
            let sql = normalized(run.sql)
            return sql.range(of: "messageHeader", options: .caseInsensitive) != nil
                && !sql.uppercased().hasPrefix("PRAGMA")
        }
    }

    /// Reads `sql` once on a reader and returns the VM steps the profile saw that read take.
    private func readSteps(_ env: Env, _ sql: String, _ arguments: StatementArguments) async throws -> Int32? {
        env.profile.drain()
        _ = try await env.pool.read { db in try Row.fetchAll(db, sql: sql, arguments: arguments).count }
        let target = Self.normalized(sql)
        return env.profile.drain().last { Self.normalized($0.sql) == target }?.steps
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
        let stale = try await oneHeaderStatistics()
        let env = try makeEnv()
        defer { finish(env) }
        let now = wholeSecondNow()
        let tieSize = 2_000
        let limit = 200
        let olderCount = 50
        let day: TimeInterval = 86_400

        let older: [(String, Date)] = (0..<olderCount).map { ("old-\($0)", now - Double($0 + 1) * day) }
        try insert(env, folderPath: "INBOX", older)
        // A long run of headers that share one date, and a newer folder that a walk
        // of `messageHeader_date` would read before reaching any of them.
        let tie: [(String, Date)] = (0..<tieSize).map { ("tie-\($0)", now) }
        let tieIds = try insert(env, folderPath: "INBOX", tie)
        let newer: [(String, Date)] = (0..<300).map { ("sent-\($0)", now + 60) }
        try insert(env, folderPath: "Sent", newer)
        try await applyStatistics(env, statistics, stale: stale)

        // Every header read the walk made, as SQLite ran it, on whichever connection.
        env.profile.drain()
        let result = try await walk(env, folderIds: [Self.inbox], limit: limit)
        let reads = Self.headerReads(env.profile.drain())

        #expect(result.finished)
        let visited = result.pages.flatMap { $0 }
        #expect(visited.count == tieSize + olderCount)
        #expect(Set(visited).count == visited.count)
        // The walk reads headers only through its two page statements: the first
        // page, then one read after each page handed on (the last finds the end).
        let firstPage = Self.normalized(SyncEngine.bulkIndexFirstPageSQL)
        let nextPage = Self.normalized(SyncEngine.bulkIndexNextPageSQL)
        let texts = reads.map { Self.normalized($0.sql) }
        let expectedTexts = [firstPage] + Array(repeating: nextPage, count: result.pages.count)
        #expect(texts == expectedTexts, "the walk read headers otherwise: \(texts)")

        guard let first = reads.first else {
            Issue.record("the walk read no header")
            return
        }
        // Every read costs at most twice what the first page costs ...
        for (index, read) in reads.enumerated() {
            #expect(read.steps <= 2 * first.steps,
                    "read \(index + 1) took \(read.steps) VM steps, the first page \(first.steps): \(read.expanded)")
        }
        // ... and the first page costs a fraction of reading the folder.
        let folderSteps = try await readSteps(env, "SELECT * FROM messageHeader WHERE folderId = ?", [Self.inbox])
        let folder = try #require(folderSteps)
        #expect(4 * first.steps < folder,
                "the first page took \(first.steps) VM steps, reading the whole folder \(folder)")

        // Each page statement planned as it ran: the same SQL and bound values, on a
        // reader, which loads this regime's statistics. The cursor after a page is its
        // last header's date and rowid.
        let lastIds = result.pages.compactMap(\.last)
        let plans: [String] = try await env.pool.read { db in
            let firstPlan = try Self.plan(db, SyncEngine.bulkIndexFirstPageSQL, [Self.inbox, limit])
            var plans = [firstPlan]
            for id in lastIds {
                let row = try Row.fetchOne(
                    db, sql: "SELECT date, rowid AS cursorRowID FROM messageHeader WHERE id = ?", arguments: [id])
                guard let row else { continue }
                let date: DatabaseValue = row["date"]
                let rowID: Int64 = row["cursorRowID"]
                let nextPlan = try Self.plan(db, SyncEngine.bulkIndexNextPageSQL, [Self.inbox, date, rowID, limit])
                plans.append(nextPlan)
            }
            return plans
        }
        #expect(plans.count == result.pages.count + 1)
        for (index, plan) in plans.enumerated() {
            #expect(plan.contains("USING INDEX messageHeader_folderId_date"), "statement \(index + 1): \(plan)")
            if index > 0 {
                #expect(plan.contains("(date,rowid)<(?,?)"),
                        "statement \(index + 1) does not seek past its cursor: \(plan)")
            }
            #expect(!plan.contains("SCAN"), "statement \(index + 1) scans: \(plan)")
            #expect(!plan.contains("TEMP B-TREE"), "statement \(index + 1) sorts: \(plan)")
        }

        // Control: the statement these pages replaced, whose tie-break on `id` is not
        // in the index, at a cursor in the middle of the run, through the same measure.
        let middle = tieIds.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }[tieSize / 2]
        let controlSteps = try await readSteps(env, """
            SELECT * FROM messageHeader
            WHERE folderId = ? AND date <= ? AND (date < ? OR (date = ? AND id > ?))
            ORDER BY date DESC, id ASC LIMIT ?
            """, [Self.inbox, now, now, now, middle, limit])
        let control = try #require(controlSteps)
        #expect(control > 4 * first.steps,
                "the measure cannot see a page that re-reads a run of equal dates: \(control) vs \(first.steps)")
    }

    // MARK: Exits: cancellation, an unreadable page, a failed page

    @Test("A walk cancelled while it hands on a page reads no further page and reports that it did not finish")
    func cancelledWalkReadsNoFurtherPage() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let now = wholeSecondNow()
        let inbox = try insert(env, folderPath: "INBOX", (0..<6).map { ("\(20 + $0)", now - Double($0) * 60) })
        try insert(env, folderPath: "Sent", [("40", now)])

        env.profile.drain()
        let run = Task {
            try await self.walk(env, folderIds: [Self.inbox, Self.sent], limit: 2) { pageNumber in
                // The task the walk runs in is cancelled while it hands on page 1.
                if pageNumber == 1 {
                    withUnsafeCurrentTask { task in
                        if let task { task.cancel() }
                    }
                }
            }
        }
        let result = try await run.value
        let reads = Self.headerReads(env.profile.drain())

        #expect(!result.finished)
        #expect(result.pages == [[inbox[0], inbox[1]]])
        #expect(reads.count == 1, "the cancelled walk read on: \(reads.map(\.expanded))")
    }

    @Test("A page that cannot be read ends only its own folder: the next folder is still walked")
    func unreadablePageEndsOnlyItsFolder() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let now = wholeSecondNow()
        let inbox = try insert(env, folderPath: "INBOX", [("50", now), ("51", now - 60)])
        let sent = try insert(env, folderPath: "Sent", [("60", now), ("61", now - 60)])
        // A date no header decodes from, so INBOX's first page throws.
        let unreadable = inbox[0]
        try await env.pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET date = 'not a date' WHERE id = ?", arguments: [unreadable])
        }

        let result = try await walk(env, folderIds: [Self.inbox, Self.sent], limit: 5)

        #expect(result.finished)
        #expect(result.pages == [sent])
    }

    @Test("A page whose indexing throws ends the walk with that error, and no later page is read")
    func failedPageEndsTheWalk() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let now = wholeSecondNow()
        try insert(env, folderPath: "INBOX", (0..<6).map { ("\(70 + $0)", now - Double($0) * 60) })
        try insert(env, folderPath: "Sent", [("80", now)])

        env.profile.drain()
        var handedOn: [Int] = []
        var thrown: (any Error)?
        do {
            _ = try await SyncEngine.bulkIndexWalk(
                folderIds: [Self.inbox, Self.sent], dbPool: env.database, limit: 2
            ) { _, pageNumber in
                handedOn.append(pageNumber)
                if pageNumber == 2 { throw IndexWriteFailed() }
            }
        } catch {
            thrown = error
        }
        let reads = Self.headerReads(env.profile.drain())

        let failedAsThrown = (thrown as? IndexWriteFailed) != nil
        #expect(failedAsThrown, "the walk ended with \(String(describing: thrown))")
        #expect(handedOn == [1, 2])
        #expect(reads.count == 2, "the walk read on after a failed page: \(reads.map(\.expanded))")
    }

    // MARK: Differential: the walk's pages are the pages of the OFFSET walk it replaced

    /// The page read the walk replaced, kept here as the oracle: a folder's headers,
    /// newest first, `limit` at a time from `offset`, as the bulk index read them
    /// before it paged by key.
    private static func offsetRequest(folderId: String, offset: Int, limit: Int) -> QueryInterfaceRequest<MessageHeader> {
        MessageHeader
            .filter(Column("folderId") == folderId)
            .order(Column("date").desc)
            .limit(limit, offset: offset)
    }

    /// Every page of `folderId` read by the oracle, the offset advancing by each page.
    private func offsetPages(_ env: Env, folderId: String, limit: Int, cap: Int) async throws -> [[String]] {
        var pages: [[String]] = []
        var offset = 0
        while pages.count <= cap {
            let currentOffset = offset
            let page: [String] = try await env.pool.read { db in
                try Self.offsetRequest(folderId: folderId, offset: currentOffset, limit: limit)
                    .asRequest(of: Row.self)
                    .fetchAll(db)
                    .map { $0["id"] as String }
            }
            guard !page.isEmpty else { return pages }
            pages.append(page)
            offset += page.count
        }
        throw WalkPastPageCap()
    }

    /// Every page of `folderId` read by the walk's page read, each cursor carried to the next.
    private func keysetPages(_ env: Env, folderId: String, limit: Int, cap: Int) async throws -> [[String]] {
        var pages: [[String]] = []
        var cursor: SyncEngine.BulkIndexCursor?
        while pages.count <= cap {
            let after = cursor
            let page = try await env.pool.read { db in
                try SyncEngine.bulkIndexPage(db, folderId: folderId, after: after, limit: limit)
            }
            guard let next = page.next else { return pages }
            pages.append(page.headers.map(\.id))
            cursor = next
        }
        throw WalkPastPageCap()
    }

    /// For every folder and page size, the walk's pages must be the oracle's, in the
    /// same order and split the same way. The oracle's order among equal dates is the
    /// order of the index it reads, so its plan is checked and printed for each case.
    private func expectSamePages(
        _ env: Env, folderIds: [String], limits: [Int], statistics: BulkIndexWalkStatistics, cap: Int
    ) async throws {
        for folderId in folderIds {
            for limit in limits {
                let oraclePlan: String = try await env.pool.read { db in
                    let prepared = try Self.offsetRequest(folderId: folderId, offset: limit, limit: limit)
                        .makePreparedRequest(db, forSingleResult: false)
                    return try Self.plan(db, prepared.statement.sql, prepared.statement.arguments)
                }
                print("[bulk-index differential] statistics: \(statistics), folder: \(folderId), limit: \(limit), OFFSET plan: \(oraclePlan)")
                #expect(oraclePlan.contains("USING INDEX messageHeader_folderId_date"),
                        "the OFFSET walk left the folder's date index under \(statistics) statistics: \(oraclePlan)")

                let old = try await offsetPages(env, folderId: folderId, limit: limit, cap: cap)
                let new = try await keysetPages(env, folderId: folderId, limit: limit, cap: cap)
                let oldIds = old.flatMap { $0 }
                let newIds = new.flatMap { $0 }
                let firstDifference = oldIds.indices.first { $0 >= newIds.count || oldIds[$0] != newIds[$0] }
                let same = new == old
                #expect(same, """
                    \(folderId), \(limit) a page, \(statistics) statistics: the walk handed on \(newIds.count) \
                    headers in \(new.count) pages, the OFFSET walk \(oldIds.count) in \(old.count); first \
                    difference at \(String(describing: firstDifference))
                    """)
            }
        }
    }

    @Test(
        "The walk's pages are the OFFSET walk's: empty and one-header folders, equal dates across page boundaries, two accounts",
        arguments: BulkIndexWalkStatistics.allCases)
    func pagesMatchTheOffsetWalk(statistics: BulkIndexWalkStatistics) async throws {
        let stale = try await oneHeaderStatistics()
        let env = try makeEnv()
        defer { finish(env) }
        let other = "acc2"
        try addAccount(env, Self.accountId, folders: ["Archive"])
        try addAccount(env, other, folders: ["INBOX"])
        let now = wholeSecondNow()
        let ms = 0.001
        // Dates shared to the millisecond, dates one millisecond apart, and the same
        // dates in the other account's INBOX. The inserts alternate between the two
        // folders and do not run in date order, so neither folder's rowids follow
        // its dates.
        let dates: [Date] = [
            now, now, now - ms, now, now - 2 * ms, now - ms, now - 3_600, now - 3_600,
            now - 3_600, now - 3_600 + ms, now - 7_200, now, now - 3_600,
        ]
        for (n, date) in dates.enumerated() {
            try insert(env, folderPath: "INBOX", [("\(100 + n)", date)])
            try insert(env, accountId: other, folderPath: "INBOX", [("\(100 + n)", date)])
        }
        try insert(env, folderPath: "Sent", [("200", now)])
        // "acc1:Archive" stays empty.
        try await applyStatistics(env, statistics, stale: stale)

        try await expectSamePages(
            env,
            folderIds: [Self.inbox, "\(other):INBOX", Self.sent, "\(Self.accountId):Archive"],
            limits: [1, 2, 3, 4, 5, SyncConfig.ftsIndexBatchSize],
            statistics: statistics, cap: 40)
    }

    @Test(
        "The walk's pages are the OFFSET walk's on a database of 100,000 headers in three folders of two accounts",
        arguments: BulkIndexWalkStatistics.allCases)
    func pagesMatchTheOffsetWalkAtScale(statistics: BulkIndexWalkStatistics) async throws {
        let stale = try await oneHeaderStatistics()
        let env = try makeEnv()
        defer { finish(env) }
        // Account ids shaped like the app's.
        let first = UUID().uuidString
        let second = UUID().uuidString
        try addAccount(env, first, folders: ["INBOX", "Archive"])
        try addAccount(env, second, folders: ["INBOX"])
        let now = wholeSecondNow()
        let folders: [(accountId: String, path: String, count: Int)] = [
            (first, "INBOX", 60_000), (first, "Archive", 20_000), (second, "INBOX", 20_000),
        ]
        for folder in folders {
            let template = try insert(env, accountId: folder.accountId, folderPath: folder.path, [("template", now)])
            try await clone(env, templateId: template[0], count: folder.count - 1)
        }
        let total = try await env.pool.read { db in try MessageHeader.fetchCount(db) }
        #expect(total == 100_000)
        try await applyStatistics(env, statistics, stale: stale)

        try await expectSamePages(
            env,
            folderIds: folders.map { "\($0.accountId):\($0.path)" },
            limits: [SyncConfig.ftsIndexBatchSize],
            statistics: statistics, cap: 400)
    }

    /// Adds `count` copies of the header `templateId` to its folder in one statement,
    /// each with an id and Message-ID of its own, and a date one minute further back
    /// every seven copies, so seven headers share each date.
    private func clone(_ env: Env, templateId: String, count: Int) async throws {
        try await env.pool.write { db in
            let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('messageHeader')")
            let values = columns.map { column -> String in
                switch column {
                case "id": return "t.folderId || ':c' || n.i"
                case "messageId": return "'c' || n.i"
                case "date": return "strftime('%Y-%m-%d %H:%M:%f', t.date, '-' || (n.i / 7) || ' minutes')"
                default: return "t.\"\(column)\""
                }
            }
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
                INSERT INTO messageHeader (\(columns.map { "\"\($0)\"" }.joined(separator: ", ")))
                SELECT \(values.joined(separator: ", ")) FROM n, messageHeader AS t WHERE t.id = ?
                """, arguments: [count, templateId])
        }
    }

    /// The statistics an `ANALYZE` writes while the header table holds one header, as
    /// `(tbl, idx, stat)` rows: what a device keeps when its last `ANALYZE` ran on a
    /// nearly empty database.
    private func oneHeaderStatistics() async throws -> [[String?]] {
        let env = try makeEnv()
        defer { finish(env) }
        try insert(env, folderPath: "INBOX", [("1", wholeSecondNow())])
        return try await env.pool.write { db in
            try db.execute(sql: "ANALYZE")
            return try Row.fetchAll(db, sql: "SELECT tbl, idx, stat FROM sqlite_stat1").map { row -> [String?] in
                [row["tbl"], row["idx"], row["stat"]]
            }
        }
    }

    /// Puts the planner statistics of `statistics` in place on a database whose rows
    /// are all inserted: none, the app's own (`fresh`), or `stale` (rows an `ANALYZE`
    /// wrote while the table held one header). Then closes the idle readers, so every
    /// read after this opens a connection that loads them.
    private func applyStatistics(
        _ env: Env, _ statistics: BulkIndexWalkStatistics, stale: [[String?]]
    ) async throws {
        try await env.pool.write { db in
            // The statement the app's statistics refresh runs
            // (`SyncEngine.runRefreshPlannerStatisticsIfStale`); it also creates the tables.
            try db.execute(sql: "ANALYZE")
            if statistics != .fresh {
                try db.execute(sql: "DELETE FROM sqlite_stat1")
                if try db.tableExists("sqlite_stat4") {
                    try db.execute(sql: "DELETE FROM sqlite_stat4")
                }
            }
            if statistics == .stale {
                for row in stale {
                    try db.execute(
                        sql: "INSERT INTO sqlite_stat1 (tbl, idx, stat) VALUES (?, ?, ?)",
                        arguments: [row[0], row[1], row[2]])
                }
            }
            // Makes the planner read the statistics tables again.
            try db.execute(sql: "ANALYZE sqlite_master")
        }
        env.pool.releaseMemory()
    }
}

// MARK: - Bulk Index Entry Tests

/// `SyncEngine.bulkIndexIfNeeded`, the walk's one caller, on the app's own
/// database and search index: an account its index is missing is indexed whole and
/// its headers marked complete; an account at most ten entries short opens no walk.
/// Each test uses an account of its own and removes it, its headers and its search
/// entries afterwards. The fixtures hold only example.com data.
@Suite("SyncEngineFTS - Bulk Index Entry", .serialized, .processGlobalState)
struct SyncEngineFTSBulkIndexEntryTests {

    /// An account with an INBOX and an Archive and `count` headers spread over them,
    /// none marked complete; returns the account and the header ids.
    private func seed(count: Int) async throws -> (account: Account, headerIds: [String]) {
        let account = Account(emailAddress: "bulk-entry@example.com", displayName: "User", provider: .imap)
        let now = Date()
        let ids: [String] = try await AppDatabase.dbPool.write { db in
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: account.id).insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: account.id).insert(db)
            return try (0..<count).map { n in
                let path = n.isMultiple(of: 3) ? "Archive" : "INBOX"
                let header = MessageHeader(
                    messageId: "\(n + 1)", subject: "s", from: "a@example.com",
                    fromAddress: "a@example.com", to: "user@example.com",
                    date: now - Double(n) * 60, snippet: "",
                    folderId: MessageIdentity.folderId(accountId: account.id, folderPath: path),
                    accountId: account.id, folderPath: path, isInInbox: path == "INBOX")
                try header.insert(db)
                return header.id
            }
        }
        return (account, ids)
    }

    /// Runs the bulk index for `account` to its end; returns whether the run gave
    /// up the account's slot when it ended.
    private func runBulkIndex(_ account: Account) async throws -> Bool {
        let engine = SyncEngine()
        let started = await engine.bulkIndexIfNeeded(account: account)
        let task = try #require(started)
        try await withTimeout(seconds: 60) { await task.value }
        let slot = await engine.bulkIndexTasks[account.id]
        return slot == nil
    }

    /// The account's search entries, and its headers marked complete.
    private func state(_ accountId: String) async throws -> (indexed: Int, complete: Int) {
        let indexed = try await SearchIndex.shared.documentCountForAccount(accountId: accountId)
        let complete = try await AppDatabase.dbPool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messageHeader WHERE accountId = ? AND headerComplete = 1",
                arguments: [accountId]) ?? 0
        }
        return (indexed, complete)
    }

    private func cleanup(_ accountId: String) async {
        try? await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE accountId = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM folder WHERE accountId = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
        }
        try? await SearchIndex.shared.removeMessagesForAccount(accountId: accountId)
    }

    @Test("An account its search index is missing is indexed whole, every header is marked complete, and its slot is freed")
    func sparseAccountIsIndexed() async throws {
        try await SearchIndex.shared.initialize()
        let seeded = try await seed(count: 30)
        let accountId = seeded.account.id
        let before = try await state(accountId)
        let released = try await runBulkIndex(seeded.account)
        let after = try await state(accountId)
        await cleanup(accountId)

        #expect(before.indexed == 0)
        #expect(before.complete == 0)
        #expect(after.indexed == seeded.headerIds.count)
        #expect(after.complete == seeded.headerIds.count)
        #expect(released)
    }

    @Test("An account whose search index is ten entries short opens no walk: nothing is indexed or marked")
    func accountTenShortIsLeftAlone() async throws {
        try await SearchIndex.shared.initialize()
        let seeded = try await seed(count: 15)
        let accountId = seeded.account.id
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let records = seeded.headerIds.prefix(5).map { hid in
            FTSHeaderRecord(contentKey: ContentKey(rawValue: hid), headerId: hid, messageId: hid,
                            subject: "s", from: "a@example.com", to: "user@example.com", dateMs: nowMs)
        }
        let inserted = try await SearchIndex.shared.indexHeaders(Array(records))
        let released = try await runBulkIndex(seeded.account)
        let after = try await state(accountId)
        await cleanup(accountId)

        #expect(inserted == 5)
        #expect(after.indexed == 5)
        #expect(after.complete == 0)
        #expect(released)
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
