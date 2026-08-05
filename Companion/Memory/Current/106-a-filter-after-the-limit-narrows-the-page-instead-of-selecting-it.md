# A filter applied AFTER a query's `LIMIT` narrows the page instead of selecting it — and every downstream "did we reach the end" decision inherits the lie

**Status:** Current. Landed 2026-08-04 on `v3`. Two members, one class, one layer above
`6d460aa99` (`FetchCoverage`) and one layer below it.

---

## The class, stated once

**A count that gates "is there more" must describe what the SOURCE had left, never how many
rows survived narrowing that happened after the source was asked.** `6d460aa99` closed this
for the SYNC layer (a `compactMap` parse-survivor count read as server coverage;
`selectStaleHeaders` now takes `coverage:` in place of `limit:`). The two members below are
the same class at the DISPLAY layer and at the CRAWL layer — and in both of them the
narrowing was avoidable, so the fix is to move the narrowing rather than to carry a
compensating signal past it.

Both members are shared **verbatim** by the reference branch `v2final` (`e28dd4edb`) and by
shipped `07a4bb703` / `v1.6.38`. The reference is a floor here, not a design to restore.

---

## Member 1 — the inbox label filter ran after the SQL `LIMIT`

### The shape

`InboxListReader.gather` built the durable (D) query per folder — `folderId`,
`headerComplete`, optional `isRead`, optional `date < beforeDate`, mode ordering — and ended
it with `.limit(query.targetCount)`. The **label** filter was not in that query at all: it
lived in `InboxListComposer.compose` step 6, in memory, over the rows the `LIMIT` had already
chosen.

So `compose`'s output was a post-filter SURVIVOR count, and two things read it as a statement
about the source:

1. `InboxViewModel.hasMoreMessages`, written at three sites — `resetMessages` and
   `reloadMessages`' `applyDiff` (`loadedMessages.count >= targetWindowSize`) and
   `loadMoreMessages` phase 1 (`nextPage.count >= SyncConfig.inboxPageSize`). Filtering by a
   label with 2 hits in the newest 50 rows gave `2 >= 50 == false`: the folder was reported
   exhausted and every older match became unreachable by scrolling.
2. The pagination cursor `loadedMessages.last?.date`, which named the oldest SURVIVING row
   rather than the oldest row EXAMINED — and is `nil` outright when nothing survived.

The second is why this could not be closed by carrying a coverage flag out of the reader. A
`hasMoreMessages` that stays true while the composed page is empty re-arms `InboxView`'s
infinite-scroll sentinel — `if viewModel.hasMoreMessages { Color.clear.onAppear {
viewModel.loadMoreMessages() } }` — on every render, while the cursor cannot advance. That is
an unattended network pull of the entire mailbox: the **mirror image** of the bug
(`MIS-005`), reached by "fixing" only the signal.

### The fix

Move the filter ahead of the `LIMIT`. `InboxListReader.gather` now ANDs one
`EXISTS (SELECT 1 FROM messageUserLabel WHERE messageUserLabel.messageId = messageHeader.id
AND messageUserLabel.userLabelId = ?)` per selected id (`filterLabelIds` is an `isSubset`,
i.e. an AND) into the D query, sorted for a stable statement shape. `compose` step 6 is
UNCHANGED and still required: P rows are fetched by id and S rows synthesize with
`userLabels == []`, so they have no SQL leg at all.

This is `CLAUDE.md` **A3** applied literally — *"what would this mechanism cost if the sibling
simply didn't do that yet?"* The answer was "it would not need to exist", so the deviation was
the sibling's ordering.

### A6 (database-performance lens), measured

`EXPLAIN QUERY PLAN` on the real schema, both modes:

```
SEARCH messageHeader USING INDEX messageHeader_inbox_display (folderId=? AND headerComplete=?)
CORRELATED SCALAR SUBQUERY 1
  SEARCH messageUserLabel USING COVERING INDEX sqlite_autoindex_messageUserLabel_1 (messageId=? AND userLabelId=?)
```

- The driving index is **unchanged** (`messageHeader_inbox_display`, or
  `messageHeader_triage_display` in triage mode), so ordering still comes from the index.
- Each label probe is a **covering**-index seek on `messageUserLabel`'s PRIMARY KEY
  (`messageId`, `userLabelId`) — no table access, no new index, **no migration**.
- Triage mode's `USE TEMP B-TREE FOR LAST TERM OF ORDER BY` is **pre-existing**: it appears
  identically in the no-label baseline plan. Not candidate-attributable.
