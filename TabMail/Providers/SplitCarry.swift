/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// What a "this and following" split does with the occurrences of the series, from the split on,
/// that were deleted or changed one by one (#563), and where it splits (#687). Pure and
/// provider-neutral: each calendar reads its own exceptions, hands them here as `GCalEvent`
/// values, and writes what comes back in its own terms.
///
/// The rule, Google Calendar's (measured on a test calendar):
/// - A split is an edit of every occurrence of its new part, which starts at the PLACE of the
///   occurrence named (`originalStartTime`), not where that occurrence was moved to. The series
///   is capped before that place, and an occurrence moved from its place is carried like any
///   other changed occurrence.
/// - **Reset** (`Mode.reset`) when the edit moves the new part's start (another instant or day
///   than the place) or changes its rule: nothing is carried; deleted occurrences come back and
///   changed ones lose their change, and the new part's excluded dates go.
/// - **Carry** (`Mode.carry`) otherwise: a deleted occurrence stays deleted; a changed one keeps
///   its own changes, except the fields the edit sets, which overwrite them; an end given alone
///   gives it its own start plus the new part's length; its guests get the series' difference.
///   Only an edit that leaves the start where it is carries, so no carried place moves.
enum SplitCarry {
    /// Whether a split carries the exceptions after it or resets them.
    enum Mode: String, Sendable, Equatable {
        case reset
        case carry
    }

    /// A field an edit sets, which overwrites a carried occurrence's own value. Stored by name on
    /// the split's record (`SplitRecord.fields`), so a retry carries as the first attempt did.
    enum Field: String, Sendable, CaseIterable, Comparable {
        case summary, location, description, transparency, attendees, end

        static func < (a: Field, b: Field) -> Bool { a.rawValue < b.rawValue }
    }

    /// The fields `edit` sets.
    static func fields(of edit: GCalEventInput) -> Set<Field> {
        var set = Set<Field>()
        if edit.summary != nil { set.insert(.summary) }
        if edit.location != nil { set.insert(.location) }
        if edit.description != nil { set.insert(.description) }
        if edit.transparency != nil { set.insert(.transparency) }
        if edit.attendeeChange != nil { set.insert(.attendees) }
        if edit.endDate != nil || edit.endDateTime != nil { set.insert(.end) }
        return set
    }

    /// THE mode of a split whose new part starts at `place` with `edit`, the series' rules being
    /// `storedRules`: the one predicate the confirmation card (its reset note) and every
    /// calendar's write call, so the two can't disagree. Reset when the edit gives a start that is
    /// not the place (another instant, another day, or the other kind), turns the rule's days
    /// (`ruleDayMove`), or gives a rule other than the stored one.
    static func mode(edit: GCalEventInput, place: GCalDateTime, storedRules: [String]) -> Mode {
        if edit.ruleDayMove != nil { return .reset }
        if let rules = edit.recurrence?.filter(isRule), !rules.isEmpty {
            let given = Set(rules.map(GoogleCalendarProvider.canonicalRRULE))
            let stored = Set(storedRules.filter(isRule).map(GoogleCalendarProvider.canonicalRRULE))
            if given != stored { return .reset }
        }
        if edit.startDate != nil || edit.startDateTime != nil {
            if let date = edit.startDate {
                guard let placeDate = place.date, String(date.prefix(10)) == String(placeDate.prefix(10)) else { return .reset }
            } else {
                guard let given = edit.startDateTime.flatMap(Date.fromISO8601),
                      let at = place.dateTime.flatMap(Date.fromISO8601), given == at else { return .reset }
            }
        }
        return .carry
    }

    private static func isRule(_ line: String) -> Bool { line.uppercased().hasPrefix("RRULE:") }

