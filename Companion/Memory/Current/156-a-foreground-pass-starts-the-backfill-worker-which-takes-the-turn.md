# A foreground pass starts the backfill worker, whose first slice takes the account's turn (#1340)

**Keywords:** backfill worker; `startBackfill`; `resetBackfill`; `headerBackfillTasks`; `runBackfillCycle`;
`runCatchUpRun`; `oneSyncAtATime`; account turn; busy account; follow-up flag; `followUpWanted`;
`followUpRun`; `foregroundPass`; 200 ms; flaky test; flake; `SyncRunBannerEntryPointTests`;
`busyChangeReadRefreshNeverClears`; `busyAccountPollNeverClears`; "Unable to refresh mail"; banner;
partial run; test isolation.

## What happens

`SyncEngine.foregroundPass` calls `startBackfill(account:)` (its step 3). That starts the account's
backfill worker (`headerBackfillTasks[accountId]`), which sleeps 200 ms and then loops
`runBackfillCycle`: the walk, then `runCatchUpRun(.snapshot(deadline:))`. `runCatchUpRun` always takes
the account's turn (`oneSyncAtATime`) at least once, even when there is nothing to catch up.

So about 200 ms after any foreground pass (a pull, a foreground poll, a follow-up stage 2 through
`AccountManager.followUpRun`), the account is busy for a moment. A sync trigger that arrives then finds
the turn held: its change read sets the follow-up flag instead of reading, and the run is partial.

## The test failure it caused (#1340)

`SyncRunBannerEntryPointTests.busyChangeReadRefreshNeverClears` and `busyAccountPollNeverClears` ran
`followUpRun` for account A and then, a little over 200 ms later (`waitForAsks` ends with a 200 ms
sleep), a last refresh or poll that must clear the banner. The worker the follow-up started raced that
last run: when its slice held A's turn, the last run's change read found A busy, the run was partial,
and the banner stayed (3 red in 5 runs on main).

Fix, in the tests only: stop the worker right after `followUpRun` and wait until it has ended
(`stopBackfillWorker`: `resetBackfill(accountId:)`, then await the task it cancelled).

## Rule for tests

A test that needs an account free after a foreground pass or a follow-up must stop that account's
backfill worker first, and wait for it to end, as `SyncEngine.remove(accountId:)` does. Cancelling
alone is not enough when the worker may already be inside a cycle. Earlier precedent:
`IMAPChangeCondstoreTests.foregroundPass` calls `resetBackfill` after `engine.sync`.

The product side of the same window (a pull that succeeds can leave "Unable to refresh mail" up while
a worker's slice holds the turn) is ios#1346.
