/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

// Tests for the pure ICS-manipulation helpers used by CalDAVProvider's
// recurring-event paths (updateOccurrence + splitSeries). These avoid HTTP and
// exercise just the text splicing logic.

@Suite("CalDAVProvider — ICS recurring helpers")
struct CalDAVRecurringHelpersTests {

    private let masterICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//TabMail//Test//EN
    BEGIN:VEVENT
    UID:abc-123
    DTSTAMP:20260513T120000Z
    DTSTART:20260513T170000Z
    DTEND:20260513T174500Z
    SUMMARY:Weekly sync
    LOCATION:Room 1
    RRULE:FREQ=WEEKLY;BYDAY=WE
    ATTENDEE;CN="Alice";ROLE=REQ-PARTICIPANT:mailto:alice@example.com
    ATTENDEE;CN="Bob";ROLE=REQ-PARTICIPANT:mailto:bob@example.com
    END:VEVENT
    END:VCALENDAR
    """.replacingOccurrences(of: "\n", with: "\r\n")

    @Test("extractUID pulls the master UID")
    func extractUID() {
        #expect(CalDAVProvider.extractUID(from: masterICS) == "abc-123")
    }

    @Test("extractRRule returns the full RRULE line")
    func extractRRule() {
        let r = CalDAVProvider.extractRRule(from: masterICS)
        #expect(r == "RRULE:FREQ=WEEKLY;BYDAY=WE")
    }

    @Test("replaceRRule swaps in the new value and keeps everything else intact")
    func replaceRRule() {
        let out = CalDAVProvider.replaceRRule(in: masterICS, newRRule: "RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20260519T235959Z")
        #expect(out.contains("RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20260519T235959Z"))
        #expect(!out.contains("RRULE:FREQ=WEEKLY;BYDAY=WE\r\n"), "old line still present unexpectedly")
        // Surrounding content survives.
        #expect(out.contains("SUMMARY:Weekly sync"))
        #expect(out.contains("UID:abc-123"))
        #expect(out.contains("ATTENDEE;CN=\"Alice\""))
    }

    @Test("replaceRRule targets the MASTER VEVENT's RRULE, never a leading VTIMEZONE's DST RRULE")
    func replaceRRuleIgnoresVTimezone() {
        // CRITICAL regression: real CalDAV resources lead with a VTIMEZONE whose
        // STANDARD/DAYLIGHT subcomponents carry their OWN RRULE. A naive
        // "first RRULE: in the resource" scan clobbers the timezone's DST rule
        // and leaves the event's recurrence untouched — corrupting the calendar.
        let icsWithVTimezone = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VTIMEZONE",
            "TZID:America/Vancouver",
            "BEGIN:DAYLIGHT",
            "DTSTART:20070311T020000",
            "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",   // ← timezone's DST rule — MUST survive
            "END:DAYLIGHT",
            "BEGIN:STANDARD",
            "DTSTART:20071104T020000",
            "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU",  // ← timezone's DST rule — MUST survive
            "END:STANDARD",
            "END:VTIMEZONE",
            "BEGIN:VEVENT",
            "UID:abc-123",
            "DTSTART;TZID=America/Vancouver:20260513T170000",
            "RRULE:FREQ=WEEKLY;BYDAY=WE",              // ← the EVENT's rule — the one to replace
            "SUMMARY:Weekly sync",
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n")

        let out = CalDAVProvider.replaceRRule(in: icsWithVTimezone, newRRule: "RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20260519T235959Z")
        // The VTIMEZONE's DST rules are untouched.
        #expect(out.contains("RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU"))
        #expect(out.contains("RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU"))
        // The EVENT's rule is the one that got capped.
        #expect(out.contains("RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20260519T235959Z"))
        #expect(!out.contains("RRULE:FREQ=WEEKLY;BYDAY=WE\r\n"), "the bare event RRULE should have been replaced")
    }

    @Test("replaceRRule drops a folded RRULE's continuation lines — no orphaned tail")
    func replaceRRuleDropsFoldedContinuation() {
        // RFC 5545 §3.1: a server may fold a long RRULE across physical lines
        // (continuations begin with a space/tab). Replacing only the first
        // physical `RRULE:` line would leave the continuation orphaned — a
        // parser unfolds it onto `newRRule`, corrupting the new rule.
        let icsFoldedRRule = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:abc-123",
            "DTSTART:20260513T170000Z",
            "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;INTERVAL=2;WKST=SU",
            " ;COUNT=100",                         // ← folded continuation of the RRULE
            "SUMMARY:Weekly sync",
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n")

        let out = CalDAVProvider.replaceRRule(in: icsFoldedRRule, newRRule: "RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20260519T235959Z")
        #expect(out.contains("RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20260519T235959Z"))
        // The old RRULE's folded tail must NOT survive — neither as a line nor
        // appended onto the new RRULE.
        #expect(!out.contains(";COUNT=100"), "orphaned continuation of the old RRULE leaked through")
        #expect(out.contains("SUMMARY:Weekly sync"), "the rest of the VEVENT must survive")
    }

    @Test("replaceRRule / spliceOrReplaceOverride tolerate bare-LF ICS resources (RFC 5545 §3.1)")
    func bareLineFeedICSHandling() {
        // Some CalDAV servers emit bare `\n` line endings. These helpers must
        // normalize before splitting — otherwise the whole resource is one
        // "line" and the RRULE cap / override splice silently no-ops.
        let bareLF = masterICS.replacingOccurrences(of: "\r\n", with: "\n")
        let capped = CalDAVProvider.replaceRRule(in: bareLF, newRRule: "RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20260519T235959Z")
        #expect(capped.contains("RRULE:FREQ=WEEKLY;BYDAY=WE;UNTIL=20260519T235959Z"))
        #expect(capped.contains("SUMMARY:Weekly sync"))

        let overrideBlock = "BEGIN:VEVENT\r\nUID:abc-123\r\nRECURRENCE-ID:20260520T170000\r\nSUMMARY:Override\r\nEND:VEVENT"
        let spliced = CalDAVProvider.spliceOrReplaceOverride(
            ics: bareLF, recurrenceId: "2026-05-20T17:00:00", kind: .floating, newOverrideBlock: overrideBlock
        )
        #expect(spliced.contains("SUMMARY:Override"))
        #expect(spliced.contains("END:VCALENDAR"))
        #expect(spliced.contains("SUMMARY:Weekly sync"), "the master VEVENT must survive the splice")
    }

    @Test("masterDTStartKind classifies all-day / UTC / floating / zoned DTSTART")
    func masterDTStartKindClassification() {
        func ics(_ dtstart: String) -> String {
            "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\n\(dtstart)\r\nEND:VEVENT\r\nEND:VCALENDAR"
        }
        #expect(CalDAVProvider.masterDTStartKind(from: ics("DTSTART;VALUE=DATE:20260520")) == .allDay)
        #expect(CalDAVProvider.masterDTStartKind(from: ics("DTSTART:20260520")) == .allDay)
        #expect(CalDAVProvider.masterDTStartKind(from: ics("DTSTART:20260520T170000Z")) == .utc)
        #expect(CalDAVProvider.masterDTStartKind(from: ics("DTSTART:20260520T170000")) == .floating)
        #expect(CalDAVProvider.masterDTStartKind(from: ics("DTSTART;TZID=America/Vancouver:20260520T170000")) == .zoned("America/Vancouver"))
        // Scoped to the master VEVENT — a leading VTIMEZONE's DTSTART must not win.
        let withVTZ = "BEGIN:VCALENDAR\r\nBEGIN:VTIMEZONE\r\nTZID:America/Vancouver\r\nBEGIN:STANDARD\r\nDTSTART:20071104T020000\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART;TZID=America/Vancouver:20260520T170000\r\nEND:VEVENT\r\nEND:VCALENDAR"
        #expect(CalDAVProvider.masterDTStartKind(from: withVTZ) == .zoned("America/Vancouver"))
    }

    @Test("spliceOrReplaceOverride appends a new override block when none exists")
    func spliceOrReplaceOverrideAppend() {
        let overrideBlock = "BEGIN:VEVENT\r\nUID:abc-123\r\nRECURRENCE-ID:20260520T170000\r\nSUMMARY:Different\r\nEND:VEVENT"
        let out = CalDAVProvider.spliceOrReplaceOverride(ics: masterICS, recurrenceId: "2026-05-20T17:00:00", kind: .floating, newOverrideBlock: overrideBlock)
        #expect(out.contains("SUMMARY:Weekly sync"))   // master preserved
        #expect(out.contains("SUMMARY:Different"))     // override added
        #expect(out.contains("RECURRENCE-ID:20260520T170000"))
        // Both VEVENT blocks must be inside the same VCALENDAR.
        let veventCount = out.components(separatedBy: "BEGIN:VEVENT").count - 1
        #expect(veventCount == 2)
    }

    @Test("spliceOrReplaceOverride replaces an existing override for the same recurrence-id")
    func spliceOrReplaceOverrideReplace() {
        let icsWithExisting = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:abc-123
        DTSTART:20260513T170000Z
        RRULE:FREQ=WEEKLY;BYDAY=WE
        SUMMARY:Weekly sync
        END:VEVENT
        BEGIN:VEVENT
        UID:abc-123
        RECURRENCE-ID:20260520T170000
        SUMMARY:Old override
        END:VEVENT
        END:VCALENDAR
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let newBlock = "BEGIN:VEVENT\r\nUID:abc-123\r\nRECURRENCE-ID:20260520T170000\r\nSUMMARY:New override\r\nEND:VEVENT"
        let out = CalDAVProvider.spliceOrReplaceOverride(ics: icsWithExisting, recurrenceId: "2026-05-20T17:00:00", kind: .floating, newOverrideBlock: newBlock)
        #expect(out.contains("SUMMARY:New override"))
        #expect(!out.contains("SUMMARY:Old override"))
        // Still just two VEVENTs total — master + replaced override.
        let veventCount = out.components(separatedBy: "BEGIN:VEVENT").count - 1
        #expect(veventCount == 2)
    }

    @Test("spliceOrReplaceOverride (all-day master) replaces — not duplicates — when recurrence_id carries a midnight time")
    func spliceOrReplaceOverrideAllDayMidnightTime() {
        // The first all-day occurrence edit emits `RECURRENCE-ID;VALUE=DATE:20260520`.
        // A second edit of the SAME occurrence may pass recurrence_id as a
        // midnight datetime ("2026-05-20T00:00:00"). With kind: .allDay the
        // splice must still match the date and REPLACE the override — appending
        // a duplicate VEVENT with the same UID+RECURRENCE-ID is malformed.
        let icsWithAllDayOverride = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:abc-123
        DTSTART;VALUE=DATE:20260513
        RRULE:FREQ=WEEKLY;BYDAY=WE
        SUMMARY:Weekly all-day
        END:VEVENT
        BEGIN:VEVENT
        UID:abc-123
        RECURRENCE-ID;VALUE=DATE:20260520
        SUMMARY:Old all-day override
        END:VEVENT
        END:VCALENDAR
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let newBlock = "BEGIN:VEVENT\r\nUID:abc-123\r\nRECURRENCE-ID;VALUE=DATE:20260520\r\nSUMMARY:New all-day override\r\nEND:VEVENT"
        let out = CalDAVProvider.spliceOrReplaceOverride(
            ics: icsWithAllDayOverride, recurrenceId: "2026-05-20T00:00:00",
            kind: .allDay, newOverrideBlock: newBlock
        )
        #expect(out.contains("SUMMARY:New all-day override"))
        #expect(!out.contains("SUMMARY:Old all-day override"))
        let veventCount = out.components(separatedBy: "BEGIN:VEVENT").count - 1
        #expect(veventCount == 2, "must replace the existing override, not append a duplicate")
    }

    // MARK: - TZID + duration extraction (regression coverage)

    @Test("parseICSDateTime parses TZID-qualified DTSTART in the named timezone")
    func parseICSDateTimeTZID() throws {
        let line = "DTSTART;TZID=America/Los_Angeles:20260520T170000"
        let date = try CalDAVProvider.parseICSDateTime(line, zones: .none)
        #expect(date != nil)
        // 5pm PT on 2026-05-20 — PT is UTC-7 (PDT). Spot-check the UTC instant
        // by reading back in UTC.
        if let date {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
            fmt.timeZone = TimeZone(identifier: "UTC")
            #expect(fmt.string(from: date) == "2026-05-21T00:00:00Z")
        }
    }

    @Test("parseICSDateTime parses zulu (Z) DTSTART as UTC")
    func parseICSDateTimeUTC() throws {
        let line = "DTSTART:20260520T170000Z"
        let date = try CalDAVProvider.parseICSDateTime(line, zones: .none)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        fmt.timeZone = TimeZone(identifier: "UTC")
        #expect(date != nil)
        if let date { #expect(fmt.string(from: date) == "2026-05-20T17:00:00Z") }
    }

    @Test("parseICSDateTime parses date-only all-day forms")
    func parseICSDateTimeDateOnly() throws {
        #expect(try CalDAVProvider.parseICSDateTime("DTSTART;VALUE=DATE:20990520", zones: .none) != nil)
        #expect(try CalDAVProvider.parseICSDateTime("DTSTART:20990520", zones: .none) != nil)
    }

    @Test("extractMasterDuration is correct when DTSTART/DTEND share a TZID")
    func extractMasterDurationTZID() throws {
        let ics = """
        BEGIN:VEVENT
        DTSTART;TZID=America/Los_Angeles:20260520T170000
        DTEND;TZID=America/Los_Angeles:20260520T174500
        END:VEVENT
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let d = try CalDAVProvider.extractMasterDuration(from: ics)
        #expect(d == TimeInterval(45 * 60))
    }

    // MARK: - R13-U2 — the DTSTART + DURATION form

    /// Format `date` as an ICS UTC (zulu) datetime value, e.g. `20260520T170000Z`.
    /// Derived from `Date()` at call time so no fixture date can go stale
    /// (project testing rule 7); the start instant is irrelevant to duration
    /// arithmetic, and the zulu form keeps DST out of it entirely.
    private func icsZulu(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    private func durationOnlyMaster(duration: String, start: String) -> String {
        [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:duration-master",
            "DTSTART:\(start)",
            "DURATION:\(duration)",
            "SUMMARY:Standup",
            "RRULE:FREQ=WEEKLY",
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n") + "\r\n"
    }

    @Test("extractMasterDuration reads the DTSTART + DURATION form (RFC 5545 §3.6.1)")
    func extractMasterDurationFromDurationProperty() throws {
        // DTEND and DURATION are ALTERNATIVES in RFC 5545 §3.6.1, and plenty of
        // clients emit the second. Reading DTEND only returned nil here, which
        // made an ordinary recurring master unsplittable.
        let start = icsZulu(Date())
        #expect(try CalDAVProvider.extractMasterDuration(
            from: durationOnlyMaster(duration: "PT1H30M", start: start)) == TimeInterval(90 * 60))
        #expect(try CalDAVProvider.extractMasterDuration(
            from: durationOnlyMaster(duration: "PT45M", start: start)) == TimeInterval(45 * 60))
        #expect(try CalDAVProvider.extractMasterDuration(
            from: durationOnlyMaster(duration: "P1D", start: start)) == TimeInterval(86400))
    }

    @Test("extractMasterDuration still returns nil for an unparseable or non-positive DURATION")
    func extractMasterDurationRejectsBadDuration() throws {
        // ⚠️ THE NEGATIVE CASE. The mirror image of the fix above is inventing a
        // duration from garbage — a new series of the wrong length is a silent
        // wrong-data write, which is worse than the refusal.
        let start = icsZulu(Date())
        #expect(try CalDAVProvider.extractMasterDuration(
            from: durationOnlyMaster(duration: "1H30M", start: start)) == nil)   // no leading P
        #expect(try CalDAVProvider.extractMasterDuration(
            from: durationOnlyMaster(duration: "PT0S", start: start)) == nil)    // zero length
        #expect(try CalDAVProvider.extractMasterDuration(
            from: durationOnlyMaster(duration: "", start: start)) == nil)
    }

    @Test("with neither DTEND nor DURATION an all-day series lasts one day and a timed one is refused")
    func extractMasterDurationImpliedEnd() throws {
        func master(_ dtstart: String) -> String {
            ["BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "UID:series-1", dtstart,
             "RRULE:FREQ=WEEKLY", "END:VEVENT", "END:VCALENDAR"].joined(separator: "\r\n") + "\r\n"
        }
        #expect(try CalDAVProvider.extractMasterDuration(from: master("DTSTART;VALUE=DATE:20990506")) == TimeInterval(86400))
        #expect(try CalDAVProvider.extractMasterDuration(from: master("DTSTART:20990506")) == TimeInterval(86400))
        // A timed start with no end lasts no time (RFC 5545 §3.6.1): not a length a split can copy.
        #expect(try CalDAVProvider.extractMasterDuration(from: master("DTSTART:20990506T170000Z")) == nil)
        // Zones at both ends of the offsets, so a start read in the device's zone can't pass on any runner.
        #expect(try CalDAVProvider.extractMasterDuration(from: master("DTSTART;TZID=Pacific/Kiritimati:20990506T170000")) == nil)
        #expect(try CalDAVProvider.extractMasterDuration(from: master("DTSTART;TZID=Pacific/Pago_Pago:20990506T170000")) == nil)
        // An end that is there but can't be read is still refused, not replaced by the implied one.
        let unreadableEnd = master("DTSTART;VALUE=DATE:20990506").replacingOccurrences(
            of: "RRULE:FREQ=WEEKLY", with: "DTEND;VALUE=DATE:2099MAY7\r\nRRULE:FREQ=WEEKLY")
        #expect(try CalDAVProvider.extractMasterDuration(from: unreadableEnd) == nil)
    }

    @Test("the implied end of a VEVENT with no DTEND and no DURATION, in the start's own form")
    func impliedEndValue() {
        #expect(ICSParser.impliedEndValue(dtstartParams: ";VALUE=DATE", dtstartValue: "20990506") == "20990507")
        #expect(ICSParser.impliedEndValue(dtstartParams: "VALUE=DATE", dtstartValue: "20991231") == "21000101")
        #expect(ICSParser.impliedEndValue(dtstartParams: nil, dtstartValue: "20990228") == "20990301")
        // The days clocks spring forward in the US and the EU that year: still the next date.
        #expect(ICSParser.impliedEndValue(dtstartParams: ";VALUE=DATE", dtstartValue: "20990308") == "20990309")
        #expect(ICSParser.impliedEndValue(dtstartParams: ";VALUE=DATE", dtstartValue: "20990329") == "20990330")
        #expect(ICSParser.impliedEndValue(dtstartParams: ";TZID=Europe/Paris", dtstartValue: "20990506T170000") == "20990506T170000")
        #expect(ICSParser.impliedEndValue(dtstartParams: ";VALUE=DATE-TIME", dtstartValue: "20990506T170000Z") == "20990506T170000Z")
        #expect(ICSParser.impliedEndValue(dtstartParams: ";VALUE=DATE", dtstartValue: "2099MAY6") == nil)
    }

    @Test("DTEND wins over DURATION on a non-conforming master that carries both")
    func extractMasterDurationPrefersDTEND() throws {
        // RFC 5545 forbids both in one VEVENT. If a server sends both anyway,
        // the pre-existing DTEND reading must not silently change meaning.
        let now = Date()
        let ics = [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "UID:both-master",
            "DTSTART:\(icsZulu(now))",
            "DTEND:\(icsZulu(now.addingTimeInterval(15 * 60)))",
            "DURATION:PT9H",
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n") + "\r\n"
        #expect(try CalDAVProvider.extractMasterDuration(from: ics) == TimeInterval(15 * 60))
    }

    @Test("The DURATION arm stays scoped to the master VEVENT, ignoring VTIMEZONE and override blocks")
    func extractMasterDurationDurationIsVEventScoped() throws {
        // The scoping this function already had must survive the new arm: a
        // VTIMEZONE's own DTSTART lines and an override VEVENT's DURATION must
        // both be invisible.
        let start = icsZulu(Date())
        let ics = [
            "BEGIN:VCALENDAR",
            "BEGIN:VTIMEZONE",
            "TZID:America/Los_Angeles",
            "BEGIN:DAYLIGHT",
            "DTSTART:20070311T020000",
            "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
            "END:DAYLIGHT",
            "END:VTIMEZONE",
            "BEGIN:VEVENT",
            "UID:scoped-master",
            "DTSTART:\(start)",
            "DURATION:PT30M",
            "RRULE:FREQ=WEEKLY",
            "END:VEVENT",
            "BEGIN:VEVENT",
            "UID:scoped-master",
            "RECURRENCE-ID:\(start)",
            "DTSTART:\(start)",
            "DURATION:PT8H",
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n") + "\r\n"
        #expect(try CalDAVProvider.extractMasterDuration(from: ics) == TimeInterval(30 * 60),
                "the override's PT8H or the VTIMEZONE's DTSTART leaked into the master's duration")
    }

    @Test("VEVENT-scoped extractors ignore a leading VTIMEZONE block (RRULE/DTSTART/UID/duration)")
    func extractorsIgnoreVTimezone() throws {
        // A real CalDAV .ics resource leads with a VTIMEZONE whose
        // STANDARD/DAYLIGHT subcomponents have their OWN DTSTART + RRULE (the
        // timezone's DST rule). A naive "first RRULE/DTSTART" scan would grab
        // those — catastrophic: splitSeries would cap the event with the
        // timezone's FREQ=YEARLY rule. The extractors must scope to the master
        // VEVENT (the one with no RECURRENCE-ID).
        let ics = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VTIMEZONE",
            "TZID:America/Los_Angeles",
            "BEGIN:DAYLIGHT",
            "DTSTART:20070311T020000",
            "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",   // ← timezone's own RRULE
            "TZOFFSETFROM:-0800",
            "TZOFFSETTO:-0700",
            "END:DAYLIGHT",
            "BEGIN:STANDARD",
            "DTSTART:20071104T020000",
            "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU",
            "END:STANDARD",
            "END:VTIMEZONE",
            "BEGIN:VEVENT",
            "UID:weekly-sync-abc",
            "DTSTART;TZID=America/Los_Angeles:20260513T170000",
            "DTEND;TZID=America/Los_Angeles:20260513T174500",
            "SUMMARY:Weekly sync",
            "RRULE:FREQ=WEEKLY;BYDAY=WE",                // ← the event's RRULE
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n") + "\r\n"

        // RRULE: must be the EVENT's weekly rule, not the timezone's yearly one.
        #expect(CalDAVProvider.extractRRule(from: ics) == "RRULE:FREQ=WEEKLY;BYDAY=WE")
        // UID: the event's.
        #expect(CalDAVProvider.extractUID(from: ics) == "weekly-sync-abc")
        // isAllDay: the event is timed (TZID datetime), not all-day — must NOT
        // be misled by the VTIMEZONE's bare-ish DTSTART lines.
        #expect(CalDAVProvider.icsIsAllDay(ics) == false)
        // DTSTART day: the event's, not the timezone's 2007 DTSTART, so a
        // split counts the series' occurrences from the series' own start.
        #expect(CalDAVProvider.masterDTStartDay(from: ics) == RecurrenceTail.Day(year: 2026, month: 5, day: 13))
        // Duration: 45 min from the EVENT's DTSTART/DTEND, not the timezone's.
        #expect(try CalDAVProvider.extractMasterDuration(from: ics) == TimeInterval(45 * 60))
    }

    @Test("masterTopLevelLines picks the VEVENT with no RECURRENCE-ID, skipping override blocks")
    func masterTopLevelLinesSkipsOverrides() {
        // Master + an existing override in the same resource. The extractors
        // must read the MASTER (no RECURRENCE-ID), not the override.
        let ics = [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "UID:evt-1",
            "RECURRENCE-ID:20260520T170000",            // ← override block, comes FIRST
            "SUMMARY:Override title",
            "DTSTART:20260520T180000Z",
            "END:VEVENT",
            "BEGIN:VEVENT",
            "UID:evt-1",
            "DTSTART:20260513T170000Z",
            "RRULE:FREQ=WEEKLY",                         // ← master's rule
            "SUMMARY:Master title",
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n") + "\r\n"
        let masterLines = CalDAVProvider.masterTopLevelLines(ics)
        #expect(masterLines.contains("RRULE:FREQ=WEEKLY"))
        #expect(masterLines.contains("SUMMARY:Master title"))
        #expect(!masterLines.contains("SUMMARY:Override title"))
        #expect(!masterLines.contains(where: { $0.hasPrefix("RECURRENCE-ID") }))
        #expect(CalDAVProvider.extractRRule(from: ics) == "RRULE:FREQ=WEEKLY")
    }

    @Test("recurrenceIdsMatch uses EXACT equality — no truncated-prefix false positives")
    func recurrenceIdsMatchExact() {
        // Same instant, different formats — must match.
        #expect(CalDAVProvider.recurrenceIdsMatch("2026-05-20T17:00:00", "20260520T170000"))
        // UTC Z suffix tolerated on either side.
        #expect(CalDAVProvider.recurrenceIdsMatch("20260520T170000Z", "20260520T170000"))
        #expect(CalDAVProvider.recurrenceIdsMatch("2026-05-20T17:00:00", "20260520T170000Z"))
        // Regression: a truncated value must NOT prefix-match a fuller one —
        // an earlier `hasPrefix` impl false-matched here and would splice an
        // override onto the wrong occurrence.
        #expect(!CalDAVProvider.recurrenceIdsMatch("20260520T17", "20260520T170000"))
        #expect(!CalDAVProvider.recurrenceIdsMatch("2026-05-20", "20260520T170000"))
        // Genuinely different occurrences must not match.
        #expect(!CalDAVProvider.recurrenceIdsMatch("2026-05-20T17:00:00", "2026-05-27T17:00:00"))
        #expect(!CalDAVProvider.recurrenceIdsMatch("20260520T170000", "20260520T170001"))
    }

    @Test("recurrenceIdsMatch allDay mode compares the DATE portion only")
    func recurrenceIdsMatchAllDay() {
        // All-day master: the spliced override emits a bare date while the
        // caller-supplied recurrence_id may carry a midnight time. With
        // allDay:true they must match on the date so a re-edit REPLACES.
        #expect(CalDAVProvider.recurrenceIdsMatch("20260520", "2026-05-20T00:00:00", allDay: true))
        #expect(CalDAVProvider.recurrenceIdsMatch("2026-05-20", "20260520", allDay: true))
        // Different dates still must not match.
        #expect(!CalDAVProvider.recurrenceIdsMatch("20260520", "2026-05-27T00:00:00", allDay: true))
        // Without allDay (default), the date-vs-datetime mismatch stands —
        // exact equality, no relaxation.
        #expect(!CalDAVProvider.recurrenceIdsMatch("20260520", "2026-05-20T00:00:00"))
    }

    @Test("parseICSDateTime refuses an unrecognized TZID by naming it, never reading it in the device zone")
    func parseICSDateTimeUnknownTZID() throws {
        // A TZID TabMail does not recognize must NOT be reinterpreted in the
        // device zone: that would corrupt the absolute instant (and thus
        // extractMasterDuration) of a write. It is refused, naming the zone.
        let line = "DTSTART;TZID=Customized Time Zone:20990520T170000"
        #expect {
            _ = try CalDAVProvider.parseICSDateTime(line, zones: .none)
        } throws: { error in
            guard case CalendarProviderError.notSupported(let reason) = error else { return false }
            return reason.contains("\"Customized Time Zone\"")
        }
        // A Windows zone name (common in Outlook exports) is recognized, at the
        // same instant as its CLDR zone.
        #expect(try CalDAVProvider.parseICSDateTime("DTSTART;TZID=Central European Standard Time:20990520T170000", zones: .none)
                == CalDAVProvider.parseICSDateTime("DTSTART;TZID=Europe/Warsaw:20990520T170000", zones: .none))
        // A recognized IANA TZID still parses fine.
        #expect(try CalDAVProvider.parseICSDateTime("DTSTART;TZID=America/Los_Angeles:20990520T170000", zones: .none) != nil)
        // Floating time (no TZID) still parses (device-local interpretation).
        #expect(try CalDAVProvider.parseICSDateTime("DTSTART:20990520T170000", zones: .none) != nil)
    }

    @Test("extractMasterDuration refuses when one DTSTART/DTEND line has an unrecognized TZID")
    func extractMasterDurationUnknownTZID() throws {
        // If either endpoint can't be read (unrecognized TZID), the duration is
        // unrecoverable: the split is refused, naming the zone, rather than
        // producing a series with a wrong-length duration.
        let ics = """
        BEGIN:VEVENT
        DTSTART;TZID=Customized Time Zone:20990520T140000
        DTEND;TZID=America/Los_Angeles:20260520T150000
        END:VEVENT
        """.replacingOccurrences(of: "\n", with: "\r\n")
        #expect {
            _ = try CalDAVProvider.extractMasterDuration(from: ics)
        } throws: { error in
            guard case CalendarProviderError.notSupported(let reason) = error else { return false }
            return reason.contains("\"Customized Time Zone\"")
        }
    }

    @Test("icsIsAllDay detects VALUE=DATE and bare 8-digit DTSTART forms")
    func icsIsAllDayDetection() {
        // VALUE=DATE form.
        let allDayICS = "BEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20260520\r\nEND:VEVENT\r\n"
        #expect(CalDAVProvider.icsIsAllDay(allDayICS) == true)
        // Bare 8-digit form.
        let bareICS = "BEGIN:VEVENT\r\nDTSTART:20260520\r\nEND:VEVENT\r\n"
        #expect(CalDAVProvider.icsIsAllDay(bareICS) == true)
        // Timed event — not all-day.
        let timedICS = "BEGIN:VEVENT\r\nDTSTART:20260520T170000Z\r\nEND:VEVENT\r\n"
        #expect(CalDAVProvider.icsIsAllDay(timedICS) == false)
        // TZID-qualified timed event — not all-day.
        let tzICS = "BEGIN:VEVENT\r\nDTSTART;TZID=America/Los_Angeles:20260520T170000\r\nEND:VEVENT\r\n"
        #expect(CalDAVProvider.icsIsAllDay(tzICS) == false)
    }

    @Test("extractMasterDuration returns nil when DTSTART/DTEND missing or malformed")
    func extractMasterDurationMissing() throws {
        let ics = """
        BEGIN:VEVENT
        SUMMARY:Nothing here
        END:VEVENT
        """.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try CalDAVProvider.extractMasterDuration(from: ics) == nil)
    }

    @Test("the series' UID, rule and start are read from the series alone, in every resource layout",
          arguments: MasterReadFixture.Frame.allCases, MasterReadFixture.Layout.allCases)
    func masterReadersReadTheSeriesOwnLines(_ frame: MasterReadFixture.Frame, _ layout: MasterReadFixture.Layout) throws {
        let ics = MasterReadFixture.resource(frame, layout)
        #expect(CalDAVProvider.extractUID(from: ics) == MasterReadFixture.uid)
        #expect(CalDAVProvider.extractRRule(from: ics) == MasterReadFixture.rrule)
        #expect(CalDAVProvider.masterDTStartDay(from: ics) == MasterReadFixture.startDay)
        #expect(CalDAVProvider.icsIsAllDay(ics) == (frame == .allDay))
        #expect(CalDAVProvider.masterDTStartKind(from: ics) == frame.kind)
        #expect(try CalDAVProvider.masterStartWallTime(in: ics) == MasterReadFixture.wallTime(frame))
    }
}

