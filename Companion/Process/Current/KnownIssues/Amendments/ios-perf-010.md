# IOS-PERF-010

- Register classification: `accepted`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN — CENSUS COMPLETE; CONSCIOUS SURVIVORS RETAINED (2026-08-17)** — the two concrete
`SearchView` members are fixed and the complete by-state inventory is discharged below. Classification
remains **open** only for the explicitly classified synchronous survivors and their required
state-machine/evidence work; do not close GitHub #13 from this change.

⚠️ **SUPERSEDED DISPOSITION (2026-08-20) — this record is now `accepted`, not `open`, and GitHub #13 is
CLOSED by owner decision, referencing PR #57.** Everything above stays true and still governs; only the
disposition moved. The instruction *"do not close GitHub #13 from this change"* was correct for the
change it was written about (2026-08-17/18) and is spent, not withdrawn — the owner closed #13 from a
LATER judgement that the audit is complete, not from that change. Read *🧾 OWNER DISPOSITION 2026-08-20*
at the end of this file for the decision, the per-member classification table it does NOT relax, and the
reopening bar.

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

**Historical residual after the 2026-08-14 Search pass.** That pass did not certify every synchronous
database state reachable from every `@MainActor` context. The 2026-08-15 census below discharges that
inventory debt; this paragraph remains to show why the broader pass was required.

## 2026-08-15 complete census and bounded account-field closure

**Census revision and predicate.** At exact pre-change revision
`98dde448b8587c9a47828a8aaaf64ff5e747cdc6`, walk every tracked Swift source under `TabMail/`,
`Shared/`, and `TabMailNotificationService/`; select `read`, `write`, and
`writeWithoutTransaction` calls whose receiver has a GRDB pool/queue/writer/reader type; exclude
comment-only lines and `String`/`Data.write(to:)`; classify the synchronous overload when the call
expression contains no `await`. That semantically yields **662 GRDB accessor calls: 424 async and
238 synchronous (131 reads, 107 writes)**. Positive controls are `SearchView.openResult`, both
`UndoService.push` reads, `InboxListReader.fetchSync`, and both `InboxViewModel.lookupMessage` reads.
Negative controls are the PR-24-converted Search readers and `SettingsView.loadOldMessageCount`.
After this change, the same semantic predicate yields **662 total / 425 async / 237 synchronous
(131 reads, 106 writes)**: exactly the account-field write moves from the synchronous to the async
class. The earlier receiver-name heuristic missed the replacement because its local receiver is named
`database`; its static type is still `PrioritizedDatabase`, and `AccountFieldPersistenceStore.persist`
is now an explicit positive control. The change therefore never reduced query count.

The pre-change arithmetic closes as follows; no member is inferred safe merely because its query is
cheap:

| Synchronous state bucket | Count | Main-actor disposition |
|---|---:|---|
| Actor-isolated Search/Memory/Sync/Chat/Draft stores | 118 | Runs on the owning actor; 12 static/nonisolated members were caller-traced separately |
| `PrioritizedDatabase` sync overload implementations | 3 | Mechanism, not a caller |
| Notification-service process/test-only `NSEStagingDB` | 8 | Not in the main-app target |
| Preview/demo/screenshot-only | 8 | Not a production state |
| Sidecar/App-Group queues | 30 | Five `BodyAssetStore` states are MainActor-reachable but do not contend for the main pool |
| Cold-start initialization/migration | 9 | Pre-UI, pre-contention |
| Proven off-main actor/detached work | 15 | Caller/gate traced, including NSE mirrors/merge and thread detection |
| Main-app MainActor-reachable synchronous | 47 | 41 reads and 6 writes before this change; now 46 synchronous states, plus the converted async write |

Including two nonisolated `DraftStore.load` callers and five MainActor-reached `BodyAssetStore`
sidecar states, the complete pre-change MainActor-reachable synchronous set is **54**; this change
leaves **53 synchronous states** and one converted async state.
The direct main-app path families are: `NavigationStore.loadInitialData`; `InboxListReader.fetchSync`;
`InboxViewModel` folder/account/message/role/undo/label reads; `MessageDetailViewModel` action/body
reads; `SearchView.openResult`; `InboxView` draft-tap and move-picker reads; `ComposeView` account,
edit-context, quote, and suggestion reads; `UndoReopenCompose`; `PendingSendService.undo`;
`MailNavigationView` draft classification; label/filter menus; account/reply-all compose helpers;
the Device-Sync AI-cache probe; `AIChat`/cached-user-email lookups; `AccountDetailView`; the two
`AccountManagerOutbox` decision writes; and the debug-gated `UndoService.push` diagnostics. The
adjacent ungated deletion diagnostic discovered by the same predicate belongs to the
`IOS-PERF-016` recurrence audit, not to this bounded change.

