# IOS-PERF-011

- Register classification: `open`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN (2026-08-12)** — `SettingsView.loadOldMessageCount` is a **synchronous main-actor `COUNT(*)`**
over the inbox folder set — the exact hazard `InboxViewModel.checkLargeInbox` documents having already
fixed. Found while enumerating the `IOS-PERF-010` class; not reproduced from a user report.
Classification: **open**.

## Subsystem and search terms

`SettingsView.loadOldMessageCount`; `SettingsView.archiveOldMessages`; `SyncConfig.archiveAgeDays`;
`ArchiveOldEmailsTip`; synchronous `dbPool.read` on `@MainActor`; `fetchCount` on main thread;
`.task { loadOldMessageCount() }`; settings screen hitch; `folderId IN` + `fetchCount`;
`messageHeader_folderId_date` covering index; `InboxViewModel.checkLargeInbox` prior art;
member of the `IOS-PERF-010` blocked-reader class; unbounded `fetchAll` with no LIMIT

## Full detail

**The shape.** `SettingsView.loadOldMessageCount`, invoked from a `.task { }` in the view body, runs

```swift
try? AppDatabase.dbPool.read { db in
    try MessageHeader
        .filter(inboxFolderIds.contains(Column("folderId")))
        .filter(Column("date") < archiveCutoff)
        .fetchCount(db)
}
```

— the **synchronous** `read` overload, on the main actor, inside a view body's `.task`.

**It is NOT the sorter class. Verified, so the two are not conflated:** `EXPLAIN QUERY PLAN` gives
`SEARCH messageHeader USING COVERING INDEX messageHeader_folderId_date (folderId=? AND date<?)` — a
covering index, **no sorter**, no row materialisation. There is no `ORDER BY`, so nothing defeats early
termination.

This is purely a **member of the `IOS-PERF-010` blocked-main-thread-reader class**: the query is
index-assisted and cheap in CPU, but it is synchronous on the main thread and therefore **hostage to
whoever holds the pool.**

**Why it is worth a row despite being cheap.** This is precisely the case
`InboxViewModel.checkLargeInbox` already litigated and fixed, with a comment that generalises to this
site verbatim:

> They are folderId-index-assisted (the `date <` one rides messageHeader_folderId_date), but on a large
> All Mail account even an index COUNT is non-trivial — doing it through the SYNC dbPool.read on
> @MainActor blocked the UI on EVERY inbox onAppear (tab switch / nav-back / foreground). Result only
> feeds a TipKit flag + UserDefaults, so computing it slightly later off-main is strictly better.

**Both halves of that reasoning transfer exactly:** an index `COUNT` over an inbox-scoped predicate is
non-trivial at volume, and `loadOldMessageCount`'s result feeds only `oldMessageCount` — a label and a
confirmation-dialog threshold — **nothing that must be correct before first paint.**

**So unlike `IOS-PERF-010`, this one has no UX trade-off.** The async overload already exists, the
sibling fix is already in-tree as a template, and the value is display-only, so the conversion is
mechanical: switch to `await AppDatabase.dbPool.read` inside the existing `.task`.

## Adjacent, same function family, DIFFERENT sub-shape — recorded so it is not lost

`SettingsView.archiveOldMessages` runs `filter(folderIds IN).filter(date < cutoff).order(date.asc)
.fetchAll(db)` with **no `LIMIT` at all** — an unbounded materialisation of every old inbox message into
memory.

⚠️ That is **not** the sorter class — nothing defeats a limit, because there is no limit — and it is
`async` and behind an explicit user confirmation. It is a **memory-ceiling** question rather than a
UI-stall one, and it belongs here **only as a cross-reference, not as the same defect.**

## Why registered rather than fixed

`SettingsView.swift` was outside the file claims and outside the scope of the search-performance fix
during which it was found. The fix is mechanical and carries no product decision, so this is the
cheapest of the four rows in this family to close.

## Confirm or refute with one gesture

On an account with a large inbox, open Settings and watch for a hitch on appear; or instrument
`loadOldMessageCount` with a duration log and check whether the `.task` blocks the main thread while a
`.utility` holder has the pool.

⚠️ **"Fast when uncontended" does NOT refute it** — the defect is the *dependency on the holder*, not the
query cost. Refuted only if the sync read consistently returns in single-digit ms **under contention**.

## Related

- `IOS-PERF-010` — the class this row is a confirmed member of, and its by-state census scope note.
- `IOS-PERF-001` — the holder-side census that missed this half.
- `InboxViewModel.checkLargeInbox` — the in-tree template for the fix.
