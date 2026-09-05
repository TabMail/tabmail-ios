# MIS-IOS-004 — I treated "I could not determine the answer" as "the provider said it's done"

**Class:** data-integrity
**Severity:** critical (dropped user intention)
**First seen:** ongoing · **Recurrences:** many (+1, 2026-09-04, GitHub #115) · **Status:** Active
**Related:** [MIS-IOS-003](MIS-IOS-003-reconstructed-an-address-the-wire-already-gave-us.md) · **Rule owner:** `Companion/Rules/Active/never-drop-user-intention.md`

> **`CLAUDE.md` calls this "the single most repeated defect in this codebase's history."** It has its
> own entry because it is not one bug — it is a shape that regrows in every new subsystem.

## The tell

An operation returned something that is not a success: a thrown read, an unresolvable identity, a
failed durable write, an unknown epoch. The queue needs to make progress and this op clearly cannot
execute right now. Retiring it feels like correct cleanup rather than a dropped intention.

## What actually happened

A queued operation may leave the queue for exactly **four** reasons, and no others: provider success;
a **provider-authoritative** stale/no-op result; annihilation by a newer inverse user action (only
when never attempted, members matching exactly, a true inverse); and invalidation by a **proven** id
reset in its own address space.

The recurring defect is collapsing the second into a catch-all. *"We could not determine the answer"*
is **not** provider-authoritative. A thrown read, an unresolvable identity, a failed durable write
and an **unknown** epoch are all **retryable** — forever.

## Why it is not obvious

Both cases arrive as "this op did not succeed", through the same code path, often the same `catch`.
The difference is not in the control flow but in the **epistemics**: exit 2 requires a positive fact
the provider asserted; the failure cases are an *absence of evidence*. Absence of evidence is
invisible in a stack trace.

## The rule

Retire an op only on a fact the provider **asserted**; every "unknown" is retryable forever.

## Mechanical check

```bash
# Every queue exit must map to exactly one of the four enumerated reasons:
rg -n 'delete.*pendingOperation|retire|dequeue' --type swift TabMail/Services/
# For each hit: which of the four? If the answer is "none of them", it is a dropped intention.
```

**Exit 4 does not widen exit 2.** Exit 4 needs a **proven** epoch change — a positive fact. Exit 2's
*unknown* epoch is an absence of evidence and stays retryable. The two are disjoint; exit 4 is the
only exit that is a failure, it is deliberately narrow, and nothing else may use it. A bounded,
visible, retryable quarantine is **not** a discard, and a transient failure is **not** an exit.

## Instance (2026-08-04) — the shape outside the queue: a CRAWL marked complete on an unknown UIDNEXT

The same epistemic collapse, in `SyncEngineBackfillWalk`, where there is no `PendingOperation` and
therefore nothing that looks like a queue exit — which is why it survived. `SelectHandler` assigns
`Mailbox.uidNext` **only** when the wire carried `* OK [UIDNEXT n]`, and the field's default is
`UID(0)`. So *"the server did not report a UIDNEXT"* reached the `.fresh` branch as the **number 0**,
`initialCursor = uidNext - 1` became `-1`, and `-1` took the `initialCursor < 1` early-out that was
written for UIDNEXT **1** — the single value that PROVES the mailbox never held a message (RFC 3501
§2.3.1.1: UIDs are assigned strictly increasing from 1). The folder was written
`backfillComplete = true`, completion removes it from `remaining` on every later pass, and **nothing
ever revisited it**: an entire folder's mail permanently unreachable, from an absence of evidence.

`uidNext == 1` is *evidence of empty*. `uidNext == 0` is *absence of evidence*. Same branch, opposite
epistemics — exactly exit 2 vs "could not determine", with `backfillComplete` playing the role of the
queue exit.

**The tell was already in the file, one line long.** `IMAPProvider.getUidNextWithEpoch` read
`return (Int(selection.uidNext.value), observed != 0 ? observed : nil)` — **one of the two
absent-evidence values normalised and the other not**, on the same line, for the same wire reason
(both are `nz-number`, so zero is unreportable). *An asymmetry between two sibling values handled at
one site is a defect report.* Fixed by making the absence unrepresentable as a number: the accessor
returns `uidNext: Int?` normalised symmetrically, and the walk declines the folder when it is `nil`
(same property `6d460aa99` got by replacing `limit:` with `coverage:`).

**Generalisation this instance adds:** the four-exit rule is written for the action queue, so it is
only ever *applied* there. Any **terminal, non-revisiting state** is a queue exit wearing different
clothes — `backfillComplete`, `headerComplete`, a cursor advanced past a range, a folder dropped from
a `remaining` set. Ask the exit-2 question of every one of them: *is the fact that authorised this
terminal write something the server ASSERTED, or something we failed to learn?*
Detail: `Companion/Memory/Current/106-a-filter-after-the-limit-narrows-the-page-instead-of-selecting-it.md`,
register `KNOWN_ISSUES.md` `IOS-BACKFILL-001`.

## Instance (2026-08-04) — a 404 on an address WE invalidated, read as "the provider says done"

The Graph/Exchange move arm drops the `PendingOperation` when a later op against the moved message
returns `404 ErrorItemNotFound`. **Three different world-states produce that 404:** the message was
genuinely deleted (exit 2 legitimately applies); the message **moved** and its id churned (the op is
neither done nor inapplicable); or Graph is transiently inconsistent after a change, which Microsoft
documents. The arm collapses all three into "gone, therefore done".

**What makes this instance distinct from every earlier one: we manufactured the ambiguity ourselves.**
`ExchangeProvider.moveMessage` discards the `/move` response that carries the new id (`MIS-IOS-003`
instance 5), so the id we later present is one *we* invalidated. The provider is answering the
question we actually asked — *"is there a message with this id?"* — truthfully. It is **not** answering
*"is the operation you queued already done?"* Those are different propositions, and only the second
one is exit 2. **A truthful answer to the wrong question is still "we could not determine."**

Exit 4 does not apply either: it requires a **proven** id reset disagreeing with the op's durable
`observedUidValidity`, which on Graph is always `nil`, and it is scoped to an address *space*, not to
one item's id.

The precedent was one screen away in the same file — `isPermanentlyInvalidError`'s own doc comment
reads *"🚨 A BARE STATUS CODE IS NOT A CLASSIFICATION."*

**Why it is BLOCKING rather than registrable, stated so the distinction survives:** the sibling row
`IOS-QUEUE-006` is registrable *because* the local mutation and the durable op share one transaction,
so the message stays visible where the user left it and one ordinary gesture re-issues it. **Here the
optimistic local move lands and is never rolled back — the UI shows success while the durable half is
destroyed.** The mantra's "recoverable by one ordinary user gesture" cannot fire on a user who was
shown success and has no reason to act. And the repair is date-windowed (`selectStaleHeaders`' `.date`
arm) and Exchange delta is Inbox-only, so an Archive→Trash move of older mail is never swept; every
repeat of the gesture enqueues the same dead id and is dropped identically. Registered `IOS-GRAPH-002`.

**Mirror-image trap, named because it is the obvious fix:** merely reclassifying the 404 as *retryable*
converts a silent drop into a **lane wedge** (`buildLanes` keys on `accountId:folderPath:messageId`),
and a starved op is also a dropped intention. It is the **re-key** that makes retry terminate.

## Instance (2026-09-04, GitHub #115) — a tagged NO on a raw re-established channel read as "possibly partially completed", and retired

`IMAPProvider.move`'s atomic route caught `IMAPError.moveFailedAfterPossiblePartialCompletion` and
returned `MoveOutcome(provenIds: ids, provenDestinations: [], requiresSourceReconciliation: true)` —
every member retired as dispositioned (`3f6a0a5a8`, 2026-08-13). SwiftMail raises that error for
**any** tagged NO/BAD on `UID MOVE` with no retained `COPYUID`. The fuzzer (`providerIdQueueFuzz`,
seed `0x70D8000000000002`, under full-suite load) produced the case where nothing happened at all: a
`disconnect()` landed in the one-RTT window between the pre-move `SELECT` and the `UID MOVE`,
SwiftMail's `executeCommandBody` re-opened a raw channel (no LOGIN, no SELECT) and sent the MOVE, and
the fake answered `NO No mailbox selected` before its handler ran — zero mutation. The arm took the
success path; the queue emptied with the message still in INBOX on the server and the UI already
showing success. The `IntentionLedger` settled `UNACCOUNTED (stillQueued=false endStateAchieved=false)`.

**The tell, this time:** the arm's own comment said *"the server MAY already have changed either
mailbox but supplied no trustworthy mapping"*. A retirement justified by what the server *may* have
done is a retirement on an absence of evidence. The sibling arm one line above,
`moveFailedAfterPartialCompletion(copyUID:)`, is the shape that IS exit 2: it names the members the
server *did* move. Two adjacent catch arms, one carrying evidence and one carrying a possibility,
handled identically — the same one-site asymmetry the 2026-08-04 UIDNEXT instance describes.

**What the countermeasure missed:** the arm landed WITH tests
(`IMAPMoveWireContractTests.atomicPossiblePartialCompletionIsNotRetryable`,
`NeverDropExitClosureTests.aPossiblyPartialAtomicMoveIsNeverReissued`), but both drove a fake that
COMMITS the move and then answers NO, so both pinned the one world state in which retiring is
harmless and asserted the mechanism (`moves.count == 1`, `provenIds == ids`). Neither exercised a NO
with zero mutation — the world state every transport-level refusal produces. A test that blesses the
mechanism inherits the spec's error. The arm also silently reversed the recorded `IOS-IMAP-013`
disposition ("a tagged NO/BAD remains a typed failure; the durable operation stays queued") without
amending the register.

**Fix (#115): delete the arm.** The error falls into the generic `catch` and is rethrown;
`executeSingleOp` requeues and halts the lane; the next drain retries with a fresh LOGIN/SELECT.
Retrying `UID MOVE` is safe (RFC 3501 §6.4.8 ignores absent UIDs, §2.3.1.1 forbids UID reuse within
an epoch, an epoch change is exit 4); the residual duplicate on a server that violates RFC 6851 §3.3
is already accepted (`IOS-IMAP-006`, `IOS-QUEUE-007`). Pinned by
`NeverDropExitClosureTests.aRefusedAtomicMoveStaysQueuedAndTheNextDrainLandsIt` (red on the pre-fix
provider). Sibling of the same shape, NOT fixed here: `AccountManagerQueue.reconcilePendingOperations`
deletes an attempted in-flight `.move` at launch "instead of risking a duplicate" — the arm cited it
as precedent.

---

## Pre-compaction index line (verbatim, 2026-08-13, pass 4)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 62% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced block
so its index-relative link is not re-resolved from this directory, because the index line had
accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-004](Companion/Mistakes/Active/MIS-IOS-004-conflated-unknown-with-authoritative-stale.md)** — treated "could not determine" as "provider says done" and dropped a user intention. **The single most repeated defect in this codebase's history.** Instance (2026-08-04): the shape **outside the queue**, where nothing looks like a queue exit — a SELECT that reported no UIDNEXT arrived as `UID(0)`, so `initialCursor = -1` took the `< 1` early-out written for UIDNEXT **1** (the value that PROVES an empty mailbox) and wrote `backfillComplete = true`, permanently un-crawling the folder. The tell was one line wide: `getUidNextWithEpoch` normalised the epoch's zero and not the UIDNEXT's, same line, same `nz-number` reason. **Any terminal, non-revisiting state — `backfillComplete`, `headerComplete`, an advanced cursor, a folder dropped from `remaining` — is a queue exit in other clothes; ask the exit-2 question of each.** Instance (2026-08-04b): a Graph **404 on an address WE invalidated** read as exit 2 — three world-states (deleted / moved-and-churned / transient Graph inconsistency) collapsed into "gone, therefore done", on an id made dead by our own discarded `/move` response. **A truthful answer to the wrong question is still "we could not determine"**: Graph answered *"no message has this id"*, not *"your queued op is done"*. BLOCKING rather than registrable because the optimistic local move lands and is never rolled back, so the UI shows success and the "one ordinary gesture" recovery cannot fire; repair is date-windowed and Exchange delta is Inbox-only → `IOS-GRAPH-002`. Trap: reclassifying the 404 as merely *retryable* converts the drop into a **lane wedge** — the re-key is what makes retry terminate. (×many)
```

---

## Pre-compaction index line (verbatim, 2026-08-20, pass 5)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 19% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced
block so its index-relative link is not re-resolved from this directory, because the index
line had accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-004](Companion/Mistakes/Active/MIS-IOS-004-conflated-unknown-with-authoritative-stale.md)** — treated "could not determine" as "provider says done" and dropped a user intention. **The single most repeated defect in this codebase's history.** Recurs OUTSIDE the queue, where nothing looks like a queue exit: a missing UIDNEXT arrived as `UID(0)`, took the `< 1` early-out written for UIDNEXT **1**, and wrote `backfillComplete = true`; a Graph **404 on an address WE invalidated** collapsed three world-states into "gone, therefore done" (`IOS-GRAPH-002`, BLOCKING). **Any terminal, non-revisiting state — `backfillComplete`, an advanced cursor, a folder dropped from `remaining` — is a queue exit in other clothes.** (×many)
```
