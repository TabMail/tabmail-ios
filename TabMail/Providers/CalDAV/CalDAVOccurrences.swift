/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The occurrences of a repeating CalDAV event, worked out on the device (ADR-IOS-108).
///
/// A CalDAV `calendar-query` returns each matching calendar object resource whole: a
/// repeating event comes back as its master VEVENT (DTSTART, RRULE, RDATE, EXDATE) plus one
/// VEVENT per changed or cancelled occurrence (RECURRENCE-ID). Google (`singleEvents=true`)
/// and Outlook (`calendarView`) return one row per occurrence, and the calendar tools are
/// built on that. This type turns a resource into those rows on the device, because the
/// server-side alternative (RFC 4791 `<C:expand>`) is optional, and where a server has it the
/// occurrences come back in UTC without the event's own zone (ADR-IOS-108).
///
/// The rows a listing gets:
/// - an event that does not repeat: one row, id = the resource href, as before;
/// - a repeating event: one row per occurrence that overlaps the range. Its id is the href,
///   `#` and the occurrence key (`OccurrenceId`), `recurringEventId` is the href, and
///   `recurrence` holds the series' rule lines, so every row carries the rule. A changed
///   occurrence is listed at its own time (moved into the range or out of it), with its own
///   fields; a cancelled one has status `cancelled`, which the listing drops;
/// - a repeating event this type cannot expand (a rule part `RecurrenceTail.Rule` does not
///   read, EXRULE, a THISANDFUTURE override, a walk past `Config.maxRuleSteps`, a listing with
///   no end): ONE row for the series at its first date, id = the href, with
///   `occurrencesNotListed`, so the tools say so instead of showing that date as an occurrence.
enum CalDAVOccurrences {

    private enum Config {
        /// The most rule periods (days, weeks, months or years, by FREQ) one expansion walks
        /// from a series' first date to the end of the range. A daily series that began 270
        /// years before the range still fits. A series past it is listed as one row marked not
        /// expanded, never cut short.
        static let maxRuleSteps = 100_000
        /// How far either side of a wall time to look for a UTC offset change. Zone
        /// transitions are months apart, so a day each way sees the offsets on both sides of
        /// any one of them.
        static let offsetSearchWindow: TimeInterval = 24 * 60 * 60
        /// The length of a day, for a DURATION given in days and for the margin before a
        /// range's first day (RFC 5545 §3.3.6 counts `P1D` as a nominal day).
        static let secondsPerDay: TimeInterval = 24 * 60 * 60
    }

    // MARK: - Occurrence ids

    /// An occurrence's event id: the series' resource href, `#`, then the occurrence key.
    ///
    /// The key is the occurrence's RECURRENCE-ID in one normal form: `yyyyMMdd` in an all-day
    /// series, the wall time `yyyyMMddTHHmmss` in a floating one, and the instant in UTC
    /// `yyyyMMddTHHmmssZ` in every other, as Google writes `<id>_<yyyyMMddTHHmmssZ>`.
    ///
    /// `#` cannot occur in a resource href a server returns: it starts a URI fragment, so a
    /// path holds it percent-encoded. That keeps the split unambiguous. It also means an
    /// occurrence id given to `URL(string:)` would address the WHOLE resource, because a
    /// fragment is never sent; `CalDAVProvider.resolveEventURL` therefore refuses any id that
    /// still carries one.
    enum OccurrenceId {
        static let separator: Character = "#"

        static func make(seriesHref: String, key: String) -> String {
            "\(seriesHref)\(separator)\(key)"
        }

        /// The series href and the occurrence key of an occurrence id; the id itself and nil
        /// for any other id. Throws `notSupported` for a `#` followed by anything but a key,
        /// so a damaged id is refused rather than read as some other event.
        static func split(_ id: String) throws -> (seriesHref: String, key: String?) {
            guard let mark = id.lastIndex(of: separator) else { return (id, nil) }
            let href = String(id[..<mark])
            let key = String(id[id.index(after: mark)...])
            guard !href.isEmpty, !href.contains(separator), isKey(key) else {
                throw CalendarProviderError.notSupported(
                    "'\(id)' is not an event id TabMail made for this calendar. Look the event up again with calendar_search or calendar_read")
            }
            return (href, key)
        }

