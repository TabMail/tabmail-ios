# IOS-QUEUE-008

> **Post-freeze amendment to a BASE-register record.** Added 2026-09-04 through the amendment
> surface in `Scripts/compact_known_issues.rb`. The base record's own bytes are hash-pinned and are
> **not** edited by this file: `Companion/Process/Current/KnownIssues/ios-queue-008.md` is unchanged,
> nothing in it is deleted or rewritten, and its chronology remains the audit record. This file only
> **adds** the current disposition of the row's closed-decision classification.

- Register classification: `resolved` — fixed for the stable-id providers (Gmail/Outlook) by keying
  drain lanes on address-space PROVENANCE rather than on one fixed key shape. The IMAP
  folder-qualified lane key `accountId:folderPath:messageId` from the `IOS-QUEUE-001` fix is
  **UNCHANGED and must NOT be reverted** — see `ios-queue-001.md`; reverting it re-opens a
  never-drop violation with a bystander.
- Amends: `Companion/Process/Current/KnownIssues/ios-queue-008.md`, the whole "Status" and "Full
  detail" sections — specifically the 2026-08-05 closed-decision disposition and its "the wrong end
  state is visible and fixed by one ordinary gesture" reasoning, which this amendment shows is false
  for the undo-inverse-plus-redelete shape.

## Status

✅ **FIXED for stable-id providers (2026-09-04, `42f4d4558`).** The IMAP arm is untouched and
stays governed by `ios-queue-001.md`'s invariant. The base record's registrable-and-recoverable
verdict, its severity-note closure, and its "fix the key's provenance, not its shape" prescription
all stand exactly as written; this amendment records that the prescribed fix was carried out and
names the shape of defect that motivated it.

## Subsystem and search terms

Action queue; undo inverse; re-delete; deleted email reappears; Gmail; `AccountManager.buildLanes`;
`AccountManager.buildLanes(_:folderLocalAccountIds:)`; `folderLocalAccountIds`; lane key provenance;
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
On a stable-id account, `undoMove` restores the row to its ORIGINAL id
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
`AccountManager.buildLanes(_:folderLocalAccountIds:)` now takes a folder-qualified key
(`accountId:folderPath:messageId`) for accounts whose provider ids are folder-local (IMAP/iCloud —
unchanged, keeps the `IOS-QUEUE-001` protection), and an account-qualified key
(`accountId:messageId`) for stable-id providers (Gmail/Outlook, and the demo account). The set of
folder-local account ids is computed in `drainPendingQueue` from `Account.provider`, using the same
predicate `admittedOrdinaryActionTargets` already uses to distinguish the two address spaces.

Tests: `PendingQueueLaneTests.stableIdUndoInverseAndRedeleteShareOneLane()` pins the exact race
described above — an undo inverse and a re-delete on one stable-id message must land in the same
lane. `PendingQueueLaneTests.imapSameUidInTwoFoldersStaysInSeparateLanes()` is the `IOS-QUEUE-001`
fence, re-asserted so the fix cannot regress it. `PendingQueueLaneTests.stableIdOpsInTwoFoldersMergeOnlyForTheStableIdAccount()`
checks the split applies per-account, not globally. `AccountManagerQueueDrainTests.drainPendingQueueRealStableIdSameMessageOpsNeverOverlapAndRunInIssueOrder()`
is the real-drain property test: a `setMoveHook` overlap oracle that fails if two ops on the same
stable-id message ever execute concurrently. This test is RED against the pre-fix code and GREEN
after.

## 2026-09-04 — instrumentation gap, follow-up not done here

The drain's `queueLog` is `print`-only, and the `[MoveTrace] deltaSync` branch lines are bare
`print`, both discarded on a device (production) build — so no device log could show directly which
lane ran first; the mechanism above was reconstructed from source and from the Gmail `history.list`
absence-of-evidence, not read off the device log. Gating these behind
`DebugModeManager.isLoggingEnabled()` so a future device-side race is directly observable is an
owner-decided follow-up, not done as part of this fix.
