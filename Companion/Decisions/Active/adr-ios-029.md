<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Amendment (2026-08-05) — rule 5's REQUIREMENT is unchanged; only its TIMING moves off the blocking launch path.**
>
> **Owner directive, verbatim:** *"move it off. 200k+ tail matters. I am indeed really questioning why we need ANALYZE at all in startup migrations. startup migrations should really have only things that are absolutely necessary and blocking. Other things should happen durably in the heal/sync/background queues."*
>
> **Rule 5 as amended.** A migration that adds, changes, or drops an index still obliges the app to recompute whole-database statistics — that part is unchanged, and it is still whole-database, not narrowed to the index the migration touched. What changes is **when**: the migration marks statistics stale simply by performing DDL, and `SyncEngine.runRefreshPlannerStatisticsIfStale` runs the `ANALYZE` from the background WAL maintenance pass, once per schema change. The superseded text of rule 5 stays below, unedited, per the repo's no-content-loss rule.
>
> **The general principle the owner stated, which outlives this one migration:** *startup migrations contain only what is absolutely necessary and blocking; everything else runs durably in the background queues.*
>
> **Why it was needed.** `v83_markAllAsReadUnreadSweepIndex` carried a bare `ANALYZE`: ~850 ms at 360k rows, and at profile H (500k headers / 3.4 GB) it dominated the migration in two separate harness runs — 8,522 ms total in the first, and 6,688 ms total / **5,259.6 ms in the `ANALYZE` statement alone** in the second, against 154–296 ms for the `CREATE INDEX` it accompanied. It was the single most expensive statement in the whole `v68…v83` chain, paid before any UI appears. With it removed the same migration measures **2,015 ms total / 296.5 ms body**. ⚠️ The two totals differ because this is a timing-dependent measurement on a 3.4 GB file; the durable finding is the SHAPE — one statement dominating the chain — not either integer.
>
> **The latch and what re-arms it.** The marker is the SQLite `schema_version` in force when the last `ANALYZE` completed, persisted in `UserDefaults` (the `StartupMigrations` precedent, durable across app kill / crash / reboot). SQLite bumps `schema_version` on every DDL statement, so any migration that creates, drops or alters a table or an index re-arms the refresh automatically — there is no hand-maintained counter to forget. ⚠️ **What does NOT re-arm it:** ordinary row traffic, however far the counts move. A per-poll `ANALYZE` would be a far worse defect than the one this fixes.
>
> **Current note (2026-11-25, #1450): the `VACUUM` that switches the email database to INCREMENTAL carries the marker (ADR-IOS-121 decision 6).** A `VACUUM` adds one to `schema_version` and copies `sqlite_stat1` unchanged, so without a carry it would make the statistics look stale and re-arm a whole `ANALYZE` for statistics that did not change. `SyncEngine.switchEmailDatabaseToIncremental` reads `schema_version`, switches and reads it again in one write on the writer connection, under the refresh's single-flight latch (`plannerStatisticsRefreshInFlight`, so no `ANALYZE` stores its marker in between); a marker equal to the first value is set to the second, and a marker already stale stays stale. While an `ANALYZE` holds the latch the switch does not start; the upgrade the user started waits for it. The nightly `incremental_vacuum` steps change no `schema_version` (measured) and carry nothing.
>
> ⚠️ **NEGATIVE CASE 1 — do NOT read this as "statistics do not matter".** Measured on a synthetic 120k-row / 3-account / 8-folder database: with an empty `sqlite_stat1` the drain's per-member header lookup in `AccountManagerQueue` plans as `SEARCH messageHeader USING INDEX messageHeader_accountId (accountId=?)` — an account-wide scan — and after `ANALYZE` as a `MULTI-INDEX OR` over `messageHeader_messageId_accountId` + `messageHeader_rfc822MessageId_date`, two seeks. Deleting the `ANALYZE` outright would have been a regression.
>
> **Reproduced at profile H (500k headers / 3.4 GB) on the AFTER state — i.e. the whole `v68…v83` chain with no `ANALYZE` in any body — so this is the plan a real upgraded device now holds until the first background pass.** `EXPLAIN QUERY PLAN` on the query GRDB actually emits for that lookup (`WHERE (messageId = ? OR rfc822MessageId = ?) AND accountId = ? LIMIT 1`), with a real account id: **before** — `SEARCH messageHeader USING INDEX messageHeader_accountId_messageId (accountId=?)`, seeking on the account alone, i.e. a 100k-row account-wide walk; **after** the bare background `ANALYZE` — `MULTI-INDEX OR` over `messageHeader_accountId_messageId (accountId=? AND messageId=?)` and `messageHeader_rfc822MessageId_date (rfc822MessageId=?)`, two seeks, 0.079 ms/lookup. `sqlite_stat1` went from **0 rows to 36**. ⚠️ **The probe must use a value that EXISTS**: a first attempt with a literal account id present in no row reported the same plan on both sides, which reads as "statistics change nothing" and is an artefact of the probe, not a fact about the planner. **v83's own index is unaffected either way** — the unread sweep plans as `SEARCH messageHeader USING COVERING INDEX messageHeader_unreadSweep (folderId=?)` before and after, which is the measured basis for the claim that the `ANALYZE` bought `v83` itself nothing.
>
> ⚠️ **NEGATIVE CASE 2 — this amendment does NOT narrow `ANALYZE` to one index.** Rule 5's rationale is explicitly whole-database (*"Stale stats on old indexes are a source of silent regressions"*), so narrowing it to the migration's own index would be a deviation, not a narrowing. The background pass runs a bare whole-database `ANALYZE`.
>
> ⚠️ **NEGATIVE CASE 3 — this is not licence to defer arbitrary migration work.** Anything the schema's *correctness* depends on — a column, an index a query is written against, a data repair a reader assumes — stays blocking. Only work whose omission degrades *performance* and nothing else may be deferred, and only to something durable that re-arms itself.
>
> ⚠️ **SCOPE — five older migrations still carry an in-body `ANALYZE` and are DELIBERATELY UNTOUCHED:** `v38_addHeaderComplete`, `v39_restoreOriginalIndexes`, `v40_completeIndexCoverage`, `v50_embeddingRepopulatePartialIndex`, `v51_headerIncompletePartialIndex`. A registered migration is immutable once any database has run it (Data Integrity rule 5) and every shipped install ran all five long ago. They are cheap where they sit for the same reason they are useless: on a fresh install they analyze an EMPTY database, and on an upgrade they were paid years ago. Their real legacy is the pre-state the background pass now corrects, and it is verified rather than assumed — after `AppDatabase.runMigrations` on a fresh database, `sqlite_stat1` records `messageHeader` as having **zero** rows, which `SyncMaintenanceTests.schemaChangeRearmsButRowTrafficDoesNot` asserts directly.
>
> **Exposure window, and why it is not a regression.** Between an upgrade launch and the first background maintenance pass, statistics are whatever the previous release left. That is *exactly* the shipped regime — `ANALYZE` has only ever run inside migration bodies, never periodically, and on a fresh install those bodies record statistics for an EMPTY `messageHeader`, which a device that later syncs 100k messages then carries forever. The amendment is therefore no worse than shipped during the window and strictly better after it: a fresh-install device now gets real statistics for the first time.
<!-- COMPANION-CURRENT-NOTE-END -->

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

**Amendment 2026-11-24 (iOS #1374): `messageAICache_expiry` (`v113_messageAICacheExpiryIndex`).** The AI cache purge, `SyncEngine.runPurgeExpiredAICache`, reads the expired entries (`WHERE updatedAt < ?`) as a count and then in batches, after every AI queue drain and in every maintenance pass. No index led with `updatedAt`: the cache had its primary key on `key`, `messageAICache_key` (the same column again) and `messageAICache_rfc822MessageId`. So the count and every batch scanned the whole cache. `EXPLAIN QUERY PLAN` on the migrated schema, before: `SCAN messageAICache` for the count, for a batch, and for the old `LIMIT … OFFSET` batch, both with no statistics and with large-mailbox statistics. After `CREATE INDEX messageAICache_expiry ON messageAICache(updatedAt)`: the count is `SEARCH messageAICache USING COVERING INDEX messageAICache_expiry (updatedAt<?)` and a batch is `SEARCH messageAICache USING INDEX messageAICache_expiry (updatedAt<?)`, with no statistics, with large-mailbox statistics, and with statistics recorded while every entry shared one `updatedAt` (the state the removed TTL refresh left behind). The per-entry steps seek too: the inbox check, an `EXISTS` that stops at the first copy in an inbox, through `messageHeader_rfc822MessageId (rfc822MessageId=?)`, the delete and the clock restart through the primary key. The count, the batch and the inbox check name their index with `INDEXED BY`: with statistics recorded while the cache or the headers held one row, the planner can choose `SCAN messageAICache` for a batch, or a header scan for the inbox check, once the tables have grown, and nothing re-analyses them while the schema is unchanged.
- **Why a new index and not an existing one.** No existing index leads with `updatedAt`, and no other field holds the expiry: `updatedAt` is the expiry clock. The table is mail-sized (one entry per message the AI processed), so the small-table exemption does not apply.
- **Why not a partial index (rule 2).** The cutoff moves with the clock, so no fixed predicate holds just the expired entries.
- **Name (rule 1).** Named for its query, expiry, not for the column.
- **Statistics (rule 5 as amended).** The migration is `CREATE INDEX IF NOT EXISTS` only; the background `ANALYZE` after the schema change records its statistics.
- **Pinned by** `AICacheExpiryTests.everyStatementReadsThroughAnIndex`: it records every statement the real purge runs on a mail table, plans each with no statistics, with statistics taken on one-row tables that then grew, and with fresh statistics, requires no scan of a mail table, the expiry index on the count and every batch, the Message-ID index on every inbox check and the key on every write, and checks that the same reads scan once their index hint is taken away.

---

## Amendment 2026-11-23 (#1354): `messageBody_staleEvict`

**Rule 1 applied.** `messageBody_staleEvict` on `messageBody(fetchedAt)` serves the stale-body evict step's keyset page (`SyncEngine.staleBodyPageSQL`: the next `pruneChunkSize` bodies older than the cache cutoff after a `(fetchedAt, rowid)` cursor, in index order). `EXPLAIN QUERY PLAN` before: `SCAN messageBody` (the old page, `LIMIT … OFFSET …`, walked the table from its start inside its write, through the overflow pages of every kept body, since `fetchedAt` is stored after the HTML). After: `SEARCH messageBody USING INDEX messageBody_staleEvict ((fetchedAt,rowid)>(?,?) AND fetchedAt<?)`, no scan, no temp B-tree; the first page is `(fetchedAt<?)`. Before it, `messageBody` had only its primary-key autoindex, and nothing else records when a body was cached, so no existing index could carry the predicate. A full index, not a partial one (rule 2): the stale set does not drain to empty (the rules keep inbox and recent bodies) and its bound moves with the clock. No index is dropped (rules 3 and 4). Only the evict step filters or orders on `fetchedAt`. Every other `messageBody` statement selects rows by `id` (one key, an `id` list or subquery, or an `id` prefix or range), reads `MAX(rowid)` by a right-edge rowid lookup (the v70 migration's diagnostic and `MigrationTimingLedger.measureChainScale`), or works on the whole table (wipes, a migration's copy), so no other plan can move to the new index.

**Built deferred, rule 5 by the amended timing.** The index is in `SyncEngine.deferredIndexes` (IOS-PERF-005), not a migration, because building it reads every cached body once. The build is DDL, so it moves `schema_version`, and the same maintenance pass's `runRefreshPlannerStatisticsIfStale` (which runs after it) refreshes the statistics when it completes; it is single-flight and gives up while the database is suspended, and a pass where it does not complete leaves its marker stale, so a later pass refreshes them. The evict step runs only once the index exists (`runEvictStaleBodiesIfIndexed`), so its page never runs unindexed. Detail: IOS-PERF-002 amendment of the same date.

---

## Amendment 2026-11-24: a deferred index and the statistics refresh commit in one write

**Rule 5's timing, refined.** The amended rule 5 (statistics refreshed by the background pass, once per schema change, whole-database) is unchanged. What changes is where a deferred index is built: no longer in a write of its own before the refresh, but inside the refresh's write. `SyncEngine.runRefreshPlannerStatisticsIfStale` builds every missing deferred index (`SyncEngine.deferredIndexes`), runs `ANALYZE`, and reads `schema_version` for its marker in one write; when no deferred index is missing it is the same statistics refresh as before. It checks for missing deferred indexes before its marker, so a deferred index added later is built even where the statistics are already fresh.

**Why.** `CREATE INDEX` moves `schema_version` and `ANALYZE` does not (once `sqlite_stat1` exists), and a connection reloads its schema and statistics only when `schema_version` has moved. Built in a write of its own, the index was visible for a moment with no statistics, and a connection that read in that moment kept planning from the new index beside the other indexes' old statistics after the refresh committed, until it was closed. A census of 14 statements over five statistics regimes and two index shapes found such connections planning differently from a fresh one; in one write they all converge (IOS-PERF-005, amendment of the same date, pinned by `DeferredIndexStatisticsTests`).

**Negative case.** This does not narrow the refresh to the new index: `ANALYZE <index>` in the build's write was exact only when the other statistics were current, and NEGATIVE CASE 2 above still holds. Nor does it move any build onto the launch path: the write runs only in the background maintenance pass, at `.background`, and rolls back whole if cancelled or failing.

---

## Amendment 2026-11-24 (#1401): `messageHeader_backfillProgress`

**Rule 1 applied.** `messageHeader_backfillProgress` on `messageHeader(accountId, bodyComplete, bodyEmptyConfirmed, bodyMetadataOversized, headerComplete)` serves the three counts the backfill progress publishes for one account on every update (`SyncEngine.backfillProgressCounts`, called by `updateBackfillProgressForAccount`). It holds every column `MessageHeader.bodySettledRequest` and `MessageHeader.pendingBodyRequest` test, so both counts read its entries and never a header row: the pending count seeks all five columns, the settled count seeks the account and tests its `OR` in each entry. Before it, the settled count planned `SEARCH messageHeader USING INDEX messageHeader_accountId_messageId (accountId=?)` and read every header row of the account, and the pending count planned `SEARCH messageHeader USING INDEX idx_messageHeader_bodyStatus (headerComplete=? AND bodyComplete=? AND bodyEmptyConfirmed=?)` and read every pending row of every account. No existing index has `accountId` together with `bodyEmptyConfirmed` and `bodyMetadataOversized`, so none could carry either predicate. The total keeps its `accountId`-led covering index. The two predicates and their documented `headerComplete` asymmetry are unchanged; each update still counts the whole set.

**A full index, not a partial one (rule 2).** The settled set grows to the whole account, so it does not drain to empty. A partial index on the unsettled rows would also not be chosen for these counts: GRDB binds `== true` and `== false` as parameters, and SQLite matches a partial index's `WHERE` against literal terms, not against parameters bound after the statement is prepared.

**Nothing dropped (rules 3, 4 and 6).** The index extends v40's `messageHeader_accountId_bodyComplete` and keeps its prefix, so it serves every plan that one serves; v40's stays, as v40's `messageHeader_bodyRepopulate` stayed beside `messageHeader_bodyRepopulateV2`.

**Built deferred, rule 5 by the amended timing.** It is in `SyncEngine.deferredIndexes` (IOS-PERF-005): building it reads every header once, and its absence changes no result, only how much the counts read; nothing names it in an `INDEXED BY`. It is built inside the statistics refresh's write with the other deferred indexes (amendment above), so the index and its statistics commit together. `BackfillProgressCountTests` pins the plans in three statistics states (the migration chain's, none, a fresh `ANALYZE`), with a control that drops the index and reproduces both row-reading plans, and compares the counts against the same read without the index on an empty database, one row in each flag combination, tied index keys, several accounts with one empty, and 100,000 rows.

**Measured (#1401, iOS simulator, `BackfillProgressIndexProofTests` on `DBProof.Shape.large`: 105,000 headers in four accounts, the app's own SQLite).**

Size, after a vacuum. Of the 43,180-page database:

| Index | Pages | Size | Per header | Share of the database |
|---|---|---|---|---|
| `messageHeader_backfillProgress` | 1,258 | 5.15 MB | 49.1 bytes | 2.91% |
| v40's `messageHeader_accountId_bodyComplete` | 1,188 | 4.87 MB | 46.3 bytes | 2.75% |

Write cost, as median wall time old -> new, new/old ratio. "No statistics" is no `sqlite_stat1`; "analyzed" is after the app's `ANALYZE`. These are the figures of the final proof run, on the head that ships.

| Write | No statistics | Analyzed | Pages written |
|---|---|---|---|
| 100 new headers | 37.8 -> 45.0 ms (1.19) | 37.3 -> 42.5 ms (1.14) | 232 -> 241 |
| `headerComplete = 1` on 200 headers | 59.5 -> 64.4 ms (1.08) | 53.5 -> 54.7 ms (1.02) | 754 -> 777 |
| `bodyComplete = 1` on 50 bodies | 44.4 -> 59.6 ms (1.34) | 42.7 -> 65.2 ms (1.53, marked slower) | 339 -> 511 |

The harness marks every ratio within noise except the analyzed `bodyComplete` flip. That flip writes 51% more pages because the index holds that column, so each completed body moves one entry. In time this is about 15 to 22 ms more per 50-body batch write, or 0.30 to 0.45 ms per body. An earlier run of the same proof measured about 0.15 ms per body with the same page counts. The accepted figure is this run's, and the page count is the stable measure. The cost is accepted against the reads it saves (below): each progress update reads 102 pending pages instead of 5,178 to 7,986, and 716 settled pages instead of 6,467. A body download's network time is far above half a millisecond.

Census of the hot reads, with the index present and without it, in four statistics states:
- the migration chain's;
- none;
- a fresh `ANALYZE` with the index present;
- an `ANALYZE` taken before the index was built.

Pages read, with the index / without it:

| Read | Migration chain's | None | Fresh `ANALYZE` | `ANALYZE` before the index |
|---|---|---|---|---|
| Settled count | 716 / 6,467 | 716 / 6,467 | 716 / 6,467 | 716 / 6,467 |
| Pending count | 102 / 7,986 | 102 / 7,986 | 102 / 5,178 | 102 / 5,178 |
| Total count | 677 / 677 | 677 / 677 | 677 / 677 | 716 / 677 |
| Embedding repopulate (`repopulateSQL`) | 511 / 511 | 511 / 511 | 511 / 511 | 511 / 511 |

Every other hot read (the body download queues, the inbox member seed, the label-filter page) reads within 0.3% of the same pages in every state.

What changed:
- The pending count reads 102 pages instead of 7,986 (the migration chain's and no statistics) or 5,178 (fresh and stale).
- The settled count reads 716 pages instead of 6,467, in every state.

Two reads cost more:
- **The embedding repopulate read.** Its statement is now `BackfillEmbeddingQueue.repopulateSQL`, which both queues' repopulate reads run.
  - **What happened:** with this index present and a fresh `ANALYZE`, SQLite planned it as `SEARCH messageHeader USING INDEX messageHeader_backfillProgress (ANY(accountId) AND bodyComplete=? AND bodyEmptyConfirmed=?) | USE TEMP B-TREE FOR ORDER BY`. That is a skip-scan by account plus a sort of the whole backlog: 10,831 pages instead of 511, and 915,829 VM steps instead of 2,509.
  - **The fix:** the statement names `messageHeader_embeddingIncomplete` with `INDEXED BY`. That index is migration-built (v50) and never deferred, so it always exists, and the read keeps its ordered scan in every state.
  - **Pinned by:** `BackfillProgressCountTests.embeddingRepopulateKeepsItsIndex`. It checks the plan in every statistics state and under the `sqlite_stat1` rows of a full `ANALYZE` of the proof database (taken with the Mac's sqlite3 and identical to the simulator's `ANALYZE` of it; a plain `ANALYZE` with no analysis limit, as the app runs, counts exactly, so the app's writes the same rows on that data), and it is red without the name under those rows. Setup checks compare the rows with the table's index list and require that under them the read without the name plans the skip-scan, so rows from another database fail the test instead of passing it. A fresh `ANALYZE` of the test's own 20,000 headers does not reproduce the skip-scan on the simulator's SQLite (the Mac's SQLite plans it from 5,000 headers), so the test carries the large mailbox's statistics. The planner reads nothing else about the table: the app's SQLite keeps no `sqlite_stat4`. The proof's census probe runs the production statement.
- **The total count, in the stale state only.** It moves to this index: 716 pages instead of 677 (+6%), because v40's index is the smaller covering index for that count.
  - **Accepted:** the pass no longer leaves this state. The deferred build runs inside the statistics refresh's write (amendment above), so no connection sees the index without its statistics. The census keeps the state as the worst case: before that change, a connection that loaded the schema between the build and the `ANALYZE` held it until it was closed.
  - **Why v40 stays:** in every other state the total still reads v40's `messageHeader_accountId_bodyComplete`, and it is the cheaper index there.

---

## Amendment 2026-11-24 (#1397): `messageHeader_completeByDate`

**Rule 1 applied.** `messageHeader_completeByDate` on `messageHeader(date, id) WHERE headerComplete = 1 AND bodyComplete = 1` serves the start-up search self-check's candidate read (`SyncEngine.ftsBodyMembershipCandidateSQL`, the newest 2,000 complete headers of every account), which runs at every launch and every return to the foreground.
- **Before:** `EXPLAIN QUERY PLAN` showed `SEARCH messageHeader USING INDEX idx_messageHeader_bodyStatus (headerComplete=? AND bodyComplete=?)` and `USE TEMP B-TREE FOR ORDER BY`. The read read and sorted every complete header before it returned the first.
- **After:** `SCAN messageHeader USING COVERING INDEX messageHeader_completeByDate`. The read walks the index newest first, stops at the 2,000th entry, and reads no table page.
- **No existing index could do this.** None orders the complete headers by `date`, so none could return them in date order.

**A partial index, for its scope.** The complete set does not drain to empty: it is most of the table, so rule 2's reason does not apply. The index is partial so that only a statement whose WHERE implies `headerComplete = 1 AND bodyComplete = 1` can use it.
- **The full-index version failed.** A first version was a full index on `(headerComplete, bodyComplete, date, id)`. The planner also chose it for the start-up recovery read (`headerComplete = 0`, `LIMIT 500`), which then read 40 to 97 percent more pages than through `idx_messageHeader_bodyStatus` (simulator proof at 105,000 and 525,000 headers). A partial index cannot serve that read.
- **Only two statements can use it.** In the app, only the candidate read and the page of the one-time sweep `healAllFTSBodyMembership` have a WHERE that implies the index's. The candidate statement keeps its two literals: SQLite matches a partial index's WHERE against literal terms, not against parameters bound after the statement is prepared.
- **Fewer writes.** A header enters the index only once both flags are 1. Inserting a header that has no body, or marking a header complete before its body arrives, does not write to the index.

**Statistics states.**
- **Statistics taken after the sync:** the candidate read uses the index; the recovery read and the sweep page keep their plans.
- **`sqlite_stat1` emptied:** all three reads keep the plans they had without the index, with no gain and no loss.
- **Statistics taken on an empty mailbox** (a fresh install whose first maintenance pass runs before its first sync): the candidate read uses the index, and the sweep page may too. That sweep runs once per device, seconds after the first launch's sync starts, when such a mailbox is still nearly empty. Before this index, the sweep page already sorted every complete header in that state.

**Nothing dropped (rules 3, 4 and 6).** `idx_messageHeader_bodyStatus` still serves the recovery read, and serves the sweep page when no statistics exist.

**Built deferred, rule 5 by the amended timing.** The index is in `SyncEngine.deferredIndexes` (IOS-PERF-005) for three reasons: building it reads every header once; without it no result changes, only the read's cost; and the statement names no index. It is built inside the statistics refresh's write with the other deferred indexes (amendment of 2026-11-24 above), so the index and its statistics commit together.

**Pinned by:**
- `FTSSelfHealCandidateReadTests` compares the read with the index against the replaced read, without the index, on these mailboxes: empty, one row, only incomplete headers, a window that cuts a run of equal dates, several accounts, and 100,000 rows both dense and sparse. It runs each comparison in the three statistics states, pins the plans in each state, and checks that the recovery read and the sweep page do not move to the index.
- `FTSSelfHealCandidateProofTests` measures, on the proof databases: the read, the two other reads, the sync pass's header writes, and the index's size.
- The query registry gives the read the verdict `STOPS: FTSSelfHealCandidateReadTests.candidateReadStopsAtTheWindow`, not `SEEK`: the plan check runs without statistics too, and there the planner does not choose a partial index.

## Amendment 2026-11-24 (#1433): `messageHeader_htmlCachedAt` replaces `messageBody_staleEvict` in the deferred set

**A deferred index, built with its column's fill.** `messageHeader_htmlCachedAt (isInInbox, htmlCachedAt)`
(ADR-IOS-119) is in `SyncEngine.deferredIndexes`. `v116_addMessageHeaderHTMLCachedAt` adds only the
column and its triggers; the deferred step's one write (`runRefreshPlannerStatisticsIfStale`) first
fills the column from `messageBody` (`HTMLCachePair.fillSQL`, run by `createDeferredIndexes` only
while the index is missing), then builds the index, then runs `ANALYZE`, so no connection ever loads
it without a statistics row (#1401). The index existing is the proof the fill ran. The fill reads
every cached body once (`fetchedAt` is stored after the HTML), as `messageBody_staleEvict`'s build
did, and it also rewrites one header row per cached body, and the index build reads every header, all in
the one write, so the step costs more than that build did. It runs where that build ran: in the
first background maintenance pass after the upgrade (`runWALMaintenance`, `.background`), never on
the launch path; a `.priority` write issued while it holds the writer (a Send) waits for it once.
After it commits, the step calls `checkpointWALThrottled(truncate: true)` with the pool it wrote to:
a TRUNCATE, because a PASSIVE checkpoint there would make the pass's closing TRUNCATE skip inside the
throttle's interval and leave the WAL file at its largest. `StaleBodyEvictPairProofTests` reports
v116's time and the step's (whole, its three statements apart, and per MB of body pages), the WAL
size its write leaves and its checkpoint's time, at 105k and 525k headers, and
the step again at 105k with bodies of 24 to 40 KB. Rule 1: it serves exactly the evict's keyset page
(`isInInbox = 0 AND htmlCachedAt < ?` in `(htmlCachedAt, rowid)` order). `SyncEngineMaintenanceTests.staleBodyPageSeeksItsIndex`
pins the page's plan without statistics. Its size and its write cost against the old schema are
measured in `StaleBodyEvictPairProofTests`.

**Rule 5 (other reads).** The same proof reads the plan of every hot read the #1401 census lists
(`BackfillProgressIndexProofTests.probes`, the evict's own excepted) and the chat pill's reminder
count on the old file analyzed, then after v116 and the step: none may change. Its control builds
the index over every header (not partial) after v116 with no `ANALYZE`, the state the first,
migration-built version would leave, and must move at least one `isInInbox = 1` read onto it, so the
census is shown to see such a change.

**A partial index, for its scope (as `messageHeader_completeByDate` above).** The index is
`(isInInbox, htmlCachedAt) WHERE isInInbox = 0 AND htmlCachedAt IS NOT NULL`: it holds only the cached
headers outside the inbox, so only a statement whose WHERE implies both terms can use it.
- **The full-index version failed.** Built over every header, the query plan check without statistics
  (`DatabaseIndexTests.seekVerdictsHoldInThePlan`, `.noStatistics`) planned
  `NotificationActionRouter.resolveDurableInboxHeader` (`isInInbox = 1`) onto it as a walk of every inbox
  header, instead of `messageHeader_accountId_messageId`. A partial index cannot serve that read.
- **`isInInbox` stays its first column,** one value throughout. The page's `isInInbox = 0` is then an
  equality on the index, so without statistics the planner seeks it (equality and range) and not
  `messageHeader_isInInbox_date` (equality only) with a sort, which the index on `htmlCachedAt` alone
  got. The page keeps the literal `isInInbox = 0`: SQLite matches a partial index's WHERE against
  literal terms.
- **Fewer writes.** A header enters the index only while it is outside the inbox with cached HTML: an
  inbox header's writes and a header with no cached HTML never write to it.
- "No cached HTML" (`htmlCachedAt IS NULL`) is not served; no statement reads it.

**The evict waits for it** (`runEvictStaleBodiesIfIndexed`, as it waited for `messageBody_staleEvict`).

**A named exception to NEGATIVE CASE 3.** The fill is a data repair that `HTMLCachePair.isCached`
readers rely on, the kind NEGATIVE CASE 3 keeps blocking. It is deferred only because of what its
absence does: until the step commits, a body cached before v116 reads as not cached, so it may be
fetched or merged again (`fetchBody` and the thread view fetch it again, the notification merge
re-merges a staged row, the AI diagnostic reports no body); nothing is deleted and no message is
shown another's content (ADR-IOS-119 decision 7). A repair whose absence would delete data, show a
message another's content or change what a user reads stays blocking: this exception covers this
fill only.

**`messageBody_staleEvict` (#1354) leaves `SyncEngine.deferredIndexes`.** Nothing reads it since the
evict reads its candidates from the header. As of 2026-11-24 no released or TestFlight build ran the
deferred step with it in the list (it was added after build 392, the newest TestFlight build then),
so no user's database holds it, and nothing drops it; a development database that built it keeps
it, unread and changing no result.

---

## Amendment 2026-11-27 (#1563): the three In-Reply-To lookups name `messageHeader_inReplyTo`

**What happened.** Three reads look rows up by `inReplyTo IN (…)`:
- the thread lookup's reply probe (`ThreadUtils.findAdoptableThreadId`, `LIMIT 1`), run for every
  stored email;
- the thread view's related-email search (`ThreadDetection.findRelatedMessages`,
  `ORDER BY date DESC LIMIT 100`), run for every email opened;
- the parent-side reply discovery (`ReplyParentResolver.markInsertedParentsOfStoredReplies`, joined
  to the Sent folders), run for every batch of stored headers.

None of them sought the index once `ANALYZE` had run on a mailbox with no In-Reply-To stored. The
Microsoft Graph sync stores none, so an Outlook-only database is that mailbox. *(Amended 2026-11-27,
#1559: the Graph sync now stores In-Reply-To for mail it reads with the extended-property expand; Outlook
mail stored before that release, by an Inbox baseline or from search still has none, so such a mailbox
still exists and the forced index stays right.)*
- **Why the planner chose it.** `ANALYZE` counts NULL as one value. With every `inReplyTo` NULL, the
  index's `sqlite_stat1` row reads `N N`: every row shares one value. The planner then prices a seek
  as N row lookups and prefers another plan.
- **What it cost.** Measured on the database proof of #1555 (105,000 headers, its seed's In-Reply-To
  all NULL, after `ANALYZE`). A lookup usually matches nothing, so each plan read its whole range:
  - the thread lookup planned `SCAN messageHeader`: about 605,000 pages per 50 emails stored;
  - the related-email search planned `SCAN messageHeader USING INDEX messageHeader_date`: every
    header (104,999 scan steps, about 85,000 pages, about 2 s cold) for one email opened;
  - the reply discovery planned `SCAN f`, then `SEARCH r USING INDEX
    messageHeader_folderId_providerDate (folderId=?)`: every row of each Sent folder (about 68,000
    steps, 28 ms) per chunk of up to 100 stored Message-IDs.

**The fix: name the index on those three statements.** The results are unchanged: the name only fixes
the plan.
- The thread lookup and the reply discovery name it in their SQL: `FROM messageHeader INDEXED BY
  messageHeader_inReplyTo`, and `FROM messageHeader r INDEXED BY messageHeader_inReplyTo JOIN folder f`.
  The reply discovery then seeks each match's folder by its primary key.
- The related-email search was a query-interface request, which cannot name an index. That one
  request is now raw SQL with the same filters, order and limit.
- **Why it is safe.** `INDEXED BY` throws when its index is missing.
  - `messageHeader_inReplyTo` is migration-built (`v13_addMessageHeaderInReplyTo`). It is not in
    `SyncEngine.deferredIndexes`, no migration drops it, and no migration after v13 rebuilds
    `messageHeader`.
  - Every caller runs after v13. The thread lookup: the insert paths, and the two migration callers
    (`v47_lateralThreadRepair` and `v54_mergeFragmentedThreads` through `runFragmentMergeToFixpoint`).
    The related-email search: the message detail view. The reply discovery: the sync insert paths
    (`fetchOlderMessages`, `insertBackfillBatchGuardable`, `runSyncMessages`, `insertChangeRecord`).
  - The notification extension and `Shared` call none of them.
- **Precedent.** `ReplyParentResolver.hasStoredReply` names the same index, and
  `ReplyParentResolver.parentLookupSQL` names `messageHeader_rfc822MessageId`.
- **Registry.** The related-email search and reply discovery rows move from `SIM` to `SEEK`. Their
  literals are completed at run time (an `IN` list), so the plan fence skips them and the tests
  below carry the plan.

**Pinned by** three tests, each in two statistics states: none, and the app's `ANALYZE` over a
mailbox with no In-Reply-To stored.
- `ThreadAdoptionInReplyToPlanTests.probeSeeksItsIndex` (the thread lookup),
  `InReplyToLookupPlanTests.threadViewLookupSeeksItsIndex` (the related-email search) and
  `InReplyToLookupPlanTests.replyDiscoveryLookupSeeksItsIndex` (the reply discovery).
- Each captures the statement production runs (a statement trace) and requires it to seek
  `messageHeader_inReplyTo`. The reply discovery's check covers both loops of its join.
- Under the second state each also checks the positive control: without the name, the same statement
  plans the read measured above (the reply discovery's through any index that leads with `folderId`).
- Each then checks the answer: a stored reply is still found.
- Each is red without the name.
