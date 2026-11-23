/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// One pass waiting for an account's sync turn.
struct SyncTurnWaiter {
    let id: UInt64
    let continuation: CheckedContinuation<Void, Never>
}

extension SyncEngine {
    /// Runs `pass` as the account's only sync pass, so a delta and a full sync
    /// of one account never run at the same time. A pass that arrives while
    /// another runs waits its turn, in arrival order, and then runs; nothing is
    /// joined, and a caller's timeout includes the wait. The pass's first step
    /// inside its turn is `accountAtTurnStart`. The turn is released on every
    /// exit, a throw included, and handed straight to the oldest waiter.
    /// A waiter whose task was cancelled still takes its turn, and its pass
    /// stops at its first cancellation-aware step (the turn-start read, else its
    /// first work-queue call).
    ///
    /// The provider's `ProviderWorkQueue` does not do this: it has several
    /// slots, so without this two passes of one account ran side by side, each
    /// writing the account's delta cursor.
    ///
    /// Re-entrant for the task holding the turn (`heldSyncTurn`): a listing
    /// started inside a pass of the same account runs in that pass's turn.
    /// Only that task: a task spawned inside the turn inherits the task-local
    /// but is a different task, so it waits for the turn like any other.
    func oneSyncAtATime<T>(
        accountId: String, caller: String = #fileID, line: Int = #line, _ pass: () async throws -> T
    ) async rethrows -> T {
        let task = Self.currentTaskIdentity()
        if let task, Self.heldSyncTurn[accountId] == task { return try await pass() }
        if !syncPassRunning.insert(accountId).inserted {
            let ownsTurn = await waitForSyncTurn(accountId: accountId, caller: "\(caller):\(line)")
            // Only after a test-harness overrun: that test has already failed.
            if !ownsTurn { return try await pass() }
        }
        defer { handOverSyncPass(accountId: accountId) }
        var held = Self.heldSyncTurn
        held[accountId] = task
        return try await Self.$heldSyncTurn.withValue(held) { try await pass() }
    }

    /// Waits for the account's turn; false only when the test harness released
    /// a wait that overran `SyncConfig.syncTurnWaitTestBoundSeconds`.
    private func waitForSyncTurn(accountId: String, caller: String) async -> Bool {
        syncTurnWaiterSerial += 1
        let id = syncTurnWaiterSerial
        #if DEBUG
        let watcher: Task<Void, Never>? = Self.syncTurnWaitWatch.withLock { $0 }.map { report in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(SyncConfig.syncTurnWaitTestBoundSeconds))
                guard !Task.isCancelled, let self else { return }
                guard await self.releaseOverrunSyncTurnWaiter(accountId: accountId, id: id) else { return }
                report(accountId, caller)
            }
        }
        defer { watcher?.cancel() }
        #endif
        await withCheckedContinuation {
            syncPassWaiters[accountId, default: []].append(SyncTurnWaiter(id: id, continuation: $0))
        }
        return overrunSyncTurnWaiters.remove(id) == nil
    }

    #if DEBUG
    /// Test harness only: set by the test target, never by the app. Called with
    /// the account and the waiting caller when a turn wait overruns its bound.
    static let syncTurnWaitWatch = Mutex<(@Sendable (_ accountId: String, _ caller: String) -> Void)?>(nil)

    private func releaseOverrunSyncTurnWaiter(accountId: String, id: UInt64) -> Bool {
        guard let index = syncPassWaiters[accountId]?.firstIndex(where: { $0.id == id }) else { return false }
        let waiter = syncPassWaiters[accountId]!.remove(at: index)
        if syncPassWaiters[accountId]?.isEmpty == true { syncPassWaiters[accountId] = nil }
        overrunSyncTurnWaiters.insert(id)
        waiter.continuation.resume()
        return true
    }
    #endif

    /// The accounts whose sync turn is held, each with the task holding it.
    @TaskLocal static var heldSyncTurn: [String: Int] = [:]

    /// The running task's identity, nil outside a task.
    nonisolated static func currentTaskIdentity() -> Int? {
        withUnsafeCurrentTask { $0?.hashValue }
    }

    /// Runs `body` holding the sync turn (`oneSyncAtATime`) of every account in
    /// `accountIds`, taken one after another in sorted id order, so two callers
    /// that need overlapping accounts never wait on each other in a cycle. A
    /// Settings reset writes through this (#1062): no catch-up slice, change pass
    /// or full sync of those accounts runs between its read and its write, so
    /// nothing a pass read before the reset is written after it. Take the turns
    /// before opening the database writer, never while holding it. Every turn is
    /// released on every exit, a throw included.
    func withSyncTurns<T: Sendable>(
        accountIds: [String], _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await takeSyncTurns(Set(accountIds).sorted()[...], body)
    }

    private func takeSyncTurns<T: Sendable>(
        _ accountIds: ArraySlice<String>, _ body: @Sendable () async throws -> T
    ) async throws -> T {
        guard let first = accountIds.first else { return try await body() }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[SyncTurn] \(first): waiting for the turn")
        }
        return try await oneSyncAtATime(accountId: first) {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[SyncTurn] \(first): turn taken")
            }
            return try await takeSyncTurns(accountIds.dropFirst(), body)
        }
    }

    /// The account's row as it is now, read as a pass's first step inside its
    /// turn (and again before a pass retries its change read, which the failed
    /// attempt may have moved); `nil` once the account has been removed. A pass never acts on sync
    /// state its caller read before the turn: a pass ahead of it may have moved
    /// the delta cursor (`Account.lastHistoryId`) or run the full sync
    /// (`lastFullSyncAt`) meanwhile, and a pass that waited and
    /// then used the caller's copy could clear a cursor that pass had just
    /// captured, or run a full sync again. Every write of the delta cursor runs
    /// inside a pass, so nothing moves it while the pass holds the turn.
    func accountAtTurnStart(_ accountId: String) async throws -> Account? {
        try await dbPool.read { db in try Account.fetchOne(db, key: accountId) }
    }

    #if DEBUG
    /// Test-only seam: how many passes wait for the account's turn now, so a
    /// test knows a caller is queued before acting. Compiled out of Release.
    func syncPassWaiterCountForTesting(accountId: String) -> Int {
        syncPassWaiters[accountId]?.count ?? 0
    }
    #endif

    /// Ends a pass: the oldest waiter takes the turn, or the account is free.
    private func handOverSyncPass(accountId: String) {
        guard var waiting = syncPassWaiters[accountId], !waiting.isEmpty else {
            syncPassRunning.remove(accountId)
            return
        }
        let next = waiting.removeFirst()
        syncPassWaiters[accountId] = waiting.isEmpty ? nil : waiting
        next.continuation.resume()
    }
}
