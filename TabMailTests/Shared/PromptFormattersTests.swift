/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Validates `Shared/Parse/PromptFormatters` produces the exact same strings
/// as the legacy `AIService.formatTimestampForAgent` (which now delegates
/// through this helper). Backend prompts rely on this format.
@Suite("Shared/Parse PromptFormatters")
struct PromptFormattersTests {

    @Test("formatTimestampForAgent produces expected shape")
    func timestampShape() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let result = PromptFormatters.formatTimestampForAgent(date)
        // Shape: "Weekday YYYY/MM/DD HH:MM:SS TZ (IANA/Identifier)" where TZ
        // may be alpha ("PT", "UTC") or numeric-offset ("GMT+9"). The trailing
        // parenthesized IANA id always present.
        let pattern = #"^(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday) \d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} \S+ \([^)]+\)$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(result.startIndex..., in: result)
        #expect(regex.firstMatch(in: result, range: range) != nil,
                "formatted string doesn't match expected shape: '\(result)'")
    }

    @Test("AIService.formatTimestampForAgent delegates to shared PromptFormatters")
    func legacyDelegation() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(AIService.formatTimestampForAgent(date) == PromptFormatters.formatTimestampForAgent(date))
    }

    @Test("dayOfWeek returns English weekday names")
    func dayOfWeek() {
        let sunday = Date(timeIntervalSince1970: 0)  // 1970-01-01 was a Thursday UTC
        let weekday = PromptFormatters.dayOfWeek(sunday)
        #expect(["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"].contains(weekday))
    }

    @Test("Pacific timezone collapses PDT/PST → PT")
    func timestampPacific() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        let result = PromptFormatters.formatTimestampForAgent(date, timeZone: pacific)
        #expect(result.hasSuffix(" PT (America/Los_Angeles)"),
                "Pacific should render as 'PT (America/Los_Angeles)', got: '\(result)'")
    }

    @Test("Korea timezone renders as KST, not the buggy KT")
    func timestampKorea() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        let result = PromptFormatters.formatTimestampForAgent(date, timeZone: seoul)
        // Regression: the previous `count == 3 && hasSuffix("ST")` rule
        // produced "KT" for Asia/Seoul. The IANA map now hits "KST" first.
        #expect(result.hasSuffix(" KST (Asia/Seoul)"),
                "Asia/Seoul should render as 'KST (Asia/Seoul)', got: '\(result)'")
        #expect(!result.contains(" KT "), "must not corrupt KST to KT")
    }

    @Test("Japan timezone renders as JST, not the buggy JT")
    func timestampJapan() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let result = PromptFormatters.formatTimestampForAgent(date, timeZone: tokyo)
        #expect(result.hasSuffix(" JST (Asia/Tokyo)"),
                "Asia/Tokyo should render as 'JST (Asia/Tokyo)', got: '\(result)'")
    }

    @Test("Hour digits are computed in the requested timezone")
    func timestampHonorsRequestedTimeZone() {
        // 2023-11-14 22:13:20 UTC → 14:13:20 PT (UTC-8) and 07:13:20 KST next day (UTC+9).
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let pacific = PromptFormatters.formatTimestampForAgent(date, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let seoul = PromptFormatters.formatTimestampForAgent(date, timeZone: TimeZone(identifier: "Asia/Seoul")!)
        // The minute and second components match across zones; the hour does not.
        #expect(pacific.contains(" 14:13:20 "))
        #expect(seoul.contains(" 07:13:20 "))
    }
}
