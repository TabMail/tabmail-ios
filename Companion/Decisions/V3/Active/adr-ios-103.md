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
   (`v95_addAITextMessages`, nullable, no backfill). Each text message belongs to its result: every
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
   missing value: the extension's one cache upsert (`NSEDataBridge.upsertAICache`, for an existing and a
   new header) records the Message-ID it has, as every new entry does.
   `v96_repairAICacheMessageIds` (`AppDatabase.repairAICacheMessageIds`) has run on test devices, so it
   stays (frozen): it fills the Message-ID from the header in the folder the key names. The purge no
   longer depends on it. Review round 2 (2026-11-05) also removed a second purge trigger at the end of
   the AI queue's drain. Review round 4 (2026-11-05): the purge reads the clock once (its `now`
   argument), the base of its cutoff and the re-stamp of a kept entry, so a kept entry always leaves
   the selection and the pass ends, even if the clock is set back while it runs. Later the same
   day: the extension merge stamps a cache entry's `updatedAt` as a date
   (`NSEDataBridge.upsertAICache`), like every other writer. A number sorted before every stored
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
upgraded) and `legacyEntriesSurviveUpgradeAndPurge` (including v96 filling the Message-ID that a peer's
probe then finds); `RFC822IdentityMergeGuardTests.preSyncInboxReclaimCarriesTextMessages`;
`NSESummaryTextMessageCarryTests` (the staging writes, `NSEStagingDB.open(path:)` upgrading an older
file, the extension bundle's protocol version, a later push whose only change is the text message,
including to none (`sameSummaryNewTextMessage`), the merge's second stage creating a header the first
stage could not and caching its result with the text message (`secondStageCachesTextMessage`), a merged
cache entry kept through the orphan grace (`mergedCacheEntryGetsTheGrace`), and a push through `NotificationService.didReceive`
staging the text message, via `NotificationService.stagingPathOverride`).