/// A resource whose series is preceded by everything a reader of the series must skip: a
/// VTIMEZONE with its own `DTSTART` and `RRULE` (zoned series), and a changed occurrence with its
/// own `UID` line and a `DTSTART` on another day. The series' alarm comes after its properties
/// (RFC 5545 order) and carries its own `UID` (RFC 9074). Dates are relative to today.
enum MasterReadFixture {
    static let uid = "series-603"
    static let rrule = "RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR"

    enum Frame: String, CaseIterable, Sendable {
        case allDay, utc, floating, zoned

        var kind: CalDAVProvider.MasterDTStartKind {
            switch self {
            case .allDay: return .allDay
            case .utc: return .utc
            case .floating: return .floating
            case .zoned: return .zoned("America/New_York")
            }
        }
    }

    enum Layout: String, CaseIterable, Sendable {
        /// CRLF line endings.
        case crlf
        /// Bare LF line endings.
        case bareLF
        /// CRLF, with the series' UID, rule and start folded across lines.
        case folded
        /// The series' alarm opened and closed in lower case.
        case lowercaseAlarm
    }

    private static let utcZone = TimeZone(identifier: "UTC") ?? .current

    /// The series' first day: two weeks from today.
    static let startDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utcZone
        return cal.startOfDay(for: Date().addingTimeInterval(14 * 86_400))
    }()

    static var startDay: RecurrenceTail.Day? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utcZone
        let parts = cal.dateComponents([.year, .month, .day], from: startDate)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return RecurrenceTail.Day(year: year, month: month, day: day)
    }

    private static func compact(_ date: Date, time: String?) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = utcZone
        fmt.dateFormat = "yyyyMMdd"
        return fmt.string(from: date) + (time.map { "T\($0)" } ?? "")
    }

    /// The series' `DTSTART` line, 17:00 on its first day in a timed frame.
    static func dtstart(_ frame: Frame, day: Date = startDate) -> String {
        switch frame {
        case .allDay: return "DTSTART;VALUE=DATE:\(compact(day, time: nil))"
        case .utc: return "DTSTART:\(compact(day, time: "170000"))Z"
        case .floating: return "DTSTART:\(compact(day, time: "170000"))"
        case .zoned: return "DTSTART;TZID=America/New_York:\(compact(day, time: "170000"))"
        }
    }

    /// The wall clock the series' start names: its first day at 00:00 (all-day) or 17:00, as
    /// seconds from 1970 read as if UTC.
    static func wallTime(_ frame: Frame) -> CalDAVProvider.ICSWallTime {
        let seconds = Int(startDate.timeIntervalSince1970) + (frame == .allDay ? 0 : 17 * 3_600)
        return CalDAVProvider.ICSWallTime(frame: frame.kind, wall: seconds)
    }

    /// `line` split after `at` characters into a folded continuation.
    private static func fold(_ line: String, at: Int) -> [String] {
        [String(line.prefix(at)), " " + String(line.dropFirst(at))]
    }

    static func resource(_ frame: Frame, _ layout: Layout) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN"]
        if frame == .zoned {
            lines += ["BEGIN:VTIMEZONE", "TZID:America/New_York",
                      "BEGIN:DAYLIGHT", "DTSTART:20070311T020000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
                      "TZOFFSETFROM:-0500", "TZOFFSETTO:-0400", "END:DAYLIGHT",
                      "BEGIN:STANDARD", "DTSTART:20071104T020000", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU",
                      "TZOFFSETFROM:-0400", "TZOFFSETTO:-0500", "END:STANDARD", "END:VTIMEZONE"]
        }
        let changedDay = startDate.addingTimeInterval(2 * 86_400)
        let recurrenceId = dtstart(frame, day: changedDay).replacingOccurrences(of: "DTSTART", with: "RECURRENCE-ID")
        lines += ["BEGIN:VEVENT", "UID:\(uid)", recurrenceId,
                  dtstart(frame, day: changedDay.addingTimeInterval(86_400)), "SUMMARY:Planning (moved)", "END:VEVENT"]

        let folds = layout == .folded
        lines += ["BEGIN:VEVENT"]
        lines += folds ? fold("UID:\(uid)", at: 7) : ["UID:\(uid)"]
        lines += ["DTSTAMP:\(compact(Date(), time: "000000"))Z"]
        lines += folds ? fold(dtstart(frame), at: 12) : [dtstart(frame)]
        lines += frame == .allDay ? ["DURATION:P1D"] : ["DURATION:PT1H"]
        lines += folds ? fold(rrule, at: 20) : [rrule]
        lines += ["SUMMARY:Planning"]
        let alarm = ["BEGIN:VALARM", "UID:alarm-of-\(uid)", "ACTION:DISPLAY", "DESCRIPTION:Reminder",
                     "TRIGGER:-PT15M", "END:VALARM"]
        lines += layout == .lowercaseAlarm
            ? alarm.map { $0.hasPrefix("BEGIN:") || $0.hasPrefix("END:") ? $0.lowercased() : $0 }
            : alarm
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: layout == .bareLF ? "\n" : "\r\n") + (layout == .bareLF ? "\n" : "\r\n")
    }
}

