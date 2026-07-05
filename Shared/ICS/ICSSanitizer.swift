/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Tunables for `ICSSanitizer`. All limits live here so no numeric constant is
/// hardcoded in the logic (project rule: "No hardcoded numeric values").
enum ICSSanitizerConfig {
    /// Max octets of content per *physical* line (RFC 5545 §3.1: SHOULD NOT
    /// exceed 75 octets). Lines at or under this are never folded.
    static let physicalLineOctetLimit = 75
    /// Content octets packed into each physical line when folding. One SPACE is
    /// prepended to continuation lines, so `foldWidthOctets + 1 <= physicalLineOctetLimit`.
    static let foldWidthOctets = 74
    /// An unfolded logical line longer than this (and not on the keep-list) is
    /// dropped — pathological bloat that CalDAV/Google reject and that stalls sync.
    static let maxPropertyOctets = 8_192
    /// Truncation cap for keep-list text values (DESCRIPTION/SUMMARY/…). The
    /// truncation is an ephemeral, hard-constraint operation on the value we
    /// *present*; the stored attachment / `MessageBody.icsText` keep the full copy.
    static let maxTextValueOctets = 8_192
    /// Whole-file backstop applied after per-property rules.
    static let maxTotalOctets = 65_536

    /// Alternate-representation / editor-bloat properties dropped unconditionally.
    /// `X-ALT-DESC` is an HTML mirror of `DESCRIPTION`; consumers fall back to the
    /// plain `DESCRIPTION`, so dropping it is lossless in practice.
    static let alwaysDropProperties: Set<String> = ["X-ALT-DESC"]
    /// Text properties whose over-long value is truncated (rather than the whole
    /// property being dropped), because the property itself is semantically useful.
    static let truncatableTextProperties: Set<String> = ["DESCRIPTION", "SUMMARY", "LOCATION", "COMMENT"]
    /// VALARM actions removed on import: EMAIL alarms on foreign invites are a spam
    /// vector (and rejected by Google); PROCEDURE is deprecated/unsafe.
    static let droppableAlarmActions: Set<String> = ["EMAIL", "PROCEDURE"]
    /// Injected when a `DISPLAY` alarm is missing its required `DESCRIPTION`
    /// (RFC 5545 §3.6.6). Text, not a tunable — kept here for one-line editing.
    static let defaultAlarmDescription = "Reminder"

    /// Properties never dropped by the size gate — essential event/alarm/timezone
    /// semantics. Over-long text members here are truncated instead (see above);
    /// everything else is kept verbatim.
    static let keepListProperties: Set<String> = [
        "UID", "DTSTAMP", "DTSTART", "DTEND", "DURATION", "RRULE", "RDATE", "EXDATE",
        "RECURRENCE-ID", "METHOD", "ORGANIZER", "ATTENDEE", "SUMMARY", "DESCRIPTION",
        "LOCATION", "STATUS", "SEQUENCE", "TRANSP", "CLASS", "ACTION", "TRIGGER",
        "VERSION", "PRODID", "CALSCALE",
        "TZID", "TZOFFSETFROM", "TZOFFSETTO", "TZNAME",
    ]
}

/// Cleans incoming iCalendar (ICS) payloads before they are presented to the user
/// or handed to the OS "Add to Calendar" flow.
///
/// Motivation: a real invite from a webmail composer carried a single ~79 KB
/// `X-ALT-DESC` HTML property (an editor bug that duplicated a class token
/// thousands of times). When imported into iOS Calendar and pushed to Google via
/// CalDAV, the oversized event was rejected and — because CalDAV pushes changes
/// sequentially — permanently wedged the account's calendar sync. This sanitizer
/// strips that class of bloat and repairs a few RFC violations, without touching
/// event *semantics* (METHOD / ORGANIZER / ATTENDEE / recurrence / VTIMEZONE).
///
/// The function is **total** (never throws) and **idempotent**
/// (`sanitize(sanitize(x)) == sanitize(x)`).
enum ICSSanitizer {

    // MARK: - Public API

    /// Sanitize raw ICS bytes. Non-UTF-8 input is returned unchanged (we cannot
    /// safely edit what we cannot decode).
    static func sanitize(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let cleaned = Data(sanitize(text).utf8)
        #if DEBUG
        print("[ICSSanitizer] \(data.count) → \(cleaned.count) bytes")
        #endif
        return cleaned
    }

