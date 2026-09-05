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

✅ **CLOSED AS A DECISION — DISPOSITION RESTORED (2026-09-04, GitHub #115), AND ROUTED LANE-LOCAL
(2026-09-05, round 3).** A tagged NO/BAD on `UID MOVE` that carries no `COPYUID`
(`IMAPError.moveFailedAfterPossiblePartialCompletion`) is a retryable refusal again. Only the
`COPYUID`-bearing form, `moveFailedAfterPartialCompletion(copyUID:)`, retires the source members
without retry, because it carries positive evidence that the destination copy exists.

Round 2 (2026-09-04): because the typed error's payload is the server's raw tagged response text and
`AccountManager.isMessageNotFoundError` runs with a substring fallback on the error's description,
the classifier structurally exempts the refusal from that fallback, so no response text can retire
it (pinned by `NeverDropExitClosureTests.aRefusedAtomicMoveStaysQueuedAndTheNextDrainLandsIt(refusal:)`
over `No mailbox selected` / `[NONEXISTENT] No mailbox selected` / `UID not found`).

Round 3 (2026-09-05) — **THE ROUTING, which is the current disposition.**
`IMAPProvider.move`'s atomic route catches the typed error in an arm of its own and rethrows it as a
private `ProviderEvidenceUnavailable` conformer (`IMAPAtomicMoveRefused`, alongside
`IMAPLivenessProbeInconclusive` / `IMAPDestinationEpochRefusal` / `IMAPEpochEvidenceMissing`; the
server's reason text rides along as a diagnostic payload). It therefore reaches the drain's
**lane-local evidence-unavailable arm** — requeue, `status = queued`, `retryCount += 1`,
`evidenceRefused.insert`, `.haltLane` — and **not** the generic catch, which inserts the account into
`DrainContext.failedAccounts` and suppresses every operation on the account for the rest of the
drain. The refused MOVE and its same-lane successors are held; every disjoint lane on the same
account keeps draining, on this drain and on every later one. The round-2 classifier exemption is
restated on the PROTOCOL rather than on one transport library's enum
(`if error is ProviderEvidenceUnavailable { return false }`), and `AccountManagerQueue.swift` no
longer imports SwiftMail at all.

Round 3b (2026-09-05) — **OWNER DECISION: a refusal whose RESPONSE CODE says the command can never
succeed RETIRES the operation.** The owner decided the `[TRYCREATE]` question the round-3 section
below records as pending: *"if server has deleted folder, we should retire that op"*, *"if server
says op is broken, we should retire it. and then later on full sync would catch that back"*. A
tagged NO/BAD on `UID MOVE` with no retained `COPYUID` whose resp-text BEGINS with `TRYCREATE`
(RFC 3501 §6.4.7, RFC 6851 §3.3), `NOPERM`, `CANNOT` or `NONEXISTENT` (RFC 5530 §3) is provider
AUTHORITY — a positive statement about the command the server just refused, unlike the LIST omission
round 3 routed around — so `IMAPProvider.move` throws the private `IMAPActionPermanentlyRefused` and
its own outer `catch` returns `MoveOutcome(provenIds: ids, provenDestinations: [])`. Zero wire
mutation, the message untouched in the SOURCE mailbox on the server, the queue empty, and the next
sync of the source folder reclaims the local row. `IMAPActionMailboxAbsent` is NOT widened to carry
this (it means "an exact LIST proved the mailbox gone" and has two other catch sites), and its
LIST-probe producers are untouched.

The code is read STRUCTURALLY: RFC 3501 §7.1 defines `resp-text = ["[" resp-text-code "]" SP] text`,
so only the bracketed atom at the very START of the resp-text counts. `NO Move refused, see
[TRYCREATE] semantics` is a server explaining itself in prose and does NOT retire anything — a
substring search there would let a server's human sentence drop a user's intention.

Every other refusal keeps the round-3 disposition unchanged — evidence-unavailable, lane-local
requeue, `retryCount += 1`, `.haltLane`, account untouched, retried on the next drain: no code at
all (a non-conforming server; GitHub #118, wontfix) and every code outside the permanent set
(`OVERQUOTA`, `UNAVAILABLE`, `EXPUNGEISSUED`, `SERVERBUG`, `INUSE`, `LIMIT`, …), all of which
describe conditions that can clear. **The owner has directed a queue-wide RETRY LIMIT for that
residual as a SEPARATE change; it is pending, not silent, and is not taken here.**

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
`3f6a0a5a8`; GitHub #115; IOS-IMAP-012; IOS-IMAP-006; IOS-QUEUE-007;
`ProviderEvidenceUnavailable`; `IMAPAtomicMoveRefused`; `IMAPLivenessProbeInconclusive`;
`IMAPDestinationEpochRefusal`; `IMAPEpochEvidenceMissing`; `DrainContext.failedAccounts`;
`evidenceRefused`; lane-local; account poisoning; wedge corollary; `mailboxConfirmedAbsent`;
`IMAPActionMailboxAbsent`; LIST omission is not absence; RFC 4314 §4; RFC 9051 §6.3.9;
RFC 3501 §6.4.7; `[TRYCREATE]`; `everAttempted`; `PendingStatus.cancelled`; no cancellation path;
pending-actions surface; Retry/Cancel; owner decision pending; ADR-IOS-073;
`FakeIMAPServer.hideMailboxFromList`;
`NeverDropExitClosureTests.aRefusedAtomicMoveIntoAListOmittedDestinationStaysQueuedAndLands`;
`NeverDropExitClosureTests.aPermanentlyRefusedAtomicMoveParksOnlyItsOwnLane`;
`IMAPMoveWireContractTests.atomicRefusalWithoutCopyUIDIsEvidenceUnavailable`;
`AccountManagerQueueIntegrationTests.evidenceUnavailableIsNeverMessageNotFound`;
`FakeIMAPServerOracleTests.hiddenFromListMailboxStillExists`
permanent response code; leading `resp-text-code`; RFC 3501 §7.1; structural not substring;
`TRYCREATE`; `NOPERM`; `CANNOT`; `NONEXISTENT`; RFC 5530 §3; `OVERQUOTA`; `UNAVAILABLE`;
`EXPUNGEISSUED`; `SERVERBUG`; `INUSE`; `LIMIT`; `IMAPActionPermanentlyRefused`;
`IMAPProvider.leadingResponseCode(inRenderedReason:)`; `permanentMoveRefusalCodes`;
`String(describing: TaggedResponse.State)`; `ResponseText.debugDescription`; `no([CODE] text)`;
OWNER DECISION 2026-09-05; retire on a response code; queue-wide retry limit (pending, separate
change); GitHub #118; `markMailboxDeleted`;
`NeverDropExitClosureTests.aMoveRefusedIntoADeletedDestinationRetiresWithoutMutation`;
`NeverDropExitClosureTests.aMoveRefusedWithAPermanentResponseCodeRetiresWithoutMutation`;
`NeverDropExitClosureTests.aRefusalWhoseHumanTextMentionsACodeLaterStaysQueued`;
`IMAPMoveWireContractTests.leadingResponseCodeIsReadStructurally`

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

## 2026-09-05 (round 3) — two things that paragraph got wrong, and the routing that replaces it

**(a) "Halts the lane" was not what the generic catch does.** It inserts the account into
`DrainContext.failedAccounts`, which the drain consults before every operation on that account for
the rest of the drain. `ctx` is per-drain, so a server that keeps refusing `UID MOVE` — which
`ADR-IOS-073` expressly accepts as a thing servers do — reproduced that state on every drain and
starved every disjoint-lane read, flag and move the user made on the account. Preserving one
intention by denying every intention behind it is the never-drop WEDGE corollary, not a fix.

**(b) A LIST omission was being read as authority.** With the arm deleted, the refusal reached the
generic catch's `guard await self.mailboxConfirmedAbsent(destination, server: server) else { throw
error }; throw IMAPActionMailboxAbsent()`, and `IMAPActionMailboxAbsent` retires the WHOLE operation
as a provider-authoritative no-op. That guard's evidence is an exact-name `LIST` that did not return
the destination, and **that is not evidence of absence**: RFC 4314 §4 defines `l` (visibility to
LIST) and `i` (permission to COPY/MOVE into) as INDEPENDENT rights, so a mailbox may be hidden from
LIST and still be a legal MOVE target, and RFC 9051 §6.3.9 lets a server silently ignore a
syntactically valid pattern under a tagged OK. So a zero-mutation refusal could still empty the
queue — the same drop, through a different door. The pinning test of that round,
`NeverDropExitClosureTests.aRefusedAtomicMoveIntoAListConfirmedAbsentDestinationRetiresAsANoOp`,
BLESSED the premise, because its fixture (`markMailboxDeleted`) made "gone" and "omitted from LIST"
the same state and could not tell them apart.

**The routing that replaces it.** One typed arm in `IMAPProvider.move`'s atomic route, placed BEFORE
the generic catch, translates `IMAPError.moveFailedAfterPossiblePartialCompletion` into the private
`IMAPAtomicMoveRefused` (a `ProviderEvidenceUnavailable`, carrying the server's reason text for
diagnostics). Consequences, both of them intended:

- the error never reaches the LIST probe, so no LIST result can retire an atomic-route MOVE;
- it reaches the drain's lane-local evidence-unavailable arm, so the refusal parks its own lane and
  leaves the account alone.

The generic catch itself, `mailboxConfirmedAbsent`, `IMAPActionMailboxAbsent`, the action-SELECT
LIST probe and the COPY-route destination-SELECT probe are pre-existing and are NOT changed by this
round; the same LIST-omission argument applies to them and is recorded for the owner separately.
`executeSingleOp`, `failedAccounts`, `.haltLane` and `reconcilePendingOperations` are untouched.

## 2026-09-05 (round 3) — ⚠ THE RECOVERY CLAIM IN THE BASE RECORD IS FALSE, AND IS WITHDRAWN

The base record's "WHY CLOSED AS A DECISION" reads: *"Capability/configuration correction makes the
refusal recoverable, and existing operation cancellation remains the user-owned exit."* The second
half describes a path that **does not exist**, and has not existed for as long as the row has:

- Undo annihilation of a queued operation requires `!everAttempted`, and the claim transaction sets
  `everAttempted = true` before any provider I/O — so from the FIRST attempt onward the operation
  can no longer be annihilated by an inverse gesture.
- `PendingStatus.cancelled` has **no production writer**. Nothing in the app ever sets it.
- No view queries or lists `PendingOperation` rows, so there is no surface on which a user could see
  a parked operation, let alone cancel or retry it.

**What is therefore true.** A permanently refused `UID MOVE` **parks its lane**: the operation is
never dropped and never applied, it retries on every drain, and its same-lane successors are held
behind it. That is exactly the `ADR-IOS-073` disposition ("a server that advertises but permanently
rejects MOVE can park the lane until its configuration is corrected"), and the only recovery that
genuinely exists today is the server-side one: the configuration or ACL that causes the refusal is
corrected, and the next drain lands the move.

**This is PRE-EXISTING and is not widened by #115.** Every version of this code from `ADR-IOS-073`
onward parks the lane on a permanent refusal; the 2026-08-13 arm (`3f6a0a5a8`) briefly replaced the
park with a silent DROP, which is strictly worse, and #115 restores the park. Round 3 narrows the
blast radius further, from the whole account to the one lane. Nothing in #115 makes a refused MOVE
harder to recover than it was before that arm landed.

**OWNER DECISIONS PENDING (no issue number yet — do not invent one).** Two, both deliberately not
taken here because both are product-behaviour calls:

1. **A user-visible pending-actions surface with Retry/Cancel.** It is the only thing that would make
   a client-side recovery exist. It needs a durable terminal decision the user owns, and — because
   the remote outcome of an attempted MOVE is unknown — a cancellation would have to force
   source-and-destination reconciliation rather than simply deleting the row.
2. **Retiring a MOVE into a genuinely deleted destination on the RFC 3501 §6.4.7 `[TRYCREATE]`
   response code.** A conforming server answers `NO [TRYCREATE]` when the target mailbox does not
   exist, which IS a positive statement about the destination — unlike a LIST omission. Adopting it
   would convert this particular park back into a terminal no-op on evidence rather than on absence.
   Not taken here: it is a new classification input on server-supplied text, and which behaviour the
   product wants for "the user's archive target was deleted under them" is the owner's call.

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

## 2026-09-05 (round 3) — tests

- NEW seam `FakeIMAPServer.hideMailboxFromList(_:)` — LIST omits the name while SELECT, `UID MOVE`
  and STATUS behave normally. A second seam rather than a flag on `markMailboxDeleted`, which
  conflates "deleted" with "omitted from LIST" and so cannot express this world state at all.
  `markMailboxDeleted` is kept unchanged; other suites depend on it. Its own wire contract is pinned
  by `FakeIMAPServerOracleTests.hiddenFromListMailboxStillExists` (LIST omits the name under a
  tagged OK; SELECT and `UID MOVE` succeed; an unhidden mailbox is still listed by the same handler).
- FLIPPED `NeverDropExitClosureTests.aRefusedAtomicMoveIntoAListConfirmedAbsentDestinationRetiresAsANoOp`
  → `aRefusedAtomicMoveIntoAListOmittedDestinationStaysQueuedAndLands(refusal:)`. The old test
  BLESSED the LIST-omission premise. The new one hides the destination from LIST while leaving it
  fully functional, refuses the first `UID MOVE` once over the same three response texts as the
  round-2 matrix (`[NONEXISTENT]` included), and asserts: after drain 1 the op is still queued with
  `retryCount == 1`, the source untouched and no COPY/`\Deleted` STORE/EXPUNGE; after drain 2 the
  message is in the destination exactly once, the source is empty, the queue is empty and the wire
  oracle reports no wrong-message mutation. RED on `977958c37` — the first drain retires the op.
- NEW `NeverDropExitClosureTests.aPermanentlyRefusedAtomicMoveParksOnlyItsOwnLane` — the
  repeated-refusal bystander invariant, modelled on `unprovableOpDoesNotWedgeTheAccountsOtherGestures`.
  Every `UID MOVE` is refused, on every drain, for four drains; one MOVE plus a same-lane successor
  on message A, FIVE disjoint-lane gestures on message B. The bystander half is asserted after the
  FIRST drain, and the lane is five gestures long, and both of those are load-bearing:
  `DrainContext.failedAccounts` is per-drain and is re-evaluated before every op of a lane, so a
  poisoned account lets whichever gestures are already past that check slip through, requeues the
  rest, and then releases roughly one more per drain — measured only at the end of four drains, a
  poisoned account and a healthy one reach the SAME state, and the test would have passed on the
  parent. Asserts B's five gestures all retired within drain 1 with their effects on the SERVER,
  then A's MOVE still queued with `retryCount >= 3`, its successor still held, and the queue holding
  exactly the two A rows. RED on `977958c37`: `(unrelated → []).contains("\\Seen")` and the same for
  `\Flagged` / `\Answered`, with five rows still queued where the property allows two.
- NEW `IMAPMoveWireContractTests.atomicRefusalWithoutCopyUIDIsEvidenceUnavailable` — the provider
  contract: a tagged NO with no `COPYUID` leaves `IMAPProvider.move` as an error that
  `is ProviderEvidenceUnavailable` and is NOT an `IMAPError`, with zero wire mutation. RED on
  `977958c37` — the raw `IMAPError` escapes.
- REWRITTEN `AccountManagerQueueIntegrationTests.typedNoCopyUIDMoveRefusalIsNeverMessageNotFound` →
  `evidenceUnavailableIsNeverMessageNotFound`, driving a locally declared
  `ProviderEvidenceUnavailable` conformer whose description carries both `NONEXISTENT` and
  `UID not found`. The guarantee under test is the PROTOCOL exemption, not one named error case, so
  a future conformer is covered too. The positive legs (`ProviderError.messageNotFound`, the 404
  shapes, the plain-text fallback) are unchanged, which is what keeps the exemption narrow.
- RE-EXAMINED and LEFT UNCHANGED: `IMAPMoveWireContractTests.absentDestinationIsATerminalNoOp` pins
  the OWNED COPY route (it builds its fake with `ownedCapabilities`, i.e. `MOVE` stripped), so it is
  the pre-mutation destination-SELECT property and not the atomic route;
  `UidValidityTurnoverDeletionGuardTests.deleteRecreateLifecycleStillLosesOrphanedMail`'s
  `markMailboxDeleted("Archive", …)` pins the folder-row delete/re-create turnover through full
  sync, not a MOVE disposition.
- KEPT `NeverDropExitClosureTests.aRefusedAtomicMoveStaysQueuedAndTheNextDrainLandsIt(refusal:)`
  (now the destination-PRESENT side of the pair) and
  `aTransportLossMidAtomicMoveLeavesTheOpQueuedAndALaterDrainLandsIt` (the transport-kill witness,
  which is a genuine connection fact and still uses the generic arm).

## 2026-09-05 (round 3b) — the decision taken, the shape of the parser, and the tests

**What changed in the code.** One `private static func
IMAPProvider.leadingResponseCode(inRenderedReason:)` plus a four-member
`permanentMoveRefusalCodes` set, and one `if` inside the round-3 typed arm. The extractor is
anchored on the ONE rendering contract this path depends on and nothing else: SwiftMail's
`MoveHandler.handleTaggedErrorResponse` builds its payload as
`String(describing: response.state)`, and `TaggedResponse.State`'s associated value is a
`ResponseText` whose `debugDescription` writes the WIRE form `[CODE] text` — so the reason arrives as
`no([TRYCREATE] UID MOVE destination does not exist)` / `bad([CANNOT] …)`. The extractor strips that
single enum wrapper and reads the bracketed atom only when it is the FIRST thing in the remainder.
It does no substring search over the human text, which is the whole safety argument: a response code
is a protocol statement only in the leading position (RFC 3501 §7.1).

**What is deliberately NOT changed.** `executeSingleOp`, `isMessageNotFoundError`, `failedAccounts`,
`mailboxConfirmedAbsent`, `IMAPActionMailboxAbsent` and its LIST-probe producers, the action-SELECT
LIST probe, the COPY-route destination probe, `FakeIMAPServer`'s production behaviour and SwiftMail
are all untouched. The refusal still never reaches the LIST probe.

**Tests.**

- NEW `NeverDropExitClosureTests.aMoveRefusedIntoADeletedDestinationRetiresWithoutMutation` — the
  conforming-server case the owner decided: `markMailboxDeleted("Archive", …)` makes the fake answer
  `NO [TRYCREATE] UID MOVE destination does not exist`, and after ONE drain the queue is EMPTY, the
  message is still in the source mailbox on the server, and no `UID COPY`, `\Deleted` STORE or
  EXPUNGE was issued. RED on `f9dcd71ec`, where the op stays queued.
- NEW `NeverDropExitClosureTests.aMoveRefusedWithAPermanentResponseCodeRetiresWithoutMutation`,
  parameterised over `[NOPERM] Permission denied`, `[CANNOT] Policy forbids this move` and
  `[NONEXISTENT] No such mailbox` — the same end state for the codes a server sends without deleting
  anything. RED on `f9dcd71ec`.
- NEW `NeverDropExitClosureTests.aRefusalWhoseHumanTextMentionsACodeLaterStaysQueued` — `NO Move
  refused, see [TRYCREATE] semantics` carries NO leading code, so it keeps the round-3 park: still
  queued after the refused drain, and the next drain lands it.
- NEW `IMAPMoveWireContractTests.leadingResponseCodeIsReadStructurally` — the extractor over the
  exact rendered shapes (`no([TRYCREATE] x)` → `TRYCREATE`, `bad([CANNOT] x)` → `CANNOT`,
  `no(x [TRYCREATE])` → nil, `no(No mailbox selected)` → nil). This and the test above are the
  fragile-contract pins for the `String(describing:)` rendering.
- CHANGED the round-3 refusal matrices: `[NONEXISTENT] No mailbox selected` moves out of
  `aRefusedAtomicMoveStaysQueuedAndTheNextDrainLandsIt` and
  `aRefusedAtomicMoveIntoAListOmittedDestinationStaysQueuedAndLands` — a structured `[NONEXISTENT]`
  now RETIRES by owner decision, so that row belongs to the new permanent-code test — and is
  replaced by the transient `[UNAVAILABLE] Backend temporarily unavailable`. The no-code rows are
  kept, and the round-3 property (stays queued, next drain lands it) is unchanged and still red on
  `977958c37` in spirit; that is not re-proved here.
- UNCHANGED: the round-3 classifier test
  (`AccountManagerQueueIntegrationTests.evidenceUnavailableIsNeverMessageNotFound`) — a permanent
  refusal is retired inside the provider and never reaches the classifier at all — and
  `aPermanentlyRefusedAtomicMoveParksOnlyItsOwnLane`, whose refusal text
  (`Move rejected by server policy`) carries no response code and therefore still parks.

## 2026-09-04 — relationship to IOS-IMAP-012

The 2026-08-13 head amendment on `ios-imap-012.md` described the same arm as "the same no-retry
safety class as an atomic success with missing evidence". That claim is half-withdrawn by
`Amendments/ios-imap-012.md`: the `COPYUID`-bearing half stands, the possible-partial half does not.

## 2026-09-05 (round 4) — the recognizer required the CLOSING bracket only after review

Round 3b's `IMAPProvider.leadingResponseCode(inRenderedReason:)` read the atom after `[` with
`prefix { $0 != "]" && $0 != " " }` and returned it **without checking that a `]` closed it**. RFC
3501 §7.1 writes the code as `"[" resp-text-code "]"`, so the closing bracket is part of the
grammar. The round-3 robustness reviewer reproduced five false terminal classifications against the
real NIOIMAP parser — `[TRYCREATE temporary diagnostic`, `[CANNOT temporary failure`, `[NOPERM
extra] Temporary failure`, `[NONEXISTENT UID not found`, `[TRYCREATE` — for every one of which
`parseResponseText` accepts the input as plain text with `ResponseText.code == nil`, i.e. the server
stated NO response code at all. The extractor nevertheless yielded the leading word, the refusal was
classified `IMAPActionPermanentlyRefused`, and a refusal that is retryable by the owner's own D9
decision RETIRED the user's move with the message still at its source — the `MIS-IOS-004` shape one
more time, through the newest door. The controls behaved correctly throughout (`[TRYCREATE]` →
retire, `[UNAVAILABLE]` → stays queued, a code later in prose → ignored).

**The fix DELETES the extractor's acceptance of incomplete tokens** — one guard requiring the
character immediately after the atom to be `]`, nothing else changed: not
`permanentMoveRefusalCodes`, not `IMAPActionPermanentlyRefused`, not `IMAPAtomicMoveRefused`, not
`executeSingleOp`, not `isMessageNotFoundError`, not `FakeIMAPServer`, not SwiftMail. The invariant
it pins: a tagged MOVE refusal retires ONLY when its resp-text begins with a COMPLETE `[ATOM]` whose
atom is in the permanent set; anything else keeps the round-3 lane-local park.

**Tests.** `IMAPMoveWireContractTests.leadingResponseCodeIsReadStructurally` gains the five rows
above, all expecting `nil`; `NeverDropExitClosureTests.aRefusedAtomicMoveStaysQueuedAndTheNextDrainLandsIt`
gains `[TRYCREATE temporary diagnostic` — an unclosed bracket whose atom IS in the permanent set —
and asserts the round-3 property end to end (still queued after the refused drain, landed by the
next). All six were RED on the pre-fix extractor (it returned `TRYCREATE` / `CANNOT` / `NOPERM` /
`NONEXISTENT` / `TRYCREATE` where `nil` was required, and the queue row's op was retired on the
refused drain) and every pre-existing row stayed green.

**Two comment-only accuracy amendments** landed in the same commit, with no runtime change:
`ExecutedOperation.reconcileMoveSource`'s "the op stays queued and is retried" is now qualified to
refusals WITHOUT a permanent code, and `DrainContext.evidenceRefused`'s conformer census reads FOUR
rather than THREE (`IMAPAtomicMoveRefused` added by round 3; re-derived at the tip —
`rg -n ': ProviderEvidenceUnavailable' TabMail/` returns exactly four).
