/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// `SyncEngine.withSyncTurns` (#1062, ADR-IOS-104): a Settings reset takes the
/// sync turn of every account it writes, in sorted id order, and releases each
/// on every exit.
@Suite("Settings reset sync turns")
struct SyncTurnsForResetTests {

    /// Polls before a waiting step counts as blocked.
    static let polls = 50

    /// Gate a test opens to end a pass it holds.
    actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    actor Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    static func waitFor(_ flag: Flag) async throws -> Bool {
        for _ in 0..<polls {
            if await flag.isSet { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await flag.isSet
    }

    /// Polls until `account` has `count` waiters; false at the bound.
    static func waitForWaiters(_ engine: SyncEngine, _ account: String, count: Int) async throws -> Bool {
        for _ in 0..<polls {
            if await engine.syncPassWaiterCount(accountId: account) == count { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("Turns are taken in sorted account-id order: while the lower id is busy, a reset of both holds no turn of the higher id")
    func turnsAreTakenInSortedOrder() async throws {
        let engine = SyncEngine()
        let low = "account-a", high = "account-b"
        let gate = Gate()
        let lowHeld = Flag()
        let busy = Task { await engine.oneSyncAtATime(accountId: low) { await lowHeld.set(); await gate.wait() } }
        #expect(try await Self.waitFor(lowHeld), "setup: the lower id's turn is held")
        let resetRan = Flag()
        let reset = Task { try await engine.withSyncTurns(accountIds: [high, low]) { await resetRan.set() } }
        // Sorted, the reset waits on the lower id first; caller order would hold
        // the higher id and then wait on the lower. Either way it queues on low.
        #expect(try await Self.waitForWaiters(engine, low, count: 1), "setup: the reset waits for the lower id")
        let highRan = Flag()
        let highPass = Task { await engine.oneSyncAtATime(accountId: high) { await highRan.set() } }
        let highFree = try await Self.waitFor(highRan)
        let resetWaited = await !resetRan.isSet
        await gate.release()
        await busy.value
        await highPass.value
        try await reset.value
        #expect(highFree, "#1062: the reset holds no turn of the higher id while it waits for the lower")
        #expect(resetWaited, "#1062: the reset waits for the busy account's turn")
        #expect(await resetRan.isSet)
    }

    struct ResetFailed: Error {}

    @Test("Every turn is released when the reset throws")
    func turnsAreReleasedOnThrow() async throws {
        let engine = SyncEngine()
        let ids = ["account-a", "account-b"]
        await #expect(throws: ResetFailed.self) {
            try await engine.withSyncTurns(accountIds: ids) { throw ResetFailed() }
        }
        for id in ids {
            let ran = Flag()
            let pass = Task { await engine.oneSyncAtATime(accountId: id) { await ran.set() } }
            #expect(try await Self.waitFor(ran), "#1062: \(id)'s turn is free after the failed reset")
            await pass.value
        }
    }
}
