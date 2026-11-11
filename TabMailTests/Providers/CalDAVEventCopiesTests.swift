/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// Property preservation for the CalDAV writes that copy a series' VEVENT: a one-occurrence
// override (`occurrenceOverrideResource`), a split's new part (`seriesSplitResources`), and the
// attendee replacement an edit of the whole series makes. Each test states the stored resource
// the server ends up holding, never how it was built.

// MARK: - Fixtures

private enum Fixture {
    /// A series carrying one of most properties a CalDAV server stores, including a folded line,
    /// escaped text, a quoted parameter with a comma, attendee roles and answers, and an alarm.
    static let richSeries = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Example//Test//EN",
        "BEGIN:VEVENT",
        "UID:series-1",
        "DTSTAMP:20990101T000000Z",
        "SEQUENCE:3",
        "CREATED:20990101T000000Z",
        "LAST-MODIFIED:20990102T000000Z",
        "DTSTART:20990506T170000Z",
        "DTEND:20990506T174500Z",
        "RRULE:FREQ=WEEKLY;UNTIL=20991230T170000Z",
        "SUMMARY:Lunch\\, then talk",
        "DESCRIPTION:A long description that the server folded across two physical l",
        " ines\\, with an escaped comma",
        "LOCATION:Room 1",
        "CLASS:PRIVATE",
        "CATEGORIES:Work,Planning",
        "PRIORITY:1",
        "URL:https://example.com/agenda",
        "STATUS:CONFIRMED",
        "TRANSP:OPAQUE",
        "X-EXAMPLE-FLAG:kept",
        "ORGANIZER;CN=Olivia:mailto:olivia@example.com",
        "ATTENDEE;CN=Olivia;PARTSTAT=ACCEPTED;ROLE=CHAIR:mailto:olivia@example.com",
        "ATTENDEE;CN=\"Doe, Alice\";ROLE=OPT-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:alice@example.com",
        "ATTENDEE;CN=Bob;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=DECLINED:mailto:bob@example.com",
        "BEGIN:VALARM",
        "ACTION:DISPLAY",
        "DESCRIPTION:Reminder",
        "TRIGGER:-PT15M",
        "END:VALARM",
        "END:VEVENT",
        "END:VCALENDAR",
    ].joined(separator: "\r\n") + "\r\n"

    /// The series' own lines a copy must carry unchanged (logical, unfolded).
    static let keptLines = [
        "DESCRIPTION:A long description that the server folded across two physical lines\\, with an escaped comma",
        "LOCATION:Room 1",
        "CLASS:PRIVATE",
        "CATEGORIES:Work,Planning",
        "PRIORITY:1",
        "URL:https://example.com/agenda",
        "STATUS:CONFIRMED",
        "TRANSP:OPAQUE",
        "X-EXAMPLE-FLAG:kept",
        "ORGANIZER;CN=Olivia:mailto:olivia@example.com",
        "ATTENDEE;CN=Olivia;PARTSTAT=ACCEPTED;ROLE=CHAIR:mailto:olivia@example.com",
        "ATTENDEE;CN=\"Doe, Alice\";ROLE=OPT-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:alice@example.com",
        "ATTENDEE;CN=Bob;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=DECLINED:mailto:bob@example.com",
        "BEGIN:VALARM",
        "ACTION:DISPLAY",
        "DESCRIPTION:Reminder",
        "TRIGGER:-PT15M",
        "END:VALARM",
    ]

    /// The series' revision. A one-occurrence override keeps it; a split's new part is a new event
    /// and starts without one (`newPartIdentity`).
    static let sequence = "SEQUENCE:3"

    /// The folded DESCRIPTION exactly as the server wrote it (two physical lines).
    static let foldedDescription = "DESCRIPTION:A long description that the server folded across two physical l\r\n ines\\, with an escaped comma"

    static func series(_ lines: [String]) -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0"] + lines + ["END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
    }

    /// Every VEVENT of a resource, as logical (unfolded) lines.
    static func vevents(_ ics: String) -> [[String]] {
        var out: [[String]] = []
        var current: [String]?
        for line in CalDAVProvider.icsLines(ics) {
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

    static func master(_ ics: String) -> [String] {
        vevents(ics).first { !$0.contains { $0.hasPrefix("RECURRENCE-ID") } } ?? []
    }

    static func overrides(_ ics: String) -> [[String]] {
        vevents(ics).filter { $0.contains { $0.hasPrefix("RECURRENCE-ID") } }
    }

    static func attendee(_ block: [String], _ address: String) -> String? {
        block.first { $0.hasPrefix("ATTENDEE") && $0.lowercased().hasSuffix("mailto:\(address)") }
    }

    static func stamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    static func patch(summary: String? = nil, description: String? = nil, location: String? = nil,
                      start: String? = nil, end: String? = nil,
                      attendees: [(email: String, name: String?)]? = nil) -> GCalEventInput {
        var p = GCalEventInput()
        p.summary = summary
        p.description = description
        p.location = location
        p.startDateTime = start
        p.endDateTime = end
        p.attendees = attendees
        return p
    }

    static func split(_ ics: String, slot: String = "2099-05-20T17:00:00", patch: GCalEventInput,
                      newRRule: String = "RRULE:FREQ=WEEKLY;UNTIL=20991230T170000Z",
                      cappedRRule: String = "RRULE:FREQ=WEEKLY;UNTIL=20990520T165959Z",
                      now: Date = Date()) throws -> CalDAVProvider.SeriesSplitResources {
        try CalDAVProvider.seriesSplitResources(
            storedICS: ics, slotNaiveISO: slot, cappedRRule: cappedRRule,
            newRRule: newRRule, newUid: "series-1-split", patch: patch, now: now)
    }

    static func overrideEdit(_ ics: String, recurrenceId: String = "2099-05-20T17:00:00",
                             patch: GCalEventInput, now: Date = Date()) throws -> String {
        try CalDAVProvider.occurrenceOverrideResource(
            storedICS: ics, recurrenceIdNaive: recurrenceId, patch: patch, now: now)
    }
}

/// The two copies, so a property both must keep is asserted on both.
enum CopyKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case occurrenceOverride = "one-occurrence edit"
    case splitNewPart = "split's new part"

    var testDescription: String { rawValue }

    /// The copy's VEVENT after `patch`, and the whole resource it was written into.
    func copy(of ics: String, patch: GCalEventInput, now: Date = Date()) throws -> (block: [String], resource: String) {
        switch self {
        case .occurrenceOverride:
            let out = try Fixture.overrideEdit(ics, patch: patch, now: now)
            return (try #require(Fixture.overrides(out).first, "no override was written:\n\(out)"), out)
        case .splitNewPart:
            let out = try Fixture.split(ics, patch: patch, now: now)
            return (Fixture.master(out.newPart), out.newPart)
        }
    }
}

// MARK: - Both copies

@Suite("CalDAV copies of a series keep its properties")
struct CalDAVEventCopiesTests {

    @Test("a copy keeps every property of the series that the edit does not change", arguments: CopyKind.allCases)
    func copyKeepsUnchangedProperties(_ kind: CopyKind) throws {
        let (block, resource) = try kind.copy(of: Fixture.richSeries, patch: Fixture.patch(summary: "Next phase"))
        let kept = Fixture.keptLines + (kind == .occurrenceOverride ? [Fixture.sequence] : [])
        for line in kept {
            #expect(block.contains(line), "the \(kind.rawValue) lost '\(line)':\n\(block.joined(separator: "\n"))")
        }
        #expect(block.contains("SUMMARY:Next phase"))
        #expect(resource.contains(Fixture.foldedDescription), "the folded DESCRIPTION was rewritten:\n\(resource)")
        // Properties come before the alarm (RFC 5545 component order).
        let alarm = try #require(block.firstIndex(of: "BEGIN:VALARM"))
        #expect(block[..<alarm].contains("SUMMARY:Next phase"))
    }

    @Test("text the series wrote with escapes is kept as written, and new text is escaped once", arguments: CopyKind.allCases)
    func escapedTextRoundTrips(_ kind: CopyKind) throws {
        let (block, _) = try kind.copy(of: Fixture.richSeries, patch: Fixture.patch(description: "Bring a, b; c"))
        #expect(block.contains("SUMMARY:Lunch\\, then talk"), "the series' SUMMARY changed:\n\(block.joined(separator: "\n"))")
        #expect(block.contains("DESCRIPTION:Bring a\\, b\\; c"))
        #expect(!block.contains { $0.contains("\\\\") }, "text was escaped twice:\n\(block.joined(separator: "\n"))")
        let summary = try #require(block.first { $0.hasPrefix("SUMMARY:") })
        #expect(ICSParser.unescapeText(String(summary.dropFirst("SUMMARY:".count))) == "Lunch, then talk")
    }

    @Test("attendees keep their role and answer when the edit does not reschedule", arguments: CopyKind.allCases)
    func answersKeptWithoutReschedule(_ kind: CopyKind) throws {
        let (block, _) = try kind.copy(of: Fixture.richSeries, patch: Fixture.patch(summary: "Renamed", description: "New notes"))
        for address in ["olivia@example.com", "alice@example.com", "bob@example.com"] {
            let line = try #require(Fixture.attendee(block, address))
            #expect(Fixture.keptLines.contains(line), "\(address) changed: \(line)")
        }
    }

    @Test("a reschedule asks every attendee but the organizer again, keeping their role",
          arguments: CopyKind.allCases, [
            Fixture.patch(start: "2099-05-20T18:00:00Z", end: "2099-05-20T18:45:00Z"),
            Fixture.patch(end: "2099-05-20T18:00:00Z"),
            Fixture.patch(start: "2099-05-20T16:45:00Z", end: "2099-05-20T17:45:00Z"),
            Fixture.patch(location: "Room 2"),
          ].indices.map { $0 })
    func rescheduleAsksAgain(_ kind: CopyKind, _ which: Int) throws {
        let patches = [
            Fixture.patch(start: "2099-05-20T18:00:00Z", end: "2099-05-20T18:45:00Z"),
            Fixture.patch(end: "2099-05-20T18:00:00Z"),
            Fixture.patch(start: "2099-05-20T16:45:00Z", end: "2099-05-20T17:45:00Z"),
            Fixture.patch(location: "Room 2"),
        ]
        let (block, _) = try kind.copy(of: Fixture.richSeries, patch: patches[which])
        let organizer = try #require(Fixture.attendee(block, "olivia@example.com"))
        #expect(organizer == "ATTENDEE;CN=Olivia;PARTSTAT=ACCEPTED;ROLE=CHAIR:mailto:olivia@example.com")
        let alice = try #require(Fixture.attendee(block, "alice@example.com"))
        #expect(alice.contains("PARTSTAT=NEEDS-ACTION") && alice.contains("RSVP=TRUE"), Comment(rawValue: alice))
        #expect(!alice.contains("PARTSTAT=ACCEPTED") && !alice.contains("RSVP=FALSE"), Comment(rawValue: alice))
        #expect(alice.contains("ROLE=OPT-PARTICIPANT") && alice.contains("CN=\"Doe, Alice\""), Comment(rawValue: alice))
        let bob = try #require(Fixture.attendee(block, "bob@example.com"))
        #expect(bob.contains("PARTSTAT=NEEDS-ACTION") && !bob.contains("DECLINED"), Comment(rawValue: bob))
        #expect(bob.contains("CUTYPE=INDIVIDUAL") && bob.contains("ROLE=REQ-PARTICIPANT"), Comment(rawValue: bob))
    }

    @Test("an all-day series with no end: restating its date keeps the answers, moving it asks again")
    func allDayWithNoEndKeepsAnswersUntilMoved() throws {
        let series = Fixture.series([
            "BEGIN:VEVENT", "UID:series-7", "DTSTART;VALUE=DATE:20990506", "RRULE:FREQ=WEEKLY",
            "SUMMARY:Offsite", "ORGANIZER;CN=Olivia:mailto:olivia@example.com",
            "ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com", "END:VEVENT",
        ])
        func alice(movedTo day: String) throws -> (override: String, newPart: String) {
            var patch = Fixture.patch(summary: "Offsite, day \(day)")
            patch.startDate = day
            let out = try Fixture.overrideEdit(series, recurrenceId: "2099-05-20", patch: patch)
            let block = try #require(Fixture.overrides(out).first, "no override was written:\n\(out)")
            let split = try CalDAVProvider.seriesSplitResources(
                storedICS: series, slotNaiveISO: "2099-05-20", cappedRRule: "RRULE:FREQ=WEEKLY;UNTIL=20990519",
                newRRule: "RRULE:FREQ=WEEKLY", newUid: "series-7-split", patch: patch, now: Date())
            return (try #require(Fixture.attendee(block, "alice@example.com")),
                    try #require(Fixture.attendee(Fixture.master(split.newPart), "alice@example.com")))
        }
        let kept = try alice(movedTo: "2099-05-20")
        #expect(kept.override == "ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com", Comment(rawValue: kept.override))
        #expect(kept.newPart == "ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com", Comment(rawValue: kept.newPart))
        let moved = try alice(movedTo: "2099-05-21")
        #expect(moved.override.contains("PARTSTAT=NEEDS-ACTION"), Comment(rawValue: moved.override))
        #expect(moved.newPart.contains("PARTSTAT=NEEDS-ACTION"), Comment(rawValue: moved.newPart))
    }

    @Test("an attendee the edit adds is asked; the others keep their lines", arguments: CopyKind.allCases)
    func addedAttendeeIsAsked(_ kind: CopyKind) throws {
        let attendees: [(email: String, name: String?)] = [
            ("olivia@example.com", "Olivia"), ("alice@example.com", "Doe, Alice"),
            ("bob@example.com", "Bob"), ("carol@example.com", "Carol"),
        ]
        let (block, _) = try kind.copy(of: Fixture.richSeries, patch: Fixture.patch(attendees: attendees))
        let carol = try #require(Fixture.attendee(block, "carol@example.com"))
        #expect(carol.contains("ROLE=REQ-PARTICIPANT") && carol.contains("PARTSTAT=NEEDS-ACTION") && carol.contains("RSVP=TRUE"), Comment(rawValue: carol))
        for address in ["alice@example.com", "bob@example.com"] {
            let line = try #require(Fixture.attendee(block, address))
            #expect(Fixture.keptLines.contains(line), "\(address) changed: \(line)")
        }
    }

    @Test("an alarm's own text is never taken for the event's", arguments: CopyKind.allCases)
    func alarmTextIsNotTheEventsText(_ kind: CopyKind) throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-1", "DTSTART:20990506T170000Z", "DTEND:20990506T174500Z",
            "RRULE:FREQ=WEEKLY", "SUMMARY:Sync",
            "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-PT15M", "END:VALARM",
            "END:VEVENT",
        ])
        let (block, _) = try kind.copy(of: ics, patch: Fixture.patch(description: "Agenda"))
        let alarm = try #require(block.firstIndex(of: "BEGIN:VALARM"))
        #expect(block[..<alarm].contains("DESCRIPTION:Agenda"), Comment(rawValue: block.joined(separator: "\n")))
        #expect(block[alarm...].contains("DESCRIPTION:Reminder"), "the alarm's text was replaced:\n\(block.joined(separator: "\n"))")
    }

    @Test("a new start without an end keeps the copy's length", arguments: CopyKind.allCases)
    func startAloneKeepsLength(_ kind: CopyKind) throws {
        let (block, _) = try kind.copy(of: Fixture.richSeries, patch: Fixture.patch(start: "2099-05-20T18:00:00Z"))
        #expect(block.contains("DTSTART:20990520T180000Z"))
        #expect(block.contains("DTEND:20990520T184500Z"), Comment(rawValue: block.joined(separator: "\n")))
    }

    @Test("a series measured by DURATION: an explicit end replaces it, a start alone keeps it", arguments: CopyKind.allCases)
    func durationSeries(_ kind: CopyKind) throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-1", "DTSTART:20990506T170000Z", "DURATION:PT1H",
            "RRULE:FREQ=WEEKLY", "SUMMARY:Sync",
            "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "REPEAT:2", "DURATION:PT5M", "END:VALARM",
            "END:VEVENT",
        ])
        let (ended, _) = try kind.copy(of: ics, patch: Fixture.patch(start: "2099-05-20T18:00:00Z", end: "2099-05-20T19:30:00Z"))
        let alarm = try #require(ended.firstIndex(of: "BEGIN:VALARM"))
        #expect(ended.contains("DTEND:20990520T193000Z"))
        #expect(!ended[..<alarm].contains { $0.hasPrefix("DURATION") }, "DURATION and DTEND together:\n\(ended.joined(separator: "\n"))")
        #expect(ended[alarm...].contains("DURATION:PT5M"), "the alarm's repeat interval was removed")

        let (moved, _) = try kind.copy(of: ics, patch: Fixture.patch(start: "2099-05-20T18:00:00Z"))
        #expect(moved.contains("DTSTART:20990520T180000Z"))
        #expect(moved.contains("DURATION:PT1H") && !moved.contains { $0.hasPrefix("DTEND") }, Comment(rawValue: moved.joined(separator: "\n")))
    }

    /// The edits of the issue's case that leave the notes alone: a rename, and a move in time.
    enum NotesUntouchedEdit: String, CaseIterable, Sendable {
        case rename = "a rename"
        case move = "a move in time"
    }

    @Test("a series with an alert and no notes, edited without its notes, gives a copy with no notes and the alert as stored",
          arguments: CopyKind.allCases, NotesUntouchedEdit.allCases)
    func alertOnlySeriesCopyHasNoNotes(_ kind: CopyKind, _ edit: NotesUntouchedEdit) throws {
        // Dates relative to today: a weekly series from 17:00 UTC a week from now, changed at its
        // third occurrence.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let start = utc.startOfDay(for: Date().addingTimeInterval(7 * 86_400)).addingTimeInterval(17 * 3_600)
        let slot = start.addingTimeInterval(14 * 86_400)
        func format(_ date: Date, _ pattern: String) -> String {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = utc.timeZone
            fmt.dateFormat = pattern
            return fmt.string(from: date)
        }
        let alarm = ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-PT15M", "END:VALARM"]
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-1", "DTSTAMP:\(Fixture.stamp(Date()))",
            "DTSTART:\(Fixture.stamp(start))", "DTEND:\(Fixture.stamp(start.addingTimeInterval(45 * 60)))",
            "RRULE:FREQ=WEEKLY", "SUMMARY:Sync",
        ] + alarm + ["END:VEVENT"])
        let patch: GCalEventInput
        switch edit {
        case .rename:
            patch = Fixture.patch(summary: "Sync, moved room")
        case .move:
            let moved = slot.addingTimeInterval(3_600)
            patch = Fixture.patch(start: format(moved, "yyyy-MM-dd'T'HH:mm:ss'Z'"),
                                  end: format(moved.addingTimeInterval(45 * 60), "yyyy-MM-dd'T'HH:mm:ss'Z'"))
        }
        let naiveSlot = format(slot, "yyyy-MM-dd'T'HH:mm:ss")
        let resource: String
        let block: [String]
        switch kind {
        case .occurrenceOverride:
            resource = try Fixture.overrideEdit(ics, recurrenceId: naiveSlot, patch: patch)
            block = try #require(VEventOracle.overrides(resource).first, "no override was written:\n\(resource)")
        case .splitNewPart:
            resource = try Fixture.split(
                ics, slot: naiveSlot, patch: patch, newRRule: "RRULE:FREQ=WEEKLY",
                cappedRRule: "RRULE:FREQ=WEEKLY;UNTIL=\(Fixture.stamp(slot.addingTimeInterval(-1)))").newPart
            block = try #require(VEventOracle.master(resource), "the new part has no VEVENT:\n\(resource)")
        }
        let text = block.joined(separator: "\n")
        // Non-vacuity: the copy is the series' event, carrying its own title or the new one.
        #expect(!VEventOracle.own(block, "SUMMARY").isEmpty, Comment(rawValue: text))
        #expect(VEventOracle.own(block, "DESCRIPTION").isEmpty, "the \(kind.rawValue) has notes:\n\(text)")
        #expect(VEventOracle.alarms(block) == [alarm.joined(separator: "\r\n")], "the alert changed:\n\(text)")
    }
}

