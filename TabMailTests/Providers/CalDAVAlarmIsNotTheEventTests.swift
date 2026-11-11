/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - An alarm's properties belong to the alarm, never to the event
//
// **INVARIANT.** *A VEVENT's properties are its own top-level lines. Lines inside a nested
// component (a VALARM) belong to that component.* RFC 5545 §3.6.6 requires `DESCRIPTION` on a
// DISPLAY alarm, and `SUMMARY`, `DESCRIPTION` and `ATTENDEE` on an EMAIL alarm; any alarm may carry
// `DURATION` with `REPEAT`, and RFC 9074 gives an alarm its own `UID`. None of these is the event's
// notes, title, attendee, length or identity.
//
// Read side: whatever reads a CalDAV event (`ICSParser.parse`, `CalDAVProvider.getEvent`,
// `CalDAVProvider.listEvents`, `CalDAVProvider.extractUID`) gives the event's own values, with the
// alarm after the event's properties (RFC 5545 order, which a last-wins reader gets wrong) and
// before them (which a first-match reader gets wrong).
//
// Write side: an edit drained through the real calendar queue never writes an alarm's recipient as
// an attendee or an alarm's text as the event's notes, and leaves every alarm byte for byte as
// stored, on every `edit_scope`.
//
// Every date is relative to today; every address is at example.com.

// MARK: - Reading a resource on the test side

