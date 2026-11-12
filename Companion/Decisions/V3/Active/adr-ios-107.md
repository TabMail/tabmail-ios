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
wait stays; IMAP keeps its daily check).
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
3. **The bounded hold.** `SyncConfig.catchUpPassBudgetSeconds = 2` covers the whole step across all
   folders and is checked before EVERY request. Each request runs under
   `SyncConfig.catchUpRequestTimeoutSeconds = 3`; a timeout or any failure ends that folder's work
   for the pass. **The added hold is typically about 2 s, and at most about 5 s** (the budget plus
   one request that started just inside it).
   - *Amended 2026-11-12 (the direct load):* the Gmail catch-up's loads run in batches of
     `BackfillProfile.normal.gmailBodyConcurrency` (10) concurrent `format=full` GETs, the width the
     provider uses for every body fetch. The budget is checked before every request OR every batch,
     and one batch is bounded as a whole by `catchUpRequestTimeoutSeconds`, so the added hold is
     still at most the budget plus one timeout; the request count may pass the budget check by at
     most one batch less one (the seeded direct-load property checks this).
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
     change. The full check, and continuing one already in progress, waits for a non-expensive
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
   - **Listing.** Ranges of `SyncConfig.catchUpListingRangeSpan` UIDs start at the first LOCAL UID at
     or above the cursor. For each range:
     - **Request 1:** SELECT, then `UID FETCH lo:hi (UID FLAGS)` on one folder connection. The range's
       epoch is this SELECT's UIDVALIDITY, and a mismatch applies nothing.
     - A local UID missing from the FETCH is a **candidate**, never a verdict (a short FETCH is real,
       MIS-IOS-002).
     - **Request 2:** `UID SEARCH UID <candidates>` (`searchExistingUIDs(folder:uids:)`, the walk's own
       absence proof) under the same epoch decides the removals.
     - A record without a UID makes the range unanswerable.
     - When the budget is spent before request 2, the range's flag updates still apply but the cursor
       stays, so the range is listed again.
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
   - **The request stays inside the local range.** Each FETCH runs from the range's first local UID
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
   - **Schedule** (amended 2026-11-12: no periodic check). `GmailProvider.catchUpPlan` lists a
     folder in exactly three cases: it continues a listing in progress (a lapse never interrupts
     one); it starts the folder's FIRST listing (no listing has completed yet: no state at all, or
     the state first sight wrote on an expensive network); and it starts a new listing after a lapse
     as soon as the listing in progress (if any) completes (the lapse marker, below). There is no
     periodic re-check: a tracked folder whose listing completed and that no lapse touched is never
     listed again. Shared with IMAP (`CatchUpSchedule`): on an expensive network at most
     `catchUpExpensiveNetworkMaxWaitSeconds` of waiting (`CatchUpSchedule.waitedTooLong`, kept); least
     recently attempted folder first; the pass budget before every request and
     `catchUpRequestTimeoutSeconds` on each.
     - **Why no periodic check (owner 2026-11-12).** While the history cursor is valid the delta
       follows every folder, All Mail included (#731), and every lapse lists every folder again, so
       the weekly check only backed up what neither reveals: a change whose delta GET failed while
       the capture kept the cursor (#464). The owner dropped it. Cost accepted: such a change waits
       for the next lapse. Test: `GmailCatchUpTests.gmailHasNoPeriodicCheckAndIMAPIsDaily` (a tracked,
       completed folder with no lapse makes no request 8 days later; a lapse lists it).
     - *Superseded (2026-11-12, the weekly schedule):* "`CatchUpSchedule` (shared with IMAP): a full
     check every `gmailCatchUpFullCheckIntervalSeconds` (WEEKLY, amended 2026-11-11), and a new listing after
     a lapse as soon as the listing in progress (if any) completes (the lapse marker, below); on an
     expensive network at most `catchUpExpensiveNetworkMaxWaitSeconds` of waiting (first sight writes
     `createdAt` and makes no request); least recently attempted folder first; the pass budget before
     every request and `catchUpRequestTimeoutSeconds` on each." *Superseded (2026-11-11, before the
     lapse marker):* "and at once after a lapse, which clears the folder's state".
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
       waits for a non-expensive network. A lapse does not restart that wait and does not skip it:
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
     - **What Gmail does with the marker.** A listing in progress goes on from its place; nothing
       about it is lost. Each listing records the count when it started (`lapseCountAtStart`), and a
       completed listing stores it (`listedLapseCount`). When a listing completes and a lapse came
       after it started (`GmailCatchUpState.lapsedSinceLastListing`), a new listing starts at once,
       in the same pass (on an expensive network it waits like any listing), because a change the
       lost history held may sit in a range that listing had already passed. With no listing in
       progress, the plan starts one at the next full sync. So a change is repaired within at most
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
       `lapseKeepsTheExpensiveNetworkWait`, the plan, G2 and G3.
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
     (tabmail-ios #783).

**Consequences.**

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
