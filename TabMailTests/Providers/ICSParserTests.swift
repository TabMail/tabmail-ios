/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ICSParser")
struct ICSParserTests {

    @Test("Parse simple VEVENT")
    func parseSimpleEvent() {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:Team Meeting
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        STATUS:CONFIRMED
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/event1.ics", etag: "\"abc\"")
        #expect(events.count == 1)
        #expect(events[0].summary == "Team Meeting")
        #expect(events[0].id == "/cal/event1.ics")
        #expect(events[0].status == "confirmed")
    }

    @Test("Parse VEVENT with location and description")
    func parseWithLocationDescription() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Lunch
        LOCATION:Cafe Downtown
        DESCRIPTION:Discuss Q2 plans
        DTSTART:20240315T120000Z
        DTEND:20240315T130000Z
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/lunch.ics", etag: nil)
        #expect(events.count == 1)
        #expect(events[0].location == "Cafe Downtown")
        #expect(events[0].description == "Discuss Q2 plans")
    }

    @Test("Parse all-day event (VALUE=DATE)")
    func parseAllDayEvent() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Holiday
        DTSTART;VALUE=DATE:20240315
        DTEND;VALUE=DATE:20240316
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/holiday.ics", etag: nil)
        #expect(events.count == 1)
        #expect(events[0].start?.date != nil)
        #expect(events[0].start?.dateTime == nil)
    }

    @Test("Parse VEVENT with attendees")
    func parseWithAttendees() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Review
        DTSTART:20240315T140000Z
        DTEND:20240315T150000Z
        ORGANIZER;CN="Boss":mailto:boss@test.com
        ATTENDEE;CN="Alice";PARTSTAT=ACCEPTED:mailto:alice@test.com
        ATTENDEE;CN="Bob";PARTSTAT=DECLINED:mailto:bob@test.com
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/review.ics", etag: nil)
        #expect(events.count == 1)
        #expect(events[0].organizer?.email == "boss@test.com")
        #expect(events[0].attendees?.count == 2)
        let alice = events[0].attendees?.first { $0.email == "alice@test.com" }
        #expect(alice?.responseStatus == "accepted")
        let bob = events[0].attendees?.first { $0.email == "bob@test.com" }
        #expect(bob?.responseStatus == "declined")
    }

    @Test("Parse CANCELLED event")
    func parseCancelledEvent() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Cancelled
        DTSTART:20240315T100000Z
        STATUS:CANCELLED
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events[0].status == "cancelled")
    }

    @Test("Parse TENTATIVE event")
    func parseTentativeEvent() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Maybe
        DTSTART:20240315T100000Z
        STATUS:TENTATIVE
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events[0].status == "tentative")
    }

    @Test("Parse event with DURATION instead of DTEND")
    func parseDuration() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Quick Chat
        DTSTART:20240315T100000Z
        DURATION:PT30M
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        #expect(events[0].end != nil)
    }

    // SERIES VIEW ONLY (ADR-IOS-108). `ICSParser.parse` is what a read by a series id
    // returns: the series, without its changed occurrences. A LISTING no longer reads
    // through this: it lists each occurrence, changed ones where they now are, via
    // `CalDAVOccurrences.listing`, pinned by `CalDAVOccurrenceExpansionTests`
    // (`movedOverridesAreListedWhereTheyNowAre`, `cancelledOccurrenceIsMarkedCancelled`).
    @Test("Skips RECURRENCE-ID events (exceptions)")
    func skipsRecurrenceExceptions() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Weekly Standup
        DTSTART:20240315T100000Z
        DTEND:20240315T103000Z
        RRULE:FREQ=WEEKLY
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Weekly Standup (moved)
        DTSTART:20240322T110000Z
        DTEND:20240322T113000Z
        RECURRENCE-ID:20240322T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/weekly.ics", etag: nil)
        // Should return master only (no RECURRENCE-ID)
        #expect(events.count == 1)
        #expect(events[0].summary == "Weekly Standup")
    }

    @Test("Unfolds long lines (RFC 5545 line folding)")
    func unfoldsLines() {
        // Line folding: CRLF + leading space is removed, joining lines directly.
        // Original value "Very Long Meeting Name" is folded after "Very Long " (with trailing space).
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Very Long \r\n Meeting Name\r\nDTSTART:20240315T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR"
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        #expect(events[0].summary == "Very Long Meeting Name")
    }

    @Test("Unescapes ICS text")
    func unescapesText() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting\\; Important
        LOCATION:Room 1\\, Floor 2
        DTSTART:20240315T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events[0].summary == "Meeting; Important")
        #expect(events[0].location == "Room 1, Floor 2")
    }

    @Test("Parse event with transparency")
    func parseTransparency() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Free Time
        DTSTART:20240315T100000Z
        TRANSP:TRANSPARENT
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events[0].transparency == "transparent")
    }

    @Test("Parse event with recurrence rules")
    func parseRecurrence() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Daily
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        RRULE:FREQ=DAILY;COUNT=10
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events[0].recurrence != nil)
        #expect(events[0].recurrence?.contains("RRULE:FREQ=DAILY;COUNT=10") == true)
    }

    @Test("Empty VCALENDAR returns empty array")
    func emptyCalendar() {
        let ics = "BEGIN:VCALENDAR\nEND:VCALENDAR"
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.isEmpty)
    }

    @Test("Parse event with TZID on DTSTART")
    func parseTZID() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:NYC Meeting
        DTSTART;TZID=America/New_York:20240315T100000
        DTEND;TZID=America/New_York:20240315T110000
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        #expect(events[0].start?.timeZone == "America/New_York")
    }

    // MARK: - Coverage gap tests

    // SERIES VIEW ONLY (ADR-IOS-108). A read by a series id takes the resource's first
    // VEVENT. A LISTING no longer returns one row per resource: it returns one row per
    // occurrence in the range, pinned by `CalDAVOccurrenceExpansionTests`
    // (`weeklyZonedSeriesKeepsItsWallTimeAcrossDST` and its siblings).
    @Test("Multiple master VEVENTs returns only first")
    func multipleVEventsReturnsFirst() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:First Event
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Second Event
        DTSTART:20240316T100000Z
        DTEND:20240316T110000Z
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/multi.ics", etag: nil)
        #expect(events.count == 1)
        #expect(events[0].summary == "First Event")
    }

    @Test("Parse EXDATE and RDATE in recurrence")
    func parseExdateAndRdate() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Recurring
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        RRULE:FREQ=WEEKLY
        EXDATE:20240322T100000Z
        RDATE:20240329T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        #expect(events[0].recurrence?.count == 3)
        #expect(events[0].recurrence?.contains(where: { $0.hasPrefix("EXDATE") }) == true)
        #expect(events[0].recurrence?.contains(where: { $0.hasPrefix("RDATE") }) == true)
    }

    @Test("Parse TRANSP:OPAQUE returns opaque")
    func parseOpaqueTransparency() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Busy
        DTSTART:20240315T100000Z
        TRANSP:OPAQUE
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events[0].transparency == "opaque")
    }

    @Test("Parse unknown STATUS falls through to default")
    func parseUnknownStatus() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Custom
        DTSTART:20240315T100000Z
        STATUS:DRAFT
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events[0].status == "draft")
    }

    @Test("Parse CREATED and LAST-MODIFIED as RFC 3339")
    func parseCreatedAndLastModified() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Timestamped
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        CREATED:20240301T120000Z
        LAST-MODIFIED:20240310T080000Z
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        #expect(events[0].created != nil)
        #expect(events[0].updated != nil)
        // Verify RFC 3339 format
        #expect(events[0].created?.contains("2024-03-01") == true)
        #expect(events[0].updated?.contains("2024-03-10") == true)
    }

    @Test("Parse URL property")
    func parseUrlProperty() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Linked
        DTSTART:20240315T100000Z
        URL:https://example.com/event
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events[0].htmlLink == "https://example.com/event")
    }

    @Test("Attendee with TENTATIVE and needsAction PARTSTAT")
    func parseAttendeeTentativeAndDefault() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        ATTENDEE;CN="Maybe";PARTSTAT=TENTATIVE:mailto:maybe@test.com
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:pending@test.com
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        let maybe = events[0].attendees?.first { $0.email == "maybe@test.com" }
        #expect(maybe?.responseStatus == "tentative")
        #expect(maybe?.displayName == "Maybe")
        let pending = events[0].attendees?.first { $0.email == "pending@test.com" }
        #expect(pending?.responseStatus == "needsAction")
        #expect(pending?.displayName == nil)
    }

    @Test("Attendee with no CN has nil displayName")
    func parseAttendeeNoCN() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART:20240315T100000Z
        ATTENDEE;PARTSTAT=ACCEPTED:mailto:noname@test.com
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        let attendee = events[0].attendees?.first
        #expect(attendee?.email == "noname@test.com")
        #expect(attendee?.displayName == nil)
    }

    @Test("Organizer with no CN has nil displayName")
    func parseOrganizerNoCN() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART:20240315T100000Z
        ORGANIZER:mailto:org@test.com
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events[0].organizer?.email == "org@test.com")
        #expect(events[0].organizer?.displayName == nil)
    }

    @Test("Duration with weeks and days")
    func parseDurationWeeksAndDays() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Long Event
        DTSTART:20240315T100000Z
        DURATION:P1W2D
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        #expect(events[0].end != nil)
        // 1 week + 2 days = 9 days from start
        #expect(events[0].end?.dateTime?.contains("2024-03-24") == true)
    }

    @Test("Duration with hours and seconds")
    func parseDurationHoursAndSeconds() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Precise
        DTSTART:20240315T100000Z
        DURATION:PT2H30S
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        #expect(events[0].end != nil)
        // 2 hours + 30 seconds from 10:00:00 = 12:00:30
        #expect(events[0].end?.dateTime?.contains("12:00:30") == true)
    }

    @Test("Unquoted CN in attendee")
    func parseUnquotedCN() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART:20240315T100000Z
        ATTENDEE;CN=Charlie;PARTSTAT=ACCEPTED:mailto:charlie@test.com
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        let charlie = events[0].attendees?.first
        #expect(charlie?.displayName == "Charlie")
        #expect(charlie?.email == "charlie@test.com")
    }

    @Test("DTSTART with params but no TZID")
    func parseDtstartWithParamsNoTZID() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:No TZ
        DTSTART;VALUE=DATE-TIME:20240315T100000Z
        DTEND;VALUE=DATE-TIME:20240315T110000Z
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        // params = "VALUE=DATE-TIME" (no TZID), so timeZone should be nil
        #expect(events[0].start?.timeZone == nil)
    }

    @Test("All-day event formats date as YYYY-MM-DD")
    func allDayEventDateFormat() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Day Off
        DTSTART;VALUE=DATE:20240401
        DTEND;VALUE=DATE:20240402
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events[0].start?.date == "2024-04-01")
        #expect(events[0].end?.date == "2024-04-02")
        #expect(events[0].start?.timeZone == nil)
    }

    // MARK: - How a VEVENT's lines are read (pinned before that reading changes)

    /// 10:00 UTC two weeks from today, as an ICS UTC value, and the same instant as the parser
    /// gives it.
    private static let pinStart: (ics: String, iso: String) = {
        var cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC") ?? .current
        cal.timeZone = utc
        let date = cal.startOfDay(for: Date().addingTimeInterval(14 * 86_400)).addingTimeInterval(10 * 3_600)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = utc
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = utc
        return (fmt.string(from: date), iso.string(from: date))
    }()

    @Test("trailing whitespace after a value is not part of it")
    func trailingWhitespaceIsTrimmed() {
        let ics = [
            "BEGIN:VCALENDAR", "BEGIN:VEVENT",
            "SUMMARY:Planning  ", "LOCATION:Room 1\t", "DESCRIPTION:Agenda \t ",
            "DTSTART:\(Self.pinStart.ics) ", "URL:https://example.com/agenda ",
            "ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com  ",
            "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n")
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        guard events.count == 1 else { return }
        #expect(events[0].summary == "Planning")
        #expect(events[0].location == "Room 1")
        #expect(events[0].description == "Agenda")
        #expect(events[0].start?.dateTime == Self.pinStart.iso)
        #expect(events[0].htmlLink == "https://example.com/agenda")
        #expect(events[0].attendees?.map(\.email) == ["alice@example.com"])
    }

    @Test("a line folded with CRLF or with a bare LF, after a space or a tab, is read as one line",
          arguments: ["\r\n", "\n"], [" ", "\t"])
    func foldedLinesAreJoined(_ newline: String, _ fold: String) {
        let ics = [
            "BEGIN:VCALENDAR", "BEGIN:VEVENT",
            "SUMMARY:Quarterly plan", "\(fold)ning review",
            "DESCRIPTION:Bring the num", "\(fold)bers\\, the risks", "\(fold) and the dates",
            "DTSTART:\(Self.pinStart.ics)",
            "ATTENDEE;CN=Alice;PARTSTAT=ACC", "\(fold)EPTED:mailto:alice@exa", "\(fold)mple.com",
            "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: newline)
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        guard events.count == 1 else { return }
        #expect(events[0].summary == "Quarterly planning review")
        #expect(events[0].description == "Bring the numbers, the risks and the dates")
        #expect(events[0].start?.dateTime == Self.pinStart.iso)
        #expect(events[0].attendees?.map(\.email) == ["alice@example.com"])
        #expect(events[0].attendees?.map(\.responseStatus) == ["accepted"])
    }

    @Test("the series is read when a changed occurrence comes before it in the resource")
    func masterReadWhenOverrideComesFirst() {
        let ics = [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT", "UID:series-1", "RECURRENCE-ID:\(Self.pinStart.ics)",
            "SUMMARY:Planning (moved)", "DESCRIPTION:Moved notes", "LOCATION:Room 9",
            "DTSTART:\(Self.pinStart.ics)", "DURATION:PT2H",
            "ATTENDEE;PARTSTAT=DECLINED:mailto:bob@example.com", "END:VEVENT",
            "BEGIN:VEVENT", "UID:series-1", "SUMMARY:Planning", "DESCRIPTION:Agenda", "LOCATION:Room 1",
            "DTSTART:\(Self.pinStart.ics)", "DURATION:PT1H", "RRULE:FREQ=WEEKLY",
            "ATTENDEE;PARTSTAT=ACCEPTED:mailto:alice@example.com", "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n")
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        guard events.count == 1 else { return }
        #expect(events[0].summary == "Planning")
        #expect(events[0].description == "Agenda")
        #expect(events[0].location == "Room 1")
        #expect(events[0].recurrence == ["RRULE:FREQ=WEEKLY"])
        #expect(events[0].attendees?.map(\.email) == ["alice@example.com"])
    }

    @Test("a component opened and closed in lower case ends there: the event's later properties are read")
    func lowercaseNestedComponentEnds() {
        let ics = [
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:series-1", "SUMMARY:Planning",
            "DTSTART:\(Self.pinStart.ics)",
            "begin:valarm", "ACTION:AUDIO", "TRIGGER:-PT15M", "end:valarm",
            "LOCATION:Room 1", "DESCRIPTION:Agenda", "DURATION:PT1H",
            "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n")
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        guard events.count == 1 else { return }
        #expect(events[0].summary == "Planning")
        #expect(events[0].location == "Room 1")
        #expect(events[0].description == "Agenda")
        #expect(events[0].start?.dateTime == Self.pinStart.iso)
        #expect(events[0].end != nil)
    }

    @Test("a lower-case alarm after the event's properties is the alarm's: its text and subject are not the event's")
    func lowercaseAlarmIsNotTheEvents() {
        let ics = [
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:series-1", "SUMMARY:Planning",
            "DTSTART:\(Self.pinStart.ics)", "DURATION:PT1H",
            "ATTENDEE;PARTSTAT=ACCEPTED:mailto:alice@example.com",
            "begin:valarm", "ACTION:EMAIL", "DESCRIPTION:Reminder", "SUMMARY:Alarm notification",
            "ATTENDEE:mailto:alerts@example.com", "TRIGGER:-PT15M", "end:valarm",
            "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n")
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        guard events.count == 1 else { return }
        #expect(events[0].summary == "Planning")
        #expect(events[0].description == nil, "the alarm's text was read as the notes")
        #expect(events[0].attendees?.map(\.email) == ["alice@example.com"])
    }

    @Test("a VEVENT whose BEGIN or END line ends in whitespace is read",
          arguments: ["BEGIN:VEVENT ", "BEGIN:VEVENT\t", "BEGIN:VEVENT"], ["END:VEVENT ", "END:VEVENT\t", "END:VEVENT"])
    func paddedVEventMarkersAreRead(_ begin: String, _ end: String) {
        let ics = [
            "BEGIN:VCALENDAR", begin, "UID:series-1", "SUMMARY:Planning", "DESCRIPTION:Agenda",
            "DTSTART:\(Self.pinStart.ics)", "DURATION:PT1H", end, "END:VCALENDAR",
        ].joined(separator: "\r\n")
        let events = ICSParser.parse(icsText: ics, resourceHref: "/cal/x.ics", etag: nil)
        #expect(events.count == 1)
        guard events.count == 1 else { return }
        #expect(events[0].summary == "Planning")
        #expect(events[0].description == "Agenda")
        #expect(events[0].start?.dateTime == Self.pinStart.iso)
        #expect(events[0].end != nil)
    }
}
