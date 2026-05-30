/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Comprehensive GRDB persistence tests for Account and Folder models.
@Suite("Account & Folder Persistence")
struct AccountFolderPersistenceTests {

    // MARK: - Account CRUD

    @Test("Account insert and fetch by primary key")
    func accountInsertAndFetch() throws {
        let db = try TestDatabase.make()
        let account = try TestDatabase.insertAccount(db, id: "acc1", email: "user@test.com", provider: .gmail)

        let fetched = try db.read { try Account.fetchOne($0, key: "acc1") }
        #expect(fetched != nil)
        #expect(fetched?.emailAddress == "user@test.com")
        #expect(fetched?.provider == .gmail)
        #expect(fetched?.isActive == true)
    }

    @Test("Account fetchAll returns all accounts")
    func accountFetchAll() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@b.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "c@d.com")
        try TestDatabase.insertAccount(db, id: "acc3", email: "e@f.com")

        let all = try db.read { try Account.fetchAll($0) }
        #expect(all.count == 3)
    }

    @Test("Account update persists changes")
    func accountUpdate() throws {
        let db = try TestDatabase.make()
        var account = try TestDatabase.insertAccount(db, id: "acc1", email: "old@test.com")

        account.emailAddress = "new@test.com"
        account.displayName = "New Name"
        account.isActive = false
        account.signature = "Sent from TabMail"
        try db.write { try account.update($0) }

        let fetched = try db.read { try Account.fetchOne($0, key: "acc1") }
        #expect(fetched?.emailAddress == "new@test.com")
        #expect(fetched?.displayName == "New Name")
        #expect(fetched?.isActive == false)
        #expect(fetched?.signature == "Sent from TabMail")
    }

    @Test("Account delete removes from DB")
    func accountDelete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        try db.write { _ = try Account.deleteOne($0, key: "acc1") }

        let fetched = try db.read { try Account.fetchOne($0, key: "acc1") }
        #expect(fetched == nil)
    }

    @Test("Account IMAP fields persist correctly")
    func accountImapFields() throws {
        let db = try TestDatabase.make()
        var account = try TestDatabase.insertAccount(db, id: "acc1", email: "user@imap.com", provider: .imap)
        account.imapHost = "imap.example.com"
        account.imapPort = 993
        account.smtpHost = "smtp.example.com"
        account.smtpPort = 587
        account.imapUsername = "imapuser"
        try db.write { try account.update($0) }

        let fetched = try db.read { try Account.fetchOne($0, key: "acc1") }
        #expect(fetched?.imapHost == "imap.example.com")
        #expect(fetched?.imapPort == 993)
        #expect(fetched?.smtpHost == "smtp.example.com")
        #expect(fetched?.smtpPort == 587)
        #expect(fetched?.imapUsername == "imapuser")
    }

    @Test("Account provider types all persist")
    func accountAllProviderTypes() throws {
        let db = try TestDatabase.make()
        let providers: [AccountProvider] = [.gmail, .outlook, .imap, .icloud, .caldav]

        for (i, provider) in providers.enumerated() {
            try TestDatabase.insertAccount(db, id: "acc\(i)", email: "\(provider.rawValue)@test.com", provider: provider)
        }

        let all = try db.read { try Account.fetchAll($0) }
        #expect(all.count == 5)
        let providerSet = Set(all.map(\.provider))
        #expect(providerSet.count == 5)
    }

    @Test("Account lastSyncedAt and lastFullSyncAt persist")
    func accountSyncDates() throws {
        let db = try TestDatabase.make()
        var account = try TestDatabase.insertAccount(db, id: "acc1")

        let now = Date()
        account.lastSyncedAt = now
        account.lastFullSyncAt = now
        try db.write { try account.update($0) }

        let fetched = try db.read { try Account.fetchOne($0, key: "acc1") }
        #expect(fetched?.lastSyncedAt != nil)
        #expect(fetched?.lastFullSyncAt != nil)
    }

    @Test("Account calendarOnly flag persists")
    func accountCalendarOnly() throws {
        let db = try TestDatabase.make()
        var account = try TestDatabase.insertAccount(db, id: "acc1")
        account.calendarOnly = true
        try db.write { try account.update($0) }

        let fetched = try db.read { try Account.fetchOne($0, key: "acc1") }
        #expect(fetched?.calendarOnly == true)
    }

    @Test("Account duplicate id insert throws")
    func accountDuplicateIdThrows() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        #expect(throws: (any Error).self) {
            try TestDatabase.insertAccount(db, id: "acc1", email: "other@test.com")
        }
    }

    // MARK: - Folder CRUD

    @Test("Folder insert and fetch by primary key")
    func folderInsertAndFetch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched != nil)
        #expect(fetched?.name == "INBOX")
        #expect(fetched?.path == "INBOX")
        #expect(fetched?.role == .inbox)
        #expect(fetched?.accountId == "acc1")
    }

    @Test("Folder id format is accountId:path")
    func folderIdFormat() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        let folder = try TestDatabase.insertFolder(db, name: "Inbox", path: "INBOX", accountId: "acc1")

        #expect(folder.id == "acc1:INBOX")
    }

    @Test("Folder update persists changes")
    func folderUpdate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        var folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        folder.unreadCount = 42
        folder.totalCount = 100
        folder.isFavorite = true
        folder.backfillComplete = true
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.unreadCount == 42)
        #expect(fetched?.totalCount == 100)
        #expect(fetched?.isFavorite == true)
        #expect(fetched?.backfillComplete == true)
    }

    @Test("Folder delete removes from DB")
    func folderDelete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", accountId: "acc1")

        try db.write { _ = try Folder.deleteOne($0, key: folder.id) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched == nil)
    }

    @Test("Multiple folders for same account")
    func multipleFoldersSameAccount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Work", path: "INBOX/Work", role: .custom, accountId: "acc1")

        let folders = try db.read {
            try Folder.filter(Column("accountId") == "acc1").fetchAll($0)
        }
        #expect(folders.count == 4)
    }

    // MARK: - FK cascade: Account deletion cascades to Folder

    @Test("Deleting account cascades to delete all its folders")
    func accountDeleteCascadesFolders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash, accountId: "acc1")

        try db.write { _ = try Account.deleteOne($0, key: "acc1") }

        let folders = try db.read { try Folder.fetchAll($0) }
        #expect(folders.isEmpty)
    }

    @Test("Deleting one account does not affect another account's folders")
    func accountDeleteDoesNotAffectOtherAccounts() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertAccount(db, id: "acc2")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")

        try db.write { _ = try Account.deleteOne($0, key: "acc1") }

        let folders = try db.read { try Folder.fetchAll($0) }
        #expect(folders.count == 1)
        #expect(folders[0].accountId == "acc2")
    }

    @Test("Full cascade: account → folder → messageHeader → messageBody")
    func fullCascadeChain() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100", accountId: "acc1")
        try TestDatabase.insertMessageBody(db, headerId: header.id)

        try db.write { _ = try Account.deleteOne($0, key: "acc1") }

        let folders = try db.read { try Folder.fetchAll($0) }
        let headers = try db.read { try MessageHeader.fetchAll($0) }
        let bodies = try db.read { try MessageBody.fetchAll($0) }
        #expect(folders.isEmpty)
        #expect(headers.isEmpty)
        #expect(bodies.isEmpty)
    }

    // MARK: - Folder role filtering

    @Test("Filter folders by inbox role")
    func filterByInboxRole() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Custom", path: "Custom", role: .custom, accountId: "acc1")

        let inboxFolders = try db.read {
            try Folder.filter(Column("role") == FolderRole.inbox.rawValue).fetchAll($0)
        }
        #expect(inboxFolders.count == 1)
        #expect(inboxFolders[0].name == "INBOX")
    }

    @Test("Filter folders by all standard roles")
    func filterByAllRoles() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        let roles: [(String, FolderRole)] = [
            ("INBOX", .inbox), ("Sent", .sent), ("Drafts", .drafts),
            ("Trash", .trash), ("Archive", .archive), ("Spam", .spam), ("Work", .custom)
        ]
        for (name, role) in roles {
            try TestDatabase.insertFolder(db, name: name, path: name, role: role, accountId: "acc1")
        }

        for (name, role) in roles {
            let result = try db.read {
                try Folder.filter(Column("role") == role.rawValue).fetchAll($0)
            }
            #expect(result.count == 1, "Expected 1 folder with role \(role.rawValue)")
            #expect(result[0].name == name)
        }
    }

    @Test("Filter custom folders excludes system roles")
    func filterCustomFolders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Work", path: "Work", role: .custom, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Personal", path: "Personal", role: .custom, accountId: "acc1")

        let customFolders = try db.read {
            try Folder.filter(Column("role") == FolderRole.custom.rawValue).fetchAll($0)
        }
        #expect(customFolders.count == 2)
    }

    // MARK: - Folder backfill fields

    @Test("Folder backfill cursor fields persist")
    func folderBackfillCursors() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        var folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let syncDate = Date(timeIntervalSince1970: 1700000000)
        folder.oldestSyncedDate = syncDate
        folder.lastKnownUidNext = 12345
        folder.backfillUidCursor = 500
        folder.backfillPageToken = "next_page_token_abc"
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.oldestSyncedDate != nil)
        #expect(fetched?.lastKnownUidNext == 12345)
        #expect(fetched?.backfillUidCursor == 500)
        #expect(fetched?.backfillPageToken == "next_page_token_abc")
    }

    // MARK: - Cross-account folder queries

    @Test("Folders across multiple accounts can be queried together")
    func crossAccountFolderQuery() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@test.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@test.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")

        let allInboxes = try db.read {
            try Folder.filter(Column("role") == FolderRole.inbox.rawValue).fetchAll($0)
        }
        #expect(allInboxes.count == 2)
        #expect(Set(allInboxes.map(\.accountId)) == ["acc1", "acc2"])
    }

    @Test("Folder Equatable compares relevant UI fields")
    func folderEquatableCompares() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        var f1 = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        var f2 = f1

        // Same values → equal
        #expect(f1 == f2)

        // Different unreadCount → not equal
        f2.unreadCount = 10
        #expect(f1 != f2)

        // Different name → not equal
        f2 = f1
        f2.name = "Modified"
        #expect(f1 != f2)
    }
}