// MARK: - One-occurrence override

/// A weekly series whose occurrence two weeks in was changed on its own, as another client may
/// leave it: cancelled, with its own alert, categories, link, revision, `X-` line, and attendees
/// who answered it differently from the series and are listed with other parameters. Every one of
/// these lines differs from the series'. Dates are relative to today.
private enum ChangedOccurrenceFixture {
    static let utc = TimeZone(identifier: "UTC") ?? .current

    /// The series' first start: 17:00 UTC, a week from today.
    static let seriesStart: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.startOfDay(for: Date()).addingTimeInterval(7 * 86_400 + 17 * 3_600)
    }()

    /// The changed occurrence's original start (its `RECURRENCE-ID`), two weeks after the first.
    static let slot = seriesStart.addingTimeInterval(14 * 86_400)
    static let length: TimeInterval = 45 * 60

    /// `20990520T170000Z`
    static func icsUTC(_ date: Date) -> String { format(date, "yyyyMMdd'T'HHmmss'Z'") }
    /// `2099-05-20T17:00:00`, the form `recurrence_id` takes in the series' frame.
    static func naive(_ date: Date) -> String { format(date, "yyyy-MM-dd'T'HH:mm:ss") }
    /// `2099-05-20T17:00:00Z`, the form a patch's start and end take.
    static func isoUTC(_ date: Date) -> String { format(date, "yyyy-MM-dd'T'HH:mm:ss'Z'") }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = utc
        fmt.dateFormat = pattern
        return fmt.string(from: date)
    }

    static let organizerAttendee = "ATTENDEE;CN=Olivia;PARTSTAT=ACCEPTED;ROLE=CHAIR:mailto:olivia@example.com"
    static let alice = "ATTENDEE;CN=Alice;CUTYPE=GROUP;ROLE=OPT-PARTICIPANT;PARTSTAT=TENTATIVE;RSVP=FALSE:mailto:alice@example.com"
    static let room = "ATTENDEE;CN=Room 4;CUTYPE=ROOM;ROLE=NON-PARTICIPANT;PARTSTAT=DECLINED:mailto:room-4@example.com"

    /// The occurrence's own properties that no edit below names.
    static let ownProperties = [
        "STATUS:CANCELLED",
        "CATEGORIES:Offsite,Travel",
        "URL:https://example.com/occurrence",
        "SEQUENCE:5",
        "X-EXAMPLE-OCCURRENCE:kept",
        "ORGANIZER;CN=Olivia:mailto:olivia@example.com",
    ]

    /// The occurrence's own alert, which is not the series'.
    static let ownAlarm = [
        "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Occurrence reminder", "TRIGGER:-PT1H", "END:VALARM",
    ]

    static var resource: String {
        let start = icsUTC(seriesStart)
        return Fixture.series([
            "BEGIN:VEVENT", "UID:series-10", "DTSTAMP:\(start)", "SEQUENCE:1",
            "DTSTART:\(start)", "DTEND:\(icsUTC(seriesStart.addingTimeInterval(length)))", "RRULE:FREQ=WEEKLY",
            "SUMMARY:Planning", "STATUS:CONFIRMED", "CATEGORIES:Work",
            "ORGANIZER;CN=Olivia:mailto:olivia@example.com", organizerAttendee,
            "ATTENDEE;CN=Alice;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:alice@example.com",
            "ATTENDEE;CN=Room 4;CUTYPE=ROOM;ROLE=NON-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:room-4@example.com",
            "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Series reminder", "TRIGGER:-PT15M", "END:VALARM",
            "END:VEVENT",
            "BEGIN:VEVENT", "UID:series-10", "RECURRENCE-ID:\(icsUTC(slot))", "DTSTAMP:\(start)",
            "DTSTART:\(icsUTC(slot))", "DTEND:\(icsUTC(slot.addingTimeInterval(length)))", "SUMMARY:Planning",
        ] + ownProperties + [organizerAttendee, alice, room] + ownAlarm + [
            "END:VEVENT",
        ])
    }
}

