## ADR-IOS-082: The Action Queue Is Drained by a Global Single-Operation FIFO Executor, Ordered by a Durable Position

**Date:** 2026-09-06

**Status:** Active. Restores the scheduler half of ADR-IOS-070's v2final line and **retires the lane
DISPATCH model** that ADR-IOS-018 and ADR-IOS-081 describe. Amends ADR-IOS-081 clauses 5 and 6 and
its "no schema, migration or drain-ordering change" consequence — **this record is the follow-up
that consequence routed to the owner.** Supersedes no ADR; nothing about identity, addressing or
the four exits of `never-drop-user-intention.md` changes here.

**Context.** The v2→v3 port carried v2final's queue SEMANTICS forward and lost its SCHEDULER. v3
claimed every queued row up front, partitioned the claim into connected-component lanes and
dispatched those lanes CONCURRENTLY under a three-pass outer loop. Three properties fell out of that
shape, and between them they are the root cause of the action-queue defect train:

- **Wire order was decided per lane, not globally.** Two gestures in different lanes raced, and
  nothing in the tree could answer "which operation went out, and in what order" after the fact —
  `IOS-QUEUE-008` took a month to diagnose for exactly that reason.
- **The order key was a wall clock.** `createdAt` ties are unordered, and an NTP correction or a
  user changing the device clock could put a newer intention ahead of an older one. A deferral could
  not move a row at all without deleting and re-inserting it.
- **A failure halted a whole lane, and a narrowing was treated as a failure.** With one member
  settled per provider attempt (`MIS-IOS-022`) and a three-pass cap, an eight-message gesture needed
  three separate drains — each waiting on a gesture, a reconnect or the five-minute poll, i.e.
  15–20 minutes on an idle device.

**Decision.**

1. **Order is DURABLE and allocated at admission.** `pendingOperation` gains `queuePosition`
   (migration **v90**, `INTEGER NOT NULL CHECK(queuePosition > 0)`, **no DEFAULT**, indexed by
   `pendingOperation_queuePosition`). The position is allocated after the current maximum inside the
   SAME write transaction that admits the row, so admission order IS wire order and nothing can be
   admitted ahead of work already queued.

   Two shape properties are load-bearing. **`PendingOperation` is a `MutablePersistableRecord`**:
   `PersistableRecord` re-declares `willInsert` as NON-mutating, so `MutablePersistableRecord` is the
   only conformance that can allocate the column during the insert (a non-mutating `inserted(_:)`
   wrapper exists for call sites that cannot hold a `var`). And **the column has no DEFAULT
   deliberately** — a writer that omits the position must FAIL its insert rather than silently admit
   at position zero, which under `ORDER BY queuePosition ASC` is the HEAD of the queue.
   `NSEDataBridge`'s raw-SQL admission was converted to the typed route in the same change; the
   constraint is what catches the next one.

   **`createdAt` is demoted to AGE ONLY.** It never decides order again, so equal timestamps and a
   backward clock step cannot reorder the queue.

2. **One owner, one operation at a time.** `claimFrontierOperation` walks `queuePosition ASC` in one
   short write transaction and claims the first row that can actually be attempted; the executor
   executes it, commits its result, and only then claims again. Lane DISPATCH is gone. **The
   protected-frontier law** is the counterpart: an `inFlight` row STOPS the walk — skipping it would
   let a later gesture overtake an unresolved predecessor, and stealing it would send the same
   mutation twice — and the two recoveries at the top of the next drain
   (`replayRetainedRetirements`, `recoverPendingRequeues`) are what resolve that ownership.

3. **The lane RELATION survives the lane MODEL, and it is a DEFERRAL SCOPE, not a dispatch unit.**
   `buildLanes` is renamed `buildRelatedChains` and `laneKey` `addressKey` — the union-find over
   provider ADDRESSES is unchanged, including the two address spaces ADR-IOS-081 clause 1 fixed
   (account-qualified `accountId:msgId` for Gmail/Outlook/demo, folder-qualified
   `accountId:folderPath:msgId` by default, absence meaning folder-qualified). Relatedness is
   retained because it is exactly what a DEFERRAL must cover: parking one row and taking the next
   would let a later operation on the same message overtake it.

