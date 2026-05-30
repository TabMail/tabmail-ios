/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// Memory search hybrid FTS5 + sqlite-vec pipeline for chatHistory turns.
// Per-turn granularity (v3). Sibling to `SearchIndex` (email). Separate
// `DatabasePool` at memory.db. Isolated from tabmail.sqlite — no ATTACH,
// no cross-file references.
//
// Design / scope: ADR-IOS-034.
//
// Rules:
// - chatHistory (tabmail.sqlite) is the authoritative source of truth.
//   memory.db is a derived index — can be nuked and rebuilt from chatHistory
//   via `MemorySelfHealDriver.runStageA()` at any time.
// - One memory_meta row per chatHistory turn, keyed by `chatHistoryId`.
//   memory_fts / memory_vec share rowid with memory_meta.
// - indexEpoch race stamp survives SQLite rowid reuse; keyed on chatHistoryId
//   (not rowid) because stringly-stable across re-writes.
// - `embeddingComplete = 0` partial index keeps Stage B repopulate O(pending).

/// Result type for per-turn hybrid memory search.
struct MemoryHit: Sendable, Hashable {
    let chatHistoryId: String
    let sessionId: String?
    let role: String
    let dateMs: Int64
    let content: String
    let snippet: String     // FTS5 snippet when matched, empty string for vec-only/listing hits
    let textScore: Double
    let vectorScore: Double
    let finalScore: Double
}

