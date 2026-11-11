/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

// MARK: - Deleting one occurrence of a repeating CalDAV event, over the wire (#661, ADR-IOS-108)
//
// INVARIANT (system property): deleting one occurrence of a repeating CalDAV event removes
// exactly that occurrence, as Google Calendar does. Afterwards a listing shows every other
// occurrence exactly as before (its id, start, end and title, a changed one included), and
// the deleted one nowhere: not where a changed copy had moved it, and not back at its place
// in the series. The series resource is never DELETEd, the write is ONE PUT conditional on
// the ETag the provider read (unconditional only on a server that sends none, IOS-CAL-002),
// and the resource on the server is the one it read plus one
// EXDATE (less the deleted occurrence's changed copy, when it had one), byte for byte.
// Whatever the provider can't delete that way is refused with nothing written.
//
// The PUT is an irreversible wire operation (memory 102): it removes the changed copy's
// content with no per-item recovery.
//
// Dates are worked out from `Date()`; none is written as a literal.

@Suite("CalDAVProvider: deleting one occurrence of a repeating event", .serialized)
struct CalDAVOccurrenceDeleteWireTests {
    typealias W = OccurrenceWireFixture
    typealias Frame = CalDAVOccurrenceWireTests.SeriesFrame

    /// A weekly series written in `frame`: its first occurrence a week ago (09:00 in the
    /// frame's zone, or the whole day), half an hour long (a day when all-day).
    struct Series {
        let frame: Frame
        let zone: TimeZone
        let first: Date
        let length: TimeInterval

        init(_ frame: Frame) throws {
            self.frame = frame
            zone = try frame.zone()
            let calendar = OccurrenceFixture.calendar(zone)
            let weekAgo = try #require(calendar.date(byAdding: .day, value: -7, to: Date()))
            first = frame == .allDay
                ? calendar.startOfDay(for: weekAgo)
                : try #require(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: weekAgo))
            length = frame == .allDay ? 24 * 60 * 60 : 30 * 60
        }

        /// Week `week`'s place in the series (0 = the first).
        func slot(_ week: Int) throws -> Date {
            try #require(OccurrenceFixture.calendar(zone).date(byAdding: .day, value: 7 * week, to: first))
        }

        /// The id a listing gives week `week`'s occurrence.
        func occurrenceId(_ week: Int) throws -> String {
            let slot = try slot(week)
            let key: String
            switch frame {
            case .allDay: key = OccurrenceFixture.dateValue(slot, zone)
            case .floating: key = OccurrenceFixture.wall(slot, zone)
            case .utc, .zoned: key = OccurrenceFixture.utcValue(slot)
            }
            return CalDAVOccurrences.OccurrenceId.make(seriesHref: W.seriesPath, key: key)
        }

        /// The series VEVENT's lines.
        func master() throws -> String {
            [
                "UID:standup-1", "DTSTAMP:\(OccurrenceFixture.utcValue(first))",
                try frame.line("DTSTART", first), try frame.line("DTEND", first.addingTimeInterval(length)),
                "SUMMARY:Standup", "RRULE:FREQ=WEEKLY",
            ].joined(separator: "\n")
        }

        /// Where an occurrence starting at `start` ends: half an hour later, or the next day.
        func end(_ start: Date) throws -> Date {
            guard frame == .allDay else { return start.addingTimeInterval(length) }
            return try #require(OccurrenceFixture.calendar(zone).date(byAdding: .day, value: 1, to: start))
        }

        /// The EXDATE line that removes week `week`'s occurrence, in the series' own form.
        func exdate(_ week: Int) throws -> String { try frame.line("EXDATE", try slot(week)) }
    }

    /// Every row a listing shows from the series' first occurrence through week 5, as text
    /// that carries what a user sees of each (id, start, end, title), by start.
    private static func listing(_ provider: CalDAVProvider, first: Date, through lastWeekStart: Date) async throws -> [String] {
        let rows = try await provider.listEvents(
            calendarId: W.calendarId, timeMin: first.addingTimeInterval(-60),
            timeMax: lastWeekStart.addingTimeInterval(60 * 60),
            query: nil, singleEvents: true, maxResults: 250, orderBy: "startTime")
        return rows
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .map { row in
                [row.id ?? "-", row.start?.date ?? row.start?.dateTime ?? "-", row.end?.date ?? row.end?.dateTime ?? "-", row.summary ?? "-"]
                    .joined(separator: " | ")
            }
    }

