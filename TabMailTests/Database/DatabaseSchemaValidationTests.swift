/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database Schema Validation")
struct DatabaseSchemaValidationTests {

    @Test("All expected tables exist after migration")
    func allTablesExist() throws {
        let db = try TestDatabase.make()
        let tables = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        let expected = ["account", "chatIdMapping", "chatTurn", "folder", "grdb_migrations",
                        "messageAICache", "messageBody", "messageHeader", "outboxMessage", "pendingOperation"]
        for table in expected {
            #expect(tables.contains(table), "Missing table: \(table)")
        }
    }

    @Test("Foreign keys are enabled")
    func foreignKeysEnabled() throws {
        let db = try TestDatabase.make()
        let fkEnabled = try db.read { db -> Int in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0
        }
        #expect(fkEnabled == 1)
    }

    @Test("messageHeader has expected columns")
    func messageHeaderColumns() throws {
        let db = try TestDatabase.make()
        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(messageHeader)").map { $0["name"] as String }
        }
        let expected = ["id", "accountId", "folderId", "messageId", "date", "from",
                        "fromAddress", "subject", "isRead", "isInInbox"]
        for col in expected {
            #expect(columns.contains(col), "Missing column: \(col)")
        }
    }

    @Test("outboxMessage has sentAt, sentMessageId, appendedToSent columns")
    func outboxMessageColumns() throws {
        let db = try TestDatabase.make()
        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(outboxMessage)").map { $0["name"] as String }
        }
        #expect(columns.contains("sentAt"))
        #expect(columns.contains("sentMessageId"))
        #expect(columns.contains("appendedToSent"))
    }

    @Test("chatTurn has sessionId and remindersSnapshot columns")
    func chatTurnColumns() throws {
        let db = try TestDatabase.make()
        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(chatTurn)").map { $0["name"] as String }
        }
        #expect(columns.contains("sessionId"))
        #expect(columns.contains("remindersSnapshot"))
    }

    @Test("messageBody has icsText column")
    func messageBodyIcsText() throws {
        let db = try TestDatabase.make()
        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(messageBody)").map { $0["name"] as String }
        }
        #expect(columns.contains("icsText"))
    }

    @Test("chatIdMapping table exists with expected columns")
    func chatIdMappingTable() throws {
        let db = try TestDatabase.make()
        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(chatIdMapping)").map { $0["name"] as String }
        }
        #expect(columns.contains("numericId"))
        #expect(columns.contains("realId"))
    }

    /// The cascade chain now STOPS at `messageHeader`. Stage D
    /// (`v70_dropMessageBodyHeaderFK`) removed the last link because a content key
    /// is not a header id: once N headers can share one key, a per-header cascade
    /// deletes a row the other N−1 still own, and it does so below the application
    /// layer where `MessageContentStore` cannot veto it.
    ///
    /// The half that must NOT regress is `account → folder → messageHeader`.
    /// The half that moved is the body, and it did not merely become someone
    /// else's problem — `AccountManager.removeAccountRowsTxn` deletes it in
    /// the same transaction, which is pinned by
    /// `removeAccountLeavesNoCachedMailBehind` below. Read the two together: this
    /// one says the schema no longer does it, that one says the production path
    /// still does.
    @Test("CASCADE delete: account → folder → messageHeader, and NO LONGER → messageBody")
    func cascadeDeleteChain() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")

        // Delete account — folders and headers still cascade.
        try db.write { _ = try Account.deleteAll($0, keys: ["acc1"]) }

        let folderCount = try db.read { try Folder.fetchCount($0) }
        let headerCount = try db.read { try MessageHeader.fetchCount($0) }
        let bodyCount = try db.read { try MessageBody.fetchCount($0) }
        #expect(folderCount == 0)
        #expect(headerCount == 0)
        #expect(bodyCount == 1, "content must not ride a header-space cascade")
    }

    /// The PRODUCTION account-removal transaction, driven directly. A removed
    /// account's cached email HTML must not survive it — before Stage D the FK
    /// cascade did this, and the invariant is privacy-adjacent: the user asked for
    /// the account's data to be gone.
    ///
    /// RED with the `DELETE FROM messageBody` line removed from
    /// `removeAccountRowsTxn` (verified by inverting it).
    ///
    /// Two-sided: the OTHER account's rows must all survive, so a transaction that
    /// simply wiped the tables would fail this.
    @Test("removeAccount leaves no cached mail behind — and touches no other account")
    func removeAccountLeavesNoCachedMailBehind() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "one@example.com")
        try TestDatabase.insertFolder(db, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")
        // A second folder, so the prefix delete is proven to span folders.
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertMessageHeader(
            db, messageId: "2", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false)
        try TestDatabase.insertMessageBody(db, headerId: "acc1:Archive:2")

        try TestDatabase.insertAccount(db, id: "acc2", email: "two@example.com")
        try TestDatabase.insertFolder(db, accountId: "acc2")
        try TestDatabase.insertMessageHeader(db, messageId: "9", folderId: "acc2:INBOX", accountId: "acc2")
        try TestDatabase.insertMessageBody(db, headerId: "acc2:INBOX:9")

        try db.write { conn in
            try AccountManager.removeAccountRowsTxn(conn, accountId: "acc1", wasPrimary: false)
        }

        let survivors = try db.read { conn in
            try String.fetchAll(conn, sql: "SELECT id FROM messageBody ORDER BY id")
        }
        #expect(survivors == ["acc2:INBOX:9"],
                "every body of the removed account must be gone, in EVERY folder, and no other account's may be")
        #expect(try db.read { try MessageHeader.fetchCount($0) } == 1)
        #expect(try db.read { try Account.fetchCount($0) } == 1)
    }

    /// 🚨 THE WRITE-SIDE INVARIANT, and the strongest red proof Stage D has: it
    /// needs no key movement at all. On the pre-v70 schema this INSERT dies with
    /// `FOREIGN KEY constraint failed`, because `foreignKeysEnabled = true` and no
    /// `messageHeader` holds that id.
    ///
    /// That is what E1-before-D would have been in production: not "bodies get
    /// deleted later" but *every body write for every rfc-having IMAP/iCloud
    /// message throws* — the on-demand open path, the backfill, the NSE render.
    @Test("A body row may be stored under a content key no header holds")
    func aBodyRowMayBeStoredUnderAKeyNoHeaderHolds() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        // An rfc-tailed content key — the shape Stage E1 mints — with deliberately
        // NO matching messageHeader row.
        let rfcKey = "acc1:INBOX:rfc-tail@example.com"
        #expect(try db.read { try MessageHeader.fetchOne($0, key: rfcKey) } == nil)

        try db.write { conn in
            try MessageBody(contentKey: ContentKey(rawValue: rfcKey), htmlContent: "<p>rfc</p>")
                .insert(conn)
        }

        let stored = try db.read { try MessageBody.fetchOne($0, key: rfcKey) }
        #expect(stored?.htmlContent == "<p>rfc</p>")
    }

    /// The DELETE-side invariant, stated as an END STATE rather than "the FK is
    /// absent": deleting one header must not remove content keyed to another.
    ///
    /// At Stage D `ContentKey.forHeader` still returns the header id, so the key
    /// spaces cannot be made to diverge through production code — this expresses it
    /// at the schema level, which is exactly the layer the cascade lived at and the
    /// only layer that could execute it without consulting `MessageContentStore`.
    @Test("Deleting one header removes no other content, and none of its own")
    func deletingAHeaderDoesNotTakeContentWithIt() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let a = try TestDatabase.insertMessageHeader(db, messageId: "1")
        let b = try TestDatabase.insertMessageHeader(db, messageId: "2")
        try TestDatabase.insertMessageBody(db, headerId: a.id, htmlContent: "<p>A</p>")
        try TestDatabase.insertMessageBody(db, headerId: b.id, htmlContent: "<p>B</p>")

        try db.write { _ = try MessageHeader.deleteOne($0, key: a.id) }

        let remaining = try db.read { conn in
            try String.fetchAll(conn, sql: "SELECT id FROM messageBody ORDER BY id")
        }
        #expect(remaining.count == 2)
        guard remaining.count == 2 else { return }
        #expect(remaining == [a.id, b.id].sorted(),
                "no header delete may take a content row with it — at E1 that row can be shared")
    }

    /// The migration's own post-conditions, asserted on a fully migrated database.
    @Test("v70: messageBody declares no foreign key, and the database is clean")
    func messageBodyHasNoForeignKeyAfterV70() throws {
        let db = try TestDatabase.make()
        try db.read { conn in
            let fks = try Row.fetchAll(conn, sql: #"PRAGMA foreign_key_list("messageBody")"#)
            #expect(fks.isEmpty, "v70 must leave messageBody with no REFERENCES clause")
            let integrity = try String.fetchOne(conn, sql: "PRAGMA integrity_check")
            #expect(integrity == "ok")
            let violations = try Row.fetchAll(conn, sql: "PRAGMA foreign_key_check")
            #expect(violations.isEmpty)
            // The sibling header-space cascades stay — dropping them would orphan
            // threading references and label junctions with no sweep to reclaim them.
            let refFks = try Row.fetchAll(conn, sql: #"PRAGMA foreign_key_list("messageReference")"#)
            let labelFks = try Row.fetchAll(conn, sql: #"PRAGMA foreign_key_list("messageUserLabel")"#)
            #expect(!refFks.isEmpty, "messageReference must KEEP its header cascade")
            #expect(!labelFks.isEmpty, "messageUserLabel must KEEP its header cascade")
        }
    }

    @Test("MessageAICache survives header deletion (no FK)")
    func aiCacheSurvivesHeaderDeletion() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1", rfc822MessageId: "<msg@ex.com>")

        try db.write { db in
            var cache = MessageAICache(key: "acc1:INBOX:<msg@ex.com>", rfc822MessageId: "<msg@ex.com>")
            cache.summaryBlurb = "Summary"
            try cache.insert(db)
        }

        // Delete header
        try db.write { _ = try MessageHeader.deleteOne($0, key: "acc1:INBOX:1") }

        // Cache still exists
        let cache = try db.read { try MessageAICache.fetchOne($0, key: "acc1:INBOX:<msg@ex.com>") }
        #expect(cache?.summaryBlurb == "Summary")
    }
}