- Cost model: the `LIMIT` is satisfied after examining as many candidate rows as the filter
  needs; worst case (a label matching nothing in the folder) is one covering-index seek per
  row in the folder. That replaces a version that examined 50 rows and gave the WRONG answer.

### What was deliberately NOT changed

All three `hasMoreMessages` write sites still compare a composed count against a page size,
and the residual narrowings compose still applies after the `LIMIT` are enumerated in
`KNOWN_ISSUES.md` `IOS-SCROLL-002` (overlay folder-drop; `excludeIds`, triage-mode only;
the P/S-only unread and `beforeDate` cuts; the `isSystem`/`shouldExcludeLabel` corner of the
step-6 belt). Every one fails CLOSED and is transient, and `reloadMessages` re-arms the flag
from a fresh D query with no user gesture — invoked by `runReloadCoalesced` from the
`.inboxDataDidChange` observer, and by `listDidAppear`.

---

## Member 2 — a SELECT that reported no UIDNEXT permanently marked the folder fully crawled

### The shape

`SwiftMail/IMAP/Models/Mailbox.swift` declares `public var uidNext: UID = UID(0)`, and
`SelectHandler` assigns it **only** when the wire carried `* OK [UIDNEXT n]`. So "the server
did not say" reached `SyncEngineBackfillWalk`'s `.fresh` branch as the number **0**.
`initialCursor = uidNext - 1` was then `-1`, which took the `initialCursor < 1` early-out —
a branch written for UIDNEXT **1**, the one value that PROVES the mailbox never held a
message (RFC 3501 §2.3.1.1: UIDs are assigned strictly increasing from 1) — and wrote
`backfillComplete = true`. Completion removes the folder from `remaining` on every later
pass, so **nothing ever revisited it**.

`uidNext == 1` is *evidence of an empty mailbox*. `uidNext == 0` is *absence of evidence*.
They must not take the same branch. This is `MIS-IOS-004`, the most repeated defect in this
codebase's history.

### The tell was already in the file

`IMAPProvider.getUidNextWithEpoch` read:

```swift
return (Int(selection.uidNext.value), observed != 0 ? observed : nil)
```

**One of the two absent-evidence values was normalised and the other was not**, on the same
line, for the same wire reason (both are `nz-number`, so zero is unreportable). An asymmetry
between two sibling values handled at one site is worth reading as a defect report.

### The fix

`getUidNextWithEpoch` returns `uidNext: Int?` and normalises `0 → nil` symmetrically with the
epoch, so absence of evidence is **unrepresentable as a number** at the decision site — the
same property `6d460aa99` achieved by replacing `limit:` with `coverage:`. The `.fresh`
construction guards `observation.uidNext == nil` and declines the folder
(`epochDeclinedFolderIds.insert`, `continue`), leaving the row exactly as the pass found it:
`backfillComplete` false, no cursor, no stamp, so the next call meets the same preconditions
and retries. Only one of the four `getUidNextWithEpoch` call sites reads the `uidNext`
component; the other three (`AccountManagerUidValidityReset.observeFreshUidValidity`, the
walk's `.resumed` branch, `SyncEngineSelfHeal`) use `.observedEpoch` only.

The `initialCursor < 1` completion path is **unchanged** and still fires for UIDNEXT 1,
together with NB3's epoch bootstrap in the same transaction — so a genuinely empty folder
still settles and stays gestureable. Both directions are pinned, because fixing only the
refusal manufactures an unbounded re-crawl of every empty folder.

The round-12 `crawlWalkWriteAllowed` quarantine guard and the shared-transaction epoch
bootstrap were both preserved (`MIS-018`: do not port a mechanism and leave its guard
behind).

---

## Test seam

`FakeIMAPServer.suppressSelectUidNext(for:)` / `restoreSelectUidNext(for:)` — the exact
sibling of `suppressSelectUidValidity`, and for the same reason: RFC 3501 §6.3.1 lists
UIDNEXT among SELECT's REQUIRED OK untagged responses, so **omission models a nonconforming
server** and is the only deterministic route to `UID(0)`. `setMessages(…, [])` is NOT
interchangeable — an empty mailbox makes the fake send a real `UIDNEXT 1`, which is the
opposite case.

---

## Register rows

`KNOWN_ISSUES.md` `IOS-BACKFILL-001` (member 2, FIXED, with its nonconforming-server
residual) and `IOS-SCROLL-002` (member 1's enumerated fail-closed residuals).

⚠️ `IOS-SCROLL-001` claimed member 2 was *"registered separately"*. **It was not** — the id
space held no such row and nothing else described the case. That sentence is corrected in
place rather than deleted. `MIS-024`: *"covered by X"* is a claim about X's existence and
reachability, and both belong in the same sentence as X's name.
