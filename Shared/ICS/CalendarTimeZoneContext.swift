/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// What one iCalendar resource says about the zone names it uses: the `X-LIC-LOCATION` of each of
/// its `VTIMEZONE` components, by `TZID`. `CalendarTimeZoneResolver` reads a name through it.
///
/// A reader or writer that handles one resource builds this once, from that resource, and passes it
/// down; nothing below it reads the resource's text for zone names. A name that comes from no
/// resource (the assistant's `timezone` argument, a zone Graph or Google returns) is read with
/// `.none`.
///
/// Only the `TZID` and `X-LIC-LOCATION` lines directly inside a `VTIMEZONE` are read. A zone its
/// `VTIMEZONE` defines only by its `STANDARD`/`DAYLIGHT` rules is not read from them, so such a name
/// stays unrecognized unless it is itself an IANA or Windows name.
struct CalendarTimeZoneContext: Sendable, Equatable {
    /// The context of a name read from no resource.
    static let none = CalendarTimeZoneContext(locations: [:])

    /// `X-LIC-LOCATION` by `TZID`, both unquoted. The first `VTIMEZONE` with a `TZID` defines it.
    let locations: [String: String]

    private init(locations: [String: String]) {
        self.locations = locations
    }

    /// The context of `calendarText`, in one forward pass over its lines. Each line costs only its own
    /// length and the state carried between lines is a fixed set of values, so the time is linear in
    /// the text whatever it holds. Folded continuation lines are joined only for a line directly
    /// inside a `VTIMEZONE`; everywhere else they are skipped.
    init(calendarText: String) {
        var locations: [String: String] = [:]
        var defined = Set<String>()
        // 0 outside a VTIMEZONE, 1 directly inside one, 2 or more inside one of its sub-components.
        var depth = 0
        var tzid: String?
        var location: String?
        // The line directly inside a VTIMEZONE whose continuation lines are being joined.
        var logical: String?

        func read(_ line: String) {
            guard let colon = Self.valueColon(line) else { return }
            let name = line[..<colon].prefix(while: { $0 != ";" }).uppercased()
            let value = CalendarTimeZoneResolver.unquoted(String(line[line.index(after: colon)...]))
            if name == "TZID" {
                tzid = value
            } else if name == "X-LIC-LOCATION" {
                location = value
            }
        }

        for physical in calendarText.split(whereSeparator: \.isNewline) {
            if let first = physical.first, first == " " || first == "\t" {
                logical?.append(contentsOf: physical.dropFirst())
                continue
            }
            if let pending = logical {
                read(pending)
                logical = nil
            }
            let line = physical.trimmingCharacters(in: .whitespaces)
            let upper = line.prefix(6).uppercased()
            let isBegin = upper == "BEGIN:"
            let isEnd = upper.hasPrefix("END:")
            switch depth {
            case 0:
                if isBegin, line.dropFirst(6).uppercased() == "VTIMEZONE" {
                    depth = 1
                    tzid = nil
                    location = nil
                }
            case 1:
                if isBegin {
                    depth = 2
                } else if isEnd {
                    guard line.dropFirst(4).uppercased() == "VTIMEZONE" else { continue }
                    depth = 0
                    if let tzid, !tzid.isEmpty, !defined.contains(tzid) {
                        defined.insert(tzid)
                        if let location, !location.isEmpty { locations[tzid] = location }
                    }
                } else {
                    logical = line
                }
            default:
                if isBegin { depth += 1 } else if isEnd { depth -= 1 }
            }
        }
        self.locations = locations
    }

    /// The colon that ends a content line's name and parameters: the first one outside a quoted
    /// parameter value.
    private static func valueColon(_ line: String) -> String.Index? {
        var quoted = false
        for index in line.indices {
            let character = line[index]
            if character == "\"" { quoted.toggle() }
            if character == ":", !quoted { return index }
        }
        return nil
    }
}
