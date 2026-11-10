/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - ExchangeCalendarError

@Suite("ExchangeCalendarError")
struct ExchangeCalendarErrorTests {

    @Test("missingScope is an Error")
    func missingScopeConformsToError() {
        let error: Error = ExchangeCalendarError.missingScope
        #expect(error is ExchangeCalendarError)
    }

    @Test("httpError carries status code")
    func httpErrorCarriesStatusCode() {
        let error = ExchangeCalendarError.httpError(403, nil)
        if case .httpError(let code, _) = error {
            #expect(code == 403)
        } else {
            #expect(Bool(false), "Expected httpError case")
        }
    }

    @Test("httpError carries response data")
    func httpErrorCarriesData() {
        let data = Data("Forbidden".utf8)
        let error = ExchangeCalendarError.httpError(403, data)
        if case .httpError(_, let responseData) = error {
            #expect(responseData == data)
        } else {
            #expect(Bool(false), "Expected httpError case")
        }
    }

    @Test("httpError with nil data")
    func httpErrorNilData() {
        let error = ExchangeCalendarError.httpError(500, nil)
        if case .httpError(let code, let data) = error {
            #expect(code == 500)
            #expect(data == nil)
        } else {
            #expect(Bool(false), "Expected httpError case")
        }
    }

    @Test("eventNotFound is a distinct case")
    func eventNotFound() {
        if case .eventNotFound = ExchangeCalendarError.eventNotFound {
            // pass
        } else {
            #expect(Bool(false), "Expected eventNotFound case")
        }
    }

    @Test("All four cases are distinguishable")
    func allCasesDistinguishable() {
        // The switch below is deliberately EXHAUSTIVE (no `default`): adding a case
        // to `ExchangeCalendarError` must break this test, which is how the new
        // case gets a distinguishability assertion instead of being silently
        // absorbed. `invalidPathSegment` was added 2026-08-05 with the strict
        // Graph path-segment encoder.
        let cases: [ExchangeCalendarError] = [
            .missingScope,
            .httpError(404, nil),
            .eventNotFound,
            .invalidPathSegment("Graph event id"),
        ]

        for (i, error) in cases.enumerated() {
            switch error {
            case .missingScope:
                #expect(i == 0)
            case .httpError:
                #expect(i == 1)
            case .eventNotFound:
                #expect(i == 2)
            case .invalidPathSegment(let context):
                #expect(i == 3)
                #expect(context == "Graph event id",
                        "the case must carry WHICH id failed — a bare failure is unactionable")
            }
        }
    }

    @Test("httpError preserves various HTTP status codes")
    func variousStatusCodes() {
        let codes = [400, 401, 403, 404, 409, 429, 500, 502, 503]
        for code in codes {
            let error = ExchangeCalendarError.httpError(code, nil)
            if case .httpError(let c, _) = error {
                #expect(c == code, "Expected status code \(code)")
            }
        }
    }

    @Test("httpError with empty data is distinct from nil data")
    func emptyVsNilData() {
        let emptyData = Data()
        let withEmpty = ExchangeCalendarError.httpError(400, emptyData)
        let withNil = ExchangeCalendarError.httpError(400, nil)

        if case .httpError(_, let data) = withEmpty {
            #expect(data != nil)
            #expect(data!.isEmpty)
        }
        if case .httpError(_, let data) = withNil {
            #expect(data == nil)
        }
    }

    @Test("ExchangeCalendarError has non-empty localizedDescription")
    func localizedDescription() {
        let errors: [Error] = [
            ExchangeCalendarError.missingScope,
            ExchangeCalendarError.httpError(500, nil),
            ExchangeCalendarError.eventNotFound,
        ]
        for error in errors {
            #expect(!error.localizedDescription.isEmpty)
        }
    }
}

// MARK: - Empty-event filter

@Suite("ExchangeCalendarProvider.isEmptySurfaceEvent")
struct ExchangeCalendarEmptySurfaceTests {

    private func makeProvider() -> ExchangeCalendarProvider {
        ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" })
    }

    private func decodeMSEvent(_ json: String) throws -> MSEvent {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(MSEvent.self, from: data)
    }

