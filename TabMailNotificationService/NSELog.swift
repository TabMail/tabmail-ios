/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import os.log
import Synchronization

/// Centralized NSE logging — dual-channel: `os_log` (Console.app / Xcode) AND
/// the persistent `NSELogStore` file (App Group container, readable from the
/// main app's Debug menu — `os_log` alone is invisible in the field).
enum NSELog {
    private static let logger = Logger(subsystem: "ai.tabmail.ios.NotificationService", category: "NSE")

    /// Process start, captured once per NSE process launch — anchors the
    /// file-channel `+total` timing (mirrors `BootProfiler.processStart`).
    private static let processStart = CFAbsoluteTimeGetCurrent()

    /// Wall-clock of the previous file-channel write, for the inter-call `Δ`.
    /// One NSE process handles pushes sequentially, so a single Mutex for the
    /// process lifetime is safe (mirrors `BootProfiler.lastMark`).
    private static let lastStepAt = Mutex<CFAbsoluteTime>(processStart)

    static func info(_ message: String) {
        #if DEBUG
        logger.info("🔔 \(message, privacy: .public)")
        #endif
    }

    /// Field-visible, always-on step log. Fires at `.error` os_log level —
    /// today's established field-visibility trick, preserved as-is — AND
    /// appends to `NSELogStore` when debug logging is enabled. Message text
    /// is greppable: the `NSE stepN` / `NSE ━━━` prefixes are a stable
    /// contract across call sites — preserve them.
    static func step(_ message: String) {
        logger.error("🔔 \(message, privacy: .public)")
        appendTimed(message)
    }

    static func error(_ message: String) {
        logger.error("🔔❌ \(message, privacy: .public)")
        appendTimed("❌ \(message)")
    }

    static func timing(_ label: String, _ block: () async -> Void) async {
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        await block()
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        logger.info("🔔⏱ \(label, privacy: .public): \(ms)ms")
        #else
        await block()
        #endif
    }

    /// Append a `[wall-clock] [+total Δdelta] message` line to `NSELogStore`.
    /// No-op (skips the Mutex hop + ISO8601 formatting) when the store is
    /// disabled — `NSELogStore.isEnabled()` is checked first.
    private static func appendTimed(_ message: String) {
        guard NSELogStore.isEnabled() else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let last = lastStepAt.withLock { prev -> CFAbsoluteTime in
            let p = prev; prev = now; return p
        }
        let total = Int((now - processStart) * 1000)
        let delta = Int((now - last) * 1000)
        let line = "[\(Date().iso8601StringWithMilliseconds())] [+\(total)ms Δ\(delta)ms] \(message)"
        NSELogStore.append(line)
    }
}
