# TabMail iOS - Project Memory

> **iOS-specific knowledge.** Claude reads this before every task and updates it when discovering something new. For cross-cutting knowledge, see `../PROJECT_MEMORY.md`.

**Last updated:** 2026-08-06

---

## How to use this index

**This file is a router, not an archive.** Every topic below is preserved in full under
[`Companion/Memory/`](Companion/Memory/manifest.tsv) (`sha256` per fragment); load only the topics
your task mechanically matches. Routing protocol — derive terms → `rg -ni` → read in full → enumerate
in the brief → update the detail — is **normative in root [`../CLAUDE.md`](../CLAUDE.md) § *Companion
Routing***; this file's own wording is preserved in
[`Companion/Process/Current/project-memory-index-usage-protocol.md`](Companion/Process/Current/project-memory-index-usage-protocol.md).

Current entries govern. Historical entries preserve evidence but do not override current rules or active ADRs.

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

Pre-v3-line topics absent from `v1.6.38:PROJECT_MEMORY.md`; bodies preserved byte-for-byte, provenance in [`ported-manifest.tsv`](Companion/Memory/ported-manifest.tsv).

| Status | Topic / search terms | Detail |
|---|---|---|
| Historical | HISTORICAL — Intention journal + fold-at-drain (ADR-IOS-058, 2026-07-11; queue/Undo mechanics superseded by ADR-IOS-060) | [read in full](Companion/Memory/History/090-historical-intention-journal-fold-at-drain-adr-ios-058-2026-07-11-queue.md) |
| Current | Intention queue V2 — authoritative current direction (ADR-IOS-060, 2026-07-13) | [read in full](Companion/Memory/Current/092-intention-queue-v2-authoritative-current-direction-adr-ios-060-2026-07-1.md) |
| Current | ⚠️ `FakeIMAPServer`'s `wrongMessageViolations` wire oracle is BLIND when target and bystander share an RFC 822 Message-ID — the C3 assertion goes vacuous; pin on the `UID STORE`/`EXPUNGE` log, never UID | [read in full](Companion/Memory/Current/093-the-wrong-message-wire-oracle-is-blind-to-shared-message-id-defects.md) |

---

## Post-`v1.6.38` topics — routed detail, no byte-identical `v1.6.38` twin

Authored after `v1.6.38`, so deliberately **not** rows in [`manifest.tsv`](Companion/Memory/manifest.tsv); provenance, source line ranges and per-fragment `sha256` in [`amendments-manifest.tsv`](Companion/Memory/amendments-manifest.tsv).

