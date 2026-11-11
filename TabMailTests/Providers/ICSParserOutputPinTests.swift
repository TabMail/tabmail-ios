/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - What ICSParser reads from an event with no alarm, pinned field by field
//
// A corpus covering every shape of event the CalDAV and ICSParser tests use (all-day, timed in UTC,
// in a zone, floating, measured by DURATION, repeating with excluded and added dates, with changed
// occurrences, attendees, folded lines, escaped text, VTIMEZONE blocks), none with an alarm. For
// each, every field `ICSParser.parse` gives is written out here. A change to how a VEVENT's lines
// are collected must leave every one of them as it is: only an event with an alarm may read
// differently.
//
// Expected instants are computed here from the IANA zone each value names, never through the code
// under test. Dates are relative to today.

private enum PinDates {
    static let utc = TimeZone(identifier: "UTC") ?? .current

    /// The UTC day `offset` days after the day two weeks from today.
    static func day(_ offset: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let base = cal.startOfDay(for: Date().addingTimeInterval(14 * 86_400))
        return base.addingTimeInterval(TimeInterval(offset * 86_400))
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = utc
        fmt.dateFormat = pattern
        return fmt.string(from: date)
    }

    /// `yyyyMMdd` of day `offset`.
    static func compact(_ offset: Int) -> String { format(day(offset), "yyyyMMdd") }

    /// `yyyy-MM-dd` of day `offset`.
    static func dashed(_ offset: Int) -> String { format(day(offset), "yyyy-MM-dd") }

    /// The wall clock `yyyyMMddTHHmmss` of day `offset` at `time` (`HHmmss`).
    static func wall(_ offset: Int, _ time: String) -> String { "\(compact(offset))T\(time)" }

    /// The instant `wall` names in `zone`.
    static func instant(_ wall: String, in zone: TimeZone) -> Date {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = zone
        fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        return fmt.date(from: wall) ?? .distantPast
    }

    static func zone(_ identifier: String) -> TimeZone { TimeZone(identifier: identifier) ?? utc }

    /// RFC 3339 in UTC, as the parser writes an instant.
    static func iso(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        fmt.timeZone = utc
        return fmt.string(from: date)
    }

    /// The RFC 3339 instant `wall` names in `zone`.
    static func iso(_ wall: String, in zone: TimeZone) -> String { iso(instant(wall, in: zone)) }
}

struct ParsePin: Sendable, CustomTestStringConvertible {
    let name: String
    let ics: String
    let expected: [GCalEvent]

    var testDescription: String { name }

    static let href = "/cal/pin.ics"