/// The tests' own reading of an ICS resource, written here so that no assertion goes through the
/// code under test: line endings normalized, folding undone, nested components tracked by depth.
enum VEventOracle {
    static func physicalLines(_ ics: String) -> [String] {
        ics.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// Every VEVENT of a resource, `BEGIN:VEVENT` through `END:VEVENT`, as physical lines.
    static func vevents(_ ics: String) -> [[String]] {
        var out: [[String]] = []
        var current: [String]?
        for line in physicalLines(ics) {
            if line == "BEGIN:VEVENT" { current = [line]; continue }
            if line == "END:VEVENT", var block = current {
                block.append(line)
                out.append(block)
                current = nil
                continue
            }
            current?.append(line)
        }
        return out
    }

    /// Physical lines joined into logical lines (RFC 5545 §3.1 unfolding).
    static func logical(_ physical: [String]) -> [String] {
        var out: [String] = []
        for line in physical {
            if let first = line.first, first == " " || first == "\t", !out.isEmpty {
                out[out.count - 1] += String(line.dropFirst())
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// The VEVENT's own properties as logical lines: those outside every nested component.
    static func ownProperties(_ block: [String]) -> [String] {
        var depth = 0
        var out: [String] = []
        for line in logical(block) {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:") { depth += 1; continue }
            if upper.hasPrefix("END:") { depth -= 1; continue }
            if depth == 1 { out.append(line) }
        }
        return out
    }

    /// The VEVENT's own property lines named `name` (`NAME:` or `NAME;`).
    static func own(_ block: [String], _ name: String) -> [String] {
        ownProperties(block).filter {
            let upper = $0.uppercased()
            return upper.hasPrefix(name + ":") || upper.hasPrefix(name + ";")
        }
    }

    /// Each VALARM of the VEVENT, `BEGIN:VALARM` through `END:VALARM`, as its exact physical lines
    /// joined by CRLF.
    static func alarms(_ block: [String]) -> [String] {
        var out: [String] = []
        var current: [String]?
        for line in block {
            if line.uppercased() == "BEGIN:VALARM" { current = [line]; continue }
            guard current != nil else { continue }
            current?.append(line)
            if line.uppercased() == "END:VALARM", let alarm = current {
                out.append(alarm.joined(separator: "\r\n"))
                current = nil
            }
        }
        return out
    }

    static func isOverride(_ block: [String]) -> Bool { !own(block, "RECURRENCE-ID").isEmpty }

    static func master(_ ics: String) -> [String]? { vevents(ics).first { !isOverride($0) } }

    static func overrides(_ ics: String) -> [[String]] { vevents(ics).filter { isOverride($0) } }

    /// The lowercased `mailto:` address of a property line.
    static func address(_ line: String) -> String? {
        guard let range = line.range(of: "mailto:", options: .caseInsensitive) else { return nil }
        return String(line[range.upperBound...]).lowercased()
    }

    /// Logical lines of the resource that mention `text` and are not inside a VALARM.
    static func outsideAlarms(_ ics: String, mentioning text: String) -> [String] {
        var inAlarm = false
        var out: [String] = []
        for line in logical(physicalLines(ics)) {
            let upper = line.uppercased()
            if upper == "BEGIN:VALARM" { inAlarm = true; continue }
            if upper == "END:VALARM" { inAlarm = false; continue }
            if !inAlarm, line.lowercased().contains(text.lowercased()) { out.append(line) }
        }
        return out
    }
}

// MARK: - The event and its alarms

enum AlarmFixture {
    static let utc = TimeZone(identifier: "UTC") ?? .current
    static let uid = "planning-603"
    static let path = "/cal/planning-603.ics"
    static let home = URL(string: "https://caldav.example.com/cal/")!
    static let alarmRecipient = "alerts@example.com"

    /// The series' first start: 17:00 UTC, a week from today.
    static let start: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let day = cal.startOfDay(for: Date().addingTimeInterval(7 * 86_400))
        return day.addingTimeInterval(17 * 3_600)
    }()

    /// The occurrence two weeks after the first.
    static let occurrence = start.addingTimeInterval(14 * 86_400)

    static func icsUTC(_ date: Date) -> String { format(date, "yyyyMMdd'T'HHmmss'Z'") }
    static func naiveUTC(_ date: Date) -> String { format(date, "yyyy-MM-dd'T'HH:mm:ss") }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = utc
        return formatter.string(from: date)
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    enum Alarm: String, CaseIterable, Sendable {
        case display = "a DISPLAY alarm"
        case email = "an EMAIL alarm"
        case repeating = "a repeating alarm"
        case ownUID = "an alarm with its own UID"

        var lines: [String] {
            switch self {
            case .display:
                return ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-PT15M", "END:VALARM"]
            case .email:
                return ["BEGIN:VALARM", "ACTION:EMAIL", "SUMMARY:Alarm notification", "DESCRIPTION:Soon",
                        "ATTENDEE:mailto:\(AlarmFixture.alarmRecipient)", "TRIGGER:-PT15M", "END:VALARM"]
            case .repeating:
                return ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-PT15M",
                        "REPEAT:2", "DURATION:PT5M", "END:VALARM"]
            case .ownUID:
                return ["BEGIN:VALARM", "UID:alarm-of-\(AlarmFixture.uid)", "ACTION:AUDIO", "TRIGGER:-PT15M", "END:VALARM"]
            }
        }
    }

    enum Position: String, CaseIterable, Sendable {
        case after = "after the event's properties"
        case before = "before the event's properties"
    }

    struct Shape: Sendable, CustomTestStringConvertible {
        let alarm: Alarm
        let position: Position
        let ownNotes: Bool

        var testDescription: String {
            "\(alarm.rawValue) \(position.rawValue), \(ownNotes ? "with" : "without") notes of its own"
        }

        static let all: [Shape] = Alarm.allCases.flatMap { alarm in
            Position.allCases.flatMap { position in
                [true, false].map { Shape(alarm: alarm, position: position, ownNotes: $0) }
            }
        }
    }

    /// One weekly series VEVENT, 1 hour long by `DURATION`, with its own title, organizer and one
    /// attendee, its own notes when `ownNotes`, and `alarm` where `position` puts it.
    static func resource(_ shape: Shape) -> String {
        var own = [
            "UID:\(uid)", "DTSTAMP:\(icsUTC(Date()))", "DTSTART:\(icsUTC(start))", "DURATION:PT1H",
            "RRULE:FREQ=WEEKLY", "SUMMARY:Planning",
            "ORGANIZER;CN=Olivia:mailto:olivia@example.com",
            "ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com",
        ]
        if shape.ownNotes { own.append("DESCRIPTION:Agenda") }
        let body = shape.position == .after ? own + shape.alarm.lines : shape.alarm.lines + own
        return (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN", "BEGIN:VEVENT"]
            + body + ["END:VEVENT", "END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
    }

    /// The read invariant: every value is the event's own. The title, the own attendee and the own
    /// notes are also the non-vacuity anchors (a reader that read nothing fails them).
    static func expectTheEventsOwnValues(_ event: GCalEvent?, _ shape: Shape, via entry: String) {
        guard let event else {
            Issue.record("\(entry) gave no event for \(shape.testDescription)")
            return
        }
        #expect(event.summary == "Planning", "\(entry): the title is \(event.summary ?? "<none>")")
        #expect(event.description == (shape.ownNotes ? "Agenda" : nil),
                "\(entry): the notes are \(event.description ?? "<none>")")
        let addresses = (event.attendees ?? []).compactMap { $0.email?.lowercased() }
        #expect(addresses == ["alice@example.com"], "\(entry): the attendees are \(addresses)")
        #expect(event.start?.dateTime == iso(start), "\(entry): the start is \(event.start?.dateTime ?? "<none>")")
        #expect(event.end?.dateTime == iso(start.addingTimeInterval(3_600)),
                "\(entry): the end is \(event.end?.dateTime ?? "<none>"), not an hour after the start")
    }

    static func provider(_ http: FakeHTTP.Scenario) -> CalDAVProvider {
        CalDAVProvider(
            client: CalDAVClient(username: "user@example.com", password: "pw", session: http.session),
            calendarHomeURL: home, serverBaseURL: home)
    }

    /// A CalDAV `calendar-query` REPORT answer holding `ics` under `path`.
    static func multistatus(_ ics: String) -> Data {
        let escaped = ics.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:response>
            <d:href>\(path)</d:href>
            <d:propstat>
              <d:prop>
                <d:getetag>"report-1"</d:getetag>
                <c:calendar-data>\(escaped)</c:calendar-data>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8)
    }
}

// MARK: - T1: reading

@Suite("A CalDAV event is read with its own values, never its alarm's")
struct CalDAVAlarmIsNotTheEventReadTests {

