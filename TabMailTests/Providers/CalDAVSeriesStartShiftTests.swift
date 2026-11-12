/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Moving a repeating CalDAV series to a new time keeps every occurrence it
/// had, in the same state, at the new time: a deleted occurrence stays deleted,
/// a changed occurrence stays changed, and the last occurrence stays. RFC 5545
/// ties `EXDATE`, `RDATE`, `UNTIL` and an override's `RECURRENCE-ID` to an
/// occurrence's start, so they move with the series' `DTSTART`.
///
/// Dates are in 2099 (testing rule 7's fixed-date exception), around the
/// 2099-03-08 daylight-saving start in America/Los_Angeles.
@Suite("CalDAV: moving a series' time moves what is tied to its start")
struct CalDAVSeriesStartShiftTests {

    // MARK: - Fixtures

    private static let vtimezone = """
    BEGIN:VTIMEZONE
    TZID:America/Los_Angeles
    BEGIN:DAYLIGHT
    TZOFFSETFROM:-0800
    TZOFFSETTO:-0700
    DTSTART:19700308T020000
    RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU
    TZNAME:PDT
    END:DAYLIGHT
    BEGIN:STANDARD
    TZOFFSETFROM:-0700
    TZOFFSETTO:-0800
    DTSTART:19701101T020000
    RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU
    RDATE:19701101T020000
    TZNAME:PST
    END:STANDARD
    END:VTIMEZONE
    """

    private static let alarm = """
    BEGIN:VALARM
    TRIGGER;VALUE=DATE-TIME:20990302T170000Z
    ACTION:DISPLAY
    DESCRIPTION:Reminder
    END:VALARM
    """