/// The edits made to the changed occurrence: none names its status, alert, categories, link,
/// revision or `X-` line.
enum ChangedOccurrenceEdit: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case rename = "a rename"
    case attendeeAdded = "an attendee added"
    case move = "a move"

    var testDescription: String { rawValue }

    var patch: GCalEventInput {
        switch self {
        case .rename:
            return Fixture.patch(summary: "Planning, offsite")
        case .attendeeAdded:
            return Fixture.patch(attendees: [
                ("olivia@example.com", "Olivia"), ("alice@example.com", "Alice"),
                ("room-4@example.com", "Room 4"), ("carol@example.com", "Carol"),
            ])
        case .move:
            let start = ChangedOccurrenceFixture.slot.addingTimeInterval(3_600)
            return Fixture.patch(start: ChangedOccurrenceFixture.isoUTC(start),
                                 end: ChangedOccurrenceFixture.isoUTC(start.addingTimeInterval(ChangedOccurrenceFixture.length)))
        }
    }
}

@Suite("CalDAV one-occurrence edit")
struct CalDAVOccurrenceOverrideTests {

    @Test("the override names the occurrence and carries no rule of the series")
    func overrideIdentity() throws {
        let now = Date()
        let out = try Fixture.overrideEdit(Fixture.richSeries, patch: Fixture.patch(summary: "Moved title"), now: now)
        #expect(Fixture.vevents(out).count == 2)
        let block = try #require(Fixture.overrides(out).first)
        #expect(block.filter { $0.hasPrefix("RECURRENCE-ID") } == ["RECURRENCE-ID:20990520T170000Z"])
        #expect(block.contains("UID:series-1"))
        #expect(block.contains("DTSTART:20990520T170000Z") && block.contains("DTEND:20990520T174500Z"))
        #expect(block.contains("DTSTAMP:\(Fixture.stamp(now))"))
        #expect(!block.contains { $0.hasPrefix("RRULE") || $0.hasPrefix("EXDATE") || $0.hasPrefix("RDATE") })
        // The series itself is untouched.
        #expect(Fixture.master(out) == Fixture.master(Fixture.richSeries))
    }

