# MIS-IOS-008 — verified that a recovery path EXISTS, and called the edge "recoverable" without asking where that path itself is blocked

**Class:** review-discipline / fail-closed design
**Severity:** high (a false "recoverable" claim shipped in a commit body, and it was the load-bearing justification for the fix's accepted cost)
**First seen:** 2026-08 · **Recurrences:** 1 · **Status:** Active
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
