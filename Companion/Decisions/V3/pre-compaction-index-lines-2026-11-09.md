# Pre-compaction index lines — `DECISIONS.md` (2026-11-09 pass)

**Status:** Historical (preserved source text) · **Routed:** 2026-11-09 `companion-compact` · **Source:** `tabmail-ios/DECISIONS.md` at `6597c3a7`

`tabmail-ios/DECISIONS.md` was **31150 B against its 25,000 B budget**: catalog rows and v3
bullets had regrown amendment detail inline. Each line below was replaced in the index by a
shorter line and is kept here **byte-for-byte**, in source order. Lines 20-27 are the four-exit
enumeration the section itself marks historical ("The earlier enumeration below is historical");
the normative statement is `Companion/Rules/Active/never-drop-user-intention.md`, and the
always-loaded `CLAUDE.md` § *Core Philosophy* still carries it in full. **The linked ADR bodies
are the normative records**; this pass did not touch them. Fragments are fenced so their
index-relative links are not re-resolved from this directory (`MIS-IOS-009`).

---

## Source lines 20-27 — Foundational principle, historical four-exit enumeration

<!-- BEGIN VERBATIM LINES 20-27 -->

```text
**A queued operation may leave the queue for exactly FOUR reasons — and no others** (ADR-IOS-067 as amended by ADR-IOS-069, commit `3843940cb`):

1. **Provider success.**
2. **A provider-authoritative stale/no-op result** — the provider told us the work is already done or no longer applicable. *"We could not determine the answer" is NOT this.* A thrown read, an unresolvable identity, a failed durable write and an **unknown** epoch are all **retryable**, never authoritative.
3. **Annihilation by a newer inverse user action** — only when the earlier operation was **never attempted**, the members match **exactly**, and the new action is a true inverse.
4. **Invalidation by an id reset in its own address space** — a **proven** UIDVALIDITY turnover, or a provider stable-id reset, drops every queued op that named an address in the affected space: not rebound, not re-resolved, not re-searched, not quarantined, not retried under the new numbering. v3 compares an op against its **durable** `PendingOperation.observedUidValidity`, not a selection minted inside the same call, so once the folder's epoch provably moves **every retry of that op fails identically and forever** — dropped rather than executed under numbering it never observed. Governing principle **C3: no action may ever mutate the wrong message; failing closed is always acceptable.** Registered as `IOS-EPOCH-001` / `IOS-ACTION-002` in `KNOWN_ISSUES.md`.

**Exit 4 does not widen clause 2.** Exit 4 requires a **proven** epoch change — a *positive* fact, an epoch the server actually reported that disagrees with the one the op durably recorded. Clause 2's *unknown* epoch is its opposite — an **absence of evidence** — and stays retryable forever. The two are disjoint. Exit 4 is the only exit that is a failure, it is deliberately narrow, and **nothing else may use it**. A bounded, visible, retryable quarantine is **not** a discard, and a transient failure is **not** an exit. The carve-out does not extend past queue state: Outbox sends, user-authored drafts, bodies, attachments and FTS content are never dropped under it.
```

<!-- END VERBATIM LINES 20-27 -->

---

## Source lines 74-74 — ADR-IOS-029

<!-- BEGIN VERBATIM LINES 74-74 -->

```text
| ADR-IOS-029 | Active; rule 5 TIMING amended 2026-08-05, requirement unchanged | Database Index Management — Purpose-Built Indexes, Drop What's Superseded. `ANALYZE` moved OFF migration bodies to `SyncEngine.runRefreshPlannerStatisticsIfStale`, re-armed by `PRAGMA schema_version`, run from background WAL maintenance | [read in full](Companion/Decisions/Active/adr-ios-029.md) |
```

<!-- END VERBATIM LINES 74-74 -->

---

## Source lines 77-77 — ADR-IOS-032

<!-- BEGIN VERBATIM LINES 77-77 -->

