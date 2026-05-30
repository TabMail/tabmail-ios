/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database Migration Extended")
struct DatabaseMigrationExtendedTests {

    @Test("All expected tables exist after migration")
    func allTablesExist() throws {
        let db = try TestDatabase.make()
        let tables = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        let expectedTables = [
            "account", "folder", "messageHeader", "messageBody",
            "pendingOperation", "messageAICache", "outboxMessage", "chatTurn"
        ]
        for table in expectedTables {
            #expect(tables.contains(table), "Missing table: \(table)")
        }
    }

    @Test("grdb_migrations table tracks applied migrations")
    func migrationsTracked() throws {
        let db = try TestDatabase.make()
        let migrations = try db.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(!migrations.isEmpty)
        #expect(migrations.contains("v1_createTables"))
    }

    @Test("Foreign keys are enabled")
    func foreignKeysEnabled() throws {
        let db = try TestDatabase.make()
        let fkEnabled = try db.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        #expect(fkEnabled == 1)
    }

    @Test("messageHeader table has expected columns")
    func messageHeaderColumns() throws {
        let db = try TestDatabase.make()
        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(messageHeader)")
        }
        let columnNames = columns.map { $0["name"] as String }
        let expected = ["id", "messageId", "subject", "from", "fromAddress", "to", "date",
                        "snippet", "folderId", "accountId", "isRead", "isFlagged", "isInInbox"]
        for col in expected {
            #expect(columnNames.contains(col), "Missing column: \(col)")
        }
    }

    @Test("outboxMessage table has sentAt and sentMessageId columns")
    func outboxMessageColumns() throws {
        let db = try TestDatabase.make()
        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(outboxMessage)")
        }
        let columnNames = columns.map { $0["name"] as String }
        #expect(columnNames.contains("sentAt"))
        #expect(columnNames.contains("sentMessageId"))
        #expect(columnNames.contains("appendedToSent"))
    }

    @Test("chatTurn table has sessionId column (v11 migration)")
    func chatTurnSessionId() throws {
        let db = try TestDatabase.make()
        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(chatTurn)")
        }
        let columnNames = columns.map { $0["name"] as String }
        #expect(columnNames.contains("sessionId"))
        #expect(columnNames.contains("renderedContent"))
    }

    @Test("messageBody has icsText column (v19 migration)")
    func messageBodyIcsText() throws {
        let db = try TestDatabase.make()
        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(messageBody)")
        }
        let columnNames = columns.map { $0["name"] as String }
        #expect(columnNames.contains("icsText"))
    }

    @Test("chatTurn has remindersSnapshot column (v20 migration)")
    func chatTurnRemindersSnapshot() throws {
        let db = try TestDatabase.make()
        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(chatTurn)")
        }
        let columnNames = columns.map { $0["name"] as String }
        #expect(columnNames.contains("remindersSnapshot"))
    }
}
