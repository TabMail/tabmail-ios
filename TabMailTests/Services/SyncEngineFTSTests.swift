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
        let record = FTSHeaderRecord(
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

        let record = FTSHeaderRecord(
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
        let record = FTSHeaderRecord(
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

        // Replicate the mapping from SyncEngineFTS.indexHeadersForFTS
        let records = headers.map { header in
            FTSHeaderRecord(
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
        let record = FTSHeaderRecord(
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
        let record = FTSHeaderRecord(
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

    @Test("Paginated fetch returns messages ordered by date descending with limit and offset")
    func bulkIndexPaginatedFetch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert 5 messages with distinct dates
        let baseDateInterval: TimeInterval = 1700000000
        for i in 1...5 {
            try TestDatabase.insertMessageHeader(
                db,
                messageId: "\(i)",
                subject: "Message \(i)",
                date: Date(timeIntervalSince1970: baseDateInterval + Double(i) * 3600),
                snippet: "Snippet \(i)"
            )
        }

        // First page: limit 2, offset 0 — should get the 2 most recent (5, 4)
        let page1: [MessageHeader] = try db.read { dbConn in
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX")
                .order(Column("date").desc)
                .limit(2, offset: 0)
                .fetchAll(dbConn)
        }
        #expect(page1.count == 2)
        #expect(page1[0].messageId == "5")
        #expect(page1[1].messageId == "4")

        // Second page: limit 2, offset 2 — should get (3, 2)
        let page2: [MessageHeader] = try db.read { dbConn in
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX")
                .order(Column("date").desc)
                .limit(2, offset: 2)
                .fetchAll(dbConn)
        }
        #expect(page2.count == 2)
        #expect(page2[0].messageId == "3")
        #expect(page2[1].messageId == "2")

        // Third page: limit 2, offset 4 — should get (1)
        let page3: [MessageHeader] = try db.read { dbConn in
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX")
                .order(Column("date").desc)
                .limit(2, offset: 4)
                .fetchAll(dbConn)
        }
        #expect(page3.count == 1)
        #expect(page3[0].messageId == "1")

        // Beyond last page: offset 5 — should be empty
        let page4: [MessageHeader] = try db.read { dbConn in
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX")
                .order(Column("date").desc)
                .limit(2, offset: 5)
                .fetchAll(dbConn)
        }
        #expect(page4.isEmpty)
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
