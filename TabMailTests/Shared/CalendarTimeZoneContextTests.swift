/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("CalendarTimeZoneResolver: which zone names TabMail recognizes")
struct CalendarTimeZoneResolverTests {

    private static func context(_ vtimezones: [[String]]) -> CalendarTimeZoneContext {
        CalendarTimeZoneContext(calendarText: TimeZoneFixture.resource(vtimezones.flatMap { $0 }, []))
    }

    @Test("an IANA name, quoted or not, is that zone")
    func ianaName() {
        #expect(CalendarTimeZoneResolver.zone(named: "Asia/Tokyo", in: .none)?.identifier == "Asia/Tokyo")
        #expect(CalendarTimeZoneResolver.zone(named: " \"Asia/Tokyo\" ", in: .none)?.identifier == "Asia/Tokyo")
        #expect(CalendarTimeZoneResolver.zone(named: "", in: .none) == nil)
        #expect(CalendarTimeZoneResolver.zone(named: "\"\"", in: .none) == nil)
    }

    @Test("a Windows name is its CLDR zone, with no resource to read it from")
    func windowsName() {
        #expect(CalendarTimeZoneResolver.zone(named: "Pacific Standard Time", in: .none)?.identifier == "America/Los_Angeles")
        #expect(CalendarTimeZoneResolver.zone(named: "\"Tokyo Standard Time\"", in: .none)?.identifier == "Asia/Tokyo")
        #expect(CalendarTimeZoneResolver.zone(named: "Not A Zone", in: .none) == nil)
    }

    @Test("every zone the CLDR Windows table maps to is one Foundation knows")
    func everyWindowsTargetExists() {
        let unknown = WindowsTimeZones.ianaByWindowsName.filter { TimeZone(identifier: $0.value) == nil }
        #expect(unknown.isEmpty, "unknown targets: \(unknown)")
        #expect(!WindowsTimeZones.ianaByWindowsName.isEmpty)
    }

    @Test("a name that is an IANA or Windows name is that zone, whatever location a VTIMEZONE gives it")
    func namesComeBeforeTheLocation() {
        let zones = Self.context([
            ["BEGIN:VTIMEZONE", "TZID:Asia/Tokyo", "X-LIC-LOCATION:Europe/Berlin", "END:VTIMEZONE"],
            ["BEGIN:VTIMEZONE", "TZID:Pacific Standard Time", "X-LIC-LOCATION:Europe/Berlin", "END:VTIMEZONE"],
        ])
        #expect(zones.locations["Asia/Tokyo"] == "Europe/Berlin", "non-vacuity: the location was read")
        #expect(CalendarTimeZoneResolver.zone(named: "Asia/Tokyo", in: zones)?.identifier == "Asia/Tokyo")
        #expect(CalendarTimeZoneResolver.zone(named: "Pacific Standard Time", in: zones)?.identifier == "America/Los_Angeles")
    }

    @Test("a name no table knows is the zone of its VTIMEZONE's X-LIC-LOCATION, itself an IANA or Windows name")
    func locationIsTriedAsAName() {
        let zones = Self.context([
            ["BEGIN:VTIMEZONE", "TZID:Custom Berlin", "X-LIC-LOCATION:Europe/Berlin", "END:VTIMEZONE"],
            ["BEGIN:VTIMEZONE", "TZID:Custom Tokyo", "X-LIC-LOCATION:Tokyo Standard Time", "END:VTIMEZONE"],
            ["BEGIN:VTIMEZONE", "TZID:Custom Nowhere", "X-LIC-LOCATION:Not/AZone", "END:VTIMEZONE"],
        ])
        #expect(CalendarTimeZoneResolver.zone(named: "Custom Berlin", in: zones)?.identifier == "Europe/Berlin")
        #expect(CalendarTimeZoneResolver.zone(named: "\"Custom Berlin\"", in: zones)?.identifier == "Europe/Berlin")
        #expect(CalendarTimeZoneResolver.zone(named: "Custom Tokyo", in: zones)?.identifier == "Asia/Tokyo")
        #expect(CalendarTimeZoneResolver.zone(named: "Custom Nowhere", in: zones) == nil)
        // The name alone, with no resource to read it from, is not a zone.
        #expect(CalendarTimeZoneResolver.zone(named: "Custom Berlin", in: .none) == nil)
        #expect(CalendarTimeZoneContext.none.locations.isEmpty)
    }

    @Test("a zone its VTIMEZONE defines only by its rules is not recognized")
    func rulesOnlyZoneIsUnrecognized() {
        let zones = Self.context([TimeZoneFixture.unmatched])
        #expect(zones.locations.isEmpty)
        #expect(CalendarTimeZoneResolver.zone(named: TimeZoneFixture.unmatchedTZID, in: zones) == nil)
    }
}

@Suite("CalendarTimeZoneContext: what one resource says about its zone names")
struct CalendarTimeZoneContextTests {

    private static func locations(_ lines: [String]) -> [String: String] {
        CalendarTimeZoneContext(calendarText: lines.joined(separator: "\r\n") + "\r\n").locations
    }

