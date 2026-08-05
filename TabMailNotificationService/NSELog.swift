/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import os.log
import Synchronization

// Compiled into `TabMailTests` alongside `NSEStagingDB` (see that file's header
// and the `TabMailTests` sources list in `project.yml`). `NSELogStore` is
// internal to the main-app module, hence `@testable`; in the NSE it is compiled
// in directly and no import is wanted.
#if TABMAIL_TESTS
@testable import TabMail
#endif

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

    /// Per-run attribution tag for the file channel. iOS can run several
    /// `NotificationService` instances CONCURRENTLY in one reused NSE process
    /// (one per in-flight push), interleaving their step lines in nse.log with
    /// no way to attribute a non-STARTED line to its run. `didReceive` binds
    /// this (`NSELog.$runTag.withValue(...)`) around each run's logging task
    /// bodies — the `process(...)` Task, the watchdog Task, and
    /// `serviceExtensionTimeWillExpire` — so every line inside carries
    /// `[run:<tag>]` (first 8 chars of the request identifier).
    ///
    /// Untagged lines are pre-Task `didReceive` lines (the STARTED marker
    /// itself carries the full request id, so runs remain delimitable).
    /// NOTE: `Δ` stays PROCESS-global (one `lastStepAt` for all runs) — a
    /// cross-run delta is meaningless on its own, but the absolute wall-clock
    /// timestamp on every line rescues per-run delta math when needed.
    @TaskLocal static var runTag: String?

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

    /// Append a `[wall-clock] [+total Δdelta] [run:<tag>] message` line to
    /// `NSELogStore` (the `[run:]` segment only when a `runTag` is bound —
    /// see its doc for tagging/Δ semantics). No-op (skips the Mutex hop +
    /// ISO8601 formatting) when the store is disabled —
    /// `NSELogStore.isEnabled()` is checked first.
    private static func appendTimed(_ message: String) {
        guard NSELogStore.isEnabled() else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let last = lastStepAt.withLock { prev -> CFAbsoluteTime in
            let p = prev; prev = now; return p
        }
        let total = Int((now - processStart) * 1000)
        let delta = Int((now - last) * 1000)
        // Formatting lives in NSEProviderSupport.logLine (Shared/) so the
        // tagged/untagged line shapes are pinned by unit tests — this target
        // isn't reachable from TabMailTests. logLine also caps the message at
        // NSELogStore.lineMaxChars (single unbounded field must not blow the
        // file byte cap) — no truncation needed here.
        let line = NSEProviderSupport.logLine(
            timestamp: Date().iso8601StringWithMilliseconds(),
            totalMs: total, deltaMs: delta,
            runTag: runTag, message: message
        )
        NSELogStore.append(line)
    }
}
