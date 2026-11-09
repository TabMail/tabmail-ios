/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

extension SyncEngine {
    /// Runs `pass` as the account's only sync pass, so a delta and a full sync
    /// of one account never run at the same time. A pass that arrives while
    /// another runs waits its turn, in arrival order, and then runs as it would
    /// have, on the account values its caller read before the wait; nothing is
    /// joined or skipped, and a caller's timeout includes the wait. The turn is
    /// released on every exit, a throw included, and handed straight to the
    /// oldest waiter.
    /// A waiter whose task was cancelled still takes its turn, and its pass
    /// stops at its first work-queue call.
    ///
    /// The provider's `ProviderWorkQueue` does not do this: it has several
    /// slots, so without this two passes of one account ran side by side, each
    /// writing the account's delta cursor.
    func oneSyncAtATime<T>(accountId: String, _ pass: () async throws -> T) async rethrows -> T {
        if !syncPassRunning.insert(accountId).inserted {
            await withCheckedContinuation { syncPassWaiters[accountId, default: []].append($0) }
        }
        defer { handOverSyncPass(accountId: accountId) }
        return try await pass()
    }

    /// Ends a pass: the oldest waiter takes the turn, or the account is free.
    private func handOverSyncPass(accountId: String) {
        guard var waiting = syncPassWaiters[accountId], !waiting.isEmpty else {
            syncPassRunning.remove(accountId)
            return
        }
        let next = waiting.removeFirst()
        syncPassWaiters[accountId] = waiting.isEmpty ? nil : waiting
        next.resume()
    }
}
