/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Generates an RFC 5545 `VTIMEZONE` component for an IANA time zone.
///
/// A CalDAV resource that references a zone via `DTSTART;TZID=…` MUST embed a
/// matching `VTIMEZONE` in the same `VCALENDAR` (RFC 5545 §3.2.19 / §3.6.5) —
/// strict servers (iCloud, Nextcloud, Zimbra) reject the resource otherwise.
///
/// The generated component describes the zone's CURRENT transition rule
/// projected forward: one `STANDARD` + one `DAYLIGHT` sub-component for zones
/// that observe DST, or a single fixed-offset `STANDARD` for zones that don't.
/// Historical rule changes are intentionally not represented — for events
/// going forward, the current rule is the one that matters, and a single
/// current rule per type is what mainstream CalDAV clients emit.
enum VTimeZoneBuilder {

    /// Build the `VTIMEZONE` block (logical, unfolded lines) for `timeZone`.
    /// Returns `nil` only if the zone can't be introspected at all — callers
    /// should then emit a UTC `Z` time instead (which needs no VTIMEZONE).
    static func vtimezone(for timeZone: TimeZone) -> [String]? {
        let now = Date()

        // No upcoming DST transition → the zone keeps a fixed offset. Emit a
        // single STANDARD component with that offset.
        guard let firstTransition = timeZone.nextDaylightSavingTimeTransition(after: now) else {
            return fixedOffsetVTimeZone(for: timeZone, at: now)
        }
        // A DST zone is expected to have a regular cadence of transitions. If we
        // can only see one (a zone abandoning DST, or an API quirk), fall back
        // to the current fixed offset rather than emit a half-defined rule.
        guard let secondTransition = timeZone.nextDaylightSavingTimeTransition(after: firstTransition) else {
            return fixedOffsetVTimeZone(for: timeZone, at: now)
        }

        let c1 = component(for: firstTransition, in: timeZone)
        let c2 = component(for: secondTransition, in: timeZone)
        // Order of STANDARD vs DAYLIGHT is irrelevant to parsers.
        return ["BEGIN:VTIMEZONE", "TZID:\(timeZone.identifier)"] + c1 + c2 + ["END:VTIMEZONE"]
    }

    // MARK: - Components

    private static func fixedOffsetVTimeZone(for timeZone: TimeZone, at date: Date) -> [String] {
        let offset = timeZone.secondsFromGMT(for: date)
        return [
            "BEGIN:VTIMEZONE",
            "TZID:\(timeZone.identifier)",
            "BEGIN:STANDARD",
            "DTSTART:19700101T000000",
            "TZOFFSETFROM:\(formatOffset(offset))",
            "TZOFFSETTO:\(formatOffset(offset))",
            "TZNAME:\(timeZone.abbreviation(for: date) ?? "GMT")",
            "END:STANDARD",
            "END:VTIMEZONE",
        ]
    }

