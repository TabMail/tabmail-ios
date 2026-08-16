/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Generates RFC 5545 ICS (iCalendar) strings for calendar invitations.
/// Used when the agent creates/edits events with attendees — iOS EventKit
/// cannot set attendees programmatically, so we generate an ICS and send
/// it as a `text/calendar; method=REQUEST` email attachment via OutboxMessage.
enum ICSBuilder {
    struct Attendee: Sendable {
        let email: String
        let name: String?
    }

    struct Organizer: Sendable {
        let email: String
        let name: String
    }

    struct EventSpec: Sendable {
        let uid: String
        let title: String
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
        let location: String?
        let description: String?
        let organizer: Organizer
        let attendees: [Attendee]
        /// 0 for new events, incremented for edits. RFC 5545 §3.8.7.4.
        var sequence: Int = 0
    }

    /// Build a `METHOD:REQUEST` VCALENDAR string for sending calendar invitations.
    static func buildInvitation(_ spec: EventSpec) -> String {
        var lines: [String] = []

        lines.append("BEGIN:VCALENDAR")
        lines.append("VERSION:2.0")
        lines.append("PRODID:-//TabMail//TabMail iOS//EN")
        lines.append("CALSCALE:GREGORIAN")
        lines.append("METHOD:REQUEST")

        lines.append("BEGIN:VEVENT")
        lines.append("UID:\(spec.uid)")
        lines.append("DTSTAMP:\(formatUTC(Date()))")
        lines.append("SEQUENCE:\(spec.sequence)")

        if spec.isAllDay {
            lines.append("DTSTART;VALUE=DATE:\(formatDateOnly(spec.startDate))")
            // RFC 5545: all-day DTEND is exclusive.
            // - If start == end (same day): zero-duration → add 1 day for full-day span.
            // - If different days: trust caller (EventKit endDate is already exclusive,
            //   and LLM multi-day end_iso is treated as exclusive by EK).
            let allDayEnd: Date
            if Calendar.current.isDate(spec.startDate, inSameDayAs: spec.endDate) {
                allDayEnd = Calendar.current.date(byAdding: .day, value: 1, to: spec.startDate)!
            } else {
                allDayEnd = spec.endDate
            }
            lines.append("DTEND;VALUE=DATE:\(formatDateOnly(allDayEnd))")
        } else {
            // Use UTC times — avoids needing a VTIMEZONE component (RFC 5545 §3.2.19)
            lines.append("DTSTART:\(formatUTC(spec.startDate))")
            lines.append("DTEND:\(formatUTC(spec.endDate))")
        }

        lines.append("SUMMARY:\(escapeText(spec.title))")

        if let location = spec.location, !location.isEmpty {
            lines.append("LOCATION:\(escapeText(location))")
        }
        if let desc = spec.description, !desc.isEmpty {
            lines.append("DESCRIPTION:\(escapeText(desc))")
        }

        // Organizer
        let orgCN = spec.organizer.name.isEmpty ? spec.organizer.email : spec.organizer.name
        lines.append("ORGANIZER;CN=\"\(escapeParam(orgCN))\":mailto:\(spec.organizer.email)")

        // Attendees
        for attendee in spec.attendees {
            let cn = attendee.name ?? attendee.email
            lines.append("ATTENDEE;CN=\"\(escapeParam(cn))\";RSVP=TRUE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:\(attendee.email)")
        }

        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")

        // RFC 5545 §3.1: content lines SHOULD NOT exceed 75 octets — fold long lines
        let folded = lines.map { foldLine($0) }
        return folded.joined(separator: "\r\n") + "\r\n"
    }

    /// Build a simple HTML body for the invitation email (fallback for clients
    /// that don't render ICS inline).
    static func buildInvitationBody(_ spec: EventSpec) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = spec.isAllDay ? .none : .short

