# IOS-IDENTITY-002

> Routed from `KNOWN_ISSUES.md` line 1093 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `be8befb60b1647a8bbb15b92f9a7fdeed0106c2e579ce761c8374533420592d3`

## Status

✅ **CLOSED AS A DECISION (2026-08-05, round-10 F10)** — `MessageIdentity.colonSafeMessageIdComponent` percent-encodes `:` (and only `:`) so a stable id's colon-delimited grammar survives an RFC 822 Message-ID that itself contains a colon. Its doc comment said the residual was *"Registered"* while no register row existed — a dangling citation, which is the same failure class as a stale `file:line`. **This row IS that registration, and the comment now cites this id.** The residual itself: a draft header id minted before the encoder landed can carry four colons instead of three, so a component-count parse of such an id fails and every folder purge silently skips it. **RECOVERABILITY, with the non-recovering case named:** newly-minted ids are correct, so the population is closed and drains as those drafts are sent or discarded; what does NOT self-heal is a pre-existing four-colon row's participation in folder purges, which stays skipped until the row is deleted by another route

## Subsystem and search terms

identity; stable id; `MessageIdentity`; `colonSafeMessageIdComponent`; RFC 822 Message-ID; colon; percent-encoding; draft header id; folder purge

## Full detail

Registered, not mechanised. Do not add a repair migration for the closed pre-existing population without measuring it first.
