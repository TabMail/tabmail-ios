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
   ones is the chat view's job (next PR), not this one's.
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
6. **Decoding as sent, and older entries' identity (review round 1, 2026-11-05).** The summary JSON is
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
   Message-ID from the key. v97 has run on simulators, so it stays frozen and is the only repair: an
   entry it could not fill (its email had moved before the upgrade) is purged after the grace and
   its results are made again when needed (bounded, self-healing). Writers now fill a missing
   Message-ID (NULL or empty) from the one they write with, and never replace a stored one:
   `MessageAICache.writeThrough` and the extension's upsert (`NSEDataBridge.upsertAICacheFromStaging`,
   also when its AI fields are unchanged). So such an entry is kept again from its next write while
   its email is on the device (`AICacheMessageIdFillTests`). And an entry is kept only while
   a header OF ITS OWN ACCOUNT (the key's first part) carries its Message-ID, so another account's
   copy of the email keeps nothing and a removed account's entries go after the grace; this
   replaces the writer-side account checks that PR 3b had added to `writeThrough` and the
   extension merge, which are not built. Review round 2 (2026-11-05) also removed a second purge trigger at the end of
   the AI queue's drain. Review round 4 (2026-11-05): the purge reads the clock once (its `now`
   argument), the base of its cutoff and the re-stamp of a kept entry, so a kept entry always leaves
   the selection and the pass ends, even if the clock is set back while it runs. Later the same
   day: the extension merge stamps a cache entry's `updatedAt` as a date
   (`NSEDataBridge.upsertAICacheFromStaging`), like every other writer. A number sorted before every stored
   date, so such an entry missed the grace. The two "no content" summary writers
   (`AccountManager.processMessage`'s shortcut and `BodyFetchProcessor`'s confirmed-empty write)
   clear the text message with the summary they replace.
7. **Compose's recompute writes through the identity guard (review round 3, 2026-11-05).**
   `ComposeView.recomputedReply` stores its reply and text message with
   `AccountManager.aiGuardedHeaderWrite`, using an `AIWriteTarget` captured from the email compose is
   replying to. A UIDVALIDITY reset can put a different email at the same address while the model
   answers; the write is then dropped, and the suggestion is still shown in compose. The queue's
   pre-dispatch Device Sync check (`ActiveAIQueue.executeJob`) asks through `AIService.peerProbe`, the
   seam the opened-email path already uses, so a whole queue job can be run against a fake peer
   (`ActiveAIQueue.executeWholeJobForTesting`).
8. **Chat summaries (amendment, decided 2026-11-05, the second chat-view PR).** The chat view
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
   **A thread is the whole thread (amendment 2026-11-06):** `findRelatedMessages`
   returns every email connected to the opened one, with no length or depth limit, because the chat
   shows the whole thread, all the way back (decided 2026-11-06: "Typical email threads are not that long").
   Its old cap (`SyncConfig.threadQueryLimit`, 100 emails, plus five expansion rounds) dated from the
   first release with no recorded reason and is deleted. The expansion still ends: each round adds
   only emails not seen yet. The bound is on the AI work instead (decided 2026-11-06: "add a safety
   bound that you load up to something like 10 emails from the current visible oldest message"):
   the open chat asks only for the emails on screen and those near them (decision 9,
   `ChatSummaryWindow`); until the chat screen exists the requests stay off in release builds.
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

9. **The chat screen (amendment 2026-11-05, the third chat-view PR, 3a).** With the chat view on
   (`ChatViewConfig.isActive` = the user's Settings toggle `chatViewEnabled` (default on, kept while
   AI is off) AND AI on (not opted out, a plan or trial active)), every thread open goes through
   `MessageOpenView`, which decides chat or today's email view ONCE per open (`opensInChat`, also off
   in the demo's AI-off mode and during the tutorial): the inbox, push and notification opens
   (`MessageDetailResolvedContent`), search results and the Reminders link.
   `ChatThreadView` reuses `MessageDetailViewModel` (body, thread load, mark-read; in 3a also
   archive, delete and move from today's pill menus, which 3b drops, decision 10); `ChatThread` is the pure model: drafts left out, one copy per `stableId` (the opened copy,
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
     the thread is loaded, and again on every container or content size change until a scroll of
     any kind begins (memory 036: a first scroll can be dropped while the screen settles). The first
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
   **Decided 2026-11-05:** in 3a today's pill stays and acts on the NEWEST email;
   "Sent" under every own bubble; the 15-minute gap; tutorial and demo-AI-off keep today's view; a
   reminder open highlights its email; triage rows keep the snippet, with no text message; the
   agent's toast is not shown in the chat. The User Interface Settings section, which holds the
   toggle, sits at the top of Settings.
   **The hidden release switch is deleted (decided 2026-11-05).** Until then release builds kept the
   chat view off (`isAvailableInBuild = false`; a debug-menu override turned it on while debug was
   unlocked; `isReachable` showed the toggle and moved User Interface to the top), so `main` stayed
   releasable between the chat-view PRs. It was decided that the whole train is tested, merged and
   released at once, so that reason is gone and the switch, the override and the two Settings
   positions went with it.

10. **The reply field (amendment 2026-11-05, the fourth chat-view PR, 3b).** In the chat, today's
   pill on the newest email is shown as a reply field, [mic] [field] [Send]: `DynamicIslandChat`
   with a `ChatReplyField`, so it is the same agent session (`msg:{accountId}:{stableId}`) and the
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
   Decided 2026-11-08: typed chat text no longer reaches the production
   chat error log either (debug logging keeps it), following the rule that diagnostic logging is
   debug-gated.
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
   no summary from Send) asks for its summary like the open's newest (`noteMembers`).
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
   Message-ID any more, or after `sentReplyLifetime`. Review round 11 (2026-11-07): Outlook files
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
   then. Review round 10 (2026-11-07): the date match had put a chat reply's words on a different
   reply sent elsewhere to the same email; nothing proves which email is which send, so the match
   now only ends the pending bubble. Decided 2026-11-08: the arrived email reads
   "Summarizing" for the few seconds until its summary, instead of the user's words. Nothing is
   persisted (ADR-004).
   **Product choices made in 3b, decided 2026-11-08:** the chat-view pill drops today's Reply
   and Archive menus (swipes come with PR 5, Forward and recipients with PR 4); the field-to-sheet
   change has no morph animation yet; the sheet is not sized to its content; a request that only
   acts (archive, label) opens the sheet with the agent's answer.