    @Test("an occurrence edit that gives a repeat rule writes no rule and keeps every answer",
          arguments: [false, true])
    func occurrenceIgnoresRule(_ changedBefore: Bool) throws {
        let ics = changedBefore
            ? try Fixture.overrideEdit(Fixture.richSeries, patch: Fixture.patch(summary: "Earlier change"))
            : Fixture.richSeries
        var patch = Fixture.patch(summary: "Renamed")
        patch.recurrence = ["RRULE:FREQ=DAILY"]

        let out = try Fixture.overrideEdit(ics, patch: patch)

        let blocks = Fixture.overrides(out)
        #expect(blocks.count == 1, "the occurrence has \(blocks.count) overrides:\n\(out)")
        let block = try #require(blocks.first)
        #expect(block.contains("SUMMARY:Renamed"), Comment(rawValue: block.joined(separator: "\n")))
        #expect(!block.contains { $0.hasPrefix("RRULE") }, Comment(rawValue: block.joined(separator: "\n")))
        for address in ["olivia@example.com", "alice@example.com", "bob@example.com"] {
            let line = try #require(Fixture.attendee(block, address))
            #expect(Fixture.keptLines.contains(line), "\(address) changed: \(line)")
        }
        #expect(Fixture.master(out) == Fixture.master(Fixture.richSeries))
    }

