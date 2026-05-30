/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database CRUD")
struct DatabaseCRUDTests {

    // MARK: - Account

    @Test("Insert and fetch accounts")
    func insertFetchAccounts() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@b.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "c@d.com")
        let accounts = try db.read { try Account.fetchAll($0) }
        #expect(accounts.count == 2)
    }

    // MARK: - Folder CASCADE

    @Test("Deleting account cascades to folders")
    func cascadeAccountToFolder() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        // Delete account
        try db.write { db in
            _ = try Account.deleteAll(db, keys: ["acc1"])
        }
        let folders = try db.read { try Folder.fetchAll($0) }
        #expect(folders.isEmpty)
    }

    // MARK: - MessageHeader

    @Test("Insert MessageHeader with valid accountId succeeds")
    func insertMessageHeaderValid() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)
        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched != nil)
        #expect(fetched?.subject == "Test Subject")
    }

    @Test("MessageHeader GRDB round-trip preserves all fields")
    func messageHeaderRoundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let date = Date()
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "42",
            subject: "Important Email",
            from: "Alice <alice@example.com>",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            date: date,
            snippet: "This is a snippet",
            isRead: true,
            rfc822MessageId: "<unique@example.com>",
            actionTag: .archive
        )
        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.messageId == "42")
        #expect(fetched?.subject == "Important Email")
        #expect(fetched?.fromAddress == "alice@example.com")
        #expect(fetched?.isRead == true)
        #expect(fetched?.rfc822MessageId == "<unique@example.com>")
        #expect(fetched?.actionTag == .archive)
    }

    @Test("MessageHeader query by folderId + isRead")
    func messageHeaderQueryFilter() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "2", isRead: true)
        try TestDatabase.insertMessageHeader(db, messageId: "3", isRead: false)

        let unread = try db.read { db in
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX" && Column("isRead") == false)
                .fetchAll(db)
        }
        #expect(unread.count == 2)
    }

    // MARK: - MessageBody

    @Test("MessageBody INSERT OR IGNORE: first wins")
    func messageBodyInsertOrIgnore() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        let headerId = "acc1:INBOX:1"
        try TestDatabase.insertMessageBody(db, headerId: headerId, htmlContent: "<p>First</p>")
        // Second insert with INSERT OR IGNORE should not overwrite
        try db.write { db in
            let body2 = MessageBody(headerId: headerId, htmlContent: "<p>Second</p>")
            try body2.insert(db, onConflict: .ignore)
        }
        let fetched = try db.read { try MessageBody.fetchOne($0, key: headerId) }
        #expect(fetched?.htmlContent == "<p>First</p>")
    }

    // MARK: - MessageAICache

    @Test("MessageAICache keyed by composite key")
    func aiCacheCompositeKey() throws {
        let db = try TestDatabase.make()
        let key = "acc1:INBOX:<msg@example.com>"
        try db.write { db in
            var cache = MessageAICache(key: key, rfc822MessageId: "<msg@example.com>")
            cache.summaryBlurb = "Test summary"
            try cache.insert(db)
        }
        let fetched = try db.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(fetched?.summaryBlurb == "Test summary")
    }

    @Test("MessageAICache survives MessageHeader deletion")
    func aiCacheSurvivesHeaderDeletion() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1", rfc822MessageId: "<msg@example.com>")

        let key = "acc1:INBOX:<msg@example.com>"
        try db.write { db in
            var cache = MessageAICache(key: key, rfc822MessageId: "<msg@example.com>")
            cache.summaryBlurb = "Cached summary"
            try cache.insert(db)
        }
        // Delete the message header
        try db.write { db in
            _ = try MessageHeader.deleteAll(db, keys: ["acc1:INBOX:1"])
        }
        // AI cache should still exist (no FK cascade)
        let fetched = try db.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(fetched != nil)
        #expect(fetched?.summaryBlurb == "Cached summary")
    }

    // MARK: - CASCADE chain

    @Test("Full CASCADE: account → folder → messageHeader → messageBody")
    func fullCascade() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")

        // Delete account
        try db.write { _ = try Account.deleteAll($0, keys: ["acc1"]) }

        let folders = try db.read { try Folder.fetchAll($0) }
        let headers = try db.read { try MessageHeader.fetchAll($0) }
        let bodies = try db.read { try MessageBody.fetchAll($0) }
        #expect(folders.isEmpty)
        #expect(headers.isEmpty)
        #expect(bodies.isEmpty)
    }

    // MARK: - Folder

    @Test("Folder unreadCount update persists")
    func folderUnreadCountUpdate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)
        folder.unreadCount = 5
        try db.write { try folder.update($0) }
        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.unreadCount == 5)
    }

    // MARK: - OutboxMessage lifecycle

    @Test("OutboxMessage lifecycle: queued → sending → delete")
    func outboxLifecycle() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        // Transition to sending
        msg.status = OutboxStatus.sending.rawValue
        try db.write { try msg.update($0) }
        let sendingMsg = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(sendingMsg?.outboxStatus == .sending)

        // Mark sentAt
        msg.sentAt = Date()
        try db.write { try msg.update($0) }
        let sentMsg = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(sentMsg?.sentAt != nil)
    }
}
