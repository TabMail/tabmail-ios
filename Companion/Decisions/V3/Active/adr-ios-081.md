## ADR-IOS-081: Account-Scoped Provider Ids — Drain Lanes, the Retirement Handoff, and the Row-Following Re-Key

**Date:** 2026-09-05

**Status:** Active. Amends ADR-IOS-018 (the action queue's lane model) and ADR-IOS-068 clause 6 (a
recorded address is the only name for a message). **Supersedes no ADR.** It does supersede one
known-issue section — the "why Outlook is excluded" section of
[`Companion/Process/Current/KnownIssues/Amendments/ios-queue-008.md`](../../../Process/Current/KnownIssues/Amendments/ios-queue-008.md),
whose text is preserved there verbatim and marked superseded.

**Context.** Two distinct properties of a provider id had been treated as one, under one name:

- **Folder-independence** — one provider id names one message per ACCOUNT, so two rows in different
  folders bearing the same id are the same message.
- **Immutability** — the id survives a folder move.

Gmail has both. IMAP has neither (a UID is mailbox-local AND renumbered by a move). **Microsoft
Graph has the first and not the second:** the id is account-wide, and it is REALLOCATED on every
move, because this tree sends no `Prefer: IdType="ImmutableId"` (`IOS-GRAPH-002`).

The distinction is not academic — the two properties answer two different questions, and the action
queue asks both. `AccountManager.buildLanes` needs the FIRST: to decide whether two queued
operations naming the same id are about the same message and must therefore be serialized into one
drain lane. `MessageHeaderRekey.finishMove` and every queued operation addressed at a moved message
need the SECOND: to decide whether an address learned before a move is still valid after it.

The classifier that fed `buildLanes` was called `immutableIdAccountIds`, and its name asserted the
property the lane key does NOT need while omitting the one it does. That is why Outlook could not be
admitted: it satisfied the requirement and failed the name. `IOS-QUEUE-008`'s fix therefore
serialized Gmail and the demo account and wrote an explicit prohibition against "completing" it by
adding `.outlook` — correctly, because serializing Outlook alone would have been strictly worse than
the race it replaced. A follower queued behind a move would be GUARANTEED to run after that move,
naming the id the move destroyed; Graph would answer `404`; `executeSingleOp`'s single-message
conflict arm would read that as provider-authoritative "already done" and DELETE the operation. A
race that is sometimes wrong and recoverable would become a DETERMINISTIC dropped intention.

**Decision.**

1. **The classifier names the property the lane key actually needs.**
   `AccountManager.immutableIdAccountIds` becomes **`AccountManager.accountScopedIdAccountIds`**, and
   `buildLanes(_:immutableIdAccountIds:)` becomes `buildLanes(_:accountScopedIdAccountIds:)`. It
   admits `AccountProvider.gmail`, `AccountProvider.outlook` and `DemoSeed.demoAccountId`.

   The contract is: **membership means one provider id names one message per account** — nothing
   about the id surviving a move. Two shape properties are load-bearing and unchanged from the
   `IOS-QUEUE-008` fix, and neither may be traded away by a later tidy-up:
   - **Folder-qualified is the DEFAULT, not an opt-in.** An account is account-qualified only by
     being NAMED. Absence — including an unrecognised `provider` string from a newer build or from
     persistent corruption — yields the folder-qualified key that `IOS-QUEUE-001` requires. There is
     no "unknown" classification, quarantine state or new column, because there is nothing to
     classify.
   - **It never decodes whole `Account` rows.** `AccountProvider` is a closed `String, Codable` enum
     while `account.provider` is unconstrained text, so a row-decoding query would let ONE corrupt
     bystander row throw `DecodingError.dataCorrupted` before any operation is claimed and wedge
     EVERY account's drain — the wedge corollary one level above `IOS-QUEUE-001`. The query stays an
     id-only read of the raw column.

