/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Fixtures

/// Calendar zones as Outlook, Exchange and other clients write them into the events they send, each
/// with the IANA zone it stands for. That IANA zone is the tests' oracle: every instant a test
/// expects is computed from it here, never through the code under test.
///
/// Dates are in 2099 (testing rule 7's fixed-date exception).
enum TimeZoneFixture {
    struct Zone: Sendable, CustomTestStringConvertible {
        /// The `TZID` the resource uses.
        let tzid: String
        /// The IANA zone the expected instants are computed in.
        let oracle: String
        /// The resource's `VTIMEZONE` for `tzid`.
        let vtimezone: [String]

        var testDescription: String { "\(tzid) (\(oracle))" }
    }

    /// A `VTIMEZONE` in the shape Outlook writes: rules that start in 1601, a yearly `RRULE` on a
    /// weekday of the month, and no `X-LIC-LOCATION`.
    static func outlookVTimeZone(
        tzid: String, standard: String, daylight: String?,
        standardRule: (start: String, rule: String)?, daylightRule: (start: String, rule: String)?
    ) -> [String] {
        var lines = ["BEGIN:VTIMEZONE", "TZID:\(tzid)", "BEGIN:STANDARD"]
        if let daylight, let standardRule, let daylightRule {
            lines += ["DTSTART:\(standardRule.start)", "RRULE:\(standardRule.rule)",
                      "TZOFFSETFROM:\(daylight)", "TZOFFSETTO:\(standard)", "END:STANDARD",
                      "BEGIN:DAYLIGHT", "DTSTART:\(daylightRule.start)", "RRULE:\(daylightRule.rule)",
                      "TZOFFSETFROM:\(standard)", "TZOFFSETTO:\(daylight)", "END:DAYLIGHT"]
        } else {
            lines += ["DTSTART:16010101T000000", "TZOFFSETFROM:\(standard)", "TZOFFSETTO:\(standard)", "END:STANDARD"]
        }
        return lines + ["END:VTIMEZONE"]
    }

    static let pacific = Zone(
        tzid: "Pacific Standard Time", oracle: "America/Los_Angeles",
        vtimezone: outlookVTimeZone(tzid: "Pacific Standard Time", standard: "-0800", daylight: "-0700",
                                    standardRule: ("16011104T020000", "FREQ=YEARLY;BYDAY=1SU;BYMONTH=11"),
                                    daylightRule: ("16010311T020000", "FREQ=YEARLY;BYDAY=2SU;BYMONTH=3")))
    static let tokyo = Zone(
        tzid: "Tokyo Standard Time", oracle: "Asia/Tokyo",
        vtimezone: outlookVTimeZone(tzid: "Tokyo Standard Time", standard: "+0900", daylight: nil,
                                    standardRule: nil, daylightRule: nil))
    static let westEurope = Zone(
        tzid: "W. Europe Standard Time", oracle: "Europe/Berlin",
        vtimezone: outlookVTimeZone(
            tzid: "W. Europe Standard Time", standard: "+0100", daylight: "+0200",
            standardRule: ("16011028T030000", "FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10"),
            daylightRule: ("16010325T020000", "FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3")))
    /// A name no table knows, whose `VTIMEZONE` gives its zone as `X-LIC-LOCATION` (and rules).
    static let berlinByLocation = Zone(
        tzid: "Custom Berlin", oracle: "Europe/Berlin",
        vtimezone: ["BEGIN:VTIMEZONE", "TZID:Custom Berlin", "X-LIC-LOCATION:Europe/Berlin",
                    "BEGIN:STANDARD", "DTSTART:16010101T000000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0100",
                    "END:STANDARD", "END:VTIMEZONE"])

    static let recognized: [Zone] = [pacific, tokyo, westEurope, berlinByLocation]

    /// Outlook's "Customized Time Zone": a name no table knows, defined only by its rules and with no
    /// `X-LIC-LOCATION`, so TabMail does not recognize it.
    static let unmatchedTZID = "Customized Time Zone"
    static let unmatched = outlookVTimeZone(
        tzid: unmatchedTZID, standard: "-0500", daylight: "-0400",
        standardRule: ("16011104T020000", "FREQ=YEARLY;BYDAY=1SU;BYMONTH=11"),
        daylightRule: ("16010311T020000", "FREQ=YEARLY;BYDAY=2SU;BYMONTH=3"))

    static func resource(_ vtimezone: [String], _ vevents: [[String]]) -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN"] + vtimezone
            + vevents.flatMap { $0 } + ["END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
    }

    /// One event, 2099-07-15 10:00 to 11:00 in `tzid` (the parameter as written).
    static func singleEvent(tzid: String, vtimezone: [String]) -> String {
        resource(vtimezone, [[
            "BEGIN:VEVENT", "UID:single-tz", "DTSTAMP:20990101T000000Z",
            "DTSTART;TZID=\(tzid):20990715T100000", "DTEND;TZID=\(tzid):20990715T110000",
            "SUMMARY:Planning", "END:VEVENT",
        ]])
    }

