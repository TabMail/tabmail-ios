/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - GCalEvent Computed Properties

@Suite("GCalEvent Computed Properties")
struct GCalEventComputedTests {

    @Test("isAllDay true when start has date but no dateTime")
    func isAllDayTrue() {
        let event = GCalEvent(
            id: "e1", summary: "Holiday", location: nil, description: nil,
            start: GCalDateTime(dateTime: nil, date: "2024-12-25", timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: "2024-12-26", timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.isAllDay == true)
    }

    @Test("isAllDay false when start has dateTime")
    func isAllDayFalse() {
        let event = GCalEvent(
            id: "e1", summary: "Meeting", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2024-06-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-06-15T11:00:00Z", date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.isAllDay == false)
    }

    @Test("startDate parses RFC3339 dateTime")
    func startDateFromDateTime() {
        let event = GCalEvent(
            id: "e1", summary: nil, location: nil, description: nil,
            start: GCalDateTime(dateTime: "2024-06-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.startDate != nil)
    }

    @Test("startDate parses date-only for all-day events")
    func startDateFromDate() {
        let event = GCalEvent(
            id: "e1", summary: nil, location: nil, description: nil,
            start: GCalDateTime(dateTime: nil, date: "2024-12-25", timeZone: nil),
            end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.startDate != nil)
    }

    @Test("startDate nil when no start")
    func startDateNil() {
        let event = GCalEvent(
            id: "e1", summary: nil, location: nil, description: nil,
            start: nil, end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.startDate == nil)
    }

    @Test("endDate parses correctly")
    func endDate() {
        let event = GCalEvent(
            id: "e1", summary: nil, location: nil, description: nil,
            start: nil,
            end: GCalDateTime(dateTime: "2024-06-15T11:00:00Z", date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(event.endDate != nil)
    }
}

// MARK: - GCalEvent Codable

@Suite("GCalEvent Codable Extended")
struct GCalEventCodableExtendedTests {

    @Test("GCalEvent decodes from JSON")
    func decodesFromJSON() throws {
        let json = """
        {
            "id": "abc123",
            "summary": "Team Standup",
            "location": "Room 42",
            "description": "Daily sync",
            "start": {"dateTime": "2024-06-15T10:00:00Z"},
            "end": {"dateTime": "2024-06-15T10:30:00Z"},
            "transparency": "opaque",
            "status": "confirmed",
            "htmlLink": "https://calendar.google.com/event?eid=abc",
            "recurrence": ["RRULE:FREQ=DAILY"]
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(GCalEvent.self, from: json)
        #expect(event.id == "abc123")
        #expect(event.summary == "Team Standup")
        #expect(event.location == "Room 42")
        #expect(event.description == "Daily sync")
        #expect(event.transparency == "opaque")
        #expect(event.status == "confirmed")
        #expect(event.htmlLink == "https://calendar.google.com/event?eid=abc")
        #expect(event.recurrence == ["RRULE:FREQ=DAILY"])
        #expect(event.startDate != nil)
        #expect(event.endDate != nil)
    }

    @Test("GCalEvent decodes all-day event")
    func decodesAllDay() throws {
        let json = """
        {"id": "day1", "start": {"date": "2024-12-25"}, "end": {"date": "2024-12-26"}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(GCalEvent.self, from: json)
        #expect(event.isAllDay == true)
        #expect(event.startDate != nil)
    }

    @Test("GCalEvent decodes with attendees and organizer")
    func decodesAttendeesAndOrganizer() throws {
        let json = """
        {
            "id": "e1",
            "attendees": [
                {"email": "alice@test.com", "displayName": "Alice", "responseStatus": "accepted"},
                {"email": "bob@test.com", "responseStatus": "needsAction"}
            ],
            "organizer": {"email": "alice@test.com", "displayName": "Alice", "self": true}
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(GCalEvent.self, from: json)
        #expect(event.attendees?.count == 2)
        #expect(event.attendees?[0].email == "alice@test.com")
        #expect(event.attendees?[0].displayName == "Alice")
        #expect(event.attendees?[0].responseStatus == "accepted")
        #expect(event.organizer?.email == "alice@test.com")
    }

    @Test("GCalEvent decodes minimal JSON (all nils)")
    func decodesMinimal() throws {
        let json = "{}".data(using: .utf8)!
        let event = try JSONDecoder().decode(GCalEvent.self, from: json)
        #expect(event.id == nil)
        #expect(event.summary == nil)
        #expect(event.startDate == nil)
        #expect(event.isAllDay == false)
    }

    @Test("GCalEventListResponse decodes with items")
    func listResponseWithItems() throws {
        let json = """
        {"items": [{"id": "e1"}, {"id": "e2"}], "nextPageToken": "token123"}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(GCalEventListResponse.self, from: json)
        #expect(response.items?.count == 2)
        #expect(response.nextPageToken == "token123")
    }

    @Test("GCalEventListResponse decodes empty")
    func listResponseEmpty() throws {
        let json = "{}".data(using: .utf8)!
        let response = try JSONDecoder().decode(GCalEventListResponse.self, from: json)
        #expect(response.items == nil)
        #expect(response.nextPageToken == nil)
    }

    @Test("GCalDateTime Codable round-trip")
    func dateTimeCodable() throws {
        let dt = GCalDateTime(dateTime: "2024-06-15T10:00:00Z", date: nil, timeZone: "America/New_York")
        let data = try JSONEncoder().encode(dt)
        let decoded = try JSONDecoder().decode(GCalDateTime.self, from: data)
        #expect(decoded.dateTime == "2024-06-15T10:00:00Z")
        #expect(decoded.date == nil)
        #expect(decoded.timeZone == "America/New_York")
    }

    @Test("GCalAttendee Codable round-trip")
    func attendeeCodable() throws {
        let json = """
        {"email":"alice@test.com","displayName":"Alice","responseStatus":"accepted","organizer":true,"self":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(GCalAttendee.self, from: json)
        #expect(decoded.email == "alice@test.com")
        #expect(decoded.displayName == "Alice")
        #expect(decoded.responseStatus == "accepted")
        #expect(decoded.organizer == true)
        // Re-encode to verify round-trip
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(GCalAttendee.self, from: reEncoded)
        #expect(reDecoded.email == "alice@test.com")
    }

    @Test("GCalOrganizer Codable round-trip")
    func organizerCodable() throws {
        let json = """
        {"email":"org@test.com","displayName":"Org","self":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(GCalOrganizer.self, from: json)
        #expect(decoded.email == "org@test.com")
        #expect(decoded.displayName == "Org")
        // Re-encode to verify round-trip
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(GCalOrganizer.self, from: reEncoded)
        #expect(reDecoded.email == "org@test.com")
    }
}

// MARK: - GCalEventInput

@Suite("GCalEventInput")
struct GCalEventInputTests {

    @Test("toJSON includes summary and location")
    func toJSONBasicFields() {
        var input = GCalEventInput()
        input.summary = "Meeting"
        input.location = "Room A"
        input.description = "Discuss project"
        let json = input.toJSON()
        #expect(json["summary"] as? String == "Meeting")
        #expect(json["location"] as? String == "Room A")
        #expect(json["description"] as? String == "Discuss project")
    }

    @Test("toJSON includes timed start/end")
    func toJSONTimedEvent() {
        var input = GCalEventInput()
        input.startDateTime = "2024-06-15T10:00:00Z"
        input.startTimeZone = "America/New_York"
        input.endDateTime = "2024-06-15T11:00:00Z"
        input.endTimeZone = "America/New_York"
        let json = input.toJSON()
        let start = json["start"] as? [String: Any]
        #expect(start?["dateTime"] as? String == "2024-06-15T10:00:00Z")
        #expect(start?["timeZone"] as? String == "America/New_York")
        let end = json["end"] as? [String: Any]
        #expect(end?["dateTime"] as? String == "2024-06-15T11:00:00Z")
    }

    @Test("toJSON includes all-day start/end")
    func toJSONAllDayEvent() {
        var input = GCalEventInput()
        input.startDate = "2024-12-25"
        input.endDate = "2024-12-26"
        let json = input.toJSON()
        let start = json["start"] as? [String: Any]
        #expect(start?["date"] as? String == "2024-12-25")
        let end = json["end"] as? [String: Any]
        #expect(end?["date"] as? String == "2024-12-26")
    }

    @Test("toJSON includes attendees")
    func toJSONAttendees() {
        var input = GCalEventInput()
        input.attendees = [
            (email: "alice@test.com", name: "Alice"),
            (email: "bob@test.com", name: nil),
        ]
        let json = input.toJSON()
        let attendees = json["attendees"] as? [[String: Any]]
        #expect(attendees?.count == 2)
        #expect(attendees?[0]["email"] as? String == "alice@test.com")
        #expect(attendees?[0]["displayName"] as? String == "Alice")
        #expect(attendees?[1]["email"] as? String == "bob@test.com")
        #expect(attendees?[1]["displayName"] == nil)
    }

    @Test("toJSON includes recurrence")
    func toJSONRecurrence() {
        var input = GCalEventInput()
        input.recurrence = ["RRULE:FREQ=DAILY"]
        let json = input.toJSON()
        #expect(json["recurrence"] as? [String] == ["RRULE:FREQ=DAILY"])
    }

    @Test("toJSON includes transparency")
    func toJSONTransparency() {
        var input = GCalEventInput()
        input.transparency = "transparent"
        let json = input.toJSON()
        #expect(json["transparency"] as? String == "transparent")
    }

    @Test("toJSON includes id")
    func toJSONId() {
        var input = GCalEventInput()
        input.id = "event-123"
        let json = input.toJSON()
        #expect(json["id"] as? String == "event-123")
    }

    @Test("toJSON empty input produces empty dict")
    func toJSONEmpty() {
        let input = GCalEventInput()
        let json = input.toJSON()
        #expect(json.isEmpty)
    }
}

// MARK: - CalendarToolHelpers.buildGCalEventInput

@Suite("CalendarToolHelpers buildGCalEventInput")
struct BuildGCalEventInputTests {

    @Test("buildGCalEventInput with title and location")
    func titleAndLocation() {
        let args: [String: JSONValue] = [
            "title": .string("Team Meeting"),
            "location": .string("Room 42"),
            "description": .string("Weekly sync"),
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        #expect(input.summary == "Team Meeting")
        #expect(input.location == "Room 42")
        #expect(input.description == "Weekly sync")
    }

    @Test("buildGCalEventInput with timed event start/end")
    func timedEvent() {
        let args: [String: JSONValue] = [
            "start_iso": .string("2024-06-15T10:00:00"),
            "end_iso": .string("2024-06-15T11:00:00"),
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        #expect(input.startDateTime != nil)
        #expect(input.startTimeZone != nil)
        #expect(input.endDateTime != nil)
        // Should NOT have date-only fields
        #expect(input.startDate == nil)
        #expect(input.endDate == nil)
    }

    @Test("buildGCalEventInput with all-day event")
    func allDayEvent() {
        let args: [String: JSONValue] = [
            "start_iso": .string("2024-12-25T00:00:00"),
            "end_iso": .string("2024-12-26T00:00:00"),
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: true)
        #expect(input.startDate == "2024-12-25")
        #expect(input.endDate == "2024-12-26")
        // Should NOT have dateTime fields
        #expect(input.startDateTime == nil)
        #expect(input.endDateTime == nil)
    }

    @Test("buildGCalEventInput with transparency free")
    func transparencyFree() {
        let args: [String: JSONValue] = ["transparency": .string("free")]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        #expect(input.transparency == "transparent")
    }

    @Test("buildGCalEventInput with transparency busy")
    func transparencyBusy() {
        let args: [String: JSONValue] = ["transparency": .string("busy")]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        #expect(input.transparency == "opaque")
    }

    @Test("buildGCalEventInput with attendees as dictionaries")
    func attendeesAsDicts() {
        let args: [String: JSONValue] = [
            "attendees": .array([
                .dictionary(["email": .string("alice@test.com"), "name": .string("Alice")]),
                .dictionary(["email": .string("bob@test.com")]),
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        #expect(input.attendees?.count == 2)
        #expect(input.attendees?[0].email == "alice@test.com")
        #expect(input.attendees?[0].name == "Alice")
        #expect(input.attendees?[1].email == "bob@test.com")
        #expect(input.attendees?[1].name == nil)
    }

    @Test("buildGCalEventInput with attendees as strings")
    func attendeesAsStrings() {
        let args: [String: JSONValue] = [
            "attendees": .array([
                .string("alice@test.com"),
                .string("bob@test.com"),
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        #expect(input.attendees?.count == 2)
        #expect(input.attendees?[0].email == "alice@test.com")
        #expect(input.attendees?[0].name == nil)
    }

    @Test("buildGCalEventInput with recurrence")
    func recurrence() {
        let args: [String: JSONValue] = [
            "recurrence": .dictionary([
                "freq": .string("weekly"),
                "interval": .int(2),
                "count": .int(10),
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        #expect(input.recurrence?.count == 1)
        let rrule = input.recurrence?[0] ?? ""
        #expect(rrule.contains("FREQ=WEEKLY"))
        #expect(rrule.contains("INTERVAL=2"))
        #expect(rrule.contains("COUNT=10"))
    }

    @Test("buildGCalEventInput empty args produces empty input")
    func emptyArgs() {
        let args: [String: JSONValue] = [:]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        #expect(input.summary == nil)
        #expect(input.location == nil)
        #expect(input.startDateTime == nil)
        #expect(input.attendees == nil)
        #expect(input.recurrence == nil)
    }

    @Test("buildGCalEventInput skips empty email attendees")
    func skipsEmptyEmailAttendees() {
        let args: [String: JSONValue] = [
            "attendees": .array([
                .dictionary(["email": .string("")]),
                .string(""),
                .dictionary(["email": .string("valid@test.com")]),
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        #expect(input.attendees?.count == 1)
        #expect(input.attendees?[0].email == "valid@test.com")
    }
}

// MARK: - CalendarToolHelpers formatDetailedEvent

@Suite("CalendarToolHelpers formatDetailedEvent")
struct FormatDetailedEventTests {

    @Test("Formats basic timed event")
    func basicTimedEvent() {
        let event = GCalEvent(
            id: "e1", summary: "Standup", location: "Room A", description: "Daily sync",
            start: GCalDateTime(dateTime: "2024-06-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-06-15T10:30:00Z", date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: "https://cal.example.com/e1",
            created: nil, updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("event_id: e1"))
        #expect(output.contains("title: Standup"))
        #expect(output.contains("all_day: no"))
        #expect(output.contains("availability: busy"))
        #expect(output.contains("Location: Room A"))
        #expect(output.contains("description: Daily sync"))
        #expect(output.contains("link: https://cal.example.com/e1"))
    }

    @Test("Formats all-day event")
    func allDayEvent() {
        let event = GCalEvent(
            id: "e2", summary: "Holiday", location: nil, description: nil,
            start: GCalDateTime(dateTime: nil, date: "2024-12-25", timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: "2024-12-26", timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("all_day: yes"))
    }

    @Test("Formats free event")
    func freeEvent() {
        let event = GCalEvent(
            id: "e3", summary: "Focus Time", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2024-06-15T14:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-06-15T16:00:00Z", date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: "transparent", status: nil, htmlLink: nil, created: nil, updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("availability: free"))
    }

    @Test("Formats recurring event with RRULE")
    func recurringEvent() {
        let event = GCalEvent(
            id: "e4", summary: "Weekly", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2024-06-15T09:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-06-15T10:00:00Z", date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: ["RRULE:FREQ=WEEKLY"],
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("recurring: yes"))
        #expect(output.contains("RRULE: RRULE:FREQ=WEEKLY"))
    }

    @Test("Formats event with attendees")
    func withAttendees() {
        let event = GCalEvent(
            id: "e5", summary: "Meeting", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2024-06-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-06-15T11:00:00Z", date: nil, timeZone: nil),
            attendees: [
                GCalAttendee(email: "alice@test.com", displayName: "Alice", responseStatus: "accepted", organizer: nil, self: nil),
                GCalAttendee(email: "bob@test.com", displayName: nil, responseStatus: "declined", organizer: nil, self: nil),
            ],
            organizer: GCalOrganizer(email: "alice@test.com", displayName: "Alice", self: nil),
            recurrence: nil, transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("attendees:"))
        #expect(output.contains("Alice <alice@test.com> (ACCEPTED)"))
        #expect(output.contains("<bob@test.com> (DECLINED)"))
        #expect(output.contains("Organizer: Alice <alice@test.com>"))
    }

    @Test("No title shows (No title)")
    func noTitle() {
        let event = GCalEvent(
            id: "e6", summary: "", location: nil, description: nil,
            start: nil, end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("title: (No title)"))
    }
}