// MARK: - mergePatchIntoICS

@Suite("CalDAVProvider — mergePatchIntoICS")
struct CalDAVMergePatchTests {
    private let masterICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:abc-123
    DTSTAMP:20260513T120000Z
    DTSTART;TZID=America/Los_Angeles:20260513T170000
    DTEND;TZID=America/Los_Angeles:20260513T180000
    SUMMARY:Original title
    LOCATION:Original room
    ATTENDEE;CN="Alice";ROLE=REQ-PARTICIPANT:mailto:alice@example.com
    END:VEVENT
    END:VCALENDAR
    """.replacingOccurrences(of: "\n", with: "\r\n")

    @Test("recurrence-only patch preserves DTSTART/SUMMARY (regression: iCloud 403 on partial overwrites)")
    func recurrenceOnlyPreservesEverythingElse() throws {
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=WEEKLY"]
        let merged = try CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
        #expect(merged.contains("RRULE:FREQ=WEEKLY"))
        #expect(merged.contains("DTSTART;TZID=America/Los_Angeles:20260513T170000"))
        #expect(merged.contains("DTEND;TZID=America/Los_Angeles:20260513T180000"))
        #expect(merged.contains("SUMMARY:Original title"))
        #expect(merged.contains("LOCATION:Original room"))
        #expect(merged.contains("alice@example.com"))
        // Still a single VEVENT.
        #expect(merged.components(separatedBy: "BEGIN:VEVENT").count - 1 == 1)
    }

    @Test("setting summary replaces in master, preserves the rest")
    func updateSummary() throws {
        var patch = GCalEventInput()
        patch.summary = "New title"
        let merged = try CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
        #expect(merged.contains("SUMMARY:New title"))
        #expect(!merged.contains("SUMMARY:Original title"))
        #expect(merged.contains("DTSTART"))
        #expect(merged.contains("alice@example.com"))
    }

    @Test("clearing location with empty string removes the LOCATION line entirely")
    func clearLocation() throws {
        var patch = GCalEventInput()
        patch.location = ""
        let merged = try CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
        #expect(!merged.contains("LOCATION:"))
        // Other fields intact.
        #expect(merged.contains("SUMMARY:Original title"))
        #expect(merged.contains("alice@example.com"))
    }

    @Test("replacing attendees removes the old set and inserts the new")
    func replaceAttendees() throws {
        var patch = GCalEventInput()
        patch.attendees = [(email: "bob@example.com", name: "Bob")]
        let merged = try CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
        #expect(merged.contains("bob@example.com"))
        #expect(!merged.contains("alice@example.com"))
        // No duplicate VEVENT and structural fields preserved.
        #expect(merged.components(separatedBy: "BEGIN:VEVENT").count - 1 == 1)
        #expect(merged.contains("DTSTART"))
    }

    @Test("changing DTSTART/DTEND on a zoned master re-emits in TZID form")
    func updateZonedDTStart() throws {
        var patch = GCalEventInput()
        patch.startDateTime = "2026-05-20T15:00:00-07:00"
        patch.endDateTime = "2026-05-20T16:00:00-07:00"
        patch.startTimeZone = "America/Los_Angeles"
        patch.endTimeZone = "America/Los_Angeles"
        let merged = try CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
        #expect(merged.contains("DTSTART;TZID=America/Los_Angeles:20260520T150000"))
        #expect(merged.contains("DTEND;TZID=America/Los_Angeles:20260520T160000"))
        // Old timed lines gone.
        #expect(!merged.contains("DTSTART;TZID=America/Los_Angeles:20260513T170000"))
    }

    @Test("only fields IN the patch are touched — empty patch returns input unchanged")
    func emptyPatchIsIdentity() throws {
        let merged = try CalDAVProvider.mergePatchIntoICS(masterICS, patch: GCalEventInput())
        // Every line of the original survives (order/CRLF preserved).
        #expect(merged == masterICS)
    }

    @Test("appending RRULE when master has none inserts before END:VEVENT")
    func appendNewRRule() throws {
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=DAILY;COUNT=5"]
        let merged = try CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
        #expect(merged.contains("RRULE:FREQ=DAILY;COUNT=5"))
        // Still well-formed: one BEGIN/END pair, RRULE inside.
        let lines = merged.components(separatedBy: "\r\n")
        let rruleIdx = lines.firstIndex { $0.hasPrefix("RRULE:") }
        let endIdx = lines.firstIndex(of: "END:VEVENT")
        if let r = rruleIdx, let e = endIdx { #expect(r < e) }
    }

    /// Which of the VEVENT's own `BEGIN`/`END` lines a server wrote with trailing whitespace.
    enum PaddedMarker: String, CaseIterable, Sendable {
        case begin = "BEGIN:VEVENT"
        case end = "END:VEVENT"
        case both = "BEGIN:VEVENT and END:VEVENT"
    }

    @Test("a VEVENT whose BEGIN or END line ends in whitespace is still read and written",
          arguments: PaddedMarker.allCases, [" ", "\t"])
    func paddedVEventMarkersAreReadAndWritten(_ padded: PaddedMarker, _ pad: String) throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let start = utc.startOfDay(for: Date().addingTimeInterval(10 * 86_400)).addingTimeInterval(9 * 3_600)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = utc.timeZone
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let begin = "BEGIN:VEVENT" + (padded == .end ? "" : pad)
        let end = "END:VEVENT" + (padded == .begin ? "" : pad)
        let ics = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN", begin,
            "UID:padded-603", "DTSTAMP:\(fmt.string(from: Date()))", "DTSTART:\(fmt.string(from: start))",
            "DURATION:PT1H", "SUMMARY:Planning", end, "END:VCALENDAR",
        ].joined(separator: "\r\n") + "\r\n"

        // Read as the writer reads it.
        #expect(CalDAVProvider.extractUID(from: ics) == "padded-603")
        #expect(CalDAVProvider.masterTopLevelLines(ics).contains("SUMMARY:Planning"))

        // Written: a rename replaces the title and new notes go inside the VEVENT.
        var patch = GCalEventInput()
        patch.summary = "Planning review"
        patch.description = "Agenda"
        let merged = try CalDAVProvider.mergePatchIntoICS(ics, patch: patch)
        let lines = merged.components(separatedBy: "\r\n")
        let text = Comment(rawValue: merged)
        #expect(lines.filter { $0.hasPrefix("SUMMARY") } == ["SUMMARY:Planning review"], text)
        let beginAt = try #require(lines.firstIndex(of: begin), text)
        let endAt = try #require(lines.firstIndex(of: end), text)
        let notesAt = try #require(lines.firstIndex(of: "DESCRIPTION:Agenda"), text)
        #expect(beginAt < notesAt && notesAt < endAt, text)
        // Every line not changed is kept byte for byte, the padded ones included.
        #expect(lines.filter { !$0.hasPrefix("SUMMARY") && !$0.hasPrefix("DESCRIPTION") }
                == ics.components(separatedBy: "\r\n").filter { !$0.hasPrefix("SUMMARY") }, text)
    }

    /// Which component lines of `PaddedSeries` carry trailing whitespace.
    enum Padding: String, CaseIterable, Sendable {
        case begin = "every BEGIN:VEVENT"
        case end = "every END:VEVENT"
        case calendarEnd = "END:VCALENDAR"
    }

    /// A weekly series from 09:00 UTC ten days from today, one excluded date a week in, and a changed
    /// occurrence at two weeks (and, with `laterChange`, another at four weeks); the lines `padded`
    /// names carry trailing whitespace.
    private struct PaddedSeries {
        let padded: Padding
        let laterChange: Bool
        let start: Date
        let fmt: DateFormatter

        init(_ padded: Padding, laterChange: Bool = false) {
            self.padded = padded
            self.laterChange = laterChange
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC") ?? .current
            start = utc.startOfDay(for: Date().addingTimeInterval(10 * 86_400)).addingTimeInterval(9 * 3_600)
            fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = utc.timeZone
            fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        }

        func stamp(days: Int, hours: Int = 0) -> String {
            fmt.string(from: start.addingTimeInterval(TimeInterval(days * 86_400 + hours * 3_600)))
        }

        func naive(days: Int) -> String {
            let naive = DateFormatter()
            naive.locale = Locale(identifier: "en_US_POSIX")
            naive.timeZone = fmt.timeZone
            naive.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return naive.string(from: start.addingTimeInterval(TimeInterval(days * 86_400)))
        }

        var begin: String { padded == .begin ? "BEGIN:VEVENT " : "BEGIN:VEVENT" }
        var end: String { padded == .end ? "END:VEVENT\t" : "END:VEVENT" }

        func change(days: Int) -> [String] {
            [begin, "UID:padded-series-603", "DTSTAMP:\(stamp(days: 0))", "RECURRENCE-ID:\(stamp(days: days))",
             "DTSTART:\(stamp(days: days, hours: 1))", "DURATION:PT1H", "SUMMARY:Planning (moved)", end]
        }

        var ics: String {
            ([
                "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN",
                begin, "UID:padded-series-603", "DTSTAMP:\(stamp(days: 0))", "DTSTART:\(stamp(days: 0))",
                "DURATION:PT1H", "RRULE:FREQ=WEEKLY", "EXDATE:\(stamp(days: 7))", "SUMMARY:Planning", end,
            ] + change(days: 14) + (laterChange ? change(days: 28) : [])
              + [padded == .calendarEnd ? "END:VCALENDAR " : "END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
        }

        /// A line without its trailing whitespace.
        static func unpadded(_ line: String) -> String {
            line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }

        /// The resource's VEVENTs, each as its logical lines without the BEGIN and END lines.
        static func vevents(_ ics: String) -> [[String]] {
            var out: [[String]] = []
            var current: [String]?
            for line in ics.components(separatedBy: "\r\n") {
                let marker = unpadded(line)
                if marker == "BEGIN:VEVENT" { current = []; continue }
                if marker == "END:VEVENT", let block = current { out.append(block); current = nil; continue }
                current?.append(line)
            }
            return out
        }
    }

    @Test("a padded VEVENT line does not stop a new rule replacing the series' rule",
          arguments: [Padding.begin, .end])
    func paddedVEventMarkersRuleReplaced(_ padded: Padding) {
        let series = PaddedSeries(padded)
        let replaced = CalDAVProvider.replaceRRule(in: series.ics, newRRule: "RRULE:FREQ=DAILY;COUNT=5")
        let text = Comment(rawValue: replaced)
        let before = series.ics.components(separatedBy: "\r\n")
        let after = replaced.components(separatedBy: "\r\n")
        // Only the series' rule line changed; every other line is kept byte for byte.
        #expect(after.filter { $0.hasPrefix("RRULE") } == ["RRULE:FREQ=DAILY;COUNT=5"], text)
        #expect(after.filter { !$0.hasPrefix("RRULE") } == before.filter { !$0.hasPrefix("RRULE") }, text)
    }

    @Test("a padded VEVENT line does not stop a moved start moving the excluded date and the changed occurrence",
          arguments: [Padding.begin, .end])
    func paddedVEventMarkersStartShifted(_ padded: Padding) throws {
        let series = PaddedSeries(padded)
        var patch = GCalEventInput()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        patch.startDateTime = iso.string(from: series.start.addingTimeInterval(3_600))
        let merged = try CalDAVProvider.mergePatchIntoICS(series.ics, patch: patch)
        let text = Comment(rawValue: merged)
        let events = PaddedSeries.vevents(merged)
        #expect(events.count == 2, text)
        guard events.count == 2 else { return }
        #expect(events[0].filter { $0.hasPrefix("DTSTART") } == ["DTSTART:\(series.stamp(days: 0, hours: 1))"], text)
        #expect(events[0].filter { $0.hasPrefix("EXDATE") } == ["EXDATE:\(series.stamp(days: 7, hours: 1))"], text)
        #expect(events[1].filter { $0.hasPrefix("RECURRENCE-ID") } == ["RECURRENCE-ID:\(series.stamp(days: 14, hours: 1))"], text)
        // The changed occurrence keeps its own time.
        #expect(events[1].filter { $0.hasPrefix("DTSTART") } == ["DTSTART:\(series.stamp(days: 14, hours: 1))"], text)
    }

    /// Which occurrence a one-occurrence edit changes: one with no change of its own yet, or the one
    /// the resource already holds a change for.
    enum OccurrenceEdited: String, CaseIterable, Sendable {
        case new = "an occurrence not changed before"
        case existing = "the occurrence changed before"
    }

    @Test("a padded VEVENT or VCALENDAR line does not lose or duplicate a one-occurrence change",
          arguments: Padding.allCases, OccurrenceEdited.allCases)
    func paddedVEventMarkersOccurrenceChanged(_ padded: Padding, _ edited: OccurrenceEdited) throws {
        let series = PaddedSeries(padded)
        let days = edited == .new ? 21 : 14
        let written = try CalDAVProvider.occurrenceOverrideResource(
            storedICS: series.ics, recurrenceIdNaive: series.naive(days: days),
            patch: { var p = GCalEventInput(); p.summary = "Planning (changed)"; return p }(), now: Date())
        let text = Comment(rawValue: written)
        let events = PaddedSeries.vevents(written)
        // The series, the occurrence changed before, and the new change when it is a new one.
        #expect(events.count == (edited == .new ? 3 : 2), text)
        let changed = events.filter { $0.contains("RECURRENCE-ID:\(series.stamp(days: days))") }
        #expect(changed.count == 1, text)
        #expect(changed.first?.filter { $0.hasPrefix("SUMMARY") } == ["SUMMARY:Planning (changed)"], text)
        #expect(written.components(separatedBy: "\r\n").last { !$0.isEmpty }.map(PaddedSeries.unpadded) == "END:VCALENDAR", text)
    }

    @Test("a padded VEVENT line does not stop a split capping the series and moving the later change to the new part",
          arguments: [Padding.begin, .end])
    func paddedVEventMarkersSplit(_ padded: Padding) throws {
        let series = PaddedSeries(padded, laterChange: true)
        let cappedRule = "RRULE:FREQ=WEEKLY;UNTIL=\(series.fmt.string(from: series.start.addingTimeInterval(21 * 86_400 - 1)))"
        let resources = try CalDAVProvider.seriesSplitResources(
            storedICS: series.ics, slotNaiveISO: series.naive(days: 21), cappedRRule: cappedRule,
            newRRule: "RRULE:FREQ=WEEKLY", newUid: "padded-split-603",
            patch: { var p = GCalEventInput(); p.summary = "Planning, new room"; return p }(), now: Date())
        func ids(_ events: [[String]]) -> [String] { events.flatMap { $0.filter { $0.hasPrefix("RECURRENCE-ID") } } }

        let capped = PaddedSeries.vevents(resources.cappedSeries)
        let cappedText = Comment(rawValue: resources.cappedSeries)
        #expect(capped.count == 2, cappedText)
        guard capped.count == 2 else { return }
        // The series is capped before the split and keeps only the change before it.
        #expect(capped[0].filter { $0.hasPrefix("RRULE") } == [cappedRule], cappedText)
        #expect(capped[0].filter { $0.hasPrefix("UID") } == ["UID:padded-series-603"], cappedText)
        #expect(ids(capped) == ["RECURRENCE-ID:\(series.stamp(days: 14))"], cappedText)

        let newPart = PaddedSeries.vevents(resources.newPart)
        let newText = Comment(rawValue: resources.newPart)
        #expect(newPart.count == 2, newText)
        guard newPart.count == 2 else { return }
        // The new part starts at the split under its own UID and takes the change after it.
        #expect(newPart.allSatisfy { $0.contains("UID:padded-split-603") }, newText)
        #expect(newPart[0].filter { $0.hasPrefix("DTSTART") } == ["DTSTART:\(series.stamp(days: 21))"], newText)
        #expect(newPart[0].filter { $0.hasPrefix("RRULE") } == ["RRULE:FREQ=WEEKLY"], newText)
        #expect(ids(newPart) == ["RECURRENCE-ID:\(series.stamp(days: 28))"], newText)
    }

    @Test("a folded continuation that reads END:VEVENT is not the VEVENT's end")
    func continuationIsNotAMarker() {
        #expect(!CalDAVProvider.isMarker(" END:VEVENT", "END:VEVENT"))
        #expect(!CalDAVProvider.isMarker("\tBEGIN:VEVENT", "BEGIN:VEVENT"))
        #expect(CalDAVProvider.isMarker("END:VEVENT \t", "END:VEVENT"))
        // On a physical-line writer: the notes are folded so a continuation line is " END:VEVENT".
        let ics = [
            "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:folded-603", "DESCRIPTION:Agenda",
            " END:VEVENT", "RRULE:FREQ=WEEKLY", "SUMMARY:Planning", "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n") + "\r\n"
        let replaced = CalDAVProvider.replaceRRule(in: ics, newRRule: "RRULE:FREQ=DAILY;COUNT=5")
        #expect(replaced == ics.replacingOccurrences(of: "RRULE:FREQ=WEEKLY", with: "RRULE:FREQ=DAILY;COUNT=5"),
                Comment(rawValue: replaced))
    }
}

// MARK: - splitSeries over the wire

/// A minimal WebDAV/CalDAV resource store: enough of RFC 4918 §10.4 for a
/// `PUT`'s precondition to decide its own response.
///
/// **Modelling the precondition is the entire point.** A fake that answers 200
/// to every `PUT` cannot tell a rollback that WORKS from one that is
/// structurally guaranteed to fail, so it would have stayed green against the
/// defect this suite exists to pin — and a green suite over an impossible
/// rollback is exactly how that defect survived repeated review.
final class FakeCalDAVStore: Sendable {
    private struct Resource: Sendable {
        var ics: String
        var etag: String
    }

    /// One recorded `PUT`, so a test can assert on the conditional headers that
    /// actually left the client rather than on the outcome alone.
    struct RecordedPut: Sendable {
        let path: String
        let ifMatch: String?
        let ifNoneMatch: String?
        /// The entity tag this PUT's own response carried, or nil when it was
        /// refused (412). A later PUT's `If-Match` can then be compared against
        /// the tag an EARLIER PUT minted, which is the only way to state "the
        /// rollback is conditional on the body we ourselves wrote" without
        /// hardcoding the fake's tag numbering.
        let returnedETag: String?
    }

    private struct State: Sendable {
        var resources: [String: Resource] = [:]
        var puts: [RecordedPut] = []
        var nextETag = 1
    }

    private let state = Mutex(State())

    /// Whether this server returns an `ETag` response header on `GET`.
    ///
    /// **Non-defaulted on purpose.** RFC 4791 says a CalDAV server SHOULD
    /// return entity tags, not MUST, and `CalendarSetupView.connectCalDAV()`
    /// hands `addCalDAVAccount` an arbitrary user-entered server URL — so the
    /// no-ETag branch is a real server population, not an iCloud
    /// hypothetical. That branch stayed invisible through repeated review
    /// precisely because every fixture silently modelled the ETag-serving
    /// server; making the choice unstateable-by-omission is what stops that
    /// recurring.
    private let servesETags: Bool

    /// Whether a `PUT` holding a VEVENT that has attendees and no organizer is refused with 403
    /// and changes nothing, as iCloud does (RFC 5545 §3.8.4.3; measured for a changed occurrence).
    private let refusesAttendeesWithoutOrganizer: Bool

    init(servesETags: Bool, refusesAttendeesWithoutOrganizer: Bool = false) {
        self.servesETags = servesETags
        self.refusesAttendeesWithoutOrganizer = refusesAttendeesWithoutOrganizer
    }

    func seed(path: String, ics: String) {
        state.withLock { $0.resources[path] = Resource(ics: ics, etag: "\"seed\"") }
    }

    /// The entity tag this store currently holds for `path`, or nil when it is
    /// absent — used by the held-direction assertions to prove an `If-Match`
    /// carried the CURRENT tag rather than merely being non-nil.
    func storedETag(path: String) -> String? {
        state.withLock { $0.resources[path]?.etag }
    }

    func storedICS(path: String) -> String? {
        state.withLock { $0.resources[path]?.ics }
    }

    func recordedPuts() -> [RecordedPut] {
        state.withLock { $0.puts }
    }

    func handleGET(_ request: FakeHTTP.Request) -> FakeHTTP.CannedResponse {
        let path = request.url.path
        guard let resource = state.withLock({ $0.resources[path] }) else {
            return .raw(statusCode: 404)
        }
        var headers = ["Content-Type": "text/calendar; charset=utf-8"]
        if servesETags { headers["ETag"] = resource.etag }
        return .raw(
            statusCode: 200,
            headers: headers,
            body: Data(resource.ics.utf8)
        )
    }

    /// RFC 4918 §10.4 / RFC 9110 §13.1: `If-None-Match: *` succeeds only when
    /// the resource is ABSENT; `If-Match` succeeds only when the current entity
    /// tag matches. Neither header present ⇒ unconditional overwrite.
    func handlePUT(_ request: FakeHTTP.Request) -> FakeHTTP.CannedResponse {
        let path = request.url.path
        let ifMatch = request.header("If-Match")
        let ifNoneMatch = request.header("If-None-Match")
        let body = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let refused = refusesAttendeesWithoutOrganizer && VEventOracle.vevents(body).contains {
            !VEventOracle.own($0, "ATTENDEE").isEmpty && VEventOracle.own($0, "ORGANIZER").isEmpty
        }

        return state.withLock { value -> FakeHTTP.CannedResponse in
            func record(_ returnedETag: String?) {
                value.puts.append(RecordedPut(
                    path: path, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch,
                    returnedETag: returnedETag))
            }
            if refused {
                record(nil)
                return .raw(statusCode: 403)
            }
            let existing = value.resources[path]
            if ifNoneMatch == "*", existing != nil {
                record(nil)
                return .raw(statusCode: 412)
            }
            if let ifMatch, existing?.etag != ifMatch {
                record(nil)
                return .raw(statusCode: 412)
            }
            let etag = "\"v\(value.nextETag)\""
            value.nextETag += 1
            value.resources[path] = Resource(ics: body, etag: etag)
            record(etag)
            return .raw(statusCode: 204, headers: ["ETag": etag])
        }
    }

    /// A DIFFERENT client replaces `path`, minting a tag that is distinguishable
    /// from anything this client wrote. Models an edit landing between two of
    /// this client's writes.
    func replaceOutOfBand(path: String, ics: String) {
        state.withLock { value in
            let etag = "\"other-\(value.nextETag)\""
            value.nextETag += 1
            value.resources[path] = Resource(ics: ics, etag: etag)
        }
    }

    /// An RFC 4791 §7.8 `calendar-query` REPORT: every resource under the
    /// collection the request addresses, each with its entity tag and its WHOLE
    /// calendar data (a series together with its changed occurrences, as a real
    /// server returns it), in a 207 multistatus. The query's time-range filter is
    /// not modelled: every resource is returned, so it is the client's own range
    /// check that decides which occurrences a listing shows.
    func handleREPORT(_ request: FakeHTTP.Request) -> FakeHTTP.CannedResponse {
        let collection = request.url.path
        let matches: [(path: String, etag: String, ics: String)] = state.withLock { value in
            value.resources
                .filter { $0.key.hasPrefix(collection) && $0.key != collection }
                .sorted { $0.key < $1.key }
                .map { (path: $0.key, etag: $0.value.etag, ics: $0.value.ics) }
        }
        var xml = #"<?xml version="1.0" encoding="utf-8"?>"# + "\n"
        xml += #"<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">"# + "\n"
        for match in matches {
            xml += "<d:response><d:href>\(Self.xmlEscaped(match.path))</d:href><d:propstat><d:prop>"
            xml += "<d:getetag>\(Self.xmlEscaped(match.etag))</d:getetag>"
            xml += "<c:calendar-data>\(Self.xmlEscaped(match.ics))</c:calendar-data>"
            xml += "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>\n"
        }
        xml += "</d:multistatus>"
        return .raw(
            statusCode: 207,
            headers: ["Content-Type": "application/xml; charset=utf-8"],
            body: Data(xml.utf8))
    }

    /// A WebDAV `DELETE` (RFC 4918 §9.6): the resource is gone for good, 204, or
    /// 404 when there was none. Removing it for real is what lets a test assert
    /// the series is still there rather than only that no request was counted.
    func handleDELETE(_ request: FakeHTTP.Request) -> FakeHTTP.CannedResponse {
        let path = request.url.path
        let removed = state.withLock { $0.resources.removeValue(forKey: path) }
        return .raw(statusCode: removed == nil ? 404 : 204)
    }

    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// The shared wire fixture for every `CalDAVProvider`-over-HTTP suite in this
/// file. ONE fixture, deliberately: the rollback suite and the precondition
/// suite must exercise the same master resource and the same provider wiring,
/// or a change to one silently stops covering the other.
enum CalDAVWireFixture {

    static let calendarHome = URL(string: "https://caldav.example.com/cal/")!
    static let calendarId = "/cal/"
    static let masterEventId = "/cal/master.ics"
    static let masterPath = "/cal/master.ics"

    /// Naive wall-clock ISO in the device zone — the exact shape
    /// `splitSeries` and `updateOccurrence` accept as a `recurrence_id`.
    static func naiveISO(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static func icsUTC(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Dates are derived from `Date()`, never written as literals — a literal
    /// here goes stale silently and fails months later for the wrong reason.
    struct Fixture {
        let masterICS: String
        let recurrenceId: String
    }

    /// The series starts on a Wednesday (in UTC, its frame) a week or more from now, and the
    /// `recurrence_id` is the Wednesday two weeks later: an occurrence the series has, as
    /// `updateOccurrence` and `splitSeries` require.
    static func make() -> Fixture {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let wednesday = 4
        var start = Date().addingTimeInterval(7 * 24 * 60 * 60)
        while utcCalendar.component(.weekday, from: start) != wednesday {
            start = start.addingTimeInterval(24 * 60 * 60)
        }
        let end = start.addingTimeInterval(45 * 60)
        let splitAt = start.addingTimeInterval(14 * 24 * 60 * 60)
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//TabMail//Test//EN
        BEGIN:VEVENT
        UID:master-1
        DTSTAMP:\(icsUTC(start))
        DTSTART:\(icsUTC(start))
        DTEND:\(icsUTC(end))
        SUMMARY:Weekly sync
        RRULE:FREQ=WEEKLY;BYDAY=WE
        END:VEVENT
        END:VCALENDAR
        """.replacingOccurrences(of: "\n", with: "\r\n")
        return Fixture(masterICS: ics, recurrenceId: naiveISO(splitAt))
    }

    static func makeProvider(_ scenario: FakeHTTP.Scenario) -> CalDAVProvider {
        CalDAVProvider(
            client: CalDAVClient(
                username: "user@example.com", password: "pw", session: scenario.session),
            calendarHomeURL: calendarHome,
            serverBaseURL: calendarHome
        )
    }
}

