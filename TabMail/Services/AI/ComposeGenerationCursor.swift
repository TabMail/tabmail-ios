/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// PORT — exact non-reentrant admission shape from v2final commit 3f2cc4c34.
final class ComposeAdmissionGate: @unchecked Sendable {
    private struct State {
        var isLocked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state in
                if state.isLocked {
                    state.waiters.append(continuation)
                    return false
                }
                state.isLocked = true
                return true
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = state.withLock { state in
            if !state.waiters.isEmpty { return state.waiters.removeFirst() }
            state.isLocked = false
            return nil
        }
        next?.resume()
    }
}

/// One shared cursor for every save entry point in one compose generation.
final class ComposeGenerationCursor: @unchecked Sendable {
    let newEpoch: String
    private let expectedPredecessorBox: Mutex<String?>
    private let gate = ComposeAdmissionGate()

    init(newEpoch: String, initialExpectedPredecessor: String?) {
        self.newEpoch = newEpoch
        self.expectedPredecessorBox = Mutex(initialExpectedPredecessor)
    }

    var currentExpectedPredecessorForTesting: String? {
        expectedPredecessorBox.withLock { $0 }
    }

    @discardableResult
    func admit(
        _ body: @Sendable (_ newEpoch: String, _ expectedPredecessor: String?) async throws -> DraftStore.SaveResult
    ) async throws -> DraftStore.SaveResult {
        await gate.acquire()
        defer { gate.release() }
        let predecessor = expectedPredecessorBox.withLock { $0 }
        let result = try await body(newEpoch, predecessor)
        if case .applied = result {
            expectedPredecessorBox.withLock { $0 = newEpoch }
        }
        return result
    }
}

/// ⚑ NO REFERENCE — INVENTED minimum arbitration between the only two
/// asynchronous compose owners that may race: an inline-agent edit and Send.
/// Ordinary user edits remain unrestricted; this fence owns no lifecycle state.
final class ComposeAgentSendFence: @unchecked Sendable {
    private struct State {
        var agentInFlight = false
        var sendClaimed = false
    }
    private let state = Mutex(State())

    func beginAgent() -> Bool {
        state.withLock { value in
            guard !value.agentInFlight, !value.sendClaimed else { return false }
            value.agentInFlight = true
            return true
        }
    }

    func finishAgent() {
        state.withLock { $0.agentInFlight = false }
    }

    func claimSend() -> Bool {
        state.withLock { value in
            guard !value.agentInFlight, !value.sendClaimed else { return false }
            value.sendClaimed = true
            return true
        }
    }

    func releaseFailedSend() {
        state.withLock { $0.sendClaimed = false }
    }
}
