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

Delete (tap) at t+0 s → undo at t+2 s → delete again at t+3 s, on a Gmail account. About half an
hour later a full sync inserted the message back into the inbox (`fullSync upsert[Inbox]: ins=1`),
re-enqueuing the same message id for AI processing a second time; the owner deleted it a third
time. Gmail `history.list` for every Gmail account on the device reported zero label adds/removes
across the whole gap, so no other client touched the message (another client was signed in at the
time): the INBOX label was re-added during the churn around those three gestures, by TabMail's own
undo inverse racing its own re-delete.

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

## 2026-09-05 — round 6b (PR #113): every remaining in-write diagnostic line is DELETED

⚠️ Line-format rows recorded in the 2026-09-04 sections above — the six `[MoveTrace] deltaSync`
branch lines and the five in-write `[Queue]` lines — are **removed 2026-09-05**. Their wordings are
kept above as history; they no longer describe the tree.

Round 5 fixed the full-sync upsert line's transaction boundary at ONE site. The round-5 correctness
and robustness angles both then named the SIBLINGS — the Gmail delta arm's six
`[MoveTrace] deltaSync` lines, the drain's `[Queue] Op … cancelled by undo, deleted`, the four
`[Queue] Crash recovery: …` lines inside `reconcilePendingOperations`' `retryWrite`, and
`undoMove`'s `phase=queuedInverse` — and both offered the same two resolutions: delete the
pre-commit emissions, or carry them out of the write and emit after commit. **The owner chose
DELETION (2026-09-05 00:30): "this is a debug instrument; on rare occasions it's okay to miss that
line."**

The mechanism, stated once: `BackgroundSyncLogger.logQueue`/`.logInbox` → `AppLogStore.append`
enqueues its file write on an independent serial `ioQueue`. No SQLite `ROLLBACK` retracts it. A line
emitted from inside a `dbPool.write` closure therefore SURVIVES a transaction that later fails (a
commit-time I/O error, a full disk, a `databaseWillCommit()` refusal), and the exported log then
asserts an insert, a removal, a skip, a deletion, a crash-recovery cleanup or a queued inverse that
never became durable. **A debug instrument may miss a line; it must not lie.** Deletion crosses none
of the three red lines — no unbounded loop or retry, no secret retained or exposed, no older
intention beating a newer one — because nothing here mutates state.

What was done, exactly:

- **Deleted:** the six `[MoveTrace] deltaSync` calls in `SyncEngine.gmailDeltaSync`'s changed-message
  write, together with the file-private `deltaMoveTraceLog(_:)` façade and its doc comment; and the
  five in-write `queueLog` calls (the drain's cancelled-by-undo line and the four crash-recovery
  lines). The branch structure is unchanged — the three skip arms that held nothing but a log line
  keep their `else if` and carry a comment instead, because the `recentlyCompleted` arm in
  particular is what stops a just-completed message from falling through to the insert arm. Two
  counters that became write-only (`cancelledCount`, `reAdmittedPushes`) are now `_ =`.
- **Moved, not deleted:** `undoMove`'s `phase=queuedInverse` line pre-dates this branch. It is now
  emitted AFTER the write returns, from two new optional fields on the existing `UndoMoveWriteResult`
  (`inverseOpId`, `inverseCreatedAt`) set immediately after `try inverseOp.insert(db)`, guarded on
  both being non-nil — which is the same condition as "the inverse row committed". The rendered text,
  its fields and their order are byte-identical, so `UndoProviderIdentitySafetyTests` A3.4 and its
  locked-gate twin pass unchanged.
- **Retained shape:** the round-5 `[MoveTrace] fullSync upsert[<folder>] — …` line
  (`SyncEngineFullSync.swift`) is the reference for how a diagnostic that must survive is written —
  render inside the write, RETURN it, emit after the write returns.
- **Attribution after the deletion:** the delta arm now writes NO per-message line. A message that
  reappears is attributed to the delta arm **by elimination** — the full-sync arm renders its
  `fullSync upsert[<folder>] — inserted … | reclaimed …` line when it writes — a heuristic bounded by
  the 20-id display cap (`SyncEngine.upsertInsertedIdSummary` renders at most 20 ids and elides the
  rest as `(+N more)`, pinned by `fullSyncUpsertLogsCapPlusOneElidesLastIdButDBHoldsAll`) and by log
  availability.