        /// `yyyyMMdd`, `yyyyMMddTHHmmss` or `yyyyMMddTHHmmssZ`.
        static func isKey(_ key: String) -> Bool {
            let chars = Array(key)
            let dateLength = 8
            let dateTimeLength = 15
            if chars.count == dateLength { return chars.allSatisfy(isDigit) }
            guard chars.count == dateTimeLength || (chars.count == dateTimeLength + 1 && chars.last == "Z"),
                  chars[dateLength] == "T" else { return false }
            return chars[0..<dateLength].allSatisfy(isDigit)
                && chars[(dateLength + 1)..<dateTimeLength].allSatisfy(isDigit)
        }

        /// The `recurrence_id` and its zone that name this key's occurrence to
        /// `CalendarProvider.updateOccurrence`: the date (at midnight, the shape the tools
        /// use) for an all-day key, the wall time in the device zone for a floating one, and
        /// the UTC wall time for an instant, so the provider's conversion into the series'
        /// own frame lands on the same occurrence.
        static func recurrenceId(ofKey key: String) -> (naive: String, zone: TimeZone)? {
            guard isKey(key) else { return nil }
            let c = Array(key)
            let date = "\(String(c[0..<4]))-\(String(c[4..<6]))-\(String(c[6..<8]))"
            guard c.count > 8 else { return ("\(date)T00:00:00", .current) }
            let time = "\(String(c[9..<11])):\(String(c[11..<13])):\(String(c[13..<15]))"
            return ("\(date)T\(time)", c.last == "Z" ? TimeZone.gmt : TimeZone.current)
        }

        private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
    }

    // MARK: - Listing and lookup

