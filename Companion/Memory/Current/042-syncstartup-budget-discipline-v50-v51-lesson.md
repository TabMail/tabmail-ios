
### `syncStartup` Budget Discipline (v50/v51 lesson)
- **`syncStartup` is the shared entry point** for FG return, BGAppRefresh, silent push, and BGProcessing. Any blocking work before the `syncTask` spawns is paid by ALL four paths.
- **BGAppRefresh (~25s) and silent push (~30s) have iOS-imposed budgets.** Pre-sync work eats directly into message-fetching/AI-processing time. A 3s pre-sync scan = 10% of push budget burned before a single byte is fetched. When NSE classification or delta sync gets cut off mid-flight, passive "Inbox updated" notifications appear instead of the AI-classified ones.
- **Every pre-`syncTask` step must be cheap at steady state** (<10ms each). Currently: NSE merge (0ms if unchanged), `cancelAllInFlight` (parallel, ~1-5ms), `recoverIncompleteHeaders` (partial-index seek, ~ms). Self-heal 2b/2c and repopulate are detached post-spawn.
- **Adding DB reads to the pre-sync path requires a purpose-built index.** Test with `EXPLAIN QUERY PLAN` — if you see `SCAN messageHeader`, `ANY(...)`, or `USE TEMP B-TREE FOR ORDER BY`, fix before landing. See ADR-IOS-029.
- **Prefer partial indexes for "drain to empty" queries** (crash recovery, orphan repair, queue repopulate). At steady state the index has ~0 rows, seek is free regardless of stats.
- **Incident history**: `BackfillEmbeddingQueue.repopulate` (v50 fix) burned 1.4-4.2s; `recoverIncompleteHeaders` (v51 fix) burned 2-2.6s. Both for 0-row results. Both were planner confusion from overlapping indexes + stale stats. Partial indexes + dropping the superseded full indexes eliminated both.
- **Future verification**: a seeded 100K-row in-memory harness with EXPLAIN + wall-clock assertions per hot query (planned). Until that exists, manual `EXPLAIN QUERY PLAN` probe on any new pre-sync query.
