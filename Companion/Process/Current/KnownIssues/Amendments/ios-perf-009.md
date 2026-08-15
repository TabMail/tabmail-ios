# IOS-PERF-009

- Register classification: `open`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN — MEASURED AND NARROWED (2026-08-15).** The multi-inbox plan remains reachable, but the
20,000-unread confirmation gate did not reproduce a user-significant cost and the query is off-main,
best-effort, and self-healing. Keep the row open because a much larger multi-inbox backlog can still
cross the standing threshold; do not change production code from the evidence recorded here.

## Subsystem and search terms

`UnreadCountManager`; `recordRecentUnreadForNSE`; `nseBadgeDedupRecentIds`;
`SyncConfig.nseBadgeDedupRecentLimit`; NSE badge dedup; `folderId IN`; IN-list;
`USE TEMP B-TREE FOR ORDER BY`; bounded sort; table-row fetches; `ORDER BY date DESC LIMIT`;
`messageHeader_folderId_isRead`; `messageHeader_folderId_isRead_date`; `INDEXED BY`; IN-list arity;
unread backlog; slow badge update; sibling of the `SearchView.legacyLocalSearch` Archive-search stall;
`sqlite_stat1`; stale statistics

## Full detail

**The shape.** `UnreadCountManager.recordRecentUnreadForNSE` issues

```sql
SELECT accountId, messageId, rfc822MessageId FROM messageHeader
 WHERE folderId IN (<inbox ids>) AND isRead = 0
 ORDER BY date DESC LIMIT <SyncConfig.nseBadgeDedupRecentLimit>
```

`EXPLAIN QUERY PLAN` on the `v84` schema at 250k rows gives `SEARCH messageHeader USING INDEX
messageHeader_folderId_isRead (folderId=? AND isRead=?)` **plus `USE TEMP B-TREE FOR ORDER BY`** for
two or more inbox folders. The cost scales with rows matching the predicate, not just the output
limit.

⚠️ **CORRECTION (2026-08-15) — the earlier mechanism and remedy were wrong.** This row used to say
*"the LIMIT cannot early-terminate; no index fixes it; only a per-folder rewrite does."* The temporary
sort is not itself proof of expensive work: SQLite bounds that sort by the `LIMIT`. The expensive leg
is feeding it `date` from the table for every unread match after the planner chooses
`messageHeader_folderId_isRead`, which does not carry `date`. Forcing the existing, ordinary-migration
`messageHeader_folderId_isRead_date` index keeps `USE TEMP B-TREE FOR ORDER BY` but lets SQLite feed
the bounded sort's `date` key from the index and fetch projected table columns only for rows admitted
to its top-N candidates. On the existing
four-inbox, 80,000-unread fixture, the exact production statement measured **58.344 ms median** while
the otherwise unchanged `INDEXED BY messageHeader_folderId_isRead_date` statement measured
**0.356 ms median**, returned the same 200 rows, and still reported the temporary sort. An independent
exact-schema audit found the same direction at three inboxes: **33.08 ms → 1.33 ms** at 100,000
unread. The earlier verification asked whether the sorter disappeared, so its predicate could not
express the winning result; this is the existing `MIS-007`/`MIS-033` family, not evidence for a new
per-folder mechanism.

**Why it is latent, stated as the trigger condition rather than the shape.** Three independent
narrowings, and **all three** must fail before this bites:

1. The folder set is `SELECT id FROM folder WHERE role = ?` with `role = inbox` — as written it can
   never be pointed at Archive or Gmail All Mail.
2. `AND isRead = 0` narrows the sorter's input to the **unread inbox count**, not the inbox row count.
   That count was small in the observed measurement; exact owner-mailbox counts are not public evidence.
3. One inbox-role folder is a clean `folderId = ?` case: the planner uses
   `messageHeader_folderId_isRead_date`, reports no temporary sort, and measured **0.110 ms median**
   with 20,000 unread in that folder on the four-inbox fixture. Exposure begins at two folders.

**It goes live when a multi-inbox unread backlog becomes very large** — a user who leaves tens of
thousands of messages unread across accounts, or a first full sync of several accounts whose inboxes
arrive unread before any read-state merge lands. At that point the input is the unread set and the
unhinted statement's cost scales with it.

⚠️ **It also goes live if anyone widens the `role = inbox` filter** or adds an archive/all-mail role to
that query — **the more likely regression**, because the query reads as "recent unread" and *nothing at
the callsite signals that the role filter is load-bearing for performance.*

**Mitigations that are real but must not be mistaken for a fix:** the read is `await dbPool.read`
(off-main, so it cannot stall typing), and the function is gated on
`UIApplication.shared.applicationState == .active`. The failure mode is therefore a slow reader and
CPU/database pressure, **not** a main-thread stall or a blocked WAL writer.

## Confirmation gate

The original **≥20,000 unread** gate has now been exercised under stale and fresh statistics and did
not cross ~100 ms. The remaining implementation gate is narrower: on a real device with **at least
two inbox-role folders** and a much larger unread backlog, time the exact statement. A temporary
sort alone is not evidence of harm. If the statement exceeds ~100 ms, first evaluate the existing
`messageHeader_folderId_isRead_date` index hint; do not default to a per-folder rewrite.

