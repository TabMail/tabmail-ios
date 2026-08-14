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