| Status | Topic / search terms | Detail |
|---|---|---|
| Historical | Compaction drift list — a post-`v1.6.38` amendment can differ from its `Companion/Memory/` twin; check the routed twin BEFORE editing | [read in full](Companion/Memory/History/094-retained-inline-no-byte-identical-routed-twin.md) |
| Current | v3 provider-id action-queue forward-port — ✅ SHIPPED **v1.7.0**; branch `v3` DELETED, `main` IS that line; **R0/R3 RETIRED**; ⛔ `v2final` = never-shipped SIBLING, PROVENANCE only | [read in full](Companion/Memory/Current/095-v3-provider-id-action-queue-forward-port-resume-state.md) |
| Current | T1.3 — a NEW gesture fails CLOSED on an unknown UIDVALIDITY epoch: `newGestureRefusedForUnknownEpoch` is a silent no-op (`IOS-EPOCH-001`, C3), never fail-open | [read in full](Companion/Memory/Current/096-t1-3-new-gesture-fails-closed-on-unknown-uidvalidity-epoch.md) |
| Historical | T4.S6 — ⛔ **SUPERSEDED v3 intermediate, never implement from it**: `v69`/`v72` draft epoch stamps; the RETRACTED bare mailbox-wide `EXPUNGE` | [read in full](Companion/Memory/History/097-t4-s6-follow-up-superseded-v3-intermediate-draft-epoch-stamp.md) |
| Current | IMAP external-deletion blind spot — server-deleted messages linger forever; FIXED by **ADR-IOS-051** Ph1+2: `SyncEngineDeletionReconcile`, `handleVanishedUIDs` | [read in full](Companion/Memory/Current/098-imap-external-deletion-blind-spot-amended-adr-ios-051.md) |
| Current | Persistent NSE log + watchdog partial delivery, rounds 1–7: `NSELogStore`/`nse.log`, `PartialSignalHolder`; **idle-timer-vs-SSE**; `OneShotFlag.hasFired()` | [read in full](Companion/Memory/Current/099-persistent-nse-log-file-watchdog-partial-delivery-audit-rounds.md) |
| Current | Two-instant wake handoff — "elapsed" means DO IT NOW: `AccountManager.wakeUpDelay`, `holdUntil`, `IOS-OUTBOX-005`, `UInt64(negative)` traps | [read in full](Companion/Memory/Current/100-two-instant-wake-handoff-elapsed-means-do-it-now.md) |
| Current | `isDeletedOnServer` — FOUR materialisation paths **plus a FIFTH PRESENTATION path** (`SearchView.searchAccount` sends no `NOT DELETED`), `IOS-IMAP-001`; `deepBackfillFolder` is DEAD CODE | [read in full](Companion/Memory/Current/101-isdeletedonserver-has-four-materialisation-paths.md) |
| Current | ⚠️ **SIX irreversible wire operations at `967e5b3c5`, not one** — deletion family + `CalDAVProvider.splitSeries` cap `PUT`; membership = **no reached per-item recovery**, NOT the verb; census 7/3/5/2/2 | [read in full](Companion/Memory/Current/102-there-are-four-irreversible-wire-operations-not-one.md) |
| Current | 🚨 `await dbPool.read` is NOT a short suspension — the ASYNC overload first `await`s `NSEDataBridge.mergeIfStagingPending()` (measured 7.6 s cold boot); check-then-act across it is UNBOUNDED | [read in full](Companion/Memory/Current/103-await-dbpool-read-is-not-a-short-suspension.md) |
| Current | 🚨 a latch that AUTHORISES a transition must be HELD across the write — reading `isDrainingOutbox` then `await`ing proves nothing; ACQUIRE it (`IOS-OUTBOX-006`, `reconcileOutbox`) | [read in full](Companion/Memory/Current/104-a-latch-that-authorises-a-transition-must-be-held-across-the-write.md) |
| Current | 🚨 a bare `print` is NOT production observability on iOS — `stdout` is DISCARDED on device; use `BackgroundSyncLogger.logError`; a gate inside a BRANCH CONDITION picks the branch (`MIS-019`); **a RESIDUAL RECORD is an absolute in humility's clothing** | [read in full](Companion/Memory/Current/105-a-print-is-not-production-observability-on-ios.md) |
| Current | 🚨 a filter applied AFTER a query's `LIMIT` narrows the page instead of selecting it — `InboxListReader.gather`, `hasMoreMessages` (`IOS-SCROLL-002`, `IOS-BACKFILL-001`) | [read in full](Companion/Memory/Current/106-a-filter-after-the-limit-narrows-the-page-instead-of-selecting-it.md) |
| Current | 🚨 a staging key that names an ADDRESS must re-prove identity before it reuses payload — `nse_processed_message`'s PK holds a UID, `stageHeader`'s `ON CONFLICT` (`IOS-NSE-005`, C3) | [read in full](Companion/Memory/Current/107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md) |
| Current | 🚨 a Swift `String` comparison does NOT reproduce SQLite **BINARY** collation and is not a total order — use `utf8.lexicographicallyPrecedes`; `InboxOrdering`, keyset cursor, `IOS-SCROLL-002` | [read in full](Companion/Memory/Current/113-a-swift-string-comparison-does-not-reproduce-sqlite-binary-collation.md) |
| Current | 🚨 **THE SAME STAGING KEY HAS FOUR WRITERS, AND "SAFE" POINTS THE OPPOSITE WAY FOR THREE** (`IOS-NSE-006`, `stagedIdentityPositivelyDiffers`) — ⚠️ **THE FAIL DIRECTION INVERTS** | [read in full](Companion/Memory/Current/107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md) |
| Current | 🚨 **AN ENUM WITH NO SILENT CASE DOES NOT PREVENT A SILENT PATH** — `ResultTapOutcome`'s "cannot reintroduce silence" comment was FALSE AND LOAD-BEARING (`case …: break` compiles) | [read in full](Companion/Memory/Current/109-an-enum-with-no-silent-case-does-not-prevent-a-silent-path.md) |
| Current | 🚨 THE ADDRESS PROBLEM HAS TWO ADDRESS SPACES — Graph's `/move` response IS the `COPYUID`; `ExchangeProvider.moveMessage` discarded the new `id` (`IOS-GRAPH-002`, `MIS-006`) | [read in full](Companion/Memory/Current/108-the-address-problem-has-two-address-spaces-graph-move-response-is-the-copyuid.md) |
| Current | 🚨 `uidValidityResetPendingAt` STAYS ARMED ON PURPOSE — never demand proof of transience; `crawlWalkWriteAllowed` was the LAST consumer writing under an armed flag (`16ecafd93`) | [read in full](Companion/Memory/Current/112-uidvalidityresetpendingat-is-a-redrive-flag-that-stays-armed-on-purpose.md) |
| Current | 🚨 **BOTH UIDVALIDITY RE-DRIVE OWNERS ITERATED `syncableFolders`** (`fullSync` + `imapDeltaSync`) — an armed CUSTOM NON-FAVOURITE folder had NO re-drive: quarantined, mail purged (26 folders / 145,754 rows). Count PREDICATES | [read in full](Companion/Memory/Current/114-both-uidvalidity-redrive-owners-iterate-syncablefolders.md) |
| Current | ✅ **`KNOWN_ISSUES.md` APPEND PATH — RESOLVED 2026-08-12** — strip-before-compare `KNOWN-ISSUES-AMENDMENT-BEGIN`/`-END` + non-globbed `KnownIssues/Amendments/` dir; first user `IOS-IMAP-015`; the 4 `RRULE UNTIL` residuals live there | [read in full](Companion/Memory/Current/115-known-issues-register-is-byte-frozen-and-has-no-append-path.md) |
| Current | 🚨 **ATTACHMENT FILENAMES REJECTED, NOT REDUCED** — `AttachmentFilename.isSafeFileComponent`, `AttachmentFilenameError`; **255 NFD UTF-16 unit** path-component cap (NOT bytes, NOT `Character`s); `CharacterSet.controlCharacters` = 24,970 scalars and BUILT-IN set operators materialise it unpredictably; `strippedFilenameScalars` = 79 | [read in full](Companion/Memory/Current/116-a-path-component-is-capped-in-nfd-utf16-units-not-bytes-or-characters.md) |
| Current | SwiftMail PR #208 MOVE post-completion contract — typed partial completion is non-retryable; retain COPYUID and reconcile both folders | [read in full](Companion/Memory/Current/117-swiftmail-move-post-completion-contract.md) |
| Current | 🚨 **"TRIAL ENDED" IS DERIVED, NEVER A NEW `/whoami` FLAG** — `has_subscription:false` + the `trial` KEY present (value may be **explicit `null`**; `trialKeyPresent`, `container.contains`) ; `trial_expired`/`trial_blocked` were CUT as reinvention. `.active` REQUIRES `plan_tier == "Trial"` — a legacy Stripe/Apple **CARD trial** also carries a `trial` object and must stay a plain subscriber. `trial_end` is `string \| number` upstream so `TrialInfo` decodes LENIENTLY (a String would fail the WHOLE parse). `AccountInfo.trialState(now:)`, `TrialState.noTrial` (not `.none`), `AISubscriptionGate.apply`/`trialHasEnded` (bare `openGate`/`closeGate` must NOT write it; flag is GLOBAL not account-scoped; test restore order flag-BEFORE-isActive), `ZeroBudgetPlan` per-plan quota captions, `dailyQuotaChartDenominator` explicit-zero budget, `displayPlanName` `Trial → "Free Trial"`, signup trial, plan picker, account deletion `case "signup" → .scheduleDeletion`; ⚠️ intro-offer machinery (`PlanCardIntroOffer`/`suppressesIntroOffer`/`checkTrialEligibility`/`showsTrialBadge`) DELETED 2026-08-19 issue #55 — survivor `PlanCardCTA.buttonLabel` | [read in full](Companion/Memory/Current/118-trial-ended-is-derived-never-a-new-whoami-flag.md) |
