/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AIService.normalizeUnicode Deep Coverage")
struct NormalizeUnicodeDeepTests {

    @Test("Already-ASCII text passes through unchanged")
    func asciiPassthrough() {
        let input = "Hello, World! This is a test email with numbers 123 and symbols @#$%."
        let result = AIService.normalizeUnicode(input)
        #expect(result == input)
    }

    @Test("Ellipsis normalized to three dots")
    func ellipsis() {
        let result = AIService.normalizeUnicode("hello\u{2026}world")
        #expect(result.contains("..."))
    }

    @Test("Fullwidth brackets normalized")
    func fullwidthBrackets() {
        let result = AIService.normalizeUnicode("\u{3010}title\u{3011}")
        #expect(result == "[title]")
    }

    @Test("Empty string returns empty")
    func emptyString() {
        let result = AIService.normalizeUnicode("")
        #expect(result == "")
    }

    @Test("Newlines are preserved")
    func newlinesPreserved() {
        let input = "Line 1\nLine 2\nLine 3"
        let result = AIService.normalizeUnicode(input)
        #expect(result == "Line 1\nLine 2\nLine 3")
    }

    @Test("Emoji are preserved (not stripped)")
    func emojiPreserved() {
        let input = "Check this out! 🎉"
        let result = AIService.normalizeUnicode(input)
        #expect(result.contains("🎉"))
    }
}

@Suite("AIService.parseActionResponse Extended")
struct ParseActionResponseDeepTests {

    @Test("Parses action with extra fields (justification)")
    func extraJsonFields() {
        let input = #"{"action": "archive", "justification": "This is a newsletter"}"#
        let result = AIService.parseActionResponse(input)
        #expect(result == .archive)
    }

    @Test("Parses action with confidence field")
    func withConfidence() {
        let input = #"{"action": "reply", "confidence": 0.95}"#
        let result = AIService.parseActionResponse(input)
        #expect(result == .reply)
    }

    @Test("Handles nested JSON gracefully")
    func nestedJson() {
        let input = #"{"action": "delete", "metadata": {"source": "auto"}}"#
        let result = AIService.parseActionResponse(input)
        #expect(result == .delete)
    }

    @Test("Handles action value with leading/trailing whitespace in JSON")
    func actionValueWhitespace() {
        // JSON values with extra whitespace are still valid JSON strings
        let input = #"{"action": " archive "}"#
        let result = AIService.parseActionResponse(input)
        // " archive " lowercased = " archive " which won't match any case
        #expect(result == nil)
    }

    @Test("Code fence with json tag is parsed")
    func codeFenceWithJsonTag() {
        let input = """
        ```json
        {"action": "reply"}
        ```
        """
        let result = AIService.parseActionResponse(input)
        #expect(result == .reply)
    }

    @Test("JSON with unicode action value lowercases correctly")
    func unicodeActionValue() {
        let input = #"{"action": "REPLY"}"#
        let result = AIService.parseActionResponse(input)
        #expect(result == .reply)
    }

    @Test("Null action field returns nil")
    func nullActionField() {
        let input = #"{"action": null}"#
        let result = AIService.parseActionResponse(input)
        #expect(result == nil)
    }

    @Test("Empty action string returns nil")
    func emptyActionString() {
        let input = #"{"action": ""}"#
        let result = AIService.parseActionResponse(input)
        #expect(result == nil)
    }

    @Test("JSON array with action field still extracts action (regex-based)")
    func jsonArray() {
        // Regex-based parser extracts action from any JSON shape (resilient to truncation)
        let input = #"[{"action": "delete"}]"#
        let result = AIService.parseActionResponse(input)
        #expect(result == .delete)
    }
}

@Suite("AIService.formatTimestampForAgent Extended")
struct FormatTimestampForAgentDeepTests {

    @Test("Epoch zero produces valid format")
    func epochZero() {
        let date = Date(timeIntervalSince1970: 0)
        let result = AIService.formatTimestampForAgent(date)
        // `formatTimestampForAgent` renders in the user's local timezone
        // (the backend prompt needs local time, not UTC). Epoch zero is
        // UTC 1970-01-01 00:00:00 — but in zones west of UTC it renders
        // to 1969-12-31, so we can't hardcode the y/m/d. Compute the
        // expected zone-local date with the same calendar the formatter
        // uses (see `PromptFormatters.formatTimestampForAgent`).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let expected = String(format: "%04d/%02d/%02d",
                              c.year ?? 0, c.month ?? 0, c.day ?? 0)
        #expect(result.contains(expected))
    }

    @Test("Far future date produces valid format")
    func farFuture() {
        // 2099-12-31
        var comps = DateComponents()
        comps.year = 2099
        comps.month = 12
        comps.day = 31
        comps.hour = 23
        comps.minute = 59
        comps.second = 59
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: comps)!
        let result = AIService.formatTimestampForAgent(date)
        #expect(result.contains("2099/12/31"))
        #expect(result.contains("23:59:59"))
    }

    @Test("Single-digit hour is zero-padded")
    func singleDigitHourPadded() {
        var comps = DateComponents()
        comps.year = 2024
        comps.month = 6
        comps.day = 15
        comps.hour = 9
        comps.minute = 5
        comps.second = 3
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: comps)!
        let result = AIService.formatTimestampForAgent(date)
        #expect(result.contains("09:05:03"))
    }

    @Test("Format has exactly 5 space-separated parts (DayName Date Time TzAbbr (IANA))")
    func formatStructure() {
        let date = Date()
        let result = AIService.formatTimestampForAgent(date)
        let parts = result.split(separator: " ")
        #expect(parts.count == 5) // DayName YYYY/MM/DD HH:MM:SS TZ (IANA/Identifier)
    }
}

@Suite("SummaryResult Extended")
struct SummaryResultExtendedTests {

    @Test("SummaryResult with only blurb")
    func onlyBlurb() {
        let result = SummaryResult(
            blurb: "A simple summary",
            todos: nil,
            reminderDate: nil,
            reminderTime: nil,
            reminderContent: nil,
            textMessage: nil
        )
        #expect(result.blurb == "A simple summary")
        #expect(result.todos == nil)
        #expect(result.reminderDate == nil)
    }

    @Test("SummaryResult with only reminder fields")
    func onlyReminder() {
        let result = SummaryResult(
            blurb: nil,
            todos: nil,
            reminderDate: "2024-06-01",
            reminderTime: "10:00",
            reminderContent: "Follow up",
            textMessage: nil
        )
        #expect(result.blurb == nil)
        #expect(result.todos == nil)
        #expect(result.reminderDate == "2024-06-01")
        #expect(result.reminderTime == "10:00")
        #expect(result.reminderContent == "Follow up")
    }

    @Test("SummaryResult is Sendable")
    func isSendable() async {
        let result = SummaryResult(
            blurb: "Test",
            todos: nil,
            reminderDate: nil,
            reminderTime: nil,
            reminderContent: nil,
            textMessage: nil
        )
        // Verify it can cross actor boundaries
        let task = Task { result.blurb }
        let value = await task.value
        #expect(value == "Test")
    }
}
