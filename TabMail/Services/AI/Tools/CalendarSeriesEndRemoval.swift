/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// What an edit of every occurrence that moves a repeating series' last date earlier removes, for
/// its confirmation card (#718): `count` meetings after `after`, the new last date as the card
/// shows it. `count` is nil for a series that had no end: every meeting after `after` goes.
struct SeriesEndRemoval: Sendable, Equatable {
    let count: Int?
    let after: String
}

/// The count behind the card's "N meetings after <date> are removed." line, one function for every
/// calendar (#718, above the provider boundary, ADR-IOS-060). It is worked out FROM THE STORED
/// RULE, never from a listing: the occurrences the series' rule places after the new last date
/// and up to its stored end (`RecurrenceTail`, the in-house expander, in the series' zone), less
/// the ones deleted one by one (the series' `EXDATE` lines, and the places its calendar gives,
/// `CalendarProvider.deletedOccurrencePlaces`). An occurrence changed on its own counts at the
/// place the rule gives it, wherever it was moved. It never names which calendar it is.
enum CalendarSeriesEndRemoval {

    /// Why the count can't be worked out: the card is not shown (fails closed), never a 0.
    struct Unreadable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// What the whole-series edit `edit` of `series` (`seriesId`, read on `calendarId`) removes by
    /// ending the series earlier, nil when it does not end it earlier: the edit's rule ends on a
    /// date (`UNTIL`) or after a number of occurrences (`COUNT`) before the stored rule's last
    /// occurrence, or the stored rule has no end and the edit gives it one. Dates are read in the
    /// series' zone (`GCalEvent.seriesZone`; an all-day series by its dates). Counted with the
    /// conventions the series' calendar repeats it by (`recurrenceAnchor`, `recurrenceMissingDay`,
    /// `recurrenceFirstDayOfWeek`); an occurrence the stored rule places that was deleted is not
    /// counted, and an `EXDATE` still counts toward a `COUNT` (RFC 5545).
    ///
    /// An edit whose end is decided from the two rules alone to be no earlier (`mayEndEarlier`: the
    /// stored end re-sent, or a later one) is nil before anything else is read, so a rename that
    /// re-sends the rule never fails on what the count would need. Otherwise it throws `Unreadable`
    /// when the stored rule, the series' first date, its zone or the edit's end can't be read or
    /// expanded, and rethrows when the deleted occurrences can't be read.
    static func removal(
        series: GCalEvent, seriesId: String, edit: GCalEventInput, calendarId: String, provider: any CalendarProvider
    ) async throws -> SeriesEndRemoval? {
        // Only a rule that gives an end can end the series earlier.
        guard let editedRule = rule(in: edit.recurrence),
              RecurrenceTail.withoutEnd(editedRule) != String(editedRule.dropFirst("RRULE:".count)) else { return nil }
        guard let storedLine = rule(in: series.recurrence) else {
            throw Unreadable(reason: "the repeating event's stored rule can't be read")
        }
        guard mayEndEarlier(stored: storedLine, edited: editedRule) else { return nil }
        // Dates added to the series (`RDATE`) are not counted from the rule: refused rather than
        // missed.
        guard !(series.recurrence ?? []).contains(where: { $0.uppercased().hasPrefix("RDATE") }) else {
            throw Unreadable(reason: "the repeating event has dates added to its rule, which this count does not read")
        }
        let zone: TimeZone
        if series.isAllDay {
            zone = .gmt
        } else {
            guard let seriesZone = series.seriesZone else {
                throw Unreadable(reason: "the time zone the repeating event repeats in can't be read")
            }
            zone = seriesZone
        }
        guard let start = series.start, let firstDay = day(of: start, zone: zone) else {
            throw Unreadable(reason: "the repeating event's first date can't be read")
        }
        let pattern = countedRule(storedLine, series: series)
        let anchor = series.recurrenceAnchor ?? .dtstart
        let missingDay = series.recurrenceMissingDay ?? .skip
        guard RecurrenceTail.Rule(pattern, missingDay: missingDay) != nil else {
            throw Unreadable(reason: "the repeating event's stored rule can't be expanded")
        }
        let counter = Counter(pattern: pattern, firstDay: firstDay, anchor: anchor, missingDay: missingDay)

        // The new last date: the edit's UNTIL, or the day of its COUNT-th occurrence
        // (`RecurrenceTail.lastDay`, the reading the CalDAV write uses too).
        let newLast: RecurrenceTail.Day
        switch RecurrenceTail.lastDay(of: countedRule(editedRule, series: series), seriesStart: firstDay, zone: zone,
                                      anchor: anchor, missingDay: missingDay) {
        case .day(let day): newLast = day
        case .none: return nil
        case .unreadable: throw Unreadable(reason: "the new last date of the repeating event can't be read")
        }
        guard let newLastDate = FixedDateFormat.formatter("yyyy-MM-dd", timeZone: .gmt).date(from: newLast.description) else {
            throw Unreadable(reason: "the new last date of the repeating event can't be read")
        }
        let after = FixedDateFormat.formatter("MMMM d, yyyy", timeZone: .gmt).string(from: newLastDate)

        // The stored end: an UNTIL's day, the COUNT-th occurrence's day, or none.
        let storedLast: RecurrenceTail.Day
        switch RecurrenceTail.lastDay(of: pattern, seriesStart: firstDay, zone: zone, anchor: anchor, missingDay: missingDay) {
        case .day(let day): storedLast = day
        case .none: return SeriesEndRemoval(count: nil, after: after)
        case .unreadable: throw Unreadable(reason: "the repeating event's stored end can't be read")
        }
        guard newLast < storedLast else { return nil }

        // Every occurrence the rule places after the new last date, up to the stored last one.
        let placed = try counter.count(before: storedLast.adding(days: 1)) - counter.count(before: newLast.adding(days: 1))
        // Less the ones deleted one by one, each once, where the rule places one.
        var deleted = try exdateDays(series.recurrence, zone: zone)
        for place in try await provider.deletedOccurrencePlaces(calendarId: calendarId, seriesId: seriesId, series: series) {
            guard let day = day(of: place, zone: zone) else {
                throw Unreadable(reason: "an occurrence deleted from the repeating event has a date that can't be read")
            }
            deleted.insert(day)
        }
        var removedDeleted = 0
        for day in deleted where day > newLast && day <= storedLast && day >= firstDay {
            if try counter.count(before: day.adding(days: 1)) - counter.count(before: day) > 0 { removedDeleted += 1 }
        }
        return SeriesEndRemoval(count: max(0, placed - removedDeleted), after: after)
    }

