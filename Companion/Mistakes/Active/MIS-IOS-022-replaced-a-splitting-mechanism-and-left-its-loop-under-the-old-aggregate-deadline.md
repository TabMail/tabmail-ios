# MIS-IOS-022 — I replaced a splitting mechanism with a sequential loop, under the deadline the splitting had been escaping

**Class:** data-integrity
**Severity:** critical (an intention is never sent at all — persistent retry starvation, the wedge corollary)
**First seen:** 2026-09 · **Recurrences:** 1 · **Status:** Active
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
member. Reproduced in-tree by `aSlowMemberLoopReportsItsPrefixBeforeTheOperationDeadline()` and
`aBudgetStoppedBatchNarrowsAndConvergesWithoutRedoingItsProgress()` in
`TabMailTests/Services/QueueMemberAbsenceTests.swift`; both are red without the fix.

Persistent retry starvation is the **wedge corollary** — an operation that starves forever is a
dropped intention, which THE MANTRA puts on the non-recoverable list. Not an accepted loss.

Fixed by `ProviderMemberLoopBudget.deadlineFromNow()` in `TabMail/Providers/EmailProvider.swift`: a
**second, strictly earlier** deadline (`SyncConfig.providerMemberLoopBudgetFraction` = 0.6 of the
operation timeout), consulted **between** members and **never before the first**, so every attempt
settles at least one member and the row narrows through the existing `ExecutedOperation.provenMembers`
/ `retirePartiallyCompletedOp` path — same id, same order, no replacement rows.

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

## The rule

**When you delete a mechanism that produced small units of work, find the deadline those units were
fitting inside, and give the replacement its own strictly-earlier budget so that every attempt banks
at least one member's proven progress — an attempt that can settle nothing cannot converge.**

## Mechanical check

```bash
# Every provider loop that reports per-member outcomes must consult the earlier budget.
# The second list must cover the first, per file.
rg -n "throw ProviderMembersDispositioned\(|provenIds:" TabMail/Providers/*.swift
rg -n "ProviderMemberLoopBudget.deadlineFromNow\(\)" TabMail/Providers/*.swift

# The member budget must stay STRICTLY below the operation deadline it runs under
# (fraction < 1), or the budget can never fire before the cancellation does:
rg -n "providerMemberLoopBudgetFraction" TabMail/Services/Sync/SyncConfig.swift
```