    @Test("an occurrence of a series with a start and no end can be changed")
    func startOnlySeries() throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-8", "DTSTART:20990506T170000Z", "RRULE:FREQ=WEEKLY",
            "SUMMARY:Reminder", "END:VEVENT",
        ])
        let out = try Fixture.overrideEdit(ics, patch: Fixture.patch(summary: "Renamed"))
        let block = try #require(Fixture.overrides(out).first)
        #expect(block.contains("RECURRENCE-ID:20990520T170000Z") && block.contains("DTSTART:20990520T170000Z"),
                Comment(rawValue: block.joined(separator: "\n")))
        #expect(block.contains("SUMMARY:Renamed"))
        #expect(!block.contains { $0.hasPrefix("DTEND") || $0.hasPrefix("DURATION") })
    }

    @Test("an occurrence of a zoned series with a start and no end keeps no length and every answer",
          arguments: ["Pacific/Pago_Pago", "Pacific/Kiritimati"])
    func zonedStartOnlySeries(_ zone: String) throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-9", "DTSTART;TZID=\(zone):20990506T170000", "RRULE:FREQ=WEEKLY",
            "SUMMARY:Reminder", "ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com", "END:VEVENT",
        ])
        // The occurrence's own start, as an instant.
        let offset = try #require(TimeZone(identifier: zone)).secondsFromGMT()
        var restated = Fixture.patch(summary: "Renamed")
        restated.startDateTime = try #require(Date.fromISO8601("2099-05-20T17:00:00Z"))
            .addingTimeInterval(TimeInterval(-offset)).iso8601String(timeZone: TimeZone(identifier: "UTC") ?? .current)
        for patch in [Fixture.patch(summary: "Renamed"), restated] {
            let out = try Fixture.overrideEdit(ics, patch: patch)
            let block = try #require(Fixture.overrides(out).first, "no override was written:\n\(out)")
            #expect(Fixture.attendee(block, "alice@example.com") == "ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com",
                    Comment(rawValue: block.joined(separator: "\n")))
            let start = try #require(block.first { $0.hasPrefix("DTSTART") })
            #expect(try CalDAVProvider.parseICSDateTime(start, zones: .none) == CalDAVProvider.parseICSDateTime("DTSTART;TZID=\(zone):20990520T170000", zones: .none),
                    Comment(rawValue: start))
            #expect(!block.contains { $0.hasPrefix("DURATION") })
            if let end = block.first(where: { $0.hasPrefix("DTEND") }) {
                #expect(try CalDAVProvider.parseICSDateTime(end, zones: .none) == CalDAVProvider.parseICSDateTime(start, zones: .none),
                        "the override gained a length: \(end)")
            }
        }
    }

    @Test("an occurrence changed before keeps its earlier changes")
    func existingOverrideKeepsItsChanges() throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-2",
            "DTSTART;TZID=Europe/Paris:20990506T090000", "DTEND;TZID=Europe/Paris:20990506T100000",
            "RRULE:FREQ=WEEKLY", "SUMMARY:Standup", "CLASS:PUBLIC", "END:VEVENT",
            "BEGIN:VEVENT", "UID:series-2", "RECURRENCE-ID;TZID=Europe/Paris:20990520T090000",
            "DTSTART;TZID=Europe/Paris:20990520T110000", "DTEND;TZID=Europe/Paris:20990520T120000",
            "SUMMARY:Special standup", "LOCATION:Room 9", "CLASS:CONFIDENTIAL", "X-EXAMPLE-NOTE:kept",
            "END:VEVENT",
        ])
        let out = try Fixture.overrideEdit(ics, recurrenceId: "2099-05-20T09:00:00", patch: Fixture.patch(description: "New notes"))
        let blocks = Fixture.overrides(out)
        #expect(blocks.count == 1, "the occurrence has \(blocks.count) overrides:\n\(out)")
        let block = try #require(blocks.first)
        for line in ["SUMMARY:Special standup", "LOCATION:Room 9", "CLASS:CONFIDENTIAL", "X-EXAMPLE-NOTE:kept",
                     "DTSTART;TZID=Europe/Paris:20990520T110000", "DTEND;TZID=Europe/Paris:20990520T120000",
                     "DESCRIPTION:New notes"] {
            #expect(block.contains(line), "lost '\(line)':\n\(block.joined(separator: "\n"))")
        }
        #expect(block.filter { $0.hasPrefix("RECURRENCE-ID") } == ["RECURRENCE-ID;TZID=Europe/Paris:20990520T090000"])
    }

    @Test("an occurrence changed on its own keeps its status, alert, categories, link, revision and attendees through an edit",
          arguments: ChangedOccurrenceEdit.allCases)
    func changedOccurrenceKeepsItsOwnProperties(_ edit: ChangedOccurrenceEdit) throws {
        typealias Stored = ChangedOccurrenceFixture
        let stored = Stored.resource
        let out = try Fixture.overrideEdit(stored, recurrenceId: Stored.naive(Stored.slot), patch: edit.patch)
        let blocks = Fixture.overrides(out)
        #expect(blocks.count == 1, "the occurrence has \(blocks.count) overrides:\n\(out)")
        let block = try #require(blocks.first)
        let text = Comment(rawValue: block.joined(separator: "\n"))

        #expect(block.filter { $0.hasPrefix("RECURRENCE-ID") } == ["RECURRENCE-ID:\(Stored.icsUTC(Stored.slot))"], text)
        for line in Stored.ownProperties {
            #expect(block.contains(line), "lost '\(line)':\n\(block.joined(separator: "\n"))")
        }
        // The occurrence's own alert, whole and after its properties; never the series' alert.
        let alarm = try #require(block.firstIndex(of: "BEGIN:VALARM"), text)
        #expect(Array(block[alarm..<min(alarm + Stored.ownAlarm.count, block.count)]) == Stored.ownAlarm, text)
        #expect(!block.contains("DESCRIPTION:Series reminder"), text)
        // The series is untouched.
        #expect(Fixture.master(out) == Fixture.master(stored))

        let organizer = try #require(Fixture.attendee(block, "olivia@example.com"), text)
        let alice = try #require(Fixture.attendee(block, "alice@example.com"), text)
        let room = try #require(Fixture.attendee(block, "room-4@example.com"), text)
        #expect(organizer == Stored.organizerAttendee)
        switch edit {
        case .rename:
            #expect(block.contains("SUMMARY:Planning\\, offsite"), text)
            #expect(alice == Stored.alice && room == Stored.room, text)
        case .attendeeAdded:
            #expect(alice == Stored.alice && room == Stored.room, text)
            let carol = try #require(Fixture.attendee(block, "carol@example.com"), text)
            #expect(carol.contains("PARTSTAT=NEEDS-ACTION") && carol.contains("RSVP=TRUE"), Comment(rawValue: carol))
        case .move:
            let start = Stored.slot.addingTimeInterval(3_600)
            #expect(block.contains("DTSTART:\(Stored.icsUTC(start))"), text)
            #expect(block.contains("DTEND:\(Stored.icsUTC(start.addingTimeInterval(Stored.length)))"), text)
            // Asked again for the new time, each keeping how they are listed.
            #expect(alice.contains("PARTSTAT=NEEDS-ACTION") && alice.contains("RSVP=TRUE"), Comment(rawValue: alice))
            #expect(!alice.contains("TENTATIVE") && !alice.contains("RSVP=FALSE"), Comment(rawValue: alice))
            #expect(alice.contains("CUTYPE=GROUP") && alice.contains("ROLE=OPT-PARTICIPANT") && alice.contains("CN=Alice"), Comment(rawValue: alice))
            #expect(room.contains("PARTSTAT=NEEDS-ACTION") && !room.contains("DECLINED"), Comment(rawValue: room))
            #expect(room.contains("CUTYPE=ROOM") && room.contains("ROLE=NON-PARTICIPANT") && room.contains("CN=Room 4"), Comment(rawValue: room))
        }
    }

    @Test("the override's identity and times take the series' value type", arguments: [
        ("DTSTART:20990506T170000", "DTEND:20990506T174500", "2099-05-20T17:00:00",
         "RECURRENCE-ID:20990520T170000", "DTSTART:20990520T170000"),
        ("DTSTART:20990506T170000Z", "DTEND:20990506T174500Z", "2099-05-20T17:00",
         "RECURRENCE-ID:20990520T170000Z", "DTSTART:20990520T170000Z"),
        ("DTSTART;TZID=America/Vancouver:20990506T170000", "DTEND;TZID=America/Vancouver:20990506T174500", "2099-05-20T17:00:00",
         "RECURRENCE-ID;TZID=America/Vancouver:20990520T170000", "DTSTART;TZID=America/Vancouver:20990520T170000"),
        ("DTSTART;VALUE=DATE:20990506", "DTEND;VALUE=DATE:20990507", "2099-05-20",
         "RECURRENCE-ID;VALUE=DATE:20990520", "DTSTART;VALUE=DATE:20990520"),
        ("DTSTART;VALUE=DATE:20990506", "DTEND;VALUE=DATE:20990507", "2099-05-20T00:00:00",
         "RECURRENCE-ID;VALUE=DATE:20990520", "DTSTART;VALUE=DATE:20990520"),
        ("DTSTART:20990506", "DTEND:20990507", "2099-05-20",
         "RECURRENCE-ID;VALUE=DATE:20990520", "DTSTART:20990520"),
    ])
    func valueTypes(_ start: String, _ end: String, _ recurrenceId: String, _ rid: String, _ dtstart: String) throws {
        let ics = Fixture.series(["BEGIN:VEVENT", "UID:series-4", start, end, "RRULE:FREQ=WEEKLY", "SUMMARY:Sync", "END:VEVENT"])
        let out = try Fixture.overrideEdit(ics, recurrenceId: recurrenceId, patch: Fixture.patch(summary: "Changed"))
        let block = try #require(Fixture.overrides(out).first)
        #expect(block.contains(rid), Comment(rawValue: block.joined(separator: "\n")))
        #expect(block.contains(dtstart), Comment(rawValue: block.joined(separator: "\n")))
    }

    @Test("an occurrence moved takes the series' value type for its new times; times on an all-day occurrence are refused")
    func movedOccurrenceTimes() throws {
        let zoned = Fixture.series([
            "BEGIN:VEVENT", "UID:series-5", "DTSTART;TZID=America/Vancouver:20990506T170000",
            "DTEND;TZID=America/Vancouver:20990506T174500", "RRULE:FREQ=WEEKLY", "SUMMARY:Sync", "END:VEVENT",
        ])
        let moved = try Fixture.overrideEdit(zoned, patch: Fixture.patch(start: "2099-05-20T18:30:00-07:00", end: "2099-05-20T19:00:00-07:00"))
        let block = try #require(Fixture.overrides(moved).first)
        #expect(block.contains("RECURRENCE-ID;TZID=America/Vancouver:20990520T170000"))
        #expect(block.contains("DTSTART;TZID=America/Vancouver:20990520T183000"))
        #expect(block.contains("DTEND;TZID=America/Vancouver:20990520T190000"))

        let allDay = Fixture.series([
            "BEGIN:VEVENT", "UID:series-6", "DTSTART;VALUE=DATE:20990506", "DTEND;VALUE=DATE:20990507",
            "RRULE:FREQ=WEEKLY", "SUMMARY:Holiday", "END:VEVENT",
        ])
        var byDate = GCalEventInput()
        byDate.startDate = "2099-05-21"
        byDate.endDate = "2099-05-22"
        let byDateOut = try Fixture.overrideEdit(allDay, recurrenceId: "2099-05-20", patch: byDate)
        let byDateBlock = try #require(Fixture.overrides(byDateOut).first)
        #expect(byDateBlock.contains("DTSTART;VALUE=DATE:20990521") && byDateBlock.contains("DTEND;VALUE=DATE:20990522"),
                Comment(rawValue: byDateBlock.joined(separator: "\n")))
        // Times on an all-day occurrence would make it timed, which a copy of the series never is:
        // refused, never written as the dates with the times dropped.
        #expect {
            _ = try Fixture.overrideEdit(allDay, recurrenceId: "2099-05-20",
                                         patch: Fixture.patch(start: "2099-05-21T09:30:00", end: "2099-05-22T09:30:00"))
        } throws: { error in
            if case CalendarProviderError.notSupported(let reason) = error {
                return reason == CalDAVProvider.kindChangeOnRepeatingMessage
            }
            return false
        }
    }

    @Test("a one-occurrence edit of a series that can't be read writes nothing and is refused as unsupported")
    func unreadableSeriesIsRefused() {
        let noStart = Fixture.series(["BEGIN:VEVENT", "UID:series-7", "RRULE:FREQ=WEEKLY", "SUMMARY:Broken", "END:VEVENT"])
        #expect {
            _ = try Fixture.overrideEdit(noStart, patch: Fixture.patch(summary: "x"))
        } throws: { error in
            if case CalendarProviderError.notSupported = error { return true }
            return false
        }
    }
}