    /// A weekly series from 2099-03-02 10:00 in `tzid` with five occurrences, the third deleted and
    /// the fourth changed, ending by a UTC `UNTIL` after the fifth.
    static func series(tzid: String, vtimezone: [String]) -> String {
        resource(vtimezone, [
            ["BEGIN:VEVENT", "UID:series-tz", "DTSTAMP:20990101T000000Z",
             "DTSTART;TZID=\(tzid):20990302T100000", "DTEND;TZID=\(tzid):20990302T110000",
             "RRULE:FREQ=WEEKLY;UNTIL=20990331T000000Z", "EXDATE;TZID=\(tzid):20990316T100000",
             "SUMMARY:Weekly sync", "END:VEVENT"],
            ["BEGIN:VEVENT", "UID:series-tz", "DTSTAMP:20990101T000000Z",
             "RECURRENCE-ID;TZID=\(tzid):20990323T100000",
             "DTSTART;TZID=\(tzid):20990323T113000", "DTEND;TZID=\(tzid):20990323T123000",
             "SUMMARY:Weekly sync (moved)", "END:VEVENT"],
        ])
    }

    /// `wall` (`yyyyMMddTHHmmss`) in the IANA zone `zone`.
    static func instant(_ wall: String, in zone: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let ianaZone = try #require(TimeZone(identifier: zone))
        formatter.timeZone = ianaZone
        return try #require(formatter.date(from: wall))
    }

    /// The naive `recurrence_id` for `instant`, declared in UTC.
    static func naiveUTC(_ instant: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: instant)
    }

    /// `ics` with every `TZID=<zone.tzid>` parameter renamed to the oracle's IANA name, so the
    /// test-side `SeriesOracle` can read it without the code under test.
    static func aliased(_ ics: String, _ zone: Zone) -> String {
        ics.replacingOccurrences(of: "TZID=\(zone.tzid):", with: "TZID=\(zone.oracle):")
            .replacingOccurrences(of: "TZID=\(zone.tzid);", with: "TZID=\(zone.oracle);")
    }

    /// The instant a date-time property line names, read by the test: a UTC value, or a `TZID`
    /// value read in the oracle zone of `zone` (or an IANA `TZID` as written).
    static func lineInstant(_ line: String, _ zone: Zone) throws -> Date {
        let colon = try #require(line.firstIndex(of: ":"))
        let head = line[..<colon]
        let value = String(line[line.index(after: colon)...])
        if value.hasSuffix("Z") {
            return try instant(String(value.dropLast()), in: "UTC")
        }
        let tzid = try #require(head.split(separator: ";").first { $0.hasPrefix("TZID=") }, "no TZID in \(line)")
            .dropFirst("TZID=".count)
        return try instant(value, in: String(tzid) == zone.tzid ? zone.oracle : String(tzid))
    }

    /// Every VEVENT of a resource as logical lines, sub-components dropped.
    static func vevents(_ ics: String) -> [[String]] {
        var out: [[String]] = []
        var current: [String]?
        var depth = 0
        for line in CalDAVProvider.icsLines(ics) {
            if line == "BEGIN:VEVENT" { current = []; depth = 0; continue }
            if line == "END:VEVENT" { if let current { out.append(current) }; current = nil; continue }
            if line.hasPrefix("BEGIN:") { depth += 1; continue }
            if line.hasPrefix("END:") { depth -= 1; continue }
            if depth == 0 { current?.append(line) }
        }
        return out
    }

    /// Every `TZID` a resource's events use has its `VTIMEZONE` in the resource or is an IANA name,
    /// so a strict server accepts the resource and every client reads it at the same instants.
    static func undefinedZones(_ ics: String) -> Set<String> {
        let lines = CalDAVProvider.icsLines(ics)
        let defined = Set(lines.filter { $0.hasPrefix("TZID:") }.map { String($0.dropFirst("TZID:".count)) })
        var used = Set<String>()
        for line in lines where !line.hasPrefix("TZID:") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            for parameter in line[..<colon].split(separator: ";") where parameter.hasPrefix("TZID=") {
                used.insert(String(parameter.dropFirst("TZID=".count)))
            }
        }
        return used.filter { !defined.contains($0) && TimeZone(identifier: $0) == nil }
    }

    /// Whether `error` is the refusal that names `tzid` as a zone TabMail does not recognize.
    static func namesZone(_ error: any Error, _ tzid: String) -> Bool {
        guard case CalendarProviderError.notSupported(let reason) = error else { return false }
        return reason.contains("This event uses the time zone \"\(tzid)\", which TabMail does not recognize")
    }

    /// Whether `error` is, word for word, the refusal a write that changes an event gives for the
    /// zone `tzid` TabMail does not recognize: what it did not do and the change's remedy, never
    /// the words of a delete (`CalDAVProvider.ZoneRefusal.change`).
    static func refusesTheChange(_ error: any Error, _ tzid: String) -> Bool {
        guard case CalendarProviderError.notSupported(let reason) = error else { return false }
        return reason == "This event uses the time zone \"\(tzid)\", which TabMail does not recognize, so it did not change the event. Change the time in your calendar app instead."
            && !reason.contains("Nothing was deleted")
    }

    /// The start an ICSParser read of `ics` shows.
    static func parsedStart(_ ics: String) throws -> Date {
        let event = try #require(ICSParser.parse(icsText: ics, resourceHref: "/cal/single.ics", etag: nil).first)
        return try #require(event.start?.dateTime.flatMap { Date.fromISO8601($0) })
    }
}