    /// The place of `occurrence` in its series, as a naive wall clock in `zone`, in the form a
    /// split's `recurrence_id` takes: `yyyy-MM-dd'T'HH:mm:ss` for a timed occurrence, the date for
    /// an all-day one (in the form `recurrenceId` has). `recurrenceId` itself when the occurrence
    /// starts at its place, so an unmoved occurrence's split is addressed exactly as before. Nil
    /// when the place can't be read.
    static func placeNaive(of occurrence: GCalEvent, recurrenceId: String, zone: TimeZone) -> String? {
        guard RecurrenceOccurrenceResolver.wasMoved(occurrence) else { return recurrenceId }
        guard let place = occurrence.originalStartTime else { return nil }
        if let date = place.date {
            let day = String(date.prefix(10))
            return recurrenceId.contains("T") ? "\(day)T00:00:00" : day
        }
        guard let instant = place.dateTime.flatMap(Date.fromISO8601) else { return nil }
        return naive(instant, in: zone)
    }

    /// `instant` as a naive `yyyy-MM-dd'T'HH:mm:ss` wall clock in `zone`.
    static func naive(_ instant: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: instant)
    }

    /// The edit the new part is written with. An end given alone, at an occurrence moved from its
    /// place, gives the length from where that occurrence starts now (Google: the new end minus
    /// the moved occurrence's current start), and the new part, which starts at the place, keeps
    /// that length. Every other edit is written as given. Nil when the length can't be read.
    static func partEdit(_ edit: GCalEventInput, named: GCalEvent) -> GCalEventInput? {
        guard edit.startDate == nil, edit.startDateTime == nil,
              edit.endDate != nil || edit.endDateTime != nil,
              RecurrenceOccurrenceResolver.wasMoved(named) else { return edit }
        guard let place = named.originalStartTime, let start = named.start else { return nil }
        var written = edit
        if let end = edit.endDate {
            guard let from = start.date.flatMap(day), let to = day(end), let at = place.date.flatMap(day),
                  let days = gregorianUTC.dateComponents([.day], from: from, to: to).day,
                  let moved = gregorianUTC.date(byAdding: .day, value: days, to: at) else { return nil }
            written.endDate = dayString(moved)
        } else if let end = edit.endDateTime.flatMap(Date.fromISO8601) {
            guard let from = start.dateTime.flatMap(Date.fromISO8601),
                  let at = place.dateTime.flatMap(Date.fromISO8601) else { return nil }
            let zone = edit.endTimeZone.flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) } ?? .gmt
            written.endDateTime = at.addingTimeInterval(end.timeIntervalSince(from)).iso8601String(timeZone: zone)
        } else {
            return nil
        }
        return written
    }

    // MARK: - The plan

    /// One exception of the series from the split on, read from the calendar.
    enum Exception {
        /// Deleted on its own; `place` is where the series had it.
        case deleted(place: GCalDateTime)
        /// Changed on its own; its `originalStartTime` is its place.
        case changed(GCalEvent)

        var place: GCalDateTime? {
            switch self {
            case .deleted(let place): return place
            case .changed(let event): return event.originalStartTime
            }
        }
    }

    /// What a carry writes for one changed occurrence of the new part, at `place`: its own value
    /// of each field in `own` (the calendar takes it from the exception it read), and its own times
    /// (`start`, `end`, absolute) when it starts or ends elsewhere than the new part's plain
    /// occurrence there. `guests` is set when the occurrence holds guests of its own: its own list
    /// with the edit's change applied as the series' difference.
    struct Change {
        let place: GCalDateTime
        let exception: GCalEvent
        let own: Set<Field>
        let start: GCalDateTime?
        let end: GCalDateTime?
    }

    /// What a carry writes: the places deleted on their own, and the changed occurrences.
    struct Plan {
        var deleted: [GCalDateTime] = []
        var changed: [Change] = []
    }

    /// The carry of `exceptions` (every exception at or after the split, deleted or changed) into
    /// a new part whose occurrences are `newPart` (its start and end give the length L), from a
    /// series `series` (its fields are what an occurrence's own change differs from), under an
    /// edit that set `fields`.
    ///
    /// For each changed occurrence, a field is its own when its value differs from the series'
    /// and the edit did not set it; the edit's value is the new part's already. Its times are its
    /// own when it starts elsewhere than its place or lasts other than the series: start kept, end
    /// its own, or its own start plus L when the edit set the end. One with nothing of its own left
    /// is not written. Nil when a time or place can't be read.
    static func plan(exceptions: [Exception], series: GCalEvent, newPart: GCalEvent, fields: Set<Field>) -> Plan? {
        var plan = Plan()
        let seriesLength = length(of: series)
        let partLength = length(of: newPart)
        for exception in exceptions {
            switch exception {
            case .deleted(let place):
                plan.deleted.append(place)
            case .changed(let event):
                guard let place = event.originalStartTime, let start = event.start, let end = event.end else { return nil }
                var own = Set<Field>()
                if !fields.contains(.summary), (event.summary ?? "") != (series.summary ?? "") { own.insert(.summary) }
                if !fields.contains(.location), (event.location ?? "") != (series.location ?? "") { own.insert(.location) }
                if !fields.contains(.description), (event.description ?? "") != (series.description ?? "") { own.insert(.description) }
                if !fields.contains(.transparency), (event.transparency ?? "opaque") != (series.transparency ?? "opaque") {
                    own.insert(.transparency)
                }
                if guestAddresses(event) != guestAddresses(series) { own.insert(.attendees) }
                let moved = RecurrenceOccurrenceResolver.wasMoved(event)
                let ownLength = length(of: event)
                var times: (GCalDateTime, GCalDateTime)?
                if fields.contains(.end) {
                    if moved {
                        guard let partLength, let shifted = adding(partLength, to: start) else { return nil }
                        times = (start, shifted)
                    }
                } else if moved || ownLength == nil || ownLength != seriesLength {
                    times = (start, end)
                }
                if own.isEmpty, times == nil { continue }
                plan.changed.append(Change(place: place, exception: event, own: own, start: times?.0, end: times?.1))
            }
        }
        return plan
    }

    /// Whether `place` is at or after the split at `split`: instants for a timed series, dates for
    /// an all-day one. Nil when either can't be read.
    static func isInTail(_ place: GCalDateTime, split: GCalDateTime) -> Bool? {
        if let date = place.date, let at = split.date { return String(date.prefix(10)) >= String(at.prefix(10)) }
        guard let instant = place.dateTime.flatMap(Date.fromISO8601),
              let at = split.dateTime.flatMap(Date.fromISO8601) else { return nil }
        return instant >= at
    }

    /// The guests of `event` by address, lowercased.
    private static func guestAddresses(_ event: GCalEvent) -> Set<String> {
        Set((event.attendees ?? []).compactMap { $0.email?.lowercased() })
    }

    /// How long `event` lasts: seconds for a timed one, whole days (in seconds) for an all-day one.
    static func length(of event: GCalEvent) -> TimeInterval? {
        if let s = event.start?.date.flatMap(day), let e = event.end?.date.flatMap(day) { return e.timeIntervalSince(s) }
        guard let s = event.start?.dateTime.flatMap(Date.fromISO8601),
              let e = event.end?.dateTime.flatMap(Date.fromISO8601) else { return nil }
        return e.timeIntervalSince(s)
    }

    /// `start` moved by `length`: a date by whole days, a time by seconds, in its own zone.
    private static func adding(_ length: TimeInterval, to start: GCalDateTime) -> GCalDateTime? {
        if let date = start.date.flatMap(day) {
            guard let moved = gregorianUTC.date(byAdding: .day, value: Int((length / 86_400).rounded()), to: date) else { return nil }
            return GCalDateTime(dateTime: nil, date: dayString(moved), timeZone: start.timeZone)
        }
        guard let at = start.dateTime.flatMap(Date.fromISO8601) else { return nil }
        let zone = start.timeZone.flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) } ?? .gmt
        return GCalDateTime(dateTime: at.addingTimeInterval(length).iso8601String(timeZone: zone), date: nil, timeZone: start.timeZone)
    }

    private static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = gregorianUTC
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = gregorianUTC
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
