# Pre-compaction catalog bullets — `DECISIONS.md` post-`v1.6.38` records (2026-10-24 pass)

**Status:** Historical (preserved source text) · **Routed:** 2026-10-24 `companion-compact` ·
**Source:** `tabmail-ios/DECISIONS.md` at `96ae858e`

`tabmail-ios/DECISIONS.md` was **44919 B, 80% over its 25,000 B budget**: the v3 catalog bullets
had again regrown into second copies of their ADR bodies, carrying each amendment inline (ADR-IOS-091
alone was 6.7 KB). The catalog now carries a shortened bullet for each; the text below is what
those bullets were compressed from, kept **byte-for-byte** so nothing a past plan, review prompt,
audit round or commit body quoted has become unsearchable. **The normative record is the linked
ADR body**, which this pass did not touch.

Each fragment is inside a ```text fence, as in the 2026-09-06 pass: the bullets contain links
written **relative to `DECISIONS.md`**, and `Scripts/compact_companion_docs.rb`'s
`verify_markdown_links` strips fenced code blocks before resolving links, so fencing preserves the
bytes exactly (`MIS-IOS-009`).

---

## Source line 103 — Forward-ported preamble

<!-- BEGIN VERBATIM FRAGMENT Forward-ported preamble -->

```text
These ADR bodies exist only on the mature pre-v3 line and are therefore not in `v1.6.38:DECISIONS.md`. The bodies are preserved byte-for-byte with their provenance in [`Companion/Decisions/ported-manifest.tsv`](Companion/Decisions/ported-manifest.tsv). They are excluded from the source-document reconstruction manifest and census.
```

<!-- END VERBATIM FRAGMENT Forward-ported preamble -->

---

## Source line 127 — Post-v1.6.38 preamble

<!-- BEGIN VERBATIM FRAGMENT Post-v1.6.38 preamble -->

```text
These records were authored after `v1.6.38`, so the pinned compaction has no byte-identical twin for them. Their bodies live **outside** `Companion/Decisions/{Active,Superseded,Deferred}/`, which is the census surface that reconstructs `v1.6.38:DECISIONS.md` exactly; their provenance, source line ranges and per-fragment `sha256` live in [`Companion/Decisions/V3/manifest.tsv`](Companion/Decisions/V3/manifest.tsv). Pre-compaction catalog wording is preserved byte-for-byte in [`pre-compaction-index-lines.md`](Companion/Decisions/V3/pre-compaction-index-lines.md), [`…-078-079.md`](Companion/Decisions/V3/pre-compaction-index-lines-078-079.md) and [`…-2026-09-06.md`](Companion/Decisions/V3/pre-compaction-index-lines-2026-09-06.md).
```

<!-- END VERBATIM FRAGMENT Post-v1.6.38 preamble -->

---

## Source line 129 — ADR-IOS-026B

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-026B -->

```text
- **[ADR-IOS-026B — the v3 supersession record](Companion/Decisions/V3/Superseded/adr-ios-026b-v3-superseded-by-068.md)** — *PendingOperation Uses Stable IDs (rfc822MessageId)*, **SUPERSEDED 2026-08-02 by ADR-IOS-068**, retained verbatim as evidence. **Only its durable-mutation-authority layer is superseded** — fetch, normalize, dedup, stage, the AI cache probe, threading/`References` and Outbox de-duplication SURVIVE; ADR-IOS-068's exempt list is normative. Authored under the colliding number `ADR-IOS-026`, so both search terms find it.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-026B -->

---

## Source line 130 — Compaction drift list

<!-- BEGIN VERBATIM FRAGMENT Compaction drift list -->

```text
- **[Compaction drift list](Companion/Decisions/V3/retained-inline-no-byte-identical-routed-twin.md)** — the retired *Retained inline — no byte-identical routed twin* preamble: check the routed twin before editing a post-`v1.6.38` amendment.
```

<!-- END VERBATIM FRAGMENT Compaction drift list -->

---

## Source line 139 — ADR-IOS-068

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-068 -->