```text
| ADR-IOS-032 | Partially superseded by 034; Swift stack retained, session-document model replaced; amended 2026-10-21: empty merge with keyword matches answers keyword-only (#240, native-fts #28); amended 2026-10-22: vector search only within the dates and the field via sqlite-vec `rowid IN` (#242, native-fts #26); amended 2026-10-23: memory merge ties newer first (#265, ADR-IOS-094); amended 2026-10-24: every keyword match is a result, minScore gates meaning-only candidates, empty-merge fallback deleted (#304, native-fts #51) | Memory Search Reuses iOS Swift Hybrid FTS Stack (No Rust FFI) | [read in full](Companion/Decisions/Active/adr-ios-032.md) |
```

<!-- END VERBATIM LINES 77-77 -->

---

## Source lines 81-81 — ADR-IOS-038

<!-- BEGIN VERBATIM LINES 81-81 -->

```text
| ADR-IOS-038 | Active | Demo Mode — Custom JWT + Local Mock Provider + Pre-Baked AI Cache; amended 2026-10-21: guided tutorial (scripted, no AI, no consent screens, isTutorialPractice, TutorialChatScript), demo re-tag never teaches, tips hidden in demo; 2026-10-21 replay in debug menu, practice reply no undo hold, HUD card; 2026-10-25 parts found on their own count as done (TutorialDiscovery: tag tap + retag, template, inbox chat); round 3 TutorialPulseRing moving hints, no Finish later, See rule sample delete rule mock, scripted compose edit (useSuggestion lock); round 4 tutorialLockedNavigation, open chat covers the card, highlightsChatClose, one hint at a time; round 5 Create and sheet Done rings, TutorialInboxScroll re-scrolls on list relayout (one-shot scroll dropped on device); c1 review: scripted edit bound to its demo run (chatAdmission), Replay refused while a demo start is in progress; c2 review: demo outbox drains offline, completeSetup stops once its demo run ended (no prompt overlay after exit), view-hook test gap accepted (IOS-TEST-012); c3 review: End withdraws a start not yet active, notification tap ends the tutorial from RootView (splash, finish page), orientation error handler @Sendable (background-queue refusal trapped); c4 review: three more view hooks accepted (IOS-TEST-012, eight hooks), test host answers notification permission silently, splash setup task keyed by demo run (chatAdmission; a quick end and restart kept the old splash and never set up); 2026-10-31 demo switch = one prompt-semaphore hold (enterDemo/leaveDemo, counter moves, overlay + demo reminder map in the hold), multi-step writers carry the change counter and are refused if it moved ("switch drops in-flight"), required demo: params and DemoFlagReadSitesTests deleted; round 2: tap-time sampling (install, compact rules), modeSnapshot pair, absolute waiter deadline, toggle no early return | [read in full](Companion/Decisions/Active/adr-ios-038.md) |
```

<!-- END VERBATIM LINES 81-81 -->

---

## Source lines 83-83 — ADR-IOS-040

<!-- BEGIN VERBATIM LINES 83-83 -->

```text
| ADR-IOS-040 | Active; point 4 (intro-offer trial gating: `checkTrialEligibility`, PlanCard trial badge) deleted 2026-08-19 with issue #55 — ASC offers removed, server signup trial is the only trial; amended 2026-11-03: Zero gets the same App Store free-trial offer as Basic/Pro ("Zero never has a trial" superseded), subscribing to any plan resets the trial; trial banner always says "Subscribing ends this trial and starts a new 7-day free trial." | Zero (BYOK) Plan in the IAP Plan Picker — Three-Tier, Display-Only Naming | [read in full](Companion/Decisions/Active/adr-ios-040.md) |
```

<!-- END VERBATIM LINES 83-83 -->

---

## Source lines 127-127 — Post-v1.6.38 preamble

<!-- BEGIN VERBATIM LINES 127-127 -->

