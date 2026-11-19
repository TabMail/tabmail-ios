/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// How an event card writes an event's time and time zone: the agent's confirmation card and the
/// chat view's invite card read the same.
enum CalendarEventFormat {
    /// The zone `id` names (read through `CalendarTimeZoneResolver`, so a Windows name counts),
    /// else the device's.
    static func timeZone(id: String?) -> TimeZone {
        if let id, let resolved = CalendarTimeZoneResolver.zone(named: id, in: .none) { return resolved }
        return .current
    }

    /// The zone line of a card whose times are in `tz`, or nil when `tz` is `deviceZone` (the
    /// device's zone as the card is shown): like Google Calendar, a card names a zone only when it
    /// is not the user's own (#753). Every event card decides its zone line here.
    static func timeZoneLabel(_ tz: TimeZone, deviceZone: TimeZone) -> String? {
        if tz.identifier == deviceZone.identifier { return nil }
        return zoneName(tz)
    }

    /// "PST (America/Vancouver)", or the identifier alone when it has no other abbreviation.
    private static func zoneName(_ tz: TimeZone) -> String {
        let abbr = tz.abbreviation() ?? tz.identifier
        // If abbreviation == identifier (rare), don't duplicate.
        if abbr == tz.identifier { return tz.identifier }
        return "\(abbr) (\(tz.identifier))"
    }

    /// The start date and time and the end time, or the day with "(all day)". The zone is left
    /// out: the card shows it on its own line.
    static func time(start: Date, end: Date, isAllDay: Bool, timeZone tz: TimeZone) -> String {
        if isAllDay {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            fmt.timeZone = tz
            return "\(fmt.string(from: start)) (all day)"
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        fmt.timeZone = tz
        let endFmt = DateFormatter()
        endFmt.timeStyle = .short
        endFmt.timeZone = tz
        return "\(fmt.string(from: start)) – \(endFmt.string(from: end))"
    }
}
