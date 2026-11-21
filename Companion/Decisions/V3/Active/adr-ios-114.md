## ADR-IOS-114: The Summary and the Precomputed Reply Arrive as JSON with a Text Message; AI Results Live as Long as Their Email

**Status:** Active (2026-11-05). Decided 2026-11-05 (chat view, iOS 2.0). Backend side:
the backend's protocol 2.0.0 JSON shape. iOS issue #387. A deliberate exception to
ADR-IOS-008 (Thunderbird parity) for the AI cache lifetime and the response format, until a
Thunderbird release moves to protocol 2.0.

**Context:** the chat view shows each email of a thread as a short text message in its sender's voice,
and the AI reply as the text message the user would send. Both need a second, short rendering of the
same AI result, kept as long as the email itself is shown.

**Decision:**
1. **Protocol 2.0.0.** `TABMAIL_PROTOCOL_VERSION` is a PROJECT-level build setting (one value for the
   app and the Notification Service Extension), now `2.0.0`. The app sends it as `X-Client-Version`
   (`BackendClient.clientVersion`). The extension now sends it too (`BackendNSEClient.protocolVersion`,
   its own Info.plist `TabMailProtocolVersion`): before this it sent no version at all.
2. **JSON only.** At 2.0.0 the backend returns the summary as `{todos, summary, reminder{due_date,
   due_time, content}, text_message}` and the precomputed reply as `{subject, body, text_message}`.
   `AIResponseParser.parseSummaryResponse` / `parseReplyResponse` read that object and nothing else;
   the labelled-text parsers (`extractSection`, `AIService.parseComposeResponse`) are deleted. A reply
   that is not the object is no result (nil blurb / nil reply), retried like a failed call. The stored
   shapes are unchanged (todos `• a • b`, one-line blurb, HH:MM reminder time, reminder only with content).
3. **Storage.** `MessageHeader` and `MessageAICache` gain `summaryTextMessage` and `replyTextMessage`
   (`v105_addAITextMessages`, nullable, no backfill; numbered after main's newest,
   `v103_addFolderChangeCursor`, whose numbers stay; decided 2026-11-07: main has priority, and
   these migrations have run on no released build). The next migration is v107. Each text message belongs to its result: every
   writer that sets a summary or a reply sets its text message with it (nil included), the survivor
   merge and the pre-sync restore carry it with its result, and `MessageAICache.writeThrough` replaces
   the text message whenever it replaces the result. The extension stages `summaryTextMessage` in
   `nse_processed_message` (`NSEStagingDB.ensureSummaryTextMessageColumn`, staging list v8), and the
   merge copies it to the header and the cache.
4. **No text message, by source.** A Device Sync peer (Thunderbird) result carries none, so adopting a
   peer summary or reply clears the text message. A user edit of the reply in compose
   (`ComposeView.writeCachedReplyToDB`) clears `replyTextMessage`: it described the AI's body. The
   "no content" local summary has none. A result computed before 2.0 has none. Requesting the missing
   ones is the chat view's job (decision 8).
5. **Lifetime (decided 2026-11-05).** An AI result lives as long as its email is on the device, with no size or age
   limit. The time-based purge and its inbox-only touch (`refreshAICacheTTLAndPurge`,
   `SyncConfig.aiCacheTTLDays`, the unused `replyTTLSeconds`) are deleted.
   `SyncEngine.runPurgeOrphanedAICache`, run by storage maintenance (`SyncEngine.runWALMaintenance`:
   the foreground poll and the background processing task), deletes an entry only when no header in ANY
   folder has its Message-ID and it has been untouched for `SyncConfig.aiCacheOrphanGraceDays` (7); a kept entry is
   re-stamped so it is not re-checked for another grace period. The grace keeps the cache's original
   job, restoring AI to a header that leaves and comes back (stale detection, a UIDVALIDITY reset).
   Decided 2026-11-05: the 7-day orphan grace. The extension's cache upserts now record the
   Message-ID, so the purge can match them to their email.