```text
- **[ADR-IOS-068](Companion/Decisions/V3/Active/adr-ios-068.md)** — Active. Durable message actions use the native provider id; Message-ID remains correlation only. Defines the action/content authority split and its exemptions.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-068 -->

---

## Source line 141 — ADR-IOS-070

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-070 -->

```text
- **[ADR-IOS-070](Companion/Decisions/V3/Active/adr-ios-070.md)** — Active withdrawal/disposition record for ADR-IOS-058…067. Preserves ADR-IOS-061's reset reaction + invariant tests, ports 059/066/067, reactivates 057, and records that 062 was never an ADR.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-070 -->

---

## Source line 142 — ADR-IOS-071

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-071 -->

```text
- **[ADR-IOS-071](Companion/Decisions/V3/Active/adr-ios-071.md)** — Active. No backward compatibility for the action queue: v74 purged it predicate-free, and **as of the 2026-09-06 owner-approved amendment the purge is a STANDING APP-RELEASE BOUNDARY** — `AppDatabase.retirePreviousReleaseActionQueue` (migration `v89`, `appReleaseStamp`) deletes every `pendingOperation` row undecoded and marks every account full-sync-due, in ONE transaction inside `AppDatabase.init`; an unchanged release does not purge. Lifecycle carve-out, **not a fifth exit**; cost `IOS-ACTION-003`.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-071 -->

---

## Source line 143 — ADR-IOS-072

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-072 -->

```text
- **[ADR-IOS-072](Companion/Decisions/V3/Active/adr-ios-072.md)** — Active. Content belongs to message identity, not a mutable slot. A NULL identity stamp means re-fetch, never destroy; positive mismatch and two-phase publish gates own cleanup.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-072 -->

---

## Source line 144 — ADR-IOS-073

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-073 -->

```text
- **[ADR-IOS-073](Companion/Decisions/V3/Active/adr-ios-073.md)** — Active. Atomic `UID MOVE` is a distinct no-fallback route; `UIDPLUS` governs evidence, not eligibility. Missing evidence never authorizes guessing, replay, or stale undo.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-073 -->

---

## Source line 147 — ADR-IOS-076

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-076 -->

```text
- **[ADR-IOS-076](Companion/Decisions/V3/Active/adr-ios-076.md)** — Active. ⚠️ **PARTIALLY IMPLEMENTED.** The message document is untrusted content, enforced at the WebKit boundary: `allowsContentJavaScript = false` + the 12-directive `<meta>` CSP, a nonce-keyed navigation permit (`RenderNavigationPolicy`, default-deny `decidePolicyFor`), an `http`/`https` allowlist (`RenderLinkPolicy`), bridge validation (`RenderBridgeInput`), `.eml` traversal (`BodyAssetSchemeHandler`), deferred-image withholding (`hiddenByViewMode`). ⚠️ **FOUR owner REVERSALS are registered exceptions** (`IOS-UI-002`/`003`, `IOS-PRIVACY-001`/`002`/`003`). **Re-derive status from `git log`.**
```

<!-- END VERBATIM FRAGMENT ADR-IOS-076 -->

---

## Source line 148 — ADR-IOS-077

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-077 -->

```text
- **[ADR-IOS-077](Companion/Decisions/V3/Active/adr-ios-077.md)** — Active. Hostile attachment filenames are **REJECTED, not reduced** (`c35cfdca2`): one `AttachmentFilename.isSafeFileComponent` predicate, throw before `createDirectory` on save and refuse before the fetch on download; the reducer was DELETED because all five defects lived in the *transformation*. ⚠️ Rejecting at save does NOT make the loaders safe (`metaBase`/`afterIndexPrefix`; the combining test is `ccc != 0` on NFD). ⚠️ Consequence 5 retracts the MIGRATION GUARANTEE — `IOS-ATTACH-001`, forward-only by owner verdict.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-077 -->

---

## Source line 149 — ADR-IOS-078

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-078 -->

```text
- **[ADR-IOS-078](Companion/Decisions/V3/Active/adr-ios-078.md)** — Active. Newest-100 bounds sync-origin AI processing only; existing summaries always display (except under the user's own "Show AI Summaries" off preference — `showAISummariesKey`, "Hide Summary Bubbles" long-press, #153, amended 2026-09-10), while action tags remain Inbox-only. `ActiveAIQueue.recentInboxWindowContains`, `AIJob.windowExempt`, `MIS-IOS-018`, #68, #67. [Prior catalog wording](Companion/Decisions/V3/pre-compaction-index-lines-078-079.md#source-line-150--adr-ios-078)
```

