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

        let read = try TestDatabase.insertMessageHeader(
            db, messageId: "1", isRead: true, actionTag: .reply)
        try TestDatabase.insertMessageHeader(db, messageId: "2")
        try TestDatabase.insertMessageHeader(db, messageId: "9", folderId: "acc2:INBOX", accountId: "acc2")
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

        try AppDatabase.runMigrations(on: db)

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
        let after = try db.read { try MessageHeader.fetchOne($0, key: read.id) }
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
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageHeader(db, messageId: "2")
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
        try TestDatabase.insertMessageHeader(db, messageId: "1")

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
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")

        let key = ContentKey(rawValue: "acc1:INBOX:1")
        let pixel = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let inlineId = BodyAssetStore.writeInlineImage(
            contentKey: key, contentId: "cid-1", contentType: "image/png", data: pixel)
        let attachmentId = BodyAssetStore.writeAttachment(
            contentKey: key, section: "2", contentType: "application/pdf", data: pixel)
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
        #expect(BodyAssetStore.attachmentAssetId(contentKey: key, section: "2") == attachmentId,
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
            contentKey: key, section: "2", contentType: "application/pdf", data: pixel)
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
}
