/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database Multi-Account")
struct DatabaseMultiAccountTests {

    @Test("Messages from different accounts are isolated")
    func accountIsolation() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@b.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "c@d.com")
        try TestDatabase.insertFolder(db, accountId: "acc1")
        try TestDatabase.insertFolder(db, accountId: "acc2")

        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc2:INBOX", accountId: "acc2")

        let acc1Count = try db.read {
            try MessageHeader.filter(Column("accountId") == "acc1").fetchCount($0)
        }
        let acc2Count = try db.read {
            try MessageHeader.filter(Column("accountId") == "acc2").fetchCount($0)
        }
        #expect(acc1Count == 2)
        #expect(acc2Count == 1)
    }

    @Test("Deleting one account doesn't affect another")
    func deleteOneAccountPreservesOther() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@b.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "c@d.com")
        try TestDatabase.insertFolder(db, accountId: "acc1")
        try TestDatabase.insertFolder(db, accountId: "acc2")
        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc2:INBOX", accountId: "acc2")

        // Delete acc1
        try db.write { _ = try Account.deleteAll($0, keys: ["acc1"]) }

        // acc2 should be untouched
        let acc2Messages = try db.read {
            try MessageHeader.filter(Column("accountId") == "acc2").fetchAll($0)
        }
        #expect(acc2Messages.count == 1)

        let acc1Messages = try db.read {
            try MessageHeader.filter(Column("accountId") == "acc1").fetchAll($0)
        }
        #expect(acc1Messages.isEmpty)
    }

    @Test("Folders cascade independently per account")
    func folderCascadePerAccount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@b.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "c@d.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")

        try db.write { _ = try Account.deleteAll($0, keys: ["acc1"]) }

        let remainingFolders = try db.read { try Folder.fetchAll($0) }
        #expect(remainingFolders.count == 1)
        #expect(remainingFolders[0].accountId == "acc2")
    }

    @Test("MessageAICache survives account deletion (no FK)")
    func aiCacheSurvivesAccountDeletion() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1", rfc822MessageId: "<msg@ex.com>")

        let key = "acc1:INBOX:<msg@ex.com>"
        try db.write { db in
            var cache = MessageAICache(key: key, rfc822MessageId: "<msg@ex.com>")
            cache.summaryBlurb = "Summary"
            try cache.insert(db)
        }

        // Delete account (cascades to folders, headers, bodies)
        try db.write { _ = try Account.deleteAll($0, keys: ["acc1"]) }

        // AI cache should survive (intentionally no FK)
        let fetched = try db.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(fetched != nil)
        #expect(fetched?.summaryBlurb == "Summary")
    }
}
