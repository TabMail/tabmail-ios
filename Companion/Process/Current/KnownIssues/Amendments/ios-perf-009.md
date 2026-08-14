# IOS-PERF-009

- Register classification: `open`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN (2026-08-12)** — **latent, shape-confirmed, not reproduced.**
`UnreadCountManager.recordRecentUnreadForNSE` carries the **same index-defeating sorter shape** as the
Archive-search stall fixed in `53d17514e`. Classified **open**, not accepted: *nothing about the code
prevents it, only the current data does.*

## Subsystem and search terms

`UnreadCountManager`; `recordRecentUnreadForNSE`; `nseBadgeDedupRecentIds`;
`SyncConfig.nseBadgeDedupRecentLimit`; NSE badge dedup; `folderId IN`; IN-list;
`USE TEMP B-TREE FOR ORDER BY`; sorter defeats LIMIT; `ORDER BY date DESC LIMIT`;
`messageHeader_folderId_isRead`; early termination; unread backlog; slow badge update;
sibling of the `SearchView.legacyLocalSearch` Archive-search stall; `sqlite_stat1`; stale statistics

## Full detail

**The shape.** `UnreadCountManager.recordRecentUnreadForNSE` issues

```sql
SELECT accountId, messageId, rfc822MessageId FROM messageHeader
 WHERE folderId IN (<inbox ids>) AND isRead = 0
 ORDER BY date DESC LIMIT <SyncConfig.nseBadgeDedupRecentLimit>
```

This is the **same defect class** as the Archive-search stall. `EXPLAIN QUERY PLAN` on the `v84` schema
at 250k rows gives `SEARCH messageHeader USING INDEX messageHeader_folderId_isRead (folderId=? AND
isRead=?)` **plus `USE TEMP B-TREE FOR ORDER BY`**. SQLite cannot satisfy `ORDER BY date DESC` from any
index across an `IN`-list — k folders yield k separately-ordered runs and there is no merge operator —
so the `LIMIT` **cannot early-terminate** and cost is O(rows matching the predicate), not O(limit).
**No index fixes it**, verified by forcing every candidate with `INDEXED BY`; only a per-folder
`folderId = ?` rewrite does, as in `SearchView.recentHeaders`.

**Why it is latent, stated as the trigger condition rather than the shape.** Two independent narrowings,
and **both** must fail before this bites:

1. The folder set is `SELECT id FROM folder WHERE role = ?` with `role = inbox` — as written it can
   never be pointed at Archive or Gmail All Mail.
2. `AND isRead = 0` narrows the sorter's input to the **unread inbox count**, not the inbox row count.
   That count was small in the observed measurement; exact owner-mailbox counts are not public evidence.

**It goes live when the unread inbox backlog becomes large** — a user who leaves thousands of inbox
messages unread, or a first full sync of an account whose inbox arrives entirely unread before any
read-state merge lands. At that point the sorter's input is the unread set and cost scales with it.

⚠️ **It also goes live if anyone widens the `role = inbox` filter** or adds an archive/all-mail role to
that query — **the more likely regression**, because the query reads as "recent unread" and *nothing at
the callsite signals that the role filter is load-bearing for performance.*

**Mitigations that are real but must not be mistaken for a fix:** the read is `await dbPool.read`
(off-main, so it cannot stall typing), and the function is gated on
`UIApplication.shared.applicationState == .active`. The failure mode is therefore a slow reader
connection and write-queue scheduling pressure, **not** a main-thread stall.

## Confirm or refute with one measurement

On a device or simulator whose inbox has **≥20,000 unread rows**, run `EXPLAIN QUERY PLAN` on that exact
statement against the live DB and time it. If the plan still shows `USE TEMP B-TREE FOR ORDER BY` and
the statement exceeds ~100 ms, it is live and should get the same per-folder rewrite as
`SearchView.recentHeaders`.

⚠️ **If the plan has flipped to `SCAN … USING INDEX messageHeader_date`, the measurement is INVALID and
must be re-taken at realistic volume** — that flip is what happens at small scale once `sqlite_stat1`
is populated. See `IOS-PERF-012` for the symmetric statistics trap and
`TabMailTests/Search/SearchScopedPageTests.swift` for the instrument note.

## Why registered rather than fixed

Latent behind two data-dependent narrowings, off the main thread, and outside the file scope of the
search-performance fix that found it. Nothing in THE MANTRA's blocking set is engaged. The rewrite is
mechanical when it becomes warranted, and the superset argument that licences it is the same one used
for `SearchView.recentHeaders`: the global top *n* by date can draw at most *n* rows from any single
folder, so each folder's own top *n* necessarily contains that folder's entire contribution.

## Related

- `IOS-SEARCH-004` — the same sorter shape in `SearchIndex.scanByDateRange`, with a worse index story.
- `IOS-PERF-010` — the blocked-main-thread-reader half of the Archive-search problem.
- `IOS-PERF-012` — the `sqlite_stat1` staleness trap that decides which plan you observe.
- `53d17514e` — the commit that fixed the first confirmed instance of this class.

## 📏 MEASURED 2026-08-13 — "latent" was the correct call

The whole-SQL-surface audit measured this site at **5 ms**, confirming the 2026-08-12 classification:
the shape is genuinely index-defeating, and the current data genuinely keeps it cheap. **Neither half
of "latent, shape-confirmed, not reproduced" needs revising.**

⚠️ **This row was one of two deliberately WITHHELD from that audit's brief as a blind control.** The
audit enumerated this site on its own and reached the same conclusion the row already recorded. A
prediction made from shape alone, later confirmed by independent measurement, is what makes the
*rest* of that audit's shape-only classifications worth acting on.

**Unlike `SearchIndex.searchFTSOnly`, the per-partition rewrite DOES work here** — this site has a real
`(folderId, …, date)` composite for the `IN` list to defeat, so splitting per folder restores early
termination exactly as it did in `53d17514e`. **That is the discriminator to carry forward:** the
transferable defect is *"the LIMIT bounds the OUTPUT and not the WORK"*; the per-partition rewrite is
only its remedy where an ordering index actually exists. See `IOS-PERF-012` for the case where it does
not and the rewrite buys nothing.
