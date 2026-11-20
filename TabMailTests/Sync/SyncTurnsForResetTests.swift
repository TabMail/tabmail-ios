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

    @Test("Turns are taken in sorted account-id order: while the lower id is busy, a reset of both holds no turn of the higher id")
    func turnsAreTakenInSortedOrder() async throws {
        let engine = SyncEngine()
        let low = "account-a", high = "account-b"
        let gate = Gate()
        let busy = Task { await engine.oneSyncAtATime(accountId: low) { await gate.wait() } }
        try await Task.sleep(for: .milliseconds(20))
        let resetRan = Flag()
        let reset = Task { try await engine.withSyncTurns(accountIds: [high, low]) { await resetRan.set() } }
        try await Task.sleep(for: .milliseconds(20))
        let highRan = Flag()
        let highPass = Task { await engine.oneSyncAtATime(accountId: high) { await highRan.set() } }
        #expect(try await Self.waitFor(highRan), "#1062: the reset waits for the lower id first and holds no other turn meanwhile")
        #expect(await !resetRan.isSet, "#1062: the reset waits for the busy account's turn")
        await gate.release()
        await busy.value
        await highPass.value
        try await reset.value
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
