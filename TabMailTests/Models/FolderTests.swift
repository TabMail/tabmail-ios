/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("Folder")
struct FolderTests {

    @Test("ID format is accountId:path")
    func idFormat() {
        let folder = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: "a1")
        #expect(folder.id == "a1:INBOX")
    }

    @Test("ID with nested path")
    func idNestedPath() {
        let folder = Folder(name: "Work", path: "INBOX/Work", role: .custom, accountId: "a1")
        #expect(folder.id == "a1:INBOX/Work")
    }

    @Test("FolderRole raw values")
    func folderRoleRawValues() {
        #expect(FolderRole.inbox.rawValue == "inbox")
        #expect(FolderRole.sent.rawValue == "sent")
        #expect(FolderRole.drafts.rawValue == "drafts")
        #expect(FolderRole.trash.rawValue == "trash")
        #expect(FolderRole.archive.rawValue == "archive")
        #expect(FolderRole.spam.rawValue == "spam")
        #expect(FolderRole.custom.rawValue == "custom")
    }

    @Test("backfillComplete defaults to false")
    func backfillCompleteDefault() {
        let folder = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: "a1")
        #expect(folder.backfillComplete == false)
    }

    @Test("unreadCount and totalCount default to 0")
    func countsDefault() {
        let folder = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: "a1")
        #expect(folder.unreadCount == 0)
        #expect(folder.totalCount == 0)
    }

    @Test("isFavorite defaults to false")
    func isFavoriteDefault() {
        let folder = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: "a1")
        #expect(folder.isFavorite == false)
    }

    @Test("oldestSyncedDate is nil by default")
    func oldestSyncedDateDefault() {
        let folder = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: "a1")
        #expect(folder.oldestSyncedDate == nil)
    }

    @Test("backfillUidCursor is nil by default")
    func backfillUidCursorDefault() {
        let folder = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: "a1")
        #expect(folder.backfillUidCursor == nil)
    }

    @Test("backfillPageToken is nil by default")
    func backfillPageTokenDefault() {
        let folder = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: "a1")
        #expect(folder.backfillPageToken == nil)
    }

    @Test("Hashable uses id only")
    func hashableById() {
        var f1 = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: "a1")
        var f2 = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: "a1")
        f1.unreadCount = 5
        f2.unreadCount = 10
        // Same id → same hash
        #expect(f1.hashValue == f2.hashValue)
    }
}