    private static func listing(_ provider: CalDAVProvider, _ series: Series) async throws -> [String] {
        try await listing(provider, first: series.first, through: try series.slot(5))
    }

    /// The rows of `rows` that are not the occurrence `id`.
    private static func without(_ id: String, _ rows: [String]) -> [String] {
        rows.filter { !$0.hasPrefix(id + " |") }
    }

    /// `ics` with the one line `line` taken out, and how many times that line was in it.
    private static func removingLine(_ line: String, from ics: String) -> (rest: String, count: Int) {
        let lines = ics.components(separatedBy: "\r\n")
        let rest = lines.filter { $0 != line }
        return (rest.joined(separator: "\r\n"), lines.count - rest.count)
    }

    /// The text from the series VEVENT's BEGIN to its END (the first VEVENT, as these fixtures write it).
    private static func masterBlock(of ics: String) -> String {
        guard let begin = ics.range(of: "BEGIN:VEVENT"),
              let end = ics.range(of: "END:VEVENT", range: begin.upperBound..<ics.endIndex) else { return "" }
        return String(ics[begin.lowerBound..<end.upperBound])
    }

    private static func writes(_ http: FakeHTTP.Scenario) -> [String] {
        http.recordedCalls().filter { $0.method != "GET" && $0.method != "REPORT" }.map { "\($0.method) \($0.url)" }
    }

    @Test("one occurrence is deleted with one conditional PUT that adds one EXDATE in the series' own form, and every other occurrence stays as it was",
          arguments: Frame.allCases)
    func deletesExactlyThatOccurrence(_ frame: Frame) async throws {
        let series = try Series(frame)
        let ics = OccurrenceFixture.ics([try series.master()])
        let fixture = W(zone: series.zone, first: series.first, ics: ics)
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let deleted = try series.occurrenceId(2)
        let seededETag = store.storedETag(path: W.seriesPath)

        let before = try await Self.listing(provider, series)
        #expect(before.contains { $0.hasPrefix(deleted + " |") }, "\(frame): setup: the occurrence is not listed before the delete: \(before)")

        try await provider.deleteEvent(calendarId: W.calendarId, eventId: deleted, sendUpdates: "all")

        // What the user sees: that occurrence gone, every other one as it was.
        let after = try await Self.listing(provider, series)
        #expect(after == Self.without(deleted, before), "\(frame): the listing did not lose exactly that occurrence.\nbefore: \(before)\nafter: \(after)")
        #expect(after.count == before.count - 1)
        await #expect("\(frame): the deleted occurrence still reads back by its id") {
            _ = try await provider.getEvent(calendarId: W.calendarId, eventId: deleted)
        } throws: { error in
            if case CalDAVError.notFound = error { return true }
            return false
        }

