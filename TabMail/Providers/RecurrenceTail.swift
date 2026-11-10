/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The end a this-and-following split gives its NEW series.
///
/// A split caps the original series with an `UNTIL` just before the split
/// occurrence and starts a new series there. The new series has to end where
/// the original one ended:
///  - an `UNTIL` at or after the split is kept verbatim (it names the same
///    instant);
///  - `COUNT=N` becomes N minus the occurrences the original series keeps
///    before the split;
///  - a series with no end stays without one.
///
/// When the original series already ends before the split there is nothing to
/// move, so the split is refused, and it is refused before anything is written.
///
/// Counting follows RFC 5545 §3.3.10: DTSTART is always the first occurrence,
/// and occurrences removed by EXDATE still count toward COUNT. It works on whole
/// calendar days in the rule's own frame (DTSTART's zone, or UTC for a UTC
/// DTSTART): every occurrence of a supported rule has DTSTART's time of day, so
/// the day is enough to say whether it falls before the split.
enum RecurrenceTail {

    // MARK: - Days

    /// A calendar day in the rule's frame.
    struct Day: Comparable, Hashable, Sendable, CustomStringConvertible {
        let year: Int
        let month: Int
        let day: Int

        init?(year: Int, month: Int, day: Int) {
            guard (1...12).contains(month), day >= 1,
                  day <= RecurrenceTail.daysIn(month: month, year: year) else { return nil }
            self.year = year
            self.month = month
            self.day = day
        }

        /// The leading `yyyy-MM-dd` of a naive ISO 8601 value
        /// (`2026-05-20` or `2026-05-20T17:00:00`).
        init?(iso value: String) {
            let chars = Array(value.prefix(10))
            guard chars.count == 10, chars[4] == "-", chars[7] == "-",
                  let y = RecurrenceTail.number(chars[0..<4]),
                  let m = RecurrenceTail.number(chars[5..<7]),
                  let d = RecurrenceTail.number(chars[8..<10]) else { return nil }
            self.init(year: y, month: m, day: d)
        }

        /// The leading `yyyyMMdd` of an iCalendar DATE or DATE-TIME value
        /// (`20260520` or `20260520T170000Z`).
        init?(ical value: String) {
            let chars = Array(value.prefix(8))
            guard chars.count == 8,
                  let y = RecurrenceTail.number(chars[0..<4]),
                  let m = RecurrenceTail.number(chars[4..<6]),
                  let d = RecurrenceTail.number(chars[6..<8]) else { return nil }
            self.init(year: y, month: m, day: d)
        }

        fileprivate init(ordinal: Int) {
            let (y, m, d) = RecurrenceTail.civil(fromOrdinal: ordinal)
            self.year = y
            self.month = m
            self.day = d
        }

        /// Days since 1970-01-01, so day arithmetic is integer arithmetic.
        fileprivate var ordinal: Int { RecurrenceTail.ordinal(year: year, month: month, day: day) }

        fileprivate var weekday: Weekday { RecurrenceTail.weekday(ofOrdinal: ordinal) }

        static func < (lhs: Day, rhs: Day) -> Bool {
            (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
        }

        var description: String {
            String(format: "%04d-%02d-%02d", year, month, day)
        }
    }

    // MARK: - The new series' rule

