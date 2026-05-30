/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
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

    @Test("buildOverrideVEvent with ATTENDEE carries the master's ORGANIZER — RFC 5545 §3.8.4.3 / iCloud HTTP 403 regression")
    func buildOverrideVEventIncludesOrganizerWithAttendees() {
        var patch = GCalEventInput()
        patch.attendees = [(email: "bob@example.com", name: "Bob")]
        let masterOrg = "ORGANIZER;CN=\"Alice\":mailto:alice@example.com"
        let block = CalDAVProvider.buildOverrideVEvent(
            patch: patch, uid: "abc-123", recurrenceId: "2026-05-20T17:00:00",
            kind: .floating, organizerLine: masterOrg
        )
        #expect(block.contains("ATTENDEE"))
        #expect(block.contains(masterOrg), "RFC 5545 + iCloud require ORGANIZER alongside ATTENDEE")
        // ORGANIZER must appear BEFORE the ATTENDEE lines so iTIP processors
        // see the scheduling context before the recipients.
        if let orgIdx = block.range(of: "ORGANIZER")?.lowerBound,
           let attIdx = block.range(of: "ATTENDEE;")?.lowerBound {
            #expect(orgIdx < attIdx)
        }
    }

    @Test("buildOverrideVEvent WITHOUT ATTENDEE omits ORGANIZER — avoids spurious scheduling on simple overrides")
    func buildOverrideVEventOmitsOrganizerWhenNoAttendees() {
        var patch = GCalEventInput()
        patch.summary = "title-only change"
        let block = CalDAVProvider.buildOverrideVEvent(
            patch: patch, uid: "abc-123", recurrenceId: "2026-05-20T17:00:00",
            kind: .floating, organizerLine: "ORGANIZER:mailto:alice@example.com"
        )
        #expect(!block.contains("ORGANIZER"), "no ATTENDEE → no need for ORGANIZER (iTIP wouldn't trigger)")
    }

    @Test("buildOverrideVEvent (timed master) emits a date-time RECURRENCE-ID")
    func buildOverrideVEventTimed() {
        var patch = GCalEventInput()
        patch.summary = "Special edition"
        let block = CalDAVProvider.buildOverrideVEvent(
            patch: patch, uid: "abc-123", recurrenceId: "2026-05-20T17:00:00", kind: .floating
        )
        #expect(block.hasPrefix("BEGIN:VEVENT"))
        #expect(block.hasSuffix("END:VEVENT"))
        #expect(block.contains("UID:abc-123"))
        #expect(block.contains("RECURRENCE-ID:20260520T170000"))
        // Timed form — must NOT carry the VALUE=DATE param.
        #expect(!block.contains("RECURRENCE-ID;VALUE=DATE"))
        #expect(block.contains("SUMMARY:Special edition"))
    }

    @Test("buildOverrideVEvent (all-day master) emits RECURRENCE-ID;VALUE=DATE — RFC 5545 §3.8.4.4")
    func buildOverrideVEventAllDay() {
        // RFC 5545: RECURRENCE-ID's value type must match the master's DTSTART.
        // All-day master → RECURRENCE-ID;VALUE=DATE:YYYYMMDD (no time).
        var patch = GCalEventInput()
        patch.summary = "Holiday override"
        // recurrence_id for an all-day occurrence may arrive in either form.
        let blockA = CalDAVProvider.buildOverrideVEvent(
            patch: patch, uid: "abc-123", recurrenceId: "2026-05-20", kind: .allDay
        )
        #expect(blockA.contains("RECURRENCE-ID;VALUE=DATE:20260520"))
        #expect(!blockA.contains("RECURRENCE-ID:2026"), "must not emit a bare timed RECURRENCE-ID for an all-day master")
        let blockB = CalDAVProvider.buildOverrideVEvent(
            patch: patch, uid: "abc-123", recurrenceId: "2026-05-20T00:00:00", kind: .allDay
        )
        #expect(blockB.contains("RECURRENCE-ID;VALUE=DATE:20260520"))
    }

    @Test("buildOverrideVEvent (all-day master) emits DATE-typed DTSTART/DTEND — RFC 5545 §3.8.4.4")
    func buildOverrideVEventAllDayDtStartEnd() {
        // An all-day override's DTSTART/DTEND value type MUST match the
        // DATE-typed RECURRENCE-ID — never a timed DTSTART:…THHmmss.
        var patchDate = GCalEventInput()
        patchDate.startDate = "2026-05-21"
        patchDate.endDate = "2026-05-22"
        let blockA = CalDAVProvider.buildOverrideVEvent(
            patch: patchDate, uid: "abc-123", recurrenceId: "2026-05-20", kind: .allDay
        )
        #expect(blockA.contains("DTSTART;VALUE=DATE:20260521"))
        #expect(blockA.contains("DTEND;VALUE=DATE:20260522"))
        #expect(!blockA.contains("DTSTART:2026"), "all-day override must not emit a timed DTSTART")
        #expect(!blockA.contains("DTEND:2026"), "all-day override must not emit a timed DTEND")

        // The patch may also carry the move as a date-time string — the date
        // component must still be taken (not the time).
        var patchDateTime = GCalEventInput()
        patchDateTime.startDateTime = "2026-05-21T09:30:00"
        patchDateTime.endDateTime = "2026-05-22T09:30:00"
        let blockB = CalDAVProvider.buildOverrideVEvent(
            patch: patchDateTime, uid: "abc-123", recurrenceId: "2026-05-20", kind: .allDay
        )
        #expect(blockB.contains("DTSTART;VALUE=DATE:20260521"))
        #expect(blockB.contains("DTEND;VALUE=DATE:20260522"))
        #expect(!blockB.contains("T093000"), "all-day override must drop the time component")
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

    @Test("buildOverrideVEvent (zoned master) emits TZID-qualified RECURRENCE-ID + DTSTART")
    func buildOverrideVEventZoned() {
        var patch = GCalEventInput()
        patch.startDateTime = "2026-05-20T18:30:00-07:00"
        patch.endDateTime = "2026-05-20T19:00:00-07:00"
        let block = CalDAVProvider.buildOverrideVEvent(
            patch: patch, uid: "abc-123", recurrenceId: "2026-05-20T17:00:00",
            kind: .zoned("America/Vancouver")
        )
        // RECURRENCE-ID + DTSTART must carry the same TZID as the master (RFC 5545 §3.8.4.4).
        #expect(block.contains("RECURRENCE-ID;TZID=America/Vancouver:20260520T170000"))
        #expect(block.contains("DTSTART;TZID=America/Vancouver:20260520T183000"))
        #expect(block.contains("DTEND;TZID=America/Vancouver:20260520T190000"))
        #expect(!block.contains("RECURRENCE-ID:2026"), "must not emit a bare floating RECURRENCE-ID for a zoned master")
    }

    @Test("buildOverrideVEvent (UTC master) emits Z-suffixed RECURRENCE-ID + DTSTART")
    func buildOverrideVEventUTC() {
        var patch = GCalEventInput()
        patch.startDateTime = "2026-05-20T17:00:00Z"
        let block = CalDAVProvider.buildOverrideVEvent(
            patch: patch, uid: "abc-123", recurrenceId: "2026-05-20T17:00:00", kind: .utc
        )
        #expect(block.contains("RECURRENCE-ID:20260520T170000Z"))
        #expect(block.contains("DTSTART:20260520T170000Z"))
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

    @Test("buildNewSeriesInput inherits master fields and applies patch overrides")
    func buildNewSeriesInput() throws {
        var patch = GCalEventInput()
        patch.attendees = [(email: "alice@example.com", name: "Alice"), (email: "carol@example.com", name: "Carol")]
        let out = try CalDAVProvider.buildNewSeriesInput(
            masterICS: masterICS, patch: patch,
            newStartNaiveISO: "2026-05-20T17:00:00",
            newRRule: "RRULE:FREQ=WEEKLY;BYDAY=WE"
        )
        // Inherited from master:
        #expect(out.summary == "Weekly sync")
        #expect(out.location == "Room 1")
        // From patch:
        #expect(out.attendees?.count == 2)
        #expect(out.attendees?.contains(where: { $0.email == "carol@example.com" }) == true)
        // New recurrence:
        #expect(out.recurrence == ["RRULE:FREQ=WEEKLY;BYDAY=WE"])
        // Start was rewritten.
        #expect(out.startDateTime != nil)
        // Duration preserved: master is 45 minutes, so end should be start + 45min.
        if let s = out.startDateTime, let e = out.endDateTime,
           let sd = Date.fromISO8601(s), let ed = Date.fromISO8601(e) {
            #expect(Int(ed.timeIntervalSince(sd)) == 45 * 60)
        }
    }

    // MARK: - TZID + duration extraction (regression coverage)

    @Test("parseICSDateTime parses TZID-qualified DTSTART in the named timezone")
    func parseICSDateTimeTZID() {
        let line = "DTSTART;TZID=America/Los_Angeles:20260520T170000"
        let date = CalDAVProvider.parseICSDateTime(line)
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
    func parseICSDateTimeUTC() {
        let line = "DTSTART:20260520T170000Z"
        let date = CalDAVProvider.parseICSDateTime(line)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        fmt.timeZone = TimeZone(identifier: "UTC")
        #expect(date != nil)
        if let date { #expect(fmt.string(from: date) == "2026-05-20T17:00:00Z") }
    }

    @Test("parseICSDateTime parses date-only all-day forms")
    func parseICSDateTimeDateOnly() {
        #expect(CalDAVProvider.parseICSDateTime("DTSTART;VALUE=DATE:20260520") != nil)
        #expect(CalDAVProvider.parseICSDateTime("DTSTART:20260520") != nil)
    }

    @Test("extractMasterDuration is correct when DTSTART/DTEND share a TZID")
    func extractMasterDurationTZID() {
        let ics = """
        BEGIN:VEVENT
        DTSTART;TZID=America/Los_Angeles:20260520T170000
        DTEND;TZID=America/Los_Angeles:20260520T174500
        END:VEVENT
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let d = CalDAVProvider.extractMasterDuration(from: ics)
        #expect(d == TimeInterval(45 * 60))
    }

    @Test("VEVENT-scoped extractors ignore a leading VTIMEZONE block (RRULE/DTSTART/UID/duration)")
    func extractorsIgnoreVTimezone() {
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
        // Duration: 45 min from the EVENT's DTSTART/DTEND, not the timezone's.
        #expect(CalDAVProvider.extractMasterDuration(from: ics) == TimeInterval(45 * 60))
    }

    @Test("masterVEventLines picks the VEVENT with no RECURRENCE-ID, skipping override blocks")
    func masterVEventLinesSkipsOverrides() {
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
        let masterLines = CalDAVProvider.masterVEventLines(from: ics)
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

    @Test("parseICSDateTime refuses to guess on an unresolvable TZID — returns nil, no device-tz fallback")
    func parseICSDateTimeUnknownTZID() {
        // Windows-style TZID names (common from Outlook .ics exports) are not
        // IANA identifiers; TimeZone(identifier:) returns nil for them. We must
        // NOT silently reinterpret in the device tz — that would corrupt the
        // absolute instant (and thus extractMasterDuration). Expect nil.
        let line = "DTSTART;TZID=Central European Standard Time:20260520T170000"
        #expect(CalDAVProvider.parseICSDateTime(line) == nil)
        // A recognized IANA TZID still parses fine.
        #expect(CalDAVProvider.parseICSDateTime("DTSTART;TZID=America/Los_Angeles:20260520T170000") != nil)
        // Floating time (no TZID) still parses (device-local interpretation).
        #expect(CalDAVProvider.parseICSDateTime("DTSTART:20260520T170000") != nil)
    }

    @Test("extractMasterDuration returns nil when one DTSTART/DTEND line has an unresolvable TZID")
    func extractMasterDurationUnknownTZID() {
        // If either endpoint can't be parsed (unknown TZID), the duration is
        // unrecoverable — return nil so buildNewSeriesInput fails fast rather
        // than producing a series with a wrong-length duration.
        let ics = """
        BEGIN:VEVENT
        DTSTART;TZID=Central European Standard Time:20260520T140000
        DTEND;TZID=America/Los_Angeles:20260520T150000
        END:VEVENT
        """.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(CalDAVProvider.extractMasterDuration(from: ics) == nil)
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
    func extractMasterDurationMissing() {
        let ics = """
        BEGIN:VEVENT
        SUMMARY:Nothing here
        END:VEVENT
        """.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(CalDAVProvider.extractMasterDuration(from: ics) == nil)
    }

    @Test("buildNewSeriesInput unfolds long DESCRIPTION lines (RFC 5545 §3.1) before extracting")
    func buildNewSeriesInputUnfoldsDescription() throws {
        // ICS line folding splits long lines at column 75 with a leading space
        // or tab on the continuation. Without unfolding the extractor would
        // return only the first 75-ish chars of DESCRIPTION/LOCATION and
        // silently drop the rest into the new series.
        // NOTE: build with explicit "\r\n" concatenation; using `"""..."""`
        // + a `\n→\r\n` replace would also rewrite the `\n` inside our
        // intentional `\r\n ` continuation marker into `\r\n\r\n`, breaking
        // the test's premise (a properly folded ICS line) before the SUT
        // ever runs.
        let longDesc = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor"
        let ics = "BEGIN:VEVENT\r\n"
            + "UID:abc-123\r\n"
            + "DTSTART:20260520T170000Z\r\n"
            + "DTEND:20260520T180000Z\r\n"
            + "SUMMARY:Long event\r\n"
            + "DESCRIPTION:Lorem ipsum dolor sit amet consectetur adipiscing elit sed do e\r\n iusmod tempor\r\n"
            + "RRULE:FREQ=WEEKLY\r\n"
            + "END:VEVENT\r\n"
        let out = try CalDAVProvider.buildNewSeriesInput(
            masterICS: ics, patch: GCalEventInput(),
            newStartNaiveISO: "2026-05-27T17:00:00",
            newRRule: "RRULE:FREQ=WEEKLY"
        )
        #expect(out.description == longDesc, "description was truncated by folding: got '\(out.description ?? "nil")'")
    }

    @Test("buildNewSeriesInput throws when master duration is unrecoverable")
    func buildNewSeriesInputThrowsOnBadDuration() {
        let brokenICS = """
        BEGIN:VEVENT
        UID:abc-123
        SUMMARY:Broken
        END:VEVENT
        """.replacingOccurrences(of: "\n", with: "\r\n")
        var patch = GCalEventInput()
        patch.attendees = [(email: "a@example.com", name: "A")]
        var threw = false
        do {
            _ = try CalDAVProvider.buildNewSeriesInput(
                masterICS: brokenICS, patch: patch,
                newStartNaiveISO: "2026-05-20T17:00:00",
                newRRule: "RRULE:FREQ=WEEKLY"
            )
        } catch {
            threw = true
        }
        #expect(threw)
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
    func recurrenceOnlyPreservesEverythingElse() {
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=WEEKLY"]
        let merged = CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
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
    func updateSummary() {
        var patch = GCalEventInput()
        patch.summary = "New title"
        let merged = CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
        #expect(merged.contains("SUMMARY:New title"))
        #expect(!merged.contains("SUMMARY:Original title"))
        #expect(merged.contains("DTSTART"))
        #expect(merged.contains("alice@example.com"))
    }

    @Test("clearing location with empty string removes the LOCATION line entirely")
    func clearLocation() {
        var patch = GCalEventInput()
        patch.location = ""
        let merged = CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
        #expect(!merged.contains("LOCATION:"))
        // Other fields intact.
        #expect(merged.contains("SUMMARY:Original title"))
        #expect(merged.contains("alice@example.com"))
    }

    @Test("replacing attendees removes the old set and inserts the new")
    func replaceAttendees() {
        var patch = GCalEventInput()
        patch.attendees = [(email: "bob@example.com", name: "Bob")]
        let merged = CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
        #expect(merged.contains("bob@example.com"))
        #expect(!merged.contains("alice@example.com"))
        // No duplicate VEVENT and structural fields preserved.
        #expect(merged.components(separatedBy: "BEGIN:VEVENT").count - 1 == 1)
        #expect(merged.contains("DTSTART"))
    }

    @Test("changing DTSTART/DTEND on a zoned master re-emits in TZID form")
    func updateZonedDTStart() {
        var patch = GCalEventInput()
        patch.startDateTime = "2026-05-20T15:00:00-07:00"
        patch.endDateTime = "2026-05-20T16:00:00-07:00"
        patch.startTimeZone = "America/Los_Angeles"
        patch.endTimeZone = "America/Los_Angeles"
        let merged = CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
        #expect(merged.contains("DTSTART;TZID=America/Los_Angeles:20260520T150000"))
        #expect(merged.contains("DTEND;TZID=America/Los_Angeles:20260520T160000"))
        // Old timed lines gone.
        #expect(!merged.contains("DTSTART;TZID=America/Los_Angeles:20260513T170000"))
    }

    @Test("only fields IN the patch are touched — empty patch returns input unchanged")
    func emptyPatchIsIdentity() {
        let merged = CalDAVProvider.mergePatchIntoICS(masterICS, patch: GCalEventInput())
        // Every line of the original survives (order/CRLF preserved).
        #expect(merged == masterICS)
    }

    @Test("appending RRULE when master has none inserts before END:VEVENT")
    func appendNewRRule() {
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=DAILY;COUNT=5"]
        let merged = CalDAVProvider.mergePatchIntoICS(masterICS, patch: patch)
        #expect(merged.contains("RRULE:FREQ=DAILY;COUNT=5"))
        // Still well-formed: one BEGIN/END pair, RRULE inside.
        let lines = merged.components(separatedBy: "\r\n")
        let rruleIdx = try? #require(lines.firstIndex { $0.hasPrefix("RRULE:") })
        let endIdx = try? #require(lines.firstIndex(of: "END:VEVENT"))
        if let r = rruleIdx, let e = endIdx { #expect(r < e) }
    }
}
