/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database Folder CRUD")
struct DatabaseFolderTests {

    @Test("Insert and fetch folders")
    func insertAndFetch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        let folders = try db.read { try Folder.fetchAll($0) }
        #expect(folders.count == 2)
    }

    @Test("Folder backfill fields persist")
    func backfillFieldsPersist() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        folder.backfillComplete = true
        folder.oldestSyncedDate = Date(timeIntervalSince1970: 1000)
        folder.backfillUidCursor = 500
        folder.backfillPageToken = "token123"
        folder.lastKnownUidNext = 1000
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillComplete == true)
        #expect(fetched?.oldestSyncedDate != nil)
        #expect(fetched?.backfillUidCursor == 500)
        #expect(fetched?.backfillPageToken == "token123")
        #expect(fetched?.lastKnownUidNext == 1000)
    }

    @Test("Folder isFavorite persists")
    func isFavoritePersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        folder.isFavorite = true
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.isFavorite == true)
    }

    @Test("Multiple folders for same account")
    func multipleFolders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let roles: [(String, String, FolderRole)] = [
            ("INBOX", "INBOX", .inbox),
            ("Sent", "Sent", .sent),
            ("Drafts", "Drafts", .drafts),
            ("Trash", "Trash", .trash),
            ("Archive", "Archive", .archive),
        ]
        for (name, path, role) in roles {
            try TestDatabase.insertFolder(db, name: name, path: path, role: role)
        }

        let folders = try db.read { try Folder.fetchAll($0) }
        #expect(folders.count == 5)
    }

    @Test("Folder filter by accountId")
    func filterByAccount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@b.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "c@d.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")

        let acc1Folders = try db.read {
            try Folder.filter(Column("accountId") == "acc1").fetchAll($0)
        }
        #expect(acc1Folders.count == 1)
        #expect(acc1Folders[0].accountId == "acc1")
    }

    @Test("Folder filter by role")
    func filterByRole() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        try TestDatabase.insertFolder(db, name: "Custom", path: "Custom", role: .custom)

        let inboxFolders = try db.read {
            try Folder.filter(Column("role") == FolderRole.inbox.rawValue).fetchAll($0)
        }
        #expect(inboxFolders.count == 1)
    }
}
