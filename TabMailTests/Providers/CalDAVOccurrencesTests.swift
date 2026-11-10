/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - The occurrences a CalDAV listing shows (ADR-IOS-108)
//
// INVARIANT (system property): a listing over a range shows a repeating CalDAV event
// the way Google and Outlook list one, one row per occurrence that overlaps the range,
// each at its own time and with an id of its own, and never a single row at the series'
// first date passed off as an occurrence. A series the device cannot expand is one row
// that SAYS its occurrences are not listed.
//
// These suites are the listing contract that `ICSParserTests.skipsRecurrenceExceptions`
// and `ICSParserTests.multipleVEventsReturnsFirst` used to stand in for: those two now
// pin only the SERIES view (`ICSParser.parse`, read by a series id). The changed and
// cancelled occurrences the first one skipped are pinned here by
// `movedOverridesAreListedWhereTheyNowAre` and `cancelledOccurrenceIsMarkedCancelled`;
// the one-row-per-resource shape the second one pinned is replaced by
// `weeklyZonedSeriesKeepsItsWallTimeAcrossDST` and its siblings.
//
// Every date is worked out from `Date()`; none is written as a literal.

/// Builders shared by the occurrence suites.
enum OccurrenceFixture {
    static let href = "/cal/series.ics"

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func format(_ date: Date, _ pattern: String, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// An iCalendar UTC DATE-TIME, `yyyyMMddTHHmmssZ`, which is also an occurrence key.
    static func utcValue(_ date: Date) -> String { format(date, "yyyyMMdd'T'HHmmss'Z'", .gmt) }
    /// An iCalendar wall time in `zone`, `yyyyMMddTHHmmss`.
    static func wall(_ date: Date, _ zone: TimeZone) -> String { format(date, "yyyyMMdd'T'HHmmss", zone) }
    /// An iCalendar DATE in `zone`, `yyyyMMdd`.
    static func dateValue(_ date: Date, _ zone: TimeZone) -> String { format(date, "yyyyMMdd", zone) }
    /// The `yyyy-MM-dd` a listing gives an all-day occurrence.
    static func isoDate(_ date: Date, _ zone: TimeZone) -> String { format(date, "yyyy-MM-dd", zone) }
    /// The naive `yyyy-MM-ddTHH:mm:ss` a `recurrence_id` is written in.
    static func naive(_ date: Date, _ zone: TimeZone) -> String { format(date, "yyyy-MM-dd'T'HH:mm:ss", zone) }

    /// The top of the hour `hours` from now: a whole-second instant, as iCalendar writes them.
    static func topOfHour(hoursFromNow hours: Int) -> Date {
        let hour: TimeInterval = 60 * 60
        let now = (Date().timeIntervalSince1970 / hour).rounded(.down) * hour
        return Date(timeIntervalSince1970: now + TimeInterval(hours) * hour)
    }

    static func days(_ n: Int) -> TimeInterval { TimeInterval(n) * 24 * 60 * 60 }

    /// A VCALENDAR holding `vevents` (each the lines between BEGIN:VEVENT and END:VEVENT).
    static func ics(_ vevents: [String]) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN"]
        for vevent in vevents {
            lines.append("BEGIN:VEVENT")
            lines.append(contentsOf: vevent.split(separator: "\n").map(String.init))
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    static func listing(_ ics: String, from: Date?, to: Date?) -> [GCalEvent] {
        CalDAVOccurrences.listing(icsText: ics, href: href, timeMin: from, timeMax: to)
    }

    static func occurrenceId(_ key: String) -> String {
        CalDAVOccurrences.OccurrenceId.make(seriesHref: href, key: key)
    }
}

@Suite("CalDAV occurrences: each occurrence at its own time")
struct CalDAVOccurrenceExpansionTests {
    typealias F = OccurrenceFixture

    @Test("a weekly series in its own zone keeps its wall time across a change of UTC offset")
    func weeklyZonedSeriesKeepsItsWallTimeAcrossDST() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let transition = try #require(newYork.nextDaylightSavingTimeTransition(after: Date()))
        let calendar = F.calendar(newYork)
        let twoWeeksBefore = try #require(calendar.date(byAdding: .day, value: -14, to: transition))
        let first = try #require(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: twoWeeksBefore))
        let ics = F.ics(["""
            UID:dst-weekly
            DTSTAMP:\(F.utcValue(first))
            DTSTART;TZID=America/New_York:\(F.wall(first, newYork))
            DTEND;TZID=America/New_York:\(F.wall(first.addingTimeInterval(30 * 60), newYork))
            SUMMARY:Standup
            RRULE:FREQ=WEEKLY
            """])

        let rows = F.listing(ics, from: first.addingTimeInterval(-60 * 60), to: first.addingTimeInterval(F.days(29)))
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        #expect(rows.count == 5, "five weekly occurrences overlap the four weeks, got \(rows.count)")
        guard rows.count == 5 else { return }
        var starts: [Date] = []
        for row in rows {
            let start = try #require(row.startDate)
            let end = try #require(row.endDate)
            starts.append(start)
            let wall = calendar.dateComponents([.hour, .minute], from: start)
            #expect(wall.hour == 9 && wall.minute == 0, "an occurrence left 09:00 New York time: \(row.start?.dateTime ?? "nil")")
            #expect(end.timeIntervalSince(start) == 30 * 60)
            #expect(row.id == F.occurrenceId(F.utcValue(start)), "the row's id is not its own occurrence's: \(row.id ?? "nil")")
            #expect(row.recurringEventId == F.href)
            #expect(row.start?.timeZone == "America/New_York")
            #expect(row.recurrence?.contains("RRULE:FREQ=WEEKLY") == true, "the row does not carry its series' rule")
            #expect(row.occurrencesNotListed == nil)
        }
        let gaps = zip(starts.dropFirst(), starts).map { $0.timeIntervalSince($1) }
        let hour: TimeInterval = 60 * 60
        #expect(gaps.allSatisfy { abs($0 - F.days(7)) <= hour }, "weekly gaps: \(gaps)")
        #expect(gaps.contains { $0 != F.days(7) }, "setup: the four weeks did not cross the zone's change of UTC offset")
    }

    @Test("an all-day series lists plain dates, with no time and no zone")
    func allDaySeriesListsPlainDates() throws {
        let device = TimeZone.current
        let calendar = F.calendar(device)
        let firstDay = try #require(calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: Date())))
        func day(_ n: Int) throws -> Date {
            try #require(calendar.date(byAdding: .day, value: n, to: firstDay))
        }
        let secondDay = try day(1)
        let ics = F.ics(["""
            UID:all-day
            DTSTART;VALUE=DATE:\(F.dateValue(firstDay, device))
            DTEND;VALUE=DATE:\(F.dateValue(secondDay, device))
            SUMMARY:Holiday
            RRULE:FREQ=DAILY;COUNT=3
            """])

        let rows = F.listing(ics, from: try day(-1), to: try day(10))
            .sorted { ($0.start?.date ?? "") < ($1.start?.date ?? "") }

        #expect(rows.count == 3)
        guard rows.count == 3 else { return }
        for (index, row) in rows.enumerated() {
            let thisDay = try day(index)
            let nextDay = try day(index + 1)
            #expect(row.start?.date == F.isoDate(thisDay, device))
            #expect(row.end?.date == F.isoDate(nextDay, device))
            #expect(row.start?.dateTime == nil && row.start?.timeZone == nil, "an all-day occurrence was given a time or a zone")
            #expect(row.id == F.occurrenceId(F.dateValue(thisDay, device)))
            #expect(row.isAllDay)
        }
    }

    @Test("an excluded occurrence still counts toward COUNT")
    func excludedOccurrenceCountsTowardCount() {
        let first = F.topOfHour(hoursFromNow: 24)
        let ics = F.ics(["""
            UID:count-exdate
            DTSTART:\(F.utcValue(first))
            DTEND:\(F.utcValue(first.addingTimeInterval(60 * 60)))
            SUMMARY:Course
            RRULE:FREQ=DAILY;COUNT=5
            EXDATE:\(F.utcValue(first.addingTimeInterval(F.days(1))))
            """])

        let keys = F.listing(ics, from: first.addingTimeInterval(-60), to: first.addingTimeInterval(F.days(10)))
            .compactMap(\.id).sorted()

        let expected = [0, 2, 3, 4].map { F.occurrenceId(F.utcValue(first.addingTimeInterval(F.days($0)))) }
        #expect(keys == expected, "COUNT=5 with the second date excluded is four occurrences, the last on day 5")
    }

    @Test("a DATE in an EXDATE takes out that day's occurrence of a timed series")
    func dateExclusionTakesOutThatDay() {
        let first = F.topOfHour(hoursFromNow: 30)
        let second = first.addingTimeInterval(F.days(1))
        let ics = F.ics(["""
            UID:exdate-date
            DTSTART:\(F.utcValue(first))
            DTEND:\(F.utcValue(first.addingTimeInterval(60 * 60)))
            RRULE:FREQ=DAILY;COUNT=3
            EXDATE;VALUE=DATE:\(F.dateValue(second, .gmt))
            """])

        let keys = F.listing(ics, from: first.addingTimeInterval(-60), to: first.addingTimeInterval(F.days(5))).compactMap(\.id)

        #expect(!keys.contains(F.occurrenceId(F.utcValue(second))))
        #expect(keys.count == 2)
    }

    @Test("UNTIL: a DATE includes its whole day, and an instant is exact to the second")
    func untilBoundsTheSeries() throws {
        let calendar = F.calendar(.current)
        let firstDay = try #require(calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: Date())))
        let lastDay = try #require(calendar.date(byAdding: .day, value: 2, to: firstDay))
        let allDay = F.ics(["""
            UID:until-date
            DTSTART;VALUE=DATE:\(F.dateValue(firstDay, .current))
            RRULE:FREQ=DAILY;UNTIL=\(F.dateValue(lastDay, .current))
            """])
        #expect(F.listing(allDay, from: firstDay.addingTimeInterval(-60), to: firstDay.addingTimeInterval(F.days(10))).count == 3)

        let first = F.topOfHour(hoursFromNow: 12)
        let third = first.addingTimeInterval(F.days(2))
        func timed(until: Date) -> String {
            F.ics(["""
                UID:until-instant
                DTSTART:\(F.utcValue(first))
                DTEND:\(F.utcValue(first.addingTimeInterval(60 * 60)))
                RRULE:FREQ=DAILY;UNTIL=\(F.utcValue(until))
                """])
        }
        let range = (from: first.addingTimeInterval(-60), to: first.addingTimeInterval(F.days(10)))
        #expect(F.listing(timed(until: third), from: range.from, to: range.to).count == 3, "an UNTIL on an occurrence includes it")
        #expect(F.listing(timed(until: third.addingTimeInterval(-1)), from: range.from, to: range.to).count == 2,
                "an UNTIL a second before an occurrence excludes it")
    }

