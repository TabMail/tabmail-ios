/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ICSSanitizer")
struct ICSSanitizerTests {

    // MARK: - Fixture builders (synthetic — no real addresses/domains, dynamic dates)

    /// A single UTC date string `YYYYMMDDTHHMMSSZ` offset from now.
    private static func icsDate(daysFromNow: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: daysFromNow, to: Date())!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    /// Build a CRLF-joined ICS from logical lines (unfolded).
    private static func ics(_ lines: [String]) -> String {
        lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Physical (folded) lines of an ICS string.
    private static func physicalLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// The webmail-composer pathology: a huge `X-ALT-DESC` HTML property whose
    /// class attribute repeats a token thousands of times, a DISPLAY alarm missing
    /// its DESCRIPTION, and a multi-byte character. Folded with HTAB continuations.
    private static func pathologicalICS() -> String {
        let start = icsDate(daysFromNow: 3)
        let end = icsDate(daysFromNow: 3)
        let bloatClass = String(repeating: "__editor_node_has_style ", count: 4000) // ~96 KB
        let htmlValue = "<div class=\"\(bloatClass)\">Hello © world</div>"

        // Build with tab folding to mirror the real file.
        var lines = [
            "BEGIN:VCALENDAR",
            "PRODID:-//Example Webmail Co//Calendar//EN",
            "VERSION:2.0",
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            "UID:synthetic-uid-12345@example.com",
            "DTSTAMP:\(start)",
            "DTSTART:\(start)",
            "DTEND:\(end)",
            "SUMMARY:Sync Meeting",
            "ORGANIZER;CN=Organizer:mailto:organizer@example.com",
            "ATTENDEE;CN=Guest;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:guest@example.com",
        ]
        // X-ALT-DESC folded across many physical lines with leading TAB.
        lines.append(tabFold("X-ALT-DESC;FMTTYPE=text/html:\(htmlValue)"))
        lines.append(contentsOf: [
            "BEGIN:VALARM",
            "ACTION:DISPLAY",
            "TRIGGER;VALUE=DURATION:-PT15M",
            "END:VALARM",
            "END:VEVENT",
            "END:VCALENDAR",
        ])
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Fold a logical line into CRLF + HTAB continuations at 73 octets, mirroring
    /// a webmail composer that folds with tabs.
    private static func tabFold(_ line: String) -> String {
        let bytes = Array(line.utf8)
        let width = 73
        guard bytes.count > width else { return line }
        var out = ""
        var offset = 0
        var first = true
        while offset < bytes.count {
            var end = min(offset + width, bytes.count)
            if end < bytes.count { while end > offset && (bytes[end] & 0xC0) == 0x80 { end -= 1 } }
            if end <= offset { end = min(offset + width, bytes.count) }
            let chunk = String(decoding: bytes[offset..<end], as: UTF8.self)
            out += first ? chunk : "\r\n\t" + chunk
            first = false
            offset = end
        }
        return out
    }

    private static func hasProperty(_ text: String, _ name: String) -> Bool {
        for line in physicalLines(text) where !line.hasPrefix(" ") && !line.hasPrefix("\t") {
            if line.uppercased().hasPrefix(name.uppercased() + ":")
                || line.uppercased().hasPrefix(name.uppercased() + ";") {
                return true
            }
        }
        return false
    }

    // MARK: - Case 1: trigger pathology

    @Test("Drops X-ALT-DESC and preserves event semantics")
    func trigger() {
        let input = Self.pathologicalICS()
        #expect(input.utf8.count > 90_000)
        let out = ICSSanitizer.sanitize(input)

        #expect(!Self.hasProperty(out, "X-ALT-DESC"))
        #expect(out.utf8.count < ICSSanitizerConfig.maxTotalOctets)
        #expect(Self.hasProperty(out, "UID"))
        #expect(Self.hasProperty(out, "DTSTART"))
        #expect(Self.hasProperty(out, "DTEND"))
        #expect(Self.hasProperty(out, "SUMMARY"))
        #expect(out.contains("mailto:organizer@example.com"))
        #expect(out.contains("mailto:guest@example.com"))
        #expect(out.contains("METHOD:REQUEST"))
    }

    // MARK: - Case 2: DISPLAY alarm repair

    @Test("Injects DESCRIPTION into a DISPLAY alarm that lacks one")
    func displayAlarmRepair() {
        let input = Self.ics([
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:a@example.com",
            "DTSTART:\(Self.icsDate(daysFromNow: 1))", "SUMMARY:Test",
            "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER;VALUE=DURATION:-PT10M", "END:VALARM",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let out = ICSSanitizer.sanitize(input)
        #expect(out.contains("BEGIN:VALARM"))
        #expect(out.contains("ACTION:DISPLAY"))
        #expect(out.uppercased().contains("DESCRIPTION:"))
    }

    @Test("Does not add a second DESCRIPTION when one exists")
    func displayAlarmKeepsExistingDescription() {
        let input = Self.ics([
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:a@example.com",
            "DTSTART:\(Self.icsDate(daysFromNow: 1))", "SUMMARY:Test",
            "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Custom", "TRIGGER;VALUE=DURATION:-PT10M", "END:VALARM",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let out = ICSSanitizer.sanitize(input)
        let descCount = Self.physicalLines(out).filter { $0.uppercased().hasPrefix("DESCRIPTION:") }.count
        #expect(descCount == 1)
        #expect(out.contains("DESCRIPTION:Custom"))
    }

    // MARK: - Case 3: alarm action filtering

    @Test("Drops EMAIL and PROCEDURE alarms but keeps a sibling DISPLAY alarm")
    func dropsUnsafeAlarms() {
        let input = Self.ics([
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:a@example.com",
            "DTSTART:\(Self.icsDate(daysFromNow: 1))", "SUMMARY:Test",
            "BEGIN:VALARM", "ACTION:EMAIL", "DESCRIPTION:Spam", "TRIGGER;VALUE=DURATION:-PT10M",
            "ATTENDEE:mailto:victim@example.com", "END:VALARM",
            "BEGIN:VALARM", "ACTION:PROCEDURE", "ATTACH:file:///bin/sh", "TRIGGER;VALUE=DURATION:-PT5M", "END:VALARM",
            "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Keep me", "TRIGGER;VALUE=DURATION:-PT1M", "END:VALARM",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let out = ICSSanitizer.sanitize(input)
        #expect(!out.contains("ACTION:EMAIL"))
        #expect(!out.contains("ACTION:PROCEDURE"))
        #expect(!out.contains("victim@example.com"))
        #expect(out.contains("ACTION:DISPLAY"))
        #expect(out.contains("DESCRIPTION:Keep me"))
    }

    // MARK: - Case 4: oversized non-keep-list property dropped

    @Test("Drops an oversized non-keep-list property (e.g. inline ATTACH)")
    func dropsOversizedAttach() {
        let blob = String(repeating: "A", count: ICSSanitizerConfig.maxPropertyOctets + 100)
        let input = Self.ics([
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:a@example.com",
            "DTSTART:\(Self.icsDate(daysFromNow: 1))", "SUMMARY:Test",
            "ATTACH;ENCODING=BASE64;VALUE=BINARY:\(blob)",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let out = ICSSanitizer.sanitize(input)
        #expect(!Self.hasProperty(out, "ATTACH"))
        #expect(Self.hasProperty(out, "UID"))
    }

    // MARK: - Case 5: oversized DESCRIPTION truncated (not dropped)

    @Test("Truncates an oversized DESCRIPTION at an escape-safe boundary")
    func truncatesDescription() {
        // End the value in an escape sequence to exercise the dangling-backslash guard.
        let huge = String(repeating: "word ", count: ICSSanitizerConfig.maxTextValueOctets) + "\\,"
        let input = Self.ics([
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:a@example.com",
            "DTSTART:\(Self.icsDate(daysFromNow: 1))", "SUMMARY:Test",
            "DESCRIPTION:\(huge)",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let out = ICSSanitizer.sanitize(input)
        #expect(Self.hasProperty(out, "DESCRIPTION")) // kept, not dropped
        #expect(out.contains("…"))
        // No physical line exceeds the RFC octet limit.
        for line in Self.physicalLines(out) {
            #expect(line.utf8.count <= ICSSanitizerConfig.physicalLineOctetLimit)
        }
        // Still parseable as an invite.
        #expect(ICSBuilder.parseIncoming(out) != nil)
    }

    // MARK: - Case 6: tab folding + LF-only normalized

    @Test("Normalizes tab folding and LF-only breaks to spec CRLF with ≤75-octet lines")
    func normalizesFolding() {
        let longSummary = "Summary " + String(repeating: "x", count: 200)
        // LF-only, no folding on input.
        let input = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a@example.com\nDTSTART:\(Self.icsDate(daysFromNow: 1))\nSUMMARY:\(longSummary)\nEND:VEVENT\nEND:VCALENDAR\n"
        let out = ICSSanitizer.sanitize(input)
        #expect(out.contains("\r\n"))
        for line in Self.physicalLines(out) {
            #expect(line.utf8.count <= ICSSanitizerConfig.physicalLineOctetLimit)
        }
        // Unfolding restores the full summary.
        #expect(ICSBuilder.parseIncoming(out)?.title == longSummary)
    }

    // MARK: - Case 7: multi-byte char at fold boundary

    @Test("Never splits a multi-byte character across a fold boundary")
    func multibyteFoldSafety() {
        let value = String(repeating: "é", count: 100) // 2 bytes each → crosses 74-octet boundary
        let input = Self.ics([
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:a@example.com",
            "DTSTART:\(Self.icsDate(daysFromNow: 1))", "SUMMARY:\(value)",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let out = ICSSanitizer.sanitize(input)
        // Re-decoding succeeds and the character survives unfold.
        #expect(ICSBuilder.parseIncoming(out)?.title == value)
    }

    // MARK: - Case 8: clean invite is preserved

    @Test("A clean invite keeps all of its properties")
    func cleanInvitePreserved() {
        let input = Self.ics([
            "BEGIN:VCALENDAR", "VERSION:2.0", "METHOD:REQUEST", "BEGIN:VEVENT",
            "UID:clean@example.com", "DTSTAMP:\(Self.icsDate(daysFromNow: 0))",
            "DTSTART:\(Self.icsDate(daysFromNow: 2))", "DTEND:\(Self.icsDate(daysFromNow: 2))",
            "SUMMARY:Clean", "LOCATION:Room 1", "DESCRIPTION:Short note",
            "ORGANIZER;CN=Org:mailto:org@example.com",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let out = ICSSanitizer.sanitize(input)
        for prop in ["VERSION", "METHOD", "UID", "DTSTAMP", "DTSTART", "DTEND", "SUMMARY", "LOCATION", "DESCRIPTION", "ORGANIZER"] {
            #expect(Self.hasProperty(out, prop), "missing \(prop)")
        }
    }

    // MARK: - Case 9: idempotence

    @Test("Sanitizing twice equals sanitizing once")
    func idempotent() {
        let hugeDesc = String(repeating: "word ", count: ICSSanitizerConfig.maxTextValueOctets) + "\\,"
        let inputs = [
            Self.pathologicalICS(),
            Self.ics([
                "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:a@example.com",
                "DTSTART:\(Self.icsDate(daysFromNow: 1))", "SUMMARY:Test",
                "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER;VALUE=DURATION:-PT10M", "END:VALARM",
                "END:VEVENT", "END:VCALENDAR",
            ]),
            // Truncation path must also be a fixed point.
            Self.ics([
                "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:a@example.com",
                "DTSTART:\(Self.icsDate(daysFromNow: 1))", "SUMMARY:Test",
                "DESCRIPTION:\(hugeDesc)", "END:VEVENT", "END:VCALENDAR",
            ]),
        ]
        for input in inputs {
            let once = ICSSanitizer.sanitize(input)
            let twice = ICSSanitizer.sanitize(once)
            #expect(once == twice)
        }
    }

    // MARK: - Case 10: non-UTF-8 passthrough

    @Test("Non-UTF-8 data is returned unchanged")
    func nonUTF8Passthrough() {
        let data = Data([0xFF, 0xFE, 0x00, 0x01, 0xC0, 0x80])
        #expect(ICSSanitizer.sanitize(data) == data)
    }

    @Test("Non-calendar text is returned unchanged")
    func nonCalendarPassthrough() {
        let text = "This is not a calendar file.\nJust some text.\n"
        #expect(ICSSanitizer.sanitize(text) == text)
    }

    // MARK: - Case 11: round-trip parity through ICSBuilder

    @Test("Parsed invite is identical before and after sanitization")
    func roundTripParity() {
        let start = Self.icsDate(daysFromNow: 4)
        let end = Self.icsDate(daysFromNow: 4)
        let input = Self.ics([
            "BEGIN:VCALENDAR", "METHOD:REQUEST", "BEGIN:VEVENT",
            "UID:rt@example.com", "DTSTART:\(start)", "DTEND:\(end)",
            "SUMMARY:Round Trip", "LOCATION:HQ",
            "ORGANIZER;CN=Org:mailto:org@example.com",
            "ATTENDEE;CN=Guest:mailto:guest@example.com",
            "END:VEVENT", "END:VCALENDAR",
        ])
        guard let before = ICSBuilder.parseIncoming(input),
              let after = ICSBuilder.parseIncoming(ICSSanitizer.sanitize(input)) else {
            Issue.record("parseIncoming returned nil")
            return
        }
        #expect(before.method == after.method)
        #expect(before.title == after.title)
        #expect(before.location == after.location)
        #expect(before.startDate == after.startDate)
        #expect(before.endDate == after.endDate)
        #expect(before.organizer?.email == after.organizer?.email)
        #expect(before.attendees.count == after.attendees.count)
    }

    // MARK: - Organizer-as-attendee removal

    @Test("Drops the ATTENDEE that duplicates the ORGANIZER, keeps organizer + others")
    func dropsOrganizerAttendee() {
        let input = Self.ics([
            "BEGIN:VCALENDAR", "METHOD:REQUEST", "BEGIN:VEVENT", "UID:a@example.com",
            "DTSTART:\(Self.icsDate(daysFromNow: 1))", "SUMMARY:Test",
            "ORGANIZER;CN=Org:mailto:org@example.com",
            "ATTENDEE;CN=Me;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:me@example.com",
            "ATTENDEE;CN=Org;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:org@example.com",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let out = ICSSanitizer.sanitize(input)
        // Organizer kept (RSVP preserved), real attendee kept.
        #expect(out.contains("ORGANIZER;CN=Org:mailto:org@example.com"))
        #expect(out.contains("mailto:me@example.com"))
        // The organizer's address now appears only once — on the ORGANIZER line;
        // the duplicate ATTENDEE was dropped.
        let orgHits = Self.physicalLines(out).filter { $0.contains("mailto:org@example.com") }.count
        #expect(orgHits == 1)
        let attendees = Self.physicalLines(out).filter { $0.uppercased().hasPrefix("ATTENDEE") }.count
        #expect(attendees == 1)
    }

    @Test("Keeps all attendees when none equals the organizer")
    func keepsAttendeesWhenNoOrganizerDup() {
        let input = Self.ics([
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:a@example.com",
            "DTSTART:\(Self.icsDate(daysFromNow: 1))", "SUMMARY:Test",
            "ORGANIZER;CN=Org:mailto:org@example.com",
            "ATTENDEE;CN=A:mailto:a@example.com",
            "ATTENDEE;CN=B:mailto:b@example.com",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let out = ICSSanitizer.sanitize(input)
        let attendees = Self.physicalLines(out).filter { $0.uppercased().hasPrefix("ATTENDEE") }.count
        #expect(attendees == 2)
    }

    // MARK: - Case 12: control-character strip

    @Test("Strips control characters from property values")
    func stripsControlChars() {
        let input = Self.ics([
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:a@example.com",
            "DTSTART:\(Self.icsDate(daysFromNow: 1))", "SUMMARY:Clean\u{0007}Bell\u{0000}Null",
            "END:VEVENT", "END:VCALENDAR",
        ])
        let out = ICSSanitizer.sanitize(input)
        #expect(!out.unicodeScalars.contains { $0.value == 0x07 || $0.value == 0x00 })
        #expect(out.contains("CleanBellNull"))
    }
}
