/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// Priority tier for provider work queue operations.
/// Workers drain the highest-priority non-empty tier first.
enum WorkPriority: Int, Comparable, Sendable {
    /// User-initiated actions (move, mark read, send, open message).
    /// Must complete first — the user is waiting.
    case userAction = 0
    /// Header fetching (sync, backfill headers, folder listing).
    /// More urgent than body fetch — headers populate the UI.
    case headerFetch = 1
    /// Body/attachment fetching, FTS indexing, AI processing.
    /// Background work that runs after headers are visible.
    case bodyFetch = 2

    static func < (lhs: WorkPriority, rhs: WorkPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Bounded-concurrency work queue for email providers.
/// ALL provider operations that hit the network MUST go through this queue.
/// It is the SINGLE concurrency gate for a given account.
///
/// Design:
/// - Three-tier priority queue: userAction > headerFetch > bodyFetch
/// - N concurrent worker slots (fixed at init)
/// - Workers pick from the highest-priority non-empty tier
/// - Failed items stay in queue for retry by the caller (queue doesn't retry internally)
/// - For IMAP, the connection pool's `checkout` is the real concurrency gate —
///   if no connections are available, callers wait in the pool's waiter queue.
///   The work queue provides priority scheduling on top of the pool.
actor ProviderWorkQueue {
    /// The underlying provider. Access only inside `execute()` closures for network ops.
    /// Direct access is safe for non-network property reads (e.g. type checks).
    nonisolated let provider: any EmailProvider

    private var maxConcurrency: Int
    private var activeCount: Int = 0
    private var isInvalidated = false
    /// Synchronous admission fence used by account removal before its first
    /// actor hop. The actor-owned bit below still owns waiter retirement.
    private nonisolated let invalidatedFence = Mutex<Bool>(false)

    /// A queued slot waiter. `id` lets cancellation remove the entry; the
    /// continuation resumes `true` when granted a slot, `false` when cancelled
    /// while waiting (no slot held — the caller must not run work).
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Three-tier waiter queues. Workers drain from tier 0 (userAction) first,
    /// then tier 1 (headerFetch), then tier 2 (bodyFetch).
    private var waiters: [[Waiter]] = [[], [], []]

    init(provider: any EmailProvider, maxConcurrency: Int) {
        self.provider = provider
        self.maxConcurrency = maxConcurrency
    }

    /// Increase max concurrency when the server's actual connection limit is discovered.
    /// Immediately wakes queued waiters if slots are now available.
    func updateMaxConcurrency(_ newMax: Int) {
        guard !isInvalidated, newMax > maxConcurrency else { return }
        let oldMax = maxConcurrency
        maxConcurrency = newMax
        if DebugModeManager.isLoggingEnabled() { print("[WorkQueue] Max concurrency updated \(oldMax) → \(newMax)") }
        // Wake waiters that can now run with the expanded capacity
        while activeCount < maxConcurrency {
            var woke = false
            for tier in 0..<waiters.count {
                if !waiters[tier].isEmpty {
                    let next = waiters[tier].removeFirst()
                    activeCount += 1
                    next.continuation.resume(returning: true)
                    woke = true
                    break
                }
            }
            if !woke { break }
        }
    }

    /// Execute work with bounded concurrency.
    /// Suspends until a worker slot is available. Higher-priority work gets slots first.
    /// Cancellation-aware: if the calling task is cancelled while waiting for a slot,
    /// throws `CancellationError` immediately — no slot is consumed and `work` never runs.
    func execute<T: Sendable>(priority: WorkPriority = .bodyFetch, _ work: @Sendable () async throws -> T) async throws -> T {
        guard !invalidatedFence.withLock({ $0 }) else { throw ProviderError.notConnected }
        try await acquireSlotCancellable(priority: priority)
        guard !invalidatedFence.withLock({ $0 }) else {
            releaseSlot()
            throw ProviderError.notConnected
        }
        do {
            let result = try await work()
            releaseSlot()
            return result
        } catch {
            releaseSlot()
            throw error
        }
    }

    /// Non-throwing variant for fire-and-forget work. NOT cancellation-aware:
    /// always waits for a slot and always runs `work`.
    /// Overload-resolution gotcha: a non-throwing Void closure resolves HERE even
    /// when written with `try await`. For the cancellation-aware path the closure
    /// must throw or return a value.
    func execute(priority: WorkPriority = .bodyFetch, _ work: @Sendable () async -> Void) async {
        guard !invalidatedFence.withLock({ $0 }) else { return }
        guard await acquireSlot(priority: priority) else { return }
        guard !invalidatedFence.withLock({ $0 }) else {
            releaseSlot()
            return
        }
        await work()
        releaseSlot()
    }

    /// Permanently close this account's queue. New work is refused and every
    /// queued waiter is resumed without running its closure. Already-active
    /// provider calls are retired by the matching provider disconnect.
    nonisolated func markInvalidated() {
        invalidatedFence.withLock { $0 = true }
    }

    func invalidate() {
        markInvalidated()
        guard !isInvalidated else { return }
        isInvalidated = true
        let stranded = waiters.flatMap { $0 }
        waiters = [[], [], []]
        for waiter in stranded {
            waiter.continuation.resume(returning: false)
        }
    }

    /// Current number of in-flight operations.
    var activeOperations: Int { activeCount }

    /// Total number of operations waiting for a slot across all tiers.
    var waitingCount: Int { waiters.reduce(0) { $0 + $1.count } }

    // MARK: - Slot Management

    private func acquireSlot(priority: WorkPriority) async -> Bool {
        guard !isInvalidated else { return false }
        if activeCount < maxConcurrency {
            activeCount += 1
            return true
        }
        // Queue is full — wait in the appropriate tier. No cancellation handler:
        // fire-and-forget callers run once a slot frees up unless account
        // teardown invalidates the queue first.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiters[priority.rawValue].append(Waiter(id: UUID(), continuation: continuation))
        }
    }

    /// Cancellation-aware acquire for the throwing `execute` path. Throws
    /// `CancellationError` if the task is cancelled while waiting; the waiter
    /// entry is removed so it never receives (or blocks) a slot.
    private func acquireSlotCancellable(priority: WorkPriority) async throws {
        try Task.checkCancellation()
        guard !isInvalidated else { throw ProviderError.notConnected }
        if activeCount < maxConcurrency {
            activeCount += 1
            return
        }
        // Queue is full — wait in the appropriate tier
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters[priority.rawValue].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
        if !granted {
            // `false` means either caller cancellation or account teardown.
            // Preserve CancellationError for the former and report the queue's
            // terminal state for the latter.
            try Task.checkCancellation()
            throw ProviderError.notConnected
        }
        // Race: releaseSlot can grant the slot before the spawned cancelWaiter
        // task runs on this actor. The waiter then holds a slot but its task is
        // cancelled — release and bail instead of running doomed work. (The
        // throw happens before execute's do/catch, so no double-release.)
        if Task.isCancelled {
            releaseSlot()
            throw CancellationError()
        }
    }

    /// Remove a cancelled waiter and resume it with `false` (no slot held).
    /// No-op if the waiter was already granted a slot by `releaseSlot` /
    /// `updateMaxConcurrency` (actor serialization makes this race-free).
    private func cancelWaiter(id: UUID) {
        for tier in 0..<waiters.count {
            if let idx = waiters[tier].firstIndex(where: { $0.id == id }) {
                let waiter = waiters[tier].remove(at: idx)
                waiter.continuation.resume(returning: false)
                return
            }
        }
    }

    private func releaseSlot() {
        // Wake the highest-priority waiter (slot transfers — activeCount unchanged)
        for tier in 0..<waiters.count {
            if !waiters[tier].isEmpty {
                let next = waiters[tier].removeFirst()
                next.continuation.resume(returning: true)
                return
            }
        }
        activeCount -= 1
    }
}
