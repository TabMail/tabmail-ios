# `uidValidityResetPendingAt` is a RE-DRIVE flag that stays armed on purpose, and the crawl was the last consumer still writing under it (2026-08-05)

## The absolute this corrects

A reviewer — and a coordinator's own brief — will reach for *"prove the flag is transient"* when
asked whether it is safe to make a guard refuse while `uidValidityResetPendingAt` is armed. **That
property is FALSE, and it is false deliberately.** `Folder.uidValidityResetPendingAt`'s own doc says
so: *"re-drive state, not admission arbitration: every abort leg of the reaction leaves it SET, so
the folder is retryable rather than half-reset."* Step 5's `catch` logs *"flag stays set, re-drive
will retry"*. The clear at `AccountManagerUidValidityReset` sits **inside a write that can throw and
behind two `return false` legs** — the "unconditional clear after the loop" that gets quoted is a
sentence in a doc comment, not the code.

So a stop-rule of the form *"if any path can leave the flag armed, the fix is wrong"* **fails closed
in the wrong direction**: it abandons a correct fix because it demanded the wrong property.

## The discharge that actually works, and why

Three independent legs. Any reviewer asked to bless a refusal gated on this flag should use these
rather than re-deriving transience:

1. **A refusal writes nothing, so it cannot become its own durable re-entry condition.** The failure
   shape this repo fears — *"a transient container plus a durable re-entry condition is a permanent
   refusal"*, documented at `resetEmptyFolderCrawlEpoch` — needs the refusal to leave behind state
   that re-triggers it. A guard that returns `false` and skips a write leaves the database exactly
   as it was; the moment the flag clears, the next pass writes normally.
2. **An armed folder is ALREADY excluded from every other consumer.** Verified by grep at
   `57c5fe8d4`: new gestures (`AccountManagerActions.swift:497, 583, 662`), full sync
   (`SyncEngineFullSync.swift:315, 1053`), the durable queue drain (`AccountManagerQueue.swift:388,
   449`), and the AI queue (`ActiveAIQueue.swift:646`, whose comment already enumerates this as
   "arm 5, TRANSIENT"). The backfill crawl was the **one remaining consumer that still wrote under
   an armed flag**. Adding the guard therefore makes the flag *consistent* across consumers rather
   than inventing a new refusal class — which is a much stronger argument than transience, and is
   checkable by one grep.
3. **The only forever-armed state is one the code deliberately never creates** — arming on a SELECT
   that returned no UIDVALIDITY, which is documented as a PERMANENT BRICK. In that state the folder
   is already dead for all four consumers above, so the crawl guard changes nothing about it.

## The defect this closed

`SyncEngine.crawlWalkWriteAllowed` CASed only `Folder.lastKnownUidValidity`, which the reset purge
**deliberately leaves at the OLD value** during the reset window. An already-running old-epoch crawl
therefore satisfied `stored == premiseEpoch` *after* the purge and could write
`backfillComplete = true` or re-plant a stale `backfillUidCursor`. Because the new-epoch sync starts
inserting rows immediately, the folder is non-empty by the time the stale crawl commits, so
`resetEmptyFolderCrawlEpoch` (which only repairs ZERO-row folders) can no longer fire. Result: a
permanent completeness gap — the folder is dropped from all later crawl selection. Fixed at
`16ecafd93` by adding `guard folder.uidValidityResetPendingAt == nil else { return false }`.

The guard's own doc comment had already confessed the gap — *"v3 has the clearer and, since T4.S6,
the flag as well — **but this guard does not read the flag**"* — for three review rounds before
anyone acted on it. **A comment that documents a gap is not a decision to accept it; treat a
self-confessed gap as an open finding until a register row says otherwise.**

## How to write a mirror-image stop-rule from now on

Not *"prove property P; if P is false, STOP"* — that binds the fix to a property that may be false
for unrelated reasons. Instead: *"state the mirror image, attempt a discharge, and if you cannot
discharge it, report the argument you tried rather than abandoning the fix."* The reviewer is better
placed than the brief author to find the right argument, because they are reading the code.
