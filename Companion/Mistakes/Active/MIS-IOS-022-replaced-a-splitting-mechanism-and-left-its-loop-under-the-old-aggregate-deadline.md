# MIS-IOS-022 — I bounded an unbounded REQUEST with a margin measured in elapsed TIME

*(Originally filed as "I replaced a splitting mechanism with a sequential loop, under the deadline the splitting had been escaping". The recurrence generalised it: the loop was the first instance, the fix for the loop was the second, and both are the same error about what a time margin can promise.)*

**Class:** data-integrity
**Severity:** critical (an intention is never sent at all — persistent retry starvation, the wedge corollary)
**First seen:** 2026-09 · **Recurrences:** 2 · **Status:** Active
**Related:** `MIS-IOS-004` (unknown is not authoritative — the exit the wedge corollary sits beside) · `MIS-IOS-021` (the other defect that entered through this same refactor) · `MIS-IOS-011` (a residual declared on an argument never run) · `Companion/Rules/Active/never-drop-user-intention.md` (THE MANTRA; the wedge corollary)

## The tell

I am deleting a mechanism I can see is ugly — the drain answered a multi-member not-found by
manufacturing child operations and deleting the parent — and replacing it with something obviously
cleaner: ask the provider about each member in turn, and report what each one said. Two sentences,
both of which I believed:

1. *"I have checked the replacement against the thing I deleted, member by member. Same
   classification, same answers, and now on ONE durable row with its original id instead of
   replacement rows."*
2. *"The loop accumulates and reports at the end. Where else would it report?"*

Every comparison I made was about **what the mechanism decided**. I never compared **how much work
it committed to before returning**. The splitting arm was not only classifying members; it was also
cutting the batch into pieces that each fit inside the caller's deadline. That was a side effect of
its shape, not its stated purpose, so it appeared in no name, no comment and no test — and my
member-by-member diff was structurally incapable of seeing it.

**AND THE SECOND TELL, WHICH IS THE GENERAL ONE.** I am about to write a sentence of the form *"we
have spent T so far and the deadline is D, so there is D − T left — that is enough, start the next
one."* The subtraction is arithmetic and it is correct. The inference is not, and the reason is
visible in the sentence itself: **every quantity in it is elapsed time, and the thing it is deciding
about is a request whose duration is not one of them.** Nothing bounds the next request. There is no
per-request ceiling in `AuthedHTTP` or `performHTTPRequestWithRetry`; a provider may queue the call
for a slot before it even starts. So the margin protects the prefix only for those next requests that
happen to be short enough, which is precisely the assumption that was never available.

The giveaway is the shape of the defence, not its size: **a margin can only bound what has ALREADY
happened.** If what you need to protect is a finished prefix, and the thing that can destroy it is
the request you are about to start, then no choice of margin is a defence — you have to not start the
request. Asking *"is 0.6 the right fraction?"* means the error has already been made; the answer is
that no fraction is right, and the follow-up question *"what would make 0.6 safe?"* has the answer
*"a per-request maximum that does not exist."*

## What actually happened

PR 1 of the two-PR action-queue refactor, branch `agent/ios-queue-no-split`, commit `a270c312a`.

`GmailProvider.modifyEachMessage` and `ExchangeProvider.patchEachMessage` walk `ids` sequentially,
accumulate proven and absent members, and throw `ProviderMembersDispositioned` **after the loop
ends**. The whole call runs inside `withTimeout(SyncConfig.pendingOperationTimeoutSeconds)` (15 s)
from `AccountManager.executeSingleOp`.

`withTimeout` in `TabMail/Helpers/AsyncTimeout.swift` resumes the continuation with `TimeoutError`
**first** and only then cancels the operation task, so **anything the loop produces at or after the
deadline is discarded** — including the report of everything it had already proven. `executeOperation`
never sees the report, `executeSingleOp` takes the generic failure path, and `requeueOrRetain` bumps
`retryCount` **without narrowing `messageIds`**. The next attempt re-requests the identical prefix and
dies at the same member. The final member's intention is never sent to the provider on any attempt.

