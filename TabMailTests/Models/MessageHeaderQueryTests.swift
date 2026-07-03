/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("MessageHeader GRDB Queries")
struct MessageHeaderQueryTests {

    // MARK: - Basic CRUD

    @Test("Insert and fetch by primary key")
    func insertAndFetch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100", subject: "Hello World")

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched != nil)
        #expect(fetched?.subject == "Hello World")
        #expect(fetched?.messageId == "100")
    }

    @Test("Delete removes header")
    func deleteRemoves() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        try db.write { _ = try MessageHeader.deleteOne($0, key: header.id) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched == nil)
    }

    @Test("Update persists changes")
    func updatePersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "100")

        header.isRead = true
        header.isFlagged = true
        header.summaryBlurb = "Test summary"
        header.actionTag = .reply
        header.tagSortOrder = ActionTag.reply.sortOrder
        try db.write { try header.update($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.isRead == true)
        #expect(fetched?.isFlagged == true)
        #expect(fetched?.summaryBlurb == "Test summary")
        #expect(fetched?.actionTag == .reply)
        #expect(fetched?.tagSortOrder == 0)
    }

    // MARK: - ID format

    @Test("Header ID format is accountId:folderPath:messageId")
    func headerIdFormat() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "myacct")
        try TestDatabase.insertFolder(db, path: "INBOX", accountId: "myacct")
        let header = try TestDatabase.insertMessageHeader(db, messageId: "42", folderId: "myacct:INBOX", accountId: "myacct")

        #expect(header.id == "myacct:INBOX:42")
    }

    // MARK: - Query patterns

    @Test("Filter by folderId")
    func filterByFolderId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX")
        try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc1:INBOX", folderPath: "INBOX")
        try TestDatabase.insertMessageHeader(db, messageId: "3", folderId: "acc1:Sent", folderPath: "Sent")

        let inbox = try db.read {
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchAll($0)
        }
        #expect(inbox.count == 2)
    }

    @Test("Filter by accountId")
    func filterByAccountId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertAccount(db, id: "acc2")
        try TestDatabase.insertFolder(db, accountId: "acc1")
        try TestDatabase.insertFolder(db, accountId: "acc2")

        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc2:INBOX", accountId: "acc2")

        let acc1 = try db.read {
            try MessageHeader.filter(Column("accountId") == "acc1").fetchAll($0)
        }
        #expect(acc1.count == 1)
        #expect(acc1[0].accountId == "acc1")
    }

    @Test("Order by date descending (newest first)")
    func orderByDateDesc() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "1", date: Date(timeIntervalSince1970: 1000))
        try TestDatabase.insertMessageHeader(db, messageId: "2", date: Date(timeIntervalSince1970: 3000))
        try TestDatabase.insertMessageHeader(db, messageId: "3", date: Date(timeIntervalSince1970: 2000))

        let ordered = try db.read {
            try MessageHeader.order(Column("date").desc).fetchAll($0)
        }
        #expect(ordered.count == 3)
        #expect(ordered[0].messageId == "2")
        #expect(ordered[1].messageId == "3")
        #expect(ordered[2].messageId == "1")
    }

    @Test("Filter unread messages")
    func filterUnread() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "2", isRead: true)
        try TestDatabase.insertMessageHeader(db, messageId: "3", isRead: false)

        let unread = try db.read {
            try MessageHeader.filter(Column("isRead") == false).fetchAll($0)
        }
        #expect(unread.count == 2)
    }

    @Test("Count unread messages")
    func countUnread() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "2", isRead: true)
        try TestDatabase.insertMessageHeader(db, messageId: "3", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "4", isRead: false)

        let count = try db.read {
            try MessageHeader.filter(Column("isRead") == false).fetchCount($0)
        }
        #expect(count == 3)
    }

    @Test("Filter by actionTag")
    func filterByActionTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "1", actionTag: .reply)
        try TestDatabase.insertMessageHeader(db, messageId: "2", actionTag: .delete)
        try TestDatabase.insertMessageHeader(db, messageId: "3", actionTag: .archive)
        try TestDatabase.insertMessageHeader(db, messageId: "4")

        let replies = try db.read {
            try MessageHeader.filter(Column("actionTag") == ActionTag.reply.rawValue).fetchAll($0)
        }
        #expect(replies.count == 1)
        #expect(replies[0].actionTag == .reply)
    }

    @Test("Order by tagSortOrder for triage")
    func orderByTagSortOrder() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "1", actionTag: .delete)   // sortOrder 3
        try TestDatabase.insertMessageHeader(db, messageId: "2", actionTag: .reply)    // sortOrder 0
        try TestDatabase.insertMessageHeader(db, messageId: "3", actionTag: .archive)  // sortOrder 2

        let ordered = try db.read {
            try MessageHeader.order(Column("tagSortOrder").asc).fetchAll($0)
        }
        #expect(ordered[0].actionTag == .reply)
        #expect(ordered[1].actionTag == .archive)
        #expect(ordered[2].actionTag == .delete)
    }

    @Test("Filter flagged messages")
    func filterFlagged() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "1")
        var h2 = try TestDatabase.insertMessageHeader(db, messageId: "2")
        h2.isFlagged = true
        try db.write { try h2.update($0) }

        let flagged = try db.read {
            try MessageHeader.filter(Column("isFlagged") == true).fetchAll($0)
        }
        #expect(flagged.count == 1)
        #expect(flagged[0].messageId == "2")
    }

    @Test("Limit and offset for pagination")
    func limitAndOffset() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        for i in 1...10 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", date: Date(timeIntervalSince1970: Double(i * 1000)))
        }

        let page = try db.read {
            try MessageHeader.order(Column("date").desc).limit(3, offset: 2).fetchAll($0)
        }
        #expect(page.count == 3)
    }

    // MARK: - stableId computed property

    @Test("stableId returns rfc822MessageId for numeric UID")
    func stableIdNumericUid() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "12345", rfc822MessageId: "<test@example.com>")

        #expect(header.stableId == "<test@example.com>")
    }

    @Test("stableId returns messageId for non-numeric ID")
    func stableIdNonNumeric() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "gmail-abc123")

        #expect(header.stableId == "gmail-abc123")
    }

    @Test("stableId returns messageId when rfc822MessageId is nil")
    func stableIdNilRfc822() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "999")

        #expect(header.stableId == "999")
    }

    @Test("stableId returns messageId when rfc822MessageId is empty")
    func stableIdEmptyRfc822() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "999", rfc822MessageId: "")

        #expect(header.stableId == "999")
    }

    // MARK: - Cascade delete

    @Test("Deleting account cascades through to headers (v2 migration: FK on accountId, not folderId)")
    func accountDeleteCascadesToHeaders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageHeader(db, messageId: "2")

        // v2 migration removed FK on folderId. Cascade is via accountId→account.
        try db.write { _ = try Account.deleteOne($0, key: "acc1") }

        let headers = try db.read { try MessageHeader.fetchAll($0) }
        #expect(headers.isEmpty)
    }

    @Test("Deleting account cascades through folder to headers")
    func accountDeleteCascadesHeaders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")

        try db.write { _ = try Account.deleteOne($0, key: "acc1") }

        let headers = try db.read { try MessageHeader.fetchAll($0) }
        let bodies = try db.read { try MessageBody.fetchAll($0) }
        #expect(headers.isEmpty)
        #expect(bodies.isEmpty)
    }

    // MARK: - AI fields persistence

    @Test("Summary fields persist")
    func summaryFieldsPersist() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        header.summaryBlurb = "Meeting reminder for tomorrow"
        header.summaryTodos = "- Prepare slides\n- Review agenda"
        header.cachedReply = "Thanks for the reminder!"
        try db.write { try header.update($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.summaryBlurb == "Meeting reminder for tomorrow")
        #expect(fetched?.summaryTodos == "- Prepare slides\n- Review agenda")
        #expect(fetched?.cachedReply == "Thanks for the reminder!")
    }

    @Test("Reminder fields persist")
    func reminderFieldsPersist() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        header.reminderDate = "2024-03-20"
        header.reminderTime = "14:00"
        header.reminderContent = "Follow up on proposal"
        try db.write { try header.update($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.reminderDate == "2024-03-20")
        #expect(fetched?.reminderTime == "14:00")
        #expect(fetched?.reminderContent == "Follow up on proposal")
    }

    // MARK: - Complex queries

    @Test("Inbox unread count per account")
    func inboxUnreadCountPerAccount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertAccount(db, id: "acc2")
        try TestDatabase.insertFolder(db, accountId: "acc1")
        try TestDatabase.insertFolder(db, accountId: "acc2")

        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", accountId: "acc1", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc1:INBOX", accountId: "acc1", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "3", folderId: "acc1:INBOX", accountId: "acc1", isRead: true)
        try TestDatabase.insertMessageHeader(db, messageId: "4", folderId: "acc2:INBOX", accountId: "acc2", isRead: false)

        let acc1Unread = try db.read {
            try MessageHeader
                .filter(Column("accountId") == "acc1" && Column("isRead") == false)
                .fetchCount($0)
        }
        let acc2Unread = try db.read {
            try MessageHeader
                .filter(Column("accountId") == "acc2" && Column("isRead") == false)
                .fetchCount($0)
        }
        #expect(acc1Unread == 2)
        #expect(acc2Unread == 1)
    }

    @Test("Batch update read status")
    func batchUpdateReadStatus() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "2", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "3", isRead: false)

        // Mark all as read
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE accountId = ?", arguments: ["acc1"])
        }

        let unread = try db.read {
            try MessageHeader.filter(Column("isRead") == false).fetchCount($0)
        }
        #expect(unread == 0)
    }

    @Test("threadId grouping query")
    func threadIdGrouping() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        var h1 = try TestDatabase.insertMessageHeader(db, messageId: "1", subject: "Thread A")
        h1.threadId = "thread-abc"
        try db.write { try h1.update($0) }

        var h2 = try TestDatabase.insertMessageHeader(db, messageId: "2", subject: "Re: Thread A")
        h2.threadId = "thread-abc"
        try db.write { try h2.update($0) }

        var h3 = try TestDatabase.insertMessageHeader(db, messageId: "3", subject: "Different")
        h3.threadId = "thread-xyz"
        try db.write { try h3.update($0) }

        let threadAbc = try db.read {
            try MessageHeader.filter(Column("threadId") == "thread-abc").fetchAll($0)
        }
        #expect(threadAbc.count == 2)
    }
}

