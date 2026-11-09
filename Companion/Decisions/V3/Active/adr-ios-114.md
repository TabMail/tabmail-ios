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
   longer depends on it. Review round 2 (2026-11-05) also removed a second purge trigger at the end of
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
   that set (`enqueueChatSummaryJobs`, `retiredForProcess`). `rearmUnattributableJobs`, which runs
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
   same, and the next request reads what is missing from the database.
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
   `ChatThreadView` reuses `MessageDetailViewModel` (body, thread load, mark-read, archive, delete,
   move); `ChatThread` is the pure model: drafts left out, one copy per `stableId` (the opened copy,
   else one with a text message), oldest first by (date, id), own = from one of the account addresses
   or in a Sent folder, reply people = the newest email's `buildReplyAllRecipients` minus the user,
   a group when more than one other person; time stamps after `ChatViewLayout.timeStampGap`; the
   Unread line above the first email unread at open (recorded before marking read). Each bubble opens
   the email card (today's `MessageDetailView` in a sheet). `ChatThreadContext` reads the Drafts/Sent
   folders, the label union (`UserLabel.union`, shared with `ThreadGroup.displayInfo`), top-level
   attachment names and an addable invite (`ChatInvite`; the card stands for its calendar file).
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
     (`ChatThreadView.askForNewest`).
   - An older email asks for its own summary when its row comes on screen (`askAsShown`, per-row
     `onScrollVisibilityChange`). Nothing else asks: no record of what is on screen, no settle wait,
     no hand-scroll flag.
   - Every request's work goes to the FRONT of both queues in the order asked, each request in front
     of the earlier ones (`QueueStorage.moveToFront`, `ActiveBodyQueue.enqueueBatch(first:)`). An
     email without its body waits in `ActiveAIQueue.chatAwaitingBody` (header id to account) and its
     job goes to the front when the body lands. There is no request numbering.
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
     uses `onScrollVisibilityChange`.
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
     was shown; a jump to the top asks for the top and nothing it jumped past.

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

**Release order:** an iOS build at protocol 2.0.0 must not reach users before the backend change
(its protocol 2.0.0 JSON shape) is deployed to production: an older backend sends 2.0.0 the labelled text, which this
parser does not read.

**Tests:** `AISummaryParsingTests`, `AISummaryResponseTests`, `AIReplyParseTests`, `AIReplyTests`
(parsers and `ReplyResult`); `AICachePurgeTests` (the orphan purge, driven for real, including
`legacyEntryKeptByItsKey`, `maintenanceRunsThePurge` and `clockOffWallClockEnds`, the clock behind and ahead of the wall clock);
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
upgraded) and `legacyEntriesSurviveUpgradeAndPurge` (including v97 filling the Message-ID that a peer's
probe then finds); `RFC822IdentityMergeGuardTests.preSyncInboxReclaimCarriesTextMessages`;
`NSESummaryTextMessageCarryTests` (the staging writes, `NSEStagingDB.open(path:)` upgrading an older
file, the extension bundle's protocol version, a later push whose only change is the text message,
including to none (`sameSummaryNewTextMessage`), the merge's second stage creating a header the first
stage could not and caching its result with the text message (`secondStageCachesTextMessage`), a merged
cache entry kept through the orphan grace (`mergedCacheEntryGetsTheGrace`), and a push through `NotificationService.didReceive`
staging the text message, via `NotificationService.stagingPathOverride`).
Decision 8: `ChatSummaryQueueTests` (including a chat offer made while its ordinary twin is in flight, just after it ended, or when it runs again, and the foreground pass's walk, two-sided on the chat view); `ChatSummaryExecutionTests` (the own-email field, two-sided; the executor refusing an ordinary summary outside the Inbox, with an Inbox control). Decision 9: `ChatThreadTests`,
`ChatThreadContextTests`, `ChatThreadViewLifecycleTests`, `ChatCardIdentityTests`, `ChatSummaryQueueTests.chatViewSwitch`/`activeMatrix`, `ThreadGroupTests.displayInfoUnionLabels`.
