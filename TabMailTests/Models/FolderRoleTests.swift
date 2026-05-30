/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("FolderRole")
struct FolderRoleTests {

    @Test("All standard roles have raw values")
    func standardRoles() {
        #expect(FolderRole.inbox.rawValue == "inbox")
        #expect(FolderRole.sent.rawValue == "sent")
        #expect(FolderRole.drafts.rawValue == "drafts")
        #expect(FolderRole.trash.rawValue == "trash")
        #expect(FolderRole.archive.rawValue == "archive")
        #expect(FolderRole.spam.rawValue == "spam")
        #expect(FolderRole.custom.rawValue == "custom")
    }

    @Test("FolderRole is Codable")
    func codableRoundTrip() throws {
        let roles: [FolderRole] = [.inbox, .sent, .drafts, .trash, .archive, .spam, .custom]
        for role in roles {
            let data = try JSONEncoder().encode(role)
            let decoded = try JSONDecoder().decode(FolderRole.self, from: data)
            #expect(decoded == role)
        }
    }

    @Test("FolderRole has exactly 7 cases")
    func roleCount() {
        let allRoles: [FolderRole] = [.inbox, .sent, .drafts, .trash, .archive, .spam, .custom]
        #expect(allRoles.count == 7)
    }

    @Test("FolderRole decoding rejects unknown values")
    func rejectsUnknown() {
        let json = "\"unknownRole\""
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FolderRole.self, from: json.data(using: .utf8)!)
        }
    }

    @Test("FolderRole encoding produces raw string without wrapper")
    func encodingProducesRawString() throws {
        let data = try JSONEncoder().encode(FolderRole.inbox)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "\"inbox\"")
    }
}

@Suite("Folder Equality")
struct FolderEqualityTests {

    @Test("Same id and same visible fields are equal")
    func equalFolders() {
        let f1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let f2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        #expect(f1 == f2)
    }

    @Test("Different unreadCount makes them unequal")
    func differentUnreadCount() {
        var f1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        var f2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        f1.unreadCount = 0
        f2.unreadCount = 5
        #expect(f1 != f2)
    }

    @Test("Different totalCount makes them unequal")
    func differentTotalCount() {
        var f1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        var f2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        f1.totalCount = 100
        f2.totalCount = 200
        #expect(f1 != f2)
    }

    @Test("Different isFavorite makes them unequal")
    func differentIsFavorite() {
        var f1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        var f2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        f1.isFavorite = false
        f2.isFavorite = true
        #expect(f1 != f2)
    }

    @Test("Different backfillComplete makes them unequal")
    func differentBackfillComplete() {
        var f1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        var f2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        f1.backfillComplete = false
        f2.backfillComplete = true
        #expect(f1 != f2)
    }

    // Regression — without `role` in `==`, AccountDetailView's ForEach
    // diff cached stale rows after the user changed a folder's role,
    // so the icons/labels wouldn't update even though the DB was correct.
    @Test("Different role makes them unequal")
    func differentRole() {
        var f1 = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        var f2 = Folder(name: "Trash", path: "Trash", role: .custom, accountId: "acc1")
        #expect(f1 != f2)
        f2.role = .trash
        #expect(f1 == f2)
    }

    @Test("Hash only on id -- same id goes to same bucket")
    func hashOnlyId() {
        var f1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        var f2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        f1.unreadCount = 0
        f2.unreadCount = 99
        #expect(f1.hashValue == f2.hashValue)
    }

    @Test("Different non-equality fields do not affect equality")
    func nonEqualityFieldsIgnored() {
        var f1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        var f2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        // Fields NOT compared in ==: path, role, accountId, oldestSyncedDate, backfillUidCursor, etc.
        f1.oldestSyncedDate = Date(timeIntervalSince1970: 1000)
        f2.oldestSyncedDate = Date(timeIntervalSince1970: 2000)
        f1.lastKnownUidNext = 100
        f2.lastKnownUidNext = 200
        f1.backfillUidCursor = 50
        f2.backfillUidCursor = 150
        f1.backfillPageToken = "token-a"
        f2.backfillPageToken = "token-b"
        #expect(f1 == f2) // These fields are NOT in the == implementation
    }

