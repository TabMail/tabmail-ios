/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

// MARK: - How an account's syncs start and take turns (design settled 2026-11-23)
//
// Read this before you change a sync trigger, the account turn, a sync time limit
// or the return-to-app path. v1.11.4 changed these together and regressed: due
// full syncs were swallowed (#1275) and a pass that waited for its turn read
// nothing (#1289). Keep this design simple. Add no timer, skip, guard, queue or
// second path. Before v1.11.3 the flow was mostly fine; prefer it to anything new.
//
// Two stages:
// - Stage 1 is the quick sync (`SyncEngine.backgroundDeltaSync`, reached through
//   `SyncScheduler.syncStartup` / `backgroundPoll`). It reads changes only and
//   never runs a full sync (10 s limit from `syncStartup`; pull to refresh gives
//   it stage 2's limit). Push and background refresh read the
//   inbox only (on IMAP); a return to the app, IMAP IDLE, pull to refresh and
//   background processing read every folder. It is the lean path the startup,
//   push and background budgets depend on (iOS memory 042).
// - Stage 2 is `SyncEngine.sync(account:)`, run for each account by
//   `SyncScheduler.poll()`: a quick sync, then the full sync when `lastFullSyncAt`
//   says it is due or the read needs a listing. Only the foreground starts it:
//   opening the app, the 5-minute poll timer (stopped when the app leaves the
//   foreground), adding an account and the account screen in Settings. The one
//   exception is the one-time v1.7.1 epoch rebuild, which runs once per install
//   on whatever launch comes first. A stage 2 already running when the app leaves
//   the foreground may finish in the short background grace period.
//
// One sync at a time per account (`oneSyncAtATime`, ADR-IOS-104): two passes of
// one account wrote its sync state, such as the delta cursor, at the same time.
//
// The per-account follow-up flag (#1289, #1313, #1314):
// - A trigger (push, IDLE, pull to refresh, the poll, a return to the app) that
//   finds the account busy sets the account's flag and returns. It never waits
//   in line and is never dropped. However many arrive, the account runs ONE
//   stage 2 when the running work ends, which runs the full sync if it is due.
//   The flag is cleared when that sync starts.
// - Only an account that is free takes the quick-sync-only route.
// - In the background a set flag waits for the next opening of the app: stage 2
//   never starts in the background. A silent push already schedules background
//   work, and the next push, poll or opening covers anything else.
// - The poll does not wait for a busy account either. It sets the flag and goes
//   straight on to the queued work (actions, outbox, calendar), which never
//   depended on stage 2: each gesture and a network restore already start that
//   work on their own, while syncs run.
//
// Every time limit counts from when the sync starts running, never from when it
// was asked for. Stage 2's limit (`SyncConfig.perAccountSyncTimeoutSeconds`)
// starts when stage 2 takes the account's turn. In v1.11.4 it counted the wait
// for the turn, so a stage 2 queued behind stage 1 had no time left (#1289).
//
// No recent-sync guard, of any length. A return to the app runs stage 1's quick
// sync and then stage 2's own quick sync. They take turns, so they never collide,
// and the second usually finds nothing: one cheap request per account. That cost
// is accepted. The 15-second skip that saved it (added 2026-02) swallowed due
// full syncs (#1275, deleted in #1308). A guard optimizes a tiny cost at the risk
// of that failure again (#1278).
//
// History (pre-public archive and this repository):
// - 2026-02-27: the 60 s limit was added while the poll still synced the accounts
//   one after another; since 2026-03-12 they sync in parallel.
// - 2026-04-08: one shared stage 1 for a return, push and background work, run
//   alongside the poll on purpose ("sync never blocks queues"). The return has
//   read twice since then.
// - 2026-06-26: on a cold launch, stage 1, the push resubscribe and the poll wait
//   for the first paint; the staged notification-extension mail merges first. The
//   cause was measured: the on-device embedding model load starved the merge.
// - 2026-11-10 (v1.11.4): one sync at a time per account (#575), which made the
//   wait for a turn count against the caller's limit (#1289).

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
