/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The days a repeating series' rule names, moved with a move of the series to another day, as
/// Google Calendar moves them: a weekly series on Mondays moved one day later repeats on
/// Tuesdays, one on the 15th of the month moved to the 16th repeats on the 16th.
///
/// - **Weekdays** (`BYDAY` without positions) turn by the days moved; a series every few weeks
///   turns its week start (`WKST`, Monday when it names none) with them, so its days stay grouped
///   into the same weeks.
/// - **Days of the month** (`BYMONTHDAY`, counted from the month's start) move by the change in the
///   start's day of the month; **months** (`BYMONTH`) by the change in its month.
/// - **A day named by its position** (`BYDAY=2TU`, `-1FR`, or a `BYSETPOS`): the whole rule is kept.
///   The moved start is then one extra occurrence before the series goes on on its named day.
/// - **A rule naming no days** repeats on its start's day, so its days move with the start.
///
/// Refused (`notSupported`), as no move by whole days carries it: a day of the month counted from
/// the month's end, one moved out of 1 to 31, a day of the year (`BYYEARDAY`) and a week number
/// (`BYWEEKNO`).
///
/// One rule for every provider: Google and CalDAV turn their RRULE (`shifted`), Outlook its stored
/// pattern by the same parts (`weekday(_:by:)`, `monthDay(_:by:)`, `month(_:by:)`).
enum RecurrenceDayShift {

    /// A move of a series' start from one day to another, both in the frame its rule repeats in
    /// (the series' own zone, or the dates of an all-day series).
    struct Move: Sendable, Equatable {
        let from: RecurrenceTail.Day
        let to: RecurrenceTail.Day

        /// Whole days moved.
        var days: Int { to.days(since: from) }
        /// The change in the day of the month.
        var monthDays: Int { to.day - from.day }
        /// The change in the month of the year.
        var months: Int { to.month - from.month }
    }

    /// The weekday codes in RFC 5545 order, Monday first.
    static let weekdayCodes = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

    /// The week start a rule has when it names none (RFC 5545 §3.3.10).
    static let defaultWeekStart = "MO"

    /// The parts of a rule that name the days or dates a series repeats on.
    static let namedDayParts: Set<String> = ["BYDAY", "BYMONTHDAY", "BYYEARDAY", "BYWEEKNO", "BYMONTH", "BYSETPOS"]

    /// `rrule` (with or without its `RRULE:` prefix, kept as given) with its named days moved by
    /// `move`. Its other parts, its end (`COUNT`, `UNTIL`) included, are kept as written.
    static func shifted(_ rrule: String, by move: Move) throws -> String {
        let prefix = rrule.uppercased().hasPrefix("RRULE:") ? String(rrule.prefix("RRULE:".count)) : ""
        let parts = rrule.dropFirst(prefix.count).split(separator: ";").map(String.init)
        func value(_ key: String) -> String? {
            parts.first { name(of: $0) == key }.map { String($0.drop { $0 != "=" }.dropFirst()).uppercased() }
        }
        let byDay = value("BYDAY")
        let positional = value("BYSETPOS") != nil
            || (byDay?.split(separator: ",").contains { !weekdayCodes.contains($0.trimmingCharacters(in: .whitespaces)) } ?? false)
        guard move.days != 0, !positional else { return rrule }
        let interval = Int(value("INTERVAL") ?? "1") ?? 1
        let turnsWeekStart = byDay != nil && value("FREQ") == "WEEKLY" && interval > 1
        var out: [String] = []
        for part in parts {
            let key = name(of: part)
            let list = (value(key) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            switch key {
            case "BYDAY":
                out.append("BYDAY=" + (try list.map { try weekday($0, by: move.days) }).joined(separator: ","))
            case "BYMONTHDAY":
                out.append("BYMONTHDAY=" + (try list.map { day -> String in
                    guard let day = Int(day) else { throw unmovable(part) }
                    return String(try monthDay(day, by: move.monthDays))
                }).joined(separator: ","))
            case "BYMONTH":
                out.append("BYMONTH=" + (try list.map { month -> String in
                    guard let month = Int(month), (1...12).contains(month) else { throw unmovable(part) }
                    return String(self.month(month, by: move.months))
                }).joined(separator: ","))
            case "BYYEARDAY", "BYWEEKNO":
                throw unmovable(part)
            case "WKST" where turnsWeekStart:
                continue
            default:
                out.append(part)
            }
        }
        if turnsWeekStart {
            out.append("WKST=" + (try weekday(value("WKST") ?? defaultWeekStart, by: move.days)))
        }
        return prefix + out.joined(separator: ";")
    }

    /// A weekday code (`MO` … `SU`) turned by `days`.
    static func weekday(_ code: String, by days: Int) throws -> String {
        guard let index = weekdayCodes.firstIndex(of: code.uppercased()) else { throw unmovable("BYDAY=\(code)") }
        let count = weekdayCodes.count
        return weekdayCodes[((index + days) % count + count) % count]
    }

    /// A day of the month counted from its start, moved by `days`; refused out of 1 to 31 or
    /// counted from the month's end.
    static func monthDay(_ day: Int, by days: Int) throws -> Int {
        let moved = day + days
        guard day >= 1, (1...31).contains(moved) else { throw unmovable("BYMONTHDAY=\(day)") }
        return moved
    }

    /// A month of the year moved by `months`, around the year.
    static func month(_ month: Int, by months: Int) -> Int {
        ((month - 1 + months) % 12 + 12) % 12 + 1
    }

    /// Whether `rrule` names the days it repeats on (a part in `namedDayParts`).
    static func namesDays(_ rrule: String) -> Bool {
        let body = rrule.uppercased().hasPrefix("RRULE:") ? rrule.dropFirst("RRULE:".count) : Substring(rrule)
        return body.split(separator: ";").contains { namedDayParts.contains(name(of: String($0))) }
    }

    private static func name(of part: String) -> String {
        String(part.prefix { $0 != "=" }).trimmingCharacters(in: .whitespaces).uppercased()
    }

    private static func unmovable(_ part: String) -> CalendarProviderError {
        .notSupported(
            "this repeating event repeats on days its rule names in a way a move to another day can't carry (\(part)); give the new repeat rule (recurrence) with the move, or change just that date (edit_scope 'this_only' with recurrence_id)")
    }
}
