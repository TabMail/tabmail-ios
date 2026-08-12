/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Extension to convert GCalEventInput to ICS format for CalDAV PUT operations.
/// Separate from ICSBuilder which generates METHOD:REQUEST for email invitations.
/// CalDAV PUT uses plain VCALENDAR (no METHOD line).
extension GCalEventInput {

    /// Convert to a VCALENDAR string suitable for CalDAV PUT.
    /// `uid` is the VEVENT UID (usually matches the .ics filename without extension).
    ///
    /// Any `DTSTART;TZID=…` / `DTEND;TZID=…` the VEVENT emits is accompanied by
    /// a matching `VTIMEZONE` component (RFC 5545 §3.2.19 — a TZID parameter
    /// MUST reference a VTIMEZONE in the same VCALENDAR). When a referenced zone
    /// can't be turned into a VTIMEZONE, that property falls back to a UTC `Z`
    /// time, which needs no VTIMEZONE.
    func toICS(uid: String) -> String {
        let (eventLines, vtimezones) = veventLines(uid: uid)

        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//TabMail//TabMail iOS//EN",
            "CALSCALE:GREGORIAN",
        ]
        // Embed VTIMEZONE(s) before the VEVENT. Sorted for stable output.
        for tzid in vtimezones.keys.sorted() {
            lines.append(contentsOf: vtimezones[tzid]!)
        }
        lines.append(contentsOf: eventLines)
        lines.append("END:VCALENDAR")

