
## ADR-IOS-034: Memory Index Moves to Per-Turn Granularity (Supersedes v2 Session-Document Model)

**Context:** ADR-IOS-032 shipped a session-document model: one `memory_fts` + `memory_meta` + `memory_vec` row per chat session, with all user + assistant turns concatenated (`[USER]: …\n\n[AGENT]: …`) into a single searchable document.

Observable issues surfaced in `logmain.log` 2026-04-22 against live data:

- **BM25 dilution.** A 3000-char session with one "Kyle" mention ranks alongside — and often worse than — a 200-char session with one "Kyle" mention, because BM25 penalizes long documents. Users saw content they remembered clearly, and the agent couldn't find it.
- **Embedding dilution.** Per-session vectors average over everything the user discussed in one sitting. A session that briefly touched Kyle during an otherwise-unrelated compose produces a near-useless vector for "Kyle"; cosine distances cluster in 0.7–1.0 near-uniformly across queries.
- **Snippet fidelity.** `snippet()` highlights a range inside the concatenated blob, crossing turn boundaries. Output like `[USER]: …added Kyle…[AGENT]: Done!…` is noisy for both the LLM and the UI.
- **Read semantics.** `memory_read(timestamp, tolerance_minutes, max_turns)` returned whole session documents inside the time window. TB's tool contract promises a contiguous window of turns centered on the matched turn within the matched session — we were returning the wrong shape.

**Decision:** Supersede ADR-IOS-032's session-document model with a per-turn model. Every allowlisted chatHistory turn (`type = 'normal'`, role ∈ {user, assistant}) becomes one row in `memory_meta` / `memory_fts` / `memory_vec`, keyed by `chatHistoryId`. `memory_read` returns a session-bounded context window around the matched turn. The LLM-observable tool contract adjusts (per-turn hits, role tag on each result) — which is the TB-parity behavior we claimed in v2 but didn't achieve. Prompt-template update coordinated at rollout.

memory.db remains an isolated sidecar file (no ATTACH, no cross-DB references) — same pattern as `SearchIndex`'s `fts.db`. Writes are orchestrated from a single Swift method: `ChatStore.appendTurn` commits to chatHistory, then calls `MemoryIndex.indexTurn` + enqueues embedding. Failures between the two are caught by Stage A self-heal's A−B direction on next launch.

**Rationale:**

- **Correct ranking unit.** BM25 operates on single-turn documents; each turn's relevance is independent. Embeddings are per-turn — semantic precision for fine-grained queries.
- **Correct snippet unit.** FTS5 `snippet()` can't cross turn boundaries because each turn is its own row.
- **TB parity actually achieved.** TB's `memory_db.rs` operates on turns (via the internal turn ordering implicit in its store). v3 matches — not just at the tool-contract args boundary, but at the returned-shape boundary too.
- **Hardened persistence unchanged.** `indexEpoch` race stamp, `embeddingComplete = 0` partial index, bounded Stage A concurrency, epoch-stamp mid-flight detection — all inherited verbatim from v2. v3's novelty is granularity + read semantics; durability model is unchanged.
- **Disposable index, authoritative truth elsewhere.** chatHistory stays the source of truth; memory.db is derivable. Future schema changes → bump `PRAGMA user_version`, delete the file on first launch, Stage A rebuilds from chatHistory in seconds.
- **UI = single query path.** ChatHistoryView's default view and search both go through `MemoryIndex.listTurns` / `MemoryIndex.search`. No more mixed data source (chatHistory for the list, memory.db for search).

**Consequences:**

