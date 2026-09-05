# IOS-QUEUE-008

> **Post-freeze amendment to a BASE-register record.** Added 2026-09-04 through the amendment
> surface in `Scripts/compact_known_issues.rb`. The base record's own bytes are hash-pinned and are
> **not** edited by this file: `Companion/Process/Current/KnownIssues/ios-queue-008.md` is unchanged,
> nothing in it is deleted or rewritten, and its chronology remains the audit record. This file only
> **adds** the current disposition of the row's closed-decision classification.

- Register classification: `resolved` — fixed **for Gmail and the demo account** by keying drain
  lanes on address-space PROVENANCE rather than on one fixed key shape. The folder-qualified lane
  key `accountId:folderPath:messageId` from the `IOS-QUEUE-001` fix is **UNCHANGED for every other
  account and must NOT be reverted** — see `ios-queue-001.md`; reverting it re-opens a never-drop
  violation with a bystander.
- ⚠️ **Outlook/Graph is deliberately NOT serialized, and this row does NOT cover it.** An earlier
  wording of this amendment said "stable-id providers (Gmail/Outlook)"; that was narrowed
  2026-09-04 before any of it shipped. Rationale below under "why Outlook is excluded". Tracking:
  follow-up issue (number pending).
- Amends: `Companion/Process/Current/KnownIssues/ios-queue-008.md`, the whole "Status" and "Full
  detail" sections — specifically the 2026-08-05 closed-decision disposition and its "the wrong end
  state is visible and fixed by one ordinary gesture" reasoning, which this amendment shows is false
  for the undo-inverse-plus-redelete shape.

## Status

✅ **FIXED for Gmail and the demo account (2026-09-04, `5e02dd1805042176571995dc22b9ea84e5541717`,
narrowed the same day — see "why Outlook is excluded" below).**
⚠️ This line named `42f4d4558` until 2026-09-04. That object is **not in `main`'s ancestry** — it was
the pre-rebase hash of the same patch, still reachable from the pre-merge branch, so it resolves
locally and reads as valid while pointing at a commit no released build contains. Cite the merged
hash; the pre-rebase one is recorded here only so a future reader who finds it in an older artifact
can identify it. The IMAP arm is untouched and
stays governed by `ios-queue-001.md`'s invariant. The base record's registrable-and-recoverable
verdict, its severity-note closure, and its "fix the key's provenance, not its shape" prescription
all stand exactly as written; this amendment records that the prescribed fix was carried out and
names the shape of defect that motivated it.

## Subsystem and search terms

Action queue; undo inverse; re-delete; deleted email reappears; Gmail; `AccountManager.buildLanes`;
`AccountManager.buildLanes(_:immutableIdAccountIds:)`; `immutableIdAccountIds`; `AccountManager.immutableIdAccountIds(_:)`; lane key provenance; immutable-id vs folder-independent; Outlook NOT serialized; `IOS-GRAPH-002`; (superseded label `folderLocalAccountIds`);
`drainPendingQueue`; `optimisticMoveToFolder` exact-opposite predicate; `undoMove`; annihilation;
`recentlyCompleted`; connected components; concurrent lanes; provider-stable ids; v1.7.0; v1.7.16;
`635cb78b1`; `PendingQueueLaneTests`; `AccountManagerQueueDrainTests`; `setMoveHook`; MIS-IOS-008

## 2026-09-04 — observed defect, from the owner's device log

Delete (tap) at 16:21:19 → undo at 16:21:21 → delete again at 16:21:22, on a Gmail account.
Thirty-one minutes later a full sync inserted the message back into the inbox
(`fullSync upsert[Inbox]: ins=1`), re-enqueuing the same message id for AI processing a second time
and moving the inbox count from 39 to 40; the owner deleted it a third time. Gmail `history.list` for
BOTH Gmail accounts on the device reported zero label adds/removes across the whole 16:22→16:53 gap,
so no other client (Thunderbird was open at the time) touched the message: the INBOX label was
re-added during the 16:21–16:22 churn, by TabMail's own undo inverse racing its own re-delete.

## 2026-09-04 — mechanism: `IOS-QUEUE-008`'s lane split, in a shape the base record never named