actor MemoryIndex {
    static let shared = MemoryIndex()

    private var dbPool: DatabasePool?
    private var isInitialized = false

    /// Schema version stored in `PRAGMA user_version`. Bumping this triggers a
    /// drop-and-rebuild of all memory_* tables on next launch. memory.db is a
    /// derived index — Stage A refills from chatHistory.
    private static let schemaVersion: Int32 = 3

    // MARK: - Init

    private func ensureReady() {
        guard !isInitialized else { return }
        do {
            try initialize()
        } catch {
            print("[MemoryIndex] Lazy initialization failed: \(error)")
        }
    }

    private func initialize() throws {
        guard !isInitialized else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TabMail/tabmail_memory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbPath = dir.appendingPathComponent("memory.db").path
        print("[MemoryIndex] Opening memory database at \(dbPath)")

        var config = Configuration()
        // Smaller reader pool than SearchIndex (email) — memory search has much
        // lower read volume. 16 is plenty.
        config.maximumReaderCount = 16
        config.prepareDatabase { db in
            // Register sqlite-vec vec0 module on this connection.
            // tabmail_register_sqlite_vec_on_db is idempotent per-connection
            // (sqlite_vec_register.c:12-13), so it's safe to call alongside
            // SearchIndex's registration on a separate pool.
            if let sqliteConn = db.sqliteConnection {
                let rc = tabmail_register_sqlite_vec_on_db(UnsafeMutableRawPointer(sqliteConn))
                if rc != 0 /* SQLITE_OK */ {
                    print("[MemoryIndex] WARNING: sqlite-vec registration returned \(rc)")
                }
            }

            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA cache_size = \(SearchConfig.cacheSizeKiB)")
            try db.execute(sql: "PRAGMA busy_timeout = \(SearchConfig.busyTimeoutMs)")
        }

        let pool = try DatabasePool(path: dbPath, configuration: config)
        dbPool = pool

        // Schema-version gate. If we detect a pre-v3 schema (v0 on first launch
        // after upgrade, or a leftover v2 memory.db), drop every memory_* table
        // and let Stage A refill. chatHistory is unaffected.
        try pool.write { db in
            let currentVersion: Int32 = try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if currentVersion < Self.schemaVersion {
                print("[MemoryIndex] Schema v\(currentVersion) < v\(Self.schemaVersion) — dropping old memory_* tables")
                try db.execute(sql: "DROP TABLE IF EXISTS memory_vec")
                try db.execute(sql: "DROP TABLE IF EXISTS memory_meta")
                try db.execute(sql: "DROP TABLE IF EXISTS memory_fts")
            }
        }

        try createSchema()

        try pool.write { db in
            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
        }

        isInitialized = true

        // Init-time census: table counts, scope breakdown, orphan detection.
        do {
            let (metaC, ftsC, vecC, completeC, scopeBreakdown) = try pool.read { db -> (Int, Int, Int, Int, [(String, Int)]) in
                let m = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_meta") ?? 0
                let f = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_fts") ?? 0
                let v = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_vec") ?? 0
                let c = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_meta WHERE embeddingComplete = 1") ?? 0
                let rows = try Row.fetchAll(db, sql: """
                    SELECT CASE
                        WHEN sessionId LIKE 'msg:%' THEN 'msg'
                        WHEN sessionId LIKE 'compose:%' THEN 'compose'
                        WHEN sessionId IS NULL THEN 'null'
                        ELSE 'inbox'
                    END AS scope, COUNT(*) AS n
                    FROM memory_meta GROUP BY scope
                    """)
                let breakdown = rows.map { (($0["scope"] as String?) ?? "?", ($0["n"] as Int?) ?? 0) }
                return (m, f, v, c, breakdown)
            }
            print("[MemoryIndex] Initialized meta=\(metaC) fts=\(ftsC) vec=\(vecC) embedComplete=\(completeC) scope=\(scopeBreakdown)")
            if vecC > metaC {
                print("[MemoryIndex] WARNING: vec has \(vecC - metaC) orphan row(s) (vec > meta)")
            }
            if ftsC > metaC {
                print("[MemoryIndex] WARNING: fts has \(ftsC - metaC) orphan row(s) (fts > meta)")
            }
        } catch {
            print("[MemoryIndex] Count snapshot failed: \(error)")
        }
    }

    private func createSchema() throws {
        guard let dbPool else { return }
        try dbPool.write { db in
            // memory_fts: single-column FTS5 table. The content column is at index 0,
            // which is why our snippet() call uses col_index=0 (TB's schema has 4 FTS
            // columns and uses col_index=2; do NOT copy that constant).
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
                    content,
                    tokenize = "porter unicode61 remove_diacritics 2 tokenchars '-_.@'",
                    prefix = '2 3 4'
                )
                """)

            // Per-turn metadata. `chatHistoryId` is the stable cross-table reference
            // to `chatHistory.id`. `indexEpoch` catches reindex races (see
            // `storeEmbeddings`). Turn-level model means one row per chatHistory turn.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS memory_meta (
                    rowid INTEGER PRIMARY KEY,
                    chatHistoryId TEXT UNIQUE NOT NULL,
                    sessionId TEXT,
                    role TEXT NOT NULL,
                    dateMs INTEGER NOT NULL,
                    indexEpoch INTEGER NOT NULL DEFAULT 1,
                    embeddingComplete INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_memory_meta_dateMs ON memory_meta(dateMs)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_memory_meta_sessionId ON memory_meta(sessionId)")
            // Composite index for `readByTimestamp`'s session-bounded window walk.
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_memory_meta_session_date ON memory_meta(sessionId, dateMs)")
            // Partial index — only "needs embed" rows. Steady-state near-empty.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_memory_meta_embeddingComplete
                ON memory_meta(embeddingComplete)
                WHERE embeddingComplete = 0
                """)

            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS memory_vec USING vec0(
                    embedding FLOAT[\(SearchConfig.embeddingDims)] distance_metric=cosine
                )
                """)
        }
    }

    // MARK: - Text Extraction

    /// Per-turn searchable text. Single source of truth used by both write-time
    /// (`ChatStore.appendTurn`) and catch-up time (`MemorySelfHealDriver`).
    ///
    /// For user turns, prefer `userMessage` over `content` — `content` is the
    /// template name ("chat_converse"), not human text. The v2 session-end hook
    /// had a separate ChatTurn-based extractor that read `renderedContent`; v3
    /// operates on ChatHistoryTurn only (always post-dereference), so the
    /// dual-path complexity is gone.
    ///
    /// Returns nil for non-allowlisted turns (type != "normal", unknown roles,
    /// or empty text after extraction). Nil signals "skip indexing".
    static func memoryText(for turn: ChatHistoryTurn) -> String? {
        guard turn.type == "normal" else { return nil }
        let text: String
        switch turn.role {
        case "user":
            if let userMessage = turn.userMessage, !userMessage.isEmpty {
                text = userMessage
            } else {
                text = turn.content
            }
        case "assistant":
            text = turn.content
        default:
            return nil
        }
        return text.isEmpty ? nil : text
    }

    // MARK: - Indexing

    /// Idempotent upsert of a single turn. Called synchronously after the
    /// chatHistory write commits. Non-throwing — logs errors internally; Stage A
    /// self-heal (A−B direction) picks up any write that fails here.
    func indexTurn(chatHistoryId: String, sessionId: String?, role: String, dateMs: Int64, text: String) {
        ensureReady()
        guard let dbPool else { return }
        do {
            try dbPool.write { db in
                try Self.writeTurn(db: db, chatHistoryId: chatHistoryId, sessionId: sessionId, role: role, dateMs: dateMs, text: text)
            }
            let head = String(text.prefix(80)).replacingOccurrences(of: "\n", with: "\\n")
            print("[MemoryIndex] indexTurn WRITE id=\(chatHistoryId.prefix(20)) sid=\(sessionId?.prefix(30) ?? "nil") role=\(role) chars=\(text.count) head=\(head)")
        } catch {
            print("[MemoryIndex] indexTurn(\(chatHistoryId.prefix(20))) failed: \(error)")
        }
    }

    /// Bulk variant for Stage A self-heal. One transaction covers all turns.
    func indexTurns(_ entries: [(chatHistoryId: String, sessionId: String?, role: String, dateMs: Int64, text: String)]) {
        ensureReady()
        guard let dbPool, !entries.isEmpty else { return }
        do {
            try dbPool.write { db in
                for e in entries {
                    try Self.writeTurn(db: db, chatHistoryId: e.chatHistoryId, sessionId: e.sessionId, role: e.role, dateMs: e.dateMs, text: e.text)
                }
            }
            print("[MemoryIndex] indexTurns WRITE count=\(entries.count)")
        } catch {
            print("[MemoryIndex] indexTurns(count=\(entries.count)) failed: \(error)")
        }
    }

    /// Single-turn write inside a GRDB write transaction. Idempotent:
    /// on existing `chatHistoryId` → bump epoch, delete prior fts/meta/vec,
    /// insert fresh fts/meta with `embeddingComplete = 0`.
    ///
    /// `nonisolated static` so it runs on the caller's (GRDB write-queue's)
    /// executor without hopping isolation — required because Swift 6 forbids
    /// `self.method(...)` calls from inside a `@Sendable` write closure.
    private nonisolated static func writeTurn(
        db: Database,
        chatHistoryId: String,
        sessionId: String?,
        role: String,
        dateMs: Int64,
        text: String
    ) throws {
        var nextEpoch: Int64 = 1
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT rowid, indexEpoch FROM memory_meta WHERE chatHistoryId = ?",
            arguments: [chatHistoryId]
        ) {
            let oldRowid: Int64 = row["rowid"]
            let oldEpoch: Int64 = row["indexEpoch"]
            nextEpoch = oldEpoch &+ 1
            // DELETE vec first so no dangling vec row points at a freed rowid.
            try db.execute(sql: "DELETE FROM memory_vec WHERE rowid = ?", arguments: [oldRowid])
            try db.execute(sql: "DELETE FROM memory_meta WHERE rowid = ?", arguments: [oldRowid])
            try db.execute(sql: "DELETE FROM memory_fts WHERE rowid = ?", arguments: [oldRowid])
        }

        try db.execute(sql: "INSERT INTO memory_fts(content) VALUES (?)", arguments: [text])
        let newRowid = db.lastInsertedRowID
        try db.execute(sql: """
            INSERT INTO memory_meta(rowid, chatHistoryId, sessionId, role, dateMs, indexEpoch, embeddingComplete)
            VALUES (?, ?, ?, ?, ?, ?, 0)
            """, arguments: [newRowid, chatHistoryId, sessionId, role, dateMs, nextEpoch])
    }

    // MARK: - Delete

    /// Idempotent delete by chatHistoryId. Called from `ChatStore.deleteTurns` /
    /// `deleteHistoryTurns` after the chatHistory delete succeeds, and from
    /// Stage A self-heal's orphan (B−A) direction.
    func deleteTurns(chatHistoryIds: [String]) {
        ensureReady()
        guard let dbPool, !chatHistoryIds.isEmpty else { return }
        do {
            var deletedCount = 0
            try dbPool.write { db in
                let placeholders = Array(repeating: "?", count: chatHistoryIds.count).joined(separator: ",")
                let rowids = try Int64.fetchAll(
                    db,
                    sql: "SELECT rowid FROM memory_meta WHERE chatHistoryId IN (\(placeholders))",
                    arguments: StatementArguments(chatHistoryIds)
                )
                guard !rowids.isEmpty else { return }
                deletedCount = rowids.count
                let rowidPlaceholders = Array(repeating: "?", count: rowids.count).joined(separator: ",")
                // Order: vec → meta → fts (matches writeTurn's DELETE order on reindex).
                try db.execute(sql: "DELETE FROM memory_vec WHERE rowid IN (\(rowidPlaceholders))", arguments: StatementArguments(rowids))
                try db.execute(sql: "DELETE FROM memory_meta WHERE rowid IN (\(rowidPlaceholders))", arguments: StatementArguments(rowids))
                try db.execute(sql: "DELETE FROM memory_fts WHERE rowid IN (\(rowidPlaceholders))", arguments: StatementArguments(rowids))
            }
            print("[MemoryIndex] deleteTurns requested=\(chatHistoryIds.count) deleted=\(deletedCount)")
        } catch {
            print("[MemoryIndex] deleteTurns failed: \(error)")
        }
    }

    /// Wipe everything — called by `ChatStore.clearAll`. Users expect "Clear
    /// History" to remove memory as well; otherwise `memory_search` keeps
    /// surfacing cleared content, which is a privacy regression.
    func deleteAll() {
        ensureReady()
        guard let dbPool else { return }
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM memory_vec")
                try db.execute(sql: "DELETE FROM memory_meta")
                try db.execute(sql: "DELETE FROM memory_fts")
            }
            print("[MemoryIndex] Cleared all memory turns")
        } catch {
            print("[MemoryIndex] deleteAll failed: \(error)")
        }
    }

    /// Purge memory rows whose `sessionId` starts with the given prefix.
    /// Demo Mode uses session IDs prefixed `"demo:"` so this scopes the wipe
    /// to demo content only — production memory survives.
    func purgeForSessionPrefix(_ prefix: String) {
        ensureReady()
        guard let dbPool else { return }
        do {
            try dbPool.write { db in
                let pattern = "\(prefix)%"
                let rowids = try Int64.fetchAll(
                    db,
                    sql: "SELECT rowid FROM memory_meta WHERE sessionId LIKE ?",
                    arguments: [pattern]
                )
                for rowid in rowids {
                    try? db.execute(sql: "DELETE FROM memory_vec WHERE rowid = ?", arguments: [rowid])
                    try? db.execute(sql: "DELETE FROM memory_fts WHERE rowid = ?", arguments: [rowid])
                }
                try db.execute(
                    sql: "DELETE FROM memory_meta WHERE sessionId LIKE ?",
                    arguments: [pattern]
                )
            }
            print("[MemoryIndex] purgeForSessionPrefix(\(prefix)) done")
        } catch {
            print("[MemoryIndex] purgeForSessionPrefix failed: \(error)")
        }
    }

    // MARK: - Self-heal introspection

    /// All chatHistory IDs known to memory.db. Used by Stage A self-heal's
    /// set-diff (both directions: A−B for missing, B−A for orphan).
    func knownChatHistoryIds() -> Set<String> {
        ensureReady()
        guard let dbPool else { return [] }
        do {
            let ids = try dbPool.read { db in
                try String.fetchAll(db, sql: "SELECT chatHistoryId FROM memory_meta")
            }
            print("[MemoryIndex] knownChatHistoryIds returning \(ids.count) ids")
            return Set(ids)
        } catch {
            print("[MemoryIndex] knownChatHistoryIds failed: \(error)")
            return []
        }
    }

    // MARK: - Queue-facing helpers

    /// Queue's `repopulateFromDatabase` probe. Uses partial index
    /// `idx_memory_meta_embeddingComplete` (WHERE embeddingComplete = 0) —
    /// O(pending), not O(corpus).
    func pendingEmbeddingChatHistoryIds(limit: Int) -> [String] {
        ensureReady()
        guard let dbPool else { return [] }
        do {
            let ids = try dbPool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT chatHistoryId FROM memory_meta
                    WHERE embeddingComplete = 0
                    ORDER BY dateMs DESC
                    LIMIT ?
                    """, arguments: [limit])
            }
            let preview = ids.prefix(5).map { $0.prefix(20) }.joined(separator: ",")
            print("[MemoryIndex] pendingEmbeddingChatHistoryIds(limit=\(limit)) returning \(ids.count) ids [\(preview)\(ids.count > 5 ? ",..." : "")]")
            return ids
        } catch {
            print("[MemoryIndex] pendingEmbeddingChatHistoryIds failed: \(error)")
            return []
        }
    }

    /// Bulk read of FTS content + rowid + indexEpoch for the embedding queue's
    /// `processBatch`. One JOIN against `chatHistoryId` unique index — no scan.
    func ftsContentWithEpochs(chatHistoryIds: [String]) -> [String: (rowid: Int64, indexEpoch: Int64, content: String)] {
        ensureReady()
        guard let dbPool, !chatHistoryIds.isEmpty else { return [:] }
        do {
            let result = try dbPool.read { db -> [String: (rowid: Int64, indexEpoch: Int64, content: String)] in
                let placeholders = Array(repeating: "?", count: chatHistoryIds.count).joined(separator: ",")
                let sql = """
                    SELECT meta.chatHistoryId, meta.rowid, meta.indexEpoch, fts.content
                    FROM memory_fts fts
                    JOIN memory_meta meta ON fts.rowid = meta.rowid
                    WHERE meta.chatHistoryId IN (\(placeholders))
                    """
                var out: [String: (rowid: Int64, indexEpoch: Int64, content: String)] = [:]
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(chatHistoryIds))
                for row in rows {
                    guard let cid = row["chatHistoryId"] as String? else { continue }
                    let rid: Int64 = row["rowid"]
                    let epoch: Int64 = row["indexEpoch"]
                    let content: String = row["content"]
                    out[cid] = (rowid: rid, indexEpoch: epoch, content: content)
                }
                return out
            }
            let missing = chatHistoryIds.filter { result[$0] == nil }.count
            print("[MemoryIndex] ftsContentWithEpochs requested=\(chatHistoryIds.count) returned=\(result.count) missing=\(missing)")
            return result
        } catch {
            print("[MemoryIndex] ftsContentWithEpochs failed: \(error)")
            return [:]
        }
    }

    /// Bulk store embeddings with epoch-stamp race check. For each pair:
    /// - Re-read current (rowid, indexEpoch) from memory_meta by chatHistoryId.
    /// - If current epoch != observedEpoch → turn was re-indexed mid-flight;
    ///   skip the write and return the id in `skippedRace`.
    /// - Else DELETE stale vec, INSERT new vec, UPDATE embeddingComplete = 1.
    /// Returns (committed, skippedRace). Queue marks skippedRace items
    /// shouldRetry:true so the next drain picks up fresh content.
    func storeEmbeddings(_ pairs: [(chatHistoryId: String, observedEpoch: Int64, embedding: [Float])]) -> (committed: [String], skippedRace: [String]) {
        ensureReady()
        guard let dbPool, !pairs.isEmpty else { return ([], []) }
        var committed: [String] = []
        var skippedRace: [String] = []
        var missing: [String] = []
        do {
            try dbPool.write { db in
                for pair in pairs {
                    guard let row = try Row.fetchOne(
                        db,
                        sql: "SELECT rowid, indexEpoch FROM memory_meta WHERE chatHistoryId = ?",
                        arguments: [pair.chatHistoryId]
                    ) else {
                        missing.append(pair.chatHistoryId)
                        continue
                    }
                    let currentRowid: Int64 = row["rowid"]
                    let currentEpoch: Int64 = row["indexEpoch"]
                    if currentEpoch != pair.observedEpoch {
                        skippedRace.append(pair.chatHistoryId)
                        continue
                    }
                    let blob = pair.embedding.withUnsafeBytes { Data($0) }
                    try db.execute(sql: "DELETE FROM memory_vec WHERE rowid = ?", arguments: [currentRowid])
                    try db.execute(
                        sql: "INSERT INTO memory_vec(rowid, embedding) VALUES (?, ?)",
                        arguments: [currentRowid, blob]
                    )
                    try db.execute(
                        sql: "UPDATE memory_meta SET embeddingComplete = 1 WHERE rowid = ?",
                        arguments: [currentRowid]
                    )
                    committed.append(pair.chatHistoryId)
                }
            }
            print("[MemoryIndex] storeEmbeddings pairs=\(pairs.count) committed=\(committed.count) skippedRace=\(skippedRace.count) missing=\(missing.count)")
        } catch {
            print("[MemoryIndex] storeEmbeddings failed: \(error)")
        }
        return (committed, skippedRace)
    }

    // MARK: - Listing (ChatHistoryView default view)

    /// Reverse-chronological listing used by the ChatHistoryView default view.
    /// Returns per-turn rows with empty `snippet` (the UI uses `content`
    /// directly when no search is active). Caller groups by `sessionId` for
    /// rendering.
    func listTurns(limit: Int) -> [MemoryHit] {
        ensureReady()
        guard let dbPool else { return [] }
        do {
            return try dbPool.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT meta.chatHistoryId, meta.sessionId, meta.role, meta.dateMs, fts.content
                    FROM memory_meta meta
                    JOIN memory_fts fts ON fts.rowid = meta.rowid
                    ORDER BY meta.dateMs DESC
                    LIMIT ?
                    """, arguments: [limit])
                return rows.map { row in
                    MemoryHit(
                        chatHistoryId: row["chatHistoryId"],
                        sessionId: row["sessionId"] as String?,
                        role: row["role"],
                        dateMs: row["dateMs"],
                        content: row["content"],
                        snippet: "",
                        textScore: 0,
                        vectorScore: 0,
                        finalScore: 0
                    )
                }
            }
        } catch {
            print("[MemoryIndex] listTurns failed: \(error)")
            return []
        }
    }

    // MARK: - Search (hybrid FTS + vec, per-turn)

    /// Hybrid memory search with FTS5 + sqlite-vec, returning per-turn hits.
    /// Each `MemoryHit` corresponds to a single chatHistory turn. A session
    /// with three matching turns produces three independently-ranked hits.
    ///
    /// - `fromMs` / `toMs`: optional dateMs window.
    /// - `limit`: post-merge cap; per-leg candidate expansion = limit × SearchConfig.candidateMultiplier.
    func search(query: String, fromMs: Int64? = nil, toMs: Int64? = nil, limit: Int) -> [MemoryHit] {
        ensureReady()
        guard let dbPool else { return [] }
        let candidateLimit = limit * SearchConfig.candidateMultiplier
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // FTS5 candidates — ORDER BY rank ASC, meta.dateMs DESC.
        var ftsCandidates: [(rowid: Int64, rank: Double, snippet: String, content: String, chatHistoryId: String, sessionId: String?, role: String, dateMs: Int64)] = []
        do {
            ftsCandidates = try dbPool.read { db in
                var sql = """
                    SELECT fts.rowid, fts.content, meta.chatHistoryId, meta.sessionId, meta.role, meta.dateMs,
                           snippet(memory_fts, 0, '[', ']', '…', \(SearchConfig.snippetTokens)) AS snippet,
                           bm25(memory_fts) AS rank
                    FROM memory_fts fts
                    JOIN memory_meta meta ON fts.rowid = meta.rowid
                    WHERE memory_fts MATCH ?
                    """
                var args: [DatabaseValueConvertible?] = [ftsQuery(trimmed)]
                if let fromMs {
                    sql += " AND meta.dateMs >= ?"
                    args.append(fromMs)
                }
                if let toMs {
                    sql += " AND meta.dateMs <= ?"
                    args.append(toMs)
                }
                sql += " ORDER BY rank ASC, meta.dateMs DESC LIMIT ?"
                args.append(candidateLimit)

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                return rows.map { row in
                    (
                        rowid: row["rowid"],
                        rank: (row["rank"] as Double?) ?? 0.0,
                        snippet: (row["snippet"] as String?) ?? "",
                        content: (row["content"] as String?) ?? "",
                        chatHistoryId: (row["chatHistoryId"] as String?) ?? "",
                        sessionId: row["sessionId"] as String?,
                        role: (row["role"] as String?) ?? "",
                        dateMs: (row["dateMs"] as Int64?) ?? 0
                    )
                }
            }
        } catch {
            print("[MemoryIndex] FTS candidate fetch failed: \(error)")
        }

        // Vector candidates — query EmbeddingService for query vector; graceful-empty on any failure.
        var vecCandidates: [(Int64, Double)] = []
        if let embedService = EmbeddingService.shared {
            do {
                let qVec = try embedService.embed(trimmed)
                vecCandidates = searchVecCandidates(queryEmbedding: qVec, limit: candidateLimit)
            } catch {
                print("[MemoryIndex] Query embedding failed: \(error)")
            }
        }

        let ftsMatchArg = ftsQuery(trimmed)
        // Snapshot current table sizes for diagnostics.
        var vecTableSize = -1
        var metaTableSize = -1
        _ = try? dbPool.read { db in
            vecTableSize = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_vec") ?? -1
            metaTableSize = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_meta") ?? -1
        }
        print("[MemoryIndex] search q='\(trimmed.prefix(60))' ftsMatchArg=\(ftsMatchArg) ftsCands=\(ftsCandidates.count) vecCands=\(vecCandidates.count) vecTableSize=\(vecTableSize) metaTableSize=\(metaTableSize) fromMs=\(fromMs.map(String.init) ?? "nil") toMs=\(toMs.map(String.init) ?? "nil") limit=\(limit) candLimit=\(candidateLimit) embedSvc=\(EmbeddingService.shared != nil)")

        // Both-legs-empty short-circuit.
        if ftsCandidates.isEmpty && vecCandidates.isEmpty {
            print("[MemoryIndex] search RESULT 0 hits (both legs empty)")
            return []
        }

        // FTS-only fallback when vec table is empty (steady state during initial
        // backfill, or when EmbeddingService is unavailable).
        if vecCandidates.isEmpty {
            let hits = assembleFTSOnly(Array(ftsCandidates.prefix(limit)))
            print("[MemoryIndex] search RESULT \(hits.count) hits (FTS-only fallback)")
            return hits
        }

        // Merge via HybridMerge with memory weights.
        let textPairs: [(Int64, Double)] = ftsCandidates.map { ($0.rowid, $0.rank) }
        let merged = HybridMerge.mergeResults(
            textResults: textPairs,
            vectorResults: vecCandidates,
            vectorWeight: SearchConfig.memoryVectorWeight,
            textWeight: SearchConfig.memoryTextWeight,
            limit: limit
        )
        print("[MemoryIndex] search merged=\(merged.count) (hybrid via HybridMerge)")

        // Assemble results. FTS hits carry full payload already; vec-only hits need
        // a batched JOIN lookup on rowid.
        var ftsMap: [Int64: (content: String, chatHistoryId: String, sessionId: String?, role: String, dateMs: Int64, snippet: String)] = [:]
        for c in ftsCandidates {
            ftsMap[c.rowid] = (c.content, c.chatHistoryId, c.sessionId, c.role, c.dateMs, c.snippet)
        }

        var vecOnlyRowids: [Int64] = []
        for r in merged where ftsMap[r.rowid] == nil {
            vecOnlyRowids.append(r.rowid)
        }
        let vecOnlyMap = vecOnlyRowids.isEmpty ? [:] : fetchMetaForRowids(vecOnlyRowids)

        var results: [MemoryHit] = []
        for r in merged {
            if let fts = ftsMap[r.rowid] {
                results.append(MemoryHit(
                    chatHistoryId: fts.chatHistoryId,
                    sessionId: fts.sessionId,
                    role: fts.role,
                    dateMs: fts.dateMs,
                    content: fts.content,
                    snippet: fts.snippet,
                    textScore: r.textScore,
                    vectorScore: r.vectorScore,
                    finalScore: r.finalScore
                ))
            } else if let meta = vecOnlyMap[r.rowid] {
                if let fromMs, meta.dateMs < fromMs { continue }
                if let toMs, meta.dateMs > toMs { continue }
                results.append(MemoryHit(
                    chatHistoryId: meta.chatHistoryId,
                    sessionId: meta.sessionId,
                    role: meta.role,
                    dateMs: meta.dateMs,
                    content: meta.content,
                    snippet: "",
                    textScore: r.textScore,
                    vectorScore: r.vectorScore,
                    finalScore: r.finalScore
                ))
            }
        }
        let ftsOnlyCount = results.filter { $0.vectorScore == 0 }.count
        let vecOnlyCount = results.filter { $0.textScore == 0 }.count
        let bothCount = results.count - ftsOnlyCount - vecOnlyCount
        print("[MemoryIndex] search RESULT \(results.count) hits (fts-only=\(ftsOnlyCount) vec-only=\(vecOnlyCount) both=\(bothCount))")
        return results
    }

    private func assembleFTSOnly(_ cands: [(rowid: Int64, rank: Double, snippet: String, content: String, chatHistoryId: String, sessionId: String?, role: String, dateMs: Int64)]) -> [MemoryHit] {
        cands.map { c in
            let textScore = HybridMerge.bm25RankToScore(c.rank)
            let finalScore = SearchConfig.memoryTextWeight * textScore
            return MemoryHit(
                chatHistoryId: c.chatHistoryId,
                sessionId: c.sessionId,
                role: c.role,
                dateMs: c.dateMs,
                content: c.content,
                snippet: c.snippet,
                textScore: textScore,
                vectorScore: 0,
                finalScore: finalScore
            )
        }
    }

    /// Batched lookup of `(content, chatHistoryId, sessionId, role, dateMs)` for vec-only hits.
    private func fetchMetaForRowids(_ rowids: [Int64]) -> [Int64: (content: String, chatHistoryId: String, sessionId: String?, role: String, dateMs: Int64)] {
        guard let dbPool, !rowids.isEmpty else { return [:] }
        do {
            return try dbPool.read { db in
                let placeholders = Array(repeating: "?", count: rowids.count).joined(separator: ",")
                let sql = """
                    SELECT fts.rowid, fts.content, meta.chatHistoryId, meta.sessionId, meta.role, meta.dateMs
                    FROM memory_fts fts
                    JOIN memory_meta meta ON fts.rowid = meta.rowid
                    WHERE fts.rowid IN (\(placeholders))
                    """
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(rowids))
                var out: [Int64: (content: String, chatHistoryId: String, sessionId: String?, role: String, dateMs: Int64)] = [:]
                for row in rows {
                    let rid: Int64 = row["rowid"]
                    out[rid] = (
                        content: (row["content"] as String?) ?? "",
                        chatHistoryId: (row["chatHistoryId"] as String?) ?? "",
                        sessionId: row["sessionId"] as String?,
                        role: (row["role"] as String?) ?? "",
                        dateMs: (row["dateMs"] as Int64?) ?? 0
                    )
                }
                return out
            }
        } catch {
            print("[MemoryIndex] fetchMetaForRowids failed: \(error)")
            return [:]
        }
    }

    /// Vector KNN query. Uses writer connection to avoid sqlite-vec vtab lifecycle issues
    /// (matches `SearchIndex.searchVecCandidates`).
    private func searchVecCandidates(queryEmbedding: [Float], limit: Int) -> [(Int64, Double)] {
        guard let dbPool else { return [] }
        let blob = queryEmbedding.withUnsafeBytes { Data($0) }
        do {
            let (pairs, distances) = try dbPool.writeWithoutTransaction { db -> ([(Int64, Double)], [Double]) in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT rowid, distance FROM memory_vec WHERE embedding MATCH ? AND k = ?
                    """, arguments: [blob, limit])
                var pairs: [(Int64, Double)] = []
                var ds: [Double] = []
                for row in rows {
                    guard let rowid = row["rowid"] as Int64?,
                          let distance = row["distance"] as Double? else { continue }
                    pairs.append((rowid, distance))
                    ds.append(distance)
                }
                return (pairs, ds)
            }
            let minD = distances.min().map { String(format: "%.3f", $0) } ?? "nil"
            let maxD = distances.max().map { String(format: "%.3f", $0) } ?? "nil"
            print("[MemoryIndex] searchVecCandidates k=\(limit) returned=\(pairs.count) distRange=[\(minD)…\(maxD)]")
            return pairs
        } catch {
            print("[MemoryIndex] Vec search failed: \(error)")
            return []
        }
    }

    /// Normalize user query for FTS5 MATCH.
    ///
    /// Split the input into alphanumeric tokens, lowercase, append `*` for prefix
    /// matching against the `prefix='2 3 4'` index. Joined by spaces (implicit AND).
    /// Phrase quotes `"token"` DO NOT consult the prefix index — confirmed against
    /// `logmain.log` 2026-04-22 where `"mel"`→0 but `mel*`→hits.
    private func ftsQuery(_ query: String) -> String {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "\"\"" }
        return tokens.map { "\($0)*" }.joined(separator: " ")
    }

    // MARK: - Read (TB-parity: session-bounded context window)

    /// Return a contiguous window of turns centered on the turn whose `dateMs`
    /// is closest to `timestampMs` within `± toleranceMs`. If the matched turn
    /// has a non-nil `sessionId`, the window is bounded to that session (using
    /// `idx_memory_meta_session_date`). If the matched turn has NULL
    /// `sessionId` (legacy pre-v11 rows), fall back to a pure time-window walk
    /// bounded by tolerance.
    ///
    /// Returns empty `[]` when no turn is within tolerance — the caller
    /// (`MemoryReadTool`) converts this to the TB-parity literal string.
    func readByTimestamp(timestampMs: Int64, toleranceMs: Int64, maxTurns: Int) -> [MemoryHit] {
        ensureReady()
        guard let dbPool else { return [] }
        let lowerBound = timestampMs - toleranceMs
        let upperBound = timestampMs + toleranceMs
        print("[MemoryIndex] readByTimestamp target=\(timestampMs) tolMs=\(toleranceMs) maxTurns=\(maxTurns) window=[\(lowerBound), \(upperBound)]")

        do {
            return try dbPool.read { db in
                // Step 1: find the matched turn (closest dateMs to target within tolerance).
                // ORDER BY abs(dateMs - target) isn't SQLite-natural; use two ranked queries
                // (<= target and >= target) and pick the closer one.
                let beforeRow = try Row.fetchOne(db, sql: """
                    SELECT rowid, chatHistoryId, sessionId, role, dateMs
                    FROM memory_meta
                    WHERE dateMs >= ? AND dateMs <= ?
                    ORDER BY dateMs DESC LIMIT 1
                    """, arguments: [lowerBound, timestampMs])
                let afterRow = try Row.fetchOne(db, sql: """
                    SELECT rowid, chatHistoryId, sessionId, role, dateMs
                    FROM memory_meta
                    WHERE dateMs > ? AND dateMs <= ?
                    ORDER BY dateMs ASC LIMIT 1
                    """, arguments: [timestampMs, upperBound])

                let matched: Row?
                switch (beforeRow, afterRow) {
                case (let b?, let a?):
                    let bd: Int64 = b["dateMs"]
                    let ad: Int64 = a["dateMs"]
                    matched = abs(bd - timestampMs) <= abs(ad - timestampMs) ? b : a
                case (let b?, nil):
                    matched = b
                case (nil, let a?):
                    matched = a
                default:
                    matched = nil
                }

                guard let matched else {
                    print("[MemoryIndex] readByTimestamp MATCH none (empty window)")
                    return []
                }

                let matchedSid = matched["sessionId"] as String?
                let matchedDate: Int64 = matched["dateMs"]

                // Step 2: window fetch.
                let windowRows: [Row]
                if let sid = matchedSid {
                    // Session-bounded: fetch up to maxTurns/2 before + maxTurns/2 after within the session.
                    let half = maxTurns / 2
                    let beforeTurns = try Row.fetchAll(db, sql: """
                        SELECT meta.chatHistoryId, meta.sessionId, meta.role, meta.dateMs, fts.content
                        FROM memory_meta meta
                        JOIN memory_fts fts ON fts.rowid = meta.rowid
                        WHERE meta.sessionId = ? AND meta.dateMs <= ?
                        ORDER BY meta.dateMs DESC LIMIT ?
                        """, arguments: [sid, matchedDate, half + 1])   // +1 to include matched turn
                    let afterTurns = try Row.fetchAll(db, sql: """
                        SELECT meta.chatHistoryId, meta.sessionId, meta.role, meta.dateMs, fts.content
                        FROM memory_meta meta
                        JOIN memory_fts fts ON fts.rowid = meta.rowid
                        WHERE meta.sessionId = ? AND meta.dateMs > ?
                        ORDER BY meta.dateMs ASC LIMIT ?
                        """, arguments: [sid, matchedDate, maxTurns - (beforeTurns.count)])
                    // Merge chronologically.
                    windowRows = beforeTurns.reversed() + afterTurns
                } else {
                    // NULL sessionId: fall back to pure time-window walk.
                    windowRows = try Row.fetchAll(db, sql: """
                        SELECT meta.chatHistoryId, meta.sessionId, meta.role, meta.dateMs, fts.content
                        FROM memory_meta meta
                        JOIN memory_fts fts ON fts.rowid = meta.rowid
                        WHERE meta.dateMs >= ? AND meta.dateMs <= ?
                        ORDER BY meta.dateMs ASC LIMIT ?
                        """, arguments: [lowerBound, upperBound, maxTurns])
                }

                let hits = windowRows.map { row in
                    MemoryHit(
                        chatHistoryId: row["chatHistoryId"],
                        sessionId: row["sessionId"] as String?,
                        role: row["role"],
                        dateMs: row["dateMs"],
                        content: row["content"],
                        snippet: "",
                        textScore: 0,
                        vectorScore: 0,
                        finalScore: 0
                    )
                }
                print("[MemoryIndex] readByTimestamp MATCH sid=\(matchedSid?.prefix(30) ?? "nil") matchedDate=\(matchedDate) window=\(hits.count) turns")
                return hits
            }
        } catch {
            print("[MemoryIndex] readByTimestamp failed: \(error)")
            return []
        }
    }
}

