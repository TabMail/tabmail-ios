## T4.S6 follow-up — SUPERSEDED v3 intermediate; retain for history, never implement from it (2026-07-31)

⛔ **CURRENT FORWARD-PORT RULING (2026-08-01) supersedes the two implementation prescriptions
below.** The old `v69` draft-op stamp and the later `v72` draft-specific queue epoch were
intermediate compatibility machinery, not the destination. The active frozen candidate uses the
native `(account, Drafts mailbox path, UIDVALIDITY, UID)` tuple, records the queue epoch in
`PendingOperation.observedUidValidity`, leaves the applied physical draft-specific queue column
inert, normalizes unsafe legacy Draft linkage in v73, and blanket-purges every legacy
`pendingOperation` in v74. There is no action-queue migration compatibility requirement; authored
Draft/body/recipient/attachment/ChatTurn bytes and Outbox obligations remain outside that purge.

Most importantly, **a mailbox-wide non-UIDPLUS EXPUNGE is never an acceptable fallback.** It can
destroy every co-resident message already marked `\Deleted`, including messages the action did not
name, and therefore violates C3. Without UIDPLUS, keep the soft delete/fail closed and let sync
reconcile; an orphan or a user-redone action is acceptable, a wrong-message deletion is not. Read
the historical derivation below only to understand how the rejected state arose.

Two independent confirmed defects on the draft path, fixed together. Both are C3 (never mutate the wrong message).

### 1. Historical intermediate: `PendingOperation.observedUidValidity` at migration `v69`

🚨 **THE LESSON, worth more than the fix: "carries a non-numeric id" is a property of the ROW; "resolves by SEARCH" is a property of the EXECUTOR, and the two can disagree.** `AccountManager.opIsAddressOnly` classifies by id shape and returns FALSE for any op carrying a non-numeric id alongside a UID. `queueDraftDelete` writes `messageIds = [numericUID, rfc822]` — the rfc822 is there for the SYNC FILTER (`pendingAllIds`), not for resolution — so the op read as identity-carrying, the reset reaction's step-5 sweep left it alone, and `executeOperation` then handed `messageIds.first` (the UID) to `provider.deleteDraft`, which for a numeric id short-circuits to a literal `UIDSet` with no SEARCH. Post-reaction the op unparked and expunged whichever message the NEW numbering had placed at that UID. This also **falsified the drain's own written safety argument** ("the same transaction that clears the flag also removes the address-only ops"), which is now corrected in place at `AccountManager.drainPendingQueue`'s claim transaction.

**Owner directive (verbatim, 2026-07-31):** *"The delete op should NOT survive a UIDVALIDITY reset — it cannot. The op should no-op once that validity gets invalid."* A live-epoch re-resolution / existence-FETCH machinery for the draft path was PROPOSED AND OVERRIDDEN — do not reintroduce it.

The shape (design (a), ported from `v2final`'s `v74_addPendingOperationObservedUidValidity`; design (b), widening the sweep's classifier, was REJECTED — see below):
- `PendingOperation.observedUidValidity: Int?` (migration `v69`, nullable, no backfill). Stamped INSIDE the same gated write transaction as the insert with the folder's `lastKnownUidValidity`.
- **Stamped by exactly ONE site today: `queueDraftDelete`, and only when `serverDraftId` is NUMERIC** — the same discriminator `newGestureRefusedForUnknownEpoch` already uses. Stamping an rfc822-addressed op would let the claim check drop intention that is still perfectly resolvable (Message-ID SEARCH is epoch-immune): the mirror-image bug, a permanent refusal. Non-IMAP accounts stamp nil for free — Gmail/Graph never populate the column.
- The claim transaction in `drainPendingQueue` DELETES the row (never parks — the old epoch never comes back, so a park is a permanent wedge) when the stamp and the folder's current epoch both exist and disagree. C5 blesses the drop.
- **FAILS OPEN on a nil live epoch**, same polarity as the reference. `SyncEngine.resetEmptyFolderCrawlEpoch` really does clear the column back to NULL, so "unknown" must not read as "different".
- Ordered AFTER the quarantine park: during quarantine the folder still holds the OLD epoch (step 5 owns advancing it), so the stamp agrees and the compare cannot fire.