@Suite("CalDAVProvider — a split it can't build writes nothing", .serialized)
struct CalDAVSplitRefusedBeforeWriteTests {

    @Test("a series whose excluded dates can't be read is refused before the cap, so it keeps every meeting")
    func unreadableExcludedDatesWriteNothing() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        let fixture = CalDAVWireFixture.make()
        let ics = fixture.masterICS.replacingOccurrences(
            of: "RRULE:FREQ=WEEKLY;BYDAY=WE",
            with: "RRULE:FREQ=WEEKLY;BYDAY=WE\r\nEXDATE;TZID=Not/AZone:20990101T090000")
        #expect(ics != fixture.masterICS, "setup: the excluded date was not added")
        store.seed(path: CalDAVWireFixture.masterPath, ics: ics)
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }

        await #expect {
            _ = try await CalDAVWireFixture.makeProvider(http).splitSeries(
                calendarId: CalDAVWireFixture.calendarId,
                eventId: CalDAVWireFixture.masterEventId,
                recurrenceId: fixture.recurrenceId,
                recurrenceIdZone: .current,
                patch: GCalEventInput(),
                sendUpdates: "none")
        } throws: { error in
            if case CalendarProviderError.notSupported = error { return true }
            return false
        }

        #expect(store.recordedPuts().isEmpty, "the split wrote before it was refused")
        #expect(store.storedICS(path: CalDAVWireFixture.masterPath) == ics)
    }
}

