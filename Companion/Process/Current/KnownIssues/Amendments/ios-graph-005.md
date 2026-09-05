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
contain"); `moveOverlapObserved` / `peakConcurrentMoves` (built, then REMOVED — see "the overlap
oracle this fixture cannot have"); `URLProtocol` `startLoading` serialization.

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
   `?? capturedOp` fallback: a fallback would resurrect a withdrawn gesture from memory and send it
   to the wire — a fail-DANGEROUS default.

   ⚠️ **CORRECTED 2026-09-05 (COR-1), in two places at once.** This item used to say the re-read
   "skips it if the row is gone", full stop, and justified the missing fallback with "the only
   writers that delete a claimed row are cancel and annihilation, both of which are the user
   withdrawing the intention". Both halves were wrong.
   - **The reason was wrong.** The claim commits `status = inFlight` AND `everAttempted = true` in
     one transaction, and both the cancel fold and `undoMove`'s annihilation filter require `queued`
     and `!everAttempted` — so neither can delete a row that has been claimed. The writers that CAN
     are the local wipes and resets, which never join a running drain:
     `SettingsView.localIndexWipeTxn` (`DELETE FROM pendingOperation WHERE type != 'saveDraft'`),
     `AppDataWiper`, `AccountManagerSetup`'s per-account delete, `DemoSeed`'s demo reset, and the
     UIDVALIDITY-reset sweep. The conclusion survives — those are still the user's NEWER gesture
     winning over the one the lane captured — but the premise a future reader would reason from did
     not.
   - **The behaviour was wrong.** `liveOperation` was `try? await dbPool.read`, so a FAILED read
     collapsed into the same `nil` an absent row produces and took the skip arm: the operation
     stayed `inFlight` forever (every later claim loop refuses `inFlight`), its lane kept draining so
     a later member overtook it, and `reconcilePendingOperations` deleted it at the next launch if it
     was a `.move`. It is now `async throws`; `nil` means exactly one thing — the row no longer
     exists — and a read that fails requeues that operation and the rest of its lane with
     `markQueued`, halts the lane, and charges no retry. "We could not determine the answer" is
     retryable, never authoritative. Witness:
     `AccountManagerQueueDrainTests.drainPendingQueueRealFailedPostClaimReReadKeepsTheLaneRetryable`
     (red-first) and `.drainPendingQueueRealRowDeletedByALocalWipeMidDrainIsSkipped`, which drives
     the surviving `nil` arm through the real `SettingsView.localIndexWipeTxn`.

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

### ⚠️ NARROWED 2026-09-05 to PROCESS DEATH ONLY (owner decision B, `TabMail/tabmail-ios#120`)

The acceptance above was written as though a failed retirement transaction implied a dead process.
It does not. The round-2 reviewers reproduced, independently and on GRDB 7.11.1, a LIVE process in
which all three `retryWrite` attempts fail: GRDB suspends writes when the app is backgrounded
mid-drain while reads keep working (ADR-IOS-041), and a full disk or an I/O error at COMMIT does the
same. On that path the provider's returned `ExecutedOperation` — carrying `provenDestinations` —
was discarded and the operation fell through to `.proceed`, so the follower serialized behind it in
the same account-scoped lane ran next naming the id Graph had just invalidated, got a structural
`404`, and was DELETED by the single-message conflict arm. `retirePartiallyCompletedOp`'s catch was
the twin: it requeued the ORIGINAL bundle including the already-moved source id, so later passes
re-ran the move on the wire, split and dropped the dead member, and deleted its stale-address
follower. In both shapes the user's NEWER intention was lost with no crash at all.

The owner's decision (option B, 2026-09-05) keeps the process-death window ACCEPTED exactly as
stated above, and closes the live-process half by RETENTION AND REPLAY:

- `AccountManager.pendingRetirements` holds the provider's own returned result, keyed by operation
  id, for exactly the operations whose retirement write failed. Both retirement callers store into
  it instead of discarding (full path) or requeueing the whole bundle (partial path), and both
  leave the row `inFlight` with ALL of its members and no retry charged, so the claim loop refuses
  it and the move is never sent to the wire twice.