    @Test("a folded X-LIC-LOCATION or TZID is read joined, and quoted values unquoted")
    func foldedAndQuoted() {
        #expect(Self.locations([
            "BEGIN:VTIMEZONE", "TZID:Custom", "\t Berlin", "X-LIC-LOCATION:Euro", " pe/Berlin", "END:VTIMEZONE",
        ]) == ["Custom Berlin": "Europe/Berlin"])
        #expect(Self.locations([
            "BEGIN:VTIMEZONE", "TZID:\"Custom Berlin\"", "x-lic-location;X-PARAM=\"a:b\":Europe/Berlin", "END:VTIMEZONE",
        ]) == ["Custom Berlin": "Europe/Berlin"])
    }

    @Test("the first VTIMEZONE with a TZID defines it, even with no location")
    func firstDefinitionWins() {
        #expect(Self.locations([
            "BEGIN:VTIMEZONE", "TZID:Custom", "X-LIC-LOCATION:Europe/Berlin", "END:VTIMEZONE",
            "BEGIN:VTIMEZONE", "TZID:Custom", "X-LIC-LOCATION:Asia/Tokyo", "END:VTIMEZONE",
        ]) == ["Custom": "Europe/Berlin"])
        #expect(Self.locations([
            "BEGIN:VTIMEZONE", "TZID:Custom", "END:VTIMEZONE",
            "BEGIN:VTIMEZONE", "TZID:Custom", "X-LIC-LOCATION:Asia/Tokyo", "END:VTIMEZONE",
        ]).isEmpty)
    }

    @Test("only the lines directly inside a VTIMEZONE are read")
    func onlyDirectlyInsideAVTimeZone() {
        #expect(Self.locations([
            "BEGIN:VTIMEZONE", "TZID:Custom", "BEGIN:STANDARD", "TZID:Other", "X-LIC-LOCATION:Asia/Tokyo",
            "DTSTART:16010101T000000", "END:STANDARD", "X-LIC-LOCATION:Europe/Berlin", "END:VTIMEZONE",
            "BEGIN:VEVENT", "TZID:Event", "X-LIC-LOCATION:Asia/Tokyo", "END:VEVENT",
            "TZID:Outside", "X-LIC-LOCATION:Asia/Tokyo",
        ]) == ["Custom": "Europe/Berlin"])
        // A folded continuation outside a VTIMEZONE is not joined onto the last line inside one.
        #expect(Self.locations([
            "BEGIN:VTIMEZONE", "TZID:Custom", "X-LIC-LOCATION:Europe/Berlin", "END:VTIMEZONE",
            "BEGIN:VEVENT", "SUMMARY:Planning", " more", "END:VEVENT",
        ]) == ["Custom": "Europe/Berlin"])
    }

    /// The context is one forward pass over the lines, each read once and only its own length, with
    /// a fixed set of values carried between them: its time is linear in the text by construction,
    /// whatever counts, years, nesting or lengths the text names. This is a guard against a change
    /// that breaks that shape, not a measure of it, so its limit is generous.
    @Test("a resource with many events and a huge, malformed VTIMEZONE is read promptly and still shown",
          .timeLimit(.minutes(1)))
    func hostileResource() throws {
        let events = (0..<2_000).map { index in
            ["BEGIN:VEVENT", "UID:hostile-\(index)", "DTSTAMP:20990101T000000Z",
             "DTSTART;TZID=Custom:20990715T100000", "RRULE:FREQ=SECONDLY;COUNT=\(Int.max);UNTIL=99991231T000000Z",
             "SUMMARY:Planning", "END:VEVENT"]
        }
        let malformed = ["BEGIN:VTIMEZONE", "TZID:Custom"]
            + Array(repeating: " :::\"" + String(repeating: "x", count: 1_000), count: 2_000)
            + Array(repeating: "BEGIN:STANDARD", count: 20_000)
            + ["RDATE:" + Array(repeating: "99991231T000000", count: 50_000).joined(separator: ",")]
        let ics = TimeZoneFixture.resource(malformed, events)
        #expect(ics.utf8.count > 2_000_000, "setup: \(ics.utf8.count) bytes")

        // The VTIMEZONE never ends, so it defines nothing, and the zone is read in the device's zone.
        #expect(CalendarTimeZoneContext(calendarText: ics).locations.isEmpty)
        let event = try #require(ICSParser.parse(icsText: ics, resourceHref: "/cal/hostile.ics", etag: nil).first)
        #expect(event.summary == "Planning")
        #expect(ICSBuilder.parseIncoming(ics) != nil)
    }
}

@Suite("CalendarToolHelpers.resolveWriteTimeZone: the zone an assistant write uses")
struct CalendarToolHelpersWriteTimeZoneTests {

    @Test("a Windows zone name is its CLDR zone")
    func windowsName() throws {
        let args: [String: JSONValue] = ["timezone": .string("Pacific Standard Time")]
        #expect(try CalendarToolHelpers.resolveWriteTimeZone(args, consequence: "it did not change the event").identifier
                == "America/Los_Angeles")
    }

    @Test("a zone it does not recognize is refused, naming it, instead of using the device's")
    func unknownZoneIsRefused() {
        let args: [String: JSONValue] = ["timezone": .string("Not/AZone")]
        #expect {
            _ = try CalendarToolHelpers.resolveWriteTimeZone(args, consequence: "it did not change the event")
        } throws: { error in
            guard case CalendarProviderError.notSupported(let reason) = error else { return false }
            return reason == "This event uses the time zone \"Not/AZone\", which TabMail does not recognize, so it did not change the event. Change the time in your calendar app instead."
        }
    }

    @Test("with no zone named, it is the device's zone")
    func defaultIsTheDeviceZone() throws {
        #expect(try CalendarToolHelpers.resolveWriteTimeZone([:], consequence: "x") == .current)
        #expect(try CalendarToolHelpers.resolveWriteTimeZone(["timezone": .string("")], consequence: "x") == .current)
    }
}