⚠️ **If the plan has flipped to `SCAN … USING INDEX messageHeader_date`, the measurement is INVALID and
must be re-taken at realistic volume** — that flip is what happens at small scale once `sqlite_stat1`
is populated. See `IOS-PERF-012` for the symmetric statistics trap and
`TabMailTests/Search/SearchScopedPageTests.swift` for the instrument note.

## Why registered rather than fixed

Latent behind three data-dependent narrowings, off the main thread, and outside the file scope of the
search-performance fix that found it. Nothing in THE MANTRA's blocking set is engaged. The existing
composite-index hint is the smallest candidate if the device threshold is crossed: one statement and
one reader acquisition remain one, output stays bounded at 200, and no index or migration is added.
The established `catch { return }` also preserves the fail-safe direction if the expected index were
ever unavailable. A per-folder rewrite works, but is dominated here: it changes one query to *k*,
transports up to *k* × 200 rows, and adds an app-side merge for less measured benefit.

## Related

- `IOS-SEARCH-004` — the same sorter shape in `SearchIndex.scanByDateRange`, but its sidecar lacks the
  composite index used by this row's candidate, so the hint does not transfer.
- `IOS-PERF-010` — the blocked-main-thread-reader half of the Archive-search problem.
- `IOS-PERF-012` — the general `sqlite_stat1` measurement trap; this row measured the same
  multi-folder plan under stale and fresh statistics, so statistics were not its deciding axis.
- `53d17514e` — the commit that fixed the first confirmed instance of this class.

## 📏 MEASURED 2026-08-13 — "latent" was the correct call

The whole-SQL-surface audit measured this site at **5 ms**, confirming the 2026-08-12 classification:
the shape is genuinely index-defeating, and the current data genuinely keeps it cheap. **Neither half
of "latent, shape-confirmed, not reproduced" needs revising.**

⚠️ **This row was one of two deliberately WITHHELD from that audit's brief as a blind control.** The
audit enumerated this site on its own and reached the same conclusion the row already recorded. A
prediction made from shape alone, later confirmed by independent measurement, is what makes the
*rest* of that audit's shape-only classifications worth acting on.

⚠️ **SUPERSEDED REMEDY (2026-08-15).** The earlier audit correctly showed that the per-partition
rewrite works here, but incorrectly made that fact the discriminator and preferred remedy. The
existing composite-index hint is smaller and measured faster while keeping one query. The reusable
lesson is narrower: decompose the work instead of using the presence of a temporary sorter as the
oracle. Here the sorter survives the winning candidate and its input source decides the cost.

## 📏 MEASURED 2026-08-15 — proportionality gate and sensitivity

The resumed pass used a **250,000-row, current-relevant-index-shaped synthetic fixture**, not a claim
about every production database: four inbox folders, 80,000 inbox rows, 170,000 archive rows, TEXT
payloads, and 20,000 unread distributed evenly. `ANALYZE` first ran against the empty table for the
stale/fresh-install regime, then after population for the fresh regime. Python's monotonic clock timed
30 read-only executions after a first read; the OS cache remained warm.

| unread across four inboxes | statistics | first read | warm median | warm p95 |
|---:|---|---:|---:|---:|
| 20,000 | empty/stale | 48.998 ms | **5.866 ms** | 6.868 ms |
| 20,000 | fresh | 48.047 ms | **6.432 ms** | 10.749 ms |
| 80,000 | empty/stale | 50.203 ms | **50.195 ms** | 55.034 ms |
| 80,000 | fresh | 58.842 ms | **48.456 ms** | 49.994 ms |

Both regimes chose `messageHeader_folderId_isRead` plus `USE TEMP B-TREE FOR ORDER BY`; fresh
statistics did not remove the multi-folder sorter. A later fresh-statistics run on the same 80,000
fixture measured **58.344 ms median** for the production statement and **0.356 ms** for the unchanged
statement forced through `messageHeader_folderId_isRead_date`; both plans still reported the sorter
and returned the same 200 rows. These Mac/SQLite fixture numbers are method evidence, not a device
latency claim. They preserve the earlier ~5 ms observation and show sensitivity without crossing the
standing ~100 ms device gate at the required 20,000-unread shape.

**Exact shipped fallback, checked against `v1.6.38`.** `recordRecentUnreadForNSE` is unchanged. The
authoritative unread total is written to the system badge and app-group mirror **before** this
foreground-only dedup read. Any read, staging-open, or mark failure skips the optimization; an NSE can
then over-count transiently and the next absolute main-app recount corrects it. Sidebar notification
delivery is already fire-and-forget relative to `updateBadge`. No user intention, message identity,
or durable authored data depends on this query.

**Disposition.** Keep `IOS-PERF-009` open and latent; ship no code from this measurement. Re-enter the
implementation gate with an exact device measurement when there are at least two inbox-role folders,
a realistically much larger unread population (start at 50,000), and the statement itself exceeds
~100 ms. If that happens, evaluate `INDEXED BY messageHeader_folderId_isRead_date` first. Do not add a
date tie-break as cleanup: the current query defines no order among equal dates, and the independent
audit measured `ORDER BY date DESC, id ASC` as destroying the hinted plan's benefit. A surviving code
candidate needs an invariant/plan test, not a timing assertion.