    @Test("RDATE adds occurrences, and a PERIOD gives its occurrence its own length")
    func rdatesAddOccurrences() {
        let first = F.topOfHour(hoursFromNow: 20)
        let ics = F.ics(["""
            UID:rdate
            DTSTART:\(F.utcValue(first))
            DTEND:\(F.utcValue(first.addingTimeInterval(60 * 60)))
            RRULE:FREQ=WEEKLY;COUNT=2
            RDATE:\(F.utcValue(first.addingTimeInterval(F.days(3))))
            RDATE;VALUE=PERIOD:\(F.utcValue(first.addingTimeInterval(F.days(4))))/PT2H
            """])

        let rows = F.listing(ics, from: first.addingTimeInterval(-60), to: first.addingTimeInterval(F.days(20)))
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        let expectedStarts: [Date] = [0, 3, 4, 7].map { first.addingTimeInterval(F.days($0)) }
        #expect(rows.compactMap(\.startDate) == expectedStarts)
        var lengths: [TimeInterval] = []
        for row in rows {
            guard let start = row.startDate, let end = row.endDate else { continue }
            lengths.append(end.timeIntervalSince(start))
        }
        let hour: TimeInterval = 60 * 60
        let expectedLengths: [TimeInterval] = [hour, hour, 2 * hour, hour]
        #expect(lengths == expectedLengths)
    }