<!-- END VERBATIM FRAGMENT ADR-IOS-078 -->

---

## Source line 150 — ADR-IOS-079

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-079 -->

```text
- **[ADR-IOS-079](Companion/Decisions/V3/Active/adr-ios-079.md)** — Active. Scheduled tasks and `taskCache` are deleted from iOS, remain live on Thunderbird; `[Task]` prose and `disabledReminders` `t:` hashes are retained. [Prior catalog wording](Companion/Decisions/V3/pre-compaction-index-lines-078-079.md#source-line-151--adr-ios-079)
```

<!-- END VERBATIM FRAGMENT ADR-IOS-079 -->

---

## Source line 151 — ADR-IOS-081

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-081 -->

```text
- **[ADR-IOS-081](Companion/Decisions/V3/Active/adr-ios-081.md)** — Active. **Account-scoped ≠ immutable**: `accountScopedIdAccountIds` admits `.outlook` to account-qualified lanes, and `MessageHeaderRekey.finishMove` re-addresses every non-cancelled same-account queued op naming a proven source id in the SAME transaction that retires the move (`readdressQueuedOperations`, keyed `(accountId, messageId)`; G3's folder clause stays byte-identical on IMAP, the C3 guard). Amends ADR-IOS-018 + ADR-IOS-068 §6. ⚠️ **AMENDED by ADR-IOS-082** — every "lane" here now means a related CHAIN. `IOS-GRAPH-005`, #114.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-081 -->

---

## Source line 152 — ADR-IOS-082

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-082 -->

```text
- **[ADR-IOS-082](Companion/Decisions/V3/Active/adr-ios-082.md)** — Active. **The action queue is drained by a GLOBAL SINGLE-OPERATION FIFO EXECUTOR** ordered by durable `queuePosition` (migration **v90**, `NOT NULL CHECK(queuePosition > 0)`, allocated in the admitting transaction; `createdAt` is AGE ONLY); one owner claims the front row (`claimFrontierOperation`), **protected-frontier law** stops at `inFlight`; lane DISPATCH retired (`buildRelatedChains`/`addressKey`/`deferRelatedChainToTail` scope a TAIL deferral). 🚨 **`.proceed` INVARIANT: only if the claimed row is provably GONE, NARROWED, or OWNED by `pendingRequeues`/`pendingRetirements`** — else it wedges every account's drain. Startup requeues interrupted moves with original identity + attempt history (#116).
```

<!-- END VERBATIM FRAGMENT ADR-IOS-082 -->

---

## Source line 154 — ADR-IOS-084

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-084 -->

```text
- **[ADR-IOS-084](Companion/Decisions/V3/Active/adr-ios-084.md)** — Active. **Gmail `internalDate` is NOT arrival time for Google-generated/relayed mail** (DMARC reports, list relays: measured `internalDate` eight weeks before the `Received:` acceptance day) — display/sort `date` on Gmail is the FIRST `Received:` header's timestamp (`EmailDateParsing.receivedHeaderDate`, `metadataHeaders=Received`), fallback `internalDate` only when absent/unparseable, never `Date()`; new column `messageHeader.providerDate` (migration **v91**, `NOT NULL`, backfilled `= date`) carries the provider's order key and is what the `.date` stale window, `oldestSyncedDate`, `before:` cutoffs and backfill anchors read; NSE stages `providerDate`; IMAP/Graph mirror `date`. Sort-order bug the owner reported 2026-09-15.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-084 -->

---

## Source line 155 — ADR-IOS-085

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-085 -->

