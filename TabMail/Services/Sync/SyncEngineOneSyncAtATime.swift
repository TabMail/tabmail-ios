/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

extension SyncEngine {
    /// Runs `pass` as the account's only sync pass, so a delta and a full sync
    /// of one account never run at the same time. A pass that arrives while
    /// another runs waits its turn, in arrival order, and then runs; nothing is
    /// joined, and a caller's timeout includes the wait. The pass's first step
    /// inside its turn is `accountAtTurnStart`. The turn is released on every
    /// exit, a throw included, and handed straight to the oldest waiter.
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

    /// The account's row as it is now, read as a pass's first step inside its
    /// turn; `nil` once the account has been removed. A pass never acts on sync
    /// state its caller read before the turn: a pass ahead of it may have moved
    /// the delta cursor (`Account.lastHistoryId`) or run the full sync
    /// (`lastFullSyncAt`, `lastSyncedAt`) meanwhile, and a pass that waited and
    /// then used the caller's copy could clear a cursor that pass had just
    /// captured, or run a full sync again. Every write of the delta cursor runs
    /// inside a pass, so nothing moves it while the pass holds the turn.
    func accountAtTurnStart(_ accountId: String) async throws -> Account? {
        try await dbPool.read { db in try Account.fetchOne(db, key: accountId) }
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
