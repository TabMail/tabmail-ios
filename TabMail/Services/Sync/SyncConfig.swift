/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit

// MARK: - Backfill Profile (Power-Aware)
// Determines how aggressively backfill runs based on device state.
// Four tiers:
//   .low        — thermal throttling (serious/critical). Minimal resource usage.
//   .normal     — on battery, default. Moderate progress, reasonable drain.
//   .aggressive — plugged in (automatic). Full throughput, UI stays responsive.
//   .turbo      — user-triggered fast sync. Maximum throughput, UI may lag.
// Low Power Mode and battery < 20% pause backfill entirely (not a profile tier).
enum BackfillProfile {
    case low
    case normal
    case aggressive
    case turbo

    /// Backfill fetch+insert chunk size.
    var backfillChunkSize: Int {
        switch self {
        case .low: return 200
        case .normal: return 500
        case .aggressive: return 1000
        case .turbo: return 1000
        }
    }

    /// IMAP provider: how many UIDs to FETCH per batch within a single lock acquisition.
    /// .turbo uses large batches — lock holds ~2-4s, user actions may queue briefly.
    var imapFetchBatchSize: Int {
        switch self {
        case .low: return 50
        case .normal: return 100
        case .aggressive: return 200
        case .turbo: return 500
        }
    }

    /// Gmail provider: yield delay interval (sleep every N fetches).
    var gmailFetchBatchSize: Int {
        switch self {
        case .low: return 25
        case .normal: return 50
        case .aggressive: return 100
        case .turbo: return 200
        }
    }

    /// Gmail API page size (maxResults parameter).
    var gmailPageSize: Int {
        switch self {
        case .low: return 250
        case .normal: return 500
        case .aggressive: return 500
        case .turbo: return 500
        }
    }

    /// Delay between IMAP FETCH batches within a single backfillWindow call (seconds).
    var imapInterBatchDelay: TimeInterval {
        switch self {
        case .low: return 1.0
        case .normal: return 0.5
        case .aggressive: return 0.1
        case .turbo: return 0
        }
    }

    /// Delay between Gmail API pages during listBackfillMessageIds (seconds).
    var gmailInterPageDelay: TimeInterval {
        switch self {
        case .low: return 0.5
        case .normal: return 0.3
        case .aggressive: return 0.1
        case .turbo: return 0
        }
    }

    /// Gmail header fetch concurrency — how many API calls run in parallel.
    /// Gmail API rate limit is 250 qps per user, so even turbo stays well within limits.
    var gmailHeaderConcurrency: Int {
        switch self {
        case .low: return 2
        case .normal: return 5
        case .aggressive: return 10
        case .turbo: return 20
        }
    }

    /// Delay between Gmail per-message FETCH batches (seconds).
    var gmailInterFetchDelay: TimeInterval {
        switch self {
        case .low: return 1.0
        case .normal: return 0.5
        case .aggressive: return 0.1
        case .turbo: return 0
        }
    }


    /// Delay between deep backfill windows (seconds).
    var deepCrawlInterWindowDelay: TimeInterval {
        switch self {
        case .low: return 1.0
        case .normal: return 0.5
        case .aggressive: return 0.2
        case .turbo: return 0
        }
    }

    /// Delay between folders in performBackfill (seconds).
    var interFolderDelay: TimeInterval {
        switch self {
        case .low: return 1.0
        case .normal: return 0.5
        case .aggressive: return 0.2
        case .turbo: return 0
        }
    }

    /// Sleep between backfill cycles when work was done (seconds).
    var interCycleActiveDelay: TimeInterval {
        switch self {
        case .low: return 10
        case .normal: return 3
        case .aggressive: return 0.5
        case .turbo: return 0
        }
    }

    /// Sleep between backfill cycles when no work was done (seconds).
    var interCycleIdleDelay: TimeInterval {
        switch self {
        case .low: return 60
        case .normal: return 30
        case .aggressive: return 10
        case .turbo: return 3
        }
    }

    /// Body fetch chunk — how many bodies to index per backfill cycle.
    /// Larger chunks amortize connection setup and enable more pipeline stages.
    var bodyFetchChunkSize: Int {
        switch self {
        case .low: return 10
        case .normal: return 50
        case .aggressive: return 500
        case .turbo: return 500
        }
    }

    /// IMAP FTS body fetch: how many messages per lock acquisition.
    /// Each message needs ~1-2 text-part FETCH commands (~100ms RTT each).
    /// .turbo uses large batches (~5-10s lock hold) — user actions queue behind.
    var imapBodyFetchBatchSize: Int {
        switch self {
        case .low: return 5
        case .normal: return 10
        case .aggressive: return 20
        case .turbo: return 50
        }
    }

    /// Parallel IMAP connections for FTS body fetching.
    /// Each connection is independent (no serial lock needed).
    /// These are upper bounds — the server's actual limit (parsed from
    /// mail_max_userip_connections=N on rejection) is the real constraint.
    var imapBodyConcurrency: Int {
        switch self {
        case .low: return 1
        case .normal: return 4
        case .aggressive: return 10
        case .turbo: return 30
        }
    }

