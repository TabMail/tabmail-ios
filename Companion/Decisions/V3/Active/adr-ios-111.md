## ADR-IOS-111: Provider-Neutral Change Reading

**Status:** Active (2026-11-12). Gmail is the first provider under it (#783, #735, #715); Outlook and IMAP
keep their own change paths until their readers land.

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
   Background passes never store a candidate. The candidate is stored even when a folder's listing failed:
   that folder stays untracked, so every later full sync lists it until a listing finishes, and nothing is
   lost meanwhile. A change to its mail after the candidate is in the history the next reads take from the
   bookmark; an account-wide reader names every folder, and a full record inserts a message the folder does
   not hold yet. Its mail as it stood before is taken by its later window listing, and older mail by its
   catch-up, which runs for every syncable folder whether or not the window listing finished and keeps a
   lapse mark until that folder's check is done. (Superseded: the candidate waited for every syncable
   folder, so one folder that could not be listed kept the account with no bookmark, and every foreground
   pass listed every folder again while changes to older mail went unread.)
6. **Refusal.** One transaction clears the bookmark, untracks every folder, marks one lapse for each
   folder's catch-up and makes the full sync due (`applyChangeRefusal`); the same pass then reads again with
   no bookmark, so the re-list and the new candidate happen in that pass and exactly one catch-up check runs.
   A pass's retry after a lost connection reads the account row again first: the failed attempt may already
   have applied a refusal, and retrying from the pass's own copy would be refused a second time and mark a
   second lapse.
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
pass starts a new bookmark and lists every folder.

**Not done here (open):** the Outlook and IMAP readers; action tags are NOT read from Gmail labels (ADR-IOS-036
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
