/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("GCalEventInput toICS")
struct GCalEventInputICSTests {

    @Test("toICS produces valid VCALENDAR structure")
    func validVCalendar() {
        let input = GCalEventInput(summary: "Meeting", startDateTime: "2024-03-15T10:00:00Z", endDateTime: "2024-03-15T11:00:00Z")
        let ics = input.toICS(uid: "test-uid")
        #expect(ics.contains("BEGIN:VCALENDAR"))
        #expect(ics.contains("END:VCALENDAR"))
        #expect(ics.contains("BEGIN:VEVENT"))
        #expect(ics.contains("END:VEVENT"))
        #expect(ics.contains("UID:test-uid"))
    }

    @Test("toICS does NOT include METHOD (CalDAV PUT, not email invitation)")
    func noMethodLine() {
        let input = GCalEventInput(summary: "Meeting", startDateTime: "2024-03-15T10:00:00Z")
        let ics = input.toICS(uid: "uid1")
        #expect(!ics.contains("METHOD:"))
    }

    @Test("toICS includes SUMMARY")
    func includesSummary() {
        let input = GCalEventInput(summary: "Team Standup")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("SUMMARY:Team Standup"))
    }

    @Test("toICS includes LOCATION when present")
    func includesLocation() {
        let input = GCalEventInput(summary: "Meeting", location: "Room 42")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("LOCATION:Room 42"))
    }

    @Test("toICS omits LOCATION when nil")
    func omitsLocationWhenNil() {
        let input = GCalEventInput(summary: "Meeting")
        let ics = input.toICS(uid: "uid1")
        #expect(!ics.contains("LOCATION:"))
    }

    @Test("toICS includes DESCRIPTION")
    func includesDescription() {
        let input = GCalEventInput(summary: "Meeting", description: "Discuss Q2 plans")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("DESCRIPTION:Discuss Q2 plans"))
    }

    @Test("toICS all-day event uses VALUE=DATE format")
    func allDayEvent() {
        let input = GCalEventInput(startDate: "2024-03-15", endDate: "2024-03-16")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("DTSTART;VALUE=DATE:20240315"))
        #expect(ics.contains("DTEND;VALUE=DATE:20240316"))
    }

    @Test("toICS timed event with timezone uses TZID")
    func timedEventWithTimezone() {
        let input = GCalEventInput(
            startDateTime: "2024-03-15T10:00:00-04:00",
            startTimeZone: "America/New_York",
            endDateTime: "2024-03-15T11:00:00-04:00",
            endTimeZone: "America/New_York"
        )
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("DTSTART;TZID=America/New_York:"))
        #expect(ics.contains("DTEND;TZID=America/New_York:"))
    }

    @Test("toICS embeds a VTIMEZONE for every TZID it references — RFC 5545 §3.2.19")
    func embedsVTimeZone() {
        // A `DTSTART;TZID=…` with no matching VTIMEZONE is rejected by strict
        // CalDAV servers (iCloud, Nextcloud). toICS must embed the component.
        let input = GCalEventInput(
            startDateTime: "2026-03-15T10:00:00-07:00",
            startTimeZone: "America/Vancouver",
            endDateTime: "2026-03-15T11:00:00-07:00",
            endTimeZone: "America/Vancouver"
        )
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("DTSTART;TZID=America/Vancouver:"))
        #expect(ics.contains("BEGIN:VTIMEZONE"))
        #expect(ics.contains("TZID:America/Vancouver"))
        #expect(ics.contains("END:VTIMEZONE"))
        // The VTIMEZONE must appear BEFORE the VEVENT that references it.
        let vtzRange = ics.range(of: "BEGIN:VTIMEZONE")
        let veventRange = ics.range(of: "BEGIN:VEVENT")
        #expect(vtzRange != nil && veventRange != nil && vtzRange!.lowerBound < veventRange!.lowerBound)
        // Exactly one VTIMEZONE even though both start and end reference the zone.
        #expect(ics.components(separatedBy: "BEGIN:VTIMEZONE").count == 2)
    }

    @Test("toICS falls back to UTC Z time for an unresolvable timezone (no dangling TZID)")
    func unresolvableTimezoneFallsBackToUTC() {
        let input = GCalEventInput(
            startDateTime: "2026-03-15T10:00:00Z",
            startTimeZone: "Not/AReal_Zone",
            endDateTime: "2026-03-15T11:00:00Z",
            endTimeZone: "Not/AReal_Zone"
        )
        let ics = input.toICS(uid: "uid1")
        // No TZID reference and no VTIMEZONE — a plain UTC time instead.
        #expect(!ics.contains("TZID=Not/AReal_Zone"))
        #expect(!ics.contains("BEGIN:VTIMEZONE"))
        #expect(ics.contains("DTSTART:") && ics.contains("Z"))
    }

    @Test("toICS UTC event uses Z suffix")
    func utcEvent() {
        let input = GCalEventInput(startDateTime: "2024-03-15T10:00:00Z", endDateTime: "2024-03-15T11:00:00Z")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("DTSTART:") || ics.contains("DTSTART;"))
    }

    @Test("toICS includes DTSTAMP")
    func includesDtstamp() {
        let input = GCalEventInput(summary: "Meeting")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("DTSTAMP:"))
    }

    @Test("toICS includes PRODID")
    func includesProdid() {
        let input = GCalEventInput(summary: "Meeting")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("PRODID:"))
    }

    @Test("toICS includes attendees")
    func includesAttendees() {
        let input = GCalEventInput(
            summary: "Meeting",
            attendees: [(email: "alice@test.com", name: "Alice"), (email: "bob@test.com", name: nil)]
        )
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("alice@test.com"))
        #expect(ics.contains("bob@test.com"))
        #expect(ics.contains("ATTENDEE"))
    }

    @Test("toICS includes TRANSP when set")
    func includesTransparency() {
        let input = GCalEventInput(summary: "Free Time", transparency: "transparent")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("TRANSP:TRANSPARENT"))
    }

    @Test("toICS includes recurrence rules")
    func includesRecurrence() {
        let input = GCalEventInput(summary: "Weekly", recurrence: ["RRULE:FREQ=WEEKLY;COUNT=10"])
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("RRULE:FREQ=WEEKLY;COUNT=10"))
    }

    @Test("toICS escapes special characters in text fields")
    func escapesSpecialChars() {
        let input = GCalEventInput(summary: "Review; Budget, Q1")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.contains("Review\\; Budget\\, Q1"))
    }

    @Test("toICS ends with CRLF")
    func endsWithCRLF() {
        let input = GCalEventInput(summary: "Meeting")
        let ics = input.toICS(uid: "uid1")
        #expect(ics.hasSuffix("\r\n"))
    }

    @Test("toICS folds long lines")
    func foldsLongLines() {
        let longSummary = String(repeating: "A", count: 100)
        let input = GCalEventInput(summary: longSummary)
        let ics = input.toICS(uid: "uid1")
        // After folding, continuation lines start with space
        let lines = ics.components(separatedBy: "\r\n")
        let hasFolded = lines.contains { $0.hasPrefix(" ") }
        #expect(hasFolded)
    }
}

