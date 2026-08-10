# IOS-IMAP-012

> Routed from `KNOWN_ISSUES.md` line 1433 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `53c5d3dfa0fb042bba9c9b2f0b76570535d9030d2b350c7fe828d16726e8598a`

## Status

✅ **CLOSED AS A DECISION (2026-08-08)** — atomic success without admissible destination evidence retires the provider action but leaves the optimistic row unaddressed for sync; no identity-recovery mechanism is added

## Subsystem and search terms

IMAP; atomic UID MOVE; COPYUID; untagged OK; malformed COPYUID; `copyProvenDestinations`; `MessageHeaderRekey`; `BodyAddressGate`; undo

## Full detail

**THE MECHANISM.** `moveAtomically` may succeed with no `COPYUID`, with malformed/cardinality-refused `COPYUID`, or with evidence reported only in an untagged OK that the current SwiftMail handler does not retain. `IMAPProvider.move` still marks every requested source member proven because the atomic command succeeded, but admits no destination mapping. Local finish retires the durable operation, keeps an exact surviving optimistic row at its old primary key, removes stale undo authority, and leaves new IMAP body/attachment fetches fail-closed at `BodyAddressGate`.

**WHY CLOSED AS A DECISION.** Replaying a successful MOVE can duplicate mail; guessing a destination UID or searching by Message-ID can bind a different message. The unaddressed row is recoverable through ordinary destination-folder sync, which materializes the server's real address; the cost is temporary stale presentation and no undo for that member.

**KNOWN UPSTREAM CANDIDATE, NOT YET SHIPPED (verified 2026-08-09).** SwiftMail PR #208, remote branch `agent/atomic-uid-move` at `6ac6b84f93593d331b284f7a97402de83c76a279`, retains the first valid untagged-OK `COPYUID` and reports malformed/conflicting present evidence only after tagged OK. The released app still resolves SwiftMail `main` at `4a409fe8a45a29ea54492d7146b60543acaeb7fe`, which does not contain that PR head, so this row remains reachable and is not marked fixed.

**WHAT WOULD RE-OPEN THIS ROW:** SwiftMail retaining admissible untagged-OK `COPYUID` evidence, or a provider-native immutable result token becoming available. Either narrows the edge; neither permits heuristic identity recovery.
