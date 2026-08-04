## Two-instant wake handoff — a deadline can elapse BETWEEN the query that selected it and the guard that re-checks it, and "already elapsed" means DO IT NOW, never DO NOTHING (2026-08-04)

**This is a CLASS, not a call site.** Any code shaped like

1. read the durable store at instant **A** to pick the *next* deadline (a predicate such as `deadline > A`), then
2. `await` something — a database read, a provider call, an actor hop — then
3. re-check that deadline against a **fresh** instant **B** and decide whether to schedule work,

has a window in which the deadline is **future at A and past at B**. The dangerous shape is a guard
whose "already elapsed" branch simply **falls through**: the loop above it has finished, the timer
below it is never armed, and the durable row is left waiting for an unrelated external trigger.
Nothing is lost — the row is still there — but nothing is *live* either, which is a **liveness**
defect against the never-drop contract rather than a correctness one.

**The correct response to "the deadline already passed" is to do the work IMMEDIATELY.** Clamp the
interval at zero and schedule; never treat elapsed-ness as a reason to skip. The end state a user
expects ("my held send goes out when its hold ends") is reached by an immediate re-drive, and by
nothing else.

### The instance that produced this entry

`AccountManager.drainOutbox` (in the FILE `TabMail/Services/Account/AccountManagerOutbox.swift` —
⚠️ **the file name is not a type qualifier**; the enclosing type is `AccountManager` and
`AccountManagerOutbox.wakeUpDelay` greps as nothing) selects its wake target with
`AccountManager.earliestFutureHoldWakeTarget(now:db:)`, whose predicate is `holdUntil > now`, and
then re-checked `hold > Date()` — a **fresh** instant, with an `await dbPool.read` in between. An
undo-send deadline that elapsed during that read armed **no timer at all**, and the row stayed
`.queued` until a foreground, a sync, a network change or another `queueSend` happened along.
Registered as `KNOWN_ISSUES.md` **`IOS-OUTBOX-005`**, fixed by `1a1962207`. Its sibling
`IOS-OUTBOX-002` is the same symptom via a different mechanism (query ORDERING, not this race) —
neither fix closes the other, which is why they are two rows.

The fix is `AccountManager.wakeUpDelay(for:at:)`, a `nonisolated static` that clamps the interval at
zero, so an elapsed deadline schedules an **immediate** re-drive.

### 🚨 The companion hazard: `UInt64(a negative Double)` TRAPS

The clamp is **independently load-bearing**, and this is the part that turns a liveness bug into a
crash if the fall-through is "fixed" carelessly. The caller converts the interval with
`UInt64(interval * 1_000_000_000)`. In Swift, converting a **negative** `Double` to an unsigned
integer type is a **runtime trap**, not a saturating conversion and not a wrap-around. So "just
schedule it anyway" without a `max(0, …)` turns the missed wake into a crash on exactly the timing
window that was already the rare one. Clamp first; schedule second.

### Why the decision takes an INSTANT PARAMETER instead of reading the clock inline

Because a decision that reads `Date()` internally **cannot be tested at a chosen instant**, and this
repo has already paid for that. `PostLoopWakeUpQueryTests`' own doc comment records that an inline
clock is precisely why a **replica** test stayed green while `IOS-OUTBOX-002` shipped: the suite
asserted against a copy of the query written out in the test helper, and a replica cannot go red on
a defect in the original. `earliestFutureHoldWakeTarget` takes `now:` for the same reason
`wakeUpDelay` takes `at:`. **Both halves of a two-instant handoff must be evaluable at instants the
test chooses**, or the test can only ever pin the mechanism it re-implements.

### Termination — state it, do not assume it

An immediate re-drive must also be shown to **stop**. In the outbox instance: the drain loop's
admission filter is `(holdUntil ?? .distantPast) <= Date()`, so the next pass **admits** the elapsed
row instead of falling through again; and `earliestFutureHoldWakeTarget` filters `holdUntil > now`,
so that row is no longer a wake target and no second timer can be armed. A still-future deadline is
unaffected (`max(0, positive) == positive`), so the ordinary path is byte-identical. Any other
instance of this class owes the same two sentences: *what claims the work on the re-drive*, and
*why a second timer cannot be armed*.

### Where to look for more instances

Anywhere a wake/retry/backoff target is chosen by a query and then re-validated after an `await`:
outbox holds, action-queue backoff, AI job re-enqueue, sync scheduling. The tell is a `guard`/`if`
whose *else* branch does nothing and whose comment says something like *"already elapsed — the drain
above will have handled it"* — a statement about a loop that has, by then, already run.
