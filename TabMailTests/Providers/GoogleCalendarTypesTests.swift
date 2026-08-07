/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("GCalCalendar Codable")
struct GCalCalendarCodableTests {

    @Test("Decodes full calendar object")
    func decodesFull() throws {
        let json = """
        {
            "id": "primary@gmail.com",
            "summary": "My Calendar",
            "primary": true,
            "accessRole": "owner",
            "backgroundColor": "#4285f4"
        }
        """.data(using: .utf8)!
        let cal = try JSONDecoder().decode(GCalCalendar.self, from: json)
        #expect(cal.id == "primary@gmail.com")
        #expect(cal.summary == "My Calendar")
        #expect(cal.primary == true)
        #expect(cal.accessRole == "owner")
        #expect(cal.backgroundColor == "#4285f4")
    }

    @Test("Decodes with only required field")
    func decodesMinimal() throws {
        let json = """
        {"id": "cal123"}
        """.data(using: .utf8)!
        let cal = try JSONDecoder().decode(GCalCalendar.self, from: json)
        #expect(cal.id == "cal123")
        #expect(cal.summary == nil)
        #expect(cal.primary == nil)
        #expect(cal.accessRole == nil)
        #expect(cal.backgroundColor == nil)
    }

    @Test("primary false decodes correctly")
    func primaryFalse() throws {
        let json = """
        {"id": "x", "primary": false}
        """.data(using: .utf8)!
        let cal = try JSONDecoder().decode(GCalCalendar.self, from: json)
        #expect(cal.primary == false)
    }
}

@Suite("GCalCalendarListResponse Codable")
struct GCalCalendarListResponseCodableTests {

