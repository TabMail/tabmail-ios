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

    @Test("All three cases are distinguishable")
    func allCasesDistinguishable() {
        let cases: [ExchangeCalendarError] = [
            .missingScope,
            .httpError(404, nil),
            .eventNotFound,
        ]

        for (i, error) in cases.enumerated() {
            switch error {
            case .missingScope:
                #expect(i == 0)
            case .httpError:
                #expect(i == 1)
            case .eventNotFound:
                #expect(i == 2)
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
        ExchangeCalendarProvider(accessToken: { _ in "test-token" })
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
}

// MARK: - Recurring-event reference-conformance (verified against MS Graph + RFC 5545)

@Suite("ExchangeCalendarProvider recurring-event Graph conformance")
struct ExchangeCalendarRecurringTests {

    private func makeProvider() -> ExchangeCalendarProvider {
        ExchangeCalendarProvider(accessToken: { _ in "test-token" })
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
        #expect(ExchangeCalendarProvider.graphEndDateBefore(naiveISO: "2026-05-20T17:00:00", allDay: false) == "2026-05-19")
        // Date-only recurrence_id form also parses.
        #expect(ExchangeCalendarProvider.graphEndDateBefore(naiveISO: "2026-05-20", allDay: true) == "2026-05-19")
        // Malformed input → nil (caller surfaces an error rather than guessing).
        #expect(ExchangeCalendarProvider.graphEndDateBefore(naiveISO: "garbage", allDay: false) == nil)
    }

    @Test("graphEndDateBefore rolls month/year boundaries (Calendar arithmetic, not flat 86400s)")
    func graphEndDateBeforeBoundaries() {
        #expect(ExchangeCalendarProvider.graphEndDateBefore(naiveISO: "2026-03-01T09:00:00", allDay: false) == "2026-02-28")
        #expect(ExchangeCalendarProvider.graphEndDateBefore(naiveISO: "2026-01-01T09:00:00", allDay: false) == "2025-12-31")
        // Leap year.
        #expect(ExchangeCalendarProvider.graphEndDateBefore(naiveISO: "2028-03-01T09:00:00", allDay: false) == "2028-02-29")
    }

    /// 2026-05-14 is a Thursday — used to verify DTSTART-implied fields.
    private func thursdayStart() -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f.date(from: "2026-05-14T22:00:00")!
    }

    @Test("parseRRULEToGraphRecurrence converts a timestamp UNTIL to a YYYY-MM-DD endDate")
    func parseRRULETimestampUntil() async {
        let provider = makeProvider()
        // googleUntilString emits the 16-char UTC form; the old parser only
        // handled the bare 8-char date and left this malformed.
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20260527T235959Z", eventStart: nil)
        let range = rec["range"] as? [String: Any]
        #expect(range?["type"] as? String == "endDate")
        #expect(range?["endDate"] as? String == "2026-05-27")
    }

    @Test("parseRRULEToGraphRecurrence handles the bare 8-char UNTIL date too")
    func parseRRULEBareDateUntil() async {
        let provider = makeProvider()
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=DAILY;UNTIL=20260527", eventStart: nil)
        let range = rec["range"] as? [String: Any]
        #expect(range?["endDate"] as? String == "2026-05-27")
    }

    @Test("parseRRULEToGraphRecurrence leaves range as noEnd for an open-ended rule")
    func parseRRULENoEnd() async {
        let provider = makeProvider()
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=WEEKLY;BYDAY=MO,WE", eventStart: nil)
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
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=WEEKLY", eventStart: thursdayStart())
        let pattern = rec["pattern"] as? [String: Any]
        #expect(pattern?["type"] as? String == "weekly")
        #expect(pattern?["daysOfWeek"] as? [String] == ["thursday"])
        #expect(pattern?["firstDayOfWeek"] as? String == "sunday")
    }

    @Test("parseRRULEToGraphRecurrence: FREQ=MONTHLY maps to absoluteMonthly with dayOfMonth from DTSTART")
    func parseRRULEMonthlyAbsolute() async {
        // "monthly" is NOT a valid Graph pattern type — must be absoluteMonthly
        // (with dayOfMonth) or relativeMonthly.
        let provider = makeProvider()
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=MONTHLY", eventStart: thursdayStart())
        let pattern = rec["pattern"] as? [String: Any]
        #expect(pattern?["type"] as? String == "absoluteMonthly")
        #expect(pattern?["dayOfMonth"] as? Int == 14)
    }

    @Test("parseRRULEToGraphRecurrence: FREQ=MONTHLY;BYMONTHDAY=15 uses the explicit dayOfMonth")
    func parseRRULEMonthlyByMonthDay() async {
        let provider = makeProvider()
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=MONTHLY;BYMONTHDAY=15", eventStart: thursdayStart())
        let pattern = rec["pattern"] as? [String: Any]
        #expect(pattern?["type"] as? String == "absoluteMonthly")
        #expect(pattern?["dayOfMonth"] as? Int == 15)
    }

    @Test("parseRRULEToGraphRecurrence: FREQ=MONTHLY;BYDAY=2FR maps to relativeMonthly with index")
    func parseRRULEMonthlyRelative() async {
        let provider = makeProvider()
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=MONTHLY;BYDAY=2FR", eventStart: thursdayStart())
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
        let rec = provider.parseRRULEToGraphRecurrence("RRULE:FREQ=YEARLY", eventStart: thursdayStart())
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
        let regraph = provider.parseRRULEToGraphRecurrence(rrule, eventStart: nil)
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
    }
}
