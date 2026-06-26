/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Darwin
#if DEBUG
import Synchronization
#endif

/// Boot / foreground / NSE-merge timeline profiler (DEBUG builds only).
///
/// Emits ONE greppable channel so a launch reads as a single ordered timeline:
///
///     [BootProfile +<total>ms (Δ<delta>ms)] <label>
///
/// `<total>` is measured from the **kernel process-start time** (not first app
/// code), so the pre-main cost (dyld, Swift runtime, static init — usually the
/// single biggest chunk of a cold launch) is visible as the first mark's `+Nms`.
/// `<delta>` is the gap since the previous mark, so the slow STEP jumps out.
///
/// Gating: `#if DEBUG`. In any debug build every `mark(...)` prints — no runtime
/// toggle to unlock first — which is exactly how we analyze it (run the Xcode
/// debug build; it shows everything regardless, slower but easier to read). In a
/// Release/TestFlight build the whole type is compiled out: each `mark(...)` is
/// an empty call (the label autoclosure is never evaluated, so no string cost)
/// and none of the sysctl / Mutex / print machinery ships. Rule 12 ("`#if DEBUG`
/// is acceptable for code that should be fully stripped from release binaries").
///
/// (If you ever want on-device / TestFlight boot capture, swap the `#if DEBUG`
/// in `mark` for `guard DebugModeManager.isLoggingEnabled() else { return }` —
/// the same runtime gate `BackgroundSyncLogger` uses for its on-device log file.)
///
/// To read a launch: filter the Xcode console on `BootProfile`. The biggest `Δ`
/// between consecutive marks is the next thing to make instant; compare the
/// first mark's `+total` (pre-main) against the `first paint` mark to see how
/// much is framework load vs. our own work.
enum BootProfiler {

    #if DEBUG
    /// Kernel process-start as a `CFAbsoluteTime`, so `+total` includes pre-main.
    /// Falls back to "first touch" if the sysctl is unavailable.
    private static let processStart: CFAbsoluteTime = kernelProcessStart() ?? CFAbsoluteTimeGetCurrent()

    /// Timestamp of the previous mark, for the inter-mark `Δ`. Marks fire from
    /// many isolation domains (main actor, detached tasks, GRDB queues), so it's
    /// guarded by a `Mutex` (SE-0433) rather than `nonisolated(unsafe)`.
    private static let lastMark = Mutex<CFAbsoluteTime>(processStart)
    #endif

    /// Record a boot-timeline mark. No-op (and label not built) in release.
    /// `label` is an `@autoclosure` so any interpolation it does is skipped
    /// entirely when the body is compiled out.
    static func mark(_ label: @autoclosure () -> String) {
        #if DEBUG
        let now = CFAbsoluteTimeGetCurrent()
        let last = lastMark.withLock { prev -> CFAbsoluteTime in
            let p = prev; prev = now; return p
        }
        let total = Int((now - processStart) * 1000)
        let delta = Int((now - last) * 1000)
        print("[BootProfile +\(total)ms (Δ\(delta)ms)] \(label())")
        #endif
    }

    #if DEBUG
    /// Read this process's start time from the kernel (`KERN_PROC_PID`) and
    /// convert the `p_starttime` timeval (unix epoch) to `CFAbsoluteTime`.
    private static func kernelProcessStart() -> CFAbsoluteTime? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = mib.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, UInt32(buf.count), &info, &size, nil, 0)
        }
        guard rc == 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        let unixSeconds = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000.0
        return unixSeconds - kCFAbsoluteTimeIntervalSince1970
    }
    #endif
}
