/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// Semaphore limiting concurrent LLM API calls, owned by BackendClient.
/// Matches TB's `_llmSemaphore` in llm.js — counter + FIFO waiter queue.
///
/// Architecture: `sendCompletions` / `sendCompletionsWithTools` acquire a slot
/// before making the HTTP request. "Direct" variants bypass the semaphore for
/// user-initiated calls (agent chat, inline edit) that should not wait behind
/// background AI processing.
///
/// Thread safety: `Mutex<State>` provides synchronization. `@unchecked Sendable`
/// is safe because Mutex protects all mutable state.
final class LLMSemaphore: @unchecked Sendable {
    private let maxConcurrent: Int

    private struct State {
        var current: Int = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(maxConcurrent: Int = SyncConfig.maxConcurrentLLMCalls) {
        self.maxConcurrent = maxConcurrent
        self.state = Mutex(State())
    }

    /// Acquire a slot. If all slots are taken, suspends until one is released.
    /// Matches TB's `_acquire()` — FIFO waiter queue ensures fairness.
    func acquire() async {
        let shouldWait = state.withLock { state -> Bool in
            if state.current < maxConcurrent {
                state.current += 1
                return false
            }
            return true
        }

        guard shouldWait else { return }

        let waitStart = CFAbsoluteTimeGetCurrent()
        let (slots, waiters) = state.withLock { (s: inout State) -> (Int, Int) in
            (s.current, s.waiters.count)
        }
        BackgroundSyncLogger.logAIProcessing("[SEMAPHORE] acquire WAIT (slots=\(slots)/\(maxConcurrent), waiters=\(waiters))")

        await withCheckedContinuation { continuation in
            state.withLock { state in
                // Double-check: a slot may have opened between the check above and here
                if state.current < maxConcurrent {
                    state.current += 1
                    continuation.resume()
                } else {
                    state.waiters.append(continuation)
                }
            }
        }

        let waitMs = Int((CFAbsoluteTimeGetCurrent() - waitStart) * 1000)
        if waitMs > 100 {
            BackgroundSyncLogger.logAIProcessing("[SEMAPHORE] acquire END after \(waitMs)ms (slots=\(activeCount)/\(maxConcurrent))")
        }
    }

    /// Release a slot. If waiters exist, the first one is immediately resumed.
    /// Matches TB's `_release()` — synchronous, safe to call from `defer`.
    func release() {
        let (slots, waiters) = state.withLock { state -> (Int, Int) in
            state.current = max(0, state.current - 1)
            if !state.waiters.isEmpty {
                let next = state.waiters.removeFirst()
                state.current += 1
                next.resume()
            }
            return (state.current, state.waiters.count)
        }
        if waiters > 0 {
            BackgroundSyncLogger.logAIProcessing("[SEMAPHORE] release (slots=\(slots)/\(maxConcurrent), waiters=\(waiters))")
        }
    }

    /// Current number of active slots (for diagnostics).
    var activeCount: Int {
        state.withLock { $0.current }
    }

    /// Current number of waiters (for diagnostics).
    var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }
}
