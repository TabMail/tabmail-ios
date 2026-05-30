/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database MessageHeader Queries")
struct DatabaseMessageHeaderQueryTests {

    @Test("Query by actionTag")
    func queryByActionTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "1", actionTag: .archive)
        try TestDatabase.insertMessageHeader(db, messageId: "2", actionTag: .delete)
        try TestDatabase.insertMessageHeader(db, messageId: "3", actionTag: .archive)
        try TestDatabase.insertMessageHeader(db, messageId: "4", actionTag: nil)

        let archiveMessages = try db.read {
            try MessageHeader.filter(Column("actionTag") == ActionTag.archive.rawValue).fetchAll($0)
        }
        #expect(archiveMessages.count == 2)
    }

    @Test("Query unread count per folder")
    func unreadCountPerFolder() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc1:INBOX", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "3", folderId: "acc1:INBOX", isRead: true)
        try TestDatabase.insertMessageHeader(db, messageId: "4", folderId: "acc1:Sent", folderPath: "Sent", isRead: false)

        let inboxUnread = try db.read {
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX" && Column("isRead") == false)
                .fetchCount($0)
        }
        #expect(inboxUnread == 2)
    }

    @Test("Query by accountId")
    func queryByAccountId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@b.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "c@d.com")
        try TestDatabase.insertFolder(db, accountId: "acc1")
        try TestDatabase.insertFolder(db, accountId: "acc2")

        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc2:INBOX", accountId: "acc2")
        try TestDatabase.insertMessageHeader(db, messageId: "3", folderId: "acc1:INBOX", accountId: "acc1")

        let acc1Messages = try db.read {
            try MessageHeader.filter(Column("accountId") == "acc1").fetchAll($0)
        }
        #expect(acc1Messages.count == 2)
    }

    @Test("Sort by date descending")
    func sortByDateDescending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let dates = [
            Date(timeIntervalSince1970: 1000),
            Date(timeIntervalSince1970: 3000),
            Date(timeIntervalSince1970: 2000),
        ]
        for (i, date) in dates.enumerated() {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", date: date)
        }

        let sorted = try db.read {
            try MessageHeader.order(Column("date").desc).fetchAll($0)
        }
        #expect(sorted[0].date > sorted[1].date)
        #expect(sorted[1].date > sorted[2].date)
    }

    @Test("Query with isInInbox filter")
    func queryIsInInbox() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", isInInbox: true)
        try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false)

        let inboxMessages = try db.read {
            try MessageHeader.filter(Column("isInInbox") == true).fetchAll($0)
        }
        #expect(inboxMessages.count == 1)
    }

    @Test("Update messageHeader fields")
    func updateFields() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)

        header.isRead = true
        header.isFlagged = true
        header.summaryBlurb = "AI generated summary"
        header.actionTag = .reply
        try db.write { try header.update($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.isRead == true)
        #expect(fetched?.isFlagged == true)
        #expect(fetched?.summaryBlurb == "AI generated summary")
        #expect(fetched?.actionTag == .reply)
    }

    @Test("Delete message by key")
    func deleteByKey() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        try db.write { _ = try MessageHeader.deleteOne($0, key: header.id) }

        let count = try db.read { try MessageHeader.fetchCount($0) }
        #expect(count == 0)
    }

    @Test("Batch delete messages")
    func batchDelete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        var ids: [String] = []
        for i in 0..<5 {
            let header = try TestDatabase.insertMessageHeader(db, messageId: "\(i)")
            ids.append(header.id)
        }

        try db.write { db in
            _ = try MessageHeader.deleteAll(db, keys: Array(ids.prefix(3)))
        }

        let remaining = try db.read { try MessageHeader.fetchCount($0) }
        #expect(remaining == 2)
    }
}
