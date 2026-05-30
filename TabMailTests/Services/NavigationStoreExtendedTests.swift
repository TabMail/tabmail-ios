/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for GRDB query patterns used by NavigationStore.
/// NavigationStore itself is @MainActor and depends on AppDatabase.dbPool,
/// so we test the underlying GRDB queries it relies on using TestDatabase.

@Suite("NavigationStore Query Patterns - Account Filtering")
struct NavigationStoreAccountQueryTests {

    @Test("Fetches only active non-calendar accounts")
    func fetchesActiveNonCalendarAccounts() throws {
        let db = try TestDatabase.make()

        // Active email account
        try TestDatabase.insertAccount(db, id: "a1", email: "active@test.com")

        // Inactive account
        var inactive = Account(emailAddress: "inactive@test.com", displayName: "Inactive", provider: .gmail)
        inactive.id = "a2"
        inactive.isActive = false
        try db.write { try inactive.insert($0) }

        // Calendar-only account
        var calOnly = Account(emailAddress: "cal@test.com", displayName: "Cal", provider: .caldav)
        calOnly.id = "a3"
        calOnly.calendarOnly = true
        try db.write { try calOnly.insert($0) }

        let accounts = try db.read { db in
            try Account.filter(Column("isActive") == true && Column("calendarOnly") == false)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
        #expect(accounts.count == 1)
        #expect(accounts[0].id == "a1")
    }

    @Test("Orders accounts by createdAt")
    func ordersAccountsByCreatedAt() throws {
        let db = try TestDatabase.make()

        var a1 = Account(emailAddress: "first@test.com", displayName: "First", provider: .gmail)
        a1.id = "a1"
        a1.createdAt = Date(timeIntervalSince1970: 1000)
        try db.write { try a1.insert($0) }

        var a2 = Account(emailAddress: "second@test.com", displayName: "Second", provider: .gmail)
        a2.id = "a2"
        a2.createdAt = Date(timeIntervalSince1970: 2000)
        try db.write { try a2.insert($0) }

        let accounts = try db.read { db in
            try Account.filter(Column("isActive") == true && Column("calendarOnly") == false)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
        #expect(accounts.count == 2)
        #expect(accounts[0].id == "a1")
        #expect(accounts[1].id == "a2")
    }

    @Test("Empty database returns empty accounts")
    func emptyDatabaseReturnsEmpty() throws {
        let db = try TestDatabase.make()
        let accounts = try db.read { db in
            try Account.filter(Column("isActive") == true && Column("calendarOnly") == false)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
        #expect(accounts.isEmpty)
    }
}

@Suite("NavigationStore Query Patterns - Folder Queries")
struct NavigationStoreFolderQueryTests {

    @Test("Fetches all folders ordered by name")
    func fetchesFoldersOrderedByName() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Zebra", path: "Zebra", role: .custom)
        try TestDatabase.insertFolder(db, name: "Alpha", path: "Alpha", role: .custom)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        let folders = try db.read { db in
            try Folder.order(Column("name")).fetchAll(db)
        }
        #expect(folders.count == 3)
        #expect(folders[0].name == "Alpha")
        #expect(folders[1].name == "INBOX")
        #expect(folders[2].name == "Zebra")
    }

    @Test("Folder unreadCount updates correctly")
    func folderUnreadCountUpdates() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        #expect(folder.unreadCount == 0)

        try db.write { db in
            try db.execute(sql: "UPDATE folder SET unreadCount = 5 WHERE id = ?", arguments: [folder.id])
        }

        let updated = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(updated?.unreadCount == 5)
    }

    @Test("Folder isFavorite toggle")
    func folderFavoriteToggle() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        #expect(folder.isFavorite == false)

        try db.write { db in
            try db.execute(sql: "UPDATE folder SET isFavorite = NOT isFavorite WHERE id = ?", arguments: [folder.id])
        }

        let toggled = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(toggled?.isFavorite == true)

        try db.write { db in
            try db.execute(sql: "UPDATE folder SET isFavorite = NOT isFavorite WHERE id = ?", arguments: [folder.id])
        }

        let toggledBack = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(toggledBack?.isFavorite == false)
    }

    @Test("Folder setFavorite to specific value")
    func folderSetFavorite() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        try db.write { db in
            try db.execute(sql: "UPDATE folder SET isFavorite = ? WHERE id = ?", arguments: [true, folder.id])
        }

