# IOS-GRAPH-005

> **Post-freeze record.** Added 2026-09-05 through the amendment surface in
> `Scripts/compact_known_issues.rb`. It has no row in the hash-pinned archive and is not regenerated
> from it. GitHub: [TabMail/tabmail-ios#114](https://github.com/TabMail/tabmail-ios/issues/114).
> Related: [#117](https://github.com/TabMail/tabmail-ios/issues/117) (migrate Outlook to Graph
> immutable ids — the structural fix for the residual below) and
> [#116](https://github.com/TabMail/tabmail-ios/issues/116) (the launch-time drop of an interrupted
> `.move`, which the residual depends on).

- Register classification: `resolved`.
- Relates to: `Companion/Process/Current/KnownIssues/Amendments/ios-queue-008.md` (whose
  "why Outlook is excluded" section this record SUPERSEDES),
  `Companion/Process/Current/KnownIssues/ios-graph-002.md`,
  `Companion/Process/Current/KnownIssues/ios-graph-003.md`.

## Status

✅ **RESOLVED (2026-09-05, `<merge-hash — FILL AT MERGE>`).**

The hash is deliberately a placeholder rather than the branch's pre-merge hash.

⚠️ The hash above must be the hash the change carries **in `main`'s ancestry after merge**, not the
pre-rebase hash of the same patch. `ios-queue-008.md` records exactly that trap: a pre-rebase hash
still resolves locally, reads as valid, and points at a commit no released build contains.

## Subsystem and search terms

Action queue; Microsoft Graph; Outlook; drain lanes; address handoff; retirement transaction;
`readdressQueuedOperations`; `accountScopedIdAccountIds`;
`AccountManager.accountScopedIdAccountIds(_:)`; `buildLanes(_:accountScopedIdAccountIds:)`;
`MessageHeaderRekey.finishMove(_:destinations:addressChangesOnMove:accountScopedIds:db:)`;
`MoveFinishResult.readdressedOperationIds`; `PendingOperation.markQueued`;
`AccountManager.liveOperation`; account-scoped id; folder-independent vs immutable; row-following
re-key; `IOS-QUEUE-008`; `IOS-GRAPH-002`; `IOS-GRAPH-003`; `IOS-QUEUE-001`; `MIS-IOS-003`;
`OutlookQueueHandoffTests`; `inheritedRowid` (NOT introduced — see "what this record does not
contain").

## The two shapes this record is about

Both are one Outlook message and two user gestures, and both end with the user's LATEST intention
lost — the red line.

**Shape 1 — a follower queued behind a move.** The user archives a message and then acts on it
again (mark read, flag, move somewhere else) before the first gesture has drained: offline, or
simply inside the same drain pass. Microsoft Graph REALLOCATES a message's default id on every
folder move and this tree sends no `Prefer: IdType="ImmutableId"` (`IOS-GRAPH-002`), so the second
operation names an id that the first operation's success has just destroyed. It reaches the wire,
Graph answers `404`, and `executeSingleOp`'s single-message conflict arm reads that as
provider-authoritative "already done" and DELETES the operation. Nothing on the server or in the
queue records that the user ever asked.

**Shape 2 — delete, undo, delete again.** The device sequence behind `IOS-QUEUE-008`, in the Graph
id space. The undo is an ordinary reverse move built from the OPTIMISTIC row, which still carries
the pre-move id; the re-delete after it is built from whatever row the user is looking at. Every
link in that chain has to carry the address the previous link's wire response proved, or the chain
breaks at the first link that does not.

## Why the obvious fix was the wrong one, and what it cost

`IOS-QUEUE-008`'s fix put Gmail and the demo account on account-qualified drain lanes and
deliberately LEFT OUTLOOK OUT, with a written prohibition against "completing" the fix by adding
`.outlook`. That prohibition was correct at the time and is now superseded, and the distinction is
worth keeping because it is the whole point:

- Account-qualifying Outlook GUARANTEES that a follower runs AFTER the move it shares a message
  with, instead of racing it.
- Under a racing (folder-qualified) key the follower is sometimes wrong and sometimes right, and
  recoverable.
- Under a serialized key with no handoff, the follower is ALWAYS wrong. Serialization converts an
  inherited race into a DETERMINISTIC dropped intention, which is strictly worse.

So the lane change is only correct in the presence of the handoff, and the handoff is only reachable
because of the lane change. The two are one fix and must not be split.

## The fix

1. **The classifier states the property it actually needs.**
   `AccountManager.immutableIdAccountIds` is renamed `accountScopedIdAccountIds` and admits
   `AccountProvider.gmail`, `AccountProvider.outlook` and `DemoSeed.demoAccountId`. The property the
   lane key needs is "one provider id names one message per ACCOUNT", **not** "the id survives a
   move" — Graph satisfies the first and violates the second. The query stays an **id-only** read of
   the raw `provider` column, so one corrupt bystander row still cannot throw
   `DecodingError.dataCorrupted` and wedge every account's drain, and an unrecognised provider string
   still falls on the folder-qualified (safe) side by construction.

2. **The retirement transaction carries the address into the queue.**
   `MessageHeaderRekey.finishMove` gains a NON-defaulted `accountScopedIds: Bool` and a private
   `readdressQueuedOperations`. When the flag is set and the wire proved at least one destination
   address, every `PendingOperation` of the same account that is not this one and not `cancelled`
   and whose members intersect the proven source ids has each such member replaced by its mapped
   destination id — `UPDATE` by primary key, in the SAME transaction that re-keys the header and
   retires the move. The rewritten ids are returned in `MoveFinishResult.readdressedOperationIds`
   and logged through `BackgroundSyncLogger.logQueue` (debug-gated); `IOS-QUEUE-008` took a month to
   diagnose precisely because the lane decision left no readable trace.
   The mapping is per-id, so a multi-member follower is partially rewritten correctly, and chains
   converge because each retirement maps against the ids the row carries at that moment.

3. **The re-key follows the ROW on an account-scoped provider.**
   The member's row is located by `(accountId, messageId)` rather than by primary key at
   `op.destinationPath`, and re-keyed in the folder it CURRENTLY occupies. Exactly one match is
   required: zero is the ordinary "already gone" case, two or more declines. This is what makes
   shape 2 work — when the forward move retires, an undo has already put the row back in the source
   folder, so a destination-keyed lookup misses it and the row keeps a dead id, which the user's next
   gesture then names. G3's folder clause remains, unchanged, on the IMAP arm, where it is correct
   for the opposite reason: a UID is mailbox-local, so a row that is not where the operation put it
   is a DIFFERENT physical message and re-keying it would be a C3 wrong-message mutation.

4. **The drain stops executing stale values.**
   The lane loop re-reads each operation by primary key immediately before executing it
   (`AccountManager.liveOperation`) and skips it if the row is gone. There is deliberately NO
   `?? capturedOp` fallback: the only writers that delete a claimed row are cancel and annihilation,
   both of which are the user withdrawing the intention, so a fallback would resurrect a withdrawn
   gesture from memory and send it to the wire — a fail-DANGEROUS default.

5. **Requeues write columns, not structs.**
   The eight drain sites that returned an operation to `queued` by saving a captured struct now call
   `PendingOperation.markQueued(_:id:incrementRetryCount:)`, which writes only `status` (and
   optionally `retryCount + 1`) addressed by primary key. A `save` is an UPDATE of every column from
   a snapshot taken before any lane ran, so the `.haltLane` and evidence-refused requeues of the
   REMAINING lane members would have written pre-handoff ids back over addresses the wire had just
   proved. `reconcilePendingOperations`, the claim loop and the partial-batch narrowing fetch and
   save inside one transaction and are correctly left alone.

## Accepted limitation — the crash window (owner-accepted 2026-09-04)

If the process dies AFTER Graph returns `2xx` for a move and BEFORE the retirement transaction
commits, that move's queued followers keep the dead id.

- On relaunch `reconcilePendingOperations` DROPS the interrupted `.move` — it cannot distinguish a
  completed move from an uncommitted one and prefers a dropped move to a duplicate. That behaviour
  is itself tracked as [#116](https://github.com/TabMail/tabmail-ios/issues/116) and is deliberately
  NOT touched here.
- The header row converges by sync. The FOLLOWER's intention does not: its next attempt `404`s and
  the conflict arm deletes it.
- It is **not closable in this design.** Re-associating the follower needs the response that was
  lost, and RFC identity may NOT be used as a mutation authority to bridge the gap — that direction
  is banned by ADR-IOS-068 D4 / `IOS-IMAP-002`.
- It is bounded to ONE process death inside ONE write, and it is **strictly narrower than what it
  replaces**: before the handoff existed, the same follower was lost on every such move with no
  crash at all.
- The structural fix is to make Graph ids immutable (`Prefer: IdType="ImmutableId"`), tracked in
  [#117](https://github.com/TabMail/tabmail-ios/issues/117).

The same statement is carried IN THE SOURCE, beside `readdressQueuedOperations` in
`TabMail/Services/MessageHeaderRekey.swift` — a limitation recorded only in a document is not
recorded where the next person to edit the mechanism will read it.

## Tests

All named tests are RED against a named inversion of the fix and GREEN after; the mutation matrix
and its per-mutation red evidence are in the pull request.

- `OutlookQueueHandoffTests` (new, `.serialized`, `.processGlobalState`) — real `AccountManager`
  drain, real `ExchangeProvider`, `StatefulExchangeActionServer` with `churnsIdOnMove: true`, and
  NO destination `Folder` row so the post-drain sync (a repair strictly downstream of the defect)
  cannot mask anything:
  - **T1** `markReadQueuedBehindAMoveLandsAtTheProvenId` — a follower does not reach the wire while
    its predecessor's move is unresolved, and then lands at the id the move proved.
  - **T2** `twoQueuedMovesOfOneMessageSerializeAndTheLatestWins` — two moves of one message never
    overlap in the server's `/move` route, and the latest destination wins with no duplicate.
  - **T3** `undoDuringTheInFlightWindowRestoresTheMessage` — an undo issued inside the in-flight
    window restores the message on the server.
  - **T4** `reDeleteAfterAnUndoIsTheGestureThatWins` — shape 2 end to end; the re-delete built from
    the row after an undo lands, because the row carries the proven address.
  - **T5** `aLaneHaltDoesNotRevertTheHandoff` — a lane that halts mid-drain resumes at the proven
    addresses, not at its snapshot's.
- `AccountManagerQueueDrainTests.accountScopedIdAccountIdsAdmitsExactlyGmailOutlookAndTheDemoAccount`
  — exact-set oracle over `account` rows for every provider plus one row whose `provider` column is
  set by raw SQL to an undecodable string. Replaces the negative-sign version this record supersedes.
- `PendingQueueLaneTests.outlookSameIdInTwoFoldersSharesOneLane` — the pure `buildLanes` case.
- `QueueCoreInvariantTests.accountScopedRekeyFollowsTheRowOutOfTheDestinationFolder`,
  `.imapRekeyStillDeclinesWhenTheRowLeftTheDestination`,
  `.queuedFollowerIsReaddressedAndBystandersAreNot` — the `finishMove` unit trio, including the
  bystander half (re-addressing an operation naming a different message would be a wrong-message
  mutation).
- `ProviderIdQueueFuzzTests.stableIdQueueLaneFuzz` — now alternates `.gmail` and `.outlook` per
  round (Testing Rule 11). The Outlook rounds run a real `ExchangeProvider` against a churning
  server with seeded fault modes and assert: no `/move` overlap, latest destination wins, exactly
  one copy per RFC identity, durable convergence, disjoint bystanders progress exactly once, and a
  permanent fault retains exactly the halted-lane state.
- `StatefulExchangeActionServerTests` — self-checks for the four fixture seams this work added
  (`holdNextMove`, the `/move` overlap counter *and its positive control*, `failNextPatch`,
  `failAllMutations`). A seam proved only through a full drain is indistinguishable from a seam that
  never fires.

Unchanged and still green, as the two-sided non-vacuity legs:
`FinishTheMoveLocallyGraphTests.twoGesturesWorkWhenGraphIdsDoNotChurn`,
`PendingQueueLaneTests.imapSameUidInTwoFoldersStaysInSeparateLanes`,
`QueueCoreInvariantTests.laneHaltInOneFolderDoesNotStarveTheSameUidInAnother`, and the fuzzer's
Gmail rounds (where `addressChangesOnMove` is false, so the handoff is a no-op by construction).

## What this record does NOT contain

**No `rowid` ordering change, no `inheritedRowid` column, no migration.** The design considered
making the drain order by durable insertion order rather than by `createdAt`, so that a backward
clock step or a 404 batch split could not reorder the queue. The owner routed that to a separate
follow-up: the drain keeps `createdAt` order, the 404 split keeps copying `createdAt` onto its
children, and `messageNotFoundBatchSplitPreservesCreatedAt` is unchanged. If a future reader finds
`inheritedRowid` referenced in a plan or review artifact, it belongs to that other piece of work and
not to this one.

**Nothing is deleted from the `DeferredMoveSuccessor` family.** It remains the IMAP-only mechanism
for an undo issued while a `COPYUID` is still outstanding; the Graph path reaches an ordinary queued
inverse instead, which is what the re-addressing then repairs.
