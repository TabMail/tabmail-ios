/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Silent-push drain-mode decision (`SyncScheduler.drainModeForSilentPush`, ADR-IOS-056).
///
/// Background: the silent-push handlers used to pass `drain: .budget(PushConfig.
/// silentPushDeadlineSeconds)` UNCONDITIONALLY into `syncStartup`, even when the push
/// arrived while the app was foreground-active. That budget exists to poll-wait for the
/// active queues within the ~30s iOS gives a BACKGROUND wake before killing the process —
/// a foreground-active push has no such envelope (the active queues now self-drain at
/// `.normal`, ADR-IOS-056 part A), so it should behave like the foreground boot path
/// (`syncStartup(drain: .none)`) and return immediately instead of holding the handler
/// open for up to 25s.
@Suite("SyncScheduler.drainModeForSilentPush (ADR-IOS-056)")
struct SyncSchedulerDrainModeTests {

    @Test("Foreground-active → .none (mirrors the foreground boot path)")
    func foregroundActiveReturnsNone() {
        let mode = SyncScheduler.drainModeForSilentPush(isForegroundActive: true)
        guard case .none = mode else {
            Issue.record("Expected .none, got \(Self.describe(mode))")
            return
        }
    }

    @Test("Not foreground-active → .budget(PushConfig.silentPushDeadlineSeconds) (background-envelope watchdog, unchanged)")
    func backgroundReturnsBudget() {
        let mode = SyncScheduler.drainModeForSilentPush(isForegroundActive: false)
        guard case .budget(let seconds) = mode else {
            Issue.record("Expected .budget, got \(Self.describe(mode))")
            return
        }
        #expect(seconds == PushConfig.silentPushDeadlineSeconds)
    }

    @Test("Exhaustive: exactly the two legal outcomes, one per input")
    func exhaustiveTruthTable() {
        for isForegroundActive in [true, false] {
            let mode = SyncScheduler.drainModeForSilentPush(isForegroundActive: isForegroundActive)
            switch (isForegroundActive, mode) {
            case (true, .none):
                break // expected
            case (false, .budget(let seconds)):
                #expect(seconds == PushConfig.silentPushDeadlineSeconds)
            default:
                Issue.record("Unexpected pairing: isForegroundActive=\(isForegroundActive), mode=\(Self.describe(mode))")
            }
        }
    }

    @Test("Pure — repeated calls with the same input are stable (no hidden state)")
    func pureAndStable() {
        let a = SyncScheduler.drainModeForSilentPush(isForegroundActive: true)
        let b = SyncScheduler.drainModeForSilentPush(isForegroundActive: true)
        guard case .none = a, case .none = b else {
            Issue.record("Expected both calls to return .none")
            return
        }
    }

    /// `SyncScheduler.DrainMode` has no `CustomStringConvertible` conformance — a plain
    /// local helper (not a retroactive protocol conformance) for readable failure messages.
    private static func describe(_ mode: SyncScheduler.DrainMode) -> String {
        switch mode {
        case .none: return "none"
        case .budget(let seconds): return "budget(\(seconds))"
        case .full: return "full"
        }
    }
}