**The fixed high-frequency invariant.** `AccountDetailView.saveAccountField` was byte-identical in
shipped `v1.6.38`: Name, Email, and IMAP username field setters synchronously entered GRDB's single
writer on every keystroke (the same helper also persisted signature placement and focus-loss
signature commits). A synchronous `PrioritizedDatabase.write` cannot await `DatabaseWriteQueue`, so
it bypassed priority ordering and blocked MainActor behind the current SQLite writer. The replacement
updates the field and `NavigationStore` before returning, then the app-lifetime
`AccountFieldPersistenceStore` chains each account's persistence tasks behind their predecessor and
uses the async priority writer. No live-account intent is cancelled or coalesced; accepted order is
durable order, so a
rapid edit remains last-write-wins even across pop/re-enter. A pending or failed account+field value
overlays `NavigationStore.refresh` until a post-commit refresh actually observes it on disk, so a
stale refresh cannot revert accepted presentation. Failures are stored and presented independently
per account+field with Retry; a superseded failure cannot overwrite newer UI, and a successful retry
clears only its own field. Account-row removal is authoritative: it drains a write already admitted
to GRDB, purges retry/overlay state, and fences queued closures; deliberate fixed-id demo recreation
opens a clean lifecycle. A zero-row `UPDATE` is therefore handled as account disappearance rather
than a false success. SQL remains one `UPDATE account ... WHERE id = ?`; query count, schema, and
index requirements are unchanged.

**Consciously classified survivors — keep this record and GitHub #13 open.**

> ⚠️ **The "keep GitHub #13 open" half of that heading is SUPERSEDED (2026-08-20): #13 is CLOSED and this
> record is `accepted`. The "consciously classified survivors" half is NOT — every classification,
> proof, trip-wire and DO-NOT-TOUCH instruction below is unchanged and still binding.** See
> *🧾 OWNER DISPOSITION 2026-08-20* at the end of this file.

- `SearchView.openResult` remains one indexed one-row lookup on an explicit tap. The synchronous
  overload intentionally skips the async read-through NSE merge, which has measured multi-second
  suspension potential; the read revalidates rendered identity, and inserting an `await` would admit
  a second tap between decision and navigation/alert application. Shipped `v1.6.38` skipped local
  revalidation and therefore is not an architecture to restore. Keep this site synchronous unless a
  generation/cancellation design and device evidence justify the added state machine.
- Inbox/detail gesture lookups and label reconciliations preserve visualized-snapshot, undo,
  destination, and atomic read-then-observable-mutation rules. They are indexed/small-set and benefit
  from the 64-reader pool backstop; naive suspension would reopen action reentrancy/order defects.
- `InboxListReader.fetchSync`, initial folder resolution, and `NavigationStore.loadInitialData` retain
  the documented first-paint/pagination and cold-start contracts. Render/on-appear reads in compose,
  draft routing, move/label pickers, and thread cards remain scheduling exposure, but are bounded and
  have no measured surviving stall; converting them requires tri-state/loading machinery rather than
  a local scheduling edit.
- `UndoService.push` reads are reachable only after the debug-logging gate and are not ordinary
  production work. The Device-Sync AI-cache probe remains a background-triggered 2N MainActor read
  shape and needs its own set-wise result-equivalence proof before conversion.
