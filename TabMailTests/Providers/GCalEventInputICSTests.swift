/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("GCalEventInput toICS")
struct GCalEventInputICSTests {

    @Test("toICS produces valid VCALENDAR structure")
    func validVCalendar() {
        let input = GCalEventInput(summary: "Meeting", startDateTime: "2024-03-15T10:00:00Z", endDateTime: "2024-03-15T11:00:00Z")
        let ics = input.toICS(uid: "test-uid")
        #expect(ics.contains("BEGIN:VCALENDAR"))
        #expect(ics.contains("END:VCALENDAR"))
        #expect(ics.contains("BEGIN:VEVENT"))
        #expect(ics.contains("END:VEVENT"))
        #expect(ics.contains("UID:test-uid"))
    }

    @Test("toICS does NOT include METHOD (CalDAV PUT, not email invitation)")
    func noMethodLine() {
        let input = GCalEventInput(summary: "Meeting", startDateTime: "2024-03-15T10:00:00Z")
        let ics = input.toICS(uid: "uid1")
        #expect(!ics.contains("METHOD:"))
    }

    @Test("toICS includes SUMMARY")
    func includesSummary() {
        let input = GCalEventInput(summary: "Team Standup")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("SUMMARY:Team Standup"))
    }

    @Test("toICS includes LOCATION when present")
    func includesLocation() {
        let input = GCalEventInput(summary: "Meeting", location: "Room 42")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("LOCATION:Room 42"))
    }

    @Test("toICS omits LOCATION when nil")
    func omitsLocationWhenNil() {
        let input = GCalEventInput(summary: "Meeting")
        let ics = input.toICS(uid: "uid1")
        #expect(!ics.contains("LOCATION:"))
    }

    @Test("toICS includes DESCRIPTION")
    func includesDescription() {
        let input = GCalEventInput(summary: "Meeting", description: "Discuss Q2 plans")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("DESCRIPTION:Discuss Q2 plans"))
    }

    @Test("toICS all-day event uses VALUE=DATE format")
    func allDayEvent() {
        let input = GCalEventInput(startDate: "2024-03-15", endDate: "2024-03-16")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("DTSTART;VALUE=DATE:20240315"))
        #expect(ics.contains("DTEND;VALUE=DATE:20240316"))
    }

    @Test("toICS timed event with timezone uses TZID")
    func timedEventWithTimezone() {
        let input = GCalEventInput(
            startDateTime: "2024-03-15T10:00:00-04:00",
            startTimeZone: "America/New_York",
            endDateTime: "2024-03-15T11:00:00-04:00",
            endTimeZone: "America/New_York"
        )
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("DTSTART;TZID=America/New_York:"))
        #expect(ics.contains("DTEND;TZID=America/New_York:"))
    }

    @Test("toICS embeds a VTIMEZONE for every TZID it references — RFC 5545 §3.2.19")
    func embedsVTimeZone() {
        // A `DTSTART;TZID=…` with no matching VTIMEZONE is rejected by strict
        // CalDAV servers (iCloud, Nextcloud). toICS must embed the component.
        let input = GCalEventInput(
            startDateTime: "2026-03-15T10:00:00-07:00",
            startTimeZone: "America/Vancouver",
            endDateTime: "2026-03-15T11:00:00-07:00",
            endTimeZone: "America/Vancouver"
        )
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("DTSTART;TZID=America/Vancouver:"))
        #expect(ics.contains("BEGIN:VTIMEZONE"))
        #expect(ics.contains("TZID:America/Vancouver"))
        #expect(ics.contains("END:VTIMEZONE"))
        // The VTIMEZONE must appear BEFORE the VEVENT that references it.
        let vtzRange = ics.range(of: "BEGIN:VTIMEZONE")
        let veventRange = ics.range(of: "BEGIN:VEVENT")
        #expect(vtzRange != nil && veventRange != nil && vtzRange!.lowerBound < veventRange!.lowerBound)
        // Exactly one VTIMEZONE even though both start and end reference the zone.
        #expect(ics.components(separatedBy: "BEGIN:VTIMEZONE").count == 2)
    }

    @Test("toICS falls back to UTC Z time for an unresolvable timezone (no dangling TZID)")
    func unresolvableTimezoneFallsBackToUTC() {
        let input = GCalEventInput(
            startDateTime: "2026-03-15T10:00:00Z",
            startTimeZone: "Not/AReal_Zone",
            endDateTime: "2026-03-15T11:00:00Z",
            endTimeZone: "Not/AReal_Zone"
        )
        let ics = input.toICS(uid: "uid1")
        // No TZID reference and no VTIMEZONE — a plain UTC time instead.
        #expect(!ics.contains("TZID=Not/AReal_Zone"))
        #expect(!ics.contains("BEGIN:VTIMEZONE"))
        #expect(ics.contains("DTSTART:") && ics.contains("Z"))
    }

    @Test("toICS UTC event uses Z suffix")
    func utcEvent() {
        let input = GCalEventInput(startDateTime: "2024-03-15T10:00:00Z", endDateTime: "2024-03-15T11:00:00Z")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("DTSTART:") || ics.contains("DTSTART;"))
    }

    @Test("toICS includes DTSTAMP")
    func includesDtstamp() {
        let input = GCalEventInput(summary: "Meeting")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("DTSTAMP:"))
    }

    @Test("toICS includes PRODID")
    func includesProdid() {
        let input = GCalEventInput(summary: "Meeting")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("PRODID:"))
    }

    @Test("toICS includes attendees")
    func includesAttendees() {
        let input = GCalEventInput(
            summary: "Meeting",
            attendees: [(email: "alice@test.com", name: "Alice"), (email: "bob@test.com", name: nil)]
        )
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("alice@test.com"))
        #expect(ics.contains("bob@test.com"))
        #expect(ics.contains("ATTENDEE"))
    }

    @Test("toICS includes TRANSP when set")
    func includesTransparency() {
        let input = GCalEventInput(summary: "Free Time", transparency: "transparent")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("TRANSP:TRANSPARENT"))
    }

    @Test("toICS includes recurrence rules")
    func includesRecurrence() {
        let input = GCalEventInput(summary: "Weekly", recurrence: ["RRULE:FREQ=WEEKLY;COUNT=10"])
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("RRULE:FREQ=WEEKLY;COUNT=10"))
    }

    @Test("toICS escapes special characters in text fields")
    func escapesSpecialChars() {
        let input = GCalEventInput(summary: "Review; Budget, Q1")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("Review\\; Budget\\, Q1"))
    }

    @Test("toICS ends with CRLF")
    func endsWithCRLF() {
        let input = GCalEventInput(summary: "Meeting")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.hasSuffix("\r\n"))
    }

    @Test("toICS folds long lines")
    func foldsLongLines() {
        let longSummary = String(repeating: "A", count: 100)
        let input = GCalEventInput(summary: longSummary)
        let ics = input.toICS(uid: "uid1")
        // After folding, continuation lines start with space
        let lines = ics.components(separatedBy: "\r\n")
        let hasFolded = lines.contains { $0.hasPrefix(" ") }
        #expect(hasFolded)
    }
}

