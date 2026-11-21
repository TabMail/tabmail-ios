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
     (`SyncEngine.syncableFoldersInOrder`); a per-folder reader reads only these.
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
   reaction runs after the folder transaction and is re-driven at the next pass start
   (`redriveArmedTurnovers`). Every read carries `FolderChanges.addressEpoch`; the apply's binding
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

### Amendment 2026-11-20 (#1062): the owed check is the catch-up's UID listing

The self-heal pass an unproven move owes a folder (`healFoldersAfterAnUnprovenMove`,
`selfHealRecentMessages(forceSingleFolder:)`, the 90-day date reach) is deleted. The mark
(`FolderChangeState.selfHealOwed`, `selfHealLapse`) is now settled by the IMAP catch-up (ADR-IOS-107,
amendment 2026-11-20): a CLEAN completed listing that started after the mark loads every missing UID
in the held range by UID and calls `markListingDue`, so the next scheduled full sync lists the folder
and `commitChangeBaseline` tracks it again. An unclean completion (a UID passed over at the hold
bound, a listing whose first UIDNEXT read reported none (`topUnknown`, 2026-11-20), or loads skipped as an over-age read in any slice of the listing) keeps the folder owed and
re-marks nothing: an owed folder counts as untracked in the catch-up plan even with a bookmark, so it
is relisted at least daily, plus when its change counter (HIGHESTMODSEQ) moves past the stamp the
unclean listing still records. A clean completion that started before the mark re-marks the lapse once
(amended 2026-11-20). *Superseded (2026-11-20):* "An unclean completion (a UID passed over at the hold
bound) or one that started before the mark re-marks the catch-up lapse, so a folder holding a new
bookmark is still listed again until the mark settles." (selfHealDue, owed check, unproven move,
catch-up, re-arm, #1062)
