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

    @Test("CASCADE delete: account → folder → messageHeader → messageBody")
    func cascadeDeleteChain() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")

        // Delete account should cascade everything
        try db.write { _ = try Account.deleteAll($0, keys: ["acc1"]) }

        let folderCount = try db.read { try Folder.fetchCount($0) }
        let headerCount = try db.read { try MessageHeader.fetchCount($0) }
        let bodyCount = try db.read { try MessageBody.fetchCount($0) }
        #expect(folderCount == 0)
        #expect(headerCount == 0)
        #expect(bodyCount == 0)
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