    @Test("ICSParser.parse gives the event's own notes, title, attendees and length",
          arguments: AlarmFixture.Shape.all)
    func parseReadsTheEventsOwnValues(_ shape: AlarmFixture.Shape) {
        let events = ICSParser.parse(icsText: AlarmFixture.resource(shape), resourceHref: AlarmFixture.path, etag: nil)
        #expect(events.count == 1, "parse gave \(events.count) events")
        AlarmFixture.expectTheEventsOwnValues(events.first, shape, via: "ICSParser.parse")
    }

    @Test("CalDAVProvider.getEvent gives the event's own notes, title, attendees and length",
          arguments: AlarmFixture.Shape.all)
    func getEventReadsTheEventsOwnValues(_ shape: AlarmFixture.Shape) async throws {
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: AlarmFixture.path, ics: AlarmFixture.resource(shape))
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        let event = try await AlarmFixture.provider(http).getEvent(calendarId: "/cal/", eventId: AlarmFixture.path)
        AlarmFixture.expectTheEventsOwnValues(event, shape, via: "getEvent")
    }

    /// The listing's range. With no range the series is listed once, at its first date; with a
    /// range it is expanded into its occurrences (`CalDAVOccurrences.listing`). The range here holds
    /// only the first occurrence.
    enum ListingRange: String, CaseIterable, Sendable {
        case none = "no range"
        case firstOccurrence = "a range holding the first occurrence"

        var bounds: (min: Date?, max: Date?) {
            switch self {
            case .none: return (nil, nil)
            case .firstOccurrence:
                return (AlarmFixture.start.addingTimeInterval(-3_600), AlarmFixture.start.addingTimeInterval(86_400))
            }
        }
    }

    @Test("CalDAVProvider.listEvents gives the event's own notes, title, attendees and length",
          arguments: AlarmFixture.Shape.all, ListingRange.allCases)
    func listEventsReadsTheEventsOwnValues(_ shape: AlarmFixture.Shape, _ range: ListingRange) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/cal/", method: "REPORT", response: .raw(
            statusCode: 207, headers: ["Content-Type": "application/xml; charset=utf-8"],
            body: AlarmFixture.multistatus(AlarmFixture.resource(shape))))
        let events = try await AlarmFixture.provider(http).listEvents(
            calendarId: "/cal/", timeMin: range.bounds.min, timeMax: range.bounds.max, query: nil,
            singleEvents: false, maxResults: 50, orderBy: "startTime")
        #expect(events.count == 1, "listEvents gave \(events.count) events")
        AlarmFixture.expectTheEventsOwnValues(events.first, shape, via: "listEvents (\(range.rawValue))")
    }

    @Test("CalDAVProvider.extractUID gives the event's UID, not its alarm's",
          arguments: AlarmFixture.Position.allCases)
    func extractUIDIsTheEventsOwn(_ position: AlarmFixture.Position) {
        let shape = AlarmFixture.Shape(alarm: .ownUID, position: position, ownNotes: false)
        let uid = CalDAVProvider.extractUID(from: AlarmFixture.resource(shape))
        #expect(uid == AlarmFixture.uid, "the UID read is \(uid ?? "<none>")")
    }
}

