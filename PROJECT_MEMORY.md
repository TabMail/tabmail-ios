# TabMail iOS - Project Memory

> **iOS-specific knowledge.** Claude reads this before every task and updates it when discovering something new. For cross-cutting knowledge, see `../PROJECT_MEMORY.md`.

**Last updated:** 2026-08-02

---

## How to use this index

**This file is a router, not an archive.** Every topic below is preserved in full under
[`Companion/Memory/`](Companion/Memory/manifest.tsv); the manifest carries a `sha256` per fragment.
Load only the topics your task mechanically matches.

1. Build search terms from the request, named files/symbols, subsystem, provider, invariant, and likely defect class.
2. Run `rg -ni '<terms>' PROJECT_MEMORY.md DECISIONS.md MISTAKES.md Companion/` and a code census with `rg`.
3. Read each matched detailed topic, ADR, process, rule, and mistake document completely before acting.
4. Record every required routed path in any plan, implementation brief, or review prompt.
5. Update the relevant detail file and its index row when durable knowledge changes; do not grow this file into an unconditional archive.

Current entries govern. Historical entries preserve evidence but do not override current rules or active ADRs.
Do not use Markdown imports as a context shortcut; imported text still consumes startup context.

## Current topics

Search the topic text below as subsystem keywords. Each link is mandatory when its row matches the task.

