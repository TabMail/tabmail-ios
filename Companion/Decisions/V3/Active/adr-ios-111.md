## ADR-IOS-111: Provider-Neutral Change Reading

**Status:** Active (2026-11-12). Gmail is the first provider under it (#783, #735, #715); Outlook and IMAP
keep their own change paths until their readers land. (Superseded for Outlook 2026-11-12: Outlook reads
under it too, folder by folder; see the Outlook amendment below. IMAP keeps its own path.)

**Context:** Each provider had its own change path above the provider boundary (`gmailDeltaSync`,
`exchangeDeltaSync`, `imapDeltaSync`, plus the Gmail and Outlook arms of `captureSyncCursors`), each
repeating the same apply rules with small drifts. Every folder was also re-listed by the full sync's
15-minute window (`runSyncMessages`, ADR-IOS-009), which healed whatever the change path missed for the
newest mail and nothing older. Gmail's cursor was captured AFTER the full sync's listings and its catch-up,
and that capture was a lapse, so a new account listed every folder twice for the older-mail catch-up
(#783) and a change made during the listings to older mail was lost (#464, #460).

**Decision:**
1. **One read call per provider.** `EmailProvider.fetchChanges(since: ChangeCursor, request: ChangeRequest)
   -> ChangeSet?` (`EmailProvider.swift`, types in `EmailProviderChanges.swift`). It only reads. `nil` = the
   provider has no reader yet (protocol default); the engine then keeps that provider's remaining path. A
   `ChangeSet` carries the account bookmark update (`keep`, `set`, `clear`, `candidate`), the complete
   folder list on a `.all` pass, and per folder a status (`tracked`, `baselineReady`, `refused`, `failed`,
   `notRun`), PARTIAL records (an absent field never overwrites) and removals.
2. **One generic apply** (`SyncEngineChanges.swift`, `SyncEngineChangesApply.swift`): the folder list
   (`SyncEngine.applyFolderList`, extracted from `fullSync`), then one write transaction per folder with
   the shields read inside it (pending-operation snapshot, `liveRecentlyCompleted()`; Memory 127), then
   reply-parent notifications, search, body queue and one unread recount, then the bookmark in its own
   transaction. The recount runs only when the apply wrote rows (the old Gmail delta recounted after every
   non-empty history), so every other row writer counts what it wrote: the full sync's window listing
   recounts each folder it listed (`processSyncResult`), which the old unconditional recount had hidden. Removals go through the one removal core (`deleteConfirmedGhostHeadersReportingProtected`)
   with the union of every shield, plus the account-wide identity term when the ids are stable
   (`addressEpoch == nil`). Inserts carry today's header builder, AI-cache restore, reply-detect, orphan
   reclaim, the Drafts AND Sent placeholder dedup with label and body carry, references and user labels,
   and the Sent reply-parent mark. No provider cast and no provider test in those two files (pinned by `ChangeSeamFenceTests`).
3. **The re-read list.** *(Its over-the-limit cut is amended 2026-11-15, #903: only a pass's own
   additions are cut; a stored id never is. See the amendment at the end.)* Every change the apply keeps back under a shield, and every message the reader
   names in a folder's `FolderChanges.rereadLater` (one it could not read this pass), is put on the folder's
   `Folder.changeState.recheck` (v102, engine-owned JSON, message ids only); a folder whose only change is
   such an id is still written, or the bookmark would move past a change kept nowhere. The next request passes it; the
   reader reads those messages again and returns ordinary records or removals; an id leaves the list once it
   applies. One pass asks for at most `SyncConfig.changeRereadBudgetPerPass` distinct ids, taking the
   folders' lists in turn from the front (`SyncEngine.rereadIdsWithinBudget`); the ids not asked for stay
   listed, and an id kept back again goes to the back of its list, so every id gets its turn. Full lists
   would otherwise make every background pass overrun its deadline (`backgroundPerAccountTimeoutSeconds`),
   which applies nothing, so new mail would wait for the app to be opened. Over
   `SyncConfig.changeRecheckLimit`, the extra ids are dropped and the folder's catch-up is
   armed (the lapse mark, `SyncEngine.markCatchUpLapse`).
4. **Tracking.** `Folder.changeState.tracking` turns on for a folder only after a window listing that
   finished in a foreground pass whose read covered it (`commitChangeBaseline`). A tracked folder gets no
   window listing (ADR-IOS-009 amended) while the account holds a bookmark, read with the folder rows; a
   refusal turns it off. With no bookmark every folder is listed whatever its flag says: a reset runs
   outside the sync turn, so a pass already past its read can set the flag again after the reset, and
   skipping those folders would leave the account with no bookmark and nothing listed for good.
   *Superseded 2026-11-20 (tabmail-ios #1062):* both Settings resets now take the sync turn (ADR-IOS-104
   amendment), so the reason above no longer holds for them. The no-bookmark rule stays: the UIDVALIDITY
   purge (ADR-IOS-061) still runs outside the turn under its own single flight and clears a folder's
   change state, so a pass already past its read can still set the flag again after it.
   The folder list is written column by column (`updateChanges`), so applying it on every `.all` read
   bumps no backfill version (ADR-IOS-107).
5. **The bookmark is read before the listings.** With no bookmark the reader returns a candidate (Gmail:
   the profile's history id) and every folder `.baselineReady`. The engine makes the full sync due, the same
   foreground pass lists, runs the catch-up, and only then stores the candidate, WITHOUT a lapse mark (#783).
   Background passes never store a candidate. The candidate is stored also when the full sync dropped a
   folder (`FullSyncListing.droppedFolder`). The full sync's per-folder failure handling decides which:
   a lost connection is retried once, and a second loss stops the listing, so that folder and every later
   one go unlisted; any other error on that retry, or (IMAP) a failed SELECT, drops that folder only; any
   other first failure (an HTTP status, an answer that cannot be decoded) fails the whole pass, and then
   nothing is stored. Dropped folders stay untracked, and a reader pass that dropped a folder leaves
   `lastFullSyncAt` unwritten, so the next foreground pass runs the full sync again and lists only the
   untracked folders (tracked ones get no window listing). Nothing is lost meanwhile: a change to their
   mail after the candidate is in the history the next reads take from the bookmark; an account-wide
   reader names every folder, and a full record inserts a message the folder does not hold yet. Their mail
   as it stood before is taken by the later window listing, and older mail by the catch-up, which runs for
   every syncable folder whether or not the window listing finished and keeps a lapse mark until that
   folder's check is done. (Superseded: the candidate waited for every syncable folder, so a dropped folder
   kept the account with no bookmark, and every foreground pass listed every folder again while changes to
   older mail went unread.)
   *Amended 2026-11-12 (ADR-IOS-107, #766):* the catch-up no longer runs in the pass; the backfill worker
   runs it after the pass, in slices. The pass lists and then stores the candidate; the catch-up's listing
   comes later. The candidate was still read before every listing, so a change made during the catch-up's
   listing is in the history the next read takes. "runs the catch-up" above is superseded.
   **Superseded in part 2026-11-19 (#1060; see the #755 amendment item 3):** an unproven listing no longer fails
   the pass. It withholds the full-sync stamp and the folder is listed again on the next pass; the text above is
   kept as written.
6. **Refusal.** One transaction clears the bookmark, untracks every folder, marks one lapse for each
   folder's catch-up and makes the full sync due (`applyChangeRefusal`); the same pass then reads again with
   no bookmark, so the re-list and the new candidate happen in that pass and exactly one catch-up check runs.
   A pass's retry after a lost connection reads the account row again first: the failed attempt may already
   have applied a refusal, and retrying from the pass's own copy would be refused a second time and mark a
   second lapse. When that retry reads a new candidate and the pass lists, the pass does not report the
   first attempt's lost connection as its failure: a full sync that ran reached the server.
   *Amended 2026-11-12 (ADR-IOS-107, #766):* the one catch-up check the lapse calls for runs in the
   backfill worker (which every foreground poll starts) or the background processing job, not in the
   pass itself.
7. **Gmail's reader** (`GmailProviderChanges.swift`): `labels.list` as the folder list on `.all` passes (a
   label created, renamed or deleted shows on the next pass), the history read as before, a deleted message
   a removal in every folder, every changed or re-read message fetched once and a record in each folder its
   labels put it in and a removal elsewhere, a re-read message that is gone a removal everywhere. **One
   unreadable message never stops the account (#444):** a message whose own answer cannot be used
   (`isUnreadableAnswerForOneMessage`: a 5xx, a non-gone 4xx past the retries, a body or record that does not
   decode) is named in `GmailDetailBatch.unreadable`, put in every folder's `rereadLater`, and the rest of the
   pass lands with the bookmark moved; it is read again on each later pass until it reads (it lands) or
   answers 404/410 (a removal everywhere). A failure about the account (a dropped connection, a 401 after
   the refresh, cancellation) is `.failed` with the removals kept and the bookmark kept. (Superseded: any
   failed detail fetch was `.failed`, which with the capture gone held new mail back until a refusal.)
8. **Deleted:** the Gmail arm of `performDeltaSync`, `gmailDeltaSync`, the Gmail arm of
   `captureSyncCursors` and its `deltaReachedCursor` parameter.

**Reset paths:** both Settings resets clear `Account.lastHistoryId` and `Folder.changeState`, so the next
pass starts a new bookmark and lists every folder. (Amended 2026-11-12: they also clear
`Folder.changeCursor`, a folder's own bookmark.)

**Amended 2026-11-14 (tabmail-ios #501, #848): one reset list.** The two resets wrote their own column
lists and disagreed: the Settings wipe (`SettingsView.localIndexWipeStatements`) kept
`lastKnownUidNext`, `lastFullSyncAt` and every empty-path folder row (`WHERE path != ''`), and neither
reset cleared `catchUpState` (the older-mail check, ADR-IOS-107) or `lastKnownHighestModSeq`. Both now
call `SyncEngine.resetSyncStateTxn(_:accountId:)` (nil = every account) inside their own single
transaction; it is the only place that names the columns a reset clears. Per folder:
`backfillComplete = 0`, `oldestSyncedDate`, `lastKnownUidNext`, `lastKnownHighestModSeq`,
`backfillUidCursor`, `backfillPageToken`, `backfillPageHeldSince`, `changeState`, `changeCursor`,
`catchUpState`, on every folder row of the account(s), empty path included. Per account:
`lastHistoryId` and `lastFullSyncAt`, for both resets, so the next pass runs the full sync whatever the
change reader decides. `lastKnownHighestModSeq` is in the list because a kept value lets the full sync
skip a non-Inbox IMAP folder whose MODSEQ has not moved (`shouldSkipFolderFetch`), and the folder has
just lost its rows; the UIDVALIDITY purge, the other "rebuild the folder" path, clears it too. Kept on
purpose: `lastKnownUidValidity` and `uidValidityResetPendingAt` (ADR-IOS-061: the epoch and the
reaction's quarantine flag, which a reset does not change) and `backfillVersion` (trigger-owned). Not
joined, because they mean something else: the UIDVALIDITY purge (`uidValidityResetPurgeTxn`, one
folder, re-anchors `oldestSyncedDate` and zeroes the counts), Smart Reindex (`resetCrawlState`, keeps
the mail), the frozen migrations and the one-time `StartupMigrations` re-walks. Tests:
`SettingsSyncStateResetTests` derive the sync-state columns from the `folder` schema (every column but
the identity, display and epoch ones named with a reason), so a column added later is checked until it
is cleared or named as kept.

**Not done here (open):** the Outlook and IMAP readers (superseded 2026-11-12 for Outlook: see the
amendment below); action tags are NOT read from Gmail labels (ADR-IOS-036
keeps action tags local); the history record limit (#491), the gate skip of the history request (#584) and
the extension's own history path (#455) are unchanged. `fetchHistory` cannot tell an expired history from an
over-long one, so Gmail reports both as `.refused(.expired)`. *(Superseded 2026-11-16 for the record limit,
#491: see the amendment "Gmail resumes its history read" at the end. `fetchHistory` is deleted; only an
expired history is refused.)*

**Trade-offs:** No cross-check: a reader bug is no longer corrected by the 15-minute listing for a tracked
folder; the guards are the pinned tests, the fuzz and the fences, and "Reset message data" clears the
bookmark. A genuine server change that races the user's own action lands one pass later (the re-read).
A message that never reads costs at most one GET per pass while on the re-read list (within the per-pass budget); a 429 or 5xx storm across a
large change batch puts many ids there, and past `changeRecheckLimit` the folder's catch-up is armed.

Keywords: change reader, ChangeSet, fetchChanges, ChangeCursor, ChangeRequest, recheck, re-read list,
tracking, changeState, v102, baseline, candidate bookmark, refusal, lapse, applyFolderList, window listing
off, labels.list, rereadLater, unreadable message, GmailDetailBatch, re-read budget, changeRereadBudgetPerPass,
background deadline, unlistable folder, retry account row, #444, #783, #735, #715, #464, #460.

### Amendment 2026-11-12: Outlook reads folder by folder

**Context.** Outlook's old change path read one Graph message delta for the Inbox only
(`exchangeDeltaSync`), fetched every changed message by id, and was bounded by a cursor capture after the
full sync (`captureSyncCursors`, `getCurrentDeltaLink`, `deltaWalkContinuation`). Every other folder was
seen only by the 15-minute window listing, so a message another client moved into Archive outside that
window never appeared (#722, #536), and changes to older mail were lost (#464, #460).

**Decision.**
1. **The seam, widened for a reader that reads folder by folder** (`EmailProviderChanges.swift`):
   - `ChangeFolder.cursor`: each folder keeps its own opaque bookmark, `Folder.changeCursor` (v103,
     nullable TEXT, NULL = no bookmark yet). The engine writes back `FolderChanges.cursor` in that
     folder's transaction.
   - `ChangeFolder.isSynced`: the folder is in the full sync's syncable set
     (`SyncEngine.syncableFoldersInOrder`); a per-folder reader reads only these. *Amended 2026-11-22
     (#1109):* the set also holds every followed folder (`Folder.isFollowed`, a folder a user action
     landed in); see the amendment of that date at the end.
   - `ChangeFolder.heldSince`: the start of the folder's held range (`Folder.oldestSyncedDate`), a hint
     only; the apply checks the range again inside the transaction.
   - `ChangeRequest.localRows`: the existing `CatchUpLocalRowReader` (ids and two flags, never content;
     ADR-004), so a reader whose records lack the header fields fetches headers only for messages a folder
     does not hold.
   - `ChangeContext`: the caller's read deadline, an injectable clock and `isExpensiveNetwork`, a value
     snapshot taken when the pass's turn starts. *Superseded 2026-11-19 (#1063): every state baseline runs on any network; see ADR-IOS-107, amendment of that date.*
   - `FolderChangeStatus.baselining` (a folder's first round in progress); `ChangeRefusal.rejected(status)`
     and `.failingTooLong`; `AccountCursorUpdate.unchanged` (the read succeeded and the stored account
     part stays); `FolderListUpdate.complete` / `.updated`.
2. **A refused FOLDER bookmark touches that folder only**, in its own transaction: its bookmark is cleared,
   it is untracked, its catch-up gets one lapse mark, and the full sync is made due. The account part and
   every other folder's bookmark survive. A refused ACCOUNT bookmark keeps decision 6.
3. **Baseline records.** A record from a folder's first round (`.baselining`, `.baselineReady`)
   updates a stored row, and inserts only a message dated within the folder's held range, checked inside
   the transaction; a folder with no held range (after a reset) inserts nothing. A later round's record
   inserts at any age: a message moved in by another client appears whatever its date (#722, #536).
   *Amended 2026-11-26 (#1363):* a folder with no held range whose older-mail walk has completed (the walk
   found it empty) holds the whole folder and inserts at any age; see the amendment of that date at the end.
4. **The read budget ends before the caller's deadline** (`SyncEngine.changeReadEnd`): the smaller of
   `SyncConfig.changeReadBudgetSeconds` and the caller's deadline less one request's timeout
   (`changeReadRequestTimeoutSeconds`) and the apply margin (`changeReadApplyMarginSeconds`). No request
   starts after it, and every request is given up after its timeout, so what a pass reads is applied
   before the caller stops waiting. A pass whose turn starts with too little time left reads nothing
   (`.notRun`) and keeps every bookmark; nothing is dropped, the next pass reads it. The arithmetic is
   beside the constants in `SyncConfig`. (ADR-IOS-104 decision 2 amended: the pass takes the caller's
   deadline, which is not account sync state.)
5. **Outlook's reader** (`ExchangeProviderChanges.swift`):
   - **Bookmarks.** The account part (`OutlookAccountCursor`, `{"v":1,"folders":"<link>"}` in
     `Account.lastHistoryId`) is the mail-folder delta link only; an older build's Inbox delta link reads
     as no bookmark. Each folder's `OutlookFolderCursor` holds the link to read next, its phase (baseline
     or tracking), its `$select` kind, the round's page count, the first counted failure and when its
     baseline was first needed. *Superseded 2026-11-19 (#1063): every state baseline runs on any network; see ADR-IOS-107, amendment of that date.*
   - **Two `$select`s, chosen by role when a chain starts and stored in the cursor.** The Inbox uses the
     header fields (`ExchangeGraphMessageRequest.readChanges`, `GraphAPI.headerOnlySelection`), so new
     Inbox mail arrives in the delta page itself. Every other folder uses the state set
     (`GraphAPI.stateSelection`: `id,isRead,flag,receivedDateTime,categories`). A change to a message the
     phone holds applies from that record; a message the folder does not hold whose record carries
     `receivedDateTime` (a new or moved-in message) gets its headers fetched, when the folder is tracking,
     or during its baseline when the message is within the held range (with no range, every such message
     once the folder's older-mail walk has completed; amended 2026-11-26, #1363).
   - **Why not ids only.** A delta chain keeps the `$select` it was started with (Graph encodes it in the
     next and delta links), and later rounds carry only selected fields. With `$select=id` every read or
     flag change would cost one GET per message, or might not be reported at all; a change key says only
     that something changed. The state set carries exactly what the merge writes for a stored row
     (`isRead`, `isFlagged`; the merge never writes subject, sender or recipients into a stored row), so
     it is correct for every apply rule.
   - **Size (estimates, none measured):** per message, uncompressed JSON with Graph's annotations: header
     fields about 1.2-1.5 KB, ids and change keys about 0.3 KB, the state set about 0.35-0.4 KB. For a
     100,000-message folder: about 120-150 MB, 27-33 MB and 35-40 MB. The long message id dominates.
     The request count is the same for all three, one page per `graphChangeReadPageSize` messages.
   - **Headers for missing messages** (`fetchMessageDetails`, Graph `$batch` of at most
     `SyncConfig.graphBatchMaxRequests`): a folder's bookmark never passes a page until every such header
     is in, read as gone (404/410, or now in another folder: that folder's round reports it), or reported
     unreadable for that one message (`rereadLater`). A page cut short by the budget is read again on the
     next pass, which fetches only what is still missing. A 5xx item holds the page and counts towards the
     failure lapse; a throttle, timeout or authorization answer holds it without counting. (Superseded
     2026-11-13, see the amendment below: a 5xx item is unreadable for that one message.)
   - **Request rate.** One read sends at most `SyncConfig.graphChangeReadRequestsPerSecond` (half of
     Graph's documented 10,000 requests per 10 minutes per mailbox, about 8.3 per second) times its read
     budget; every request is charged before it is sent, a `$batch` its width (Graph counts each request
     in a batch). A batch of 20 fits the smallest read's allowance (about 41), so headers are batched.
     Ids beyond the allowance wait on the page and are never dropped.
   - **Network.** A non-Inbox baseline on an expensive network (cellular, a hotspot) waits at most
     `SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds`, counted from when the folder first needed it
     (stored in its cursor), then runs on any network, as the catch-up does (ADR-IOS-107). The Wi-Fi-only
     setting is not consulted. The Inbox baseline runs on any network. *Superseded 2026-11-19 (#1063): every state baseline runs on any network; see ADR-IOS-107, amendment of that date.*
   - **Failures.** A refused bookmark (`graphRefusedDeltaToken`: a 4xx other than 401, 403, 408 and 429) is
     `.refused(.rejected(status))`; a refused saved baseline continuation restarts the baseline from page 1
     once per pass first. A 5xx, a page that cannot be decoded, a repeating next link or a round longer
     than `changeReadMaxRoundPages` counts towards `changeReadFailureLapseSeconds`, after which the folder
     is `.refused(.failingTooLong)` and starts a new baseline. (Superseded 2026-11-13, see the amendment
     below: a round's length is never a failure, and `changeReadMaxRoundPages` is deleted.) A baseline that read something before a
     failure reports `.baselining`, so its records stay baseline records.
   - **Folder list** (scope `.all`): the mail-folder delta is a change signal. Records for folders already
     stored update their name and count in place (`.updated`); a new folder, a removed one or a record
     without its name and count runs the complete tree listing (`fetchFolders`, `.complete`), with the new
     link minted before it. No link yet, or a refused one, mints it first and then lists. Hidden folders
     stay listed. Search folders are ignored.
   - **Order.** Folders already tracking before those in their baseline, the Inbox first in each. Scope
     `.inboxOnly` (push, background) reads the Inbox only; `.all` reads every syncable folder.
   - **Re-reads** go through `fetchMessageDetails` too: in the folder = a record; gone or elsewhere = a
     removal here; unreadable = read again later. Ids not read within the budget stay listed.
   - The well-known folder ids (Inbox, Archive, Deleted Items) are set from the request's roles on every
     read, so the legacy category strip (ADR-IOS-036) has them in a process whose full sync skipped
     discovery.
6. **Deleted:** the Outlook arm of `performChangePass`, `exchangeDeltaSync`, `captureSyncCursors` and its
   caller branch, `getCurrentDeltaLink`, `deltaWalkContinuation`, `SyncConfig.graphDeltaCursorWalkPageSize`,
   and the `EmailProvider.fetchHistory` requirement with the Exchange, IMAP and Demo implementations
   (Gmail keeps its own `fetchHistory`).

**Costs.** Every message that arrives in a non-Inbox folder from another client costs one header GET
(one `$batch` item): mail archived on the web or desktop, sent from another device, or delivered to Junk.
A bulk web move of 2,000 messages into Archive costs about 2,000 batch items, spread over passes by the
request rate. In-step folders cost pages only. Moves made on the phone are re-keyed locally and cost
nothing.

**Limits.** A hidden folder created on the server is found at the next structural change (a new, removed
or renamed-without-count folder), when the complete listing runs, if the folder delta does not report
hidden folders. A record for a search folder's child runs the complete listing each time it appears.

Keywords: Outlook change reader, ExchangeProviderChanges, per-folder bookmark, changeCursor, v103,
OutlookFolderCursor, OutlookAccountCursor, folder refusal, baselining, baseline held range, changeReadEnd,
caller deadline, read budget, state selection, stateSelection, headerOnlySelection, ids only, delta chain
$select, $batch, graphBatchMaxRequests, graphChangeReadRequestsPerSecond, expensive network wait,
mail-folder delta, FolderListUpdate, hidden folders, failingTooLong, #722, #536, #450, #458, #548.

### Amendment 2026-11-13: a round's length is never a failure; one message's 5xx is unreadable

**Context.** Two rules of decision 5 above failed in ways a user sees. (a) A round longer than
`changeReadMaxRoundPages` counted towards the failure lapse: a folder of more than about 200,000 messages
(or any folder Graph serves in pages smaller than asked for) could never finish its first round, so it
started its baseline again every lapse, forever. (b) A 5xx answer for one message's header fetch held the
page: every later change in that folder stayed hidden until the lapse, then the folder started again,
met the same message and looped.

**Decision.**
1. **A round's length is never a failure.** `changeReadMaxRoundPages` and the cursor's round page count
   are deleted. A round that moves page after page is saved page by page; each pass is bounded by its
   read budget and request allowance, and a next link that repeats still counts as a failure.
2. **One message's server error is about that message**, as Gmail's reader already rules (decision 7,
   #444): `fetchMessageDetails` classes a 5xx item as unreadable, it goes on the folder's re-read list
   (`rereadLater`) and the page passes. A throttle (429), a timeout (408) and an authorization answer
   (401, 403) for an item still hold the page without counting; a failure of the whole `$batch` request
   still holds it, a 5xx counting towards the lapse.
3. **A record carries only what Graph sent.** A full Inbox record takes `isRead` and `isFlagged` from the
   delta record (absent = not written, never the parser's default), and no Graph record carries a
   References chain, so a stored chain stays (`ChangeRecord.references` nil).
4. **A partial record never settles a message on the re-read list** (`ChangeRecord.carriesReadAndFlag`).
   A change kept back under the user's pending action may be to the read state or the flag; a later record
   that lacks either (Outlook's read-state-only record) applies what it carries and the message stays
   listed. The reader counts such a message as unanswered, so the re-read reads it in full in the same
   pass when the allowance has room, otherwise on a later pass. Before this, the read-state-only record
   that follows the user's completed read removed the message from the list, and a flag change another
   client made meanwhile was lost in a tracked folder (found by the Outlook fuzzer through the engine).
   The settle set is the read state and the flag, not the server tag the apply also holds back: no reader
   carries a server tag today (Gmail and Graph tags are local-only, ADR-IOS-036; their records' `serverTag`
   is always nil), so no tag change can be held back. When the IMAP reader carries the tag keyword, its
   records need a "no tag" value distinct from "not sent", and the settle set then includes the tag.
5. **A partial record never inserts a message.** A record for a message the folder does not hold that
   lacks the read state or the flag (an Inbox record Graph sent without `isRead` or `flag`) is declined:
   the message goes on the re-read list and the full re-read inserts it. Before this, it was stored with
   the parser's default (unread, unflagged) and never listed, so it kept the wrong state until the next
   change to it.

Keywords: partial record insert, new message default read state, settle set, server tag not carried, no-tag value, changeReadMaxRoundPages deleted, round length, long round, per-item 5xx, unreadable header,
rereadLater, page hold, absent field, references kept, partial record, carriesReadAndFlag, kept-back flag
change, #444.

### Amendment 2026-11-13: the Outlook catch-up next to the change reader

The change reader stays the only path that reports changes after a folder's first read. Outlook's
older-mail catch-up (ADR-IOS-107, amendment 2026-11-13) covers what the reader cannot: messages
deleted or changed before the folder's first read (a baseline never removes) and changes lost in a
lapse. It starts a folder's listing only while the folder's bookmark is tracking
(`ExchangeProvider.catchUpTrackingGateOpen`), so every deletion falls either before the listing,
which sees it, or after the first read began, which the delta reports. It pages by received-date
keyset, takes a quarter of the mailbox request rate, and lists a folder once more after its backfill
walk completes. Its apply never lets a read that began before a user action completed overwrite
that action's read or flag state (ADR-IOS-107, completed actions), nor put back a message the user
moved out of the folder after that read began (ADR-IOS-107, "Loads too", later the same day).

### Amendment 2026-11-14: the change merge writes user labels; replied and forwarded are not read (#882)

**Context.** The merge wrote only the read state, the flag and the server tag. A Gmail label or Outlook
category another client added or removed reached a stored message only if the message was inserted
again, so label chips stayed stale on both providers. The records already carried the label set
(`ChangeRecord.userLabelIds`), but the merge never read it, Outlook's state-only record dropped the
`categories` it had decoded, and a Gmail push pass (`.inboxOnly`) in a fresh process read messages
before the label catalog had loaded, so its label sets were not complete.

**Decision.**
1. **A record's label set means what it says.** `ChangeRecord.userLabelIds` is nil when the record does
   not know the labels (the header's `userLabelIdsAreAuthoritative` is false, or Graph did not send
   `categories`), and a set, empty included, when it does. A Gmail header's set is known only when the
   label catalog has loaded AND knows every label id on the message (`GmailUserLabelCatalogState.isCompleteUserLabelSet`:
   each id listed by the last `/labels` or one of Gmail's system labels, `GmailProvider.systemLabelIds`). A set REPLACES the stored labels of the
   message in the merge (`SyncEngineChangesApply.replaceUserLabels`: junction rows not in the set are
   deleted, missing labels and junction rows are inserted); nil writes nothing.
2. **The user's pending label change wins, like read and flag.** `PendingOperationSnapshot.userLabel`
   (`.addUserLabel`, `.removeUserLabel`) and the completed-action shield (`liveRecentlyCompleted`) hold a
   label change back; the message goes on the re-read list and the next pass re-reads it.
3. **The settle set now includes labels.** A record settles a re-read id only when it carries read state,
   flag and labels (`ChangeRecord.carriesKeptBackFields`); Outlook's `answeredIds` uses the same test.
   A record without labels applies what it carries and the message stays listed (decision 4 of the
   2026-11-13 amendment, extended to the label set).
4. **Outlook's state-only record carries its categories** (filtered by `isLegacyActionTagCategory`,
   verbatim names), absent = nil.
5. **Gmail loads the label catalog before it reads any message detail** when the catalog is not loaded
   (`GmailProvider.isUserLabelCatalogLoaded`); a failed catalog load fails the pass with the bookmark
   kept, as any account failure does. **A label created on the server after the catalog loaded**
   (the web's "Label as > Create new", which creates and applies in one gesture) is an id the catalog
   does not know: the reader reloads the catalog once in that pass and extracts the labels again
   (`GmailProvider.reextractUserLabels`). An id still unknown makes that message's set unknown (nil):
   the stored labels stay, and the reader puts the message on the re-read list of every folder its
   record lands in (`rereadLater`), so a later read that knows the set lands it. A failed reload leaves
   those sets unknown the same way and does not fail the pass. (Corrected in review the same day: the
   first wording said such a label was "unknown until the next `.all` pass" while the record still
   counted as complete. In fact the label was lost for good on that message, since the next pass never
   re-read it, and a stored label the process's catalog did not know was deleted.) The listing is the
   Gmail reader's, not the apply's: Graph's read-state-only record also lacks `categories`, and listing
   it would re-read every message another device marks read, though nothing about its categories
   changed.
6. **Replied and forwarded are not written by the merge.** No reader carries them: Gmail has no such
   server state, and the Graph records do not select `PidTagLastVerbExecuted`; both providers' records
   say false by default, and writing that would wipe the marks the outbox and Sent-folder discovery
   (`ReplyParentResolver`) set. Reading Outlook's last verb is a new feature for a separate issue.

**Not changed.** The full sync's existing-row merge and the catch-up still only insert label rows. The
release-boundary re-read list does not yet name label or replied kinds; that list is another change, and
once both are merged the label kind belongs on it. *(Done 2026-11-14, #903: the user-label kinds are on
the release-boundary re-read list; replied/forwarded are still not.)*

**Trade-off.** A label change raced by the user's own label action lands one pass later (the re-read),
as read and flag already do. An Outlook record that keeps omitting `categories` keeps the message on the
re-read list until a full read answers it. A Gmail message whose label id no `/labels` listing names
is re-read, with one catalog reload, on each pass until it is named (bounded by the re-read budget and
`changeRecheckLimit`).

Keywords: user labels, label merge, replaceUserLabels, Gmail labels, Outlook categories, label shield,
PendingOperationSnapshot.userLabel, carriesKeptBackFields, settle set labels, userLabelIdsAreAuthoritative,
label catalog, isUserLabelCatalogLoaded, inboxOnly push pass, isCompleteUserLabelSet, listedLabelIds,
systemLabelIds, reextractUserLabels, unknown label id, label created after catalog, catalog reload,
replied, forwarded, PidTagLastVerbExecuted, ReplyParentResolver, #882.

### Amendment 2026-11-14: the release boundary fills the re-read list (#876)

Decision 4 took the window listing away from tracked folders, and with it the correction the release
boundary relied on for actions it retires (ADR-IOS-071). The boundary now writes the re-read list
itself: before its delete it reads each retired row's raw columns only and appends the ids of a move or
read/flag change to `Folder.changeState.recheck` of the source folder and, for a move, the destination
folder, whatever that folder's tracking or synced state (see the next amendment: every listed folder
is read, and an explicit re-read answer applies whatever the window). *Superseded within this
amendment, same day, twice:* (1) "only where that folder is tracked"; (2) "only where the change
reader reads that folder: the syncable set (`SyncEngine.isSyncable`, the folders
`ChangeFolder.isSynced` marks), tracked or not. [...] a folder outside the syncable set is never read
by a per-folder reader, and an id there would hold part of every pass's re-read budget". (2) held only
for Outlook (Gmail reads every list), and it left an older message stuck in a custom non-favourite
folder, which the master-agent ruled a stuck state, not an edge. For every account holding a
change bookmark (`SyncEngine.recheckRetiredActions`,
provider-blind, pinned by `ChangeSeamFenceTests.retiredActionRecheckIsProviderBlind`). The cap and the
overflow rule are decision 3's. A row the release cannot decode arms its folder's catch-up (the
account's when the folder is unknown). A re-read id is answered as any other (record in the folder,
removal where the message is not); the Outlook reader now also reads the list of a folder outside the
synced set (next amendment). *Superseded same day:* "Readers need nothing new". The IMAP reader, when it lands, inherits
these ids on its folders' lists. *Amended 2026-11-16 (#751):* the IMAP reader keeps its bookmarks per folder, so
`Account.lastHistoryId` stays NULL and "an account holding a change bookmark" also means an account whose ids are
mailbox-local (not in `AccountOperationExecutor.accountScopedIdAccountIds`) holding a bookmark on any folder. For
such an account a retired move takes the exit rule (item 11 of the IMAP amendment): its source and destination drop
their bookmark with one self-heal owed, and its ids go on no list (a source UID names nothing, or another message,
in the destination, and the optimistic row there can never prove it owns the address); every folder of the account
when the destination is not recorded or a folder does not resolve. A read/flag or user-label row lists its ids on
its own folder, also when a retired move drops that folder (the listing never replaces a held row's user labels;
the folder's baseline read answers the list). A draft delete or an undecodable row drops its folder's
bookmark the same way (the IMAP catch-up only checks held rows). `dropChangeBookmark` reads raw columns only.
Detail: `IOS-ACTION-003` ("Retired actions read again").

Keywords: release boundary, retired actions, recheckRetiredActions, appReleaseStamp, purge, re-read
list, undecodable row, #876.

### Amendment 2026-11-14: every listed folder is read; an explicit re-read answer applies whatever the window (#876)

Two rules of the re-read list (decision 3), so that an id on a folder's list always gets the server's
answer in that folder, for a message of any age:

1. **A per-folder reader reads every listed folder's list.** A reader that reads folder by folder reads
   a synced folder's list after its delta, also during its baseline (as before), and, on a `.all`
   pass, the list of every folder outside the synced set whose list is not empty, on its own: each
   listed message read by id and answered for that folder (a record where the server holds it, a
   removal where it does not), returned as `.notRun`, so no bookmark and no coverage change.
   `ChangeFolder.isSynced` now decides only which folders' CHANGES are read, never whose list is.
   Outlook: `ExchangeProvider.fetchChanges` runs `reread` (one GET per id, by `parentFolderId`) for
   those folders. Gmail already read every list (account-wide `messages.get`, every folder answered by
   the message's labels). An `.inboxOnly` pass still reads the Inbox only; the other lists wait for the
   next `.all` pass.
2. **An explicit re-read answer applies whatever the window.** A baseline record is the folder as it
   is, gated by the held range (`Folder.oldestSyncedDate`; older mail is the backfill's). A record
   whose id is on the folder's own re-read list, read inside the folder's transaction, is the server's
   answer about that one message, so the gate does not apply to it
   (`SyncEngine.applyFolderChanges` passes `heldRangeApplies` false for it): it is inserted or merged
   wherever its date falls, also below `oldestSyncedDate` (ruled acceptable: that is where the row was
   before the gesture, and the backfill upserts by id). The bypass is strictly for a listed id; a
   baseline record for an unlisted older message is still not inserted. Removals were never gated.
3. **A list is cut only where the catch-up will find the rest** (added same day, review round 4;
   *amended 2026-11-15, #903: a stored id is never cut, see the amendment below*). Over
   `SyncConfig.changeRecheckLimit`, a folder the catch-up checks (`SyncEngine.isSyncable`: a main role
   or a favourite, the same set `syncableFoldersInOrder` gives the full sync and the catch-up run;
   *amended 2026-11-22, #1109: or a followed folder*)
   keeps its first ids and its catch-up is armed, as decision 3 says. A folder the catch-up never
   checks keeps every id: arming its catch-up is a no-op there (`markCatchUpLapse` updates only a
   non-NULL state, and the catch-up run never takes that folder), so a dropped id would stay wrong for
   good. Both the change apply (`applyFolderChanges`) and the release boundary
   (`recheckRetiredActions`) apply this rule. The cost stays bounded: each pass reads at most
   `changeRereadBudgetPerPass` ids within its request allowance, and the list holds only distinct ids
   of that folder. A role this release cannot read counts as not checked (every id kept).
   Chosen over dropping the cap everywhere: in a checked folder, one whole-folder check is cheaper than
   reading hundreds of ids fifty a pass, and that path is unchanged.

Why: the release boundary (#876) lists retired ids on every folder the action named. Without rule 1
an Outlook folder outside the synced set never had its list read (the ids stuck, and the optimistic
row of an older message stayed for good: the full sync never lists such a folder, and opening it
lists only a date window); without rule 2 an Outlook folder whose read was a baseline settled a
listed id without restoring the message (the record was gated, then counted as applied). Both are
stuck states, not edges (master-agent ruling, 2026-11-14).

Tests: `ReleaseBoundaryRecheckTests` (`olderMessageReturnsToABaseliningInbox`,
`baselineGateHoldsForAnUnlistedId`, `gmailCustomLabelsAreReadAgain`, `outlookCustomFolderIsReadAgain`,
`listedInEveryNamedFolder`; rule 3 and the custom-folder read: `customFolderKeepsEveryRetiredIdAndReadsThemAll`,
`applyOverflowDropsOnlyWhereTheCatchUpChecks`, `unreadableRoleKeepsEveryRetiredId`,
`favouriteCustomFolderIsCutAndArmed`, `customFolderReadChangesNoCoverage`,
`inboxOnlyPassLeavesTheCustomList`, `failingCustomReadHoldsBackNothingElse`,
`customReadStaysWithinTheAllowance`).

Keywords: re-read list, recheck, non-synced folder, custom folder, notRun, baseline gate, held range,
oldestSyncedDate, heldRangeApplies, explicit re-read answer, changeRecheckLimit, overflow, isSyncable,
catch-up coverage, #876.

### Amendment 2026-11-15: a stored id is never cut; only a pass's own additions are (#903)

Decision (coordinator ruling, option B): the re-read list's limit (`SyncConfig.changeRecheckLimit`)
no longer cuts ids already stored.
1. The release boundary (`recheckRetiredActions`) keeps every retired id, in every folder, and arms
   no catch-up for them. The set is finite and written once; each pass reads at most
   `changeRereadBudgetPerPass` ids, so a long list drains over passes.
2. In the change apply (`applyFolderChanges`), in a folder the catch-up checks, when THIS pass's own
   additions (declined or `rereadLater` ids not already listed) take the list over the limit, only
   those additions are cut, keeping as many as fit after the stored ids, and the folder's catch-up is
   armed for them. A list already over the limit is never cut back by a later pass. A folder the
   catch-up never checks stays uncapped; ordering is unchanged.
Why: the catch-up never corrects user labels, so a retired label id cut to the catch-up stayed wrong
for good; draining corrects every kind. The reader's own bursts keep the old bound and the old
whole-folder check. *Superseded by this amendment:* rule 3's "in a folder the catch-up checks, the
list keeps its first ids and arms the catch-up" for ids already stored, and its application at the
release boundary.
Tests: `ReleaseBoundaryRecheckTests` (`manyRetiredLabelIdsDrainInACheckedFolder`,
`applyCutsOnlyThisPassesAdditions`, `overflowKeepsEveryRetiredId`,
`favouriteCustomFolderKeepsEveryRetiredId`), `OutlookCatchUpTests.recheckOverflowRebaselinesAndHealsAFlag` (renamed 2026-11-20, #1107, from
`recheckOverflowHealsAFlag`: it now asserts the dropped bookmark of the 2026-11-17 amendment and
re-baselines before the listing),
`ChangeApplyTests.recheckOverflowArmsCatchUp`.
Keywords: changeRecheckLimit, overflow, stored ids never cut, this pass's additions, retired ids
drain, #903.

### Amendment 2026-11-17: an overflow in a folder holding its own bookmark re-baselines it (#751)

Decision (coordinator ruling, 2026-11-17): item 2 of the #903 amendment above is amended for a folder that holds
its own change bookmark (`Folder.changeCursor`). There, when this pass's own additions are cut, the
folder's bookmark is also dropped (`cutDropsBookmark` in `SyncEngine.applyFolderChanges`, through
`dropChangeBookmark`, which arms the catch-up as well): the folder is listed again and its next read
starts a new baseline.
Why: that folder's catch-up need not load a missing message (the IMAP one only checks the rows a folder
holds), and the bookmark would otherwise move past a cut arrival. A folder with no bookmark keeps the
#903 behaviour (catch-up armed).
1. **Bounded per pass, resumed later.** The re-baseline is paged; a pass starts no request after its
   deadline (a request already sent may finish within its own timeout) or past its request allowance
   (`graphChangeReadRequestsPerSecond` x the read budget). A folder that fits in the allowance can finish
   in one pass; an unfinished baseline resumes page by page on later passes.
2. **Networks.** The Inbox re-baseline runs on cellular, as the Inbox baseline already does by design;
   other folders' state baselines wait on an expensive network as before
   (`catchUpExpensiveNetworkMaxWaitSeconds`). *Superseded 2026-11-19 (#1063): every state baseline runs on any network; see ADR-IOS-107, amendment of that date.*
3. **Cost on Outlook.** For a folder of N messages: about N/100 delta pages
   (`graphChangeReadPageSize` = 100), plus header fetches only for messages a non-Inbox folder is
   missing within the held range, plus the by-id reads of the folder's re-read list (at most
   `changeRereadBudgetPerPass` ids a pass).
4. **Replied and forwarded arrows.** The baseline's delta pages expand no last verb and there is no
   baseline verb sweep (#890 amendment); only its by-id reads (missing messages, re-read ids) expand it.
   The listing the dropped bookmark makes due expands the last verb, so cut ids inside the listing
   window get their arrows back. The #903 limitation remains for mail older than the listing window.
This PR adds no new limitation.
Tests (added 2026-11-20, #1107): `OutlookCatchUpTests.recheckOverflowRebaselinesAndHealsAFlag` (a real
read whose cut arrival answers 500 drops the bookmark and stores none of the read's later one, makes the
full sync due, and the re-baseline loads the cut arrival), `IMAPMoveIntoTrackedFolderTests.cutArrivalLandsAfterTheListing`.
Keywords: cutDropsBookmark, overflow, own bookmark, re-baseline, listed again, delta pages, cellular
Inbox, last verb, listing window, #751, #903.

### Amendment 2026-11-14: Outlook reads the last verb; the merge sets replied and forwarded (#890)

**Context.** Decision 6 of the #882 amendment left replied and forwarded unread: a reply made in Outlook
on the web, the desktop or another phone never showed its arrow in TabMail. Outlook keeps the last action
on a message in PidTagLastVerbExecuted (`Integer 0x1081`: 102 reply to sender, 103 reply to all, 104
forward). Measured 2026-11-14 on a test account: a reply from Outlook on the web sets it to 102 and the
Inbox message delta reports the message as changed, but the delta cannot carry the property (`$expand`
on delta is a 400, a `$select` of it is ignored). Also measured: a reply sent the way the app sends it
(Graph `sendMail`) does NOT set it: the original's 0x1081/0x1082, lastModified and changeKey stay and the
delta reports nothing. So the absence of the verb never means "not replied": the phone marks its own
replies (`ReplyParentResolver`, the outbox) and no read may clear that mark (pinned by
`appReplyMarkSurvivesAnOriginalWithNoVerb`). Marking the original on the server is a separate issue (#915).

**Decision.**
1. **Read by id, never on the delta.** `GraphMessageSelection.expandsLastVerb` adds
   `GraphAPI.lastVerbExpandParameter` to the listings (`fetchMessages`, `fetchOlderMessages`,
   `fetchMessageHeaders`) and to `fetchMessageDetails`; `parseGraphMessage` maps the verb to
   `MessageHeaderInfo.isReplied` / `isForwarded`. The delta selections (`readChanges`, `stateSelection`)
   never expand. The verb stays inside the Exchange provider; above the seam only the generic marks travel.
2. **The reader reads the verb of every changed message in a tracking round.** Each record taken from a
   delta page (a held message's state record, an Inbox header record) is also read by id
   (`readLastVerbs`, `fetchMessageDetails` in `$batch`es) after EVERY folder's delta in the pass, out of
   the allowance left, so they never delay paging or new mail (review round 1: read inline, one page of
   changes spent a short pass's whole allowance and held new mail behind it). These reads NEVER hold the page: a message whose verb was not read (budget or
   allowance spent, a failed batch, a throttle, an unusable answer) goes on the folder's re-read list
   (`rereadLater`), whose full read carries the verb. (First draft held the page like a missing header;
   that wedged: a page of more changes than one pass's allowance could never pass, and a cut page's
   landed messages became held, needing verb reads again. Found by the existing long-round and burst
   tests.) Only the replied and forwarded marks join the record; an inserted record takes them too. A baseline reads none.
3. **The merge only sets.** `ChangeRecord.isReplied` / `isForwarded` (false = not known or not shown) set a
   stored row's mark and never clear it: the phone's own reply marks its parent before the server shows
   it, and Outlook keeps only the LAST verb, so a forward after a reply reads as not replied. A newly set
   replied mark runs ReplyDetect (a `reply` tag becomes `none`), as the insert and the full sync's merge do.
   This supersedes decision 6 of the #882 amendment. The full sync's merge already only upgraded.

**Costs.** Every message another client changes (read, flagged, categorised, replied, new in the Inbox)
now costs one `$batch` item per tracking round, charged against the request allowance; in-step folders
are no longer pages only. Verb reads beyond a pass's allowance move to the re-read list (at most
`changeRereadBudgetPerPass` a pass; over `changeRecheckLimit` the catch-up is armed, which does not read the
verb, so a very large burst may leave some arrows unshown until the message changes again). Verb-only ids
share that list, its per-pass budget and its limit with ids kept back under a user action, so a large
burst (a web "mark all read") delays those re-reads and can overflow the list into a catch-up. Under the
#903 amendment above, verb ids a pass lists (via `rereadLater`) are that pass's own additions: once
stored they are never cut and drain `changeRereadBudgetPerPass` a pass; in a folder the catch-up checks,
additions that would take the list over `changeRecheckLimit` are cut (the verb ids among them lose their
arrow until the message changes again, as the catch-up armed for them does not read the verb); a folder
the catch-up never checks keeps them all.

**Encoding.** `lastVerbExpandParameter` has literal spaces: a request URL is percent-encoded once when sent,
so a pre-encoded `%20` became `%2520` and Graph would not have expanded it. A `$batch` item's URL travels in
the JSON body unencoded, so `GraphAPI.batchItemURL` encodes its spaces.

**Limits.** A message replied to elsewhere before its folder's change bookmark began tracking shows the
arrow only if the full sync's window listing lists it or it changes again; the Outlook catch-up listing
does not read the verb. The arrow is never written to the server (Mail.Send and phone-sent replies are
out of scope).
*Amended 2026-11-15 (#915):* the app now writes the verb on the original after a confirmed send
(memory 151); the reader sees that echo as a mark already set locally, so it changes nothing.

Tests: `OutlookLastVerbTests.swift` (extension of `OutlookChangeReadingTests`).

Keywords: last verb, PidTagLastVerbExecuted, 0x1081, replied, answered, forwarded, reply arrow,
singleValueExtendedProperties, $expand, expandsLastVerb, readLastVerbs, batchItemURL,
double encoding, ReplyDetect, #890.

### Amendment 2026-11-16: Gmail resumes its history read (#491)

**Context.** Gmail's reader read the whole history through `GmailAPI.historyList` and refused it
(`.refused(.expired)`: bookmark cleared, every folder untracked, the same pass re-lists) when it held more
than `GmailAPI.historyMaxChanges` records or changed messages or ran past `historyMaxPages` pages. That
rule came from #429 (memory 041), where a 20,000-record delta timed out before its cursor moved and failed
the same way on every poll; resuming from a record was never weighed. A web bulk archive of a few hundred
messages, or a long background gap, therefore re-listed every folder. The Outlook amendment of 2026-11-13
already made a round's length never a failure and saved progress page by page.

**Decision.**
1. **Record by record within the time budget.** `GmailProvider.readHistory`
   (`GmailProviderHistoryRead.swift`) reads `GmailAPI.historyPage` (`maxResults` 500, all four history
   types, no label filter). The first page of a pass is always read; a later page starts only while the
   pass's budget lasts (`ChangeContext.hasBudget`), and at most `historyMaxPages` pages are read. Before
   each record but the pass's first, the budget is checked; when it is spent the pass stops before that
   record. No fixed record or message count bounds the app's read (`historyMaxChanges` binds only the
   notification extension).
2. **One record is read whole.** A record's added and relabelled messages are queued and read
   `GmailAPI.maxConcurrentRequests` at a time (`fetchMessageDetails`), and at the end of the read. A record
   naming more messages than the budget covers (a conversation-wide change) is read whole; that pass runs
   over. There is no special refusal for it.
3. **Two bookmark values.** A read that reaches a page with no `nextPageToken` stores the first page's
   `historyId`, as before. A read that stops early (budget or page cap) stores the `id` of the last record
   it took; `users.history.list` returns the records after `startHistoryId` in increasing id, so the next
   pass resumes with the first record not yet taken and nothing is listed again. A pass that took no record
   keeps its bookmark. *Amended 2026-11-16 (#938):* a pass that reads `historyMaxPages` pages without
   taking a record is refused like an expired history (`.refused(.expired)`: bookmark cleared, the same
   pass re-lists and stores a fresh bookmark), as every page-cap pass was before #491; a pass whose time
   budget runs out before it takes a record still keeps its bookmark.
4. **Boundary validation.** The stop point must be a numeric id greater than the numeric bookmark the pass
   read from; otherwise the read is refused as for an expired history. A 404 is still `.refused(.expired)`
   with the same-pass re-list (decision 6 unchanged). So is the page cap reached with no record taken
   (#938, decision 3).
5. **Write order unchanged.** The folder transactions are written first and the bookmark after them, in its
   own transaction. A failure about the account while reading messages keeps the bookmark (`.failed`); a page
   that cannot be read throws. A crash between the two re-reads the same records, which is harmless: the
   reader writes each message's current server state, not what a record says.
6. **Re-reads during a pass.** A record whose id is past the first page's `historyId` was written after the
   pass's first reads began, so a message it names that was already read is read again; a message named
   again by a record the first page covered is not.
7. **Injected clock.** `SyncEngine(changeReadClock:)` (the wall clock in the app) is the clock of
   `changeReadEnd` and `ChangeContext.clock`, so tests drive the budget deterministically.
8. **Out of scope: the notification extension.** It keeps `GmailAPI.historyList` (read whole, nil past
   `historyMaxChanges` or `historyMaxPages`, its own cursor map). It does not resume.
9. **Deleted:** `GmailProvider.fetchHistory`, `HistoryResponse`, `HistoryMessageRef`, `HistoryLabelChange`;
   the fake's `answerHistoryTooLong`.

This supersedes, for the app's Gmail reader, the #429 rule that a history too long for one delta is
refused like an expired one (memory 041), and the "Not done here" line about the record limit above.

**Costs.** A backlog lands over several passes rather than through one re-list; each pass applies what it
read. A resume id is as old as the oldest change not yet applied and ages like any bookmark (a 404 past
Gmail's retention re-lists). A pass with a very large record runs past its budget by that record's reads.

Tests: `GmailDeltaApplyInvariantTests` P18 (cut and resume with no listing; short pages over passes, by
budget and by page limit; add then relabel across the cut; a record over the budget applied whole),
`GmailHistoryPaginationTests` (page limit stops and resumes, stop-point validation, re-read of a message a
record written during the pass names, long and deletion histories in one pass). #938: P18 "page cap
without taking a record re-lists" and "budget runs out before a record keeps its bookmark, one page short of
the cap" (`StatefulGmailActionServer.serveEmptyHistoryPages`); `GmailHistoryPaginationTests` "a history whose
last page is the last one the cap allows is complete with no record, and not refused".

Keywords: Gmail history resume, per-record resume, readHistory, historyPage, HistoryPage, HistoryRecord,
history record id, startHistoryId, cut, stop point, bookmark, time budget, changeReadClock, historyMaxChanges,
historyMaxPages, too-long history, refusal, re-list, notification extension, page cap with no record,
empty history pages, #491, #429, #938.

### Amendment 2026-11-15: the IMAP reader (QRESYNC, per folder) (#751)

Decision (2026-11-15): IMAP reads changes through the seam with RFC 7162
QRESYNC, folder by folder, on a dedicated change connection (`IMAPProviderChanges.swift`).
1. **Capability gate.** QRESYNC is used only when the server advertises `QRESYNC`, `ENABLE` and
   `UIDPLUS` (`IMAPProvider.qresyncUsable`, capabilities fetched once when the change session opens):
   QRESYNC can only be switched on through ENABLE (RFC 5161), and without UIDPLUS (RFC 4315 COPYUID)
   every move into a tracked folder would land without a proven destination UID (exit rule, item 11). CONDSTORE is never inferred from QRESYNC nor the
   other way. `ENABLE QRESYNC` is sent once per session, on the change connection only. **Connection
   budget** (2026-11-16): the change connection counts
   against the server's limit only while it is open, like IDLE (`maxFolderConnections`; the pool's
   reserved count stays 2, action + IDLE). When a slot is needed, the eviction order is: the change
   connection if it is idle between passes (never while a pass holds or opens it,
   `evictChangeConnectionIfIdle`), then the least recently used folder connection, then IDLE; this
   holds for the folder pool's capacity loop and its limit-error retry. Opening the change connection
   takes the folder connection's refusal handling (`createChangeServer`): a login refused with the
   server's limit (Dovecot's `max_userip_connections` wording) learns the limit, evicts the LRU folder
   connection (else IDLE) and retries once; a second refusal fails the pass through the existing
   failure handling (item 9). No other fallback. Every login made after an eviction (a folder
   connection after the capacity loop evicted, and both limit retries, folder and change connection)
   first waits for the LOGOUTs of the connections that same call evicted (`awaitEvictionLogouts`, at
   most `SyncConfig.imapEvictionLogoutWaitSeconds`): the server counts a session until its LOGOUT is
   answered, so a login sent right after a detached logout was refused again (found 2026-11-16 by a
   fake server that counts sessions; IDLE's DONE + LOGOUT lost that race every time). Each caller
   keeps and awaits only its own evictions' logouts; nothing is stored on the provider. An evicted
   IDLE connection ends its IDLE first (`evictIdleConnection`, 2026-11-16; order amended 2026-11-17):
   the listener is cancelled first (a cancelled listener returns without logging out, as on main's
   `tearDownIdleConnection`), then DONE completes (its tagged OK, or at most
   `SyncConfig.imapIdleEvictionDoneWaitSeconds`: a DONE still unanswered then is cancelled, and SwiftMail
   closes the connection on that cancellation, which ends the session), then the session logs out, once.
   Before, a listener still running took the stream DONE ended as a server-side end and logged the session
   out a second time; earlier still, a LOGOUT could reach the connection ahead of DONE and wait for an IDLE
   nobody ended, past the login's wait, so the login was refused (made deterministic by holding DONE back,
   `idleEvictionEndsIdleBeforeTheLogout`; the bound: `idleEvictionDoneWaitIsBounded`). So a server that allows two connections still runs a
   pass, a folder fetch and an action (before this, the change connection had been a
   third, unevictable one). A server without the pair, an ENABLE that is not acknowledged,
   or a mailbox answering `NOMODSEQ` leaves the folder `.untracked(UntrackedObservation)`: no
   ENABLE is sent, no pass fails on it, and its coverage is cleared. A bookmark the folder holds is
   kept (2026-11-16): nothing of that read is applied to it, so the next read that can track the
   folder goes on from it; dropping it started a new baseline past the messages that arrived
   meanwhile, which background passes never listed.
2. **Bookmark.** `Folder.changeCursor` holds `IMAPChangeCursor` JSON (`uidValidity`,
   `highestModSeq`, `uidNext`, `failingSince`): server metadata, no content (ADR-004). It is never an
   epoch writer; `Folder.lastKnownUidValidity` stays the epoch authority. A folder holding rows under
   an unknown UIDVALIDITY starts no bookmark (IOS-EPOCH-001). A first read is a plain SELECT,
   `.baselineReady` with `FolderChanges.armCatchUpWithBookmark` (the folder's catch-up is armed
   once, in the same transaction that stores the new bookmark. Once a bookmark is stored the catch-up
   runs no periodic check, so the arm is never left to the later commit of tracking: a pass with no
   listing, a failed listing or a crash in between would otherwise leave the bookmark without it).
3. **A read.** STATUS first; an unchanged HIGHESTMODSEQ under the bookmark's UIDVALIDITY (both in the
   STATUS answer) is `.tracked` with no SELECT; a MODSEQ means nothing outside its UIDVALIDITY, so a
   STATUS without UIDVALIDITY never takes this shortcut (2026-11-16). Otherwise
   `SELECT (QRESYNC (uidvalidity modseq))` with its own timeout (`imapChangeSelectTimeoutSeconds`).
   Removals are VANISHED ranges intersected with the folder's held rows (never expanded) and
   `\Deleted` changes on any row the folder holds, at or above the bookmark's UIDNEXT too (a
   moved-in row re-keyed to its destination UID there; a message the server holds as `\Deleted` is
   never shown); changed flags on held rows are partial records (read, flag, answered,
   `$Forwarded`, keywords as user labels); new UIDs and changed-not-held UIDs inside the held range
   are fetched in full and counted against `imapChangeArrivalsLimit` (100); over it the bookmark is
   refused (`.tooFarBehind`) and nothing is fetched (the refusal arms the folder's
   whole-folder catch-up, and the next baseline arms it once more with its bookmark (item 2), so older-mail changes made
   while the old bookmark lived are caught up). Arrivals do not rely on the SELECT's FETCH stream:
   RFC 7162 §3.2.5.1 says only "The server sends the client any pending flag changes (using FETCH
   responses that MUST contain UIDs) and expunges those that have occurred in this mailbox since the
   provided modification sequence", which does not name new messages; so every UID from the
   bookmark's UIDNEXT to the served one is asked for with `UID SEARCH UID <range> ALL`. A UID
   the header FETCH does not return goes on the re-read list (removed only when `UID SEARCH` proves it
   gone), so the bookmark never moves past a lost arrival. STATUS fields the server leaves out
   are unknown, not 0: an untracked folder is then unreadable for the pass. STATUS is never
   sent for the mailbox selected on the change connection; it is selected again instead. A
   folder whose read the apply's binding check rejected is not trackable that pass. **The
   held range for a changed-not-held UID** (2026-11-16) comes from
   the folder's older-mail download progress, carried in `ChangeFolder.olderMailComplete` /
   `olderMailCursor` (`Folder.backfillComplete` / `backfillUidCursor`), never from the rows the folder
   holds now (`IMAPProvider.heldRangeStart`): every UID once the walk completed, above its position
   while it runs, none before it starts (a UID below is the walk's to download). The lowest held row
   had been used before; when that row was removed through `\Deleted` elsewhere and later un-deleted,
   the UID fell below the new lowest row and never came back. Before every pass the change session
   sends a NOOP (some servers answer STATUS from a cached view); the session counts as open only after
   it answers (item 9). No Message-ID pairing: a moved message is inserted
   under its own UID and the leftover copy leaves through its own removal (ADR-IOS-068 D4).
4. **Epoch.** A UIDVALIDITY other than the bookmark's (STATUS or SELECT) is
   `.refused(.addressEpochChanged(served))`: the apply clears the bookmark and the re-read list and,
   only against a KNOWN stored epoch that differs, arms `uidValidityResetPendingAt`; the turnover
   reaction runs after the folder transaction and is re-driven after the next pass's read, within that
   read's budget (`redriveArmedTurnovers`, amendment 2026-11-22 (#1287) below; *superseded in place:* "is
   re-driven at the next pass start"). Every read carries `FolderChanges.addressEpoch`; the apply's binding
   check writes nothing (not even the bookmark) when the folder stores another epoch.
5. **Untracked folders** report a STATUS observation; the engine compares it with the folder row and
   re-lists a changed folder through the shared listing path (`refreshUntrackedFolder`, the former
   `imapDeltaSync` per-folder logic). `imapDeltaSync` and the engine's IMAPProvider cast are deleted;
   the ADR-IOS-051 count walk goes through `EmailProvider.presentIds(folder:uids:)`.
6. **Recheck.** Every listed folder's re-read list is read (synced or not), answered whatever the
   window, without moving the bookmark or tracking; a UID the FETCH does not return is a removal only
   when `UID SEARCH` on the same selection confirms it gone (its answer is asked about each missing
   UID, never expanded).
7. **Merge.** Answered and forwarded are raised, never lowered; an answered message tagged reply
   becomes none with a queued tag write (ReplyDetect), stamped through `MessageHeader.setActionTag`,
   and skipped while the user's own `.setTag`/`.removeTag` for the message is pending
   (`PendingOperationSnapshot.tag`).
8. **Coverage.** A tracked IMAP folder gets no window listing, no full-sync count walk, no self-heal;
   its catch-up lists only its first listing, a listing in progress, or a lapse since its last
   completed listing. STATUS counts are still read for every folder the full sync discovers (no
   folder loses its counts).
9. **Failure lapse**. A folder whose read keeps failing keeps its bookmark with
   `failingSince` and is refused (`.failingTooLong`, listed again) after
   `changeReadFailureLapseSeconds`. This covers a request on the folder being read that times out or
   loses the connection, whatever the cause (the session is dropped, but that folder is stamped first:
   a server that always closes the connection on one folder's SELECT or FETCH must not leave it
   tracked without a failure time), and a pass whose change session never opens (connect, CAPABILITY,
   ENABLE or the pass-start NOOP failing: every work folder is stamped; a NOOP that always fails had
   wedged the folders without a failure time). A connection the server closes during one folder's
   read fails that folder only: the pass goes on with the folders after it on a new session (at most
   one per folder, bounded by the read budget), so a server that always drops the connection on the
   inbox's read still lets the account's other tracked folders be read in the same pass. A read that
   times out ends the pass instead (2026-11-17): the reader has closed its side, but a server that
   stopped answering counts that session until it notices, and the client has no signal for when it
   does, so a new login could hold two sessions against the account's connection limit. The folders
   not yet read wait for the next pass, which reads them first and the folder that timed out last
   (2026-11-17), so a folder whose read times out on every pass never keeps the account's other
   folders from being read. The inbox keeps first place until its read has timed out on
   `SyncConfig.imapChangeInboxTimeoutsBeforeReadLast` (2) passes in a row, and a successful inbox
   read starts that count again (2026-11-17): one passing timeout never delays new mail behind the
   other folders (with every other folder changed, that delay is about four round trips per folder,
   up to the 20 s read budget), and an inbox that keeps timing out holds the others back for at most
   two passes. These order hints are dropped for folders the account no longer has. A session dropped while its connection still answers (a
   liveness NOOP answered with an error) logs in again only once its LOGOUT has been answered,
   waited for at most `imapEvictionLogoutWaitSeconds`; a LOGOUT that times out, in that wait or in
   the IMAP library's own command timeout, has not ended the session and ends the pass, and is waited
   for only once: the next pass opens a session without waiting for it again; a liveness NOOP that times out reopens the
   session once, before any folder is read. A session that cannot be opened again
   mid-pass, a read that timed out, a dropped one whose LOGOUT does not end in time, or a teardown
   (`markDirty`, `disconnect`) fails the folders not yet read with no failure time. A teardown ends
   the pass wherever it lands, while a session is awaited or opened included: no new session logs in
   for that pass (the pass's generation is checked right before each command that opens the session,
   LOGIN, CAPABILITY and ENABLE, after every wait before it, 2026-11-17), and since it is the app's own act it leaves no failure time even before the pass's
   first session has opened (2026-11-17). The session being opened is open to a teardown from the
   start of its connect until the pass keeps or discards it. Each attempt (the first, and the retry
   after an eviction) turns reconnects off first, then checks the pass's generation and becomes open
   to a teardown in the same actor turn that starts its connect, so a teardown either ends the attempt
   before it connects or finds it open; no connection of a torn-down attempt reaches the server
   (2026-11-17). Known window, accepted: the connect call can still wait for the IMAP library's
   actor after the attempt became open to a teardown, and a higher-priority teardown's close can
   run first; the library's `connect()` re-arms the session and undoes that close, so the socket
   opens and a slow greeting holds it, and the change lane, up to the connect timeout. No LOGIN is
   ever sent (the check before LOGIN ends the attempt). The cause is in the library and is tracked
   by tabmail-ios #952; no workaround here. A teardown closes the session being opened at once, without a LOGOUT, so
   whatever it waits for (connect, LOGIN, the CAPABILITY the IMAP library sends after LOGIN, the
   reader's CAPABILITY or ENABLE) ends with an error, and the server stops counting it right away
   instead of when a held answer comes (2026-11-17). A teardown closes only a session opened for its
   own pass or an older one, never a newer pass's, and the session never reconnects inside a command,
   so nothing it was waiting for logs in again. A pass that gets the change connection only after a
   teardown never uses the session a newer pass kept.
10. **Accepted cost.** A server advertising QRESYNC without CONDSTORE gets no HIGHESTMODSEQ in STATUS,
   so every tracked folder does a QRESYNC SELECT each pass (no fast path). Work, not loss.
11. **Exit rule: a move that leaves a folder's view possibly wrong** (2026-11-15). ADR-IOS-073
   consequence 3 says an atomic move without safe `COPYUID` "can leave an optimistic row unaddressed
   and recoverable by ordinary sync". For a tracked folder ordinary sync is the change reader, which
   never removes or restores such a row (no window listing, count walk or self-heal, item 8). So
   whenever `MessageHeaderRekey.finishMove` retires an IMAP move member without re-keying its row, it
   drops, in the same transaction, the bookmark of every folder whose local view that leaves possibly
   wrong (`SyncEngine.dropChangeBookmark`: the same effect as a refused read, like the over-100 rule;
   the folder is listed again by the full sync, which becomes due, and its tracking restarts with the
   older-mail catch-up armed):
   - no proven destination UID (COPYUID left out, or declined because it is not one-to-one; also a
     move the server refused or whose folder is gone, which retire with no destination): the folder
     the row sits in, and the source folder, which the optimistic move emptied while a refused move
     left the message there. A refused move does not put the row back in the source; the source's
     listing does;
   - the row was moved on before this move retired (a chained move): the folder the row now sits in,
     which holds it under this move's source UID; with no proof, the source as well;
   - a proven destination under a UIDVALIDITY the folder does not share: the folder the row sits in
     (the reader would also refuse that folder; dropped here for uniformity).
   Both routes are covered, the atomic UID MOVE and the owned COPY sequence on servers without MOVE
   (both retire through `finishMove`). A move that retires with no provider result to apply (the
   retry-limit exit, the UIDVALIDITY-changed refusal, the single-message not-found drop, the
   claim-time retire, and the UIDVALIDITY turnover reaction's exit-4 drop) deletes its row through `AccountOperationExecutor.deleteRetiringOperation`,
   which runs `finishMove` with no destination in the same transaction, so the same rule applies;
   which exits exist and when they fire is unchanged. One drop mechanism: a refused read's apply
   calls `dropChangeBookmark` too. A bookmark dropped between a read and its apply is not written
   back (`FolderChanges.readFrom`), and `commitChangeBaseline` tracks a folder with a bookmark of
   its own only while, in the same write, it still stores exactly the bookmark this pass left it
   (`ChangePassOutcome.folderBookmarkLeft`), whatever the read returned (a first read, a "nothing
   changed" read). A retirement whose row is no longer at its key drops the source too. Nothing is deleted and no queued operation is touched:
   removing the placeholder would drop queued user actions that name it, which the never-drop rule
   forbids. The window listing reaches only the newest messages, and the IMAP older-mail catch-up
   only updates or removes rows it holds, so a message such a move left in a folder below the window
   (a move that retired with no effect, its source message older than the window, with backfill
   complete) would stay missing. So a bookmark this rule drops also owes the folder ONE self-heal
   pass before it is tracked again (2026-11-16; *the self-heal pass below is superseded 2026-11-20
   (#1062): the IMAP catch-up's UID listing repairs the folder instead, see the amendment of that date*): `dropChangeBookmark`
   counts one more retirement in `FolderChangeState.selfHealOwed`, whether or not the folder held a
   bookmark (a folder awaiting its first baseline is tracked after its next listing, which does not
   reach below the window either; without a bookmark only the mark is written, no listing is made
   due); the full sync, after its listings and before
   `commitChangeBaseline`, runs the existing self-heal scoped to that one folder
   (`healFoldersAfterAnUnprovenMove` → `selfHealRecentMessages(forceSingleFolder:)`, main's 90-day
   reach, no hourly limit); `commitChangeBaseline` leaves a folder with the mark untracked; the mark
   is cleared only after a COMPLETE pass (`SelfHealFolderOutcome.complete`: no failed check, no
   epoch refusal, no search too large, every UID found missing answered by the FETCH and landed),
   and only while the count is still the one the pass began with (a pass that fails or is short, or
   a retirement added meanwhile, keeps it for the next full sync). A folder whose pass never
   completes stays untracked and listed, as on main. Tests: `IMAPMoveIntoTrackedFolderTests` (the message held once, where the server holds
   it, under its UID, after the normal sync path; `retiredMoveBelowTheWindowIsHealedBeforeTracking`).
Tests: `IMAPChangeReaderTests`, `ChangeApplyIMAPTests`, `IMAPCatchUpTests.planTrackedFolder`,
`IMAPChangeFuzzTests`, `ChangeSeamFenceTests`; red-first mutants recorded in the mutation ledger.
Keywords: QRESYNC, CONDSTORE, ENABLE, VANISHED, HIGHESTMODSEQ, NOMODSEQ, IMAPChangeCursor, change
connection, untracked, addressEpochChanged, arrivals limit, imapDeltaSync deleted, presentIds, UIDPLUS,
COPYUID, exit rule, dropChangeBookmark, move without destination proof, connection budget,
evictChangeConnectionIfIdle, createChangeServer, max_userip_connections, eviction order, heldRangeStart,
olderMailComplete, olderMailCursor, backfillUidCursor, un-deleted, pass-start NOOP, selfHealDue, selfHealOwed, SelfHealFolderOutcome,
healFoldersAfterAnUnprovenMove, evictIdleConnection, IDLE DONE before LOGOUT, #751.

### Amendment 2026-11-18 (#755): one writer of folder counters, and a listing proves its window

**Context.** Folder counters (`totalCount`, `lastKnownUidNext`, `lastKnownHighestModSeq`) had several
writers (folder-list STATUS, the change read's observation, the listing), so a counter could claim a state
no listing had seen, and the ADR-IOS-051 phase 2 could compare the local rows against a count taken at
another moment. A listing whose FETCH came back short still counted as the folder's listing, and the stale
sweep had a lower UID bound only, so a listing could remove a message another listing had stored after
its own SELECT.

**Decision.**
1. **The listing is the only writer of folder counters.** An IMAP folder's count, UIDNEXT and MODSEQ are
   written only from the SELECT of the window listing that saw the rows, carried on the provider-neutral
   listing result (`FetchCoverage.counters`, `ListingCounters`) and written in the listing's own
   transaction (`SyncEngine.writeListingCounters`). `applyFolderList`, `applyFolderUpdates`, the untracked
   refresh and the crawl write no counters. The UIDVALIDITY bootstrap (ADR-IOS-061) is unchanged.
   Resets (Settings resets, the startup migration, the UIDVALIDITY reaction) clear counters only through
   the same owner (`SyncEngine.invalidateListingCounters`). **By construction:** the database record
   encoding (`Folder.encode(to: inout PersistenceContainer)`) leaves the three counters
   (`Folder.listingCounterColumns`) out of the record's persistence container, while `Codable` stays whole
   (a JSON round trip keeps every field), so a
   whole-record `insert`/`update`/`save` cannot write them (an insert takes the table defaults); only the
   writer's column-scoped UPDATE does. Seeds (demo, screenshot, preview, test fixtures) write counts
   through the same writer. Fence: `FolderRoleTests.wholeRecordSaveNeverWritesTheListingCounters`.
2. **The listing's MODSEQ.** The listing's connection decides CONDSTORE once per session
   (`IMAPProvider.negotiateListingCondStore`): with ENABLE, only an acknowledged `ENABLE CONDSTORE`; without
   ENABLE, CONDSTORE if advertised. The decision belongs to the pooled connection and goes with it. With
   CONDSTORE on, the listing's SELECT carries `(CONDSTORE)` (through `IMAPChangeCommands`). With it off, or
   on a NOMODSEQ folder, the listing clears the stored MODSEQ and never fails for it. The decision is keyed
   by the connection's identity, never the folder path, and set only while that connection is a live pool
   entry: a renegotiation that resumes after its connection left the pool cannot overwrite the decision of
   the connection that replaced it. A `(CONDSTORE)` SELECT refused by the server, or by the client because a
   reopened session no longer advertises CONDSTORE (`IMAPProvider.isCondStoreSelectRefusal`), is selected
   again plainly and that connection lists without CONDSTORE from then on: no ENABLE after a session has
   selected (RFC 5161 §3.1); ENABLE is sent only when a connection opens, before its first SELECT. The
   pool's own open-the-folder SELECT is always plain: a server that refuses the `(CONDSTORE)` parameter
   still opens the folder, and only the listing's own SELECT (with its plain fallback) carries it. The cost
   of a server that misbehaves here is only an extra listing without MODSEQ; it is RFC 5161 compliant. A HIGHESTMODSEQ of 0 (NOMODSEQ) is no value (`SyncEngine.knownModSeq`): it never
   triggers a listing and never proves a folder unchanged.
3. **Each folder's listing this pass is one of three, by the server's answer** (`SyncEngine.listingProvedItsWindow`):
   - **Proven:** EXISTS in range, a header record back for every message the window holds, and (on EXISTS
     0) a confirming SEARCH. It writes the counters, may sweep, counts toward the full-sync stamp.
   - **Not listable:** the server refused the SELECT (`ProviderFolderNotListable`, mapped from the IMAP
     SELECT refusal at the provider boundary) or the SELECT sent no usable EXISTS
     (`FetchCoverage.notListable`). Nothing is written or swept; the folder does not withhold the stamp, so
     a folder the server always refuses does not keep the full sync due on every pass.
   - **Unproven:** a short or empty FETCH against a positive EXISTS (an expunge between SELECT and FETCH
     included), a contradicted EXISTS 0, or any other failure after the listing started. It writes no
     counters, runs no stale sweep, certifies no change baseline and drives no phase 2, and it withholds
     the stamp of the pass that ran it (`FullSyncListing.droppedFolder`; the untracked route's listings
     record in `SyncEngine.unprovenListingPasses` under the foreground pass's own id, which only grows
     during that pass, so an error in a later folder never loses an earlier folder's). An on-demand listing
     belongs to no pass and never withholds a scheduled pass's stamp. Every unproven listing (on-demand or
     untracked) makes its folder due (`FolderChangeState.listingDue`) and owes it a deep pass, so the next
     pass lists it whatever STATUS or its counters say. Invariant: `lastFullSyncAt` is never stamped after a pass in which a
     started listing failed to prove its window.
   The records an unproven listing did return are still merged as positive records (inserts and flag
   updates of messages the server showed); only absence is never inferred from it. A connection lost
   mid-listing is retried once; the retry's own answer classifies the folder, and the failed attempt wrote
   nothing (`runSyncMessages` writes in one transaction after its server reads). The background passes show
   no error for it; pull-to-refresh keeps the errors it showed before (a lost connection ends the refresh
   with that error; a refused or server-gone folder and an unconfirmed count are skipped silently), mapped
   by its caller from the outcome, whose `.unproven` carries the listing's own error. The folder is listed
   again next pass. **The proof is bound to its session:** after the listing's SELECT its connection never
   reconnects inside a command (`setReconnectsInsideCommands(false)` for the FETCH or SEARCH that confirms
   it), so a session lost between the SELECT and its proof makes the listing unproven (a lost connection,
   retried whole on a fresh SELECT) instead of proving a new session's selection against this one's count,
   epoch and UIDNEXT. A refused SELECT is typed (`ProviderFolderNotListable`) at the listing's own SELECT.
4. **An EXISTS 0** empties a folder only when a `UID SEARCH ALL` on the same selection reads as empty;
   otherwise that folder's listing fails (`ProviderListingUnconfirmed`, content-free description) and is
   retried; the other folders proceed. A SEARCH that the library reports as an empty result without an
   untagged answer is treated as unproven once the library preserves that distinction (tracked separately);
   Tests pin it.
   **One classifier.** Every route (full sync, untracked refresh, and every on-demand listing: folder
   open, after a send, after a move, epoch-rebuild step 6, all through `syncFolderMessages` → `listFolder`)
   lists through `SyncEngine.runListing`, which never throws and returns `ListingOutcome` (`.proven`,
   `.notListable`, `.unproven`); any failure after the SELECT is `.unproven` there, so no caller can rethrow
   a listing error past it. The merge (`runSyncMessages`) is private to it; there is no other door
   (fence: `ListingRouteFenceTests`). An on-demand listing that proves nothing is not an error shown to
   the user; the folder is listed again next pass. The full sync records it with `SyncEngine.record`; the untracked route consumes it via
   `listFolder`. An unproven listing (the deep pass's included) owes the folder a deep pass
   (`oweDeepListing`), so the next full sync never MODSEQ-skips it. The proof, the rows and the sweep
   bounds read one record set: the requested window's records with a UID, one per UID
   (`IMAPProvider.inWindow`); an unsolicited FETCH outside the window is no part of the listing. A record
   set that names one sequence number twice or whose UIDs do not rise with the sequence number
   (`IMAPProvider.windowRecordsAreConsistent`) proves nothing and lists nothing.
5. **SEARCH answers (RFC 4731) have one reader,** `ExtendedSearchResult.listed(within:)`; the unbounded
   `listed()` is private to it, so every caller must name its request's scope and the compiler finds a new
   one. An answer that does not list its UIDs fails the request, never reads as empty; one naming any UID
   outside the scope is refused, so a set cannot be trimmed into absence. A search over the whole selected
   mailbox uses `MessageIdentifierSet.anyUID`: a UID at or above the SELECT's UIDNEXT there is new mail
   delivered since, kept for app search and the NSE lookup; removal evidence is bounded separately by the
   listing's own SELECT (item 6). Census: the EXISTS 0 confirmation, `searchOnConnection`, `searchDateRange`,
   `searchBeforeOnly`, `searchByMessageId`, `currentUIDs`, `appendToSentFolder`, the arrivals range,
   the QRESYNC `rereadIds` re-read, `searchExistingUIDs`, `readChangeFolder` and the NSE's `searchMessageId`.
6. **The stale sweep stays inside the listing's own window (#997).** On IMAP it judges only UIDs from the
   lowest to the highest UID the listing fetched; a whole-folder listing judges only UIDs below its own
   UIDNEXT (or, with none reported, at most the highest UID it saw; with neither it removes nothing). A
   windowed listing's ceiling is also below its own SELECT's UIDNEXT: a UID allocated after that SELECT
   that its FETCH still returned is never evidence for removal. Both sweep branches (small whole-folder and
   windowed) take the coverage they judge with from one builder (`SyncEngine.sweepCoverage`), which keeps
   the listing's own SELECT evidence, and the windowed candidate load and the removal decision take their
   UID window from one helper (`SyncEngine.windowedSweepUIDBounds`); fence:
   `ListingRouteFenceTests.sweepCoverageHasOneBuilder`. A
   message another listing stored after this listing's SELECT is never removed by it. Removals come only
   from this sweep and from the change reader's removal core; phase 2 removes only after its own walk.
   *Amended 2026-11-22 (#1184): a windowed listing's ceiling is its UIDNEXT - 1 alone, not the highest
   UID it fetched; see the amendment of that date below. The text above is kept as written.*
7. **Observations are triggers only.** STATUS and the change read's observation decide whether a folder is
   listed. The full sync's MODSEQ skip (`shouldSkipFolderFetch`) needs MODSEQ, MESSAGES and UIDNEXT all equal
   to the stored listing counters and no due listing.
8. **Phase 2 runs only on the count of a listing in the same pass** (`FullSyncListing.listedCounts`; the
   untracked refresh uses its own listing's result). A phase 2 that does not finish sets
   `FolderChangeState.listingDue`, as does a listing whose server count is below the rows held (armed in the
   listing's transaction, `armListingDueIfHeldExceeds`); a due folder is listed and walked again and is left
   out of the change baseline; only a finished walk whose counts agree clears it. Phase 2 honours the
   pass's deadline (`FullSyncPlan.deadline`, the foreground pass's own). The due bit carries a token per
   mark (`FolderChangeState.markListingDue` / `clearListingDue(ifMarkedBy:)`): a phase 2 clears only its own
   mark, so an older check that finishes after a newer listing marked the folder never clears that mark.
   A walk's deletion re-checks, inside the deleting transaction, that the folder's stored UIDVALIDITY is
   still the one the answer was read under and no turnover is armed
   (`deleteServerConfirmedDeletions(answerEpoch:)`); an answer about the old mailbox deletes nothing. The
   always-on deletion log names the folder's role, never its name. The count checks compare the server's
   count with the rows the server can list (`SyncEngine.heldServerRowCount`): a never-uploaded draft's
   placeholder is not one, so it never keeps a healthy folder due.
9. **Backfill progress has its own source,** `EmailProvider.progressTotal(crawling:)`, needed because the
   STATUS writers that fed it are gone: Gmail its profile total, Exchange the sum of `totalItemCount` over its
   last complete folder list, set only when the scheduled full sync adopts one
   (`EmailProvider.adoptFullSyncFolderList`; a change read's folder discovery never sets it), IMAP each folder's UIDNEXT from its last folder
   list (`SyncEngine.uidWalkProgress`). Before the first folder list nothing is published. The wake lock
   reads the folders' walk state and fails closed: an account not polled, or with no folder rows, is not
   done.
   *Superseded (2026-11-22, #1273):* "Before the first folder list nothing is published." See the amendment
   of that date below: until the provider's total is known, progress is the database's own.

**Consequences.** A folder whose listing proves nothing keeps its earlier counters and rows and is listed
again next pass. The engine stays provider-blind. No column, no migration (`listingDue` lives in
`changeState`).

Keywords: ListingCounters, writeListingCounters, listedCounts, listingProvedItsWindow, short FETCH,
unproven listing, stale sweep window, upper bound, negotiateListingCondStore, ProviderListingUnconfirmed,
ExtendedSearchResult.listed, listed(within:), ProviderFolderNotListable, notListable, UntrackedRefresh,
invalidateListingCounters, ListingOutcome, runListing, listingCounterColumns,
inWindow, anyUID, unprovenListingAccounts, unprovenListingPasses, sweepCoverage, windowedSweepUIDBounds,
windowRecordsAreConsistent, heldServerRowCount, adoptFullSyncFolderList, setReconnectsInsideCommands, ListingRouteFenceTests, syncFolderMessages, knownModSeq, NOMODSEQ, listingDueToken, oweDeepListing, answerEpoch, isCondStoreSelectRefusal, answeredInWindow, armListingDueIfHeldExceeds, folderWalkDone, listingDue, progressTotal, ProgressTotal, uidWalkProgress, folder counters one
writer, #755, #985, #990, #997.

### Amendment 2026-11-22 (#1184): the windowed sweep's ceiling is the listing's UIDNEXT - 1

**Context.** The #755 amendment (item 6) bounded a windowed IMAP sweep above by the lower of the highest
UID the listing fetched and its own UIDNEXT - 1. The highest fetched UID is below a message that was the
folder's newest and was then deleted on the server, so that message was never judged: in an IMAP folder
over `syncMessageLimit` (or the held-row cap) that is not tracked by QRESYNC, a message deleted on another
client stayed on the device until newer mail arrived or the catch-up's daily check removed it.

**Decision.** `SyncEngine.windowedSweepUIDBounds` judges from the lowest UID the listing fetched to the
listing's own UIDNEXT - 1 when the listing reports a UIDNEXT, and to the highest UID it fetched only when it
reports none; with no usable fetched UID it removes nothing, as before. The whole-folder branch already used UIDNEXT - 1 alone; both
branches now bound by the listing's own SELECT the same way.

**Why the #755 protection holds.** That bound protects a message another listing stored after this
listing's SELECT. Every such message has a UID at or above this SELECT's UIDNEXT (RFC 3501 §2.3.1.1 and
§6.3.1: UIDs are assigned in ascending order and UIDNEXT is the next one to be assigned), so UIDNEXT - 1
alone keeps it out of the window. A UID between the highest fetched and UIDNEXT - 1 was assigned before the
SELECT and is not in the listing's window, which reaches the folder's newest message; a proven listing
returned every record that window holds, so such a UID is a message the server no longer holds. A record
the client could not parse stays present (`unmaterialisedIds`).

**The load stays bounded.** After another client deletes thousands of a folder's newest messages, the
window up to UIDNEXT - 1 can hold that many rows. The windowed slice therefore loads at most
`SyncConfig.staleDetectionMaxFullScan` rows, newest UID first (numerically), the same bound the
whole-folder branch has; the rows past it stay (fail closed). The next listing judges those that are still
inside its own window, which reaches from its lowest fetched UID up, so a clipped row stays in reach until
`syncMessageLimit` newer messages have arrived on the server above it. A clipped row that a later window's
floor has passed is a row below the window (IOS-IMAP-008): the ADR-IOS-051 count walk removes it when the
device holds more rows than the server, and the whole-folder branch once the device holds at most the bound.
Reaching that case takes more than `staleDetectionMaxFullScan` deletions in the folder's newest messages and
`syncMessageLimit` arrivals before the next listing. On a partly mirrored folder the count walk does not fire,
so such a row can stay, as any row below the window can (IOS-IMAP-008), until the catch-up's UID check finds
it gone where that check runs, or the folder becomes small enough for the whole-folder branch; a row still
flagged `\Deleted` (one the clipped listing saw) is first left until it is expunged. Ordering the slice upwards
instead would keep the window's own rows first but leave the folder's newest deleted messages, the ones the
user sees at the top of the list, for later listings; the newest-first order is kept on purpose.

**Accepted residual.** The window reaches the folder's newest message because the listing FETCHes the
highest sequence numbers its SELECT's EXISTS counted, and sequence numbers ascend with UIDs. A server whose
EXISTS undercounted the mailbox while reporting a correct UIDNEXT would have its uncounted newest messages
removed from the device; a later listing with a correct EXISTS fetches them again. No server is known to
answer this way, and nothing on the server is touched.

**The widened band is judged as the window always was.** The rows between the highest fetched UID and
UIDNEXT - 1 go through the same `selectStaleHeaders`, RFC remap and stale protections as every other row of
the window; this amendment adds no new rule for them. Two consequences are the window's own, unchanged:
- A stale row whose RFC Message-ID matches an incoming record the device does not hold is rekeyed onto it
  (Memory 023) before `staleFiltered` applies the pending and recent protections, as inside the old window.
  The codebase treats one RFC Message-ID as one message's content (the two-layer keying; full-text search is
  keyed by it), so the rekeyed row carries the same message; its flags and labels follow the server on the
  next merge. An optimistically moved row (IOS-MOVE-002) is protected from deletion by its pending move,
  and its move drains by its source address either way.
- A row is judged by the listing's epoch, not its own (IOS-EPOCH-002): a nil row epoch, or a SELECT without
  UIDVALIDITY (a server declaring no UID support, RFC 3501 §2.3.1.1), is treated inside the band as inside
  the old window. Narrowing either for the band alone would make one window follow two rules.

Tests: `ListingCountersTests.provenWindowHoldsExactlyTheServersMessagesUpToUidNext` (red with the old
ceiling: the newest message, deleted after a proven listing, survived the next full sync);
`StaleDetectionWindowTests.uidWindowStillDeletesGenuinelyStale` (the harness now carries the listing's
UIDNEXT); `ListingCountersTests.overlappingWindowedListingKeepsAnArrivalAboveItsWindow` and
`SyncEngineRunSyncTests.rowAboveOwnUidNextSurvivesBothSweepBranches` keep pinning the #755 protection;
`ListingCountersTests.massDeletionSweepIsBoundedAndConverges` (each windowed listing judges exactly the
newest `staleDetectionMaxFullScan` rows of its window by numeric UID; the next windowed listing, after an
arrival, continues where it stopped; rows below the window kept; convergence once the device holds at most
the bound); `ListingCountersTests.noUidNextBoundsTheWindowedSweep` (with
no UIDNEXT a windowed listing stops at the highest UID it fetched).

Keywords: windowedSweepUIDBounds, stale sweep ceiling, UIDNEXT - 1, highest fetched UID, deleted newest
message, windowed listing, staleDetectionMaxFullScan, mass deletion, clipped rows, newest first, RFC remap,
row epoch, EXISTS undercount, #1184, #755, #997.

### Amendment 2026-11-20 (#1062): the owed check is the catch-up's UID listing

The self-heal pass an unproven move owes a folder (`healFoldersAfterAnUnprovenMove`,
`selfHealRecentMessages(forceSingleFolder:)`, the 90-day date reach) is deleted. The mark
(`FolderChangeState.selfHealOwed`, `selfHealLapse`) is now settled by the IMAP catch-up (ADR-IOS-107,
amendment 2026-11-20): a CLEAN completed listing that started after the mark loads every missing UID
at or above its load floor by UID (the held range's start; under a storage limit, above the prune
cutoff of the folder's epoch, ADR-IOS-006 floor rule; *superseded 2026-11-21:* "in the held range")
and calls `markListingDue`, so the next scheduled full sync lists the folder
and `commitChangeBaseline` tracks it again. An unclean completion (a UID passed over at the hold
bound, a listing whose first UIDNEXT read reported none (`topUnknown`, 2026-11-20), loads skipped as an over-age read in any slice of the listing, or nothing to check: no load floor of
the folder's epoch and no local row, so the listing read nothing from the server, 2026-11-21) keeps the folder owed and
re-marks nothing: an owed folder counts as untracked in the catch-up plan even with a bookmark, so it
is relisted at least daily, plus when its change counter (HIGHESTMODSEQ) moves past the stamp the
unclean listing still records. A clean completion that started before the mark re-marks the lapse once
(amended 2026-11-20). *Superseded (2026-11-20):* "An unclean completion (a UID passed over at the hold
bound) or one that started before the mark re-marks the catch-up lapse, so a folder holding a new
bookmark is still listed again until the mark settles." (selfHealDue, owed check, unproven move,
catch-up, re-arm, #1062)

### Amendment 2026-11-19 (#755): CONDSTORE without QRESYNC

**Context.** A server with CONDSTORE and UIDPLUS but no QRESYNC was read as untracked: its folders were listed
from STATUS, so a flag change below the listing window and an expunge of an older message stayed unseen
until the catch-up or a count walk. Without QRESYNC an expunge is not reported and may leave HIGHESTMODSEQ
unchanged (RFC 7162).

**Decision.**
1. **Mode, once per change session** (`IMAPChangeMode.plan`): QRESYNC + ENABLE + UIDPLUS asks `ENABLE QRESYNC`
   (`.qresync` only when acknowledged); else CONDSTORE + UIDPLUS asks `ENABLE CONDSTORE` (only an acknowledged
   one gives `.condstore(selectParameter: false)`), or, without ENABLE, `.condstore(selectParameter: true)` and
   every SELECT on the change session carries `(CONDSTORE)`; else untracked. ENABLE only after the pass's
   generation check. No retry across modes. The engine never sees the mode.
2. **The bookmark carries MESSAGES** (`IMAPChangeCursor.messageCount`, the SELECT's EXISTS, both modes; a count
   outside 0...UInt32.max does not decode). A CONDSTORE read of a bookmark without it starts a baseline. A
   tracked read also wrote `provenFrom` (removed 2026-11-19, see clause 6). A bookmark stores EXISTS 0 only after
   `UID SEARCH ALL` on the same selection reads empty (`searchReadsEmpty`, `listed(within:)`): on a first
   baseline, and (amended 2026-11-19, review) on a tracked CONDSTORE read too, where a SELECT saying EXISTS 0
   while SEARCH still finds UIDs leaves the folder untracked that pass with its prior bookmark kept. Committing
   that count would make every later read's owed count negative and fail until the failure lapse.
3. **The read** (`IMAPProviderChangesCondstore.swift`): STATUS fast path only when MESSAGES, UIDNEXT, HIGHESTMODSEQ
   and UIDVALIDITY all equal the bookmark's, no re-read list and no pending check. Otherwise SELECT (epoch
   refusal; NOMODSEQ or no EXISTS untracked; no UIDVALIDITY/UIDNEXT fails), `UID FETCH lo:N1-1 (UID FLAGS)
   (CHANGEDSINCE m)` through `IMAPChangeCommands.flagsChangedSince`, then the shared classifier and arrivals
   SEARCH (`readChangedAndArrivals`; a CHANGEDSINCE UID in [N0, N1) is an arrival). owed = M0 + |A| - M1; below
   0 fails the folder (`IMAPChangeCountMismatch`).
4. **The removal check.** With owed > 0 (or a held moved-in row in [N0, N1) missing from A) the newest held UIDs
   below N0, up to `SyncConfig.imapChangeRemovalCheckWindow`, are searched by chunk from
   `CatchUpLocalRowReader.rows(folderId:numericIdsBelow:limit:)` (UID order, never date). A candidate is removed
   only when the FETCH and a confirming SEARCH both leave it out (`rereadIds`). Held rows left below the window
   arm the catch-up with the new bookmark (`armCatchUpWithBookmark`). The read reports
   `FolderChanges.heldRowsProof {lowerId, upperId, checkedIds}`; before any removal the apply re-reads the rows it
   holds in that range and, when one is not among `checkedIds`, keeps the stored bookmark.
5. **The cut.** The check is priced from its exact request count before the arrivals' FETCH. When it does not
   fit (or the budget runs out mid-check) the folder is reported `.untracked` with
   `UntrackedObservation.mustList` (listed the same pass), the bookmark keeps its reading position and carries
   the check's progress (`pendingCheck {pending, nextBelow, remaining, unproven}`). The pass that creates the
   check arms the catch-up (its bytes change, so the arm lands); later passes write progress only and never
   arm again: one lapse per check. A finished check commits the pending bookmark of the pass that started it.
   *Amended 2026-11-19 (review):* the up-front price is removed. It counted the ORIGINAL owed removals on
   every pass, so after a bulk expunge (owed above about 1000) a check that had finished never "fit" the
   20 s budget and was cut on every pass, dropping the folder's flag changes for good. The check is
   budgeted step by step (`runRemovalCheck` stops before a step the budget cannot pay), so only an
   unfinished check cuts; the arrivals' FETCH keeps its own budget gate.
6. **The from-server insert guard** (`SyncEngine.fromServerInsertAllowed`): the crawl (per range) and load older
   (per folder) snapshot the folder's `changeCursor` and `changeState` before their server read and insert
   only while both are byte-equal in their write transaction; a refused crawl range fails (nothing advances),
   a refused load-older page reports more to load. The notification merge refuses a staged UID the folder does
   not hold below the UIDNEXT of a `provenFrom` bookmark (`NSEDataBridge.stagedRowProvenGone`, skip-and-delete).
   **Amended 2026-11-19 (review): that merge refusal is removed, with `provenFrom` and
   `IMAPChangeCursor.provesGone`.** UIDNEXT is not per-UID evidence: a live older UID the window never loaded,
   or a header the prune removed, also sits below it unheld, and its staged notification payload was deleted.
   Unproven staging stays for merge or retry; a staged copy of a message a read proved gone can therefore be
   merged back as a header, which a later listing or removal check removes again. It also kept an IMAP
   bookmark reading out of the notification merge, above the provider boundary. Any replacement needs
   positive per-UID evidence.
   **Amended again 2026-11-19 (review): the merge-back is settled by ending tracking.** A tracked folder is
   never listed, healed or count-checked, so the merged-back header above could stay for good. Now, when the
   notification merge inserts a header under an id the folder's change bookmark claims it already held
   (`EmailProvider.changeBookmark(_:claimsHeld:)`, read by account type beside the protocol; IMAP: a UID below
   the bookmark's UIDNEXT, either mode), the same transaction drops the bookmark as a refused read does
   (`SyncEngine.endTrackingIfBookmarkClaimsHeld` -> `dropChangeBookmark`). The staged row is kept. The next full
   sync lists the folder and removes a gone message; a live one stays and the folder is tracked again after
   its next baseline. The cost is one listing per such merge; tabmail-ios#1089 (P4) tracks the per-UID
   record of proven removals that would avoid it. No new persisted state.
   **Amended 2026-11-20 (review): the newly covered arrival range is proven too.** A staged UID equal to the
   stored UIDNEXT is not claimed by the stored bookmark, so a merge between the read's lookup and its apply
   kept tracking, and the new bookmark then covered a row nothing checked (a permanent ghost when the server
   had expunged it). The CONDSTORE read now also reports `FolderChanges.arrivalRowsProof` for [N0, N1 of the
   bookmark it writes): the arrivals the server listed plus the moved-in rows its own lookup found. The apply
   checks it as it checks `heldRowsProof`; any other held row there keeps the stored bookmark, so the next
   read finds the row moved-in and checks it. The staged row is kept; no new persisted state.
   A UID admitted to that proof must have an applicable result. A listed arrival the read sees flagged
   `\Deleted` (not expunged) is therefore emitted as a removal whether or not the folder held it at the
   lookup (IOS-IMAP-001 D3: a `\Deleted` message is not present for display); the shared changed-flags
   classifier (`readChangedAndArrivals`) no longer restricts that removal to held rows, for QRESYNC too, and
   the apply's shields (pending operations, recent/outbox protections) decide as for every removal. A row
   the merge inserts before the apply is removed by it; one it inserts after the apply contradicts the new
   bookmark and ends tracking (`endTrackingIfBookmarkClaimsHeld`), so the next listing settles it. The
   proof was not narrowed to omit such UIDs: one rule, no second path.
7. **The turn.** A standalone `syncFolderMessages` lists inside `oneSyncAtATime`, which is re-entrant for the
   task holding it (`@TaskLocal heldSyncTurn`).
8. The catch-up's MODSEQ freshness for a TRACKED folder with a same-epoch bookmark (one not owed a check) is
   the bookmark's MODSEQ alone: its plan compares nothing (a tracked folder gets no MODSEQ check), and a new
   listing stamps that MODSEQ. A folder owed a check is untracked in the plan even with a bookmark (amendment
   2026-11-20 (#1062) above): its freshness stays its stored HIGHESTMODSEQ (`lastKnownHighestModSeq`), so a
   moved listing counter relists it whatever its bookmark says. A bookmark of another epoch never supplies it.
   *Superseded in place (2026-11-21):* "for a folder with a same-epoch bookmark", which also took the
   bookmark's MODSEQ for an owed folder, so its relisting waited for a change read to move the bookmark.
   This amendment changes nothing about network conditions for scans (handled separately).

**Consequences.** CONDSTORE servers get the change reader; the only new provider-neutral seam fields are
`mustList` and `heldRowsProof`. No column, no migration. Limits: a cut pass lists the folder (no later than
before); a progress-only bookmark write fails a concurrent crawl range or load-older page once (retried).

Keywords: IMAPChangeMode, CHANGEDSINCE, flagsChangedSince, messageCount, provenFrom, pendingCheck,
IMAPRemovalCheckProgress, imapChangeRemovalCheckWindow, numericIdsBelow, IMAPChangeCountMismatch, mustList,
heldRowsProof, arrivalRowsProof, fromServerInsertAllowed, ChangeInsertPremise, stagedRowProvenGone, heldSyncTurn, #755.

### Amendment 2026-11-22 (#1273): backfill progress before the provider's total is known

**Context.** Item 9 of the #755 amendment published no backfill progress while `progressTotal` answered
`.notKnownYet`. IMAP knows its total only after `fetchFolders` ran in this process, Outlook only after a full
sync's `fetchFullSyncFolders`; the routine passes are change reads, which never adopt a folder-list total. So after a launch
an IMAP (iCloud included) or Outlook account's Fast Sync card read "Waiting..." for a long time, also when its
walk was complete. 1.11.4 always published progress from the database.

**Decision.** `SyncEngine.updateBackfillProgressForAccount` publishes while the total is not known yet. A
`.notKnownYet` answer adds no UID scope (`uidTotal` 0) and no server total, so the published progress is the
database's own: messages stored (`totalEmails`), settled (`ftsIndexed`), still owed a body
(`pendingBodyCount`) and the walk's state (`headersDone`), hence the completed state ("N messages indexed")
once every folder's walk is done and no body is owed. Once the provider's total is known it sharpens the
denominator exactly as before (IMAP's UID scope from the folder list, Outlook's folder-list sum while
crawling). A provider not registered yet still publishes nothing.

**What stays.** Progress never reads the stored folder counters (`totalCount`, `lastKnownUidNext`), which
only a proven listing writes; an unproven count is never shown as a denominator. Completion still gates on
`pendingBodyCount` (PROJECT_MEMORY "Backfill / Fast Sync Completion").

**Consequences.** Before a folder list the card's bar is "settled of stored", which can read near 100% while
the walk still runs; it shows no check mark until the walk is done. For an account still crawling, the bar
can drop once the provider's total arrives (IMAP switches to UIDs walked; Outlook's denominator becomes the
folder-list sum). No column, no migration.

Keywords: progressTotal, notKnownYet, updateBackfillProgressForAccount, Fast Sync Waiting, FastSyncAccountCard,
BackfillProgress, #1273.

### Amendment 2026-11-22 (#1287): the turnover re-drive runs after the read, inside the read's budget

**Context.** Since #974 every change pass re-drove every armed folder of the account
(`uidValidityResetPendingAt` set) before it read, one reaction after another, inside the account's sync turn and
with no time limit of its own. A reaction is not short: the write barrier, the purges, a disconnect, a fresh
login for the epoch observation, and the folder's resync listing (step 6, re-entrant in the same turn). When a
reaction could not finish (its barrier gave up while an action drain ran, or the caller's timeout cancelled it),
its flag stayed set and the next pass paid the same cost again. Until every armed folder's reaction completed,
the account's change reads either timed out (10 s per-account pass, 60 s foreground pass) or started with no
budget left and read nothing. On a 1.11.5 test build, an IMAP account read changes in 3 of 16 per-account passes
for the first five minutes after the update (folders armed long before, #1277) and in 30 of 31 after the last
re-drive. Gmail and Outlook accounts were unaffected.

**Decision.** `SyncEngine.performChangePass` builds its request first (`makeChangeRequest`, the snapshot taken
at the start of the turn). The request samples the end of the pass's read budget once, after its folder snapshot
and before the first request (`changeReadEnd(turnStart:callerDeadline:)` on `changeReadClock`, in the request's
`ChangeContext`). The pass reads and applies with that request (`readAndApplyChanges(account:provider:request:
deadline:pass:)`), then calls `redriveArmedTurnovers(accountId:until:)` with the same end. The end belongs to
the attempt: a pass that retries its read after a connection error (the foreground and per-account passes) builds
a new request for the retry, and its first attempt, which threw, re-drove nothing. The end is a start
cutoff: a reaction starts only before it; the armed folders not reached stay armed for a later pass. A pass that
throws before the re-drive skips it: a failed request snapshot, a cancelled pass, a database failure, or a read in
which every folder the pass read failed (the apply then throws; the IMAP reader itself records a lost or refused
connection per folder and does not throw). A reaction already running at the end runs on until it completes or
its pass is cancelled by the caller's timeout. A reaction that stops before it stamps the new epoch (step 5)
leaves the flag set, and a later re-drive retries it (unchanged). One that stops after the stamp, during its resync
listing (step 6), leaves the folder unarmed under its new epoch with its old rows purged (and none of the new ones
yet, unless the listing committed some before it stopped); a later listing fills it
(the change pass's listing of an untracked folder it reads and finds changed, the full sync for a syncable folder,
opening the folder, or the catch-up crawl, since the purge reset `backfillComplete`). A pass cancelled before the
end may still start the next folder's reaction; that reaction's first database read fails (a cancelled task's
read throws), so it starts no purge. The full sync's re-drive (after its listing) and the apply's reaction for a
folder its own read found renumbered are unchanged. The second runs inside the read: after the apply's folder
transactions and before the untracked folders' listings, so in a pass that also has a changed untracked folder
that listing waits for the reaction, as before. A folder that reaction left armed is retried by the same pass's
re-drive while the budget lasts.

**Why this placement and not a reaction outside the turn.** The apply already tolerates a reaction running
outside the turn (its in-transaction armed check and binding epoch check), and the trigger handler spawns one
that way. But every reaction disconnects the provider's sessions (step 5's connection hygiene), and a re-drive
running beside the change read would cut that read's session once per armed folder. Inside the turn, after the
read, a re-drive never cuts a change read of its own account. This covers the re-drive's own loop. A re-check that
a reaction spawns when it ends (`releaseUidValidityReaction`) and the trigger handler's reaction run in tasks of
their own: they can do their work before the listing beside a change read, as before, and their listing waits for
the turn. A pass waiting for the turn behind a re-drive waits
for the rest of the holder's turn: its read budget, the one reaction running at the budget's end, and whatever
the holder does after its change pass (a foreground pass's full sync and catch-up start). That reaction is
bounded by its caller's timeout (10 s per-account pass, 60 s foreground pass) and then by how long its cancelled
work takes to unwind; a caller that sets no timeout does not bound it. The waiting pass follows a pass that has
just read the account's changes. Whether a signal that arrives during the holder's turn is read when the turn
frees is #1289's (a waiting pass's deadline, and a follow-up pass), not this amendment's.

**Liveness (count the predicates, Memory 114).** An armed folder is re-driven by: this re-drive (every armed folder
of the account, of any role, with a path, on every pass that reaches it, inbox-only passes included, while the
budget lasts); the full sync after its listing (armed folders of the primary or secondary roles or favourites,
with a path, excluding `skippablePaths` and the folders the pass tracks); the apply's reaction (a folder the pass's
own read found renumbered); `syncFolderMessages` for the folder it is asked to list (opening any folder); and the
trigger handler (a folder a read or listing finds renumbered). None is unconditional. Before this amendment the
re-drive also ran on passes whose read then threw or used its whole budget. A folder now waits through such
passes, and a later armed folder also waits while an earlier one's reaction uses the rest of each pass's budget.
A custom folder that is not a favourite, which no scheduled listing selects, then waits until the user opens it,
the on-demand path such folders always had. Accepted: the read comes first.

**Consequences.** A pass's change read is never delayed by its own re-drive; a pass waiting for the turn can be,
by the one reaction running at the holder's budget end (above). Re-driving N armed folders spreads over as many
passes as their reactions need; each completed reaction is permanent. The turnover's new numbering is listed after
the read instead of before it, so its arrivals show one step later in the same pass when that listing completes.
No new setting, column or migration; nothing is added before the change read (the armed-folder query that ran
before it now runs after it).

Keywords: redriveArmedTurnovers, changeReadEnd, runUidValidityResetReaction, uidValidityResetPendingAt, write
barrier exhausted, turnover re-drive, change read starved, #1287, #974, #1277.

### Amendment 2026-11-22 (#1109): a folder a user action lands in is followed

**Context.** The syncable set (`SyncEngine.isSyncable`: main roles and favourites) decided which folders
get the full sync's listing, the change read (`ChangeFolder.isSynced`), the catch-up and the UIDVALIDITY
re-drive. Every other folder was listed only when opened, and only its newest messages (the window
listing). A delete, move, or read or flag change made elsewhere below those, or a message the device
never loaded, then stayed wrong for good in a folder the user works in but never starred: an IMAP
custom folder, an Outlook folder that is not a favourite. Memory 114 records the same predicate's effect
on the re-drive.

**Decision.**
1. **The mark.** `Folder.isFollowed` (`v112_addFolderIsFollowed`, `BOOLEAN NOT NULL DEFAULT 0`, no index).
   A followed folder is in the syncable set (`SyncEngine.isSyncable(_:)`), ordered after the secondary
   roles (`syncableFoldersInOrder`: Inbox, favourites, secondary roles, followed folders). It therefore
   gets everything a favourite gets, with no new provider code: the full sync's listing, the change read,
   the catch-up run (`syncableFolderIds`), the UIDVALIDITY re-drive (the same loop) and the re-read
   list's overflow cut (rule 3 of the #876 amendment). This amends decision 1 of the 2026-11-12 Outlook
   amendment (`ChangeFolder.isSynced`) and ADR-IOS-107 decision 1 (the catch-up's folders).
   - One writer, `SyncEngine.markFollowed(folderIds:db:)`: a column-scoped UPDATE of the named folders not
     followed yet. It only sets the mark; nothing clears it (no expiry). The column is left out of
     `Folder.encode(to:)` (`Folder.followedColumn`), as the listing counters are, so a whole-record write
     from an older read never clears it. Fences: `ListingRouteFenceTests.followMarkHasOneWriter`, the
     `FolderRoleTests` encode fence.
   - It is the user's choice, not sync state: both Settings resets keep it, as they keep `isFavorite`
     (`SettingsSyncStateResetTests`). A renamed or re-created IMAP folder is a new row and starts
     unfollowed.
2. **The access points** (`SyncEngine.folderAccessed`: the mark, then an access catch-up run):
   - opening a folder or pulling to refresh it (`AccountManager.syncFolders`): the mark is written first,
     before the connect and the listings, so an open while offline, or a listing that fails, still follows
     the folder. `followFolders` reads first and opens a write only when some folder is not followed yet:
     a mark is never cleared, so the usual pull (a folder already followed) never waits for the database's
     one writer before its first read (apart from the merge of a notification extension's staged rows,
     which every async read of the sync pool waits for). *(Amended in review 2026-11-23: it first opened a write on every
     pull.)* The run starts after the change read, so a folder the reader has just baselined may be
     listed. When that read finds the account busy (it sets the account's follow-up flag and reads
     nothing, #1289), the run starts all the same and waits for the turn; it may take the turn before
     the follow-up stage 2, and an Outlook folder the follow-up has yet to baseline is then not listed by
     this run (decision 5) but by the ordinary catch-up once it is baselined. *(Amended 2026-11-26,
     #1360, ADR-IOS-104: the run's slices wait as catch-up slices, behind the follow-up once that is in
     line; the run takes the turn before the follow-up only when the turn frees before the follow-up
     has joined.)*;
   - a drained move, archive or delete: its source and its destination (`AccountOperationExecutor.finishDrain`,
     `DrainContext.foldersAccessed`);
   - opening a message, from a folder, a search result, or a chat or AI answer alike
     (`MessageDetailViewModel.loadBody`): started when the body load ends, whichever way it ends, on a
     detached task, so the open never waits for it and the folder's catch-up requests never queue ahead
     of the message's body request on a provider's shared request slots (Graph's per-mailbox
     `HTTPConcurrencyGate`). A body still queued ends the load by handing it to the body poll, so the
     access starts then (a limit below). The view model's production init turns the access on
     (`accessesFolder`, fenced in `ListingRouteFenceTests`); its test init leaves it off unless a test
     asks, because the access writes through the shared engine and database, not a test's own pool.
   The trigger is not `syncFolderMessages`, the place the issue first proposed: that route also serves
   the post-send Sent listing and step 6 of the epoch rebuild, which are not user actions in the folder.
3. **The access catch-up run** (`SyncEngine.startAccessCatchUp`): one per account, on its own task (an
   unstructured task, as the older-mail worker's), never awaited by the caller; folders that
   arrive while it runs are taken by its next run. Each run is `runCatchUpRun` with
   `CatchUpRun.accessedFolderIds`: it asks only those folders (the syncable ones among them, so a folder
   whose mark did not land is not asked), under the account's turn and slice pacing like every slice,
   until they make no progress or their slices have spent `SyncConfig.accessCatchUpRunSeconds` (120 s)
   of working time (`CatchUpRun.workSeconds`), each slice's counted from when its provider work starts,
   once the account's provider work queue gives it a slot: the wait for the turn, the wait for the slot
   and the pacing wait between slices are not counted, because waiting is not working time. The run ends
   with the slice that spends its time. What a large folder still needs
   then is the backfill worker's, whose catch-up checks every followed folder. *(Amended in review
   2026-11-23: the run first had a deadline 120 s from when it took its folders, so a run whose first
   slice waited behind a long pass, as after a pull that found its account busy, could spend it all
   waiting and ask nothing.)* *(Amended in review 2026-11-23, second time. Superseded: "spent ... (120 s)
   inside the account's turn (`CatchUpRun.workSeconds`): the wait for the turn and the pacing wait
   between slices are not counted". A slice's clock then started at its turn, so its wait for a slot of
   the provider work queue, inside the turn, counted as working time, and a slice that waited its whole
   slice reached the provider with no time left; and a run whose last slice spent its time took another
   turn, and could wait for another pacing window, before it found its time spent. Every catch-up slice,
   the backfill's included, now starts its clock at its slot: ADR-IOS-107, amendment 2026-11-23 (#1109).)*
   `CatchUpContext.accessedFolderIds` tells the provider which folders an action reached (provider-neutral).
   `SyncEngine.remove(accountId:)` drops the folders waiting for a run and cancels the running one, so a
   disconnect that keeps the account's credentials (a re-authentication, re-adding an account) does not
   wait for its slot or its pacing window. A run still in line for the account's turn ends once the passes
   ahead of it have handed the turn over (waiting for the turn ignores cancellation by design); on a
   re-authentication their provider was just disconnected, so the wait is short.
4. **IMAP access check** (`IMAPProvider.catchUpPlan`, `counters:`, `accessed:`). An untracked folder with no
   mod-sequences has no cheap check, so the daily full check alone would leave an accessed folder stale for
   up to a day. An accessed, untracked folder is listed when its stored counters (`totalCount`, the
   listing's EXISTS, and `lastKnownUidNext`) differ from those its last completed listing started from
   (`IMAPCatchUpState.completionCounters`, taken from `Listing.firstCounters` before the first range, as
   `firstStamp` is; inside the opaque state, no column), with or without MODSEQ: a server with CONDSTORE
   alone need not move HIGHESTMODSEQ on an expunge, so an equal MODSEQ never vetoes a moved count. With no
   MODSEQ pair to compare (no fresh MODSEQ from the server or session, or a last completed listing that
   started with none, so no `completionStamp`) it is also listed when that listing completed longer ago
   than `SyncConfig.catchUpAccessCheckAgeSeconds` (1 h: a flag change moves no counter). With a pair, the
   MODSEQ check already lists a folder whose flags changed, and a tracked folder's changes come through
   its change read. *(Amended in review the same day: the first form vetoed moved counters when a pair
   existed.)*
5. **Outlook keeps its catch-up gate**: a followed folder is synced, so its change read baselines it first,
   and only then does the catch-up list it. Gmail's change read already covers every label; a followed
   label gains the catch-up.
6. **Unchanged:** sync by UID, never by date; the reconcile is a scan and runs on any network, battery level
   and power mode (header and body loads wait as before, ADR-IOS-107 amendment 2026-11-19); removals go
   through the one removal core; no mail content is stored; nothing provider-specific above the boundary.

**Why a new column, and why no index.** Every existing field was checked first:
1. `changeState` is sync progress. The UIDVALIDITY reaction sets it NULL (`AccountManagerUidValidityReset`)
   and the full sync's re-drive loops over the syncable set (`SyncEngineFullSync`), so a mark kept there
   would take the folder out of the syncable set inside its own epoch reaction: it would lose its full
   sync listing, change read and catch-up, and after an abort only the change pass's re-drive
   (`redriveArmedTurnovers`, every armed folder) would still reach it (Memory 114). Both Settings resets
   clear it (`resetSyncStateTxn`), and `FolderChangeState.encoded` stores NULL for a state with nothing in
   it. Keeping the mark there would mean carving it out of the epoch reaction and both resets.
2. `catchUpState` and `changeCursor` are provider-opaque JSON the engine cannot read above the boundary,
   and both are provider progress with their own lifetimes: an epoch change, the exit rule and both
   resets drop them, and a lapse rewrites the catch-up state (it adds the lapse it owes); nil already
   means "first listing" and "baseline needed".
3. `isFavorite` is the user's visible favourites list: setting it would add folders to the sidebar.
4. A per-folder "last synced" time does not exist; `Account.lastSyncedAt` is account-wide.
5. The listing counters and the walk's columns (`totalCount`, `lastKnownUidNext`, `lastKnownHighestModSeq`,
   `backfillComplete`, `backfillUidCursor`) are written by paths that are not user actions (the post-send
   Sent listing, step 6 of the epoch rebuild, the walk over every folder) and invalidated by a reset.
No index: the mark is read only with an account's folder rows (`syncableFoldersInOrder` filters the rows
read by `accountId`, tens per account); no query selects by the mark alone.

**Consequences.** A folder the user has acted in is kept current like a favourite, at the cost of its change
read and catch-up from then on. The set only grows; a folder the user stops using stays followed.
Limits (each recovers through the ordinary schedule, because the folder is followed from then on, except
the #1268 label sets and the #1276 cost, as their bullets say):
- An access that comes inside an open slice window waits for it (at most `catchUpSliceIntervalSeconds`).
- A visit shorter than the folder view's start delay before its sync is not an access: no sync starts,
  so the folder is not marked. This is on purpose: the mark is never cleared, so a folder tapped by
  mistake and left at once is not followed for good.
- An access with no change evidence waits for the ordinary schedule: on Outlook a first access by a
  drained action or a message open waits until the change read baselines the folder (decision 5); on IMAP
  with no mod-sequences, a flag change made elsewhere below the newest listing within an hour of the last
  completed listing waits for the next access after that hour, or the daily check; a message open, and
  the source of a drained move, archive or delete (which the drain does not list), compare the counters
  the folder's last listing stored, so a change made elsewhere since then waits for the folder's next
  open (whose listing refreshes them), the next access after the hour, or the daily check; a tracked folder's changes wait for its next change
  read; a listing that throws ends that run.
- A pull whose connect, listing or change read throws starts no access run, nor does one whose account
  is gone by then: the folders are already followed, so the backfill worker's catch-up reconciles them.
- A message whose body is still queued (the poll path: a background body queue, cancelled reads, an
  address the provider is blocking) starts its access when the load hands over to the poll, so the poll's
  next read (every 2 s) can wait behind at most one catch-up request on the folder's connection or
  request slot. The direct body load, the common open, is first.
- Rare timing windows where one action's mark is missed (an app kill between a drained action's commit
  and its mark, which also spans the post-drain listings; a retirement replay committed while offline,
  whose drain stops at the connectivity check before the mark; a message load cancelled during its first
  read): the next action in the folder marks it (#1263). The same issue holds a window where an
  account is removed and registered again under the same id while its old engine state is torn down:
  the teardown can cancel the new registration's access run; the marks stay, and the ordinary catch-up
  reconciles the folders.
- Following widens two existing limits to followed folders: a Gmail label's re-read overflow cut in a
  syncable label drops the retry for a label set the catch-up never replaces, so a cut message's user
  labels stay stale until a later change to that message is read; the ordinary schedule does not
  recover them (#1268). Outlook reads tracking folders before baselines every pass, in a fixed order,
  so once the tracking folders fill a pass's request allowance every baseline waits: a new followed
  folder's, and a main folder's re-baseline after a refused change token (the Inbox is first only
  within its phase), whose catch-up stays gated meanwhile; in a background pass the later tracking
  folders, secondary roles included, are not read either. A foreground pass recovers them for
  realistic folder counts (#1269).
- On IMAP without CONDSTORE no folder holds a change bookmark, so every folder is untracked, and an
  access whose counters moved lists the whole folder again: an arrival raises UIDNEXT, and the user's
  own archive out of the Inbox lowers EXISTS and raises the Archive's counters. While a user triages,
  the Inbox and the Archive are listed far more often than the daily check did (paced by the slice
  window). Cost only, nothing shown is wrong; skipping counters that show only arrivals is #1276.
- Pre-existing, not changed here: an IMAP folder the reader can no longer track keeps its bookmark on
  purpose, so the catch-up plan counts it as tracked and it gets neither the daily nor the access check
  (#1264).

Tests: `FollowedFolderTests` (`FollowedFolderMarkTests`: the mark, the order, the access plan: moved
counters list with or without a MODSEQ pair, the age rule only without one, including a missing fresh
MODSEQ; a state stored before the counters existed decodes with none and its next access lists the
folder; `FollowedFolderIMAPTests`: the wire oracle for opening the folder, a move into it, taking a
message out of it by a move, an archive or a delete (each following the folder and the destination, the
message held once in the destination on both sides), and opening one of its messages, on a server with
no mod-sequences and on a QRESYNC server, each against the scenario's expected server and device state,
the action's own `UID MOVE` the only change sent to the server, each run asking only the accessed
folders and a quiet re-open listing nothing, the message's body requested before any catch-up slice, a
second access during a run taken by the next run (and never asked alone, with a pause between the
handovers), an open while offline that still follows the folder, following a followed folder while
another write holds the database's writer (no wait), a pull whose change read finds the
account busy (its access run waits behind the running pass, asks nothing meanwhile, then reconciles the
folder with all of its time although its clock moved on twice that time while it waited), and a completion that keeps the
counters its listing started from across slices; `FollowedFolderOutlookTests`: through the production change read, the gated access sends no
request for the folder and writes no listing, then the baseline, then the listing),
`ReleaseBoundaryRecheckTests.applyOverflowInAFollowedFolderArmsTheCatchUp` (the first ids are kept),
`FolderIsFollowedMigrationTests`, `ListingRouteFenceTests.followMarkHasOneWriter` (every production
mention of the mark and of its column constant, and the detail view model's production init turning the
access on), `GmailCatchUpTests.removingTheAccountEndsItsAccessRun` (removing the account ends a run waiting
for its slot at once, sends nothing, and drops the folders waiting for the next run).

Keywords: isFollowed, followed folder, follow mark, markFollowed, followedColumn, folderAccessed,
followFolders, startAccessCatchUp, access catch-up run, accessedFolderIds, accessCatchUpRunSeconds,
catchUpAccessCheckAgeSeconds, completionCounters, firstCounters, Counters, syncable set, isSyncable,
custom non-favourite folder, sync on demand, v112_addFolderIsFollowed, accessesFolder, body poll, #1109,
#1263, #1264, #1268, #1269, #1276.

### Amendment 2026-11-23 (#1110): the folders outside the syncable set have their changes read every 15 minutes

**Context.** The passes read the changes of the syncable set only (`SyncEngine.isSyncable`: main roles,
favourites and, since #1109, followed folders). Every other folder (an IMAP custom folder or an Outlook
folder the user has not opened or acted in) was read only when opened: mail a server rule filed there, and
changes made there elsewhere, did not reach the device until then. Gmail was already covered: every
pass's history read reports every label.

**Decision.**
1. **The run.** A foreground pass whose full sync was due by its 15-minute clock (`lastFullSyncAt` against
   `fullSyncInterval`; not a pass whose full sync ran only because its change read needed a listing), and
   whose full sync ran without an error, starts the account's other-folder run when it ends
   (`SyncEngine.startOtherFolderRun`, `SyncEngineOtherFolders.swift`), beside the older-mail worker. A full
   sync whose listing proved nothing leaves the clock due, so the next clock-due pass may start the next run.
   At most one run per account: a start while one runs starts none. A run under way when the app leaves the
   screen goes on in the app's later wakes, as the older-mail check and the access runs of #1109 do: no
   lifecycle check of its own (decided 2026-11-23). *Superseded (2026-11-23):* "The run is the foreground's
   only (`CatchUpRun.inForeground`, the lifecycle flag `DatabaseSuspension.isAppActive`): a pass that ends
   after the app has left starts none, and each slice asks again at its turn and at its slot, so a run whose
   app leaves ends there and reads nothing more". The run has no timer, scheduler, queue,
   gate or turn of its own (tabmail-ios rule `sync-work-rides-the-existing-pipe.md`): it is the catch-up
   runner (`runCatchUpRun` with `CatchUpRun.readsOtherFolders`), so each slice takes the account's turn
   (ADR-IOS-104), waits for the pacing window outside it, takes a `.headerFetch` slot of the provider work
   queue and works at most one slice (`catchUpSliceSeconds`), then hands the turn on. A trigger that comes
   during a slice sets the account's follow-up flag (#1289), and the stage 2 it asks for waits at most that
   slice. The poll, IDLE, push, pull and return passes are unchanged, and nothing is added to
   `syncStartup`: a clock-due pass does one in-memory check and starts one task when it ends.
2. **What a slice reads.** The other folders (`isSyncable` false, a non-empty path) not yet done in the
   run, those whose read finished, moved (a baseline that moved and is not done) or failed longest ago
   first, never-read ones first of all (`otherFolderReadOrder`, an in-memory record per engine,
   `otherFolderAttemptedAt`, which keeps only the account's folders that still exist, so a deleted folder's
   time neither stays nor passes to a folder made later at its id). *Superseded (2026-11-23):* "finished or
   failed": a long baseline first in the order kept its never-read place and took every slice's read share
   before a folder never reached, run after run. The slice reads them
   through the provider's change reader with the new scope `ChangeScope.otherFolders` (every folder of the
   request is read: `ChangeFolder.isSynced` true), for at most half the slice (`otherFolderReadShare`), its
   first folder excepted: that folder's read may start while the slice itself still has time
   (`ChangeContext.firstFolderDeadline`, `ChangeRequest.forFirstFolder`; decided 2026-11-24), so a slow
   session check (the NOOP before the reads) never leaves a slice with no folder read, and no request
   starts after the slice's end. *Superseded (2026-11-24):* the first folder too only within the read
   share: on a slow link the NOOP used up the share, every folder came back not run, and every later run
   did the same. The slice applies the answer with the passes' one generic apply (`applyChangeSet`). Readers read the request's
   folders in its order and report a folder they did not reach as `.notRun`, which stays pending. A folder
   whose read was started and cut by the slice's time is kept apart from one not reached (#1358): the IMAP
   reader, which always sends a run's folder its STATUS (or SELECT) first, reports it `.notRun` with
   `FolderChanges.readCut`; the Outlook reader reports `.baselining` with `readCut` for a run's baseline read
   that passed no page (its time ran out inside the page, or the page's header batch failed), so the held
   rows of a page read again are applied but not counted as the folder moving; the engine also counts as cut
   an Outlook baseline that neither moved nor failed and an untracked folder whose listing could not start.
   A cut folder stays pending while the slice moved
   or failed another folder (the next slice reads it first); a slice that did nothing else counts it as
   tried (`inFlightFolderIds`: left out of the rest of the run, behind the others in the next run's order),
   so the run goes on to the next folders. Before this, on a slow link a changed first folder's STATUS could
   use the whole read share every run: no slice moved, the run ended, and the folders after it were never
   read while the link stayed slow.
   - IMAP with QRESYNC or CONDSTORE: each folder's own bookmark (`Folder.changeCursor`). A first read stores
     it (`.baselineReady`) and arms the folder's catch-up check (decision 5). On a server with CONDSTORE and
     no QRESYNC, the bookmark's removal check (`runRemovalCheck`) takes at most ONE step in a slice (the
     proof of its open candidates, or one chunk's SEARCH), started only while the slice has time, each
     request at most `SyncConfig.catchUpRequestTimeoutSeconds`, as a request of the older-mail check; its
     progress rides in the bookmark, so later slices and runs take the next steps until the window is done
     (decided 2026-11-23). A pass still takes every step its budget pays for whole. Before, a run priced
     each step at the passes' request limit, above its read share, so the check never moved in a run. A
     check finished in a slice whose arrivals cannot start in it (no time left) stays in the bookmark's
     progress (`pendingCheck`) with its proven removals, so a later slice reads the arrivals instead of
     taking the check again; a pass is unchanged.
   - IMAP with no change tracking: each folder's STATUS. A folder whose counters moved is listed
     (`refreshUntrackedFolder`, `otherFolderSlice:`) only while the slice has time to start a listing
     (`.listingNotStarted` otherwise: a later slice of the run lists it). The listing (the 50-message window
     a pass lists) is bounded as a request of the older-mail check is (`ListingRequestBound`, decided
     2026-11-23): a request is one provider call (the epoch check's sample, the listing's window read),
     bounded as a whole, as in `IMAPProvider.catchUpFolder`. The call starts only while the slice has time,
     and the listing waits for it at most `SyncConfig.catchUpRequestTimeoutSeconds`, a limit that covers
     everything inside the call: the connection checkout, a cold session's connect and login, SELECT, and
     the FETCH. So a command of a call that started in time may start after the slice's end, and a slice
     holds the turn at most to its end plus one such call, as an older-mail slice does (decided 2026-11-23:
     per call, not per command). *Superseded (2026-11-23):* "each of its requests (the epoch check's FETCH,
     the listing's read) starts only while the slice has time", which read as a check before every command.
     A window read the slice's end leaves unstarted (after the epoch check) is a listing not started
     (`.listingNotStarted`); a call the request limit cuts proves nothing (`.unproven`). Either way the
     listing writes nothing, the folder's counters stay as they were, the run's listing owes no deep listing
     and sets no due mark (only a pass's unproven listing does: a full sync never lists an other folder, and
     the run ignores a due mark), and a later slice or run lists the folder. *Superseded (2026-11-23):* "A
     listing cut or given up writes nothing: it is unproven" (a cut or unproven run listing owed a deep
     listing and set a due mark, as a pass's does). *Superseded (2026-11-23):*
     "A listing once started runs to completion, so a slice can end later than its time by that listing"
     (the listing's connection, SELECT and FETCH had no bound of their own). The listing runs no deletion check:
     its walk can take longer than a slice, and the weekly whole-folder check (decision 5) removes what it
     would. A due mark (`FolderChangeState.listingDue`) alone lists nothing in a run and is left as it is.
     *Superseded (2026-11-23):* "the listing's deletion check is bounded by the slice"; "a check cut by a
     slice's end leaves one, and honouring it would list the folder in every run".
   - Outlook: the per-folder Graph delta of the run's folders in the request's order (a pass reads tracked
     folders first; a run does not, so a folder in its baseline is never kept behind tracked ones run after
     run), with no folder-list read; a first read baselines, across slices if it must. It stops when the
     request allowance is spent (`.notRun`).
   - Gmail: nothing is sent (every folder `.notRun`).
3. **What a run never writes.** The folder list, the account's bookmark (the slice keeps it, `.keep`),
   `lastSyncedAt` and `lastFullSyncAt`; and it never turns a folder's coverage (`FolderChangeState.tracking`)
   on, since the full sync does not list these folders. A refused or dropped bookmark of an other folder
   (`dropChangeBookmark(listedByFullSync: false)`, and the first bookmark's due listing) does not make the
   account's full sync due; it arms the catch-up check as always. That includes a bookmark dropped because a
   read took the folder's re-read list over `changeRecheckLimit`.
4. **The end rule.** A run ends at the first of: every other folder read once in it (a folder whose baseline
   a slice's end cut stays pending while the slice moved another); a slice that reads nothing new and leaves
   no new folder out (a slice whose only work was a folder its time cut leaves that folder out, decision 2,
   so a cut first folder never ends the run; a reader that reads nothing, Gmail's, still ends it at once); its
   working time spent (`SyncConfig.otherFolderRunSeconds`, 120 s, slice time only: the waits for the turn,
   the slot and the pacing window do not count, as for the access run of #1109); the account removed
   (`remove(accountId:)` cancels and awaits it). A folder the run did not finish is read first by the next.
   *Superseded (2026-11-23):* "the app no longer in the foreground at a slice's turn or slot".
5. **The catch-up checks every folder** (`catchUpFolderIds`): the syncable ones first, then the others
   (`CatchUpContext.otherFolderIds`, `CatchUpSchedule.leastRecentlyAttemptedFirst(later:)`), so the other
   folders' first checks never hold back a due check of the syncable set. An IMAP other folder with no
   change tracking gets its whole-folder check weekly (`SyncConfig.catchUpOtherFolderFullCheckIntervalSeconds`)
   instead of daily, because its run cannot fit a deletion check in a slice; a first check and a lapse are
   not held back. First checks run on any network, as every scan does (#1063). This amends ADR-IOS-107
   decision 1. *Superseded:* "the syncable folders, then every other folder owed a check after a move
   retired without proof".
6. **Unchanged:** the syncable set, the passes and their triggers, the sync timing promises (each is listed
   in the change's pull request), the startup budget (tabmail-ios memory 042), sync by UID, the one removal
   core, no mail content stored, nothing provider-specific above the boundary
   (`ChangeSeamFenceTests.otherFolderRunIsProviderBlindAndUngated`).

**Consequences.** A change made to an other folder elsewhere reaches the device within about 15 minutes
while the app is open. Cost per run: IMAP with no change tracking, one STATUS per quiet folder; IMAP with
tracking, one SELECT per folder; Outlook, one delta request per quiet folder; Gmail, nothing. An account's
first runs also store each folder's first bookmark or baseline, spread over runs by the working time.
Limits:
- The run starts only after a clock-due foreground pass: while the app is closed the other folders wait for
  the next opening.
- The run passes no re-read list (`ChangeRequest.recheck` is empty): a message a reader could not read in an
  other folder (an Outlook last verb past the slice's allowance, an answer that could not be used) goes on
  that folder's re-read list, which the foreground passes already read for a folder outside the synced set,
  within their per-pass re-read budget (`changeRereadBudgetPerPass`) and after the folders' changes (Outlook)
  or the Inbox (IMAP). One re-read path, the passes'. A list a read takes over `changeRecheckLimit` is cut
  in an other folder as in a syncable one, and the folder's catch-up is armed for the cut ids (the catch-up
  checks every folder, decision 5; a folder holding a bookmark drops it, which leaves the full sync as it
  was). *Superseded (2026-11-23):* other folders were exempt from the cut, which kept every id because the
  catch-up never checked them.
- On IMAP with no change tracking a flag change made elsewhere moves no counter: it arrives with the weekly
  check, or at once when the user opens the folder (which then follows it, #1109).
- A folder whose read keeps failing is left out for the rest of its run and goes behind the others in the
  next.
- A new-mail follow-up asked for during a slice takes the account's turn in the order the turn's line keeps
  (first come, first served): it waits for the slice holding the turn plus the slices of the other runs
  already waiting for it (the older-mail worker, an access run, the other-folder run: at most one each), each
  at most about 5 s. ios#1360 makes the turn hand the follow-up ahead of them; this change leaves the
  hand-over as it is (decided 2026-11-23).
- A slice reads its folder rows inside the turn with the awaited database read, which first awaits the
  single-flight merge of the notification extension's staged rows. A pass waiting for the turn does the
  same merge at its own first read (the same awaited read, the same single flight), so the merge only moves
  earlier and a trigger's time to its first read does not grow (decided 2026-11-23: no change).

Tests: `OtherFolderRunTests` (`OtherFolderRuleTests`: the weekly and daily check, the order, Outlook's
folders, Gmail's empty read, the dropped bookmark; `OtherFolderIMAPTests`, against `FakeIMAPServer` with and
without QRESYNC: rule-filed mail arrives after a clock-due pass, the passes send nothing for the other
folders, a listing-only full sync starts no run, the account's clocks and the folders' coverage stay as they
were, a quiet folder costs one STATUS, a trigger during a slice gets its stage 2 before the run's next slice,
waiting is not working time, a folder not reached is read first next run, a listing starts only within the
slice, a failed folder is left out of the run, a run's listing runs no deletion check, a cut first folder
does not stop the run (#1358, both modes, run after run), the reader reports a cut read apart from a folder
not reached and from a pass's cut (`theReaderReportsACutReadApart`), a run's listing is bounded as an
older-mail request (a new-mail trigger brings the Inbox while the listing's answer is held, and the next run
lists the folder again), an other folder's whole-folder check is weekly end to end, removing the account
ends the run when its slice ends (`removingTheAccountEndsTheRun`), a run goes on when the app leaves the
screen (`aRunGoesOnWhenTheAppLeavesTheScreen`), a slice waits for its slot in the older-mail tier
(`aSliceTakesTheOlderMailSlot`);
`OtherFolderRuleTests.outlookRunKeepsTheEnginesOrder`, `OtherFolderRuleTests.listingRequestBound`;
`OtherFolderSliceRuleTests`: what a slice reports for cut, not reached, moved and failed folders (a folder
not reached goes ahead of a baseline that moved), an Outlook baseline the reader reports cut, the order
forgets a folder that is gone (`aGoneFolderLeavesTheOrder`), a listing whose window read the slice's end
leaves unstarted has not started and owes nothing (`aListingCutBeforeItsReadHasNotStarted`), the account
parts it ignores (no re-read list), a reader that throws or none; `OtherFolderOutlookTests`: baseline, then
new, deleted and read changes, a baseline page not passed is cut (`aBaselinePageNotPassedIsCut`), the
older-mail check works a due syncable folder before a due other folder under one shared budget
(`olderMailWorksTheSyncableFolderFirst`)), `GmailCatchUpTests.olderMailWorksTheSyncableFolderFirst`,
`IMAPChangeCondstoreCheckTests.otherFolderRunTakesOneCheckStepPerSlice`,
`ReleaseBoundaryRecheckTests.applyOverflowIsCutInEveryFolder`, and
`ChangeSeamFenceTests.otherFolderRunIsProviderBlindAndUngated`. *Superseded (2026-11-23):* "a run starts
and takes each slice only in the foreground".

Keywords: other folder, other-folder run, startOtherFolderRun, readOtherFolders, readsOtherFolders,
otherFolderReadOrder, otherFolderAttemptedAt, otherFolderRunSeconds, otherFolderReadShare, ChangeScope
otherFolders, catchUpOtherFolderFullCheckIntervalSeconds, otherFolderIds, catchUpFolderIds,
listingNotStarted, listedByFullSync, changeRecheckLimit, later wakes, rule-filed mail, folder outside the
syncable set, 15-minute clock, clockDue, readCut, cut folder, tried, slow link, ListingRequestBound,
listing bound, catchUpRequestTimeoutSeconds, Outlook baseline page not passed, baselining readCut, #1110,
#1358, runRemovalCheck, removal check step, CONDSTORE without QRESYNC, per provider call, account removal,
headerFetch slot, staging merge, firstFolderDeadline, forFirstFolder, slow NOOP, first folder in the slice, pendingCheck kept.

### Amendment 2026-11-26 (#1363): a folder the older-mail walk found empty is held whole

**Context.** Decision 3 lets a baseline insert nothing in a folder with no held range, and Outlook's reader
(decision 5) fetches nothing for it. The older-mail walk sets the held range (`Folder.oldestSyncedDate`) only
from messages it sees, so a folder it finds empty is marked complete (`Folder.backfillComplete`) with no range.
Mail that landed there after the walk and before the folder's first read was skipped by that read, and the
bookmark then passed it: later reads report only later changes, and the Outlook catch-up lists only the ranges
between the folder's own rows, of which there are none. It stayed missing from the folder's list and from
search until the user opened the folder. This shows on folders outside the syncable set, whose first read is
the other-folder run's (#1110): a synced folder's window listing fetches its newest `syncMessageLimit`
messages, and sets its range once the folder holds that many. IMAP already holds the whole folder once its walk
has completed (`IMAPProvider.heldRangeStart`, amendment 2026-11-16).

**Decision.**
1. **A folder with no held range whose older-mail walk has completed holds the whole folder.** A baseline
   record inserts a message the folder lacks whatever the message's date. The apply reads `backfillComplete`
   from the folder row it already loads in the folder's transaction (`SyncEngine.applyChangeRecord`). Outlook's
   reader fetches the headers of every such message (`ExchangeProvider.needsHeader`, from
   `ChangeFolder.olderMailComplete`, which `SyncEngine.changeFolder` already fills). Before the walk has
   completed, a folder with no range still inserts and fetches nothing: the walk takes what is there.
2. **A completed walk never widens a held range.** A folder with a range keeps decision 3: mail below the
   range of a walked folder is the older-mail catch-up's (ADR-IOS-107: once the walk has completed, it lists
   a folder that holds rows down to the epoch). A folder with no rows has no such listing, which is why the
   no-range case above needed its own rule.
3. **Resets are unchanged.** Every reset clears `backfillComplete` in the same write that clears or
   re-anchors the range (`resetSyncStateTxn`, the startup resets and the shipped migration clear both;
   Smart Reindex's `resetCrawlState` anchors the range at now), so decision 3's folder "after a reset" still
   inserts nothing until its walk runs again.
4. **Nothing new is stored or asked.** No new query, statement, column or migration, and no new kind of
   request: Outlook's first read already fetches missing messages in `$batch`es, within its time budget and
   request allowance. Only Outlook's first read carries records today (IMAP's and Gmail's set the bookmark
   only), so nothing changes for them; the apply's rule stays provider-neutral.
5. **Sync timing promises: unchanged** (each is listed in the change's pull request). No trigger, gate, turn,
   deadline, skip, IDLE step or start-of-pass work changes. The header fetches run inside the read's own budget
   and allowance; a pass reads tracked folders and the Inbox before folders on their first read; an
   other-folder slice stays one slice; nothing is added to the startup or return path.

**Consequences.**
- A folder the walk completed empty is healed by its first read on a build with this change, mail moved in
  with an older date included. A folder whose first read ran on an earlier build keeps what that read skipped
  until it is opened.
- Cost: one header fetch per message the folder lacks, inside the read's allowance; a long first read goes on
  across slices and runs (#1358), and bodies follow by the download rules. Under a storage limit such a folder
  may take more mail than the walk would have; the storage prune trims it as it does any folder, and a
  re-baseline loads trimmed mail again, as for any folder.
- The reader decides from the folder as its read began (`ChangeFolder`, a value snapshot), the apply from the
  row in its transaction. A reset while a read is under way leaves the apply inserting nothing (the row's
  `backfillComplete` is false again). A walk that completes while a first read is under way: that read keeps
  the earlier rule, and the baseline's later reads take the new one.

Tests: `OutlookChangeReadingTests` (`baselineWithNoHeldRangeAfterTheWalkTakesEveryMessage`, `needsHeaderRule`,
`baselineFetchesOnlyWithinTheHeldRange` with and without a completed walk, `baselineWithNoHeldRangeInsertsNothing`
before the walk), `ChangeApplyTests.firstReadInsertsWithinTheHeldRange`, and end to end on the Graph fake
`OtherFolderOutlookTests.mailAfterAnEmptyWalkComesInWithTheFirstRead` (the walk finds an other folder empty, a
new and an older moved-in message land, the run's first read inserts both).

Keywords: #1363, walked empty, empty folder, no held range, held whole, oldestSyncedDate nil, backfillComplete,
olderMailComplete, needsHeader, heldRangeApplies, first read, baseline gate, older-mail walk completed, moved in
with an older date, other-folder run, IMAP heldRangeStart rule.
