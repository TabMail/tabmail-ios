# TabMail iOS - Architectural Decisions

> **Check this file before proposing alternatives.** For cross-cutting decisions, see `../DECISIONS.md`.

---

## Foundational Principle: Never Drop User Intention

The following ADRs (001, 003, 018, 019) form a unified system built on one principle: **user intention must never be lost.** When a user performs an action — archive, delete, send, tag — that intention is persisted to the database before the UI acknowledges success. Remote execution is deferred and retried until complete or provably unnecessary.

**Key invariants across all queue-based systems:**

- **Persist → Acknowledge → Execute** — database write happens before UI dismissal/animation. If persist fails, the user sees an error and retains their data (compose stays open, action is not animated).
- **Remote state wins on conflict** — when sync reveals the server already reflects the desired state (message deleted by another client, tag set by TB addon), the queued operation is silently dropped. The server is the source of truth.
- **Treat all instances equally** — IMAP keyword changes from another TabMail instance (e.g., TB addon setting `tm_archive`) are treated as equivalent to local user actions. When consolidating, the most recent writer wins regardless of which device originated the action. The queue is not privileged over remote state.
- **Never silently discard user work** — failed operations remain visible for user action (retry/dismiss). Automatic cleanup only applies to provably-completed operations.

---

## ADR-IOS-001: Optimistic UI with Hardened Sync

**Context:** Mobile apps operate in unreliable environments — connections drop, users close the app mid-operation, processes get killed by the OS. Email operations (archive, delete, move, sync) involve both local state and remote IMAP/provider state that must stay consistent.

**Decision:**
1. **Optimistic UI** — All user-initiated actions (archive, delete, move, mark read) update local database state (GRDB) and animate immediately using native iOS animations (swipe-to-zap). The user never waits for a server round-trip.
2. **Verified state persistence** — Backend state markers (history IDs, sync cursors, IMAP UIDs) are only persisted after verified completion of the remote operation. Never write state ahead of confirmation.
3. **Idempotent operations** — Every operation that touches remote state must be idempotent. Re-executing the same operation after a crash or disconnect must produce the same result without side effects.
4. **Self-healing on launch** — On app launch and sync resume, detect incomplete operations (local state says "archived" but IMAP move never completed) and either retry the remote operation or roll back local state.

**Rationale:**
- Users expect instant responsiveness — waiting for IMAP round-trips feels broken on mobile
- Connections are fundamentally unreliable on mobile (cellular handoffs, tunnels, airplane mode)
- The OS can kill the app at any time (memory pressure, user swipe-to-close)
- Pre-writing state markers before confirmation causes stale entries that corrupt future syncs
- Idempotency + self-healing means the app always converges to a correct state

**Consequences:**
- Every sync operation needs a "pending" → "confirmed" state machine
- Local database model needs fields to track operation completion status
- Launch/resume path must include an incomplete-operation scan
- Slightly more complex code, but dramatically more reliable UX
- No "ghost" messages that were deleted locally but never synced

---

## ADR-IOS-002: User Activity Prioritization

**Context:** `IMAPProvider` is a Swift actor with a single IMAP connection per account. All operations (sync, body fetching, message opening) are serialized through the actor's queue. Background body fetching and backfill can block user-initiated `fetchMessage` calls for extended periods — the user taps a message and nothing happens until all background work finishes.

**Decision:**
1. **Cancellable background tasks** — Backfill tasks are stored and cancellable. When the user opens a message, background tasks for that account are cancelled immediately.
2. **Cooperative cancellation** — Background body fetch checks `Task.isCancelled` between each network call. On cancellation, it exits early, freeing the actor for user-initiated work.

**Rationale:**
- IMAP servers typically allow only one active command per connection
- Actor serialization means background work directly delays user actions
- Cancellation is cooperative in Swift — the loop must check and bail
- Users expect message opens to be instant; background work can wait

**Consequences:**
- Any new background work on the IMAP actor must follow the same cancellation pattern
- The cancel → action pattern applies to all user-initiated provider calls

---

## ADR-IOS-003: Pending Operation Queue for Crash Recovery

**Context:** ADR-IOS-001 requires self-healing on launch — detecting and retrying incomplete operations. Operations like archive, delete, and move modify both remote (IMAP/Gmail) and local (GRDB) state. If the app crashes between the remote operation succeeding and the local state update, the states drift permanently.

**Decision:**
1. **PendingOperation GRDB model** — Before any remote state-changing operation, insert a `PendingOperation` record. After success, delete it. Leftover records indicate operations that started but didn't complete.
2. **Launch reconciliation** — On app launch, before the first sync, query for `PendingOperation` records and retry them (up to 3 times). After max retries, discard the record.
3. **Optimistic UI with rollback** — `toggleRead` and `toggleFlag` update local state immediately. If the remote operation fails, the optimistic change is reverted and an error is shown. Archive/delete/move show errors but don't need rollback (local state only updates after remote success).

**Rationale:**
- Without a pending queue, crashed operations are invisible to the system
- Retry with a limit prevents infinite loops on permanently failing operations
- Optimistic UI rollback prevents local/remote state drift for flag operations

**Consequences:**
- Slight overhead per operation (two GRDB writes: insert + delete)

---

## ADR-IOS-004: ~~First Compute Wins for Cross-Instance Action Tags~~ (SUPERSEDED by ADR-IOS-036)

**Context:** Multiple TabMail instances (Thunderbird, iOS) can share the same IMAP account. When both instances process the same inbox message, both would independently compute the action via LLM, wasting tokens and potentially producing inconsistent results.

**Decision (superseded):** iOS / TB wrote `tm_*` IMAP keywords / Gmail labels / Exchange categories to the server so the other instance could adopt the tag on next sync without re-running the LLM.

**Why superseded:** Device Sync (the device-sync WSS relay) now exchanges `{summary, action, reply}` between connected peers via `ai_cache_probe` — this replaces the IMAP-keyword channel for the "both devices online" case. We accept losing async cross-device pickup (see ADR-IOS-036 tradeoff discussion). Removing the server-side label writes eliminates Gmail/Outlook/IMAP label-list pollution that users were seeing as `tm_reply` etc.

**Migration:** On-server `tm_*` keywords/labels from prior versions are left alone; they age out as inboxes churn. The iOS code no longer reads or writes them.

---

## ADR-IOS-005: Progressive Background Backfill

**Context:** Initial sync fetches only the latest N messages (50 inbox, 25 others) with a hardcoded 30-day age limit. Users with months of email history see a sparse mailbox. Opening a non-synced email could silently fail if the provider was disconnected.

**Decision:**
1. **Full sync depth** — Backfill always walks to completion: IMAP walks from UIDNEXT-1 to UID 1, Gmail/Exchange exhausts all pages. No date-based age cutoff — storage budget is the only gate.
2. **Progressive backfill** — After each initial sync, a background task fetches older messages. Uses IMAP UID range walking or Gmail `nextPageToken` pagination. Follows the same cooperative cancellation pattern as snippet fetching (ADR-IOS-002).
3. **Prioritized sync order** — Inbox first, then favorites, then secondary roles (sent/drafts/trash/archive/spam).
4. **No silent failures** — `fetchBody` throws descriptive errors instead of silently returning when provider/account is missing. Attempts reconnection if provider is nil.

**Rationale:**
- Users expect to see their full mailbox history, not just the latest 50
- Background backfill avoids blocking the initial sync/UI
- Cancellable backfill ensures user actions (opening messages) take priority
- Pure UID walk (no date-based cutoff) guarantees no messages are arbitrarily skipped — IMAP UIDs and message dates are not monotonically correlated

**Consequences:**
- Additional IMAP/API traffic after each sync cycle (one-time per folder until `backfillComplete`)
- `Folder.backfillComplete` and `Folder.oldestSyncedDate` track per-folder progress
- Backfill is cancelled alongside snippets before user-initiated provider calls

---

## ADR-IOS-006: Storage-Budget Retention with Progressive Crawling

**Context:** ADR-IOS-005 used age-based message eviction — messages older than `maxSyncAgeDays` were actively deleted during sync. This caused emails to disappear after being fetched, wasting bandwidth and confusing users. Users expect their mail client to keep downloaded messages, similar to Apple Mail which stores ~2GB of data.

**Decision:**
1. **No age-based eviction** — Once a message is fetched, it stays in local storage. Storage budget is the only limiting factor.
2. **Global storage budget** — `StorageEstimator.budgetMB` (UserDefaults, default 2048 = 2GB) is a global soft cap across all accounts. When exceeded, oldest messages are pruned across all accounts — bodies first (re-fetchable), then headers. Always keeps minimum 50 messages per folder.
3. **Complete backfill** — Backfill walks to completion (UID 1 for IMAP, last page for Gmail/Exchange). Storage budget gates whether backfill proceeds, but never prematurely marks folders as complete.
4. **Actual file size measurement** — `StorageEstimator` measures actual disk usage of GRDB database (`tabmail.sqlite` + WAL/SHM) and FTS files (`fts.db` + WAL/SHM) via recursive directory enumeration. No formula estimation.
5. **Infinite scroll** — When users scroll to the bottom of a mailbox, older messages are fetched on-demand via `fetchOlderMessages` regardless of age settings.
6. **50-message floor per folder** — Every folder always syncs at least 50 recent messages, regardless of age settings or storage budget.
7. **No body duplication** — `MessageBody` stores only `htmlContent` (plain-text-only emails are wrapped in HTML on ingest). FTS stores stripped plain text for search. No `textContent` field.

**Rationale:**
- Users don't expect fetched emails to disappear
- Apple Mail stores ~2GB — users accept this storage usage
- Progressive crawling fills storage naturally without aggressive initial downloads
- Actual file measurement is fast (3 `attributesOfItem` calls) and accurate
- Global budget is simpler UX (one setting in app settings) and matches single-file SQLite reality
- Eliminating `textContent` removes body duplication between main database and FTS
- Infinite scroll makes any historical email accessible without configuration

**Consequences:**
- Storage UI in SettingsView (global) shows actual usage and limit picker
- Pruning works globally across all accounts, oldest messages first
- Deep backfill increases IMAP/API traffic but runs at low priority with throttling

---

## ADR-IOS-007: Hybrid FTS5 + Vector Search (Local)

**Context:** Search was remote-first (IMAP SEARCH / Gmail API) with basic in-memory string matching for local results. This was slow, didn't search message bodies, had no stemming or synonyms, and required network connectivity. The Thunderbird extension had a mature Rust FTS library with FTS5, synonym expansion, and all-MiniLM-L6-v2 embeddings.

**Decision:**
1. **Separate SQLite FTS5 database** — `fts.db` in Application Support using GRDB, separate from the main app database (`tabmail.sqlite`).
2. **Query parser with synonym expansion** — Ported from Rust `query.rs`. Handles field aliases (`from:`→`from_:`), auto-wildcards for tokens ≥4 chars, OR groups for synonym expansion (~65 email synonym groups).
3. **CoreML embeddings** — all-MiniLM-L6-v2 converted to CoreML float16 (~45MB). Runs on Neural Engine when available. Bundled in app for offline support.
4. **Hybrid merge** — 70% semantic / 30% keyword scoring with candidate multiplier (4×). Minimum score threshold (0.1) filters noise.
5. **In-memory embedding matrix** — Loaded lazily on first semantic search. Uses Accelerate/vDSP for batch cosine similarity. Evicted on memory warnings.
6. **Incremental indexing** — Headers indexed via SyncEngine hooks on insert. Body text + embedding generated in AccountManager.fetchBody(). Background rebuild catches up existing messages.
7. **Graceful degradation** — If CoreML model/tokenizer not in bundle, falls back to FTS-only keyword search. If FTS index is empty, falls back to legacy string matching.

**Rationale:**
- Offline-capable search is essential for a mobile mail client
- FTS5 with Porter stemmer handles English morphology (searching "meeting" finds "meetings")
- Synonym expansion finds related concepts (searching "meeting" also finds "standup", "huddle", "sync")
- Semantic search finds conceptually similar messages even without keyword overlap
- CoreML + Neural Engine makes embedding inference practical on modern iPhones (~10ms per embedding)
- Porting from proven Rust implementation reduces risk vs. designing from scratch

**Consequences:**
- ~45MB added to app bundle (CoreML model) — acceptable, comparable to other ML features
- ~75MB additional on-device storage for embeddings (at 50K messages) — excluded from StorageEstimator
- Embedding generation is CPU/NPU-intensive — throttled to low priority, cooperative cancellation
- First-launch bulk indexing may take minutes for large mailboxes — runs in background
- GRDB adds a new dependency — well-maintained, widely used in iOS ecosystem

---

## ADR-IOS-008: AI Processing Must Replicate TB Addon Architecture

**Context:** The iOS app needs background AI processing (summary, action classification, cached reply generation). Rather than designing a new architecture, we must exactly replicate the Thunderbird addon's proven architecture, adapted to Swift/iOS idioms.

**Decision:**
1. **Exact replication** — All AI processing flows (summary, action, reply) must match the TB addon's architecture 1:1. The TB addon's `messageProcessorQueue.js`, `summaryGenerator.js`, `actionGenerator.js`, and `llm.js` are the authoritative reference implementations.
2. **Persistent processing queue** — Messages awaiting AI processing are stored in a persistent queue (GRDB model) that survives app suspension/termination. Restored on launch.
3. **Event-driven enqueue** — Messages are enqueued for processing on: new mail arrival (post-sync), message moved to inbox, and startup scan of recent untagged inbox messages.
4. **Drain loop with watchdog** — A periodic timer (watchdog) drains the queue in batches. Processing failures trigger a retry timer with backoff. The queue is persisted on app backgrounding.
5. **Per-message semaphores** — Prevent concurrent AI generation for the same message. If a summary is already being generated for message X, other requestors wait for the result.
6. **Global LLM concurrency limit** — A semaphore limits total concurrent backend API calls (prevent overload). Priority/user-initiated requests can bypass the semaphore.
7. **Caching with TTL** — AI results (summary, action) are cached in database fields with generation timestamps. Expired results can be recomputed. Cache is checked before any LLM call.
8. **First-compute-wins** — Before LLM action generation, check IMAP keywords / Gmail labels (per ADR-IOS-004). If found, adopt without LLM.
9. **Three-call action voting** — Action classification makes N parallel calls and takes the mode (most common action), matching TB's voting mechanism.

**Rationale:**
- TB's architecture is battle-tested in production with thousands of users
- Consistent behavior across platforms reduces user confusion
- Persistent queue ensures no messages are missed across app lifecycle events
- Concurrency control prevents backend overload and duplicate work
- Replicating rather than redesigning eliminates architectural risk

**Consequences:**
- iOS AI code must be kept in sync with TB addon changes (same flow, same edge cases)
- When modifying AI flows, always check the TB reference implementation first
- New AI features must be designed for both platforms simultaneously
- Slightly more complex than a naive implementation, but dramatically more reliable

---

## ADR-IOS-009: Two-Tier Delta + Full Sync

**Context:** Sync ran a full sync every 60 seconds — fetching all messages, diffing against local state, updating folders. This was slow and wasteful, especially for accounts with many folders. Gmail's `history.list` API was previously tried but abandoned because the `historyId` cursor expires after ~7 days. IMAP had no incremental sync at all.

**Decision:**
1. **Delta sync (frequent, every 60s)** — Lightweight check for changes since last sync. Gmail uses `history.list` with `lastHistoryId` cursor. IMAP uses `STATUS` command per folder to compare `uidNext` and `messageCount` against cached values.
2. **Full sync (periodic, every 10 min)** — Safety net and self-healing. Runs the existing `fullSync()` with complete message diffing. Also captures fresh sync cursors (Gmail historyId, IMAP uidNext per folder).
3. **Graceful fallback** — If delta sync fails for any reason (Gmail 404 expired cursor, IMAP errors, missing cursors), falls through to full sync automatically. The expired historyId is cleared so the next full sync captures a fresh one.
4. **Cursor management** — Gmail: `Account.lastHistoryId` captured after full sync via `getCurrentHistoryId()`. IMAP: `Folder.lastKnownUidNext` captured from `FolderInfo.uidNext` during full sync.

**Rationale:**
- Full sync every 60s is unnecessarily expensive — most polls find zero changes
- Gmail history expiry (~7 days) isn't catastrophic if handled as a fallback trigger
- IMAP `STATUS` is cheap (no `SELECT` needed) and reliably detects new/deleted messages
- Two-tier approach gives fast responsiveness (delta) with guaranteed consistency (periodic full)
- Background tasks (snippets, backfill, AI) only run after full syncs — delta is fast-path only

**Consequences:**
- Delta sync skips background work (snippets, backfill, AI processing) — these run after full syncs
- Gmail delta sync processes message adds/deletes/label changes individually (more API calls per changed message, but rare)
- IMAP delta still runs `syncMessages()` for changed folders — STATUS only detects change, not what changed
- New model fields: `Account.lastFullSyncAt`, `Folder.lastKnownUidNext`, `FolderInfo.uidNext`
- `GmailProvider.fetchHistory` returns nil on 404 instead of throwing

---

## ADR-IOS-010: Device Always-On Sync with AI Cache Probe

**Context:** Prompt settings (composition, action rules, knowledge base, templates) were manually synced between TB and iOS. AI processing (summary + action) ran independently on each device, duplicating LLM calls for the same emails. Backend KV cache was rejected per ADR-004 (zero server-side data retention).

**Decision:**
1. **Always-on Device Sync** — WebSocket connection to Cloudflare Durable Object relay. Auto-connects on launch, reconnects on foreground, disconnects on background. No manual send/receive buttons.
2. **Per-field timestamp merge** — Each field (composition, action, kb, templates) has its own `updated_at` timestamp. Incoming field applied only if timestamp > local. Prevents newer edits from being overwritten.
3. **AI cache probe before LLM** — Before running LLM for a message, probe connected peers for cached results via WebSocket relay. 2-second timeout. If hit, skip LLM entirely.
4. **RFC 2822 Message-ID as probe key** — Both iOS and TB use the RFC Message-ID header (angle brackets stripped) as the device-independent cache key. iOS stores this in `MessageHeader.rfc822MessageId`.
5. **Consecutive timeout optimization** — After 2 consecutive probe timeouts (no peer connected), skip future probes silently. Reset counter when any peer message is received.
6. **Backup before merge** — Current state saved to UserDefaults ring buffer (max 10) before applying incoming sync.

**Rationale:**
- Pure sync relay — no user data stored on server (ADR-004 compliance)
- DO with WebSocket Hibernation API costs ~$0.001/user/month
- AI cache probe saves $6-75/user/month in LLM costs
- RFC Message-ID is the only device-independent email identifier (UIDs, Gmail IDs are provider-specific)
- Consecutive timeout optimization avoids 2s latency per message when no peer is connected

**Consequences:**
- `rfc822MessageId` may be nil for some messages (IMAP servers with no ENVELOPE Message-ID) — probe gracefully skipped
- `rfc822MessageId` field on MessageHeader — existing messages get nil until re-synced
- WebSocket connection adds minor battery/network overhead — mitigated by hibernation (idle pings auto-responded without waking DO)
- Gmail metadata fetch now requests `Message-Id` header (one extra header per API call — negligible)

---

## ADR-IOS-011: ActionTag Raw Values Are Plain Names

**Context:** See global ADR-022. ActionTag raw values were `"tm_delete"` (IMAP keyword format), causing Device Sync mismatches with TB which uses `"delete"` internally.

**Decision:** Changed `ActionTag` raw values to plain names (`"delete"`, `"archive"`, `"reply"`, `"none"`). Added `imapKeyword` computed property and `fromIMAPKeyword()` for IMAP/Gmail boundary conversion.

**Rationale:** Unifies internal storage format with TB. Eliminates transport-layer naming from application logic.

**Consequences:**
- `ActionTag.rawValue` is now the canonical format for Device Sync, database, and all internal use
- Use `tag.imapKeyword` when writing IMAP flags or Gmail labels
- Use `ActionTag.fromIMAPKeyword()` when reading IMAP flags or Gmail labels

---

## ADR-IOS-012: ~~Inbox Excluded from Stale Detection~~ (SUPERSEDED)

**Status:** Superseded — inbox stale detection is now enabled for all folders.

**Original context:** Concern that UIDVALIDITY changes could cause mass false-positive staleness, wiping AI state.

**Why superseded:** `MessageAICache` already preserves AI state (summary, action) for re-inserted messages via `restoreIfCached()`. The overlap-window approach limits stale detection to the date range covered by fetched messages, preventing mass deletion. Without inbox stale detection, messages moved out of inbox on the server persisted locally indefinitely — IMAP delta sync detected the change but never cleaned up the stale local copies.

**Current behavior:** All folders including inbox use the same stale detection logic (overlap-window when fetched count >= limit, full comparison otherwise).

---

## ADR-IOS-013: Direct Priority Path for Opened Emails

**Context:** TB addon processes the currently-displayed email via a direct inline path (`onMessagesDisplayed` → `getSummary()` → `getAction()`), bypassing the background queue entirely. This ensures the user sees AI results immediately when opening an email, without waiting behind other queued messages.

**Decision:** Added `processOpenedMessage()` public method to AccountManager. When the user opens a message in MessageDetailView and the body is already loaded, this direct path triggers AI processing immediately. It bypasses the background queue (matches TB's `processVisibleMessages` architecture). Per-message dedup in AIService prevents duplicate LLM calls if the queue also picks up the same message.

**Rationale:**
- ADR-IOS-008 requires exact replication of TB addon architecture
- TB uses dual-path: direct for displayed email, queue for background batch
- User should see AI results immediately when opening an email

**Consequences:**
- `processOpenedMessage()` runs outside the semaphore-gated queue
- AIService's first-compute-wins dedup prevents duplicate processing
- Body-fetch path (fetchBody → processMessage) still handles the case where body is fetched on open

---

## ADR-IOS-014: IMAP Connection Pool (supersedes serial lock)

**Context:** IMAP operations were serialized by a single lock on one TCP connection. This prevented concurrent operations (e.g., a user archiving a message while backfill fetches headers) even though IMAP servers support multiple concurrent connections (e.g., 15 for Gmail). Move/tag/mark operations blocked behind background work despite using priority lock.

**Decision:** Replaced the serial lock AND temporary connection infrastructure with `IMAPConnectionPool` — an actor managing a pool of logged-in IMAP connections. Operations checkout a connection via `withPoolConnection(priority:) { server in ... }`, SELECT their mailbox independently, and return the connection on completion. The pool handles:
- **Priority checkout**: user ops jump the waiter queue (preserves ADR-IOS-002 intent)
- **Adaptive concurrency**: detects server limits from `mail_max_userip_connections=N` rejections, cooldown on full failure, gradual recovery
- **Connection reuse**: idle connections persist across operations (no create/destroy per batch)
- **Liveness checks**: NOOP before reuse if idle > 2 minutes
- **Batch checkout**: `checkoutBatch(count:)` for parallel body fetch (replaces `createTempConnections`)

**Rationale:**
- IMAP servers allow multiple concurrent connections — serialization was unnecessary overhead
- Connection pool amortizes TCP+TLS+LOGIN cost across operations
- Pool unifies the two separate concurrency mechanisms (serial lock + temp connections) into one
- Actor isolation on the pool eliminates the race conditions that a class-based pool would have

**Consequences:**
- Multiple IMAP operations for an account can execute concurrently on separate connections
- Background tasks no longer block user actions (each gets its own connection)
- Body fetch connections return to pool for reuse instead of being destroyed after each batch
- Pool actor + IMAPProvider actor = two actor hops per operation (negligible overhead — pool methods are microsecond-fast)

---

## ADR-IOS-015: Three-Tier Background Execution for AI Processing

**Context:** AI processing calls (summary, action, future tool-enabled chat) can take 60+ seconds, especially with multi-turn tool execution loops. iOS suspends apps within ~5 seconds of backgrounding. Without protection, all in-flight AI work is lost (though idempotent design means messages re-queue on next sync, wasting LLM tokens). The existing `BGAppRefreshTask` (Tier 2) only provides ~15-60s — insufficient for long AI calls.

**Decision:**
1. **Tier 2 (existing):** `BGAppRefreshTask` (`ai.tabmail.sync`) — lightweight sync polling + embeddings (15-60s budget).
2. **Tier 3 (new):** `BGProcessingTask` (`ai.tabmail.ai-processing`) — long-running AI processing (up to ~10 min). Requires network connectivity, no external power required. Scheduled on app background with 5 min earliest begin date. Runs: sync → AI processing for all accounts → embeddings → badge update.
3. **`beginBackgroundTask`:** Wraps both `processMessagesForAccount` (queue path) and `processMessage` (priority path) to protect in-flight AI calls with ~30s grace period on backgrounding.
4. **SSE streaming with tool execution loop:** `BackendClient.sendCompletionsWithTools()` implements multi-turn tool execution matching TB's architecture. Parses full SSE event stream, executes client-side tools via `ToolRegistry`, manages `conversation_state` across rounds.
5. **Tool scaffold:** `AgentTool` protocol + `ToolRegistry` actor. No implementations yet — tools added incrementally.

**Rationale:**
- `BGProcessingTask` grants up to ~10 minutes — sufficient for batch AI processing with tool loops
- `beginBackgroundTask` is a quick-win safety net (~30s) for single in-flight calls
- Tool execution loop matches TB's proven architecture (ADR-IOS-008 compliance)
- Existing summary/action pipeline untouched (still uses simpler `sendCompletions`)

**Consequences:**
- `processing` added to `UIBackgroundModes` in Info.plist
- iOS decides when to run `BGProcessingTask` (not immediate — best-effort scheduling)
- Tool-enabled features (chat, reply precompute) use `sendCompletionsWithTools`; summary/action use `sendCompletions`
- When adding tools, register them in `ToolRegistry` at app startup

---

## ADR-IOS-016: ~~PersistenceGateway — Coalesced SwiftData Saves~~ (SUPERSEDED)

**Status:** Superseded — no longer applicable after migration from SwiftData to GRDB.

**Why superseded:** GRDB's `DatabasePool` writes are immediate and thread-safe. There is no `@Query` re-evaluation, no `autosaveEnabled`, and no `ModelContext` to manage. The "render storm" problem was SwiftData-specific (`@Query` change notifications on every `save()`). With GRDB, UI updates are explicit via `NavigationStore` (GRDB `ValueObservation`), which doesn't suffer from the same issue. The `PersistenceGateway` class, `setNeedsSave()`, `awaitSave()`, and `saveNow()` have all been removed.

---

## ADR-IOS-017: ~~Remove Folder→MessageHeader @Relationship~~ (SUPERSEDED)

**Status:** Superseded — no longer applicable after migration from SwiftData to GRDB.

**Why superseded:** GRDB uses explicit SQL foreign keys, not ORM-managed inverse relationships. The `messageHeader` table has a `folderId` foreign key with `ON DELETE CASCADE` — the database engine handles cascade deletes automatically. There is no inverse materialization problem because GRDB never eagerly loads related objects. Queries use `Column("folderId") == fid` directly.

---

## ADR-IOS-018: Persistent Offline Action Queue

> **Partially superseded by ADR-IOS-060 (2026-07-13).** Retained: optimistic local mutation, durable execution, drain triggers, sync protection, and authoritative stale/no-op handling. Superseded: connected-component/per-account parallel lanes, batch splitting, retry-cap stale classification, status/token/snapshot Undo cancellation, provider-aware move-back recovery, and durable action-tag queuing. Message actions now target one global one-job-at-a-time FIFO with account embedded in each job.

> **Historical record:** The numbered decision, rationale, consequences, and later amendments below describe the pre-ADR-IOS-060 implementation. In particular, the `setTag`/`removeTag` queue support, the "Tag queue" decision, and tag-before-move FIFO consequences are historical; action tags are local-only under ADR-IOS-060. Remote user-label set/unset operations remain ordinary provider-neutral queue jobs.

**Context:** Archive/delete/move actions previously updated local state only after remote success. If the user was offline or the connection dropped, actions failed with an error message and the user's intent was lost. This was inconsistent with ADR-IOS-001 (optimistic UI) which specifies immediate local updates.

**Decision:**
1. **All user actions are optimistic** — archive, delete, move, read, flag, and tag update local state immediately. The remote operation is queued in `PendingOperation` (GRDB) for async execution.
2. **Persistent queue** — `PendingOperation` now tracks `status` (queued/inFlight) and supports `setTag`/`removeTag` operation types. Operations survive app kill and are drained on launch, network restore, foreground return, and after each sync poll.
3. **Network monitoring** — `NetworkMonitor` (NWPathMonitor wrapper) detects connectivity changes and triggers queue drain on reconnect.
4. **Conflict detection** — When executing a queued destructive op (archive/delete/move), if the server returns "message not found" (already moved/deleted by another client), the queued op is silently dropped (server wins).
5. **Sync protection** — During delta/full sync, messages with pending operations are not re-inserted (prevents optimistic UI "flash" where archived messages temporarily reappear) and not deleted (lets queue execute first).
6. **Tag queue** — AI background tag writes and manual tag overrides go through the same queue, replacing the fire-and-forget `writeActionTagWithRetry` pattern. FIFO ordering ensures tag removal happens before archive/delete.
7. **Undo integration** — Undo first attempts to cancel the queued operation. If still queued, local state is restored directly. If already executed on server, a counter-operation (move-back) is queued.

**Rationale:** Users expect actions to be instant and resilient. Queuing operations makes the app functional during airplane mode, poor connectivity, and IMAP connection drops (which happen after device sleep). The queue also provides crash recovery (supersedes the old trackPending/completePending pattern).

**Consequences:**
- Actions never fail from the user's perspective — worst case, they execute on next reconnect
- AccountManager action methods are now synchronous (no async/throws) — simpler call sites
- ViewModels no longer need error handling or rollback logic for message actions
- Queue drain order matters: tag removals must precede archive/delete (FIFO guaranteed)
- Stale pending ops (provider removed, message gone) are cleaned up within 5 retries

**Amendment (2026-07-10) — connected-component lanes + uidResolutionFailed is transient (PLAN_OVERLAY_CALLSITE_AUDIT.md §6 follow-ups).** Two drain-semantics fixes:
1. **Lanes are keyed by connected components over ALL member ids, not `messageIds.first`** (`AccountManager.buildLanes`, pure/unit-tested). The old first-id key let a batch move `[A,B,C]` and a later single-id flag op on B land in SEPARATE lanes that ran concurrently on separate IMAP connections (`ProviderWorkQueue` is bounded-concurrency, not serial) — the flag STORE raced the MOVE of the same message and was lost on EXPUNGE or wrongly confirmed-stale mid-move. Any two ops sharing any member id now serialize in one FIFO lane (createdAt order preserved).
2. **`uidResolutionFailed` on non-move, non-tag ops retries with a cap instead of dropping.** `IMAPProvider.resolveUID`'s documented contract ("message likely exists but SEARCH couldn't find it… treats this as transient") was honored only for `.move` (destination-check) and tag ops (best-effort by design); every other type was unconditionally dropped as "confirmed stale" — discarding user intention on a false-negative SEARCH. Now: retry up to `SyncConfig.maxUidResolutionRetries`, then confirmed-stale drop. Additionally, `executeSingleOp` returns `SingleOpOutcome` and the lane loop **halts the remainder of a lane** whenever an op is re-queued for retry (`.haltLane`) — a later op on the same connected component must never run ahead of its unresolved predecessor (that run-early mechanism is exactly how the wrongly-dropped flag ops were reached). `failedAccounts` semantics unchanged. Also (ADR-IOS-036 interplay): `optimisticMoveToFolder` no longer enqueues the legacy `.removeTag` op — tags are local-only, so the clear happens in the same optimistic `updateAll` as the move (the `.setTag`/`.removeTag` drain case stays as a legacy-row flush no-op), making the "tag removals precede archive/delete" FIFO consequence above moot for action tags. Tests: `PendingQueueLaneTests` (pure lane grouping) and `AccountManagerQueueDrainTests` (real `executeSingleOp` outcome/retry/cap/lane-halt and end-to-end `drainPendingQueue`). The former hand-simulated `DrainQueueIntegrationTests` suite was deleted in round 52 because it tested a copied, obsolete algorithm rather than production.

**Follow-up fix (same day, 2026-07-10) — two audit-caught regressions in the above amendment:**
(a) **Batch-split ops lost the original `createdAt`.** Both split sites (`messageNotFound`, `uidResolutionFailed`) constructed replacement single-message ops via `PendingOperation(...)`, whose init stamps `createdAt = Date()` — later than a same-lane sibling op queued between the batch and the split, starving the split op behind it on every later `buildLanes` pass (violates the createdAt-order invariant lanes depend on). Fixed by copying `currentOp.createdAt` onto each split op before insert — split ops are the SAME user intention, re-shaped, so they keep the original queue position.
(b) **The retry cap read the SHARED `retryCount`**, which the generic transient-error branch (bottom of `executeSingleOp`'s catch) also increments on every ordinary connection blip — a few unrelated blips could pre-exhaust `SyncConfig.maxUidResolutionRetries` before the op's first real SEARCH miss, triggering a false "confirmed stale" drop (dropping user intention, the exact failure mode item 2 above was meant to fix). Fixed with a genuinely DEDICATED counter: `PendingOperation.uidResolutionRetryCount` (v67 migration, `ALTER TABLE pendingOperation ADD COLUMN uidResolutionRetryCount INTEGER NOT NULL DEFAULT 0`) — only the `uidResolutionFailed` non-move/non-tag branch reads/increments it; the generic branch keeps bumping `retryCount` as before (diagnostic only). Batch-split ops deliberately get a FRESH counter (each member earns its own confirmation cycle; a batch can only split once, so there is no reset-the-budget loop). Tests: `AccountManagerQueueDrainTests` (contamination regression, cap-on-dedicated-counter, split-preserves-createdAt for both split sites), `DatabaseMigrationTests` (v67 column), `PendingOperationPersistenceTests` (independent round-trip of both counters).

**Notification-action revival (2026-07-10, audit rounds 2–3 of the same follow-up session).** The notification action buttons' backing writes had been silently dead since 2026-05-30: the handlers' raw SQL INSERT targeted a nonexistent column (`messageIds` — schema says `messageIdsJSON`) and omitted NOT-NULL `folderPath`/`createdAt`, so it always threw (catch merely logged) — and even a successful insert would have queued `.archive`/`.delete` `OperationType`s, which are legacy NO-OPS in the drain (all modern ops are `.move`). Net effect: tapping Archive/Delete on a notification dropped the user's intention outright; MARK_READ's header-not-local fallback was equally dead. Replaced with `NotificationActionRouter` (AppDelegate.swift): (1) durable header lookup **scoped to `isInInbox = 1`** — IMAP UIDs are folder-scoped (`MessageIdentity.headerId` embeds folderPath for this reason), so an unscoped `(messageId, accountId)` match could archive/delete an unrelated same-UID row in another folder; notification actions are inbox-arrival semantics. (2) In-memory staged-row fallback (`NSEDataBridge.latestStagedRows`). (3) On a full miss, ONE `NSEMergeCoordinator.merge()` (the `ensureDurable` call) pulls disk-staged rows durable and the lookup re-runs — a cold background launch has an empty in-memory cache but the staging TABLE persists. (4) ARCHIVE/DELETE dispatch via `performCoordinatedRoleMove` (overlay + FIFO + fresh re-resolve — same coordination as agent tools); MARK_READ via the batch `markRead` (outside the register per ADR-IOS-057). (5) Only if no header is resolvable anywhere: a record-typed cold `PendingOperation` (`.markRead`, or `.move` with the role-folder destination) against the account's inbox path — never raw SQL. Accepted residual (documented at the site): the cold `.move` carries the raw numeric UID, which skips rfc822 verification in the drain; safe within a UIDVALIDITY generation (UIDs are never reused — `resolveUID` short-circuits numeric ids straight to a UIDSet without SEARCH, so a stale UID reaches the server as a UID-addressed command matching no message, which IMAP servers no-op), wrong-target requires a UIDVALIDITY change between push and drain (rare; triggers a resync anyway), and dropping the tap instead would violate never-drop-user-intention. **Second accepted residual (audit round 4):** a message that already LEFT the inbox before the tap (moved by another client or an earlier sync) misses the inbox-scoped lookup and falls to the cold path, whose inbox-targeted op no-ops on IMAP — the action is dropped rather than applied to the moved row. Deliberate: the notification action is inbox-triage semantics on an inbox arrival; a message that left the inbox first was already handled by a later action, and the conflict rule (core philosophy §4, server/other-client wins) applies — the unscoped alternative is exactly the wrong-row destructive hazard this scoping fixes. Gmail/Exchange converge regardless (id-based remote ops). Also noted: ARCHIVE/DELETE now await coordinated durable completion inside the `notification-action` `beginBackgroundWork` bracket — a longer window than the old single write, extending (not creating) ADR-IOS-057's accepted crash/kill residual into this background context. **Suggested-action categories (same day):** the NSE stamps `categoryIdentifier` per AI action tag (`EmailNotificationBuilder.categoryIdentifier(forActionTag:)`) — `archive`/`delete` tags get `EMAIL_TAG_*` categories whose long-press sheet lists the suggested action FIRST, titled "(Suggested)"; `reply`/`none`/nil stay on the generic `EMAIL` category (user decision: reply has no notification-actionable equivalent yet). Action IDENTIFIERS are identical across categories, so the router is category-blind. Tests: `NotificationActionRouterTests` (durable dispatch incl. overlay-drain, same-UID-two-folders wrong-row regression, cold fallbacks) + `EmailNotificationBuilderTests` (category mapping + fill stamping).

**RFC-identity amendment (2026-07-13; ADR-IOS-060).** The raw-provider-ID cold-path residual above is superseded and rejected. APNs may still carry the provider ID for immediate lookup, but any actionable payload also carries normalized RFC Message-ID. Legacy payloads recover RFC identity only from exactly one account-scoped inbox match across the combined durable and staged tiers; zero, multiple, or cross-tier-conflicting matches no-op. A true cold miss queues only the supplied valid RFC identity against authoritative nonblank account/inbox scope. Durable/staged exact duplicates are deduplicated by header ID; distinct matches are ambiguous. Notification actions therefore use the same provider-neutral admission boundary as every other producer and never persist the transport ID.

**Audit round 4 (2026-07-10) — batch-split outcome was still `.proceed`, letting a later same-lane op run ahead of the un-executed split children.** Both `executeSingleOp` split sites (`messageNotFound`, `uidResolutionFailed`) returned `.proceed` after inserting the split singles, so a chained same-lane op (e.g. a lane `[move([A,B] INBOX→ARCHIVE), move([B] ARCHIVE→TRASH)]`) ran in the SAME pass, ahead of its unresolved split sibling — the chained op's SEARCH missed B in ARCHIVE (still sitting in INBOX pending its own split's drain), the destination-check found it in neither source nor destination, and it was wrongly confirmed-stale and dropped, permanently losing the user's delete. Both split sites now `return .haltLane` — same never-run-ahead invariant as the retry paths above; the lane loop requeues the rest of the lane so it serializes behind the split ops on a later pass. Test: `AccountManagerQueueDrainTests.laneHaltsAfterBatchSplitBlocksChainedOp` (also updated the two existing split-`createdAt` tests' outcome assertion from `.proceed` to `.haltLane`).

**Audit round 4 (2026-07-10) — `AccountManager.move()` trusted the caller's (possibly stale) `MessageHeader` snapshot instead of row truth.** Gesture paths capture a `lookupMessage` snapshot at tap time and pass it into a queued closure; a second destination-changing gesture on the same message before the first closure commits recorded a `PendingOperation` against the STALE source `folderPath` — on IMAP the drain then SEARCHes the wrong folder, hits `uidResolutionFailed`, and the destination-check wrongly confirms it stale and drops it (same failure class as the split-ordering bug above, different cause). Fixed at the single choke point: `move()` now re-resolves fresh headers by id (`resolveHeadersForAction(ids: messages.map(\.id))`) FIRST and runs its same-folder no-op filter and the rest of the function on the fresh result; ids that no longer resolve (vanished rows) are dropped from the batch. `performCoordinatedRoleMove`'s own in-closure re-resolve is unaffected (now a harmless double resolve). Test: `AccountManagerActionsTagClearTests.moveReResolvesFreshHeaderOverStaleCallerSnapshot`.

**Audit round 4 (2026-07-10) — `SettingsView.archiveOldMessages` was a 7th `UndoService.push` producer with the stale-snapshot bug ADR-IOS-057 fixed at the 6 inbox gesture sites.** Its raw `fetchAll` snapshot went straight into `UndoService.push`, so a still-queued gesture cycle's `isRead`/`isFlagged`/`actionTag` would be silently reverted by undo. `InboxViewModel.overlayAdjustedForUndo`'s body is now promoted to `AccountManager.overlayAdjustedSnapshot(_:)` (same overlay-read logic, `nonisolated`); `InboxViewModel`'s private helper is a one-line wrapper (all 6 gesture call sites unchanged); `archiveOldMessages` maps its per-account messages through it for the `UndoableAction` only (the `manager.move` call keeps the raw structs — moot anyway now that `move()` re-resolves fresh headers, per the fix above). Test: `AccountManagerActionsTagClearTests.overlayAdjustedSnapshotPicksUpQueuedTagIntent`.

---

## ADR-IOS-019: Outbox — Persistent Offline Send Queue

**Context:** Email sending was synchronous — `AccountManager.send()` directly called `provider.send(draft:)`. If offline, the send failed with an error and the user's composed message was lost. This was inconsistent with ADR-IOS-018 (all actions go through a persistent queue) and ADR-IOS-001 (optimistic UI). Users expected to compose and "send" even without connectivity.

**Decision:**
1. **OutboxMessage GRDB model** — `outboxMessage` table persists the full draft (recipients, subject, body, isHTML, inReplyTo, references) with status (queued/sending/failed) and `sentAt` timestamp. Attachments stored on disk under `Application Support/TabMail/outbox_attachments/{id}/` (not in DB — avoids blob bloat). v3 migration adds the table, v4 adds `sentAt`.
2. **Always queue, never direct send** — `ComposeView.send()` calls `AccountManager.queueSend()` which persists to GRDB + disk, then fires `drainOutbox()` async. ComposeView dismisses only on success. If persistence fails, error is shown and compose stays open.
3. **drainOutbox() pattern** — Mirrors `drainPendingQueue()`: isDrainingOutbox guard, NetworkMonitor gate, FIFO by createdAt, marks `sending` before attempt. Messages are sent in parallel — each gets its own Task, with provider-level concurrency managed by PriorityWorkQueue. A failure for one account does not block other accounts or messages. Only processes `.queued` messages — `.failed` requires explicit user Retry. Max 3 passes.
4. **Drain triggers** — NetworkMonitor reconnect, app launch (reconcileOutbox), after queueSend, after discardOutboxMessage (so remaining queued messages proceed immediately), SyncScheduler foreground polling + after each poll.
5. **Post-send: Sent folder append** — After `provider.send()` succeeds: (1) stamp `sentAt` timestamp, (2) attempt IMAP APPEND to Sent folder with dedup check, (3) on success: delete from DB + update isReplied/isForwarded + delete attachments. Gmail/Exchange auto-save to Sent — their `appendToSentFolder` is a no-op. IMAP requires explicit APPEND because SMTP only delivers; it does NOT store a copy on the sender's server.
6. **Message-ID pre-generation** — Before SMTP send, a stable RFC822 Message-ID is generated and persisted to `outboxMessage.sentMessageId`. Both SMTP send and IMAP APPEND use this same ID (via `DraftMessage.messageId` → `Email.additionalHeaders["Message-Id"]`). On retry, the Sent folder is searched by `HEADER Message-ID <id>` to prevent duplicate appends.
7. **Persistent Sent append** — If the IMAP APPEND fails (connection drop, app kill), the outbox message stays with `sentAt != nil` and `appendedToSent == false`. `drainPendingSentAppends()` retries on next drain cycle. The message is only finalized (deleted + flags updated) when BOTH send and append succeed. v18 migration adds `sentMessageId` and `appendedToSent` columns.
8. **Crash recovery (reconcileOutbox)** — On launch: messages with `sentAt != nil` AND `appendedToSent == true` → delete (fully completed). Messages with `sentAt != nil` AND `appendedToSent == false` → keep for append retry (already sent, don't re-send). Messages with `sentAt == nil` and status `sending` → reset to `queued` (retry). Also cleans orphaned attachment dirs.
9. **Auto-retry + escalation** — Transient failures (retryCount < 3) keep status as `queued` for automatic retry on next drain. Persistent failures (retryCount >= 3) mark as `failed` — user must tap Retry (which resets retryCount to 0 for a fresh set of attempts).
8. **User actions** — Retry: resets failed→queued + retryCount→0, triggers drain. Discard: atomic fetch+delete in single write transaction, refused if status==sending.
9. **Reactive UI** — `NavigationStore` observes `outboxMessage` table via GRDB `ValueObservation`. Sidebar shows "Outbox" in unified section + per-account sections, with count badge (red if failures). `OutboxView` hides discard button for sending messages.

**Core reliability philosophy — a dropped send or double-send is near end-of-product:**

- **Never drop a message.** `queueSend` throws on failure. ComposeView MUST show the error and NOT dismiss. The compose view is the user's last chance to preserve their message.
- **Never `try?` on state transitions.** Every DB write that changes outbox status (queued→sending, sending→failed, success→delete) MUST use `do/catch` with retries (3 attempts, 100ms backoff). A silently swallowed failure leads to message loss or double-send via crash recovery.
- **`sentAt` before delete.** After successful send, stamp `sentAt` BEFORE attempting the delete. If the app crashes between send-success and delete, `reconcileOutbox` sees `sentAt != nil` → deletes (not re-queues). Without this marker, the message would be re-sent.
- **Prefer double-send over drop.** The two-generals problem is inherent. When in doubt (crash mid-send, no sentAt), we re-queue and retry. A rare duplicate email is vastly preferable to a silently lost message.
- **No silent data corruption.** `loadAttachments()` throws if ANY file can't be read. Never send an email with missing attachments — mark as failed with a clear error instead.
- **File I/O outside DB transactions.** Attachment disk operations (delete, cleanup) MUST happen outside write transactions. File I/O failure inside a transaction rolls back the DB changes.
- **No auto-discard, ever.** Outbox messages are NEVER automatically deleted. Failed messages stay visible until the user explicitly discards. The user always has agency.

**Rationale:** Matches the established pattern from ADR-IOS-018. Users expect "send" to succeed instantly regardless of connectivity. The outbox completes the "every user change is recorded and executed upon connection" guarantee. Attachments on disk avoid GRDB row size bloat. The reliability philosophy reflects that email sending is the single highest-stakes operation — a lost email can mean lost business, lost relationships, lost trust.

**Consequences:**
- Sends never fail from the user's perspective — worst case, they execute on next reconnect
- ComposeView only dismisses after successful persistence — never before
- Failed sends stay visible in Outbox UI with error + retry/discard options
- Auto-retry handles transient errors (3 attempts) before bothering the user
- `sentAt` marker closes the main double-send crash window (irreducible ~microsecond gap remains between provider.send() and sentAt write — inherent two-generals problem)
- Orphaned attachment dirs cleaned on every app launch
- Account deletion cascades via FK — attachment dirs cleaned before cascade

---

## ADR-IOS-020: Swift 6 BGTask Handler Isolation Pattern

**Context:** `SyncScheduler` is a `@MainActor` class. `BGAppRefreshTask` and `BGProcessingTask` expiration handlers run on arbitrary Apple-internal threads. In Swift 6 strict concurrency, ALL local variables in a `@MainActor` method are main-actor-isolated — accessing them from `@Sendable` expiration handler closures triggers a dynamic isolation trap (`EXC_BREAKPOINT` at runtime), even for inherently thread-safe types like `Mutex<Bool>`. `nonisolated(unsafe)` on local variables does not prevent this (only works on stored properties per SE-0412). Additionally, `NWPathMonitor.pathUpdateHandler` can fire multiple times racing with `cancel()`, causing `CheckedContinuation` double-resume crashes.

**Decision:**
1. **`nonisolated func` on BGTask handler methods** — Strips actor isolation from ALL method locals, allowing them to be freely captured in `@Sendable` closures. The actual work runs inside `Task { @MainActor in }`.
2. **`BGTaskContext` class (`@unchecked Sendable`)** — Holds shared state (expired flag, processing task reference) between the expiration handler and the processing Task. Uses `NSLock` for internal synchronization. `@unchecked Sendable` lets it be captured across isolation domains without triggering region-based sending errors.
3. **`@preconcurrency import BackgroundTasks`** — Downgrades strict Sendable checking for `BGTask`/`BGProcessingTask` (ObjC types lacking proper annotations), preventing "sending risks causing data races" errors.
4. **Use-then-send ordering** — Set `task.expirationHandler` BEFORE creating the `Task { @MainActor in }` closure that captures `task`. This satisfies Swift 6's region-based "no use after send" rule (SE-0414).
5. **`Mutex<Bool>` guard in `isOnWiFi()`** — Prevents `CheckedContinuation` double-resume when `NWPathMonitor.pathUpdateHandler` fires multiple times racing with `cancel()`.
6. **Only `Task { @MainActor in }` body calls `setTaskCompleted`** — The expiration handler NEVER calls BGTask methods directly. It only sets the expired flag and cancels the processing task. The processing task checks the flag and calls `setTaskCompleted` itself.

**Rationale:**
- Swift 6 runtime isolation checking is stricter than compile-time checks — code that compiles can still crash at runtime
- `Mutex<Bool>` and `Task` are `Sendable`, but Swift 6 isolates them to the actor context of the enclosing method
- `nonisolated(unsafe)` only prevents compile-time errors on stored properties, not runtime isolation traps on locals
- `@unchecked Sendable` on a class with NSLock is the established pattern for cross-isolation shared state
- BGTask's ObjC types don't conform to `Sendable` — `@preconcurrency` is the approved workaround

**Consequences:**
- All BGTask handler methods must be `nonisolated func` — never `@MainActor`
- Shared state between expiration handler and processing task must go through `BGTaskContext` (or similar `@unchecked Sendable` class)
- Any new `CheckedContinuation` with callback-based APIs needs a `Mutex<Bool>` resume guard
- The pattern is more verbose but eliminates an entire class of runtime crashes

---

## ADR-IOS-021: Backfill Power Optimization

**Context:** The backfill crawler aggressively syncs all historical email for AI processing and FTS. Unlike iOS Mail/Gmail/Outlook (which use push + on-demand fetch), TabMail needs all data locally. Profiling showed excessive CPU wakeups from small IMAP batches (50 UIDs) with inter-batch sleeps, redundant per-row SQL existence checks in write transactions, and no battery level awareness.

**Decision:**
1. **Batch existence check** — Replace N individual `fetchCount` queries in `insertBackfillBatch` with a single batch `fetchSet` at the start of the write transaction. O(N) → O(1) SQL round-trips.
2. **Battery level gate** — Skip backfill entirely when battery < 20% and not charging. `shouldPauseBackfill` checks every 60s. Threshold matches iOS's Low Battery warning.
3. **Larger batch sizes** — `backfillChunkSize` 200→500 (normal), 500→1000 (aggressive). `imapFetchBatchSize` 50→100 (normal), 100→200 (aggressive). Fewer write transactions and lock cycles.
4. **Reduced delays** — `interFolderDelay` 1.0→0.5s, `deepCrawlInterWindowDelay` 1.0→0.5s, `imapInterWindowDelay` 0.5→0.3s (normal). `waitForIdle()` already gates responsiveness.
5. **Cellular awareness** — `NetworkMonitor.isExpensive` (from `NWPath.isExpensive`). On metered connections, backfill only inbox-role folders.
6. **Coalesced FTS indexing** — `insertBackfillBatch` returns FTS records instead of indexing inline. `backfillWindow` indexes once at end of window instead of per chunk.

**Rationale:**
- User actions (send, archive, fetchBody) are already disjoint: SMTP/HTTP for sends, priority IMAP lock for actions, GRDB WAL for DB writes. No contention with backfill.
- Fewer, larger batches reduce CPU wakeups, lock cycles, and radio activity — completing backfill faster means less total wall-clock power usage.
- Battery gate prevents draining the last 20% — the range users notice most.
- Cellular gate is consistent with how iOS Mail handles metered connections.

**Consequences:**
- User action worst-case IMAP lock wait increases from ~500ms to ~1s (normal profile). Priority lock ensures this is bounded.
- Cellular users won't have non-inbox folders backfilled until on WiFi. Inbox is always prioritized.
- `insertBackfillBatch` return type changed to `(inserted: Int, ftsRecords: [FTSHeaderRecord])` — callers must handle FTS indexing.

---

## ADR-IOS-022: Agent Chat with Persistent History

**Context:** The Thunderbird addon has a conversational AI assistant (`agentConverse`) that uses the `system_prompt_agent` system prompt, persistent chat history, and the completions API. The iOS app needed the same feature in the Dynamic Island chat pill, replicating TB's architecture per ADR-IOS-008.

**Decision:**
1. **Completions API** — Chat uses `AIService.sendChatMessage()` which sends `system_prompt_agent` (system) + history turns + `chat_converse` (user message) via `sendWithTools()`. Server-side tools (search_web, date_to_day, find_available_slots, time_delta) auto-execute in the backend — the iOS client just receives the final response.
2. **GRDB persistence** — `ChatStore` actor with `chatTurn` table (v6 migration). `ChatTurn` model matches TB's `persistentChatStore.js` turn structure. Budget: 50 exchanges max, 25K chars max, FIFO eviction.
3. **Backend templates** — iOS-specific `system_prompt_agent-v1.0.0.md` (simplified from TB: server-side tool instructions for search_web + date_to_day, no calendar/contacts/FSM, mobile-optimized formatting). Supporting templates: `chat_converse_user_message` (aliased to `chat_converse`), `chat_converse_history`, `chat_converse_reminders`.
4. **History in UI** — `ChatHistoryView` accessible from Settings > AI. Searchable, clearable.
5. **No client-side tools yet** — Server-side tools work out-of-the-box. Client-side tools (email search, memory search, etc.) will be added incrementally via `ToolRegistry`.

**Rationale:**
- ADR-IOS-008 requires exact replication of TB's architecture
- TB's `system_prompt_agent` + `expandSystemPromptAgent()` expansion model is battle-tested
- Persistent history enables cross-session context (prior session history, conversation continuity)
- Server-side tools (search_web, date_to_day) auto-execute in the backend with no iOS code needed — the backend auto-loops and returns the final response

**Consequences:**
- Backend prompt templates must be maintained in sync between iOS and TB (shared intent, platform-specific content)
- iOS agent is more limited than TB (no email operations, calendar, contacts) until client-side tools are implemented
- `chat_converse` alias in `gen-registries.mjs` maps `chat_converse_user_message` filename → `chat_converse` registry key (critical for iOS code that sends `content: "chat_converse"`)
- Budget enforcement is device-local — chat history is NOT synced via Device Sync (per design: stays per-device)

---

## ADR-IOS-023: Mobile-Native Chat UX (Exception to TB Parity)

**Context:** ADR-IOS-008 requires exact replication of TB's architecture, and ADR-IOS-022 established the agent chat system matching TB's `agentConverse`. However, TB's desktop "infinite chat" paradigm — welcome-back messages, greyed-out old sessions, full history replay in the chat window — doesn't suit mobile UX. The iOS Dynamic Island chat pill has limited screen space and users expect a lightweight, focused interaction.

**Decision:** The iOS chat departs from TB's UI presentation while keeping the backend architecture identical:

1. **No welcome-back message** — TB shows a "Welcome back {name}" bubble with staged animation. iOS shows **reminder cards at the top of the chat** (same visual pattern as the email context card) instead. Reminders are loaded fresh on each expand.
2. **Session history with swipe navigation** — TB greys out old-session messages inline. iOS stores a `sessionId` on each `ChatTurn` (GRDB migration v11) and presents past sessions as horizontally swipeable pages in a `TabView(.page)`. Users can swipe left to browse up to K most recent sessions (configurable via `maxChatSessions` in Settings, default 10). The rightmost page is always the current/newest session and is the default on open. **Resuming**: swiping to an old session and sending a message adopts that session's turns as the API conversation history, effectively "resuming" the conversation. The backend receives the same `history` array — no backend changes needed. Sessions reorder by last activity on close/reopen.
3. **Multi-turn within session** — Current session IS multi-turn: prior user/assistant turns from `sessionTurns` (in-memory, in `ChatPillState.Session`) are sent as conversation history. When resuming an old session, that session's persisted turns become the `sessionTurns`. **30s idle timeout** — if the user hasn't interacted for 30s (and the agent is not working), the next expand starts a new session. KB refinement fires on the expiring session.
4. **Nudges become reminder cards** — TB's proactive nudges insert a chat bubble. iOS shows nudge-worthy reminders (urgent/overdue) as **top-of-chat cards with accent highlighting**. Tap to expand, dismiss to snooze.
5. **Compose edit mode is single-turn (atomic)** — Each edit instruction is independent. `editHistory` provides context for continuity, but the LLM does not receive prior conversation turns as messages.

**What stays identical (ADR-IOS-008 compliance):**
- System prompt construction (`system_prompt_agent` with `user_name`, `user_kb_content`, `user_reminders_json`)
- KB refresh per turn, reminders refresh per turn
- ChatIdTranslator (ID recycling, ref counting, pill rendering, eviction cleanup)
- ChatStore persistence (turns still saved for Settings > Chat History, budget enforcement)
- Tool execution (SSE events, server-side tools, client-side tools via ToolRegistry)
- `renderedContent` generation for ChatHistoryView
- Email context enrichment (`Regarding [Email](N):` prefix for LLM, hidden from user)

**Rationale:**
- Mobile users benefit from browsing recent conversations without infinite scrollback
- Swipe-based session navigation is a natural iOS pattern (TabView with page style)
- Resuming old sessions by swapping the conversation history is purely client-side — no backend changes
- Reminder cards at the top are more actionable than a welcome-back bubble
- Multi-turn within the active session is essential for natural conversation flow
- The agent's tools (memory_search, inbox_read) supplement session context

**Consequences:**
- `ChatMessage` model is simplified (no `isHistory`, `isOldSession`, `isGreeting` flags)
- `ChatBubble` is simplified (no greeting tint, no opacity/saturation modifiers)
- Greeting builder functions (`buildGreeting`, `formatRemindersForGreeting`, `formatDueDateForGreeting`) are removed
- `ChatTurn.sessionId` (nullable, GRDB v11) groups turns into sessions; pre-v11 turns have NULL
- `ChatPillState.Session` holds multi-session state: `loadedSessions`, `activeSessionIndex`, `currentSessionId`
- `ChatStore.loadSessions(limit:)` queries distinct sessions ordered by last activity
- `DynamicIslandChatButton` uses `TabView(.page)` for horizontal swiping with custom dot indicators
- Sending in a past session adopts its `sessionId` and turns as the API `history` parameter
- ChatHistoryView and Settings Chat History are unaffected — full history accessible from Settings
- Session state survives SwiftUI view recreation via `ChatPillState` singleton

---

## ADR-IOS-024: Destructive Tool Confirmation with ToolDeclinedError

**Context:** Agent tools that perform destructive or irreversible actions (archive, delete, edit contacts) must get explicit user confirmation before executing. The tool suspends via `withCheckedContinuation` while a confirmation card is shown in the chat UI. If the user declines, the tool must signal failure to the LLM with `ok: false` so the LLM knows the action was NOT performed and can adjust its behavior (e.g., re-read the inbox to verify correct targets).

**Decision:**

1. Tool calls `AgentToolRouter.ActionConfirmation.awaitConfirmation()` which suspends via `withCheckedContinuation`
2. `DynamicIslandChatButton` observes `pendingAction` and appends a confirmation card to the chat
3. On accept: continuation resumes with `true`, tool executes the action and returns success JSON
4. On decline: continuation resumes with `false`, tool throws `ToolDeclinedError(output:)` with structured JSON containing `cancelled: true` and a guidance message for the LLM
5. `ToolRegistry.execute()` catches `ToolDeclinedError` specifically and returns `ToolExecutionResult(output:, ok: false)` — distinct from generic errors which also return `ok: false` but with a different error message
6. Cancellation safety: `withTaskCancellationHandler` + `ContinuationGuard` (NSLock-based single-resume guard) prevents double-resume crashes when both task cancellation and user response fire

**All tools requiring user confirmation MUST follow this exact pattern.**

Currently applies to: `email_archive`, `email_delete`, `contacts_edit`, `contacts_delete`.

**Consequences:**
- LLM receives structured feedback on decline — can retry with correct targets
- `ToolDeclinedError` is distinct from generic tool errors — allows different UX handling if needed
- Confirmation cards become non-interactive after response (prevents double-tapping)
- Task cancellation (Stop button) safely resumes pending confirmations as declined

**SUPERSEDED (delivery mechanism) by ADR-IOS-053:** Step 2 above (a global `pendingAction` slot observed by `DynamicIslandChatButton` via `.onChange`) caused a cross-view delivery race that hung calendar/confirmation tools. Delivery now goes through an owned, explicit, invocation-scoped `AgentUISink` into the invoking session's model, rendered level-triggered. The `ToolDeclinedError` contract (steps 3–6) and Stop-cancel safety are unchanged.

---

## Template for New Decisions

```markdown
## ADR-XXX: [Title]

**Context:** [What situation led to this decision?]

**Decision:** [What did we decide?]

**Rationale:** [Why?]

**Consequences:**
- [Trade-offs, both positive and negative]
```

---

## ADR-IOS-025: Backfill Crawl Progress Must Not Use Date-Based Anchors From Unrelated Queries

**Context:** In Feb 2026, we discovered that `fullSync` anchored `oldestSyncedDate` to `min(date)` across ALL messages in a folder, not just the sync batch. After a Smart Reindex (which resets `oldestSyncedDate` to nil), the next `fullSync` would re-anchor to the oldest message in the folder (potentially years old), causing backfill to start from that ancient date instead of from today. This created a massive unscanned gap between the latest-50 sync window and where backfill resumed.

**Root cause bugs found (all fixed):**
1. `fullSync` anchor used `min(date)` across entire folder — fixed to use the Nth most recent message
2. Deep backfill missing 1-day overlap for IMAP date boundary messages — fixed
3. Deep backfill terminated on `insertedCount == 0` instead of `found == 0` — fixed
4. Shallow backfill `<=` instead of `<` at age cutoff boundary — lost messages on exact cutoff date — fixed
5. `fetchOlderMessages` used `Calendar.current` instead of UTC — timezone-dependent gaps — fixed
6. `todayMidnight` used hardcoded `86400` seconds instead of Calendar API — fixed

**Decision:**
- **NEVER derive crawl progress pointers from aggregate queries over the full message store.** The anchor must reflect only the current operation's scope (e.g., the oldest date from the just-synced batch, or the window boundary that backfill just completed).
- **Date-based crawling is inherently fragile** — IMAP SINCE/BEFORE uses date-only granularity (no time component), sender dates can be wrong (clock skew), and midnight-aligned UTC windows can miss messages at boundaries. We mitigate with 1-day overlap between windows and self-healing (UID comparison), but this remains a known weakness.
- **UID-based tracking is not a complete solution either** — UIDs are folder-specific, can change on UIDVALIDITY change (mailbox compaction), and are not available for Gmail/Exchange. UIDs are used for gap detection (self-heal) but not as the primary crawl pointer.
- **Self-healing mechanism** (`SyncEngineSelfHeal.swift`) runs after full sync (rate-limited hourly) and on-demand folder refresh, comparing IMAP UIDs against GRDB and fetching any missing messages. This is the safety net for any crawl logic bugs.

**Additional bugs found and fixed (same investigation):**
7. **Duplicate backfill workers** — when `resetCrawlState()` cancels old tasks, the old task's `defer { headerBackfillTasks[accountId] = nil }` could fire AFTER a replacement task was placed in the dictionary, overwriting it. Next sync poll would see nil and spawn a duplicate. Fixed: defer only clears on non-cancelled exit.
8. **FTS body fetch — missing UIDs get retry** — `fetchTextBodiesParallel` silently drops UIDs for some messages (e.g., Deleted Messages, attachment-only). Added one-retry for transient drops. Permanently missing UIDs are NOT marked as fetched (headers exist = messages are real). The existing `ftsStalled`/`ftsSkipOffset` mechanism handles these without data loss.

**Consequences:**
- Smart Reindex now works correctly — backfill starts from just below the sync window and crawls the full history
- Self-heal catches any remaining gaps within the 90-day window
- No more duplicate workers racing on the same account
- FTS body retry catches transient IMAP FETCH drops; permanently missing UIDs handled by ftsStalled mechanism
- The fundamental tension between date-based and UID-based progress tracking remains unresolved — both have failure modes

---

## ADR-IOS-026: Proactive Local Notifications (Replicating TB's Nudge System)

**Context:** TB's `proactiveCheckin.js` delivers browser notifications for reminders via two deterministic triggers. iOS needs the same functionality using `UNUserNotificationCenter` local notifications, which work even when the app is killed (via `UNCalendarNotificationTrigger`).

**Decision:**
1. **Two triggers matching TB:**
   - `new_reminder` — fired after AI message processing detects new reply-tagged reminders within the configured window. Debounced 1s.
   - `due_approaching` — scheduled via `UNCalendarNotificationTrigger` N minutes before a reminder's due date/time. Reschedules on every reminder list change.
2. **`ProactiveNotifyService` actor** — singleton orchestrator. Called from `AccountManagerAI.processMessagesForAccount()` (after drain) and `RootView` on foreground return.
3. **`ReachedOutStore`** — UserDefaults-backed dedup keyed by `"{reminderHash}:{triggerType}"`. Prune splits on LAST colon (reminder hashes contain colons like `m:msgId`).
4. **Separate `NotificationDelegate`** — `UNUserNotificationCenterDelegate` extracted from `AppDelegate` into its own class because `UIApplicationDelegate` makes `AppDelegate` implicitly `@MainActor`, conflicting with the delegate's arbitrary-thread callbacks in Swift 6.
5. **Foreground return delivered-notification sync** — `onForegroundReturn()` syncs `deliveredNotifications()` to `ReachedOutStore` before checking for overdue reminders. Covers the case where `UNCalendarNotificationTrigger` fired while the app was killed (delegate never ran).
6. **No LLM calls** — notification content is template-based string interpolation, matching TB.
7. **Rate limiting** — 60s minimum between immediate notifications, matching TB's `MIN_INTERVAL`.

**Consequences:**
- Notifications work even when app is killed (calendar triggers are OS-managed)
- Deep link on notification tap posts `.proactiveNotificationTapped` — observer not yet implemented (follow-up)
- Settings: toggle, window days, advance minutes — all in TabMailSettingsView "Notifications" section

---

## ADR-IOS-027: Ever-Rolling FIFO Queues — Leave Only on Confirmed Success or Confirmed Stale

**Context:** Background processing queues (ActiveBodyQueue, ActiveAIQueue, BackfillEmbeddingQueue) handle work items that represent real user data — message bodies, AI summaries, vector embeddings. Fire-and-forget patterns risk silent data loss: if a task fails (connectivity drop, timeout, crash), the item vanishes from the queue and is never retried. The consolidation/self-heal pass on next launch should be a safety net, not the primary recovery mechanism.

**Decision — Ever-Rolling FIFO with In-Flight Safety:**

1. **Items NEVER leave the queue until confirmed done.** An item is removed ONLY on:
   - **Confirmed success** — the work completed and was persisted (FTS write, AI cache write, embedding stored).
   - **Confirmed stale** — the source data no longer exists (account deleted, header deleted, content permanently gone e.g. HTTP 404/410).
   - **Max retries exceeded** — transient failures exhausted the retry budget (`SyncConfig.maxQueueRetries`). Item is dropped from in-memory queue; `repopulateFromDatabase()` rediscovers it on next foreground.

2. **Dispatch = copy to back + mark in-flight.** When dispatching an item:
   - Move item from front to back of the FIFO array (item is always in the queue).
   - Mark item in the `inFlight` set (dispatch skips in-flight items).
   - Launch fire-and-forget task for the actual work.
   - On success: remove from queue. On failure: clear in-flight flag — item stays at back, will naturally cycle to front for retry.
   - **Candidate scan MUST skip past in-flight items** — use a `scanIdx` that advances past in-flight entries instead of breaking at the first one. Without this, newly-enqueued items get stuck behind wrapped-around in-flight items at the front of the queue, even when concurrency slots are available (dispatch starvation).

3. **Two-phase dispatch (actor reentrancy safety).** Phase 1 collects candidates synchronously (no `await` — safe from actor reentrancy). Phase 2 resolves async dependencies (provider lookup, DB reads) and launches tasks. This prevents queue mutation during iteration.

4. **Immediate dispatch on idle→active transition.** First item enqueued into an empty queue dispatches immediately (no debounce delay). Subsequent rapid enqueues are debounced (300ms body, 500ms embedding) to batch redundant dispatch calls.

5. **Boot-time recovery for every queue.** Each queue has `repopulateFromDatabase()` that discovers incomplete work from GRDB/FTS state (e.g., inbox headers missing FTS body, messages with body but no embedding). Called from `SyncScheduler` on foreground return and in `BGProcessingTask`. The queue itself is ephemeral (in-memory); the database is the durable source of truth.

6. **Failed items yield to others.** On failure, the item is already at the back of the FIFO — other items get their turn before the failed item cycles back to the front. This prevents one bad item from blocking the entire queue.

**Queues implementing this pattern:**
- `ActiveBodyQueue` — fetches message bodies from provider, writes plain text to FTS
- `BodyRenderQueue` — renders FullMessageInfo → MessageBody (CID, ICS, attachments). Background pre-cache path uses INSERT OR IGNORE; user-open path uses save() (upsert) to always win over background.
- `ActiveAIQueue` — generates summaries/actions/replies via backend LLM
- `BackfillEmbeddingQueue` — generates vector embeddings via CoreML

**Rationale:**
- No item is ever in a state where it's "not in the queue AND not confirmed done"
- Crash at any point loses only the in-memory queue — `repopulateFromDatabase()` rebuilds from durable state
- The self-heal/consolidation pass should never need to do real work — it's purely a safety net
- IMAP priority lock (`acquirePriorityLock()`) handles user-vs-background contention naturally — no pause mechanism needed

**Consequences:**
- Slightly more memory per queue (in-flight set, retry counts, dedup set)
- `repopulateFromDatabase()` is idempotent — safe to call multiple times (dedup set prevents duplicates)
- All four queues follow identical structure — any new processing queue must adopt the same pattern

---

## ADR-IOS-026B: Durable Message Actions Use RFC Message-ID Across Providers

> **Amended and made authoritative by ADR-IOS-060 (2026-07-13).** The earlier provider-selected scheme used RFC Message-ID only for numeric IMAP UIDs while Gmail and Exchange durable jobs carried provider resource IDs. That scheme is historical and is replaced below.

**Context:** IMAP UIDs and Microsoft Graph default resource IDs change on MOVE. Gmail IDs survive label changes, but retaining a Gmail-only durable identity forces the generic queue to preserve mixed provider semantics. TabMail and the Thunderbird reference architecture already fetch, normalize, deduplicate, stage, and cross-device-probe messages through the RFC `Message-ID` (`MessageHeader.rfc822MessageId`; Graph `internetMessageId`).

**Decision:** Every durable message-action member for Gmail, Exchange, and IMAP is identified by its normalized RFC Message-ID. The job also carries account and recorded source folder, so the provider can resolve that RFC identity inside the exact source scope. Exactly one authoritative match is mutated through the provider's current transient resource ID/UID; zero or multiple matches return normally as stale/unsafe no-op; lookup/auth/transport failure throws for retry.

Provider IDs remain valid for local database primary keys, sync, immediate body/attachment fetches, drafts, outbox delivery, and APNs/NSE transport. They are not durable message-action identity. `MessageHeader.stableId` remains a legacy/local helper until its non-queue consumers are separately audited; queue admission must use the explicit RFC operation identity instead of inferring provider type from ID shape.

A message with no RFC Message-ID is not durably admitted and receives no provider-ID fallback. Admission validates locally available RFC presence/syntax before optimistic mutation; it does not perform a synchronous provider preflight. An invalid member is neither changed locally nor queued, while valid members of the same batch may proceed. Released provider-ID message-action rows undergo one finite conversion before the new drain owner starts; conversion preserves rowid/FIFO, member order, and command semantics and does not create a permanent dual-format executor. Missing local evidence triggers finite provider-assisted resolution; database/provider uncertainty leaves rows unchanged and blocks startup for retry, while a completed authoritative stale/ambiguous or provider-unrepresentable result may omit a member. For the IMAP cutover, noncanonical/out-of-range legacy UID text and an exact source UID without a valid RFC Message-ID are terminally unrepresentable; SELECT/FETCH failure or contradictory correlation remains uncertainty.

**Rationale:** One lowest-common-denominator identity makes the queue and Undo provider-blind. A forward move and inverse move carry the same RFC key; Gmail resolves it to a Gmail ID, Exchange to the current Graph ID, and IMAP to the current UID in their respective recorded source scopes. Crash recovery therefore needs no receipts, aliases, immutable-Graph migration, or provider-specific durable state.

**Consequences:**
- Provider adapters perform an authoritative source-scoped lookup before every durable message mutation; Gmail accepts an extra lookup despite already having a stable provider ID.
- Missing and duplicate RFC identities fail safely as terminal no-op instead of guessing.
- Draft/outbox and immediate notification-fetch identifiers remain outside this message-action identity contract.
- Graph remains in its default resource-ID mode. The provider resolves the current ID from `internetMessageId` for each operation; no immutable-ID header, account migration, or push/NSE identity-mode handshake is required.
- Sync protection continues matching RFC identity; any local Graph/IMAP re-key preservation bug is fixed in sync/search, not in the queue.

**Historical implementation retained for the audit record:** before this amendment, `MessageHeader.stableId` selected RFC identity only when `messageId` parsed as a numeric IMAP UID and otherwise selected the Gmail/Exchange provider ID; `queueTagWrite` duplicated that heuristic, sync matched both fields, and missing IMAP RFC identity fell back to the numeric UID. Those mechanics explain the released provider-ID rows requiring finite conversion, but they are not the current contract.

---

## ADR-IOS-028: Background Execution Budget — Lightweight Refresh, Heavy Processing

**Context:** iOS imposes strict time budgets on background execution. `BGAppRefreshTask` has ~30 seconds; silent push notifications have a similar budget. Exceeding these budgets causes iOS to penalize the app: throttling future `BGAppRefreshTask` scheduling AND rate-limiting silent push delivery. We observed that running full sync (which fires backfill, bulk FTS indexing, and embedding rebuild as fire-and-forget Tasks) during push/refresh was blowing the budget and causing iOS to stop delivering push notifications entirely.

**Decision:** Split all background work into two tiers with a strict contract:

### Tier A — Lightweight Refresh (BGAppRefreshTask + Silent Push)

**Budget:** Must complete in <25 seconds. Enforced by BGTaskContext expiration handler.

**Allowed work (exhaustive list):**
1. `reconnectProviders()` — reconnect stale IMAP/API connections
2. `backgroundDeltaSync()` — header-only delta sync (no full sync fallback). Per-account timeout of 15s.
3. `drainPendingQueue()` + `drainOutbox()` — execute queued user actions (fast, bounded)
4. `updateBadgeCount()` — recount unread from local DB
5. `scheduleBackgroundProcessing()` — schedule Tier B to run next

**Prohibited work (NEVER in Tier A):**
- Full sync (`sync()` / `fullSync()`) — unbounded duration, fires background Tasks
- `startBackfill()` — backward crawl, unbounded IMAP fetches
- `bulkIndexIfNeeded()` — FTS indexing of all unindexed messages
- `startEmbeddingRebuild()` — ML model inference
- `ActiveBodyQueue.awaitDrain()` — fetches full message bodies via IMAP/API
- `ActiveAIQueue.awaitDrain()` — LLM API calls
- `BackfillEmbeddingQueue.awaitDrain()` — ML embedding generation
- `repopulateFromDatabase()` — queue scan of entire message table
- Any fire-and-forget `Task { }` that does unbounded work

**Account scoping:**
- **BGAppRefreshTask:** IMAP/iCloud accounts only (Gmail/Outlook have push).
- **Silent push:** Only the pushed account (resolved from `accountEmail` in payload). Falls back to all active accounts if email can't be resolved.

### Tier B — Background Processing (BGProcessingTask)

**Budget:** Minutes of execution time. Requires network connectivity.

**Work (in order):**
1. `reconnectProviders()`
2. Repopulate + drain body/AI/embedding queues
3. `generateMissingEmbeddings()`
4. Backfill (backward crawl) — WiFi-gated via `wifiOnlyKey` setting
5. `drainPendingQueue()` (in case backfill queued tag writes)
6. `updateBadgeCount()`

**Scheduling:** Tier B is scheduled immediately after every Tier A completion (both BGAppRefreshTask and silent push). Also scheduled on app background as a periodic fallback.

### Entry Points

| Trigger | Tier | Method | Accounts |
|---------|------|--------|----------|
| BGAppRefreshTask | A | `handleBackgroundSync()` → `backgroundPoll()` | IMAP/iCloud only |
| Silent push (APNs) | A | `handleSilentPush()` → `backgroundPollNow(accounts:)` | Pushed account only |
| BGProcessingTask | B | `handleBackgroundAIProcessing()` | All active |
| Foreground timer | Full | `poll()` → `sync()` | All active |
| Foreground return | Full | `startForegroundPolling()` → `poll()` | All active |

### Key Implementation Details

- `backgroundDeltaSync()` is the Tier A counterpart to `sync()`. It calls `performDeltaSync()` directly — never falls back to `fullSync()`, never fires `startBackfill()` / `bulkIndexIfNeeded()` / `startEmbeddingRebuild()`.
- `backgroundPoll()` defaults to IMAP/iCloud accounts when no override is provided. The push handler explicitly passes the resolved account(s).
- IMAP delta uses STATUS UNSEEN to detect remote read/unread flag changes without full folder sync. When only unread count changed (no new/deleted messages), updates the folder count directly — avoids the cost of `syncMessages()`.
- The push handler races sync against a deadline (`PushConfig.silentPushDeadlineSeconds`) with early return. Even on timeout, returns `.newData` to avoid iOS throttling.

**Rationale:** iOS documentation and observed behavior confirm that exceeding background budgets causes compounding penalties: delayed BGAppRefreshTask scheduling, reduced silent push delivery rate, and eventual suspension of background execution privileges. The two-tier split ensures the time-critical path (Tier A) always completes within budget, while heavy work (Tier B) runs when iOS grants extended execution time.

**Consequences:**
- New messages appear as headers immediately (Tier A), but body/AI/snippets populate later (Tier B)
- If iOS never grants Tier B time, queues drain on next foreground return (existing crash recovery path)
- IMAP accounts without server-side push (pre-IMAP_CHECK_PUSH) rely on BGAppRefreshTask frequency, which iOS controls unpredictably (minutes to hours)

---

## ADR-IOS-029: Database Index Management — Purpose-Built Indexes, Drop What's Superseded

**Context:** Two incidents shaped this ADR.

**Incident 1 (v38, 2025):** Migration v38 added a `headerComplete` column and replaced the existing `(folderId)` and `(folderId, isRead)` indexes with composite indexes that included `headerComplete`. This broke every query that relied on the original column order — unread counts, folder listings, and basic folder lookups regressed to full table scans on 250K rows. Instant folder opens became sustained 0.1 GB/s disk reads.

**Incident 2 (v50, 2026):** `BackfillEmbeddingQueue.repopulateFromDatabase` consistently took 1.4-4.2s for 0-row results despite a hand-tuned full index `messageHeader_embeddingStatus` existing. `EXPLAIN QUERY PLAN` revealed the planner was choosing `idx_messageHeader_bodyStatus` with `ANY(headerComplete)` + a temp-btree sort, scanning most of the table. The root cause: stale `ANALYZE` statistics, and too many overlapping indexes gave the planner a bad choice it took. Replacing the full index with a partial index (`WHERE embeddingComplete=0 AND bodyComplete=1 AND bodyEmptyConfirmed=0`) that holds ~0 rows at steady state, AND dropping the superseded full index, made it sub-ms.

**Decision:** Indexes are load-bearing and must be designed for specific query patterns. Add purpose-built indexes for new queries. DROP indexes that are provably superseded by better ones — stale indexes actively mislead the query planner and are not free. But never drop an index that other queries still depend on just because one query no longer needs it.

**Rules:**

1. **New query patterns get new indexes** with descriptive names that describe the query, not the column list (`messageHeader_embeddingIncomplete`, `messageHeader_aiIncomplete`, `messageHeader_triage_display`).
2. **Prefer partial indexes for queues that drain to empty.** If a query's predicate matches the desired row set (e.g., "messages that still need X"), a partial index on exactly that predicate holds ~0 rows at steady state. Seeks become free regardless of planner choices.
3. **Before dropping an index, audit every query that could use it.** Grep for the column combination and all predicates it covers. Confirm each usage is served by another index at least as well. When in doubt, keep it and revisit later.
4. **Never drop an index on the same PR as schema changes that reshape queries.** Do one at a time so regressions are easy to bisect.
5. **Run `ANALYZE`** at the end of any migration that adds, changes, or drops indexes. Without it the planner uses default cost estimates and may pick badly. Stale stats on old indexes are a source of silent regressions.
6. **Composite index column order matters.** `(folderId, isRead)` serves `WHERE folderId=? AND isRead=0`. Inserting a column between them (`folderId, headerComplete, isRead`) breaks every query that used the original prefix — SQLite can only use a contiguous leading prefix up to the first non-equality column. If you need a new order, add a new index — don't rearrange an existing one.
7. **More reads is cheaper than more indexes; more indexes is cheaper than a single wrong-plan query.** Index write-amplification is bounded by `indexCount × log(N)`. A full-table scan is `O(N)`. The app is read-heavy — err on the side of more indexes, but only when each one earns its keep.
8. **When a query stays slow after indexes exist, run `EXPLAIN QUERY PLAN` before adding more indexes.** The planner may be picking a wrong index. A partial index or pinning the right one (via query rewrite, not `INDEXED BY` hacks) is usually the fix.
9. **Index changes require load evidence, not only a green query test.** Audit already-migrated pool-open/schema-read time, one-time migration build time, logical index bytes/pages, representative write amplification, and `EXPLAIN QUERY PLAN` before/after `ANALYZE` at realistic 250K+ scale. Keep wall-clock thresholds out of ordinary CI; record repeatable manual benchmark results and pin deterministic schema/plan invariants in tests.
10. **Correct released indexes with a forward migration.** Create a replacement under a new name before dropping the old tree so interruption never leaves a hot query unindexed; update historical migration bodies so fresh databases do not build throwaway indexes; finish with `ANALYZE`. Dropped pages remain reusable freelist space. Never run startup `VACUUM` merely to shrink the high-water file size—it blocks launch and requires peak temporary disk.

**Rationale:** SQLite indexes are B-trees. A query can only use a contiguous leading prefix of index columns with equality predicates, then one range/ORDER-BY column. Adding a separate index preserves existing query performance while enabling new query patterns. But an unused index is not inert: the planner considers it on every query and stale statistics (post-migration column changes, skewed data distribution) can make it look deceptively cheap. Dropping obsolete indexes is a perf fix, not a cleanup task.

**Consequences:**
- The `messageHeader` table may have 10+ indexes — acceptable for a read-heavy workload.
- Write amplification per `INSERT/UPDATE` is bounded by `indexCount × log(N)`.
- Index disk space is ~10-20% of table size per index — acceptable for a 250K row table.
- Migrations that drop indexes must include the `ANALYZE` call and document what was superseded, so future readers understand why the index no longer exists.

**Index-load audit amendment (2026-07-13).** The strict post-`07a4bb7` inventory found only v69's `messageHeader_pendingFTSRekeys`; its corrected sparse `id WHERE marker IS NOT NULL` shape occupies one 4 KiB page when empty, adds no ordinary-row entry, and showed no measurable difference across 100 open/schema reads (0.821 s with or without it) on a one-million-row synthetic database. Before the migration-scope clarification, the bounded audit had already proved two older costs: v62 retained a redundant `(folderId,isRead)` tree fully covered by `(folderId,isRead,date)`, and v66 indexed every provider ID even though only `.uid` stale windows query its numeric expression. v70 creates `messageHeader_folderId_numericUid` first with an ASCII-decimal partial predicate, drops the full v66 and redundant v21 trees, and runs `ANALYZE`; the `.uid` query repeats the predicate so SQLite can prove eligibility. On a 250K mixed-provider fixture, relevant logical DB pages fell from 72.0 MB to 60.6 MB, the UID tree fell from 7.43 MB to 3.07 MB, 5,000 unread counts were effectively unchanged (1.346 s versus 1.353 s), and a 250K read/date mutation improved from 0.709 s to 0.416 s. The corrective migration took 134 ms on this Mac. It does not `VACUUM`; released pages remain reusable. Keep this completed benefit, but do not widen into further audits of v67-and-earlier migrations.

---

## ADR-IOS-030: Agent Compose Tool FIFO Queue

**Context:** Agent tools `email_compose`, `email_reply`, and `email_forward` set `AgentToolRouter.pendingCompose`, which `InboxView` and `MessageDetailView` observe via `onChange` and present as a `fullScreenCover`. There was no coordination with already-presented compose windows:

- If the user had a compose window open (manually, or from a prior agent call), a new agent compose request was silently dropped — SwiftUI cannot stack two `fullScreenCover`s from the same source view, and the local `@State` set during `onChange` is not re-evaluated when the prior cover dismisses.
- If two agent tools fired back-to-back, the second overwrote the first in the single-slot router state and was lost before any view captured it.
- The LLM still received `"Opening compose window..."` as the tool result, so the model thought the operation succeeded — confidently wrong, no retry, no user-visible failure.

**Decision:** Compose tool requests go through an in-memory FIFO queue on `AgentToolRouter`. Only one `ComposeView` is presented at a time. **A manually-opened compose window counts as the head of the queue** — agent requests wait until it dismisses, then play one after another with no gaps.

**Mechanism:**

1. Tools call `AgentToolRouter.shared.enqueueCompose(request)` (synchronous, fire-and-forget). The request is appended to `composeQueue`. Tools' return strings are unchanged — the LLM gets the same response it always did.
2. `dispatchNextIfIdle()` runs synchronously after enqueue. The dispatch guard checks four conditions: `awaitingAppear == false`, `pendingCompose == nil`, `presentationCount == 0`, and `!composeQueue.isEmpty`. If all are satisfied, it pops the front of the queue, sets `awaitingAppear = true`, and assigns the request to `pendingCompose`.
3. The existing `onChange(of: pendingCompose?.id)` in `InboxView`/`MessageDetailView` captures the request into local `@State` and presents the cover via the existing `.fullScreenCover(item:)` plumbing.
4. `ComposeView.onAppear` calls `composePresentationDidBegin()` which increments `presentationCount` AND clears `awaitingAppear`. `ComposeView.onDisappear` calls `composePresentationDidEnd()` which decrements (clamped at 0) and dispatches the next queued request if count returns to 0.
5. Because the lifecycle hook lives **inside `ComposeView` itself**, it fires for **every** presentation path automatically — manual compose toolbar button, contact compose, reply, replyAll, forward, agent compose, agent draft re-open via `DraftComposePresenter`. No per-cover-site instrumentation, no risk of forgetting one. (`DraftComposePresenter` also has the same hook on its body root — see "Loading wrapper race" below.)

**The `awaitingAppear` flag closes the dispatch race.**

Without it, there is a brief window between "router sets `pendingCompose = A`" and "the new `ComposeView`'s `onAppear` fires `composePresentationDidBegin`" during which:
- The view's `onChange` handler has already captured `A` into local `@State` and synchronously nilled `pendingCompose` (the original pre-queue housekeeping pattern, preserved in this change).
- The `fullScreenCover` is mid-presentation but `composePresentationDidBegin` hasn't yet fired.
- `pendingCompose == nil` AND `presentationCount == 0` are both true.

If a second `enqueueCompose(B)` arrived in this window, the dispatch guard would falsely succeed, set `pendingCompose = B`, and the view's `onChange` would fire again — replacing the in-flight `agentCompose` `@State` value from A to B mid-presentation. SwiftUI's `fullScreenCover(item:)` does not gracefully transition between two non-nil identifiable values (per Apple docs and observed behavior on iOS 18+), so A would be silently dropped.

`awaitingAppear` is set to `true` at dispatch time and cleared in `composePresentationDidBegin`. The dispatch guard tests it. A second `enqueueCompose` during the race window finds `awaitingAppear == true` and queues instead. The window is microseconds in normal SwiftUI runloops, but the race is real when two LLM tool calls return in the same runloop tick.

**Loading wrapper race (DraftComposePresenter).**

`DraftComposePresenter` is a wrapper that loads a draft from GRDB before rendering `ComposeView`. It is presented in two places: (a) `InboxView`'s `showAgentDraft` cover, set by tapping an agent toast; (b) `ComposeToolbarButton`'s `showDraft` cover, set when re-opening an in-progress agent draft. During the brief loading state (synchronous GRDB read, microseconds), `ComposeView` has not yet rendered, so the queue's `presentationCount` is still 0. Without a hook on `DraftComposePresenter` itself, a queued agent compose could try to present from the same source view during this window — and SwiftUI would silently drop the second cover.

Fix: `DraftComposePresenter` carries the same `composePresentationDidBegin/End` hook on its body root. When the cover presents, count increments immediately even before the inner `ComposeView` loads. When the cover dismisses, both `ComposeView.onDisappear` and `DraftComposePresenter.onDisappear` fire (inner first), decrementing the count from 2 → 1 → 0, with the dispatch trigger firing on the second decrement. `ServerDraftComposeLoader` (a navigation destination, not a cover) doesn't need this hook because it's not a `fullScreenCover` and an agent compose can present on top of it without conflict.

**Lifecycle hooks are safe against ComposeView's internal modals.**

ComposeView contains `.alert`, `.popover`, `.photosPicker`, `.fileImporter`, and a `.fullScreenCover` for the camera. Confirmed via Apple Developer Forums (thread 655338) that a parent view's `onAppear`/`onDisappear` do **not** fire when the parent itself presents any of these. The parent stays in the view hierarchy; only the inner presentation is layered on top. So `presentationCount` does not drift when the user opens the camera or picks a photo from inside `ComposeView`.

**In-memory only.** App kill loses the queue. Agent compose requests are session-scoped UI intent, not durable user actions like outbox sends (ADR-IOS-019) or pending operations (ADR-IOS-018). Persistence would add complexity for negligible benefit — if the app dies, the agent task that produced the request is also gone.

**Stop button is not relevant.** The user cannot tap Stop while a compose `fullScreenCover` is presented (the inbox/chat surface is hidden behind it). The queue therefore needs no cancellation semantics — by the time the user could possibly cancel, the compose window has already appeared and the request has already left the queue.

**Consequences:**

- Multiple back-to-back agent compose requests are presented in order, each waiting for the previous to dismiss. The user may be "bombarded" with compose confirmations — accepted as the lesser evil compared to silently losing requests.
- A manually-opened compose window blocks queued agent compose requests until the user dismisses it. The agent waits patiently. When the user closes their compose, the queued agent compose appears immediately.
- The InboxView/MessageDetailView observer race (both views observe `pendingCompose`; whichever wins captures and nils the slot) is unchanged — the queue layer is orthogonal to which view presents. Whichever view wins each dispatch round presents that round's request.
- If neither `InboxView` nor `MessageDetailView` is alive when the queue dispatches (e.g., user is deep in Settings), `pendingCompose` stays set and the queue stalls. Acceptable — these are the only views that observe, and at least one is always alive when an agent runs from a chat surface.
- The queue has no priority and no deduplication. If the agent fires three "compose to alice@x.com" requests in a row, the user sees three compose windows in sequence. By design — we can't second-guess the agent's intent.

**Out of scope (deliberately):**

- Persistence across app kill.
- A user-visible queue indicator (e.g. "2 more compose drafts pending"). Easy follow-up if needed.
- Queueing of `ActionConfirmation` (archive/delete/calendar prompts) — separate single-slot system, separate concern.
- Coordinating with non-`ComposeView` UI surfaces.
- Telling the LLM that a request is queued vs. dispatched. Tool return string is unchanged.

**Files:**

- `TabMail/Services/AI/AgentToolRouter.swift` — `composeQueue`, `presentationCount`, `awaitingAppear`, `enqueueCompose`, `composePresentationDidBegin/End`, `dispatchNextIfIdle`. New private fields are `@ObservationIgnored` so they don't create observation dependencies.
- `TabMail/Services/AI/Tools/EmailComposeTool.swift`, `EmailReplyTool.swift`, `EmailForwardTool.swift` — call `enqueueCompose` instead of writing `pendingCompose` directly
- `TabMail/Views/Compose/ComposeView.swift` — `onAppear`/`onDisappear` lifecycle hooks on the body root
- `TabMail/Views/Compose/DraftComposePresenter.swift` — same hooks on its body root, to close the loading-window race before the inner `ComposeView` renders

**PARTIALLY SUPERSEDED (routing) by ADR-IOS-053:** the InboxView/MessageDetailView `pendingCompose` observer race noted in the Consequences is slated to be fixed (Phase 2) by re-homing compose routing to the owned `AgentUISink`. The cover-serialization FIFO (`composeQueue`/`presentationCount`/`awaitingAppear`) is retained — it solves the distinct "SwiftUI can't stack two fullScreenCovers" constraint, which owned routing does not address.

---

## ADR-IOS-031: Background Tasks Touching GRDB MUST Use `.medium` Priority (Never `.low` / `.utility` / `.background`)

**Context:** iOS Thread Performance Checker caught a priority inversion during a reported blank-inbox-during-rapid-nav symptom. Stack trace:

```
Thread Performance Checker: Thread running at User-initiated quality-of-service
class waiting on a lower QoS thread running at Default quality-of-service class.
Investigate ways to avoid priority inversions

... GRDB.Pool.get
... GRDB.DatabasePool.read
... SearchIndex.headerIdsWithEmptyFolderId
... SyncEngine.backfillFolderIdsIfNeeded  ← Task(priority: .low) { … }
```

MainActor (user-initiated QoS 25) was blocked waiting on a GRDB reader held by a `.low`-priority backfill task (= utility QoS 17). The 8-level QoS gap was large enough for iOS to stall MainActor's execution while the backfill read completed. Body evaluation produced the correct view tree (`normalListView body eval — OK loaded=50 groups=38 visible=38`) seconds before MainActor could actually commit the render. Visible symptom: stuck blank inbox until the reader released (self-recovery in 1–2 s). Same mechanism also manifests as lagged sync-status pill updates after foreground return — every `@Observable` state change and NotificationCenter handler hops through MainActor and queues up behind the same block.

**Decision:** Any background `Task { … }` that touches GRDB (any `dbPool.read` / `dbPool.write` on the main DB OR the FTS DB OR any other `DatabasePool` we own) MUST use `priority: .medium` (= `.default` QoS 21) or higher. Never `.low`, never `.utility`, never `.background`. This is a hard invariant with no exceptions — the GRDB reader pool is a finite resource shared with MainActor, and any QoS gap of more than 4 levels below MainActor (`.userInitiated` == 25) triggers priority inversion that stalls the render thread.

**QoS reference (Task.Priority → QoS numeric):**

| TaskPriority | QoS            | QoS # | Use |
|---|---|---|---|
| `.userInitiated` / `.high` | userInitiated | 25 | User-triggered sync (pull-to-refresh, foreground poll) |
| `.medium` (default) | default | 21 | **Background tasks that touch GRDB — FLOOR** |
| `.low` / `.utility` | utility | 17 | ❌ NEVER for GRDB work |
| `.background` | background | 9 | ❌ NEVER for GRDB work |

`.medium` stays below `.userInitiated` so user-triggered operations retain priority, but only by 4 QoS levels — below iOS's priority-inversion detection threshold, and close enough that the scheduler won't stall MainActor waiting on it.

**Rationale:**

- GRDB's `DatabasePool` has a finite reader pool (default 5). When all readers are busy, additional readers — including MainActor — must wait.
- iOS's Thread Performance Checker flags any situation where a higher-QoS thread waits on a lower-QoS thread's resource. The warning is not just noise: iOS's scheduler genuinely throttles the higher-priority thread's execution in this state (priority promotion *helps* but doesn't fully compensate for large QoS gaps).
- The practical effect is indistinguishable from MainActor being frozen — SwiftUI body has produced the correct view tree, but the commit-to-screen phase waits on the blocked MainActor.
- `.low` / `.utility` are superficially appealing for "low-priority background work", but their 8-level QoS gap below MainActor is exactly the range that triggers inversion. They're appropriate for CPU-only tasks with no shared resources, not for anything touching GRDB.
- `.medium` is the minimum safe floor. Further bumping to `.userInitiated` is wrong — that matches MainActor priority and defeats the purpose of "background" designation; user-triggered syncs should still outrank background ones.

**Consequences:**

- All sync-engine background tasks (header backfill, FTS bulk index, folderId backfill) use `.medium`.
- Any new Task created in the data layer must explicitly set `.medium` or higher when it will touch GRDB. Inheriting from the caller is NOT acceptable because the caller's QoS is often MainActor → inheriting creates a different problem (the task blocks the caller).
- Pure CPU background work (e.g., in-memory threading heuristic, text processing with no DB access) may still use `.low` / `.utility` / `.background`. The rule is scoped to GRDB-touching code specifically.
- PR review checklist item: grep `Task(priority:` on all new Tasks and verify none use `.low` / `.utility` / `.background` in files that touch GRDB.

**Out of scope:**

- Raising GRDB's `maximumReaderCount` as an alternative fix. Considered but rejected — more readers increase SQLite contention, and doesn't address the underlying rule that background work must not cause priority inversion.
- Converting all MainActor sync GRDB reads to async. Worth doing for MainActor-specific hot paths independently, but doesn't address the root cause (the priority inversion would still fire if background tasks run at `.low`).
- `DispatchQueue.global(qos:)` usage. The same rule applies: GRDB-touching dispatches must be at `.default` QoS or higher.

**Files:**

- `TabMail/Services/Sync/SyncEngineBackfill.swift:208` — header backfill (was `.low`, now `.medium`)
- `TabMail/Services/Sync/SyncEngineFTS.swift:184` — FTS bulk index (was `.low`, now `.medium`)
- `TabMail/Services/Sync/SyncEngineFTS.swift:270` — FTS folderId backfill (was `.low`, now `.medium`)

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

## ADR-IOS-036: Action Tags Are Local-Only (Supersedes ADR-IOS-004)

**Context:** Since the original cross-instance tag-sync design (ADR-IOS-004), iOS and TB had been writing `tm_*` IMAP keywords, Gmail labels, and Exchange categories so the other instance could adopt the classification without re-running the LLM. Two problems accumulated:

1. **User-visible pollution.** Gmail web/mobile showed `tm_reply` / `tm_archive` / `tm_delete` / `tm_none` in the label sidebar. Outlook desktop/web/mobile showed those same strings as colored category chips on every triaged message plus a master-category-list entry. Other IMAP clients (Apple Mail, plain TB) surfaced the strings as raw keyword flags. Users who paid attention to their label/category UI saw TabMail internals leaking through.
2. **Redundant with Device Sync.** The device-sync WSS relay already exchanges `{summary, action, reply}` between connected peers via `ai_cache_probe` — this fully covers the "both devices online" case without any server-side label writes.

The only gap Device Sync leaves uncovered is the *async* cross-device case: device A classifies a message, device B comes online hours later while device A is offline. Previously device B would pick up the classification via IMAP keyword / Gmail label. Now device B runs the LLM independently — one extra LLM call per miss.

**Decision:**

1. iOS no longer reads or writes `tm_*` IMAP keywords / Gmail labels / Exchange categories. All provider `setActionTag` methods are no-ops. All provider parse paths set `actionTag = nil`; the local `MessageAICache` restore + AI classification pipeline is the only populator of `MessageHeader.actionTag`.
2. `GmailProvider.fetchFolders` no longer provisions `tm_*` labels via REST, does not build a `tagLabelMap`, and does not hide legacy `tm_*` labels. Legacy labels are filtered out of the folder list via `UserLabelStore.shouldExcludeLabel` (which already matched the `tm_` prefix for user-label visibility).
3. `ExchangeProvider` drops `tagCategoryMap`. The category → ActionTag resolution in `parseGraphMessage` is removed.
4. `IMAPProvider.buildMessageHeaderInfo` stops extracting ActionTag from IMAP keywords.
5. `NSEDataBridge` stops mirroring the Gmail `tagLabelMap`. `resolveServerActionTag` returns nil unconditionally — the NSE merge falls through to the AI-computed tag on the staging row.
6. `SyncEngineMaintenance.sweepStaleActionTags` keeps clearing local `actionTag` on non-inbox messages (inbox-scoped UX contract) but no longer issues server-side `setActionTag(nil)` calls.
7. `AccountManagerQueue` `.setTag` / `.removeTag` drain branches become explicit no-ops — legacy queued ops flush cleanly, no provider call.
8. **Inbox-exit cleanup for legacy pollution.** Whenever a message moves OUT of the inbox (archive, delete, user-initiated move), each provider strips any residual `tm_*` labels/keywords/categories inline with the move. This is the natural decay mechanism for pre-ADR pollution: as users triage, their on-server `tm_*` count drops to zero. Implementation per provider:
   - **Gmail:** `fetchFolders` records `legacyTmLabelIds: Set<String>` (any label whose name starts with `tm_`). `move()` includes these IDs in the existing `messages.modify` `removeLabelIds` array when `source == "INBOX"`. Zero extra round-trip.
   - **IMAP:** `idempotentMove` issues a `STORE -FLAGS (tm_reply tm_archive tm_delete tm_none)` on the source UIDs before the MOVE when `source.uppercased() == "INBOX"`. One extra round-trip. Best-effort — a STORE failure logs and continues (the move must not be blocked by cleanup).
   - **Exchange:** `move()` calls `stripLegacyCategories(id:)` before `moveMessage` when `source == inboxFolderId`. That helper does a `$select=categories` GET, filters out `tm_*`, and PATCHes the message if anything changed. Two extra round-trips worst case, skipped entirely if no `tm_*` categories present. Best-effort — a strip failure logs and continues.
9. ADR-IOS-004 is marked **superseded** by this ADR.

**What still works:**

- `MessageHeader.actionTag` continues to drive the UI chip everywhere it does today — inbox row chip, message detail, thread bubbles, tag sort order.
- AIService classification still writes `MessageHeader.actionTag` + `MessageAICache.actionTag` via `AccountManagerAI.processSingleMessage` / `setManualTag`.
- User manual override (long-press menu → pick action) still flows: `setManualTag` writes `MessageHeader` and `MessageAICache` locally for persistence across delete/re-insert. It creates no durable `PendingOperation`; legacy `.setTag` / `.removeTag` rows only drain as no-op cleanup.
- Device Sync probe (`DeviceSyncService.probeAICache`) still serves action/summary/reply between peers on cache miss.
- `ActionTag.imapKeyword` / `fromIMAPKeyword` helpers are retained as **legacy stubs** for tests and any one-off migration reads.

**Rationale:**

- **No server-side mutation from a privacy-first email client.** Every user expects an email client to *read* their mailbox, not leave persistent tag/label breadcrumbs visible to other clients and other recipients who share the account.
- **Device Sync is the right layer.** It's a first-class real-time channel between TabMail instances, not a piggyback on IMAP keywords. It doesn't leak TabMail internals into the user's mail provider.
- **One extra LLM call per async-cross-device miss is acceptable.** A classification is ~cents of token cost. Orders of magnitude less than the "we're polluting your Gmail label list" trust cost.
- **Verified no shortcut on TB side.** `nsImapMailFolder.cpp`'s `HandleCustomFlags` overwrites local `keywords` with server state on every folder resync when the server advertises user-flag support (Gmail, every modern IMAP) — so "write `keywords` locally via Experiment, skip IMAP STORE" does NOT work. TB's equivalent work requires a custom painter driven from IDB. (See the parallel work in the tabmail-thunderbird add-on.)

**Consequences:**

- **Async cross-device pickup is lost.** Device A tags, goes offline. Device B online hours later → re-runs LLM. For users who keep both clients open simultaneously, no change. For "phone morning, desktop evening" users, up to 2× LLM cost on overlapping inboxes + possible action-pick divergence (3-call vote is non-deterministic).
- **Existing on-server `tm_*` keywords/labels/categories decay naturally** via inbox-exit cleanup (see point 8). We don't do a wholesale scrub (too risky — irreversible server writes on every message). Instead, cleanup is piggybacked on normal user triage: every archive/delete/move strips the message's `tm_*` residue on the way out. Over time, as users work through their inbox, on-server pollution trends to zero. Label *definitions* still exist in Gmail sidebar / Outlook "All Categories" list until the user manually deletes them (or until Gmail auto-hides unused labels, which varies).
- **NSE `gmailTagLabelMaps` UserDefaults key becomes orphaned.** Old mirror data sits in the app group container; no one reads it. Cleanup is a non-goal (zero-cost to leave).
- **Tests that verified server-side ActionTag resolution (`NSEMergeFullHeaderTests` server-tag-wins cases) are inverted** to pin the new local-only behavior: legacy `tm_*` labels in `providerLabels` are ignored; AI's `msg.actionTag` wins.

**Migration path:**

- On-server data: no proactive scrub. The chip reads from `MessageHeader.actionTag` (not from server labels), so the visual behavior is unchanged for end users; only the label-list pollution gradually fades as messages turn over.
- Local data: no migration. `MessageAICache` and `MessageHeader.actionTag` already contained the canonical local state; we just stop feeding them from provider labels.
- TB parallel work: the tabmail-thunderbird add-on removes TB's tag writes and adds an IDB-driven custom painter for the chip (TB has no single GRDB column for actionTag, so the painter is more involved than iOS).

**Related:** ADR-IOS-004 (superseded), ADR-IOS-010 (Device Sync), ADR-IOS-018 (PendingOperation queue — `.setTag` drain is now a no-op).

**Amendment (2026-07-10) — leaving the inbox clears the tag in the SAME optimistic write.** *(Superseded 2026-07-14 by the Round D-0 amendment below; retained as history.)* `optimisticMoveToFolder` used to enqueue a `.removeTag` PendingOperation on archive/inbox-exit whose drain case is a no-op `break` (correct — tags are local-only), while the local `actionTag` column was never cleared anywhere at move time: the stale chip stayed visible in Archive/Trash list rows (`MessageRowView.effectiveTag` and `TriageRowView` render `actionTag` UNGATED on `isInInbox`; only the detail view gates) until `sweepStaleActionTags` after the next full sync (≤ ~15 min). Now the inbox-leaving move's `updateAll` also sets `actionTag = nil, tagSortOrder = 99` (the sweep's own sentinel), the dead `.removeTag` enqueue is deleted (the drain case stays as a legacy-row flush), and the gesture/tool overlay mutations register `actionTag: .some(nil)` for inbox-leaving moves so the mid-drain window doesn't flash the chip. The former claim that Undo restores the tag via a full-row snapshot save is superseded and rejected by ADR-IOS-060. Undo is an ordinary inverse; any final visible-tag behavior is specified and tested only as end state, without snapshot resurrection. Tests: `AccountManagerActionsTagClearTests` (real archive/move/undo paths; exact Undo-mechanism assertions are being retired under ADR-IOS-060).

**Amendment (2026-07-14, Round D-0) — the tag lives WITH the header; display is gated, data is retained.** The 2026-07-10 destructive clear is reversed. An action tag is inbox-scoped *presentation*, not an inbox-scoped invariant: no move, fold, or sync write may destroy it. `optimisticMoveToFolder` no longer touches `actionTag`/`tagSortOrder`; the fold's clear-on-move and its `actionTagClearedByMove` resurrect-guard are deleted; sync's `normalizeInboxScopedActionTag()` became `normalizeActionTagSortOrder()` (derives only the paired sort key and never nils the tag). Every renderer instead gates on `isInInbox` — the 2026-07-10 stale-chip bug is fixed at the display layer, where it belonged, including the previously ungated `ThreadChildCardView` color bar/chip; `ThreadGroupBuilder.threadTag` aggregates over inbox members only so a retained out-of-inbox tag cannot leak an aggregate chip. Consequence for ADR-IOS-060: Undo needs no tag handling at all — a move back to the inbox re-reveals the retained tag, so the inverse move is genuinely ordinary and nothing is restored. `sweepStaleActionTags` remains the only reclaimer, as disk hygiene (age-based TTL semantics mirroring the TB addon are the follow-up in this same round). Pinned by tests: a provider DTO with `actionTag: nil` can never clear a local tag on merge; archive→return-to-inbox retains and re-displays the tag through both the fold and the full DB path.

**Amendment (2026-07-14, Round D-0b) — the sweep is a real TTL.** `sweepStaleActionTags` reclaims an out-of-inbox tag only once `actionTagSetAt` is older than `SyncConfig.actionTagTTLSeconds` (604,800 s — byte-parity with the TB addon's `actionTTLSeconds`; TB physically strips tags on inbox-exit only because Thunderbird renders its native tags and cannot gate display — iOS gates, so retention plus TTL is the equivalent-or-better lifecycle). Inbox tags are never swept. Unreleased migration v72 adds nullable `messageHeader.actionTagSetAt` (no index) and backfills tagged rows at migration time, establishing `actionTag != nil ⇒ actionTagSetAt != nil`; a NULL stamp is fail-safe (treated as expired — a writer that misses stamping degrades to the pre-TTL clear, never a leak). `MessageHeader.setActionTag(_:at:)` keeps the tag/stamp/sortOrder triple atomic; new assignments stamp now, identity-merge copies carry the source stamp, and the NSE staged-merge stamps conditionally so re-merging an unchanged tag does not reset its clock.

## ADR-IOS-037: NSE/Main-App AI Ownership Lease (Cross-Process Coordination)

**Context:** APNs pushes with `mutable-content: 1` always dispatch to the Notification Service Extension in its own process, regardless of main-app state (foreground / background / suspended / terminated). There is no Apple API to suppress NSE when the main app is foreground. Historically the NSE unconditionally called backend `/completions/chat` for summary + action on every push, and the main-app `ActiveAIQueue` also ran summary + action for the same message seconds later — two identical backend calls per push. Additionally, the main-app privacy opt-out flag (`privacy_opt_out_all_ai`) lived in `UserDefaults.standard`, which is a different namespace in the NSE process, so the NSE silently bypassed the toggle and kept calling backend AI after the user opted out.

**Decision:**

1. **Opt-out flag moves to the App Group shared suite** (`group.ai.tabmail`). `AIService.optOutStore` is the single source of truth. All `@AppStorage` usages and any direct `UserDefaults.standard.bool(forKey: optOutAllAIKey)` reads now go through `AIService.optOutStore`. `NSEState.isAIDisabled()` reads the same store. A one-time `AppDelegate.migrateOptOutFlagToSharedSuite()` copies any pre-existing value from `.standard` on first launch.
2. **AI ownership lease on `nse_processed_message`**. Two new columns — `aiOwner TEXT` (`"nse"` | `"mainApp"` | NULL) and `aiHeartbeatMs INTEGER` — added in staging-DB migration v5. The holder refreshes `aiHeartbeatMs` every `AIOwnershipLease.heartbeatIntervalMs` (1s) while AI runs. A gap > `staleMs` (4s) means the holder died and the other side may take over. Claim is atomic via conditional UPDATE (`WHERE aiOwner IS NULL OR aiOwner = :me OR (now - heartbeat) > staleMs`) with `db.changesCount` as the win check.
3. **NSE gate + claim**. `NotificationService.process` step 6 is gated: skip if `NSEState.isAIDisabled()`; skip if main app holds a fresh claim; otherwise `tryClaim(owner: .nse)` + spawn heartbeat Task + run AI + cancel heartbeat + `release(owner: .nse)` (conditional on still owning).
4. **Main-app poll + claim**. `ActiveAIQueue.executeJob` opens the NSE staging DB (via `NSEDataBridge.openStagingDB()`), checks `AIOwnershipLease.state`, and if NSE holds a fresh claim polls every `mainAppPollIntervalMs` (1s) up to `mainAppPollMaxMs` (28s). Once NSE publishes a result (`summaryBlurb` set or `aiCompleted=1`), main app triggers `NSEDataBridge.mergeNSEStagingData` and re-reads the `MessageHeader` — if the job's field is now populated, it returns without running the LLM. Otherwise main app `tryClaim(owner: .mainApp)` + heartbeat + runs AI + releases. Reply always runs on main-app side regardless of lease (NSE has no Reply pass).
5. **Shared helper in `Shared/Persistence/AIOwnershipLease.swift`** so both targets use identical lock semantics without file-target duplication.

**Rationale:**

- **Staging DB as coordinator is the ground truth.** No process-state guessing (main-app heartbeat timestamps, Darwin notifications). Both sides inspect the same row; claim race is decided by SQLite's atomic UPDATE.
- **Lease-with-heartbeat handles crash recovery for free.** If NSE is killed mid-AI (OOM, 30 s hard budget), the heartbeat goes stale after 4 s and main app takes over on its next dispatch tick. Symmetric for a main-app crash.
- **1 s heartbeat is cheap at local-only scope.** Both reader and writer are the same on-device DB; the cost is a single conditional UPDATE per second per active message. At most one message is "active" in NSE at a time, and main-app AI queue processes serially per message.
- **Max 28 s poll keeps main-app AI from deadlocking on a stuck NSE.** Ceiling is below NSE's 30 s iOS budget — if NSE hasn't produced a result in 28 s, main app takes over.
- **Privacy gate separated from lease.** NSE can check opt-out before doing anything, including claiming. Main app also gates on opt-out as today — the lease just prevents duplicated work when opt-out is OFF.
- **No protocol version bump required on the staging table.** Columns are additive (SQLite `ALTER TABLE ADD COLUMN`), default NULL — older main-app versions reading the staging DB just see nullable columns they ignore.

**What still works:**

- `NSEDataBridge.mergeNSEStagingData` still brings NSE-produced AI fields into `MessageHeader` + `MessageAICache` on next wake; the lease just ensures the NSE is the one producing them instead of both sides.
- Device Sync probe (`DeviceSyncService.probeAICache`) still runs before the lease check, so TB peer results short-circuit both NSE and main-app work.
- `MessageAICache` dedup still catches "already computed" cases at the field level after any cross-process race.

**Consequences:**

- **Existing opt-out users whose flag lived only in `.standard`** get auto-migrated to the shared suite on first launch. If the migration runs after some pushes, those pushes' NSE wakes briefly bypass opt-out (NSE can't see the flag until the main app runs). Migration is one-shot and idempotent via `guard shared.object(forKey:) == nil`.
- **One schema migration** (staging DB v5). Additive; no data loss on downgrade (older app simply ignores the columns).
- **Main-app wait up to 28 s for NSE results** on the very-first job per message. Typical NSE completion is ~9 s, so worst-case user-visible delay is bounded by NSE's own budget.

**Tuning** (`AIOwnershipLease`):

- `heartbeatIntervalMs = 1000`
- `staleMs = 4000` (4 × interval, tolerates scheduling jitter)
- `mainAppPollIntervalMs = 1000`
- `mainAppPollMaxMs = 28000` (NSE's 30 s budget minus a safety margin)

**Related:** ADR-IOS-008 (AI processing architecture), ADR-IOS-010 (Device Sync).


## ADR-IOS-038: Demo Mode — Custom JWT + Local Mock Provider + Pre-Baked AI Cache

**Status:** Accepted (2026-04-30)

**Decision:** Add a "Try the demo without creating an account" entry on the
login screen that lets a brand-new user explore TabMail with sample data
without creating a Supabase user. Implemented in three layers:

1. **Backend identity:** stateless HS256 demo JWT (`iss: 'tabmail-demo'`)
   minted by new `POST /demo/start` endpoint. Backend's `gatewayHelpers`
   peeks the issuer and short-circuits to a synthesized entitlement with
   `user_id = '00000000-0000-4000-8000-44454d4f0000'` (fixed UUID
   sentinel — hex `4d4f` mnemonic "DE-MO"). All demo cost rolls up to that
   single sentinel row in `usage_events`. A per-token in-memory rate limit
   defends against abuse; a per-IP rate limit on `/demo/start`
   prevents mint flooding. Dual-key HMAC rotation (`PRIMARY` +
   `PREV`) mirrors `INTERNAL_USAGE_SECRET`.

2. **Local mock provider:** `DemoProvider` (EmailProvider) and
   `DemoCalendarProvider` (CalendarProvider) answer entirely from GRDB —
   no network. Demo account is `accountId == "demo-account"`. Demo
   calendar events live in a new `demoCalendarEvent` table (table-prefix
   scoping for clean wipes).

3. **Pre-baked AI cache invariant:** every seeded inbox message
   has `MessageHeader.summaryBlurb`, `actionTag`, and (where applicable)
   `cachedReply` populated by `DemoSeed`, plus a corresponding
   `MessageAICache` row. Opening any seeded message MUST NOT fire an LLM
   round-trip. `AIService.process` carries a hard demo guard that
   returns empty results rather than running the LLM, even if upstream
   short-circuit logic ever changes.

**LLM call accounting:** the user-visible 50-call cap lives
on iOS (`DemoModeStore.callsConsumed` in UserDefaults, persisting per
install). Counter is decremented at three chokepoints — and only there:
`AIChat.sendChatMessage`, `AIInlineEdit.performInlineEdit`, and the
`BackfillAIQueue.enqueueActionRefine` enqueue site driven from
`AccountManagerAI.applyManualTag`. Tool rounds within one agent
turn don't double-count. Refund matrix: `URLError`,
`CancellationError`, 5xx, demo-token 429 refund; 4xx/parse failures don't.

**Consent gates:** demo runs the production `ConsentGateView` and
`AIConsentView` on entry, but writes to demo-prefixed `@AppStorage` keys
(`demo.hasCompletedConsentGate`, `demo.hasSeenAIConsent`,
`demo.aiEnabled`) so production gates run from scratch when the user
later signs up. `AIConsentView` was refactored to remove its internal
`AIService.writeOptOutFlag` call — caller now decides where to persist
the AI choice. `PushConsentView` is skipped in demo (no real push).

**AI-disabled demo:** when the user declines AI on the demo gate,
seeded summaries / action chips / cached replies / chat pill / inline
edit are all rendered as off (the data stays in GRDB, the views just
gate on `DemoModeStore.aiEnabled`). The demo Settings page exposes an
"Enable AI" button that re-runs the AI consent gate without re-seeding.

**Cleanup:** `DemoModeService.exit()` wipes:
- `accountId == "demo-account"` rows from `messageHeader`, `folder`,
  `messageBody`, `messageAICache`, `outboxMessage`, `pendingOperation`,
  `account`.
- `chatTurn WHERE sessionId LIKE 'demo:%'`.
- `demoCalendarEvent` (full table — demo only).
- FTS demo entries via new `SearchIndex.purgeForAccount(_:)`.
- memory.db demo entries via new `MemoryIndex.purgeForSessionPrefix(_:)`.

The 50-call counter, demo gate flags, and TipKit shown-state all
**persist** across exit. Only uninstall resets them.

**Once user signs up (refined 2026-05-01):** the original plan used a
sticky `demo.servedItsPurpose` UserDefault set on first non-demo account
add. **Replaced with a state check**: `TabMailLoginView`'s demo button now
gates on `navigationStore.hasAnyAccount` (a new field on `NavigationStore`
that counts active rows in `account` including `calendarOnly == true`).
Reactive on `.backgroundDataDidChange`, so adding any account hides the
button on the next refresh and removing all accounts (sign-out + wipe)
restores it — no sticky flag, no need to clear UserDefaults to recover.
`connectAccount` still calls `DemoModeService.purgeOrphanedDemoData` to
clean residual demo rows.

**What we explicitly DO NOT do in demo:**
- Push notifications (`PushNotificationService.subscribeAccount` is
  guarded).
- Device Sync (`DeviceSyncService.connect` is guarded).
- Real EKEventStore writes (ICS imports route to `DemoCalendarProvider`
  via guard in `ICSCalendarImporter.presentCalendarImport`).
- Vector embeddings during seeding (FTS-only).
- Proactive reminder notifications (`ProactiveNotifyService` entry points
  are demo-guarded — rescheduling from the demo-scoped reminder list would
  replace the user's pending OS notification schedule and pollute
  `ReachedOutStore` with demo hashes; added 2026-07-02).
- KB refinement (the session-expiry enqueue skips `demo:` sessions — a
  demo chat must never rewrite the user's KB; added 2026-07-02).

**Chat + reminder isolation (added 2026-07-02):**
- **Every demo chat sessionId carries the `demo:` prefix** via
  `DemoModeStore.scopedSessionId(_:)` — `demo:{uuid}` (inbox),
  `demo:msg:{key}` (message detail), `demo:compose:{draftId}` (compose).
  ALL mint AND lookup sites route through the helper (they live in
  `DynamicIslandChatButton`); `DraftStore` compose-turn deletes target both
  the plain and `demo:`-prefixed variants unconditionally. The prefix is
  what makes `DemoSeed.wipe`'s chatTurn/chatHistory range deletes and
  `MemoryIndex.purgeForSessionPrefix("demo:")` actually match — before
  this fix, demo turns were minted UNprefixed, so they were never wiped
  and mixed freely with the user's sessions. Within a demo run, chat
  behaves exactly like the real app (sessions persist, resume, swipe as
  history pages) — they are just namespaced, and all of it is wiped on
  exit. Wipe cost is unchanged at boot: `hasDemoData` still short-circuits
  on one PK lookup, and both range deletes use the `chatTurn_sessionId` /
  `chatHistory_sessionId` indexes (half-open range form, no LIKE scans).
- `ChatStore.inboxSessionScopeSQL(demoActive:)` scopes the session-history
  swipe UI: demo mode lists only `demo:` inbox sessions; normal mode
  excludes all `demo:` sessions. Inbox-session eviction always excludes
  demo sessions (they must not crowd out or count against the user's
  session limit).
- `ChatPillState.shared.removeAllSessions()` runs on demo entry
  (`completeSetup`, behind the seeding splash) and on exit, so in-memory
  pill state (live turns, loaded pages, reminder buffers) never crosses
  the demo/real boundary.
- `ReminderBuilder` is demo-scoped both directions: message reminders
  filter `accountId == "demo-account"` in demo (3 seeded reminders match
  the 3 cards shown on chat expand) / `!=` in normal mode, and KB
  reminders/tasks parse from the demo prompt overlay (below). The account
  filter is an extra AND predicate on the existing reminder query — no new
  table scans. Cache invalidates on entry/exit via the existing
  `.remindersDidChange` posts.

**Tool-boundary isolation (added 2026-07-02, same-day follow-up):** an
audit found essentially the whole agent-tool layer crossed the demo/real
boundary (`ToolContext.db` is the shared pool; `ChatIdTranslator` is one
global map; `registerDemoProviders` leaves real providers registered). The
fix gates at shared chokepoints, not per-tool patches:
- **Nonisolated demo flag** — `DemoModeStore.isDemoActive`
  (`Mutex`-mirrored from `isActive.didSet`) so nonisolated readers
  (PromptStore snapshots, DisabledRemindersStore, Search/Memory indexes,
  tool guards) can branch without a MainActor hop.
- **Prompt overlay** — while demo is active, ALL FOUR PromptStore fields
  (kb / composition / action / templates) read+write `demo.`-prefixed
  UserDefaults keys (`PromptStore.storageKey`), seeded from bundled
  defaults by `enterDemoOverlay()` (called in `completeSetup`) and torn
  down by `exitDemoOverlay()` (called in `exit()` BEFORE `isActive` flips
  false — ordering contract). Demo-time `didSet`s skip NSE mirror, Device
  Sync broadcast/timestamps, and prompt history; `applySync` / `reset*` /
  `loadHistory` / `restoreFromHistory` are demo-guarded. Device Sync is
  `disconnect()`ed on demo entry (an existing coexistence connection could
  push peer state into the overlay) and `forceReconnect()`ed on exit.
  This closes kb_add/kb_del/reminder_add/reminder_del/task_*/template_*
  AND gives demo chat a demo KB (snapshot readers are demo-aware).
- **`DemoToolGuard`** (in DemoSeed.swift) — `accountScope(demoActive:)`
  GRDB predicate + `headerAccessible(_:)` (blocks BOTH directions) +
  `blockedMessage`. Applied in: InboxReadTool (account-scoped queries),
  EmailRead/Open/Reply/Forward/Archive/Delete (post-resolve header guard —
  closes the execute hole where stale global ChatIdTranslator numeric IDs
  let a demo chat act on REAL emails), EmailComposeTool (demo forces the
  demo account; normal mode excludes it — coexistence has TWO isPrimary
  rows), Contact*/ChangeSetting tools (blocked in demo).
- **SearchIndex** — `demoAccountScopeSQL` on the indexed
  `message_meta.accountId` in FTS candidates / FTS-only / date-scan legs;
  vector-only hybrid hits filtered by `headerIdInDemoScope` (headerId =
  `accountId:folderPath:messageId`). Covers email_search AND the inbox
  search UI ("Search All" spanned every account).
- **MemoryIndex** — `demoScopeSQL` (sessionId `demo:` range) on the FTS
  leg, the vec KNN leg (meta join), and `readByTimestamp` — memory_search /
  memory_read never cross modes (NULL sessionId = legacy real).
- **CalendarProviderDispatch** — demo resolves ONLY `DemoCalendarProvider`
  (new `CalendarBackend.demo` case); normal mode skips the demo entry.
  Without this, coexistence calendar_read leaked real events and
  calendar_event_create wrote to the REAL calendar.
- **DisabledRemindersStore** — demo operates on `demo.disabled_reminders_v2`
  (fresh map, no Device Sync broadcast); deleted on exit.
- **BackfillAIQueue** — `dispatchBatch` defers while demo is active (a
  queued real-session KB/action refine would run against the demo overlay
  and authenticate via the demo token); rows drain after exit.
- **DemoSeed.wipe** additions: `chatIdMapping` (demo range) +
  `pendingCalendarOperation` (demo account).
- Boot cost unchanged: everything is either an extra predicate on existing
  queries or gated behind `isDemoActive`; the wipe stays behind the
  `hasDemoData` PK short-circuit with indexed range deletes.

**Post-commit audit findings (2026-07-02, all fixed same day):**
- Fork path (`forkFromMessage`) minted an UNscoped sessionId — wrapped in
  `scopedSessionId` (the invariant: EVERY sessionId mint/lookup routes
  through it; grep for `UUID().uuidString` near chat code when touching).
- `ChatPillState.removeAllSessions()` now CANCELS `activeChatTask` (and
  drops resume checkpoints): a streaming agent loop re-samples the demo
  flag per tool call, so a task surviving the mode flip executes tools on
  the wrong side of the boundary. Teardown (+ Device Sync disconnect)
  moved from `completeSetup` to `start()` so the entry window is closed
  the instant `isActive` flips.
- In-flight refinements that complete DURING demo are dropped at their
  save sites (`KBRefinementService`, `AIPromptLearning`) — else the real
  refined KB/action text would be spliced into the demo overlay (visible
  in a recording). `registerAlarmsWithPushWorker` +
  `TaskEvaluationService.evaluate` are demo-guarded (empty demo KB would
  GC real task execution state / clobber alarm registrations).
- `DisabledRemindersStore` RMW ops capture `activeKeyV2` once (read+write
  same key even if the mode flips mid-operation).
- `DemoSeed.wipe` also deletes `draft` rows (demo compose autosaves).
- `MemoryIndexTests.vecCandidates_demoScope` pins the vec0 KNN
  subquery+JOIN shape (a planner rejection would silently degrade memory
  search to FTS-only in normal mode).
- Separately (same session): `BackendConfig.useDevServers` no longer
  defaults to dev on DEBUG builds once the debug menu is unlocked — ALL
  builds default to prod, dev is toggle-only. The old default silently
  pointed debug builds at dev.tabmail.ai, whose environment auth gate
  blocks `/demo/start` (not in `publicPaths`) → "Could not start demo:
  HTTP 401". Demo mint is prod-only by decision.
- Debug-menu entry (`startFromDebugMenu`) sets
  `DemoModeStore.enteredFromDebugMenu` (in-memory): RootView suppresses
  the DemoBanner for clean demo recordings; "Exit Demo Mode" and
  `resetCallBudget()` (reset the 50-call counter) live in the debug menu
  instead.

**Related:**
- The demo-auth mint/verify/throttle, the admin demo-stats readout, and the
  HMAC secret-rotation tooling all live server-side.
- ADR-IOS-008 (AI processing architecture — demo replicates the
  short-circuit).
- ADR-IOS-018 (PendingOperation queue — DemoProvider stubs the drain
  side).

---

## ADR-IOS-039: Idempotent HTML Render Fit + Scroll-Phase Height Freeze

**Date:** 2026-06-09

**Context:** Two user-visible bugs shared one root. (1) In the message
detail view, slow scrolling with expanded related messages caused cards to
overlap / render on top of each other. (2) Backgrounding the app with an
HTML message open and re-foregrounding shrank the message fonts a little
more on every cycle.

`AutoSizingHTMLView`'s pipeline is measure→mutate→re-measure: `fitViewportJS`
measures content overflow, then MUTATES the document (viewport-meta widen,
inline width strips, body padding zeroing) so WebKit scales wide emails
down. The height arm of this pipeline had already been hardened
(`html,body{height:auto}` override; `__tmLayoutVp` instead of
`window.innerWidth`, WebKit bug 170595), but the width arm was
**non-idempotent**: re-running `fit()` against an already-widened document
re-measured widened CSS px against an unreliable `innerWidth` and re-mutated
the document. The `didBecomeActive` foreground observer re-runs `fit()` with
no baseline reset — every background→foreground cycle re-entered the widen
logic (bug 2). The same non-determinism fed bug 1: `handleHeightMessage`
only applies a height when it CHANGED, so scroll-time re-measurement
(WKWebView recycle/process-resume during List scrolling) could only move
rows — and overlap cards via List self-sizing mid-pan — when the
re-derived scale/height drifted from the previous pass.

**Decision:**
1. **Idempotency guard in `fitViewportJS`** — if `window.__tmLayoutVp` is
   already set, the document is already fitted: bail (no measure, no
   mutation). Same document + same device width → same answer.
2. **Swift-stamped baseline width** — `fit()` stamps `window.__tmDeviceWidth`
   from `webView.bounds.width` before the script runs; `fitViewportJS`
   measures against it (`innerWidth` is only a last-resort fallback).
   `monitorHeightJS` vp fallback chain: `__tmLayoutVp || __tmDeviceWidth ||
   innerWidth`.
3. **Explicit reset path for REAL width changes** — `viewportResetJS(deviceWidth:)`
   (updateUIView width-change branch) clears `__tmLayoutVp`, re-stamps
   `__tmDeviceWidth`, and restores `width=device-width` BEFORE `fit()` so
   the guard re-derives from a clean baseline.
4. **ScrollFreezeGate** (Mutex-based, not @MainActor — the WKScriptMessageHandler
   Coordinator is nonisolated) — while `MessageDetailView`'s List scroll
   phase is non-idle, Coordinators buffer changed heights (`pendingHeight`,
   latest-wins) and flush on `.scrollFreezeReleased`. Covers the residual
   legitimate height changes (late image loads) that idempotency can't
   remove. Exception: never-sized rows (`height <= 1`) apply immediately.
   `end()` is also called from `onDisappear` so the gate can't stick frozen.

**Rationale:** The measured height is only cacheable/stable if the render is
a pure function of (content, device width). Fixing idempotency makes the
existing `visualHeight != height` dedup absorb all steady-state
re-measurements for free; the freeze gate then only ever buffers genuine
changes. A height seed cache (considered first) would have cached the
output of a non-converging pipeline — wrong order.

**Consequences:**
- Foreground re-fit is now a no-op for already-fitted documents (fonts
  stable across background cycles).
- Mid-scroll height application is deferred to scroll-idle; rows cannot
  resize under the user's finger.
- A late image load while scrolling keeps the stale row height until the
  scroll idles (acceptable: sub-second, and strictly better than overlap).
- If a future code path needs a genuine re-fit (e.g. content injected into
  an existing document), it MUST go through the reset path, not bare `fit()`.
- Regression tests: `EmailRenderPipelineTests` (idempotency guard, stamped
  width, vp fallback chain, reset semantics) + `ScrollFreezeGateTests`.

**Related:** PROJECT_MEMORY.md "HTML Email Render Pipeline" section;
EmailHTMLWrapper height-arm overrides; WebKit bug 170595.

**Addendum (2026-06-09, same day — log evidence + HeightSeedCache):**
A post-fix device log (`logmain.log`) confirmed decisions 1–4 working (5×
foreground re-fits bailed as idempotent no-ops; all re-measurements
converged to identical values) but surfaced the residual overlap source:
SwiftUI List dismantles far-offscreen rows, and when an expanded card
scrolls back toward the viewport the whole `AutoSizingHTMLView` — INCLUDING
its `@State height` — is recreated. The same message reloaded 5× in one
scroll session with `frameH=1` at onload: the row collapses to 1 pt,
shifting rows below up by the card height, then re-inflates ~200–500 ms
later when the fresh WKWebView re-measures (the `height <= 1` freeze
exception correctly applies it mid-scroll). Fix: **HeightSeedCache** —
in-memory (NOT disk; ADR-004) map of headerId → last applied visual height,
written on every applied height, read in `AutoSizingHTMLView.init` to seed
`@State height`. The seeded row re-enters at its real height; the recreated
WKWebView's idempotent re-measure returns the identical value and the `!=`
guard drops it — the row never moves. Seeding is only sound BECAUSE of the
idempotency from decisions 1–3; a seed cache over the old non-convergent
pipeline would have cached drifting values (why this was sequenced last).
Width changes are accepted as a one-snap correction (~200 ms) rather than
keying the cache by width.

**Addendum (2026-07-04 — post-image-load width recheck):** hiding deferred
images during `measureMaxRight` (the 2026-06-29 phantom-overflow fix) makes
an IMAGE-DRIVEN width invisible to `fit()`: FleetOptics' centered 515px
table measured 307px with its 12 remote images hidden → fit committed a
400px layout viewport → the images loaded, the table re-expanded to 515px,
and the overflow stayed clipped forever (the idempotency guard correctly
blocks bare re-entry; height had post-load re-report paths, width had
none). Fix adds a THIRD sanctioned re-fit trigger alongside rotation/sheet
resize: `postImageWidthRecheckJS` waits (event-driven, load/error listeners
keyed exactly like the measure-hide) for the LAST deferred/in-flight image
to settle, re-measures the rightmost edge against `__tmLayoutVp ||
__tmDeviceWidth` with the same 8px slop, and posts a ONE-SHOT
`{requestWidthRefit:true}`; `Coordinator.resetAndFit()` then runs
`viewportResetJS + fitViewportJS` in a SINGLE JS turn (one WebKit
layout/scale commit — no intermediate device-width paint of the revealed
content). This preserves purity: the final state is still a function of
(content INCLUDING loaded images, device width); the one-shot flag plus the
reset-path discipline prevent loops. Companion widen-loop fix: the target
now includes the culprit's own width (`max(maxRight, culpritWidth)`,
measured while images are hidden) because a centered (`margin:auto`)
culprit re-centers on every pass and its `rect.right` closes only half the
overflow per pass — it exhausted `MAX_PASSES` still clipped and could trip
the runaway guard into reverting a fixed-width email to 1.0×. Tests:
`fitViewportWidenTargetsCulpritWidth`, `postImageWidthRecheckPolicy`.

## ADR-IOS-040: Zero (BYOK) Plan in the IAP Plan Picker — Three-Tier, Display-Only Naming

**Date:** 2026-06-10
**Status:** Accepted
**Context:** PLAN_BYOK_PRICING_PAGES.md Phase 3; global ADR-025 (explicit-zero
priority budget → slow queue). The BYOK plan (Apple products
`ai.tabmail.byok.monthly`/`.yearly`) ships as the cheapest, first-listed tier:
no priority AI budget, AI via the user's own keys or the throttled queue.

**Decisions:**
1. **Ranks renumber to Unknown=0 / BYOK=1 / Basic=2 / Pro=3** —
   `StoreKitManager.tierRank(for:)` (product ID) and `tierRank(forTier:)`
   (backend tier string), matching billing-worker/apple-webhook ranks. All
   upgrade/downgrade direction logic (PlanCard buttonLabel, entitlement
   best-plan pick) is rank-driven; no binary `isPro` branching remains.
2. **Display-only naming (D6):** user-facing label is "Zero";
   `StoreKitManager.displayPlanName(forTier:)` maps "BYOK"→"Zero" at render
   time ONLY. `planName(for:)` keeps returning backend-facing "BYOK" because it
   must equal `AccountInfo.planTier`. Internal ids stay byok/BYOK everywhere
   (product IDs, KV plan_name, planQuotas). Site precedent: PLAN_DISPLAY
   (pricing.js), PLAN_TIER_DISPLAY (dashboard.js).
3. **Plan picker sorts by explicit tier order** (Zero → Basic → Pro), not by
   price — "BYOK happens to be cheapest" is not a contract.
4. **Trial gating is per-product intro offer, not group eligibility alone:**
   `checkTrialEligibility()` reads eligibility from the first product that HAS
   an introductory offer (Zero has none and sorts first — `products.first`
   would report ineligible and hide the Basic/Pro "2 weeks free" badge).
   PlanCard shows trial badge/label only when group-eligible AND the product
   carries an intro offer (suppresses it on Zero). Zero NEVER has a trial (D8).
5. **Cost disclosure (D7):** the plan picker footnotes carry the same note as
   the site FAQ — provider API bills can be significant; TabMail's own AI
   infra (Basic/Pro) is generally 10–100× cheaper for the same usage.
6. **Quota shows N/A for Zero** (dashboard): a percentage of a zero budget is
   meaningless; sublabel explains no-priority-budget. Daily-quota chart already
   hides via `maxMonthlyCostCents > 0`.
7. **Configuration.storekit group levels fixed to Apple's convention** (level
   1 = highest service tier): Pro=1, Basic=2, BYOK=3. The file previously had
   Basic=1 < Pro=2 (inverted). Local-testing only; ASC group order must be set
   to match (Pro highest → Basic → Zero lowest). Verify upgrade/downgrade
   direction during the sandbox IAP smoke before release.
8. **No `storeKitConfiguration` on any scheme** — verified 2026-06-10: the
   simulator loads REAL App Store product metadata (live ASC prices/names)
   without any local StoreKit configuration, which is exactly what the
   plan-picker screenshots (12-15) should show. Pinning the local
   Configuration.storekit would risk screenshots rendering placeholder
   prices. The file remains for optional manual StoreKit-testing in Xcode
   (e.g. sandbox-verifying group-level upgrade/downgrade direction).

**Related:** global DECISIONS.md ADR-025; PLAN_BYOK_PRICING_PAGES.md §6/§7.

---

## ADR-IOS-041: GRDB Database Suspension — 0xdead10cc Defense

**Date:** 2026-06-12
**Status:** Accepted

**Context:** TestFlight crash reports from 1.6.3 and 1.6.5 showed `RUNNINGBOARD 0xdead10cc` kills: iOS terminated the app at suspension time because SQLite file locks were still held. Implicated paths: `SyncEngine.scheduleMaintenanceInBackground` (`BodyAssetMaintenance.pruneOrphans`, `deleteAllAssets`), `refreshAICacheTTLAndPurge` (post-`jobCompleted`), and `selfHealFTSBodyMembership` (startup self-heal) — all background DB work on detached tasks with no lifecycle protection. Per-call-site `beginBackgroundTask` wrapping (the existing `backfill-grace` / `ai-job-*` pattern) cannot fully solve this: cooperative cancellation is asynchronous and cannot guarantee no lock is held at the suspension deadline, and every new code path must remember to wrap itself.

**Decision:** Enforce the OS invariant ("no file locks while suspended") mechanically at the database layer, with `DatabaseSuspension` deciding *when*:

1. **Every main-app GRDB connection sets `Configuration.observesSuspensionNotifications = true`** — `AppDatabase` (tabmail.sqlite), `SearchIndex` (fts.db), `MemoryIndex` (memory.db), `BodyAssetStore` manifest queue, NSE staging queues (`NSEDataBridge`, `createNSEStagingDBIfNeeded`). While suspended, GRDB releases/refuses locks; lock-acquiring accesses throw `DatabaseError` `SQLITE_ABORT`/`SQLITE_INTERRUPT` — **except reads on WAL databases, which keep working** (GRDB checks the actual `PRAGMA journal_mode`). The flag is inert in the NSE process (nothing posts the notification there; the NSE is terminated, not suspended).
2. **`DatabaseSuspension` (Services/DatabaseSuspension.swift)** posts `Database.suspendNotification` from the **expiration handler** of a `db-quiesce` `beginBackgroundTask` armed at `didEnterBackground` — NOT at backgrounding itself. iOS expires all of an app's assertions together at the app-wide background deadline, so every in-flight grace-window pattern (`backfill-grace`, `ai-job-*`) keeps its full window; behavior changes only in the final instant, where previously the process was SIGKILLed mid-write.
3. **Every background execution entry point resumes** (`Database.resumeNotification`) and re-arms the quiesce window on completion via `beginBackgroundWork`/`endBackgroundWork` (work-unit counter): silent push (`AppDelegate.didReceiveRemoteNotification`), BGAppRefresh + BGProcessing task bodies (`SyncScheduler`), background notification actions (MARK_READ/ARCHIVE/DELETE in `NotificationDelegate` — these run WITHOUT foregrounding; missing this would abort user-intention writes), and foreground return (`willEnterForeground`).
4. **BGTask expiration handlers additionally call `DatabaseSuspension.postSuspendImmediately`** — the mechanical backstop for the wind-down race where cancelled work straddles the deadline.

**Why aborted transactions are safe here:** the entire codebase already requires every operation to survive dying at any instant (Resilience Rule 3, ADR-IOS-001/003): maintenance is idempotent and re-runs, self-heals re-walk, PendingOperation/Outbox drains retry. A suspension-abort (atomic rollback, process survives) is strictly better than the prior failure mode (whole process SIGKILLed mid-write). Double work is accepted; double-SEND is not — the `sentAt` stamp (the double-send firewall) was hardened from single-attempt to `retryWrite` (3 attempts) per Outbox rule 2, and `reconcileOutbox`'s `sending`+`sentAt==nil` → re-queue path is unchanged (same window as the pre-existing crash case, gentler failure).

**Alternatives considered:** (a) wrapping every DB-touching path in `beginBackgroundTask` — rejected: per-call-site convention, structurally cannot guarantee the deadline; (b) full quiescence coordinator + moving maintenance to BGProcessingTask — rejected for now as over-engineering: the mechanical layer alone removes the crash class, and the existing schedulers already cancel work on expiration.

**Consequences:**
- Writes attempted in the suspended instant throw `SQLITE_ABORT`/`SQLITE_INTERRUPT` — callers must treat as retryable-later (all audited paths already do; see tests).
- Non-WAL queues (BodyAssetStore manifest, NSE staging) abort reads too while suspended — acceptable (only maintenance/merge touch them in background, both retryable).
- GRDB marks the suspension API 🔥 EXPERIMENTAL (v7.10.0) — pin behavior with `DatabaseSuspensionTests` on any GRDB upgrade.

**Tests:** `TabMailTests/Database/DatabaseSuspensionTests.swift` (suspend→write aborts / WAL reads survive / resume restores; straddling transaction rolls back atomically; non-WAL queue abort; unflagged DB unaffected; interrupted-maintenance retry). Outbox recovery state pinned by `OutboxIntegrationTests` ("sentAt nil + status sending → reset to queued").

**Amendment (2026-06-17) — never strand a FOREGROUND database; don't surface the abort.** Field log showed the DB stuck suspended *while the app was in the foreground*, so EVERY subsequent foreground sync threw `SQLite error 4: Database is suspended` and surfaced as `lastSyncFailed = true`. Root cause: the BGTask **expiration handlers** (`SyncScheduler` BGAppRefresh ~811 / BGProcessing ~938) called `postSuspendImmediately` **unconditionally**, but resume fires only on a foreground *transition* (`willEnterForeground` / `beginBackgroundWork`). When a BGTask runs/expires while the app is foreground (user reopened it, debug-simulate, foreground-scheduled task), the suspend lands with no following transition → stranded forever. Fix, two parts:
- **Root cause:** `DatabaseSuspension` now mirrors app-active state in a `nonisolated static Mutex<Bool> appActive` (seeded in `start()` from `applicationState != .background`; updated by `didEnterBackground`=false / `willEnterForeground`+`didBecomeActive`=true). `postSuspendImmediately` **skips the suspend when `appActive`** — a foreground app is never frozen by iOS, so there is no 0xdead10cc risk and suspending would only strand the DB. Added a `didBecomeActive` resume observer as a belt-and-suspenders net (covers a suspend that lands during a transition, which `willEnterForeground` alone misses).
- **Surfacing:** the two FOREGROUND sync catch paths (`InboxViewModel.performSync`, `AccountManager.foregroundSyncOne`) now have a `catch where error.isDatabaseSuspensionAbort` arm that does NOT set `lastSyncFailed` / banner (the 13 background write paths already used this helper; the foreground ones were the gap).
- Pure-classifier coverage: `IsDatabaseSuspensionAbortTests` in `ErrorClassificationTests.swift`. NOTE distinct from the unrelated `isTransientError` (HTTP 5xx/429) fix landed the same day.

---

## ADR-IOS-042: Stale-Detection Overlap Window Is Measured in the Fetch's Ordering Dimension (UID for IMAP, date for Gmail/Exchange)

**Context:** Full-sync (`SyncEngine.runSyncMessages`) fetches only the newest `SyncConfig.syncMessageLimit` (=50) messages per folder, then stale-DELETEs local rows in the "overlap window" the server didn't return. The window was bounded by **message date** (`date >= min(fetched dates)`) for every provider. That is only safe when the windowed fetch's ordering correlates with date. It does NOT for IMAP: `fetchMessages(limit:)` returns the highest **UIDs**, and a folder's UID order is **archive-time**, not message date. Archiving an OLD-dated email assigns it a fresh HIGH UID, so it enters the newest-50 and drags `min(fetched dates)` backwards — sweeping every mid-range month that wasn't in the newest-50 into "stale" and deleting it. Re-fires every full-sync (so it survives Smart Reindex re-fetches). Diagnosed from a real user mailbox: IMAP `Archive` lost all of May 2026 (`2026-04=135, 2026-05=0, 2026-06=48`, `bfComplete=Y`) while Sent/Trash (UID≈date) and Gmail All Mail (date-ordered fetch) were intact — exactly the reported "missing months", IMAP-only.

**Decision:**
1. `EmailProvider.staleWindowMode: StaleWindowMode` (`enum { uid, date }`). Default `.date` (HTTP providers fetch most-recent-by-date); `IMAPProvider` overrides to `.uid`.
2. `SyncEngine.selectStaleHeaders(candidates:fetched:limit:windowMode:)` is the **single source of truth** for which local rows are stale-deletable — pure, `nonisolated static`, no DB/IO. `< limit` ⇒ whole folder fetched ⇒ anything local-not-remote is gone; `.uid` ⇒ candidate iff `Int64(messageId) >= min(fetched UID)` AND not in remote; `.date` ⇒ `date >= min(fetched date)` AND not in remote (unchanged).
3. Production `runSyncMessages` still loads only the **bounded** candidate slice from SQL (`CAST(messageId AS INTEGER) >= floor` for `.uid`; `date >= cutoff` for `.date`) to preserve the memory budget, then defers the keep/delete decision to `selectStaleHeaders`. The test harness `simulateRunSyncMessages` calls the SAME function — no logic copy that can drift.

**Rationale:** "We only have complete remote knowledge for the slice the fetch actually covered" is the real invariant, and the slice must be measured in the dimension the fetch ordered by. UID is that dimension for IMAP; switching to it makes archiving old mail harmless (there is no date floor to drag). Gmail/Exchange are already correct (date-ordered fetch, non-numeric ids) and are left unchanged.

**Consequences:**
- A windowed IMAP stale pass can no longer delete rows below the fetched UID floor — those are simply outside the window and wait for a future fetch/backfill that covers them. It still deletes genuinely server-removed rows *inside* the UID slice.
- **Field heal (v59 migration):** the code fix only STOPS deletion — already-deleted Archive mail is gone locally until re-fetched. `v59_rewalkImapArchiveAfterStaleWindowFix` (shared body `AppDatabase.rewalkImapArchiveFolders`) runs once on upgrade: resets `backfillComplete=0` / `backfillUidCursor=NULL` for **IMAP archive-role folders only** so the next backfill re-walks and re-fetches the deleted headers (existence-checked, so intact folders cost ~SEARCH only); the UID-window fix keeps them this time. MUST ship in the SAME build as the fix (without it the re-walked mail would just be deleted again). Without v59, each user would have to trigger Smart Reindex manually.
- Any future windowed stale-delete (any provider) MUST route through `selectStaleHeaders`. `deltaSync` has no windowed date-stale path and is unaffected.
- Regression: `E2ESyncScenarioTests.StaleDetectionWindowTests` (3 tests, incl. a characterization that the old `.date` window over-deletes) + `ArchiveRewalkHealTests` (v59 scoping).

---

## ADR-IOS-043: Outgoing Thread Binding — One Header Builder, Gmail Carries `threadId`

**Context:** Replying from the iOS app on a Gmail account broke the thread on Gmail web — the reply started a new conversation and never appeared in the original thread. Two compounding defects: (1) the reply compose path set only `In-Reply-To` and never built the `References` chain, so every provider sent an empty `References` (`ComposeView.send` passed no `references:`); (2) Gmail's REST `users.messages.send` does not thread by headers alone — it requires the `threadId` field **plus** RFC-2822 `References`/`In-Reply-To` **plus** a matching `Subject` to file a sent message into an existing conversation — and iOS never plumbed the parent's `MessageHeader.threadId` into the send. (Thunderbird is unaffected: it sends Gmail over SMTP, where Gmail's ingestion threads by headers. Functional parity is the goal, not implementation parity — implementations may differ. Per ADR-IOS-008 spirit.)

Forward semantics were verified against Gmail (web research, 2026-06-23): Gmail keeps a forwarded message under the **original conversation in the sender's own mailbox** (the recipient, new to the thread, still sees a fresh conversation). So forward threads the same as reply; it is not a "new thread" case.

**Decision:**
1. **Single source of truth:** `ThreadUtils.outgoingThreadHeaders(...)` derives the outgoing `inReplyTo` + full normalized/deduped `References` chain (`parent.references ++ parent.rfc822MessageId`, RFC 5322 §3.6.4) + Gmail `threadId`. A pure scalar core (no `MessageHeader` needed) plus a `MessageHeader` adapter for the callsite — keeps it unit-testable.
2. **Reply and forward share ONE derivation path** (no `isForward` flag in the builder) — per Gmail convention a forward attaches to the source conversation. Forward-specific differences (empty `To`, `Fwd:` subject, quote block) stay in `ComposeView`.
3. **`threadId` is Gmail-only**, guarded by **two** preconditions: the parent's account == the sending account (the stored id belongs to the sending mailbox), and `normalizeSubject(sendSubject) == normalizeSubject(parent.subject)` (Gmail rejects a `threadId` attach on subject mismatch). A failed guard yields `nil` → a fresh thread, which is the correct outcome for a cross-account send or a deliberately changed subject. These are **preconditions, not a fallback** (consistent with ADR-003).
4. **Plumbing:** `threadId` is added to `DraftMessage` and persisted on `OutboxMessage` (migration **v60**, `threadId TEXT`) so an outbox drain after relaunch re-sends with the same binding. The `Draft` GRDB record is **not** changed — `ComposeView.send` derives the headers from the already-resolved `replyTo`, exactly as `inReplyTo` was derived before.
5. **Provider responsibilities:** Gmail send includes `threadId` in the request body (`GmailProvider.buildSendBody`, extracted for testability) when present. Exchange (`internetMessageHeaders`) and IMAP/SMTP (`buildEmail`) already emit `In-Reply-To`/`References` — they need **no code change**, only the now-populated `References` chain.
6. **One callsite** (`ComposeView.send`) covers manual AND agent reply/forward, because the agent `email_reply`/`email_forward` tools open the same `ComposeView` via `AgentToolRouter.ComposeRequest(mode:.reply/.forward, replyTo:)`.

**Rationale:** Centralizing the header derivation prevents the per-provider drift that caused the empty-`References` bug, and keeps the Gmail-specific `threadId` logic (with its account/subject guards) in one tested place. Persisting only `threadId` on the outbox row (not the `Draft`) is the minimal change that survives process death between queue and drain.

**Consequences:**
- A Gmail reply/forward now lands in the source conversation on Gmail web; IMAP/Exchange recipients thread on the full `References` chain.
- `threadId` is intentionally dropped when the user switches the From account or materially changes the subject → those start a new Gmail thread (correct).
- IMAP parents lacking a Message-ID produce a best-effort (possibly empty) chain — same as before, no regression.
- Local receive-side grouping (`ThreadUtils.assignComputedThreadId`) is untouched; this ADR governs **outgoing** headers only.
- Regression: `OutgoingThreadHeadersTests` (builder), `GmailSendBodyTests` (threadId in/out of send body), `ExchangeSendPayloadTests` (References emission), `DatabaseOutboxTests` (v60 column + round-trip), plus existing `IMAPProviderBuildEmailTests` (References). See `PLAN_THREAD_FIX.md`.

---

## ADR-IOS-044: Inbox Usage-Throttle Banner — Driven by Cached `/whoami`, Tier-Branched CTA

**Context:** When a user's background AI processing gets throttled (a Basic user exhausts their monthly priority budget and flips to the slow queue; a BYOK user with no own key runs permanently on the slow shared queue per global ADR-025), nothing on iOS told them — processing just silently slowed. The throttle signals already existed in the `/whoami` response (`AccountInfo.queueMode`, `quotaPercentage`, `planTier`) but were decoded and unused. The 429-driven `.throttled`/`.throttleEnded` SSE events only flow through the **interactive chat** path (`sendCompletionsWithTools`); the **background** summary/action path (`sendCompletions`) has no throttle callback, so a reactive 429 banner was not feasible for background work.

**Decision:**
1. **Proactive signal, not reactive.** A new `@Observable` singleton `UsageThrottleStore` (`Services/AI/UsageThrottleStore.swift`) caches `planTier` + a derived `isThrottled` (`queue_mode == "slow"` OR `quota_percentage >= 100`) + `hasOwnAPIKeys` (`AIService.shared.byokBundle != nil`) from `/whoami`. It exposes `banner: UsageThrottleBannerKind?` computed live so observing views re-render on change. `hasCheckedOnce` stays **in-memory** (not persisted) → the banner never flashes on cold launch before the first authoritative `/whoami`.
2. **No new poll.** `update(from:)` is fed from the **existing always-on** foreground `/whoami` fetch in `RootView.revalidateAISubscriptionGate()` (fires on launch-`.active` and sign-in), plus `AccountDashboardView.fetchAll` for freshness. `refreshKeyState()` is called from `APIKeysView` key persist so the BYOK banner reacts immediately to add/remove without waiting for the next foreground.
3. **Tier-branched CTA** (`UsageThrottleStore.banner`): **Basic + throttled** → `.upgradeToPro` → routes to `PlanPickerView`; **BYOK + no own key** → `.configureKeys` → routes to TabMail Settings' **AI Provider** section (NOT the raw keys page — BYOK requires picking a provider per tier AND a key, both of which live in that section); **Pro** → `nil` (explicit placeholder for the future Max / pay-as-you-go upsell); unknown/no-subscription → `nil` (the "Start Your Free Trial" sidebar surface owns those users).
4. **UI.** `UsageThrottleBanner` (`Views/Shared/`) — subtle (soft orange tint, caption type, chevron), **no dismiss button** (the condition self-clears on quota reset / upgrade / provider setup), inserted at the top of `InboxView` gated on `isInboxView`. Tap posts `.navigateToPlanPicker` / `.navigateToAIProvider`. `MailNavigationView` routes the first to `.planPicker`; for the second it sets `selection = .prompts` and raises `TabMailSettingsView.pendingScrollAIProviderKey` (UserDefaults), and `TabMailSettingsView` (wrapped in a `ScrollViewReader`) scrolls to the `.id`-anchored AI Provider section on appear, then clears the flag. (There is intentionally NO standalone provider/keys route — provider selection only exists embedded in TabMail Settings.)
5. **Body type-checker budget.** The four sidebar navigation `.onReceive`s were extracted into one `NavigationNotificationHandlers` ViewModifier — adding the two new ones inline pushed `MailNavigationView.body` past the Swift "unable to type-check in reasonable time" limit.

**Rationale:** The `/whoami` fields ARE the authoritative "exceeded your monthly usage" signal, and reusing the existing foreground fetch avoids a new network call (and respects ADR-004 — nothing new persisted). A proactive store fits background processing (which has no 429 callback) far better than the chat path's reactive SSE events. Branching on tier keeps each cohort's message + destination correct without a backend change.

**Consequences:**
- Banner accuracy tracks `/whoami` cadence (refreshes each foreground/sign-in + on dashboard view + on key change) — a just-exhausted quota shows the banner on the next foreground, which is acceptable for a non-urgent nudge.
- Adding a future tier banner (e.g. Pro→Max) is a one-line `case "Pro":` change in `UsageThrottleStore.banner`.
- Any new top-level settings destination would need adding to BOTH `MailboxSelection` switches in `MailNavigationView` (`SettingsContentColumn` + `InboxColumnResolver.resolve`) — but this feature deliberately reuses the existing `.prompts` route + a scroll deep-link rather than adding one.
- Previews live at `Views/Previews/Inbox/UsageThrottleBanner+Preview.swift` (per the repo's `Views/Previews/<group>/<View>+Preview.swift` convention, NOT inline in the view). They render the banner in the **real** `InboxView` seeded via `PreviewMocks`, with `UsageThrottleStore.previewConfigure(...)` (DEBUG-only) forcing the Basic and BYOK states — so the surface is verifiable exactly as it looks live, without triggering a real throttle. (Same setup as the tooltip previews, e.g. `EnableInboxPushTip+Preview`.) The preview is **interactive**: a small `ThrottleBannerPreviewHost` puts the inbox in a `NavigationStack` and bridges the banner's `.navigateToPlanPicker`/`.navigateToAIProvider` notifications (handled by `MailNavigationView` in the app) into a push, so tapping the banner in the canvas actually opens the real `PlanPickerView` / `TabMailSettingsView` (the BYOK push also sets the scroll flag, so the AI Provider scroll is exercised). It injects a fresh `StoreKitManager` (PlanPickerView reads it from the environment) and calls `PreviewMocks.hideAllTips()` so tooltips don't pop in on interaction.

---

## ADR-IOS-045: Attachment QuickLook Is Presented Imperatively (Detached From the SwiftUI Tree)

**Context:** Tapping a file attachment opened a preview that **blinked / reloaded** intermittently. The preview is reached via `AttachmentListView` → `MessageCardView` → the message-detail `List` row, and originally used SwiftUI's `.quickLookPreview($url)` modifier hosted on that row. Because the modifier lives inside a re-rendering container, any re-render of that subtree (background sync, AI updates, the inbox/detail re-evaluating, even QuickLook's own presentation layout passes) reconfigures the hosted preview — the **out-of-process QuickLook extension** gets interrupted and relaunched, which reads as a blink. We first tried to suppress the re-render *sources* with `PreviewFreezeGate` (and extended it to `MessageCardView`'s `.inboxDataDidChange` label reload), but a device log (`logmain.log` 2026-06-24) proved it insufficient: with the gate demonstrably holding (`refresh(wake) SKIPPED — preview frozen`) and **zero** app data-change notifications during the window, the preview still cycled (`Connection to appex interrupted`, ~4 `QLOverlayDefaultActionBut…` re-layout bursts). It reproduced for both a `.xlsx` and a PDF — two different QL extensions → the common cause is the **host**, not the file. A re-render-source gate is whack-a-mole; the presentation itself is the problem.

**Decision:** Present file attachments via a `QLPreviewController` created and presented **imperatively** from the top view controller (`AttachmentQuickLook` enum in `AttachmentListView.swift`), the same detached-from-SwiftUI pattern already used by `ICSCalendarImporter`. The controller is retained in a `@MainActor` static slot (its `dataSource`/`delegate` are `weak`); `NSURL` is the `QLPreviewItem`; dismissal is detected via `QLPreviewControllerDelegate.previewControllerDidDismiss`. `PreviewFreezeGate` is still raised for the preview's duration (defense-in-depth + quiets background sync), but correctness no longer depends on it — no SwiftUI re-render at any level can touch a controller that isn't in the view tree. The `.eml` preview path is **left** as a SwiftUI `.sheet` (`EmlAttachmentPreview`): it's an in-process SwiftUI view with `.presentationDetents([.large])`, not an out-of-process QL extension, so it doesn't exhibit the appex-churn blink, and converting it would risk its detents/`NavigationStack` presentation for no reported benefit.

**Rationale:** SwiftUI modal presentation (`.sheet`, `.quickLookPreview`) hosted inside a `List`/`ForEach` row is a known-fragile anti-pattern — the row is subject to re-creation/reconfiguration the presentation can't survive. Detaching the presentation from the tree is the robust fix and matches existing codebase precedent (`ICSCalendarImporter`). Keeping `PreviewFreezeGate` as a secondary measure preserves the CPU/quiet-UI benefit while removing it from the correctness path.

**Consequences:**
- The preview is independent of `AttachmentListView`'s lifetime: if the row is recycled or the detail view re-renders while the preview is up, the preview is unaffected. Gate release is owned by the QL dismiss delegate (idempotent `handleDismiss`), not by `.onChange`/`.onDisappear`.
- Only one QuickLook can be on screen at once (full-screen modal) — `AttachmentQuickLook.present` no-ops if one is already up; a single static slot suffices.
- Imperative presentation is **not** unit-testable (it presents UIKit controllers from the key window); verification is build + on-device. The `PreviewFreezeGate` / `PreviewGatedReload` buffer-flush logic remains unit-tested (`EmailRenderPipelineTests.swift`).
- `AttachmentListView` still owns the **download** (spinner, `BodyAssetStore` cache, `makePreviewURL`, `downloadedFiles` checkmark + `ShareLink`); only the final present step is imperative.
- If the `.eml` sheet ever shows the same blink, migrate it the same way (wrap `EmlAttachmentPreview` in a `UIHostingController` presented imperatively, replicating `.large` detent via the sheet presentation controller).

---

## ADR-IOS-046: Background Drain Loops Are Abandon-on-Suspend — Never Hold a Lease to "Look Cooperative"

**Date:** 2026-06-26
**Status:** Accepted
**Extends:** ADR-IOS-041 (GRDB suspension / 0xdead10cc defense)

**Context:** A device `logmain.log` showed **6,312** identical `SQLite error 4: Database is suspended … BEGIN IMMEDIATE TRANSACTION` lines in a single post-suspend window (`DatabaseSuspension SUSPEND (quiesce window expired)` at the start, no RESUME for the rest of the capture). Root cause is a **two-counter coordination gap** in ADR-IOS-041's implementation. There are two independent "keep alive" mechanisms:
- **Process assertion** — `UIApplication.beginBackgroundTask` (`backfill-grace` in `SyncScheduler`, `db-quiesce` in `DatabaseSuspension`): keeps the *process* alive / grants OS background time.
- **DB-resume lease** — `DatabaseSuspension.beginBackgroundWork`/`endBackgroundWork` (a work-unit counter): keeps the *database* resumed. The quiesce window arms only when this counter hits 0.

The detached background drain loops (`BackfillBodyQueue`, `BackfillAIQueue`, the three embedding queues, and `SyncEngine.scheduleMaintenanceInBackground`) run under the **process** assertion (`backfill-grace`) but take **no DB-resume lease**. So when the silent-push handler — the only `beginBackgroundWork` holder covering that work — returned (3.7 s), the counter hit 0, the quiesce window armed and SUSPENDED, while a 46 s iCloud body batch (slow IDLE reset) and the maintenance sweep were still in flight. Every subsequent write aborted; the loops kept fetching-and-discarding because the process was still alive.

**Decision (the key call): the fix is "stop now," NOT "delay the suspend."** Giving the loops their own `beginBackgroundWork` lease was explicitly **rejected** — a DB-resume lease does not extend the finite OS budget (all assertions expire together at the app-wide deadline), it only keeps the pool **write-capable closer to the freeze**, which is exactly the `0xdead10cc` SIGKILL ADR-IOS-041 exists to prevent. Trading a benign, self-healing aborted-write for a hard mid-write kill to "look cooperative" is strictly worse. Background work is idempotent and abandonable by contract (Resilience Rule 3, ADR-IOS-001/003), so the correct response to suspension is to **abandon and retry next wake**.

Mechanically:
1. **`DatabaseSuspension.isSuspended`** — a pollable `nonisolated static` flag, driven by **observing** the same `Database.suspendNotification` / `resumeNotification` posts GRDB observes (`installSuspensionStateObserver`, installed from `start()`), so it is authoritative, not a second bookkeeping copy that can drift.
2. **Every background drain loop checks it at its existing dispatch boundary** (right where it already does the network gate + `PriorityGate.yield`) and returns early when suspended. Items were not yet collected, so nothing is lost; nothing is marked complete (honoring "never mark unfetched as fetched"). `SyncEngine`'s maintenance loop gates each step with `shouldRun() = !Task.isCancelled && !DatabaseSuspension.isSuspended` (suspension is treated like cancellation — both answer "should I still be doing this?").
3. **Resume re-kick:** each queue's `repopulateFromDatabase` (run on every wake by `syncStartup`) now `scheduleDispatch()`s whenever `storage.pendingCount > 0`, not only when the query found NEW rows — items left pending by an abandoned cycle are already enqueued, so the old `if added > 0` gate would strand them.
4. **Log hygiene (backstop):** the residual aborts from the ≤3 batches whose fetch was already in flight when suspend fired are filtered through `error.isDatabaseSuspensionAbort` (app paths: `BodyFetchProcessor`) / GRDB's `isInterruptionError` (shared/NSE path: `BodyAssetStore`) so an *expected* abort is never logged as a failure. The new debug breadcrumbs in the loops are `#if DEBUG` only.

**Rationale:** This is the GRDB/FTS-writer analogue of the existing cooperative-priority pattern (ADR-IOS-002 user-activity prioritization, ADR-IOS-014 IMAP priority lock, the `PriorityGate` merge gate): a background loop yields/stops at a SAFE boundary rather than fighting for a resource it can't safely hold. Abandon-on-suspend is universal — a suspended DB rejects all writes regardless of the loop's priority — so it lives in one shared flag every loop polls, with no per-subsystem classification to forget.

**Consequences:**
- The one batch already mid-fetch when suspend fires still attempts (and harmlessly aborts) its writes — its bytes were already fetched, so skipping the write saves nothing; it's quieted by the log hygiene and re-fetched next wake. Everything *after* the suspend point is skipped, eliminating the bulk of the waste.
- The **active** queues (`ActiveBodyQueue`, `ActiveEmbeddingQueue`) were deliberately NOT given the dispatch guard: they run inside the resumed lease window (driven by foreground/push events), so `isSuspended` is false when they run. They are still covered by the shared `BodyFetchProcessor`/`BodyAssetStore` log hygiene. Add the guard there too if a future path runs them detached.
- A DB-resume lease for backfill must never be reintroduced as a "finish the work" mechanism — it reopens the 0xdead10cc window. Stopping is the contract.

**Tests:** `DatabaseSuspensionTests.isSuspendedFlagTracksNotifications` (flag mirrors suspend/resume posts, idempotent re-install). The underlying abort-and-retry safety is pinned by the existing `DatabaseSuspensionTests` suite (ADR-IOS-041).

**Amendment (2026-06-28, build 326 / 1.6.18 crash) — the `!isSuspended` step-gate is NECESSARY BUT NOT SUFFICIENT for a NON-WAL read; those reads must be FOREGROUND-ONLY.** A TestFlight `0xdead10cc` (BGAppRefresh success path) showed the maintenance loop's `BodyAssetMaintenance.evict → BodyAssetStore.usedBytes` full-table `SELECT SUM(sizeBytes)` read in flight (blocked in `pread`) on the **non-WAL BodyAssetStore manifest** (App-Group `DatabaseQueue`) at the suspension instant — holding the SQLite read lock RunningBoard kills for. Two gaps the original abandon-on-suspend gate did not close:
1. **The gate is *between* steps; a single step's read can be in flight across the suspend boundary.** And — unlike a WAL read, which GRDB lets continue while suspended — a **non-WAL read holds a lock that `Database.suspendNotification` can only try to `sqlite3_interrupt`, which cannot abort a `pread` mid-syscall.** WAL is the only `0xdead10cc`-exempt access ([Apple DTS](https://developer.apple.com/forums/thread/126438); GRDB *Sharing a Database*: "all accesses but reads in WAL mode may throw `SQLITE_INTERRUPT`/`SQLITE_ABORT`"). We keep the manifest **non-WAL on purpose** — WAL in an App-Group container shared with an extension is its own hazard class (extension writes after suspension still kill; `-wal`/`-shm` cross-process coordination; see *SQLite Databases in App Group Containers: Just Don't*), and the NSE-staging DB already follows the same non-WAL + suspension pattern.
2. **The maintenance task was decoupled from any lifecycle** — a `Task.detached(.utility)` fired only by the **foreground poll**, never cancelled on background, so a foreground-started task lingered/resumed inside a later BGAppRefresh window (where `isSuspended` was briefly false under that task's `beginBackgroundWork`) and ran the non-WAL read straight into `setTaskCompleted` → suspend.

**Decision:** Split maintenance by journal mode and gate each half by what it can survive:
- **`SyncEngine.runWALMaintenance`** (storage prune, body-TTL evict, AI-cache purge, chat-session evict — AppDatabase/SearchIndex, all WAL) keeps the `!Task.isCancelled && !isSuspended` gate and runs from **BOTH** the foreground poll **AND** the `.full` BGProcessing drain. Apple does not guarantee BGProcessing runs, and foreground misses long background sessions, so running both is deliberate — neither alone suffices.
- **`SyncEngine.runBodyAssetMaintenance`** (non-WAL BodyAssetStore evict + orphan sweep) gates additionally on **`DatabaseSuspension.isAppActive`** — it may only START in the foreground, where iOS never freezes the process. The foreground poll is a reliable, frequent trigger, so eviction is not starved; the attachment cap is a soft disk budget, and a temporary background overage is reclaimed on the next foreground poll. A `0xdead10cc` SIGKILL is not an acceptable price for enforcing a soft cap a few minutes sooner. The entry gate stops the read from *starting* backgrounded, but `BodyAssetMaintenance.evict`/`pruneOrphans` ALSO re-check `isAppActive && !isSuspended` at the top of each loop iteration, so an eviction/sweep that began in the foreground **abandons mid-loop** if the app backgrounds — otherwise the inner `oldestAccessedMessages` read + `deleteAllAssets` deletes would be a narrower (but real) non-WAL-at-suspension window.
- **Note (NOT addressed here):** the same manifest is *written* in the background by body fetch (`BackfillBodyQueue`) and the NSE — a non-WAL write blocked at suspension is the same hazard class, but lower-probability (single-row inserts vs. a full-table SUM) and already covered by the body queues' `isSuspended` abandon-gate + log hygiene. Left as a separate follow-up; this ADR is scoped to the maintenance read that crashed.
- **`SyncEngine.cancelMaintenance()`** is called from `SyncScheduler.stopPolling()` (scenePhase `.background`) so a foreground task can't linger into a BGTask window. The `isAppActive` step-gate is the hard guarantee; the cancel is the matching lifecycle cleanup.

**Consequences:**
- `DatabaseSuspension.isAppActive` (already-maintained `appActive` mirror) is now exposed `nonisolated static` for off-main maintenance gating. WAL paths must NOT gate on it (that would needlessly block their legitimate BGProcessing run).
- **General rule:** any NON-WAL store read reachable from a background-execution context must gate on `isAppActive`, not just `!isSuspended` — `!isSuspended` is sufficient only for WAL accesses (which abort benignly) and for writes (likewise). Reads on a non-WAL DB hold a lock that can't be aborted at the freeze.
- **Tests:** `DatabaseSuspensionTests.nonWALReadsAreNotSuspensionExempt` — a non-WAL `DatabaseQueue` read throws under suspension (contrast: the existing WAL test where reads keep working), pinning the rationale. If the manifest is ever moved to WAL, that test and this foreground-only gate must both be revisited.

---

## ADR-IOS-047: Two-Phase NSE Merge — Header+Snippet Visibility Is Decoupled From the Body-Blob Write

**Date:** 2026-06-29
**Status:** Accepted
**Related:** ADR-IOS-037 (NSE/main-app AI lease), ADR-IOS-013 (dual-path AI), ADR-IOS-001/003 (optimistic UI / crash recovery), the `PriorityGate` merge gate (ADR-IOS-046), ADR-IOS-008 (AI parity).

**Context:** On-device wifi-off `BootProfiler` captures showed a residual: after a push, a freshly-merged message sometimes took **1.3–8s** to appear in the inbox. A merge-write decomposition (`merge: GRDB writer ACQUIRED after Xms` / `main tx committed`) proved it was **NOT** writer contention (0ms wait) and **NOT** the network — it was the **actual in-transaction write of a single staged message**, strongly size-correlated (39 KB body → 2ms; multi-MB → seconds). The cause is structural: `NSEDataBridge.performMerge` wrote the `MessageBody` HTML blob **inside the same `dbPool.write` transaction whose commit (then `flushNSEBatchToFTS` → `headerComplete=1`) makes the message inbox-visible**. A sender that embeds images as inline `data:base64` directly in the HTML (not `cid:`, not remote — so the NSE stages it verbatim and the merge writes the whole blob) produces a multi-MB row; its write gated visibility. Confirmed the merge does NOT render and the renderer fetches NO remote content (`BodyRenderer` has no `URLSession`; remote `<img>` stays verbatim for the WebView), so the only lever was *where* the blob is written, not *whether*.

**Decision:** Split `performMerge` into two phases; visibility no longer waits on the blob.
- **Phase 1 (new, additive):** per staged message, ensure its `MessageHeader` EXISTS with snippet — refresh the snippet on an already-synced header, or insert a HEADER-ONLY row for a brand-new push via `insertNewHeaderFromStaging(headerOnly: true)` (header + computed thread + reference/label junctions + snippet; **no body blob, no AI fields**). Then `flushHeadersToFTS` (the header half — steps 1–3 — of `flushNSEBatchToFTS`) → `headerComplete=1` (inbox-visible) → post `.inboxDataDidChange` (immediate). **Phase 1 deletes nothing.**
- **Phase 2 (the pre-existing merge block, unchanged):** writes the body blob + summary/action/AI cache, FTS-indexes the body → `bodyComplete=1`, posts a second immediate `.inboxDataDidChange`, and **only then** deletes the staging row. Because phase 1 created the headers, phase 2 normally takes its existing-header branch; if phase 1 ever missed a row (per-message savepoint failed, or the outer tx threw), phase 2's new-header branch is the **full-merge fallback**.

So the user-visible sequence is: header+snippet → render → body+AI → render → (gate releases) → herd. The AI fields (`summaryBlurb`/`actionTag`) are tiny but were deliberately deferred to phase 2 too, keeping phase 1 the *minimal* "make it visible" write — simplicity over a field-by-field split.

**Rationale / why this is safe, not clever:**
- It reuses an invariant the codebase already ships: `headerComplete=1` (FTS has header → inbox-visible) is already DECOUPLED from `bodyComplete=1` (body present), and the unresolved-CID path **already** surfaces a header with `bodyComplete=0` and lets `ActiveBodyQueue` (`WHERE headerComplete=1 AND bodyComplete=0`) backstop it. Phase 1 just makes the non-CID body path behave the same way.
- **Staging is the durable source — deletion happens ONLY in phase 2.** A crash between phases self-heals on the next wake: phase 1's header upsert is idempotent, and the staging row is still present for phase 2 to write the body from. We do NOT carry the body across phases in memory and delete staging early (rejected — violates "delete only when confirmed correct").
- **No body-queue refetch race:** the whole `performMerge` runs inside `PriorityGate.privileged`, so `ActiveBodyQueue` yields until after phase 2 has flipped `bodyComplete=1` — it never observes the transient `bodyComplete=0` window.
- The double header-FTS-flush (phase 1's `flushHeadersToFTS` + phase 2's `flushNSEBatchToFTS` re-running the same IDs) is intentional and free — `indexHeaders` is idempotent and the `headerComplete=1` flip is a second-time no-op.

**Consequences:**
- The merge now emits **two** immediate `.inboxDataDidChange` posts per wake with new mail (header render, then body/AI render) instead of one — bounded at two; the inbox's single-flight reload coalesces them. `NSEGradualMergeTests` updated accordingly.
- A brief sub-second window exists where a just-surfaced message has no `MessageBody` yet; opening it in that window hits the same `bodyComplete=0` open path that already exists (and self-heals). Acceptable and pre-existing for CID bodies.
- `insertNewHeaderFromStaging` gained a trailing `headerOnly: Bool = false` (trailing on purpose — a defaulted param before the `inout ftsBatch` broke the cross-module test call's overload resolution).
- Also tuned `nseMergeHerdSettleSeconds` 1.0 → 0.5 (the detached post-merge reply/embedding-enqueue delay; off the display path, so purely shifts when the AI herd starts).

**Tests:** `NSEMergeFullHeaderTests.headerOnlyDefersBodyAndAI` (headerOnly writes NO `MessageBody` row + nil AI fields; the default writes both). `NSEGradualMergeTests` post-count updated to the two immediate renders. 54 NSE tests green.

---

## ADR-IOS-049: Instant Inbox Insert — Render NSE-Staged Mail In-Memory, Before the Durable Merge Write

**Context:** On foreground return, newly-pushed mail didn't appear until the merge's phase-1 header WRITE finished — measured at ~1.5s after a ~3-min background (resume-time I/O throttle + fsync on a just-woken app), up to ~10s after a long suspension. Priority controls write *ordering*, not I/O speed; the merge already runs first, so being first just means it eats the fault/fsync cost. The only way to beat it is to stop gating the render on the write. Full design: `PLAN_INBOX_INSTANT_INSERT.md`.

*(A prior variant — ADR-IOS-048 "staging-union overlay" — was prototyped and REVERTED, so its number is intentionally skipped. It kept a GRDB read on the render path (`foldStagingOverlay`) and added a pre-write existence read, both resume-time-cold, which made the observed delay WORSE. Lesson baked into this ADR: the render path must do ZERO DB I/O.)*

**Decision:** On new staged mail, insert the rows straight into `InboxViewModel.loadedMessages` **in memory** (no GRDB read/write); the durable write lands in the background; a normal reload reconciles. Reuses the shipped `insertUndoneMessages` targeted-insert pattern, sourced from staged data instead of a GRDB read. **Scope: inbox list only** — badge and body render keep lagging to the merge.

1. **Merge → VM signal.** `performMerge` posts `.messagesStaged` with `[StagedInboxRow]` (a `Sendable` header projection) right after reading staging, before the phase-1 write. Separate from `.inboxDataDidChange`, so the merge's 2-post contract (ADR-IOS-047, `NSEGradualMergeTests`) is untouched. The VM dedups, so re-posting on a no-op re-merge inserts nothing — no gating read needed.
2. **In-memory insert.** `InboxView` → `InboxViewModel.insertStagedRows`: dedup vs `loadedIds`, folder + unread-filter guard, sorted insert, `rebuildDisplayGroups`. Zero DB I/O. Tracked in `pendingStagedRows` (keyed by headerId).
3. **Anti-flicker guard (the crux).** A just-inserted row isn't in GRDB, so `reloadMessages` Pass-1 would evict it (it removes any loaded row absent from the fresh GRDB set) if a competing reload (sync, backfill, badge recount, 2nd push) fires before the durable write. Guard: **keep** a not-in-fresh row iff `pendingStagedRows[id] != nil && overlay[id] == nil`. The `overlay[id] == nil` clause drops the guard once the user acts (archive → `registerMutation` exists), preventing archived-row resurrection. Cleared per-row when the row appears durable (in the fresh set) or is acted on; wholesale on `resetMessages`.
4. **Actions gate on durability.** A surfaced-but-not-durable row has no GRDB header: `lookupMessage` synthesizes from `pendingStagedRows` (else the action silently `guard`-returns); `ensureDurable` (a cheap existence read on the action path, NOT the render path) drains the merge first if any target is absent, so the optimistic write lands on a real row instead of hitting 0 rows and being resurrected as inbox. The instant `registerMutation` overlay stays the acknowledgment — never-drop-intention (ADR-IOS-001) preserved.

**Consequences:**
- New `StagedInboxRow.swift`; `.messagesStaged` notification; `NSEDataBridge.performMerge` posts it; `InboxViewModel.insertStagedRows` + `pendingStagedRows` + Pass-1 guard + `lookupMessage` synthesis + `resetMessages` clear; `InboxView` receiver (extracted to a `StagedRowsReceiver` `ViewModifier` so the large body stays under the SwiftUI type-check limit); `AccountManagerActions.ensureDurable` on markRead/markUnread/move/markFlagged.
- Render path does ZERO DB I/O — the win the reverted overlay couldn't deliver. No global singleton store (`pendingStagedRows` is VM-local, so no cross-test contamination).
- Badge, body, search, filters reflect a just-arrived message only after the merge (≤ merge delay). Deliberate.
- Staged rows render as thread singletons until merged (`computedThreadId` empty → `ThreadGroupBuilder` id fallback).

**Tests:** `InboxStagedInsertTests` (synthesis, insert, dedup, folder-guard, `lookupMessage` synthesis). `NSEGradualMergeTests` 2-post `.inboxDataDidChange` contract unchanged. Full suite green.

**Amendment (2026-07-03) — boot paint gate:** cold-boot FIRST PAINT was still gated on the FULL boot merge (`runIfNeeded` awaited `mergeIfStagingPending()` to completion), so a slow phase-1 write gated the inbox — measured 8.4s to paint (7.6s phase-1 header upsert on a killed-mid-sync WAL-debt + cold-I/O boot, boot_logs 5) while the in-memory snapshot was ready at +700ms. The 2026-06-29 fail-fast probe protected paint from the NSE's *lock*, not from a slow *write*. Fix: `NSEDataBridge.mergeIfStagingPendingPaintGate()` — boot awaits a `OneShotGate` released by a new `onSnapshotPublished` callback (threaded through the coordinator into `performMerge`, fired right after the `latestStagedRows`/`latestStagedBodies` replace + `.messagesStaged` post decision, BEFORE phase-1) or by merge completion on every no-snapshot exit; the merge continues un-awaited and lands durably post-paint. Safe because `InboxViewModel.resetMessages` (VM init, i.e. at paint) seeds from `latestStagedRows` — the pre-paint notification was already being dropped (VM not yet constructed) — and the Pass-1 guard/dedup reconcile the durable write exactly as on foreground merges. Tests: `NSEPaintGateTests` (callback strictly precedes the durable header write; fires under re-post suppression; gate releases with nothing pending; `OneShotGate` semantics).

**Amendment (2026-07-04) — merge-commit signal for the open detail view (`.nseMergeDidCommit`):** the quick-render open path (staged header + `stagedBodyFallback` body) runs `loadThreadMessagesAsync` → `ThreadDetection.findRelatedMessages` against GRDB *before* the merge has written the header + `messageReference` junction rows, so related messages that are themselves staging-only (e.g. earlier thread members from the same push batch) come up empty — and nothing re-ran thread detection after the merge landed (`applyRefresh` only updates thread members *already present* in `threadMessages`). Fix: `performMerge` posts a new **`.nseMergeDidCommit`** (no payload; production posts carry `object: nil` — tests post with a sentinel object so cross-suite count contracts can exclude them) at exactly the two existing gated render points — phase-1 surface (`newlyVisible > 0`; headers + junctions are queryable from here) and end-of-merge (`endOfMergeChanged`) — bounded at two per wake, mirroring the `.inboxDataDidChange` contract. `MessageDetailViewModel` observes it (both inits) and re-runs `loadThreadMessagesAsync()` — **deliberately WITHOUT an `applyRefresh` of the focused header**: phase-1 rows are header-ONLY (AI fields nil, ADR-IOS-047), so re-reading would regress a staged-synthesized `message` that already carries the NSE's summary/action tag ("Analyzing…" flash until phase 2); AI updates reach the view via `.messageDataDidChange` as before (caught in adversarial review before commit). Preview-freeze safe at BOTH boundaries: handler entry buffers as `pendingThreadRefreshOnRelease` (replays on `.previewFreezeReleased`, same contract as `pendingRefreshIds` — and the test-only init registers the release listener too, so a buffered refresh is never silently dropped), and `loadThreadMessagesAsync` re-checks the gate at its MUTATION site (the detached query can outlast a preview appearing mid-await) and re-buffers instead of mutating. Deliberately NOT reusing `.inboxDataDidChange` in the VM (fires from sync/backfill/compose — would re-run thread queries on every inbox tick) nor `.messageDataDidChange` (fires per AI-field update — same waste, per-id semantics). Known/accepted: the signal is payload-less, so an open detail view re-runs one (indexed, bounded) thread query per merge post even for unrelated pushes — merges are rare and bounded at 2 posts; a relevance prefilter was judged premature. Tests: `NSEGradualMergeTests.mergePostsMergeCommitSignal` (2 posts per merge wake, 0 on empty re-merge; filters `object == nil`), `MessageDetailStagedFallbackTests` (`.serialized` — one test freezes the global gate): `mergeCommitRefreshesThreadMessages` (staged-only open → post → related messages appear), `mergeCommitBuffersDuringPreviewFreeze` (frozen → buffered, release → replayed; never dropped). Round-2 review hardening: `loadThreadMessagesAsync` now CLEARS `threadMessages` on an empty result (remote state wins — an end-of-merge signal after inbox removals must not leave stale bubbles pointing at deleted messages; test `mergeCommitClearsRemovedThreadMessages`), the `[ThreadDebug]` probe + prints are `DebugModeManager.isLoggingEnabled()`-gated (rule 12 — the probe's two unbounded `fetchAll`s no longer run per merge post in production, restoring the stated one-indexed-query cost), and the `.previewFreezeReleased` flush re-checks the SHARED gate before consuming buffers (a non-shared `PreviewFreezeGate` instance's `end()` posts the same global notification; consuming while frozen would drop the buffered refresh). Round-3 review hardening: `loadThreadMessagesAsync` gained a **generation token** (only the newest run applies — clear-on-empty made unordered detached completions destructive: a stale pre-merge empty result could wipe just-populated bubbles) and an **overlay-preserve pass** (never revert an in-flight optimistic bubble mutation: ids with a pending `registerMutation` overlay entry keep their current in-memory row, because folder-move fields are deliberately NOT in `applyOverlay` and the DB row is stale until the drain lands — test `mergeCommitPreservesPendingBubbleMutation`); the flush loop re-checks the gate per-iteration and re-buffers the unapplied remainder if a new preview begins mid-flush; the buffered flag was renamed `pendingThreadRefreshOnRelease` (it is set by ANY freeze-discarded thread reload, not just merge-commit ones — a freeze-discarded reload MUST replay or its update is lost); empty→empty no-ops before the freeze check (no pointless replay); the `[PreviewFreeze]` flush print is now debug-gated (rule 12). Round-4 review hardening: `locallyMovedBubbleIds` preserves in-place-moved thread bubbles ACROSS reloads for the view's lifetime (`updateThreadMessageFolder`'s "card stays visible showing its new location" contract — the moved row is excluded from fresh results by ThreadDetection's Trash/Spam filter AND its overlay entry drains within ms, so neither query nor overlay-preserve could keep it; missing rows are re-appended from the current in-memory array); the ordering guard compares against last-APPLIED generation (`lastAppliedThreadGeneration`), so if the newest run throws, an older successful result still applies instead of being discarded with nothing to replace it; `applyRefresh` re-checks the frozen gate at its two mutation sites (re-buffers the id — closes the await-window for ALL its callers, including the pre-existing AI listener); one shared overlay snapshot serves display-overlay + preserve pass (two reads could diverge mid-drain); the test-only init's listeners are opt-in (`observeMergeCommits: false` default) so pre-existing test-init consumers keep notification-free behavior. DECLINED (recorded so future rounds don't re-litigate): replacing the dedicated `.nseMergeDidCommit` channel with `.inboxDataDidChange` + `inboxReloadImmediateKey` filtering (couples the detail view to a key documented as the inbox's privileged-reload contract; the lockstep risk is two adjacent lines in the same Task blocks), and adopting `PreviewGatedReload` for `pendingThreadRefreshOnRelease` (the three-site set/consume/re-buffer choreography with generation interplay doesn't map onto its request/release API; consolidation would be a standalone refactor). Round-5 review hardening: `applyRefresh`'s thread-member branch re-finds the index AFTER its awaited read (a merge reload — including clear-on-empty — can replace/shrink `threadMessages` mid-suspension; a stale index is an out-of-bounds fatalError or wrong-row overwrite) and skips ids in `locallyMovedBubbleIds` (the per-id refresh would otherwise snap a locally-moved card back to the stale DB row — same contract as the wholesale reload's preserve pass; test `aiRefreshPreservesLocallyMovedBubble`); the empty→empty short-circuit now RECORDS `lastAppliedThreadGeneration` (it successfully observed "no related messages" — without recording, a stale older run with a pre-removal snapshot could pass the guard afterwards and resurrect bubbles for deleted messages); the test-init flag was renamed `observeNotifications` and now registers all three production listeners (AI-update included) so refresh-path contracts are testable. Round-6 review hardening — the move-pin became FIELD-LEVEL with an un-pin path (`preservingLocalMove`): a whole-row, insert-only pin had two confirmed defects — an UNDONE archive/delete left the card permanently showing the moved-away folder (every refresh path was blocked by the pin's own guards; remote-state-wins was violated once the local intent was revoked), and pinned bubbles were starved of AI updates ("Analyzing…" stuck forever for a bubble moved into the Inbox). Contract now: while the move is IN FLIGHT (overlay entry present) only `folderPath`/`folderId`/`isInInbox` carry over from the in-memory row and AI/display fields flow from the fresh DB row; once the overlay drains the DB is authoritative (drain landed / undo / remote move) — the pin clears and the fresh row wins wholesale. The re-append of rows EXCLUDED from fresh results (Trash/Spam filter) remains the only view-lifetime part, and a row that reappears (undo) heals + un-pins. Tests: `aiRefreshPreservesLocallyMovedBubble` (folder preserved AND AI fields flow), `undoHealsLocallyMovedBubble` (overlay drained → DB truth wins, pin cleared). Round-7 review hardening — the pin's lifetime is now EXACTLY the overlay window (the round-6 "view-lifetime re-append for excluded rows" is SUPERSEDED): the wholesale reload prunes `locallyMovedBubbleIds` to ids with a live overlay entry before the preserve pass. Rationale: an id-keyed view-lifetime pin fights the data model — post-drain sync RE-KEYS header ids (IMAP MOVE changes UIDs), so the pinned old-id card rendered as a permanent DUPLICATE next to the fresh new-id row, and the per-id refresh path could un-pin a trash-excluded card early (fetchOne bypasses ThreadDetection's filter), silently dropping it. Post-drain behavior is now uniform: fresh results are the truth — a trashed card drops on the next merge reload exactly as a fresh open of the view would show (the "card stays visible" doc contract is an ACTION-TIME in-place behavior, which still holds; it was never a cross-reload durability guarantee — pre-change reloads dropped trashed cards too, by ThreadDetection's own design). The in-flight re-append remains (the optimistic local write can land the row in Trash before the overlay entry drains — the card must not flicker out mid-drain). Test: `trashedCardDropsAfterDrain`. Round-8 review hardening — the pin window is keyed to the move OPERATION's own lifetime, not the overlay entry (round-7's `formIntersection(overlay.keys)` pruning is SUPERSEDED): `AccountManager.optimisticOverlay` coalesces ONE `PendingMutation` per id and every op's drain calls `removeOverlayEntries(ids:)` on the whole entry (verified: 8 call sites), so overlay-presence is the wrong proxy for "this move is in flight" — a sibling op draining first (mark-read queued before the archive) ended the window while the move hadn't executed (card snapped back to INBOX mid-flight), and `UndoService` registering the move-back under the same id extended it (stale Archive fields clobbered the undo). Now: `updateThreadMessageFolder` pins; the archive/delete/move `enqueueWrite` continuations call `completeLocalMove` after the op executes (optimistic local write landed) — un-pin is exact, `preservingLocalMove` carries folder fields purely on pin membership, and no overlay pruning exists. If the op never executes, the pin (and the optimistic card) persists — which is never-drop-intention, not a leak. Also: the flush loop's trailing thread refresh re-checks the gate (a preview beginning during the last applyRefresh await otherwise launched a guaranteed-discarded query). Tests: `siblingDrainDoesNotEndMovePin` (coalesced-entry wipe mid-move keeps the card), `undoHealsLocallyMovedBubble`/`trashedCardDropsAfterDrain` updated to drive `completeLocalMove`. Round-9 review fix — the round-8 wiring itself was defective (verified: `AccountManager.enqueueWrite` APPENDS to `writeQueue` and returns immediately, "Never blocks caller", AccountManager.swift:261-268): the `completeLocalMove` continuation placed AFTER `await enqueueWrite` ran at ENQUEUE time, collapsing the pin window to one actor hop — a merge reload arriving before `drainLocalWrites` executed the move snapped the card back to INBOX, the exact regression round 8 claimed to fix, and the suite stayed green because every pin test drove `completeLocalMove` manually. Fix: `completeLocalMove` is called INSIDE the queued closure, after `manager.move` + `removeOverlayEntries`. New test `pinSurvivesWhileMoveQueued` drives the REAL `archiveMessage` wiring with the write queue deterministically blocked by a gate closure (RED under the round-8 code). Round-10 review hardening: the pin is a REFCOUNT (`localMovePins: [String: Int]`), not a Set — two overlapping move ops on the SAME still-visible card (archive, then delete; reachable because the card stays actionable by design and deleteMessage's role guard passes for an Archive-folder bubble) each pin/un-pin independently, where the Set collapsed them and the FIRST op's `completeLocalMove` ended the window while the second move was still queued (test `overlappingMovesKeepPinUntilLastCompletes`). The triplicated queued-move closure is one helper (`enqueueMove` — the round-9 defect had shipped in three hand-kept copies); the vestigial `using:` snapshot params on both `applyOverlay` overloads (their second consumer was removed in round 6's field-level redesign) are gone along with the stale shared-snapshot comment; `pinSurvivesWhileMoveQueued`'s teardown leaves the test `AppDatabase` alive when `previous == nil` (manager.move fires unstructured drainPendingQueue/recount tasks the drain barrier cannot join — restoring nil would let an escaped task hit `rawPool`'s force-unwrap and kill the test process). Round-11 review fix — `loadThreadMessagesAsync` guards the wholesale reassignment with a full-value equality check (`overlayed != threadMessages`; `MessageHeader` gained synthesized `Equatable`): an UNRELATED merge re-ran the reload, `ThreadDetection` returned the same set, and the code still reassigned the `@Observable` `threadMessages` + re-ran `recomputeThreadSplit` on every push (2 posts/merge), invalidating the thread view for nothing — now consistent with the empty→empty no-op guard beside it. Full-value equality (never a field subset) so a real thread change can never be silently skipped; the generation is still recorded on the skip so a later stale run can't apply over the confirmed-current set. ACCEPTED (recorded, do not re-report): a stale in-flight wholesale reload can overwrite a newer per-id AI refresh — last-writer-wins among refresh paths is the pre-existing consistency model and the AI queue re-posts per field write, so it heals on the next post; the fresh row's `actionTag` reappearing on a moved card has no visible impact (tag chips are inbox-only UI gated on `isInInbox`, carried `false` in-flight; post-drain the DB row is authoritative and any tag-column staleness is the pre-existing move-path semantics). Round-12 review — REJECTED (recorded, do not re-report): the `.nseMergeDidCommit` thread reload mutates `threadMessages` gated only by `PreviewFreezeGate` (QuickLook), not a user-interaction freeze, so a merge landing mid-swipe on a thread bubble *could* re-lay-out the list under an active gesture. Not fixed, deliberately: (a) the detail view's thread rows use NATIVE SwiftUI `.swipeActions` (List-managed, reconciled by `Identifiable` id), NOT the inbox's custom swipe-to-zap gestures the `beginInteraction/endInteraction` rule was written for — `MessageDetailViewModel` has never had that gate; (b) the unfrozen-thread-mutation pattern is PRE-EXISTING (`applyRefresh` mutates `threadMessages[idx]` on every `.messageDataDidChange` AI update; `startBodyPoll`'s 2 s cadence re-ran the reload) — this change adds one more trigger to an accepted pattern, not a new hazard class; (c) the finding was PLAUSIBLE, not CONFIRMED — the symptom (a dropped swipe) is unproven and needs on-device repro; (d) the round-11 no-op equality guard means the reassignment fires ONLY when the thread genuinely changed, which is exactly when the user should see it. The only real fix would be a whole interaction-freeze subsystem in the detail VM — unwarranted for an unproven concern.

**Amendment (2026-07-05) — additive simplification ATTEMPTED, AUDITED, and REVERTED (do NOT re-attempt):** on the theory that the move-pin machinery above (rounds 4–11) was overcomplication, an experiment (commits since removed from history) replaced the wholesale merge reload + move-pin with an ADDITIVE `refreshAfterMergeCommit` — append only the thread members not already displayed, never touch an existing bubble — reasoning that "never touching existing bubbles" removes the need to preserve in-flight moves, so the pin, generation token, and clear-on-empty could all go. A two-round adversarial audit proved the theory WRONG; the change was reverted to this pin-era code. The pin is **load-bearing**, for three reasons that are INDEPENDENT of the merge-vs-additive choice: **(1)** the wholesale `loadThreadMessagesAsync` still runs from `refetchBody` (pull-to-refresh) and `startBodyPoll` — without the pin those revert an in-flight optimistically-moved thread bubble to its stale pre-drain DB folder (Never-Drop-User-Intention); the additive merge path only protects the merge trigger, not these. **(2)** `applyRefresh` on a `.messageDataDidChange` likewise reverts a moved bubble unless it preserves the in-flight folder fields — and preserving them UNCONDITIONALLY (the experiment's round-1 patch, with no pin gate) breaks undo-heal: after an undo the card shows the moved-away folder forever. Correct preserve therefore needs the pin's in-flight signal (the overlay is the wrong proxy — it coalesces one entry per id, so a sibling op's drain ends the window early: the round-8 finding). **(3)** the additive append-only design CANNOT dedup a UID re-key: after an IMAP MOVE re-keys a bubble, `findRelatedMessages` returns the NEW id while `existing` holds only the OLD id, so the member is appended a SECOND time (duplicate bubble); the wholesale reload deduped this for free via replace semantics. Fixing (3) requires the merge handler to remove stale-id rows = reconcile the whole set = a wholesale reload — so "additive" cannot be made correct without becoming wholesale-with-a-pin, i.e. this design. Net of the experiment: it also LOST removed-member cleanup (a documented trade-off) and added an `additiveAppendSeq` ordering guard that itself had a hole. Conclusion: the pin is the minimal correct machinery for in-place thread-bubble moves; keep it.

**Amendment (2026-07-05) — the merge-commit signal ALSO adopts the newly-durable BODY (`boot_logs 8`, distinct from the thread-refresh above):** the notification-tap open whose `loadBody` is cancelled by the inbox-reload/nav churn defers body-load to `startBodyPoll`, whose entry fast-paths (durable `MessageBody` read + `stagedBodyFallback`) can BOTH miss in a merge-timing race — and the poll then waits a FULL 2 s before re-checking. Counterintuitively the miss happens on FAST merges: when phase-1's durable write is *slow* (queued behind priority writes, e.g. `merge.phase1 in 1572ms`) the staged-body snapshot (`latestStagedBodies`, replace-all per merge) stays populated and `stagedBodyFallback` hits (~0.7 s open); when the merge writes+drains *fast* (body committed +51 ms after the poll started, then a 0-staged re-merge clears `latestStagedBodies`) both fast-paths miss and the body strands on the 2 s cadence — measured ~2.6 s open-lag with the body **durable ~2 s before it displayed** (`boot_logs 8`: durable at +…960 ms, shown at +…989 ms via `poll (DB, 2s cadence)`). Fix: `refreshAfterMergeCommit()` now ALSO calls the shared `adoptReadyBody(source:)` (extracted from `startBodyPoll`'s entry — durable read → staged fallback) when `messageBody == nil`. The end-of-merge `.nseMergeDidCommit` (`endOfMergeChanged`) fires the instant the body is durable, so the body renders event-driven (~ms) instead of on the timer; the 2 s poll stays as the ultimate fallback. **Body-only — never touches `self.message`** (the AI-field invariant the thread-refresh amendment relies on is preserved: nil → content is additive, never a regression). NOT the reverted additive-thread experiment above — orthogonal (that was the thread reload + move-pin; this is the body blob). **Round-1 review hardening (5-finding adversarial pass):** (1) adoption invariants moved to a post-await MUTATION SITE (`adopt`) — the caller's pre-await guard is stale after the awaited read, so `adopt` re-checks `messageBody == nil` + `!isRefetchingBody` immediately before writing (matches `applyRefresh`/`loadThreadMessagesAsync`'s mutation-site re-checks). (A `!PreviewFreezeGate.isFrozen` re-check was ALSO added here in round 1, then REMOVED in round 2 as unreachable — see the round-2 note below.) (2) **refetch race:** `refetchBody` (pull-to-refresh) deliberately deletes the durable body + sets `messageBody = nil` for its multi-second refresh window; a concurrent `.nseMergeDidCommit` re-adopted a stale / re-committed body mid-refresh (spinner cleared, stale body flashed back, defeating the explicit refresh) — guarded by the new `isRefetchingBody` flag (set for the whole `refetchBody`, `defer`-reset). (3) `adoptReadyBody` no longer re-runs thread detection; the caller owns the SINGLE scan (a body-adopting merge-commit had double-scanned via the helper + the handler's tail). (4) the diagnostic `print` is now `DebugModeManager.isLoggingEnabled()`-gated (rule 12; `BootProfiler.mark` was already gated). (5) freeze-at-adoption is poll-latency, NOT a drop — the still-running 2 s poll re-adopts (the body, unlike the thread refresh, has an independent retry, so no replay-arming is needed). Tests: `MessageDetailStagedFallbackTests.mergeCommitAdoptsNewlyDurableBody` (durable body → post → adopted under the 2 s floor), `adoptReadyBodyBailsDuringRefetch` (refetch window blocks adoption); `OnDemandBodyFetchGRDBTests.startBodyPollImmediateCacheHit` unchanged (the refactored entry still renders a cached body immediately). **Round-2 review hardening (3 findings):** (1) **poll-loop refetch gap (CONFIRMED, correctness):** round-1's `isRefetchingBody` guard lived only in `adopt`, but `startBodyPoll`'s 2 s STEADY-STATE loop wrote `messageBody` directly (DB-hit + server-fetch branches) and `refetchBody` never cancels the poll — so a poll tick landing in the multi-second pull-to-refresh window still flashed a stale/re-committed body back AND fired a duplicate concurrent IMAP fetch competing with `refetchBody`'s own. Fixed: `guard !isRefetchingBody else { continue }` at the top of the loop (skips both branches, resumes next tick). (2) **duplication (CONFIRMED, cleanup):** the loop's DB-hit branch was a near-verbatim copy of the just-extracted `adoptReadyBody` durable-read path — now routed through `adoptReadyBody(source: "poll (DB, 2s cadence)")`. (3) **freeze re-check REMOVED (converges round-1 finding #2):** round 1 added `!PreviewFreezeGate.isFrozen` to `adopt`; round 2 proved it unreachable — `adopt` runs only when `messageBody == nil`, i.e. no body is rendered, so no `AttachmentListView` (the ONLY `PreviewFreezeGate.begin()` caller) can be on screen to freeze the gate for this view, and the merge-commit path is already freeze-gated at the observer. The dead check also created a cross-suite test flake (a global-gate freeze in one suite could make a concurrent `startBodyPollImmediateCacheHit` bail); removed along with its `adoptReadyBodyBailsWhenFrozen` test. Body-only adoption when `messageBody == nil` therefore needs no freeze guard (CLAUDE.md "don't guard impossible scenarios"). **Round-3 review hardening (2 findings, both consequences of round-2's changes):** (1) **poll server-fetch clobber (CONFIRMED):** the round-2 loop-top `!isRefetchingBody` guard only blocks STARTING a fetch; a `manager.fetchBody` already in flight when a pull-to-refresh begins still completed and wrote `messageBody`/`message` — clearing the refresh spinner + flashing a body back. Fixed with a post-fetch `guard !isRefetchingBody else { continue }` at that mutation site. Accepted residual: at most ONE in-flight duplicate IMAP fetch can still run to completion (its write is skipped, and the loop-top guard blocks every subsequent tick) — `manager.fetchBody` is not reliably cancellable, so an already-started fetch can't be aborted; it either wastes a round-trip or errors on the serial IMAP lock (caught). (2) **staged fallback broke poll durability (PLAUSIBLE):** routing the 2s loop's step-1 through `adoptReadyBody` (round-2 dedup) also ran its in-memory staged fallback, so a durable-miss + staged-hit adopted DISPLAY-ONLY bytes and ended the poll before its server-fetch branch — the ONLY path that PERSISTS a durable `MessageBody` (`hasBody`/FTS/AI would stay empty under a phase-2 write failure). Fixed with an `allowStagedFallback` param: the poll passes `false` (durable-only → falls through to persist); the entry keeps the default `true` (its staged bytes come from a fresh merge that persists in phase 2). Test `adoptReadyBodyDurableOnlyIgnoresStaged`. **Round-4 review hardening (2 findings, poll-vs-refetch class):** (1) **poll-vs-refetch guard placement (CONFIRMED):** rounds 2-3 guarded the poll's server-fetch branch BEFORE its awaited reads, so a refresh starting during the read still clobbered and the poll `return`ed (died). Round 4 tried a cancel+restart "root fix" (`refetchBody` cancels `bodyPollTask` + restarts it at the tail) — but round 5 proved that WRONG (see the round-5 note); it was REVERTED. (2) **merge-commit catch-up staged-durability (CONFIRMED):** the catch-up used the default `allowStagedFallback: true`, so on the phase-1 `.nseMergeDidCommit` (which PRECEDES the phase-2 body write) it adopted display-only staged bytes and ended the persisting poll — R3-2 on that path. Fixed: the catch-up passes `false` (durable-only), adopting only once the body is durable (the end-of-merge post, or the poll). Tests `adoptReadyBodyDurableOnlyIgnoresStaged`, `mergeCommitCatchUpIgnoresStagedOnly`. **Round-5 review hardening (3 findings — all in round-4's cancel+restart, now REVERTED for the simpler correct design):** round-4's `refetchBody` cancel+restart had three defects: (R5-1) the tail `if messageBody == nil { startBodyPoll() }` ran AFTER the `defer` cleared `isRefetchingBody` (no `await` between), so the restarted poll's entry — `allowStagedFallback: true` — re-adopted the STALE staged body refetch was replacing and died; (R5-2) the `messageNotFound` early return skipped the tail restart, so a `.refreshable` cancellation left the body deleted with a cancelled, un-restarted poll; (R5-3) the unconditional cancel let the poll's in-flight header read return nil → `message = nil` (transient header blank). **Final design: DON'T cancel the poll.** The loop-top `guard !isRefetchingBody else { continue }` (round-2 style, restored) skips ticks while refetch owns the body — the poll stays ALIVE and resumes after, so no cancel and no restart (both R5-1 and R5-2 vanish). The server-fetch branch reads BOTH the body + header, THEN gates a SINGLE `!isRefetchingBody` mutation-site check followed by SYNCHRONOUS writes (no `await` between the guard and `return`, so a concurrent refresh cannot interleave — fixes R4-1's placement issue and R5-3's header-blank at once; a refresh beginning during the fetch/reads bails to `continue`). `refetchBody` now only sets the `isRefetchingBody` flag (`defer`-reset), matching pre-existing "body-showing → refetch fails → no poll" behavior; `adopt`'s `!isRefetchingBody` guard stays for the entry + merge-commit callers, and step-1 stays durable-only. **Round-6 review hardening (2 findings, PLAUSIBLE):** (1) **redundant poll fetch on concurrent set (correctness):** the poll's step-1 `adoptReadyBody(allowStagedFallback: false)` returns false BOTH on a durable miss AND when `adopt` bails on a concurrent `messageBody` set (the new merge-commit catch-up winning the durable read during step-1's await) — the poll couldn't tell them apart and fell through to a redundant `manager.fetchBody` for an already-durable, already-displayed body (serial-folder-lock contention, the "cannot connect" hazard `loadBody` avoids). Added `guard messageBody == nil else { return }` after step-1. (2) **test robustness (cleanup):** `mergeCommitCatchUpIgnoresStagedOnly` asserted a negative (`messageBody == nil`) after a fixed 200 ms sleep — a slow CI catch-up Task would false-pass a real staged-adoption regression. Restructured to assert the DURABLE content via `waitUntil` (a wrong staged adoption leaves `"<p>staged only</p>"`, failing the robust assertion). **Round-7 review hardening (1 finding, CONFIRMED):** the round-6 `guard messageBody == nil else { return }` after the poll's step-1 checked only the body, not `isRefetchingBody` — so a pull-to-refresh beginning DURING step-1's await (the loop-top guard now stale across that read) let the poll fall through to a competing `manager.fetchBody` on the serial folder connection lock. Added a matching `guard !isRefetchingBody else { continue }` there (`continue`, not `return` — keeps the poll alive to resume after the refresh). Every poll await window is now guarded: the 2 s sleep → loop-top guard; step-1's read → the body guard + this `isRefetchingBody` re-check; the post-fetch reads → the single mutation-site guard. The sole remaining residual is INHERENT and accepted — a refresh that begins DURING the non-cancellable `manager.fetchBody` competes for one round-trip (its write is skipped by the mutation-site guard, and the loop-top guard blocks every subsequent tick).

**Amendment (2026-07-07) — the snapshot-publish CONTRACT + detail-view seed (`.messagesStaged` observer); staging-FILE reads ATTEMPTED, AUDITED ON-DEVICE, and REVERTED (do NOT re-attempt):** a notification tap for a just-pushed message races the tap-kicked merge's snapshot publish: `seedAtInit` + the resolve ladder read `latestStagedRows` BEFORE the merge replaces it (~100ms later), so every in-memory tier missed, `viewModel.message` stayed nil — and the skeleton is gated on the HEADER (`MessageDetailView` `if let message`), not the body — so the tap pulsed for SECONDS until an unrelated `.messageDataDidChange` (boot_logs 7); `startBodyPoll`'s fetch step also guards on `self.message`, so a nil header left the poll spinning. A same-day experiment (`d97efdf`, reverted by `0cd5513`) attacked this with DIRECT staging-FILE reads (a `readStagedForDisplay` PK read wired into the resolve ladder + body path) — on-device it resolved the tap's id in 4ms, which made things WORSE: the id resolved 13-100ms BEFORE the snapshot existed, so every downstream snapshot consumer (header seed, mark-read, staged body) still missed. Racing the publish with a faster side-channel starves the consumers behind it. **The fix that stuck — react to the publish:** `MessageDetailViewModel` observes `.messagesStaged` (the same publish signal `insertStagedRows` consumes); `seedFromStagedPublish` seeds the header the instant the snapshot is fresh (pending-sentinel match account-scoped; resolved-composite match EXACT `headerId` ONLY — the fuzzy folder-ignoring `stagedRowFallback` arm would let a same-UID INBOX push hijack an Archive open, rewriting `messageId` and marking the WRONG message read: caught in adversarial review), re-arms the `markReadOnOpenIfNeeded` fast path, and adopts the staged body (else starts the body poll, which now has its header). `resolveTapIfNeeded` returns true when the seed resolved the tap mid-ladder. **THE CONTRACT (extension rule):** staged-not-yet-durable data has ONE read-model (`latestStagedRows`/`latestStagedBodies`), ONE publisher (the merge, which publishes BEFORE its slow durable write), and one publish event (`.messagesStaged`). Consumers read the read-model (fast path) or react to the publish (catch-up) — NOBODY reads the staging file for display. Accepted residual: if the publish itself is late (merge in-flight holds the coordinator / staging busy), the skeleton shows until publish — bounded, self-healing; the lever is merge-loop latency, not another tap-side side-channel. Tests: `MessageDetailStagedPublishTests` (seed on publish, no-clobber durable-first, account-scoped, EXACT-match regression, body catch-up), `StagedSnapshotParityTests` (the `StagedMessage(row:)`/`toInboxRow()`/`toBodySnapshot()` extraction — kept from the experiment — builds the identical snapshot).

**Amendment (2026-07-07, same day) — the NON-staged cancelled-open hole: `recoverHeaderIfMissing` in the body poll:** the `.messagesStaged` seed only covers STAGED opens. A chat email-pill "Open Email" pushes the detail view with a plain composite id of an OLDER, non-staged message: `seedAtInit` misses (zero-I/O, staged-snapshot-only — the sync durable read was removed for a measured ~4.3s main-thread stall, boot_logs 6), `loadBody`'s initial header read gets cancelled by the chat-collapse/nav churn (GRDB throws `CancellationError` in cancelled Tasks) and latches `loadBodyCalled` — so the header-resolve ladder never runs and NOTHING sets `message`: the header-gated skeleton pulsed forever (boot_logs 8, +4026513/+4058827; the poll's entry fast-path even adopted the cached BODY and returned, ending the poll with a nil header). Fix: `startBodyPoll` — already the designated un-cancelled recovery task — now recovers the HEADER too (`recoverHeaderIfMissing`: `resolveMessageAsync`, i.e. exactly the PK → cross-folder → rfc822 → staged-fallback resolve the cancelled `loadBody` would have run; durable tiers first, so this does NOT reintroduce the fuzzy staged-hijack excluded from the seed). Runs at poll entry (ordered BEFORE body adoption so adopt-and-return can't end the poll header-less) and at each 2s tick; the poll ends only when body AND header are set. Guarded off while `pendingProviderTapId != nil` (the tap ladder owns sentinel resolution) and no-ops instantly when `message != nil` — the staged fast paths pay zero added I/O. `adoptReadyBody` stays body-only (load-bearing for `refreshAfterMergeCommit`). Tests: `MessageDetailHeaderRecoveryTests` (chat-pill repro both-recovered, header-only stays alive, no-clobber, pending-tap guard).

**Amendment (2026-07-09) — three "inbox briefly reverts to pre-merge state" races fixed (`boot_logs 2`) + the redundant kept-row re-merge eliminated:** the in-memory staged render is instant (median 3ms post→insert), but the durable phase-1 write lands mean 3.9s / p90 7s later under load (writer-thread starvation during concurrent sync/paint CPU bursts — NOT WAL, NOT staging-DB contention, NOT writer-queue waits: `acquireWriter≈0`, `sched≈0`, `wal` KB-scale on all 49 >2s merges). Three races made that window user-visible, all shipped fixes:
1. **Guard release rule (Pass-1):** `overlay[id] == nil` released the eviction guard on ANY user mutation — opening a message registers an isRead overlay instantly (`markReadOnOpenIfNeeded`; thread-open marks many), so reading a just-pushed message let the next reload evict it until the durable write landed. Now ONLY a folder-move overlay releases the guard (`overlay[id]?.folderId == nil` survives); `applyOverlay` already filters moved-away rows from `fresh`, so a folder-move is the only legitimate reason a protected row is absent from `freshById`. Tests: `InboxStagedRowGuardTests`.
2. **AI-field carry-over (Pass-1):** phase-1/sync-created headers carry NO AI fields; the first durable row to appear in `fresh` blind-replaced the staged snapshot → actionTag/summaryBlurb flashed away until phase-2 + the AI repaint (phase1→phase2 gap usually ~15ms, observed 13.9s; a sync insert can precede the merge entirely). While `pendingStagedRows[id]` exists, nil AI fields on `fresh` inherit the staged values (`MessageSnapshot.tagSortOrder` is now `var`); the guard entry is retained until a fresh row arrives WITH real AI fields (still bounded by the 60s expiry). Mirrors the detail-view rule "do NOT applyRefresh AI fields from phase-1 rows".
3. **Stale-protection TTL (per-entry expiry):** `AccountManager.recentlyCompleted` now stores per-entry EXPIRY dates (`recordRecentlyCompleted(messageIds:ttl:)`); push-merge registration uses `SyncConfig.pushMergeStaleProtectionTTLSeconds` (120s — the 30s default expired 5s before an observed INBOX stale-delete of a pushed message; push-merged rows are upserted ONLY by the merge, so protection is their sole shield against a transient fetch-miss). All sync snapshot sites (`fullSync`, `syncMessages`, both deltas, deletionReconcile) now prune before snapshotting — the sync-side reads are presence checks that don't consult expiry. Tests: `RecentlyCompletedTTLTests`.
4. **Stage-memo skip (kept-row re-merge elimination):** every merge trigger re-ran BOTH write phases for every KEPT gradual row (`aiCompleted=0`) — one message's body written 36×, 80 no-op merges holding the writer 16.5s total. `performMerge` now partitions staged rows by a per-row `StageKey` presence signature vs an in-process `stageMemo` (Mutex); memo-identical rows are durability-VERIFIED (one `rawPool` batch read: header + body-if-staged exist — a failed verify re-merges and drops the stale entry, so a sync stale-delete self-heals instead of staying invisible) and then skipped from both write phases — a fully-skipped merge never acquires the GRDB writer. Skipped rows still publish `latestStagedRows`/`.messagesStaged` (computed pre-partition), still refresh stale-protection (load-bearing for #3), and post no render signals. Tests: `NSEMergeStageMemoTests`.
5. **Guard clock correctness (`ForegroundActiveClock`, same day):** the eviction-guard window was measured on `CFAbsoluteTimeGetCurrent()` (wall clock) — it kept flowing through device sleep and app suspension, exactly when neither the durable write nor a reconciling reload can progress (the 435s suspended-merge, slept=127s, would expire the guard mid-write and let a resume-racing reload evict + tombstone a real row). `pendingStagedRows` ages now use `ForegroundActiveClock.now()`: base `CLOCK_UPTIME_RAW` (excludes device sleep, NTP-immune), additionally paused across app backgrounding (`didEnterBackground`→`willEnterForeground`), and reading FROZEN during an in-progress background span (a BGTask wake must not see the suspended span as elapsed). Semantics: "running time to make progress" — use it for guards, never for user-visible/persisted timestamps. Tests: `ForegroundActiveClockTests` + `suspendedSpanDoesNotExpireGuard`.

**Amendment (2026-07-09, evening) — the display-side compensating machinery is SUPERSEDED by ADR-IOS-055 (single merged read-model).** The instant in-memory insert (this ADR's core) remains, but purely as a latency optimization: `InboxListReader`/`InboxListComposer` now compose EVERY list read from durable ∪ overlay-pinned ∪ staged, so the Pass-1 eviction guard (`pendingStagedRows`), the `expiredStagedIds` tombstones, the Pass-1 AI carry-over, `SyncConfig.stagedRowEvictionGuardSeconds`, `ForegroundActiveClock` (items 1/2/5 of the morning amendment above), and the `.stagedRowsInvalidated` VM-eviction path from the stale-by-move fix are all DELETED — a reload converges to the composed truth without them. The merge-side stale-by-move detection + staging-delete + snapshot scrub, the stale-protection TTL (item 3), and the stage-memo skip (item 4) are unaffected (write-path, still load-bearing). If "suspension-aware active time" is ever needed again, `ForegroundActiveClock` is resurrectable from git (deleted at the Phase-5 commit of PLAN_INBOX_UNIFIED_READ.md); its semantics are documented in item 5 above.

**Relates:** builds on ADR-IOS-047 (two-phase merge); supersedes the reverted ADR-IOS-048 intent; display machinery superseded by ADR-IOS-055.

---

## ADR-IOS-050: `bodyComplete` Is the FTS-Indexed Truth — Display-Cache Eviction Never Touches It

**Context:** Users saw indexing "go backwards and then forwards" and accounts that could never finish. `backfill.log` showed the body-pending population climbing (6,788 → 8,414 → 9,347) *while* the backfill completed 50-item batches every few seconds — net-negative progress. Root cause: `BodyAssetMaintenance` (the inline-image asset cache's LRU evictor, cap default 1 GB, run on every foreground poll) flipped `bodyComplete = 0` on each eviction victim. During an archive backfill the least-recently-accessed assets are the backfill's *own just-written output*, so the system was a closed loop: backfill fetches bodies → writes image assets → cache crosses cap → evicts the backfill's output and un-completes it → repopulate re-enqueues → refetch → re-fill → evict. Bandwidth and battery burned indefinitely; `pendingBodyCount` could never reach 0, so `isFullyComplete` never fired.

The flip conflated two independent facts:
- **"Body text is fetched and indexed in FTS"** — what `bodyComplete` actually gates (backfill pending population, `pendingBodyCount` completion, AI queue, embedding queues). Eviction never touches fts.db, so this fact remains TRUE for every victim.
- **"Rendered HTML + assets are on disk for instant display"** — a cache property. The flip existed so an open wouldn't render HTML with dead `tabmail-asset://` refs, but deleting the `messageBody` row in the same write already guarantees that (the detail view fetches on cache-miss).

**Decision:** `bodyComplete` means exactly one thing: *the body text is indexed in FTS*. It is set only after a confirmed FTS write (`flushBatch`, NSE batch flush) and cleared only when the indexed truth is invalidated (user Refetch, FTS-loss self-heal, Smart Reindex). **The display cache gets NO flag** — the `messageBody` row's existence IS its state, atomically maintained with the asset files. A second flag would just recreate the drift problem one level down. This was already the contract everywhere else: `runEvictStaleBodies` (TTL) and `runPruneIfOverBudget` (storage budget) have always deleted `messageBody` rows without flag flips; `BodyAssetMaintenance` was the lone outlier.

1. `BodyAssetMaintenance.dropMessage` and `wipeAll(.inlineImage)` delete the `messageBody` row + asset files only. (`wipeAll` bonus: "Delete All Email Attachments" no longer triggers a full-history re-download; bodies return lazily on open.)
2. **One-time reverse heal** (`SyncEngine.oneTimeBodyCompleteRestore`, gate `bodyCompleteRestore.v1.done`): pending rows (`headerComplete=1, bodyComplete=0, bodyEmptyConfirmed=0`) whose FTS entry has real body text (`SearchIndex.headerIdsWithFTSBody`, length>1 — excludes the " " sentinel and header-only entries) AND have no `messageBody` row flip back to `bodyComplete=1`. Zero network. The no-cached-HTML guard keeps every "cache present but flagged for re-render" state (NSE unresolved-CID mail — which also never writes an FTS body — and suspension-aborted flag writes) on the conservative refetch path. Gate set only after a clean pass; interrupted runs resume next launch.
3. **Eviction is observable**: every evict/wipe run logs victims + MB reclaimed + duration to `backfill.log` (it was previously silent, which is why this took forensic effort to find).
4. `EmailReadTool` falls back MessageBody → FTS body text → snippet, so the agent reads full bodies for cache-evicted (old) messages.

**Consequences:**
- The refetch loop is dead: eviction discards only bytes, never state. During heavy backfill the asset cache still churns at its cap (each message's assets written once, evicted once) — wasted disk I/O but bounded and net-forward; "should backfill even persist inline images for years-old mail" is a separate future optimization.
- `bodyComplete=1` does NOT imply a `messageBody` row exists (it never reliably did — TTL/budget eviction predates this). Verified consumers: detail view fetches on cache-miss; compose quoting falls back to snippet (human replies come from an open message, which re-caches); AI reads `SearchIndex.bodyText`; embeddings read FTS.
- Rows evicted by the pre-fix flip are healed on first launch without refetching.

**Tests:** `BodyCompleteRestoreTests` — eviction preserves `bodyComplete` while dropping the cached row; heal flips FTS-backed victims; skips cached-HTML rows, header-only FTS entries, `bodyEmptyConfirmed` rows; one-time gate; `headerIdsWithFTSBody` probe classification.

**Relates:** ADR-IOS-046 (abandon-on-suspend — both the evictor and the heal abandon cleanly); the backfill-stall fixes of 2026-07-02 (UID-remap re-key — the other "never reaches 100%" mechanism); PROJECT_MEMORY "Backfill / Fast Sync Completion" (`pendingBodyCount` gate).

---

## ADR-IOS-051: Evidence-Triggered IMAP External-Deletion Reconcile (VANISHED + Count-Mismatch UID Walk)

**Context:** The 2026-07-02 audit (PROJECT_MEMORY "IMAP external-deletion blind spot") confirmed that raw-IMAP/iCloud accounts never remove an externally-deleted message once it falls below the newest-`syncMessageLimit`(=50)-UID stale window: `selectStaleHeaders` is windowed, backfill is insert-only, `selfHealRecentMessages` is add-only, and the complete-knowledge branch is capped to tiny folders. Ghost rows persisted in GRDB + FTS + search indefinitely (Gmail/Exchange are immune — provider deltas carry deletions of any age). Two free signals were being wasted: `imapDeltaSync` observed `status.messageCount != folder.totalCount` but only ran the windowed sync and then OVERWROTE `totalCount` (evidence consumed, ghost survived), and IDLE `VANISHED(UIDSet)` — the server literally naming the deleted UIDs — was discarded into a generic poll.

**Decision:** Two evidence-triggered mechanisms (`SyncEngineDeletionReconcile.swift`), no periodic jobs, work proportional to drift, UID everywhere (never date — ADR-IOS-042):

1. **Phase 1 — consume IDLE `VANISHED`:** `SyncScheduler` maps `.vanished(uidSet)` → `SyncEngine.handleVanishedUIDs` (targeted deletes on the IDLE-monitored INBOX) and still runs the generic poll. `.expunge` carries SEQUENCE numbers, not UIDs — cannot be mapped safely; it remains a generic poll trigger.
2. **Phase 2 — count-mismatch reconcile walk:** For IMAP folders, local GRDB is a partial mirror (optimistic local deletes only LOWER local count), so **`localHeaderCount > server messageCount` proves ghosts exist** (`local < server` is backfill-normal). The predicate (`shouldReconcileDeletions`, tolerance `SyncConfig.deletionReconcileCountTolerance`=0) is evaluated (a) in `imapDeltaSync` after a changed folder's windowed pass, against the LIVE local count vs the just-fetched STATUS count (the `totalCount` overwrite is kept — the trigger no longer depends on it), and (b) per IMAP folder at the end of `fullSync` (catches ghosts when STATUS-change gating skips delta). The walk iterates the LOCAL UID set ascending in chunks of `deletionReconcileChunkSize`(=500), issues explicit-set `UID SEARCH UID <set>` per chunk (`IMAPProvider.searchExistingUIDs(folder:uids:)` — response can only name queried UIDs, far below the 1MB NIO buffer), deletes `chunkLocalUIDs − serverFound` per chunk, and yields between chunks (work-queue `.headerFetch` priority, per-chunk pool checkout — backfill etiquette). No persisted walk progress: the evidence is durable/recomputable, an interrupted walk re-triggers, per-chunk deletion shrinks the mismatch monotonically.
3. **Safety invariants:** a thrown SEARCH chunk deletes NOTHING from that chunk (connection/SELECT errors abort the walk; other errors skip the chunk). **UIDVALIDITY guard:** `folder.lastKnownUidValidity` (new nullable column, migration `v63`) is bootstrapped by the walk's first SELECT; any later mismatch — or an unreported (0) value — ABORTS without persisting (a changed UIDVALIDITY invalidates every local UID; the UID-remap/resync machinery owns that case). A failed DB write aborts (abandon-on-suspend, ADR-IOS-046).
4. **One deletion path:** every deletion (Phase 1 + Phase 2) flows through `deleteServerConfirmedDeletions` → `deleteConfirmedGhostHeaders`, which applies the SAME protections as the windowed stale flow (pending ops targeting the folder as source OR destination, recently-completed ops, in-flight outbox sends in Sent) and the SAME FTS-removal channel (`removeHeadersFromFTS`) + unread recount. Protected rows survive; remote-wins is settled by the existing drain conflict handling and the evidence re-fires after the queue drains.

**Rejected alternatives:** periodic full-folder scans (cost without evidence; violates the no-periodic-jobs goal); per-row `verifiedAt` columns (persistent state to maintain — the COUNT-vs-STATUS predicate is recomputable for free); any date-windowed sweep (ADR-IOS-042 — UID and date are decorrelated; this class already caused multi-month data loss); mapping `.expunge` sequence numbers to UIDs (requires a perfect local sequence mirror we don't keep — unsafe).

**Consequences:**
- Walk cost is paid only on provable drift: O(localCount / 500) SEARCHes per triggered folder, serial, background-priority.
- `.expunge`-only servers (no CONDSTORE/QRESYNC) get no targeted deletes from IDLE; the Phase 2 predicate still catches the drift on the next delta/full sync.
- A folder whose UIDVALIDITY changed keeps its (now-dangling) sub-window rows — status-quo blind-spot behavior, never mass-deletion; the walk stays disabled for that folder until the stored value is reconciled (future work alongside Phase 3).
- **Phase 3 (documented only, not implemented):** the SwiftMail fork already supports CONDSTORE/HIGHESTMODSEQ/VANISHED; a future O(changes) path can ENABLE QRESYNC where advertised, SELECT with QRESYNC params, and consume `VANISHED (EARLIER)`. Phases 1+2 close the correctness hole without it.
- **Deletion circuit breaker (hardening, added same day):** the walk's per-ghost proof is a single source — the SEARCH response — so a response that ever parsed as falsely EMPTY (server quirk, protocol regression) would read entire chunks as ghosts. The walk therefore caps cumulative deletions at the trigger's expected mismatch (`localCount − serverCount`) + `SyncConfig.deletionReconcileCapSlack`, aborting BEFORE the offending chunk. Worst case becomes "walk aborted, logged" instead of "folder wiped"; legitimate excess deletions re-derive a higher cap from fresh counts next sync. Phase 1 (VANISHED) is uncapped by design — the server explicitly names those UIDs.

**Tests:** `SyncEngineDeletionReconcileTests` — trigger predicate (tolerance boundaries, backfill-normal direction), ghost selection (subset/superset/empty/all-gone), chunk planner (exact multiple/remainder/empty/sorting), walk semantics via injected effects (failed-chunk-skips-deletes, connection-error abort, stored-validity mismatch abort without persist, mid-walk validity-change abort, bootstrap persist-once, validity-0 abort, persist/delete failure aborts, deletion-cap: within-cap proceeds / exceeding chunk aborts undeleted / first-chunk-over-cap deletes nothing / exact boundary allowed), shared deletion path on in-memory GRDB (exact-UID deletes, unknown-UID no-ops, pending-op source+destination protection, recently-completed protection, outbox Sent protection, unrelated-op non-protection), v63 column round-trip.

**Relates:** ADR-IOS-042 (UID not date), ADR-IOS-014 (connection pool / per-batch checkout etiquette), ADR-IOS-041/046 (suspension / abandon-on-suspend), PROJECT_MEMORY "IMAP external-deletion blind spot", `PLAN_IMAP_DELETION_RECONCILE.md`, TB counterpart `../tabmail-thunderbird/PLAN_FOLDER_SET_RECONCILE.md`.

---

## ADR-IOS-052: Presentation-Time ICS Sanitizer for Incoming Invites

**Context:** A real `text/calendar; method=REQUEST` invite generated by a third-party webmail calendar composer wedged the user's iOS Calendar ↔ Google Calendar sync after being added via the native "Add to Calendar" dialog. Root cause was not our code: the file was 85 KB, of which a single `X-ALT-DESC;FMTTYPE=text/html` property was ~79 KB — an editor bug that duplicated one CSS class token ~2,600 times. iOS imports the event verbatim, then pushes it to Google via CalDAV; Google rejects the oversized event and, because CalDAV pushes changes sequentially per collection, the one permanently-rejected event stalls everything queued behind it → "calendar stopped syncing". The file also carried an RFC-invalid `VALARM` (`ACTION:DISPLAY` with no `DESCRIPTION`, required by §3.6.6), HTAB line folding, and a foreign `ORGANIZER`. Our production "Add to Calendar" path (`ICSCalendarImporter`) forwarded the raw, unparsed bytes to the OS.

**Decision:** Sanitize the ICS at the single presentation choke point — the first statement of `ICSCalendarImporter.presentCalendarImport(icsData:)` — via a new total, idempotent `ICSSanitizer.sanitize(_:)` (`Shared/ICS/ICSSanitizer.swift`). Because the `icsText:` overload and the demo-mode branch both funnel through `presentCalendarImport(icsData:)`, one hook covers every current and future presentation path with no UI changes. Rules (all limits in `ICSSanitizerConfig`, no hardcoded numerics): drop `X-ALT-DESC` unconditionally; size-gate any other non-keep-list property (catches generic bloat like inline base64 `ATTACH`); truncate over-long keep-list text values (DESCRIPTION/SUMMARY/LOCATION/COMMENT) at a UTF-8- and escape-safe boundary; inject `DESCRIPTION` into DISPLAY alarms that lack one and drop EMAIL/PROCEDURE alarms; strip illegal control chars; normalize folding (accept CR/LF/CRLF + SPACE/HTAB continuation) and re-fold to ≤75-octet CRLF lines; whole-file backstop that drops largest non-essential properties if still over cap; and drop the single `ATTENDEE` whose address equals the `ORGANIZER` (organizer-listed-as-its-own-attendee is hidden by Google Calendar — the organizer and every other attendee are preserved, so RSVP still works). On the real trigger file: 85,107 → 2,607 bytes, all event semantics preserved.

**Rationale:**
- One choke point is provably complete (verified against the code): both real and demo import paths and the `icsText:` overload pass through `presentCalendarImport(icsData:)`.
- Semantics are essentially never rewritten — `METHOD`/`ORGANIZER`/`ATTENDEE`/recurrence/`VTIMEZONE` pass through, with ONE surgical exception: the `ATTENDEE` that duplicates the `ORGANIZER` is dropped. That self-reference (organizer listed as its own attendee) causes Google Calendar to hide the imported event; removing just that one entry keeps the organizer + real attendees intact, so RSVP is unaffected. We do NOT strip the whole scheduling triad (that would kill RSVP), and we do NOT rewrite `ORGANIZER` to the local user (forging meeting identity). The remaining foreign-organizer Google rejection is an OS/provider concern.
- Stored copies stay full: the on-disk attachment (`BodyAssetStore`), the share-sheet file, and `MessageBody.icsText` are byte-identical originals. Truncation is the sanctioned "hard external constraint on the constrained-path input" pattern (global CLAUDE.md rule 11) — the *presented* bytes only.
- The inline invite card (`ICSBuilder.parseIncoming`) is a read-only summary that never reaches EventKit/Google, so it is deliberately NOT hooked (would burn NSE budget for no user-visible benefit).

**Rejected alternatives:** sanitize at extraction/persistence (violates full-length-storage rule, burns NSE budget on a read-only path); rewrite `ORGANIZER` to the local user (forges meeting identity); refuse/warn on oversized imports (new UI, against the explicit no-UI-change requirement); reuse `ICSBuilder`/`ICSParser` as the cleaner (both are lossy-by-design extractors — sanitization must be lossless except for the specific rules).

**Consequences:**
- Residual (accepted, not fixable from ICS content): a foreign-organizer scheduling object with fully external addresses — where the target calendar's owner is neither the organizer nor a participant — is rejected by Google CalDAV (409) and iOS retries it forever, which is the real "wedge". Confirmed via an on-device bisection suite (since removed): reconstructing the invite with the user's own/friendly addresses only ever *hides* the event; the hard brick needs the real external addresses (which we can't put in a test without emailing the real parties). The `ATTENDEE`==`ORGANIZER` drop removes one Google-hostile bit but does not resolve the underlying iOS↔Google CalDAV behavior; fully avoiding it would require either stripping the scheduling (kills RSVP) or adding via the Google Calendar API instead of iOS Calendar (Google-only, larger project). Parked as an iOS system-level limitation.
- Any new caller that presents ICS to the user/OS must route through `presentCalendarImport` (or call `ICSSanitizer.sanitize` itself) — do not add a bypass.
- Debug log is `#if DEBUG` (DebugModeManager is main-app-only; the sanitizer lives in `Shared`, compiled into the NSE too).

**Tests:** `TabMailTests/Shared/ICSSanitizerTests.swift` (16 cases, synthetic fixtures with generic domains + dynamic dates): trigger pathology (X-ALT-DESC dropped, semantics preserved, size under cap), DISPLAY-alarm repair + no-double-DESCRIPTION, EMAIL/PROCEDURE alarm drop with sibling DISPLAY kept, oversized-ATTACH drop, DESCRIPTION truncation at escape-safe boundary, tab/LF folding normalization to ≤75-octet CRLF, multi-byte fold safety, clean-invite preservation, idempotence, non-UTF-8 + non-calendar passthrough, `ICSBuilder.parseIncoming` round-trip parity, control-char strip, organizer-as-attendee drop (keeps organizer + other attendees), and no-drop-when-no-organizer-duplicate.

**Relates:** global CLAUDE.md rule 11 (never truncate stored user content), ADR-IOS-045 (imperative QuickLook/import presentation), `PLAN_ICS_SANITIZER.md`. No TB counterpart — Thunderbird handles incoming invites natively (Lightning); our addon is not in that path.

---

## ADR-IOS-053: Owned, Level-Triggered Delivery for FSM Tool UI Requests (Supersedes the delivery mechanism of ADR-IOS-024 and ADR-IOS-030)

**Context:** Confirmation-based ("FSM") agent tools suspend a chat turn while a UI request (a confirmation card, or a compose window) is shown, then resume on the user's response. The original mechanism (ADR-IOS-024, ADR-IOS-030) handed the request off through a single global slot on `AgentToolRouter` (`pendingAction` / `pendingCompose`) observed by every mounted `DynamicIslandChat` / `InboxView` / `MessageDetailView` via `.onChange`. Because ≥2 of those views are mounted at once in a NavigationStack (the inbox pill stays alive under the message-detail pill), the write raced: the first observer to fire consumed and nilled the slot and delivered the card to *its own* session — possibly an off-screen session the user was not looking at. `.onChange` is edge-triggered and never replays a value already set when a view mounts, so a request written while no correct observer was live was lost outright. The suspended continuation had no owner and no timeout, so a mis-delivered card produced an infinite "creating/editing calendar" spinner and wasted the LLM round. Reproduced on `calendar_event_create`, which does zero pre-card work — proving the fault is delivery, not any provider/network/timeout path.

**Decision:**
1. **Owned routing, explicit seam.** The invoking chat session's delivery channel (`AgentUISink`, holding the `ChatPillState.Session` captured at send time) is passed as an explicit invocation-scoped parameter (`ToolInvocation`) threaded alongside the existing `onSSEEvent` handler: `AIService.sendChatMessage`/`resumeChatMessage` → `sendWithTools[Direct]` → `BackendClient.sendCompletionsWithTools[Direct]`/`…Internal` → `ToolRegistry.execute` → `AgentTool.execute`. It is NOT ambient (no `@TaskLocal`) and NOT part of `ToolContext` (which stays construction-scoped for global deps). A confirmation tool invoked with a nil sink (non-interactive callers: reply precompute, inline edit, task eval, BYOK smoke) returns `ok:false` immediately — a visible structural failure, never a hang.
2. **Level-triggered rendering.** The pending UI request is stored in the owning `ChatPillState.Session` (which outlives pill expand/collapse and view teardown) as a `ChatMessage(actionConfirmation:)` and rendered declaratively by the pill's `ChatBubble` → `ActionConfirmationCard`. No global slot, no `.onChange` edge event. A request in the model is shown whenever that session's pill is on screen and cannot be missed or raced. `AgentToolRouter.pendingAction` and its observer are removed.
3. **No timeouts.** Delivery is now reliable and level-triggered, so the card is never lost; the continuation's only resolvers are the user's response and Stop (task cancellation → declined via `withTaskCancellationHandler` + `ContinuationGuard`, unchanged). Timeouts are prohibited on this path.
4. **Applies to all FSM tooling.** Confirmation cards (Phase 1, implemented — the 12 confirmation tools) and compose windows (Phase 2, planned — keeps ADR-IOS-030's cover-serialization FIFO but re-homes routing to the owned channel).

**Implementation shape (minimal-churn form of the sub-decision):** `AgentTool.execute(arguments:invocation:)` is a protocol requirement with an extension default that forwards to `execute(arguments:)`, so **non-FSM tools are untouched** (they inherit the default). `invocation` params are **defaulted** to `.noninteractive` through the completion chain, so **non-interactive callers are untouched**. FSM tools implement `execute(arguments:invocation:)` (real logic using `invocation.uiSink`) plus a trivial `execute(arguments:)` forwarder to `.noninteractive`.

**Rationale:**
- A missing delivery channel must fail at compile time or as an immediate `ok:false`, never as a silent hang. Explicit threading + the nil-sink check make the missing-channel case loud; `@TaskLocal` would reintroduce the same silent-wiring failure class and is at odds with the codebase's explicit-concurrency stance.
- Level-triggered rendering from owned session state is structurally immune to the edge-triggered / no-replay / cross-view-race failure modes of the global slot, and additionally routes concurrent turns in different sessions correctly.
- Construction-scoped deps (`ToolContext`) and invocation-scoped routing (`ToolInvocation`) are different lifetimes, kept separate.

**Consequences:**
- The observer races on `pendingAction` (and, after Phase 2, `pendingCompose`) are eliminated.
- Non-interactive completion paths pass `ToolInvocation.noninteractive`.
- In-memory only: app kill still loses an in-flight turn (consistent with ADR-IOS-030) — acceptable; these are session-scoped agent intents, not durable user actions (contrast ADR-IOS-018/019).
- **Tests:** `TabMailTests/Tools/FSMToolDeliveryTests.swift` — owned routing (card reaches only the invoking sink, not another session's), nil-sink fast-fail without suspension, accept/decline resume, and `SessionUISink` level-triggered append.
- **Files:** `TabMail/Services/AI/Tools/ToolInvocation.swift` (new: `ToolInvocation`, `AgentUISink`, `SessionUISink`); `ToolRegistry.swift`, `AgentToolRouter.swift`, `BackendClient.swift`, `AIService.swift`, `AIChat.swift`, `DynamicIslandChatButton.swift`, and the 12 confirmation tools.

---

## ADR-IOS-054: Programmatic Message Opens Use a Real `navigationDestination(item:)` Push — Never the Inbox `List(selection:)` Binding

**Date:** 2026-07-07
**Status:** Accepted (on-device confirmed)

**Context.** The app (iPhone-only, collapsed `NavigationSplitView`) historically opened every message by writing `selectedMessageId` — which is ALSO the inbox `List(selection:)` binding (`listSelectionBinding` in `InboxView`) — and letting the detail column (`MessageDetailContainer`) swap content on it. That works when the value corresponds to a real, currently-rendered list row (inbox row taps) and happened to work for notification deep links. It silently FAILED for chat email-pill opens: the pill writes a message id that is NOT any row of the rendered inbox list (Sent/Archive/All-Mail), while the list is mid re-render from the concurrent chat-collapse spring animation. SwiftUI's `List(selection:)` reconciles the foreign selection away — the framework revokes the push within ~10ms-1s: the detail's `.task` is cancelled mid-DB-read (the chronic `loadBody CANCELLED (initial read)` on this path — long misattributed to "navigation churn"), the inbox bounces (`onDisappear`→`onAppear` back-to-back), the selection is nil'd, and the detached detail view is deinit'd. Its lazy `List` never lays out, so the ViewModel looks perfect in logs (header recovered, body adopted, `bodyContent` builder evaluating `content`) while NOTHING renders — and no scroll anchor can run. Two earlier fixes (the `.messagesStaged`/poll header recovery and the multi-pass scroll re-anchor) were tuning a view that was never validly on screen for this path.

**Decision.** Programmatic opens whose target need not be a list row drive a REAL navigation-stack push: `@State pushedMessageId` on `MailNavigationView` + `.navigationDestination(item: $pushedMessageId)` registered on the content column's root (so it exists for every content-column selection), rendering `PushedMessageDestination` → `MessageDetailResolvedContent` (the drafts-check + `MessageDetailView` resolution, extracted and shared with the detail column). The List has no way to revoke a genuine push. Popping writes nil into the binding automatically. Migrated: both `.emailPillTapped` handlers (InboxView + the MailNavigationView fallback). Deliberately NOT migrated (working, untouched): inbox row taps (a real row selection), notification deep links (`selectedMessageId` + sentinel flows), the folder-change wipe. Known same-class candidate to migrate if it ever misbehaves: the agent-toast tap (`InboxView.handleAgentToastTap`) writes a possibly-foreign `selectedMessageId`.

**Rule for new code:** any new "open this message" entry point that is not literally a tap on a rendered inbox row must use `pushedMessageId` (or its own `navigationDestination`), never `selectedMessageId`. `listSelectionBinding.set` carries a debug-gated `[DetailRender]` trace so a future selection revocation is caught red-handed.

**Related same-day view fixes (detail open UX):** `MessageDetailSkeleton`'s pulse is `.phaseAnimator`-driven — a `repeatForever` animation started in `onAppear` leaks into the removal transition and strands a pulsing ghost skeleton over the rendered content (on-device confirmed); and the skeleton has a 350ms minimum dwell so fast opens keep the skeleton→content dissolve consistently across paths.

**Amendment (2026-07-08) — `.navigateToAccount` migrated to the same push pattern (defensive), and the Account-page infinite spinner root-caused to a DIFFERENT mechanism.** The Account dashboard's forever-spinner was initially suspected to be this ADR's selection-revocation (WarningBubble → direct `selection = .account` write). On-device instrumentation DISPROVED that for the observed repro: the sidebar selection stayed stable and the view identity never changed (`[Dashboard] id=` constant), yet `.task` cancel/restarted in a ~100Hz self-sustaining storm. Real cause: **`.task`/`.onAppear` attached directly to a `@ViewBuilder` conditional (`if isLoading … else if errorMessage … else …`) fire disappear/appear on every branch flip, and `loadData()`'s own state writes flip the branch** — `isLoading = true` on entry cancels the just-started task (`URLError.cancelled`), the exit path's state write flips it back and restarts it. The pre-fix `if !Task.isCancelled { isLoading = false }` gate turned this into a silent deadlock: first success flipped spinner→content, the restarted task flipped it back and cancelled itself, `isLoading` stranded true → permanent spinner with zero logs. Fix: anchor `.task`/lifecycle modifiers on a stable `ZStack { content }` wrapper that survives branch flips, plus `loadData()` defer-clears `isLoading` (the `InboxViewModel.performSync` precedent) and surfaces a Retry state on a cancelled data-less load. **Rule for new code: never attach a load-driving `.task`/`.onAppear` directly to a conditional whose branches the load's own state writes control — hang it on a stable container.** The `.navigateToAccount` push migration (`pushedShowsAccount` + `.navigationDestination(isPresented:)` on the content-column root, chat collapse via `CollapseChatOnNavigateModifier`) was kept — it conforms to this ADR's rule for programmatic non-row entry points. Remaining same-class candidates still on direct selection writes: `.navigateToSettings`, `.navigateToPlanPicker`, `.navigateToAIProvider` (and the agent-toast tap noted above) — migrate if they ever misbehave.

**Amendment (2026-07-09) — the spurious-disappear quirk hits InboxView on EVERY sidebar → content entry; lifecycle-driven UI state must not trust a bare `onDisappear`.** On-device logs (logmain.log, build 343): every mailbox-selection → inbox/folder entry fires `onAppear` → `listDidAppear` → **spurious `onDisappear` in the same runloop, with no re-appear** — the view stays visible and keeps evaluating body afterwards. The spurious disappear also "spends" the balanced appearance callback: a subsequent detail push fires NO further `onDisappear` (the next real event is the pop-back `onAppear`). Regression symptom: `InboxView.onDisappear` unconditionally set `sideButtonsReady = false`, stranding the filter/search side buttons hidden until a real pop-back `onAppear` (returning from an email restored them; re-entering from the sidebar never did). Fix: gate the hide on `detailPushed` (`selectedMessageId != nil || pushedMessageId != nil` at disappear time) — the only disappear where hiding matters is a detail push over a still-alive InboxView. A sidebar return DESTROYS the view (fresh `@State` + new VM instance per entry, confirmed by per-entry instanceTags), and a `pushedShowsAccount` cover physically hides the buttons. **Rule for new code: `onDisappear` on a content-column page is NOT a reliable "user left" signal — it fires spuriously right after appear on collapsed-split-view push transitions. Gate any state mutation there on corroborating navigation state (pushed-detail bindings), or design the state so a fresh view instance re-derives it.**

---

## ADR-IOS-055: Single Merged Read-Model for the Inbox List — One Pure Composer over Durable ∪ Pinned ∪ Staged

**Date:** 2026-07-09
**Status:** Accepted (full suite green; device soak pending)
**Supersedes:** the compensating display machinery of ADR-IOS-049 (Pass-1 eviction guard, tombstones, AI carry-over, `ForegroundActiveClock`, `.stagedRowsInvalidated`) — NOT its instant-insert render path, which remains as a pure latency optimization.

**Context.** The inbox list had FOUR read paths that disagreed about what "the list" is: `insertStagedRows` (staged snapshot + overlay + in-memory dedup — blind to durable truth), `reloadMessages`/`fetchFullRange` (folder-filtered GRDB + overlay — blind to staged and moved-in rows), `resetMessages` (GRDB page-1 + staged re-seed), and `insertUndoneMessages` (by-id GRDB + overlay folder override — no reload-survival guarantee). Every staged-row display bug fixed on 2026-07-09 (guard-release-on-any-overlay, AI-less phase-1 clobber, wall-clock guard expiry during suspension, archived-mail resurrection from state-change re-stages) plus a latent undo hole (an undone row was evicted by the very next reload — empirically proven by a pinning test before the fix) was a coherence failure BETWEEN these paths, each patched with more per-path machinery. Full design + audit trail: `PLAN_INBOX_UNIFIED_READ.md` (local, gitignored).

**Decision.** ONE list-composition function, split into a pure core and a boring I/O shell:
- **`InboxListComposer.compose(ComposeInputs) -> [MessageSnapshot]`** (pure — no I/O, clocks, or singletons): unions **D** (folder-filtered durable rows), **P** (overlay-pinned rows whose overlay `folderId` points into the displayed set but whose durable row is elsewhere — the undo shape, fetched by id), and **S** (the in-memory `latestStagedRows` snapshot; NEVER the staging file — the reverted ADR-IOS-048 lesson), then applies overlay, filters, mode-aware sort, dedup, window trim.
- **`InboxListReader.fetch/fetchSync`** gather inputs (overlay + S Mutex snapshots BEFORE one read txn producing D, P, and per-staged-row identity resolutions) and call `compose`. `fetch` reads `rawPool` (repaint decoupling, as before); `fetchSync` serves the sync init/pagination paths. All three fetch sites (`fetchFullRange`, `fetchPage`, `resetMessages`) route through it; nothing else fetches list rows.
- **S-row eligibility is stale-by-move, NOT blanket identity-existence** (the one design defect caught in audit): a staged row is suppressed only when a durable header with the same identity exists in a DIFFERENT folder or with `isInInbox=false` (`detectStaleByMoveRows`' exact predicate), or when the durable row is actually present in D ∪ P (then its nil AI fields inherit the staged values — the relocated carry-over). A durable row that EXISTS but is invisible to D (phase-1 writes `headerComplete=false` until the post-tx FTS flush) keeps rendering from S — blanket suppression would reintroduce the vanish-flicker in exactly the window ADR-IOS-049 exists to cover.
- **Identity is shared by construction:** `DurableIdentityLookup.find` ((accountId, messageId) → rfc822MessageId fallback) is the ONE helper used by the merge's four lookup sites AND the reader. Divergence here = duplicate phantoms or resurrected archived mail; a contract-parity test pins it.
- **Event inserts (`insertStagedRows`, `insertUndoneMessages`, `.messagesStaged`/`.messagesUndone`) are latency optimizations only.** They keep the zero-I/O first-paint contract and the in-memory subset of the reader's eligibility checks (identity dedup, folder membership, overlay, unread + label filters); any divergence self-corrects at the next reload because the reader includes S and P. They carry no correctness-bearing bookkeeping anymore.

**Deleted (the payoff):** `pendingStagedRows`/`PendingStagedRow` + the whole Pass-1 guard branch, `expiredStagedIds` tombstones, the Pass-1 AI carry-over block, `SyncConfig.stagedRowEvictionGuardSeconds`, `ForegroundActiveClock` (+ tests; sole consumer was the guard — resurrect from git if "suspension-aware active time" is ever needed again; concept documented in ADR-IOS-049 amendment item 5), `.stagedRowsInvalidated` + `InboxViewModel.invalidateStagedRows` + receiver plumbing (the merge-side stale-by-move detection/staging-delete/snapshot-scrub REMAINS as hygiene), `resetMessages`' staged re-seed, `applyOverlay` (VM copy), and the guard's test suite (each behavior re-covered: see the mapping in the Phase-5 commit). `reloadMessages`' Pass-1 is an honest diff again.

**Emergent property (kept deliberately):** if sync stale-deletes a still-staged row, its identity resolution flips to "absent" and the S row becomes eligible again — the display self-heals a DB race for free instead of blanking.

**Testing (the reason this refactor is trustworthy):** the pure core is driven by `InboxComposeScenarioTests` — a 16-step lifecycle World DSL (including `silentStateChangePush`/`pushRedelivery`, because state-change silent pushes re-staging acted-on mail are ROUTINE push-worker behavior, and `ftsFlushCommit` splitting "durable exists" from "durable visible") with invariants I1–I7 asserted after EVERY step, 14 named scenarios encoding the 2026-07-09 boot-log histories, commutation permutations, and seeded SplitMix64 fuzz (~4,800 compositions). A §5A.4 retro-fit check verified the harness catches all four bug classes when each fix is deliberately sabotaged. Shell: real-temp-GRDB integration tests incl. merge-vs-reader identity parity.

**Rules for new code:**
1. Any new inbox-list read goes through `InboxListReader` (or, for zero-I/O event paths, uses the in-memory subset of `InboxListComposer`'s checks). Never a parallel GRDB list query.
2. Any change to merge dedup identity goes through `DurableIdentityLookup` and must keep the reader in lockstep (the doc comment lists all consumers).
3. Never suppress a staged row on bare identity-existence — the predicate is stale-by-move + D∪P-visibility (see `InboxListComposer` step 2 / plan §2.1a).
4. New lifecycle steps (push semantics, merge phases) get a World DSL step + invariant coverage in `InboxComposeScenarioTests` BEFORE shipping.

**Audit addendum (2026-07-09, adversarial review of the refactor — 2 HIGH + 2 LOW found and fixed):** (1) a **scrub-only merge wake** (only staged content was stale-by-move) posted NO reload signal after the sweep deleted `.stagedRowsInvalidated`, stranding the phantom the pre-detection `.messagesStaged` post inserted — `performMerge` now posts the immediate `.inboxDataDidChange` via an `else if scrubbedStaleStagedRows` branch (structurally preserves the ≤2-posts-per-wake contract; redelivery-idempotence pinned incl. the nil-date suppression-bypass edge). (2) `compose` trimmed to `targetCount` BEFORE the VM's `loadedIds` pagination dedup where the old code deduped first — in triage mode (cutoff is date-based, sort is tag-based) an already-loaded row re-enters page queries, ate a trim slot, and flipped `hasMoreMessages` false with reachable mail remaining; fixed with `InboxListQuery.excludeIds` applied after S-eligibility (so §2.1a case-(c) suppression still sees excluded durable rows) but before sort/trim; `fetchPage` passes `loadedIds`, `fetchFullRange` passes `[]`. (3) The §4.4-2 union-step >10ms BootProfiler mark is now implemented in `gather`. (4) Composer thread-adoption now uses a growing `adoptionPool` so a staged reply to a same-batch staged sibling chain-adopts under truncated `References` (old event-path parity). Each fix carries named regression tests at the layer the bug lived.

**Audit round 2 (same day — 3 more finding groups, fixed):** (5) **Pass-1 "non-empty beats empty" field preservation** — deleting the guard branch let a staged-only row's per-reload re-synthesis clobber VM-enriched fields: an in-place SnippetLoader fill reverted to the (possibly empty) staging snippet, and a thread-adoption miss reverted `computedThreadId` to a singleton, silently re-collapsing a user-expanded thread (`rebuildDisplayGroups` never migrates `expandedThreads` keys). Fresh EMPTY values no longer overwrite non-empty on-screen ones; durable rows are unaffected (their `computedThreadId` is never empty by `assignComputedThreadId` construction; a real fresh snippet always wins). (6) **Deterministic compose ordering** — `byId.values` iteration is nondeterministic and the sort had no total order, so equal-key rows straddling the window trim could alternate across reloads; both sort modes now tie-break by `id`. (7) **`DurableIdentityLookup` is now 3-step: exact-folder first, folder-blind with rfc822-mismatch REJECTION, then rfc822 fallback** — the folder-blind `(accountId, messageId)` primary could false-match an UNRELATED message for IMAP (UIDs are per-FOLDER, ADR-IOS-042); pre-existing in the merge (worst case: phase-2 wrote one message's body/AI onto another's row) and newly display-amplified by the reader (instant false suppression of a genuinely new message). A folder-blind candidate whose non-nil rfc822 DISAGREES with the staged row's is provably a different message and is rejected; nil-rfc822 candidates retain the conservative match. All five lookup consumers inherit the fix. Rules 2/3 above still apply — the lockstep list in `DurableIdentityLookup.swift` now includes the exact-folder step.

**Audit round 3 (2026-07-09, later — G3 in-memory-comparator gap, fixed):** Audit round 2 item (7) hardened `DurableIdentityLookup.find`'s folder-blind SQL step, but the composer's own belt dedup (`InboxListComposer.isDuplicateIdentity`, step 2) and `InboxViewModel.insertStagedRows`' inline dedup check were UNCHANGED — both still did a bare `(accountId, messageId)`-then-rfc822-fallback match against rows already held in memory. That silently undid `find`'s G3 rejection ONE BRANCH LATER: `find` can correctly resolve `stagedResolutions[row.headerId]?.durable` to `nil` for a staged row (rejecting a cross-folder UID collision as unprovable), but the row then still had to clear the in-memory identity-dedup check against `byId`/`loadedMessages` — and the OLD bare comparator there would flag it as a duplicate of an UNRELATED on-screen row (e.g. a P row — an overlay-pinned Archive message showing via undo) that merely shares a raw per-folder IMAP UID (ADR-IOS-042), suppressing a genuinely new message. Fix: extracted `DurableIdentityLookup.isSameLogicalMessage` — the pure in-memory analog of `find`'s step-2 rejection (different accountId → false; both rfc822 known → rfc822 equality, so a known disagreement rejects even an equal messageId; otherwise → conservative messageId equality, unchanged) — and routed BOTH `isDuplicateIdentity` and `insertStagedRows`' inline check through it. The ONLY behavior change: equal messageId + both-known-DISAGREEING rfc822 now returns non-duplicate (previously a false-positive duplicate); every previously-true case (UID-remap dup, same-folder redelivery, one-side-unknown-rfc822 collision) is unchanged. Truth-table-pinned in `DurableIdentityLookupTests`; regression coverage in `InboxComposeScenarioTests` (P-row/staged-row UID collision) and `InboxStagedInsertTests` (VM-level). `DurableIdentityLookup`'s lockstep consumer list now includes this comparator.

**Audit rounds 4 and 5 (2026-07-09): CLEAN — two consecutive clean rounds, audit closed.** Round 4 (fix-review + free sweep) confirmed the round-3 comparator's full truth table (exactly one cell changed), cross-fix consistency between `find()` and the in-memory comparator in every shared cell, and surfaced one COVERAGE hole (no positive-path label-filter test through the real reader — a genuinely-labeled durable/pinned row surviving the filter), filled test-only (`labeledDurableRowSurvivesLabelFilter`, `labeledPinnedRowSurvivesLabelFilter`, `labeledRowsSurviveLabelFilterInCompose`; `SimHeader` gained `userLabels`). Round 5 re-derived the §2.1a table from first principles against the shipped code cell-by-cell, hand-executed three scenario tests against the real `compose` source, and audited the deleted-guard-suite coverage mapping — zero confirmed findings. Closing gate: **full suite 7,609 tests / 1,032 suites green at HEAD**. Audit totals: rounds 1–3 found and fixed 9 defects/gaps (2 HIGH display regressions, 1 identity false-match class reaching phase-2 data integrity, 6 smaller), round 4 one coverage hole; every fix carries named regression tests at the layer the bug lived.

---

## ADR-IOS-056: Active Body/AI Flushes Are Normal-Tier; the Drain Budget Is a Background-Envelope Watchdog Only

**Date:** 2026-07-10
**Status:** Accepted

**Context.** `logmain.log` captured a 22s BUDGETED drain (a silent push) dominated by back-to-back 2-4s `DBwrite EXEC[priority]` trains — the active body/AI flush (`ActiveBodyQueue` → shared `BodyFetchProcessor`, and `ActiveAIQueue`'s summary/action/reply result writes) was riding `AppDatabase.dbPool`'s default `.priority` tier, the SAME tier as the NSE→inbox merge and optimistic user actions (archive/move/send/tag) and the unread-badge recount. A `DatabaseWriteQueue.priority` write jumps every queued `.normal`/`.background` write (ADR from `DatabaseWriteQueue.swift` FIX 13/PROJECT_MEMORY), so a big post-sync flush of newly-arrived mail could starve a live user action behind its own write train — the drain was accidentally privileged, when it is ordinary sync-level work. Separately, the silent-push handlers (`PushNotificationService.handleSilentPush`, the `nse_followup` and general branches) passed `drain: .budget(PushConfig.silentPushDeadlineSeconds)` UNCONDITIONALLY into `syncStartup`. That budget exists to poll-wait for the active queues within the ~30s iOS gives a BACKGROUND wake before killing the process (silent push delivered while suspended, BGAppRefresh) — a real envelope worth protecting. But a silent push delivered while the app is FOREGROUND-ACTIVE has no such envelope (the process isn't about to be killed), and the foreground boot path (`startForegroundPolling` → `syncStartup(drain: .none)`, `SyncScheduler.swift:518`) already knows this — the push handlers were the one conflated case still forcing a 22-25s polling wait in the foreground for no protective reason. `ActiveAIQueue` was, at the time of this ADR, already `.background`-tagged (2026-06-29 FIX 8) — one tier BELOW the intended target, sitting alongside deep historical backfill (`BackfillAIQueue`) instead of above it.

**Decision.**
1. **Tier (A):** `ActiveBodyQueue`'s own pool and its wrap of the shared `BodyFetchProcessor.process`/`.flushBatch` calls, plus `ActiveAIQueue`'s `dbPool`, now route through `AppDatabase.syncPool` (`.normal`) — mirroring the existing `AppDatabase.syncPool`/`PriorityGate.normal { }` pattern `SyncEngine` already uses for foreground delta/full sync, and the exact wrap shape `BackfillBodyQueue` already uses for `.background`. `BodyFetchProcessor`'s own default pool is left at `AppDatabase.dbPool` (`.priority`) — the on-demand/user-open fetch paths (`AccountManagerFetch.fetchBody`, `InboxViewModel`'s SnippetLoader tier-2 network fetch) call it unwrapped and are UNCHANGED, since a user tapping into a message is a live user action, not drain work. **DECLINED alternative (user decision 2026-07-10, do not re-litigate): re-tiering the user-open persist to `.normal` behind a return-then-persist refactor** (display from the fetched value in memory, persist async as cache-fill). Considered because in the current design the open's first render gates on the durable write (`fetchBody` returns `Void`; the detail view reads the body back from the DB). Declined: a user open is a RARE single indexed write — it creates no trains — and the refactor would add an in-memory masking layer to the detail view's heavily-audited body-adoption contracts (ADR-IOS-049 poll/refetch rounds 1–7) for negligible gain. Robustness of the simple gate-on-persist path wins. `BackfillBodyQueue`/`BackfillAIQueue`/`BackfillEmbeddingQueue` (deep historical backfill) and the unread-badge recount are untouched — they stay `.background`/`.priority` respectively. `ActiveEmbeddingQueue`'s one `embeddingComplete` write stays `.background`: it's a standalone write site (not routed through `BodyFetchProcessor`'s shared flush path), so re-tiering it is out of scope for this ADR — noted, not changed. NSE-side merge writes (`NSEDataBridge.persistRenderedBodyFromStaging`/`flushNSEBatchToFTS`) are entirely separate code (their own inline GRDB calls, never call `BodyFetchProcessor`) and are untouched; they run under `PriorityGate.privileged { }`, which forces `.priority` regardless of any pool tag (`PrioritizedDatabase.effectivePriority` checks `inPrivilegedContext` before any `.normal`/`.background` override) — so a merge in flight still wins over this re-tiering automatically.
2. **Drain gating (B):** both silent-push `syncStartup` call sites now choose their `drain:` via a new pure function, `SyncScheduler.drainModeForSilentPush(isForegroundActive:) -> DrainMode` — foreground-active → `.none`, else the unchanged `.budget(PushConfig.silentPushDeadlineSeconds)`. `isForegroundActive` reuses the existing `UIApplication.shared.applicationState == .active` oracle (the same MainActor-hopped read `handleSilentPush` already did for the stale-connections/`markAllProvidersDirty` guard), captured once and shared across both branches. `BGAppRefresh` (`.budget(bgAppRefreshBudgetSeconds)`, `SyncScheduler.swift:1037`) and `BGProcessing` (`.full`, `:1146`) are genuine background-envelope entry points and are unchanged.

**Rationale:** User actions and the NSE→inbox merge own `.priority` — that tier means "the user is waiting." The active body/AI drain is ordinary sync-level work (it makes newly-arrived mail visible/searchable/summarized), so it belongs at sync-level tier (`.normal`), same as `SyncEngine`'s own writes — above deep backfill, below the merge/user actions. Post-boot UX is unchanged either way: the queues self-schedule and self-drain regardless of who's watching, so moving them off `.priority` doesn't remove or delay the work, it just stops it from jumping ahead of a live user action in the single GRDB writer. The `.budget` drain was never meant to gate a foreground caller — it is the mechanism that lets a BACKGROUND wake poll-wait for queue completion inside its kill deadline; conflating "the deadline exists" with "always poll-wait for it" cost every foreground silent push a needless multi-second-to-25s hold even though the app was never at risk of being killed.

**Consequences:**
- Under heavy concurrent user-action load (rapid archive/move/tag), a post-boot summary/action/reply write may land marginally later than before (it now waits behind `.priority` writes it previously jumped) — acceptable; the badge, the merge, and every user action still commit first, which is the whole point.
- Foreground silent pushes (`nse_followup` and the general branch) no longer hold the handler open for up to `PushConfig.silentPushDeadlineSeconds` (25s) polling a budget that protected a background wake that never happened — `syncStartup` returns as soon as it spawns the herd, same as the ungated foreground boot path.
- An actual background-wake silent push (app suspended, or backgrounded mid-push) is byte-for-byte unchanged: `isForegroundActive == false` still selects `.budget(PushConfig.silentPushDeadlineSeconds)`.
- `ActiveAIQueue` moves UP one tier from its prior `.background` tag (2026-06-29 FIX 8) to `.normal` — it no longer shares a tier with deep historical backfill, consistent with "sync-level work at sync-level tier."

**Tests:** `SyncSchedulerDrainModeTests` (pure truth table for `drainModeForSilentPush`); `WriteTierRoutingTests` (`DatabaseWriteQueue` DEBUG-only test observer + real `AppDatabase`-backed `BodyFetchProcessor.process`/`.flushBatch` calls: `.normal` when wrapped the way `ActiveBodyQueue` wraps them, `.priority` when unwrapped — pinning the on-demand path is unchanged — `.priority` when ALSO inside `PriorityGate.privileged { }` regardless of the `.normal` wrap, and `ActiveAIQueue.dbPoolPriorityForTesting == .normal`); `DatabaseWriteQueueTests` (observer records `(priority, label)` and clears on `nil`). Existing `NSEGradualMergeTests`/`NSEMergeStageMemoTests`/`NSEStaleStagedRowInvalidationTests`/`InboxEndToEndInvariantTests` reverified green — NSE-side tiers are untouched by this ADR.

**Relates:** `DatabaseWriteQueue.swift` FIX 13 (3-tier priority-ordered writer scheduler), `PriorityGate.swift` FIX 8/5b (two-tier `.normal`/`.background` task-local overrides), PROJECT_MEMORY `project_db_write_queue`.

## ADR-IOS-057: The Action Queue Is an Intent Register, Not an Event Log — Latest-Intent Coalescing per Message Id

**Date:** 2026-07-10

**Context:** Rapid repeated gestures on the same message (alternating read/unread taps, re-tagging) each enqueued their own FIFO write closure. N taps replayed serially: N durable writes, N `folder.unreadCount` bumps, N `requestRecount(notifyImmediately: true)` badge sets, N `PendingOperation`s, N remote IMAP flag flips — and each remote state change can bounce a state-change silent push back at this device (push-worker D2 policy), churning the NSE/merge for zero net effect. Field report 2026-07-10: badges bouncing through every intermediate state while backgrounded. The overlay refcount (commit `1c5128e`) fixed the DISPLAY during the drain; the queue still replayed history. Separately, the refcount conversion had covered only gesture toggles: the move family, undo, and manual-tag paths still called `removeOverlayEntries(ids:)` unconditionally — a **mixed-path refcount bypass** in both directions (a direct-removal op completing strips a refcounted op's coalesced overlay entry; a refcounted op's final release strips a direct-removal op's still-pending folder intent), the exact bug class `1c5128e` fixed, reintroduced through the unconverted paths.

**Decision:**
1. **Per-id intent-cycle register** (`AccountManager.pendingIntentCycles` + `registerGestureIntent`/`executeIntentCycle`): the FIRST gesture intent for an id opens a cycle, takes ONE overlay retain, and enqueues ONE executor closure on the FIFO write queue. Subsequent gestures while the cycle is queued only update the register (latest value PER FIELD: isRead, isFlagged, actionTag) + the display overlay — no new closure, no new write. The executor atomically CONSUMES the cycle (a gesture landing after consumption starts a fresh cycle that executes strictly later), resolves the header off-main, and writes only fields whose final target differs from the RESOLVED HEADER's current truth (round-3 refinement — originally the gesture-time baseline; for an undisturbed cycle the two are identical). A perfect cancel-out (even toggle count, tag back to original) is a clean no-op: no local write, no unreadCount churn, no badge set, no `PendingOperation`, no remote flip. When an out-of-band writer touched the row mid-cycle (`markAllAsRead` — a local user action that bypasses the register — or a remote sync flip), the cycle's net intent is the user's latest visualized state and is asserted against the row; a write the DB already reflects is skipped as redundant.
2. **All remaining direct `removeOverlayEntries` production call sites converted to retain/release** (inbox + detail archive/delete/move incl. thread variants, `UndoService.undo`, detail read paths, both `applyManualTag`s — the latter routed through the register). `removeOverlayEntries` now has exactly one production caller: `releaseOverlayEntry`'s zero-refcount branch. Overlay entry lifetime = the union of ALL in-flight ops touching that id.
3. **Scope this round: toggles + tags coalesce; moves and undo do NOT** (they keep one closure per op, now refcounted). Move coalescing (net A→C from A→B→C, annihilating an archive against its undo, ≤1 remote MOVE) is deliberately deferred: each coalesce must reconcile UndoService stack entries, detail-view `localMovePins`/`completeLocalMove`, `ensureDurable` gating, and MOVE-vs-STORE UID-rekeying — see `PLAN_OVERLAY_CALLSITE_AUDIT.md` §5 for the phase-2 design. `applyManualTag` also lost its gesture-path `lookupMessage` (sync main-actor DB read) — the inbox variant now guards on the on-screen snapshot, per the zero-DB gesture contract (`1c5128e`).
4. **Never-drop-user-intention interpretation:** collapsing preserves the FINAL intent — that IS the intention. Intermediate states are deliberately not replayed locally, remotely, or on other devices. This extends core-philosophy point 5 (remote actions as user actions; most-recent-wins on consolidation) to the LOCAL queue.
5. **TB parity (ADR-IOS-008):** deliberate divergence, verified 2026-07-10 — the TB addon fire-and-forgets `browser.messages.update`/`.move` to Thunderbird core per gesture (no queue, no debounce; core owns IMAP write ordering). iOS owns its own IMAP write path and its own persistent action queue, so the coalescing layer lives here; TB has no equivalent layer to mirror.

**Rationale:** The queue's job is to make the user's intention durable, not to journal their taps. Serial replay amplified one decision into N provider round-trips and N badge flickers, and mixed overlay-removal semantics made "presence" mean different things on different paths (ADR-IOS-049 rounds 8–10 precedent: presence is the wrong proxy for in-flight-ness).

**Consequences:**
- A gesture intent that joins an existing cycle executes at the CYCLE's queue position (earlier than its own gesture time). Reordering vs. an intervening queued move is bounded: flag/tag writes are per-message state, and IMAP MOVE preserves flags, so net outcomes match serial replay; the executor re-resolves the header at run time (composite id is stable across the optimistic move; post-drain sync re-keys later; a rekey that has ALREADY landed by drain time still drops the write — pre-existing parity with the per-op closures, see plan §6).
- **(SUPERSEDED by the round-3 refinement in Decision 1)** ~~a cancelled-out intent leaves a mid-cycle remote value in place (remote-state-wins)~~ — that semantic produced a visible flip-back (display shows the user's final visualized state; the overlay releases; the row snaps to the out-of-band value) and, worse, let a `markAllAsRead` batch write queued BEFORE the burst silently swallow gestures that postdate it (round-3 audit, confirmed). The executor now compares against the row's current truth: an intent the row already reflects is skipped as redundant; one it doesn't is asserted — "the user's next action always takes priority over stale server state" (core philosophy §4). The narrow cost: a remote flip landing mid-cycle whose value differs from the user's net visualized intent is overridden by that intent — which is exactly what the user was looking at when they acted. Regression test: `markAllAsReadBeforeToggleBurstDoesNotSwallowLatestIntent`.
- `markRead(_ messageIds:)` batch (thread mark-read) keeps its own refcounted closure: off-screen members need in-closure resolution + filtering, and its writes are one-direction idempotent sets — not the bounce source.
- **Accepted residual (round-1 audit):** the executor consumes the cycle after header resolution but before its writes; a gesture landing INSIDE the write section opens a fresh cycle whose write executes after (correct order, not coalesced). That second write carries intent that genuinely postdates the in-flight write, so it is semantically necessary — write count is bounded by one per write-latency window, not per tap. A loop-until-stable executor was evaluated and DECLINED: it does not reduce write counts in any constructed interleaving (an opposing intent arriving mid-write always needs its own write) and adds a generation-tracked compare-and-remove protocol for no observable gain. Do not re-litigate without a new interleaving where it wins.
- **Nil-resolve retry (round-2 audit):** an intent that JOINS the open cycle during a header resolve that ends up returning nil must not be consumed and dropped on the strength of a read that predates it — pre-coalescing it would have been its own cycle with its own fresh resolve, and the row can become resolvable in the interim (an NSE merge lands). The executor now re-resolves while the cycle's `generation` moved during a failed resolve; each retry requires a new mid-resolve gesture, so the loop is bounded by the actual tap stream — and total resolve cost equals the pre-coalescing baseline (one resolve per gesture, through the same FIFO). **Round-3 hardening: on the nil-resolve path, the generation-stability check and the cycle consume are ONE atomic lock section** — with two separate acquisitions, a gesture joining in the instant between "generation unchanged" and `removeValue` was consumed by a verdict that predated it and silently dropped (retain/release stayed balanced throughout, which is why strand-hygiene assertions are structurally blind to this class — a dropped intent is not a leaked resource). A genuinely vanished row still drops its intents exactly as the pre-coalescing vanished-row branch did (the on-screen row is gone too). Fixed in the same round: `applyManualTag` now calls `ensureDurable` first — its fetchOne-guarded Step-1 write silently no-op'd for a tag-only gesture on a staged-only row (pre-existing, reachable identically before this ADR; surfaced by the audit).
- **Crash/kill window (round-2 audit, recorded not fixed):** the FIFO write queue and the intent register are in-memory; a kill between gesture and executor drain loses the burst's net intent (the durable `PendingOperation` only exists once the executor writes). This is the pre-existing architecture — per-tap closures were equally in-memory and unflushed on kill. The delta under coalescing: a burst is lost ALL-OR-NOTHING (no write yet) instead of as a partial prefix of taps (some intermediate states persisted, the tail lost) — arguably cleaner, and on relaunch both designs show DB truth. A durable intent register (persist-before-acknowledge for flag gestures, ADR-IOS-018-style) would close it and is deliberately out of scope; read/flag/tag gestures have never been persist-before-acknowledge. Pre-existing queue-architecture follow-ups surfaced by the same round live in `PLAN_OVERLAY_CALLSITE_AUDIT.md` §6. **Narrowed (2026-07-10, same-day follow-up):** `AppDelegate`'s `didEnterBackground` durability bracket now drains the write queue (`AccountManager.awaitWriteQueueDrain`, deadline-bounded by `SyncConfig.backgroundWriteQueueFlushTimeoutSeconds`) BEFORE `checkpointForDurability()` — the common backgrounding path commits queued intent cycles and covers them with the WAL fsync (previously the checkpoint could fsync a WAL missing everything still in the queue). A hard kill while foregrounded remains the accepted residual. The race is deliberately NOT `withTaskGroup` (it implicitly awaits children even after `cancelAll()`, so it cannot bound the wait — see the `awaitWriteQueueDrainOrTimeout` doc comment). Tests: `WriteQueueFlushTests`.
- **Agent tools coordinated (2026-07-10, same-day follow-up):** `EmailArchiveTool`/`EmailDeleteTool` no longer call `AccountManager.archive`/`delete` directly with the header snapshot resolved BEFORE the unbounded user-confirmation wait (a stale snapshot could pass the role/path filters and silently relocate a row the user had since moved elsewhere — reversing the more recent intent — while also bypassing the overlay and FIFO ordering entirely). They now go through `AccountManager.performCoordinatedRoleMove(ids:role:)`: same retain→register→enqueueWrite→release lifecycle as gestures, with headers RE-RESOLVED inside the queued closure so the write acts on row truth at execution time; awaits durable completion so the tools' success JSON semantics are unchanged. Regression pin: `CoordinatedToolActionTests` (incl. the stale-snapshot trace and a FIFO/union test behind an open intent cycle).
- Tests: `InboxGestureActionTests` (24) — cancel-out = zero writes/ops, odd-count = exactly one write, consume-then-new-cycle, tag re-tag coalescing + tag-back-to-baseline no-op, mixed toggle+archive both orders (the bypass regression), undo retain hygiene, strand-free refcount/register after every drain; round-1 audit additions: `detailToggleReadCancelOutIsZeroWrites`, `threeFieldsCoalesceInOneCycle`, `sequentialCyclesEachExecuteIndependently` (sequential-cycles pin — the mid-write residual itself has no production pause seam and is deliberately untested; see the deviation note in the test file), `threadBatchRetainsPerMemberAndReleasesPerMember`, `undoMultiMessageReleasesAllRetains`; round-2: `tagOnStagedOnlyRowRunsEnsureDurableAndReleasesGracefully` (strand-hygiene pin only — the test host's merge no-op cannot observe the ensureDurable call); round-3: `markAllAsReadBeforeToggleBurstDoesNotSwallowLatestIntent`, guarded-teardown helper (`restoreTestDB`, mirrors the MessageDetailStagedFallbackTests escaped-Task precedent).

**Addendum (2026-07-10, follow-up-session audit rounds 1–3) — three register-adjacent hardenings:**
- **Undo restores `actionTag` into the overlay AND undo snapshots are overlay-adjusted.** Two stacked staleness bugs: (1) `UndoService.undo()`'s restore mutation set only folder fields, so an archive gesture's overlay tag-clear (`.some(nil)`) survived the merge and hid the restored chip for the whole undo drain window — fixed by registering `actionTag: .some(msg.actionTag)` from the pre-move snapshot (symmetric to isInInbox). (2) The pre-move snapshot ITSELF was a fresh `lookupMessage` DB read, which predates any still-queued intent cycle's isRead/isFlagged/actionTag — an undo could silently revert the user's most recent gesture (never-drop violation). Fixed by `InboxViewModel.overlayAdjustedForUndo`: undo snapshots take those three fields from `snapshotOverlay()` (captured BEFORE the site's own registerMutation, so earlier gestures' targets are picked up but not the archive's own tag-clear); folder fields deliberately stay DB-truth. `MessageDetailViewModel` needed no change (its snapshots come from overlay-current view state — verified). Tests: `undoRestoresActionTagIntoOverlayWhileArchiveClearStillHeld`, `undoAfterArchiveRestoresStillQueuedTagGesture`. **CORRECTION (2026-07-12):** that "no change needed" verification was wrong — `MessageDetailViewModel.archiveMessage`/`deleteMessage`/`moveMessage` pushed `messages: [msg]` (the raw caller-passed header) straight into `UndoableAction`, never calling `overlayAdjustedSnapshot`; the caller-passed `msg` argument is not guaranteed to be a freshly re-read `self.message`/`threadMessages[idx]` (a SwiftUI closure can capture it ahead of a render update), so a still-queued gesture on the same id could be silently reverted by undo exactly like the pre-fix `InboxViewModel` bug. Fixed by adding the same `manager.overlayAdjustedSnapshot(msg)` capture (before `recordMove()`, same ordering constraint) to all three methods. Test: `MessageDetailViewModelMoveTests.archiveMessagePushesOverlayAdjustedSnapshotSurvivingUndo` (mutation-verified: reverting to the raw `msg` turns it red). **Promoted (audit round 4, 2026-07-10):** the body moved to `AccountManager.overlayAdjustedSnapshot(_:)` (`nonisolated`, same logic) so non-`InboxViewModel` producers of `UndoableAction` can share it — `InboxViewModel.overlayAdjustedForUndo` is now a one-line wrapper (all 6 call sites unchanged). First consumer: `SettingsView.archiveOldMessages`, which was pushing a raw `fetchAll` snapshot straight into `UndoService.push` (the same staleness bug, a 7th producer that predated this fix). Test: `AccountManagerActionsTagClearTests.overlayAdjustedSnapshotPicksUpQueuedTagIntent`.
- **The executor's actionTag write is inbox-scoped (DELIBERATE divergence from the isRead/isFlagged assert-latest policy).** `executeIntentCycle` skips the tag write when the resolved row has `isInInbox == false`: tag gestures and move gestures enqueue via separate unstructured Tasks (no cross-Task FIFO ordering guarantee), and the ADR-IOS-036 clear-on-inbox-exit write created a field-level conflict — a tag executor draining after the archive move re-applied the tag to the archived row (stale chip in Archive/Trash lists until the next sweep). Rationale for skipping rather than asserting: `actionTag` is an inbox-scoped FIELD (ADR-IOS-036; both tag-gesture UI entry points are isInInbox-gated, so no legitimate tag intent can target a non-inbox row) — a row that left the inbox by execution time means a move ran after the gesture, and the later action's clear wins, exactly matching serial-replay ordering. This differs from isRead/isFlagged (asserted against any row state) because those fields are valid everywhere; the divergence is about field scope, not a retreat from assert-latest. A remote (non-local) mid-cycle eviction also voids the tag intent — accepted: writing it would produce a state ADR-IOS-036 defines as stale and the next sweep would clear anyway. Test: `tagIntentSkipsReinstateWhenRowLeftInboxBeforeExecution`.
- **Notification actions now participate in the register-adjacent coordination** — see the ADR-IOS-018 "Notification-action revival" paragraph (router dispatches ARCHIVE/DELETE via `performCoordinatedRoleMove`).

**Relates:** ADR-IOS-049 (amendment rounds 8–10), ADR-IOS-055 (overlay consumers), commit `1c5128e`, `PLAN_OVERLAY_CALLSITE_AUDIT.md` (§5 phase-2 move coalescing), PROJECT_MEMORY `project_inbox_flicker_races`.

---

## ADR-IOS-058: The Intention Journal — Dumb Append, Derived Overlay, Fold at Drain (Supersedes the ADR-IOS-057 Register)

> **Partially superseded by ADR-IOS-060 (2026-07-13).** Retained: one synchronous in-memory append API, derived overlay, pure fold, serialized local execution, fresh row resolution, journal-aware background flush, and serial-model testing. Superseded: `.undoRestore`, snapshot/checkpoint restore, durable `undoToken`, annihilation tests that pin row choreography, and the decision to leave durable lanes/splits/retry caps untouched. Undo is an ordinary inverse command with replaceable provider-blind durable reconciliation.

**Date:** 2026-07-11
**Status:** Accepted + audited (core `5c4bc54..d4f7f8c`; adversarial audit 2026-07-11: 14 rounds / 28 lens passes, terminated on two consecutive clean — 12 CONFIRMED defects found+fixed incl. 5 production-HIGH, per-round log in the plan's §10e; final suite 7,759/1,044 green)
**Supersedes:** ADR-IOS-057's enqueue-side `IntentCycle` register, the `overlayOpRefCount` retain/release protocol, `performCoordinatedRoleMove`, and the per-surface hand wiring — NOT ADR-IOS-057's semantics ledger, every entry of which is carried (see Consequences).

**Context.** ADR-IOS-057 put latest-intent coalescing at ENQUEUE time: a per-id register with a generation/atomic-consume protocol, an overlay-entry refcount, a coordination wrapper for tools/notifications, and 10 call sites hand-rolling retain/register/enqueue/release. It was correct (survived 14 audit rounds across two sessions) but wrong-shaped: three of its own audit defects were bugs in its own protocol, and every new surface had to re-implement the wiring. The original philosophy (core philosophy §5; ADR-IOS-018) locates consolidation at DRAIN time. Full design + verified inventory + risk register: `PLAN_INTENTION_QUEUE.md` §9 (local, gitignored).

**Decision.**
1. **One dumb append API.** Every surface — inbox gestures (toggles/tags/move family incl. the batch `markRead(_ messageIds:)` the old inventory undercounted), detail gestures, agent tools, notification actions, settings bulk-archive, undo — calls `AccountManager.record(ids:kind:displays:origin:)` and knows nothing else. Appends are synchronous and totally ordered under one Mutex (`IntentionJournal`), which deletes the unstructured-Task reorder race class between sibling surfaces outright. Tools/notifications use `recordAndWait` — awaiting the receipt is the ONLY tool/finger difference. Records are IN-MEMORY (plan §9c): a durable-per-tap INSERT is forbidden twice over (zero-DB gesture contract; writer starvation makes an awaited tap INSERT the dead-toggle hang again), so crash semantics are exactly the ADR-IOS-057 accepted residual, still narrowed by the didEnterBackground write-queue flush — which is JOURNAL-AWARE since round 8 (the flush loops the FIFO barrier until the intention journal is fully drained, covering a record() whose fold-enqueue Task has not reached the actor yet; a bare barrier missed exactly that window).
2. **The overlay is DERIVED.** `snapshotOverlay()` returns the journal's fold-merge of pending records' per-id `displays` (+ the in-flight hold between consume and write-commit, preserving release-at-completion timing). Entry lifetime = "id has pending or in-flight records" — the refcount machinery has nothing left to count. All 8 consumers (ADR-IOS-055 composer/reader, detail applyOverlay, NavigationStore badge split) are unchanged by interface. `overlayAdjustedSnapshot` is KEPT (deviation from the plan's delete-list): under the derived source its body IS the "capture the visualized state" read undo snapshots need; the call-before-your-own-record() ordering constraint carries over unchanged.
3. **Fold at drain, execute through the existing methods.** The first record for an id enqueues ONE fold closure on the existing FIFO write queue ("drain time" = that closure running — the substrate survives, so the AsyncStream-gate/barrier test determinism technique survives verbatim). The executor consumes the id's connected component (union-find across batch records), folds it pure (`IntentionFold`), resolves row truth ONCE via a THROWING resolve — read-error keeps the records and retries on a `SyncConfig.intentionResolveRetryDelaySeconds` cadence (never drop intention on a read failure); vanished drops with a log. A component with a surviving undo performs a SECOND throwing resolve after phase 1 (the restore re-materializes rows the later phases act on); its read-error handling is deliberately DIFFERENT (round-11): records are already consumed, so instead of reinsert-and-retry the executor reconstructs the header map zero-I/O — non-undo ids keep their first-resolve headers, the undo's ids take their restore payload snapshots with the per-member restored folder stamped — and proceeds, dropping nothing. It then executes net intent by calling the EXISTING `markRead`/`markUnread`/`markFlagged`/`applyManualTag`/`move`/`archive`/`delete`: sibling rfc822 expansion, unread math, atomic local-write+PendingOperation transactions, notifications, and badge recounts are inherited, never reimplemented. The remote `PendingOperation` queue, lanes, splits, and retry caps are UNTOUCHED (remote folding deliberately rejected: serial replay of temporally-separated durable ops is correct; the sync-protection layers — snapshot-inside-txn, recentlyCompleted TTL, fold's assert-vs-row-truth — already guarantee "sync never wins over pending intent", the invariant this ADR names).
4. **Fold semantics are property-pinned against a serial-replay model** (`IntentionFoldTests`, 300 seeded random sequences + deterministic pins). The property harness found FIVE fold defects before any wiring existed: (a) tag writes must gate on the location context AT THE TAG'S SEQ (the then-pending move's destination), not the final destination; (b) a gated-off tag record is a no-op and must not disturb fold state; (c) an intervening inbox-leaving move's F6 clear must survive a later move-back-to-inbox (`actionTagClearedByMove` + the executor's teach-free `clearActionTagLocal`); (d) annihilation is CHECKPOINT/RESTORE of per-id fold state at the paired move (range-clearing loses pre-move intents that serial's snapshot restore preserves); (e) undo pairs nest LIFO by stack discipline — crossing pairs are unrepresentable in production and the fold's precondition documents it.
5. **Undo is hybrid (plan §9h).** `UndoService` stack/toast and `undoDestructiveAction`'s full-row snapshot restore + cancel-or-move-back stay (the upsert can resurrect a drain-deleted row — an inverse intention structurally cannot). `undo()` dispatches ONE `undoRestore` record carrying the `UndoableAction.token`; an undo tapped while its move's records are still pending ANNIHILATES both in the fold — zero writes, zero PendingOperation, zero remote MOVE — and needs no stack invalidation (undo() pops before dispatch; §9h's pop-entry mechanism proved unnecessary). An undo of an executed move survives the fold and runs the restore through `undoDestructiveAction`, ordered by the same FIFO (that function itself was hardened by audit rounds 2–5: per-member restore folders, per-MEMBER cancellation/move-back scoping (round-3 shipped per-group; round-4 refined to per-member for batch-split remnants), and — round-5 — the cancellation MATCH itself is now GESTURE-LINEAGE-scoped via a `PendingOperation.undoToken` column (v68 migration), not bare OperationType+id overlap: the prior match could cancel an EARLIER, unrelated gesture's still-queued op sharing the same type and message id (archive A, then delete A, then undo the delete wrongly cancelled the archive too) — pre-existing cross-folder-batch and cross-gesture defects, see the plan's §10e log).

**Behavior refinements (deliberate, recorded):** batch `markRead` on-screen ids now skip-if-row-already-reflects instead of writing unconditionally (assert-latest; fewer redundant remote ops); off-screen batch ids get overlay coverage from gesture time; `SettingsView.archiveOldMessages` gains overlay coverage + FIFO ordering it never had; a toggle + move on one id folds into ONE executor (flag-op PendingOperations still precede the move op in creation order; lanes serialize remotely); tools/notifications joining an open component execute with it.

**What stays OUTSIDE the journal (plan §9i):** `markAllAsRead` and manager-level batch `markRead(_ messages:)` (direct FIFO closures; one-direction idempotent; the fold's row-truth assert corrects them — invariant 3), `AccountManagerAI`'s three direct tag writes (background AI, not user intention), demo mode (no queue interaction), `loadBody`'s `processOpenedMessage` FIFO use (ordering, not intention).

**Deleted:** `IntentCycle` + `pendingIntentCycles` + `executeIntentCycle` + generation/atomic-consume protocol; `optimisticOverlay` + `registerMutation` + `removeOverlayEntries`; `overlayOpRefCount` + retain/release + all per-site wiring (10 sites); `performCoordinatedRoleMove`; `enqueueMove`; the transition dual-write shim. `registerGestureIntent` survives as a thin `record()` adapter (8 call sites).

**Accepted residuals:** in-memory records (crash window unchanged from ADR-IOS-057, narrowed by the bg flush); the E2E fuzz harness's `.overlayDrain` step now clears the whole journal rather than one id (test-only coarsening, flagged to audit); a same-component undo executing before later out-of-band writers is bounded by the same serial-replay-parity arguments as the fold rules (property-pinned); under move↔undo annihilation, a tool/notification record folded into the annihilated component still resumes its awaited receipt as success — intent is processed to its net outcome (most-recent-wins), matching serial replay's final state (round-2 audit). **Round-6 (fixes the round-5 addendum below):** the round-5 addendum's premise — that drain batch-split remnants and tool/notification role moves legitimately stay `undoToken == nil` — was itself the bug: a tool op sharing its destination with a later, unrelated user undo got wrongly cancelled by the destination-narrowed legacy fallback (CONFIRMED HIGH; trace in `undoDestructiveAction`'s cancellation comment and `PLAN_INTENTION_QUEUE.md` §10e round 6). Fixed by making EVERY post-v68 `.move` op-creation site stamp a non-nil `undoToken` — gesture sites use their own `UndoableAction.token` (unchanged); tokenless surfaces (`recordRoleMove`, the cold notification-router path, drain batch-split remnants, undo's own move-back insert) stamp a FRESH, NEVER-REFERENCED `UUID()`, which is inert for the exact-lineage match (no `UndoableAction` ever carries it) and, being non-nil, excluded from the legacy fallback too. The destination-narrowed legacy fallback is therefore now reserved STRICTLY for pre-v68 rows (upgrade-transient) — narrower than round-5 believed. The tokenless UID-collision member match-back residual (round-5 Lens A) is narrowed correspondingly: it can now only ever be reached by a genuinely pre-v68 row.

**Tests:** `IntentionFoldTests` (property + pins), `IntentionJournalTests` (append order/coverage/consume/derived overlay/receipts/reinsertion), three new annihilation pins (`undoWhileMovePendingAnnihilatesToZeroWrites`, `undoAfterMoveExecutedRunsRestoreExactlyAsToday`, `undoRestoresStillPendingTagGestureViaAnnihilationWindow`), the carried ADR-IOS-057 regression suite re-targeted to journal seams (`recordsForTesting`/`isFullyDrainedForTesting`/`seedDisplayForTesting`/`resetForTesting`), and a REPRODUCED escaped-write test-pollution fix (synchronous gesture tests must drain the FIFO before returning — `InboxViewModelDiffTests`, 4/4 repro → 4/4 clean).

**Cross-account thread gestures (test-review round 17, CONFIRMED production defect — pre-existing, fixed 2026-07-11).** A thread group can span ACCOUNTS: `ThreadGroupBuilder` groups by bare `computedThreadId` with no account partition, and `ThreadUtils.findAdoptableThreadId` probes rfc822/inReplyTo/references with **no `accountId` filter**, so the same message delivered to two of the user's accounts adopts one `computedThreadId`. `archiveThread`/`deleteThread`/`moveThread` resolved the destination from `first.accountId` ONLY and stamped that single path on every member — account B's message got `folderId = "B:<A's archive path>"` (no folder backs it → the row vanishes from B's views) and a `PendingOperation` whose `destinationPath` is meaningless to B's provider (the server-side archive/delete **never happens**). This is the exact defect class `moveToRoleFolderPerAccount` already fixed for tools/notifications in the main audit's round 6 — the gesture *thread* sites were simply never migrated. Fix: `archiveThread`/`deleteThread` now record `.move(.role(.archive/.trash), undoToken:)` so the executor's existing `.role` branch resolves the role folder PER ACCOUNT (`archive()`/`delete()` → `moveToRoleFolderPerAccount`), with per-member displays carrying each member's own account path and members whose account lacks the role folder excluded (mirroring that function's skip); `moveThread`'s destination is a single explicit folder of ONE account (the picker is per-account) and a cross-account IMAP move is impossible, so it now scopes the gesture to the destination account and skips foreign-account members with a gated log. The undo path had the same account-blindness (batch-wide `accountId` drove the cancellation query, the restore `folderId`, unread counts, the move-back op's account/provider), so `undoDestructiveAction` now groups `messages` by `msg.accountId` and runs its (unchanged) per-account body per group — every rounds-2-6 property (per-member restore, per-MEMBER cancellation, per-restore-group move-back, lineage matching) preserved; signature and `IntentionUndoPayload` unchanged. Pinned by three real-path tests (per-account landing; per-account undo restore + move-back; cross-account annihilation while pending), the first of which was written **red first** against the old code as proof.

**Relates:** ADR-IOS-018 (queue philosophy; untouched remote machinery), ADR-IOS-036 (F6 tag scope — now fold+executor two-layer), ADR-IOS-055 (overlay consumers), ADR-IOS-057 (superseded register; semantics carried), `PLAN_INTENTION_QUEUE.md` §9–§10.

---

## ADR-IOS-059: A Folder Role Is Never Identity — Undo Resolves by a Recorded Tuple and Drops on Any Mismatch

> **Superseded by ADR-IOS-060 (2026-07-13).** The general lesson that mutable attributes are not identity remains valid. The recorded-destination resolver, token ledger, provider receipt identities, alias advancement, full-row restoration, and mismatch adjudication are rejected. Undo no longer resolves a historical row or owns a second recovery protocol; it issues an ordinary inverse command through the global queue.

**Status:** Accepted (2026-07-12) — supersedes the undo-resolution machinery accreted in ADR-IOS-058's audit rounds 23-50.

### Context

Undo had to answer one question — *which durable row does this undo entry restore?* — under two facts:

- **IMAP re-keys rows.** `messageHeader.id` is `accountId:folderPath:messageId`, and on IMAP `messageId` is the UID, which a MOVE changes. Sync deletes the stale row and re-inserts it under a new id. So the composite id is a birth certificate, not an address, and it goes stale the moment our own move syncs.
- **Folder metadata drifts.** Settings can retag any folder's role (`AccountDetailView.assignRole` is a raw `UPDATE folder SET role`), sync re-derives roles, drops folders that vanish remotely, and renames change a folder's path.

The implementation answered it by **scoping a probe by folder role** — "find the row with this rfc822 id, in this account's archive-role folder" — and then spent ~30 commits patching the consequences: the probe was re-scoped four times (each adding one more qualifier), the captured-vs-live role precedence was reversed three times, and a "last-resort" probe was reinstated and then deleted again after it was shown to resurrect deliberately-deleted mail. `AccountManagerActions.swift` grew from 1,239 to 2,269 lines.

Every one of those bugs was real. None of them was the bug. **The bug was using a mutable, per-account, user-editable attribute as part of an identity key.** Role can be reassigned between the gesture and the undo; a key that can be edited by the user is not a key. This is the same error ADR-IOS-042 forbids for sync (window by UID, never by the mutable `date`) and the same one the MOVE-changes-UIDs rule forbids for message identity.

### Decision

**An undo entry records, at gesture time, what it did. At undo time, it resolves only what it recorded. Role is never read at undo time — not for probes, not for scoping, not for guards, not for tie-breaks.**

Concretely, the undo entry carries, per account, the folder the gesture moved that account's messages into (`UndoableAction.destinationPathByAccount`). Gesture sites seed the intended paths synchronously; `AccountManagerActions.move` overwrites them after its GRDB transaction with the paths the write actually used. A token-keyed `UndoService` ledger survives the action being popped until the undo journal receipt completes, so a move finishing in the pop→undo-fold window cannot lose its actual destination. Resolution is then one lookup and one comparison, per member:

```
identityKey := rfc822MessageId            (providers whose ids re-key: IMAP/iCloud)
            := messageId                  (provider whose ids are stable: Gmail)
            := receipt-proven id component (Outlook Graph default REST ids re-key)
            := NONE                       (re-keying provider, no Message-ID header)

row := the single row with (accountId, identityKey) whose folderId == the RECORDED destination folder

  exactly one such row  -> RESTORE it (location + user state from the snapshot),
                           move-back sources from the recorded destination
  anything else         -> DROP the member and report it refused
```

"Anything else" is every case the deleted machinery tried to adjudicate, and it needs no adjudication:

- **The row moved on** (another client re-filed or deleted it, a later gesture superseded it): its `folderId` is not the recorded destination, so it is not ours any more. Drop. This single comparison replaces the SUPERSEDED guard, the UNKNOWN-LOCATION guards, the opposite-role probe, and the sent/drafts exclusion lists — and it cannot resurrect deliberately-deleted mail, because a row in Trash is by definition not at our recorded destination.
- **The row is gone** (hard-deleted): zero candidates. Drop. We never fabricate a row we cannot identify; the old upsert-under-old-id path did exactly that and produced phantom duplicates.
- **The member has no identity** (IMAP message with no `Message-ID` header — a SHOULD, not a MUST, in RFC 5322): no key exists, so nothing can honestly be resolved. Drop.
- **Ambiguity** (the same rfc822 id in several folders — a self-sent message's Inbox and Sent copies): only the row *at the recorded destination* is ours. The Sent sibling is excluded because its folder is not the destination, not because we reasoned about its role.

A re-keyed row is found because the identity key survives a re-key; that is the entire point of keying on it. The undo restores it **in place, under its new id**, and re-posts `.messagesUndone` with the id it actually lives under.

**Audit amendment (2026-07-12, round 52).** Five details are part of this decision, not optional fallbacks:

1. **Choose the key from the provider first.** Gmail resolves by its stable `messageId`, even when the snapshot also has an RFC Message-ID. Outlook resolves only through the exact provider-id component proved by Graph MOVE receipts; it never falls back to RFC identity. RFC-first resolution can select a different same-RFC copy sitting at the destination. IMAP/iCloud use RFC Message-ID because their UIDs re-key and provide no replacement UID receipt.
2. **The committed destination receipt outlives stack membership.** A value-type action is popped before the original move's asynchronous post-commit stamp can run. Phase 1 reads the token ledger immediately before resolution; successful execution-time stamps override gesture-time provisional paths. The ledger entry is removed only after `IntentionJournal.awaitCompletion` for the undo record (or when an unpopped action is evicted/dismissed).
3. **A re-key is carried forward by the exact restored row.** `undoDestructiveAction` returns `[snapshotId: restored MessageHeader]` from the same unique-row transaction. `executeFold` refreshes by each row's actual current id, then indexes it under the old fold id for later co-bundled field/move intentions. The read-error fallback uses that exact returned row too. It never performs a broad RFC fallback, and refused members produce no alias.
4. **Resolution is bijective, not merely unique on the database side.** Exactly one destination row may match one snapshot, and exactly one snapshot in the undo group may carry that immutable key. If two snapshots share one provider identity, every such member is refused even when only one destination row survives; otherwise both snapshots can claim the same row and restore it twice with order-dependent user state.
5. **Every historical alias observes the latest restored state.** Successive IMAP moves can make several old fold ids name one current row. `executeFold` therefore tracks old-id → actual-id separately from the latest restored header per actual id. If refresh fails after multiple undos in one component, all aliases resolve to the row's final serially-restored state, never an intermediate Archive/Trash snapshot that can incorrectly gate a later field or move intention.

**Audit amendment (2026-07-13, round 53).** Microsoft Graph's default REST message id changes on MOVE. Each exact receipt advances the token ledger's provider-id component before the matching GRDB re-key, and the undo resolver snapshots that ledger from inside its serialized write. A cycle or collision between previously distinct components marks that token/account's alias history explicitly invalid; the resolver refuses every member in that account. An empty alias map is not a corruption marker and must never trigger fallback to the captured old id after contradictory receipt evidence.

### Consequences

**Deleted:** `resolveRoleScopedRekeyedRow`, `resolveRelocatedRow`, `scopedRole`, `capturedDestructiveRole`, `effectiveRole`, `UndoableAction.destinationRole` (and its payload field), `supersedingRoles`, `destinationFallback`, the SUPERSEDED / UNKNOWN-LOCATION / UNKNOWN-LOCATION-rekeyed / REKEY+SUPERSEDE guards, the per-member exclusion sets, the representative-account path borrowing, the upsert-under-old-id restore, and the bespoke unread delta arithmetic (the undo now recomputes each touched folder's count from truth inside the same transaction, so there is no delta to get wrong and no exclusion set to keep in sync).

**Behaviour we deliberately gave up** — each is now a drop, and each was previously a guess:

1. A message another client re-filed to a custom folder is no longer dragged back. It is not where we put it; the last actor to touch it was not us.
2. A hard-deleted row is no longer re-fabricated from the snapshot.
3. A folder renamed between gesture and undo makes the recorded destination stop matching (`Folder.id` is path-derived), so those members drop. Refusing is honest; guessing is what produced the bugs.

In all three the user sees the undo decline to act rather than silently do the wrong thing, and the refused ids drive a corrective reload so the UI never shows a row that does not exist.

**Follow-up (not done here):** `Folder.id = "\(accountId):\(path)"` makes a folder's identity path-derived, which is the same class of error one level down — a rename is indistinguishable from a different folder. Giving `Folder` a server-derived stable id would let a rename survive an undo. Recorded as a known limitation; not required by this ADR.

### The rule this generalises

> **Identity keys must be immutable. If an attribute can be edited, re-derived, or reassigned — a role, a path, a date, a UID — it is a display attribute, not a key. Never scope a lookup by one.**

If a future change finds itself adding *one more qualifier* to an undo lookup to make a case pass, that is this ADR's failure mode. Stop and re-read it.

---

## ADR-IOS-060: Durable Message Actions Are One Dumb Global FIFO

**Status:** Accepted (2026-07-13). Supersedes the queue/Undo mechanics identified above in ADR-IOS-018, ADR-IOS-058, and ADR-IOS-059; amends ADR-IOS-026B with universal RFC Message-ID operation identity.

### Context

The intention-journal work began as a test-coverage and GRDB-write reduction effort. The in-memory journal succeeded at that goal, but durable Undo retained a hybrid “cancel if queued, otherwise restore/move back” protocol. Tests then exposed real races in that protocol. Successive fixes added member-level cancellation, durable lineage tokens, recorded destinations, provider receipts, Graph alias/recovery handles, dependent-job rewrites, queue-owned GRDB/FTS recovery, and provider-specific branches. `AccountManagerQueue.swift` grew from roughly 965 committed lines to roughly 2,622 in the Round 53 working tree.

The root error was architectural: a generic action queue became responsible for Undo identity and provider recovery. The queue should carry ordinary account/folder/message commands in order. Provider peculiarities belong below the `EmailProvider` boundary, and Undo should be evaluated by its final serial effect rather than by preserving one internal cancellation formula.

### Decision

1. **One global queue, one job at a time.** The durable message-action queue is a single global insertion-order FIFO. Each job embeds its account and ordinary command data. There are no per-account drains, connected-component lanes, or parallel message-action execution. A transient failure blocks all later jobs until the frontier can retry. This deliberate throughput trade-off keeps execution and reasoning serial.

2. **One shared mutation gate and one protected frontier.** Durable append, bounded Undo reconciliation, drain claim, drain completion/requeue, and startup reconciliation coordinate through one cancellation-safe max-one async gate. The first active job in insertion order is never touched by Undo, even if its persisted status still says `queued`, because drain may already be claiming it. Exactly one drain owner exists, and provider/network I/O never runs while the gate is held. Gate release is guaranteed on every success, error, cancellation, and early-return path.

3. **The durable executor is a dumb pipe.** A persisted semantic payload is never rewritten, split, re-parented, merged with another payload, advanced through provider aliases, or interpreted through Undo identity. The executor claims the first job, calls the generic provider operation, deletes on applied/authoritative-no-op completion, and restores the unchanged job to `queued` on transient failure. Crash recovery may reset abandoned `inFlight` lifecycle state before a live drainer exists.

4. **General coalescing exists only in memory.** The `IntentionJournal` may fold rapid actions before GRDB/durable output to reduce database and provider work. Once ordinary work is durable, there is no background compactor or drain-time latest-intent register. The sole admission-time exception is bounded Undo reconciliation under the mutation gate: safely queued work behind the protected frontier may be removed or replaced when doing so preserves the same final state as serial action-then-Undo execution.

5. **Undo is an ordinary inverse command, not a recovery protocol.** Undo stores only enough generic command data to issue the inverse and render its UI. No `.undoRestore`, full-row resurrection, durable `undoToken`, provider receipt, destination ledger, alias graph, recovery handle, or provider-specific matcher participates. Reversible move/archive/delete-to-trash operations invert source and destination; idempotent read/flag/remote-label operations invert their desired state. Permanent deletion remains non-undoable.

6. **The exact durable Undo formula is replaceable.** Every formula must hold the mutation gate, leave the protected first job untouched, remain provider-blind, avoid persisted-payload mutation/partial batch rewriting, and produce the serially correct final state. ADR-IOS-060 deliberately does not specify newest-related scanning, `flipped()` equality, or move-delete versus setter-replace choreography. Those are implementation choices recorded in `PLAN_INTENTION_QUEUE_AUDIT_V2.md` and may change without an ADR revision.

7. **Stale is terminal; uncertainty retries.** A locally vanished/ambiguous target drops before durable output. At execution, a successful authoritative provider lookup showing missing source membership, a missing message/folder, or a non-unique target unsafe to mutate returns normally as a no-op and the job leaves the queue. Transport/auth/throttle/timeout or a failed/incomplete lookup throws and retains the unchanged frontier for retry. No retry budget converts uncertainty into absence.

8. **Provider peculiarities stop at `EmailProvider`.** The queue sees normalized RFC Message-ID members and generic account/folder/message operations. Gmail ID/label resolution, Graph `internetMessageId` to current resource-ID resolution, IMAP UID resolution, and provider-specific stale classification remain inside adapters. The queue contains no concrete-provider casts, receipts, aliases, destination probes, header/body re-keying, or FTS recovery.

9. **Universal RFC operation identity is the prerequisite.** Before generic queue/Undo simplification proceeds, every Gmail, Exchange, and IMAP durable message-action admission path must require normalized RFC Message-ID and every adapter must resolve it authoritatively inside the recorded source scope. Local RFC presence/syntax validation precedes optimistic mutation, so refused members are not changed locally; authoritative exact-one provider resolution remains deferred to drain. Provider resource IDs are transient execution details. Missing/non-unique resolution no-ops and ordinary sync reconciles optimistic state to provider truth; failed lookup retries. There is no provider-ID fallback, Graph immutable-ID migration, move receipt, runtime alias ledger, or permanent dual-format executor. Released provider-ID rows are converted once before the new drain starts. The finite conversion passes recorded source and optional optimistic destination separately: Gmail and account-scoped Graph IDs may be corroborated in either, but a mailbox-scoped legacy IMAP UID is exact-FETCHed only in the source because the same numeric destination UID can identify another message. The IMAP cutover terminally omits noncanonical/out-of-range UID encodings and exact source members that cannot supply a valid RFC Message-ID; failed SELECT/FETCH or contradictory correlation throws. Unsupported provider conversion throws. This cutover reuses existing exact header indexes and adds no schema, token, or new durable migration state.

10. **Undo queue tests are black-box end-to-end tests.** Tests drive public action and `UndoService` entry points through the real journal, local GRDB transaction, durable queue, drain, and deterministic stateful provider doubles. They assert final local/provider state, overlay clearance, unrelated-action preservation, and queue idle. They do not assert durable row counts, which row was removed/replaced, candidate selection, `flipped()` output, temporary inverse rows, cancellation status, or private call order. Changing one correct formula to another must not require test changes. Narrow low-level tests may cover the generic gate, single-drainer ownership, insertion-order FIFO, and startup recovery only.

11. **Audit convergence is historical and explicit.** The inherited Round 53 working tree is first committed as an explicitly rejected recovery checkpoint together with this ADR and the V2 plan, establishing a clean audit trail. Every subsequent implementation/audit round starts and ends clean, has its own signed DCO commit, and is not squashed until convergence. Completion requires two consecutive independent clean audit rounds.

### Scope

This ADR governs the durable message-action `PendingOperation` queue. `OutboxMessage` send reliability remains governed by ADR-IOS-019 and is not merged into this queue. Calendar persistence remains separate. If a draft-related operation is represented as a `PendingOperation`, it obeys this FIFO but is not made undoable by this ADR.

### Consequences

- One offline or throttled account can block later actions for other accounts. This is accepted; cross-account parallelism is intentionally rejected as unnecessary complexity.
- Universal source-scoped RFC resolution must be solved before queue simplification; provider-ID churn is never compensated for with queue-visible recovery after MOVE.
- Runtime ownership and the fresh-schema migration of unreleased v68 `undoToken` are removed; the installed-and-needed schema boundary is `07a4bb7`/v67, and older migrations are out of scope. V69's queue-only `queueParentRowId` state is removed with batch splitting. Its independently live ordinary-sync `pendingFTSRekeySourceIdsJSON` crash journal remains because it closes the GRDB-to-FTS interruption gap and is not queue receipt state; its partial index is keyed by `id` so the id-ordered recovery cursor probes only marked rows. Legacy email `cancelled` rows may be cleaned at startup, but new email code never creates them.
- Existing tests that pin token/cancellation/receipt choreography are rewritten around final serial outcomes or deleted.
- Sync may retain only the smallest provider-agnostic pending/recent-completion shield proven by real-path tests; it does not become an execution receipt ledger.
- The initial matching formula can evolve freely behind the ADR invariants and end-to-end suite.

**B3 implementation checkpoint (2026-07-14).** The finite released-row converter performs provider-assisted resolution outside GRDB, then one guarded transaction raw-updates only member identity JSON or deletes an all-stale row. It revalidates the full active legacy row set, semantic payload, account provider, and local header evidence after provider awaits; any uncertainty or concurrent change leaves every convertible row unchanged. It preserves rowid/FIFO and the inert physical v67 field, excludes dead/no-op/draft/local-only types, reuses the v64 exact header index, and adds no schema or permanent dual executor. Every message execution entry is gated by one process-local preparation flight bound to the exact active `AppDatabase`: conversion runs first, crash recovery second, and no drain owner, claim, or provider action exists until both succeed. Uncertainty blocks all message work but not independent Outbox/calendar reconciliation. Database-instance readiness/handoff and caller cancellation are fail-closed; an authorized drain keeps the prepared database frozen through its full DB lifecycle and draft persistence even if the process-global database changes. The queue has no post-drain sync tail; ordinary sync independently owns provider-ID re-key and local reconciliation. One structured owner stays active across requested re-drains and retries the newest database when an awaited replacement preparation becomes obsolete, preventing rapid replacement from clearing the newest trigger. Recovery resets abandoned `inFlight` rows and deletes legacy email cancelled/no-op rows with debug-gated counts. The production-path gate suite covers concurrent callers, cancellation before ownership, restart, sequential/overlapping/rapid/post-authorization database replacement, draft-await replacement, whole-queue blocking, provider exclusion, quiescence, and independent recovery. No schema, index, token, or persistent cutover state was added. B3 is complete; B4 stateful end-to-end identity coverage remains before the global-FIFO cut.

**B4 remote-label implementation checkpoint (2026-07-14; complete).** Remote user-label reconciliation remains outside the generic queue's provider identity logic. The provider DTO carries label IDs and a separate authority bit; sync may delete a local membership only when the provider explicitly supplies an authoritative complete set. IMAP keyword state is authoritative. Gmail first builds a generation-ordered actor-local catalog of non-system user-label IDs and preserves create/find discoveries across concurrent listings; before that catalog exists, parsing is deliberately non-authoritative. Full sync applies exact-set reconciliation after every canonical row/re-key/reclaim path and retains the existing pending/recent/push shield for newer local intent. Provider label identity is `(accountId, providerLabelId)` at rest and in every read-model boundary: v71 rebuilds the existing parent/junction tables with a composite parent key/FK, replaces the scalar reverse index with one composite reverse index, and preserves the message-led junction PK. Legacy collision damage is recovered without copying another account's metadata; the missing account receives only a raw-ID/non-system placeholder until authoritative provider sync. Unified filtering, selected-chip resolution, cross-account thread union, and label-action admission all retain account scope. End-to-end Gmail/IMAP tests cover add, remove, authoritative ambiguous no-op convergence, collision migration, account deletion isolation, and cross-account final read-model outcomes without pinning queue choreography. Remote-label user admission is governed by one exhaustive provider capability: Gmail/IMAP/iCloud are supported, while Outlook/CalDAV are rejected before optimistic UI, local junction, visible read-model, or durable queue mutation. UI optimism is guarded and the fresh account capability is rechecked inside each GRDB mutation transaction; creation uses an exhaustive provider switch. The generic queue remains provider-neutral. With this boundary verified through final-state tests and the full warning-free suite, B4 and Round B are complete; Round C's global FIFO/shared-gate cut is next.

**Round C mutation-gate checkpoint (2026-07-14; this commit).** `PendingOperationMutationGate` is the one process-local, max-one permit that later Round C checkpoints use for every bounded durable message-action selection or GRDB mutation. Its `Mutex` state carries an in-memory owner UUID plus FIFO continuation waiters; these UUIDs are synchronization bookkeeping only and never enter persistence, identity, or Undo. Acquisition removes a queued cancellation synchronously. If cancellation races after ownership transfer but before continuation resumption, it reclaims that exact owner and hands the permit to the next waiter before throwing. Acquisition returns an opaque in-memory lease, and synchronous release accepts only that exact lease, so a stale or duplicated release cannot free a successor's permit. Every callsite installs release in `defer` immediately. The API deliberately exposes acquire/lease-release instead of an unrestricted async-body wrapper: provider I/O, callbacks, sleeps, and retry delays must remain structurally outside the permit. Eight primitive tests cover FIFO exclusion, queued cancellation, pre-cancelled acquisition, deterministic cancellation at the handoff boundary with and without a successor, stale-lease rejection, cancellation after entry, and throwing-callsite release. The global drain and durable writers are not yet switched in this checkpoint; that wiring remains the next Round C work.

**Round C global-FIFO checkpoint (2026-07-14; this commit; decisions 1–3 now live).** Message actions execute as one global, one-job-at-a-time FIFO. Connected-component lanes, the parallel per-lane task fan-out, the multi-pass drain, lane halting, and batch splitting are deleted. Durable order is SQLite insertion order (`rowid`); wall-clock `createdAt` no longer participates in any queue ordering, so a clock rollback cannot reorder work. The claim selects the first active row under one gate acquisition and one bounded transaction, physically deleting legacy `cancelled` rows as it walks, and it neither steals nor skips an `inFlight` frontier. A frontier whose account has no registered provider is returned to `queued` and stops the drain instead of being skipped: account removal already purges that account's rows, so this blocks only on a not-yet-connected provider, and per-account failure isolation is deliberately given up for the single serial model of decision 1. A transient failure requeues the unchanged payload and stops the drain; a batch is retried whole and never split; `retryCount` is diagnostics only and never a drop policy. Provider I/O and retry backoff are structurally outside the permit. **Terminal durable writes are cancellation-immune by construction:** the gate's `acquire()` throws the instant its caller is cancelled, so a drain cancelled while completing its claimed frontier would strand that row `inFlight`, and because decision 2's protected frontier refuses to steal or skip such a row while crash recovery only runs once per database instance, one stranded row would wedge the entire FIFO until the next process start. The gated write helper therefore runs its attempts on a detached task, re-binding `PriorityGate`'s write-tier task-locals so detaching cannot silently re-tier a queue write. All fifteen durable append sites — gestures, moves, setters, Undo's inverse, drafts, outbox replied/forwarded, remote user labels, cold notification actions, and the released-row converter's closing compare-and-swap — now commit their local optimistic mutation and their durable insert in one gated transaction, making local state, queue state, and the drain frontier a single linearizable sequence. The helper is `nonisolated` because `AccountManager` being an actor does not by itself supply this exclusion: its methods are reentrant across awaited GRDB calls. Terminal provider-error classification and the queue-owned confirmed-gone header delete are deliberately unchanged here; they move below the `EmailProvider` boundary in Round E and are removed in Round F. Decisions 5–6 are NOT yet live: Undo still uses the pre-V2 durable token/status-cancellation formula, which Round D replaces.

**Queue-liveness amendment to decision 2 (2026-07-14).** The protected frontier means a row stranded `inFlight` by a departed owner blocks the whole FIFO, so the abandoned-row reset of decision 3 is generalized from process start to **ownership** start. This preserves §9.4's stated precondition exactly — "before any drain owner or provider call can exist" — because exactly one drain owner exists at a time (a second caller becomes a re-drain signal, never a second claimant) and a departed owner can have no outstanding provider call or unlanded terminal write. Any `inFlight` row observed as a new ownership begins is therefore provably abandoned, and resetting it is not stealing. The NSE never touches `PendingOperation`, so this invariant holds across processes. The rule to keep in mind: **a blocked queue must still be a live queue.** Head-of-line blocking on an unresolved frontier is intended (decision 1); a leaked permit, leaked owner, leaked claim, or unrecoverable `inFlight` row is not, and every one of those is now pinned by a liveness suite that also proves a fresh op still drains. The accepted cost of decision 1 is that a persistently failing or unregistered provider blocks other accounts' actions; the old per-account failure isolation is deliberately given up, and must not be reintroduced as lanes without a new ADR.

**Round D Undo checkpoint (2026-07-14; this commit; decisions 4–6 now live).** Undo is an ordinary inverse command issued through the same journal/fold/gated-admission path as every other gesture. The undo entry carries per-account generic command data only (normalized RFC members, per-member source folder, forward destination, plus a UI-local pre-move id used solely to un-dismiss the hidden row); the full-row snapshot, durable `undoToken` (runtime property and all writers — the released-schema-compatible v68 column stays inert until Round F), `.undoRestore`/`IntentionUndoPayload`, fold checkpoints, the second post-undo resolve, the destination receipt ledger, and email production of `PendingStatus.cancelled` are deleted. The initial replaceable formula (decision 6) is `reconcileUndoAdmission`: inside the same gated transaction as the local inverse mutation, exclude the protected first row, scan newest→oldest, stop at the first related row, and physically delete only a still-queued exact whole-flip match — a move appends nothing, a setter re-appends the inverse, everything else appends the ordinary inverse. Local resolution accepts a member only at its two serial-intent locations (forward destination after the fold, or its own source before it); anywhere else is a stale drop, pinning the §19 rule that undo never drags a message back from an unrelated folder. The token's original raison d'être — undoing a delete that followed an archive must not cancel the archive — is now guaranteed structurally by the newest-related stop rule and pinned red/green by an end-to-end final-state test. Tag behavior needs no undo handling at all: Round D-0 retains tags across moves, so the inverse move re-reveals them.

**Round F schema checkpoint (2026-07-14; this commit).** The two unreleased post-v67 migrations are trimmed to match the runtime model deletions Round D/E already made. `v68_addUndoToken`'s body is now empty — a fresh database never creates the `undoToken` column at all — and `v69_addMoveRecoveryAndFTSRekey` no longer adds `queueParentRowId`; both identifiers stay registered under their original names and are never renamed, removed, or replaced with a corrective migration, because GRDB's `DatabaseMigrator` tracks completion purely by identifier string in `grdb_migrations` and never re-runs an applied identifier's body regardless of body content (`unappliedExecutions` maps an applied, non-merged identifier to `nil`; verified against `DatabaseMigrator.swift` and pinned by a new upgrade-compatibility test that forges the old pre-Round-F schema, marks both identifiers applied, and migrates to head). A development database that already ran the old bodies keeps both inert nullable columns forever, exactly as §12 anticipates — GRDB's synthesized `Decodable` init for `PendingOperation` only queries the columns the struct still declares, so those two extra columns are silently ignored on decode, and `save()`/`insert()` never reference or null them out. v69's independently live `pendingFTSRekeySourceIdsJSON` crash-journal column and its sparse `messageHeader_pendingFTSRekeys` index are untouched. `PendingOperation.queueParentRowId` (runtime property, its `init` assignment, and its doc comment) and the `queueParentRowId` compare-and-swap term in `AccountManagerLegacyIdentityConversion.sameStoredOperation` are deleted; a released-row-conversion test that pinned the now-deleted field (`operation.queueParentRowId = 777` / the matching before/after assertion) is updated. A repo-wide grep confirms `undoToken`/`queueParentRowId` survive only in the two migrations' doc comments. Clean `build-for-testing` is warning-free; the migration, legacy-conversion, and queue-drain/liveness/model test suites are green (134 focused tests).

**Hybrid-identity amendment to decision 9 (2026-07-14; PLAN_IDENTITY_HYBRID; this commit).** Decision 9's universal-RFC admission is amended to **RFC-first hybrid**: its "refuse identity-less members" clause and its finite released-row conversion are superseded and deleted. One shared shape predicate, `MessageIdentity.durableMemberKind`, classifies every durable member string at every consumer (admission, adapters, undo-entry construction, notification router): a string that passes `durableActionRFC822MessageId` is an **RFC member** (normalized, resolved by source-scoped search — today's path, unchanged); anything else non-empty is a **token member** — the raw provider ID (Gmail ID / Graph ID / IMAP UID), preserved byte-exact and resolved by exact provider-ID fetch plus source-membership verification. Collision safety: a valid RFC ID contains exactly one `@`; provider shapes never do, and a malformed with-`@` string classifies as a token whose exact lookup can only zero-match — an authoritative no-op, never a wrong-message mutation. Admission never refuses a message with a provider ID: producers fall back from a non-normalizing `rfc822MessageId` to `header.messageId`, the optimistic local mutation proceeds, and mixed batches classify per member. IMAP token members are mailbox-scoped by the row's recorded `folderPath`; sibling (rfc822) expansion never applies to tokens. Undo carries `UndoMember.memberIdentity` (either shape); its resolution and `flipped()`/reconciliation matching are identity-agnostic string comparisons, with a token tier-2 fallback of `messageId == token` in the forward-destination scope under the same location guards. Sync protection is permanently two-key: queued members and recently-completed keys are matched against both the header's provider `messageId` and its normalized RFC identity (`containsAnyKey` / `identityIds` seams). The cold notification path admits the transport ID as a token member on a full local miss instead of refusing. **Owner-accepted degraded-tail semantics (= or > released behavior):** Exchange-tail undo after resource-ID churn is a stale no-op; IMAP-tail undo after a completed move is a stale no-op (the UID changed); IMAP-tail moves skip the rfc822 destination probe/post-verify (no cross-mailbox identity). Undo-before-drain still annihilates in memory or via exact queue-row reconciliation for all shapes. **Deletions:** `AccountManagerLegacyIdentityConversion.swift`, the `preparePendingQueueForExecution` conversion step (the flight keeps crash recovery + legacy row cleanup + database binding), the `resolveLegacyMessageActionIdentity` protocol requirement and all provider implementations (generalized into each adapter's private `resolveTokenMember` on the normal action path, source scope only — B3's destination corroboration existed for conversion, not execution), `LegacyMessageActionIdentityResolution`, the converter's Batch-A timeout, and its test suite. Released ≤1.6.38 bare provider-ID rows are, by construction, tail members and execute through the token path with no pre-drain conversion, no startup gate, and no wedge window. The §18-equivalent forbidden-symbol sweep gains `resolveLegacyMessageActionIdentity`, `LegacyMessageActionIdentityResolution`, and `convertReleasedMessageActionIdentities` (none may exist in production). Decision 9's stop signs remain binding: no receipts, aliases, recovery handles, or durable lineage for tail members; no provider casts in the generic queue; a token member never upgrades in place (payload immutability — a message that later gains identity simply queues RFC members for new actions); and any urge to make Exchange-tail undo survive churn is the receipt spiral again.

**Persistent-failure chain-demotion amendment to decision 1 (2026-07-15; owner-directed).** Decision 1's "a transient failure blocks all later jobs" is amended with a THIRD failure class between transient and authoritative-terminal: **persistent** — a provider failure that is permanent-SHAPED but not authoritative-terminal (e.g. an unrecognized structural REST 400 whose body matches none of the adapter's known terminal shapes). Before this amendment such a failure retried forever at the frontier and wedged the entire global FIFO for every account; the rejected alternative (shipped briefly in an earlier release) dropped all 400s — self-healing but silently discarding intent. The owner chose demotion: *"fail and move the failure to the end of the queue — we'd have to move the whole chain related to the failing message though — so that it lets other moves go through. But also report the error loudly."* Classification stays below `EmailProvider` (Law 5/decision 8): Gmail throws `ProviderError.persistentActionFailure` for an action-path 400 whose body matches NONE of its known terminal shapes — invalid-label, and invalid-id-value on the token-member GET (both stay authoritative no-ops); Exchange for an action-path 400 other than `ErrorInvalidIdMalformed` (which stays authoritative — the PATCH setter path now classifies it as such too, consistent with move/token resolution), including its RFC `$filter` action search; IMAP has no persistent class (its terminal shapes are already classified; protocol errors stay transient). Coverage note (final audit 2026-07-15): the classification exists exactly where the body-preserving request variant is wired — every Gmail/Exchange action-path resolution and mutation site as of this amendment; a bodyless-400 arrival elsewhere (e.g. Graph nextLink pagination) stays plain transient by design. 401/403/429/5xx/transport are NEVER persistent — they stay plain transient and keep blocking the frontier (auth/throttle heal on their own). The queue reacts generically in ONE gated transaction: it computes the failing op's exact RELATED CHAIN — the transitive closure over same-account active rows whose member sets intersect, including the failing op — and re-inserts the chain at the queue TAIL, preserving `id` and every MODELED payload field byte-for-byte (delete + insert; only the rowid position changes — unmodeled inert physical columns, i.e. the v67 diagnostics counter and dev-only legacy columns absent from the model, reset to their column defaults on re-insert; all diagnostics-only, and the payload-immutability test asserts modeled fields by construction), keeping intra-chain relative order, all rows `queued`. Per-message serial order is never violated — where "message" means MEMBER STRING: relatedness (for both chain closure and undo reconciliation) is member-string intersection, so two ops addressing the same physical message through DIFFERENT identity shapes (a provider-token cold-notification row vs a later RFC-member row, PLAN_IDENTITY_HYBRID) never intersect and demotion may reorder them across each other. That is an accepted degraded-tail consequence: the misordered op resolves to an authoritative stale no-op at worst, never a wrong-message mutation. Cross-message reordering within an account is likewise the accepted cost, exactly like a user re-issuing the other actions after the failing one. No retry budget ever drops an intention — the chain retries at the tail on every future drain, ONE provider attempt per drain PASS (the spin-guard set lives on the per-pass `DrainContext`, so a `needsRedrain` re-pass inside one ownership grants a fresh attempt; re-passes only arise from external append triggers, so a lone failing chain still cannot spin — demote → guard-requeue → drain stops). The error is reported loudly (ungated `[Queue] ERROR: persistent provider failure — demoted N-op chain …` plus the once-per-drain `[QueueDiag]` deep dump). Undo reconciliation is unaffected: its newest-related scan is rowid-based and a demoted chain's newest member is still its newest. Pinned by `AccountManagerQueueDemotionTests` (demotion/recovery/spin-guard/closure/payload-immutability/undo-vs-demoted) and adapter cells in `GmailProviderMockTests`/`ExchangeProviderMockTests`.

**Implementation and audit record:** `PLAN_INTENTION_QUEUE_AUDIT_V2.md` (force-added in the Round 53 recovery checkpoint). Hybrid identity: `PLAN_IDENTITY_HYBRID.md`.