// MARK: - Split

@Suite("CalDAV split of a series")
struct CalDAVSeriesSplitCopyTests {

    @Test("the new part is the series re-anchored at the split, under its own identity")
    func newPartIdentity() throws {
        let now = Date()
        let out = try Fixture.split(Fixture.richSeries, patch: Fixture.patch(summary: "Next phase"), now: now)
        let part = Fixture.master(out.newPart)
        #expect(part.contains("UID:series-1-split"))
        #expect(part.contains("DTSTART:20990520T170000Z") && part.contains("DTEND:20990520T174500Z"))
        #expect(part.contains("RRULE:FREQ=WEEKLY;UNTIL=20991230T170000Z"), "the new part lost the series' end date")
        #expect(part.contains("DTSTAMP:\(Fixture.stamp(now))"))
        #expect(!part.contains { $0.hasPrefix("SEQUENCE") || $0.hasPrefix("CREATED") || $0.hasPrefix("LAST-MODIFIED") })
        // The capped series changes its rule and nothing else.
        let capped = Fixture.master(out.cappedSeries)
        let stored = Fixture.master(Fixture.richSeries)
        #expect(capped.filter { !$0.hasPrefix("RRULE") } == stored.filter { !$0.hasPrefix("RRULE") })
        #expect(capped.contains("RRULE:FREQ=WEEKLY;UNTIL=20990520T165959Z"))
    }