    /// Concurrent body fetches for Gmail/Exchange (HTTP) in FTS indexing.
    /// Gmail: 250 quota units/sec, messages.get = 5 units → ~50 req/sec max.
    /// At ~200ms RTT, 25 concurrent ≈ 125 req/sec peak — within limit with margin.
    /// Exchange limit is ~16 qps — 429/403 retry with backoff handles overshoot.
    var gmailBodyConcurrency: Int {
        switch self {
        case .low: return 3
        case .normal: return 10
        case .aggressive: return 20
        case .turbo: return 25
        }
    }
    /// Query the current backfill profile from device state.
    /// Standalone — no SyncEngine dependency. Safe to call from any actor.
    @MainActor
    static func current() -> BackfillProfile {
        let isFastSync = AccountManagerState.shared.fastSyncModeActive
        if isFastSync { return .turbo }
        let isOnPower = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        let isThermallyThrottled = ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.thermalState == .serious
        if isOnPower && !isThermallyThrottled { return .aggressive }
        if isThermallyThrottled { return .low }
        return .normal
    }
}

// MARK: - Sync Configuration
// All memory-bounding chunk sizes in one place.
// Every batch/pagination loop MUST use these — never hardcode numeric limits.
enum SyncConfig {
    /// How many messages to fetch per folder during sync (fullSync, deltaSync, on-demand).
    static let syncMessageLimit = 50
    /// Fix B task 4: force a DEEP (never-skip) full sync of a non-inbox CONDSTORE folder
    /// every Nth full sync, even when HIGHESTMODSEQ says nothing changed — the ADR-IOS-009
    /// self-healing net against a buggy server modseq. With full sync ~every 10 min, 6 ≈
    /// hourly. Inbox is never skipped regardless.
    static let fullSyncDeepEveryN = 6
    /// Upper bound on local rows for the "complete-knowledge" stale-detection path
    /// (`runSyncMessages`, the `coverage.spansEntireFolder` branch). When the SERVER
    /// proves the fetch spanned the whole folder we may stale-delete any local row not
    /// in the remote set. That is only BOUNDED when the LOCAL side is also small —
    /// concluding "complete" on a huge folder would load the whole thing into the
    /// writer — so above this count we fall through to the windowed slice instead
    /// (which can't conclude anything outside its floor). Generous on purpose; only
    /// pathologically large folders (Gmail All Mail / big Archives) trip it.
    ///
    /// 🚨 **This is a MEMORY bound, and it was never the safety bound.** The branch it
    /// gates used to trip on `messages.count < syncMessageLimit` — a count taken AFTER
    /// the provider's `compactMap` — so one unparseable record in a full window made a
    /// 900-message folder look complete and stale-deleted ~851 rows, well under this
    /// 2000-row ceiling. The safety property now comes from `FetchCoverage`, which the
    /// provider derives from the server's own EXISTS / page size. Do not re-introduce
    /// a survivor-count test here or at the branch, and do not read this constant as
    /// protection against one.
    static let staleDetectionMaxFullScan = 2000
    /// Max bound parameters per SQL `IN (...)` chunk — stays under SQLite's variable
    /// limit. Used to chunk large id lists for membership / dedup queries.
    static let sqlChunkSize = 500
    /// Page size for inbox list pagination (per folder).
    static let inboxPageSize = 50
    /// Per-folder page size the infinite scroller asks the SERVER for
    /// (`SyncEngine.fetchOlderMessages`). Deliberately distinct from
    /// `inboxPageSize`, which sizes the LOCAL list page: this is the number of
    /// records we requested, so it — and never `inboxPageSize` — is the yardstick
    /// for "the server handed back a FULL page, so it may hold older mail beyond
    /// it". Was a bare `25` at three provider call sites.
    static let infiniteScrollFetchLimit = 25
    /// Body fetch chunk — how many bodies to fetch at a time during background sync.
    static let bodyFetchChunkSize = 20
    /// HTTP body fetch concurrency (Gmail/Exchange) — ActiveBodyQueue concurrent fetches.
    static let bodyFetchConcurrency = 10
    /// Max retries per item in ActiveBodyQueue/ActiveAIQueue before dropping.
    /// Failed items move to back of FIFO, yielding to others. After max retries,
    /// item is removed from in-memory queue; repopulateFromDatabase catches it on next foreground.
    ///
    /// ⚠️ SCOPE of that last clause — it is TRUE of one of the two named queues and
    /// only PARTLY true of the other (ADR-IOS-078 pathway regating; comment corrected
    /// 2026-08-20, iOS #66). Do not flatten the distinction:
    ///   • `ActiveBodyQueue.repopulateFromDatabase` is Inbox-wide and UNBOUNDED
    ///     (`headerComplete = 1 AND bodyComplete = 0 AND … isInInbox = 1`, no LIMIT),
    ///     so for the BODY queue the sentence above holds for every Inbox row.
    ///   • `ActiveAIQueue.repopulateFromDatabase` runs `repopulationCandidates`, which
    ///     is WINDOW-BOUNDED in SQL to the newest `SyncConfig.maxRecentEmails` Inbox
    ///     rows. The pathway regating also gave that queue WINDOW-EXEMPT jobs (manual
    ///     open, push/NSE merge, moved-into-inbox — `AIJob.windowExempt`), and for an
    ///     exempt job on an OUT-OF-WINDOW row the promised recovery never fires:
    ///     retry exhaustion drops it and no sweep brings it back.
    /// Accepted per ADR-IOS-078's residual invariant — fail-closed, non-durable, and
    /// repairable by one ordinary gesture (reopen/Retry re-enters the exempt direct
    /// path). Do NOT widen the sweep to "fix" this: the AI bound is the install-flood
    /// door, kept shut precisely because the BODY sweep above is unbounded.
    static let maxQueueRetries = 3
    /// FTS orphan prune (one-time sweep): entries paged per FTS read.
    static let ftsOrphanPruneChunk = 500
    /// FTS orphan prune: delay before re-verifying candidates against GRDB —
    /// kills in-flight insert races without holding any lock.
    static let ftsOrphanPruneRecheckMs = 100

