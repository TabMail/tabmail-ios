# IOS-DRAFT-013

> Routed from `KNOWN_ISSUES.md` line 1014 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `not-defect`
- Original row SHA-256: `06b1b348ff74a1d499d03a13c5890873d4305126adf39b53b0e679301813deca`

## Status

✅ **NOT A DEFECT (2026-08-05)** — raised at **P0** by the external reviewer in round 3 (`A2-01`) as a **verbatim repeat** of round 2's `F3`, which had already been adjudicated and refused; it was re-filed only because nothing in the tree recorded the refusal

## Subsystem and search terms

IMAP drafts; `IMAPProvider.saveDraft`; `deleteDraftStrong`; `UID EXPUNGE`; `expungeScopedToTargets`; UIDVALIDITY assertion; `withActionConnectionSelection`; `selectMailboxTracked`; mailbox generation; RFC 3501 §2.3.1.1; `requireUidValidity`; `fetchMessageInfosBulk`; A5 move-path assertion

## Full detail

**The claim:** `saveDraft` / `deleteDraftStrong` can issue a `UID EXPUNGE` after their last UIDVALIDITY assertion, so a turnover in that window would destroy the wrong draft. **Four independent grounds it is refused on, all re-verified against source:** (1) both draft-destruction blocks run inside `withActionConnectionSelection`, which performs exactly **one** `selectMailboxTracked` before `body`, and the call-site census shows no re-`SELECT` inside either block — there is no point at which a new mailbox generation could be observed; (2) **RFC 3501 §2.3.1.1 forbids UIDVALIDITY changing during a session** — a turnover is observable only across a `SELECT`, so within one selected session the UID→message mapping is stable by protocol; (3) pre-body and post-body `generation == acquiredGeneration` guards bracket `body`, so a reconnect throws a retryable `ProviderError.notConnected` rather than continuing on a new socket; (4) both guards fail **safe** — a withheld live epoch of `0` against a recorded `> 0` makes `requireUidValidity` false, and **the branch that is skipped is the destructive one** — and independently `fetchMessageInfosBulk` re-proves the target exists immediately before `STORE \Deleted`. **The move path's A5 assertion is not a precedent for adding one here:** it exists precisely because the move path **does** re-`SELECT` (source → destination → source). The draft paths do not. The absence is structural, not an omission.
