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

    /// Application Support directory that holds the production database.
    static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
    }

    /// Production database file URL.
    static var databaseURL: URL {
        directoryURL.appendingPathComponent("tabmail.sqlite")
    }

    /// Opens the production `DatabasePool` (creating the directory + file if
    /// needed) WITHOUT running migrations. Split from migration so startup can
    /// cheaply probe for pending migration work (`hasPendingMigrationWork`) and
    /// decide whether to show the "Updating…" splash BEFORE paying for the
    /// (possibly slow) migration passes. See `AppStartup`.
    /// The production DB configuration (WAL, synchronous=NORMAL, suspension-aware, manual
    /// checkpointing). Extracted from `makePool` so tests can assert the pragmas against a
    /// temp-path pool without touching the real DB file.
    static func makeConfiguration() -> Configuration {
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
        // WAL checkpointing is driven MANUALLY off the background maintenance path
        // (`SyncEngine.runWALMaintenance` → PASSIVE/TRUNCATE checkpoint), NOT by SQLite's
        // automatic page-count threshold. With autocheckpoint OFF, a foreground /
        // `.priority` write (the NSE→inbox merge, a user action) NEVER stalls doing a
        // checkpoint: the write that happened to cross the threshold used to eat a
        // ~1-2s PASSIVE checkpoint, seen as the merge "tic" lagging the paint by 1-2s.
        // Now checkpoints land only on `.background`, keeping the foreground path fast.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            // synchronous=NORMAL: WAL commits no longer fsync (only checkpoints do),
            // removing the per-commit fsync that stalled `merge.phase1` ~5s on cold-disk
            // foreground-return (that one commit's WAL fsync WAS the stall — see 4f3dacb).
            // NORMAL is corruption-safe and always consistent; a committed txn is durable
            // across app CRASH / KILL / clean reboot (the WAL is a persisted file, held by
            // the OS regardless of `synchronous`). It risks ONLY the last un-checkpointed
            // commits on an UNCLEAN power loss / kernel panic. That window is closed for
            // USER INTENT (PendingOperation / OutboxMessage) by `checkpointForDurability()`:
            // forced on `didEnterBackground` (fsync before the app suspends) and right after
            // `queueSend`. Cache writes (merge / sync / FTS-header) simply get fast commits.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return config
    }

    static func makePool() throws -> DatabasePool {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try DatabasePool(path: databaseURL.path, configuration: makeConfiguration())
    }

    /// True if migrating `pool` will do real work: pending GRDB schema
    /// migrations OR pending one-time data resets. Cheap + read-only (checks the
    /// migrator's applied set + the reset flags); `pool` must be freshly opened
    /// and not yet migrated. Callers gate the migration splash on this AND on the
    /// DB pre-existing — a fresh/empty DB migrates instantly so it never warrants
    /// the splash (see `AppStartup`). On a brand-new file the migrator reports
    /// "not completed", which is why the caller's pre-existing check matters.
    static func hasPendingMigrationWork(_ reader: some DatabaseReader) throws -> Bool {
        var migrator = DatabaseMigrator()
        registerAllMigrations(on: &migrator)
        let schemaComplete = try reader.read { try migrator.hasCompletedMigrations($0) }
        if !schemaComplete { return true }
        return !StartupMigrations.allResetsComplete
    }

    /// Designated initializer. Wraps an already-open `pool`, runs schema
    /// migrations, and — production only — the one-time destructive cached-mail
    /// resets. Migrations run BEFORE the pool is exposed (`AppDatabase.shared`)
    /// or the inbox observer is wired: DB opens → schema migrates → data resets
    /// → only THEN can sync / NSE merge / demo+screenshot seed touch it.
    /// `runStartupResets` is false for tests so they never mutate global
    /// UserDefaults flags or the FTS directory.
    init(pool: DatabasePool, runStartupResets: Bool) throws {
        self.dbPool = pool
        // Migration timing breadcrumb (RC2 / PLAN_HANG_FIX): the O(mailbox-size)
        // thread-repair migrations (v9/v27/v47/v53/v54) run here. A multi-second
        // value on a large mailbox after a multi-version jump IS the "hang on
        // boot" — log it so the field can confirm/deny. The gating splash
        // (AppStartup) keeps the UI honest while this runs.
        let migrateT0 = CFAbsoluteTimeGetCurrent()
        try Self.runMigrations(on: pool)
        BackgroundSyncLogger.log("AppDatabase: schema migrations completed in \(Int((CFAbsoluteTimeGetCurrent() - migrateT0) * 1000))ms")
        BootProfiler.mark("AppDatabase.migrate done in \(Int((CFAbsoluteTimeGetCurrent() - migrateT0) * 1000))ms")
        if runStartupResets {
            StartupMigrations.run(pool)
        }
        self.inboxNotificationObserver = try Self.makeInboxNotificationObserver(on: pool)
    }

    /// Test-only initializer: accepts an already-configured DatabasePool (e.g.
    /// temp-file) and runs schema migrations only — no destructive resets, so no
    /// global flag / FTS side effects. Not for production use.
    convenience init(dbPool: DatabasePool) throws {
        try self.init(pool: dbPool, runStartupResets: false)
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

    /// The raw GRDB pool. Use ONLY for GRDB APIs that require a `DatabasePool` /
    /// `DatabaseReader` (e.g. `ValueObservation.publisher(in:)`). For reads/writes
    /// prefer `dbPool` so priority is applied uniformly (see `PrioritizedDatabase`).
    static var rawPool: DatabasePool {
        shared.withLock { $0!.dbPool }
    }

    /// The app database chokepoint — every read/write flows through here. Its
    /// async writes run through `DatabaseWriteQueue` at `.priority` (the default
    /// tier), so foreground work — the NSE→inbox merge, optimistic user actions,
    /// the badge recount — jumps ahead of queued background writes in the single
    /// GRDB writer. See `PriorityGate`/`PrioritizedDatabase`/`DatabaseWriteQueue`.
    static var dbPool: PrioritizedDatabase {
        PrioritizedDatabase(pool: rawPool)
    }

    /// `.normal`-tier chokepoint for foreground SYNC — full / delta / pull-down sync,
    /// on-demand folder sync, infinite-scroll pagination. Beats the deep background
    /// filling queues (`.background`) in the write scheduler but yields to the merge
    /// and to a live user action (`.priority`). Used as `SyncEngine.dbPool`, so sync
    /// writes are `.normal` even when issued from a `Task.detached` — the pool's own
    /// tier survives the task-local loss a `PriorityGate.normal { }` override would not.
    static var syncPool: PrioritizedDatabase {
        PrioritizedDatabase(pool: rawPool, priority: .normal)
    }

    /// `.background`-tier chokepoint for the heavy background FILLING queues (reply
    /// precompute, embedding, body/header backfill, maintenance, FTS self-heal,
    /// drain-loop reconciliation). Its async writes run last in the write
    /// scheduler, so foreground/`.normal` work is never queued behind them.
    static var backgroundPool: PrioritizedDatabase {
        PrioritizedDatabase(pool: rawPool, priority: .background)
    }

    /// Force-fsync the WAL so `synchronous=NORMAL` commits become durable on disk NOW.
    /// NORMAL never fsyncs per commit (only checkpoints do), so an un-checkpointed commit
    /// can be lost on an UNCLEAN power loss. This closes that window for USER INTENT by
    /// checkpointing at the two moments intent must be hardened: just before the app
    /// suspends (`didEnterBackground`) and right after a send is queued.
    ///
    /// PASSIVE, not TRUNCATE: on synchronous=NORMAL every checkpoint fsyncs the WAL first
    /// (SQLite: "the WAL file is synchronized before each checkpoint"), so PASSIVE already
    /// hardens every committed frame — which is all durability needs. TRUNCATE additionally
    /// RESETS the WAL, which BLOCKS on all readers draining: a device capture showed
    /// TRUNCATE taking 7.6s while the 5-account sync herd held read snapshots. This runs on
    /// the RAW pool (SQLite-serialized with the writer), so a blocking TRUNCATE after a send
    /// would stall the next merge/sync write for seconds. PASSIVE never waits on readers.
    /// WAL shrink stays the background maintenance's job (`checkpointWALThrottled(truncate:)`).
    /// Best-effort: a suspended DB skips it (the next checkpoint covers it).
    static func checkpointForDurability() async {
        guard !DatabaseSuspension.isSuspended else { return }
        _ = try? await rawPool.writeWithoutTransaction { db in
            _ = try? Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(PASSIVE)")
        }
    }

    // MARK: - NSE Staging Database

    /// Staging schema version. BUMP whenever the `nse_processed_message` column
    /// set (or the sibling tables) change in `createNSEStagingDB`. The main app
    /// is the SOLE migrator of this schema — the NSE assumes it already exists
    /// (see `NSEStagingDB`) — so a bump takes effect on the next main-app launch,
    /// before the NSE relies on the new columns. Current = 6 ("populated" flag).
    private static let nseStagingSchemaVersion = 6
    private static let nseStagingSchemaVersionKey = "nse.stagingSchemaVersion"

    /// Create the NSE staging database schema in the App Group container.
    /// The NSE extension reads/writes this DB. Idempotent + version-gated: a no-op
    /// once the file exists at the current `nseStagingSchemaVersion`.
    static func createNSEStagingDBIfNeeded() {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.ai.tabmail"
        ) else {
            print("[AppDatabase] App Group container not available — NSE staging DB not created")
            return
        }
        let path = url.appendingPathComponent("nse_staging.sqlite").path
        // Skip the CREATE/ALTER storm (and its cross-process write lock) when the
        // staging file already exists at the current schema version. The schema is
        // append-only + idempotent, but re-running ~20 `ALTER TABLE` on EVERY
        // launch is pure waste — each one fails with "duplicate column" (the
        // logmain.log noise) and, worse, takes the staging DB's write lock, which
        // blocks up to 2s when an NSE is mid-write on a fresh push. The version
        // marker lives in the App Group suite (same container as the file → both
        // are wiped together on uninstall, so they can't drift). Gated off the
        // production path only; the parameterized core stays ungated for unit tests.
        let suite = UserDefaults(suiteName: "group.ai.tabmail")
        if FileManager.default.fileExists(atPath: path),
           suite?.integer(forKey: nseStagingSchemaVersionKey) == nseStagingSchemaVersion {
            return
        }
        if createNSEStagingDB(atPath: path) {
            suite?.set(nseStagingSchemaVersion, forKey: nseStagingSchemaVersionKey)
        }
    }

    /// Schema-creation core, parameterized by path. Production resolves the App
    /// Group container path via `createNSEStagingDBIfNeeded`; the NSE-merge unit
    /// tests (whose host has no app-group entitlement, so the container path is
    /// unavailable) build a real staging DB at a temp path so they can drive the
    /// real `NSEDataBridge.mergeNSEStagingData`.
    /// Returns `true` only if the schema was applied successfully — the
    /// production caller (`createNSEStagingDBIfNeeded`) gates the version marker
    /// on this so a failed open/write retries on the next launch instead of being
    /// permanently skipped.
    @discardableResult
    static func createNSEStagingDB(atPath path: String) -> Bool {
        var config = Configuration()
        config.busyMode = .timeout(2)
        // 0xdead10cc defense (ADR-IOS-041). Non-WAL queue: ALL accesses abort
        // while suspended — schema setup is launch-time-only, so this is inert
        // in practice but keeps every main-app connection covered.
        config.observesSuspensionNotifications = true
        guard let db = try? DatabaseQueue(path: path, configuration: config) else {
            print("[AppDatabase] Failed to open NSE staging DB")
            return false
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
            return true
        } catch {
            print("[AppDatabase] Failed to create NSE staging DB schema: \(error)")
            return false
        }
    }

    // MARK: - Migrations

    /// Run all migrations on an arbitrary DatabaseWriter (used by tests with in-memory DB).
    static func runMigrations(on writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        registerAllMigrations(on: &migrator)
        try migrator.migrate(writer)
    }

    /// One-time heal for ADR-IOS-042 (IMAP Archive "missing months" data-loss):
    /// reset backfill state so affected folders RE-WALK and re-fetch the headers the
    /// pre-fix date-window stale detection deleted. Now that stale detection uses a
    /// UID window (`SyncEngine.selectStaleHeaders`), the re-fetched mail survives.
    /// Scope: archive-role folders on IMAP accounts only — Gmail/Exchange use a
    /// date-ordered fetch (never affected) and inbox/sent/trash are chronological
    /// (UID≈date, never affected). Shared by the v59 migration and its test so the
    /// scoping SQL has a single source. Returns the number of folders reset.
    @discardableResult
    static func rewalkImapArchiveFolders(_ db: Database) throws -> Int {
        try db.execute(sql: """
            UPDATE folder SET
                backfillComplete = 0,
                backfillUidCursor = NULL
            WHERE role = ?
              AND accountId IN (SELECT id FROM account WHERE provider = ?)
            """, arguments: [FolderRole.archive.rawValue, AccountProvider.imap.rawValue])
        return db.changesCount
    }

    // MARK: - Migration Definitions

    /// Every schema migration, in order. Registered through
    /// `DatabaseMigrator.registerTimedMigration` (bottom of this file) — a
    /// pass-through wrapper that adds a debug-gated per-migration duration line
    /// and forwards the identifier and body to GRDB unchanged.
    ///
    /// The identifier strings and bodies below are what GRDB records in
    /// `grdb_migrations`: **immutable once applied**. Never edit an applied
    /// migration — add a new one.
    static func registerAllMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerTimedMigration("v1_createTables") { db in
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
        migrator.registerTimedMigration("v2_dropMessageHeaderFolderFK", foreignKeyChecks: .deferred) { db in
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
        migrator.registerTimedMigration("v3_createOutboxMessage") { db in
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
        migrator.registerTimedMigration("v4_addOutboxSentAt") { db in
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "sentAt", .datetime)
            }
        }

        // v5: Add isPrimary column to account — explicit primary account for compose default.
        migrator.registerTimedMigration("v5_addAccountIsPrimary") { db in
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
        migrator.registerTimedMigration("v6_createChatTurn") { db in
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
        migrator.registerTimedMigration("v7_addChatTurnRenderedContent") { db in
            try db.alter(table: "chatTurn") { t in
                t.add(column: "renderedContent", .text)
            }
        }

        // v8: Pending calendar operation queue — crash-safe calendar mutations.
        // Mirrors PendingOperation pattern: persist before acknowledging, drain async.
        migrator.registerTimedMigration("v8_createPendingCalendarOperation") { db in
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
        migrator.registerTimedMigration("v9_backfillThreadIds") { db in
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
        migrator.registerTimedMigration("v10_addCcBcc") { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "cc", .text).notNull().defaults(to: "")
                t.add(column: "bcc", .text).notNull().defaults(to: "")
            }
        }

        // v11: Add sessionId to chatTurn — groups turns into sessions for swipe-navigable
        // history in the chat pill. Existing turns keep NULL sessionId (visible in Settings
        // Chat History only, not in pill session navigation).
        migrator.registerTimedMigration("v11_addChatTurnSessionId") { db in
            try db.alter(table: "chatTurn") { t in
                t.add(column: "sessionId", .text)
            }
            try db.create(index: "chatTurn_sessionId", on: "chatTurn", columns: ["sessionId"])
        }

        // v12: Persistent ID mapping for ChatIdTranslator — survives app restart so that
        // pill references ([Email](N)) in old sessions remain resolvable.
        migrator.registerTimedMigration("v12_createChatIdMapping") { db in
            try db.create(table: "chatIdMapping") { t in
                t.primaryKey("numericId", .integer)
                t.column("realId", .text).notNull().unique()
            }
        }

        // v13: Add inReplyTo column to messageHeader — RFC 2822 In-Reply-To header
        // for header-based thread detection (replaces subject heuristic).
        migrator.registerTimedMigration("v13_addMessageHeaderInReplyTo") { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "inReplyTo", .text)
            }
            try db.create(index: "messageHeader_inReplyTo", on: "messageHeader", columns: ["inReplyTo"])
        }

        // v14: Add backfillUidCursor column to folder — IMAP backfill walks backward
        // from UIDNEXT by UID range instead of date-windowed SEARCH.
        // Seed cursor for in-progress IMAP backfills from MIN(messageId) where messageId is numeric (UID).
        migrator.registerTimedMigration("v14_addFolderBackfillUidCursor") { db in
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
        migrator.registerTimedMigration("v15_addFolderBackfillPageToken") { db in
            try db.alter(table: "folder") { t in
                t.add(column: "backfillPageToken", .text)
            }
        }

        // v16: CalDAV support — config table + calendarOnly flag on account.
        migrator.registerTimedMigration("v16_createCalDAVConfig") { db in
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

        migrator.registerTimedMigration("v17_addCalendarOnlyToAccount") { db in
            try db.alter(table: "account") { t in
                t.add(column: "calendarOnly", .boolean).notNull().defaults(to: false)
            }
        }

        // v18: Persistent sent-folder append for IMAP — after SMTP send succeeds,
        // the outbox message stays alive until the copy is appended to the Sent folder.
        // sentMessageId: RFC822 Message-ID generated before send (used for dedup on retry).
        // appendedToSent: false until IMAP APPEND (or Gmail/Exchange auto-save) confirms.
        migrator.registerTimedMigration("v18_addOutboxSentAppend") { db in
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "sentMessageId", .text)
                t.add(column: "appendedToSent", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerTimedMigration("v19_addMessageBodyIcsText") { db in
            try db.alter(table: "messageBody") { t in
                t.add(column: "icsText", .text)
            }
        }

        // v20: Add remindersSnapshot to chatTurn — stores the reminder list shown when a session
        // started, as JSON. Only populated on the first turn of each session. Enables read-only
        // reminder display when viewing past sessions.
        migrator.registerTimedMigration("v20_addChatTurnRemindersSnapshot") { db in
            try db.alter(table: "chatTurn") { t in
                t.add(column: "remindersSnapshot", .text)
            }
        }

        // v21: Composite index for efficient unread count queries.
        // COUNT(*) WHERE folderId = ? AND isRead = 0 is a covering index scan
        // instead of index lookup + row filter.
        migrator.registerTimedMigration("v21_addUnreadCountIndex") { db in
            try db.create(index: "messageHeader_folderId_isRead", on: "messageHeader", columns: ["folderId", "isRead"])
        }

        // v22: Email context snapshot for message-detail chat sessions.
        // Stores the email being discussed (subject, from, messageHeaderId) on the first
        // turn of a message-detail session so past sessions show which email was discussed.
        migrator.registerTimedMigration("v22_addChatTurnEmailContext") { db in
            try db.alter(table: "chatTurn") { t in
                t.add(column: "emailContextJSON", .text)
            }
        }

        // v23: Draft persistence for compose sessions.
        // Stores draft state (to/cc/bcc/subject/body) + edit history so compose chat
        // can resume on reopen. Tied to reply/forward via replyToId, or new compose via UUID key.
        migrator.registerTimedMigration("v23_createDraft") { db in
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
        migrator.registerTimedMigration("v24_addServerDraftSync") { db in
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
        migrator.registerTimedMigration("v25_createChatHistory") { db in
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
        migrator.registerTimedMigration("v26_addMessageHeaderReferences") { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "referencesJSON", .text)
            }
        }

        // v27: Add computedThreadId + messageReference junction table for unified thread grouping.
        // computedThreadId: assigned once at insert time. Gmail/Exchange: copied from native threadId.
        // IMAP: computed by chain-walking inReplyTo/References in the DB.
        // messageReference: junction table for indexed reverse lookups of References header.
        migrator.registerTimedMigration("v27_computedThreadId") { db in
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
        migrator.registerTimedMigration("v28_addPendingCalendarOpCalendarId") { db in
            try db.alter(table: "pendingCalendarOperation") { t in
                t.add(column: "calendarId", .text)
            }
        }

        migrator.registerTimedMigration("v29_addChatTurnThinkingContent") { db in
            try db.alter(table: "chatTurn") { t in
                t.add(column: "thinkingContent", .text)
            }
        }

        // v30: Reset backfill state for all folders to re-walk with robust cursor.
        // The old cursor could advance past failed ranges, permanently skipping messages.
        // Re-walking with the new claim/confirm model ensures nothing is missed.
        // Existing messages are preserved — dedup in insertBackfillBatch handles duplicates.
        migrator.registerTimedMigration("v30_resetBackfillForRobustCursor") { db in
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
        migrator.registerTimedMigration("v31_addHasBodyInFTS") { db in
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
        migrator.registerTimedMigration("v32_createPendingRender") { db in
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
        migrator.registerTimedMigration("v33_userLabelSupport") { db in
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

        migrator.registerTimedMigration("v34_addConfirmedEmptyBody") { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "confirmedEmptyBody", .boolean).notNull().defaults(to: false)
            }
            try db.create(
                index: "idx_messageHeader_bodyStatus",
                on: "messageHeader",
                columns: ["bodyComplete", "confirmedEmptyBody"]
            )
        }

        migrator.registerTimedMigration("v35_addHasEmbedding") { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "hasEmbedding", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerTimedMigration("v36_renameBodyFlags") { db in
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

        migrator.registerTimedMigration("v37_bodyStatusIndexWithInbox") { db in
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

        migrator.registerTimedMigration("v38_addHeaderComplete") { db in
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

        migrator.registerTimedMigration("v39_restoreOriginalIndexes") { db in
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

        migrator.registerTimedMigration("v40_completeIndexCoverage") { db in
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

        migrator.registerTimedMigration("v41_addEmptyFetchCount") { db in
            // Track how many times a body fetch returned empty for a message.
            // Prevents false-positive bodyEmptyConfirmed from partial IMAP responses
            // (connection drops, BGTask cancellation). A single empty fetch no longer
            // confirms the message as empty — requires emptyFetchCount >= 2.
            try db.alter(table: "messageHeader") { t in
                t.add(column: "emptyFetchCount", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerTimedMigration("v42_addNotified") { db in
            // NSE notification tracking. Prevents double-notifying: if the NSE already
            // delivered an AI-classified notification for a message, the main app won't
            // post a duplicate local notification. Set by NSE (via staging DB merge) or
            // by main app after posting a local notification for "reply" emails.
            try db.alter(table: "messageHeader") { t in
                t.add(column: "notified", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerTimedMigration("v43_folderAccountIdRoleIndex") { db in
            // Covers UnreadCountManager.updateBadge() and NSEDataBridge's inbox
            // folderId resolution (WHERE role = 'inbox' [AND accountId IN ...]).
            // folder had no indexes previously.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS folder_accountId_role
                ON folder(accountId, role)
            """)
        }

        migrator.registerTimedMigration("v44_messageAICacheKeyIndex") { db in
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
        migrator.registerTimedMigration("v45_createPendingAIRefinement") { db in
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

        migrator.registerTimedMigration("v46_addMissFetchCount") { db in
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
        migrator.registerTimedMigration("v47_lateralThreadRepair") { db in
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

        migrator.registerTimedMigration("v48_dedupFolderRoles") { db in
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
        migrator.registerTimedMigration("v49_addOutboxHoldAndDraftId") { db in
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
        migrator.registerTimedMigration("v50_embeddingRepopulatePartialIndex") { db in
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
        migrator.registerTimedMigration("v51_headerIncompletePartialIndex") { db in
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
        migrator.registerTimedMigration("v52_addChatHistoryType") { db in
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
        migrator.registerTimedMigration("v53_backfillIsRepliedFromSentReplies") { db in
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
        migrator.registerTimedMigration("v54_mergeFragmentedThreads") { db in
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
        migrator.registerTimedMigration("v55_createChatEventCalendar") { db in
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
        migrator.registerTimedMigration("v56_createDemoCalendarEvent") { db in
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
        migrator.registerTimedMigration("v57_repairOptimisticSentBodyComplete") { db in
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
        migrator.registerTimedMigration("v58_resyncTagSortOrderFromActionTag") { db in
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

        // v59: Heal the IMAP Archive "missing months" data-loss (ADR-IOS-042). The
        // pre-fix stale detection used a DATE overlap window on IMAP's UID-ordered
        // fetch, so archiving an old-dated email (fresh high UID) dragged the date
        // floor back and deleted mid-range months from the Archive folder. The code
        // fix (SyncEngine.selectStaleHeaders → UID window) stops further deletion;
        // this one-time reset re-walks the affected folders so the deleted headers are
        // re-fetched from the server and now survive. Ships in the SAME build as the
        // fix — without the fix, the re-walked mail would just be deleted again.
        migrator.registerTimedMigration("v59_rewalkImapArchiveAfterStaleWindowFix") { db in
            let reset = try AppDatabase.rewalkImapArchiveFolders(db)
            if reset > 0 {
                print("[v59] Reset backfill for \(reset) IMAP archive folder(s) — re-fetching stale-window-deleted mail")
            }
        }

        // v60: Persist the Gmail conversation id on queued sends so a reply/forward
        // files into the source thread on Gmail web. The value survives app
        // relaunch (outbox drain re-sends with the same binding). Gmail REST send
        // only; IMAP/Exchange thread via In-Reply-To/References headers. See
        // PLAN_THREAD_FIX.md / ADR-IOS-043.
        migrator.registerTimedMigration("v60_addOutboxThreadId") { db in
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "threadId", .text)
            }
        }

        migrator.registerTimedMigration("v61_addCalendarSetupFailedToAccount") { db in
            try db.alter(table: "account") { t in
                t.add(column: "calendarSetupFailed", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerTimedMigration("v62_inboxQueryUnreadDateIndex") { db in
            // The UNREAD-filter inbox query is `WHERE folderId=? AND isRead=false
            // ORDER BY date DESC LIMIT N` (InboxViewModel fetchPage/fetchFullRange).
            // `messageHeader_folderId_date` (folderId,date) ALREADY exists and covers
            // the NON-filtered list; `messageHeader_folderId_isRead` (folderId,isRead,
            // v21) exists for the unread COUNT but lacks `date`, so the unread LIST
            // still seeks (folderId,isRead=0) then SORTS by date. This (folderId,
            // isRead,date) composite lets it seek + scan in date order and stop at
            // LIMIT — no sort — so a huge folder (Gmail "All Mail") doesn't block the
            // synchronous @MainActor `fetchPage` read when the unread filter is on.
            //
            // ⚠️ DATE here is DISPLAY-ONLY (the list is ordered by date for human
            // reading). DO NOT reuse a date window/cursor for IMAP *sync* decisions —
            // UID and message-date are decorrelated and a date window over-deletes the
            // Archive (ADR-IOS-042 data-loss; CLAUDE.md Data Integrity rule 4). Sync
            // stale/cursor logic windows by UID via `selectStaleHeaders` /
            // `staleWindowMode`, NOT this index.
            //
            // IF NOT EXISTS is REQUIRED: building a composite index on a HUGE folder
            // is slow and can be interrupted by DB suspension (ADR-IOS-041) / an app
            // kill AFTER the index commits but BEFORE GRDB records the migration —
            // a non-idempotent re-run would hit "index already exists" and BRICK the
            // whole DB build (stuck on the migration splash). (The original v62 also
            // tried to CREATE the already-existing `messageHeader_folderId_date` —
            // that NAME COLLISION is what bricked it; that duplicate is removed here.)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS messageHeader_folderId_isRead_date ON messageHeader(folderId, isRead, date)")
        }

        migrator.registerTimedMigration("v63_addFolderUidValidity") { db in
            // ADR-IOS-051: UIDVALIDITY abort guard for the IMAP deletion-reconcile
            // walk. Nullable — bootstrapped by the folder's first reconcile walk;
            // a later mismatch aborts the walk (local UIDs would be from an
            // invalidated numbering — never delete on uncertainty).
            try db.alter(table: "folder") { t in
                t.add(column: "lastKnownUidValidity", .integer)
            }
        }

        migrator.registerTimedMigration("v64_messageIdCompositeIndexes") { db in
            // Sync/NSE HOT PATH: two-column-equality lookups keyed on `messageId` run
            // ONCE PER fetched/pushed message inside write transactions. The predicate
            // is indexed only on the OTHER column (folderId or accountId), so the
            // on-device planner seeks that single column and SCANS-AND-FILTERS messageId
            // — a covering-index folder/account scan. Harmless on small folders;
            // catastrophic on Gmail "All Mail" (tens of thousands of rows): boot_logs 7
            // measured recon≈loop≈4233ms for 45 msgs (~94ms per 1-ROW lookup), which
            // holds the single GRDB writer and serializes every other write behind it.
            // (The `canonicalizeLookupUsesIndex` test passed regardless: "USING INDEX
            // messageHeader_folderId" satisfies "not a SCAN" — yet it IS a folder scan.)
            //
            // Two lookup shapes → two composites, each an EXACT 2-column-equality match
            // the planner prefers over the single-column index → a direct seek:
            //   • WHERE folderId=? AND messageId=?  — SyncEngineFullSync canonicalize
            //     (:385) / recon (:856), SyncEngine (:579), delta (:165), plus the
            //     `folderId=? AND messageId IN(…)` chunk lookups (reconcile/self-heal/
            //     backfill).
            //   • WHERE accountId=? AND messageId=? — NSE merge (:801/1024/1560/2364),
            //     AppDelegate (:143), Search/Undo/InboxView/FTS by-account lookups.
            //     These search by ACCOUNT deliberately (to find a header that MOVED
            //     folders via UID remap) — they must NOT be narrowed to folderId.
            //
            // (accountId, messageId)'s LEADING column serves every accountId-only query
            // the single-column `messageHeader_accountId` did (and `messageHeader_
            // accountId_bodyComplete` already leads with accountId too), so that index
            // is redundant → dropped. Net +1 index, not +2 — minimizing write
            // amplification on the very table this migration is speeding up.
            //
            // IF (NOT) EXISTS is REQUIRED (see v62): a suspension/kill AFTER a statement
            // commits but BEFORE GRDB records the migration would re-run and hit
            // "already exists" / "no such index", bricking the DB build.
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS messageHeader_folderId_messageId ON messageHeader(folderId, messageId)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS messageHeader_accountId_messageId ON messageHeader(accountId, messageId)")
            try db.execute(sql: "DROP INDEX IF EXISTS messageHeader_accountId")
        }

        migrator.registerTimedMigration("v65_addFolderHighestModSeq") { db in
            // IMAP CONDSTORE (RFC 7162) flag-aware change cursor. Lets delta sync detect
            // \Seen/flag changes on EXISTING messages (which uidNext+count miss — the
            // latent "read-on-another-client doesn't propagate on IMAP" bug) and lets
            // full sync SKIP fetching provably-unchanged folders. Nullable; bootstrapped
            // by the first STATUS on a CONDSTORE server (nil → uidNext+count fallback).
            try db.alter(table: "folder") { t in
                t.add(column: "lastKnownHighestModSeq", .integer)
            }
        }

        migrator.registerTimedMigration("v66_folderIdUidIntIndex") { db in
            // Stale-detection windowed slice (SyncEngineFullSync :737) for LARGE IMAP
            // folders: `WHERE folderId=? AND CAST(messageId AS INTEGER) >= ?` — a numeric
            // UID range that NO text index serves (v64's (folderId, messageId) is
            // lexicographic, not numeric), so it SCANNED the whole folder (tens of
            // thousands of rows on Archive / All Mail) and held the GRDB writer through
            // stale detection. This EXPRESSION index turns it into a folderId seek + UID
            // range-scan. Non-numeric messageIds (Gmail/Exchange) index as CAST=0 — benign;
            // those providers use the `.date` stale window, not this query.
            //
            // IF NOT EXISTS is REQUIRED (see v62): a suspension/kill after the index
            // commits but before GRDB records the migration would re-run and brick.
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS messageHeader_folderId_uidInt ON messageHeader(folderId, CAST(messageId AS INTEGER))")
        }

        migrator.registerTimedMigration("v67_addUidResolutionRetryCount") { db in
            // Historical RFC-resolution retry budget. The column remains because
            // this migration shipped; provider-ID actions leave it dormant.
            try db.alter(table: "pendingOperation") { t in
                t.add(column: "uidResolutionRetryCount", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerTimedMigration("v68_addFolderUidValidityResetPending") { db in
            // T4.S6 — the UIDVALIDITY purge-and-resync reaction's own quarantine
            // state. Non-nil ⇒ `AccountManager.runUidValidityResetReaction` armed
            // this folder and has not yet stamped the fresh epoch. Nullable with no
            // default: every existing folder starts un-quarantined, which is the
            // correct pre-migration state (no reaction has ever run).
            //
            // This column is what makes every abort leg of the reaction RETRYABLE
            // rather than fire-once: the flag stays set on abort, and full sync's
            // per-folder loop re-drives on it. See `Folder.uidValidityResetPendingAt`.
            try db.alter(table: "folder") { t in
                t.add(column: "uidValidityResetPendingAt", .datetime)
            }
        }

        migrator.registerTimedMigration("v69_addPendingOperationObservedUidValidity") { db in
            // T4.S6 follow-up — the admission-time UIDVALIDITY stamp for a durable op
            // that will be executed by BARE UID (see `PendingOperation
            // .observedUidValidity`). Nullable, no default and no backfill: a
            // pre-migration row simply has no stamp, so the claim-time compare in
            // `AccountManager.drainPendingQueue` skips it and the op behaves exactly
            // as it does today (fail open). Those rows drain within one session and
            // carry only the pre-existing residual.
            //
            // PORTED from the reference's `v74_addPendingOperationObservedUidValidity`
            // (`v2final:TabMail/Services/AppDatabase.swift`) — same column, same type,
            // same nullable/no-backfill policy. The number differs because v3's
            // migration ceiling is v68; v2final's v68–v91 range is IRRELEVANT here
            // (that line never shipped, so no device carries it) and deliberately
            // NOT skipped.
            try db.alter(table: "pendingOperation") { t in
                t.add(column: "observedUidValidity", .integer)
            }
        }

        migrator.registerTimedMigration("v70_dropMessageBodyHeaderFK") { db in
            // #37 Stage D. `messageBody.id` is a CONTENT key, not a header id
            // (`ContentKeySpace`). Once its tail becomes the RFC 822 Message-ID at
            // Stage E1 the reference is invalid in BOTH directions: the FK REJECTS
            // the insert outright (`FOREIGN KEY constraint failed` on every body
            // write for every rfc-having IMAP/iCloud message), and where a row does
            // exist the cascade deletes content still owned by the other N−1 headers
            // — below the application layer, where `MessageContentStore` cannot veto
            // it. Ownership is answered by `MessageContentStore` from here on.
            //
            // NO key is re-written here. v3 changes only what NEW content keys are
            // minted, so every surviving key stays byte-identical and there is no
            // bulk re-key (that is what `PLAN_RFC_KEY_MIGRATION_ADR062.md` §4
            // describes for the LARGER design — re-keying `messageHeader.id` itself
            // — which v3 does not do).
            //
            // `messageReference.messageHeaderId` and `messageUserLabel.messageId`
            // KEEP their cascades deliberately: both are header-space rows (threading
            // references, the user-label junction), neither moves to the content key
            // space, and nothing would reclaim them if the cascade were dropped.
            // Do not "complete" Stage D by removing those.
            //
            // ── WHY DROP-AND-RECREATE, AND WHY LOSING THE CACHE IS ACCEPTABLE ──
            //
            // SQLite has no `ALTER TABLE … DROP CONSTRAINT` and GRDB offers no
            // drop-FK helper, so the constraint can only leave with the table that
            // declares it. `messageBody` is a RE-FETCHABLE CACHE of rendered email
            // HTML — every row can be rebuilt from the server, and the app already
            // discards these rows routinely and by design (`runEvictStaleBodies`
            // TTL sweep, `BodyAssetMaintenance.evictIfOverCap` LRU,
            // `runPruneIfOverBudget`). Dropping all of it is therefore the SAME
            // class of event those sweeps produce every day, not a new one, and the
            // OWNER HAS EXPLICITLY ACCEPTED the one-time cache loss on upgrade.
            //
            // Measured: drop+create is 0.319 s with ZERO extra disk, and the
            // freelist those pages return to is consumed again as the cache refills
            // — so the file never grows and no `VACUUM` is ever needed.
            //
            // The two alternatives were costed and REJECTED:
            // - The textbook 12-step rebuild (`v2_dropMessageHeaderFolderFK` here,
            //   `v71_accountScopeUserLabels` on `v2final`) preserves the rows but
            //   measured ~11 s for a 2 GB body table on a Mac — 2–4× worse on
            //   device — needs ≈3× the table free at peak, and leaves the file at
            //   ≈2× until a `VACUUM` the app never runs outside `AppDataWiper`.
            //   That permanent growth feeds `StorageEstimator.totalSizeMB()` →
            //   `isOverBudget()` → `SyncEngine.runPruneIfOverBudget`, which deletes
            //   `MessageHeader` ROWS oldest-first: a schema-only migration causing
            //   MESSAGE pruning. `StorageEstimator.defaultBudgetMB == Int.max`, so
            //   this table is unbounded and multi-GB is normal. On a device without
            //   3× headroom it cannot complete at all — the app loops at the
            //   "Updating…" splash, which is this app's documented boot-hang shape
            //   (see the `PLAN_HANG_FIX` note above).
            // - An in-place `sqlite_master` DDL edit via `PRAGMA writable_schema`
            //   would have been ~0 s and lossless, but it is BLOCKED: Apple's system
            //   SQLite ships `SQLITE_DBCONFIG_DEFENSIVE = 1` by default, which makes
            //   `PRAGMA writable_schema = ON` a SILENT no-op (measured three ways).
            //   Clearing it needs a C shim; the owner declined that dependency.
            //
            // ── WHAT MUST **NOT** BE "REPAIRED" ALONGSIDE THIS ──
            //
            // `messageHeader.bodyComplete` is NOT reset, and that is deliberate. It
            // is the FTS-indexed truth (backfill completion / `pendingBodyCount` /
            // AI + embedding gating), NOT an assertion that a cached row exists —
            // exactly as stated by the type-level INVARIANT (2026-07-02) on
            // `BodyAssetMaintenance`, which this migration is bound by. Flipping it
            // re-enqueues every victim into the backfill body queue, which re-fetches
            // the bodies, which re-fills the cache past its cap, which evicts again:
            // the "indexing goes backwards" infinite refetch loop. "HTML cache
            // present" needs no flag — the `messageBody` row's existence IS that
            // state, and every reader already computes it live
            // (`MessageDetailViewModel.loadThreadMessageBody`,
            // `AccountManagerFetch.fetchBodyIfNeeded`) and fetches on cache-miss.
            // `v2final`'s `repairPayloadTooLargeEmptyBodies` DOES pair a body delete
            // with `bodyComplete = 0`, but only for bodies that were never VALIDLY
            // fetched (`bodyEmptyConfirmed = 1 AND emptyFetchCount < 3`) — the
            // repair case, not the eviction case. This is the eviction case.
            //
            // `BodyAssetStore` is NOT cleared either. Its manifest ids are
            // deterministic (`headerHash(contentKey)/assetHash(cid|section)`) and
            // written with `ON CONFLICT(id) DO UPDATE`, so a re-fetch re-attaches
            // the SAME rows and the SAME files — it cannot duplicate either. The
            // assets stay owned (their headers are untouched, so
            // `BodyAssetMaintenance.pruneOrphans` correctly protects them), stay
            // bounded (`evictIfOverCap` against `attachmentsBudgetMB`, default
            // 1024 MB), and are still reclaimed when their header dies via the
            // routed `MessageContentStore.releaseUnowned(… .assets)` sites. Clearing
            // them would delete still-reachable user data and force a re-download of
            // every cached attachment.
            //
            // `SearchIndex.message_meta.hasBody` is NOT reset. It lives in the
            // separate FTS database, which this DDL does not touch, and it means
            // "the FTS row carries non-empty indexed body TEXT" — which stays TRUE,
            // because the FTS text survives. Search keeps working over bodies whose
            // HTML cache this migration discarded.
            if DebugModeManager.isLoggingEnabled() {
                let discarded = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageBody") ?? -1
                print("[Migration v70] discarding \(discarded) cached body row(s) to drop the header FK")
            }
            try db.drop(table: "messageBody")
            // Recreated WITHOUT the `.references("messageHeader", onDelete: .cascade)`
            // that `v1`/`v2` declared. Every other column is reproduced exactly as the
            // v69 schema had it — `icsText` last, because `v19` added it by `ALTER`.
            // `messageBody` carries no named index on any schema up to v69: its only
            // index is the implicit `sqlite_autoindex` behind the TEXT primary key,
            // which `CREATE TABLE` reproduces. If a later migration ever adds one
            // BEFORE v70, it must be recreated here too — `v70RecreatesEveryIndex`
            // pins that.
            try db.create(table: "messageBody") { t in
                t.primaryKey("id", .text)
                t.column("htmlContent", .text)
                t.column("attachmentsJSON", .text)
                t.column("fetchedAt", .datetime).notNull()
                t.column("icsText", .text)
            }
        }

        migrator.registerTimedMigration("v71_addOutboxDraftRfc822MessageId") { db in
            // The DRAFT's own RFC 822 Message-ID, snapshotted at queue-send time so
            // the post-send server-draft cleanup can name the Drafts copy by an
            // identity instead of by the bare IMAP UID `IMAPProvider.saveDraft`
            // returns. Without it, `finalizeOutboxMessage` and `reconcileOutbox`
            // queued a `.deleteDraft` carrying nothing but that UID — which
            // `IMAPProvider.deleteDraft` refuses (a UID is an ADDRESS, not an
            // identity), so the op could only fail and be dropped while the sent
            // draft stayed on the server.
            //
            // This is NOT `sentMessageId`: that is the SENT message's own
            // independently-generated id, which the Drafts copy never carries, so
            // keying the cleanup by it searches Drafts and finds nothing.
            //
            // Nullable, no default, no backfill — a pre-migration outbox row simply
            // has no snapshot and its cleanup behaves exactly as it does today. Such
            // rows drain within one session.
            //
            // PORTED from the reference's `OutboxMessage.draftRfc822MessageId`
            // (`v2final:TabMail/Models/OutboxMessage.swift`). The migration NUMBER is
            // v3's own: v3's ceiling is v70 and `v2final` never shipped, so its
            // numbering is irrelevant here and must not be copied.
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "draftRfc822MessageId", .text)
            }
        }

        migrator.registerTimedMigration("v72_addDraftServerUidValidity") { db in
            // The UIDVALIDITY EPOCH the draft's server address (`serverDraftId`, a bare
            // IMAP UID) was MINTED under, carried beside that address everywhere the
            // address goes: the `draft` row that owns it, the `outboxMessage` snapshot
            // the post-send backstops read, and the `.deleteDraft` PendingOperation the
            // backstops record.
            //
            // WHY v71 ALONE WAS NOT THE CLOSURE. v71 gave the delete an rfc822
            // IDENTITY, and identity alone cannot tell one draft from a LEGITIMATE
            // same-Message-ID SIBLING — two distinct drafts may share a Message-ID after
            // a copy or another client's save, which is why `IMAPProvider.deleteDraft`
            // refuses outright when it sees 2+ exact matches. The dangerous crossing is
            // when the gesture's own target is already gone (another client removed it,
            // or the primary delete got there first) and the sibling is the SOLE
            // remaining match: the Message-ID SEARCH then returns exactly one hit — the
            // sibling — and deleting it is a wrong-message delete (C3).
            //
            // With the epoch, that delete resolves through the STRONG arm instead:
            // SELECT reports the live UIDVALIDITY, it must EQUAL the recorded one (a
            // mismatch fails closed), and only then may the recorded UID be FETCHed and
            // corroborated against the recorded rfc822. If the gesture's target is gone
            // the FETCH finds nothing and the delete is a clean no-op — the sibling is
            // never even a candidate.
            //
            // PORTED from the reference's `v85_addOutboxDraftServerUidValidity`
            // (`OutboxMessage.draftServerUidValidity`) and `Draft.serverDraftUidValidity`
            // (`v2final`). Two migrations exist there for the same reason two columns
            // exist here: the rfc822 column and the epoch column are separate halves of
            // one identity, and the reference shipped the second only after the
            // same-rfc-sibling failure was found. The migration NUMBER is v3's own — v71
            // is v3's ceiling and has already been APPLIED to local databases, so it is
            // immutable and this is a new migration rather than an edit.
            //
            // `pendingOperation.draftServerUidValidity` is a TYPED COLUMN where the
            // reference uses a positional `messageIds` slot. ⚑ DELIBERATE DEVIATION,
            // forced by v3: `SyncEngine`'s stale sweep builds its protection set as
            // `Set(opsTargetingThisFolder.flatMap(\.messageIds))`, so ANY value parked in
            // a `messageIds` slot — a numeric epoch, or the reference's empty-string
            // positional placeholders — enters that set and can protect a header whose
            // own id happens to equal it. A column carries the same datum with no such
            // aliasing.
            //
            // All three nullable, no default, no backfill: a pre-migration row simply has
            // no recorded epoch and cannot authorize a destructive IMAP operation.
            // Never "0" — RFC 3501 §2.3.1.1 types
            // UIDVALIDITY as `nz-number`, so a synthesised zero would be an epoch that
            // compares equal to another synthesised zero.
            try db.alter(table: "draft") { t in
                t.add(column: "serverDraftUidValidity", .integer)
            }
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "draftServerUidValidity", .integer)
            }
            try db.alter(table: "pendingOperation") { t in
                t.add(column: "draftServerUidValidity", .integer)
            }
        }

        migrator.registerTimedMigration("v73_bindDraftUidToMailbox") { db in
            try db.alter(table: "draft") { t in
                t.add(column: "serverDraftFolderPath", .text)
            }
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "draftServerFolderPath", .text)
            }

            // SUBTRACT — no migration compatibility for old IMAP addresses.
            // Preserve authored content while clearing incomplete tuples so the
            // next admitted save takes the safe fresh-APPEND path.
            try db.execute(sql: """
                UPDATE draft
                SET serverDraftId = NULL,
                    serverPushStatus = NULL,
                    serverDraftUidValidity = NULL,
                    serverDraftFolderPath = NULL
                WHERE accountId IN (
                    SELECT id FROM account WHERE provider IN ('imap', 'icloud')
                )
                  AND serverDraftId IS NOT NULL
                """)
        }

        migrator.registerTimedMigration("v74_purgeLegacyPendingOperations") { db in
            // ⚑ NO REFERENCE — INVENTED. Owner-approved C6 upgrade boundary:
            // superseded in-flight operations are discarded without decoding.
            // Draft, Outbox, authored content and attachments remain untouched.
            try db.execute(sql: "DELETE FROM pendingOperation")
        }

        migrator.registerTimedMigration("v75_addDraftPushAttemptVersion") { db in
            // PORT — v2final v81 conflict version, with recovery fields omitted.
            try db.alter(table: "draft") { t in
                t.add(column: "pushAttemptVersion", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerTimedMigration("v76_addDraftGenerationAndTypedIdentity") { db in
            // PORT — reduced generation/provider-native schema. No backfill and
            // no pending/outbox compatibility: nil generations fail closed until
            // an ordinary compose admission acquires the existing Draft.
            try db.alter(table: "draft") { t in
                t.add(column: "instanceEpoch", .text)
            }
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "instanceEpoch", .text)
                t.add(column: "serverDraftGmailMessageId", .text)
            }
            try db.alter(table: "pendingOperation") { t in
                t.add(column: "instanceEpoch", .text)
                t.add(column: "draftId", .text)
                t.add(column: "draftDeleteAddressKind", .text)
            }
        }

        migrator.registerTimedMigration("v77_addMessageHeaderObservedUidValidity") { db in
            // ⚑ NO REFERENCE — INVENTED. Source-bound IMAP epoch transport,
            // explicitly deferred by v2final commit 486bafd4b. Nullable, with no
            // default and no backfill: existing rows remain unproven rather than
            // adopting the Folder's current epoch by assertion.
            try db.alter(table: "messageHeader") { t in
                t.add(column: "observedUidValidity", .integer)
            }
        }

        migrator.registerTimedMigration("v78_addPendingOperationEverAttempted") { db in
            // PORT — v2final v73 (`d1d4f01ce`). Annihilation is only an
            // optimization, so pre-existing rows take the conservative TRUE
            // backfill: a false positive costs one inverse provider call;
            // a false negative could erase the only compensation for an
            // already-started move.
            try db.alter(table: "pendingOperation") { t in
                t.add(column: "everAttempted", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "UPDATE pendingOperation SET everAttempted = 1")
        }

        // PORT — v2final `v78_addDraftLastTouchedSeq` (commit `fc90bcc2c`), taken
        // here as v79 (v78 is already registered above and is immutable).
        //
        // `DraftStore.evictImpl` previously ordered by wall-clock `updatedAt`, so
        // equal timestamps or a clock rollback could rank a freshly-saved draft
        // beyond the keep-limit and DELETE it — authored user bytes lost to routine
        // maintenance. `lastTouchedSeq` is assigned `MAX(lastTouchedSeq) + 1` inside
        // the save transaction (GRDB's single serialized writer ⇒ strictly
        // increasing, no ties, no rollback).
        //
        // SEED existing rows with a DISTINCT rank so post-upgrade eviction has a
        // total order immediately, rather than an all-zero tie that would fall back
        // to the wall clock this migration exists to stop trusting: each row's
        // 1-based position in `(updatedAt ASC, id ASC)` — the recency signal the app
        // already displays by, and the best available legacy proxy. `applySave`'s
        // `MAX+1` then continues from N. Additive; no data reshape; no row deleted.
        migrator.registerTimedMigration("v79_addDraftLastTouchedSeq") { db in
            try db.alter(table: "draft") { t in
                t.add(column: "lastTouchedSeq", .integer).notNull().defaults(to: 0)
            }
            try AppDatabase.seedDraftLastTouchedSeq(db)
        }

        // T5.8 — the ADDRESS of the message a reply/forward draft was written
        // against, recorded beside the (mutable) `replyToId` PK it can no longer be
        // recovered from.
        //
        // ⚑ NO REFERENCE — INVENTED. `v2final` discriminates the reply target by
        // RFC 822 Message-ID (`Draft.expectedReplyToRfc` / `acceptStrategy1ReplyHit`),
        // which recovers a baseline only for a numeric-IMAP source. That RFC baseline
        // is PORTED and still runs; these two columns are the second, independent
        // baseline v3 needs because `replyToId` is `accountId:folderPath:messageId`
        // and every part of it is mutable — a folder move re-keys it, and a
        // UIDVALIDITY reset + purge-and-resync can seat a DIFFERENT physical message
        // at the very same PK while keeping the same UID. Quoting the body found
        // there puts another correspondent's mail into the user's OUTGOING reply
        // (C3: no action may mutate or misattribute the wrong message).
        //
        // `replyToProviderMessageId` belongs to the **provider-id (action)** keying
        // scheme — the question is which physical COPY the user replied to, not
        // which content — and `replyToUidValidity` is the epoch that address is only
        // meaningful within. Neither belongs to the RFC/content scheme; both keying
        // schemes exist in this repo on purpose (`MessageIdentity.ContentKeySpace`).
        //
        // NULLABLE, NO DEFAULT, and deliberately NO BACKFILL. Backfilling from the
        // row currently sitting at `replyToId` would ADOPT whatever is there as "the
        // expected identity" — which, for exactly the substituted rows this exists to
        // catch, BLESSES the impostor and converts a detectable hazard into a
        // permanent laundered pass. A pre-v80 row therefore keeps nil = UNKNOWN, and
        // the ported RFC baseline (recoverable from the draft KEY, which every legacy
        // row already has) is what guards it until an ordinary save re-stamps it.
        //
        // Never 0 for the epoch: RFC 3501 §2.3.1.1 types UIDVALIDITY as `nz-number`,
        // so a synthesised zero would compare equal to another synthesised zero.
        migrator.registerTimedMigration("v80_addDraftReplyTargetAddress") { db in
            try db.alter(table: "draft") { t in
                t.add(column: "replyToProviderMessageId", .text)
                t.add(column: "replyToUidValidity", .integer)
            }
        }

        // PORT — v2final `v72_addActionTagSetAt` (renumbered: v72..v80 are already
        // taken on this line, and a migration is immutable once applied).
        //
        // Round D-0b: real TTL semantics for `sweepStaleActionTags` (mirrors TB's
        // SETTINGS.actionTTLSeconds — SyncConfig.actionTagTTLSeconds, 1 week).
        // Nullable, no default, NO INDEX: the sweep is a bounded ~15-minute
        // maintenance scan over out-of-inbox rows only (SyncEngineMaintenance.swift),
        // so an index here is unjustified. Backfill every already-tagged row with a
        // stamp AT MIGRATION TIME so it gets a full TTL from upgrade, keeping the
        // invariant `actionTag != nil ⇒ actionTagSetAt != nil` true from day one —
        // including for the historic v53/legacy raw-SQL rows whose actionTag is the
        // string 'none' (still NOT NULL in SQL, so still covered by this WHERE
        // clause). Convergence: a fresh install runs v53 then v81, an existing DB
        // skips v53 and runs v81 — either way every row carrying a tag when v81
        // runs leaves it stamped, and every untagged row leaves it NULL.
        migrator.registerTimedMigration("v81_addActionTagSetAt") { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "actionTagSetAt", .datetime)
            }
            try db.execute(sql: """
                UPDATE messageHeader
                SET actionTagSetAt = ?
                WHERE actionTag IS NOT NULL
                """, arguments: [Date()])
        }
    }

    /// PORT — v2final `AppDatabase.seedDraftLastTouchedSeq`. Extracted to a static
    /// so the v79 migration and its tests share ONE algorithm.
    ///
    /// Ranks every existing `draft` row 1-based by `(updatedAt ASC, id ASC)`. The
    /// `d2.id <= draft.id` tie-break counts the row itself, so the lowest-ranked row
    /// gets 1 (never 0, which is the column default a never-saved row would keep).
    /// Pure ranking — it reads and rewrites only `lastTouchedSeq`, and never
    /// deletes or reshapes a draft.
    static func seedDraftLastTouchedSeq(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE draft SET lastTouchedSeq = (
                SELECT COUNT(*) FROM draft d2
                WHERE d2.updatedAt < draft.updatedAt
                   OR (d2.updatedAt = draft.updatedAt AND d2.id <= draft.id)
            )
        """)
    }
}

// MARK: - Per-migration timing

/// ⚑ NO REFERENCE — INVENTED. `v2final` times the migration pass only in
/// AGGREGATE (`AppDatabase.init`'s "schema migrations completed in Nms" line,
/// which is KEPT as-is and stays always-on); it has no per-migration counterpart.
///
/// Wraps `DatabaseMigrator.registerMigration` so every registration in
/// `AppDatabase.registerAllMigrations` reports how long ITS OWN body took. The
/// aggregate line can only say a multi-version jump cost 12s; this says WHICH of
/// the O(mailbox-size) bodies (v9 / v27 / v47 / v53 / v54 …) spent it — the
/// attribution the "hang on boot" reports need.
///
/// **The applied-migrations ledger is untouched.** The identifier string and the
/// migrate closure are forwarded to GRDB byte-for-byte; the only change is an
/// outer closure that calls `migrate(db)`. GRDB keys `grdb_migrations` by
/// identifier, so every already-applied migration stays applied and its body is
/// never re-run — migrations are immutable once applied, and this wrapper is
/// deliberately the one thing around them that is not part of that identity.
private extension DatabaseMigrator {

    /// `Duration.components` splits into (seconds, attoseconds), so rendering the
    /// fractional part in milliseconds needs these unit factors. Not tunables:
    /// 1 s = 1e3 ms and 1 ms = 1e-3 s = 1e15 as.
    static let millisecondsPerSecond: Int64 = 1_000
    static let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000

    /// Whole elapsed milliseconds, matching the aggregate line's `Nms` format.
    static func wholeMilliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds * millisecondsPerSecond + attoseconds / attosecondsPerMillisecond)
    }

    /// `registerMigration`, plus a **debug-gated** per-migration duration line
    /// that distinguishes success from failure. Errors propagate unchanged.
    ///
    /// - Gating (project rule 12): with debug logging LOCKED — the default
    ///   release state — the wrapper is one `UserDefaults` bool read and then a
    ///   direct `migrate(db)`: no clock is read and no string is built. And since
    ///   GRDB only invokes bodies for UNAPPLIED migrations, an up-to-date
    ///   database pays even that nothing at all.
    /// - Clock: `ContinuousClock` is MONOTONIC. A wall-clock source
    ///   (`CFAbsoluteTimeGetCurrent`) can be stepped by an NTP/timezone
    ///   adjustment mid-migration and report a nonsense or negative duration.
    /// - Failure: a throwing body is logged as FAILED, with its own elapsed time
    ///   and the error, and is then re-thrown UNCHANGED so GRDB still rolls the
    ///   migration back. Without this, a body that dies 40s in is invisible —
    ///   the aggregate line never prints because `init` throws first.
    mutating func registerTimedMigration(
        _ identifier: String,
        foreignKeyChecks: ForeignKeyChecks = .deferred,
        migrate: @escaping @Sendable (Database) throws -> Void
    ) {
        registerMigration(identifier, foreignKeyChecks: foreignKeyChecks) { db in
            guard DebugModeManager.isLoggingEnabled() else {
                try migrate(db)
                return
            }
            let start = ContinuousClock.now
            // `start.duration(to: .now)` rather than `.now - start`: reads as
            // "elapsed since start", so no sign convention has to be recalled.
            do {
                try migrate(db)
                let elapsed = DatabaseMigrator.wholeMilliseconds(start.duration(to: ContinuousClock.now))
                BackgroundSyncLogger.log("AppDatabase: migration \(identifier) applied in \(elapsed)ms")
            } catch {
                let elapsed = DatabaseMigrator.wholeMilliseconds(start.duration(to: ContinuousClock.now))
                BackgroundSyncLogger.log("AppDatabase: migration \(identifier) FAILED after \(elapsed)ms: \(error)")
                throw error
            }
        }
    }
}