    // MARK: - BackfillAIQueue

    /// Rows claimed per drain pass in BackfillAIQueue.
    /// Refinements are human-paced (one per tag-teach / one per chat-session-end),
    /// so a small batch size is enough. Matches sibling `batchSize` pattern.
    static let backfillAIBatchSize = 8

    /// Initial backoff on transient LLM failure (retriable SSE heartbeat throw, 5xx, timeout).
    /// Doubles per retry up to `backfillAIBackoffCap`.
    static let backfillAIBackoffInitial: TimeInterval = 5.0

    /// Cap for exponential backoff on transient LLM failure.
    static let backfillAIBackoffCap: TimeInterval = 300.0

    /// Stale-drop TTL for pending AI refinement rows. Rows older than this are
    /// dropped at launch / foreground `repopulateFromDatabase`. A week-old teach
    /// or session is no longer a reliable refinement signal.
    /// Expressed as unix-millis delta (the `createdAt` column is INTEGER millis).
    static let backfillAIJobTTLMillis: Int64 = 7 * 24 * 60 * 60 * 1000
    /// Max concurrent LLM API calls (summary/action/reply). Matches TB's `maxAgentWorkers` semaphore.
    /// Gates `sendCompletions` / `sendCompletionsWithTools` at the BackendClient level via LLMSemaphore.
    /// Background AI processing tasks have no concurrency limit — the semaphore ensures
    /// exactly this many HTTP calls are in flight at any time.
    static let maxConcurrentLLMCalls = 32
    /// Backfill fetch+insert chunk — IMAP/Gmail backfill processes this many at a time.
    /// Used as default; overridden by BackfillProfile at runtime.
    static let backfillChunkSize = 500
    /// Pruning batch size — how many messages to process per iteration when over budget.
    static let pruneChunkSize = 50
    /// FTS bulk-index batch size — headers indexed per folder page.
    static let ftsIndexBatchSize = 200
    /// Yield interval during FTS body backfill — sleep briefly every N updates.
    static let ftsBodyYieldInterval = 50
    /// FTS batch write size — how many body updates per DB transaction.
    /// Balances write efficiency vs actor lock hold time.
    static let ftsWriteBatchSize = 50
    /// Embedding generation batch size.
    static let embeddingBatchSize = 50
    /// Max rows materialized per `BackfillEmbeddingQueue.repopulateFromDatabase` call.
    /// The partial index `messageHeader_embeddingIncomplete` filters to only matching
    /// rows, so at steady state this is near-empty. Large first-sync backlogs would
    /// otherwise blow memory by loading every unembedded message in one read — chunk
    /// so the next cycle picks up the remainder as rows drop out of the partial index
    /// after being embedded.
    static let embeddingRepopulateChunk = 5_000
    /// Memory-embedding batch size — sibling to `embeddingBatchSize`. Same initial value;
    /// tune independently if telemetry warrants it (ADR-IOS-034).
    static let memoryEmbeddingBatchSize = 50
    /// Max rows materialized per `BackfillMemoryEmbeddingQueue.repopulateFromDatabase` call.
    /// Sibling to `embeddingRepopulateChunk`. The partial index
    /// `idx_memory_meta_embeddingComplete` (WHERE embeddingComplete = 0) keeps this probe
    /// O(pending) regardless of total corpus size.
    static let memoryEmbeddingRepopulateChunk = 5_000
    /// Drain-time self-repopulate limit for memory embedding queue.
    /// Sibling to email's hardcoded `LIMIT 500` at `BackfillEmbeddingQueue.swift:300`.
    /// Safety-net bound, not bulk-backfill load — queue re-runs until the query returns 0.
    static let memoryEmbeddingDrainRepopulateLimit = 500
    /// On-demand snippet loading chunk — how many snippets to fetch per batch when rows appear.
    static let snippetOnDemandChunkSize = 15
    /// Prefetch lookahead — queue snippets for this many messages ahead of the visible row.
    static let snippetPrefetchLookahead = 30
    /// Max snapshots held in loadedMessages before evicting oldest off-screen rows.
    static let maxLoadedMessages = 500
    /// Max message IDs returned by Gmail listBackfillMessageIds per call.
    /// Safety cap to bound the in-memory ID array. 1M IDs ≈ 20MB — safe for iOS devices.
    /// In practice, 90-day deep backfill windows rarely exceed a few thousand IDs.
    static let gmailBackfillIdCap = 1_000_000
    /// Body cache TTL — evict cached MessageBody objects older than this (non-inbox).
    /// Pre-cached by ActiveBodyQueue for all fetched messages, so a generous TTL
    /// keeps most recently-synced messages instantly readable without re-fetch.
    static let bodyCacheTTLHours = 72
    /// Keep bodies for N most recent messages per non-inbox folder regardless of TTL.
    static let bodyCacheRecentPerFolder = 50
    /// Reply cache TTL — precomputed replies older than this are regenerated (seconds).
    /// Matches TB's SETTINGS.replyTTLSeconds in config.js.
    static let replyTTLSeconds: TimeInterval = 604_800 // 1 week
    /// Age before an out-of-inbox action tag is reclaimed by sweepStaleActionTags.
    /// Matches TB's SETTINGS.actionTTLSeconds (1 week). Inbox tags are never swept.
    static let actionTagTTLSeconds: TimeInterval = 604_800
    /// AI cache TTL — MessageAICache entries not refreshed within this period are purged.
    /// Entries are touched during inbox sync; entries for messages that leave inbox expire.
    static let aiCacheTTLDays = 7
    /// Age after which a TERMINALLY-RETIRED calendar operation
    /// (`PendingStatus.failed`) is reclaimed by
    /// `SyncEngine.runReclaimRetiredCalendarOps`.
    ///
    /// R16-1 changed the six terminal arms from deleting the row to retaining it
    /// as `failed`, and NOTHING swept it — so `pendingCalendarOperation` grew
    /// monotonically and `drainCalendarQueue`'s
    /// `filter(status == queued).order(createdAt)` full-scan-plus-temp-sort (the
    /// table has no index on `status`) got slower forever. The window is a
    /// retention period for a diagnostic record, not a correctness bound: a
    /// `failed` row is invisible to the drain, to reconciliation and to every
    /// production reader, so reclaiming it can neither drop nor revive an
    /// intention.
    static let retiredCalendarOpRetentionDays = 30
    /// Max message-detail chat sessions to keep (non-inbox messages only; inbox exempt).
    static let maxMessageChatSessions = 10
    /// Max compose drafts to keep (drafts for inbox reply/forward exempt).
    static let maxComposeDraftSessions = 10
    /// TTL for compose chat session turns. Compose sessions are never resumable;
    /// turns are kept for MemorySearchTool until this TTL, then deleted.
    static let composeChatSessionTTLDays = 30
    /// Thread query: max messages returned per thread query.
    static let threadQueryLimit = 100
    /// Max inline images (CID) to resolve per message — alias onto the shared
    /// canonical constant so main-app callers (providers, IMAP, Graph) and
    /// NSE use the same value without a second source of truth.
    static let maxInlineImages = BodyRenderer.maxInlineImages
    /// Max size per inline image in bytes — alias onto the shared canonical.
    static let maxInlineImageBytes = BodyRenderer.maxInlineImageBytes
    /// Max undo stack depth — oldest actions evicted when exceeded. In-memory only, no persistence.
    static let undoStackMaxSize = 20
    /// Body fetch repopulate limit — max headers loaded per repopulate cycle.
    /// Queue self-replenishes: drains this batch, next repopulate loads more.
    static let bodyFetchRepopulateLimit = 500
    /// BackfillBodyQueue dispatch batch — items collected per dispatch cycle.
    /// Grouped by folder after collection, so actual per-folder batches may be smaller.
    static let backfillBodyDispatchBatch = 50
    /// Max consecutive IMAP batch-fetch misses (UID not returned at all, as opposed
    /// to an empty body) before treating the message as confirmed gone from the
    /// server and deleting the local header. Per-fetch retries cross cycles because
    /// missFetchCount persists in GRDB until a successful fetch resets it to 0.
    static let backfillBodyMissThreshold = 5
    /// Debounce interval for unread count recounts (seconds). Rapid actions coalesce into one DB query.
    static let unreadRecountDebounceSeconds: TimeInterval = 0.2
    /// Max recent unread inbox messages the main app records into the NSE's
    /// `nse_badge_counted` dedup table per authoritative recount (see
    /// `UnreadCountManager.updateBadge`). Bounds the write for users with large
    /// unread inboxes — only RECENTLY-arrived unread can race a concurrent NSE
    /// delivery, so the most-recent-by-date slice is both sufficient and capped.
    static let nseBadgeDedupRecentLimit = 200
    /// TTL for recently completed action protection (seconds). After a pending operation
    /// completes and is deleted, the sync engine skips overwriting optimistic state
    /// (flag changes, move re-insertions) for this duration to absorb server-side lag.
    static let recentActionProtectionTTLSeconds: TimeInterval = 90

