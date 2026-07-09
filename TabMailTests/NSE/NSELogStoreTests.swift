/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// `NSELogStore` — the persistent NSE log file in the App Group container.
///
/// The unit-test host has no App Group entitlement, so every test drives the
/// REAL store through its test seams (`fileURLOverride`, `enabledOverride`,
/// `maxBytesOverride`, `keepBytesOverride`) rather than a mock. `.serialized`
/// because the store's caches (`state`, `enabledCache`) are process-lifetime
/// statics — `_resetForTesting()` runs before/after every test so no test
/// leaks a stale cached `FileHandle` or gate value into the next one.
@Suite("NSELogStore", .serialized)
struct NSELogStoreTests {

    private func setUp() -> URL {
        NSELogStore._resetForTesting()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nse-log-test-\(UUID().uuidString).log")
        NSELogStore.fileURLOverride.withLock { $0 = url }
        return url
    }

    private func tearDown(_ url: URL) {
        NSELogStore._resetForTesting()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Append / read round-trip

    @Test("append then read round-trips via the path override")
    func appendReadRoundTrip() {
        let url = setUp()
        defer { tearDown(url) }
        NSELogStore.enabledOverride.withLock { $0 = true }

        NSELogStore.append("first line")
        NSELogStore.append("second line")

        let text = NSELogStore.read()
        #expect(text.contains("first line"))
        #expect(text.contains("second line"))
        // Order preserved — append is a tail write, not a prepend.
        let firstRange = text.range(of: "first line")
        let secondRange = text.range(of: "second line")
        guard let firstRange, let secondRange else {
            Issue.record("expected both lines present")
            return
        }
        #expect(firstRange.lowerBound < secondRange.lowerBound)
    }

    @Test("read() on a missing file returns the placeholder")
    func readMissingFileReturnsPlaceholder() {
        let url = setUp()
        defer { tearDown(url) }
        // Never appended — file was never created.
        #expect(NSELogStore.read() == "(no NSE log)")
    }

    // MARK: - Clear

    @Test("clear empties the log")
    func clearEmptiesLog() {
        let url = setUp()
        defer { tearDown(url) }
        NSELogStore.enabledOverride.withLock { $0 = true }

        NSELogStore.append("will be cleared")
        #expect(NSELogStore.read().contains("will be cleared"))

        NSELogStore.clear()
        #expect(NSELogStore.read() == "(no NSE log)")
    }

    // MARK: - Gate

    @Test("append is a no-op when the gate is disabled")
    func appendNoOpWhenDisabled() {
        let url = setUp()
        defer { tearDown(url) }
        NSELogStore.enabledOverride.withLock { $0 = false }

        NSELogStore.append("should never be written")

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(NSELogStore.read() == "(no NSE log)")
    }

    @Test("isEnabled() reflects the override")
    func isEnabledReflectsOverride() {
        let url = setUp()
        defer { tearDown(url) }

        NSELogStore.enabledOverride.withLock { $0 = true }
        #expect(NSELogStore.isEnabled())

        NSELogStore.enabledOverride.withLock { $0 = false }
        #expect(!NSELogStore.isEnabled())
    }

    // MARK: - Trim at open

    @Test("first append of the process trims a file over the byte cap")
    func trimsOversizedFileOnFirstAppend() throws {
        let url = setUp()
        defer { tearDown(url) }
        NSELogStore.enabledOverride.withLock { $0 = true }
        // Small caps so the test doesn't need a multi-megabyte payload.
        NSELogStore.maxBytesOverride.withLock { $0 = 200 }
        NSELogStore.keepBytesOverride.withLock { $0 = 100 }

        // Pre-populate the file directly (bypassing `append`, which would
        // itself trigger the trim) with well over the 200-byte cap: 30 lines
        // of 8 bytes each = 240 bytes.
        let preExisting = (0..<30).map { String(format: "line%03d", $0) }.joined(separator: "\n") + "\n"
        #expect(preExisting.utf8.count > 200)
        try preExisting.write(to: url, atomically: true, encoding: .utf8)

        // First append this test-process-lifetime — trims BEFORE writing the
        // new line (see `NSELogStore.trimIfNeeded`, run once per process,
        // gated by `trimmedThisProcess`, which `_resetForTesting()` cleared).
        NSELogStore.append("new line after trim")

        let text = NSELogStore.read()
        // The oldest content is gone...
        #expect(!text.contains("line000"))
        // ...but the just-appended line survived the trim.
        #expect(text.contains("new line after trim"))
        // Trimmed file stays well under the pre-trim size.
        #expect(text.utf8.count < preExisting.utf8.count)
    }

    @Test("trim runs at most once per process — a second append does not re-trim")
    func trimOnlyOncePerProcess() throws {
        let url = setUp()
        defer { tearDown(url) }
        NSELogStore.enabledOverride.withLock { $0 = true }
        NSELogStore.maxBytesOverride.withLock { $0 = 200 }
        NSELogStore.keepBytesOverride.withLock { $0 = 100 }

        let preExisting = (0..<30).map { String(format: "line%03d", $0) }.joined(separator: "\n") + "\n"
        try preExisting.write(to: url, atomically: true, encoding: .utf8)

        NSELogStore.append("first append trims")
        let afterFirstAppend = NSELogStore.read()

        // Grow the file back past the cap via direct appends that bypass the
        // store (simulating heavy writes within the same "process" run).
        let filler = String(repeating: "x", count: 300)
        if let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((filler + "\n").utf8))
            try handle.close()
        }

        NSELogStore.append("second append — no retrim")
        let afterSecondAppend = NSELogStore.read()

        // The filler survives because `trimmedThisProcess` is already true —
        // only the FIRST append of the process trims.
        #expect(afterSecondAppend.contains(filler))
        #expect(afterSecondAppend.contains("second append — no retrim"))
        #expect(afterFirstAppend.contains("first append trims"))
    }
}