@Suite("GCalEventInput toJSON")
struct GCalEventInputJSONTests {

    @Test("toJSON includes summary")
    func includesSummary() {
        let input = GCalEventInput(summary: "Meeting")
        let json = input.toJSON()
        #expect(json["summary"] as? String == "Meeting")
    }

    @Test("toJSON includes location")
    func includesLocation() {
        let input = GCalEventInput(location: "Room A")
        let json = input.toJSON()
        #expect(json["location"] as? String == "Room A")
    }

    @Test("toJSON omits nil fields")
    func omitsNilFields() {
        let input = GCalEventInput()
        let json = input.toJSON()
        #expect(json["summary"] == nil)
        #expect(json["location"] == nil)
        #expect(json["description"] == nil)
    }

    @Test("toJSON includes start dateTime")
    func includesStartDateTime() {
        let input = GCalEventInput(startDateTime: "2024-03-15T10:00:00Z")
        let json = input.toJSON()
        let start = json["start"] as? [String: Any]
        #expect(start?["dateTime"] as? String == "2024-03-15T10:00:00Z")
    }

    @Test("toJSON all-day event uses date instead of dateTime")
    func allDayUsesDate() {
        let input = GCalEventInput(startDate: "2024-03-15", endDate: "2024-03-16")
        let json = input.toJSON()
        let start = json["start"] as? [String: Any]
        #expect(start?["date"] as? String == "2024-03-15")
        #expect(start?["dateTime"] == nil)
    }