**Why (b) — widening `opIsAddressOnly` — loses, in the words that matter for the next person tempted by it.** (i) It is a classifier over id shapes, so the next op shape that carries a non-address id beside a UID defeats it again; widening it to "ANY id numeric" over-drops a batch `.move` of `[rfc1, uid2]`, dropping rfc1's still-resolvable intention. (ii) **The sweep only runs inside the reaction's step-5 transaction, and there is a second door that never touches the reaction at all**: `resetEmptyFolderCrawlEpoch` clears the epoch to nil and `bootstrapCrawledFolderUidValidity` re-stamps a NEW value, with no `uidValidityResetPendingAt` ever set and no sweep ever run. A per-op stamp survives that route; a sweep cannot.

### 2. Historical defect: `IMAPProvider.deleteDraft` did a bare, mailbox-wide EXPUNGE

Independent of any epoch question. A bare `expunge()` is mailbox-WIDE (RFC 3501 §6.4.3) — it removes EVERY `\Deleted` message in the selected mailbox. In Drafts that population is not hypothetical: `saveDraft`'s old-copy delete marks messages `\Deleted` with BOTH the STORE and the EXPUNGE `try?`-swallowed, so every failed/interrupted save leaves exactly that residue, and another client's soft-deleted drafts qualify too. Deleting one draft destroyed all of them.

New private `IMAPProvider.expungeScopedToTargets(_:server:logDescription:)` — the UIDPLUS-conditional tail, shape taken from `idempotentMove` in the same file (the in-repo precedent for this exact decision). Applied at `deleteDraft` AND at both legs of `saveDraft`'s old-copy delete (scope only; their `try?` swallowing and reachability are unchanged).

⛔ **RETRACTION — this was never a valid deliberate deviation.** `v2final`'s
`storeDeletedAndMaybeExpunge` fails closed without UIDPLUS because bare EXPUNGE is mailbox-wide.
The claimed “bounded collateral” was unbounded with respect to the action's target set and was a
real wrong-message/data-loss defect. v3 follows the reference safety direction: no UIDPLUS means
no mailbox-wide purge. Do not restore this fallback even if the soft-deleted draft later
re-materializes; that fail-closed residue is the owner-approved simplification.

### Tests (both red-proven by in-place inversion)

`TabMailTests/Sync/DraftDeleteEpochBoundaryTests.swift` and `TabMailTests/Providers/IMAPDraftExpungeScopeTests.swift`. Both pin SYSTEM PROPERTIES, never the mechanism: *"an op recorded under a discarded numbering never executes"* (asserted on `MockEmailProvider`'s call log after a real `queueDraftDelete` → real `uidValidityResetArmFlag`/`uidValidityResetStampFreshEpoch` → real `drainPendingQueue`) and *"no mutation lands on a message whose identity differs from the gesture's target"* (delegated to the existing `FakeIMAPServer` wrong-message wire oracle, `expectMutation`/`wrongMessageViolations`). Three over-refusal controls guard the mirror image: unchanged epoch still deletes, rfc822-addressed delete survives an epoch change, and a non-UIDPLUS server still gets its draft deleted.

⚠️ **Test-harness trap worth remembering: one `await drainPendingQueue()` is NOT enough in a test that has just called a `queue*` method.** Those methods end with an unstructured `Task { await drainPendingQueue() }`; if that stray drain is still inside its three-pass loop, the `isDraining` guard turns the test's own call into a `needsRedrain` flag and returns IMMEDIATELY, so assertions run before anything executed. `DraftDeleteEpochBoundaryTests.drainUntilSettled` loops on (queue empty ∧ `pendingQueueIsQuiescentForTesting`). This made a CORRECT implementation fail its own control test on first run.

---

