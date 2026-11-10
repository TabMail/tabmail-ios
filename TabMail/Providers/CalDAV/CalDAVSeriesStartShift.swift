/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Moving a repeating series' start moves everything tied to it.
///
/// RFC 5545 matches an `EXDATE`, an `RDATE` and an override's `RECURRENCE-ID`
/// against an occurrence's start, and a date-time `UNTIL` bounds the last
/// occurrence by its start. So when an edit moves the master's `DTSTART`, each
/// of those values has to move with it: otherwise a deleted occurrence comes
/// back at the new time, a changed occurrence no longer names any occurrence,
/// and the series loses its last occurrence. Thunderbird moves the same values
/// when a series' start changes, and leaves an override's own `DTSTART` and
/// `DTEND` where the user put them; so does this.
///
/// The move is whole days plus the wall-clock difference, measured in the
/// series' own frame, never an absolute duration: a weekly 10:00 series moved
/// by one week across a daylight-saving change still repeats at 10:00, and the
/// values tied to it must stay at 10:00 too.
extension CalDAVProvider {

    /// Seconds in a calendar day of wall-clock arithmetic.
    static let wallSecondsPerDay = 86_400

    /// A DATE or DATE-TIME value as written in the resource: the wall clock it
    /// names and the frame that gives that wall clock its meaning.
    struct ICSWallTime: Equatable {
        /// `.allDay` for a `VALUE=DATE` day, `.utc` for a trailing `Z`,
        /// `.floating` for no zone, `.zoned` for a `TZID` as written (which may
        /// name a zone this device does not know).
        var frame: MasterDTStartKind
        /// The wall clock as seconds from 1970-01-01T00:00:00, read as if it
        /// were UTC, so integer arithmetic on it moves the wall clock.
        var wall: Int
    }

    /// The change an edit makes to a series' start, from the master's `DTSTART`
    /// before the edit (`old`) to after it (`new`).
    struct SeriesStartShift {
        let old: ICSWallTime
        let new: ICSWallTime
        /// The zone context of the resource the series is in, for a value that has to move
        /// through its instant.
        let zones: CalendarTimeZoneContext

        /// Whole days plus the wall-clock difference, each start read in its
        /// own frame.
        var delta: Int { new.wall - old.wall }

        /// Whole calendar days between the two starts' dates.
        var days: Int {
            CalDAVProvider.dayNumber(new.wall) - CalDAVProvider.dayNumber(old.wall)
        }

        /// Where `value` goes when the series' start moves.
        ///
        /// - A calendar date moves by whole days.
        /// - A value written in the series' own frame moves its wall clock and
        ///   is written in the new start's frame (Thunderbird also re-expresses
        ///   it there). This needs no zone data, so a `TZID` this device does
        ///   not know is no obstacle.
        /// - In an all-day or floating series, or for a floating value, there is
        ///   no instant to convert through, so the value's own wall clock moves.
        /// - A value in another zone is read in the series' frame through its
        ///   instant, moved there, and written back in its own zone. If a zone
        ///   that takes is unknown, the move is refused rather than guessed.
        func moved(_ value: ICSWallTime) throws -> ICSWallTime {
            if value.frame == .allDay {
                return ICSWallTime(frame: .allDay, wall: value.wall + days * CalDAVProvider.wallSecondsPerDay)
            }
            if value.frame == old.frame {
                return ICSWallTime(frame: new.frame, wall: value.wall + delta)
            }
            guard CalDAVProvider.namesAnInstant(old.frame), CalDAVProvider.namesAnInstant(value.frame) else {
                return ICSWallTime(frame: value.frame, wall: value.wall + delta)
            }
            let own = try CalDAVProvider.knownZone(value.frame, zones: zones)
            let seriesBefore = try CalDAVProvider.knownZone(old.frame, zones: zones)
            let seriesAfter = try CalDAVProvider.knownZone(new.frame, zones: zones)
            guard let instant = CalDAVProvider.instant(ofWall: value.wall, in: own),
                  let seriesWall = CalDAVProvider.wall(of: instant, in: seriesBefore),
                  let movedInstant = CalDAVProvider.instant(ofWall: seriesWall + delta, in: seriesAfter),
                  let movedWall = CalDAVProvider.wall(of: movedInstant, in: own) else {
                throw CalendarProviderError.notSupported(
                    "TabMail could not work out where this event's \(CalDAVProvider.renderICSWallTime(value)) goes when its time changes, so it did not change the event. Change the time in your calendar app instead.")
            }
            return ICSWallTime(frame: value.frame, wall: movedWall)
        }
    }

