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

    // MARK: cut (calendar order, owner rule 2026-11-12)

    /// A weekly series from today at 09:00 UTC, with `rule`'s end.
    private static func weekly(_ end: String = "") throws -> GCalEvent {
        var series = Self.series
        series["recurrence"] = ["RRULE:FREQ=WEEKLY" + end]
        return try Self.event(series)
    }

    private static func instant(_ text: String) -> GCalDateTime { GCalDateTime(dateTime: text, date: nil, timeZone: "UTC") }

    @Test("an unmoved occurrence is cut at its place, addressed by its recurrence id")
    func cutOfUnmovedOccurrence() throws {
        let plain = try Self.occurrence(place: 7, start: Self.at(7), end: Self.at(7, "09:30:00"))
        let cut = try #require(SplitCarry.cut(named: plain, series: try Self.weekly()))
        #expect(cut == .at(Self.instant(Self.at(7))))
        guard case .at(let at) = cut else { return }
        #expect(SplitCarry.splitAt(at, named: plain, recurrenceId: "given", zone: .gmt) == "given")
    }

    @Test("an occurrence moved later is cut at the first place after where it is now, not its own place")
    func cutOfOccurrenceMovedLater() throws {
        let moved = try Self.occurrence(place: 7, start: Self.at(9), end: Self.at(9, "09:30:00"))
        let cut = try #require(SplitCarry.cut(named: moved, series: try Self.weekly()))
        #expect(cut == .at(Self.instant(Self.at(14))))
        guard case .at(let at) = cut else { return }
        #expect(SplitCarry.splitAt(at, named: moved, recurrenceId: "ignored", zone: .gmt) == String(Self.at(14).dropLast()))
    }

    @Test("an occurrence moved earlier is cut at the first place after where it is now, before its own place")
    func cutOfOccurrenceMovedEarlier() throws {
        let moved = try Self.occurrence(place: 14, start: Self.at(5), end: Self.at(5, "09:30:00"))
        #expect(SplitCarry.cut(named: moved, series: try Self.weekly()) == .at(Self.instant(Self.at(7))))
    }

    @Test("(a) a place at exactly the moved start counts as after it: the cut is that place")
    func cutAtTie() throws {
        let moved = try Self.occurrence(place: 7, start: Self.at(14), end: Self.at(14, "09:30:00"))
        #expect(SplitCarry.cut(named: moved, series: try Self.weekly()) == .at(Self.instant(Self.at(14))))
        // Later on the same day as a place is after it.
        let later = try Self.occurrence(place: 7, start: Self.at(14, "10:00:00"), end: Self.at(14, "10:30:00"))
        #expect(SplitCarry.cut(named: later, series: try Self.weekly()) == .at(Self.instant(Self.at(21))))
    }

    @Test("(e) an occurrence moved past the series' last place has no cut")
    func cutPastEnd() throws {
        let moved = try Self.occurrence(place: 7, start: Self.at(9), end: Self.at(9, "09:30:00"))
        #expect(SplitCarry.cut(named: moved, series: try Self.weekly(";COUNT=2")) == .pastEnd)
        #expect(SplitCarry.cut(named: moved, series: try Self.weekly(";COUNT=3")) == .at(Self.instant(Self.at(14))))
    }

    @Test("(f) all-day: a place on the same date as the moved occurrence counts as after it")
    func cutAllDaySameDate() throws {
        func day(_ n: Int) -> String { String(Self.at(n).prefix(10)) }
        let series = try Self.event([
            "id": "s", "start": ["date": day(0)], "end": ["date": day(1)], "recurrence": ["RRULE:FREQ=WEEKLY"],
        ])
        let moved = try Self.event([
            "id": "s_7", "recurringEventId": "s", "originalStartTime": ["date": day(7)],
            "start": ["date": day(14)], "end": ["date": day(15)],
        ])
        #expect(SplitCarry.cut(named: moved, series: series) == .at(GCalDateTime(dateTime: nil, date: day(14), timeZone: nil)))
    }

    /// `at(days, time)` as an iCalendar UTC value (`20990101T090000Z`).
    private static func ical(_ days: Int, _ time: String = "09:00:00") -> String {
        at(days, time).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
    }

    @Test("an added date (RDATE) before the rule's next place is the cut")
    func cutAtAddedDate() throws {
        let moved = try Self.occurrence(place: 7, start: Self.at(9), end: Self.at(9, "09:30:00"))
        let cut = SplitCarry.cut(named: moved, series: try Self.weekly(), rdates: ["RDATE:\(Self.ical(10))"])
        #expect(cut == .at(Self.instant(Self.at(10))))
        // One after the rule's next place leaves the cut there.
        let later = SplitCarry.cut(named: moved, series: try Self.weekly(), rdates: ["RDATE:\(Self.ical(16))"])
        #expect(later == .at(Self.instant(Self.at(14))))
    }

    @Test("a UTC UNTIL before the next place leaves no cut; one at it keeps the place")
    func cutPastUTCUntil() throws {
        let moved = try Self.occurrence(place: 7, start: Self.at(9), end: Self.at(9, "09:30:00"))
        #expect(SplitCarry.cut(named: moved, series: try Self.weekly(";UNTIL=\(Self.ical(13))")) == .pastEnd)
        #expect(SplitCarry.cut(named: moved, series: try Self.weekly(";UNTIL=\(Self.ical(14))")) == .at(Self.instant(Self.at(14))))
    }

    @Test("a date UNTIL is the series' own date: an evening place in a zone behind UTC on that date is kept")
    func cutDateUntilInSeriesZone() throws {
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        // 23:00 UTC is the afternoon of the same date in Pacific time, and 02:00 UTC is the evening before.
        let series = try Self.event([
            "id": "s", "start": Self.time(Self.at(0, "02:00:00")), "end": Self.time(Self.at(0, "03:00:00")),
            "recurrence": ["RRULE:FREQ=WEEKLY;UNTIL=\(String(Self.ical(13).prefix(8)))"],
        ])
        let moved = try Self.occurrence(place: 7, start: Self.at(9), end: Self.at(9, "10:00:00"))
        // The place on day 14 at 02:00 UTC is day 13 in Pacific time, on the UNTIL date.
        #expect(SplitCarry.cut(named: moved, series: series, zone: pacific) == .at(Self.instant(Self.at(14, "02:00:00"))))
        // Read in UTC it is day 14, after the UNTIL date.
        #expect(SplitCarry.cut(named: moved, series: series, zone: .gmt) == .pastEnd)
    }

    @Test("a local date-time UNTIL compares by wall clock in the series' zone")
    func cutLocalUntilInSeriesZone() throws {
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let moved = try Self.occurrence(place: 7, start: Self.at(9), end: Self.at(9, "10:00:00"))
        func series(_ until: String) throws -> GCalEvent {
            try Self.event([
                "id": "s", "start": Self.time(Self.at(0, "02:00:00")), "end": Self.time(Self.at(0, "03:00:00")),
                "recurrence": ["RRULE:FREQ=WEEKLY;UNTIL=\(until)"],
            ])
        }
        let day13 = String(Self.ical(13).prefix(8))
        // The day-14 place is 18:00 or 19:00 Pacific on day 13 (with or without daylight time).
        #expect(SplitCarry.cut(named: moved, series: try series("\(day13)T230000"), zone: pacific) == .at(Self.instant(Self.at(14, "02:00:00"))))
        #expect(SplitCarry.cut(named: moved, series: try series("\(day13)T170000"), zone: pacific) == .pastEnd)
    }

    // MARK: CalDAV's split point

    /// A weekly CalDAV series from today at 09:00 with `start` (`DTSTART` params and value
    /// suffix), its day-7 occurrence moved to day 9, and `extra` top-level lines.
    private static func caldavSeries(floating: Bool, extra: [String] = []) -> String {
        let z = floating ? "" : "Z"
        func v(_ days: Int, _ time: String = "09:00:00") -> String { String(ical(days, time).dropLast()) + z }
        return ([
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN",
            "BEGIN:VEVENT", "UID:split-point@example.com", "DTSTAMP:\(ical(0))",
            "DTSTART:\(v(0))", "DTEND:\(v(0, "09:30:00"))", "RRULE:FREQ=WEEKLY", "SUMMARY:Standup",
        ] + extra + [
            "END:VEVENT",
            "BEGIN:VEVENT", "UID:split-point@example.com", "DTSTAMP:\(ical(0))", "RECURRENCE-ID:\(v(7))",
            "DTSTART:\(v(9))", "DTEND:\(v(9, "09:30:00"))", "SUMMARY:Standup",
            "END:VEVENT", "END:VCALENDAR",
        ]).joined(separator: "\r\n")
    }

    @Test("CalDAV cuts at an added date (RDATE) the series holds, as the card shows it")
    func caldavSplitPointAtAddedDate() throws {
        let ics = Self.caldavSeries(floating: false, extra: ["RDATE:\(Self.ical(10))"])
        let point = try CalDAVProvider.splitPoint(
            masterICS: ics, href: "/cal/split-point.ics", key: nil, recurrenceId: String(Self.at(9).dropLast()), zone: .gmt)
        #expect(point.cut == .at(Self.instant(Self.at(10))))
        #expect(point.slot == String(Self.at(10).dropLast()))
    }

    @Test("CalDAV reads a floating series in the operation's zone, not the device's")
    func caldavSplitPointFloatingInOperationZone() throws {
        let candidates = ["Pacific/Kiritimati", "Pacific/Pago_Pago"].compactMap(TimeZone.init(identifier:))
        let zone = try #require(candidates.first { $0.secondsFromGMT() != TimeZone.current.secondsFromGMT() })
        let ics = Self.caldavSeries(floating: true)
        let point = try CalDAVProvider.splitPoint(
            masterICS: ics, href: "/cal/split-point.ics", key: nil, recurrenceId: String(Self.at(9).dropLast()), zone: zone)
        #expect(point.slot == String(Self.at(14).dropLast()))
        // The occurrence named starts at its wall clock in that zone.
        #expect(point.namedInstants.start == GoogleCalendarProvider.naiveInstant(String(Self.at(9).dropLast()), zone: zone))
    }

    // MARK: an edit past the series' end

    @Test("an edit past the end keeps absolute targets: a retry after a partial write never moves an occurrence twice")
    func shownEditsRetryMovesOnce() throws {
        // Named: placed day 7, now day 30; another shown after it at day 31. The edit moves it an hour later.
        let named = try Self.occurrence(place: 7, start: Self.at(30), end: Self.at(30, "09:30:00"))
        let other = try Self.occurrence(place: 0, start: Self.at(31), end: Self.at(31, "09:30:00"))
        var edit = GCalEventInput()
        edit.startDateTime = Self.at(30, "10:00:00")
        edit.endDateTime = Self.at(30, "10:30:00")
        let first = try #require(SplitCarry.shownEdits(exceptions: [.changed(named), .changed(other)], named: named, seriesId: "s", patch: edit))
        #expect(first.record.isPastEnd && first.record.newPartId == "s_7")
        #expect(first.edits.map(\.exception.id) == ["s_0", "s_7"])
        // The first write landed, the named one's did not. The record survives the queue's round trip.
        let kept = try #require(SplitRecord([SplitRecord.argumentKey: first.record.argument]))
        #expect(kept == first.record)
        let written = try Self.occurrence(place: 0, start: Self.at(31, "10:00:00"), end: Self.at(31, "10:30:00"))
        let retry = try #require(SplitCarry.shownEdits(exceptions: [.changed(named), .changed(written)], record: kept))
        #expect(retry.map(\.exception.id) == ["s_0", "s_7"])
        func start(_ edit: SplitCarry.Edit?) -> Date? { edit?.start?.dateTime.flatMap(Date.fromISO8601) }
        // The one written stays where the first attempt put it; the named one goes where it was to.
        #expect(start(retry.first) == Date.fromISO8601(Self.at(31, "10:00:00")), "moved twice: \(String(describing: retry.first?.start))")
        #expect(start(retry.last) == Date.fromISO8601(Self.at(30, "10:00:00")))
        // Both landed: nothing moves again, and the named one is still found by its place.
        let namedWritten = try Self.occurrence(place: 7, start: Self.at(30, "10:00:00"), end: Self.at(30, "10:30:00"))
        let done = try #require(SplitCarry.shownEdits(exceptions: [.changed(namedWritten), .changed(written)], record: kept))
        #expect(done.count == 2)
        #expect(start(done.first) == Date.fromISO8601(Self.at(31, "10:00:00")) && start(done.last) == Date.fromISO8601(Self.at(30, "10:00:00")))
    }

    @Test("an edit past the end that sets the end keeps its length on the record")
    func shownEditsKeepLength() throws {
        let named = try Self.occurrence(place: 7, start: Self.at(30), end: Self.at(30, "09:30:00"))
        var edit = GCalEventInput()
        edit.endDateTime = Self.at(30, "10:00:00")
        let first = try #require(SplitCarry.shownEdits(exceptions: [.changed(named)], named: named, seriesId: "s", patch: edit))
        #expect(first.record.editLength == 3600)
        let kept = try #require(SplitRecord([SplitRecord.argumentKey: first.record.argument]))
        #expect(kept.editLength == 3600)
        let retry = try #require(SplitCarry.shownEdits(exceptions: [.changed(named)], record: kept))
        #expect(retry.first?.end?.dateTime.flatMap(Date.fromISO8601) == Date.fromISO8601(Self.at(30, "10:00:00")))
    }

    @Test("a record whose kept length is not a number is not read, so a retry never ends an occurrence at a guessed length")
    func malformedEditLengthIsNotRead() throws {
        let named = try Self.occurrence(place: 7, start: Self.at(30), end: Self.at(30, "09:30:00"))
        var edit = GCalEventInput()
        edit.endDateTime = Self.at(30, "10:00:00")
        let first = try #require(SplitCarry.shownEdits(exceptions: [.changed(named)], named: named, seriesId: "s", patch: edit))
        guard case .dictionary(var stored) = first.record.argument else { Issue.record("the record is not a dictionary"); return }
        stored["edit_length"] = .string("an hour")
        #expect(SplitRecord([SplitRecord.argumentKey: .dictionary(stored)]) == nil)
    }

    @Test("Outlook orders moves without dating an occurrence that does not move, so a series with no readable zone still writes it")
    func moveOrderNeedsNoZoneForStays() throws {
        let time = GCalDateTime(dateTime: Self.at(30), date: nil, timeZone: nil)
        let later = GCalDateTime(dateTime: Self.at(31), date: nil, timeZone: nil)
        // No target, and a target at the instant it is at: neither moves.
        let stays: [(at: GCalDateTime, to: GCalDateTime?)] = [(time, nil), (time, time)]
        let ordered = try ExchangeCalendarProvider.moveOrder(stays, at: \.at, to: \.to, zone: nil)
        #expect(ordered.count == 2)
        // A move is dated: with no zone to date it in, it is refused before anything is written.
        #expect(throws: CalendarProviderError.self) {
            try ExchangeCalendarProvider.moveOrder([(at: time, to: Optional(later))], at: \.at, to: \.to, zone: nil)
        }
    }

    // MARK: partition

    @Test("exceptions sort into four groups by place against the cut and start against the named one; a deleted one goes by its place")
    func partitionGroups() throws {
        // Named: placed day 7, moved to day 9; cut at day 14.
        let namedStart = Self.instant(Self.at(9))
        let cut = SplitCarry.Cut.at(Self.instant(Self.at(14)))
        let earlier = try Self.occurrence(place: 0, start: Self.at(1), end: Self.at(1, "09:30:00"))     // untouched
        let named = try Self.occurrence(place: 7, start: Self.at(9), end: Self.at(9, "09:30:00"))       // edited where it is
        let movedOut = try Self.occurrence(place: 0, start: Self.at(10), end: Self.at(10, "09:30:00"))  // edited where it is
        let later = try Self.occurrence(place: 21, start: Self.at(22), end: Self.at(22, "09:30:00"))    // tail
        let movedIn = try Self.occurrence(place: 28, start: Self.at(8), end: Self.at(8, "09:30:00"))    // kept whole
        let tie = try Self.occurrence(place: 35, start: Self.at(9), end: Self.at(9, "09:30:00"))        // (a): tail
        let parts = try #require(SplitCarry.partition([
            .changed(earlier), .changed(named), .changed(movedOut), .changed(later), .changed(movedIn), .changed(tie),
            .deleted(place: Self.instant(Self.at(7))), .deleted(place: Self.instant(Self.at(42))),
        ], cut: cut, namedStart: namedStart))
        #expect(parts.edited.map(\.id) == ["s_7", "s_0"])
        #expect(parts.kept.map(\.id) == ["s_28"])
        #expect(parts.tail.count == 3)
        #expect(parts.tail.compactMap { if case .changed(let e) = $0 { return e.id } else { return nil } } == ["s_21", "s_35"])
        #expect(parts.tail.contains { if case .deleted(let p) = $0 { return p.dateTime == Self.at(42) } else { return false } })
    }

    @Test("(e) with no cut, every occurrence shown from the named one on is edited where it is")
    func partitionPastEnd() throws {
        let named = try Self.occurrence(place: 7, start: Self.at(30), end: Self.at(30, "09:30:00"))
        let before = try Self.occurrence(place: 0, start: Self.at(2), end: Self.at(2, "09:30:00"))
        let parts = try #require(SplitCarry.partition([.changed(named), .changed(before)], cut: .pastEnd, namedStart: Self.instant(Self.at(30))))
        #expect(parts.edited.map(\.id) == ["s_7"] && parts.tail.isEmpty && parts.kept.isEmpty)
    }

    // MARK: the edit's times

    @Test("an end given alone at a moved occurrence keeps its length from where it is now")
    func endOnlyAtMovedOccurrence() throws {
        var edit = GCalEventInput()
        edit.endDateTime = Self.at(9, "10:00:00")
        let written = try #require(SplitCarry.partEdit(edit, namedStart: Self.instant(Self.at(9)), cut: Self.instant(Self.at(14))))
        #expect(written.endDateTime.flatMap(Date.fromISO8601) == Date.fromISO8601(Self.at(14, "10:00:00")))
    }

    @Test("(b) a start given moves the new part from the cut as far as it moves the named occurrence")
    func startGivenShiftsFromTheCut() throws {
        var edit = GCalEventInput()
        edit.startDateTime = Self.at(9, "11:00:00")
        edit.endDateTime = Self.at(9, "11:30:00")
        let written = try #require(SplitCarry.partEdit(edit, namedStart: Self.instant(Self.at(9)), cut: Self.instant(Self.at(14))))
        #expect(written.startDateTime.flatMap(Date.fromISO8601) == Date.fromISO8601(Self.at(14, "11:00:00")))
        #expect(written.endDateTime.flatMap(Date.fromISO8601) == Date.fromISO8601(Self.at(14, "11:30:00")))
        // At a cut that is the named start, the edit is written as given.
        let same = try #require(SplitCarry.partEdit(edit, namedStart: Self.instant(Self.at(9)), cut: Self.instant(Self.at(9))))
        #expect(same.startDateTime == edit.startDateTime)
    }

    @Test("(b) an edited occurrence moves by the shift; a retry moves it to the start kept, never twice")
    func editsMoveOnceAcrossARetry() throws {
        let movedOut = try Self.occurrence(place: 0, start: Self.at(10), end: Self.at(10, "09:45:00"))
        let first = try #require(SplitCarry.edits(of: [movedOut], shift: 7200, length: nil, fields: [.summary]))
        #expect(first.first?.start?.dateTime.flatMap(Date.fromISO8601) == Date.fromISO8601(Self.at(10, "11:00:00")))
        #expect(first.first?.end?.dateTime.flatMap(Date.fromISO8601) == Date.fromISO8601(Self.at(10, "11:45:00")))
        let targets = SplitCarry.targets(of: first)
        // The write landed: the occurrence now starts at 11:00. The retry leaves its time as it is.
        let written = try Self.occurrence(place: 0, start: Self.at(10, "11:00:00"), end: Self.at(10, "11:45:00"))
        let retry = try #require(SplitCarry.edits(of: [written], targets: targets, length: nil, fields: [.summary]))
        #expect(retry.count == 1 && retry.first?.start == nil)
        // It did not land: the retry moves it as the first attempt would have.
        let again = try #require(SplitCarry.edits(of: [movedOut], targets: targets, length: nil, fields: [.summary]))
        #expect(again.first?.start?.dateTime.flatMap(Date.fromISO8601) == Date.fromISO8601(Self.at(10, "11:00:00")))
        // An occurrence with no target kept is not edited.
        let other = try Self.occurrence(place: 21, start: Self.at(23), end: Self.at(23, "09:30:00"))
        #expect(SplitCarry.edits(of: [other], targets: targets, length: nil, fields: [.summary])?.isEmpty == true)
    }

    @Test("an occurrence placed after the cut but shown before the named one is planned whole; on a reset the named one is planned at its moved start")
    func planKeptWholeAndNamedOnReset() throws {
        let series = try Self.event(Self.series)
        let movedIn = try Self.occurrence(place: 28, start: Self.at(8), end: Self.at(8, "09:30:00"))
        let named = try Self.occurrence(place: 14, start: Self.at(12), end: Self.at(12, "09:30:00"))
        let plan = try #require(SplitCarry.plan(
            exceptions: [], kept: [movedIn], named: named, shift: 3600, series: series, newPart: series, fields: [.summary]))
        #expect(plan.changed.count == 2)
        guard plan.changed.count == 2 else { return }
        #expect(plan.changed[0].whole && plan.changed[0].start?.dateTime == Self.at(8))
        #expect(!plan.changed[1].whole)
        #expect(plan.changed[1].start?.dateTime.flatMap(Date.fromISO8601) == Date.fromISO8601(Self.at(12, "10:00:00")))
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

    /// A weekly series from Monday 2099-01-05 09:00 UTC, its occurrence placed on the 12th (the one
    /// named) moved to the 14th, so the cut is the 19th; the one placed on the 5th moved to the
    /// 15th (shown after the named one); the one placed on the 26th moved to the 13th (shown before
    /// it); and the one on February 2 changed in place.
    private static let calDAVMovedSeries = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//EN
    BEGIN:VEVENT
    UID:moved-1
    DTSTAMP:20990101T000000Z
    DTSTART:20990105T090000Z
    DTEND:20990105T093000Z
    SUMMARY:Standup
    RRULE:FREQ=WEEKLY
    END:VEVENT
    BEGIN:VEVENT
    UID:moved-1
    RECURRENCE-ID:20990112T090000Z
    DTSTAMP:20990101T000000Z
    DTSTART:20990114T090000Z
    DTEND:20990114T093000Z
    SUMMARY:Standup
    END:VEVENT
    BEGIN:VEVENT
    UID:moved-1
    RECURRENCE-ID:20990105T090000Z
    DTSTAMP:20990101T000000Z
    DTSTART:20990115T090000Z
    DTEND:20990115T093000Z
    SUMMARY:Standup
    END:VEVENT
    BEGIN:VEVENT
    UID:moved-1
    RECURRENCE-ID:20990126T090000Z
    DTSTAMP:20990101T000000Z
    DTSTART:20990113T090000Z
    DTEND:20990113T093000Z
    SUMMARY:Standup
    END:VEVENT
    BEGIN:VEVENT
    UID:moved-1
    RECURRENCE-ID:20990202T090000Z
    DTSTAMP:20990101T000000Z
    DTSTART:20990202T090000Z
    DTEND:20990202T093000Z
    SUMMARY:Standup
    LOCATION:Room 9
    END:VEVENT
    END:VCALENDAR
    """.replacingOccurrences(of: "\n", with: "\r\n")

    /// The lines of the override placed at `rid` (its RECURRENCE-ID value) in `ics`.
    private static func override(_ rid: String, in ics: String) -> [String] {
        let lines = ics.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
        guard let at = lines.firstIndex(of: "RECURRENCE-ID:\(rid)"),
              let begin = lines[..<at].lastIndex(of: "BEGIN:VEVENT") else { return [] }
        let end = lines[at...].firstIndex(of: "END:VEVENT") ?? lines.endIndex
        return Array(lines[begin..<end])
    }

    private static func calDAVMovedSplit(_ patch: GCalEventInput) throws -> CalDAVProvider.SeriesSplitResources {
        let named = (start: try #require(Date.fromISO8601("2099-01-14T09:00:00Z")), place: try #require(Date.fromISO8601("2099-01-12T09:00:00Z")))
        return try CalDAVProvider.seriesSplitResources(
            storedICS: calDAVMovedSeries, slotNaiveISO: "2099-01-19T09:00:00", cappedRRule: "RRULE:FREQ=WEEKLY;UNTIL=20990119T085959Z",
            newRRule: "RRULE:FREQ=WEEKLY", newUid: "moved-2", patch: patch, now: Date(),
            zones: CalendarTimeZoneContext(calendarText: calDAVMovedSeries), named: named)
    }

    @Test("CalDAV: a split named at a moved occurrence edits what is shown after it where it is, and keeps what is shown before it whole (owner rule)")
    func calDAVMovedSplitGroups() throws {
        var patch = GCalEventInput()
        patch.summary = "Renamed"
        let r = try Self.calDAVMovedSplit(patch)
        #expect(r.mode == .carry)
        // On the capped series: the named one and the one shown after it, edited where they are.
        #expect(Self.override("20990112T090000Z", in: r.cappedSeries).contains("SUMMARY:Renamed"), "\(r.cappedSeries)")
        #expect(Self.override("20990105T090000Z", in: r.cappedSeries).contains("SUMMARY:Renamed"), "\(r.cappedSeries)")
        // On the new part: the one shown before the named one, whole; the later one carried.
        let kept = Self.override("20990126T090000Z", in: r.newPart)
        #expect(kept.contains("SUMMARY:Standup") && kept.contains("DTSTART:20990113T090000Z"), "kept: \(kept)")
        let carried = Self.override("20990202T090000Z", in: r.newPart)
        #expect(carried.contains("SUMMARY:Renamed") && carried.contains("LOCATION:Room 9"), "carried: \(carried)")
        #expect(r.newPart.contains("DTSTART:20990119T090000Z"))
    }

    @Test("CalDAV: a new start at a moved occurrence moves it where it is by the same amount and still keeps what is shown before it (owner rule b, c)")
    func calDAVMovedSplitReset() throws {
        var patch = GCalEventInput()
        // The new part's start as the provider gives it (`partEdit`): the cut, an hour on.
        patch.startDateTime = "2099-01-19T10:00:00Z"
        patch.startTimeZone = "UTC"
        let r = try Self.calDAVMovedSplit(patch)
        #expect(r.mode == .reset)
        let named = Self.override("20990112T090000Z", in: r.cappedSeries)
        #expect(named.contains("DTSTART:20990114T100000Z") && named.contains("DTEND:20990114T103000Z"), "named: \(named)")
        // Kept at its own time, named by the new part's occurrence its place now is (an hour on).
        let kept = Self.override("20990126T100000Z", in: r.newPart)
        #expect(kept.contains("DTSTART:20990113T090000Z") && kept.contains("SUMMARY:Standup"), "kept: \(kept)")
        #expect(Self.override("20990202T090000Z", in: r.newPart).isEmpty && Self.override("20990202T100000Z", in: r.newPart).isEmpty,
                "the reset kept a later change")
    }

    @Test("CalDAV: (d) on a reset, an occurrence deleted between the named one's place and the cut stays deleted on the capped series")
    func calDAVResetKeepsDeletedBeforeTheCut() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Test//EN
        BEGIN:VEVENT
        UID:moved-1
        DTSTAMP:20990101T000000Z
        DTSTART:20990105T090000Z
        DTEND:20990105T093000Z
        RRULE:FREQ=WEEKLY
        EXDATE:20990119T090000Z
        SUMMARY:Standup
        END:VEVENT
        BEGIN:VEVENT
        UID:moved-1
        RECURRENCE-ID:20990112T090000Z
        DTSTAMP:20990101T000000Z
        DTSTART:20990121T090000Z
        DTEND:20990121T093000Z
        SUMMARY:Standup
        END:VEVENT
        END:VCALENDAR
        """.replacingOccurrences(of: "\n", with: "\r\n")
        var patch = GCalEventInput()
        // The new part's start as the provider gives it (`partEdit`): the cut (26th), an hour on.
        patch.startDateTime = "2099-01-26T10:00:00Z"
        patch.startTimeZone = "UTC"
        let named = (start: try #require(Date.fromISO8601("2099-01-21T09:00:00Z")), place: try #require(Date.fromISO8601("2099-01-12T09:00:00Z")))
        let r = try CalDAVProvider.seriesSplitResources(
            storedICS: ics, slotNaiveISO: "2099-01-26T09:00:00", cappedRRule: "RRULE:FREQ=WEEKLY;UNTIL=20990126T085959Z",
            newRRule: "RRULE:FREQ=WEEKLY", newUid: "moved-2", patch: patch, now: Date(),
            zones: CalendarTimeZoneContext(calendarText: ics), named: named)
        #expect(r.mode == .reset)
        #expect(r.cappedSeries.contains("EXDATE:20990119T090000Z"), "the deleted occurrence came back: \(r.cappedSeries)")
        #expect(!r.newPart.contains("EXDATE"), "the new part kept an excluded date on a reset: \(r.newPart)")
        #expect(Self.override("20990112T090000Z", in: r.cappedSeries).contains("DTSTART:20990121T100000Z"), "\(r.cappedSeries)")
    }

    @Test("CalDAV: an occurrence moved past the series' last place: the edit reaches what is shown from it on, and nothing else (owner rule e)")
    func calDAVPastEnd() throws {
        var patch = GCalEventInput()
        patch.summary = "Renamed"
        let edited = try CalDAVProvider.pastEndResource(
            storedICS: Self.calDAVMovedSeries, patch: patch, shownFrom: try #require(Date.fromISO8601("2099-01-14T09:00:00Z")),
            shift: 0, length: nil, zones: CalendarTimeZoneContext(calendarText: Self.calDAVMovedSeries))
        #expect(Self.override("20990112T090000Z", in: edited).contains("SUMMARY:Renamed"))
        #expect(Self.override("20990126T090000Z", in: edited).contains("SUMMARY:Standup"), "an occurrence shown before it changed")
        #expect(edited.contains("RRULE:FREQ=WEEKLY\r\n"), "the rule changed")
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