- **v2 session-level code is deleted in-place**, not feature-flagged. v2 ran only on dev devices, and memory.db is disposable — a clean cutover is simpler than carrying both paths. On first v3 launch, the schema-version gate (`PRAGMA user_version < 3`) drops any leftover v2 tables; Stage A refills memory.db from chatHistory. chatHistory itself is untouched across the transition — zero user data loss.
- **Schema (all in memory.db, isolated):** `memory_meta(rowid PK, chatHistoryId TEXT UNIQUE NOT NULL, sessionId TEXT, role TEXT NOT NULL, dateMs INT NOT NULL, indexEpoch INT DEFAULT 1, embeddingComplete INT DEFAULT 0)`. Supporting indexes on `dateMs`, `sessionId`, `(sessionId, dateMs)` composite for read window walks, partial on `embeddingComplete = 0`. `memory_fts(content)` FTS5 and `memory_vec(embedding FLOAT[384] cosine)` share rowid with `memory_meta`.
- **API surface** on `MemoryIndex`: `indexTurn(chatHistoryId:, sessionId:, role:, dateMs:, text:)`, `indexTurns(_:)` (bulk), `deleteTurns(chatHistoryIds:)`, `deleteAll()`, `listTurns(limit:)`, `search(query:, fromMs:, toMs:, limit:)`, `readByTimestamp(timestampMs:, toleranceMs:, maxTurns:)`, `knownChatHistoryIds()`, plus the queue-facing helpers `pendingEmbeddingChatHistoryIds(limit:)`, `ftsContentWithEpochs(chatHistoryIds:)`, `storeEmbeddings(pairs:)`. Shared extractor `MemoryIndex.memoryText(for:)` handles the user-turn `userMessage ?? content` guard for "chat_converse" template leak.
- **`MemoryHit` shape** changes from `(sessionId, memId, dateMs, content, …)` to `(chatHistoryId, sessionId?, role, dateMs, content, …)`. `sessionId` becomes optional because pre-v11 chatHistory rows have NULL; `readByTimestamp` falls back to a pure time-window walk in that case.
- **`BackfillMemoryEmbeddingQueue.Item` becomes `{ chatHistoryId }`** (was `{ sessionId }`). All embed pipeline semantics unchanged. Retry + epoch-stamp race + drain-time self-repopulate inherited verbatim.
- **`MemorySelfHealDriver` grows the B−A orphan direction.** v2 only handled A−B (missing → index). v3 per-turn deletes open a crash window: chatHistory DELETE commits, memory.db cascade may fail, orphans linger. Stage A's B−A pass walks `knownChatHistoryIds - allHistoryTurnIds` and calls `deleteTurns`. The A−B direction uses `historyTurnIdsForSelfHeal(olderThan:)` (idle-cutoff-filtered); the B−A direction uses `allHistoryTurnIds()` so active sessions' memory.db rows aren't wrongly pruned.
- **`DynamicIslandChatButton` session-end hook shrinks.** No more `indexSession(turns:)` fire-and-forget at idle timeout — per-turn indexing happens at `appendTurn` time. Session-end's remaining role: KB-refine trigger + `dereferenceSessionTurns`.
- **`ChatHistoryView` queries memory.db only.** Default view → `MemoryIndex.listTurns(limit:)`; search → `MemoryIndex.search(...)`. `ChatStore.loadAllHistoryTurns()` is no longer called from the view but stays on `ChatStore` for debug/test access to the authoritative chatHistory.
- **Tool output changes:** `memory_search` hits include `(USER)` / `(AGENT)` role tag; `memory_read` returns `--- <date> (USER|AGENT) ---\n<body>` per turn in the context window. Backend prompt template must be updated to reflect the new shape (coordinated in the same release).
- **No tabmail.sqlite migration.** chatHistory schema (v25 + v52) is sufficient. `MemoryIndex.memoryText` is computed in Swift at index time.
- **GRDB SQL-interpolation pitfall guards** on every map closure that builds tool output — explicit `let formatted: String` + `-> String in` return-type annotation. Regression test in `MemorySearchToolTests` asserts the output contains no `SQL(elements:` or `GRDB.SQL.Element` AST literals (caught on 2026-04-22 when v2 leaked type descriptions into LLM output).

**Migration / rollout:**

- Dev device with v2 memory.db: drop-and-rebuild triggers automatically via `PRAGMA user_version < 3` on first v3 launch. Stage A refills from chatHistory; users see a brief "memory catching up" window (seconds, bounded by `memorySelfHealChunkSize = 200` per transaction).
- Production: same path. memory.db file is disposable; chatHistory carries the truth.
- Future schema changes on memory.db: bump `schemaVersion` (currently 3) — existing dev-device data gets dropped and rebuilt. Zero migration code needed.

**Related:** ADR-IOS-032 (superseded for granularity + read semantics; durability model preserved), ADR-IOS-008 (TB parity scope now extends to per-turn hit shape and role tagging), ADR-IOS-027 (ever-rolling FIFO queue invariants inherited by the new chatHistoryId-keyed item).

---