        var html = "<div style=\"font-family: -apple-system, sans-serif; font-size: 14px;\">"
        html += "<h3>\(escapeHTML(spec.title))</h3>"
        html += "<p><strong>When:</strong> \(escapeHTML(dateFormatter.string(from: spec.startDate)))"
        if !spec.isAllDay {
            let endFmt = DateFormatter()
            endFmt.timeStyle = .short
            html += " – \(escapeHTML(endFmt.string(from: spec.endDate)))"
        }
        html += "</p>"
        if let location = spec.location, !location.isEmpty {
            html += "<p><strong>Where:</strong> \(escapeHTML(location))</p>"
        }
        if let desc = spec.description, !desc.isEmpty {
            html += "<p>\(escapeHTML(desc))</p>"
        }
        html += "<p style=\"color: #666; font-size: 12px;\">Sent via TabMail</p>"
        html += "</div>"
        return html
    }

    // MARK: - ICS Date Formatting

    /// UTC timestamp: `YYYYMMDDTHHMMSSZ`
    private static func formatUTC(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    /// Date-only: `YYYYMMDD`
    private static func formatDateOnly(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: date)
    }

    // MARK: - ICS Text Escaping

    /// Escape text content per RFC 5545 §3.3.11.
    /// Backslash-escape commas, semicolons, backslashes, and convert newlines to `\n`.
    private static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Fold a content line at 75 octets per RFC 5545 §3.1.
    /// Continuation lines begin with a single space character.
    private static func foldLine(_ line: String) -> String {
        let maxOctets = 75
        let utf8 = Array(line.utf8)
        guard utf8.count > maxOctets else { return line }
        var result = ""
        var offset = 0
        var isFirst = true
        while offset < utf8.count {
            let limit = isFirst ? maxOctets : maxOctets - 1 // continuation line has leading space
            let end = min(offset + limit, utf8.count)
            // Don't split in the middle of a multi-byte UTF-8 sequence.
            // If the byte at `end` is a continuation byte (10xxxxxx), back up to
            // the lead byte and exclude the entire character from this chunk.
            var safeEnd = end
            if safeEnd < utf8.count {
                while safeEnd > offset && utf8[safeEnd] & 0xC0 == 0x80 {
                    safeEnd -= 1
                }
                // safeEnd now points at the lead byte — exclude it (next chunk gets full char)
            }
            if safeEnd <= offset { safeEnd = end } // safety: advance anyway
            let chunk = String(decoding: utf8[offset..<safeEnd], as: UTF8.self)
            if isFirst {
                result = chunk
                isFirst = false
            } else {
                result += "\r\n " + chunk
            }
            offset = safeEnd
        }
        return result
    }

    /// Escape a parameter value (e.g., CN). Quotes are already provided by caller,
    /// so just escape backslashes and double-quotes inside the value.
    private static func escapeParam(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "'")
    }

    /// Basic HTML escaping for the fallback body.
    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Incoming ICS Parsing

    /// Parsed result from an incoming ICS (calendar invite).
    struct ParsedInvite: Sendable {
        let method: String // REQUEST, REPLY, CANCEL
        let title: String
        let startDate: Date?
        let endDate: Date?
        let isAllDay: Bool
        let location: String?
        let description: String?
        let organizer: (name: String, email: String)?
        let attendees: [(name: String, email: String)]
    }

    /// Parse an incoming ICS text and extract the first VEVENT.
    /// Handles unfolding (RFC 5545 §3.1), common date formats, and parameters.
    static func parseIncoming(_ icsText: String) -> ParsedInvite? {
        // Unfold continuation lines (CRLF + space/tab → join)
        let unfolded = icsText
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")

        let lines = unfolded.components(separatedBy: .newlines)

        var method = "REQUEST"
        var inEvent = false
        var nestedDepth = 0 // Track nested components (VALARM, etc.) to skip their properties
        var title = ""
        var location: String?
        var description: String?
        var dtstart: String?
        var dtstartParams: String?
        var dtend: String?
        var dtendParams: String?
        var organizerLine: String?
        var attendeeLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if trimmed == "BEGIN:VEVENT" { inEvent = true; continue }
            if trimmed == "END:VEVENT" { break }

            // Skip nested components inside VEVENT (e.g., VALARM).
            // Their properties (like DESCRIPTION:REMINDER) must not overwrite event-level ones.
            if inEvent {
                if trimmed.hasPrefix("BEGIN:") { nestedDepth += 1; continue }
                if trimmed.hasPrefix("END:") && nestedDepth > 0 { nestedDepth -= 1; continue }
                if nestedDepth > 0 { continue }
            }

            // Calendar-level properties
            if !inEvent {
                if let val = extractValue(
                    trimmed,
                    property: "METHOD",
                    caseInsensitivePropertyName: true
                ) {
                    method = val.uppercased()
                }
                continue
            }

            // Event-level properties
            if let val = extractValue(trimmed, property: "SUMMARY") {
                title = unescapeText(val)
            } else if let val = extractValue(trimmed, property: "LOCATION") {
                location = unescapeText(val)
            } else if let val = extractValue(trimmed, property: "DESCRIPTION") {
                description = unescapeText(val)
            } else if trimmed.hasPrefix("DTSTART") {
                let (params, val) = splitPropertyLine(trimmed)
                dtstart = val
                dtstartParams = params
            } else if trimmed.hasPrefix("DTEND") {
                let (params, val) = splitPropertyLine(trimmed)
                dtend = val
                dtendParams = params
            } else if trimmed.hasPrefix("ORGANIZER") {
                organizerLine = trimmed
            } else if trimmed.hasPrefix("ATTENDEE") {
                attendeeLines.append(trimmed)
            }
        }

        guard inEvent else { return nil }

        // Parse dates
        let isAllDay = dtstartParams?.contains("VALUE=DATE") == true
            || (dtstart.map { $0.count == 8 } ?? false)
        let startDate = dtstart.flatMap { parseICSDate($0, params: dtstartParams) }
        let endDate = dtend.flatMap { parseICSDate($0, params: dtendParams) }

        // Parse organizer
        let organizer = organizerLine.flatMap(parseParticipant)

        // Parse attendees
        let attendees = attendeeLines.compactMap(parseParticipant)

        return ParsedInvite(
            method: method,
            title: title.isEmpty ? "(No title)" : title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location,
            description: description,
            organizer: organizer,
            attendees: attendees
        )
    }

    /// Build an HTML body from a parsed incoming ICS invite.
    /// Renders a clean table layout matching TB's calendar invite style,
    /// with dark mode support matching our WebView theme.
    static func buildIncomingInviteBody(_ invite: ParsedInvite) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = invite.isAllDay ? .none : .short

        // Header: "X has invited you to Y" / "X has cancelled Y"
        let orgName = invite.organizer.map { $0.name.isEmpty ? $0.email : $0.name } ?? "Someone"
        let actionVerb: String
        switch invite.method {
        case "CANCEL": actionVerb = "has cancelled"
        case "REPLY": actionVerb = "has responded to"
        default: actionVerb = "has invited you to"
        }

        var html = "<div class=\"tm-ics-invite\">"
        html += "<style>"
        html += ".tm-ics-invite { font-size: 15px; margin-bottom: 16px; }"
        html += ".tm-ics-header { font-size: 15px; margin: 0 0 8px 0; }"
        html += ".tm-ics-table { border-collapse: collapse; }"
        html += ".tm-ics-label { padding: 3px 12px 3px 0; vertical-align: top; text-align: right; color: rgba(0,0,0,0.45); font-size: 14px; white-space: nowrap; }"
        html += ".tm-ics-value { padding: 3px 0; font-size: 14px; }"
        html += "@media (prefers-color-scheme: dark) {"
        html += "  .tm-ics-label { color: rgba(255,255,255,0.45); }"
        html += "}"
        html += "</style>"

        html += "<p class=\"tm-ics-header\"><strong>\(escapeHTML(orgName))</strong> \(actionVerb) <strong>\(escapeHTML(invite.title))</strong></p>"

        html += "<table class=\"tm-ics-table\">"

        html += "<tr><td class=\"tm-ics-label\">Title:</td>"
        html += "<td class=\"tm-ics-value\">\(escapeHTML(invite.title))</td></tr>"

        if let start = invite.startDate {
            var when = escapeHTML(dateFormatter.string(from: start))
            if !invite.isAllDay, let end = invite.endDate {
                let endFmt = DateFormatter()
                endFmt.timeStyle = .short
                when += " – \(escapeHTML(endFmt.string(from: end)))"
            }
            html += "<tr><td class=\"tm-ics-label\">When:</td>"
            html += "<td class=\"tm-ics-value\">\(when)</td></tr>"
        }

        if let location = invite.location, !location.isEmpty {
            html += "<tr><td class=\"tm-ics-label\">Where:</td>"
            html += "<td class=\"tm-ics-value\">\(escapeHTML(location))</td></tr>"
        }

        if let org = invite.organizer {
            let display = formatParticipant(org)
            html += "<tr><td class=\"tm-ics-label\">Organizer:</td>"
            html += "<td class=\"tm-ics-value\">\(display)</td></tr>"
        }

        if !invite.attendees.isEmpty {
            html += "<tr><td class=\"tm-ics-label\">Attendees:</td>"
            html += "<td class=\"tm-ics-value\">"
            for (i, att) in invite.attendees.prefix(10).enumerated() {
                if i > 0 { html += "<br>" }
                html += formatParticipant(att)
            }
            if invite.attendees.count > 10 {
                html += "<br>... and \(invite.attendees.count - 10) more"
            }
            html += "</td></tr>"
        }

        html += "</table>"

        if let desc = invite.description, !desc.isEmpty {
            html += "<p style=\"margin-top: 8px; font-size: 14px;\">\(escapeHTML(desc))</p>"
        }
        html += "</div>"
        return html
    }

    /// Format a participant (organizer or attendee) for display.
    /// Shows "Name <email>" if both exist, just email if name is empty or same as email.
    private static func formatParticipant(_ participant: (name: String, email: String)) -> String {
        let name = participant.name
        let email = participant.email
        if name.isEmpty || name.lowercased() == email.lowercased() {
            return escapeHTML(email)
        }
        return "\(escapeHTML(name)) &lt;\(escapeHTML(email))&gt;"
    }

    // MARK: - ICS Parsing Helpers

    /// Extract the value for a simple property (e.g., "SUMMARY:Meeting" → "Meeting").
    /// Handles properties with parameters (e.g., "SUMMARY;LANGUAGE=en:Meeting" → "Meeting").
    private static func extractValue(
        _ line: String,
        property: String,
        caseInsensitivePropertyName: Bool = false
    ) -> String? {
        let propertyPrefix = line.prefix(property.count)
        let propertyMatches = caseInsensitivePropertyName
            ? String(propertyPrefix).caseInsensitiveCompare(property) == .orderedSame
            : String(propertyPrefix) == property
        guard propertyMatches else { return nil }
        let after = line.dropFirst(property.count)
        if after.hasPrefix(":") {
            return String(after.dropFirst())
        }
        if after.hasPrefix(";") {
            // Has parameters — find the value after the last unquoted colon
            if let colonIdx = findValueColon(String(after)) {
                return String(after[after.index(after.startIndex, offsetBy: colonIdx + 1)...])
            }
        }
        return nil
    }

    /// Split a property line into (parameters, value). E.g.,
    /// "DTSTART;TZID=America/New_York:20240101T120000" → ("TZID=America/New_York", "20240101T120000")
    private static func splitPropertyLine(_ line: String) -> (params: String?, value: String) {
        // Find the colon that separates params from value (skip colons inside quoted strings)
        guard let colonIdx = findValueColon(line) else {
            return (nil, line)
        }
        let before = String(line[line.startIndex..<line.index(line.startIndex, offsetBy: colonIdx)])
        let value = String(line[line.index(line.startIndex, offsetBy: colonIdx + 1)...])
        // Extract params (everything after property name and semicolon)
        if let semiIdx = before.firstIndex(of: ";") {
            return (String(before[before.index(after: semiIdx)...]), value)
        }
        return (nil, value)
    }

    /// Find the index of the colon that separates property+params from value.
    /// Skips colons inside quoted parameter values.
    private static func findValueColon(_ line: String) -> Int? {
        var inQuote = false
        for (i, ch) in line.enumerated() {
            if ch == "\"" { inQuote.toggle() }
            if ch == ":" && !inQuote { return i }
        }
        return nil
    }

    /// Parse an ICS date string (YYYYMMDD or YYYYMMDDTHHMMSS or YYYYMMDDTHHMMSSZ).
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
            // Date-only (all-day)
            fmt.dateFormat = "yyyyMMdd"
            fmt.timeZone = .current
            return fmt.date(from: cleaned)
        }

        // Date-time with optional timezone
        fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        if let params, let tzid = extractTZID(params) {
            fmt.timeZone = TimeZone(identifier: tzid) ?? mapWindowsTimezone(tzid)
        } else {
            fmt.timeZone = .current
        }
        return fmt.date(from: cleaned)
    }

    /// Extract TZID from property parameters.
    private static func extractTZID(_ params: String) -> String? {
        for part in params.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces).uppercased() == "TZID" {
                return String(kv[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Map common Windows timezone names to IANA identifiers.
    private static func mapWindowsTimezone(_ windowsTZ: String) -> TimeZone? {
        let map: [String: String] = [
            "Eastern Standard Time": "America/New_York",
            "Central Standard Time": "America/Chicago",
            "Mountain Standard Time": "America/Denver",
            "Pacific Standard Time": "America/Los_Angeles",
            "GMT Standard Time": "Europe/London",
            "W. Europe Standard Time": "Europe/Berlin",
            "Romance Standard Time": "Europe/Paris",
            "Central European Standard Time": "Europe/Warsaw",
            "E. Europe Standard Time": "Europe/Bucharest",
            "Tokyo Standard Time": "Asia/Tokyo",
            "China Standard Time": "Asia/Shanghai",
            "India Standard Time": "Asia/Kolkata",
            "AUS Eastern Standard Time": "Australia/Sydney",
            "UTC": "UTC",
        ]
        if let iana = map[windowsTZ] {
            return TimeZone(identifier: iana)
        }
        return nil
    }

    /// Parse ORGANIZER or ATTENDEE line into (name, email).
    /// Handles formats like:
    /// - `ORGANIZER;CN="John Doe":mailto:john@example.com`
    /// - `ATTENDEE;CN=John;RSVP=TRUE:mailto:john@example.com`
    /// - `ORGANIZER;CN=John Doe:mailto:john@example.com` (unquoted CN)
    private static func parseParticipant(_ line: String) -> (name: String, email: String)? {
        // Extract email from mailto: URI
        guard let mailtoRange = line.range(of: "mailto:", options: .caseInsensitive) else { return nil }
        let email = String(line[mailtoRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return nil }

        // Extract CN parameter — try quoted first, then unquoted.
        // Quoted:   CN="John Doe" → capture between quotes
        // Unquoted: CN=John Doe   → capture up to next ; or : (stops before mailto)
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

    /// Unescape ICS text (reverse of escapeText).
    private static func unescapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