    /// TTL for the recentlyCompleted protection set (replaces recentActions).
    /// After a PendingOp is deleted post-execution, protects against stale in-flight sync writes.
    /// Actual gap is 1-2s; 30s gives 15x margin for edge cases (brief app backgrounding, etc.).
    static let recentlyCompletedTTLSeconds: TimeInterval = 30

    /// TTL for NSE push-merge arrival stale-protection (NSEDataBridge). A message that
    /// becomes durable via push-merge is upserted ONLY by the merge — sync deliberately
    /// skips its upsert while protected — so a transient server-fetch miss (STATUS/fetch
    /// propagation lag) after the protection expires stale-deletes a real message. 120s
    /// covers two foreground delta-sync poll cycles (60s cadence, see
    /// `SyncEngine.backgroundDeltaSync`/two-tier sync) so a miss self-corrects before
    /// protection lapses. The 30s `recentlyCompletedTTLSeconds` default was too short for
    /// this purpose: it expired 5s before an observed INBOX stale-delete of a freshly
    /// pushed message ("boot_logs 2", 2026-07-09).
    static let pushMergeStaleProtectionTTLSeconds: TimeInterval = 120

    // MARK: - Large Inbox Management
    // Matches TB's SETTINGS.inboxManagement. Inboxes larger than maxRecentEmails
    // are treated as "large" — only recent messages are AI-processed AUTOMATICALLY
    // (see the scope note on `maxRecentEmails` below).

