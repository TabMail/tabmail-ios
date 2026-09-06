# MIS-IOS-023 — I wrote a new call over the one that path already owed

**Class:** data-integrity
**Severity:** critical (dropped user intention — latent: unreachable on today's providers, reachable on the next provider change)
**First seen:** 2026-09 · **Recurrences:** 2 · **Status:** Active
**Related:** `MIS-IOS-008` (the deferred-successor mechanism this drops, `IOS-QUEUE-008`) · `MIS-IOS-021` and `MIS-IOS-022` (the other two defects that entered through this same refactor) · `MIS-IOS-012` (a caller census whose grep shape hid half the callers) · `Companion/Rules/Active/never-drop-user-intention.md`

## The tell

I am adding a call to a function that already ends with a call, and the new one belongs at exactly
the same spot — right after the retirement is frozen, on the same retired op and finish result. I
write it there. It reads perfectly: one call, in the obvious place, doing the new thing the change
is about.

What I never ask is what *used* to be on that line. The diff shows an addition and the function is
longer than before, so nothing looks lost. The tell is the feeling that a spot in a function is
"the natural home" for my new call — a spot is only a home if I checked who already lived there.

The second, quieter form of the tell: I am satisfied because the path I edited is correct, and I do
not go looking for the *other* path that is supposed to agree with it.

## What actually happened

`a270c312a` (PR #125, the change moving per-member absence to the provider boundary) added
`retireConfirmedGoneMemberHeaders` to `AccountManager.retirePartiallyCompletedOp` and wrote it over
the existing `materializeDeferredMoveSuccessors` call at that spot. No comment, no recorded
decision — the call simply stopped existing.

- Base `AccountManagerQueue.swift` had **4** `materializeDeferredMoveSuccessors` call sites. The
  branch had **3**, from `a270c312a` through `a8b6a015f`.
- The surviving evidence was an internal disagreement: the live narrowing path no longer
  materialized, while its own retained replay in `replayRetainedRetirements` still did. Two paths
  that exist to agree, disagreeing.
- Consequence had it been reachable: an operation that retires by NARROWING never materializes the
  deferred inverse it owes. The undo the user already gestured stays in `deferredMoveSuccessors`
  forever with its overlay entry retained, and `coalesceDeferredMoves` folds every later gesture on
  that message into a successor that never materializes — a dropped user intention, the
  non-recoverable class.
- It was **unreachable on today's providers**: a `DeferredMoveSuccessor` is registered only against
  an IMAP predecessor, and `IMAPProvider.move` returns `provenIds == ids` at every return site, so
  IMAP never enters the narrowing path.
- Restored in `a2666c7fa`, in the position the surviving three sites use, with a comment stating why
  it must stay even though nothing reaches it today. Pinned by
  `narrowedRetirementMaterializesTheDeferredInverseItsPredecessorOwes`, red-first: with the restored
  call commented out it fails `inverse.count -> 0`, `deferredStillWaiting=1 ops=[move["202"]]`.

**A second instance of the identical shape, same PR — ADJUDICATED AND FIXED 2026-09-06, and still
NOT counted in `Recurrences`.** The same change narrowed
`ExchangeProvider.moveProvingDestinations` from `for id in ids` / `MoveOutcome(provenIds: ids)` to
addressing `ids.first` and returning a one-member outcome without throwing. Its caller inside the
same file — the `EmailProvider` conformance `move(ids:from:to:)`, whose whole body was
`_ = try await moveProvingDestinations(...)` — was **byte-identical to base** and therefore discarded
a partial result while returning `Void`, which its protocol contract means "all N moved". Three
reviewers independently confirmed it was unreachable, because `dispatchOperation`'s `.move` arm casts
`provider as? ExchangeProvider` and returns from inside that branch.

The ruling was to make it IMPOSSIBLE rather than leave it merely unreached, because unreachability is
a property of the CALLER and this is a contract. The conformance now mirrors
`GmailProvider.modifyEachMessage` member for member: it throws
`ProviderMembersDispositioned(dispositionedMemberIds: outcome.provenIds, absentMemberIds:
outcome.confirmedGoneIds)` unless the outcome is "this whole request, all mutated", and
`AccountManager.executeOperation` converts that at its single chokepoint. ⚠️ The condition is
`!outcome.confirmedGoneIds.isEmpty || outcome.provenIds != ids` and **both disjuncts are load-bearing**:
`moveProvingDestinations`' gone branch returns `MoveOutcome(provenIds: [id], provenDestinations: [],
confirmedGoneIds: [id])` — the two lists OVERLAP by design, because `provenIds` answers *"is this
member settled?"* and `confirmedGoneIds` answers *"is it still there?"* — so for a single-member
request `provenIds == ids` holds and a `provenIds`-only comparison returns silence for the exact case
the fix exists to close, letting the `Void` contract read the server's authoritative "gone" as
"moved". Do not simplify it back to one comparison.

That second instance does NOT raise `Recurrences`: it is the same shape found by the same census in
the same unmerged branch, closed by hardening the contract rather than by a second, later commission
of the error. Counting it would double-charge one occurrence of the tell.

**A THIRD instance — and this one DOES raise `Recurrences` to 2 (2026-09-06).** After the census
above reported clean, an independent architecture gate angle found that
`AccountManager.retirePartiallyCompletedOp` — the path this same PR promoted to primary for every
multi-member Gmail and Graph operation — never called `recordMembersThatEnteredInbox`, while both
paths it displaced (the whole-op success arm and `replayRetainedRetirements`' `.full` arm) did. A
multi-member move into the Inbox therefore recorded the ADR-IOS-008 decision-3 event for the single
member that settled through the whole-op arm and silently dropped it for the other N−1;
`ActiveAIQueue.repopulateFromDatabase` does not cover them, because it is bounded by the newest-
`SyncConfig.maxRecentEmails` window that the window-exempt enqueue exists to escape. Fixed
`f3f16169a` by adding the call post-commit with `frozenRetiredOp` (never `currentOp` —
`optimisticMoveToFolder` has already moved all N header rows locally, so `currentOp` would enqueue
members the server has not moved), mirrored into the `.partial` replay arm. Four call sites now.

This is the **quieter form of the tell**, and it counts because I committed the error a second time
after having written this record: I was satisfied that the path I edited was correct and did not go
looking for the other paths that were supposed to agree with it.

⚠️ **It also falsifies the mechanical check below as a sufficient guard — read that section's
limitation before relying on it.**

## Why it is not obvious

Every instinct that normally catches a lost behaviour was pointed the wrong way:

- **The diff grew.** The function gained lines. Deletions announce themselves; an overwrite of one
  call by another at the same insertion point does not.
- **The reviews were aimed elsewhere.** Two independent gate angles reviewed this exact commit range
  and both filed the same P1 about loop budgets. A finding that big is where attention goes.
- **The path was genuinely new.** `retirePartiallyCompletedOp` was documented as test-only
  ("no production provider returns a strict subset"), so a missing call in it read as a path that
  had never needed one — while the same change had just made it the primary production path for
  every multi-member Gmail and Graph operation. The stale doc comment actively defended the omission.
- **It is unreachable, so no test could go red.** Correctness cannot be established by running the
  suite here; only by comparing against base.

## The rule

When a change narrows or replaces what a helper does, diff the CALL-SITE COUNT of every helper in
the touched file against base and account for each drop — and require the paths that are supposed to
mirror each other to still agree.

## Mechanical check

```bash
# Every helper whose call-site count DROPPED from base to candidate in one file.
# Each drop must be explained by an intended deletion, or it is a lost call.
B=c5c715c60; C=f4a355426; P=TabMail/Services/Account/AccountManagerQueue.swift
for R in "$B" "$C"; do
  git show "$R:$P" | grep -oE '[a-zA-Z_][A-Za-z0-9_]*\(' | sed 's/(//' \
    | sort | uniq -c | awk '{print $2"\t"$1}' | sort -k1,1 > "/tmp/cd_${R}.tsv"
done
join -t$'\t' -a1 -e0 -o 0,1.2,2.2 "/tmp/cd_${B}.tsv" "/tmp/cd_${C}.tsv" \
  | awk -F'\t' '$2>$3 {printf "%-45s base=%s cand=%s\n", $1, $2, $3}'
```

### ⚠️ What this check STRUCTURALLY CANNOT catch

It compares call-site COUNTS between base and candidate and flags **drops**. The third instance above
produced **no drop**: `recordMembersThatEnteredInbox` occurred 5 times in base and 5 times in the
candidate. The lost call was not removed from an existing path — a NEW path was promoted to primary
without ever acquiring the call its predecessors owed. A count that holds steady while the set of
paths that need the call grows is invisible to this check, and it read CLEAN on the exact commit that
carried the defect.

So the count diff is a floor, not a ceiling. When a change promotes, replaces, or adds a path, the
count comparison must be followed by a **per-path census**: enumerate every path that reaches the
same terminal state, list the statements each one executes after its commit, and diff those lists
against each other. State the resulting count as a falsifiable claim ("all four retirement paths
execute the same five post-commit statements") so the next reviewer can refute it rather than re-derive
it. That census — not this one — is what would have caught it.

**Self-test it before trusting it** (a census that reports clean by failing is worse than none): run
it with `C=a270c312a`, where the defect is live, and it must print
`materializeDeferredMoveSuccessors  base=4 cand=3`. Run it with `C=f4a355426` and that symbol must be
absent, leaving exactly three drops — `deleteOne` 9→8, `dropDeferredMoveSuccessors` 5→4 and
`PendingOperation` 1→0 — all seven of whose removed lines sit in the single hunk
`@@ -2119,49 +2225,5 @@` that deletes the batch-splitting arm on purpose. Zero unexplained.

Pair it with the mirror-path check, which needs judgment and so is not automatable: for a retirement
or finalisation path, list every sibling path that is supposed to reach the same terminal state
(here `replayRetainedRetirements`) and diff their call sequences against each other, not against
their own previous revision.