| Topic / search terms | Detail |
|---|---|
| Key Files | [read in full](Companion/Memory/Current/001-key-files.md) |
| Inbox list = ONE merged read-model (ADR-IOS-055, 2026-07-09 evening) — supersedes the same-day guard/carry-over fixes | [read in full](Companion/Memory/Current/002-inbox-list-one-merged-read-model-adr-ios-055-2026-07-09-evening-supersed.md) |
| Summary `recipient_status` (cc detection) — 2026-07-04 | [read in full](Companion/Memory/Current/003-summary-recipient-status-cc-detection-2026-07-04.md) |
| IMAP external-deletion blind spot — old server-deleted messages linger forever (audit 2026-07-02) | [read in full](Companion/Memory/Current/004-imap-external-deletion-blind-spot-old-server-deleted-messages-linger-for.md) |
| CLI testing breaks with "Simulator device failed to launch / Launchd job spawn failed" → app is UNSIGNED in DerivedData (2026-06-22) | [read in full](Companion/Memory/Current/005-cli-testing-breaks-with-simulator-device-failed-to-launch-launchd-job-sp.md) |
| Test flakiness: `UserDefaults(suiteName:)` isolation FALLS THROUGH to `.standard` — isolating a suite's WRITES is necessary but not sufficient (2026-06-22) | [read in full](Companion/Memory/Current/006-test-flakiness-userdefaults-suitename-isolation-falls-through-to-standar.md) |
| Foreground-return UI freeze — main-actor DB ops must not block (2026-06-21) | [read in full](Companion/Memory/Current/007-foreground-return-ui-freeze-main-actor-db-ops-must-not-block-2026-06-21.md) |
| OAuth / Google Cloud | [read in full](Companion/Memory/Current/008-oauth-google-cloud.md) |
| Architecture Patterns | [read in full](Companion/Memory/Current/009-architecture-patterns.md) |
| Email image aspect-ratio distortion — gated post-load correction (2026-06-26) | [read in full](Companion/Memory/Current/010-email-image-aspect-ratio-distortion-gated-post-load-correction-2026-06-2.md) |
| IMAP Connection Pool (supersedes ADR-IOS-014) | [read in full](Companion/Memory/Current/011-imap-connection-pool-supersedes-adr-ios-014.md) |
| ProviderWorkQueue Cancellation Semantics (2026-06-09) | [read in full](Companion/Memory/Current/012-providerworkqueue-cancellation-semantics-2026-06-09.md) |
| FTS Tokenizer — NO tokenchars (ADR-024, 2026-06-09, lockstep with Rust crate) | [read in full](Companion/Memory/Current/013-fts-tokenizer-no-tokenchars-adr-024-2026-06-09-lockstep-with-rust-crate.md) |
| SwiftUI preview convention | [read in full](Companion/Memory/Current/014-swiftui-preview-convention.md) |
| Inbox usage-throttle banner (ADR-IOS-044) | [read in full](Companion/Memory/Current/015-inbox-usage-throttle-banner-adr-ios-044.md) |
| Remote Search (SearchView) | [read in full](Companion/Memory/Current/016-remote-search-searchview.md) |
| FTS↔GRDB id drift (folder baked into the key) — "indexed but unfindable" / wrong-subject class | [read in full](Companion/Memory/Current/017-fts-grdb-id-drift-folder-baked-into-the-key-indexed-but-unfindable-wrong.md) |
| "Searchable but can't open / no snippet / not in its folder" — GRDB-side stuck headers (NOT FTS orphans), IMAP (under investigation 2026-06-22) | [read in full](Companion/Memory/Current/018-searchable-but-can-t-open-no-snippet-not-in-its-folder-grdb-side-stuck-h.md) |
| Stale-detection window MUST match the fetch's ordering dimension — IMAP Archive "missing months" data-loss (CONFIRMED ROOT CAUSE + FIXED 2026-06-23) | [read in full](Companion/Memory/Current/019-stale-detection-window-must-match-the-fetch-s-ordering-dimension-imap-ar.md) |
| GRDB Persistence | [read in full](Companion/Memory/Current/020-grdb-persistence.md) |
| GRDB ValueObservation — DO NOT put on `messageHeader` | [read in full](Companion/Memory/Current/021-grdb-valueobservation-do-not-put-on-messageheader.md) |
| AI Priority Processing (ADR-IOS-013) | [read in full](Companion/Memory/Current/022-ai-priority-processing-adr-ios-013.md) |
| IMAP Message IDs & UID Resolution | [read in full](Companion/Memory/Current/023-imap-message-ids-uid-resolution.md) |
| iOS Keychain Persistence | [read in full](Companion/Memory/Current/024-ios-keychain-persistence.md) |
| Persistent Offline Action Queue (ADR-IOS-003, ADR-IOS-018) | [read in full](Companion/Memory/Current/025-persistent-offline-action-queue-adr-ios-003-adr-ios-018.md) |
| Progressive Backfill & Storage Budget (ADR-IOS-005, ADR-IOS-006) | [read in full](Companion/Memory/Current/026-progressive-backfill-storage-budget-adr-ios-005-adr-ios-006.md) |
| Backfill diagnostics: `backfill.log` channel (2026-07-02) | [read in full](Companion/Memory/Current/027-backfill-diagnostics-backfill-log-channel-2026-07-02.md) |
| Backfill stall fixes (2026-07-02) — UID-remap re-key, no fast-sync cursor reset, persisted server limit | [read in full](Companion/Memory/Current/028-backfill-stall-fixes-2026-07-02-uid-remap-re-key-no-fast-sync-cursor-res.md) |
| `bodyComplete` = FTS-indexed truth; display cache has NO flag (ADR-IOS-050, 2026-07-02) | [read in full](Companion/Memory/Current/029-bodycomplete-fts-indexed-truth-display-cache-has-no-flag-adr-ios-050-202.md) |
| Backfill / Fast Sync Completion — gate on `pendingBodyCount`, NEVER a server total | [read in full](Companion/Memory/Current/030-backfill-fast-sync-completion-gate-on-pendingbodycount-never-a-server-to.md) |
| Ever-Rolling FIFO Queues (ADR-IOS-027) | [read in full](Companion/Memory/Current/031-ever-rolling-fifo-queues-adr-ios-027.md) |
| Bounded Memory (CRITICAL) | [read in full](Companion/Memory/Current/032-bounded-memory-critical.md) |
| Optimistic UI Rollback | [read in full](Companion/Memory/Current/033-optimistic-ui-rollback.md) |
| Gmail Label System | [read in full](Companion/Memory/Current/034-gmail-label-system.md) |
| SwiftUI Observable Array Mutation Safety | [read in full](Companion/Memory/Current/035-swiftui-observable-array-mutation-safety.md) |
| SwiftUI Layout Gotchas | [read in full](Companion/Memory/Current/036-swiftui-layout-gotchas.md) |
| HTML Email Render Pipeline (AutoSizingHTMLView) — MUST stay idempotent (ADR-IOS-039) | [read in full](Companion/Memory/Current/037-html-email-render-pipeline-autosizinghtmlview-must-stay-idempotent-adr-i.md) |
| Swift Gotchas | [read in full](Companion/Memory/Current/038-swift-gotchas.md) |
| Folder.== must include every UI-visible field | [read in full](Companion/Memory/Current/039-folder-must-include-every-ui-visible-field.md) |
| IMAP Folder Role Detection & Dedup (iCloud "Trash" + "Deleted Messages") | [read in full](Companion/Memory/Current/040-imap-folder-role-detection-dedup-icloud-trash-deleted-messages.md) |
| Two-Tier Sync (ADR-IOS-009) | [read in full](Companion/Memory/Current/041-two-tier-sync-adr-ios-009.md) |
| `syncStartup` Budget Discipline (v50/v51 lesson) | [read in full](Companion/Memory/Current/042-syncstartup-budget-discipline-v50-v51-lesson.md) |
| Stale Message Detection (syncMessages) | [read in full](Companion/Memory/Current/043-stale-message-detection-syncmessages.md) |
| Benign Sync Log Noise — DraftUpsertSkip + Gmail 429 (diagnosed 2026-06-09) | [read in full](Companion/Memory/Current/044-benign-sync-log-noise-draftupsertskip-gmail-429-diagnosed-2026-06-09.md) |
| Transient provider HTTP errors must NOT surface as a sync failure — `SyncEngine.isTransientError` (2026-06-17) | [read in full](Companion/Memory/Current/045-transient-provider-http-errors-must-not-surface-as-a-sync-failure-syncen.md) |
| Raw NIO error types must be added to `isConnectionError` by NSError DOMAIN, not substring (2026-07-04) | [read in full](Companion/Memory/Current/046-raw-nio-error-types-must-be-added-to-isconnectionerror-by-nserror-domain.md) |
| ICS Calendar Import — Invisible SFSafariViewController Hack | [read in full](Companion/Memory/Current/047-ics-calendar-import-invisible-sfsafariviewcontroller-hack.md) |
| Attachment Support | [read in full](Companion/Memory/Current/048-attachment-support.md) |
| Compose AI Suggestion — chat pill edits suggestion in place when bubble is visible | [read in full](Companion/Memory/Current/049-compose-ai-suggestion-chat-pill-edits-suggestion-in-place-when-bubble-is.md) |
| Compose body — caret-aware scroll, NO input gating | [read in full](Companion/Memory/Current/050-compose-body-caret-aware-scroll-no-input-gating.md) |
| Compose Attachments | [read in full](Companion/Memory/Current/051-compose-attachments.md) |
| SwiftMail Types | [read in full](Companion/Memory/Current/052-swiftmail-types.md) |
| Outgoing email header encoding — RFC 2047 (mojibake fix, 2026-06-21) | [read in full](Companion/Memory/Current/053-outgoing-email-header-encoding-rfc-2047-mojibake-fix-2026-06-21.md) |
| Hybrid FTS5 + Vector Search (Local) | [read in full](Companion/Memory/Current/054-hybrid-fts5-vector-search-local.md) |
| Device Prompt Sync & AI Cache Probe | [read in full](Companion/Memory/Current/055-device-prompt-sync-ai-cache-probe.md) |
| Cross-Instance Action Tag Sync (ADR-IOS-036, supersedes ADR-IOS-004 "First Compute Wins") | [read in full](Companion/Memory/Current/056-cross-instance-action-tag-sync-adr-ios-036-supersedes-adr-ios-004-first.md) |
| AI Summary & Action Pipeline | [read in full](Companion/Memory/Current/057-ai-summary-action-pipeline.md) |
| Background AI Processing (Tier 3) | [read in full](Companion/Memory/Current/058-background-ai-processing-tier-3.md) |
| Swift 6 BGTask Isolation Pattern (ADR-IOS-020) — CRITICAL | [read in full](Companion/Memory/Current/059-swift-6-bgtask-isolation-pattern-adr-ios-020-critical.md) |
| SSE Streaming & Tool Execution Loop | [read in full](Companion/Memory/Current/060-sse-streaming-tool-execution-loop.md) |
| Thread (ThreadGroup) Actions — tag-tap dispatch & grouped undo | [read in full](Companion/Memory/Current/061-thread-threadgroup-actions-tag-tap-dispatch-grouped-undo.md) |
| Manual Tag Teaching (Long-Press Context Menu) | [read in full](Companion/Memory/Current/062-manual-tag-teaching-long-press-context-menu.md) |
| Tool Registry (Scaffold) | [read in full](Companion/Memory/Current/063-tool-registry-scaffold.md) |
| Agent Chat (ADR-IOS-022, ADR-IOS-023) | [read in full](Companion/Memory/Current/064-agent-chat-adr-ios-022-adr-ios-023.md) |
| Screen Keep-Awake (chat pill) | [read in full](Companion/Memory/Current/065-screen-keep-awake-chat-pill.md) |
| Agent Compose FIFO Queue (ADR-IOS-030) | [read in full](Companion/Memory/Current/066-agent-compose-fifo-queue-adr-ios-030.md) |
| Outgoing Threading — reply/forward stay in-thread on every provider (ADR-IOS-043, 2026-06-23) | [read in full](Companion/Memory/Current/067-outgoing-threading-reply-forward-stay-in-thread-on-every-provider-adr-io.md) |
| Incoming Thread Detection — `ThreadDetection.findRelatedMessages` has NO subject-based fallback (by design) | [read in full](Companion/Memory/Current/068-incoming-thread-detection-threaddetection-findrelatedmessages-has-no-sub.md) |
| Outbox — Persistent Offline Send Queue (ADR-IOS-019) | [read in full](Companion/Memory/Current/069-outbox-persistent-offline-send-queue-adr-ios-019.md) |
| Proactive Local Notifications (ADR-IOS-026) | [read in full](Companion/Memory/Current/070-proactive-local-notifications-adr-ios-026.md) |
| App Icon Badge Routine (NSE counter + main-app recount) | [read in full](Companion/Memory/Current/071-app-icon-badge-routine-nse-counter-main-app-recount.md) |
| Persistent NSE log file + watchdog partial-result delivery (2026-07-09) | [read in full](Companion/Memory/Current/072-persistent-nse-log-file-watchdog-partial-result-delivery-2026-07-09.md) |
| Sync-status subtitle ("Updated N min ago") | [read in full](Companion/Memory/Current/073-sync-status-subtitle-updated-n-min-ago.md) |
| Stuck-`isLoading` rule: async view loads must defer-clear their spinner flag — and `.task` must NOT hang on the conditional it flips | [read in full](Companion/Memory/Current/074-stuck-isloading-rule-async-view-loads-must-defer-clear-their-spinner-fla.md) |
| Cron Reminders (ScheduledItem Architecture) | [read in full](Companion/Memory/Current/075-cron-reminders-scheduleditem-architecture.md) |
| Banner Flash Prevention (MailNavigationView) | [read in full](Companion/Memory/Current/076-banner-flash-prevention-mailnavigationview.md) |
| Test Isolation for `UserDefaults`-Backed State | [read in full](Companion/Memory/Current/077-test-isolation-for-userdefaults-backed-state.md) |
| Delivered-Notification Cleanup | [read in full](Companion/Memory/Current/078-delivered-notification-cleanup.md) |
| Startup Data Migrations (`StartupMigrations.swift`) | [read in full](Companion/Memory/Current/079-startup-data-migrations-startupmigrations-swift.md) |
| TextEditor/TextField Caret Jump — Never Save Per Keystroke (2026-07-02) | [read in full](Companion/Memory/Current/080-texteditor-textfield-caret-jump-never-save-per-keystroke-2026-07-02.md) |
| Migration Splash / iOS Indeterminate Linear ProgressView Pitfall (2026-07-01) | [read in full](Companion/Memory/Current/081-migration-splash-ios-indeterminate-linear-progressview-pitfall-2026-07-0.md) |
| Zero (BYOK) Plan — IAP Surface (ADR-IOS-040) | [read in full](Companion/Memory/Current/082-zero-byok-plan-iap-surface-adr-ios-040.md) |
| BYOK Model Picker — Two-Section Query-All (ADR-026, 2026-07-08) | [read in full](Companion/Memory/Current/083-byok-model-picker-two-section-query-all-adr-026-2026-07-08.md) |
| HTML-Document Guard for text/plain Extraction (2026-06-11) | [read in full](Companion/Memory/Current/084-html-document-guard-for-text-plain-extraction-2026-06-11.md) |
| GRDB Database Suspension — 0xdead10cc Defense (ADR-IOS-041, 2026-06-12) | [read in full](Companion/Memory/Current/085-grdb-database-suspension-0xdead10cc-defense-adr-ios-041-2026-06-12.md) |
| Dictation leaves AVAudioSession active → haptics die process-wide (2026-06-27) | [read in full](Companion/Memory/Current/086-dictation-leaves-avaudiosession-active-haptics-die-process-wide-2026-06.md) |
| fullScreenCover content must never re-fetch by a rekeyable id → presented-but-empty cover renders SOLID BLACK (2026-07-08) | [read in full](Companion/Memory/Current/087-fullscreencover-content-must-never-re-fetch-by-a-rekeyable-id-presented.md) |
| Inbox gesture actions derive intent from the VISUALIZED snapshot, never a gesture-path DB read (dead-toggle fix, 2026-07-10) | [read in full](Companion/Memory/Current/088-inbox-gesture-actions-derive-intent-from-the-visualized-snapshot-never-a.md) |
| Action queue coalesces gesture intents to latest-per-field (ADR-IOS-057, 2026-07-10) + overlay call-site audit closed | [read in full](Companion/Memory/Current/089-action-queue-coalesces-gesture-intents-to-latest-per-field-adr-ios-057-2.md) |
| Knowledge Gaps | [read in full](Companion/Memory/Current/090-knowledge-gaps.md) |