**It is a regression, not an inherited limit.** At base, the first 404 ended the batch by splitting,
and each single-member child then fit its own 15 s deadline. A reviewer compiled a Swift 6 probe using
my exact helper bodies and the production `withTimeout`: both providers timed out on all three
attempts with the last member never requested, while a base-semantics control completed every live
member. Reproduced in-tree by `gmailSetterOverrunNarrowsUnderTheOriginalIdAndReachesTheTail()`,
`graphSetterOverrunNarrowsUnderTheOriginalIdAndReachesTheTail()` and
`graphMoveOverrunNarrowsUnderTheOriginalIdAndReachesTheTail()` in
`TabMailTests/Services/QueueMemberAbsenceTests.swift` — one per affected loop, each red against the
budget shape. ⚠️ They REPLACED `aSlowMemberLoopReportsItsPrefixBeforeTheOperationDeadline()` and
`aBudgetStoppedBatchNarrowsAndConvergesWithoutRedoingItsProgress()`, which were red against
recurrence 1 and **green against recurrence 2**: the first used requests comfortably shorter than the
reserve and the second forced a zero budget, so neither ever started a member before the budget that
finished after the outer deadline. That gap is the whole of what round 1 missed, and it is why the
replacements assert the fixture really is an overrun profile — every member individually admissible,
the batch jointly inadmissible — before asserting anything about the outcome.

Persistent retry starvation is the **wedge corollary** — an operation that starves forever is a
dropped intention, which THE MANTRA puts on the non-recoverable list. Not an accepted loss.

### Recurrence 2 — the fix was the same mistake, one level in

Round-1 of PR 1's gate was answered with `ProviderMemberLoopBudget.deadlineFromNow()` in
`TabMail/Providers/EmailProvider.swift`: a **second, strictly earlier** deadline
(`SyncConfig.providerMemberLoopBudgetFraction` = 0.6 of the operation timeout), consulted **between**
members and **never before the first**, so that every attempt settles at least one member and the row
narrows through `ExecutedOperation.provenMembers` / `retirePartiallyCompletedOp`. It shipped as
`43db4979b`, with tests, and both round-2 angles (architecture A1, robustness R1) reproduced **the
identical starvation** against it, each with its own independently compiled Swift 6 probe built from
the real loop bodies.

The counterexample is three lines long. Members that each need ~8 s, under the 15 s operation
deadline, with a 9 s budget: `[gone, live-a, live-b, tail]`. `gone` settles instantly; `live-a`
finishes at ~8 s; **8 < 9, so the loop starts `live-b`** — and `live-b` cannot finish before 15 s.
`withTimeout` resumes the drain with `TimeoutError` and the settled prefix `[gone, live-a]` dies with
the abandoned task, exactly as before. `requeueOrRetain` preserves the full membership, every later
attempt reproduces the same events, and `tail` is never requested on any of them. Each individual
request was comfortably admissible; the batch was not; and the check could not tell, because **it ran
before the request whose duration decided the outcome**.

⛔ **A SMALLER FRACTION IS NOT A FIX, and both reviewers said so independently.** The reserve has to
exceed the duration of the next request, that duration has no bound, so no fixed fraction establishes
the contract. ⛔ **Deleting the check alone is not a fix either** — that restores the unbounded prefix
replay of recurrence 1. The two obvious repairs fail in opposite directions, which is the signature of
a mechanism that should not exist.

Fixed by deletion, prescribed identically by both angles: **`ProviderMemberLoopBudget` is gone**, along
with `providerMemberLoopBudgetFraction` / `providerMemberLoopBudgetSeconds`, and each of the three
loops — `GmailProvider.modifyEachMessage`, `ExchangeProvider.patchEachMessage`,
`ExchangeProvider.moveProvingDestinations` — now settles **exactly one member per attempt** and
reports it through the same narrowing path. An attempt's exposure is then one request, which is the
only quantity the operation deadline actually bounds. `pendingOperationTimeoutSeconds` stays at 15 and
is untouched.

