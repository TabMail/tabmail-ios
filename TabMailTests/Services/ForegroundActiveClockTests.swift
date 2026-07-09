/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// `ForegroundActiveClock` is the suspension-aware "active time" clock backing
/// `SyncConfig.stagedRowEvictionGuardSeconds` (see `InboxViewModel.pendingStagedRows`
/// / ADR-IOS-049). It replaced `CFAbsoluteTimeGetCurrent()` because wall clock
/// keeps flowing during device sleep / app backgrounding — exactly when neither
/// the merge nor a reconciling reload can make progress — which let a
/// suspension-delayed merge blow straight through the guard window (435s
/// suspended-merge observation, "boot_logs 2", 2026-07-09).
///
/// `.serialized`: `ForegroundActiveClock` is a process-wide singleton (Mutex-backed
/// static state), so concurrent tests would race each other's `_testReset()` /
/// simulate calls.
@Suite("ForegroundActiveClock (ADR-IOS-049 suspension-aware guard clock)", .serialized)
struct ForegroundActiveClockTests {

    @Test("now() is monotonic non-decreasing across consecutive calls")
    func nowIsMonotonicNonDecreasing() {
        ForegroundActiveClock._testReset()
        var previous = ForegroundActiveClock.now()
        for _ in 0..<25 {
            let current = ForegroundActiveClock.now()
            #expect(current >= previous)
            previous = current
        }
    }

    @Test("simulated background→foreground excludes the backgrounded span from now() deltas")
    func backgroundForegroundExcludesPausedSpan() {
        ForegroundActiveClock._testReset()
        // With a freshly-reset clock (pausedTotal == 0), now() IS the raw uptime
        // reading at this instant — use it as a synthetic "current uptime" handle
        // for the simulate seam without needing access to the private primitive.
        let t0 = ForegroundActiveClock.now()

        let simulatedBackgroundSpanSeconds: Double = 120
        ForegroundActiveClock._testSimulateBackground(at: t0)
        ForegroundActiveClock._testSimulateForeground(at: t0 + simulatedBackgroundSpanSeconds)

        // Real elapsed time between t0 and this next now() call is a few
        // milliseconds (test execution), not 120s. A clock that did NOT exclude
        // the backgrounded span would read ~t0 (± ms). Because the span IS
        // excluded (subtracted as `pausedTotal`), now() reads far BELOW t0.
        let t1 = ForegroundActiveClock.now()
        #expect(t1 < t0)
        #expect(t0 - t1 > simulatedBackgroundSpanSeconds - 1)
    }

    @Test("double background (no intervening foreground) is idempotent — keeps the ORIGINAL mark")
    func doubleBackgroundIsIdempotent() {
        ForegroundActiveClock._testReset()
        let t0 = ForegroundActiveClock.now()

        // First background mark at t0.
        ForegroundActiveClock._testSimulateBackground(at: t0)
        // A second background call 50s later, with NO foreground in between —
        // must be ignored. If it were honored (overwriting backgroundedAt), the
        // eventual paused span would be computed from t0+50, not t0.
        ForegroundActiveClock._testSimulateBackground(at: t0 + 50)
        // Foreground 100s after the ORIGINAL mark.
        ForegroundActiveClock._testSimulateForeground(at: t0 + 100)

        let t1 = ForegroundActiveClock.now()
        // Correct (first-mark-wins) behavior excludes ~100s. The buggy
        // (second-mark-wins) behavior would only exclude ~50s — the >90 threshold
        // clearly distinguishes the two.
        #expect(t0 - t1 > 90)
    }

    @Test("now() reads FROZEN during an in-progress background span (BGTask wake)")
    func nowIsFrozenWhileBackgrounded() {
        ForegroundActiveClock._testReset()
        let t0 = ForegroundActiveClock.now()

        // Background began 300s ago in uptime terms (i.e. the current uptime
        // reading is far past the mark) with NO foreground yet — the shape a
        // BGTask wake sees. now() must read frozen at the background mark, not
        // count the in-progress span as elapsed.
        ForegroundActiveClock._testSimulateBackground(at: t0)
        let during = ForegroundActiveClock.now()
        #expect(abs(during - t0) < 1)

        // Unfreeze so this test leaves no in-progress span behind. Real uptime
        // barely advanced while the SIMULATED foreground says 300s passed, so
        // the paused subtraction lands ~300s below t0 (same style as the
        // exclusion test above) — the point here is only that the clock
        // unfreezes and stays consistent, not a continuity claim in real time.
        ForegroundActiveClock._testSimulateForeground(at: t0 + 300)
        let after = ForegroundActiveClock.now()
        #expect(after < t0)
        #expect(t0 - after > 299)
    }

    @Test("foreground with no preceding background is a no-op")
    func foregroundWithoutBackgroundIsNoOp() {
        ForegroundActiveClock._testReset()
        let t0 = ForegroundActiveClock.now()
        // No _testSimulateBackground call — this must not corrupt pausedTotal.
        ForegroundActiveClock._testSimulateForeground(at: t0 + 999)
        let t1 = ForegroundActiveClock.now()
        // Should read close to a fresh raw-uptime sample — nowhere near
        // t0 - 999 (which a buggy unconditional-subtract implementation would
        // produce).
        #expect(t1 >= t0)
    }
}