```text
- **[ADR-IOS-085](Companion/Decisions/V3/Active/adr-ios-085.md)** — Active. **Chat-pill dictation = TabMail Voice's backend speech-to-text + cleanup** (`POST /dictation/transcribe`, `system_prompt_dictate_cleanup`; since 2026-09-29 the cleanup rides in the transcription request as `cleanup` → `cleaned_text`, backend ADR-027, deadline enforced by the backend, `cleanupTimeout` and the completions cleanup removed), replacing Apple `SFSpeechRecognizer`/`SpeechRecognizer`: `Services/Dictation/` (DictationController, MicrophoneCapture, AudioRecorder, FLACEncoder, LevelEnvelope, DictationCleanup) copied from Voice; uploads FLAC since 2026-09-29 (was WAV; same bytes as Voice's encoder, golden hash pinned in both); warm-up `GET /whoami` at the tap and 5xx/dropped-connection retry with a "Server error, retrying…" note (2026-09-29, Voice ADR-DESK-039); mic off offline (`NetworkMonitor`), Voice's waveform over the dimmed input field (no pill, no language shown, failures silent, accent-colour waveform, send while listening finishes then sends, Voice's spinner while transcribing, light cleanup: 500 chars before the caret, 1.5 s timeout — owner 2026-09-28); records only once speech is heard (on-device SoundAnalysis classifier, 2 s pre-roll, cap counts from speech, waits without limit), text appended at the end; audio leaves the device (not stored); audio session released every dictation; dictation language (`DictationLanguage`, Settings → Dictation Language, Automatic = iPhone language, sent as `language` so the backend picks the model per backend ADR-024; `DictationLanguageTip`); recording **peak-normalised to −3 dBFS** before upload, ≤ +30 dB, never cut (`AudioRecorder.normalizePeak`, amendment 2026-09-29, Voice ADR-DESK-040). Amendment 2026-10-02: the waveform always moves (follows the mic from its first sound); only the recording waits for speech; grey-blue (#9DB3C9) while waiting, iOS system blue (#0A84FF) once speech is heard, purple on the spinner while retrying (2026-10-03: fuchsia #C026D3 → #E0399E, faded in over `DictationConfig.colourTransition`; dictation colours in `Theme/Palette.swift`, as Voice ADR-DESK-048); the "Server error, retrying…" note waits 2 s after the first error (`showsRetryNote`, `transcriptionRetryNoticeDelay`), as Voice. Amendment 2026-10-03: `transcriptionRetryDelays` 0.5, 1.5, 3, 5, 10, 10, 15, 15 s (~1 min; was 0.5, 1.5) — owner "more retries, don't lose the end". Amendment 2026-10-05: **Smart Dictation** toggle (Settings, below Dictation Language, `SmartDictation`, default OFF, snapshotted at start): off sends no `cleanup` and no long-dictation polish, transcript appended as heard. **Amended 2026-10-08: one 10 s `transcriptionDeadline` from the tap to stop covers every request, retry, chunk and polish; retries 0.5/1.5/3 s; request timeout stays 45 s (chunks sent mid-dictation).**
```

<!-- END VERBATIM FRAGMENT ADR-IOS-085 -->

---

## Source line 156 — ADR-IOS-086

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-086 -->

