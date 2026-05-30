/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

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

    /// Three-tier waiter queues. Workers drain from tier 0 (userAction) first,
    /// then tier 1 (headerFetch), then tier 2 (bodyFetch).
    private var waiters: [[CheckedContinuation<Void, Never>]] = [[], [], []]

    init(provider: any EmailProvider, maxConcurrency: Int) {
        self.provider = provider
        self.maxConcurrency = maxConcurrency
    }

    /// Increase max concurrency when the server's actual connection limit is discovered.
    /// Immediately wakes queued waiters if slots are now available.
    func updateMaxConcurrency(_ newMax: Int) {
        guard newMax > maxConcurrency else { return }
        let oldMax = maxConcurrency
        maxConcurrency = newMax
        print("[WorkQueue] Max concurrency updated \(oldMax) → \(newMax)")
        // Wake waiters that can now run with the expanded capacity
        while activeCount < maxConcurrency {
            var woke = false
            for tier in 0..<waiters.count {
                if !waiters[tier].isEmpty {
                    let next = waiters[tier].removeFirst()
                    activeCount += 1
                    next.resume()
                    woke = true
                    break
                }
            }
            if !woke { break }
        }
    }

    /// Execute work with bounded concurrency.
    /// Suspends until a worker slot is available. Higher-priority work gets slots first.
    func execute<T: Sendable>(priority: WorkPriority = .bodyFetch, _ work: @Sendable () async throws -> T) async throws -> T {
        await acquireSlot(priority: priority)
        do {
            let result = try await work()
            releaseSlot()
            return result
        } catch {
            releaseSlot()
            throw error
        }
    }

    /// Non-throwing variant for fire-and-forget work.
    func execute(priority: WorkPriority = .bodyFetch, _ work: @Sendable () async -> Void) async {
        await acquireSlot(priority: priority)
        await work()
        releaseSlot()
    }

    /// Current number of in-flight operations.
    var activeOperations: Int { activeCount }

    /// Total number of operations waiting for a slot across all tiers.
    var waitingCount: Int { waiters.reduce(0) { $0 + $1.count } }

    // MARK: - Slot Management

    private func acquireSlot(priority: WorkPriority) async {
        if activeCount < maxConcurrency {
            activeCount += 1
            return
        }
        // Queue is full — wait in the appropriate tier
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[priority.rawValue].append(continuation)
        }
    }

    private func releaseSlot() {
        // Wake the highest-priority waiter
        for tier in 0..<waiters.count {
            if !waiters[tier].isEmpty {
                let next = waiters[tier].removeFirst()
                next.resume()
                return
            }
        }
        activeCount -= 1
    }
}
