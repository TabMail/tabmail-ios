/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database Migrations")
struct DatabaseMigrationTests {

    /// Insert a messageHeader row using only the columns that exist through
    /// v70 (mirrors `v2FolderIdEmpty`'s literal column list) — for tests that
    /// deliberately migrate to an intermediate version and therefore cannot
    /// use `TestDatabase.insertMessageHeader` (that helper's `.insert(db)`
    /// encodes every CURRENT `MessageHeader` model column, including any
    /// added by a later migration such as v72's `actionTagSetAt`). Returns
    /// the row's id (`MessageIdentity.headerId`, matching the model's own
    /// id derivation).
    @discardableResult
    private func insertLegacyMessageHeader(
        _ db: DatabaseQueue,
        messageId: String,
        folderId: String,
        accountId: String,
        folderPath: String = "INBOX"
    ) throws -> String {
        let id = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: messageId)
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO messageHeader (id, folderId, accountId, folderPath, isInInbox, messageId, subject, "from", fromAddress, "to", date, snippet, isRead, isFlagged, hasAttachments, tagSortOrder, cc, bcc, isReplied, isForwarded)
                VALUES (?, ?, ?, ?, 1, ?, 'Test', 'sender@example.com', 'sender@example.com', 'recipient@example.com', datetime('now'), '', 0, 0, 0, 99, '', '', 0, 0)
                """, arguments: [id, folderId, accountId, folderPath, messageId])
        }
        return id
    }

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
                VALUES ('acc1:INBOX:1', '', 'acc1', 'INBOX', 1, '1', 'Test', 'sender@example.com', 'sender@example.com', 'recipient@example.com', datetime('now'), '', 0, 0, 0, 99, '', '', 0, 0)
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

    @Test("v70: v62 composite replaces the v21 unread-count index")
    func v70UnreadCountIndexReplacement() throws {
        let db = try TestDatabase.make()
        try db.read { db in
            let indexes = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='messageHeader'")
            let names = indexes.map { $0["name"] as String }
            #expect(names.contains("messageHeader_folderId_isRead_date"))
            #expect(!names.contains("messageHeader_folderId_isRead"))
        }
    }

    @Test("v70 upgrades the released full UID and unread indexes")
    func v70ReleasedIndexUpgrade() throws {
        let db = try TestDatabase.make()

        // Reconstruct the relevant v69-applied index state. Removing v70 from
        // GRDB's migration ledger makes runMigrations exercise the real forward
        // corrective migration instead of only validating a fresh database.
        try db.write { db in
            try db.execute(sql: "DROP INDEX messageHeader_folderId_numericUid")
            try db.execute(sql: "CREATE INDEX messageHeader_folderId_uidInt ON messageHeader(folderId, CAST(messageId AS INTEGER))")
            try db.execute(sql: "CREATE INDEX messageHeader_folderId_isRead ON messageHeader(folderId, isRead)")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: ["v70_trimMessageHeaderIndexes"]
            )
        }

        try AppDatabase.runMigrations(on: db)

        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA index_list(messageHeader)")
            let names = Set(rows.map { $0["name"] as String })
            #expect(names.contains("messageHeader_folderId_numericUid"))
            #expect(!names.contains("messageHeader_folderId_uidInt"))
            #expect(!names.contains("messageHeader_folderId_isRead"))

            let partial = try Int.fetchOne(db, sql: """
                SELECT partial FROM pragma_index_list('messageHeader')
                WHERE name = 'messageHeader_folderId_numericUid'
                """)
            #expect(partial == 1)
        }
    }

    @Test("v71 upgrades legacy label collisions to account-scoped identity")
    func v71AccountScopedLabelUpgrade() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)

        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: "v70_trimMessageHeaderIndexes")

        try TestDatabase.insertAccount(
            db,
            id: "account-a",
            email: "account-a@example.com"
        )
        try TestDatabase.insertAccount(
            db,
            id: "account-b",
            email: "account-b@example.com"
        )
        try TestDatabase.insertFolder(db, accountId: "account-a")
        try TestDatabase.insertFolder(db, accountId: "account-b")
        // NOT `TestDatabase.insertMessageHeader` here: that helper inserts via the
        // CURRENT `MessageHeader` model (every column, including v72's
        // `actionTagSetAt`), but this DB is deliberately migrated only up to v70 —
        // one migration short of v72 — to reconstruct the exact pre-v71 state.
        // Raw SQL with the v70-era column list keeps this test independent of
        // schema columns added by any migration after v70.
        let messageAId = try insertLegacyMessageHeader(
            db, messageId: "message-a", folderId: "account-a:INBOX", accountId: "account-a"
        )
        let messageBId = try insertLegacyMessageHeader(
            db, messageId: "message-b", folderId: "account-b:INBOX", accountId: "account-b"
        )

        // v70 had one global label parent. Account B's provider-local ID
        // therefore pointed at account A's surviving parent metadata.
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO userLabel (id, accountId, name, isSystem)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: ["Label_42", "account-a", "Account A Label", true]
            )
            try db.execute(
                sql: """
                    INSERT INTO messageUserLabel (messageId, userLabelId)
                    VALUES (?, ?), (?, ?)
                """,
                arguments: [
                    messageAId, "Label_42",
                    messageBId, "Label_42",
                ]
            )
        }

        try migrator.migrate(db)

        try db.read { db in
            let labels = try Row.fetchAll(
                db,
                sql: """
                    SELECT accountId, id, name, isSystem
                    FROM userLabel
                    ORDER BY accountId
                """
            )
            #expect(labels.count == 2)
            guard labels.count == 2 else { return }
            #expect(labels[0]["accountId"] as String == "account-a")
            #expect(labels[0]["id"] as String == "Label_42")
            #expect(labels[0]["name"] as String == "Account A Label")
            #expect(labels[0]["isSystem"] as Bool)
            #expect(labels[1]["accountId"] as String == "account-b")
            #expect(labels[1]["id"] as String == "Label_42")
            #expect(labels[1]["name"] as String == "Label_42")
            #expect(!(labels[1]["isSystem"] as Bool))

            let memberships = try Row.fetchAll(
                db,
                sql: """
                    SELECT messageId, accountId, userLabelId
                    FROM messageUserLabel
                    ORDER BY accountId
                """
            )
            #expect(memberships.count == 2)
            guard memberships.count == 2 else { return }
            #expect(memberships[0]["messageId"] as String == messageAId)
            #expect(memberships[0]["accountId"] as String == "account-a")
            #expect(memberships[0]["userLabelId"] as String == "Label_42")
            #expect(memberships[1]["messageId"] as String == messageBId)
            #expect(memberships[1]["accountId"] as String == "account-b")
            #expect(memberships[1]["userLabelId"] as String == "Label_42")

            let labelColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(userLabel)")
            let labelPrimaryKey = Dictionary(uniqueKeysWithValues: labelColumns.map {
                ($0["name"] as String, $0["pk"] as Int)
            })
            #expect(labelPrimaryKey["accountId"] == 1)
            #expect(labelPrimaryKey["id"] == 2)

            let membershipColumns = try Row.fetchAll(
                db,
                sql: "PRAGMA table_info(messageUserLabel)"
            )
            let membershipPrimaryKey = Dictionary(uniqueKeysWithValues: membershipColumns.map {
                ($0["name"] as String, $0["pk"] as Int)
            })
            #expect(membershipPrimaryKey["messageId"] == 1)
            #expect(membershipPrimaryKey["accountId"] == 0)
            #expect(membershipPrimaryKey["userLabelId"] == 2)

            let foreignKeys = try Row.fetchAll(
                db,
                sql: "PRAGMA foreign_key_list(messageUserLabel)"
            )
            let labelForeignKeys = foreignKeys.filter {
                $0["table"] as String == "userLabel"
            }
            #expect(labelForeignKeys.count == 2)
            let labelForeignKeyIDs = Set(labelForeignKeys.map { $0["id"] as Int })
            #expect(labelForeignKeyIDs.count == 1)
            let labelForeignKeyColumns = Dictionary(uniqueKeysWithValues: labelForeignKeys.map {
                ($0["from"] as String, $0["to"] as String)
            })
            #expect(labelForeignKeyColumns == [
                "accountId": "accountId",
                "userLabelId": "id",
            ])
            #expect(labelForeignKeys.allSatisfy { ($0["on_delete"] as String) == "CASCADE" })

            let indexNames = Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_index_list('messageUserLabel')"
            ))
            #expect(indexNames.count == 2) // PK autoindex + one composite reverse index
            #expect(indexNames.contains("idx_messageUserLabel_accountId_userLabelId"))
            #expect(!indexNames.contains("idx_messageUserLabel_userLabelId"))
            let replacementIndexColumns = try Row.fetchAll(
                db,
                sql: "PRAGMA index_info(idx_messageUserLabel_accountId_userLabelId)"
            ).sorted { ($0["seqno"] as Int) < ($1["seqno"] as Int) }
            #expect(replacementIndexColumns.count == 2)
            guard replacementIndexColumns.count == 2 else { return }
            #expect(replacementIndexColumns[0]["name"] as String == "accountId")
            #expect(replacementIndexColumns[1]["name"] as String == "userLabelId")

            let foreignKeyViolations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            #expect(foreignKeyViolations.isEmpty)
        }

        try db.write { db in
            try db.execute(
                sql: "DELETE FROM account WHERE id = ?",
                arguments: ["account-a"]
            )
        }

        try db.read { db in
            let remainingLabels = try Row.fetchAll(
                db,
                sql: "SELECT accountId, id, name FROM userLabel"
            )
            #expect(remainingLabels.count == 1)
            guard remainingLabels.count == 1 else { return }
            #expect(remainingLabels[0]["accountId"] as String == "account-b")
            #expect(remainingLabels[0]["id"] as String == "Label_42")
            #expect(remainingLabels[0]["name"] as String == "Label_42")

            let remainingMemberships = try Row.fetchAll(
                db,
                sql: "SELECT messageId, accountId, userLabelId FROM messageUserLabel"
            )
            #expect(remainingMemberships.count == 1)
            guard remainingMemberships.count == 1 else { return }
            #expect(remainingMemberships[0]["messageId"] as String == messageBId)
            #expect(remainingMemberships[0]["accountId"] as String == "account-b")
            #expect(remainingMemberships[0]["userLabelId"] as String == "Label_42")
        }
    }

    @Test("v67: released UID retry column remains inert and model-compatible")
    func v67UidResolutionRetryCount() throws {
        let db = try TestDatabase.make()
        try db.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(pendingOperation)")
            let names = columns.map { $0["name"] as String }
            #expect(names.contains("uidResolutionRetryCount"))
        }
        // Released v67 made the column NOT NULL with a default. A current-model
        // insert that omits this now-inert compatibility column must still work.
        try TestDatabase.insertAccount(db)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO pendingOperation (id, type, messageIdsJSON, accountId, folderPath, createdAt, status, retryCount)
                VALUES ('op1', 'markRead', '["msg-1"]', 'acc1', 'INBOX', datetime('now'), 'queued', 0)
                """)
        }
        let defaultValue = try db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT uidResolutionRetryCount FROM pendingOperation WHERE id = ?",
                arguments: ["op1"]
            )
        }
        #expect(defaultValue == 0)

        // Released databases may already contain a non-zero historical value.
        // The current model must decode/save without owning or overwriting it.
        try db.write { db in
            try db.execute(
                sql: "UPDATE pendingOperation SET uidResolutionRetryCount = 7 WHERE id = ?",
                arguments: ["op1"]
            )
        }
        var fetched = try #require(try db.read { db in
            try PendingOperation.fetchOne(db, key: "op1")
        })
        fetched.retryCount = 2
        try db.write { try fetched.save($0) }

        let preservedValue = try db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT uidResolutionRetryCount FROM pendingOperation WHERE id = ?",
                arguments: ["op1"]
            )
        }
        #expect(preservedValue == 7)
        #expect(try db.read { db in
            try PendingOperation.fetchOne(db, key: "op1")?.retryCount
        } == 2)
    }

    @Test("v69: pending FTS recovery uses a sparse id-ordered index")
    func v69PendingFTSRecoveryIndex() throws {
        let db = try TestDatabase.make()

        try db.read { db in
            let indexes = try Row.fetchAll(
                db,
                sql: "PRAGMA index_list(messageHeader)"
            )
            let pendingIndex = try #require(indexes.first {
                ($0["name"] as String) == "messageHeader_pendingFTSRekeys"
            })
            #expect((pendingIndex["partial"] as Int) == 1)

            let plan = try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT id FROM messageHeader
                    WHERE pendingFTSRekeySourceIdsJSON IS NOT NULL AND id > ?
                    ORDER BY id
                    LIMIT ?
                """,
                arguments: ["", SyncConfig.ftsIndexBatchSize]
            )
            let details = plan.map { $0["detail"] as String }
            #expect(details.contains {
                $0.contains("USING INDEX messageHeader_pendingFTSRekeys")
            })
        }
    }

    @Test("v68/v69: fresh database omits the deleted queue-only undoToken/queueParentRowId columns, keeps the FTS rekey column/index")
    func v68v69FreshSchemaOmitsQueueOnlyColumns() throws {
        let db = try TestDatabase.make()
        try db.read { db in
            let pendingOperationColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(pendingOperation)")
            let pendingOperationNames = pendingOperationColumns.map { $0["name"] as String }
            #expect(!pendingOperationNames.contains("undoToken"))
            #expect(!pendingOperationNames.contains("queueParentRowId"))

            let messageHeaderColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(messageHeader)")
            let messageHeaderNames = messageHeaderColumns.map { $0["name"] as String }
            #expect(messageHeaderNames.contains("pendingFTSRekeySourceIdsJSON"))

            let indexNames = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='messageHeader'"
            )
            #expect(indexNames.contains("messageHeader_pendingFTSRekeys"))
        }
    }

    @Test("v68/v69: a database that already ran the old queue-recovery bodies migrates to head and keeps decoding PendingOperation")
    func v68v69UpgradeFromLegacyQueueRecoverySchema() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)

        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: "v67_addUidResolutionRetryCount")

        // Reconstruct exactly what the OLD (pre-Round-F) v68/v69 migration
        // bodies created on a development database, then mark those two
        // identifiers applied directly in grdb_migrations. GRDB's
        // DatabaseMigrator never re-runs an applied identifier's body
        // (`unappliedExecutions` maps an applied, non-merged identifier to
        // `nil` — see DatabaseMigrator.swift), so migrating this database to
        // head below exercises the CURRENT (trimmed) v68/v69 bodies being
        // skipped entirely — the same shape a real developer's
        // already-migrated database is in today.
        try db.write { db in
            try db.execute(sql: "ALTER TABLE pendingOperation ADD COLUMN undoToken TEXT")
            try db.execute(sql: "ALTER TABLE pendingOperation ADD COLUMN queueParentRowId INTEGER")
            try db.execute(sql: "ALTER TABLE messageHeader ADD COLUMN pendingFTSRekeySourceIdsJSON TEXT")
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS messageHeader_pendingFTSRekeys
                ON messageHeader(id)
                WHERE pendingFTSRekeySourceIdsJSON IS NOT NULL
                """)
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?), (?)",
                arguments: ["v68_addUndoToken", "v69_addMoveRecoveryAndFTSRekey"]
            )
        }

        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // A row written under the pre-Round-F model, with both legacy columns
        // populated — simulates a real pre-existing queue row on a dev machine.
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO pendingOperation (id, type, messageIdsJSON, accountId, folderPath, createdAt, status, retryCount, undoToken, queueParentRowId, uidResolutionRetryCount)
                VALUES ('legacy-op', 'markRead', '["msg-1"]', 'acc1', 'INBOX', datetime('now'), 'queued', 0, 'legacy-token', 42, 0)
                """)
        }

        try migrator.migrate(db)

        try db.read { db in
            let pendingOperationColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(pendingOperation)")
            let pendingOperationNames = pendingOperationColumns.map { $0["name"] as String }
            #expect(pendingOperationNames.contains("undoToken"))
            #expect(pendingOperationNames.contains("queueParentRowId"))

            let messageHeaderColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(messageHeader)")
            #expect(messageHeaderColumns.map { $0["name"] as String }.contains("pendingFTSRekeySourceIdsJSON"))
        }

        // The current model decodes the row fine — GRDB's synthesized Decodable
        // init only asks for the columns PendingOperation still declares, so the
        // two inert legacy columns are never queried and never cause an error.
        var fetched = try #require(try db.read { db in
            try PendingOperation.fetchOne(db, key: "legacy-op")
        })
        fetched.retryCount = 3
        try db.write { try fetched.save($0) }

        let stillLegacy = try db.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT undoToken, queueParentRowId FROM pendingOperation WHERE id = ?",
                arguments: ["legacy-op"]
            )
        }
        #expect((stillLegacy?["undoToken"] as String?) == "legacy-token")
        #expect((stillLegacy?["queueParentRowId"] as Int?) == 42)
        #expect(try db.read { db in
            try PendingOperation.fetchOne(db, key: "legacy-op")?.retryCount
        } == 3)
    }

    @Test("v72: backfills actionTagSetAt for pre-migration tagged rows, leaves untagged rows NULL")
    func v72BackfillsActionTagSetAtForTaggedRows() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)

        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: "v71_accountScopeUserLabels")

        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Pre-v72 schema has no actionTagSetAt column yet — insert raw rows
        // using only the columns that exist at v71, mirroring how a released
        // database would actually look going into the upgrade.
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO messageHeader (
                    id, folderId, accountId, folderPath, isInInbox, messageId, subject,
                    "from", fromAddress, "to", date, snippet, isRead, isFlagged,
                    hasAttachments, tagSortOrder, actionTag, cc, bcc, isReplied, isForwarded
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "acc1:INBOX:tagged", "acc1:INBOX", "acc1", "INBOX", true, "tagged", "Tagged Subject",
                    "Sender", "sender@example.com", "recipient@example.com", Date(), "snippet", false, false,
                    false, ActionTag.archive.sortOrder, ActionTag.archive.rawValue, "", "", false, false,
                ])
            try dbConn.execute(sql: """
                INSERT INTO messageHeader (
                    id, folderId, accountId, folderPath, isInInbox, messageId, subject,
                    "from", fromAddress, "to", date, snippet, isRead, isFlagged,
                    hasAttachments, tagSortOrder, actionTag, cc, bcc, isReplied, isForwarded
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "acc1:INBOX:untagged", "acc1:INBOX", "acc1", "INBOX", true, "untagged", "Untagged Subject",
                    "Sender", "sender@example.com", "recipient@example.com", Date(), "snippet", false, false,
                    false, 99, nil, "", "", false, false,
                ])
        }

        try migrator.migrate(db)

        try db.read { db in
            let taggedRow = try MessageHeader.fetchOne(db, key: "acc1:INBOX:tagged")
            let untaggedRow = try MessageHeader.fetchOne(db, key: "acc1:INBOX:untagged")
            #expect(taggedRow?.actionTag == .archive)
            #expect(taggedRow?.actionTagSetAt != nil)
            #expect(untaggedRow?.actionTag == nil)
            #expect(untaggedRow?.actionTagSetAt == nil)
        }
    }

    @Test("v72: fresh install (no pre-existing rows) has the actionTagSetAt column ready for immediate use")
    func v72FreshInstallHasActionTagSetAtColumn() throws {
        // No separate "create current schema directly" path exists in this
        // codebase (verified: `registerAllMigrations` is the only schema
        // builder, used identically by fresh installs and upgrades) — so the
        // "fresh schema" equivalent of the v72 backfill is simply: a brand
        // new TestDatabase.make() run (v1...v72 in sequence) has the column
        // and it round-trips normally through the model.
        let db = try TestDatabase.make()
        try db.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(messageHeader)")
            let names = columns.map { $0["name"] as String }
            #expect(names.contains("actionTagSetAt"))
        }
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let stamp = Date()
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "fresh1", actionTag: .reply, actionTagSetAt: stamp
        )
        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.actionTag == .reply)
        #expect(fetched?.actionTagSetAt != nil)
    }

}
