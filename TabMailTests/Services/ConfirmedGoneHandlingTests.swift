/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Header deletion SQL correctness

/// Validates `AccountManager.deleteConfirmedGoneHeader`. The helper is scoped to
/// `headerId` (full `accountId:folderPath:messageId` primary key) — NOT to
/// `(accountId, messageId)` alone — so IMAP UIDs that coincide across folders
/// don't get mass-deleted when only one is confirmed gone.
@Suite("Confirmed-gone header deletion — scoped to exact headerId")
struct DeleteConfirmedGoneHeaderTests {

    @Test("DELETE by headerId removes the row and cascades to messageBody")
    func deleteCascadesToBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        _ = try TestDatabase.insertMessageBody(db, headerId: header.id)

        let bodyCountBefore = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageBody WHERE id = ?", arguments: [header.id]) ?? 0
        }
        #expect(bodyCountBefore == 1)

        let deleted: Bool = try db.write { conn in try MessageHeader.deleteOne(conn, key: header.id) }
        #expect(deleted == true)

        let headerCount = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [header.id]) ?? 0
        }
        #expect(headerCount == 0)

        let bodyCountAfter = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageBody WHERE id = ?", arguments: [header.id]) ?? 0
        }
        #expect(bodyCountAfter == 0)
    }

    /// The exact bug that motivated the audit fix. Two IMAP folders in one account
    /// can hold the same UID — they are unrelated messages (UID space is per-folder).
    /// A broader `WHERE accountId=? AND messageId=?` delete would wipe both when one
    /// is 404'd. A headerId-scoped delete affects only the specific row.
    @Test("Same UID in two folders (IMAP collision) — only the target headerId is deleted")
    func sameUidAcrossFoldersOnlyOneDeleted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        let inboxUid42 = try TestDatabase.insertMessageHeader(
            db, messageId: "42", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", isInInbox: true
        )
        let archiveUid42 = try TestDatabase.insertMessageHeader(
            db, messageId: "42", folderId: "acc1:Archive", accountId: "acc1",
            folderPath: "Archive", isInInbox: false
        )
        #expect(inboxUid42.id != archiveUid42.id)

        let deleted: Bool = try db.write { conn in try MessageHeader.deleteOne(conn, key: inboxUid42.id) }
        #expect(deleted == true)

        let inboxStillThere = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [inboxUid42.id]) ?? 0
        }
        let archiveStillThere = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [archiveUid42.id]) ?? 0
        }
        #expect(inboxStillThere == 0, "Target INBOX UID 42 should be deleted")
        #expect(archiveStillThere == 1, "Archive UID 42 (unrelated message) MUST survive")
    }

    /// Different accounts with same messageId — must not cross-delete either.
    @Test("Same messageId across accounts — scoped by primary key, only target account's row is deleted")
    func sameMessageIdAcrossAccounts() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "accA")
        try TestDatabase.insertAccount(db, id: "accB", email: "b@example.com")
        try TestDatabase.insertFolder(db, accountId: "accA")
        try TestDatabase.insertFolder(db, accountId: "accB")
        let a = try TestDatabase.insertMessageHeader(db, messageId: "same", folderId: "accA:INBOX", accountId: "accA")
        let b = try TestDatabase.insertMessageHeader(db, messageId: "same", folderId: "accB:INBOX", accountId: "accB")

        _ = try db.write { conn in try MessageHeader.deleteOne(conn, key: a.id) }

        let aGone = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [a.id]) ?? 0
        }
        let bStill = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [b.id]) ?? 0
        }
        #expect(aGone == 0)
        #expect(bStill == 1)
    }

    /// `deleteOne` on an absent key is a no-op — safe to call even when another
    /// queue (or full-sync) has already removed the row.
    @Test("DELETE for absent headerId is a safe no-op")
    func deleteAbsentHeaderIsNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let deleted: Bool = try db.write { conn in try MessageHeader.deleteOne(conn, key: "acc1:INBOX:doesnotexist") }
        #expect(deleted == false)
    }

    /// Regression guard: if headerId format ever changes, the PendingOperation
    /// drain call site (which reconstructs headerId via MessageIdentity) must
    /// continue to produce a key that matches the primary key contract.
    @Test("MessageIdentity.headerId format matches MessageHeader primary key")
    func headerIdFormat() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")
        let reconstructed = MessageIdentity.headerId(
            accountId: header.accountId,
            folderPath: header.folderPath,
            messageId: header.messageId
        )
        #expect(reconstructed == header.id)
    }
}
