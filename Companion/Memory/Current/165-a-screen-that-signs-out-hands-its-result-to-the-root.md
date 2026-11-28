# 165 — A screen that signs out cannot show its own result; it hands an in-memory receipt to `RootView`

**Status:** Current (2026-11-28, ios#1676). Applies to any screen inside the signed-in navigation that ends
the TabMail session and then wants to show something.

## Why the screen's own result never appears

`TabMailAuthService.completeSession` is the sole emitter of `.tabMailDidSignOut`. `RootView`'s receiver sets
`hasTabMailSession = false`, and `RootView.routedContent` (an if/else chain) moves from its signed-in branch
`MailNavigationView()` to the email-only branch `MailNavigationView(initialSelection: nil)` or to the login
screen. A different branch is a different view identity, so the whole signed-in navigation, and every screen
pushed in it, is removed. A screen that signs out and then sets its own state to show a result is gone before
that state renders.

This hid the account deletion's "Deletion Scheduled" confirmation (the date, how to keep the account) from
v1.6.0 until ios#1676: the person saw only the generic "Signed Out" alert. The confirmation appeared only when
the local sign-out failed (a Keychain error), because then the screen stays.

## The pattern

- `AccountDeletionReceipt` (`TabMail/Services/Account/AccountDeletionReceipt.swift`) holds one receipt in
  memory (the formatted server date and whether to show Apple's manual steps, memory 164). Nothing is
  stored; a killed app shows nothing, which is fine for a notice.
- The deletion screen signs out only through `AccountDeletionReceipt.signOut(handing:signOut:)`: the receipt
  is placed with no suspension before `completeSession`, and dropped at once when it returns false (no
  notification follows a failed sign-out, so a receipt left behind would surface on some later, ordinary
  sign-out).
- `RootView`'s `.tabMailDidSignOut` receiver calls `AccountDeletionReceipt.take()` once: with a receipt it
  shows `AccountDeletionConfirmation` as a sheet in place of the "Signed Out" alert; without one it shows the
  alert unless `suppressNextSignedOutAlert` (the failed-age-check sign-out) is set. The flag is cleared either
  way.
- `AccountDeletionConfirmation` is the one confirmation view, used by the root sheet and, after a failed
  sign-out, by the deletion screen (with its error line and a Done that dismisses the screen).
- Same shape as `PendingAccountAdd` (in-memory hand-off across a routing change).
- Known limit (ios#1678, P4): the root shows one presentation at a time. If the one-time "Database update"
  cover opens while a deletion's request is still running, the sheet (like the "Signed Out" alert before it)
  may not show over it. The fix there is to show root notices one at a time, not a per-notice retry.

## Tests

`AccountDeletionReceiptTests` (the receipt is in place while the sign-out runs, taken once, dropped on a failed
sign-out) and `AccountDeletionConfirmationWiringTests` (a source check: the deletion screen's only
`completeSession` goes through the receipt and carries the server date and the manual-steps flag; the root takes the receipt in the
sign-out receiver, shows the sheet, and shows the alert only without a receipt), in
`AccountDeletionCoordinatorTests.swift`. The sheet's presentation itself is checked on a device.
