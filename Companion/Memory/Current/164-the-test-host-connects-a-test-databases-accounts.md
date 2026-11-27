# The unit-test host connects a test database's accounts and drains its outbox

**Date:** 2026-11-27 · **Area:** tests, `RootView`, `AccountManager`, outbox drain · **Issues:** #1595 (the cause),
#1594 (one symptom)

## What happens

The unit tests run inside the app, so `RootView` is live while they run. Its post-paint setup is
`.task(id: navigationStore.accounts.isEmpty)`, and the sidebar store refreshes its accounts from `AppDatabase.dbPool`
(the database the current test installed) about 100 ms after a `.backgroundDataDidChange` post. So whenever a test's
post makes the account list go from empty to filled, the task runs again, against that test's database. Its only skip
is `ScreenshotMode.isActive` (the `--screenshot-mode` launch argument), which the unit-test host does not pass;
foreground polling has its own test-host skip (`ForegroundPollStart.isUnitTestHost`), this task does not. The task:

- calls `connectAccount` for each active account of the test database. `connectAccount` stores the provider and its
  `ProviderWorkQueue` before it connects and keeps them when the connect fails, so the test account stays registered
  in `AccountManager.shared` for the rest of the process, and later tests that reuse the account id run against it;
- runs `reconcilePendingOperations`, whose `reconcileOutbox` ends with `drainOutbox`, on the test's rows.

With a queue for the account, any drain does real work: it claims a ready outbox row, and `drainPendingSentAppends`
appends a sent row's Sent copy (for Gmail, `appendToSentFolder` returns `true` with no network call), marks the row
appended, and `finalizeOutboxMessage` deletes it. Undo (`discardOutboxMessageConfirmed`, through
`finishOutboxCancellation`) starts such a drain too, and posts `.backgroundDataDidChange`.

## How it showed

`ChatSendingBubbleTests`, all on account `acc-sending`: `whichRowsShow` twice (the sent row deleted between two reads;
its diagnostic print showed the row gone, the other rows kept), and `summaryAtSendIsTheEmailsOwn` once (its control
claim of a ready row failed: a drain had claimed it). Each failing run's log has the task's `NetworkMonitor: start()`
line inside the suite before the failure; the task prints it every time it runs.

## How to apply

- A row or pending operation that vanishes or changes in a test with no code of its own touching it: look for the
  task's `NetworkMonitor: start()` line before the failure in the test log, then for the drain that could act on it.
- Until #1595 is fixed, a test that checks reads or a row's state, with no drain in mind, keeps drains out: unregister
  the account's provider first (`AccountManager.shared.unregisterProviderForTesting(accountId:)`) and make removals
  through the database half (`AccountManager.cancelHeldOutboxRow(db:messageId:)`), which starts no drain and posts
  nothing.
- A hosted screen on headers with no stored body can also reach the live `AccountManager.fetchBody(for:)`, which
  connects the account the same way (see the `_fetchBodyOverride` note in `MessageDetailViewModel`).

Related: memory 006 (a test passing alone and failing in the suite points at shared state), memory 089 (the
`registerProviderForTesting` seam).
