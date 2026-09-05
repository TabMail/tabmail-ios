<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note (2026-09-04, GitHub #115): the first and third bullets below are HALF
> wrong and are corrected here; the body is preserved unedited.** Only
> `.moveFailedAfterPartialCompletion(copyUID:reason:)` is non-retryable — it carries positive
> `COPYUID` evidence, and TabMail still retires on it and reconciles both folders.
> `.moveFailedAfterPossiblePartialCompletion` is raised for ANY tagged NO/BAD with no retained
> `COPYUID`, including a refusal answered before any mutation (a transport loss between the pre-move
> `SELECT` and the `UID MOVE` makes `IMAPConnection.executeCommandBody` re-open a raw channel with no
> LOGIN/SELECT, and the server answers `NO No mailbox selected`). Treating it as non-retryable dropped
> the user's move (`3f6a0a5a8`; `MIS-IOS-004` recurrence). #115 deletes that arm: the error is a
> typed, retryable failure (`IOS-IMAP-013`), the op stays queued, and the next drain reissues
> `UID MOVE` — safe because RFC 3501 §6.4.8 ignores absent UIDs and §2.3.1.1 forbids UID reuse within
> an epoch; the residual duplicate on a server that violates RFC 6851 §3.3 is accepted under
> `IOS-IMAP-006` / `IOS-QUEUE-007`.
<!-- COMPANION-CURRENT-NOTE-END -->
# SwiftMail MOVE post-completion contract — PR #208

- `IMAPError.moveFailedAfterPossiblePartialCompletion` and
  `.moveFailedAfterPartialCompletion(copyUID:reason:)` are **non-retryable**: mailbox state may
  already have changed before tagged NO/BAD.
- The verified form's `CopyUID` is attempt-correlated destination evidence and should be preserved.
- TabMail retires the original source identifiers for both forms and reconciles both source and
  destination folders. Reissuing UID MOVE can duplicate mail or address a later source-UID occupant.
- `IMAPError.moveFallbackFailedAfterCopy` is not reachable from TabMail's atomic route because it
  always calls `move(..., fallback: .disabled)`; do not conflate it with the two cases above if that
  routing changes.
- Collision proof for the 2026-08-13 fork sync: pinned integration tree `7aee922` is byte-identical
  to merged PR #208 at `e77744c`. Upstream `f8469b1` adds ordered repeated selective-header fields
  while retaining the legacy last-value-wins dictionary; TabMail does not consume the new property.
- Sync completed 2026-08-13: `TabMail/SwiftMail` `main`, local `origin/main`, and `upstream/main` all
  resolve to `f8469b14f7620ef7b1105eccbfa19271448819d5`; `project.yml` pins that exact revision.
  SwiftMail verification: build passed, 479 tests / 62 suites passed, strict lint 0 violations / 293
  files. iOS app + embedded NSE build passed with the two sanctioned AppIntents warnings, followed by
  120 re-pinned integration tests / 7 suites.
- Duplicate linked worktrees `tabmail-ios-SwiftMailFocused` and
  `tabmail-ios-SwiftMailReleaseTests` were clean and removed. Their branch refs remain; safety branch
  `tabmail/pre-sync-20260813` retains integration commit `7aee922`.