    /// A weekly Monday series, 2099-03-02 to 2099-03-30. The 03-16 occurrence is
    /// deleted, the 03-23 one is moved to 11:30, and UNTIL is the 03-30 start.
    /// `master` and `override` are the lines that vary between fixtures.
    private static func series(master: [String], override: [String]? = nil, timezone: Bool = true) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN"]
        if timezone { lines += vtimezone.components(separatedBy: "\n") }
        lines += ["BEGIN:VEVENT", "UID:series-1", "DTSTAMP:20990101T000000Z"] + master + ["SUMMARY:Weekly sync"]
        lines += alarm.components(separatedBy: "\n") + ["END:VEVENT"]
        if let override {
            lines += ["BEGIN:VEVENT", "UID:series-1", "DTSTAMP:20990101T000000Z"] + override
                + ["SUMMARY:Weekly sync (moved)", "END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    private static let zonedSeries = series(
        master: [
            "DTSTART;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;TZID=America/Los_Angeles:20990302T110000",
            "RRULE:FREQ=WEEKLY;UNTIL=20990330T170000Z",
            "EXDATE;TZID=America/Los_Angeles:20990316T100000",
        ],
        override: [
            "RECURRENCE-ID;TZID=America/Los_Angeles:20990323T100000",
            "DTSTART;TZID=America/Los_Angeles:20990323T113000",
            "DTEND;TZID=America/Los_Angeles:20990323T123000",
        ])

    /// The same series written the way a server that stores UTC values writes it.
    private static let utcValuedSeries = series(
        master: [
            "DTSTART;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;TZID=America/Los_Angeles:20990302T110000",
            "RRULE:FREQ=WEEKLY;UNTIL=20990330T170000Z",
            "EXDATE:20990316T170000Z",
        ],
        override: [
            "RECURRENCE-ID:20990323T170000Z",
            "DTSTART;TZID=America/Los_Angeles:20990323T113000",
            "DTEND;TZID=America/Los_Angeles:20990323T123000",
        ])

    private static func timedPatch(start: String, end: String, zone: String = "America/Los_Angeles") -> GCalEventInput {
        var patch = GCalEventInput()
        patch.startDateTime = start
        patch.endDateTime = end
        patch.startTimeZone = zone
        patch.endTimeZone = zone
        return patch
    }

    private static let shown: [SeriesOracle.State] = [.shown, .shown, .deleted, .changed, .shown]

    @Test("The fixtures' zone still changes its clocks on 2099-03-08, as every daylight-saving case here assumes")
    func fixtureZoneObservesDaylightSaving() throws {
        // A zone that stops changing clocks (as British Columbia's did in 2026) silently turns every
        // daylight-saving case below into a wrong-hour failure, so check the assumption on its own.
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let before = try #require(utc.date(from: DateComponents(year: 2099, month: 3, day: 2, hour: 12)))
        let after = try #require(utc.date(from: DateComponents(year: 2099, month: 3, day: 9, hour: 12)))
        #expect(zone.secondsFromGMT(for: before) == -8 * 3600)
        #expect(zone.secondsFromGMT(for: after) == -7 * 3600)
    }

    // MARK: - Every occurrence survives the move, in the same state

    @Test("Moving a weekly series from 10:00 to 15:00 keeps its deleted, changed and last occurrences")
    func timeMoveKeepsEveryOccurrence() throws {
        #expect(try SeriesOracle.states(Self.zonedSeries) == Self.shown, "non-vacuity: the fixture reads as intended")
        let merged = try CalDAVProvider.mergePatchIntoICS(
            Self.zonedSeries, patch: Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T16:00:00-08:00"))
        #expect(try SeriesOracle.states(merged) == Self.shown)
        #expect(merged.contains("EXDATE;TZID=America/Los_Angeles:20990316T150000"))
        #expect(merged.contains("RECURRENCE-ID;TZID=America/Los_Angeles:20990323T150000"))
        #expect(merged.contains("RRULE:FREQ=WEEKLY;UNTIL=20990330T220000Z"))
        // The changed occurrence stays where the user put it.
        #expect(merged.contains("DTSTART;TZID=America/Los_Angeles:20990323T113000"))
    }

    @Test("Moving a series by a week across a daylight-saving change keeps every value on the wall clock")
    func weekMoveAcrossDaylightSaving() throws {
        let merged = try CalDAVProvider.mergePatchIntoICS(
            Self.zonedSeries, patch: Self.timedPatch(start: "2099-03-09T10:00:00-07:00", end: "2099-03-09T11:00:00-07:00"))
        #expect(try SeriesOracle.states(merged) == Self.shown)
        // A one-week move across the change is 7 days minus an hour as a duration;
        // as days plus wall clock it stays at 10:00.
        #expect(merged.contains("EXDATE;TZID=America/Los_Angeles:20990323T100000"))
        #expect(merged.contains("RECURRENCE-ID;TZID=America/Los_Angeles:20990330T100000"))
        #expect(merged.contains("UNTIL=20990406T170000Z"))
    }

    @Test("Values a server stored in UTC move to the right instant and stay in UTC")
    func utcValuesStayUTC() throws {
        #expect(try SeriesOracle.states(Self.utcValuedSeries) == Self.shown, "non-vacuity")
        let merged = try CalDAVProvider.mergePatchIntoICS(
            Self.utcValuedSeries, patch: Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T16:00:00-08:00"))
        #expect(try SeriesOracle.states(merged) == Self.shown)
        #expect(merged.contains("EXDATE:20990316T220000Z"))
        #expect(merged.contains("RECURRENCE-ID:20990323T220000Z"))
    }

    @Test("An all-day series moved by a day moves its dates by a day, and they stay dates")
    func allDaySeriesMovesByDays() throws {
        let ics = Self.series(
            master: ["DTSTART;VALUE=DATE:20990302", "DTEND;VALUE=DATE:20990303",
                     "RRULE:FREQ=WEEKLY;UNTIL=20990330", "EXDATE;VALUE=DATE:20990316"],
            override: ["RECURRENCE-ID;VALUE=DATE:20990323", "DTSTART;VALUE=DATE:20990324", "DTEND;VALUE=DATE:20990325"])
        #expect(try SeriesOracle.states(ics) == Self.shown, "non-vacuity")
        var patch = GCalEventInput()
        patch.startDate = "2099-03-03"
        patch.endDate = "2099-03-04"
        let merged = try CalDAVProvider.mergePatchIntoICS(ics, patch: patch)
        #expect(try SeriesOracle.states(merged) == Self.shown)
        #expect(merged.contains("EXDATE;VALUE=DATE:20990317"))
        #expect(merged.contains("RECURRENCE-ID;VALUE=DATE:20990324"))
        #expect(merged.contains("RRULE:FREQ=WEEKLY;UNTIL=20990331"))
    }

    @Test("A series from before 1970 moves by whole days too")
    func seriesBefore1970() throws {
        let ics = Self.series(
            master: ["DTSTART;VALUE=DATE:19650302", "DTEND;VALUE=DATE:19650303",
                     "RRULE:FREQ=YEARLY;UNTIL=19700302", "EXDATE;VALUE=DATE:19680302"],
            timezone: false)
        var patch = GCalEventInput()
        patch.startDate = "1965-03-03"
        patch.endDate = "1965-03-04"
        let merged = try CalDAVProvider.mergePatchIntoICS(ics, patch: patch)
        #expect(merged.contains("EXDATE;VALUE=DATE:19680303"))
        #expect(merged.contains("RRULE:FREQ=YEARLY;UNTIL=19700303"))
    }

    @Test("A date-only UNTIL on a timed series moves by the days the start moved")
    func dateUntilOnTimedSeries() throws {
        let ics = Self.series(master: [
            "DTSTART;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;TZID=America/Los_Angeles:20990302T110000",
            "RRULE:FREQ=WEEKLY;UNTIL=20990330",
        ])
        let sameDay = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T16:00:00-08:00"))
        #expect(sameDay.contains("RRULE:FREQ=WEEKLY;UNTIL=20990330"))
        let nextDay = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.timedPatch(start: "2099-03-03T10:00:00-08:00", end: "2099-03-03T11:00:00-08:00"))
        #expect(nextDay.contains("RRULE:FREQ=WEEKLY;UNTIL=20990331"))
        // 23 hours later, on the next day: a day, not a duration rounded down.
        let nextDayEarlier = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.timedPatch(start: "2099-03-03T09:00:00-08:00", end: "2099-03-03T10:00:00-08:00"))
        #expect(nextDayEarlier.contains("RRULE:FREQ=WEEKLY;UNTIL=20990331"))
    }

    @Test("An RRULE the patch writes is kept as written; the other values still move")
    func patchedRuleKeepsItsUntil() throws {
        var patch = Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T16:00:00-08:00")
        patch.recurrence = ["RRULE:FREQ=WEEKLY;UNTIL=20990413T220000Z"]
        let merged = try CalDAVProvider.mergePatchIntoICS(Self.zonedSeries, patch: patch)
        #expect(merged.contains("RRULE:FREQ=WEEKLY;UNTIL=20990413T220000Z"))
        #expect(merged.contains("EXDATE;TZID=America/Los_Angeles:20990316T150000"))
        #expect(merged.contains("RECURRENCE-ID;TZID=America/Los_Angeles:20990323T150000"))
    }

    @Test("Extra dates move too: a date-time RDATE, and a PERIOD's start and end but not its duration")
    func extraDatesMove() throws {
        let ics = Self.series(master: [
            "DTSTART;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;TZID=America/Los_Angeles:20990302T110000",
            "RRULE:FREQ=WEEKLY;COUNT=5",
            "RDATE;TZID=America/Los_Angeles:20990305T100000",
            "RDATE;VALUE=PERIOD:20990306T180000Z/20990306T190000Z,20990307T180000Z/PT1H",
            "RDATE;VALUE=PERIOD:20990305T180000Z/+PT1H",
        ])
        let merged = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T16:00:00-08:00"))
        #expect(merged.contains("RDATE;TZID=America/Los_Angeles:20990305T150000"))
        #expect(merged.contains("RDATE;VALUE=PERIOD:20990306T230000Z/20990307T000000Z,20990307T230000Z/PT1H"))
        #expect(merged.contains("RDATE;VALUE=PERIOD:20990305T230000Z/+PT1H"))
        #expect(merged.contains("RRULE:FREQ=WEEKLY;COUNT=5"))
    }

    @Test("A folded EXDATE line moves as one value list, leaving no orphaned continuation")
    func foldedExdate() throws {
        let ics = Self.series(master: [
            "DTSTART;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;TZID=America/Los_Angeles:20990302T110000",
            "RRULE:FREQ=WEEKLY;COUNT=5",
            "EXDATE;TZID=America/Los_Angeles:20990316T100000,20990323T1",
            " 00000",
        ])
        let merged = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T16:00:00-08:00"))
        #expect(merged.contains("EXDATE;TZID=America/Los_Angeles:20990316T150000,20990323T150000\r\nSUMMARY:"))
    }

    @Test("A floating series moves its floating values by the same wall clock")
    func floatingSeries() throws {
        let ics = Self.series(master: [
            "DTSTART:20990302T100000", "DTEND:20990302T110000",
            "RRULE:FREQ=WEEKLY;UNTIL=20990330T100000", "EXDATE:20990316T100000",
        ], timezone: false)
        // A floating start is rendered in the device zone, so state the patch there.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let start = try #require(local.date(from: DateComponents(year: 2099, month: 3, day: 2, hour: 15)))
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var patch = GCalEventInput()
        patch.startDateTime = iso.string(from: start)
        patch.endDateTime = iso.string(from: start.addingTimeInterval(3600))
        // A floating value is written as the wall clock in the zone the patch is labelled with
        // (#753): the tools always label it with the zone their card showed.
        patch.startTimeZone = TimeZone.current.identifier
        patch.endTimeZone = TimeZone.current.identifier
        let merged = try CalDAVProvider.mergePatchIntoICS(ics, patch: patch)
        #expect(merged.contains("DTSTART:20990302T150000"))
        #expect(merged.contains("EXDATE:20990316T150000"))
        #expect(merged.contains("UNTIL=20990330T150000"))
    }

    // MARK: - A start moved with no end keeps the event's length

    // Google and Outlook carry the end when an edit gives only a start; CalDAV
    // writes DTEND only from the patch, so the merge must move the existing one.

    private static func startOnly(_ start: String, zone: String) -> GCalEventInput {
        var patch = GCalEventInput()
        patch.startDateTime = start
        patch.startTimeZone = zone
        return patch
    }

    private static func line(_ ics: String, _ name: String) -> String? {
        let masterEnd = ics.range(of: "END:VEVENT").map { String(ics[..<$0.lowerBound]) } ?? ics
        return masterEnd.components(separatedBy: "\r\n").last { $0.hasPrefix(name + ";") || $0.hasPrefix(name + ":") }
    }

    @Test("An all-day event given only a new start keeps its length in days")
    func allDayStartAloneKeepsItsDays() throws {
        let ics = Self.series(master: ["DTSTART;VALUE=DATE:20990302", "DTEND;VALUE=DATE:20990304"], timezone: false)
        var patch = GCalEventInput()
        patch.startDate = "2099-03-10"
        let merged = try CalDAVProvider.mergePatchIntoICS(ics, patch: patch)
        #expect(Self.line(merged, "DTSTART") == "DTSTART;VALUE=DATE:20990310")
        #expect(Self.line(merged, "DTEND") == "DTEND;VALUE=DATE:20990312",
                "a two-day event lost its length: \(Self.line(merged, "DTEND") ?? "<none>")")
    }

