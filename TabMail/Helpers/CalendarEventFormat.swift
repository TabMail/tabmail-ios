/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// How an event card writes an event's time and time zone: the agent's confirmation card and the
/// chat view's invite card (E3) read the same.
enum CalendarEventFormat {
    /// The zone `id` names, else the device's.
    static func timeZone(id: String?) -> TimeZone {
        if let id, let resolved = TimeZone(identifier: id) { return resolved }
        return .current
    }

    /// "PST (America/Vancouver)", or the identifier alone when it has no other abbreviation.
    static func timeZoneLabel(_ tz: TimeZone) -> String {
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