    // MARK: - Applying the shift

    /// The master `DTSTART`'s value, or nil when the master has none.
    /// Throws when it is present but is not a DATE or DATE-TIME RFC 5545
    /// allows: nothing tied to the start could then be moved correctly.
    static func masterStartWallTime(in ics: String) throws -> ICSWallTime? {
        guard let line = masterVEventLines(from: ics).first(where: { $0.uppercased().hasPrefix("DTSTART") }) else {
            return nil
        }
        guard let property = ICSProperty(line),
              let value = parseICSWallTime(property.value, tzid: property.tzid, isDate: ICSValueType.statesDate(property.head)) else {
            throw CalendarProviderError.notSupported(
                "TabMail could not read this event's start time, so it did not change the series. Change the time in your calendar app instead.")
        }
        return value
    }

    /// Move every value RFC 5545 ties to the series' start: the master's
    /// `EXDATE` and `RDATE` values and, when `moveUntil`, its `RRULE`'s
    /// `UNTIL`, and each override's `RECURRENCE-ID`. When `moveEnd`, the
    /// master's `DTEND` moves the same way, so an event whose start moves
    /// keeps its length (in days for an all-day event, on the wall clock for a
    /// timed one); a master with `DURATION` and no `DTEND` has nothing to move.
    /// Only a VEVENT's own
    /// properties are read; a VTIMEZONE's `RDATE`/`RRULE` and a VALARM belong
    /// to something else. A property whose values do not change keeps its
    /// exact bytes, folding included; a rewritten one is written on one line,
    /// like every other property this merge writes.
    static func shiftSeriesAnchoredValues(in ics: String, by shift: SeriesStartShift, moveUntil: Bool, moveEnd: Bool) throws -> String {
        let lines = physicalICSLines(ics)
        var output: [String] = []
        var handledMaster = false
        var i = 0
        while i < lines.count {
            guard lines[i] == "BEGIN:VEVENT" else {
                output.append(lines[i]); i += 1; continue
            }
            var block: [String] = [lines[i]]
            i += 1
            while i < lines.count && lines[i] != "END:VEVENT" {
                block.append(lines[i])
                i += 1
            }
            if i < lines.count { block.append(lines[i]); i += 1 }

            let names: Set<String>
            if block.contains(where: { $0.hasPrefix("RECURRENCE-ID") }) {
                names = ["RECURRENCE-ID"]
            } else if !handledMaster {
                // The master is the first VEVENT with no RECURRENCE-ID, as in
                // every other helper of this merge.
                var master: Set<String> = ["EXDATE", "RDATE"]
                if moveUntil { master.insert("RRULE") }
                if moveEnd { master.insert("DTEND") }
                names = master
                handledMaster = true
            } else {
                names = []
            }
            output.append(contentsOf: try shiftProperties(named: names, in: block, by: shift))
        }
        return output.joined(separator: "\r\n")
    }

    private static func shiftProperties(named names: Set<String>, in block: [String], by shift: SeriesStartShift) throws -> [String] {
        guard !names.isEmpty else { return block }
        var output: [String] = []
        // Depth of components nested in the VEVENT (a VALARM): their lines are
        // not the event's. The block's own BEGIN:VEVENT is index 0.
        var depth = 0
        var j = 0
        while j < block.count {
            var end = j + 1
            while end < block.count, let first = block[end].first, first == " " || first == "\t" {
                end += 1
            }
            let physical = Array(block[j..<end])
            let isFirst = j == 0
            j = end

            let upper = physical[0].uppercased()
            if !isFirst && upper.hasPrefix("BEGIN:") { depth += 1 }
            if upper.hasPrefix("END:") { depth -= 1 }

            // RFC 5545 §3.1 unfolding: a continuation drops its leading space or tab.
            let logical = physical[0] + physical.dropFirst().map { String($0.dropFirst()) }.joined()
            if depth == 0, let property = ICSProperty(logical), names.contains(property.name),
               let rewritten = try shifted(property, by: shift), rewritten != logical {
                output.append(rewritten)
            } else {
                output.append(contentsOf: physical)
            }
        }
        return output
    }

