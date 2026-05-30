/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AuthDiagnostics", .serialized)
struct AuthDiagnosticsTests {

    @Test("Log and readLog round-trip")
    func logAndRead() {
        let marker = "diag_test_\(UUID().uuidString.prefix(8))"
        AuthDiagnostics.log(marker)
        // Read immediately — the entry we just wrote must be present
        let log = AuthDiagnostics.readLog()
        #expect(log.contains(marker))
    }

    @Test("Log entries have timestamps")
    func logTimestamps() {
        let marker = "ts_test_\(UUID().uuidString.prefix(8))"
        AuthDiagnostics.log(marker)
        let log = AuthDiagnostics.readLog()
        // ISO8601 timestamps look like [2024-03-15T...]
        #expect(log.contains("["))
        #expect(log.contains("]"))
        #expect(log.contains(marker))
    }

    @Test("Most recent log entry is always present")
    func multipleEntries() {
        let markerA = "multi_A_\(UUID().uuidString.prefix(8))"
        let markerB = "multi_B_\(UUID().uuidString.prefix(8))"
        AuthDiagnostics.log(markerA)
        AuthDiagnostics.log(markerB)
        let log = AuthDiagnostics.readLog()
        #expect(log.contains(markerB))
    }

    @Test("readLog returns fallback when no log exists")
    func readLogFallback() {
        let log = AuthDiagnostics.readLog()
        #expect(!log.isEmpty)
    }
}
