/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Parses VCALENDAR/VEVENT ICS text into GCalEvent models.
/// Uses ICSBuilder's existing parseICSDate and unescapeText logic for consistency.
enum ICSParser {

    /// The SERIES view of a calendar object resource: its master VEVENT (the
    /// first one with no RECURRENCE-ID) as one event, or nothing when the
    /// resource has no master. A repeating event comes back once, at its first
    /// date, with its rule in `recurrence`; its changed occurrences are not
    /// returned. `getEvent` by a series id and a split's read-back use this.
    /// A listing must not: it lists occurrences (`CalDAVOccurrences.listing`).
    /// `resourceHref` is used as the event ID (for CalDAV GET/PUT/DELETE operations).
    static func parse(icsText: String, resourceHref: String, etag: String?) -> [GCalEvent] {
        guard let master = components(icsText: icsText, resourceHref: resourceHref)
            .first(where: { $0.recurrenceId == nil }) else { return [] }
        return [master.event]
    }

    /// A property's parameters (the text between the name and the colon, without
    /// the leading `;`) and its value, as written.
    struct PropertyValue: Sendable {
        let params: String?
        let value: String
    }

    /// One VEVENT of a resource: the app's event model of it (id = the resource
    /// href), plus the parts a recurrence expansion needs.
    struct VEventComponent: Sendable {
        let event: GCalEvent
        let dtstart: PropertyValue?
        let dtend: PropertyValue?
        /// The DURATION value, when the VEVENT gives one instead of a DTEND.
        let duration: String?
        let isAllDay: Bool
        let startDate: Date?
        let endDate: Date?
        /// The values of the RRULE lines (without `RRULE:`).
        let rrules: [String]
        let hasExRule: Bool
        let rdates: [PropertyValue]
        let exdates: [PropertyValue]
        /// Set on an override (a changed or cancelled occurrence), nil on the master.
        let recurrenceId: PropertyValue?
        /// The zone context of the resource the VEVENT is in, so a recurrence
        /// expansion reads its wall times through the same resolver this parser does.
        let zones: CalendarTimeZoneContext
    }

    /// Every VEVENT in the resource, masters and overrides, in document order.
    ///
    /// Each VEVENT is read as the writer reads it (`CalDAVProvider.icsUnits`, `veventBlocks`,
    /// `topLevel`): its own properties only. A nested component's lines belong to that component,
    /// so a VALARM's `DESCRIPTION`, `SUMMARY`, `ATTENDEE` or `DURATION` is never read as the
    /// event's notes, title, attendee or length (#603).
    static func components(icsText: String, resourceHref: String) -> [VEventComponent] {
        // What the resource's VTIMEZONE components say about its zone names, read once for all its events.
        let zones = CalendarTimeZoneContext(calendarText: icsText)
        return CalDAVProvider.veventBlocks(CalDAVProvider.icsUnits(icsText)).map { block in
            let lines = CalDAVProvider.topLevel(block).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            return parseVEvent(lines: lines, resourceHref: resourceHref, zones: zones)
        }
    }

    // MARK: - Private