The first delete drained within 2 seconds, so `undoMove` found no related op left to annihilate and
queued a real inverse operation: `folderPath = TRASH, destinationPath = INBOX`. The re-delete one
second later queued `folderPath = INBOX, destinationPath = TRASH`. Both operations were `queued`
when one drain pass fetched the queue. `buildLanes` keyed on `accountId:folderPath:messageId`, and
Gmail's id is folder-independent, so the two ops on one message landed in different connected
components — different lanes — and `drainPendingQueue` ran them concurrently, one Task per lane.
The inverse completed last: the server ended up with the message back in INBOX, the local row ended
up in TRASH, and both operations retired as provider successes with no error and no retry. The
sync-side `recentlyCompleted` guard, a 30-second TTL, had long expired by the time full sync re-listed
the inbox and imported the wrong state as if it were fresh.

## 2026-09-04 — why annihilation did not fold the inverse, so two ops coexisted at all

`optimisticMoveToFolder`'s exact-opposite predicate requires the row to sit at the PREDECESSOR's
SOURCE address (`message.id == MessageIdentity.headerId(folderPath: predecessor.folderPath, …)`).
On an immutable-id account, `undoMove` restores the row to its ORIGINAL id
(`…:INBOX:…`) — which is the inverse operation's DESTINATION, not its source — so the predicate can
never match an undo inverse on Gmail or Graph. This was deliberately NOT changed as part of this
fix: once lanes correctly serialize same-message ops, missing the annihilation costs one extra wire
round trip, never a wrong end state. Widening the predicate to also match on the destination address
was considered and rejected as unnecessary once the lane-key fix lands.

## 2026-09-04 — why the base record's closed-decision disposition was wrong for this shape

`IOS-QUEUE-008` was closed as a decision on the ground that the wrong end state is "fixed by one
ordinary gesture". In this shape the corrective gesture IS the same delete gesture that produced the
race in the first place, so performing it re-enters the same lane split and can reproduce the same
race — the owner performed it three times on one message before it stuck. This also inverts the
project's never-drop ordering clause, "the user's next action always takes priority": here the
NEWEST intention (the second delete) was overwritten by an OLDER one (the first delete's undo
inverse), racing on the wire after the newer gesture had already been issued. It is not a two-places
residual of the kind the base record's Exchange/Graph analysis discusses — the message ends up back
in INBOX only, not simultaneously in two folders — but the corrective-gesture argument the record
relied on to keep the row `closed-decision` does not hold for it.

## 2026-09-04 — introduction and shipping range