## Historical and superseded memory

These files preserve source history. Read them when a current topic, ADR, plan, or shipped-release comparison points to the older design.

| Status | Topic / search terms | Detail |
|---|---|---|
| Historical | Original project-memory preamble | [read in full](Companion/Memory/History/000-original-project-memory-preamble.md) |

## Forward-ported topics absent from the shipped source

These topics exist only on the mature pre-v3 line and are therefore not in `v1.6.38:PROJECT_MEMORY.md`. The bodies are preserved byte-for-byte with their provenance in [`Companion/Memory/ported-manifest.tsv`](Companion/Memory/ported-manifest.tsv). They are excluded from the source-document reconstruction manifest.

| Status | Topic / search terms | Detail |
|---|---|---|
| Historical | HISTORICAL — Intention journal + fold-at-drain (ADR-IOS-058, 2026-07-11; queue/Undo mechanics superseded by ADR-IOS-060) | [read in full](Companion/Memory/History/090-historical-intention-journal-fold-at-drain-adr-ios-058-2026-07-11-queue.md) |
| Current | Intention queue V2 — authoritative current direction (ADR-IOS-060, 2026-07-13) | [read in full](Companion/Memory/Current/092-intention-queue-v2-authoritative-current-direction-adr-ios-060-2026-07-1.md) |
| Current | ⚠️ The `FakeIMAPServer` wrong-message wire oracle (`wrongMessageViolations` / `expectMutation` / `expectedMutationRfcs`) is STRUCTURALLY BLIND to any C3 defect whose precondition is that target and bystander share one RFC 822 Message-ID — it discriminates by RFC-identity set membership, so such a mutation is declared correct and the assertion is vacuous while looking rigorous; pin on physical wire state + the `UID STORE`/`EXPUNGE` command log instead, and do NOT re-base the oracle on UID (2026-08-04, from the B1 draft-SEARCH fix `459786db1`) | [read in full](Companion/Memory/Current/093-the-wrong-message-wire-oracle-is-blind-to-shared-message-id-defects.md) |