    /// `zones` is the zone context of the resource the event is in.
    private static func parseVEvent(lines: [String], resourceHref: String, zones: CalendarTimeZoneContext) -> VEventComponent {
        var summary = ""
        var location: String?
        var description: String?
        var dtstart: String?
        var dtstartParams: String?
        var dtend: String?
        var dtendParams: String?
        var duration: String?
        var recurrence: [String] = []
        var transparency: String?
        var status: String?
        var organizerLine: String?
        var attendeeLines: [String] = []
        var created: String?
        var lastModified: String?
        var url: String?
        var recurrenceId: PropertyValue?
        var rrules: [String] = []
        var hasExRule = false
        var rdates: [PropertyValue] = []
        var exdates: [PropertyValue] = []

        for line in lines {
            if line.hasPrefix("SUMMARY") {
                summary = unescapeText(extractValue(line))
            } else if line.hasPrefix("LOCATION") {
                location = unescapeText(extractValue(line))
            } else if line.hasPrefix("DESCRIPTION") {
                description = unescapeText(extractValue(line))
            } else if line.hasPrefix("DTSTART") {
                let (params, val) = splitPropertyLine(line)
                dtstart = val
                dtstartParams = params
            } else if line.hasPrefix("DTEND") {
                let (params, val) = splitPropertyLine(line)
                dtend = val
                dtendParams = params
            } else if line.hasPrefix("DURATION") {
                duration = extractValue(line)
            } else if line.hasPrefix("RRULE:") {
                recurrence.append(line)
                rrules.append(String(line.dropFirst("RRULE:".count)))
            } else if line.hasPrefix("EXRULE") {
                hasExRule = true
            } else if line.hasPrefix("EXDATE") {
                recurrence.append(line)
                let (params, val) = splitPropertyLine(line)
                exdates.append(PropertyValue(params: params, value: val))
            } else if line.hasPrefix("RDATE") {
                recurrence.append(line)
                let (params, val) = splitPropertyLine(line)
                rdates.append(PropertyValue(params: params, value: val))
            } else if line.hasPrefix("TRANSP") {
                transparency = extractValue(line).lowercased() == "transparent" ? "transparent" : "opaque"
            } else if line.hasPrefix("STATUS") {
                let s = extractValue(line).uppercased()
                switch s {
                case "TENTATIVE": status = "tentative"
                case "CONFIRMED": status = "confirmed"
                case "CANCELLED": status = "cancelled"
                default: status = s.lowercased()
                }
            } else if line.hasPrefix("ORGANIZER") {
                organizerLine = line
            } else if line.hasPrefix("ATTENDEE") {
                attendeeLines.append(line)
            } else if line.hasPrefix("CREATED") {
                created = extractValue(line)
            } else if line.hasPrefix("LAST-MODIFIED") {
                lastModified = extractValue(line)
            } else if line.hasPrefix("URL") {
                url = extractValue(line)
            } else if line.hasPrefix("RECURRENCE-ID") {
                let (params, val) = splitPropertyLine(line)
                recurrenceId = PropertyValue(params: params, value: val)
            }
        }

        // Parse dates
        let isAllDay = dtstartParams.map { ICSValueType.statesDate($0) } == true
            || (dtstart.map { $0.count == 8 } ?? false)

        let startDate = dtstart.flatMap { parseICSDate($0, params: dtstartParams, zones: zones) }
        var endDate = dtend.flatMap { parseICSDate($0, params: dtendParams, zones: zones) }

        // Compute end from duration if DTEND not present
        if endDate == nil, let dur = duration, let start = startDate {
            endDate = addDuration(dur, to: start)
        }

        let start = makeGCalDateTime(date: startDate, raw: dtstart, params: dtstartParams, isAllDay: isAllDay)
        let end = makeGCalDateTime(date: endDate, raw: dtend ?? dtstart, params: dtendParams ?? dtstartParams, isAllDay: isAllDay)

        // Parse organizer
        let organizer: GCalOrganizer? = organizerLine.flatMap { line in
            guard let participant = parseParticipant(line) else { return nil }
            return GCalOrganizer(email: participant.email, displayName: participant.name.isEmpty ? nil : participant.name, self: false)
        }

        // Parse attendees
        let attendees: [GCalAttendee] = attendeeLines.compactMap { line in
            guard let participant = parseParticipant(line) else { return nil }
            let partstat = extractParam(line, name: "PARTSTAT")?.lowercased()
            let responseStatus: String?
            switch partstat {
            case "accepted": responseStatus = "accepted"
            case "declined": responseStatus = "declined"
            case "tentative": responseStatus = "tentative"
            default: responseStatus = "needsAction"
            }
            return GCalAttendee(
                email: participant.email,
                displayName: participant.name.isEmpty ? nil : participant.name,
                responseStatus: responseStatus,
                organizer: false,
                self: false
            )
        }

        // Convert ICS datetime to RFC 3339 for created/updated
        let createdRFC = created.flatMap { icsDateToRFC3339($0) }
        let updatedRFC = lastModified.flatMap { icsDateToRFC3339($0) }

        let event = GCalEvent(
            id: resourceHref,
            summary: summary.isEmpty ? nil : summary,
            location: location,
            description: description,
            start: start,
            end: end,
            attendees: attendees.isEmpty ? nil : attendees,
            organizer: organizer,
            recurrence: recurrence.isEmpty ? nil : recurrence,
            transparency: transparency,
            status: status ?? "confirmed",
            htmlLink: url,
            created: createdRFC,
            updated: updatedRFC
        )
        return VEventComponent(
            event: event,
            dtstart: dtstart.map { PropertyValue(params: dtstartParams, value: $0) },
            dtend: dtend.map { PropertyValue(params: dtendParams, value: $0) },
            duration: duration,
            isAllDay: isAllDay,
            startDate: startDate,
            endDate: endDate,
            rrules: rrules,
            hasExRule: hasExRule,
            rdates: rdates,
            exdates: exdates,
            recurrenceId: recurrenceId,
            zones: zones
        )
    }