// MARK: - Reading

@Suite("ICSParser: an event's time zone is read at its own instants")
struct ICSParserTimeZoneTests {

    @Test("an event in a recognized zone is read at that zone's instant, whatever the device's zone",
          arguments: TimeZoneFixture.recognized)
    func readsAtTheZonesInstant(zone: TimeZoneFixture.Zone) throws {
        let ics = TimeZoneFixture.singleEvent(tzid: zone.tzid, vtimezone: zone.vtimezone)
        let event = try #require(ICSParser.parse(icsText: ics, resourceHref: "/cal/single.ics", etag: nil).first)
        let start = try #require(event.start?.dateTime.flatMap { Date.fromISO8601($0) })
        let end = try #require(event.end?.dateTime.flatMap { Date.fromISO8601($0) })
        #expect(start == (try TimeZoneFixture.instant("20990715T100000", in: zone.oracle)))
        #expect(end == (try TimeZoneFixture.instant("20990715T110000", in: zone.oracle)))
    }

    @Test("non-vacuity: some fixture zone's offset differs from the device's, so the read test can tell them apart")
    func fixturesDifferFromTheDevice() throws {
        let sample = try TimeZoneFixture.instant("20990715T100000", in: "UTC")
        let differing = try TimeZoneFixture.recognized.filter {
            try #require(TimeZone(identifier: $0.oracle)).secondsFromGMT(for: sample) != TimeZone.current.secondsFromGMT(for: sample)
        }
        #expect(differing.count >= 2, "device zone \(TimeZone.current.identifier)")
    }

    @Test("an X-LIC-LOCATION folded over two lines, and a quoted TZID, still name the location's zone")
    func foldedLocationAndQuotedTZID() throws {
        let expected = try TimeZoneFixture.instant("20990715T100000", in: "Europe/Berlin")
        let folded = TimeZoneFixture.singleEvent(
            tzid: "Custom Berlin",
            vtimezone: TimeZoneFixture.berlinByLocation.vtimezone.map {
                $0 == "X-LIC-LOCATION:Europe/Berlin" ? "X-LIC-LOCATION:Euro\r\n pe/Berlin" : $0
            })
        #expect(folded.contains("Euro\r\n pe/Berlin"), "setup: the line was not folded")
        #expect(try TimeZoneFixture.parsedStart(folded) == expected)
        let quoted = TimeZoneFixture.singleEvent(
            tzid: "\"Custom Berlin\"",
            vtimezone: TimeZoneFixture.berlinByLocation.vtimezone.map { $0 == "TZID:Custom Berlin" ? "TZID:\"Custom Berlin\"" : $0 })
        #expect(quoted.contains("DTSTART;TZID=\"Custom Berlin\":"), "setup: the TZID was not quoted")
        #expect(try TimeZoneFixture.parsedStart(quoted) == expected)
    }

    @Test("when a resource defines one TZID twice, the first definition is the one read")
    func firstDefinitionWins() throws {
        let second = ["BEGIN:VTIMEZONE", "TZID:Custom Berlin", "X-LIC-LOCATION:Asia/Tokyo", "END:VTIMEZONE"]
        let ics = TimeZoneFixture.singleEvent(tzid: "Custom Berlin", vtimezone: TimeZoneFixture.berlinByLocation.vtimezone + second)
        let berlin = try TimeZoneFixture.instant("20990715T100000", in: "Europe/Berlin")
        #expect(berlin != (try TimeZoneFixture.instant("20990715T100000", in: "Asia/Tokyo")), "non-vacuity")
        #expect(try TimeZoneFixture.parsedStart(ics) == berlin)
    }

    @Test("an event in a zone TabMail does not recognize is still shown, read in the device's zone")
    func unrecognizedZoneIsStillShown() throws {
        let ics = TimeZoneFixture.singleEvent(tzid: TimeZoneFixture.unmatchedTZID, vtimezone: TimeZoneFixture.unmatched)
        let event = try #require(ICSParser.parse(icsText: ics, resourceHref: "/cal/single.ics", etag: nil).first)
        #expect(event.summary == "Planning")
        let start = try #require(event.start?.dateTime.flatMap { Date.fromISO8601($0) })
        #expect(start == (try TimeZoneFixture.instant("20990715T100000", in: TimeZone.current.identifier)))
    }
}

/// The Windows zone names `ICSBuilder` read before the CLDR table replaced its own map, each with
/// the zone that map gave it. An invite in any of them must still be read at the same instant.
@Suite("ICSBuilder: the time zones of incoming invites")
struct ICSBuilderTimeZoneTests {

    static let previouslyMapped: [(windows: String, iana: String)] = [
        ("Eastern Standard Time", "America/New_York"),
        ("Central Standard Time", "America/Chicago"),
        ("Mountain Standard Time", "America/Denver"),
        ("Pacific Standard Time", "America/Los_Angeles"),
        ("GMT Standard Time", "Europe/London"),
        ("W. Europe Standard Time", "Europe/Berlin"),
        ("Romance Standard Time", "Europe/Paris"),
        ("Central European Standard Time", "Europe/Warsaw"),
        ("E. Europe Standard Time", "Europe/Bucharest"),
        ("Tokyo Standard Time", "Asia/Tokyo"),
        ("China Standard Time", "Asia/Shanghai"),
        ("India Standard Time", "Asia/Kolkata"),
        ("AUS Eastern Standard Time", "Australia/Sydney"),
        ("UTC", "UTC"),
    ]

