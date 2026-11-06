## ADR-IOS-103: The Summary and the Precomputed Reply Arrive as JSON with a Text Message; AI Results Live as Long as Their Email

**Status:** Active (2026-11-05). Owner decisions 2026-11-05 (chat view, iOS 2.0). Backend side:
`tabmail-backend` ADR-032. iOS issue #387. A deliberate exception to
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
   (`v96_addAITextMessages`, nullable, no backfill; numbered after main's
   `v95_convertNumericAICacheUpdatedAt`, which keeps its number; owner 2026-11-07: main has priority, and
   these migrations have run on no device). The next migration is v98. Each text message belongs to its result: every
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
5. **Lifetime (owner D1).** An AI result lives as long as its email is on the device, with no size or age
   limit. The time-based purge and its inbox-only touch (`refreshAICacheTTLAndPurge`,
   `SyncConfig.aiCacheTTLDays`, the unused `replyTTLSeconds`) are deleted.
   `SyncEngine.runPurgeOrphanedAICache`, run by storage maintenance (`SyncEngine.runWALMaintenance`:
   the foreground poll and the background processing task), deletes an entry only when no header in ANY
   folder has its Message-ID and it has been untouched for `SyncConfig.aiCacheOrphanGraceDays` (7); a kept entry is
   re-stamped so it is not re-checked for another grace period. The grace keeps the cache's original
   job, restoring AI to a header that leaves and comes back (stale detection, a UIDVALIDITY reset).
   Awaiting owner blessing: the 7-day orphan grace. The extension's cache upserts now record the
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
   `v97_repairAICacheMessageIds` (`AppDatabase.repairAICacheMessageIds`) stays: it fills the Message-ID from the header in the folder the key names. The purge no
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
8. **Chat summaries (owner D2, D3; amendment 2026-11-05, the second chat-view PR).** The chat view
   needs a summary with a text message for every email of a thread, from any folder, the user's own
   included. Two requests ask for them, both behind `ChatViewConfig.isActive` (the user's toggle and AI
   on, decision 9), read once at the start of the operation:
   - **D2, opening a thread** (`MessageDetailViewModel.loadThreadMessagesAsync`, once per open):
     `ActiveAIQueue.enqueueChatSummaries` with the opened message and every member
     `ThreadDetection.findRelatedMessages` returns. A member with its body gets a job now; one without
     goes to `ActiveBodyQueue` and gets its job when `BodyFetchProcessor.flushBatch` writes the body
     (`chatBodyArrived`).
   - **D3, the background walk** (`chatWalkCandidates`, run at the end of `repopulateFromDatabase`):
     the threads of the newest `SyncConfig.maxRecentEmails` Inbox rows, every member with its body.
   **A thread is the whole thread (amendment 2026-11-06, train gate):** `findRelatedMessages`
   returns every email connected to the opened one, with no length or depth limit, because the chat
   shows the whole thread, all the way back (owner Q2, "Typical email threads are not that long").
   Its old cap (`SyncConfig.threadQueryLimit`, 100 emails, plus five expansion rounds) dated from the
   first release with no recorded reason and is deleted. The expansion still ends: each round adds
   only emails not seen yet. The bound is on the AI work instead (owner 2026-11-06: "add a safety
   bound that you load up to something like 10 emails from the current visible oldest message"):
   the open chat asks only for the emails on screen and those near them (decision 9,
   `ChatSummaryWindow`); until the chat screen exists the requests stay off in release builds.
   **Amended 2026-11-06 (owner's safety bound):** D2 no longer asks for every member at open, and D3
   takes at most each thread's newest `ChatViewConfig.summaryWindow`; see decision 9, "The chat asks
   for the emails in view".
   A chat request is an ordinary summary job (same model, queue, executor and write) with
   `AIJob.forChat`: it is window-exempt, any folder passes its scope checks (`readJobOutcome`,
   `executeJob`), and it is done only when the summary has its text message. `forChat` is context,
   not identity, like `windowExempt`; on dedupe the flags only widen (`admitOrUpgrade`). The chained
   action job does not inherit it, so it keeps the Inbox scope.
   **The user's own email** (amendment 2026-11-05, train gate): a summary of an email the user
   wrote, as the chat decides it (from one of the user's addresses, or in a Sent folder;
   `ActiveAIQueue.isSentByUser`), sends `is_sent_by_user: true` (`PromptVariables.summaryVariables`),
   so the backend writes its text message in the user's voice (ADR-032); any other email's request
   omits the field, as Thunderbird's always do. Every queue summary job carries it; the new-mail
   pipeline (`AIService.process`) is Inbox mail and keeps Thunderbird's request.
   *Amended 2026-11-07 (train review round 8):* the last sentence was wrong. Inbox mail can be the
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
   **TB parity:** a further exception to ADR-IOS-008: Thunderbird summarizes Inbox mail only.
   **Recoverable edges, awaiting owner blessing:** members awaiting their body are held in memory
   only (a relaunch forgets them; the next open or walk asks again); a member whose body arrives
   through the background backfill (not the AI-enabled body queue) is picked up by the next walk or
   open, not at once; a chat offer rejected by `recentlyCompleted` or an in-flight twin is asked again
   by the next walk or open.

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
   The inbox row shows the text message when the chat view is on (`MessageSnapshot.preview`).
   A bubble with no text message yet reads "Summarizing"; an email with nothing to summarize is
   done without one (`MessageHeader.noContentSummary`, which `summaryDone` counts as done), so its
   bubble shows that line instead (`ChatThread.Item.textMessage`), never a spinner that cannot end.
   The chat shows the whole thread, all the way back (owner Q2): it comes from
   `ThreadDetection.findRelatedMessages`, shared with today's thread list, which has no length or
   depth limit (decision 8).
   **The chat asks for the emails in view (owner, 2026-11-06, train gate).** Owner: "add a safety
   bound that you load up to something like 10 emails from the current visible oldest message.
   scrolling triggers everything "in view" to be prioritized once scrolling stops, and then again
   20 in both directions". So the thread lookup stays whole, and the per-email work (body download
   and summary) is bounded by what is on screen. `ChatThreadView.askForSummaries` reads the emails on
   screen (`onScrollTargetVisibilityChange`) and asks `ActiveAIQueue.enqueueChatSummaries` for the
   ids `ChatSummaryWindow.ids` gives: the emails on screen, newest first, then, until the user has
   scrolled by hand, the `ChatViewConfig.summaryWindow` (10) emails above the oldest on screen; once
   a hand scroll (`ChatSummaryWindow.userMoved`: a drag or its fling) stops, `ChatViewConfig.
   summaryWindow` on each side, nearest first. The chat's own scrolls (to the Unread line, a
   searched email, the jump to the bottom) keep the open window. It asks once the emails on screen
   have stayed the same for `ChatViewConfig.summaryAskSettle` (300 ms) with the scroll at rest (the
   open, an email that joins at the bottom) and when a scroll stops; the wait keeps the layout jumps
   while the chat moves to its opening place from asking for emails the user never sees. The first
   scroll records the members' unread state itself (`noteMembers`) before choosing where to land:
   SwiftUI runs the thread-loaded and members changes in either order, and the screen tests caught
   the chat opening at the bottom with the Unread line missing. Each request's work
   goes to the FRONT of both queues in that order (`QueueStorage.moveToFront`, `ActiveBodyQueue.
   enqueueBatch(first:)`), so the screen comes first and the latest request beats earlier ones; a
   body that lands for an email asked for gets its job at the front too. The open-time request in
   `MessageDetailViewModel` (D2 as first built, every member at once) is deleted. The background walk
   (D3) pre-summarizes each walked thread's newest `summaryWindow` emails, which a chat opens at.
   Overnight calls, awaiting the owner's blessing: the open asks for the screen plus 10 above and a
   stopped hand scroll for 20 each way (the two numbers read as the open's bound and the scroll's);
   the screen is asked newest first; the walk's 10 per thread; bodies are put first like summaries;
   the 300 ms settle.
   **Owner ruling 2026-11-06 on those calls:** the 20 was arbitrary; one number, 10, everywhere: 10
   above the oldest email on screen at open, 10 each way once a hand scroll stops, and the walk's 10
   newest per thread, all from the single `ChatViewConfig.summaryWindow` so it is easy to change
   (it replaced `summaryLead` and `summarySpread`).
   Tests: `ChatSummaryWindowTests`, `ChatSummaryQueueTests` (order, latest first, walk bound),
   `QueueStorageTests` (`moveToFront`), and `ChatThreadViewLifecycleTests`, which opens the real
   chat in a window: the first scroll (bottom, Unread line, searched email), every email marked read
   in the database, and the request covering only the screen and the 10 above it.
   **Blessed by the owner (2026-11-05):** in 3a today's pill stays and acts on the NEWEST email;
   "Sent" under every own bubble; the 15-minute gap; tutorial and demo-AI-off keep today's view; a
   reminder open highlights its email; triage rows keep the snippet, with no text message; the
   agent's toast is not shown in the chat. The User Interface Settings section, which holds the
   toggle, sits at the top of Settings.
   **The hidden release switch is deleted (owner, 2026-11-05).** Until then release builds kept the
   chat view off (`isAvailableInBuild = false`; a debug-menu override turned it on while debug was
   unlocked; `isReachable` showed the toggle and moved User Interface to the top), so `main` stayed
   releasable between the chat-view PRs. The owner ruled that the whole train is tested, merged and
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
   **The Sent bubble before its email arrives (N7):** a reply sent from the chat (the ready AI Reply,
   or an agent compose asked for in the field) is kept in memory (`ChatSentReplies`, keyed by the
   account and the replied-to Message-ID) and shown as the user's words: on the sent email's own
   bubble while it has no text message (matched by `inReplyTo` and a date no earlier than the send
   minus `ChatViewLayout.sentReplyDateSlack`), else as a pending bubble at the bottom. An entry goes
   when its email's text message arrives (`settle`) or after `sentReplyLifetime`. After a relaunch
   the sent email shows "Summarizing" until its summary lands; nothing is persisted (ADR-004).
   **Product choices made in 3b, awaiting owner blessing:** the chat-view pill drops today's Reply
   and Archive menus (swipes come with PR 5, Forward and recipients with PR 4); the field-to-sheet
   change has no morph animation yet; the sheet is not sized to its content; a request that only
   acts (archive, label) opens the sheet with the agent's answer.

**Release order:** an iOS build at protocol 2.0.0 must not reach users before the backend change
(ADR-032) is deployed to production: an older backend sends 2.0.0 the labelled text, which this
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
Decision 8: `ChatSummaryQueueTests`; `ChatSummaryExecutionTests` (the own-email field, two-sided; a real body write releasing the waiting chat summary once; the executor refusing an ordinary summary outside the Inbox, with an Inbox control). Decision 9: `ChatThreadTests`,
`ChatThreadContextTests`, `ChatSummaryQueueTests.chatViewSwitch`/`activeMatrix`, `ThreadGroupTests.displayInfoUnionLabels`.
Decision 10: `ChatReplyFieldTests` (the ready text, Send's route, the agent's message, the status
line, sent-reply matching and settling, and the field and chat wiring read from the source),
`ChatSummaryQueueTests.openAsksForAnEmailThatJoins`.