        let updated = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(updated?.isFavorite == true)
    }

    @Test("Folders across multiple accounts")
    func foldersAcrossAccounts() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@test.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@test.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")

        let folders = try db.read { db in
            try Folder.order(Column("name")).fetchAll(db)
        }
        #expect(folders.count == 2)
        // Both named INBOX but different IDs (accountId:path)
        #expect(folders[0].id != folders[1].id)
    }
}

@Suite("NavigationStore Query Patterns - Message Queries by Folder")
struct NavigationStoreMessageQueryTests {

    @Test("Fetches messages by folderId ordered by date desc")
    func fetchesMessagesByFolder() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let oldDate = Date(timeIntervalSince1970: 1000)
        let newDate = Date(timeIntervalSince1970: 2000)

        try TestDatabase.insertMessageHeader(db, messageId: "old", subject: "Old", date: oldDate)
        try TestDatabase.insertMessageHeader(db, messageId: "new", subject: "New", date: newDate)

        let messages = try db.read { db in
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX")
                .order(Column("date").desc)
                .fetchAll(db)
        }
        #expect(messages.count == 2)
        #expect(messages[0].subject == "New")
        #expect(messages[1].subject == "Old")
    }

    @Test("Counts unread messages in folder")
    func countsUnreadMessages() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "2", isRead: true)
        try TestDatabase.insertMessageHeader(db, messageId: "3", isRead: false)

        let unreadCount = try db.read { db in
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX" && Column("isRead") == false)
                .fetchCount(db)
        }
        #expect(unreadCount == 2)
    }

    @Test("Messages filtered by accountId")
    func messagesByAccountId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@test.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@test.com")
        try TestDatabase.insertFolder(db, accountId: "acc1")
        try TestDatabase.insertFolder(db, accountId: "acc2")

        try TestDatabase.insertMessageHeader(db, messageId: "m1", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "m2", folderId: "acc2:INBOX", accountId: "acc2")

        let acc1Messages = try db.read { db in
            try MessageHeader.filter(Column("accountId") == "acc1").fetchAll(db)
        }
        #expect(acc1Messages.count == 1)
        #expect(acc1Messages[0].messageId == "m1")
    }

    @Test("Messages with actionTag filter")
    func messagesByActionTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "r1", actionTag: .reply)
        try TestDatabase.insertMessageHeader(db, messageId: "a1", actionTag: .archive)
        try TestDatabase.insertMessageHeader(db, messageId: "d1", actionTag: .delete)
        try TestDatabase.insertMessageHeader(db, messageId: "n1", actionTag: ActionTag.none)

        let replyMessages = try db.read { db in
            try MessageHeader.filter(Column("actionTag") == ActionTag.reply.rawValue).fetchAll(db)
        }
        #expect(replyMessages.count == 1)
        #expect(replyMessages[0].messageId == "r1")
    }

    @Test("Messages ordered by tagSortOrder then date")
    func messagesOrderedByTagThenDate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        try TestDatabase.insertMessageHeader(db, messageId: "a1", date: date2, actionTag: .archive)
        try TestDatabase.insertMessageHeader(db, messageId: "r1", date: date1, actionTag: .reply)

        let messages = try db.read { db in
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX")
                .order(Column("tagSortOrder").asc, Column("date").desc)
                .fetchAll(db)
        }
        #expect(messages.count == 2)
        // Reply has sortOrder 0, Archive has sortOrder 2
        #expect(messages[0].actionTag == .reply)
        #expect(messages[1].actionTag == .archive)
    }
}

@Suite("NavigationStore Query Patterns - Primary Account")
struct NavigationStorePrimaryAccountTests {

    @Test("Set primary account clears others")
    func setPrimaryAccountClearsOthers() throws {
        let db = try TestDatabase.make()

        var a1 = Account(emailAddress: "a@test.com", displayName: "A", provider: .gmail)
        a1.id = "a1"
        a1.isPrimary = true
        try db.write { try a1.insert($0) }

        var a2 = Account(emailAddress: "b@test.com", displayName: "B", provider: .gmail)
        a2.id = "a2"
        a2.isPrimary = false
        try db.write { try a2.insert($0) }

        // Set a2 as primary (mimics NavigationStore.setPrimaryAccount)
        try db.write { db in
            try db.execute(sql: "UPDATE account SET isPrimary = 0 WHERE isPrimary = 1")
            try db.execute(sql: "UPDATE account SET isPrimary = 1 WHERE id = ?", arguments: ["a2"])
        }

        let accounts = try db.read { try Account.fetchAll($0) }
        let a1Updated = accounts.first { $0.id == "a1" }
        let a2Updated = accounts.first { $0.id == "a2" }
        #expect(a1Updated?.isPrimary == false)
        #expect(a2Updated?.isPrimary == true)
    }

