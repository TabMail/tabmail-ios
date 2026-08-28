/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// Persistent NSE log file (`nse.log`) in the App Group container, alongside
/// `nse_staging.sqlite`. Written by the NSE (`NSELog.step` / `NSELog.error`),
/// read/cleared by the main app's Debug menu (`DebugLogView`).
///
/// Modeled on `BackgroundSyncLogger`'s file-log pattern (trim-tail, debug-
/// gated, main-app readable/clearable) but SYNCHRONOUS: unlike the main app,
/// the NSE process can be hard-killed at any instant (0xdead10cc suspension,
/// watchdog timeout, ~30s OS budget expiry). An async write queue (as
/// `BackgroundSyncLogger` uses) would lose exactly the tail line that would
/// explain why — so every `append` writes inline on the calling thread/task
/// via a cached `FileHandle`.
///
/// Lives in `Shared/` (compiled into BOTH targets) because the NSE writes and
/// the main app reads. `BodyAssetConfig.appGroup` (also `Shared/`) is reused
/// for the App Group identifier — `SharedNSEData` (the NSE's key-constant
/// registry) is NSE-target-only and can't be referenced from main-app-only
/// compiled code.
enum NSELogStore {
    /// Filename inside the App Group container, alongside `nse_staging.sqlite`.
    private static let fileName = "nse.log"

    /// Hard cap on file size, checked once per NSE process (first `append`).
    /// Internal (not private) so tests can reason about / override trim
    /// behavior without writing multi-megabyte payloads.
    static let maxBytes = 3 * 1024 * 1024
    /// Bytes retained after a trim, advanced past the first newline so no
    /// entry is ever split.
    static let keepBytes = 1536 * 1024 // 1.5 MB
    /// Hard per-line cap (characters) applied to the MESSAGE field by
    /// `NSEProviderSupport.logLine`. A single unbounded interpolated field
    /// (e.g. a crafted From display name echoed into a step line) must not
    /// blow the `maxBytes` file cap — `trimIfNeeded` runs once per NSE
    /// process BEFORE the first write and cannot bound the write itself;
    /// this cap does. Character-based (`prefix`), not byte-exact: fine for a
    /// debug channel, and matches the codebase's display-truncation
    /// convention (`String(x.prefix(n))`).
    static let lineMaxChars = 2000

    /// App Group suite key. Mirrored by `NSEDataBridge.mirrorDebugLogging()`
    /// and pushed immediately by `DebugModeManager` on unlock/lock. Also
    /// declared on `SharedNSEData.debugLoggingEnabledKey` (NSE target) for
    /// NSE-side call sites that prefer the named constant.
    static let debugLoggingEnabledKey = "nse.debugLoggingEnabled"

    // MARK: - Test seams
    //
    // The unit-test host has no App Group entitlement — `containerURL(for
    // SecurityApplicationGroupIdentifier:)` returns nil there, the same
    // problem `NSEStagingDB` / `NSEDataBridge` solve with a path-override
    // parameter. `nil` = use the real App Group container / real gate / real
    // byte caps.

    /// Test-only override for the log file location.
    static let fileURLOverride = Mutex<URL?>(nil)
    /// Test-only override for `isEnabled()`, bypassing the App Group suite read.
    static let enabledOverride = Mutex<Bool?>(nil)
    /// Test-only override for `maxBytes` — lets trim tests use small caps
    /// instead of writing multi-megabyte payloads.
    static let maxBytesOverride = Mutex<Int?>(nil)
    /// Test-only override for `keepBytes`.
    static let keepBytesOverride = Mutex<Int?>(nil)

    private static var effectiveMaxBytes: Int { maxBytesOverride.withLock { $0 } ?? maxBytes }
    private static var effectiveKeepBytes: Int { keepBytesOverride.withLock { $0 } ?? keepBytes }

