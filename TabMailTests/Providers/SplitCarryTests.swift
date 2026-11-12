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
        #expect(SplitCarry.mode(edit: edit, place: place, storedRules: ["RRULE:FREQ=WEEKLY"]) == .carry)
        edit.startDateTime = Self.at(7)
        #expect(SplitCarry.mode(edit: edit, place: place, storedRules: ["RRULE:FREQ=WEEKLY"]) == .carry)
    }

    @Test("a start elsewhere than the place, or another rule, resets")
    func startOrRuleChangeResets() throws {
        let place = GCalDateTime(dateTime: Self.at(7), date: nil, timeZone: "UTC")
        var moved = GCalEventInput()
        moved.startDateTime = Self.at(7, "10:00:00")
        #expect(SplitCarry.mode(edit: moved, place: place, storedRules: ["RRULE:FREQ=WEEKLY"]) == .reset)
        var rule = GCalEventInput()
        rule.recurrence = ["RRULE:FREQ=DAILY"]
        #expect(SplitCarry.mode(edit: rule, place: place, storedRules: ["RRULE:FREQ=WEEKLY"]) == .reset)
        var same = GCalEventInput()
        same.recurrence = ["RRULE:FREQ=WEEKLY"]
        #expect(SplitCarry.mode(edit: same, place: place, storedRules: ["RRULE:FREQ=WEEKLY"]) == .carry)
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

    @Test("a deleted occurrence stays deleted; a changed one keeps only what the edit did not set")
    func planKeepsOwnChanges() throws {
        let series = try Self.event(Self.series)
        let newPart = series
        let renamedAndRoom = try Self.occurrence(place: 14, start: Self.at(14), end: Self.at(14, "09:30:00"),
                                                 extra: ["summary": "Own", "location": "Room 2"])
        let onlyTitle = try Self.occurrence(place: 21, start: Self.at(21), end: Self.at(21, "09:30:00"), extra: ["summary": "Own"])
        let deletedPlace = GCalDateTime(dateTime: Self.at(28), date: nil, timeZone: "UTC")
        let plan = try #require(SplitCarry.plan(
            exceptions: [.changed(renamedAndRoom), .changed(onlyTitle), .deleted(place: deletedPlace)],
            series: series, newPart: newPart, fields: [.summary]))
        #expect(plan.deleted.count == 1 && plan.deleted.first?.dateTime == Self.at(28))
        // The title the edit set overwrites; the room stays the occurrence's own. One with only a
        // title of its own has nothing left to carry.
        #expect(plan.changed.count == 1, "changed: \(plan.changed.map(\.own))")
        guard plan.changed.count == 1 else { return }
        #expect(plan.changed[0].own == [.location] && plan.changed[0].start == nil)
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
