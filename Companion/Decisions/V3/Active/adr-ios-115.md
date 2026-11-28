## ADR-IOS-115: A Gesture Read Before a Folder's UIDVALIDITY Reset Is Refused by the Folder's Reset Generation

**Status:** Active (2026-11-17, #414, part 1: the core and the AI confirmation cards).

**Context:** After a proven UIDVALIDITY reset (ADR-IOS-061), step 5 of
`runUidValidityResetReaction` stamps the fresh epoch and step 6 resyncs, re-seating a DIFFERENT
email at the same header id (`account:folder:UID`) with the new epoch. Any path that took a header
id from something the user saw and re-resolves the row by that id when the work runs picks up the
replacement, and `admittedOrdinaryActionTargets` admits it because its `observedUidValidity`
equals the live epoch (C3 wrong-message mutation). The content witness `ExpectedMessageIdentity`
is blind when either Message-ID is missing (IOS-IDENTITY-001). Durable ops (exit 4), undo (recorded
tuple) and draft deletes (minted epoch) already carry their own epoch and are safe.

**Decision:**
1. `FolderResetGeneration` (in memory): a monotonic serial, the serial at which each folder last
   finished a reset, and a task-local `gestureStamp`. `recordReset(folderId:)` runs inside step 5's
   stamping branch, before `lastKnownUidValidity = fresh`; an idempotent re-drive does not bump.
2. The write queue stamps each item when it is enqueued (`enqueueWriteFromSynchronousContext`
   synchronously before its actor hop; `enqueueWriteAfterPriorAdmissions` at entry) with
   `gestureStamp ?? current()` and runs it under that stamp. An `IntentCycle` keeps the OLDEST stamp
   (`resetStamp`) and runs its write section under it.
3. `admittedOrdinaryActionTargets` returns nil, before anything else, when a bound stamp predates the
   folder's last reset; `roleMoveRejectDispositions` reports that as `.terminalStale` (a retry under
   a fresh stamp would admit the replacement). No stamp bound = no verdict (refuse-only witness,
   ADR-IOS-068 carve-out). The outbox finalize binds nil (it reads the original at execution time).
4. Background work is not a gesture: a deferred Undo is materialized with no stamp (its source
   address is the one the provider just proved) and only when the destination row still carries the
   epoch the provider proved; the outbox finalize binds no stamp. A manual tag (local only, no
   admission) checks the generation inside its own write, and on a failed write before skipping its
   cache and teaching steps.
5. A surface whose wait outlives the reset binds the stamp taken when its view was READ. Part 1:
   the AI archive / delete cards (`EmailArchiveTool`, `EmailDeleteTool`) stamp before reading the
   headers the card shows.
   Settings "Archive old messages" (`SettingsView.archiveOldMessages`, #813) stamps before reading
   the old rows and binds that stamp around its mark-read and move, which run outside the write
   queue.

**Why not the alternatives:** a per-message RFC witness (six review rounds each found a producer
that dropped or rebuilt the Message-ID before admission, and it is blind on RFC-less mail) or a
per-message epoch witness (the same threading problem through ids-only APIs). The generation is
ambient: one stamp per operation, captured centrally, blind to nothing.

**Consequences:** a refusal is silent (IOS-EPOCH-001 D6(a)); a moved row returns through
`.messageMovesRefused`. A defect fails closed (only removes admissions). In memory is enough: no
queued closure or surface survives a relaunch, and durable ops are covered by exit 4.

**Open (part 2, after the chat-view rewrite of the same producers):** the inbox list
(`displayStamp` captured before each full read), the Move and label sheets, the detail view
(`openStamp`), and a lexical fence forcing every gesture producer through a stamp wrapper. Until
then those surfaces are stamped at enqueue time and keep the pre-#414 exposure.

**Amendment 2026-11-25 (#1139): the reset also forgets the folder's address links.**
- *Context.* A provider-proven move leaves a process-local link from the old header id to the new
  one (`MessageHeaderRekey.addressHandoffs`). The links bridge the gap until the in-memory mirrors
  follow the re-key. Four readers use them: `snapshotOverlayMutation` (the Undo snapshot's
  `overlayAdjustedSnapshot` and the action location), `coalesceDeferredMoves`,
  `InboxViewModel.lookupMessage` and the refused-move payload. A link is keys only. After a
  reset, the resync can seat a different email at either end of a link. The link then joins two
  different messages: a pending change of one is read as the other's, and a lookup of one id
  reaches the other message.
- *Decision.* Step 5's stamping branch calls `MessageHeaderRekey.forgetAddressHandoffs` right
  after `recordReset`. It forgets every link with EITHER end in the folder; links outside the
  folder stay. It runs in that write and not at the purge (step 3), for one reason. G2 in
  `finishMove` compares a COPYUID's epoch with the folder's stored epoch, and that epoch changes
  only in this write. So a move retired between the purge and the stamp could still publish a link
  under the old epoch; after the stamp G2 refuses one. Every earlier write published its links in
  its commit callback, before this write began.
- *Consequences.* In memory only, like the generation. A rolled-back stamp leaves the links
  forgotten, and a link from a still-valid chain through the folder is forgotten too. Both only
  drop a short-lived bridge, and the next reload follows the durable row (fails closed).
- *Tests.* `UidValidityResetPurgeCompanionTests.resetForgetsTheAddressLinksOfItsFolderOnly` runs
  the real reaction and asserts four things:
  - neither an Undo snapshot nor a lookup crosses a link out of the folder;
  - neither crosses a link into it;
  - a link outside the folder survives;
  - the test must fail on the code before this amendment (red-first, proven once in the
    confirmation run).
- *Keywords:* address handoff, handoff link, `predecessorHeaderIds`, `currentHeaderId(afterHandoffFrom:)`,
  `forgetAddressHandoffs`, UIDVALIDITY reset, re-seat.
