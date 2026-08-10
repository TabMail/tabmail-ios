# IOS-IMAP-013

> Routed from `KNOWN_ISSUES.md` line 1434 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `60cd3f6833b955121a3820289b563b1856513fd7eda3c23c0e91ca5e1c2bef7c`

## Status

✅ **CLOSED AS A DECISION (2026-08-08)** — a server that advertises `MOVE` but permanently rejects `UID MOVE` can keep the durable operation retryable and park its account lane; TabMail does not fall back after the atomic attempt

## Subsystem and search terms

IMAP; RFC 6851; MOVE capability; tagged NO; tagged BAD; `IMAPError.moveFailed`; retry; lane park; no fallback

## Full detail

**THE MECHANISM.** The app snapshots advertised `MOVE` and calls the atomic-only entry point. A tagged NO/BAD remains a typed failure; the durable operation stays queued and the account lane can halt again on later drains if the server keeps advertising a command it rejects. The source is not assumed unchanged because a MOVE failure may be partial, so the same attempt never falls through to COPY/STORE/EXPUNGE.

**WHY CLOSED AS A DECISION.** Capability/configuration correction makes the refusal recoverable, and existing operation cancellation remains the user-owned exit. Automatic fallback would trade a visible wedge on a lying server for duplicate or wrong-message mutation after an ambiguous partial command.

**WHAT WOULD RE-OPEN THIS ROW:** provider evidence that a rejected command was guaranteed pre-mutation, or a capability refresh contract strong enough to prove that guarantee for the exact connection and command.