    @Test("A timed event given only a new start keeps its length, across the March daylight-saving change too")
    func timedStartAloneKeepsItsLength() throws {
        let ics = Self.series(master: [
            "DTSTART;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;TZID=America/Los_Angeles:20990302T113000",
        ])
        let sameDay = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.startOnly("2099-03-02T15:00:00-08:00", zone: "America/Los_Angeles"))
        #expect(Self.line(sameDay, "DTEND") == "DTEND;TZID=America/Los_Angeles:20990302T163000",
                "end: \(Self.line(sameDay, "DTEND") ?? "<none>")")
        // 2099-03-08 is the change; the event still runs 10:00 to 11:30 a week later.
        let nextWeek = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.startOnly("2099-03-09T10:00:00-07:00", zone: "America/Los_Angeles"))
        #expect(Self.line(nextWeek, "DTSTART") == "DTSTART;TZID=America/Los_Angeles:20990309T100000")
        #expect(Self.line(nextWeek, "DTEND") == "DTEND;TZID=America/Los_Angeles:20990309T113000",
                "end: \(Self.line(nextWeek, "DTEND") ?? "<none>")")
    }

    @Test("An end in another zone from the start moves to the same instant after the start, in its own zone")
    func endInAnotherZoneMovesInItsZone() throws {
        // 10:00 New York to 16:30 London is 90 minutes in early March (EST, GMT).
        let ics = Self.series(master: [
            "DTSTART;TZID=America/New_York:20990302T100000",
            "DTEND;TZID=Europe/London:20990302T163000",
        ], timezone: false)
        // A week later New York is on EDT and London still on GMT: 90 minutes after
        // 10:00 EDT is 15:30 in London.
        let merged = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.startOnly("2099-03-09T10:00:00-04:00", zone: "America/New_York"))
        #expect(Self.line(merged, "DTEND") == "DTEND;TZID=Europe/London:20990309T153000",
                "end: \(Self.line(merged, "DTEND") ?? "<none>")")
    }

    @Test("A master with DURATION and no DTEND gains no DTEND when its start moves")
    func durationMasterNeedsNothing() throws {
        let ics = Self.series(master: [
            "DTSTART;TZID=America/Los_Angeles:20990302T100000",
            "DURATION:PT1H30M",
        ])
        let merged = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.startOnly("2099-03-02T15:00:00-08:00", zone: "America/Los_Angeles"))
        #expect(Self.line(merged, "DTSTART") == "DTSTART;TZID=America/Los_Angeles:20990302T150000")
        #expect(Self.line(merged, "DTEND") == nil, "a DTEND was added: \(Self.line(merged, "DTEND") ?? "")")
        #expect(merged.contains("\r\nDURATION:PT1H30M\r\n"))
    }

    @Test("An end the patch gives is written as given, not moved with the start")
    func explicitEndWins() throws {
        let ics = Self.series(master: [
            "DTSTART;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;TZID=America/Los_Angeles:20990302T113000",
        ])
        let merged = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T15:20:00-08:00"))
        #expect(Self.line(merged, "DTEND") == "DTEND;TZID=America/Los_Angeles:20990302T152000",
                "end: \(Self.line(merged, "DTEND") ?? "<none>")")
    }

    @Test("A DTEND that cannot be read or converted refuses the move instead of writing half of it")
    func unmovableEndRefuses() throws {
        let unreadable = Self.series(master: [
            "DTSTART;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;TZID=America/Los_Angeles:2099030T110000",
        ])
        #expect(throws: CalendarProviderError.self) {
            _ = try CalDAVProvider.mergePatchIntoICS(
                unreadable, patch: Self.startOnly("2099-03-02T15:00:00-08:00", zone: "America/Los_Angeles"))
        }
        // An end in a zone this device does not know, from a start in a known one,
        // can only move through an instant it cannot compute.
        let unknownZone = Self.series(master: [
            "DTSTART;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;TZID=Example Unknown Zone:20990302T110000",
        ])
        #expect(throws: CalendarProviderError.self) {
            _ = try CalDAVProvider.mergePatchIntoICS(
                unknownZone, patch: Self.startOnly("2099-03-02T15:00:00-08:00", zone: "America/Los_Angeles"))
        }
    }

    @Test("The same unmovable DTENDs are not read when the patch gives the end: it is written as given")
    func unmovableEndIsReplacedWhenTheEndIsGiven() throws {
        for end in ["DTEND;TZID=America/Los_Angeles:2099030T110000", "DTEND;TZID=Example Unknown Zone:20990302T110000"] {
            let ics = Self.series(master: ["DTSTART;TZID=America/Los_Angeles:20990302T100000", end])
            let merged = try CalDAVProvider.mergePatchIntoICS(
                ics, patch: Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T16:00:00-08:00",
                                            zone: "America/Los_Angeles"))
            #expect(Self.line(merged, "DTEND") == "DTEND;TZID=America/Los_Angeles:20990302T160000",
                    "\(end): end is \(Self.line(merged, "DTEND") ?? "<none>")")
        }
    }

    // MARK: - What does not move

    @Test("Time-zone rules, alarms and an override's own times are not the series' and stay byte for byte")
    func unrelatedLinesStay() throws {
        let merged = try CalDAVProvider.mergePatchIntoICS(
            Self.zonedSeries, patch: Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T16:00:00-08:00"))
        #expect(merged.contains(Self.vtimezone.replacingOccurrences(of: "\n", with: "\r\n")))
        #expect(merged.contains(Self.alarm.replacingOccurrences(of: "\n", with: "\r\n")))
        #expect(merged.contains("DTSTART;TZID=America/Los_Angeles:20990323T113000\r\nDTEND;TZID=America/Los_Angeles:20990323T123000"))
    }

    @Test("An edit that does not move the start leaves every tied value byte for byte")
    func noMoveNoChange() throws {
        let unchangedStart = try CalDAVProvider.mergePatchIntoICS(
            Self.zonedSeries, patch: Self.timedPatch(start: "2099-03-02T10:00:00-08:00", end: "2099-03-02T11:00:00-08:00"))
        #expect(unchangedStart == Self.zonedSeries)
        var rename = GCalEventInput()
        rename.summary = "Renamed"
        let renamed = try CalDAVProvider.mergePatchIntoICS(Self.zonedSeries, patch: rename)
        #expect(renamed == Self.zonedSeries.replacingOccurrences(of: "SUMMARY:Weekly sync\r\nBEGIN:VALARM", with: "SUMMARY:Renamed\r\nBEGIN:VALARM"))
    }

    // MARK: - Zones the device does not know

    @Test("Values in the series' own unknown zone move on the wall clock and follow the start into its new zone")
    func unknownSeriesZoneOwnValues() throws {
        #expect(TimeZone(identifier: "Customized Time Zone") == nil, "non-vacuity: the device does not know this zone")
        let ics = Self.series(
            master: [
                "DTSTART;TZID=Customized Time Zone:20990302T100000",
                "DTEND;TZID=Customized Time Zone:20990302T110000",
                "RRULE:FREQ=WEEKLY;COUNT=5",
                "EXDATE;TZID=Customized Time Zone:20990316T100000",
            ],
            override: [
                "RECURRENCE-ID;TZID=Customized Time Zone:20990323T100000",
                "DTSTART;TZID=Customized Time Zone:20990323T113000",
                "DTEND;TZID=Customized Time Zone:20990323T123000",
            ],
            timezone: false)
        let merged = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T16:00:00-08:00"))
        #expect(merged.contains("DTSTART;TZID=America/Los_Angeles:20990302T150000"))
        #expect(merged.contains("EXDATE;TZID=America/Los_Angeles:20990316T150000"))
        #expect(merged.contains("RECURRENCE-ID;TZID=America/Los_Angeles:20990323T150000"))
    }

    @Test("Moving a series into another zone moves its UTC values through their instants")
    func crossZoneMoveConvertsThroughInstants() throws {
        // A New York series (10:00 EST, then EDT from 03-08) moved to 09:00 in Los Angeles.
        let ics = Self.series(
            master: [
                "DTSTART;TZID=America/New_York:20990302T100000",
                "DTEND;TZID=America/New_York:20990302T110000",
                "RRULE:FREQ=WEEKLY;UNTIL=20990330T140000Z",
                "EXDATE:20990316T140000Z",
            ],
            override: [
                "RECURRENCE-ID:20990323T140000Z",
                "DTSTART;TZID=America/New_York:20990323T113000",
                "DTEND;TZID=America/New_York:20990323T123000",
            ],
            timezone: false)
        #expect(try SeriesOracle.states(ics) == Self.shown, "non-vacuity: the fixture reads as intended")
        let merged = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.timedPatch(start: "2099-03-02T09:00:00-08:00", end: "2099-03-02T10:00:00-08:00"))
        #expect(merged.contains("DTSTART;TZID=America/Los_Angeles:20990302T090000"), "non-vacuity: the zone changed")
        #expect(try SeriesOracle.states(merged) == Self.shown)
        // 09:00 PDT is 16:00 UTC; the same wall-clock shift without the zones would give 13:00.
        #expect(merged.contains("UNTIL=20990330T160000Z"))
        #expect(merged.contains("EXDATE:20990316T160000Z"))
        #expect(merged.contains("RECURRENCE-ID:20990323T160000Z"))
    }

    @Test("A UTC value moved by a week across a daylight-saving change keeps its wall clock in the series' zone")
    func utcValueAcrossDaylightSaving() throws {
        // The first occurrence (10:00 PST, 18:00 UTC) is deleted; a week later it is 10:00 PDT.
        let ics = Self.series(
            master: [
                "DTSTART;TZID=America/Los_Angeles:20990302T100000",
                "DTEND;TZID=America/Los_Angeles:20990302T110000",
                "RRULE:FREQ=WEEKLY;UNTIL=20990330T170000Z",
                "EXDATE;TZID=America/Los_Angeles:20990316T100000",
                "EXDATE:20990302T180000Z",
            ],
            override: [
                "RECURRENCE-ID;TZID=America/Los_Angeles:20990323T100000",
                "DTSTART;TZID=America/Los_Angeles:20990323T113000",
                "DTEND;TZID=America/Los_Angeles:20990323T123000",
            ])
        let states: [SeriesOracle.State] = [.deleted, .shown, .deleted, .changed, .shown]
        #expect(try SeriesOracle.states(ics) == states, "non-vacuity")
        let merged = try CalDAVProvider.mergePatchIntoICS(
            ics, patch: Self.timedPatch(start: "2099-03-09T10:00:00-07:00", end: "2099-03-09T11:00:00-07:00"))
        #expect(merged.contains("EXDATE:20990309T170000Z"))
        #expect(try SeriesOracle.states(merged) == states)
    }

    @Test("A start this code cannot read refuses the edit instead of moving nothing")
    func unreadableStartIsRefused() throws {
        let ics = Self.series(master: [
            "DTSTART;TZID=America/Los_Angeles:20990302T1000",
            "DTEND;TZID=America/Los_Angeles:20990302T110000",
            "RRULE:FREQ=WEEKLY;UNTIL=20990330T170000Z",
            "EXDATE;TZID=America/Los_Angeles:20990316T100000",
        ])
        #expect(throws: CalendarProviderError.self) {
            _ = try CalDAVProvider.mergePatchIntoICS(
                ics, patch: Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T16:00:00-08:00"))
        }
    }

    @Test("A value that would need an unknown zone to move is refused, never written at the old time")
    func unknownZoneConversionIsRefused() throws {
        #expect(TimeZone(identifier: "Customized Time Zone") == nil, "non-vacuity: the device does not know this zone")
        let ics = Self.series(master: [
            "DTSTART;TZID=Customized Time Zone:20990302T100000",
            "DTEND;TZID=Customized Time Zone:20990302T110000",
            "RRULE:FREQ=WEEKLY;UNTIL=20990330T170000Z",
        ], timezone: false)
        #expect(throws: CalendarProviderError.self) {
            _ = try CalDAVProvider.mergePatchIntoICS(
                ics, patch: Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T16:00:00-08:00"))
        }
        // The same series with nothing to convert moves.
        let countOnly = ics.replacingOccurrences(of: "UNTIL=20990330T170000Z", with: "COUNT=5")
        let merged = try CalDAVProvider.mergePatchIntoICS(
            countOnly, patch: Self.timedPatch(start: "2099-03-02T15:00:00-08:00", end: "2099-03-02T16:00:00-08:00"))
        #expect(merged.contains("DTSTART;TZID=America/Los_Angeles:20990302T150000"))
    }
}

