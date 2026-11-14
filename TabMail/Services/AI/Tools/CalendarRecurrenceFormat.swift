import Foundation

/// One recurrence format for the calendar tools (#552, the Thunderbird add-on's format):
/// the read tools show a stored repeat rule in the fields `calendar_event_create` and
/// `calendar_event_edit` take, so the assistant can pass back exactly what it read:
///
///     recurrence: {"freq":"WEEKLY","byDay":["MO","WE"],"until":"2099-12-31"}
///
/// - Only the fields the rule states, in a fixed order; `interval` is left out when it is 1 and
///   `wkst` when it is MO (the writer leaves both out too).
/// - `until` is a plain date: the day the series' last occurrence falls on, in the zone the
///   read output prints its times in (`untilDay`), so the edit tool, which reads a plain-date
///   `until` as the end of that day in the edit's `timezone` (default the device's), keeps exactly
///   the same occurrences when it is written back. Where that day would not (near a clock
///   change), it is the last occurrence's instant in UTC.
/// - `BYDAY=TU;BYSETPOS=2` folds to `"byDay":["2TU"]` where RFC 5545 makes the two the same
///   (`foldedSetPosition`).
/// - Every part the fields cannot express goes to `other`, and the read line adds
///   `otherPartsNote`; an edit that gives a rule for such a series is refused before the card
///   (`storedOtherRefusal`), as restating it would drop those parts.
enum CalendarRecurrenceFormat {
    /// What the read line adds after a rule with `other` parts (the Thunderbird add-on's words).
    static let otherPartsNote = "the edit tool cannot express these; omit recurrence to keep the rule"

    /// The frequencies the tools write.
    static let writableFreqs: Set<String> = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"]

    /// A stored rule in the tools' fields.
    struct Fields: Equatable {
        var freq: String?
        var interval: Int?
        var count: Int?
        var until: String?
        var byDay: [String]?
        var byMonthDay: [Int]?
        var byMonth: [Int]?
        var wkst: String?
        /// The stored parts the fields cannot express, as stored (`BYSETPOS=2`, `RRULE:<value>` for
        /// a further rule), in the order met.
        var other: [String] = []

        /// The fields as one compact JSON object, in the tools' field order, `other` joined by `;`.
        var json: String {
            var members: [String] = []
            func add(_ key: String, _ value: String) { members.append("\"\(key)\":\(value)") }
            if let freq { add("freq", CalendarRecurrenceFormat.jsonString(freq)) }
            if let interval { add("interval", String(interval)) }
            if let count { add("count", String(count)) }
            if let until { add("until", CalendarRecurrenceFormat.jsonString(until)) }
            if let byDay { add("byDay", "[" + byDay.map(CalendarRecurrenceFormat.jsonString).joined(separator: ",") + "]") }
            if let byMonthDay { add("byMonthDay", "[" + byMonthDay.map(String.init).joined(separator: ",") + "]") }
            if let byMonth { add("byMonth", "[" + byMonth.map(String.init).joined(separator: ",") + "]") }
            if let wkst { add("wkst", CalendarRecurrenceFormat.jsonString(wkst)) }
            if !other.isEmpty { add("other", CalendarRecurrenceFormat.jsonString(other.joined(separator: ";"))) }
            return "{" + members.joined(separator: ",") + "}"
        }
    }

    /// `calendar_event_read`'s line for a rule: `recurrence: {...}`, with `otherPartsNote` after a
    /// rule that has `other` parts.
    static func readLine(_ fields: Fields) -> String {
        let line = "recurrence: \(fields.json)"
        return fields.other.isEmpty ? line : "\(line) (\(otherPartsNote))"
    }