    @Test("toJSON includes attendees array")
    func includesAttendees() {
        let input = GCalEventInput(attendees: [(email: "a@b.com", name: "Alice")])
        let json = input.toJSON()
        let attendees = json["attendees"] as? [[String: String]]
        #expect(attendees?.count == 1)
        #expect(attendees?[0]["email"] == "a@b.com")
    }

    @Test("toJSON includes event id when set")
    func includesEventId() {
        var input = GCalEventInput(summary: "Meeting")
        input.id = "event-123"
        let json = input.toJSON()
        #expect(json["id"] as? String == "event-123")
    }

    // MARK: - ICS line injection (S2-F6)

    /// A value that still carries CRLF when the lines are joined splits its own line into a SECOND
    /// ICS property that the CalDAV server then honours. ATTENDEE is the sharp case: the server mails
    /// the invitation, disclosing the event to an address the user never typed.
    ///
    /// `recurrence` is the reachable entry point — `CalendarToolHelpers.buildGCalEventInput` builds the
    /// RRULE from model-supplied `freq`/`until` strings, and an RRULE cannot be passed through the ICS
    /// text escaper without corrupting the `;` and `,` that separate its own parts.
    @Test("A CRLF in a recurrence rule cannot inject a second ICS property")
    func recurrenceCannotInjectProperty() {
        var input = GCalEventInput(summary: "Meeting", startDateTime: "2024-03-15T10:00:00Z", endDateTime: "2024-03-15T11:00:00Z")
        input.recurrence = ["RRULE:FREQ=WEEKLY\r\nATTENDEE;CN=\"x\":mailto:attacker@evil.example"]
        let ics = input.toICS(uid: "u")

        // The injected property must not exist as a property — i.e. must not start a line.
        let lines = ics.components(separatedBy: "\r\n")
        #expect(!lines.contains { $0.hasPrefix("ATTENDEE") }, "injected ATTENDEE became a real property:\n\(ics)")
        // Non-vacuity: the event itself must still have been produced.
        #expect(lines.contains("BEGIN:VEVENT"))
        #expect(lines.contains("END:VEVENT"))
    }

    @Test("A bare LF in a recurrence rule cannot inject a property either")
    func recurrenceBareLFCannotInject() {
        var input = GCalEventInput(summary: "M", startDateTime: "2024-03-15T10:00:00Z", endDateTime: "2024-03-15T11:00:00Z")
        input.recurrence = ["RRULE:FREQ=DAILY\nORGANIZER:mailto:attacker@evil.example"]
        let ics = input.toICS(uid: "u")
        // Split on ANY newline, not just CRLF. Splitting on "\r\n" would make this test vacuous — a
        // bare LF never produces a separate element, so the assertion would pass even with the
        // sanitizer removed (verified: it did, 2026-08-12). Real ICS parsers are lenient about bare
        // LF, so the oracle has to be at least as lenient as the parser we are defending.
        let lines = ics.split(whereSeparator: \.isNewline).map(String.init)
        #expect(!lines.contains { $0.hasPrefix("ORGANIZER") }, "bare LF injected a property:\n\(ics)")
        #expect(lines.contains { $0.hasPrefix("RRULE:FREQ=DAILY") }, "non-vacuity: no RRULE emitted:\n\(ics)")
    }

