/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The split's carry rule (`SplitCarry`), provider-neutral: when a "this and following" split
/// carries the occurrences after it and when it resets them, where it splits, and what each carried
/// occurrence keeps of its own.
@Suite("SplitCarry: what a split carries, and where it splits")
struct SplitCarryTests {
    /// `days` from today at `time` UTC, as an RFC 3339 instant.
    private static func at(_ days: Int, _ time: String = "09:00:00") -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let today = calendar.startOfDay(for: Date())
        let day = calendar.date(byAdding: .day, value: days, to: today) ?? today
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: day))T\(time)Z"
    }

    private static func event(_ fields: [String: Any]) throws -> GCalEvent {
        try JSONDecoder().decode(GCalEvent.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private static func time(_ text: String) -> [String: Any] { ["dateTime": text, "timeZone": "UTC"] }

    private static var series: [String: Any] { [
        "id": "s", "summary": "Standup", "location": "Room 1",
        "start": time(at(0)), "end": time(at(0, "09:30:00")),
    ] }

    /// An occurrence of the series at day `place`, starting at `start` and ending at `end`.
    private static func occurrence(place: Int, start: String, end: String, extra: [String: Any] = [:]) throws -> GCalEvent {
        var fields: [String: Any] = [
            "id": "s_\(place)", "summary": "Standup", "location": "Room 1", "recurringEventId": "s",
            "originalStartTime": time(at(place)), "start": time(start), "end": time(end),
        ]
        fields.merge(extra) { $1 }
        return try event(fields)
    }

    // MARK: mode

    @Test("an edit that leaves the start at the place and the rule as it is carries")
    func renameCarries() throws {
        var edit = GCalEventInput()
        edit.summary = "Renamed"
        let place = GCalDateTime(dateTime: Self.at(7), date: nil, timeZone: "UTC")
        #expect(SplitCarry.mode(edit: edit, place: place, storedRules: ["RRULE:FREQ=WEEKLY"], seriesZone: .gmt) == .carry)
        edit.startDateTime = Self.at(7)
        #expect(SplitCarry.mode(edit: edit, place: place, storedRules: ["RRULE:FREQ=WEEKLY"], seriesZone: .gmt) == .carry)
    }

    @Test("a start elsewhere than the place, or another rule, resets")
    func startOrRuleChangeResets() throws {
        let place = GCalDateTime(dateTime: Self.at(7), date: nil, timeZone: "UTC")
        var moved = GCalEventInput()
        moved.startDateTime = Self.at(7, "10:00:00")
        #expect(SplitCarry.mode(edit: moved, place: place, storedRules: ["RRULE:FREQ=WEEKLY"], seriesZone: .gmt) == .reset)
        var rule = GCalEventInput()
        rule.recurrence = ["RRULE:FREQ=DAILY"]
        #expect(SplitCarry.mode(edit: rule, place: place, storedRules: ["RRULE:FREQ=WEEKLY"], seriesZone: .gmt) == .reset)
        var same = GCalEventInput()
        same.recurrence = ["RRULE:FREQ=WEEKLY"]
        #expect(SplitCarry.mode(edit: same, place: place, storedRules: ["RRULE:FREQ=WEEKLY"], seriesZone: .gmt) == .carry)
    }

    @Test("the same instant in another time zone resets, as Google's own split does; the same zone by another name carries")
    func zoneOnlyChangeResets() throws {
        let place = GCalDateTime(dateTime: Self.at(7), date: nil, timeZone: "UTC")
        var other = GCalEventInput()
        other.startDateTime = Self.at(7)
        other.startTimeZone = "Atlantic/Reykjavik"
        #expect(SplitCarry.mode(edit: other, place: place, storedRules: [], seriesZone: .gmt) == .reset)
        var same = other
        same.startTimeZone = "Pacific Standard Time"
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(SplitCarry.mode(edit: same, place: place, storedRules: [], seriesZone: pacific) == .carry)
    }

    // MARK: place

    @Test("a moved occurrence is split at its place; an unmoved one at its recurrence id")
    func placeOfMovedOccurrence() throws {
        let moved = try Self.occurrence(place: 7, start: Self.at(9), end: Self.at(9, "09:30:00"))
        let naive = SplitCarry.placeNaive(of: moved, recurrenceId: String(Self.at(9).dropLast()), zone: .gmt)
        #expect(naive == String(Self.at(7).dropLast()))
        let plain = try Self.occurrence(place: 7, start: Self.at(7), end: Self.at(7, "09:30:00"))
        #expect(SplitCarry.placeNaive(of: plain, recurrenceId: "given", zone: .gmt) == "given")
    }

    @Test("an end given alone at a moved occurrence keeps its length from where it is now")
    func endOnlyAtMovedOccurrence() throws {
        let moved = try Self.occurrence(place: 7, start: Self.at(9), end: Self.at(9, "09:30:00"))
        var edit = GCalEventInput()
        edit.endDateTime = Self.at(9, "10:00:00")
        let written = try #require(SplitCarry.partEdit(edit, named: moved))
        #expect(written.endDateTime.flatMap(Date.fromISO8601) == Date.fromISO8601(Self.at(7, "10:00:00")))
    }

    // MARK: plan

    @Test("a deleted occurrence stays deleted; EVERY changed one is carried, whatever makes it one")
    func planCarriesEveryChangedOccurrence() throws {
        let series = try Self.event(Self.series)
        let renamedAndRoom = try Self.occurrence(place: 14, start: Self.at(14), end: Self.at(14, "09:30:00"),
                                                 extra: ["summary": "Own", "location": "Room 2"])
        // Only a guest's answer of its own: still carried (C1).
        let answered = try Self.occurrence(place: 21, start: Self.at(21), end: Self.at(21, "09:30:00"),
                                           extra: ["attendees": [["email": "guest@example.com", "responseStatus": "declined"]]])
        let deletedPlace = GCalDateTime(dateTime: Self.at(28), date: nil, timeZone: "UTC")
        let plan = try #require(SplitCarry.plan(
            exceptions: [.changed(renamedAndRoom), .changed(answered), .deleted(place: deletedPlace)],
            series: series, newPart: series, fields: [.summary]))
        #expect(plan.deleted.count == 1 && plan.deleted.first?.dateTime == Self.at(28))
        #expect(plan.changed.count == 2 && plan.changed.allSatisfy { $0.start == nil }, "changed: \(plan.changed.map(\.place))")
    }

    @Test("Google: a deleted place is excluded in the series' own form: a date, a TZID wall clock, or UTC")
    func excludedDateLineForms() throws {
        let allDay = try Self.event(["id": "s", "start": ["date": "2099-03-02"], "end": ["date": "2099-03-03"]])
        #expect(GoogleCalendarProvider.excludedDateLine(GCalDateTime(dateTime: nil, date: "2099-03-09", timeZone: nil), master: allDay)
                == "EXDATE;VALUE=DATE:20990309")
        let zoned = try Self.event(["id": "s", "start": ["dateTime": "2099-03-02T09:00:00-08:00", "timeZone": "America/Los_Angeles"],
                                    "end": ["dateTime": "2099-03-02T09:30:00-08:00", "timeZone": "America/Los_Angeles"]])
        let place = GCalDateTime(dateTime: "2099-01-12T17:00:00Z", date: nil, timeZone: nil)
        #expect(GoogleCalendarProvider.excludedDateLine(place, master: zoned) == "EXDATE;TZID=America/Los_Angeles:20990112T090000")
        let utcOnly = try Self.event(["id": "s", "start": ["dateTime": "2099-03-02T17:00:00Z"], "end": ["dateTime": "2099-03-02T17:30:00Z"]])
        #expect(GoogleCalendarProvider.excludedDateLine(place, master: utcOnly) == "EXDATE:20990112T170000Z")
    }

    // MARK: CalDAV carry onto the new part's overrides

    private static let calDAVSeries = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//EN
    BEGIN:VEVENT
    UID:carry-1
    DTSTAMP:20990101T000000Z
    DTSTART:20990105T090000Z
    DTEND:20990105T093000Z
    SUMMARY:Standup
    RRULE:FREQ=WEEKLY
    END:VEVENT
    BEGIN:VEVENT
    UID:carry-1
    RECURRENCE-ID:20990119T090000Z
    DTSTAMP:20990101T000000Z
    DTSTART:20990120T110000Z
    DTEND:20990120T113000Z
    SUMMARY:Own title
    LOCATION:Room 9
    END:VEVENT
    END:VCALENDAR
    """.replacingOccurrences(of: "\n", with: "\r\n")

    private static func calDAVSplit(_ patch: GCalEventInput) throws -> [String] {
        let ics = calDAVSeries
        let slot = try #require(try CalDAVProvider.recurrenceIdInMasterFrame(
            "2099-01-12T09:00:00", declaredZone: .gmt, kind: CalDAVProvider.masterDTStartKind(from: ics),
            zones: CalendarTimeZoneContext(calendarText: ics)))
        let resources = try CalDAVProvider.seriesSplitResources(
            storedICS: ics, slotNaiveISO: slot, cappedRRule: "RRULE:FREQ=WEEKLY;UNTIL=20990112T085959Z",
            newRRule: "RRULE:FREQ=WEEKLY", newUid: "carry-2", patch: patch, now: Date())
        #expect(resources.mode == .carry)
        return resources.newPart.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
    }

    /// The lines of the new part's override (the one with a RECURRENCE-ID).
    private static func overrideLines(_ lines: [String]) -> [String] {
        guard let at = lines.firstIndex(where: { $0.hasPrefix("RECURRENCE-ID") }),
              let begin = lines[..<at].lastIndex(of: "BEGIN:VEVENT") else { return [] }
        let end = lines[at...].firstIndex(of: "END:VEVENT") ?? lines.endIndex
        return Array(lines[begin..<end])
    }

    @Test("CalDAV: a rename overwrites a carried override's own title and keeps its own room")
    func calDAVCarryOverwritesSetField() throws {
        var patch = GCalEventInput()
        patch.summary = "Renamed"
        let override = Self.overrideLines(try Self.calDAVSplit(patch))
        #expect(override.contains("SUMMARY:Renamed") && override.contains("LOCATION:Room 9"), "override: \(override)")
    }

    @Test("CalDAV: an end given alone gives a carried moved override its own start plus the new length")
    func calDAVCarryEndOnly() throws {
        var patch = GCalEventInput()
        patch.endDateTime = "2099-01-12T10:00:00Z"
        patch.endTimeZone = "UTC"
        let override = Self.overrideLines(try Self.calDAVSplit(patch))
        #expect(override.contains("DTSTART:20990120T110000Z") && override.contains("DTEND:20990120T120000Z"), "override: \(override)")
    }

    @Test("a moved occurrence keeps its times; with an end set, its own start plus the new part's length")
    func planMovedTimes() throws {
        let series = try Self.event(Self.series)
        let moved = try Self.occurrence(place: 14, start: Self.at(15), end: Self.at(15, "09:30:00"))
        let kept = try #require(SplitCarry.plan(exceptions: [.changed(moved)], series: series, newPart: series, fields: [.summary]))
        #expect(kept.changed.first?.start?.dateTime == Self.at(15) && kept.changed.first?.end?.dateTime == Self.at(15, "09:30:00"))
        var longer = Self.series
        longer["end"] = Self.time(Self.at(0, "10:00:00"))
        let ended = try #require(SplitCarry.plan(exceptions: [.changed(moved)], series: series,
                                                 newPart: try Self.event(longer), fields: [.end]))
        let end = ended.changed.first?.end?.dateTime.flatMap(Date.fromISO8601)
        #expect(end == Date.fromISO8601(Self.at(15, "10:00:00")), "end: \(ended.changed.first?.end?.dateTime ?? "none")")
    }

    @Test("a place is in the tail at or after the split")
    func tail() {
        let split = GCalDateTime(dateTime: Self.at(7), date: nil, timeZone: "UTC")
        #expect(SplitCarry.isInTail(GCalDateTime(dateTime: Self.at(7), date: nil, timeZone: "UTC"), split: split) == true)
        #expect(SplitCarry.isInTail(GCalDateTime(dateTime: Self.at(6), date: nil, timeZone: "UTC"), split: split) == false)
    }
}