4. **A failure defers the whole related chain; the shape depends on whether the wire was touched.**
   A row that FAILED a provider attempt moves to the TAIL with its live related chain, keeping
   relative order, and is recorded in the drain's deferred set so the same run cannot re-claim it
   (`deferRelatedChainToTail`) — exactly one attempt per drain, and every unrelated intention, on
   this account and on every other, keeps executing in that same run. A row that could NOT be
   attempted at all (no registered provider, a source folder mid-UIDVALIDITY reset, checkpoint A
   without epoch evidence) is skipped IN MEMORY: its chain is deferred for the drain, but no position
   changes, no retry is charged, `everAttempted` stays false, and the rows stay exactly where the
   user's gestures put them. v2final's global-stop branch is NOT restored — one not-yet-connected
   account must not hold every other account's mail.

5. **One member per attempt is ORDINARY traffic, and a narrowing is STRICT PROGRESS.**
   `GmailProvider.modifyEachMessage` and `ExchangeProvider.patchEachMessage` address exactly one id
   per attempt and report it through `ProviderMembersDispositioned`, so the narrowing path is the
   COMMON path for that traffic rather than a contingency (`MIS-IOS-022`: a margin measured in
   elapsed time cannot bound a request that has not started, which is why the bound is ONE request).
   `retirePartiallyCompletedOp` therefore answers `.proceed`, not `.deferred`: the remainder and its
   chain move to the tail — so unrelated mail is not stuck behind N provider calls — and the same
   continuous run comes back to it. An N-member gesture settles in ONE drain.

   **Deliberate deviation from the spec's failure table, recorded here and in the source.** Marking a
   partial completion deferred would bound it to one member per DRAIN, strictly worse than the
   three-per-drain shape being replaced. Failure alone still cannot create a self-rescheduling hot
   loop, because a "partial" that narrows NOTHING is not progress: the **strict-progress guard**
   (`remaining.count < messageIds.count`) routes that shape to the ordinary retryable disposition,
   which does defer.

6. **🚨 THE `.proceed` INVARIANT — no arm may report progress it did not make.**
   **An arm may return `.proceed` only if the claimed row is provably GONE, provably NARROWED, or
   provably OWNED by `pendingRequeues` / `pendingRetirements`.** The claim transaction has already
   committed `inFlight` + `everAttempted`, and clause 2's protected-frontier law stops the walk at an
   `inFlight` row — so a `.proceed` on an iteration that changed nothing does not waste a pass, it
   **wedges the drain at that row for every account for the life of the process**. Every gesture is
   then applied locally and acknowledged in the UI and never reaches the wire, and at the next launch
   `AppDatabase.recoverPreviousSessionResidue` deletes an `everAttempted` `.move` outright. That is
   the **wedge corollary** of `never-drop-user-intention.md`, and it terminates in a DROPPED
   intention rather than a delay.

   The failure shape it rules out is `try? await retryWrite { … deleteOne }` followed by
   `return .proceed`. `retryWrite` is three attempts 100 ms apart, and GRDB write suspension while
   backgrounded (ADR-IOS-041), a data-protection lock and `SQLITE_FULL` all make all three throw
   while READS keep working; `try?` then discards the only evidence that nothing happened. Three
   terminal arms did this — the single-message conflict, the permanently-invalid drop, and the
   `actionIdentityResolutionFailed` refusal — and all three now take the `uidValidityChanged` arm's
   shape: a real `do`/`catch`, `await requeueOrRetain(currentOp.id)` in the catch, `return
   .stopDrain`. The executor's outcome box defaults to `.stopDrain` for the same reason, because
   `ProviderWorkQueue.execute`'s non-throwing overload has three early returns that skip `work()`.

   **The invariant is stated as an invariant because the site list is not stable.** Commit
   `288231f1b` fixed the identical class at the eight `try? … markQueued` REQUEUE sites one commit
   earlier and did not census the RETIREMENT writes (`MIS-006`, `MIS-IOS-020`). The census that
   accompanies it is a falsifiable count, not a list to trust: **seven `.proceed` sites in
   `AccountManagerQueue.swift` before the change** — three provably-resolved returns (whole-op
   success, `uidValidityChanged`, `retirePartiallyCompletedOp`'s tail, each reached only after its
   retirement transaction COMMITTED), the three arms above, and the outcome-box default. **Six
   after it, all in the provably-resolved class**, because the box default is now `.stopDrain`. An
   eighth site, then or now, is a finding.

