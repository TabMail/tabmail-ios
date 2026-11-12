/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// A move of a series to another day moves the days its rule names, as Google Calendar does
/// (`RecurrenceDayShift`), on an RRULE (Google, CalDAV) and on Outlook's stored pattern alike.
/// Every date is relative to today.
@Suite("RecurrenceDayShift: a series' named days move with it")
struct RecurrenceDayShiftTests {

    /// A day `offset` days from a date two weeks ahead.
    private static func day(_ offset: Int) throws -> RecurrenceTail.Day {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(byAdding: .day, value: 14 + offset, to: cal.startOfDay(for: Date()))!
        let parts = cal.dateComponents([.year, .month, .day], from: date)
        return try #require(RecurrenceTail.Day(year: parts.year!, month: parts.month!, day: parts.day!))
    }

    /// A move by `days` from the start of the month after next, so the day of the month moves by
    /// as much (a move within one month).
    private static func withinMonth(_ days: Int, from start: Int = 10) throws -> RecurrenceDayShift.Move {
        let base = try day(0)
        let month = base.month % 12 + 1
        let year = base.year + (base.month == 12 ? 1 : 0)
        let from = try #require(RecurrenceTail.Day(year: year, month: month, day: start))
        return .init(from: from, to: from.adding(days: days))
    }

