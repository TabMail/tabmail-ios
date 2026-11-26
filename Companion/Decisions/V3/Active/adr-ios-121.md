## ADR-IOS-121: Both Databases Move to `auto_vacuum = INCREMENTAL` Through a One-Time Upgrade the User Starts, Then Give Their Empty Pages Back Overnight in Short Steps

**Status:** Active (2026-11-26, #1450; the upgrade's free-space need amended 2026-11-26, #1449 and #1545,
decision 3 "Room and power"). Amends ADR-IOS-006 (its current note of 2026-11-24 left
"returning the empty pages to the file system" as separate work) and ADR-IOS-029 (a `VACUUM` carries
the planner statistics marker). First written 2026-11-25 with an overnight switch the app ran by
itself; that design was replaced before release (see "Replaced design" at the end). Amended
2026-11-26 (#1448): the Optimize Storage tap, the steps' one run in the foreground (decision 5).

**Context:** A row delete moves the pages it frees to the database's freelist. On
`auto_vacuum = NONE`, the mode of every database the app created until now, no file ever shrinks: the
storage prune (ADR-IOS-006) and the body-cache evict delete rows, and the space they free stays in the
email and search database files until later writes reuse it. The app ran `VACUUM` only after "Delete
All Email Index Data" and the wipe of the app's data. A `VACUUM` of a mail-sized database holds SQLite's
single writer for the whole rewrite (measured on a Mac at 1.14 GB: 10.4 to 15.0 s, then 4.0 to 10.3 s
for the TRUNCATE checkpoint of the WAL it leaves, which held 965 MB), so a nightly `VACUUM` would hold
every write that long on every night it ran, and needs twice the database's size free each time. Once a
`VACUUM` writes its copy back into the database file (about the last 60 to 65% of its time), it cannot
be stopped: run by the app on its own in the background, an ended job would leave the rest of the
rewrite to the user's next opening of the app, with every save, search and AI tool waiting behind it.

**Decision:**
1. **Both databases use `auto_vacuum = INCREMENTAL`.** A delete still leaves its pages on the freelist;
   `PRAGMA incremental_vacuum(N)` moves up to N of them to the end of the file and cuts the end off. That
   is a short write whose cost is the pages it moves, with no table read. Everything about the mode
   lives in `DatabaseVacuum`. The cost of the mode: an INCREMENTAL file keeps pointer-map pages (one for
   about every 800 pages), which SQLite updates in every write that adds, frees or moves pages, a small
   cost on each such write, accepted. Test databases built through `AppDatabase.makeConfiguration`
   (`TestDatabase` and every fixture made with it) are new files, so they start INCREMENTAL too and pay
   the same; their page counts include the pointer-map pages, and their deletes leave empty pages on
   the freelist as before.
2. **A new install starts INCREMENTAL.** `DatabaseVacuum.setIncrementalOnNewFile` runs first in each
   database's `prepareDatabase` (`AppDatabase.makeConfiguration`, `SearchIndex.initialize`): on a file
   with no page yet (`page_count = 0`) it sets the mode before the first table exists. It must come
   before `journal_mode = WAL`, which writes the first page; GRDB runs `prepareDatabase` before it sets
   up WAL on a pool's writer. It skips read-only connections (a pool's readers), where setting the mode
   of an INCREMENTAL file fails. A new install never sees the upgrade.
