# MIS-IOS-023 — I wrote a new call over the one that path already owed

**Class:** data-integrity
**Severity:** critical (dropped user intention — latent: unreachable on today's providers, reachable on the next provider change)
**First seen:** 2026-09 · **Recurrences:** 1 · **Status:** Active
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

**A second candidate instance of the identical shape, same PR, found 2026-09-06 and NOT counted in
`Recurrences` because it has not been adjudicated.** The same change narrowed
`ExchangeProvider.moveProvingDestinations` from `for id in ids` / `MoveOutcome(provenIds: ids)` to
addressing `ids.first` and returning a one-member outcome without throwing. Its caller inside the
same file — the `EmailProvider` conformance `move(ids:from:to:)`, whose whole body is
`_ = try await moveProvingDestinations(...)` — is **byte-identical to base** and now discards a
partial result while returning `Void`, which its protocol contract means "all N moved". Unreachable
today only because `dispatchOperation`'s `.move` arm casts `provider as? ExchangeProvider` and
returns from inside that branch. Held pending a design consult; recorded here so the class is
visible even if the ruling is "leave it".

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
