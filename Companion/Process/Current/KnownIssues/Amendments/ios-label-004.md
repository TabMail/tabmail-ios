# IOS-LABEL-004

> **Post-freeze amendment to a BASE-register record.** Added 2026-09-04 through the amendment
> surface described in `Scripts/compact_known_issues.rb`. The base record's own bytes are
> hash-pinned and are **not** edited by this file:
> `Companion/Process/Current/KnownIssues/ios-label-004.md` keeps its original row and its original
> SHA-256. This file only **adds** the fact that the guard the row is about no longer exists.

- Register classification: **UNCHANGED — still `closed-decision`.** Nothing here re-opens the row;
  the residual it registered has become unreachable by construction rather than by rarity.
- Amends: the base record's "the guard is kept" status line, its reachability derivation, and its
  closing "reconsider if the guard ever starts firing" watch.

## What changed

The defensive guard this row is about — `guard try MessageHeader.fetchOne(db, key: header.id) == nil
else { …SKIPPING insert for id=… — already exists (post-snapshot)…; continue }` immediately before
`header.insert(db)` — was **deleted from both arms** of `SyncEngineDeltaSync.swift`
(`gmailDeltaSync` and `exchangeDeltaSync`) on 2026-09-04, together with its `[MoveTrace]` line
(the Gmail one on the `.queue` channel via `deltaMoveTraceLog`; the Exchange one a bare `print`).
In its place is a comment at each `header.insert` stating the invariant below. The
`[MoveTrace] deltaSync` census is therefore **six** sites, not seven
(`GmailDeltaMoveTraceLogTests`, the `deltaMoveTraceLog` doc comment, and the `IOS-QUEUE-008`
amendment were updated in the same commit).

## Why: the guard was unreachable, not merely rare

Both arms have the same shape inside ONE `DatabasePool.write` transaction: **PK read #1** —
`if var orphaned = try MessageHeader.fetchOne(db, key: header.id)` (orphan reclaim) — whose `else`
branch runs the Sent-dedup block (`optimisticDedupSQL` → `MessageBody.deleteOne(oldId)` →
`optimistic.delete(db)`) and then **PK read #2**, the guard, then the insert. The two reads are the
same statement on the same key in the same transaction, so they can only disagree if a
`messageHeader` row is written under `header.id` between them:

- **No other writer can interleave.** `DatabasePool` serialises in-process writers and SQLite's
  write lock excludes the NSE process; a write transaction's snapshot is fixed at `BEGIN`. A
  concurrent delta pass, the NSE, an optimistic sent insert in another transaction, or a row
  committed before this transaction began are all seen identically by BOTH reads and land in the
  orphan-reclaim arm or the by-columns `existing` update arm — never at the guard.
- **The only in-window `messageHeader` write is a DELETE** (`optimistic.delete(db)`, plus its
  cascades onto child tables; `MessageBody.deleteOne` touches only `messageBody`). A delete cannot
  make a nil read become non-nil. The dedup predicate (`messageId <> ?`) also proves the deleted row
  is never `header.id`.
- **No trigger and no callback can insert.** The four `messageHeader` triggers created by v85 are
  all dropped by `v87_retireDirectAIPending`; there is no other non-comment `CREATE TRIGGER` in
  `AppDatabase.swift`, and `MessageHeader` declares no GRDB `willInsert`/`didDelete`-style
  persistence callback (`rg "func (will|did|around)(Delete|Insert|Save|Update)\("` over
  `TabMail/ Shared/ TabMailNotificationService/` is empty).
- **The loops never revisit a `(folder, messageId)` pair.** `details` is built from `Array(toFetch)`
  where `toFetch` is a `Set<String>`; and even a repeated id would hit the by-columns `existing`
  read on its second visit and take the update arm, never the "new message" arm. Two `Folder` rows
  sharing one `path` ("sibling folder iteration") reach PK read #1 on the second folder and are
  reclaimed there. ⚠️ This corrects the base row's reachability sketch, which needed "the same
  provider message appearing twice in one batch" to reach its condition (b) — that path never
  reached the guard either.

Coverage agreed: with the full 9,459-test suite under `-enableCodeCoverage YES`, the Gmail guard
line ran 3 times and its `else` body **0**; the Exchange guard line ran once and its body **0**.
The round-2 test-coverage review's own attempt to construct the site concluded that only a
test-installed SQLite `AFTER DELETE` trigger — a writer that does not exist in production — could
fire it. Deletion-first applied: a mechanism whose only reachable trigger is a manufactured one is
removed, not pinned.

## What the deletion changes, and what it does not

- The residual this row registered — "when the guard fires, the carried body and user-label
  membership are dropped" — is now **moot**: the insert always runs after the dedup carry, so the
  carried body and labels are always re-attached.
- The base row's stated alternative, "a thrown `UNIQUE` constraint that aborts the whole delta
  transaction for every folder in the pass", is now the behaviour on the (unreachable) collision —
  and it is the correct one. A `UNIQUE` throw rolls back the whole batch transaction. **The
  `lastHistoryId` / deltaToken advance is a SEPARATE `dbPool.write` at the end of each arm**, so
  the cursor stays put. What a rollback leaves behind: the earlier messages-deleted write, which is
  its own already-committed transaction whose deletes are idempotent on the re-run, and nothing
  else from the batch (no header, no `PendingOperation` tag op, no dedup delete, no body move). The
  next delta pass re-fetches the same history from the same cursor and the orphan-check read
  reclaims any row already occupying the id. No retry, no new mechanism.
- The "reconsider if the guard ever starts firing" watch is **retired**. Its witness line is gone;
  the loud witness now is a thrown `UNIQUE constraint failed: messageHeader.id` surfacing from
  `performDeltaSync`, which the delta callers in `SyncEngine.swift` already propagate as an
  ordinary sync error (they retry only on connection errors).
- **Not touched:** the full-sync twins in `SyncEngineFullSync.swift` (`[Sync] Dedup: SKIPPING insert
  … (post-snapshot)`, `[Sync] DraftDedup: …`, `[MoveTrace] fullSync — SKIPPING insert …`). Full sync
  has a different read structure — `SyncEngineRunSyncTests` documents a reachable shape for its
  dedup guard (a row occupying the PK whose `folderId` points elsewhere) — so this deletion's
  premise was not evaluated there and nothing there was changed. The sibling `[Sync] Gmail delta
  dedup:` / `[Sync] Exchange delta dedup:` `print` lines are likewise untouched.

## Search terms

post-snapshot guard removed; unreachable guard; `SKIPPING insert for id`; `already exists
(post-snapshot)`; two PK reads one transaction; snapshot isolation; `DatabasePool.write` writer
serialisation; `optimistic.delete(db)`; v87 triggers dropped; `lastHistoryId` separate transaction;
UNIQUE rolls back batch; orphan reclaim; `deltaMoveTraceLog`; six `[MoveTrace] deltaSync` sites;
`IOS-QUEUE-008`; deletion-first
