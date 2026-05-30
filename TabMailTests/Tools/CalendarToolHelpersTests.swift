/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("CalendarToolHelpers Argument Parsing")
struct CalendarToolHelpersArgTests {

    @Test("stringArg extracts string value")
    func stringArgExtractsValue() {
        let args: [String: JSONValue] = ["title": .string("Meeting")]
        #expect(CalendarToolHelpers.stringArg(args, "title") == "Meeting")
    }

    @Test("stringArg returns empty for missing key")
    func stringArgMissingKey() {
        let args: [String: JSONValue] = [:]
        #expect(CalendarToolHelpers.stringArg(args, "title") == "")
    }

    @Test("stringArg returns empty for non-string value")
    func stringArgNonString() {
        let args: [String: JSONValue] = ["count": .int(5)]
        #expect(CalendarToolHelpers.stringArg(args, "count") == "")
    }

    @Test("stringArg trims whitespace")
    func stringArgTrims() {
        let args: [String: JSONValue] = ["title": .string("  Meeting  ")]
        #expect(CalendarToolHelpers.stringArg(args, "title") == "Meeting")
    }

    @Test("stringArgOpt returns nil for missing key")
    func stringArgOptMissing() {
        let args: [String: JSONValue] = [:]
        #expect(CalendarToolHelpers.stringArgOpt(args, "title") == nil)
    }

    @Test("stringArgOpt returns string for present key")
    func stringArgOptPresent() {
        let args: [String: JSONValue] = ["loc": .string("Room A")]
        #expect(CalendarToolHelpers.stringArgOpt(args, "loc") == "Room A")
    }

    @Test("stringArgOpt returns nil for non-string value")
    func stringArgOptNonString() {
        let args: [String: JSONValue] = ["count": .bool(true)]
        #expect(CalendarToolHelpers.stringArgOpt(args, "count") == nil)
    }

    @Test("boolArg extracts bool value")
    func boolArgExtractsValue() {
        let args: [String: JSONValue] = ["is_all_day": .bool(true)]
        #expect(CalendarToolHelpers.boolArg(args, "is_all_day") == true)
    }

    @Test("boolArg returns nil for missing key")
    func boolArgMissing() {
        let args: [String: JSONValue] = [:]
        #expect(CalendarToolHelpers.boolArg(args, "is_all_day") == nil)
    }

    @Test("boolArg returns nil for non-bool value")
    func boolArgNonBool() {
        let args: [String: JSONValue] = ["flag": .string("true")]
        #expect(CalendarToolHelpers.boolArg(args, "flag") == nil)
    }
}

@Suite("CalendarToolHelpers buildGCalEventInput")
struct CalendarToolHelpersBuildInputTests {