    @Test("excluded dates, added dates and changed occurrences go with the part they fall in")
    func partitionAtTheSplit() throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-1", "DTSTART:20990506T170000Z", "DTEND:20990506T174500Z",
            "RRULE:FREQ=WEEKLY", "EXDATE:20990513T170000Z,20990527T170000Z",
            "RDATE:20990515T170000Z,20990529T170000Z", "SUMMARY:Sync", "END:VEVENT",
            "BEGIN:VEVENT", "UID:series-1", "RECURRENCE-ID:20990513T170000Z", "DTSTART:20990513T180000Z",
            "DTEND:20990513T184500Z", "SUMMARY:Early change", "END:VEVENT",
            "BEGIN:VEVENT", "UID:series-1", "RECURRENCE-ID:20990527T170000Z", "DTSTART:20990527T180000Z",
            "DTEND:20990527T184500Z", "SUMMARY:Late change", "SEQUENCE:2", "END:VEVENT",
        ])
        let out = try Fixture.split(ics, patch: Fixture.patch(summary: "Sync"))
        let capped = Fixture.master(out.cappedSeries)
        #expect(capped.contains("EXDATE:20990513T170000Z") && capped.contains("RDATE:20990515T170000Z"), Comment(rawValue: capped.joined(separator: "\n")))
        #expect(Fixture.overrides(out.cappedSeries).map { $0.first { $0.hasPrefix("SUMMARY") } } == ["SUMMARY:Early change"])
        let part = Fixture.master(out.newPart)
        #expect(part.contains("EXDATE:20990527T170000Z") && part.contains("RDATE:20990529T170000Z"), Comment(rawValue: part.joined(separator: "\n")))
        let moved = try #require(Fixture.overrides(out.newPart).first)
        #expect(Fixture.overrides(out.newPart).count == 1)
        #expect(moved.contains("SUMMARY:Late change") && moved.contains("UID:series-1-split"))
        #expect(moved.contains("RECURRENCE-ID:20990527T170000Z"), "a moved occurrence lost its absolute time")
    }

    @Test("a split that moves the new part's start moves the dates and occurrences tied to it; the capped series keeps its own")
    func movedNewPartTakesItsDatesAlong() throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-1", "DTSTART:20990506T170000Z", "DTEND:20990506T174500Z",
            "RRULE:FREQ=WEEKLY", "EXDATE:20990513T170000Z,20990527T170000Z",
            "RDATE:20990515T170000Z,20990529T170000Z", "SUMMARY:Sync", "END:VEVENT",
            "BEGIN:VEVENT", "UID:series-1", "RECURRENCE-ID:20990513T170000Z", "DTSTART:20990513T180000Z",
            "DTEND:20990513T184500Z", "SUMMARY:Early change", "END:VEVENT",
            "BEGIN:VEVENT", "UID:series-1", "RECURRENCE-ID:20990603T170000Z", "DTSTART:20990603T190000Z",
            "DTEND:20990603T194500Z", "SUMMARY:Late change", "END:VEVENT",
        ])
        // From the split on, the series runs an hour later.
        let out = try Fixture.split(ics, patch: Fixture.patch(start: "2099-05-20T18:00:00Z"))
        let part = Fixture.master(out.newPart)
        let partText = Comment(rawValue: part.joined(separator: "\n"))
        #expect(part.contains("DTSTART:20990520T180000Z") && part.contains("DTEND:20990520T184500Z"), partText)
        // Each value names an occurrence of the new part, which now falls an hour later.
        #expect(part.contains("EXDATE:20990527T180000Z") && part.contains("RDATE:20990529T180000Z"), partText)
        #expect(part.contains("RRULE:FREQ=WEEKLY;UNTIL=20991230T180000Z"), partText)
        let moved = try #require(Fixture.overrides(out.newPart).first)
        #expect(moved.contains("RECURRENCE-ID:20990603T180000Z"), "the changed occurrence no longer names one of the new part's occurrences")
        #expect(moved.contains("DTSTART:20990603T190000Z"), "the changed occurrence's own time is the user's and stays")
        // The capped series was not moved.
        let capped = Fixture.master(out.cappedSeries)
        #expect(capped.contains("DTSTART:20990506T170000Z") && capped.contains("EXDATE:20990513T170000Z")
                && capped.contains("RDATE:20990515T170000Z"), Comment(rawValue: capped.joined(separator: "\n")))
        #expect(Fixture.overrides(out.cappedSeries).first?.contains("RECURRENCE-ID:20990513T170000Z") == true)
    }

    @Test("a changed occurrence and an added date exactly at the split go to the new part only")
    func splitPointGoesToTheNewPart() throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-1", "DTSTART:20990506T170000Z", "DTEND:20990506T174500Z",
            "RRULE:FREQ=WEEKLY", "RDATE:20990520T170000Z", "SUMMARY:Sync", "END:VEVENT",
            "BEGIN:VEVENT", "UID:series-1", "RECURRENCE-ID:20990520T170000Z", "DTSTART:20990520T180000Z",
            "DTEND:20990520T184500Z", "SUMMARY:Changed at the split", "END:VEVENT",
        ])
        let out = try Fixture.split(ics, patch: Fixture.patch(summary: "Sync"))
        let capped = Fixture.master(out.cappedSeries)
        #expect(!capped.contains { $0.hasPrefix("RDATE") }, Comment(rawValue: capped.joined(separator: "\n")))
        #expect(Fixture.overrides(out.cappedSeries).isEmpty, "the capped series kept the occurrence at the split")
        let part = Fixture.master(out.newPart)
        #expect(part.contains("RDATE:20990520T170000Z"), Comment(rawValue: part.joined(separator: "\n")))
        let overrides = Fixture.overrides(out.newPart)
        #expect(overrides.count == 1, "the occurrence at the split was lost or doubled: \(overrides.count)")
        guard overrides.count == 1 else { return }
        #expect(overrides[0].contains("SUMMARY:Changed at the split") && overrides[0].contains("RECURRENCE-ID:20990520T170000Z"))
    }

    @Test("a split that changes only the repeat rule asks every attendee but the organizer again")
    func ruleOnlyChangeAsksAgain() throws {
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=DAILY"]
        let part = Fixture.master(try Fixture.split(Fixture.richSeries, patch: patch).newPart)
        #expect(part.contains("RRULE:FREQ=DAILY"), Comment(rawValue: part.joined(separator: "\n")))
        #expect(Fixture.attendee(part, "olivia@example.com") == "ATTENDEE;CN=Olivia;PARTSTAT=ACCEPTED;ROLE=CHAIR:mailto:olivia@example.com")
        for address in ["alice@example.com", "bob@example.com"] {
            let line = try #require(Fixture.attendee(part, address))
            #expect(line.contains("PARTSTAT=NEEDS-ACTION") && line.contains("RSVP=TRUE"), Comment(rawValue: line))
        }
    }

    @Test("the new part carries the rule the split gives it, which ends where the series did")
    func newPartTakesTheGivenRule() throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-1", "DTSTART:20990506T170000Z", "DTEND:20990506T174500Z",
            "RRULE:FREQ=WEEKLY;COUNT=10;BYDAY=WE", "SUMMARY:Sync", "END:VEVENT",
        ])
        let out = try Fixture.split(ics, patch: Fixture.patch(summary: "Sync"), newRRule: "RRULE:FREQ=WEEKLY;COUNT=8;BYDAY=WE")
        let part = Fixture.master(out.newPart)
        #expect(part.filter { $0.hasPrefix("RRULE") } == ["RRULE:FREQ=WEEKLY;COUNT=8;BYDAY=WE"], Comment(rawValue: part.joined(separator: "\n")))
        #expect(Fixture.master(out.cappedSeries).contains("RRULE:FREQ=WEEKLY;UNTIL=20990520T165959Z"))
    }

    @Test("a series measured by DURATION only splits with its length")
    func durationOnlySeriesSplits() throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-1", "DTSTART:20990506T170000Z", "DURATION:PT1H",
            "RRULE:FREQ=WEEKLY", "SUMMARY:Standup", "END:VEVENT",
        ])
        let part = Fixture.master(try Fixture.split(ics, patch: GCalEventInput()).newPart)
        #expect(part.contains("DTSTART:20990520T170000Z") && part.contains("DURATION:PT1H"), Comment(rawValue: part.joined(separator: "\n")))
        #expect(part.contains("SUMMARY:Standup"))
    }

    @Test("a series that can't be read is refused as unsupported before anything is written")
    func unreadableSeriesIsRefused() {
        let noLength = Fixture.series(["BEGIN:VEVENT", "UID:series-1", "DTSTART:20990506T170000Z", "RRULE:FREQ=WEEKLY", "END:VEVENT"])
        let unknownZone = Fixture.series([
            "BEGIN:VEVENT", "UID:series-1", "DTSTART;TZID=Not/AZone:20990506T170000",
            "DTEND;TZID=Not/AZone:20990506T174500", "RRULE:FREQ=WEEKLY", "END:VEVENT",
        ])
        for ics in [noLength, unknownZone] {
            #expect {
                _ = try Fixture.split(ics, patch: GCalEventInput())
            } throws: { error in
                if case CalendarProviderError.notSupported = error { return true }
                return false
            }
        }
    }
}

