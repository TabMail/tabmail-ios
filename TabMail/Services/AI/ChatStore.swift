/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - ChatTurn Model (Sessions — resumable)

/// A single turn in a resumable chat session.
/// Contains raw `[Email](N)` references that require ChatIdTranslator mappings.
/// Evicted aggressively by session eviction logic.
struct ChatTurn: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "chatTurn"

    let id: String          // unique turn ID (timestamp-random, like TB's generateTurnId)
    let timestamp: Double   // epoch milliseconds (_ts in TB)
    let role: String        // "user" or "assistant"
    let content: String     // for user: "chat_converse" (template name); for assistant: actual response text
    let userMessage: String? // for user turns: the raw user text
    let type: String        // "normal", "greeting", "welcome_back", "session_break"
    let chars: Int          // character count for budget enforcement
    let renderedContent: String? // v7: pre-processed text with resolved pills (for history rendering)
    let sessionId: String?       // v11: groups turns into sessions for pill swipe navigation (nil for legacy)
    let remindersSnapshot: String? // v20: JSON array of reminders shown when session started (first turn only)
    let emailContextJSON: String?  // v22: JSON with email context for message-detail sessions (first turn only)
    let thinkingContent: String?   // v29: extended thinking / reasoning content from the LLM

    /// Generate a unique turn ID matching TB's `generateTurnId()`.
    static func generateId() -> String {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let random = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        return "\(ts)-\(random)"
    }
}

// MARK: - ChatHistoryTurn Model (Memory — searchable, never resumable)

/// Dereferenced copy of a chat turn, stored in parallel to ChatTurn.
/// Content always has resolved subjects (no `[Email](N)` patterns).
/// Searched by MemorySearchTool, displayed in ChatHistoryView.
/// Evicted only by the global turn cap ("Memory" setting).
struct ChatHistoryTurn: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "chatHistory"

    let id: String          // same ID as corresponding ChatTurn
    let timestamp: Double
    let role: String
    let content: String     // always dereferenced — subjects baked in
    let userMessage: String?
    let sessionId: String?
    let chars: Int
    let type: String        // v52: "normal" | "greeting" | "welcome_back" | "session_break" — enables memory search filter parity with KBRefinementService
}

// MARK: - ChatStore