@Suite("CalDAVProvider — splitSeries writes the new part before the cap", .serialized)
struct CalDAVSplitRollbackTests {

    private static let calendarId = CalDAVWireFixture.calendarId
    private static let masterEventId = CalDAVWireFixture.masterEventId
    private static let masterPath = CalDAVWireFixture.masterPath

    private static func makeFixture() -> CalDAVWireFixture.Fixture { CalDAVWireFixture.make() }

    private static func makeProvider(_ scenario: FakeHTTP.Scenario) -> CalDAVProvider {
        CalDAVWireFixture.makeProvider(scenario)
    }

    private static func split(_ provider: CalDAVProvider, _ fixture: CalDAVWireFixture.Fixture) async throws {
        _ = try await provider.splitSeries(
            calendarId: Self.calendarId,
            eventId: Self.masterEventId,
            recurrenceId: fixture.recurrenceId,
            recurrenceIdZone: .current,
            patch: GCalEventInput(),
            sendUpdates: "none")
    }

    private static func newPartPath(_ fixture: CalDAVWireFixture.Fixture) -> String {
        "/cal/\(GoogleCalendarProvider.deterministicSplitEventId(masterId: Self.masterEventId, recurrenceId: fixture.recurrenceId)).ics"
    }

    @Test("when the new part can't be written, the series is not touched")
    func failedNewPartWriteLeavesTheSeriesUntouched() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        let fixture = Self.makeFixture()
        store.seed(path: Self.masterPath, ics: fixture.masterICS)
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
        // Longest prefix wins: this route claims the new part's PUT.
        http.register(path: Self.newPartPath(fixture), method: "PUT", response: .status(500))

        await #expect(throws: (any Error).self) {
            try await Self.split(Self.makeProvider(http), fixture)
        }

        #expect(store.storedICS(path: Self.masterPath) == fixture.masterICS,
                "the series must keep every occurrence when there is no new part to take them")
        #expect(store.recordedPuts().allSatisfy { $0.path != Self.masterPath }, "the series was written")
        #expect(store.storedICS(path: Self.newPartPath(fixture)) == nil)
    }

    @Test("""
    a concurrent edit of the series between the two writes survives: the cap is refused, and \
    the retry caps the series as it now stands
    """)
    func concurrentEditBeforeTheCapSurvives() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        let fixture = Self.makeFixture()
        store.seed(path: Self.masterPath, ics: fixture.masterICS)
        let concurrentICS = fixture.masterICS
            .replacingOccurrences(of: "SUMMARY:Weekly sync", with: "SUMMARY:Renamed by another client")
        let editedOnce = Mutex(false)
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
        http.register(path: Self.newPartPath(fixture), method: "PUT") { request in
            let response = store.handlePUT(request)
            // Another client edits the series right after our new part lands.
            if editedOnce.withLock({ done in defer { done = true }; return !done }) {
                store.replaceOutOfBand(path: Self.masterPath, ics: concurrentICS)
            }
            return response
        }
        let provider = Self.makeProvider(http)

        await #expect(throws: (any Error).self) { try await Self.split(provider, fixture) }
        #expect(store.storedICS(path: Self.masterPath) == concurrentICS,
                "the cap overwrote an edit it never read")

        try await Self.split(provider, fixture)
        let master = try #require(store.storedICS(path: Self.masterPath))
        #expect(master.contains("UNTIL=") && master.contains("SUMMARY:Renamed by another client"),
                "the retry must cap the series as the other client left it: \(master)")
        #expect(store.storedICS(path: Self.newPartPath(fixture)) != nil)
    }

    @Test("""
    Lost ACK — when the deterministic successor resource already exists and \
    carries OUR derived UID, the split goes on to the cap instead of \
    wedging the account's calendar queue on a 412
    """)
    func splitRetiresWhenItsOwnSuccessorAlreadyExists() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        let fixture = Self.makeFixture()
        store.seed(path: Self.masterPath, ics: fixture.masterICS)

        let newUid = GoogleCalendarProvider.deterministicSplitEventId(
            masterId: Self.masterEventId, recurrenceId: fixture.recurrenceId)
        let successorPath = "/cal/\(newUid).ics"
        // The state a lost ACK leaves behind: a previous attempt's successor PUT
        // committed, so the resource is present and its master VEVENT carries the
        // deterministic UID this call would derive.
        let existingSuccessorICS = fixture.masterICS
            .replacingOccurrences(of: "UID:master-1", with: "UID:\(newUid)")
        store.seed(path: successorPath, ics: existingSuccessorICS)

        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }

        let provider = Self.makeProvider(http)
        let result = try await provider.splitSeries(
            calendarId: Self.calendarId,
            eventId: Self.masterEventId,
            recurrenceId: fixture.recurrenceId,
            recurrenceIdZone: .current,
            patch: GCalEventInput(),
            sendUpdates: "none")

        // THE INVARIANT, three ways — the split is COMPLETE.
        // 1. The call returns, so the queue takes its success exit. Throwing here
        //    throws `CalDAVError.preconditionFailed`, which
        //    `AccountManager.isCalendarBadRequestError` does not
        //    classify, so the op requeues forever and its account joins
        //    `failedAccounts` — the wedge, which is a dropped user intention.
        #expect(result.id == successorPath)
        // 2. The series is CAPPED, so its later occurrences show once.
        let master = store.storedICS(path: Self.masterPath)
        #expect(master?.contains("UNTIL=") == true,
                "the series must be capped — left open, every later occurrence shows twice")
        // 3. The successor is byte-unchanged. Recognising it must never become a
        //    licence to overwrite a series the user may have edited.
        #expect(store.storedICS(path: successorPath) == existingSuccessorICS,
                "the existing successor must not be rewritten")
        let successorPuts = store.recordedPuts().filter { $0.path == successorPath }
        #expect(successorPuts.count == 1)
        #expect(successorPuts.first?.ifNoneMatch == "*",
                "the successor PUT stays CREATE-ONLY — the held direction is not weakened by the lost-ACK exit")
        #expect(store.recordedPuts().filter { $0.path == Self.masterPath }.count == 1,
                "exactly the cap PUT")
    }

    @Test("""
    Held direction — a foreign resource sitting at the successor URL is NOT \
    mistaken for our own write: the split stops with the series untouched \
    rather than reporting a success it has no evidence for
    """)
    func foreignResourceAtTheSuccessorURLStillRollsBack() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        let fixture = Self.makeFixture()
        store.seed(path: Self.masterPath, ics: fixture.masterICS)

        let successorPath = Self.newPartPath(fixture)
        // Same URL, DIFFERENT content owner. `newEventURL` is a path we chose, so
        // occupancy alone proves nothing; only the UID inside the body does.
        let foreignICS = fixture.masterICS
            .replacingOccurrences(of: "UID:master-1", with: "UID:somebody-elses-event")
        store.seed(path: successorPath, ics: foreignICS)

        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }

        await #expect(throws: (any Error).self) {
            try await Self.split(Self.makeProvider(http), fixture)
        }

        // THE INVARIANT: absence of evidence is never permission. Without a
        // positive UID match there is no new part, so the series keeps everything.
        #expect(store.storedICS(path: Self.masterPath) == fixture.masterICS,
                "the series must be untouched when the successor URL holds someone else's event")
        #expect(store.recordedPuts().allSatisfy { $0.path != Self.masterPath }, "the series was written")
        #expect(store.storedICS(path: successorPath) == foreignICS,
                "the foreign resource must be untouched")
    }

    // MARK: Changed occurrences and extra dates

    /// The fixture series with an excluded date, an extra date and a changed occurrence on each side
    /// of the split. Every instant is distinct from the series' own start, end, stamp and cap.
    private struct Dated {
        let ics: String
        let before: [String]
        let after: [String]
    }

    private static func dated(_ fixture: CalDAVWireFixture.Fixture) throws -> Dated {
        let utc = CalDAVWireFixture.icsUTC
        let start = Date().addingTimeInterval(7 * 86_400)
        func day(_ n: Double, hour: Double = 0) -> String { utc(start.addingTimeInterval(n * 86_400 + hour * 3_600)) }
        // The split is fourteen days after the series' start.
        let excludedBefore = day(7), extraBefore = day(8, hour: 2), changedBefore = day(9, hour: 3)
        let excludedAfter = day(21), extraAfter = day(22, hour: 2), changedAfter = day(23, hour: 3)
        func changed(_ instant: String, _ summary: String) -> String {
            ["BEGIN:VEVENT", "UID:master-1", "DTSTAMP:\(instant)", "RECURRENCE-ID:\(instant)",
             "DTSTART:\(instant)", "DURATION:PT45M", "SUMMARY:\(summary)", "END:VEVENT"].joined(separator: "\r\n")
        }
        let ics = fixture.masterICS
            .replacingOccurrences(
                of: "RRULE:FREQ=WEEKLY;BYDAY=WE",
                with: "RRULE:FREQ=WEEKLY;BYDAY=WE\r\nEXDATE:\(excludedBefore),\(excludedAfter)\r\nRDATE:\(extraBefore),\(extraAfter)")
            .replacingOccurrences(
                of: "END:VCALENDAR",
                with: changed(changedBefore, "Changed before") + "\r\n" + changed(changedAfter, "Changed after") + "\r\nEND:VCALENDAR")
        #expect(ics.contains("EXDATE:") && ics.contains("Changed after"), "setup: the dates were not added")
        return Dated(ics: ics,
                     before: [excludedBefore, extraBefore, changedBefore, "SUMMARY:Changed before"],
                     after: [excludedAfter, extraAfter, changedAfter, "SUMMARY:Changed after"])
    }

    private static func expectPartition(_ store: FakeCalDAVStore, _ fixture: CalDAVWireFixture.Fixture,
                                        _ dated: Dated) throws {
        let master = try #require(store.storedICS(path: Self.masterPath))
        let newPart = try #require(store.storedICS(path: Self.newPartPath(fixture)), "there is no new part")
        #expect(master.contains("UNTIL="), "the series was not capped")
        for item in dated.before {
            #expect(master.contains(item), "the series lost '\(item)'")
            #expect(!newPart.contains(item), "the new part took '\(item)' from before the split")
        }
        for item in dated.after {
            #expect(newPart.contains(item), "the new part lost '\(item)'")
            #expect(!master.contains(item), "the series kept '\(item)', so it shows on both parts")
        }
    }

    @Test("excluded dates, extra dates and changed occurrences each end up in exactly one part")
    func changedAndExtraDatesSplitBetweenTheParts() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        let fixture = Self.makeFixture()
        let dated = try Self.dated(fixture)
        store.seed(path: Self.masterPath, ics: dated.ics)
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }

        try await Self.split(Self.makeProvider(http), fixture)

        try Self.expectPartition(store, fixture, dated)
        #expect(store.recordedPuts().map(\.path) == [Self.newPartPath(fixture), Self.masterPath],
                "the new part must be written before the cap")
    }

    @Test("""
    a cap whose response is lost, then a retry: the later changed occurrences and dates are \
    still on the new part
    """)
    func lostCapResponseKeepsTheLaterChanges() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        let fixture = Self.makeFixture()
        let dated = try Self.dated(fixture)
        store.seed(path: Self.masterPath, ics: dated.ics)
        let dropNext = Mutex(true)
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
        http.register(path: Self.masterPath, method: "PUT") { request in
            let response = store.handlePUT(request)
            // The server keeps the first write of the series; its response never arrives.
            return dropNext.withLock { drop in defer { drop = false }; return drop } ? .raw(statusCode: 500) : response
        }
        let provider = Self.makeProvider(http)

        await #expect(throws: (any Error).self) { try await Self.split(provider, fixture) }
        #expect(store.storedICS(path: Self.masterPath)?.contains("UNTIL=") == true,
                "setup: the first cap did not land")
        try await Self.split(provider, fixture)

        try Self.expectPartition(store, fixture, dated)
    }

    @Test("""
    Held direction — create-only PUTs still assert absence: creating an event \
    whose resource already exists is REFUSED, so the new-resource guard that \
    makes retries idempotent is not weakened
    """)
    func createOnlyPutsStillRefuseAnExistingResource() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        let fixture = Self.makeFixture()
        // A resource ALREADY sits at the id createEvent will derive.
        store.seed(path: "/cal/taken-id.ics", ics: fixture.masterICS)

        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }

        let provider = Self.makeProvider(http)
        var input = GCalEventInput()
        input.id = "taken-id"
        input.summary = "Should not overwrite"

        // `CalDAVError` is not `Equatable`, so match the case explicitly.
        let thrown = await #expect(throws: CalDAVError.self) {
            _ = try await provider.createEvent(
                calendarId: Self.calendarId, event: input, sendUpdates: "none")
        }
        if case .preconditionFailed = thrown {
            // expected
        } else {
            Issue.record("expected CalDAVError.preconditionFailed, got \(String(describing: thrown))")
        }
        // NON-VACUITY for the test above: this fake does not answer 200 to
        // everything, and the create path still carries `If-None-Match: *`.
        #expect(store.storedICS(path: "/cal/taken-id.ics") == fixture.masterICS)
        #expect(store.recordedPuts().last?.ifNoneMatch == "*")
    }
}