    /// Sanitize ICS text. Core implementation.
    static func sanitize(_ text: String) -> String {
        // Only touch actual iCalendar payloads — if this isn't one, return it
        // verbatim rather than risk mangling a misrouted file.
        guard text.range(of: "BEGIN:VCALENDAR", options: .caseInsensitive) != nil else {
            return text
        }

        let logical = unfold(text)
        // The ORGANIZER's address, so we can drop the ATTENDEE that duplicates it.
        // An invite where the organizer is also listed as an attendee is hidden by
        // Google Calendar (confirmed via wedge-test bisection). Removing just that
        // one entry keeps the organizer + the real attendees, so RSVP still works.
        let organizerAddress = logical.first(where: { hasKeywordPrefix($0, "ORGANIZER") })
            .flatMap { mailtoAddress(in: $0)?.lowercased() }
        var output: [String] = []
        var i = 0
        while i < logical.count {
            let line = logical[i]
            if isBlank(line) { i += 1; continue }

            if isBeginVALARM(line) {
                if let endIdx = matchingEndVALARM(logical, from: i + 1) {
                    output.append(contentsOf: sanitizeAlarm(Array(logical[i...endIdx])))
                    i = endIdx + 1
                    continue
                }
                // Unclosed alarm: emit the delimiter and keep going normally.
                output.append(line)
                i += 1
                continue
            }

            if isDelimiter(line) {
                output.append(line)
            } else if let kept = sanitizeProperty(line, organizerAddress: organizerAddress), !kept.isEmpty {
                output.append(kept)
            }
            i += 1
        }

        output = applyTotalSizeGuard(output)
        return output.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Line unfolding / folding (RFC 5545 §3.1)

    /// Split into logical lines: break on CRLF/LF/CR, then join continuation
    /// lines (those beginning with SPACE or HTAB) back onto their predecessor,
    /// removing the single leading fold character.
    private static func unfold(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var logical: [String] = []
        for physical in normalized.components(separatedBy: "\n") {
            if let first = physical.first, first == " " || first == "\t" {
                let continuation = String(physical.dropFirst())
                if logical.isEmpty {
                    logical.append(continuation) // malformed leading continuation
                } else {
                    logical[logical.count - 1] += continuation
                }
            } else {
                logical.append(physical)
            }
        }
        return logical
    }

    /// Fold a logical line so no physical line exceeds `physicalLineOctetLimit`.
    /// Continuation lines begin with a single SPACE. UTF-8 sequences are never split.
    private static func fold(_ line: String) -> String {
        guard line.utf8.count > ICSSanitizerConfig.physicalLineOctetLimit else { return line }
        let utf8 = Array(line.utf8)
        let width = ICSSanitizerConfig.foldWidthOctets
        var result = ""
        var offset = 0
        var isFirst = true
        while offset < utf8.count {
            var end = min(offset + width, utf8.count)
            // Back off to a UTF-8 character boundary (don't split a multi-byte char).
            if end < utf8.count {
                while end > offset && (utf8[end] & 0xC0) == 0x80 { end -= 1 }
            }
            if end <= offset { end = min(offset + width, utf8.count) } // single char > width
            let chunk = String(decoding: utf8[offset..<end], as: UTF8.self)
            if isFirst {
                result = chunk
                isFirst = false
            } else {
                result += "\r\n " + chunk
            }
            offset = end
        }
        return result
    }

    // MARK: - Per-property rules

    /// Apply per-property rules. Returns the cleaned line, or nil to drop it.
    /// `organizerAddress` (lowercased) drops the ATTENDEE that duplicates the
    /// organizer — that self-reference is what Google hides.
    private static func sanitizeProperty(_ rawLine: String, organizerAddress: String?) -> String? {
        let line = stripControlChars(rawLine) // R5
        guard let name = propertyName(line) else {
            // No property name (no unquoted colon) — malformed. Drop only if huge.
            return line.utf8.count > ICSSanitizerConfig.maxPropertyOctets ? nil : line
        }
        if ICSSanitizerConfig.alwaysDropProperties.contains(name) { return nil } // R1
        // Drop the ATTENDEE whose address equals the ORGANIZER — organizer-as-own-
        // attendee hides the event in Google Calendar. Keeps organizer + the other
        // attendees, so RSVP is preserved.
        if name == "ATTENDEE", let organizerAddress,
           mailtoAddress(in: line)?.lowercased() == organizerAddress {
            return nil
        }
        if ICSSanitizerConfig.truncatableTextProperties.contains(name),
           line.utf8.count > ICSSanitizerConfig.maxTextValueOctets {
            return truncateProperty(line) // R3
        }
        if line.utf8.count > ICSSanitizerConfig.maxPropertyOctets,
           !ICSSanitizerConfig.keepListProperties.contains(name) {
            return nil // R2
        }
        return line
    }

    /// Truncate a text property's value to fit `maxTextValueOctets` (incl. prefix
    /// and ellipsis), at a UTF-8- and escape-safe boundary.
    private static func truncateProperty(_ line: String) -> String {
        guard let colon = valueColonIndex(line) else { return line }
        let prefix = String(line[...colon]) // name+params and the ':'
        let value = String(line[line.index(after: colon)...])
        let ellipsis = "…"
        let budget = ICSSanitizerConfig.maxTextValueOctets - prefix.utf8.count - ellipsis.utf8.count
        return prefix + truncateValue(value, maxOctets: max(0, budget), ellipsis: ellipsis)
    }

    /// Truncate `value` to `maxOctets` UTF-8 bytes without splitting a character
    /// or leaving a dangling backslash (which would escape the appended ellipsis).
    private static func truncateValue(_ value: String, maxOctets: Int, ellipsis: String) -> String {
        let bytes = Array(value.utf8)
        guard bytes.count > maxOctets else { return value }
        var end = maxOctets
        while end > 0 && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        var truncated = String(decoding: bytes[0..<end], as: UTF8.self)
        var trailingBackslashes = 0
        for ch in truncated.reversed() {
            if ch == "\\" { trailingBackslashes += 1 } else { break }
        }
        if trailingBackslashes % 2 == 1 { truncated.removeLast() }
        return truncated + ellipsis
    }

    /// Remove control octets illegal in ICS content (C0 controls except HTAB, and DEL).
    private static func stripControlChars(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: isStrippableControl) else { return s }
        var scalars = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where !isStrippableControl(scalar) { scalars.append(scalar) }
        return String(scalars)
    }