    /// Build the `STANDARD` or `DAYLIGHT` sub-component for one DST transition.
    private static func component(for transition: Date, in tz: TimeZone) -> [String] {
        let justBefore = transition.addingTimeInterval(-1)
        let justAfter = transition.addingTimeInterval(1)
        let offsetFrom = tz.secondsFromGMT(for: justBefore)
        let offsetTo = tz.secondsFromGMT(for: justAfter)
        // The period STARTING at this transition is daylight or standard.
        let isDaylight = tz.isDaylightSavingTime(for: justAfter)
        let name = isDaylight ? "DAYLIGHT" : "STANDARD"

        // The transition's wall-clock components, expressed in LOCAL time using
        // the TZOFFSETFROM offset (RFC 5545 §3.6.5: a sub-component's onset is a
        // date-with-local-time value). These fields are always populated for a
        // real Date + Gregorian calendar — force-unwrap so a genuine failure
        // surfaces loudly rather than silently emitting a wrong onset.
        var fromCal = Calendar(identifier: .gregorian)
        fromCal.timeZone = TimeZone(secondsFromGMT: offsetFrom) ?? tz
        let c = fromCal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday],
            from: transition
        )
        let rule = onsetRule(components: c, calendar: fromCal, transition: transition)

        // RFC 5545 §3.6.5: "the offset to apply at any given time is found by
        // locating the observance that has the last onset date and time BEFORE
        // the time in question." The transition we observed is in the FUTURE,
        // and an RRULE only generates instances forward from DTSTART — so an
        // event earlier than the next transition would have NO prior onset and
        // an unresolvable offset. Re-anchor: keep the rule's month / weekday-
        // ordinal / wall-clock time, but place the concrete onset in a fixed
        // past year so the RRULE's instance set covers all realistic dates.
        // (Projecting the current rule backward is the same simplification this
        // file already makes forward — see the type doc comment.) When the rule
        // can't be derived — impossible for a real transition — fall back to the
        // transition's own date so at least that single onset is represented.
        let dtstart: String
        if let rule {
            dtstart = anchoredDTStart(rule: rule, hour: c.hour!, minute: c.minute!, second: c.second!)
        } else {
            dtstart = String(format: "%04d%02d%02dT%02d%02d%02d",
                             c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        }

        var lines = [
            "BEGIN:\(name)",
            "DTSTART:\(dtstart)",
            "TZOFFSETFROM:\(formatOffset(offsetFrom))",
            "TZOFFSETTO:\(formatOffset(offsetTo))",
            "TZNAME:\(tz.abbreviation(for: justAfter) ?? name)",
        ]
        if let rule {
            lines.append("RRULE:\(rrule(for: rule))")
        }
        lines.append("END:\(name)")
        return lines
    }

    // MARK: - Onset rule

    /// The recurring DST onset rule derived from one observed transition.
    private struct OnsetRule {
        let month: Int      // 1-12
        let ordinal: Int    // 1-4, or -1 for "last <weekday> of the month"
        let weekday: Int    // 1=Sun … 7=Sat
    }

    /// Derive the yearly onset rule from a transition's wall-clock components.
    /// The ordinal is `-1` when the transition falls in the last week of the
    /// month (so "last Sunday" style EU rules round-trip correctly), otherwise
    /// the 1-based occurrence within the month (US "2nd Sunday" style).
    private static func onsetRule(components c: DateComponents, calendar: Calendar, transition: Date) -> OnsetRule? {
        guard let month = c.month, let day = c.day, let weekday = c.weekday,
              weekday >= 1, weekday <= 7 else { return nil }
        let daysInMonth = calendar.range(of: .day, in: .month, for: transition)?.count ?? 31
        let ordinal: Int = (day + 7 > daysInMonth) ? -1 : ((day - 1) / 7 + 1)
        return OnsetRule(month: month, ordinal: ordinal, weekday: weekday)
    }

    /// `FREQ=YEARLY;BYMONTH=<m>;BYDAY=<nth><weekday>` describing the rule.
    private static func rrule(for rule: OnsetRule) -> String {
        let weekdayAbbrev = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        return "FREQ=YEARLY;BYMONTH=\(rule.month);BYDAY=\(rule.ordinal)\(weekdayAbbrev[rule.weekday - 1])"
    }

    // MARK: - Past-anchored onset date

    /// Anchor year for sub-component `DTSTART` values — far enough in the past
    /// that every realistic event date has a prior onset to resolve against.
    private static let onsetAnchorYear = 1970

    /// Concrete onset DATE-TIME (local time, no offset) for `rule` in the fixed
    /// past anchor year — a real instance of `rrule(for:)` that precedes any
    /// realistic event date.
    private static func anchoredDTStart(rule: OnsetRule, hour: Int, minute: Int, second: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = nthWeekdayOfMonth(ordinal: rule.ordinal, weekday: rule.weekday,
                                    month: rule.month, year: onsetAnchorYear, calendar: cal)
        return String(format: "%04d%02d%02dT%02d%02d%02d",
                      onsetAnchorYear, rule.month, day, hour, minute, second)
    }

    /// Day-of-month of the `ordinal`-th `weekday` (1=Sun…7=Sat) in the given
    /// month/year; `ordinal == -1` means the last such weekday of the month.
    private static func nthWeekdayOfMonth(ordinal: Int, weekday: Int, month: Int, year: Int, calendar: Calendar) -> Int {
        guard let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth) else {
            return 1
        }
        let daysInMonth = range.count
        if ordinal < 0 {
            var day = daysInMonth
            while day >= 1 {
                if let d = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                   calendar.component(.weekday, from: d) == weekday {
                    return day
                }
                day -= 1
            }
            return daysInMonth
        }
        var found = 0
        var day = 1
        while day <= daysInMonth {
            if let d = calendar.date(from: DateComponents(year: year, month: month, day: day)),
               calendar.component(.weekday, from: d) == weekday {
                found += 1
                if found == ordinal { return day }
            }
            day += 1
        }
        return daysInMonth
    }

    /// Format a GMT offset in seconds as the RFC 5545 `±HHMM` (or `±HHMMSS`)
    /// `UTC-OFFSET` form.
    static func formatOffset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let total = abs(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if s != 0 {
            return String(format: "%@%02d%02d%02d", sign, h, m, s)
        }
        return String(format: "%@%02d%02d", sign, h, m)
    }
}
