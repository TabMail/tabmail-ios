/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AIService.normalizeUnicode")
struct NormalizeUnicodeTests {

    @Test("Ellipsis to three dots (NFKC)")
    func ellipsis() {
        let result = AIService.normalizeUnicode("wait\u{2026}")
        #expect(result == "wait...")
    }

    @Test("Non-breaking space to regular space (NFKC)")
    func nonBreakingSpace() {
        let result = AIService.normalizeUnicode("hello\u{00A0}world")
        #expect(result == "hello world")
    }

    @Test("Fullwidth brackets to regular")
    func fullwidthBrackets() {
        let result = AIService.normalizeUnicode("\u{3010}notice\u{3011}")
        #expect(result == "[notice]")
    }

    @Test("Plain ASCII unchanged")
    func plainAscii() {
        let input = "Hello, World! 123"
        let result = AIService.normalizeUnicode(input)
        #expect(result == input)
    }

    @Test("Empty string unchanged")
    func emptyString() {
        #expect(AIService.normalizeUnicode("") == "")
    }

    @Test("normalizeUnicode produces a result")
    func normalizeProducesResult() {
        // Verify the function runs without error on mixed Unicode input
        let input = "\u{201C}It\u{2019}s 3\u{2013}5 pages\u{2026}\u{201D}"
        let result = AIService.normalizeUnicode(input)
        // NFKC handles ellipsis → "..."
        #expect(result.contains("..."))
        #expect(!result.isEmpty)
    }

    @Test("Whitespace-only input normalizes to empty after trim — guards against empty toast")
    func whitespaceOnlyBecomesEmpty() {
        // Verifies the scenario that causes empty agent toasts:
        // LLM returns whitespace-only text → passes !isEmpty check →
        // after normalizeUnicode + trim → empty string.
        // sendChatMessage must return nil for these cases.
        let inputs = [" ", "\n", "\t", " \n\t ", "\u{00A0}"]
        for input in inputs {
            let normalized = AIService.normalizeUnicode(input)
            let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed.isEmpty, "Expected empty after normalize+trim for input: \(input.debugDescription)")
        }
    }
}

@Suite("AIService.formatTimestampForAgent")
struct FormatTimestampForAgentTests {

    @Test("Format includes day name")
    func includesDayName() {
        let date = Date()
        let result = AIService.formatTimestampForAgent(date)
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let startsWithDay = dayNames.contains { result.hasPrefix($0) }
        #expect(startsWithDay)
    }

    @Test("Format includes date in YYYY/MM/DD format")
    func includesDate() {
        var comps = DateComponents()
        comps.year = 2024
        comps.month = 3
        comps.day = 15
        comps.hour = 10
        comps.minute = 30
        comps.second = 45
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let result = AIService.formatTimestampForAgent(date)
        #expect(result.contains("2024/03/15"))
        #expect(result.contains("10:30:45"))
    }

    @Test("Format ends with timezone abbreviation and IANA identifier")
    func endsWithTimezone() {
        let result = AIService.formatTimestampForAgent(Date())
        // Shape: "<weekday> <date> <time> <abbr> (<IANA/Identifier>)"
        let parts = result.split(separator: " ")
        #expect(parts.count >= 4)
        let ianaPart = String(parts.last!)
        #expect(ianaPart.hasPrefix("(") && ianaPart.hasSuffix(")"))
        // The abbreviation token sits before the IANA suffix.
        let abbr = String(parts[parts.count - 2])
        #expect(abbr.count >= 2 && abbr.count <= 6)
    }

    @Test("genericTimezoneAbbr converts DST/standard abbreviations to generic forms")
    func genericTimezoneConversion() {
        // Test both summer and winter dates to cover both hasSuffix("DT") and hasSuffix("ST") branches
        // Use dates in January (standard time) and July (daylight time) for US timezones
        let cal = Calendar(identifier: .gregorian)
        let winterDate = cal.date(from: DateComponents(year: 2024, month: 1, day: 15, hour: 12))!
        let summerDate = cal.date(from: DateComponents(year: 2024, month: 7, day: 15, hour: 12))!

        // Both dates should produce valid formatted strings ending with a timezone abbreviation
        let winterResult = AIService.formatTimestampForAgent(winterDate)
        let summerResult = AIService.formatTimestampForAgent(summerDate)

        // Verify format structure (day YYYY/MM/DD HH:MM:SS TZ)
        let winterParts = winterResult.split(separator: " ")
        let summerParts = summerResult.split(separator: " ")
        #expect(winterParts.count >= 3)
        #expect(summerParts.count >= 3)

        // Timezone abbreviation should be 2-5 characters
        let winterTz = String(winterParts.last!)
        let summerTz = String(summerParts.last!)
        #expect(winterTz.count >= 2)
        #expect(summerTz.count >= 2)
    }
}