// MARK: - Update PUTs never assert the resource is absent

/// **THE INVARIANT: an update against a server that returns no ETag still
/// LANDS, and never asserts the resource is absent.**
///
/// `updateEvent`, `updateOccurrence` and the `splitSeries` master cap each GET
/// the resource first and throw on an empty body, so reaching their PUT is
/// PROOF the resource exists. Sending `If-None-Match: *` there — *"apply only
/// if this resource does NOT exist"* — contradicts what the code just observed
/// and is a guaranteed 412, not a conservative choice.
///
/// **Why the ETag-absent branch is reachable rather than dead code.** RFC 4791
/// says a CalDAV server SHOULD return entity tags, not MUST, and
/// `CalendarSetupView.connectCalDAV()` passes an arbitrary user-entered
/// `serverURL` to `addCalDAVAccount` — TabMail talks to whatever CalDAV server
/// the user names, not only iCloud.
///
/// **Why a 412 here is a wedge and not a fail-closed refusal.**
/// `CalDAVError.preconditionFailed` is a dedicated case, so
/// `AccountManager.isCalendarBadRequestError` — which matches
/// `CalDAVError.httpError`, and whose own comment says "401/404/412 already map
/// to dedicated cases" — returns false for it. It is not `notFound`,
/// `missingScope`, `authFailed`, `unsupported` or `inconsistentState` either.
/// So it falls to the generic arm ("Transient errors — always retry. NEVER drop
/// on age alone"), is requeued with `retryCount += 1`, re-sends the identical
/// `If-None-Match: *`, and 412s again forever. The drain then skips every later
/// op on that account (`failedAccounts`), so the lane never drains. A
/// permanently starving op plus a blocked account lane is the wedge corollary —
/// in THE MANTRA's non-recoverable set, so "fail closed and let it be" does not
/// cover it.
@Suite("CalDAVProvider — update PUTs never assert absence", .serialized)
struct CalDAVUpdatePreconditionTests {

    private static let calendarId = CalDAVWireFixture.calendarId

    private static func makeProvider(_ scenario: FakeHTTP.Scenario) -> CalDAVProvider {
        CalDAVWireFixture.makeProvider(scenario)
    }

    /// Wire the fake so every request under the calendar home reaches `store`.
    private static func route(_ http: FakeHTTP.Scenario, to store: FakeCalDAVStore) {
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
    }

    @Test("""
    An edit lands against a CalDAV server that returns no ETag: the merged ICS \
    reaches the resource, and the PUT never claims the resource is absent — \
    which, against a resource the preceding GET just proved exists, is a \
    guaranteed 412 that wedges the account's whole calendar lane
    """)
    func editLandsWhenTheServerReturnsNoETag() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: false)
        let fixture = CalDAVWireFixture.make()
        let path = "/cal/edit-no-etag.ics"
        store.seed(path: path, ics: fixture.masterICS)
        Self.route(http, to: store)

        let provider = Self.makeProvider(http)
        var patch = GCalEventInput()
        patch.summary = "Renamed by the user"

        do {
            _ = try await provider.updateEvent(
                calendarId: Self.calendarId, eventId: path,
                event: patch, sendUpdates: "none")
        } catch {
            Issue.record("the edit must land against a server that returns no ETag — threw: \(error)")
        }

        // THE INVARIANT, at the resource: the user's edit is on the server.
        let stored = store.storedICS(path: path)
        #expect(stored?.contains("SUMMARY:Renamed by the user") == true,
                "the edited summary must be what the resource now holds")
        #expect(stored != fixture.masterICS,
                "non-vacuity: the resource actually changed, so this is not asserting on the seed")

        // WHY it can land, stated at the wire.
        let puts = store.recordedPuts().filter { $0.path == path }
        #expect(puts.count == 1)
        guard puts.count == 1 else { return }
        #expect(puts[0].ifNoneMatch == nil,
                "`If-None-Match: *` asserts the resource is ABSENT — the GET above just proved it is not")
        #expect(puts[0].ifMatch == nil,
                "there is no ETag to match on; inventing one would be a different bug")
    }

    @Test("""
    A single-occurrence override lands against a CalDAV server that returns no \
    ETag: the spliced RECURRENCE-ID reaches the resource and the PUT never \
    claims the resource is absent
    """)
    func occurrenceOverrideLandsWhenTheServerReturnsNoETag() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: false)
        let fixture = CalDAVWireFixture.make()
        let path = "/cal/occurrence-no-etag.ics"
        store.seed(path: path, ics: fixture.masterICS)
        Self.route(http, to: store)

        let provider = Self.makeProvider(http)
        var patch = GCalEventInput()
        patch.summary = "Just this one"

        do {
            _ = try await provider.updateOccurrence(
                calendarId: Self.calendarId, eventId: path,
                recurrenceId: fixture.recurrenceId, recurrenceIdZone: .current, event: patch, sendUpdates: "none")
        } catch {
            Issue.record("the override must land against a server that returns no ETag — threw: \(error)")
        }

        let stored = store.storedICS(path: path)
        #expect(stored?.contains("RECURRENCE-ID") == true,
                "the override VEVENT must be what the resource now holds")
        #expect(stored?.contains("SUMMARY:Just this one") == true)
        #expect(stored != fixture.masterICS, "non-vacuity: the resource actually changed")

        let puts = store.recordedPuts().filter { $0.path == path }
        #expect(puts.count == 1)
        guard puts.count == 1 else { return }
        #expect(puts[0].ifNoneMatch == nil)
        #expect(puts[0].ifMatch == nil)
    }

    @Test("""
    A series split lands against a CalDAV server that returns no ETag — and \
    two-sided: the master CAP asserts nothing about existence while the \
    SUCCESSOR write is still create-only, so the idempotent-retry guard that \
    stops a lost ACK duplicating the series is not weakened
    """)
    func seriesSplitCapLandsWhileTheSuccessorStaysCreateOnly() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: false)
        let fixture = CalDAVWireFixture.make()
        let masterPath = "/cal/split-no-etag.ics"
        store.seed(path: masterPath, ics: fixture.masterICS)
        Self.route(http, to: store)

        let provider = Self.makeProvider(http)
        do {
            _ = try await provider.splitSeries(
                calendarId: Self.calendarId, eventId: masterPath,
                recurrenceId: fixture.recurrenceId,
                recurrenceIdZone: .current,
                patch: GCalEventInput(), sendUpdates: "none")
        } catch {
            Issue.record("the split must land against a server that returns no ETag — threw: \(error)")
        }

        // THE INVARIANT: the split actually happened — master capped, successor
        // created. With `If-None-Match: *` on the cap it 412s, so the series is
        // never capped.
        let master = store.storedICS(path: masterPath)
        #expect(master?.contains("UNTIL=") == true, "the master series must be capped")
        let successorPath = "/cal/\(GoogleCalendarProvider.deterministicSplitEventId(masterId: masterPath, recurrenceId: fixture.recurrenceId)).ics"
        #expect(store.storedICS(path: successorPath) != nil, "the successor series must exist")

        let capPuts = store.recordedPuts().filter { $0.path == masterPath }
        #expect(capPuts.count == 1, "exactly one cap PUT")
        guard capPuts.count == 1 else { return }
        #expect(capPuts[0].ifNoneMatch == nil)
        #expect(capPuts[0].ifMatch == nil)

        // HELD DIRECTION, same flow: the create site is untouched.
        let successorPuts = store.recordedPuts().filter { $0.path == successorPath }
        #expect(successorPuts.count == 1)
        guard successorPuts.count == 1 else { return }
        #expect(successorPuts[0].ifNoneMatch == "*",
                "the successor write stays CREATE-ONLY — widening it trades a 412 for silently replacing a series someone may have edited")
    }

    @Test("""
    HELD DIRECTION — when the server DOES return an ETag, all three update \
    sites still send `If-Match` carrying that exact tag: the fix relaxes only \
    the no-ETag branch and must not cost the lost-update protection that an \
    entity tag buys
    """)
    func updatesStillCarryIfMatchWhenTheServerReturnsAnETag() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        let fixture = CalDAVWireFixture.make()
        let editPath = "/cal/held-edit.ics"
        let occurrencePath = "/cal/held-occurrence.ics"
        let splitPath = "/cal/held-split.ics"
        for path in [editPath, occurrencePath, splitPath] {
            store.seed(path: path, ics: fixture.masterICS)
        }
        // The tag every one of these three PUTs must echo back.
        let seedETag = store.storedETag(path: editPath)
        #expect(seedETag != nil, "non-vacuity: this store really does serve entity tags")
        Self.route(http, to: store)

        let provider = Self.makeProvider(http)
        var patch = GCalEventInput()
        patch.summary = "Edited"

        _ = try await provider.updateEvent(
            calendarId: Self.calendarId, eventId: editPath, event: patch, sendUpdates: "none")
        _ = try await provider.updateOccurrence(
            calendarId: Self.calendarId, eventId: occurrencePath,
            recurrenceId: fixture.recurrenceId, recurrenceIdZone: .current, event: patch, sendUpdates: "none")
        _ = try await provider.splitSeries(
            calendarId: Self.calendarId, eventId: splitPath,
            recurrenceId: fixture.recurrenceId,
            recurrenceIdZone: .current,
            patch: GCalEventInput(), sendUpdates: "none")

        for path in [editPath, occurrencePath, splitPath] {
            let puts = store.recordedPuts().filter { $0.path == path }
            #expect(puts.count == 1, "expected exactly one PUT at \(path)")
            guard puts.count == 1 else { continue }
            #expect(puts[0].ifMatch == seedETag,
                    "the update at \(path) must still be conditional on the tag the GET returned")
            #expect(puts[0].ifNoneMatch == nil, "an If-Match update never also asserts absence")
        }
    }
}

// MARK: - R18d-G2 — the split's two writers must agree on the boundary instant

/// `splitSeries` derives TWO values from ONE `recurrence_id`:
///
///  * the RRULE cap on the master, via
///    `GoogleCalendarProvider.googleUntilString(…, zone: recurrenceIdZone)` —
///    parsed in the DECLARED zone and emitted as an absolute UTC instant; and
///  * the new part's `DTSTART`, via `CalDAVProvider.seriesSplitResources`,
///    which is handed `recurrenceIdInMasterFrame`'s output.
///
/// The SYSTEM PROPERTY, stated without reference to how either is computed:
/// **the successor series starts exactly one second after the cap.** The cap is
/// `boundary − 1s` and the successor starts at `boundary`, so any other gap
/// means the split dropped the boundary occurrence (successor late) or
/// duplicated it (successor early). `splitSeries`'s cap `PUT` is an
/// irreversible replacement-family write, so a wrong cap destroys the master's
/// post-split occurrences.
///
/// This suite deliberately does NOT test how the frame is chosen. It never names a
/// frame, an offset, or `.current` — it asserts only that two independently
/// computed instants meet. A mechanism assertion ("the reader uses the master's
/// zone") would stay green under the mirror-image arrangement that puts the two
/// writers back in different frames.
@Suite("CalDAVProvider splitSeries — cap and successor agree on the boundary instant")
struct CalDAVSplitBoundaryInstantTests {

    private static let vancouver = TimeZone(identifier: "America/Vancouver")!
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private static let utcZone = TimeZone(identifier: "UTC")!