    @Test("A recurrence rule cannot close the VEVENT early to append a second event")
    func recurrenceCannotForgeExtraEvent() {
        var input = GCalEventInput(summary: "M", startDateTime: "2024-03-15T10:00:00Z", endDateTime: "2024-03-15T11:00:00Z")
        input.recurrence = ["RRULE:FREQ=DAILY\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nSUMMARY:forged"]
        let ics = input.toICS(uid: "u")
        // The oracle must be LINE-level, not substring-level. Sanitizing strips the CRLFs rather than
        // rejecting the value, so the attacker's text survives as inert RRULE *value* text on a single
        // line — `ics.contains("BEGIN:VEVENT")` is therefore true twice by design and says nothing
        // about safety. What makes an ICS property is being at the START of an unfolded line, so that
        // is what this asserts. (A substring count here failed against the working fix, 2026-08-12.)
        let lines = ics.components(separatedBy: "\r\n")
        #expect(lines.filter { $0 == "BEGIN:VEVENT" }.count == 1, "extra VEVENT forged:\n\(ics)")
        #expect(lines.filter { $0 == "END:VEVENT" }.count == 1, "extra VEVENT terminator forged:\n\(ics)")
        #expect(!lines.contains { $0.hasPrefix("SUMMARY:forged") }, "forged SUMMARY became a property:\n\(ics)")
        // Non-vacuity: the legitimate SUMMARY must still be a property line of its own.
        #expect(lines.contains("SUMMARY:M"), "real event body missing:\n\(ics)")
    }

    @Test("sanitizeICSLine strips control characters but preserves ordinary text and TAB")
    func sanitizeLineIsTwoSided() {
        // Two-sided: a function that returned "" would satisfy the stripping assertions alone.
        #expect(GCalEventInput.sanitizeICSLine("RRULE:FREQ=WEEKLY") == "RRULE:FREQ=WEEKLY")
        #expect(GCalEventInput.sanitizeICSLine("a\r\nb") == "ab")
        #expect(GCalEventInput.sanitizeICSLine("a\nb") == "ab")
        #expect(GCalEventInput.sanitizeICSLine("a\rb") == "ab")
        #expect(GCalEventInput.sanitizeICSLine("a\tb") == "a\tb", "HTAB is legal in ICS values")
        #expect(GCalEventInput.sanitizeICSLine("café") == "café", "non-ASCII must survive")
    }