    @Test("an invite in a Windows zone ICSBuilder mapped before is read at the same instant",
          arguments: previouslyMapped.map(\.windows))
    func previouslyMappedNameReadsTheSame(windows: String) throws {
        let iana = try #require(Self.previouslyMapped.first { $0.windows == windows }?.iana)
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DTSTART;TZID=\(windows):20990715T100000
        END:VEVENT
        END:VCALENDAR
        """
        #expect(ICSBuilder.parseIncoming(ics)?.startDate == (try TimeZoneFixture.instant("20990715T100000", in: iana)))
    }

    @Test("an invite in a zone only its own VTIMEZONE's X-LIC-LOCATION names is read at that zone's instant")
    func zoneNamedByTheInvitesLocation() throws {
        let zone = TimeZoneFixture.berlinByLocation
        let parsed = try #require(ICSBuilder.parseIncoming(TimeZoneFixture.singleEvent(tzid: zone.tzid, vtimezone: zone.vtimezone)))
        #expect(parsed.startDate == (try TimeZoneFixture.instant("20990715T100000", in: zone.oracle)))
        #expect(parsed.endDate == (try TimeZoneFixture.instant("20990715T110000", in: zone.oracle)))
    }
}

// MARK: - Writing

/// Every CalDAV write of an event in a recognized zone lands at the right instants, and every write
/// that needs the instants of an event in a zone TabMail does not recognize is refused, naming the
/// zone, with nothing sent. Observed at the resource the server holds (`FakeCalDAVStore`).
@Suite("CalDAVProvider: writes of an event in a non-IANA time zone", .serialized)
struct CalDAVTimeZoneWireTests {

    private static let calendarId = CalDAVWireFixture.calendarId
    private static let path = "/cal/tz-event.ics"

    private static func serve(_ ics: String) -> (FakeHTTP.Scenario, FakeCalDAVStore) {
        let http = FakeHTTP.Scenario()
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: path, ics: ics)
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
        http.register(path: "/cal/", method: "REPORT") { store.handleREPORT($0) }
        return (http, store)
    }

    private static func timePatch(_ start: Date, _ end: Date, zone: String?) -> GCalEventInput {
        var patch = GCalEventInput()
        patch.startDateTime = start.iso8601String(timeZone: TimeZone(identifier: "UTC") ?? .current)
        patch.endDateTime = end.iso8601String(timeZone: TimeZone(identifier: "UTC") ?? .current)
        patch.startTimeZone = zone
        patch.endTimeZone = zone
        return patch
    }

    @Test("an edit of an event's time lands at the right instants, keeping the TZID the resource defines",
          arguments: TimeZoneFixture.recognized, [false, true])
    func editLandsAtTheRightInstants(zone: TimeZoneFixture.Zone, patchNamesTheZone: Bool) async throws {
        let (http, store) = Self.serve(TimeZoneFixture.singleEvent(tzid: zone.tzid, vtimezone: zone.vtimezone))
        defer { http.close() }
        let start = try TimeZoneFixture.instant("20990715T140000", in: zone.oracle)
        let end = try TimeZoneFixture.instant("20990715T153000", in: zone.oracle)

        _ = try await CalDAVWireFixture.makeProvider(http).updateEvent(
            calendarId: Self.calendarId, eventId: Self.path,
            event: Self.timePatch(start, end, zone: patchNamesTheZone ? zone.oracle : nil), sendUpdates: "none")

        let stored = try #require(store.storedICS(path: Self.path))
        let master = try #require(TimeZoneFixture.vevents(stored).first)
        #expect(try TimeZoneFixture.lineInstant(try #require(master.first { $0.hasPrefix("DTSTART") }), zone) == start)
        #expect(try TimeZoneFixture.lineInstant(try #require(master.first { $0.hasPrefix("DTEND") }), zone) == end)
        #expect(TimeZoneFixture.undefinedZones(stored).isEmpty, "\(TimeZoneFixture.undefinedZones(stored)):\n\(stored)")
        // The event's own zone, named by the patch by its IANA name or not named, stays under the
        // TZID the resource defines.
        for name in ["DTSTART", "DTEND"] {
            let line = try #require(master.first { $0.hasPrefix(name) })
            #expect(line.hasPrefix("\(name);TZID=\(zone.tzid):"), Comment(rawValue: line))
        }
    }

    @Test("moving a series' time keeps its deleted, changed and last occurrences, in a recognized zone",
          arguments: TimeZoneFixture.recognized)
    func seriesMoveKeepsEveryOccurrence(zone: TimeZoneFixture.Zone) async throws {
        let seed = TimeZoneFixture.series(tzid: zone.tzid, vtimezone: zone.vtimezone)
        #expect(try SeriesOracle.states(TimeZoneFixture.aliased(seed, zone)) == [.shown, .shown, .deleted, .changed, .shown],
                "non-vacuity")
        let (http, store) = Self.serve(seed)
        defer { http.close() }
        let start = try TimeZoneFixture.instant("20990302T150000", in: zone.oracle)
        let end = try TimeZoneFixture.instant("20990302T160000", in: zone.oracle)

        _ = try await CalDAVWireFixture.makeProvider(http).updateEvent(
            calendarId: Self.calendarId, eventId: Self.path, event: Self.timePatch(start, end, zone: nil), sendUpdates: "none")

        let stored = try #require(store.storedICS(path: Self.path))
        let master = try #require(TimeZoneFixture.vevents(stored).first)
        #expect(try TimeZoneFixture.lineInstant(try #require(master.first { $0.hasPrefix("DTSTART") }), zone) == start)
        #expect(try SeriesOracle.states(TimeZoneFixture.aliased(stored, zone)) == [.shown, .shown, .deleted, .changed, .shown],
                Comment(rawValue: stored))
    }

    @Test("a one-occurrence edit names the occurrence meant, in a recognized zone", arguments: TimeZoneFixture.recognized)
    func overrideNamesTheOccurrence(zone: TimeZoneFixture.Zone) async throws {
        let (http, store) = Self.serve(TimeZoneFixture.series(tzid: zone.tzid, vtimezone: zone.vtimezone))
        defer { http.close() }
        let occurrence = try TimeZoneFixture.instant("20990309T100000", in: zone.oracle)
        let start = try TimeZoneFixture.instant("20990309T120000", in: zone.oracle)
        let end = try TimeZoneFixture.instant("20990309T130000", in: zone.oracle)
        var patch = Self.timePatch(start, end, zone: nil)
        patch.summary = "Weekly sync (later)"

        _ = try await CalDAVWireFixture.makeProvider(http).updateOccurrence(
            calendarId: Self.calendarId, eventId: Self.path,
            recurrenceId: TimeZoneFixture.naiveUTC(occurrence), recurrenceIdZone: try #require(TimeZone(identifier: "UTC")),
            event: patch, sendUpdates: "none")

        let stored = try #require(store.storedICS(path: Self.path))
        #expect(try SeriesOracle.states(TimeZoneFixture.aliased(stored, zone)) == [.shown, .changed, .deleted, .changed, .shown],
                Comment(rawValue: stored))
        let override = try #require(TimeZoneFixture.vevents(stored).first { $0.contains("SUMMARY:Weekly sync (later)") })
        #expect(try TimeZoneFixture.lineInstant(try #require(override.first { $0.hasPrefix("RECURRENCE-ID") }), zone) == occurrence)
        #expect(try TimeZoneFixture.lineInstant(try #require(override.first { $0.hasPrefix("DTSTART") }), zone) == start)
        #expect(TimeZoneFixture.undefinedZones(stored).isEmpty, "\(TimeZoneFixture.undefinedZones(stored))")
    }

    @Test("a split divides the series' occurrences between the two parts, in a recognized zone",
          arguments: TimeZoneFixture.recognized)
    func splitDividesTheOccurrences(zone: TimeZoneFixture.Zone) async throws {
        let (http, store) = Self.serve(TimeZoneFixture.series(tzid: zone.tzid, vtimezone: zone.vtimezone))
        defer { http.close() }
        let splitAt = try TimeZoneFixture.instant("20990309T100000", in: zone.oracle)

        _ = try await CalDAVWireFixture.makeProvider(http).splitSeries(
            calendarId: Self.calendarId, eventId: Self.path,
            recurrenceId: TimeZoneFixture.naiveUTC(splitAt), recurrenceIdZone: try #require(TimeZone(identifier: "UTC")),
            patch: GCalEventInput(), sendUpdates: "none")

        let capped = try #require(store.storedICS(path: Self.path))
        let newPath = try #require(store.recordedPuts().map(\.path).first { $0 != Self.path })
        let newPart = try #require(store.storedICS(path: newPath))
        #expect(try SeriesOracle.states(TimeZoneFixture.aliased(capped, zone)) == [.shown], Comment(rawValue: capped))
        #expect(try SeriesOracle.states(TimeZoneFixture.aliased(newPart, zone)) == [.shown, .deleted, .changed, .shown],
                Comment(rawValue: newPart))
        let newMaster = try #require(TimeZoneFixture.vevents(newPart).first { !$0.contains { $0.hasPrefix("RECURRENCE-ID") } })
        #expect(try TimeZoneFixture.lineInstant(try #require(newMaster.first { $0.hasPrefix("DTSTART") }), zone) == splitAt)
        #expect(TimeZoneFixture.undefinedZones(newPart).isEmpty, "\(TimeZoneFixture.undefinedZones(newPart))")
    }

    /// The ids and starts a listing of March 2099 shows for the resource, by start.
    private static func march(_ provider: CalDAVProvider) async throws -> [String] {
        let rows = try await provider.listEvents(
            calendarId: Self.calendarId, timeMin: try TimeZoneFixture.instant("20990301T000000", in: "UTC"),
            timeMax: try TimeZoneFixture.instant("20990401T000000", in: "UTC"),
            query: nil, singleEvents: true, maxResults: 250, orderBy: "startTime")
        return rows.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .map { "\($0.id ?? "-") | \($0.start?.dateTime ?? "-")" }
    }

    @Test("deleting one occurrence excludes it at its wall time under the series' own TZID, in a recognized zone",
          arguments: TimeZoneFixture.recognized)
    func occurrenceDeleteExcludesItInTheSeriesZone(zone: TimeZoneFixture.Zone) async throws {
        let seed = TimeZoneFixture.series(tzid: zone.tzid, vtimezone: zone.vtimezone)
        let (http, store) = Self.serve(seed)
        defer { http.close() }
        let provider = CalDAVWireFixture.makeProvider(http)
        let occurrence = try TimeZoneFixture.instant("20990309T100000", in: zone.oracle)
        let id = CalDAVOccurrences.OccurrenceId.make(seriesHref: Self.path, key: OccurrenceFixture.utcValue(occurrence))
        let before = try await Self.march(provider)
        #expect(before.contains { $0.hasPrefix(id + " |") }, "setup: the occurrence is not listed: \(before)")

        try await provider.deleteEvent(calendarId: Self.calendarId, eventId: id, sendUpdates: "none")

        #expect(store.recordedPuts().count == 1, "expected one PUT: \(store.recordedPuts().map(\.path))")
        let stored = try #require(store.storedICS(path: Self.path))
        let master = try #require(TimeZoneFixture.vevents(stored).first)
        #expect(master.contains("EXDATE;TZID=\(zone.tzid):20990309T100000"), "stored:\n\(stored)")
        #expect(try SeriesOracle.states(TimeZoneFixture.aliased(stored, zone)) == [.shown, .deleted, .deleted, .changed, .shown],
                Comment(rawValue: stored))
        let after = try await Self.march(provider)
        #expect(after == before.filter { !$0.hasPrefix(id + " |") }, "the listing did not lose exactly that occurrence.\nbefore: \(before)\nafter: \(after)")
    }

    @Test("the delete's check refuses a series in an unrecognized zone by name, in the delete's words, before it looks the occurrence up")
    func occurrenceDeleteCheckRefusesTheZoneFirst() throws {
        let tzid = TimeZoneFixture.unmatchedTZID
        let seed = TimeZoneFixture.series(tzid: tzid, vtimezone: TimeZoneFixture.unmatched)
        // A key no expansion of the series gives, in any device zone: looked up first, it would be
        // reported not found instead of naming the zone.
        #expect {
            _ = try CalDAVOccurrences.deletion(icsText: seed, href: Self.path, key: "20990309T150700Z")
        } throws: { error in
            guard case CalendarProviderError.notSupported(let reason) = error else { return false }
            return reason == "This event uses the time zone \"\(tzid)\", which TabMail does not recognize, so it can't delete one occurrence of it. Nothing was deleted. The user can delete it in their calendar app."
        }
    }

    // MARK: Unrecognized

    enum Write: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case timeEdit = "an edit of an event's time"
        case seriesMove = "moving a series' time"
        case override = "a one-occurrence edit"
        case split = "a split"
        var testDescription: String { rawValue }
    }

    @Test("a write that needs the instants of an event in an unrecognized zone is refused, naming the zone, with nothing sent",
          arguments: Write.allCases)
    func unrecognizedZoneIsRefused(write: Write) async throws {
        let tzid = TimeZoneFixture.unmatchedTZID
        let seed = write == .timeEdit
            ? TimeZoneFixture.singleEvent(tzid: tzid, vtimezone: TimeZoneFixture.unmatched)
            : TimeZoneFixture.series(tzid: tzid, vtimezone: TimeZoneFixture.unmatched)
        #expect(TimeZone(identifier: tzid) == nil, "non-vacuity: the zone is not an IANA name")
        let (http, store) = Self.serve(seed)
        defer { http.close() }
        let provider = CalDAVWireFixture.makeProvider(http)
        let utc = try #require(TimeZone(identifier: "UTC"))
        let instant = try TimeZoneFixture.instant("20990309T150000", in: "UTC")
        let patch = Self.timePatch(instant, instant.addingTimeInterval(3_600), zone: nil)

        await #expect {
            switch write {
            case .timeEdit, .seriesMove:
                _ = try await provider.updateEvent(calendarId: Self.calendarId, eventId: Self.path, event: patch, sendUpdates: "none")
            case .override:
                _ = try await provider.updateOccurrence(
                    calendarId: Self.calendarId, eventId: Self.path, recurrenceId: TimeZoneFixture.naiveUTC(instant),
                    recurrenceIdZone: utc, event: patch, sendUpdates: "none")
            case .split:
                _ = try await provider.splitSeries(
                    calendarId: Self.calendarId, eventId: Self.path, recurrenceId: TimeZoneFixture.naiveUTC(instant),
                    recurrenceIdZone: utc, patch: GCalEventInput(), sendUpdates: "none")
            }
        } throws: { error in
            TimeZoneFixture.namesZone(error, tzid) && TimeZoneFixture.refusesTheChange(error, tzid)
        }
        #expect(store.recordedPuts().isEmpty, "a PUT was sent: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: Self.path) == seed)
    }

    enum OccurrenceCall: String, CaseIterable, CustomTestStringConvertible {
        case override = "a one-occurrence edit"
        case split = "a split"
        case startDay = "the read of the day an occurrence starts on"
        var testDescription: String { rawValue }
    }

    @Test("a timed series in an unrecognized zone is refused by name before its occurrences are worked out, with nothing written",
          arguments: OccurrenceCall.allCases)
    func timedSeriesInUnrecognizedZoneIsRefusedByName(call: OccurrenceCall) async throws {
        let tzid = TimeZoneFixture.unmatchedTZID
        let seed = TimeZoneFixture.series(tzid: tzid, vtimezone: TimeZoneFixture.unmatched)
        let (http, store) = Self.serve(seed)
        defer { http.close() }
        let provider = CalDAVWireFixture.makeProvider(http)
        let utc = try #require(TimeZone(identifier: "UTC"))
        // 2099-03-09 10:00 at the zone's -05:00: the series' second occurrence, so a device-zone
        // expansion would report it not found rather than name the zone.
        let rid = "2099-03-09T15:00:00"
        await #expect {
            switch call {
            case .override:
                var patch = GCalEventInput()
                patch.summary = "Renamed"
                _ = try await provider.updateOccurrence(
                    calendarId: Self.calendarId, eventId: Self.path, recurrenceId: rid,
                    recurrenceIdZone: utc, event: patch, sendUpdates: "none")
            case .split:
                _ = try await provider.splitSeries(
                    calendarId: Self.calendarId, eventId: Self.path, recurrenceId: rid,
                    recurrenceIdZone: utc, patch: GCalEventInput(), sendUpdates: "none")
            case .startDay:
                _ = try await provider.occurrenceStartDay(
                    calendarId: Self.calendarId, eventId: Self.path, recurrenceId: rid, recurrenceIdZone: utc)
            }
        } throws: { error in
            TimeZoneFixture.namesZone(error, tzid) && TimeZoneFixture.refusesTheChange(error, tzid)
        }
        #expect(store.recordedPuts().isEmpty, "a PUT was sent: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: Self.path) == seed)
    }

    enum OverrideOnlyCall: String, CaseIterable, CustomTestStringConvertible {
        case override = "a one-occurrence edit"
        case startDay = "the read of the day an occurrence starts on"
        var testDescription: String { rawValue }
    }

    @Test("a changed occurrence held without its series, in an unrecognized zone, is refused by name in the change's words, with nothing written",
          arguments: OverrideOnlyCall.allCases)
    func changedOccurrenceWithoutSeriesInUnrecognizedZoneIsRefused(call: OverrideOnlyCall) async throws {
        let tzid = TimeZoneFixture.unmatchedTZID
        let seed = TimeZoneFixture.resource(TimeZoneFixture.unmatched, [[
            "BEGIN:VEVENT", "UID:series-tz", "DTSTAMP:20990101T000000Z",
            "RECURRENCE-ID;TZID=\(tzid):20990309T100000",
            "DTSTART;TZID=\(tzid):20990309T110000", "DTEND;TZID=\(tzid):20990309T120000",
            "SUMMARY:Weekly sync, moved", "END:VEVENT",
        ]])
        let (http, store) = Self.serve(seed)
        defer { http.close() }
        let provider = CalDAVWireFixture.makeProvider(http)
        let utc = try #require(TimeZone(identifier: "UTC"))
        // The occurrence as a listing names it: with no series, its frame is its RECURRENCE-ID's,
        // the zone TabMail does not recognize.
        let rows = try await provider.listEvents(
            calendarId: Self.calendarId, timeMin: try TimeZoneFixture.instant("20990301T000000", in: "UTC"),
            timeMax: try TimeZoneFixture.instant("20990401T000000", in: "UTC"),
            query: nil, singleEvents: true, maxResults: 250, orderBy: "startTime")
        try #require(rows.count == 1, "setup: the changed occurrence is not listed once: \(rows.map { $0.id ?? "-" })")
        let id = try #require(rows[0].id)
        let rid = TimeZoneFixture.naiveUTC(try #require(rows[0].startDate))
        await #expect {
            switch call {
            case .override:
                var patch = GCalEventInput()
                patch.summary = "Renamed"
                _ = try await provider.updateOccurrence(
                    calendarId: Self.calendarId, eventId: id, recurrenceId: rid,
                    recurrenceIdZone: utc, event: patch, sendUpdates: "none")
            case .startDay:
                _ = try await provider.occurrenceStartDay(
                    calendarId: Self.calendarId, eventId: id, recurrenceId: rid, recurrenceIdZone: utc)
            }
        } throws: { error in
            TimeZoneFixture.namesZone(error, tzid) && TimeZoneFixture.refusesTheChange(error, tzid)
        }
        #expect(store.recordedPuts().isEmpty, "a PUT was sent: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: Self.path) == seed)
    }

    /// A weekly all-day series from 2099-03-02 whose DTSTART carries a TZID TabMail does not
    /// recognize next to VALUE=DATE: a date has no zone, so the TZID is never read.
    private static func allDaySeriesWithUnrecognizedTZID() -> String {
        let tzid = TimeZoneFixture.unmatchedTZID
        return TimeZoneFixture.resource(TimeZoneFixture.unmatched, [[
            "BEGIN:VEVENT", "UID:allday-tz", "DTSTAMP:20990101T000000Z",
            "DTSTART;VALUE=DATE;TZID=\(tzid):20990302", "DTEND;VALUE=DATE;TZID=\(tzid):20990303",
            "RRULE:FREQ=WEEKLY;COUNT=5", "SUMMARY:Offsite", "END:VEVENT",
        ]])
    }

    @Test("an all-day series whose date start carries an unrecognized TZID stays editable: its start day is read and one occurrence is written")
    func allDaySeriesWithUnrecognizedTZIDStaysEditable() async throws {
        let (http, store) = Self.serve(Self.allDaySeriesWithUnrecognizedTZID())
        defer { http.close() }
        let provider = CalDAVWireFixture.makeProvider(http)
        let utc = try #require(TimeZone(identifier: "UTC"))

        let day = try await provider.occurrenceStartDay(
            calendarId: Self.calendarId, eventId: Self.path, recurrenceId: "2099-03-09T00:00:00", recurrenceIdZone: utc)
        #expect(day == "2099-03-09")

        var patch = GCalEventInput()
        patch.summary = "Offsite (renamed)"
        _ = try await provider.updateOccurrence(
            calendarId: Self.calendarId, eventId: Self.path, recurrenceId: "2099-03-09T00:00:00",
            recurrenceIdZone: utc, event: patch, sendUpdates: "none")
        let stored = try #require(store.storedICS(path: Self.path))
        #expect(store.recordedPuts().count == 1)
        #expect(stored.contains("RECURRENCE-ID;VALUE=DATE"), "stored:\n\(stored)")
        #expect(stored.contains("20990309"))
        #expect(stored.contains("SUMMARY:Offsite (renamed)"))
    }

    @Test("an edit that needs no instant of an event in an unrecognized zone still lands")
    func titleEditOfUnrecognizedZoneLands() async throws {
        let seed = TimeZoneFixture.series(tzid: TimeZoneFixture.unmatchedTZID, vtimezone: TimeZoneFixture.unmatched)
        let (http, store) = Self.serve(seed)
        defer { http.close() }
        var patch = GCalEventInput()
        patch.summary = "Renamed sync"

        _ = try await CalDAVWireFixture.makeProvider(http).updateEvent(
            calendarId: Self.calendarId, eventId: Self.path, event: patch, sendUpdates: "none")

        let stored = try #require(store.storedICS(path: Self.path))
        #expect(stored.contains("SUMMARY:Renamed sync"))
        #expect(stored.contains("DTSTART;TZID=\(TimeZoneFixture.unmatchedTZID):20990302T100000"))
    }
}

// MARK: - The one resolver

/// Every place the app turns a zone NAME into a `TimeZone` does it through
/// `CalendarTimeZoneResolver`, so no path can recognize a zone another refuses or read it at
/// other instants. A zone named by a string literal (`"UTC"`) is not a name read from data. And a
/// resource's zone context is built only where one resource is read or written, once.
@Suite("Source fence: zone names become zones only in CalendarTimeZoneResolver")
struct CalendarTimeZoneResolverFenceTests {

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Providers
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
    }

    @Test("no non-literal TimeZone(identifier:) outside the resolver; contexts built only at the per-resource entry points")
    func noOtherZoneLookups() throws {
        let root = Self.repositoryRoot()
        let pattern = try NSRegularExpression(
            pattern: #"(TimeZone(\.init)?\(\s*identifier:(?!\s*"[^"]*"\s*\))|TimeZone\.init\(identifier:\)|NSTimeZone\(\s*name:)"#)
        var scanned = 0
        var offenders: [String] = []
        var contexts: [String: Int] = [:]
        for directory in ["TabMail", "Shared", "TabMailNotificationService"] {
            let base = root.appendingPathComponent(directory)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                guard url.lastPathComponent != "CalendarTimeZoneResolver.swift" else { continue }
                scanned += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                for (number, line) in source.components(separatedBy: "\n").enumerated() {
                    let code = line.components(separatedBy: "//").first ?? line
                    let range = NSRange(code.startIndex..., in: code)
                    if pattern.firstMatch(in: code, range: range) != nil {
                        offenders.append("\(directory)/\(url.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                    if code.contains("CalendarTimeZoneContext(calendarText:") {
                        contexts[url.lastPathComponent, default: 0] += 1
                    }
                }
            }
        }
        #expect(scanned > 100, "non-vacuity: only \(scanned) files were scanned")
        #expect(offenders.isEmpty, "zone names read outside CalendarTimeZoneResolver:\n\(offenders.joined(separator: "\n"))")
        // `ICSParser.parse`, `ICSBuilder.parseIncoming`, CalDAV's four write operations (update,
        // occurrence update, split, and the cap that finishes a split, `finishSplit`), and its
        // read of the day a moved all-day occurrence starts on (`occurrenceStartDay`), and its read
        // of the stored series for a move to another day (`dayMovedRules`). Each is one
        // resource's entry point: a context is built once per resource read, never per value.
        #expect(contexts == ["ICSParser.swift": 1, "ICSBuilder.swift": 1, "CalDAVProvider.swift": 6], "\(contexts)")
    }
}