```text
Authored after `v1.6.38`, so they have no byte-identical twin: their bodies live outside `Companion/Decisions/{Active,Superseded,Deferred}/` (the census surface that reconstructs `v1.6.38:DECISIONS.md`), with provenance and `sha256` in [`Companion/Decisions/V3/manifest.tsv`](Companion/Decisions/V3/manifest.tsv). Earlier wording of these lines, byte-for-byte: [`pre-compaction-index-lines.md`](Companion/Decisions/V3/pre-compaction-index-lines.md), [`…-078-079.md`](Companion/Decisions/V3/pre-compaction-index-lines-078-079.md), [`…-2026-09-06.md`](Companion/Decisions/V3/pre-compaction-index-lines-2026-09-06.md), [`…-2026-10-24.md`](Companion/Decisions/V3/pre-compaction-index-lines-2026-10-24.md).
```

<!-- END VERBATIM LINES 127-127 -->

---

## Source lines 155-155 — ADR-IOS-085

<!-- BEGIN VERBATIM LINES 155-155 -->

```text
- **[ADR-IOS-085](Companion/Decisions/V3/Active/adr-ios-085.md)** — Active. Chat-pill dictation = TabMail Voice's backend speech-to-text + cleanup (`POST /dictation/transcribe`, `DictationController`), not `SFSpeechRecognizer`. Amended 2026-10-29: Opt Out of AI dictates on-device (`OnDeviceSpeechRecognizer`); amended 2026-10-31: the pill's auto-start (Auto-Enable Dictation) starts it only when speech recognition + microphone are already granted, else does nothing.
```

<!-- END VERBATIM LINES 155-155 -->

---

## Source lines 161-161 — ADR-IOS-091

<!-- BEGIN VERBATIM LINES 161-161 -->

```text
- **[ADR-IOS-091](Companion/Decisions/V3/Active/adr-ios-091.md)** — Active. Drafts written by other mail apps are adopted on open (#217, last save wins, no lease): `ServerDraftComposeLoader`, `ExternalDraftAdoption`, `adopted:<uuid>`; opens are prepared before the compose shows, no blank frame (#309, `DraftOpenPreparation`); the cover opens at once with a spinner inside, no busy row mark (#326, `DraftOpeningView`); new Outlook drafts upload large attachments through sessions (#237); Outlook sends with attachments go draft + `/send`, not inline `sendMail` (#422); single-POST threshold stays 3 MiB binary megabyte, live 3,100,000-byte check accepted on both routes, `GraphAttachmentLimits` test edges (#433).
```

<!-- END VERBATIM LINES 161-161 -->

---

## Source lines 163-163 — ADR-IOS-093

<!-- BEGIN VERBATIM LINES 163-163 -->

```text
- **[ADR-IOS-093](Companion/Decisions/V3/Active/adr-ios-093.md)** — Active. Search query text reaches FTS5 as text (#246, ADR-NF-011): `SearchQueryParser.buildFTSMatch` quotes every word; fixes `fts5: syntax error`. Amended 2026-10-24 (#301, ADR-NF-019): a kept `NOT` answers by keyword only (`queryExcludes`); the vector filter splits at each `OR`.
```

<!-- END VERBATIM LINES 163-163 -->

---

## Source lines 164-164 — ADR-IOS-094

<!-- BEGIN VERBATIM LINES 164-164 -->

```text
- **[ADR-IOS-094](Companion/Decisions/V3/Active/adr-ios-094.md)** — Active. A search sorts before its limit (#265, ADR-NF-017): `SearchSort`, `HybridMerge.mergeResults` ties, `SearchConfig.dateSortPool`. Amended 2026-10-24: the backend reads `TABMAIL_PROTOCOL_VERSION` (now 1.10.0), not the marketing version.
```

<!-- END VERBATIM LINES 164-164 -->

---

## Source lines 167-167 — ADR-IOS-097

<!-- BEGIN VERBATIM LINES 167-167 -->

```text
- **[ADR-IOS-097](Companion/Decisions/V3/Active/adr-ios-097.md)** — Active. A date-sorted search walks date windows so it is exact past the 4,096 pool (#294, ADR-NF-023, native-fts #47): `dateWindowCandidates`, `vecDistancesWithin`, `knnCandidates`; amends ADR-IOS-094; typing path `keywordSearch` untouched.
```