    /// A weekly recurring master whose only variable is the DTSTART/DTEND form,
    /// so `masterDTStartKind` classification is what each test is selecting.
    private func master(dtstart: String, dtend: String) -> String {
        [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:boundary-master",
            "SUMMARY:Boundary",
            dtstart,
            dtend,
            "RRULE:FREQ=WEEKLY",
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n") + "\r\n"
    }

    /// Parse the absolute UTC `UNTIL` form `googleUntilString` emits for a timed
    /// series (`yyyyMMdd'T'HHmmss'Z'`).
    private func capInstant(_ until: String) throws -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = Self.utcZone
        return try #require(f.date(from: until), "unparseable UNTIL '\(until)'")
    }

    /// Run the exact production pair for one master + declared zone and return
    /// the two instants a split must reconcile.
    private func boundary(
        masterICS: String, recurrenceId: String, declared: TimeZone
    ) throws -> (cap: Date, successor: Date) {
        let until = try #require(
            GoogleCalendarProvider.googleUntilString(
                beforeNaiveISO: recurrenceId, allDay: false, zone: declared),
            "the cap must be computable for a timed master"
        )
        let kind = CalDAVProvider.masterDTStartKind(from: masterICS)
        let masterFrameId = try #require(
            try CalDAVProvider.recurrenceIdInMasterFrame(
                recurrenceId, declaredZone: declared, kind: kind, zones: CalendarTimeZoneContext(calendarText: masterICS)),
            "the recurrence_id must be expressible in the master's frame"
        )
        let resources = try CalDAVProvider.seriesSplitResources(
            storedICS: masterICS, slotNaiveISO: masterFrameId,
            cappedRRule: "RRULE:FREQ=WEEKLY;UNTIL=\(until)", newRRule: "RRULE:FREQ=WEEKLY",
                newUid: "boundary-master-split",
            patch: GCalEventInput(), now: Date()
        )
        return (try capInstant(until), try successorStart(resources.newPart, declared: declared))
    }

    /// The new part's start as an instant. A floating `DTSTART` is a wall clock with no zone of
    /// its own, so it is read in the declared zone — the zone the cap was computed in.
    private func successorStart(_ newPart: String, declared: TimeZone) throws -> Date {
        let line = try #require(
            CalDAVProvider.masterTopLevelLines(newPart).first { $0.hasPrefix("DTSTART") },
            "the new part must carry a start")
        if line.contains("TZID=") || line.hasSuffix("Z") {
            return try #require(try CalDAVProvider.parseICSDateTime(line, zones: .none), "unparseable start '\(line)'")
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = declared
        let value = try #require(line.split(separator: ":").last.map(String.init))
        return try #require(f.date(from: value), "unparseable floating start '\(line)'")
    }

    @Test("a UTC-anchored master: the successor starts one second after the cap")
    func utcMasterBoundaryAgrees() throws {
        // 09:00 America/Vancouver on 2026-05-20 is 16:00Z (PDT, UTC−7), so this
        // master really is the series the declared recurrence_id names.
        //
        // RED BEFORE THE FIX: the successor builder read the master-frame value
        // in the DEVICE zone for every non-`.zoned` master, so on any device not
        // running UTC the successor landed the device's offset away from the cap
        // (7h + 1s on a Vancouver simulator) — the boundary occurrence excluded
        // by the cap and not restored by the successor, i.e. dropped.
        let ics = master(dtstart: "DTSTART:20260520T160000Z", dtend: "DTEND:20260520T164500Z")
        let (cap, successor) = try boundary(
            masterICS: ics, recurrenceId: "2026-05-27T09:00:00", declared: Self.vancouver)
        #expect(successor.timeIntervalSince(cap) == 1,
                "a UTC master's split left a \(successor.timeIntervalSince(cap))s gap between the cap and the successor; the boundary occurrence is dropped unless that gap is exactly 1s")
    }

    @Test("a floating master: the successor starts one second after the cap in EVERY declared zone")
    func floatingMasterBoundaryAgreesInEveryDeclaredZone() throws {
        // Two declared zones 16 hours apart. Whatever zone the test device runs
        // in, it can equal at most ONE of them, so this case is red before the
        // fix on ANY device — unlike the UTC arm above, whose redness needs a
        // non-UTC device.
        let ics = master(dtstart: "DTSTART:20260520T090000", dtend: "DTEND:20260520T094500")
        for declared in [Self.vancouver, Self.tokyo] {
            let (cap, successor) = try boundary(
                masterICS: ics, recurrenceId: "2026-05-27T09:00:00", declared: declared)
            #expect(successor.timeIntervalSince(cap) == 1,
                    "a floating master's split left a \(successor.timeIntervalSince(cap))s gap in \(declared.identifier); the cap is computed in the declared zone, so the successor must be read there too")
        }
    }

    @Test("a TZID-qualified master still agrees — the arm that was already correct")
    func zonedMasterBoundaryStillAgrees() throws {
        // NON-VACUITY / anti-mirror-image control. This arm read the master's
        // zone before the fix and reads it after, so it must be green on BOTH
        // sides. If a change makes this red, the fix moved the defect rather
        // than closing it.
        let ics = master(
            dtstart: "DTSTART;TZID=Asia/Tokyo:20260520T090000",
            dtend: "DTEND;TZID=Asia/Tokyo:20260520T094500")
        let (cap, successor) = try boundary(
            masterICS: ics, recurrenceId: "2026-05-26T17:00:00", declared: Self.vancouver)
        #expect(successor.timeIntervalSince(cap) == 1,
                "a TZID master's split left a \(successor.timeIntervalSince(cap))s gap; this arm was correct before the fix and must stay correct")
    }

    @Test("an all-day master: the cap names the day before the boundary and the successor starts on it, in every declared zone")
    func allDayMasterBoundaryIsFrameFree() throws {
        // The all-day arm is frame-free by construction (RFC 5545 DATE has no
        // zone), which is exactly why it must NOT move with the declared zone.
        // This is the anchor for the frame-free half of the invariant: without
        // it, a "fix" that ran all-day values through a zone conversion could
        // pass every timed assertion above.
        let ics = master(
            dtstart: "DTSTART;VALUE=DATE:20260520",
            dtend: "DTEND;VALUE=DATE:20260521")
        for declared in [Self.vancouver, Self.tokyo, Self.utcZone] {
            let until = try #require(
                GoogleCalendarProvider.googleUntilString(
                    beforeNaiveISO: "2026-05-27T00:00:00", allDay: true, zone: declared))
            #expect(until == "20260526",
                    "an all-day cap moved with the declared zone \(declared.identifier): got '\(until)'")
            let masterFrameId = try #require(
                try CalDAVProvider.recurrenceIdInMasterFrame(
                    "2026-05-27T00:00:00", declaredZone: declared, kind: .allDay, zones: CalendarTimeZoneContext(calendarText: ics)))
            let resources = try CalDAVProvider.seriesSplitResources(
                storedICS: ics, slotNaiveISO: masterFrameId,
                cappedRRule: "RRULE:FREQ=WEEKLY;UNTIL=\(until)", newRRule: "RRULE:FREQ=WEEKLY",
                newUid: "boundary-master-split",
                patch: GCalEventInput(), now: Date()
            )
            let starts = CalDAVProvider.masterTopLevelLines(resources.newPart).filter { $0.hasPrefix("DTSTART") }
            #expect(starts == ["DTSTART;VALUE=DATE:20260527"],
                    "an all-day successor's start moved with the declared zone \(declared.identifier), or took a time: got \(starts)")
        }
    }
}

// MARK: - ICS injection on the UPDATE paths

/// `GCalEventInput.toICS` is not the only place ICS property lines are assembled, and guarding it
/// alone left this class open: `toICS` covers create, while `updateOccurrence` builds its VEVENT in
/// `CalDAVProvider.occurrenceOverrideResource` and `updateEvent` and the split build it in
/// `CalDAVProvider.mergePatchIntoICS` (via `replaceOrAppendInMasterVEvent`, `replaceRRule` and
/// `replaceAttendeesInMasterVEvent`). Every one of those interpolates model-supplied tool arguments,
/// so each is asserted here directly rather than through the create path.
///
/// The oracle is LINE-level and splits on ANY newline: sanitizing strips the separators rather than
/// rejecting the value, so the payload text legitimately survives as inert value text — what must
/// never happen is that it starts a line, because that is what makes it an ICS property.
@Suite("CalDAVProvider — ICS injection on update paths")
struct CalDAVICSInjectionTests {

    /// CRLF, bare LF, and the Unicode separators `Character.isNewline` also recognises.
    private static let payloadBreaks = ["\r\n", "\n", "\r", "\u{2028}", "\u{2029}", "\u{0085}"]

    private func propertyLines(_ ics: String) -> [String] {
        ics.split(whereSeparator: \.isNewline).map(String.init)
    }