    @Test("Sets summary from title argument")
    func setsSummary() {
        let args: [String: JSONValue] = ["title": .string("Team Standup")]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.summary == "Team Standup")
    }

    @Test("Sets location from argument")
    func setsLocation() {
        let args: [String: JSONValue] = ["location": .string("Room 42")]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.location == "Room 42")
    }

    @Test("Sets description from argument")
    func setsDescription() {
        let args: [String: JSONValue] = ["description": .string("Discuss Q2")]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.description == "Discuss Q2")
    }

    @Test("Transparency free maps to transparent")
    func transparencyFree() {
        let args: [String: JSONValue] = ["transparency": .string("free")]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.transparency == "transparent")
    }

    @Test("Transparency busy maps to opaque")
    func transparencyBusy() {
        let args: [String: JSONValue] = ["transparency": .string("busy")]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.transparency == "opaque")
    }

    @Test("All-day event uses date-only format")
    func allDayUsesDateOnly() {
        let args: [String: JSONValue] = [
            "start_iso": .string("2024-03-15T10:00:00"),
            "end_iso": .string("2024-03-16T10:00:00")
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: true)
        #expect(input.startDate == "2024-03-15")
        #expect(input.endDate == "2024-03-16")
        #expect(input.startDateTime == nil)
        #expect(input.endDateTime == nil)
    }

    @Test("Timed event uses RFC3339 format")
    func timedEventUsesRFC3339() {
        let args: [String: JSONValue] = [
            "start_iso": .string("2024-03-15T10:00:00"),
            "end_iso": .string("2024-03-15T11:00:00")
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        #expect(input.startDateTime != nil)
        #expect(input.endDateTime != nil)
        #expect(input.startDate == nil)
        #expect(input.endDate == nil)
        #expect(input.startTimeZone != nil)
    }

    @Test("Attendees from array of dictionaries")
    func attendeesFromDicts() {
        let args: [String: JSONValue] = [
            "attendees": .array([
                .dictionary(["email": .string("alice@test.com"), "name": .string("Alice")]),
                .dictionary(["email": .string("bob@test.com")])
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.attendees?.count == 2)
        #expect(input.attendees?[0].email == "alice@test.com")
        #expect(input.attendees?[0].name == "Alice")
        #expect(input.attendees?[1].email == "bob@test.com")
        #expect(input.attendees?[1].name == nil)
    }

    @Test("Attendees from array of strings")
    func attendeesFromStrings() {
        let args: [String: JSONValue] = [
            "attendees": .array([
                .string("alice@test.com"),
                .string("bob@test.com")
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.attendees?.count == 2)
        #expect(input.attendees?[0].email == "alice@test.com")
        #expect(input.attendees?[0].name == nil)
    }

    @Test("Empty email attendees filtered out")
    func emptyEmailAttendees() {
        let args: [String: JSONValue] = [
            "attendees": .array([
                .dictionary(["email": .string(""), "name": .string("Ghost")]),
                .string(""),
                .dictionary(["email": .string("real@test.com")])
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.attendees?.count == 1)
        #expect(input.attendees?[0].email == "real@test.com")
    }

    @Test("Recurrence with freq and count")
    func recurrenceFreqAndCount() {
        let args: [String: JSONValue] = [
            "recurrence": .dictionary([
                "freq": .string("weekly"),
                "count": .int(10)
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.recurrence?.count == 1)
        #expect(input.recurrence?[0].contains("FREQ=WEEKLY") == true)
        #expect(input.recurrence?[0].contains("COUNT=10") == true)
    }

    @Test("Recurrence with interval")
    func recurrenceWithInterval() {
        let args: [String: JSONValue] = [
            "recurrence": .dictionary([
                "freq": .string("daily"),
                "interval": .int(2)
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.recurrence?[0].contains("INTERVAL=2") == true)
    }

    @Test("No arguments produces empty input")
    func noArguments() {
        let args: [String: JSONValue] = [:]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.summary == nil)
        #expect(input.location == nil)
        #expect(input.startDateTime == nil)
        #expect(input.attendees == nil)
        #expect(input.recurrence == nil)
    }
}

@Suite("CalendarToolHelpers formatDetailedEvent")
struct CalendarToolHelpersFormatTests {

    @Test("Format event with all fields")
    func formatFullEvent() {
        let event = GCalEvent(
            id: "evt-123",
            summary: "Team Standup",
            location: "Room 42",
            description: "Daily standup",
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T10:30:00Z", date: nil, timeZone: nil),
            attendees: [
                GCalAttendee(email: "alice@test.com", displayName: "Alice", responseStatus: "accepted", organizer: nil, self: nil)
            ],
            organizer: GCalOrganizer(email: "bob@test.com", displayName: "Bob", self: nil),
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: "https://calendar.google.com/event/123",
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("event_id: evt-123"))
        #expect(output.contains("title: Team Standup"))
        #expect(output.contains("all_day: no"))
        #expect(output.contains("availability: busy"))
        #expect(output.contains("Location: Room 42"))
        #expect(output.contains("Organizer: Bob <bob@test.com>"))
        #expect(output.contains("alice@test.com"))
        #expect(output.contains("ACCEPTED"))
        #expect(output.contains("description: Daily standup"))
        #expect(output.contains("link: https://calendar.google.com/event/123"))
    }

    @Test("Format all-day event")
    func formatAllDayEvent() {
        let event = GCalEvent(
            id: "evt-allday",
            summary: "Holiday",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: nil, date: "2024-03-25", timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: "2024-03-26", timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("all_day: yes"))
        #expect(output.contains("title: Holiday"))
        #expect(!output.contains("Location:"))
        #expect(!output.contains("link:"))
    }

    @Test("Format transparent event shows free")
    func formatTransparentEvent() {
        let event = GCalEvent(
            id: "evt-free",
            summary: "Focus Time",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T14:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T16:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: "transparent",
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("availability: free"))
    }

    @Test("Format recurring event")
    func formatRecurringEvent() {
        let event = GCalEvent(
            id: "evt-rec",
            summary: "Weekly",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T11:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: ["RRULE:FREQ=WEEKLY"],
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("recurring: yes"))
        #expect(output.contains("RRULE: RRULE:FREQ=WEEKLY"))
    }

    @Test("No title shows (No title)")
    func noTitleEvent() {
        let event = GCalEvent(
            id: "evt-notitle",
            summary: nil,
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("title: (No title)"))
    }

    @Test("Empty summary shows (No title)")
    func emptySummaryEvent() {
        let event = GCalEvent(
            id: "evt-empty",
            summary: "",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("title: (No title)"))
    }

    @Test("Organizer with email only (no name)")
    func organizerEmailOnly() {
        let event = GCalEvent(
            id: "evt-org-email",
            summary: "Meeting",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: nil,
            organizer: GCalOrganizer(email: "org@test.com", displayName: nil, self: nil),
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("Organizer:"))
        #expect(output.contains("org@test.com"))
    }

    @Test("Organizer with name only (no email)")
    func organizerNameOnly() {
        let event = GCalEvent(
            id: "evt-org-name",
            summary: "Meeting",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: nil,
            organizer: GCalOrganizer(email: nil, displayName: "OrgName", self: nil),
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("Organizer: OrgName"))
    }

    @Test("Organizer with both empty name and email omits line")
    func organizerBothEmpty() {
        let event = GCalEvent(
            id: "evt-org-empty",
            summary: "Meeting",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: nil,
            organizer: GCalOrganizer(email: nil, displayName: nil, self: nil),
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(!output.contains("Organizer:"))
    }

    @Test("Attendee with no response status")
    func attendeeNoStatus() {
        let event = GCalEvent(
            id: "evt-att-nostatus",
            summary: "Meeting",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: [
                GCalAttendee(email: "test@test.com", displayName: "Test User", responseStatus: nil, organizer: nil, self: nil)
            ],
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("attendees:"))
        #expect(output.contains("Test User"))
        #expect(output.contains("test@test.com"))
    }

    @Test("Attendee with empty response status")
    func attendeeEmptyStatus() {
        let event = GCalEvent(
            id: "evt-att-emptystatus",
            summary: "Meeting",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: [
                GCalAttendee(email: "test@test.com", displayName: nil, responseStatus: "", organizer: nil, self: nil)
            ],
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("attendees:"))
        #expect(output.contains("<test@test.com>"))
    }

    @Test("Whitespace-only description omits description line")
    func whitespaceOnlyDescription() {
        let event = GCalEvent(
            id: "evt-ws-desc",
            summary: "Meeting",
            location: nil,
            description: "   ",
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(!output.contains("description:"))
    }

    @Test("Event with no start date omits start_iso line")
    func eventNoStartDate() {
        let event = GCalEvent(
            id: "evt-nostart",
            summary: "Meeting",
            location: nil,
            description: nil,
            start: nil,
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(!output.contains("start_iso:"))
        #expect(!output.contains("end_iso:"))
    }
}

// MARK: - formatGroupedSummary Tests

@Suite("CalendarToolHelpers formatGroupedSummary")
struct CalendarToolHelpersGroupedSummaryTests {

    @Test("Empty events list returns empty string")
    func emptyEvents() {
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [])
        #expect(output == "")
    }

    @Test("Single timed event formats correctly")
    func singleTimedEvent() {
        let event = GCalEvent(
            id: "evt-1",
            summary: "Standup",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T10:30:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [event])
        #expect(output.contains("date:"))
        #expect(output.contains("timezone:"))
        #expect(output.contains("Standup"))
        #expect(output.contains("event_id: evt-1"))
    }

    @Test("All-day event shows 'All day'")
    func allDayEventGrouped() {
        let event = GCalEvent(
            id: "evt-allday",
            summary: "Holiday",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: nil, date: "2024-03-25", timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: "2024-03-26", timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [event])
        #expect(output.contains("All day: Holiday"))
    }

    @Test("Recurring event shows recurrence marker")
    func recurringEventGrouped() {
        let event = GCalEvent(
            id: "evt-rec",
            summary: "Weekly",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T11:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: ["RRULE:FREQ=WEEKLY"],
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [event])
        // The formatter now embeds the RRULE alongside the recurrence marker so
        // the LLM can see UNTIL/COUNT details inline (commit 28959af). The
        // marker remains "↻", but the full token is "(↻ <RRULE>)".
        #expect(output.contains("(\u{21BB} RRULE:FREQ=WEEKLY)"))
    }

    @Test("Transparent event shows [free] marker")
    func transparentEventGrouped() {
        let event = GCalEvent(
            id: "evt-free",
            summary: "Focus",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T14:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T16:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: "transparent",
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [event])
        #expect(output.contains("[free]"))
    }

    @Test("No title event shows (No title)")
    func noTitleGrouped() {
        let event = GCalEvent(
            id: "evt-notitle",
            summary: nil,
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T11:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [event])
        #expect(output.contains("(No title)"))
    }

    @Test("Event with no end date uses toNaiveISO for time range")
    func eventNoEndDate() {
        let event = GCalEvent(
            id: "evt-noend",
            summary: "Open-ended",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [event])
        #expect(output.contains("Open-ended"))
        #expect(output.contains("event_id: evt-noend"))
    }

    @Test("Events with no start date are skipped")
    func eventNoStartDateSkipped() {
        let event = GCalEvent(
            id: "evt-nostart",
            summary: "Ghost",
            location: nil,
            description: nil,
            start: nil,
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [event])
        #expect(output == "")
    }

    @Test("Multiple events on same day grouped together")
    func sameDayGrouped() {
        let event1 = GCalEvent(
            id: "evt-1",
            summary: "Morning",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T09:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let event2 = GCalEvent(
            id: "evt-2",
            summary: "Afternoon",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T14:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T15:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [event1, event2])
        // Should have exactly one "date:" header since both events are on the same day
        let dateOccurrences = output.components(separatedBy: "date:").count - 1
        #expect(dateOccurrences == 1)
        #expect(output.contains("Morning"))
        #expect(output.contains("Afternoon"))
    }

    @Test("Events on different days produce separate groups")
    func differentDaysGrouped() {
        let event1 = GCalEvent(
            id: "evt-1",
            summary: "Day1",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T11:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let event2 = GCalEvent(
            id: "evt-2",
            summary: "Day2",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-16T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-16T11:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [event1, event2])
        let dateOccurrences = output.components(separatedBy: "date:").count - 1
        #expect(dateOccurrences == 2)
        #expect(output.contains("Day1"))
        #expect(output.contains("Day2"))
    }

    @Test("Non-transparent event omits [free] marker")
    func opaqueEventNoFreeMarker() {
        let event = GCalEvent(
            id: "evt-opaque",
            summary: "Busy Event",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T11:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: "opaque",
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [event])
        #expect(!output.contains("[free]"))
    }

    @Test("Empty recurrence array does not show recurrence marker")
    func emptyRecurrenceNoMarker() {
        let event = GCalEvent(
            id: "evt-norec",
            summary: "Once",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T11:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: [],
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [event])
        #expect(!output.contains("(\u{21BB})"))
    }

    @Test("Event with nil id outputs empty event_id")
    func nilEventIdGrouped() {
        let event = GCalEvent(
            id: nil,
            summary: "No ID",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T11:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatGroupedSummary(gcalEvents: [event])
        #expect(output.contains("event_id: "))
    }
}

// MARK: - resolveDateRange Tests

@Suite("CalendarToolHelpers resolveDateRange")
struct CalendarToolHelpersDateRangeTests {

    @Test("Both from_date and to_date provided")
    func bothDatesProvided() {
        let args: [String: JSONValue] = [
            "from_date": .string("2024-03-15T00:00:00"),
            "to_date": .string("2024-03-20T00:00:00")
        ]
        let (start, end) = CalendarToolHelpers.resolveDateRange(args)
        let cal = Calendar.current
        let startComps = cal.dateComponents([.year, .month, .day], from: start)
        let endComps = cal.dateComponents([.year, .month, .day], from: end)
        #expect(startComps.year == 2024)
        #expect(startComps.month == 3)
        #expect(startComps.day == 15)
        #expect(endComps.year == 2024)
        #expect(endComps.month == 3)
        #expect(endComps.day == 20)
    }

    @Test("Date-only to_date is inclusive (+1 day bump so target day's events are visible)")
    func dateOnlyToDateInclusive() {
        let args: [String: JSONValue] = [
            "from_date": .string("2026-04-28"),
            "to_date": .string("2026-04-30")
        ]
        let (start, end) = CalendarToolHelpers.resolveDateRange(args)
        // Window should span 3 days: April 28 00:00 → May 1 00:00 (so events
        // on April 30 are included since Google's events.list returns rows
        // with start < timeMax).
        let interval = end.timeIntervalSince(start)
        #expect(interval == 86400 * 3)
    }

    @Test("Datetime to_date is verbatim, no +1 day bump")
    func datetimeToDateVerbatim() {
        let args: [String: JSONValue] = [
            "from_date": .string("2026-04-28T00:00:00"),
            "to_date": .string("2026-04-30T15:00:00")
        ]
        let (start, end) = CalendarToolHelpers.resolveDateRange(args)
        // Window is exactly the user-specified range — no +1 day bump.
        let interval = end.timeIntervalSince(start)
        #expect(interval == 86400 * 2 + 3600 * 15)
    }

    @Test("Single-day date-only to_date (==from_date) covers that one day")
    func singleDayInclusive() {
        let args: [String: JSONValue] = [
            "from_date": .string("2026-04-28"),
            "to_date": .string("2026-04-28")
        ]
        let (start, end) = CalendarToolHelpers.resolveDateRange(args)
        // Should cover April 28 entirely: 24h window, not 0h.
        let interval = end.timeIntervalSince(start)
        #expect(interval == 86400)
    }

    @Test("No arguments defaults to today start and +1 day")
    func noArguments() {
        let args: [String: JSONValue] = [:]
        let (start, end) = CalendarToolHelpers.resolveDateRange(args)
        let expectedStart = Calendar.current.startOfDay(for: Date())
        let expectedEnd = expectedStart.addingTimeInterval(86400)
        #expect(abs(start.timeIntervalSince(expectedStart)) < 1)
        #expect(abs(end.timeIntervalSince(expectedEnd)) < 1)
    }

    @Test("Only from_date provided, to_date defaults to +1 day")
    func onlyFromDate() {
        let args: [String: JSONValue] = [
            "from_date": .string("2024-06-01T00:00:00")
        ]
        let (start, end) = CalendarToolHelpers.resolveDateRange(args)
        let expectedEnd = start.addingTimeInterval(86400)
        #expect(abs(end.timeIntervalSince(expectedEnd)) < 1)
    }

    @Test("Only to_date provided, from_date defaults to today")
    func onlyToDate() {
        let args: [String: JSONValue] = [
            "to_date": .string("2024-12-31T23:59:59")
        ]
        let (start, _) = CalendarToolHelpers.resolveDateRange(args)
        let expectedStart = Calendar.current.startOfDay(for: Date())
        #expect(abs(start.timeIntervalSince(expectedStart)) < 1)
    }

    @Test("Invalid from_date falls back to today")
    func invalidFromDate() {
        let args: [String: JSONValue] = [
            "from_date": .string("not-a-date")
        ]
        let (start, _) = CalendarToolHelpers.resolveDateRange(args)
        let expectedStart = Calendar.current.startOfDay(for: Date())
        #expect(abs(start.timeIntervalSince(expectedStart)) < 1)
    }

    @Test("Invalid to_date falls back to from_date +1 day")
    func invalidToDate() {
        let args: [String: JSONValue] = [
            "from_date": .string("2024-03-15T00:00:00"),
            "to_date": .string("garbage")
        ]
        let (start, end) = CalendarToolHelpers.resolveDateRange(args)
        let expectedEnd = start.addingTimeInterval(86400)
        #expect(abs(end.timeIntervalSince(expectedEnd)) < 1)
    }

    @Test("Empty string from_date falls back to today")
    func emptyFromDate() {
        let args: [String: JSONValue] = [
            "from_date": .string("")
        ]
        let (start, _) = CalendarToolHelpers.resolveDateRange(args)
        let expectedStart = Calendar.current.startOfDay(for: Date())
        #expect(abs(start.timeIntervalSince(expectedStart)) < 1)
    }

    @Test("Date-only format works for from_date")
    func dateOnlyFromDate() {
        let args: [String: JSONValue] = [
            "from_date": .string("2024-03-15")
        ]
        let (start, _) = CalendarToolHelpers.resolveDateRange(args)
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: start)
        #expect(comps.year == 2024)
        #expect(comps.month == 3)
        #expect(comps.day == 15)
    }

    @Test("widens default range when query is supplied (~30 days back to ~365 days forward)")
    func widensDefaultRangeForQuery() {
        // Regression: with `query` set and no dates, the LLM is searching by
        // name and needs to find future occurrences of recurring events. The
        // old default (today+1d) caused the LLM to miss the second half of a
        // split series. With a query, the window must span enough on both
        // sides for recurring events to surface.
        let args: [String: JSONValue] = ["query": .string("Weekly sync")]
        let (start, end) = CalendarToolHelpers.resolveDateRange(args)
        let diffDays = end.timeIntervalSince(start) / 86400
        #expect(diffDays > 300, "expected ~395 days, got \(diffDays)")
        #expect(diffDays < 450, "expected ~395 days, got \(diffDays)")
        // Start should be in the past relative to now.
        #expect(start.timeIntervalSinceNow < 0)
        // End should be roughly a year out.
        #expect(end.timeIntervalSinceNow > 300 * 86400)
    }

    @Test("keeps tight default range when no query (overview mode)")
    func tightDefaultRangeNoQuery() {
        let args: [String: JSONValue] = [:]
        let (start, end) = CalendarToolHelpers.resolveDateRange(args)
        let diffDays = end.timeIntervalSince(start) / 86400
        // 1-day window when no query supplied — keeps overview compact.
        #expect(diffDays > 0.9)
        #expect(diffDays < 1.5)
    }
}

// MARK: - buildGCalEventInput Additional Coverage

@Suite("CalendarToolHelpers buildGCalEventInput - Additional")
struct CalendarToolHelpersBuildInputAdditionalTests {

    @Test("Recurrence with until string")
    func recurrenceWithUntil() {
        let args: [String: JSONValue] = [
            "recurrence": .dictionary([
                "freq": .string("daily"),
                "until": .string("2024-12-31T23:59:59")
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.recurrence?.count == 1)
        #expect(input.recurrence?[0].contains("FREQ=DAILY") == true)
        #expect(input.recurrence?[0].contains("UNTIL=") == true)
    }

    @Test("Recurrence with double interval")
    func recurrenceWithDoubleInterval() {
        let args: [String: JSONValue] = [
            "recurrence": .dictionary([
                "freq": .string("weekly"),
                "interval": .double(3.0)
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.recurrence?[0].contains("INTERVAL=3") == true)
    }

    @Test("Recurrence with double count")
    func recurrenceWithDoubleCount() {
        let args: [String: JSONValue] = [
            "recurrence": .dictionary([
                "freq": .string("monthly"),
                "count": .double(5.0)
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.recurrence?[0].contains("COUNT=5") == true)
    }

    @Test("Recurrence with interval=1 does not add INTERVAL")
    func recurrenceIntervalOne() {
        let args: [String: JSONValue] = [
            "recurrence": .dictionary([
                "freq": .string("daily"),
                "interval": .int(1)
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.recurrence?[0].contains("INTERVAL") == false)
    }

    @Test("toRFC3339 with date-only string (no time component)")
    func timedEventDateOnlyISO() {
        let args: [String: JSONValue] = [
            "start_iso": .string("2024-03-15")
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        // toRFC3339 falls back to date-only parsing and produces RFC3339 output
        #expect(input.startDateTime != nil)
        #expect(input.startDateTime?.contains("2024-03-15") == true)
    }

    @Test("toRFC3339 with unparseable string returns original")
    func timedEventUnparseableISO() {
        let args: [String: JSONValue] = [
            "start_iso": .string("not-a-date-at-all")
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        // toRFC3339 can't parse it, returns the original string
        #expect(input.startDateTime == "not-a-date-at-all")
    }

    @Test("Mixed attendees: dicts and strings together")
    func mixedAttendees() {
        let args: [String: JSONValue] = [
            "attendees": .array([
                .dictionary(["email": .string("alice@test.com"), "name": .string("Alice")]),
                .string("bob@test.com"),
                .int(42)  // invalid type, should be filtered
            ])
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: nil)
        #expect(input.attendees?.count == 2)
    }
}

// MARK: - cacheEventDetailsForPills Tests

@Suite("CalendarToolHelpers cacheEventDetailsForPills")
struct CalendarToolHelpersCacheTests {

    @Test("Caches event details to translator")
    func cachesEventDetails() async {
        let translator = MockChatIdTranslator()
        let event = GCalEvent(
            id: "evt-cache-1",
            summary: "Cached Meeting",
            location: "Room 1",
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-03-15T11:00:00Z", date: nil, timeZone: nil),
            attendees: [
                GCalAttendee(email: "alice@test.com", displayName: "Alice", responseStatus: "accepted", organizer: nil, self: nil)
            ],
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: "https://cal.example.com/evt-cache-1",
            created: nil,
            updated: nil
        )
        await CalendarToolHelpers.cacheEventDetailsForPills([event], translator: translator)

        // Verify the event was cached by looking it up
        let numericId = await translator.toNumericId("evt-cache-1")
        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail != nil)
        #expect(detail?.title == "Cached Meeting")
        #expect(detail?.location == "Room 1")
        #expect(detail?.htmlLink == "https://cal.example.com/evt-cache-1")
        #expect(detail?.attendees.count == 1)
        #expect(detail?.attendees[0].email == "alice@test.com")
    }

    @Test("Skips events with nil id")
    func skipsNilId() async {
        let translator = MockChatIdTranslator()
        let event = GCalEvent(
            id: nil,
            summary: "No ID",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        await CalendarToolHelpers.cacheEventDetailsForPills([event], translator: translator)
        // No events should be cached (translator shouldn't have any mappings)
        let detail = await translator.resolveEventDetail(1)
        #expect(detail == nil)
    }

    @Test("Skips events with empty id")
    func skipsEmptyId() async {
        let translator = MockChatIdTranslator()
        let event = GCalEvent(
            id: "",
            summary: "Empty ID",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        await CalendarToolHelpers.cacheEventDetailsForPills([event], translator: translator)
        let detail = await translator.resolveEventDetail(1)
        #expect(detail == nil)
    }

    @Test("Caches event with no summary as (No title)")
    func cachesNoTitle() async {
        let translator = MockChatIdTranslator()
        let event = GCalEvent(
            id: "evt-notitle",
            summary: nil,
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        await CalendarToolHelpers.cacheEventDetailsForPills([event], translator: translator)
        let numericId = await translator.toNumericId("evt-notitle")
        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail?.title == "(No title)")
    }

    @Test("Caches transparent event as free availability")
    func cachesTransparentAsFree() async {
        let translator = MockChatIdTranslator()
        let event = GCalEvent(
            id: "evt-free",
            summary: "Focus",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: "transparent",
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        await CalendarToolHelpers.cacheEventDetailsForPills([event], translator: translator)
        let numericId = await translator.toNumericId("evt-free")
        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail?.availability == "free")
    }

    @Test("Caches recurring event")
    func cachesRecurring() async {
        let translator = MockChatIdTranslator()
        let event = GCalEvent(
            id: "evt-rec",
            summary: "Weekly",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: ["RRULE:FREQ=WEEKLY"],
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        await CalendarToolHelpers.cacheEventDetailsForPills([event], translator: translator)
        let numericId = await translator.toNumericId("evt-rec")
        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail?.isRecurring == true)
    }

    @Test("Filters attendees with empty email")
    func filtersEmptyEmailAttendees() async {
        let translator = MockChatIdTranslator()
        let event = GCalEvent(
            id: "evt-att",
            summary: "Meeting",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-03-15T10:00:00Z", date: nil, timeZone: nil),
            end: nil,
            attendees: [
                GCalAttendee(email: "valid@test.com", displayName: "Valid", responseStatus: "accepted", organizer: nil, self: nil),
                GCalAttendee(email: "", displayName: "NoEmail", responseStatus: nil, organizer: nil, self: nil),
                GCalAttendee(email: nil, displayName: "NilEmail", responseStatus: nil, organizer: nil, self: nil)
            ],
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        await CalendarToolHelpers.cacheEventDetailsForPills([event], translator: translator)
        let numericId = await translator.toNumericId("evt-att")
        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail?.attendees.count == 1)
        #expect(detail?.attendees[0].email == "valid@test.com")
    }

    @Test("Multiple events all cached")
    func multipleEventsCached() async {
        let translator = MockChatIdTranslator()
        let events = (1...3).map { i in
            GCalEvent(
                id: "evt-\(i)",
                summary: "Event \(i)",
                location: nil,
                description: nil,
                start: GCalDateTime(dateTime: "2024-03-15T\(10 + i):00:00Z", date: nil, timeZone: nil),
                end: nil,
                attendees: nil,
                organizer: nil,
                recurrence: nil,
                transparency: nil,
                status: nil,
                htmlLink: nil,
                created: nil,
                updated: nil
            )
        }
        await CalendarToolHelpers.cacheEventDetailsForPills(events, translator: translator)
        for i in 1...3 {
            let numericId = await translator.toNumericId("evt-\(i)")
            let detail = await translator.resolveEventDetail(numericId)
            #expect(detail?.title == "Event \(i)")
        }
    }
}

// MARK: - Timezone Resolution Tests

@Suite("CalendarToolHelpers Timezone Resolution")
struct CalendarToolHelpersTimezoneTests {

    @Test("resolveTimeZone returns device timezone when no timezone arg")
    func resolveTimeZoneDefault() {
        let args: [String: JSONValue] = [:]
        let tz = CalendarToolHelpers.resolveTimeZone(args)
        #expect(tz == .current)
    }

    @Test("resolveTimeZone returns specified IANA timezone")
    func resolveTimeZoneExplicit() {
        let args: [String: JSONValue] = ["timezone": .string("Asia/Tokyo")]
        let tz = CalendarToolHelpers.resolveTimeZone(args)
        #expect(tz.identifier == "Asia/Tokyo")
    }

    @Test("resolveTimeZone falls back to current for invalid identifier")
    func resolveTimeZoneInvalid() {
        let args: [String: JSONValue] = ["timezone": .string("Not/A/Timezone")]
        let tz = CalendarToolHelpers.resolveTimeZone(args)
        #expect(tz == .current)
    }

    @Test("resolveTimeZone ignores empty string")
    func resolveTimeZoneEmpty() {
        let args: [String: JSONValue] = ["timezone": .string("")]
        let tz = CalendarToolHelpers.resolveTimeZone(args)
        #expect(tz == .current)
    }

    @Test("resolveDateRange uses timezone for parsing")
    func resolveDateRangeWithTimezone() {
        let argsTokyo: [String: JSONValue] = [
            "from_date": .string("2024-06-15T09:00:00"),
            "timezone": .string("Asia/Tokyo")
        ]
        let argsLa: [String: JSONValue] = [
            "from_date": .string("2024-06-15T09:00:00"),
            "timezone": .string("America/Los_Angeles")
        ]
        let (startTokyo, _) = CalendarToolHelpers.resolveDateRange(argsTokyo)
        let (startLa, _) = CalendarToolHelpers.resolveDateRange(argsLa)
        // Same naive time in different timezones = different absolute Date values
        #expect(startTokyo != startLa)
        let diffHours = startLa.timeIntervalSince(startTokyo) / 3600
        #expect(abs(diffHours - 16) < 1)
    }

    @Test("buildGCalEventInput uses timezone for startTimeZone")
    func buildInputTimezone() {
        let args: [String: JSONValue] = [
            "start_iso": .string("2024-06-15T10:00:00"),
            "end_iso": .string("2024-06-15T11:00:00"),
            "timezone": .string("Europe/Berlin")
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        #expect(input.startTimeZone == "Europe/Berlin")
        #expect(input.endTimeZone == "Europe/Berlin")
    }

    @Test("buildGCalEventInput without timezone uses device timezone")
    func buildInputNoTimezone() {
        let args: [String: JSONValue] = [
            "start_iso": .string("2024-06-15T10:00:00"),
        ]
        let input = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false)
        #expect(input.startTimeZone == TimeZone.current.identifier)
    }

    @Test("resolveDateRange fallback startOfDay uses resolved timezone")
    func resolveDateRangeFallbackTimezone() {
        // When from_date is omitted but timezone is specified,
        // startOfDay should be computed in the specified timezone
        let args: [String: JSONValue] = [
            "timezone": .string("Asia/Tokyo")
        ]
        let (start, _) = CalendarToolHelpers.resolveDateRange(args)
        // Verify the start is midnight in Tokyo time, not device time
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let components = cal.dateComponents([.hour, .minute, .second], from: start)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }

    @Test("formatDetailedEvent uses specified timezone for start_iso/end_iso")
    func formatDetailedEventTimezone() {
        // 2024-06-15 00:00:00 UTC = 2024-06-15 09:00:00 JST
        let event = GCalEvent(
            id: "evt-tz",
            summary: "TZ Test",
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: "2024-06-15T00:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2024-06-15T01:00:00Z", date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let utc = TimeZone(identifier: "UTC")!
        let outputTokyo = CalendarToolHelpers.formatDetailedEvent(event, timeZone: tokyo)
        let outputUTC = CalendarToolHelpers.formatDetailedEvent(event, timeZone: utc)
        // In Tokyo (UTC+9), midnight UTC = 09:00 JST
        #expect(outputTokyo.contains("start_iso: 2024-06-15T09:00:00"))
        #expect(outputUTC.contains("start_iso: 2024-06-15T00:00:00"))
    }
}

// MARK: - applyAttendeeDelta (calendar_event_edit-v1.5.21)

@Suite("CalendarToolHelpers applyAttendeeDelta")
struct CalendarToolHelpersAttendeeDeltaTests {

    private let alice: (email: String, name: String?) = ("alice@example.com", "Alice")
    private let bob: (email: String, name: String?) = ("bob@example.com", "Bob")
    private let carol: (email: String, name: String?) = ("carol@example.com", "Carol")

    @Test("returns base unchanged when adds and removes are empty")
    func emptyDelta() {
        let result = CalendarToolHelpers.applyAttendeeDelta(base: [alice, bob], adds: [], removes: [])
        #expect(result.count == 2)
        guard result.count == 2 else { return }
        #expect(result[0].email == "alice@example.com")
        #expect(result[1].email == "bob@example.com")
    }

    @Test("adds a new attendee on top of existing list")
    func addsNewAttendee() {
        let result = CalendarToolHelpers.applyAttendeeDelta(base: [alice], adds: [bob], removes: [])
        #expect(result.count == 2)
        guard result.count == 2 else { return }
        #expect(result.map(\.email) == ["alice@example.com", "bob@example.com"])
    }

    @Test("removes a specific attendee case-insensitively")
    func removesOneCaseInsensitive() {
        let result = CalendarToolHelpers.applyAttendeeDelta(base: [alice, bob], adds: [], removes: ["BOB@EXAMPLE.COM"])
        #expect(result.count == 1)
        guard result.count == 1 else { return }
        #expect(result[0].email == "alice@example.com")
    }

    @Test("preserves existing attendees when only adding — the original bug")
    func preservesExistingOnAdd() {
        // Before delta: passing `attendees: [carol]` whole-list-replaced alice+bob with just carol.
        // With delta: alice+bob survive.
        let result = CalendarToolHelpers.applyAttendeeDelta(base: [alice, bob], adds: [carol], removes: [])
        #expect(result.count == 3)
        #expect(Set(result.map(\.email)) == ["alice@example.com", "bob@example.com", "carol@example.com"])
    }

    @Test("dedupes adds that already exist in base — base entry wins")
    func dedupesAddAgainstBase() {
        let dupeAlice: (email: String, name: String?) = ("ALICE@example.com", "Different Alice")
        let result = CalendarToolHelpers.applyAttendeeDelta(base: [alice], adds: [dupeAlice], removes: [])
        #expect(result.count == 1)
        guard result.count == 1 else { return }
        #expect(result[0].name == "Alice")
    }

    @Test("clears all attendees when remove list contains '*'")
    func starClearsAll() {
        let result = CalendarToolHelpers.applyAttendeeDelta(base: [alice, bob, carol], adds: [], removes: ["*"])
        #expect(result.isEmpty)
    }

    @Test("clear-all then add — adds replace the whole list")
    func clearThenAdd() {
        let result = CalendarToolHelpers.applyAttendeeDelta(base: [alice, bob], adds: [carol], removes: ["*"])
        #expect(result.count == 1)
        guard result.count == 1 else { return }
        #expect(result[0].email == "carol@example.com")
    }

    @Test("silently ignores removes that don't match anything in base")
    func ignoresMissingRemoves() {
        let result = CalendarToolHelpers.applyAttendeeDelta(base: [alice], adds: [], removes: ["nonexistent@example.com"])
        #expect(result.count == 1)
        guard result.count == 1 else { return }
        #expect(result[0].email == "alice@example.com")
    }
}

@Suite("CalendarToolHelpers attendee delta parsers")
struct CalendarToolHelpersAttendeeParsersTests {

    @Test("parseAttendeeAdds handles object items with name + email")
    func parseAddsObjectItems() {
        let value: JSONValue = .array([
            .dictionary(["email": .string("alice@example.com"), "name": .string("Alice")]),
            .dictionary(["email": .string("bob@example.com")]),
        ])
        let result = CalendarToolHelpers.parseAttendeeAdds(value)
        #expect(result.count == 2)
        guard result.count == 2 else { return }
        #expect(result[0].email == "alice@example.com")
        #expect(result[0].name == "Alice")
        #expect(result[1].email == "bob@example.com")
        #expect(result[1].name == nil)
    }

    @Test("parseAttendeeAdds accepts bare email strings")
    func parseAddsBareString() {
        let value: JSONValue = .array([.string("alice@example.com")])
        let result = CalendarToolHelpers.parseAttendeeAdds(value)
        #expect(result.count == 1)
        guard result.count == 1 else { return }
        #expect(result[0].email == "alice@example.com")
    }

    @Test("parseAttendeeAdds strips mailto: prefix")
    func parseAddsStripsMailto() {
        let value: JSONValue = .array([.dictionary(["email": .string("MAILTO:alice@example.com")])])
        let result = CalendarToolHelpers.parseAttendeeAdds(value)
        #expect(result.count == 1)
        guard result.count == 1 else { return }
        #expect(result[0].email == "alice@example.com")
    }

    @Test("parseAttendeeAdds drops empty / star-only entries")
    func parseAddsDropsEmptyAndStar() {
        let value: JSONValue = .array([
            .dictionary(["email": .string("")]),
            .dictionary(["email": .string("*")]),
            .dictionary(["email": .string("alice@example.com")]),
        ])
        let result = CalendarToolHelpers.parseAttendeeAdds(value)
        #expect(result.count == 1)
        guard result.count == 1 else { return }
        #expect(result[0].email == "alice@example.com")
    }

    @Test("parseAttendeeRemoves preserves '*' clear-all marker")
    func parseRemovesKeepsStar() {
        let value: JSONValue = .array([.dictionary(["email": .string("*")])])
        let result = CalendarToolHelpers.parseAttendeeRemoves(value)
        #expect(result == ["*"])
    }

    @Test("parseAttendeeRemoves strips mailto: prefix")
    func parseRemovesStripsMailto() {
        let value: JSONValue = .array([.dictionary(["email": .string("mailto:alice@example.com")])])
        let result = CalendarToolHelpers.parseAttendeeRemoves(value)
        #expect(result == ["alice@example.com"])
    }

    @Test("parseAttendeeAdds returns empty for non-array JSONValue")
    func parseAddsNonArray() {
        #expect(CalendarToolHelpers.parseAttendeeAdds(.string("not an array")).isEmpty)
        #expect(CalendarToolHelpers.parseAttendeeAdds(nil).isEmpty)
    }

    @Test("parseAttendeeAdds returns empty for an explicit empty array")
    func parseAddsEmptyArray() {
        // LLM might emit `add_attendees: []` instead of omitting the key —
        // resolveAttendeeDelta short-circuits in that case, so the parser must
        // distinguish "absent" from "empty after parse" cleanly.
        #expect(CalendarToolHelpers.parseAttendeeAdds(.array([])).isEmpty)
    }

    @Test("parseAttendeeRemoves returns empty for an explicit empty array")
    func parseRemovesEmptyArray() {
        #expect(CalendarToolHelpers.parseAttendeeRemoves(.array([])).isEmpty)
    }
}

// MARK: - Event Pill Attendee Parsing

/// Regression coverage for the `EventPillAttendee` builders that feed the chat
/// event-pill popover. Previously the create/read cache sites hardcoded
/// `attendees: []`, so a freshly-created event's pill showed no attendees until
/// the in-memory cache was evicted and a live re-fetch ran.
@Suite("CalendarToolHelpers eventPillAttendees")
struct EventPillAttendeeParsingTests {

    private func attendee(_ email: String?, _ name: String? = nil, _ status: String? = nil) -> GCalAttendee {
        GCalAttendee(email: email, displayName: name, responseStatus: status, organizer: nil, self: nil)
    }

    private func eventWith(attendees: [GCalAttendee]?) -> GCalEvent {
        GCalEvent(
            id: "evt-1", summary: "Sync", location: nil, description: nil,
            start: nil, end: nil, attendees: attendees, organizer: nil,
            recurrence: nil, transparency: nil, status: nil, htmlLink: nil,
            created: nil, updated: nil
        )
    }

    // MARK: from event

    @Test("from event: maps email, name, and response status")
    func fromEventMapsFields() {
        let event = eventWith(attendees: [
            attendee("alice@test.com", "Alice", "accepted"),
            attendee("bob@test.com", "Bob", "declined"),
        ])
        let result = CalendarToolHelpers.eventPillAttendees(from: event)
        #expect(result.count == 2)
        guard result.count == 2 else { return }
        #expect(result[0].email == "alice@test.com")
        #expect(result[0].name == "Alice")
        #expect(result[0].status == "accepted")
        #expect(result[1].status == "declined")
    }

    @Test("from event: missing responseStatus defaults to needsAction")
    func fromEventDefaultsStatus() {
        let result = CalendarToolHelpers.eventPillAttendees(from: eventWith(attendees: [attendee("c@test.com", "C", nil)]))
        #expect(result.count == 1)
        guard result.count == 1 else { return }
        #expect(result[0].status == "needsAction")
    }

    @Test("from event: drops attendees with missing or empty email")
    func fromEventDropsEmpty() {
        let result = CalendarToolHelpers.eventPillAttendees(from: eventWith(attendees: [
            attendee("", "Ghost", "accepted"),
            attendee(nil, "NoEmail", "accepted"),
            attendee("real@test.com", "Real", "accepted"),
        ]))
        #expect(result.count == 1)
        guard result.count == 1 else { return }
        #expect(result[0].email == "real@test.com")
    }

    @Test("from event: nil attendee list yields empty")
    func fromEventNilList() {
        #expect(CalendarToolHelpers.eventPillAttendees(from: eventWith(attendees: nil)).isEmpty)
    }

    // MARK: fromArguments

    @Test("fromArguments: dictionary form maps email and name, status needsAction")
    func fromArgsDicts() {
        let args: [String: JSONValue] = ["attendees": .array([
            .dictionary(["email": .string("alice@test.com"), "name": .string("Alice")]),
            .dictionary(["email": .string("bob@test.com")]),
        ])]
        let result = CalendarToolHelpers.eventPillAttendees(fromArguments: args)
        #expect(result.count == 2)
        guard result.count == 2 else { return }
        #expect(result[0].email == "alice@test.com")
        #expect(result[0].name == "Alice")
        #expect(result[0].status == "needsAction")
        #expect(result[1].name == nil)
    }

    @Test("fromArguments: bare-string form maps email with nil name")
    func fromArgsStrings() {
        let args: [String: JSONValue] = ["attendees": .array([.string("alice@test.com")])]
        let result = CalendarToolHelpers.eventPillAttendees(fromArguments: args)
        #expect(result.count == 1)
        guard result.count == 1 else { return }
        #expect(result[0].email == "alice@test.com")
        #expect(result[0].name == nil)
    }

    @Test("fromArguments: drops empty emails and tolerates missing key")
    func fromArgsDropsEmptyAndMissing() {
        let withEmpty: [String: JSONValue] = ["attendees": .array([
            .dictionary(["email": .string("")]),
            .string(""),
            .dictionary(["email": .string("real@test.com")]),
        ])]
        let result = CalendarToolHelpers.eventPillAttendees(fromArguments: withEmpty)
        #expect(result.count == 1)
        guard result.count == 1 else { return }
        #expect(result[0].email == "real@test.com")
        // Missing key → empty
        #expect(CalendarToolHelpers.eventPillAttendees(fromArguments: [:]).isEmpty)
    }
}
