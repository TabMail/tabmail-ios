## ADR-IOS-104: One Sync Pass at a Time per Account

**Status:** Active (2026-11-09; owner ruling, relayed by the coordinating session). Found while reviewing #427.

**Context:** a sync pass is `SyncEngine.sync(account:)` (the delta, then the full sync when it is due,
then its post-steps) or `SyncEngine.backgroundDeltaSync(account:)` (the delta alone, for push wakes and
background refresh). Neither had a per-account guard. `sync(account:)` said "ProviderWorkQueue handles
concurrency", but the work queue has several slots (Gmail and Exchange 10; IMAP as many as the pool),
so it serializes requests, not passes. `backgroundDeltaSync` said outright that background deltas "run
concurrently with foreground syncs", on the grounds that delta writes are idempotent and cursors only
grow. The foreground poll, launch, account setup, Settings and a push wake could therefore run one
pass's full sync while another pass's delta was in flight, and both write the account's delta cursor
(`Account.lastHistoryId`). The owner's model was always that this cannot happen.

**Decision:**
1. **One semaphore per account, first in first out** (`SyncEngine.oneSyncAtATime`). Both entry points
   run their whole pass inside it. A pass that arrives while another of the same account runs waits its
   turn and then runs; a caller's timeout includes the wait. The turn is released on every exit, a throw
   included, and handed straight to the oldest waiter, so a later arrival cannot overtake.