Accepted cost, recorded so it is not "fixed" later by someone who reads it as a regression: a healthy
N-member operation converges in **N drain attempts** instead of one, narrowing the same durable row
(same id, same `createdAt`, `everAttempted` preserved) each time. Monotonic progress in exchange for a
prefix that could replay forever. **Batching must not be reintroduced to recover the old rate.**

## Why it is not obvious

Nothing goes red, and nothing can. The provider helpers' own tests have no deadline above them. The
queue's tests have fast fixtures, so the loop always finishes. The defect needs *members × real
latency* and appears only in the composition of two files owned by two subsystems: a loop that is
correct alone, and a cancellation that is correct alone.

A timeout also *reads* as a safety property, so exceeding one feels like "this attempt failed, we
retry" rather than "this attempt destroyed the evidence the retry needed in order to make progress".
The two are indistinguishable from the outside — a retry that repeats an identical prefix and a retry
that is converging both look like `retryCount += 1` — unless you count **members reached per attempt**
and require that number to be ≥ 1.

And "return the accumulated result at the end" is simply the shape loops have. It becomes a defect
only because a canceller upstream throws that result away, which is invisible at the loop.

The recurrence hid behind its own tests. Both budget tests were genuinely red before the budget
existed and genuinely green after, so the fix looked verified from every angle a green suite can see.
Neither ever produced the state that matters, because producing it requires a member that STARTS
inside the budget and FINISHES outside the operation deadline — and both fixtures were built from the
mental model that the budget was already correct, so neither author had a reason to construct the one
timing that falsifies it. A test written to confirm a margin will choose latencies the margin
survives.

## The rule

**A margin measured in elapsed TIME cannot protect finished work from a request whose duration is
unbounded. Bound the WORK an attempt commits to — one unit — not the time it has already spent.**

Both halves are load-bearing, because the two failures sit on either side of it:

- **An attempt must commit to AT MOST one unit**, or a cancellation can destroy work it has already
  finished and the retry repeats it forever (recurrences 1 and 2).
- **An attempt must settle AT LEAST one unit**, or it can never converge — which is why the stopping
  rule can never be consulted before the first member.

When you delete a mechanism that produced small units of work, the question is not *"what deadline
were those units fitting inside?"* but *"how many units did each one commit to before returning?"* —
and the answer the replacement gives must be the same number.

## Mechanical check

```bash
# 1. THE DELETED MACHINERY MUST STAY DELETED. Any hit is recurrence 3.
#    (Self-test: this grep is only meaningful if it can match — check it against
#     `git show 43db4979b -- TabMail/Providers/EmailProvider.swift`, where it does.)
grep -rn "ProviderMemberLoopBudget\|providerMemberLoopBudget" TabMail/ TabMailTests/

# 2. EVERY per-member provider loop settles ONE member. Each of these three sites
#    must return or throw before it can issue a second addressed request; a loop
#    (`for`/`while`) over `ids` inside one of them is the defect returning.
grep -n "func modifyEachMessage" -A40 TabMail/Providers/GmailProvider.swift
grep -n "func patchEachMessage" -A30 TabMail/Providers/ExchangeProvider.swift
grep -n "func moveProvingDestinations" -A60 TabMail/Providers/ExchangeProvider.swift

# 3. The census of loops that report per-member outcomes, so a NEW one cannot be
#    added without being read against rule 2 above.
grep -rn "throw ProviderMembersDispositioned(\|provenIds:" TabMail/Providers/

# 4. The operation deadline is the ONLY deadline over these loops. Expect exactly
#    ONE hit, `pendingOperationTimeoutSeconds`; a second, smaller one is the
#    mechanism this entry exists to keep deleted.
grep -n "pendingOperationTimeout\|memberLoopBudget" TabMail/Services/Sync/SyncConfig.swift
```
