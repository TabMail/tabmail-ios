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
3. **The re-read list.** Every change the apply keeps back under a shield, and every message the reader
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
over-long one, so Gmail reports both as `.refused(.expired)`.

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
     (`SyncEngine.syncableFoldersInOrder`); a per-folder reader reads only these.
   - `ChangeFolder.heldSince`: the start of the folder's held range (`Folder.oldestSyncedDate`), a hint
     only; the apply checks the range again inside the transaction.
   - `ChangeRequest.localRows`: the existing `CatchUpLocalRowReader` (ids and two flags, never content;
     ADR-004), so a reader whose records lack the header fields fetches headers only for messages a folder
     does not hold.
   - `ChangeContext`: the caller's read deadline, an injectable clock and `isExpensiveNetwork`, a value
     snapshot taken when the pass's turn starts.
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
     baseline was first needed.
   - **Two `$select`s, chosen by role when a chain starts and stored in the cursor.** The Inbox uses the
     header fields (`ExchangeGraphMessageRequest.readChanges`, `GraphAPI.headerOnlySelection`), so new
     Inbox mail arrives in the delta page itself. Every other folder uses the state set
     (`GraphAPI.stateSelection`: `id,isRead,flag,receivedDateTime,categories`). A change to a message the
     phone holds applies from that record; a message the folder does not hold whose record carries
     `receivedDateTime` (a new or moved-in message) gets its headers fetched, when the folder is tracking,
     or during its baseline when the message is within the held range.
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
     setting is not consulted. The Inbox baseline runs on any network.
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
these ids on its folders' lists. Detail: `IOS-ACTION-003` ("Retired actions read again").

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
3. **A list is cut only where the catch-up will find the rest** (added same day, review round 4). Over
   `SyncConfig.changeRecheckLimit`, a folder the catch-up checks (`SyncEngine.isSyncable`: a main role
   or a favourite, the same set `syncableFoldersInOrder` gives the full sync and the catch-up run)
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
`favouriteCustomFolderKeepsEveryRetiredId`), `OutlookCatchUpTests.recheckOverflowHealsAFlag`,
`ChangeApplyTests.recheckOverflowArmsCatchUp`.
Keywords: changeRecheckLimit, overflow, stored ids never cut, this pass's additions, retired ids
drain, #903.