    static func calendar(_ body: [String], newline: String = "\r\n") -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN"] + body + ["END:VCALENDAR"])
            .joined(separator: newline) + newline
    }

    static func vevent(_ lines: [String]) -> [String] { ["BEGIN:VEVENT"] + lines + ["END:VEVENT"] }

    static func timed(_ dateTime: String, zone: String? = nil) -> GCalDateTime {
        GCalDateTime(dateTime: dateTime, date: nil, timeZone: zone)
    }

    static func allDay(_ date: String) -> GCalDateTime { GCalDateTime(dateTime: nil, date: date, timeZone: nil) }

    static func attendee(_ email: String, _ name: String?, _ status: String) -> GCalAttendee {
        GCalAttendee(email: email, displayName: name, responseStatus: status, organizer: false, self: false)
    }

    static func event(
        summary: String? = nil, location: String? = nil, description: String? = nil,
        start: GCalDateTime?, end: GCalDateTime?, attendees: [GCalAttendee]? = nil,
        organizer: GCalOrganizer? = nil, recurrence: [String]? = nil, transparency: String? = nil,
        status: String = "confirmed", htmlLink: String? = nil, created: String? = nil, updated: String? = nil
    ) -> GCalEvent {
        GCalEvent(
            id: href, summary: summary, location: location, description: description,
            start: start, end: end, attendees: attendees, organizer: organizer, recurrence: recurrence,
            transparency: transparency, status: status, htmlLink: htmlLink, created: created, updated: updated)
    }

    static var all: [ParsePin] {
        let utc = PinDates.utc
        let ten = PinDates.wall(0, "100000")
        let eleven = PinDates.wall(0, "110000")
        let tenUTC = PinDates.iso(ten, in: utc)
        let elevenUTC = PinDates.iso(eleven, in: utc)
        let tenInstant = PinDates.instant(ten, in: utc)
        let stamp = "DTSTAMP:\(ten)Z"

        return [
            ParsePin(
                name: "a timed UTC event with a status",
                ics: calendar(vevent(["UID:pin-1", stamp, "SUMMARY:Team Meeting", "DTSTART:\(ten)Z",
                                      "DTEND:\(eleven)Z", "STATUS:CONFIRMED"])),
                expected: [event(summary: "Team Meeting", start: timed(tenUTC), end: timed(elevenUTC))]),
            ParsePin(
                name: "a place and notes with escaped text",
                ics: calendar(vevent(["UID:pin-2", stamp, "SUMMARY:Meeting\\; Important",
                                      "LOCATION:Room 1\\, Floor 2", "DESCRIPTION:Line one\\nLine two\\\\ end",
                                      "DTSTART:\(ten)Z", "DTEND:\(eleven)Z"])),
                expected: [event(summary: "Meeting; Important", location: "Room 1, Floor 2",
                                 description: "Line one\nLine two\\ end", start: timed(tenUTC), end: timed(elevenUTC))]),
            ParsePin(
                name: "an all-day event stating VALUE=DATE, free",
                ics: calendar(vevent(["UID:pin-3", stamp, "SUMMARY:Offsite",
                                      "DTSTART;VALUE=DATE:\(PinDates.compact(0))",
                                      "DTEND;VALUE=DATE:\(PinDates.compact(2))", "TRANSP:TRANSPARENT"])),
                expected: [event(summary: "Offsite", start: allDay(PinDates.dashed(0)), end: allDay(PinDates.dashed(2)),
                                 transparency: "transparent")]),
            ParsePin(
                name: "an all-day event by a bare date with no end",
                ics: calendar(vevent(["UID:pin-4", stamp, "SUMMARY:Holiday", "DTSTART:\(PinDates.compact(0))"])),
                expected: [event(summary: "Holiday", start: allDay(PinDates.dashed(0)), end: allDay(PinDates.dashed(0)))]),
            ParsePin(
                name: "an organizer and attendees in every form",
                ics: calendar(vevent([
                    "UID:pin-5", stamp, "SUMMARY:Review", "DTSTART:\(ten)Z", "DTEND:\(eleven)Z",
                    "ORGANIZER;CN=\"Olivia Example\":mailto:olivia@example.com",
                    "ATTENDEE;CN=\"Alice\";PARTSTAT=ACCEPTED:mailto:alice@example.com",
                    "ATTENDEE;CN=Bob;PARTSTAT=DECLINED:mailto:bob@example.com",
                    "ATTENDEE;CN=\"Carol\";PARTSTAT=TENTATIVE:mailto:carol@example.com",
                    "ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:dave@example.com",
                    "ATTENDEE;RSVP=TRUE:MAILTO:erin@example.com",
                    "ATTENDEE;CN=Room;CUTYPE=ROOM:urn:uuid:room-1",
                ])),
                expected: [event(
                    summary: "Review", start: timed(tenUTC), end: timed(elevenUTC),
                    attendees: [
                        attendee("alice@example.com", "Alice", "accepted"),
                        attendee("bob@example.com", "Bob", "declined"),
                        attendee("carol@example.com", "Carol", "tentative"),
                        attendee("dave@example.com", nil, "needsAction"),
                        attendee("erin@example.com", nil, "needsAction"),
                    ],
                    organizer: GCalOrganizer(email: "olivia@example.com", displayName: "Olivia Example", self: false))]),
            ParsePin(
                name: "a cancelled event",
                ics: calendar(vevent(["UID:pin-6", stamp, "SUMMARY:Cancelled", "DTSTART:\(ten)Z", "STATUS:CANCELLED"])),
                expected: [event(summary: "Cancelled", start: timed(tenUTC), end: nil, status: "cancelled")]),
            ParsePin(
                name: "a tentative event",
                ics: calendar(vevent(["UID:pin-7", stamp, "SUMMARY:Maybe", "DTSTART:\(ten)Z", "DTEND:\(eleven)Z",
                                      "STATUS:TENTATIVE"])),
                expected: [event(summary: "Maybe", start: timed(tenUTC), end: timed(elevenUTC), status: "tentative")]),
            ParsePin(
                name: "a status RFC 5545 does not name",
                ics: calendar(vevent(["UID:pin-8", stamp, "SUMMARY:Custom", "DTSTART:\(ten)Z", "STATUS:DRAFT"])),
                expected: [event(summary: "Custom", start: timed(tenUTC), end: nil, status: "draft")]),
            ParsePin(
                name: "a length in minutes by DURATION",
                ics: calendar(vevent(["UID:pin-9", stamp, "SUMMARY:Quick Chat", "DTSTART:\(ten)Z", "DURATION:PT30M"])),
                expected: [event(summary: "Quick Chat", start: timed(tenUTC),
                                 end: timed(PinDates.iso(tenInstant.addingTimeInterval(30 * 60))))]),
            ParsePin(
                name: "a length in weeks and days by DURATION",
                ics: calendar(vevent(["UID:pin-10", stamp, "SUMMARY:Long Event", "DTSTART:\(ten)Z", "DURATION:P1W2D"])),
                expected: [event(summary: "Long Event", start: timed(tenUTC),
                                 end: timed(PinDates.iso(tenInstant.addingTimeInterval(9 * 86_400))))]),
            ParsePin(
                name: "a length in hours and seconds by DURATION",
                ics: calendar(vevent(["UID:pin-11", stamp, "SUMMARY:Precise", "DTSTART:\(ten)Z", "DURATION:PT2H30S"])),
                expected: [event(summary: "Precise", start: timed(tenUTC),
                                 end: timed(PinDates.iso(tenInstant.addingTimeInterval(2 * 3_600 + 30))))]),
            ParsePin(
                name: "a rule with excluded and added dates",
                ics: calendar(vevent([
                    "UID:pin-12", stamp, "SUMMARY:Recurring", "DTSTART:\(ten)Z", "DTEND:\(eleven)Z",
                    "RRULE:FREQ=WEEKLY;COUNT=10", "EXDATE:\(PinDates.wall(7, "100000"))Z",
                    "EXDATE;VALUE=DATE-TIME:\(PinDates.wall(14, "100000"))Z", "RDATE:\(PinDates.wall(9, "100000"))Z",
                ])),
                expected: [event(summary: "Recurring", start: timed(tenUTC), end: timed(elevenUTC), recurrence: [
                    "RRULE:FREQ=WEEKLY;COUNT=10", "EXDATE:\(PinDates.wall(7, "100000"))Z",
                    "EXDATE;VALUE=DATE-TIME:\(PinDates.wall(14, "100000"))Z", "RDATE:\(PinDates.wall(9, "100000"))Z",
                ])]),
            ParsePin(
                name: "a series followed by a changed occurrence",
                ics: calendar(
                    vevent(["UID:pin-13", stamp, "SUMMARY:Weekly Standup", "DTSTART:\(ten)Z",
                            "DTEND:\(PinDates.wall(0, "103000"))Z", "RRULE:FREQ=WEEKLY"])
                    + vevent(["UID:pin-13", stamp, "RECURRENCE-ID:\(PinDates.wall(7, "100000"))Z",
                              "SUMMARY:Weekly Standup (moved)", "DTSTART:\(PinDates.wall(7, "110000"))Z",
                              "DTEND:\(PinDates.wall(7, "113000"))Z"])),
                expected: [event(summary: "Weekly Standup", start: timed(tenUTC),
                                 end: timed(PinDates.iso(PinDates.wall(0, "103000"), in: utc)),
                                 recurrence: ["RRULE:FREQ=WEEKLY"])]),
            ParsePin(
                name: "a changed occurrence followed by its series",
                ics: calendar(
                    vevent(["UID:pin-14", stamp, "RECURRENCE-ID:\(PinDates.wall(7, "100000"))Z",
                            "SUMMARY:Weekly Standup (moved)", "LOCATION:Room 9", "DTSTART:\(PinDates.wall(7, "110000"))Z",
                            "DTEND:\(PinDates.wall(7, "113000"))Z", "ATTENDEE;PARTSTAT=DECLINED:mailto:bob@example.com"])
                    + vevent(["UID:pin-14", stamp, "SUMMARY:Weekly Standup", "DTSTART:\(ten)Z",
                              "DTEND:\(PinDates.wall(0, "103000"))Z", "RRULE:FREQ=WEEKLY",
                              "ATTENDEE;PARTSTAT=ACCEPTED:mailto:alice@example.com"])),
                expected: [event(summary: "Weekly Standup", start: timed(tenUTC),
                                 end: timed(PinDates.iso(PinDates.wall(0, "103000"), in: utc)),
                                 attendees: [attendee("alice@example.com", nil, "accepted")],
                                 recurrence: ["RRULE:FREQ=WEEKLY"])]),
            ParsePin(
                name: "two events with no changed occurrence: the first",
                ics: calendar(
                    vevent(["UID:pin-15a", stamp, "SUMMARY:First Event", "DTSTART:\(ten)Z", "DTEND:\(eleven)Z"])
                    + vevent(["UID:pin-15b", stamp, "SUMMARY:Second Event", "DTSTART:\(PinDates.wall(1, "100000"))Z",
                              "DTEND:\(PinDates.wall(1, "110000"))Z"])),
                expected: [event(summary: "First Event", start: timed(tenUTC), end: timed(elevenUTC))]),
            ParsePin(
                name: "lines folded across CRLF",
                ics: calendar(vevent([
                    "UID:pin-16", stamp, "SUMMARY:Very Long ", " Meeting Name",
                    "DESCRIPTION:Notes that the server folded across two physical l", " ines\\, with a comma",
                    "DTSTART:\(ten)Z", "DTEND:\(eleven)Z",
                ])),
                expected: [event(summary: "Very Long Meeting Name",
                                 description: "Notes that the server folded across two physical lines, with a comma",
                                 start: timed(tenUTC), end: timed(elevenUTC))]),
            ParsePin(
                name: "lines folded across a bare LF with a tab",
                ics: calendar(vevent([
                    "UID:pin-17", stamp, "SUMMARY:Quarterly plan", "\tning", "LOCATION:Room ", "\t1",
                    "DTSTART:\(ten)Z", "DTEND:\(eleven)Z",
                ]), newline: "\n"),
                expected: [event(summary: "Quarterly planning", location: "Room 1",
                                 start: timed(tenUTC), end: timed(elevenUTC))]),
            ParsePin(
                name: "an IANA zone with no VTIMEZONE",
                ics: calendar(vevent([
                    "UID:pin-18", stamp, "SUMMARY:NYC Meeting", "DTSTART;TZID=America/New_York:\(ten)",
                    "DTEND;TZID=America/New_York:\(eleven)",
                ])),
                expected: [event(summary: "NYC Meeting",
                                 start: timed(PinDates.iso(ten, in: PinDates.zone("America/New_York")), zone: "America/New_York"),
                                 end: timed(PinDates.iso(eleven, in: PinDates.zone("America/New_York")), zone: "America/New_York"))]),
            ParsePin(
                name: "a Windows zone name defined by an Outlook VTIMEZONE",
                ics: calendar(TimeZoneFixture.pacific.vtimezone + vevent([
                    "UID:pin-19", stamp, "SUMMARY:Planning", "DTSTART;TZID=Pacific Standard Time:\(ten)",
                    "DTEND;TZID=Pacific Standard Time:\(eleven)",
                ])),
                expected: [event(summary: "Planning",
                                 start: timed(PinDates.iso(ten, in: PinDates.zone("America/Los_Angeles")), zone: "Pacific Standard Time"),
                                 end: timed(PinDates.iso(eleven, in: PinDates.zone("America/Los_Angeles")), zone: "Pacific Standard Time"))]),
            ParsePin(
                name: "a zone name a VTIMEZONE places by X-LIC-LOCATION",
                ics: calendar(TimeZoneFixture.berlinByLocation.vtimezone + vevent([
                    "UID:pin-20", stamp, "SUMMARY:Planning", "DTSTART;TZID=Custom Berlin:\(ten)",
                    "DTEND;TZID=Custom Berlin:\(eleven)",
                ])),
                expected: [event(summary: "Planning",
                                 start: timed(PinDates.iso(ten, in: PinDates.zone("Europe/Berlin")), zone: "Custom Berlin"),
                                 end: timed(PinDates.iso(eleven, in: PinDates.zone("Europe/Berlin")), zone: "Custom Berlin"))]),
            ParsePin(
                name: "a zone no table knows, read in the device's zone",
                ics: calendar(TimeZoneFixture.unmatched + vevent([
                    "UID:pin-21", stamp, "SUMMARY:Planning", "DTSTART;TZID=\(TimeZoneFixture.unmatchedTZID):\(ten)",
                    "DTEND;TZID=\(TimeZoneFixture.unmatchedTZID):\(eleven)",
                ])),
                expected: [event(summary: "Planning",
                                 start: timed(PinDates.iso(ten, in: .current), zone: TimeZoneFixture.unmatchedTZID),
                                 end: timed(PinDates.iso(eleven, in: .current), zone: TimeZoneFixture.unmatchedTZID))]),
            ParsePin(
                name: "a floating time, read in the device's zone",
                ics: calendar(vevent(["UID:pin-22", stamp, "SUMMARY:Local", "DTSTART:\(ten)", "DTEND:\(eleven)"])),
                expected: [event(summary: "Local", start: timed(PinDates.iso(ten, in: .current)),
                                 end: timed(PinDates.iso(eleven, in: .current)))]),
            ParsePin(
                name: "a UTC start stating VALUE=DATE-TIME",
                ics: calendar(vevent(["UID:pin-23", stamp, "SUMMARY:No TZ", "DTSTART;VALUE=DATE-TIME:\(ten)Z",
                                      "DTEND;VALUE=DATE-TIME:\(eleven)Z"])),
                expected: [event(summary: "No TZ", start: timed(tenUTC), end: timed(elevenUTC))]),
            ParsePin(
                name: "created, last-modified and a link",
                ics: calendar(vevent([
                    "UID:pin-24", stamp, "SUMMARY:Timestamped", "DTSTART:\(ten)Z", "DTEND:\(eleven)Z",
                    "CREATED:\(PinDates.wall(-7, "120000"))Z", "LAST-MODIFIED:\(PinDates.wall(-1, "080000"))Z",
                    "URL:https://example.com/event", "TRANSP:OPAQUE",
                ])),
                expected: [event(summary: "Timestamped", start: timed(tenUTC), end: timed(elevenUTC), transparency: "opaque",
                                 htmlLink: "https://example.com/event",
                                 created: PinDates.iso(PinDates.wall(-7, "120000"), in: utc),
                                 updated: PinDates.iso(PinDates.wall(-1, "080000"), in: utc))]),
            ParsePin(
                name: "trailing whitespace after values",
                ics: calendar(vevent([
                    "UID:pin-25", stamp, "SUMMARY:Planning  ", "LOCATION:Room 1\t", "DESCRIPTION:Agenda ",
                    "DTSTART:\(ten)Z ", "DTEND:\(eleven)Z\t",
                ])),
                expected: [event(summary: "Planning", location: "Room 1", description: "Agenda",
                                 start: timed(tenUTC), end: timed(elevenUTC))]),
            ParsePin(name: "a calendar with no event", ics: calendar([]), expected: []),
        ]
    }
}

@Suite("ICSParser: what an event with no alarm reads as, pinned")
struct ICSParserOutputPinTests {

    private static func json(_ events: [GCalEvent]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(events) else { return "<unencodable>" }
        return String(decoding: data, as: UTF8.self)
    }

    @Test("every field the parser gives is the pinned one", arguments: ParsePin.all)
    func parseOutputIsPinned(_ pin: ParsePin) {
        let actual = Self.json(ICSParser.parse(icsText: pin.ics, resourceHref: ParsePin.href, etag: "\"pin\""))
        let expected = Self.json(pin.expected)
        #expect(actual == expected, "\(pin.name)\nexpected:\n\(expected)\nactual:\n\(actual)")
    }

    @Test("the corpus covers every shape it names (non-vacuity)")
    func corpusIsNotEmpty() {
        let pins = ParsePin.all
        #expect(pins.count == 26)
        #expect(pins.filter { $0.expected.count == 1 }.count == 25)
        #expect(pins.allSatisfy { !$0.ics.uppercased().contains("BEGIN:VALARM") })
    }
}