// MARK: - T2: writing through the queue

@Suite("A CalDAV edit through the queue writes nothing of an alarm as the event's", .serialized, .processGlobalState)
struct CalDAVAlarmIsNotTheEventWriteTests {

    enum Scope: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case all
        case thisOnly = "this_only"
        case thisAndFollowing = "this_and_following"

        var testDescription: String { rawValue }

        var arguments: [String: JSONValue] {
            switch self {
            case .all:
                return [:]
            case .thisOnly, .thisAndFollowing:
                return ["edit_scope": .string(rawValue),
                        "recurrence_id": .string(AlarmFixture.naiveUTC(AlarmFixture.occurrence)),
                        "timezone": .string("UTC")]
            }
        }
    }

    /// The series' alarms exactly as stored: a DISPLAY alarm, then an EMAIL alarm whose text the
    /// server folded across two physical lines.
    static let storedAlarms = [
        ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-PT15M", "END:VALARM"],
        ["BEGIN:VALARM", "ACTION:EMAIL", "SUMMARY:Alarm notification",
         "DESCRIPTION:Soon\\, the planning meeting starts in fifteen minutes and its agenda i",
         " s attached", "ATTENDEE:mailto:\(AlarmFixture.alarmRecipient)", "TRIGGER:-PT15M", "END:VALARM"],
    ].map { $0.joined(separator: "\r\n") }

    /// A weekly series with its own notes and one attendee, and the two alarms after its properties.
    static func series() -> String {
        ([
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN", "BEGIN:VEVENT",
            "UID:\(AlarmFixture.uid)", "DTSTAMP:\(AlarmFixture.icsUTC(Date()))",
            "DTSTART:\(AlarmFixture.icsUTC(AlarmFixture.start))", "DURATION:PT1H", "RRULE:FREQ=WEEKLY",
            "SUMMARY:Planning", "DESCRIPTION:Agenda",
            "ORGANIZER;CN=Olivia:mailto:olivia@example.com",
            "ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com",
        ] + storedAlarms + ["END:VEVENT", "END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
    }

    private struct Run {
        let store: FakeCalDAVStore
        let http: FakeHTTP.Scenario
        let provider: CalDAVProvider
    }

    private static func setUp() -> Run {
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: AlarmFixture.path, ics: series())
        let http = FakeHTTP.Scenario()
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
        return Run(store: store, http: http, provider: AlarmFixture.provider(http))
    }

    private static func drain(_ run: Run, _ scope: Scope, _ edit: [String: JSONValue], account: String) async throws
        -> [PendingCalendarOperation] {
        try await drainEdit(accountId: account, eventId: AlarmFixture.path, calendarId: "/cal/",
                            arguments: edit.merging(scope.arguments) { edited, _ in edited }, provider: run.provider)
    }

    /// Every resource the edit left on the server.
    private static func storedResources(_ run: Run, _ scope: Scope) -> [String] {
        var paths = [AlarmFixture.path]
        if scope == .thisAndFollowing {
            let newUid = GoogleCalendarProvider.deterministicSplitEventId(
                masterId: AlarmFixture.path, recurrenceId: AlarmFixture.naiveUTC(AlarmFixture.occurrence))
            paths.append("/cal/\(newUid).ics")
        }
        return paths.compactMap { run.store.storedICS(path: $0) }
    }

    /// The VEVENT the edit wrote: the series, the changed occurrence, or the split's new part.
    private static func editedEvent(_ run: Run, _ scope: Scope) throws -> [String] {
        let resources = storedResources(run, scope)
        let series = try #require(resources.first, "no series is stored")
        switch scope {
        case .all:
            return try #require(VEventOracle.master(series), "the series has no VEVENT:\n\(series)")
        case .thisOnly:
            return try #require(VEventOracle.overrides(series).first, "no changed occurrence was written:\n\(series)")
        case .thisAndFollowing:
            #expect(resources.count == 2, "no new part was written; PUTs: \(run.store.recordedPuts().map(\.path))")
            let newPart = try #require(resources.last)
            return try #require(VEventOracle.master(newPart), "the new part has no VEVENT:\n\(newPart)")
        }
    }

    /// Every VEVENT the server holds after the edit keeps the stored alarms byte for byte, and no
    /// alarm recipient appears outside an alarm.
    private static func expectAlarmsUntouched(_ run: Run, _ scope: Scope) {
        let resources = storedResources(run, scope)
        for resource in resources {
            for block in VEventOracle.vevents(resource) {
                #expect(VEventOracle.alarms(block) == storedAlarms,
                        "a VEVENT's alarms changed:\n\(block.joined(separator: "\n"))")
            }
            #expect(VEventOracle.outsideAlarms(resource, mentioning: AlarmFixture.alarmRecipient).isEmpty,
                    "the alarm's recipient was written outside the alarm:\n\(resource)")
        }
    }

    @Test("adding an attendee writes the event's own attendees and the added one, never the alarm's recipient",
          arguments: Scope.allCases)
    func addAttendeeWritesNoAlarmRecipient(_ scope: Scope) async throws {
        let run = Self.setUp()
        defer { run.http.close() }
        let rows = try await Self.drain(run, scope, [
            "add_attendees": .array([.dictionary(["email": .string("carol@example.com"), "name": .string("Carol")])]),
        ], account: "alarm-attendee-\(scope.rawValue)")
        #expect(rows.isEmpty, "the edit did not land: \(rows.first?.failureReason ?? "<none>")")

        let event = try Self.editedEvent(run, scope)
        let attendees = VEventOracle.own(event, "ATTENDEE").compactMap(VEventOracle.address)
        #expect(attendees.sorted() == ["alice@example.com", "carol@example.com"],
                "the event's attendees are \(attendees):\n\(event.joined(separator: "\n"))")
        Self.expectAlarmsUntouched(run, scope)
    }

    @Test("adding to the notes builds on the event's own notes, never on an alarm's text",
          arguments: Scope.allCases)
    func addToNotesKeepsTheEventsOwnNotes(_ scope: Scope) async throws {
        let run = Self.setUp()
        defer { run.http.close() }
        // The assistant reads the event (`calendar_event_read` is `getEvent`) and writes back its
        // notes with the addition.
        let read = try await run.provider.getEvent(calendarId: "/cal/", eventId: AlarmFixture.path)
        let addition = "Dial-in: https://example.com/join"
        let notes = [read.description, addition].compactMap { $0 }.joined(separator: "\n\n")
        let rows = try await Self.drain(run, scope, ["description": .string(notes)],
                                        account: "alarm-notes-\(scope.rawValue)")
        #expect(rows.isEmpty, "the edit did not land: \(rows.first?.failureReason ?? "<none>")")

        let event = try Self.editedEvent(run, scope)
        let descriptions = VEventOracle.own(event, "DESCRIPTION")
        #expect(descriptions.count == 1, "the event has \(descriptions.count) notes:\n\(event.joined(separator: "\n"))")
        let written = descriptions.first.flatMap { line -> String? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return ICSParser.unescapeText(String(line[line.index(after: colon)...]))
        }
        #expect(written == "Agenda\n\n\(addition)",
                "the notes written are \(written ?? "<none>"), not the event's own notes with the addition")
        Self.expectAlarmsUntouched(run, scope)
    }

    @Test("a rename leaves every alarm as stored", arguments: Scope.allCases)
    func renameLeavesTheAlarms(_ scope: Scope) async throws {
        let run = Self.setUp()
        defer { run.http.close() }
        let rows = try await Self.drain(run, scope, ["title": .string("Planning review")],
                                        account: "alarm-rename-\(scope.rawValue)")
        #expect(rows.isEmpty, "the edit did not land: \(rows.first?.failureReason ?? "<none>")")

        let event = try Self.editedEvent(run, scope)
        #expect(VEventOracle.own(event, "SUMMARY") == ["SUMMARY:Planning review"],
                "the event's title is \(VEventOracle.own(event, "SUMMARY"))")
        Self.expectAlarmsUntouched(run, scope)
    }
}
