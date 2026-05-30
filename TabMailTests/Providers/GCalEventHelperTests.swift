/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("GCalEvent Computed Properties")
struct GCalEventHelperTests {

    @Test("startDate parses RFC3339 dateTime")
    func startDateFromDateTime() {
        let event = GCalEvent(
            id: "e1", summary: nil, location: nil, description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.startDate != nil)
    }

    @Test("startDate parses date-only for all-day")
    func startDateFromDateOnly() {
        let event = GCalEvent(
            id: "e1", summary: nil, location: nil, description: nil,
            start: GCalDateTime(dateTime: nil, date: "2024-03-15", timeZone: nil),
            end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.startDate != nil)
    }

    @Test("startDate nil when no start")
    func startDateNil() {
        let event = GCalEvent(
            id: "e1", summary: nil, location: nil, description: nil,
            start: nil,
            end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.startDate == nil)
    }

    @Test("endDate parses RFC3339")
    func endDateFromDateTime() {
        let event = GCalEvent(
            id: "e1", summary: nil, location: nil, description: nil,
            start: nil,
            end: GCalDateTime(dateTime: "2024-03-15T11:00:00Z", date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.endDate != nil)
    }

    @Test("endDate parses date-only")
    func endDateFromDateOnly() {
        let event = GCalEvent(
            id: "e1", summary: nil, location: nil, description: nil,
            start: nil,
            end: GCalDateTime(dateTime: nil, date: "2024-03-16", timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.endDate != nil)
    }

    @Test("isAllDay true when start has date only")
    func isAllDayTrue() {
        let event = GCalEvent(
            id: "e1", summary: nil, location: nil, description: nil,
            start: GCalDateTime(dateTime: nil, date: "2024-03-15", timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: "2024-03-16", timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.isAllDay == true)
    }

    @Test("isAllDay false when start has dateTime")
    func isAllDayFalse() {
        let event = GCalEvent(
            id: "e1", summary: nil, location: nil, description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.isAllDay == false)
    }

    @Test("isAllDay false when no start")
    func isAllDayNoStart() {
        let event = GCalEvent(
            id: "e1", summary: nil, location: nil, description: nil,
            start: nil,
            end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.isAllDay == false)
    }

    @Test("Decodes from JSON with dateTime")
    func decodesFromJSON() throws {
        let json = """
        {
            "id": "abc123",
            "summary": "Meeting",
            "location": "Room 1",
            "start": { "dateTime": "2024-03-15T10:00:00Z" },
            "end": { "dateTime": "2024-03-15T11:00:00Z" },
            "transparency": "transparent",
            "htmlLink": "https://calendar.google.com/event/abc123"
        }
        """
        let event = try JSONDecoder().decode(GCalEvent.self, from: json.data(using: .utf8)!)
        #expect(event.id == "abc123")
        #expect(event.summary == "Meeting")
        #expect(event.location == "Room 1")
        #expect(event.transparency == "transparent")
        #expect(event.htmlLink == "https://calendar.google.com/event/abc123")
        #expect(event.isAllDay == false)
    }

    @Test("Decodes from JSON with all-day date")
    func decodesAllDayJSON() throws {
        let json = """
        {
            "id": "allday1",
            "summary": "Holiday",
            "start": { "date": "2024-12-25" },
            "end": { "date": "2024-12-26" }
        }
        """
        let event = try JSONDecoder().decode(GCalEvent.self, from: json.data(using: .utf8)!)
        #expect(event.isAllDay == true)
    }

    @Test("Decodes with attendees")
    func decodesAttendees() throws {
        let json = """
        {
            "id": "evt1",
            "start": { "dateTime": "2024-03-15T10:00:00Z" },
            "attendees": [
                { "email": "alice@test.com", "displayName": "Alice", "responseStatus": "accepted" },
                { "email": "bob@test.com", "responseStatus": "needsAction" }
            ]
        }
        """
        let event = try JSONDecoder().decode(GCalEvent.self, from: json.data(using: .utf8)!)
        #expect(event.attendees?.count == 2)
        #expect(event.attendees?[0].email == "alice@test.com")
        #expect(event.attendees?[0].displayName == "Alice")
        #expect(event.attendees?[0].responseStatus == "accepted")
        #expect(event.attendees?[1].displayName == nil)
    }

    @Test("Decodes with organizer")
    func decodesOrganizer() throws {
        let json = """
        {
            "id": "evt1",
            "start": { "dateTime": "2024-03-15T10:00:00Z" },
            "organizer": { "email": "boss@test.com", "displayName": "Boss" }
        }
        """
        let event = try JSONDecoder().decode(GCalEvent.self, from: json.data(using: .utf8)!)
        #expect(event.organizer?.email == "boss@test.com")
        #expect(event.organizer?.displayName == "Boss")
    }

    @Test("Decodes with recurrence")
    func decodesRecurrence() throws {
        let json = """
        {
            "id": "evt1",
            "start": { "dateTime": "2024-03-15T10:00:00Z" },
            "recurrence": ["RRULE:FREQ=WEEKLY;COUNT=10"]
        }
        """
        let event = try JSONDecoder().decode(GCalEvent.self, from: json.data(using: .utf8)!)
        #expect(event.recurrence?.count == 1)
        #expect(event.recurrence?[0] == "RRULE:FREQ=WEEKLY;COUNT=10")
    }
}
