/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit
import Synchronization
import Darwin

/// Process-wide "active time" clock: seconds of device-awake, app-not-backgrounded
/// time since process start. Use this for GUARDS whose window means "running time
/// to make progress" (e.g. ADR-IOS-049's staged-row eviction guard,
/// `SyncConfig.stagedRowEvictionGuardSeconds`). NEVER use it for timestamps shown
/// to users or persisted to disk — it has no relationship to wall-clock time and
/// resets on every process launch.
///
/// Two layers:
/// 1. **Base: `CLOCK_UPTIME_RAW`** — monotonic uptime EXCLUDING device sleep. Same
///    primitive as the private `DatabaseWriteQueue.uptimeSeconds()` helper (mirror,
///    not shared — that one is a private diagnostic helper scoped to an actor;
///    cross-reference if either drifts). This alone fixes the device-sleep case
///    with zero lifecycle dependency: a merge suspended for minutes while the
///    device sleeps doesn't erode a guard window measured here, unlike
///    `CFAbsoluteTimeGetCurrent()` (wall clock — keeps flowing during sleep, and
///    is also NTP-jump-prone).
/// 2. **Pause across app backgrounding** — the device can stay AWAKE while the
///    app itself is suspended in the background; `CLOCK_UPTIME_RAW` keeps
///    advancing through that too, but neither a merge write nor a reconciling
///    reload can make progress while backgrounded. `now()` additionally subtracts
///    accumulated backgrounded time, observed via
///    `UIApplication.didEnterBackgroundNotification` /
///    `willEnterForegroundNotification`.
///
/// Main-app-target only: `UIApplication` is unavailable in the Notification
/// Service Extension. `TabMail/Services/` is not part of the NSE target's source
/// list (see `project.yml` — the `TabMailNotificationService` target's sources
/// are `TabMailNotificationService/` + `Shared/`, not `TabMail/`), so this is
/// enforced by target membership, not a runtime guard.
enum ForegroundActiveClock {
    private struct State {
        /// Total backgrounded seconds accumulated so far, in uptime units.
        var pausedTotal: Double = 0
        /// Uptime at which the current backgrounded span began. `nil` means the
        /// app is not currently backgrounded (or the process hasn't backgrounded
        /// yet).
        var backgroundedAt: Double?
        /// Guards one-time (idempotent) observer installation.
        var observersInstalled = false
    }

    private static let state = Mutex(State())

    /// Seconds of device-awake, app-not-backgrounded time since process start.
    /// While a background span is IN PROGRESS (`backgroundedAt != nil` — e.g. a
    /// BGTask wake calls this before `willEnterForeground` ever fires), the
    /// clock reads FROZEN at the value it had when backgrounding began:
    /// otherwise the whole suspended span so far would count as elapsed and a
    /// background-wake reload could expire a guard the foreground never had a
    /// chance to reconcile. Conservative direction — guards survive longer.
    static func now() -> Double {
        installObserversIfNeeded()
        return state.withLock { s in
            let base = s.backgroundedAt ?? uptimeRawSeconds()
            return base - s.pausedTotal
        }
    }

    // MARK: - Lifecycle observation (lazy on first `now()` call)

    /// Installs the background/foreground observers exactly once, on the first
    /// call to `now()`. Before the first background event the clock is pure
    /// `CLOCK_UPTIME_RAW` — already correct for the device-sleep case that
    /// motivated this type — so there is no correctness gap in the window before
    /// installation, only before the app's first background transition.
    private static func installObserversIfNeeded() {
        let alreadyInstalled = state.withLock { s -> Bool in
            if s.observersInstalled { return true }
            s.observersInstalled = true
            return false
        }
        guard !alreadyInstalled else { return }
        let nc = NotificationCenter.default
        nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in
            handleDidEnterBackground(at: uptimeRawSeconds())
        }
        nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { _ in
            handleWillEnterForeground(at: uptimeRawSeconds())
        }
    }

    private static func handleDidEnterBackground(at uptime: Double) {
        state.withLock { s in
            // Idempotent: a second didEnterBackground without an intervening
            // foreground must not overwrite the original mark — doing so would
            // shrink the eventually-computed paused span (or, if the fake mark is
            // later than the real one, produce a negative delta at foreground).
            guard s.backgroundedAt == nil else { return }
            s.backgroundedAt = uptime
        }
    }

    private static func handleWillEnterForeground(at uptime: Double) {
        state.withLock { s in
            guard let backgroundedAt = s.backgroundedAt else { return }
            s.pausedTotal += max(0, uptime - backgroundedAt)
            s.backgroundedAt = nil
        }
    }

    /// Monotonic uptime EXCLUDING device sleep (`CLOCK_UPTIME_RAW`), in seconds.
    private static func uptimeRawSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    #if DEBUG
    /// Test seam: drive the same background transition the real
    /// `didEnterBackgroundNotification` observer would, with an injected uptime
    /// instead of a real notification / real elapsed time.
    static func _testSimulateBackground(at uptime: Double) {
        handleDidEnterBackground(at: uptime)
    }

    /// Test seam: drive the same foreground transition the real
    /// `willEnterForegroundNotification` observer would. See
    /// `_testSimulateBackground`.
    static func _testSimulateForeground(at uptime: Double) {
        handleWillEnterForeground(at: uptime)
    }

    /// Test seam: reset accumulated pause state so tests don't leak into each
    /// other via this process-wide singleton. Does NOT uninstall the
    /// NotificationCenter observers — harmless, since their handlers are
    /// idempotent and re-observe real transitions correctly afterward.
    static func _testReset() {
        state.withLock { $0 = State() }
    }
    #endif
}