    @Test("All-empty MSEvent is empty-surface")
    func allEmpty() async throws {
        let event = try decodeMSEvent(#"{"id": "evt-empty"}"#)
        let provider = makeProvider()
        let result = await provider.isEmptySurfaceEvent(event)
        #expect(result == true)
    }

    @Test("Explicit nulls are empty-surface")
    func explicitNulls() async throws {
        let event = try decodeMSEvent("""
        {
            "id": "evt-nulls",
            "subject": null,
            "location": null,
            "bodyPreview": null,
            "attendees": null
        }
        """)
        let provider = makeProvider()
        let result = await provider.isEmptySurfaceEvent(event)
        #expect(result == true)
    }

    @Test("Empty strings on every surface field is empty-surface")
    func emptyStrings() async throws {
        let event = try decodeMSEvent("""
        {
            "id": "evt-empty-strings",
            "subject": "",
            "location": {"displayName": ""},
            "bodyPreview": "",
            "attendees": []
        }
        """)
        let provider = makeProvider()
        let result = await provider.isEmptySurfaceEvent(event)
        #expect(result == true)
    }

    @Test("Subject populated → not empty-surface")
    func onlySubject() async throws {
        let event = try decodeMSEvent(#"{"id": "evt-subject", "subject": "Team Sync"}"#)
        let provider = makeProvider()
        let result = await provider.isEmptySurfaceEvent(event)
        #expect(result == false)
    }

    @Test("Attendees populated → not empty-surface")
    func onlyAttendees() async throws {
        let event = try decodeMSEvent("""
        {
            "id": "evt-attendees",
            "attendees": [
                {"emailAddress": {"address": "alice@example.com", "name": "Alice"}}
            ]
        }
        """)
        let provider = makeProvider()
        let result = await provider.isEmptySurfaceEvent(event)
        #expect(result == false)
    }

    @Test("Location populated → not empty-surface")
    func onlyLocation() async throws {
        let event = try decodeMSEvent("""
        {
            "id": "evt-location",
            "location": {"displayName": "Conference Room A"}
        }
        """)
        let provider = makeProvider()
        let result = await provider.isEmptySurfaceEvent(event)
        #expect(result == false)
    }

    @Test("BodyPreview populated → not empty-surface")
    func onlyBodyPreview() async throws {
        let event = try decodeMSEvent(#"{"id": "evt-body", "bodyPreview": "Agenda: …"}"#)
        let provider = makeProvider()
        let result = await provider.isEmptySurfaceEvent(event)
        #expect(result == false)
    }

    @Test("Fully populated → not empty-surface, conversion preserves fields")
    func fullyPopulated() async throws {
        let event = try decodeMSEvent("""
        {
            "id": "evt-full",
            "subject": "Quarterly Review",
            "location": {"displayName": "HQ"},
            "bodyPreview": "Bring slides",
            "body": {"contentType": "html", "content": "<html><body><p>Bring slides</p></body></html>"},
            "attendees": [{"emailAddress": {"address": "bob@example.com"}}],
            "showAs": "busy",
            "isAllDay": false
        }
        """)
        let provider = makeProvider()
        #expect(await provider.isEmptySurfaceEvent(event) == false)

        let gcal = await provider.toGCalEvent(event)
        #expect(gcal.summary == "Quarterly Review")
        #expect(gcal.location == "HQ")
        #expect(gcal.description == "Bring slides")
        #expect(gcal.attendees?.count == 1)
    }

    @Test("the description is the stored body at full length, never the 255-character preview, and nil without a body")
    func descriptionFromTheBody() async throws {
        let long = String(repeating: "Notes past the preview. ", count: 20).trimmingCharacters(in: .whitespaces)
        let provider = makeProvider()
        let html = try decodeMSEvent(#"{"id": "evt-html", "bodyPreview": "Notes past", "body": {"contentType": "html", "content": "<p>\#(long)</p>"}}"#)
        #expect(await provider.toGCalEvent(html).description == long)
        let text = try decodeMSEvent(#"{"id": "evt-text", "bodyPreview": "Line one", "body": {"contentType": "text", "content": "Line one\r\nLine two"}}"#)
        #expect(await provider.toGCalEvent(text).description == "Line one\r\nLine two")
        let none = try decodeMSEvent(#"{"id": "evt-none", "bodyPreview": "Preview only"}"#)
        #expect(await provider.toGCalEvent(none).description == nil)
        #expect(await provider.toGCalEvent(none).conferenceUrl == nil)
    }
}

// MARK: - Recurring-event reference-conformance (verified against MS Graph + RFC 5545)

@Suite("ExchangeCalendarProvider recurring-event Graph conformance")
struct ExchangeCalendarRecurringTests {

    private func makeProvider() -> ExchangeCalendarProvider {
        ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" })
    }

    private func decodeMSEvent(_ json: String) throws -> MSEvent {
        try JSONDecoder().decode(MSEvent.self, from: Data(json.utf8))
    }

    @Test("toGCalEvent maps Graph seriesMasterId → recurringEventId")
    func mapsSeriesMasterId() async throws {
        // An expanded occurrence row from calendarView carries seriesMasterId.
        let event = try decodeMSEvent("""
        {
            "id": "occ-abc_20260520",
            "subject": "Weekly sync",
            "seriesMasterId": "master-abc"
        }
        """)
        let provider = makeProvider()
        let gcal = await provider.toGCalEvent(event)
        #expect(gcal.recurringEventId == "master-abc")
    }

    @Test("toGCalEvent leaves recurringEventId nil for a non-occurrence event")
    func noSeriesMasterIdMeansNil() async throws {
        let event = try decodeMSEvent(#"{"id": "single-evt", "subject": "One-off"}"#)
        let provider = makeProvider()
        let gcal = await provider.toGCalEvent(event)
        #expect(gcal.recurringEventId == nil)
    }

    @Test("graphEndDateBefore returns the local DATE of (split − 1 day) — Graph endDate is inclusive")
    func graphEndDateBeforeDayBefore() {
        // MS Graph recurrenceRange.endDate is DATE-inclusive, so to EXCLUDE the
        // 2026-05-20 occurrence the cap endDate must be 2026-05-19.
        #expect(ExchangeCalendarProvider.graphEndDateBefore(naiveISO: "2026-05-20T17:00:00", allDay: false, zone: .current) == "2026-05-19")
        // Date-only recurrence_id form also parses.
        #expect(ExchangeCalendarProvider.graphEndDateBefore(naiveISO: "2026-05-20", allDay: true, zone: .current) == "2026-05-19")
        // Malformed input → nil (caller surfaces an error rather than guessing).
        #expect(ExchangeCalendarProvider.graphEndDateBefore(naiveISO: "garbage", allDay: false, zone: .current) == nil)
    }

    @Test("graphEndDateBefore rolls month/year boundaries (Calendar arithmetic, not flat 86400s)")
    func graphEndDateBeforeBoundaries() {
        #expect(ExchangeCalendarProvider.graphEndDateBefore(naiveISO: "2026-03-01T09:00:00", allDay: false, zone: .current) == "2026-02-28")
        #expect(ExchangeCalendarProvider.graphEndDateBefore(naiveISO: "2026-01-01T09:00:00", allDay: false, zone: .current) == "2025-12-31")
        // Leap year.
        #expect(ExchangeCalendarProvider.graphEndDateBefore(naiveISO: "2028-03-01T09:00:00", allDay: false, zone: .current) == "2028-02-29")
    }

    /// 2026-05-14 is a Thursday — used to verify DTSTART-implied fields.
    private func thursdayStart() -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f.date(from: "2026-05-14T22:00:00")!
    }

    // MARK: - #551: Graph's endDate is the series' last day in the EVENT's zone

    /// A day relative to `now`, written in `format` in `zone` (never a hardcoded date). Each test
    /// reads the clock once and passes it to every call, so a run across midnight cannot mix days.
    private func relativeDay(_ days: Int, _ format: String, in zone: TimeZone, from now: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = cal
        f.timeZone = zone
        f.dateFormat = format
        return f.string(from: cal.date(byAdding: .day, value: days, to: now)!)
    }

    /// Zones on both sides of UTC, including half-hour offsets and the extremes. A timed series is
    /// labelled with each and the round trip reads its range in each, so those outcomes do not
    /// depend on the simulator's zone. An all-day input carries no zone label, so for it the zone
    /// only picks which day is today.
    static let endDateZones = [
        "America/Los_Angeles", "America/St_Johns", "UTC", "Asia/Kolkata", "Pacific/Kiritimati",
    ]

    /// How the user can say when a series that starts at 10:00 ends, as wall time in the event's
    /// zone, and the day its last occurrence falls on relative to the day named: a date (read as
    /// the end of that day), a time after the start, the start time itself (the bound is
    /// inclusive), and times before it, where that day's 10:00 occurrence is past the end.
    struct UntilCase: Sendable, CustomTestStringConvertible {
        let wallTime: String?
        let lastDayOffset: Int
        var testDescription: String { "\(wallTime ?? "date only"), last day \(lastDayOffset)" }
    }

    static let untilCases = [
        UntilCase(wallTime: nil, lastDayOffset: 0),
        UntilCase(wallTime: "23:30:00", lastDayOffset: 0),
        UntilCase(wallTime: "10:00:00", lastDayOffset: 0),
        UntilCase(wallTime: "09:59:59", lastDayOffset: -1),
        UntilCase(wallTime: "05:00:00", lastDayOffset: -1),
    ]

    /// INVARIANT (#551): **an Outlook series ends on the last day whose occurrence starts at or
    /// before the user's end, in the event's zone**, as Google Calendar expands the same rule. The
    /// user's end goes through the real producer (`buildGCalEventInput`, which writes a timed
    /// series' `UNTIL` as a UTC instant) and the real writer (`toGraphEventJSON`), and Graph's
    /// inclusive `endDate` must be that day. Before the fix the writer used the UTC instant's own
    /// date: a day long behind UTC for a late end (every attendee got an extra day of
    /// occurrences), and an end before the start time kept a day it never reaches.
    @Test("A timed series ends on its last occurrence's day in the event's zone",
          arguments: ExchangeCalendarRecurringTests.endDateZones, ExchangeCalendarRecurringTests.untilCases)
    func timedSeriesEndsOnItsLastOccurrenceDay(zoneId: String, untilCase: UntilCase) throws {
        let zone = try #require(TimeZone(identifier: zoneId))
        let now = Date()
        let namedDay = relativeDay(30, "yyyy-MM-dd", in: zone, from: now)
        let lastDay = relativeDay(30 + untilCase.lastDayOffset, "yyyy-MM-dd", in: zone, from: now)
        let firstDay = relativeDay(7, "yyyy-MM-dd", in: zone, from: now)
        let until = untilCase.wallTime.map { "\(namedDay)T\($0)" } ?? namedDay
        let args: [String: JSONValue] = [
            "title": .string("Daily check-in"),
            "start_iso": .string("\(firstDay)T10:00:00"),
            "end_iso": .string("\(firstDay)T10:30:00"),
            "timezone": .string(zoneId),
            "recurrence": .dictionary(["freq": .string("daily"), "until": .string(until)]),
        ]
        let input = try CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        let rule = try #require(input.recurrence?.first)
        #expect(rule.hasSuffix("Z"), "premise: a timed series' UNTIL is a UTC instant (\(rule))")

        let json = makeProvider().toGraphEventJSON(input)
        let range = (json["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        #expect(range?["type"] as? String == "endDate")
        #expect(range?["endDate"] as? String == lastDay, "UNTIL \(rule) in \(zoneId)")
    }

    /// A start written without seconds (`…T10:00`) is the same 10:00 start, so an end at 05:00 still
    /// ends the series the day before.
    @Test("A seconds-less start still ends the series before an unreached start time")
    func secondsLessStartKeepsTheStartTimeRule() throws {
        let zoneId = "America/Los_Angeles"
        let zone = try #require(TimeZone(identifier: zoneId))
        let now = Date()
        let firstDay = relativeDay(7, "yyyy-MM-dd", in: zone, from: now)
        let args: [String: JSONValue] = [
            "title": .string("Daily check-in"),
            "start_iso": .string("\(firstDay)T10:00"),
            "end_iso": .string("\(firstDay)T10:30"),
            "timezone": .string(zoneId),
            "recurrence": .dictionary(["freq": .string("daily"),
                                       "until": .string("\(relativeDay(30, "yyyy-MM-dd", in: zone, from: now))T05:00:00")]),
        ]
        let input = try CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        let json = makeProvider().toGraphEventJSON(input)
        #expect((json["start"] as? [String: Any])?["dateTime"] as? String == "\(firstDay)T10:00:00")
        let range = (json["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        #expect(range?["endDate"] as? String == relativeDay(29, "yyyy-MM-dd", in: zone, from: now))
    }

    /// A weekly series created at 23:30 on the device, its start spelled with or without an offset:
    /// Graph stores that instant, the end is the one given, and the rule's weekday and range start
    /// are the stored start's device day, which near midnight is not the UTC day.
    @Test("A weekly series created near midnight by a start spelled with an offset meets on the stored start's weekday",
          arguments: StartSpelling.allCases)
    func weeklySeriesBySpelledStartNearMidnight(_ spelling: StartSpelling) throws {
        let device = TimeZone.current.identifier
        let start = GraphFixture.onDevice(days: 0, hour: 23).addingTimeInterval(1_800)
        let args: [String: JSONValue] = [
            "title": .string("Late sync"),
            "start_iso": .string(spelling.spell(start, label: device)),
            "end_iso": .string(spelling.spell(start.addingTimeInterval(1_800), label: device)),
            "recurrence": .dictionary(["freq": .string("weekly")]),
        ]
        let json = makeProvider().toGraphEventJSON(try CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false))

        let stored = try #require(GraphFixture.instant(json["start"] as? [String: Any]), "no start in \(json)")
        #expect(stored == start, "Graph stores \(String(describing: json["start"])), the user asked for \(start)")
        #expect(GraphFixture.instant(json["end"] as? [String: Any]) == start.addingTimeInterval(1_800), "\(String(describing: json["end"]))")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let recurrence = json["recurrence"] as? [String: Any]
        #expect((recurrence?["pattern"] as? [String: Any])?["daysOfWeek"] as? [String] == [names[cal.component(.weekday, from: stored) - 1]],
                "\(String(describing: recurrence))")
        #expect((recurrence?["range"] as? [String: Any])?["startDate"] as? String == GraphFixture.deviceDay(stored))
    }

    /// An all-day series' `UNTIL` is a bare date and stays the day the user named. The input
    /// carries no zone label, so the writer runs in the simulator's zone here; that a bare date
    /// keeps its digits in every zone is pinned by `graphEndDateForms` and `graphEndDateRoundTrips`.
    @Test("An all-day series ends on the user's last day", arguments: ExchangeCalendarRecurringTests.endDateZones)
    func allDaySeriesEndsOnTheNamedDay(zoneId: String) throws {
        let zone = try #require(TimeZone(identifier: zoneId))
        let now = Date()
        let lastDay = relativeDay(30, "yyyy-MM-dd", in: zone, from: now)
        let args: [String: JSONValue] = [
            "title": .string("Holiday"),
            "start_iso": .string(relativeDay(7, "yyyy-MM-dd", in: zone, from: now)),
            "end_iso": .string(relativeDay(8, "yyyy-MM-dd", in: zone, from: now)),
            "timezone": .string(zoneId),
            "recurrence": .dictionary(["freq": .string("weekly"), "until": .string(lastDay)]),
        ]
        let input = try CalendarToolHelpers.buildGCalEventInput(args, isAllDay: true)
        let json = makeProvider().toGraphEventJSON(input)
        let range = (json["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        #expect(range?["endDate"] as? String == lastDay)
    }

    /// Each UNTIL form on its own: a UTC instant is dated in the given zone (the next or previous
    /// UTC day becomes the local day), a floating time and a bare date keep their date, and a UTC
    /// time of day before the series' start time ends the series the day before.
    @Test("graphEndDate dates an UNTIL in the zone and ends the day before an unreached start time")
    func graphEndDateForms() throws {
        let behind = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let ahead = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        let now = Date()
        let utcDay = relativeDay(30, "yyyyMMdd", in: utc, from: now)
        let day = relativeDay(30, "yyyy-MM-dd", in: utc, from: now)
        let previousDay = relativeDay(29, "yyyy-MM-dd", in: utc, from: now)
        let nextDay = relativeDay(31, "yyyy-MM-dd", in: utc, from: now)
        let tenAM = "\(day)T10:00:00"
        let endDate = ExchangeCalendarProvider.graphEndDate(until:in:startWallTime:)

        // With no start time, 06:00Z is the previous evening at UTC-7 and UTC-8; 12:00Z is 02:00
        // the next day at UTC+14.
        #expect(endDate("\(utcDay)T060000Z", behind, nil) == previousDay)
        #expect(endDate("\(utcDay)T120000Z", ahead, nil) == nextDay)
        #expect(endDate("\(utcDay)T120000Z", utc, nil) == day)
        // A 10:00 series: that evening is after its start time, so that day stays; 02:00 is before
        // it, so the series ends the local day before, here the UTC date.
        #expect(endDate("\(utcDay)T060000Z", behind, tenAM) == previousDay)
        #expect(endDate("\(utcDay)T120000Z", ahead, tenAM) == day)
        // The bound is inclusive: at the start time the day stays, one second earlier it does not.
        #expect(endDate("\(utcDay)T100000Z", utc, tenAM) == day)
        #expect(endDate("\(utcDay)T095959Z", utc, tenAM) == previousDay)
        // Floating wall time keeps its own date, whatever the start time.
        #expect(endDate("\(utcDay)T070000", behind, nil) == day)
        #expect(endDate("\(utcDay)T070000", behind, tenAM) == day)
        #expect(endDate("\(utcDay)T100000", behind, tenAM) == day)
        // A bare date has no time of day: always its own date.
        #expect(endDate(utcDay, ahead, tenAM) == day)
        // A start in no wall-time form leaves the UNTIL's own local day.
        #expect(endDate("\(utcDay)T120000Z", ahead, "garbage") == nextDay)
        // A 16-character `Z` value that does not parse (second 60) keeps its own date digits,
        // where dating it at UTC+14 would have moved it to the next day.
        #expect(endDate("\(utcDay)T235960Z", ahead, nil) == day)
        // Too few date digits: no endDate (the range stays noEnd).
        #expect(endDate("1234", behind, nil) == nil)
    }

    /// The rule `toGCalEvent` derives from Graph's own `endDate` range comes back to the same
    /// date in any zone, so an edit that re-sends the recurrence keeps the series' end.
    @Test("A Graph endDate range round-trips through toGCalEvent in any zone", arguments: ExchangeCalendarRecurringTests.endDateZones)
    func graphEndDateRoundTrips(zoneId: String) async throws {
        let zone = try #require(TimeZone(identifier: zoneId))
        let now = Date()
        let startDay = relativeDay(7, "yyyy-MM-dd", in: zone, from: now)
        let endDate = relativeDay(30, "yyyy-MM-dd", in: zone, from: now)
        let event = try decodeMSEvent("""
        {"id": "m1", "subject": "x",
         "recurrence": {"pattern": {"type": "daily", "interval": 1},
                        "range": {"type": "endDate", "startDate": "\(startDay)",
                                  "endDate": "\(endDate)"}}}
        """)
        let provider = makeProvider()
        let rrule = try #require(await provider.toGCalEvent(event).recurrence?.first)
        let regraph = provider.parseRRULEToGraphRecurrence(rrule, eventStart: nil, timeZone: zone, startWallTime: "\(startDay)T10:00:00")
        #expect((regraph["range"] as? [String: Any])?["endDate"] as? String == endDate)
    }

    @Test("parseRRULEToGraphRecurrence handles the bare 8-char UNTIL date too")
    func parseRRULEBareDateUntil() async {
        let provider = makeProvider()
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=DAILY;UNTIL=20260527", eventStart: nil, timeZone: .current, startWallTime: nil)
        let range = rec["range"] as? [String: Any]
        #expect(range?["endDate"] as? String == "2026-05-27")
    }

    @Test("parseRRULEToGraphRecurrence leaves range as noEnd for an open-ended rule")
    func parseRRULENoEnd() async {
        let provider = makeProvider()
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=WEEKLY;BYDAY=MO,WE", eventStart: nil, timeZone: .current, startWallTime: nil)
        let range = rec["range"] as? [String: Any]
        #expect(range?["type"] as? String == "noEnd")
        let pattern = rec["pattern"] as? [String: Any]
        #expect(pattern?["type"] as? String == "weekly")
        #expect((pattern?["daysOfWeek"] as? [String])?.sorted() == ["monday", "wednesday"])
        // Graph REQUIRES firstDayOfWeek for weekly patterns.
        #expect(pattern?["firstDayOfWeek"] as? String == "sunday")
    }

    @Test("parseRRULEToGraphRecurrence: FREQ=WEEKLY with no BYDAY derives daysOfWeek from DTSTART")
    func parseRRULEWeeklyNoByDay() async {
        // Graph rejects a weekly pattern with no daysOfWeek (HTTP 400). RFC 5545:
        // FREQ=WEEKLY with no BYDAY recurs on DTSTART's weekday.
        let provider = makeProvider()
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=WEEKLY", eventStart: thursdayStart(), timeZone: .current, startWallTime: nil)
        let pattern = rec["pattern"] as? [String: Any]
        #expect(pattern?["type"] as? String == "weekly")
        #expect(pattern?["daysOfWeek"] as? [String] == ["thursday"])
        #expect(pattern?["firstDayOfWeek"] as? String == "sunday")
    }

    /// A series in a zone other than the device's that starts near midnight recurs on its
    /// start's weekday in its own zone, where Graph reads the pattern, not the device's.
    @Test("toGraphEventJSON: a weekly rule with no day recurs on the start's weekday in the event's zone, not the device's")
    func weeklyNoByDayInEventZone() throws {
        let provider = makeProvider()
        // A zone half a day from the device's, and a start whose date there is not the device's.
        let east = TimeZone.current.secondsFromGMT() < 0
        let zoneName = east ? "Pacific/Kiritimati" : "Pacific/Pago_Pago"
        let zone = try #require(east ? TimeZone(identifier: "Pacific/Kiritimati") : TimeZone(identifier: "Pacific/Pago_Pago"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let day = cal.startOfDay(for: Date().addingTimeInterval(30 * 86_400))
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = zone
        fmt.dateFormat = "yyyy-MM-dd"
        let dayText = fmt.string(from: day)
        let offset = east ? "+14:00" : "-11:00"
        let wall = east ? "00:30:00" : "23:30:00"
        var input = GCalEventInput()
        input.summary = "Standup"
        input.startDateTime = "\(dayText)T\(wall)\(offset)"
        input.startTimeZone = zoneName
        input.endDateTime = "\(dayText)T\(east ? "01:30:00" : "23:45:00")\(offset)"
        input.endTimeZone = zoneName
        input.recurrence = ["RRULE:FREQ=WEEKLY"]

        let recurrence = provider.toGraphEventJSON(input)["recurrence"] as? [String: Any]

        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let weekday = names[cal.component(.weekday, from: day) - 1]
        let days = (recurrence?["pattern"] as? [String: Any])?["daysOfWeek"] as? [String]
        #expect(days == [weekday], "the series recurs on \(days ?? []), its start is a \(weekday) in \(zoneName)")
        #expect((recurrence?["range"] as? [String: Any])?["startDate"] as? String == dayText)
    }

    @Test("parseRRULEToGraphRecurrence: FREQ=MONTHLY maps to absoluteMonthly with dayOfMonth from DTSTART")
    func parseRRULEMonthlyAbsolute() async {
        // "monthly" is NOT a valid Graph pattern type — must be absoluteMonthly
        // (with dayOfMonth) or relativeMonthly.
        let provider = makeProvider()
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=MONTHLY", eventStart: thursdayStart(), timeZone: .current, startWallTime: nil)
        let pattern = rec["pattern"] as? [String: Any]
        #expect(pattern?["type"] as? String == "absoluteMonthly")
        #expect(pattern?["dayOfMonth"] as? Int == 14)
    }

    @Test("parseRRULEToGraphRecurrence: FREQ=MONTHLY;BYMONTHDAY=15 uses the explicit dayOfMonth")
    func parseRRULEMonthlyByMonthDay() async {
        let provider = makeProvider()
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=MONTHLY;BYMONTHDAY=15", eventStart: thursdayStart(), timeZone: .current, startWallTime: nil)
        let pattern = rec["pattern"] as? [String: Any]
        #expect(pattern?["type"] as? String == "absoluteMonthly")
        #expect(pattern?["dayOfMonth"] as? Int == 15)
    }

    @Test("parseRRULEToGraphRecurrence: FREQ=MONTHLY;BYDAY=2FR maps to relativeMonthly with index")
    func parseRRULEMonthlyRelative() async {
        let provider = makeProvider()
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=MONTHLY;BYDAY=2FR", eventStart: thursdayStart(), timeZone: .current, startWallTime: nil)
        let pattern = rec["pattern"] as? [String: Any]
        #expect(pattern?["type"] as? String == "relativeMonthly")
        #expect(pattern?["daysOfWeek"] as? [String] == ["friday"])
        #expect(pattern?["index"] as? String == "second")
    }

    @Test("parseRRULEToGraphRecurrence: FREQ=YEARLY maps to absoluteYearly with month + dayOfMonth from DTSTART")
    func parseRRULEYearlyAbsolute() async {
        // "yearly" is NOT a valid Graph pattern type — must be absoluteYearly
        // (month + dayOfMonth) or relativeYearly.
        let provider = makeProvider()
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=YEARLY", eventStart: thursdayStart(), timeZone: .current, startWallTime: nil)
        let pattern = rec["pattern"] as? [String: Any]
        #expect(pattern?["type"] as? String == "absoluteYearly")
        #expect(pattern?["dayOfMonth"] as? Int == 14)
        #expect(pattern?["month"] as? Int == 5)
    }

    @Test("toGraphEventJSON injects the required recurrenceRange.startDate from the event start")
    func toGraphEventJSONInjectsStartDate() async {
        // MS Graph requires recurrenceRange.startDate for EVERY range type.
        // parseRRULEToGraphRecurrence can't know it (RRULE has no DTSTART), so
        // toGraphEventJSON must inject it from the event's own start.
        let provider = makeProvider()
        var input = GCalEventInput()
        input.summary = "Weekly sync"
        input.startDateTime = "2026-04-08T17:00:00-07:00"
        input.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=WE"]
        let json = provider.toGraphEventJSON(input)
        let rec = json["recurrence"] as? [String: Any]
        let range = rec?["range"] as? [String: Any]
        #expect(range?["startDate"] as? String == "2026-04-08", "startDate must be the date part of the event start")
    }

    @Test("toGraphEventJSON injects startDate from an all-day startDate field too")
    func toGraphEventJSONInjectsStartDateAllDay() async {
        let provider = makeProvider()
        var input = GCalEventInput()
        input.summary = "All-day series"
        input.startDate = "2026-04-08"
        input.recurrence = ["RRULE:FREQ=WEEKLY"]
        let json = provider.toGraphEventJSON(input)
        let rec = json["recurrence"] as? [String: Any]
        let range = rec?["range"] as? [String: Any]
        #expect(range?["startDate"] as? String == "2026-04-08")
    }

    // MARK: - R12-T5 — a retried calendar create must not duplicate the event

    /// INVARIANT (system property): **a queued calendar create that is retried
    /// produces at most ONE event on the user's calendar.** Not "the payload has
    /// a field named transactionId" — the property is that the create the
    /// provider issues carries a client-supplied key derived from the queue's own
    /// DURABLE pre-generated event id, so the server can recognise the retry as
    /// the same intent.
    ///
    /// Why this became reachable: `AccountManagerCalendarQueue` classifies
    /// `408 Request Timeout` as INDETERMINATE, so the op is requeued rather than
    /// retired (retiring it would drop the user's intention on "we could not
    /// determine the answer"). If Graph committed the POST and then answered 408,
    /// a plain non-idempotent `POST /events` produced a SECOND event and a second
    /// round of invitations to every attendee. Both are authoritative server
    /// objects; sync never converges them.
    ///
    /// ⚠️ TWO-SIDED, and the second half is the one that keeps this honest: a
    /// create with NO pre-generated id must carry NO key, or two genuinely
    /// distinct user creates could be collapsed into one by the server — the
    /// mirror image (a dropped intention wearing an idempotency hat).
    @Test("Exchange create carries the durable pre-generated id as Graph's transactionId, so a retried create cannot duplicate the event")
    func createEventCarriesIdempotencyKey() async {
        let provider = makeProvider()
        var input = GCalEventInput()
        input.summary = "Quarterly review"
        input.startDateTime = "2026-04-08T17:00:00-07:00"
        input.endDateTime = "2026-04-08T18:00:00-07:00"
        // Exactly what `AccountManagerCalendarQueue` stamps onto the input:
        // `if let pregenId = op.eventId { input.id = pregenId }`, where
        // `op.eventId` is the durable id generated when the op was queued.
        input.id = PendingCalendarOperation.generateGoogleEventId(from: UUID().uuidString)

        let json = provider.createEventJSON(input)
        #expect(json["transactionId"] as? String == input.id,
                "the Graph create carries no client-supplied idempotency key, so a retry after a committed-then-408 POST creates a SECOND event and re-invites every attendee — and the queue now retries 408 by design")

        // NEGATIVE CASE — no durable id, no key.
        var anonymous = GCalEventInput()
        anonymous.summary = "Ad-hoc"
        anonymous.startDateTime = "2026-04-08T17:00:00-07:00"
        let anonJSON = provider.createEventJSON(anonymous)
        #expect(anonJSON["transactionId"] == nil,
                "a create with no durable pre-generated id must not invent a key — two genuinely distinct user creates would be deduped into one by the server")

        // ⚠️ SIBLING PARITY (`feedback_half_port_drops_the_guard`): Google's
        // create is idempotent by a DIFFERENT mechanism — the client-supplied
        // event `id` itself, which the server 409s on duplicate and the drain
        // catches as success. Pinned here so a future change to
        // `GCalEventInput.toJSON()` that drops `id` cannot silently un-protect
        // the Google path while this test keeps passing for Exchange.
        #expect(input.toJSON()["id"] as? String == input.id,
                "Google's create relies on the client-supplied event id being in the body — dropping it makes the Google retry path non-idempotent too")
    }

    // MARK: - toGCalEvent recurrence reconstruction (Graph pattern → RFC 5545 RRULE)

    @Test("toGCalEvent maps Graph absoluteMonthly → FREQ=MONTHLY;BYMONTHDAY (not invalid FREQ=ABSOLUTEMONTHLY)")
    func toGCalEventAbsoluteMonthly() async throws {
        // Regression: the old code did FREQ=\(type.uppercased()) → "FREQ=ABSOLUTEMONTHLY",
        // an invalid RRULE that round-trips to `default → daily` on split.
        let event = try decodeMSEvent("""
        {"id": "m1", "subject": "Monthly report",
         "recurrence": {"pattern": {"type": "absoluteMonthly", "interval": 1, "dayOfMonth": 15},
                        "range": {"type": "noEnd"}}}
        """)
        let provider = makeProvider()
        let gcal = await provider.toGCalEvent(event)
        #expect(gcal.recurrence == ["RRULE:FREQ=MONTHLY;BYMONTHDAY=15"])
    }

    @Test("toGCalEvent maps Graph relativeMonthly → FREQ=MONTHLY;BYDAY;BYSETPOS (preserves the index)")
    func toGCalEventRelativeMonthly() async throws {
        // "2nd Friday of every month" — the `index` field must survive as BYSETPOS,
        // else split downgrades it to "every Friday" / "first Friday".
        let event = try decodeMSEvent("""
        {"id": "m1", "subject": "2nd Friday sync",
         "recurrence": {"pattern": {"type": "relativeMonthly", "interval": 1,
                        "daysOfWeek": ["friday"], "index": "second"},
                        "range": {"type": "noEnd"}}}
        """)
        let provider = makeProvider()
        let gcal = await provider.toGCalEvent(event)
        #expect(gcal.recurrence == ["RRULE:FREQ=MONTHLY;BYDAY=FR;BYSETPOS=2"])
    }

    @Test("toGCalEvent maps Graph absoluteYearly → FREQ=YEARLY;BYMONTH;BYMONTHDAY")
    func toGCalEventAbsoluteYearly() async throws {
        let event = try decodeMSEvent("""
        {"id": "m1", "subject": "Anniversary",
         "recurrence": {"pattern": {"type": "absoluteYearly", "interval": 1, "month": 3, "dayOfMonth": 15},
                        "range": {"type": "numbered", "numberOfOccurrences": 5}}}
        """)
        let provider = makeProvider()
        let gcal = await provider.toGCalEvent(event)
        #expect(gcal.recurrence == ["RRULE:FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=15;COUNT=5"])
    }

    @Test("toGCalEvent recurrence round-trips back through parseRRULEToGraphRecurrence")
    func toGCalEventRoundTrip() async throws {
        // The RRULE toGCalEvent emits must be re-parseable to the SAME Graph
        // pattern type — splitSeries reads master.recurrence then re-parses it.
        let event = try decodeMSEvent("""
        {"id": "m1", "subject": "x",
         "recurrence": {"pattern": {"type": "relativeMonthly", "interval": 2,
                        "daysOfWeek": ["monday"], "index": "last"},
                        "range": {"type": "noEnd"}}}
        """)
        let provider = makeProvider()
        let rrule = (await provider.toGCalEvent(event)).recurrence!.first!
        let regraph = provider.parseRRULEToGraphRecurrence(rrule, eventStart: nil, timeZone: .current, startWallTime: nil)
        let pattern = regraph["pattern"] as? [String: Any]
        #expect(pattern?["type"] as? String == "relativeMonthly")
        #expect(pattern?["daysOfWeek"] as? [String] == ["monday"])
        #expect(pattern?["index"] as? String == "last")
        #expect(pattern?["interval"] as? Int == 2)
    }

    @Test("graphNaiveDateTime strips RFC 3339 offsets / Z to leave the naive wall-time")
    func graphNaiveDateTime() {
        // Regression: when the dateTime carried an offset alongside our
        // `timeZone` field, Outlook web double-converted and rendered the
        // event on the wrong day. Graph's spec is naive-only.
        #expect(ExchangeCalendarProvider.graphNaiveDateTime("2026-05-15T20:00:00-0700") == "2026-05-15T20:00:00")
        #expect(ExchangeCalendarProvider.graphNaiveDateTime("2026-05-15T20:00:00-07:00") == "2026-05-15T20:00:00")
        #expect(ExchangeCalendarProvider.graphNaiveDateTime("2026-05-16T03:00:00Z") == "2026-05-16T03:00:00")
        #expect(ExchangeCalendarProvider.graphNaiveDateTime("2026-05-15T20:00:00+0530") == "2026-05-15T20:00:00")
        // Already naive → unchanged.
        #expect(ExchangeCalendarProvider.graphNaiveDateTime("2026-05-15T20:00:00") == "2026-05-15T20:00:00")
        // The `-` in the date portion must NOT be mistaken for an offset.
        #expect(ExchangeCalendarProvider.graphNaiveDateTime("2026-05-15T20:00:00.123-0700") == "2026-05-15T20:00:00.123")
        // Any other form keeps its wall time as written: the tools hand every time they
        // read over with seconds and its label's offset.
        #expect(ExchangeCalendarProvider.graphNaiveDateTime("2099-05-15T20:00") == "2099-05-15T20:00")
        #expect(ExchangeCalendarProvider.graphNaiveDateTime("2099-05-15T20:00Z") == "2099-05-15T20:00")
        #expect(ExchangeCalendarProvider.graphNaiveDateTime("2099-05-15T2000") == "2099-05-15T2000")
        #expect(ExchangeCalendarProvider.graphNaiveDateTime("2099-05-15T20") == "2099-05-15T20")
    }

    /// A series' range date follows its start even when the start is in no form
    /// the wall-time reader knows: such a start is dated as written, so moving the
    /// series to another day still moves its range rather than leaving the old date.
    @Test("a start in no known wall-time form is dated as written")
    func dayOfAnUnreadableStartIsItsWrittenDate() {
        #expect(ExchangeCalendarProvider.day(nil, "2099-05-15T9:00", in: "UTC") == "2099-05-15")
        #expect(ExchangeCalendarProvider.day(nil, "2099-05-15T2000", in: nil) == "2099-05-15")
        #expect(ExchangeCalendarProvider.day("2099-05-15", nil, in: nil) == "2099-05-15")
    }

    /// Two Windows zone names nineteen hours apart, so whatever the device's zone, at least one of
    /// them is not it and a read in the device's zone instead shows.
    static let windowsZones: [(windows: String, iana: String, wall: String)] = [
        ("Tokyo Standard Time", "Asia/Tokyo", "2099-07-15T03:00:00"),
        ("Hawaiian Standard Time", "Pacific/Honolulu", "2099-07-15T21:00:00"),
    ]

    @Test("an event Graph returns in a Windows zone is read at that zone's instant")
    func windowsZoneIsReadAtItsInstant() async throws {
        let provider = makeProvider()
        var differing = 0
        for zone in Self.windowsZones {
            let event = try decodeMSEvent("""
            {"id": "e1", "subject": "Planning",
             "start": {"dateTime": "\(zone.wall).0000000", "timeZone": "\(zone.windows)"},
             "end": {"dateTime": "\(zone.wall).0000000", "timeZone": "\(zone.windows)"}}
            """)
            let gcal = await provider.toGCalEvent(event)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let ianaZone = try #require(TimeZone(identifier: zone.iana))
            formatter.timeZone = ianaZone
            let expected = try #require(formatter.date(from: zone.wall))
            #expect(gcal.start?.dateTime.flatMap { Date.fromISO8601($0) } == expected, "\(zone.windows)")
            if ianaZone.secondsFromGMT(for: expected) != TimeZone.current.secondsFromGMT(for: expected) { differing += 1 }
        }
        #expect(differing > 0, "non-vacuity: device zone \(TimeZone.current.identifier)")
    }

    @Test("the day of a start in a Windows zone is the day of that zone's instant")
    func dayOfAStartInAWindowsZone() {
        var moved = 0
        for zone in Self.windowsZones {
            let day = ExchangeCalendarProvider.day(nil, zone.wall, in: zone.windows)
            #expect(day == ExchangeCalendarProvider.day(nil, zone.wall, in: zone.iana), "\(zone.windows)")
            // Read in the device's zone instead, the start would be on the day it is written with.
            if day != String(zone.wall.prefix(10)) { moved += 1 }
        }
        #expect(moved > 0, "non-vacuity: device zone \(TimeZone.current.identifier)")
    }
}
