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

Keywords: changeReadMaxRoundPages deleted, round length, long round, per-item 5xx, unreadable header,
rereadLater, page hold, absent field, references kept, partial record, carriesReadAndFlag, kept-back flag
change, #444.