---

## Post-`v1.6.38` topics — routed detail, no byte-identical `v1.6.38` twin

Authored after `v1.6.38`, so the pinned compaction has no byte-identical twin. Deliberately **not** rows in [`manifest.tsv`](Companion/Memory/manifest.tsv), which reconstructs `v1.6.38:PROJECT_MEMORY.md` exactly; provenance, source line ranges and per-fragment `sha256` are in [`amendments-manifest.tsv`](Companion/Memory/amendments-manifest.tsv).

| Status | Topic / search terms | Detail |
|---|---|---|
| Historical | Compaction drift list — the retired *Retained inline — no byte-identical routed twin* preamble: why a post-`v1.6.38` amendment can differ from its `Companion/Memory/` twin, and the check-the-routed-twin-before-editing rule | [read in full](Companion/Memory/History/094-retained-inline-no-byte-identical-routed-twin.md) |
| Current | v3 provider-id action-queue forward-port — authoritative resume state (2026-08-02): branch `v3`, HEAD `583de7a5d`, **PAUSED BY OWNER**, never pushed; the hierarchical plan — `PLAN_IOS_REFACTOR_V3.md` ROUTING INDEX always first, `PLAN_IOS_REFACTOR_V3/PLAN_V3_*.md` on demand only, never re-merged; last landed **T4.T2**, next **T5.9** then **T4.T1**, T4.O5 deferred; verification baseline **7,994 tests / 1,085 suites / 0 hard failures @ `35d5b2814`** and why it is unmeasured across seven landed commits; rules R0–R4 and the `v2final` PORT / SUBTRACT / `⚑ NO REFERENCE — INVENTED` classification; **the invention census is exactly two** — the agent-versus-Send fence and the `v74` blanket `PendingOperation` purge; the ~277 KB of per-commit history deleted 2026-08-02, reconstruct with `git log 07a4bb703..HEAD` | [read in full](Companion/Memory/Current/095-v3-provider-id-action-queue-forward-port-resume-state.md) |
| Current | T1.3 — a NEW gesture fails CLOSED when the folder's UIDVALIDITY epoch is unknown (2026-07-30/31): `AccountManager.newGestureRefusedForUnknownEpoch` is a **silent no-op** (`IOS-EPOCH-001`, constraint C3) and must NOT be "fixed" back to fail-open, unlike `v2final`; the carve-outs — provider-scoped rather than "the column is nil" (`Folder.lastKnownUidValidity` is nil FOREVER on Gmail/Exchange, `.icloud` MUST stay in the IMAP set), `DemoSeed.demoAccountId` excluded by id, a missing `Folder` row fails closed, and the two draft sites re-classified at EXECUTION time by `DraftStore.pushDraftToServer`; the crawl-epoch machinery `IMAPProvider.selectMailboxTracked` / `getUidNextWithEpoch` / `EmailProvider.fetchMessagesWithObservedEpoch` / `SyncEngine.bootstrapCrawledFolderUidValidity` / `crawlEpochAgrees` / `crawlEpochGate` / `crawlWalkWriteAllowed` / `resetEmptyFolderCrawlEpoch` / `verifyAndBootstrapPrePopulatedFolderEpoch`; the round-7/8/10 **RETRACTIONS** — say *indefinite*, never *permanent*, and **a TRANSIENT container plus a DURABLE re-entry condition is a PERMANENT refusal**; the consumer-direction inversion (a comparison that ABORTS in the reference became a first-epoch WRITE here); and the presentation rule — on a refused optimistic write RECONCILE FROM THE DATABASE, never restore a snapshot (`UserLabelMenuModel.reconcileAppliedIdsFromDatabase`, `InboxViewModel.reconcileUserLabels`) | [read in full](Companion/Memory/Current/096-t1-3-new-gesture-fails-closed-on-unknown-uidvalidity-epoch.md) |
| Historical | T4.S6 follow-up — **SUPERSEDED v3 intermediate; retain for history, never implement from it** (2026-07-31): the `v69` `PendingOperation.observedUidValidity` draft-op stamp and the later `v72` draft-specific queue epoch as historical derivation only; the lesson *"carries a non-numeric id" is a property of the ROW, "resolves by SEARCH" is a property of the EXECUTOR* — `AccountManager.opIsAddressOnly` versus `queueDraftDelete`'s `messageIds = [numericUID, rfc822]`; the owner directive that a delete op must NOT survive a UIDVALIDITY reset; why widening the sweep's classifier was REJECTED; and ⛔ the **RETRACTED** bare mailbox-wide `EXPUNGE` — `IMAPProvider.expungeScopedToTargets` is UIDPLUS-conditional and the no-UIDPLUS path fails closed, do not restore the fallback; tests `DraftDeleteEpochBoundaryTests` / `IMAPDraftExpungeScopeTests` and the `drainUntilSettled` versus `isDraining` test-harness trap | [read in full](Companion/Memory/History/097-t4-s6-follow-up-superseded-v3-intermediate-draft-epoch-stamp.md) |
| Current | IMAP external-deletion blind spot — old server-deleted messages linger forever (audit 2026-07-02), **FIXED 2026-07-03 by ADR-IOS-051** Phases 1+2, with every post-fix amendment: `SyncEngineDeletionReconcile`, `handleVanishedUIDs`, `IMAPProvider.searchExistingUIDs`, `SyncConfig.deletionReconcileChunkSize` / `deletionReconcileCapSlack` deletion circuit breaker, the first-walk UIDVALIDITY bootstrap caveat and the body-fetch "gone" UX follow-up; IDLE `.vanished` is CONSUMED while `.expunge` still degrades to a poll (the earlier "both DISCARDED" claim was falsified); the thrice-corrected modseq wiring — `IMAPProvider.folderStatus` → `SyncEngine.modSeqIndicatesChange` (delta, can only FORCE a fetch) versus `fetchFolders`' `FolderInfo.highestModSeq` → `SyncEngine.shouldSkipFolderFetch` (full sync, the only skip-capable gate), the shared `Folder.lastKnownHighestModSeq` column both write, the fresh-versus-cached sides of the comparison, and the UPDATE/INSERT asymmetry; no CONDSTORE `CHANGEDSINCE`, no QRESYNC, no `VANISHED (EARLIER)`, `IMAPProvider.fetchHistory` returns nil | [read in full](Companion/Memory/Current/098-imap-external-deletion-blind-spot-amended-adr-ios-051.md) |
| Current | Persistent NSE log file + watchdog partial-result delivery (2026-07-09) and audit rounds 1–7: `NSELogStore` / `nse.log` synchronous append, inode-preserving `clear()` and `trimIfNeeded` (never an atomic replace), `NSELog.step` dual-channel logging and the `NSE stepN` / `NSE ━━━` grep contract, `NSELog.$runTag` per-run attribution, `NSEProviderSupport.logLine` + `lineMaxChars`; `PartialSignalHolder` and `NotificationService.applyPartialOrBareFallback`; the **idle-timer-versus-SSE** root cause (a summary ran 26.4 s and missed the 27 s watchdog by 9 ms), `BackendNSEClient.performRequestWithDeadline`, `NSEProviderSupport.llmCallBudget`, the summary retry loop and the action-requires-summary parity gate (ADR-IOS-008); the **zombie-resume** class — `OneShotFlag.hasFired()` and all NINE abandon checkpoints, including the two corrected exemptions (peer-cache probe, `handleTaskAlarm`); and the notification-tap pop suppression — `MessageDetailViewModel.retryLoad`, `shouldPopForUnresolvedTap`, `isViewVisible`, `hasActivePresentation`, `PreviewFreezeGate` (covers do NOT fire `onDisappear`) | [read in full](Companion/Memory/Current/099-persistent-nse-log-file-watchdog-partial-delivery-audit-rounds.md) |
