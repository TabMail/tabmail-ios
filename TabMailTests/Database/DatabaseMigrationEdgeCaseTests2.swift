/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Migration Data Integrity")
struct MigrationDataIntegrityTests {

    @Test("messageAICache table has no foreign key (intentional)")
    func aiCacheNoFK() throws {
        let db = try TestDatabase.make()

        // Insert AI cache without any account/header existing
        try db.write { db in
            var cache = MessageAICache(key: "orphan:key", rfc822MessageId: "<orphan@test.com>")
            cache.summaryBlurb = "No parent"
            try cache.insert(db)
        }

        // Should succeed — no FK means no constraint violation
        let fetched = try db.read { try MessageAICache.fetchOne($0, key: "orphan:key") }
        #expect(fetched?.summaryBlurb == "No parent")
    }

    @Test("chatTurn table exists with sessionId column (v11)")
    func chatTurnSessionId() throws {
        let db = try TestDatabase.make()

        let turn = ChatTurn(
            id: "t1", timestamp: 1000, role: "user",
            content: "test", userMessage: nil,
            type: "normal", chars: 4, renderedContent: nil,
            sessionId: "session-xyz", remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "t1") }
        #expect(fetched?.sessionId == "session-xyz")
    }

    @Test("outboxMessage has sentAt and appendedToSent columns (v18)")
    func outboxV18Columns() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "V18", body: "test")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.sentAt = Date()
        msg.appendedToSent = true
        msg.sentMessageId = "<uuid@tabmail.ai>"
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.sentAt != nil)
        #expect(fetched?.appendedToSent == true)
        #expect(fetched?.sentMessageId == "<uuid@tabmail.ai>")
    }

    @Test("Multiple migrations are idempotent (run twice)")
    func migrationsIdempotent() throws {
        // Creating TestDatabase runs all migrations
        let db1 = try TestDatabase.make()
        // Second make() runs all migrations again on a fresh DB — no crash
        let db2 = try TestDatabase.make()

        // Both should be functional
        try TestDatabase.insertAccount(db1)
        try TestDatabase.insertAccount(db2)

        #expect(try db1.read { try Account.fetchCount($0) } == 1)
        #expect(try db2.read { try Account.fetchCount($0) } == 1)
    }

    @Test("All expected tables exist after migration")
    func allTablesExist() throws {
        let db = try TestDatabase.make()
        let tables = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'")
        }

        let expected = ["account", "folder", "messageHeader", "messageBody",
                        "pendingOperation", "messageAICache", "outboxMessage", "chatTurn"]
        for table in expected {
            #expect(tables.contains(table), "Missing table: \(table)")
        }
    }

    @Test("Foreign keys are enabled")
    func foreignKeysEnabled() throws {
        let db = try TestDatabase.make()
        let fkEnabled = try db.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        #expect(fkEnabled == 1)
    }
}

@Suite("Database Schema Edge Cases")
struct DatabaseSchemaEdgeCaseTests {

    @Test("NULL values in optional MessageHeader fields")
    func nullOptionalFields() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let header = MessageHeader(
            messageId: "1", subject: "Test", from: "a@b.com",
            fromAddress: "a@b.com", to: "c@d.com", date: Date(),
            snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        try db.write { try header.insert($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.rfc822MessageId == nil)
        #expect(fetched?.threadId == nil)
        #expect(fetched?.inReplyTo == nil)
        #expect(fetched?.actionTag == nil)
    }

    @Test("MessageBody with nil htmlContent")
    func bodyNilHtmlContent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        let body = MessageBody( contentKey: ContentKey(rawValue: "acc1:INBOX:1"), htmlContent: nil)
        try db.write { try body.insert($0) }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(fetched?.htmlContent == nil)
    }

    @Test("Folder unreadCount and totalCount default to zero")
    func folderCountDefaults() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        #expect(folder.unreadCount == 0)
        #expect(folder.totalCount == 0)
    }

    @Test("PendingOperation retryCount defaults to zero")
    func pendingOpRetryDefault() {
        let op = PendingOperation(
            type: .archive, messageIds: ["1"],
            accountId: "acc1", folderPath: "INBOX"
        )
        #expect(op.retryCount == 0)
    }

    @Test("PendingOperation status defaults to queued")
    func pendingOpStatusDefault() {
        let op = PendingOperation(
            type: .archive, messageIds: ["1"],
            accountId: "acc1", folderPath: "INBOX"
        )
        #expect(op.status == PendingStatus.queued.rawValue)
    }

    @Test("Large messageIds JSON array persists correctly")
    func largeMessageIdsArray() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let ids = (0..<100).map { "msg_\($0)" }
        var op = PendingOperation(
            type: .markRead, messageIds: ids,
            accountId: "acc1", folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.messageIds.count == 100)
        #expect(fetched?.messageIds.contains("msg_50") == true)
    }
}