- Both callers' transaction bodies are factored into `AccountManager.commitFullRetirement` and
  `AccountManager.commitPartialRetirement`, so the replay runs the SAME write rather than a second
  copy that can drift. The transaction content is unchanged.
- `AccountManager.replayRetainedRetirements` runs at the top of `drainPendingQueue`, after the
  `isDraining` guard and BEFORE the `NetworkMonitor` check — the recovery is entirely local and must
  not wait for connectivity. On success it runs the post-commit steps the original site would have
  run; on a row the local wipes/resets removed it drops the entry, for the same reason
  `liveOperation`'s nil arm skips; on a still-failing commit it keeps the entry and stops the drain,
  because a database that cannot commit cannot retire anything else safely either.
- **The invariant is `no claim pass starts while this process holds an unresolved proven
  retirement`, and `drainPendingQueue` therefore also STOPS AT THE PASS BOUNDARY on
  `if !pendingRetirements.isEmpty { break }`** — placed immediately after the lane tasks are joined
  and before `if !ctx.executedAny { break }` — because the top-of-drain replay runs only ONCE, while
  the pass loop can start a second claim pass on any other progress in the same pass (a successful
  bystander on the full arm; `retirePartiallyCompletedOp`, which sets `executedAny` unconditionally
  even after its retention catch, on the partial one), and that pass claims the halted lane's
  follower ALONE — the claim loop refuses the retained predecessor because it is `inFlight` — at the
  id the uncommitted result has already invalidated, where the `404` and the single-message conflict
  arm delete the user's newest gesture with no crash at all. The next drain owns the recovery: its
  replay runs before anything is claimed, so the proof commits (re-addressing the follower in the
  same transaction) or the drain refuses to start. Fences:
  `OutlookQueueHandoffTests.aBystandersProgressDoesNotReleaseAHeldRetirementsFollower` (the full arm,
  with a bystander) and `.aHeldNarrowingStopsTheDrainWithoutABystander` (the partial arm, which needs
  none), both RED on the pre-gate code and on a named inversion of the gate; the second uses
  `StatefulExchangeActionServer.failMoveOnce(providerMessageId:)`, the one-shot id-scoped `/move`
  fault added so a batch's LATER member can fail while its earlier member is proved.

No identity lookup, no receipt table, no schema change, and no wire replay of the move: RFC identity
remains banned as a mutation authority (ADR-IOS-068 D4, `IOS-IMAP-002`). The map is bounded by the
number of claimed moves whose retirement failed, and entries leave on replay success, when the row
is gone, or with the process — which is the accepted window above, now stated at its true width.

