# IOS-SEARCH-004

- Register classification: `not-defect`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

✅ **NOT A DEFECT (2026-08-15)** — the filed multi-folder date-range query is not reachable from any
production or test caller. The sole production caller of `SearchIndex.search`, `EmailSearchTool`,
passes date bounds but never `folderIds`; `SearchView` uses `keywordSearch` and never reaches
`scanByDateRange`. No multi-folder query is therefore constructed, and no user-visible defect in that
query exists to fix.

## 2026-08-15 campaign disposition

**Exact reachability correction.** A bare-symbol caller census found one production call to
`SearchIndex.shared.search`: `EmailSearchTool.execute`. Its call supplies `query`, `fromDateMs`,
`toDateMs`, and `limit`, but not `folderIds`. No test calls this entry point with `folderIds` either.
The `folderId IN (...)` branch remains valid parameter plumbing inside `scanByDateRange`, but it is
dead today. This explicitly retracts the historical wording below that treated the AI tool as a
caller of the multi-folder statement; the tool reaches only the unscoped arm.

**Actually reachable residual, preserved rather than hidden.** A model can still improvise
`query = "*"` with a date bound. That reaches the unscoped statement on the `SearchIndex` actor's
separate `fts.db` pool. The prior whole-SQL-surface audit measured that arm at **22 ms** and found no
`dateMs` index. It remains a real full scan, but it is off-main, does not contend the main GRDB pool,
is not on the typing path, and has no demonstrated user-visible delay. There is no local query
fallback: tool failure becomes a tool error, while the successful result set is capped at 50.

**Why no adjacent index was added.** An independent solution audit considered a single-column
`dateMs` index for the reachable unscoped arm. That would optimize a different query than the filed
multi-folder issue while adding permanent storage and write amplification plus a one-time sidecar
index build. Those costs are not proportionate to the measured 22 ms, agent-only, off-main residual.
A `(folderId, dateMs)` composite would optimize only the dead branch. The historical suggestion that
a per-folder rewrite is a no-schema remedy is also withdrawn: unlike `messageHeader`,
`message_meta` has no folder/date ordering index for such a rewrite to restore, so each per-folder
statement still sorts. No index, rewrite, new fallback, or test-only machinery is justified now.

**Shipped comparison and reopen trigger.** `v1.6.38`, latest shipped `v1.7.9`, and current `main`
carry the same query shape and relevant index set; no shipped remedy was overlooked. Reopen and
re-cost this record if a production caller begins supplying `folderIds`, if a date-filter UI places
the query on an interactive path, or if the reachable unscoped arm is measured causing a
user-visible agent delay. At that point prove result-set equivalence, duplicate-folder semantics,
inclusive date boundaries, deterministic equal-date ordering, and cost scaling before choosing a
schema or query-shape change.

Everything below is preserved as the original registration and subsequent measurement history. Its
multi-folder reachability and proposed-remedy statements are superseded by the correction above.

## Subsystem and search terms

`SearchIndex.scanByDateRange`; `message_meta`; `idx_meta_folderId`; missing `(folderId, dateMs)`
composite; `folderId IN`; IN-list; `ORDER BY dateMs DESC LIMIT`; `USE TEMP B-TREE FOR ORDER BY`;
empty FTS query; `"*"` with date params; `SearchQueryParser.buildFTSMatch` empty; `EmailSearchTool`;
date-range scan; `fts.db` sidecar; slow agent-chat search tool call

## Full detail

**The shape.** `SearchIndex.scanByDateRange` builds

```sql
SELECT headerId, dateMs FROM message_meta
 WHERE <demo scope> [AND dateMs >= ?] [AND dateMs <= ?] AND folderId IN (<placeholders>)
 ORDER BY dateMs DESC LIMIT ?
```

Same class as `IOS-PERF-009` and the Archive-search stall, **but strictly worse on the index side**:
`message_meta`'s only relevant index is `idx_meta_folderId(folderId)`. There is **no
`(folderId, dateMs)` composite at all**, so unlike `messageHeader` there is not even a composite for the
planner to reject — the sorter is unavoidable for *any* scoped ordering here, and the unscoped case has
no `dateMs` index to walk either.

