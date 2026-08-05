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

    /// Budget constants (matching TB). PORT — internal (not private), as in
    /// v2final's `ChatStore`, so the active-compose-guard tests derive the budget
    /// thresholds FROM these constants instead of hardcoding the numbers.
    static let maxExchanges = 50
    static let charsPerExchange = 500

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
        // PORT — v2final `ChatStore.appendTurn`. Both budget branches below delete the
        // globally-OLDEST turns during a normal append. Exempt the compose sessions the
        // user currently has OPEN so an append in ANOTHER session can't evict an active
        // reopened compose's turns.
        //
        // 🚨 THIS IS THE CHEAP FIRST FILTER, NOT THE AUTHORITY. It is read BEFORE
        // `dbPool.write` opens, so a compose that calls `register(draftId)` after this
        // line is invisible to it — the stale-snapshot shape `DraftSessionRegistry`'s
        // header forbids. `enforceTurnBudgets` re-asks the registry LIVE inside the
        // transaction and takes the union; see its doc comment.
        let activeComposeSessions = DraftSessionRegistry.shared.activeComposeSessionIds()
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

            let evictedTurns = try Self.enforceTurnBudgets(db: db, activeComposeSessions: activeComposeSessions)

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

    /// PORT — v2final `ChatStore.enforceTurnBudgets(db:activeComposeSessions:)`.
    /// The two `chatTurn` budget sweeps (count FIFO + char), factored out of
    /// `appendTurn` so the active-compose exemption is unit-testable against a real
    /// db without the actor / global-pool / post-commit memory-index machinery.
    ///
    /// Both sweeps EXEMPT `activeComposeSessions`: a compose the user has OPEN must
    /// not lose its turns to a budget triggered by an append in ANOTHER session —
    /// those are authored user bytes, on screen right now. A nil `sessionId`
    /// (legacy) is never in the active set → stays evictable. The exemption is a
    /// bounded, visible DEFERRAL, never a discard: `DraftSessionRegistry` is
    /// in-memory only and starts EMPTY at every launch, so a missed `unregister`
    /// over-retains for at most the remainder of the process and the next
    /// maintenance pass reclaims it. Both caps therefore stay SOFT rather than
    /// disabled — every INACTIVE turn is still fully evictable.
    ///
    /// 🚨 **THE `activeComposeSessions` PARAMETER IS A SNAPSHOT, SO THIS FUNCTION
    /// RE-ASKS THE REGISTRY LIVE.** ⚠️ CORRECTED 2026-08-05: the paragraph above
    /// said "a compose the user has OPEN must not lose its turns" as though the
    /// parameter delivered that. It did not. `appendTurn` samples the registry
    /// BEFORE opening `dbPool.write`, so a compose that called `register` between
    /// that sample and the commit was absent from the set and its authored turns
    /// were deleted by the very next append in another session — the stale-snapshot
    /// shape `DraftSessionRegistry`'s doc header forbids and that `DraftStore`
    /// carried until `eda55f4ca` the same day. The exemption set used below is
    /// therefore the UNION of the caller's snapshot and a LIVE read taken inside the
    /// caller's write transaction.
    ///
    /// COST (Rule A6) — the live read is taken ONCE at the top of this function, not
    /// per row. This helper runs on the ORDINARY append path, and both loops below
    /// walk every `chatTurn` row (`ChatTurn.order(…).fetchAll`, bounded by the count
    /// cap `maxExchanges * 2` plus the excess that triggered the sweep). One
    /// uncontended `Mutex` read per append is the cost; a per-row read would be ~100×
    /// that for no gain, because every deletion decision below is taken after this
    /// line and inside the same transaction.
    ///
    /// RESIDUAL, stated precisely rather than claimed closed: the live read narrows
    /// the exposure from [`appendTurn`'s pre-transaction sample .. commit] to [this
    /// function's own read .. commit] — the insert of the new turn and its
    /// `chatHistory` twin, plus the two sweeps. A `register` landing inside THAT
    /// remnant still misses. It is the direction the mantra tolerates: the compose
    /// keeps its text in memory and re-appends, and `chatHistory` (the memory
    /// store, evicted separately) is unaffected by this sweep.
    ///
    /// TERMINATION — each loop iterates a materialized array fetched BEFORE the
    /// loop. The measured variant is the number of unvisited elements of that array
    /// (strictly decreasing by exactly 1 per iteration, lower bound 0); the exempt
    /// arm `continue`s, which consumes the variant like every other arm, so an
    /// exempted session can never stall the sweep. `deleted`/`totalChars` are early
    /// exits, not the variant.
    ///
    /// Returns the deleted turns (for the caller's ID-translator cleanup). Runs
    /// inside the caller's write transaction (`db`).
    static func enforceTurnBudgets(db: Database, activeComposeSessions: Set<String>) throws -> [ChatTurn] {
        var evictedTurns: [ChatTurn] = []

        // Snapshot ∪ LIVE — see the header. `activeComposeSessions` was sampled before
        // the caller opened its write transaction; this read happens INSIDE it, which
        // is what makes it the authority. `activeComposeSessionIds()` is the registry's
        // OWN derivation of the `compose:<id>` / `demo:compose:<id>` forms, so deriving
        // them here would fork the key format. Hoisted out of both loops on purpose
        // (Rule A6): once per sweep, never per row.
        let exemptSessions = activeComposeSessions
            .union(DraftSessionRegistry.shared.activeComposeSessionIds())

        // Turn-COUNT budget. Scan oldest-first, SKIP active-compose turns, delete
        // `excess` ELIGIBLE turns (a bare `.limit(excess)` could pick active ones).
        // If too few inactive turns exist the cap stays SOFT — active history wins.
        let totalTurns = try ChatTurn.fetchCount(db)
        let maxMessages = Self.maxExchanges * 2
        if totalTurns > maxMessages {
            let excess = totalTurns - maxMessages
            let oldestAll = try ChatTurn.order(Column("timestamp").asc).fetchAll(db)
            var deleted = 0
            for old in oldestAll {
                if deleted >= excess { break }
                if let sid = old.sessionId, exemptSessions.contains(sid) { continue }
                try old.delete(db)
                evictedTurns.append(old)
                deleted += 1
            }
        }

        // CHAR budget — evict oldest (skipping active-compose) until under budget.
        var totalChars = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(chars), 0) FROM chatTurn") ?? 0
        let maxChars = Self.maxExchanges * Self.charsPerExchange
        if totalChars > maxChars {
            let oldestTurns = try ChatTurn.order(Column("timestamp").asc).fetchAll(db)
            for oldest in oldestTurns {
                guard totalChars > maxChars else { break }
                if let sid = oldest.sessionId, exemptSessions.contains(sid) { continue }
                totalChars -= oldest.chars
                try oldest.delete(db)
                evictedTurns.append(oldest)
            }
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

    /// SQL predicate scoping the inbox-session list per mode. Demo chat
    /// sessions always carry the `demo:` sessionId prefix (see
    /// `DemoModeStore.scopedSessionId`): in demo mode ONLY demo sessions are
    /// listed (minus demo msg/compose contexts, which have their own load
    /// paths); in normal mode demo sessions are excluded entirely.
    /// Static + pure so tests can run it against an in-memory DB.
    nonisolated static func inboxSessionScopeSQL(demoActive: Bool) -> String {
        demoActive
            ? "sessionId LIKE 'demo:%' AND sessionId NOT LIKE 'demo:msg:%' AND sessionId NOT LIKE 'demo:compose:%'"
            : "sessionId NOT LIKE 'demo:%' AND sessionId NOT LIKE 'msg:%' AND sessionId NOT LIKE 'compose:%'"
    }

    /// Load the last K distinct **inbox** sessions, ordered newest-last (rightmost in swipe UI).
    /// Excludes message-detail sessions (sessionId LIKE 'msg:%') and compose sessions
    /// (sessionId LIKE 'compose:%') — those are loaded separately via loadContextSession().
    /// `demoActive` scopes the list to demo-only / demo-free (see inboxSessionScopeSQL).
    func loadSessions(limit: Int, demoActive: Bool) throws -> [ChatSession] {
        try AppDatabase.dbPool.read { db in
            // Get distinct sessionIds ordered by max timestamp DESC, limited to K
            // Filter out msg-detail and compose sessions (they have their own load paths)
            let sessionRows = try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId IS NOT NULL
                  AND \(Self.inboxSessionScopeSQL(demoActive: demoActive))
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

    /// PORT — v2final `ChatStore.extractAccountAndStableId(from:)`, which REPLACED
    /// that branch's `extractStableId(from:)` (v3's twin, removed here — it had no
    /// other callers). Parse a msg-detail sessionId "msg:{accountId}:{stableId}"
    /// (optionally "demo:"-prefixed) into its components. Splits on the FIRST ':'
    /// after "msg:" so a stableId that itself contains colons round-trips. The
    /// session account is authoritative for identity scoping. Rejects empty account
    /// or empty stable components; non-message sessions (compose:/inbox/malformed)
    /// return nil.
    static func extractAccountAndStableId(from sessionId: String) -> (accountId: String, stableId: String)? {
        var sid = sessionId
        if sid.hasPrefix("demo:") { sid = String(sid.dropFirst(5)) }
        guard sid.hasPrefix("msg:") else { return nil }
        let after = String(sid.dropFirst(4)) // drop "msg:"
        guard let ci = after.firstIndex(of: ":") else { return nil }
        let accountId = String(after[..<ci])
        let stableId = String(after[after.index(after: ci)...])
        guard !accountId.isEmpty, !stableId.isEmpty else { return nil }
        return (accountId, stableId)
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
            // Demo sessions are excluded (demoActive: false scope): they are
            // wiped wholesale on demo exit and must not crowd out (or be
            // counted against) the user's inbox-session limit.
            let sessionRows = try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId IS NOT NULL
                  AND \(inboxSessionScopeSQL(demoActive: false))
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

    /// PORT — v2final `ChatStore.findByStableId(_:accountId:db:)`. Resolve a
    /// MessageHeader by the session's stable-identity `anchor`, SCOPED to
    /// `accountId`. Used as the fallback when the GRDB PK is stale after an IMAP
    /// folder move.
    ///
    /// ⚑ THE KEY IS UNCHANGED AND STILL RFC-822-BASED — `rfc822MessageId`, exactly
    /// as before. This adds a SCOPE (`accountId`), not a keying scheme: chat binding
    /// is CONTENT identity ("same content ⇒ same key"), never the provider-id keying
    /// the durable action queue uses. Without the scope the lookup searched
    /// `rfc822MessageId` GLOBALLY, so a session in account A could bind to account
    /// B's copy of the same message.
    ///
    /// Only a CANONICAL RFC anchor is resolvable here (rfc822 is the move-durable
    /// identity); a token/bare anchor is NOT globally matched — a bare "123" must
    /// never bind a row whose stored rfc822 is the malformed literal "123". The PK
    /// strategy at each caller already covers the token/bare row.
    /// `MessageIdentity.comparableRfc822Identity` is this branch's name for the
    /// reference's `MessageIdentity.durableActionRFC822MessageId` (see that symbol's
    /// doc comment: renamed because v3 reversed the RFC-keyed action queue, ported
    /// verbatim in semantics, and it is the identity-COMPARISON form — the one this
    /// call needs — not the key-MINTING form).
    ///
    /// Deterministic inbox-preferred pick among same-account, same-RFC copies
    /// (siblings = one logical message), so a resolve never flip-flops between an
    /// Inbox row and its Archive twin.
    static func findByStableId(_ anchor: String, accountId: String, db: Database) throws -> MessageHeader? {
        guard let canonical = MessageIdentity.comparableRfc822Identity(anchor) else { return nil }
        return try MessageHeader
            .filter(Column("accountId") == accountId && Column("rfc822MessageId") == canonical)
            .order(Column("isInInbox").desc, Column("id").asc)
            .fetchOne(db)
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
        // PORT — v2final `ChatStore.evictHistoryBeyondCapImpl`. Never cap-evict history
        // turns of a compose session the user currently has OPEN. The cap stays a SOFT
        // target: only the oldest INACTIVE turns are selected, so active compose history
        // survives even if it keeps total > cap.
        //
        // 🚨 CHEAP FIRST FILTER ONLY. ⚠️ CORRECTED 2026-08-05: "never cap-evict history
        // turns of a compose the user currently has OPEN" was not what this code did.
        // This read happens BEFORE `dbPool.write` opens, so a compose that called
        // `register` in between was absent from the exemption and its history rows were
        // selected and DELETED — the stale-snapshot shape `DraftSessionRegistry`'s doc
        // header forbids, and the shape `DraftStore.evictImpl` carried until
        // `eda55f4ca` the same day. The exemption actually used is the union with a
        // LIVE read taken inside the write block, below.
        let snapshotComposeSessions = DraftSessionRegistry.shared.activeComposeSessionIds()
        return try dbPool.write { db in
            let totalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chatHistory") ?? 0
            guard totalCount > maxTurns else { return [] }
            let excess = totalCount - maxTurns
            // Snapshot ∪ LIVE, INSIDE the transaction and AT the deletion decision —
            // that is what makes it the authority. This site builds its exemption into
            // the SELECT's `NOT IN` list, so "live" means deriving that list here
            // rather than before the write opened.
            //
            // ONCE per sweep (Rule A6), and deliberately AFTER the `guard` above: the
            // set feeds one SQL statement, so there is no per-row question to ask, and
            // the common under-cap no-op path now takes no registry read at all.
            //
            // RESIDUAL, stated precisely rather than claimed closed: the window narrows
            // from [pre-transaction sample .. commit] to [this line .. commit] — the id
            // SELECT and the DELETE. A `register` landing inside that remnant still
            // misses. `chatTurn` (the resumable session rows the open compose actually
            // renders) is a different table and is untouched here, so the loss in that
            // remnant is memory-search recall, not the text on screen.
            let activeComposeSessions = snapshotComposeSessions
                .union(DraftSessionRegistry.shared.activeComposeSessionIds())
            // Capture the IDs BEFORE deletion so we can cascade to memory.db. Select
            // the oldest EVICTABLE ids: exclude active compose sessions. NULL-safe —
            // `sessionId IS NULL OR sessionId NOT IN (...)` keeps null/non-compose rows
            // eligible (a bare `NOT IN` yields NULL for a null sessionId, which would
            // wrongly immortalize it). Empty active set → the plain query (avoids the
            // invalid `NOT IN ()`).
            let evictedIds: [String]
            if activeComposeSessions.isEmpty {
                evictedIds = try String.fetchAll(db, sql: """
                    SELECT id FROM chatHistory ORDER BY timestamp ASC LIMIT ?
                """, arguments: [excess])
            } else {
                let activeArr = Array(activeComposeSessions)
                let ph = Array(repeating: "?", count: activeArr.count).joined(separator: ",")
                var args: [DatabaseValueConvertible] = activeArr
                args.append(excess)
                evictedIds = try String.fetchAll(db, sql: """
                    SELECT id FROM chatHistory
                    WHERE (sessionId IS NULL OR sessionId NOT IN (\(ph)))
                    ORDER BY timestamp ASC LIMIT ?
                """, arguments: StatementArguments(args))
            }
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
    /// Strategy 1: emailContextJSON PK lookup. Strategy 2: the session's stable-identity
    /// anchor, re-resolved ACCOUNT-SCOPED (see `findByStableId`) — a session in account A
    /// must never decide its inbox membership from account B's copy of the same RFC id.
    static func isMessageInInbox(sessionId: String, db: Database) throws -> Bool {
        let firstTurn = try ChatTurn
            .filter(Column("sessionId") == sessionId)
            .order(Column("timestamp").asc)
            .fetchOne(db)
        if let json = firstTurn?.emailContextJSON,
           let ctx = decodeEmailContext(json),
           let header = try MessageHeader.fetchOne(db, key: ctx.messageHeaderId) {
            return header.isInInbox
        }
        if let (acct, anchor) = extractAccountAndStableId(from: sessionId),
           let header = try findByStableId(anchor, accountId: acct, db: db) {
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
        // PORT — v2final `ChatStore.evictComposeSessionsImpl`. Never TTL-sweep a compose
        // session the user currently has OPEN. A REOPENED compose whose turns are all
        // older than the TTL would otherwise lose its live chat history while on screen
        // (no race required).
        //
        // 🚨 CHEAP FIRST FILTER ONLY — and the race the parenthetical above did not
        // cover was real. ⚠️ CORRECTED 2026-08-05: this read happens BEFORE
        // `dbPool.write` opens, so a compose REOPENED after this line but before the
        // commit was absent from the exemption and the sweep deleted its authored turns
        // while it was on screen. That is the stale-snapshot shape
        // `DraftSessionRegistry`'s doc header forbids, and the direct analogue of
        // `DraftStore.evictImpl`'s orphan-session loop, fixed in `eda55f4ca` the same
        // day. The loop below re-asks the registry LIVE at each deletion decision.
        let activeComposeSessions = DraftSessionRegistry.shared.activeComposeSessionIds()
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
                // Snapshot first (cheap), then the LIVE registry as the authority —
                // this is the point at which THIS session's deletion is decided, so
                // this is where the question has to be asked. Mirrors
                // `DraftStore.evictImpl`'s orphan-session loop exactly.
                //
                // Per-row is affordable here and is NOT the `enforceTurnBudgets` case
                // (Rule A6): `sessionRows` is the DISTINCT expired `compose:%` sessions
                // in `chatTurn`, and `chatTurn` is itself capped at
                // `maxExchanges * 2` rows by `enforceTurnBudgets`, so this loop is tens
                // of iterations on a background maintenance pass, not thousands on the
                // append path. `activeComposeSessionIds()` is O(open composes) — 0–2.
                //
                // RESIDUAL, stated precisely rather than claimed closed: the window
                // narrows from [pre-transaction sample .. commit] to [this session's
                // own check .. commit]. A `register` landing after this session has
                // already been examined still misses, because the rows are by then
                // deleted inside the open transaction.
                if activeComposeSessions.contains(sid)
                    || DraftSessionRegistry.shared.activeComposeSessionIds().contains(sid) { continue }
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
    /// Strategy 1: PK lookup. Strategy 2: account-scoped stable-identity re-resolve.
    func resolveMessageHeaderId(originalId: String, sessionId: String) throws -> String? {
        try AppDatabase.dbPool.read { db in
            try Self.resolveMessageHeaderId(originalId: originalId, sessionId: sessionId, db: db)
        }
    }

    /// PORT — v2final `ChatStore.resolveMessageHeaderId(originalId:sessionId:db:)`, the
    /// testable core of the wrapper above (the actor method reads the global pool).
    /// Strategy 1: PK lookup, unchanged. Strategy 2: the session's stable-identity
    /// anchor, re-resolved ACCOUNT-SCOPED (see `findByStableId`) so a stale PK in
    /// account A can never resolve onto account B's copy of the same RFC id.
    static func resolveMessageHeaderId(originalId: String, sessionId: String, db: Database) throws -> String? {
        if try MessageHeader.fetchOne(db, key: originalId) != nil {
            return originalId
        }
        if let (acct, anchor) = extractAccountAndStableId(from: sessionId),
           let header = try findByStableId(anchor, accountId: acct, db: db) {
            return header.id
        }
        return nil
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