    @Test("a changed occurrence is listed where it now is: moved out of the range it is gone, moved into it it shows")
    func movedOverridesAreListedWhereTheyNowAre() {
        let first = F.topOfHour(hoursFromNow: 6)
        let movedOut = first.addingTimeInterval(F.days(7))
        let movedInFrom = first.addingTimeInterval(F.days(35))
        let movedInTo = first.addingTimeInterval(F.days(15))
        let ics = F.ics([
            """
            UID:overrides
            DTSTART:\(F.utcValue(first))
            DTEND:\(F.utcValue(first.addingTimeInterval(60 * 60)))
            SUMMARY:Review
            RRULE:FREQ=WEEKLY
            """,
            """
            UID:overrides
            RECURRENCE-ID:\(F.utcValue(movedOut))
            DTSTART:\(F.utcValue(first.addingTimeInterval(F.days(40))))
            DTEND:\(F.utcValue(first.addingTimeInterval(F.days(40) + 60 * 60)))
            SUMMARY:Review moved away
            """,
            """
            UID:overrides
            RECURRENCE-ID:\(F.utcValue(movedInFrom))
            DTSTART:\(F.utcValue(movedInTo))
            DTEND:\(F.utcValue(movedInTo.addingTimeInterval(60 * 60)))
            SUMMARY:Review moved here
            """,
        ])

        let rows = F.listing(ics, from: first.addingTimeInterval(-60), to: first.addingTimeInterval(F.days(20)))
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        #expect(rows.map(\.summary) == ["Review", "Review", "Review moved here"])
        #expect(rows.compactMap(\.startDate) == [first, first.addingTimeInterval(F.days(14)), movedInTo])
        #expect(!rows.contains { $0.startDate == movedOut }, "the occurrence moved away is still listed at its old time")
        #expect(rows.last?.id == F.occurrenceId(F.utcValue(movedInFrom)),
                "a moved occurrence keeps the id of the occurrence it replaces (its RECURRENCE-ID)")
    }

    @Test("a cancelled occurrence comes back marked cancelled, which the listing drops")
    func cancelledOccurrenceIsMarkedCancelled() {
        let first = F.topOfHour(hoursFromNow: 8)
        let cancelled = first.addingTimeInterval(F.days(7))
        let ics = F.ics([
            """
            UID:cancelled
            DTSTART:\(F.utcValue(first))
            DTEND:\(F.utcValue(first.addingTimeInterval(60 * 60)))
            RRULE:FREQ=WEEKLY
            """,
            """
            UID:cancelled
            RECURRENCE-ID:\(F.utcValue(cancelled))
            DTSTART:\(F.utcValue(cancelled))
            DTEND:\(F.utcValue(cancelled.addingTimeInterval(60 * 60)))
            STATUS:CANCELLED
            """,
        ])

        let rows = F.listing(ics, from: first.addingTimeInterval(-60), to: first.addingTimeInterval(F.days(15)))
        let atCancelled = rows.filter { $0.id == F.occurrenceId(F.utcValue(cancelled)) }

        #expect(atCancelled.count == 1)
        #expect(atCancelled.allSatisfy { $0.status == "cancelled" }, "the cancelled occurrence is listed as taking place")
        #expect(rows.filter { $0.status != "cancelled" }.count == 2)
    }

    @Test("an override names its occurrence by the instant, whichever way its RECURRENCE-ID is written")
    func overrideMatchesItsOccurrenceAcrossForms() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let calendar = F.calendar(newYork)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: Date()))
        let first = try #require(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow))
        let second = try #require(calendar.date(byAdding: .day, value: 7, to: first))
        let ics = F.ics([
            """
            UID:forms
            DTSTART;TZID=America/New_York:\(F.wall(first, newYork))
            DTEND;TZID=America/New_York:\(F.wall(first.addingTimeInterval(60 * 60), newYork))
            SUMMARY:Planning
            RRULE:FREQ=WEEKLY;COUNT=3
            """,
            """
            UID:forms
            RECURRENCE-ID:\(F.utcValue(second))
            DTSTART;TZID=America/New_York:\(F.wall(second, newYork))
            DTEND;TZID=America/New_York:\(F.wall(second.addingTimeInterval(60 * 60), newYork))
            SUMMARY:Planning (agenda changed)
            """,
        ])

        let rows = F.listing(ics, from: first.addingTimeInterval(-60), to: first.addingTimeInterval(F.days(20)))

        #expect(rows.count == 3, "the override was listed next to the occurrence it replaces: \(rows.map(\.summary))")
        #expect(rows.filter { $0.startDate == second }.map(\.summary) == ["Planning (agenda changed)"])
    }

    @Test("a floating series repeats at its wall time on the device, keyed by that wall time")
    func floatingSeriesUsesWallTimeKeys() throws {
        let calendar = F.calendar(.current)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: Date()))
        let first = try #require(calendar.date(bySettingHour: 8, minute: 30, second: 0, of: tomorrow))
        let second = try #require(calendar.date(byAdding: .day, value: 1, to: first))
        let ics = F.ics(["""
            UID:floating
            DTSTART:\(F.wall(first, .current))
            DTEND:\(F.wall(first.addingTimeInterval(15 * 60), .current))
            RRULE:FREQ=DAILY;COUNT=2
            """])

        let rows = F.listing(ics, from: first.addingTimeInterval(-60), to: first.addingTimeInterval(F.days(5)))
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        #expect(rows.compactMap(\.startDate) == [first, second])
        #expect(rows.compactMap(\.id) == [F.occurrenceId(F.wall(first, .current)), F.occurrenceId(F.wall(second, .current))])
    }

    @Test("an event that does not repeat is one row with its resource href, as before")
    func singleEventIsOneRow() {
        let start = F.topOfHour(hoursFromNow: 3)
        let ics = F.ics(["""
            UID:single
            DTSTART:\(F.utcValue(start))
            DTEND:\(F.utcValue(start.addingTimeInterval(60 * 60)))
            SUMMARY:Dentist
            """])

        let rows = F.listing(ics, from: start.addingTimeInterval(-60), to: start.addingTimeInterval(F.days(1)))

        #expect(rows.count == 1)
        #expect(rows.first?.id == F.href)
        #expect(rows.first?.recurringEventId == nil)
        #expect(rows.first?.occurrencesNotListed == nil)
    }
}

