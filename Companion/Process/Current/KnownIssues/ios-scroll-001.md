# IOS-SCROLL-001

> Routed from `KNOWN_ISSUES.md` line 583 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `4d5287892bed4fe4092017ee37fda27baf1bc32d9c101ab9f1e1d62c5739fce1`

## Status

✅ **CLOSED AS A DECISION (2026-08-05)** — the progress half is a TERMINATION guard, not a coverage claim, and `runBackfill`'s coverage-advancing UID walk delivers the mail beyond the stalled page anyway; the cell below states all five closure elements, including the non-recovering case by name. **Its full statement is preserved verbatim below. Original disposition, retained as history:** 🔓 **OPEN** — accepted, recoverable without a user gesture; the coverage half of the same decision is ✅ fixed, this is the PROGRESS half, which is a termination guard and not a coverage claim

## Subsystem and search terms

Infinite scroll; `SyncEngine.fetchOlderMessages`; `mayHaveMore`; `FetchCoverage.serverRecordCount`; full page, zero inserts; `\Deleted` page; no UIDPLUS; soft-deleted source copy; `runBackfill` UID walk; `backfillComplete`

## Full detail

Continuing to page requires BOTH *coverage* (`found >= SyncConfig.infiniteScrollFetchLimit`, now the SERVER's own record count) and *progress* (this folder materialised at least one new row). **A full page in which EVERY record is skipped therefore stops paging.** The reachable instance is a page whose every record the server reports `\Deleted` — routine on a server without UIDPLUS, where each completed move leaves a soft-deleted source copy behind that `IOS-IMAP-001`/D3 deliberately refuses to materialise. **Why the progress half is not simply dropped:** this pull's cursor IS the folder's oldest local row (`oldestDate`), so a round that inserts nothing would re-ask the identical window forever. Removing the guard trades a bounded gap for an unbounded spin. **Why the fix is not a persisted page cursor:** that is a new column and a new migration to close an edge that already recovers. **Recoverability, with the non-recovering case named:** `SyncEngine.runBackfill`'s UID-range walk advances its cursor on COVERAGE (`UIDWalkCursor.confirmRange` fires when a range is ACCOUNTED FOR, not when it inserts), so the mail beyond the stalled page still arrives locally and the next reset re-arms the scroller; it is invoked by `SyncEngine.startBackfill` after every sync and by `SyncScheduler`'s BGProcessing pass. It does NOT recover a folder wrongly marked `backfillComplete` by the `.fresh` branch when the server reports no UIDNEXT — ~~that case is registered separately and is not reachable by ordinary sync~~ ⚠️ **CORRECTED 2026-08-04: it was NOT registered separately. No such row existed** — the id space held no `IOS-BACKFILL-001` and nothing else described the case, so this sentence discharged a named non-recovery by pointing at a register row that had never been written (`MIS-024`: a "covered by X" is a claim about X's existence and reachability, and both must be checked in the same sentence). The case is real and is **now** `IOS-BACKFILL-001` below, where it is ✅ **FIXED**; the "not reachable by ordinary sync" half was true and is preserved there (it needs a server that omits a REQUIRED response code).