    @Test("Decodes list with items and nextPageToken")
    func decodesListWithToken() throws {
        let json = """
        {
            "items": [
                {"id": "cal1", "summary": "Work"},
                {"id": "cal2", "summary": "Personal"}
            ],
            "nextPageToken": "abc123"
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(GCalCalendarListResponse.self, from: json)
        #expect(response.items?.count == 2)
        #expect(response.items?[0].id == "cal1")
        #expect(response.nextPageToken == "abc123")
    }

    @Test("Decodes empty response")
    func decodesEmpty() throws {
        let json = "{}".data(using: .utf8)!
        let response = try JSONDecoder().decode(GCalCalendarListResponse.self, from: json)
        #expect(response.items == nil)
        #expect(response.nextPageToken == nil)
    }
}

@Suite("GCalDateTime Codable")
struct GCalDateTimeCodableTests {

    @Test("Decodes dateTime for timed event")
    func decodesDateTime() throws {
        let json = """
        {"dateTime": "2024-03-15T10:00:00-07:00", "timeZone": "America/Los_Angeles"}
        """.data(using: .utf8)!
        let dt = try JSONDecoder().decode(GCalDateTime.self, from: json)
        #expect(dt.dateTime == "2024-03-15T10:00:00-07:00")
        #expect(dt.date == nil)
        #expect(dt.timeZone == "America/Los_Angeles")
    }

    @Test("Decodes date for all-day event")
    func decodesDateOnly() throws {
        let json = """
        {"date": "2024-03-15"}
        """.data(using: .utf8)!
        let dt = try JSONDecoder().decode(GCalDateTime.self, from: json)
        #expect(dt.date == "2024-03-15")
        #expect(dt.dateTime == nil)
        #expect(dt.timeZone == nil)
    }

    @Test("Decodes empty object")
    func decodesEmptyObject() throws {
        let json = "{}".data(using: .utf8)!
        let dt = try JSONDecoder().decode(GCalDateTime.self, from: json)
        #expect(dt.dateTime == nil)
        #expect(dt.date == nil)
        #expect(dt.timeZone == nil)
    }
}

@Suite("GCalAttendee Codable")
struct GCalAttendeeCodableTests {

    @Test("Decodes full attendee")
    func decodesFull() throws {
        let json = """
        {
            "email": "bob@example.com",
            "displayName": "Bob Smith",
            "responseStatus": "accepted",
            "organizer": true,
            "self": false
        }
        """.data(using: .utf8)!
        let attendee = try JSONDecoder().decode(GCalAttendee.self, from: json)
        #expect(attendee.email == "bob@example.com")
        #expect(attendee.displayName == "Bob Smith")
        #expect(attendee.responseStatus == "accepted")
        #expect(attendee.organizer == true)
        #expect(attendee.`self` == false)
    }

    @Test("Decodes minimal attendee")
    func decodesMinimal() throws {
        let json = """
        {"email": "test@test.com"}
        """.data(using: .utf8)!
        let attendee = try JSONDecoder().decode(GCalAttendee.self, from: json)
        #expect(attendee.email == "test@test.com")
        #expect(attendee.displayName == nil)
        #expect(attendee.responseStatus == nil)
        #expect(attendee.organizer == nil)
        #expect(attendee.`self` == nil)
    }

    @Test("Decodes with needsAction status")
    func needsAction() throws {
        let json = """
        {"email": "x@y.com", "responseStatus": "needsAction"}
        """.data(using: .utf8)!
        let attendee = try JSONDecoder().decode(GCalAttendee.self, from: json)
        #expect(attendee.responseStatus == "needsAction")
    }
}

@Suite("GCalOrganizer Codable")
struct GCalOrganizerCodableTests {

    @Test("Decodes full organizer")
    func decodesFull() throws {
        let json = """
        {"email": "org@example.com", "displayName": "Org Name", "self": true}
        """.data(using: .utf8)!
        let org = try JSONDecoder().decode(GCalOrganizer.self, from: json)
        #expect(org.email == "org@example.com")
        #expect(org.displayName == "Org Name")
        #expect(org.`self` == true)
    }

    @Test("Decodes empty organizer")
    func decodesEmpty() throws {
        let json = "{}".data(using: .utf8)!
        let org = try JSONDecoder().decode(GCalOrganizer.self, from: json)
        #expect(org.email == nil)
        #expect(org.displayName == nil)
        #expect(org.`self` == nil)
    }
}

@Suite("GCalEvent Codable")
struct GCalEventCodableTests {

    @Test("Decodes full event")
    func decodesFull() throws {
        let json = """
        {
            "id": "evt123",
            "summary": "Team Meeting",
            "location": "Conference Room A",
            "description": "Weekly sync",
            "start": {"dateTime": "2024-03-15T10:00:00Z"},
            "end": {"dateTime": "2024-03-15T11:00:00Z"},
            "attendees": [
                {"email": "alice@test.com", "responseStatus": "accepted"}
            ],
            "organizer": {"email": "org@test.com"},
            "recurrence": ["RRULE:FREQ=WEEKLY"],
            "transparency": "opaque",
            "status": "confirmed",
            "htmlLink": "https://calendar.google.com/event?eid=abc",
            "created": "2024-03-01T08:00:00Z",
            "updated": "2024-03-10T12:00:00Z"
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(GCalEvent.self, from: json)
        #expect(event.id == "evt123")
        #expect(event.summary == "Team Meeting")
        #expect(event.location == "Conference Room A")
        #expect(event.description == "Weekly sync")
        #expect(event.start?.dateTime == "2024-03-15T10:00:00Z")
        #expect(event.end?.dateTime == "2024-03-15T11:00:00Z")
        #expect(event.attendees?.count == 1)
        #expect(event.attendees?[0].email == "alice@test.com")
        #expect(event.organizer?.email == "org@test.com")
        #expect(event.recurrence == ["RRULE:FREQ=WEEKLY"])
        #expect(event.transparency == "opaque")
        #expect(event.status == "confirmed")
        #expect(event.htmlLink == "https://calendar.google.com/event?eid=abc")
        #expect(event.created == "2024-03-01T08:00:00Z")
        #expect(event.updated == "2024-03-10T12:00:00Z")
    }

    @Test("Decodes minimal event")
    func decodesMinimal() throws {
        let json = "{}".data(using: .utf8)!
        let event = try JSONDecoder().decode(GCalEvent.self, from: json)
        #expect(event.id == nil)
        #expect(event.summary == nil)
        #expect(event.start == nil)
        #expect(event.end == nil)
        #expect(event.attendees == nil)
        #expect(event.organizer == nil)
        #expect(event.recurrence == nil)
        #expect(event.status == nil)
    }

    @Test("All-day event has date not dateTime")
    func allDayEvent() throws {
        let json = """
        {
            "id": "allday1",
            "summary": "Holiday",
            "start": {"date": "2024-12-25"},
            "end": {"date": "2024-12-26"}
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(GCalEvent.self, from: json)
        #expect(event.start?.date == "2024-12-25")
        #expect(event.start?.dateTime == nil)
        #expect(event.isAllDay == true)
    }

    @Test("Cancelled event status")
    func cancelledEvent() throws {
        let json = """
        {"id": "c1", "status": "cancelled"}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(GCalEvent.self, from: json)
        #expect(event.status == "cancelled")
    }

    @Test("isAllDay false for timed event")
    func isAllDayFalseForTimed() throws {
        let json = """
        {"start": {"dateTime": "2024-03-15T10:00:00Z"}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(GCalEvent.self, from: json)
        #expect(event.isAllDay == false)
    }

    @Test("Multiple attendees decode correctly")
    func multipleAttendees() throws {
        let json = """
        {
            "attendees": [
                {"email": "a@b.com", "responseStatus": "accepted"},
                {"email": "c@d.com", "responseStatus": "declined"},
                {"email": "e@f.com", "responseStatus": "tentative"}
            ]
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(GCalEvent.self, from: json)
        #expect(event.attendees?.count == 3)
        #expect(event.attendees?[1].responseStatus == "declined")
    }
}

@Suite("GCalEventListResponse Codable")
struct GCalEventListResponseCodableTests {

    @Test("Decodes event list with pagination token")
    func decodesWithToken() throws {
        let json = """
        {
            "items": [
                {"id": "e1", "summary": "Event 1"},
                {"id": "e2", "summary": "Event 2"}
            ],
            "nextPageToken": "page2token"
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(GCalEventListResponse.self, from: json)
        #expect(response.items?.count == 2)
        #expect(response.items?[0].summary == "Event 1")
        #expect(response.nextPageToken == "page2token")
    }

    @Test("Decodes empty event list")
    func decodesEmpty() throws {
        let json = "{}".data(using: .utf8)!
        let response = try JSONDecoder().decode(GCalEventListResponse.self, from: json)
        #expect(response.items == nil)
        #expect(response.nextPageToken == nil)
    }

    @Test("Decodes with empty items array")
    func emptyItemsArray() throws {
        let json = """
        {"items": []}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(GCalEventListResponse.self, from: json)
        #expect(response.items?.isEmpty == true)
        #expect(response.nextPageToken == nil)
    }
}

// MARK: - selected field

@Suite("GCalCalendar.selected decoding")
struct GCalCalendarSelectedTests {

    @Test("selected: true is preserved")
    func selectedTrue() throws {
        let json = """
        {"id": "cal1", "selected": true}
        """.data(using: .utf8)!
        let cal = try JSONDecoder().decode(GCalCalendar.self, from: json)
        #expect(cal.selected == true)
    }

    @Test("selected: false is preserved")
    func selectedFalse() throws {
        let json = """
        {"id": "cal1", "selected": false}
        """.data(using: .utf8)!
        let cal = try JSONDecoder().decode(GCalCalendar.self, from: json)
        #expect(cal.selected == false)
    }

    @Test("Missing selected field decodes to nil")
    func selectedMissing() throws {
        let json = """
        {"id": "cal1"}
        """.data(using: .utf8)!
        let cal = try JSONDecoder().decode(GCalCalendar.self, from: json)
        #expect(cal.selected == nil)
    }
}

// MARK: - Recurring-series split helpers (calendar_event_edit-v1.5.21+)

@Suite("GoogleCalendarProvider split-RRULE helpers")
struct GoogleCalendarSplitHelpersTests {

    @Test("replaceOrAppendUntil drops existing UNTIL and appends the new one")
    func replaceUntilExisting() {
        let input = "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20260101T000000Z"
        let out = GoogleCalendarProvider.replaceOrAppendUntil(in: input, untilValue: "20260520T235959Z")
        #expect(out == "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20260520T235959Z")
    }

    @Test("replaceOrAppendUntil strips COUNT and replaces with UNTIL")
    func replaceCountWithUntil() {
        let input = "RRULE:FREQ=WEEKLY;COUNT=10"
        let out = GoogleCalendarProvider.replaceOrAppendUntil(in: input, untilValue: "20260520T235959Z")
        #expect(out == "RRULE:FREQ=WEEKLY;UNTIL=20260520T235959Z")
    }

    @Test("replaceOrAppendUntil appends when no UNTIL/COUNT present")
    func appendUntilWhenAbsent() {
        let input = "RRULE:FREQ=DAILY;INTERVAL=2"
        let out = GoogleCalendarProvider.replaceOrAppendUntil(in: input, untilValue: "20260520T235959Z")
        #expect(out == "RRULE:FREQ=DAILY;INTERVAL=2;UNTIL=20260520T235959Z")
    }

    @Test("stripUntilAndCount removes both UNTIL and COUNT in one pass")
    func stripBoth() {
        let input = "RRULE:FREQ=WEEKLY;UNTIL=20260101T000000Z;COUNT=5;BYDAY=WE"
        let out = GoogleCalendarProvider.stripUntilAndCount(input)
        #expect(out == "RRULE:FREQ=WEEKLY;BYDAY=WE")
    }

    @Test("stripUntilAndCount is case-insensitive on rule names")
    func stripCaseInsensitive() {
        let input = "RRULE:FREQ=WEEKLY;until=20260101T000000Z;Count=5"
        let out = GoogleCalendarProvider.stripUntilAndCount(input)
        #expect(out == "RRULE:FREQ=WEEKLY")
    }

    @Test("googleUntilString (timed event) produces a UTC date-time, 1 second before the naive ISO")
    func googleUntilStringTimedFormat() {
        // RFC 5545: timed master (DTSTART with tz) → UNTIL must be UTC date-time.
        // Naive ISO is interpreted in device-local time, then output in UTC.
        let out = GoogleCalendarProvider.googleUntilString(beforeNaiveISO: "2026-05-20T17:00:00", allDay: false, zone: .current)
        #expect(out != nil)
        guard let out else { return }
        // ICS basic UTC date-time form: yyyyMMddTHHmmssZ — 16 chars, Z-terminated.
        #expect(out.count == 16)
        #expect(out.hasSuffix("Z"))
        #expect(out.contains("T"))
    }

    @Test("googleUntilString (all-day event) produces a bare DATE, the day before — RFC 5545 §3.3.10")
    func googleUntilStringAllDayFormat() {
        // RFC 5545: when DTSTART is VALUE=DATE, UNTIL MUST also be a bare DATE
        // (no time, no Z). Capping an all-day series before its 2026-05-20
        // occurrence means UNTIL=20260519.
        let out = GoogleCalendarProvider.googleUntilString(beforeNaiveISO: "2026-05-20T00:00:00", allDay: true, zone: .current)
        #expect(out == "20260519", "all-day UNTIL must be YYYYMMDD day-before; got \(out ?? "nil")")
        // Date-only recurrence_id form must also parse.
        let out2 = GoogleCalendarProvider.googleUntilString(beforeNaiveISO: "2026-05-20", allDay: true, zone: .current)
        #expect(out2 == "20260519")
        // No 'T', no 'Z' — must NOT be the date-time form.
        if let out { #expect(!out.contains("T") && !out.contains("Z")) }
    }

    @Test("googleUntilString (all-day) day-before crosses month/year boundaries correctly")
    func googleUntilStringAllDayBoundaries() {
        // Calendar-based subtraction (not flat 86400s) must roll month/year
        // boundaries and is DST-correct by Foundation's contract.
        #expect(GoogleCalendarProvider.googleUntilString(beforeNaiveISO: "2026-03-01", allDay: true, zone: .current) == "20260228")
        #expect(GoogleCalendarProvider.googleUntilString(beforeNaiveISO: "2026-01-01", allDay: true, zone: .current) == "20251231")
        // Leap year: 2028 is a leap year, so day before Mar 1 is Feb 29.
        #expect(GoogleCalendarProvider.googleUntilString(beforeNaiveISO: "2028-03-01", allDay: true, zone: .current) == "20280229")
    }

    @Test("mergeMasterAndPatch honors patch.recurrence when LLM wants to change the pattern")
    func mergeMasterAndPatchHonorsPatchRecurrence() {
        // Regression: an earlier version always used the caller-supplied
        // newRecurrence (which is the master's RRULE stripped of UNTIL/COUNT),
        // silently dropping any patch.recurrence the LLM provided. That made
        // "starting next week, make it bi-weekly" impossible on iOS while
        // TB's bridge correctly applied it.
        let master = GCalEvent(
            id: "m1", summary: "Daily", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2026-05-20T17:00:00-07:00", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2026-05-20T18:00:00-07:00", date: nil, timeZone: nil),
            attendees: nil, organizer: nil,
            recurrence: ["RRULE:FREQ=DAILY"], transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil
        )
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=MO"]
        let out = GoogleCalendarProvider.mergeMasterAndPatch(
            master: master, patch: patch,
            newStartNaiveISO: "2026-05-25T17:00:00",
            newStartZone: .current,
            newRecurrence: ["RRULE:FREQ=DAILY"]  // default would be daily
        )
        #expect(out.recurrence == ["RRULE:FREQ=WEEKLY;BYDAY=MO"])
    }

    @Test("mergeMasterAndPatch preserves all-day-ness — does NOT convert an all-day series to timed")
    func mergeMasterAndPatchAllDayPreserved() {
        // Regression: mergeMasterAndPatch always emitted startDateTime/endDateTime,
        // silently converting an all-day master's split into a timed event. An
        // all-day master must yield an all-day new series (date-only start/end).
        let master = GCalEvent(
            id: "m1", summary: "Daily standup week", location: nil, description: nil,
            // All-day: `start.date` set, `dateTime` nil. Google's all-day end is
            // exclusive, so a 1-day event is start=05-20, end=05-21.
            start: GCalDateTime(dateTime: nil, date: "2026-05-20", timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: "2026-05-21", timeZone: nil),
            attendees: nil, organizer: nil,
            recurrence: ["RRULE:FREQ=WEEKLY"], transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil
        )
        #expect(master.isAllDay, "test fixture sanity: master must be all-day")
        let out = GoogleCalendarProvider.mergeMasterAndPatch(
            master: master, patch: GCalEventInput(),
            newStartNaiveISO: "2026-05-27",   // all-day recurrence_id form
            newStartZone: .current,
            newRecurrence: ["RRULE:FREQ=WEEKLY"]
        )
        // Must emit date-only fields, NOT date-time.
        #expect(out.startDate == "2026-05-27", "expected all-day startDate, got startDate=\(out.startDate ?? "nil") startDateTime=\(out.startDateTime ?? "nil")")
        #expect(out.endDate == "2026-05-28", "1-day all-day event → end is exclusive next day")
        #expect(out.startDateTime == nil, "must NOT emit a timed startDateTime for an all-day master")
        #expect(out.endDateTime == nil)
    }

    @Test("mergeMasterAndPatch sets a named start/end timeZone for the timed new series")
    func mergeMasterAndPatchSetsTimeZone() {
        // Regression: the timed branch emitted startDateTime/endDateTime but NO
        // startTimeZone/endTimeZone. Google REQUIRES a named timeZone when
        // creating a RECURRING event — without it the split's new-series POST
        // is rejected with HTTP 400 "Missing time zone definition for start
        // time". Inherit the master's IANA zone.
        let master = GCalEvent(
            id: "m1", summary: "Weekly sync", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2026-05-14T22:00:00-07:00", date: nil, timeZone: "America/Vancouver"),
            end: GCalDateTime(dateTime: "2026-05-14T22:30:00-07:00", date: nil, timeZone: "America/Vancouver"),
            attendees: nil, organizer: nil,
            recurrence: ["RRULE:FREQ=WEEKLY"], transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil
        )
        let out = GoogleCalendarProvider.mergeMasterAndPatch(
            master: master, patch: GCalEventInput(),
            newStartNaiveISO: "2026-05-21T22:00:00",
            newStartZone: .current,
            newRecurrence: ["RRULE:FREQ=WEEKLY"]
        )
        #expect(out.startTimeZone == "America/Vancouver")
        #expect(out.endTimeZone == "America/Vancouver")
        #expect(out.startDateTime != nil)

        // When the master carries no timeZone, fall back to the device zone
        // (still a named identifier, never nil — Google would reject nil).
        let noTzMaster = GCalEvent(
            id: "m2", summary: "x", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2026-05-14T22:00:00-07:00", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2026-05-14T22:30:00-07:00", date: nil, timeZone: nil),
            attendees: nil, organizer: nil,
            recurrence: ["RRULE:FREQ=WEEKLY"], transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil
        )
        let out2 = GoogleCalendarProvider.mergeMasterAndPatch(
            master: noTzMaster, patch: GCalEventInput(),
            newStartNaiveISO: "2026-05-21T22:00:00",
            newStartZone: .current,
            newRecurrence: ["RRULE:FREQ=WEEKLY"]
        )
        #expect(out2.startTimeZone == TimeZone.current.identifier)
        #expect(out2.endTimeZone == TimeZone.current.identifier)
    }

    @Test("mergeMasterAndPatch falls back to newRecurrence when patch.recurrence is nil")
    func mergeMasterAndPatchFallsBackToDefault() {
        let master = GCalEvent(
            id: "m1", summary: "Daily", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2026-05-20T17:00:00-07:00", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2026-05-20T18:00:00-07:00", date: nil, timeZone: nil),
            attendees: nil, organizer: nil,
            recurrence: ["RRULE:FREQ=DAILY"], transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil
        )
        let out = GoogleCalendarProvider.mergeMasterAndPatch(
            master: master, patch: GCalEventInput(),
            newStartNaiveISO: "2026-05-25T17:00:00",
            newStartZone: .current,
            newRecurrence: ["RRULE:FREQ=DAILY"]
        )
        #expect(out.recurrence == ["RRULE:FREQ=DAILY"])
    }