    /// The RRULE for the new series of a split, given the original series'
    /// RRULE (with or without its `RRULE:` prefix).
    ///
    /// - `seriesStart`: the original series' DTSTART day, in the rule's frame.
    /// - `split`: the split occurrence's day, in the same frame.
    /// - `capUntil`: the `UNTIL` value this split caps the original series with.
    ///
    /// An `UNTIL` equal to `capUntil` is this split's own cap: the master was
    /// capped by an earlier attempt whose new series may or may not exist. The
    /// caller's duplicate check returns an existing new series; otherwise the new
    /// series gets no end, because the original end can no longer be read and
    /// refusing would retire the operation with the master capped and no
    /// successor.
    ///
    /// Throws `CalendarProviderError.notSupported` when the original series ends
    /// before the split, or when its end cannot be carried over (a COUNT this
    /// counter cannot expand, or a day it cannot place).
    static func newSeriesRule(
        from rrule: String,
        seriesStart: Day?,
        split: Day?,
        capUntil: String
    ) throws -> String {
        let prefix = "RRULE:"
        let body = rrule.hasPrefix(prefix) ? String(rrule.dropFirst(prefix.count)) : rrule
        let parts = body.split(separator: ";").map(String.init)
        let untils = parts.filter { $0.uppercased().hasPrefix("UNTIL=") }
        let counts = parts.filter { $0.uppercased().hasPrefix("COUNT=") }
        let openEnded = prefix + parts
            .filter { !$0.uppercased().hasPrefix("UNTIL=") && !$0.uppercased().hasPrefix("COUNT=") }
            .joined(separator: ";")
        let splitText = split.map { "the occurrence on \($0)" } ?? "the chosen occurrence"

        switch (untils.count, counts.count) {
        case (0, 0):
            return openEnded

        case (1, 0):
            let until = String(untils[0].dropFirst("UNTIL=".count)).uppercased()
            if until == capUntil.uppercased() { return openEnded }
            guard let endsBefore = untilIsBeforeSplit(until, split: split, capUntil: capUntil) else {
                throw CalendarProviderError.notSupported(
                    "Can't split this series: its repeat rule ends on \(until), which can't be compared with \(splitText). Edit the whole series instead.")
            }
            if endsBefore {
                throw CalendarProviderError.notSupported(
                    "Can't split this series at \(splitText): the series already ends before it (UNTIL=\(until)), so there are no occurrences from that point on to change.")
            }
            return prefix + parts.joined(separator: ";")

        case (0, 1):
            guard let count = Int(counts[0].dropFirst("COUNT=".count)), count >= 1 else {
                throw CalendarProviderError.notSupported(
                    "Can't split this series: its repeat rule has an invalid COUNT (\(counts[0])).")
            }
            guard let seriesStart, let split else {
                throw CalendarProviderError.notSupported(
                    "Can't split this series: it ends after \(count) occurrences, and the dates of its first occurrence or of \(splitText) can't be read, so the new series' length can't be worked out. Edit the whole series instead.")
            }
            guard let before = occurrences(of: rrule, seriesStart: seriesStart, before: split) else {
                throw CalendarProviderError.notSupported(
                    "Can't split this series: it ends after \(count) occurrences, and its repeat rule (\(body)) is not one TabMail can count, so the new series' length can't be worked out. Edit the whole series instead.")
            }
            guard before < count else {
                throw CalendarProviderError.notSupported(
                    "Can't split this series at \(splitText): the series ends after \(count) occurrences, all before it, so there are no occurrences from that point on to change.")
            }
            let remaining = count - before
            return prefix + parts
                .map { $0.uppercased().hasPrefix("COUNT=") ? "COUNT=\(remaining)" : $0 }
                .joined(separator: ";")

        default:
            throw CalendarProviderError.notSupported(
                "Can't split this series: its repeat rule (\(body)) has more than one end (UNTIL/COUNT).")
        }
    }

    /// Whether an `UNTIL` value ends the series before the split occurrence.
    /// nil when it cannot be decided.
    ///
    /// Two UTC date-times compare exactly: the cap is one second before the
    /// split instant, so an `UNTIL` earlier than the cap is earlier than the
    /// split. Any other pairing compares whole days, and a DATE `UNTIL` is
    /// inclusive of its whole day, so it is before the split only when its day
    /// is earlier than the split's.
    static func untilIsBeforeSplit(_ until: String, split: Day?, capUntil: String) -> Bool? {
        let until = until.uppercased()
        let cap = capUntil.uppercased()
        if isUTCDateTime(until), isUTCDateTime(cap) { return until < cap }
        guard let untilDay = Day(ical: until), let split else { return nil }
        return untilDay < split
    }

    // MARK: - Counting

    /// The number of occurrences the rule generates on days from `seriesStart`
    /// up to, but not including, `before`. DTSTART counts as the first.
    /// COUNT and UNTIL are ignored: this counts what the pattern generates.
    ///
    /// Returns nil for a rule outside the supported subset:
    /// FREQ DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, BYMONTH, BYMONTHDAY,
    /// BYDAY, WKST, and BYSETPOS (MONTHLY, or YEARLY with BYMONTH, over a plain
    /// BYDAY set). BYWEEKNO, BYYEARDAY, BYHOUR/BYMINUTE/BYSECOND, FREQ below
    /// DAILY and unknown parts are not supported, nor are BYMONTHDAY with
    /// WEEKLY, a numbered BYDAY with DAILY or WEEKLY or alongside BYMONTHDAY,
    /// and any other BYSETPOS.
    static func occurrences(of rrule: String, seriesStart: Day, before split: Day) -> Int? {
        guard let rule = Rule(rrule) else { return nil }
        guard seriesStart < split else { return 0 }
        let first = seriesStart.ordinal
        let end = split.ordinal
        var count = 1  // DTSTART
        for days in rule.periods(from: seriesStart, before: split) {
            count += days.filter { $0 > first && $0 < end }.count
        }
        return count
    }

