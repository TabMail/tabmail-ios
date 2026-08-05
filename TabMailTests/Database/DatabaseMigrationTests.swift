/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// REFACTOR NOTE (PLAN_INTENTION_QUEUE.md): uidResolutionRetryCount is schema/column-level and
// orthogonal to the intent-register refactor — the retry-budget concept is explicitly KEPT
// (plan section 3) regardless of the one-table-vs-two decision (section 5a).

import Testing
import Foundation
import GRDB
@testable import TabMail

private func insertPreV77Header(
    _ db: DatabaseQueue,
    messageId: String,
    accountId: String = "acc1",
    folderPath: String = "INBOX",
    isRead: Bool = false,
    actionTag: ActionTag? = nil
) throws -> String {
    let id = "\(accountId):\(folderPath):\(messageId)"
    try db.write { connection in
        try connection.execute(sql: """
            INSERT INTO messageHeader
                (id, folderId, accountId, folderPath, isInInbox, messageId,
                 subject, `from`, fromAddress, `to`, date, snippet, isRead,
                 actionTag, tagSortOrder)
            VALUES (?, ?, ?, ?, ?, ?, 'subject', 'sender@example.com',
                    'sender@example.com', 'recipient@example.com', 1, 'snippet',
                    ?, ?, ?)
            """, arguments: [
                id, "\(accountId):\(folderPath)", accountId, folderPath,
                folderPath == "INBOX", messageId, isRead,
                actionTag?.rawValue, actionTag?.sortOrder ?? 99,
            ])
    }
    return id
}

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

    // MARK: - v70 — dropping the messageBody → messageHeader cascade

    /// A database migrated only as far as `v69`, i.e. the exact schema every device
    /// arrives at `v70` on.
    private static func makeV69Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: "v69_addPendingOperationObservedUidValidity")
        return db
    }

    private static func makeDatabase(upTo migration: String) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: migration)
        return db
    }

    private static func migrate(_ db: DatabaseQueue, upTo migration: String) throws {
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: migration)
    }

    private static func insertRawDraft(
        _ db: DatabaseQueue,
        id: String,
        accountId: String,
        subject: String = "subject",
        body: String = "body",
        serverDraftId: String? = "42",
        serverPushStatus: String? = "pushed",
        uidValidity: Int? = 7
    ) throws {
        try db.write { connection in
            try connection.execute(sql: """
                INSERT INTO draft
                    (id, accountId, toJSON, ccJSON, bccJSON, subject, body,
                     replyToId, isForward, editHistoryJSON, createdAt, updatedAt,
                     serverDraftId, serverPushStatus, rfc822MessageId,
                     attachmentsDirName, serverDraftUidValidity)
                VALUES (?, ?, '[\"to@example.com\"]', '[\"cc@example.com\"]', '[]', ?, ?,
                        NULL, 0, '[{\"edit\":\"keep\"}]', 1, 2, ?, ?,
                        'draft@example.com', 'attachments-keep', ?)
                """, arguments: [
                    id, accountId, subject, body, serverDraftId,
                    serverPushStatus, uidValidity,
                ])
        }
    }

    private static func insertRawOutbox(
        _ db: DatabaseQueue,
        id: String,
        accountId: String,
        draftId: String? = nil
    ) throws {
        try db.write { connection in
            try connection.execute(sql: """
                INSERT INTO outboxMessage
                    (id, accountId, toJSON, ccJSON, bccJSON, subject, body,
                     createdAt, draftId, serverDraftId, draftRfc822MessageId,
                     draftServerUidValidity)
                VALUES (?, ?, '[\"to@example.com\"]', '[]', '[]', 'outbox subject',
                        'outbox body', datetime('now'), ?, 'resource-1',
                        'draft@example.com', 7)
                """, arguments: [id, accountId, draftId])
        }
    }

    private static func insertRawPendingOperation(
        _ db: DatabaseQueue,
        id: String,
        accountId: String,
        type: String = OperationType.deleteDraft.rawValue
    ) throws {
        try db.write { connection in
            try connection.execute(sql: """
                INSERT INTO pendingOperation
                    (id, type, messageIdsJSON, accountId, folderPath, createdAt)
                VALUES (?, ?, '[\"42\"]', ?, 'DRAFT', datetime('now'))
                """, arguments: [id, type, accountId])
        }
    }

    /// One line per column — `name|type|notnull|dflt|pk`, in declaration order.
    /// Compared as a whole so a reordered, retyped, renamed or dropped column all
    /// fail the same way.
    private static func columnShape(_ db: DatabaseQueue, _ table: String) throws -> [String] {
        try db.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA table_info(\(table))").map {
                let dflt = ($0["dflt_value"] as String?) ?? "∅"
                return "\($0["name"] as String)|\($0["type"] as String)|\($0["notnull"] as Int)|\(dflt)|\($0["pk"] as Int)"
            }
        }
    }

    /// Every index SQLite knows for a table, **including the implicit
    /// `sqlite_autoindex` behind a TEXT primary key**, each with its columns.
    ///
    /// `PRAGMA index_list` is used rather than `sqlite_master`, precisely because
    /// `sqlite_master` does NOT carry autoindexes — and the autoindex is the only
    /// index `messageBody` has, so a `sqlite_master`-based check would be vacuous
    /// on today's schema and would not notice the primary key going missing.
    private static func indexShape(_ db: DatabaseQueue, _ table: String) throws -> [String] {
        try db.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA index_list(\(table))").map { idx in
                let name = idx["name"] as String
                let columns = try Row.fetchAll(conn, sql: "PRAGMA index_info(\(name))")
                    .map { ($0["name"] as String?) ?? "<expr>" }
                    .joined(separator: ",")
                // The autoindex's NAME embeds an ordinal that is stable for a given
                // table, so it is safe to compare; `unique`/`origin` pin that a
                // recreated PK is still a UNIQUE index created by a PK constraint.
                return "\(name)|unique=\(idx["unique"] as Int)|origin=\(idx["origin"] as String)|(\(columns))"
            }
        }
    }

    /// 🚨 THE RED PROOF FOR STAGE D, AND ITS GREEN, IN ONE TEST — deliberately, so
    /// neither half can be read without the other.
    ///
    /// On the `v69` schema the FK is live and an rfc-tailed body INSERT (the shape
    /// Stage E1 mints) dies with `FOREIGN KEY constraint failed`; after `v70` the
    /// same INSERT succeeds. Nothing has to move a key to demonstrate it.
    ///
    /// `v70` drops and recreates the table, so the property to pin is not "the rows
    /// survived" — they deliberately do not — but **"the table that comes back is
    /// the same table minus the constraint"**. Column shape and index shape are
    /// therefore captured from the real v69 schema and compared whole.
    @Test("v70: the FK is live at v69 and gone at v70, with the table's shape intact")
    func v70DropsTheForeignKeyAndPreservesTheTableShape() throws {
        let db = try Self.makeV69Database()

        // PRE-CONDITION: the FK really is there, and really is enforced.
        try db.read { conn in
            let fks = try Row.fetchAll(conn, sql: #"PRAGMA foreign_key_list("messageBody")"#)
            #expect(fks.count == 1, "precondition: v69 declares exactly one messageBody FK")
        }
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var rejected = false
        do {
            try db.write { conn in
                try conn.execute(
                    sql: "INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText) VALUES (?, ?, ?, ?, ?)",
                    arguments: ["acc1:INBOX:rfc-tail@example.com", "<p>rfc</p>", nil, Date(), nil])
            }
        } catch {
            rejected = true
        }
        #expect(rejected,
                "RED PROOF: on the pre-v70 schema an rfc-tailed body INSERT must be rejected by the FK")

        let columnsBefore = try Self.columnShape(db, "messageBody")
        let indexesBefore = try Self.indexShape(db, "messageBody")
        #expect(!columnsBefore.isEmpty, "non-vacuity: the v69 shape must have been read")
        #expect(!indexesBefore.isEmpty,
                "non-vacuity: v69's messageBody must report at least the primary-key autoindex")

        try AppDatabase.runMigrations(on: db)

        // POST-CONDITION 1: the constraint is gone and the database is clean.
        let (fkRows, integrity, fkViolations) = try db.read { conn in
            (try Row.fetchAll(conn, sql: #"PRAGMA foreign_key_list("messageBody")"#),
             try String.fetchOne(conn, sql: "PRAGMA integrity_check"),
             try Row.fetchAll(conn, sql: "PRAGMA foreign_key_check"))
        }
        #expect(fkRows.isEmpty)
        #expect(integrity == "ok")
        #expect(fkViolations.isEmpty)

        // POST-CONDITION 2: same columns, same order, same types, same nullability,
        // same defaults, same primary key.
        #expect(try Self.columnShape(db, "messageBody") == columnsBefore)

        // POST-CONDITION 3: GREEN — the insert the FK used to reject now succeeds,
        // with foreign keys still enforced on the connection.
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try db.write { conn in
            try conn.execute(
                sql: "INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText) VALUES (?, ?, ?, ?, ?)",
                arguments: ["acc1:INBOX:rfc-tail@example.com", "<p>rfc</p>", nil, Date(), nil])
        }
        #expect(try db.read {
            try MessageBody.fetchOne($0, key: "acc1:INBOX:rfc-tail@example.com")
        }?.htmlContent == "<p>rfc</p>")

        // POST-CONDITION 4: and the cascade genuinely stopped firing — a body stored
        // under a live header's id survives that header's deletion.
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")
        try db.write { _ = try MessageHeader.deleteOne($0, key: "acc1:INBOX:1") }
        #expect(try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:1") } != nil,
                "no header-space cascade may reach a content row any more")
    }

    /// The table comes back with EVERY index it had — stated as "the index shape is
    /// unchanged", not "the autoindex is present".
    ///
    /// `messageBody` carries no NAMED index on any schema up to v69, so today this
    /// pins the primary key. Its real job is the future: if a migration numbered
    /// below 70 ever adds an index to this table, `v70`'s `CREATE TABLE` will not
    /// reproduce it and this test goes red — which is the only signal that would
    /// otherwise be missing, because a silently missing index degrades performance
    /// without ever failing a query.
    @Test("v70: the recreated messageBody carries every index the dropped one had")
    func v70RecreatesEveryIndex() throws {
        let db = try Self.makeV69Database()
        let before = try Self.indexShape(db, "messageBody")
        #expect(!before.isEmpty, "non-vacuity: v69 must report at least one index")

        try AppDatabase.runMigrations(on: db)

        let after = try Self.indexShape(db, "messageBody")
        #expect(after == before,
                "v70 must recreate every index messageBody had at v69 — got \(after), expected \(before)")
    }

    /// 🚨 THE BLAST RADIUS. `v70` discards the body CACHE — that is the accepted
    /// cost — and must touch **nothing else**.
    ///
    /// Two-sided by construction: the cache must be EMPTY (so a migration that
    /// quietly kept the table would fail), and every other store must be
    /// BYTE-IDENTICAL (so a migration that wiped more than the cache would fail).
    @Test("v70: the body cache is discarded and nothing else in the database is")
    func v70DiscardsOnlyTheBodyCache() throws {
        let db = try Self.makeV69Database()
        try TestDatabase.insertAccount(db, id: "acc1", email: "one@example.com")
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertAccount(db, id: "acc2", email: "two@example.com")
        try TestDatabase.insertFolder(db, accountId: "acc2")

        let readId = try insertPreV77Header(db, messageId: "1", isRead: true, actionTag: .reply)
        _ = try insertPreV77Header(db, messageId: "2")
        _ = try insertPreV77Header(db, messageId: "9", accountId: "acc2")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:2")
        try TestDatabase.insertMessageBody(db, headerId: "acc2:INBOX:9")

        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO messageAICache (key, summaryBlurb, updatedAt) VALUES (?, ?, ?)
                """, arguments: ["acc1:INBOX:1", "a summary", Date()])
            try conn.execute(sql: """
                INSERT INTO pendingOperation
                    (id, type, messageIdsJSON, accountId, folderPath, createdAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: ["op1", "archive", "[\"1\"]", "acc1", "INBOX", Date()])
        }

        let headersBefore = try db.read { conn in
            try Row.fetchAll(conn, sql: "SELECT * FROM messageHeader ORDER BY id").map(\.description)
        }
        let foldersBefore = try db.read { conn in
            try Row.fetchAll(conn, sql: "SELECT * FROM folder ORDER BY id").map(\.description)
        }
        #expect(headersBefore.count == 3)
        #expect(foldersBefore.count == 2)

        try Self.migrate(db, upTo: "v70_dropMessageBodyHeaderFK")

        // The cache is gone — the accepted cost, asserted so it cannot silently
        // stop being what this migration does.
        #expect(try db.read { try MessageBody.fetchCount($0) } == 0,
                "v70 discards the re-fetchable body cache")
        // …and it is the ONLY thing gone.
        #expect(try db.read { conn in
            try Row.fetchAll(conn, sql: "SELECT * FROM messageHeader ORDER BY id").map(\.description)
        } == headersBefore, "no messageHeader row or column may change")
        #expect(try db.read { conn in
            try Row.fetchAll(conn, sql: "SELECT * FROM folder ORDER BY id").map(\.description)
        } == foldersBefore, "no folder row may change")
        #expect(try db.read { try Account.fetchCount($0) } == 2)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageAICache") } == 1)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pendingOperation") } == 1)
        // Flags survive verbatim, including the AI tag — a body-cache drop is not a
        // reason to lose a message's triage state.
        let after = try db.read { try MessageHeader.fetchOne($0, key: readId) }
        #expect(after?.isRead == true)
        #expect(after?.actionTag == .reply)
    }

    /// 🚨 THE INVARIANT `v70` IS BOUND BY, PINNED WHERE IT CAN REGRESS.
    ///
    /// `BodyAssetMaintenance`'s type-level INVARIANT (2026-07-02): discarding a
    /// cached body NEVER touches `bodyComplete`. That flag is the FTS-indexed truth
    /// (backfill completion / `pendingBodyCount` / AI + embedding gating), not an
    /// assertion that a cached row exists. Flipping it re-enqueues every victim into
    /// the backfill body queue, which re-fetches, which re-fills the cache past its
    /// cap, which evicts again — the "indexing goes backwards" infinite refetch
    /// loop, and at `v70`'s scale that is EVERY message on the device.
    ///
    /// `bodyEmptyConfirmed` likewise stays: "the server confirmed this message has
    /// no body" is a fact about the SERVER, which discarding a local cache cannot
    /// falsify. Clearing it would re-queue every genuinely-empty message forever.
    @Test("v70 discards bodies without touching bodyComplete or bodyEmptyConfirmed")
    func v70LeavesBodyFetchFlagsAlone() throws {
        let db = try Self.makeV69Database()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        _ = try insertPreV77Header(db, messageId: "1")
        _ = try insertPreV77Header(db, messageId: "2")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")
        try db.write { conn in
            try conn.execute(sql: """
                UPDATE messageHeader SET bodyComplete = 1 WHERE id = 'acc1:INBOX:1'
                """)
            try conn.execute(sql: """
                UPDATE messageHeader SET bodyEmptyConfirmed = 1, emptyFetchCount = 3
                WHERE id = 'acc1:INBOX:2'
                """)
        }

        try AppDatabase.runMigrations(on: db)

        #expect(try db.read { try MessageBody.fetchCount($0) } == 0, "precondition: the cache was discarded")
        let flags = try db.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT id, bodyComplete, bodyEmptyConfirmed, emptyFetchCount
                FROM messageHeader ORDER BY id
                """)
        }
        #expect(flags.count == 2)
        guard flags.count == 2 else { return }
        #expect(flags[0]["bodyComplete"] as Bool == true,
                "a body that WAS validly fetched keeps bodyComplete — resetting it is the infinite-refetch bug")
        #expect(flags[1]["bodyEmptyConfirmed"] as Bool == true,
                "a server-confirmed-empty body stays confirmed — the server's answer is not local cache")
        #expect(flags[1]["emptyFetchCount"] as Int == 3)
    }

    /// Re-running the migrator must not re-drop the cache the app has refilled
    /// since. Stated as the END STATE a user would notice — "the bodies I have are
    /// still here" — rather than "the migration is registered once", because the
    /// second is a property of GRDB and the first is the property that matters.
    @Test("v70: a second migration pass does not re-drop bodies written after it")
    func v70DoesNotReRunAndDiscardRefilledBodies() throws {
        let db = try Self.makeV69Database()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        _ = try insertPreV77Header(db, messageId: "1")

        try AppDatabase.runMigrations(on: db)
        #expect(try db.read { try MessageBody.fetchCount($0) } == 0)

        // The cache refills, exactly as the backfill queue and the detail view do.
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1", htmlContent: "<p>refilled</p>")

        try AppDatabase.runMigrations(on: db)
        try AppDatabase.runMigrations(on: db)

        let survivor = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(survivor?.htmlContent == "<p>refilled</p>",
                "re-running migrations must never discard a refilled cache")
        let fks = try db.read { conn in
            try Row.fetchAll(conn, sql: #"PRAGMA foreign_key_list("messageBody")"#)
        }
        #expect(fks.isEmpty)
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

    @Test("v67: pendingOperation has uidResolutionRetryCount column, defaulting to 0")
    func v67UidResolutionRetryCount() throws {
        let db = try TestDatabase.make()
        try db.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(pendingOperation)")
            let names = columns.map { $0["name"] as String }
            #expect(names.contains("uidResolutionRetryCount"))
        }
        // A row inserted via raw SQL that omits the column (mirrors the explicit-
        // column INSERTs in AppDelegate.swift/NSEDataBridge.swift) must default to 0.
        try TestDatabase.insertAccount(db)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO pendingOperation (id, type, messageIdsJSON, accountId, folderPath, createdAt, status, retryCount)
                VALUES ('op1', 'markRead', '["msg-1"]', 'acc1', 'INBOX', datetime('now'), 'queued', 0)
                """)
        }
        let fetched = try db.read { db in try PendingOperation.fetchOne(db, key: "op1") }
        #expect(fetched?.uidResolutionRetryCount == 0)
    }

    @Test("v73 clears legacy IMAP addresses while preserving authored Draft content")
    func v73ClearsOnlyLegacyImapAddresses() throws {
        let db = try Self.makeDatabase(upTo: "v72_addDraftServerUidValidity")
        try TestDatabase.insertAccount(db, id: "imap-account", provider: .imap)
        try TestDatabase.insertAccount(db, id: "icloud-account", provider: .icloud)
        try TestDatabase.insertAccount(db, id: "gmail-account", provider: .gmail)
        try Self.insertRawDraft(
            db, id: "imap-draft", accountId: "imap-account",
            subject: "keep imap subject", body: "keep imap body")
        try Self.insertRawDraft(
            db, id: "icloud-draft", accountId: "icloud-account",
            subject: "keep icloud subject", body: "keep icloud body")
        try Self.insertRawDraft(
            db, id: "gmail-draft", accountId: "gmail-account",
            subject: "keep gmail subject", body: "keep gmail body",
            serverDraftId: "gmail-resource", uidValidity: nil)

        try Self.migrate(db, upTo: "v73_bindDraftUidToMailbox")

        let rows = try db.read { connection in
            try Row.fetchAll(connection, sql: """
                SELECT id, subject, body, toJSON, ccJSON, editHistoryJSON,
                       attachmentsDirName, serverDraftId, serverPushStatus,
                       serverDraftUidValidity, serverDraftFolderPath
                FROM draft ORDER BY id
                """)
        }
        #expect(rows.count == 3)
        guard rows.count == 3 else { return }
        for row in rows where (row["id"] as String) != "gmail-draft" {
            #expect((row["serverDraftId"] as String?) == nil)
            #expect((row["serverPushStatus"] as String?) == nil)
            #expect((row["serverDraftUidValidity"] as Int?) == nil)
            #expect((row["serverDraftFolderPath"] as String?) == nil)
            #expect((row["body"] as String).hasPrefix("keep "))
            #expect((row["toJSON"] as String) == "[\"to@example.com\"]")
            #expect((row["ccJSON"] as String) == "[\"cc@example.com\"]")
            #expect((row["editHistoryJSON"] as String?) != nil)
            #expect((row["attachmentsDirName"] as String?) == "attachments-keep")
        }
        let gmail = try #require(rows.first { ($0["id"] as String) == "gmail-draft" })
        #expect((gmail["serverDraftId"] as String?) == "gmail-resource")
        #expect((gmail["serverPushStatus"] as String?) == "pushed")
        #expect((gmail["body"] as String) == "keep gmail body")
    }

    @Test("v74 purges only pending operations and preserves Draft and Outbox rows")
    func v74PurgesOnlyPendingOperations() throws {
        let db = try Self.makeDatabase(upTo: "v73_bindDraftUidToMailbox")
        try TestDatabase.insertAccount(db, id: "acc1", provider: .gmail)
        try Self.insertRawDraft(
            db, id: "draft-keep", accountId: "acc1", body: "authored draft body",
            serverDraftId: "gmail-resource", uidValidity: nil)
        try Self.insertRawOutbox(db, id: "outbox-keep", accountId: "acc1", draftId: "draft-keep")
        try Self.insertRawPendingOperation(db, id: "op-delete", accountId: "acc1")
        try Self.insertRawPendingOperation(
            db, id: "op-read", accountId: "acc1", type: OperationType.markRead.rawValue)

        try Self.migrate(db, upTo: "v74_purgeLegacyPendingOperations")

        try db.read { connection in
            let pendingOperationCount = try Int.fetchOne(
                connection, sql: "SELECT COUNT(*) FROM pendingOperation")
            let draftBody = try String.fetchOne(
                connection, sql: "SELECT body FROM draft WHERE id = 'draft-keep'")
            let outboxBody = try String.fetchOne(
                connection, sql: "SELECT body FROM outboxMessage WHERE id = 'outbox-keep'")
            #expect(pendingOperationCount == 0)
            #expect(draftBody == "authored draft body")
            #expect(outboxBody == "outbox body")
        }
    }

    @Test("v75-v76 raw upgrade seeds pushAttemptVersion zero and adds nullable typed authority without backfill")
    func v75V76UpgradeAddsUnbackfilledGenerationAuthority() throws {
        let db = try Self.makeDatabase(upTo: "v74_purgeLegacyPendingOperations")
        try TestDatabase.insertAccount(db, id: "acc1", provider: .gmail)
        try Self.insertRawDraft(db, id: "draft-existing", accountId: "acc1")
        try Self.insertRawOutbox(db, id: "outbox-existing", accountId: "acc1", draftId: "draft-existing")
        try Self.insertRawPendingOperation(db, id: "op-existing", accountId: "acc1")

        try Self.migrate(db, upTo: "v76_addDraftGenerationAndTypedIdentity")

        try db.read { connection in
            let fetchedDraftRow = try Row.fetchOne(
                connection,
                sql: "SELECT pushAttemptVersion, instanceEpoch FROM draft WHERE id = 'draft-existing'")
            let fetchedOutboxRow = try Row.fetchOne(
                connection,
                sql: "SELECT instanceEpoch, serverDraftGmailMessageId FROM outboxMessage WHERE id = 'outbox-existing'")
            let fetchedOpRow = try Row.fetchOne(
                connection,
                sql: "SELECT instanceEpoch, draftId, draftDeleteAddressKind FROM pendingOperation WHERE id = 'op-existing'")
            let draftRow = try #require(fetchedDraftRow)
            let outboxRow = try #require(fetchedOutboxRow)
            let opRow = try #require(fetchedOpRow)
            #expect((draftRow["pushAttemptVersion"] as Int) == 0)
            #expect((draftRow["instanceEpoch"] as String?) == nil)
            #expect((outboxRow["instanceEpoch"] as String?) == nil)
            #expect((outboxRow["serverDraftGmailMessageId"] as String?) == nil)
            #expect((opRow["instanceEpoch"] as String?) == nil)
            #expect((opRow["draftId"] as String?) == nil)
            #expect((opRow["draftDeleteAddressKind"] as String?) == nil)
        }
    }

    @Test("v78 conservatively marks every pre-existing pending operation attempted")
    func v78BackfillsExistingOperationsAttemptedAndDefaultsNewRowsFalse() throws {
        let db = try Self.makeDatabase(upTo: "v77_addMessageHeaderObservedUidValidity")
        try TestDatabase.insertAccount(db, id: "acc1", provider: .gmail)
        try Self.insertRawPendingOperation(db, id: "op-existing", accountId: "acc1")

        try Self.migrate(db, upTo: "v78_addPendingOperationEverAttempted")

        let columns = try db.read {
            try Row.fetchAll($0, sql: "PRAGMA table_info(pendingOperation)")
        }
        let column = try #require(columns.first { ($0["name"] as String) == "everAttempted" })
        #expect((column["notnull"] as Int) == 1)
        #expect((column["dflt_value"] as String?) == "0")

        let existing = try db.read {
            try PendingOperation.fetchOne($0, key: "op-existing")
        }
        #expect(existing?.everAttempted == true)

        let fresh = PendingOperation(
            type: .markRead, messageIds: ["msg-new"],
            accountId: "acc1", folderPath: "INBOX")
        try db.write { try fresh.insert($0) }
        let inserted = try db.read { try PendingOperation.fetchOne($0, key: fresh.id) }
        #expect(inserted?.everAttempted == false)
    }

    // MARK: - The migration chain's arrival invariants

    /// The database's whole SHAPE as comparable text, so two databases can be
    /// compared without naming a single column by hand.
    ///
    /// Three layers, because no one of them is sufficient: every `sqlite_master`
    /// entry (tables, indexes, triggers, views — autoindexes appear here with a
    /// NULL `sql`), then each table's `columnShape` (a renamed/retyped/reordered
    /// column that left the CREATE text alone still fails) and `indexShape` (which
    /// reads `PRAGMA index_list`, the only place the implicit primary-key
    /// autoindex is visible at all).
    private static func schemaDump(_ db: DatabaseQueue) throws -> [String] {
        let objects: [String] = try db.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT type, name, tbl_name, COALESCE(sql, '∅') AS sql
                FROM sqlite_master
                ORDER BY type, name, tbl_name
                """).map {
                "\($0["type"] as String)|\($0["name"] as String)|\($0["tbl_name"] as String)|\($0["sql"] as String)"
            }
        }
        let tables: [String] = try db.read { conn in
            try String.fetchAll(
                conn, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        var dump = objects
        for table in tables {
            let columns = try columnShape(db, table).map { "col \(table).\($0)" }
            let indexes = try indexShape(db, table).map { "idx \(table).\($0)" }
            dump.append("── \(table)")
            dump.append(contentsOf: columns)
            dump.append(contentsOf: indexes)
        }
        return dump
    }

    /// GRDB's applied-migrations ledger, read straight out of GRDB's own table
    /// rather than through `DatabaseMigrator` — the point is what is RECORDED,
    /// not what the migrator computes.
    private static func appliedLedger(_ db: DatabaseQueue) throws -> [String] {
        try db.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    /// 🚨 THE INVARIANT EVERY INSTALLED DEVICE DEPENDS ON, ASSERTED AS AN OUTCOME.
    ///
    /// Migrations are IMMUTABLE once applied, and `registerAllMigrations` now
    /// registers all of them through a wrapper — i.e. something in the execution
    /// path around every already-shipped body changed even though no identifier or
    /// SQL did. The property that must survive that is: a database already at the
    /// current version runs **zero** migration bodies on the next launch, and its
    /// schema does not move.
    ///
    /// "Zero bodies ran" is asserted through the two migrations that would leave
    /// FORENSIC EVIDENCE if they re-ran — `v74` (`DELETE FROM pendingOperation`)
    /// and `v78` (`UPDATE pendingOperation SET everAttempted = 1`) — against a
    /// sentinel row inserted AFTER the first pass. "No schema change" is asserted
    /// through the whole schema dump plus `PRAGMA schema_version`, SQLite's own DDL
    /// counter, which any re-run `ALTER`/`CREATE` would move.
    ///
    /// Nothing here inspects the wrapper, a clock, or a log line: a test that
    /// pinned the mechanism would go green on a wrapper that re-ran everything.
    @Test("An already-migrated database runs no migration body on a second pass")
    func alreadyMigratedDatabaseRunsNoMigrationBodyOnASecondPass() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .gmail)
        // Sentinel: v74 would DELETE this row, v78 would flip everAttempted to 1.
        try Self.insertRawPendingOperation(db, id: "op-sentinel", accountId: "acc1")

        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        let registered = migrator.migrations
        let ledgerBefore = try Self.appliedLedger(db)
        // Non-vacuity: the second pass is only a no-op test if the FIRST pass
        // really applied the whole chain.
        #expect(!registered.isEmpty)
        #expect(ledgerBefore == registered.sorted())
        let cookieBeforeValue = try db.read { try Int.fetchOne($0, sql: "PRAGMA schema_version") }
        // `try #require` rather than comparing two optionals: if the pragma stopped
        // being readable, `nil == nil` would pass and assert nothing.
        let schemaCookieBefore = try #require(cookieBeforeValue)
        let schemaBefore = try Self.schemaDump(db)

        try AppDatabase.runMigrations(on: db)

        let cookieAfterValue = try db.read { try Int.fetchOne($0, sql: "PRAGMA schema_version") }
        let schemaCookieAfter = try #require(cookieAfterValue)
        let schemaAfter = try Self.schemaDump(db)
        let ledgerAfter = try Self.appliedLedger(db)
        let sentinelRow = try db.read {
            try Row.fetchOne(
                $0, sql: "SELECT everAttempted FROM pendingOperation WHERE id = 'op-sentinel'")
        }

        #expect(ledgerAfter == ledgerBefore)
        #expect(schemaAfter == schemaBefore)
        #expect(schemaCookieAfter == schemaCookieBefore,
                "no DDL ran, so SQLite's schema cookie must not move")
        let sentinel = try #require(sentinelRow, "v74's DELETE must not have re-run")
        #expect((sentinel["everAttempted"] as Int) == 0,
                "v78's backfill UPDATE must not have re-run")
    }

    /// 🚨 THE TWO WAYS A DEVICE ARRIVES AT THE CURRENT SCHEMA MUST AGREE.
    ///
    /// A NEW install runs the whole chain in one pass; an EXISTING install that
    /// shipped every intermediate release arrives one version at a time. Because
    /// the wrapper is applied to ALL registrations at once, anything it perturbed
    /// — registration order, `v2`'s `foreignKeyChecks: .deferred` mode, the
    /// identifier GRDB records — would show up as these two paths landing on
    /// different schemas. Compared whole: DDL text, column shape and index shape
    /// (autoindexes included) for every table.
    @Test("A fresh database and one upgraded version-by-version reach the same schema")
    func freshAndVersionByVersionUpgradedDatabasesReachTheSameSchema() throws {
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        let identifiers = migrator.migrations
        // Non-vacuity: the stepped path must really have taken many steps.
        #expect(identifiers.count > 1)
        guard identifiers.count > 1 else { return }

        let fresh = try TestDatabase.make()

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let upgraded = try DatabaseQueue(configuration: configuration)
        for identifier in identifiers {
            try migrator.migrate(upgraded, upTo: identifier)
        }

        // Both paths must have recorded the SAME ledger — the identifiers are what
        // GRDB keys on, so a diverging ledger is a diverging schema by definition.
        let expectedLedger = identifiers.sorted()
        let freshLedger = try Self.appliedLedger(fresh)
        let upgradedLedger = try Self.appliedLedger(upgraded)
        #expect(freshLedger == expectedLedger)
        #expect(upgradedLedger == expectedLedger)

        let freshDump = try Self.schemaDump(fresh)
        let upgradedDump = try Self.schemaDump(upgraded)
        // Non-vacuity: an empty dump would make the comparison below trivially true.
        #expect(!freshDump.isEmpty)
        #expect(freshDump == upgradedDump)
    }
}

/// `v70` drops and recreates a table in the MAIN database. The two other stores a
/// message's content lives in — the on-disk `BodyAssetStore` and the separate FTS
/// database — are reached by neither `DROP TABLE` nor `CREATE TABLE`, and both are
/// deliberately left alone. These pin that as an OUTCOME, in the stores themselves,
/// because "the statement doesn't name that file" is an argument, not a test.
@Suite("v70 cross-store invariants", .serialized, .processGlobalState)
struct V70CrossStoreInvariantTests {

    private static func makeV69Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: "v69_addPendingOperationObservedUidValidity")
        return db
    }

    /// Every regular file under the asset container, so "did the store grow?" is
    /// answered from the FILESYSTEM rather than from the manifest that describes it.
    private static func filesOnDisk(_ dir: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .map(\.path)
            .sorted()
    }

    /// 🚨 THE DISK INVARIANT, ASSERTED ON THE DISK.
    ///
    /// `v70` discards the cached HTML that REFERENCES these assets. It must not
    /// leave them dangling and it must not inflate the store — so both halves are
    /// asserted:
    ///
    /// - **Not dangling.** The asset survives with its owner's header untouched, so
    ///   `BodyAssetMaintenance.pruneOrphans` still (correctly) protects it, the
    ///   routed `MessageContentStore.releaseUnowned(… .assets)` sites still reclaim
    ///   it when that header dies, and `evictIfOverCap` still bounds it. Deleting it
    ///   here would destroy a still-owned attachment the user would have to
    ///   re-download.
    /// - **No inflation.** The manifest id is derived — `headerHash(contentKey) /
    ///   assetHash(cid|section)` — and written `ON CONFLICT(id) DO UPDATE`, so the
    ///   re-fetch that repopulates `messageBody` re-attaches the SAME row and the
    ///   SAME file. The file census before and after that re-fetch must be equal;
    ///   a second copy would mean every upgraded device pays double for its cache.
    @Test("v70 leaves cached assets on disk, and a refetch re-attaches them without duplicating")
    func v70LeavesAssetsOnDiskAndARefetchCannotDuplicateThem() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("v70AssetTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BodyAssetStore._setTestEnvironment(containerURL: dir, queue: try BodyAssetStore._makeTestQueue())
        defer {
            BodyAssetStore._resetForTesting()
            try? FileManager.default.removeItem(at: dir)
        }

        let db = try Self.makeV69Database()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        _ = try insertPreV77Header(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")

        let key = ContentKey(rawValue: "acc1:INBOX:1")
        // The message this cached attachment belongs to. Same value on the write and
        // the read: the point of this test is that the SAME message still gets its
        // cache back across the migration, not that any lookup does.
        let v70AttachmentIdentityStamp = "rfc:v70-cached@example.com"
        let pixel = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let inlineId = BodyAssetStore.writeInlineImage(
            contentKey: key, contentId: "cid-1", contentType: "image/png", data: pixel)
        let attachmentId = BodyAssetStore.writeAttachment(
            contentKey: key, section: "2", contentType: "application/pdf", data: pixel,
            identityStamp: v70AttachmentIdentityStamp)
        #expect(inlineId != nil)
        #expect(attachmentId != nil)
        let filesBefore = Self.filesOnDisk(dir)
        #expect(filesBefore.count == 2, "precondition: both assets are on disk")

        try AppDatabase.runMigrations(on: db)

        // The cache this migration discards really was discarded…
        #expect(try db.read { try MessageBody.fetchCount($0) } == 0)
        // …and the assets it referenced are STILL THERE, on disk and in the manifest.
        #expect(Self.filesOnDisk(dir) == filesBefore,
                "v70 must not delete still-owned assets — their headers are untouched")
        #expect(BodyAssetStore.allManifestContentKeys().contains(key))
        #expect(BodyAssetStore.attachmentAssetId(
                    contentKey: key, section: "2",
                    identityStamp: v70AttachmentIdentityStamp) == attachmentId,
                "the cached attachment must still resolve, so the refetch skips the network")
        if let inlineId {
            let url = BodyAssetStore.urlOnDisk(assetId: inlineId)
            #expect(url != nil)
            #expect(try Data(contentsOf: #require(url)) == pixel, "the bytes must be intact, not just the path")
        }

        // THE REFETCH. The backfill queue re-renders the same message and writes the
        // same assets. Deterministic ids ⇒ same rows, same files, no growth.
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1", htmlContent: "<p>refetched</p>")
        let inlineIdAgain = BodyAssetStore.writeInlineImage(
            contentKey: key, contentId: "cid-1", contentType: "image/png", data: pixel)
        let attachmentIdAgain = BodyAssetStore.writeAttachment(
            contentKey: key, section: "2", contentType: "application/pdf", data: pixel,
            identityStamp: v70AttachmentIdentityStamp)
        #expect(inlineIdAgain == inlineId)
        #expect(attachmentIdAgain == attachmentId)
        #expect(Self.filesOnDisk(dir) == filesBefore,
                "a refetch must re-attach the cached assets, never duplicate them")
    }

    /// The FTS index lives in its OWN database file. `message_meta.hasBody` means
    /// "this FTS row carries non-empty indexed body TEXT" — its only writer, ever,
    /// was the one-shot backfill from the retired monolithic `messages_fts` — so it
    /// is not falsified by discarding the main DB's HTML cache, and must not be
    /// reset. The user-visible consequence, and what is asserted here: **search over
    /// body text keeps working across the upgrade**, on messages whose cached HTML
    /// `v70` just threw away.
    @Test("v70 does not disturb the FTS database — body text stays searchable")
    func v70LeavesTheFTSDatabaseAlone() async throws {
        let index = SearchIndex.shared
        let hid = "v70fts_\(UUID().uuidString):INBOX:1"
        let key = ContentKey(rawValue: hid)

        let record = FTSHeaderRecord(
            contentKey: key, headerId: hid, messageId: "m1",
            subject: "Quarterly plan", from: "sender@example.com", to: "recipient@example.com",
            dateMs: 1_700_000_000_000
        )
        #expect(try await index.indexHeaders([record]) == 1)
        try await index.updateBody(contentKey: key, body: "chrysanthemum budget narrative")
        #expect(try await index.bodyText(contentKey: key) == "chrysanthemum budget narrative")

        let db = try Self.makeV69Database()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try AppDatabase.runMigrations(on: db)

        #expect(try await index.bodyText(contentKey: key) == "chrysanthemum budget narrative",
                "the FTS body text is in a separate database and must survive v70 intact")
        let hits = try await index.keywordSearch(query: "chrysanthemum")
        #expect(hits.contains { $0.contentKey == key },
                "search over a body whose HTML cache v70 discarded must still find the message")

        // `SearchIndex.shared` is process-global — the unique key above plus this
        // cleanup keep the suite from leaking rows into its neighbours.
        try await index.removeMessages(contentKeys: [key])
    }

    @Test("v77 adds nullable observedUidValidity without backfilling existing headers")
    func v77AddsNullableObservationEpochWithoutBackfill() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        var beforeMigrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &beforeMigrator)
        try beforeMigrator.migrate(db, upTo: "v76_addDraftGenerationAndTypedIdentity")
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let headerId = "acc1:INBOX:77"
        try db.write { connection in
            try connection.execute(sql: """
                INSERT INTO messageHeader
                    (id, folderId, accountId, folderPath, isInInbox, messageId,
                     subject, `from`, fromAddress, `to`, date, snippet)
                VALUES (?, 'acc1:INBOX', 'acc1', 'INBOX', 1, '77',
                        'subject', 'sender@example.com', 'sender@example.com',
                        'recipient@example.com', 1, 'snippet')
                """, arguments: [headerId])
        }

        var afterMigrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &afterMigrator)
        try afterMigrator.migrate(db, upTo: "v77_addMessageHeaderObservedUidValidity")

        let columns = try db.read { try Row.fetchAll($0, sql: "PRAGMA table_info(messageHeader)") }
        let column = try #require(columns.first { ($0["name"] as String) == "observedUidValidity" })
        #expect((column["notnull"] as Int) == 0)
        let value: Int? = try db.read {
            try Int.fetchOne($0, sql: "SELECT observedUidValidity FROM messageHeader WHERE id = ?", arguments: [headerId])
        }
        #expect(value == nil)
    }

    /// The legacy-row rule for `actionTagSetAt` (2026-08-05): v81 is SCHEMA
    /// ONLY. It adds the column and touches no row, so **every** row that
    /// predates the upgrade emerges with a NULL stamp — including rows that
    /// were already carrying an action tag.
    ///
    /// The state this test pins is not an implementation detail, it is the
    /// input to a behaviour: `SyncEngineMaintenance.sweepStaleActionTags`
    /// treats a NULL stamp as ALREADY EXPIRED (`if let setAt =
    /// msg.actionTagSetAt, setAt > cutoff { continue }`), so a legacy tag on a
    /// message that has already left the inbox is reclaimed on the next
    /// maintenance pass instead of after a further TTL. That consequence is
    /// pinned end-to-end by `SyncMaintenanceTests`' "NULL actionTagSetAt on an
    /// out-of-inbox tag is swept (legacy-row fail-safe pin)"; this test pins
    /// that v81 is what puts a legacy row INTO that state.
    ///
    /// ⚠️ Two-sided on purpose, and the second side is the important one. The
    /// relaxation applies to pre-v81 rows and to NOTHING else: a
    /// going-forward writer must still keep `actionTag != nil ⇒
    /// actionTagSetAt != nil`, which `MessageHeader.setActionTag` enforces
    /// atomically. A change that "simplified" the stamp away everywhere would
    /// pass the first three assertions and fail the last one.
    @Test("v81: adds actionTagSetAt without stamping any pre-migration row, and the going-forward stamp still holds")
    func v81AddsNullableColumnAndStampsNothing() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        var beforeMigrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &beforeMigrator)
        try beforeMigrator.migrate(db, upTo: "v80_addDraftReplyTargetAddress")
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let taggedId = try insertPreV77Header(db, messageId: "81-tagged", actionTag: .reply)
        let untaggedId = try insertPreV77Header(db, messageId: "81-untagged", actionTag: nil)

        var afterMigrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &afterMigrator)
        try afterMigrator.migrate(db, upTo: "v81_addActionTagSetAt")

        let columns = try db.read { try Row.fetchAll($0, sql: "PRAGMA table_info(messageHeader)") }
        let column = try #require(columns.first { ($0["name"] as String) == "actionTagSetAt" })
        #expect((column["notnull"] as Int) == 0)

        let tagged = try db.read { try MessageHeader.fetchOne($0, key: taggedId) }
        #expect(tagged?.actionTag == .reply, "the tag itself must survive the upgrade untouched")
        #expect(
            tagged?.actionTagSetAt == nil,
            "a pre-v81 tagged row must emerge UNSTAMPED, so the sweep sees it as already expired"
        )

        let untagged = try db.read { try MessageHeader.fetchOne($0, key: untaggedId) }
        #expect(untagged?.actionTag == nil)
        #expect(untagged?.actionTagSetAt == nil, "no tag means nothing to stamp")

        // The going-forward side: v81 relaxes history, not the invariant.
        var fresh = MessageHeader(
            messageId: "81-post-upgrade", subject: "s", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "snippet",
            folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        fresh.setActionTag(.reply)
        try db.write { try fresh.insert($0) }
        let storedFresh = try db.read { try MessageHeader.fetchOne($0, key: fresh.id) }
        #expect(storedFresh?.actionTag == .reply)
        #expect(
            storedFresh?.actionTagSetAt != nil,
            "every writer after v81 must still keep actionTag != nil ⇒ actionTagSetAt != nil"
        )
    }

    @Test("v81: a fresh install has a nullable actionTagSetAt column that round-trips a stamp")
    func v81FreshInstallColumnIsUsableImmediately() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db)
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let before = Date()
        var header = MessageHeader(
            messageId: "81-fresh", subject: "s", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "snippet",
            folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        header.setActionTag(.reply)
        try db.write { try header.insert($0) }

        let stored = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(stored?.actionTag == .reply)
        let stamp = try #require(stored?.actionTagSetAt)
        #expect(stamp >= before.addingTimeInterval(-1))
    }
}