    @Test("Only one primary account at a time")
    func onlyOnePrimary() throws {
        let db = try TestDatabase.make()

        for i in 1...3 {
            var acct = Account(emailAddress: "a\(i)@test.com", displayName: "A\(i)", provider: .gmail)
            acct.id = "a\(i)"
            try db.write { try acct.insert($0) }
        }

        // Set a2 as primary
        try db.write { db in
            try db.execute(sql: "UPDATE account SET isPrimary = 0 WHERE isPrimary = 1")
            try db.execute(sql: "UPDATE account SET isPrimary = 1 WHERE id = ?", arguments: ["a2"])
        }

        let primaryCount = try db.read { db in
            try Account.filter(Column("isPrimary") == true).fetchCount(db)
        }
        #expect(primaryCount == 1)
    }
}

@Suite("NavigationStore Query Patterns - Cascade Delete")
struct NavigationStoreCascadeDeleteTests {

    @Test("Deleting account cascades to folders")
    func deleteAccountCascadesFolders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let foldersBefore = try db.read { try Folder.fetchCount($0) }
        #expect(foldersBefore == 1)

        try db.write { try Account.deleteAll($0) }

        let foldersAfter = try db.read { try Folder.fetchCount($0) }
        #expect(foldersAfter == 0)
    }

    @Test("Deleting account cascades to message headers")
    func deleteAccountCascadesHeaders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db)

        let headersBefore = try db.read { try MessageHeader.fetchCount($0) }
        #expect(headersBefore == 1)

        try db.write { try Account.deleteAll($0) }

        let headersAfter = try db.read { try MessageHeader.fetchCount($0) }
        #expect(headersAfter == 0)
    }
}

@Suite("NavigationStore Query Patterns - Outbox Queries")
struct NavigationStoreOutboxQueryTests {

    @Test("Outbox messages ordered by createdAt desc")
    func outboxOrderedByDate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft1 = DraftMessage(to: ["a@test.com"], subject: "First", body: "Body 1", isHTML: false, attachments: [])
        let draft2 = DraftMessage(to: ["b@test.com"], subject: "Second", body: "Body 2", isHTML: false, attachments: [])

        try db.write { db in
            var msg1 = OutboxMessage(accountId: "acc1", draft: draft1)
            msg1.createdAt = Date(timeIntervalSince1970: 1000)
            try msg1.insert(db)

            var msg2 = OutboxMessage(accountId: "acc1", draft: draft2)
            msg2.createdAt = Date(timeIntervalSince1970: 2000)
            try msg2.insert(db)
        }

        let outbox = try db.read { db in
            try OutboxMessage.order(Column("createdAt").desc).fetchAll(db)
        }
        #expect(outbox.count == 2)
        #expect(outbox[0].subject == "Second")
        #expect(outbox[1].subject == "First")
    }

    @Test("Empty outbox returns empty array")
    func emptyOutbox() throws {
        let db = try TestDatabase.make()
        let outbox = try db.read { db in
            try OutboxMessage.order(Column("createdAt").desc).fetchAll(db)
        }
        #expect(outbox.isEmpty)
    }
}

@Suite("NavigationStore Query Patterns - Folder ID Convention")
struct FolderIdConventionTests {

    @Test("Folder ID is accountId:path")
    func folderIdFormat() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "myacc")
        let folder = try TestDatabase.insertFolder(db, path: "INBOX", accountId: "myacc")
        #expect(folder.id == "myacc:INBOX")
    }

    @Test("Folder ID uniqueness across accounts")
    func folderIdUniqueness() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@test.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@test.com")

        let f1 = try TestDatabase.insertFolder(db, path: "INBOX", accountId: "acc1")
        let f2 = try TestDatabase.insertFolder(db, path: "INBOX", accountId: "acc2")

        #expect(f1.id == "acc1:INBOX")
        #expect(f2.id == "acc2:INBOX")
        #expect(f1.id != f2.id)
    }

    @Test("Message folderId matches folder id")
    func messageFolderIdMatchesFolderId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, folderId: folder.id)
        #expect(header.folderId == folder.id)
    }
}
