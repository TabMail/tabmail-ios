# 157. A keyset page's tie-break must be in the index it walks

**Status:** Current (2026-11-24, iOS #1370).

**Search terms:** keyset paging; cursor; tie-break; equal dates; tie group; row value; `(date, rowid) < (?, ?)`;
`rowid`; `INDEXED BY`; `USE TEMP B-TREE FOR LAST TERM OF ORDER BY`; `messageHeader_folderId_date`;
`SyncEngine.bulkIndexPage`; `bulkIndexWalk`; VM steps; `sqlite3_stmt_status`; `SQLITE_STMTSTATUS_VM_STEP`.

## The fact

A keyset page `WHERE folderId = ? AND date <= ? AND (date < ? OR (date = ? AND id > ?)) ORDER BY date DESC, id ASC
LIMIT n` seeks `messageHeader_folderId_date (folderId, date)` to the cursor's date, but `id` is not in that index.
SQLite then reads EVERY row that shares the cursor's date, filters them on `id` and sorts them
(`USE TEMP B-TREE FOR LAST TERM OF ORDER BY`), on every page. Paging through a run of N headers with one date costs
about N rows per page, N²/n in all. IMAP dates are INTERNALDATE to the second, so an import can give thousands of
headers one date.

Measured on the host (SQLite 3.54, a 55-column header-like table, 2,000 headers sharing one date, page of 200):
first page 12,808 VM steps; a page in the middle of the run 101,468 with the `id` tie-break; 14,225 with the fix.

## The rule

Break the tie with a column the index already holds. Every index entry ends with the table's rowid, so
`(folderId, date)` is really `(folderId, date, rowid)`:

```sql
SELECT *, rowid AS bulkIndexRowID FROM messageHeader INDEXED BY messageHeader_folderId_date
WHERE folderId = ? AND (date, rowid) < (?, ?)
ORDER BY date DESC, rowid DESC LIMIT ?
```

The plan is `SEARCH ... (folderId=? AND (date,rowid)<(?,?))` with no sort: each page reads only its own rows.
Keep the cursor's date as the stored `DatabaseValue`, not a `Date` re-encoded. A rowid is stable while its row
exists (an UPDATE keeps it; a replace or a delete-and-insert gives a new one; a `VACUUM` keeps the rowids of a
table with an index, measured, though SQLite documents only that it may renumber a table without an INTEGER
PRIMARY KEY; an `incremental_vacuum` step moves pages, not rows), so it suits a cursor that lives for one pass, not
one that is stored. (Corrected 2026-11-25, #1450: this said that a full VACUUM renumbers rows and that the app runs
one only after deleting all mail; the one-time upgrade the user starts now also runs one per database, to switch it
to `auto_vacuum = INCREMENTAL`, ADR-IOS-121.) `INDEXED BY` is needed when another index gives the same order (`messageHeader_date` does), because a
planner that took it would walk every folder to fill one page.

Measure a page's cost from the statement as it ran: SQLite's profile callback (`sqlite3_trace_v2` with
`SQLITE_TRACE_PROFILE`) installed on every connection of the test pool reports each finished statement with its SQL and
`sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1)`, so every read the code made is seen and costed on the
connection that ran it, bound values and the reader's statistics included. Re-running a statement from its
`expandedDescription` on another connection is weaker: bound values become literals, which can change the plan
(IOS-PERF-004), and the other connection may hold other statistics; a filter on the expected statement text also
misses an extra read the code makes. Keep the old shape as a control
(`SyncEngineFTSBulkIndexTests.everyPageReadsOnlyItsOwnRows`).

## Where else the shape appears

`InboxListReader.durableQuerySQL` pages the inbox by `(date, id)` too, and its display indexes
(`messageHeader_inbox_display`, `messageHeader_triage_display`) do not hold `id` either; a page of 50 inside a large
run of equal dates re-reads the run. Its cost is measured in `InboxListReader`'s comment on the `ORDER BY`: the sort
is bounded by the `LIMIT` plus the tied-second block straddling it (`USE TEMP B-TREE FOR LAST TERM OF ORDER BY`, 0.24 ms
at 100k on a Mac; triage sorts one whole tag bucket, 1.91 ms), so it is small for the inbox; IOS-SCROLL-004 owns that
ordering.
