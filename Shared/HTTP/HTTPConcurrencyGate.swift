/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// Microsoft Graph's Outlook service limits, per app ID and mailbox
/// (learn.microsoft.com/graph/throttling-limits, "Outlook service limits"):
/// "Four concurrent requests", and 10,000 requests in 10 minutes. Concurrency is
/// the one a sync with several requests in flight reaches first (#426).
enum GraphConfig {
    /// The most Graph requests in flight at once for one mailbox, across mail,
    /// calendar, actions and sends in this process.
    static let maxConcurrentRequestsPerMailbox = 4
    /// Parallel message fetches for Outlook backfill and body indexing. Kept below
    /// `maxConcurrentRequestsPerMailbox` so a send, an action or a sync request
    /// waits behind at most this many background fetches.
    static let bodyFetchConcurrency = 2
}

/// A first-in, first-out limit on how many HTTP requests run at once.
///
/// `performHTTPRequest` holds one slot for each request it sends, and only while
/// that request is on the wire: a retry's back-off sleep and a token refresh hold
/// none. Waiters are served in arrival order, so no caller waits behind a later one.
/// A slot is released when the request finishes, fails or is cancelled.
final class HTTPConcurrencyGate: Sendable {
    private struct State {
        var inFlight = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    let limit: Int
    private let state = Mutex(State())

    init(limit: Int) {
        precondition(limit > 0, "HTTPConcurrencyGate needs at least one slot")
        self.limit = limit
    }

    /// Run `body` holding one slot, waiting first if every slot is taken.
    func withSlot<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        let admitted = state.withLock { state -> Bool in
            guard state.inFlight < limit else { return false }
            state.inFlight += 1
            return true
        }
        if admitted { return }
        await withCheckedContinuation { continuation in
            state.withLock { state in
                // A slot may have opened since the check above. The queue must be
                // empty too, or this caller would pass the ones already waiting.
                if state.inFlight < limit, state.waiters.isEmpty {
                    state.inFlight += 1
                    continuation.resume()
                } else {
                    state.waiters.append(continuation)
                }
            }
        }
    }

    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if state.waiters.isEmpty {
                state.inFlight -= 1
                return nil
            }
            // Hand the slot straight to the oldest waiter: `inFlight` stays the same.
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}

/// One `HTTPConcurrencyGate` per Outlook mailbox, shared by every provider of that
/// mailbox in this process, so mail and calendar requests count against the same
/// four. The notification service extension is a separate process and cannot share
/// it; it sends a couple of requests per notification.
enum GraphMailboxGates {
    private static let gates = Mutex<[String: HTTPConcurrencyGate]>([:])

    static func gate(for mailbox: String) -> HTTPConcurrencyGate {
        let key = mailbox.lowercased()
        return gates.withLock { gates in
            if let gate = gates[key] { return gate }
            let gate = HTTPConcurrencyGate(limit: GraphConfig.maxConcurrentRequestsPerMailbox)
            gates[key] = gate
            return gate
        }
    }
}