2. **A pass never acts on account sync state read before its turn** (owner, 2026-11-10, choosing the fix
   at the cause over blessing the gap). The pass's first step inside its turn re-reads the account row
   (`SyncEngine.accountAtTurnStart`), and the pass bodies (`foregroundPass`, `backgroundDeltaPass`) take
   only the account id, so no cursor path can reach the caller's copy. The delta cursor
   (`Account.lastHistoryId`), the full-sync-due decision (`lastFullSyncAt`) and the 15-second recent-sync
   check (`lastSyncedAt`) all come from that fresh row. So a pass that waited never clears or overwrites
   a cursor a pass ahead of it wrote, and two queued passes never both run a full sync only one was due
   for. Census at the ruling: every write of `lastHistoryId` runs inside a pass (the Gmail and Outlook
   delta's advance and clear, `captureSyncCursors`; the extension writes only its own mirror), so nothing
   moves the cursor while a pass holds the turn and no compare-and-set is needed. The writers of
   `lastFullSyncAt` outside a pass (`StartupMigrations`, the epoch rebuild, Settings' resync) only clear it
   to make a full sync due, which the fresh read honours when the clear lands before the pass's turn starts
   (`AppDatabase` also clears it at its release boundary, before any pass runs). A clear that lands while
   a foreground pass's full sync is in flight is stamped over by that pass's end write: a pre-existing
   race, tabmail-ios #572. This is live sync state, not a setting, so the
   snapshot-at-operation-start rule does not apply to it ("settings versus the world").

   **Amended 2026-11-12:** a pass also takes the caller's deadline (`deadline:` on `sync(account:)`,
   `backgroundDeltaSync` and `performDeltaSync`). It is not account sync state: it is when the caller stops
   waiting, fixed before the turn. A change reader's budget is measured from it at the start of the turn
   (ADR-IOS-111, `SyncEngine.changeReadEnd`), so a pass that waited for its turn reads for less, and one
   left with too little time reads nothing and keeps its bookmark, rather than reading what it cannot apply
   before the caller gives up. Without it, a pass that waited could start a full read budget near the
   caller's timeout and have its applied work cut off. Superseded wording, kept: "the pass bodies
   (`foregroundPass`, `backgroundDeltaPass`) take only the account id" (they now take the account id and
   the caller's deadline, and still no copy of the account).
3. **Nothing else changes** (owner: "the full sync and delta sync work the same as right now ... If one
   is running, the other just waits. It's a simple semaphore. Do not change anything of the timing
   logic"). There is no joining, no coalescing and no new trigger. The 15-minute full-sync interval, the
   15-second recent-sync check (now on the fresh row, item 2), the delta-then-full-sync order inside a
   pass and every scheduler stay as they were.
4. **No time cap on the wait.** A waiter whose task was cancelled still takes its turn; its pass then
   stops at its first cancellation-aware step: the turn-start account read (GRDB's async reads throw
   `CancellationError` once the task is cancelled), or else its first work-queue call.
5. **Not inside it:** single-folder syncs (`SyncEngine.syncFolderMessages`: pull to refresh through
   `AccountManager.syncFolders`, message detail, the operation executor, the outbox, on-demand fetches,
   and the UIDVALIDITY reaction under its own per-folder single flight, ADR-IOS-061), backfill, FTS
   indexing and the AI queues. None of them runs a delta or a full sync, or writes the account's delta
   cursor (`Account.lastHistoryId`).

   **Amended 2026-11-22 (tabmail-ios #755): `syncFolderMessages` takes the turn.** A single-folder
   listing now runs inside `oneSyncAtATime` of its account (ADR-IOS-111, amendment 2026-11-19 (#755)
   "CONDSTORE without QRESYNC", item 7), so no listing commits between a change read and its apply. It
   still runs no delta or full sync and writes no delta cursor. Its quarantined-folder branch still
   starts the UIDVALIDITY reaction before taking the turn. Superseded wording, kept: "single-folder
   syncs (`SyncEngine.syncFolderMessages`: ...)" in the list of what is "Not inside it" above.

**Rejected:** joining a running pass or coalescing waiters into one trailing pass (the owner asked for a
plain semaphore, and both change what a caller's pass does); a wait cap that drops the waiter (a
skipped pass); relying on the work queue (it has several slots by design, for throughput).

**Consequence:** a push wake that arrives during a foreground full sync now waits for it, then runs its
delta from the cursor that full sync captured. A foreground pass that waited behind one that has just
synced skips (the 15-second check). The epoch rebuild's immediate resync, which clears `lastFullSyncAt`
and then passes accounts it read before the clear, now runs the full sync it exists to force, unless its turn starts
within 15 seconds of another pass's sync (the recent-sync check), in which case the full sync stays due
and the next foreground pass runs it; on the caller's copy it did not run when a full sync had run in
the last 15 minutes. The work queue is still looked up before the wait (tabmail-ios #573). No caller
calls a pass from inside a pass (census at the ruling: the account-manager entry points, account setup,
three Settings actions and the launch-time epoch-rebuild kick), so the non-reentrant semaphore cannot
deadlock; a new caller from inside a pass would. Tests: `OneSyncAtATimeTests` (a second pass, foreground
or background, waits until the first pass's full sync is done, and a waiting foreground pass then skips
rather than sync again; a delta that waited behind a full sync runs from the cursor it captured; a full
sync made due after the caller read the account still runs; a pass that throws hands the turn on; passes
waiting their turn run one at a time in arrival order, and one arriving during a handed-over turn waits
too; passes whose account was removed while they waited do nothing and hand the turn on; another
account's pass does not wait).

**Amended 2026-11-22 (tabmail-ios #755): the semaphore is re-entrant for the task holding the turn.**
`oneSyncAtATime` records the task holding each account's turn in a task-local (`@TaskLocal heldSyncTurn`,
`SyncEngineOneSyncAtATime.swift`). A call from that same task, such as a listing reached inside a pass
(a quarantined folder's turnover resync during the full sync), runs in the pass's turn instead of waiting
for it. A task spawned inside the turn is a different task and waits like any other caller, so a turn
holder must never await such a task: it would never finish. The test harness reports such a wait once it
overruns `SyncConfig.syncTurnWaitTestBoundSeconds`. See ADR-IOS-111, amendment 2026-11-19 (#755)
"CONDSTORE without QRESYNC", item 7. Superseded wording, kept: "so the non-reentrant semaphore cannot
deadlock; a new caller from inside a pass would" (a caller in the holding task now runs in the turn; one
in another task that the holder awaits still would). Tests: `IMAPChangeTurnAndGuardTests`
(`nestedListingInsideTheTurnCompletes`, `spawnedTaskWaitsForTheTurn`,
`fullSyncReDrivesAQuarantinedFolderWithoutDeadlock`, `turnFuzzNeverDeadlocksAndConverges`),
`OneSyncAtATimeTests.awaitedChildTakingTheTurnIsReported`.

**Amended 2026-11-20 (tabmail-ios #1062): the Settings resets are turn-takers.** "Reset message data" (one
account) and "Delete All Email Index Data" (every account) run their authoritative write transaction
only through the engine entry points `SyncEngine.resetMessageData(accountId:)` and
`SyncEngine.wipeLocalIndex()` (which own the transactions `resetMessageDataTxn` and `localIndexWipeTxn`,
moved off the SwiftUI views), inside the sync turn of every account they write, through
`SyncEngine.withSyncTurns(accountIds:)`, which
takes the turns one after another through `oneSyncAtATime` in sorted, de-duplicated account-id order, so
two callers needing overlapping accounts never wait on each other in a cycle. The turns are taken before
the database writer opens, never while holding it, and every turn is released on every exit, a throw
included. The wipe reads the account ids again inside its write; if they changed while it waited, it
releases the turns and takes them again for the new set, so no account is wiped without its turn. The
derived cleanup and the resync after the reset run outside the turn, so no pass is called
from inside a pass. Why: a catch-up slice, change pass or full sync read before a reset and written after
it put pre-reset picks and progress back over the reset. The turn PREVENTS that collision; nothing
detects it (no reset generation, no compare-and-set on `Folder.catchUpState`). **The wait:** a reset
waits for the account's running pass and every pass already queued ahead of it (FIFO, no time cap, item
4); a running full sync can take minutes, a catch-up slice at most one slice. Settings shows its existing
progress state (`isResetting`, `isNuking`) for the whole wait; the reset does not cancel a running pass.
Tests: `SyncTurnsForResetTests` (sorted order: a reset queued on the lower id holds no turn of the
higher; every turn released on a throw), `IMAPMissingByUIDTests.resetDuringASliceIsNeverUndone` (both
entry points: a reset issued while a slice is in flight leaves no pre-reset pick inserted and no
pre-reset progress kept). Cancelling the running pass is not done (tabmail-ios#1118).

**Amended 2026-11-22 (tabmail-ios #1275): no recent-sync skip; the two clocks gate the pass.** A
foreground pass is gated by the account's two persisted clocks and nothing else. It always reads changes
(a successful change read stamps `lastSyncedAt`), then runs the full sync when `lastFullSyncAt` on the
turn-start row is `fullSyncInterval` old or more, or NULL, or when the change read needs a listing (a
failed change read does not stop a due full sync); the order inside the pass (change read, then full sync)
is unchanged. The
15-second recent-sync check on `lastSyncedAt` is deleted. Why: item 2 moved that check onto the fresh row,
which also carries the stamp of a change read that has just run. Every foreground return starts a
background delta (`SyncScheduler.syncStartup` returns at once; its sync task runs `backgroundPoll`)
alongside its poll's foreground pass, and pull to refresh runs one too (`AccountManager.syncFolders`).
When the delta took the account's turn first, which it usually does, the poll's pass found the account
synced moments ago and returned before the full-sync-due decision. A due full sync then ran only when the app stayed open for a whole poll
interval (`SyncConfig.foregroundPollIntervalSeconds`); on the caller's copy (before item 2) the stamp
predated the change read and it ran. The check is not needed: passes of an account take turns (item 1),
so a pass that follows another repeats only a change read that finds nothing, and never a full sync the
other recorded (it reads `lastFullSyncAt` at its turn's start, item 2). Cost accepted: a foreground
return now runs the change read twice per account (the background delta, then the poll's pass), as it
did before item 1 when the two ran at the same time; the fix for that cost is the trigger shape (one gated
pass per account per trigger), never a time skip. A pass behind one whose full sync was not recorded (a
dropped folder or an unproven listing, #755) runs the full sync again, as every waiting pass did on the
caller's copy. The epoch rebuild's and Settings' resyncs clear `lastFullSyncAt`, and the first pass to
take the account's turn after the clear runs that full sync and records it: their own pass, or a launch,
poll or setup pass that took the turn first (a clear that lands while a full sync runs is #572 above).
`lastSyncedAt` is still written by every successful change read and every completed full sync, and is
shown in the account's Settings. Superseded wording, kept: in item 2, "and the 15-second recent-sync check
(`lastSyncedAt`)"; in item 3, "the 15-second recent-sync check (now on the fresh row, item 2)"; in the
Consequence, "A foreground pass that waited behind one that has just synced skips (the 15-second check)",
"unless its turn starts within 15 seconds of another pass's sync (the recent-sync check), in which case the
full sync stays due and the next foreground pass runs it", and in its test list "and a waiting foreground
pass then skips rather than sync again" (it now runs its change read and no second full sync). Tests:
`OneSyncAtATimeTests.passRightAfterAChangeRead` (right after a background delta stamped the account, the
foreground pass reads changes, and runs the full sync when it was never run or ran an hour ago, and not
when it ran a minute ago, where the pass records its own change read), `failedReadRightAfterAChangeRead`
(the same when the pass's own change read fails: the due full sync runs and is recorded with no error, and
with none due the pass reports the failed read), `secondPassWaitsForTheFirst` (either second pass, queued
behind the first, runs its change read after the first pass's full sync, and no second full sync: one Inbox
window listing and three label list requests, as a second full sync's folder discovery would ask a fourth
time). The test helpers that cleared `lastSyncedAt` to get past the check no longer do.

**Amended 2026-11-23 (tabmail-ios #1289, #1313, #1314): a sync trigger never waits for its turn; a busy
account gets one follow-up stage 2.** The design, its reasons and its history are written at the top of
`SyncEngineOneSyncAtATime.swift` (the sync design block); this amendment records the decision.
1. **Which calls are triggers.** Stage 1, the quick sync (`backgroundDeltaSync`: a return to the app,
   silent push, the open-app push, IMAP IDLE, background refresh and processing, and pull to refresh's
   change read), and stage 2 when a trigger runs it (`syncOrFollowUp`: the poll's tick, a return's herd,
   item 5's triggers). The follow-up stage 2 (item 3) is not a trigger: it waits.
2. **Take or flag.** A trigger takes the account's turn only when it is free
   (`oneSyncAtATimeOrFollowUp`). When anything else holds it (a pass, a listing, a catch-up slice, a
   reset), the trigger sets the account's in-memory follow-up flag (`SyncEngine.syncFollowUpWanted`),
   reads nothing and returns nil at once. A call from the task that holds the turn still runs in it (the
   re-entrancy amendment above).
3. **One stage 2 per flag, waiting in the trigger's place.** Setting the flag asks for one stage 2, the
   follow-up (`syncFollowUp` -> `SyncScheduler.runSyncFollowUp` -> `AccountManager.followUpRun` ->
   `SyncEngine.followUpPass`). The follow-up waits in line for the turn (`oneSyncAtATime`), so it starts as
   soon as the work holding the turn ends, even when that work takes the turn again at once (a catch-up's
   next slice: at most one slice once it is in line, as when the trigger itself waited; work that asks for
   the turn during its first steps, the account read and the connection check, goes first, #1329). At its turn it runs stage 2 only if
   the flag is still set. Stage 2 clears the flag as its first step inside the turn (`foregroundPass`), so
   however many triggers arrived, one stage 2 serves them and its read starts after each of them; it runs
   the full sync when it is due (the #1275 amendment). A follow-up whose flag an earlier stage 2 served
   does nothing and reports nothing. One that ran stands in for the trigger's own read, so it does that
   read's side steps: it reloads the inbox after its read (`.inboxDataDidChange`), and after a read that
   found changes it mirrors the delta cursors for the notification extension
   (`NSEDataBridge.mirrorLastHistoryIds`, as `SyncScheduler.backgroundPoll` does). When the turn becomes free with the flag still set (`handOverSyncPass`, the branch with
   no waiter), the engine asks again: that serves a flag set in the background, whose first ask started
   nothing, at the next opening. Removing an account (`SyncEngine.remove`) drops its flag.
4. **Foreground only.** The follow-up starts only in the foreground (`SyncScheduler.followUpMayStart`: the
   app is not in the background, read from `UIApplication.applicationState`, so inactive, a sheet or
   Control Center over the app, counts as foreground; the silent-push path's own check is narrower,
   `.active` only; sync is not disabled, no demo mode). Fast Sync does not hold it back: it stands in for
   the trigger's own read, which Fast Sync never held back (v1.11.2; that tag had no account turn and no
   catch-up slices, so only this eligibility comes from it). During Fast Sync the follow-up waits for the
   running catch-up slice and reads before the next one; the processing job's fast sync runs in the
   background, where it does not start anyway. Item 5's stage 2 for every account keeps
   the poll's gate (`SyncScheduler.pollStageTwoMayStart`: also not during Fast Sync, when the poll skips
   its own reads). In the background
   the flag waits: the next opening's stage 1 frees the account and asks again. The follow-up checks the
   same gate when it is asked for and again inside its turn, before it clears the flag
   (`followUpPass`'s `mayStart`): if the app left while it waited, it starts nothing and the flag stays set;
   the release asks again, that ask stops at the scheduler's gate, and the next opening serves the flag. On
   a launch the follow-up also waits for the first paint (`foregroundLaunchReady`), as the poll does. The
   flag is not stored; a launch runs every account's stage 1 and stage 2 anyway.
5. **A trigger that finds its own work running.** A poll tick that lands during a poll (#1313) and a
   return to the app while the previous return's work still runs (#1314, after the first paint) run
   stage 2 for every account through the same trigger form: a free account runs it, a busy one is
   flagged. The running work does the rest (the queued work, the push re-subscribe).
6. **The poll never waits for a busy account.** It reports the account `skipped`
   (`AccountManager.SyncResult.skipped`) and goes on to the queued work (actions, outbox, calendar). A run
   with a skipped account is partial, so it never clears the inbox error banner. So is a pull to refresh
   whose change read found an account busy (`AccountManager.syncFolders` returns it). The follow-up
   reports its own account as a partial run. A poll run with a skipped account also does not advance
   "Updated" (`AccountManagerState.lastSyncCompletedAt`, display only): the follow-up does, once its read
   completes. A pull to refresh whose change read found an account busy still advances it: it listed the
   folders on screen, so what the user sees is fresh.
7. **No time limit counts a wait for another pass's turn.** A trigger never waits for one: its caller's
   time limit (`SyncConfig.perAccountSyncTimeoutSeconds` for the poll's stage 2 and pull to refresh's
   change read, `SyncConfig.backgroundPerAccountTimeoutSeconds` for stage 1) and the deadline its change
   read is measured against (the 2026-11-12 amendment) start before at most its own connection check
   (`AccountManager.ensureConnected`, unchanged). Inside the turn, a wait for a provider connection slot
   does count against them (#1333). The follow-up waits, so it takes its change read's
   deadline (`perAccountSyncTimeoutSeconds` from its turn) when it gets the turn. It has no outer timeout,
   like `sync(account:)` from Settings: a waiter cancelled by a timeout would still take the turn and clear
   the flag without reading. Its deadline bounds its change read and the deadline-bounded steps of a due
   full sync (`FullSyncPlan`), as for the poll's stage 2; what a full sync could not finish in time, such as
   an IMAP folder's deletion reconcile, is owed to the next listing (ADR-IOS-111). In v1.11.4 a stage 2 queued behind stage 1 could reach its turn with no time left and read nothing
   (#1289).
8. **What still waits** (first in first out, item 4): the follow-up stage 2 (item 3); `sync(account:)` for
   Settings, a new account and the epoch rebuild; single-folder listings (`syncFolderMessages`: pull to
   refresh's folders on screen, message detail and its other callers); catch-up slices; the Settings
   resets (`withSyncTurns`). None is a trigger, and none has a time limit that counts the wait. Pull to
   refresh's listing therefore still waits for a running stage 2: the poll's is bounded by its 60 s limit
   from its turn plus the time to stop after cancellation; a follow-up, or a stage 2 from Settings, has no
   outer timeout, so a due full sync in it is waited for to its end.

**Cost:** at an opening, an account flagged before the opening's poll reached it runs one extra quick
read (its follow-up stage 2 runs when its stage 1 ends, then the poll's stage 2 reads again and finds the
full sync recorded). Per flag set in the foreground, one MainActor task that reads the account row,
checks the connection and waits in line. **Rejected:** a wait cap; dropping a busy trigger (a dropped
new-mail signal); a timer, debounce gap or recent-sync guard (#1275); starting stage 2 in the background (a
silent push already schedules background work, and the next push, poll or opening reads the rest); storing
the flag; a follow-up that takes or flags the turn like a trigger (first draft of this amendment: work that
takes the turn again at once, a catch-up's back-to-back slices, beat it at every release, so its read
waited for the whole catch-up instead of one slice, and each free release asked again, running a second
stage 2 for one flag); a timeout around the waiting follow-up (a cancelled waiter clears the flag unread).

Superseded wording, kept: in item 1, "A pass that arrives while another of the same account runs waits its
turn and then runs; a caller's timeout includes the wait" (only work that is not a trigger waits now, and
no trigger's time limit includes a wait); in item 3, "There is no joining, no coalescing and no new
trigger", and in Rejected, "coalescing waiters into one trailing pass" (busy triggers now fold into one
follow-up stage 2; work that waits is still never joined or folded); in the Consequence, "a push wake that
arrives during a foreground full sync now waits for it, then runs its delta from the cursor that full sync
captured" (it flags the account, and the follow-up stage 2 runs after that full sync, from the cursor it
captured) and, in its test list, "a second pass, foreground or background, waits" (the waiting second pass
is now `sync(account:)`; a trigger is flagged); in the #1275 amendment's tests, "either second pass, queued
behind the first" (the `sync(account:)` pass only).

Tests: `SyncFollowUpTests`: `busyTriggersGetOneStageTwo` (stage 1 or the poll's stage 2, alone or in a
burst of three, returns at once while the account is busy and reads nothing; the flag asks once for one
follow-up, which waits in line, reads once from the fresh cursor when the turn is released and runs the due
full sync once), `flagWaitsForAStageTwo` (a flag no stage 2 answered stays set, and every release asks
again until a stage 2 runs and clears it), `stageTwoAfterALongStageOneReads` (a follow-up asked for during a
stage 1 that outlasts its time limit still reads, its limit counted from its turn),
`servedFollowUpReadsNothing` (a follow-up whose flag a second follow-up or a stage 2 from Settings served
first reads nothing), `removingAnAccountDropsItsFlag`, `openingRunsTheFullSyncOnceAndReadsLast` (at an
opening the due full sync runs once per account, and each account's last read starts after its stage 1
ends: the poll during stage 1, an account flagged before the opening, the poll first),
`fuzzEveryTriggerGetsALaterRead` (seeded triggers, poll passes and held work with read latency and a clock
that jumps past every limit: every trigger gets a change read that starts after it, passes never overlap,
the flag ends empty, and at every point the account goes idle its last read started after its last trigger;
both trigger kinds meet a busy account), `pollTickDuringAPollRunsStageTwo` (#1313), `returnDuringAReturnRunsStageTwo` and
`herdSkipBranchAsksForStageTwo` (#1314), `followUpRunsInTheForegroundOnly` (active and inactive run it,
background does not), `followUpAfterTheAppLeftWaitsForTheOpening` (a follow-up admitted in the foreground
whose app leaves before its turn starts no stage 2, keeps the flag, and the next opening serves it),
`followUpWaitsForTheFirstPaint`; `SyncRunBannerEntryPointTests.busyAccountPollNeverClears` (a poll with a
busy account returns at once, reads nothing, does not clear the banner and does not advance "Updated", nor
does the account's follow-up clear it, which reads it once; a later full run does),
`busyTriggerAsksTheAppScheduler` (the app's engine asks the app's scheduler, at the flag and again at the
release), `pollTickDuringAPollReadsAFreeAccount` (the real stage 2 of #1313's branch),
`followUpWithChangesMirrorsTheCursors`, `followUpWithNothingOwedDoesNothing` (no phase, report or reload),
`followUpReloadsTheInbox` (after its read) and `busyChangeReadRefreshNeverClears` (a unified-inbox pull whose change read finds an account
busy does not clear; with the account free it does); `GmailCatchUpTests.sliceHandsTheTurnOn` and
`jobHandsTheTurnOnBetweenSlices` (a trigger during a catch-up is flagged, and its follow-up reads at the
next slice boundary, within one slice). `OneSyncAtATimeTests`'
waiting cases (`secondPassWaitsForTheFirst`, `waitingPassKeepsTheFreshCursor`, `throwingPassHandsTheTurnOn`,
`removedWhileWaitingDoesNothing`) now queue `sync(account:)`, the form that still waits.

**Amended 2026-11-23 (tabmail-ios #1331, #1327): the screen starts foreground polling in one place.** A
return to the app reaches `SyncScheduler.startForegroundPolling` (a return's stage 1 for every account, the
300 s poll timer and IMAP IDLE) through `ForegroundPollStart`, a view modifier RootView applies. It reads one
condition, the scene is active and an account exists and the app is not in screenshot mode, when RootView
mounts and whenever any part of it changes, and starts foreground polling on every change to true. A change
to false does nothing there; RootView's scene-phase handler still stops polling in the background.

Why: RootView's scene-phase handler started foreground polling on a change to active only. RootView mounts
only once the inbox is ready to paint (since v1.6.7), a cold launch in the foreground is already active by
then, and `onChange` does not run for the value a view mounts with, so the poll, stage 1 and IDLE waited for
the next background-and-return (#1331). Adding the first account while the app is open changes no phase
either (#1327). One condition read at mount and on every change covers both, with no new timer, path or
layer; Settings' database reset stays the only other caller.

IDLE follows the provider. `startImapIdle` starts IDLE only for the IMAP providers registered when it looks,
and at a cold launch RootView's connect loop usually registers them after that (the first account's provider
connects after the account list refreshes, too). So every place that makes a connected mail provider the
account's live one hands the account to `SyncScheduler.accountConnected` through
`AccountManager.liveProviderConnected` (a main-actor task it does not wait for): `connectAccount` after a
successful connect, `addIMAPAccount` and `addICloudAccount` once the provider they connected is installed,
and `updatePassword` once the accepted probe is live. The adds and the password update install their own
connected provider without `connectAccount`, so a hand-off in `connectAccount` alone missed a second IMAP
account and a re-sign-in by password. The scheduler starts the provider's IDLE when foreground polling is on,
read from the existing poll timer (set by `startForegroundPolling`, cleared by `stopPolling`). This covers
the cold launch, the first account, an account added after the last was removed (the timer survives the
removal, and `startForegroundPolling`'s `guard timer == nil` timer dedup, kept as it is, returns before
`startImapIdle`), a second account added in the open app, a re-sign-in by password, and the OAuth
reconnects (which go through `connectAccount`; their providers have no IDLE). `connectAccount` installs its
provider before it connects and keeps it when the connect fails, and `ensureConnected` later reconnects that
provider without a hand-off; so `connectAccount` hands off after a failed connect too, unless the sign-in was
refused (`authFailedAccounts`, which holds both the typed refusal and an IMAP password refusal, recorded by
the provider's sign-in reporter before it throws) or the account was removed. A cold launch with no network,
a timeout or a temporary refusal then gets IDLE at once, and IDLE's own launch retry (every 10 s) brings it up
when the server answers, as it already did for a provider `startImapIdle` found installed but not connected.
A refused password hands nothing off, so IDLE never retries it; the password update hands off the accepted
provider. A password the server refuses later, while the app is open, stops IDLE as well (#1349): a credentials
refusal in `IMAPProvider.launchIdleConnection` (an `IMAPError` whose `isSignInRefusal` holds: the sign-in of
`createServer`, or the one SwiftMail repeats inside the INBOX select or the IDLE command on a reopened connection; a
refusal for now is
`createServer`'s `ProviderTemporaryRefusal` or a `loginFailed` that `isSignInRefusal` rules out) calls the existing
`stopIdle` instead of the 10 s retry, and `startImapIdle`
skips an account in `authFailedAccounts`, so IDLE never sends a refused password again. A refusal for now, a
network error and a dropped stream keep the retry. Accepted: a server that wrongly refuses a correct password
leaves IDLE off until the next return to the app or a password update (an accepted login clears
`authFailedAccounts` but does not restart IDLE). Accepted: a server that wrongly refuses the sign-in at a cold launch and accepts the same password
later gets IDLE at the next return. A provider that goes live in the background (no timer) starts nothing. A background transition that lands between the timer check and
the provider's IDLE start can leave that IDLE on until the app is suspended, the same window
`startImapIdle` has; it is harmless extra work and the next return and background transition put it right. A provider started twice keeps one IDLE connection: `launchIdleConnection` returns
when its IDLE connection is live, and a second start during a launch replaces that launch, whose
connection is then logged out as surplus.

Screenshot mode never starts it: its seeded data is the whole content, as RootView's account task and
`InboxViewModel.performSync` already say. Before, a return inside a screenshot run started it (test-only).
Demo mode needs no term: `syncStartup` and the poll skip sync while the demo is on. RootView passes the
unit-test host as screenshot mode too (`ForegroundPollStart.isUnitTestHost`, the `XCTestConfigurationFilePath`
check, DEBUG only): the tests install their own databases and post account changes that reach the host's
account list, and the host app must not start real sync, push resubscription or IDLE over them. Every test
that starts the shared scheduler's polling stops it in its teardown, so a connect's IDLE start cannot reach a
later test.

Cold-launch cost (no network or database work is added before the first paint): RootView mounts only once the
inbox is ready to paint, and the start's synchronous part runs on the main actor at that mount (the poll
timer, the two background-task submits of `ensureBackgroundTasksScheduled`, and the spawn of the start's
tasks; not measured, the BootProfiler mark "startForegroundPolling CALLED" shows it in a device log). The
herd's first foreground pass waits for the first paint, so after it a foreground cold launch now runs what
every return runs, as every cold launch did before v1.6.7: the staged-push merge, stage 1 with its resume
recovery (in-flight queue work cancelled and re-read from the database, providers marked dirty so an IMAP
pool reconnects at its next checkout and IDLE relaunches), the poll's first stage 2, the poll timer and
IDLE. These and the inbox's own read of the folders on screen (`InboxView.onAppear` -> `startSync`, one
second later) share each account's turn, as on a return. The inbox's folder listing is not a trigger and
waits in line behind stage 1 (and, when the poll's flag came first, behind the follow-up stage 2 with a
due full sync); its account change read is a trigger, which flags a busy account, and the flags fold into
one follow-up stage 2. A pull to refresh in that window waits for the listing, as a pull right after any
return waits behind the return's work (promise 7: the reads it wants start after it).
Before the fix the launch ran only the inbox's read (the folders on screen, then each of their accounts'
change read, `AccountManager.syncFolders` -> `backgroundDeltaSync`); the full sync when due, the older-mail
catch-up, the poll and IDLE waited for a return. The hand-off adds, per provider that goes live (and per
connect that failed for now), one main-actor task the install does not wait for, and while the poll timer
is set two actor hops (the provider lookup and the provider's IDLE start).

Tests: `ForegroundPollStartTests` (a view that mounts in an active scene with an account starts once; the
first account added in an active scene starts once; a view mounted before the scene is active starts when it
becomes active; every return starts again; an account added after the last was removed starts again;
screenshot mode never starts; the unit-test host never starts; the condition's table; RootView starts it only
through the modifier, and the app's only other caller is Settings). `ForegroundStartEffectTests`, through the
app's scheduler and the app's own entry points against a fake IMAP server, with no phase change: a cold
launch (`connectAccount`) starts stage 1, then the poll's pass, installs the timer and starts IDLE for a
provider connected before the start and for one connected after it; the first account, an account added
after the last was removed and a second account, each through `addIMAPAccount`; a password update through
`updatePassword`; no IDLE from a connect while polling is off (before any start, after the app left); a cold
launch whose first connect and first IDLE launch are refused for now gets IDLE live through IDLE's retry
with no return, and one whose password is refused
gets no IDLE start; a password refused at IDLE's sign-in while the app is open gets that one sign-in and no
retry past 10 s, a return starts IDLE for a working account and skips the refused one, and the password update
brings its IDLE back, and a teardown (`markDirty`) relaunches nothing for it; IDLE's sign-in refused for now
twice keeps retrying, 10 s apart, until it is live, and so does a refusal for now of the sign-in repeated inside the
INBOX select, while a refusal of the password there stops IDLE with no retry (#1349); a provider started twice, while launching and once live, sends IDLE once on one
connection; IDLE's events on a real IDLE session (EXISTS reads the new message now; VANISHED deletes the row
it names while another pass holds the account, and its read asks for the follow-up); and a source fence:
every place in `TabMail/Services/Account` that makes a connected mail provider live calls
`liveProviderConnected` (the iCloud add, whose server is fixed, is covered by the fence alone). The
scheduler's `foregroundWorkHook` (DEBUG) records the start's work instead of running it; stage 1 and the
poll are offered at the entry of `syncStartup` and `poll`, so a record means the start reached them.
`addIMAPAccount`'s provider takes the factory's TLS test override (nil in production) so the add can reach
the plain-TCP fake server.