2. **Retirement is the chokepoint, and it carries the address to every holder of the old one.**
   `MessageHeaderRekey.finishMove` is redefined from "finish the move locally for the header" to
   **"finish the move locally for every holder of the old address"** — the header row (as before) and
   the queued operations (new, `readdressQueuedOperations`). Both retirement paths already run it
   inside ONE `retryWrite` transaction (`executeSingleOp`'s success arm and
   `retirePartiallyCompletedOp`), so the re-key and the re-addressing commit together or not at all.

   The predicate: when the account's ids are account-scoped and the wire proved at least one
   destination, every `PendingOperation` with `accountId == op.accountId`, `id != op.id` and
   `status != cancelled` whose members intersect the proven source ids has each such member replaced
   by its mapped destination id, by primary key, leaving every other column untouched. The mapping is
   **per id**, so a multi-member follower is partially rewritten correctly and a partial batch
   re-addresses exactly its proven prefix. Chains converge because each retirement maps against the
   ids the rows carry at that moment. The readdressed ids are returned in
   `MoveFinishResult.readdressedOperationIds` and logged on the debug-gated queue channel;
   `IOS-QUEUE-008` took a month to diagnose because the lane decision left no readable trace, and
   that is not repeated.

   **`status != cancelled` rather than `status == queued` is deliberate.** Under account-qualified
   lanes every operation sharing an id with the retiring one was claimed in the SAME pass — that is
   what `buildLanes`' connected-component grouping means — and is `inFlight` while it waits behind
   the predecessor in the same lane task. Those are exactly the operations that must be
   re-addressed. Operations inserted mid-pass are `queued` and are covered too. Nothing outside the
   lane can hold the id, by construction.

   **Durable re-addressing only — not a drain-scoped map, and not both.** A map dies with the
   process and with the drain, while an undo's inverse may be claimed in the NEXT drain and an
   offline follower is claimed in a drain that never saw the predecessor's wire response. Carrying
   both would be two sources for one fact, which is the "N spot checks instead of one chokepoint"
   shape this codebase has been burned by repeatedly. The table is the only truth, and the lane loop
   re-reads it.

3. **The account-scoped gate is a C3 guard, not a performance switch.**
   Re-addressing on IMAP would be a WRONG-MESSAGE mutation: a UID is mailbox-local, so a pre-move
   operation — or `NSEDataBridge.queueSetTagPendingOp`, which inserts a raw row at `folderPath`
   `'INBOX'` — can legitimately name the same numeric UID for a DIFFERENT message in another folder.
   IMAP also has no legitimate follower to re-address, because `admittedOrdinaryActionTargets`
   refuses the nil-epoch optimistic row. The gate is therefore the same fact the lane key uses, and
   the two must never drift apart.

4. **On an account-scoped provider the re-key FOLLOWS THE ROW; G3's folder clause is IMAP-specific.**
   `finishMove`'s G3 clause fetched the member by primary key at the operation's destination path.
   On an account-scoped provider the member is now located by `(accountId, messageId)` and re-keyed
   in the folder it CURRENTLY occupies, requiring exactly one match — zero is the ordinary
   "already gone" case and yields `removedOldHeaderIds`; two or more declines.

   This is what makes delete → undo → re-delete work. When the forward move retires, an undo has
   already moved the row back to the source folder, so a destination-keyed lookup misses it, the row
   keeps a dead id, and the user's next gesture names it.

   ⚠️ **The IMAP arm keeps G3's folder clause, byte for byte, and it is correct there for the exact
   opposite reason.** A row that is not where the operation put it is a DIFFERENT physical message,
   and re-keying it would be the C3 violation clause 3 guards against. "The folder clause is a bug"
   and "the folder clause is the guard" are both true, of different address spaces. Do not unify
   them.

5. **A requeue writes COLUMNS, not a struct captured before the lane ran.**
   The eight drain sites that returned an operation to `queued` by saving a captured value now call
   `PendingOperation.markQueued(_:id:incrementRetryCount:)`, which writes `status` — and optionally
   `retryCount + 1` — addressed by primary key. A `save` is an UPDATE of EVERY column from a snapshot
   taken before any lane ran, so a `.haltLane` or evidence-refused requeue of the REMAINING lane
   members would write pre-handoff ids back over addresses the wire had just proved, silently
   undoing clause 2 at exactly the moment it mattered. `reconcilePendingOperations`, the claim loop
   and the partial-batch narrowing fetch and save inside one transaction and are correctly left
   alone. **The general rule this instantiates: a write that intends to change one field must not be
   expressed as a whole-row write from a stale snapshot, in any code that another writer can touch
   between the read and the write.**

