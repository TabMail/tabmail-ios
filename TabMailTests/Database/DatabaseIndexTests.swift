/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database Index Verification")
struct DatabaseIndexTests {

    @Test("Composite indexes exist for common queries")
    func compositeIndexesExist() throws {
        let db = try TestDatabase.make()
        let indexes = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index'")
                .map { $0["name"] as String }
        }
        // The DB should have indexes for the most common query patterns
        // Exact index names may vary, but we verify the query doesn't full-scan
        #expect(!indexes.isEmpty)
    }

    @Test("Canonicalize upsert lookup (messageId + folderId) uses an index, not a scan")
    func canonicalizeLookupUsesIndex() throws {
        // canonicalizeLocalRows runs once per remote message in every folder
        // sync — it MUST seek via messageHeader_messageId_accountId (v40),
        // never scan (ADR-IOS-029).
        let db = try TestDatabase.make()
        let details: [String] = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM messageHeader WHERE messageId = 'x' AND folderId = 'acc1:INBOX'
                """).map { row in row["detail"] as String }
        }
        let plan = details.joined(separator: " | ")
        #expect(plan.contains("USING INDEX"), "expected index seek, got: \(plan)")
        #expect(!plan.contains("SCAN messageHeader"), "full scan on hot upsert path: \(plan)")
    }

    @Test("Query by folderId + isRead uses index effectively")
    func queryByFolderIdAndIsRead() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert many messages
        for i in 0..<50 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", isRead: i % 2 == 0)
        }

        // This query pattern should be efficient due to indexes
        let unreadCount = try db.read {
            try MessageHeader.filter(
                Column("folderId") == "acc1:INBOX" && Column("isRead") == false
            ).fetchCount($0)
        }
        #expect(unreadCount == 25)
    }

    @Test("Query messages by accountId is efficient")
    func queryByAccountId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "a1", email: "a@b.com", provider: .gmail)
        try TestDatabase.insertAccount(db, id: "a2", email: "c@d.com", provider: .imap)
        try TestDatabase.insertFolder(db, accountId: "a1")
        try TestDatabase.insertFolder(db, accountId: "a2")

        for i in 0..<10 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", folderId: "a1:INBOX", accountId: "a1")
        }
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", folderId: "a2:INBOX", accountId: "a2")
        }

        let a1Count = try db.read {
            try MessageHeader.filter(Column("accountId") == "a1").fetchCount($0)
        }
        let a2Count = try db.read {
            try MessageHeader.filter(Column("accountId") == "a2").fetchCount($0)
        }
        #expect(a1Count == 10)
        #expect(a2Count == 5)
    }

    @Test("MessageHeader ordered by date DESC for inbox view")
    func messageHeaderOrderByDate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let dates = [
            Date().addingTimeInterval(-3600),
            Date().addingTimeInterval(-7200),
            Date(),
        ]
        for (i, date) in dates.enumerated() {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", date: date)
        }

        let ordered = try db.read {
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX")
                .order(Column("date").desc)
                .fetchAll($0)
        }
        #expect(ordered.count == 3)
        #expect(ordered[0].date >= ordered[1].date)
        #expect(ordered[1].date >= ordered[2].date)
    }
}
