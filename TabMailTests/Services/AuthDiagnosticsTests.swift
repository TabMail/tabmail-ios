/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// `.processGlobalState` as well as `.serialized`: these tests rebind
/// `AppLogStore.fileURLOverride`, which is process-global, and `.serialized`
/// orders tests only WITHIN this suite. `AppLogStoreTests` and
/// `BackgroundSyncLoggerTests` mutate the same seam from their own suites — so
/// without the shared critical section another suite's `_resetForTesting` can
/// point `AuthDiagnostics.log` at the real Application Support log mid-test.
@Suite("AuthDiagnostics", .serialized, .processGlobalState)
struct AuthDiagnosticsTests {

    /// Point the shared app log at a fresh temp file for one test.
    private func withTempLog<T>(_ body: () throws -> T) rethrows -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("authdiag_\(UUID().uuidString).log")
        AppLogStore.fileURLOverride.withLock { $0 = url }
        defer {
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        return try body()
    }

    @Test("Log and read round-trip")
    func logAndRead() {
        withTempLog {
            let marker = "diag_test_\(UUID().uuidString.prefix(8))"
            AuthDiagnostics.log(marker)
            #expect(AppLogStore.read(channel: .auth).contains(marker))
        }
    }

    @Test("Log entries carry a timestamp and the AUTH channel tag")
    func logTimestamps() {
        withTempLog {
            let marker = "ts_test_\(UUID().uuidString.prefix(8))"
            AuthDiagnostics.log(marker)
            let log = AppLogStore.read(channel: .auth)
            #expect(log.contains(marker))
            let line = log.split(separator: "\n").first { $0.contains(marker) }
            #expect(line != nil)
            if let line {
                // ISO8601 timestamps look like [2024-03-15T...]
                #expect(line.hasPrefix("["))
                #expect(AppLogStore.entryTag(of: line) == "AUTH")
                // …and "looks like" is not enough: `hasPrefix("[")` and
                // `entryTag` are both satisfied by `[not-a-date] [AUTH] x`, so
                // replacing `Date().iso8601String()` in `AppLogStore.append`
                // with a literal string left this test green. Parse it.
                let field = AppLogEntryLine.timestampField(of: line)
                #expect(field != nil)
                #expect(Date.fromISO8601(field ?? "") != nil,
                        "entry timestamp is not ISO8601: \(field ?? "<none>")")
            }
        }
    }

    @Test("Entries accumulate in call order")
    func multipleEntries() {
        withTempLog {
            let markerA = "multi_A_\(UUID().uuidString.prefix(8))"
            let markerB = "multi_B_\(UUID().uuidString.prefix(8))"
            AuthDiagnostics.log(markerA)
            AuthDiagnostics.log(markerB)
            let log = AppLogStore.read(channel: .auth)
            #expect(log.contains(markerA))
            #expect(log.contains(markerB))
            guard let posA = log.range(of: markerA), let posB = log.range(of: markerB) else {
                Issue.record("markers missing from log")
                return
            }
            #expect(posA.lowerBound < posB.lowerBound)
        }
    }

    @Test("Reading with no auth entries returns a placeholder")
    func readFallback() {
        withTempLog {
            #expect(AppLogStore.read(channel: .auth) == "(no AUTH log)")
        }
    }

    @Test("Auth entries are readable from the shared app log")
    func auditIsReachableFromTheSharedLog() {
        // Auth diagnostics used to go to `auth_diagnostics.log`, which the Debug
        // menu never surfaced — written, never REACHABLE. (Not "never readable":
        // `v1.7.14:AuthDiagnostics` did declare `readLog()`; what it lacked was any
        // surface that called it, and it was the only one of the fifteen log files
        // with no share button anywhere.) The point of the move is
        // that they now appear in the one App Logs export.
        withTempLog {
            let marker = "reachable_\(UUID().uuidString.prefix(8))"
            AuthDiagnostics.log(marker)
            #expect(AppLogStore.read().contains(marker))
        }
    }
}
