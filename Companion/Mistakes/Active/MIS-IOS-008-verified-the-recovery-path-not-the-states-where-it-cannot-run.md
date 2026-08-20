# MIS-IOS-008 — verified that a recovery path EXISTS, and called the edge "recoverable" without asking where that path itself is blocked

**Class:** review-discipline / fail-closed design
**Severity:** high (a false "recoverable" claim shipped in a commit body, and it was the load-bearing justification for the fix's accepted cost)
**First seen:** 2026-08 · **Recurrences:** 3 · **Status:** Active
**Related:** `MIS-IOS-007` (the same session, the same guard — a premise that felt checked because real code was read) · **Rule owner:** `tabmail-ios/CLAUDE.md` § *THE MANTRA*

## The tell

I have made an edge fail closed. The mantra says that is correct **if** the system reaches a correct
state later — by a sync pass, a retry, or one ordinary gesture. So I go find the recovery path. I
find it. I read it in real code, and I can name the function and the transaction it runs in. I write
**"recoverable"** and move on.

**The confidence is real and it is misplaced, because I proved the wrong proposition.** I proved
*"a recovery path exists"*. The mantra asks *"does this state reach a correct state later"* — which
requires the recovery path to be **runnable from the state I just created**. I never enumerated the
states where the recovery path itself refuses to run.

The tell in one line: **I can name the recovery mechanism, but I have not named a single state in
which it does not fire.** If asked "when does the recovery NOT happen?" I would have to go look —
which means I never checked.

## What actually happened

2026-08-04, branch `v3`, fixing the round-1 audit-train BLOCKING finding in
`AIWriteTarget.resolveCurrentHeader` (commit `6b689890d`).

Arm 7 was fail-**open**: `guard let liveEpoch = folder?.lastKnownUidValidity else { return header }`
admitted an AI write when the `Folder` row was **absent** or its epoch never observed. The fix made
both refuse. The brief explicitly flagged the cost — a refused AI write for an RFC-less row — and
required the implementer to *"confirm this is recoverable… and if you find it is NOT recoverable for
some reachable state, STOP and report rather than shipping a permanent AI blackout."*

The implementing agent traced the recovery chain and reported it sound. **I verified it too**, and
agreed. The chain is real:

- `SyncEngine.runSyncMessages` calls `bootstrapFolderUidValidity` inside the same `dbPool.write`
  transaction as the merge, **before** the header inserts — so a first population does stamp the
  folder.
- An already-populated folder can earn its epoch through
  `verifyAndBootstrapPrePopulatedFolderEpoch`.
- A refused write leaves `summaryBlurb` nil, so the AI queue's arbiter re-drives the job.

Every one of those statements is TRUE. The commit body said the refusal was recoverable. **Both
reviewers in the next round found a state where it is not**, and found it independently of each
other:

- blind bootstrap refuses a folder that **already holds rows** (`NOT EXISTS (messageHeader WHERE
  folderId)`), and
- the verified door **excludes RFC-less rows from its sample** and returns `.unobservable` on an
  **all-RFC-less** population.

So for an RFC-less row in a folder that is both already-populated and all-RFC-less, *neither* door
can ever stamp the epoch, and the refusal is **permanent**. Worse, the consumer makes it expensive
rather than inert: `ActiveAIQueue.readJobOutcome` returns `.needsRetry`, retries run with
`maxRetries: .max` and a 30 s backoff cap, and `MessageAICache` cannot short-circuit because it keys
by `rfc822MessageId` — which these rows do not have. Summary, action and reply each re-run a paid
model call indefinitely. Registered as `IOS-AI-003`.

**The fix is still correct** — refusing is right, and the alternative was a C3 misattribution. What
was wrong was the *claim about its cost*, which is the thing the owner would have used to decide
whether to accept it.

## Why the usual defences did not catch it

- **It was not an unchecked assumption.** Real code was read, by two people, and everything read was
  accurate. The error was in the *quantifier*, not the facts.
- **The brief demanded the check** and even specified a STOP condition for exactly this. Being asked
  the right question was not enough, because the question was answered in the existential form
  ("does a path exist?") rather than the universal one ("does it exist from every state I now
  create?").
- **The doc comment on the arm being replaced already named the hazard** — arm 8's comment says *"a
  paid API call repeated forever for a summary that could never land"*. The cost was written down,
  next to the code, and still missed.

## The countermeasure

When about to write **"recoverable"**, do not stop at naming the recovery path. Do the negative pass:

1. **Name the recovery mechanism** (sync pass / retry / user gesture).
2. **Enumerate its own preconditions**, and for each one ask: *is there a state, reachable from the
   refusal I just introduced, in which this precondition is false?* Read the guards on the recovery
   path itself — `NOT EXISTS`, sampling predicates, early returns, `.unobservable`/`.cannotConfirm`
   arms.
3. **State at least one concrete state where recovery does NOT fire**, or state that you searched for
   one and why none exists. *"Recoverable"* with no negative case recorded is an unfinished check.
4. **Then check what the retry costs.** A refusal that is retried forever is not inert: money,
   battery, and queue slots are real. Look at the consumer's retry ceiling and at whether any cache
   can short-circuit it.

This is the repo-local form of the standing rule that an absolute claim needs its negative case. The
mantra's test is **recoverability of the state**, never **existence of a mechanism** — and those two
come apart precisely where a guard on the recovery path excludes the same rows the refusal caught.

---

## Instance 2 — 2026-08-12, `IOS-AI-004`: the recovery gesture required the row to be ON SCREEN

Registering `IOS-AI-004` (no AI enqueue when a message enters an inbox by local move) as an accepted
MANTRA residual rather than a defect. The load-bearing sentence was:

> **Masked in ordinary use because opening the message processes it on demand via
> `AccountManager.processOpenedMessage` — that tap IS the MANTRA recovery gesture.**

`processOpenedMessage` is real, it is reached from `MessageDetailViewModel.loadBody`, it enqueues with
priority, and its `guard let opened, opened.current.isInInbox` is correct. Every fact checked out —
**again**. And again the quantifier was wrong: **a tap gesture requires a tappable row**, and the row
was hidden by the then-unfixed move-visibility defect. Both device episodes that motivated the record
were captured *before* the visibility fix landed, i.e. from states where the named recovery gesture
**could not be performed at all**. The record even says so, in its own next clause — the precondition
was written down, adjacent to the claim, and still did not travel back into the claim.

**What makes this instance distinct from instance 1, and worth its own entry:** there the blocking
guard was in the *code* of the recovery path (`NOT EXISTS`, an all-RFC-less sample). Here the recovery
path's code was fine and the blocker was **elsewhere in the product** — a UI defect in a different
subsystem, filed as its own issue, that removed the affordance the gesture needs. So step 2 of the
countermeasure is too narrow as written: *"read the guards on the recovery path itself"* would not have
caught this, because there was nothing wrong with the recovery path.

**Countermeasure, amended — extend step 2 with the affordance question:**

> 2b. If the recovery is **a user gesture**, name what the user must be able to see or reach in order
>     to perform it, and check that *that* is true in the failing state. A gesture is not a mechanism
>     you can read in one function; it is a mechanism plus an affordance, and the affordance is
>     usually owned by a different subsystem than the one you are registering.

**Sequel, and the reason this entry is not merely historical:** the gap was closed on 2026-08-13 by
`1eb41702e`, which added the missing trigger — so the residual that remains is *not* the one this
argument was made about. The MANTRA argument was never re-run against the narrowed state; the record
now carries an explicit reopen condition instead. **A residual that changes shape needs its
recoverability argument re-run, not inherited.** Related: `MIS-IOS-011` (invoking THE MANTRA's name
instead of running its test).

---

## Instance 3 — 2026-08-15, `IOS-AI-004`: checked identity on a recovery path that selects by state

The narrowed record correctly named `ActiveAIQueue.repopulationCandidates` as the durable fallback
and correctly named its recent-window boundary. It nevertheless continued to describe the residual
as RFC-less identity recovery: either construct a way to re-identify the moved row across a remap,
or keep the issue open.

That asks the recovery path to satisfy a precondition it does not have. The production query contains
no RFC or provider-address predicate; it selects the row in its **current** location by
`isInInbox`, `bodyComplete`, and missing AI fields. Gmail canonicalization may change the id and an
IMAP path may leave it unchanged, but either way the query reads the durable row now present. RFC
governs the immediate move-event resolver only. The negative pass belongs on the selector's actual
preconditions: body readiness and membership in the recent backlog window.

This is the same quantifier error from the opposite direction. Instances 1 and 2 proved that a named
recovery mechanism was not runnable from every claimed state. This instance imposed an identity
requirement on the fallback without checking whether the fallback used identity at all. The amended
countermeasure is: **enumerate the recovery mechanism's predicates mechanically; do not transfer a
predicate from the failing path merely because both paths target the same user-visible state.**

### Pre-compaction index line (verbatim, 2026-08-15)

The Instance 3 recurrence initially pushed the mandatory index over its 12 KB budget. Its full index
text is preserved byte-for-byte here before the startup-context pointer was shortened:

```text
- **[MIS-IOS-008](Companion/Mistakes/Active/MIS-IOS-008-verified-the-recovery-path-not-the-states-where-it-cannot-run.md)** — proved a recovery path EXISTS and wrote "recoverable", never asking from which states that path is itself blocked (`IOS-AI-003`; false cost claim shipped in `6b689890d`). THE MANTRA's test is recoverability of the STATE, not existence of a MECHANISM. Instance 2 (`IOS-AI-004`) showed that a gesture also needs a reachable affordance. **Instance 3 imposed an RFC identity requirement on `repopulationCandidates`, even though that fallback selects current rows by state and contains no identity predicate. Enumerate the recovery mechanism's actual predicates; do not transfer a guard from the failing path merely because both target the same visible state.** A changed residual needs its recoverability argument re-run. (×3)
```

---

## Pre-compaction index line (verbatim, 2026-08-13, pass 4)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 62% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced block
so its index-relative link is not re-resolved from this directory, because the index line had
accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-008](Companion/Mistakes/Active/MIS-IOS-008-verified-the-recovery-path-not-the-states-where-it-cannot-run.md)** — proved a recovery path EXISTS and wrote "recoverable"; never asked from which states that path itself is blocked. The mantra's test is recoverability of the STATE, not existence of a MECHANISM, and they come apart exactly where a guard on the recovery path excludes the same rows the refusal caught. Shipped a false cost claim in `6b689890d`'s body; both round-2 reviewers found it independently (`IOS-AI-003`). A refusal retried forever is not inert — check the retry ceiling too. **Instance 2 (`IOS-AI-004`): the recovery path's CODE was fine — the blocker was an affordance owned by a DIFFERENT subsystem.** "Tapping the message is the recovery gesture" needs a **tappable row**, and the row was hidden by the then-unfixed move-visibility defect, so both motivating device episodes came from states where the gesture could not be performed. Reading the recovery path's own guards would not have caught it. New step 2b: if the recovery is a **user gesture**, name the affordance it requires and check *that* in the failing state. Also — a residual that later changes shape needs its recoverability argument **re-run, not inherited**. (×2)
```

---

## Pre-compaction index line (verbatim, 2026-08-20, pass 5)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 19% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced
block so its index-relative link is not re-resolved from this directory, because the index
line had accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-008](Companion/Mistakes/Active/MIS-IOS-008-verified-the-recovery-path-not-the-states-where-it-cannot-run.md)** — called a state "recoverable" after finding a mechanism, without proving it can run there (`IOS-AI-003`/`004`). Instance 2 adds the affordance a user gesture needs. **Instance 3 imposed RFC identity on `repopulationCandidates`, though that fallback selects by state. Enumerate the recovery's actual predicates; never transfer a guard from the failing path.** Re-run the argument whenever the residual changes shape. (×3)
```
