# A foreground pass starts the backfill worker, whose first slice takes the account's turn (#1340)

**Keywords:** backfill worker; `startBackfill`; `resetBackfill`; `stopBackfillWorkerForTesting`;
`headerBackfillTasks`; `runBackfillCycle`; `runCatchUpRun`; `oneSyncAtATime`; account turn; busy account;
follow-up flag; `followUpWanted`; `followUpRun`; `followUpPass`; `syncOrFollowUp`; `foregroundPass`;
200 ms; flaky test; flake; `SyncRunBannerEntryPointTests`; `busyChangeReadRefreshNeverClears`;
`busyAccountPollNeverClears`; "Unable to refresh mail"; banner; partial run; test isolation.

## What happens

`SyncEngine.foregroundPass` calls `startBackfill(account:)` (its step 3). Its callers are
`sync(account:)`, `syncOrFollowUp` (a foreground poll, through `AccountManager.foregroundSyncOne`) and
`followUpPass` (the follow-up stage 2, through `AccountManager.followUpRun`). A pull-to-refresh is not one:
it runs its listings and the change read (`syncFolderMessages`, `backgroundDeltaSync`), and reaches
`startBackfill` only through a stage 2 it asks for when it finds the account busy.

When the account has no worker yet, `startBackfill` starts one (`headerBackfillTasks[accountId]`); with
one running it does nothing. A new worker, in order: sleeps 200 ms, updates the backfill progress, reads its
power and network gates, yields to `PriorityGate`, then runs `runBackfillCycle`: the walk when its gates
allow it, then `runCatchUpRun(.snapshot(deadline:))`. `runCatchUpRun` takes the account's turn
(`oneSyncAtATime`) at least once, even when there is nothing to catch up, when the account has a registered
work queue. A worker cancelled before then stops at its next check.

So some time after a foreground pass started a new worker (no sooner than its 200 ms sleep; the later
steps add to it, with no bound), the account is busy for a moment. A sync trigger that arrives then finds
the turn held: its change read sets the follow-up flag instead of reading, and the run is partial.

## The test failure it caused (#1340)

`SyncRunBannerEntryPointTests.busyChangeReadRefreshNeverClears` and `busyAccountPollNeverClears` ran
`followUpRun` for account A and then, a little over 200 ms later (`waitForAsks` ends with a 200 ms
sleep), a last refresh or poll that must clear the banner. The worker the follow-up started raced that
last run: when its slice held A's turn, the last run's change read found A busy, the run was partial,
and the banner stayed (3 red in 5 runs on main).

Fix, in the tests only: right after `followUpRun`, stop the worker and wait until it has ended
(`SyncEngine.stopBackfillWorkerForTesting(accountId:)`, a test-target extension that removes the task and
cancels it in one actor turn, then waits for it to end; while it waits, other engine work can run, so a
test must not start another foreground pass of that account meanwhile). The tests then check that the follow-up read A once and
served the flag, and that the last run read A again.

## Rule for tests

A test that needs an account free after a foreground pass or a follow-up must stop that account's
backfill worker first and wait for it to end: `stopBackfillWorkerForTesting(accountId:)`. Cancelling
alone (`resetBackfill`) does not wait for a worker already inside a cycle. `SyncEngine.remove(accountId:)`
also joins the worker, but it unregisters the account from the engine (its provider, work queue and
follow-up flag), so a later run's engine work skips that account: no change read until it is registered
again.
Earlier precedent: `IMAPChangeCondstoreTests.foregroundPass` calls `resetBackfill` after `engine.sync`.

The product side of the same window (a pull that succeeds can leave "Unable to refresh mail" up while
a worker's slice holds the turn) is ios#1346.