/// Reads a weekly series the way RFC 5545 does, independently of the code
/// under test: occurrences every 7 days of wall clock from `DTSTART` in its
/// zone, while not after `UNTIL` (or `COUNT` of them); an occurrence is deleted
/// when an `EXDATE` names its start, and changed when an override's
/// `RECURRENCE-ID` does. Values are compared as instants (dates as dates), so a
/// value written in UTC or another zone matches the occurrence it names.
enum SeriesOracle {
    enum State: Equatable { case shown, deleted, changed }

    private struct Key: Hashable, Comparable {
        let value: Double
        static func < (lhs: Key, rhs: Key) -> Bool { lhs.value < rhs.value }
    }

    static func states(_ ics: String) throws -> [State] {
        let lines = ics.replacingOccurrences(of: "\r\n ", with: "").components(separatedBy: "\r\n")
        var blocks: [[String]] = []
        var current: [String]?
        var depth = 0
        for line in lines {
            if line == "BEGIN:VEVENT" { current = []; depth = 0; continue }
            if line == "END:VEVENT" { if let current { blocks.append(current) }; current = nil; continue }
            if line.hasPrefix("BEGIN:") { depth += 1 }
            if line.hasPrefix("END:") { depth -= 1; continue }
            if depth == 0 { current?.append(line) }
        }
        let master = try #require(blocks.first(where: { !$0.contains(where: { $0.hasPrefix("RECURRENCE-ID") }) }))
        let start = try #require(master.first(where: { $0.hasPrefix("DTSTART") }))
        let rule = try #require(master.first(where: { $0.hasPrefix("RRULE:") }))
        let (startZone, startWall, isDate) = try parse(start)

        var deleted = Set<Key>()
        for line in master where line.hasPrefix("EXDATE") {
            let head = String(line[..<line.firstIndex(of: ":")!])
            for value in line[line.index(after: line.firstIndex(of: ":")!)...].split(separator: ",") {
                deleted.insert(try key(parse(head + ":" + value)))
            }
        }
        var changed = Set<Key>()
        for block in blocks {
            if let rid = block.first(where: { $0.hasPrefix("RECURRENCE-ID") }) { changed.insert(try key(parse(rid))) }
        }

        var until: Key?
        var count: Int?
        for part in rule.dropFirst("RRULE:".count).split(separator: ";") {
            if part.hasPrefix("UNTIL=") { until = try key(parse("UNTIL:" + part.dropFirst("UNTIL=".count))) }
            if part.hasPrefix("COUNT=") { count = Int(part.dropFirst("COUNT=".count)) }
        }

        var states: [State] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for week in 0..<60 {
            let wall = try #require(calendar.date(byAdding: .day, value: 7 * week, to: startWall))
            let occurrence = try key((startZone, wall, isDate))
            if let until, until < occurrence { break }
            if let count, states.count == count { break }
            states.append(deleted.contains(occurrence) ? .deleted : changed.contains(occurrence) ? .changed : .shown)
        }
        return states
    }

    /// (zone the wall clock is read in, the wall clock as a UTC date, is a DATE)
    private static func parse(_ line: String) throws -> (TimeZone?, Date, Bool) {
        let colon = try #require(line.firstIndex(of: ":"))
        let head = line[..<colon]
        let value = String(line[line.index(after: colon)...])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        if value.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            return (nil, try #require(formatter.date(from: value)), true)
        }
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let wall = try #require(formatter.date(from: String(value.prefix(15))))
        if value.hasSuffix("Z") { return (TimeZone(identifier: "UTC"), wall, false) }
        if let tz = head.split(separator: ";").first(where: { $0.hasPrefix("TZID=") }) {
            let zone = try #require(TimeZone(identifier: String(tz.dropFirst("TZID=".count))))
            return (zone, wall, false)
        }
        return (TimeZone(identifier: "UTC"), wall, false)  // floating: read as a plain wall clock
    }

    private static func key(_ parsed: (TimeZone?, Date, Bool)) throws -> Key {
        let (zone, wall, isDate) = parsed
        guard !isDate, let zone else { return Key(value: wall.timeIntervalSince1970) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wall)
        return Key(value: try #require(local.date(from: parts)).timeIntervalSince1970)
    }
}