6. **Decoding as sent, and older entries' identity (2026-11-05).** The summary JSON is
   decoded exactly as received: rewriting characters first (`normalizeUnicode`, kept from the labelled
   text) turned curly or fullwidth quotes inside a JSON string into bare ASCII quotes and broke the
   object. A reply body is any non-blank string, "None" included: only the text message's "NONE"
   placeholder of the summary is not a body rule. Entries an older build wrote have no Message-ID; the
   purge then reads it from the entry's key (`SyncEngine.aiCacheEntryHasEmail`: the text after the
   key's last colon, kept only when a header of the key's own account has it, in any folder), so an
   email that moved before the upgrade keeps its results. A Message-ID that itself contains a colon
   reads wrong there and counts as an orphan, recoverable by asking again. Writers do not fill the
   missing value: the extension's one cache upsert (`NSEDataBridge.upsertAICacheFromStaging`, for an existing and a
   new header) records the Message-ID it has, as every new entry does.
   `v106_repairAICacheMessageIds` (`AppDatabase.repairAICacheMessageIds`) stays: it fills the Message-ID from the header in the folder the key names. The purge no
   longer depends on it.
   **Amended by the rebuild (2026-11-09):** the purge no longer reads a missing
   Message-ID from the key. `v106_repairAICacheMessageIds` stays as written and is the only repair: an
   entry it could not fill (its email had moved before the upgrade) is purged after the grace and
   its results are made again when needed (bounded, self-healing). Writers now fill a missing
   Message-ID (NULL or empty) from the one they write with, and never replace a stored one:
   `MessageAICache.writeThrough` and the extension's upsert (`NSEDataBridge.upsertAICacheFromStaging`,
   also when its AI fields are unchanged). So such an entry is kept again from its next write while
   its email is on the device (`AICacheMessageIdFillTests`). And an entry is kept only while
   a header OF ITS OWN ACCOUNT (the key's first part) carries its Message-ID, so another account's
   copy of the email keeps nothing and a removed account's entries go after the grace; this
   replaces writer-side account checks in `writeThrough` and the extension merge, which are
   not built. A second purge trigger at the end of the AI queue's drain was removed (2026-11-05).
   The purge reads the clock once (2026-11-05; its `now`
   argument), the base of its cutoff and the re-stamp of a kept entry, so a kept entry always leaves
   the selection and the pass ends, even if the clock is set back while it runs. Later the same
   day: the extension merge stamps a cache entry's `updatedAt` as a date
   (`NSEDataBridge.upsertAICacheFromStaging`), like every other writer. A number sorted before every stored
   date, so such an entry missed the grace. The two "no content" summary writers
   (`AccountManager.processMessage`'s shortcut and `BodyFetchProcessor`'s confirmed-empty write)
   clear the text message with the summary they replace.
7. **Compose's recompute writes through the identity guard (2026-11-05).**
   `ComposeView.recomputedReply` stores its reply and text message with
   `AccountManager.aiGuardedHeaderWrite`, using an `AIWriteTarget` captured from the email compose is
   replying to. A UIDVALIDITY reset can put a different email at the same address while the model
   answers; the write is then dropped, and the suggestion is still shown in compose. The queue's
   pre-dispatch Device Sync check (`ActiveAIQueue.executeJob`) asks through `AIService.peerProbe`, the
   seam the opened-email path already uses, so a whole queue job can be run against a fake peer
   (`ActiveAIQueue.executeWholeJobForTesting`).
8. **Chat summaries (amendment, decided 2026-11-05).** The chat view
   needs a summary with a text message for every email of a thread, from any folder, the user's own
   included. Two requests ask for them, both behind `ChatViewConfig.isActive` (the user's toggle and AI
   on, decision 9), read once at the start of the operation:
   - **Opening a thread** (`MessageDetailViewModel.loadThreadMessagesAsync`, once per open):
     `ActiveAIQueue.enqueueChatSummaries` with the opened message and every member
     `ThreadDetection.findRelatedMessages` returns. A member with its body gets a job now; one without
     goes to `ActiveBodyQueue`, and gets its job from a later request that reads it from the
     database with its body. Nothing is kept for it in memory.
     *Amended 2026-11-15:* the queue no longer holds a member that waits for its body. It was held
     in `ActiveAIQueue.chatAwaitingBody` and released by `BodyFetchProcessor.flushBatch`
     (`chatBodyArrived`), which only the AI-enabled body queue called; five other body writers and
     the background backfill never released it, and every queue cancel emptied it. The map, the
     release and the writer's call are deleted.
   - **The background walk** (`chatWalkCandidates`, run at the end of `repopulateFromDatabase`):
     the threads of the newest `SyncConfig.maxRecentEmails` Inbox rows, every member with its body.
     *Amended 2026-11-15:* drafts are left out before each thread's window is
     taken, so no chat job is asked for a draft (its unsent text would leave the device for
     nothing shown) and the window holds real emails. Each thread is looked up once: an Inbox row
     that an earlier lookup reached through the thread's reference links, started from a row with
     the same `threadId`, is skipped (`ThreadDetection.related`, `linkedIds`). The links are
     direction-agnostic, so such a row's lookup would return the same thread; a row reached only
     through a native thread id, or under another one, is looked up itself, so no email is lost.
     Before, every Inbox row of a thread repeated the whole lookup (k rows of an N-email thread
     cost about k x N reads), on every `syncStartup`, push wake and background refresh.
     *Amended 2026-11-15:* unsent draft text never reaches the backend, with no exception. The
     queue decides it from the email's OWN folder role, read with the row
     (`ActiveAIQueue.chatSummaryAllowed`), never from what a screen loaded: `enqueueChatSummaries`
     (the open, a joining email, a row on screen) gives a Drafts-folder email no job and no body
     request, and the scope check before every model call (`inScope`, in `executeJob` and
     `readJobOutcome`) refuses a chat summary of one however it was queued (the walk, a landed
     body, a twin's hand-back, any later caller). An email whose folder row is missing is refused
     too (fail closed; the next sync writes the folder and a later ask asks again).
   **A thread is the whole thread (amendment 2026-11-06):** `findRelatedMessages`
   returns every email connected to the opened one, with no length or depth limit, because the chat
   shows the whole thread, all the way back (decided 2026-11-06: "Typical email threads are not that long").
   Its old cap (`SyncConfig.threadQueryLimit`, 100 emails, plus five expansion rounds) dated from the
   first release with no recorded reason and is deleted. The expansion still ends: each round adds
   only emails not seen yet. The bound is on the AI work instead (decided 2026-11-06: "add a safety
   bound that you load up to something like 10 emails from the current visible oldest message"):
   the open chat asks only for the emails on screen and those near them (decision 9,
   `ChatSummaryWindow`).
   **Amended 2026-11-09 (supersedes the 2026-11-06 window):** the chat asks, on open, for the
   thread's newest `ChatViewConfig.summaryWindow` emails, newest first, and later for each older
   email as it comes on screen; the walk takes each thread's newest `summaryWindow`. See decision 9, "What
   the chat asks for".
   A chat request is an ordinary summary job (same model, queue, executor and write) with
   `AIJob.forChat`: it is window-exempt, any folder passes its scope checks (`readJobOutcome`,
   `executeJob`), and it is done only when the summary has its text message. `forChat` is context,
   not identity, like `windowExempt`; on dedupe the flags only widen (`admitOrUpgrade`). The chained
   action job does not inherit it, so it keeps the Inbox scope.
   **The user's own email** (amendment 2026-11-05): a summary of an email the user
   wrote, as the chat decides it (from one of the user's addresses, or in a Sent folder;
   `ActiveAIQueue.isSentByUser`), sends `is_sent_by_user: true` (`PromptVariables.summaryVariables`),
   so the backend writes its text message in the user's voice; any other email's request
   omits the field, as Thunderbird's always do. Every queue summary job carries it; the new-mail
   pipeline (`AIService.process`) is Inbox mail and keeps Thunderbird's request.
   *Amended 2026-11-07:* the last sentence was wrong. Inbox mail can be the
   user's own (a copy to themselves, or mail from another of their accounts), and the chat reuses
   whichever writer's text message is stored first. So the rule is one function,
   `PromptVariables.isSentByUser` (it replaced `ActiveAIQueue.isSentByUser`), and every summary
   writer calls it: the queue, opening an email (`AccountManager.processMessage` through
   `AIService.process`), and the notification extension (with the mirrored account addresses,
   `NSEState.getAllAccountEmails`; a pushed email is never in a Sent folder).
   **The no-forever-retry rule:** "done" is ONE predicate, `ActiveAIQueue.summaryDone`, used by every
   completion check and by both requests. A chat job whose done-condition could never become true
   would retry forever (the backoff has no cap on attempts), so: the parser keeps any non-empty text
   message, a literal "None" included (`AIResponseParser.nonEmpty`; the 2.0 backend never sends an
   empty one, `readStructuredSummary`), and the local no-content summary
   (`MessageHeader.noContentSummary`), which has no text message, counts as done.
   *Amended 2026-11-15:* a chat summary whose model call completed and wrote a summary but no
   text message (an image-only email, an invite, a backend without the 2.0 contract) is terminal
   for that job in this process. The executor puts the job in its own in-memory set,
   `ActiveAIQueue.textlessChatJobs`, and `jobCompleted` retires it (`.answeredWithoutTextMessage`,
   `abandonWithoutCompletion`). The open, the walk and the drain all skip a job in
   that set, and so do the shown chat's database observation and its re-checks (decision 9)
   (`enqueueChatSummaryJobs`, `retiredForProcess`). `rearmUnattributableJobs`, which runs
   at every sync start (launch, foreground return, every push wake, background refresh) and on
   suspension recovery, does not clear it: a sync cannot change the model's answer. The set starts
   empty in a new process, and AI re-enable (`ActiveAIQueue.aiReenabled`) empties it; nothing else
   clears it. So the bound is one model call per email per process; AI re-enable asks again. Its
   bubble reads "Summarizing" until then. Deleting the text-message requirement would leave older
   summaries without one for good, and dropping the retry would end it for a failed call too, so
   the bound is the fix (tests: `ChatSummaryExecutionTests.textlessChatSummaryIsNotAskedAgainBySyncStarts`,
   a launch and a push wake through `repopulateFromDatabase`, and
   `textlessChatSummaryIsAskedOncePerProcess`, every chat ask and AI re-enable).
   **TB parity:** a further exception to ADR-IOS-008: Thunderbird summarizes Inbox mail only.
   **Recoverable edges, decided 2026-11-05:** members awaiting their body are held in memory
   only (a relaunch forgets them; the next open or walk asks again); a member whose body arrives
   through the background backfill (not the AI-enabled body queue) is picked up by the next walk or
   open, not at once.
   *Amended 2026-11-15:* no member is held while it awaits its body; every body writer is the
   same, and the next request reads what is missing from the database. While a chat is shown, that
   request comes at once: the chat observes its rows in the database and asks when a body lands, and
   asks again after every rebuild of the queue (decision 9, "summaries follow the database while a
   chat is shown"). A relaunch or a cancel is recovered by that re-check or by the next open.
   *Amended 2026-11-09:* a chat offer is never lost to its ordinary twin. That edge was listed
   above, but it was not recoverable while the chat stayed open: a twin finished by a Device Sync
   peer's summary has no text message, so the bubble kept "Summarizing" until a later reopen. Now a
   pending twin is upgraded, a twin within the `recentlyCompleted` TTL no longer blocks the offer,
   and an in-flight twin keeps the offer (`ActiveAIQueue.chatOffersOnInFlightTwin`) until
   `jobCompleted` admits it.

9. **The chat screen (amendment 2026-11-05).** With the chat view on
   (`ChatViewConfig.isActive` = the user's Settings toggle `chatViewEnabled` (default on, kept while
   AI is off) AND AI on (not opted out, a plan or trial active)), every thread open goes through
   `MessageOpenView`, which decides chat or today's email view ONCE per open (`opensInChat`, also off
   in the demo's AI-off mode and during the tutorial): the inbox, push and notification opens
   (`MessageDetailResolvedContent`), search results and the Reminders link.
   *Amended 2026-11-15:* `MessageOpenView.route` also sends a Drafts-folder
   message to the draft editor (`DraftComposePresenter`), from every one of those paths, so a draft
   found by search opens for editing, not as an empty chat. The check had sat only in
   `MessageDetailResolvedContent`, so search and the Reminders link skipped it; that copy is
   deleted. A search result whose header no longer carries the Message-ID it found goes to the chat
   or the detail, which refuse a replaced message. The chat screen and the Reply to sheet dismiss
   the keyboard on a tap outside it (`dismissKeyboardOnTap`, the keyboard dismiss rule).
   `ChatThreadView` reuses `MessageDetailViewModel` (body, thread load, mark-read; at first also
   archive, delete and move from today's pill menus, which the reply field drops, decision 10); `ChatThread` is the pure model: drafts left out, one copy per `stableId` (the opened copy,
   else one with a text message), oldest first by (date, id), own = from one of the account addresses
   or in a Sent folder, reply people = the newest email's `buildReplyAllRecipients` minus the user,
   a group when more than one other person; time stamps after `ChatViewLayout.timeStampGap`; the
   Unread line above the first email unread at open (recorded before marking read). Each bubble opens
   the email card (today's `MessageDetailView` in a sheet). `ChatThreadContext` reads the Drafts/Sent
   folders, the label union (`UserLabel.union`, shared with `ThreadGroup.displayInfo`), top-level
   attachment names and an addable invite (`ChatInvite`; the card stands for its calendar file).
   *Amended 2026-11-16:* a bubble shows at most `ChatViewLayout.attachmentChipCount` (2) attachment
   chips, then one "+N" chip for the rest, as the header shows its names (`ChatThread.headerTitle`).
   "+N" opens the email's card, which lists every attachment. Tests: `ChatBubbleActionTests`.
   The inbox row shows the text message when the chat view is on (`MessageSnapshot.preview`).
   A bubble with no text message yet reads "Summarizing"; an email with nothing to summarize is
   done without one (`MessageHeader.noContentSummary`, which `summaryDone` counts as done), so its
   bubble shows that line instead (`ChatThread.Item.textMessage`), never a spinner that cannot end.
   The chat shows the whole thread, all the way back (decided 2026-11-06): it comes from
   `ThreadDetection.findRelatedMessages`, shared with today's thread list, which has no length or
   depth limit (decision 8).
   *Amended 2026-11-15:* opening the chat reads every row its thread loaded, not only the copy it
   shows. `ThreadDetection.related` also returns the `copies` that `excludeCopies` leaves out:
   another folder's or account's copy of a shown email, the opened one's included (a Sent copy and
   the list's echo in the Inbox, or one email delivered to two accounts). The view model keeps them
   from the same load (`MessageDetailViewModel.threadCopies`) and `ChatThreadView.noteCopies` marks
   each read by its own id, as the shown copy is. The dedupe is display only; a Message-ID never
   selects a row to change (ADR-IOS-068 D4), so a copy the thread did not load (Trash, Spam) is not
   touched. Tests: `ChatCopiesTests.openReadsEveryCopy`, `ThreadDetectionTests.copiesAreTheRowsLeftOut`.
   *Amended 2026-11-21 (#1000, #1001):* the opened email is never also one of the rows, and the
   rows are the thread of the email opened now. Both hold through the `message` setter, for every
   writer of it: when the opened id changes, the new id leaves `threadCopies` and `threadMessages`
   at once and the earlier/later split is recomputed against it
   (`MessageDetailViewModel.dropOpenedFromThreadRows`), and
   when one opened email is replaced by another the setter queues the serialized thread reload
   (`reloadThread`, FIFO behind the writer's display turn, preview-freeze buffered), which rebuilds
   the rows from the new opened email. So the email screen never shows the opened email twice,
   `chatRows` never lists a row twice, and the email opened before (another Gmail label's copy,
   which shares its provider id) is a row or a copy again after that reload whenever the thread
   load still finds it, so a whole-chat action takes it. Tests: `MessageDetailOpenedRowTests`.
   **What the chat asks for, and where it opens (decided 2026-11-09).** In the decision's words: "Just walk back
   from the recent thing until you walk through the whole thread with some cap. We already have a
   cap somewhere; it's probably good enough. If we scroll further up, we could see more summarizing
   as we scroll up." This supersedes the 2026-11-06 window below and the earlier wording
   of it. The rule:
   - On open, once the thread is loaded, the chat asks once for its newest
     `ChatViewConfig.summaryWindow` (10) emails, newest first, wherever it lands
     (`ChatThreadView.askForNewest`). *Superseded 2026-11-15* by the first value of the observation
     below; `askForNewest` is deleted.
   - An older email asks for its own summary when its row comes on screen (`askAsShown`, per-row
     `onScrollVisibilityChange`). Nothing else asks: no record of what is on screen, no settle wait,
     no hand-scroll flag. *Amended 2026-11-15:* the observation and the re-check after a queue
     rebuild ask too, and the chat keeps the ids of the rows that came on screen (`shownIds`) to know
     which rows to check. There is still no settle wait and no hand-scroll flag.
     *Amended 2026-11-16:* a row comes on screen by one rule for every height
     (`ChatRowVisibility`, per-row `onGeometryChange` against the scroll view's bounds): its visible
     part is at least `ChatViewLayout.shownShareOfRow` (half) of the row, or at least
     `ChatViewLayout.shownShareOfViewport` (half) of the chat's visible height.
     `onScrollVisibilityChange` needed half of the row, which a row taller than twice the screen
     never shows, so such a row never asked. Tests: `ChatThreadViewLifecycleTests.visibilityRule`,
     `tallRowAsksOnceScrolledInto`, `shortRowAsksAtHalf`.
   - **Summaries follow the database while a chat is shown (2026-11-15).** From its landing, while
     it is on screen, the chat observes its emails' body, summary and text message in the database
     (`ChatSummaryState`: one GRDB `ValueObservation` per shown chat, run by
     `ChatThreadView.followSummaries` in a `.task` keyed on the member ids, the landing and whether
     the chat is on screen). The scope is the newest `summaryWindow` emails plus every email that
     came on screen during this presentation (`shownIds`), newest first.
     - The first value, at the open and each time the chat is shown again after another screen
       covered it, asks for every email in scope.
     - Each later value asks for the emails in scope whose state changed. A body that lands by any
       writer (either body queue, backfill, the notification merge, a sync) gets its summary asked
       for at the front.
     - After every rebuild of the AI queue from the database (the end of `repopulateFromDatabase`
       with the chat view on: each sync start, AI re-enable, the AI redrives), the queue posts
       `.aiQueueRebuilt` and the shown chat asks for its whole scope again. It comes after the
       foreground return's cancel, so the ask it restores is not wiped by that cancel.
     - The view's sets say only which rows are checked. Whether a row still needs work is read from
       the database at every ask (`enqueueChatSummaries`, `summaryDone`); nothing is kept for a row
       that waits. A done row gets nothing, and a textless one stays retired (decision 8).
     - The fetch reads only those columns of the chat's members, so a read-state or flag write does
       not wake it, and `removeDuplicates` passes only real changes to the main actor. This is the
       one observation of `messageHeader` allowed outside small tables (memory 021): it runs only
       while a chat is shown and reads only that chat's rows.
     - A chat left on screen when the app goes to the background keeps observing, so a body that
       lands during background work asks its summary then, as the walk does at every background
       start.
     - Before this, the open asked once and a row without its body waited in the queue (below and
       decision 8); a body written by any other writer, a queue cancel, or a covered chat left the
       bubble on "Summarizing" until the chat was opened again.
   - Every request's work goes to the FRONT of both queues in the order asked, each request in front
     of the earlier ones (`QueueStorage.moveToFront`, `ActiveBodyQueue.enqueueBatch(first:)`). An
     email without its body waits in `ActiveAIQueue.chatAwaitingBody` (header id to account) and its
     job goes to the front when the body lands. There is no request numbering. *Amended 2026-11-15:*
     nothing waits (`chatAwaitingBody` is deleted); the observation asks for it once its body lands,
     and its job goes to the front.
   - The background walk takes each walked thread's newest `summaryWindow` emails, which is what
     an open asks for first.
   - The thread is the store's whole thread (`findRelatedMessages`, above), not the inbox list's
     loaded members; checked 2026-11-09.

   Where it opens: the opened email when it came from search or a notification (centered, with
   a brief glow), else the Unread line (at the top), else the bottom.
   - The list is a plain `VStack`. A `LazyVStack` starts rows at guessed heights and moves a
     `scrollTo` target while they measure (memory 036); with real heights, one `scrollTo` lands.
     Threads are short, and the AI work is bounded by what the chat asks for, not by the rows it
     builds. In a plain stack `onAppear` fires for every row at once, which is why the per-row ask
     uses `onScrollVisibilityChange` (`onGeometryChange` with `ChatRowVisibility` since 2026-11-16).
   - `defaultScrollAnchor(.bottom)` opens at the newest email. The landing `scrollTo` is issued once
     the thread is loaded, and again on every container size, content size or scroll inset change
     until the user's scroll or a jump-button tap (memory 036: a first scroll can be dropped while
     the screen settles; and the first pass shows the opened email alone, which
     `defaultScrollAnchor(.bottom)` sits at the bottom with a top inset filling the rest of the
     screen. That fill goes in the next layout pass after the landing scroll, and on that inset
     change the platform keeps the offset plus the top inset, which moves a bottom landing past the
     bottom by the fill. Main-thread stalls only widen the gap between the landing and that pass:
     3 ms in a two-email chat, 150 to 310 ms in 40-email chats behind stalls of a quarter to most of
     a second. The signed-in and ready AI Reply states add no update of their own: the AI
     Suggestion appears only once the thread and accounts have loaded (decision 16), never in the
     first pass, and a later arrival is a content size change, which re-issues the landing;
     amended 2026-11-20, mechanism measured 2026-11-21). **Amended 2026-11-18:** the landing first ended on
     a scroll of any kind; "any kind" dropped the pin on the chat's own animated or settling re-pin
     scroll, so a late height (the AI Suggestion, the reply field's measured height) left the chat
     short of the bottom. The landing now ends only on the user's scroll (`tracking`,
     `interacting`; `ChatThreadView.userTookOver`) or a jump-button tap. The first
     scroll records the members' unread state itself (`noteMembers`) before choosing where to land:
     SwiftUI runs the thread-loaded and members changes in either order, and the screen tests caught
     the chat opening at the bottom with the Unread line missing.
   - Deleted with the old rule: `ChatSummaryWindow`, the visible-set tracking, the 300 ms
     `summaryAskSettle`, the landing hold (`ChatLanding`, `landingPasses`) and the request numbering
     (`chatRequestNumber`), with their tests.
   - Tests: `ChatSummaryQueueTests` (front order, a landed body first, the walk's bound),
     `QueueStorageTests` (`moveToFront`), and `ChatThreadViewLifecycleTests`. The last opens the real
     chat in a window and pins: where it lands (bottom, Unread line, searched email); every email
     marked read; the open's request is the newest 10, newest first; any other ask is an email that
     was shown; a jump to the top asks for the top and nothing it jumped past; and
     (`aBodyThatLandsWhileTheChatIsNotLookingShowsItsSummary`, 2026-11-15) an email whose body lands
     while the chat is on screen, after a background return that cancelled and rebuilt the queue,
     while another screen covers the chat, or across a relaunch shows its summary once the chat is
     shown again.
   - No automated test fails without the landing's re-issue on the insets (2026-11-21). A hosted
     test that held the chat's thread lookup until a display frame showed the first pass's fill saw
     the fill go in the same frame as the landing, with or without the re-issue, in every run:
     nothing there stalls the main thread between the landing and the next layout pass, and a test
     can make such a stall only by blocking the main thread, so that test was dropped. A settled
     check passes either way (a later platform update sometimes clamps the offset back), and a real
     top bar that shrinks keeps the bottom by itself (memory 036). The fix rests on the debug-gated
     geometry log: without the re-issue the chat showed 488 and 386 points past its bottom, and with
     it the landing came back 2 ms after the jump. A phone check before the chat view merges to
     main is the check.

   **Superseded 2026-11-09: the chat asks for the emails in view (decided 2026-11-06).**
   In the decision's words: "add a safety bound that you load up to something like 10 emails from the current visible
   oldest message. scrolling triggers everything "in view" to be prioritized once scrolling stops,
   and then again 20 in both directions". As built: the open asked for the emails on screen and the
   10 above the oldest of them; once a hand scroll stopped, the screen and 10 each way
   (`ChatSummaryWindow`). It asked once the screen had stayed the same for 300 ms with the scroll at
   rest. A request number kept the latest screen first, and a landing hold re-scrolled until a
   settled screen showed the target. Decided 2026-11-06 on its calls: one number, 10,
   everywhere (`ChatViewConfig.summaryWindow`). It was replaced on 2026-11-09 with the simpler
   rule above; the mechanism had needed four layers to land reliably on iOS 27.
   **Decided 2026-11-05:** until the reply field (decision 10), today's pill stays and acts on the NEWEST email;
   "Sent" under every own bubble; the 15-minute gap; tutorial and demo-AI-off keep today's view; a
   reminder open highlights its email; triage rows keep the snippet, with no text message; the
   agent's toast is not shown in the chat. The User Interface Settings section, which holds the
   toggle, sits at the top of Settings.
   **The hidden release switch is deleted (decided 2026-11-05).** Until then release builds kept the
   chat view off (`isAvailableInBuild = false`; a debug-menu override turned it on while debug was
   unlocked; `isReachable` showed the toggle and moved User Interface to the top), so `main` stayed
   releasable while the chat view was built in parts. It was decided that the whole chat view is
   tested, merged and released at once, so that reason is gone and the switch, the override and the
   two Settings positions went with it.

10. **The reply field (amendment 2026-11-05).** In the chat, today's
   pill on the newest email is shown as a reply field, [mic] [field] [Send]: `DynamicIslandChat`
   with a `ChatReplyField`, so it is the same agent session (`msg:{accountId}:{stableId}`; the
   thread's `thread:{accountId}:{threadId}` since decision 14, 2026-11-16) and the
   same sheet. The field holds the ready AI Reply's text message (`ChatReplyField.readyText`: someone
   else's email, a full `cachedReply` and a `replyTextMessage`, not a no-reply sender), with an
   "AI Reply" caption while unchanged. Send with it unchanged (`ChatReplyField.route`, trimmed
   compare) opens today's Reply All compose with the full AI Reply in its suggestion box and calls no
   agent. Any other words, typed or said, go to the agent as today's Chat pill message on the newest
   email with a short nudge (`ChatReplyField.agentMessage`): they came from that email's reply field,
   so an unclear request is a reply to it; for a no-reply sender (`EmailFilter.isNoReply`, with the
   "Replies won't be read" line) the nudge says not to write a reply. While the agent works the
   words pulse in the field and the line above shows the agent's own step labels, writing a reply as
   "Writing your email" (`ChatReplyField.statusLine`). An answer or a confirmation card opens the
   sheet and empties the field, except after a compose the request opened (the compose was the
   answer). Dictation in the field replaces an unchanged AI Reply rather than appending to it, and
   the field never starts dictation by itself.
   **The AI Reply shows only while the field holds no words of the user's, and never on the user's
   turn (decided 2026-11-07):** `ChatFieldFill.offer`. An empty field, or the AI Reply the app itself
   put there, takes the ready reply whenever it arrives, collapsed or in the open sheet; typed or
   dictated words are never replaced. Three things hold it back, and nothing else (no sheet or
   timing condition): (a) the user spoke last and is still waiting, a dictation bringing their
   words or the agent answering them; (b) the user emptied the field by hand, which keeps it empty
   for that newest email (`emptiedByHand`; only the user's own edits count, and a newer email
   shows its own reply); (c) it is the user's turn: the newest email is theirs, or a reply of
   theirs is still in the outbox below it (`ChatThreadView.pill`, `unsentReplies`), from the moment
   of Send, online or offline, until someone else's email arrives. Words sent to the agent are not a
   turn: once it has answered, the email still awaits a reply, so the reply shows again. The field
   is offered the reply when the reply changes, when a dictation ends, when the agent has answered
   and whenever the field empties.
   **Each send names the email it is about, and the field's words stay out of logs (review,
   2026-11-05):** a send looks up the pill's current email as it starts
   (`DynamicIslandChat.contextNumber`), never the number found for an earlier newest email. A failed
   send from the field logs without its text (`DynamicIslandChat.loggedText`, and
   `AIService.sendChatMessage(logsUserText:)` for the request's own failure lines): the field's text
   is often the AI Reply, written from the email, and the chat error log is kept with debug logging
   off. Text typed in the chat is logged as before.
   **Superseded (review, 2026-11-06):** a resend or rewind replayed the field's words
   without that flag and logged them. The gate moved to the one writer instead:
   `BackgroundSyncLogger.logChatError` always keeps the error line and adds the user's words only
   while debug logging is on, for every caller (typed chat text included), and the flag and
   `loggedText` are deleted. Tests: `ChatReplyFieldRuntimeTests.chatRequestFailureLog` (every
   request failure branch, debug off and on) and `BackgroundSyncLoggerTests.chatErrorRoundTrip`.
   Decided 2026-11-06: typed chat text no longer reaches the production chat error
   log either (debug logging keeps it), following the rule that diagnostic logging is debug-gated.
   **The Sending bubble is read from the outbox (rebuild, 2026-11-09):** every outbox row whose
   In-Reply-To is the Message-ID of an email in the chat, from any account, and whose own email is
   not one of the chat's emails yet, shows as
   the user's bubble at the bottom (`ChatUnsentReply.fetch`, one `ValueObservation` per open chat
   keyed by the chat's Message-ID set, `ChatUnsentReply.changes`): "Not sent" with the red mark,
   Retry and Delete when the row has failed (the Outbox's own `retryOutboxMessage` and
   `discardOutboxMessageConfirmed`), "Sending" otherwise. Its text is the summary made at Send (the
   AI cache under the row's `sentMessageId` in its Sent folder), "Summarizing" until then. Once the
   provider takes the email the send stamps `sentAt`, then writes the optimistic Sent copy
   (`insertOptimisticSentHeader`) under the row's Message-ID, then may delete the row once the
   Sent append is done. The chat's list of emails is not observed (it reloads its emails on
   `.nseMergeDidCommit`; decision 9's observation, from 2026-11-15, reads only their summary
   state), so a sent row keeps its bubble until its copy is one of the chat's emails: when the copy
   is in the database (`ChatUnsentReply.filed`) or a shown row leaves the outbox, the chat reloads
   its emails (`MessageDetailViewModel.reloadThread`), the copy's
   Message-ID joins the chat's set and the bubble ends, the copy showing as an ordinary email with
   "Sent" under it. A sent row without its Message-ID cannot be handed over and shows nothing. Ending
   the bubble at the `sentAt` write, as the rebuild first did, left neither on screen until the
   next merge signal; the screen tests now hand over with no merge signal posted.
   Undo or a discard deletes the row, and the bubble goes. Nothing
   is kept in memory: the in-memory entries and their progress, the Message-ID watch across
   accounts, the gone-row rule, the 24-hour prune (`sentReplyLifetime`) and
   `ComposeOutcome.sent(outboxId:)` are deleted; a sent compose card only empties the field
   (`composeEnded`). A reply sent outside the chat to one of its emails shows the same way. An
   email that joins the open chat (a Sent copy the provider filed under a Message-ID of its own has
   no summary from Send) asks for its summary like the open's newest (`noteMembers`); a draft that
   joins, from any account, never gets one: the queue refuses it (`chatSummaryAllowed`, decision 8,
   2026-11-15).
   *Amended 2026-11-15:* `noteMembers` no longer asks. A joining email changes the chat's member
   ids, which restarts the summary observation (decision 9), and its first value asks for the
   newest emails, the joining one first. The summary at Send (`SentEmailSummary`) and the
   Message-ID at the queue write are unchanged.
   **Superseded by the rebuild (2026-11-09), kept for history:**
   **The Sending bubble follows its queued email (decided 2026-11-07):** a reply sent from
   the chat (the ready AI Reply, or an agent compose) reports its queued email's outbox row
   (`ComposeOutcome.sent(outboxId:)`), and `ChatSentReplies` follows that row and the email's AI
   cache entry with one GRDB observation. The bubble shows from the queue write, Undo window
   included: "Summarizing" until the email's summary is made, then that summary, even while still
   sending; under it the grey caption every own email has, "Sending", then "Sent" once the provider
   took it (`sentAt`). Undo or a discard deletes the unsent row and the bubble with it; a filed row
   (sent, then appended to Sent) keeps the bubble, "Sent", until the email itself, by its own
   Message-ID, is in the chat (`isInChat`, `settle`), or until no email of its account carries that
   Message-ID any more, or after `sentReplyLifetime`. Found 2026-11-07: Outlook files
   its own copy under a Message-ID of its own and the Sent sync then drops our optimistic copy, so
   with no chat on screen at that moment the bubble stayed under its own email for up to a day and
   held the user's turn; `ChatSentReplies` now follows a filed row's Message-ID and ends the bubble
   when no email carries it. Ending it at filing instead was tried and rejected: the chat reloads
   its emails only after the Sent sync commits, so the bubble would vanish a moment before the
   email shows. The summary is
   made at Send (`SentEmailSummary`, chat view on and AI allowed only): the outbox row gets its
   Message-ID at the queue write (`persistQueuedSend`; the claim keeps it and the send uses it),
   the summary is written to the AI cache under the Sent folder and that Message-ID, and the
   optimistic Sent copy (`insertOptimisticSentHeader`) and every synced copy restore it, so the
   email's own bubble shows the same summary with no second bubble. A copy that arrived before the
   summary returned takes it when it does. The reason: the words typed in the chat are not
   guaranteed to be the summary, so a real summary of the final email is the simpler, correct
   source. Outlook does not keep our Message-ID, so its server copy is summarized as it arrives;
   offline the bubble stays "Sending". **A send that failed for good (decided 2026-11-07):** it reads
   "Not sent", with a red exclamation mark beside the bubble as in Messages; touch and hold offers
   Retry and Delete (`ChatSentReplies.retry` / `delete`), which are the Outbox's own Retry and Discard
   (`AccountManager.retryOutboxMessage`, `discardOutboxMessageConfirmed`) for the same outbox row, so
   no new state: Retry queues that row again and the bubble follows it back to "Sending", and Delete
   removes the row and the bubble with it. VoiceOver reaches both as the mark's named actions. The
   words are kept nowhere; nothing new is persisted (ADR-004).
   Tests: `ChatSendingBubbleTests` (`failedSendRetryAndDelete` drives the hosted chat's own actions;
   `bubbleEndsWhateverIdTheProviderFilesUnder` sends through a provider that files its own
   Message-ID and one that keeps ours; `summaryAtSendGate` turns each input of the gate off).
   **Superseded by the above (2026-11-07), kept for history:**
   *The Sent bubble before its email arrives:* a reply sent from the chat (the ready AI Reply,
   or an agent compose asked for in the field) is kept in memory (`ChatSentReplies`, keyed by the
   account and the replied-to Message-ID) and shown as the user's words in a pending Sent bubble at
   the bottom until an own email answering that Message-ID, dated no earlier than the send minus
   `ChatViewLayout.sentReplyDateSlack`, is in the chat (`settle`), or after `sentReplyLifetime`.
   The words never go on an email: an email shows only its own text message, "Summarizing" until
   then. Found 2026-11-07: the date match had put a chat reply's words on a different
   reply sent elsewhere to the same email; nothing proves which email is which send, so the match
   now only ends the pending bubble. Decided 2026-11-07, with the summary-at-Send
   decision: the arrived email reads "Summarizing" for the few seconds until its summary, instead of
   the user's words. Nothing is persisted (ADR-004).
   **Product choices of the reply field, decided 2026-11-08:** the chat-view pill drops today's Reply
   and Archive menus (swipes are decision 12, Forward and recipients decision 11); the field-to-sheet
   change has no morph animation yet; the sheet is not sized to its content; a request that only
   acts (archive, label) opens the sheet with the agent's answer.

11. **Who gets the reply, and Forward (amendment 2026-11-05).** The
   reply is a Reply All to the newest email's people by default (`ChatReplyTarget.replyAll`).
   Tapping the header's names opens "Reply to" (`ChatReplyToSheet`): the newest email's people, all
   ticked; untick someone or add someone (today's contact search, or a typed address; never the
   user). Done with everyone ticked and nobody added stays Reply All (`ChatReplyTarget.chosen`);
   anything else replies only to the ticked people, shown as a gray "Replying only to" line of chips
   above the field (two names, then "+N"; tap for everyone). Nothing forks: the header stays the
   whole group. The chosen people become the compose card's To (Cc empty) for a reply asked for in
   the field. With recipients changed, Send on the unchanged AI Reply goes to the agent, so the
   email is written again for the people chosen (`route(recipientsChanged:)`), and the agent's
   message names them (`agentMessage(onlyTo:)`). A sent reply, or a new newest email, returns to
   Reply All. Forward is the chat's top-right button: today's forward compose for the newest email.
   **Replied only to:** an email that left out someone already in the chat (on an earlier
   email) carries who it went to (`ChatThread.Item.repliedOnlyTo`, `OnlyTo`): a gray
   "(replied only to you, David Kim +1)" after the sender's name, or "You (replied only to …)" above
   the user's own bubble; tap for the full list (`ChatPeopleList`). The user is one person whichever
   address an email used. VoiceOver reads it (`ChatBubbleView.accessibilityText`).
   **Product choices of who gets the reply, decided 2026-11-08:** an email that only adds someone new is
   not "only" (the new person joins the chat's people), and an email is never "only" for someone who
   joined after it; a new newest email resets the choice to Reply All; with recipients chosen the
   agent's own recipient changes are replaced by the chosen people on the compose card.
   **Reply All is recorded as the reply goes (2026-11-15):** the ready AI Reply and a reply asked
   for in the field open compose as Reply All (`ComposeView.isReplyAll`, which the send records on
   the original) exactly when nobody is chosen in Reply to; with people chosen they open as a plain
   reply to only them, with no Cc or Bcc. A reply the agent writes in the open sheet keeps the
   agent's recipients and opens as Reply All only when the agent opened it as one and those
   recipients are the whole Reply All audience. One helper decides the kind and the recipients
   together (`ChatReplyCompose.make`), once, as the card opens, so a newer email resetting the
   choice does not change an open card. Before this, the ready AI Reply always went to everyone and
   neither card opened as Reply All. Tests: `ChatReplyFieldTests` (`readyReplyToEveryoneIsReplyAll`,
   `readyReplyToChosenIsPlainReply`, `agentReplyFromTheFieldFollowsTheTarget`,
   `agentReplyFromTheSheetKeepsItsRecipients`).
   **Reply All only to the whole audience (2026-11-16):** a chat reply records Reply All only when
   its recipients (To, Cc and Bcc, compared case-insensitively) equal the full Reply All audience.
   This now holds for a reply the agent writes from the field with nobody chosen too: it keeps the
   agent's recipients, and when the agent left someone out or added someone it opens as a plain
   reply. Before this, such a reply opened as Reply All whatever the agent's recipients were.
   `ChatReplyCompose.make` checks the audience once for every agent reply. Test:
   `ChatReplyFieldTests.agentReplyFromTheFieldIsReplyAllOnlyToTheWholeAudience`. (History: the
   containment rule of 2026-11-16 below replaces this equal-audience rule.)
   **Reply All when the recipients contain the whole audience (2026-11-16, current):** a chat reply
   records Reply All when its recipients (To, Cc and Bcc, compared case-insensitively) contain
   everyone in the full Reply All audience, whether or not the agent added people. This matches what
   Outlook's own apps record; the kind drives the Outlook last-verb marker on the original. A reply
   that drops anyone in the audience stays a plain reply; from the open sheet the agent must also have
   opened it as a Reply All, as before. Before this, a reply the agent widened was a plain reply.
   `ChatReplyCompose.make` checks containment once for every agent reply. Tests:
   `ChatReplyFieldTests.agentReplyThatAddsPeopleIsStillReplyAll`,
   `agentReplyFromTheFieldFollowsTheTarget`, `agentReplyFromTheSheetKeepsItsRecipients`.
   **Who a field reply is for travels with its request (2026-11-16, current):** whether a reply was
   asked for in the field, and who was chosen in Reply to, are read once, as the field's send
   starts, and travel with the request (`ChatFieldReply`: `ToolInvocation.fieldReply`, stamped on
   the `ComposeRequest` by the reply tool only for a reply to the email the field replies to). The
   agent's compose card is read from its request alone (`ChatReplyCompose.make(agent:)`): with
   people chosen when it was sent, a plain reply to only them; otherwise the agent's recipients,
   under the containment rule above. The chat that shows the card decides nothing from its own state
   at that moment. Before this, the chat replaced any agent reply's recipients with its current
   choice whenever its sheet was closed as the card arrived, so a reply asked for in the open sheet
   whose sheet closed while the card waited, or a reply about another chat's email delivered to this
   chat, went only to this chat's chosen people. Tests: `ChatReplyComposeOriginTests` (a held real
   reply, the chat opened and its Reply to chosen through the sheet: `panelClosedBeforeDelivery`,
   `requestFromAnotherChat`, `fieldRequestAboutAnotherEmail`, `fieldRequestUsesItsCapturedChoice`,
   `fieldRequestToEveryoneKeepsItsRecipients`).
   *Amended 2026-11-16:* a recovered send keeps its origin and choice. The field's send is read once
   as it starts (`ChatFieldSend`: the email, the people chosen, whether the email takes replies).
   A turn cut off in transit keeps its `ChatFieldReply` beside its checkpoint
   (`ChatPillState.Session.pendingResume`, in memory only), and the resumed turn's tools get it.
   Retry after a failed send re-sends the send as it was (`Session.lastFailedSend`): from the
   field, with the same email and choice, or from the sheet; it never reads the field again. Before
   this, a resumed turn lost the field's request, so its compose card took the agent's recipients
   instead of the people chosen, and Retry re-read the field (its current choice, or a sheet send when the sheet was open). Tests:
   `ChatReplyRecoveryTests` (connection lost then resumed, and a server failure then Retry, the
   choice changed in between).

12. **Swipes in the chat (amendment 2026-11-05).** Swiping left
   anywhere between the header and the field slides the whole chat to reveal Trash, then Archive at
   the edge, so a full swipe archives; swiping right on a bubble reveals "Unread from here"
   (this email and every newer one become unread, never the user's own) or, on an unread bubble,
   "Read up to here" (this email and every older one become read), and Move for the whole chat
   as well. The Unread line then marks the emails unread (`ChatSwipe.unreadIds`). One reveal
   is open at a time (`ChatSwipeReveal`, `openId`); the pan starts only on a horizontal motion
   toward its buttons (`ChatHorizontalPan`), so vertical scrolling stays the scroll view's.
   Only a drag the user finished acts: one the system cancels or fails (a call, a system
   gesture) closes the reveal and runs nothing, however far it went (`ChatHorizontalPan.finished`,
   `ChatSwipe.settle(finished:)`; review, 2026-11-05).
   *Amended 2026-11-16 (the user-interaction freeze rule):* from the moment a swipe's pan begins
   until it has let go and settled (`ChatViewLayout.swipeSettleHold`: the spring, then the rule's
   200ms cooldown), data that lands waits: the pan drives the app's one freeze, `PreviewFreezeGate`,
   whose readers keep what lands and apply it on release (`ChatSwipeHold`, through
   `ChatHorizontalPan.handle`). A cancelled or failed pan releases the same way, and a reveal that
   goes away mid-drag releases at once. Several swipes hold it together; a preview that froze first
   keeps it. Tests: `ChatThreadViewLifecycleTests.swipeHoldsTheFreezeUntilSettled`,
   `summaryWaitsForTheSwipe` (a real summary write under a held pan, with a no-swipe control),
   `teardownLetsGo`.
   *Amended 2026-11-16:* the hold keeps state only for swipes that hold the finger or still settle:
   each settle has its own token, and an id leaves once it settles, is taken again, or lets go at
   once (every bubble that leaves the screen lets go of its id), so the state stays bounded and a
   reused id's newer swipe is never released by an earlier settle. Before, a counter per id grew
   with every bubble ever shown. Test: `swipeHoldKeepsNoStateOnceSettled`.
   VoiceOver reaches every button as a named action. *Amended 2026-11-16:* a bubble's own buttons
   and the chat's ("Archive chat", "Trash chat") are actions of the bubble itself
   (`ChatBubbleView.actions`), not of its whole row: actions on a row of several elements made
   VoiceOver read the bubble between its own attachment chips. Tests: `chipsStopAtTheCap`,
   `chatSwipeWiring`.
   *Amended 2026-11-18 (the back swipe, as Mail does it):* iOS 26 goes back on a rightward drag
   anywhere on the screen, so a bubble's swipe popped the chat. One owner, `ChatSwipeOpen`, holds
   what is open (one reveal and its frame). With nothing open, a reveal's pan takes a drag toward
   its buttons, except that a rightward drag from the screen's left edge
   (`ChatViewLayout.backSwipeEdgeWidth`) is the back swipe's (`ChatSwipe.takesDrag`); both back
   swipes wait for the pans. While a reveal is open only it takes sideways drags on itself, either
   way (further open, a full swipe, or shut), and its buttons stay tappable. Any sideways drag or
   tap anywhere else (another bubble, empty space, the reply field, the header, the navigation bar,
   the screen's edge) only closes it, through one closer, `ChatSwipeCloser`, which owns a pan and a
   tap on the navigation controller's own view (not a view over the chat, so VoiceOver and every
   control see the chat as before). A vertical drag while a swipe is open, anywhere (on the open
   reveal too), both scrolls the chat and closes the open swipe, as in Mail. The closer takes a
   touch only while something is open; a sideways drag is the open reveal's only inside its frame,
   a tap only on its buttons (a tap on a bubble while anything is open only closes), and only
   between the header and the reply field, so the header, the reply field and the navigation bar
   are never the open reveal's, though the chat's scroll view runs under them. Every frame and the
   touch are measured in one space by construction: the chat's named coordinate space
   (`ChatSwipeOpen.space`), which the closer's anchor fills and reads the touch in. The screen's
   recognizers on that touch wait for the closer (the bubbles' taps and swipes, the reply field,
   the bar's buttons, both back swipes); the scroll views' pans run alongside its drag, which is
   how a vertical drag also scrolls; and the window's own recognizers run alongside it too, so the
   window-level keyboard-dismiss tap (`dismissKeyboardOnTap`) drops the keyboard on the same tap
   that closes a swipe: the keyboard rule holds with no exception, through its one dismiss path
   (review, 2026-11-18). *Amended 2026-11-19:* the dismiss tap's own delegate also runs it alongside
   every recognizer (`KeyboardDismissView`), because a SwiftUI gesture on the tapped bubble shut it out
   at touch down before the closer could; test: `testOpenActionsTapOnAnotherBubbleClosesAndDropsTheKeyboard`.
   The screen-edge back swipe is off while something is open. The next drag
   goes back. A closing drag or tap holds the interaction freeze like any swipe, and lets go when
   the system cancels or fails it or the closer is torn down. A swipe runs alone (no
   simultaneous recognizer), so a swipe never also opens the bubble's card. An open reveal whose
   view leaves the chat (its email moved away by a sync) is no longer open, so the next swipe works
   (ios#1004). Tests: `ChatSwipeUITests` (real drags: the four open states, the edge, close then
   back, the reply field, the header and the navigation bar with a bubble or the chat open, a tap
   on the reply field, on Forward and on a bubble, the open bubble's own Move, the chat inside a
   presented sheet and opened from a mailbox through a collapsed split view's
   `PushedMessageDestination`, left drags, a vertical drag that scrolls and closes, a closing tap
   that drops the keyboard, the email leaving), `nothingOpen`, `onlyTheOpenRevealTakesDrags`,
   `openState`, `openRevealOnlyWhereATouchReachesIt`,
   `closerTakesOnlyTouchesOutsideTheOpenReveal`, `closerTakesEveryDragButTheOpenRevealsOwn`,
   `closerBeatsOnlyTheScreensRecognizers`, `closerCoversTheWholeScreen`,
   `backSwipesWaitForTheRule`, `closingHoldsTheFreeze`.
   Archive, Trash and Move act on every email the
   chat shows, wherever it is filed ("always the whole thread", 2026-11-04), except the user's sent
   copies and drafts, which stay in their folders, and emails already at the destination
   (`MessageDetailViewModel.archiveChat` / `deleteChat` / `moveChat`), and close the chat as closing
   the email does today. **Amended in review (2026-11-06):** they first took only
   the opened email's folder, which left the chat's archived and filed emails behind. One Undo puts
   each email back in its own folder: `UndoableAction` keeps one command per source folder and epoch,
   because `AccountManager.undoMove` moves a command back to one source; this also fixes Undo of an
   inbox thread whose emails sat in different folders. They are ONE action each: the detail view model's
   `archiveMessages` / `deleteMessages` / `moveMessages` push one undo entry and queue one move for
   every email (`recordMove`, one `enqueueMove` closure with the read op before the move); the
   single-email `archiveMessage` / `deleteMessage` / `moveMessage` are now the one-email case of
   these. Grouping a move by account and building its one undo entry is one shared helper
   (`UndoableAction.byAccount`, `UndoableAction.move`; rebuild 2026-11-09), used by the
   chat here and by the inbox's thread actions. `setRead` sets each email's read state through today's gesture intent. In the inbox, Read
   on a collapsed chat reads every email in it when the chat view is on (`ChatSwipe.inboxReadIds`,
   as opening it does); Unread stays on the newest email.
   **Product choices of the swipes:** Unread from here skips the user's own emails. Decided
   2026-11-15. A bubble has no full swipe: this follows the 2026-11-04 swipe rules.
   **Decided 2026-11-06:** a whole-chat action leaves the user's sent copies and
   drafts where they are (a draft must stay in Drafts to stay editable; on Gmail a sent copy is the
   same email as its other labels).
   *Amended 2026-11-15:* the button that moves the chat to Trash says "Trash", the inbox
   row's word, on screen and as its VoiceOver action ("Trash chat"); it first said "Delete", as the
   mock did.
   *Amended 2026-11-15:* a whole-chat Archive, Trash or Move acts on every row the chat loaded
   (`MessageDetailViewModel.chatRows`: the opened email, the thread's emails and their copies in
   other folders and accounts, decision 9), each by its own id through the same one move and one
   undo entry, so no copy of a chat email is left in an Inbox. Sent copies and drafts are still
   left where they are, per copy. The action set is that snapshot, never a lookup by Message-ID at
   action or drain time (ADR-IOS-068 D4): a copy the thread did not load (Spam), or one that arrived
   after the chat loaded, is not moved. Test: `ChatCopiesTests.wholeChatActionMovesEveryCopy`.
   *Amended 2026-11-15:* which rows of that snapshot each action takes is decided per row from its
   folder (`MessageDetailViewModel.ChatMoveSource`). Archive takes the Inbox copies (role `.inbox`, in
   every account). Move takes the copies in the folder the chat was opened from: a system folder by
   its role, in every account; a user folder, a Gmail label included, by its own folder id. Trash
   takes every row. Sent copies, drafts and rows already at the destination are still left where
   they are. A copy filed or labeled elsewhere therefore stays where it is: on Gmail, archiving the
   Inbox copy removes only the INBOX label, so the message keeps its other labels; on IMAP and
   Outlook a filed copy is a separate message and stays in its folder. This replaces "every row the
   chat loaded" above for Archive and Move. The role only decides which rows qualify; each row is
   still moved by its own id (ADR-IOS-068 D4 and clause 6), and nothing above `EmailProvider`
   checks the provider. A chat with no Inbox copy (opened from a label, Archive or search) offers
   no Archive: no swipe button, no "Archive chat" VoiceOver action, and no full swipe
   (`MessageDetailViewModel.chatHasInboxCopy`, `ChatSwipeReveal(allowsFullSwipe:)`), so the gesture
   that archives elsewhere never trashes there. The actions return the ids they moved, and the
   list behind is told to hide the opened row only if it moved (`ChatThreadView.dismissChat`):
   archiving a chat opened on a label leaves that row in the label's list. Tests:
   `ChatCopiesTests.wholeChatArchiveLeavesFiledCopies`, `chatWithNoInboxCopyOffersNoArchive`,
   `archiveFromALabelKeepsTheListRow`, `wholeChatActionMovesEveryCopy`;
   `MessageDetailThreadActionTests.moveChatTakesTheOpenedFolder`, `archiveChatAcrossFolders`.
   *Amended 2026-11-16:* the roles are read once for the action (`lookupFolderRoles`) and fail
   closed. A row whose folder role cannot be read (no Folder row) may be a sent copy or a draft, so
   it stays where it is; if the read fails, nothing moves. A Move opened from a folder whose role
   cannot be read moves nothing, since that folder is not known to be a user folder. Before, an
   unknown role passed the sent and draft check, so Trash took such a row, and an unknown opened
   folder was moved as a user folder. Tests: `MessageDetailThreadActionTests.unknownRoleFailsClosed`,
   `systemFoldersByRoleAcrossAccounts`, `sameNamedFolderInAnotherAccountStays`.
   *Amended 2026-11-15:* "Unread from here" and "Read up to here" change, with each email they
   target, its copies from the same snapshot (`MessageDetailViewModel.setRead`: the
   `threadCopies` rows that `excludeCopies` left out under that email's Message-ID), each by its
   own id, as the open reads them (decision 9). A copy the thread did not load keeps its state
   (ADR-IOS-068 D4). Test: `ChatCopiesTests.readSwipesChangeEveryCopy`.

13. **The tutorial in the chat view (amendment 2026-11-05).** A
   tutorial run teaches the view it starts in: with Chat View on and AI not opted out
   (`TutorialCoordinator.chatViewOnForTutorial`), `start` snapshots `teachesChat = true` and the run
   keeps it whatever the setting does meanwhile; with Chat View off or AI opted out the run is today's,
   unchanged. `ChatViewConfig.opensInChat` follows the run (`tutorialRunning ? tutorialTeachesChat :
   …`), so a chat-view run's emails open as chats and today's run keeps today's view. Part 2 opens
   Priya's email as a chat with everyone on the thread (the demo seeds Sam Lee's earlier email in the
   same thread, and Jordan's trip thread with the user's own Sent reply; every seeded email has its
   text message, every seeded AI Reply its reply text message). The reply field holds the AI Reply,
   prefilled and read-only (`TutorialChatInputBar` with the "AI Reply" label, `FieldMove.sendReadyReply`);
   Send opens today's compose, whose draft-chat edit is "Make it shorter", so the Sent bubble stays a
   yes (`TutorialChatScript.shorterReply`). After it is sent, the same field asks "Save my reply as a
   template." (`FieldMove.ask(.saveReplyAsTemplate)`, "Saving template" for a moment), which shows the
   real Create card for "Event RSVP: yes"; the inbox chat offers no template prompt in this run. Part 3
   asks the flights question in the inbox chat as today; the email reference opens Jordan's chat at his
   email, where the step's card says so (`chatShowsCard`). A last step (`Step.chatViewSwitch`, after
   the recap's Finish) shows TabMail Settings' Chat View switch, ringed, in a sheet
   (`TutorialChatViewSwitchSheet`, `ChatViewToggleRow`, shared with Settings); flipping it switches for
   real, and only the card's Finish closes it. The welcome and recap screens name the chat view's reply
   and the switch. Inside the chat, Forward, Reply to, Move, the read swipes, Archive and Trash ask the
   tutorial first (`admits(.other)`), as every mail action does in the tutorial. Outside the tutorial:
   the inbox's Reply tag opens the email's chat when the chat view is on (`executeTaggedAction`
   `.reply`), and an email opened from a chat's email reference highlights its referenced text as a
   message opened from the agent does (`PushedMessageDestination`, `highlightsMessage: true`).
   **Product choices of the tutorial (decided 2026-11-05):** today's
   tutorial still runs with Chat View off or AI opted out; the switch step is a sheet holding only the
   switch; the edit is "Make it shorter"; the template is "Event RSVP: yes"; compose keeps its Use
   Suggestion step; no attachment chip is seeded for the agenda; the Reply tag opens the chat in
   general, not only in the tutorial.

14. **One TabMail chat per thread (amendment 2026-11-16).** An email's TabMail chat belongs to its
   thread, with the chat view on or off. Decided 2026-11-16: "per-mail chat sessions now should be
   per-thread chat sessions, which is fine even when chat view is off", with "a simple migration +
   going forward identity using threads not individual messages".
   - **Identity.** The session key is `thread:<accountId>:<threadId>` (`ChatThreadKey`), the thread id
     being the one the inbox groups by: `computedThreadId`, or the header id when it is empty. A demo
     keeps its `demo:` scope (`DemoModeStore.scopedSessionId`). The in-process session
     (`ChatPillState.session(for:)`) is keyed by the bare thread key; the agent dot on an inbox row
     (`MessageRowBackgroundModifier`), the row glow and the agent toast (`AgentToastDestination.thread`,
     which opens the thread's newest email, `ChatThreadKey.newestMessageId`) read the same key. The
     per-email key `msg:<accountId>:<stableId>`, `ActiveAgentTracker.messageStableId`,
     `isMessageWorking`, `ChatStore.isMessageInInbox` and `InboxView.resolveMessageIdByStableId` are
     deleted.
   - **The newest email is the context, everywhere.** Decided 2026-11-16: "for the chat in the chat
     view, it is ALWAYS regarding the most recent email in context", and for the email screen's Chat
     pill: "the context email that gets sent in the request still should be the most latest email ...
     in the thread ... since that's most useful. And even if that changes due to timing issues, that's
     fine and not a problem. Since it will just be as if we were interrupted mid-discussion and the
     next message will be properly contexted. The message on top should thus be the most recent
     message." So every request, from the chat view or from the email screen's pill while an older
     email is on screen, names the thread's newest email (`MessageDetailViewModel.chatNewest`: the
     chat view's `ChatThread.newest` rule, drafts left out, latest by date then id), and its turns are
     written under that email's current thread key. The pill's top card shows the newest email. A
     request already running when a newer email lands finishes with the context it was sent with;
     nothing else is done about it. The email screen keeps the email the user picked
     (`chatContextMessage`) for its own bottom-bar actions. The chat view's panel card is unchanged.
     *Amended 2026-11-16:* the newest email is the context in the chat view only. The email
     screen's Chat pill is about the email that is open, as before the thread chat: its requests
     name that email (`chatContextMessage`, else the screen's email), its top card shows it, and its
     turns are written under that email's current thread key, so the thread's chat is still one
     chat, read whole by `ThreadChatReader`. `MessageDetailViewModel.chatNewest` is deleted. Tests:
     `ThreadChatTests.emailScreenUsesTheOpenEmail`, `chatViewUsesTheNewestEmail`.
   - **One reader** (`ThreadChatReader`), for what the pill shows and for the history a request sends,
     on both surfaces. Its keys are the own key of the email the chat is about (the chat view's
     newest, the email screen's open one, 2026-11-16) and those of every other email of the
     thread on the device (`ThreadDetection.related`, every account, copies included), so a copy in
     another account or two threads a newer email joins read as one chat with no re-keying. It merges
     their turns by time (a stable k-way merge, so a session's own order is kept), shows each key's
     live confirmation card in place (the card stays in the session that raised it, where its request
     is waiting), and sends the newest turns within `ChatStore.maxExchanges` exchanges and
     `maxExchanges * charsPerExchange` characters. An inbox chat still sends its own session's turns.
     The re-send and rewind menu acts on the shown session's own turns only.
   - **Email pills stay resolvable.** The `ChatIdTranslator` mapping is global and a move remaps it
     (`ChatIdTranslator.remapRealId`, called by the move's effects in `AccountManagerOperationEffects`), so every `[Email](N)` in a merged chat, whichever email's chat it
     was written in, still resolves. The per-email remap on open is deleted: the translator already
     follows moves, and a merged chat has no single email to remap to.
   - **Clearing old chats** (`ChatStore.evictMessageDetailSessions`) counts threads: a thread chat is
     kept, uncounted, while any email of its account and thread is in the Inbox
     (`ChatStore.isThreadInInbox`, `ChatThreadKey.memberSQL`, one index search). A leftover `msg:`
     chat (one the migration found no email for) has no Inbox email and is counted and cleared as it
     was before. Inbox chats
     (`inboxSessionScopeSQL`, which keeps `thread:` and leftover `msg:` keys out) and compose chats are
     unchanged.
   - **Migration `v107_rekeyChatSessionsByThread`.** One set-based statement per turn table
     (`chatTurn`, `chatHistory`, `AppDatabase.rekeyChatSessionsByThreadSQL`) moves every `msg:` and
     `demo:msg:` session to its email's thread key, finding the email as the app found it
     (`MessageHeader.stableId`: a UID `messageId` with a Message-ID by the Message-ID, otherwise by
     `messageId`; account-scoped; Inbox copy first, then lowest id). Two emails of one thread end
     under one key in time order. A chat whose email is not on the device keeps its key and stays as
     it was; no cap is added. Turn ids do not change, so memory index entries (`memory_meta`) still
     name their turns. Each email lookup is a hinted index search (`messageHeader_rfc822MessageId`,
     `messageHeader_accountId_messageId`), with or without planner statistics.
   - **No write changes a thread id under a chat; a fence keeps it so (2026-11-16).** The one write
     of `computedThreadId` to an existing email is the fragment merge
     (`ThreadUtils.runFragmentMergeOnce`), and its only caller is `v54`, which runs before `v107`
     creates thread keys, so it never strands a chat and no chat-moving code exists.
     `ThreadIdWriteFenceTests` fails any caller of the merge other than a migration registered
     before v107, and any other write of `computedThreadId` to an existing row (a migration from
     v107 on included); its message says the new caller must move the thread chats to their new key.
   - **Tests:** `ThreadChatTests` (a card raised for an earlier email answered after a newer one
     lands, also across accounts; a newer email's question carries the earlier exchange; the email
     screen on an older email shows the thread's chat with the open email's card and context
     (`emailScreenUsesTheOpenEmail`), the chat view the newest email's (`chatViewUsesTheNewestEmail`); two joined
     threads; the upgrade; eviction keeps a thread with an Inbox email; inbox chats unchanged; through
     the pill's Send and the production reader, the history of a chat stored under two keys,
     interleaved and over the budget by turns and by characters, is in time order with equal times
     the newest email's key first and keeps the newest turns that fit,
     `historyAcrossKeysIsChronologicalAndBudgeted`; a live card keeps its place, `liveCardKeepsItsPlace`),
     `ThreadIdWriteFenceTests` (the fragment merge's callers and the write sites of
     `computedThreadId`, with planted violations),
     `ThreadChatKeyTests` (key round trip, reader keys, merge, budget, migration key equals the runtime
     key, migration plan and time, thread-in-Inbox plan, toast).

**Release order:** an iOS build at protocol 2.0.0 must not reach users before the backend change
(its protocol 2.0.0 JSON shape) is deployed to production: an older backend sends 2.0.0 the labelled text, which this
parser does not read.

**Tests:** `AISummaryParsingTests`, `AISummaryResponseTests`, `AIReplyParseTests`, `AIReplyTests`
(parsers and `ReplyResult`); `AICachePurgeTests` (the orphan purge, driven for real, including
`legacyEntryWithoutMessageIdPurged`, `entryKeptOnlyByItsOwnAccount`, `maintenanceRunsThePurge` and `clockOffWallClockEnds`, the clock behind and ahead of the wall clock);
`ComposeSuggestionPersistTests.editClearsReplyTextMessage`; the migration and merge tests;
`AITextMessageCallerTests` (the queue's summary and reply jobs, a failed reply asked again and the next
one stored (`queueReplyFailureRecovers`), the "no content" summary clearing the text message
(`noContentClearsTextMessage`, `confirmedEmptyClearsTextMessage`), the opened-email direct path in full and
reply-only, a peer result through both, a whole queue job adopting a peer's action while keeping this
device's summary and reply text messages (`queuePeerActionKeepsLocalPairs`), compose's recompute
(`ComposeView.recomputedReply`) and its refusal to store on a replacement email at the same address
(`composeRecomputeReplacedEmail`), a filtered recompute and one from the snippet
(`composeRecomputeFiltered`, `composeRecomputeFromSnippet`), and the extension's request, each through its real producer and a
fake backend or peer); `AITextMessageStorageTests.upgradeKeepsResults` (a v94 database with results,
upgraded) and `legacyEntriesSurviveUpgradeAndPurge` (the purge keeps only the entries v106 filled; including v106 filling the Message-ID that a peer's
probe then finds); `RFC822IdentityMergeGuardTests.preSyncInboxReclaimCarriesTextMessages`;
`NSESummaryTextMessageCarryTests` (the staging writes, `NSEStagingDB.open(path:)` upgrading an older
file, the extension bundle's protocol version, a later push whose only change is the text message,
including to none (`sameSummaryNewTextMessage`), the merge's second stage creating a header the first
stage could not and caching its result with the text message (`secondStageCachesTextMessage`), a merged
cache entry kept through the orphan grace (`mergedCacheEntryGetsTheGrace`), and a push through `NotificationService.didReceive`
staging the text message, via `NotificationService.stagingPathOverride`).
Decision 8: `ChatSummaryQueueTests` (including a chat offer made while its ordinary twin is in flight, just after it ended, or when it runs again, and the foreground pass's walk, two-sided on the chat view; the walk leaving drafts out of its window (`walkLeavesDraftsOut`), looking a thread up once (`walkLooksEachThreadUpOnce`, statements counted) and losing no email to that (`walkLosesNoEmailOfAThread`); the draft gate for every caller (`draftGateRefusesEveryCaller`)); `ChatSummaryExecutionTests` (the own-email field, two-sided; the executor refusing an ordinary summary outside the Inbox, with an Inbox control, and a chat summary of a draft, with a Sent control (`chatSummaryRefusesADraft`)). Decision 9: `ChatThreadTests`,
`ChatThreadContextTests` (including `draftOpensInTheDraftEditor`, `everyOpenPathRoutesDrafts` and `chatDismissesTheKeyboardOnTap`), `ChatThreadViewLifecycleTests`, `ChatCardIdentityTests`, `ChatSummaryQueueTests.chatViewSwitch`/`activeMatrix`, `ThreadGroupTests.displayInfoUnionLabels`.
Decision 10: `ChatReplyFieldTests` (the ready text, Send's route, the agent's message, the status
line, and the field and chat wiring read from the source),
`ChatReplyFieldRuntimeTests` (the ready AI Reply in the mounted field, the send's email lookup,
a failed request's log with and without its text, and the send wiring),
`ChatSendingBubbleTests` (`whichRowsShow`, the hosted hand-over and Retry/Delete, the summary at
Send and its gate), `ChatThreadViewLifecycleTests.aJoiningEmailAsks`, `aJoiningDraftDoesNotAsk`, `aJoiningDraftFromAnotherAccountDoesNotAsk`,
`newestBubbleClearsATallField` and `sentReplyTakesTheTurn`.
Decision 11: `ChatThreadTests.repliedOnlyTo`,
`someoneNewIsNotOnly`, `userIsOnePerson`; `ChatReplyFieldTests` (`changedRecipientsRoute`,
`agentMessageOnlyTo`, `replyTarget`, `replyToChoice`, `accessibilityOnlyTo`, `recipientsWiring`);
`ChatReplyComposeOriginTests` (who gets the agent's reply, by where its request came from).
Decision 12: `ChatSwipeTests` (the read swipes' targets, the Unread line after them, the whole-chat
members, the inbox's Read, letting go, an interrupted drag running nothing, and the drag limits, and the swipe wiring read from the
source); `MessageDetailThreadActionTests` (a chat's Archive, Trash and Move as one undo entry and
one queued move, one undo restoring every email, one undo command per source folder and epoch
(`archiveChatUndoSplitsByEpoch`), the no-ops, `setRead`); `UndoableActionAccountMoveTests`
(the shared by-account grouping and its one undo entry); the single-email detail
actions stay pinned by `MessageDetailViewModelMoveTests`, `MessageDetailMarkReadOnArchiveDeleteTests`,
`SameFolderNoOpTests` and `MessageDetailStagedFallbackTests`, green before and after the refactor.
Decision 13: `TutorialChatViewContentTests` (each step's card where it happens, compose's order, the
progress lines and titles, Send only on screens that have it, the field's moves, the inbox chat's
prompts and working status, where a chat shows the card, the edit staying a yes);
`TutorialChatViewSeedTests` (the request shows the Create card without reaching the model, the seeded
chats and inbox groups, every seeded email's text message); `TutorialChatViewRunTests` (a chat-view run
from Part 2 to the switch with the setting flipped mid-run, and today's run with Chat View off or AI
opted out); `ChatThreadContextTests.opensInChat`; the tutorial locks in the chat read from the source
by `ChatSwipeTests.bubbleSwipeWiring` and `ChatReplyFieldTests.recipientsWiring`.

15. **Where the field and the header sit (amendment 2026-11-17).** The chat is laid out as Messages
   is. The reply field's bottom edge sits `ChatViewLayout.fieldBottomGap` (8 pt) above the bottom
   safe-area line, collapsed or opened, with `ChatViewLayout.fieldSideInset` (16 pt, measured in
   Messages) on each side. The safe area already clears the home indicator, so nothing else is
   added; the 34 pt the pill used to add counted it twice. The inbox and email-screen pills keep
   theirs. The header (`ChatHeaderView`, the avatars and the names that open "Reply to") is the
   navigation bar's principal item, level with Back; the subject and labels are one thin line under
   the bar (`ChatSubjectLine`), with no band of their own: they sit in the chat's top
   `safeAreaBar`, not a plain `safeAreaInset`, so the navigation bar's scroll-edge backdrop reaches
   under them and the chat scrolls under the whole header instead of drawing through the subject,
   with `ChatViewLayout.subjectLineBottomGap` under the line. The chat screen never hides its
   navigation bar, even while the opened pill has focus, since the bar holds who the chat is with;
   the inbox and the email screen keep hiding theirs then. Tests: `ChatThreadLayoutTests` (the
   hosted chat's measured field position, the opened pill between the bar and the safe area at the
   largest text size, the header inside the bar and the subject under it, and the scroll area
   clearing the subject and its gap at sampled scroll positions),
   `TutorialChatViewRunTests.chatCardHoldsItsRoom` (no bubble under the coach card in the bar, nor under the subject once it goes) and
   `ChatReplyFieldTests.messagesLayout` (the top bar, never a plain top inset).

16. **The AI Suggestion as a ghost bubble (amendment 2026-11-18; supersedes the parts of decisions
   10 and 13 that put the ready reply in the field).** The ready reply no longer sits in the reply
   field. It shows as a ghost of the user's next message, where the reply lands once sent (after the
   last email and any outbox bubble): `ChatSuggestionBubble`, drawn as a filled bubble, not a clear one: a dashed 1.5 pt accent outline (75% light, 85% dark) on a faded accent fill (14%
   light, 22% dark) with dark-blue text (`Palette.chatSuggestionStroke`, `chatSuggestionFill`,
   `chatSuggestionText`; `ChatViewLayout.suggestionStrokeWidth`, `suggestionDash`), with "AI
   Suggestion · Tap to use" under it. The name is "AI Suggestion", the one compose's suggestion box
   uses (`ChatSuggestionConfig.label`); "AI Reply" is gone from the chat view's strings. Its text is
   the reply's text message, read from the email's row (`ChatReplyField.suggestionText`), so a new
   text message there rewrites the ghost in place, with no second copy. None shows on the user's
   turn, for a no-reply sender, or while the reply goes only to people chosen in Reply to (the
   suggestion was written for everyone; the field has the agent write one for them).
   - **Tap** (the bubble or its caption, one button): opens today's Reply All compose card with the
     full reply in its suggestion box, as Send did (`ChatThreadView.openSuggestion`,
     `ChatReplyCompose.make(replyAllTo:)`); Send there sends and the Sent bubble replaces the ghost,
     and the field's words stay (the card is not a send from the field); Close goes back with the
     ghost still there. An edit or a Recompute in the card that is stored on the row posts
     `.messageDataDidChange`, so the ghost under the card follows it. How a thread reload
     is ordered against such a refresh (a reload that read its rows before the change and finishes
     after it puts the older row back, #992) is not decided here: it is superseded by "one display
     read at a time", fixed on its own (ADR-IOS-049's #992 amendment, `MessageDetailViewModel.inDisplayTurn`). The card saves to a draft of its own
     (`Draft.separateReplyKey`, the parent in its tail as a reply key's): the chat ignores saved
     drafts, so a reply draft already saved for the email stays as it is in Drafts, never opened,
     saved over or deleted by the card; each card has its own key, so two cards' drafts never
     overwrite each other. The ghost shows only once the thread and the email's own account have
     loaded, and not while the agent works on a request from the field. In the tutorial only the step that asks for it
     (`FieldMove.tapSuggestion`, ringed by `TutorialPulseRing`) opens the card; elsewhere the
     locked notice shows.
   - **The field** holds only the user's words (`ChatFieldFill`: `shown`, `emptiedOn` and
     `ChatReplyField.route` removed): "Reply or ask anything", and under the empty field an "e.g."
     line with one change from `ChatSuggestionConfig.replyExamples`, picked at random once per chat
     open (`ChatThreadView.example`). A tap puts the change in the field (`DynamicIslandChat.putExample`)
     and never sends it. Every Send from the field goes to the agent. When the compose prompt
     returns its own suggested change with each draft, the line will show that one while a
     suggestion shows; until then it always shows the config example.
   - **Tried and reverted (2026-11-20): holding the card's bubble until the card is on screen.**
     Following an owner ruling that the bubble must never animate in while the compose card slides
     in, ComposeView briefly held the bubble's insertion until a zero-size child controller saw
     `viewDidAppear`. It was reverted. In the hosted chat test that "appeared" signal fired while the
     full-screen cover's transition was still running (`isBeingPresented` and a transition
     coordinator were both still set), so it was not a "presentation finished" signal. The saved-draft
     test's missing card body, which motivated the hold, was not a timing issue either: with the
     bubble inserted only after the signal, the card's scroll content (bubble and editor) was still absent from the hosted view tree. The question moved to a UI test in the
     running app (`ChatSwipeUITests`).
     The hosted harness intermittently leaves the card's bubble and editor out of the accessibility
     tree, so the card's body content is checked only in XCUITest
     (`ChatSwipeUITests.testSavedDraftGhostCardShowsTheSuggestionAndUseSuggestionFillsTheBody`).
     **Superseded 2026-11-21:** the text above is not a harness limit. The cause is the compose
     scroll view's class swap (`DisableAutoScrollToVisible`'s `object_setClass`), tabmail-ios#1124,
     and it hides the AI Suggestion box, Dismiss and Use Suggestion from accessibility in the running
     app too. Until #1124 is fixed the UI test holds those queries under a strict
     `XCTExpectFailure`, and the card's transitions are pinned by hosted model-entry-point tests
     (`ComposeSuggestionPersistTests.useSuggestionFillsTheBody`,
     `cardShowsTheTappedSuggestionNotTheRowsLaterReply`,
     `cardSaveWritesItsOwnDraftAndLeavesTheSavedOneAlone`).
     The owner ruling that the bubble must never animate in while the compose card slides in is
     still unmet after the revert; it remains open.
   Tests: `ChatSuggestionBubbleTests` (the ghost, its tap opening the card, the in-place rewrite,
   no "AI Reply" string), `ChatSwipeUITests.testSavedDraftGhostCardShowsTheSuggestionAndUseSuggestionFillsTheBody`
   (the card's body, Use Suggestion, the saved draft left in Drafts), `ChatThreadViewLifecycleTests.suggestionSitsAtTheSentPosition` and
   `sentReplyTakesTheTurn`, `ChatReplyFieldRuntimeTests.exampleLinePutsTheChange` and
   `suggestionNeverEntersTheField`, `ChatReplyFieldTests.suggestionText` and `exampleFromConfig`,
   `TutorialChatViewTests.fieldText`.

   **Amended 2026-11-20 (the working bubble):** while the suggestion is written its row is the
   working bubble, `ChatSuggestionWorkingBubble` (the ghost's dashed bubble with three pulsing dots,
   "AI Suggestion · Writing", identifier `chat.aiSuggestion.writing`; the ghost keeps
   `chat.aiSuggestion`), always the last chat row above the field. "Being written" is the inbox
   row's "AI is working" rule under the ghost's own guards (`ChatReplyField.suggestionPhase`). The phase is keyed by the newest email, so
   a new email that arrives above a ready ghost puts the row back to Writing at once. Only Writing to
   ready animates (`ChatSuggestionPhase.fills`): the row grows into the ghost over
   `ChatSuggestionConfig.fillDuration` (0.3 s) with the landing's re-pin `scrollTo` in the same
   `withAnimation` (`ChatThreadView.showSuggestion`); under Reduce Motion the height changes at once
   and the ghost fades in (`ghostFadeDuration`, 0.2 s), as the mock's M2. A ghost with no working
   bubble before it still shows at once: the working bubble is held only while a grow is pending, so
   opening on a ready suggestion never shows it, and the ghost's removal always follows its
   transaction. The dots cap at 30 fps. The arrival rise of the new email is not built here (it is decision 21).
   On an arrival in a landed chat (decision 21) the swap back to Writing rides the arrival's rise
   (at once under Reduce Motion); the fill and its re-pin stay their own, on Writing to ready.

   **Writing rule (2026-11-20):** Writing shows when the newest email meets the inbox row's one shared
   predicate, `AIWorkingRule` (tagged with no reply processed, or untagged in the Inbox with an AI
   source on), which `MessageRowView` calls too; a filtered email's empty-reply sentinel never writes.
   Tests: `ChatReplyFieldTests.suggestionPhaseWritingThenReady`, `suggestionPhaseNewEmailResetsToWriting`,
   `workingDots`, `suggestionPhaseWritingRule`, `suggestionFillWiring`;
   `ChatSwipeUITests.testWorkingBubbleBecomesTheGhostAboveTheField`.

17. **The field, compact (amendment 2026-11-20).** Every open field bar (the chat's reply field,
   the opened pill's input bar in the inbox, over a draft and on an email, and the tutorial's
   copy) draws one row, `ChatFieldBarRow`, with the `ChatViewLayout.field*` values: the mic glyph
   12 pt in from the field's edge, 10 pt from glyph to text, the 28 pt Send circle 6 pt in, 10 pt
   above and below the text. The buttons sit on the text's LAST line, not its middle, and stay
   there as the field grows; each lays out at its glyph's width and one line's height while its
   tap area stays 44 pt tall and may reach past the field's edge. One line is 42 pt, the collapsed
   field's corner `min(height / 2, 21)`. The collapsed Chat pill keeps its size. The line height
   scales with the text size (`@ScaledMetric`), so at the largest sizes the buttons still centre
   on the last line. The Stop and Retry glyphs keep their size. Tests:
   `ChatThreadLayoutTests.fieldButtonsOnTheLastLine` and `signedInEmptyField` (the "e.g." line is
   the last line, as in the option-B drawing), `ChatReplyFieldTests.everyOpenBarSharesTheRow`,
   `statusLinePadding` and `tutorialArrowOnTheMic`.

18. **The field is the chat's bottom bar (amendment 2026-11-20).** The reply field is the scroll
   view's `.safeAreaBar(edge: .bottom, spacing: 0)`, as the header is its top bar (decision 15), so
   the chat scrolls under it and the system blurs the strip below it, as in Messages; no field
   floats over the chat in a `ZStack` any more. There is one field, always in the bar: the bar is a
   slot of the collapsed field's measured height, and the opened pill grows upward out of it as an
   overlay, so the bar's inset, and the chat under the panel, do not move when it opens. The field
   keeps its 8 pt above the safe-area line (or the keyboard) inside the bar. The last row keeps only
   `pillGap` (the inset keeps the field's room), and the landing is issued again when the bottom
   inset changes (the field's height and the keyboard arrive as that inset). Tests:
   `ChatThreadLayoutTests.chatScrollsBehindTheField` and `openingThePillKeepsTheChat`,
   `ChatReplyFieldTests.messagesLayout` (the bottom bar, no plain bottom inset).

19. **Drag the field up to open the TabMail chat (amendment 2026-11-20).** Until now the panel
   opened only on an agent answer, a confirmation card or `.openMessageWithChat`. A drag up on the
   collapsed reply field now opens it too, and the field itself swells into the panel: while the
   finger moves, the field's top follows it (`ChatReplyField.swell`, `ChatFieldDrag.swell`, at most
   `ChatViewLayout.fieldDragMaxSwell`); on let-go the panel opens with the pill's spring once the
   swell, or a flick's predicted swell, reaches `fieldDragOpenDistance`, and otherwise the field
   settles back. Only a drag more up than sideways counts, so the chat's sideways swipes are
   unchanged. The swell is not the field's room: `pill(on:)` takes it back out of the layout right
   after the field (`.padding(.top, -fieldDragProgress.swell)`), so the field's glass grows upward
   while its measured height, the bar, its inset and the chat stay put; the two paddings read the
   same gesture state and spring back in the same reset transaction, so they cancel through the
   settle too. While the field is dragged up, its swollen glass grows over the "Replying only to" line or
   the no-reply notice above it, and the bar, the chat and its inset stay still, as designed. *Superseded 2026-11-21 (the compensation below needed three fixes and was deleted
   for the padding above):* "from the drag's start until its swell has settled
   (`ChatThreadView.fieldDragSettle`, the pill spring's own `settlingDuration`, so the two cannot
   drift apart) the bar keeps its resting height, so the chat does not move during the swell or the
   settle. The bar also ignores the field's height while the drag is in progress
   (`fieldDragProgress.isDragging`): the drag's start queues the bar's geometry action and the
   `onChange` that sets the settle token together, and SwiftUI runs deferred actions in an
   unspecified order." The drag's state is a `@GestureState`
   (`ChatFieldDrag.Progress`) reset with the pill's spring, so a cancelled drag (the panel opening on
   an agent answer mid-drag, a system interruption) springs back too; the let-go only decides
   whether the panel opens. The drag holds the user-interaction freeze through `ChatSwipeHold` under
   its own id (`ChatThreadView.fieldDragHoldId`) from its start until its swell has settled
   (`ChatThreadView.fieldDragSettle`, the pill spring's own `settlingDuration`, so the two cannot
   drift apart) plus the freeze rule's cooldown (`ChatViewLayout.freezeCooldown`, the part of
   `swipeSettleHold` past the swipe spring) after it ends, finished or cancelled: one
   `ChatSwipeHold.release(_:after:)` at the let-go, which a newer drag's `begin` cancels.
   *Superseded 2026-11-21:* "One timer chain does both: at the settle the bar takes the field's
   height, after the cooldown the freeze is released, so the hold always lasts at least the settle
   plus the cooldown."
   VoiceOver opens the panel with the named action "Show TabMail chat" on the element it focuses:
   the text field, the sent words while the agent works, the waveform while dictating
   (`showChatAction`), only while the panel is closed. Not in the tutorial, whose steps open the chat themselves. The panel stays dimmed
   with the rest of the chat as built (the ghost dims with it). Tests: `ChatFieldDragTests`,
   `ChatSwipeUITests.testDragUpOnTheReplyFieldOpensTheChatPanel`,
   `testShortDragUpOnTheReplyFieldSettlesBack` and `testDraggedOpenPanelClosesOnCloseAndOnTheDim`
   (taps), `ChatReplyFieldTests.fieldDragWiring`. The swell and the settle are covered by
   `ChatSwipeUITests.testShortDragOnTheReplyFieldKeepsTheChat`, which reads the debug marker
   `ChatFieldDragMarker` (the newest row's largest move from the drag's start until well after the
   settle, and whether the freeze is still held halfway through the cooldown), by
   `testDragThatOpensThePanelReleasesTheFreeze` (the same marker's freeze state) and by
   `ChatReplyFieldTests.fieldDragSettleIsThePillSpring` (the settle is the pill spring's).
   (`fieldDragSettleFences`, which pinned the deleted settle token, gate and timer chain, was
   removed with them on 2026-11-21.) The VoiceOver action:
   `ChatThreadLayoutTests.showChatActionOpensThePanel`.

20. **The first-time drag tip (amendment 2026-11-20).** Once, above the collapsed reply field, a
   tip in today's TipKit style (`ChatFieldDragTip`, behind the onboarding gate, shown at most once)
   says "Drag up to see what you asked TabMail about this conversation." It is an inline `TipView`
   with `arrowEdge: .bottom` in an overlay whose bottom sits on the field's top, not a popover: it
   pushes no layout and takes no touch from the field, so the user's first tap focuses the field
   and their first drag opens the panel (a popover tip would swallow that first touch). It goes
   away for good when a drag starts, the field takes focus, the panel opens, or on its own close
   button (TipKit invalidates it with `.tipClosed`; the drag, the focus and the panel opening call
   `ChatFieldDragTip.close()`, `invalidate(reason: .actionPerformed)`), and is not shown over the open panel or in the
   tutorial; there is no tutorial step for it. The overlay hangs on the whole stack in
   `pill(on:)`, so it sits above "Replying only to" and the no-reply notice, never over them. Tests:
   `ChatReplyFieldTests.fieldDragTip`, `ChatFieldDragTests.firstDragWithTheTipOpens`,
   `ChatSwipeUITests.testFieldDragTipShowsAndLeavesTheFieldItsTouches` (launched with
   `--chat-field-drag-tip`, which resets the TipKit datastore and forces the tip on).

21. **A new email rises into the open chat (amendment 2026-11-20).** When the newest email changes
   after the chat has landed (`ChatArrival.isArrival`), the new bubble rises from behind the reply
   field (`.move(edge: .bottom)`) over `ChatViewLayout.arrivalRiseDuration` (0.42 s) and the rows
   above move up with it: the stack's layout animates with the same rise, so the row's height grows
   inside the animation. While the landing still holds the chat at the bottom, the arrival re-pins
   it through the landing's own target in the same animation, so the new email ends fully above the
   field. Under Reduce Motion the space opens at once (no layout animation, the chat jumps up) and
   the bubble fades in over `arrivalFadeDuration` (0.2 s). The open's own load never animates, and
   only the arriving row has the transition, so Reduce Motion does not fade in a load's rows. The
   user's own newest email (their reply, filed from Sent) is not an arrival and does not rise.
   Not decided here and left for later work: the AI Suggestion's working bubble and its growth into
   the ghost. *Since built:* decision 16's working-bubble amendment (2026-11-20). Tests: `ChatArrivalTests`, `ChatThreadLayoutTests.arrivalEndsAboveTheField`,
   `ChatReplyFieldTests.arrivalWiring`.

## The longer index line (routed 2026-11-09)

The DECISIONS.md row grew with each decision of the chat view; it moved here when the index went
back under its size budget. The index keeps one short line. The migration names were corrected to
the renumbered `v105`/`v106` on 2026-11-15, and the build-stage labels were replaced by decision
numbers.

```text
- **[ADR-IOS-114](Companion/Decisions/V3/Active/adr-ios-114.md)** — Active. Protocol 2.0.0: summary + precomputed reply arrive as JSON with a text message (`summaryTextMessage`, `replyTextMessage`, `v105_addAITextMessages`, `parseReplyResponse`, NSE `X-Client-Version`); AI results live as long as their email (`runPurgeOrphanedAICache`, `aiCacheOrphanGraceDays`; TTL purge deleted); decode JSON as sent (no `normalizeUnicode`), reply body "None" is data, legacy cache entries filled by `v106_repairAICacheMessageIds`, the purge keeps an entry only while a header of its OWN account has its Message-ID (`aiCacheEntryHasEmail`; key branch and writer account guards dropped, 2026-11-09), purge only in storage maintenance (`runWALMaintenance`), one clock read per pass (`now`), extension cache entries stamped as a date (`upsertAICacheFromStaging`, shared with #395), "no content" summaries clear the text message; compose recompute (`recomputedReply`) writes through `aiGuardedHeaderWrite`; queue peer check via `AIService.peerProbe`; the backend's protocol 2.0.0 JSON shape; TB-parity exception. Decision 8: chat summaries for every thread member, any folder (`AIJob.forChat`, `enqueueChatSummaries`, `chatWalkCandidates`, `summaryDone`, `ChatViewConfig`, `noContentSummary`, textless answers in `textlessChatJobs` until `aiReenabled`). Decision 9: the chat screen (`MessageOpenView`, `opensInChat`, `ChatThreadView`, `ChatThread`, `ChatThreadContext`, `ChatInvite`, `chatViewEnabled` toggle, `isActive` = toggle + AI on (hidden release switch deleted, the chat view ships whole), `MessageSnapshot.preview`, `UserLabel.union`); what it asks for and where it opens (decided 2026-11-09, supersedes the 2026-11-06 window): newest `summaryWindow` on open, newest first (`askForNewest`), older rows as they come on screen (`askAsShown`, `onScrollVisibilityChange`), chat work always at the front (`moveToFront`, `chatAwaitingBody`, no request numbering), plain `VStack` + `defaultScrollAnchor(.bottom)` + one `scrollTo` re-issued on size change until the first scroll (the Unread line, a searched email); `ChatSummaryWindow`, `ChatLanding`, `summaryAskSettle` deleted. Decision 10: the reply field (`ChatReplyField`, `readyText`, `route`, `agentMessage`, `statusLine`, `DynamicIslandChat` `replyField`), the Sending bubble read from the outbox (`ChatUnsentReply`, `ChatUnsentReplyBubble`, row by In-Reply-To until its Sent copy is in the chat, `filed` + `reloadThread` hand-over, no in-memory state; rebuild 2026-11-09), summary at Send `SentEmailSummary`, a joining member's summary (`noteMembers`). Decision 11: who gets the reply (`ChatReplyTarget`, `ChatReplyToSheet`, `ChatReplyToChoice`, "Replying only to", `route(recipientsChanged:)`, `agentMessage(onlyTo:)`), Forward button, "replied only to" labels (`repliedOnlyTo`, `OnlyTo`, `ChatPeopleList`, VoiceOver `accessibilityText`). Decision 12: chat swipes (`ChatSwipe`, `ChatSwipeReveal`, `ChatHorizontalPan`, Unread from here / Read up to here, `readTargets`, `unreadIds`), whole-chat Archive/Trash/Move as one undo + one move (`archiveMessages`, `deleteMessages`, `moveMessages`, `recordMove`, shared `UndoableAction.byAccount`/`move`, `chatMembers`), `setRead`, inbox Read on a collapsed chat reads it all (`inboxReadIds`). Decision 13: the tutorial in the chat view (`teachesChat` snapshot at `start`, `chatViewOnForTutorial`, `opensInChat` follows the run, `FieldMove` `.sendReadyReply`/`.ask(.saveReplyAsTemplate)`, `chatShowsCard`, `Step.chatViewSwitch`, `TutorialChatViewSwitchSheet`, `ChatViewToggleRow`, "Make it shorter" `shorterReply`, "Event RSVP: yes", seeded threads `computedThreadId`/`inReplyTo`/`textMessage`, chat mail actions `admits(.other)`), Reply tag opens the chat, reference highlight.
```