6. **The drain re-reads before it executes, and there is NO fallback.**
   The lane loop fetches each operation by primary key immediately before `executeSingleOp` and
   SKIPS it if the row is gone. A `?? capturedOp` fallback is refused: the only writers that delete a
   claimed row are cancel and annihilation, both of which are the user WITHDRAWING the intention, so
   a fallback would resurrect a withdrawn gesture and send it to the wire. A nil-defaulted or
   silently-falling-back seam is fail-DANGEROUS here, not fail-safe.

7. **`finishMove` gains a NON-defaulted `accountScopedIds: Bool`.**
   Every call site — two production, eight test — passes it explicitly. A defaulted parameter would
   let a future provider acquire, or lose, the row-following re-key and the queue handoff BY
   SILENCE, which is precisely how the immutable/account-scoped conflation entered the tree.

8. **The IMAP deferred-successor mechanism is NOT unified with the handoff, and nothing is deleted
   from it.** `DeferredMoveSuccessor`, `registerDeferredMoveSuccessors`, `coalesceDeferredMoves`,
   `dropDeferredMoveSuccessors`, `materializeDeferredMoveSuccessors[InFIFO]`, their tests and
   `MessageHeaderRekey.addressHandoffs` all stand. The two mechanisms share the retirement chokepoint
   and nothing else. Three independently sufficient reasons:
   - **Admission.** An IMAP follower behind an in-flight predecessor cannot be admitted at all —
     `optimisticMoveToFolder` nulls `observedUidValidity` and `admittedOrdinaryActionTargets` refuses
     a nil-epoch row, which is the C3 protection `IOS-MOVE-002` says never to weaken. An Outlook
     follower is admitted by id alone.
   - **Laning.** Laning an IMAP follower with its predecessor would need the account-qualified key,
     which re-opens `IOS-QUEUE-001` on IMAP (a wedge with a bystander), or a durable predecessor
     link — a new column and a new lane axis.
   - **Timing.** `DeferredMoveSuccessor` is created BEFORE the wire answers and deliberately holds no
     address; the handoff rewrites an address that already exists, AFTER the wire answers. The whole
     point of the IMAP design is that the successor is not a row.

   On Outlook the deferred arm is unreachable anyway — it requires
   `predecessor.observedUidValidity != nil`, which is never true there — so an Outlook second gesture
   already falls through to an ordinary durable operation. That is strictly better than a
   process-local successor: "if the process dies, sync simply exposes the completed forward move" is
   an accepted IMAP loss that a durable row does not have.

**Accepted limitation (owner, 2026-09-04).** If the process dies AFTER Graph returns `2xx` for a
move and BEFORE the retirement transaction commits, that move's queued followers keep the dead id.
On relaunch `reconcilePendingOperations` DROPS the interrupted `.move` — it cannot distinguish a
completed move from an uncommitted one and prefers a dropped move to a duplicate — so the header
converges by sync while the FOLLOWER's intention does not: its next attempt `404`s and the conflict
arm deletes it.

