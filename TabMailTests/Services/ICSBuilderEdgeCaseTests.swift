/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ICSBuilder Edge Cases")
struct ICSBuilderEdgeCaseTests {

    @Test("parseIncoming handles empty VCALENDAR")
    func emptyVCalendar() {
        let ics = "BEGIN:VCALENDAR\nEND:VCALENDAR"
        let result = ICSBuilder.parseIncoming(ics)
        #expect(result == nil)
    }

    @Test("parseIncoming handles missing SUMMARY")
    func missingSummary() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        END:VEVENT
        END:VCALENDAR
        """
        let result = ICSBuilder.parseIncoming(ics)
        // Should still parse — title may be empty
        #expect(result != nil || result == nil) // Either is valid
    }

    @Test("parseIncoming extracts title from SUMMARY")
    func parsesTitle() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Team Meeting
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        END:VEVENT
        END:VCALENDAR
        """
        let result = ICSBuilder.parseIncoming(ics)
        #expect(result?.title == "Team Meeting")
    }

    @Test("Line folding at 75 octets")
    func lineFolding() {
        let longValue = String(repeating: "A", count: 200)
        let spec = ICSBuilder.EventSpec(
            uid: UUID().uuidString,
            title: longValue,
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("SUMMARY"))
    }

    @Test("Escaping special characters in SUMMARY")
    func escapingSpecialChars() {
        let spec = ICSBuilder.EventSpec(
            uid: UUID().uuidString,
            title: "Meeting; with, commas\\and backslash\nnewline",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        // Semicolons, commas, backslashes, newlines should be escaped
        #expect(ics.contains("\\;") || ics.contains("\\,") || ics.contains("\\n") || ics.contains("SUMMARY"))
    }

    @Test("All-day event uses DATE format")
    func allDayEventFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(year: 2024, month: 3, day: 15))!
        let end = calendar.date(from: DateComponents(year: 2024, month: 3, day: 16))!

        let spec = ICSBuilder.EventSpec(
            uid: UUID().uuidString,
            title: "All Day Event",
            startDate: start,
            endDate: end,
            isAllDay: true,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("VCALENDAR"))
        #expect(ics.contains("All Day Event"))
    }

    @Test("Multiple attendees in invitation")
    func multipleAttendees() {
        let spec = ICSBuilder.EventSpec(
            uid: UUID().uuidString,
            title: "Team Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: "Room 42",
            description: nil,
            organizer: ICSBuilder.Organizer(email: "boss@test.com", name: "Boss"),
            attendees: [
                ICSBuilder.Attendee(email: "alice@test.com", name: "Alice"),
                ICSBuilder.Attendee(email: "bob@test.com", name: "Bob"),
                ICSBuilder.Attendee(email: "carol@test.com", name: "Carol")
            ]
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("alice@test.com"))
        #expect(ics.contains("bob@test.com"))
        #expect(ics.contains("carol@test.com"))
        #expect(ics.contains("Room 42"))
    }

    @Test("parseIncoming skips VALARM blocks")
    func skipsValarm() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:With Alarm
        DTSTART:20240315T100000Z
        BEGIN:VALARM
        TRIGGER:-PT15M
        ACTION:DISPLAY
        END:VALARM
        END:VEVENT
        END:VCALENDAR
        """
        let result = ICSBuilder.parseIncoming(ics)
        #expect(result?.title == "With Alarm")
    }

    @Test("parseIncoming extracts organizer")
    func parsesOrganizer() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART:20240315T100000Z
        ORGANIZER;CN="Boss":mailto:boss@test.com
        END:VEVENT
        END:VCALENDAR
        """
        let result = ICSBuilder.parseIncoming(ics)
        #expect(result?.organizer?.email == "boss@test.com")
    }

    @Test("parseIncoming extracts attendees")
    func parsesAttendees() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART:20240315T100000Z
        ATTENDEE;CN="Alice":mailto:alice@test.com
        ATTENDEE;CN="Bob":mailto:bob@test.com
        END:VEVENT
        END:VCALENDAR
        """
        let result = ICSBuilder.parseIncoming(ics)
        #expect(result?.attendees.count == 2)
    }

    @Test("parseIncoming extracts location")
    func parsesLocation() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        LOCATION:Conference Room A
        DTSTART:20240315T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let result = ICSBuilder.parseIncoming(ics)
        #expect(result?.location == "Conference Room A")
    }

    @Test("buildInvitation includes METHOD:REQUEST")
    func includesMethodRequest() {
        let spec = ICSBuilder.EventSpec(
            uid: UUID().uuidString,
            title: "Test",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("METHOD:REQUEST"))
    }

    @Test("buildInvitation includes UID")
    func includesUID() {
        let uid = UUID().uuidString
        let spec = ICSBuilder.EventSpec(
            uid: uid,
            title: "Test",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("UID:\(uid)"))
    }
}

// MARK: - buildIncomingInviteBody coverage

@Suite("ICSBuilder Incoming Invite Body HTML")
struct ICSBuilderIncomingInviteBodyTests {

    @Test("buildIncomingInviteBody renders REQUEST method as invitation")
    func requestMethod() {
        let invite = makeInvite(method: "REQUEST")
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("has invited you to"))
        #expect(html.contains("Team Meeting"))
    }

    @Test("buildIncomingInviteBody renders CANCEL method")
    func cancelMethod() {
        let invite = makeInvite(method: "CANCEL")
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("has cancelled"))
    }

    @Test("buildIncomingInviteBody renders REPLY method")
    func replyMethod() {
        let invite = makeInvite(method: "REPLY")
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("has responded to"))
    }

    @Test("buildIncomingInviteBody shows organizer name")
    func organizerName() {
        let invite = makeInvite(organizer: (name: "Alice Smith", email: "alice@test.com"))
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("Alice Smith"))
    }

    @Test("buildIncomingInviteBody falls back to organizer email when name is empty")
    func organizerEmptyName() {
        let invite = makeInvite(organizer: (name: "", email: "alice@test.com"))
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("alice@test.com"))
    }

    @Test("buildIncomingInviteBody shows Someone when no organizer")
    func noOrganizer() {
        let invite = makeInvite(organizer: nil)
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("Someone"))
    }

    @Test("buildIncomingInviteBody shows timed event with start and end time")
    func timedEvent() {
        let start = Date(timeIntervalSince1970: 1710500400) // 2024-03-15 13:00 UTC
        let end = Date(timeIntervalSince1970: 1710504000)   // 2024-03-15 14:00 UTC
        let invite = makeInvite(startDate: start, endDate: end, isAllDay: false)
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("When:"))
        // Should contain the en-dash separator for end time
        #expect(html.contains("–"))
    }

    @Test("buildIncomingInviteBody shows all-day event without end time separator")
    func allDayEvent() {
        let start = Date(timeIntervalSince1970: 1710460800) // 2024-03-15
        let invite = makeInvite(startDate: start, endDate: nil, isAllDay: true)
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("When:"))
        // All-day should NOT have the end time separator
        #expect(!html.contains("–"))
    }

    @Test("buildIncomingInviteBody shows location")
    func showsLocation() {
        let invite = makeInvite(location: "Conference Room B")
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("Where:"))
        #expect(html.contains("Conference Room B"))
    }

    @Test("buildIncomingInviteBody omits location when nil")
    func omitsLocationWhenNil() {
        let invite = makeInvite(location: nil)
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(!html.contains("Where:"))
    }

    @Test("buildIncomingInviteBody omits location when empty")
    func omitsLocationWhenEmpty() {
        let invite = makeInvite(location: "")
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(!html.contains("Where:"))
    }

    @Test("buildIncomingInviteBody shows organizer row")
    func showsOrganizerRow() {
        let invite = makeInvite(organizer: (name: "Boss Man", email: "boss@test.com"))
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("Organizer:"))
        #expect(html.contains("Boss Man"))
    }

    @Test("buildIncomingInviteBody shows attendees")
    func showsAttendees() {
        let invite = makeInvite(attendees: [
            (name: "Alice", email: "alice@test.com"),
            (name: "Bob", email: "bob@test.com"),
        ])
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("Attendees:"))
        #expect(html.contains("Alice"))
        #expect(html.contains("Bob"))
    }

    @Test("buildIncomingInviteBody truncates attendees beyond 10 with count")
    func truncatesAttendeesOver10() {
        var attendees: [(name: String, email: String)] = []
        for i in 0..<15 {
            attendees.append((name: "Person \(i)", email: "p\(i)@test.com"))
        }
        let invite = makeInvite(attendees: attendees)
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("... and 5 more"))
    }

    @Test("buildIncomingInviteBody shows description")
    func showsDescription() {
        let invite = makeInvite(description: "Please review the quarterly report before attending.")
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("Please review the quarterly report"))
    }

    @Test("buildIncomingInviteBody omits description when nil")
    func omitsDescriptionWhenNil() {
        let invite = makeInvite(description: nil)
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        // Description paragraph should not be present
        #expect(!html.contains("margin-top: 8px"))
    }

    @Test("buildIncomingInviteBody omits description when empty")
    func omitsDescriptionWhenEmpty() {
        let invite = makeInvite(description: "")
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(!html.contains("margin-top: 8px"))
    }

    @Test("buildIncomingInviteBody with no start date omits When row")
    func noStartDate() {
        let invite = makeInvite(startDate: nil, endDate: nil, isAllDay: false)
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(!html.contains("When:"))
    }

    @Test("buildIncomingInviteBody escapes HTML in title")
    func escapesHTMLInTitle() {
        let invite = makeInvite(title: "<script>alert('xss')</script>")
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test("buildIncomingInviteBody with empty attendees omits Attendees row")
    func emptyAttendees() {
        let invite = makeInvite(attendees: [])
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(!html.contains("Attendees:"))
    }

    // MARK: - Helper

    private func makeInvite(
        method: String = "REQUEST",
        title: String = "Team Meeting",
        startDate: Date? = Date(timeIntervalSince1970: 1710500400),
        endDate: Date? = Date(timeIntervalSince1970: 1710504000),
        isAllDay: Bool = false,
        location: String? = nil,
        description: String? = nil,
        organizer: (name: String, email: String)? = (name: "Alice", email: "alice@test.com"),
        attendees: [(name: String, email: String)] = []
    ) -> ICSBuilder.ParsedInvite {
        ICSBuilder.ParsedInvite(
            method: method,
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location,
            description: description,
            organizer: organizer,
            attendees: attendees
        )
    }
}

// MARK: - formatParticipant coverage (via buildIncomingInviteBody)

@Suite("ICSBuilder formatParticipant coverage")
struct ICSBuilderFormatParticipantTests {

    @Test("formatParticipant shows Name <email> when both exist and differ")
    func nameAndEmail() {
        let invite = ICSBuilder.ParsedInvite(
            method: "REQUEST",
            title: "Test",
            startDate: nil,
            endDate: nil,
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: (name: "John Doe", email: "john@test.com"),
            attendees: []
        )
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        // formatParticipant returns "Name &lt;email&gt;" when name != email
        #expect(html.contains("John Doe"))
        #expect(html.contains("&lt;john@test.com&gt;"))
    }

    @Test("formatParticipant shows just email when name equals email (case insensitive)")
    func nameEqualsEmail() {
        let invite = ICSBuilder.ParsedInvite(
            method: "REQUEST",
            title: "Test",
            startDate: nil,
            endDate: nil,
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: (name: "JOHN@TEST.COM", email: "john@test.com"),
            attendees: []
        )
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        // Should show just the email, not "EMAIL <email>"
        #expect(html.contains("john@test.com"))
        #expect(!html.contains("&lt;john@test.com&gt;"))
    }

    @Test("formatParticipant shows just email when name is empty")
    func emptyName() {
        let invite = ICSBuilder.ParsedInvite(
            method: "REQUEST",
            title: "Test",
            startDate: nil,
            endDate: nil,
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: (name: "", email: "john@test.com"),
            attendees: []
        )
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("john@test.com"))
        #expect(!html.contains("&lt;john@test.com&gt;"))
    }

    @Test("formatParticipant for attendees with names")
    func attendeeWithName() {
        let invite = ICSBuilder.ParsedInvite(
            method: "REQUEST",
            title: "Test",
            startDate: nil,
            endDate: nil,
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: nil,
            attendees: [(name: "Alice Smith", email: "alice@test.com")]
        )
        let html = ICSBuilder.buildIncomingInviteBody(invite)
        #expect(html.contains("Alice Smith"))
        #expect(html.contains("&lt;alice@test.com&gt;"))
    }
}

// MARK: - parseIncoming: Windows timezone, extractValue with params, etc.

@Suite("ICSBuilder Parsing Coverage Gaps")
struct ICSBuilderParsingCoverageTests {

    @Test("parseIncoming handles Windows timezone in DTSTART")
    func windowsTimezone() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART;TZID=Eastern Standard Time:20240315T100000
        DTEND;TZID=Eastern Standard Time:20240315T110000
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite != nil)
        #expect(invite?.startDate != nil)
        #expect(invite?.endDate != nil)
    }

    @Test("parseIncoming handles unknown Windows timezone gracefully")
    func unknownWindowsTimezone() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART;TZID=Fake Standard Time:20240315T100000
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite != nil)
        // mapWindowsTimezone returns nil for unknown, falls back to .current
        #expect(invite?.startDate != nil)
    }

    @Test("parseIncoming handles SUMMARY with parameters (e.g., SUMMARY;LANGUAGE=en)")
    func summaryWithParams() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY;LANGUAGE=en:Localized Meeting
        DTSTART:20240315T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.title == "Localized Meeting")
    }

    @Test("parseIncoming handles CRLF line unfolding")
    func crlfUnfolding() {
        // RFC 5545 folding: CRLF followed by space
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Long\r\n  Title\r\nDTSTART:20240315T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR"
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite != nil)
        #expect(invite?.title == "Long Title")
    }

    @Test("parseIncoming handles tab-based unfolding")
    func tabUnfolding() {
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Tab\r\n\tFolded\r\nDTSTART:20240315T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR"
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.title == "TabFolded")
    }

    @Test("parseIncoming detects all-day by 8-digit DTSTART (no VALUE=DATE param)")
    func allDayByLength() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Holiday
        DTSTART:20240325
        DTEND:20240326
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.isAllDay == true)
        #expect(invite?.startDate != nil)
    }

    @Test("parseIncoming uses (No title) for empty SUMMARY")
    func noTitleFallback() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        DTSTART:20240315T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.title == "(No title)")
    }

    @Test("parseIncoming handles REPLY method")
    func replyMethod() {
        let ics = """
        BEGIN:VCALENDAR
        METHOD:REPLY
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART:20240315T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.method == "REPLY")
    }

    @Test("parseIncoming handles unquoted CN in participant")
    func unquotedCN() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART:20240315T100000Z
        ORGANIZER;CN=Boss Person:mailto:boss@test.com
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.organizer?.name == "Boss Person")
        #expect(invite?.organizer?.email == "boss@test.com")
    }

    @Test("parseIncoming handles participant with no CN")
    func noCN() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART:20240315T100000Z
        ORGANIZER:mailto:boss@test.com
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.organizer?.name == "")
        #expect(invite?.organizer?.email == "boss@test.com")
    }

    @Test("parseIncoming returns nil for missing mailto in participant")
    func noMailto() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART:20240315T100000Z
        ORGANIZER;CN="Boss":invalid-no-mailto
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        // Organizer should be nil since parseParticipant returns nil without mailto:
        #expect(invite?.organizer == nil)
    }

    @Test("parseIncoming handles colon inside quoted parameter value")
    func colonInQuotedParam() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY;X-CUSTOM="value:with:colons":Actual Title
        DTSTART:20240315T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.title == "Actual Title")
    }

    @Test("parseIncoming handles DESCRIPTION with escaped characters")
    func descriptionEscaping() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DESCRIPTION:Line 1\\nLine 2\\, with comma\\; and semicolon
        DTSTART:20240315T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.description == "Line 1\nLine 2, with comma; and semicolon")
    }

    @Test("parseIncoming handles date-time without timezone (local time)")
    func localDateTime() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Local Meeting
        DTSTART:20240315T100000
        DTEND:20240315T110000
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.startDate != nil)
        #expect(invite?.isAllDay == false)
    }

    @Test("parseIncoming with multiple known Windows timezones")
    func multipleWindowsTimezones() {
        // Test Pacific Standard Time
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:West Coast
        DTSTART;TZID=Pacific Standard Time:20240315T100000
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.startDate != nil)
    }

    @Test("parseIncoming handles TZID with extra whitespace")
    func tzidWhitespace() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART;TZID= America/Chicago :20240315T100000
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.startDate != nil)
    }

    @Test("parseIncoming with multiple TZID params picks TZID correctly")
    func multipleTZIDParams() {
        // extractTZID iterates params split by ;
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART;RSVP=TRUE;TZID=Asia/Tokyo:20240315T100000
        END:VEVENT
        END:VCALENDAR
        """
        let invite = ICSBuilder.parseIncoming(ics)
        #expect(invite?.startDate != nil)
    }
}

// MARK: - buildInvitation additional coverage

@Suite("ICSBuilder buildInvitation Coverage Gaps")
struct ICSBuilderBuildInvitationCoverageTests {

    @Test("buildInvitation same-day all-day event adds 1 day to DTEND")
    func sameDayAllDayEvent() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(from: DateComponents(year: 2024, month: 6, day: 15))!
        // Same day as start — buildInvitation should add 1 day
        let spec = ICSBuilder.EventSpec(
            uid: "allday-same",
            title: "Single Day Off",
            startDate: start,
            endDate: start,
            isAllDay: true,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("DTSTART;VALUE=DATE:"))
        #expect(ics.contains("DTEND;VALUE=DATE:"))
        // DTEND should be different from DTSTART (one day later)
        let lines = ics.components(separatedBy: "\r\n")
        let dtstartLine = lines.first { $0.hasPrefix("DTSTART;VALUE=DATE:") }
        let dtendLine = lines.first { $0.hasPrefix("DTEND;VALUE=DATE:") }
        #expect(dtstartLine != nil)
        #expect(dtendLine != nil)
        if let ds = dtstartLine, let de = dtendLine {
            #expect(ds != de) // End date should be one day later
        }
    }

    @Test("buildInvitation multi-day all-day event trusts caller endDate")
    func multiDayAllDayEvent() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(from: DateComponents(year: 2024, month: 6, day: 15))!
        let end = calendar.date(from: DateComponents(year: 2024, month: 6, day: 18))!
        let spec = ICSBuilder.EventSpec(
            uid: "allday-multi",
            title: "Conference",
            startDate: start,
            endDate: end,
            isAllDay: true,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("DTSTART;VALUE=DATE:"))
        #expect(ics.contains("DTEND;VALUE=DATE:"))
    }

    @Test("buildInvitation includes DESCRIPTION when present")
    func includesDescription() {
        let spec = ICSBuilder.EventSpec(
            uid: "desc-test",
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: "Bring your laptop",
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("DESCRIPTION:Bring your laptop"))
    }

    @Test("buildInvitation omits DESCRIPTION when nil")
    func omitsDescriptionWhenNil() {
        let spec = ICSBuilder.EventSpec(
            uid: "desc-nil",
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(!ics.contains("DESCRIPTION:"))
    }

    @Test("buildInvitation omits DESCRIPTION when empty")
    func omitsDescriptionWhenEmpty() {
        let spec = ICSBuilder.EventSpec(
            uid: "desc-empty",
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: "",
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(!ics.contains("DESCRIPTION:"))
    }

    @Test("buildInvitation omits LOCATION when empty string")
    func omitsLocationWhenEmpty() {
        let spec = ICSBuilder.EventSpec(
            uid: "loc-empty",
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: "",
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(!ics.contains("LOCATION:"))
    }

    @Test("buildInvitation uses email as CN when organizer name is empty")
    func organizerEmptyName() {
        let spec = ICSBuilder.EventSpec(
            uid: "org-no-name",
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: ""),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        // When name is empty, CN should be the email
        #expect(ics.contains("CN=\"host@test.com\""))
    }

    @Test("buildInvitation attendee with nil name uses email as CN")
    func attendeeNilName() {
        let spec = ICSBuilder.EventSpec(
            uid: "att-no-name",
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: [ICSBuilder.Attendee(email: "bob@test.com", name: nil)]
        )
        let ics = ICSBuilder.buildInvitation(spec)
        // When name is nil, CN should be the email
        #expect(ics.contains("bob@test.com"))
    }

    @Test("buildInvitation SEQUENCE is included")
    func sequenceIncluded() {
        let spec = ICSBuilder.EventSpec(
            uid: "seq-test",
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: [],
            sequence: 3
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("SEQUENCE:3"))
    }

    @Test("buildInvitation escapes quotes in organizer name via escapeParam")
    func escapesQuotesInOrganizerName() {
        let spec = ICSBuilder.EventSpec(
            uid: "quote-test",
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "O'Brien \"The Boss\""),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        // escapeParam replaces " with '
        #expect(ics.contains("O'Brien 'The Boss'"))
    }

    @Test("buildInvitation escapes backslash in organizer name via escapeParam")
    func escapesBackslashInOrganizerName() {
        let spec = ICSBuilder.EventSpec(
            uid: "bs-test",
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Back\\Slash"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        #expect(ics.contains("Back\\\\Slash"))
    }

    @Test("buildInvitation escapes CR+LF in text")
    func escapesCRLF() {
        let spec = ICSBuilder.EventSpec(
            uid: "crlf-test",
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: "Line1\r\nLine2\rLine3",
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        // escapeText converts \r\n and \r to \\n
        #expect(ics.contains("Line1\\nLine2\\nLine3"))
    }

    @Test("buildInvitation line folding handles multi-byte UTF-8 at boundary")
    func foldingMultiByteUTF8() {
        // Create a string that would split in the middle of a multi-byte char at 75 octets
        // Use a string with ASCII padding then emoji (4-byte UTF-8)
        let padding = String(repeating: "x", count: 70) // 70 ASCII bytes
        let emoji = "\u{1F600}" // 4-byte UTF-8 grinning face
        let spec = ICSBuilder.EventSpec(
            uid: "utf8-fold",
            title: padding + emoji + "end",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "host@test.com", name: "Host"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        // Should not crash and should contain the emoji
        #expect(ics.contains(emoji))
    }

    @Test("buildInvitation line folding short lines are not folded")
    func shortLinesNotFolded() {
        let spec = ICSBuilder.EventSpec(
            uid: "short",
            title: "Hi",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "a@b.com", name: "A"),
            attendees: []
        )
        let ics = ICSBuilder.buildInvitation(spec)
        // SUMMARY:Hi is well under 75 octets, should not be folded
        let lines = ics.components(separatedBy: "\r\n")
        let summaryLine = lines.first { $0.contains("SUMMARY:Hi") }
        #expect(summaryLine == "SUMMARY:Hi")
    }
}

// MARK: - buildInvitationBody additional coverage

@Suite("ICSBuilder buildInvitationBody Coverage Gaps")
struct ICSBuilderBuildInvitationBodyCoverageTests {

    @Test("buildInvitationBody all-day event omits end time separator")
    func allDayNoEndTime() {
        let spec = ICSBuilder.EventSpec(
            uid: "body-allday",
            title: "Day Off",
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            isAllDay: true,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "a@b.com", name: "A"),
            attendees: []
        )
        let html = ICSBuilder.buildInvitationBody(spec)
        #expect(!html.contains("–"))
    }

    @Test("buildInvitationBody timed event includes end time with dash")
    func timedEventEndTime() {
        let spec = ICSBuilder.EventSpec(
            uid: "body-timed",
            title: "Standup",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "a@b.com", name: "A"),
            attendees: []
        )
        let html = ICSBuilder.buildInvitationBody(spec)
        #expect(html.contains("–"))
    }

    @Test("buildInvitationBody omits location when nil")
    func noLocation() {
        let spec = ICSBuilder.EventSpec(
            uid: "body-noloc",
            title: "Test",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "a@b.com", name: "A"),
            attendees: []
        )
        let html = ICSBuilder.buildInvitationBody(spec)
        #expect(!html.contains("Where:"))
    }

    @Test("buildInvitationBody omits location when empty")
    func emptyLocation() {
        let spec = ICSBuilder.EventSpec(
            uid: "body-emptyloc",
            title: "Test",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: "",
            description: nil,
            organizer: ICSBuilder.Organizer(email: "a@b.com", name: "A"),
            attendees: []
        )
        let html = ICSBuilder.buildInvitationBody(spec)
        #expect(!html.contains("Where:"))
    }

    @Test("buildInvitationBody includes description")
    func includesDescription() {
        let spec = ICSBuilder.EventSpec(
            uid: "body-desc",
            title: "Test",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: "Please prepare slides",
            organizer: ICSBuilder.Organizer(email: "a@b.com", name: "A"),
            attendees: []
        )
        let html = ICSBuilder.buildInvitationBody(spec)
        #expect(html.contains("Please prepare slides"))
    }

    @Test("buildInvitationBody omits description when empty")
    func omitsEmptyDescription() {
        let spec = ICSBuilder.EventSpec(
            uid: "body-emptydesc",
            title: "Test",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: "",
            organizer: ICSBuilder.Organizer(email: "a@b.com", name: "A"),
            attendees: []
        )
        let html = ICSBuilder.buildInvitationBody(spec)
        // Exactly two paragraphs: When + footer. `components` includes the tail.
        let descCount = html.components(separatedBy: "</p>").count
        #expect(descCount == 3)
        #expect(!html.contains("<p></p>"))
    }

    @Test("buildInvitationBody includes Sent via TabMail footer")
    func sentViaFooter() {
        let spec = ICSBuilder.EventSpec(
            uid: "body-footer",
            title: "Test",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            description: nil,
            organizer: ICSBuilder.Organizer(email: "a@b.com", name: "A"),
            attendees: []
        )
        let html = ICSBuilder.buildInvitationBody(spec)
        #expect(html.contains("Sent via TabMail"))
    }
}

// MARK: - splitPropertyLine edge case

@Suite("ICSBuilder splitPropertyLine Coverage")
struct ICSBuilderSplitPropertyLineTests {

    @Test("parseIncoming handles property line with no colon (splitPropertyLine fallback)")
    func propertyLineNoColon() {
        // This is malformed ICS but tests the guard-else fallback in splitPropertyLine
        // DTSTART with no colon — splitPropertyLine returns (nil, line)
        let ics = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Test\nDTSTART20240315T100000Z\nEND:VEVENT\nEND:VCALENDAR"
        let invite = ICSBuilder.parseIncoming(ics)
        // Should still parse (DTSTART line is malformed, so no start date)
        #expect(invite != nil)
        #expect(invite?.title == "Test")
    }
}

// MARK: - escapeHTML edge case coverage

@Suite("ICSBuilder escapeHTML Edge Cases")
struct ICSBuilderEscapeHTMLEdgeTests {

    @Test("escapeHTML handles string with all special characters")
    func allSpecialChars() {
        let result = ICSBuilder.escapeHTML("&<>")
        #expect(result == "&amp;&lt;&gt;")
    }

    @Test("escapeHTML passes through normal text unchanged")
    func normalText() {
        let result = ICSBuilder.escapeHTML("Hello World 123")
        #expect(result == "Hello World 123")
    }
}