/// Persistent chat turn storage, matching TB's persistentChatStore.js.
/// Device-local only — NOT synced via Device Sync (per design: chat history stays per-device).
actor ChatStore {
    static let shared = ChatStore()

    /// Budget constants (matching TB)
    private static let maxExchanges = 50
    private static let charsPerExchange = 500

    // MARK: - Load

    /// Load all history turns ordered by timestamp (for ChatHistoryView).
    func loadAllHistoryTurns() throws -> [ChatHistoryTurn] {
        try AppDatabase.dbPool.read { db in
            try ChatHistoryTurn.order(Column("timestamp").asc).fetchAll(db)
        }
    }

    /// Load every turn for a session in timestamp-ascending order. Uses the
    /// `chatHistory_sessionId` index. Kept as a debug / raw-access helper —
    /// v3 memory self-heal operates per-turn via `loadHistoryTurns(ids:)`.
    func loadHistoryTurns(forSessionId sid: String) throws -> [ChatHistoryTurn] {
        try AppDatabase.dbPool.read { db in
            try ChatHistoryTurn
                .filter(Column("sessionId") == sid)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    /// All chatHistory turn IDs eligible for memory indexing (self-heal Stage A
    /// A−B direction). Returns the set of `chatHistory.id` rows that:
    /// - are older than `cutoffMs` (protects in-progress sessions),
    /// - have `type = 'normal'` (filter out greetings / welcome_back / session_break),
    /// - have `role IN ('user', 'assistant')`.
    ///
    /// Scope-agnostic: includes inbox, `msg:%`, and `compose:%` sessions.
    /// Bounded by the chatHistory turn cap (default 5000).
    ///
    /// See ADR-IOS-034.
    func historyTurnIdsForSelfHeal(olderThan cutoffMs: Int64) throws -> Set<String> {
        try AppDatabase.dbPool.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM chatHistory
                WHERE timestamp < ?
                  AND type = 'normal'
                  AND role IN ('user', 'assistant')
                """, arguments: [Double(cutoffMs)])
            // Scope breakdown for diagnosis.
            let scopeRows = try Row.fetchAll(db, sql: """
                SELECT CASE
                    WHEN sessionId LIKE 'msg:%' THEN 'msg'
                    WHEN sessionId LIKE 'compose:%' THEN 'compose'
                    WHEN sessionId IS NULL THEN 'null'
                    ELSE 'inbox'
                END AS scope, COUNT(*) AS n
                FROM chatHistory
                WHERE timestamp < ? AND type = 'normal' AND role IN ('user', 'assistant')
                GROUP BY scope
                """, arguments: [Double(cutoffMs)])
            let scopeBreakdown = scopeRows.map { (($0["scope"] as String?) ?? "?", ($0["n"] as Int?) ?? 0) }
            print("[ChatStore] historyTurnIdsForSelfHeal(olderThan=\(cutoffMs)) eligible=\(ids.count) scopeBreakdown=\(scopeBreakdown)")
            return Set(ids)
        }
    }

    /// All chatHistory turn IDs, regardless of age / type / role. Used by Stage A's
    /// orphan-prune direction (B−A): a memory.db row whose chatHistoryId is not in
    /// this set is an orphan. This set must include ALL chatHistory rows, not just
    /// the self-heal-eligible subset — otherwise we'd prune memory.db rows for
    /// still-active sessions.
    /// See ADR-IOS-034.
    func allHistoryTurnIds() throws -> Set<String> {
        try AppDatabase.dbPool.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM chatHistory")
            return Set(ids)
        }
    }

    /// Bulk load chatHistory turns by ID. Used by Stage A to materialize the
    /// A−B set-diff result before calling `MemoryIndex.indexTurns`.
    func loadHistoryTurns(ids: [String]) throws -> [ChatHistoryTurn] {
        guard !ids.isEmpty else { return [] }
        return try AppDatabase.dbPool.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            return try ChatHistoryTurn.fetchAll(
                db,
                sql: "SELECT * FROM chatHistory WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
        }
    }

    // MARK: - Append + Budget

    /// Append a turn and enforce budget. Returns evicted turns (for ID translator cleanup).
    /// Also writes a dereferenced copy to chatHistory (parallel memory store).
    ///
    /// After the GRDB write commits, forwards the new history turn to
    /// `MemoryIndex.indexTurn` + enqueues embedding. If the memory.db write
    /// fails or the process is killed between the two, Stage A self-heal
    /// catches up on next launch (A−B direction). See ADR-IOS-034.
    @discardableResult
    func appendTurn(_ turn: ChatTurn) async throws -> [ChatTurn] {
        let (evictedTurns, historyTurn) = try await AppDatabase.dbPool.write { db -> ([ChatTurn], ChatHistoryTurn) in
            try turn.insert(db)

            // Parallel write to chatHistory — always dereferenced content.
            // renderedContent has resolved subjects; content has raw [Email](N).
            let historyTurn = ChatHistoryTurn(
                id: turn.id,
                timestamp: turn.timestamp,
                role: turn.role,
                content: turn.renderedContent ?? turn.content,
                userMessage: turn.role == "user" ? (turn.renderedContent ?? turn.userMessage) : nil,
                sessionId: turn.sessionId,
                chars: turn.chars,
                type: turn.type
            )
            try historyTurn.save(db) // save = INSERT OR REPLACE (updates if session gets more turns)

            var evictedTurns: [ChatTurn] = []

            // Enforce turn count budget
            let totalTurns = try ChatTurn.fetchCount(db)
            let maxMessages = Self.maxExchanges * 2
            if totalTurns > maxMessages {
                // Delete oldest turns beyond budget (FIFO)
                let excess = totalTurns - maxMessages
                let oldest = try ChatTurn
                    .order(Column("timestamp").asc)
                    .limit(excess)
                    .fetchAll(db)
                for old in oldest {
                    try old.delete(db)
                    evictedTurns.append(old)
                }
            }

            // Also enforce char budget — fetch oldest turns and evict until under budget
            var totalChars = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(chars), 0) FROM chatTurn") ?? 0
            let maxChars = Self.maxExchanges * Self.charsPerExchange
            if totalChars > maxChars {
                let oldestTurns = try ChatTurn.order(Column("timestamp").asc).fetchAll(db)
                for oldest in oldestTurns {
                    guard totalChars > maxChars else { break }
                    totalChars -= oldest.chars
                    try oldest.delete(db)
                    evictedTurns.append(oldest)
                }
            }

            if !evictedTurns.isEmpty {
                print("[ChatStore] Evicted \(evictedTurns.count) turns (budget enforcement)")
            }
            return (evictedTurns, historyTurn)
        }

        // After commit, forward to memory.db (per-turn index + embedding enqueue).
        // Non-blocking on the caller's turn write — indexTurn is cheap FTS insert;
        // embedding is queued, never synchronous.
        if let text = MemoryIndex.memoryText(for: historyTurn) {
            await MemoryIndex.shared.indexTurn(
                chatHistoryId: historyTurn.id,
                sessionId: historyTurn.sessionId,
                role: historyTurn.role,
                dateMs: Int64(historyTurn.timestamp),
                text: text
            )
            await BackfillMemoryEmbeddingQueue.shared.enqueue(chatHistoryId: historyTurn.id)
        }

        return evictedTurns
    }

    // MARK: - Clear

    /// Delete all chat sessions and history.
    func clearAll() async throws {
        _ = try await AppDatabase.dbPool.write { db in
            try ChatTurn.deleteAll(db)
            try ChatHistoryTurn.deleteAll(db)
        }
        // Also wipe memory.db — otherwise `memory_search` keeps surfacing
        // "cleared" conversations. See ADR-IOS-034.
        await MemoryIndex.shared.deleteAll()
        print("[ChatStore] Cleared all chat history")
    }

    // MARK: - Delete Specific Turns

    /// Delete session turns by their IDs (for re-send/fork in DynamicIslandChat).
    /// Also deletes from chatHistory to avoid orphaned entries.
    /// Memory.db rows are evicted per-turn by `chatHistoryId`.
    func deleteTurns(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await AppDatabase.dbPool.write { db in
            try ChatTurn.filter(ids.contains(Column("id"))).deleteAll(db)
            try ChatHistoryTurn.filter(ids.contains(Column("id"))).deleteAll(db)
        }
        await MemoryIndex.shared.deleteTurns(chatHistoryIds: ids)
        print("[ChatStore] Deleted \(ids.count) session+history turns")
    }

    /// Delete history turns by their IDs (for swipe-to-delete in ChatHistoryView).
    /// Memory.db rows are evicted per-turn by `chatHistoryId`.
    func deleteHistoryTurns(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await AppDatabase.dbPool.write { db in
            try ChatHistoryTurn.filter(ids.contains(Column("id"))).deleteAll(db)
        }
        await MemoryIndex.shared.deleteTurns(chatHistoryIds: ids)
        print("[ChatStore] Deleted \(ids.count) history turns")
    }

    // MARK: - Convert to API Messages

    /// Convert persisted turns into CompletionsMessages for the API.
    /// System message is NOT included — caller prepends it.
    func turnsToMessages(_ turns: [ChatTurn]) -> [CompletionsMessage] {
        turns.compactMap { turn in
            switch turn.role {
            case "user":
                guard let userMessage = turn.userMessage else { return nil }
                return CompletionsMessage(
                    role: "user",
                    content: "chat_converse",
                    vars: [
                        "user_message": .string(userMessage),
                        "time_stamp": .string(AIService.formatTimestampForAgent(
                            Date(timeIntervalSince1970: turn.timestamp / 1000)
                        )),
                    ]
                )
            case "assistant":
                // Skip session_break and other structural turns
                if turn.type == "session_break" { return nil }
                var vars: [String: JSONValue] = [:]
                if let thinking = turn.thinkingContent {
                    vars["thinking"] = .string(thinking)
                }
                return CompletionsMessage(
                    role: "assistant",
                    content: turn.content,
                    vars: vars
                )
            default:
                return nil
            }
        }
    }

    // MARK: - Turn Count

    func turnCount() throws -> Int {
        try AppDatabase.dbPool.read { db in
            try ChatTurn.fetchCount(db)
        }
    }

    // MARK: - Session Loading

    /// A loaded session with its turns and metadata.
    struct ChatSession: Sendable, Identifiable {
        let id: String  // sessionId
        let turns: [ChatTurn]
        let lastActivity: Date  // max(timestamp) of turns in this session
        let remindersSnapshot: [Reminder]?  // v20: reminders shown when session started
        let emailContext: EmailContextSnapshot?  // v22: email being discussed in message-detail sessions
    }

    /// Load the last K distinct **inbox** sessions, ordered newest-last (rightmost in swipe UI).
    /// Excludes message-detail sessions (sessionId LIKE 'msg:%') and compose sessions
    /// (sessionId LIKE 'compose:%') — those are loaded separately via loadContextSession().
    func loadSessions(limit: Int) throws -> [ChatSession] {
        try AppDatabase.dbPool.read { db in
            // Get distinct sessionIds ordered by max timestamp DESC, limited to K
            // Filter out msg-detail and compose sessions (they have their own load paths)
            let sessionRows = try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId IS NOT NULL
                  AND sessionId NOT LIKE 'msg:%'
                  AND sessionId NOT LIKE 'compose:%'
                GROUP BY sessionId
                ORDER BY maxTs DESC
                LIMIT ?
            """, arguments: [limit])

            // Load turns for each session
            var sessions: [ChatSession] = []
            for row in sessionRows {
                let sid: String = row["sessionId"]
                let maxTs: Double = row["maxTs"]
                let turns = try ChatTurn
                    .filter(Column("sessionId") == sid)
                    .order(Column("timestamp").asc)
                    .fetchAll(db)
                // Decode reminder snapshot from first turn (if present)
                let reminders: [Reminder]? = turns.first?.remindersSnapshot.flatMap {
                    Self.decodeRemindersSnapshot($0)
                }
                // Decode email context from first turn (if present)
                let emailCtx: EmailContextSnapshot? = turns.first?.emailContextJSON.flatMap {
                    Self.decodeEmailContext($0)
                }
                sessions.append(ChatSession(
                    id: sid,
                    turns: turns,
                    lastActivity: Date(timeIntervalSince1970: maxTs / 1000),
                    remindersSnapshot: reminders,
                    emailContext: emailCtx
                ))
            }

            // Reverse so newest is LAST (rightmost in TabView)
            return sessions.reversed()
        }
    }

    // MARK: - Context Session Loading

    /// Load a single session by exact sessionId (for message-detail or compose contexts).
    /// Returns nil if no turns exist for this sessionId.
    func loadContextSession(sessionId: String) throws -> ChatSession? {
        try AppDatabase.dbPool.read { db in
            let turns = try ChatTurn
                .filter(Column("sessionId") == sessionId)
                .order(Column("timestamp").asc)
                .fetchAll(db)
            guard !turns.isEmpty else { return nil }
            let maxTs = turns.last?.timestamp ?? 0
            let reminders: [Reminder]? = turns.first?.remindersSnapshot.flatMap {
                Self.decodeRemindersSnapshot($0)
            }
            let emailCtx: EmailContextSnapshot? = turns.first?.emailContextJSON.flatMap {
                Self.decodeEmailContext($0)
            }
            return ChatSession(
                id: sessionId,
                turns: turns,
                lastActivity: Date(timeIntervalSince1970: maxTs / 1000),
                remindersSnapshot: reminders,
                emailContext: emailCtx
            )
        }
    }

    /// Dereference numeric IDs in a session's turns: replace raw `[Email](N)` in `content`
    /// with the resolved `renderedContent`. This ensures that once a session leaves the active
    /// state (expires, gets archived), its turns are searchable by subject/name and don't
    /// depend on ChatIdTranslator mappings that may be freed later.
    ///
    /// Only updates assistant turns where renderedContent differs from content.
    /// User turns already have `renderedContent` = raw text (without enriched prefix).
    func dereferenceSessionTurns(sessionId: String) throws {
        try AppDatabase.dbPool.write { db in
            let turns = try ChatTurn
                .filter(Column("sessionId") == sessionId)
                .fetchAll(db)
            var updated = 0
            for turn in turns {
                guard let rendered = turn.renderedContent, rendered != turn.content else { continue }
                // Replace content with dereferenced version
                try db.execute(
                    sql: "UPDATE chatTurn SET content = ? WHERE id = ?",
                    arguments: [rendered, turn.id]
                )
                updated += 1
            }
            if updated > 0 {
                print("[ChatStore] Dereferenced \(updated) turns in session \(sessionId.prefix(30))")
            }
        }
    }

    /// Delete all turns for a session (used on send to clean up compose sessions).
    func deleteSessionTurns(sessionId: String) throws {
        _ = try AppDatabase.dbPool.write { db in
            try ChatTurn.filter(Column("sessionId") == sessionId).deleteAll(db)
        }
        print("[ChatStore] Deleted turns for session \(sessionId)")
    }

    // MARK: - StableId Helpers

    /// Extract the stableId component from a msg-detail sessionId.
    /// Format: "msg:{accountId}:{stableId}" → returns "{stableId}".
    /// Returns nil if the sessionId doesn't match the expected format.
    private static func extractStableId(from sessionId: String) -> String? {
        let after = String(sessionId.dropFirst(4)) // drop "msg:"
        guard let ci = after.firstIndex(of: ":") else { return nil }
        let stableId = String(after[after.index(after: ci)...])
        return stableId.isEmpty ? nil : stableId
    }

    // MARK: - Inbox Session Eviction

    /// Evict inbox chat sessions beyond the limit (oldest first).
    /// Uses the user-configurable "Sessions" setting.
    @discardableResult
    func evictInboxSessions(limit: Int) throws -> Int {
        try Self.evictInboxSessionsImpl(dbPool: AppDatabase.dbPool, limit: limit)
    }

    nonisolated func evictInboxSessionsSync(dbPool: PrioritizedDatabase, limit: Int) throws -> Int {
        try Self.evictInboxSessionsImpl(dbPool: dbPool, limit: limit)
    }

    private static func evictInboxSessionsImpl(dbPool: PrioritizedDatabase, limit: Int) throws -> Int {
        try dbPool.write { db in
            let sessionRows = try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId IS NOT NULL
                  AND sessionId NOT LIKE 'msg:%'
                  AND sessionId NOT LIKE 'compose:%'
                GROUP BY sessionId
                ORDER BY maxTs DESC
            """)

            var evicted = 0
            for (index, row) in sessionRows.enumerated() {
                if index < limit { continue }
                let sid: String = row["sessionId"]
                _ = try ChatTurn.filter(Column("sessionId") == sid).deleteAll(db)
                evicted += 1
            }
            if evicted > 0 {
                print("[ChatStore] Evicted \(evicted) inbox sessions (limit=\(limit))")
            }
            return evicted
        }
    }

    /// Find a MessageHeader by stableId (rfc822MessageId search, indexed).
    /// Used as fallback when GRDB PK is stale after IMAP folder moves.
    private static func findByStableId(_ stableId: String, db: Database) throws -> MessageHeader? {
        let normalized = EmailFilter.normalizeMessageId(stableId)
        return try MessageHeader.filter(Column("rfc822MessageId") == normalized).fetchOne(db)
    }

    // MARK: - Memory Turn Cap Eviction

    /// Enforce the global max-turns cap for chat history (memory). Deletes the oldest
    /// history turns until the total count is at or below the limit.
    /// This is the user-configurable "Memory" setting — controls how many turns
    /// MemorySearchTool can recall. Default 5000, configurable in settings.
    /// Only affects chatHistory table — chatTurn (sessions) has its own eviction.
    ///
    /// Returns the IDs of evicted turns so the caller can cascade to memory.db.
    /// Stage A's B−A orphan prune would catch any stragglers on next sync startup,
    /// but an immediate cascade avoids the lag window where `memory_search` could
    /// surface content the user configured away. See ADR-IOS-034.
    @discardableResult
    func evictHistoryBeyondCap(maxTurns: Int) throws -> [String] {
        try Self.evictHistoryBeyondCapImpl(dbPool: AppDatabase.dbPool, maxTurns: maxTurns)
    }

    /// Nonisolated eviction for background maintenance thread.
    nonisolated func evictHistoryBeyondCapSync(dbPool: PrioritizedDatabase, maxTurns: Int) throws -> [String] {
        try Self.evictHistoryBeyondCapImpl(dbPool: dbPool, maxTurns: maxTurns)
    }

    private static func evictHistoryBeyondCapImpl(dbPool: PrioritizedDatabase, maxTurns: Int) throws -> [String] {
        try dbPool.write { db in
            let totalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chatHistory") ?? 0
            guard totalCount > maxTurns else { return [] }
            let excess = totalCount - maxTurns
            // Capture the IDs BEFORE deletion so we can cascade to memory.db.
            let evictedIds = try String.fetchAll(db, sql: """
                SELECT id FROM chatHistory ORDER BY timestamp ASC LIMIT ?
            """, arguments: [excess])
            guard !evictedIds.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: evictedIds.count).joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM chatHistory WHERE id IN (\(placeholders))",
                arguments: StatementArguments(evictedIds)
            )
            print("[ChatStore] Evicted \(evictedIds.count) history turns (cap=\(maxTurns), was=\(totalCount))")
            return evictedIds
        }
    }

    // MARK: - Message-Detail Session Eviction

    /// Evict old message-detail chat sessions beyond the limit.
    /// Sessions for messages still in inbox are exempt (kept indefinitely).
    @discardableResult
    func evictMessageDetailSessions(limit: Int) throws -> Int {
        try Self.evictMessageDetailSessionsImpl(dbPool: AppDatabase.dbPool, limit: limit)
    }

    /// Nonisolated eviction for background maintenance thread.
    nonisolated func evictMessageDetailSessionsSync(dbPool: PrioritizedDatabase, limit: Int) throws -> Int {
        try Self.evictMessageDetailSessionsImpl(dbPool: dbPool, limit: limit)
    }

    private static func evictMessageDetailSessionsImpl(dbPool: PrioritizedDatabase, limit: Int) throws -> Int {
        try dbPool.write { db in
            let sessionRows = try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId LIKE 'msg:%'
                GROUP BY sessionId
                ORDER BY maxTs DESC
            """)

            var kept = 0
            var evicted = 0
            for row in sessionRows {
                let sid: String = row["sessionId"]
                if try isMessageInInbox(sessionId: sid, db: db) { continue }
                kept += 1
                if kept > limit {
                    // Delete session turns. History (chatHistory) is a separate table
                    // with dereferenced content — it's preserved by the turn cap setting.
                    _ = try ChatTurn.filter(Column("sessionId") == sid).deleteAll(db)
                    evicted += 1
                }
            }
            if evicted > 0 {
                print("[ChatStore] Evicted \(evicted) message-detail sessions (limit=\(limit))")
            }
            return evicted
        }
    }

    /// Check if the message for a msg-detail session is still in inbox.
    /// Strategy 1: emailContextJSON PK lookup. Strategy 2: stableId rfc822MessageId search.
    private static func isMessageInInbox(sessionId: String, db: Database) throws -> Bool {
        let firstTurn = try ChatTurn
            .filter(Column("sessionId") == sessionId)
            .order(Column("timestamp").asc)
            .fetchOne(db)
        if let json = firstTurn?.emailContextJSON,
           let ctx = decodeEmailContext(json),
           let header = try MessageHeader.fetchOne(db, key: ctx.messageHeaderId) {
            return header.isInInbox
        }
        if let stableId = extractStableId(from: sessionId),
           let header = try findByStableId(stableId, db: db) {
            return header.isInInbox
        }
        return false
    }

    // MARK: - Compose Session Eviction

    /// Evict compose chat sessions older than TTL days.
    /// Compose sessions are NOT resumable — each new compose creates a fresh session.
    /// Old compose turns are kept for MemorySearchTool until TTL expires, then deleted.
    /// Compose edits don't contain [Email](N) references, so no dereferencing needed.
    @discardableResult
    func evictComposeSessions(ttlDays: Int) throws -> Int {
        try Self.evictComposeSessionsImpl(dbPool: AppDatabase.dbPool, ttlDays: ttlDays)
    }

    /// Nonisolated eviction for background maintenance thread.
    nonisolated func evictComposeSessionsSync(dbPool: PrioritizedDatabase, ttlDays: Int) throws -> Int {
        try Self.evictComposeSessionsImpl(dbPool: dbPool, ttlDays: ttlDays)
    }

    private static func evictComposeSessionsImpl(dbPool: PrioritizedDatabase, ttlDays: Int) throws -> Int {
        let cutoffMs = (Date().timeIntervalSince1970 - Double(ttlDays) * 86400) * 1000
        return try dbPool.write { db in
            let sessionRows = try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId LIKE 'compose:%'
                GROUP BY sessionId
                HAVING maxTs < ?
            """, arguments: [cutoffMs])

            var evicted = 0
            for row in sessionRows {
                let sid: String = row["sessionId"]
                _ = try ChatTurn.filter(Column("sessionId") == sid).deleteAll(db)
                evicted += 1
            }
            if evicted > 0 {
                print("[ChatStore] Evicted \(evicted) compose sessions (ttl=\(ttlDays) days)")
            }
            return evicted
        }
    }

    // MARK: - Message Header ID Resolution

    /// Resolve a possibly-stale messageHeaderId to the current GRDB PK.
    /// Strategy 1: PK lookup. Strategy 2: stableId rfc822MessageId search.
    func resolveMessageHeaderId(originalId: String, sessionId: String) throws -> String? {
        try AppDatabase.dbPool.read { db in
            if try MessageHeader.fetchOne(db, key: originalId) != nil {
                return originalId
            }
            if let stableId = Self.extractStableId(from: sessionId),
               let header = try Self.findByStableId(stableId, db: db) {
                return header.id
            }
            return nil
        }
    }

    // MARK: - Reminder Snapshot Encoding

    /// Codable struct for persisting reminder snapshots (subset of Reminder fields).
    private struct ReminderSnapshot: Codable {
        let content: String
        let dueDate: String?
        let dueTime: String?
        let source: String
        let hash: String
        let subject: String?
        let from: String?
    }

    /// Encode reminders to JSON string for storage in chatTurn.remindersSnapshot.
    static func encodeRemindersSnapshot(_ reminders: [Reminder]) -> String? {
        let snapshots = reminders.map {
            ReminderSnapshot(
                content: $0.content, dueDate: $0.dueDate, dueTime: $0.dueTime,
                source: $0.source, hash: $0.hash, subject: $0.subject, from: $0.from
            )
        }
        guard let data = try? JSONEncoder().encode(snapshots) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode reminders from JSON string stored in chatTurn.remindersSnapshot.
    static func decodeRemindersSnapshot(_ json: String) -> [Reminder]? {
        guard let data = json.data(using: .utf8),
              let snapshots = try? JSONDecoder().decode([ReminderSnapshot].self, from: data) else { return nil }
        return snapshots.map {
            Reminder(
                type: "reminder",
                content: $0.content, dueDate: $0.dueDate, dueTime: $0.dueTime,
                source: $0.source, hash: $0.hash, enabled: true,
                action: nil, messageId: nil, uniqueId: nil,
                subject: $0.subject, from: $0.from,
                instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil
            )
        }
    }

    // MARK: - Email Context Snapshot Encoding

    /// Encode email context to JSON string for storage in chatTurn.emailContextJSON.
    static func encodeEmailContext(_ snapshot: EmailContextSnapshot) -> String? {
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode email context from JSON string stored in chatTurn.emailContextJSON.
    static func decodeEmailContext(_ json: String) -> EmailContextSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EmailContextSnapshot.self, from: data)
    }
}

/// Snapshot of email context for message-detail chat sessions.
/// Persisted in chatTurn.emailContextJSON so past sessions show which email was discussed.
struct EmailContextSnapshot: Codable, Sendable, Equatable {
    let messageHeaderId: String  // MessageHeader.id (for re-registering in ChatIdTranslator)
    let subject: String
    let from: String
}
