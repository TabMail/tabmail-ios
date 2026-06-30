/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import UIKit

/// Event-driven AI processing queue for inbox messages.
/// Decoupled from sync/backfill — receives messages after body is written to FTS.
/// Reads body text from FTS (SearchIndex.bodyText), never fetches from provider.
/// Matches TB's messageProcessorQueue architecture: persistent queue, drain loop,
/// first-compute-wins, caching.
///
/// Concurrency model (matching TB):
/// - No limit on how many job tasks can run concurrently.
/// - All pending jobs are dispatched immediately as fire-and-forget Tasks.
/// - Queue dedup via QueueStorage (per-message, per-job-type).
/// - HTTP concurrency gated by BackendClient's internal LLM semaphore (32 slots).
///
/// Processing model: Three independent job types per message:
/// - Summary: generates blurb/todos/reminder. Also runs Device Sync probe and writes
///   any peer results (summary/action/reply) to GRDB immediately.
/// - Action: classifies action tag. Depends on summary — bails early if no summary yet.
/// - Reply: precomputes reply. Fully independent of summary/action.
///
/// Architecture: jobs stay in queue until confirmed done. On dispatch, job moves
/// to back of queue and is marked in-flight. Fire-and-forget task runs the AI call.
/// On success: job removed from queue. On failure: job stays in queue with backoff,
/// will be retried when backoff expires. No job is ever lost at any point.
///
/// Resilience contract:
/// - Jobs are ALWAYS in the queue until confirmed complete or max retries exceeded.
/// - Failed jobs cycle to back of FIFO with exponential backoff, retried up to maxQueueRetries.
/// - After max retries, job removed; repopulateFromDatabase catches on next foreground.
/// - App crash loses in-memory queue; repopulateFromDatabase rebuilds from GRDB on next launch.
/// - canProcessAI=false clears ephemeral queue; repopulateFromDatabase re-discovers when conditions change.
actor ActiveAIQueue {
    static let shared = ActiveAIQueue()

    /// Independent job: one AI task for one message.
    struct AIJob: Hashable {
        let headerId: String
        let accountId: String
        let jobType: JobType

        enum JobType: String, Hashable {
            case summary
            case action
            case reply
        }

        // Hashable by (headerId, jobType) — accountId is context, not identity
        func hash(into hasher: inout Hasher) {
            hasher.combine(headerId)
            hasher.combine(jobType)
        }
        static func == (lhs: AIJob, rhs: AIJob) -> Bool {
            lhs.headerId == rhs.headerId && lhs.jobType == rhs.jobType
        }
    }

    /// Shared queue bookkeeping (FIFO, dedup, retry, concurrency).
    private var storage = QueueStorage<AIJob>()

    /// Per-job backoff tracking. Jobs with nextAttemptAt > now are skipped by the drainer.
    /// On failure: nextAttemptAt = now + exponential backoff (1s, 2s, 4s, 8s, cap 30s).
    /// On success: removed from dict.
    private var backoff: [AIJob: Date] = [:]

    /// Retry count for backoff calculation (separate from QueueStorage retry count).
    private var backoffRetryCount: [AIJob: Int] = [:]


    /// Cached config snapshot from last dispatchPending() call.
    /// Reused by launchCandidates() to avoid MainActor hop on every slot refill.
    /// Invalidated (set to nil) when queue is drained or canProcessAI becomes false.
    private var cachedConfig: DispatchConfig?

    /// Tracks whether any actual LLM work was done since last drain.
    /// Prevents spammy "Queue fully drained" logs when items are enqueued
    /// but immediately found to need no work (already processed).
    private var didLLMWorkSinceDrain = false

    /// Tracks fired processing tasks so they can be cancelled on foreground return.
    /// Keyed by AIJob for easy cleanup when jobs complete.
    private var inFlightTasks: [AIJob: Task<Void, Never>] = [:]

    /// Watches for connectivity return when dispatch was deferred offline.
    /// Single task — avoids duplicate watchers from rapid enqueues while offline.
    private var connectivityWatchTask: Task<Void, Never>?

    /// Timestamp of last cancelAllInFlight(). Repopulate is throttled for 2s after cancel
    /// to prevent the cancel→repopulate→dispatch cycle from creating duplicate job storms.
    private var lastCancelAt: CFAbsoluteTime = 0

    /// Snapshot of MainActor state needed to launch AI jobs.
    private struct DispatchConfig {
        let aiService: AIService
        let kbText: String
        let actionPrompt: String
        let compositionPrompt: String
    }

    // Background-tagged: this queue's async writes (summary/action/reply, lease
    // and Device-Sync write-throughs) yield to foreground/UI work (NSE merge,
    // badge recount, inbox reload) instead of queueing ahead of it. Reads are
    // unaffected (WAL — they never contend the writer).
    private var dbPool: PrioritizedDatabase { AppDatabase.backgroundPool }

    // MARK: - Public API

    /// Enqueue an inbox message for AI processing after its body is written to FTS.
    /// Called by ActiveBodyQueue (backfill) and AccountManagerFetch (user-opened, if needed).
    /// Enqueues S + R only. Action is enqueued by the summary job on completion
    /// (action depends on summary — no point queuing it before summary exists).
    /// Dispatches immediately — no debounce. Matching TB's kickDelayMs: 0.
    func enqueue(headerId: String, accountId: String) {
        let jobs = [
            AIJob(headerId: headerId, accountId: accountId, jobType: .summary),
            AIJob(headerId: headerId, accountId: accountId, jobType: .reply),
        ]
        var added = 0
        for job in jobs {
            if storage.enqueue(job) { added += 1 }
        }
        guard added > 0 else { return }
        BackgroundSyncLogger.logAIProcessing("Enqueued \(headerId.prefix(30)) (\(added) jobs, total: \(storage.count))")
        scheduleDispatch()
    }

    /// Enqueue multiple messages at once (e.g., from repopulate).
    /// Enqueues S + R for each message. Also enqueues A if summary already exists
    /// but action is missing (crash recovery: S completed but A wasn't enqueued).
    func enqueueBatch(_ items: [(headerId: String, accountId: String)]) {
        var allJobs: [AIJob] = []
        for item in items {
            allJobs.append(AIJob(headerId: item.headerId, accountId: item.accountId, jobType: .summary))
            allJobs.append(AIJob(headerId: item.headerId, accountId: item.accountId, jobType: .reply))
            allJobs.append(AIJob(headerId: item.headerId, accountId: item.accountId, jobType: .action))
        }
        let added = storage.enqueueBatch(allJobs)
        guard added > 0 else { return }
        print("[ActiveAI] Enqueued \(added) jobs for \(items.count) messages (total: \(storage.count))")
        BackgroundSyncLogger.logAIProcessing("Enqueued batch of \(added) jobs for \(items.count) messages (total: \(storage.count))")
        scheduleDispatch()
    }

    /// Repopulate queue from GRDB on app launch / AI re-enable.
    /// Finds inbox messages that have body in FTS but are missing summary/action.
    /// Only the most recent `SyncConfig.maxRecentEmails` inbox messages are considered,
    /// matching TB's inboxManagement.maxRecentEmails cap. Older messages in large
    /// inboxes are not AI-processed to save LLM tokens and battery.
    func repopulateFromDatabase() async {
        // Throttle: skip if cancelAllInFlight() fired < 2s ago.
        // Prevents the cancel→repopulate→dispatch cycle from creating duplicate job storms
        // when the user rapidly switches apps (foreground→background→foreground).
        let sinceCancelMs = Int((CFAbsoluteTimeGetCurrent() - lastCancelAt) * 1000)
        if sinceCancelMs < 2000 {
            BackgroundSyncLogger.logAIProcessing("[REPOPULATE] throttled — \(sinceCancelMs)ms since cancel, waiting")
            try? await Task.sleep(for: .milliseconds(2000 - sinceCancelMs))
            guard !Task.isCancelled else { return }
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            // Single indexed SQL query — no per-message FTS probes.
            // bodyComplete flag is set when body is written to FTS, so we know
            // which messages have body text ready for AI processing.
            let items: [(headerId: String, accountId: String)] = try await dbPool.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, accountId FROM messageHeader
                    WHERE isInInbox = 1 AND bodyComplete = 1
                    AND (summaryBlurb IS NULL OR summaryBlurb = ''
                         OR actionTag IS NULL OR cachedReply IS NULL)
                    ORDER BY date DESC
                    LIMIT ?
                """, arguments: [SyncConfig.maxRecentEmails])
                return rows.map { ($0["id"] as String, $0["accountId"] as String) }
            }

            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if !items.isEmpty {
                print("[ActiveAI] Repopulated \(items.count) messages from database in \(ms)ms")
                BackgroundSyncLogger.logAIProcessing("Repopulated \(items.count) messages from database")
                enqueueBatch(items)
            } else {
                print("[ActiveAI] Repopulate: 0 messages need AI (\(ms)ms)")
            }
        } catch {
            print("[ActiveAI] Repopulate failed: \(error)")
        }
    }

    /// Cancel all in-flight processing tasks and reset queue state.
    /// Called on foreground return to release frozen tasks that held
    /// stale connections during iOS process suspension. Without this,
    /// suspended tasks block re-processing until they eventually resume
    /// with stale connections (can take 20+ minutes of wall-clock time).
    /// After calling this, repopulateFromDatabase() re-discovers items.
    func cancelAllInFlight() {
        lastCancelAt = CFAbsoluteTimeGetCurrent()
        let taskCount = inFlightTasks.count
        let activeJobsBefore = storage.activeJobs
        for (_, task) in inFlightTasks {
            task.cancel()
        }
        inFlightTasks.removeAll()
        storage.cancelAllInFlight()
        backoff.removeAll()
        backoffRetryCount.removeAll()
        cachedConfig = nil
        connectivityWatchTask?.cancel()
        connectivityWatchTask = nil
        if taskCount > 0 || activeJobsBefore > 0 {
            print("[ActiveAI] Cancelled \(taskCount) in-flight tasks on foreground return")
            BackgroundSyncLogger.logAIProcessing("Cancelled \(taskCount) in-flight tasks on foreground return (activeJobs: \(activeJobsBefore)→0, depth=\(storage.count))")
        }
    }

    /// Whether the queue has no pending items and no active jobs.
    var isIdle: Bool {
        storage.isEmpty && storage.activeJobs == 0
    }

    /// Wait for all current processing to complete (used by BGProcessingTask).
    /// Polls until queue is empty and no active jobs remain.
    /// Respects Task cancellation so BGProcessingTask can exit promptly
    /// after iOS fires the expiration handler — prevents blocking
    /// setTaskCompleted() for up to 120s (HTTP timeout).
    func awaitDrain() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        let maxSeconds = SyncConfig.awaitDrainMaxSeconds
        var lastHeartbeat = t0
        while true {
            if storage.isEmpty && storage.activeJobs == 0 { break }
            if Task.isCancelled {
                BackgroundSyncLogger.logAIProcessing("[DRAIN] cancelled (depth=\(storage.count), activeJobs=\(storage.activeJobs), inFlight=\(inFlightTasks.count))")
                break
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            if elapsed >= maxSeconds {
                BackgroundSyncLogger.logAIProcessing("[DRAIN] safety timeout after \(Int(elapsed))s (depth=\(storage.count), activeJobs=\(storage.activeJobs), inFlight=\(inFlightTasks.count))")
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastHeartbeat >= 5.0 {
                BackgroundSyncLogger.logAIProcessing("[DRAIN] waiting... (depth=\(storage.count), activeJobs=\(storage.activeJobs), inFlight=\(inFlightTasks.count), elapsed=\(Int(now - t0))s)")
                lastHeartbeat = now
            }
        }
    }

    // MARK: - Dispatch

    /// Dispatch immediately — no debounce. Matching TB's kickDelayMs: 0.
    /// Each enqueue triggers a dispatch attempt. With no concurrency limit on tasks,
    /// all pending jobs are dispatched as fire-and-forget Tasks. The LLM semaphore
    /// handles actual API call concurrency (32 max).
    private func scheduleDispatch() {
        Task {
            await dispatchPending()
        }
    }

    /// Poll for connectivity return and re-dispatch when online.
    /// Single watcher task — avoids duplicate polling from rapid enqueues while offline.
    private func scheduleDispatchOnReconnect() {
        guard connectivityWatchTask == nil else { return }
        connectivityWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                let connected = NetworkMonitor.checkConnected()
                if connected {
                    await self?.dispatchPending()
                    return
                }
            }
        }
    }

    /// Dispatch jobs from queue as independent fire-and-forget tasks.
    /// Phase 1: snapshot MainActor config (single hop, cached for subsequent dispatches).
    /// Phase 2: collect ALL pending candidates (no concurrency limit — semaphore gates LLM calls).
    /// Phase 3: launch tasks.
    private func dispatchPending() async {
        let isConnected = NetworkMonitor.checkConnected()
        guard isConnected else {
            if !storage.isEmpty {
                BackgroundSyncLogger.logAIProcessing("Dispatch deferred — no connectivity (\(storage.count) jobs pending)")
                scheduleDispatchOnReconnect()
            }
            return
        }
        connectivityWatchTask?.cancel()
        connectivityWatchTask = nil

        // Snapshot state — nonisolated reads where possible, minimal MainActor hop
        let aiDisabled = AIService.optOutStore.bool(forKey: AIService.optOutAllAIKey)
        let hasCompletedConsent = UserDefaults.standard.bool(forKey: "hasCompletedConsentGate")
        let deviceSyncConnected = DeviceSyncService.checkConnected()
        let kbText = PromptStore.kbTextSnapshot()
        let actionPrompt = PromptStore.actionMarkdownSnapshot()
        // compositionMarkdown includes template injection — needs MainActor
        let (hasSession, compositionPrompt) = await MainActor.run {
            (TabMailAuthService.hasSession(),
             PromptStore.shared.compositionMarkdown())
        }
        let subscriptionActive = AISubscriptionGate.shared.isActive
        let canProcessAI = hasSession && hasCompletedConsent && (!aiDisabled || deviceSyncConnected) && subscriptionActive
        guard canProcessAI else {
            if !storage.isEmpty {
                print("[ActiveAI] Skipping dispatch — canProcessAI=false (session=\(hasSession), consent=\(hasCompletedConsent), aiDisabled=\(aiDisabled), deviceSync=\(deviceSyncConnected), subscription=\(subscriptionActive))")
                BackgroundSyncLogger.logAIProcessing("Dispatch SKIPPED — canProcessAI=false (session=\(hasSession), consent=\(hasCompletedConsent), aiDisabled=\(aiDisabled), deviceSync=\(deviceSyncConnected), subscription=\(subscriptionActive)), clearing \(storage.count) jobs")
                // Clear ephemeral queue — repopulateFromDatabase() re-discovers from GRDB
                // when conditions change. Without this, items stuck in enqueued dedup set
                // block future repopulate from re-adding them.
                storage.clearAll()
                backoff.removeAll()
                backoffRetryCount.removeAll()
                cachedConfig = nil
            }
            return
        }

        // Cache config for subsequent dispatches (avoids MainActor hop)
        cachedConfig = DispatchConfig(
            aiService: AIService.shared,
            kbText: kbText,
            actionPrompt: actionPrompt,
            compositionPrompt: compositionPrompt
        )

        launchCandidates()
    }

    /// Collect and launch ALL pending candidates that are not backed off.
    /// Synchronous candidate collection + task launch. Uses cachedConfig set by dispatchPending().
    /// Called from dispatchPending() (after config fetch) and jobCompleted() (for newly arrived items).
    private func launchCandidates() {
        guard let config = cachedConfig else { return }

        let now = Date()
        // Int.max: no task concurrency limit — BackendClient's LLM semaphore gates actual API calls
        let allCandidates = storage.collectCandidates(maxJobs: Int.max)

        // Separate eligible from backed-off. Release backed-off items back to pending.
        var candidates: [AIJob] = []
        for job in allCandidates {
            if backoff[job] ?? .distantPast <= now {
                candidates.append(job)
            } else {
                // Still in backoff — release from in-flight back to pending
                storage.releaseInFlight(job, shouldRetry: true, maxRetries: .max)
            }
        }

        guard !candidates.isEmpty else { return }

        let networkPath = NetworkMonitor.checkExpensive() ? "cellular" : "wifi"
        print("[ActiveAI] Dispatching \(candidates.count) jobs (active: \(storage.activeJobs + candidates.count), queued: \(storage.pendingCount))")
        BackgroundSyncLogger.logAIProcessing("Dispatching \(candidates.count) jobs (active: \(storage.activeJobs + candidates.count), queued: \(storage.pendingCount), inFlight=\(inFlightTasks.count), net=\(networkPath))")
        for job in candidates {
            storage.incrementActiveJobs()

            let task = Task { [self] in
                let shouldRetry = await executeJob(job, config: config)
                await jobCompleted(job: job, shouldRetry: shouldRetry)
            }
            inFlightTasks[job] = task
        }
    }

    /// Called when a fire-and-forget job finishes. GRDB is the arbiter: we re-read the
    /// job's target field to decide success vs. retry, ignoring the executor's Bool.
    /// That way every failure path (FTS miss, LLM timeout, LLM empty, network drop,
    /// cancellation, provider gone, …) funnels into the same re-queue path — no
    /// executor-specific dead-letter is possible.
    ///
    /// Ordering: do the GRDB re-read BEFORE touching `storage`. `storage.jobCompleted`
    /// removes the item from `inFlight` + `enqueued`; reading GRDB first and updating
    /// storage atomically afterward keeps state transitions linear. The whole thing
    /// runs inside the actor so there is no true race, but the order keeps it clean.
    private func jobCompleted(job: AIJob, shouldRetry advisoryRetry: Bool) async {
        // If this job is no longer tracked in inFlightTasks, it was already
        // cleaned up by cancelAllInFlight() (foreground return or BGAppRefresh).
        // Skip storage update — cancel already reset activeJobs to 0.
        guard inFlightTasks.removeValue(forKey: job) != nil else {
            BackgroundSyncLogger.logAIProcessing("[JOB] \(job.headerId.prefix(30)).\(job.jobType.rawValue) completed but not in inFlightTasks (cancelled?) activeJobs=\(storage.activeJobs)")
            return
        }

        // Re-read GRDB to determine outcome. Three states:
        //  - target field present → verified success
        //  - header missing or not in inbox → scope exited
        //  - otherwise → retry (regardless of `advisoryRetry`)
        let outcome = await readJobOutcome(job)
        let retryCount = storage.retryCount(for: job)
        let shouldRetry: Bool

        switch outcome {
        case .verifiedComplete:
            _ = storage.jobCompleted(job, shouldRetry: false, maxRetries: .max)
            backoff.removeValue(forKey: job)
            backoffRetryCount.removeValue(forKey: job)
            shouldRetry = false
        case .scopeExited:
            _ = storage.abandonWithoutCompletion(job)
            backoff.removeValue(forKey: job)
            backoffRetryCount.removeValue(forKey: job)
            shouldRetry = false
        case .needsRetry:
            _ = storage.jobCompleted(job, shouldRetry: true, maxRetries: .max)
            // Exponential backoff: 1s, 2s, 4s, 8s, cap at 30s
            let backoffCount = backoffRetryCount[job] ?? 0
            let delaySecs = min(Double(1 << backoffCount), 30.0)
            backoff[job] = Date().addingTimeInterval(delaySecs)
            backoffRetryCount[job] = backoffCount + 1
            let newCount = retryCount + 1
            print("[ActiveAI] Retry \(newCount) for \(job.headerId.prefix(30)).\(job.jobType.rawValue) (backoff \(delaySecs)s, advisory=\(advisoryRetry))")
            BackgroundSyncLogger.logAIProcessing("Retry \(newCount) for \(job.headerId.prefix(30)).\(job.jobType.rawValue) (backoff \(delaySecs)s)")

            // Schedule a delayed re-dispatch for when backoff expires
            Task {
                try? await Task.sleep(for: .seconds(delaySecs))
                guard !Task.isCancelled else { return }
                launchCandidates()
            }
            shouldRetry = true
        }

        let hasMore = storage.pendingCount > 0

        // Dispatch any items that arrived while this job was running.
        // Skip on retry — the backoff Task above handles re-dispatch.
        if hasMore && !shouldRetry {
            launchCandidates()
        }

        // When all in-memory work is done, re-query GRDB for anything that slipped
        // past the push path (crash between write and enqueue, lost notify, etc.).
        // If the query returns rows, they're enqueued and drain continues. Only when
        // GRDB reports zero work is the queue truly idle.
        if storage.isEmpty && storage.activeJobs == 0 {
            let repopulated = await repopulateOnDrain()
            if !repopulated {
                cachedConfig = nil
                if didLLMWorkSinceDrain {
                    BackgroundSyncLogger.logAIProcessing("Queue fully drained — all jobs processed")
                    didLLMWorkSinceDrain = false
                }
                await ProactiveNotifyService.shared.onInboxUpdated()

                // Lazy TTL touch + eviction: refresh AI cache TTL for inbox messages
                // and purge expired entries. Runs once after all AI work completes.
                Task.detached {
                    SyncEngine.refreshAICacheTTLAndPurge(dbPool: AppDatabase.backgroundPool)
                }
            }
        }
    }

    /// Outcome of an AI job, determined by GRDB state rather than executor return value.
    private enum JobOutcome {
        case verifiedComplete
        case scopeExited
        case needsRetry
    }

    /// Re-read GRDB to decide whether the job succeeded. Ignores the executor Bool.
    private func readJobOutcome(_ job: AIJob) async -> JobOutcome {
        guard let message = try? await dbPool.read({ db in
            try MessageHeader.fetchOne(db, key: job.headerId)
        }) else {
            return .scopeExited // row gone
        }
        guard message.isInInbox else {
            return .scopeExited // archived / moved out
        }
        switch job.jobType {
        case .summary:
            let has = (message.summaryBlurb?.isEmpty == false)
            return has ? .verifiedComplete : .needsRetry
        case .action:
            return (message.actionTag != nil) ? .verifiedComplete : .needsRetry
        case .reply:
            return (message.cachedReply != nil) ? .verifiedComplete : .needsRetry
        }
    }

    /// Drain-time self-repopulate: re-run the work-remaining query and enqueue any
    /// hits. Returns true if any items were enqueued (caller skips idle-finalization).
    /// Called only when `storage.isEmpty && activeJobs == 0`, so no in-flight overlap.
    @discardableResult
    private func repopulateOnDrain() async -> Bool {
        do {
            let items: [(headerId: String, accountId: String)] = try await dbPool.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, accountId FROM messageHeader
                    WHERE isInInbox = 1 AND bodyComplete = 1
                    AND (summaryBlurb IS NULL OR summaryBlurb = ''
                         OR actionTag IS NULL OR cachedReply IS NULL)
                    ORDER BY date DESC
                    LIMIT ?
                """, arguments: [SyncConfig.maxRecentEmails])
                return rows.map { ($0["id"] as String, $0["accountId"] as String) }
            }
            guard !items.isEmpty else { return false }
            BackgroundSyncLogger.logAIProcessing("[DRAIN] Self-repopulate enqueued \(items.count) messages")
            enqueueBatch(items)
            return storage.pendingCount > 0
        } catch {
            print("[ActiveAI] Drain-time repopulate failed: \(error)")
            return false
        }
    }

    // MARK: - Job Execution

    /// Execute a single job. Routes to the appropriate handler by job type.
    /// Returns true if the job should be retried.
    private func executeJob(_ job: AIJob, config: DispatchConfig) async -> Bool {
        let jobT0 = CFAbsoluteTimeGetCurrent()
        // Bail early if cancelled (e.g., foreground return cancelled frozen tasks)
        guard !Task.isCancelled else {
            BackgroundSyncLogger.logAIProcessing("[JOB] \(job.headerId.prefix(30)).\(job.jobType.rawValue) cancelled before start")
            return false
        }

        // Background grace period for in-flight writes — primarily the 1Hz AI lease
        // heartbeat into the App Group staging DB. Suspending the process while a
        // sandbox-guarded SQLite write is pending trips RUNNINGBOARD 0xdead10cc.
        // Atomic claim via Mutex so the expiration handler and the `defer` cleanup
        // race-safely: whichever runs first ends the task and zeroes the id; the
        // other sees `.invalid` and no-ops.
        //
        // Expiration handler also signals the unified wind-down: cancel in-flight
        // AI Tasks so the remaining grace window is spent unwinding rather than
        // racing suspension. Mirrors the BGAppRefresh / BGProcessing handlers.
        let bgTaskId = Mutex<UIBackgroundTaskIdentifier>(.invalid)
        let beginId = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "ai-job-\(job.headerId.prefix(8))") {
                Task { await ActiveAIQueue.shared.cancelAllInFlight() }
                let toEnd = bgTaskId.withLock { let was = $0; $0 = .invalid; return was }
                if toEnd != .invalid {
                    UIApplication.shared.endBackgroundTask(toEnd)
                }
            }
        }
        bgTaskId.withLock { $0 = beginId }
        defer {
            let toEnd = bgTaskId.withLock { let was = $0; $0 = .invalid; return was }
            if toEnd != .invalid {
                Task { @MainActor in UIApplication.shared.endBackgroundTask(toEnd) }
            }
        }

        // Read message from GRDB — may have been processed by direct path already
        guard let message = try? await dbPool.read({ db in
            try MessageHeader.fetchOne(db, key: job.headerId)
        }) else { return false }

        // Large inbox gate: skip messages outside the top N most recent.
        if message.isInInbox {
            let isRecent = (try? await dbPool.read { db in
                let newerCount = try MessageHeader
                    .filter(Column("isInInbox") == true)
                    .filter(Column("date") > message.date)
                    .fetchCount(db)
                return newerCount < SyncConfig.maxRecentEmails
            }) ?? true
            if !isRecent { return false }
        }

        // Check if this specific job type is already done
        switch job.jobType {
        case .summary:
            guard message.summaryBlurb == nil || message.summaryBlurb?.isEmpty == true else { return false }
        case .action:
            guard message.actionTag == nil else { return false }
        case .reply:
            guard message.cachedReply == nil else { return false }
        }

        didLLMWorkSinceDrain = true

        // Read body text from FTS (already persisted by ActiveBodyQueue/backfill).
        // If body is missing, drop — body fetch pipeline will enqueue AI when body arrives.
        guard let plainText = try? await SearchIndex.shared.bodyText(headerId: job.headerId),
              !plainText.isEmpty else {
            // Diagnostic: distinguish failure modes to find root cause of FTS body loss
            let ftsDbReady = await SearchIndex.shared.isReady
            let hasMessageBody = (try? await dbPool.read { db in
                try MessageBody.fetchOne(db, key: job.headerId) != nil
            }) ?? false
            let ftsReason = await SearchIndex.shared.bodyTextDiagnostic(headerId: job.headerId)
            let diag = "bodyComplete=\(message.bodyComplete), hasMessageBody=\(hasMessageBody), ftsReady=\(ftsDbReady), fts=\(ftsReason)"
            print("[ActiveAI] No FTS body for \(job.headerId.prefix(30)) — dropping (\(diag))")
            BackgroundSyncLogger.logAIProcessing("No FTS body for \(job.headerId.prefix(30)) — dropping (\(diag))")
            BackgroundSyncLogger.logError("No FTS body: \(diag)", source: "activeAI:\(job.headerId.prefix(30))")
            return false
        }

        guard let account = try? await dbPool.read({ db in
            try Account.fetchOne(db, key: job.accountId)
        }) else { return false }

        // Device Sync probe: check if peer (TB addon) already computed this message's AI.
        // Runs ONCE per message (not per job) — writes peer summary/action/reply to GRDB so
        // individual jobs find the fields already filled and skip LLM. Matches TB architecture.
        if let rfc822 = message.rfc822MessageId, !rfc822.isEmpty {
            let probeKey = rfc822
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: ">", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !probeKey.isEmpty,
               let probeResults = await DeviceSyncService.shared.probeAICache(keys: [probeKey]),
               let cached = probeResults[probeKey] {
                // Write peer data to GRDB — individual jobs will find fields filled and skip LLM
                try? await dbPool.write { db in
                    guard var msg = try MessageHeader.fetchOne(db, key: job.headerId) else { return }
                    var changed = false
                    if let ps = cached.summary, msg.summaryBlurb == nil {
                        let blurb = ps.blurb.isEmpty ? nil : ps.blurb
                        if let blurb {
                            msg.summaryBlurb = blurb
                            msg.summaryTodos = ps.todos?.isEmpty == true ? nil : ps.todos
                            msg.reminderDate = ps.reminderDate?.isEmpty == true ? nil : ps.reminderDate
                            msg.reminderTime = ps.reminderTime?.isEmpty == true ? nil : ps.reminderTime
                            msg.reminderContent = ps.reminderContent?.isEmpty == true ? nil : ps.reminderContent
                            changed = true
                            BackgroundSyncLogger.logAIProcessing("DeviceSync summary HIT for \(job.headerId.prefix(30))")
                        }
                    }
                    if let pa = cached.action, msg.actionTag == nil, let tag = ActionTag(rawValue: pa) {
                        let effective = (tag == .reply && msg.isReplied) ? ActionTag.none : tag
                        msg.actionTag = effective
                        msg.tagSortOrder = effective.sortOrder
                        changed = true
                        BackgroundSyncLogger.logAIProcessing("DeviceSync action HIT for \(job.headerId.prefix(30)): \(tag.rawValue)")
                    }
                    if let pr = cached.reply, !pr.isEmpty, msg.cachedReply == nil {
                        msg.cachedReply = pr
                        changed = true
                        BackgroundSyncLogger.logAIProcessing("DeviceSync reply HIT for \(job.headerId.prefix(30))")
                    }
                    if changed {
                        try msg.save(db)
                        try MessageAICache.writeThrough(
                            accountId: account.id,
                            folderPath: message.folderPath,
                            rfc822MessageId: message.rfc822MessageId,
                            summaryBlurb: msg.summaryBlurb,
                            summaryTodos: msg.summaryTodos,
                            reminderDate: msg.reminderDate,
                            reminderTime: msg.reminderTime,
                            reminderContent: msg.reminderContent,
                            actionTag: msg.actionTag,
                            cachedReply: msg.cachedReply,
                            db: db
                        )
                    }
                }

                // Re-read message to pick up peer data — job may now skip LLM
                if let updated = try? await dbPool.read({ db in
                    try MessageHeader.fetchOne(db, key: job.headerId)
                }) {
                    // Re-check if this job is now done after peer data write
                    switch job.jobType {
                    case .summary:
                        if updated.summaryBlurb != nil && !(updated.summaryBlurb?.isEmpty ?? true) {
                            NotificationCenter.default.post(name: .messageDataDidChange, object: job.headerId)
                            return false
                        }
                    case .action:
                        if updated.actionTag != nil { return false }
                    case .reply:
                        if updated.cachedReply != nil { return false }
                    }
                }
            }
        }

        // NSE ownership lease: the NSE may be computing summary/action for this
        // same message RIGHT NOW (all pushes wake the NSE). Coordinate via the
        // lease columns on `nse_processed_message` to AVOID DOUBLE LLM work — but
        // NEVER by blocking. We (a) merge whatever the NSE has already staged and
        // skip our LLM if our job is satisfied (dedup), and (b) if the NSE is
        // actively claiming with nothing staged yet, DEFER and let the queue retry
        // with backoff — instead of the old up-to-28s sleep-poll that held a queue
        // slot (and, if the NSE timed out / died mid-AI, sat on the stale lease for
        // ~4s). When the NSE finishes, the merge brings its result in and a retry
        // finds the job done; if the NSE died, its lease goes stale (4s) and a retry
        // claims + computes. Reply is EXEMPT — the NSE never computes it — so it
        // never stalls behind an NSE summary/action run.
        let nseDB: DatabaseQueue? = NSEDataBridge.openStagingDB()
        var didClaimForMainApp = false
        var heartbeatTask: Task<Void, Never>?
        if let nseDB {
            let accountId = message.accountId
            let messageId = message.messageId
            // (a) Dedup — pull in any result the NSE has ALREADY staged (cheap,
            // idempotent) and skip our LLM if our job is now satisfied.
            if AIOwnershipLease.hasResult(db: nseDB, accountId: accountId, messageId: messageId) {
                await NSEDataBridge.mergeNSEStagingData()
                if let updated = try? await dbPool.read({ db in
                    try MessageHeader.fetchOne(db, key: job.headerId)
                }) {
                    switch job.jobType {
                    case .summary:
                        if updated.summaryBlurb != nil && !(updated.summaryBlurb?.isEmpty ?? true) {
                            BackgroundSyncLogger.logAIProcessing("NSE lease HIT (summary) for \(job.headerId.prefix(30))")
                            NotificationCenter.default.post(name: .messageDataDidChange, object: job.headerId)
                            return false
                        }
                    case .action:
                        if updated.actionTag != nil {
                            BackgroundSyncLogger.logAIProcessing("NSE lease HIT (action) for \(job.headerId.prefix(30))")
                            return false
                        }
                    case .reply:
                        // NSE doesn't generate replies; fall through to claim+run.
                        break
                    }
                }
            }
            // (b) If the NSE is ACTIVELY computing summary/action for this message
            // (fresh claim, nothing staged yet), DEFER — don't double-compute, don't
            // block. The queue retries with backoff; the dedup branch above catches
            // the NSE's result on a later pass, or the lease goes stale (NSE died)
            // and a retry claims below. Reply is exempt.
            if job.jobType != .reply,
               let existing = AIOwnershipLease.state(db: nseDB, accountId: accountId, messageId: messageId),
               existing.owner == .nse,
               AIOwnershipLease.isFresh(heartbeatMs: existing.heartbeatMs),
               !AIOwnershipLease.hasResult(db: nseDB, accountId: accountId, messageId: messageId) {
                BackgroundSyncLogger.logAIProcessing("NSE actively computing \(job.headerId.prefix(30)).\(job.jobType.rawValue) — defer, no block (retry)")
                return true // retry later — never block the queue slot on the NSE
            }
            // Phase 3 — claim for ourselves and start the heartbeat. Best-effort:
            // if the claim fails (rare — race with another fresh NSE wake), we
            // still run the LLM; the cost is one duplicate call, not correctness.
            didClaimForMainApp = AIOwnershipLease.tryClaim(
                db: nseDB, accountId: accountId, messageId: messageId, owner: .mainApp
            )
            if didClaimForMainApp {
                heartbeatTask = Task { [nseDB, accountId, messageId] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: AIOwnershipLease.heartbeatIntervalMs * 1_000_000)
                        if Task.isCancelled { break }
                        // Stop the drumbeat once the app is backgrounded — letting the
                        // lease go stale (4s) hands ownership back to NSE cleanly. A
                        // refresh racing iOS suspension is exactly what fires 0xdead10cc.
                        let backgrounded = await MainActor.run {
                            UIApplication.shared.applicationState == .background
                        }
                        if backgrounded { break }
                        AIOwnershipLease.refresh(db: nseDB, accountId: accountId, messageId: messageId, owner: .mainApp)
                    }
                }
            }
        }

        // Per-job wall clock deadline — safety net above the HTTP resource timeout.
        // Prevents any single job from consuming unbounded time (semaphore + HTTP + GRDB).
        let deadline = SyncConfig.llmJobDeadlineSeconds
        let result: Bool = await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                switch job.jobType {
                case .summary:
                    return await self.executeSummaryJob(job, message: message, plainText: plainText, account: account, config: config)
                case .action:
                    return await self.executeActionJob(job, message: message, plainText: plainText, account: account, config: config)
                case .reply:
                    return await self.executeReplyJob(job, message: message, plainText: plainText, account: account, config: config)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(deadline))
                return nil // sentinel: deadline fired
            }

            let first = await group.next() ?? nil
            group.cancelAll()

            if let value = first {
                return value // job completed before deadline
            }
            // The deadline task returned its nil sentinel. CAUTION: `try? await
            // Task.sleep` ALSO returns nil when its task is CANCELLED — and the AI
            // queue cancels in-flight jobs on user-activity prioritization / job
            // supersession, which fires immediately. So this branch is reached by
            // BOTH a genuine `deadline`-second timeout AND a fast cancellation.
            // Discriminate by whether we actually reached the deadline: `Task.sleep`
            // never under-sleeps, so jobMs >= deadline is a real timeout, while a
            // small jobMs is a cancellation. (Conflating them produced impossible
            // logs like "DEADLINE exceeded (254ms > 150s)".) Both still retry.
            let jobMs = Int((CFAbsoluteTimeGetCurrent() - jobT0) * 1000)
            if jobMs >= Int(deadline * 1000) {
                BackgroundSyncLogger.logAIProcessing("[JOB] \(job.headerId.prefix(30)).\(job.jobType.rawValue) DEADLINE exceeded (\(jobMs)ms > \(Int(deadline))s) — will retry")
            } else {
                BackgroundSyncLogger.logAIProcessing("[JOB] \(job.headerId.prefix(30)).\(job.jobType.rawValue) cancelled after \(jobMs)ms (deadline \(Int(deadline))s not reached) — will retry")
            }
            return true // retry
        }

        // Release lease + stop heartbeat. Conditional release (WHERE aiOwner =
        // "mainApp") means if an NSE run took over after a stale gap, we
        // won't clobber its claim.
        heartbeatTask?.cancel()
        if didClaimForMainApp, let nseDB {
            AIOwnershipLease.release(
                db: nseDB,
                accountId: message.accountId, messageId: message.messageId,
                owner: .mainApp
            )
        }

        let jobMs = Int((CFAbsoluteTimeGetCurrent() - jobT0) * 1000)
        if jobMs > 10000 {
            BackgroundSyncLogger.logAIProcessing("[JOB] \(job.headerId.prefix(30)).\(job.jobType.rawValue) total wall=\(jobMs)ms retry=\(result)")
        }
        return result
    }

    // MARK: - Summary Job

    /// Summary generation job. Calls generateSummary() directly — Device Sync probe
    /// already ran in executeJob() and wrote peer data to GRDB.
    /// Returns true if should retry.
    private func executeSummaryJob(
        _ job: AIJob, message: MessageHeader, plainText: String,
        account: Account, config: DispatchConfig
    ) async -> Bool {
        // Cache check: if summary already exists, skip LLM but still chain A.
        if let existing = message.summaryBlurb, !existing.isEmpty {
            BackgroundSyncLogger.logAIProcessing("Summary cache HIT for \(job.headerId.prefix(30))")
            // Always chain A — even from cache hit
            let actionJob = AIJob(headerId: job.headerId, accountId: job.accountId, jobType: .action)
            if storage.enqueue(actionJob) { scheduleDispatch() }
            return false
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        BackgroundSyncLogger.logAIProcessing("Summary START \(job.headerId.prefix(30))")

        do {
            let summary = try await config.aiService.generateSummary(
                subject: message.subject,
                from: message.from,
                fromAddress: message.fromAddress,
                date: message.date,
                bodyText: plainText,
                htmlContent: nil,
                userName: account.displayName,
                kbText: config.kbText
            )

            guard let blurb = summary.blurb, !blurb.isEmpty else {
                print("[ActiveAI] No blurb returned for \(message.messageId)")
                NotificationCenter.default.post(name: .aiDidFailForMessage, object: job.headerId)
                return false
            }

            try? await dbPool.write { db in
                guard var msg = try MessageHeader.fetchOne(db, key: job.headerId) else { return }
                msg.summaryBlurb = blurb
                msg.summaryTodos = summary.todos
                msg.reminderDate = summary.reminderDate
                msg.reminderTime = summary.reminderTime
                msg.reminderContent = summary.reminderContent
                try msg.save(db)

                try MessageAICache.writeThrough(
                    accountId: account.id,
                    folderPath: message.folderPath,
                    rfc822MessageId: message.rfc822MessageId,
                    summaryBlurb: blurb,
                    summaryTodos: summary.todos,
                    reminderDate: summary.reminderDate,
                    reminderTime: summary.reminderTime,
                    reminderContent: summary.reminderContent,
                    db: db
                )
            }

            NotificationCenter.default.post(name: .messageDataDidChange, object: job.headerId)
            await AISubscriptionGate.shared.openGate()
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            BackgroundSyncLogger.logAIProcessing("Summary complete for \(job.headerId.prefix(30)) in \(elapsed)ms")

            // Always chain A after summary completes
            let actionJob = AIJob(headerId: job.headerId, accountId: job.accountId, jobType: .action)
            if storage.enqueue(actionJob) { scheduleDispatch() }
        } catch {
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            print("[ActiveAI] Summary failed for \(message.messageId): \(error)")
            BackgroundSyncLogger.logAIProcessing("Summary FAILED for \(job.headerId.prefix(30)) after \(elapsed)ms: \(error.localizedDescription)")
            if Self.isSubscriptionError(error) {
                await AISubscriptionGate.shared.closeGate()
                return false
            }
            NotificationCenter.default.post(name: .aiDidFailForMessage, object: job.headerId)
            return true
        }

        return false
    }

    // MARK: - Action Job

    /// Action classification job. Chained by summary job on completion — summary
    /// is guaranteed to exist. Also enqueued by repopulate for crash recovery.
    /// Returns true if should retry.
    private func executeActionJob(
        _ job: AIJob, message: MessageHeader, plainText: String,
        account: Account, config: DispatchConfig
    ) async -> Bool {
        // Re-read to get latest state (summary may have been written by summary job)
        guard let msg = try? await dbPool.read({ db in
            try MessageHeader.fetchOne(db, key: job.headerId)
        }) else { return false }

        // Cache check: if action already exists, skip LLM
        guard msg.actionTag == nil else {
            BackgroundSyncLogger.logAIProcessing("Action cache HIT for \(job.headerId.prefix(30))")
            return false
        }

        // No summary yet? Drop — S job will chain A when it completes.
        guard let blurb = msg.summaryBlurb, !blurb.isEmpty else {
            BackgroundSyncLogger.logAIProcessing("Action skipped (no summary yet) \(job.headerId.prefix(30))")
            return false
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        BackgroundSyncLogger.logAIProcessing("Action START \(job.headerId.prefix(30))")

        do {
            let existingSummary = SummaryResult(
                blurb: msg.summaryBlurb,
                todos: msg.summaryTodos,
                reminderDate: msg.reminderDate,
                reminderTime: msg.reminderTime,
                reminderContent: msg.reminderContent
            )
            let action = try await config.aiService.classifyAction(
                subject: msg.subject,
                from: msg.from,
                fromAddress: msg.fromAddress,
                bodyText: plainText,
                htmlContent: nil,
                summary: existingSummary,
                userName: account.displayName,
                actionPrompt: config.actionPrompt
            )
            if let action {
                let effectiveAction: ActionTag = (try? await dbPool.write { db -> ActionTag in
                    guard var updMsg = try MessageHeader.fetchOne(db, key: job.headerId) else { return action }
                    let resolved = (action == .reply && updMsg.isReplied) ? ActionTag.none : action
                    updMsg.actionTag = resolved
                    updMsg.tagSortOrder = resolved.sortOrder
                    try updMsg.save(db)
                    try MessageAICache.writeThrough(
                        accountId: account.id,
                        folderPath: msg.folderPath,
                        rfc822MessageId: msg.rfc822MessageId,
                        actionTag: action,
                        db: db
                    )
                    return resolved
                }) ?? action
                if effectiveAction != action {
                    print("[ReplyDetect] ActiveAI action: reply→none for \(message.messageId)")
                }
                AccountManager.queueTagWrite(
                    accountId: account.id, messageId: message.messageId,
                    rfc822MessageId: message.rfc822MessageId,
                    tag: effectiveAction, folder: message.folderPath
                )
                NotificationCenter.default.post(name: .messageDataDidChange, object: job.headerId)
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                print("[ActiveAI] Action for \(message.messageId): \(effectiveAction.displayName) in \(elapsed)ms")
                BackgroundSyncLogger.logAIProcessing("Action complete for \(job.headerId.prefix(30)) in \(elapsed)ms")
                await AISubscriptionGate.shared.openGate()
            }
        } catch {
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            print("[ActiveAI] Action failed for \(message.messageId): \(error)")
            BackgroundSyncLogger.logAIProcessing("Action FAILED for \(job.headerId.prefix(30)) after \(elapsed)ms: \(error.localizedDescription)")
            if Self.isSubscriptionError(error) {
                await AISubscriptionGate.shared.closeGate()
                return false
            }
            return true // transient error — retry
        }

        return false
    }

    // MARK: - Reply Job

    /// Reply precompute job. Independent of summary/action — uses body text directly.
    /// Returns true if should retry.
    private func executeReplyJob(
        _ job: AIJob, message: MessageHeader, plainText: String,
        account: Account, config: DispatchConfig
    ) async -> Bool {
        // Cache check: if reply already exists, skip LLM
        if let existing = message.cachedReply, !existing.isEmpty {
            BackgroundSyncLogger.logAIProcessing("Reply cache HIT for \(job.headerId.prefix(30))")
            return false
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        BackgroundSyncLogger.logAIProcessing("Reply START \(job.headerId.prefix(30))")

        do {
            let reply = try await config.aiService.processReply(
                messageId: message.messageId,
                rfc822MessageId: message.rfc822MessageId,
                accountEmail: account.emailAddress,
                subject: message.subject,
                from: message.from,
                fromAddress: message.fromAddress,
                to: message.to,
                date: message.date,
                bodyText: plainText,
                htmlContent: nil,
                userName: account.displayName,
                kbText: config.kbText,
                compositionPrompt: config.compositionPrompt
            )
            if let reply {
                try? await dbPool.write { db in
                    guard var msg = try MessageHeader.fetchOne(db, key: job.headerId) else { return }
                    msg.cachedReply = reply
                    try msg.save(db)
                    if !reply.isEmpty {
                        try MessageAICache.writeThrough(
                            accountId: account.id,
                            folderPath: message.folderPath,
                            rfc822MessageId: msg.rfc822MessageId,
                            cachedReply: reply,
                            replyGeneratedAt: Date(),
                            db: db
                        )
                        let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                        print("[ActiveAI] Reply precomputed for \(message.messageId)")
                        BackgroundSyncLogger.logAIProcessing("Reply precomputed for \(job.headerId.prefix(30)) in \(elapsed)ms")
                    } else {
                        print("[ActiveAI] Reply filtered (sentinel) for \(message.messageId)")
                    }
                }
                NotificationCenter.default.post(name: .messageDataDidChange, object: job.headerId)
                await AISubscriptionGate.shared.openGate()
            }
        } catch {
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            print("[ActiveAI] Reply failed for \(message.messageId): \(error)")
            BackgroundSyncLogger.logAIProcessing("Reply FAILED for \(job.headerId.prefix(30)) after \(elapsed)ms: \(error.localizedDescription)")
            if Self.isSubscriptionError(error) {
                await AISubscriptionGate.shared.closeGate()
            }
        }

        return false
    }

    // MARK: - Subscription Error Detection

    /// Returns true if the error indicates the user needs an active subscription (402 or 403).
    private static func isSubscriptionError(_ error: any Error) -> Bool {
        if case BackendError.requestFailed(statusCode: 402) = error { return true }
        if case BackendError.forbidden = error { return true }
        return false
    }
}