11. **Who gets the reply, and Forward (amendment 2026-11-05, the fifth chat-view PR, PR 4).** The
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
   **Product choices made in PR 4, decided 2026-11-08:** an email that only adds someone new is
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
   `ChatReplyFieldTests.agentReplyFromTheFieldIsReplyAllOnlyToTheWholeAudience`.

**Release order:** an iOS build at protocol 2.0.0 must not reach users before the backend change
(its protocol 2.0.0 JSON shape) is deployed to production: an older backend sends 2.0.0 the labelled text, which this
parser does not read.

**Tests:** `AISummaryParsingTests`, `AISummaryResponseTests`, `AIReplyParseTests`, `AIReplyTests`
(parsers and `ReplyResult`); `AICachePurgeTests` (the orphan purge, driven for real, including
`legacyEntryWithoutMessageIdPurged`, `entryKeptOnlyByItsOwnAccount`, `maintenanceRunsThePurge` and `clockOffWallClockEnds`, the clock behind and ahead of the wall clock);
`ComposeSuggestionPersistTests.editClearsReplyTextMessage`; migration and merge tests in this PR;
`AITextMessageCallerTests` (the queue's summary and reply jobs, a failed reply asked again and the next
one stored (`queueReplyFailureRecovers`), the "no content" summary clearing the text message
(`noContentClearsTextMessage`, `confirmedEmptyClearsTextMessage`), the opened-email direct path in full and
reply-only, a peer result through both, a whole queue job adopting a peer's action while keeping this
device's summary and reply text messages (`queuePeerActionKeepsLocalPairs`), compose's recompute
(`ComposeView.recomputedReply`) and its refusal to store on a replacement email at the same address
(`composeRecomputeReplacedEmail`), a filtered recompute and one from the snippet
(`composeRecomputeFiltered`, `composeRecomputeFromSnippet`), and the extension's request, each through its real producer and a
fake backend or peer); `AITextMessageStorageTests.upgradeKeepsResults` (a v94 database with results,
upgraded) and `legacyEntriesSurviveUpgradeAndPurge` (the purge keeps only the entries v97 filled; including v97 filling the Message-ID that a peer's
probe then finds); `RFC822IdentityMergeGuardTests.preSyncInboxReclaimCarriesTextMessages`;
`NSESummaryTextMessageCarryTests` (the staging writes, `NSEStagingDB.open(path:)` upgrading an older
file, the extension bundle's protocol version, a later push whose only change is the text message,
including to none (`sameSummaryNewTextMessage`), the merge's second stage creating a header the first
stage could not and caching its result with the text message (`secondStageCachesTextMessage`), a merged
cache entry kept through the orphan grace (`mergedCacheEntryGetsTheGrace`), and a push through `NotificationService.didReceive`
staging the text message, via `NotificationService.stagingPathOverride`).
Decision 8: `ChatSummaryQueueTests` (including a chat offer made while its ordinary twin is in flight, just after it ended, or when it runs again, and the foreground pass's walk, two-sided on the chat view); `ChatSummaryExecutionTests` (the own-email field, two-sided; the executor refusing an ordinary summary outside the Inbox, with an Inbox control). Decision 9: `ChatThreadTests`,
`ChatThreadContextTests`, `ChatThreadViewLifecycleTests`, `ChatCardIdentityTests`, `ChatSummaryQueueTests.chatViewSwitch`/`activeMatrix`, `ThreadGroupTests.displayInfoUnionLabels`.
Decision 10: `ChatReplyFieldTests` (the ready text, Send's route, the agent's message, the status
line, and the field and chat wiring read from the source),
`ChatReplyFieldRuntimeTests` (the ready AI Reply in the mounted field, the send's email lookup,
a failed request's log with and without its text, and the send wiring),
`ChatSendingBubbleTests` (`whichRowsShow`, the hosted hand-over and Retry/Delete, the summary at
Send and its gate), `ChatThreadViewLifecycleTests.aJoiningEmailAsks`,
`newestBubbleClearsATallField` and `sentReplyTakesTheTurn`.
Decision 11: `ChatThreadTests.repliedOnlyTo`,
`someoneNewIsNotOnly`, `userIsOnePerson`; `ChatReplyFieldTests` (`changedRecipientsRoute`,
`agentMessageOnlyTo`, `replyTarget`, `replyToChoice`, `accessibilityOnlyTo`, `recipientsWiring`).