- Five synchronous MainActor writes remain after this closure, and this record now CLASSIFIES each
  rather than restating the count (2026-08-18, HEAD `cdf11a6e5`; GitHub #13). **Record-accuracy
  correction to the earlier wording, which used the FILE name as a type qualifier:**
  `retryOutboxMessage(_:)` and `discardOutboxMessageConfirmed(_:)` are `nonisolated func … -> Bool`
  **declared in the file `AccountManagerOutbox.swift`** — that file is a single `extension
  AccountManager`, so **`AccountManagerOutbox` is NOT a type**; the declaring type is **`actor
  AccountManager`**. Being `nonisolated`, both run on the CALLER's thread, which for the Undo-Send
  state machine is the `@MainActor`. The five, by member:

  1. `AccountDetailView.setFolderRole(_:role:)` — **inconclusive; DO NOT TOUCH.** Conversion requires
     per-account ordered persistence (see Members 1–3 below).
  2. `AccountDetailView.assignRole(_:to:)` (one synchronous write holding two `UPDATE`s) — **same.**
  3. `AccountDetailView.clearRole(_:)` — **same.**
  4. `AccountManager.retryOutboxMessage(_:)` — **inconclusive; held synchronous for symmetry with its
     pair; DO NOT TOUCH.**
  5. `AccountManager.discardOutboxMessageConfirmed(_:)` — **MUST STAY SYNCHRONOUS** (consciously
     synchronous, the same disposition as `SearchView.openResult`).

  **Member 5 — the proofs (why an `await` here reopens `IOS-OUTBOX-006`).**
  - **Proof A (the deadline).** `SyncConfig.outboxUndoHoldSeconds = 5` and
    `SyncConfig.outboxClaimBufferSeconds = 1`, so `OutboxMessage.holdUntil` is set to `queuedAt + 6 s`,
    where `queuedAt` is not a stored column but the `Date()` captured in
    `AccountManager.persistQueuedSend` — **before** that function's `saveAttachments` disk write and
    its awaited `AppDatabase.dbPool.write`. The toast's Undo window is anchored to a DIFFERENT instant:
    it starts at `PendingSendService.present()`, which `ComposeView` calls only **after** that awaited
    persist returns, and it renders the Undo button for the first 5 s from there. So the button's t=0
    is `queuedAt + Δ`, where Δ is the attachment-save + DB-write time between the two anchors: a tap at
    the visible ≈4.9 s mark has roughly `(1.1 - Δ)` s of budget before `atomicClaim` flips the row
    `.sending` — near ≈1.1 s for a small send on an idle device, and shrinking toward zero (or below)
    as Δ grows for a large-attachment or contended send. The synchronous
    `discardOutboxMessageConfirmed` waits only on GRDB's writer queue; the async
    `PrioritizedDatabase.write` overload additionally awaits `DatabaseWriteQueue.acquire(.priority)`
    (whose own comment records a 3-row `merge.phase1` upsert taking multiple seconds). Converting ADDS
    that wait INSIDE that already-Δ-eroded budget → the drain claims the row → the discard then refuses
    on `.sending` → `PendingSendService.undoFailureMessage = "Try again."` with the Undo button no
    longer rendered and **the mail delivered**. That is the `IOS-OUTBOX-006` end state (BLOCKING,
    non-registrable — a delivered message for which the user was shown the `RootView` "Couldn't undo"
    alert with body `PendingSendService.undoNotConfirmedMessage` ("Try again.") and the Undo button
    already gone; nothing recovers the delivered mail). The Δ gap only sharpens this — a smaller real
    budget is more reason to keep the write off the async queue, never less. Keeping this write
    synchronous is therefore a deliberate design decision / accepted limitation, not an unaddressed
    perf smell — the in-code annotation on `discardOutboxMessageConfirmed` is the durable guardrail
    against a future pass re-flagging and converting it.
  - **Proof B (reentrancy).** `RootView` wires `PendingSendToast(onUndo: { if let snapshot =
    pendingSendService.undo() { … } })` — a synchronous decide-then-apply whose return drives a
    `fullScreenCover`. An `await` forces a `Task {}` at a Button that is NOT disabled, so a second tap
    re-enters `undo()` before the first cleared `current`; the second `discardOutboxMessageConfirmed`
    returns false (row already deleted) and sets `"Try again."` on a SUCCESSFUL undo — the mirror
    image of the R16-9 defect.
  - **Proof C (memory 104).** `retainedAuthorityOutcome(for:)` authorises; the discard is the write it
    authorises; inserting a suspension between them is the read-latch-then-await-then-mutate class that
    produced `IOS-OUTBOX-006` (`Companion/Memory/Current/104-…`; and `103-…` — `await dbPool.read` is
    NOT a short suspension: its async overload runs a full NSE staging merge, measured 7.6 s on a
    cold-I/O boot, and staging is pending precisely on foreground return). Also
    `PendingSendService.present()` can replace `current` across the suspension, so
    `dismissTask?.cancel(); current = nil` would clear the NEWER toast.
  - The `OutboxRow` swipe caller ("Cancel Send" while `isHeld`) sits inside the same hold window, so
    splitting sync/async variants would give one invariant two writers. Outbox Reliability Rule 3
    (`sentAt` before delete — the double-send firewall) and Rule 10 (cannot discard a `sending`
    message) are the rules the end state violates.

  **Member 4 — the weakest, still no-touch.** Durable admission is a SQL CAS
  (`WHERE id = ? AND status = 'failed' AND sentAt IS NULL`, `changesCount == 1`), so D1 survives an
  async conversion, and retry does NOT rewrite `holdUntil`, so Proof A does not apply. But the doc
  comment records `NavigationStore`'s 100 ms refresh debounce leaving a stale `.failed` snapshot
  visible after a first Retry already queued the row — an `await` widens that window; a repeat tap off
  the stale snapshot is then refused silently (the `Bool` result discarded) → an unresponsive-feeling
  Retry — and its side effects are documented as "mirroring `discardOutboxMessageConfirmed`", so
  converting one half of a deliberately symmetric pair is the fix-at-one-entry-of-two shape that
  `IOS-OUTBOX-006` warns against. **Trip-wire for the record: if `retryOutboxMessage` ever starts
  writing `holdUntil`, it moves under Proof A and this inconclusive classification no longer holds.**

  **Members 1–3 — the folder-role writes.** What the synchronous write currently guarantees:
  (1) atomic role reassignment (both `UPDATE`s in one transaction — survives conversion);
  (2) **gesture order == durable order — this does NOT survive.** Two unstructured `Task { await write }`
  dispatched from the `@MainActor` have no mutual ordering (`DatabaseWriteQueue` is FIFO by arrival at
  `acquire`, set by the cooperative pool, not by tap order). Concrete loss: long-press → assign Trash
  to F1, immediately reassign to F2; task B may arrive first; the final durable state is the user's
  EARLIER intention, silently — a **NEVER DROP USER INTENTION** violation. This is exactly what
  `AccountFieldPersistenceStore` (in `NavigationStore.swift`) spends ~200 lines solving (per-account
  tail chaining), and roles need per-ACCOUNT keying (overlapping row sets), so the existing store's
  keying does not transfer unchanged. (3) write-then-read coherence with the synchronous
  `reloadFolders()` — the "failure visibly reverts" property that keeps `IOS-SETTINGS-002` classified
  `accepted`. Honest narrowing (record this): the synchronous write buys consistency only against
  `@MainActor`-sequenced readers — `SyncEngineBackfillWalk` etc. capture `folder.role` into memory
  across long loops and can already act on a stale role; and the `folder_retireDirectAIOnInboxRoleExit`
  trigger was dropped by migration v87 (PR #39 retirement), so no trigger fires on a role change at
  HEAD. Net: conversion needs new ordering machinery for three context-menu gestures on a
  tens-of-rows table with no measured stall. If a stall is ever measured, the fix is a per-account
  serial tail modeled on `AccountFieldPersistenceStore`, NOT a bare `Task { await write }`.
  `IOS-SETTINGS-002` stays `accepted`, unaffected by this record.

  **HEAD re-verification (`cdf11a6e5`).** Re-counted against census revision `98dde448b`: exactly one
  synchronous MainActor write has been REMOVED since that revision (the `AccountDetailView`
  account-field write → async `AccountFieldPersistenceStore.persist`), **none has been added**, and
  **five remain** — the three folder-role writes plus the two `AccountManager` Outbox decision writes
  above. There is **no `Thread Performance Checker` evidence in-tree** for any of the five, and (per
  `IOS-PERF-011`) "fast when uncontended does NOT refute it": the exposure is real-but-unmeasured, and
  this census is **revision-bound, not a certification**. Cross-links: `IOS-OUTBOX-006`; memories 103
  and 104; Outbox Reliability Rules 3 and 10; `IOS-SETTINGS-002` (`accepted`, unaffected);
  `IOS-PERF-011`.

The census is revision-bound, not a future-proof certification. No surviving member has a measured
post-PR-24 user-visible stall; the synchronous-write subclass is justified by its unmitigated single
writer dependency, while the reader survivors are consciously narrowed rather than called harmless.

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

## 🧾 OWNER DISPOSITION 2026-08-20 — AUDIT COMPLETE; ACCEPTED LIMITATION; GitHub #13 CLOSED

**Owner decision (2026-08-20): the audit this record owed is COMPLETE, the record moves from `open` to
ACCEPTED LIMITATION, and GitHub issue [#13](https://github.com/TabMail/tabmail-ios/issues/13) is CLOSED
by that decision**, referencing PR [#57](https://github.com/TabMail/tabmail-ios/pull/57) — *"Pin the
Undo-Send synchronous-write invariants and harden the IOS-PERF-010 guardrails"*, merged 2026-08-19. No
production behaviour changed with this disposition. Everything recorded above stays true and still
governs; only the disposition moved.

**Nothing was fixed by this disposition, and nothing was reclassified into safety.** The five surviving
synchronous `@MainActor` writes are exactly the five enumerated above, and they are **NOT one family**:

| # | Member | Family | Classification |
|---|---|---|---|
| 1 | `AccountDetailView.setFolderRole(_:role:)` | folder-role (Settings) | inconclusive / **DO NOT TOUCH** |
| 2 | `AccountDetailView.assignRole(_:to:)` | folder-role (Settings) | inconclusive / **DO NOT TOUCH** |
| 3 | `AccountDetailView.clearRole(_:)` | folder-role (Settings) | inconclusive / **DO NOT TOUCH** |
| 4 | `AccountManager.retryOutboxMessage(_:)` | Undo-Send / outbox | inconclusive / **DO NOT TOUCH** |
| 5 | `AccountManager.discardOutboxMessageConfirmed(_:)` | Undo-Send / outbox | **MUST STAY SYNCHRONOUS** |

⚠️ **Read the table before restating the count.** Summarising these as "the five Undo-Send writes", or
as five members of one hazard, is wrong in both directions and has already been done once:

- **Only TWO of the five are on the Undo-Send / outbox path** — members 4 and 5, both `nonisolated func`
  declared in the file `AccountManagerOutbox.swift` on `actor AccountManager` (that file is a single
  `extension AccountManager`, so `AccountManagerOutbox` is not a type). **The other three are folder-role
  writes on a Settings path** and have no undo race at all.
- **The two families have DIFFERENT hazards.** Members 4–5: Proof A's Δ-eroded undo budget and the
  `IOS-OUTBOX-006` end state — a *delivered* message for which the user was shown "Couldn't undo" with
  the Undo button already gone; nothing recovers the delivered mail. Members 1–3: the loss of **gesture
  order == durable order**, i.e. a **NEVER DROP USER INTENTION** violation in which two unstructured
  `Task { await write }` land out of tap order and the user's EARLIER intention silently wins.
- **Only member 5 is MUST STAY SYNCHRONOUS.** The other four are **inconclusive**, which is a different
  verdict from "safe": it means no proof was produced in either direction. Member 4 is the weakest of
  the four — its durable admission is a SQL CAS that survives conversion and it does not rewrite
  `holdUntil`, so Proof A does not reach it — and it is still no-touch, held synchronous for symmetry
  with its pair.
- **Both families already carry their exit route, so neither is unfinished audit work.** Members 1–3
  have a documented conversion path: a **per-account serial tail modelled on
  `AccountFieldPersistenceStore`**, never a bare `Task { await write }` (roles need per-ACCOUNT keying
  because the row sets overlap, so that store's keying does not transfer unchanged). Member 4 carries a
  recorded **trip-wire**: if `retryOutboxMessage` ever starts writing `holdUntil` it moves under Proof A
  and its inconclusive classification lapses.
- `IOS-SETTINGS-002` stays `accepted` and is unaffected, exactly as recorded above.

**What closing #13 does and does not mean.** It retires a tracker row whose remaining work is no longer
an audit — the by-state census is discharged, revision-bound at `98dde448b` and re-verified at
`cdf11a6e5` — but a set of deliberate design decisions plus four inconclusive verdicts that need device
evidence nobody has. **This record is now the fence.** The reopening bar is unchanged and unrelaxed by
this disposition: a measured, user-visible stall attributable to a NAMED member. There is still **no
`Thread Performance Checker` evidence in-tree** for any of the five, and per `IOS-PERF-011` *"fast when
uncontended does NOT refute it"* — the exposure stays real-but-unmeasured, and the census stays
revision-bound rather than a certification.

⚠️ **Do not read `accepted` as "these five are now fine to convert."** The per-member classifications
are the operative instruction; the disposition line is not.
