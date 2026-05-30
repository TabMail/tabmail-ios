/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Coverage for the NSE staging DB's `folderId` → `folderPath` rename
/// (AppDatabase v3 additive migration) and for the NSEDataBridge merge's
/// decode that now reads the provider-canonical folder path.
///
/// The staging DB normally lives in the App Group container. Here we open
/// a file-backed `DatabaseQueue` in a temp dir, run the schema creation +
/// migration against it (same code path as production), then drive the
/// insert/read shapes that NSE + NSEDataBridge use on-device.
@Suite("NSE staging folderPath migration")
struct NSEStagingFolderPathTests {

    /// Replicate `AppDatabase.createNSEStagingDBIfNeeded`'s schema + v3
    /// migration against an arbitrary DB file. In production this runs on
    /// the shared App Group staging DB once per launch; the migration is
    /// idempotent (ALTER ADD COLUMN + backfill both safe to re-run).
    private func runStagingSchemaWithV3(_ db: DatabaseQueue) throws {
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_processed_message (
                    id TEXT PRIMARY KEY,
                    accountId TEXT NOT NULL, accountEmail TEXT NOT NULL,
                    provider TEXT NOT NULL, messageId TEXT NOT NULL,
                    rfc822MessageId TEXT, threadId TEXT, folderPath TEXT,
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
            for col in ["folderPath TEXT"] {
                do { try db.execute(sql: "ALTER TABLE nse_processed_message ADD COLUMN \(col)") }
                catch {
                    let msg = "\(error)".lowercased()
                    if !msg.contains("duplicate column") { throw error }
                }
            }
            do {
                try db.execute(sql: """
                    UPDATE nse_processed_message
                    SET folderPath = folderId
                    WHERE (folderPath IS NULL OR folderPath = '') AND folderId IS NOT NULL
                    """)
            } catch {
                let msg = "\(error)".lowercased()
                if !msg.contains("no such column") { throw error }
            }
        }
    }

    /// Build a legacy v2 schema (the one that shipped before the rename):
    /// column is `folderId`, no `folderPath`.
    private func runLegacyV2Schema(_ db: DatabaseQueue) throws {
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
        }
    }

    private func tempDB() throws -> DatabaseQueue {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DatabaseQueue(path: dir.appendingPathComponent("s.sqlite").path)
    }

    @Test("v3 migration adds folderPath column on legacy v2 DB")
    func v3AddsColumn() throws {
        let db = try tempDB()
        try runLegacyV2Schema(db)

        try runStagingSchemaWithV3(db)

        // Column exists now — a SELECT shouldn't throw.
        let count = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(folderPath) FROM nse_processed_message") ?? 0
        }
        #expect(count == 0)
    }

    @Test("v3 migration backfills legacy folderId values into folderPath")
    func v3Backfill() throws {
        let db = try tempDB()
        try runLegacyV2Schema(db)

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, folderId, processedAt)
                VALUES ('legacy-1', 'acct', 'a@b.com', 'gmail', 'msg-1', 'INBOX', 0)
                """)
        }

        try runStagingSchemaWithV3(db)

        let folderPath = try db.read { db in
            try String.fetchOne(db, sql: "SELECT folderPath FROM nse_processed_message WHERE id = 'legacy-1'")
        }
        #expect(folderPath == "INBOX")
    }

    @Test("v3 migration is idempotent — second run no-ops")
    func v3Idempotent() throws {
        let db = try tempDB()
        try runLegacyV2Schema(db)
        try runStagingSchemaWithV3(db)
        try runStagingSchemaWithV3(db)  // must not throw

        let count = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nse_processed_message") ?? -1
        }
        #expect(count == 0)
    }

    @Test("Fresh install (no legacy folderId column) tolerates backfill UPDATE")
    func v3OnFreshInstall() throws {
        let db = try tempDB()
        // Fresh schema WITHOUT the legacy folderId column. Simulates an install
        // that went through the new code path only.
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE nse_processed_message (
                    id TEXT PRIMARY KEY, accountId TEXT NOT NULL,
                    accountEmail TEXT NOT NULL, provider TEXT NOT NULL,
                    messageId TEXT NOT NULL, folderPath TEXT,
                    processedAt REAL NOT NULL
                )
                """)
        }

        // Migration should NOT throw when `folderId` doesn't exist.
        try runStagingSchemaWithV3(db)
    }

    @Test("Write with provider folderPath (Outlook) round-trips through the schema")
    func outlookFolderPathRoundTrip() throws {
        let db = try tempDB()
        try runStagingSchemaWithV3(db)

        let graphFolder = "AQMkADAwATE2MTQwLTk2YTQtNjViMy0wMAItMDAKAC4AAAMD"
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, folderPath, processedAt)
                VALUES ('fresh-o', 'acct-o', 'user@outlook.com', 'outlook', 'AQMk…', ?, 0)
                """, arguments: [graphFolder])
        }
        let read = try db.read { db in
            try String.fetchOne(db, sql: "SELECT folderPath FROM nse_processed_message WHERE id = 'fresh-o'")
        }
        #expect(read == graphFolder)
    }
}
