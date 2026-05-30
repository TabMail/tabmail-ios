/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - QueueStorage

/// Generic FIFO queue storage with retry, dedup, and concurrency tracking.
/// Used by all in-memory processing queues (BodyFetch, AI, Embedding, BodyRender).
///
/// Extracts the shared queue management that was duplicated across 4 actor queues:
/// - queue array (FIFO ordering)
/// - inFlight set (items being processed)
/// - enqueued set (dedup on insert)
/// - retryCount dict (per-item retry tracking)
/// - activeJobs counter (concurrency limit)
///
/// Each actor owns a QueueStorage instance and delegates bookkeeping to it.
/// The actor retains full control over dispatch logic, job processing, and
/// queue-specific behavior (account grouping, config caching, etc.).
struct QueueStorage<Item: Hashable> {
    /// FIFO queue. Items stay here until confirmed done or max retries exceeded.
    private(set) var queue: [Item] = []

    /// Items currently being processed. Dispatch skips these.
    private(set) var inFlight = Set<Item>()

    /// Dedup set to prevent duplicate enqueue.
    private(set) var enqueued = Set<Item>()

    /// Retry count per item.
    private(set) var retryCount: [Item: Int] = [:]

    /// Items that verifiably completed in this session, keyed by completion timestamp.
    /// Prevents repopulate → re-enqueue → process → repopulate churn for items whose
    /// result was just written to GRDB but hasn't yet been observed by the work-remaining
    /// query (GRDB writes are serialized so the window is short; TTL is a belt).
    /// Entries older than `SyncConfig.recentlyCompletedTTLSeconds` are swept lazily on
    /// enqueue — after the TTL, the GRDB query is authoritative.
    private(set) var recentlyCompleted: [Item: Date] = [:]

    /// Number of currently running tasks.
    private(set) var activeJobs = 0

    var isEmpty: Bool { queue.isEmpty }
    var count: Int { queue.count }
    var pendingCount: Int { queue.count - inFlight.count }

    // MARK: - Enqueue

    /// Enqueue a single item. Returns true if the item was added (not a duplicate).
    ///
    /// Dedup against `enqueued` covers pending AND in-flight items — items are only
    /// removed from `enqueued` in `removeFromQueue` after completion. So any re-enqueue
    /// (from upstream push, drain-time repopulate, etc.) naturally no-ops if the job
    /// is mid-flight. No separate in-flight check required.
    @discardableResult
    mutating func enqueue(_ item: Item) -> Bool {
        sweepExpiredRecentlyCompleted()
        guard !enqueued.contains(item) else { return false }
        guard recentlyCompleted[item] == nil else { return false }
        enqueued.insert(item)
        queue.append(item)
        return true
    }

