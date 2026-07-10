/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// `NSEProviderSupport.llmCallBudget` — the pure wall-clock budget function
/// behind the DEFECT 1 fix (field nse.log, 2026-07-09): `URLRequest.timeoutInterval`
/// is an idle timer that SSE trickling resets, so a nominal "12s" summary call
/// was observed running 26.4s, missing the 27s graceful-exit watchdog by 9ms.
/// Budgeting each call from the run's REMAINING time (instead of the raw
/// nominal timeout) makes the watchdog a true backstop.
///
/// `NSEConfig` (the production constants — 15s-per-attempt summary / 12s action
/// nominal, 27s watchdog, 2.5s finish margin, 2s min call) lives in the
/// `TabMailNotificationService` target only, not `TabMail` — this file uses
/// representative literal values directly so it stays testable from
/// `TabMailTests` (which depends on `TabMail`, and `NSEProviderSupport` lives
/// in `Shared`, compiled into both targets). The function is pure; the exact
/// nominal doesn't change any semantics under test.
@Suite("NSEProviderSupport.llmCallBudget")
struct NSELLMBudgetTests {

    // Representative values (production action nominal + shared watchdog/margin/floor).
    private let nominal: TimeInterval = 12
    private let watchdog: TimeInterval = 27
    private let finishMargin: TimeInterval = 2.5
    private let minCall: TimeInterval = 2

    @Test("Early in the run: plenty of time left, returns the nominal timeout unchanged")
    func nominalFitsFully() {
        // elapsed=1s → remaining budget to watchdog-margin is 27-1-2.5=23.5s,
        // well above nominal (12s) — nominal wins the min().
        let budget = NSEProviderSupport.llmCallBudget(
            nominal: nominal, elapsed: 1, watchdog: watchdog,
            finishMargin: finishMargin, minCall: minCall
        )
        #expect(budget == nominal)
    }

    @Test("Late in the run: remaining time is less than nominal, budget is capped")
    func remainingTimeCapped() {
        // elapsed=20s → remaining = 27-20-2.5 = 4.5s, below nominal (12s).
        let budget = NSEProviderSupport.llmCallBudget(
            nominal: nominal, elapsed: 20, watchdog: watchdog,
            finishMargin: finishMargin, minCall: minCall
        )
        #expect(budget == 4.5)
    }

    @Test("Below the floor: capped budget under minCall returns nil (skip the call)")
    func belowFloorReturnsNil() {
        // elapsed=24s → remaining = 27-24-2.5 = 0.5s, below minCall (2s).
        let budget = NSEProviderSupport.llmCallBudget(
            nominal: nominal, elapsed: 24, watchdog: watchdog,
            finishMargin: finishMargin, minCall: minCall
        )
        #expect(budget == nil)
    }

    @Test("Exactly at the floor boundary: budget == minCall is NOT skipped")
    func exactlyAtFloorBoundary() {
        // Choose elapsed so that watchdog - elapsed - finishMargin == minCall exactly:
        // 27 - elapsed - 2.5 == 2  =>  elapsed == 22.5
        let budget = NSEProviderSupport.llmCallBudget(
            nominal: nominal, elapsed: 22.5, watchdog: watchdog,
            finishMargin: finishMargin, minCall: minCall
        )
        #expect(budget == minCall)
    }

    @Test("Elapsed already past the watchdog: negative budget returns nil")
    func elapsedPastWatchdogReturnsNil() {
        let budget = NSEProviderSupport.llmCallBudget(
            nominal: nominal, elapsed: 30, watchdog: watchdog,
            finishMargin: finishMargin, minCall: minCall
        )
        #expect(budget == nil)
    }

    @Test("elapsed=0: full nominal budget available at the very start of a run")
    func zeroElapsedReturnsNominal() {
        let budget = NSEProviderSupport.llmCallBudget(
            nominal: nominal, elapsed: 0, watchdog: watchdog,
            finishMargin: finishMargin, minCall: minCall
        )
        #expect(budget == nominal)
    }
}

/// `NSEProviderSupport.logLine` — the pure nse.log line formatter behind
/// `NSELog.appendTimed` (extracted to `Shared/` so the format is testable;
/// the NSE target isn't reachable from TabMailTests). These pins are the
/// grep contract for field-log tooling: `[ts] [+Nms ΔMms]` timing block,
/// then the optional `[run:<tag>]` attribution segment added when iOS runs
/// several NotificationService instances concurrently in one reused NSE
/// process. The timestamp is opaque passthrough (far-future literal is fine
/// — nothing compares it to the current date).
@Suite("NSEProviderSupport.logLine format pins")
struct NSELogLineFormatTests {

    private let ts = "2099-01-01T00:00:00.000Z"

    @Test("untagged shape: [ts] [+Nms ΔMms] message")
    func untaggedShape() {
        let line = NSEProviderSupport.logLine(
            timestamp: ts, totalMs: 1234, deltaMs: 56, runTag: nil,
            message: "NSE step4 OK: from=Sender"
        )
        #expect(line == "[\(ts)] [+1234ms Δ56ms] NSE step4 OK: from=Sender")
    }

    @Test("tagged shape: [ts] [+Nms ΔMms] [run:tag] message")
    func taggedShape() {
        let line = NSEProviderSupport.logLine(
            timestamp: ts, totalMs: 0, deltaMs: 0, runTag: "abcd1234",
            message: "NSE ⏰ TIMEOUT"
        )
        #expect(line == "[\(ts)] [+0ms Δ0ms] [run:abcd1234] NSE ⏰ TIMEOUT")
    }

    @Test("oversize message is capped at NSELogStore.lineMaxChars — one unbounded field can't blow the file cap")
    func oversizeMessageCapped() {
        let oversize = String(repeating: "x", count: NSELogStore.lineMaxChars + 500)
        let line = NSEProviderSupport.logLine(
            timestamp: ts, totalMs: 1, deltaMs: 1, runTag: nil, message: oversize
        )
        let expectedPrefix = "[\(ts)] [+1ms Δ1ms] "
        #expect(line.hasPrefix(expectedPrefix))
        let messagePortion = String(line.dropFirst(expectedPrefix.count))
        #expect(messagePortion.count == NSELogStore.lineMaxChars,
                "message portion must be exactly lineMaxChars characters")
        #expect(messagePortion == String(oversize.prefix(NSELogStore.lineMaxChars)))
    }

    @Test("message at exactly lineMaxChars passes through uncapped")
    func exactLimitMessageUntouched() {
        let exact = String(repeating: "y", count: NSELogStore.lineMaxChars)
        let line = NSEProviderSupport.logLine(
            timestamp: ts, totalMs: 2, deltaMs: 2, runTag: nil, message: exact
        )
        #expect(line == "[\(ts)] [+2ms Δ2ms] \(exact)")
    }
}
