# IOS-IMAP-014

> Routed from `KNOWN_ISSUES.md` line 1435 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `5cf31b1753ad86e587f6b7116b3380c02e73871224fb4f29ec3fd21f3a36dbb3`

## Status

✅ **CLOSED AS A DECISION (2026-08-08)** — a syntactically valid but false same-epoch `COPYUID` can pass every client-side admission check and re-key to the wrong destination UID; no heuristic recovery is added

## Subsystem and search terms

IMAP; atomic UID MOVE; false COPYUID; UIDVALIDITY; same epoch; provider evidence integrity; C3; `copyProvenDestinations`; Message-ID search

## Full detail

**THE MECHANISM.** The client can verify positivity, requested-source membership, cardinality/order pairing, and positive destination-epoch agreement. It cannot prove that a server-provided destination UID actually names the moved message when the server returns a false but well-formed mapping under the same UIDVALIDITY. Such evidence passes the strict admission matrix and can re-key local state and mirrors to the wrong server slot.

**WHY CLOSED AS A DECISION.** The protocol response is the only provider-native result evidence available. A Message-ID search is neither unique nor immutable and would recreate the forbidden hybrid mutation authority; replaying the MOVE cannot validate the first result. This is an external evidence-integrity residual, not permission to weaken C3 elsewhere.

**RECOVERABILITY / NEGATIVE CASE.** There is no guaranteed automatic recovery once false evidence is accepted; a later authoritative sync may expose a collision or replace local presentation, but that is not a proof. Re-open only if the provider supplies an independent immutable identity witness or the fork can cryptographically/transactionally bind the response to the moved member.