    /// Sweep `recentlyCompleted` entries older than the TTL.
    /// Called lazily from `enqueue` — cheap when the dict is small.
    private mutating func sweepExpiredRecentlyCompleted() {
        guard !recentlyCompleted.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-SyncConfig.recentlyCompletedTTLSeconds)
        recentlyCompleted = recentlyCompleted.filter { $0.value > cutoff }
    }

    /// Enqueue multiple items. Returns count of items actually added.
    @discardableResult
    mutating func enqueueBatch(_ items: [Item]) -> Int {
        var added = 0
        for item in items {
            if enqueue(item) { added += 1 }
        }
        return added
    }

    // MARK: - Dispatch

    /// Collect up to `maxJobs - activeJobs` candidates for dispatch.
    /// Each candidate is moved to the back of the queue and marked in-flight.
    /// Returns the candidates to launch.
    mutating func collectCandidates(maxJobs: Int) -> [Item] {
        var candidates: [Item] = []
        var scanIdx = 0
        while candidates.count + activeJobs < maxJobs, scanIdx < queue.count {
            let item = queue[scanIdx]
            if inFlight.contains(item) {
                scanIdx += 1
                continue
            }
            // Move to back (item stays in queue), mark in-flight
            queue.remove(at: scanIdx)
            queue.append(item)
            inFlight.insert(item)
            candidates.append(item)
            // Don't increment scanIdx — next item shifted into this position
        }
        return candidates
    }

    /// Increment active job count. Call when launching a task for a candidate.
    mutating func incrementActiveJobs() {
        activeJobs += 1
    }

    /// Decrement active job count. Call when a batch job completes.
    mutating func decrementActiveJobs() {
        activeJobs = max(0, activeJobs - 1)
    }

    // MARK: - Batch Item Completion (no activeJobs change)

    /// Finalize an item within a batch — remove or retry WITHOUT touching activeJobs.
    /// Use when activeJobs is managed at batch level (one increment/decrement per batch),
    /// not per-item. The caller must call decrementActiveJobs() once for the whole batch.
    @discardableResult
    mutating func batchItemCompleted(_ item: Item, shouldRetry: Bool, maxRetries: Int) -> Bool {
        inFlight.remove(item)

        if shouldRetry {
            let count = (retryCount[item] ?? 0) + 1
            if count <= maxRetries {
                retryCount[item] = count
            } else {
                removeFromQueue(item)
            }
        } else {
            recentlyCompleted[item] = Date()
            removeFromQueue(item)
        }

        return pendingCount > 0
    }

    // MARK: - Job Completion

    /// Called when a job completes. Decrements active count, clears in-flight,
    /// and either removes the item (success) or handles retry.
    /// Returns true if there are more items to dispatch.
    ///
    /// `shouldRetry=false` marks the item as verified-complete with a TTL. Callers
    /// that want to drop an item WITHOUT marking it complete (e.g., scope exited,
    /// row no longer exists) should use `abandonWithoutCompletion(_:)` instead —
    /// that path skips `recentlyCompleted` so any future enqueue fires immediately.
    @discardableResult
    mutating func jobCompleted(_ item: Item, shouldRetry: Bool, maxRetries: Int) -> Bool {
        activeJobs -= 1
        inFlight.remove(item)

        if shouldRetry {
            let count = (retryCount[item] ?? 0) + 1
            if count <= maxRetries {
                retryCount[item] = count
                // Item stays in queue at back — will cycle to front for retry
            } else {
                removeFromQueue(item)
            }
        } else {
            // Verified success — track in recentlyCompleted (TTL) to prevent
            // repopulate churn for the brief window before the GRDB query observes
            // the just-written result.
            recentlyCompleted[item] = Date()
            removeFromQueue(item)
        }

        return pendingCount > 0
    }

    /// Drop a job WITHOUT marking it complete. Use when the item has genuinely exited
    /// this queue's scope (row deleted, no longer in inbox, etc.) — future enqueue
    /// attempts can re-add it immediately because no `recentlyCompleted` entry is set.
    /// Decrements activeJobs and clears in-flight like jobCompleted.
    @discardableResult
    mutating func abandonWithoutCompletion(_ item: Item) -> Bool {
        activeJobs -= 1
        removeFromQueue(item)
        return pendingCount > 0
    }

    /// Current retry count for an item.
    func retryCount(for item: Item) -> Int {
        retryCount[item] ?? 0
    }

    // MARK: - Release Without Active Job

    /// Release an in-flight item back to pending state (e.g., connection failed before task launch).
    /// Does NOT decrement activeJobs — only use for items that never had incrementActiveJobs called.
    /// Handles retry/drop logic like jobCompleted but without touching the active job counter.
    @discardableResult
    mutating func releaseInFlight(_ item: Item, shouldRetry: Bool, maxRetries: Int) -> Bool {
        inFlight.remove(item)
        if shouldRetry {
            let count = (retryCount[item] ?? 0) + 1
            if count <= maxRetries {
                retryCount[item] = count
            } else {
                removeFromQueue(item)
            }
        } else {
            removeFromQueue(item)
        }
        return pendingCount > 0
    }

    /// Release an in-flight item back to pending WITHOUT touching retry counters.
    /// Used when a connection-level failure prevents dispatch — the item itself didn't fail.
    mutating func releaseInFlightOnly(_ item: Item) {
        inFlight.remove(item)
    }

    // MARK: - Queue Management

    /// Remove item from all tracking (success or permanent failure).
    mutating func removeFromQueue(_ item: Item) {
        if let idx = queue.firstIndex(of: item) {
            queue.remove(at: idx)
        }
        inFlight.remove(item)
        enqueued.remove(item)
        retryCount.removeValue(forKey: item)
    }

    /// Clear the entire queue (used when processing is disabled).
    /// Preserves recentlyCompleted to prevent re-enqueue churn on re-enable.
    mutating func clearAll() {
        queue.removeAll()
        inFlight.removeAll()
        enqueued.removeAll()
        retryCount.removeAll()
        // Note: recentlyCompleted intentionally NOT cleared — prevents churn
    }

    /// Cancel all in-flight items: full reset of queue state so
    /// repopulateFromDatabase() can rebuild from GRDB.
    /// Called on foreground return to release frozen tasks' bookkeeping.
    /// Must clear recentlyCompleted — otherwise a semaphore race
    /// (frozen task holds semaphore → fresh task skips → marked "completed")
    /// permanently blocks re-processing.
    mutating func cancelAllInFlight() {
        let count = inFlight.count
        inFlight.removeAll()
        activeJobs = 0
        enqueued.removeAll()
        queue.removeAll()
        retryCount.removeAll()
        recentlyCompleted.removeAll()
        if count > 0 {
            print("[QueueStorage] Cancelled \(count) in-flight items")
        }
    }

    /// Clear the recentlyCompleted map. Call on app launch or explicit refresh.
    mutating func resetRecentlyCompleted() {
        recentlyCompleted.removeAll()
    }

    /// Forget a single item's "recently completed" marker so a re-enqueue of
    /// the same item is accepted. Used by queues where a re-enqueue of the
    /// same key is a legitimate new signal (e.g. BackfillAIQueue — user
    /// re-teaches the same message after a prior refinement succeeded in the
    /// same session).
    mutating func forgetCompleted(_ item: Item) {
        recentlyCompleted.removeValue(forKey: item)
    }
}

// MARK: - Retry Write Helper

/// Retries a GRDB write up to `maxAttempts` times with delay between retries.
/// Used by drain queues (PendingOperation, Outbox, Calendar) for critical DB writes
/// that must succeed (e.g., deleting a completed op after remote execution).
func retryWrite<T: Sendable>(
    _ dbPool: DatabasePool,
    maxAttempts: Int = 3,
    retryDelay: Duration = .milliseconds(100),
    label: String,
    operation: @Sendable @escaping (Database) throws -> T
) async throws -> T {
    for attempt in 1...maxAttempts {
        do {
            return try await dbPool.write(operation)
        } catch {
            print("[\(label)] Write failed (attempt \(attempt)/\(maxAttempts)): \(error)")
            if attempt < maxAttempts {
                try? await Task.sleep(for: retryDelay)
            } else {
                throw error
            }
        }
    }
    fatalError("Unreachable")
}
