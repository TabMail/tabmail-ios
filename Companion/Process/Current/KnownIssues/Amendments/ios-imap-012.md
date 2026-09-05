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