    /// Maximum recent inbox emails to AI-process AUTOMATICALLY (summary, action, reply).
    ///
    /// ⚠️ SCOPE (ADR-IOS-078 pathway regating, owner directive 2026-08-19) — this is
    /// NOT a global cap on AI processing, and reading it as one is the mistake this
    /// note exists to prevent. It bounds SYNC-ORIGIN admission and the repopulation
    /// sweep, because `ActiveBodyQueue.repopulateFromDatabase` is Inbox-wide and
    /// unbounded and would otherwise flood the LLM on first install. Arrival and
    /// user-intent events are deliberately EXEMPT and DO process an older message:
    /// opening it, receiving it by push/NSE merge, or moving it into the Inbox.
    /// See `ActiveAIQueue.recentInboxWindowContains` for the two scoping mechanisms.
    ///
    /// Matches TB's inboxManagement.maxRecentEmails.
    static let maxRecentEmails = 100
    /// Age threshold (days) for the archive prompt. Messages older than this
    /// in a large inbox trigger a suggestion to archive.
    /// Matches TB's inboxManagement.archiveAgeDays.
    static let archiveAgeDays = 14

    // MARK: - Polling & Background Intervals (seconds)

    /// Foreground polling interval. Push-capable accounts get real-time updates;
    /// this mainly serves IMAP-only accounts and as a safety net.
    static let foregroundPollIntervalSeconds: TimeInterval = 300 // 5 min

    /// Safety-net timeout for the first-paint launch gate
    /// (`AppStartup.awaitLaunchReady(background: false)`). The deferrable FOREGROUND
    /// boot herd (NSE merge / sync / queue repopulation / CoreML load) waits for the
    /// REAL first paint (`isReady`), not a fixed settle. A foreground launch always
    /// paints, so this bound is only reached on a background launch (no paint) or a
    /// pathological stall — it just stops the herd hanging forever.
    static let firstPaintGateTimeoutSeconds: Double = 8

    /// Settle delay after a FOREGROUND NSE merge before the downstream reply-
    /// precompute + embedding herd is enqueued (`NSEDataBridge.flushNSEBatchToFTS`).
    /// On a quick-open, the merge surfaces the message and the inbox reloads via the
    /// immediate signal; this brief window lets that render land before the heavy
    /// herd's non-DB cost (SSE/tool LLM, CoreML) starts. Reply precompute is 4–8s
    /// anyway, so this only shifts WHEN it starts. Background merges skip it
    /// entirely (precomputing before the user opens is the point). Gated on first
    /// paint first, so cold-launch waits for the inbox; this is the post-paint settle.
    static let nseMergeHerdSettleSeconds: Double = 0.5

    /// Deadline for the background write-queue drain barrier
    /// (`AccountManager.awaitWriteQueueDrainOrTimeout`) inside AppDelegate's
    /// `didEnterBackground` "wal-durability-checkpoint" bracket. The drain
    /// races this timeout; whichever finishes first wins, then
    /// `AppDatabase.checkpointForDurability()` runs. Bounded so a
    /// pathological queue can't hold the background budget hostage — the
    /// queued closures are local GRDB writes only (no network), typically
    /// milliseconds each, and iOS grants ~30s total for the bracket. On
    /// timeout the checkpoint proceeds anyway; the un-drained tail closures
    /// still run later (never dropped), they just miss this fsync window.
    static let backgroundWriteQueueFlushTimeoutSeconds: Double = 10

    /// Max headers per `insertBackfillBatch` write TRANSACTION. The backfill walk
    /// may hand it up to `backfillChunkSize` (500–1000) headers; inserting them in
    /// one transaction holds the single GRDB writer for the whole batch (~100s of
    /// ms), so a priority/UI write (badge recount, NSE merge) that arrives mid-batch
    /// waits the full batch — SQLite can't preempt an in-flight transaction. Splitting
    /// the insert into transactions of this size (each via `backgroundPool`, which
    /// yields to foreground/UI between chunks) bounds that wait to ~one small chunk.
    /// Kept well under SQLite's ~999 bound-variable limit so the per-chunk existence
    /// check stays a single `IN (...)` query.
    static let backfillInsertChunkSize = 100

    /// First-paint-gate timeout for the CoreML embedding load specifically (the one
    /// boot task that runs on BOTH launch kinds). On a FOREGROUND launch it resumes
    /// at first paint and this value is irrelevant; on a cold BACKGROUND launch
    /// (which never paints) it waits this long so the privileged NSE merge wins the
    /// CPU first, THEN loads the 45MB model. Sized comfortably above the unburdened
    /// merge's worst case (a few hundred ms incl. a cold first FTS open) — far below
    /// the earlier arbitrary 3s.
    static let embeddingLoadGateTimeoutSeconds: Double = 1

