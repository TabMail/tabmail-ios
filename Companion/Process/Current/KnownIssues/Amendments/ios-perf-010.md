# IOS-PERF-010

- Register classification: `open`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN — NARROWED (2026-08-14)** — the two concrete `SearchView` members named by this record are
fixed, but the record's broader by-state acceptance criterion is not complete. Classification remains
**open**; do not close GitHub #13 from this change.

## 2026-08-14 implementation and residual

The confirmed typing-path stalls are removed without moving the legacy result behind the 150 ms FTS
debounce:

- `legacyLocalSearch` still starts before the debounce, but its bounded recent-header query and
  account map now share one asynchronous raw-`DatabasePool` reader acquisition. Cancellation is
  checked before publishing its result. While that reader is pending, Search shows its existing
  loading state instead of a false empty result, and any remote rows that arrive first retain
  identity ownership: account-wide provider rows supersede same-account local folder copies, while
  folder-scoped IMAP rows supersede only the matching folder UID.
- `ftsResultsToSearchResults` now resolves a ranked page under one asynchronous reader acquisition.
  The common path is two set-wise statements (accounts plus exact header ids), replacing the old
  per-result acquisitions. The rare Gmail/Outlook stable-id drift fallback is grouped into one indexed
  query per affected account. Input rank order, folder scoping, diagnostics, and both FTS self-heals
  are preserved.
- Both per-keystroke Search reads use the raw pool rather than `PrioritizedDatabase` read-through.
  A pending NSE staging merge may legitimately take seconds, and cannot add a header to the FTS page
  that was already queried, so making it part of this hot display path would change semantics without
  improving the current result. Settings retains read-through for its eventual display-only count.
- A real WAL `DatabasePool` test with `maximumReaderCount = 1` holds the only reader for about 350 ms.
  The fixed paths wait about 361 ms while a 20 ms `MainActor` heartbeat advances 17 times. The inverse
  synchronous control waits about 364 ms with zero heartbeat ticks and fails the regression test.

This is a **proven reachable stall**, not a query-duration theory: the original device stack already
ended in `dispatch_sync`, and the inverse control reproduces the actor starvation under reader
contention. It is also a query-count improvement: the exact FTS path no longer performs N+1 pool
acquisitions.

**Residual scope keeping this record open.** This pass did a current-state census sufficient to cover
the two issue-listed Search paths, but it did not certify every synchronous database state reachable
from every `@MainActor` context. At least `SearchView.openResult` still contains one synchronous,
indexed header lookup on an explicit result tap. `UndoService.push` also retains synchronous
main-actor diagnostic reads, now wholly behind the debug-logging gate fixed by `IOS-PERF-016`; that is
not ordinary production work, but must be classified explicitly in a full census. Close #13 only
after that complete by-state inventory either converts or consciously classifies every survivor.

## Subsystem and search terms

synchronous `dbPool.read` on `@MainActor`; main-thread block; priority inversion;
`Thread Performance Checker`; `User-interactive waiting on … Utility`; `PrioritizedDatabase.read`;
raw `DatabasePool.read` async overload; NSE staging read-through;
blocked reader vs pool holder; `SearchView.legacyLocalSearch`; `SearchView.onQueryChanged`;
`.onChange(of: query)`; per-keystroke DB read; debounce bypass; `IOS-PERF-001` census scope error;
`Task.detached(priority: .utility)`; `MAIN THREAD STALL`; cheap-but-synchronous; census by state

## Original registration detail (historical; named SearchView sites fixed 2026-08-14)

**The gap, stated plainly.** `IOS-PERF-001` enumerated **18 sites / 7 violations / 2 mechanism-only** of
the QoS inversion, and its unit of enumeration was *"sites that HOLD one of our pools at the wrong
QoS"* — `Task.detached(priority: .utility)` and friends whose bodies transitively reach a `DatabasePool`
we own. That census was corrected **twice** (once for a base-scope error, once because the instrument
read the *line* rather than the *reachable work*) and closed with all violations fixed. **Every one of
those corrections was still about the holder side.**

The inversion has a second half: a **User-interactive thread that synchronously blocks on the pool.**
Nothing in `IOS-PERF-001` enumerated that half.

**The evidence that this half is real and not theoretical** is already in the Archive-search log
(`logmain_inbox_move_bug.log` lines 301–344): a `Thread Performance Checker` report reading *"Thread
running at User-interactive quality-of-service class waiting on a lower QoS thread running at Utility
quality-of-service class"*, with the blocked stack being `UIApplicationMain` → SwiftUI
`.onChange(of: query)` → `SearchView.onQueryChanged` → `SearchView.legacyLocalSearch` →
`PrioritizedDatabase.read` → `GRDB.DatabasePool.read` → `dispatch_sync`. The holder was at Utility; the
blocked party was the typing thread.

