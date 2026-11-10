/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// A DTSTART that states `VALUE=DATE-TIME` (the default, which a client may
/// spell out) is a timed value at every ICS reader; `VALUE=DATE` is a day.
@Suite("ICS value type: VALUE=DATE-TIME is timed, VALUE=DATE is a day, at every reader")
struct ICSValueTypeTests {

    private static func calendar(_ dtstart: String, _ dtend: String) -> String {
        [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
            "UID:vt-1", "DTSTAMP:20990101T000000Z", dtstart, dtend, "SUMMARY:Review",
            "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n")
    }

    /// 2099-03-05 10:00 UTC, computed independently of the readers under test.
    private static let tenUTC: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2099, month: 3, day: 5, hour: 10))!
    }()

    // MARK: The parameter match

    @Test("the VALUE parameter is matched whole and in any case")
    func parameterMatch() {
        #expect(ICSValueType.statesDate("DTSTART;VALUE=DATE"))
        #expect(ICSValueType.statesDate("DTEND;value=date"))
        #expect(ICSValueType.statesDate("VALUE=DATE"))
        #expect(ICSValueType.statesDate("DTSTART;X-A=B;VALUE=DATE"))
        #expect(!ICSValueType.statesDate("DTSTART;VALUE=DATE-TIME"))
        #expect(!ICSValueType.statesDate("DTSTART;VALUE=DATE-TIME;TZID=America/Los_Angeles"))
        #expect(!ICSValueType.statesDate("VALUE=DATE-TIME"))
        #expect(!ICSValueType.statesDate("DTSTART;X-VALUE=DATE"))
        #expect(!ICSValueType.statesDate("DTSTART"))
    }

    // MARK: ICSParser (CalDAV event reads)

    @Test("ICSParser reads a DTSTART stating VALUE=DATE-TIME as a timed start")
    func parserReadsDateTimeAsTimed() {
        let events = ICSParser.parse(
            icsText: Self.calendar("DTSTART;VALUE=DATE-TIME:20990305T100000Z", "DTEND;VALUE=DATE-TIME:20990305T110000Z"),
            resourceHref: "/cal/vt-1.ics", etag: nil)
        #expect(events.count == 1)
        guard events.count == 1 else { return }
        #expect(events[0].start?.date == nil, "read as all-day: \(String(describing: events[0].start))")
        #expect(events[0].start?.dateTime != nil)
        #expect(events[0].end?.date == nil)
    }

    @Test("ICSParser still reads a DTSTART stating VALUE=DATE as all-day")
    func parserReadsDateAsAllDay() {
        let events = ICSParser.parse(
            icsText: Self.calendar("DTSTART;VALUE=DATE:20990305", "DTEND;VALUE=DATE:20990306"),
            resourceHref: "/cal/vt-1.ics", etag: nil)
        #expect(events.count == 1)
        guard events.count == 1 else { return }
        #expect(events[0].start?.date != nil)
        #expect(events[0].start?.dateTime == nil)
    }

    // MARK: ICSBuilder.parseIncoming (invitations in mail)

    @Test("an invitation whose DTSTART states VALUE=DATE-TIME is timed, at its own instant")
    func invitationReadsDateTimeAsTimed() {
        let invite = ICSBuilder.parseIncoming(
            Self.calendar("DTSTART;VALUE=DATE-TIME:20990305T100000Z", "DTEND;VALUE=DATE-TIME:20990305T110000Z"))
        #expect(invite?.isAllDay == false)
        #expect(invite?.startDate == Self.tenUTC)
    }

    @Test("an invitation whose DTSTART states VALUE=DATE is still all-day")
    func invitationReadsDateAsAllDay() {
        let invite = ICSBuilder.parseIncoming(Self.calendar("DTSTART;VALUE=DATE:20990305", "DTEND;VALUE=DATE:20990306"))
        #expect(invite?.isAllDay == true)
    }

    // MARK: CalDAVProvider's resource readers

    @Test("the CalDAV resource readers treat VALUE=DATE-TIME as timed")
    func providerReadersTreatDateTimeAsTimed() throws {
        let utc = Self.calendar("DTSTART;VALUE=DATE-TIME:20990305T100000Z", "DTEND;VALUE=DATE-TIME:20990305T110000Z")
        #expect(!CalDAVProvider.icsIsAllDay(utc))
        #expect(CalDAVProvider.masterDTStartKind(from: utc) == .utc)
        let zoned = Self.calendar("DTSTART;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990305T020000",
                                  "DTEND;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990305T030000")
        #expect(!CalDAVProvider.icsIsAllDay(zoned))
        #expect(CalDAVProvider.masterDTStartKind(from: zoned) == .zoned("America/Los_Angeles"))
        #expect(try CalDAVProvider.parseICSDateTime("DTSTART;VALUE=DATE-TIME:20990305T100000Z", zones: .none) == Self.tenUTC)
        // 02:00 in Los Angeles on 2099-03-05 (before the March change, UTC-8) is 10:00 UTC.
        #expect(try CalDAVProvider.parseICSDateTime("DTSTART;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990305T020000", zones: .none)
                == Self.tenUTC)
    }

    @Test("the CalDAV split helpers read a VALUE=DATE-TIME master as timed, with its real length")
    func splitHelpersTreatDateTimeAsTimed() throws {
        let master = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
            "UID:vt-2", "DTSTAMP:20990101T000000Z",
            "DTSTART;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990302T113000",
            "RRULE:FREQ=WEEKLY", "SUMMARY:Review", "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n")
        #expect(try CalDAVProvider.extractMasterDuration(from: master) == TimeInterval(90 * 60))
        // An empty patch: the new part's start and end are the copy's own, so its end is the one
        // the copy wrote and no later merge rewrites it.
        let split = try CalDAVProvider.seriesSplitResources(
            storedICS: master, slotNaiveISO: "2099-03-16T10:00:00",
            cappedRRule: "RRULE:FREQ=WEEKLY;UNTIL=20990316T165959Z", newRRule: "RRULE:FREQ=WEEKLY",
            newUid: "vt-2-split", patch: GCalEventInput(), now: Date())
        let lines = split.newPart.components(separatedBy: "\r\n")
        let start = lines.first { $0.hasPrefix("DTSTART") }
        let end = lines.first { $0.hasPrefix("DTEND") }
        #expect(start == "DTSTART;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990316T100000",
                "the new series' start: \(start ?? "<none>")")
        #expect(end == "DTEND;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990316T113000",
                "the new series' end is not a timed end of the series' length: \(end ?? "<none>")")
    }

    @Test("the CalDAV resource readers still treat VALUE=DATE as a day")
    func providerReadersTreatDateAsDay() throws {
        let ics = Self.calendar("DTSTART;VALUE=DATE:20990305", "DTEND;VALUE=DATE:20990306")
        #expect(CalDAVProvider.icsIsAllDay(ics))
        #expect(CalDAVProvider.masterDTStartKind(from: ics) == .allDay)
        let lower = Self.calendar("DTSTART;value=date:20990305", "DTEND;value=date:20990306")
        #expect(CalDAVProvider.icsIsAllDay(lower))
        #expect(CalDAVProvider.masterDTStartKind(from: lower) == .allDay)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(try CalDAVProvider.parseICSDateTime("DTSTART;VALUE=DATE:20990305", zones: .none)
                == utc.date(from: DateComponents(year: 2099, month: 3, day: 5)))
    }
}