    /// Coalesce window (ms) for the read-through NSE-staging probe
    /// (`NSEDataBridge.stagingHasPending`). `PrioritizedDatabase.read` calls it
    /// before every async read; the probe is a cross-process read of the NSE's
    /// non-WAL staging file, so it runs at most once per this window. Between
    /// probes a freshly-staged row waits ≤ this long for a read-triggered merge —
    /// but the explicit boot/foreground/push merges (which bypass the probe) are
    /// the primary path, so this is only the safety-net's latency. Small enough to
    /// be imperceptible, large enough that frequent reads don't hammer the file.
    static let stagingProbeCoalesceMs: Double = 100

    /// Max age of a matched staging signature before the read-through path merges
    /// anyway (see `NSEDataBridge.mergeIfStagingPending`). A KEPT gradual row
    /// (`aiCompleted=0`, NSE still computing) makes the pending-probe answer "yes"
    /// for up to 60s; without the signature skip, EVERY async read re-ran a full
    /// ~45ms merge of an already-merged row (measured: 47 re-merges per push).
    /// The TTL bounds the worst case for anything the signature can't see
    /// (identical-signature content change, or a failed merge needing retry):
    /// it re-merges within this window regardless. Explicit merge triggers
    /// (foreground, push, syncStartup, action-gate) bypass the skip entirely.
    static let stagingMergeSignatureTTLSeconds: TimeInterval = 5

    /// Notification-tap resolve: how long to poll the in-memory staged snapshot
    /// + the indexed durable lookup before falling back to awaiting a full
    /// `mergeNSEStagingData` behind the coordinator. A tap at foreground-return
    /// races the syncStartup merge by MILLISECONDS: the merge publishes
    /// `latestStagedRows` within ~15ms of reading staging, but its phase-1 write
    /// can then run 4s+ under cold/saturated I/O — losing the race used to mean
    /// serializing behind that write (observed: `resolved via mergeFallback in
    /// 5658ms` where the snapshot appeared 14ms after the first check).
    static let notifTapStagedResolveWaitSeconds: TimeInterval = 1.5
    /// Poll step for the above wait.
    static let notifTapStagedResolvePollMs = 50

    /// BGAppRefresh earliest begin date. iOS controls actual timing;
    /// this is the minimum delay we request.
    static let bgAppRefreshIntervalSeconds: TimeInterval = 300 // 5 min

    /// Minimum time since last activity before an IMAP provider is considered stale
    /// and needs reconnection. Matches pool liveness check threshold.
    static let reconnectStalenessSeconds: TimeInterval = 120 // 2 min

    /// Minimum time between device registrations with push worker (cache TTL).
    static let deviceRegistrationCacheTTLSeconds: TimeInterval = 86_400 // 24h

    // MARK: - Network Timeouts (seconds)

    /// Timeout for IMAP/provider connect() during reconnect. TCP handshake + login.
    static let connectTimeoutSeconds: TimeInterval = 15
    /// Timeout for per-account sync during poll(). Prevents one stalled server from blocking others.
    static let perAccountSyncTimeoutSeconds: TimeInterval = 60
    /// Min seconds between WAL checkpoints. The checkpoint is invoked from many
    /// background/normal jobs (full/delta sync, backfill batches, maintenance) via
    /// `SyncEngine.checkpointWALThrottled`; this throttle stops a high-frequency caller
    /// (the embedding queue) from over-checkpointing while still bounding the WAL. SQLite
    /// autocheckpoint is disabled (see `AppDatabase.makePool`).
    static let walCheckpointMinIntervalSeconds: TimeInterval = 1.5
    /// Timeout for WiFi check (NWPathMonitor). Returns false if exceeded.
    static let wifiCheckTimeoutSeconds: TimeInterval = 5
    /// Timeout for per-account background delta sync (ensureConnected + delta).
    /// Accounts run in parallel, so wall-clock = max(per-account).
    /// 10s allows slow IMAP accounts (iCloud) to finish while body/AI runs in parallel.
    static let backgroundPerAccountTimeoutSeconds: TimeInterval = 10
    /// Timeout for IMAP connection pool checkout. Prevents indefinite queue when all connections are in use.
    static let imapLockTimeoutSeconds: TimeInterval = 30
    /// Timeout for a single IMAP batch operation (SELECT + BODYSTRUCTURE + part fetches).
    /// Safety cap — individual IMAP commands already have NIO-level timeouts (10s for fetchPart,
    /// 30s for SELECT). This catches pathological cases where many parts each timeout sequentially.
    static let imapBatchOperationTimeoutSeconds: TimeInterval = 30
    /// Timeout for SMTP send (connect + login + send + disconnect). Covers stalled SMTP servers.
    static let smtpSendTimeoutSeconds: TimeInterval = 30
    /// Hard cap on total LLM HTTP request time (seconds). Uses timeoutIntervalForResource
    /// which caps the entire request regardless of bytes received — prevents stalled
    /// connections from holding semaphore slots for 5-16 minutes (observed in device logs).
    /// Normal responses complete in 2-6s; tool-loop replies can take 1-2 min.
    /// 120s is generous while still killing the multi-minute stalls. Phase 2 (SSE heartbeat)
    /// will detect stalls in ~2s, making this a rarely-hit safety net.
    static let llmResourceTimeoutSeconds: TimeInterval = 120
    /// Hard cap for MAINTENANCE-class LLM calls (manual action-rules compaction):
    /// a single compaction of a large user_action.md (20K+ chars observed) can
    /// legitimately run for minutes, which the 120s cap killed (NSURLError -1001).
    /// Stall detection is still the SSE heartbeat watchdog (seconds); this cap is
    /// only the absolute safety net. Not used by background AI jobs, so
    /// llmJobDeadlineSeconds is unaffected.
    static let llmLongOpResourceTimeoutSeconds: TimeInterval = 420
    /// Hard cap on a single AI job's total wall time (seconds). Covers semaphore wait +
    /// HTTP request + GRDB writes. Must be above llmResourceTimeoutSeconds to avoid
    /// racing the HTTP timeout. Acts as safety net for any cause of unbounded job time.
    static let llmJobDeadlineSeconds: TimeInterval = 150
    /// Maximum wall time for awaitDrain() in BGProcessingTask (seconds). Prevents
    /// the drain poll loop from blocking setTaskCompleted() indefinitely if activeJobs
    /// counter is stale or jobs are stuck. Normal drains complete in seconds.
    static let awaitDrainMaxSeconds: TimeInterval = 300
    /// SSE heartbeat watchdog timeout (seconds). If no SSE event (keepalive or data)
    /// arrives within this window, the connection is considered stalled and cancelled.
    /// Backend sends heartbeat every 3s — 10s allows 3 missed heartbeats.
    static let sseHeartbeatTimeoutSeconds: TimeInterval = 10
    /// Timeout for a single pending operation (archive, move, flag, etc.) in drainPendingQueue.
    /// Prevents one stalled operation from blocking the entire queue.
    static let pendingOperationTimeoutSeconds: TimeInterval = 15

