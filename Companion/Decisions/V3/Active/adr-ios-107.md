## ADR-IOS-107: The Full Sync Catches Up Server-Side Changes to Older Mail

**Status:** Active (2026-11-10). Issue #540. This ADR covers the generic seam and IMAP. The Outlook
and Gmail catch-ups plug into the same seam later and will amend this ADR with their own sections.
**Amended 2026-11-10: Gmail** (decision 8 below: the Gmail catch-up, the delta-cursor lapse, the
re-armed backfill for moved-in mail, and the order-date reader accessor).
**Amended 2026-11-11: Gmail re-arm record** (decisions 1 and 8: the record of missing ids expires
after `catchUpRearmRetryIntervalSeconds`, and a folder whose walk is complete is listed from the epoch).
The record itself was removed later the same day (see the rebase amendment below); the epoch listing stays.
**Amended 2026-11-11: Gmail weekly full check** (decision 8, owner ruling: once the Gmail history
delta follows All Mail (#731), the Gmail full check is a weekly safety check plus the catch-up after
every lapse; IMAP keeps its daily check).
**Amended 2026-11-11: rebase onto the bounded page walk (#713, #723)** (decisions 5 and 8: the
backfill version migration is renumbered `v100_addFolderBackfillVersion`; a re-arm also clears
`backfillPageHeldSince`; the membership list asks for Spam and Trash mail only in those two folders;
a fetch the walk passed over is a named trigger; the re-arm record is removed, because it holds
nothing back on the weekly schedule).
**Amended 2026-11-11: lapse marker, newest first, storage limit** (decision 8: a lapse marks every
folder's state instead of clearing it, so a listing in progress keeps its place and a new listing
starts once it completes; listings run newest first; while a storage limit is in force no catch-up
re-arms a walk or lists below the oldest local row; the writer list and the Spam/Trash sentence are
corrected).
**Amended 2026-11-12: no periodic Gmail check** (decision 8, owner ruling: the weekly Gmail full check
is dropped. A Gmail folder is listed in exactly three cases: its first listing, a listing in progress,
and after a lapse. `SyncConfig.gmailCatchUpFullCheckIntervalSeconds` is deleted; the expensive-network
wait stays; IMAP keeps its daily check). *Superseded 2026-11-19 (#1063): scans always run; see the amendment of that date.*
**Amended 2026-11-12: the direct load** (decisions 1, 3, 4 and 8, owner ruling: the Gmail catch-up
loads a missing id itself, through the backfill page walk's own insert tail, bounded per pass, newest
first; a membership page's token moves on only once its missing ids have loaded or been classified
done; the backfill re-arm, its storage-limit decline and `CatchUpFolderResult.rearmBackfill` are
removed; a missing id that keeps failing holds its range for at most the page walk's hold bound).
**Amended 2026-11-12: loads that did not land** (decisions 4 and 8: a load that does
not land writes no catch-up state and the page walk keeps its page token; an id loaded earlier in the
same pass counts as held; a duplicate id in one insert chunk is skipped as the same message instead
of rolling back the chunk; the load hold clock is per page, cleared whenever the page moves on).
**Amended 2026-11-12: the hold bound under the pass budget** (decision 8: loads that
stop on the pass budget with nothing loaded hold the page like a held load, so the hold bound also
ends a page a slow link never finishes; loads that stop on the budget after loading some clear the
page's hold clock).
**Amended 2026-11-12: the catch-up runs in the backfill worker (#766)** (decisions 1, 2 and 3, the
lapse marker, and the consequences: the full sync no longer runs the catch-up. The backfill worker
runs it after the folders' walk, in slices under the one-sync-at-a-time lock, released between
slices: one slice per foreground backfill cycle, and slices until the deadline in the background
processing job. The run snapshots the network state, the storage-limit flag and the deadline when
it starts. The title's "full sync" is historical.)
**Amended 2026-11-13: the Outlook catch-up, the shared direct load, completed actions** (decisions
1, 3, 4 and 8; see the amendment at the end). Exchange implements the seam
(`ExchangeProvider.catchUp`, `ExchangeProviderCatchUp.swift`). The range cut and the direct load
moved below the seam into `TabMail/Providers/CatchUpListing.swift` and are shared by Gmail and
Outlook: `CatchUpRange` (`cut`, `listsToEpoch`) and `CatchUpDirectLoad` (`load`, `pageVerdict`).
`GmailProvider.loadMissing` is gone; where this ADR names it, read `CatchUpDirectLoad.load`. The
apply (every provider) skips a read or flag update for a message whose user action completed at or
after the moment the read began, and an over-age read applies no read or flag update. *Later the same
day:* the direct load's insert follows the same rule (a load the user's newer action stands on is not
inserted, and an over-age read inserts no load); see "Loads too" below.

**Context.** Every sync path windows its work, and changes to older mail fall outside every window:

- Delta sync and the full sync's per-folder pass fetch only the newest messages (`fetchMessages(limit:)`,
  UID-windowed for IMAP, ADR-IOS-042).
- The backfill walk only inserts.
- The deletion-reconcile walk (ADR-IOS-051) only fires when the local count exceeds the server count.

So a read or flag change made on another client to a message older than the window never reached
the device. Neither did a removal in a folder that is not fully backfilled, because there the local
count is below the server count.

The owner's rulings of 2026-11-09:

- one per-pass provider call;
- all provider logic below `EmailProvider`;
- the full sync stays a dumb pipe that "thinks it's doing full sync";
- a bounded hold under the sync lock;
- one opaque `Folder` column;
- one removal path.

**Decision.**

1. **The seam** (`EmailProviderCatchUp.swift`) is one protocol requirement,
   `catchUp(folders:localRows:context:) async -> [CatchUpFolderResult]`. It is called ONCE per full
   sync pass with all of the pass's syncable folders, re-read after the folder upsert. Each folder's
   `catchUpState` is the provider's own opaque state.
   - *Amended 2026-11-12 (#766):* it is called ONCE per slice of the backfill worker's catch-up run
     (decision 2), with the account's syncable folders as they are when the slice starts: the
     folders the full sync syncs (`SyncEngine.syncableFoldersInOrder`, main roles and favourites, in
     the full sync's order), re-read at every slice. The sentence above ("ONCE per full sync pass
     [...] re-read after the folder upsert") is superseded.
   - The provider reads local rows through `CatchUpLocalRowReader`. It gets ids and the read and
     flagged state, never content (ADR-004), and reads by numeric range, by first id, by an id list,
     or as an ordered scan. Nothing loads a whole folder.
   - It returns provider-blind results: flag updates, removed ids, the epoch the ids belong to, and
     the new opaque state.
   - **The catch-up is not the backfill (owner 2026-11-10).** It changes or removes only rows the
     device already holds. The result has no field for a message without a local row, so no
     provider's catch-up can insert: new mail is the ordinary sync's job and older mail is the
     backfill's. A folder with a partial backfill is never listed below its lowest local id or above
     its highest.
     - *Amended 2026-11-11 (Gmail):* a folder whose backfill walk is complete when a Gmail listing
       starts is listed from the epoch up to its newest local row, not from its oldest local row. A
       message older than every local row that moves into such a folder is then found missing and
       the folder's walk re-armed (decision 8). Without it that message never appears: no walk is
       running to reach it, and the delta does not cover All Mail. The catch-up still inserts
       nothing and still never lists above the newest local row. *Amended 2026-11-11:* the listing
       runs newest first, so it is its OLDEST range that reaches down to the epoch, and not while a
       storage limit is in force (decision 8, "No old mail is loaded back under a storage limit").
       *Note (2026-11-11, after #731):* the Gmail delta now follows All Mail too, so while its
       cursor is valid it inserts such a message itself. The epoch listing still covers a move the
       delta never applied (a lapse, or a change whose GET failed, #464).
     - *Superseded (2026-11-10):* "No request names an id outside the range the device holds."
     - *Amended 2026-11-12 (Gmail, the direct load):* the result carries `loaded` (the messages a
       provider fetched, header and body, for ids the server lists in the folder that no local row
       holds) and `loadFailures` (the ids that did not load, each with the page walk's own failure
       class). The apply inserts `loaded` through the backfill page walk's insert tail
       (`SyncEngine.insertFetchedBackfillMessages`, the one insert path both use). So the Gmail
       catch-up does insert, but only what the server lists in the folder, only through the
       backfill's insert path, and never above the newest local row. The sentences above that say
       the result has no field for a message without a local row, and that the catch-up inserts
       nothing, are superseded for Gmail; IMAP still returns no loads.
   - The do-nothing default returns `[]`. Gmail, Exchange and Demo use it until their own
     catch-up lands. (Gmail's landed with decision 8; Exchange and Demo still use the default.)
   - No cast, switch or knob names a provider above the boundary (ADR-IOS-060). The only generic
     input is `staleWindowMode`, which already exists.
2. **Placement.** The step runs at the very end of `SyncEngine.fullSync`, after the IMAP
   deletion-reconcile loop (`SyncEngine.runCatchUp`). That puts it inside `queue.execute(.headerFetch)`
   and the one-sync-at-a-time lock (ADR-IOS-104). The lock is taken once per pass and is never
   released between folders.
   - The step never throws, so it cannot trigger the full sync's connection-error retry, which would
     double the hold.
   - `CatchUpContext` is a value snapshot taken when the step starts: `NetworkMonitor.checkExpensive()`,
     the budget deadline and the clock.
   - *Superseded 2026-11-12 (#766):* the placement above. A full sync runs at most every 15 minutes
     and gave the catch-up 2 s, so one listing of a ten-year folder (about 1,570 list requests) took
     about 56 hours of app-open time, and the overnight background processing job never ran it.
   - **Placement since #766.** The backfill worker runs the catch-up: `SyncEngine.runBackfill` is the
     folders' walk (`runBackfillWalk`) followed by the catch-up run (`runCatchUpRun`), for every
     provider (one without catch-up returns `[]` from the default, so its run ends after one empty
     slice). It is the only caller. Both callers of `runBackfill` run it: the foreground worker
     (`startBackfill`, which every foreground poll starts) and the background processing job
     (`SyncScheduler`'s BGProcessing drain, through `performBackfill`). No cast or switch names a
     provider above the boundary (ADR-IOS-060).
     - **Run-start snapshot.** When the run starts, after the walk, `SyncEngine.CatchUpRun.snapshot`
       reads `NetworkMonitor.checkExpensive()`, whether a storage limit is in force
       (`StorageEstimator.budgetMB != Int.max`) and the deadline (the job's, or none for a foreground
       cycle). Every slice's `CatchUpContext` comes from that snapshot only (root rule: snapshot
       settings at operation start). It is taken after the walk, not before it, so a long walk never
       hands the catch-up a network state from before the walk.
     - **Slices under the lock.** Each slice takes the account's `oneSyncAtATime` turn (ADR-IOS-104),
       runs inside `queue.execute(.headerFetch)`, and releases the turn when it ends. The slice's clock
       starts when its turn starts, not while it waits. A push or silent-push delta (or a foreground
       pass) that arrives during the catch-up therefore waits at most one slice, and the turn is FIFO,
       so it runs before the run's next slice. A slice never throws.
     - **How many slices.** A foreground cycle (no deadline) runs ONE slice. The background job runs
       slices until its deadline (`SyncConfig.backgroundBackfillDeadlineSeconds`, 5 minutes, which
       also bounds the walk; formerly the literal `5 * 60` in `SyncScheduler`). Either stops after a
       slice in which no applied result made progress (`CatchUpFolderResult.madeProgress`, set below
       the boundary: the listing moved or completed, or something loaded or applies), so a folder
       whose requests keep failing is tried again at the next cycle, never at network rate.
       *Superseded in place (2026-11-21, #1062):* "Either stops after a slice in which no applied result
       made progress": a background run also takes another slice when the slice left a folder out (the
       second amendment below), and a foreground cycle takes ONE slice whatever that slice made.
       - *Clarified 2026-11-21 (#1062): who can be asked again in the same run.* The restrictions below
         (never asked again in the run, at most one more slice per folder) apply to a folder whose request
         TIMED OUT. A healthy folder is asked in every slice of the run that still has work for it, so it
         can be asked in several slices. A folder whose listing range got an answer too large or
         undecodable ends its call with the width cap written but nothing in flight, so it stays in the
         run: a later slice of the same run may ask it again, and that retry is cut by the cap.
       - *Amended 2026-11-21 (#1062): a folder whose request may still be in flight is left out of the
         rest of the run.* A folder result can report that a request of its call may still be in flight
         (`CatchUpFolderResult.requestMayBeInFlight`, provider-neutral; IMAP sets it when any catch-up
         request of the call times out (the UIDNEXT read, a listing range, a membership proof, an
         unanswered UID's SEARCH, a header load), because the timeout cancelled the request, and SwiftMail
         closes the session of a cancelled command at once (no LOGOUT; the late answer is never read; the
         pool keeps the connection, released as healthy, and its next command reconnects and logs in
         again; *qualified in place 2026-11-21:* that holds for a command on the wire; a timeout can also
         fire while the request still waits for a connection, the folder's or pool capacity, before any
         command is sent, and it is reported in flight the same way); Gmail and Outlook requests have no per-folder session to end and leave it false). The
         run never asks that folder again: `runCatchUpRun` keeps the folder ids in a set
         in its own memory (gone when the run ends, never persisted, no timer), and later slices do not
         pass them to `runCatchUp`. (*Superseded by the next amendment:* "Only the progress of folders not in
         the set decides another slice, so a slice whose only progress came from such a folder ends the run.")
         `madeProgress` is unchanged, and
         the state that folder's call saved is kept. `runCatchUpRun` still returns true when any applied
         result made progress, that folder's included (the worker's `caughtUp`). Why: a second request
         to the folder in the same run first reconnects and logs in again on the link that just timed
         out, and a second timeout there halves the width cap for a reason unrelated to width; the other
         folders' connections are untouched, so their work goes on. The worker's next cycle and the walk
         can still reach the folder soon after, and log in again on the same link: that is the
         connection layer's issue, #1133, open.
         *Superseded (2026-11-21):* "because the abandoned request holds the folder's connection until
         its late answer; Gmail and Outlook requests hold no folder connection", "Why: a second request
         to the folder in the same run waits behind the late answer or forces a new session" and "while
         the late answer is outstanding". Read against SwiftMail (the pinned revision): a timed-out
         catch-up request's cancellation closes its connection's socket at once and settles the command
         with `CancellationError`; `IMAPProvider.withFolderConnection` then releases the connection as
         healthy (`pooledConnectionUnusable`), so nothing waits for the late answer and nothing keeps the
         folder blocked; only the new session's login is left. The rule is unchanged.
       - *Amended 2026-11-21 (#1062): the slice that leaves a folder out takes one more slice.* A timeout
         spends its slice (the slice, `catchUpSliceSeconds` 2 s, is shorter than one request's timeout,
         `catchUpRequestTimeoutSeconds` 3 s), so when the timed-out folder came first in its slice the
         other folders made no progress in it, and the rule above ended the run with their work
         outstanding. The run now takes another slice when any folder the slice asked made progress, OR when
         the slice added a folder to the set. A slice asks only folders outside the set, so a slice whose only
         progress came from a folder it left out goes on because it added that folder; a folder already in
         the set is never asked, so it can never keep the run going. A foreground cycle still runs one
         slice. Bound: the set only grows, a folder in it is never passed to
         a slice again, and a folder joins it once, so the second condition adds at most one slice per
         folder to the run (at most as many as the account has catch-up folders); each such slice keeps its
         own window (`catchUpSliceIntervalSeconds`) and its own request cap (`catchUpSliceMaxRequests`).
         Nothing can loop more than once per folder: a folder in the set is filtered out before each slice,
         so it can neither be asked again nor join again; a slice with no folder left to ask, or whose
         folder read fails, returns nothing and ends the run; a slice whose folders made no progress and
         added none ends the run; the deadline still ends it. So the run ends once only left-out folders
         have work. Connections are per folder (`IMAPProvider.withFolderConnection`, one pinned connection
         per folder path, exclusive checkout), so the other folders' requests never wait behind the late
         answer. *Superseded in place (2026-11-21, #1062):* "never wait": the pool holds a bounded
         number of folder connections (`maxFolderConnections`), and when every one is in use another
         folder's checkout waits for any folder's slot to free (`IMAPProvider.createFolderConnection`'s
         capacity wait), so a request can wait across folder paths; it never waits for a late answer,
         which is never read. Rejected: going on while the set is not empty, which keeps taking slices to the deadline
         once only left-out folders have work. `runCatchUpRun`'s returned Bool is unchanged: it still
         counts a left-out folder's applied progress, so the foreground worker's next cycle can come at
         once; pacing across runs is #1133's.
         *Superseded (2026-11-21):* "Only the progress of folders not in the set decides another slice, so
         a slice whose only progress came from such a folder ends the run."
         *Superseded (2026-11-21):* "The run now takes another slice when a folder not in the set made
         progress, OR when the slice added a folder to the set. The left-out folder's own progress never
         counts": the code subtracted the set from the slice's progressed folders, which never changed a
         decision, because a progressed folder the slice left out is one the slice added. The guard now
         reads the slice's progressed folders whole; the behaviour is the same.
     - **The worker's cycle.** `runBackfill` returns true when the walk did work or the catch-up made
       progress, so the foreground worker keeps cycling (the profile's active delay between cycles:
       3 s, or 0.5 s on power) until the listing completes; then a cycle does no work and, with the
       walk done, the worker exits until the next poll starts it.
       - *Amended 2026-11-12 (#766): only the walk's own work decides the delay while a walk is
         unfinished.* A call returns what each part did (`SyncEngine.BackfillCycle`: `walked`,
         `caughtUp`). The worker waits the profile's ACTIVE delay after a call whose walk did work, or
         whose catch-up made progress once every walk of the account is complete
         (`isFolderWalkComplete`); after any other call it waits the IDLE delay
         (`SyncEngine.backfillInterCycleDelay`). Reason: a page the walk holds (a message that keeps
         failing transiently) waits the idle delay between listings (#757); a catch-up that makes
         progress in the same call must not turn that wait into the active delay and re-list the
         held page at the active pace. Once every walk is complete no page can be held, and the
         catch-up keeps the active pace; its requests are paced by the slice gap
         (`SyncConfig.catchUpSliceIntervalSeconds`), not by the worker's delay. The worker and its
         delay are per account, so another account's progress never shortens an account's wait.
         *Superseded:* "returns true when the walk did work or the catch-up made progress, so the
         foreground worker keeps cycling (the profile's active delay between cycles [...])" as the
         rule for the delay; the return value of `runBackfill` (either part did something) still
         keeps the worker cycling. Test: `BackfillPageWalkHoldBoundTests.heldPageWaitsWhileCatchUpProgresses`
         (three accounts on one engine: an account holding a page while its own catch-up progresses,
         and one holding a page while another account's catch-up progresses; neither held page is
         listed again inside the idle delay).
     - **The worker's gates now gate the catch-up.** The worker pauses while the battery is below 20%
       and not charging, and while the Wi-Fi-only setting (`backgroundSyncWiFiOnly`, default on) is
       on and the network is expensive; the background job does not run in Low Power Mode or, with
       Wi-Fi-only on, on an expensive network. *Superseded 2026-11-19 (#1063): scans always run; see the amendment of that date.* The catch-up waits for the same conditions as the walk
       (see the consequences).
       - *Superseded 2026-11-12 (#766, the Wi-Fi-only ruling below):* the Wi-Fi-only half of the bullet
         above. The battery gate and Low Power Mode still delay the catch-up as stated.
     - **Wi-Fi-only holds back the walk, not the catch-up (amended 2026-11-12, #766).** The catch-up
       ignores the Wi-Fi-only setting and keeps its own network rules, unchanged: a Gmail listing on
       an expensive network (cellular or a hotspot) waits at most
       `SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds` (7 days) since the last completed listing
       and then lists on any network; an IMAP folder on an expensive network lists only on a MODSEQ
       change, and its daily full check waits for a non-expensive network for at most the same 7 days. *Superseded 2026-11-19 (#1063): scans always run; see the amendment of that date.*
       The walk keeps honouring Wi-Fi-only exactly as before. Reason: the catch-up lists ids and
       labels only (bodies are loaded only for a message that is missing locally): one full listing
       of a ten-year Gmail Inbox (1,825 messages, 1,371 list requests) is about 1.4 MB. Its repairs
       (a read or flag change, a removal, a message archived on the web older than every sync window)
       reach the device through nothing else, so they must not wait for a Wi-Fi network that may
       never come; a device that is always on cellular with the default setting would otherwise
       never be repaired. The battery gate (below 20%, not charging) and Low Power Mode may still
       delay it, since both lift on their own. Mechanism, generic above the boundary (ADR-IOS-060): the
       caller decides `walkAllowed` (`runBackfillCycle(account:deadline:walkAllowed:)`); false skips
       the walk only. The foreground worker sets it from the setting and
       `NetworkMonitor.checkExpensive()` and no longer pauses the whole cycle (a cycle with nothing to
       do while the walk is held back still waits the setting's 30 s pause); the background job
       decides with `SyncScheduler.backgroundBackfillPlan` (Low Power Mode skips the backfill;
       Wi-Fi-only off Wi-Fi runs it with the walk held back). Tests:
       `GmailCatchUpTests.wifiOnlyHoldsTheWorkerWalkNotTheCatchUp` and
       `wifiOnlyHoldsTheJobWalkNotTheCatchUp` (Wi-Fi-only on, only cellular: a lapsed Gmail folder past
       the 7-day wait is listed, in the foreground worker and in the background job, and the walk
       sends nothing), and `IMAPCatchUpTests.wifiOnlyCellularKeepsTheDailyRule` (the same setup keeps
       IMAP's non-expensive-network rule for the daily listing).
     - Tests: `GmailCatchUpTests.sliceHandsTheTurnOn` (a delta that arrives during the run waits at
       most one slice), `jobHandsTheTurnOnBetweenSlices` (the same through the background job's
       production entry, `performBackfill`), both on a work queue of production's width so the queue
       cannot serialize the delta in the lock's place, `deadlineMidListingResumes` (a deadline
       mid-listing stops the run and the next run resumes from the saved range),
       `deadlineCutsTheSliceShort` (a deadline inside a slice ends that slice), `runStopsWithoutProgress`, `foregroundCycleMakesProgress`
       (one cycle, one slice, and the worker completes the listing), `backgroundJobRunsTheCatchUp`,
       and `IMAPCatchUpTests.backfillCycleRunsTheCatchUp`.
3. **The bounded hold.** `SyncConfig.catchUpPassBudgetSeconds = 2` covers the whole step across all
   folders and is checked before EVERY request. Each request runs under
   `SyncConfig.catchUpRequestTimeoutSeconds = 3`; a timeout or any failure ends that folder's work
   for the pass. **The added hold is typically about 2 s, and at most about 5 s** (the budget plus
   one request that started just inside it).
   - *Amended 2026-11-12 (#766):* the budget is per SLICE: `SyncConfig.catchUpSliceSeconds = 2`
     (formerly `catchUpPassBudgetSeconds`), checked before every request, with the same request
     timeout. A slice holds the lock for about 2 s typically and about 5 s at most, and the lock is
     released between slices. "For the pass" above reads "for the slice". It no longer adds to a full
     sync's hold: the full sync runs no catch-up.
   - *Amended 2026-11-12 (the direct load):* the Gmail catch-up's loads run in batches of
     `BackfillProfile.normal.gmailBodyConcurrency` (10) concurrent `format=full` GETs, the width the
     provider uses for every body fetch. The budget is checked before every request OR every batch,
     and one batch is bounded as a whole by `catchUpRequestTimeoutSeconds`, so the added hold is
     still at most the budget plus one timeout; the request count may pass the budget check by at
     most one batch less one (the seeded direct-load property checks this).
   - *Superseded 2026-11-12 (#766, the request cap below):* the slice was bounded by time only, so the
     number of requests one slice sends was whatever a fast link answered in 2 s, and back-to-back
     slices of the background job had no rate bound.
   - *Amended 2026-11-12 (#766): a request cap per slice and a pacing window.* A slice is bounded by
     time AND by a request count, `SyncConfig.catchUpSliceMaxRequests`. `CatchUpContext` counts
     the requests it allows: `hasBudget(cost:)` is false once the slice's time or its count is
     spent, and a provider charges every request before sending it. A batch of concurrent loads is
     charged its whole width before any of it is sent, so a batch that does not fit in what is left
     is not sent at all and no slice ever passes the cap (this replaces the "one batch less one"
     overshoot above). The cap is derived, not chosen: back-to-back slices must keep the sustained
     rate at no more than half of Gmail's documented per-user quota. That quota is 250 units/s, a
     list or a get costs 5 units, so half the quota is 250 × 0.5 ÷ 5 = 25 requests/s
     (`catchUpMaxRequestsPerSecond`), and one 2 s slice may send 25 × 2 = 50 requests. The rate
     holds across slices because each slice opens a window of `catchUpSliceIntervalSeconds` (real time,
     per account, in `SyncEngine.catchUpSliceWindowEnds`; *amended 2026-11-12:* a named constant of its
     own, 2 s, equal to the slice length, so the cap is 25 requests/s × 2 s; formerly the window
     reused `catchUpSliceSeconds`): no slice of the account, from the same
     run or another (a foreground cycle and the background job), starts before the previous window
     ends. The wait happens outside the lock, so a delta never waits for it, and never reaches past
     the run's deadline: a window that ends at or after the deadline ends the run. IMAP charges the
     same count (one per UID SEARCH or FETCH); the cap is generic and sits below the boundary only
     where requests are sent. Tests: `GmailCatchUpTests.loadBatchIsChargedItsWidthFirst`,
     `backToBackSlicesStayWithinTheRate`, and
     `BackfillPageWalkHoldBoundTests.heldPageWorkerWaitsTheIdleDelay` (counts every request of the
     worker's cycles, walk and catch-up, against the walk's budget plus the slice cap).
4. **The generic apply** (`SyncEngineCatchUp.swift`) uses the existing paths only.
   1. Nothing is inserted (decision 1). *Amended 2026-11-12 (the direct load):* except the result's
      `loaded` messages, which go in first, through the backfill page walk's insert tail, read with
      the folder as it is then (a folder that is gone or quarantined gets nothing). They go in BEFORE
      the transaction below writes the new state, so a crash in between lists them again rather than
      losing them, and the insert skips what is already there. The transaction itself still inserts
      nothing and never writes the walk's bookkeeping. *Amended 2026-11-12 (loads that did not
      land):* if any loaded message did not land (an insert chunk's write transaction failed, or the
      folder could take nothing), the apply writes nothing at all for that result, the state
      included (`CatchUpApplyOutcome.skipped`), so the listing stays where it was and lists those
      ranges again on a later pass. *Superseded:* a failed insert chunk was only logged, and the
      transaction then wrote the state that moved the listing past the messages it lost.
   2. ONE write transaction re-reads the folder (it must exist and not be quarantined) and
      applies the epoch gate: the result's epoch must equal the folder's stored known epoch.
      - If both are known and they differ, it writes nothing and fires the turnover reaction, exactly
        as the walk does.
      - An unknown stored epoch, or a `.uid` result naming no epoch, writes nothing.
   3. Flag updates follow the `runSyncMessages` merge rule: provider-address ownership must be proven
      (`providerAddressOwnershipProven`), and a queued flag op from this folder (`containsAnyKey`) or a
      recent completion wins. The pending ops and `liveRecentlyCompleted()` are read inside the
      transaction.
   4. Removals go through `deleteConfirmedGhostHeaders`, widened from `uids: [UInt32]` to provider
      `ids: [String]` (approved), with its pending, recent and outbox protections.
   5. The new state is written in the SAME transaction. After the commit come FTS removal and an
      unread recount.
5. **Persistence.** The catch-up's own state is one nullable `Folder.catchUpState TEXT` column, added
   by `v98_addFolderCatchUpState`. NULL is the correct start for every existing folder. The UIDVALIDITY
   purge transaction (`AccountManager.uidValidityResetPurgeTxn`) clears it with the folder's other
   sync cursors. *Correction (2026-11-11):* this was first worded "There is one nullable
   `Folder.catchUpState TEXT` column", but it is not the only column the catch-up added.
   `v100_addFolderBackfillVersion` adds `Folder.backfillVersion` (INTEGER NOT NULL DEFAULT 0), the
   backfill bookkeeping's row version, so that the backfill walk never overwrites a catch-up re-arm
   (decision 8). *Renumbered (2026-11-11):* this migration was first `v99_addFolderBackfillVersion`;
   main shipped `v99_addFolderBackfillPageHeldSince` (#713) first, so it is v100. It never reached a
   release under the old name.
6. **IMAP** (`IMAPProviderCatchUp.swift`; the wire request `IMAPProvider.listFlagsInUIDRange`).
   - **Eligibility.** A folder is handled only if its stored epoch is known, it is not quarantined,
     and its path is non-empty. The state carries its epoch (`IMAPCatchUpState.epoch`); a state from
     another epoch is discarded and the listing restarts from UID 1.
   - **Cheap check, no request.** This pass's STATUS HIGHESTMODSEQ (`Folder.lastKnownHighestModSeq`,
     written by the folder upsert) is compared with the stored completion stamp.
   - **Full check.** It runs every `SyncConfig.catchUpFullCheckIntervalSeconds` (one day). It also
     serves as the only check on a server without CONDSTORE.
   - **Network.** On an expensive network only a MODSEQ change may list, because that is evidence of a
     change. *Superseded 2026-11-19 (#1063): scans always run; see the amendment of that date.* The full check, and continuing one already in progress, waits for a non-expensive
     network, but for no longer than `SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds` (7 days,
     owner 2026-11-10) since the folder's last completed listing. Before the first completed listing
     the wait counts from `createdAt` in the state, written on the catch-up's first sight of the
     folder (with no request, when the network holds it back). After the wait the network no longer
     holds the folder back. **So every folder gets a full catch-up at least every 7 days on any
     network**, plus the passes its listing needs; a device that is always on cellular or a
     hotspot is covered. ("Expensive" is `NetworkMonitor.checkExpensive()`, the path's `isExpensive`;
     Low Data Mode on Wi-Fi is not expensive and never waits.)
   - **Order.** The least recently ATTEMPTED folder goes first (`lastAttemptAt` in the state, written
     whenever a listing was tried, whether or not it succeeded; a completion is an attempt). A folder
     whose requests keep failing or timing out therefore goes behind the others and cannot hold
     their catch-up past the 7-day bound.
   - **Listing.** *Superseded 2026-11-20 (#1062): ranges are cut on UIDs from the held range's start,
     with a membership proof and direct loads; see the amendment of that date.* Ranges of `SyncConfig.catchUpListingRangeSpan` UIDs start at the first LOCAL UID at
     or above the cursor. For each range:
     - **Request 1:** SELECT, then `UID FETCH lo:hi (UID FLAGS)` on one folder connection. The range's
       epoch is this SELECT's UIDVALIDITY, and a mismatch applies nothing.
     - A local UID missing from the FETCH is a **candidate**, never a verdict (a short FETCH is real,
       MIS-IOS-002).
     - **Request 2:** `UID SEARCH UID <candidates>` (`searchExistingUIDs(folder:uids:)`, the walk's own
       absence proof) under the same epoch decides the removals.
     - A record without a UID makes the range unanswerable.
     - When the budget is spent before request 2, the range's flag updates still apply but the cursor
       stays, so the range is listed again. *Superseded 2026-11-20 (#1062): such a stop, and a failed
       SEARCH, are held under the bounded hold, see the amendment of that date.*
     - The cursor (`listing.nextUid`) is kept in the state across passes.
   - **The FIRST-stamp invariant.** The completion stamp is the HIGHESTMODSEQ taken BEFORE THE FIRST
     range: this pass's STATUS value, captured when the listing starts and carried unchanged in
     `listing.firstStamp`. It is never the last range's. A change to an already-listed range made
     while the listing is still running moves the server's counter past the first stamp, so the next
     cheap check lists the folder again.
     - *Deviation from the spec's wording ("per-range stamp from the SELECT"):*
       `Mailbox.Selection.highestModSequence` is NIOIMAPCore's type, which the app does not import, and
       STATUS of the same pass is already a stamp taken before every range. The per-range SELECT
       supplies the per-range EPOCH, which is what removal safety needs.
   - **The request stays inside the local range.** *Superseded 2026-11-20 (#1062): the upper bound is
     the larger of the last local UID and the bookmark's (else the listing's own) UIDNEXT - 1; see the
     amendment of that date.* Each FETCH runs from the range's first local UID
     to its LAST local UID, not to the end of the span. Mail above the highest local UID belongs to
     delta and full sync; mail below the lowest belongs to the backfill.
   - **The first stamp of a new folder.** The full sync's folder insert writes STATUS HIGHESTMODSEQ
     to the new row, as its update arm always did. Without it a new folder's first listing completed
     with no stamp, and the cheap check stayed off until the next full check.
7. **One removal path, two triggers.** There is one deletion core (`deleteConfirmedGhostHeaders`)
   and one absence proof (`UID SEARCH UID <set>` under the stored verified epoch). They are reached by:
   - IDLE VANISHED (unchanged);
   - the count-mismatch walk (unchanged; immediate when the server count proves ghosts);
   - the catch-up listing, which covers what a count cannot see: folders that are not fully
     backfilled, and a deletion offset by an arrival.

   The catch-up does not adopt the walk's count-based circuit breaker, because this population has
   no count evidence. Its removal needs two independent server statements instead: absence from the
   range FETCH and absence from `UID SEARCH`, both under the folder's epoch.
8. **Gmail** (amendment 2026-11-10; `GmailProviderCatchUp.swift`, `GmailCatchUpState`). The IMAP
   plan without a MODSEQ signal, keyed by order date instead of UID.
   - **Why Gmail needs it.** The history delta reaches every change only while its cursor is valid.
     When the history expires (404) or is too long for one delta, or when the full sync's capture
     replaces a cursor this pass's delta did not reach (a delta whose message GET failed, #464), the
     changes in the gap reach no delta. A change to older mail in that gap, and an All Mail read
     change beyond the window at any time, then never reached the device.
     *Amended 2026-11-11 (#731):* the delta now follows All Mail like every other folder
     (`GmailProvider.folder(_:containsMessageWithLabels:)`, built on `allMailExcludedLabelIds`, the
     one All Mail membership rule; the catch-up's removal proof asks the same rule). So while the
     cursor is valid every change reaches the device through the delta, All Mail included, and the
     catch-up is the safety net for the gaps above.
     *Amended 2026-11-12 (ADR-IOS-111):* the Gmail delta and the Gmail capture are deleted. The gaps
     are now a change-bookmark refusal (history expired or too long, `applyChangeRefusal`) and a
     re-read list over `changeRecheckLimit`; a message whose GET fails is put on the folder's re-read
     list and read again on later passes, so it opens no gap.
     *Amended 2026-11-19 (#1066, #726):* the same rule makes Trash and Spam exclusive: a message
     carrying TRASH or SPAM is a member of the Trash or Spam folder only, never of Sent, Drafts,
     Starred, a user label or the Inbox, whatever labels Gmail keeps on it (it keeps SENT, DRAFT,
     STARRED and user labels on trash). `folder(_:containsMessageWithLabels:)` answers false for
     those folders through `spamTrashFolderIds`, matching every listing outside Trash and Spam,
     which omits `includeSpamTrash`. So the change reader removes such a row and the catch-up's
     removal proof succeeds; before, a delete from Sent was put back into Sent by the re-read
     after the recent-completion hold. A message carrying both TRASH and SPAM (Gmail does not
     produce it) would show in both folders; accepted.
   - **Schedule** (amended 2026-11-12: no periodic check). `GmailProvider.catchUpPlan` lists a
     folder in exactly three cases: it continues a listing in progress (a lapse never interrupts
     one); it starts the folder's FIRST listing (no listing has completed yet: no state at all, or
     the state first sight wrote on an expensive network); and it starts a new listing after a lapse
     as soon as the listing in progress (if any) completes (the lapse marker, below). There is no
     periodic re-check: a tracked folder whose listing completed and that no lapse touched is never
     listed again. Shared with IMAP (`CatchUpSchedule`): on an expensive network at most
     `catchUpExpensiveNetworkMaxWaitSeconds` of waiting (`CatchUpSchedule.waitedTooLong`, kept); least
     recently attempted folder first; the pass budget before every request and
     `catchUpRequestTimeoutSeconds` on each. *Superseded 2026-11-19 (#1063): scans always run; see the amendment of that date.*
     - **Why no periodic check (owner 2026-11-12).** While the history cursor is valid the delta
       follows every folder, All Mail included (#731), and every lapse lists every folder again, so
       the weekly check only backed up what neither reveals: a change whose delta GET failed while
       the capture kept the cursor (#464). The owner dropped it. Cost accepted: such a change waits
       for the next lapse. *Amended 2026-11-12 (ADR-IOS-111):* that case is gone for Gmail; such a
       message is re-read on later passes from the folder's re-read list. Test: `GmailCatchUpTests.gmailHasNoPeriodicCheckAndIMAPIsDaily` (a tracked,
       completed folder with no lapse makes no request 8 days later; a lapse lists it).
     - *Superseded (2026-11-12, the weekly schedule):* "`CatchUpSchedule` (shared with IMAP): a full
     check every `gmailCatchUpFullCheckIntervalSeconds` (WEEKLY, amended 2026-11-11), and a new listing after
     a lapse as soon as the listing in progress (if any) completes (the lapse marker, below); on an
     expensive network at most `catchUpExpensiveNetworkMaxWaitSeconds` of waiting (first sight writes
     `createdAt` and makes no request); least recently attempted folder first; the pass budget before
     every request and `catchUpRequestTimeoutSeconds` on each." *Superseded (2026-11-11, before the
     lapse marker):* "and at once after a lapse, which clears the folder's state". *Superseded 2026-11-19 (#1063): scans always run; see the amendment of that date.*
     - **Only IMAP has an interval** (amended 2026-11-12). `CatchUpSchedule.fullCheckDue` is called
       by `IMAPProvider.catchUpPlan` alone, with `catchUpFullCheckIntervalSeconds` (one day). Nothing
       above `EmailProvider` names a provider or an interval. *Superseded (2026-11-12):* the bullet
       below.
     - **Each provider chooses its own interval, below the boundary.**
       `CatchUpSchedule.fullCheckDue(lastCompletedAt:now:interval:)` takes the interval as an
       argument; `GmailProvider.catchUpPlan` passes `gmailCatchUpFullCheckIntervalSeconds` (7 days)
       and `IMAPProvider.catchUpPlan` passes `catchUpFullCheckIntervalSeconds` (one day, unchanged).
       Nothing above `EmailProvider` names a provider or an interval.
     - *Superseded (2026-11-12, no periodic check):* the two bullets below ("Why weekly",
       "Consequences of the week"). Their point about the length of a listing still holds: a
       listing spans many full syncs, so the repair after a lapse takes, newest first, one full sync
       for this week's mail and up to one listing for mail of any age.
     - **Why weekly (owner 2026-11-11).** With #731 the delta reaches every change while its cursor
       is valid, and after a lapse every folder is listed again, newest first, as soon as its
       listing in progress completes. The regular check only backs up what no delta and no lapse
       reveals (for example a change whose delta GET failed while the capture kept the cursor). The
       owner accepted that such mail may take up to a week to appear. *Corrected (2026-11-11):* a
       listing is not one full sync. Each full sync gives the whole catch-up
       `catchUpPassBudgetSeconds` (2 s), and a range costs three list requests, so a folder holding
       ten years of mail (about 520 week-long ranges, about 1,570 requests) takes about 220 full
       syncs at 300 ms a request, many hours of foreground time. So "up to a week" is a week plus
       up to one listing of that folder, and the repair after a lapse takes, newest first, one
       full sync for this week's mail and up to one listing for mail of any age, however often
       lapses come. The earlier wording ("a lapse clears the catch-up state, so every folder is
       listed in full at the next full sync anyway") was false for any folder that needs more than
       one full sync to list.
     - **Consequences of the week.** The expensive-network wait is counted from the last completed
       listing and is as long as the week, so a due weekly check has already waited as long as the
       wait allows and runs on any network; only a folder with no completed listing (new, or reset)
       waits for a non-expensive network. *Superseded 2026-11-19 (#1063): scans always run; see the amendment of that date.* A lapse does not restart that wait and does not skip it:
       the marker keeps `createdAt` and `lastCompletedAt`, so a listing a lapse asks for on an
       expensive network waits until `catchUpExpensiveNetworkMaxWaitSeconds` after the last
       completed listing, like any other. *Superseded (2026-11-11):* "(new, or cleared by a lapse)":
       a lapse that cleared the state restarted the wait, so with lapses more often than weekly an
       always-expensive device never listed. And while an id stays missing, each weekly
       check re-arms the folder once (one ids-only re-walk per week, the bound below). *Note
       (2026-11-11):* this week is why the re-arm record was removed; it held back no re-arm here.
     - *Superseded (2026-11-10):* "a full check every `catchUpFullCheckIntervalSeconds` (daily)".
     Every number is in `SyncConfig`
     (`catchUpGmailRangeRowLimit`, `catchUpGmailRangeMaxSpanSeconds`, `catchUpGmailRangeSlackSeconds`,
     `catchUpGmailListPageSize`; `catchUpMissingIdsRecordLimit` was removed with the re-arm record,
     2026-11-11, and `gmailCatchUpFullCheckIntervalSeconds` with the weekly check, 2026-11-12).
     The network state comes only from the `CatchUpContext` snapshot.
   - **Ranges by order date, newest first** (amended 2026-11-11). The reader's order-date accessors
     (index `(folderId, providerDate)`) are `newestRows(folderId:orderDatesBefore:limit:)` (the
     newest rows before a bound, descending) to cut a range and `rows(folderId:orderDatesFrom:before:)`
     (every row in a range, ascending) to read it. A listing starts at the newest local row and
     works back: each range holds at most `catchUpGmailRangeRowLimit` rows (unless more share its
     newest second), starts on a whole second (rows sharing the cut second go to the next, older
     range), and its local rows span at most `catchUpGmailRangeMaxSpanSeconds` back from its newest
     one. `CatchUpRange` is `from` (inclusive), `firstLocal` and `localEnd` (the range's oldest and
     one past its newest local row when it was cut) and `upTo` (exclusive: the previous, newer
     range's `from`, or the first range's `localEnd`). The cursor `listing.nextBeforeSecond` resumes
     across passes. The membership list covers `[from, upTo)` and the flag lists only
     `[firstLocal, localEnd)`, each widened by `catchUpGmailRangeSlackSeconds`, so a sparse folder
     never asks for the account's flags over a long empty stretch, and a row that arrived in a
     range's stretch outside its local rows after the range was cut keeps its flags. A listing
     that starts while the folder's walk is complete and no storage limit is in force
     (`Listing.toEpoch`, set when the listing starts) extends its OLDEST range, the one that holds
     every remaining row, down to 0, so that range's membership list also covers mail older than
     every local row; no `after:` bound is ever below 0. Under a storage limit the oldest range ends
     at the oldest local row (next bullet). Why newest first: recent mail is where a change the
     user notices sits, and a listing that a lapse asks for reaches this week's mail at the next
     full sync instead of after every older range. *Superseded (2026-11-11), oldest first:* "Ranges
     are cut from the LOCAL rows' `providerDate` (Gmail's `internalDate`) through the reader's new
     order-date accessor (`rows(folderId:orderDatesFrom:before:limit:)`, index
     `(folderId, providerDate)`): at most
     `catchUpGmailRangeRowLimit` rows (unless more share the first second), whole seconds, at most
     `catchUpGmailRangeMaxSpanSeconds` from the range's first local row. Ranges tile the local range
     without gaps; the cursor (`listing.nextFromSecond`) resumes across passes. Every list carries
     `after:`/`before:` bounds widened by `catchUpGmailRangeSlackSeconds` only. A listing that starts
     while the folder's walk is complete starts its first range at 0 (decision 1, amended
     2026-11-11), so that range's membership list also covers mail older than every local row; its
     `after:` bound is never below 0. The flag lists still start at the range's first local row, and
     no list reaches above the newest local row." Within that superseded text, *superseded
     (2026-11-10):* "so no request reaches outside the local range."
   - **No old mail is loaded back under a storage limit** (amended 2026-11-12, the direct load:
     what holds now is that a new Gmail listing under a storage limit lists nothing older than the
     folder's oldest local row, so the direct load loads nothing older back. The re-arm and its
     decline are gone. A message the server lists BETWEEN kept rows is loaded like any missing id:
     the prune deletes oldest first by `date`, so such an id is rare (a row whose `providerDate` and
     `date` order differently) and costs one load until the next prune. Test:
     `GmailCatchUpTests.storageLimitLoadsNothingBelowTheOldestKeptRow`, which replaces
     `storageLimitStopsTheReload`.) Its text as of 2026-11-11 follows. When the step
     starts, `runCatchUp` snapshots whether the user's Email Index Limit is finite
     (`StorageEstimator.budgetMB != Int.max`) into `CatchUpContext.storageLimitInForce`; nothing
     reads the limit again during the step (root rule: snapshot settings at operation start). While
     it holds, the apply re-arms no backfill walk (`applyCatchUpTransaction`), and a new Gmail
     listing does not reach down to the epoch: it lists nothing older than the folder's oldest
     local row (less the slack). Why: the storage prune (ADR-IOS-006) deletes the oldest rows once
     the store passes the limit, so every check would find the pruned mail missing, re-arm, and
     the walk would download it again only for the prune to delete it again, every week, for every
     folder past the limit. The prune orders by `date` and the ranges by `providerDate`, so pruned
     ids sit between kept rows too; declining the re-arm, not only the epoch start, is what ends
     the churn. **The trade-off:** with a storage limit set, old mail moved into a folder (older than
     the newest rows, which the sync windows reach) is not loaded, and neither is a message the
     walk passed over because its fetch failed. That is what the limit means: old mail is not kept.
     Flags and removals of the rows that are kept are still caught up. With no limit (the default),
     nothing changes. Tests: `GmailCatchUpTests.storageLimitStopsTheReload`,
     `productionSnapshotTakesTheStorageLimit`.
   - **Per range.** The folder's membership list (`listMessageIdsPage` with a date window, extended),
     then the account-wide `is:unread` and `is:starred` lists over the same dates
     (`listAccountMessageIdsPage`). Flags come only for local rows the membership list names, and
     account-wide lists make them immune to a move between requests. A range counts only when all of
     its lists finished. Each list resumes at its saved page token (`listing.range`), so a budget stop
     or failure loses no page and a range whose lists need more requests than one pass allows still
     completes over several passes. The saved range keeps only what concerns its own local rows (the
     rows the membership list named, with their flags when it completed, and which of them the unread
     and starred lists named), so its size is bounded by the range's row count. A named row whose
     local flags changed after the membership list completed (a later delta, the user) gets no update
     from the range: its pages may be older than that change.
   - **Spam and Trash only where they belong** (amendment 2026-11-11). What the code relies on
     (narrowed 2026-11-11): a search (`q`) list and a list of any label other than SPAM or TRASH
     leave Spam and Trash mail out unless `includeSpamTrash` is sent, while a list by
     `labelIds=TRASH` or `SPAM` returns that folder's mail without it (the Spam and Trash walks list
     that way, and their re-arms load through it). Google's `users.messages.list` reference
     documents the flag ("Include messages from SPAM and TRASH in the results", unsent = false) but
     not how it combines with `labelIds`. *Superseded wording (2026-11-11):* "Gmail leaves Spam and
     Trash mail out of a list that does not send `includeSpamTrash`", which, read literally, would
     leave the Trash and Spam walks empty. The
     membership list sends it only for the Spam and Trash folders' own lists
     (`GmailProvider.spamTrashFolderIds`, `messageListPath`); the account-wide unread and starred
     lists always send it, so a Spam or Trash row's flags still arrive. Every other folder's check
     therefore lists what its walk lists: a message in a label that is also in Trash or Spam is not
     missing there and re-arms nothing. *Superseded (2026-11-10):* every windowed list sent
     `includeSpamTrash`, so such a message re-armed its label's walk at every check for nothing. A
     live check on a test account found no labelled message in Trash to decide it, so this rests on
     Google's documented behaviour; if the live API included that mail anyway, the outcome is the
     earlier behaviour (a wasted re-arm), never worse.
   - **A refused page token restarts its list once per pass** (amendment 2026-11-11). Gmail documents
     no wording for a page token it no longer accepts (an invalid value is a `400`, `badRequest`), so
     any `400` to one of the catch-up's own list requests (membership, unread, starred) that carried a
     saved token drops the token and starts that list again from the range's start, its pages so far
     dropped. The bound is once per list per pass and is held in memory inside `catchUpFolder`; it is
     never saved in the state. A second `400` in the same pass stops the pass like any other failure,
     and the next pass resumes the list where it stopped, and may start it over once again. A saved
     bound would stall a list for good once a later pass found its fresh token refused too. The
     catch-up's own lists keep a `400`'s body (`requestPreservingBadRequestBody`) only so that the
     debug-gated log line can name the structured reason (`GmailProvider.badRequestReason`).
   - **Removal needs proof.** A local row the membership list leaves out is only a candidate. Its own
     `GET format=minimal` decides: 404/410 removes; labels without the folder's label remove; for All
     Mail, labels carrying INBOX, SENT, TRASH, SPAM or DRAFT (what All Mail's query excludes) remove;
     any other answer, including an unreadable one for that message, keeps the row. A failure that is
     no answer (a dropped connection, a timeout) ends the folder's pass. Removals go only through
     `deleteConfirmedGhostHeaders`.
   - **Candidates carried across passes.** A range's candidates are saved in the state
     (`listing.pendingCandidates`) and verified before the next range, so a range whose GETs run past
     the budget is never listed again for them (liveness on a slow link).
   - **Never inserts; placeholders.** *Superseded (2026-11-12, the direct load):* "Results carry no
     new rows." Results carry the loaded missing messages (next bullet). A synthetic placeholder id
     (`isSyntheticPlaceholderId`) is never named in a request, never removed, and never counted as
     missing. Results carry `epoch: nil`; Gmail folders have no known epoch, so the gate passes and the
     `.date` window mode applies.
   - **Missing mail is loaded by the check: the direct load** (owner ruling 2026-11-12). An id a
     membership page names that no local row in the folder holds (mail moved in, mail older than
     every local row in an epoch listing, or new mail beyond the sync window after a lapse) is
     missing. Before that page's token moves on, `GmailProvider.loadMissing` fetches the page's
     missing ids, newest first (the list's own order), through the backfill's own fetch
     (`fetchBackfillBatch`: header and body in one `format=full` GET), in batches (decision 3).
     *(Amended 2026-11-13: `GmailProvider.loadMissing` is gone; the load is the shared
     `CatchUpDirectLoad.load` in `CatchUpListing.swift`, which Outlook uses too. The sentence is kept
     as written.)*
     - **A range moves on only once its missing ids are done.** A page's token is saved only after
       every missing id on it has loaded or been classified done. If the budget runs out part way,
       the range keeps the page's token as it was and the next pass lists the same page again, where
       what loaded is no longer missing. No id list is kept in the state. *Amended 2026-11-12
       (the hold bound under the pass budget):* that holds while the pass loaded some of the
       page's ids. When the loads stop on the budget with nothing loaded (every id asked for was
       held, or the budget ran out before any was asked for), the page is held (next bullet but
       one), so it is listed again for at most the hold bound. *Amended 2026-11-12:*
       within one pass, an id the pass already loaded counts as held (`loadedThisPass` in
       `catchUpFolder`), because the loads are inserted only after the provider returns. So an id
       listed again in the same pass is never fetched or inserted twice: a listing that completes
       and restarts at once after a lapse, a list restarted after a `400` on its saved token, and
       the `catchUpGmailRangeSlackSeconds` overlap where two ranges' membership windows meet.
       *Superseded:* "missing" was decided from the local rows alone, so such an id was loaded
       twice and the duplicate rolled back its whole insert chunk (up to
       `backfillInsertChunkSize` messages), after which the state moved the listing past them.
     - **Classification** (the page walk's own rule, `SyncEngine.backfillFetchFailureKind`). Gone or
       about the message (404/410, any other 4xx except 401/403/429, a `DecodingError`, an answer
       with no header) counts as done at once. Transient (5xx, 429, 403, a connection error, no
       answer within the timeout) holds the range.
     - **The unloadable-id bound.** A held range is held for at most `SyncConfig.backfillPageHoldMinutes`
       (60) wall-clock from its FIRST hold (`RangeScan.loadHeldSince`, on the page walk's hold clock
       `SyncEngine.backfillPageHoldNow`, decided by `SyncEngine.decideBackfillPage`); past that, the
       id counts as done, like a per-message failure, and the range moves on. The first-hold time is
       an additive optional field in the `catchUpState` JSON (no migration) and goes with the range
       when the range moves on. No new constant. An id counted done is tried again at the next
       listing (after the next lapse). *Amended 2026-11-12 (per page):* `loadHeldSince` is cleared
       whenever the list's page moves on (its token is saved, or restarted after a `400`), as the
       walk clears `backfillPageHeldSince` with every write of its token, so the bound runs from the
       first hold of the page now held. *Superseded:* "from its FIRST hold" counted per range and was
       never reset by a page that loaded, so a hold on a later page of the same range more than the
       bound after an earlier page's hold passed its ids over on their first failure. A batch whose
       timeout fires holds every id it has no answer for (the bound above still applies; on a
       persistently slow link those ids count as done after it, the trade-off already stated).
       *Amended 2026-11-12 (the hold bound under the pass budget):* the bound
       applies wherever the loads stop. When they stop on the pass budget, the page is held if this
       pass loaded none of its ids (every id asked for was held, or the budget ran out before any
       was asked for, as when the membership list alone spends it): the clock starts or is kept,
       and once the bound has passed, the held ids and the ids not yet asked for count as done and
       the page moves on (the listing goes on with the next page or list, and completes). When they
       stop on the budget after loading some, the page is moving: it is listed again on the next
       pass and its clock is cleared, so a page whose loads keep moving is never passed over for an
       earlier hold, and every loadable id on it loads. The pass budget and the request timeout are
       unchanged. Tests: `GmailCatchUpTests.budgetStoppedHoldStartsTheClock`,
       `slowLinkHoldEndsAtTheBound`, `budgetStopAfterLoadsRestartsTheHoldClock`. *Superseded:* the
       budget stop came before the hold handling, so on a slow link (a batch that always times out
       past a budget smaller than one batch, or a list that alone spends the budget) the clock
       never started, the bound was never consulted, and every pass listed the same page again for
       as long as the link stayed slow.
     - **The insert** is the page walk's insert tail, extracted test-first into one helper
       (`SyncEngine.insertFetchedBackfillMessages`, called by the walk and by the apply): the batch
       insert (which skips an id protected by a pending destructive op), the search index, FTS
       bodies, snippets and `bodyComplete` for confirmed bodies, and the `BackfillBodyQueue`
       enqueue. A missing id refused by the insert (a queued op) is loaded at a later listing.
       *Amended 2026-11-12 (loads that did not land):* the helper returns whether every write chunk
       landed (`allLanded`), and neither caller moves past rows that did not: the apply writes no
       state (decision 4.1), and the page walk keeps its page token and skips the folder for the
       rest of the call, so the next call lists the same page again. And a duplicate id inside one
       chunk no longer rolls the chunk back: the batch insert (`insertBackfillBatchGuardable`)
       skips an id the chunk has already inserted. That is safe for every caller because a
       primary-key hit there can only be such a duplicate (the existence check inside the chunk's
       transaction already covers every row of the folder, and the key is account, folder path and
       id), and each call carries ids from one id space: a Gmail or Graph id names one message, and
       an IMAP UID names one message under the single epoch the call carries (its insert is gated on
       that epoch). A UID reused after a UIDVALIDITY reset is not a duplicate within a chunk: it
       meets the existence check against the old row, which the reset's purge removes, never the
       primary key. *Superseded:* the chunk's existence check was read once before its loop, so a
       second entry for the same id hit the primary key and rolled back the whole chunk, neighbours
       included.
     - **The walk is never touched.** The check writes none of the walk's bookkeeping
       (`backfillComplete`, `backfillPageToken`, `backfillPageHeldSince`, `backfillVersion`),
       whatever the walk's state; an unfinished walk goes on from its page. `walkColumnWritesAreNamedSites`
       lists one site fewer (the re-arm in `SyncEngineCatchUp.swift`).
     - **Why** (owner 2026-11-12). After a lapse, new Inbox mail beyond the full sync's window had no
       row: the re-arm was declined for an unfinished walk and under a storage limit, and an
       accepted re-arm restarted a walk that lists from the top down, so new mail below the window
       waited for a whole re-walk. Tests: `GmailCatchUpTests.lapseLoadsNewMailBeyondTheWindow`
       (walk complete, unfinished, storage limit), `directLoadResumesAcrossPasses`,
       `goneMissingIdNeverWedgesARange`, `failingMissingIdHoldsTheRangeUntilTheBound`,
       `seededDirectLoadProperty` (replacing `seededRearmProperty`).
   - *Superseded (2026-11-12, the direct load): the re-arm.* The bullets below ("Moved-in mail
     re-arms the backfill", "Only a completed walk is re-armed") describe the re-arm as it was.
     What still holds from them: what leaves an id missing, and that each listing is a fresh
     chance to load. Removed: `CatchUpFolderResult.rearmBackfill`, `Listing.foundMissing`, the
     re-arm write and the `storageLimitInForce` decline in `applyCatchUpTransaction`.
   - **Moved-in mail re-arms the backfill** (amended 2026-11-11: the re-arm record is removed). When
     a check's listing completes, the server ids it listed that no local row in the folder holds (an
     old message moved or archived into the folder) are missing.
     - **When a check asks.** The result sets `rearmBackfill` when the completed listing found a
       missing id (`listing.foundMissing`). Nothing about earlier re-arms is kept.
     - **The re-arm.** The apply writes `backfillComplete = 0, backfillPageToken = NULL,
       backfillPageHeldSince = NULL` in the SAME transaction as the state (the page hold time belongs
       to the token it clears, like every other write of `backfillPageToken`; added 2026-11-11 with
       #713's column). A declined re-arm (next bullet) writes the same state.
     - **What leaves an id missing** (named 2026-11-11). Mail moved in from elsewhere below every
       window that no delta brought (a lapse; *superseded:* "a lapse (the state is cleared)"); and
       a fetch that failed during the
       walk: the walk passes over a message whose `format=full` GET fails about that message (a
       per-message failure) or keeps failing past the page hold bound (#713), completes without it,
       and the next check finds it missing and re-arms. Test:
       `GmailCatchUpTests.idPassedOverByTheWalkLoadsAtTheNextCheck`. *Note (2026-11-12, no periodic
       check):* the next check of a tracked folder is the listing after the next lapse.
     - **Bounds.** Ids that stay missing cost at most one re-arm per completed listing per folder:
       the first listing, plus the listing after each lapse (*superseded 2026-11-12:* "one per week
       on the weekly schedule, plus the listing after each lapse"; *superseded:* "plus the check
       after each lapse"); none while a storage limit is in force. Each try is a fresh chance
       to load, so an id whose cause passed (a queued op removed, a server error over) loads at the
       next check. One re-arm costs one ids-only re-walk of the folder (about one list request per
       500 messages) and one `format=full` GET per id still missing.
     - The catch-up itself still never inserts: the existing insert-only backfill walk loads the
       mail.
     - *Superseded (2026-11-11): the re-arm record, removed.* It held back no re-arm on the shipped
       weekly schedule: every completed check comes at least `catchUpRearmRetryIntervalSeconds` after
       the last re-arm, and a lapse clears the record with the rest of the state, so it only added
       state, config and tests. Removed with it: `GmailCatchUpState.recordedMissingIds` and
       `rearmedAt`, `Listing.missingIds` and `foundUnrecordedMissing`, `CatchUpBackfillRearm`
       (`stateIfWalkUnfinished`), `SyncConfig.catchUpMissingIdsRecordLimit` and
       `catchUpRearmRetryIntervalSeconds`. It was JSON inside `catchUpState`, so no column or
       migration changes. Its wording before removal:
     - **Moved-in mail re-arms the backfill** (amended 2026-11-11: the record expires). When a check's
       listing completes, the server ids it listed that no local row in the folder holds (an old message
       moved or archived into the folder) are the missing set. The state keeps the ids the last re-arm
       was for (`recordedMissingIds`, the first `catchUpMissingIdsRecordLimit` in listing order) and when
       that re-arm was made (`rearmedAt`, optional, so a state saved without it still decodes).
       - **When a check asks.** The result sets `rearmBackfill` when the missing set is not empty and
         either the last re-arm is at least `catchUpRearmRetryIntervalSeconds` (7 days) old or there was
         none, or a missing id is not in the record while the record has room.
       - **The record changes with the re-arm.** The apply writes `backfillComplete = 0,
         backfillPageToken = NULL, backfillPageHeldSince = NULL` in the SAME transaction as the state
         (the page hold time belongs to the token it clears, like every other write of
         `backfillPageToken`; added 2026-11-11 with #713's column), and that state carries the new
         record and `rearmedAt`. A declined re-arm (next bullet) changes neither. A check that asks for
         nothing and finds no missing id outside the record shrinks the record to the missing set, so
         an id loaded since leaves it at the next such check.
       - **Why the record expires.** Whether an id can load is only known by trying, and it changes: a
         destructive op queued for it in that folder is removed later, or its `format=full` GET failed
         once and the walk moved on past it. A record without an expiry kept such an id out of every
         later re-arm, and so did one holding an id that loaded and then moved out and back with no
         check in between: the message never appeared. With the expiry the record only delays another
         try, by at most the interval.
       - **Why the record is kept** (2026-11-11, corrected). It bounds the re-arms of a check that
         completes sooner than `catchUpRearmRetryIntervalSeconds` after the last re-arm. On today's
         schedule none does: the weekly check comes no sooner, and a lapse clears the record together
         with the rest of the state, so the post-lapse check re-arms whatever is missing (the "plus one
         after each lapse" in the bounds). What it still bounds is a check run off that schedule, or a
         device clock set back. It is kept by ruling (2026-11-11), and it is used only by the Gmail
         catch-up, not by IMAP.
       - **Bounds.** Ids that stay missing cost at most one re-arm per interval per folder, plus one
         after each lapse (which clears the record), however many there are. Past the record limit a
         newly missing id also waits for the interval, so a folder with more unloadable ids than the
         limit does not re-walk at every daily check. One re-arm costs one ids-only re-walk of the
         folder (about one list request per 500 messages) and one `format=full` GET per id still
         missing. *Note (2026-11-11, weekly check):* the regular check now comes no sooner than the
         interval, so these bounds are met by the schedule itself and the record holds nothing back
         (Schedule, above); it would matter again only if a Gmail check ran more often than
         `catchUpRearmRetryIntervalSeconds`.
     - *Superseded wording (2026-11-10):* "If it holds an id not recorded at the previous completed
       check, the result sets `rearmBackfill` [...] The state records the missing set
       (`recordedMissingIds`, the first `catchUpMissingIdsRecordLimit` in listing order), replaced at
       every completed check. So an id the backfill cannot load (a destructive op queued for it in
       that folder) re-arms once and then stays recorded; a later move re-arms once more; an id loaded
       and later missing again counts as new. Over the limit, the unrecorded id re-arms at most once
       per daily check, and only a completed walk (next bullet). A lapse clears the record (at worst
       one extra re-arm)."
   - **Only a completed walk is re-armed** (amendment 2026-11-11). The apply re-arms only when the
     folder's `backfillComplete` is 1, read from the folder row inside the SAME transaction as the
     re-arm and the state write (`applyCatchUpTransaction`), not from the folder the provider listed:
     the walk can complete, or a reset can unfinish it, between the listing and the apply, and the
     write transaction is the only read that no walk write can overtake. Why: the re-arm writes
     `backfillPageToken = NULL`, so re-arming an unfinished walk throws its position away. A folder
     whose local range reaches below the walk's position (an old message moved in) lists every
     not-yet-walked id as missing; such checks would keep asking for a re-arm, and a folder too large
     to walk between two of them could then restart from the top each time and never complete.
     Declining loses nothing: the walk goes on and loads everything below its position, and the
     first check after the walk completes asks again for whatever is still missing; that walk then
     loads anything above the old position. *Superseded (2026-11-11, record removed):* "A declined
     re-arm writes the result's `CatchUpBackfillRearm.stateIfWalkUnfinished`, which is the new state
     without the record change (the previous record and `rearmedAt` kept), so the first check after
     the walk completes asks again for whatever is still missing outside that record, or for anything
     missing once the record is old enough; that walk then loads anything above the old position." Cost: mail moved in above an unfinished walk's position loads up to one
     check interval after the walk completes. The backfill-version compare-and-set below is
     unchanged: two walks are not serialized, so a second walk can complete a folder and a re-arm
     land while the first walk's iteration is in flight.
   - **The backfill walk never overwrites a re-arm** (amendment 2026-11-11). *Note (2026-11-12, the
     direct load):* there is no re-arm any more; the compare-and-set on `Folder.backfillVersion` is
     kept, because it still keeps a walk iteration from overwriting a reset or a second walk's
     write made while its page was in flight. The re-arm can land
     while a page-token walk iteration (Gmail and Exchange, `SyncEngine.runBackfill`) is waiting on
     its page; no serial gate covers both (`oneSyncAtATime` serializes the sync passes, and the walk
     does not take it). Since only a completed walk is re-armed, that takes a second walk (the
     foreground loop and a background run are not serialized either) completing the folder while the
     first walk's iteration is in flight. The walk's two bookkeeping writes, the next page token and the folder's
     completion (`SyncEngine.advanceBackfillPageWalk`), are therefore compare-and-set on
     `Folder.backfillVersion` (v100; first numbered v99), read with the folder at the start of the iteration. The trigger
     `folder_bumpBackfillVersion` bumps it on every UPDATE that writes `backfillPageToken` or
     `backfillComplete`, even when the value is unchanged, and never on an insert (a new folder
     starts at 0). Every writer bumps it without naming it: the re-arm, the walk's own writes, the
     IMAP walk's completions, the fast-sync and Settings resets, the startup resets, the
     UIDVALIDITY reaction's whole-record folder updates, and `SyncEngine.fullSync`'s folder-list
     upsert (added to this list 2026-11-11). The upsert is a whole-record `existing.update(db)` of a
     row read in the same transaction: it names both columns with their values unchanged, so every
     existing folder's version moves once per full sync, and a walk iteration in flight then misses
     its compare-and-set and lists the same saved page once more (one extra list request, bounded).
     *Amended 2026-11-12 (ADR-IOS-111):* the upsert (`applyFolderList`) now runs on every change read
     with a folder list too (each Gmail poll and push wake), so it writes the row column by column
     (`updateChanges(db, from:)`): it names neither backfill column and bumps no version.
     Every whole-record writer reads its row in the same transaction, so none writes an older
     version back; a future whole-record write from a stale record would. The check is the version ALONE, not the
     token and completion it read: a re-arm of a folder whose walk is at its top (no token, not
     complete) writes exactly that state, so a value comparison still matches and the walk would
     move on from a page answered before the move, past the moved-in message. A write that matches
     no row stops that folder's iteration; the next iteration re-reads the folder and walks on from
     what it then holds: from the top after a re-arm or a reset, the same saved page again after a
     write that changed neither column (*superseded:* "and walks it from the top"). It never
     retries the stale write. SQLite's change count excludes the trigger's own
     update, so it reports the walk's statement alone.
     - **One version for every walk, never repeated** (amendment 2026-11-12,
       `v101_backfillVersionCoversUidCursorAndNeverRepeats`; v100 unchanged). Two changes to the
       contract above. (1) The trigger now also fires on every UPDATE that writes
       `backfillUidCursor`, and the IMAP UID walk's six bookkeeping writes (the UIDNEXT 1
       completion, the initial cursor, the two throttled progress writes, the final completion, the
       final cursor) go through `SyncEngine.writeUIDWalkPosition`: the UIDVALIDITY guard
       (`crawlWalkWriteAllowed`) AND a compare-and-set on the version the walk read with the folder
       (`UIDWalkPosition`). A write that lands reads the version it left back in its own
       transaction, so the walk never refuses a position it wrote itself. A version miss marks the
       position lost: the workers stop claiming ranges, the pass skips its final writes and declines
       the folder for the rest of the call (the IMAP walk's existing refusal shape; the page walk
       re-reads instead), and the next call walks on from what the folder then holds. A refused
       write is no work for the call's `didWork`. This closes the IMAP side of the overwrite: a
       user reset (Reset Message Data, the Settings wipe, Smart Reindex) or a second walker writing
       the cursor or the completion while a batch was in flight, which the epoch guard cannot see
       because none of them touches UIDVALIDITY. The full-sync upsert costs the IMAP walk at most
       the progress since its last throttled write (one second) per full sync. (2) Every version
       is drawn from one database-wide counter (`backfillVersionCounter`, one row, seeded with the
       highest existing version), on a bump and on an insert (`folder_seedBackfillVersion`).
       `Folder.id` is the deterministic `"\(accountId):\(path)"`, so a folder deleted and re-created
       under the same id used to start again at 0 and could climb back to the exact version an
       in-flight walk of the old row had read (ABA), landing that walk's write on the new row. A
       whole-record write from a stale record is also overwritten by a fresh value now.
       *Superseded (2026-11-12):* "bumps it on every UPDATE that writes `backfillPageToken` or
       `backfillComplete`, even when the value is unchanged, and never on an insert (a new folder
       starts at 0)" and "a future whole-record write from a stale record would [write an older
       version back]".
       - **The walk's own version is recorded when its write commits** (2026-11-12).
         `writeUIDWalkPosition` still reads back, in its own transaction, the version its write
         left, but the walk takes it as its own only when that transaction commits
         (`Database.afterNextTransaction(onCommit:)`). A transaction that rolls back (an error at
         COMMIT, or a later statement in it failing) puts the row and the counter back, and the
         next bump in the database then issues that same version again; recorded before the
         commit, it let the walk's next write match and write over a reset's or a sibling's
         write. A rolled-back write leaves the walk's version unchanged, and rollback is
         deliberately not handled: the row is back at the version the walk expects, so the next
         write lands if nothing else wrote, and any later bump makes it miss. Do not move the
         record back into the transaction, and do not add a rollback handler that restores or
         advances it. *Superseded (2026-11-12):* "A write that lands reads the version it left
         back in its own transaction, so the walk never refuses a position it wrote itself" (the
         read-back stays; the record moved to the commit).
     - **A failed insert chunk is reported to every IMAP caller** (amendment 2026-11-12). The
       premised `SyncEngine.insertBackfillBatch` returns `.landed(…, allLanded:)`, false when a
       write chunk's transaction threw (the same report the premise-less overload gives as
       `failed`, which the page walk and the catch-up already honour). The IMAP walk fails that
       range rather than confirming it (its cursor stays above it) and declines the folder for the
       rest of the call; self-heal puts its hourly stamp back, so the next sync's self-heal loads
       the messages.
   - **The delta-cursor lapse** (`SyncEngine.lapseDeltaCursor`; amended 2026-11-11: a marker, not a
     clear). One provider-blind helper writes the account's new cursor (nil clears it) AND marks the
     lapse in `catchUpState` for every folder of the account, in the caller's transaction: the
     integer under `CatchUpLapse.countKey` (`lapseCount`) in the state's JSON object goes up by one,
     an additive field in the existing column, so no migration. A NULL state stays NULL (no state
     already means a full check is due, which a new folder and a reset rely on); a state that is not
     a JSON object becomes NULL, the same start. It is used by the Gmail delta's clear arm (history
     expired or too long) and by `captureSyncCursors` when it replaces a cursor this pass's delta did
     not reach. A cursor the pass's delta DID reach is now kept (`deltaReachedCursor`), so the next
     delta reads every change made since, including those made during the full sync.
     *Amended 2026-11-12 (ADR-IOS-111):* for Gmail both callers are deleted; `applyChangeRefusal`
     (a refused change bookmark) is the Gmail caller now, and a new bookmark is stored with no lapse
     mark. The Exchange arm of `captureSyncCursors` is unchanged.
     - **What Gmail does with the marker.** A listing in progress goes on from its place; nothing
       about it is lost. Each listing records the count when it started (`lapseCountAtStart`), and a
       completed listing stores it (`listedLapseCount`). When a listing completes and a lapse came
       after it started (`GmailCatchUpState.lapsedSinceLastListing`), a new listing starts at once,
       in the same pass (on an expensive network it waits like any listing), because a change the
       lost history held may sit in a range that listing had already passed. *Superseded 2026-11-19 (#1063): scans always run; see the amendment of that date.* With no listing in
       progress, the plan starts one at the next full sync. *Amended 2026-11-12 (#766):* at the
       backfill worker's next slice, which the next poll's worker (or the background job) runs; no
       full sync is needed. So a change is repaired within at most
       two listings' worth of ranges: the rest of the listing in progress, then the new one, newest
       first, however often lapses come. The lapse runs under the account's one-sync-at-a-time
       lock, as the catch-up does, so no catch-up reads a state before a lapse and writes it after.
     - The lapse survives a relaunch because it is persisted with the cursor.
     - *Superseded (2026-11-11):* "AND clears `catchUpState` for every folder of the account [...]
       Cleared state makes the next full sync's catch-up list every folder in full, which is what
       finds the changes the lost history held." A clear threw away the listing in progress, so
       lapses more frequent than one listing kept restarting it from the start, and the ranges it
       reached last were never repaired.
     - Tests: `GmailCatchUpTests.lapseHelper`, `lapseKeepsTheListingsProgress`,
       `changesAreRepairedDespiteRecurringLapses`, `newestRangeIsListedFirst`,
       `lapseKeepsTheExpensiveNetworkWait`, the plan, G2 and G3. *Superseded 2026-11-19 (#1063): scans always run; see the amendment of that date.*
   - **Costs.** A lapse costs one more listing of each folder after the one in progress; lapses
     that come while a listing runs share that one. A delta failure in a pass with a due full sync
     is such a lapse. *Superseded (2026-11-11):* "A delta failure in a pass with a due full sync
     clears the catch-up state that pass's full sync just wrote, so the next full sync lists again
     (one extra listing). More generally (amendment 2026-11-11), every lapse clears ALL listing
     progress, saved pages included, so repeated lapses can keep restarting the listing of a folder
     too large to list within the passes between two lapses: more than one extra listing. It is
     bounded: the listing completes once deltas succeed and no lapse interrupts it." That bound was
     conditional, and recurring lapses never met the condition. The slack of
     `catchUpGmailRangeSlackSeconds` may count a message within one second outside the local range as
     missing (at worst one extra re-arm). A row whose stored `providerDate` differs from Gmail's
     `internalDate` is not known to exist: `providerDate` is Gmail's `internalDate` on every write
     path (parse, every sync, backfill and delta insert or refresh, NSE staging, copies), and rows
     from before v91 hold it too, because Gmail's `date` was `internalDate` until v91 copied it into
     `providerDate`. Such a row would fall outside its range's list, become a candidate and be kept by
     its GET: one cheap `format=minimal` GET per listing (the first and one after each lapse since
     2026-11-12; weekly from 2026-11-11; daily before).
   - **Cost: a new account's first sync** (2026-11-12). The capture writes a new Gmail account's
     first cursor through `lapseDeltaCursor`, after the same full sync's catch-up has started each
     folder's first listing, so that first cursor counts as a lapse and a new Gmail account's first
     sync lists each folder twice until the cursor is captured before the catch-up lists
     (tabmail-ios #783). *Fixed 2026-11-12 (ADR-IOS-111):* the bookmark is read before the listings
     and stored after them with no lapse mark, so each folder is listed once.

**Consequences.**

- *Amended 2026-11-12 (#766), the schedule:*
  - A Gmail listing gets one 2 s slice per foreground backfill cycle (a cycle every 3 s while it
    makes progress, 0.5 s on power) and slices for up to 5 minutes in every background processing
    job, instead of 2 s per full sync. Measured in the simulator against the REST fake, for a
    ten-year Inbox (1,825 messages, one every two days; 1,371 list requests), the foreground worker
    alone (the normal profile, no background job) completes one listing in about 90 s when a request
    takes no time (the slice cap and window bound it: 50 requests per slice) and in about 12 minutes
    (712 s) when every list request takes 0.2 s. Before, the same listing took about 56 hours of
    app-open time. (`GmailCatchUpTests.measureForegroundListing`, run only when the test runner's
    environment sets `TABMAIL_CATCHUP_MEASURE`.)
  - *Superseded 2026-11-12 (#766, the Wi-Fi-only ruling): the next bullet.* The catch-up ignores the
    Wi-Fi-only setting, so the 7-day expensive-network bound holds whatever the setting; only the
    battery gate and Low Power Mode delay it, and both lift on their own. *Superseded 2026-11-19 (#1063): scans always run; see the amendment of that date.*
  - **The 7-day bound below now holds only when the worker may run.** With the Wi-Fi-only setting on
    (the default), the catch-up, like the walk, does not run on an expensive network, so a device
    that is always on cellular or a hotspot gets no catch-up. *Superseded 2026-11-19 (#1063): scans always run; see the amendment of that date.* With the setting off, the 7-day
    expensive-network bound holds as before. The battery gate (below 20%, not charging) and Low Power
    Mode (background job) pause it too.
  - **An IMAP folder whose HIGHESTMODSEQ moves is relisted at the next worker cycle**, which every
    poll starts, instead of at the next full sync: an active IMAP Inbox may be relisted about once a
    minute in the foreground (about 50 bytes per message per listing), one slice at a time.
  - The bullets below that speak of a pass or of "the hold under the sync lock" read per slice; a
    full sync's hold no longer includes the catch-up.
- An older-mail read or flag change reaches the device within one pass if the server supports
  CONDSTORE (a large folder may take several passes), otherwise within the full-check interval.
- A removal in a folder that is not fully backfilled is applied within the full-check interval.
- The hold under the sync lock grows by about 2 s typically and about 5 s at most.
- A folder whose HIGHESTMODSEQ moves every pass (an active Inbox) is relisted continuously within
  that budget.
- **Limits:**
  - Without CONDSTORE, changes wait up to a day.
  - A STATUS that omits HIGHESTMODSEQ leaves the previous value in the folder row, so that pass's
    cheap check may read "unchanged" (the full check is the backstop).
  - A pathologically slow link where request 1 alone exceeds the budget relists the same range and
    applies only its flags. That fails closed and is recoverable.
  - Only read and flagged are caught up. An action tag, `\Answered`, or a message left
    `\Deleted`-but-present on older mail is not.

**Alternatives rejected.**

- A per-folder provider call: it would put the budget and the ordering above the boundary.
- (#766) Keeping the catch-up in the full sync with a longer budget: it lengthens the hold of every
  full sync and still leaves the overnight job without it. A separate catch-up worker beside the
  backfill worker: a second loop with its own gates and schedule, where the backfill worker already
  has both.
- `UID SEARCH MODSEQ` plus a FETCH of the changed UIDs: it needs NIOIMAPCore's
  `SearchModificationSequence`, and the agreed shape is a listing.
- `CHANGEDSINCE`: the SwiftMail fork has no FETCH modifier for it.
- Folding the walk into the catch-up: the walk's immediate count trigger is worth keeping, and it
  already shares the one removal path.
- A last-range completion stamp: it misses mid-listing changes (above).

### Amendment (2026-11-12, ADR-IOS-111: change reading; #783)

- **Arming is the lapse mark.** The catch-up still receives every syncable folder; Gmail's plan already
  lists a folder only on its first listing, a listing in progress, or after a lapse, so a tracked folder
  gets no scheduled check. A change-bookmark refusal marks ONE lapse per folder (`applyChangeRefusal`,
  which calls `lapseDeltaCursor`); a re-read list over `SyncConfig.changeRecheckLimit` marks one folder
  (`markCatchUpLapse`). No separate `catchUpArmed` flag or `completedFullCheck` result was added: the lapse
  counter already says "one more full check is due" and the listing records when it was done.
- **No lapse at a new bookmark (#783).** The Gmail cursor is no longer captured after the full sync (the
  deleted Gmail arm of `captureSyncCursors` marked a lapse on every capture that replaced an unreached
  cursor, so a new account's catch-up listed every folder twice). The candidate is read before the
  listings and stored after them with no lapse mark.
- IMAP's daily check is unchanged until its reader lands.

### Amendment (2026-11-13): the Outlook catch-up, the shared direct load, completed actions

**The shared listing pieces.** The newest-first range cut (`CatchUpRange.cut`, with
`CatchUpRange.listsToEpoch`) and the direct load (`CatchUpDirectLoad.load`, with
`CatchUpDirectLoad.pageVerdict` for the page hold) live below the seam in
`TabMail/Providers/CatchUpListing.swift`. The load takes the fetch as a closure, because
`fetchBackfillBatch` is not an `EmailProvider` requirement. `GmailProvider.loadMissing` is gone; the
Gmail behaviour above is unchanged.

**Outlook (`ExchangeProvider.catchUp`).** Per folder, in this order:

- *When a listing starts.* The first listing, a new listing after a lapse, and one listing once the
  folder's backfill walk completes (the walk's offset paging can leave holes); never a periodic
  check. A new listing starts only while the folder's change bookmark is tracking (its first
  change read is complete), the one place this lives being `catchUpTrackingGateOpen`: before that,
  a message deleted between the listing's pass and the first read's start would be reported by
  neither. The expensive-network wait counts from first sight, which is recorded even while the
  gate holds, so the two waits run side by side. *Superseded 2026-11-19 (#1063): scans always run; see the amendment of that date.*
- *Paging.* Each range is listed with `receivedDateTime ge/lt` filters, newest first, `$top`
  `SyncConfig.catchUpGraphListPageSize` (250), resuming at a date (keyset), never at a saved
  `$skip` or link. A page whose oldest second also holds newer messages is listed again from that
  second; a page of one second follows Graph's own link inside the slice only. Ranges hold at most
  `SyncConfig.catchUpGraphRangeRowLimit` (500) local rows.
- *Requests.* A quarter of the mailbox request rate (`SyncConfig.graphCatchUpRequestShare`,
  `graphCatchUpRequestsPerSecond`), charged before each request; a `$batch` is charged its width.
  Graph's own 429/503 retries are not charged.
- *Removals.* A local row no page of its range names is a candidate, removed only when its own
  `$batch` answer says gone or in another folder; an unusable answer keeps it, held at most the page
  walk's hold bound. Ids loaded this slice count as named.
- *Loads.* An id a page names that no local row holds is loaded through `CatchUpDirectLoad.load`,
  in batches of `GraphConfig.bodyFetchConcurrency`, with the page walk's hold bound.
- It never throws, writes nothing itself, and reads no setting or device state (the context
  snapshot carries them). Progress: a range cut whose first page failed is no progress.

**Completed actions against a slow read (every provider's apply).** A read can reach the apply after
the 30 s `recentlyCompleted` protection ran out. `AccountManager` keeps, in memory only, when each
action completed (account and message key, the keys `recentlyCompleted` uses), written at both
completion sites of the action queue and kept for `SyncConfig.catchUpCompletionLogRetentionSeconds`
(one hour). `SyncEngine.runCatchUp` takes `readStartedAt` just before the provider call. The apply
skips a read or flag update for a message whose action completed at or after `readStartedAt`. A read
at least the retention old applies no read or flag update at all; its removals, loads and state still
apply, so a listing always moves on. All three times are on one wall clock (`CatchUpWallClock`),
never `CatchUpContext.clock`. Nothing is persisted and no content is kept.

**Loads too (2026-11-13, later the same day).** The rule above guarded only read and flag updates,
so a move that completed after a read listed and loaded a message, and before its apply, put the old
id back in the source folder (the #106 ghost; Memory 127). The direct load's insert now applies the
same rule inside each insert chunk's transaction (`insertBackfillBatch` with `catchUpRead`, a
`CatchUpReadLatch`, from `SyncEngine.applyCatchUpResult`; *superseded name:* `catchUpReadStartedAt`): it skips a message the shared 30 s protection still holds or
whose completion-log time is at or after `readStartedAt` (`SyncEngine.catchUpReadPredatesAction`, the
one check the flag path also uses), and an over-age read (`SyncEngine.catchUpReadIsOverAge`) inserts
no load at all. A skipped load is not a failure and marks nothing: the state is written, and a
message the server still lists in the folder is missing again at the next listing. The sentence above
that counts loads among what an over-age read still applies is superseded and kept as written. *Amended 2026-11-20 (#1062):* over-age is a one-way latch (`CatchUpReadLatch`) checked before
the insert, in each insert chunk and in the transaction; chunks inserted before it sets stay, later
loads are dropped, and a dropped load makes the listing unclean (`CatchUpSkippedLoads.key`), so an owed
folder stays owed. The "inserts no load at all" wording above is superseded and kept as written.
Gmail's and Outlook's direct loads share the insert, so both are covered; the page walk passes no read
start and is unchanged.

Tests: `OutlookCatchUpTests` (removals, loads, lapses, bounds, paging, same-second groups, the gate's
timing, completed actions), `OutlookChangeFuzzTests` (catch-up schedules with faults, lapses, clock
jumps and user actions; the completed-action invariant), `StatefulExchangeActionServerCatchUpTests`.

**Amended 2026-11-14 (tabmail-ios #848): a Settings reset clears `catchUpState`.** "Reset message data"
and "Delete All Email Index Data" now clear `Folder.catchUpState` with the folder's other sync progress,
through the one reset list `SyncEngine.resetSyncStateTxn` (ADR-IOS-111 amendment of the same date).
Before, a check part-way through a folder went on from its saved place in a folder the reset had
emptied, fetching that stretch's older mail at the check's pace alongside the reset's re-download. A
cleared state is the first-check state of a new folder, which every provider's `catchUpPlan` already
handles. Test: `SettingsSyncStateResetTests`.


### Amendment (2026-11-19, #1063): scans always run; only downloads wait

**Amended 2026-11-19 (#1063): scans always run; only downloads wait.** A scan keeps the mailbox
accurate and costs little when nothing changed, especially on servers that report changes; downloads
keep the Wi-Fi-only, battery and Low Power Mode rules. The catch-up (every provider: listings, the IMAP
daily check, first listings, listings after a lapse) and the Outlook change read's state baseline
(ADR-IOS-111) run with no expensive-network wait, no battery gate and no Low Power Mode gate, in the
foreground backfill worker and the background processing job.

- **Deleted:** `SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds`, `CatchUpSchedule.waitedTooLong`,
  `CatchUpContext.isExpensiveNetwork`, `SyncEngine.CatchUpRun.isExpensiveNetwork`,
  `ChangeContext.isExpensiveNetwork`, `OutlookFolderCursor.baselineSince`, the `createdAt` of the IMAP,
  Gmail and Outlook catch-up states (stored keys are ignored on decode and dropped on the next write; no
  migration), `SyncEngine.getShouldPauseBackfill` and `SyncScheduler.BackgroundBackfillPlan`.
- **Every gate now decides only `walkAllowed`.** The foreground worker reads one power and network
  snapshot per cycle (`SyncEngine.backfillPowerState`) and decides with `SyncEngine.backfillWalkAllowed`:
  Low Power Mode off power, a battery below 20% off power, or the Wi-Fi-only setting on an expensive
  network hold the walk; fast sync lifts the two power gates (not the Wi-Fi-only rule, as before). The
  job decides with `SyncScheduler.backgroundBackfillPlan` (Low Power Mode, or Wi-Fi-only off Wi-Fi, holds
  the walk) and always runs the backfill. `runBackfillCycle` always runs the catch-up.
- **The walk keeps every rule it had**, including skipping non-primary folders on an expensive network
  (`SyncEngineBackfillWalk`). The body queues have no gate (unchanged; tabmail-ios #1064 tracks that
  gap). A message the scan finds missing is loaded with it (the direct load follows the scan): a missing
  message is the scan's result, and holding it keeps the mailbox wrong.
  *Note (2026-11-20, #1064):* "The body queues have no gate" above is superseded: `BackfillBodyQueue`
  (older-mail bodies) now follows the walk's download gates (ADR-IOS-005, amendment of 2026-11-20 and its
  correction). In the background job the walk and the bodies decide with the job's one Wi-Fi
  measurement, taken concurrently with the job's work: scans never wait for the reading, and the walk
  and the bodies hold until it lands; outside it, a network NetworkMonitor has not reported yet holds under Wi-Fi-only.
  *Note (2026-11-20, #1064 review):* "on Wi-Fi" is an unmetered network (satisfied, not expensive, any
  interface) for all three decisions (the foreground gate, the job's bodies, the job's walk) through one
  predicate, `SyncEngine.onUnmeteredNetwork`, so a Personal Hotspot holds them and wired Ethernet does not. The job's scan-only pre-pass ends when the reading lands; the account then
  runs its normal pipeline with the full budget, so the pre-pass never takes budget from the walk; scans
  still run first in that pipeline's catch-up as before (ADR-IOS-005, second correction of 2026-11-20).
  `ActiveBodyQueue` and opened messages are not gated; scans and the direct load are unchanged.
- **Pacing is unchanged:** 2 s slices, `catchUpSliceMaxRequests`, the slice window, the 3 s request
  timeout. A worker cycle whose walk a power gate holds still sleeps 60 s when it did no work, and one
  whose walk only Wi-Fi-only holds sleeps 30 s, so the wake cadence is unchanged. A cycle that made
  catch-up progress with every walk complete uses the active delay, also below 20% battery.
- **Costs, accepted:** the daily full listing of an IMAP folder without CONDSTORE now runs on cellular
  (about 50 bytes per message per listing); every folder's first listing runs at once on any network;
  under Low Power Mode the background job runs catch-up slices until its deadline instead of skipping,
  and ends after one slice without progress when nothing is due. A scan with nothing due sends no request.
- **Tests:** `scanRunsUnderEveryDownloadGate` in `IMAPCatchUpTests`, `GmailCatchUpTests` and
  `OutlookCatchUpTests` (expensive network, low battery, Low Power Mode, each in the worker and the job,
  each with a walk control; the Gmail and Outlook cases also load a missing message),
  `IMAPCatchUpTests.firstListingRunsAtOnceOnAnExpensiveNetwork`,
  `GmailCatchUpTests.lapseDuringListingRelistsAtOnceOnCellular`,
  `OutlookChangeReadingTests.stateBaselineRunsOnCellular`, `SyncSchedulerConstantsTests`
  (`backfillWalkAllowedTruthTable`, `backgroundBackfillPlanTruthTable`, `wifiOnlySettingGuard`) and the
  fence `ChangeSeamFenceTests.scansNeverReadAGate`. Deleted with the rule they pinned:
  `IMAPCatchUpTests.dailyCheckDeferredOnExpensiveNetwork`, `expensiveNetworkWaitIsBounded`;
  `GmailCatchUpTests.expensiveNetworkWaits`, `lapseKeepsTheExpensiveNetworkWait`,
  `wifiOnlyHoldsTheWorkerWalkNotTheCatchUp`, `wifiOnlyHoldsTheJobWalkNotTheCatchUp` (folded into the
  gate cases); `OutlookCatchUpTests.expensiveNetworkWaits`, `mobileWaitsRunSideBySide`;
  `OutlookChangeReadingTests.expensiveNetworkWaitIsBounded`. Inverted:
  `IMAPCatchUpTests.wifiOnlyCellularKeepsTheDailyRule`, now `wifiOnlyCellularRunsTheDailyListing` (the
  daily listing runs on cellular, the walk does not). The plan truth tables (`planDecision`, Gmail
  `catchUpPlan`, Outlook `plan`) lost their network rows; the seeded Gmail spacing that used the wait
  bound now uses a one-week test constant.

Keywords: scans always run, any network, low battery, Low Power Mode, walk held, walkAllowed,
backfillWalkAllowed, backfillPowerState, backgroundBackfillPlan, download gate, #1063.

### Amendment (2026-11-20, #1062): missing mail is found by UID; the date repair is gone

The IMAP catch-up now finds and loads a message the server holds in the folder's held range with no
local row, whatever its date. The date-based self-heal (`SyncEngineSelfHeal.swift`) is deleted.
Operative rules (`IMAPProviderCatchUp.swift`, `SyncEngineCatchUp.swift`):

- **Ranges are cut on UIDs, not on local rows.** The lower bound is where the held range starts
  (`heldRangeStart`: 1 once the older-mail walk is complete, else its cursor + 1); under a storage limit
  loads start above the prune cutoff of the folder's epoch (*superseded in place 2026-11-21 by THE
  FLOOR RULE below:* "loads start at the higher of that and the first local UID (amended 2026-11-20: was
  the first local UID alone, which let rows infinite scroll cached below the cursor pull the floor down
  and load MORE under a limit)"), so pruned mail is neither listed for load nor loaded. Below the load start a listing
  only checks local rows. The upper bound is the larger of the last local UID and, with a change
  bookmark of the same epoch, the bookmark's UIDNEXT - 1 (by the bookmark, not by tracking), else the
  listing's stored top (2026-11-20, below). *Superseded (2026-11-20):* "else the listing's own SELECT
  UIDNEXT - 1", set per call from its first listed range.
- **Stored top, current (2026-11-20).** `IMAPCatchUpState.Listing.top`, in the epoch-tagged state: the
  last UIDNEXT - 1 the listing's SELECTs reported, at least the last local UID, raised by every later
  listed SELECT. UIDNEXT is read at most once per listing, by a call with no bookmark, no stored top
  and no recorded `topUnknown` (one request, UIDVALIDITY checked, before its first range); every
  range is cut at the top. When it reports none (a nonconforming server; a "could not determine" answer is not an answer), no top is stored and
  the listing records `Listing.topUnknown`: every call of it lists up to the last local UID with no
  further UIDNEXT read (so a slice of one request still lists ranges), flags and removals are reconciled
  as before, an empty folder completes, and the listing completes only as not clean, so an owed folder
  stays owed, is listed again at the daily check, and nothing settles on an unknown top
  (IOS-CATCHUP-005). A later range SELECT without UIDNEXT keeps the top already learned; one that
  reports UIDNEXT stores it as the top, the listing goes on to it, and it still completes not clean. A change
  of the top alone is progress. *Superseded (2026-11-20):* "a SELECT without UIDNEXT is unknown: no top
  is stored, the folder stops for the call and stays owed", which also stopped every flag and removal
  check of a folder without a bookmark on such a server. Why: with no bookmark, each
  call's first range was asked blind, and an empty one sized the next to the maximum span, so at one
  request per call an owed folder walked above the server's top and never completed.
- **UID-range membership proof.** A FETCH can be short, so a UID in the load range that is absent from
  the FETCH and has no local row is never read as absent: when the range has one, `UID SEARCH` over the
  whole load range (with the removal candidates) proves membership under the same epoch. A UID SEARCH
  finds but the FETCH did not answer is unresolved (its flags, `\Deleted` included, are unknown).
- **Direct loads.** Missing UIDs (listed, not `\Deleted`, no local row, in the load range) load by
  header in batches of `SyncConfig.catchUpLoadBatchSize`, each charged before it is sent; a UID the
  header FETCH does not answer is checked by SEARCH: gone is done, present is held. Loads bind to their
  observed epoch and are inserted through the walk's insert tail.
- **The bounded hold.** `listing.loadHeldSince` belongs to the UID at `listing.nextUid`, the earliest
  unresolved UID. It survives budget stops, SEARCH failures and later successful loads of later UIDs,
  and resets only when that UID resolves or the earliest unresolved UID advances. Past
  `SyncConfig.backfillPageHoldMinutes` the held and unasked UIDs count as done (`listing.passedOver`),
  the range moves on, and the listing completes as NOT clean. A stop before the membership proof (the
  slice's budget is spent by the FETCH, or the SEARCH fails) leaves the range unresolved from its start
  under the same hold, so a slow link that spends every slice on the FETCH cannot stall repair.
  *Replaces:* "When the budget is spent before request 2 [...] the cursor stays, so the range is listed again."
- **Clean and unclean completion; retry.** A folder owed a check (`FolderChangeState.selfHealOwed`, set
  by `dropChangeBookmark(selfHealDue:)` after an unproven move) is settled ONLY by a CLEAN completed
  listing that started at or after the mark (`lapseCountAtStart >= selfHealLapse`). Unclean: anything
  passed over (held, unanswered, a range moved past after its membership SEARCH kept failing), a
  listing whose first UIDNEXT read reported none (`Listing.topUnknown`, 2026-11-20), or loads
  the apply skipped as an over-age read. An unclean completion keeps the folder owed and re-marks
  nothing: it is listed again at least daily, plus when its change counter moves past the stamp the unclean listing still records; loads dropped as over-age in ANY slice mark the saved state unclean through the provider-neutral key `CatchUpSkippedLoads.key`, and over-age is a one-way latch (`CatchUpReadLatch`) checked before the insert, in each insert chunk and in the transaction (amended 2026-11-20; *superseded (2026-11-20):* "it is listed again at the daily full check, never hourly"; the earlier 2026-11-20 rule
  "settled by any completion, passed-over UIDs on the re-read list" is superseded: it recorded only the
  lowest held UID per range and settled with mail on no retry path). An owed folder gets the daily and
  MODSEQ checks even when it holds a bookmark (the plan's `isTracked` = bookmark held AND not owed),
  because a change pass can store a bookmark on an owed folder. A listing's start count comes from the
  raw state's `lapseCount` (`CatchUpLapse.read`) when the typed state is absent (floor-only, another
  epoch). The apply then calls
  `markListingDue`, so the next scheduled full sync lists the folder and `commitChangeBaseline` tracks it
  again. A clean completion that started before the mark, and a mark landing
  during the read, re-mark the lapse on the state just written (also when it was NULL) and record it in
  `selfHealLapse`: the obligation survives, so a later listing still repairs the missing UID even when a
  bookmark keeps the daily and MODSEQ checks off (the bookmark-based planning rule is unchanged).
- **Unknown epoch fails closed.** A folder whose epoch is unknown is not listed and loads nothing; the
  epochless date repair is not replaced (accepted limitation).
- **Amendments (2026-11-20, #1062), current where they differ from the bullets above:**
  - *Range size.* A range's width in UIDs is sized from the folder's EXISTS and UIDNEXT (first the
    stored STATUS values, then each listing SELECT's own): mean UIDs per message times
    `SyncConfig.catchUpListingRangeMessages`, never below `SyncConfig.catchUpListingMinRangeSpan`
    (`IMAPProvider.listingRangeSpan`). A listing costs about EXISTS / that many ranges, however sparse
    the UID space; each range has ONE membership SEARCH, asked as the range itself (plus the removal
    candidates) and never expanded (`searchMembership`). *Replaces:* fixed 1000-UID ranges
    (`catchUpListingRangeSpan`), which made a sparse folder cost one or two requests per 1000 UIDs.
  - *Range size, current (2026-11-20).* Only the FIRST range is sized from EXISTS and
    UIDNEXT (a stored count of 0 reads as unknown: the minimum width). Each later range's width comes
    from the previous range's own count (`IMAPProvider.nextListingRangeSpan`), within
    `catchUpListingMinRangeSpan...catchUpListingMaxRangeSpan`, so a bunched folder never puts most of
    itself in one range. A listing range that times out, or whose answer is too large or undecodable
    (`UIDWalkCursor.failureCallsForSmallerRange`), is cut by the walk's one splitting rule
    (`UIDWalkCursor.halves`, #1006) to the half next to where the listing stands in
    its direction of travel (the listing runs upward, so the LOWER half; the walk runs downward). That
    half's width is stored in the listing (`IMAPCatchUpState.Listing.rangeWidth`, an optional JSON field,
    no migration) and the folder stops for the rest of the call: a timeout closed the folder
    connection's session, so a retry in the same call would first log in again on the link that just
    timed out. The listing keeps its place
    (decision 8); the next call asks from there with the stored width, and every answered range
    re-sizes it from its own count, so the next range need not be the other half. A one-UID range that
    fails stays unconfirmed: the listing never moves past it and the next call asks it again. With no
    stored width, the first range is sized from EXISTS and UIDNEXT. Header-load batches are never split.
    *Superseded (2026-11-20):* "is asked again as its halves ... the half next to
    where the listing stands first ..., the other next", a retry of both halves inside the same call,
    which could not work while the timed-out request still held the folder's connection. *Replaces:* the width recomputed from each SELECT's EXISTS and UIDNEXT, and a
    listing failure that ended the folder's pass with no split.
    *Superseded in part (2026-11-21):* the cut to a half and the stored half width ("is cut by the walk's
    one splitting rule ... That half's width is stored in the listing ... the next call asks from there
    with the stored width"); see *Timeout, current (2026-11-21)* below.
    *Superseded (2026-11-21):* the reason "the timed-out request still holds the folder's connection
    until its late answer, so no retry in the same call" (and "while the timed-out request still held
    the folder's connection" in the 2026-11-20 note above): a timeout closes the folder connection's
    session at once, and nothing waits for the late answer (see the 2026-11-21 in-flight amendment under
    *How many slices*).
  - *Timeout, current (2026-11-21).* A listing range that times out, or whose answer is too large or
    undecodable (`UIDWalkCursor.failureCallsForSmallerRange`), stores ONLY the width cap
    (`IMAPCatchUpState.Listing.widthCap`: its width divided by `SyncConfig.catchUpWidthCapShrinkFactor`),
    and the folder stops for the rest of the call. The stored width (`Listing.rangeWidth`) is left as it
    was: only a range that answers sets it, from that range's own count. The listing keeps its place, and
    the next call asks from there at most the capped width (the cap is applied where the next range is
    cut). The cap write is no progress: a call that changed nothing else (a cap-only change) is no
    progress, while a call that started the listing, learned its top or answered an earlier range made
    progress and keeps what it saved. Whatever progress it made, a call whose request timed out reports
    the folder's request as possibly in flight (`CatchUpFolderResult.requestMayBeInFlight`): the run never
    asks a folder again after its request timed out, and goes on with its other folders (see the
    2026-11-21 amendments under *How many slices*). Only a timeout reports it: an answer too large or
    undecodable caps the width and ends the call the same way, but nothing of it is outstanding, so it
    reports no request in flight. The folder's next call, in a later run, asks at most the capped width.
    *Qualified in place (2026-11-21, #1062):* "in a later run" holds after a timeout; after an answer too
    large or undecodable the folder stays in the run, so its next call may be a later slice of the same
    run, cut by the same cap. A one-UID
    range that fails stays unconfirmed. Other callers that reach the folder soon after (the worker's next
    cycle, the walk) log in again on the same link: the connection layer's issue, #1133, open. Why:
    with the shrink factor at 2 the cap (half the width, rounded down) was never wider than the stored
    lower half (rounded up), so the stored half width never set a range; its only effect was that a
    timeout changed the listing and so counted as progress, against the rule that a request that failed
    before anything moved is no progress.
    *Superseded (2026-11-21):* "The call is no progress (a cap-only change), so a
    background run does not ask again at once on the connection the timed-out request still holds: the
    folder is tried again at the next cycle." A call that starts a listing, or answers a range before the
    one that times out, made progress, and the run's progress counted every folder, so the run asked the
    folder again at once on the held connection.
    *Superseded (2026-11-21):* "Whatever progress it made, the call reports the folder's request as
    possibly in flight": it read as if a too-large or undecodable answer reported one too.
    *Superseded (2026-11-21):* "Other callers that reach the folder while the late answer is
    outstanding": a timeout closes the session at once, so no late answer is outstanding for them.
  - *Every timeout ends the call (2026-11-21, #1062).* Any catch-up request of a call that times out (the
    UIDNEXT read, a listing range, a membership proof, a header load, an unanswered UID's SEARCH) ends the
    folder's call, including a proof, load or SEARCH timeout on a range whose hold is past
    `backfillPageHoldMinutes`: that range is passed over and saved (`Listing.passedOver`, `nextUid` past
    the range, the hold cleared, no carry), and the call stops there instead of listing the next range. No
    new state. The call's result keeps what it found before the timeout (flag updates, proven removals,
    loaded headers), applied with that state (*qualified in place 2026-11-21:* the flag updates, removals
    and state in one transaction; loaded headers are inserted before it, in the insert tail's own chunk
    transactions, and a failed chunk writes no state). Nothing is lost: the only work the same
    call did after such a pass-over was to list the following ranges (their FETCH, proof and loads), and
    the next call does exactly that from `nextUid`, as after a budget stop, with the stored width, cap and
    top unchanged and a fresh hold for any UID it holds. `passedOver` stays in the listing, so whichever
    call completes it completes it unclean (an owed folder stays owed); if the passed-over range was the
    listing's last, the next call completes it at once, with no request. Why: a timeout on the wire closed the
    folder connection's session (a timeout while the request still waited for its connection sent
    nothing, and is treated the same way), and with budget left (a slice whose clock has not run out, or no
    deadline) the next range's request would first log in again on the link that just timed out, and a
    timeout of its listing would cap the width for a reason that is not the range's size.
    *Superseded (2026-11-21):* the reason "the timed-out request may still hold the folder's connection
    [...] the next range's request would wait behind it or reach the next range after its late answer":
    a timeout closes the session at once, and its late answer is never read.
    *Superseded (2026-11-21):* past the hold bound, a proof, load or SEARCH timeout passed the range over
    and the same call listed the next range; only a slice's time budget, shorter than one timeout, usually
    stopped it.
  - *Width cap, current (2026-11-20).* A range that times out sets the cap
    (`IMAPCatchUpState.Listing.widthCap`) to its width divided by `SyncConfig.catchUpWidthCapShrinkFactor`;
    each range that answers multiplies it by `SyncConfig.catchUpWidthCapGrowthFactor` (2026-11-20: kept only
    when the call makes progress; a call that moves nothing restores the cap it started with), and at
    `catchUpListingMaxRangeSpan` it is dropped. No range-scoped end (`widthCapThrough` removed). Why: the
    cap below only ever shrank, so about 20 timeouts unrelated to range size left a sparse folder at
    one-UID ranges over millions of UIDs. A cap-only change is still no progress. 2026-11-21: the cap is
    all a timeout stores, so the timeout's own write is no progress (*Timeout, current (2026-11-21)*
    above). *Superseded (2026-11-21):* "so a timeout is no progress": a call that
    moved its listing before the timeout still made progress.
  - *Width cap after a timeout, superseded by the current width-cap entry above.* A range that times out also stores a
    width cap (`IMAPCatchUpState.Listing.widthCap`, the stored half width) together with the upper end
    of the range that timed out (`widthCapThrough`); repeated timeouts before the listing moves past
    keep the smallest cap and the highest end. While the listing stands at or below that end, no range
    is wider than the cap, whatever a range's count (or `catchUpListingMinRangeSpan`) would size it to;
    once the next range starts past that end, the cap is dropped and widths follow the counts again.
    Both fields are optional JSON (no migration) and go with the listing when it completes. Why: the
    listing returns to a place it already reached (a held UID, a budget stop), and re-sizing from a
    count alone asked the width that had timed out again from there, so a slow link timed out at the
    same range on every call. Why it lifts: a cap kept for the rest of the listing would narrow every
    later range after one slow stretch, down to one UID after repeated timeouts, and a large folder
    would never complete its listing (flags, removals and missing-mail loads would stop with it).
  - *Carried range, current (2026-11-20).* A range the budget stops after its listing FETCH
    (before the membership SEARCH) or after its proof (before a header batch) is carried in the
    listing (`IMAPCatchUpState.Listing.carried`: the range, its unproven candidates, the missing UIDs,
    the `\Deleted` ones it listed, whether it is proven, and a held UID). The next call goes on with it
    before it lists anything new, so no call throws away a request it already paid for and any slice
    budget that fits one request converges. UIDs only (metadata, ADR-004), at most
    `SyncConfig.catchUpCarriedUidCap`: past it the range is cut at the UID that reaches the cap and the
    rest is listed again later. It lives in the opaque catch-up state, so it goes with it: under
    another UIDVALIDITY (the state's `epoch`) and with a re-created folder row (whose state starts
    empty). A carried UID re-read as local since is not loaded again; an expunged one finds nothing.
    A held UID keeps its first hold while the carry runs and is passed over at the bound. A failed
    SEARCH still holds the range from its start. Superseded: "a budget stop before the proof holds
    the range from `lo`", which made a slice that fits only the listing and the proof list the same
    range forever. No migration.
    *Amended later the same day (2026-11-20), current:* the carry stores the load floor its range was listed under
    (`loadsFrom`); the resume loads only from the higher of that and the current floor, so a rising
    floor (a walk reset, a prune) loads nothing below it and a range listed with no floor proves only
    its candidates. Carried UIDs (missing, `\Deleted`, unanswered, the held one) now local are
    dropped, the held one with its hold. A budget stop before the SEARCH for UIDs a load batch did
    not answer carries that SEARCH (`unanswered`). A failed SEARCH or load keeps the carry within the
    hold bound, so the retry pays only for what failed. The header load compares the SELECT's
    UIDVALIDITY before its FETCH and sends nothing under another numbering; a UID SEARCH is read-only
    and is compared after its answer, which is discarded on a mismatch. The slice reads the load
    floor at the start of its turn and drops carried UIDs outside it. A Settings reset takes the
    account's sync turn (ADR-IOS-104 amendment 2026-11-20), so no slice runs between its read and its
    write and nothing read before a reset is written after it; there is no compare-and-set on the
    state. A re-created folder row is a new insert whose state starts empty; an existing row's
    folder-list update never writes it. Superseded: "a failed SEARCH or load drops the carry".
    *Replaces:* "every answered range re-sizes it from its own count" with no bound after a timeout.
  - *Range bounds.* Only FETCH records inside the range asked for count; an unsolicited FETCH for
    another UID is no part of the listing (the #755 rule).
  - *Load floor before the walk starts.* With no walk cursor, the load floor is the folder's lowest held
    UID: new mail beyond the window is a scan's to load, and a scan never waits for the walk's download
    gates (#1063). Only mail older than every local row waits for the walk. *Replaces:* "before the walk
    has started, below the window is the walk's to load" (nothing loaded).
  - *Load floor before the walk starts, current (2026-11-20).* The floor is the lowest UID a
    window listing of the folder reached (`CatchUpWindowFloor`, kept under `windowFloor` in the
    folder's `catchUpState` JSON by the window merge, `SyncEngine.recordCatchUpWindowFloor`, as the
    lowest any window listing in the epoch reached; the catch-up apply carries it across its own state
    writes; a turnover clears it with the state). Under a storage limit, the higher of that and the
    lowest held UID (after the walk starts, the higher of the walk's start and the lowest held UID). No floor recorded yet: nothing is loaded until a window listing records one. Rows
    infinite scroll writes far below the window never pull it down, so older mail stays the walk's,
    which waits for Wi-Fi under Wi-Fi-only. After the walk starts, the walk-cursor rule stands. No
    migration (the state column is opaque JSON). *Replaces:* the lowest held UID as the floor, which
    let infinite-scroll rows pull it down over old mail.
  - *THE FLOOR RULE, current (2026-11-21, #1062); the two entries below restate parts of it.* (1) Every
    floor and cutoff the catch-up stores is stored WITH the UIDVALIDITY it was learned under
    (`windowFloor` and `pruneCutoff` are `{uid, epoch}` objects in `catchUpState`, `CatchUpEpochValue`);
    an entry of another epoch reads as absent and is never rebound; none is written under an unknown
    epoch. (2) Loads start at the held range's start (the walk's start once it started, else the epoch's
    window floor; none: nothing loads; with no local row either, nothing is checked: the listing completes
    with no server read and NOT clean, so an owed folder stays owed until a window listing records a floor;
    *superseded:* it completed clean); under a storage limit at least one past the epoch's prune cutoff;
    nothing else raises it: the first local UID is no evidence of what was pruned. (3) The scan floor is
    the lower of that start (before the cutoff) and the first local UID; the cutoff never raises it. (4)
    The prune cutoff, the only record of what was pruned, is written by the prune in its delete
    transaction from rows it actually deleted that were still in the folder under the same UID and
    carried the folder's epoch, only for a UID prune order; within an epoch the higher UID is kept. (5)
    The window floor is the lowest UID a window listing named in the epoch; within an epoch the lower is
    kept. (6) The storage prune shipped long before the cutoff (date order, released versions), so under
    a storage limit a UID-windowed folder with a known epoch, local rows and no cutoff of that epoch gets
    ONE from the catch-up slice, in its turn before the provider reads
    (`SyncEngine.seedCatchUpPruneCutoffs`): the lower of its first local UID and its window floor of the
    CURRENT epoch (none: the first local UID alone), minus one; the window-floor term keeps an unreadable
    lowest window UID loadable. Only a slice admitted with budget writes it; a folder whose turnover is
    pending gets none; a folder whose seed read or write fails is left out of that slice and seeded by a
    later one. A never-pruned folder is seeded too: nothing tells it apart from a pruned one. (7) The catch-up apply
    carries both keys with their own epochs; a turnover and a Settings reset clear them with the state.
    No migration. (8) The cutoff is one number per epoch: under a limit everything at or below it is
    pruned territory, including a UID that was never local (unreadable when its window was listed),
    because the UID-ordered prune would have deleted that UID first; scroll and search reach it like any
    pruned mail. (9) The seed is an inference: a date-ordered prune can leave gaps above it, a scroll
    page cached before the seed lowers it, and a deleted row with no epoch stamp (cached before stamping
    existed, an optimistic move, an unproven merge) never raises the cutoff; the catch-up loads such
    mail again at most once, within the limit, as rows stamped with the epoch, which the next UID-ordered
    prune counts. (10) The walk's empty-folder recovery clears the folder's epoch but keeps its state, so
    both keys survive it; they are inert there, because they are read only in their own epoch and a
    write in a new epoch replaces them. Why: a floor inferred from local rows was wrong in three cases:
    an unreadable window UID below the first local one, a cached scroll page below the pruned UIDs, and a
    floor kept across a renumbering by the walk's empty-folder recovery.
    *Superseded (2026-11-21):* "a turnover and a Settings reset clear them with the state" read as every
    path that detects a renumbering: (10) above is the exception.
    *Superseded (2026-11-21):* the window floor as a bare number with no epoch; "under a storage limit,
    the higher of that and the lowest held UID" in *Load floor before the walk starts, current
    (2026-11-20)* above and "The load floor is the lowest held UID" in *Storage limit* below.
  - *Window floor, current (2026-11-21, #1062).* The window merge records the floor as the lowest UID
    the window listing NAMED: the UIDs it mapped to headers and the UIDs it listed but could not map
    (`coverage.unmaterialisedIds`, a record whose header did not read). It records it only when the
    folder's UIDVALIDITY is known for that listing (`sourceBoundEpoch`); with no known epoch it writes no
    floor, because a floor kept under the folder's state could otherwise outlive a renumbering it never
    saw. Why: a window whose lowest UID failed to map recorded the next mapped UID as the floor, so once
    that record read again, no catch-up loaded it (it was below the floor) and no window listing reached
    it again (the window had moved on); the message stayed missing. The lapse check on a gap still uses
    the mapped UIDs. No migration. *Superseded (2026-11-21):* "the lowest UID a window listing of the
    folder reached" read as the lowest MAPPED UID, written whatever the epoch.
  - *Storage limit.* The load floor is the lowest held UID, and the prune deletes lowest UIDs first on
    IMAP (ADR-IOS-006 current note), so nothing pruned is listed for load or fetched again. The insert's
    date skip is deleted. *Replaces:* the date skip in `insertCatchUpLoads`.
  - *Storage limit, prune cutoff (2026-11-21, #1062).* "The load floor is the lowest held UID ... so
    nothing pruned is listed for load" fails once a row below the pruned range is held again: infinite
    scroll caches rows far below the window, the lowest held UID drops below the pruned range, and the
    next catch-up loaded the pruned mail back, so the prune and the catch-up undid each other. The prune
    now records the highest UID it deleted, with the folder's UIDVALIDITY, under `pruneCutoff` in the
    folder's `catchUpState` JSON (`CatchUpPruneCutoff`, `{uid, epoch}`; written in the prune's own write
    transaction by `SyncEngine.recordCatchUpPruneCutoff`, only when the account's prune order is by UID
    and the epoch is known; within one epoch the higher UID is kept, another epoch replaces it; amended
    the same day: only rows the transaction actually deleted, still in the folder under the same UID and
    stamped with the folder's epoch, count, so a row a reset or a turnover removed meanwhile, or one an
    optimistic move brought in under its source UID, never moves it). Under a
    storage limit the load floor is at least the cutoff plus one, read only when its epoch matches the
    listing's; a cutoff of another epoch counts for nothing. The catch-up apply carries it across its own
    state writes, as it carries `windowFloor`; a turnover or a Settings reset clears it with the state.
    The scan floor (flags, removals) is unchanged, so a scrolled row below the cutoff still gets its flag
    updates and removals. No migration (opaque JSON key, ignored by the state decoder).
    *Superseded in part (2026-11-21):* "so nothing pruned is listed for load or fetched again" with the
    lowest held UID as the only guard.
  - *Header batches.* `SyncConfig.catchUpLoadBatchSize` (20) UIDs per FETCH. A record the client cannot
    read fails only that UID (held like an unanswered one, logged when debug logging is on); a batch that
    fails as a whole stops the loads there and the next slice asks it again. No split, no retry within
    the slice.

(missing message, catch-up by UID, membership proof, direct load, bounded hold, loadHeldSince,
passedOver, unclean completion, re-arm lapse, selfHealOwed, selfHealLapse, markListingDue, slow link,
budget stop, SEARCH failure, date self-heal removed, range sized by EXISTS and UIDNEXT, sparse folder,
unsolicited FETCH, walk not started, UID-ordered prune, header batch size, width cap, widthCap,
widthCapThrough, timed-out width, cap growth, cap dropped at the maximum span, clean-only settle, daily relisting of owed folders, storage-limit floor after the walk, request in flight, requestMayBeInFlight, folder left out of the run, held connection, one more slice per left-out folder, every timeout ends the call, pass-over ends the call, per-folder connection, #1133,
window floor named UIDs, unmaterialised UID, known epoch, prune cutoff, pruneCutoff, scroll page after a prune,
pool capacity wait, healthy folder asked in several slices, floor rule, epoch-tagged floor, CatchUpEpochValue,
legacy prune seed, seedCatchUpPruneCutoffs, scan floor below the cutoff, actually deleted rows)
