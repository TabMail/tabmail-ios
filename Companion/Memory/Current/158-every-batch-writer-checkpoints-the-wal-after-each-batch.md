# 158 — Every batch writer checkpoints the WAL after each batch (2026-11-24, #1376)

**The rule.** Any code that writes the main database in a loop of batches (a worker draining a list,
a one-time sweep, a backfill) bounds each batch and calls `SyncEngine.checkpointWALThrottled()` after
each batch, OUTSIDE the write transaction.

**Why.** SQLite autocheckpoint is OFF (`AppDatabase.makePool`), so nothing else moves committed pages
out of the WAL while a writer keeps writing. A batch loop with no checkpoint grows the WAL for as long
as it runs, and every later read pays for the longer WAL. Calling it inside the write would hold the
writer through the checkpoint. The call is throttled
(`SyncConfig.walCheckpointMinIntervalSeconds`), skipped while the database is suspended, and runs a
`PASSIVE` checkpoint on the background pool, so calling it after every batch costs at most one
checkpoint per interval and never waits on readers or writers.

**How to apply.**
- Take the checkpoint as a parameter with the production default
  (`checkpoint: @Sendable () async -> Void = { await SyncEngine.checkpointWALThrottled() }`), call it
  after each batch's write has returned, and pin it with a test that passes a counting closure and
  asserts one call per batch (`BodyAssetPendingDeleteTests.drainsInBoundedBatchesWithACheckpointAfterEach`,
  `oneTimeSweepQueuesDeadKeysAndRunsOnce`).
- Do not change the database's own checkpoint settings to get the same effect: no `PRAGMA
  wal_autocheckpoint` change and no connection-wide setting without its history check (see the
  `PRAGMA` history in `AppDatabase`).

**Where it applies today.** `BodyAssetMaintenance.processPendingDeletes` (the body-asset
pending-delete worker) and `BodyAssetMaintenance.runOrphanSweepOnce` (its one-time sweep); the
backfill body queue and the embedding queue already call it.

**Search terms:** WAL checkpoint; `checkpointWALThrottled`; autocheckpoint off; batch writer;
constant writer; WAL growth; pending-delete worker; one-time sweep.