    // MARK: - IMAP Connection Pool

    /// NOOP liveness check threshold (seconds). Connections idle longer than this
    /// get a NOOP before reuse to verify the server hasn't closed them.
    static let imapPoolLivenessCheckSeconds: TimeInterval = 120
    /// Idle connection prune threshold (seconds). Connections not used for this
    /// long are closed to free server-side resources.
    static let imapPoolIdlePruneSeconds: TimeInterval = 300
    /// Minimum idle connections to keep after pruning (prevents excessive reconnects).
    static let imapPoolMinIdleConnections: Int = 1
    /// **Single source of truth** for IMAP connection ceiling.
    /// Used by: pool default max, work queue concurrency, probe target, backfill workers.
    /// Set high so the pool aggressively creates connections until the server rejects
    /// with `max_userip_connections=N`. The rejection locks maxConnections to N - reserved.
    /// Most IMAP servers allow 10-20 per user; enterprise can go higher.
    static let imapMaxConnectionCeiling: Int = 20

    // MARK: - Provider Work Queue Concurrency
    /// Max concurrent operations for Gmail API providers.
    static let gmailWorkQueueConcurrency: Int = 10
    /// Max concurrent operations for Exchange/Graph API providers.
    static let exchangeWorkQueueConcurrency: Int = 10

    // MARK: - Outbox Send Throttle

    /// Duration (seconds) of the UI Undo window. During this window, the toast
    /// shows an Undo button; the user can tap to cancel the send.
    static let outboxUndoHoldSeconds: TimeInterval = 5

    /// Safety buffer (seconds) between the UI Undo deadline and the drain's
    /// hold deadline. OutboxMessage.holdUntil = queuedAt + outboxUndoHoldSeconds
    /// + outboxClaimBufferSeconds, but the Undo button is only rendered for
    /// outboxUndoHoldSeconds. This gap eliminates TOCTOU races between
    /// user-taps-Undo and drain's atomic claim.
    static let outboxClaimBufferSeconds: TimeInterval = 1

    /// Duration (seconds) of the "Message sent ✓" confirmation phase shown
    /// after the Undo window closes. Total visible toast time =
    /// outboxUndoHoldSeconds + outboxClaimBufferSeconds + outboxPostSendConfirmSeconds.
    static let outboxPostSendConfirmSeconds: TimeInterval = 1.5

    /// Minimum gap (seconds) between successive sends in the serial drain loop.
    /// Task.sleep between iterations — no per-account tracking needed.
    /// 3s ≈ 20/min peak, below every provider's anti-abuse threshold.
    static let outboxMinSendGapSeconds: TimeInterval = 3

    /// Hard cap on recipient count (To + Cc + Bcc total) in a single compose.
    /// Below every major provider's per-message recipient cap.
    static let outboxMaxRecipients: Int = 50

    /// Threshold at which the compose UI starts showing the "N/50" counter
    /// next to the recipient field. Below this, counter is hidden.
    static let outboxMaxRecipientsWarnThreshold: Int = 45

    /// Grace window (seconds) an UNREFERENCED outbox attachment directory must
    /// age past before `cleanOrphanedAttachmentDirs` may reclaim its bytes.
    ///
    /// `queueSend` deliberately writes the attachment directory to disk BEFORE
    /// the gated write that commits the row referencing it (Outbox Reliability
    /// Rule 6 — file I/O must never run inside a DB transaction), so for the
    /// whole staging→commit window the live directory is referenced by NO
    /// committed row and a concurrent sweep would classify it as an orphan.
    /// The window is one gated write long (milliseconds to a few seconds on a
    /// contended writer); 10 minutes is orders of magnitude above that while
    /// still reclaiming crash orphans on the next `reconcileOutbox` pass.
    ///
    /// This is a BOUNDED MITIGATION, not a proof: nothing in the source bounds
    /// staging-to-commit latency below this interval, so the loss window is
    /// narrowed by orders of magnitude, not closed.
    static let attachmentOrphanReclaimGraceSeconds: TimeInterval = 600