        // What the server got: one PUT on the series, conditional on the tag it read; no DELETE.
        let writes = Self.writes(http)
        #expect(writes.count == 1 && writes.allSatisfy { $0.hasPrefix("PUT ") && $0.hasSuffix(W.seriesPath) },
                "\(frame): the delete did not write exactly one PUT of the series: \(writes)")
        let puts = store.recordedPuts()
        #expect(puts.count == 1 && puts.first?.ifMatch == seededETag, "\(frame): the PUT was not conditional on the ETag the provider read: \(puts.map { $0.ifMatch ?? "nil" })")

        // The series as it was plus one EXDATE in the series' own form, byte for byte.
        let stored = try #require(store.storedICS(path: W.seriesPath))
        let exdate = try series.exdate(2)
        let (rest, count) = Self.removingLine(exdate, from: stored)
        #expect(count == 1, "\(frame): expected exactly one '\(exdate)' line: \(stored)")
        #expect(Self.masterBlock(of: stored).contains(exdate), "\(frame): the EXDATE is not in the series VEVENT: \(stored)")
        #expect(rest == ics, "\(frame): the rest of the series changed on the wire.\nsent: \(stored)")
    }

    /// How a changed occurrence's RECURRENCE-ID names its place in the series. Only the series'
    /// own form reads like the occurrence's key, so the other two tell a match by key from a
    /// match by text.
    enum Spelling: String, CaseIterable {
        /// The series DTSTART's own form: a DATE, a floating or UTC value, or a wall time in its TZID.
        case seriesForm
        /// UTC for a timed series (as Google spells it); the date with no VALUE parameter for an
        /// all-day one.
        case otherForm
        /// A wall time in another zone than the series' (`otherZoneId`) naming the same instant;
        /// for an all-day series a DATE-TIME at the start of that day.
        case otherZone

        static let otherZoneId = "Asia/Kolkata"

        func line(_ frame: Frame, _ slot: Date, zone: TimeZone) throws -> String {
            switch (self, frame) {
            case (.seriesForm, _):
                return try frame.line("RECURRENCE-ID", slot)
            case (.otherForm, .allDay):
                return "RECURRENCE-ID:\(OccurrenceFixture.dateValue(slot, zone))"
            case (.otherZone, .allDay):
                return "RECURRENCE-ID:\(OccurrenceFixture.dateValue(slot, zone))T000000"
            case (.otherForm, _):
                return "RECURRENCE-ID:\(OccurrenceFixture.utcValue(slot))"
            case (.otherZone, _):
                let other = try #require(TimeZone(identifier: Self.otherZoneId))
                return "RECURRENCE-ID;TZID=\(Self.otherZoneId):\(OccurrenceFixture.wall(slot, other))"
            }
        }
    }

    @Test("a moved occurrence is excluded at its place in the series and its changed copy removed, matched by its key whatever form its RECURRENCE-ID takes, in every series frame; another changed occurrence is kept",
          arguments: Frame.allCases, Spelling.allCases)
    func movedOccurrenceIsExcludedAtItsSlot(_ frame: Frame, _ spelling: Spelling) async throws {
        let series = try Series(frame)
        let zone = series.zone
        let calendar = OccurrenceFixture.calendar(zone)
        let label = "\(frame)/\(spelling)"
        // Week 2's occurrence moved to the next day (10:00, or that whole day) and retitled.
        let movedSlot = try series.slot(2)
        let dayAfter = try #require(calendar.date(byAdding: .day, value: 1, to: movedSlot))
        let movedTo = frame == .allDay
            ? calendar.startOfDay(for: dayAfter)
            : try #require(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: dayAfter))
        let keptSlot = try series.slot(3)
        let movedOverride = [
            "UID:standup-1", try spelling.line(frame, movedSlot, zone: zone),
            "DTSTAMP:\(OccurrenceFixture.utcValue(series.first))",
            try frame.line("DTSTART", movedTo), try frame.line("DTEND", try series.end(movedTo)),
            "SUMMARY:Standup (moved)",
        ].joined(separator: "\n")
        let keptOverride = [
            "UID:standup-1", try frame.line("RECURRENCE-ID", keptSlot),
            "DTSTAMP:\(OccurrenceFixture.utcValue(series.first))",
            try frame.line("DTSTART", keptSlot), try frame.line("DTEND", try series.end(keptSlot)),
            "SUMMARY:Standup (retitled)",
        ].joined(separator: "\n")
        let master = try series.master()
        let ics = OccurrenceFixture.ics([master, movedOverride, keptOverride])
        let (store, http) = W.serve(W(zone: zone, first: series.first, ics: ics))
        defer { http.close() }
        let provider = W.makeProvider(http)
        let deleted = try series.occurrenceId(2)

        let before = try await Self.listing(provider, series)
        let movedRow = before.first { $0.hasPrefix(deleted + " |") }
        #expect(movedRow?.contains("Standup (moved)") == true, "\(label): setup: the moved occurrence is not listed as moved: \(before)")
        #expect(before.contains { $0.contains("Standup (retitled)") }, "\(label): setup: the other changed occurrence is not listed: \(before)")

        try await provider.deleteEvent(calendarId: W.calendarId, eventId: deleted, sendUpdates: "all")

        let after = try await Self.listing(provider, series)
        #expect(after == Self.without(deleted, before),
                "\(label): the listing did not lose exactly the moved occurrence (or it came back at its place).\nbefore: \(before)\nafter: \(after)")
        #expect(Self.writes(http).count == 1 && store.recordedPuts().count == 1, "\(label): expected one PUT and nothing else: \(Self.writes(http))")

        // The EXDATE names the original slot, in the series' own form; the moved copy is gone and
        // the other changed occurrence is kept byte for byte.
        let stored = try #require(store.storedICS(path: W.seriesPath))
        let exdate = try series.exdate(2)
        let (rest, count) = Self.removingLine(exdate, from: stored)
        #expect(count == 1, "\(label): expected exactly one '\(exdate)' line: \(stored)")
        #expect(rest == OccurrenceFixture.ics([master, keptOverride]),
                "\(label): the series is not what it was less the moved copy plus the EXDATE.\nsent: \(stored)")
    }

    @Test("an exclusion the series would not read as the occurrence is never written: an occurrence added in UTC in the repeated hour of a fall-back day, with and without a changed copy, is refused and nothing is written",
          arguments: [false, true])
    func exclusionTheSeriesWouldNotReadIsNeverWritten(withChangedCopy: Bool) async throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        // The next change back to standard time (the UTC offset goes down), whatever today's date.
        var transition = try #require(zone.nextDaylightSavingTimeTransition(after: Date()))
        if zone.secondsFromGMT(for: transition) >= zone.secondsFromGMT(for: transition.addingTimeInterval(-60)) {
            transition = try #require(zone.nextDaylightSavingTimeTransition(after: transition))
        }
        #expect(zone.secondsFromGMT(for: transition) < zone.secondsFromGMT(for: transition.addingTimeInterval(-60)),
                "setup: no change back to standard time found")
        // The second of the two 01:30s that day, in standard time. Its wall time in the series'
        // zone names the first 01:30 (RFC 5545 §3.3.5), so an EXDATE written in that zone
        // excludes nothing.
        let repeated = transition.addingTimeInterval(30 * 60)
        let calendar = OccurrenceFixture.calendar(zone)
        let twoWeeksBefore = try #require(calendar.date(byAdding: .day, value: -14, to: transition))
        let first = try #require(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: twoWeeksBefore))
        let wall = { (date: Date) in OccurrenceFixture.wall(date, zone) }
        var vevents = [[
            "UID:standup-1", "DTSTAMP:\(OccurrenceFixture.utcValue(first))",
            "DTSTART;TZID=America/New_York:\(wall(first))",
            "DTEND;TZID=America/New_York:\(wall(first.addingTimeInterval(30 * 60)))",
            "SUMMARY:Standup", "RRULE:FREQ=WEEKLY", "RDATE:\(OccurrenceFixture.utcValue(repeated))",
        ].joined(separator: "\n")]
        if withChangedCopy {
            let movedTo = repeated.addingTimeInterval(60 * 60)
            vevents.append([
                "UID:standup-1", "RECURRENCE-ID:\(OccurrenceFixture.utcValue(repeated))",
                "DTSTAMP:\(OccurrenceFixture.utcValue(first))",
                "DTSTART:\(OccurrenceFixture.utcValue(movedTo))",
                "DTEND:\(OccurrenceFixture.utcValue(movedTo.addingTimeInterval(30 * 60)))",
                "SUMMARY:Standup (changed)",
            ].joined(separator: "\n"))
        }
        let ics = OccurrenceFixture.ics(vevents)
        let (store, http) = W.serve(W(zone: zone, first: first, ics: ics))
        defer { http.close() }
        let provider = W.makeProvider(http)
        let id = CalDAVOccurrences.OccurrenceId.make(seriesHref: W.seriesPath, key: OccurrenceFixture.utcValue(repeated))

        let listed = try await Self.listing(provider, first: repeated, through: repeated.addingTimeInterval(60 * 60))
        #expect(listed.contains { $0.hasPrefix(id + " |") }, "setup: the occurrence in the repeated hour is not listed: \(listed)")

        await #expect("the delete was not refused") {
            try await provider.deleteEvent(calendarId: W.calendarId, eventId: id, sendUpdates: "all")
        } throws: { error in
            guard case CalendarProviderError.notSupported(let reason) = error else { return false }
            return reason.contains("in a form the repeating event reads") && reason.contains("Nothing was deleted")
        }
        #expect(Self.writes(http).isEmpty, "the refused delete wrote: \(Self.writes(http))")
        #expect(store.storedICS(path: W.seriesPath) == ics, "the series is not on the server as it was")
    }

    @Test("an occurrence the series no longer has (excluded, cancelled, never there, or already deleted) is not found and nothing is written")
    func missingOrCancelledOccurrenceWritesNothing() async throws {
        let fixture = try W.makeChanged()
        let cancelledSlot = try fixture.occurrence(2)
        let wall = { (date: Date) in OccurrenceFixture.wall(date, fixture.zone) }
        let cancelled = [
            "UID:standup-1", "RECURRENCE-ID;TZID=America/New_York:\(wall(cancelledSlot))",
            "DTSTAMP:\(OccurrenceFixture.utcValue(fixture.first))",
            "DTSTART;TZID=America/New_York:\(wall(cancelledSlot))",
            "DTEND;TZID=America/New_York:\(wall(cancelledSlot.addingTimeInterval(30 * 60)))",
            "STATUS:CANCELLED",
        ].joined(separator: "\r\n")
        let ics = fixture.ics.replacingOccurrences(of: "END:VCALENDAR", with: "BEGIN:VEVENT\r\n\(cancelled)\r\nEND:VEVENT\r\nEND:VCALENDAR")
        let (store, http) = W.serve(W(zone: fixture.zone, first: fixture.first, ics: ics))
        defer { http.close() }
        let provider = W.makeProvider(http)
        let between = CalDAVOccurrences.OccurrenceId.make(
            seriesHref: W.seriesPath, key: OccurrenceFixture.utcValue(try fixture.occurrence(4).addingTimeInterval(60 * 60)))
        let cases = [
            ("excluded", try fixture.occurrenceId(W.excludedWeek)),
            ("cancelled", try fixture.occurrenceId(2)),
            ("never there", between),
        ]
        for (label, id) in cases {
            await #expect("\(label): not reported as not found") {
                try await provider.deleteEvent(calendarId: W.calendarId, eventId: id, sendUpdates: "all")
            } throws: { error in
                if case CalDAVError.notFound = error { return true }
                return false
            }
            #expect(Self.writes(http).isEmpty, "\(label): the refused delete wrote: \(Self.writes(http))")
            #expect(store.storedICS(path: W.seriesPath) == ics, "\(label): the series is not on the server as it was")
        }

        // A retry of a delete whose first attempt landed (its response lost) finds it gone.
        let fourth = try fixture.occurrenceId(4)
        try await provider.deleteEvent(calendarId: W.calendarId, eventId: fourth, sendUpdates: "all")
        await #expect("the repeated delete was not reported as not found") {
            try await provider.deleteEvent(calendarId: W.calendarId, eventId: fourth, sendUpdates: "all")
        } throws: { error in
            if case CalDAVError.notFound = error { return true }
            return false
        }
        #expect(store.recordedPuts().count == 1, "the repeated delete wrote again: \(Self.writes(http))")
    }

    @Test("an occurrence of a resource that holds only changed occurrences, with no series, is refused and nothing is written")
    func changedOnlyResourceIsRefused() async throws {
        let fixture = try W.make()
        let slot = try fixture.occurrence(2)
        let start = slot.addingTimeInterval(60 * 60)
        let wall = { (date: Date) in OccurrenceFixture.wall(date, fixture.zone) }
        let path = "/cal/invite.ics"
        let ics = OccurrenceFixture.ics([[
            "UID:invite-1", "DTSTAMP:\(OccurrenceFixture.utcValue(fixture.first))",
            "RECURRENCE-ID;TZID=America/New_York:\(wall(slot))",
            "DTSTART;TZID=America/New_York:\(wall(start))",
            "DTEND;TZID=America/New_York:\(wall(start.addingTimeInterval(30 * 60)))",
            "SUMMARY:Planning", "ORGANIZER:mailto:organizer@example.com", "ATTENDEE:mailto:user@example.com",
        ].joined(separator: "\n")])
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        store.seed(path: path, ics: ics)
        let id = CalDAVOccurrences.OccurrenceId.make(seriesHref: path, key: OccurrenceFixture.utcValue(slot))

        await #expect {
            try await W.makeProvider(http).deleteEvent(calendarId: W.calendarId, eventId: id, sendUpdates: "all")
        } throws: { error in
            guard case CalendarProviderError.notSupported(let reason) = error else { return false }
            return reason.contains("without their repeating event") && reason.contains("Nothing was deleted")
        }
        #expect(Self.writes(http).isEmpty, "the refused delete wrote: \(Self.writes(http))")
        #expect(store.storedICS(path: path) == ics, "the resource is not on the server as it was")
    }

    @Test("a change by another client between the read and the write fails the PUT with 412 and survives; the retry deletes the occurrence from the series as it now stands")
    func concurrentChangeFailsThePreconditionAndSurvives() async throws {
        let fixture = try W.make()
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: W.seriesPath, ics: fixture.ics)
        let concurrentICS = fixture.ics.replacingOccurrences(of: "SUMMARY:Standup", with: "SUMMARY:Renamed by another client")
        let changedOnce = Mutex(false)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/cal/", method: "GET") { request in
            let response = store.handleGET(request)
            // Another client edits the series right after the provider reads it.
            if changedOnce.withLock({ done in defer { done = true }; return !done }) {
                store.replaceOutOfBand(path: W.seriesPath, ics: concurrentICS)
            }
            return response
        }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
        http.register(path: "/cal/", method: "DELETE") { store.handleDELETE($0) }
        let provider = W.makeProvider(http)
        let deleted = try fixture.occurrenceId(2)

        await #expect("the stale write was not refused as a failed precondition") {
            try await provider.deleteEvent(calendarId: W.calendarId, eventId: deleted, sendUpdates: "all")
        } throws: { error in
            if case CalDAVError.preconditionFailed = error { return true }
            return false
        }
        #expect(store.storedICS(path: W.seriesPath) == concurrentICS, "the delete overwrote a change it never read")
        let refused = store.recordedPuts()
        #expect(refused.count == 1 && refused.first?.ifMatch == "\"seed\"" && refused.first?.returnedETag == nil,
                "the PUT was not conditional on the tag the provider read")

        try await provider.deleteEvent(calendarId: W.calendarId, eventId: deleted, sendUpdates: "all")
        let stored = try #require(store.storedICS(path: W.seriesPath))
        let exdate = "EXDATE;TZID=America/New_York:\(OccurrenceFixture.wall(try fixture.occurrence(2), fixture.zone))"
        let (rest, count) = Self.removingLine(exdate, from: stored)
        #expect(count == 1 && rest == concurrentICS,
                "the retry did not delete the occurrence from the series as the other client left it: \(stored)")
        #expect(http.recordedCalls().allSatisfy { $0.method != "DELETE" }, "a DELETE reached the server")
    }

    @Test("on a server that sends no ETag the delete is one unconditional PUT (IOS-CAL-002) that still removes exactly that occurrence")
    func serverWithoutETagsGetsOneUnconditionalPut() async throws {
        let fixture = try W.make()
        let store = FakeCalDAVStore(servesETags: false)
        store.seed(path: W.seriesPath, ics: fixture.ics)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
        http.register(path: "/cal/", method: "DELETE") { store.handleDELETE($0) }
        let provider = W.makeProvider(http)

        try await provider.deleteEvent(calendarId: W.calendarId, eventId: try fixture.occurrenceId(2), sendUpdates: "all")

        let puts = store.recordedPuts()
        #expect(puts.count == 1 && puts.first?.ifMatch == nil && puts.first?.ifNoneMatch == nil,
                "expected one PUT with no precondition: \(puts.map { "If-Match \($0.ifMatch ?? "nil"), If-None-Match \($0.ifNoneMatch ?? "nil")" })")
        let stored = try #require(store.storedICS(path: W.seriesPath))
        let exdate = "EXDATE;TZID=America/New_York:\(OccurrenceFixture.wall(try fixture.occurrence(2), fixture.zone))"
        let (rest, count) = Self.removingLine(exdate, from: stored)
        #expect(count == 1 && rest == fixture.ics, "the series is not what it was plus the one EXDATE: \(stored)")
        let writes = Self.writes(http)
        #expect(writes.count == 1 && writes.allSatisfy { $0.hasPrefix("PUT ") && $0.hasSuffix(W.seriesPath) },
                "expected one PUT of the series and nothing else: \(writes)")
    }

    /// How another client changes the series between the listing and the delete.
    enum LaterChange: String, CaseIterable {
        case secondRule, exRule, ruleRemoved

        func apply(to ics: String) -> String {
            let rule = "RRULE:FREQ=WEEKLY"
            switch self {
            case .secondRule: return ics.replacingOccurrences(of: rule, with: "\(rule)\r\nRRULE:FREQ=MONTHLY")
            case .exRule: return ics.replacingOccurrences(of: rule, with: "\(rule)\r\nEXRULE:FREQ=MONTHLY")
            case .ruleRemoved: return ics.replacingOccurrences(of: "\(rule)\r\n", with: "")
            }
        }
    }

    @Test("a series changed after the listing into one TabMail can't expand, or into one that no longer repeats, is refused as such, never reported not found, and nothing is written",
          arguments: LaterChange.allCases)
    func seriesTabMailCantReadIsRefusedNotReportedMissing(_ change: LaterChange) async throws {
        let fixture = try W.make()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let id = try fixture.occurrenceId(2)
        let listed = try await Self.listing(provider, first: fixture.first, through: try fixture.occurrence(5))
        #expect(listed.contains { $0.hasPrefix(id + " |") }, "\(change): setup: the occurrence is not listed: \(listed)")
        let changed = change.apply(to: fixture.ics)
        #expect(changed != fixture.ics, "\(change): setup: the series did not change")
        store.replaceOutOfBand(path: W.seriesPath, ics: changed)

        await #expect("\(change): the delete was not refused as unsupported") {
            try await provider.deleteEvent(calendarId: W.calendarId, eventId: id, sendUpdates: "all")
        } throws: { error in
            guard case CalendarProviderError.notSupported(let reason) = error else { return false }
            return reason.contains("Nothing was deleted")
        }
        #expect(Self.writes(http).isEmpty, "\(change): the refused delete wrote: \(Self.writes(http))")
        #expect(store.storedICS(path: W.seriesPath) == changed, "\(change): the series is not on the server as it was")
    }

    /// Which VEVENT of `paddedMarkersKeepEveryOtherVEvent`'s resource ends with a padded
    /// `END:VEVENT` line (a trailing space).
    enum PaddedEnd: String, CaseIterable { case changedCopy, series }

    @Test("an END:VEVENT line with trailing space, after the deleted occurrence's changed copy or after the series, is read as the end of that VEVENT, so the next changed occurrence is kept",
          arguments: PaddedEnd.allCases)
    func paddedMarkersKeepEveryOtherVEvent(_ padded: PaddedEnd) async throws {
        let series = try Series(.zoned)
        let wall = { (date: Date) in OccurrenceFixture.wall(date, series.zone) }
        let slot = try series.slot(2)
        let keptSlot = try series.slot(3)
        let target = [
            "UID:standup-1", "RECURRENCE-ID;TZID=America/New_York:\(wall(slot))",
            "DTSTAMP:\(OccurrenceFixture.utcValue(series.first))",
            "DTSTART;TZID=America/New_York:\(wall(slot.addingTimeInterval(60 * 60)))",
            "DTEND;TZID=America/New_York:\(wall(slot.addingTimeInterval(90 * 60)))",
            "SUMMARY:Standup (later)",
        ].joined(separator: "\n")
        let kept = [
            "UID:standup-1", "RECURRENCE-ID;TZID=America/New_York:\(wall(keptSlot))",
            "DTSTAMP:\(OccurrenceFixture.utcValue(series.first))",
            "DTSTART;TZID=America/New_York:\(wall(keptSlot))",
            "DTEND;TZID=America/New_York:\(wall(keptSlot.addingTimeInterval(series.length)))",
            "SUMMARY:Standup (retitled)",
        ].joined(separator: "\n")
        let master = try series.master()
        let lastLine = padded == .series ? "RRULE:FREQ=WEEKLY" : "SUMMARY:Standup (later)"
        let pad = { (ics: String) in
            ics.replacingOccurrences(of: "\(lastLine)\r\nEND:VEVENT\r\n", with: "\(lastLine)\r\nEND:VEVENT \r\n")
        }
        let ics = pad(OccurrenceFixture.ics([master, target, kept]))
        #expect(ics.contains("END:VEVENT \r\n"), "\(padded): setup: no padded END:VEVENT line")
        let (store, http) = W.serve(W(zone: series.zone, first: series.first, ics: ics))
        defer { http.close() }
        let provider = W.makeProvider(http)
        let deleted = try series.occurrenceId(2)

        let before = try await Self.listing(provider, series)
        #expect(before.contains { $0.hasPrefix(deleted + " |") && $0.contains("Standup (later)") }, "\(padded): setup: the changed occurrence is not listed: \(before)")
        #expect(before.contains { $0.contains("Standup (retitled)") }, "\(padded): setup: the other changed occurrence is not listed: \(before)")

        try await provider.deleteEvent(calendarId: W.calendarId, eventId: deleted, sendUpdates: "all")

        let after = try await Self.listing(provider, series)
        #expect(after == Self.without(deleted, before), "\(padded): the listing did not lose exactly that occurrence.\nbefore: \(before)\nafter: \(after)")
        let stored = try #require(store.storedICS(path: W.seriesPath))
        let (rest, count) = Self.removingLine(try series.exdate(2), from: stored)
        let expected = padded == .series ? pad(OccurrenceFixture.ics([master, kept])) : OccurrenceFixture.ics([master, kept])
        #expect(count == 1 && rest == expected, "\(padded): the series is not what it was less that changed copy plus the EXDATE.\nsent: \(stored)")
    }

    /// What the check before the PUT is handed in `rebuiltResourceThatLosesMoreIsRefused`.
    enum Rebuilt: String, CaseIterable {
        /// As the delete builds it: the EXDATE added and the occurrence's changed copy removed.
        case asBuilt
        /// Another changed occurrence removed too.
        case anotherChangedCopyLost
        /// The series VEVENT removed.
        case seriesLost
    }

    @Test("the check before the PUT refuses a rebuilt resource that lost the series or another changed occurrence, nothing deleted, and passes the one the delete builds",
          arguments: Rebuilt.allCases)
    func rebuiltResourceThatLosesMoreIsRefused(_ rebuilt: Rebuilt) throws {
        let series = try Series(.zoned)
        let wall = { (date: Date) in OccurrenceFixture.wall(date, series.zone) }
        let override = { (week: Int, title: String) throws -> String in
            let slot = try series.slot(week)
            return [
                "UID:standup-1", "RECURRENCE-ID;TZID=America/New_York:\(wall(slot))",
                "DTSTAMP:\(OccurrenceFixture.utcValue(series.first))",
                "DTSTART;TZID=America/New_York:\(wall(slot.addingTimeInterval(60 * 60)))",
                "DTEND;TZID=America/New_York:\(wall(slot.addingTimeInterval(90 * 60)))",
                "SUMMARY:\(title)",
            ].joined(separator: "\n")
        }
        let master = try series.master()
        let target = try override(2, "Standup (later)")
        let other = try override(3, "Standup (retitled)")
        let stored = OccurrenceFixture.ics([master, target, other])
        let key = try #require(try CalDAVOccurrences.OccurrenceId.split(try series.occurrenceId(2)).key)
        let deletion = try CalDAVOccurrences.deletion(icsText: stored, href: W.seriesPath, key: key)
        let excluded = master + "\n" + (try series.exdate(2))
        let updated: String
        switch rebuilt {
        case .asBuilt: updated = OccurrenceFixture.ics([excluded, other])
        case .anotherChangedCopyLost: updated = OccurrenceFixture.ics([excluded])
        case .seriesLost: updated = OccurrenceFixture.ics([other])
        }

        guard rebuilt != .asBuilt else {
            try CalDAVOccurrences.requireDeletedAlone(deletion, updatedICS: updated, href: W.seriesPath)
            return
        }
        #expect("\(rebuilt): the check let it through") {
            try CalDAVOccurrences.requireDeletedAlone(deletion, updatedICS: updated, href: W.seriesPath)
        } throws: { error in
            guard case CalendarProviderError.notSupported(let reason) = error else { return false }
            return reason.contains("would not keep the rest of it") && reason.contains("Nothing was deleted")
                && reason.contains("calendar app")
        }
    }
}