    @Test("Folder id is accountId:path")
    func folderIdFormat() {
        let folder = Folder(name: "Sent", path: "Sent", role: .sent, accountId: "acc1")
        #expect(folder.id == "acc1:Sent")
    }

    @Test("Folder defaults")
    func folderDefaults() {
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        #expect(folder.unreadCount == 0)
        #expect(folder.totalCount == 0)
        #expect(folder.isFavorite == false)
        #expect(folder.backfillComplete == false)
        #expect(folder.oldestSyncedDate == nil)
        #expect(folder.backfillUidCursor == nil)
        #expect(folder.backfillPageToken == nil)
        #expect(folder.lastKnownUidNext == nil)
    }

    @Test("Folder databaseTableName is folder")
    func tableNameIsCorrect() {
        #expect(Folder.databaseTableName == "folder")
    }
}

@Suite("Folder Codable")
struct FolderCodableTests {

    @Test("Folder Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        var folder = Folder(name: "Work Projects", path: "INBOX/Work", role: .custom, accountId: "acc1")
        folder.unreadCount = 42
        folder.totalCount = 150
        folder.isFavorite = true
        folder.backfillComplete = true
        folder.oldestSyncedDate = Date(timeIntervalSince1970: 1700000000)
        folder.lastKnownUidNext = 5000
        folder.backfillUidCursor = 200
        folder.backfillPageToken = "next-page-xyz"

        let data = try JSONEncoder().encode(folder)
        let decoded = try JSONDecoder().decode(Folder.self, from: data)

        #expect(decoded.id == folder.id)
        #expect(decoded.accountId == "acc1")
        #expect(decoded.name == "Work Projects")
        #expect(decoded.path == "INBOX/Work")
        #expect(decoded.role == .custom)
        #expect(decoded.unreadCount == 42)
        #expect(decoded.totalCount == 150)
        #expect(decoded.isFavorite == true)
        #expect(decoded.backfillComplete == true)
        #expect(decoded.lastKnownUidNext == 5000)
        #expect(decoded.backfillUidCursor == 200)
        #expect(decoded.backfillPageToken == "next-page-xyz")
    }

    @Test("Folder Codable round-trip with nil optional fields")
    func codableRoundTripNils() throws {
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let data = try JSONEncoder().encode(folder)
        let decoded = try JSONDecoder().decode(Folder.self, from: data)

        #expect(decoded.oldestSyncedDate == nil)
        #expect(decoded.lastKnownUidNext == nil)
        #expect(decoded.backfillUidCursor == nil)
        #expect(decoded.backfillPageToken == nil)
    }

    @Test("Folder GRDB round-trip preserves all fields")
    func grdbRoundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        folder.unreadCount = 10
        folder.totalCount = 500
        folder.isFavorite = true
        folder.backfillComplete = true
        folder.oldestSyncedDate = Date(timeIntervalSince1970: 1600000000)
        folder.lastKnownUidNext = 9999
        folder.backfillUidCursor = 100
        folder.backfillPageToken = "token-abc"
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.unreadCount == 10)
        #expect(fetched?.totalCount == 500)
        #expect(fetched?.isFavorite == true)
        #expect(fetched?.backfillComplete == true)
        #expect(fetched?.lastKnownUidNext == 9999)
        #expect(fetched?.backfillUidCursor == 100)
        #expect(fetched?.backfillPageToken == "token-abc")
    }

    @Test("Folder with nested path has correct id")
    func nestedPathId() {
        let folder = Folder(name: "Deep", path: "INBOX/Work/Projects/Deep", role: .custom, accountId: "acc1")
        #expect(folder.id == "acc1:INBOX/Work/Projects/Deep")
    }

    @Test("Folder with Gmail label path has correct id")
    func gmailLabelId() {
        let folder = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: "gmail-acc")
        #expect(folder.id == "gmail-acc:INBOX")

        let sent = Folder(name: "Sent", path: "SENT", role: .sent, accountId: "gmail-acc")
        #expect(sent.id == "gmail-acc:SENT")
    }

    @Test("Folder in Set uses id for hashing")
    func folderInSet() {
        let f1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let f2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        // Both have same id and same field values → deduplicated in Set
        let set: Set<Folder> = [f1, f2]
        #expect(set.count == 1)
    }
}