    @Test("weekdays turn by the days moved, around the week, the rule's other parts and end kept")
    func weekdaysTurn() throws {
        #expect(try RecurrenceDayShift.shifted("RRULE:FREQ=WEEKLY;BYDAY=MO", by: try Self.withinMonth(1)) == "RRULE:FREQ=WEEKLY;BYDAY=TU")
        #expect(try RecurrenceDayShift.shifted("RRULE:FREQ=WEEKLY;COUNT=10;BYDAY=MO,WE,FR", by: try Self.withinMonth(2))
                == "RRULE:FREQ=WEEKLY;COUNT=10;BYDAY=WE,FR,SU")
        #expect(try RecurrenceDayShift.shifted("RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20991231T000000Z", by: try Self.withinMonth(-1))
                == "RRULE:FREQ=WEEKLY;BYDAY=SU;UNTIL=20991231T000000Z")
        #expect(try RecurrenceDayShift.shifted("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR", by: try Self.withinMonth(8))
                == "FREQ=DAILY;BYDAY=TU,WE,TH,FR,SA")
        #expect(try RecurrenceDayShift.shifted("rrule:freq=weekly;byday=mo", by: try Self.withinMonth(1)) == "rrule:freq=weekly;BYDAY=TU")
    }

    @Test("a rule naming both a weekday and a day of the month turns both")
    func weekdayAndMonthDayTurnTogether() throws {
        #expect(try RecurrenceDayShift.shifted("RRULE:FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13", by: try Self.withinMonth(1))
                == "RRULE:FREQ=MONTHLY;BYDAY=SA;BYMONTHDAY=14")
    }

    @Test("Google drops the excluded dates when the rule's days turn, as its own editor does, and keeps the added dates")
    func googleDropsExcludedKeepsAddedDates() throws {
        let stored = ["RRULE:FREQ=WEEKLY;BYDAY=MO", "EXDATE;TZID=UTC:20990105T090000", "RDATE:20990107T090000Z"]
        #expect(try GoogleCalendarProvider.turned(stored, by: try Self.withinMonth(1))
                == ["RRULE:FREQ=WEEKLY;BYDAY=TU", "RDATE:20990107T090000Z"])
    }

    @Test("Google keeps the excluded dates of a rule named by position, which a move leaves as it is")
    func googleKeepsExcludedDatesOfAnUnturnedRule() throws {
        let stored = ["RRULE:FREQ=MONTHLY;BYDAY=2TU", "EXDATE:20990113T090000Z"]
        #expect(try GoogleCalendarProvider.turned(stored, by: try Self.withinMonth(1)) == stored)
    }

    @Test("a series every few weeks turns its week start with its days, Monday when it names none")
    func weekStartTurnsEveryFewWeeks() throws {
        #expect(try RecurrenceDayShift.shifted("RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH", by: try Self.withinMonth(1))
                == "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,FR;WKST=TU")
        #expect(try RecurrenceDayShift.shifted("RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;WKST=SU", by: try Self.withinMonth(1))
                == "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;WKST=MO")
        #expect(try RecurrenceDayShift.shifted("RRULE:FREQ=WEEKLY;BYDAY=MO;WKST=SU", by: try Self.withinMonth(1))
                == "RRULE:FREQ=WEEKLY;BYDAY=TU;WKST=SU", "every week: the week start does not group the days")
    }

    @Test("a day of the month moves by the change in the start's day of the month, a month by its month")
    func monthDaysAndMonthsMove() throws {
        #expect(try RecurrenceDayShift.shifted("RRULE:FREQ=MONTHLY;BYMONTHDAY=10", by: try Self.withinMonth(1)) == "RRULE:FREQ=MONTHLY;BYMONTHDAY=11")
        #expect(try RecurrenceDayShift.shifted("RRULE:FREQ=MONTHLY;BYMONTHDAY=10,20", by: try Self.withinMonth(-2))
                == "RRULE:FREQ=MONTHLY;BYMONTHDAY=8,18")
        // From the 28th to the 3rd of the next month: the day goes back 25, the month on by one.
        let across = try Self.withinMonth(6, from: 28)
        let month = across.from.month
        #expect(try RecurrenceDayShift.shifted("RRULE:FREQ=YEARLY;BYMONTH=\(month);BYMONTHDAY=28", by: across)
                == "RRULE:FREQ=YEARLY;BYMONTH=\(month % 12 + 1);BYMONTHDAY=\(across.to.day)")
    }

    @Test("a day named by its position keeps the whole rule: the moved start is one extra occurrence")
    func positionalRuleIsKept() throws {
        for rule in ["RRULE:FREQ=MONTHLY;BYDAY=2TU", "RRULE:FREQ=MONTHLY;BYDAY=-1FR", "RRULE:FREQ=MONTHLY;BYDAY=MO,TU;BYSETPOS=1",
                     "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2TU"] {
            #expect(try RecurrenceDayShift.shifted(rule, by: try Self.withinMonth(1)) == rule, "\(rule)")
        }
    }

    @Test("a rule naming no days, and a move within the same day, are kept")
    func nothingToTurnIsKept() throws {
        for rule in ["RRULE:FREQ=DAILY", "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=5", "RRULE:FREQ=MONTHLY"] {
            #expect(try RecurrenceDayShift.shifted(rule, by: try Self.withinMonth(3)) == rule, "\(rule)")
        }
        #expect(try RecurrenceDayShift.shifted("RRULE:FREQ=WEEKLY;BYDAY=MO", by: try Self.withinMonth(0)) == "RRULE:FREQ=WEEKLY;BYDAY=MO")
    }

    @Test("a day of the year, a week number, a day counted from the month's end, and one moved out of the month are refused, naming the part")
    func unmovableIsRefused() throws {
        for (rule, part, move) in [
            ("RRULE:FREQ=YEARLY;BYYEARDAY=100", "BYYEARDAY=100", try Self.withinMonth(1)),
            ("RRULE:FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO", "BYWEEKNO=20", try Self.withinMonth(1)),
            ("RRULE:FREQ=MONTHLY;BYMONTHDAY=-1", "BYMONTHDAY=-1", try Self.withinMonth(1)),
            ("RRULE:FREQ=MONTHLY;BYMONTHDAY=28,30", "BYMONTHDAY=30", try Self.withinMonth(2, from: 20)),
        ] {
            do {
                let turned = try RecurrenceDayShift.shifted(rule, by: move)
                Issue.record("\(rule) was turned to \(turned)")
            } catch CalendarProviderError.notSupported(let reason) {
                #expect(reason.contains(part), "\(rule): \(reason)")
            }
        }
    }

    // MARK: - Outlook's pattern

    private static func graphRecurrence(_ pattern: [String: Any]) -> [String: Any] {
        ["pattern": pattern, "range": ["type": "numbered", "startDate": "2099-01-05", "numberOfOccurrences": 4]]
    }

    @Test("Outlook: a weekly pattern turns its days, its week start too every few weeks, its range kept")
    func outlookWeeklyTurns() throws {
        let weekly = Self.graphRecurrence(["type": "weekly", "interval": 1, "daysOfWeek": ["monday", "sunday"], "firstDayOfWeek": "sunday"])
        let turned = try ExchangeCalendarProvider.turned(weekly, by: try Self.withinMonth(1))
        let pattern = turned["pattern"] as? [String: Any]
        #expect(pattern?["daysOfWeek"] as? [String] == ["tuesday", "monday"])
        #expect(pattern?["firstDayOfWeek"] as? String == "sunday")
        #expect((turned["range"] as? [String: Any])?["numberOfOccurrences"] as? Int == 4)
        let everyOther = Self.graphRecurrence(["type": "weekly", "interval": 2, "daysOfWeek": ["monday"], "firstDayOfWeek": "sunday"])
        let turnedOther = try ExchangeCalendarProvider.turned(everyOther, by: try Self.withinMonth(1))["pattern"] as? [String: Any]
        #expect(turnedOther?["daysOfWeek"] as? [String] == ["tuesday"] && turnedOther?["firstDayOfWeek"] as? String == "monday")
    }

    @Test("Outlook: a day of the month and a month move; a day named by its position keeps the pattern")
    func outlookMonthlyAndYearly() throws {
        let monthly = Self.graphRecurrence(["type": "absoluteMonthly", "interval": 1, "dayOfMonth": 10])
        #expect((try ExchangeCalendarProvider.turned(monthly, by: try Self.withinMonth(1))["pattern"] as? [String: Any])?["dayOfMonth"] as? Int == 11)
        let across = try Self.withinMonth(6, from: 28)
        let yearly = Self.graphRecurrence(["type": "absoluteYearly", "interval": 1, "dayOfMonth": 28, "month": across.from.month])
        let turned = try ExchangeCalendarProvider.turned(yearly, by: across)["pattern"] as? [String: Any]
        #expect(turned?["dayOfMonth"] as? Int == across.to.day && turned?["month"] as? Int == across.to.month)
        // Across the year's end: December 31 to January 1.
        let year = try Self.day(0).year
        let newYear = RecurrenceDayShift.Move(
            from: try #require(RecurrenceTail.Day(year: year, month: 12, day: 31)),
            to: try #require(RecurrenceTail.Day(year: year + 1, month: 1, day: 1)))
        let yearEnd = Self.graphRecurrence(["type": "absoluteYearly", "interval": 1, "dayOfMonth": 31, "month": 12])
        let turnedYear = try ExchangeCalendarProvider.turned(yearEnd, by: newYear)["pattern"] as? [String: Any]
        #expect(turnedYear?["dayOfMonth"] as? Int == 1 && turnedYear?["month"] as? Int == 1, "\(turnedYear ?? [:])")
        let relative = Self.graphRecurrence(["type": "relativeMonthly", "interval": 1, "daysOfWeek": ["tuesday"], "index": "second"])
        let kept = try ExchangeCalendarProvider.turned(relative, by: try Self.withinMonth(1))["pattern"] as? [String: Any]
        #expect(kept?["daysOfWeek"] as? [String] == ["tuesday"])
    }

    // MARK: - Google's split

    @Test("Google: a split's new part keeps what is left of the series' count on its new days")
    func googleSplitCarriesTheCountOntoTheNewDays() async throws {
        // A Monday/Wednesday/Friday series of ten from a Monday, split at the next Monday and moved
        // to Tuesday: three occurrences before it, seven left, on Tuesday, Thursday and Saturday.
        var cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        cal.timeZone = utc
        let start = try #require(cal.nextDate(after: Date().addingTimeInterval(7 * 86_400),
                                              matching: DateComponents(hour: 9, minute: 0, second: 0, weekday: 2),
                                              matchingPolicy: .nextTime))
        let split = start.addingTimeInterval(7 * 86_400)
        func naive(_ d: Date) -> String { EKEventStoreHelper.toNaiveISO(d, timeZone: utc) }
        let masterPath = "/calendar/v3/calendars/primary/events/m"
        let master = Data("""
        {"id":"m","summary":"Standup","status":"confirmed",
         "start":{"dateTime":"\(naive(start))Z","timeZone":"UTC"},
         "end":{"dateTime":"\(naive(start.addingTimeInterval(1_800)))Z","timeZone":"UTC"},
         "recurrence":["RRULE:FREQ=WEEKLY;COUNT=10;BYDAY=MO,WE,FR"]}
        """.utf8)
        let instances = try JSONSerialization.data(withJSONObject: ["items": [[
            "id": "m_1", "status": "confirmed", "recurringEventId": "m",
            "start": ["dateTime": naive(split) + "Z", "timeZone": "UTC"],
            "originalStartTime": ["dateTime": naive(split) + "Z", "timeZone": "UTC"],
        ]]])
        let json = ["Content-Type": "application/json"]
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: masterPath, method: "GET", response: .raw(statusCode: 200, headers: json, body: master))
        http.register(path: masterPath + "/instances", method: "GET", response: .raw(statusCode: 200, headers: json, body: instances))
        http.register(path: masterPath, method: "PATCH", response: .raw(statusCode: 200, headers: json, body: master))
        http.register(path: "/calendar/v3/calendars/primary/events", method: "POST",
                      response: .raw(statusCode: 200, headers: json, body: Data(#"{"id":"successor","status":"confirmed"}"#.utf8)))
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        let splitDay = try #require(RecurrenceTail.Day(iso: naive(split)))
        var patch = GCalEventInput()
        patch.startDateTime = naive(split.addingTimeInterval(86_400)) + "Z"
        patch.startTimeZone = "UTC"
        patch.ruleDayMove = .init(from: splitDay, to: splitDay.adding(days: 1))
        _ = try await provider.splitSeries(calendarId: "primary", eventId: "m", recurrenceId: naive(split),
                                           recurrenceIdZone: utc, patch: patch, sendUpdates: "none")
        let created = http.recordedCalls().first { $0.method == "POST" }
            .flatMap { $0.body }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["recurrence"] as? [String] }
        #expect(created == ["RRULE:FREQ=WEEKLY;COUNT=7;BYDAY=TU,TH,SA"], "\(String(describing: created))")
    }
}