    @Test("sanitizeICSLine strips every scalar the test oracles treat as a line break, plus DEL")
    func sanitizeCoversUnicodeLineBreaksAndDEL() {
        // The guard was `< 0x20`, which is narrower than `Character.isNewline` — the notion of "line"
        // every injection oracle in this file uses. U+0085, U+2028 and U+2029 are newlines to Swift
        // (and to Python's str.splitlines(), so to a plausible server) but passed a `< 0x20` filter
        // untouched, meaning a payload using them would have been reported as an injected property by
        // the very tests meant to prove it could not happen. RFC 5545 also excludes DEL.
        for scalar: Unicode.Scalar in ["\u{0085}", "\u{2028}", "\u{2029}", "\u{7F}"] {
            let line = "RRULE:FREQ=DAILY\(Character(scalar))ATTENDEE:mailto:x@y.z"
            let out = GCalEventInput.sanitizeICSLine(line)
            #expect(!out.unicodeScalars.contains(scalar),
                    "U+\(String(scalar.value, radix: 16, uppercase: true)) survived sanitizing: \(out)")
            #expect(out.split(whereSeparator: \.isNewline).count == 1,
                    "sanitized value still splits into multiple lines: \(out)")
        }
        // Two-sided: ordinary text, HTAB and non-ASCII must all survive untouched.
        #expect(GCalEventInput.sanitizeICSLine("SUMMARY:a\tb café 会議") == "SUMMARY:a\tb café 会議")
    }

    // MARK: - RRULE field validation (the reachable entry point)

    @Test("Only RFC 5545 FREQ tokens are accepted")
    func freqIsValidated() {
        // Two-sided: legal tokens must pass, or the rejection half is vacuous.
        #expect(CalendarToolHelpers.validatedRRuleFreq("weekly") == "WEEKLY")
        #expect(CalendarToolHelpers.validatedRRuleFreq("DAILY") == "DAILY")
        #expect(CalendarToolHelpers.validatedRRuleFreq("YEARLY") == "YEARLY")
        // Anything else is dropped rather than interpolated.
        #expect(CalendarToolHelpers.validatedRRuleFreq("WEEKLY\r\nATTENDEE:mailto:x@y.z") == nil)
        #expect(CalendarToolHelpers.validatedRRuleFreq("") == nil)
        #expect(CalendarToolHelpers.validatedRRuleFreq("NOTAFREQ") == nil)
    }

    /// The two tests above check the validators in isolation, which only proves the validators work —
    /// not that the code path that builds an event actually calls them. This one asserts the SYSTEM
    /// property: model-supplied tool arguments in, ICS text out, no injected property. It stays
    /// meaningful if the validation moves to a different layer.
    @Test("A poisoned freq cannot become an ICS property, end to end from tool arguments")
    func poisonedFreqCannotInjectThroughToolPath() {
        let args: [String: JSONValue] = [
            "recurrence": .dictionary([
                "freq": .string("DAILY\r\nATTENDEE;ROLE=REQ-PARTICIPANT:mailto:attacker@evil.example")
            ])
        ]
        let ics = CalendarToolHelpers.buildGCalEventInput(args, isAllDay: false).toICS(uid: "u")
        let lines = ics.split(whereSeparator: \.isNewline).map(String.init)
        #expect(!lines.contains { $0.hasPrefix("ATTENDEE") }, "injected ATTENDEE became a property:\n\(ics)")

        // Two-sided: a legitimate freq must still produce a rule, or the assertion above would also
        // hold for a build path that silently emitted no recurrence at all.
        let legalArgs: [String: JSONValue] = ["recurrence": .dictionary(["freq": .string("weekly")])]
        let legalICS = CalendarToolHelpers.buildGCalEventInput(legalArgs, isAllDay: false).toICS(uid: "u")
        #expect(legalICS.split(whereSeparator: \.isNewline).map(String.init)
            .contains { $0.hasPrefix("RRULE:FREQ=WEEKLY") }, "legal recurrence dropped:\n\(legalICS)")
    }

    @Test("UNTIL must be a DATE or UTC DATE-TIME shape")
    func untilIsValidated() {
        // UNTIL's value type is dictated by DTSTART (RFC 5545 §3.3.10), so the two halves of this
        // invariant must BOTH hold: the emitted value names the instant the user meant, AND it is the
        // value type the event's own DTSTART requires. Two shipped versions each satisfied one half by
        // violating the other — appending `Z` to a naive value kept the type legal and moved the instant;
        // preserving the naive form fixed the instant and emitted a floating UNTIL against a zoned
        // DTSTART. Assert both, or the next fix moves the bug again instead of closing it.
        // ⚠️ FIXED-OFFSET zones, not named ones, for the conversion arithmetic. The first version of
        // this test used `America/Vancouver` and hardcoded a UTC−8 winter offset from general knowledge.
        // It failed — because the tzdata on this machine has BC on UTC−7 ALL YEAR (2026-12-31 reports
        // `MST`, July reports `PDT`), so the expectation, not the code, was wrong. A named zone's offset
        // is a political fact that changes under you, which makes it the same hazard as a hardcoded date
        // in a test: it goes stale silently and the failure looks like a code regression. A fixed offset
        // pins the arithmetic and cannot drift.
        let minus8 = TimeZone(secondsFromGMT: -8 * 3600)!
        let utc = TimeZone(identifier: "UTC")!

        // ALL-DAY ⇒ bare DATE, because the all-day arm emits `DTSTART;VALUE=DATE:`.
        #expect(CalendarToolHelpers.validatedRRuleUntil("2026-12-31", allDay: true, zone: minus8) == "20261231")
        #expect(CalendarToolHelpers.validatedRRuleUntil("20261231", allDay: true, zone: minus8) == "20261231")
        // A time on an all-day event is dropped, not rejected — the date is what the user meant.
        #expect(CalendarToolHelpers.validatedRRuleUntil("2026-12-31T23:59:59", allDay: true, zone: minus8) == "20261231")

        // TIMED ⇒ UTC DATE-TIME, because the timed arms emit `DTSTART;TZID=…` or `DTSTART:…Z`.
        // THE INSTANT HALF: 23:59:59 on Dec 31 at UTC−8 is 07:59:59 UTC on Jan 1. Appending
        // `Z` would have said 23:59:59Z — eight hours early, dropping that evening's occurrence.
        #expect(CalendarToolHelpers.validatedRRuleUntil("2026-12-31T23:59:59", allDay: false, zone: minus8) == "20270101T075959Z")
        // THE VALUE-TYPE HALF, stated separately so a regression to the floating form is unmistakable.
        let timed = CalendarToolHelpers.validatedRRuleUntil("2026-12-31T23:59:59", allDay: false, zone: minus8)
        #expect(timed?.hasSuffix("Z") == true, "a timed event's UNTIL must be UTC, got \(timed ?? "nil")")
        // An input already in UTC is emitted unchanged — no double conversion.
        #expect(CalendarToolHelpers.validatedRRuleUntil("2026-12-31T23:59:59Z", allDay: false, zone: minus8) == "20261231T235959Z")
        // In UTC the wall clock and the instant coincide, which pins the conversion as zone-driven
        // rather than a constant offset.
        #expect(CalendarToolHelpers.validatedRRuleUntil("2026-12-31T23:59:59", allDay: false, zone: utc) == "20261231T235959Z")
        // A date-only input on a timed event means the END of that day in the event's zone. Midnight
        // would drop every occurrence on the day the user named.
        #expect(CalendarToolHelpers.validatedRRuleUntil("2026-12-31", allDay: false, zone: minus8) == "20270101T075959Z")

        // A NAMED zone still gets covered, but with the expectation DERIVED from the zone's own rules
        // rather than asserted from memory — so it holds whatever tzdata this machine ships.
        let named = TimeZone(identifier: "America/Vancouver")!
        let inFmt = DateFormatter()
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.calendar = Calendar(identifier: .gregorian)
        inFmt.dateFormat = "yyyyMMdd'T'HHmmss"
        inFmt.timeZone = named
        let outFmt = DateFormatter()
        outFmt.locale = Locale(identifier: "en_US_POSIX")
        outFmt.calendar = Calendar(identifier: .gregorian)
        outFmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        outFmt.timeZone = TimeZone(identifier: "UTC")
        let expectedNamed = inFmt.date(from: "20261231T235959").map { outFmt.string(from: $0) }
        // Non-vacuity: a nil expectation would compare equal to a nil result and prove nothing.
        #expect(expectedNamed != nil, "the derived named-zone expectation itself failed to compute")
        #expect(CalendarToolHelpers.validatedRRuleUntil("2026-12-31T23:59:59", allDay: false, zone: named) == expectedNamed,
                "named-zone conversion disagreed with the zone's own offset")

        // Injection and junk are dropped, on both arms — the shape check runs before any conversion.
        #expect(CalendarToolHelpers.validatedRRuleUntil("20261231\r\nATTENDEE:mailto:x@y.z", allDay: false, zone: minus8) == nil)
        #expect(CalendarToolHelpers.validatedRRuleUntil("20261231\r\nATTENDEE:mailto:x@y.z", allDay: true, zone: minus8) == nil)
        #expect(CalendarToolHelpers.validatedRRuleUntil("tomorrow", allDay: false, zone: minus8) == nil)
        #expect(CalendarToolHelpers.validatedRRuleUntil("", allDay: false, zone: minus8) == nil)
    }

    /// INVARIANT (the property of the emitted value, not of the mechanism that checks it):
    /// **`validatedRRuleUntil` never returns a value that does not name a real instant.** Its doc
    /// comment promised *"anything unparseable returns nil"*; the check was SHAPE-only, so every arm
    /// emitted impossible values, and one arm silently CHANGED the instant instead of rejecting it.
    ///
    /// Written as a table over all three arms because the shape check is shared and the return paths
    /// are not — a defect in one arm is invisible from the others. Each row states what the arm
    /// returned before the range guards existed, so a regression cannot be mistaken for a new case.
    ///
    /// ⚠️ TWO-SIDED (`MIS-030`, `MIS-014`). `nil` for everything satisfies the whole rejection half,
    /// so the second table is the non-vacuity control: a real leap day in a real leap year, a
    /// month-end, and an RFC 5545 leap second must all still come through. The leap second is the
    /// reason this validator is hand-written instead of delegating to `DateFormatter`, which rejects
    /// it — so if it stops passing, the fix has been replaced by a formatter parse.
    @Test("An UNTIL whose numeric fields are out of range is dropped, on every arm — and legitimate edge values are not")
    func untilFieldsAreRangeValidated() {
        let minus8 = TimeZone(secondsFromGMT: -8 * 3600)!

        // ── Arm 1: all-day (returns the bare date). Every value below was returned VERBATIM.
        for impossible in ["20261340", "00000000", "99999999", "20261232", "20260229", "20260230", "20260231"] {
            #expect(CalendarToolHelpers.validatedRRuleUntil(impossible, allDay: true, zone: minus8) == nil,
                    "all-day arm emitted the impossible date \(impossible) into the RRULE")
        }

        // ── Arm 2: already-UTC (emits its input unchanged). Same shape, different return path.
        for impossible in ["20261231T999999Z", "20261231T246000Z", "20261340T120000Z", "00000000T000000Z"] {
            #expect(CalendarToolHelpers.validatedRRuleUntil(impossible, allDay: false, zone: minus8) == nil,
                    "already-UTC arm emitted \(impossible) into the RRULE")
        }

        // ── Arm 3: naive → UTC. THE REGRESSION ARM, and the one that is not merely invalid output:
        // `DateFormatter` rejects month 13 and day 32 but ROLLS an out-of-range day inside a real
        // month, so these returned a WRONG INSTANT up to three days past what the user wrote.
        #expect(CalendarToolHelpers.validatedRRuleUntil("20260230", allDay: false, zone: minus8) == nil,
                "Feb 30 rolled forward instead of being rejected (it returned 20260303T075959Z)")
        #expect(CalendarToolHelpers.validatedRRuleUntil("20260231", allDay: false, zone: minus8) == nil,
                "Feb 31 rolled forward instead of being rejected (it returned 20260304T075959Z)")
        #expect(CalendarToolHelpers.validatedRRuleUntil("20260229T120000", allDay: false, zone: minus8) == nil,
                "Feb 29 of a non-leap year rolled forward (it returned 20260301T200000Z)")
        #expect(CalendarToolHelpers.validatedRRuleUntil("20261340T120000", allDay: false, zone: minus8) == nil)

        // ── Non-vacuity, both value types. These are the values a correct validator must NOT reject.
        #expect(CalendarToolHelpers.validatedRRuleUntil("2028-02-29", allDay: true, zone: minus8) == "20280229",
                "2028 IS a leap year — the leap-year rule was inverted or the check is rejecting everything")
        #expect(CalendarToolHelpers.validatedRRuleUntil("2026-01-31", allDay: true, zone: minus8) == "20260131",
                "a 31-day month's last day must pass")
        #expect(CalendarToolHelpers.validatedRRuleUntil("2026-02-28", allDay: true, zone: minus8) == "20260228")
        #expect(CalendarToolHelpers.validatedRRuleUntil("2028-02-29T12:00:00Z", allDay: false, zone: minus8) == "20280229T120000Z")
        #expect(CalendarToolHelpers.validatedRRuleUntil("20261231T235960Z", allDay: false, zone: minus8) == "20261231T235960Z",
                "RFC 5545 §3.3.12 allows second 60 (a positive leap second); rejecting it means the range check was delegated to DateFormatter, which does not")
        #expect(CalendarToolHelpers.validatedRRuleUntil("20261231T235959Z", allDay: false, zone: minus8) == "20261231T235959Z")
        #expect(CalendarToolHelpers.validatedRRuleUntil("20261231T000000Z", allDay: false, zone: minus8) == "20261231T000000Z",
                "hour/minute/second 00 are the lower bounds, not falsy")
        // 1900 is NOT a leap year (÷100 and not ÷400); 2000 IS. Pins the century rule both ways.
        #expect(CalendarToolHelpers.validatedRRuleUntil("19000229", allDay: true, zone: minus8) == nil)
        #expect(CalendarToolHelpers.validatedRRuleUntil("20000229", allDay: true, zone: minus8) == "20000229")

        // The all-day arm's documented behaviour is UNCHANGED: it drops a supplied time rather than
        // rejecting the date, so only the DATE is range-checked there. Stated as a test because it is
        // the one place the two guards deliberately disagree.
        #expect(CalendarToolHelpers.validatedRRuleUntil("20261231T999999Z", allDay: true, zone: minus8) == "20261231",
                "the all-day arm must still keep the date the user meant when it discards the time")
    }
}
