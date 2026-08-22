## An affordance's lifetime is bounded by the DURABLE state that backs it, never by when the UI happened to appear (issue #76, 2026-08-20)

**This is a CLASS, not a call site.** Any code shaped like

1. write a **durable** deadline at instant **A** (a row, a lease, a token expiry), then
2. `await` the persist — a disk write, an awaited `dbPool.write`, a provider round-trip — then
3. present a UI affordance whose lifetime is counted from **B**, the instant the UI appeared,

has silently made two different instants interchangeable. They differ by **Δ**, the persist latency,
and Δ is not small on the paths that matter: large attachments, a device under I/O pressure, a cold
database. The affordance therefore outlives its own backing state by exactly Δ, and the user's tap
lands on a deadline the executor has already passed.

**The rule.** Derive the affordance's deadline from the durable value itself and carry that value to
the presenter. Presentation latency may **shorten the visible window** — including to nothing — but
it must never **move the deadline**. Shortening is the fail-closed direction because no Undo
intention or cancellation promise was accepted; the original Send remains durably queued/retryable.
An Undo that is offered and then refused is different: the UI accepted a gesture it could not honour
and must say so truthfully rather than implying the send stopped.

### The instance that produced this entry

`OutboxMessage.holdUntil` is stamped inside `AccountManager.persistQueuedSend` as
`queuedAt + SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds`, where `queuedAt`
is captured at **persist START** — before that function's attachment write and before its awaited
`AppDatabase.dbPool.write`. It is **not a stored column**, so nothing downstream can re-derive it.

`PendingSendService.present(...)` counted a flat `outboxUndoHoldSeconds` from its **own** `Date()`,
which `ComposeView.send` reaches only after the awaited persist has returned. Once Δ exceeded the 1 s
`outboxClaimBufferSeconds`, the Undo button stayed tappable **after** the drain was already entitled
to claim the row, and the tap failed with *"Couldn't undo / Try again."* on a message that had gone
out. Worst on large sends and loaded devices — exactly when undo matters most.

The fix carries the durable value forward: `persistQueuedSend` and `AccountManager.queueSend` return
`holdUntil` alongside the id, `PendingSendService.Pending.undoDeadline` derives the button's
withdrawal instant as `holdUntil - outboxClaimBufferSeconds`, and the phase decision moves into
`PendingSendToastPhase.resolve(at:presentedAt:undoDeadline:)`. Fixed by
`5568a51c98bad568a434ef890909e550f03d9cbc` (PR #77).

### 🚨 The tell — two variables sharing a NAME while denoting DIFFERENT INSTANTS in different layers

This is the cheapest detector in the entry, and it is greppable. `PendingSendService.Pending` had a
field called `queuedAt`; so did the persist path. They were **not the same instant** — one was
persist start, the other was persist start plus Δ — and nothing in either layer said so. The name
carried an equality the code never established.

**A shared name across a durable/presentational boundary is a smell worth grepping for.** When the
same identifier appears on both sides of an `await`, ask which side owns the value and whether the
other side is entitled to recompute it. The repair here was to rename the presentational one to
`Pending.presentedAt` and give the durable one its own field, `Pending.holdUntil`, so the two can no
longer be confused by a reader or by autocomplete.

### The technique that resolved the ambiguous contract: find the SIBLING affordance first

Issue #76 was filed `needs-verification` because **two readings were defensible** — was the toast's
5 s window the spec and the durable hold merely its backstop, or the reverse? Nothing in the toast's
own code settled it.

What settled it was finding **the other affordance over the same durable state**: `OutboxRow.isHeld`
in the Outbox list already gates on `(message.holdUntil ?? .distantPast) > Date()`, and that
predicate is what decides whether the swipe action reads "Cancel Send" or "Discard" (the same
predicate drives the row's countdown text and its tick timer). So the durable hold was **already**
the contract in shipped behaviour, and the toast was the outlier — not a design question, a
consistency defect.

> **When a contract is ambiguous, look for a sibling affordance over the same durable state before
> designing anything.** If one exists, the ambiguity is usually already resolved somewhere in the
> tree, and the fix is consistency with shipped behaviour rather than a new invention. This is the
> same instinct as *check the last shipped release when a design spirals*, applied inside one commit.

### Anti-regression details worth keeping

- **`PendingSendService.present(...)`'s `holdUntil` parameter has NO default value, deliberately.**
  A `= nil` (or worse, `= Date().addingTimeInterval(...)`) would let any future call site silently
  reinstate the defect while still compiling. Requiring the argument makes every future presenter
  state where its deadline came from. **A defaulted parameter on a safety-critical input is a
  re-entry point for the bug it closes.**
- **`PendingSendToastPhase.resolve` is a pure function of three instants** (`at:`, `presentedAt:`,
  `undoDeadline:`) rather than a method that reads the clock. That is what made the invariant
  testable at instants the test chooses, for the same reason `AccountManager.wakeUpDelay(for:at:)`
  takes `at:` — see [two-instant wake handoff](100-two-instant-wake-handoff-elapsed-means-do-it-now.md).
  A decision that reads `Date()` internally can only be pinned by a replica of itself, and a replica
  cannot go red on a defect in the original.
- **A `nil` hold yields `.distantPast`, so no Undo is offered at all.** Legacy pre-`v49` rows have no
  hold and the drain treats them as immediately claimable; offering an Undo there would be an
  affordance with no backing state whatsoever.
- **`max(0, …)` before the `UInt64` conversion is load-bearing, not defensive dressing.** `holdUntil`
  can already be in the past at `present(...)`, and `UInt64(a negative Double)` is a runtime **trap**
  in Swift — the companion hazard already recorded in topic `100`.
- Pinned by `UndoAffordanceHoldInvariantTests` (four invariant tests, one a nine-argument latency
  sweep) plus the producer-side `reportedHoldUntilIsTheStoredHoldUntil` in `OutboxDoubleSendTests`.
  `KNOWN_ISSUES.md` `IOS-PERF-010`'s Proof A is superseded in place, not deleted: its Δ-eroded
  arithmetic no longer holds, while its *must stay synchronous* verdict on
  `discardOutboxMessageConfirmed` is unchanged and now rests on a guaranteed 1 s budget.

### Finding ONE instance does not close the class — sweep the other exits of the same producer

The same sweep found a **second** instance in the same producer. `persistQueuedSend`'s double-send
firewall has a **dedup exit**: when an in-flight row already exists for the draft it keeps that row
and discards the new one. It returned the kept row's id but not its hold, so the toast opened a fresh
5 s window over a row whose `holdUntil` was stamped at the *earlier* send's persist and **may already
have elapsed**. Repaired by carrying `InFlightOutboxCandidate.holdUntil` through and returning
`existing.holdUntil` on that exit.

**The generalisation:** a producer with several return paths must be audited **exit by exit**, not
once at its happy path. The dedup exit is not a variant of the insert exit — it returns a *different
row*, stamped at a *different instant*, and every derived deadline inherits that difference.

### Where to look for more instances

Anywhere a durable deadline is written before an `await` and a UI affordance is then offered against
it: undo-send holds, action-queue undo windows, AI-lease expiry banners, subscription/trial grace
countdowns, token-refresh retry prompts, quarantine release timers. The tell is a view or presenter
that calls `Date()` (or starts a `TimelineView`/`Timer` from "now") to compute a deadline whose
authority lives in a database column.