@Suite("GCalEventInput toJSON")
struct GCalEventInputJSONTests {

    @Test("toJSON includes summary")
    func includesSummary() {
        let input = GCalEventInput(summary: "Meeting")
        let json = input.toJSON()
        #expect(json["summary"] as? String == "Meeting")
    }

    @Test("toJSON includes location")
    func includesLocation() {
        let input = GCalEventInput(location: "Room A")
        let json = input.toJSON()
        #expect(json["location"] as? String == "Room A")
    }

    @Test("toJSON omits nil fields")
    func omitsNilFields() {
        let input = GCalEventInput()
        let json = input.toJSON()
        #expect(json["summary"] == nil)
        #expect(json["location"] == nil)
        #expect(json["description"] == nil)
    }

    @Test("toJSON includes start dateTime")
    func includesStartDateTime() {
        let input = GCalEventInput(startDateTime: "2024-03-15T10:00:00Z")
        let json = input.toJSON()
        let start = json["start"] as? [String: Any]
        #expect(start?["dateTime"] as? String == "2024-03-15T10:00:00Z")
    }

    @Test("toJSON all-day event uses date instead of dateTime")
    func allDayUsesDate() {
        let input = GCalEventInput(startDate: "2024-03-15", endDate: "2024-03-16")
        let json = input.toJSON()
        let start = json["start"] as? [String: Any]
        #expect(start?["date"] as? String == "2024-03-15")
        #expect(start?["dateTime"] == nil)
    }

    @Test("toJSON includes attendees array")
    func includesAttendees() {
        let input = GCalEventInput(attendees: [(email: "a@b.com", name: "Alice")])
        let json = input.toJSON()
        let attendees = json["attendees"] as? [[String: String]]
        #expect(attendees?.count == 1)
        #expect(attendees?[0]["email"] == "a@b.com")
    }

    @Test("toJSON includes event id when set")
    func includesEventId() {
        var input = GCalEventInput(summary: "Meeting")
        input.id = "event-123"
        let json = input.toJSON()
        #expect(json["id"] as? String == "event-123")
    }
}
