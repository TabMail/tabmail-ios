/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("UnreadCountManager Database Logic")
struct UnreadCountManagerDatabaseTests {

    @Test("Unread count recount from DB")
    func recountFromDB() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // 5 messages: 2 read, 3 unread
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", isRead: i < 2)
        }

        // Manual recount query (same logic as UnreadCountManager.performRecount)
        let count = try db.read { db in
            try MessageHeader.filter(
                Column("folderId") == "acc1:INBOX" && Column("isRead") == false
            ).fetchCount(db)
        }
        #expect(count == 3)
    }

    @Test("Recount updates folder unreadCount")
    func recountUpdatesFolder() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        for i in 0..<4 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", isRead: i < 1)
        }

        // Simulate recount logic
        let unreadCount = try db.read {
            try MessageHeader.filter(
                Column("folderId") == "acc1:INBOX" && Column("isRead") == false
            ).fetchCount($0)
        }
        folder.unreadCount = unreadCount
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.unreadCount == 3)
    }

    @Test("Recount with all read messages gives zero")
    func allReadZero() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        for i in 0..<3 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", isRead: true)
        }

        let count = try db.read {
            try MessageHeader.filter(
                Column("folderId") == "acc1:INBOX" && Column("isRead") == false
            ).fetchCount($0)
        }
        #expect(count == 0)
    }

    @Test("Recount with empty folder gives zero")
    func emptyFolderZero() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let count = try db.read {
            try MessageHeader.filter(
                Column("folderId") == "acc1:INBOX" && Column("isRead") == false
            ).fetchCount($0)
        }
        #expect(count == 0)
    }

    @Test("Recount after flag-only change (read→unread toggle on existing message)")
    func recountAfterFlagChange() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert 3 messages, all read
        for i in 0..<3 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", isRead: true)
        }

        // Verify initially 0 unread
        var count = try db.read {
            try MessageHeader.filter(
                Column("folderId") == "acc1:INBOX" && Column("isRead") == false
            ).fetchCount($0)
        }
        #expect(count == 0)

        // Simulate a delta sync flag-only change: mark message "1" as unread
        try db.write {
            try $0.execute(sql: "UPDATE messageHeader SET isRead = 0 WHERE messageId = '1'")
        }

        // Simulate performRecount grouped query (same SQL as UnreadCountManager)
        let folderIds = ["acc1:INBOX"]
        let recountResult = try db.read { dbConn -> [String: Int] in
            let placeholders = folderIds.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT folderId, COUNT(*) as cnt
                FROM messageHeader
                WHERE folderId IN (\(placeholders)) AND isRead = 0
                GROUP BY folderId
                """
            let rows = try Row.fetchAll(dbConn, sql: sql, arguments: StatementArguments(folderIds))
            var counts: [String: Int] = [:]
            for row in rows {
                let fid: String = row["folderId"]
                let cnt: Int = row["cnt"]
                counts[fid] = cnt
            }
            return counts
        }
        #expect(recountResult["acc1:INBOX"] == 1)

        // Apply recount to folder table
        try db.write { dbConn in
            for folderId in folderIds {
                let c = recountResult[folderId] ?? 0
                try dbConn.execute(
                    sql: "UPDATE folder SET unreadCount = ? WHERE id = ?",
                    arguments: [c, folderId]
                )
            }
        }

        let folder = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(folder?.unreadCount == 1)
    }

    @Test("Recount after deletion-only change (message removed, no new headers)")
    func recountAfterDeletionOnly() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert 3 unread messages
        for i in 0..<3 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", isRead: false)
        }

        // Verify 3 unread
        var count = try db.read {
            try MessageHeader.filter(
                Column("folderId") == "acc1:INBOX" && Column("isRead") == false
            ).fetchCount($0)
        }
        #expect(count == 3)

        // Simulate delta sync deletion: remove message "0"
        try db.write {
            try MessageHeader.filter(Column("messageId") == "0").deleteAll($0)
        }

        // Recount after deletion — no new headers, just removals
        count = try db.read {
            try MessageHeader.filter(
                Column("folderId") == "acc1:INBOX" && Column("isRead") == false
            ).fetchCount($0)
        }
        #expect(count == 2)

        // Apply to folder
        try db.write {
            try $0.execute(
                sql: "UPDATE folder SET unreadCount = ? WHERE id = ?",
                arguments: [count, "acc1:INBOX"]
            )
        }
        let folder = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(folder?.unreadCount == 2)
    }

    @Test("Badge total across multiple inbox folders")
    func badgeTotalMultipleInboxes() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "gmail", email: "user@gmail.com", provider: .gmail)
        try TestDatabase.insertAccount(db, id: "imap", email: "user@imap.com", provider: .imap)
        try TestDatabase.insertFolder(db, accountId: "gmail")
        try TestDatabase.insertFolder(db, accountId: "imap")

        // Set unread counts
        try db.write {
            try $0.execute(sql: "UPDATE folder SET unreadCount = 5 WHERE id = 'gmail:INBOX'")
            try $0.execute(sql: "UPDATE folder SET unreadCount = 3 WHERE id = 'imap:INBOX'")
        }

        // Query total badge count (same as UnreadCountManager.updateBadge logic)
        let totalUnread = try db.read { db -> Int in
            let activeAccountIds = try String.fetchAll(db,
                Account.select(Column("id")).filter(Column("isActive") == true)
            )
            guard !activeAccountIds.isEmpty else { return 0 }
            return try Int.fetchOne(db,
                sql: """
                    SELECT COALESCE(SUM(unreadCount), 0)
                    FROM folder
                    WHERE accountId IN (\(activeAccountIds.map { _ in "?" }.joined(separator: ", ")))
                      AND role = ?
                    """,
                arguments: StatementArguments(activeAccountIds + [FolderRole.inbox.rawValue])
            ) ?? 0
        }
        #expect(totalUnread == 8)
    }
}