@Suite("CalDAV occurrences: a series that can't be expanded says so")
struct CalDAVOccurrenceNotListedTests {
    typealias F = OccurrenceFixture

    private static func series(first: Date, extra: [String]) -> String {
        F.ics(["""
            UID:not-listed
            DTSTART:\(F.utcValue(first))
            DTEND:\(F.utcValue(first.addingTimeInterval(30 * 60)))
            SUMMARY:Shift
            \(extra.joined(separator: "\n"))
            """])
    }

    private static func expectOneMarkedRow(_ rows: [GCalEvent], first: Date, rule: String?, label: String) {
        #expect(rows.count == 1, "\(label): \(rows.count) row(s)")
        guard rows.count == 1 else { return }
        let row = rows[0]
        #expect(row.id == F.href, "\(label): the series row must carry the series id, not an occurrence id")
        #expect(row.occurrencesNotListed == true, "\(label): the row does not say its occurrences are missing")
        #expect(row.startDate == first, "\(label): the row is not the series at its first date")
        if let rule { #expect(row.recurrence?.contains(rule) == true, "\(label): the row lost its rule") }
    }

    @Test("rule shapes the expansion does not read are one row marked not listed")
    func unreadableRulesAreOneMarkedRow() {
        let first = F.topOfHour(hoursFromNow: -48)
        let range = (from: Date(), to: Date().addingTimeInterval(F.days(7)))
        let cases: [(extra: [String], rule: String?, label: String)] = [
            (["RRULE:FREQ=HOURLY;INTERVAL=8"], "RRULE:FREQ=HOURLY;INTERVAL=8", "FREQ=HOURLY"),
            (["RRULE:FREQ=WEEKLY;BYWEEKNO=20"], "RRULE:FREQ=WEEKLY;BYWEEKNO=20", "BYWEEKNO"),
            (["RRULE:FREQ=DAILY;BYHOUR=9,17"], "RRULE:FREQ=DAILY;BYHOUR=9,17", "BYHOUR"),
            (["RRULE:FREQ=DAILY", "EXRULE:FREQ=WEEKLY"], "RRULE:FREQ=DAILY", "EXRULE"),
            (["RRULE:FREQ=DAILY", "RRULE:FREQ=WEEKLY"], "RRULE:FREQ=DAILY", "two RRULEs"),
        ]
        for entry in cases {
            let rows = F.listing(Self.series(first: first, extra: entry.extra), from: range.from, to: range.to)
            Self.expectOneMarkedRow(rows, first: first, rule: entry.rule, label: entry.label)
        }
    }

    @Test("a change that applies to all later occurrences (RANGE=THISANDFUTURE) leaves the series one marked row")
    func thisAndFutureOverrideIsOneMarkedRow() {
        let first = F.topOfHour(hoursFromNow: -24)
        let changed = first.addingTimeInterval(F.days(2))
        let ics = F.ics([
            """
            UID:thisandfuture
            DTSTART:\(F.utcValue(first))
            DTEND:\(F.utcValue(first.addingTimeInterval(30 * 60)))
            RRULE:FREQ=DAILY
            """,
            """
            UID:thisandfuture
            RECURRENCE-ID;RANGE=THISANDFUTURE:\(F.utcValue(changed))
            DTSTART:\(F.utcValue(changed.addingTimeInterval(60 * 60)))
            DTEND:\(F.utcValue(changed.addingTimeInterval(90 * 60)))
            """,
        ])
        let rows = F.listing(ics, from: Date(), to: Date().addingTimeInterval(F.days(7)))
        Self.expectOneMarkedRow(rows, first: first, rule: "RRULE:FREQ=DAILY", label: "RANGE=THISANDFUTURE")
    }

    @Test("a walk past the step cap is one marked row, and a series well inside it is expanded")
    func stepCapIsOneMarkedRow() throws {
        let calendar = F.calendar(.gmt)
        let now = F.topOfHour(hoursFromNow: 0)
        let ancient = try #require(calendar.date(byAdding: .year, value: -300, to: now))
        let range = (from: now, to: now.addingTimeInterval(F.days(3)))

        let tooOld = F.listing(Self.series(first: ancient, extra: ["RRULE:FREQ=DAILY"]), from: range.from, to: range.to)
        Self.expectOneMarkedRow(tooOld, first: ancient, rule: "RRULE:FREQ=DAILY", label: "a daily series 300 years old")

        let recent = now.addingTimeInterval(-F.days(100))
        let expanded = F.listing(Self.series(first: recent, extra: ["RRULE:FREQ=DAILY"]), from: range.from, to: range.to)
        #expect(expanded.count == 3, "a daily series 100 days old was not expanded: \(expanded.count) row(s)")
        #expect(expanded.allSatisfy { $0.occurrencesNotListed == nil })
    }

    @Test("a listing with no end cannot be expanded, so the series is one marked row")
    func listingWithNoEndIsOneMarkedRow() {
        let first = F.topOfHour(hoursFromNow: 2)
        let rows = F.listing(Self.series(first: first, extra: ["RRULE:FREQ=WEEKLY"]), from: Date(), to: nil)
        Self.expectOneMarkedRow(rows, first: first, rule: "RRULE:FREQ=WEEKLY", label: "no timeMax")
    }
}

@Suite("CalDAV occurrences: an occurrence id reads back the occurrence it names")
struct CalDAVOccurrenceLookupTests {
    typealias F = OccurrenceFixture