    private let masterICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:abc-123
    DTSTAMP:20260513T120000Z
    DTSTART;TZID=America/Los_Angeles:20260513T170000
    SUMMARY:Original title
    ATTENDEE;CN="Alice";ROLE=REQ-PARTICIPANT:mailto:alice@example.com
    END:VEVENT
    END:VCALENDAR
    """.replacingOccurrences(of: "\n", with: "\r\n")

    /// `masterICS` as a repeating series with a length, which a one-occurrence edit needs.
    private var seriesICS: String {
        masterICS.replacingOccurrences(
            of: "SUMMARY:Original title",
            with: "DTEND;TZID=America/Los_Angeles:20260513T174500\r\nRRULE:FREQ=WEEKLY\r\nSUMMARY:Original title"
        )
    }

    @Test("occurrenceOverrideResource: a poisoned SUMMARY cannot become a second property")
    func overrideSummaryCannotInject() throws {
        for brk in Self.payloadBreaks {
            var patch = GCalEventInput()
            patch.summary = "Standup\(brk)ATTENDEE;ROLE=REQ-PARTICIPANT:mailto:attacker@evil.example"
            let block = try CalDAVProvider.occurrenceOverrideResource(
                storedICS: seriesICS, recurrenceIdNaive: "2026-05-13T17:00:00", patch: patch, now: Date()
            )
            let lines = propertyLines(block)
            #expect(!lines.contains { $0.hasPrefix("ATTENDEE") && $0.contains("attacker") },
                    "break \(brk.unicodeScalars.map { String($0.value, radix: 16) }) injected ATTENDEE:\n\(block)")
            // Non-vacuity: the override itself is still produced.
            #expect(lines.contains { $0.hasPrefix("RECURRENCE-ID") }, "no override emitted:\n\(block)")
            #expect(lines.contains { $0.hasPrefix("SUMMARY:Standup") }, "no SUMMARY emitted:\n\(block)")
        }
    }

    @Test("occurrenceOverrideResource: a poisoned attendee name cannot forge an occurrence")
    func overrideAttendeeCannotForgeOccurrence() throws {
        var patch = GCalEventInput()
        patch.attendees = [(email: "real@example.com",
                            name: "Bob\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nRECURRENCE-ID:20260520T170000Z\r\nSTATUS:CANCELLED")]
        let block = try CalDAVProvider.occurrenceOverrideResource(
            storedICS: seriesICS, recurrenceIdNaive: "2026-05-13T17:00:00", patch: patch, now: Date()
        )
        let lines = propertyLines(block)
        // The series and the one override, and no forged cancellation of a DIFFERENT occurrence — that
        // would be a mutation of an event the gesture never named, on a wire operation with no
        // per-item recovery.
        #expect(lines.filter { $0 == "BEGIN:VEVENT" }.count == 2, "forged VEVENT:\n\(block)")
        #expect(!lines.contains { $0.hasPrefix("STATUS:CANCELLED") }, "forged cancellation:\n\(block)")
        #expect(!lines.contains { $0.hasPrefix("RECURRENCE-ID:20260520") }, "forged RECURRENCE-ID:\n\(block)")
        // Non-vacuity: the attendee we asked for is present.
        #expect(lines.contains { $0.hasPrefix("ATTENDEE") && $0.contains("real@example.com") })
    }

    @Test("replaceAttendeesInMasterVEvent: a poisoned attendee name cannot add a property")
    func replaceAttendeesCannotInject() {
        let out = CalDAVProvider.replaceAttendeesInMasterVEvent(
            in: masterICS,
            attendees: [(email: "real@example.com",
                         name: "Bob\r\nATTENDEE;ROLE=REQ-PARTICIPANT:mailto:attacker@evil.example")]
        )
        let lines = propertyLines(out)
        let attendeeLines = lines.filter { $0.hasPrefix("ATTENDEE") }
        #expect(attendeeLines.count == 1, "expected exactly the one attendee we set:\n\(out)")

        // Self-calibrating property-line count, replacing an assertion that could not fire in either
        // direction. That one read `!out.contains("mailto:attacker@evil.example\r\n")`, but the address
        // sits inside the CN parameter and is always followed by `";ROLE=` — so it held pre-fix too and
        // merely LOOKED like coverage. Comparing against a clean run of the same helper catches an
        // injected property of ANY name, not just ATTENDEE, and needs no hardcoded baseline.
        let clean = CalDAVProvider.replaceAttendeesInMasterVEvent(
            in: masterICS,
            attendees: [(email: "real@example.com", name: "Bob")]
        )
        #expect(lines.count == propertyLines(clean).count,
                "the poisoned name changed the number of property lines:\n\(out)")
        #expect(attendeeLines.first?.contains("real@example.com") == true, "non-vacuity: real attendee missing:\n\(out)")
    }

    @Test("mergePatchIntoICS: end to end, a poisoned attendee name cannot add a property")
    func mergePatchAttendeeCannotInject() throws {
        var patch = GCalEventInput()
        patch.attendees = [(email: "real@example.com",
                            name: "Bob\u{2028}ORGANIZER:mailto:attacker@evil.example")]
        let merged = try CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
        let lines = propertyLines(merged)
        #expect(!lines.contains { $0.hasPrefix("ORGANIZER:mailto:attacker") }, "injected ORGANIZER:\n\(merged)")
        #expect(lines.filter { $0 == "BEGIN:VEVENT" }.count == 1, "extra VEVENT:\n\(merged)")
        // Non-vacuity: the merge still did its job.
        #expect(lines.contains("SUMMARY:Original title"), "merge dropped untouched properties:\n\(merged)")
    }

    @Test("replaceOrAppendInMasterVEvent guards the line at the point of insertion")
    func replaceOrAppendSanitizesItsInput() {
        // Asserted on the helper directly, because the guard belongs to the helper rather than to
        // today's callers: every current caller happens to be safe, so a test driven only through
        // them would pass with the guard removed and the next caller would inherit nothing.
        let out = CalDAVProvider.replaceOrAppendInMasterVEvent(
            in: masterICS,
            propertyKey: "TRANSP",
            newLine: "TRANSP:OPAQUE\r\nATTENDEE;ROLE=REQ-PARTICIPANT:mailto:attacker@evil.example"
        )
        let lines = propertyLines(out)
        #expect(!lines.contains { $0.hasPrefix("ATTENDEE") && $0.contains("attacker") }, "injected ATTENDEE:\n\(out)")
        #expect(lines.contains { $0.hasPrefix("TRANSP:OPAQUE") }, "non-vacuity: TRANSP not written:\n\(out)")
    }

    @Test("replaceRRule guards the line at the point of insertion")
    func replaceRRuleSanitizesItsInput() {
        // `replaceRRule` REPLACES an existing rule (the master-has-no-RRULE case is handled by
        // `mergePatchIntoICS`'s fallback, not here), so the fixture must already carry one or the
        // non-vacuity assertion below would fail for a reason unrelated to sanitizing.
        let withRRule = masterICS.replacingOccurrences(
            of: "SUMMARY:Original title",
            with: "RRULE:FREQ=DAILY\r\nSUMMARY:Original title"
        )
        let out = CalDAVProvider.replaceRRule(
            in: withRRule,
            newRRule: "RRULE:FREQ=WEEKLY\r\nATTENDEE;ROLE=REQ-PARTICIPANT:mailto:attacker@evil.example"
        )
        let lines = propertyLines(out)
        #expect(!lines.contains { $0.hasPrefix("ATTENDEE") && $0.contains("attacker") }, "injected ATTENDEE:\n\(out)")
        #expect(lines.contains { $0.hasPrefix("RRULE:FREQ=WEEKLY") }, "non-vacuity: RRULE not written:\n\(out)")
    }
}

// MARK: - The new series keeps the original series' end

/// A this-and-following split hands its NEW series the original series' end:
/// the same UNTIL, or what is left of its COUNT. Before this, the new series
/// was written with UNTIL and COUNT stripped, so a series meant to end ran
/// forever from the split on.
///
/// When the original series already ends before the split there is no tail to
/// move: the split is refused, and refused before the cap PUT, which replaces
/// the master and is one of the irreversible wire operations.
///
/// The master is zoned to Pacific/Auckland at 07:00 (the previous day in UTC)
/// and the split's `recurrence_id` is declared in UTC, so its BYDAY rule
/// counts different occurrences when read in the wrong frame. Dates are
/// relative to now.
@Suite("CalDAVProvider splitSeries — the new series keeps the original end", .serialized)
struct CalDAVSplitSeriesTailTests {

    private static let auckland = TimeZone(identifier: "Pacific/Auckland")!
    private static let utc = TimeZone(identifier: "UTC")!

    /// A Monday 07:00 in Auckland at least a week from now.
    private static func mondayInAuckland() throws -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = auckland
        let weekFromNow = Date().addingTimeInterval(7 * 86_400)
        let monday = DateComponents(hour: 7, minute: 0, second: 0, weekday: 2)
        return try #require(cal.nextDate(after: weekFromNow, matching: monday, matchingPolicy: .nextTime))
    }

    /// The same wall clock `days` days later in Auckland.
    private static func aucklandDays(_ days: Int, after date: Date) throws -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = auckland
        return try #require(cal.date(byAdding: .day, value: days, to: date))
    }

    private static func format(_ date: Date, _ pattern: String, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        f.timeZone = zone
        return f.string(from: date)
    }

    private static func masterICS(rrule: String, start: Date) -> String {
        let local = "yyyyMMdd'T'HHmmss"
        return [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//TabMail//Test//EN",
            "BEGIN:VEVENT",
            "UID:tail-master",
            "DTSTAMP:\(format(start, local, utc))Z",
            "DTSTART;TZID=Pacific/Auckland:\(format(start, local, auckland))",
            "DTEND;TZID=Pacific/Auckland:\(format(start.addingTimeInterval(3_600), local, auckland))",
            "SUMMARY:Standup",
            rrule,
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n") + "\r\n"
    }

    private struct Outcome {
        let error: Error?
        let originalMaster: String
        let master: String?
        let successorRRule: String?
        let puts: [FakeCalDAVStore.RecordedPut]
        let recurrenceId: String
    }

    /// Split a Monday/Wednesday/Friday series the following Monday. Three
    /// occurrences fall before the split in Auckland (Monday, Wednesday,
    /// Friday); read in UTC the same days are Sunday, Tuesday and Thursday.
    private func split(rrule: String, patch: GCalEventInput = GCalEventInput()) async throws -> Outcome {
        let start = try Self.mondayInAuckland()
        let recurrenceId = Self.format(try Self.aucklandDays(7, after: start), "yyyy-MM-dd'T'HH:mm:ss", Self.utc)
        let original = Self.masterICS(rrule: rrule, start: start)

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: CalDAVWireFixture.masterPath, ics: original)
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
        let provider = CalDAVWireFixture.makeProvider(http)

        var thrown: Error?
        do {
            _ = try await provider.splitSeries(
                calendarId: CalDAVWireFixture.calendarId,
                eventId: CalDAVWireFixture.masterEventId,
                recurrenceId: recurrenceId, recurrenceIdZone: Self.utc,
                patch: patch, sendUpdates: "none")
        } catch {
            thrown = error
        }
        let newUid = GoogleCalendarProvider.deterministicSplitEventId(
            masterId: CalDAVWireFixture.masterEventId, recurrenceId: recurrenceId)
        // The event's own rule. The new resource carries the series' VTIMEZONE, whose
        // STANDARD/DAYLIGHT blocks have RRULE lines of their own and come first.
        let successorRRule = store.storedICS(path: "/cal/\(newUid).ics")?
            .components(separatedBy: "\r\n")
            .drop { $0 != "BEGIN:VEVENT" }
            .first { $0.hasPrefix("RRULE:") }
        return Outcome(
            error: thrown, originalMaster: original,
            master: store.storedICS(path: CalDAVWireFixture.masterPath),
            successorRRule: successorRRule, puts: store.recordedPuts(), recurrenceId: recurrenceId)
    }

    private func isRefusal(_ error: Error?) -> Bool {
        if case CalendarProviderError.notSupported(let message)? = error { return !message.isEmpty }
        return false
    }

    @Test("A COUNT series' new half gets the occurrences the original had left")
    func countCarriesOver() async throws {
        let out = try await split(rrule: "RRULE:FREQ=WEEKLY;COUNT=10;BYDAY=MO,WE,FR")
        #expect(out.error == nil, "got \(String(describing: out.error))")
        #expect(out.successorRRule == "RRULE:FREQ=WEEKLY;COUNT=7;BYDAY=MO,WE,FR", """
            ten occurrences, three of them (Monday, Wednesday, Friday in Auckland) before the split: \
            the new series has seven. An unbounded rule is the defect; COUNT=6 means the rule was \
            read in UTC, where the series starts on a Sunday. got \(String(describing: out.successorRRule))
            """)
        #expect(out.master?.contains("UNTIL=") == true, "non-vacuity: the master was capped")
    }

    @Test("A COUNT already used up before the split is refused with nothing written")
    func usedUpCountIsRefusedBeforeAnyWrite() async throws {
        let out = try await split(rrule: "RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=MO,WE,FR")
        #expect(isRefusal(out.error), "got \(String(describing: out.error))")
        #expect(out.puts.isEmpty, """
            the refusal must come before any write. got \(out.puts.map(\.path))
            """)
        #expect(out.master == out.originalMaster, "the master must be untouched")
    }

    @Test("An UNTIL before the split is refused with nothing written")
    func earlierUntilIsRefusedBeforeAnyWrite() async throws {
        let start = try Self.mondayInAuckland()
        let until = Self.format(try Self.aucklandDays(3, after: start), "yyyyMMdd'T'HHmmss'Z'", Self.utc)
        let out = try await split(rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=\(until)")
        #expect(isRefusal(out.error), "got \(String(describing: out.error))")
        #expect(out.puts.isEmpty, "got \(out.puts.map(\.path))")
        #expect(out.master == out.originalMaster)
    }

    @Test("An UNTIL after the split is carried over verbatim")
    func laterUntilCarriesOver() async throws {
        let start = try Self.mondayInAuckland()
        let until = Self.format(try Self.aucklandDays(30, after: start), "yyyyMMdd'T'HHmmss'Z'", Self.utc)
        let rule = "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=\(until)"
        let out = try await split(rrule: rule)
        #expect(out.error == nil, "got \(String(describing: out.error))")
        #expect(out.successorRRule == rule, "the new series must end where the original did. got \(String(describing: out.successorRRule))")
    }

    @Test("A master already carrying this split's cap is a retry: the new series is written without an end")
    func ownCapIsARetry() async throws {
        let start = try Self.mondayInAuckland()
        let recurrenceId = Self.format(try Self.aucklandDays(7, after: start), "yyyy-MM-dd'T'HH:mm:ss", Self.utc)
        let cap = try #require(GoogleCalendarProvider.googleUntilString(beforeNaiveISO: recurrenceId, allDay: false, zone: Self.utc))
        let out = try await split(rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=\(cap)")
        #expect(out.recurrenceId == recurrenceId, "setup: the cap must be the one this split computes")
        #expect(out.error == nil, """
            refusing here retires the operation while the master stays capped with no new \
            series. got \(String(describing: out.error))
            """)
        #expect(out.successorRRule == "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR", "got \(String(describing: out.successorRRule))")
    }

    @Test("A DAILY COUNT series' new half gets the occurrences the original had left")
    func dailyCountCarriesOver() async throws {
        let out = try await split(rrule: "RRULE:FREQ=DAILY;COUNT=10")
        #expect(out.error == nil, "got \(String(describing: out.error))")
        #expect(out.successorRRule == "RRULE:FREQ=DAILY;COUNT=3",
                "seven daily occurrences fall before the split, three are left. got \(String(describing: out.successorRRule))")
    }

    @Test("A patch that brings its own recurrence is written as given")
    func patchRecurrenceIsWrittenAsGiven() async throws {
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=DAILY;COUNT=4"]
        let out = try await split(rrule: "RRULE:FREQ=WEEKLY;COUNT=10;BYDAY=MO,WE,FR", patch: patch)
        #expect(out.error == nil, "got \(String(describing: out.error))")
        #expect(out.successorRRule == "RRULE:FREQ=DAILY;COUNT=4", "got \(String(describing: out.successorRRule))")
    }

    @Test("A COUNT master whose numbers would overflow the counter is refused before any write")
    func overflowingCountMasterIsRefused() async throws {
        for rrule in ["RRULE:FREQ=YEARLY;INTERVAL=30000000000000000;COUNT=3",
                      "RRULE:FREQ=MONTHLY;BYMONTHDAY=-9223372036854775808;COUNT=3"] {
            let out = try await split(rrule: rrule)
            #expect(isRefusal(out.error), "\(rrule): got \(String(describing: out.error))")
            #expect(out.puts.isEmpty, "\(rrule): got \(out.puts.map(\.path))")
            #expect(out.master == out.originalMaster, "the master must be untouched")
        }
    }

    @Test("A patch that brings its own recurrence is still refused when the series ended before the split")
    func patchRecurrenceDoesNotSkipTheEndCheck() async throws {
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=DAILY;COUNT=4"]
        let out = try await split(rrule: "RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=MO,WE,FR", patch: patch)
        #expect(isRefusal(out.error), """
            the cap would move the end of a series that already ended to the day before the \
            split, and start a new series past its end. got \(String(describing: out.error))
            """)
        #expect(out.puts.isEmpty, "got \(out.puts.map(\.path))")
        #expect(out.master == out.originalMaster, "the master must be untouched")
    }
}

/// Moving a repeating series' time through `updateEvent`, observed at the
/// resource: what the server ends up holding is the moved series with every
/// occurrence in the state it had, or, when a tied value cannot be moved, the
/// untouched original with no PUT sent. Dates are in 2099 (testing rule 7's
/// fixed-date exception).
@Suite("CalDAVProvider — moving a series' time over the wire", .serialized)
struct CalDAVSeriesStartShiftWireTests {

    private static let calendarId = CalDAVWireFixture.calendarId

    private static func route(_ http: FakeHTTP.Scenario, to store: FakeCalDAVStore) {
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
    }

    private static func series(zone: String, until: String) -> String {
        [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN",
            "BEGIN:VEVENT", "UID:series-wire", "DTSTAMP:20990101T000000Z",
            "DTSTART;TZID=\(zone):20990302T100000", "DTEND;TZID=\(zone):20990302T110000",
            "RRULE:FREQ=WEEKLY;\(until)", "EXDATE;TZID=\(zone):20990316T100000",
            "SUMMARY:Weekly sync", "END:VEVENT",
            "BEGIN:VEVENT", "UID:series-wire", "DTSTAMP:20990101T000000Z",
            "RECURRENCE-ID;TZID=\(zone):20990323T100000",
            "DTSTART;TZID=\(zone):20990323T113000", "DTEND;TZID=\(zone):20990323T123000",
            "SUMMARY:Weekly sync (moved)", "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n")
    }

    private static func moveTo15() -> GCalEventInput {
        var patch = GCalEventInput()
        patch.startDateTime = "2099-03-02T15:00:00-08:00"
        patch.endDateTime = "2099-03-02T16:00:00-08:00"
        patch.startTimeZone = "America/Los_Angeles"
        patch.endTimeZone = "America/Los_Angeles"
        return patch
    }

    @Test("A moved series reaches the server with its deleted, changed and last occurrences intact")
    func movedSeriesLandsWhole() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        let path = "/cal/series-move.ics"
        let seed = Self.series(zone: "America/Los_Angeles", until: "UNTIL=20990330T170000Z")
        #expect(try SeriesOracle.states(seed) == [.shown, .shown, .deleted, .changed, .shown], "non-vacuity")
        store.seed(path: path, ics: seed)
        Self.route(http, to: store)

        _ = try await CalDAVWireFixture.makeProvider(http).updateEvent(
            calendarId: Self.calendarId, eventId: path, event: Self.moveTo15(), sendUpdates: "none")

        let stored = try #require(store.storedICS(path: path))
        #expect(stored.contains("DTSTART;TZID=America/Los_Angeles:20990302T150000"), "non-vacuity: the start moved")
        #expect(try SeriesOracle.states(stored) == [.shown, .shown, .deleted, .changed, .shown])
        #expect(store.recordedPuts().filter { $0.path == path }.count == 1)
    }

    @Test("A series whose tied values cannot be moved is refused before any write; the server keeps the original")
    func unmovableSeriesIsNeverWritten() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        let path = "/cal/series-unknown-zone.ics"
        let zone = "Customized Time Zone"
        #expect(TimeZone(identifier: zone) == nil, "non-vacuity: the device does not know this zone")
        let seed = Self.series(zone: zone, until: "UNTIL=20990330T170000Z")
        store.seed(path: path, ics: seed)
        Self.route(http, to: store)

        await #expect(throws: CalendarProviderError.self) {
            _ = try await CalDAVWireFixture.makeProvider(http).updateEvent(
                calendarId: Self.calendarId, eventId: path, event: Self.moveTo15(), sendUpdates: "none")
        }
        #expect(store.recordedPuts().isEmpty, "no PUT may carry a series whose tied values were left behind")
        #expect(store.storedICS(path: path) == seed)
    }
}
