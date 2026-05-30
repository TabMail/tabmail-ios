/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database Migrations")
struct DatabaseMigrationTests {

    @Test("Fresh DB runs all migrations without error")
    func freshDBAllMigrations() throws {
        let db = try TestDatabase.make()
        // Verify key tables exist
        try db.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            #expect(tables.contains("account"))
            #expect(tables.contains("folder"))
            #expect(tables.contains("messageHeader"))
            #expect(tables.contains("messageBody"))
            #expect(tables.contains("pendingOperation"))
            #expect(tables.contains("messageAICache"))
            #expect(tables.contains("outboxMessage"))
            #expect(tables.contains("chatTurn"))
            #expect(tables.contains("pendingCalendarOperation"))
            #expect(tables.contains("caldavConfig"))
            #expect(tables.contains("chatIdMapping"))
        }
    }

    @Test("Running migrations twice is idempotent")
    func migrationsIdempotent() throws {
        let db = try TestDatabase.make()
        // Run again — should not error (DatabaseMigrator skips applied migrations)
        try AppDatabase.runMigrations(on: db)
    }

    @Test("v2: messageHeader folderId='' does not FK-violate")
    func v2FolderIdEmpty() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        // Insert header with empty folderId (optimistic UI pattern)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO messageHeader (id, folderId, accountId, folderPath, isInInbox, messageId, subject, "from", fromAddress, "to", date, snippet, isRead, isFlagged, hasAttachments, tagSortOrder, cc, bcc, isReplied, isForwarded)
                VALUES ('acc1:INBOX:1', '', 'acc1', 'INBOX', 1, '1', 'Test', 'a@b.com', 'a@b.com', 'c@d.com', datetime('now'), '', 0, 0, 0, 99, '', '', 0, 0)
            """)
        }
        // Should not throw FK violation
    }

    @Test("v4: outboxMessage has sentAt column")
    func v4SentAt() throws {
        let db = try TestDatabase.make()
        try db.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(outboxMessage)")
            let names = columns.map { $0["name"] as String }
            #expect(names.contains("sentAt"))
        }
    }

    @Test("v6: chatTurn table exists with expected columns")
    func v6ChatTurn() throws {
        let db = try TestDatabase.make()
        try db.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(chatTurn)")
            let names = columns.map { $0["name"] as String }
            #expect(names.contains("id"))
            #expect(names.contains("role"))
            #expect(names.contains("content"))
        }
    }

    @Test("v11: chatTurn has sessionId column")
    func v11SessionId() throws {
        let db = try TestDatabase.make()
        try db.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(chatTurn)")
            let names = columns.map { $0["name"] as String }
            #expect(names.contains("sessionId"))
        }
    }

    @Test("v18: outboxMessage has sentMessageId and appendedToSent")
    func v18SentAppend() throws {
        let db = try TestDatabase.make()
        try db.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(outboxMessage)")
            let names = columns.map { $0["name"] as String }
            #expect(names.contains("sentMessageId"))
            #expect(names.contains("appendedToSent"))
        }
    }

    @Test("v19: messageBody has icsText column")
    func v19IcsText() throws {
        let db = try TestDatabase.make()
        try db.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(messageBody)")
            let names = columns.map { $0["name"] as String }
            #expect(names.contains("icsText"))
        }
    }

    @Test("v21: composite unread-count index exists")
    func v21UnreadCountIndex() throws {
        let db = try TestDatabase.make()
        try db.read { db in
            let indexes = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='messageHeader'")
            let names = indexes.map { $0["name"] as String }
            #expect(names.contains("messageHeader_folderId_isRead"))
        }
    }
}