    // MARK: - Rule

    enum Weekday: Int, CaseIterable, Sendable {
        case mo = 0, tu, we, th, fr, sa, su

        init?(code: String) {
            switch code {
            case "MO": self = .mo
            case "TU": self = .tu
            case "WE": self = .we
            case "TH": self = .th
            case "FR": self = .fr
            case "SA": self = .sa
            case "SU": self = .su
            default: return nil
            }
        }
    }

    /// A BYDAY entry: a weekday, optionally numbered (`2TU`, `-1FR`).
    struct WeekdayNum: Hashable, Sendable {
        let ordinal: Int?
        let weekday: Weekday
    }

    /// The largest INTERVAL the counter accepts: the days four-digit years
    /// span (10000 years of at most 366 days). A larger step, in any unit,
    /// places no second occurrence before a split such a year can name, and
    /// the bound keeps every step of the counter's arithmetic far from
    /// overflow. A rule above it is not counted.
    static let maxInterval = 10_000 * 366

    /// The parts of an RRULE the counter expands.
    struct Rule: Sendable {
        enum Frequency: Sendable { case daily, weekly, monthly, yearly }

        let frequency: Frequency
        let interval: Int
        let byMonth: [Int]
        let byMonthDay: [Int]
        let byDay: [WeekdayNum]
        let bySetPos: [Int]
        let weekStart: Weekday

        /// nil for anything outside the supported subset (see `occurrences`).
        init?(_ rrule: String) {
            let prefix = "RRULE:"
            let body = rrule.hasPrefix(prefix) ? String(rrule.dropFirst(prefix.count)) : rrule
            var values: [String: String] = [:]
            for part in body.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { return nil }
                let name = pair[0].uppercased()
                guard values[name] == nil else { return nil }
                values[name] = pair[1].uppercased()
            }
            let known: Set<String> = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYMONTH", "BYMONTHDAY", "BYDAY", "BYSETPOS", "WKST"]
            guard Set(values.keys).isSubset(of: known) else { return nil }

            switch values["FREQ"] {
            case "DAILY": frequency = .daily
            case "WEEKLY": frequency = .weekly
            case "MONTHLY": frequency = .monthly
            case "YEARLY": frequency = .yearly
            default: return nil
            }

            if let text = values["INTERVAL"] {
                guard let n = Int(text), (1...RecurrenceTail.maxInterval).contains(n) else { return nil }
                interval = n
            } else {
                interval = 1
            }

            guard let months = RecurrenceTail.numbers(values["BYMONTH"], allowed: 1...12, signed: false),
                  let monthDays = RecurrenceTail.numbers(values["BYMONTHDAY"], allowed: 1...31, signed: true),
                  let setPositions = RecurrenceTail.numbers(values["BYSETPOS"], allowed: 1...366, signed: true)
            else { return nil }
            byMonth = months
            byMonthDay = monthDays
            bySetPos = setPositions

            var days: [WeekdayNum] = []
            if let text = values["BYDAY"] {
                for entry in text.split(separator: ",", omittingEmptySubsequences: false) {
                    guard let parsed = RecurrenceTail.weekdayNum(String(entry)) else { return nil }
                    days.append(parsed)
                }
            }
            byDay = days

            if let text = values["WKST"] {
                guard let wd = Weekday(code: text) else { return nil }
                weekStart = wd
            } else {
                weekStart = .mo
            }

            let numbered = byDay.contains { $0.ordinal != nil }
            if frequency == .weekly, !byMonthDay.isEmpty { return nil }
            if numbered, frequency == .daily || frequency == .weekly { return nil }
            if numbered, !byMonthDay.isEmpty { return nil }
            if !bySetPos.isEmpty {
                let setPosShape = (frequency == .monthly || (frequency == .yearly && !byMonth.isEmpty))
                    && !byDay.isEmpty && !numbered && byMonthDay.isEmpty
                guard setPosShape else { return nil }
            }
        }

