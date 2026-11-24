/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
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

// MARK: - Bulk Index Query Tests

@Suite("SyncEngineFTS - Bulk Index Queries")
struct SyncEngineFTSBulkIndexTests {

    /// Pages `folderId` to the end exactly as `bulkIndexIfNeeded` does: the
    /// production request, and the next cursor from `BulkIndexCursor(after:)`. At
    /// most `maxPages` pages, so a cursor that stops advancing fails the test
    /// instead of hanging it.
    private func pageAll(
        _ db: DatabaseQueue, folderId: String, limit: Int, maxPages: Int = 50
    ) throws -> [[String]] {
        var pages: [[String]] = []
        var cursor: SyncEngine.BulkIndexCursor?
        for _ in 0..<maxPages {
            let after = cursor
            let page: [MessageHeader] = try db.read { conn in
                try SyncEngine.bulkIndexPageRequest(folderId: folderId, after: after, limit: limit)
                    .fetchAll(conn)
            }
            guard let next = SyncEngine.BulkIndexCursor(after: page) else { return pages }
            pages.append(page.map(\.id))
            cursor = next
        }
        Issue.record("bulk index paging did not reach the end of the folder in \(maxPages) pages")
        return pages
    }

    @Test("Bulk index paging visits every header of the folder once, newest first, ties included")
    func bulkIndexPagingVisitsEveryHeaderOnce() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        // Whole seconds, so the stored dates compare equal to the inserted ones.
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970).rounded(.down))
        let hour: TimeInterval = 3600
        // Three headers share one date and straddle the boundary between pages 1
        // and 2 (limit 2); two more share another. Their message ids sort as
        // strings in a different order than they are inserted ("100" < "30" < "4").
        let plan: [(messageId: String, date: Date)] = [
            ("7", now),
            ("30", now.addingTimeInterval(-hour)),
            ("4", now.addingTimeInterval(-hour)),
            ("100", now.addingTimeInterval(-hour)),
            ("9", now.addingTimeInterval(-2 * hour)),
            ("12", now.addingTimeInterval(-2 * hour)),
            ("5", now.addingTimeInterval(-3 * hour)),
        ]
        var inserted: [MessageHeader] = []
        for entry in plan {
            let header = try TestDatabase.insertMessageHeader(
                db, messageId: entry.messageId, date: entry.date, folderId: "acc1:INBOX")
            inserted.append(header)
        }
        // Another folder's header, newer than all of them, must never appear.
        let other = try TestDatabase.insertMessageHeader(
            db, messageId: "8", date: now.addingTimeInterval(hour),
            folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false)

        // SQLite's BINARY order on `id` is UTF-8 byte order; Swift's `<` on
        // `String` is not (see `InboxOrdering`).
        let expected = inserted
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
            .map(\.id)
        let pages = try pageAll(db, folderId: "acc1:INBOX", limit: 2)
        let visited = pages.flatMap { $0 }

        #expect(visited == expected)
        #expect(Set(visited).count == visited.count)
        #expect(!visited.contains(other.id))
        let pageSizes = pages.map(\.count)
        #expect(pageSizes == [2, 2, 2, 1])
    }

    @Test("A bulk index page after a cursor seeks the folder's date index at the cursor, with no OFFSET")
    func bulkIndexPageSeeksAtTheCursor() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX")
        let cursor = try #require(SyncEngine.BulkIndexCursor(after: [header]))

        // Planned with no statistics: what a device has until its first ANALYZE.
        let planned: (sql: String, plan: String) = try db.write { conn in
            if try conn.tableExists("sqlite_stat1") {
                try conn.execute(sql: "DELETE FROM sqlite_stat1")
                try conn.execute(sql: "ANALYZE sqlite_master")
            }
            let statement = try SyncEngine
                .bulkIndexPageRequest(folderId: "acc1:INBOX", after: cursor, limit: 200)
                .makePreparedRequest(conn, forSingleResult: false)
                .statement
            let plan = try Row.fetchAll(
                conn, sql: "EXPLAIN QUERY PLAN " + statement.sql, arguments: statement.arguments)
                .map { $0["detail"] as String }
                .joined(separator: " | ")
            return (statement.sql, plan)
        }

        let seeksAtCursor = planned.plan.contains("messageHeader_folderId_date (folderId=? AND date<?)")
        #expect(seeksAtCursor, "the page no longer seeks to the cursor's date: \(planned.plan)")
        #expect(!planned.plan.contains("SCAN"), "the page scans: \(planned.plan)")
        #expect(!planned.sql.uppercased().contains("OFFSET"), "the page uses OFFSET: \(planned.sql)")
    }

    @Test("Bulk index iterates each folder separately")
    func bulkIndexPerFolderIteration() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        // Insert messages into different folders
        for i in 1...3 {
            try TestDatabase.insertMessageHeader(
                db,
                messageId: "inbox-\(i)",
                subject: "Inbox \(i)",
                snippet: "Snippet",
                folderId: "acc1:INBOX"
            )
        }
        for i in 1...2 {
            try TestDatabase.insertMessageHeader(
                db,
                messageId: "sent-\(i)",
                subject: "Sent \(i)",
                snippet: "Snippet",
                folderId: "acc1:Sent"
            )
        }

        // Fetch folder IDs for the account (same query as bulkIndexIfNeeded)
        let folderIds: [String] = try db.read { dbConn in
            try String.fetchAll(dbConn,
                Folder.select(Column("id")).filter(Column("accountId") == "acc1")
            )
        }
        #expect(folderIds.count == 2)

        // Count messages per folder
        var counts: [String: Int] = [:]
        for fi in folderIds {
            let count = try db.read { dbConn in
                try MessageHeader.filter(Column("folderId") == fi).fetchCount(dbConn)
            }
            counts[fi] = count
        }
        #expect(counts["acc1:INBOX"] == 3)
        #expect(counts["acc1:Sent"] == 2)

        // Verify total
        let totalCount = counts.values.reduce(0, +)
        #expect(totalCount == 5)
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
