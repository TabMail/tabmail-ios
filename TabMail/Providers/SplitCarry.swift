/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// What a "this and following" split does with the occurrences of the series, from the split on,
/// that were deleted or changed one by one (#563), and where it splits (#687). Pure and
/// provider-neutral: each calendar reads its own exceptions, hands them here as `GCalEvent`
/// values, and writes what comes back in its own terms.
///
/// The rule (where to cut: calendar order; what to carry: Google Calendar's, measured on a test calendar):
/// - A split changes the occurrence named and every one shown after it, by where each is now
///   (`cut`): the new part starts at the first place of the series at or after where the
///   occurrence named starts now, and the series is capped before it. An occurrence shown after
///   the named one but placed before the cut is edited where it is (`Parts.edited`); one placed
///   after the cut but shown before the named one is carried whole, unchanged (`Parts.kept`).
///   Past the series' last place nothing is cut and only the occurrences shown are edited
///   (`Cut.pastEnd`).
/// - **Reset** (`Mode.reset`) when the edit moves the new part's start (another instant or day
///   than the cut, or the same instant in another time zone) or changes its rule: nothing is carried; deleted occurrences come back and
///   changed ones lose their change, and the new part's excluded dates go.
/// - **Carry** (`Mode.carry`) otherwise: a deleted occurrence stays deleted; a changed one is
///   carried WHOLE (everything it holds that the calendar lets the organizer write, its guests'
///   answers included), except the fields the edit sets, which the new part already holds; an end
///   given alone gives it its own start plus the new part's length; its guests get the series'
///   difference.
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
    /// `seriesZone` is the zone the series' start is kept in (nil for a floating or all-day one):
    /// a start given in another zone at the same instant is a new start.
    static func mode(edit: GCalEventInput, place: GCalDateTime, storedRules: [String], seriesZone: TimeZone?) -> Mode {
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
                // Another time zone at the same instant is a new start too: Google's own
                // "this and following" resets the later exceptions for a zone-only change
                // (measured on a test calendar), and the same rule holds on every calendar.
                if let zone = edit.startTimeZone, let seriesZone, !sameZone(zone, seriesZone) { return .reset }
            }
        }
        return .carry
    }

    private static func isRule(_ line: String) -> Bool { line.uppercased().hasPrefix("RRULE:") }

    /// Whether the zone named `name` is `zone`: the name resolves (`CalendarTimeZoneResolver`, so a
    /// Windows name and its IANA name agree) to the same zone. A name that does not resolve is
    /// another zone.
    private static func sameZone(_ name: String, _ zone: TimeZone) -> Bool {
        guard let given = CalendarTimeZoneResolver.zone(named: name, in: .none) else { return false }
        return given.identifier == zone.identifier
    }

    /// The split point of a split at `cut` named at `occurrence`, as a naive wall clock in `zone`,
    /// in the form a split's `recurrence_id` takes: `yyyy-MM-dd'T'HH:mm:ss` for a timed series,
    /// the date for an all-day one (in the form `recurrenceId` has). `recurrenceId` itself when the
    /// occurrence starts at its place, so an unmoved occurrence's split is addressed exactly as
    /// before. Nil when the cut can't be read.
    static func splitAt(_ cut: GCalDateTime, named occurrence: GCalEvent, recurrenceId: String, zone: TimeZone) -> String? {
        guard RecurrenceOccurrenceResolver.wasMoved(occurrence) else { return recurrenceId }
        return naive(of: cut, recurrenceId: recurrenceId, zone: zone)
    }

    /// The whole days from the date `from` begins with to the date `to` begins with. Nil when
    /// either can't be read.
    private static func days(from: String, to: String) -> Int? {
        guard let a = day(from), let b = day(to) else { return nil }
        return gregorianUTC.dateComponents([.day], from: a, to: b).day
    }

    /// The date `text` begins with, moved by `count` days: `.some(nil)` when there is none, nil
    /// when it can't be read.
    private static func movedDay(_ text: String?, by count: Int) -> String?? {
        guard let text else { return .some(nil) }
        guard let date = day(text), let out = gregorianUTC.date(byAdding: .day, value: count, to: date) else { return nil }
        return .some(dayString(out))
    }

    /// `instant` as a naive `yyyy-MM-dd'T'HH:mm:ss` wall clock in `zone`.
    static func naive(_ instant: Date, in zone: TimeZone) -> String {
        FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: zone).string(from: instant)
    }

    /// The edit the new part is written with, the new part starting at `cut`. Each time the edit
    /// gives is measured from where the occurrence named starts now (`namedStart`) and moved by
    /// the same amount from the cut: an end given alone keeps the length it gives from that start
    /// (Google: the new end minus the moved occurrence's current start), and a start given moves
    /// the new part, and every occurrence after it, as far as it moves the one named (owner rule,
    /// 2026-11-12). At a cut that is the named start (an occurrence never moved), the edit is
    /// written as given. A change between all-day and timed moves the new part by whole days, the
    /// days from the named occurrence's day to the day given, read in the series' zone `zone`
    /// (#837: the new part takes the requested kind), and keeps the time of day given. Nil when a
    /// time can't be read.
    static func partEdit(_ edit: GCalEventInput, namedStart: GCalDateTime, cut: GCalDateTime, zone: TimeZone?) -> GCalEventInput? {
        guard isInTail(namedStart, split: cut) != true || isInTail(cut, split: namedStart) != true else { return edit }
        var written = edit
        if cut.date == nil, edit.startDate != nil || edit.endDate != nil {
            // A timed series made all-day: the dates given, moved by the days from the named
            // occurrence's day to the cut's, in the series' zone.
            guard let zone, let from = namedStart.dateTime.flatMap(Date.fromISO8601), let at = cut.dateTime.flatMap(Date.fromISO8601),
                  let days = days(from: naive(from, in: zone), to: naive(at, in: zone)) else { return nil }
            guard let start = movedDay(edit.startDate, by: days), let end = movedDay(edit.endDate, by: days) else { return nil }
            written.startDate = start
            written.endDate = end
            return written
        }
        if let date = cut.date, edit.startDateTime != nil || edit.endDateTime != nil {
            // An all-day series made timed: each time given, moved by the days from the named
            // occurrence's date to the cut's, at the time of day given in its own zone.
            guard let named = namedStart.date, let days = days(from: named, to: date) else { return nil }
            func moved(_ text: String?, zone name: String?) -> String?? {
                guard let text else { return .some(nil) }
                guard let given = Date.fromISO8601(text) else { return nil }
                let zone = name.flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) } ?? .gmt
                let wall = naive(given, in: zone)
                guard let day = movedDay(String(wall.prefix(10)), by: days).flatMap({ $0 }),
                      let instant = GoogleCalendarProvider.naiveInstant("\(day)T\(wall.dropFirst(11))", zone: zone) else { return nil }
                return .some(instant.iso8601String(timeZone: zone))
            }
            guard let start = moved(edit.startDateTime, zone: edit.startTimeZone),
                  let end = moved(edit.endDateTime, zone: edit.endTimeZone) else { return nil }
            written.startDateTime = start
            written.endDateTime = end
            return written
        }
        if let date = cut.date {
            guard let from = namedStart.date.flatMap(day), let at = day(date) else { return nil }
            func moved(_ text: String?) -> String?? {
                guard let text else { return .some(nil) }
                guard let to = day(text), let days = gregorianUTC.dateComponents([.day], from: from, to: to).day,
                      let out = gregorianUTC.date(byAdding: .day, value: days, to: at) else { return nil }
                return .some(dayString(out))
            }
            guard let start = moved(edit.startDate), let end = moved(edit.endDate) else { return nil }
            written.startDate = start
            written.endDate = end
        } else {
            guard let from = namedStart.dateTime.flatMap(Date.fromISO8601), let at = cut.dateTime.flatMap(Date.fromISO8601) else { return nil }
            func moved(_ text: String?, zone name: String?) -> String?? {
                guard let text else { return .some(nil) }
                guard let given = Date.fromISO8601(text) else { return nil }
                let zone = name.flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) } ?? .gmt
                return .some(at.addingTimeInterval(given.timeIntervalSince(from)).iso8601String(timeZone: zone))
            }
            guard let start = moved(edit.startDateTime, zone: edit.startTimeZone),
                  let end = moved(edit.endDateTime, zone: edit.endTimeZone) else { return nil }
            written.startDateTime = start
            written.endDateTime = end
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

    /// What a carry writes for one changed occurrence of the new part, at `place` (the new part's
    /// occurrence it is written on): the whole
    /// `exception` as the calendar read it, but for the fields the edit set (the calendar copies
    /// its own read of it), and its own times (`start`, `end`, absolute) when it starts or ends
    /// elsewhere than the new part's plain occurrence there.
    struct Change {
        let place: GCalDateTime
        let exception: GCalEvent
        let start: GCalDateTime?
        let end: GCalDateTime?
        /// Written whole, the fields the edit set and its guests included (`Parts.kept`): the
        /// occurrence is shown before the one named, so the edit does not reach it.
        var whole = false
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
    /// Every changed occurrence is written: what makes it an exception may be anything it holds
    /// (a guest's answer, a reminder, a colour), so none is judged unchanged. Its times are its own
    /// when it starts elsewhere than its place or lasts other than the series: start kept, end its
    /// own, or its own start plus L when the edit set the end. Nil when a time or place can't be
    /// read.
    ///
    /// `kept` (`Parts.kept`) are written whole at their own times, in either mode. `named`, on a
    /// reset, is the occurrence named when it was moved and is placed in the new part: it is
    /// carried like a changed one, at its own times moved by `shift`, so it starts where the edit
    /// put it; a `shift` that can't be read (nil, `shift(cut:newPart:)`) is needed only then. Each
    /// of them is written at its `slot`, the new part's occurrence that stands for its place
    /// (`slot(of:cut:newPart:series:zone:missingDay:)`), which on a reset that moves the new
    /// part is not its old place; the exceptions after the cut are carried only by an edit that
    /// moves nothing, so they keep their places.
    static func plan(
        exceptions: [Exception], kept: [(event: GCalEvent, slot: GCalDateTime)] = [],
        named: (event: GCalEvent, slot: GCalDateTime)? = nil, shift: TimeInterval? = 0,
        series: GCalEvent, newPart: GCalEvent, fields: Set<Field>
    ) -> Plan? {
        var plan = Plan()
        for (event, slot) in kept {
            guard let start = event.start, let end = event.end else { return nil }
            plan.changed.append(Change(place: slot, exception: event, start: start, end: end, whole: true))
        }
        if let (named, slot) = named {
            guard let start = named.start, let end = named.end,
                  let edit = edits(of: [named], shift: shift, length: length(of: newPart), fields: fields)?.first else { return nil }
            plan.changed.append(Change(place: slot, exception: named, start: edit.start ?? start, end: edit.end ?? end))
        }
        let seriesLength = length(of: series)
        let partLength = length(of: newPart)
        for exception in exceptions {
            switch exception {
            case .deleted(let place):
                plan.deleted.append(place)
            case .changed(let event):
                guard let place = event.originalStartTime, let start = event.start, let end = event.end else { return nil }
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
                plan.changed.append(Change(place: place, exception: event, start: times?.0, end: times?.1))
            }
        }
        return plan
    }

    // MARK: - The carry onto the new part

    /// Why a split is refused when an occurrence moved to before the one named, but placed in the
    /// new part (`Parts.kept`), has no occurrence of the new part to stay on: the new part is of
    /// the other kind (all-day or timed), or repeats on other days. It must keep what it shows
    /// (owner rule, 2026-11-12), and the new part has nowhere to keep it. Refused before anything
    /// is written.
    static let keptHasNoSlotRefusal =
        "An occurrence of this repeating event moved to before the one named has no place in the new repeat, so it would vanish or change, and the occurrences from the one named on can't be split off. Make the change in your calendar app instead."

    /// Why a change between all-day and timed is refused when an occurrence moved to after the one
    /// named is placed before the cut (`Parts.edited`): it stays on the old part, which keeps its
    /// kind, and one occurrence can't change kind on its own, so the edit can't reach it.
    /// Refused before anything is written.
    static let editedKindRefusal =
        "An occurrence of this repeating event moved to after the one named stays on the earlier part, which can't change between all-day and timed for one occurrence, so the occurrences from the one named on can't be split off. Make the change in your calendar app instead."

    /// THE carry a split writes onto its new part `newPart` (its start, its end, its rule in its
    /// `recurrence`), cut at `cut` from `series` (its places wall clocks in `zone`, nil for an
    /// all-day one): on a carry the exceptions after the cut, in either mode those shown before the
    /// one named whole (`Parts.kept`), and on a reset the one named when it was moved, moved as the
    /// edit moves it. Each is written on the new part's occurrence that stands for its place
    /// (`slot`). Decided before the new part is created, against the part the create will write,
    /// and again on a retry against the part written, so no carried write can miss its occurrence
    /// after the create:
    /// - one shown before the one named with no occurrence on the new part is refused
    ///   (`keptHasNoSlotRefusal`);
    /// - the one named with none (a change of kind, or a new rule that does not place it) is reset,
    ///   as a reset resets every changed occurrence: it is the new part's own occurrence, in the
    ///   requested kind;
    /// - a change of kind is refused while an occurrence shown after the one named stays on the old
    ///   part (`editedKindRefusal`).
    /// Nil when a time can't be read.
    static func carryPlan(
        parts: Parts, mode: Mode, namedStart: GCalDateTime, namedPlace: GCalDateTime, cut: GCalDateTime,
        series: GCalEvent, zone: TimeZone?, newPart: GCalEvent, fields: Set<Field>,
        missingDay: RecurrenceTail.MissingMonthDay = .skip
    ) throws -> Plan? {
        guard let partStart = newPart.start else { return nil }
        if (cut.date != nil) != (partStart.date != nil), !parts.edited.isEmpty {
            throw CalendarProviderError.notSupported(editedKindRefusal)
        }
        func slotOf(_ place: GCalDateTime) -> GCalDateTime? {
            slot(of: place, cut: cut, newPart: newPart, series: series, zone: zone, missingDay: missingDay)
        }
        var kept: [(event: GCalEvent, slot: GCalDateTime)] = []
        for event in parts.kept {
            guard let place = event.originalStartTime else { return nil }
            guard let slot = slotOf(place) else { throw CalendarProviderError.notSupported(keptHasNoSlotRefusal) }
            kept.append((event, slot))
        }
        var named: (event: GCalEvent, slot: GCalDateTime)?
        if mode == .reset, key(namedStart) != key(namedPlace), let event = Self.named(in: parts, place: namedPlace),
           let slot = slotOf(namedPlace) {
            named = (event, slot)
        }
        return plan(
            exceptions: mode == .carry ? parts.tail : [], kept: kept, named: named, shift: shift(cut: cut, newPart: newPart),
            series: series, newPart: newPart, fields: fields)
    }

    /// The occurrence of the new part `newPart` that stands for the place `place` of `series`, cut
    /// at `cut`: `place` moved as far as the new part's start is from the cut, in whole days on the
    /// series' wall clock (`zone`; dates for an all-day series), at the new part's own time of day
    /// on that clock, so a move across a change of offset lands on the occurrence the calendar
    /// lists. A split's new part repeats in the series' zone on every provider, with a new rule too
    /// (Google labels it with the series' zone, Outlook writes its start and range in it, a zoned
    /// CalDAV copy keeps its own), so one clock serves both. It counts only when the new part's rule (its
    /// `recurrence`) names that day (`missingDay` as the calendar reads it); a new part that keeps
    /// the series' days and pattern places it there without reading the rule. A new part's start
    /// that its rule does not name is never a slot (`.patternStart`): RFC 5545 §3.3.10 leaves such
    /// a recurrence set undefined, so whether the calendar lists an occurrence there is not known.
    /// Nil when there is none: the new part is of the other kind (all-day or timed), its rule
    /// names no occurrence there or has ended before it (its `UNTIL` or `COUNT`,
    /// `endsAtOrAfter`), or a time or the rule can't be read.
    static func slot(
        of place: GCalDateTime, cut: GCalDateTime, newPart: GCalEvent, series: GCalEvent, zone: TimeZone?,
        missingDay: RecurrenceTail.MissingMonthDay = .skip
    ) -> GCalDateTime? {
        guard let start = newPart.start else { return nil }
        let placeDay: String, cutDay: String, startDay: String
        let out: (String) -> GCalDateTime?
        if let date = place.date {
            guard let cutDate = cut.date, let startDate = start.date else { return nil }
            (placeDay, cutDay, startDay) = (String(date.prefix(10)), String(cutDate.prefix(10)), String(startDate.prefix(10)))
            out = { GCalDateTime(dateTime: nil, date: $0, timeZone: nil) }
        } else {
            guard let zone, cut.date == nil, start.date == nil,
                  let at = place.dateTime.flatMap(Date.fromISO8601), let cutAt = cut.dateTime.flatMap(Date.fromISO8601),
                  let startAt = start.dateTime.flatMap(Date.fromISO8601) else { return nil }
            let startWall = naive(startAt, in: zone)
            (placeDay, cutDay, startDay) = (String(naive(at, in: zone).prefix(10)), String(naive(cutAt, in: zone).prefix(10)), String(startWall.prefix(10)))
            out = { day in
                GoogleCalendarProvider.naiveInstant("\(day)T\(startWall.dropFirst(11))", zone: zone)
                    .map { GCalDateTime(dateTime: $0.iso8601String(), date: nil, timeZone: "UTC") }
            }
        }
        guard let from = day(cutDay), let to = day(startDay), let at = day(placeDay),
              let days = gregorianUTC.dateComponents([.day], from: from, to: to).day,
              let moved = gregorianUTC.date(byAdding: .day, value: days, to: at) else { return nil }
        let slotDay = dayString(moved)
        if days != 0 || !samePattern(newPart.recurrence, series.recurrence) {
            guard let rule = newPart.recurrence?.first(where: isRule), let first = RecurrenceTail.Day(iso: startDay),
                  let target = RecurrenceTail.Day(iso: slotDay),
                  RecurrenceTail.firstDay(of: rule, seriesStart: first, onOrAfter: target, anchor: .patternStart, missingDay: missingDay) == .day(target)
            else { return nil }
        }
        guard let slot = out(slotDay),
              endsAtOrAfter(newPart, slot: slot, slotDay: slotDay, startDay: startDay, zone: zone, missingDay: missingDay) else { return nil }
        return slot
    }

    /// Whether the new part `newPart` (starting on `startDay`) has not ended by its occurrence
    /// `slot` on `slotDay`, a day its rule names: by its rule's `UNTIL` (inclusive; a date names
    /// its whole day, a UTC time an instant, a time with no zone a wall clock in the series' zone
    /// `zone`, the one the part repeats in) or its `COUNT` (the occurrences from its start
    /// before `slotDay` fewer than the count, its start counted as the first as RFC 5545 counts
    /// it, which can only count one more than Outlook's range does). A rule with neither has not.
    /// False when the end can't be read: no slot.
    private static func endsAtOrAfter(
        _ newPart: GCalEvent, slot: GCalDateTime, slotDay: String, startDay: String, zone: TimeZone?,
        missingDay: RecurrenceTail.MissingMonthDay
    ) -> Bool {
        guard let rule = newPart.recurrence?.first(where: isRule) else { return true }
        let parts = rule.uppercased().dropFirst("RRULE:".count).split(separator: ";").map(String.init)
        guard let target = RecurrenceTail.Day(iso: slotDay) else { return false }
        if let count = parts.first(where: { $0.hasPrefix("COUNT=") }) {
            guard let total = Int(count.dropFirst("COUNT=".count)), let first = RecurrenceTail.Day(iso: startDay),
                  let before = RecurrenceTail.occurrences(of: rule, seriesStart: first, before: target, missingDay: missingDay)
            else { return false }
            return before < total
        }
        guard let until = parts.first(where: { $0.hasPrefix("UNTIL=") }).map({ String($0.dropFirst("UNTIL=".count)) }) else { return true }
        if until.count == 8 || slot.date != nil {
            guard let last = RecurrenceTail.Day(ical: until) else { return false }
            return target <= last
        }
        guard let at = slot.dateTime.flatMap(Date.fromISO8601) else { return false }
        if until.hasSuffix("Z") {
            guard let end = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss'Z'", timeZone: .gmt).date(from: until) else { return false }
            return at <= end
        }
        guard let zone,
              let end = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss", timeZone: zone).date(from: until) else { return false }
        return at <= end
    }

    /// Whether two series' rules repeat alike: the same parts but where they end (`UNTIL`,
    /// `COUNT`), which a split's new part takes over from what is left of the series.
    private static func samePattern(_ a: [String]?, _ b: [String]?) -> Bool {
        func parts(_ lines: [String]?) -> Set<String>? {
            guard let rule = lines?.first(where: isRule) else { return nil }
            return Set(rule.uppercased().dropFirst("RRULE:".count).split(separator: ";").map(String.init)
                .filter { !$0.hasPrefix("UNTIL=") && !$0.hasPrefix("COUNT=") })
        }
        guard let a = parts(a), let b = parts(b) else { return false }
        return a == b
    }

    // MARK: - Calendar order (a split named at a moved occurrence)

    /// Why a split past the series' last place (`Cut.pastEnd`) can't change the repeat: no new
    /// part is left to take it. The write and the card refuse it in the same words.
    static let pastEndRuleRefusal = "the occurrence named is after the series' last one, so its repeat can't be changed from it"

    /// Where a split cuts its series.
    enum Cut: Equatable {
        /// The old series keeps every place before this one; the new part starts here.
        case at(GCalDateTime)
        /// The series has no place at or after the occurrence named: nothing is cut, and the edit
        /// is written onto the occurrences shown from the named one on (`Parts.edited`).
        case pastEnd
    }

    /// The pattern of a series, as a split reads it to find its cut.
    struct Pattern {
        /// The series' RRULE line.
        let rule: String
        /// The series' first start.
        let start: GCalDateTime
        /// The zone its places are wall clocks in (nil for an all-day series).
        let zone: TimeZone?
        /// Its added places (`RDATE`).
        var added: [GCalDateTime] = []
        var anchor: RecurrenceTail.Anchor = .dtstart
        var missingDay: RecurrenceTail.MissingMonthDay = .skip
    }

    /// THE cut of a split named at an occurrence that starts at `namedStart` and has its place at
    /// `namedPlace` (owner rule, 2026-11-12: a split changes the occurrence named and every one
    /// shown after it, by where each is now). It is the first place of the series at or after
    /// `namedStart` (an instant for a timed series, a date for an all-day one, a tie counting as
    /// after), so every occurrence that was never moved falls on the side it is shown on. For an
    /// occurrence that was never moved it is its place, worked out without reading the rule.
    /// Nil when the rule or a time can't be read.
    static func cut(namedStart: GCalDateTime, namedPlace: GCalDateTime, moved: Bool, pattern: Pattern) -> Cut? {
        guard moved else { return .at(namedPlace) }
        let ruleCut = ruleCut(after: namedStart, pattern: pattern)
        guard let ruleCut else { return nil }
        var candidates: [GCalDateTime] = []
        if case .at(let place) = ruleCut { candidates.append(place) }
        for added in pattern.added {
            guard let after = isInTail(added, split: namedStart) else { return nil }
            if after { candidates.append(added) }
        }
        var first: GCalDateTime?
        for candidate in candidates {
            guard let current = first else { first = candidate; continue }
            guard let earlier = isInTail(current, split: candidate) else { return nil }
            if earlier { first = candidate }
        }
        return first.map(Cut.at) ?? .pastEnd
    }

    /// The cut of a split of `series` named at the occurrence `named` (`cut`), the series' pattern
    /// read from its `recurrence` lines: its RRULE, and its added dates (`RDATE`, read with
    /// `zones`). Its places are wall clocks in `zone`, the series' own (`seriesZone`) when not
    /// given. `rdates` are `RDATE` lines the series holds outside `recurrence` (a CalDAV series
    /// as `ICSParser` reads it). Nil when the occurrence or the series can't be read.
    static func cut(
        named: GCalEvent, series: GCalEvent, rdates: [String] = [], zone: TimeZone? = nil,
        zones: CalendarTimeZoneContext = .none,
        anchor: RecurrenceTail.Anchor = .dtstart, missingDay: RecurrenceTail.MissingMonthDay = .skip
    ) -> Cut? {
        guard let namedStart = named.start, let namedPlace = named.originalStartTime ?? named.start else { return nil }
        let moved = RecurrenceOccurrenceResolver.wasMoved(named)
        guard moved else { return .at(namedPlace) }
        let lines = (series.recurrence ?? []) + rdates
        guard let rule = lines.first(where: isRule), let start = series.start else { return nil }
        var added: [GCalDateTime] = []
        for line in lines where line.uppercased().hasPrefix("RDATE") {
            guard (try? CalDAVProvider.filterDateList(line, zones: zones, keep: { instant in
                added.append(series.isAllDay
                    ? GCalDateTime(dateTime: nil, date: naive(instant, in: .gmt).prefix(10).description, timeZone: nil)
                    : GCalDateTime(dateTime: instant.iso8601String(), date: nil, timeZone: "UTC"))
                return true
            })) != nil else { return nil }
        }
        let pattern = Pattern(
            rule: rule, start: start, zone: series.isAllDay ? nil : zone ?? series.seriesZone,
            added: added, anchor: anchor, missingDay: missingDay)
        return cut(namedStart: namedStart, namedPlace: namedPlace, moved: true, pattern: pattern)
    }

    /// The naive wall clock (`yyyy-MM-dd'T'HH:mm:ss`, or the date for an all-day series written
    /// as `recurrenceId` is) `cut` is in `zone`.
    static func naive(of cut: GCalDateTime, recurrenceId: String, zone: TimeZone) -> String? {
        if let date = cut.date {
            let day = String(date.prefix(10))
            return recurrenceId.contains("T") ? "\(day)T00:00:00" : day
        }
        return cut.dateTime.flatMap(Date.fromISO8601).map { naive($0, in: zone) }
    }

    /// The first place the RRULE gives at or after `namedStart`, or `.pastEnd` when its COUNT or
    /// UNTIL ends the series before one.
    private static func ruleCut(after namedStart: GCalDateTime, pattern: Pattern) -> Cut? {
        let body = pattern.rule.uppercased().hasPrefix("RRULE:") ? String(pattern.rule.dropFirst("RRULE:".count)) : pattern.rule
        let parts = body.uppercased().split(separator: ";").map(String.init)
        let until = parts.first { $0.hasPrefix("UNTIL=") }.map { String($0.dropFirst("UNTIL=".count)) }
        let count = parts.first { $0.hasPrefix("COUNT=") }.flatMap { Int($0.dropFirst("COUNT=".count)) }
        if parts.contains(where: { $0.hasPrefix("COUNT=") }), count == nil { return nil }

        // The place on `day`, and the first day of the pattern on or after `from`.
        let place: (RecurrenceTail.Day) -> GCalDateTime?
        let fromDay: RecurrenceTail.Day
        let seriesDay: RecurrenceTail.Day
        if let date = pattern.start.date {
            guard let start = RecurrenceTail.Day(iso: date), let named = namedStart.date.flatMap({ RecurrenceTail.Day(iso: $0) }) else { return nil }
            seriesDay = start
            fromDay = named
            place = { GCalDateTime(dateTime: nil, date: $0.description, timeZone: nil) }
        } else {
            guard let zone = pattern.zone, let start = pattern.start.dateTime.flatMap(Date.fromISO8601),
                  let named = namedStart.dateTime.flatMap(Date.fromISO8601) else { return nil }
            let wall = naive(start, in: zone)
            guard let startDay = RecurrenceTail.Day(iso: wall), let namedDay = RecurrenceTail.Day(iso: naive(named, in: zone)) else { return nil }
            seriesDay = startDay
            fromDay = namedDay
            let time = String(wall.dropFirst(11))
            place = { day in
                GoogleCalendarProvider.naiveInstant("\(day)T\(time)", zone: zone)
                    .map { GCalDateTime(dateTime: $0.iso8601String(), date: nil, timeZone: "UTC") }
            }
        }
        var day = fromDay
        while true {
            switch RecurrenceTail.firstDay(of: pattern.rule, seriesStart: seriesDay, onOrAfter: day, anchor: pattern.anchor, missingDay: pattern.missingDay) {
            case .unsupported: return nil
            case .none: return .pastEnd
            case .day(let found):
                guard let at = place(found), let after = isInTail(at, split: namedStart) else { return nil }
                guard after else { day = found.adding(days: 1); continue }
                if let count {
                    guard let before = RecurrenceTail.occurrences(
                        of: pattern.rule, seriesStart: seriesDay, before: found, anchor: pattern.anchor, missingDay: pattern.missingDay)
                    else { return nil }
                    if before >= count { return .pastEnd }
                }
                if let until {
                    guard let ends = endsBefore(at, until: until, zone: pattern.zone) else { return nil }
                    if ends { return .pastEnd }
                }
                return .at(at)
            }
        }
    }

    /// Whether an `UNTIL` value ends the series before `place`: a UTC date-time compares by
    /// instant; any other is a wall clock in the series' zone (`zone`, nil for an all-day series),
    /// so `place` is read in that zone: a local date-time compares by wall clock, a date by date (a
    /// date `UNTIL` takes in its whole day). Nil when unreadable.
    private static func endsBefore(_ place: GCalDateTime, until: String, zone: TimeZone?) -> Bool? {
        if until.hasSuffix("Z"), until.count == 16, let instant = place.dateTime.flatMap(Date.fromISO8601) {
            guard let end = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss'Z'", timeZone: .gmt).date(from: until) else { return nil }
            return end < instant
        }
        guard let untilDay = RecurrenceTail.Day(ical: until) else { return nil }
        if let date = place.date {
            guard let placeDay = RecurrenceTail.Day(iso: date) else { return nil }
            return untilDay < placeDay
        }
        guard let zone, let instant = place.dateTime.flatMap(Date.fromISO8601) else { return nil }
        let wall = naive(instant, in: zone)
        guard let placeDay = RecurrenceTail.Day(iso: wall) else { return nil }
        guard until.count == 15, until.dropFirst(8).first == "T" else { return untilDay < placeDay }
        // A local date-time: the same wall clock form, compared as text.
        let untilWall = "\(untilDay)T\(until.dropFirst(9).prefix(2)):\(until.dropFirst(11).prefix(2)):\(until.dropFirst(13).prefix(2))"
        return untilWall < wall
    }

    /// The exceptions of a series sorted by calendar order around a split (`partition`).
    struct Parts {
        /// Placed at or after the cut and shown at or after the occurrence named: carried or reset
        /// as the split's mode says (`plan`).
        var tail: [Exception] = []
        /// Placed at or after the cut but shown before the occurrence named: carried into the new
        /// part WHOLE, the fields the edit set included, in either mode, so they keep what they
        /// show (`plan`'s `kept`).
        var kept: [GCalEvent] = []
        /// Placed before the cut (or anywhere, with no cut) but shown at or after the occurrence
        /// named (the occurrence named among them, when it was moved later): edited where they
        /// are, on the old series (`edits`).
        var edited: [GCalEvent] = []
    }

    /// `exceptions` (every one the series holds, wherever it is placed) sorted around a split cut
    /// at `cut` and named at an occurrence that starts at `namedStart`. A deleted occurrence goes
    /// by its place; one placed before the cut and shown before the named one is not touched.
    /// Nil when a place or start can't be read.
    static func partition(_ exceptions: [Exception], cut: Cut, namedStart: GCalDateTime) -> Parts? {
        var parts = Parts()
        for exception in exceptions {
            guard let place = exception.place else { return nil }
            let placedAfter: Bool
            switch cut {
            case .pastEnd: placedAfter = false
            case .at(let at):
                guard let after = isInTail(place, split: at) else { return nil }
                placedAfter = after
            }
            switch exception {
            case .deleted:
                if placedAfter { parts.tail.append(exception) }
            case .changed(let event):
                guard let start = event.start, let shownAfter = isInTail(start, split: namedStart) else { return nil }
                switch (placedAfter, shownAfter) {
                case (true, true): parts.tail.append(exception)
                case (true, false): parts.kept.append(event)
                case (false, true): parts.edited.append(event)
                case (false, false): break
                }
            }
        }
        return parts
    }

    /// What an edit writes onto one occurrence it changes where it is: the fields the edit set,
    /// and its own times (`start`, `end`, absolute) when the edit moves or ends it.
    struct Edit {
        let exception: GCalEvent
        let start: GCalDateTime?
        let end: GCalDateTime?
    }

    /// The writes of an edit onto `occurrences` where they are: each moved by `shift` (the new
    /// start given less the named occurrence's start), and, when the edit set the end, lasting
    /// `length` (the new part's) from its new start. Nil when a time can't be read, or when there is
    /// an occurrence to edit and no `shift`: a new part of the other kind (a change between all-day
    /// and timed) gives none (`shift(cut:newPart:)`), and needs none when nothing moves with it.
    static func edits(of occurrences: [GCalEvent], shift: TimeInterval?, length: TimeInterval?, fields: Set<Field>) -> [Edit]? {
        var out: [Edit] = []
        for event in occurrences {
            guard let shift, let start = event.start, let end = event.end else { return nil }
            guard shift != 0 || fields.contains(.end) else {
                out.append(Edit(exception: event, start: nil, end: nil))
                continue
            }
            guard let movedStart = adding(shift, to: start) else { return nil }
            let movedEnd: GCalDateTime?
            if fields.contains(.end) {
                guard let length else { return nil }
                movedEnd = adding(length, to: movedStart)
            } else {
                movedEnd = adding(shift, to: end)
            }
            guard let movedEnd else { return nil }
            out.append(Edit(exception: event, start: movedStart, end: movedEnd))
        }
        return out
    }

    /// The values of the fields the edit set (`fields`, not the end), as `source` holds them: the
    /// new part once it is written, which a retry reads back, or the edit itself when the split
    /// writes no new part (`Cut.pastEnd`).
    static func values(of source: GCalEventInput, fields: Set<Field>) -> GCalEventInput {
        var input = GCalEventInput()
        if fields.contains(.summary) { input.summary = source.summary }
        if fields.contains(.location) { input.location = source.location }
        if fields.contains(.description) { input.description = source.description }
        if fields.contains(.transparency) { input.transparency = source.transparency }
        return input
    }

    /// `values(of:fields:)` read from the new part.
    static func values(of part: GCalEvent, fields: Set<Field>) -> GCalEventInput {
        var source = GCalEventInput()
        source.summary = part.summary
        source.location = part.location
        source.description = part.description
        source.transparency = part.transparency
        return values(of: source, fields: fields)
    }

    /// The one-occurrence write of `edit` (`edits`): `values`, the guests' change `guests`, and
    /// its times when it moves or ends elsewhere. The same input a "this occurrence" edit writes.
    static func input(for edit: Edit, values: GCalEventInput, guests: AttendeeChange?) -> GCalEventInput {
        var input = values
        input.attendeeChange = guests
        if let start = edit.start, let end = edit.end {
            input.startDate = start.date
            input.startDateTime = start.dateTime
            input.startTimeZone = start.timeZone
            input.endDate = end.date
            input.endDateTime = end.dateTime
            input.endTimeZone = end.timeZone
        }
        return input
    }

    /// The edits a retry writes onto `occurrences` (`Parts.edited` as the series holds them now):
    /// each to the start `targets` kept for its place (`SplitRecord.edits`), so one already
    /// written is not moved again. An occurrence with no target kept is not edited. Nil when a
    /// time can't be read.
    static func edits(of occurrences: [GCalEvent], targets: [String: String], length: TimeInterval?, fields: Set<Field>) -> [Edit]? {
        var out: [Edit] = []
        for event in occurrences {
            guard let place = event.originalStartTime.map(key), let target = targets[place] else { continue }
            guard let start = event.start else { return nil }
            var shift: TimeInterval = 0
            if !target.isEmpty {
                guard let to = time(target), let moved = seconds(from: start, to: to) else { return nil }
                shift = moved
            }
            guard let edit = edits(of: [event], shift: shift, length: length, fields: fields)?.first else { return nil }
            out.append(edit)
        }
        return out
    }

    /// The edits' targets a split keeps on its record (`SplitRecord.edits`): each edited
    /// occurrence's place (`key`) to the start it is moved to, or "" when it keeps its start.
    static func targets(of edits: [Edit]) -> [String: String] {
        var out: [String: String] = [:]
        for edit in edits {
            guard let place = edit.exception.originalStartTime else { continue }
            out[key(place)] = edit.start.map(key) ?? ""
        }
        return out
    }

    /// A place or start as a record keeps it: its instant (ISO 8601, UTC) or its date.
    static func key(_ time: GCalDateTime) -> String {
        if let date = time.date { return String(date.prefix(10)) }
        return time.dateTime.flatMap(Date.fromISO8601)?.iso8601String() ?? (time.dateTime ?? "")
    }

    /// The place or start a record keeps (`key`).
    static func time(_ key: String) -> GCalDateTime? {
        if key.contains("T") {
            guard Date.fromISO8601(key) != nil else { return nil }
            return GCalDateTime(dateTime: key, date: nil, timeZone: "UTC")
        }
        return day(key) != nil ? GCalDateTime(dateTime: nil, date: key, timeZone: nil) : nil
    }

    /// The time from `from` to `to`: seconds, or whole days in seconds for dates.
    private static func seconds(from: GCalDateTime, to: GCalDateTime) -> TimeInterval? {
        if let a = from.date.flatMap(day), let b = to.date.flatMap(day) { return b.timeIntervalSince(a) }
        guard let a = from.dateTime.flatMap(Date.fromISO8601), let b = to.dateTime.flatMap(Date.fromISO8601) else { return nil }
        return b.timeIntervalSince(a)
    }

    /// How far `edit` moves the occurrence that starts at `start`, and how long it then lasts when
    /// the edit gives an end. Nil when a time can't be read.
    static func moved(by edit: GCalEventInput, start: GCalDateTime) -> (shift: TimeInterval, length: TimeInterval?)? {
        var shift: TimeInterval = 0
        if let given = edit.startDate ?? edit.startDateTime {
            let to = edit.startDate != nil
                ? GCalDateTime(dateTime: nil, date: given, timeZone: nil)
                : GCalDateTime(dateTime: given, date: nil, timeZone: edit.startTimeZone)
            guard let seconds = seconds(from: start, to: to) else { return nil }
            shift = seconds
        }
        guard let givenEnd = edit.endDate ?? edit.endDateTime else { return (shift, nil) }
        guard let newStart = adding(shift, to: start) else { return nil }
        let to = edit.endDate != nil
            ? GCalDateTime(dateTime: nil, date: givenEnd, timeZone: nil)
            : GCalDateTime(dateTime: givenEnd, date: nil, timeZone: edit.endTimeZone)
        guard let length = seconds(from: newStart, to: to) else { return nil }
        return (shift, length)
    }

    /// `occurrences` with the one placed at `place` (the occurrence named) last.
    static func namedLast(_ occurrences: [GCalEvent], place: GCalDateTime?) -> [GCalEvent] {
        guard let place else { return occurrences }
        let isNamed = { (event: GCalEvent) in event.originalStartTime.map(key) == key(place) }
        return occurrences.filter { !isNamed($0) } + occurrences.filter(isNamed)
    }

    /// An edit past the series' last place (`Cut.pastEnd`) named at `named` of the series
    /// `seriesId`, whose exceptions are `exceptions`: the edits of every occurrence shown from the
    /// one named on (`Parts.edited`), the one named last, each to an absolute target worked out
    /// once, and the record (`SplitRecord.pastEnd`) that keeps those targets for a retry
    /// (`shownEdits(exceptions:record:)`). Nil when a time can't be read.
    static func shownEdits(
        exceptions: [Exception], named: GCalEvent, seriesId: String, patch: GCalEventInput
    ) -> (record: SplitRecord, edits: [Edit])? {
        let fields = fields(of: patch)
        guard let namedId = named.id, let namedStart = named.start, let namedPlace = named.originalStartTime,
              let parts = partition(exceptions, cut: .pastEnd, namedStart: namedStart),
              let moved = moved(by: patch, start: namedStart),
              let edits = edits(of: namedLast(parts.edited, place: namedPlace), shift: moved.shift, length: moved.length, fields: fields)
        else { return nil }
        let record = SplitRecord.pastEnd(
            seriesId: seriesId, namedId: namedId, fields: fields, namedPlace: key(namedPlace), namedStart: key(namedStart),
            edits: targets(of: edits), editLength: fields.contains(.end) ? moved.length : nil)
        return (record, edits)
    }

    /// The edits a retry of an edit past the series' last place writes (`record`, kept by
    /// `shownEdits(exceptions:named:seriesId:patch:)`): each occurrence still shown from where the
    /// one named started then, to the target the record keeps for its place, the one named last.
    /// One already written is written to where it is. Nil when a time can't be read.
    static func shownEdits(exceptions: [Exception], record: SplitRecord) -> [Edit]? {
        guard let namedStart = record.namedStart.flatMap(time),
              let parts = partition(exceptions, cut: .pastEnd, namedStart: namedStart) else { return nil }
        let ordered = namedLast(parts.edited, place: record.namedPlace.flatMap(time))
        return edits(of: ordered, targets: record.edits, length: record.editLength, fields: record.fields)
    }

    /// The occurrence named, when the split places it in the new part (`Parts.tail`): found by
    /// its place.
    static func named(in parts: Parts, place: GCalDateTime) -> GCalEvent? {
        for exception in parts.tail {
            guard case .changed(let event) = exception, let at = event.originalStartTime else { continue }
            if key(at) == key(place) { return event }
        }
        return nil
    }

    /// The shift a new part's start gives: from `cut` to where the new part starts. Zero when the
    /// new part starts at its cut; nil when it can't be read, or the new part is of the other kind
    /// (a date against an instant), which no shift spans.
    static func shift(cut: GCalDateTime, newPart: GCalEvent) -> TimeInterval? {
        guard let start = newPart.start else { return nil }
        if let date = cut.date {
            guard let from = day(date), let to = start.date.flatMap(day) else { return nil }
            return to.timeIntervalSince(from)
        }
        guard let from = cut.dateTime.flatMap(Date.fromISO8601), let to = start.dateTime.flatMap(Date.fromISO8601) else { return nil }
        return to.timeIntervalSince(from)
    }

    /// Whether `place` is at or after the split at `split`: instants for a timed series, dates for
    /// an all-day one. Nil when either can't be read.
    static func isInTail(_ place: GCalDateTime, split: GCalDateTime) -> Bool? {
        if let date = place.date, let at = split.date { return String(date.prefix(10)) >= String(at.prefix(10)) }
        guard let instant = place.dateTime.flatMap(Date.fromISO8601),
              let at = split.dateTime.flatMap(Date.fromISO8601) else { return nil }
        return instant >= at
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
        FixedDateFormat.formatter("yyyy-MM-dd", timeZone: .gmt).date(from: String(text.prefix(10)))
    }

    private static func dayString(_ date: Date) -> String {
        FixedDateFormat.formatter("yyyy-MM-dd", timeZone: .gmt).string(from: date)
    }
}
