# IOS-IMAP-013

> **Post-freeze amendment to a BASE-register record.** Added 2026-09-04 (GitHub #115) through the
> amendment surface in `Scripts/compact_known_issues.rb`. The base record's own bytes are hash-pinned
> and are **not** edited by this file: `Companion/Process/Current/KnownIssues/ios-imap-013.md` is
> unchanged, nothing in it is deleted or rewritten, and its chronology remains the audit record. This
> file only **adds** the current disposition of the row and records that the disposition the base
> record states was silently violated for three weeks and has been restored.

- Register classification: `closed-decision` — UNCHANGED. The base record's disposition — *"a tagged
  NO/BAD remains a typed failure; the durable operation stays queued and the account lane can halt
  again on later drains"* — is exactly the behaviour #115 restores. The record was never re-opened;
  the code stopped honouring it on 2026-08-13 and honours it again as of #115.
- Amends: `Companion/Process/Current/KnownIssues/ios-imap-013.md`, "Full detail" → "THE MECHANISM".
  The sentence *"The source is not assumed unchanged because a MOVE failure may be partial, so the
  same attempt never falls through to COPY/STORE/EXPUNGE"* still holds (no fallback was added). What
  this amendment records is that between `3f6a0a5a8` (2026-08-13) and #115 the code went the OTHER
  way from that sentence: instead of keeping a "may be partial" failure queued, `IMAPProvider.move`
  **retired** the operation on it, as though the MOVE had succeeded.

## Status

✅ **CLOSED AS A DECISION — DISPOSITION RESTORED (2026-09-04, GitHub #115).** A tagged NO/BAD on
`UID MOVE` that carries no `COPYUID` (`IMAPError.moveFailedAfterPossiblePartialCompletion`) is a
retryable refusal again: it falls to the generic catch in `AccountManager.executeSingleOp`, the
operation is requeued (`status = queued`, `retryCount += 1`) and the account lane halts for that
drain. Only the `COPYUID`-bearing form, `moveFailedAfterPartialCompletion(copyUID:)`, retires the
source members without retry, because it carries positive evidence that the destination copy exists.
Round 2 (2026-09-04): because the typed error's payload is the server's raw tagged response text and
`AccountManager.isMessageNotFoundError` runs BEFORE the generic catch with a substring fallback on
the error's description, the classifier now structurally exempts
`moveFailedAfterPossiblePartialCompletion` from that fallback, so the generic requeue arm is reached
for every response text (pinned by
`NeverDropExitClosureTests.aRefusedAtomicMoveStaysQueuedAndTheNextDrainLandsIt(refusal:)` over
`No mailbox selected` / `[NONEXISTENT] No mailbox selected` / `UID not found`, and by
`AccountManagerQueueIntegrationTests.typedNoCopyUIDMoveRefusalIsNeverMessageNotFound`).

## Subsystem and search terms

IMAP; RFC 6851; RFC 3501 §6.4.8; RFC 3501 §2.3.1.1; RFC 6851 §3.3; `UID MOVE`; tagged NO; tagged BAD;
`No mailbox selected`; raw reconnect; `IMAPConnection.executeCommandBody`; `clearInvalidChannel`;
`connectBody`; `MoveHandler.handleTaggedErrorResponse`;
`IMAPError.moveFailedAfterPossiblePartialCompletion`; `moveFailedAfterPartialCompletion(copyUID:)`;
`IMAPProvider.move`; `MoveOutcome`; `provenIds`; `requiresSourceReconciliation`;
`AccountManager.executeSingleOp` generic catch; requeue; `haltLane`; never-drop exit 2; "may have";
absence of evidence; MIS-IOS-004; `providerIdQueueFuzz`; `killFragments`; seed `0x70D8000000000002`;
`NeverDropExitClosureTests.aRefusedAtomicMoveStaysQueuedAndTheNextDrainLandsIt`;
`NeverDropExitClosureTests.aPossiblyPartialAtomicMoveConvergesToExactlyOneDestinationCopy`;
`NeverDropExitClosureTests.aVerifiedPartialAtomicMoveIsNeverReissued`;
`IMAPMoveWireContractTests.atomicPossiblePartialCompletionIsRetriedToExactlyOneCopy`;
`FakeIMAPServer.moveFailureAfterCommit`; `failNextCommand(containing: "UID MOVE")`; SwiftMail PR #208;
`3f6a0a5a8`; GitHub #115; IOS-IMAP-012; IOS-IMAP-006; IOS-QUEUE-007

## 2026-09-04 — the defect (GitHub #115): a refusal retired as a completion

On 2026-08-13 (`3f6a0a5a8`, the adaptation to SwiftMail PR #208) `IMAPProvider.move` gained a
`catch IMAPError.moveFailedAfterPossiblePartialCompletion` arm that returned
`MoveOutcome(provenIds: ids, provenDestinations: [], requiresSourceReconciliation: true)` — i.e. it
marked every requested source member PROVEN and let the queue retire the durable operation, exactly
as it would after a successful MOVE. But SwiftMail's `MoveHandler.handleTaggedErrorResponse` raises
that error for ANY tagged NO/BAD answer to `UID MOVE` when no `COPYUID` was retained. The error is
the server saying "no"; it carries no evidence that anything mutated. The arm treated the ABSENCE of
`COPYUID` evidence as if it were a provider-authoritative completion — the never-drop exit-2
conflation `MIS-IOS-004` names.

Found by `ProviderIdQueueFuzzTests.providerIdQueueFuzz`, seed `0x70D8000000000002`, on 2026-09-04,
with the shortest real reproduction: the connection drops mid-`UID MOVE`;
`IMAPConnection.executeCommandBody` calls `clearInvalidChannel()` → `connectBody()`, which
re-establishes a RAW TCP channel — no `LOGIN`, no `SELECT`; the retried `UID MOVE` on that channel is
answered `NO No mailbox selected` (zero server mutation; the server rejected the command before
touching any mailbox); the arm retired the op; the message stayed in INBOX; the queue was empty; the
user's archive gesture was gone. A dropped user intention is a defect, not an edge — this is the
"non-recoverable set" case of THE MANTRA, not a fail-closed residual.

## 2026-09-04 — the fix: delete the arm, nothing added

The arm is deleted. `moveFailedAfterPossiblePartialCompletion` now propagates out of
`IMAPProvider.move` to the generic catch in `AccountManager.executeSingleOp`, which requeues the
operation and halts the lane for that drain — the base record's disposition, verbatim. No new
mechanism, no classifier, no string-matching of the server's reason text. The
`moveFailedAfterPartialCompletion(copyUID:)` arm is untouched: it is the verified-partial form,
carries the `COPYUID` the server returned, and legitimately retires the source members with the
destination address admitted. `reconcilePendingOperations` is untouched. The invariant is stated in
a comment on the generic catch in `IMAPProvider.move`.

## 2026-09-04 — why retrying a "possibly partial" MOVE is safe (the argument the 08-13 change lacked)

The base record's re-open condition — *"provider evidence that a rejected command was guaranteed
pre-mutation"* — was never the requirement for keeping the operation queued. The requirement is that
a RETRY be harmless whatever the first attempt did, and three RFC clauses give that directly:

- **RFC 3501 §6.4.8** — a UID command naming a UID that no longer exists in the mailbox is ignored,
  not an error. If the first attempt already moved the message, the retry's `UID MOVE` is a no-op on
  the source and the operation retires on that later success.
- **RFC 3501 §2.3.1.1** — UIDs are not reused within a `UIDVALIDITY` epoch, and the drain compares
  every operation against its durable `observedUidValidity`, so a retry cannot name a different
  message than the one the user acted on (C3 is preserved).
- **RFC 6851 §3.3** — a server SHOULD NOT leave a message in both mailboxes after a failed MOVE. The
  residual worst case, a destination copy that landed while the source survived, produces a
  duplicate after the retry — the residual already ACCEPTED under `IOS-IMAP-006` / `IOS-QUEUE-007` —
  never a wrong-message mutation and never a dropped intention.

Contrast the `COPYUID`-bearing form: there the server has POSITIVELY reported the destination copy's
address, so retiring the source member and admitting the destination is evidence-backed, not a
guess. "The server may have done something" and "the server told us what it did" are different
evidence classes; the 2026-08-13 change put both in the no-retry class on the strength of the word
"may". `MIS-IOS-004` recurrence recorded.

## 2026-09-04 — tests

- NEW `NeverDropExitClosureTests.aRefusedAtomicMoveStaysQueuedAndTheNextDrainLandsIt()` — the
  invariant test for #115: `FakeIMAPServer.failNextCommand(containing: "UID MOVE", message: "No
  mailbox selected")`, one queued `.move` INBOX→Archive, two drains. Half 1 asserts the operation is
  still queued after the refused drain and the message is still in INBOX; half 2 asserts that after
  the next drain Archive holds the target, INBOX does not, the queue is empty and the wire oracle
  reports no wrong-message mutation. RED on the pre-fix code (queue empty after the refused drain;
  Archive empty and INBOX still populated after the retry), GREEN after. It never asserts a MOVE
  count — the property is the end state, not the mechanism.
- FLIPPED `NeverDropExitClosureTests.aPossiblyPartialAtomicMoveIsNeverReissued` →
  `aPossiblyPartialAtomicMoveConvergesToExactlyOneDestinationCopy`; and
  `IMAPMoveWireContractTests.atomicPossiblePartialCompletionIsNotRetryable` →
  `atomicPossiblePartialCompletionIsRetriedToExactlyOneCopy`. Both previously BLESSED the defect
  (they asserted the refusal was not reissued and the queue emptied); both now assert convergence to
  exactly one destination copy with no `UID COPY`, no `\Deleted` stores and no expunge.
- KEPT `NeverDropExitClosureTests.aVerifiedPartialAtomicMoveIsNeverReissued` and its helper — the
  `COPYUID`-bearing form's no-retry contract stands.
- `FakeIMAPServer.moveFailureAfterCommit` is now one-shot (the NEXT `UID MOVE` fails after
  committing; a retry is served normally) so the flipped tests can converge.
- `ProviderIdQueueFuzzTests.killFragments` gains `"UID MOVE"` so the fuzzer keeps reaching the
  mid-command kill on the atomic route; both recorded seeds are retained.

## 2026-09-04 — relationship to IOS-IMAP-012

The 2026-08-13 head amendment on `ios-imap-012.md` described the same arm as "the same no-retry
safety class as an atomic success with missing evidence". That claim is half-withdrawn by
`Amendments/ios-imap-012.md`: the `COPYUID`-bearing half stands, the possible-partial half does not.