Candidate-introduced by `635cb78b1` (2026-08-04, "Key drain lanes by folder and finish moves on
every retire path" — the `IOS-QUEUE-001` fix); first shipped in v1.7.0; present through v1.7.16.
This is not a recent regression: nothing landed since 2026-08-20 touched lane keying or the undo
inverse; the defect has been live and reachable for the entire v1.7.x line.

## 2026-09-04 — the fix and its tests

Per the base record's own prescription — fix the lane key's PROVENANCE, not its shape.
`AccountManager.buildLanes(_:immutableIdAccountIds:)` takes an account-qualified key
(`accountId:messageId`) for accounts NAMED in the set, and the folder-qualified key
(`accountId:folderPath:messageId`) for everything else — which keeps the `IOS-QUEUE-001` protection
unchanged for IMAP and iCloud. The set is computed by
`AccountManager.immutableIdAccountIds(_ db: Database)`, an **id-only** query over the raw `provider`
column (`provider == AccountProvider.gmail.rawValue || id == DemoSeed.demoAccountId`).

Two properties of that shape are load-bearing and were both chosen deliberately:

- **The conservative behaviour is the DEFAULT, not an opt-in.** An account is account-qualified only
  by being named; absence — including an unrecognised `provider` string from persistent corruption
  or from a newer build — yields the base's folder-qualified key. There is no "unknown"
  classification, quarantine state or new column, because there is nothing to classify.
- **It never decodes whole `Account` rows.** `AccountProvider` is a closed `String, Codable` enum
  while `account.provider` is unconstrained text, so an `Account.fetchAll(db)` here would let ONE
  corrupt bystander row throw `DecodingError.dataCorrupted` before any op is claimed, take the
  drain's `catch`/`break`, and wedge EVERY account's queue forever behind a debug-gated log — the
  wedge corollary one level up from `IOS-QUEUE-001`. Precedent for the id-only form:
  `AccountManagerUidValidityReset.armImapUidValidityResetForEpochRebuildIfNeeded`.

## 2026-09-04 — why Outlook is excluded, even though Graph ids are folder-independent

⚠️ **Folder-independent is NOT the same property as immutable, and conflating them is what the
first cut of this fix did.** Microsoft Graph REALLOCATES a message's default id on every move, and
this tree sends no `Prefer: IdType="ImmutableId"` (`IOS-GRAPH-002`).

Account-qualifying Graph would put a move `A: Inbox→Archive` and any op on `A` that was queued
BEFORE that move landed — offline, or simply in the same drain snapshot — into ONE lane. That
GUARANTEES the follower runs after the move, against the id the move just invalidated:
`MessageHeaderRekey.finishMove` re-keys the `MessageHeader` and nothing rewrites a later
`PendingOperation.messageIds`, so the follower reaches the wire with a dead id, Graph answers 404,
and `executeSingleOp`'s single-message conflict arm DELETES it. The user's latest intention is gone.

Folder-qualified, those two ops sit in different lanes and merely RACE — sometimes wrong, sometimes
right, and recoverable. So serializing Outlook would convert an inherited race into a
**deterministic intention loss**, which is strictly worse than the defect this row is about. The
proper fix — carry a move's A→B handoff into later same-lane members before their wire call — is a
queue-semantics change deliberately NOT attempted here; it is routed to the owner as its own
follow-up issue (number pending). Until that exists, Graph stays folder-qualified.

🚨 **Do not "complete" this fix by adding `.outlook` to `immutableIdAccountIds`.** The negative case
is pinned by `AccountManagerQueueDrainTests.immutableIdAccountIdsAdmitsOnlyGmailAndTheDemoAccount()`,
an exact-set oracle over rows for every provider — the only test shape that can fail on an account a
drain fixture never seeds.

Tests: `PendingQueueLaneTests.stableIdUndoInverseAndRedeleteShareOneLane()` pins the exact race
described above — an undo inverse and a re-delete on one immutable-id message must land in the same
lane. `PendingQueueLaneTests.imapSameUidInTwoFoldersStaysInSeparateLanes()` is the `IOS-QUEUE-001`
fence, re-asserted so the fix cannot regress it. `PendingQueueLaneTests.stableIdOpsInTwoFoldersMergeOnlyForTheStableIdAccount()`
checks the split applies per-account, not globally. `AccountManagerQueueDrainTests.drainPendingQueueRealStableIdSameMessageOpsNeverOverlapAndRunInIssueOrder()`
is the real-drain property test: a `setMoveHook` overlap oracle that fails if two ops on the same
immutable-id message ever execute concurrently. This test is RED against the pre-fix code and GREEN
after.

Added 2026-09-04 with the narrowing, all RED against a named mutation and GREEN after:
`AccountManagerQueueDrainTests.immutableIdAccountIdsAdmitsOnlyGmailAndTheDemoAccount()` is the
exact-set oracle over `account` rows for EVERY provider plus one row whose `provider` column is set
by raw SQL to an undecodable string — the only shape that can fail on an account a drain fixture
never seeds, which is exactly how "`.outlook` was quietly admitted" would otherwise escape.
`drainPendingQueueRealStableIdSameMessageOpsNeverOverlapAndRunInIssueOrder` is parameterized over
Gmail AND the demo account (whose row is stored `.imap` and admitted BY ID).
`QueueCoreInvariantTests.laneHaltInOneFolderDoesNotStarveTheSameUidInAnother` is parameterized over
`.imap` AND `.icloud`, both of which must stay folder-qualified.
`ProviderIdQueueFuzzTests.stableIdQueueLaneFuzz` wires the new serialization invariant into the
queue fuzzer per root testing rule 11: seeded scheduling perturbation, an injected retryable fault,
and a per-round wire oracle for max-in-flight-per-`(account, id)` == 1, `createdAt` order,
latest-destination-wins, disjoint progress and durable convergence. Its acceptance bar is that
reverting the account-qualified arm makes the fuzzer rediscover the race with no bespoke hook.

⚠️ **There is deliberately NO Outlook real-drain test asserting serialization.** Writing one would
be a test that BLESSES the bug described in the previous section.

## 2026-09-04 — instrumentation gap, follow-up not done here

The drain's `queueLog` is `print`-only, and the `[MoveTrace] deltaSync` branch lines are bare
`print`, both discarded on a device (production) build — so no device log could show directly which
lane ran first; the mechanism above was reconstructed from source and from the Gmail `history.list`
absence-of-evidence, not read off the device log. Gating these behind
`DebugModeManager.isLoggingEnabled()` so a future device-side race is directly observable is an
owner-decided follow-up, not done as part of this fix.

**DONE in the follow-up (2026-09-04).** The drain's `queueLog`, the seven `[MoveTrace] deltaSync`
branch lines and the full-sync inserted-id line now all route through
`BackgroundSyncLogger.logQueue`, which is debug-gated by `DebugModeManager.isLoggingEnabled()`,
escapes its fully rendered line, and appends to the **new `AppLogChannel.queue`** (tag `QUEUE`) —
so the next occurrence of this race is readable from the exported app log on a device or TestFlight
build, for a user with debug logging unlocked. Note the gate is a RUNTIME unlock, not a build
configuration: these lines are live on shipping builds for an allowed user, which is the point.

**Later the same day (2026-09-04): six, not seven.** One of the seven `[MoveTrace] deltaSync`
lines — `SKIPPING insert for id=… — already exists (post-snapshot)` — was removed together with the
post-snapshot re-read guard it witnessed, because the guard was unreachable: it re-read, inside the
same `DatabasePool.write` transaction, the key the orphan check had just read, and the only
`messageHeader` write between the two reads is the Sent-dedup DELETE. The Exchange arm's `print`
twin went with it. Six `[MoveTrace] deltaSync` sites remain on the `.queue` channel. Detail and the
transaction-boundary facts: `Companion/Process/Current/KnownIssues/Amendments/ios-label-004.md`.

## 2026-09-04 — round 5 (PR #113): the full-sync upsert line now tells the truth (R4-RS-1)

Two lies in the `[MoveTrace] fullSync upsert[<folder>] — …` line the follow-up above added, both
removed in `SyncEngine.runSyncMessages` (`SyncEngineFullSync.swift`):

1. **Reclaimed rows were reported as inserted.** The orphan-reclaim arm UPDATES an existing row in
   place — a local row an optimistic move re-homed, whose server folder disagreed; for this issue
   the MORE interesting event — and appended it to `newHeaders`, which the line rendered under
   `inserted N header(s):`. The line now carries TWO segments, always both, each capped by
   `SyncConfig.upsertInsertedIdLogCap`: `inserted N header(s): … | reclaimed M header(s): …`.
   `insertedIds` grows only next to a `header.insert(db)` (the plain insert, the DraftDedup
   replacement and the pre-sync inbox reclaim — each a NEW row under the reported id);
   `reclaimedIds` only at the orphan-reclaim arm's in-place update. `newHeaders` is unchanged for
   its FTS / body-queue consumers and is no longer the source of the diagnostic. An update-only
   pass renders `inserted 0 header(s):  | reclaimed 0 header(s): ` (both trailing spaces kept).
   The renderer is the same pure `SyncEngine.upsertInsertedIdSummary`, now with a `verb:`
   parameter defaulting to `"inserted"`.
2. **The line was written before COMMIT.** It was emitted inside the `dbPool.write` closure, and
   `AppLogStore.append` enqueues file I/O that no ROLLBACK can retract, so a commit failure (I/O
   error, full disk) left a line naming rows that never became durable. The closure now RETURNS the
   rendered line (`upsertLine: String?`, nil when the pass emits nothing — the emission condition
   is unchanged) as one more field of its result tuple, and `BackgroundSyncLogger.logQueue` runs
   only after the write has returned; a thrown write never reaches it. `BootProfiler.mark` stays
   inside the closure as before.

Pinned in `SyncEngineRunSyncTests` (`SyncEngineFullSyncUpsertDiagnosticTests`; real
`runSyncMessages`, debug gate unlocked, oracle `AppLogStore.read(channel: .queue)`): an orphan
reclaim under a `.date` stale window (the Gmail/Exchange arm — IMAP refuses the reclaim, see
`RFC822IdentityMergeGuardTests`) is reported under `reclaimed` and not `inserted`, with the row back
in the synced folder; a mixed pass (one insert + one reclaim) pins the exact two-segment line; and a
GRDB `TransactionObserver` whose `databaseWillCommit()` throws once the sync's transaction has
written `messageHeader` proves a rolled-back pass leaves NO line and NO row. All three were red on
`2f0294c8c`, and each condition has a mutation proof (emit inside the transaction again → the
rollback test goes red; append reclaimed ids to `insertedIds` → the reclaim tests go red). The pure
suite `SyncEngineUpsertInsertedIdSummaryTests` gained the `verb: "reclaimed"` case; the only
pre-existing oracle the new shape changed is the update-only line above.
