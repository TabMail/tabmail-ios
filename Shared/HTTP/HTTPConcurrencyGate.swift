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
    /// Parallel message fetches of one Outlook backfill or body-indexing stream.
    /// Kept below `maxConcurrentRequestsPerMailbox` so the stream alone never
    /// takes every slot; other requesters of the mailbox share the rest in arrival
    /// order.
    static let bodyFetchConcurrency = 2
}

/// A first-in, first-out limit on how many HTTP requests run at once.
///
/// `performHTTPRequest` holds one slot for each request it sends, and only while
/// that request is on the wire: a retry's back-off sleep and a token refresh hold
/// none. Waiters are served in arrival order, so no caller waits behind a later one.
/// A slot is released when the request finishes, fails or is cancelled. A caller
/// cancelled while queued keeps its place; it is admitted in turn, its request
/// fails at once, and it releases the slot.
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

    /// One decision under one lock: take a free slot, or queue. A slot is never
    /// free while anyone is queued (`release` hands it to the oldest waiter), so
    /// a free slot cannot let this caller pass an earlier one.
    private func acquire() async {
        await withCheckedContinuation { continuation in
            let admitted = state.withLock { state -> Bool in
                if state.inFlight < limit {
                    state.inFlight += 1
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if admitted { continuation.resume() }
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
/// four. `ExchangeProvider` and `ExchangeCalendarProvider` look theirs up from the
/// mailbox address they are built for. The notification service extension is a
/// separate process and cannot share it; it sends a couple of requests per
/// notification.
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