    private static func makeGCalDateTime(date: Date?, raw: String?, params: String?, isAllDay: Bool) -> GCalDateTime? {
        guard date != nil || raw != nil else { return nil }
        if isAllDay {
            let dateStr = raw.map { String($0.prefix(8)) } ?? ""
            let formatted = dateStr.count == 8
                ? "\(dateStr.prefix(4))-\(dateStr.dropFirst(4).prefix(2))-\(dateStr.suffix(2))"
                : nil
            return GCalDateTime(dateTime: nil, date: formatted, timeZone: nil)
        }
        if let date {
            let tz = params.flatMap { extractTZID($0) }
            return GCalDateTime(dateTime: date.iso8601String(), date: nil, timeZone: tz)
        }
        return nil
    }

    // MARK: - ICS Helpers (reuse ICSBuilder patterns)

    private static func extractValue(_ line: String) -> String {
        // Find the colon separating property+params from value
        var inQuote = false
        for (i, ch) in line.enumerated() {
            if ch == "\"" { inQuote.toggle() }
            if ch == ":" && !inQuote {
                return String(line[line.index(line.startIndex, offsetBy: i + 1)...])
            }
        }
        return line
    }

    private static func splitPropertyLine(_ line: String) -> (params: String?, value: String) {
        var inQuote = false
        for (i, ch) in line.enumerated() {
            if ch == "\"" { inQuote.toggle() }
            if ch == ":" && !inQuote {
                let before = String(line[line.startIndex..<line.index(line.startIndex, offsetBy: i)])
                let value = String(line[line.index(line.startIndex, offsetBy: i + 1)...])
                if let semiIdx = before.firstIndex(of: ";") {
                    return (String(before[before.index(after: semiIdx)...]), value)
                }
                return (nil, value)
            }
        }
        return (nil, line)
    }

