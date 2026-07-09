/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Darwin
import Synchronization

/// Boot / foreground / NSE-merge timeline profiler.
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
/// Gating: runtime — `guard DebugModeManager.isLoggingEnabled()`. When debug
/// logging is LOCKED (the default release state) every `mark(...)` is a single
/// guard-return: the `label` autoclosure is never evaluated and the lazy
/// `processStart` / `lastMark` statics are never initialized (no sysctl, no Mutex
/// alloc), so it's effectively free. When UNLOCKED (debug build, or
/// TestFlight/Release with debug mode unlocked in Settings) it prints to the
/// console AND appends to the downloadable **boot.log** (`BackgroundSyncLogger`),
/// so a cold-launch timeline can be captured on-device and shared from the debug
/// menu — not just read from the Xcode console. (Was `#if DEBUG`-only; switched to
/// the runtime gate 2026-06-29 to enable on-device/OOO boot capture, as the old
/// doc comment anticipated. Rule 12: a runtime debug gate is the sanctioned
/// alternative to `#if DEBUG`.)
///
/// To read a launch: filter on `BootProfile` (console) or download "Boot Profile
/// Logs" from Settings → Debug. The biggest `Δ` between consecutive marks is the
/// next thing to make instant; compare the first mark's `+total` (pre-main)
/// against the `first paint` mark to see how much is framework load vs. our work.
enum BootProfiler {

    /// Kernel process-start as a `CFAbsoluteTime`, so `+total` includes pre-main.
    /// Lazy — only initialized once `mark` first runs with logging unlocked, so a
    /// locked release build pays nothing. Falls back to "first touch" if the
    /// sysctl is unavailable.
    private static let processStart: CFAbsoluteTime = kernelProcessStart() ?? CFAbsoluteTimeGetCurrent()

    /// Timestamp of the previous mark, for the inter-mark `Δ`. Marks fire from
    /// many isolation domains (main actor, detached tasks, GRDB queues), so it's
    /// guarded by a `Mutex` (SE-0433) rather than `nonisolated(unsafe)`.
    private static let lastMark = Mutex<CFAbsoluteTime>(processStart)

    /// Record a boot-timeline mark. No-op (and `label` not built) unless debug
    /// logging is unlocked. `label` is an `@autoclosure` so any interpolation it
    /// does is skipped entirely when gated out.
    static func mark(_ label: @autoclosure () -> String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let last = lastMark.withLock { prev -> CFAbsoluteTime in
            let p = prev; prev = now; return p
        }
        let total = Int((now - processStart) * 1000)
        let delta = Int((now - last) * 1000)
        let line = "[BootProfile +\(total)ms (Δ\(delta)ms)] \(label())"
        print(line)
        BackgroundSyncLogger.logBoot(line)
    }

    // MARK: - Main-thread stall watchdog

    /// One watchdog thread for the process (armed once from `startStallWatchdog`).
    private static let watchdogArmed = Mutex<Bool>(false)

    /// Debug-gated main-thread stall watchdog: pings the main queue every
    /// `pingInterval`; when a ping's turnaround exceeds `stallThreshold` the
    /// stall lands in the BootProfile timeline as `⚠ MAIN THREAD STALL ~Xms`,
    /// timestamped at RECOVERY (the ping runs when the main thread frees up, so
    /// the stall WINDOW is [mark − Xms, mark]). This is the attribution tool for
    /// user-reported "main actor stall" — correlate the window against the
    /// surrounding EXEC/merge/sync marks instead of guessing. Costs one ping
    /// block per 250ms while debug logging is unlocked; never armed otherwise.
    static func startStallWatchdog(
        pingInterval: TimeInterval = 0.25,
        stallThreshold: TimeInterval = 0.5,
        ongoingStallInterval: TimeInterval = 2.0
    ) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        let shouldArm = watchdogArmed.withLock { armed -> Bool in
            if armed { return false }
            armed = true
            return true
        }
        guard shouldArm else { return }
        let thread = Thread {
            while true {
                let sent = CFAbsoluteTimeGetCurrent()
                let done = Mutex<Bool>(false)
                DispatchQueue.main.async {
                    let latency = CFAbsoluteTimeGetCurrent() - sent
                    done.withLock { $0 = true }
                    if latency > stallThreshold {
                        mark("⚠ MAIN THREAD STALL ~\(Int(latency * 1000))ms (recovered now; window = the preceding \(Int(latency * 1000))ms)")
                    }
                }
                Thread.sleep(forTimeInterval: pingInterval)
                // If the ping is still pending after the sleep, the main thread is
                // CURRENTLY stalled — wait for it rather than piling up pings. While
                // waiting, emit periodic "still stalled" marks from THIS (watchdog)
                // thread so an ongoing hang is visible in the timeline before it ever
                // recovers — this is what lets a real log-then-black-screen report be
                // read as "still alive, just slow" vs. "actually hung". `mark()` writes
                // directly (print + BackgroundSyncLogger.logBoot → a background
                // ioQueue.async) with no main-queue hop, so it's safe to call from here
                // even while the main thread is stalled.
                var lastOngoingMark = sent
                while !done.withLock({ $0 }) {
                    Thread.sleep(forTimeInterval: 0.05)
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastOngoingMark >= ongoingStallInterval {
                        let elapsedMs = Int((now - sent) * 1000)
                        mark("⚠ MAIN THREAD STALL ONGOING ~\(elapsedMs)ms (unrecovered yet)")
                        lastOngoingMark = now
                    }
                }
            }
        }
        thread.name = "tabmail.mainThreadStallWatchdog"
        thread.qualityOfService = .utility
        thread.start()
        mark("main-thread stall watchdog armed (ping=\(Int(pingInterval * 1000))ms threshold=\(Int(stallThreshold * 1000))ms)")
    }

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
}