    /// `property` with its values moved, or nil when it carries none to move.
    private static func shifted(_ property: ICSProperty, by shift: SeriesStartShift) throws -> String? {
        if property.name == "RRULE" {
            var changed = false
            let parts = try property.value.split(separator: ";", omittingEmptySubsequences: false).map { part -> String in
                guard part.uppercased().hasPrefix("UNTIL=") else { return String(part) }
                let text = String(part.dropFirst("UNTIL=".count))
                let moved = try shift.moved(try readValue(text, property: property, tzid: nil, isDate: false))
                changed = true
                return "UNTIL=" + renderICSWallTime(moved)
            }
            return changed ? property.head + ":" + parts.joined(separator: ";") : nil
        }

        let isDate = ICSValueType.statesDate(property.head)
        var movedZone: String?
        func move(_ text: String) throws -> String {
            let moved = try shift.moved(try readValue(text, property: property, tzid: property.tzid, isDate: isDate))
            if case .zoned(let tzid) = moved.frame { movedZone = tzid }
            return renderICSWallTime(moved)
        }
        let values = try property.value.split(separator: ",", omittingEmptySubsequences: false).map { item -> String in
            let text = String(item)
            guard property.valueType == "PERIOD" else { return try move(text) }
            // A PERIOD is start/end or start/duration; a duration does not move.
            let halves = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard halves.count == 2 else { return try move(text) }
            let end = halves[1]
            let isDuration = end.hasPrefix("P") || end.hasPrefix("+") || end.hasPrefix("-")
            return try move(halves[0]) + "/" + (isDuration ? end : move(end))
        }
        var head = property.head
        if let movedZone, let tzid = property.tzid, movedZone != tzid {
            head = property.headReplacingTZID(with: movedZone)
        }
        return head + ":" + values.joined(separator: ",")
    }

    private static func readValue(_ text: String, property: ICSProperty, tzid: String?, isDate: Bool) throws -> ICSWallTime {
        guard let value = parseICSWallTime(text, tzid: tzid, isDate: isDate) else {
            throw CalendarProviderError.notSupported(
                "TabMail could not read this event's \(property.name) value \"\(text)\", so it did not change the event's time. Change the time in your calendar app instead.")
        }
        return value
    }

    // MARK: - Values

    /// One value of a DATE or DATE-TIME property. `tzid` is the line's `TZID`
    /// parameter and `isDate` its `VALUE=DATE`. Nil when the text is not a
    /// value RFC 5545 allows.
    static func parseICSWallTime(_ text: String, tzid: String?, isDate: Bool) -> ICSWallTime? {
        let upper = text.uppercased()
        if isDate || (upper.count == 8 && !upper.contains("T")) {
            guard upper.count == 8, let wall = wallSeconds(upper, format: "yyyyMMdd") else { return nil }
            return ICSWallTime(frame: .allDay, wall: wall)
        }
        let isUTC = upper.hasSuffix("Z")
        let digits = isUTC ? String(upper.dropLast()) : upper
        guard digits.count == 15, let wall = wallSeconds(digits, format: "yyyyMMdd'T'HHmmss") else { return nil }
        if isUTC { return ICSWallTime(frame: .utc, wall: wall) }
        if let tzid, !tzid.isEmpty { return ICSWallTime(frame: .zoned(tzid), wall: wall) }
        return ICSWallTime(frame: .floating, wall: wall)
    }