It is **not closable in this design.** Re-associating the follower needs the response that was lost,
and RFC identity may NOT be used as a mutation authority to bridge the gap: that is exactly the
direction ADR-IOS-068 D4 bans (`IOS-IMAP-002`), and this ADR does not weaken it. The window is
bounded to ONE process death inside ONE write and is **strictly narrower than what it replaces** —
before the handoff existed the same follower was lost on every such move with no crash at all. The
structural fix is Graph immutable ids
([#117](https://github.com/TabMail/tabmail-ios/issues/117)); the launch-time drop it depends on is
[#116](https://github.com/TabMail/tabmail-ios/issues/116). Per the standing rule that an accepted
limitation belongs where the next editor will read it, the same statement is carried in the source
beside `readdressQueuedOperations`.

**Consequences.**

- **`IOS-QUEUE-008` is now fixed for Gmail, Outlook and the demo account.** Its Outlook-exclusion
  section is superseded, not withdrawn: the reasoning was right, and the prohibition it wrote was MET
  rather than waived, because the missing precondition landed in the same change. **The lane change
  and the handoff are ONE fix and must never be split, in either direction** — landing the lane
  change alone reproduces the deterministic loss the exclusion described.
- **The negative fence survives the rename.** The exact-set oracle
  `AccountManagerQueueDrainTests.accountScopedIdAccountIdsAdmitsExactlyGmailOutlookAndTheDemoAccount`
  still asserts an EXACT set over rows for every provider, including one whose `provider` column is
  set by raw SQL to an undecodable string — the only shape that can fail on an account a drain
  fixture never seeds. Widening the classifier to `.icloud`, to `.imap`, or by accident, fails it.
- **`IOS-GRAPH-002`'s residual is closed for the ordinary paths it enumerated** (offline triage
  drained together, a swipe in one folder followed by a swipe in another, an undo of a drained move),
  and `IOS-GRAPH-003`'s reachable set narrows to the crash window above plus an EXTERNAL move by
  Outlook desktop, OWA or a server rule — which no local fix can reach, because no local wire
  response ever carried that address. `deleteConfirmedGoneHeader` and `isConfirmedGoneError` are
  untouched.
- **No schema, migration or drain-ordering change.** The drain still orders by `createdAt`, and the
  404 batch split still copies `createdAt` onto its children. Making the queue's order durable
  against a backward clock step is a separate concern, routed by the owner to its own follow-up; it
  is NOT part of this decision and no column was added for it.
- **The 404 classification is untouched**, so no lane wedge is introduced. The re-key is what makes a
  retry terminate; reclassifying the error without re-keying would trade one never-drop violation for
  another, which `IOS-GRAPH-002` records as mirror-image trap 1.
- **`Prefer: IdType="ImmutableId"` was NOT adopted**, for the account-wide migration reasons
  `IOS-GRAPH-002` enumerates: it changes id format for every already-minted value at once
  (`MessageHeader.messageId`, `PendingOperation.messageIds`, `MessageIdentity.aiCacheKey`,
  `nse_processed_message.id`, content-store keys, `Folder.path`, and the NSE's separate Graph
  client), and Microsoft still documents the immutable id as changing on an archive-mailbox move or
  an export/re-import. It narrows the churn; it does not abolish it. Evaluate it on top of the
  handoff, never instead of it — [#117](https://github.com/TabMail/tabmail-ios/issues/117).
- **Recorded as `MIS-IOS-003` instance 6.** The wire's new id was applied to the header and not to
  the queued operations that named the same address: the same defect as the original, one table over,
  in its quiet form.

**Fences.** `TabMailTests/Services/OutlookQueueHandoffTests.swift` (five real-drain cases against a
churning Graph server, source folder only so the post-drain sync cannot mask a failure);
`QueueCoreInvariantTests.accountScopedRekeyFollowsTheRowOutOfTheDestinationFolder`,
`.imapRekeyStillDeclinesWhenTheRowLeftTheDestination`,
`.queuedFollowerIsReaddressedAndBystandersAreNot`;
`PendingQueueLaneTests.outlookSameIdInTwoFoldersSharesOneLane` and, as the untouched IMAP negative,
`.imapSameUidInTwoFoldersStaysInSeparateLanes`;
`AccountManagerQueueDrainTests.accountScopedIdAccountIdsAdmitsExactlyGmailOutlookAndTheDemoAccount`;
`ProviderIdQueueFuzzTests.stableIdQueueLaneFuzz`, now alternating `.gmail` and `.outlook` per round;
and `StatefulExchangeActionServerTests`' self-checks for the three fixture seams. A fourth seam — a
`/move` overlap counter — was built and REMOVED when its positive control failed: a `URLProtocol`
transport does not admit a second request into a route while an earlier one is blocked, so the
counter reported the transport's serialization rather than the queue's and its negative was
unfalsifiable. Outlook serialization is instead pinned by the ORDER a follower's differently-shaped
verb reaches the wire in, and by `buildLanes` directly.
