/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// Core FTS5 + vector database manager.
// Uses GRDB DatabasePool with WAL mode. Shared actor — all calls serialized.

/// A record to be indexed into FTS5.
///
/// 🚨 **THIS RECORD CARRIES TWO DIFFERENT IDS ON PURPOSE.** It used to carry one
/// `headerId` doing two unrelated jobs — keying the FTS row *and* naming the
/// `messageHeader` row whose `headerComplete` / `bodyComplete` flag the indexing
/// pipeline flips afterwards. That worked only because the two were the same
/// string. When the content key moves off the provider id (`ContentKeySpace`),
/// feeding the FTS key to `UPDATE messageHeader … WHERE id IN (…)` matches
/// **nothing**: headers never flip to complete, and the inbox query gates on
/// `headerComplete == true`, so the user's mail never becomes visible. Keep them
/// apart; the types now say which is which.
struct FTSHeaderRecord: Sendable {
    /// The FTS row's own key — written to `message_ids.headerId` and
    /// `message_meta.headerId`. **Never** a `messageHeader.id` predicate.
    let contentKey: ContentKey
    /// The `messageHeader.id` this record was built from. Use this — and only
    /// this — for `WHERE messageHeader.id …`.
    let headerId: String
    let messageId: String
    let subject: String
    let from: String
    let to: String
    let cc: String
    let bcc: String
    let dateMs: Int64
    let folderId: String

    // MARK: - The identity stamp (ADR-IOS-066)
    //
    // Four values that answer ONE question at the upsert: *is the entry already
    // sitting at this content key the SAME message this record describes?* They are
    // EVIDENCE, never a key — `contentKey` alone addresses the row. Reading the RFC
    // 822 Message-ID here is not a return to RFC keying: on `v3` the RFC id is never
    // mutation authority for a durable ACTION (D4 keys those by native provider id),
    // but it remains the strongest available proof of *which message this is*, which
    // is exactly the question a content-store write has to answer.
    //
    // 🚨 **A NULL IDENTITY STAMP MEANS RE-FETCH, NEVER DESTROY.** Every one of these
    // is OPTIONAL and defaults to `nil` — "this producer did not state it" — and a
    // `nil` can only ever make the write MORE conservative (preserve the existing
    // body and embedding, adopt the new header fields). The nil default is therefore
    // fail-SAFE in the direction its only consumer reads it: a dropped injection
    // costs a re-index, never a destroyed body. See
    // `SearchIndex.identityWriteDisposition`.

    /// The message's raw RFC 822 Message-ID, unvalidated —
    /// `MessageIdentity.comparableRfc822Identity` normalizes it at the compare.
    let rfc822MessageId: String?
    /// The mailbox's `UIDVALIDITY` epoch (`Folder.lastKnownUidValidity`) — `nil`
    /// for a provider that does not have one, and for a folder whose epoch is
    /// still unknown (`nil` there means UNKNOWN, never "fresh").
    let uidValidity: Int?
    /// A monotonic marker for the generation this record was read in, ordering two
    /// writers against each other.
    ///
    /// ⚠ NO `v3` PRODUCER SUPPLIES THIS TODAY, by an explicit design decision
    /// recorded on `Folder.uidValidityResetPendingAt`: *"`v2final`'s companion
    /// column `lastUidValidityResetAt` is deliberately NOT ported — its sole purpose
    /// there is to be the monotonic authority sidecar producers compare against, and
    /// v3 has no such producer."* The parameter is carried so the refusal arm exists
    /// and is exercisable the day one does.
    ///
    /// ⚑ ALL-OR-NOTHING PER FOLDER. `resetMarkerOrder` reads a stored marker with no
    /// incoming one as `.incomingOlder` (the reference's semantics, ported
    /// verbatim), so the first producer to start stamping a folder makes every
    /// producer that does NOT stamp that same folder get REFUSED. Whoever wires the
    /// first one must wire them all.
    let resetAtMs: Int64?
    /// Which identity space this provider's content rows draw their key tail from —
    /// bridge in through `AccountProvider.contentKeySpace`. `nil` is "unstated",
    /// which is NOT the same as `.uidAddressed`.
    let contentKeySpace: ContentKeySpace?

    init(contentKey: ContentKey, headerId: String, messageId: String, subject: String,
         from: String, to: String, cc: String = "", bcc: String = "",
         dateMs: Int64, folderId: String = "",
         rfc822MessageId: String? = nil, uidValidity: Int? = nil,
         resetAtMs: Int64? = nil, contentKeySpace: ContentKeySpace? = nil) {
        self.contentKey = contentKey
        self.headerId = headerId
        self.messageId = messageId
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.dateMs = dateMs
        self.folderId = folderId
        self.rfc822MessageId = rfc822MessageId
        self.uidValidity = uidValidity
        self.resetAtMs = resetAtMs
        self.contentKeySpace = contentKeySpace
    }
}

/// A search result from the FTS5 index.
///
/// ⚠ `contentKey` is what the FTS index stores; it is NOT guaranteed to be a
/// `messageHeader.id` once the content key moves. Callers resolving a hit back
/// to a header must go through the header lookup that owns that mapping.
struct FTSSearchResult {
    let contentKey: ContentKey
    let messageId: String
    let snippet: String
    let rank: Double
    let dateMs: Int64
}

