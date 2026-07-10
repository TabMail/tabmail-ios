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

    /// Stable file identity (inode number) — the assertion currency for the
    /// "clear must not swap the inode" tests below. nil when the file is gone.
    private func fileID(_ url: URL) -> NSNumber? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber
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

    @Test("inverted override caps (keepBytes > size > maxBytes) do not trap — no trim, content intact")
    func invertedCapsNoTrapNoTrim() throws {
        let url = setUp()
        defer { tearDown(url) }
        NSELogStore.enabledOverride.withLock { $0 = true }
        // INVERTED caps: the ~200-byte file is over maxBytes (64) but UNDER
        // keepBytes (10_000). Before the `size > keepBytes` guard was added,
        // trimIfNeeded computed `size - keepBytes` on UInt64 → underflow trap
        // on the very first append.
        NSELogStore.maxBytesOverride.withLock { $0 = 64 }
        NSELogStore.keepBytesOverride.withLock { $0 = 10_000 }

        let preExisting = (0..<25).map { String(format: "line%03d", $0) }.joined(separator: "\n") + "\n"
        #expect(preExisting.utf8.count > 64)
        #expect(preExisting.utf8.count < 10_000)
        try preExisting.write(to: url, atomically: true, encoding: .utf8)

        // Would trap here without the guard. With it: no crash, no trim.
        NSELogStore.append("appended after inverted caps")

        let text = NSELogStore.read()
        // Nothing was trimmed — keeping MORE than the whole file means the
        // whole file is already within the keep budget.
        #expect(text.contains("line000"))
        #expect(text.contains("line024"))
        #expect(text.contains("appended after inverted caps"))
    }

    @Test("file size exactly at maxBytes is not trimmed (strictly-greater boundary)")
    func exactMaxBytesBoundaryNoTrim() throws {
        let url = setUp()
        defer { tearDown(url) }
        NSELogStore.enabledOverride.withLock { $0 = true }
        NSELogStore.maxBytesOverride.withLock { $0 = 200 }
        NSELogStore.keepBytesOverride.withLock { $0 = 100 }

        // Exactly 200 bytes: 25 lines of "lineNNN\n" (8 bytes each).
        let preExisting = (0..<25).map { String(format: "line%03d", $0) }.joined(separator: "\n") + "\n"
        #expect(preExisting.utf8.count == 200)
        try preExisting.write(to: url, atomically: true, encoding: .utf8)

        NSELogStore.append("boundary append")

        let text = NSELogStore.read()
        // size == maxBytes must NOT trim — the guard is strictly greater-than.
        #expect(text.contains("line000"))
        #expect(text.contains("boundary append"))
    }

    // MARK: - Clear preserves the inode (cross-process cached-handle contract)

    @Test("external in-place clear preserves the inode — a warm NSE's cached handle keeps writing to the visible file")
    func clearPreservesInodeForCachedWriters() throws {
        let url = setUp()
        defer { tearDown(url) }
        NSELogStore.enabledOverride.withLock { $0 = true }

        // Warm NSE process: the first append caches the store's FileHandle.
        NSELogStore.append("old line before clear")
        let idBefore = try #require(fileID(url), "seeded file must exist")

        // Simulate the MAIN APP's Debug-menu clear from its own process using
        // the FIXED clear() semantics — open forWritingTo + truncate(0) +
        // close — via an INDEPENDENT FileHandle. Deliberately NOT
        // NSELogStore.clear(): in this same-process test that would take the
        // cached-handle branch and prove nothing about the cross-process case.
        let external = try FileHandle(forWritingTo: url)
        try external.truncate(atOffset: 0)
        try external.close()

        // The warm NSE's next push logs through its CACHED handle. With the
        // old atomic-replace clear (write-temp-then-RENAME), this line landed
        // on the deleted-inode orphan and vanished — exactly the lines the
        // developer cleared the file to capture.
        NSELogStore.append("new line after external clear")

        let text = NSELogStore.read()
        #expect(!text.contains("old line before clear"), "cleared content must be gone")
        #expect(text.contains("new line after external clear"),
                "the cached handle must land on the VISIBLE file, not an orphaned inode")
        let idAfter = try #require(fileID(url), "file must still exist after clear + append")
        #expect(idAfter == idBefore, "in-place truncate must preserve the inode")
    }

    @Test("clear() without a cached handle truncates in place — same inode, empty content")
    func clearWithoutCachedHandleTruncatesInPlace() throws {
        let url = setUp()   // _resetForTesting() ran — no cached handle in the store
        defer { tearDown(url) }

        // Seed the file directly — NOT via NSELogStore.append, which would
        // cache a handle and route clear() through the cached-handle branch;
        // this test pins the no-cached-handle (production Debug-menu) branch.
        try "seeded line one\nseeded line two\n".write(to: url, atomically: false, encoding: .utf8)
        let idBefore = try #require(fileID(url), "seeded file must exist")

        NSELogStore.clear()

        #expect(NSELogStore.read() == "(no NSE log)", "cleared file reads as empty (placeholder)")
        let idAfter = try #require(fileID(url), "the file must survive the clear (truncate, not delete/rename)")
        #expect(idAfter == idBefore,
                "the no-cached-handle branch must NOT atomic-replace (rename swaps the inode) — truncate in place")
    }
}
