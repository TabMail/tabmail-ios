
## ADR-IOS-032: Memory Search Reuses iOS Swift Hybrid FTS Stack (No Rust FFI)

> **Partial supersession:** the session-document data model described below was replaced by the per-turn model in **ADR-IOS-034** (2026-04-22). The Swift-vs-Rust-FFI decision in this ADR still holds — only the granularity / read-semantics parts are superseded.

**Context:** The memory-search feature (replacing `ChatStore.search`'s LIKE-based SCAN with a hybrid FTS5 + vector pipeline) needs to match the LLM-observable behavior of Thunderbird's `memory_search` / `memory_read` tools under ADR-IOS-008 (AI processing must replicate TB addon architecture).

A tempting framing was "reuse the Rust implementation in `tabmail-native-fts/src/fts/memory_db.rs` via FFI, to avoid drift from TB." That framing was stale. On inspection, **iOS does not link `tabmail-native-fts` at all.** Email FTS on iOS is independently implemented in Swift (`TabMail/Services/Search/SearchIndex.swift`), using GRDB + FTS5 + vendored `sqlite-vec`. The hybrid merge math is already ported in `HybridMerge.swift`, and the tuning constants (`vectorWeight=0.7`, `textWeight=0.3`, `vectorScoreThreshold=0.45`, `minScore=0.1`) are already in `SearchConfig.swift` with matching names to `tabmail-native-fts/src/config.rs`. The Rust crate ships solely with TB's native-messaging host.

**Decision:** Memory search on iOS is implemented entirely in Swift, reusing the existing FTS pipeline (`HybridMerge`, `SearchConfig`, sqlite-vec registration pattern, actor-serialized `DatabasePool`). No FFI to `tabmail-native-fts` is added. A new `MemoryIndex` actor mirrors `SearchIndex`'s structure against a sibling DB file at `Application Support/TabMail/tabmail_memory/memory.db`.

ADR-IOS-008 parity is measured at the **tool boundary** (args, result shape, ranking characteristics observed by the LLM), not at the storage-engine boundary. The TB addon itself runs in a separate process from the Rust native host, communicating over native messaging — the storage split is a TB architectural detail, not a portability mandate. Matching schema + constants + merge math in Swift achieves the same LLM-observable parity.

**Rationale:**

- **Consistency with existing iOS FTS.** Email search is already Swift-native. Making memory search Rust-FFI would create a split where two sibling features use two storage stacks for no user-facing reason.
- **No new cross-language boundary.** Adding FFI for a feature that can be built on existing Swift infrastructure is net-new complexity (new C-visible exports, bridging header, Swift wrapper layer, Rust release-cadence coupling).
- **Drift risk is bounded and managed.** `HybridMerge.swift` is ~90 lines. `SearchConfig` constants already mirror `config.rs` by name and value. A TB-side tuning change is a one-file mirror.
- **Debuggability.** Swift stack traces + Xcode breakpoints end-to-end beat opaque FFI return codes for a feature that will need empirical tuning (ranking quality is inherently observational).
- **Decoupled release cadence.** Memory-search tweaks don't require a `tabmail-native-fts` version bump + re-vendor cycle (`tabmail-release` skill).

**Consequences:**

- `MemoryIndex.swift` (new actor, single file) is the only new iOS module. It lives at `TabMail/Services/Search/MemoryIndex.swift` — next to `SearchIndex.swift` (its structural sibling), not in a separate `Services/Memory/` directory. No separate `MemoryIndexer.swift` — the simplification rounds folded all indexing logic into the single actor, and durability is handled by fire-and-forget `Task` at session-end + startup self-heal via set diff (no queue/drain).
- `MemoryIndex` mirrors `SearchIndex`'s structure: `DatabasePool`, `sqlite-vec` registered via `tabmail_register_sqlite_vec_on_db` in `prepareDatabase`, schema self-managed (not via `AppDatabase` migrator), lazy `private func ensureReady()` on first public call. Schema: `memory_fts` (FTS5 on `content` only), `memory_meta` (rowid + memId UNIQUE + dateMs + sessionId + **`indexEpoch` monotonic race stamp** + `embeddingComplete` flag), `memory_vec` (vec0 FLOAT[384] cosine). Partial index on `embeddingComplete = 0` keeps repopulate probes O(pending).
- Memory-specific constants are added to `SearchConfig.swift` (separate slots from email even when values match, per the global rule against reusing constants that upstream keeps split — `tabmail-native-fts/src/config.rs:78-82` maintains separate `EMAIL_*` and `MEMORY_*` weights even though values are identical today, so iOS matches slot-for-slot). Exception: tokenizer / candidate-multiplier / snippet-tokens are reused because TB also reuses them across email and memory. `SyncConfig` gets three memory-embedding constants sibling to email's (`memoryEmbeddingBatchSize`, `memoryEmbeddingRepopulateChunk`, `memoryEmbeddingDrainRepopulateLimit`) — split because email splits them (top-level `repopulateFromDatabase` chunk ≠ `repopulateOnDrain` safety net), same slot-for-slot rule.
- Race stamp: the queue's mid-flight re-index detection uses `memory_meta.indexEpoch` (monotonic per-session counter), not `rowid`. SQLite's default rowid allocation can reuse a freshly-DELETEd rowid when it was the current max (e.g., rowids `{1,2,3,4,5}` → delete 5 → next INSERT picks 5 again), so a rowid-only stamp would be defeated in that narrow case. Epoch is strictly monotonic per-session — closes the hole deterministically.
- `chatHistory` gets a **v52 migration** (next free slot — migrations v1–v51 are already registered, latest `v51_headerIncompletePartialIndex` at `AppDatabase.swift:1390`; do not collide with unrelated `v26_addMessageHeaderReferences`) adding a `type TEXT NOT NULL DEFAULT 'normal'` column + backfill from `chatTurn` (which has `type` since v6). Without v52, the self-heal path cannot apply the `type == "normal"` filter that `KBRefinementService.swift:33-35` enforces — non-normal assistant turns (greeting, welcome_back, session_break) would pollute FTS. Backfill uses a correlated subquery on `chatTurn.id` (TEXT PK, O(log N) per probe via implicit PK index, no scan) with `COALESCE(..., 'normal')` fallback for rows whose chatTurn was already evicted (chatTurn cap is ~100, chatHistory cap is ~5000 — divergence is expected and the default is pragmatic). The self-heal filter loads ~20 turns per session via the existing `chatHistory_sessionId` index and filters in memory — no new `type` index needed.
- If TB's `memory_db.rs` merge math or tokenizer settings change, update `HybridMerge` / `SearchConfig` to match in the same PR. This is the ongoing coordination tax for this decision.
- Tool contract (`memory_search` / `memory_read` args, paginated result shape with `[timestamp: ...]` prefix) is unchanged — the swap is transparent to the LLM. `MemoryReadTool`'s success output is corrected to raw string per TB (was JSON-dict-wrapped — a bug). `MemoryIndex.search` FTS-candidate query uses `ORDER BY rank ASC, meta.dateMs DESC LIMIT ?` per TB `memory_db.rs:586` for deterministic ordering.
- `indexSession` short-circuits on empty content (zero surviving turns after the role/type filter) — no write transaction, no FTS row, no `memory_meta` entry. Mirrors TB `memoryIndexer.js:47-50`. Prevents empty sessions from polluting `knownSessionIds()` and causing repeated no-op self-heal passes.

**Out of scope:**

- Migrating email FTS to the Rust crate (opposite direction; not considered — email FTS is working and shipped).
- Cross-device memory sync.
- Making `tabmail-native-fts` linkable from iOS for some future feature. If such a feature appears (e.g., a large native-compute workload that's genuinely hard to replicate in Swift), revisit. Memory search is not that feature.

**Files (will be created under this plan):**

- `TabMail/Services/Search/MemoryIndex.swift` — actor + GRDB pool + FTS5 + sqlite-vec schema for `memory.db`. Owns FTS+meta writes, search, `readByTimestamp`, `knownSessionIds`, `ftsContentWithEpochs(sessionIds:)`, `pendingEmbeddingSessionIds(limit:)`, `storeEmbeddings(pairs:)` (with epoch-stamp check), and the role-aware session-text extractor. Does **not** own embedding — that's the queue's job.
- `chatHistory` schema gains `type` column via **v52 migration** (minimal DDL + correlated-subquery backfill from `chatTurn` using its TEXT PK — O(log N) per probe, no scan).
- `TabMail/Services/Search/BackfillMemoryEmbeddingQueue.swift` — clone of `BackfillEmbeddingQueue.swift` with `Item: { sessionId: String }` and memory.db-specific read/write methods. Cloned rather than genericized (keeps each queue focused, avoids polymorphic dispatch, follows CLAUDE.md "no premature abstraction"). Inherits all durability patterns (retry cap, foreground repopulate, drain-time self-repopulate, `EmbeddingService.shared != nil` gating, BGProcessingTask drain) from the email queue. Rationale: *"we should really not reinvent the system that's working well."*
- Reused as-is: `TabMail/Services/Search/HybridMerge.swift`, `TabMail/Services/Search/SearchConfig.swift` (memory constants added alongside email's), `TabMail/Vendor/sqlite-vec/*`, `QueueStorage<Item>` generic.
- New actor `TabMail/Services/Search/MemorySearchCache.swift` for per-user-turn pagination caching (mirrors TB's `memory_search.js` `searchSessions` map).

**Related:** ADR-IOS-008 (TB parity scope), ADR-IOS-031 (GRDB-touching background tasks at `.medium` priority).

---