- **Tests:** `GmailDeltaMoveTraceLogTests` keeps all six of its tests and every durable-DB and
  history-cursor assertion; only the expectations that required a `[MoveTrace] deltaSync` line, and
  the now-unused `moveTraceLines` extractor, were removed. No test was added: red-first does not
  apply to a deletion, and the owner's standing rule is no tests for tests' sake.

### The standing fence

Run from the iOS checkout root. It reports every `queueLog` / `deltaMoveTraceLog` /
`BackgroundSyncLogger.logQueue|logInbox` call that is lexically inside an open database write, and
must print exactly **TOTAL 3** — `undoMove`'s `phase=relatedOps`, `phase=deferBehindInFlight` and
`phase=annihilateQueued`, all of which pre-date this branch and are untouched by it. It printed 15
on `ef81ee3e5`.

```
python3 - <<'PY'
import re,glob
emit=re.compile(r'BackgroundSyncLogger\.log(Queue|Inbox)\(|queueLog\(|deltaMoveTraceLog\(')
opener=re.compile(r'(\.write\s*\{|retryWrite\(|\.write\s*\(|\.inTransaction\s*\{|\.inSavepoint\s*\{|\.barrierWriteWithoutTransaction\s*\{)')
hits=[]
for f in sorted(glob.glob('TabMail/**/*.swift',recursive=True)):
    depth=0; stack=[]
    for i,line in enumerate(open(f).read().split('\n'),1):
        code=re.sub(r'//.*','',line); code=re.sub(r'"(\\.|[^"\\])*"','""',code)
        if opener.search(code): stack.append((i,depth))
        if emit.search(line) and stack: hits.append((f,i,stack[-1][0],line.strip()[:100]))
        depth+=code.count('{')-code.count('}')
        while stack and depth<=stack[-1][1]: stack.pop()
for h in hits: print(f"{h[0]}:{h[1]} (write opened at {h[2]}): {h[3]}")
print("TOTAL",len(hits))
PY
```

⚠️ Those three remaining lines are NOT blessed by this row — they are simply out of this change's
scope. Whoever next touches `undoMove`'s write should carry them out on the same
`UndoMoveWriteResult` seam or delete them, not add a fourth.

## 2026-09-05 — the undo rollback boundary now has a witness

`UndoProviderIdentitySafetyTests.queuedInverseDiagnosticIsAbsentWhenTheUndoWriteRollsBack` pins the
boundary the "Moved, not deleted" bullet above created: a GRDB `TransactionObserver` refuses the
COMMIT of the transaction that inserted the inverse `PendingOperation`, and the test asserts that
`undoMove` restores nothing, that no inverse row is durable, that the header still sits at its
pre-undo address, and that `AppLogStore.read(channel: .inbox)` carries NO `phase=queuedInverse`
line. It is RED when that emission is moved back next to `try inverseOp.insert(db)` — the
pre-`7b848ab5d` shape, same fields — which until 2026-09-05 nothing in the tree could tell apart
from the committed one.

## 2026-09-05 — round 8 (PR #113): the exported drain line now witnesses a HALTED lane

- **`outcome=haltLane` has an oracle.** `AccountManagerQueueDrainTests.drainLaneInstrumentationIsReadableFromTheExportedLog()`
  gained a third phase, between its gate-OPEN and gate-CLOSED halves, that arms the same retryable
  provider fault the stable-id fuzzer's `.transientThenClears` mode uses
  (`setMoveThrowsOnId(id, error: ProviderError.notConnected)`) on the predecessor of the
  `IOS-QUEUE-008` pair, and asserts the exact three-entry lane/order artifact — the `lane0(2)`
  composition line, `executing` and `executed … outcome=haltLane` for pos 1/2, and **nothing for
  pos 2/2** — plus the durable state read independently of the log: both rows still `queued`,
  `retryCount` 1 and 0, `everAttempted` true on both, exactly one `move` attempt in the mock's
  attempt ledger and nothing in its success ledger; clearing the fault then drains the same lane to
  completion with `outcome=proceed` twice and the inverse on the wire before the re-delete. Until
  this phase existed the whole tree contained only two `outcome=proceed` expectations and no
  `outcome=haltLane` expectation at all, so a **sink-only** mutation — replacing the interpolation
  with the literal `outcome=proceed`, production behaviour untouched — left every test green while
  the exported log would describe a halted lane as one that kept draining. The extended phase is RED
  on exactly that mutation (one issue, on the `outcome=haltLane` equality) and green on the restored
  tree. Keeping the field rather than deleting it is deliberate: it is the instrument's only positive
  statement that a lane stopped, which is the question `IOS-QUEUE-008` could not answer.
