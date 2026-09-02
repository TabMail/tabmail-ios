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

        // 🚨 CALIBRATION — ALWAYS ON, AND ONLY WHEN THE CHAIN HAS WORK TO DO.
        //
        // A duration with no denominator is not observability. The owner's device
        // reported a 27,601 ms chain and nobody could say whether that meant "slow
        // migrations" or "a very large mailbox" — and those have OPPOSITE remedies.
        // This emits the denominator once, immediately before the first body runs:
        // a header ceiling, a body ceiling, exact account and folder counts, and the
        // database's page footprint. See `MigrationTimingLedger.measureChainScale` —
        // the two unbounded tables report `MAX(rowid)` rather than `COUNT(*)`, because
        // counting them cost the owner's device 7,533 ms of a 19,558 ms splash.
        //
        // The `unapplied.isEmpty` guard is what keeps this off the ordinary launch
        // path. An already-migrated database pays ONE read of `grdb_migrations` — the
        // same read `migrator.migrate` is about to do anyway — and emits nothing. The
        // four figures are paid at most once per app upgrade, and none of them is on
        // the row axis any more.
        //
        // ⚠️ IT IS INSIDE THE WINDOW IT MEASURES. `AppDatabase.init` brackets this
        // whole function with the aggregate *"schema migrations completed in Nms"*
        // line, so the measurement inflates that number. `ChainScale.measurementMs`
        // is printed on the same line for exactly that reason — subtractable rather
        // than invisible. Moving the measurement outside the bracket was considered
        // and rejected: `runMigrations` is the only place that knows what is
        // unapplied, and duplicating that read in the caller is how the two drift.
        //
        // ⚠️ IT MUST NEVER THROW. A diagnostic that can fail a migration chain is a
        // brick, which is in the non-recoverable set; a missing number is not. Every
        // read inside `measureChainScale` is individually optional, and this whole
        // block is `try?` — on a fresh install `messageHeader` does not exist yet.
        let scale: MigrationTimingLedger.ChainScale? = (try? writer.read { db in
            let completed = Set(try migrator.completedMigrations(db))
            let unapplied = migrator.migrations.filter { !completed.contains($0) }
            guard !unapplied.isEmpty else { return nil }
            return MigrationTimingLedger.measureChainScale(
                db, pendingMigrations: unapplied.count)
        }) ?? nil
        if let scale { MigrationTimingLedger.logChainScale(scale) }

        try migrator.migrate(writer)
        // THE LAST MIGRATION HAS NO SUCCESSOR to close its post-body interval, so
        // the chain-completion site closes it and emits the reconciliation line.
        // Gated exactly like the per-migration lines, and a no-op when this writer
        // ran no body at all — the already-migrated case, which is every launch
        // after the upgrade one. `writeWithoutTransaction` (not a barrier) because
        // all it needs is the writer's own `Database`, which is the key the ledger
        // recorded the chain under; it opens no transaction and touches no row.
        guard MigrationTimingGate.isRecording else { return }
        writer.writeWithoutTransaction { db -> Void in
            MigrationTimingLedger.shared.finish(db: db)
        }
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

        // ── FOREIGN-KEY CHECK MODE FOR THE v68…v88 RANGE ─────────────────────
        //
        // `registerTimedMigration`'s DEFAULT stays `.deferred` and is NOT
        // changed. v1…v67 have never been adjudicated for `.immediate` safety,
        // and a device sitting at an intermediate version would run the
        // unadjudicated ones against populated data. Only the migrations that
        // spell `foreignKeyChecks: .immediate` out below run that way.
        //
        // WHY. GRDB's `.deferred` path (`Migration.runWithDeferredForeignKeys
        // Checks`) wraps each body in `PRAGMA foreign_keys = OFF` and then a
        // WHOLE-DATABASE `PRAGMA foreign_key_check` before COMMIT. That check
        // scans every FK-bearing row in the file regardless of what the body
        // touched, and it is paid once per migration. Measured on a 500k-header
        // / 1M-association / 3.4 GB database, v68…v83 cost 61.8–87.4 s, of
        // which 42.5–65.0 s (69–74%) was those sixteen checks — `v68` alone is
        // one `ALTER TABLE folder ADD COLUMN` with a 0.3 ms body and an
        // 8.8–10.7 s check. `.immediate` keeps foreign keys ENFORCED LIVE
        // inside the body and runs no trailing whole-database scan. Same
        // statements, same rows, byte-identical resulting schema; the same
        // chain measures 27.6–29.0 s. On device (×2–4) that is 2.1–5.8 min →
        // 0.9–1.9 min. Harness + raw output: `scratchpad/MIGRATION_COST/`.
        //
        // NOT A BODY CHANGE. `foreignKeyChecks:` is an argument to
        // `registerMigration`, not part of the migration body, so Data
        // Integrity rule 5 (a registered migration is immutable once ANY
        // database has run it) is not engaged: a database that already applied
        // a migration SKIPS it entirely and the mode never runs; a database
        // that has not applies it under the new mode and reaches the identical
        // schema.
        //
        // WHEN `.immediate` IS SAFE. It differs from `.deferred` only for a
        // body that TRANSIENTLY violates an FK and repairs it before COMMIT.
        // The v67 FK graph is `account ← {caldavConfig, draft, folder,
        // messageHeader, outboxMessage, pendingCalendarOperation, userLabel}`,
        // `messageHeader ← {messageBody (until v70), messageReference,
        // messageUserLabel}`, `userLabel ← {messageUserLabel}` — every one
        // `ON DELETE CASCADE` / `ON UPDATE NO ACTION`. Against that graph:
        //   • v68 v69 v71 v72 v75 v76 v77 v80 — `ADD COLUMN` only. None of the
        //     21 columns these add declares `.references`, and adding a column
        //     writes no key.
        //   • v73 v78 v79 — `ADD COLUMN` + an `UPDATE` of
        //     `serverDraftId`/`serverPushStatus`/`serverDraft*` /
        //     `everAttempted` / `lastTouchedSeq`. SQLite re-validates an FK only
        //     when a parent- or child-key column is written; none of these is
        //     one.
        //   • v74 — `DELETE FROM pendingOperation`. That table declares no FK
        //     and NOTHING references it, so the delete fires no FK action.
        //   • v70 — `DROP TABLE messageBody` + recreate. `messageBody` is a
        //     pure CHILD; nothing references it, so the implicit delete that
        //     `DROP TABLE` performs under enforced FKs cascades to nothing.
        //   • v81 — `ADD COLUMN` only as of 2026-08-05; its
        //     `UPDATE messageHeader SET actionTagSetAt = …` was removed (see that
        //     migration's own note). `messageHeader` IS a parent, but adding a
        //     column writes no key of either kind.
        //   • v83 — EMPTY BODY as of 2026-08-06; changes no row and issues no
        //     statement. Both halves of what it used to do — the `ANALYZE` and then
        //     the `CREATE INDEX` itself — moved to the background maintenance pass
        //     (ADR-IOS-029, 2026-08-05 amendment and its 2026-08-06 extension). The
        //     mode is retained on an empty body so this range's census stays uniform
        //     and a future reader who fills the body in does not inherit `.deferred`.
        //   • v84 — `ALTER TABLE … ADD COLUMN` only (`pendingCalendarOperation`
        //     `failureReason`). Same argument as the `ADD COLUMN` bullet above:
        //     adding a column writes no key of either kind.
        //   • v85 — two `ALTER TABLE … ADD COLUMN` statements, a sparse index,
        //     and four `messageHeader` triggers; none changes an FK-bearing key.
        //     Existing rows take the false defaults, so the sparse direct-request
        //     index starts empty. Creating triggers mutates no row or key.
        //   • v86 — one `folder` role-change trigger. Creating a trigger mutates no
        //     row or key; its later UPDATE targets only a non-key header column.
        //   • v87 — drops only v85/v86's direct-AI triggers, sparse index and two
        //     non-key marker columns. It neither reads nor rewrites an FK-bearing
        //     value; existing derived-work markers are intentionally discarded.
        //   • v88 — one `ALTER TABLE messageHeader ADD COLUMN`
        //     (`bodyMetadataOversized`). Same argument as the `ADD COLUMN` bullet
        //     above: `messageHeader` IS a parent, but adding a column writes no key
        //     of either kind. Its index is NOT built here — it is deferred to
        //     `SyncEngine.createDeferredIndexes` off the launch path
        //     (ADR-IOS-029, 2026-08-05 amendment), so the body is one statement.
        //
        //   • v82 — `DROP`/`CREATE` of `userLabel` + `messageUserLabel`. FK-clean
        //     per statement, verified statement by statement in that migration's own
        //     comment, which is where the argument lives. ⚠️ This bullet used to say
        //     *"because the CHILD is dropped before the PARENT"*; that clause was
        //     wrong and is corrected at the migration — the drop order is the `v2`
        //     house pattern, and the snapshots taken before either drop are what make
        //     the body safe.
        //
        // ⚑ AMENDED 2026-08-06, RANGE RE-DERIVED AT R17-6 — **EVERY MIGRATION IN
        // v68…v88 NOW RUNS `.immediate`, so this range runs ZERO whole-database
        // foreign-key checks.** The range is an OPEN interval that moves with the
        // top of the chain, so it is re-derived rather than restated (`MIS-031` — a
        // sentence that enumerates is a cache, and this one had gone stale at `v84`
        // in five places at once). Comments excluded so this paragraph cannot
        // satisfy its own predicate (`MIS-033`, `IOS-DOC-002`):
        //   rg -c --pcre2 '^(?!\s*(///|//)).*foreignKeyChecks: \.immediate' \
        //      TabMail/Services/AppDatabase.swift                            → 21
        //   rg -o '"v([0-9]+)_[A-Za-z0-9_]+"' -r '$1' \
        //      TabMail/Services/AppDatabase.swift | sort -n -u | awk '$1>=68' | wc -l → 21
        // Equal counts are the invariant: every migration from v68 to the top runs
        // `.immediate`, and none below v68 does. The sentence
        // that stood here said *"`v71` and `v82` stay `.deferred`, each for a
        // different reason — read their own comments before changing either"*, and
        // the `ADD COLUMN` bullet above listed `v71` among the migrations that
        // *would be* safe under `.immediate` — an invitation the closing sentence
        // then walked back. All of that is gone. The bullets above are now simply a
        // statement of what these migrations do, with nothing to walk back.
        //
        // WHY, in one line each, with the full arguments at the two registrations:
        // on the owner's device (v67 → v83, 5 accounts / 78 folders) the chain cost
        // 27,601 ms, of which 19,312 ms (70%) was `PRAGMA foreign_key_check` —
        // 12,083 ms of it `v71`'s gate guarding a one-statement `ADD COLUMN` whose
        // body took 1 ms, and 7,228 ms `v82`'s guarding a body that took 7 ms.
        //
        // ⚠️ NEGATIVE CASE, and it is the whole cost of this change: an orphan that
        // PRE-EXISTED in the v67 database, on an edge no migration in this range
        // rebuilds, is no longer detected by the chain at all. It survives, renders
        // nothing, loses nothing, and is re-supplied by the next sync of its owning
        // message — recoverable, so per THE MANTRA it is registered rather than
        // mechanised (`KNOWN_ISSUES.md` `IOS-MIGRATION-002`). What this does NOT
        // license: adding a NEW migration that transiently violates an FK. The
        // adjudication above is per-migration and a new one owes its own.
        migrator.registerTimedMigration(
            "v68_addFolderUidValidityResetPending", foreignKeyChecks: .immediate
        ) { db in
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

        migrator.registerTimedMigration(
            "v69_addPendingOperationObservedUidValidity", foreignKeyChecks: .immediate
        ) { db in
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

        migrator.registerTimedMigration(
            "v70_dropMessageBodyHeaderFK", foreignKeyChecks: .immediate
        ) { db in
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
            // ⚠️ **THE DECISION RESTS ON THE DISK CLAIM, NOT ON THE SPEED RATIO.**
            // Both halves were re-measured 2026-08-05 and only one of them
            // generalises:
            //   • ZERO EXTRA DISK holds at EVERY scale — peak overhead ≤ +2.6 MB.
            //     This is the load-bearing fact and it is why the rebuild was
            //     rejected; do not weaken it.
            //   • The old "0.319 s" was a 100 MB-scale number read as universal.
            //     `DROP TABLE messageBody` is strongly SUPER-LINEAR: 100 MB → 18 ms,
            //     500 MB → 87 ms, 1.2 GB → 2,182 ms, 2.6 GB → 7,886 ms. So the
            //     advantage over the ~11 s rebuild is ~35× at 100 MB but only ~1.4×
            //     at 2.6 GB. A reader sizing this migration on a large device should
            //     expect SECONDS, not milliseconds.
            // The freelist those pages return to is consumed again as the cache
            // refills — so the file never grows and no `VACUUM` is ever needed.
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
            // `AccountManager.fetchBodyIfNeeded`) and fetches on cache-miss.
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
            // `MAX(rowid)`, not `COUNT(*)`: this is a diagnostic, and on the owner's
            // device the `COUNT(*)` it replaces scanned ~3,000 index pages (~4.5 s of
            // this migration's 11,993 ms body) to produce a number nothing branches on.
            // A ceiling costs 9 pages. `COALESCE` keeps an empty table reading `0`
            // rather than `-1`. Full measurement: `MigrationTimingLedger.measureChainScale`.
            if DebugModeManager.isLoggingEnabled() {
                let discarded = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(rowid), 0) FROM messageBody") ?? -1
                print("[Migration v70] discarding <=\(discarded) cached body row(s) to drop the header FK")
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

        // ⚑ THIS MIGRATION RUNS `foreignKeyChecks: .immediate` AS OF 2026-08-06.
        //
        // It used to be the range's POSITIONED WHOLE-DATABASE ORPHAN GATE, and this
        // comment used to carry the instruction *"Do not 'finish the optimisation'
        // by flipping it"* together with a `⚑ .deferred MADE EXPLICIT` paragraph
        // whose stated purpose was to make a future sweep DELETE an explicit choice
        // rather than merely add an argument. **This is that sweep, and the
        // instruction is WITHDRAWN on the owner's directive.** The original
        // rationale is preserved below in the past tense rather than deleted: it was
        // right about what the gate DID and wrong only about whether it was worth
        // its price.
        //
        // 🚨 WHAT IT COST, on real hardware rather than on the harness. The owner
        // measured a device upgrading v67 → v83 with 5 accounts / 78 folders;
        // `MigrationTimingLedger` attributed:
        //     v71 total 12,084ms = body 1ms + fkCheck/commit 12,083ms [.deferred]
        // — one `ALTER TABLE outboxMessage ADD COLUMN`, and twelve seconds of
        // whole-database `PRAGMA foreign_key_check` charged to it. The whole chain
        // was 27,601 ms, of which 19,312 ms (70%) was foreign-key checking rather
        // than work, and first paint came at 33.1 s.
        //
        // WHY THE GATE IS NOT WORTH THAT — three independent facts.
        //
        //  1. ORPHANS ARE STRUCTURALLY PREVENTED, so the gate guards a state the
        //     schema already forbids. `AppDatabase.makeConfiguration` sets
        //     `config.foreignKeysEnabled = true`, and EVERY foreign key this schema
        //     declares carries `ON DELETE CASCADE`. Measured two ways at
        //     `271d13334`, over the chain through `v83`:
        //     • LIVE SCHEMA — authoritative. `PRAGMA foreign_key_list` over every
        //       table of a freshly migrated database (21 tables) returns 10 foreign
        //       keys, and `on_delete` is `CASCADE` for all 10, zero otherwise:
        //       `{folder, messageHeader, draft, outboxMessage, userLabel,
        //       caldavConfig, pendingCalendarOperation} → account`;
        //       `messageReference → messageHeader`; `messageUserLabel →
        //       {messageHeader, userLabel}`. Pinned by
        //       `MigrationForeignKeyModeTests.everyLiveForeignKeyCascades`, so this
        //       paragraph is now checked by the suite rather than by re-grepping.
        //     • SOURCE DDL — secondary. `rg '\.references\("'` over
        //       `TabMail/ Shared/ TabMailNotificationService/` finds 16 DDL
        //       declarations, all 16 spelling `onDelete: .cascade`, zero bare.
        //     16 ≠ 10 because six declarations are DEAD SOURCE: `v1`'s
        //     `messageHeader.folderId → folder` (dropped by `v2`), `messageBody →
        //     messageHeader` spelled twice (`v1`, then `v2`'s rebuild — both dropped
        //     by `v70`), and `v82`'s rebuild re-spelling the three label edges `v33`
        //     first declared. THE GREP COUNTS DEAD DDL; THE PRAGMA DOES NOT.
        //     ⚠️ `MIS-033` — this census read *"returns 19 lines, 3 of which are
        //     prose, leaving 16"* and the truth was 20 and 4. The uncounted fourth
        //     prose line was A LINE OF THIS BANNER: it quotes the search token, so
        //     the grep matches the paragraph that reports it, and the total drifts by
        //     one every time the wording changes. Never restate this as "N lines, M
        //     of which are prose" — state the DDL count, which the banner cannot
        //     contaminate. For the same reason the four corroborating predicates once
        //     claimed here to "each return nothing" are gone: a bare
        //     `.references("x")`, raw-SQL `REFERENCES` and `foreignKey(` now match
        //     only this comment, and `t.belongsTo` matches this comment PLUS a real
        //     hit. That hit is not a counterexample — GRDB record associations
        //     (`rg 'belongsTo|hasMany\(|ForeignKey\(' TabMail/Models/` → 3 sites, a
        //     path this banner cannot pollute) are QUERY-LAYER joins declaring no
        //     schema constraint, and both columns they join on are already among the
        //     10 cascading edges above. Deleting a parent takes its children with it;
        //     no application path can strand one.
        //  2. IT IS REDUNDANT WITH THE REST OF THE CHAIN. The large majority of the
        //     83 migrations still end with their own whole-database check — the
        //     exact figure is re-derived in `v82`'s step-1 comment below, which is
        //     the single place this file keeps that census — so anything the CHAIN
        //     ITSELF created would abort at its own migration, not here. The only
        //     thing this gate uniquely caught is an orphan that PRE-EXISTED in the
        //     v67 database.
        //  3. ITS REMEDY ON FIRING IS A BRICK. A failed check throws → `AppDatabase`
        //     init throws → `AppDatabase.rawPool`'s force-unwrap crashes at launch.
        //     Per THE MANTRA (`tabmail-ios/CLAUDE.md`) a brick is in the
        //     NON-RECOVERABLE set, while the condition it detects — a dangling
        //     `messageUserLabel` row, i.e. a label chip that does not resolve — is
        //     RECOVERABLE: it renders nothing, and the server re-supplies the
        //     association on the next sync of that message. The gate traded a
        //     recoverable cosmetic defect for a non-recoverable brick and charged
        //     12 s of every upgrade launch for the trade.
        //
        // AND THE CLASS IT GUARDED IS REPAIRED DOWNSTREAM ANYWAY — this is the fact
        // the old rationale never checked. `v82` handles BOTH `messageUserLabel`
        // orphan classes locally: its step 1 explicitly `DELETE`s an association
        // whose `messageHeader` is gone, and its step 3a `LEFT JOIN`s the legacy
        // label snapshot so an association pointing at a MISSING `userLabel` still
        // gets a rebuilt parent row (named by its bare provider id). So the orphan
        // this gate ran early specifically to catch BEFORE `v82` is the orphan `v82`
        // itself fixes.
        //
        // ⚠️ NEGATIVE CASE — what flipping this does NOT claim. It does not claim
        // the check was useless: it was one of the two things that would have found
        // a pre-existing orphan on an edge no range migration rebuilds (e.g.
        // `messageReference → messageHeader`). `v82`'s gate was the other, and it
        // was retired in the very next commit, so **nothing from v68 to the top of
        // the chain detects one any more** (the range was written as "v68…v83" and
        // was already stale at `v84`; it is now stated as the open interval it has
        // always been — see the range predicate in the section header above).
        // Such a row now survives the chain, renders nothing, and is
        // swept by nothing. That residual is ACCEPTED and registered —
        // `KNOWN_ISSUES.md` `IOS-MIGRATION-002`, whose own text used to say
        // "Neither gate may be flipped to `.immediate`" and is corrected there.
        // ⚠️ This paragraph read *"and after this flip nothing in v68…v83 detects
        // one"* in the commit that flipped `v71` ALONE, which was false for exactly
        // one commit — `v82`'s gate was still standing. Corrected here rather than
        // left as a sentence that happened to become true.
        //
        // HISTORY, kept because it explains why the gate sat HERE and not at v68 or
        // at the end, and a future reader proposing to reinstate a gate needs it:
        // `v70` has just removed the `messageBody → messageHeader` FK, whose check
        // reads every page of a multi-GB table for one column, which made this gate
        // 2.4–2.5× cheaper here than the same gate at `v68` (3.6–3.8 s vs 9.1 s at
        // 500k headers / 3.4 GB) while still running BEFORE `v82` mutates a row. A
        // closing-only gate would have been cheaper still, but migrations COMMIT
        // INDIVIDUALLY: a failure there strands the database at v82 retrying v83
        // forever, with 15 migrations' work already applied. Also kept from the
        // superseded text, because it was itself a correction and deleting it would
        // re-open the question: an earlier revision claimed this was "THE ONLY
        // whole-database FK gate in the v68…v83 range", which was false (`v82` was
        // also `.deferred`), and a follow-up accused that revision of fabricating a
        // quotation from `v82`, which was ALSO false — the quotation is genuine and
        // hard-wrapped across two lines in `v82`'s step-1 body comment. A null grep
        // is a claim about the QUERY first (`MIS-008`).
        //
        // NOT A BODY CHANGE. `foreignKeyChecks:` is an argument to
        // `registerMigration`, not part of the migration body, so Data Integrity
        // rule 5 is not engaged: a database that has already applied v71 SKIPS it
        // entirely and never runs the new mode; one that has not applies the
        // identical single `ALTER TABLE … ADD COLUMN` under it and reaches the same
        // schema. No SQL, no statement and no migration name changed.
        migrator.registerTimedMigration(
            "v71_addOutboxDraftRfc822MessageId", foreignKeyChecks: .immediate
        ) { db in
            // ⚠ THIS COLUMN IS INERT AS OF `e0d3d30e0` ("Bind draft mutations to
            // provider UID, epoch, and generation"). The matching
            // `OutboxMessage.draftRfc822MessageId` property was deleted 2026-08-05;
            // nothing reads or writes the column. The migration STAYS REGISTERED
            // and unchanged because a migration is immutable once applied — every
            // database that has run v71 has this column, and removing or editing
            // the migration would diverge fresh installs from existing ones.
            // Everything below is the ORIGINAL justification, kept verbatim as
            // history and stated in the past tense; it is not a live mechanism.
            //
            // It carried the DRAFT's own RFC 822 Message-ID, snapshotted at
            // queue-send time so the post-send server-draft cleanup could name the
            // Drafts copy by an identity instead of by the bare IMAP UID
            // `IMAPProvider.saveDraft` returns. Without it, `finalizeOutboxMessage`
            // and `reconcileOutbox` queued a `.deleteDraft` carrying nothing but
            // that UID — which `IMAPProvider.deleteDraft` refuses (a UID is an
            // ADDRESS, not an identity), so the op could only fail and be dropped
            // while the sent draft stayed on the server. `e0d3d30e0` replaced that
            // scheme with the strong address+epoch arm keyed on `v72`'s
            // `draftServerUidValidity`, which is why this one went dark.
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

        migrator.registerTimedMigration(
            "v72_addDraftServerUidValidity", foreignKeyChecks: .immediate
        ) { db in
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
            // SELECT reports the live UIDVALIDITY and it must EQUAL the recorded one (a
            // provable mismatch fails closed; an epoch the server omitted is UNKNOWN and
            // also fails closed, retryably). The delete is then issued against the
            // recorded UID alone. If the gesture's target is already gone that UID
            // addresses nothing and the delete is a clean no-op — the sibling is never
            // even a candidate, because no search ever runs.
            //
            // ⚠️ COMMENT CORRECTED 2026-08-06 (no statement changed — this migration is
            // applied and immutable). The paragraph above used to end "and only then may
            // the recorded UID be FETCHed and corroborated against the recorded rfc822.
            // If the gesture's target is gone the FETCH finds nothing". That FETCH does
            // not exist on v3: `e0d3d30e0` removed the RFC leg entirely, v71's column is
            // inert, and `IMAPProvider.deleteDraftStrong`'s own doc records that it omits
            // the reference's optional RFC corroboration "because v3's typed identity has
            // no RFC leg". The "WHY v71 ALONE WAS NOT THE CLOSURE" paragraph above is
            // kept verbatim because it is the historical argument for THIS migration and
            // is accurate about what v71 did; it describes a path that no longer exists.
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

        migrator.registerTimedMigration(
            "v73_bindDraftUidToMailbox", foreignKeyChecks: .immediate
        ) { db in
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

        migrator.registerTimedMigration(
            "v74_purgeLegacyPendingOperations", foreignKeyChecks: .immediate
        ) { db in
            // ⚑ NO REFERENCE — INVENTED. Owner-approved C6 upgrade boundary:
            // superseded in-flight operations are discarded without decoding.
            // Draft, Outbox, authored content and attachments remain untouched.
            try db.execute(sql: "DELETE FROM pendingOperation")
        }

        migrator.registerTimedMigration(
            "v75_addDraftPushAttemptVersion", foreignKeyChecks: .immediate
        ) { db in
            // PORT — v2final v81 conflict version, with recovery fields omitted.
            try db.alter(table: "draft") { t in
                t.add(column: "pushAttemptVersion", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerTimedMigration(
            "v76_addDraftGenerationAndTypedIdentity", foreignKeyChecks: .immediate
        ) { db in
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

        migrator.registerTimedMigration(
            "v77_addMessageHeaderObservedUidValidity", foreignKeyChecks: .immediate
        ) { db in
            // ⚑ NO REFERENCE — INVENTED. Source-bound IMAP epoch transport,
            // explicitly deferred by v2final commit 486bafd4b. Nullable, with no
            // default and no backfill: existing rows remain unproven rather than
            // adopting the Folder's current epoch by assertion.
            try db.alter(table: "messageHeader") { t in
                t.add(column: "observedUidValidity", .integer)
            }
        }

        migrator.registerTimedMigration(
            "v78_addPendingOperationEverAttempted", foreignKeyChecks: .immediate
        ) { db in
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
        migrator.registerTimedMigration(
            "v79_addDraftLastTouchedSeq", foreignKeyChecks: .immediate
        ) { db in
            // ⚠️ `seedDraftLastTouchedSeq`'s correlated subquery is QUADRATIC in the
            // number of `draft` rows — measured 2.9 ms → 252 ms for a 10× row count.
            // ⚠️ **THE ORIGINAL JUSTIFICATION NAMED A CAP THAT DOES NOT BOUND THIS
            // TABLE — corrected 2026-08-05 (round-10 F12), registered as
            // `IOS-DRAFT-017`. The MIGRATION BODY IS UNCHANGED and must stay so (a
            // migration is immutable once applied), and the eviction exemption below
            // is UNCHANGED and deliberate. This is a comment-only correction.**
            //
            // Retained verbatim as the original claim: *"It is safe ONLY because the
            // table is capped: `SyncEngineMaintenance` evicts drafts down to
            // `SyncConfig.maxComposeDraftSessions` (10), so the realistic input is
            // tens of rows, not thousands."*
            //
            // `DraftStore.evictImpl` `continue`s over inbox-tied EXEMPT drafts
            // WITHOUT counting them toward `kept`. An exempt row is therefore not
            // merely retained past the cap — it does not CONSUME the cap. The
            // retained set is `maxComposeDraftSessions + |exempt|`, and `|exempt|` is
            // bounded by the size of the user's inbox, not by any config. So the cap
            // bounds the non-exempt population only, and "tens of rows, not
            // thousands" is an assumption about a user's inbox, not a guarantee the
            // code makes.
            //
            // What IS true is that the cost is measured rather than assumed, and it
            // stays bounded and one-time. Round-8 (A4) timings of this body, on a
            // Mac — device-adjusted ×2–4 per this repo's standing rule, because Mac
            // timings understate device by that factor:
            //   100 rows → 2 ms · 300 rows → 9 ms · 1,000 rows → 93 ms ·
            //   3,000 rows → 841 ms.
            //
            // **Raising `maxComposeDraftSessions` makes this migration quadratically
            // more expensive for every device that has not yet run it** — a database
            // sitting at v78 today still pays the new cost tomorrow — and so does
            // anything that widens the exemption predicate, which is the input this
            // comment used to be blind to. If the RETAINED count (cap + exempt, not
            // the cap alone) can reach ~1,000, re-measure this body or replace the
            // subquery with a window function before shipping.
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
        migrator.registerTimedMigration(
            "v80_addDraftReplyTargetAddress", foreignKeyChecks: .immediate
        ) { db in
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
        // so an index here is unjustified.
        //
        // 🚨 SCHEMA ONLY — THERE IS DELIBERATELY NO BACKFILL. An earlier revision of
        // this body followed the `ADD COLUMN` with
        // `UPDATE messageHeader SET actionTagSetAt = ? WHERE actionTag IS NOT NULL`,
        // binding `Date()`. It was removed 2026-08-05. Harness-measured at profile H
        // (500k headers / 3.4 GB, `scratchpad/MIGRATION_COST`): the `UPDATE`
        // statement alone took **1,320.8 ms**, and it was the ENTIRE reason this
        // migration needed transient WAL headroom — peak file+WAL+shm fell from
        // **3,697.7 MB to 3,388.1 MB** when it was removed, i.e. **309.6 MB** of
        // required free space, one half of the documented precondition. The body is
        // now 0.9 ms. A full consumer census shows what that bought.
        //
        // THE LEGACY-ROW RULE, which is what replaces it. A row that was already
        // carrying an action tag when `v81` ran keeps `actionTagSetAt = NULL`.
        // `actionTagSetAt` has exactly ONE production reader,
        // `SyncEngine.sweepStaleActionTags`, whose TTL test is
        // `if let setAt = msg.actionTagSetAt, setAt > cutoff { continue }` — so a
        // NULL stamp is treated as ALREADY EXPIRED. That is the deliberate fail-safe
        // direction recorded at the sweep itself, and it matches TB's
        // `purgeExpiredActionEntries`, where a missing timestamp is likewise treated
        // as expired (ADR-IOS-008). The whole user-visible difference the backfill
        // made: a legacy tag on a message that had ALREADY LEFT THE INBOX is cleared
        // on the next maintenance pass instead of after a further week. The sweep
        // iterates non-inbox folders only (`Folder.filter(… role != inbox)`), because
        // action tags are inbox-scoped and the chip must not follow a message into
        // Archive/Trash — so tags on inbox messages are unaffected either way, and
        // clearing an out-of-inbox tag is precisely what the sweep exists to do.
        // This state is not new: `ReplyParentResolver` documents a path that
        // "Deliberately does NOT stamp `actionTagSetAt`", so
        // `actionTag != nil ∧ actionTagSetAt == nil` is already designed for.
        //
        // ⚠️ NEGATIVE CASE, and it is the important half: this is NOT licence for a
        // GOING-FORWARD writer to skip the stamp. Every writer after `v81` must keep
        // `actionTag != nil ⇒ actionTagSetAt != nil`, which is exactly what
        // `MessageHeader.setActionTag` enforces atomically. The relaxation applies to
        // pre-`v81` rows and to nothing else.
        //
        // `foreignKeyChecks: .immediate` — SAFE, and one statement away from not
        // being. `messageHeader` is the PARENT of `messageReference` and
        // `messageUserLabel`, and its own `accountId` is a CHILD key into `account`.
        // `ADD COLUMN` writes no key of either kind. ⚠️ NEGATIVE CASE: if a row-
        // touching statement is ever added here and it writes `id`,
        // `ON UPDATE NO ACTION` would ABORT it under `.immediate` while `.deferred`
        // would pass whenever the final state happened to be consistent. Adding one
        // means re-deciding this mode.
        //
        // ⚠️ FREE SPACE — REDUCED, NOT REMOVED. Dropping the backfill removes `v81`'s
        // half of the transient WAL headroom requirement; `v82` still needs ~300 MB
        // on its own and that is unavoidable (it is a genuine table rebuild). The
        // precondition therefore stays open — registered as `IOS-MIGRATION-003` in
        // `KNOWN_ISSUES.md` — and this body must not grow a full-table pass back
        // without re-measuring the peak.
        //
        // CONVERGENCE (Data Integrity rule 5): additive and idempotent. A fresh
        // install and an existing database both end with one nullable column and no
        // row touched.
        migrator.registerTimedMigration(
            "v81_addActionTagSetAt", foreignKeyChecks: .immediate
        ) { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "actionTagSetAt", .datetime)
            }
        }

        // v82: account-scoped `userLabel` identity (D10 / `IOS-LABEL-001`).
        //
        // 🚨 THE DEFECT. `v33_userLabelSupport` made the PROVIDER's label id the primary
        // key (`t.primaryKey("id", .text)`), but a provider label id is unique only
        // WITHIN an account. Two accounts with a `Receipts` Gmail label, or two IMAP
        // accounts using a `work` keyword, shared ONE row. Three verified consequences:
        // (1) the row's owner FLAPPED — the Gmail arm upserts with `.save(db)` so the
        // last account to sync overwrote `accountId`/`name`/`isSystem`, while the IMAP
        // arms `insert(onConflict: .ignore)` so the FIRST writer won forever and later
        // accounts silently bound to a row naming someone else's account; (2) a CASCADE
        // CROSSED THE ACCOUNT BOUNDARY — the Gmail stale sweep's FILTER is account-scoped
        // but the ROW was global, and `messageUserLabel.userLabelId` references this
        // table `onDelete: .cascade`, so account A removing a label server-side deleted
        // every association row for account B's messages; (3) the two display readers
        // (`UserLabelStore.loadLabels` / `labelsForMessage`) join by id alone, so B's
        // chips rendered A's name.
        //
        // 🚨 THE FIX — split identity from the wire value, completing the pattern
        // `folder` and `messageHeader` already have. `id` becomes the deterministic
        // surrogate `"<accountId>:<providerLabelId>"` (cf. `Folder.id`), and the BARE
        // provider value moves to its own `providerLabelId` column (cf. `Folder.path`),
        // which is what every wire path reads. A composite primary key `(accountId, id)`
        // was considered and rejected: it forces an `accountId` column onto
        // `messageUserLabel` and rewrites its foreign key — strictly more surgery — and
        // it still leaves the wire paths with no clean bare value to read.
        //
        // ⚠️ NEVER split the surrogate back apart on ':' — a provider label id may itself
        // contain a colon (this repo has a live defect from exactly that assumption).
        // Read the account from `accountId`, the wire value from `providerLabelId`.
        //
        // CONVERGENCE (Data Integrity rule 5). A fresh install runs `v33` (old shape) and
        // then this migration over EMPTY tables: the delete matches nothing, both
        // snapshots are empty, all four inserts move zero rows, and only the schema
        // changes. An existing database runs the same body over real rows and rewrites
        // their ids. Both reach the identical schema and the identical id shape.
        //
        // 🚨 FOREIGN KEYS / THE CASCADE — READ THIS BEFORE TOUCHING A SINGLE STATEMENT
        // OF THE BODY. `foreignKeyChecks: .immediate` AS OF 2026-08-06, so foreign keys
        // are ENFORCED LIVE, PER STATEMENT, while the body runs.
        //
        // ⚠️ THIS PARAGRAPH SAID THE OPPOSITE UNTIL 2026-08-06 and the superseded
        // reasoning is stated here rather than deleted, because it is the reasoning a
        // reader will otherwise re-derive: it ran `.deferred`, i.e. the whole body under
        // `PRAGMA foreign_keys = OFF` followed by a full `PRAGMA foreign_key_check`
        // before commit, and it argued that this made consequence (2)'s cascade a
        // STRUCTURAL no-op — no FK action CAN fire when foreign keys are off — while the
        // trailing check proved every rebuilt reference resolved. Both halves were true.
        // Neither is load-bearing any more, and here is the replacement for each.
        //
        //  • THE CASCADE CANNOT REACH ANYTHING THAT MATTERS. With foreign keys ON,
        //    `DROP TABLE` performs an implicit `DELETE FROM`, which fires
        //    `ON DELETE CASCADE` on children. The body drops the CHILD
        //    (`messageUserLabel`) BEFORE the PARENT (`userLabel`) and recreates the
        //    child only AFTER the parent is repopulated, so the parent's implicit
        //    delete finds no child to cascade to and no cascade fires at all.
        //    Verified per statement, all thirteen of them, against a census of the
        //    referrers. ⚠️ ALL THREE COUNTS BELOW WERE RE-DERIVED WITH AN INSTRUMENT
        //    THIS COMMENT CANNOT ENTER (R16-7, 2026-08-06). As first written they were
        //    bare `rg` invocations that MATCHED THEMSELVES: the naive greps return 3, 1
        //    and 1 rather than the TWO / ZERO / zero claimed, because each sentence
        //    quoting a pattern is a hit for it. `MIS-033` — and note the countermeasure
        //    was already in this file about 530 lines above, with its own `MIS-033`
        //    citation, and simply was not applied here. Predicates, all excluding `//`
        //    and `///` lines by negative lookahead, all rooted at
        //    `TabMail/ Shared/ TabMailNotificationService/`:
        //      · `rg -c --pcre2 '^(?!\s*(///|//)).*references\("userLabel"'` → **2**,
        //        both in this file (`v33`'s create and step 4 below) and BOTH of them
        //        `messageUserLabel`. (Naive: 3.)
        //      · `rg -c --pcre2 '^(?!\s*(///|//)).*references\("messageUserLabel"'` →
        //        **no output, exit 1** — nothing can be cascaded into. (Naive: 1.)
        //      · `rg -i -c --pcre2 '^(?!\s*(///|//)).*CREATE TRIGGER'` → **4**,
        //        all later v85 direct-AI lifecycle triggers. None exists while v82
        //        runs, and SQLite's implicit `DROP TABLE` delete does not fire
        //        triggers in any case. (Before v85 this live census was zero.)
        //    Non-vacuity for the predicates: the FIRST returns a non-empty 2 and the
        //    trigger predicate returns 4, so the lookahead demonstrably does not
        //    swallow live code.
        //    The two `CREATE TABLE … AS SELECT` snapshots carry no constraints (SQLite
        //    copies none through CTAS), so they neither block a drop nor participate in
        //    a cascade, and SQLite's implicit delete does not fire triggers in any case.
        //  • THE TRAILING PROOF IS NOW A PER-STATEMENT PROOF. Step 5 writes the SAME
        //    expression over the SAME join that step 3a inserted from, so every parent
        //    it names provably exists; step 3a's `accountId` comes from
        //    `messageHeader.accountId`, itself an enforced FK to `account`; step 3b's
        //    comes from the legacy snapshot of `userLabel.accountId`, also an enforced
        //    FK. A dangling value in 3b would abort at that statement instead of at the
        //    closing check — the SAME outcome (the migration rolls back, launch bricks),
        //    reached one statement earlier. What is genuinely LOST is the sweep over
        //    tables this migration never touches; see the negative case below.
        //
        // ⚠️ THE DROP ORDER IS **NOT** LOAD-BEARING — SAID PLAINLY BECAUSE TWO
        // SUCCESSIVE REVISIONS OF THIS COMMENT CLAIMED IT WAS. The previous revision
        // recorded a conditional — *"If this ever moves to `.immediate`, that ordering
        // becomes load-bearing"* — and the first draft of THIS revision (2026-08-06)
        // upgraded it to *"the drop order is load-bearing now"* on the strength of that
        // inherited sentence rather than on a measurement. Then it was measured, and it
        // is false. Swapping the two `db.drop` calls so `userLabel` goes first was
        // built and run against `MigrationForeignKeyModeTests`: all three tests still
        // pass, all 14 seeded memberships survive with their correct re-pointed ids,
        // and the database is still foreign-key clean. Nothing aborts.
        //
        // WHY it is harmless, which is the fact worth keeping: **step 2's snapshots are
        // the safety mechanism, not the ordering.** After step 2, every subsequent
        // statement reads exclusively from `messageUserLabel_v82_legacy`,
        // `userLabel_v82_legacy` and `messageHeader` — NOTHING reads the live
        // `messageUserLabel` again. So a cascade that empties it before it is dropped
        // destroys a table whose contents are already copied and which is dropped on
        // the next line regardless. Dropping child-first is the `v2` house pattern and
        // is worth keeping for that reason; it is not what makes this body safe.
        //
        // 🚨 THE REAL LOAD-BEARING STATEMENT IS STEP 2. Deleting either snapshot, or
        // re-sourcing step 3a/5 from the live `messageUserLabel` instead of the
        // snapshot, silently rebuilds an EMPTY join table — every user label chip in
        // the app disappears and the database is still perfectly foreign-key clean, so
        // the violation-count test cannot see it. That is the mutation
        // `v82PreservesLabelMembershipsAcrossTheRebuild` is red against (verified by
        // pointing step 5 at the live table: 0 of 14 memberships survive).
        //
        // WHY IT MOVED — cost, measured on hardware. On the owner's device upgrading
        // v67 → v83 (5 accounts / 78 folders) `MigrationTimingLedger` attributed
        // `v82 total 7,235ms = body 7ms + fkCheck/commit 7,228ms [.deferred]`: the
        // whole-database check cost a THOUSAND TIMES the body. ⚠️ The claim this
        // replaces — *"It is kept `.deferred` on COST, not on safety: `.immediate` pays
        // per-row FK enforcement on the 1M-row step-5 insert and measures SLOWER
        // (8,571 ms body vs 6,309 ms deferred at 500k headers)"* — was a harness
        // measurement at profile H (500k headers / 1M associations) and it is not
        // retracted: at THAT shape `.immediate` really does cost ~+2,262 ms of body.
        // It is outweighed, because the check it removes is a whole-database scan
        // (the same post-`v70` gate measured 3.6–3.8 s at profile H when `v71` ran it).
        // ⚠️ The number NOT measured, named so nobody quotes an inference as data:
        // `v82`'s OWN `.deferred` check at profile H was never isolated. If this trade
        // is ever revisited, measure that — do not re-argue it from `v71`'s figure, and
        // do not restore the gate as a cost instrument; it is a correctness one.
        //
        // With this change the `.immediate` range — `v68` to the top of the chain,
        // `v86` as of the folder-role lifecycle correction — runs ZERO
        // whole-database foreign-key gates.
        // `v2_dropMessageHeaderFolderFK` is the only explicitly `.deferred` migration
        // left in the file, and it applied on every shipped device long ago. (This
        // said "the v68…v83 range"; the regime is an open interval and the endpoint
        // was stale one migration later. Predicate: the section header above.)
        //
        // BEST-EFFORT `name`. A row reconstructed for account B in step 3a inherits
        // whatever `name`/`isSystem` the hijacked shared row was carrying, because that
        // is the only evidence in the database. The SERVER is the source of truth and
        // the next sync of that account overwrites both. No lookup is invented here.
        //
        // ⚠️ FREE SPACE — same requirement as `v81`: ~300 MB of WAL at profile H
        // (500k headers / 1M associations / 3.4 GB), held until the single
        // transaction commits. The file does NOT grow across the migration
        // (3,385.4 MB before → 3,385.4 MB after), so this is a transient headroom
        // requirement, not a permanent one. Registered as `IOS-MIGRATION-003`
        // (renumbered 2026-08-05: `IOS-MIGRATION-001` was in use for a different
        // subject). Since `v81`'s backfill was dropped, THIS body is the only one
        // in the range that carries the precondition.
        //
        // ✅ CLOSED DECISION — STEP 5's PLAN IS ALREADY OPTIMAL; DO NOT "OPTIMISE" IT.
        // The obvious idea is to index `messageUserLabel_v82_legacy` so step 5's
        // `JOIN messageHeader` has a driving index. Measured at profile H, that is a
        // PESSIMIZATION: 11,279 ms with the snapshot index vs 10,424 ms without.
        // Building the index costs more than the hash join it replaces, and the
        // snapshot table is dropped four statements later, so the index is never
        // reused. Same for step 3a — the `DISTINCT` already reduces the join input to
        // the tiny pair set, which is why it is written that way.
        migrator.registerTimedMigration(
            "v82_accountScopedUserLabelIdentity", foreignKeyChecks: .immediate
        ) { db in
            // 1. An association whose owning message is gone cannot be re-pointed —
            //    steps 3a and 5 need `messageHeader.accountId` to name the owner. Leaving
            //    such a row would strand it on a bare id that no rebuilt `userLabel` row
            //    carries, and the closing `foreign_key_check` would then fail the whole
            //    migration (a launch brick). It renders nothing to the user, and the
            //    server re-supplies the association on the next sync of that message.
            //    Expected to match zero rows, for TWO independent reasons — name both,
            //    because the first one alone is what an earlier revision of this comment
            //    said and it is no longer true:
            //      (a) `messageUserLabel.messageId` declares `onDelete: .cascade` from
            //          `messageHeader`, so deleting a header takes its associations with
            //          it. This is the real guarantee and it holds unconditionally.
            //      (b) every PRIOR migration ends with a check that would have caught an
            //          orphan — but the CHECK IS NOT THE SAME ONE EVERYWHERE.
            //          ⚠️ CORRECTED 2026-08-05. This comment used to read "every migration
            //          on this line ends with a full foreign-key check." That was TRUE
            //          WHEN WRITTEN and was invalidated ONE COMMIT LATER by `204590b34`,
            //          which converted 14 migrations to `foreignKeyChecks: .immediate`.
            //          ⚠️ RE-DERIVED AGAIN 2026-08-06, mechanically and not by arithmetic
            //          on the previous figures, because BOTH `v71` and `v82` changed
            //          mode: 83 registered migrations — **16** explicit `.immediate`,
            //          **1** explicit `.deferred` (`v2` alone), **66** taking
            //          `registerTimedMigration`'s default, which IS `.deferred`. So
            //          **67 of 83 end with a whole-database `PRAGMA foreign_key_check`
            //          and 16 do not** — and NONE of the 67 is in the `.immediate`
            //          range, which runs no whole-database gate at all. (It was 69/14
            //          with both gates, 68/15 with only `v82`'s.)
            //          ⚠️ RE-DERIVED AGAIN AT R17-6, because `v84` invalidated every
            //          integer in the paragraph above and nobody came back for them —
            //          which is the very lesson recorded at the bottom of this comment,
            //          committed a third time. The figures are kept verbatim as the
            //          2026-08-06 reading and superseded here rather than overwritten:
            //          **84** registered, **17** explicit `.immediate` (v68…v84,
            //          contiguous), **1** explicit `.deferred`, **66** default ⇒
            //          **67 of 84 end with the whole-database check and 17 do not**.
            //          The 67 is unchanged because `v84` joined the `.immediate` side.
            //          Predicates, comments excluded so this paragraph cannot satisfy
            //          them (`MIS-033`):
            //            rg -o '"v([0-9]+)_[A-Za-z0-9_]+"' -r '$1' <this file> | sort -n -u | wc -l
            //            rg -c --pcre2 '^(?!\s*(///|//)).*foreignKeyChecks: \.immediate' <this file>
            //            rg -c --pcre2 '^(?!\s*(///|//)).*foreignKeyChecks: \.deferred'  <this file>
            //          Re-derived after v85: **85** registered, **18** explicit
            //          `.immediate` (v68…v85, contiguous), **1** explicit
            //          `.deferred`, **66** default ⇒ **67 of 85** end with the
            //          whole-database check and 18 do not. The 67 is unchanged
            //          because v85 joined the immediate side.
            //          Re-derived after v86: **86** registered, **19** explicit
            //          `.immediate` (v68…v86, contiguous), **1** explicit
            //          `.deferred`, **66** default ⇒ **67 of 86** end with the
            //          whole-database check and 19 do not. The 67 is unchanged
            //          because v86 joined the immediate side.
            //          Re-derived after v87: **87** registered, **20** explicit
            //          `.immediate` (v68…v87, contiguous), **1** explicit
            //          `.deferred`, **66** default ⇒ **67 of 87** end with the
            //          whole-database check and 20 do not. The 67 is unchanged
            //          because v87 joined the immediate side.
            //          ⚠️ THIS MIGRATION IS ONE OF THE 20: reason (b) below is now a
            //          statement about migrations that
            //          ran on shipped devices long ago, not about this chain.
            //          Confirmed against GRDB's own
            //          `GRDB/Migration/Migration.swift`: `runWithDeferredForeignKeysChecks`
            //          calls `db.checkForeignKeys()` before commit, while
            //          `runWithImmediateForeignKeysChecks` calls NOTHING — it runs the body
            //          with foreign keys left ON, i.e. per-statement enforcement.
            //    ⚠️ NEGATIVE CASE — the correction changes nothing here, and saying why is
            //    the point: an `.immediate` migration cannot create an orphan either, it
            //    just proves it per statement instead of once at the end. So (b) is
            //    weaker than it was but not absent, and (a) never depended on it. The
            //    `DELETE` stays regardless, because doing it explicitly makes step 5's
            //    totality a LOCAL fact rather than an inherited cross-migration invariant
            //    — which is exactly the property that survived the invalidation.
            //    📌 THE DURABLE LESSON, recorded here because this comment is the evidence:
            //    a commit that changes a MODE, a DEFAULT, or a FLAG owes a grep for every
            //    comment that asserted the old one. `204590b34` ("Run 14 of 16 range
            //    migrations with immediate foreign-key checks") changed the mode and left
            //    this sentence standing — and it was then cited as evidence, twice, before
            //    anyone re-derived it.
            try db.execute(sql: """
                DELETE FROM messageUserLabel
                WHERE NOT EXISTS (
                    SELECT 1 FROM messageHeader mh WHERE mh.id = messageUserLabel.messageId
                )
                """)

            // 2. Snapshot both tables before touching either (the `v2` pattern). Step 3a
            //    reads the associations to discover which accounts actually reference
            //    each legacy label, so the associations must survive the rebuild of
            //    `userLabel`.
            try db.execute(sql: """
                CREATE TABLE userLabel_v82_legacy AS
                SELECT id, accountId, name, isSystem FROM userLabel
                """)
            try db.execute(sql: """
                CREATE TABLE messageUserLabel_v82_legacy AS
                SELECT messageId, userLabelId FROM messageUserLabel
                """)

            // 3. Rebuild `userLabel` in the new shape. Dependent table first, matching
            //    `v2`. SQLite cannot add a NOT NULL column without a default nor change a
            //    primary key in place, so recreate-and-copy is the only route.
            try db.drop(table: "messageUserLabel")
            try db.drop(table: "userLabel")
            try db.create(table: "userLabel") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("providerLabelId", .text).notNull()
                t.column("name", .text).notNull()
                t.column("isSystem", .integer).notNull().defaults(to: false)
            }

            // 3a. THE REPAIR FOR CONSEQUENCE (1). One row per (owning message's account,
            //     legacy bare label id) pair the surviving associations reference. This is
            //     what gives account B a B-OWNED row to point at instead of the row whose
            //     `accountId` account A had hijacked. The `DISTINCT` runs first so the
            //     name lookup joins the tiny pair set, not every association row.
            try db.execute(sql: """
                INSERT OR IGNORE INTO userLabel (id, accountId, providerLabelId, name, isSystem)
                SELECT p.accountId || ':' || p.labelId, p.accountId, p.labelId,
                       COALESCE(l.name, p.labelId), COALESCE(l.isSystem, 0)
                FROM (
                    SELECT DISTINCT mh.accountId AS accountId, mul.userLabelId AS labelId
                    FROM messageUserLabel_v82_legacy mul
                    JOIN messageHeader mh ON mh.id = mul.messageId
                ) p
                LEFT JOIN userLabel_v82_legacy l ON l.id = p.labelId
                """)

            // 3b. …then every legacy row under its OWN recorded account, so a label the
            //     user CREATED BUT NEVER APPLIED survives the rewrite. Dropping those
            //     would destroy a label the user made — a dropped user intention. The
            //     `OR IGNORE` can only skip a row 3a already inserted, and those two are
            //     the same label: `accountId` is a colon-free UUID string (`Account.init`
            //     / `DemoSeed.demoAccountId`), so `accountId || ':' || labelId` is
            //     injective and equal ids force equal accounts AND equal provider ids.
            try db.execute(sql: """
                INSERT OR IGNORE INTO userLabel (id, accountId, providerLabelId, name, isSystem)
                SELECT l.accountId || ':' || l.id, l.accountId, l.id, l.name, l.isSystem
                FROM userLabel_v82_legacy l
                """)

            // 4. Recreate the join table unchanged in shape (only its VALUES are rewritten).
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

            // 5. Re-point every surviving association at ITS OWN account's row, using the
            //    same expression and the same join 3a inserted from — so every value
            //    written here provably exists in the rebuilt `userLabel`. Inserting into
            //    a fresh table rather than `UPDATE`-ing in place is deliberate: an
            //    in-place update of a primary-key column can collide TRANSIENTLY with a
            //    not-yet-rewritten sibling row (a keyword literally named
            //    `"<accountId>:x"`), and that collision would abort the migration and
            //    brick launch. A plain `INSERT` is provably conflict-free here: for one
            //    message the account is a single value, and prefixing a fixed string is
            //    injective, so distinct source rows stay distinct.
            try db.execute(sql: """
                INSERT INTO messageUserLabel (messageId, userLabelId)
                SELECT mul.messageId, mh.accountId || ':' || mul.userLabelId
                FROM messageUserLabel_v82_legacy mul
                JOIN messageHeader mh ON mh.id = mul.messageId
                """)

            // 6. No legacy bare-id row survives — the rebuilt table was populated only
            //    from steps 3a/3b, both of which write prefixed ids. Drop the snapshots.
            try db.drop(table: "messageUserLabel_v82_legacy")
            try db.drop(table: "userLabel_v82_legacy")
        }

        // v83: partial index for `InboxViewModel.markAllAsRead`'s keyset sweep.
        //
        // 🚨🚨 THE BODY OF THIS MIGRATION IS EMPTY AS OF 2026-08-06. THE INDEX IS
        // REAL AND STILL REQUIRED; ONLY ITS BUILD MOVED. It is created by
        // `SyncEngine.runBuildDeferredIndexesIfMissing`, the background WAL
        // maintenance pass, from the SAME `CREATE INDEX IF NOT EXISTS` statement —
        // `SyncEngine.deferredIndexes` is the one place the DDL lives now. Everything
        // below about WHY the index exists, WHY it is partial, and WHY it must be
        // chosen by the planner is unchanged and still governs; only the sentences
        // about WHEN it is built have moved, and they say so where they occur.
        //
        // WHY IT MOVED — cost, measured on hardware. On the owner's device upgrading
        // v67 → v83 (5 accounts / 78 folders) `MigrationTimingLedger` attributed
        // **5,050 ms** to `v83`, all of it this one `CREATE INDEX` over the whole
        // `messageHeader` table, paid before any UI appears. Together with `v71`'s and
        // `v82`'s retired foreign-key gates that is 24,360 ms of a 27,601 ms chain.
        // Owner directive, 2026-08-05: *"startup migrations should really have only
        // things that are absolutely necessary and blocking. Other things should
        // happen durably in the heal/sync/background queues."* The `ANALYZE` half of
        // this body moved for the same reason a day earlier; this is the other half.
        //
        // CONVERGENCE (Data Integrity rule 5) — THE ARGUMENT, IN FULL, BECAUSE THIS IS
        // A BODY CHANGE TO AN ALREADY-APPLIED MIGRATION AND THAT IS NORMALLY BANNED.
        // Rule 5's two prohibited shapes are APPENDING statements to an applied body
        // (they never execute on a database that already ran it) and RENAMING it (GRDB
        // re-runs the whole body and fails on the existing objects). This is neither:
        // the identifier is frozen, and the body only ever SHRANK. The three
        // populations and where each ends up:
        //   • A database that ran `v83` BEFORE this change — has the index. The empty
        //     body does not run again. Unchanged.
        //   • A database that has not reached `v83` yet, and every fresh install — runs
        //     the empty body, does NOT get the index from the migration, and gets it
        //     from the first background maintenance pass.
        //   • A database that never reaches the maintenance pass — see the accepted
        //     window below.
        // All three converge on the identical schema because
        // `CREATE INDEX IF NOT EXISTS` is idempotent and the pass runs from BOTH the
        // foreground poll and the BGProcessing drain, re-arming itself on every launch
        // until it succeeds. Nothing reads or writes a row either way.
        //
        // ⚠️ THE ACCEPTED WINDOW, stated because this change creates it. Between an
        // upgrade launch and the first maintenance pass, `markAllAsRead` sorts through
        // a temp B-tree. It is SLOW, not wrong: the same rows are returned in the same
        // order. Recoverable without any user gesture, so it fails closed and is
        // registered (`IOS-PERF-005`) rather than mechanised — THE MANTRA.
        //
        // 🚨 THIS PARAGRAPH USED TO LICENSE THE WINDOW WITH *"the pre-`v83`
        // behaviour, i.e. every shipped release up to and including `v1.6.38`"* — AND
        // THAT WAS FALSE (R16-4, corrected 2026-08-06). Shipped's `markAllAsRead`
        // (`07a4bb703:TabMail/ViewModels/InboxViewModel.swift`, quoted against an
        // immutable tag) fetches `.filter(folderId == fid && isRead == false)
        // .limit(batchSize)` with **NO `ORDER BY` at all**, so it never sorted and
        // never had the O(U²/50) shape. The ordered keyset sweep was introduced
        // IN-RANGE by `a790dd61d` (2026-08-03), which
        // `git merge-base --is-ancestor a790dd61d 07a4bb703` reports is **not** an
        // ancestor of the shipped tag (exit 1). The window is therefore a real
        // in-range REGRESSION, not a restoration of shipped behaviour: 357,400 rows /
        // 100,000 unread / fresh-install `sqlite_stat1` measures shipped's unordered
        // sweep at **7,889 ms**, the current sweep WITH the index at **4,610 ms**, and
        // the current sweep WITHOUT it at **43,296 ms** — **5.5× worse than shipped**,
        // 86.6–173.2 s at this repo's 2–4× Mac-understates-device factor.
        // ⚠️ THE ACCEPTANCE SURVIVES THE CORRECTION, ON A DIFFERENT BASIS, and the
        // basis is the only thing that licenses it: the window is transient and
        // self-healing (the pass re-arms on every foreground poll and BGProcessing
        // drain until it succeeds), not a permanent state. It is NOT licensed by
        // equivalence to shipped, and the two remedies that would restore
        // equivalence are both worse — see the "Do NOT" pair on `IOS-PERF-005`:
        // restoring `v83`'s body re-imposes 5,050 ms before first paint, and
        // restoring shipped's UNORDERED fetch removes the `ORDER BY` that IS the
        // sweep's loop variant.
        // ⚠️ NEGATIVE CASE, so this is not read as licence: an index whose absence
        // changes a RESULT, or that a query names in an `INDEXED BY` clause (SQLite
        // *errors* when such an index is missing), or that a write depends on for
        // uniqueness, may NOT move. `messageHeader_unreadSweep` is named in no
        // `INDEXED BY` clause anywhere in `TabMail/ Shared/ TabMailNotificationService/`
        // — that is a checked fact, not an assumption, and it is the check to re-run
        // before deferring the next one.
        //
        // ⚠️ RE-RUN IT WITH THE PAIR OF COMMANDS ON `SyncEngineMaintenance
        // .deferredIndexes`, NOT WITH A BARE GREP FOR THE INDEX NAME. This banner
        // used to send the next author to a check that matched the sentence
        // describing it — one hit, from prose — so the re-run could never come back
        // clean and the reader could not tell prose from SQL (`MIS-033`). Those two
        // commands exclude `//` and `///` lines by construction, and the second one
        // is the non-vacuity half: it must return the four live hints, or the first
        // one's silence proves nothing.
        //
        // 🚨 THE DEFECT IS A PLAN, NOT A QUERY. `markAllAsRead` runs three statements
        // per folder — a frozen upper-bound probe (`ORDER BY id COLLATE BINARY DESC
        // LIMIT 1`), a first page, and a cursor page (`id > ? AND id <= ?`), all under
        // `folderId = ? AND isRead = 0`, all ordered by `id`. EVERY pre-existing
        // candidate index orders by `date` (`messageHeader_folderId_isRead_date`,
        // `messageHeader_inbox_display`, …), so SQLite satisfies the WHERE from an
        // index and then SORTS — `USE TEMP B-TREE FOR ORDER BY` — once per page, over
        // the whole remaining unread set. That is the O(U²/50) shape. The sweep design
        // itself (frozen upper bound + unconditional cursor advance) is correct and is
        // NOT what this migration touches.
        //
        // ⚠️ WHY IT DOES NOT REPRODUCE UNDER `ANALYZE` — read this before "confirming"
        // it on a freshly-analyzed database. The plan is a function of `sqlite_stat1`,
        // and the two regimes diverge completely (measured, SHAPE M = 5 accounts ×
        // 8 folders, unread interleaved with read, sweeping the 5-INBOX unified set,
        // WAL, `batchSize = SyncConfig.inboxPageSize`, committed per page):
        //
        //     stats     U         no index      with this index    read-phase only
        //     stale     20,000     6,289 ms          1,220 ms      5,217 → 124 ms
        //     stale    100,000   199,425 ms          6,300 ms    193,053 → 986 ms
        //     fresh    100,000     6,747 ms          6,469 ms      1,055 → 946 ms
        //
        // What this DOES NOT fix, stated so nobody re-measures expecting more: once
        // the quadratic term is gone the sweep is WRITE-bound — 85–89% of the
        // remaining wall clock is `UPDATE` + `COMMIT` across ~2,000 separate committed
        // pages. No read-side index can touch that. This removes the quadratic; it
        // does not make a 100k-message sweep fast in absolute terms.
        //
        // STALE IS THE SHIPPED REGIME — this is a statement about the SHIPPED
        // release, and it is why the measurement above was taken that way. In every
        // shipped build `ANALYZE` ran only inside migration bodies, never
        // periodically, and on a FRESH INSTALL a migration's `ANALYZE` records stats
        // for an EMPTY `messageHeader`, so a device that then syncs 100k messages
        // carries "table is empty" statistics forever. So the index, not `ANALYZE`,
        // is the load-bearing fix; the 1.0× "fresh" row above is the number you get
        // if you measure on a database no user has. (As of the ADR-IOS-029
        // 2026-08-05 amendment the background pass does refresh statistics — see
        // `SyncEngine.runRefreshPlannerStatisticsIfStale` — which makes the "fresh"
        // row reachable for the first time. It does not change the conclusion: the
        // partial index is what removes the quadratic, in both regimes.)
        //
        // PARTIAL, not `(folderId, isRead, id)` — measured both:
        //   • plan: partial serves all THREE statements with no temp B-tree
        //     (`Q1 SEARCH … USING COVERING INDEX messageHeader_unreadSweep (folderId=?)`,
        //      `Q2/Q3 … (folderId=? AND id<?)` / `(folderId=? AND id>? AND id<?)`).
        //   • size at 100k rows / 10% unread: 377 KB (92 pages) vs 3.86 MB (942 pages).
        //   • insert cost, 50k rows in one transaction: +1.38% vs +3.27%.
        // It also shrinks as mail is read, which the three-column form does not.
        //
        // COLLATION. `messageHeader.id` is `TEXT PRIMARY KEY` with NO `COLLATE` clause,
        // so its collation is BINARY — verified structurally (`PRAGMA index_xinfo` on
        // `sqlite_autoindex_messageHeader_1` reports `coll=BINARY`) and behaviourally
        // (`ORDER BY id` and `ORDER BY id COLLATE BINARY` agree; `COLLATE NOCASE`
        // differs). The index therefore matches the queries' explicit `COLLATE BINARY`
        // without needing one of its own.
        //
        // THERE IS NO `ANALYZE` IN THIS BODY, AND THAT IS A DECISION — not an
        // oversight, and not a violation of ADR-IOS-029 rule 5. Rule 5's
        // REQUIREMENT survives in full: an index-changing migration still causes a
        // whole-database `ANALYZE`. Only its TIMING moved off the blocking launch
        // path, to `SyncEngine.runRefreshPlannerStatisticsIfStale`, which the
        // background WAL maintenance pass runs once per schema change. Owner
        // directive, 2026-08-05: *"startup migrations should really have only
        // things that are absolutely necessary and blocking. Other things should
        // happen durably in the heal/sync/background queues."* Recorded as the
        // 2026-08-05 amendment to ADR-IOS-029; read it before adding one back.
        // ⚠️ As of 2026-08-06 there is no `CREATE INDEX` in this body either, for the
        // same reason and by the same route — see the banner at the top of this
        // block. The two deferrals are ordered inside one maintenance pass: index
        // first (its DDL bumps `schema_version`), `ANALYZE` second, so a single pass
        // converges instead of two.
        //
        // WHY THIS BODY IS WHERE IT MATTERED. Measured launch cost on a 360k-row
        // database: `CREATE INDEX` 119 ms + `ANALYZE` ~850 ms. Harness-measured at
        // profile H (500k headers / 3.4 GB, `scratchpad/MIGRATION_COST`) across two
        // separate runs the whole migration was **8,522 ms** and **6,688 ms**, of
        // which the bare `ANALYZE` alone was **5,259.6 ms** in the second — the
        // single most expensive statement in the whole `v68…v83` chain, paid before
        // any UI appears. With it removed the same migration measured **2,015 ms
        // total / 296.5 ms body** on that harness. ⚠️ THAT RESIDUAL WAS NOT SMALL ON
        // REAL HARDWARE, which is why the `CREATE INDEX` followed it out: the owner's
        // device (5 accounts / 78 folders) attributed **5,050 ms** to this migration
        // with the `ANALYZE` already gone. A harness figure on a quiet Mac understates
        // a device by 2–4×, and 296.5 ms × 4 is not 5,050 ms — read the SHAPE (one
        // statement dominating), never the integer, and prefer the device number when
        // the two disagree. The `ANALYZE` also bought THIS migration nothing: the plan
        // quoted above is chosen identically with and without statistics, which is the
        // whole reason the partial form was preferred.
        //
        // ⚠️ NEGATIVE CASE — STATISTICS THEMSELVES ARE NOT OPTIONAL, so "just delete
        // the `ANALYZE`" would have been the wrong change. Measured at profile H on
        // the post-chain state a real upgraded device holds until its first
        // background pass, the drain's per-member header lookup in
        // `AccountManagerQueue` plans as
        // `SEARCH … messageHeader_accountId_messageId (accountId=?)` — a 100k-row
        // account-wide walk — before the background `ANALYZE`, and as a two-seek
        // `MULTI-INDEX OR` (0.079 ms/lookup) once it has run, which fills
        // `sqlite_stat1` to 36 rows. Statistics demonstrably change plans on at least
        // one hot path. What moved is WHEN they are computed, never WHETHER.
        //
        // ⚠️ Probe with a value that EXISTS: an account id present in no row reports
        // the same plan on both sides, which reads as "statistics change nothing" and
        // is an artefact.
        //
        // ⚠️ TWO CITATIONS WERE WRONG HERE UNTIL 2026-08-05; do not restore them from
        // an older revision. (1) This paragraph used to quote the pre-`ANALYZE` plan
        // as `SEARCH messageHeader USING INDEX messageHeader_accountId (accountId=?)`
        // on a synthetic 120k-row database. That index is DROPPED by
        // `v64_messageIdCompositeIndexes` (`DROP INDEX IF EXISTS
        // messageHeader_accountId`, this file), so the plan it quotes cannot be
        // produced at `v83` in any statistics regime — the measurement predates v64.
        // The profile-H reproduction above survives because
        // `messageHeader_accountId_messageId` is a v64 index that still exists.
        // (2) The regime was described as "an empty `sqlite_stat1`". The accurate
        // description is "no stat row for any FULL index on `messageHeader`" — see
        // `MessageContentStore.owners`, which measures all three regimes. The 36-vs-0
        // row counts above are this HARNESS's numbers, and its fixture is seeded
        // directly at `v67` with `grdb_migrations` pre-stamped, so the five in-body
        // `ANALYZE`s named in the SCOPE paragraph below (`v38`/`v39`/`v40`/`v50`/`v51`,
        // all registered EARLIER in this file) never ran in it and its
        // `sqlite_stat1` genuinely starts
        // absent. A genuine fresh install is NOT that state — it starts with
        // partial-index rows and zero full-index rows — but both plan identically,
        // so the conclusion is unchanged.
        //
        // ⚠️ SCOPE, stated so the next reader does not "finish the job". FIVE older
        // migrations still carry their own in-body `ANALYZE` — `v38`, `v39`, `v40`,
        // `v50` and `v51` — and they are DELIBERATELY UNTOUCHED, because a
        // registered migration is immutable once any database has run it (Data
        // Integrity rule 5) and every shipped install ran all five long ago. They
        // are also cheap where they sit for the reason that makes them useless: on
        // a fresh install they run against an EMPTY database, and on an upgrade
        // they were paid years ago. Their real legacy is the pre-state the
        // background pass now corrects: on a fresh install those five `ANALYZE`s
        // create `sqlite_stat1` and populate it with rows for `messageHeader`'s
        // PARTIAL indexes only (each `0 0`), leaving NO row for any of its full
        // indexes — and a partial index's row does not give the planner the table's
        // row estimate. So the device that later synced 100k messages carried that
        // absence forever, planning exactly as if it had never been analysed. ⚠️ Not
        // "records `messageHeader` as having ZERO rows", which is what this comment
        // said until 2026-08-05: there is no such estimate to record, and a health
        // check written against "is `sqlite_stat1` empty?" would report a fresh
        // install as healthy. Measured three ways in `MessageContentStore.owners`.
        // That exact pre-state is pinned by `SyncMaintenanceTests`'
        // `schemaChangeRearmsButRowTrafficDoesNot`.
        //
        // ⚠️ SECOND NEGATIVE CASE, because this is the sentence a future migration
        // will quote: this is NOT licence to move arbitrary work out of a migration.
        // Anything the schema's CORRECTNESS depends on — a column, an index a query
        // is written against, a data repair a reader assumes — stays blocking. Only
        // work whose omission degrades PERFORMANCE and nothing else may be deferred,
        // and only to something durable that re-arms itself.
        //
        // Same partial-index shape as `v51_headerIncompletePartialIndex`, the
        // precedent in this file (`messageHeader_headerIncomplete`, and see also
        // `messageHeader_aiIncomplete` / `messageHeader_embeddingIncomplete` /
        // `messageHeader_reminderLookup` — all raw-SQL partials).
        //
        // ⚠️ THE BODY IS EMPTY ON PURPOSE — do not "restore" the `CREATE INDEX`. It
        // read, until 2026-08-06:
        //
        //     try db.execute(sql: """
        //         CREATE INDEX IF NOT EXISTS messageHeader_unreadSweep
        //         ON messageHeader(folderId, id)
        //         WHERE isRead = 0
        //     """)
        //
        // and that statement now lives in `SyncEngine.deferredIndexes`, executed by
        // `SyncEngine.runBuildDeferredIndexesIfMissing` from the background WAL
        // maintenance pass. The identifier and the registration stay because a
        // registered migration's NAME is frozen once any database has run it (Data
        // Integrity rule 5) — deleting the registration would make GRDB see an applied
        // identifier it no longer knows. The convergence argument for the empty body
        // is at the top of this block.
        //
        // `foreignKeyChecks: .immediate` is retained rather than removed: an empty
        // body cannot violate a constraint, so the mode is moot, but leaving it keeps
        // the file's mode census uniform from `v68` to the top of the chain, and means
        // a future reader who fills this body in cannot inherit the default
        // `.deferred` and its whole-database scan by accident. (This said "uniform
        // across v68…v83 (16 of 16)"; the count was correct when written and stale one
        // migration later. The range predicate is in the section header above.)
        migrator.registerTimedMigration(
            "v83_markAllAsReadUnreadSweepIndex", foreignKeyChecks: .immediate
        ) { _ in
            // Intentionally empty. See above.
        }

        // v84 (R16-1) — the durable half of a terminal calendar outcome.
        //
        // A terminal arm of `drainCalendarQueue` used to `deleteOne` the row and
        // report the failure ONLY through `signalCalendarOpOutcome`, an in-memory
        // continuation. Five of the six drain triggers can never have a waiter
        // registered at all (only `queueCalendarOperation`'s trigger is causally
        // paired with one, and even it loses the waiter after the tool's 10 s
        // budget), so on the majority of paths a permanent failure was delivered to
        // nobody and the user's intention was destroyed with no record — after the
        // agent had already answered *"queued … will appear on the calendar
        // shortly"*. Terminal arms now write `status = 'failed'` plus this reason in
        // the SAME write, so the retirement cannot outrun its own record.
        //
        // A nullable TEXT column with no index and no backfill: existing rows are
        // all `queued`/`inFlight`/`cancelled`, for which `NULL` is the correct
        // value, so the body is one `ALTER TABLE` and adds nothing to the blocking
        // launch chain.
        //
        // `foreignKeyChecks: .immediate` matches every migration from `v68` up — an
        // `ALTER TABLE … ADD COLUMN` cannot violate a constraint, so the mode is
        // moot, but a uniform census is worth more than a considered exception.
        //
        // ⚠️ THIS READ "matches v68…v83 (17 of 17)" AND WAS WRONG BY ONE IN A
        // SPECIFIC, INSTRUCTIVE WAY (R17-6): `v68…v83` has SIXTEEN members and 17 is
        // the `v68…v84` count, so the author counted the row being ADDED and
        // described the range EXCLUDING it. The same file said "16 of 16" for the
        // identical range 27 lines above, written by the same commit. Per
        // `IOS-DOC-002` the predicate ships with the sentence, comments excluded so
        // it cannot count its own recording (`MIS-033`):
        //   rg -o '"v([0-9]+)_[A-Za-z0-9_]+"' -r '$1' TabMail/Services/AppDatabase.swift \
        //     | sort -n -u | awk '$1>=68' | wc -l                                  → 18
        //   rg -c --pcre2 '^(?!\s*(///|//)).*foreignKeyChecks: \.immediate' \
        //      TabMail/Services/AppDatabase.swift                                  → 18
        // The two must be EQUAL. A new migration keeps them equal by declaring
        // `.immediate`; one that cannot must say why, here.
        migrator.registerTimedMigration(
            "v84_addPendingCalendarOperationFailureReason", foreignKeyChecks: .immediate
        ) { db in
            try db.alter(table: "pendingCalendarOperation") { t in
                t.add(column: "failureReason", .text)
            }
        }

        // v85 — durable authority for an uncapped DIRECT AI event.
        //
        // `maxRecentEmails` is the owner-confirmed automatic working-inbox policy:
        // it selects the newest population before filtering cached work. A message
        // explicitly opened, pushed, or moved into Inbox bypasses that population,
        // matching Thunderbird's direct `processMessage` path. The ActiveAI queue
        // is in-memory, so that bypass needs one durable bit or a relaunch can erase
        // the event and leave an old message outside automatic eligibility forever.
        // RFC-bearing intent is mirrored in `messageAICache`, whose existing
        // content key survives UIDVALIDITY delete-and-resync; RFC-less rows remain
        // deliberately fail-closed because no durable content identity exists.
        //
        // The live header column is deliberately schema-only: `MessageHeader` does
        // not encode it, so ordinary provider/sync model saves cannot reset it.
        // Direct producers and guarded AI completion mutate it with raw SQL. Re-key
        // code explicitly carries it because delete+insert cannot carry a column the
        // model does not know about. Existing rows default false; there is no
        // backfill and therefore no invented historical direct intent.
        //
        // The partial index starts empty on upgrade and contains only direct-work
        // rows. Keeping the predicate at the durable authority bit makes BOTH the
        // live-work selector and terminal cleanup seek this sparse index; indexing
        // only the live-work predicate would make cleanup scan the full header table.
        migrator.registerTimedMigration(
            "v85_addDirectAIPending", foreignKeyChecks: .immediate
        ) { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "aiDirectPending", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "messageAICache") { t in
                t.add(column: "aiDirectPending", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS messageHeader_directAIPending
                ON messageHeader(date DESC, id DESC)
                WHERE aiDirectPending = 1
            """)
            // Scope exit is terminal for direct Inbox work. A folder-path or RFC
            // identity change must also relocate the RFC-keyed mirror: the outer
            // UPDATE has already written NEW coordinates before a nested marker-
            // clear trigger runs, so relying on that nested transition would strand
            // the OLD cache key. NEW.date supplies a correctly encoded non-NULL
            // timestamp when a previously RFC-less row first gains an identity;
            // pending mirrors are excluded from TTL expiry until they retire.
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messageHeader_clearDirectPendingOnInboxExit
                AFTER UPDATE OF isInInbox, folderPath, rfc822MessageId ON messageHeader
                WHEN OLD.aiDirectPending = 1
                  AND (NEW.isInInbox = 0
                       OR OLD.folderPath != NEW.folderPath
                       OR OLD.rfc822MessageId IS NOT NEW.rfc822MessageId)
                BEGIN
                    UPDATE messageAICache SET aiDirectPending = 0
                    WHERE key = OLD.accountId || ':' || OLD.folderPath || ':' || OLD.rfc822MessageId
                      AND OLD.rfc822MessageId IS NOT NULL
                      AND OLD.rfc822MessageId != ''
                      AND NOT EXISTS (
                          SELECT 1 FROM messageHeader AS live
                          WHERE live.aiDirectPending = 1
                            AND live.id != NEW.id
                            AND live.accountId = OLD.accountId
                            AND live.folderPath = OLD.folderPath
                            AND live.rfc822MessageId = OLD.rfc822MessageId
                      );
                    INSERT INTO messageAICache (
                        key, rfc822MessageId, aiDirectPending, updatedAt
                    )
                    SELECT NEW.accountId || ':' || NEW.folderPath || ':' || NEW.rfc822MessageId,
                           NEW.rfc822MessageId, 1,
                           COALESCE((
                               SELECT oldCache.updatedAt
                               FROM messageAICache AS oldCache
                               WHERE oldCache.key = OLD.accountId || ':' || OLD.folderPath || ':' || OLD.rfc822MessageId
                           ), NEW.date)
                    WHERE NEW.aiDirectPending = 1
                      AND NEW.isInInbox = 1
                      AND NEW.rfc822MessageId IS NOT NULL
                      AND NEW.rfc822MessageId != ''
                      AND EXISTS (
                          SELECT 1 FROM folder AS f
                          WHERE f.id = NEW.folderId
                            AND f.accountId = NEW.accountId
                            AND f.role = 'inbox'
                      )
                    ON CONFLICT(key) DO UPDATE SET
                        aiDirectPending = 1,
                        updatedAt = excluded.updatedAt;
                    UPDATE messageHeader SET aiDirectPending = 0
                    WHERE id = NEW.id AND NEW.isInInbox = 0;
                END
            """)
            // Every Swift setter for the live bit also persists the RFC-keyed cache
            // mirror. These trigger arms own the inverse lifecycle so ordinary
            // archive/delete paths cannot leave a direct event ready to resurrect.
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messageHeader_clearDirectPendingCache
                AFTER UPDATE OF aiDirectPending ON messageHeader
                WHEN OLD.aiDirectPending = 1 AND NEW.aiDirectPending = 0
                  AND OLD.rfc822MessageId IS NOT NULL
                  AND OLD.rfc822MessageId != ''
                BEGIN
                    UPDATE messageAICache SET aiDirectPending = 0
                    WHERE key = OLD.accountId || ':' || OLD.folderPath || ':' || OLD.rfc822MessageId
                      AND NOT EXISTS (
                          SELECT 1 FROM messageHeader AS live
                          WHERE live.aiDirectPending = 1
                            AND live.accountId = OLD.accountId
                            AND live.folderPath = OLD.folderPath
                            AND live.rfc822MessageId = OLD.rfc822MessageId
                      );
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messageHeader_clearDirectPendingCacheOnDelete
                AFTER DELETE ON messageHeader
                WHEN OLD.aiDirectPending = 1
                  AND OLD.rfc822MessageId IS NOT NULL
                  AND OLD.rfc822MessageId != ''
                  AND NOT EXISTS (
                      SELECT 1 FROM folder AS f
                      WHERE f.id = OLD.folderId
                        AND f.uidValidityResetPendingAt IS NOT NULL
                  )
                BEGIN
                    UPDATE messageAICache SET aiDirectPending = 0
                    WHERE key = OLD.accountId || ':' || OLD.folderPath || ':' || OLD.rfc822MessageId
                      AND NOT EXISTS (
                          SELECT 1 FROM messageHeader AS live
                          WHERE live.aiDirectPending = 1
                            AND live.accountId = OLD.accountId
                            AND live.folderPath = OLD.folderPath
                            AND live.rfc822MessageId = OLD.rfc822MessageId
                      );
                END
            """)
            // A reset purge deliberately leaves the cache mirror armed. The first
            // identity-matching resync insert restores the live sparse marker in
            // that insert transaction; RFC-less rows remain fail-closed.
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messageHeader_restoreDirectPendingAfterInsert
                AFTER INSERT ON messageHeader
                WHEN NEW.isInInbox = 1 AND NEW.bodyEmptyConfirmed = 0
                  AND NEW.rfc822MessageId IS NOT NULL
                  AND NEW.rfc822MessageId != ''
                  AND (NEW.summaryBlurb IS NULL OR NEW.summaryBlurb = ''
                       OR NEW.actionTag IS NULL OR NEW.cachedReply IS NULL)
                  AND EXISTS (
                      SELECT 1 FROM folder AS f
                      WHERE f.id = NEW.folderId
                        AND f.accountId = NEW.accountId
                        AND f.role = 'inbox'
                  )
                  AND EXISTS (
                      SELECT 1 FROM messageAICache AS c
                      WHERE c.key = NEW.accountId || ':' || NEW.folderPath || ':' || NEW.rfc822MessageId
                        AND c.aiDirectPending = 1
                  )
                BEGIN
                    UPDATE messageHeader SET aiDirectPending = 1 WHERE id = NEW.id;
                END
            """)
        }

        // v86 — a folder role is live Inbox scope, not just presentation metadata.
        //
        // v85's marker lifecycle already retires direct authority when a header
        // leaves Inbox, but a folder role can change without touching any header.
        // Every current and future writer is covered at the database boundary: an
        // inbox→non-inbox transition clears the sparse live marker only for headers
        // whose account and folder both match the row that changed. The existing
        // `messageHeader_clearDirectPendingCache` trigger then retires each RFC-keyed
        // mirror in the same outer transaction. Reassigning the folder to Inbox does
        // not restore either bit; only a new direct event may do that.
        //
        // This is a new migration rather than an amendment to v85. Candidate
        // simulators may already have recorded v85, so appending to that body would
        // leave upgraded databases without the trigger while fresh installs had it.
        migrator.registerTimedMigration(
            "v86_retireDirectAIOnInboxRoleExit", foreignKeyChecks: .immediate
        ) { db in
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS folder_retireDirectAIOnInboxRoleExit
                AFTER UPDATE OF role ON folder
                WHEN OLD.role = 'inbox' AND NEW.role != 'inbox'
                BEGIN
                    UPDATE messageHeader SET aiDirectPending = 0
                    WHERE aiDirectPending = 1
                      AND folderId = OLD.id
                      AND accountId = OLD.accountId;
                END
            """)
        }

        // v87 — retire PR #39's durable direct-AI exception machinery.
        //
        // v85 and v86 remain immutable because databases may already record those
        // identifiers. This forward migration removes their runtime schema instead:
        // derived AI work carries no durable bypass that can keep an old message
        // cycling through the body and AI queues.
        //
        // ⚠️ Do NOT read this as "bounded solely by the newest
        // `SyncConfig.maxRecentEmails` Inbox rows" (its wording until 2026-08-19):
        // since ADR-IOS-078 that window bounds SYNC-ORIGIN admission and the
        // repopulation sweep only, while arrival/user-intent events (open,
        // push/NSE merge, move into the Inbox) are window-EXEMPT. What v87
        // retires is the DURABLE exception machinery, not the exemptions — those
        // are deliberately ephemeral (an in-memory job flag; no marker columns,
        // no triggers, no relaunch redrive). Re-gating an exempt producer to
        // "restore" a global bound would contradict the owner directive.
        //
        // Trigger and index names are dropped before their referenced columns.
        // Existing true bits are intentionally discarded; they represent derived,
        // recomputable work rather than authored content or a user intention.
        migrator.registerTimedMigration(
            "v87_retireDirectAIPending", foreignKeyChecks: .immediate
        ) { db in
            for trigger in [
                "folder_retireDirectAIOnInboxRoleExit",
                "messageHeader_clearDirectPendingOnInboxExit",
                "messageHeader_clearDirectPendingCache",
                "messageHeader_clearDirectPendingCacheOnDelete",
                "messageHeader_restoreDirectPendingAfterInsert",
            ] {
                try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
            }
            try db.execute(sql: "DROP INDEX IF EXISTS messageHeader_directAIPending")
            try db.execute(sql: "ALTER TABLE messageHeader DROP COLUMN aiDirectPending")
            try db.execute(sql: "ALTER TABLE messageAICache DROP COLUMN aiDirectPending")
        }

        // v88: durable quarantine for a message whose metadata FETCH overflows the
        // IMAP response parser's buffer.
        //
        // The pre-existing quarantine (`oversizedDeferredThisSession`) is an
        // in-memory Set rebuilt empty on every launch, so every launch re-fetched
        // every oversized message and failed again. Each failure is expensive, not
        // merely wasted: `withFolderConnection` classifies `PayloadTooLargeError` as
        // unhealthy, so the connection is torn down and the next attempt pays a full
        // TCP + TLS + LOGIN + SELECT. This column makes the quarantine survive a
        // relaunch.
        //
        // Index: the admission queries gain a fifth equality predicate, so the index
        // that already serves them needs to cover it. `messageHeader_bodyRepopulate`
        // (v40) is `(isInInbox, headerComplete, bodyComplete, bodyEmptyConfirmed,
        // date)` — created precisely for this query, with `date` last so the seek and
        // the ORDER BY are served by one index and no temp B-tree is needed. Adding
        // `bodyMetadataOversized` before `date` extends that shape by one equality
        // column and preserves both properties.
        //
        // ⚠️ MEASURED, not assumed. EXPLAIN QUERY PLAN over the four shapes:
        //   - existing index alone → SEARCH on 4 of the 5 equality columns, the fifth
        //     filtered per row;
        //   - a PARTIAL `(isInInbox, date) WHERE <the four flags>` index → NEVER
        //     CHOSEN; the planner keeps preferring `messageHeader_bodyRepopulate`, so
        //     it would be pure write amplification;
        //   - this extended index → SEARCH on all 5 equality columns, date ordered.
        // Per ADR-IOS-029 the v40 index is NOT dropped; a new one is added alongside,
        // which is the same thing v40 itself did to v22's `idx_messageHeader_bodyStatus`.
        // (An earlier version of this comment justified keeping it with "other queries use
        // it" — unverified, and not the reason. The measured reason is that v40 remains
        // the FALLBACK plan for these same four queries: with the extended index dropped
        // they still plan `SEARCH … USING INDEX messageHeader_bodyRepopulate` on four of
        // the five equality columns, date-ordered, no temp B-tree. That is asserted by
        // `OversizedDurableFlagIndexTests
        // .withoutTheIndexTheFifthPredicateLeavesTheSeek`.)
        //
        // ⛔ THE INDEX IS NOT BUILT HERE. It lives in
        // `SyncEngine.deferredIndexes` as `messageHeader_bodyRepopulateV2`.
        // ADR-IOS-029's amendment is explicit — *"startup migrations should really have
        // only things that are absolutely necessary and blocking"* — and this index
        // passes that ADR's own eligibility test: its absence degrades PERFORMANCE AND
        // NOTHING ELSE. Measured without it, the four admission queries still plan
        // `SEARCH ... USING INDEX messageHeader_bodyRepopulate` on four of the five
        // equality columns, still date-ordered, still no temp B-tree — identical rows in
        // identical order, with the fifth conjunct filtered per row. Nothing names it in
        // an `INDEXED BY` clause and no write depends on it.
        //
        // The precedent is exact: `v83_markAllAsReadUnreadSweepIndex` has an
        // INTENTIONALLY EMPTY body because the owner had its `CREATE INDEX` moved out
        // after `MigrationTimingLedger` attributed 5,050 ms of blocking launch to it.
        // This index is LARGER than that one — measured at 360k rows on a Mac, 192 ms /
        // 1,589 pages against v83's 138 ms / 1,311 pages — and Mac timings understate
        // device by 2-4x. Building it here would re-add to the launch path exactly what
        // that amendment removed.
        //
        // The ADD COLUMN below stays blocking: a column is correctness, not performance,
        // and code compiled against it must never meet a database without it.
        migrator.registerTimedMigration(
            "v88_addBodyMetadataOversized", foreignKeyChecks: .immediate
        ) { db in
            try db.alter(table: "messageHeader") { t in
                t.add(column: "bodyMetadataOversized", .boolean)
                    .notNull()
                    .defaults(to: false)
            }
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
///
/// ⚑ INTERNAL RATHER THAN `private` AS OF 2026-08-06, for exactly one reason.
/// `MigrationTimingAttributionTests`' non-vacuity control used to be the SHIPPING
/// pair `v68` (`.immediate`) vs `v71` (`.deferred`) — two identical
/// `ALTER TABLE … ADD COLUMN` bodies with opposite foreign-key modes. `v71` is now
/// `.immediate` too, so that pair no longer exists anywhere in the chain and the
/// control has to register its own probe migrations THROUGH THIS WRAPPER (going
/// around it to GRDB's raw `registerMigration` would test a reimplementation of the
/// thing under test — `MIS-015`). Nothing in the app calls this outside
/// `registerAllMigrations`; the widening buys the test the production code path and
/// nothing else.
extension DatabaseMigrator {

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
    ///
    /// 🚨 **THE BODY TIMER IS NOT THE MIGRATION'S COST, AND SAYING SO IS THE
    /// POINT OF `MigrationTimingLedger`.** `try migrate(db)` returns BEFORE GRDB
    /// runs `PRAGMA foreign_key_check` (on the `.deferred` path), the COMMIT and
    /// its `grdb_migrations` bookkeeping — so this clock measures the cheapest
    /// part of an expensive migration. The old line said *"applied in 0ms"* for
    /// `v68`, whose real cost at 500k headers is ~9 s, essentially all of it the
    /// foreign-key check. The ledger closes each migration's post-body interval
    /// when the NEXT body starts and emits a `total = body + fkCheck/commit`
    /// line, so a reader never has to do the subtraction — and never has to know
    /// that the subtraction was needed. ⚠️ Do not "simplify" this back to a
    /// single timer around the body; the number it produces is not wrong by a
    /// little, it points at the wrong migration.
    mutating func registerTimedMigration(
        _ identifier: String,
        foreignKeyChecks: ForeignKeyChecks = .deferred,
        migrate: @escaping @Sendable (Database) throws -> Void
    ) {
        // Captured once at REGISTRATION, so the per-body path builds no string.
        let modeLabel: String
        switch foreignKeyChecks {
        case .deferred: modeLabel = "deferred"
        case .immediate: modeLabel = "immediate"
        }
        registerMigration(identifier, foreignKeyChecks: foreignKeyChecks) { db in
            guard MigrationTimingGate.isRecording else {
                try migrate(db)
                return
            }
            let ledger = MigrationTimingLedger.shared
            // Closes the PREVIOUS migration's post-body interval: everything
            // between that body returning and this line is its foreign-key
            // check + commit + bookkeeping.
            ledger.bodyWillStart(db: db)
            let start = ContinuousClock.now
            // `start.duration(to: .now)` rather than `.now - start`: reads as
            // "elapsed since start", so no sign convention has to be recalled.
            do {
                try migrate(db)
                let elapsed = MigrationTimingLedger.wholeMilliseconds(start.duration(to: ContinuousClock.now))
                BackgroundSyncLogger.log("AppDatabase: migration \(identifier) body \(elapsed)ms")
                ledger.bodyDidFinish(
                    db: db, identifier: identifier, mode: modeLabel, bodyMs: elapsed)
            } catch {
                let elapsed = MigrationTimingLedger.wholeMilliseconds(start.duration(to: ContinuousClock.now))
                BackgroundSyncLogger.log("AppDatabase: migration \(identifier) FAILED after \(elapsed)ms: \(error)")
                // A reconciliation over a chain that did not complete would be a
                // number that does not mean what it says.
                ledger.abandon(db: db)
                throw error
            }
        }
    }
}
