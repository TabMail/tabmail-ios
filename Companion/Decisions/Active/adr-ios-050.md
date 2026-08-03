
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