```text
- **[ADR-IOS-086](Companion/Decisions/V3/Active/adr-ios-086.md)** — Active. **Dictation dictionary**: user words (`DictationDictionary`, UserDefaults, per device, 150 max, 100 typed max, learned words LRU-evicted by a `lastUsed` use count, Settings typed-then-learned alphabetical — amendment 2026-10-02; SENT in priority order, typed then learned each most recently used first, so the backend's per-model cut keeps the first — amendment 2026-10-07) + **context terms** filling the rest of 200 (`vocabularyMaxTerms` − dictionary size, ≥50; amendment 2026-10-02 later) picked on-device from the pill context and the email body (`DictationContextTerms`, `SearchIndex.bodyText`) sent as `vocabulary` (backend ADR-025); cleanup gets `dictionary`; snapshot at start; learns corrections in the pill input (`DictationCorrectionWatch`, `DictationCorrections` = Voice ADR-DESK-038 learner); Settings › Personalization › Voice Dictation Dictionary; no separate consent.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-086 -->

---

## Source line 157 — ADR-IOS-087

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-087 -->

```text
- **[ADR-IOS-087](Companion/Decisions/V3/Active/adr-ios-087.md)** — Active. **Long dictations in chunks** (TabMail Voice ADR-DESK-049, tabmail-voice #1): cap 10 min (was 120 s); `DictationChunker` cuts mid 1 s pause once a chunk holds 10 s of speech (levels relative to the recording) — ⛔ pause cuts OFF since 2026-10-07 (`chunkCutsAtPauses = false`, code kept; owner: pauses between words/sentences hurt, little speed-up) — else forced at 105 s on the quietest 300 ms with a 15 s-speech overlap (≤ 30 s); `DictationChunkJoin` strips seam ellipses, joins overlap on the longest ≥ 3-word run within 80 words, else whole; `AudioRecorder` `takeChunks`/`onChunk`/`Recording.lastChunk`; `DictationChunkUploads` sends each chunk at once with its own cleanup, retries 5xx/network/504/speech-model 429 (`transcription_rate_limited`) while recording (1, 2, 5, 10 s repeating), the release cuts waits short and gives the usual last tries (now ~1 min, 504 included) + retry note; pastes the chunks up to the first that gave up (first lost → nothing, silent); every chunk sent, no loudness gate; two chunks or more get a final polish of their joined cleanups via `/completions/chat` (`system_prompt_dictate_cleanup`, 5 s cap `chunkPolishTimeout`, else the joined cleanups; owner 2026-10-03); no iOS notice (AI consent covers voice). **2026-10-08: the release's last tries, every chunk and the polish share the one 10 s `transcriptionDeadline` (ADR-IOS-085 amendment).**
```

<!-- END VERBATIM FRAGMENT ADR-IOS-087 -->

---

## Source line 158 — ADR-IOS-088

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-088 -->

```text
- **[ADR-IOS-088](Companion/Decisions/V3/Active/adr-ios-088.md)** — Active. **PDF attachment text (`attachment_read_pdf`) is read by the bundled pdf.js (pdfjs-dist 6.3.289 legacy, byte-identical to the TB add-on's) in a hidden `WKWebView`, not PDFKit**: `PDFTextHost`, one web view per call, `nonPersistent` store, `tabmail-pdf://local/` scheme serves page, script, `pdfjs/` and the PDF at `/document`; a memory bomb ends the WebContent process (`webViewWebContentProcessDidTerminate` → `.failed`, "the PDF could not be read"), not the app; `PDFStreamBudget`/`PDFPageGlyphCounter` deleted, IOS-AI-009/010 resolved; pdf.js in the vulnerability scan (owner 2026-10-04).
```

<!-- END VERBATIM FRAGMENT ADR-IOS-088 -->

---

## Source line 159 — ADR-IOS-089

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-089 -->

```text
- **[ADR-IOS-089](Companion/Decisions/V3/Active/adr-ios-089.md)** — Active. **Device Sync state belongs to one TabMail account** (owner 2026-10-05, "clear on account change"): `DeviceSyncService.ownerUserIdKey` + `claimLocalState(for:)` at the three `installNewSession` sites and in `connect()`; same account keeps everything, no recorded owner adopts, a DIFFERENT account gets `PromptStore.resetForNewAccount()` defaults, `DisabledRemindersStore.removeAllForNewAccount()`, thresholds/per-field `device_sync_ts:*`/backups/auto-enabled removed so it probes as a new device instead of broadcasting the previous account's prompts; `completeSession` disconnects Device Sync on every sign-out (the socket stayed in the old account's room); `DeviceSyncAccountOwnershipTests`.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-089 -->

---

## Source line 160 — ADR-IOS-090

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-090 -->

```text
- **[ADR-IOS-090](Companion/Decisions/V3/Active/adr-ios-090.md)** — Active. **`web_read` reads a page as a user agent, without asking robots.txt** (owner 2026-10-07): robots.txt is for crawlers, and `WebReadTool` fetches one page the user asked for, as a browser does; `checkRobotsTxt`/`isPathAllowed`/`robotsTimeoutSeconds` and `WebReadToolRobotsTests` deleted (the parser matched only `*` or the full user-agent, not the RFC 9309 product token, and a later group cleared the `*` rules). TabMail stays in the User-Agent; backend URL guard unchanged; TB ADR-026, Voice ADR-DESK-030 amendment and the backend tool description change together (ADR-IOS-008 parity); supersedes Voice #45.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-090 -->

---

## Source line 161 — ADR-IOS-091

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-091 -->

```text
- **[ADR-IOS-091](Companion/Decisions/V3/Active/adr-ios-091.md)** — Active. **Drafts written by other mail apps are adopted on open** (#217, owner 2026-10-17: any client, last save wins, no lease): with no local owner, `ServerDraftComposeLoader` → `ExternalDraftAdoption` fetches body + attachments and, in one write transaction that re-proves the exact address, inserts an `adopted:<uuid>` `Draft` (`"pushed"`) owning IMAP folder+UIDVALIDITY+UID / Gmail resource id / Graph id; save replaces and Send deletes exactly that copy; reverses `e0d3d30e`'s "unverified server-origin reopen" SUBTRACT without its Message-ID matching. **Amended:** text comparison (`serverDraftText`, v92, `fetchDraftCopy`, `DraftServerText`: subject, To/Cc/Bcc, attachment names, whitespace-collapsed body), not server revisions; every saved-draft open (`ComposeView.loadDraftOrPrepopulate` → `refreshBeforeOpen`) reloads a clean row whose copy changed and asks Overwrite/Reload/Save as new for unsent edits whose copy changed (Save asks the same); upload refuses a changed copy (`.serverChanged`); Send does not check; the choices advance `pushAttemptVersion`; inline images carried; check-then-write race accepted; round 2: IMAP copy read under the checked selection, demo drafts never compared (`isSharedWithOtherApps`), empty body reloads; attachment names only (#229) and non-address recipient text (#230) accepted. **4th ruling 2026-10-21: LAST SAVE WINS** (#233): the change check, `serverDraftText`/v92, `DraftServerText`, `DraftServerCheck` and the three-choice alerts are deleted; every open of a clean Gmail/Outlook row reloads its server copy with no comparison (`reloadsBeforeOpen`, `ExternalDraftOpenConfig.reloadTimeoutSeconds`); draft-copy reads are COMPLETE or throw (every inline image, IMAP `attachmentData` from the proven read, `completeDraftCopy`); Graph draft update replaces attachments via `/attachments` (PATCH cannot); `IOS-DRAFT-019`/`020`/`021`. **5th ruling 2026-10-21:** drafts upload as plain text (`isHTML: false`) and decode through the ONE converter (`EmailFilter.htmlToPlainText` line rules fixed: br, block open/close, no double blank lines; `editableBody`, CRLF, `(no subject)`); draft reads are the draft not its render (no attached-message text, every Content-ID image, Graph `Prefer` text); Outlook attachments sync by NAME, add before delete, upload session for 3 MiB+ (`replaceDraftAttachments`, `draftAttachmentPlan`, `ExchangeDraftConfig`); same-name edge `IOS-DRAFT-022` (#236); #237 filed; format=flowed text parts decoded on read (#238, `EmailFilter.decodeFormatFlowed`, `isFlowedSoftBreak`, SwiftMail fork keeps `format`/`delsp` in part content types); review round 3: pre-upgrade drafts reload the copy the earlier release uploaded, accepted `IOS-DRAFT-024` (owner dropped migration `v93_openPreUpgradeServerDraftsLocally` before release; v92/v93 burned), IMAP draft part declared non-empty but empty = missing (`draftPartArrived`), uncarriable attachments (item/reference, refused name) refused with `DraftCopyUnsupportedAttachment` and never deleted (#241), Gmail text in its declared charset, trailing typed line breaks accepted `IOS-DRAFT-023`. Review round 4: a quoted `charset="…"` is the declared charset (SwiftMail fork `declaredCharset` reads the MIME parameter, app pin `946ae36`); a failed Graph upload-session PUT rethrows a code-only `URLError` so its `authtoken` URL never reaches the queue log. Review round 5: `htmlToPlainText` ends a block only on a line holding something visible, a no-break space included (`<p>&nbsp;</p>` blank lines from TinyMCE/CKEditor/Word HTML), and a draft's text passes `keepingSpacing: true` (each `&nbsp;` a space, `<pre>` whitespace as written, no space at inline tags/links); Gmail draft parts are classified by disposition first (an attached `f_` Content-ID image keeps its name) and a file whose bytes came in `body.data` is carried in `attachmentData`. Review round 6: a Gmail file part with children and no bytes/attachment id is refused (`DraftCopyUnsupportedAttachment`), never a 0-byte file; an adopted reply's key carries its parent's `{accountId}:{stableId}` (`adopted:<uuid>:…`, `ExternalDraftAdoption.adoptedKey`, `Draft.replyKeyTail`) so Strategy 2 finds the original after an IMAP move. Review round 7: adopted rows insert at eviction rank `lastTouchedSeq = 0`, below every draft saved here, so opening other apps' drafts never evicts an unsent local draft. Codex round 1: Graph attachment lists follow `@odata.nextLink` (`ExchangeProvider.listAttachments`, bounded by `maxAttachmentListPages`, never acting on part of a list); a whitespace-only body opens as written; `format`/`delsp` read via SwiftMail `MessagePart.contentTypeParameter(named:)`; fork `c86900c` quotes non-token BODYSTRUCTURE values; pre-wrap and link-label spacing moved to #251. Codex round 2: Gmail empty `data` + `attachmentId` fetched by id (`draftPartBytes`); literal "(no subject)" kept (`keepEmptySubject`, placeholder compare deleted); draft text via `MessagePart.draftTextContent` (declared charset or UTF-8, else refused; #257); Graph last upload range must be 201; fork `9ceb96b`; HTML cases to #251 (now SwiftSoup, no WebKit). Codex round 3: IMAP draft files take the fetched part's name; a Gmail copy replaced since listing is refused on adoption, and a reload whose copy replies to a different known parent deletes the clean row (`repliesElsewhere`, `OpenCheck.replacedElsewhere`); `draftTextContent` declared charset only (no UTF-8 guess); flowed prefix as scalars; Graph draft inline images carried as named files (#241 refusal applies); fork `3a0cdf7`. Codex round 4: `repliesElsewhere` resolves the row's parent as Send does (`resolveReplyToHeader`, follows a moved parent) and an uncorroborated claimed parent is not agreement; single-POST limit exclusive; #272 (two plain alternatives doubled, P4, in train), #273 (staging cleanup test, P5). Codex round 5: eviction and the resolver read the key's parent as scalars (`Draft.replyKeyParent`, adopted keys included); flowed soft-break space as a scalar; IMAP/Gmail parts shorter than their declared size refused; #276 (CID text body), #277 (RFC 2231 params), #278 (reply replaced by standalone) filed P4, in train. Codex round 6: flowed signature separator recognised before delsp drops the marker; every Gmail draft file read whole with the draft and every part size-checked by either route. Codex round 7: mixed text + HTML pieces keep only the HTML -> #272 (needs SwiftMail grouping); attachment-refusal Close covered by `ServerDraftCloseUITests`. #272 Gmail half: one alternative read (the last with body text), every other multipart's pieces in order; mixed text + HTML converted per piece (`DraftBodyPiece.body`).
```

<!-- END VERBATIM FRAGMENT ADR-IOS-091 -->

---

## Source line 162 — ADR-IOS-092

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-092 -->

```text
- **[ADR-IOS-092](Companion/Decisions/V3/Active/adr-ios-092.md)** — Active. **Compose recipient fields are lists of addresses, never free text** (owner 2026-10-18): `RecipientEntry` splits typed/pasted (on `,` `;` newline, and spaces/tabs after an address since a single-line field flattens a pasted column), contact pick (unsendable → input line), prefill, reopened-draft, reply (`RecipientEntry.reply(to:)`, every Reply-To mailbox), AI-edit and reply-all (unsendable Reply-To text → input line) text with SwiftMail's address-list parser into one chip per `isValidEmailAddress` mailbox; groups flattened, duplicates dropped, cap overflow stays in input (AI clear/removal covers it); text naming no address (empty group, lone comment included) stays in the input line as written, and Send refuses it (`ComposeDraftGuards.sendRecipients`, also Send's cap); drafts still store leftover text; `sendableRecipients` expands a legacy queued "a, b" recipient; `extractEmailAddress` deleted; the three fields are one `ComposeDraftGuards.Recipients` value (role mapping tested). Overrides the 2026-10-03 "drafts keep recipients as typed" rule for the compose UI; `replyRecipients` deleted. Amendment 2026-10-19: split FIRST, then read; never replace an entry with a decoded/rewritten form (invalid-entry decode, AI `parseDeltaForField` pre-parser, contact-pick name wrapping, `MailtoRequest` comma split #223, reply-tool raw removals, over-cap name loss; `RecipientSplitFirstTests`). Amendment 2026-10-19 (owner): text naming no sendable address is a RED CHIP per entry (`RecipientField.rejected`), never joined to other text (t2r6: two rejected entries joined in the input line formed a new recipient and sent); tap moves it to the input line (`editingRejected`), Send refuses while any exist, drafts store each as written; quote-aware split point `RecipientEntry.lastSeparator`; `sendableRecipients` refuses a decoded-empty invalid part. t2r7 2026-10-20: rejected text kept as WRITTEN (not the parse form with synthetic commas), both scanners read Unicode SCALARS (quote + combining mark), `splitAtLastSeparator`, empty group beside a mailbox refused at send, hosted `TokenFieldBehaviourTests`. t2r8 2026-10-20: draft placeholder header/FTS = `RecipientEntry.headerText` (addresses only, never raw-joined arrays; Reply All on a saved draft could invent a recipient or leak Bcc), `RecipientTokenField` + `Recipients.replace(with:showCc:)` = the one compose state write, hosted-tested.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-092 -->

---

## Source line 163 — ADR-IOS-093

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-093 -->

```text
- **[ADR-IOS-093](Companion/Decisions/V3/Active/adr-ios-093.md)** — Active. **Email search query text reaches FTS5 as text** (#246, port of native-fts ADR-NF-011 #14/#31): `SearchQueryParser.buildFTSMatch` ports `build_fts_match` — every word/phrase an FTS5 string, capital AND/OR/NOT only between terms, `searchMaxKeptNots` 100, both apostrophe spellings `("don't" OR "dont"*)`, possessive strip, prefix star per run from 4 UTF-8 bytes, only subject/from/to/cc/bcc/body scope (`msgId:` and `from :` no longer); fixes `fts5: syntax error` on `50% off`, `R&D`, `NOT budget`, `"jane doe" meeting`.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-093 -->

---

## Source line 164 — ADR-IOS-094

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-094 -->

```text
- **[ADR-IOS-094](Companion/Decisions/V3/Active/adr-ios-094.md)** — Active. **A search sorts before it takes its limit** (tabmail-ios#265, port of native-fts #46 / ADR-NF-017): `SearchSort` relevance (tool default) / date_desc / date_asc through `SearchIndex.search`/`hybridSearch`; ties in `HybridMerge.mergeResults` (relevance newer first, date better match first, then rowid; undated candidate left out; vector-only dates via `SearchIndex.fetchDates` json_each); date sort reads `SearchConfig.dateSortPool` 4,096 per leg (sqlite-vec max k); field-only query (`queryIsFieldOnly`) keyword-only over all matches, newest first under relevance; `searchFTSOnly` and the `*` date scan follow the sort; memory merge ties newer first; `EmailSearchTool` passes the sort, no post-fetch sort, unknown sort = relevance (as TB #150); `keywordSearch` (SearchView typing) unchanged newest first.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-094 -->

---

## Source line 165 — ADR-IOS-095

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-095 -->

```text
- **[ADR-IOS-095](Companion/Decisions/V3/Active/adr-ios-095.md)** — Active. **Every search fetches 100, in pages of 20 where it pages** (tabmail-ios#264, TB `CHAT_SETTINGS` parity, owner 2026-10-22): `email_search` `maxResults` 100 (was 50) pages of 20; `memory_search` one fetch of `SearchConfig.memorySearchMaxResults` 100 in pages of `memorySearchPageSize` 20 (was 5 x 4 = 20 in pages of 5; `memoryPrefetchPagesDefault`/`memoryPrefetchMaxResults`/`memoryPageSizeDefault`/`memoryPageSizeMax` deleted); ChatHistoryView listing and search 100 (was 200), no paging; `searchDefaultLimit` 100 (was 50, inbox SearchView); past the last page = last page, agent narrows.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-095 -->