    @Test("googleUntilString returns nil for malformed input — no silent 'now' fallback")
    func googleUntilStringMalformedInput() {
        // Regression: the helper used to fall back to Date() if parsing failed,
        // producing a UNTIL value that capped the series at "now". Caller couldn't
        // tell parse-success from silent-default. Now we return nil so the caller
        // surfaces a clear error to the LLM/user.
        #expect(GoogleCalendarProvider.googleUntilString(beforeNaiveISO: "garbage", allDay: false, zone: .current) == nil)
        #expect(GoogleCalendarProvider.googleUntilString(beforeNaiveISO: "", allDay: false, zone: .current) == nil)
        #expect(GoogleCalendarProvider.googleUntilString(beforeNaiveISO: "2026-13-99T99:99:99", allDay: true, zone: .current) == nil)
    }

    @Test("deterministicSplitEventId is stable across calls and varies with inputs")
    func deterministicSplitEventId() {
        let a1 = GoogleCalendarProvider.deterministicSplitEventId(masterId: "evt-123", recurrenceId: "2026-05-20T17:00:00")
        let a2 = GoogleCalendarProvider.deterministicSplitEventId(masterId: "evt-123", recurrenceId: "2026-05-20T17:00:00")
        // Same inputs → same id (this is what makes split retries idempotent).
        #expect(a1 == a2)
        // Different master or different recurrence point → different id.
        #expect(a1 != GoogleCalendarProvider.deterministicSplitEventId(masterId: "evt-999", recurrenceId: "2026-05-20T17:00:00"))
        #expect(a1 != GoogleCalendarProvider.deterministicSplitEventId(masterId: "evt-123", recurrenceId: "2026-05-27T17:00:00"))
        // 64 lowercase hex chars — valid Google base32hex id, CalDAV filename, Graph transactionId.
        #expect(a1.count == 64)
        #expect(a1.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}