    static func renderICSWallTime(_ value: ICSWallTime) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(value.wall))
        switch value.frame {
        case .allDay: return wallFormatter("yyyyMMdd").string(from: date)
        case .utc: return wallFormatter("yyyyMMdd'T'HHmmss").string(from: date) + "Z"
        case .floating, .zoned: return wallFormatter("yyyyMMdd'T'HHmmss").string(from: date)
        }
    }

    private static func wallSeconds(_ text: String, format: String) -> Int? {
        let formatter = wallFormatter(format)
        // The round trip rejects anything the formatter would read leniently.
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return Int(date.timeIntervalSince1970)
    }

    private static func wallFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = format
        return formatter
    }

    /// The calendar day a wall clock falls on, counted from 1970-01-01
    /// (floor division, so dates before 1970 count correctly).
    static func dayNumber(_ wall: Int) -> Int {
        let days = wall / wallSecondsPerDay
        return wall % wallSecondsPerDay < 0 ? days - 1 : days
    }

    private static func namesAnInstant(_ frame: MasterDTStartKind) -> Bool {
        switch frame {
        case .utc, .zoned: return true
        case .allDay, .floating: return false
        }
    }

    /// The zone a timed frame's wall clock is read in (`CalendarTimeZoneResolver`,
    /// through the resource's zone context). Throws for a `TZID` TabMail does not
    /// recognize: converting through a guessed zone would write a value no
    /// occurrence has.
    private static func knownZone(_ frame: MasterDTStartKind, zones: CalendarTimeZoneContext) throws -> TimeZone {
        switch frame {
        case .zoned(let tzid):
            guard let zone = CalendarTimeZoneResolver.zone(named: tzid, in: zones) else {
                throw CalendarProviderError.unrecognizedTimeZone(
                    tzid, consequence: "it could not move the series' deleted and changed occurrences with it and did not change the event")
            }
            return zone
        case .utc, .allDay, .floating:
            return .gmt
        }
    }

    private static func instant(ofWall wall: Int, in zone: TimeZone) -> Date? {
        var plain = Calendar(identifier: .gregorian)
        plain.timeZone = .gmt
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let parts = plain.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                         from: Date(timeIntervalSince1970: TimeInterval(wall)))
        return local.date(from: parts)
    }

    private static func wall(of instant: Date, in zone: TimeZone) -> Int? {
        var plain = Calendar(identifier: .gregorian)
        plain.timeZone = .gmt
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let parts = local.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        return plain.date(from: parts).map { Int($0.timeIntervalSince1970) }
    }

    // MARK: - Property lines

    /// One unfolded property line split into its name, parameters and value.
    /// The split honours quoted parameter values, which may hold `:` and `;`.
    struct ICSProperty {
        /// Upper-cased property name.
        let name: String
        /// Everything before the value's `:`, exactly as written.
        let head: String
        /// Parameters as written, without the name.
        let parameters: [String]
        let value: String

        init?(_ line: String) {
            guard let colon = Self.firstIndex(of: ":", outsideQuotesIn: line) else { return nil }
            let headText = String(line[..<colon])
            var pieces = Self.split(headText, on: ";")
            guard !pieces.isEmpty else { return nil }
            head = headText
            value = String(line[line.index(after: colon)...])
            name = pieces.removeFirst().uppercased()
            parameters = pieces
        }

        /// The `TZID` parameter's value, without quotes.
        var tzid: String? {
            parameter("TZID").map { $0.replacingOccurrences(of: "\"", with: "") }
        }

        /// The upper-cased `VALUE` parameter, when present.
        var valueType: String? { parameter("VALUE")?.uppercased() }

        func headReplacingTZID(with tzid: String) -> String {
            let needsQuotes = tzid.contains(where: { $0 == ":" || $0 == ";" || $0 == "," })
            let written = needsQuotes ? "\"\(tzid)\"" : tzid
            let rewritten = parameters.map { $0.uppercased().hasPrefix("TZID=") ? "TZID=\(written)" : $0 }
            return ([String(head.prefix(while: { $0 != ";" && $0 != ":" }))] + rewritten).joined(separator: ";")
        }

        private func parameter(_ key: String) -> String? {
            let prefix = key + "="
            return parameters.first(where: { $0.uppercased().hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
        }

        private static func firstIndex(of separator: Character, outsideQuotesIn text: String) -> String.Index? {
            var quoted = false
            for index in text.indices {
                if text[index] == "\"" { quoted.toggle() }
                if !quoted && text[index] == separator { return index }
            }
            return nil
        }

        private static func split(_ text: String, on separator: Character) -> [String] {
            var pieces: [String] = []
            var current = ""
            var quoted = false
            for character in text {
                if character == "\"" { quoted.toggle() }
                if !quoted && character == separator {
                    pieces.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }
            pieces.append(current)
            return pieces
        }
    }
}