// MARK: - Test hooks
//
// Some test scenarios need to inject a pool against an in-memory database or a tmp
// path. Exposed as internal-visibility methods so unit tests can override without
// going through the main `initialize` path. NEVER call from production code.
extension MemoryIndex {
    /// Replace the internal pool with a test-provided one and run schema creation
    /// against it. After this call, `ensureReady` is a no-op. Tests should supply
    /// a pool configured with `tabmail_register_sqlite_vec_on_db` in prepareDatabase.
    func _testInstallPool(_ pool: DatabasePool) async throws {
        dbPool = pool
        try createSchema()
        _ = try await pool.write { db in
            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
        }
        isInitialized = true
    }

    /// Test-only: install pool AND run the v3 schema-version gate. Mirrors what
    /// production `initialize()` does (version check → drop stale tables → create
    /// v3 schema → stamp user_version). Use when the test seeds a pre-v3 schema
    /// on the pool and needs to verify the drop-and-rebuild works.
    func _testInstallPoolWithGate(_ pool: DatabasePool) async throws {
        dbPool = pool
        _ = try await pool.write { db in
            let currentVersion: Int32 = try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if currentVersion < Self.schemaVersion {
                try db.execute(sql: "DROP TABLE IF EXISTS memory_vec")
                try db.execute(sql: "DROP TABLE IF EXISTS memory_meta")
                try db.execute(sql: "DROP TABLE IF EXISTS memory_fts")
            }
        }
        try createSchema()
        _ = try await pool.write { db in
            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
        }
        isInitialized = true
    }

