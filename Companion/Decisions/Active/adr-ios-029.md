
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

**Rationale:** SQLite indexes are B-trees. A query can only use a contiguous leading prefix of index columns with equality predicates, then one range/ORDER-BY column. Adding a separate index preserves existing query performance while enabling new query patterns. But an unused index is not inert: the planner considers it on every query and stale statistics (post-migration column changes, skewed data distribution) can make it look deceptively cheap. Dropping obsolete indexes is a perf fix, not a cleanup task.

**Consequences:**
- The `messageHeader` table may have 10+ indexes — acceptable for a read-heavy workload.
- Write amplification per `INSERT/UPDATE` is bounded by `indexCount × log(N)`.
- Index disk space is ~10-20% of table size per index — acceptable for a 250K row table.
- Migrations that drop indexes must include the `ANALYZE` call and document what was superseded, so future readers understand why the index no longer exists.

---