7. **`accountScopedIds:` stays non-defaulted at every call site — stated without a number.**
   ADR-IOS-081 clause 7 gave a count, and the count went stale within a day. The durable statement is
   the one that cannot rot: **the parameter has no default, so the compiler enumerates the call sites
   and a new provider can neither acquire nor lose the row-following re-key BY SILENCE.** The
   derivation, for anyone who wants today's figure: `grep -rn "accountScopedIds:" TabMail/
   TabMailTests/` = two declarations (`MessageHeaderRekey.finishMove`,
   `.readdressQueuedOperations`), one internal forward between them, two production call sites
   (`commitFullRetirement`, `commitPartialRetirement`), and the rest tests.

**What this changes in ADR-IOS-081.** Clauses 5 and 6 are written against a lane loop that no longer
exists, and both are AMENDED rather than withdrawn:

- **Clause 5 (a requeue writes COLUMNS, not a captured struct) survives intact and generalises.**
  `PendingOperation.markQueued` is still the requeue write, and the rule it instantiates — a write
  that intends to change one field must not be a whole-row write from a stale snapshot — is if
  anything more load-bearing now that `queuePosition` is a column a stale snapshot would clobber.
  The "eight drain sites" it counts belong to the lane loop; the sites moved, the rule did not.
- **Clause 6 (the drain re-reads by primary key before executing, with NO `?? capturedOp`
  fallback)** described a re-read the lane loop performed between claiming a suffix and executing
  each member. Under a single-operation executor the claim transaction and the execution are
  adjacent, so that re-read is gone from the drain; the refusal to fall back to a captured value is
  unchanged wherever a re-read still happens, and the corrected list of writers that can delete a
  claimed row (the local wipes and resets, not cancel/annihilation) is unchanged.

**Consequences.**

- **This IS the follow-up ADR-IOS-081 routed to the owner.** That record's "No schema, migration or
  drain-ordering change — the drain still orders by `createdAt` … routed by the owner to its own
  follow-up" is now historical; a correction note stands at the bullet, and the sentence is kept
  verbatim so the sequence stays readable.
- **Simplifications the single-operation executor makes available, and they are DELETIONS.**
  `pendingRetirementSuffixes` is deleted (it existed to undo concurrent lane dispatch);
  `pendingRetirements` and `pendingRequeues` can each hold at most ONE entry; `laneDiagnosticSummary`
  — the formatter that rendered a lane-composition plan there is no longer any plan to state — is
  deleted with its two unit tests. The drain's log line carries the claimed row's `queuePosition`
  instead, which is the whole answer to "what went out, in what order".
- **The v2final "demote lane" this tree recorded as MISSING (F2b L4) now exists**, as a side effect
  of clause 4: every retryable arm demotes the failing chain to the tail.
- **The identity-refusal TERMINAL DROP is deliberately unchanged.** It is an owner-accepted
  limitation (`IOS-QUEUE-003` item 4); changing it is a product-behaviour decision and is not this
  record's business. What changed is only that its retirement WRITE is now checked (clause 6).
- **Provider batching is NOT reintroduced and narrowings are NOT deferred.** Both are explicitly out
  of scope (`MIS-IOS-022`, and clause 5's recorded deviation).
- **A backward clock step is no longer an ordering hazard anywhere in the queue.** Every earlier
  candidate for making the order robust — inheriting a rowid, re-inserting on deferral, tie-breaking
  a timestamp — is retired by the durable column, and none of them should be revived.

**Fences.** `TabMailTests/Services/GlobalFifoExecutorTests.swift` — admission order against an
adversarial clock (equal stamps, an hour-old op admitted second), an eight-member Graph operation
settling in ONE drain while yielding to a bystander, the spec's two worked chain-deferral examples,
one attempt per drain plus convergence when the fault clears, unclaimable frontiers, cross-account
and cross-folder chain separation, the effective `PRAGMA table_info` schema, status-only crash
recovery, a 400-row backlog cost bound, **the strict-progress guard driven through a real drain with
an empty dispositioned report**, and **a retirement write refused three times, whose oracle is
another ACCOUNT's wire on the NEXT drain** (clause 6). `PendingQueueChainTests` (renamed from
`PendingQueueLaneTests`) keeps the two address spaces, including the IMAP negative
`.imapSameUidInTwoFoldersStaysInSeparateLanes`. `DrainQueueIntegrationTests.fifoOrdering` pins that a
timestamp sort disagrees with the durable order. `QueueMemberAbsenceTests`,
`OutlookQueueHandoffTests` and `ProviderIdQueueFuzzTests` continue to run the identity and
member-absence invariants against the new scheduler unchanged.
