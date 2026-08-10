# IOS-IMAP-003

> Routed from `KNOWN_ISSUES.md` line 101 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `fixed`
- Original row SHA-256: `96a4993b06d0ddf7e36c7d6b3571495f79cc4bfe51ab95f70018ea96e7d61bdd`

## Status

✅ **FIXED FOR APP ROUTING (2026-08-08; fork `8da5d45a`, app `dd51c74ff`)** — `supportsMove` is load-bearing again. Original disposition, retained as history: ✅ **CLOSED AS A DECISION (2026-08-04)** — mitigated by owning the sequence; the upstream accessor is out-of-repo and is NOT a v3 dependency

## Subsystem and search terms

IMAP; MOVE; UIDPLUS; capability detection; SwiftMail; epoch assertion

## Full detail

**CURRENT CLOSURE (2026-08-08).** The prior conclusion that `supportsMove` “buys nothing” is retracted. After A1, `IMAPProvider.move` snapshots `server.supportsMove`: true selects the fork's atomic-only `moveAtomically`, while false selects the audited owned COPY/STORE/UID-EXPUNGE sequence. `UIDPLUS` controls destination `COPYUID` evidence and the owned purge tail; it is not a `UID MOVE` route prerequisite. The fork rechecks `MOVE` inside the atomic entry point and refuses before mutation when the app snapshot is stale. Both `MoveHandler` and `CopyHandler` now treat tagged OK plus absent or malformed `COPYUID` as success without evidence and preserve typed NO/BAD failures. The owner is recorded as the upstream-PR actor; this task opens no upstream PR.

**HISTORICAL RECORD (retained).** On a UIDPLUS-but-no-MOVE server, SwiftMail's `move` runs COPY → STORE `\Deleted` → scoped `UID EXPUNGE` with **no epoch check between the steps**; a UIDVALIDITY reset after the COPY makes the internal STORE mark a *different* message. `capabilities` is `internal` while `supportsUIDPlus` is `public`, so app code could not detect MOVE support at all. **Mitigated by owning the sequence:** v3 never calls `server.move` on an action path and issues its own five-assertion COPY/STORE/scoped-EXPUNGE, at the cost of losing atomic `UID MOVE`. A public `supportsMove` accessor exists locally (unpushed) and the upstream PR is the owner's to open; `supportsMove` alone is NOT a sufficient gate — a UID-addressed move requires `supportsMove && supportsUIDPlus`, or owning the sequence, which is what v3 does.

✅ **CLOSED AS A DECISION (2026-08-04) — v3 owns the sequence, so MOVE capability detection buys nothing for correctness.** The decision: no `supportsMove` gate is added, and no local capability accessor is landed in this repo. **Verified at the tip:** `supportsMove` appears **nowhere** in `TabMail/` or `Shared/` — zero hits — and the only capability read is `await server.supportsUIDPlus`, at two sites (`IMAPProvider.move`'s `serverSupportsUIDPlus`, and `expungeScopedToTargets`). `IMAPProvider.move` never calls `server.move` on an action path; it issues its own COPY → `\Deleted` STORE → scoped `UID EXPUNGE` with five epoch assertions. The mitigation this row described is in force, so the accessor would gate nothing that is not already owned. **Why a decision and not a deferral:** the row's only remaining item is an upstream PR to Cocoanetics/SwiftMail, which per `feedback_swiftmail_pr_upstream` goes upstream and is the owner's to open — it cannot be discharged in this repo at all — and `supportsMove` alone was never a sufficient gate anyway, as this row already says. **Accepted cost:** the loss of atomic `UID MOVE`, so a failure between steps leaves a duplicate rather than a clean move; that cost is tracked in full as `IOS-IMAP-006`. **Recoverability:** every partial state is copy-present / source-present — a duplicate, never a loss — and the user deletes the duplicate with one ordinary gesture. **A state in which owning the sequence produces something atomic `UID MOVE` would not, and that does not recover, was searched for: none exists.**