    /// Reset to uninitialized state for teardown between tests.
    func _testReset() async {
        dbPool = nil
        isInitialized = false
    }

    /// Test introspection: row count in memory_meta.
    func _testMetaRowCount() -> Int {
        guard let dbPool else { return 0 }
        return (try? dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_meta") ?? 0
        }) ?? 0
    }

    /// Test introspection: row count in memory_vec.
    func _testVecRowCount() -> Int {
        guard let dbPool else { return 0 }
        return (try? dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_vec") ?? 0
        }) ?? 0
    }

    /// Test introspection: pull a snapshot of a memory_meta row by chatHistoryId.
    func _testMetaRow(chatHistoryId: String) -> (rowid: Int64, chatHistoryId: String, sessionId: String?, role: String, dateMs: Int64, indexEpoch: Int64, embeddingComplete: Int64)? {
        guard let dbPool else { return nil }
        return try? dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT rowid, chatHistoryId, sessionId, role, dateMs, indexEpoch, embeddingComplete FROM memory_meta WHERE chatHistoryId = ?",
                arguments: [chatHistoryId]
            ) else { return nil }
            return (
                rowid: row["rowid"],
                chatHistoryId: row["chatHistoryId"],
                sessionId: row["sessionId"] as String?,
                role: row["role"],
                dateMs: row["dateMs"],
                indexEpoch: row["indexEpoch"],
                embeddingComplete: row["embeddingComplete"]
            )
        }
    }

    /// Test helper: fetch the FTS content for a chatHistoryId.
    func _testFTSContent(chatHistoryId: String) -> String? {
        guard let dbPool else { return nil }
        return try? dbPool.read { db in
            try String.fetchOne(db, sql: """
                SELECT fts.content FROM memory_fts fts
                JOIN memory_meta meta ON fts.rowid = meta.rowid
                WHERE meta.chatHistoryId = ?
                """, arguments: [chatHistoryId])
        }
    }

    /// Test helper: the schema version actually set on the memory.db file.
    func _testSchemaVersion() -> Int32 {
        guard let dbPool else { return -1 }
        return (try? dbPool.read { db in
            try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? -1
        }) ?? -1
    }
}
