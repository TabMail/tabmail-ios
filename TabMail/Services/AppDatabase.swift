/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

/// Central GRDB database manager. Owns migrations, DatabasePool, and schema.
/// All reads/writes go through `dbPool`. No auto-observation — UI updates are explicit.
final class AppDatabase: Sendable {
    static let shared = Mutex<AppDatabase?>(nil)

    let dbPool: DatabasePool
    /// Clears delivered notifications when a row leaves the inbox (local action
    /// or remote sync). Held strongly here because GRDB retains observers weakly
    /// at `.observerLifetime`.
    let inboxNotificationObserver: InboxNotificationObserver

    init() throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("tabmail.sqlite").path

        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        // Reader pool size: 64. Raised from 10 after a repro log captured
        // MainActor blocked up to 6.7s waiting for a GRDB reader during
        // foreground-return (5-account sync + 5-account backfill + FTS bulk
        // index + AI processor all reading concurrently). MainActor's
        // synchronous `dbPool.read` (e.g. fetchPage in loadInitialPage)
        // blocks on DispatchSemaphore when all readers are held by
        // background work — this is distinct from the priority-inversion
        // fix (ADR-IOS-031); that addressed QoS attribution but not the
        // underlying pool contention.
        //
        // 64 readers is well above our actual concurrent-reader count
        // (observed ceiling: ~15 during burst). Each reader connection
        // costs ~100-200KB for page+statement caches → ~12MB worst case.
        // SQLite WAL supports unlimited concurrent readers natively with
        // zero reader-vs-reader locking, so this only affects memory
        // footprint and one-time connection setup (~2ms each, amortized
        // as the pool grows under load).
        config.maximumReaderCount = 64
        // 0xdead10cc defense: release/refuse SQLite locks when DatabaseSuspension
        // posts Database.suspendNotification just before process suspension.
        // WAL reads keep working while suspended; lock-acquiring accesses throw
        // SQLITE_ABORT/SQLITE_INTERRUPT and retry on next wake. See ADR-IOS-041.
        config.observesSuspensionNotifications = true
        dbPool = try DatabasePool(path: path, configuration: config)
        try Self.runMigrations(on: dbPool)
        // One-time destructive cached-mail resets, synchronously, BEFORE the pool
        // is exposed (`AppDatabase.shared` set in TabMailApp.init) or the inbox
        // observer is wired. DB opens → schema migrates → data resets → only THEN
        // can sync / NSE merge / demo+screenshot seed touch the DB. This is what
        // lets us drop the old async "migrations complete" gate. NOT run in the
        // test init below (tests must not touch global flags / the FTS directory).
        StartupMigrations.run(dbPool)
        self.inboxNotificationObserver = try Self.makeInboxNotificationObserver(on: dbPool)
    }

    /// Test-only initializer: accepts an already-configured DatabasePool (e.g. in-memory)
    /// and runs all migrations on it. Not for production use.
    init(dbPool: DatabasePool) throws {
        self.dbPool = dbPool
        try Self.runMigrations(on: dbPool)
        self.inboxNotificationObserver = try Self.makeInboxNotificationObserver(on: dbPool)
    }

    /// Wires production-flavored `InboxNotificationObserver` to the pool.
    /// Atomic seed + register inside one write block — GRDB-documented idiomatic
    /// pattern (`db.add(transactionObserver:)` from inside `pool.write`). Caller
    /// MUST retain the returned observer; GRDB holds it weakly at
    /// `.observerLifetime`.
    private static func makeInboxNotificationObserver(on pool: DatabasePool) throws -> InboxNotificationObserver {
        let observer = InboxNotificationObserver(clear: { acct, mid in
            NSEDataBridge.clearNotification(accountId: acct, messageId: mid)
        })
        try pool.write { db in
            try observer.seed(db)
            db.add(transactionObserver: observer)
        }
        return observer
    }

    /// Read-only access (concurrent readers, no blocking).
    var reader: any DatabaseReader { dbPool }

    /// Read-write access (serialized writes).
    var writer: any DatabaseWriter { dbPool }

    /// Convenience accessor — safe after app init.
    static var dbPool: DatabasePool {
        shared.withLock { $0!.dbPool }
    }

    // MARK: - NSE Staging Database

    /// Create the NSE staging database schema in the App Group container.
    /// Called once on app launch. The NSE extension reads/writes this DB.
    static func createNSEStagingDBIfNeeded() {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.ai.tabmail"
        ) else {
            print("[AppDatabase] App Group container not available — NSE staging DB not created")
            return
        }
        let path = url.appendingPathComponent("nse_staging.sqlite").path
        var config = Configuration()
        config.busyMode = .timeout(2)
        // 0xdead10cc defense (ADR-IOS-041). Non-WAL queue: ALL accesses abort
        // while suspended — schema setup is launch-time-only, so this is inert
        // in practice but keeps every main-app connection covered.
        config.observesSuspensionNotifications = true
        guard let db = try? DatabaseQueue(path: path, configuration: config) else {
            print("[AppDatabase] Failed to open NSE staging DB")
            return
        }
        do {
            try db.write { db in
                // v2 schema: includes rendered-body columns so the NSE can persist
                // htmlContent/textContent/attachmentsJSON/icsText/hasUnresolvedCIDs
                // alongside AI results — merge then writes MessageBody + FTS without
                // a redundant body re-fetch. MUST match NSEStagingDB.createSchemaIfNeeded.
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

                // Additive migrations for existing DBs (upgrade paths).
                // ALTER TABLE ADD COLUMN fails with "duplicate column" on already-
                // migrated DBs — that's expected and benign. Any other error
                // (locked table, disk I/O, etc.) must surface so we don't silently
                // ship a partial schema that later crashes the merge SELECTs.
                //
                // v2: body-render columns (NSE writes body alongside AI).
                // v3: rename folderId → folderPath (the column always stored a
                //     folder *path*, not a composite folderId; name was
                //     misleading and invited the bug chain where NSE wrote
                //     "INBOX" while main-app sync used the real provider
                //     folderPath — see bug 2b). Adds the new column, copies
                //     the legacy value over, leaves `folderId` in place (SQLite
                //     pre-3.35 can't safely drop columns and this DB is
                //     append-only anyway — the dead column is harmless).
                //
                // v4 (2026-04-19): full-header staging. NSE fetches recipients,
                // flags, reply/ref chain, provider labels — all previously
                // dropped between parse and persist, so the merge'd
                // MessageHeader shipped with placeholder `to: ""` + default-
                // `false` flags until sync's UPDATE pass ran over it. Violated
                // CLAUDE.md Data Integrity Rule #1 (no sentinel values for
                // data that WAS fetched). See commit d6fdd10 for when the
                // placeholder leaked in.
                //   • to/cc/bcc/replyTo — raw per-provider format (Gmail = raw
                //     RFC 2822 header, Graph = email-only comma list, IMAP =
                //     SwiftMail `info.to` joined with ", ").
                //   • inReplyTo + referencesJSON — enables the MessageReference
                //     junction insert in merge so thread continuity works
                //     before sync materializes.
                //   • isFlagged, hasAttachments — flags present in every
                //     provider response; NSE had them but didn't forward.
                //   • providerLabelsJSON — Gmail labelIds / Outlook categories
                //     / IMAP custom keywords. Merge resolves MessageUserLabel
                //     junction rows + optional server-side ActionTag override.
                for col in [
                    "htmlContent TEXT", "textContent TEXT",
                    "attachmentsJSON TEXT", "icsText TEXT",
                    "hasUnresolvedCIDs INTEGER DEFAULT 0",
                    "folderPath TEXT",
                    "toRaw TEXT DEFAULT ''",
                    "ccRaw TEXT DEFAULT ''",
                    "bccRaw TEXT DEFAULT ''",
                    "replyToRaw TEXT",
                    "inReplyTo TEXT",
                    "referencesJSON TEXT",
                    "isFlagged INTEGER DEFAULT 0",
                    "hasAttachments INTEGER DEFAULT 0",
                    "providerLabelsJSON TEXT",
                    // v4.1 (2026-04-19): IMAP-only replied/forwarded flags.
                    // IMAP surfaces these via `\Answered` standard flag and
                    // `$Forwarded` custom keyword; Gmail/Graph always stage
                    // false (REST surface doesn't expose per-message).
                    "isReplied INTEGER DEFAULT 0",
                    "isForwarded INTEGER DEFAULT 0",
                    // v5 (2026-04-24): AI-ownership lease. NSE and main app both
                    // compute summary/action; without coordination every push
                    // duplicates the backend call. aiOwner ∈ {"nse","mainApp",NULL}
                    // with aiHeartbeatMs (unix ms) acts as a lease — the holder
                    // refreshes every 1s while running; a stale heartbeat
                    // (> AI_LEASE_STALE_MS) means the holder died and the other
                    // side takes over. Atomic claim via conditional UPDATE.
                    "aiOwner TEXT",
                    "aiHeartbeatMs INTEGER",
                    // v6 (2026-04-27): populated flag. NSE's persistProcessedMessage
                    // sets this to 1; AIOwnershipLease.ensureRow leaves it at the
                    // 0 default. Merge SELECTs `WHERE populated=1` so half-written
                    // lease placeholders never become zombie MessageHeaders.
                    "populated INTEGER NOT NULL DEFAULT 0",
                ] {
                    do {
                        try db.execute(sql: "ALTER TABLE nse_processed_message ADD COLUMN \(col)")
                    } catch {
                        let msg = "\(error)".lowercased()
                        if !msg.contains("duplicate column") {
                            throw error
                        }
                    }
                }
                // Backfill folderPath from legacy folderId column where the new
                // column is empty. One-shot migration; idempotent (second run
                // finds folderPath already populated and no-ops).
                do {
                    try db.execute(sql: """
                        UPDATE nse_processed_message
                        SET folderPath = folderId
                        WHERE (folderPath IS NULL OR folderPath = '') AND folderId IS NOT NULL
                        """)
                } catch {
                    // `folderId` may not exist on very-new installs that skipped
                    // the legacy schema entirely. Log + continue — fresh DBs have
                    // folderPath populated on every INSERT.
                    let msg = "\(error)".lowercased()
                    if !msg.contains("no such column") {
                        throw error
                    }
                }

                // v6 backfill (2026-04-27): mark pre-migration rows as populated
                // when they look real (non-empty provider AND non-empty
                // accountEmail — the two columns AIOwnershipLease.ensureRow
                // writes as explicit empty strings). A blanket SET populated=1
                // would mark in-flight lease placeholders as real, producing
                // zombie MessageHeaders on the first post-upgrade wake.
                // Idempotent: post-migration writers go through the explicit
                // flag, so this UPDATE is a no-op on second run.
                try db.execute(sql: """
                    UPDATE nse_processed_message SET populated = 1
                    WHERE provider IS NOT NULL AND provider != ''
                      AND accountEmail IS NOT NULL AND accountEmail != ''
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
            print("[AppDatabase] NSE staging DB schema ready (v6 — populated flag)")
        } catch {
            print("[AppDatabase] Failed to create NSE staging DB schema: \(error)")
        }
    }

    // MARK: - Migrations

    /// Run all migrations on an arbitrary DatabaseWriter (used by tests with in-memory DB).
    static func runMigrations(on writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        registerAllMigrations(on: &migrator)
        try migrator.migrate(writer)
    }

    // MARK: - Migration Definitions

    static func registerAllMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_createTables") { db in
            // Account
            try db.create(table: "account") { t in
                t.primaryKey("id", .text)
                t.column("emailAddress", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("provider", .text).notNull()
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("signature", .text)
                t.column("signatureBelowQuote", .boolean).notNull().defaults(to: false)
                t.column("imapUsername", .text)
                t.column("imapHost", .text)
                t.column("imapPort", .integer)
                t.column("smtpHost", .text)
                t.column("smtpPort", .integer)
                t.column("maxSyncAgeDays", .integer).notNull().defaults(to: Int.max)
                t.column("createdAt", .datetime).notNull()
                t.column("lastSyncedAt", .datetime)
                t.column("lastFullSyncAt", .datetime)
                t.column("lastHistoryId", .text)
            }

            // Folder
            try db.create(table: "folder") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull().defaults(to: "")
                t.column("role", .text).notNull()
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("totalCount", .integer).notNull().defaults(to: 0)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("backfillComplete", .boolean).notNull().defaults(to: false)
                t.column("oldestSyncedDate", .datetime)
                t.column("lastKnownUidNext", .integer)
            }

            // MessageHeader
            try db.create(table: "messageHeader") { t in
                t.primaryKey("id", .text)
                t.column("folderId", .text).notNull()
                    .references("folder", onDelete: .cascade)
                t.column("accountId", .text).notNull()
                t.column("folderPath", .text).notNull()
                t.column("isInInbox", .boolean).notNull().defaults(to: false)
                t.column("messageId", .text).notNull()
                t.column("rfc822MessageId", .text)
                t.column("threadId", .text)
                t.column("subject", .text).notNull()
                t.column("from", .text).notNull()
                t.column("fromAddress", .text).notNull()
                t.column("to", .text).notNull()
                t.column("replyTo", .text)
                t.column("date", .datetime).notNull()
                t.column("snippet", .text).notNull().defaults(to: "")
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.column("isFlagged", .boolean).notNull().defaults(to: false)
                t.column("hasAttachments", .boolean).notNull().defaults(to: false)
                t.column("isReplied", .boolean).notNull().defaults(to: false)
                t.column("isForwarded", .boolean).notNull().defaults(to: false)
                t.column("actionTag", .text)
                t.column("tagSortOrder", .integer).notNull().defaults(to: 99)
                t.column("summaryBlurb", .text)
                t.column("summaryTodos", .text)
                t.column("reminderDate", .text)
                t.column("reminderTime", .text)
                t.column("reminderContent", .text)
                t.column("cachedReply", .text)
            }

            // MessageBody
            try db.create(table: "messageBody") { t in
                t.primaryKey("id", .text)
                    .references("messageHeader", onDelete: .cascade)
                t.column("htmlContent", .text)
                t.column("attachmentsJSON", .text)
                t.column("fetchedAt", .datetime).notNull()
            }

            // PendingOperation
            try db.create(table: "pendingOperation") { t in
                t.primaryKey("id", .text)
                t.column("type", .text).notNull()
                t.column("messageIdsJSON", .text).notNull()
                t.column("accountId", .text).notNull()
                t.column("folderPath", .text).notNull()
                t.column("destinationPath", .text)
                t.column("tagValue", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull().defaults(to: "queued")
            }

            // MessageAICache
            try db.create(table: "messageAICache") { t in
                t.primaryKey("key", .text)
                t.column("rfc822MessageId", .text)
                t.column("summaryBlurb", .text)
                t.column("summaryTodos", .text)
                t.column("reminderDate", .text)
                t.column("reminderTime", .text)
                t.column("reminderContent", .text)
                t.column("actionTag", .text)
                t.column("cachedReply", .text)
                t.column("replyGeneratedAt", .datetime)
                t.column("updatedAt", .datetime).notNull()
            }

            // Indexes
            try db.create(index: "messageHeader_folderId", on: "messageHeader", columns: ["folderId"])
            try db.create(index: "messageHeader_accountId", on: "messageHeader", columns: ["accountId"])
            try db.create(index: "messageHeader_rfc822MessageId", on: "messageHeader", columns: ["rfc822MessageId"])
            try db.create(index: "messageHeader_threadId", on: "messageHeader", columns: ["threadId"])
            try db.create(index: "messageHeader_date", on: "messageHeader", columns: ["date"])
            try db.create(index: "messageAICache_rfc822MessageId", on: "messageAICache", columns: ["rfc822MessageId"])
        }

        // v2: Remove FK on messageHeader.folderId → folder.
        // The FK prevents optimistic UI updates (setting folderId = "" for pending
        // archive/delete) because "" is not a valid folder.id. Replace with FK on
        // accountId → account for CASCADE cleanup on account deletion.
        migrator.registerMigration("v2_dropMessageHeaderFolderFK", foreignKeyChecks: .deferred) { db in
            // Backup existing data
            try db.execute(sql: "CREATE TABLE messageHeader_backup AS SELECT * FROM messageHeader")
            try db.execute(sql: "CREATE TABLE messageBody_backup AS SELECT * FROM messageBody")

            // Drop old tables (dependent first)
            try db.drop(table: "messageBody")
            try db.drop(table: "messageHeader")

            // Recreate messageHeader: folderId is plain column (no FK), accountId has CASCADE FK
            try db.create(table: "messageHeader") { t in
                t.primaryKey("id", .text)
                t.column("folderId", .text).notNull()
                t.column("accountId", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("folderPath", .text).notNull()
                t.column("isInInbox", .boolean).notNull().defaults(to: false)
                t.column("messageId", .text).notNull()
                t.column("rfc822MessageId", .text)
                t.column("threadId", .text)
                t.column("subject", .text).notNull()
                t.column("from", .text).notNull()
                t.column("fromAddress", .text).notNull()
                t.column("to", .text).notNull()
                t.column("replyTo", .text)
                t.column("date", .datetime).notNull()
                t.column("snippet", .text).notNull().defaults(to: "")
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.column("isFlagged", .boolean).notNull().defaults(to: false)
                t.column("hasAttachments", .boolean).notNull().defaults(to: false)
                t.column("isReplied", .boolean).notNull().defaults(to: false)
                t.column("isForwarded", .boolean).notNull().defaults(to: false)
                t.column("actionTag", .text)
                t.column("tagSortOrder", .integer).notNull().defaults(to: 99)
                t.column("summaryBlurb", .text)
                t.column("summaryTodos", .text)
                t.column("reminderDate", .text)
                t.column("reminderTime", .text)
                t.column("reminderContent", .text)
                t.column("cachedReply", .text)
            }

            // Recreate messageBody with FK to new messageHeader
            try db.create(table: "messageBody") { t in
                t.primaryKey("id", .text)
                    .references("messageHeader", onDelete: .cascade)
                t.column("htmlContent", .text)
                t.column("attachmentsJSON", .text)
                t.column("fetchedAt", .datetime).notNull()
            }

            // Restore data
            try db.execute(sql: "INSERT INTO messageHeader SELECT * FROM messageHeader_backup")
            try db.execute(sql: "INSERT INTO messageBody SELECT * FROM messageBody_backup")

            // Drop backup tables
            try db.drop(table: "messageHeader_backup")
            try db.drop(table: "messageBody_backup")

            // Recreate indexes
            try db.create(index: "messageHeader_folderId", on: "messageHeader", columns: ["folderId"])
            try db.create(index: "messageHeader_accountId", on: "messageHeader", columns: ["accountId"])
            try db.create(index: "messageHeader_rfc822MessageId", on: "messageHeader", columns: ["rfc822MessageId"])
            try db.create(index: "messageHeader_threadId", on: "messageHeader", columns: ["threadId"])
            try db.create(index: "messageHeader_date", on: "messageHeader", columns: ["date"])
        }

        // v3: Add outboxMessage table for offline send queue.
        migrator.registerMigration("v3_createOutboxMessage") { db in
            try db.create(table: "outboxMessage") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("toJSON", .text).notNull()
                t.column("ccJSON", .text).notNull()
                t.column("bccJSON", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("body", .text).notNull()
                t.column("isHTML", .boolean).notNull().defaults(to: false)
                t.column("inReplyTo", .text)
                t.column("referencesJSON", .text)
                t.column("attachmentsDirName", .text)
                t.column("status", .text).notNull().defaults(to: "queued")
                t.column("errorMessage", .text)
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("originalMessageHeaderId", .text)
                t.column("isForward", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "outboxMessage_accountId", on: "outboxMessage", columns: ["accountId"])
            try db.create(index: "outboxMessage_status", on: "outboxMessage", columns: ["status"])
        }

        // v4: Add sentAt column — set after successful provider.send() but before
        // DB delete. Allows reconcileOutbox to distinguish "crashed mid-send" from
        // "crashed after send succeeded" and avoid double-sends.
        migrator.registerMigration("v4_addOutboxSentAt") { db in
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "sentAt", .datetime)
            }
        }

        // v5: Add isPrimary column to account — explicit primary account for compose default.
        migrator.registerMigration("v5_addAccountIsPrimary") { db in
            try db.alter(table: "account") { t in
                t.add(column: "isPrimary", .boolean).notNull().defaults(to: false)
            }
            // Set the oldest active account as primary
            try db.execute(sql: """
                UPDATE account SET isPrimary = 1
                WHERE id = (SELECT id FROM account WHERE isActive = 1 ORDER BY createdAt LIMIT 1)
            """)
        }

        // v6: Add chatTurn table for persistent agent chat history (device-local, not synced).
        migrator.registerMigration("v6_createChatTurn") { db in
            try db.create(table: "chatTurn") { t in
                t.primaryKey("id", .text)
                t.column("timestamp", .double).notNull()
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("userMessage", .text)
                t.column("type", .text).notNull().defaults(to: "normal")
                t.column("chars", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "chatTurn_timestamp", on: "chatTurn", columns: ["timestamp"])
        }

        // v7: Add renderedContent column to chatTurn — stores pre-processed text with resolved
        // email pills (subjects baked in) so history renders correctly across sessions.
        // Matches TB's _rendered snapshot approach.
        migrator.registerMigration("v7_addChatTurnRenderedContent") { db in
            try db.alter(table: "chatTurn") { t in
                t.add(column: "renderedContent", .text)
            }
        }

        // v8: Pending calendar operation queue — crash-safe calendar mutations.
        // Mirrors PendingOperation pattern: persist before acknowledging, drain async.
        migrator.registerMigration("v8_createPendingCalendarOperation") { db in
            try db.create(table: "pendingCalendarOperation") { t in
                t.primaryKey("id", .text)
                t.column("operationType", .text).notNull()
                t.column("accountId", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("eventId", .text)
                t.column("argumentsJSON", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "queued")
                t.column("createdAt", .datetime).notNull()
                t.column("retryCount", .integer).notNull().defaults(to: 0)
            }
        }

        // v9: Backfill subject-based threadIds for existing IMAP messages (threadId IS NULL).
        // Uses cursor for bounded memory. Gmail messages already have threadId — skipped.
        migrator.registerMigration("v9_backfillThreadIds") { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, accountId, subject FROM messageHeader WHERE threadId IS NULL
            """)
            while let row = try rows.next() {
                let id: String = row["id"]
                let accountId: String = row["accountId"]
                let subject: String = row["subject"]
                if let threadId = ThreadUtils.computeSubjectThreadId(accountId: accountId, subject: subject) {
                    try db.execute(sql: "UPDATE messageHeader SET threadId = ? WHERE id = ?", arguments: [threadId, id])
                }
            }
        }

        // v10: Add cc/bcc columns to messageHeader for FTS search parity with TB.
        // Defaults to empty string — will be populated on next header re-fetch.
        migrator.registerMigration("v10_addCcBcc") { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "cc", .text).notNull().defaults(to: "")
                t.add(column: "bcc", .text).notNull().defaults(to: "")
            }
        }

        // v11: Add sessionId to chatTurn — groups turns into sessions for swipe-navigable
        // history in the chat pill. Existing turns keep NULL sessionId (visible in Settings
        // Chat History only, not in pill session navigation).
        migrator.registerMigration("v11_addChatTurnSessionId") { db in
            try db.alter(table: "chatTurn") { t in
                t.add(column: "sessionId", .text)
            }
            try db.create(index: "chatTurn_sessionId", on: "chatTurn", columns: ["sessionId"])
        }

        // v12: Persistent ID mapping for ChatIdTranslator — survives app restart so that
        // pill references ([Email](N)) in old sessions remain resolvable.
        migrator.registerMigration("v12_createChatIdMapping") { db in
            try db.create(table: "chatIdMapping") { t in
                t.primaryKey("numericId", .integer)
                t.column("realId", .text).notNull().unique()
            }
        }

        // v13: Add inReplyTo column to messageHeader — RFC 2822 In-Reply-To header
        // for header-based thread detection (replaces subject heuristic).
        migrator.registerMigration("v13_addMessageHeaderInReplyTo") { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "inReplyTo", .text)
            }
            try db.create(index: "messageHeader_inReplyTo", on: "messageHeader", columns: ["inReplyTo"])
        }

        // v14: Add backfillUidCursor column to folder — IMAP backfill walks backward
        // from UIDNEXT by UID range instead of date-windowed SEARCH.
        // Seed cursor for in-progress IMAP backfills from MIN(messageId) where messageId is numeric (UID).
        migrator.registerMigration("v14_addFolderBackfillUidCursor") { db in
            try db.alter(table: "folder") { t in
                t.add(column: "backfillUidCursor", .integer)
            }
            // Seed cursor for IMAP folders that are mid-backfill (have messages but not yet complete).
            // messageId for IMAP is the UID stored as a string — cast to integer for MIN.
            try db.execute(sql: """
                UPDATE folder SET backfillUidCursor = (
                    SELECT MIN(CAST(mh.messageId AS INTEGER))
                    FROM messageHeader mh
                    WHERE mh.folderId = folder.id
                      AND CAST(mh.messageId AS INTEGER) > 0
                )
                WHERE folder.backfillComplete = 0
                  AND folder.path != ''
                  AND EXISTS (
                    SELECT 1 FROM account a
                    WHERE a.id = folder.accountId AND a.provider = 'imap'
                  )
                  AND EXISTS (
                    SELECT 1 FROM messageHeader mh2
                    WHERE mh2.folderId = folder.id
                  )
            """)
        }

        // v15: Add backfillPageToken column to folder — Gmail/Exchange page-token cursor
        // for backfill. Walks the full label/folder listing one page at a time, resuming
        // from stored token. Nil means start from page 1.
        migrator.registerMigration("v15_addFolderBackfillPageToken") { db in
            try db.alter(table: "folder") { t in
                t.add(column: "backfillPageToken", .text)
            }
        }

        // v16: CalDAV support — config table + calendarOnly flag on account.
        migrator.registerMigration("v16_createCalDAVConfig") { db in
            try db.create(table: "caldavConfig") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("serverURL", .text).notNull()
                t.column("principalURL", .text)
                t.column("calendarHomeURL", .text)
                t.column("username", .text).notNull()
                t.column("displayName", .text)
                t.column("needsReauth", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v17_addCalendarOnlyToAccount") { db in
            try db.alter(table: "account") { t in
                t.add(column: "calendarOnly", .boolean).notNull().defaults(to: false)
            }
        }

        // v18: Persistent sent-folder append for IMAP — after SMTP send succeeds,
        // the outbox message stays alive until the copy is appended to the Sent folder.
        // sentMessageId: RFC822 Message-ID generated before send (used for dedup on retry).
        // appendedToSent: false until IMAP APPEND (or Gmail/Exchange auto-save) confirms.
        migrator.registerMigration("v18_addOutboxSentAppend") { db in
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "sentMessageId", .text)
                t.add(column: "appendedToSent", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v19_addMessageBodyIcsText") { db in
            try db.alter(table: "messageBody") { t in
                t.add(column: "icsText", .text)
            }
        }

        // v20: Add remindersSnapshot to chatTurn — stores the reminder list shown when a session
        // started, as JSON. Only populated on the first turn of each session. Enables read-only
        // reminder display when viewing past sessions.
        migrator.registerMigration("v20_addChatTurnRemindersSnapshot") { db in
            try db.alter(table: "chatTurn") { t in
                t.add(column: "remindersSnapshot", .text)
            }
        }

        // v21: Composite index for efficient unread count queries.
        // COUNT(*) WHERE folderId = ? AND isRead = 0 is a covering index scan
        // instead of index lookup + row filter.
        migrator.registerMigration("v21_addUnreadCountIndex") { db in
            try db.create(index: "messageHeader_folderId_isRead", on: "messageHeader", columns: ["folderId", "isRead"])
        }

        // v22: Email context snapshot for message-detail chat sessions.
        // Stores the email being discussed (subject, from, messageHeaderId) on the first
        // turn of a message-detail session so past sessions show which email was discussed.
        migrator.registerMigration("v22_addChatTurnEmailContext") { db in
            try db.alter(table: "chatTurn") { t in
                t.add(column: "emailContextJSON", .text)
            }
        }

        // v23: Draft persistence for compose sessions.
        // Stores draft state (to/cc/bcc/subject/body) + edit history so compose chat
        // can resume on reopen. Tied to reply/forward via replyToId, or new compose via UUID key.
        migrator.registerMigration("v23_createDraft") { db in
            try db.create(table: "draft") { t in
                t.primaryKey("id", .text)                           // draftKey: "reply:{id}", "forward:{id}", "new:{uuid}"
                t.column("accountId", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("toJSON", .text).notNull().defaults(to: "[]")
                t.column("ccJSON", .text).notNull().defaults(to: "[]")
                t.column("bccJSON", .text).notNull().defaults(to: "[]")
                t.column("subject", .text).notNull().defaults(to: "")
                t.column("body", .text).notNull().defaults(to: "")
                t.column("replyToId", .text)                        // original message header ID for reply/forward
                t.column("isForward", .boolean).notNull().defaults(to: false)
                t.column("editHistoryJSON", .text)                  // JSON array of InlineEditTurn
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
        }

        // v24: Server draft sync columns + draft attachments.
        // Enables lazy push of local drafts to server Drafts folder.
        // serverDraftId: Gmail draft ID / Exchange message ID / IMAP UID
        // serverPushStatus: NULL (not pushed), "pushed", "dirty" (needs re-push)
        // rfc822MessageId: Stable Message-ID for IMAP dedup across UID changes
        // attachmentsDirName: Disk directory for draft attachments (mirrors outbox pattern)
        // Also adds serverDraftId to outboxMessage for post-send draft cleanup.
        migrator.registerMigration("v24_addServerDraftSync") { db in
            try db.alter(table: "draft") { t in
                t.add(column: "serverDraftId", .text)
                t.add(column: "serverPushStatus", .text)
                t.add(column: "rfc822MessageId", .text)
                t.add(column: "attachmentsDirName", .text)
            }
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "serverDraftId", .text)
            }
        }

        // v25: Create chatHistory table — parallel store for dereferenced chat turns.
        // chatTurn = resumable sessions (raw [Email](N) references, ChatIdTranslator mappings).
        // chatHistory = memory (dereferenced content, searchable by MemorySearchTool).
        // Written alongside chatTurn on every turn persist. Evicted only by global turn cap.
        // Backfill existing chatTurn data: use renderedContent if available, else content.
        migrator.registerMigration("v25_createChatHistory") { db in
            try db.create(table: "chatHistory") { t in
                t.primaryKey("id", .text)              // same ID as chatTurn
                t.column("timestamp", .double).notNull()
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()   // always dereferenced (no [Email](N))
                t.column("userMessage", .text)
                t.column("sessionId", .text)
                t.column("chars", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "chatHistory_timestamp", on: "chatHistory", columns: ["timestamp"])
            try db.create(index: "chatHistory_sessionId", on: "chatHistory", columns: ["sessionId"])

            // Backfill from existing chatTurn data
            try db.execute(sql: """
                INSERT INTO chatHistory (id, timestamp, role, content, userMessage, sessionId, chars)
                SELECT id, timestamp, role,
                       COALESCE(renderedContent, content),
                       userMessage, sessionId, chars
                FROM chatTurn
            """)
        }
        // v26: Add referencesJSON column to messageHeader — RFC 2822 References header
        // as JSON array of normalized message IDs. Enables thread detection when inReplyTo
        // points to a message not in the local DB (common with forwarded email chains).
        migrator.registerMigration("v26_addMessageHeaderReferences") { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "referencesJSON", .text)
            }
        }

        // v27: Add computedThreadId + messageReference junction table for unified thread grouping.
        // computedThreadId: assigned once at insert time. Gmail/Exchange: copied from native threadId.
        // IMAP: computed by chain-walking inReplyTo/References in the DB.
        // messageReference: junction table for indexed reverse lookups of References header.
        migrator.registerMigration("v27_computedThreadId") { db in
            // 1. Add computedThreadId column
            try db.alter(table: "messageHeader") { t in
                t.add(column: "computedThreadId", .text).notNull().defaults(to: "")
            }
            try db.create(index: "messageHeader_computedThreadId",
                          on: "messageHeader", columns: ["computedThreadId"])

            // 2. Create messageReference junction table
            try db.create(table: "messageReference") { t in
                t.column("messageHeaderId", .text).notNull().references("messageHeader", onDelete: .cascade)
                t.column("referencedRfc822Id", .text).notNull()
            }
            try db.create(index: "messageReference_referencedRfc822Id",
                          on: "messageReference", columns: ["referencedRfc822Id"])
            try db.create(index: "messageReference_messageHeaderId",
                          on: "messageReference", columns: ["messageHeaderId"])

            // 3. Populate computedThreadId for Gmail/Exchange (have real threadId, not subj: prefix)
            try db.execute(sql: """
                UPDATE messageHeader SET computedThreadId = threadId
                WHERE threadId IS NOT NULL AND threadId != '' AND threadId NOT LIKE 'subj:%'
            """)

            // 4. Populate computedThreadId for IMAP by chain-walking.
            // Strategy: process messages oldest-first. For each message without a computedThreadId,
            // look up inReplyTo/references in existing messages. If found, adopt their computedThreadId.
            // Otherwise, use own rfc822MessageId as a new thread root.
            let imapRows = try Row.fetchAll(db, sql: """
                SELECT id, rfc822MessageId, inReplyTo, referencesJSON
                FROM messageHeader
                WHERE computedThreadId = ''
                ORDER BY date ASC
            """)

            for row in imapRows {
                let headerId: String = row["id"]
                let rfc822: String? = row["rfc822MessageId"]
                let inReplyTo: String? = row["inReplyTo"]
                let refsJSON: String? = row["referencesJSON"]

                // Collect all rfc822 IDs this message references
                var lookupIds: [String] = []
                if let irt = inReplyTo, !irt.isEmpty { lookupIds.append(irt) }
                if let json = refsJSON, let data = json.data(using: .utf8),
                   let refs = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    lookupIds.append(contentsOf: refs)
                }

                // Populate messageReference rows
                for refId in lookupIds {
                    try db.execute(sql: """
                        INSERT INTO messageReference (messageHeaderId, referencedRfc822Id) VALUES (?, ?)
                    """, arguments: [headerId, refId])
                }

                // Forward lookup: find existing message with matching rfc822MessageId
                var adoptedThreadId: String?
                if !lookupIds.isEmpty {
                    let placeholders = lookupIds.map { _ in "?" }.joined(separator: ",")
                    let found = try String.fetchOne(db, sql: """
                        SELECT computedThreadId FROM messageHeader
                        WHERE rfc822MessageId IN (\(placeholders)) AND computedThreadId != ''
                        LIMIT 1
                    """, arguments: StatementArguments(lookupIds))
                    adoptedThreadId = found
                }

                // Reverse lookup: find messages whose inReplyTo points to us
                if adoptedThreadId == nil, let rfc = rfc822, !rfc.isEmpty {
                    let found = try String.fetchOne(db, sql: """
                        SELECT computedThreadId FROM messageHeader
                        WHERE inReplyTo = ? AND computedThreadId != ''
                        LIMIT 1
                    """, arguments: [rfc])
                    if found == nil {
                        // Also check messageReference table (messages whose References contain us)
                        let refFound = try String.fetchOne(db, sql: """
                            SELECT m.computedThreadId FROM messageReference r
                            JOIN messageHeader m ON m.id = r.messageHeaderId
                            WHERE r.referencedRfc822Id = ? AND m.computedThreadId != ''
                            LIMIT 1
                        """, arguments: [rfc])
                        adoptedThreadId = refFound
                    } else {
                        adoptedThreadId = found
                    }
                }

                let finalThreadId = adoptedThreadId ?? rfc822 ?? headerId
                try db.execute(sql: "UPDATE messageHeader SET computedThreadId = ? WHERE id = ?",
                               arguments: [finalThreadId, headerId])
            }

            // 5. Also populate messageReference for Gmail/Exchange messages (already have computedThreadId)
            let gmailRows = try Row.fetchAll(db, sql: """
                SELECT id, inReplyTo, referencesJSON FROM messageHeader
                WHERE computedThreadId != '' AND threadId IS NOT NULL AND threadId != '' AND threadId NOT LIKE 'subj:%'
            """)
            for row in gmailRows {
                let headerId: String = row["id"]
                let inReplyTo: String? = row["inReplyTo"]
                let refsJSON: String? = row["referencesJSON"]
                var lookupIds: [String] = []
                if let irt = inReplyTo, !irt.isEmpty { lookupIds.append(irt) }
                if let json = refsJSON, let data = json.data(using: .utf8),
                   let refs = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    lookupIds.append(contentsOf: refs)
                }
                for refId in lookupIds {
                    try db.execute(sql: """
                        INSERT INTO messageReference (messageHeaderId, referencedRfc822Id) VALUES (?, ?)
                    """, arguments: [headerId, refId])
                }
            }
        }

        // v28: Add calendarId to pendingCalendarOperation — stores which calendar
        // an event belongs to so edit/delete operations target the correct calendar.
        // Nullable for backwards compat: existing queued ops fall back to preferred calendar.
        migrator.registerMigration("v28_addPendingCalendarOpCalendarId") { db in
            try db.alter(table: "pendingCalendarOperation") { t in
                t.add(column: "calendarId", .text)
            }
        }

        migrator.registerMigration("v29_addChatTurnThinkingContent") { db in
            try db.alter(table: "chatTurn") { t in
                t.add(column: "thinkingContent", .text)
            }
        }

        // v30: Reset backfill state for all folders to re-walk with robust cursor.
        // The old cursor could advance past failed ranges, permanently skipping messages.
        // Re-walking with the new claim/confirm model ensures nothing is missed.
        // Existing messages are preserved — dedup in insertBackfillBatch handles duplicates.
        migrator.registerMigration("v30_resetBackfillForRobustCursor") { db in
            try db.execute(sql: """
                UPDATE folder SET
                    backfillComplete = 0,
                    backfillUidCursor = NULL,
                    backfillPageToken = NULL
            """)
        }

        // v31: Add bodyComplete flag to messageHeader.
        // Tracks whether the message body has been written to FTS.
        // Eliminates expensive per-message FTS probes during AI/body queue repopulate
        // (reduces repopulate from ~20s to <1ms).
        // Backfill: mark existing messages that already have snippets (snippet is set
        // at the same time as FTS body write, so non-empty snippet ↔ body in FTS).
        migrator.registerMigration("v31_addHasBodyInFTS") { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "bodyComplete", .boolean).notNull().defaults(to: false)
            }
            // Backfill: messages with non-empty snippets already have body in FTS
            try db.execute(sql: """
                UPDATE messageHeader SET bodyComplete = 1
                WHERE snippet IS NOT NULL AND snippet != '' AND snippet != ' '
            """)
            // Index for fast repopulate query
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_messageHeader_aiRepopulate
                ON messageHeader(isInInbox, bodyComplete, date)
                WHERE isInInbox = 1 AND bodyComplete = 1
            """)
        }

        // v32: Create pendingRender table for durable body staging.
        // Persists fetched message bodies between fetch and render so they
        // survive app kills. Evicted after MessageBody is created.
        // Also serves as offline cache: fetchBody checks here before server.
        migrator.registerMigration("v32_createPendingRender") { db in
            try db.create(table: "pendingRender") { t in
                t.primaryKey("id", .text)           // headerId
                t.column("accountId", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("folderPath", .text).notNull()
                t.column("htmlBody", .text)
                t.column("textBody", .text)
                t.column("attachmentsJSON", .text)
                t.column("inlineImagesJSON", .text)
                t.column("createdAt", .double).notNull()
            }
        }

        // v33: UserLabel support — user-facing labels (Gmail labels, IMAP keywords).
        // Creates userLabel + messageUserLabel tables, adds userLabelId to pendingOperation,
        // and resets backfill state so existing messages get label data during re-walk.
        migrator.registerMigration("v33_userLabelSupport") { db in
            // 1. Create userLabel table
            try db.create(table: "userLabel") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("isSystem", .integer).notNull().defaults(to: false)
            }

            // 2. Create messageUserLabel join table
            try db.create(table: "messageUserLabel") { t in
                t.column("messageId", .text).notNull()
                    .references("messageHeader", onDelete: .cascade)
                t.column("userLabelId", .text).notNull()
                    .references("userLabel", onDelete: .cascade)
                t.primaryKey(["messageId", "userLabelId"])
            }
            try db.create(
                index: "idx_messageUserLabel_userLabelId",
                on: "messageUserLabel",
                columns: ["userLabelId"]
            )

            // 3. Add userLabelId column to pendingOperation
            try db.alter(table: "pendingOperation") { t in
                t.add(column: "userLabelId", .text)
            }

            // 4. Reset backfill state to re-walk all folders (populates label data for existing messages)
            try db.execute(sql: """
                UPDATE folder SET
                    backfillComplete = 0,
                    backfillUidCursor = NULL,
                    backfillPageToken = NULL,
                    oldestSyncedDate = NULL
            """)
        }

        migrator.registerMigration("v34_addConfirmedEmptyBody") { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "confirmedEmptyBody", .boolean).notNull().defaults(to: false)
            }
            try db.create(
                index: "idx_messageHeader_bodyStatus",
                on: "messageHeader",
                columns: ["bodyComplete", "confirmedEmptyBody"]
            )
        }

        migrator.registerMigration("v35_addHasEmbedding") { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "hasEmbedding", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v36_renameBodyFlags") { db in
            // Rename columns for clarity: "has/confirmed" → "complete/confirmed" semantics.
            // bodyComplete already has its final name (renamed in v31).
            // confirmedEmptyBody → bodyEmptyConfirmed (server confirmed no content)
            // hasEmbedding → embeddingComplete
            try db.alter(table: "messageHeader") { t in
                t.rename(column: "confirmedEmptyBody", to: "bodyEmptyConfirmed")
                t.rename(column: "hasEmbedding", to: "embeddingComplete")
            }
            // Recreate composite index with new column names
            try db.drop(index: "idx_messageHeader_bodyStatus")
            try db.create(
                index: "idx_messageHeader_bodyStatus",
                on: "messageHeader",
                columns: ["bodyComplete", "bodyEmptyConfirmed"]
            )
        }

        migrator.registerMigration("v37_bodyStatusIndexWithInbox") { db in
            // Include isInInbox in the body status index so ActiveBodyQueue (isInInbox=1)
            // and BackfillBodyQueue (isInInbox=0) repopulate queries can be answered
            // directly from the index without scanning ~144K rows. Drops repopulate
            // time from ~2-3s to single-digit ms.
            try db.drop(index: "idx_messageHeader_bodyStatus")
            try db.create(
                index: "idx_messageHeader_bodyStatus",
                on: "messageHeader",
                columns: ["bodyComplete", "bodyEmptyConfirmed", "isInInbox"]
            )
        }

        migrator.registerMigration("v38_addHeaderComplete") { db in
            // Tracks whether header's FTS indexing is complete (GRDB + FTS two-phase write).
            // Body queue requires headerComplete=1 before fetching body — prevents the race
            // where body fetch runs before FTS indexing, causing permanent AI processing failure.
            // Default 1 for existing rows (assumed already indexed). New inserts start at 0.
            try db.alter(table: "messageHeader") { t in
                t.add(column: "headerComplete", .boolean).notNull().defaults(to: true)
            }

            // IMPORTANT: Do NOT drop existing indexes — they serve other queries.
            // ADD new indexes alongside existing ones. SQLite picks the best per query.

            // Body queue repopulate: WHERE headerComplete=1 AND bodyComplete=0 AND isInInbox=1
            // (extends existing idx_messageHeader_bodyStatus with headerComplete)
            try db.drop(index: "idx_messageHeader_bodyStatus")
            try db.create(
                index: "idx_messageHeader_bodyStatus",
                on: "messageHeader",
                columns: ["headerComplete", "bodyComplete", "bodyEmptyConfirmed", "isInInbox"]
            )

            // Inbox display with headerComplete: WHERE folderId=? AND headerComplete=1 ORDER BY date
            // The ORIGINAL messageHeader_folderId (folderId) stays for simple folderId queries.
            // The ORIGINAL messageHeader_folderId_isRead (folderId, isRead) stays for unread counts.
            try db.create(
                index: "messageHeader_inbox_display",
                on: "messageHeader",
                columns: ["folderId", "headerComplete", "date"]
            )

            // Triage mode: WHERE folderId=? AND headerComplete=1 ORDER BY tagSortOrder, date
            try db.create(
                index: "messageHeader_triage_display",
                on: "messageHeader",
                columns: ["folderId", "headerComplete", "tagSortOrder", "date"]
            )

            // Embedding queue repopulate: WHERE embeddingComplete=0 AND bodyComplete=1
            try db.create(
                index: "messageHeader_embeddingStatus",
                on: "messageHeader",
                columns: ["embeddingComplete", "bodyComplete", "bodyEmptyConfirmed", "isInInbox", "date"]
            )

            // Update statistics so query planner makes good decisions with new indexes/column
            try db.execute(sql: "ANALYZE")
        }

        migrator.registerMigration("v39_restoreOriginalIndexes") { db in
            // v38 incorrectly DROPPED the original (folderId) and (folderId, isRead) indexes
            // and replaced them with composite indexes that broke unrelated queries.
            // Restore the originals — they serve unread counts, folder listings, etc.
            // The new headerComplete indexes from v38 are ADDITIVE (kept alongside).

            // Restore simple folderId index (used by folder count, basic folder queries)
            // Safe to create even if v38 didn't drop it (IF NOT EXISTS behavior)
            let hasOriginalFolderId = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master
                WHERE type='index' AND name='messageHeader_folderId'
                AND sql LIKE '%folderId)%' AND sql NOT LIKE '%headerComplete%'
            """) ?? false
            if !hasOriginalFolderId {
                // v38 replaced it with (folderId, headerComplete, date) — drop that, recreate original
                try? db.drop(index: "messageHeader_folderId")
                try db.create(index: "messageHeader_folderId", on: "messageHeader", columns: ["folderId"])
            }

            // Restore (folderId, isRead) index (used by unread count queries)
            let hasOriginalFolderRead = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master
                WHERE type='index' AND name='messageHeader_folderId_isRead'
                AND sql LIKE '%isRead)%' AND sql NOT LIKE '%headerComplete%'
            """) ?? false
            if !hasOriginalFolderRead {
                // v38 replaced it with (folderId, headerComplete, isRead, date) — drop, recreate original
                try? db.drop(index: "messageHeader_folderId_isRead")
                try db.create(index: "messageHeader_folderId_isRead", on: "messageHeader", columns: ["folderId", "isRead"])
            }

            // Re-ANALYZE with restored indexes
            try db.execute(sql: "ANALYZE")
        }

        migrator.registerMigration("v40_completeIndexCoverage") { db in
            // Full query audit found multiple hot-path queries without covering indexes.
            // Per ADR-IOS-029: never drop existing indexes, only add new ones.

            // P0: Search result lookup — messageId has no index, causing 250K scans per FTS result
            try db.create(index: "messageHeader_messageId_accountId",
                          on: "messageHeader", columns: ["messageId", "accountId"])

            // P0: Body queue repopulate ORDER BY date — idx_messageHeader_bodyStatus covers
            // WHERE but not ORDER BY. Extend with date to eliminate in-memory sort.
            // Keep the old bodyStatus index (used by other queries) — add a new one for repopulate.
            try db.create(index: "messageHeader_bodyRepopulate",
                          on: "messageHeader",
                          columns: ["isInInbox", "headerComplete", "bodyComplete", "bodyEmptyConfirmed", "date"])

            // P0: AI tool pagination — isInInbox + date for InboxReadTool OFFSET queries
            try db.create(index: "messageHeader_isInInbox_date",
                          on: "messageHeader", columns: ["isInInbox", "date"])

            // P1: Folder + date composite — used by maintenance pruning, FTS bulk indexing,
            // folder archive, and any folderId + ORDER BY date query
            try db.create(index: "messageHeader_folderId_date",
                          on: "messageHeader", columns: ["folderId", "date"])

            // P1: Thread detection — rfc822MessageId + date for ancestor/descendant walks
            try db.create(index: "messageHeader_rfc822MessageId_date",
                          on: "messageHeader", columns: ["rfc822MessageId", "date"])

            // P2: Sync stats — accountId + bodyComplete for backfill progress check
            try db.create(index: "messageHeader_accountId_bodyComplete",
                          on: "messageHeader", columns: ["accountId", "bodyComplete"])

            // P0: Reminder count — ChatPillState ValueObservation re-runs on EVERY
            // messageHeader write. Without this index, each re-run does a full 250K scan.
            // Also used by ReminderBuilder.collectMessageReminders().
            // Partial index: only rows with reminderContent (typically <100 rows).
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS messageHeader_reminderLookup
                ON messageHeader(isInInbox, isReplied)
                WHERE reminderContent IS NOT NULL
            """)

            // P0: AI queue repopulate — finds inbox messages needing AI processing.
            // Without this, scans all 10K+ inbox messages to find ~100 without AI.
            // Partial index: only rows that actually need AI work. As AI processes
            // each message, the row drops out of the index automatically.
            // At steady state this index has 0-100 rows.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS messageHeader_aiIncomplete
                ON messageHeader(date DESC)
                WHERE isInInbox = 1 AND bodyComplete = 1
                  AND (summaryBlurb IS NULL OR summaryBlurb = '' OR actionTag IS NULL OR cachedReply IS NULL)
            """)

            try db.execute(sql: "ANALYZE")
        }

        migrator.registerMigration("v41_addEmptyFetchCount") { db in
            // Track how many times a body fetch returned empty for a message.
            // Prevents false-positive bodyEmptyConfirmed from partial IMAP responses
            // (connection drops, BGTask cancellation). A single empty fetch no longer
            // confirms the message as empty — requires emptyFetchCount >= 2.
            try db.alter(table: "messageHeader") { t in
                t.add(column: "emptyFetchCount", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v42_addNotified") { db in
            // NSE notification tracking. Prevents double-notifying: if the NSE already
            // delivered an AI-classified notification for a message, the main app won't
            // post a duplicate local notification. Set by NSE (via staging DB merge) or
            // by main app after posting a local notification for "reply" emails.
            try db.alter(table: "messageHeader") { t in
                t.add(column: "notified", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v43_folderAccountIdRoleIndex") { db in
            // Covers UnreadCountManager.updateBadge() and NSEDataBridge's inbox
            // folderId resolution (WHERE role = 'inbox' [AND accountId IN ...]).
            // folder had no indexes previously.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS folder_accountId_role
                ON folder(accountId, role)
            """)
        }

        migrator.registerMigration("v44_messageAICacheKeyIndex") { db in
            // Covers account-deletion cleanup queries of the form
            //   DELETE FROM messageAICache WHERE key LIKE 'accountId:%'
            // Prefix LIKE (no leading '%') is index-seekable once key is indexed.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS messageAICache_key
                ON messageAICache(key)
            """)
        }

        // v45: Create pendingAIRefinement table for the BackfillAIQueue.
        // Durable snapshot of fire-and-forget AI refinement jobs (action tag teach,
        // KB refine on chat session end). PK = dedupKey so INSERT OR REPLACE
        // collapses re-enqueues of the same (jobType + identifying fields) in place.
        // Work-remaining state is "row exists"; drain deletes on success.
        migrator.registerMigration("v45_createPendingAIRefinement") { db in
            try db.create(table: "pendingAIRefinement") { t in
                t.primaryKey("dedupKey", .text)
                t.column("jobType", .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.column("createdAt", .integer).notNull()   // unix millis
            }
            // Covers repopulate FIFO (ORDER BY createdAt ASC) and TTL sweep
            // (WHERE createdAt < ?). Both walk a single btree.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_pendingAIRefinement_createdAt
                ON pendingAIRefinement(createdAt)
            """)
        }

        migrator.registerMigration("v46_addMissFetchCount") { db in
            // Count of consecutive times an IMAP batch fetch did not return the UID
            // for this header. After 5 misses the header is considered gone from the
            // server and the row is deleted. Reset to 0 on any successful body fetch.
            try db.alter(table: "messageHeader") { t in
                t.add(column: "missFetchCount", .integer).notNull().defaults(to: 0)
            }
        }

        // v47: Repair orphan computedThreadId values that missed a shared-ancestor
        // sibling on the original v27 walk. The original chain-walk only did
        // forward (rfc822 IN my.refs) and reverse (referencedRfc822Id == my.rfc822)
        // lookups, so Outlook/Exchange-rewritten threads where neither local copy
        // directly references the other — only a shared external ancestor — ended
        // up with each message keyed to its own rfc822MessageId (one group per
        // message). The fix is the unified forward+reverse+lateral lookup in
        // `ThreadUtils.findAdoptableThreadId`; this migration re-runs it for
        // every row whose computedThreadId is still the self-fallback.
        //
        // Rows whose computedThreadId adopted a parent (computedThreadId !=
        // rfc822MessageId AND != id) are left alone — those were correctly joined
        // on the first pass. Native-threadId rows (Gmail/Exchange) also have
        // computedThreadId = threadId != rfc822, so they're skipped.
        //
        // Oldest-first order so that once an earlier row adopts, later rows in
        // the same cluster can observe that adoption and converge on the same
        // thread key.
        migrator.registerMigration("v47_lateralThreadRepair") { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, rfc822MessageId, inReplyTo, referencesJSON FROM messageHeader
                WHERE computedThreadId != ''
                  AND (computedThreadId = rfc822MessageId OR computedThreadId = id)
                ORDER BY date ASC
            """)

            for row in rows {
                let id: String = row["id"]
                let rfc822: String? = row["rfc822MessageId"]
                let inReplyTo: String? = row["inReplyTo"]
                let refsJSON: String? = row["referencesJSON"]

                var references: [String] = []
                if let json = refsJSON, let data = json.data(using: .utf8),
                   let refs = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    references = refs
                }

                if let adopted = try ThreadUtils.findAdoptableThreadId(
                    myHeaderId: id,
                    rfc822MessageId: rfc822,
                    inReplyTo: inReplyTo,
                    references: references,
                    db: db
                ) {
                    try db.execute(sql: "UPDATE messageHeader SET computedThreadId = ? WHERE id = ?",
                                   arguments: [adopted, id])
                }
            }
        }

        migrator.registerMigration("v48_dedupFolderRoles") { db in
            // Heal accounts where multiple folders ended up with the same
            // non-custom role (iCloud's "Trash" + "Deleted Messages" both
            // matched the legacy name heuristic). Pick a winner per
            // (accountId, role) pair using the same canonical-name preference
            // as the runtime dedup; demote the rest to .custom. SPECIAL-USE
            // attributes aren't stored on disk, so this pass is name-only —
            // future syncs will not undo this because fullSync only updates
            // name/totalCount/uidNext, never role.
            let canonical: [String: [String]] = [
                "inbox":   ["inbox"],
                "sent":    ["sent", "sent messages", "sent items", "sent mail"],
                "drafts":  ["drafts", "draft"],
                "trash":   ["trash", "deleted messages", "deleted items", "bin"],
                "archive": ["archive", "archives", "all mail"],
                "spam":    ["junk", "spam", "junk e-mail", "bulk mail"]
            ]
            func rank(_ name: String, role: String) -> Int {
                guard let names = canonical[role],
                      let idx = names.firstIndex(of: name.lowercased()) else { return Int.max }
                return idx
            }

            let collisions = try Row.fetchAll(db, sql: """
                SELECT accountId, role
                FROM folder
                WHERE role != 'custom'
                GROUP BY accountId, role
                HAVING COUNT(*) > 1
            """)
            for collision in collisions {
                let accountId: String = collision["accountId"]
                let role: String = collision["role"]
                let folders = try Row.fetchAll(db, sql: """
                    SELECT id, name FROM folder
                    WHERE accountId = ? AND role = ?
                """, arguments: [accountId, role])
                let winner = folders.min { a, b in
                    let an: String = a["name"]
                    let bn: String = b["name"]
                    let ar = rank(an, role: role)
                    let br = rank(bn, role: role)
                    if ar != br { return ar < br }
                    return an.count < bn.count
                }
                guard let winnerId: String = winner?["id"] else { continue }
                for folder in folders {
                    let id: String = folder["id"]
                    if id == winnerId { continue }
                    try db.execute(
                        sql: "UPDATE folder SET role = 'custom' WHERE id = ?",
                        arguments: [id]
                    )
                }
            }
        }

        // v49: Add holdUntil + draftId columns to outboxMessage for undo-send.
        // holdUntil: wall-clock deadline before drain is allowed to claim
        //   (= queuedAt + outboxUndoHoldSeconds + outboxClaimBufferSeconds).
        //   Legacy rows (pre-v49) have NULL, treated as "no hold" by the gate.
        // draftId: the Draft row id associated with the send, used at claim time
        //   to fire deferred DraftStore.delete (so Undo can reopen compose with
        //   the exact draft contents).
        migrator.registerMigration("v49_addOutboxHoldAndDraftId") { db in
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "holdUntil", .datetime)
                t.add(column: "draftId", .text)
            }
        }

        // v50: Partial index for BackfillEmbeddingQueue repopulate + drop obsolete indexes.
        //
        // Observed issue: the full `messageHeader_embeddingStatus` index existed, but
        // EXPLAIN QUERY PLAN showed the planner picking `idx_messageHeader_bodyStatus`
        // with `ANY(headerComplete)` + `USE TEMP B-TREE FOR ORDER BY`, scanning most of
        // the table on every foreground return (1.4-4.2s for 0 rows).
        //
        // A partial index constrained to the exact query predicate eliminates the
        // ambiguity: rows either match the WHERE and are in the (small) index, or they
        // aren't and cost nothing. At steady state (all messages embedded) the index
        // holds 0 rows — seek is free regardless of planner stats.
        //
        // Drops:
        // - `messageHeader_embeddingStatus` (v38): fully superseded by the new partial
        //   index. Stale stats were actively misleading the planner.
        // - `idx_messageHeader_aiRepopulate` (v31): partial index `WHERE isInInbox=1
        //   AND bodyComplete=1` superseded by `messageHeader_aiIncomplete` (v40) which
        //   is strictly narrower (adds the AI-NULL predicates) and covers every known
        //   query that filters on `isInInbox=1 AND bodyComplete=1`.
        //
        // Re-ANALYZE after so planner sees the new landscape.
        migrator.registerMigration("v50_embeddingRepopulatePartialIndex") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS messageHeader_embeddingIncomplete
                ON messageHeader(isInInbox DESC, date DESC)
                WHERE embeddingComplete = 0 AND bodyComplete = 1 AND bodyEmptyConfirmed = 0
            """)
            try db.execute(sql: "DROP INDEX IF EXISTS messageHeader_embeddingStatus")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_messageHeader_aiRepopulate")
            try db.execute(sql: "ANALYZE")
        }

        // v51: Partial index for `recoverIncompleteHeaders`.
        //
        // Observed issue: `SELECT * FROM messageHeader WHERE headerComplete = 0 LIMIT 500`
        // was taking 2.0-2.6s for 0-row results. EXPLAIN QUERY PLAN showed `SCAN messageHeader`
        // — a full 250K row scan. Existing `idx_messageHeader_bodyStatus` has `headerComplete`
        // as leading column, but v38 defaulted all pre-existing rows to `headerComplete=TRUE`,
        // so stats show ~100% of rows match `headerComplete=1` and the planner won't commit
        // to index-seek + table-fetch for the (rare) `headerComplete=0` case.
        //
        // Same fix as v50: a partial index with WHERE clause matching the exact query
        // predicate. At steady state the partial holds 0 rows, so seek returns instantly.
        // When recovery IS needed (post-crash), the few pending rows are in the index
        // and still found quickly.
        migrator.registerMigration("v51_headerIncompletePartialIndex") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS messageHeader_headerIncomplete
                ON messageHeader(id)
                WHERE headerComplete = 0
            """)
            try db.execute(sql: "ANALYZE")
        }

        // v52: Add `type` column to chatHistory + backfill from chatTurn.
        //
        // v25 created chatHistory without `type`; chatTurn has had `type` since v6.
        // Memory search's role/type filter (matching KBRefinementService.buildChatHistory
        // which keeps role ∈ {user, assistant} AND type == "normal") is unsatisfiable
        // on the self-heal path without this column — non-normal assistant turns
        // (greeting / welcome_back / session_break) would pollute FTS.
        //
        // Backfill uses a correlated subquery on chatTurn's TEXT PRIMARY KEY
        // (AppDatabase.swift v6 at line 467) — O(log N) per probe, no table scan.
        // Eviction divergence: chatTurn is capped at ~100 rows (per-session budget in
        // ChatStore.appendTurn), chatHistory is capped at ~5000 (global "Memory" setting).
        // Historical chatHistory rows whose chatTurn was already evicted default to
        // 'normal' via COALESCE. That's a pragmatic default: most non-normal turns are
        // assistant-role with generic content (greetings etc.), so mis-classifying a
        // handful as 'normal' adds low-volume FTS noise, not garbage. Forward-new turns
        // post-migration get precise type via the updated ChatStore.appendTurn write.
        migrator.registerMigration("v52_addChatHistoryType") { db in
            try db.alter(table: "chatHistory") { t in
                t.add(column: "type", .text).notNull().defaults(to: "normal")
            }
            try db.execute(sql: """
                UPDATE chatHistory SET type = COALESCE(
                    (SELECT type FROM chatTurn WHERE chatTurn.id = chatHistory.id),
                    'normal'
                )
            """)
        }

        // One-shot historic backfill for the isReplied bug: every local parent
        // whose rfc822MessageId is the In-Reply-To of some local Sent-folder
        // reply gets isReplied = 1 (and a stale .reply action tag cleared).
        // Going-forward inserts use ReplyParentResolver.markParentsReplied;
        // this catches the historic backlog.
        migrator.registerMigration("v53_backfillIsRepliedFromSentReplies") { db in
            let count = try ReplyParentResolver.runHistoricBackfill(db: db)
            print("[v53] Backfilled isReplied for \(count) historic parents of Sent replies")
        }

        // v54: Merge fragmented Gmail/Exchange conversations.
        //
        // Gmail (and Exchange) sometimes splits what users perceive as one
        // thread into multiple native `threadId`s (subject change, time gap,
        // server-side heuristics). Pre-v54, `assignComputedThreadId` trusted
        // the native id verbatim, so the inbox showed those fragments as
        // separate rows even though their inReplyTo/References chain links
        // them. v54 (paired with the going-forward `chain-walk first` change
        // in `ThreadUtils.assignComputedThreadId`) re-evaluates every row:
        // if `findAdoptableThreadId` finds a connected message with a
        // different `computedThreadId`, the row adopts it.
        //
        // Iterates to fixpoint because `findAdoptableThreadId` returns the
        // first connected ctid (no ORDER BY), so a single pass over a chain
        // of 3+ messages with different ctids can leave the head of the
        // chain partially merged. Each pass propagates one hop further;
        // bounded by `maxPasses` as a safety guard against pathological
        // cases. Realistic email threads converge in 1-3 passes.
        migrator.registerMigration("v54_mergeFragmentedThreads") { db in
            let totalMerged = try ThreadUtils.runFragmentMergeToFixpoint(db: db)
            print("[v54] Merged \(totalMerged) fragmented thread rows")
        }

        // v55: Persist agent event calendar provenance so [Event](N) pills in
        // past chat sessions can re-fetch the live event from the right
        // calendar provider after app restart. Mirrors how email/contact/
        // template pills resolve — the realId (here: compoundId via idMap) is
        // persisted, and the popover queries the authoritative source live.
        // We deliberately do NOT snapshot title/dates/attendees: those come
        // straight from the calendar API on each tap, so renames or rescheds
        // by other clients show through immediately.
        migrator.registerMigration("v55_createChatEventCalendar") { db in
            try db.create(table: "chatEventCalendar") { t in
                t.primaryKey("compoundId", .text)
                t.column("accountId", .text).notNull()
                t.column("calendarId", .text).notNull()
                t.column("calendarName", .text)
            }
        }

        // v56: Demo Mode calendar event table.
        // Backs `DemoCalendarProvider`. All rows are wiped on demo exit
        // (DELETE FROM demoCalendarEvent — table-prefix scoping).
        // Times stored as INTEGER ms-since-epoch for consistency with the
        // calendar provider protocol's epoch-ms fields.
        migrator.registerMigration("v56_createDemoCalendarEvent") { db in
            try db.create(table: "demoCalendarEvent") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull()
                t.column("calendarId", .text).notNull()
                t.column("title", .text).notNull()
                t.column("location", .text)
                t.column("description", .text)
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
                t.column("allDay", .integer).notNull().defaults(to: 0)
                t.column("attendeesJSON", .text)
            }
            try db.create(index: "idx_demoCalendarEvent_account_start", on: "demoCalendarEvent", columns: ["accountId", "startMs"])
        }

        // v57: Repair optimistic Sent placeholders left behind by the prior bug
        // where insertOptimisticSentHeader did NOT set bodyComplete=1, even though
        // the body was already persisted to messageBody locally. Those rows match
        // BackfillBodyQueue's repopulate query (headerComplete=1 AND bodyComplete=0
        // AND isInInbox=0) on every cold start, and the queue then forwards the
        // synthetic "sent-<UUID>" id to the provider — Gmail/Graph reject it with
        // HTTP 400 "Invalid id value". The new prod write sets bodyComplete=1, but
        // existing rows on users' devices stay broken until SyncEngine delta-sync
        // happens to replace each one. This migration heals them in a single pass:
        // any "sent-%" placeholder that has a matching messageBody row gets
        // bodyComplete=1 immediately. Bounded — only touches rows that actually
        // have a body cached locally.
        migrator.registerMigration("v57_repairOptimisticSentBodyComplete") { db in
            try db.execute(sql: """
                UPDATE messageHeader
                SET bodyComplete = 1
                WHERE messageId LIKE 'sent-%'
                  AND headerComplete = 1
                  AND bodyComplete = 0
                  AND id IN (SELECT id FROM messageBody)
                """)
            let healed = db.changesCount
            if healed > 0 {
                print("[v57] Repaired bodyComplete on \(healed) optimistic Sent placeholders")
            }
        }

        // v58: one-time resync of tagSortOrder with actionTag.
        // The NSE→main-app merge UPDATE in NSEDataBridge.swift was setting
        // `actionTag` without writing `tagSortOrder`, leaving rows with
        // e.g. (actionTag='reply', tagSortOrder=99). Triage view sorts by
        // `ORDER BY tagSortOrder ASC, date DESC`, so those rows ended up at
        // the bottom even though the tag indicator rendered correctly. The
        // NSE write path is now fixed; this migration repairs already-stored
        // rows so existing inboxes don't keep showing the misplaced email.
        migrator.registerMigration("v58_resyncTagSortOrderFromActionTag") { db in
            try db.execute(sql: """
                UPDATE messageHeader
                SET tagSortOrder = CASE actionTag
                        WHEN 'reply'   THEN 0
                        WHEN 'none'    THEN 1
                        WHEN 'archive' THEN 2
                        WHEN 'delete'  THEN 3
                        ELSE 99
                    END
                WHERE tagSortOrder != CASE actionTag
                        WHEN 'reply'   THEN 0
                        WHEN 'none'    THEN 1
                        WHEN 'archive' THEN 2
                        WHEN 'delete'  THEN 3
                        ELSE 99
                    END
                """)
            let healed = db.changesCount
            if healed > 0 {
                print("[v58] Resynced tagSortOrder on \(healed) row(s)")
            }
        }
    }
}