        /// The occurrence days (as ordinals) of every period the rule visits,
        /// from DTSTART's period to the last one that starts before `split`.
        /// Days before DTSTART inside its own period are included here; the
        /// caller drops them.
        func periods(from start: Day, before split: Day) -> [[Int]] {
            let end = split.ordinal
            var out: [[Int]] = []
            switch frequency {
            case .daily:
                var o = start.ordinal
                while o < end {
                    if matchesLimits(Day(ordinal: o)) { out.append([o]) }
                    o += interval
                }
            case .weekly:
                let daysPerWeek = Weekday.allCases.count
                let offset = (start.weekday.rawValue - weekStart.rawValue + daysPerWeek) % daysPerWeek
                var weekFirst = start.ordinal - offset
                let wanted = byDay.isEmpty ? [start.weekday] : byDay.map(\.weekday)
                while weekFirst < end {
                    let days = (0..<daysPerWeek)
                        .map { weekFirst + $0 }
                        .filter { wanted.contains(RecurrenceTail.weekday(ofOrdinal: $0)) }
                        .filter { byMonth.isEmpty || byMonth.contains(Day(ordinal: $0).month) }
                    out.append(days)
                    weekFirst += daysPerWeek * interval
                }
            case .monthly:
                var (y, m) = (start.year, start.month)
                while let monthFirst = Day(year: y, month: m, day: 1), monthFirst.ordinal < end {
                    out.append(monthDays(year: y, month: m, start: start))
                    let next = m - 1 + interval
                    y += next / 12
                    m = next % 12 + 1
                }
            case .yearly:
                var y = start.year
                while let yearFirst = Day(year: y, month: 1, day: 1), yearFirst.ordinal < end {
                    out.append(yearDays(year: y, start: start))
                    y += interval
                }
            }
            return out
        }

        /// DAILY: BYMONTH, BYMONTHDAY and BYDAY each limit the day.
        private func matchesLimits(_ day: Day) -> Bool {
            if !byMonth.isEmpty, !byMonth.contains(day.month) { return false }
            if !byMonthDay.isEmpty,
               !RecurrenceTail.resolve(monthDays: byMonthDay, year: day.year, month: day.month).contains(day.day) {
                return false
            }
            if !byDay.isEmpty, !byDay.contains(where: { $0.weekday == day.weekday }) { return false }
            return true
        }

        /// MONTHLY: the month's days, then BYSETPOS over them.
        private func monthDays(year: Int, month: Int, start: Day) -> [Int] {
            if !byMonth.isEmpty, !byMonth.contains(month) { return [] }
            var days: [Int]
            if !byMonthDay.isEmpty {
                days = RecurrenceTail.resolve(monthDays: byMonthDay, year: year, month: month)
                    .compactMap { Day(year: year, month: month, day: $0)?.ordinal }
                if !byDay.isEmpty {
                    days = days.filter { o in byDay.contains { $0.weekday == RecurrenceTail.weekday(ofOrdinal: o) } }
                }
            } else if !byDay.isEmpty {
                days = byDay.flatMap { RecurrenceTail.days(of: $0, inMonth: month, year: year) }
            } else {
                days = Day(year: year, month: month, day: start.day).map { [$0.ordinal] } ?? []
            }
            return RecurrenceTail.applySetPos(bySetPos, to: days)
        }

        /// YEARLY: BYMONTH picks the months (BYDAY numbers count within the
        /// month); without it BYMONTHDAY spans every month and BYDAY numbers
        /// count within the year. With no BY parts, DTSTART's month and day.
        private func yearDays(year: Int, start: Day) -> [Int] {
            var days: [Int]
            if byMonthDay.isEmpty, byDay.isEmpty {
                let months = byMonth.isEmpty ? [start.month] : byMonth
                days = months.compactMap { Day(year: year, month: $0, day: start.day)?.ordinal }
            } else if !byMonthDay.isEmpty {
                let months = byMonth.isEmpty ? Array(1...12) : byMonth
                days = months.flatMap { m in
                    RecurrenceTail.resolve(monthDays: byMonthDay, year: year, month: m)
                        .compactMap { Day(year: year, month: m, day: $0)?.ordinal }
                }
                if !byDay.isEmpty {
                    days = days.filter { o in byDay.contains { $0.weekday == RecurrenceTail.weekday(ofOrdinal: o) } }
                }
            } else if !byMonth.isEmpty {
                days = byMonth.flatMap { m in byDay.flatMap { RecurrenceTail.days(of: $0, inMonth: m, year: year) } }
            } else {
                days = byDay.flatMap { RecurrenceTail.days(of: $0, inYear: year) }
            }
            return RecurrenceTail.applySetPos(bySetPos, to: days)
        }
    }