    // MARK: - IMAP External-Deletion Reconcile (ADR-IOS-051)

    /// Tolerance for the deletion-reconcile trigger predicate
    /// (`localHeaderCount > serverCount + tolerance`). Local GRDB is a partial
    /// mirror of the server folder (optimistic local deletes remove rows
    /// immediately, so pending user deletions only LOWER local count), which
    /// makes ANY excess provable ghost evidence — hence default 0. Exists only
    /// to absorb transient in-flight appends; tune only with evidence.
    static let deletionReconcileCountTolerance = 0
    /// UID SEARCH chunk size for the deletion-reconcile walk. Aligned with the
    /// backfill walk's UID-SEARCH sizing: ~500 UIDs keeps both the explicit
    /// `UID SEARCH UID <set>` command and its response far below the 1MB NIO
    /// buffer limit even in dense folders.
    static let deletionReconcileChunkSize = 500
    /// Yield between reconcile-walk chunks (seconds) — mirrors the backfill
    /// worker's etiquette: the pool connection is checked out per chunk, and
    /// this gap lets user actions grab connections between chunks.
    static let deletionReconcileInterChunkDelaySeconds: TimeInterval = 0.1
    /// Circuit-breaker slack on top of the trigger's expected mismatch
    /// (`localCount − serverCount`): the walk may delete at most
    /// expected + slack rows, then aborts. Slack absorbs additional
    /// LEGITIMATE external deletions landing between the trigger's count
    /// snapshot and the walk's chunks (each slack deletion is still
    /// individually server-confirmed-absent). The breaker exists for the
    /// falsely-empty-SEARCH-response worst case — without it a parsing or
    /// protocol regression could read entire chunks as ghosts and wipe a
    /// folder; with it the walk aborts before the offending chunk.
    static let deletionReconcileCapSlack = 50

    // MARK: - Sent-Reply Parent Discovery

    /// When sync discovers a Sent-folder reply, we mark the parent message's
    /// `isReplied` locally (see ReplyParentResolver). For each updated parent
    /// we'd normally post a per-ID `.messageDataDidChange` so detail views
    /// refresh. On a first-ever Sent-folder full-sync this can be thousands of
    /// notifications in one batch — wasteful. Above this count we skip the
    /// per-ID fan-out and rely on the single `.inboxDataDidChange` to drive a
    /// list refresh.
    static let sentDiscoverNotifyPerIdLimit: Int = 50

    // MARK: - UIDVALIDITY purge-and-resync reaction (T4.S6)

    /// Iteration cap on the reaction's step-2.5 write barrier. UNLIKE
    /// `AccountManager.awaitWriteQueueDrainOrTimeout` (which races a wall clock and
    /// is ALLOWED to resume with work still queued), this barrier is bounded by an
    /// ITERATION count and the reaction ABORTS on exhaustion — it never "proceeds
    /// anyway". Purging a folder while a queued local write is still in flight
    /// against it would let that write land on rows the purge has already removed.
    static let uidValidityResetBarrierMaxAttempts = 5
    /// Delay between barrier attempts (seconds).
    static let uidValidityResetBarrierPollSeconds: TimeInterval = 0.05

    // MARK: - Verified epoch bootstrap for pre-populated folders (T4.S6b)

    /// Highest-UID half of the sample
    /// `SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch` FETCHes to decide
    /// whether a nil-epoch folder's EXISTING rows belong to the numbering the
    /// server is serving now.
    static let uidValidityVerifySampleHighCount = 4
    /// Lowest-UID half of the same sample. A renumber's strongest evidence lives
    /// HERE: after a UIDVALIDITY change the server re-assigns `1…M`, so a LOW local
    /// UID usually still EXISTS and addresses a DIFFERENT message — a positive
    /// MISMATCH. A HIGH local UID (near the old UIDNEXT, above `M`) usually does not
    /// exist at all, which is no evidence either way. A high-only sample would
    /// therefore reach the zero-agreements leg by ABSENCE rather than by PROOF.
    static let uidValidityVerifySampleLowCount = 4
    /// Minimum RFC-822 agreements required to stamp. Zero agreements is NOT
    /// verification: after a renumber "every sampled UID is simply missing" is the
    /// NORMAL shape, so it must never be read as consent. One agreement suffices —
    /// a stored Message-ID still answering at its stored UID is strong evidence the
    /// numbering is intact, and requiring more only fails closed on small folders.
    static let uidValidityVerifyMinAgreements = 1
    /// Batch size for the verification FETCH. Sized so the whole sample is served by
    /// ONE SELECT: `IMAPProvider.fetchMessageHeadersWithObservedEpoch` collapses its
    /// observed epoch to nil when two batches disagree, so a single batch makes
    /// `observedEpoch == nil` mean exactly "THIS SELECT reported no UIDVALIDITY" —
    /// the condition the anti-brick rule keys on.
    static let uidValidityVerifyFetchBatchSize =
        uidValidityVerifySampleHighCount + uidValidityVerifySampleLowCount
}
