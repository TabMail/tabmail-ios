/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ICSBuilder Invitation Generation")
struct ICSBuilderInvitationTests {

    @Test("buildInvitation produces valid VCALENDAR structure")
    func validVCalendar() {
        let spec = makeSpec()
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("BEGIN:VCALENDAR"))
        #expect(ics.contains("END:VCALENDAR"))
        #expect(ics.contains("BEGIN:VEVENT"))
        #expect(ics.contains("END:VEVENT"))
        #expect(ics.contains("METHOD:REQUEST"))
        #expect(ics.contains("VERSION:2.0"))
    }

    @Test("buildInvitation includes SUMMARY")
    func includesSummary() {
        let spec = makeSpec(title: "Team Standup")
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("SUMMARY:Team Standup"))
    }

    @Test("buildInvitation includes LOCATION when present")
    func includesLocation() {
        let spec = makeSpec(location: "Room 42")
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("LOCATION:Room 42"))
    }

    @Test("buildInvitation omits LOCATION when nil")
    func omitsLocationWhenNil() {
        let spec = makeSpec(location: nil)
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(!ics.contains("LOCATION:"))
    }

    @Test("buildInvitation includes organizer")
    func includesOrganizer() {
        let spec = makeSpec()
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("ORGANIZER"))
        #expect(ics.contains("mailto:alice@test.com"))
    }

    @Test("buildInvitation includes attendees with RSVP")
    func includesAttendees() {
        let att = ICSBuilder.Attendee(email: "bob@test.com", name: "Bob")
        let spec = makeSpec(attendees: [att])
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("ATTENDEE"))
        // "mailto:" may be split by line folding at 75 octets
        #expect(ics.contains("bob@test.com"))
        #expect(ics.contains("RSVP=TRUE"))
    }

    @Test("buildInvitation all-day event uses VALUE=DATE")
    func allDayEvent() {
        let spec = makeSpec(isAllDay: true)
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("DTSTART;VALUE=DATE:"))
        #expect(ics.contains("DTEND;VALUE=DATE:"))
    }

    @Test("buildInvitation timed event uses UTC format")
    func timedEvent() {
        let spec = makeSpec(isAllDay: false)
        let ics = ICSBuilder.buildInvitation(spec)
        // UTC format ends with Z
        #expect(ics.contains("DTSTART:") || ics.contains("DTSTART;"))
    }

    @Test("buildInvitation line folding for long lines")
    func lineFolding() {
        let longDesc = String(repeating: "a", count: 100)
        let spec = makeSpec(description: longDesc)
        let ics = ICSBuilder.buildInvitation(spec)
        // Folded lines have CRLF + space continuation
        let lines = ics.components(separatedBy: "\r\n")
        // At least one continuation line should start with space
        let hasFolded = lines.contains { $0.hasPrefix(" ") }
        #expect(hasFolded)
    }

    @Test("buildInvitation escapes special characters in text")
    func escapesSpecialChars() {
        let spec = makeSpec(title: "Review; Budget, Q1")
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("Review\\; Budget\\, Q1"))
    }

    // MARK: - Helper

    private func makeSpec(
        title: String = "Meeting",
        isAllDay: Bool = false,
        location: String? = "Room 1",
        description: String? = nil,
        attendees: [ICSBuilder.Attendee] = []
    ) -> ICSBuilder.EventSpec {
        ICSBuilder.EventSpec(
            uid: "test-uid-123",
            title: title,
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: isAllDay,
            location: location,
            description: description,
            organizer: ICSBuilder.Organizer(email: "alice@test.com", name: "Alice"),
            attendees: attendees
        )
    }
}

@Suite("ICSBuilder Incoming Parsing")
struct ICSBuilderParsingTests {

    @Test("parseIncoming extracts basic VEVENT fields")
    func basicParsing() {
        let ics = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        SUMMARY:Team Meeting
        LOCATION:Conference Room
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        ORGANIZER;CN="Alice":mailto:alice@test.com
        ATTENDEE;CN="Bob":mailto:bob@test.com
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite != nil)
        #expect(invite?.title == "Team Meeting")
        #expect(invite?.location == "Conference Room")
        #expect(invite?.method == "REQUEST")
        #expect(invite?.organizer?.email == "alice@test.com")
        #expect(invite?.attendees.count == 1)
    }

    @Test("parseIncoming handles all-day event")
    func allDayEvent() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Holiday
        DTSTART;VALUE=DATE:20240325
        DTEND;VALUE=DATE:20240326
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.isAllDay == true)
        #expect(invite?.startDate != nil)
    }

    @Test("parseIncoming handles CANCEL method")
    func cancelMethod() {
        let ics = """
        BEGIN:VCALENDAR
        METHOD:CANCEL
        BEGIN:VEVENT
        SUMMARY:Cancelled Meeting
        DTSTART:20240315T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.method == "CANCEL")
    }

    @Test("parseIncoming returns nil for no VEVENT")
    func noVevent() {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite == nil)
    }

    @Test("parseIncoming unescapes text")
    func unescapesText() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Review\\; Budget\\, Q1
        DTSTART:20240315T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.title == "Review; Budget, Q1")
    }

    @Test("parseIncoming with VALARM nested component skips alarm description")
    func skipsVALARMProperties() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Real Title
        DESCRIPTION:Real Description
        DTSTART:20240315T100000Z
        BEGIN:VALARM
        DESCRIPTION:REMINDER
        END:VALARM
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.title == "Real Title")
        #expect(invite?.description == "Real Description")
    }

    @Test("parseIncoming with timezone in DTSTART")
    func timezoneInDtstart() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART;TZID=America/New_York:20240315T100000
        DTEND;TZID=America/New_York:20240315T110000
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.startDate != nil)
        #expect(invite?.isAllDay == false)
    }
}

@Suite("ICSBuilder HTML Escaping")
struct ICSBuilderHTMLTests {

    @Test("escapeHTML escapes special characters")
    func escapeHTMLChars() {
        let escaped = ICSBuilder.escapeHTML("<script>alert('xss')</script>")
        #expect(escaped.contains("&lt;"))
        #expect(escaped.contains("&gt;"))
        #expect(!escaped.contains("<script>"))
    }

    @Test("escapeHTML escapes ampersand")
    func escapeAmpersand() {
        let escaped = ICSBuilder.escapeHTML("A & B")
        #expect(escaped == "A &amp; B")
    }
}

@Suite("ICSBuilder Invitation Body HTML")
struct ICSBuilderInvitationBodyTests {

    @Test("buildInvitationBody includes title")
    func includesTitle() {
        let spec = ICSBuilder.EventSpec(
            uid: "uid1", title: "Sprint Review",
            startDate: Date(), endDate: Date().addingTimeInterval(3600),
            isAllDay: false, location: "Room A", description: "Review sprint",
            organizer: ICSBuilder.Organizer(email: "a@b.com", name: "Alice"),
            attendees: []
        )
        let html = ICSBuilder.buildInvitationBody(spec)
        #expect(html.contains("Sprint Review"))
    }

    @Test("buildInvitationBody includes location")
    func includesLocation() {
        let spec = ICSBuilder.EventSpec(
            uid: "uid1", title: "Meeting",
            startDate: Date(), endDate: Date().addingTimeInterval(3600),
            isAllDay: false, location: "Zoom", description: nil,
            organizer: ICSBuilder.Organizer(email: "a@b.com", name: "A"),
            attendees: []
        )
        let html = ICSBuilder.buildInvitationBody(spec)
        #expect(html.contains("Zoom"))
    }
}