    /// The rows a listing shows for one resource: see the type's comment. `timeMin`/`timeMax`
    /// is the listing's range (an occurrence is listed when it overlaps it, RFC 4791 §9.9).
    static func listing(icsText: String, href: String, timeMin: Date?, timeMax: Date?) -> [GCalEvent] {
        let components = ICSParser.components(icsText: icsText, resourceHref: href)
        let overrides = components.filter { $0.recurrenceId != nil }
        guard let master = components.first(where: { $0.recurrenceId == nil }) else {
            // Only changed occurrences, no series (an invitation to single occurrences,
            // RFC 4791 §4.1): each is listed where it is.
            return overrides.compactMap { override in
                guard let rid = override.recurrenceId,
                      let key = standaloneKey(of: rid, zones: override.zones),
                      let overrideSpan = spanOf(override),
                      overlaps(overrideSpan, timeMin: timeMin, timeMax: timeMax) else { return nil }
                return occurrenceRow(override.event, href: href, key: key, recurrence: nil)
            }
        }
        let series: Series
        switch shape(of: master, overrides: overrides) {
        case .single:
            return [master.event]
        case .unexpandable(let reason):
            return [notListedRow(master, href: href, reason: reason)]
        case .series(let s):
            series = s
        }
        guard let timeMax, let lastDay = series.frame.day(of: timeMax) else {
            return [notListedRow(master, href: href, reason: "the listing has no end")]
        }
        // Occurrences on days before this one end before the range starts.
        let firstNeeded = timeMin
            .flatMap { series.frame.day(of: $0.addingTimeInterval(-series.lengthForRange)) }?
            .adding(days: -1)
        guard let found = expandInstances(of: series, from: firstNeeded, through: lastDay) else {
            return [notListedRow(master, href: href, reason: "more than \(Config.maxRuleSteps) repeats before the range")]
        }

        var rows: [GCalEvent] = []
        var overridden = Set<String>()
        for override in overrides {
            guard let rid = override.recurrenceId,
                  let key = occurrenceKey(ofValue: rid.value, params: rid.params, in: series),
                  overridden.insert(key).inserted else { continue }
            guard let overrideSpan = spanOf(override), overlaps(overrideSpan, timeMin: timeMin, timeMax: timeMax) else { continue }
            rows.append(occurrenceRow(override.event, href: href, key: key, recurrence: series.recurrenceLines))
        }
        for instance in found where !overridden.contains(instance.key) {
            guard overlaps((start: instance.start, end: instance.end), timeMin: timeMin, timeMax: timeMax) else { continue }
            rows.append(instanceRow(instance, of: series, href: href))
        }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CalDAV] occurrences: \(href) has \(rows.count) row(s) in range from \(found.count) occurrence(s) and \(overrides.count) override(s)")
        }
        return rows
    }

    /// The occurrence `key` names in the resource, as a listing shows it, or nil when the
    /// series has no such occurrence now (it was removed, or the series changed since the id
    /// was listed). A cancelled occurrence comes back with status `cancelled`.
    static func occurrence(key wanted: String, icsText: String, href: String) -> GCalEvent? {
        let components = ICSParser.components(icsText: icsText, resourceHref: href)
        let overrides = components.filter { $0.recurrenceId != nil }
        guard let master = components.first(where: { $0.recurrenceId == nil }) else {
            return overrides.first { override in override.recurrenceId.flatMap { standaloneKey(of: $0, zones: override.zones) } == wanted }
                .map { occurrenceRow($0.event, href: href, key: wanted, recurrence: nil) }
        }
        guard case .series(let series) = shape(of: master, overrides: overrides) else { return nil }
        if let override = overrides.first(where: { component in
            guard let rid = component.recurrenceId else { return false }
            return occurrenceKey(ofValue: rid.value, params: rid.params, in: series) == wanted
        }) {
            return occurrenceRow(override.event, href: href, key: wanted, recurrence: series.recurrenceLines)
        }
        // A UTC key's date is a day either side of the occurrence's date in the series' zone
        // at most (UTC offsets stay within 14 hours).
        guard let keyDay = RecurrenceTail.Day(ical: wanted),
              let found = expandInstances(of: series, from: keyDay.adding(days: -1), through: keyDay.adding(days: 1)),
              let instance = found.first(where: { $0.key == wanted }) else { return nil }
        return instanceRow(instance, of: series, href: href)
    }

    // MARK: - Series

    /// How a series' DTSTART places its occurrences.
    private enum Frame {
        case allDay
        case floating
        case utc
        case zoned(TimeZone, tzid: String)

        /// The zone the series' wall times are read in. An all-day date and a floating time
        /// are read in the device's, like every other all-day and floating value in the app.
        var zone: TimeZone {
            switch self {
            case .allDay, .floating: return .current
            case .utc: return .gmt
            case .zoned(let zone, _): return zone
            }
        }

        /// The calendar day `instant` falls on here.
        func day(of instant: Date) -> RecurrenceTail.Day? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let c = calendar.dateComponents([.year, .month, .day], from: instant)
            guard let year = c.year, let month = c.month, let day = c.day else { return nil }
            return RecurrenceTail.Day(year: year, month: month, day: day)
        }
    }

    /// A repeating master the expansion can read.
    private struct Series {
        let master: ICSParser.VEventComponent
        let frame: Frame
        let firstDay: RecurrenceTail.Day
        /// DTSTART's time of day; nil for an all-day series.
        let timeOfDay: (hour: Int, minute: Int, second: Int)?
        let rule: RecurrenceTail.Rule?
        let count: Int?
        let until: Until?
        /// Days an all-day occurrence lasts.
        let allDayLength: Int
        /// Seconds a timed occurrence lasts.
        let timedLength: TimeInterval
        var recurrenceLines: [String]? { master.event.recurrence }
        /// How long an occurrence lasts, for working out the first day a range needs.
        var lengthForRange: TimeInterval {
            timeOfDay == nil ? TimeInterval(allDayLength) * Config.secondsPerDay : timedLength
        }
    }

    /// An UNTIL: an instant (`…Z`, or a wall time read in the series' zone) or a whole day.
    private enum Until {
        case instant(Date)
        case day(RecurrenceTail.Day)
    }

    private enum Shape {
        case single
        case unexpandable(reason: String)
        case series(Series)
    }

    private static func shape(of master: ICSParser.VEventComponent, overrides: [ICSParser.VEventComponent]) -> Shape {
        guard !master.rrules.isEmpty || !master.rdates.isEmpty || master.hasExRule else { return .single }
        guard !master.hasExRule else { return .unexpandable(reason: "it has an EXRULE") }
        guard master.rrules.count <= 1 else { return .unexpandable(reason: "it has more than one RRULE") }
        if overrides.contains(where: { hasParam($0.recurrenceId?.params, name: "RANGE", value: "THISANDFUTURE") }) {
            return .unexpandable(reason: "a change applies to an occurrence and all later ones (RANGE=THISANDFUTURE)")
        }
        guard let dtstart = master.dtstart, let firstDay = RecurrenceTail.Day(ical: dtstart.value) else {
            return .unexpandable(reason: "its first date can't be read")
        }

        let frame: Frame
        var timeOfDay: (hour: Int, minute: Int, second: Int)?
        if master.isAllDay {
            frame = .allDay
        } else {
            guard let wall = wallTime(dtstart.value) else { return .unexpandable(reason: "its start time can't be read") }
            timeOfDay = (wall.hour, wall.minute, wall.second)
            // The order `ICSParser` reads a start in: `Z`, then a TZID, else floating.
            if dtstart.value.uppercased().hasSuffix("Z") {
                frame = .utc
            } else if let params = dtstart.params, let tzid = ICSParser.extractTZID(params) {
                frame = .zoned(ICSParser.wallTimeZone(params: params, zones: master.zones), tzid: tzid)
            } else {
                frame = .floating
            }
        }

        var rule: RecurrenceTail.Rule?
        var count: Int?
        var until: Until?
        if let text = master.rrules.first {
            guard let parsed = RecurrenceTail.Rule(text) else {
                return .unexpandable(reason: "TabMail can't expand its rule")
            }
            rule = parsed
            let countText = rulePart("COUNT", in: text)
            let untilText = rulePart("UNTIL", in: text)
            if countText != nil, untilText != nil { return .unexpandable(reason: "its rule has both COUNT and UNTIL") }
            if let countText {
                guard let n = Int(countText), n >= 1 else { return .unexpandable(reason: "its COUNT can't be read") }
                count = n
            }
            if let untilText {
                guard let parsedUntil = parseUntil(untilText, frame: frame) else {
                    return .unexpandable(reason: "its UNTIL can't be read")
                }
                until = parsedUntil
            }
        }

        var allDayLength = 0
        var timedLength: TimeInterval = 0
        if master.isAllDay {
            allDayLength = allDayDays(of: master, firstDay: firstDay)
        } else if let start = master.startDate, let end = master.endDate, end > start {
            timedLength = end.timeIntervalSince(start)
        }
        return .series(Series(
            master: master, frame: frame, firstDay: firstDay, timeOfDay: timeOfDay,
            rule: rule, count: count, until: until,
            allDayLength: allDayLength, timedLength: timedLength))
    }

    /// An all-day VEVENT's length in days: its DTEND's date less its DTSTART's, else its
    /// DURATION, else the one day RFC 5545 §3.6.1 gives it.
    private static func allDayDays(of component: ICSParser.VEventComponent, firstDay: RecurrenceTail.Day) -> Int {
        if let dtend = component.dtend, let endDay = RecurrenceTail.Day(ical: dtend.value) {
            let days = endDay.days(since: firstDay)
            if days >= 1 { return days }
        } else if let duration = component.duration {
            let reference = Date(timeIntervalSince1970: 0)
            if let end = ICSParser.addDuration(duration.trimmingCharacters(in: .whitespaces), to: reference) {
                let days = Int((end.timeIntervalSince(reference) / Config.secondsPerDay).rounded(.down))
                if days >= 1 { return days }
            }
        }
        return 1
    }

    // MARK: - Occurrences

    /// One occurrence where the series puts it, before any change to it.
    private struct Instance {
        let key: String
        /// The occurrence's day in the series' frame.
        let day: RecurrenceTail.Day
        let start: Date
        let end: Date
        /// An all-day occurrence's last day plus one; nil for a timed one.
        let allDayEnd: RecurrenceTail.Day?
    }

    /// The series' occurrences on days up to `lastDay` in its frame, earliest first: DTSTART,
    /// the rule's (COUNT and UNTIL applied, an excluded date still counting toward COUNT),
    /// and every RDATE, less every EXDATE. The rule's occurrences on days before `firstNeeded`
    /// are counted but not built. nil when the rule takes more than `Config.maxRuleSteps`
    /// periods to get to `lastDay`.
    private static func expandInstances(
        of series: Series, from firstNeeded: RecurrenceTail.Day?, through lastDay: RecurrenceTail.Day
    ) -> [Instance]? {
        var days = [series.firstDay]
        if let rule = series.rule {
            var bound = lastDay
            if let until = series.until, let limit = untilDay(until, frame: series.frame), limit < bound {
                bound = limit
            }
            guard let ruleDays = rule.days(from: series.firstDay, through: bound, maxSteps: Config.maxRuleSteps) else {
                return nil
            }
            days = ruleDays
            if let count = series.count { days = Array(days.prefix(count)) }
        }

        var out: [Instance] = []
        var keys = Set<String>()
        for (index, day) in days.enumerated() {
            if let firstNeeded, day < firstNeeded { continue }
            guard let instance = makeInstance(of: series, on: day) else { continue }
            // DTSTART is always the first occurrence, whatever the UNTIL.
            if index > 0, let until = series.until, !isOnOrBefore(instance, until: until) { continue }
            if keys.insert(instance.key).inserted { out.append(instance) }
        }

        for rdate in series.master.rdates {
            let isPeriod = hasParam(rdate.params, name: "VALUE", value: "PERIOD")
            for item in rdate.value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                guard let instance = addedInstance(item, params: rdate.params, isPeriod: isPeriod, to: series),
                      instance.day <= lastDay else { continue }
                if keys.insert(instance.key).inserted { out.append(instance) }
            }
        }

        var excludedKeys = Set<String>()
        var excludedDays = Set<RecurrenceTail.Day>()
        for exdate in series.master.exdates {
            for item in exdate.value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if series.timeOfDay != nil, isDateValue(item, params: exdate.params) {
                    // A DATE excluded from a timed series takes out that day's occurrence.
                    if let day = RecurrenceTail.Day(ical: item) { excludedDays.insert(day) }
                } else if let key = occurrenceKey(ofValue: item, params: exdate.params, in: series) {
                    excludedKeys.insert(key)
                }
            }
        }
        return out
            .filter { !excludedKeys.contains($0.key) && !excludedDays.contains($0.day) }
            .sorted { $0.start < $1.start }
    }

    /// The occurrence the series' DTSTART time of day puts on `day`.
    private static func makeInstance(of series: Series, on day: RecurrenceTail.Day) -> Instance? {
        guard let time = series.timeOfDay else {
            let endDay = day.adding(days: series.allDayLength)
            guard let start = startOfDay(day), let end = startOfDay(endDay) else { return nil }
            return Instance(key: dateKey(day), day: day, start: start, end: end, allDayEnd: endDay)
        }
        guard let start = wallInstant(day: day, hour: time.hour, minute: time.minute, second: time.second, in: series.frame.zone) else {
            return nil
        }
        let key: String
        if case .floating = series.frame {
            key = wallKey(day: day, hour: time.hour, minute: time.minute, second: time.second)
        } else {
            guard let utc = utcKey(start) else { return nil }
            key = utc
        }
        return Instance(key: key, day: day, start: start, end: start.addingTimeInterval(series.timedLength), allDayEnd: nil)
    }

    /// An RDATE item as an occurrence: a DATE, a DATE-TIME, or (VALUE=PERIOD) a start and an
    /// end or a duration, which then gives this occurrence its own length.
    private static func addedInstance(_ item: String, params: String?, isPeriod: Bool, to series: Series) -> Instance? {
        var startText = item
        var periodEnd: String?
        if isPeriod {
            let parts = item.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            startText = parts[0]
            periodEnd = parts[1]
        }
        if series.timeOfDay == nil || isDateValue(startText, params: params) {
            guard let day = RecurrenceTail.Day(ical: startText) else { return nil }
            return makeInstance(of: series, on: day)
        }
        guard let start = valueInstant(startText, params: params, in: series),
              let key = occurrenceKey(ofValue: startText, params: params, in: series),
              let day = series.frame.day(of: start) else { return nil }
        var end = start.addingTimeInterval(series.timedLength)
        if let periodEnd {
            if periodEnd.uppercased().hasPrefix("P") {
                guard let periodEndInstant = ICSParser.addDuration(periodEnd.uppercased(), to: start) else { return nil }
                end = periodEndInstant
            } else {
                guard let periodEndInstant = valueInstant(periodEnd, params: params, in: series) else { return nil }
                end = periodEndInstant
            }
        }
        return Instance(key: key, day: day, start: start, end: max(end, start), allDayEnd: nil)
    }

    private static func isOnOrBefore(_ instance: Instance, until: Until) -> Bool {
        switch until {
        case .instant(let limit): return instance.start <= limit
        case .day(let limit): return instance.day <= limit
        }
    }

    private static func untilDay(_ until: Until, frame: Frame) -> RecurrenceTail.Day? {
        switch until {
        case .instant(let limit): return frame.day(of: limit)
        case .day(let limit): return limit
        }
    }

    /// RFC 5545 §3.3.10: an UNTIL is a DATE in an all-day series and a UTC DATE-TIME in a
    /// timed one. A DATE in a timed series, or a DATE-TIME in an all-day one, is read by its
    /// date (the whole day is included), and a DATE-TIME without `Z` as a wall time in the
    /// series' zone.
    private static func parseUntil(_ text: String, frame: Frame) -> Until? {
        let value = text.uppercased()
        if case .allDay = frame { return RecurrenceTail.Day(ical: value).map(Until.day) }
        if value.count == 8 { return RecurrenceTail.Day(ical: value).map(Until.day) }
        guard let wall = wallTime(value) else { return nil }
        let zone = value.hasSuffix("Z") ? TimeZone.gmt : frame.zone
        return wallInstant(day: wall.day, hour: wall.hour, minute: wall.minute, second: wall.second, in: zone).map(Until.instant)
    }

    // MARK: - Keys

    /// The occurrence key a RECURRENCE-ID, EXDATE or RDATE value names in `series`.
    private static func occurrenceKey(ofValue value: String, params: String?, in series: Series) -> String? {
        if series.timeOfDay == nil {
            return RecurrenceTail.Day(ical: value).map(dateKey)
        }
        if isDateValue(value, params: params) {
            return RecurrenceTail.Day(ical: value).flatMap { makeInstance(of: series, on: $0)?.key }
        }
        if case .floating = series.frame {
            let upper = value.uppercased()
            if !upper.hasSuffix("Z"), params.flatMap(ICSParser.extractTZID) == nil {
                return wallTime(upper).map { wallKey(day: $0.day, hour: $0.hour, minute: $0.minute, second: $0.second) }
            }
            return valueInstant(value, params: params, in: series).flatMap { wallKey(of: $0, in: .current) }
        }
        return valueInstant(value, params: params, in: series).flatMap(utcKey)
    }

    /// The key of a changed occurrence whose series is not in the resource, read by its own
    /// form: a DATE, a floating wall time, or an instant. `zones` is the resource's zone context.
    private static func standaloneKey(of rid: ICSParser.PropertyValue, zones: CalendarTimeZoneContext) -> String? {
        let value = rid.value.uppercased()
        if isDateValue(value, params: rid.params) { return RecurrenceTail.Day(ical: value).map(dateKey) }
        guard let wall = wallTime(value) else { return nil }
        if !value.hasSuffix("Z"), rid.params.flatMap(ICSParser.extractTZID) == nil {
            return wallKey(day: wall.day, hour: wall.hour, minute: wall.minute, second: wall.second)
        }
        let zone = value.hasSuffix("Z") ? TimeZone.gmt : ICSParser.wallTimeZone(params: rid.params, zones: zones)
        return wallInstant(day: wall.day, hour: wall.hour, minute: wall.minute, second: wall.second, in: zone).flatMap(utcKey)
    }

    /// A DATE-TIME value as an instant: `Z` is UTC; otherwise its wall time in the TZID its
    /// parameters name, else in the series' zone.
    private static func valueInstant(_ value: String, params: String?, in series: Series) -> Date? {
        let upper = value.uppercased()
        guard let wall = wallTime(upper) else { return nil }
        let zone: TimeZone
        if upper.hasSuffix("Z") {
            zone = .gmt
        } else if params.flatMap(ICSParser.extractTZID) != nil {
            zone = ICSParser.wallTimeZone(params: params, zones: series.master.zones)
        } else {
            zone = series.frame.zone
        }
        return wallInstant(day: wall.day, hour: wall.hour, minute: wall.minute, second: wall.second, in: zone)
    }

    private static func dateKey(_ day: RecurrenceTail.Day) -> String {
        String(format: "%04d%02d%02d", day.year, day.month, day.day)
    }

    private static func wallKey(day: RecurrenceTail.Day, hour: Int, minute: Int, second: Int) -> String {
        dateKey(day) + String(format: "T%02d%02d%02d", hour, minute, second)
    }

    private static func wallKey(of instant: Date, in zone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        guard let year = c.year, let month = c.month, let dayOfMonth = c.day,
              let hour = c.hour, let minute = c.minute, let second = c.second,
              let day = RecurrenceTail.Day(year: year, month: month, day: dayOfMonth) else { return nil }
        return wallKey(day: day, hour: hour, minute: minute, second: second)
    }

    private static func utcKey(_ instant: Date) -> String? {
        wallKey(of: instant, in: .gmt).map { $0 + "Z" }
    }

    // MARK: - Wall times

    /// The date and time of day of a `yyyyMMddTHHmmss[Z]` value.
    private static func wallTime(_ value: String) -> (day: RecurrenceTail.Day, hour: Int, minute: Int, second: Int)? {
        let c = Array(value)
        guard c.count >= 15, c[8] == "T",
              let day = RecurrenceTail.Day(ical: value),
              c[9..<15].allSatisfy({ $0.isASCII && $0.isNumber }),
              let hour = Int(String(c[9..<11])), let minute = Int(String(c[11..<13])), let second = Int(String(c[13..<15])),
              hour < 24, minute < 60, second < 61 else { return nil }
        return (day, hour, minute, second)
    }

    /// The instant a wall time names in `zone` (RFC 5545 §3.3.5): a time a change to summer
    /// time skips is read with the UTC offset from before the change (02:30 on a 02:00 to 03:00
    /// day is 03:30), and a time the change back repeats names the first of the two.
    static func wallInstant(day: RecurrenceTail.Day, hour: Int, minute: Int, second: Int, in zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute, second: second)
        guard let naive = calendar.date(from: components) else { return nil }
        let before = zone.secondsFromGMT(for: naive.addingTimeInterval(-Config.offsetSearchWindow))
        let after = zone.secondsFromGMT(for: naive.addingTimeInterval(Config.offsetSearchWindow))
        let readBefore = naive.addingTimeInterval(TimeInterval(-before))
        let readAfter = naive.addingTimeInterval(TimeInterval(-after))
        let beforeHolds = zone.secondsFromGMT(for: readBefore) == before
        let afterHolds = zone.secondsFromGMT(for: readAfter) == after
        switch (beforeHolds, afterHolds) {
        case (true, true): return min(readBefore, readAfter)
        case (false, true): return readAfter
        case (true, false), (false, false): return readBefore
        }
    }

    /// The instant an all-day date starts on the device, as `GCalEvent.startDate` reads it,
    /// and still defined on a day whose midnight a change to summer time skips.
    private static func startOfDay(_ day: RecurrenceTail.Day) -> Date? {
        wallInstant(day: day, hour: 0, minute: 0, second: 0, in: .current)
    }

    // MARK: - Rows

    /// A component's start and end, for the range check: its own times, and for an all-day
    /// one its dates on the device (one day when it gives no end).
    private static func spanOf(_ component: ICSParser.VEventComponent) -> (start: Date, end: Date)? {
        if component.isAllDay {
            guard let value = component.dtstart?.value, let firstDay = RecurrenceTail.Day(ical: value),
                  let start = startOfDay(firstDay),
                  let end = startOfDay(firstDay.adding(days: allDayDays(of: component, firstDay: firstDay))) else { return nil }
            return (start: start, end: end)
        }
        guard let start = component.startDate else { return nil }
        return (start: start, end: max(component.endDate ?? start, start))
    }

    /// RFC 4791 §9.9: an occurrence with a length overlaps the range when it starts before the
    /// range ends and ends after it starts; one with no length, when it starts in the range.
    private static func overlaps(_ span: (start: Date, end: Date), timeMin: Date?, timeMax: Date?) -> Bool {
        let startsBeforeEnd = timeMax.map { span.start < $0 } ?? true
        if span.end > span.start {
            return startsBeforeEnd && (timeMin.map { span.end > $0 } ?? true)
        }
        return startsBeforeEnd && (timeMin.map { span.start >= $0 } ?? true)
    }

    private static func instanceRow(_ instance: Instance, of series: Series, href: String) -> GCalEvent {
        let start: GCalDateTime
        let end: GCalDateTime
        if let endDay = instance.allDayEnd {
            start = GCalDateTime(dateTime: nil, date: instance.day.description, timeZone: nil)
            end = GCalDateTime(dateTime: nil, date: endDay.description, timeZone: nil)
        } else {
            var tzid: String?
            if case .zoned(_, let id) = series.frame { tzid = id }
            start = GCalDateTime(dateTime: instance.start.iso8601String(), date: nil, timeZone: tzid)
            end = GCalDateTime(dateTime: instance.end.iso8601String(), date: nil, timeZone: tzid)
        }
        let master = series.master.event
        return GCalEvent(
            id: OccurrenceId.make(seriesHref: href, key: instance.key),
            summary: master.summary, location: master.location, description: master.description,
            start: start, end: end, attendees: master.attendees, organizer: master.organizer,
            recurrence: series.recurrenceLines, transparency: master.transparency, status: master.status,
            htmlLink: master.htmlLink, created: master.created, updated: master.updated,
            recurringEventId: href, conferenceUrl: master.conferenceUrl)
    }

    private static func occurrenceRow(_ event: GCalEvent, href: String, key: String, recurrence: [String]?) -> GCalEvent {
        GCalEvent(
            id: OccurrenceId.make(seriesHref: href, key: key),
            summary: event.summary, location: event.location, description: event.description,
            start: event.start, end: event.end, attendees: event.attendees, organizer: event.organizer,
            recurrence: recurrence, transparency: event.transparency, status: event.status,
            htmlLink: event.htmlLink, created: event.created, updated: event.updated,
            recurringEventId: href, conferenceUrl: event.conferenceUrl)
    }

    private static func notListedRow(_ master: ICSParser.VEventComponent, href: String, reason: String) -> GCalEvent {
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CalDAV] occurrences: \(href) not expanded (\(reason)), listed once at its first date")
        }
        var row = master.event
        row.occurrencesNotListed = true
        return row
    }

    // MARK: - Parameters

    private static func rulePart(_ name: String, in rrule: String) -> String? {
        for part in rrule.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).uppercased() == name {
                return pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func hasParam(_ params: String?, name: String, value: String) -> Bool {
        guard let params else { return false }
        return params.split(separator: ";").contains { part in
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            return pair.count == 2 && pair[0] == name && pair[1] == value
        }
    }

    /// A DATE value: stated by `VALUE=DATE`, or eight digits with no time.
    private static func isDateValue(_ value: String, params: String?) -> Bool {
        ICSValueType.statesDate(params ?? "") || (value.count == 8 && !value.contains("T"))
    }
}