    // MARK: - Calendar arithmetic (proleptic Gregorian)

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// Days since 1970-01-01: H. Hinnant's `days_from_civil`
    /// (https://howardhinnant.github.io/date_algorithms.html), which counts in
    /// 400-year eras of 146097 days with March as the first month so the leap
    /// day falls at the end of the year.
    private static func ordinal(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The inverse of `ordinal(year:month:day:)` (Hinnant's `civil_from_days`).
    private static func civil(fromOrdinal ordinal: Int) -> (Int, Int, Int) {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// 1970-01-01 (ordinal 0) was a Thursday.
    fileprivate static func weekday(ofOrdinal ordinal: Int) -> Weekday {
        let count = Weekday.allCases.count
        let raw = ((Weekday.th.rawValue + ordinal) % count + count) % count
        return Weekday(rawValue: raw) ?? .mo
    }

    /// BYMONTHDAY values as days of the given month: negatives count from the
    /// end, and a day the month does not have is dropped.
    fileprivate static func resolve(monthDays: [Int], year: Int, month: Int) -> [Int] {
        let length = daysIn(month: month, year: year)
        let days = monthDays.map { $0 > 0 ? $0 : length + 1 + $0 }.filter { (1...length).contains($0) }
        return Array(Set(days)).sorted()
    }

    /// The days a BYDAY entry names within a month.
    fileprivate static func days(of entry: WeekdayNum, inMonth month: Int, year: Int) -> [Int] {
        guard let first = Day(year: year, month: month, day: 1) else { return [] }
        return pick(entry, from: first.ordinal, count: daysIn(month: month, year: year))
    }

    /// The days a BYDAY entry names within a year.
    fileprivate static func days(of entry: WeekdayNum, inYear year: Int) -> [Int] {
        guard let first = Day(year: year, month: 1, day: 1),
              let next = Day(year: year + 1, month: 1, day: 1) else { return [] }
        return pick(entry, from: first.ordinal, count: next.ordinal - first.ordinal)
    }

    /// Every matching weekday in the span, or only the numbered one
    /// (from the start for `n`, from the end for `-n`).
    private static func pick(_ entry: WeekdayNum, from first: Int, count: Int) -> [Int] {
        let matches = (0..<count).map { first + $0 }.filter { weekday(ofOrdinal: $0) == entry.weekday }
        guard let n = entry.ordinal else { return matches }
        let index = n > 0 ? n - 1 : matches.count + n
        return matches.indices.contains(index) ? [matches[index]] : []
    }

    /// BYSETPOS over a period's sorted, de-duplicated days.
    fileprivate static func applySetPos(_ positions: [Int], to days: [Int]) -> [Int] {
        let sorted = Array(Set(days)).sorted()
        guard !positions.isEmpty else { return sorted }
        let picked = positions.compactMap { p -> Int? in
            let index = p > 0 ? p - 1 : sorted.count + p
            return sorted.indices.contains(index) ? sorted[index] : nil
        }
        return Array(Set(picked)).sorted()
    }

    // MARK: - Parsing

    /// `yyyyMMddTHHmmssZ`.
    private static func isUTCDateTime(_ value: String) -> Bool {
        let chars = Array(value)
        guard chars.count == 16, chars[8] == "T", chars[15] == "Z" else { return false }
        return chars[0..<8].allSatisfy(\.isASCIIDigit) && chars[9..<15].allSatisfy(\.isASCIIDigit)
    }

    fileprivate static func number(_ chars: ArraySlice<Character>) -> Int? {
        guard !chars.isEmpty, chars.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(String(chars))
    }

    /// A comma-separated list of non-zero integers whose magnitude is in
    /// `allowed`; an absent part is an empty list. nil when malformed.
    /// The magnitude is compared as `UInt`: `abs` traps on `Int.min`.
    fileprivate static func numbers(_ text: String?, allowed: ClosedRange<UInt>, signed: Bool) -> [Int]? {
        guard let text else { return [] }
        var out: [Int] = []
        for item in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard let n = Int(item), allowed.contains(n.magnitude), signed || n > 0 else { return nil }
            out.append(n)
        }
        return out
    }

    /// `MO`, `2TU`, `+1WE`, `-1FR`. The number may be ±1…53.
    fileprivate static func weekdayNum(_ text: String) -> WeekdayNum? {
        guard text.count >= 2, let weekday = Weekday(code: String(text.suffix(2))) else { return nil }
        let numberText = String(text.dropLast(2))
        if numberText.isEmpty { return WeekdayNum(ordinal: nil, weekday: weekday) }
        let maxWeekNumber: UInt = 53
        guard let n = Int(numberText), n != 0, n.magnitude <= maxWeekNumber else { return nil }
        return WeekdayNum(ordinal: n, weekday: weekday)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