    private static func extractParam(_ line: String, name: String) -> String? {
        // Find the params portion (before the colon)
        var inQuote = false
        var colonIdx: String.Index?
        for (i, ch) in line.enumerated() {
            if ch == "\"" { inQuote.toggle() }
            if ch == ":" && !inQuote {
                colonIdx = line.index(line.startIndex, offsetBy: i)
                break
            }
        }
        guard let colonIdx else { return nil }
        let params = String(line[line.startIndex..<colonIdx])

        for part in params.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces).uppercased() == name.uppercased() {
                return String(kv[1]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    static func extractTZID(_ params: String) -> String? {
        for part in params.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces).uppercased() == "TZID" {
                return String(kv[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func parseICSDate(_ value: String, params: String?, zones: CalendarTimeZoneContext) -> Date? {
        let cleaned = value.trimmingCharacters(in: .whitespaces)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")

        if cleaned.hasSuffix("Z") {
            fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            fmt.timeZone = TimeZone(identifier: "UTC")
            return fmt.date(from: cleaned)
        }
        if cleaned.count == 8 {
            fmt.dateFormat = "yyyyMMdd"
            fmt.timeZone = .current
            return fmt.date(from: cleaned)
        }
        fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        fmt.timeZone = wallTimeZone(params: params, zones: zones)
        return fmt.date(from: cleaned)
    }

    /// The zone this parser reads a DATE-TIME's wall time in: the zone the TZID
    /// the parameters name resolves to (`CalendarTimeZoneResolver`, in the
    /// resource's context `zones`), else the device's (a floating time). The
    /// recurrence expansion reads its wall times in the same zone, so a series'
    /// occurrences line up with its first date.
    ///
    /// A read never refuses. A zone the resolver does not recognize (one a VTIMEZONE defines
    /// only by its rules, say) is read in the device's zone, so the event is still shown; that
    /// reading is wrong whenever the two zones differ. Writes of such an event are refused
    /// instead (`CalDAVProvider.zone(forTZID:zones:)`).
    static func wallTimeZone(params: String?, zones: CalendarTimeZoneContext) -> TimeZone {
        guard let params, let tzid = extractTZID(params) else { return .current }
        return CalendarTimeZoneResolver.zone(named: tzid, in: zones) ?? .current
    }

    private static func icsDateToRFC3339(_ icsDate: String) -> String? {
        // No parameters, so no zone name to read.
        guard let date = parseICSDate(icsDate, params: nil, zones: .none) else { return nil }
        return date.iso8601String()
    }

    /// The `DTEND` value RFC 5545 §3.6.1 gives a VEVENT that has neither `DTEND` nor `DURATION`,
    /// in the start's own form, so it pairs with the `DTSTART` parameters (`DTEND<params>:<value>`):
    /// a start that is a date lasts that one day, so the end is the next date; a start that is a
    /// date-time lasts no time, so the end is the start. Nil when a date start can't be read.
    ///
    /// The one place for this rule. `CalDAVProvider.extractMasterDuration` and
    /// `CalDAVProvider.effectiveEnd` use it; any other reader of a VEVENT's end should too.
    static func impliedEndValue(dtstartParams: String?, dtstartValue: String) -> String? {
        let value = dtstartValue.trimmingCharacters(in: .whitespaces)
        let isDate = ICSValueType.statesDate(dtstartParams ?? "")
            || (value.count == 8 && !value.contains("T"))
        guard isDate else { return value }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd"
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let day = fmt.date(from: value), let next = utc.date(byAdding: .day, value: 1, to: day) else { return nil }
        return fmt.string(from: next)
    }

    /// Parse ISO 8601 duration (e.g., PT1H30M, P1D) and add to a date.
    ///
    /// Internal rather than private because it is the tree's ONLY RFC 5545
    /// `DURATION` parser and `CalDAVProvider.extractMasterDuration` reuses it
    /// for the `DTSTART` + `DURATION` form of a VEVENT. A second copy is how
    /// two spellings of one grammar drift apart.
    static func addDuration(_ duration: String, to date: Date) -> Date? {
        var d = duration
        guard d.hasPrefix("P") else { return nil }
        d = String(d.dropFirst())

        var totalSeconds = 0
        var inTime = false
        var num = ""

        for ch in d {
            if ch == "T" {
                inTime = true
                continue
            }
            if ch.isNumber {
                num.append(ch)
                continue
            }
            guard let val = Int(num) else { num = ""; continue }
            if inTime {
                switch ch {
                case "H": totalSeconds += val * 3600
                case "M": totalSeconds += val * 60
                case "S": totalSeconds += val
                default: break
                }
            } else {
                switch ch {
                case "W": totalSeconds += val * 7 * 86400
                case "D": totalSeconds += val * 86400
                default: break
                }
            }
            num = ""
        }

        return date.addingTimeInterval(TimeInterval(totalSeconds))
    }

    private static func parseParticipant(_ line: String) -> (name: String, email: String)? {
        // Extract email from mailto: URI
        guard let mailtoRange = line.range(of: "mailto:", options: .caseInsensitive) else { return nil }
        let email = String(line[mailtoRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return nil }

        // Extract CN parameter
        var name = ""
        let quotedCN = /CN="([^"]+)"/
        let unquotedCN = /CN=([^";:]+)/
        if let match = line.firstMatch(of: quotedCN) {
            name = String(match.1).trimmingCharacters(in: .whitespaces)
        } else if let match = line.firstMatch(of: unquotedCN) {
            name = String(match.1).trimmingCharacters(in: .whitespaces)
        }

        return (name: name, email: email)
    }

    static func unescapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
