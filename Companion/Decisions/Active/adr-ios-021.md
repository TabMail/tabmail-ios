
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