    @Test("every listed occurrence reads back by its id exactly as it was listed")
    func listedOccurrencesReadBack() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let calendar = F.calendar(newYork)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: Date()))
        let first = try #require(calendar.date(bySettingHour: 16, minute: 0, second: 0, of: tomorrow))
        let changed = try #require(calendar.date(byAdding: .day, value: 14, to: first))
        let excluded = try #require(calendar.date(byAdding: .day, value: 7, to: first))
        let ics = F.ics([
            """
            UID:lookup
            DTSTART;TZID=America/New_York:\(F.wall(first, newYork))
            DTEND;TZID=America/New_York:\(F.wall(first.addingTimeInterval(45 * 60), newYork))
            SUMMARY:One to one
            RRULE:FREQ=WEEKLY;COUNT=6
            EXDATE;TZID=America/New_York:\(F.wall(excluded, newYork))
            """,
            """
            UID:lookup
            RECURRENCE-ID;TZID=America/New_York:\(F.wall(changed, newYork))
            DTSTART;TZID=America/New_York:\(F.wall(changed.addingTimeInterval(60 * 60), newYork))
            DTEND;TZID=America/New_York:\(F.wall(changed.addingTimeInterval(105 * 60), newYork))
            SUMMARY:One to one (later)
            """,
        ])

        let rows = F.listing(ics, from: first.addingTimeInterval(-60), to: first.addingTimeInterval(F.days(60)))
        #expect(rows.count == 5)
        for row in rows {
            let id = try #require(row.id)
            let split = try CalDAVOccurrences.OccurrenceId.split(id)
            let key = try #require(split.key, "\(id) is not an occurrence id")
            let read = try #require(CalDAVOccurrences.occurrence(key: key, icsText: ics, href: F.href), "\(id) does not read back")
            #expect(read.id == row.id)
            #expect(read.startDate == row.startDate && read.endDate == row.endDate)
            #expect(read.summary == row.summary)
        }
        let excludedRead = CalDAVOccurrences.occurrence(key: F.utcValue(excluded), icsText: ics, href: F.href)
        #expect(excludedRead?.id == nil, "an excluded occurrence must not read back")
        let nearbyRead = CalDAVOccurrences.occurrence(key: F.utcValue(first.addingTimeInterval(60 * 60)), icsText: ics, href: F.href)
        #expect(nearbyRead?.id == nil, "a key no occurrence has must not read back as a nearby occurrence")
    }

    @Test("occurrence ids: a series id has no key, a damaged one is refused, and each key names its recurrence_id")
    func occurrenceIdShapes() throws {
        let instant = F.topOfHour(hoursFromNow: 5)
        let utcKey = F.utcValue(instant)
        let split = try CalDAVOccurrences.OccurrenceId.split(F.occurrenceId(utcKey))
        #expect(split.seriesHref == F.href && split.key == utcKey)
        #expect(try CalDAVOccurrences.OccurrenceId.split(F.href).key == nil)

        for damaged in ["\(F.href)#", "\(F.href)#tomorrow", "#\(utcKey)", "\(F.href)#\(utcKey)#\(utcKey)"] {
            #expect(throws: CalendarProviderError.self, "'\(damaged)' was read as an event id") {
                _ = try CalDAVOccurrences.OccurrenceId.split(damaged)
            }
        }

        let utcRid = try #require(CalDAVOccurrences.OccurrenceId.recurrenceId(ofKey: utcKey))
        #expect(utcRid.naive == F.naive(instant, .gmt) && utcRid.zone.secondsFromGMT(for: instant) == 0)
        let wallKey = F.wall(instant, .current)
        let wallRid = try #require(CalDAVOccurrences.OccurrenceId.recurrenceId(ofKey: wallKey))
        #expect(wallRid.naive == F.naive(instant, .current) && wallRid.zone.identifier == TimeZone.current.identifier)
        let dateKey = F.dateValue(instant, .current)
        let dateRid = try #require(CalDAVOccurrences.OccurrenceId.recurrenceId(ofKey: dateKey))
        #expect(dateRid.naive == F.isoDate(instant, .current) + "T00:00:00")
    }
}