    private static var fileURL: URL? {
        if let override = fileURLOverride.withLock({ $0 }) { return override }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BodyAssetConfig.appGroup
        )?.appendingPathComponent(fileName)
    }

    /// Cached result of the App Group suite gate read, for the process lifetime.
    private static let enabledCache = Mutex<Bool?>(nil)

    /// Whether the persistent NSE log is active. Cached for the process
    /// lifetime so the hot `append` path never re-reads UserDefaults. iOS may
    /// reuse an NSE process across pushes, so a debug-mode toggle takes effect
    /// on the NEXT NSE process launch — acceptable for a diagnostic gate.
    static func isEnabled() -> Bool {
        if let override = enabledOverride.withLock({ $0 }) { return override }
        return enabledCache.withLock { cache in
            if let cached = cache { return cached }
            let value = UserDefaults(suiteName: BodyAssetConfig.appGroup)?.bool(forKey: debugLoggingEnabledKey) ?? false
            cache = value
            return value
        }
    }

    /// Cached `FileHandle` (opened `forUpdating:` so the same handle can both
    /// read the tail for a trim and write new appends) plus the "have we
    /// checked for a trim yet this process" flag. Class wrapper because
    /// `Mutex` is noncopyable and this needs shared mutable identity across
    /// calls.
    private final class HandleState: @unchecked Sendable {
        var handle: FileHandle?
        var trimmedThisProcess = false
    }
    private static let state = Mutex<HandleState>(HandleState())

    /// Synchronously append one line. No-op when disabled — checked first so
    /// a locked/production process pays nothing beyond the cheap cached
    /// `isEnabled()` read (no file I/O, no timestamp formatting).
    static func append(_ line: String) {
        guard isEnabled(), let url = fileURL else { return }
        state.withLock { s in
            if s.handle == nil {
                let fm = FileManager.default
                if !fm.fileExists(atPath: url.path) {
                    fm.createFile(atPath: url.path, contents: nil)
                }
                s.handle = try? FileHandle(forUpdating: url)
            }
            guard let handle = s.handle else { return }
            if !s.trimmedThisProcess {
                s.trimmedThisProcess = true
                trimIfNeeded(handle: handle)
            }
            guard let data = (line + "\n").data(using: .utf8) else { return }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Drop on write error; matches `BackgroundSyncLogger`'s
                // best-effort behavior for this diagnostic-only channel.
            }
        }
    }

    /// Trim the file to its last `effectiveKeepBytes`, advanced past the
    /// first newline, if it has grown past `effectiveMaxBytes`. Runs at most
    /// once per NSE process (gated by `trimmedThisProcess`) on the SAME
    /// `FileHandle` used for subsequent appends — never an atomic external
    /// replace (`AppLogStore.trimTail`'s approach), which would
    /// orphan the cached handle onto a since-deleted inode. Caller must hold
    /// `state`'s lock.
    private static func trimIfNeeded(handle: FileHandle) {
        // `size > keepBytes` too: overridden caps can invert (keepBytes > size
        // while size > maxBytes), and the unsigned subtraction below would trap.
        guard let size = try? handle.seekToEnd(),
              size > UInt64(effectiveMaxBytes),
              size > UInt64(effectiveKeepBytes) else { return }
        let offset = size - UInt64(effectiveKeepBytes)
        do { try handle.seek(toOffset: offset) } catch { return }
        guard var data = try? handle.readToEnd() else { return }
        if let newline = data.firstIndex(of: 0x0A) {
            data = data.subdata(in: (newline + 1)..<data.count)
        }
        do {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
        } catch {
            // Best effort — leave the untrimmed file in place on failure.
        }
    }

    /// Read the full log for the Debug-menu share sheet. Returns a placeholder
    /// when missing/empty, matching `BackgroundSyncLogger`'s reader pattern.
    static func read() -> String {
        guard let url = fileURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else { return "(no NSE log)" }
        return text
    }

    /// Clear the log file. In production this is always called from the main
    /// app process (Debug menu), which never holds `state`'s cached handle —
    /// that's populated only by the NSE process's own `append` calls, in its
    /// own address space — so it takes the no-cached-handle branch below. A
    /// same-process caller that already has a cached handle (e.g. a test that
    /// appends then clears) truncates that handle in place instead.
    ///
    /// BOTH branches truncate IN PLACE — the inode is preserved. The
    /// no-cached-handle branch previously used `"".write(atomically: true)`,
    /// which is write-temp-then-RENAME: it swaps the inode, so a WARM NSE
    /// process's cached `FileHandle` (in its own address space, invisible from
    /// here) kept writing to the deleted-inode orphan — the very next push's
    /// log lines, the ones the developer cleared the file to capture,
    /// vanished until that NSE process died. That contradicted the trim
    /// path's own no-atomic-replace rule (see `trimIfNeeded`). With the
    /// in-place truncate, a warm NSE's cached handle keeps writing to the
    /// visible file after a Debug-menu clear — clear-then-capture works.
    /// A missing file needs no action (`append` creates it).
    static func clear() {
        guard let url = fileURL else { return }
        state.withLock { s in
            if let handle = s.handle {
                try? handle.truncate(atOffset: 0)
                try? handle.seek(toOffset: 0)
                s.trimmedThisProcess = false
            } else if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.truncate(atOffset: 0)
                    try? handle.close()
                }
            }
        }
    }

    /// Test-only: close any cached `FileHandle` and reset every cache/override
    /// to its default. The cached handle, `enabledCache`, and the override
    /// seams are all process-lifetime state (matching the real NSE, which is
    /// one process per push) — without this, tests sharing this test-host
    /// process would leak a stale handle pointing at a PRIOR test's temp file,
    /// or a stale `enabledCache`/override value, into the next test.
    static func _resetForTesting() {
        state.withLock { s in
            try? s.handle?.close()
            s.handle = nil
            s.trimmedThisProcess = false
        }
        enabledCache.withLock { $0 = nil }
        fileURLOverride.withLock { $0 = nil }
        enabledOverride.withLock { $0 = nil }
        maxBytesOverride.withLock { $0 = nil }
        keepBytesOverride.withLock { $0 = nil }
    }
}