Fences: `OutlookQueueHandoffTests.aRetirementThatCannotCommitRetainsTheProofAndReplaysIt` (real
drain against the churning Graph server, three refused commits then recovery),
`QueueCoreInvariantTests.narrowedRetirementThatCannotCommitKeepsTheWholeBundleQueued` (rewritten
from the old mechanism's whole-bundle-requeue expectation to the invariant) and its account-scoped
sibling `.narrowedRetirementThatCannotCommitIsReplayedOnAnAccountScopedProvider`.

### ⚠️ CORRECTED 2026-09-05 (round 4, A1) — the crash-residue sweep ran where a live drain could already own the rows

The retention-and-replay design above is correct and unchanged. What was wrong is a site it depends
on: the sweep that reconciles the PREVIOUS process's residue sat at the top of
`AccountManager.reconcilePendingOperations`, and that function is **not** the launch-only entry
point its own comment claimed.

**Invariant.** Crash residue from a PREVIOUS process is reconciled at a point where nothing in this
process can have claimed anything — the database-startup boundary — and nothing this process owns (a
retained retirement, a claimed lane, a halted suffix) is ever swept.

**Mechanism of the defect.** `RootView` calls `reconcilePendingOperations` only after EVERY account
has finished connecting, while a connected account's gestures and the background entry points have
already been draining. The sweep blindly resets every `inFlight` row and DELETES every
`everAttempted` `.move`. So: account A's Outlook move succeeds on Graph, its retirement write is
refused, the proof is retained and the row stays `inFlight` + `everAttempted`; account B's connect
completes; the sweep DELETES A's row; the drain that follows hits `replayRetainedRetirements`'
row-gone arm, drops the proof as if the user had wiped the row, and the follower is claimed alone at
the id Graph already reallocated — `404`, single-message conflict arm, the user's newest gesture
deleted. Live process, no crash: **outside the accepted process-death window.** On a retained
PARTIAL retirement it costs strictly more — deleting the bundle discards the still-owed, never-executed
members too. The correctness angle reproduced both shapes independently on GRDB 7.11.1 (COR-1).

**The fix is a MOVE, not a new mechanism, and it adds no state.** The sweep body is unchanged and now
lives in `AppDatabase.recoverPreviousSessionResidue(on:)`, called unconditionally from
`AppDatabase.init(pool:runStartupResets:)` after `runMigrations` and before the inbox observer is
wired. No latch, no flag, no `…ForTesting` reset seam: the premise becomes STRUCTURAL rather than
conventional, because the only writer of `pendingOperation.status = inFlight` is the drain's claim,
every drain reaches the database through `AppDatabase.dbPool` → `rawPool` → `shared`, and `shared` is
not published until that initializer returns. It is deliberately NOT inside `StartupMigrations.run`
and NOT gated by `runStartupResets` — those are one-time, flag-gated, production-only data resets,
while this is per-launch recovery with no UserDefaults or FTS side effect, so test fixtures run it
too. `reconcilePendingOperations` keeps its name and both callers and is now exactly
`drainPendingQueue()` + `reconcileOutbox()` + `reconcileCalendarQueue()`.

**Failure semantics at the boundary: fail closed.** A throw PROPAGATES out of `init`, exactly as a
failed migration or the observer-seeding write does; `AppStartup` renders "TabMail couldn't open its
local database" and **does not publish the pool**. A database that cannot take the recovery write
must not go on to release new claims into unreconciled state, so there is no `try?`, no retry ladder
and no swallow-and-log. The previous site swallowed the failure (`try? await retryWrite`) and drained
anyway.

**The NSE cannot reach it.** `TabMailNotificationService` compiles only `TabMailNotificationService/`
+ `Shared/` (`project.yml`) and never `TabMail/Services/AppDatabase.swift`; the whole-tree census of
`AppDatabase(` in production is `TabMailApp.swift` (the real launch) and `PreviewMocks.swift`.

**Fences.** Three new real-drain witnesses in `OutlookQueueHandoffTests`, all driven through the REAL
`reconcilePendingOperations()` — the `RootView` entry — and all RED on the pre-fix code:
`theLaunchReconcilerDoesNotEraseARetirementThisProcessStillOwns` (full retention: the follower
PATCHed at the invalidated id and was deleted),
`theLaunchReconcilerDoesNotEraseAHeldNarrowingsStillOwedMembers` (partial retention: the still-owed
member never moved at all) and
`theLaunchReconcilerArrivingDuringADrainLeavesTheClaimedLaneAlone` (the reconciler arriving while a
move is parked in the wire route: the claimed move row was DELETED and its follower released back to
`queued` under the lane task still holding it). The sweep itself is pinned at its new boundary by the
two tests that used to pin it at the old one, rewritten to enter through `AppDatabase(dbPool:)` with
every assertion kept verbatim:
`AccountManagerQueueDrainTests.databaseStartupRecoveryResetsInFlightDeletesCancelledLeavesQueued`
(renamed from `.reconcilePendingOperationsResetsInFlightDeletesCancelledLeavesQueued`) and
`.launchReconciliationReAdmitsAnOrphanedDraftPush`. Their inverted proof is deleting the `init` call
while keeping the static.

## Tests

All named tests are RED against a named inversion of the fix and GREEN after; the mutation matrix
and its per-mutation red evidence are in the pull request.

- `OutlookQueueHandoffTests` (new, `.serialized`, `.processGlobalState`) — real `AccountManager`
  drain, real `ExchangeProvider`, `StatefulExchangeActionServer` with `churnsIdOnMove: true`, and
  NO destination `Folder` row so the post-drain sync (a repair strictly downstream of the defect)
  cannot mask anything:
  - **T1** `markReadQueuedBehindAMoveLandsAtTheProvenId` — a follower does not reach the wire while
    its predecessor's move is unresolved, and then lands at the id the move proved.
  - **T2** `twoQueuedMovesOfOneMessageSerializeAndTheLatestWins` — two moves of one message run in
    issue order and the latest destination wins, with no duplicate. Its oracle is the OUTCOME; see
    "the overlap oracle this fixture cannot have" below for why there is no wire-level one.
  - **T3** `undoDuringTheInFlightWindowRestoresTheMessage` — an undo issued inside the in-flight
    window restores the message on the server.
  - **T4** `reDeleteAfterAnUndoIsTheGestureThatWins` — shape 2 end to end; the re-delete built from
    the row after an undo lands, because the row carries the proven address.
  - **T5** `aLaneHaltDoesNotRevertTheHandoff` — a lane that halts mid-drain resumes at the proven
    addresses, not at its snapshot's. Its three-PATCH count proves the halt happened; the ADDRESS
    each of those three named, and the refused mark-read's own `isRead` outcome, are asserted
    separately, because a snapshot-restoring requeue produces the same count while sending the
    retry to the dead id.
  - **T6** `aFailedAccountRequeueDoesNotRevertTheHandoff` — the THIRD requeue site, the only one
    driven from another lane: a connectivity failure on a second Graph message marks the account
    failed, and the follower behind a retired move is requeued at the proven address, uncharged for
    a failure that was not its own. The two-lane schedule uses only `holdNextMove` and
    `failNextPatch`, and its barrier is a real happens-after — `failedAccounts.insert` precedes the
    `.haltLane` requeue whose durable write the test waits on.
- `AccountManagerQueueDrainTests.accountScopedIdAccountIdsAdmitsExactlyGmailOutlookAndTheDemoAccount`
  — exact-set oracle over `account` rows for every provider plus one row whose `provider` column is
  set by raw SQL to an undecodable string. Replaces the negative-sign version this record supersedes.
- `PendingQueueLaneTests.outlookSameIdInTwoFoldersSharesOneLane` — the pure `buildLanes` case.
- `QueueCoreInvariantTests.accountScopedRekeyFollowsTheRowOutOfTheDestinationFolder`,
  `.imapRekeyStillDeclinesWhenTheRowLeftTheDestination`,
  `.queuedFollowerIsReaddressedAndBystandersAreNot` — the `finishMove` unit trio, including the
  bystander half (re-addressing an operation naming a different message would be a wrong-message
  mutation). Its two boundaries are pinned separately, because the sweep's `WHERE` has two clauses
  and each is a different C3: `.readdressingIsBoundedByAccountNotOnlyByMessageId` (another
  MAILBOX's operation carrying the same opaque id string) and
  `.imapReaddressingNeverCrossesAFolderBoundary` (a queued operation on `(Trash, UID 77)` while a
  `COPYUID` proves `(INBOX, 77) → 5`). `.narrowedRetirementOnAnAccountScopedProviderCarriesTheAddressIntoTheQueue`
  covers `retirePartiallyCompletedOp` on the arm Graph actually takes,
  `.narrowedRetirementThatCannotCommitKeepsTheWholeBundleQueued` proves that write is all-or-nothing
  under a `TransactionObserver` that refuses the COMMIT, and
  `.accountScopedZeroMatchAfterAMessageDataResetIsClassifiedForMirrorRemoval` separates the
  account-scoped "already gone" arm from the adjacent "ambiguous" arm using the real
  `AccountDetailView.resetMessageDataTxn` as the producer.
- `ProviderIdQueueFuzzTests.stableIdQueueLaneFuzz` — now alternates `.gmail` and `.outlook` per
  round (Testing Rule 11). The Outlook rounds run a real `ExchangeProvider` against a churning
  server with seeded fault modes and assert: the latest destination wins, exactly one copy per RFC
  identity, durable convergence, disjoint bystanders progress exactly once, and a permanent fault
  retains exactly the halted-lane state.
- `StatefulExchangeActionServerTests` — self-checks for the three fixture seams this work added
  (`holdNextMove`, `failNextPatch`, `failAllMutations`). A seam proved only through a full drain is
  indistinguishable from a seam that never fires.

### The overlap oracle this fixture cannot have

A fourth seam was built and then REMOVED, and the removal is the finding worth recording. The
Graph fixture gained a `movesInFlight`/`maxMovesInFlight` counter sampled inside its `/move` route,
so that "two moves of one message never overlapped" could be a positive observation rather than an
inference from a final state a lucky race would share. Testing rule "non-vacuity must be two-sided"
required a positive control: park one move inside the route, drive a second concurrently, and assert
the peak reaches 2.

**The control FAILED.** The peak stayed at `1` across a 3 s window, and the fixture's own record of
what it served while the first move was parked contained exactly one entry — the parked move itself.
A `URLProtocol`-backed transport does not admit a second request into the route while an earlier one
is blocked inside `startLoading()`. So the counter could only ever answer "no overlap", that answer
is the TRANSPORT's and not the QUEUE's, and it would have held identically with the lane key
reverted. The tell was already visible in the mutation matrix before the control was written:
inverting the lane classifier left T2 GREEN.

⚠️ **NARROWED 2026-09-05 — what that mutation run actually says about T2's remaining oracle.** This
paragraph used to end "With the counter removed T2 keeps only its outcome oracle — and that oracle
DOES go red under the same inversion, because two racing lanes let the older gesture land last."
That is **not** what was measured, and the very run cited above contradicts it: T2 was GREEN under
the classifier inversion **while the outcome oracle was already present**, so every assertion T2
still has passed under the inversion. No re-measurement was taken after the counter was removed.
What is established is only the negative half — the deleted counter could not distinguish the two
regimes. Whether the OUTCOME oracle can is UNKNOWN, and the mechanism above gives a concrete reason
to expect it cannot: the same `URLProtocol` transport that refused to admit two `/move`s into the
route concurrently also serializes the two racing lanes' moves, so the older gesture has no window
in which to land last. Treat T2 as an outcome/no-duplicate test, not as a serialization oracle;
the falsifiable serialization oracles are the two named below.

The seam, its control, and all four assertions that consumed it (T2, and two in the fuzzer's Outlook
round) were deleted rather than weakened. The falsifiable Outlook serialization oracles are
`OutlookQueueHandoffTests` T1 — a follower's PATCH, a DIFFERENT request the transport does let
through, must not reach the wire at all while its predecessor's move is unresolved — and
`PendingQueueLaneTests.outlookSameIdInTwoFoldersSharesOneLane`, which asserts on `buildLanes`
directly.

⚠️ **NARROWED 2026-09-05 — those two do not fail for the same reason, and only one of them sees the
classifier at all.** This sentence used to read "Both go red when `.outlook` leaves the
account-scoped set." The `buildLanes` test **cannot**: `buildLanes(_:accountScopedIdAccountIds:)`
takes the set as a PARAMETER and the test INJECTS it (`accountScopedIdAccountIds: ["acc-outlook"]`),
so it never reads `AccountManager.accountScopedIdAccountIds` and stays green with `.outlook` removed
from it. What it pins is the LANE KEY given the classification — it goes red only if the key itself
stops being account-qualified for a set member. The test that sees the classifier is
`AccountManagerQueueDrainTests.accountScopedIdAccountIdsAdmitsExactlyGmailOutlookAndTheDemoAccount`
(its exact-set oracle over real `account` rows), and end to end so does T1, which drives a real
drain. Read the trio as three DIFFERENT mutations — membership, lane key, and end-to-end behaviour —
not as one assertion made three times. The Gmail side keeps its
`setMoveHook` in-flight counter, which works because it samples inside the fake PROVIDER rather than
inside a URL-loading route.

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
