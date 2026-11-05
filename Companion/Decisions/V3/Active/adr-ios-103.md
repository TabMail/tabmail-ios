## ADR-IOS-103: The Summary and the Precomputed Reply Arrive as JSON with a Text Message; AI Results Live as Long as Their Email

**Status:** Active (2026-11-05). Owner decisions 2026-11-05 (chat view, iOS 2.0). Backend side:
`tabmail-backend` ADR-032 (issue `tabmail-backend#153`). iOS issue #387. A deliberate exception to
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
   `SyncEngine.runPurgeOrphanedAICache` deletes an entry only when no header in ANY folder has its
   Message-ID and it has been untouched for `SyncConfig.aiCacheOrphanGraceDays` (7); a kept entry is
   re-stamped so it is not re-checked for another grace period. The grace keeps the cache's original
   job, restoring AI to a header that leaves and comes back (stale detection, a UIDVALIDITY reset).
   Awaiting owner blessing: the 7-day orphan grace. The extension's cache upserts now record the
   Message-ID, so the purge can match them to their email.
6. **Decoding as sent, and older entries' identity (review round 1, 2026-11-05).** The summary JSON is
   decoded exactly as received: rewriting characters first (`normalizeUnicode`, kept from the labelled
   text) turned curly or fullwidth quotes inside a JSON string into bare ASCII quotes and broke the
   object. A reply body is any non-blank string, "None" included: only the text message's "NONE"
   placeholder of the summary is not a body rule. Entries an older extension wrote have no Message-ID,
   so the purge would delete them though their email is here: the extension's one cache upsert
   (`NSEDataBridge.upsertAICache`, used for an existing and a new header) fills a missing Message-ID on
   conflict (`COALESCE`, and the row is rewritten even when its content is unchanged),
   `MessageAICache.writeThrough` fills it on any later write, and `v96_repairAICacheMessageIds`
   (`AppDatabase.repairAICacheMessageIds`) fills existing ones from the header whose key the entry has.
   An entry with no such header stays without one and is an orphan, as before.

**Release order:** an iOS build at protocol 2.0.0 must not reach users before the backend change
(ADR-032) is deployed to production: an older backend sends 2.0.0 the labelled text, which this
parser does not read.

**Tests:** `AISummaryParsingTests`, `AISummaryResponseTests`, `AIReplyParseTests`, `AIReplyTests`
(parsers and `ReplyResult`); `AICachePurgeTests` (the orphan purge, driven for real);
`ComposeSuggestionPersistTests.editClearsReplyTextMessage`; migration and merge tests in this PR;
`AITextMessageCallerTests` (the queue's summary and reply jobs, the opened-email direct path in full and
reply-only, compose's
recompute and the extension's request, each through its real producer and a fake backend);
`AITextMessageStorageTests.v96RepairsLegacyIdentity` / `writeThroughRepairsLegacyIdentity`;
`NSEGradualMergeTests.existingHeaderMergeRepairsLegacyCacheIdentity` /
`newHeaderMergeRepairsLegacyCacheIdentity`; `RFC822IdentityMergeGuardTests.preSyncInboxReclaimCarriesTextMessages`.
Not driven by a test: the line in the extension's `NotificationService` that hands the parsed text
message to staging (the pipeline has no harness); its parser and its staging writes are tested.