3. **An existing install switches once, when the user starts the upgrade (`DatabaseUpgrade`).** The
   mode of a file that has pages changes only through a `VACUUM`. That is not a GRDB migration: SQLite
   cannot `VACUUM` inside a transaction, and launch migrations run before the app can show anything.
   The app never runs it by itself.
   - **The banner and the notice.** While either database is on NONE (`DatabaseUpgrade.needsUpgrade`,
     read from the files' headers once the inbox shows: `DatabaseUpgrade.checkAfterLaunch`, after the
     launch gate `AppStartup.awaitLaunchReady` and `SyncConfig.databaseUpgradeNoticeQuietDelaySeconds`,
     never on the first render, because the search database's read opens the search index, which the
     app opens only after the first paint, `TabMailApp.deferredSearchIndexInitIfNeeded`, memory 007;
     fence `IncrementalVacuumTests.theUpgradeCheckReadsAfterTheLaunch`), a banner sits on top of the inbox
     (`DatabaseUpgradeBanner`, the shape of the sign-in and significant-update banners: no dismiss
     button, one action, gone once its condition clears). Its action opens the notice
     (`DatabaseUpgradeView`, a full-screen cover): what the upgrade does, that it is one time, that it
     takes a minute or so (longer for a large mailbox) and that TabMail must stay open; **Upgrade now**
     and **Later**. Later closes it and the banner stays. The notice also shows by itself once per
     install, from the same check right after that read: only while the app is active and nothing else
     is presented, checked and presented with no wait between; the `DatabaseUpgrade.noticeOffered`
     flag records that it has shown. After that only the banner opens it.
   - **The storage limits come after it.** The size-limit features (Optimize Storage, #1448, decision
     5; the low-space cleanup, #1449, which does not exist yet) must give space back only on an
     upgraded database: their entry points must read `DatabaseUpgrade.needsUpgrade`, say the upgrade
     comes first, and open this same notice (`DatabaseUpgrade.openNotice`). Optimize Storage does
     (`StorageOptimizer.Row.upgradeFirst`).
   - **Room and power.** Upgrade now is off while the device lacks
     `SyncConfig.incrementalVacuumSwitchFreeSpaceMultiple` (2.05) times a not-yet-upgraded database's
     pages less its empty pages free (`DatabaseVacuum.SpaceState.liveBytes`, the storage measure's
     count; `SyncEngine.bytesToFreeForUpgrade`). The `VACUUM` copies only the pages that hold data,
     into its temporary copy and then through the WAL (each page with a 24-byte frame header, so about
     2.006 times); the rest covers the pointer-map pages the INCREMENTAL copy adds (about one page in
     820), the WAL index's growth (8 bytes a frame) and the WAL's header, about 2.010 in all, and a
     copy laid out a little differently. Amended 2026-11-26 (#1449, #1545): the first version asked
     for 2 times the file's size, empty pages included. On a database with many empty pages, the case
     of a phone short of space, that asked for far more than the rewrite uses (the file's size over
     its data, times: four times for a database three quarters empty); on one with almost none, 2 times was a little short, and the rewrite could run out near its
     end. The space counted is the space free right now (`volumeAvailableCapacityKey`),
     not what iPhone Storage shows as available, which adds space iOS could purge: the `VACUUM` writes at
     once and cannot wait for a purge, and counting purgeable space could fill the disk mid-rewrite,
     the risk of breaking the device that made the upgrade one the user starts (2026-11-26). So the notice says the space must be free right now ("TabMail needs N free
     right now. Free up space, then try again.", N = `SyncEngine.bytesNeededForUpgrade`), and does not
     contradict iPhone Storage. Upgrade now is also off while the battery is under
     `SyncConfig.databaseUpgradeMinimumBatteryLevel` (20%) and not charging (`DatabaseUpgrade.needsPower`;
     an unknown level asks nothing). Both are read again when the notice opens, on the app's return and
     on a battery change, and once more when Upgrade now is tapped. Upgrade now starts only from the
     notice: a second tap (or a repeated VoiceOver activation) while the first tap's read runs finds the
     upgrade under way and starts nothing (`DatabaseUpgradeTests.twoTapsRunOneUpgrade`).
   - **Upgrade mode.** Upgrade now shows a spinner on the same full-screen cover, with the screen kept
     awake (`keepScreenAwake`, as Fast Sync), so the user cannot use the app until it ends; and it makes
     the light pause, the two stops the app already makes on going to the background:
     `SyncScheduler.stopPolling` (the poll timer, IMAP IDLE, the foreground maintenance pass) and
     `SyncScheduler.cancelAllInFlightQueues(inboxOnly: false)` (every body, AI and embedding queue
     emptied and its running tasks cancelled). A quiet database lets the rewrite run faster and its
     final TRUNCATE empty the WAL, which then holds a second copy of the database. Nothing else is held,
     the accounts' sync turns included (no `withSyncTurns`), and no gate, queue or check is added
     anywhere (ADR-IOS-009): anything else that starts meanwhile (a push, a network change, the outbox,
     action and calendar drains, the extension's staged-mail merge, a return to the app) waits behind
     SQLite's writer and catches up after. The pause holds only until the scene next becomes active: a
     glance at Control Center or Notification Center, or a system alert, during the rewrite makes the
     scene inactive and then active again, and `ForegroundPollStart` then turns polling, its timer and
     IDLE back on through the app's own return path (only going to the background stops them). Their
     work waits behind the writer like the rest, and the final TRUNCATE may then find a reader and leave
     part of the WAL to the later checkpoints (below). No gate is added for this (ADR-IOS-009); the
     exit's start is then a second start, whose timer guard keeps one timer.
   - **The rewrite** (`SyncEngine.runDatabaseUpgrade`): the email database first, then the search
     database. Each one's free space is checked against its data (its pages less its empty pages)
     read just before, so the search
     database is measured after the email database's rewrite gave space back. Each gets one `VACUUM`
     (`DatabaseVacuum.switchToIncremental`) and then a TRUNCATE checkpoint. The copy goes to a file
     (`temp_store = FILE` for the switch, the connection's own setting restored after it): the search
     database keeps temporary data in memory, which would hold the whole copy there (measured: 595 MB at
     the peak for a 462 MB database, 182 MB with a file). The first database that needs space, stops or
     fails ends the upgrade; the later ones are left on NONE for the next try. If a maintenance pass's
     `ANALYZE` holds the statistics latch (decision 6), the email switch waits for it,
     `SyncConfig.databaseUpgradeStatisticsWaitMilliseconds` at a time.
   - **The check.** `SyncEngine.upgradeMayRun` (the databases not suspended; it runs in the foreground)
     is asked before each database and again inside the switch's write, on the writer, just before the
     `VACUUM`: the write is queued and can wait behind others, and if the databases were suspended
     meanwhile nothing runs (`IncrementalVacuumTests.theUpgradeAsksTheCheckAgainOnTheWriter`).
   - **Turning everything back on.** The one `defer` set right after the stop, in `DatabaseUpgrade.run`,
     calls `SyncScheduler.startForegroundPolling` at every exit (done, failed, short of space before or
     during the rewrite, rolled back) when the app is active at that moment (`DatabaseSuspension.isAppActive`): a sync at once,
     whose stage 1 and poll refill the queues, the poll timer and IMAP IDLE. An exit while the app is in
     the background starts nothing (going to the background has just stopped polling, and a foreground
     timer left on would fire in a later background wake); the return to the app turns everything back on
     through `ForegroundPollStart` in `RootView`, which calls `startForegroundPolling` on every change to an
     active scene. The pause lives only in memory, so a relaunch after the app is killed starts with
     everything on. An Upgrade now refused for lack of room or power pauses nothing. Pinned by
     `DatabaseUpgradeTests` (each exit, active and in the background, the return, a refusal for room
     and for power, and two taps) and the source
     fence `IncrementalVacuumTests.theUpgradeRunsOnlyInUpgradeMode` (the order stop, exit, queues,
     rewrite; one stop and one start; no sync turn; nothing persisted but the notice flag).
   - **Leaving mid-upgrade.** If the user leaves the app and iOS suspends the databases while the `VACUUM`
     builds its copy (the first 35 to 40% of its time at 1 GB, memory 162), the suspension interrupts it
     and it rolls back (`aSuspensionRollsTheUpgradeBack`); the screen stays up and the upgrade starts
     again when the app is active (`DatabaseUpgrade.appBecameActive`, from the screen's scene-phase
     handler, after the return's own start). If iOS freezes the app between the interrupt and the
     switch's catch, the catch runs after the resume, finds the databases no longer suspended and the
     screen says the upgrade could not finish: nothing is lost, the banner stays and Upgrade now runs it
     again. A rarer order leaves the spinner up with nothing running: the rewrite's stop is computed just
     before iOS freezes the app, and at the resume the screen's `appBecameActive` runs before `run` has
     set `continuesOnReturn`. The screen also stays awake until then (`keepScreenAwake` follows the
     spinner), so a phone put down in that state does not lock by itself. One gesture recovers it:
     leaving and returning starts the upgrade again (killing the app also does: the banner shows at the
     next launch). Accepted; no mechanism is added for it (re-running from the stopped branch whenever
     `isAppActive` is true would loop in ADR-IOS-041's stranded-suspension race: run, stop, run again,
     each pass stopping and restarting polling). Once the `VACUUM` writes its copy back, no interrupt stops
     it (SQLite's copy-back never checks for one): if iOS ends the process first, the uncommitted copy
     rolls back when the database is next opened, nothing is lost and the banner shows again. A copy-back
     that commits after the databases were suspended has its TRUNCATE refused (the suspended database
     aborts it, and the error is dropped). That TRUNCATE, and one that cannot empty the WAL because a
     reader still holds part of it, is not tried again: the WAL keeps the rewritten pages until the
     database's later checkpoints (`checkpointWALThrottled` for the email database). Both files are in
     Application Support, not the App Group container, so the suspended process is not killed for the
     lock it holds (ADR-IOS-041).
   - **The end.** Done: the screen says so, the banner goes, and the exit's start syncs at once. Failed (a
     `VACUUM` threw while the databases were not suspended, and rolled back): the screen says nothing
     was lost and the banner stays. Short of space once paused: the notice again, with the space message.
     Out of space during the rewrite (SQLite's SQLITE_FULL although the check found room: something else
     used the space meanwhile, or the copy needed more; `UpgradeStep.ranOutOfSpace`): the `VACUUM` rolled
     back and its temporary copy is gone, nothing was lost. Its WAL is then truncated: the pages its
     copy-back wrote there keep the file large, and the TRUNCATE copies any committed frames (writes
     since the last checkpoint), then empties the log, giving that space back at once, on the one path
     where the phone is short of it (no retry; if a reader or the full disk stops it, the error is
     dropped and SQLite's journal size limit, 32 KB on the app's pools per memory 020, cuts the log back
     at its next reset). Then the notice again with the space message
     (`DatabaseUpgrade.ranOutOfSpace`, cleared when the next upgrade starts), the banner stays, and the
     exit's start turns sync back on (`DatabaseUpgradeTests.aFullDiskTurnsEverythingBackOnAndAsksForSpace`,
     `IncrementalVacuumTests.aFullDiskEndsTheUpgradeAsOutOfSpace`).
   - **No main-thread write waits on the rewrite.** The app's synchronous writes to the two databases
     (`write` or `writeWithoutTransaction` without `await`, census 2026-11-26), and why none runs on the
     main thread while the upgrade screen is up:
     - on an actor, which waits on its own executor, never the main thread: `ChatStore`,
       `ChatIdTranslator`, `DraftStore` (its synchronous `save` has no caller in the app; compose and chat
       use `saveAsync`), `SyncEngine`, `SearchIndex`, `MemoryIndex`, and the staged-mail merge
       (`NSEDataBridge.mergeInboxRemovals`, run by the `NSEMergeCoordinator` actor);
     - maintenance (`SyncEngineMaintenance`, the evictions of `ChatStore` and `DraftStore`): detached, off
       the main thread; the stop cancels the foreground pass;
     - a tap the cover blocks: Settings' folder roles (`AccountDetailView`'s `setFolderRole`, `assignRole`,
       `clearRole`) and the Outbox's retry, discard and discard-returning-draft
       (`AccountManagerOutbox.retryOutboxMessage`, `discardOutboxMessageConfirmed`,
       `discardOutboxMessageReturningDraftConfirmed`);
     - launch and migration time (`AppDatabase`, `StartupMigrations`), the extension's staging database
       (a separate file, not rewritten), and the demo and screenshot modes.
     Reads go on during the rewrite on their own connections (WAL).
   - A database that never upgrades (the user never starts it, or it never has room) stays as it was
     before this change: its empty pages are reused by later writes, and it gets no step (decision 5).
   - No launch-time switch, no switch the app starts by itself, and no copy into a new file and swap.
4. **Every `VACUUM` the app runs leaves the database INCREMENTAL.** `DatabaseVacuum.vacuum` is the only
   one (`IncrementalVacuumTests.everyVacuumStatementIsInDatabaseVacuum`) and sets the mode first. Its
   callers: the upgrade's switch, "Delete All Email Index Data" (`SettingsView.nukeDatabase`), the wipe
   (`AppDataWiper.wipeAll`) and the search database's after it (`SearchIndex.vacuum`).
5. **The nightly steps.** On an INCREMENTAL database with empty pages the background processing job
   (`SyncScheduler.performBackgroundProcessingWork`) runs `SyncEngine.runOvernightSpaceReturn` last, after
   `syncStartup`'s maintenance pass (which prunes and evicts, freeing the pages) and the tokenizer shard
   rebuild, the email database then the search database. It runs
   `incremental_vacuum(SyncConfig.incrementalVacuumStepPages)` steps (2,048 pages, 8 MB at the 4 KB
   page size; `DatabaseVacuum.giveBackEmptyPages`; the step size is at least 1, since SQLite reads 0 or
   less as "every page"), each one write and a short writer hold, never the argument-less form, which
   gives every page back in one write. It runs them until no page is empty, or a step frees nothing
   (writes filling pages as fast as the steps free them). On the email database each step is followed by
   the app's throttled PASSIVE checkpoint, as after every batch writer (autocheckpoint is off;
   `stepsGiveEveryEmptyPageBack` counts one call per step, `theEmailStepsUseTheAppsCheckpoint` pins the
   default). Before each step and before the TRUNCATE after the steps, the run checks that the app is not
   in the foreground and the databases are not suspended (`SyncEngine.spaceReturnMayRun`): the app coming
   forward or the job ending stops the run, and a step already running finishes, with its checkpoint, so
   a step's few milliseconds can land in the foreground. The foreground check is there for the sync
   timing promises below, not for ADR-IOS-046's non-WAL lock reason: both databases are WAL. Each
   database's work ends with `wal_checkpoint(TRUNCATE)`, except after a stop. No TRUNCATE follows a
   database with nothing to give back: what its WAL holds is left to its later checkpoints. A database
   still on NONE gets no step and no switch (`theJobLeavesADatabaseNotUpgradedAlone`). No nightly full
   `VACUUM`. Measured on a Mac, 190 MB empty in a 960 MB database, per step (median): 1,024 pages 51 ms,
   2,048 pages 35 ms (one step of 520 ms), 4,096 pages 71 ms, 8,192 pages 168 ms.
   - **The writer holds, in full.** The step times are the steps alone. The email database's throttled
     checkpoint runs inside its own write, at most every `SyncConfig.walCheckpointMinIntervalSeconds`
     (1.5 s): at the measured pace about one step in 40, copying what those steps wrote, up to about
     300 MB, a writer hold of about 0.6 to 2 s at 2 to 6 ms per MB (memory 162). The TRUNCATE after the
     steps copies what the last checkpoint left. A write therefore waits for at most one step and the
     checkpoint after it, the cost class of any batch writer (memory 158), or for the final TRUNCATE.
   - **The Optimize Storage tap (#1448), the steps' one run in the foreground.** Settings > Email Index
     shows an Optimize Storage row while the two databases' empty pages come to at least
     `SyncConfig.optimizeStorageMinimumGainBytes` (50 MB; `StorageEstimator.PageTotals` of both, the
     storage limit's own measure), with the size "Email Index Used" can drop to: the space used less
     those empty pages. The WAL files are not counted: a run with no empty page to give back truncates
     no WAL, so the row promises only what a run gives back. On a database not upgraded the row says
     the upgrade comes first and the tap opens the upgrade's notice (decision 3). On upgraded databases
     the tap runs the same `runOvernightSpaceReturn` now (`StorageOptimizer`), on the email database's
     background pool, so a sync or user write waiting for the writer goes first, with its own check:
     the app in the foreground and the databases not suspended (`SyncEngine.optimizeStorageMayRun`), and
     the run not stopped (`StorageOptimizer.stop`, when Settings goes or a page opens over it, cancels
     the run, and the check reads the cancellation). The app leaving, the suspension or Settings going
     stops it between two steps; a step running at a stop finishes or is interrupted and rolls back, and
     the rest waits for the night. Sync is not paused, no turn is held, and polling and IDLE stay on:
     each step is one short write followed on the email database by the app's throttled checkpoint, the
     cost class of any batch writer, and the TRUNCATE at the end copies what the last checkpoint left.
     One run at a time: a second tap while it runs starts nothing. A step that fails shows "Could not
     finish now. Nothing was lost. TabMail will try again overnight."; a stop shows nothing. "Email Index
     Used" (until then a walk of the storage folder in the view's body) and the row are measured off the
     main thread when Settings opens, after a run, when the upgrade's screen closes and after "Delete
     All Email Index Data". Pinned by `StorageOptimizerTests`,
     `IncrementalVacuumTests.theTapsCheckNeedsTheForegroundAndNoSuspension`,
     `theTapReachesTheSizeItsRowPromised` and `theTapRunsTheAppsStepsWithItsCheck`.
6. **The email database's switch carries the planner statistics marker** (ADR-IOS-029). A `VACUUM` adds
   one to `schema_version` and copies `sqlite_stat1` unchanged, so without a carry it would re-arm a
   whole `ANALYZE` for statistics that did not change. `SyncEngine.switchEmailDatabaseToIncremental`
   reads `schema_version`, switches and reads it again, in one write on the writer connection, under the
   statistics refresh's latch (`plannerStatisticsRefreshInFlight`), so no `ANALYZE` stores its marker
   in between; a marker equal to the first value is set to the second, and a marker already stale stays
   stale. If an `ANALYZE` holds the latch, the switch does not start and the upgrade waits for it
   (`theUpgradeWaitsForTheStatisticsLatch`; a suspension while it waits ends the upgrade,
   `aSuspensionWhileWaitingForTheLatchStops`). The steps change no `schema_version` (measured) and carry
   nothing. The search database has no marker.
7. **Rowids.** A `VACUUM` keeps the rowids of a table that has an index (measured; SQLite documents only
   that it may renumber the rowids of a table without an INTEGER PRIMARY KEY); a step moves pages, not
   rows. Pinned by `IncrementalVacuumTests.theEmailUpgrade` (every `messageHeader` rowid before and
   after), `theSearchUpgradeKeepsLiveRows` (the `message_ids` rowids, the key `message_meta`, the FTS
   shards and `messages_vec` share), `stepsGiveEveryEmptyPageBack` and `searchStepsGiveEveryEmptyPageBack`.
   The app's state keyed by rowid:
   - `InboxNotificationObserver.currentlyInInbox` (`messageHeader` rowids, kept for the process's
     life): the switch empties it in the same write, once the `VACUUM` has committed
     (`forgetInboxRows`), the state of a fresh launch. A row learned before the switch that leaves the
     inbox after it keeps its banner until the app is opened or the 24-hour sweep. A switch that fails
     leaves the map as it was. Pinned by `theSwitchEmptiesTheInboxObserversMap` and
     `aSuspensionRollsTheUpgradeBack`.
   - Keyset cursors that live for one walk: the Settings mark-all-read walk (`OldInboxCursor`, date and
     rowid), the storage prune (`PruneCursor`, prune key and rowid over `messageHeader`) and the
     body-cache evict (`HTMLCachePair`'s cursor, `htmlCachedAt` and rowid), both in the maintenance
     pass, and the search reindex walk in `SyncEngineFTS` (date and rowid). Rowids are kept, so a switch
     in the middle of one changes nothing.
   - `MigrationTimingLedger`'s rowid ceiling: migration time only.
   - `BodyAssetMaintenance`'s pending-delete walk: the email database's `bodyAssetPendingDelete`, walked
     and deleted by `id`, an INTEGER PRIMARY KEY, which every `VACUUM` keeps.
   - The search merge's rowids: one search.
8. **The space measure** (ADR-IOS-006: pages less empty pages) is unchanged by a switch. A step lowers
   the pages and the empty pages by the same count, plus the pointer-map pages it no longer needs, which
   the measure loses.

**SQLite facts this rests on (measured on SQLite 3.54.1):**
- `PRAGMA auto_vacuum` changes a file only before its first page is written, or through a `VACUUM` run
  after it. On a new file, `journal_mode = WAL` writes the first page: set after it, the first table
  finds NONE, though `page_count` still read 0 before the table.
- On an INCREMENTAL file, setting `auto_vacuum` on a read-only connection fails ("attempt to write a
  readonly database").
- `PRAGMA incremental_vacuum(N)` frees one page per row it returns, so it frees N pages only when read
  to its end (GRDB's `execute` does; a caller that steps it once frees one page). With N of 0 or less,
  or no N, it frees every empty page (SQLite documentation).
- A `VACUUM` adds one to `schema_version`, keeps `user_version` and copies `sqlite_stat1`; a step changes
  none of them.
- An INCREMENTAL file's `page_count` includes its pointer-map pages, so a step can lower `page_count`
  by more than it lowers `freelist_count`.

**Sync timing promises** (root rule `sync-timing-promises.md`, whose note "One owner-accepted exception:
the one-time database upgrade" records the exception below). The steps run outside every account's
sync turn, at the end of the background processing job, and touch no connection, trigger, flag or clock.
The Optimize Storage tap's run of the same steps (decision 5) is the same outside the job: in the
foreground, while Settings shows its row, on the email database's background pool, with nothing
paused. The upgrade holds no turn and adds no trigger, flag or clock; while its screen is up it stops
polling and IDLE and empties the queues (the app's own background stops), and every exit turns them
back on.
1. A new-mail signal is never dropped: kept. During the upgrade a push or other signal still starts its
   work, which waits behind the writer and runs after; the exit's start (or the return's) syncs at once.
   A pass's reads on their own connections go on during a step or a `VACUUM`; its writes wait for a step
   and the checkpoint after it, or for the `VACUUM`. The tap's run drops and delays no signal: the work
   a signal starts runs as always, its writes waiting at most one step.
2. A deadline starts when its work starts: kept for the steps (a write waits for one step and its
   throttled checkpoint, as after any batch writer, or for the final TRUNCATE), the tap's steps
   included: they queue at the background tier, so a sync write waiting for the writer goes before
   the next step. A write that arrives during the upgrade waits for its `VACUUM` and TRUNCATE inside its
   pass's time: part of the one-time exception, only while the upgrade screen is up.
3. No clock skip, one follow-up flag: unchanged; neither the upgrade nor the steps (the job's or the
   tap's) set or read a flag or clock.
4. Returning to the app runs whatever is due at once: kept. The return's start runs as always; an
   upgrade the suspension rolled back then starts again, and its pause stops polling until it ends.
   No job step and no TRUNCATE after the job's steps starts once the app is in the foreground; a step
   already running finishes. The tap's run stops when the app leaves, so none runs into a return.
5. The foreground keeps time: suspended only while the upgrade screen is up, the one-time exception
   (the pause stops the poll timer; a change to an active scene during the rewrite, such as a glance at
   Control Center, turns it back on through the app's return path, and its work waits behind the
   writer); back on at every exit while the app is active, else on the return. The tap's run stops no
   timer.
6. IMAP IDLE stays live in the foreground: suspended only while the upgrade screen is up, the one-time
   exception (turned back on with the timer as in 5); back on as in 5. The tap's run stops no IDLE.
7. Pull-to-refresh reads now, and new mail and the folder view go ahead of background slices:
   unchanged; while the upgrade screen is up the user cannot pull or open a folder. During the tap's
   run their reads go on and their writes wait at most one step.
8. Startup and maintenance work never starve the reads: unchanged. Neither is start-of-pass work, and
   the steps run only from the background processing job and the Optimize Storage tap
   (`IncrementalVacuumTests.theStepsRunOnlyFromTheBackgroundJobAndTheTap`,
   `theTapRunsTheAppsStepsWithItsCheck`).
Pinned by `DatabaseUpgradeTests`, `theUpgradeRunsOnlyInUpgradeMode`, `theUpgradesCheckNeedsOnlyNoSuspension`,
`theUpgradeStartsNothingWhenSuspended`, `nothingStartsWhenTheJobMayNotRun`,
`theAppsCheckNeedsTheBackgroundAndNoSuspension`, `theDefaultCheckStartsNothingInTheForeground`,
`aStopBetweenStepsEndsTheRun`, `aStopBeforeTheTruncateSkipsIt`,
`theTapsCheckNeedsTheForegroundAndNoSuspension` and `StorageOptimizerTests`.

**New statements:** `PRAGMA auto_vacuum = INCREMENTAL` (new files and every `VACUUM`), `PRAGMA page_count`
(read on every writer open, to tell a new file; only the mode set is limited to new files),
`PRAGMA temp_store` read, set to FILE and restored, `VACUUM` (now in one place),
`PRAGMA incremental_vacuum(N)`, `PRAGMA freelist_count`, the header read of mode and pages
(`DatabaseVacuum.SpaceState.read`), `PRAGMA schema_version` twice and `PRAGMA wal_checkpoint(TRUNCATE)`.
Reused at a new call site: the existing PASSIVE checkpoint `SyncEngine.checkpointWALThrottled` after each
nightly email step (an existing helper and registry row: like every batch writer, the steps checkpoint
after each batch, memory 158).
None reads a table; each has its row in `query-registry.tsv`. No migration, no new column, table or
index. `DatabaseUpgrade` runs no SQL of its own. The Optimize Storage tap (#1448) adds no statement:
it calls `runOvernightSpaceReturn` (the steps, the checkpoint after each email step, the TRUNCATE) from
a new place, `StorageOptimizer`, and Settings reads the existing header measures each time it opens and
after a run (`StorageEstimator.PageTotals` through `SpaceSource.app`, and `DatabaseUpgrade.refresh`'s
`SpaceState` read). `StorageOptimizer` runs no SQL of its own.

**Alternatives rejected:**
- The overnight switch the app ran by itself (the first design for this ADR): see "Replaced design".
- A GRDB migration: SQLite cannot `VACUUM` inside a transaction, and launch migrations run before the
  app can show anything.
- Pausing everything for the upgrade (every account's sync turn held, the drains stopped): more code
  and new states to turn back on, for work that can simply wait behind SQLite's writer while the screen
  is up.
- Turning polling back on at every exit whatever the app's state: an exit in the background would leave
  a foreground timer running into later background wakes; the return to the app already turns it on.
- A nightly `VACUUM` once the empty pages are worth it, stopped when the app comes forward (the first
  idea for #1450): it holds the writer for the whole rewrite every time it runs, needs twice the
  database's size free every time, and a stopped rewrite loses all its work.
- `auto_vacuum = FULL`: it moves pages at the end of every write transaction, inside the user's writes.
- Copying into a new file and swapping it in: a swap needs every connection to the file closed.

**Consequences:** after the user's upgrade, a database file shrinks within a night of the deletes that
emptied its pages. Until then nothing changes for that database. Tests: `IncrementalVacuumTests` (new
files start INCREMENTAL, an existing file keeps its mode until an upgrade, both upgrades with rowids, the
check asked again on the writer, a suspension during an upgrade, the space and power checks, every app
`VACUUM`, the marker carry and the stale marker, the statistics latch, the observer map, the steps on both
databases and their checkpoints, the stops, the three checks, the order of the databases, the Optimize
Storage tap's run on a real database, the source fences), `StorageOptimizerTests` (the Optimize Storage
row: its threshold, its states and copy, the tap's run, failure, stop and single run),
`DatabaseUpgradeTests` (each exit of the upgrade, active and in the background), `ForegroundPollStartTests`
(the start's callers) and the query registry. Not testable: a process end during a copy-back
(decision 3).

**Replaced design (2026-11-25, kept for history): the overnight switch.** Decision 3 first said, in
short: an existing install switches once, overnight. The background processing job runs
`SyncEngine.runOvernightSpaceReturn` last; a database still on NONE is switched with one `VACUUM` when
the device has twice the database's size free, otherwise a later night tries again. Starts only in the
background: the run's check (the app not in the foreground, the databases not suspended) is asked again
inside the switch's write, on the writer. Not interruptible once started: every write to that database
waits for it, a send or an action included, and a caller blocked in a synchronous write with it (the
search database's actor; a thread calling `PrioritizedDatabase`'s synchronous write). The job's end: if
iOS ends the job while the `VACUUM` builds its copy, it rolls back and a later night tries again; once it
writes the copy back, it keeps the writer and finishes once the process runs again, at the latest at the
app's next opening, and its TRUNCATE follows at once, so the user's first writes after opening the app
can wait for both. Its sync timing promises accepted, as a one-time exception per database, a write
waiting for a switch already running, including a copy-back the job's end did not stop. Replaced because
that copy-back could land on the user's next opening of the app with every save, search and AI tool
waiting behind it; the user now starts the upgrade, on a screen made for it.