    /// The rule of a series in the tools' fields, or nil when `recurrence` has no `RRULE` line.
    ///
    /// `recurrence` is the stored lines (`GCalEvent.recurrence`: the series' own, or an occurrence
    /// row's copy of them); its first `RRULE` line is the rule the fields describe, and any further
    /// one goes to `other`. EXDATE and RDATE lines are not part of the rule: every writer keeps
    /// them on a rule write. `series` gives the start the rule repeats from and its zone: the
    /// series itself, or an occurrence row of it whose `originalStartTime` is its place in the
    /// series. `zone` is the zone the output prints its times in (`untilDay`).
    static func fields(_ recurrence: [String]?, series: GCalEvent, zone: TimeZone) -> Fields? {
        let rules = (recurrence ?? []).filter(isRuleLine)
        guard let first = rules.first else { return nil }
        var parts: [(key: String, value: String, raw: String)] = []
        for raw in first.dropFirst("RRULE:".count).split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            let pair = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            parts.append((key: pair[0].uppercased(), value: pair.count == 2 ? pair[1].uppercased() : "", raw: raw))
        }
        let keys = Set(parts.map(\.key))
        let freqValue = parts.first(where: { $0.key == "FREQ" })?.value
        let fold = foldedSetPosition(parts.map { ($0.key, $0.value) })
        // `until` is the day of the last occurrence at the start's time of day; a rule that also
        // repeats at other times of day can end on another day, so its UNTIL stays in `other`. So
        // does one beside a COUNT, which the writer writes in its place.
        let oneTimeOfDay = freqValue.map(writableFreqs.contains) == true && keys.isDisjoint(with: ["BYHOUR", "BYMINUTE", "BYSECOND", "COUNT"])
        let until = oneTimeOfDay ? parts.first(where: { $0.key == "UNTIL" }).flatMap { untilDay($0.value, series: series, zone: zone) } : nil
        // A day field the writer takes with this rule's FREQ (`recurrenceDayParts`, which refuses a
        // numbered day outside MONTHLY and YEARLY, and days of the month with WEEKLY).
        func writes(_ key: String, _ value: JSONValue) -> Bool {
            (try? CalendarToolHelpers.recurrenceDayParts([key: value], freq: freqValue ?? "")) != nil
        }

