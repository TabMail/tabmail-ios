/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// `.processGlobalState` as well as `.serialized`: these tests rebind
/// `AppLogStore.fileURLOverride` and `DebugModeManager
/// .loggingEnabledOverrideForTesting`, both process-global. `.serialized`
/// orders tests only WITHIN this suite, and `AppLogStoreTests` /
/// `AuthDiagnosticsTests` mutate the same two seams — so without the shared
/// critical section another suite's `_resetForTesting` can point this suite's
/// writer at the real Application Support log mid-test.
@Suite("BackgroundSyncLogger", .serialized, .processGlobalState)
struct BackgroundSyncLoggerTests {

    /// Point the shared app log at a fresh temp file for one test.
    ///
    /// These tests used to write into the real Application Support log and hedge
    /// every assertion with "if the write failed, still pass" — which made them
    /// pass whether or not the logger worked. With the file under test control
    /// the round-trips are asserted outright.
    private func withTempLog<T>(_ body: () throws -> T) rethrows -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bgsynclog_\(UUID().uuidString).log")
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
            let marker = "bgsync_test_\(UUID().uuidString.prefix(8))"
            BackgroundSyncLogger.log(marker)
            #expect(AppLogStore.read().contains(marker))
        }
    }

    @Test("Log entries carry a timestamp and the SYNC channel tag")
    func logTimestamps() {
        withTempLog {
            let marker = "bgts_\(UUID().uuidString.prefix(8))"
            BackgroundSyncLogger.log(marker)
            let log = AppLogStore.read()
            #expect(log.contains(marker))
            let line = log.split(separator: "\n").first { $0.contains(marker) }
            #expect(line != nil)
            if let line {
                #expect(AppLogStore.entryTag(of: line) == "SYNC")
                // The timestamp must be a REAL timestamp. `entryTag` deliberately
                // does not validate it (it runs once per physical line of a
                // 32 MB-capped file), so nothing else in the suite notices if
                // `AppLogStore.append` stops formatting a date at all — replacing
                // `Date().iso8601String()` with a literal left every other
                // assertion here green.
                let field = AppLogEntryLine.timestampField(of: line)
                #expect(field != nil)
                #expect(Date.fromISO8601(field ?? "") != nil,
                        "entry timestamp is not ISO8601: \(field ?? "<none>")")
            }
        }
    }

    @Test("Error log round-trip preserves the source")
    func errorLogRoundTrip() {
        withTempLog {
            let marker = "bgerr_\(UUID().uuidString.prefix(8))"
            BackgroundSyncLogger.logError(marker, source: "TestSource")
            let log = AppLogStore.read(channel: .error)
            #expect(log.contains(marker))
            // The source stays nested inside the ERROR entry — the channel tag
            // identifies the file section, the source still identifies the site.
            #expect(log.contains("[TestSource]"))
        }
    }

    @Test("Chat error round-trip includes the user message continuation line")
    func chatErrorRoundTrip() {
        withTempLog {
            let marker = "bgchat_\(UUID().uuidString.prefix(8))"
            BackgroundSyncLogger.logChatError(marker, userMessage: "what happened")
            let log = AppLogStore.read(channel: .chatError)
            #expect(log.contains(marker))
            #expect(log.contains("User message: what happened"))
        }
    }

    @Test("Reading a channel with no entries returns a placeholder, never a crash")
    func readFallback() {
        withTempLog {
            #expect(AppLogStore.read(channel: .sync) == "(no SYNC log)")
            #expect(AppLogStore.read(channel: .error) == "(no ERROR log)")
        }
    }

    // MARK: - Body double-escape detector

    @Test("htmlLooksDoubleEscaped flags doubly-escaped entities only")
    func bodyHtmlDoubleEscapeDetection() {
        // Correct HTML — must NOT flag (a single layer of &amp;/&nbsp; is normal).
        #expect(!BackgroundSyncLogger.htmlLooksDoubleEscaped("<p>Tom &amp; Jerry &nbsp;</p>"))
        #expect(!BackgroundSyncLogger.htmlLooksDoubleEscaped("<div>plain content</div>"))
        // Doubly-escaped — the stored-body symptom.
        #expect(BackgroundSyncLogger.htmlLooksDoubleEscaped("Tom &amp;amp; Jerry"))
        #expect(BackgroundSyncLogger.htmlLooksDoubleEscaped("&amp;lt;div&amp;gt;"))
        #expect(BackgroundSyncLogger.htmlLooksDoubleEscaped("space&amp;nbsp;here"))
    }

    @Test("diagnoseStoredBody writes only for a double-escaped body")
    func diagnoseStoredBodyIsConditional() {
        withTempLog {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
            defer { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } }

            BackgroundSyncLogger.diagnoseStoredBody(
                source: "clean", headerId: "h1", htmlContent: "<p>Tom &amp; Jerry</p>"
            )
            #expect(AppLogStore.read(channel: .bodyRender) == "(no RENDER log)")

            BackgroundSyncLogger.diagnoseStoredBody(
                source: "dirty", headerId: "h2", htmlContent: "Tom &amp;amp; Jerry"
            )
            let log = AppLogStore.read(channel: .bodyRender)
            #expect(log.contains("DOUBLE-ESCAPE"))
            #expect(log.contains("h2"))
        }
    }
}
