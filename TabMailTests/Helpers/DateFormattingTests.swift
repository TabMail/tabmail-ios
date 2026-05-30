/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("Date.iso8601String")
struct DateISO8601StringTests {

    @Test("Produces ISO8601 without fractional seconds")
    func noFractionalSeconds() {
        let date = Date(timeIntervalSince1970: 1710500000)
        let result = date.iso8601String()
        #expect(result.contains("T"))
        #expect(result.hasSuffix("Z"))
        #expect(!result.contains("."))
    }

    @Test("Is consistent for same date")
    func consistent() {
        let date = Date(timeIntervalSince1970: 1000000)
        #expect(date.iso8601String() == date.iso8601String())
    }

    @Test("Known value")
    func knownValue() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(date.iso8601String() == "1970-01-01T00:00:00Z")
    }
}

@Suite("Date.fromISO8601")
struct DateFromISO8601Tests {

    @Test("Parses standard ISO8601")
    func parsesStandard() {
        let date = Date.fromISO8601("2024-03-15T10:30:00Z")
        #expect(date != nil)
    }

    @Test("Parses ISO8601 with fractional seconds")
    func parsesFractional() {
        let date = Date.fromISO8601("2024-03-15T10:30:00.123Z")
        #expect(date != nil)
    }

    @Test("Returns nil for invalid string")
    func invalidString() {
        #expect(Date.fromISO8601("not-a-date") == nil)
    }

    @Test("Returns nil for empty string")
    func emptyString() {
        #expect(Date.fromISO8601("") == nil)
    }

    @Test("Roundtrips with iso8601String")
    func roundtrip() {
        let original = Date(timeIntervalSince1970: 1710500000)
        let str = original.iso8601String()
        let parsed = Date.fromISO8601(str)
        #expect(parsed != nil)
        // Within 1 second tolerance (no fractional seconds)
        #expect(abs(parsed!.timeIntervalSince(original)) < 1)
    }
}

@Suite("Date.formattedForInbox")
struct DateFormattingTests {

    @Test("Today returns time string")
    func todayReturnsTime() {
        let now = Date()
        let result = now.formattedForInbox()
        // Should be a time string like "2:30 PM" — not "Yesterday" or a day name
        #expect(!result.contains("Yesterday"))
        #expect(!result.contains("Monday"))
        #expect(!result.isEmpty)
    }

    @Test("Yesterday returns 'Yesterday'")
    func yesterdayReturnsYesterday() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let result = yesterday.formattedForInbox()
        #expect(result == "Yesterday")
    }

    @Test("3 days ago returns day name")
    func threeDaysAgoReturnsDayName() {
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let result = threeDaysAgo.formattedForInbox()
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        #expect(dayNames.contains(result))
    }

    @Test("6 days ago returns day name (boundary)")
    func sixDaysAgoReturnsDayName() {
        let sixDaysAgo = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
        let result = sixDaysAgo.formattedForInbox()
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        #expect(dayNames.contains(result))
    }

    @Test("30 days ago same year returns 'MMM d'")
    func thirtyDaysAgoSameYear() {
        // Use a date 30 days ago — if it's still the same year, should be "MMM d" format
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let result = thirtyDaysAgo.formattedForInbox()
        // Should NOT contain year if same year, and should NOT be a day name
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        #expect(!dayNames.contains(result))
        #expect(result != "Yesterday")
    }

    @Test("Date from previous year includes year")
    func previousYearIncludesYear() {
        var comps = DateComponents()
        comps.year = 2020
        comps.month = 6
        comps.day = 15
        let oldDate = Calendar.current.date(from: comps)!
        let result = oldDate.formattedForInbox()
        #expect(result.contains("2020"))
    }

    @Test("Very old date includes year")
    func veryOldDateIncludesYear() {
        var comps = DateComponents()
        comps.year = 2000
        comps.month = 1
        comps.day = 1
        let oldDate = Calendar.current.date(from: comps)!
        let result = oldDate.formattedForInbox()
        #expect(result.contains("2000"))
    }
}