    private static func isStrippableControl(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v < 0x20 && v != 0x09) || v == 0x7F
    }

    // MARK: - VALARM handling (R4)

    /// Process a full `BEGIN:VALARM … END:VALARM` block: drop EMAIL/PROCEDURE
    /// alarms, and give a `DISPLAY` alarm the `DESCRIPTION` that RFC 5545 requires.
    /// Returns the block's lines, or an empty array to drop it.
    private static func sanitizeAlarm(_ block: [String]) -> [String] {
        guard block.count >= 2 else { return block }
        var kept: [String] = []
        var action: String?
        var hasDescription = false
        for prop in block[1..<(block.count - 1)] {
            guard let sane = sanitizeProperty(prop, organizerAddress: nil), !sane.isEmpty else { continue }
            switch propertyName(sane) {
            case "ACTION": action = propertyValue(sane)?.trimmingCharacters(in: .whitespaces).uppercased()
            case "DESCRIPTION": hasDescription = true
            default: break
            }
            kept.append(sane)
        }
        if let action, ICSSanitizerConfig.droppableAlarmActions.contains(action) {
            return []
        }
        if action == "DISPLAY", !hasDescription {
            kept.append("DESCRIPTION:\(ICSSanitizerConfig.defaultAlarmDescription)")
        }
        return [block.first!] + kept + [block.last!]
    }

    // MARK: - Whole-file guard (R6)

    /// If the payload still exceeds `maxTotalOctets`, drop the largest droppable
    /// (non-keep-list, non-delimiter) properties until it fits. Never refuses to
    /// present: if still over after that, the output is returned as-is.
    private static func applyTotalSizeGuard(_ lines: [String]) -> [String] {
        func lineCost(_ line: String) -> Int { line.utf8.count + 2 } // + CRLF
        var total = lines.reduce(0) { $0 + lineCost($1) }
        guard total > ICSSanitizerConfig.maxTotalOctets else { return lines }

        let droppable = lines.enumerated()
            .filter { _, line in
                guard !isDelimiter(line), let name = propertyName(line) else { return false }
                return !ICSSanitizerConfig.keepListProperties.contains(name)
            }
            .sorted { $0.element.utf8.count > $1.element.utf8.count }

        var dropped = Set<Int>()
        for (index, line) in droppable {
            if total <= ICSSanitizerConfig.maxTotalOctets { break }
            dropped.insert(index)
            total -= lineCost(line)
        }
        guard !dropped.isEmpty else { return lines }
        return lines.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }

    // MARK: - Parsing helpers

    /// Uppercased property name (text before the first `;` or `:`), or nil if the
    /// line has neither (not a valid property).
    private static func propertyName(_ line: String) -> String? {
        var name = ""
        for ch in line {
            if ch == ";" || ch == ":" { return name.isEmpty ? nil : name.uppercased() }
            name.append(ch)
        }
        return nil
    }

    /// The property value (everything after the value-colon), or nil if none.
    private static func propertyValue(_ line: String) -> String? {
        guard let colon = valueColonIndex(line) else { return nil }
        return String(line[line.index(after: colon)...])
    }

    /// The address after `mailto:` in an ORGANIZER/ATTENDEE line, trimmed.
    private static func mailtoAddress(in line: String) -> String? {
        guard let r = line.range(of: "mailto:", options: .caseInsensitive) else { return nil }
        return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// Index of the colon separating name+params from value, skipping colons that
    /// appear inside quoted parameter values.
    private static func valueColonIndex(_ line: String) -> String.Index? {
        var inQuote = false
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == "\"" {
                inQuote.toggle()
            } else if ch == ":" && !inQuote {
                return idx
            }
            idx = line.index(after: idx)
        }
        return nil
    }

    // MARK: - Component delimiter helpers

    /// Case-insensitive ASCII prefix test that does NOT allocate an uppercased
    /// copy of the whole line. Important because a single property (e.g. the
    /// pathological `X-ALT-DESC`) can be tens of KB, and the main loop tests
    /// every line — a full-line `uppercased()` would allocate that bloat twice
    /// before the line is even dropped. `keyword` must be uppercase ASCII.
    private static func hasKeywordPrefix(_ line: String, _ keyword: String) -> Bool {
        let lineBytes = line.utf8
        let keyBytes = keyword.utf8
        guard lineBytes.count >= keyBytes.count else { return false }
        var li = lineBytes.startIndex
        for kb in keyBytes {
            let lb = lineBytes[li]
            let upper = (lb >= 0x61 && lb <= 0x7A) ? lb - 0x20 : lb // ASCII a–z → A–Z
            if upper != kb { return false }
            li = lineBytes.index(after: li)
        }
        return true
    }

    /// True if the line is empty or only SPACE/HTAB. Short-circuits on the first
    /// non-whitespace character (no allocation), unlike `trimmingCharacters`.
    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func isDelimiter(_ line: String) -> Bool {
        hasKeywordPrefix(line, "BEGIN:") || hasKeywordPrefix(line, "END:")
    }

    private static func isBeginVALARM(_ line: String) -> Bool {
        hasKeywordPrefix(line, "BEGIN:VALARM")
    }

    /// Find the `END:VALARM` matching the alarm that opened just before `start`.
    /// Returns nil if the alarm is left unclosed before a nested or parent boundary.
    private static func matchingEndVALARM(_ lines: [String], from start: Int) -> Int? {
        var i = start
        while i < lines.count {
            let line = lines[i]
            if hasKeywordPrefix(line, "END:VALARM") { return i }
            if hasKeywordPrefix(line, "BEGIN:VALARM")
                || hasKeywordPrefix(line, "END:VEVENT") || hasKeywordPrefix(line, "END:VTODO")
                || hasKeywordPrefix(line, "END:VCALENDAR") || hasKeywordPrefix(line, "END:VJOURNAL") {
                return nil
            }
            i += 1
        }
        return nil
    }
}
