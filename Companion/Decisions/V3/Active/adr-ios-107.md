## ADR-IOS-107: The Full Sync Catches Up Server-Side Changes to Older Mail

**Status:** Active (2026-11-10). Issue #540. This ADR covers the generic seam and IMAP. The Outlook
and Gmail catch-ups plug into the same seam later and will amend this ADR with their own sections.

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
     backfill's. No request names an id outside the range the device holds; a folder with a partial
     backfill is never listed below its lowest local id or above its highest.
   - The do-nothing default returns `[]`. Gmail, Exchange and Demo use it until their own
     catch-up lands.
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
4. **The generic apply** (`SyncEngineCatchUp.swift`) uses the existing paths only.
   1. Nothing is inserted (decision 1).
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
5. **Persistence.** There is one nullable `Folder.catchUpState TEXT` column, added by
   `v98_addFolderCatchUpState`. NULL is the correct start for every existing folder. The UIDVALIDITY
   purge transaction (`AccountManager.uidValidityResetPurgeTxn`) clears it with the folder's other
   sync cursors.
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
   - **Order.** The oldest-completed folder goes first.
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
  - The oldest-completed folder goes first and keeps that place until its listing completes. While
    one folder's request times out on EVERY pass, that request uses the whole pass budget, so the
    folders behind it get no catch-up either, and the 7-day statement does not hold for them. It
    heals when the link or server recovers; nothing is lost, and the hold stays bounded. A request
    that fails quickly does not do this: the pass moves on to the next folder.
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
