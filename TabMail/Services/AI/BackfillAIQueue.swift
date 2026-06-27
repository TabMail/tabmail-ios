/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Durable queue for fire-and-forget LLM refinement jobs:
/// - `.actionRefine` — `autoUpdateUserPromptOnTag` (tag teach → `user_action.md` patch).
/// - `.kbRefine`     — `refineKB` on chat session idle-expiry (session turns → `user_kb.md`).
///
/// Each job is snapshotted into the `pendingAIRefinement` GRDB table at enqueue time
/// (the source message or chat session may vanish before drain — we must survive).
/// In-memory `QueueStorage<String>` tracks in-flight dedupKeys; backoff + retry count
/// are in-memory too and reset on launch. Row existence = work to do; row deletion = done.
///
/// Pattern mirrors `BackfillBodyQueue` / `BackfillEmbeddingQueue` / `ActiveAIQueue`:
/// `scheduleDispatch` (debounced) + `cancelAllInFlight` + `awaitDrain` + `repopulateOnDrain`
/// safety net. `maxActiveBatches = 1` because `PromptStore` mutations serialize at the
/// MainActor boundary and refinement throughput need is low.
actor BackfillAIQueue {
    static let shared = BackfillAIQueue()

    // MARK: - State

    /// dedupKeys awaiting drain. FIFO, in-memory only; GRDB is the durability layer.
    private var storage = QueueStorage<String>()

    /// Per-dedupKey next-attempt time. Filtered during candidate collection.
    private var backoff: [String: Date] = [:]
    private var backoffRetryCount: [String: Int] = [:]

    private var debounceTask: Task<Void, Never>?
    private var connectivityWatchTask: Task<Void, Never>?

    /// Always 0 or 1 — sequential drain. See class-level rationale.
    private var activeBatchCount = 0
    private let maxActiveBatches = 1

    private var dbPool: DatabasePool { AppDatabase.dbPool }

    // MARK: - Public API — enqueue

    /// Enqueue a tag-teach refinement. UPSERTs on `dedupKey` so re-teaching the
    /// same (message, tag) supersedes the earlier snapshot in place.
    /// Errors are caught and logged (matches `AccountManagerQueue.queueTagWrite` pattern).
    func enqueueActionRefine(_ snapshot: ActionRefineSnapshot) async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            let row = try PendingAIRefinement.make(snapshot, now: now)
            try await dbPool.write { db in try row.insert(db) }
            BackgroundSyncLogger.logBackfillAI("enqueue actionRefine dedupKey=\(snapshot.dedupKey)")
        } catch {
            // Suspension abort (ADR-IOS-041) is benign — re-enqueued on next wake.
            if !error.isDatabaseSuspensionAbort {
                BackgroundSyncLogger.logBackfillAI("enqueue actionRefine FAILED dedupKey=\(snapshot.dedupKey) error=\(error)")
            }
            return
        }
        storage.forgetCompleted(snapshot.dedupKey)
        _ = storage.enqueue(snapshot.dedupKey)
        scheduleDispatch()
    }

    /// Enqueue a KB-refine on session-end. UPSERTs on sessionId so repeated
    /// idle-expiries for the same session collapse into one row.
    func enqueueKBRefine(_ snapshot: KBRefineSnapshot) async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            let row = try PendingAIRefinement.make(snapshot, now: now)
            try await dbPool.write { db in try row.insert(db) }
            BackgroundSyncLogger.logBackfillAI("enqueue kbRefine dedupKey=\(snapshot.dedupKey) turns=\(snapshot.turns.count)")
        } catch {
            // Suspension abort (ADR-IOS-041) is benign — re-enqueued on next wake.
            if !error.isDatabaseSuspensionAbort {
                BackgroundSyncLogger.logBackfillAI("enqueue kbRefine FAILED dedupKey=\(snapshot.dedupKey) error=\(error)")
            }
            return
        }
        storage.forgetCompleted(snapshot.dedupKey)
        _ = storage.enqueue(snapshot.dedupKey)
        scheduleDispatch()
    }

    // MARK: - Public API — lifecycle

    /// Launch + foreground. TTL sweep, then load queued dedupKeys into QueueStorage.
    func repopulateFromDatabase() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let cutoff = now - SyncConfig.backfillAIJobTTLMillis

        // 1. TTL sweep.
        var dropped = 0
        do {
            dropped = try await dbPool.write { db -> Int in
                try db.execute(
                    sql: "DELETE FROM pendingAIRefinement WHERE createdAt < ?",
                    arguments: [cutoff]
                )
                return db.changesCount
            }
        } catch {
            if !error.isDatabaseSuspensionAbort {
                BackgroundSyncLogger.logBackfillAI("repopulate TTL sweep FAILED error=\(error)")
            }
        }

        // 2. Load remaining rows FIFO into QueueStorage.
        var loaded = 0
        do {
            let keys: [String] = try await dbPool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT dedupKey FROM pendingAIRefinement
                    ORDER BY createdAt ASC
                """)
            }
            loaded = storage.enqueueBatch(keys)
        } catch {
            BackgroundSyncLogger.logBackfillAI("repopulate load FAILED error=\(error)")
            return
        }

        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        BackgroundSyncLogger.logBackfillAI("repopulateFromDatabase loaded=\(loaded) droppedTTL=\(dropped) (\(ms)ms)")

        // Re-kick on every wake — covers items left pending by a suspend-abandoned
        // cycle (ADR-IOS-046), which `loaded` (new rows only) would miss.
        if storage.pendingCount > 0 { scheduleDispatch() }
    }

    /// Foreground-return: wipe in-memory state. GRDB rows are preserved —
    /// the next `repopulateFromDatabase` re-loads them.
    func cancelAllInFlight() {
        let depth = storage.count
        storage.cancelAllInFlight()
        backoff.removeAll()
        backoffRetryCount.removeAll()
        debounceTask?.cancel()
        debounceTask = nil
        connectivityWatchTask?.cancel()
        connectivityWatchTask = nil
        if depth > 0 {
            BackgroundSyncLogger.logBackfillAI("cancelAllInFlight depth=\(depth) (GRDB rows preserved)")
        }
    }

    /// BGProcessing / tests: wait until truly idle (queue empty + no batch running).
    func awaitDrain() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        var lastHeartbeat = t0
        while true {
            if storage.isEmpty && activeBatchCount == 0 { break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(200))
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastHeartbeat >= 5.0 {
                let elapsed = Int(now - t0)
                BackgroundSyncLogger.logBGProcessing(
                    "BackfillAI draining... (depth=\(storage.count), active=\(activeBatchCount), elapsed=\(elapsed)s)"
                )
                lastHeartbeat = now
            }
        }
    }

    var isIdle: Bool {
        storage.isEmpty && activeBatchCount == 0
    }

    // MARK: - Dispatch (private)

    private func scheduleDispatch() {
        guard activeBatchCount < maxActiveBatches else { return }
        guard storage.pendingCount > 0 else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await self?.dispatchBatch()
        }
    }

    private func scheduleDispatchOnReconnect() {
        guard connectivityWatchTask == nil else { return }
        connectivityWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                if NetworkMonitor.checkConnected() {
                    await self?.scheduleDispatch()
                    await self?.clearConnectivityWatch()
                    return
                }
            }
        }
    }

    private func clearConnectivityWatch() {
        connectivityWatchTask = nil
    }

    private func dispatchBatch() async {
        debounceTask = nil

        // Network gate.
        guard NetworkMonitor.checkConnected() else {
            if !storage.isEmpty { scheduleDispatchOnReconnect() }
            return
        }
        guard activeBatchCount < maxActiveBatches else { return }

        // ADR-IOS-046: abandon if the GRDB pool is suspended — refinement writes
        // would only abort; the queue re-dispatches on the next wake.
        guard !DatabaseSuspension.isSuspended else {
            #if DEBUG
            print("[BackfillAI] DB suspended — abandoning dispatch (ADR-IOS-046)")
            #endif
            return
        }

        // Collect candidates; drop those still in backoff.
        let rawCandidates = storage.collectCandidates(
            maxJobs: storage.activeJobs + SyncConfig.backfillAIBatchSize
        )
        let nowDate = Date()
        var candidates: [String] = []
        for key in rawCandidates {
            if let nextAttempt = backoff[key], nextAttempt > nowDate {
                // Not yet ready — release back to queue without retry bump.
                storage.releaseInFlightOnly(key)
            } else {
                candidates.append(key)
            }
        }
        guard !candidates.isEmpty else {
            // All candidates were in backoff — re-schedule a bit later.
            if storage.pendingCount > 0 {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(SyncConfig.backfillAIBackoffInitial))
                    await self?.scheduleDispatch()
                }
            }
            return
        }

        activeBatchCount += 1
        // NOTE: no defer decrement — we must decrement BEFORE the idle check
        // below so that `scheduleDispatch` (called from `repopulateOnDrain` if
        // it finds orphan rows) passes its `activeBatchCount < maxActiveBatches`
        // gate. Matches `BackfillBodyQueue`'s pattern (line 354 + idle check).
        // No early return exists between here and the decrement, so explicit
        // decrement is safe.

        for key in candidates {
            await processOne(dedupKey: key)
        }

        // Power-aware inter-batch delay.
        let delay = await BackfillProfile.current().interCycleActiveDelay
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }

        activeBatchCount -= 1

        if storage.pendingCount > 0 {
            scheduleDispatch()
        } else if storage.isEmpty && activeBatchCount == 0 {
            // Drain-time safety net — catches rows written to GRDB but missed
            // by the push-path enqueue (crash between insert and enqueue, etc.).
            await repopulateOnDrain()
        }
    }

    // MARK: - Per-item processing

    private func processOne(dedupKey: String) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        let retryCount = storage.retryCount(for: dedupKey)
        BackgroundSyncLogger.logBackfillAI("claim dedupKey=\(dedupKey) retry=\(retryCount)")

        // Fetch row from GRDB.
        let row: PendingAIRefinement?
        do {
            row = try await dbPool.read { db in
                try PendingAIRefinement.fetchOne(db, key: dedupKey)
            }
        } catch {
            BackgroundSyncLogger.logBackfillAI("fetch FAILED dedupKey=\(dedupKey) error=\(error) — transient")
            await handleTransient(dedupKey: dedupKey, error: error)
            return
        }

        guard let row else {
            // Row vanished (e.g., TTL sweep raced). Treat as completed.
            _ = storage.batchItemCompleted(
                dedupKey,
                shouldRetry: false,
                maxRetries: SyncConfig.maxQueueRetries
            )
            backoff.removeValue(forKey: dedupKey)
            backoffRetryCount.removeValue(forKey: dedupKey)
            BackgroundSyncLogger.logBackfillAI("skip dedupKey=\(dedupKey) reason=row-missing")
            return
        }

        guard let jobType = BackfillAIJobType(rawValue: row.jobType) else {
            BackgroundSyncLogger.logBackfillAI("drop dedupKey=\(dedupKey) reason=unknown-jobType=\(row.jobType)")
            await deleteRow(dedupKey: dedupKey)
            _ = storage.batchItemCompleted(
                dedupKey,
                shouldRetry: false,
                maxRetries: SyncConfig.maxQueueRetries
            )
            return
        }

        // Dispatch.
        do {
            switch jobType {
            case .actionRefine:
                let snap = try row.decodeActionRefine()
                await dispatchActionRefine(snap)
            case .kbRefine:
                let snap = try row.decodeKBRefine()
                await dispatchKBRefine(snap)
            }
        } catch {
            // Decode error is permanent — drop.
            BackgroundSyncLogger.logBackfillAI("drop dedupKey=\(dedupKey) reason=decode-error error=\(error)")
            await deleteRow(dedupKey: dedupKey)
            _ = storage.batchItemCompleted(
                dedupKey,
                shouldRetry: false,
                maxRetries: SyncConfig.maxQueueRetries
            )
            return
        }

        // Success path. The existing refinement functions handle their own
        // skip/conflict/merge cases internally and log. We treat any normal
        // return as "done"; delete the row.
        await deleteRow(dedupKey: dedupKey)
        _ = storage.batchItemCompleted(
            dedupKey,
            shouldRetry: false,
            maxRetries: SyncConfig.maxQueueRetries
        )
        backoff.removeValue(forKey: dedupKey)
        backoffRetryCount.removeValue(forKey: dedupKey)
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        BackgroundSyncLogger.logBackfillAI("success dedupKey=\(dedupKey) latencyMs=\(ms)")
    }

    private func handleTransient(dedupKey: String, error: Error) async {
        let prior = backoffRetryCount[dedupKey] ?? 0
        let next = prior + 1
        if next > SyncConfig.maxQueueRetries {
            BackgroundSyncLogger.logBackfillAI("drop dedupKey=\(dedupKey) reason=retries-exhausted (\(next))")
            await deleteRow(dedupKey: dedupKey)
            storage.removeFromQueue(dedupKey)
            backoff.removeValue(forKey: dedupKey)
            backoffRetryCount.removeValue(forKey: dedupKey)
            return
        }
        let delay = min(
            SyncConfig.backfillAIBackoffInitial * pow(2.0, Double(next)),
            SyncConfig.backfillAIBackoffCap
        )
        backoffRetryCount[dedupKey] = next
        backoff[dedupKey] = Date().addingTimeInterval(delay)
        _ = storage.batchItemCompleted(
            dedupKey,
            shouldRetry: true,
            maxRetries: SyncConfig.maxQueueRetries
        )
        BackgroundSyncLogger.logBackfillAI(
            "transientFail dedupKey=\(dedupKey) retry=\(next) backoffSec=\(Int(delay)) error=\(error)"
        )
    }

    private func deleteRow(dedupKey: String) async {
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "DELETE FROM pendingAIRefinement WHERE dedupKey = ?",
                    arguments: [dedupKey]
                )
            }
        } catch {
            if !error.isDatabaseSuspensionAbort {
                BackgroundSyncLogger.logBackfillAI("delete FAILED dedupKey=\(dedupKey) error=\(error)")
            }
        }
    }

    // MARK: - Dispatchers (call existing refinement functions unchanged)

    private func dispatchActionRefine(_ s: ActionRefineSnapshot) async {
        let currentActionMd = PromptStore.actionMarkdownSnapshot()
        await AIService.shared.autoUpdateUserPromptOnTag(
            subject: s.subject,
            from: s.from,
            summaryBlurb: s.summaryBlurb,
            summaryTodos: s.summaryTodos,
            originalAction: s.originalAction,
            userManualTag: s.userManualTag ?? "",
            currentUserActionMd: currentActionMd
        )
    }

    private func dispatchKBRefine(_ s: KBRefineSnapshot) async {
        await KBRefinementService.shared.refineKB(sessionTurns: s.toChatTurns())
    }

    // MARK: - Drain-time safety net

    /// Re-query GRDB after the queue empties to catch any rows the push path
    /// missed (crash between INSERT and `storage.enqueue`, etc.). Only called
    /// when `storage.isEmpty && activeBatchCount == 1` (we still hold the slot
    /// via the defer), so no in-flight overlap.
    private func repopulateOnDrain() async {
        do {
            let keys: [String] = try await dbPool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT dedupKey FROM pendingAIRefinement
                    ORDER BY createdAt ASC
                """)
            }
            guard !keys.isEmpty else { return }
            let added = storage.enqueueBatch(keys)
            if added > 0 {
                BackgroundSyncLogger.logBackfillAI("repopulateOnDrain enqueued \(added) items")
                scheduleDispatch()
            }
        } catch {
            BackgroundSyncLogger.logBackfillAI("repopulateOnDrain FAILED error=\(error)")
        }
    }
}