        var f = Fields()
        var seen: Set<String> = []
        for part in parts {
            // A part given twice is not one field: the repeat stays as stored.
            guard seen.insert(part.key).inserted else {
                f.other.append(part.raw)
                continue
            }
            switch part.key {
            case "FREQ" where writableFreqs.contains(part.value):
                f.freq = part.value
            case "INTERVAL" where positiveNumber(part.value) != nil:
                if let n = positiveNumber(part.value), n > 1 { f.interval = n }
            case "COUNT" where positiveNumber(part.value) != nil:
                f.count = positiveNumber(part.value)
            case "UNTIL" where until != nil:
                f.until = until
            case "BYDAY" where fold != nil:
                f.byDay = fold.map { [$0] }
            case "BYSETPOS" where fold != nil:
                continue
            case "BYDAY" where weekdays(part.value).map { writes("byDay", .array($0.map(JSONValue.string))) } == true:
                f.byDay = weekdays(part.value)
            case "BYMONTHDAY" where monthDays(part.value).map { writes("byMonthDay", .array($0.map(JSONValue.int))) } == true:
                f.byMonthDay = monthDays(part.value)
            case "BYMONTH" where months(part.value) != nil:
                f.byMonth = months(part.value)
            case "WKST" where CalendarToolHelpers.rruleWeekdays.contains(part.value):
                if part.value != "MO" { f.wkst = part.value }
            default:
                f.other.append(part.raw)
            }
        }
        for further in rules.dropFirst() { f.other.append(further) }
        return f
    }

    /// The `byDay` token a rule's single-position BYSETPOS folds to, or nil when it does not fold.
    ///
    /// RFC 5545 makes `BYDAY=TU;BYSETPOS=2` and `BYDAY=2TU` the same set of days when BYSETPOS
    /// picks from one weekday's days of a month: FREQ MONTHLY, or YEARLY with exactly one BYMONTH
    /// (a numbered BYDAY then counts within that month); exactly one weekday with no position of
    /// its own; exactly one position, which makes a valid `byDay` token; and no other part that
    /// selects days. With several weekdays BYSETPOS picks from their merged days ("the second
    /// Thursday or Friday"), which no `byDay` list says, so every other rule keeps BYSETPOS in
    /// `other`. Outlook's relative patterns are read this way (`ExchangeCalendarProvider.rrule`), so
    /// the fold is what lets "the second Tuesday of each month" be restated.
    ///
    /// iOS-only on purpose: the Thunderbird add-on keeps BYSETPOS in `other`, because Thunderbird
    /// 140 to 158 expand the two forms differently. iOS never runs that expander. Removing the
    /// call in `fields` is the whole of reverting to the add-on's choice.
    static func foldedSetPosition(_ parts: [(key: String, value: String)]) -> String? {
        let allowed: Set<String> = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYSETPOS", "BYMONTH", "WKST"]
        guard parts.allSatisfy({ allowed.contains($0.key) }) else { return nil }
        func values(_ key: String) -> [[String]] {
            parts.filter { $0.key == key }.map { $0.value.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        }
        let freq = values("FREQ")
        let byDay = values("BYDAY")
        let setPos = values("BYSETPOS")
        let byMonth = values("BYMONTH")
        guard freq.count == 1, byDay.count == 1, byDay[0].count == 1, setPos.count == 1, setPos[0].count == 1,
              let day = CalendarToolHelpers.RRuleWeekdayNum(byDay[0][0]), day.ordinal == nil,
              let position = Int(setPos[0][0]), position != 0 else { return nil }
        switch freq[0] {
        case ["MONTHLY"]: break
        case ["YEARLY"]: guard byMonth.count == 1, byMonth[0].count == 1 else { return nil }
        default: return nil
        }
        return CalendarToolHelpers.RRuleWeekdayNum("\(position)\(day.weekday)")?.token
    }

    /// A stored `UNTIL` as the plain date the tools take: the day the series' last occurrence falls
    /// on, in `zone`, the zone the read output prints its times in. Nil when that day can't be
    /// shown exactly; the caller then keeps the UNTIL in `other`.
    ///
    /// UNTIL is inclusive (RFC 5545 3.3.10). On an all-day series (by `originalStartTime ?? start`) the bound's date is the last
    /// day (a date-time bound by its UTC date, as RFC 5545 readers compare it).
    ///
    /// On a timed series the occurrences fall at the start's time of day in the series' own zone
    /// (`GCalEvent.seriesZone`), one a day at most (the caller passes only such rules). The last
    /// day `E` there is the bound's day when the occurrence slot on it is at or before the bound,
    /// else the day before, so a split's cap (one second before an occurrence) reads as the day
    /// before it. A UTC bound is that instant; a bare date (how Outlook's own range end is read,
    /// `ExchangeCalendarProvider.rrule`) is that day; a floating date-time is its wall time in the
    /// series' zone. The day shown is the date of `E`'s slot in `zone`.
    ///
    /// The series' zone is `GCalEvent.ruleZone` on CalDAV (where a start in UTC or floating names
    /// no zone), else `GCalEvent.seriesZone`.
    ///
    /// The day is shown when it round-trips: the bound the edit tool writes for it in `zone`
    /// (`CalendarToolHelpers.validatedRRuleUntil`, the end of that day) must keep `E`'s slot and not
    /// the next day's. Near a daylight-saving change it can fail (a last occurrence just after
    /// midnight on the day before the clocks change, read where that day's end falls past the next
    /// slot); the end is then shown as `E`'s slot itself, a UTC date-time (`2099-03-07T05:30:00Z`),
    /// which the edit tool writes unchanged, so writing it back keeps the same occurrences in any
    /// zone. Nil only when the stored bound can't be read or placed, or the series' zone is not
    /// known; the bound then stays in `other` and restating the rule is refused.
    ///
    /// `zone` is the one place the zone the date is shown in is chosen: the zone the output prints
    /// its times in, the user's day.
    static func untilDay(_ raw: String, series: GCalEvent, zone: TimeZone) -> String? {
        let value = raw.uppercased()
        let digits = { (s: Substring) in s.allSatisfy { $0.isASCII && $0.isNumber } }
        let chars = Array(value)
        let datePart = value.prefix(8)
        guard chars.count >= 8, digits(datePart),
              let y = Int(datePart.prefix(4)), let m = Int(datePart.dropFirst(4).prefix(2)), let d = Int(datePart.suffix(2)) else { return nil }
        var timePart: (h: Int, mi: Int, s: Int)?
        var isUTC = false
        switch chars.count {
        case 8: break
        case 15, 16:
            let t = value.dropFirst(9).prefix(6)
            guard chars[8] == "T", digits(t), chars.count == 15 || chars[15] == "Z",
                  let h = Int(t.prefix(2)), let mi = Int(t.dropFirst(2).prefix(2)), let s = Int(t.suffix(2)) else { return nil }
            timePart = (h, mi, s)
            isUTC = chars.count == 16
        default:
            return nil
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        func exact(_ cal: Calendar, _ c: DateComponents) -> Date? {
            guard let date = cal.date(from: c) else { return nil }
            let back = cal.dateComponents([.year, .month, .day], from: date)
            return back.year == c.year && back.month == c.month && back.day == c.day ? date : nil
        }

        // The series' kind, from its place in the series as the time of day below is: an occurrence
        // changed on its own can be of the other kind than its series.
        if (series.originalStartTime ?? series.start)?.date != nil {
            // All-day: the bound's own date (a date-time one at offset 0).
            guard let day = exact(utc, DateComponents(year: y, month: m, day: d)) else { return nil }
            return EKEventStoreHelper.dayKey(day, timeZone: .gmt)
        }

        guard let seriesZone = series.ruleZone ?? series.seriesZone,
              let startText = (series.originalStartTime ?? series.start)?.dateTime,
              let start = Date.fromISO8601(startText) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = seriesZone
        let time = cal.dateComponents([.hour, .minute, .second], from: start)
        // The occurrence slot on a day of the series' zone: the start's time of day there.
        func slot(_ day: Date) -> Date? {
            var c = cal.dateComponents([.year, .month, .day], from: day)
            c.hour = time.hour; c.minute = time.minute; c.second = time.second
            return cal.date(from: c)
        }
        func keepsOnly(_ last: Date, _ bound: Date) -> Bool {
            guard let at = slot(last), let nextDay = cal.date(byAdding: .day, value: 1, to: last), let next = slot(nextDay) else { return false }
            return at <= bound && bound < next
        }

        let last: Date
        if let timePart {
            let bound: Date?
            if isUTC {
                var c = DateComponents(year: y, month: m, day: d, hour: timePart.h, minute: timePart.mi, second: timePart.s)
                c.timeZone = .gmt
                bound = exact(utc, c)
            } else {
                bound = exact(cal, DateComponents(year: y, month: m, day: d, hour: timePart.h, minute: timePart.mi, second: timePart.s))
            }
            guard let bound else { return nil }
            let boundDay = cal.startOfDay(for: bound)
            guard let at = slot(boundDay) else { return nil }
            let candidate = at <= bound ? boundDay : cal.date(byAdding: .day, value: -1, to: boundDay)
            guard let candidate, keepsOnly(candidate, bound) else { return nil }
            last = candidate
        } else {
            guard let day = exact(cal, DateComponents(year: y, month: m, day: d)) else { return nil }
            last = day
        }
        guard let lastSlot = slot(last) else { return nil }
        let shown = EKEventStoreHelper.dayKey(lastSlot, timeZone: zone)
        // The bound the edit tool writes for `shown` must keep the same last occurrence; where it
        // does not, the last occurrence's own instant in UTC, which the edit tool writes as given.
        guard let written = CalendarToolHelpers.validatedRRuleUntil(shown, allDay: false, zone: zone),
              let writtenBound = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss'Z'", timeZone: .gmt).date(from: written),
              keepsOnly(last, writtenBound) else {
            return FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss'Z'", timeZone: .gmt).string(from: lastSlot)
        }
        return shown
    }

    /// Why an edit cannot give a rule for `series`, or nil: the stored rule has parts the fields
    /// cannot express (`Fields.other`), and a rule given in the fields would be written in their
    /// place, dropping them (the shared table's refusal, the Thunderbird add-on's words). Asked
    /// before the confirmation card for an edit that writes the series' rule (`edit_scope` "all"
    /// or `this_and_following`), in the edit's zone, the one its `until` is written in. An edit
    /// that gives no rule keeps the stored one and is not refused.
    static func storedOtherRefusal(_ arguments: [String: JSONValue], series: GCalEvent, zone: TimeZone) -> String? {
        guard case .dictionary(let rec) = arguments["recurrence"], (try? CalendarToolHelpers.recurrenceFreq(rec)) != nil,
              let stored = fields(series.recurrence, series: series, zone: zone), !stored.other.isEmpty else { return nil }
        return "this series repeats in a way the edit tool cannot express (\(stored.other.joined(separator: ";"))); omit recurrence to keep it, or change the repeat in the calendar app"
    }

    /// Whether a stored recurrence line is a rule (`RRULE:`).
    static func isRuleLine(_ line: String) -> Bool { line.uppercased().hasPrefix("RRULE:") }

    private static func positiveNumber(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(value), n >= 1 else { return nil }
        return n
    }

    /// A stored BYDAY as `byDay` tokens, read as the writer validates them; nil when any is not one.
    private static func weekdays(_ value: String) -> [String]? {
        tokens(value) { CalendarToolHelpers.RRuleWeekdayNum($0)?.token }
    }

    /// A stored BYMONTHDAY as `byMonthDay` (±1 to 31); nil when any value is outside it.
    private static func monthDays(_ value: String) -> [Int]? {
        tokens(value) { Int($0).flatMap { $0 != 0 && (-31...31).contains($0) ? $0 : nil } }
    }

    /// A stored BYMONTH as `byMonth` (1 to 12); nil when any value is outside it.
    private static func months(_ value: String) -> [Int]? {
        tokens(value) { Int($0).flatMap { (1...12).contains($0) ? $0 : nil } }
    }

    /// Every comma-separated token of `value` read by `read`, or nil when any of them does not read.
    private static func tokens<T>(_ value: String, _ read: (String) -> T?) -> [T]? {
        let raw = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !raw.isEmpty else { return nil }
        var out: [T] = []
        for token in raw {
            guard let t = read(token) else { return nil }
            out.append(t)
        }
        return out
    }

    private static func jsonString(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(s) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