<!-- END VERBATIM LINES 167-167 -->

---

## Source lines 168-168 — ADR-IOS-098

<!-- BEGIN VERBATIM LINES 168-168 -->

```text
- **[ADR-IOS-098](Companion/Decisions/V3/Active/adr-ios-098.md)** — Active. Device Sync v2: KB, composition and action rules sync as labelled bullets (observed-remove; `device_sync_bullets`, `BulletSync`, `PromptBulletSync`, default catalog, `bullet_state` parts); one door `PromptStore.withPromptStore` with a first-in-first-out `PromptSemaphore`, displayed removal, AI read-call-write with a change counter, arrival-order receive with a bound counting held parts; R23 marker guard in `ActionPatchApplier`; TB ADR-028; #341-#344.
```

<!-- END VERBATIM LINES 168-168 -->

---

## Source lines 169-169 — ADR-IOS-099

<!-- BEGIN VERBATIM LINES 169-169 -->

```text
- **[ADR-IOS-099](Companion/Decisions/V3/Active/adr-ios-099.md)** — Active. One anonymous trial-feedback sheet after the signup trial ends: `TrialFeedback.shouldPresent`, `trialFeedbackAutoOpen(isInbox:)` (inbox on screen only), one `trialFeedbackSheetHost()` at the mail root, asked flag set on appear, never over another sheet, trial-ended inbox row Feedback and folder-list "Tell us why" (layout C `trialEndedBanner`: See Plans filled capsule, no chevron) hidden once `trial_feedback_sent`, `{version, reason, comment?}` to the forms worker, 500 code-point cap `TrialFeedbackForm.edit` (scalar-exact `ExactText`); inbox Plans filled capsule, Feedback gray capsule; App Store privacy label declares it as User Content > Other User Content, Not Linked to You, Analytics (published by the owner 2026-11-03).
```

<!-- END VERBATIM LINES 169-169 -->

---

## Source lines 170-170 — ADR-IOS-100

<!-- BEGIN VERBATIM LINES 170-170 -->

```text
- **[ADR-IOS-100](Companion/Decisions/V3/Active/adr-ios-100.md)** — Active. Compose Send with an empty body and a visible AI suggestion accepts the suggestion and sends with no "Empty Body" prompt: `ComposeDraftGuards.sendTap` / `SendTap`, typed body never merged with the suggestion, blank suggestion still prompts, tutorial Use Suggestion lock honoured, dead "Use Suggestion & Send" alert button deleted (#384).
```

<!-- END VERBATIM LINES 170-170 -->

---

## Source lines 171-171 — ADR-IOS-101

<!-- BEGIN VERBATIM LINES 171-171 -->

```text
- **[ADR-IOS-101](Companion/Decisions/V3/Active/adr-ios-101.md)** — Active. Dictation context terms = words a shipped word-frequency list (FrequencyWords counts, 41 languages merged, `TabMail/Vendor/wordlist`, `WordList` over a memory-mapped sorted file, off the main thread) sees below Zipf 35; a script no list covers needs a capital; each word alone; no preferred languages; same rule as Voice; replaces the `UITextChecker` rule of #397 (amends ADR-IOS-086 decision 2; #383, #398).
```

<!-- END VERBATIM LINES 171-171 -->

---

## Source lines 172-172 — ADR-IOS-102

<!-- BEGIN VERBATIM LINES 172-172 -->

```text
- **[ADR-IOS-102](Companion/Decisions/V3/Active/adr-ios-102.md)** — Active. Package versions pinned by a tracked root `Package.resolved` copied into the generated project by `Scripts/xcodegen.sh`; NIOSSL 2.37.6; reverses IOS-BUILD-002 "unpinned" (SPM, dependency pinning, reproducible build, BoringSSL revision, Package.resolved gitignore).
```

<!-- END VERBATIM LINES 172-172 -->
