
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
