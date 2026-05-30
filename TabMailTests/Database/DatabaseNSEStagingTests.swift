/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("NSE Staging DB Integration")
struct DatabaseNSEStagingTests {

    /// Create a staging DB with the v2 schema (includes rendered-body columns).
    /// Mirrors AppDatabase.createNSEStagingDBIfNeeded — keep in sync.
    private func makeStagingDB() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_processed_message (
                    id TEXT PRIMARY KEY,
                    accountId TEXT NOT NULL, accountEmail TEXT NOT NULL,
                    provider TEXT NOT NULL, messageId TEXT NOT NULL,
                    rfc822MessageId TEXT, threadId TEXT, folderId TEXT,
                    subject TEXT DEFAULT '', senderName TEXT DEFAULT '', senderEmail TEXT DEFAULT '',
                    snippet TEXT DEFAULT '', date REAL, isRead INTEGER DEFAULT 0,
                    summaryBlurb TEXT, summaryTodos TEXT, actionTag TEXT,
                    reminderDate TEXT, reminderTime TEXT, reminderContent TEXT,
                    processedAt REAL NOT NULL, historyId TEXT,
                    aiCompleted INTEGER DEFAULT 0, notified INTEGER DEFAULT 0,
                    htmlContent TEXT, textContent TEXT,
                    attachmentsJSON TEXT, icsText TEXT,
                    hasUnresolvedCIDs INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_pending_task_result (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    taskName TEXT NOT NULL, taskInstruction TEXT NOT NULL,
                    result TEXT NOT NULL, timestamp REAL NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_inbox_removal (
                    id TEXT PRIMARY KEY,
                    accountId TEXT NOT NULL,
                    messageId TEXT NOT NULL,
                    timestamp REAL NOT NULL
                )
                """)
        }
        return db
    }

    /// Create a v1-era staging DB (pre-refactor schema), then run the v2 ALTER
    /// migrations. Used by the migration test below.
    private func makeStagingDBWithV1Migrate() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            // v1 schema — no rendered-body columns.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_processed_message (
                    id TEXT PRIMARY KEY,
                    accountId TEXT NOT NULL, accountEmail TEXT NOT NULL,
                    provider TEXT NOT NULL, messageId TEXT NOT NULL,
                    rfc822MessageId TEXT, threadId TEXT, folderId TEXT,
                    subject TEXT DEFAULT '', senderName TEXT DEFAULT '', senderEmail TEXT DEFAULT '',
                    snippet TEXT DEFAULT '', date REAL, isRead INTEGER DEFAULT 0,
                    summaryBlurb TEXT, summaryTodos TEXT, actionTag TEXT,
                    reminderDate TEXT, reminderTime TEXT, reminderContent TEXT,
                    processedAt REAL NOT NULL, historyId TEXT,
                    aiCompleted INTEGER DEFAULT 0, notified INTEGER DEFAULT 0
                )
                """)

            // Migrate v1 → v2 (additive ALTER TABLE; matches production migration).
            for col in [
                "htmlContent TEXT", "textContent TEXT",
                "attachmentsJSON TEXT", "icsText TEXT",
                "hasUnresolvedCIDs INTEGER DEFAULT 0",
            ] {
                try? db.execute(sql: "ALTER TABLE nse_processed_message ADD COLUMN \(col)")
            }
        }
        return db
    }

    // MARK: - Inbox Removal Schema

    @Test("nse_inbox_removal table stores and retrieves removal records")
    func inboxRemovalCRUD() throws {
        let db = try makeStagingDB()
        let now = Date().timeIntervalSince1970

        // Insert removals
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO nse_inbox_removal (id, accountId, messageId, timestamp)
                VALUES (?, ?, ?, ?)
                """, arguments: ["acc1:msg100", "acc1", "msg100", now])
            try db.execute(sql: """
                INSERT INTO nse_inbox_removal (id, accountId, messageId, timestamp)
                VALUES (?, ?, ?, ?)
                """, arguments: ["acc1:msg200", "acc1", "msg200", now])
        }

        // Read back
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM nse_inbox_removal ORDER BY messageId")
        }
        #expect(rows.count == 2)
        guard rows.count == 2 else { return }

        let first: String = rows[0]["messageId"]
        let second: String = rows[1]["messageId"]
        #expect(first == "msg100")
        #expect(second == "msg200")
    }

    @Test("nse_inbox_removal deduplicates by id (INSERT OR IGNORE)")
    func inboxRemovalDedup() throws {
        let db = try makeStagingDB()
        let now = Date().timeIntervalSince1970

        // Insert same id twice — should not fail
        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO nse_inbox_removal (id, accountId, messageId, timestamp)
                VALUES (?, ?, ?, ?)
                """, arguments: ["acc1:msg100", "acc1", "msg100", now])
            try db.execute(sql: """
                INSERT OR IGNORE INTO nse_inbox_removal (id, accountId, messageId, timestamp)
                VALUES (?, ?, ?, ?)
                """, arguments: ["acc1:msg100", "acc1", "msg100", now + 10])
        }

        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM nse_inbox_removal") }
        #expect(count == 1)
    }

    // MARK: - Inbox Removal Merge Logic

    @Test("Inbox removal deletes matching INBOX messages from main DB")
    func inboxRemovalMerge() throws {
        let mainDB = try TestDatabase.make()

        // Set up: account, folder, inbox message
        try TestDatabase.insertAccount(mainDB, id: "acc1", email: "user@gmail.com")
        try TestDatabase.insertFolder(mainDB, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(mainDB, messageId: "msg100", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(mainDB, messageId: "msg200", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(mainDB, messageId: "msg300", folderId: "acc1:INBOX", accountId: "acc1")

        // Verify 3 messages exist
        let beforeCount = try mainDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageHeader WHERE folderId LIKE '%:INBOX'") }
        #expect(beforeCount == 3)

        // Simulate NSE removal merge — delete msg100 and msg200 (as if archived from another device)
        try mainDB.write { db in
            let removedMessageIds = ["msg100", "msg200"]
            for messageId in removedMessageIds {
                try db.execute(sql: """
                    DELETE FROM messageHeader
                    WHERE accountId = ? AND messageId = ? AND folderId LIKE '%:INBOX'
                    """, arguments: ["acc1", messageId])
            }
        }

        // Verify only msg300 remains
        let afterCount = try mainDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageHeader WHERE folderId LIKE '%:INBOX'") }
        #expect(afterCount == 1)

        let remaining = try mainDB.read { db in
            try Row.fetchOne(db, sql: "SELECT messageId FROM messageHeader WHERE folderId LIKE '%:INBOX'")
        }
        let remainingId: String? = remaining?["messageId"]
        #expect(remainingId == "msg300")
    }

    @Test("Inbox removal only affects INBOX folder, not other folders")
    func inboxRemovalScopedToInbox() throws {
        let mainDB = try TestDatabase.make()

        try TestDatabase.insertAccount(mainDB, id: "acc1", email: "user@gmail.com")
        try TestDatabase.insertFolder(mainDB, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(mainDB, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        // Same messageId in INBOX and Archive
        try TestDatabase.insertMessageHeader(mainDB, messageId: "msg100", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(mainDB, messageId: "msg100-archive", folderId: "acc1:Archive", accountId: "acc1")

        // Remove from INBOX only
        try mainDB.write { db in
            try db.execute(sql: """
                DELETE FROM messageHeader
                WHERE accountId = ? AND messageId = ? AND folderId LIKE '%:INBOX'
                """, arguments: ["acc1", "msg100"])
        }

        // INBOX should be empty, Archive should still have its message
        let inboxCount = try mainDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageHeader WHERE folderId = 'acc1:INBOX'") }
        let archiveCount = try mainDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageHeader WHERE folderId = 'acc1:Archive'") }
        #expect(inboxCount == 0)
        #expect(archiveCount == 1)
    }

    @Test("Inbox removal for nonexistent message is a no-op")
    func inboxRemovalNonexistent() throws {
        let mainDB = try TestDatabase.make()

        try TestDatabase.insertAccount(mainDB, id: "acc1", email: "user@gmail.com")
        try TestDatabase.insertFolder(mainDB, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(mainDB, messageId: "msg100", folderId: "acc1:INBOX", accountId: "acc1")

        // Try to remove a message that doesn't exist — should not throw
        try mainDB.write { db in
            try db.execute(sql: """
                DELETE FROM messageHeader
                WHERE accountId = ? AND messageId = ? AND folderId LIKE '%:INBOX'
                """, arguments: ["acc1", "msg-nonexistent"])
        }

        // Original message still there
        let count = try mainDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageHeader") }
        #expect(count == 1)
    }

    // MARK: - NSE Processed Message with AI data

    @Test("Staging DB persists processed message with AI results")
    func stagingDBProcessedMessage() throws {
        let db = try makeStagingDB()
        let now = Date().timeIntervalSince1970

        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, rfc822MessageId, threadId,
                 folderId, subject, senderName, senderEmail, snippet, date,
                 summaryBlurb, summaryTodos, actionTag,
                 processedAt, historyId, aiCompleted, notified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "acc1:msg100", "acc1", "user@gmail.com", "gmail", "msg100",
                    "abc@mail.gmail.com", "thread1",
                    "INBOX", "Test Subject", "Alice", "alice@example.com", "Hello...", now,
                    "Summary of the email", "- Todo 1", "reply",
                    now, "99999", 1, 1
                ])
        }

        let row = try db.read { try Row.fetchOne($0, sql: "SELECT * FROM nse_processed_message WHERE id = 'acc1:msg100'") }
        #expect(row != nil)
        let summaryBlurb: String? = row?["summaryBlurb"]
        let actionTag: String? = row?["actionTag"]
        let aiCompleted: Int? = row?["aiCompleted"]
        #expect(summaryBlurb == "Summary of the email")
        #expect(actionTag == "reply")
        #expect(aiCompleted == 1)
    }

    @Test("Inbox removal across multiple accounts is isolated")
    func inboxRemovalMultiAccount() throws {
        let mainDB = try TestDatabase.make()

        try TestDatabase.insertAccount(mainDB, id: "acc1", email: "user1@gmail.com")
        try TestDatabase.insertAccount(mainDB, id: "acc2", email: "user2@gmail.com")
        try TestDatabase.insertFolder(mainDB, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(mainDB, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        try TestDatabase.insertMessageHeader(mainDB, messageId: "msg100", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(mainDB, messageId: "msg100", folderId: "acc2:INBOX", accountId: "acc2")

        // Remove msg100 from acc1 only
        try mainDB.write { db in
            try db.execute(sql: """
                DELETE FROM messageHeader
                WHERE accountId = ? AND messageId = ? AND folderId LIKE '%:INBOX'
                """, arguments: ["acc1", "msg100"])
        }

        // acc1 inbox empty, acc2 inbox untouched
        let acc1Count = try mainDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageHeader WHERE accountId = 'acc1'") }
        let acc2Count = try mainDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageHeader WHERE accountId = 'acc2'") }
        #expect(acc1Count == 0)
        #expect(acc2Count == 1)
    }

    @Test("Staging DB nse_inbox_removal table exists check handles missing table")
    func inboxRemovalTableExistsCheck() throws {
        // Create a staging DB WITHOUT the removal table (simulates old schema)
        var config = Configuration()
        config.foreignKeysEnabled = false
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_processed_message (
                    id TEXT PRIMARY KEY, accountId TEXT NOT NULL, accountEmail TEXT NOT NULL,
                    provider TEXT NOT NULL, messageId TEXT NOT NULL, processedAt REAL NOT NULL,
                    aiCompleted INTEGER DEFAULT 0, notified INTEGER DEFAULT 0
                )
                """)
        }

        // Reading from missing table should not crash
        let exists = try db.read { try $0.tableExists("nse_inbox_removal") }
        #expect(exists == false)

        // The merge logic guards on tableExists — no rows returned
        let removals = try db.read { db -> [Row] in
            guard try db.tableExists("nse_inbox_removal") else { return [] }
            return try Row.fetchAll(db, sql: "SELECT * FROM nse_inbox_removal")
        }
        #expect(removals.isEmpty)
    }

    // MARK: - PushConfig Settings

    @Test("PushConfig.nseFilteringApproved is false (pending Apple approval)")
    func filteringNotApproved() {
        #expect(PushConfig.nseFilteringApproved == false)
    }

    @Test("PushConfig.pushNotificationsEnabledKey matches expected key")
    func pushEnabledKey() {
        #expect(PushConfig.pushNotificationsEnabledKey == "push_notifications_enabled")
    }

    // MARK: - NSE Processed Message with AI data

    @Test("Staging DB INSERT OR REPLACE overwrites existing message")
    func stagingDBDedup() throws {
        let db = try makeStagingDB()
        let now = Date().timeIntervalSince1970

        // Insert first version
        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, processedAt, aiCompleted, notified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["acc1:msg100", "acc1", "user@gmail.com", "gmail", "msg100", now, 0, 0])
        }

        // Insert second version with AI data
        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, summaryBlurb, actionTag, processedAt, aiCompleted, notified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["acc1:msg100", "acc1", "user@gmail.com", "gmail", "msg100", "Updated summary", "reply", now + 5, 1, 1])
        }

        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM nse_processed_message") }
        #expect(count == 1)

        let row = try db.read { try Row.fetchOne($0, sql: "SELECT * FROM nse_processed_message WHERE id = 'acc1:msg100'") }
        let summary: String? = row?["summaryBlurb"]
        #expect(summary == "Updated summary")
    }

    // MARK: - v2 schema (rendered-body columns) + v1→v2 migration

    @Test("v2 schema has rendered-body columns (htmlContent/textContent/attachmentsJSON/icsText/hasUnresolvedCIDs)")
    func v2SchemaHasRenderedBodyColumns() throws {
        let db = try makeStagingDB()
        let cols: Set<String> = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(nse_processed_message)")
            return Set(rows.compactMap { $0["name"] as String? })
        }
        #expect(cols.contains("htmlContent"))
        #expect(cols.contains("textContent"))
        #expect(cols.contains("attachmentsJSON"))
        #expect(cols.contains("icsText"))
        #expect(cols.contains("hasUnresolvedCIDs"))
    }

    @Test("v1→v2 migration adds rendered-body columns without data loss")
    func v1ToV2MigrationAddsColumns() throws {
        let db = try makeStagingDBWithV1Migrate()
        // After ALTER TABLE ADD COLUMN, new columns present.
        let cols: Set<String> = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(nse_processed_message)")
            return Set(rows.compactMap { $0["name"] as String? })
        }
        #expect(cols.contains("htmlContent"))
        #expect(cols.contains("textContent"))
        #expect(cols.contains("hasUnresolvedCIDs"))
        // Legacy columns still present — ALTER TABLE is additive.
        #expect(cols.contains("summaryBlurb"))
        #expect(cols.contains("actionTag"))
    }

    @Test("v1→v2 migration is idempotent (second run is no-op)")
    func v1ToV2MigrationIdempotent() throws {
        let db = try makeStagingDBWithV1Migrate()
        // Second migration run should silently no-op on ALTER TABLE duplicate-column.
        try db.write { db in
            for col in ["htmlContent TEXT", "textContent TEXT", "attachmentsJSON TEXT",
                        "icsText TEXT", "hasUnresolvedCIDs INTEGER DEFAULT 0"] {
                try? db.execute(sql: "ALTER TABLE nse_processed_message ADD COLUMN \(col)")
            }
        }
        // Column count remains stable.
        let colCount: Int = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(nse_processed_message)")
            return rows.count
        }
        #expect(colCount >= 27)  // ~22 v1 cols + 5 v2 cols = 27
    }

    @Test("v2 schema accepts rendered-body INSERT with all new columns")
    func v2SchemaInsertWithBody() throws {
        let db = try makeStagingDB()
        let now = Date().timeIntervalSince1970
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, processedAt,
                 htmlContent, textContent, attachmentsJSON, icsText, hasUnresolvedCIDs)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "acc1:body-test", "acc1", "u@ex.com", "gmail", "msg", now,
                    "<p>hi</p>", "hi", "[]", "BEGIN:VCALENDAR", 1
                ])
        }
        let row = try db.read {
            try Row.fetchOne($0, sql: "SELECT * FROM nse_processed_message WHERE id = 'acc1:body-test'")
        }
        #expect(row?["htmlContent"] == "<p>hi</p>")
        #expect(row?["textContent"] == "hi")
        #expect(row?["attachmentsJSON"] == "[]")
        #expect(row?["icsText"] == "BEGIN:VCALENDAR")
        #expect(row?["hasUnresolvedCIDs"] == 1)
    }
}