**Why off-main makes it non-urgent.** Its only caller is `SearchIndex.search()`, in the arm taken when
the parsed FTS query is empty but a date range was supplied (`"*"` plus dates). `search()`'s only
production caller is `EmailSearchTool` — an **AI tool invocation**, not the typing path.
`SearchView`'s per-keystroke debounce calls `SearchIndex.keywordSearch`, which goes straight to
`searchFTSOnly` and **never reaches `scanByDateRange`**. It also runs on the `SearchIndex` actor's own
FTS pool — a separate `fts.db` sidecar from the main GRDB pool — so it does not contend with UI reads or
the main write queue. Worst case today is a slow agent-chat tool call, which the user already
experiences as a network-latency-shaped wait.

**What would make it urgent** — any one of:

1. ⚠️ **`scanByDateRange` acquiring a caller on the typing path** (a date-filter UI in `SearchView`, or
   `keywordSearch` gaining a date-range arm). **This is the realistic one:** a "search within date
   range" affordance is a natural product request and would silently put this query on the
   per-keystroke path.
2. `message_meta` growing to mailbox scale with a scoped call — it already holds one row per indexed
   document and has been observed at mailbox scale, so **the volume can be there; only the callers are
   protecting it.** Exact owner-mailbox counts are intentionally omitted.
3. The AI tool being called in a loop (a multi-step agent turn issuing several date-scoped searches).

## Confirm or refute with one measurement

Run `EXPLAIN QUERY PLAN` on that statement against a real `fts.db` with an archive-sized folder scope.
Expected: a sorter, no useful index.

## Why registered rather than fixed

No production caller reaches it from an interactive path today, and it sits on a separate pool that
cannot contend with the UI. Two fix options if it becomes warranted:

1. A per-folder `folderId = ?` rewrite, matching `SearchView.recentHeaders` — **no schema change.**
2. Adding a `(folderId, dateMs)` index to `message_meta`.

⚠️ **Option 2 is a `SearchIndex` schema step, NOT a GRDB `vNN` migration**, so the
migration-immutability rule does not apply to it — but `SearchIndex`'s own idempotent
`CREATE INDEX IF NOT EXISTS` convention does. Do not conflate the two schema surfaces.

## Related

- `IOS-PERF-009` — the same shape in `UnreadCountManager.recordRecentUnreadForNSE`.
- `IOS-PERF-012` — the `sqlite_stat1` staleness trap governing which plan is observed.
- `53d17514e` — the fixed instance, and the source of the per-folder rewrite pattern.

## 📏 MEASURED 2026-08-13 — no longer "not reproduced"

The whole-SQL-surface audit measured this row directly, under **both** stat regimes:

| | folder-scoped (`folderId IN`) | bare (no folder predicate) |
|---|---:|---:|
| duration | **47 ms** | **22 ms** |

**Identical in both regimes** — stale and freshly-`ANALYZE`d produce the same plan and the same cost,
so unlike `IOS-PERF-012`'s subject this row's behaviour does **not** depend on `sqlite_stat1`. The
audit independently re-confirmed the structural claim above: **`message_meta` has no `dateMs` index of
any kind**, so even the unscoped 22 ms case is walking rows to satisfy the ordering.

⚠️ **This row was one of two deliberately WITHHELD from that audit's brief as a blind control on its
census.** It surfaced this site independently, by mechanical enumeration, without knowing the row
existed — and its measurements agree with the predictions written here on 2026-08-12 from shape alone.
That is the strongest available evidence that the audit's *other* findings are not artefacts of being
told what to look for, and it is the reason to trust its negative results too.

**Fix note — cheaper than this row assumed.** Adding the missing index does **not** require a GRDB
migration: `SearchIndex.migrateSchema` is re-entrant and idempotent, and `fts.db` is a sidecar outside
`AppDatabase`'s migration registry. So the objection that normally makes an index a heavyweight change
(iOS data-integrity rule 5 — a registered migration is immutable once applied anywhere) **does not
apply here**. Weigh it on its own merits instead.

⚠️ **But do not expect an `ANALYZE` to help after adding it.** All six `ANALYZE` sites in the tree run
on the **main pool**; none touches `fts.db`. A new index on `message_meta` will therefore be chosen —
or not — on **permanently empty statistics**. See `IOS-PERF-012` for the full consequence.
