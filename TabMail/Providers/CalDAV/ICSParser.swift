/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Parses VCALENDAR/VEVENT ICS text into GCalEvent models.
/// Uses ICSBuilder's existing parseICSDate and unescapeText logic for consistency.
enum ICSParser {

    /// Parse a VCALENDAR string (potentially containing multiple VEVENTs) into GCalEvent(s).
    /// For recurring events with exceptions, returns only the master VEVENT (no RECURRENCE-ID).
    /// `resourceHref` is used as the event ID (for CalDAV GET/PUT/DELETE operations).
    /// `etag` is stored for conflict detection on updates.
    static func parse(icsText: String, resourceHref: String, etag: String?) -> [GCalEvent] {
        let unfolded = unfold(icsText)
        let lines = unfolded.components(separatedBy: .newlines)

        var events: [GCalEvent] = []
        var inEvent = false
        var eventLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "BEGIN:VEVENT" {
                inEvent = true
                eventLines = []
                continue
            }
            if trimmed == "END:VEVENT" {
                inEvent = false
                if let event = parseVEvent(lines: eventLines, resourceHref: resourceHref, etag: etag) {
                    events.append(event)
                }
                continue
            }
            if inEvent {
                eventLines.append(trimmed)
            }
        }

        // For Phase 1: return only the master VEVENT (no RECURRENCE-ID)
        let master = events.filter { event in
            // Master events don't have recurrence-id info embedded
            // We check via the original lines for RECURRENCE-ID
            true // All events parsed without RECURRENCE-ID filtering for now
        }

        // If we have events with and without recurrence info, prefer the master
        if master.count > 1 {
            return [master[0]]
        }
        return master
    }

    // MARK: - Private

    private static func parseVEvent(lines: [String], resourceHref: String, etag: String?) -> GCalEvent? {
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
        var hasRecurrenceId = false

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
            } else if line.hasPrefix("EXDATE") {
                recurrence.append(line)
            } else if line.hasPrefix("RDATE") {
                recurrence.append(line)
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
                hasRecurrenceId = true
            }
        }

        // Skip recurrence exceptions (Phase 1)
        if hasRecurrenceId { return nil }

        // Parse dates
        let isAllDay = dtstartParams?.contains("VALUE=DATE") == true
            || (dtstart.map { $0.count == 8 } ?? false)

        let startDate = dtstart.flatMap { parseICSDate($0, params: dtstartParams) }
        var endDate = dtend.flatMap { parseICSDate($0, params: dtendParams) }

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

        return GCalEvent(
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

    private static func unfold(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
    }

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

    private static func extractTZID(_ params: String) -> String? {
        for part in params.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces).uppercased() == "TZID" {
                return String(kv[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func parseICSDate(_ value: String, params: String?) -> Date? {
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
        if let params, let tzid = extractTZID(params) {
            fmt.timeZone = TimeZone(identifier: tzid) ?? .current
        } else {
            fmt.timeZone = .current
        }
        return fmt.date(from: cleaned)
    }

    private static func icsDateToRFC3339(_ icsDate: String) -> String? {
        guard let date = parseICSDate(icsDate, params: nil) else { return nil }
        return date.iso8601String()
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

    private static func unescapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