actor SearchIndex {
    static let shared = SearchIndex()

    private var dbPool: DatabasePool?
    private var isInitialized = false

    /// Close the database pool for nuke operation. Must reinitialize after.
    func closeForNuke() {
        dbPool = nil
        isInitialized = false
        knownYears.removeAll()
    }

    // Year-sharded FTS tables: messages_fts_2020, messages_fts_2021, etc.
    private var knownYears: Set<Int> = []

    // Fixed UTC calendar for consistent year derivation across locales/timezones
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func ftsTableName(year: Int) -> String { "messages_fts_\(year)" }

    private func yearFromDateMs(_ dateMs: Int64) -> Int {
        guard dateMs > 0 else { return 2000 } // dateMs=0 or negative → fallback shard
        let date = Date(timeIntervalSince1970: Double(dateMs) / 1000.0)
        return Self.utcCalendar.component(.year, from: date)
    }

    /// Create a year shard FTS table if it doesn't exist yet.
    /// Schema: 7 columns matching TB (msgId, subject, from_, to_, cc, bcc, body).
    private func ensureShard(year: Int, db: Database) throws {
        guard !knownYears.contains(year) else { return }
        let table = ftsTableName(year: year)
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS \(table) USING fts5(
                msgId, subject, from_, to_, cc, bcc, body,
                tokenize = "\(SearchConfig.ftsTokenize)",
                prefix = '\(SearchConfig.ftsPrefixes)')
            """)
        try? db.execute(sql: "INSERT INTO \(table)(\(table), rank) VALUES('automerge', \(SearchConfig.ftsAutomerge))")
        try? db.execute(sql: "INSERT INTO \(table)(\(table), rank) VALUES('usermerge', 2)")
        knownYears.insert(year)
    }

    /// Load known year shards from sqlite_master.
    private func loadKnownYears(db: Database) throws {
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'messages\\_fts\\_%' ESCAPE '\\'
            """)
        knownYears = Set(tables.compactMap { name -> Int? in
            guard name.hasPrefix("messages_fts_") else { return nil }
            return Int(name.dropFirst("messages_fts_".count))
        })
    }

    /// Resolve (rowid, shardYear) for a content key in a single query.
    private func resolveRowidAndYear(_ contentKey: ContentKey, db: Database) throws -> (rowid: Int64, year: Int)? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT mi.rowid, meta.shardYear
            FROM message_ids mi
            JOIN message_meta meta ON mi.rowid = meta.rowid
            WHERE mi.headerId = ?
            """, arguments: [contentKey]) else { return nil }
        return (rowid: row["rowid"], year: row["shardYear"])
    }

    // MARK: - Initialization

    /// Ensure the FTS database is initialized. Called lazily on first access.
    /// Safe to call multiple times — no-ops after first successful init.
    /// Non-throwing variant for methods that can't propagate errors.
    private func ensureReady() {
        guard !isInitialized else { return }
        do {
            try initialize()
        } catch {
            print("[SearchIndex] Lazy initialization failed: \(error)")
        }
    }

    func initialize() throws {
        guard !isInitialized else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let ftsDir = appSupport.appendingPathComponent("tabmail_fts", isDirectory: true)
        try FileManager.default.createDirectory(at: ftsDir, withIntermediateDirectories: true)

        let dbPath = ftsDir.appendingPathComponent("fts.db").path
        print("[SearchIndex] Opening FTS database at \(dbPath)")

        var config = Configuration()
        // Reader pool size: 64. Matches main AppDatabase pool — FTS is also
        // read heavily (search, snippet fetch, backfill-folderId walk,
        // bulk index check) and hit priority inversion under foreground
        // load. Raised from GRDB default (5). See AppDatabase.swift.
        config.maximumReaderCount = 64
        // 0xdead10cc defense (ADR-IOS-041). GRDB checks the ACTUAL journal mode
        // (PRAGMA WAL set below), so reads stay available while suspended.
        config.observesSuspensionNotifications = true
        config.prepareDatabase { db in
            // Register sqlite-vec vec0 module on this connection (belt-and-suspenders
            // alongside sqlite3_auto_extension — ensures vec0 is available on every
            // GRDB reader/writer connection regardless of auto_extension behavior).
            if let sqliteConn = db.sqliteConnection {
                let rc = tabmail_register_sqlite_vec_on_db(UnsafeMutableRawPointer(sqliteConn))
                if rc != 0 /* SQLITE_OK */ {
                    print("[SearchIndex] WARNING: sqlite-vec registration returned \(rc)")
                }
            }

            // WAL mode + performance pragmas
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA cache_size = \(SearchConfig.cacheSizeKiB)")
            try db.execute(sql: "PRAGMA mmap_size = \(SearchConfig.mmapSizeBytes)")
            try db.execute(sql: "PRAGMA busy_timeout = \(SearchConfig.busyTimeoutMs)")
        }

        dbPool = try DatabasePool(path: dbPath, configuration: config)
        try createSchema()
        try migrateSchema()
        try migrateFTSToShards()
        try dbPool!.read { db in try loadKnownYears(db: db) }
        isInitialized = true

        let count = try documentCount()
        let shardList = knownYears.sorted().map(String.init).joined(separator: ", ")
        print("[SearchIndex] Initialized with \(count) documents, shards: [\(shardList)]")

        // Tokenizer migration: rebuild shards created with an outdated tokenize=
        // string, in the background. Init is NOT blocked — searches keep working
        // against old shards until each one is atomically swapped.
        let stale = (try? dbPool!.read { db in try Self.staleTokenizerYears(db: db) }) ?? []
        if !stale.isEmpty {
            Task { await self.rebuildStaleTokenizerShards() }
        }
    }

    private func createSchema() throws {
        guard let dbPool else { return }
        try dbPool.write { db in
            // Note: FTS5 virtual tables are year-sharded (messages_fts_YYYY).
            // Created dynamically by ensureShard() when indexHeaders() encounters a new year.
            // The old monolithic messages_fts table (if present) is migrated by migrateFTSToShards().

            // Metadata table — rowids match FTS5
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS message_meta (
                    rowid INTEGER PRIMARY KEY,
                    headerId TEXT NOT NULL,
                    dateMs INTEGER NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_meta_headerId ON message_meta(headerId)")

            // Dedup table
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS message_ids (
                    headerId TEXT PRIMARY KEY
                )
                """)

            // Vector search via sqlite-vec KNN (matching TB's messages_vec table)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_vec USING vec0(
                    embedding FLOAT[\(SearchConfig.embeddingDims)] distance_metric=cosine
                )
                """)
        }
    }

    /// Migrate FTS schema for new features (runs after createSchema).
    private func migrateSchema() throws {
        guard let dbPool else { return }
        try dbPool.write { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(message_meta)")
            let columnNames = Set(columns.map { $0["name"] as String })

            // v1: Add accountId to message_meta for per-account progress tracking
            if !columnNames.contains("accountId") {
                try db.execute(sql: "ALTER TABLE message_meta ADD COLUMN accountId TEXT NOT NULL DEFAULT ''")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_meta_accountId ON message_meta(accountId)")
                let emptyCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_meta WHERE accountId = ''") ?? 0
                if emptyCount > 0 {
                    try db.execute(sql: """
                        UPDATE message_meta
                        SET accountId = SUBSTR(headerId, 1, INSTR(headerId, ':') - 1)
                        WHERE accountId = ''
                        """)
                    print("[SearchIndex] Backfilled accountId for \(emptyCount) message_meta rows")
                }
            }

            // v2: Add hasBody flag for fast progress queries (avoids expensive FTS JOIN)
            if !columnNames.contains("hasBody") {
                try db.execute(sql: "ALTER TABLE message_meta ADD COLUMN hasBody INTEGER NOT NULL DEFAULT 0")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_meta_accountId_hasBody ON message_meta(accountId, hasBody)")
                // Backfill from old monolithic messages_fts if it exists
                let hasOldFts = try Bool.fetchOne(db, sql: """
                    SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='messages_fts'
                    """) ?? false
                if hasOldFts {
                    try db.execute(sql: """
                        UPDATE message_meta SET hasBody = 1
                        WHERE rowid IN (
                            SELECT meta.rowid FROM message_meta meta
                            JOIN messages_fts fts ON fts.rowid = meta.rowid
                            WHERE fts.body != '' AND fts.body != ' '
                        )
                        """)
                    let backfilled = db.changesCount
                    if backfilled > 0 {
                        print("[SearchIndex] Backfilled hasBody for \(backfilled) message_meta rows")
                    }
                }
            }

            // v4: Migrate message_embeddings BLOB table → messages_vec (sqlite-vec KNN)
            let hasOldEmbeddings = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='message_embeddings'
                """) ?? false
            if hasOldEmbeddings {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_embeddings") ?? 0
                if count > 0 {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO messages_vec (rowid, embedding)
                        SELECT rowid, embedding FROM message_embeddings
                        """)
                    print("[SearchIndex] Migrated \(count) embeddings from message_embeddings → messages_vec")
                }
                try db.execute(sql: "DROP TABLE message_embeddings")
                print("[SearchIndex] Dropped legacy message_embeddings table")
            }

            // v5: Migrate FTS shards from 5-column (msgId, subject, from_, to_, body) to
            // 7-column schema (+ cc, bcc) matching TB. FTS5 virtual tables can't be ALTERed,
            // so we must drop and recreate. hasBody reset triggers bulkIndexIfNeeded re-index.
            // NOTE: the LIKE pattern also matches FTS5 SHADOW tables
            // (messages_fts_2026_data/_idx/_config/…), which must never be probed
            // or dropped directly (SQLite: "table … may not be dropped"). Filter
            // to real shards: the suffix after "messages_fts_" must be a year.
            let realShardTables = { (names: [String]) -> [String] in
                names.filter { Int($0.dropFirst("messages_fts_".count)) != nil }
            }
            let hasCcColumn = try { () -> Bool in
                // Check if any existing FTS shard has 7 columns (cc, bcc present)
                let tables = realShardTables(try String.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'messages\\_fts\\_%' ESCAPE '\\'
                    """))
                guard let firstTable = tables.first else { return true } // no shards yet, skip migration
                let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(\(firstTable))")
                let colNames = Set(cols.map { $0["name"] as String })
                return colNames.contains("cc")
            }()
            if !hasCcColumn {
                // Drop all existing FTS shard tables (they have the old 5-column
                // schema). Shadow tables drop automatically with their parent.
                let shardTables = realShardTables(try String.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'messages\\_fts\\_%' ESCAPE '\\'
                    """))
                for table in shardTables {
                    try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
                    print("[SearchIndex] Dropped old 5-column FTS shard: \(table)")
                }
                // Full reset: clear dedup + meta tables so indexHeaders re-inserts from scratch.
                // Without this, message_ids still has old rowids → indexHeaders skips (thinks
                // already indexed), and updateBody fails (FTS table gone but meta points to it).
                try db.execute(sql: "DELETE FROM message_ids")
                try db.execute(sql: "DELETE FROM message_meta")
                try? db.execute(sql: "DELETE FROM messages_vec")
                let deletedCount = try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
                print("[SearchIndex] Cleared dedup/meta/vec tables — bulkIndexIfNeeded will rebuild from GRDB (\(deletedCount) rows)")
            }

            // v3: Add shardYear for FTS year-table routing
            if !columnNames.contains("shardYear") {
                try db.execute(sql: "ALTER TABLE message_meta ADD COLUMN shardYear INTEGER NOT NULL DEFAULT 0")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_meta_shardYear ON message_meta(shardYear)")
                try db.execute(sql: """
                    UPDATE message_meta
                    SET shardYear = CAST(strftime('%Y', dateMs / 1000, 'unixepoch') AS INTEGER)
                    WHERE shardYear = 0 AND dateMs > 0
                    """)
                let backfilled = db.changesCount
                // Handle dateMs=0 edge case — assign year 2000
                try db.execute(sql: "UPDATE message_meta SET shardYear = 2000 WHERE shardYear = 0")
                if backfilled > 0 {
                    print("[SearchIndex] Backfilled shardYear for \(backfilled) message_meta rows")
                }
            }

            // v6: Add folderId for folder-scoped search filtering
            if !columnNames.contains("folderId") {
                try db.execute(sql: "ALTER TABLE message_meta ADD COLUMN folderId TEXT NOT NULL DEFAULT ''")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_meta_folderId ON message_meta(folderId)")
                print("[SearchIndex] Added folderId column to message_meta (backfill via SyncEngineFTS)")
            }

            // v7: Add bodyConfirmedEmpty — server confirmed no body content.
            // Prevents infinite retry: hasBody=0 messages that are genuinely empty
            // won't be re-queued by cleanup/backfill/embedding rebuild.
            if !columnNames.contains("bodyConfirmedEmpty") {
                try db.execute(sql: "ALTER TABLE message_meta ADD COLUMN bodyConfirmedEmpty INTEGER NOT NULL DEFAULT 0")
            }

            // v8: the identity stamp the header upsert classifies against
            // (ADR-IOS-066). PORT of `v2final:SearchIndex.migrateSchema`'s v8 block
            // (`486bafd4b`), verbatim including the NULL-able column types.
            //
            // ⚠ THIS IS NOT A GRDB MIGRATION. It is the FTS database's own
            // re-entrant "add the column if `PRAGMA table_info` does not list it"
            // check, which runs on EVERY launch and is idempotent by construction —
            // it carries none of the frozen-name/frozen-body hazard that makes an
            // applied `AppDatabase` migration immutable. A fresh database is created
            // by `createSchema()` without these columns and immediately runs this,
            // so fresh and upgraded databases converge on the identical
            // `message_meta` column set.
            //
            // 🚨 EXISTING ROWS STAY NULL, AND NULL MEANS UNVERIFIED — NEVER
            // "MISMATCHED". A pre-upgrade row is a message whose identity was simply
            // never recorded; a header refresh must preserve its body and embedding
            // and lazily adopt the incoming tuple. Absence of evidence is never a
            // destructive-write permit. NOT NULL defaults are deliberately absent:
            // a default would manufacture exactly the evidence this must not have.
            let identityColumns: [(String, String)] = [
                ("identityTokenVersion", "INTEGER"),
                ("identityRfc822MessageId", "TEXT"),
                ("identityUidValidity", "INTEGER"),
                ("identityResetAtMs", "INTEGER"),
                ("identityStableProvider", "INTEGER"),
            ]
            for (name, type) in identityColumns where !columnNames.contains(name) {
                try db.execute(
                    sql: "ALTER TABLE message_meta ADD COLUMN \(name) \(type)"
                )
            }
        }
    }

    /// One-time migration: copy data from monolithic messages_fts to per-year shard tables.
    private func migrateFTSToShards() throws {
        guard let dbPool else { return }

        let hasOldTable = try dbPool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='messages_fts'
                """) ?? false
        }
        guard hasOldTable else { return }

        print("[SearchIndex] Migrating monolithic FTS to year-sharded tables...")
        let startTime = Date()

        let years = try dbPool.read { db in
            try Int.fetchAll(db, sql: "SELECT DISTINCT shardYear FROM message_meta WHERE shardYear > 0")
        }

        var totalMigrated = 0
        for year in years {
            // Create shard table
            try dbPool.write { [self] db in try ensureShard(year: year, db: db) }

            let table = ftsTableName(year: year)
            var offset = 0
            let chunkSize = SearchConfig.shardMigrationChunkSize
            while true {
                let currentOffset = offset
                let migrated = try dbPool.write { db -> Int in
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT fts.rowid, fts.msgId, fts.subject, fts.from_, fts.to_, fts.body
                        FROM messages_fts fts
                        JOIN message_meta meta ON fts.rowid = meta.rowid
                        WHERE meta.shardYear = ?
                        ORDER BY fts.rowid
                        LIMIT ? OFFSET ?
                        """, arguments: [year, chunkSize, currentOffset])

                    for row in rows {
                        try db.execute(sql: """
                            INSERT OR REPLACE INTO \(table) (rowid, msgId, subject, from_, to_, cc, bcc, body)
                            VALUES (?, ?, ?, ?, ?, '', '', ?)
                            """, arguments: [
                                row["rowid"] as Int64,
                                row["msgId"] as String,
                                row["subject"] as String,
                                row["from_"] as String,
                                row["to_"] as String,
                                row["body"] as String
                            ])
                    }
                    return rows.count
                }

                offset += migrated
                totalMigrated += migrated
                if totalMigrated % 5000 < chunkSize {
                    print("[SearchIndex] Migration progress: \(totalMigrated) rows (\(year): \(offset))")
                }
                if migrated < chunkSize { break }
            }
            print("[SearchIndex] Year \(year): migrated \(offset) rows")
        }

        // Drop old monolithic table
        try dbPool.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS messages_fts")
        }

        let elapsed = Date().timeIntervalSince(startTime)
        print("[SearchIndex] Migration complete — \(totalMigrated) rows across \(years.count) years in \(String(format: "%.1f", elapsed))s")
    }

    // MARK: - Tokenizer Migration (one-time shard rebuild)

    /// Year shards created with an outdated `tokenize=` string, detected from the
    /// stored CREATE statement in sqlite_master. Current marker: the old scheme
    /// used `tokenchars '-_.@'` (glued addresses into single tokens); the current
    /// `SearchConfig.ftsTokenize` has no tokenchars. A future tokenizer change
    /// needs its own predicate here (or a switch to PRAGMA user_version).
    private static func staleTokenizerYears(db: Database) throws -> [Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT name, sql FROM sqlite_master
            WHERE type='table' AND name LIKE 'messages\\_fts\\_%' ESCAPE '\\'
            """)
        return rows.compactMap { row in
            let name: String = row["name"]
            let sql: String = row["sql"] ?? ""
            guard sql.contains("tokenchars") else { return nil }
            return Int(name.dropFirst("messages_fts_".count))
        }
    }

    /// True while a rebuild loop is in flight — makes concurrent entry points
    /// (post-init Task, BGProcessing window) no-op instead of double-converting.
    private var isRebuildingTokenizerShards = false

    /// Whether any shard still awaits tokenizer conversion. Used by the BG
    /// scheduler to decide if a BGProcessing task should be (re)queued.
    func hasStaleTokenizerShards() async -> Bool {
        ensureReady()
        guard let dbPool else { return false }
        let stale = (try? await dbPool.read { db in try Self.staleTokenizerYears(db: db) }) ?? []
        return !stale.isEmpty
    }

    /// Rebuild every stale-tokenizer shard, newest year first (most-searched mail
    /// converts first). Runs behind the scenes (post-init Task, or background
    /// windows after their sync work); searches keep working against
    /// not-yet-converted shards. Resumable and idempotent: detection is stateless
    /// (sqlite_master) and each shard converts atomically, so a kill or
    /// cancellation mid-migration just leaves the remaining shards for the next
    /// run. Checks Task cancellation between shards so a BG expiration winds
    /// down at the next shard boundary.
    /// - Parameter deadline: stop before STARTING a new shard past this instant
    ///   (short background windows pass a small post-sync budget so the
    ///   migration doesn't hog the window; nil = run until done/cancelled).
    func rebuildStaleTokenizerShards(deadline: Date? = nil) async {
        guard let dbPool else { return }
        guard !isRebuildingTokenizerShards else { return }
        isRebuildingTokenizerShards = true
        defer { isRebuildingTokenizerShards = false }

        let stale = ((try? await dbPool.read { db in try Self.staleTokenizerYears(db: db) }) ?? [])
            .sorted(by: >)
        guard !stale.isEmpty else { return }

        print("[SearchIndex] Tokenizer migration: \(stale.count) shard(s) to rebuild: \(stale)")
        let startTime = Date()

        for year in stale {
            guard self.dbPool != nil else { return } // closed for nuke mid-run
            guard !Task.isCancelled else {
                print("[SearchIndex] Tokenizer migration cancelled — resuming on next run")
                return
            }
            if let deadline, Date() >= deadline {
                print("[SearchIndex] Tokenizer migration window budget reached — resuming later")
                return
            }
            do {
                try await rebuildShardForTokenizer(year: year)
            } catch is CancellationError {
                // BG expiration / push-deadline watchdog cancelled us mid-shard.
                // GRDB aborts the write at the next statement boundary and ROLLS
                // BACK, so the shard stays old and is redone next run — wind down.
                print("[SearchIndex] Tokenizer migration cancelled mid-shard \(year) (rolled back) — resuming on next run")
                return
            } catch {
                print("[SearchIndex] ERROR: tokenizer rebuild failed for shard \(year): \(error)")
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        print("[SearchIndex] Tokenizer migration complete in \(String(format: "%.1f", elapsed))s")
    }

    /// Rebuild a single year shard with the current tokenizer. ONE write
    /// transaction: WAL readers (search) see the old shard until commit; writers
    /// queue behind it for the seconds the copy takes. rowids are preserved —
    /// message_meta / messages_vec alignment is untouched. Reads are chunked
    /// (keyset pagination) per the bounded-memory rule.
    private func rebuildShardForTokenizer(year: Int) async throws {
        guard let dbPool else { return }
        let table = ftsTableName(year: year)
        let tmpTable = "\(table)_retok"
        let start = Date()
        let copied = try await dbPool.write { db -> Int in
            try db.execute(sql: "DROP TABLE IF EXISTS \(tmpTable)") // leftover from a crashed run
            try db.execute(sql: """
                CREATE VIRTUAL TABLE \(tmpTable) USING fts5(
                    msgId, subject, from_, to_, cc, bcc, body,
                    tokenize = "\(SearchConfig.ftsTokenize)",
                    prefix = '\(SearchConfig.ftsPrefixes)')
                """)
            var lastRowid: Int64 = -1
            var copied = 0
            while true {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT rowid, msgId, subject, from_, to_, cc, bcc, body
                    FROM \(table) WHERE rowid > ? ORDER BY rowid LIMIT ?
                    """, arguments: [lastRowid, SearchConfig.shardMigrationChunkSize])
                guard !rows.isEmpty else { break }
                for row in rows {
                    try db.execute(sql: """
                        INSERT INTO \(tmpTable)(rowid, msgId, subject, from_, to_, cc, bcc, body)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            row["rowid"] as Int64,
                            row["msgId"] as String,
                            row["subject"] as String,
                            row["from_"] as String,
                            row["to_"] as String,
                            row["cc"] as String,
                            row["bcc"] as String,
                            row["body"] as String
                        ])
                }
                copied += rows.count
                lastRowid = rows.last!["rowid"]
            }
            try db.execute(sql: "DROP TABLE \(table)")
            try db.execute(sql: "ALTER TABLE \(tmpTable) RENAME TO \(table)")
            // Re-apply the write tuning ensureShard sets on creation
            try? db.execute(sql: "INSERT INTO \(table)(\(table), rank) VALUES('automerge', \(SearchConfig.ftsAutomerge))")
            try? db.execute(sql: "INSERT INTO \(table)(\(table), rank) VALUES('usermerge', 2)")
            return copied
        }
        let elapsed = Date().timeIntervalSince(start)
        print("[SearchIndex] Re-tokenized \(table): \(copied) rows in \(String(format: "%.1f", elapsed))s")
    }

    // MARK: - Test Support (tokenizer migration)

    /// TEST ONLY: seed a year shard created with an arbitrary (legacy) tokenizer,
    /// with one row aligned across message_ids / shard / message_meta exactly the
    /// way indexHeaders writes them. Returns the rowid.
    func testSeedLegacyShard(year: Int, tokenize: String, contentKey: ContentKey, msgId: String,
                             subject: String, from: String, body: String, dateMs: Int64) async throws -> Int64 {
        ensureReady()
        guard let dbPool else { return -1 }
        let table = ftsTableName(year: year)
        let rowid = try await dbPool.write { db -> Int64 in
            try db.execute(sql: "INSERT OR IGNORE INTO message_ids (headerId) VALUES (?)",
                           arguments: [contentKey])
            let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM message_ids WHERE headerId = ?",
                                           arguments: [contentKey])!
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS \(table) USING fts5(
                    msgId, subject, from_, to_, cc, bcc, body,
                    tokenize = "\(tokenize)",
                    prefix = '\(SearchConfig.ftsPrefixes)')
                """)
            try db.execute(
                sql: "INSERT INTO \(table) (rowid, msgId, subject, from_, to_, cc, bcc, body) VALUES (?, ?, ?, ?, '', '', '', ?)",
                arguments: [rowid, msgId, subject, from, body]
            )
            let accountId = String(contentKey.rawValue.prefix(while: { $0 != ":" }))
            try db.execute(
                sql: "INSERT OR IGNORE INTO message_meta (rowid, headerId, dateMs, accountId, shardYear, folderId) VALUES (?, ?, ?, ?, ?, '')",
                arguments: [rowid, contentKey, dateMs, accountId, year]
            )
            return rowid
        }
        knownYears.insert(year)
        return rowid
    }

    /// TEST ONLY: the stored CREATE statement for a year shard.
    func testShardCreateSQL(year: Int) async throws -> String? {
        guard let dbPool else { return nil }
        let table = ftsTableName(year: year)
        return try await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?",
                                arguments: [table])
        }
    }

    /// TEST ONLY: message_meta rowid for a content key.
    func testRowidForHeader(_ contentKey: ContentKey) async throws -> Int64? {
        guard let dbPool else { return nil }
        return try await dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT rowid FROM message_meta WHERE headerId = ?",
                               arguments: [contentKey])
        }
    }

    /// TEST ONLY: strip a content key's `message_meta`, shard and vector rows while
    /// LEAVING its `message_ids` entry — the exact orphan shape an earlier
    /// partially-failed folder purge leaves behind, and the state
    /// `removeMessagesForFolder`'s H-2 sweep exists to clear. No production API can
    /// produce it (every removal path goes through `deleteEntry`, which drops all
    /// four together), so the invariant has no other way to be exercised.
    func testOrphanContentKey(_ contentKey: ContentKey) throws {
        ensureReady()
        guard let dbPool else { return }
        try dbPool.write { [self] db in
            guard let resolved = try resolveRowidAndYear(contentKey, db: db) else { return }
            try db.execute(sql: "DELETE FROM \(ftsTableName(year: resolved.year)) WHERE rowid = ?",
                           arguments: [resolved.rowid])
            try db.execute(sql: "DELETE FROM message_meta WHERE rowid = ?",
                           arguments: [resolved.rowid])
            try? db.execute(sql: "DELETE FROM messages_vec WHERE rowid = ?",
                            arguments: [resolved.rowid])
        }
    }

    /// TEST ONLY: whether `message_ids` still mints this content key, independent of
    /// whether a `message_meta` row backs it. The two questions differ exactly on an
    /// orphan, and `contentKeysMissingFromFTS` only answers the second.
    func testContentKeyIsMinted(_ contentKey: ContentKey) throws -> Bool {
        guard let dbPool else { return false }
        return try dbPool.read { db in
            try Bool.fetchOne(db, sql: "SELECT COUNT(*) > 0 FROM message_ids WHERE headerId = ?",
                              arguments: [contentKey]) ?? false
        }
    }

    /// TEST ONLY: drop a year shard table and forget the year.
    func testDropShard(year: Int) async throws {
        guard let dbPool else { return }
        let table = ftsTableName(year: year)
        try await dbPool.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
        knownYears.remove(year)
    }

    // MARK: - Document Count

    func documentCount() throws -> Int {
        guard let dbPool else { return 0 }
        return try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_meta") ?? 0
        }
    }

    /// Count FTS documents belonging to a specific account.
    /// Header IDs use format "accountId:folderPath:messageId" so LIKE prefix matches.
    func documentCountForAccount(accountId: String) throws -> Int {
        guard let dbPool else { return 0 }
        let prefix = accountId + ":%"
        return try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message_ids WHERE headerId LIKE ?",
                arguments: [prefix]
            ) ?? 0
        }
    }

    /// Remove all FTS entries for a given account (used during account removal).
    /// Header IDs use format "accountId:folderPath:messageId".
    func removeMessagesForAccount(accountId: String) throws {
        ensureReady()
        guard let dbPool else { return }
        let prefix = accountId + ":%"
        try dbPool.write { [self] db in
            // Fetch rowid + shardYear for all messages in this account
            let rows = try Row.fetchAll(db, sql: """
                SELECT mi.rowid, meta.shardYear
                FROM message_ids mi
                JOIN message_meta meta ON mi.rowid = meta.rowid
                WHERE mi.headerId LIKE ?
                """, arguments: [prefix])

            // Group by year for batch FTS deletes
            var rowidsByYear: [Int: [Int64]] = [:]
            for row in rows {
                let rowid: Int64 = row["rowid"]
                let year: Int = row["shardYear"]
                rowidsByYear[year, default: []].append(rowid)
            }

            for (year, rowids) in rowidsByYear {
                let table = ftsTableName(year: year)
                for rowid in rowids {
                    try db.execute(sql: "DELETE FROM \(table) WHERE rowid = ?", arguments: [rowid])
                }
            }

            // Delete from global tables
            for row in rows {
                let rowid: Int64 = row["rowid"]
                try db.execute(sql: "DELETE FROM message_meta WHERE rowid = ?", arguments: [rowid])
                try? db.execute(sql: "DELETE FROM messages_vec WHERE rowid = ?", arguments: [rowid])
            }
            if !rows.isEmpty {
                try db.execute(sql: "DELETE FROM message_ids WHERE headerId LIKE ?", arguments: [prefix])
            }
        }
    }

    /// Remove every FTS entry belonging to ONE folder (T4.S6 — the UIDVALIDITY
    /// purge-and-resync reaction's step 4).
    ///
    /// ⚑ A **QUERY** delete, never a captured-id list. The reaction's step 3 has
    /// already deleted the `messageHeader` rows by the time this runs, so a
    /// re-drive after an interrupted attempt would hand a captured list of ZERO
    /// ids and silently leave old-epoch FTS rows behind forever — which is exactly
    /// the state that lets a search hit resolve to a reused UID under the new
    /// epoch. Recomputable from the folder alone, it stays correct on every
    /// re-drive. (`v2final:AccountManagerUidValidityReset.swift` makes the same
    /// point for `BodyAssetStore` — "manifest-QUERY delete (never a captured-id
    /// list, P1b F5)".)
    ///
    /// PORT (`v2final:SearchIndex.removeMessagesForFolder`): `message_meta.folderId`
    /// is the authoritative folder relation. It cannot confuse a colon-bearing
    /// message-id tail with an IMAP child folder, and remains queryable after the
    /// main-database headers have already been deleted.
    func removeMessagesForFolder(accountId: String, folderPath: String) throws {
        ensureReady()
        guard let dbPool else { return }
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
        let likePrefix = MessageIdentity.escapedHeaderIdLikePrefix(
            accountId: accountId, folderPath: folderPath) + "%"
        let rawPrefix = MessageIdentity.headerIdPrefix(accountId: accountId, folderPath: folderPath)
        let noDeeperColonSQL = MessageIdentity.headerIdLikeNoDeeperColonSQLFragment(column: "headerId")
        try dbPool.write { [self] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT mi.rowid, meta.shardYear
                FROM message_ids mi
                JOIN message_meta meta ON mi.rowid = meta.rowid
                WHERE meta.folderId = ?
                """, arguments: [folderId])

            var rowidsByYear: [Int: [Int64]] = [:]
            for row in rows {
                let rowid: Int64 = row["rowid"]
                let year: Int = row["shardYear"]
                rowidsByYear[year, default: []].append(rowid)
            }
            for (year, rowids) in rowidsByYear {
                let table = ftsTableName(year: year)
                for rowid in rowids {
                    try db.execute(sql: "DELETE FROM \(table) WHERE rowid = ?", arguments: [rowid])
                }
            }
            for row in rows {
                let rowid: Int64 = row["rowid"]
                try db.execute(sql: "DELETE FROM message_meta WHERE rowid = ?", arguments: [rowid])
                try? db.execute(sql: "DELETE FROM messages_vec WHERE rowid = ?", arguments: [rowid])
                try db.execute(
                    sql: "DELETE FROM message_ids WHERE rowid = ?",
                    arguments: [rowid]
                )
            }

            // H-2 — PORT of the reference's `message_ids` sweep
            // (`v2final:SearchIndex.removeMessagesForFolder`, ADR-IOS-061 item H).
            // `message_ids` carries no `folderId` column, so a pre-existing ORPHAN
            // id — one whose `message_meta` / shard rows are already gone, e.g. from
            // an earlier partially-failed purge — never appears in `rows` above and
            // therefore survives every folder-relation delete. It is NOT inert: a
            // surviving id is a live claim on a content key by a folder that has
            // been purged, so it keeps that key minted for an account/folder pair
            // that no longer holds it and every later census
            // (`documentCountForAccount`, `purgeForAccount`'s prefix delete) counts
            // it. Recomputable from the folder alone ⇒ idempotent on a crash
            // re-drive, exactly like the query above.
            //
            // ⚑ CORRECTED BY T5.2 (ADR-IOS-066), AND THE CORRECTION MATTERS. The
            // original rationale here was that `indexHeaders` is `INSERT OR IGNORE`
            // plus skip-if-unchanged, so a surviving id turned the resync's re-index
            // of that very key into a silent no-op. That half is no longer true:
            // `upsertHeader` finds no `message_meta` row behind the orphan, falls to
            // `insertHeader`, and its `INSERT OR IGNORE` ADOPTS the orphan's rowid,
            // so the message does become searchable again. This sweep is therefore
            // no longer the only thing standing between an orphan and unsearchable
            // mail — but it is still required for the reason restated above, and the
            // assertion that discriminates its presence is
            // `testContentKeyIsMinted(...) == false`, not the re-index count.
            //
            // SUBTRACT — a deliberate NARROWING of the reference, which deletes every
            // prefix match unconditionally. The `NOT EXISTS` term leaves alone any id
            // whose `message_meta` row is still LIVE but records a different folder
            // (a legacy row still awaiting `backfillFolderIdsIfNeeded`, or the window
            // between a `rekeyHeaders` and its `updateFolderIds`). Two folder
            // relations disagreeing is precisely when a purge must fail closed:
            // deleting the id alone would strand a searchable `message_meta` + shard
            // row with no id, and the next index of that key would then mint a SECOND
            // rowid whose stale twin keeps answering searches. A surviving id is a
            // nuisance; a half-deleted entry is a wrong-occupant search hit.
            //
            // Scoped by the composite-key prefix PLUS the no-deeper-colon guard, so a
            // ':'-delimiter IMAP server's nested child (`acct:Drafts:Sub:77`, which
            // shares `acct:Drafts:`) is never swept by its parent's purge; LIKE-escaped
            // because a folder path may legitimately contain `%` or `_`. Never relax
            // either term — see `MessageIdentity.usableRfc822Tail`; the fix for a
            // colon-bearing tail is at the mint.
            try db.execute(
                sql: """
                    DELETE FROM message_ids
                    WHERE headerId LIKE ? ESCAPE '\\'
                      AND \(noDeeperColonSQL)
                      AND NOT EXISTS (
                          SELECT 1 FROM message_meta meta WHERE meta.rowid = message_ids.rowid
                      )
                    """,
                arguments: [likePrefix, rawPrefix]
            )
        }
    }

    // MARK: - Indexing

    /// The identity-tuple shape `message_meta`'s `identity*` columns are written in.
    /// A stored value that is not this is a tuple written by a version whose meaning
    /// is unknown here, and is treated as UNVERIFIED — see decision 1 of
    /// `identityWriteDisposition`.
    private static let identityTokenVersion = 1

    /// The `accountId` an FTS row belongs to, taken from its content key's leading
    /// field (`"<accountId>:<folderPath>:<tail>"`). The same derivation the v1
    /// `accountId` backfill does in SQL, and the one `indexHeaders` has always used.
    private nonisolated static func accountId(of contentKey: ContentKey) -> String {
        String(contentKey.rawValue.prefix(while: { $0 != ":" }))
    }

    /// What one header write did to the entry at its content key.
    private enum HeaderUpsertResult {
        case inserted
        case updated
        case refusedOlderGeneration
    }

    /// What a header write may do to the CONTENT (indexed body + embedding) already
    /// sitting at a content key. The header FIELDS are rewritten either way — that
    /// is the whole point of the upsert; only the expensive-to-rebuild content is
    /// arbitrated here.
    private enum IdentityWriteDisposition {
        case preserveAndAdopt
        case clearAndAdopt
        case refuseOlderGeneration
    }

    /// Ordering of two reset markers.
    ///
    /// PORT of `v2final:MessageIdentity.ResetMarkerOrder` + `resetMarkerOrder`
    /// (`486bafd4b`), RELOCATED into this file: on `v3` the shared
    /// `MessageIdentity` has no such helper and the FTS index is its only would-be
    /// consumer. If a second consumer appears, promote it back to
    /// `Shared/Keys/MessageIdentity.swift` rather than growing a second copy.
    private enum ResetMarkerOrder {
        case same
        case incomingNewer
        case incomingOlder
    }

    /// PORT (`v2final:MessageIdentity.resetMarkerOrder`, `486bafd4b`) — verbatim,
    /// INCLUDING the asymmetry that a stored marker with no incoming one reads as
    /// `.incomingOlder`. See `FTSHeaderRecord.resetAtMs`'s all-or-nothing note.
    private nonisolated static func resetMarkerOrder(
        existingMs: Int64?,
        incomingMs: Int64?
    ) -> ResetMarkerOrder {
        switch (existingMs, incomingMs) {
        case (.none, .none):
            return .same
        case (.none, .some):
            return .incomingNewer
        case (.some, .none):
            return .incomingOlder
        case let (.some(existing), .some(incoming)) where incoming > existing:
            return .incomingNewer
        case let (.some(existing), .some(incoming)) where incoming < existing:
            return .incomingOlder
        default:
            return .same
        }
    }

    /// Batch index message headers into FTS5, keyed by content key.
    /// Returns count of newly inserted documents — an entry that was REFRESHED in
    /// place is not counted, which is the same meaning the previous
    /// `INSERT OR IGNORE` form returned.
    ///
    /// ⚠ Reads `record.contentKey` and never `record.headerId` — the FTS row is
    /// keyed by content. See `FTSHeaderRecord`'s two-id note.
    ///
    /// PORT (`v2final:SearchIndex.indexLiveHeaders` → `upsertLiveHeader`,
    /// `486bafd4b`). This is what closes D-A: the previous form was
    /// `INSERT OR IGNORE` plus an explicit skip-if-present, so a `message_meta`
    /// record left behind by a PREVIOUS occupant of a reused content key could never
    /// be corrected — after a UIDVALIDITY reset, search returned the NEW message
    /// carrying the OLD message's subject and sender, permanently. An existing entry
    /// is now REFRESHED in place instead of ignored.
    ///
    /// SUBTRACT — the reference's entry point re-reads every searchable field and
    /// identity value out of GRDB while holding its writer transaction across the
    /// FTS write, and flips `messageHeader.headerComplete` for what it indexed. None
    /// of that is ported: on `v3` every production producer already builds its
    /// records inside its own GRDB read and owns the `headerComplete` flip, so
    /// re-reading here would duplicate their work, cross a second database's writer
    /// inside this one, and change a signature they all depend on. The identity
    /// tuple travels ON the record instead — see `FTSHeaderRecord`.
    ///
    /// CENSUS as of this change — nine `FTSHeaderRecord(` construction sites across
    /// seven files, enumerated by grepping the TYPE rather than any one call shape:
    /// `SyncEngineFTS` ×2, `NSEDataBridge` ×2, `SyncEngineFullSync`,
    /// `SyncEngineBackfillDeep`, `AccountManagerActions`, `AccountManagerOutbox`,
    /// `DemoModeService`. All nine pass a real `folderId`, which is why the meta
    /// UPDATE below may refresh that column without blanking a correct one.
    func indexHeaders(_ records: [FTSHeaderRecord]) throws -> Int {
        ensureReady()
        guard let dbPool, !records.isEmpty else { return 0 }

        return try dbPool.write { [self] db in
            var inserted = 0

            // LOOP VARIANT: the number of elements of `records` not yet visited,
            // which strictly decreases by exactly one per iteration and is bounded
            // below by 0. `continue` advances to the next element like any other
            // arm — no arm re-enters an element, and none of the three results can
            // extend the sequence — so the refusal arm cannot hang the loop.
            for record in records {
                switch try upsertHeader(record, db: db) {
                case .inserted:
                    inserted += 1
                case .updated:
                    break
                case .refusedOlderGeneration:
                    continue
                }
            }

            return inserted
        }
    }

    /// Write one header record over whatever occupies its content key, arbitrating
    /// the existing body and embedding through `identityWriteDisposition`.
    ///
    /// PORT (`v2final:SearchIndex.upsertLiveHeader`, `486bafd4b`), keyed by
    /// `ContentKey` rather than the reference's raw `headerId` string.
    private func upsertHeader(
        _ record: FTSHeaderRecord,
        db: Database
    ) throws -> HeaderUpsertResult {
        guard let mapping = try Row.fetchOne(
            db,
            sql: """
                SELECT mi.rowid, meta.shardYear, meta.identityTokenVersion,
                       meta.identityRfc822MessageId,
                       meta.identityUidValidity, meta.identityResetAtMs,
                       meta.identityStableProvider
                FROM message_ids mi
                JOIN message_meta meta ON meta.rowid = mi.rowid
                WHERE mi.headerId = ?
                """,
            arguments: [record.contentKey]
        ) else {
            try insertHeader(record, db: db)
            return .inserted
        }

        let rowid: Int64 = mapping["rowid"]
        let oldYear: Int = mapping["shardYear"]
        let oldTable = ftsTableName(year: oldYear)
        guard let oldFTS = try Row.fetchOne(
            db,
            sql: "SELECT body FROM \(oldTable) WHERE rowid = ?",
            arguments: [rowid]
        ) else {
            // Dangling mapping — id + meta rows with no shard row behind them.
            // There is no content to arbitrate, so rebuild the entry outright.
            try db.execute(
                sql: "DELETE FROM message_meta WHERE rowid = ?",
                arguments: [rowid]
            )
            try db.execute(
                sql: "DELETE FROM message_ids WHERE headerId = ?",
                arguments: [record.contentKey]
            )
            try? db.execute(
                sql: "DELETE FROM messages_vec WHERE rowid = ?",
                arguments: [rowid]
            )
            try insertHeader(record, db: db)
            return .inserted
        }

        let disposition = identityWriteDisposition(record, stored: mapping)
        let body: String
        switch disposition {
        case .preserveAndAdopt:
            // ⚠ CARRIES THE FULL INDEXED BODY ACROSS, never a prefix of it. The
            // stored copy is what search reads; nothing here shortens it.
            body = oldFTS["body"]
        case .clearAndAdopt:
            body = ""
        case .refuseOlderGeneration:
            return .refusedOlderGeneration
        }

        let newYear = yearFromDateMs(record.dateMs)
        if newYear == oldYear {
            try db.execute(
                sql: """
                    UPDATE \(oldTable)
                    SET msgId = ?, subject = ?, from_ = ?, to_ = ?,
                        cc = ?, bcc = ?, body = ?
                    WHERE rowid = ?
                    """,
                arguments: [
                    record.messageId, record.subject, record.from, record.to,
                    record.cc, record.bcc, body, rowid,
                ]
            )
        } else {
            try ensureShard(year: newYear, db: db)
            let newTable = ftsTableName(year: newYear)
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO \(newTable)
                        (rowid, msgId, subject, from_, to_, cc, bcc, body)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    rowid, record.messageId, record.subject, record.from,
                    record.to, record.cc, record.bcc, body,
                ]
            )
            try db.execute(
                sql: "DELETE FROM \(oldTable) WHERE rowid = ?",
                arguments: [rowid]
            )
        }

        if case .clearAndAdopt = disposition {
            // The embedding describes the body just cleared, so it is now a
            // different message's vector sitting at this rowid. `try?` matches
            // every other `messages_vec` write in this file: the table is absent
            // on a device where the `vec0` module failed to register.
            try? db.execute(
                sql: "DELETE FROM messages_vec WHERE rowid = ?",
                arguments: [rowid]
            )
        }

        let stableProvider: Bool? = record.contentKeySpace.map {
            $0 == .stableProviderId
        }
        try db.execute(
            sql: """
                UPDATE message_meta
                SET dateMs = ?, accountId = ?, shardYear = ?, folderId = ?,
                    identityTokenVersion = ?, identityRfc822MessageId = ?,
                    identityUidValidity = ?, identityResetAtMs = ?,
                    identityStableProvider = ?
                WHERE rowid = ?
                """,
            arguments: [
                record.dateMs, Self.accountId(of: record.contentKey), newYear,
                record.folderId, Self.identityTokenVersion,
                record.rfc822MessageId, record.uidValidity, record.resetAtMs,
                stableProvider, rowid,
            ]
        )
        return .updated
    }

    /// Mint a brand-new FTS entry for a content key nothing occupies yet.
    ///
    /// PORT (`v2final:SearchIndex.insertLiveHeader`, `486bafd4b`). The `OR IGNORE` /
    /// `OR REPLACE` conflict clauses are a deliberate widening of the reference's
    /// bare `INSERT`s: `message_ids` can legitimately still hold an ORPHANED key
    /// whose `message_meta` and shard rows are already gone (the state
    /// `removeMessagesForFolder`'s H-2 sweep exists to clear, and the state the
    /// dangling-mapping branch above creates on purpose). The reference throws
    /// there and aborts the whole batch write; adopting the orphan's rowid indexes
    /// the message instead, which is the outcome that sweep is trying to reach.
    private func insertHeader(_ record: FTSHeaderRecord, db: Database) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO message_ids (headerId) VALUES (?)",
            arguments: [record.contentKey]
        )
        let rowid = try Int64.fetchOne(
            db,
            sql: "SELECT rowid FROM message_ids WHERE headerId = ?",
            arguments: [record.contentKey]
        )!
        let year = yearFromDateMs(record.dateMs)
        try ensureShard(year: year, db: db)
        let table = ftsTableName(year: year)
        // Body empty — filled later via updateBody/updateBodies.
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO \(table)
                    (rowid, msgId, subject, from_, to_, cc, bcc, body)
                VALUES (?, ?, ?, ?, ?, ?, ?, '')
                """,
            arguments: [
                rowid, record.messageId, record.subject, record.from,
                record.to, record.cc, record.bcc,
            ]
        )
        // Flags (bodyComplete, bodyEmptyConfirmed) live in GRDB only.
        let stableProvider: Bool? = record.contentKeySpace.map {
            $0 == .stableProviderId
        }
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO message_meta (
                    rowid, headerId, dateMs, accountId, shardYear, folderId,
                    identityTokenVersion, identityRfc822MessageId,
                    identityUidValidity, identityResetAtMs, identityStableProvider
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                rowid, record.contentKey, record.dateMs,
                Self.accountId(of: record.contentKey), year, record.folderId,
                Self.identityTokenVersion, record.rfc822MessageId,
                record.uidValidity, record.resetAtMs, stableProvider,
            ]
        )
    }

    /// 🚨 **A NULL IDENTITY STAMP MEANS RE-FETCH, NEVER DESTROY.**
    ///
    /// Classifies a header write without turning MISSING evidence into a delete.
    /// Reset markers ORDER two writers (an older one is refused; a newer one may
    /// adopt); body and embedding are cleared ONLY on a POSITIVE identity
    /// disagreement — two values that are both present and differ. Legacy,
    /// unstamped or incomplete tuples are preserved and lazily adopted.
    ///
    /// ⚑ THE REFERENCE ITSELF GOT THIS WRONG, WHICH IS WHY THE RULE IS SPELLED OUT
    /// RATHER THAN LEFT TO THE READER: it guarded this WRITE with a rule meant for
    /// READS and unrecoverably wiped the FTS body of every pre-upgrade row. The
    /// corrected form is what is ported here (`486bafd4b`'s own commit message lists
    /// that regression first). Every arm that returns `.clearAndAdopt` below is
    /// reached only from two non-nil values that disagree; there is no arm where the
    /// ABSENCE of a value clears anything.
    ///
    /// PORT (`v2final:SearchIndex.liveIdentityWriteDisposition`, `486bafd4b`).
    private nonisolated func identityWriteDisposition(
        _ record: FTSHeaderRecord,
        stored: Row
    ) -> IdentityWriteDisposition {
        // DECISION 1 — a tuple this version does not recognise (including the NULL
        // a pre-upgrade row carries) is UNVERIFIED, not mismatched. PRESERVE.
        let version: Int? = stored["identityTokenVersion"]
        guard version == Self.identityTokenVersion else { return .preserveAndAdopt }

        let oldResetAtMs: Int64? = stored["identityResetAtMs"]
        let resetOrder = Self.resetMarkerOrder(
            existingMs: oldResetAtMs,
            incomingMs: record.resetAtMs
        )
        if resetOrder == .incomingOlder {
            return .refuseOlderGeneration
        }

        // DECISION 2 — a NULL stored `identityStableProvider`. PRESERVE.
        let oldStableInt: Int? = stored["identityStableProvider"]
        guard let oldStableInt else { return .preserveAndAdopt }
        let oldStable = oldStableInt == 1
        // NARROWED from the reference, which reads the incoming side as a plain
        // `Bool` and so cannot tell "this provider is uid-addressed" from "this
        // producer did not say". On `v3` the incoming value is optional and unstated
        // at every producer today, so the reference's literal form would clear on
        // MANUFACTURED evidence the moment one producer starts stating it. An
        // unstated incoming value skips this branch entirely and falls through to
        // the RFC/epoch evidence below; it never clears on its own.
        if let newStable = record.contentKeySpace.map({ $0 == .stableProviderId }),
           oldStable || newStable {
            return oldStable == newStable
                ? .preserveAndAdopt
                : .clearAndAdopt
        }

        // DECISION 3 — CLEAR only when BOTH RFC ids are non-nil AND differ.
        let oldRfc = MessageIdentity.comparableRfc822Identity(
            stored["identityRfc822MessageId"] as String?
        )
        let newRfc = MessageIdentity.comparableRfc822Identity(
            record.rfc822MessageId
        )
        if let oldRfc, let newRfc {
            return oldRfc == newRfc
                ? .preserveAndAdopt
                : .clearAndAdopt
        }

        // A reset marker may only CLEAR when the stored side actually has one. The
        // `.incomingNewer` case is produced by `resetMarkerOrder` for BOTH
        // `(.some, .some)` where incoming is newer AND `(.none, .some)` — and that
        // second shape is the ABSENCE of a stored marker, not a disagreement with
        // one. Without the `oldResetAtMs != nil` requirement a stored row carrying
        // NO marker was cleared by an incoming record that merely stated one,
        // emptying the indexed body and deleting the embedding on missing evidence
        // — the exact write ADR-IOS-072's PRESERVE RULE forbids ("a NULL identity
        // stamp means RE-FETCH, NEVER DESTROY — only a positive mismatch clears
        // anything") and the exact claim this function's own doc block above makes
        // ("there is no arm where the ABSENCE of a value clears anything").
        //
        // 🚨 NARROW THE CONSUMER, NOT `resetMarkerOrder`. That mapping is a verbatim
        // port and `(.none, .some) ⇒ .incomingNewer` is CORRECT for the
        // `.incomingOlder` refusal above, which relies on the symmetric
        // `(.some, .none) ⇒ .incomingOlder`. Changing it there would break the
        // refusal arm.
        if resetOrder == .incomingNewer, oldResetAtMs != nil {
            return .clearAndAdopt
        }

        // DECISION 4 — CLEAR only when BOTH epochs are non-nil AND differ.
        let oldEpoch: Int? = stored["identityUidValidity"]
        if let oldEpoch, let newEpoch = record.uidValidity {
            return oldEpoch == newEpoch
                ? .preserveAndAdopt
                : .clearAndAdopt
        }

        // DECISION 5 — the fall-through. No pair of values disagreed, so nothing
        // has been shown to be a different message. PRESERVE.
        return .preserveAndAdopt
    }

    /// Write body text to FTS for a message. Caller sets GRDB flags (bodyComplete, bodyEmptyConfirmed).
    /// Whitespace-only bodies are silently skipped — caller should set bodyEmptyConfirmed in GRDB.
    func updateBody(contentKey: ContentKey, body: String) throws {
        ensureReady()
        guard let dbPool else { return }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        try dbPool.write { [self] db in
            guard let resolved = try resolveRowidAndYear(contentKey, db: db) else {
                print("[SearchIndex] updateBody: header \(contentKey.rawValue.prefix(30)) not in FTS yet, deferring")
                return
            }
            let table = ftsTableName(year: resolved.year)
            try db.execute(sql: "UPDATE \(table) SET body = ? WHERE rowid = ?",
                           arguments: [body, resolved.rowid])
        }
    }

    /// Update cc/bcc fields in FTS for existing messages (v10 migration backfill).
    func updateCcBcc(_ updates: [(contentKey: ContentKey, cc: String, bcc: String)]) throws {
        ensureReady()
        guard let dbPool, !updates.isEmpty else { return }
        try dbPool.write { [self] db in
            for update in updates {
                guard let resolved = try resolveRowidAndYear(update.contentKey, db: db) else { continue }
                let table = ftsTableName(year: resolved.year)
                try db.execute(sql: "UPDATE \(table) SET cc = ?, bcc = ? WHERE rowid = ?",
                               arguments: [update.cc, update.bcc, resolved.rowid])
            }
        }
    }

    /// One page entry for the orphan-prune cursor walk. A struct (not a
    /// labeled tuple) — tuple arrays crossing the actor boundary trip the
    /// Swift 6 region-isolation checker ("pattern that the region-based
    /// isolation checker does not understand", surfacing as a compile error
    /// in unrelated call sites of this actor).
    struct ContentKeyPageEntry: Sendable {
        let rowid: Int64
        let contentKey: ContentKey
        /// The account the row was indexed under, straight out of
        /// `message_meta.accountId`. Carried BESIDE the key so the orphan sweep's
        /// recovery leg never has to parse the key to find it — see
        /// `MessageContentStore.tail(of:folderId:)` for why parsing is wrong.
        /// Empty when no `message_meta` row exists for this rowid.
        let accountId: String
        /// `"<accountId>:<folderPath>"` from `message_meta.folderId`. Empty for rows
        /// indexed before that column existed (`backfillFolderIdsIfNeeded` fills
        /// those in).
        let folderId: String
    }

    /// Cursor page of entries from message_ids, ordered by rowid — pagination for
    /// the FTS→GRDB orphan prune. OFFSET-free so cost stays O(page) regardless of
    /// position in a large index.
    ///
    /// LEFT JOINs `message_meta` for the `accountId` / `folderId` the row was
    /// indexed under. Both are already-stored facts, so the sweep can resolve a
    /// content key's account and provider message id without splitting the key on
    /// `':'` — a `folderPath` may legitimately contain one.
    func contentKeyPage(afterRowid: Int64, limit: Int) throws -> [ContentKeyPageEntry] {
        guard let dbPool else { return [] }
        return try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT i.rowid AS rowid, i.headerId AS headerId,
                           COALESCE(m.accountId, '') AS accountId,
                           COALESCE(m.folderId, '') AS folderId
                    FROM message_ids i
                    LEFT JOIN message_meta m ON m.rowid = i.rowid
                    WHERE i.rowid > ? ORDER BY i.rowid LIMIT ?
                    """,
                arguments: [afterRowid, limit]
            ).map {
                ContentKeyPageEntry(
                    rowid: $0["rowid"] as Int64,
                    contentKey: $0["headerId"] as ContentKey,
                    accountId: $0["accountId"] as String,
                    folderId: $0["folderId"] as String
                )
            }
        }
    }

    /// Returns content keys from the input that are NOT in FTS message_meta.
    /// Used by backfill self-heal to find GRDB headers missing from FTS.
    func contentKeysMissingFromFTS(_ contentKeys: [ContentKey]) throws -> [ContentKey] {
        guard let dbPool, !contentKeys.isEmpty else { return [] }
        return try dbPool.read { db in
            var existing = Set<ContentKey>()
            for chunk in contentKeys.chunked(into: 500) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db,
                    sql: "SELECT headerId FROM message_meta WHERE headerId IN (\(placeholders))",
                    arguments: StatementArguments(chunk))
                for row in rows {
                    existing.insert(row["headerId"] as ContentKey)
                }
            }
            return contentKeys.filter { !existing.contains($0) }
        }
    }

    /// Batch update body text for multiple messages.
    /// Batch write body text to FTS. Caller sets GRDB flags (bodyComplete, bodyEmptyConfirmed).
    /// Whitespace-only bodies are silently skipped — caller should set bodyEmptyConfirmed in GRDB.
    /// Writes in sub-batches, grouped by year shard to minimize table switching.
    /// Returns the set of CONTENT KEYS that were actually written to FTS. Headers not yet
    /// in the FTS index are skipped — caller must NOT set bodyComplete for those.
    ///
    /// ⚠ The returned set is keyed by CONTENT KEY. A caller that flips
    /// `messageHeader.bodyComplete` for the confirmed subset must map each
    /// confirmed key back to its own `messageHeader.id` — the two are not
    /// interchangeable once the content key moves.
    @discardableResult
    func updateBodies(_ updates: [(contentKey: ContentKey, body: String)]) throws -> Set<ContentKey> {
        ensureReady()
        guard let dbPool, !updates.isEmpty else { return [] }

        // Filter out whitespace-only entries — caller handles GRDB flags
        let realUpdates = updates.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !realUpdates.isEmpty else { return [] }

        var writtenIds = Set<ContentKey>()
        let chunkSize = SyncConfig.ftsWriteBatchSize
        for chunkStart in stride(from: 0, to: realUpdates.count, by: chunkSize) {
            let chunk = realUpdates[chunkStart..<min(chunkStart + chunkSize, realUpdates.count)]
            let chunkWritten: [ContentKey] = try dbPool.write { [self] db in
                var updatesByYear: [Int: [(rowid: Int64, body: String, contentKey: ContentKey)]] = [:]
                for (contentKey, body) in chunk {
                    guard let resolved = try resolveRowidAndYear(contentKey, db: db) else {
                        print("[SearchIndex] updateBodies: header \(contentKey.rawValue.prefix(30)) not in FTS yet, deferring")
                        continue
                    }
                    updatesByYear[resolved.year, default: []].append((rowid: resolved.rowid, body: body, contentKey: contentKey))
                }

                var written: [ContentKey] = []
                for (year, yearUpdates) in updatesByYear {
                    let table = ftsTableName(year: year)
                    for (rowid, body, contentKey) in yearUpdates {
                        try db.execute(sql: "UPDATE \(table) SET body = ? WHERE rowid = ?",
                                       arguments: [body, rowid])
                        written.append(contentKey)
                    }
                }
                return written
            }
            writtenIds.formUnion(chunkWritten)
        }
        return writtenIds
    }

    /// Clear body text from FTS for a batch of messages. Caller resets GRDB bodyComplete.
    func clearBodies(contentKeys: [ContentKey]) throws {
        ensureReady()
        guard let dbPool, !contentKeys.isEmpty else { return }
        try dbPool.write { [self] db in
            for contentKey in contentKeys {
                guard let resolved = try resolveRowidAndYear(contentKey, db: db) else { continue }
                let table = ftsTableName(year: resolved.year)
                try db.execute(sql: "UPDATE \(table) SET body = '' WHERE rowid = ?",
                               arguments: [resolved.rowid])
            }
        }
    }

    /// Store an embedding vector for a message in the sqlite-vec KNN table.
    func storeEmbedding(contentKey: ContentKey, embedding: [Float]) throws {
        ensureReady()
        guard let dbPool else { return }
        try dbPool.write { db in
            // Graceful no-op if vec table doesn't exist (vec0 module unavailable)
            let vecTableExists = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='messages_vec'
                """) ?? false
            guard vecTableExists else { return }

            guard let rowid = try Int64.fetchOne(
                db,
                sql: "SELECT rowid FROM message_ids WHERE headerId = ?",
                arguments: [contentKey]
            ) else { return }

            let blob = embedding.withUnsafeBytes { Data($0) }
            // vec0 doesn't support INSERT OR REPLACE — delete first, then insert
            try db.execute(sql: "DELETE FROM messages_vec WHERE rowid = ?", arguments: [rowid])
            try db.execute(
                sql: "INSERT INTO messages_vec (rowid, embedding) VALUES (?, ?)",
                arguments: [rowid, blob]
            )
        }
    }

    /// Bulk store embeddings in a single FTS write transaction.
    func storeEmbeddings(_ items: [(contentKey: ContentKey, embedding: [Float])]) throws {
        ensureReady()
        guard let dbPool, !items.isEmpty else { return }
        try dbPool.write { db in
            let vecTableExists = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='messages_vec'
                """) ?? false
            guard vecTableExists else { return }

            for (contentKey, embedding) in items {
                guard let rowid = try Int64.fetchOne(
                    db,
                    sql: "SELECT rowid FROM message_ids WHERE headerId = ?",
                    arguments: [contentKey]
                ) else { continue }

                let blob = embedding.withUnsafeBytes { Data($0) }
                try db.execute(sql: "DELETE FROM messages_vec WHERE rowid = ?", arguments: [rowid])
                try db.execute(
                    sql: "INSERT INTO messages_vec (rowid, embedding) VALUES (?, ?)",
                    arguments: [rowid, blob]
                )
            }
        }
    }

    /// Remove messages from all FTS tables (for pruning/account deletion).
    func removeMessages(contentKeys: [ContentKey]) throws {
        ensureReady()
        guard let dbPool, !contentKeys.isEmpty else { return }
        try dbPool.write { [self] db in
            for contentKey in contentKeys {
                guard let resolved = try resolveRowidAndYear(contentKey, db: db) else { continue }
                try deleteEntry(contentKey: contentKey, rowid: resolved.rowid, year: resolved.year, db: db)
            }
        }
    }

    /// Delete one message's full FTS footprint (FTS row + meta + embedding +
    /// id mapping). The single source of truth for removal — used by
    /// `removeMessages` and `rekeyHeaders`' collision branch so the statement
    /// set can't drift between them.
    private func deleteEntry(contentKey: ContentKey, rowid: Int64, year: Int, db: Database) throws {
        let table = ftsTableName(year: year)
        try db.execute(sql: "DELETE FROM \(table) WHERE rowid = ?", arguments: [rowid])
        try db.execute(sql: "DELETE FROM message_meta WHERE rowid = ?", arguments: [rowid])
        try? db.execute(sql: "DELETE FROM messages_vec WHERE rowid = ?", arguments: [rowid])
        try db.execute(sql: "DELETE FROM message_ids WHERE headerId = ?", arguments: [contentKey])
    }

    /// Re-key FTS entries to a new header id IN PLACE — the FTS rowid (and
    /// with it the indexed body text and the messages_vec embedding) stays;
    /// only the id mapping moves. Used when sync re-keys a messageHeader PK:
    /// UID remap after IMAP moves, and optimistic-move remnant
    /// canonicalization. `newMessageId` optionally refreshes the FTS msgId
    /// column (UID remaps change the provider message id).
    ///
    /// If the new key already exists in FTS (e.g. a leftover orphan or a
    /// concurrent header-only index), KEEP THE RICHER ENTRY: body presence, then
    /// vector presence, then body length. Two rows must never share a content key
    /// (`message_ids.headerId` is the primary key), so exactly one of the pair is
    /// deleted — but which one is a content question, not an ordering accident.
    /// Dropping the old entry unconditionally discards a fully indexed body and its
    /// embedding merely because a skeletal new-key header landed first, and neither
    /// is recoverable without a full re-fetch of the message.
    /// PORT: `v2final:SearchIndex.rekeyHeaders` + `entryRichness` + `isRicher`
    /// (`a75196398`).
    func rekeyHeaders(_ rekeys: [(oldKey: ContentKey, newKey: ContentKey, newMessageId: String?)]) throws {
        ensureReady()
        guard let dbPool, !rekeys.isEmpty else { return }
        try dbPool.write { [self] db in
            for rekey in rekeys {
                // A self-rekey is already converged. Treat it as an explicit no-op:
                // collision handling would otherwise compare the row with ITSELF,
                // find neither side richer, and delete the entry's FTS body,
                // metadata and embedding outright.
                guard rekey.oldKey != rekey.newKey else { continue }
                guard let resolved = try resolveRowidAndYear(rekey.oldKey, db: db) else { continue }
                let table = ftsTableName(year: resolved.year)
                let newExists = try Bool.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) > 0 FROM message_ids WHERE headerId = ?",
                    arguments: [rekey.newKey]
                ) ?? false
                if newExists {
                    // An id with no `message_meta` row cannot be compared or moved
                    // onto; leave both entries untouched rather than guess.
                    guard let newResolved = try resolveRowidAndYear(rekey.newKey, db: db) else {
                        continue
                    }
                    let oldRichness = try entryRichness(
                        rowid: resolved.rowid, year: resolved.year, db: db)
                    let newRichness = try entryRichness(
                        rowid: newResolved.rowid, year: newResolved.year, db: db)
                    if Self.isRicher(oldRichness, than: newRichness) {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[SearchIndex] rekeyHeaders: preserving richer old entry \(rekey.oldKey.rawValue.prefix(40)) over skeletal \(rekey.newKey.rawValue.prefix(40))")
                        }
                        try deleteEntry(contentKey: rekey.newKey, rowid: newResolved.rowid,
                                        year: newResolved.year, db: db)
                    } else {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[SearchIndex] rekeyHeaders: \(rekey.newKey.rawValue.prefix(40)) already indexed — removing old entry \(rekey.oldKey.rawValue.prefix(40))")
                        }
                        try deleteEntry(contentKey: rekey.oldKey, rowid: resolved.rowid,
                                        year: resolved.year, db: db)
                        continue
                    }
                }
                try db.execute(sql: "UPDATE message_ids SET headerId = ? WHERE headerId = ?",
                               arguments: [rekey.newKey, rekey.oldKey])
                try db.execute(sql: "UPDATE message_meta SET headerId = ? WHERE rowid = ?",
                               arguments: [rekey.newKey, resolved.rowid])
                if let newMessageId = rekey.newMessageId {
                    try db.execute(sql: "UPDATE \(table) SET msgId = ? WHERE rowid = ?",
                                   arguments: [newMessageId, resolved.rowid])
                }
            }
        }
    }

    /// How much indexed CONTENT an FTS entry carries, for the `rekeyHeaders`
    /// collision compare. Ordered by what a re-fetch costs to rebuild: the indexed
    /// body first, then the embedding, then how much body there is.
    ///
    /// PORT (`v2final:SearchIndex.entryRichness`). The reference probes
    /// `sqlite_master` for `messages_vec` because it ships test seams that DROP the
    /// table (`testDropVectorTable` / `testRecreateVectorTable`); v3 has neither, but
    /// keeps the same probe at `storeEmbedding` / `storeEmbeddings` /
    /// `purgeForAccount` for the device where the `vec0` module fails to register, so
    /// the probe is carried here for the same reason rather than the reference's.
    private func entryRichness(
        rowid: Int64,
        year: Int,
        db: Database
    ) throws -> (hasBody: Bool, hasVector: Bool, bodyLength: Int) {
        let table = ftsTableName(year: year)
        let body = try String.fetchOne(
            db,
            sql: "SELECT body FROM \(table) WHERE rowid = ?",
            arguments: [rowid]
        ) ?? ""
        // A lone " " is this index's empty-body SENTINEL, not content — the same
        // reading `rawFTSBody` and `contentKeysWithFTSBody` already apply.
        let hasBody = !body.isEmpty && body != " "
        let vectorTableExists = try Bool.fetchOne(
            db,
            sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='messages_vec'"
        ) ?? false
        let hasVector: Bool
        if vectorTableExists {
            hasVector = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages_vec WHERE rowid = ?",
                arguments: [rowid]
            ) ?? 0) > 0
        } else {
            hasVector = false
        }
        // ⚠ MEASURES, never truncates. `body` is the FULL indexed text; only its
        // LENGTH is used, and nothing here writes back to any store.
        return (hasBody, hasVector, body.count)
    }

    /// PORT (`v2final:SearchIndex.isRicher`). Strict — equal richness is NOT
    /// "richer", so a tie keeps the pre-existing new-key entry and the old one is
    /// dropped, exactly as before this compare existed.
    private nonisolated static func isRicher(
        _ lhs: (hasBody: Bool, hasVector: Bool, bodyLength: Int),
        than rhs: (hasBody: Bool, hasVector: Bool, bodyLength: Int)
    ) -> Bool {
        if lhs.hasBody != rhs.hasBody { return lhs.hasBody }
        if lhs.hasVector != rhs.hasVector { return lhs.hasVector }
        return lhs.bodyLength > rhs.bodyLength
    }

    // MARK: - Folder ID Updates

    /// Batch-update folderId for messages (used by backfill and move sync).
    func updateFolderIds(contentKeys: [ContentKey], newFolderId: String) throws {
        ensureReady()
        guard let dbPool, !contentKeys.isEmpty else { return }
        try dbPool.write { [self] db in
            for contentKey in contentKeys {
                guard let resolved = try resolveRowidAndYear(contentKey, db: db) else { continue }
                try db.execute(sql: "UPDATE message_meta SET folderId = ? WHERE rowid = ?",
                               arguments: [newFolderId, resolved.rowid])
            }
        }
    }

    /// Return content keys where folderId is empty (for backfill).
    ///
    /// ⚠️ UNCURSORED — no `ORDER BY`, no `OFFSET`. The caller only ever advances by
    /// SHRINKING the `folderId = ''` set, so it must measure that set with
    /// `emptyFolderIdCount()` rather than assume anything about which rows this
    /// returns or in what order.
    func contentKeysWithEmptyFolderId(limit: Int) throws -> [ContentKey] {
        guard let dbPool else { return [] }
        return try dbPool.read { db in
            try ContentKey.fetchAll(db,
                sql: "SELECT headerId FROM message_meta WHERE folderId = '' LIMIT ?",
                arguments: [limit])
        }
    }

    /// How many entries still have an empty folderId — the backfill sweep's loop
    /// variant. Served by `idx_meta_folderId`, so it is an index range scan over
    /// exactly the rows still awaiting a backfill, not a table scan.
    func emptyFolderIdCount() throws -> Int {
        guard let dbPool else { return 0 }
        return try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_meta WHERE folderId = ''") ?? 0
        }
    }

    // MARK: - Keyword-Only Search

    /// Year shards sorted newest-first. Used by SearchView for progressive search.
    var sortedShardYears: [Int] { knownYears.sorted(by: >) }

    /// Search a single year shard. Returns results sorted by BM25 rank.
    /// Called per-shard by SearchView for progressive type-ahead.
    func keywordSearchShard(query: String, year: Int, limit: Int = SearchConfig.searchDefaultLimit) throws -> [FTSSearchResult] {
        guard let dbPool, knownYears.contains(year) else { return [] }

        let ftsQuery = SearchQueryParser.buildFTSMatch(query)
        guard !ftsQuery.isEmpty else { return [] }

        return try dbPool.read { [self] db in
            let table = ftsTableName(year: year)
            let sql = """
                SELECT meta.headerId, fts.msgId, meta.dateMs,
                    snippet(\(table), -1, '[', ']', '\u{2026}', \(SearchConfig.snippetTokens)) AS snippet,
                    bm25(\(table), \(SearchConfig.bm25Weights)) AS rank
                FROM \(table) fts
                JOIN message_meta meta ON fts.rowid = meta.rowid
                WHERE \(table) MATCH ?
                ORDER BY rank ASC
                LIMIT ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [ftsQuery, limit])
            return rows.map { row in
                FTSSearchResult(
                    contentKey: row["headerId"],
                    messageId: row["msgId"],
                    snippet: row["snippet"],
                    rank: row["rank"],
                    dateMs: row["dateMs"]
                )
            }
        }
    }

    /// SQL predicate scoping search results by account per demo state
    /// (ADR-IOS-038): demo mode searches ONLY the demo account's rows; normal
    /// mode never sees them. `qualifier` is the table alias prefix (e.g.
    /// "meta." or "" for unaliased message_meta). Uses the indexed
    /// message_meta.accountId column. Static + pure for tests.
    nonisolated static func demoAccountScopeSQL(demoActive: Bool, qualifier: String) -> String {
        demoActive
            ? "\(qualifier)accountId = '\(DemoSeed.demoAccountId)'"
            : "\(qualifier)accountId != '\(DemoSeed.demoAccountId)'"
    }

    /// Demo-scope check for results assembled without SQL scoping (vector-only
    /// hybrid hits). Content keys are `accountId:folderPath:<tail>`, so the
    /// account prefix is unaffected by where the tail comes from.
    nonisolated static func contentKeyInDemoScope(_ contentKey: ContentKey, demoActive: Bool) -> Bool {
        contentKey.rawValue.hasPrefix("\(DemoSeed.demoAccountId):") == demoActive
    }

    /// FTS5-only search across all year shards using a single UNION ALL query.
    /// Matching TB's search_fts_only() — sorts by dateMs DESC, rank ASC.
    func keywordSearch(query: String, fromDateMs: Int64? = nil, toDateMs: Int64? = nil,
                       limit: Int = SearchConfig.searchDefaultLimit,
                       folderIds: [String]? = nil) throws -> [FTSSearchResult] {
        ensureReady()
        guard dbPool != nil else { return [] }
        if let ids = folderIds, ids.isEmpty { return [] }

        let ftsQuery = SearchQueryParser.buildFTSMatch(query)
        guard !ftsQuery.isEmpty else { return [] }

        return try searchFTSOnly(ftsQuery: ftsQuery, fromDateMs: fromDateMs, toDateMs: toDateMs, limit: limit, folderIds: folderIds)
    }

    // MARK: - Hybrid Search

    /// Full hybrid search: FTS5 keyword + vector similarity, merged.
    /// Matching TB's search() in db.rs — includes date filtering, UNION ALL,
    /// proper FTS-only fallback, and column-scope filter-first.
    func search(query: String, fromDateMs: Int64? = nil, toDateMs: Int64? = nil,
                limit: Int = SearchConfig.searchDefaultLimit,
                folderIds: [String]? = nil) throws -> [FTSSearchResult] {
        guard let dbPool else { return [] }
        if let ids = folderIds, ids.isEmpty { return [] }

        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }

        let ftsQuery = SearchQueryParser.buildFTSMatch(query)
        let shardList = knownYears.sorted().map(String.init).joined(separator: ", ")
        print("[SearchIndex] search: raw='\(query.prefix(80))' fts='\(ftsQuery.prefix(100))' limit=\(limit) shards=[\(shardList)]")

        // When query parses to empty FTS (e.g., "*") but dates are provided,
        // fall back to date-range scan (list all emails in the period)
        if ftsQuery.isEmpty && (fromDateMs != nil || toDateMs != nil) {
            return try scanByDateRange(fromDateMs: fromDateMs, toDateMs: toDateMs, limit: limit, folderIds: folderIds)
        }
        // When query parses to empty FTS and no dates, nothing to search
        if ftsQuery.isEmpty {
            return []
        }

        // Fall back to FTS-only when no embedding engine
        guard let embeddingService = EmbeddingService.shared else {
            return try searchFTSOnly(ftsQuery: ftsQuery, fromDateMs: fromDateMs, toDateMs: toDateMs, limit: limit, folderIds: folderIds)
        }

        let candidateLimit = limit * SearchConfig.candidateMultiplier

        // --- FTS5 candidates (UNION ALL across all year shards) ---
        let ftsCandidates = try searchFTSCandidates(
            ftsQuery: ftsQuery, fromDateMs: fromDateMs, toDateMs: toDateMs, limit: candidateLimit, folderIds: folderIds)

        // --- Column-scope filter-first: restrict vector candidates to eligible rowids ---
        let eligibleRowids: Set<Int64>?
        if Self.queryHasColumnScope(ftsQuery) {
            let filterQuery = Self.extractColumnScopeFilter(ftsQuery)
            if !filterQuery.isEmpty {
                eligibleRowids = try fetchEligibleRowids(filterQuery: filterQuery, db: dbPool)
            } else {
                eligibleRowids = nil
            }
        } else {
            eligibleRowids = nil
        }

        // --- Vector candidates via sqlite-vec KNN ---
        let vecTopK = eligibleRowids != nil ? candidateLimit * 2 : candidateLimit
        let queryEmbedding = try embeddingService.embed(query)
        let allVec = searchVecCandidates(queryEmbedding: queryEmbedding, limit: vecTopK)
        let vectorCandidates: [(Int64, Double)]
        if let eligible = eligibleRowids {
            vectorCandidates = allVec.filter { eligible.contains($0.0) }
        } else {
            vectorCandidates = allVec
        }

        // Fall back to FTS-only when vec table is empty (e.g., during embedding rebuild).
        // Without this, hybrid weights (text_weight=0.3) penalize text-only results below MIN_SCORE.
        if vectorCandidates.isEmpty {
            print("[SearchIndex] No vector candidates (vec table may be empty), falling back to FTS-only search")
            return try searchFTSOnly(ftsQuery: ftsQuery, fromDateMs: fromDateMs, toDateMs: toDateMs, limit: limit, folderIds: folderIds)
        }

        // --- Merge ---
        let textPairs = ftsCandidates.map { ($0.rowid, $0.rank) }
        let merged = HybridMerge.mergeResults(
            textResults: textPairs, vectorResults: vectorCandidates,
            vectorWeight: SearchConfig.vectorWeight, textWeight: SearchConfig.textWeight,
            limit: limit)

        // --- Assemble results ---
        var ftsMap = [Int64: (contentKey: ContentKey, messageId: String, snippet: String, dateMs: Int64)]()
        for c in ftsCandidates {
            ftsMap[c.rowid] = (c.contentKey, c.messageId, c.snippet, c.dateMs)
        }

        var results = [FTSSearchResult]()
        for hr in merged {
            if let fts = ftsMap[hr.rowid] {
                // FTS result — has snippet
                results.append(FTSSearchResult(
                    contentKey: fts.contentKey, messageId: fts.messageId,
                    snippet: fts.snippet, rank: -hr.finalScore, dateMs: fts.dateMs
                ))
            } else {
                // Vector-only result — fetch metadata, apply date filter.
                // Demo scope: the KNN leg has no SQL account predicate, so
                // out-of-scope vector hits are dropped here (headerId is
                // accountId-prefixed).
                if let meta = try fetchMeta(rowid: hr.rowid) {
                    guard Self.contentKeyInDemoScope(meta.contentKey, demoActive: DemoModeStore.isDemoActive) else { continue }
                    if let from = fromDateMs, meta.dateMs < from { continue }
                    if let to = toDateMs, meta.dateMs > to { continue }
                    results.append(FTSSearchResult(
                        contentKey: meta.contentKey, messageId: meta.messageId,
                        snippet: "", rank: -hr.finalScore, dateMs: meta.dateMs
                    ))
                }
            }
        }

        let filterInfo = eligibleRowids != nil ? ", filtered to \(eligibleRowids!.count) eligible" : ""
        print("[SearchIndex] Hybrid search: \(results.count) results (FTS: \(ftsCandidates.count), Vec: \(vectorCandidates.count)\(filterInfo))")
        return results
    }

    // MARK: - Internal Search Helpers

    /// FTS candidate for hybrid merge — includes rowid for matching with vector results.
    private struct FTSCandidate {
        let rowid: Int64
        let contentKey: ContentKey
        let messageId: String
        let snippet: String
        let rank: Double
        let dateMs: Int64
    }

    /// Get FTS5 candidates with metadata for hybrid merge using a single UNION ALL query.
    /// Matching TB's search_fts_candidates() — sorts by rank ASC (best BM25 first).
    private func searchFTSCandidates(ftsQuery: String, fromDateMs: Int64?, toDateMs: Int64?,
                                      limit: Int, folderIds: [String]? = nil) throws -> [FTSCandidate] {
        guard let dbPool, !knownYears.isEmpty else { return [] }

        return try dbPool.read { [self] db in
            // Build UNION ALL across all year shards with shared bind params.
            // ?1 = ftsQuery (reused in every subquery), optional ?2/?3 = dates, folder placeholders, ?N = limit.
            var nextParam = 2
            let nonEmptyFolderIds = folderIds.flatMap { $0.isEmpty ? nil : $0 }
            let fromParam: Int? = fromDateMs != nil ? { let p = nextParam; nextParam += 1; return p }() : nil
            let toParam: Int? = toDateMs != nil ? { let p = nextParam; nextParam += 1; return p }() : nil
            let folderParamStart: Int? = nonEmptyFolderIds != nil ? { let p = nextParam; nextParam += nonEmptyFolderIds!.count; return p }() : nil
            let limitParam = nextParam

            let folderPlaceholders = nonEmptyFolderIds.map { ids in ids.indices.map { "?\(folderParamStart! + $0)" }.joined(separator: ", ") }

            let subqueries = knownYears.sorted().map { year -> String in
                let table = ftsTableName(year: year)
                var sq = """
                    SELECT fts.rowid, meta.headerId, fts.msgId, meta.dateMs,
                        snippet(\(table), -1, '[', ']', '\u{2026}', \(SearchConfig.snippetTokens)) AS snippet,
                        bm25(\(table), \(SearchConfig.bm25Weights)) AS rank
                    FROM \(table) fts
                    JOIN message_meta meta ON fts.rowid = meta.rowid
                    WHERE \(table) MATCH ?1
                      AND \(Self.demoAccountScopeSQL(demoActive: DemoModeStore.isDemoActive, qualifier: "meta."))
                    """
                if let p = fromParam { sq += " AND meta.dateMs >= ?\(p)" }
                if let p = toParam { sq += " AND meta.dateMs <= ?\(p)" }
                if let fp = folderPlaceholders { sq += " AND meta.folderId IN (\(fp))" }
                return sq
            }

            var args: [DatabaseValueConvertible] = [ftsQuery]
            if let from = fromDateMs { args.append(from) }
            if let to = toDateMs { args.append(to) }
            if let ids = nonEmptyFolderIds { args.append(contentsOf: ids) }
            args.append(limit)

            let sql = subqueries.joined(separator: " UNION ALL ") +
                " ORDER BY rank ASC LIMIT ?\(limitParam)"

            // Gated. This arm is the HYBRID path (`search()` ← `EmailSearchTool`), not the
            // per-keystroke typing path — that one is `keywordSearch` → `searchFTSOnly`
            // below. Same defect either way: `\(args)` interpolates the WHOLE
            // bind-argument array — every scoped folder id, some of them long provider
            // ids — so ungated it built and discarded that string on every search in
            // production. Kept, not deleted (debug code is preserved here); the gate is
            // the fix.
            if DebugModeManager.isLoggingEnabled() {
                print("[SearchIndex] FTS candidates args: \(args)")
            }

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            if DebugModeManager.isLoggingEnabled() {
                print("[SearchIndex] FTS candidates returned \(rows.count) rows")
            }
            return rows.map { row in
                FTSCandidate(
                    rowid: row["rowid"], contentKey: row["headerId"],
                    messageId: row["msgId"], snippet: row["snippet"],
                    rank: row["rank"], dateMs: row["dateMs"]
                )
            }
        }
    }

    /// FTS-only search across all year shards using a single UNION ALL query.
    /// Matching TB's search_fts_only() — sorts by dateMs DESC, rank ASC.
    private func searchFTSOnly(ftsQuery: String, fromDateMs: Int64?, toDateMs: Int64?,
                                limit: Int, folderIds: [String]? = nil) throws -> [FTSSearchResult] {
        guard let dbPool, !knownYears.isEmpty, !ftsQuery.isEmpty else { return [] }

        return try dbPool.read { [self] db in
            let nonEmptyFolderIds = folderIds.flatMap { $0.isEmpty ? nil : $0 }
            var nextParam = 2
            let fromParam: Int? = fromDateMs != nil ? { let p = nextParam; nextParam += 1; return p }() : nil
            let toParam: Int? = toDateMs != nil ? { let p = nextParam; nextParam += 1; return p }() : nil
            let folderParamStart: Int? = nonEmptyFolderIds != nil ? { let p = nextParam; nextParam += nonEmptyFolderIds!.count; return p }() : nil
            let limitParam = nextParam

            let folderPlaceholders = nonEmptyFolderIds.map { ids in ids.indices.map { "?\(folderParamStart! + $0)" }.joined(separator: ", ") }

            let subqueries = knownYears.sorted().map { year -> String in
                let table = ftsTableName(year: year)
                var sq = """
                    SELECT meta.headerId, fts.msgId, meta.dateMs,
                        snippet(\(table), -1, '[', ']', '\u{2026}', \(SearchConfig.snippetTokens)) AS snippet,
                        bm25(\(table), \(SearchConfig.bm25Weights)) AS rank
                    FROM \(table) fts
                    JOIN message_meta meta ON fts.rowid = meta.rowid
                    WHERE \(table) MATCH ?1
                      AND \(Self.demoAccountScopeSQL(demoActive: DemoModeStore.isDemoActive, qualifier: "meta."))
                    """
                if let p = fromParam { sq += " AND meta.dateMs >= ?\(p)" }
                if let p = toParam { sq += " AND meta.dateMs <= ?\(p)" }
                if let fp = folderPlaceholders { sq += " AND meta.folderId IN (\(fp))" }
                return sq
            }

            var args: [DatabaseValueConvertible] = [ftsQuery]
            if let from = fromDateMs { args.append(from) }
            if let to = toDateMs { args.append(to) }
            if let ids = nonEmptyFolderIds { args.append(contentsOf: ids) }
            args.append(limit)

            let sql = subqueries.joined(separator: " UNION ALL ") +
                " ORDER BY dateMs DESC, rank ASC LIMIT ?\(limitParam)"

            // Gated for the same reason as `searchFTSCandidates` above: this is THE
            // per-keystroke path (it is the query the Archive-search stall episode was
            // logged from), and ungated it interpolated a 300-char SQL prefix plus the
            // whole bind-argument array on every search in production. Kept, not deleted.
            if DebugModeManager.isLoggingEnabled() {
                print("[SearchIndex] FTS-only SQL: \(sql.prefix(300))")
                print("[SearchIndex] FTS-only args: \(args)")
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            if DebugModeManager.isLoggingEnabled() {
                print("[SearchIndex] FTS-only returned \(rows.count) rows")
            }
            return rows.map { row in
                FTSSearchResult(
                    contentKey: row["headerId"], messageId: row["msgId"],
                    snippet: row["snippet"], rank: row["rank"], dateMs: row["dateMs"]
                )
            }
        }
    }

    /// Date-range-only scan when FTS query is empty (e.g., "*" with date params).
    /// Returns messages in the date range sorted by date DESC — no text matching.
    private func scanByDateRange(fromDateMs: Int64?, toDateMs: Int64?,
                                  limit: Int, folderIds: [String]? = nil) throws -> [FTSSearchResult] {
        guard let dbPool else { return [] }
        return try dbPool.read { db in
            var sql = "SELECT headerId, dateMs FROM message_meta WHERE "
                + Self.demoAccountScopeSQL(demoActive: DemoModeStore.isDemoActive, qualifier: "")
            var args: [DatabaseValueConvertible] = []
            if let from = fromDateMs { sql += " AND dateMs >= ?"; args.append(from) }
            if let to = toDateMs { sql += " AND dateMs <= ?"; args.append(to) }
            if let ids = folderIds, !ids.isEmpty {
                let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
                sql += " AND folderId IN (\(placeholders))"
                args.append(contentsOf: ids)
            }
            sql += " ORDER BY dateMs DESC LIMIT ?"
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                FTSSearchResult(
                    contentKey: row["headerId"], messageId: "",
                    snippet: "", rank: 0, dateMs: row["dateMs"]
                )
            }
        }
    }

    // MARK: - KNN Vector Search

    /// Query sqlite-vec KNN index for nearest neighbors.
    /// Returns array of (rowid, cosineDistance) sorted by distance ascending.
    /// Gracefully returns empty if the vec table doesn't exist (e.g., during rebuild).
    ///
    /// Uses the writer connection (not reader pool) to avoid sqlite-vec vtab lifecycle
    /// crash — vec0 caches prepared statements per connection, and reader pool
    /// connection recycling can cause SIGABRT in vec0_free_resources on disconnect.
    private func searchVecCandidates(queryEmbedding: [Float], limit: Int) -> [(Int64, Double)] {
        guard let dbPool else { return [] }
        let blob = queryEmbedding.withUnsafeBytes { Data($0) }
        do {
            return try dbPool.writeWithoutTransaction { db in
                try Row.fetchAll(db, sql: """
                    SELECT rowid, distance FROM messages_vec WHERE embedding MATCH ? AND k = ?
                    """, arguments: [blob, limit])
                .compactMap { row -> (Int64, Double)? in
                    guard let rowid = row["rowid"] as Int64?,
                          let distance = row["distance"] as Double? else { return nil }
                    return (rowid, distance)
                }
            }
        } catch {
            // Graceful fallback — vec table may not exist yet (matching TB's unwrap_or_default)
            print("[SearchIndex] Vec search failed (table may not exist): \(error)")
            return []
        }
    }

    // MARK: - Column Scope Detection & Filtering

    /// Check if a processed FTS5 query contains column-scoped terms.
    /// After buildFTSMatch(), field aliases are already translated (from: → from_:, to: → to_:).
    private static let columnScopePrefixes = ["from_:", "to_:", "subject:", "cc:", "bcc:", "body:"]

    private static func queryHasColumnScope(_ ftsQuery: String) -> Bool {
        columnScopePrefixes.contains { ftsQuery.contains($0) }
    }

    /// Extract only the column-scoped terms from a processed FTS5 query.
    /// Given `from_:"alice@example.com" hiring*`, returns `from_:"alice@example.com"`.
    /// Used to build a filter-only query for pre-filtering vector candidates.
    private static func extractColumnScopeFilter(_ ftsQuery: String) -> String {
        var scopedTerms: [String] = []
        var i = ftsQuery.startIndex

        while i < ftsQuery.endIndex {
            // Skip whitespace and AND/OR keywords
            if ftsQuery[i].isWhitespace {
                i = ftsQuery.index(after: i)
                continue
            }

            let remaining = String(ftsQuery[i...])

            // Check if current position starts with a column scope prefix
            var matchedPrefix: String?
            for prefix in columnScopePrefixes {
                if remaining.hasPrefix(prefix) {
                    matchedPrefix = prefix
                    break
                }
            }

            if let prefix = matchedPrefix {
                // Found a column-scoped term — consume field:value
                let start = i
                i = ftsQuery.index(i, offsetBy: prefix.count)

                if i < ftsQuery.endIndex && ftsQuery[i] == "\"" {
                    // Quoted value: field:"value" or prefix form field:"value"*
                    i = ftsQuery.index(after: i)
                    while i < ftsQuery.endIndex && ftsQuery[i] != "\"" {
                        i = ftsQuery.index(after: i)
                    }
                    if i < ftsQuery.endIndex {
                        i = ftsQuery.index(after: i) // closing quote
                    }
                    if i < ftsQuery.endIndex && ftsQuery[i] == "*" {
                        i = ftsQuery.index(after: i) // prefix star — keep so the
                        // filter query preserves the main query's prefix semantics
                    }
                } else {
                    // Unquoted value: field:value*
                    while i < ftsQuery.endIndex && !ftsQuery[i].isWhitespace {
                        i = ftsQuery.index(after: i)
                    }
                }

                scopedTerms.append(String(ftsQuery[start..<i]))
            } else {
                // Non-scoped token — skip it
                if ftsQuery[i] == "\"" {
                    // Skip quoted phrase
                    i = ftsQuery.index(after: i)
                    while i < ftsQuery.endIndex && ftsQuery[i] != "\"" {
                        i = ftsQuery.index(after: i)
                    }
                    if i < ftsQuery.endIndex { i = ftsQuery.index(after: i) }
                } else if ftsQuery[i] == "(" {
                    // Skip parenthesized group (synonym OR expansion)
                    var depth = 1
                    i = ftsQuery.index(after: i)
                    while i < ftsQuery.endIndex && depth > 0 {
                        if ftsQuery[i] == "(" { depth += 1 }
                        if ftsQuery[i] == ")" { depth -= 1 }
                        i = ftsQuery.index(after: i)
                    }
                } else {
                    // Regular token — skip
                    while i < ftsQuery.endIndex && !ftsQuery[i].isWhitespace {
                        i = ftsQuery.index(after: i)
                    }
                }
            }
        }

        return scopedTerms.joined(separator: " ")
    }

    /// Fetch all rowids matching a column-scope filter query across all year shards.
    /// Used to pre-filter vector candidates so only messages matching the column
    /// constraint (e.g., from a specific sender) are included in hybrid results.
    private func fetchEligibleRowids(filterQuery: String, db dbPool: DatabasePool) throws -> Set<Int64> {
        try dbPool.read { [self] db in
            var rowids = Set<Int64>()
            for year in knownYears {
                let table = ftsTableName(year: year)
                let ids = try Int64.fetchAll(db, sql: """
                    SELECT fts.rowid FROM \(table) fts WHERE \(table) MATCH ?
                    """, arguments: [filterQuery])
                rowids.formUnion(ids)
            }
            return rowids
        }
    }

    // MARK: - Helpers

    private func fetchMeta(rowid: Int64) throws -> (contentKey: ContentKey, messageId: String, dateMs: Int64)? {
        guard let dbPool else { return nil }
        return try dbPool.read { [self] db in
            guard let metaRow = try Row.fetchOne(db, sql: """
                SELECT headerId, dateMs, shardYear FROM message_meta WHERE rowid = ?
                """, arguments: [rowid]) else { return nil }
            let year: Int = metaRow["shardYear"]
            let table = ftsTableName(year: year)
            let msgId = try String.fetchOne(db, sql: "SELECT msgId FROM \(table) WHERE rowid = ?",
                                            arguments: [rowid]) ?? ""
            return (metaRow["headerId"], msgId, metaRow["dateMs"])
        }
    }

    /// Check if a content row is already indexed.
    func isIndexed(contentKey: ContentKey) throws -> Bool {
        guard let dbPool else { return false }
        return try dbPool.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message_ids WHERE headerId = ?",
                arguments: [contentKey]
            ) ?? 0
            return count > 0
        }
    }

    /// Optimize FTS5 index (merge segments) across all year shards.
    func optimize() throws {
        guard let dbPool else { return }
        try dbPool.write { [self] db in
            for year in knownYears {
                let table = ftsTableName(year: year)
                try db.execute(sql: "INSERT INTO \(table)(\(table)) VALUES('optimize')")
            }
        }
        print("[SearchIndex] FTS shards optimized: \(knownYears.count) tables")
    }

    /// Drop all tables and recreate the schema. Used for one-time clean resets.
    /// Drop the entire FTS database file and reinitialize from scratch.
    /// Much faster than row-by-row SQL deletes — just removes the file.
    /// After this, `bulkIndexIfNeeded` will re-populate from GRDB on next sync.
    func resetAll() throws {
        // 1. Drop vec0 table BEFORE closing pool — vec0Destroy properly finalizes
        // prepared statements, preventing SIGABRT in vec0_free_resources during
        // pool deinit → connection close path.
        if let pool = dbPool {
            try? pool.write { db in
                try db.execute(sql: "DROP TABLE IF EXISTS messages_vec")
            }
        }

        // 2. Close existing database pool (safe now — no vec0 instances)
        dbPool = nil
        isInitialized = false
        knownYears.removeAll()

        // 3. Delete the entire FTS directory (fts.db + WAL/SHM files)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let ftsDir = appSupport.appendingPathComponent("tabmail_fts", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: ftsDir.path) {
            try fm.removeItem(at: ftsDir)
            print("[SearchIndex] Deleted FTS directory: \(ftsDir.path)")
        }

        // 4. Reinitialize — creates fresh directory, schema, and empty database
        try initialize()
        print("[SearchIndex] Reset complete — fresh database ready")
    }


    /// Purge all FTS rows that belong to a single account from every
    /// year-sharded table. Used by demo mode (`accountId == "demo-account"`)
    /// to clear demo entries on exit without nuking the entire FTS db.
    ///
    /// Walks `message_meta`, deletes matching `messages_fts_YYYY` rows by
    /// rowid (per shard year), then deletes the metadata rows and any vec0
    /// embedding rows. No-op when SearchIndex is uninitialized.
    func purgeForAccount(_ accountId: String) {
        guard let dbPool else { return }
        do {
            try dbPool.write { db in
                struct ShardRow: FetchableRecord, Decodable {
                    let rowid: Int64
                    let shardYear: Int
                }
                let rows = try ShardRow.fetchAll(
                    db,
                    sql: "SELECT rowid, shardYear FROM message_meta WHERE accountId = ?",
                    arguments: [accountId]
                )
                if rows.isEmpty {
                    return
                }
                let byYear = Dictionary(grouping: rows, by: { $0.shardYear })
                for (year, group) in byYear {
                    let table = "messages_fts_\(year)"
                    // Verify table exists (older years may not be created yet).
                    let exists = try Bool.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name=?",
                        arguments: [table]
                    ) ?? false
                    if !exists { continue }
                    for row in group {
                        try db.execute(sql: "DELETE FROM \(table) WHERE rowid = ?", arguments: [row.rowid])
                    }
                }
                // Delete vec0 embeddings (table may not exist).
                let vecExists = try Bool.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='messages_vec'"
                ) ?? false
                if vecExists {
                    for row in rows {
                        try? db.execute(sql: "DELETE FROM messages_vec WHERE rowid = ?", arguments: [row.rowid])
                    }
                }
                // Finally clear metadata + dedup ids.
                try db.execute(sql: "DELETE FROM message_meta WHERE accountId = ?", arguments: [accountId])
                try db.execute(sql: "DELETE FROM message_ids WHERE headerId LIKE ?", arguments: ["\(accountId):%"])
            }
            print("[SearchIndex] purgeForAccount(\(accountId)) done")
        } catch {
            print("[SearchIndex] purgeForAccount failed: \(error)")
        }
    }

    /// Reclaim disk space after bulk deletes.
    func vacuum() throws {
        guard let dbPool else { return }
        try dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
        print("[SearchIndex] VACUUM complete")
    }



    /// Whether the FTS database pool is initialized and ready for queries.
    var isReady: Bool { dbPool != nil }

    /// Diagnostic: returns a human-readable reason why bodyText() would return nil.
    /// Used by AI queue to log root cause of missing FTS body.
    func bodyTextDiagnostic(contentKey: ContentKey) -> String {
        ensureReady()
        guard let dbPool else { return "dbPoolNil" }
        do {
            return try dbPool.read { [self] db in
                guard let resolved = try resolveRowidAndYear(contentKey, db: db) else {
                    return "notInFtsIndex"
                }
                let table = ftsTableName(year: resolved.year)
                let body = try String.fetchOne(db, sql: "SELECT body FROM \(table) WHERE rowid = ?",
                                               arguments: [resolved.rowid])
                if body == nil { return "rowMissingInShard(\(table))" }
                if body == " " { return "sentinelSpace" }
                if body?.isEmpty == true { return "emptyString" }
                return "bodyPresent(len=\(body!.count))"
            }
        } catch {
            return "readError(\(error.localizedDescription))"
        }
    }

    /// Get body text for a header (for snippet derivation from existing FTS data).
    func bodyText(contentKey: ContentKey) throws -> String? {
        ensureReady()
        guard let dbPool else { return nil }
        return try dbPool.read { [self] db in
            guard let resolved = try resolveRowidAndYear(contentKey, db: db) else { return nil }
            let table = ftsTableName(year: resolved.year)
            let body = try String.fetchOne(db, sql: "SELECT body FROM \(table) WHERE rowid = ?",
                                           arguments: [resolved.rowid])
            guard let body, !body.isEmpty, body != " " else { return nil }
            return body
        }
    }

    /// Bulk read body texts for multiple headers in a single FTS transaction.
    func bodyTexts(contentKeys: [ContentKey]) throws -> [ContentKey: String] {
        ensureReady()
        guard let dbPool, !contentKeys.isEmpty else { return [:] }
        return try dbPool.read { [self] db in
            var result: [ContentKey: String] = [:]
            for contentKey in contentKeys {
                guard let resolved = try resolveRowidAndYear(contentKey, db: db) else { continue }
                let table = ftsTableName(year: resolved.year)
                let body = try String.fetchOne(db, sql: "SELECT body FROM \(table) WHERE rowid = ?",
                                               arguments: [resolved.rowid])
                guard let body, !body.isEmpty, body != " " else { continue }
                result[contentKey] = body
            }
            return result
        }
    }

    /// Which of the given headers have REAL body text indexed in FTS.
    /// Length-only probe (never materializes body text — the one-time
    /// bodyComplete restore feeds this thousands of ids at once). A length-1
    /// body is treated as absent: it's either the " " sentinel or too short to
    /// distinguish from one — conservative callers refetch it once.
    func contentKeysWithFTSBody(_ contentKeys: [ContentKey]) throws -> Set<ContentKey> {
        ensureReady()
        guard let dbPool, !contentKeys.isEmpty else { return [] }
        return try dbPool.read { [self] db in
            var result = Set<ContentKey>()
            for contentKey in contentKeys {
                guard let resolved = try resolveRowidAndYear(contentKey, db: db) else { continue }
                let table = ftsTableName(year: resolved.year)
                let length = try Int.fetchOne(db, sql: "SELECT length(body) FROM \(table) WHERE rowid = ?",
                                              arguments: [resolved.rowid])
                if let length, length > 1 {
                    result.insert(contentKey)
                }
            }
            return result
        }
    }

    /// Raw FTS body without sentinel filtering — used by self-heal to distinguish
    /// sentinel values (e.g. " ") from truly empty bodies.
    func rawFTSBody(contentKey: ContentKey) throws -> String? {
        guard let dbPool else { return nil }
        return try dbPool.read { [self] db in
            guard let resolved = try resolveRowidAndYear(contentKey, db: db) else { return nil }
            let table = ftsTableName(year: resolved.year)
            return try String.fetchOne(db, sql: "SELECT body FROM \(table) WHERE rowid = ?",
                                       arguments: [resolved.rowid])
        }
    }

}