**What the Archive-search fix did and did not do.** `53d17514e` removed the *cost* — the 215k-row
`USE TEMP B-TREE FOR ORDER BY`, 833 ms → 4 ms on a 250k fixture. It did **not** remove the *blocking*.
`SearchView.legacyLocalSearch` still performs **two synchronous main-actor pool acquisitions per
keystroke**: the page read, and a second `SELECT * FROM account`. Because they are synchronous, a
Utility-QoS holder can stall typing for an **unbounded** time that has nothing to do with how cheap the
queries now are.

⚠️ **Cheap-but-synchronous is a smaller target, not a safe one.** Do not read the 4 ms figure as closing
this row.

**Prior art in-tree, which is why this is a gap and not a discovery.** `InboxViewModel.checkLargeInbox`
carries a comment describing this exact hazard and its resolution, for two `fetchCount`s over the same
folder set, fixed by moving to the async overload:

> Run both COUNT(*)s OFF the main actor (async dbPool.read overload). They are folderId-index-assisted
> (the `date <` one rides messageHeader_folderId_date), but on a large All Mail account even an index
> COUNT is non-trivial — doing it through the SYNC dbPool.read on @MainActor blocked the UI on EVERY
> inbox onAppear (tab switch / nav-back / foreground). Result only feeds a TipKit flag + UserDefaults,
> so computing it slightly later off-main is strictly better.

**The reasoning existed, was written down, and was never applied to the search field.**

## Why it was originally registered rather than fixed

The fix is an async conversion, and that is **not a local edit**. `SearchView.legacyLocalSearch` is
called from `SearchView.onQueryChanged` as `results = legacyLocalSearch(trimmed)` **above** the 150 ms
debounce, precisely so results appear instantly on the first keystroke. Making it `async` reorders
`onQueryChanged`: the synchronous assignment to `results` disappears, the debounce task becomes the only
writer, and the `legacyExtras` computation — which reads the `results` that the synchronous line just
populated — has to be restructured.

**That is a UX timing change, not a refactor:** local substring hits would land *after* the debounce
instead of immediately. Deciding that trade is a product call, not an audit call, so it is recorded
rather than taken unilaterally.

## Confirm or refute with one measurement

With the Archive-search fix in place, type 8+ characters in search while in All Archive on the owner's
device and grep the log for `Thread Performance Checker` and `MAIN THREAD STALL`. Expected after the
query fix: **zero** `MAIN THREAD STALL`. **If `Thread Performance Checker` inversions still appear while
stalls do not, that is exactly this row** — the block survives without the cost, and the async
conversion is the remaining work.

## ⚠️ Scope note for whoever takes it — enumerate by STATE

The census this row owes is *"every synchronous `dbPool.read` / `write` reachable from a `@MainActor`
context"*, enumerated **by state** — `AppDatabase.dbPool.read {`, `AppDatabase.dbPool.write {`,
`PrioritizedDatabase` sync overloads, App-Group `DatabaseQueue` access — **NOT** by grepping for
`legacyLocalSearch`-shaped callsites. **Grepping by shape is the mistake that produced the two
`IOS-PERF-001` corrections**, and repeating it here would reproduce the same partial census a third
time.

## Related

- `IOS-PERF-001` — the holder-side census this row is the missing half of.
- `IOS-PERF-011` — a confirmed member of this class, with no UX trade-off blocking its fix.
- `53d17514e` — removed the cost, not the blocking.

## 📏 Historical second confirmed member — `SearchView.ftsResultsToSearchResults` (fixed 2026-08-14)

The whole-SQL-surface audit enumerated this class **by state**, as the scope note above demands, and
found a second member in the same file as the founding one:

**`SearchView.ftsResultsToSearchResults` performs a main-actor N+1** — roughly **100 pool acquisitions
per debounced keystroke**, one per result row. It is the same shape as the `SELECT * FROM account`
that `53d17514e` removed from the *sibling* function, which is the detail worth noting: **that commit
fixed the N+1 in one function and left the identical pattern in its neighbour.** A fix that stops at
the function it was called about leaves the class open.

⚠️ **Labelled by SHAPE, not measured.** The audit could not measure it — it needs the running app, not
a database harness — so the ~100 figure is a count of acquisitions derived by reading, not a duration.
**Do not restate it as a millisecond cost.** What is established is the shape (per-row synchronous
acquisition on the main actor) and the count; what is not established is what it costs under
contention, which is precisely this row's thesis: the cost is unbounded and set by whoever holds the
pool, not by the query.

This strengthens rather than changes the row's disposition. `IOS-PERF-011` remains the cheapest member
to close (mechanical, no UX trade-off); this one sits behind the same `async` conversion question as
`legacyLocalSearch`, because it feeds the same synchronous result assignment.
