/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The one place a calendar time-zone name becomes a `TimeZone`: an iCalendar `TZID`, a provider's
/// stored event zone, or the zone the assistant names in a tool argument. Every calendar path reads
/// zone names through here, so they all agree on which names TabMail recognizes.
///
/// `TimeZone(identifier:)` alone knows IANA names only, but Outlook and Exchange write Windows names
/// (`TZID=Pacific Standard Time`) into the invites they send, and CalDAV servers keep them as
/// received. A name is tried, in order, as:
/// 1. an identifier `TimeZone(identifier:)` knows (IANA names, `UTC`, `GMT`);
/// 2. a Windows zone name, through the CLDR table in `WindowsTimeZones`;
/// 3. the `X-LIC-LOCATION` the resource's `VTIMEZONE` gives the name (`CalendarTimeZoneContext`),
///    itself tried as 1 and 2.
///
/// Anything else is unrecognized, including a zone a `VTIMEZONE` defines only by its rules. What a
/// caller does with an unrecognized zone is the caller's decision; this function never substitutes
/// the device's zone.
enum CalendarTimeZoneResolver {

    /// The zone `name` names, or nil when TabMail does not recognize it.
    ///
    /// - Parameters:
    ///   - name: the zone name as written. Surrounding whitespace and double quotes are ignored
    ///     (RFC 5545 allows a quoted `TZID` parameter value).
    ///   - context: what the resource `name` was read from says about its zones; `.none` when the
    ///     name came from no resource.
    static func zone(named name: String, in context: CalendarTimeZoneContext) -> TimeZone? {
        let wanted = unquoted(name)
        guard !wanted.isEmpty else { return nil }
        if let zone = knownZone(wanted) { return zone }
        guard let location = context.locations[wanted] else { return nil }
        return knownZone(location)
    }

    /// Steps 1 and 2: an identifier Foundation knows, else a Windows name CLDR maps.
    private static func knownZone(_ name: String) -> TimeZone? {
        if let zone = TimeZone(identifier: name) { return zone }
        return WindowsTimeZones.ianaByWindowsName[name].flatMap { TimeZone(identifier: $0) }
    }

    /// `text` without surrounding whitespace and double quotes.
    static func unquoted(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespaces)
    }
}