    /// Whether the rule `edited` may end the series before the rule `stored` does, decided from the
    /// rules' text alone: false only when the edit keeps the stored pattern (every part but the
    /// end, as a set) and its end is provably no earlier: the same end, a `COUNT` no smaller, or an
    /// `UNTIL` no earlier in the same form (a date, a UTC time, a floating time: each compares by
    /// its digits). An `UNTIL` time in UTC after a stored date is no earlier once it is past that
    /// date's end in every zone (`untilAfterDayEverywhere`). True otherwise, and the count decides.
    static func mayEndEarlier(stored: String, edited: String) -> Bool {
        func parts(_ line: String) -> [String] {
            let body = line.uppercased().hasPrefix("RRULE:") ? String(line.dropFirst("RRULE:".count)) : line
            return body.uppercased().split(separator: ";").map(String.init)
        }
        func end(_ parts: [String], _ key: String) -> String? {
            parts.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        let was = parts(stored)
        let now = parts(edited)
        func pattern(_ parts: [String]) -> Set<String> { Set(parts.filter { !$0.hasPrefix("UNTIL=") && !$0.hasPrefix("COUNT=") }) }
        guard pattern(was) == pattern(now) else { return true }
        if let count = end(now, "COUNT").flatMap({ Int($0) }), let stored = end(was, "COUNT").flatMap({ Int($0) }) {
            return count < stored
        }
        guard let until = end(now, "UNTIL"), let storedUntil = end(was, "UNTIL") else { return true }
        func form(_ value: String) -> Int {
            switch (value.count, value.hasSuffix("Z")) {
            case (8, _): return 0
            case (16, true): return 1
            case (15, false): return 2
            default: return -1
            }
        }
        if form(until) >= 0, form(until) == form(storedUntil) { return until < storedUntil }
        if form(until) == 1, form(storedUntil) == 0 { return !untilAfterDayEverywhere(until, day: storedUntil) }
        return true
    }

    /// The farthest a zone's clock is behind UTC (`Etc/GMT+12`), in seconds.
    static let farthestZoneBehindUTC: TimeInterval = 12 * 3_600

    /// Whether the UTC time `until` (`YYYYMMDDTHHMMSSZ`) is at or after the last second of the date
    /// `day` (`YYYYMMDD`) in every zone, the one farthest behind UTC last: so the series' last day
    /// it gives is `day` or later wherever the series repeats, with that day's occurrence in it.
    private static func untilAfterDayEverywhere(_ until: String, day: String) -> Bool {
        guard let instant = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss'Z'", timeZone: .gmt).date(from: until),
              let lastSecond = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss", timeZone: .gmt).date(from: day + "T235959")
        else { return false }
        return instant >= lastSecond.addingTimeInterval(farthestZoneBehindUTC)
    }

    /// The occurrences a rule places, counted by `RecurrenceTail.occurrences`.
    private struct Counter {
        let pattern: String
        let firstDay: RecurrenceTail.Day
        let anchor: RecurrenceTail.Anchor
        let missingDay: RecurrenceTail.MissingMonthDay

        /// The occurrences on days before `day`.
        func count(before day: RecurrenceTail.Day) throws -> Int {
            guard let count = RecurrenceTail.occurrences(
                of: pattern, seriesStart: firstDay, before: day, anchor: anchor, missingDay: missingDay) else {
                throw Unreadable(reason: "the repeating event's stored rule can't be expanded")
            }
            return count
        }
    }

    /// The first `RRULE:` line of `lines`, nil when there is none.
    private static func rule(in lines: [String]?) -> String? {
        lines?.first(where: { $0.uppercased().hasPrefix("RRULE:") })
    }

    /// A rule as the counter reads it: with the series' first day of the week where its calendar
    /// keeps one apart from the rule (the counter places the pattern and reads no end;
    /// `RecurrenceTail.lastDay` reads the end).
    private static func countedRule(_ line: String, series: GCalEvent) -> String {
        var parts = line.dropFirst("RRULE:".count).split(separator: ";").map(String.init)
        let weekStarts = ["sunday": "SU", "monday": "MO", "tuesday": "TU", "wednesday": "WE",
                          "thursday": "TH", "friday": "FR", "saturday": "SA"]
        if !parts.contains(where: { $0.uppercased().hasPrefix("WKST=") }),
           let wkst = series.recurrenceFirstDayOfWeek.flatMap({ weekStarts[$0.lowercased()] }) {
            parts.append("WKST=\(wkst)")
        }
        return "RRULE:" + parts.joined(separator: ";")
    }


    /// The days the series' `EXDATE` lines take out, in `zone`: a date as written, a UTC time
    /// dated in `zone`, a time in a named zone (`TZID`) dated in `zone`, a floating time by its
    /// own date. Throws `Unreadable` for a value that can't be read.
    private static func exdateDays(_ lines: [String]?, zone: TimeZone) throws -> Set<RecurrenceTail.Day> {
        var days = Set<RecurrenceTail.Day>()
        for line in lines ?? [] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let params = line[..<colon].split(separator: ";").map(String.init)
            guard params.first?.uppercased() == "EXDATE" else { continue }
            let tzid = params.dropFirst().first(where: { $0.uppercased().hasPrefix("TZID=") }).map { String($0.dropFirst("TZID=".count)) }
            for value in line[line.index(after: colon)...].split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).uppercased() }) {
                let unreadable = Unreadable(reason: "a date excluded from the repeating event can't be read")
                if value.count == 8 {
                    guard let day = RecurrenceTail.Day(ical: value) else { throw unreadable }
                    days.insert(day)
                } else if value.hasSuffix("Z") {
                    guard let day = RecurrenceTail.untilDay(value, zone: zone) else { throw unreadable }
                    days.insert(day)
                } else if let tzid {
                    guard let named = CalendarTimeZoneResolver.zone(named: tzid, in: .none),
                          let instant = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss", timeZone: named).date(from: value),
                          let day = RecurrenceTail.Day(iso: FixedDateFormat.formatter("yyyy-MM-dd", timeZone: zone).string(from: instant))
                    else { throw unreadable }
                    days.insert(day)
                } else {
                    guard let day = RecurrenceTail.Day(ical: value) else { throw unreadable }
                    days.insert(day)
                }
            }
        }
        return days
    }

    /// The day `time` is on in `zone`: an all-day date as written, a timed instant dated there.
    private static func day(of time: GCalDateTime, zone: TimeZone) -> RecurrenceTail.Day? {
        if let date = time.date { return RecurrenceTail.Day(iso: date) }
        guard let instant = time.dateTime.flatMap(Date.fromISO8601) else { return nil }
        return RecurrenceTail.Day(iso: FixedDateFormat.formatter("yyyy-MM-dd", timeZone: zone).string(from: instant))
    }
}