// MARK: - Edit of the whole series

@Suite("CalDAV edit of a whole series keeps attendees and alarms")
struct CalDAVWholeSeriesEditTests {

    @Test("an attendee change keeps every staying attendee's role and answer")
    func attendeeChangeKeepsOthers() throws {
        var patch = GCalEventInput()
        patch.attendees = [("olivia@example.com", "Olivia"), ("alice@example.com", "Doe, Alice"), ("carol@example.com", "Carol")]
        let out = try CalDAVProvider.mergePatchIntoICS(Fixture.richSeries, patch: patch)
        let block = Fixture.master(out)
        #expect(Fixture.attendee(block, "olivia@example.com") == "ATTENDEE;CN=Olivia;PARTSTAT=ACCEPTED;ROLE=CHAIR:mailto:olivia@example.com")
        #expect(Fixture.attendee(block, "alice@example.com") == "ATTENDEE;CN=\"Doe, Alice\";ROLE=OPT-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:alice@example.com")
        #expect(Fixture.attendee(block, "bob@example.com") == nil, "a removed attendee stayed")
        #expect(Fixture.attendee(block, "carol@example.com") == "ATTENDEE;CN=\"Carol\";ROLE=REQ-PARTICIPANT:mailto:carol@example.com")
        let alarm = block.firstIndex(of: "BEGIN:VALARM") ?? block.endIndex
        #expect(block[..<alarm].filter { $0.hasPrefix("ATTENDEE") }.count == 3, "an attendee was written after the alarm")
    }

    @Test("adding the first attendee writes it among the event's properties, not the alarm's")
    func firstAttendeeGoesBeforeTheAlarm() throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-1", "DTSTART:20990506T170000Z", "DTEND:20990506T174500Z", "SUMMARY:Sync",
            "BEGIN:VALARM", "ACTION:EMAIL", "SUMMARY:Reminder", "DESCRIPTION:Soon", "TRIGGER:-PT15M",
            "ATTENDEE:mailto:olivia@example.com", "END:VALARM", "END:VEVENT",
        ])
        var patch = GCalEventInput()
        patch.attendees = [("carol@example.com", nil)]
        let block = Fixture.master(try CalDAVProvider.mergePatchIntoICS(ics, patch: patch))
        let alarm = block.firstIndex(of: "BEGIN:VALARM") ?? block.endIndex
        #expect(block[..<alarm].contains { $0.hasSuffix("mailto:carol@example.com") }, Comment(rawValue: block.joined(separator: "\n")))
        #expect(block[alarm...].contains("ATTENDEE:mailto:olivia@example.com"), "the alarm's recipient was removed")
    }

    @Test("an edit of the title and notes leaves an alarm's own title and text alone")
    func alarmTextUntouched() throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-1", "DTSTART:20990506T170000Z", "DTEND:20990506T174500Z",
            "BEGIN:VALARM", "ACTION:EMAIL", "SUMMARY:Reminder", "DESCRIPTION:Soon", "TRIGGER:-PT15M",
            "ATTENDEE:mailto:olivia@example.com", "END:VALARM", "END:VEVENT",
        ])
        var patch = GCalEventInput()
        patch.summary = "Sync"
        patch.description = "Agenda"
        let block = Fixture.master(try CalDAVProvider.mergePatchIntoICS(ics, patch: patch))
        let alarm = block.firstIndex(of: "BEGIN:VALARM") ?? block.endIndex
        #expect(block[..<alarm].contains("SUMMARY:Sync") && block[..<alarm].contains("DESCRIPTION:Agenda"), Comment(rawValue: block.joined(separator: "\n")))
        #expect(block[alarm...].contains("SUMMARY:Reminder") && block[alarm...].contains("DESCRIPTION:Soon"))
    }

    @Test("a repeating alarm's interval is not the event's length")
    func alarmDurationIsNotTheLength() throws {
        let ics = Fixture.series([
            "BEGIN:VEVENT", "UID:series-1", "DTSTART:20990506T170000Z", "DURATION:PT1H", "RRULE:FREQ=WEEKLY",
            "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "REPEAT:2", "DURATION:PT5M", "END:VALARM",
            "END:VEVENT",
        ])
        #expect(try CalDAVProvider.extractMasterDuration(from: ics) == 3600)
    }
}