        // Strip embedded line breaks and control characters from every assembled line BEFORE
        // folding, then fold long lines per RFC 5545.
        //
        // This is the ICS-injection boundary, and it is deliberately here rather than at each
        // interpolation site. `\r\n` is the property separator, so ANY value that reaches this point
        // still carrying one splits its line into a second property that the CalDAV server then
        // honours — the attacker gets to add ATTENDEE, ORGANIZER, or even END:VEVENT/BEGIN:VEVENT to
        // an event we PUT on the user's behalf. An injected ATTENDEE is the sharp case: the server
        // mails the invitation, so it discloses the event to an address the user never typed.
        //
        // Several values reach here unescaped by design (RRULE lines are structured, so they cannot
        // pass through `escapeICSText` without corrupting `;` and `,`), and others are simply not
        // escaped today — attendee email, transparency, TZID, all-day date strings. Guarding the one
        // reported field would have left the rest, so the class is closed at the single point every
        // line passes through.
        //
        // RFC 5545's CONTROL production (`%x00-08 / %x0A-1F / %x7F`) forbids every C0 control except
        // HTAB, plus DEL, in a property value — so stripping THOSE cannot damage a legitimate event.
        // `isForbiddenICSScalar` also strips U+0085, U+2028 and U+2029, which the RFC does NOT forbid;
        // that part is defence in depth against downstream line-splitters, justified where it is
        // defined rather than by the RFC. Do not restate this as "the RFC forbids all of them".
        let sanitized = lines.map { Self.sanitizeICSLine($0) }
        let folded = sanitized.map { foldICSLine($0) }
        return folded.joined(separator: "\r\n") + "\r\n"
    }

    /// Remove CR, LF and other C0 control characters (keeping HTAB) from a single assembled ICS line.
    ///
    /// Stripping rather than rejecting: a mangled value yields a malformed property that the server
    /// refuses, which is recoverable and visible. Silently emitting an extra property is not.
    static func sanitizeICSLine(_ line: String) -> String {
        guard line.unicodeScalars.contains(where: Self.isForbiddenICSScalar) else { return line }
        return String(String.UnicodeScalarView(
            line.unicodeScalars.filter { !Self.isForbiddenICSScalar($0) }
        ))
    }

    /// Scalars that may not appear inside an ICS property value.
    ///
    /// C0 controls except HTAB, plus DEL — RFC 5545's CONTROL production excludes `%x7F`, so the
    /// earlier `< 0x20` test was narrower than the spec it cited.
    ///
    /// It was also narrower than this guard's own test oracle, which is the part that mattered. The
    /// injection tests split the result with `Character.isNewline`, and that treats U+0085 NEL,
    /// U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR as line breaks while a `< 0x20` filter
    /// passes all three through untouched — so a payload using them would have been reported as an
    /// injected property by the very test meant to prove it could not happen. A guard must be at
    /// least as strict as the notion of "line" used to judge it, and at least as strict as the most
    /// lenient line-splitter downstream (Python's `str.splitlines()`, for one, splits on all three).
    static func isForbiddenICSScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\t" { return false }
        if scalar.value < 0x20 || scalar.value == 0x7F { return true }
        return scalar.value == 0x85 || scalar.value == 0x2028 || scalar.value == 0x2029
    }

    /// Build the VEVENT block and the set of `VTIMEZONE` components it requires.
    /// Returns the VEVENT lines plus a `tzid → VTIMEZONE block` map (deduped).
    private func veventLines(uid: String) -> (lines: [String], vtimezones: [String: [String]]) {
        var lines: [String] = []
        var vtimezones: [String: [String]] = [:]

        lines.append("BEGIN:VEVENT")
        lines.append("UID:\(uid)")
        lines.append("DTSTAMP:\(formatUTC(Date()))")

        // Emit a timed DTSTART/DTEND: use `TZID=` + a registered VTIMEZONE when
        // the zone is resolvable, otherwise a UTC `Z` time (needs no VTIMEZONE).
        func appendTimed(property: String, iso: String, tzid: String?) {
            guard let date = parseRFC3339(iso) else { return }
            if let tzid, !tzid.isEmpty, let tz = TimeZone(identifier: tzid) {
                if vtimezones[tzid] == nil, let block = VTimeZoneBuilder.vtimezone(for: tz) {
                    vtimezones[tzid] = block
                }
                if vtimezones[tzid] != nil {
                    lines.append("\(property);TZID=\(tzid):\(formatLocal(date, timeZone: tzid))")
                    return
                }
            }
            lines.append("\(property):\(formatUTC(date))")
        }

        // Start
        if let startDate {
            lines.append("DTSTART;VALUE=DATE:\(startDate.replacingOccurrences(of: "-", with: ""))")
        } else if let startDateTime {
            appendTimed(property: "DTSTART", iso: startDateTime, tzid: startTimeZone)
        }

        // End
        if let endDate {
            lines.append("DTEND;VALUE=DATE:\(endDate.replacingOccurrences(of: "-", with: ""))")
        } else if let endDateTime {
            appendTimed(property: "DTEND", iso: endDateTime, tzid: endTimeZone)
        }

        if let summary, !summary.isEmpty {
            lines.append("SUMMARY:\(escapeICSText(summary))")
        }
        if let location, !location.isEmpty {
            lines.append("LOCATION:\(escapeICSText(location))")
        }
        if let description, !description.isEmpty {
            lines.append("DESCRIPTION:\(escapeICSText(description))")
        }
        if let transparency {
            lines.append("TRANSP:\(transparency.uppercased())")
        }

        // Attendees (CalDAV server handles invitation sending)
        if let attendees {
            for a in attendees {
                let cn = a.name ?? a.email
                lines.append("ATTENDEE;CN=\"\(escapeICSParam(cn))\";ROLE=REQ-PARTICIPANT:mailto:\(a.email)")
            }
        }

        // Recurrence
        if let recurrence {
            for rule in recurrence {
                lines.append(rule)
            }
        }

        lines.append("END:VEVENT")
        return (lines, vtimezones)
    }

    // MARK: - Private Helpers

    private func formatUTC(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    private func formatLocal(_ date: Date, timeZone tz: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        fmt.timeZone = TimeZone(identifier: tz) ?? .current
        return fmt.string(from: date)
    }

    private func parseRFC3339(_ str: String) -> Date? {
        Date.fromISO8601(str)
    }

    private func escapeICSText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func escapeICSParam(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "'")
    }

    private func foldICSLine(_ line: String) -> String {
        let maxOctets = 75
        let utf8 = Array(line.utf8)
        guard utf8.count > maxOctets else { return line }
        var result = ""
        var offset = 0
        var isFirst = true
        while offset < utf8.count {
            let limit = isFirst ? maxOctets : maxOctets - 1
            let end = min(offset + limit, utf8.count)
            var safeEnd = end
            if safeEnd < utf8.count {
                while safeEnd > offset && utf8[safeEnd] & 0xC0 == 0x80 {
                    safeEnd -= 1
                }
            }
            if safeEnd <= offset { safeEnd = end }
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
}
