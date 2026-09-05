# IOS-IMAP-012

> **Post-freeze amendment to a BASE-register record.** Added 2026-09-04 (GitHub #115) through the
> amendment surface in `Scripts/compact_known_issues.rb`. The base record's own bytes are hash-pinned
> and are **not** edited by this file: `Companion/Process/Current/KnownIssues/ios-imap-012.md` is
> unchanged — including its own 2026-08-13 head `KNOWN-ISSUES-AMENDMENT` block, which is preserved
> unedited as the audit record of what was believed on that date. This file only **adds** the current
> disposition and records which half of that 2026-08-13 block no longer describes the code.

- Register classification: `closed-decision` — UNCHANGED. The base record's own subject — an atomic
  `UID MOVE` that SUCCEEDS without admissible `COPYUID` evidence retires the provider action and
  leaves the optimistic row unaddressed for sync — is untouched by #115. A tagged OK is a
  provider-authoritative success; retiring on it is never-drop exit 1.
- Amends: the 2026-08-13 head amendment block of `Companion/Process/Current/KnownIssues/ios-imap-012.md`
  — specifically (a) its claim that `IMAPError.moveFailedAfterPossiblePartialCompletion` and
  `moveFailedAfterPartialCompletion(copyUID:reason:)` are BOTH "the same no-retry safety class as an
  atomic success with missing evidence"; (b) its statement that `IMAPProvider.move` "retires the
  original source identifiers on both typed outcomes"; and (c) its description of the pinning tests
  as asserting "one UID MOVE on the wire" for the possible-partial form.

## Status

✅ **CLOSED AS A DECISION — the 2026-08-13 amendment is HALF-WITHDRAWN (2026-09-04, GitHub #115).**
The `COPYUID`-bearing half stands: `moveFailedAfterPartialCompletion(copyUID:)` still retires the
source members, admits the destination addresses the server reported, and marks the outcome for
source reconciliation; `NeverDropExitClosureTests.aVerifiedPartialAtomicMoveIsNeverReissued` still
pins it. The possible-partial half is withdrawn: `moveFailedAfterPossiblePartialCompletion` is a
tagged NO/BAD with NO retained `COPYUID` — the server refused the command and reported nothing about
what it did — and is a retryable failure under `IOS-IMAP-013`'s disposition, not a no-retry outcome.
Round 2 (2026-09-04): the queue classifier `AccountManager.isMessageNotFoundError` structurally
exempts the refusal from its message-not-found text fallback — the refusal carries the server's raw
tagged response text as a diagnostic payload, so one quoting an RFC 5530 `[NONEXISTENT]` code or the
words `UID not found` would otherwise have been retired as provider-authoritative "already gone" —
so no response text can retire it.
Round 3 (2026-09-05): `IMAPProvider.move`'s atomic route catches the typed error in an arm of its
own and rethrows it as a private `ProviderEvidenceUnavailable` conformer (`IMAPAtomicMoveRefused`),
so it reaches the drain's LANE-LOCAL evidence-unavailable arm — requeue, `retryCount += 1`,
`evidenceRefused`, `.haltLane`, account untouched — instead of the generic catch, which would insert
the account into `failedAccounts` and suppress every disjoint lane on it. The round-2 classifier
exemption is restated on the PROTOCOL rather than on one transport library's enum. The refusal
consequently never reaches the generic catch's exact-name `LIST` probe either, which matters here:
that probe cannot prove absence (RFC 4314 §4 separates the `l` and `i` rights; RFC 9051 §6.3.9
permits silent pattern omission), so routing the refusal past it is what stops a LIST omission from
retiring the operation. Full argument in `Amendments/ios-imap-013.md`.

Round 3b (2026-09-05) — **OWNER DECISION**: a refusal whose resp-text BEGINS with a response code
from the permanent set — `TRYCREATE` (RFC 3501 §6.4.7, carried to MOVE by RFC 6851 §3.3), `NOPERM`,
`CANNOT`, `NONEXISTENT` (RFC 5530 §3) — **retires the operation**. That is provider AUTHORITY that
the command can never succeed as issued, so it is never-drop exit 2, not the absence of evidence a
LIST omission is: nothing was copied, the message is untouched in the SOURCE mailbox on the server,
and the next sync of the source folder reclaims the local row. `IMAPProvider.move` throws the
private `IMAPActionPermanentlyRefused` and its own outer `catch` returns
`MoveOutcome(provenIds: ids, provenDestinations: [])`, the same terminal shape the pre-existing
`IMAPActionMailboxAbsent` arm returns — that type is NOT widened, because "the mailbox is confirmed
gone" has two other catch sites in the file. Every OTHER refusal keeps the round-3 disposition
(evidence-unavailable, lane-local requeue, retried on the next drain): no code at all, or a code
outside the permanent set (`OVERQUOTA`, `UNAVAILABLE`, `EXPUNGEISSUED`, `SERVERBUG`, `INUSE`,
`LIMIT`, …), all of which describe conditions that can clear.

## Subsystem and search terms

IMAP; atomic `UID MOVE`; `COPYUID`; tagged NO; tagged BAD; `No mailbox selected`;
`IMAPError.moveFailedAfterPossiblePartialCompletion`; `moveFailedAfterPartialCompletion(copyUID:)`;
`IMAPProvider.move`; `MoveOutcome`; `provenIds`; `provenDestinations`; `requiresSourceReconciliation`;
evidence class; positive evidence vs absence of evidence; never-drop exit 1; never-drop exit 2;
MIS-IOS-004; SwiftMail PR #208; `MoveHandler.handleTaggedErrorResponse`; `3f6a0a5a8`; GitHub #115;
`NeverDropExitClosureTests.aVerifiedPartialAtomicMoveIsNeverReissued`;
`NeverDropExitClosureTests.aPossiblyPartialAtomicMoveConvergesToExactlyOneDestinationCopy`;
`IMAPMoveWireContractTests.atomicPossiblePartialCompletionIsRetriedToExactlyOneCopy`;
`FakeIMAPServer.failUIDMoveAfterPossiblePartialCompletion`;
`FakeIMAPServer.failUIDMoveAfterVerifiedPartialCompletion`; IOS-IMAP-013;
`ProviderEvidenceUnavailable`; `IMAPAtomicMoveRefused`; `failedAccounts`; `evidenceRefused`;
`haltLane`; lane-local; account poisoning; `mailboxConfirmedAbsent`; LIST omission is not absence;
RFC 4314 §4; RFC 9051 §6.3.9; `FakeIMAPServer.hideMailboxFromList`;
`NeverDropExitClosureTests.aRefusedAtomicMoveIntoAListOmittedDestinationStaysQueuedAndLands`;
`NeverDropExitClosureTests.aPermanentlyRefusedAtomicMoveParksOnlyItsOwnLane`;
`IMAPMoveWireContractTests.atomicRefusalWithoutCopyUIDIsEvidenceUnavailable`
permanent response code; RFC 3501 §7.1 `resp-text`; leading `resp-text-code`; structural not
substring; `TRYCREATE`; `NOPERM`; `CANNOT`; `NONEXISTENT`; RFC 5530 §3; RFC 6851 §3.3;
`OVERQUOTA`; `UNAVAILABLE`; `EXPUNGEISSUED`; `SERVERBUG`; `INUSE`; `LIMIT`;
`IMAPActionPermanentlyRefused`; `IMAPProvider.leadingResponseCode(inRenderedReason:)`;
`permanentMoveRefusalCodes`; `String(describing: TaggedResponse.State)`;
`ResponseText.debugDescription`; `no([CODE] text)`; OWNER DECISION 2026-09-05; retire on a response
code; queue-wide retry limit (pending, separate change); GitHub #118;
`NeverDropExitClosureTests.aMoveRefusedIntoADeletedDestinationRetiresWithoutMutation`;
`NeverDropExitClosureTests.aMoveRefusedWithAPermanentResponseCodeRetiresWithoutMutation`;
`NeverDropExitClosureTests.aRefusalWhoseHumanTextMentionsACodeLaterStaysQueued`;
`IMAPMoveWireContractTests.leadingResponseCodeIsReadStructurally`

## 2026-09-04 — what stands from the 2026-08-13 amendment

Everything about the VERIFIED form. When the server answers a tagged NO/BAD but SwiftMail retained a
`COPYUID` from an untagged OK, the server has positively reported that the destination copy exists at
a known address. Retiring the named source members on that evidence, admitting the reported
destination addresses so `MessageHeaderRekey.finishMove` can re-key the rows, and scheduling both
folder syncs is evidence-backed and unchanged. Its pinning test and its `FakeIMAPServer` fixture
(`failUIDMoveAfterVerifiedPartialCompletion`) are unchanged by #115.

## 2026-09-04 — what is withdrawn, and why

The claim that the possible-partial form is "the same no-retry safety class as an atomic success with
missing evidence" conflated two evidence classes. An atomic SUCCESS with missing `COPYUID` (the base
record's own subject) is still a tagged OK: the server has authoritatively said the move happened,
and only the destination ADDRESS is unknown. A tagged NO/BAD with no `COPYUID` is the server saying
the command was refused, with no statement about mutation at all. SwiftMail raises
`moveFailedAfterPossiblePartialCompletion` for EVERY such refusal — including a `NO No mailbox
selected` on a raw re-established channel, where nothing was mutated. Treating "may have partially
completed" as authoritative completion is `MIS-IOS-004` (recurrence recorded 2026-09-04): "we could
not determine the answer" is retryable, never exit 2. #115 traced the consequence with the fuzzer —
the queue emptied and the user's archive was dropped while the message stayed in INBOX.

Retrying the refused command is safe (RFC 3501 §6.4.8 ignores an absent UID; §2.3.1.1 forbids UID
reuse inside the epoch the drain checks; RFC 6851 §3.3's worst case is a duplicate, the residual
already accepted under `IOS-IMAP-006` / `IOS-QUEUE-007`). The full argument is in
`Amendments/ios-imap-013.md`; it is not repeated here.

## 2026-09-05 (round 3) — the recovery claim both rows leaned on is false

`IOS-IMAP-013`'s base record says a permanent refusal is recoverable by "capability/configuration
correction" AND by "existing operation cancellation". The second half does not exist: Undo
annihilation requires `!everAttempted` and the claim transaction sets `everAttempted = true` before
any provider I/O, `PendingStatus.cancelled` has no production writer, and no view lists
`PendingOperation` rows. What actually happens to a permanently refused MOVE is that it **parks its
lane** — never dropped, never applied, retried every drain, same-lane successors held — which is the
`ADR-IOS-073` disposition and is PRE-EXISTING, not widened by #115. A user-visible Retry/Cancel
surface and the `[TRYCREATE]`-based retirement of a MOVE into a genuinely deleted destination are
OWNER DECISIONS pending (no issue number yet); neither is built here. Stated once, in full, in
`Amendments/ios-imap-013.md`; it is not repeated here.

## 2026-09-05 (round 3b) — the `[TRYCREATE]` owner decision is TAKEN, and what still parks

The sentence in the round-3 section above — *"the `[TRYCREATE]`-based retirement of a MOVE into a
genuinely deleted destination [is an] OWNER DECISION[] pending"* — is **resolved**. The owner decided
it on 2026-09-05: *"if server has deleted folder, we should retire that op"*, *"if server says op is
broken, we should retire it. and then later on full sync would catch that back"*. The code reads the
response code STRUCTURALLY — RFC 3501 §7.1 gives `resp-text = ["[" resp-text-code "]" SP] text`, so
only the bracketed atom at the very START of the resp-text is a protocol statement and the same word
later in the server's prose is not — which is what keeps a server's human sentence from retiring a
user's intention.

**Nothing else is withdrawn.** The recovery-claim withdrawal above stands in full: there is still no
client-side cancellation path, and `PendingStatus.cancelled` still has no production writer. The
other pending owner decision — a user-visible pending-actions surface with Retry/Cancel — is
untaken.

**What still parks its lane, and the one follow-up that is pending rather than silent.** A refusal
with NO response code (a non-conforming server — GitHub #118, wontfix) or with a code outside the
permanent set stays queued and retries on every drain, exactly as round 3 left it. The owner has
directed a **queue-wide retry limit** for that residual; it is a SEPARATE change and is deliberately
not taken here, so the park is bounded by that future change and not by this row.

## 2026-09-04 — the tests the 2026-08-13 amendment cited

`IMAPMoveWireContractTests.atomicPossiblePartialCompletionIsNotRetryable` and
`NeverDropExitClosureTests.aPossiblyPartialAtomicMoveIsNeverReissued` asserted the defect (one `UID
MOVE` on the wire, empty operation row). They are flipped to
`atomicPossiblePartialCompletionIsRetriedToExactlyOneCopy` and
`aPossiblyPartialAtomicMoveConvergesToExactlyOneDestinationCopy`, which assert the end state —
exactly one destination copy, an empty source, an empty queue, no `UID COPY`, no `\Deleted` store,
no expunge, no wrong-message mutation — and never a MOVE count. `FakeIMAPServer.moveFailureAfterCommit`
is one-shot so the retry is served normally. The verified-form test named in the 2026-08-13 block is
unchanged.

## 2026-09-05 (round 4b) — two witnesses the round-3 test-coverage review found missing

`NeverDropExitClosureTests.aPermanentlyRefusedAtomicMoveParksOnlyItsOwnLane` now asserts the
per-drain attempt bound EXACTLY rather than as a lower bound — one `UID MOVE` on the wire, one
consumed refusal and `retryCount == 1` after the first drain, and one consumed refusal and one
retry per drain across the four — because the productive bystander lane keeps the outer drain loop
looping, so only `DrainContext.evidenceRefused` stops a second attempt in the same pass and a `>=`
form could not reject one. The new
`NeverDropExitClosureTests.aPartiallyCompletedAtomicMoveKeepsEveryMemberAndConvergesOnRetry`
is the suite's first genuinely PARTIAL batch (RFC 6851 §3.3): the one-shot
`FakeIMAPServer.failUIDMoveAfterPossiblePartialCompletion(committingOnlyFirst:)` seam commits only
the first requested member before the uncoded `NO`, and the test pins that the requeued operation
keeps BOTH members, its source, destination and epoch, and that the next drain converges each member
to exactly one destination copy with no `UID COPY`, no `\Deleted` store and no expunge.
