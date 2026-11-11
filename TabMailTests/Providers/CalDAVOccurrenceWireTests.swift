/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - CalDAV occurrence ids over the wire (ADR-IOS-108)
//
// INVARIANT (system property): an id that names ONE occurrence of a repeating CalDAV
// event can only ever affect that occurrence. A WebDAV DELETE removes the whole
// resource, which holds every occurrence, and a URL drops its `#` fragment from the
// request, so on the code before ADR-IOS-108 a delete given an occurrence id would have
// gone out as a DELETE of the series. The delete by an occurrence id never sends a DELETE:
// it writes an EXDATE into the series (#661, `CalDAVOccurrenceDeleteWireTests`); reads and edits
// by an occurrence id address that occurrence inside its series' resource.
//
// A second property for the edits: one occurrence's edit or a split writes only at an
// occurrence the resource has now (the one an occurrence id names, or the one a series id's
// `recurrence_id` names where it is now), and an edit of the whole event (edit_scope all)
// given an occurrence id is refused by the provider before it sends any request: the user
// confirmed ONE occurrence, and on CalDAV the whole event is every occurrence. Anything
// else is refused with nothing written, asserted on what the fake server holds afterwards
// and on what a listing then shows.
//
// Dates are worked out from `Date()`; none is written as a literal.

/// One weekly series in New York time on a fake CalDAV server.
struct OccurrenceWireFixture {
    static let calendarHome = URL(string: "https://caldav.example.com/cal/")!
    static let calendarId = "/cal/"
    static let seriesPath = "/cal/standup.ics"
    /// In `makeChanged()`, the week whose occurrence is removed (EXDATE) and the week
    /// whose occurrence is moved to the next day at 10:00 (an override).
    static let excludedWeek = 1
    static let movedWeek = 3

    let zone: TimeZone
    /// The series' first occurrence, 09:00 New York time a week ago.
    let first: Date
    let ics: String

    static func make() throws -> OccurrenceWireFixture {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let calendar = OccurrenceFixture.calendar(zone)
        let weekAgo = try #require(calendar.date(byAdding: .day, value: -7, to: Date()))
        let first = try #require(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: weekAgo))
        let ics = OccurrenceFixture.ics([seriesVEvent(first: first, zone: zone, extra: [])])
        return OccurrenceWireFixture(zone: zone, first: first, ics: ics)
    }

    /// The same series as a calendar app leaves it after two changes: week `excludedWeek`'s
    /// occurrence removed, and week `movedWeek`'s moved to the next day at 10:00 and
    /// retitled "Standup (moved)".
    static func makeChanged() throws -> OccurrenceWireFixture {
        let base = try make()
        let zone = base.zone
        let wall = { (date: Date) in OccurrenceFixture.wall(date, zone) }
        let excluded = try base.occurrence(excludedWeek)
        let slot = try base.occurrence(movedWeek)
        let moved = try base.movedStart()
        let ics = OccurrenceFixture.ics([
            seriesVEvent(first: base.first, zone: zone, extra: ["EXDATE;TZID=America/New_York:\(wall(excluded))"]),
            """
            UID:standup-1
            RECURRENCE-ID;TZID=America/New_York:\(wall(slot))
            DTSTAMP:\(OccurrenceFixture.utcValue(base.first))
            DTSTART;TZID=America/New_York:\(wall(moved))
            DTEND;TZID=America/New_York:\(wall(moved.addingTimeInterval(30 * 60)))
            SUMMARY:Standup (moved)
            """,
        ])
        return OccurrenceWireFixture(zone: zone, first: base.first, ics: ics)
    }

    /// The series with week `week`'s occurrence moved to the day after week `toWeek`'s, at
    /// 10:00 (`movedStart(toWeek:)`), title unchanged: an occurrence whose place in the
    /// series is weeks before where it now is.
    static func makeMoved(week: Int, toWeek: Int) throws -> OccurrenceWireFixture {
        let base = try make()
        let zone = base.zone
        let wall = { (date: Date) in OccurrenceFixture.wall(date, zone) }
        let slot = try base.occurrence(week)
        let moved = try base.movedStart(toWeek: toWeek)
        let ics = OccurrenceFixture.ics([
            seriesVEvent(first: base.first, zone: zone, extra: []),
            """
            UID:standup-1
            RECURRENCE-ID;TZID=America/New_York:\(wall(slot))
            DTSTAMP:\(OccurrenceFixture.utcValue(base.first))
            DTSTART;TZID=America/New_York:\(wall(moved))
            DTEND;TZID=America/New_York:\(wall(moved.addingTimeInterval(30 * 60)))
            SUMMARY:Standup
            """,
        ])
        return OccurrenceWireFixture(zone: zone, first: base.first, ics: ics)
    }

    /// The series' VEVENT, with `extra` lines after its rule.
    private static func seriesVEvent(first: Date, zone: TimeZone, extra: [String]) -> String {
        let wall = { (date: Date) in OccurrenceFixture.wall(date, zone) }
        return ([
            "UID:standup-1",
            "DTSTAMP:\(OccurrenceFixture.utcValue(first))",
            "DTSTART;TZID=America/New_York:\(wall(first))",
            "DTEND;TZID=America/New_York:\(wall(first.addingTimeInterval(30 * 60)))",
            "SUMMARY:Standup",
            "RRULE:FREQ=WEEKLY",
        ] + extra).joined(separator: "\n")
    }

    /// The `weeks`-th occurrence (0 = the first), at 09:00 New York time.
    func occurrence(_ weeks: Int) throws -> Date {
        try #require(OccurrenceFixture.calendar(zone).date(byAdding: .day, value: 7 * weeks, to: first))
    }

    /// Where `makeChanged()` moved week `movedWeek`'s occurrence (or `makeMoved` moved one to
    /// week `toWeek`): the day after that week's occurrence, 10:00 New York time.
    func movedStart(toWeek: Int = movedWeek) throws -> Date {
        let calendar = OccurrenceFixture.calendar(zone)
        let slot = try occurrence(toWeek)
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: slot))
        return try #require(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: nextDay))
    }

    func occurrenceId(_ weeks: Int) throws -> String {
        CalDAVOccurrences.OccurrenceId.make(
            seriesHref: Self.seriesPath, key: OccurrenceFixture.utcValue(try occurrence(weeks)))
    }

    /// The forms a RECURRENCE-ID is written in (`overrideOnly(form:)`).
    static let overrideOnlyForms = ["tzid", "utc", "date"]

    /// A resource holding only changed occurrences, as a server stores an invitation to single
    /// occurrences of another organizer's series (RFC 4791 §4.1): week 2's occurrence, with its
    /// RECURRENCE-ID written in `form` (`tzid`, `utc` or `date`, the date form an all-day
    /// occurrence). `moved`: it starts an hour (the date form: a day) later than its place in the
    /// series; otherwise at its place. `slot` is its place, `start` where it is, `key` the key a
    /// listing gives it.
    func overrideOnly(form: String, moved: Bool = true) throws -> (ics: String, slot: Date, start: Date, key: String) {
        let slot = try occurrence(2)
        let zone = self.zone
        let wall = { (date: Date) in OccurrenceFixture.wall(date, zone) }
        let head = ["UID:invite-1", "DTSTAMP:\(OccurrenceFixture.utcValue(first))"]
        let tail = ["SUMMARY:Planning", "ORGANIZER:mailto:organizer@example.com", "ATTENDEE:mailto:user@example.com"]
        switch form {
        case "date":
            let start = try #require(OccurrenceFixture.calendar(zone).date(byAdding: .day, value: moved ? 1 : 0, to: slot))
            let lines = head + [
                "RECURRENCE-ID;VALUE=DATE:\(OccurrenceFixture.dateValue(slot, zone))",
                "DTSTART;VALUE=DATE:\(OccurrenceFixture.dateValue(start, zone))",
                "DTEND;VALUE=DATE:\(OccurrenceFixture.dateValue(start.addingTimeInterval(OccurrenceFixture.days(1)), zone))",
            ] + tail
            return (OccurrenceFixture.ics([lines.joined(separator: "\n")]), slot, start, OccurrenceFixture.dateValue(slot, zone))
        default:
            let start = slot.addingTimeInterval(moved ? 60 * 60 : 0)
            let recurrenceId = form == "utc"
                ? "RECURRENCE-ID:\(OccurrenceFixture.utcValue(slot))"
                : "RECURRENCE-ID;TZID=America/New_York:\(wall(slot))"
            let lines = head + [
                recurrenceId,
                "DTSTART;TZID=America/New_York:\(wall(start))",
                "DTEND;TZID=America/New_York:\(wall(start.addingTimeInterval(30 * 60)))",
            ] + tail
            return (OccurrenceFixture.ics([lines.joined(separator: "\n")]), slot, start, OccurrenceFixture.utcValue(slot))
        }
    }

    /// A store holding the series, and a scenario that routes every CalDAV method the
    /// provider uses to it.
    static func serve(_ fixture: OccurrenceWireFixture) -> (store: FakeCalDAVStore, http: FakeHTTP.Scenario) {
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: seriesPath, ics: fixture.ics)
        let http = FakeHTTP.Scenario()
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
        http.register(path: "/cal/", method: "REPORT") { store.handleREPORT($0) }
        http.register(path: "/cal/", method: "DELETE") { store.handleDELETE($0) }
        return (store, http)
    }

    static func makeProvider(_ http: FakeHTTP.Scenario) -> CalDAVProvider {
        CalDAVProvider(
            client: CalDAVClient(username: "user@example.com", password: "pw", session: http.session),
            calendarHomeURL: calendarHome,
            serverBaseURL: calendarHome)
    }
}

@Suite("CalDAVProvider: occurrence ids over the wire", .serialized)
struct CalDAVOccurrenceWireTests {
    typealias W = OccurrenceWireFixture

    private static func deletes(_ http: FakeHTTP.Scenario) -> [String] {
        http.recordedCalls().filter { $0.method == "DELETE" }.map(\.url)
    }

    /// Every row a listing shows from the series' first occurrence through week `weeks`, by start.
    private static func listWeeks(_ provider: CalDAVProvider, _ fixture: W, through weeks: Int) async throws -> [GCalEvent] {
        let timeMax = try fixture.occurrence(weeks + 1).addingTimeInterval(-60)
        let rows = try await provider.listEvents(
            calendarId: W.calendarId, timeMin: fixture.first.addingTimeInterval(-60), timeMax: timeMax,
            query: nil, singleEvents: true, maxResults: 250, orderBy: "startTime")
        return rows.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    /// The lines of a resource that start with `name`, in order.
    private static func lines(of ics: String, named name: String) -> [String] {
        ics.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix(name) }
    }

    /// A provider refusal whose reason, as an edit is told it (`CalendarProviderError.reason`:
    /// `notSupported`'s own, or a neutral case's edit wording), contains `phrase`.
    private static func isRefusal(_ error: any Error, saying phrase: String) -> Bool {
        guard let refused = error as? CalendarProviderError else { return false }
        return refused.reason.contains(phrase)
    }

    /// The authoritative absence Google and Outlook report for an occurrence that isn't
    /// there, which the calendar queue retires as not found.
    private static func isNotFound(_ error: any Error) -> Bool {
        if case CalDAVError.notFound = error { return true }
        return false
    }

    @Test("listEvents lists each occurrence in the range, each with its own id")
    func listEventsListsEachOccurrence() async throws {
        let fixture = try W.make()
        let (_, http) = W.serve(fixture)
        defer { http.close() }

        let rows = try await W.makeProvider(http).listEvents(
            calendarId: W.calendarId,
            timeMin: try fixture.occurrence(1).addingTimeInterval(-60),
            timeMax: try fixture.occurrence(4).addingTimeInterval(-60),
            query: nil, singleEvents: true, maxResults: 250, orderBy: "startTime")

        let ids = try [1, 2, 3].map { try fixture.occurrenceId($0) }
        let starts = try [1, 2, 3].map { try fixture.occurrence($0) }
        #expect(rows.compactMap(\.id) == ids)
        #expect(rows.compactMap(\.startDate) == starts)
        #expect(rows.allSatisfy { $0.recurringEventId == W.seriesPath })
    }

    @Test("a cancelled occurrence is not listed")
    func cancelledOccurrenceIsNotListed() async throws {
        let fixture = try W.make()
        let cancelled = try fixture.occurrence(2)
        let override = """
            BEGIN:VEVENT\r
            UID:standup-1\r
            RECURRENCE-ID;TZID=America/New_York:\(OccurrenceFixture.wall(cancelled, fixture.zone))\r
            DTSTART;TZID=America/New_York:\(OccurrenceFixture.wall(cancelled, fixture.zone))\r
            DTEND;TZID=America/New_York:\(OccurrenceFixture.wall(cancelled.addingTimeInterval(30 * 60), fixture.zone))\r
            STATUS:CANCELLED\r
            END:VEVENT\r
            END:VCALENDAR
            """
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        store.seed(path: W.seriesPath, ics: fixture.ics.replacingOccurrences(of: "END:VCALENDAR", with: override))

        let rows = try await W.makeProvider(http).listEvents(
            calendarId: W.calendarId,
            timeMin: try fixture.occurrence(1).addingTimeInterval(-60),
            timeMax: try fixture.occurrence(4).addingTimeInterval(-60),
            query: nil, singleEvents: true, maxResults: 250, orderBy: "startTime")

        let ids = try [1, 3].map { try fixture.occurrenceId($0) }
        #expect(rows.compactMap(\.id) == ids)
    }

    @Test("getEvent by an occurrence id reads that occurrence; by the series id, the series; by a stale id, not found")
    func getEventReadsWhatTheIdNames() async throws {
        let fixture = try W.make()
        let (_, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)

        let thirdId = try fixture.occurrenceId(3)
        let thirdStart = try fixture.occurrence(3)
        let occurrence = try await provider.getEvent(calendarId: W.calendarId, eventId: thirdId)
        #expect(occurrence.id == thirdId)
        #expect(occurrence.startDate == thirdStart)
        #expect(occurrence.recurringEventId == W.seriesPath)

        let series = try await provider.getEvent(calendarId: W.calendarId, eventId: W.seriesPath)
        #expect(series.id == W.seriesPath)
        #expect(series.startDate == fixture.first)

        let stale = CalDAVOccurrences.OccurrenceId.make(
            seriesHref: W.seriesPath, key: OccurrenceFixture.utcValue(thirdStart.addingTimeInterval(60 * 60)))
        await #expect {
            _ = try await provider.getEvent(calendarId: W.calendarId, eventId: stale)
        } throws: { error in
            if case CalDAVError.notFound = error { return true }
            return false
        }
    }

    @Test("deleting by an occurrence id sends no DELETE: the series stays on the server, without that occurrence only (#661)")
    func deleteByOccurrenceIdSendsNoDelete() async throws {
        let fixture = try W.make()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let oneDay = try fixture.occurrenceId(2)

        try await provider.deleteEvent(calendarId: W.calendarId, eventId: oneDay, sendUpdates: "all")

        #expect(Self.deletes(http).isEmpty, "a DELETE reached the server for one occurrence: \(Self.deletes(http))")
        #expect(store.storedICS(path: W.seriesPath) != nil, "the series is no longer on the server")
        let rows = try await Self.listWeeks(provider, fixture, through: 3)
        #expect(rows.compactMap(\.id) == (try [0, 1, 3].map { try fixture.occurrenceId($0) }),
                "the series does not hold every other occurrence: \(rows.compactMap(\.id))")
    }

    @Test("Control: deleting by the series id still deletes the series")
    func deleteBySeriesIdDeletesTheSeries() async throws {
        let fixture = try W.make()
        let (store, http) = W.serve(fixture)
        defer { http.close() }

        try await W.makeProvider(http).deleteEvent(calendarId: W.calendarId, eventId: W.seriesPath, sendUpdates: "all")

        #expect(Self.deletes(http).count == 1, "the fixture must be able to send a DELETE, or the refusal's absence proves nothing")
        #expect(store.storedICS(path: W.seriesPath) == nil)
    }

    @Test("an edit of the whole event (edit_scope all) given an occurrence id, a changed occurrence's id included, is refused at the provider before any request, whatever it sets")
    func allEditByOccurrenceIdIsRefused() async throws {
        let fixture = try W.makeChanged()
        let shown = try fixture.occurrence(2)
        let hour: TimeInterval = 60 * 60
        let day = OccurrenceFixture.isoDate
        var title = GCalEventInput()
        title.summary = "Team standup"
        var location = GCalEventInput()
        location.location = "Room 2"
        var notes = GCalEventInput()
        notes.description = "Bring notes"
        var busy = GCalEventInput()
        busy.transparency = "transparent"
        var start = GCalEventInput()
        start.startDateTime = shown.addingTimeInterval(hour).iso8601String()
        start.startTimeZone = "America/New_York"
        var end = GCalEventInput()
        end.endDateTime = shown.addingTimeInterval(45 * 60).iso8601String()
        end.endTimeZone = "America/New_York"
        var allDayStart = GCalEventInput()
        allDayStart.startDate = day(shown, fixture.zone)
        // An all-day event given only end_iso sends exactly this (`buildGCalEventInput`).
        var allDayEnd = GCalEventInput()
        allDayEnd.endDate = day(shown.addingTimeInterval(OccurrenceFixture.days(2)), fixture.zone)
        var guests = GCalEventInput()
        guests.attendeeChange = AttendeeChange(adds: [.init(email: "guest@example.com", name: nil)])
        var rule = GCalEventInput()
        rule.recurrence = ["RRULE:FREQ=DAILY"]
        let patches: [(label: String, patch: GCalEventInput)] = [
            ("a title", title), ("a location", location), ("notes", notes), ("busy status", busy),
            ("a start", start), ("an end", end), ("an all-day start", allDayStart), ("an all-day end alone", allDayEnd),
            ("guests", guests), ("a repeat rule", rule),
        ]
        let secondId = try fixture.occurrenceId(2)
        let movedId = try fixture.occurrenceId(W.movedWeek)
        let ids: [(label: String, eventId: String)] = [
            ("week 2's id", secondId),
            ("the moved occurrence's id", movedId),
        ]

        for id in ids {
            for entry in patches {
                let (store, http) = W.serve(fixture)
                defer { http.close() }
                // `updateEvent` is what the calendar queue runs for edit_scope "all", and for an
                // edit given neither edit_scope nor recurrence_id.
                await #expect("\(id.label), setting \(entry.label), was not refused") {
                    _ = try await W.makeProvider(http).updateEvent(
                        calendarId: W.calendarId, eventId: id.eventId, event: entry.patch, sendUpdates: "all")
                } throws: { error in
                    Self.isRefusal(error, saying: "nothing was changed")
                        && Self.isRefusal(error, saying: "edit_scope this_only")
                        && Self.isRefusal(error, saying: "calendar app")
                }
                #expect(http.recordedCalls().isEmpty, "\(id.label), \(entry.label): a request went out: \(http.servedCallSequence())")
                #expect(store.storedICS(path: W.seriesPath) == fixture.ics, "\(id.label), \(entry.label): the series is not on the server as it was")
            }
        }
    }

    @Test("Control: the series id still edits the whole series, every occurrence, as before")
    func allEditBySeriesIdEditsTheSeries() async throws {
        let fixture = try W.make()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        var patch = GCalEventInput()
        patch.summary = "Team standup"
        let before = try await Self.listWeeks(provider, fixture, through: 4)

        _ = try await provider.updateEvent(
            calendarId: W.calendarId, eventId: W.seriesPath, event: patch, sendUpdates: "all")

        #expect(store.recordedPuts().map(\.path) == [W.seriesPath], "the harness must be able to write, or the refusals prove nothing")
        let after = try await Self.listWeeks(provider, fixture, through: 4)
        #expect(after.compactMap(\.startDate) == before.compactMap(\.startDate), "the edit moved an occurrence")
        #expect(after.count == 5 && after.allSatisfy { $0.summary == "Team standup" },
                "the series' occurrences do not all show the edit: \(after.map(\.summary))")
    }

    @Test("this_only by an occurrence id changes that occurrence only, inside the series' resource")
    func thisOnlyEditByOccurrenceIdChangesThatOccurrence() async throws {
        let fixture = try W.make()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        var patch = GCalEventInput()
        patch.summary = "Standup with guests"
        let secondId = try fixture.occurrenceId(2)
        let starts = try [1, 2, 3].map { try fixture.occurrence($0) }
        let recurrenceId = OccurrenceFixture.naive(try fixture.occurrence(2), fixture.zone)

        let edited = try await provider.updateOccurrence(
            calendarId: W.calendarId, eventId: secondId,
            recurrenceId: recurrenceId, recurrenceIdZone: fixture.zone, event: patch, sendUpdates: "all")

        #expect(edited.id == secondId)
        #expect(store.recordedPuts().map(\.path) == [W.seriesPath], "the edit was not written into the series' resource")
        let rows = try await provider.listEvents(
            calendarId: W.calendarId,
            timeMin: try fixture.occurrence(1).addingTimeInterval(-60),
            timeMax: try fixture.occurrence(4).addingTimeInterval(-60),
            query: nil, singleEvents: true, maxResults: 250, orderBy: "startTime")
        #expect(rows.map(\.summary) == ["Standup", "Standup with guests", "Standup"])
        #expect(rows.compactMap(\.startDate) == starts)
    }

    @Test("this_only and this_and_following given an occurrence id address the series, as given its id")
    func scopedEditsByOccurrenceIdAddressTheSeries() async throws {
        let fixture = try W.make()
        let target = try fixture.occurrence(2)
        let recurrenceId = OccurrenceFixture.naive(target, fixture.zone)
        let secondId = try fixture.occurrenceId(2)

        let (store, http) = W.serve(fixture)
        defer { http.close() }
        var patch = GCalEventInput()
        patch.summary = "Standup, longer"
        _ = try await W.makeProvider(http).updateOccurrence(
            calendarId: W.calendarId, eventId: secondId,
            recurrenceId: recurrenceId, recurrenceIdZone: fixture.zone, event: patch, sendUpdates: "all")
        #expect(store.recordedPuts().map(\.path) == [W.seriesPath])

        let (splitStore, splitHTTP) = W.serve(fixture)
        defer { splitHTTP.close() }
        _ = try await W.makeProvider(splitHTTP).splitSeries(
            calendarId: W.calendarId, eventId: secondId,
            recurrenceId: recurrenceId, recurrenceIdZone: fixture.zone, patch: GCalEventInput(), sendUpdates: "all")
        let newPart = "/cal/\(GoogleCalendarProvider.deterministicSplitEventId(masterId: W.seriesPath, recurrenceId: recurrenceId)).ics"
        #expect(splitStore.recordedPuts().map(\.path) == [newPart, W.seriesPath],
                "the split by an occurrence id did not name its new part from the series, as the series id does")
    }

    // MARK: A moved occurrence, and a recurrence_id that names no occurrence

    @Test("a moved occurrence is listed at its new time with its own id, and reads back by that id")
    func movedOccurrenceIsListedWithItsOwnId() async throws {
        let fixture = try W.makeChanged()
        let (_, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let moved = try fixture.movedStart()
        let movedId = try fixture.occurrenceId(W.movedWeek)
        let expectedIds = try [0, 2, W.movedWeek, 4].map { try fixture.occurrenceId($0) }
        let expectedStarts = [try fixture.occurrence(0), try fixture.occurrence(2), moved, try fixture.occurrence(4)]

        let rows = try await Self.listWeeks(provider, fixture, through: 4)

        #expect(rows.compactMap(\.id) == expectedIds, "the listing does not give each occurrence, the moved one included, its own id")
        #expect(rows.compactMap(\.startDate) == expectedStarts, "the moved occurrence is not listed at its new time, or the removed one is listed")
        #expect(rows.filter { $0.id == movedId }.map(\.summary) == ["Standup (moved)"])
        let read = try await provider.getEvent(calendarId: W.calendarId, eventId: movedId)
        #expect(read.startDate == moved && read.summary == "Standup (moved)", "the moved occurrence's id does not read it back where it is")
    }

    @Test("this_only by a moved occurrence's id, with the start the listing showed, changes that occurrence where it is and adds none")
    func thisOnlyByMovedOccurrenceIdChangesItInPlace() async throws {
        let fixture = try W.makeChanged()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let moved = try fixture.movedStart()
        let movedId = try fixture.occurrenceId(W.movedWeek)
        let before = try await Self.listWeeks(provider, fixture, through: 4)
        var patch = GCalEventInput()
        patch.location = "Room 2"

        _ = try await provider.updateOccurrence(
            calendarId: W.calendarId, eventId: movedId,
            recurrenceId: OccurrenceFixture.naive(moved, fixture.zone), recurrenceIdZone: fixture.zone,
            event: patch, sendUpdates: "all")

        #expect(store.recordedPuts().map(\.path) == [W.seriesPath])
        let stored = try #require(store.storedICS(path: W.seriesPath))
        #expect(Self.lines(of: stored, named: "BEGIN:VEVENT").count == 2, "the edit added an occurrence to the series' resource")
        #expect(Self.lines(of: stored, named: "RECURRENCE-ID") == Self.lines(of: fixture.ics, named: "RECURRENCE-ID"),
                "the edit did not change the moved occurrence's own override")
        let after = try await Self.listWeeks(provider, fixture, through: 4)
        #expect(after.compactMap(\.id) == before.compactMap(\.id), "the edit added or removed an occurrence")
        #expect(after.compactMap(\.startDate) == before.compactMap(\.startDate), "the edit moved an occurrence")
        #expect(after.filter { $0.location == "Room 2" }.compactMap(\.id) == [movedId],
                "the edit did not land on the moved occurrence alone: \(after.map { [$0.id, $0.location] })")
    }

    @Test("this_and_following at a moved occurrence, by its id or the series id with the start the listing showed, is refused by name and nothing is written")
    func splitAtMovedOccurrenceIsRefused() async throws {
        // A split there would start at the occurrence's place in the series, and change the
        // occurrences between that place and where the occurrence now is: week 2's moved into
        // week 5 (weeks 3 and 4 between), and week 3's moved to the next day (none between).
        let movedFar = try W.makeMoved(week: 2, toWeek: 5)
        let movedNear = try W.makeChanged()
        let fixtures: [(label: String, fixture: W, week: Int, shown: Date)] = [
            ("week 2's moved into week 5", movedFar, 2, try movedFar.movedStart(toWeek: 5)),
            ("week 3's moved to the next day", movedNear, W.movedWeek, try movedNear.movedStart()),
        ]
        for entry in fixtures {
            for eventId in [try entry.fixture.occurrenceId(entry.week), W.seriesPath] {
                let (store, http) = W.serve(entry.fixture)
                defer { http.close() }
                let label = "\(entry.label), by \(eventId)"
                await #expect("this_and_following, \(label), was not refused by name") {
                    _ = try await W.makeProvider(http).splitSeries(
                        calendarId: W.calendarId, eventId: eventId,
                        recurrenceId: OccurrenceFixture.naive(entry.shown, entry.fixture.zone),
                        recurrenceIdZone: entry.fixture.zone, patch: GCalEventInput(), sendUpdates: "all")
                } throws: { error in
                    guard case CalendarProviderError.notSupported(let message) = error else { return false }
                    return message.contains("was moved from its place in the series") && message.contains("this_only")
                }
                let writes = http.recordedCalls().filter { $0.method != "GET" }.map { "\($0.method) \($0.url)" }
                #expect(writes.isEmpty, "\(label): the refused split sent a write: \(writes)")
                #expect(store.storedICS(path: W.seriesPath) == entry.fixture.ics, "\(label): the series is not on the server as it was")
            }
        }
    }

    /// How a series' DTSTART is written in `splitIsRefusedExactlyAtMovedOccurrencesInEveryFrame`.
    enum SeriesFrame: String, CaseIterable {
        case floating, utc, zoned, allDay

        /// The zone the series' wall times are in: a floating or all-day value is read in the
        /// device's, as the listing reads it.
        func zone() throws -> TimeZone {
            switch self {
            case .floating, .allDay: return .current
            case .utc: return .gmt
            case .zoned: return try #require(TimeZone(identifier: "America/New_York"))
            }
        }

        /// A DTSTART, RECURRENCE-ID or DTEND line for `date`.
        func line(_ name: String, _ date: Date) throws -> String {
            switch self {
            case .floating: return "\(name):\(OccurrenceFixture.wall(date, .current))"
            case .utc: return "\(name):\(OccurrenceFixture.utcValue(date))"
            case .zoned: return "\(name);TZID=America/New_York:\(OccurrenceFixture.wall(date, try zone()))"
            case .allDay: return "\(name);VALUE=DATE:\(OccurrenceFixture.dateValue(date, .current))"
            }
        }
    }

    /// Where `splitIsRefusedExactlyAtMovedOccurrencesInEveryFrame` puts week 2's occurrence.
    enum Move: String, CaseIterable {
        /// No change at all, and a change that kept its start (an override at its own slot).
        case none, retitledInPlace, sameDay, nextDay
    }

    @Test("this_and_following is refused exactly at a moved occurrence, in every series frame, from the device's zone or another, by either id",
          arguments: SeriesFrame.allCases, Move.allCases)
    func splitIsRefusedExactlyAtMovedOccurrencesInEveryFrame(_ frame: SeriesFrame, _ move: Move) async throws {
        // An all-day occurrence has no time of day to move within its day.
        if frame == .allDay, move == .sameDay { return }
        let zone = try frame.zone()
        let calendar = OccurrenceFixture.calendar(zone)
        let weekAgo = try #require(calendar.date(byAdding: .day, value: -7, to: Date()))
        let first = frame == .allDay
            ? calendar.startOfDay(for: weekAgo)
            : try #require(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: weekAgo))
        let slot = try #require(calendar.date(byAdding: .day, value: 14, to: first))
        let length: TimeInterval = frame == .allDay ? 24 * 60 * 60 : 30 * 60
        let shown: Date
        switch move {
        case .none, .retitledInPlace: shown = slot
        case .sameDay: shown = slot.addingTimeInterval(2 * 60 * 60)
        case .nextDay: shown = try #require(calendar.date(byAdding: .day, value: 1, to: slot)).addingTimeInterval(frame == .allDay ? 0 : 60 * 60)
        }
        var vevents = [[
            "UID:standup-1", "DTSTAMP:\(OccurrenceFixture.utcValue(first))",
            try frame.line("DTSTART", first), try frame.line("DTEND", first.addingTimeInterval(length)),
            "SUMMARY:Standup", "RRULE:FREQ=WEEKLY",
        ].joined(separator: "\n")]
        if move != .none {
            vevents.append([
                "UID:standup-1", try frame.line("RECURRENCE-ID", slot), "DTSTAMP:\(OccurrenceFixture.utcValue(first))",
                try frame.line("DTSTART", shown), try frame.line("DTEND", shown.addingTimeInterval(length)),
                "SUMMARY:Standup (changed)",
            ].joined(separator: "\n"))
        }
        let fixture = W(zone: zone, first: first, ics: OccurrenceFixture.ics(vevents))
        let occurrenceId = CalDAVOccurrences.OccurrenceId.make(
            seriesHref: W.seriesPath,
            key: frame == .allDay ? OccurrenceFixture.dateValue(slot, .current)
                : frame == .floating ? OccurrenceFixture.wall(slot, .current) : OccurrenceFixture.utcValue(slot))
        let moved = move == .sameDay || move == .nextDay
        // The model may name the occurrence in the device's zone or in another one.
        let device = TimeZone.current
        let other = try #require(TimeZone(identifier: device.identifier == "Asia/Tokyo" ? "Europe/Berlin" : "Asia/Tokyo"))

        for toolZone in [device, other] {
            for eventId in [occurrenceId, W.seriesPath] {
                let (store, http) = W.serve(fixture)
                defer { http.close() }
                let recurrenceId = frame == .allDay
                    ? OccurrenceFixture.isoDate(shown, .current)
                    : OccurrenceFixture.naive(shown, toolZone)
                let label = "\(frame) series, \(move), named in \(toolZone.identifier) by \(eventId)"
                let split: () async throws -> Void = {
                    _ = try await W.makeProvider(http).splitSeries(
                        calendarId: W.calendarId, eventId: eventId, recurrenceId: recurrenceId,
                        recurrenceIdZone: toolZone, patch: GCalEventInput(), sendUpdates: "all")
                }
                if moved {
                    await #expect("\(label): the split was not refused by name") {
                        try await split()
                    } throws: { error in
                        guard case CalendarProviderError.notSupported(let message) = error else { return false }
                        return message.contains("was moved from its place in the series")
                    }
                    let writes = http.recordedCalls().filter { $0.method != "GET" }.map { "\($0.method) \($0.url)" }
                    #expect(writes.isEmpty, "\(label): the refused split sent a write: \(writes)")
                    #expect(store.storedICS(path: W.seriesPath) == fixture.ics, "\(label): the series is not on the server as it was")
                } else {
                    do {
                        try await split()
                    } catch {
                        Issue.record("\(label): the split at an occurrence that was not moved failed: \(error)")
                    }
                    #expect(store.recordedPuts().count == 2, "\(label): the split did not write its new part and the capped series: \(store.recordedPuts().map(\.path))")
                }
            }
        }
    }

    @Test("a recurrence_id that names another occurrence than the event_id does is refused, one that names none is not found, and nothing is written")
    func recurrenceIdDisagreeingWithTheIdIsRefused() async throws {
        let fixture = try W.makeChanged()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let secondId = try fixture.occurrenceId(2)
        let movedId = try fixture.occurrenceId(W.movedWeek)
        let fourth = OccurrenceFixture.naive(try fixture.occurrence(4), fixture.zone)
        let besideMoved = OccurrenceFixture.naive(try fixture.movedStart().addingTimeInterval(60 * 60), fixture.zone)
        // A recurrence_id that names an occurrence is refused when the id names another; one
        // that names none is the authoritative absence (`isNotFound`).
        let cases: [(label: String, eventId: String, recurrenceId: String, namesNone: Bool)] = [
            ("week 2's id with week 4's start", secondId, fourth, false),
            ("the moved occurrence's id an hour after where it is", movedId, besideMoved, true),
        ]
        let disagreement = "names another occurrence than this event_id does"

        for entry in cases {
            await #expect("this_only, \(entry.label), was not refused") {
                _ = try await provider.updateOccurrence(
                    calendarId: W.calendarId, eventId: entry.eventId, recurrenceId: entry.recurrenceId,
                    recurrenceIdZone: fixture.zone, event: GCalEventInput(), sendUpdates: "all")
            } throws: { error in
                entry.namesNone ? Self.isNotFound(error) : Self.isRefusal(error, saying: disagreement)
            }
            await #expect("this_and_following, \(entry.label), was not refused") {
                _ = try await provider.splitSeries(
                    calendarId: W.calendarId, eventId: entry.eventId, recurrenceId: entry.recurrenceId,
                    recurrenceIdZone: fixture.zone, patch: GCalEventInput(), sendUpdates: "all")
            } throws: { error in
                entry.namesNone ? Self.isNotFound(error) : Self.isRefusal(error, saying: disagreement)
            }
        }
        #expect(store.recordedPuts().isEmpty, "a refused edit wrote: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: W.seriesPath) == fixture.ics, "the series is not on the server as it was")
    }

    @Test("the series id with a recurrence_id that names no occurrence now (a removed one, a time between, a moved one's old place) writes nothing, and with a moved one's new time edits that occurrence in place")
    func seriesIdWithNoOccurrenceAtTheTimeWritesNothing() async throws {
        let fixture = try W.makeChanged()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let naive = { (date: Date) in OccurrenceFixture.naive(date, fixture.zone) }
        let cases: [(label: String, recurrenceId: String)] = [
            ("the removed occurrence's time", naive(try fixture.occurrence(W.excludedWeek))),
            ("an hour after an occurrence", naive(try fixture.occurrence(2).addingTimeInterval(60 * 60))),
            ("the moved occurrence's old place", naive(try fixture.occurrence(W.movedWeek))),
        ]
        var patch = GCalEventInput()
        patch.location = "Room 2"

        for entry in cases {
            await #expect("this_only at \(entry.label) was not reported not found") {
                _ = try await provider.updateOccurrence(
                    calendarId: W.calendarId, eventId: W.seriesPath, recurrenceId: entry.recurrenceId,
                    recurrenceIdZone: fixture.zone, event: patch, sendUpdates: "all")
            } throws: { error in
                Self.isNotFound(error)
            }
            await #expect("this_and_following at \(entry.label) was not reported not found") {
                _ = try await provider.splitSeries(
                    calendarId: W.calendarId, eventId: W.seriesPath, recurrenceId: entry.recurrenceId,
                    recurrenceIdZone: fixture.zone, patch: patch, sendUpdates: "all")
            } throws: { error in
                Self.isNotFound(error)
            }
        }
        #expect(store.recordedPuts().isEmpty, "a recurrence_id that names no occurrence wrote: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: W.seriesPath) == fixture.ics, "the series is not on the server as it was")

        // The moved occurrence's new time names it, as the listing shows it: the edit changes its
        // own override in place and adds no occurrence (before the fix, a second override was
        // written at that time, an occurrence the series never had).
        _ = try await provider.updateOccurrence(
            calendarId: W.calendarId, eventId: W.seriesPath, recurrenceId: naive(try fixture.movedStart()),
            recurrenceIdZone: fixture.zone, event: patch, sendUpdates: "all")
        let stored = try #require(store.storedICS(path: W.seriesPath))
        #expect(store.recordedPuts().map(\.path) == [W.seriesPath], "the harness must be able to write, or the refusals prove nothing")
        #expect(Self.lines(of: stored, named: "BEGIN:VEVENT").count == 2, "the edit at the moved occurrence's new time added an occurrence")
        #expect(Self.lines(of: stored, named: "RECURRENCE-ID") == Self.lines(of: fixture.ics, named: "RECURRENCE-ID"),
                "the edit did not change the moved occurrence's own override")
        let rows = try await Self.listWeeks(provider, fixture, through: 4)
        let movedId = try fixture.occurrenceId(W.movedWeek)
        #expect(rows.filter { $0.location == "Room 2" }.compactMap(\.id) == [movedId], "the series id at the moved occurrence's new time did not edit it")
    }

    @Test("a recurrence_id given as a date alone that matches two occurrences that day is refused as ambiguous and nothing is written; a date with one occurrence resolves")
    func dateOnlyRecurrenceIdMatchingTwoOccurrencesIsRefused() async throws {
        // Week 3's occurrence moved onto week 2's day at 14:00: that day holds two occurrences.
        let base = try W.make()
        let zone = base.zone
        let wall = { (date: Date) in OccurrenceFixture.wall(date, zone) }
        let sharedDay = try base.occurrence(2)
        let calendar = OccurrenceFixture.calendar(zone)
        let moved = try #require(calendar.date(bySettingHour: 14, minute: 0, second: 0, of: sharedDay))
        let ics = OccurrenceFixture.ics([
            ([
                "UID:standup-1",
                "DTSTAMP:\(OccurrenceFixture.utcValue(base.first))",
                "DTSTART;TZID=America/New_York:\(wall(base.first))",
                "DTEND;TZID=America/New_York:\(wall(base.first.addingTimeInterval(30 * 60)))",
                "SUMMARY:Standup",
                "RRULE:FREQ=WEEKLY",
            ]).joined(separator: "\n"),
            """
            UID:standup-1
            RECURRENCE-ID;TZID=America/New_York:\(wall(try base.occurrence(3)))
            DTSTAMP:\(OccurrenceFixture.utcValue(base.first))
            DTSTART;TZID=America/New_York:\(wall(moved))
            DTEND;TZID=America/New_York:\(wall(moved.addingTimeInterval(30 * 60)))
            SUMMARY:Standup
            """,
        ])
        let fixture = OccurrenceWireFixture(zone: zone, first: base.first, ics: ics)
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let sharedDate = OccurrenceFixture.isoDate(sharedDay, zone)
        var patch = GCalEventInput()
        patch.location = "Room 2"

        await #expect("this_only at a date holding two occurrences was not refused as ambiguous") {
            _ = try await provider.updateOccurrence(
                calendarId: W.calendarId, eventId: W.seriesPath, recurrenceId: sharedDate,
                recurrenceIdZone: zone, event: patch, sendUpdates: "all")
        } throws: { error in
            Self.isRefusal(error, saying: "matched 2 occurrences")
        }
        await #expect("this_and_following at a date holding two occurrences was not refused as ambiguous") {
            _ = try await provider.splitSeries(
                calendarId: W.calendarId, eventId: W.seriesPath, recurrenceId: sharedDate,
                recurrenceIdZone: zone, patch: patch, sendUpdates: "all")
        } throws: { error in
            Self.isRefusal(error, saying: "matched 2 occurrences")
        }
        let writes = http.recordedCalls().filter { $0.method != "GET" && $0.method != "REPORT" }.map { "\($0.method) \($0.url)" }
        #expect(writes.isEmpty, "an ambiguous date sent: \(writes)")
        #expect(store.recordedPuts().isEmpty, "an ambiguous date wrote: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: W.seriesPath) == fixture.ics, "the series is not on the server as it was")

        // Control: week 4's date holds one occurrence, and the same edit by that date alone writes it.
        _ = try await provider.updateOccurrence(
            calendarId: W.calendarId, eventId: W.seriesPath,
            recurrenceId: OccurrenceFixture.isoDate(try base.occurrence(4), zone),
            recurrenceIdZone: zone, event: patch, sendUpdates: "all")
        #expect(store.recordedPuts().map(\.path) == [W.seriesPath], "a date with one occurrence did not resolve to it")
        let rows = try await Self.listWeeks(provider, fixture, through: 4)
        #expect(rows.filter { $0.location == "Room 2" }.compactMap(\.id) == [try fixture.occurrenceId(4)],
                "the edit by week 4's date did not change exactly week 4's occurrence")
    }

    // MARK: Where the series ends, cancelled occurrences, and what can't be addressed

    @Test("this_only after a COUNT series' last occurrence is not found and writes nothing; at its last occurrence it writes")
    func thisOnlyAfterTheSeriesEndWritesNothing() async throws {
        let base = try W.make()
        let fixture = OccurrenceWireFixture(
            zone: base.zone, first: base.first,
            ics: base.ics.replacingOccurrences(of: "RRULE:FREQ=WEEKLY", with: "RRULE:FREQ=WEEKLY;COUNT=3"))
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let afterEnd = OccurrenceFixture.naive(try fixture.occurrence(3), fixture.zone)
        var patch = GCalEventInput()
        patch.location = "Room 2"

        let afterEndId = try fixture.occurrenceId(3)
        for eventId in [W.seriesPath, afterEndId] {
            await #expect("this_only after the series' end by \(eventId) was not reported not found") {
                _ = try await provider.updateOccurrence(
                    calendarId: W.calendarId, eventId: eventId, recurrenceId: afterEnd,
                    recurrenceIdZone: fixture.zone, event: patch, sendUpdates: "all")
            } throws: { error in
                Self.isNotFound(error)
            }
        }
        #expect(store.recordedPuts().isEmpty, "an edit after the series' end wrote: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: W.seriesPath) == fixture.ics, "the series is not on the server as it was")

        // Control: the last occurrence is still one.
        _ = try await provider.updateOccurrence(
            calendarId: W.calendarId, eventId: W.seriesPath,
            recurrenceId: OccurrenceFixture.naive(try fixture.occurrence(2), fixture.zone),
            recurrenceIdZone: fixture.zone, event: patch, sendUpdates: "all")
        #expect(store.recordedPuts().map(\.path) == [W.seriesPath], "the harness must be able to write, or the refusals prove nothing")
    }

    @Test("this_only and this_and_following at a cancelled occurrence are not found, and nothing is written")
    func scopedEditAtACancelledOccurrenceWritesNothing() async throws {
        let base = try W.make()
        let cancelled = try base.occurrence(2)
        let wall = { (date: Date) in OccurrenceFixture.wall(date, base.zone) }
        let override = """
            BEGIN:VEVENT\r
            UID:standup-1\r
            RECURRENCE-ID;TZID=America/New_York:\(wall(cancelled))\r
            DTSTART;TZID=America/New_York:\(wall(cancelled))\r
            DTEND;TZID=America/New_York:\(wall(cancelled.addingTimeInterval(30 * 60)))\r
            STATUS:CANCELLED\r
            END:VEVENT\r
            END:VCALENDAR
            """
        let fixture = OccurrenceWireFixture(
            zone: base.zone, first: base.first, ics: base.ics.replacingOccurrences(of: "END:VCALENDAR", with: override))
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let recurrenceId = OccurrenceFixture.naive(cancelled, fixture.zone)
        var patch = GCalEventInput()
        patch.location = "Room 2"

        let cancelledId = try fixture.occurrenceId(2)
        for eventId in [W.seriesPath, cancelledId] {
            await #expect("this_only at the cancelled occurrence by \(eventId) was not reported not found") {
                _ = try await provider.updateOccurrence(
                    calendarId: W.calendarId, eventId: eventId, recurrenceId: recurrenceId,
                    recurrenceIdZone: fixture.zone, event: patch, sendUpdates: "all")
            } throws: { error in
                Self.isNotFound(error)
            }
            await #expect("this_and_following at the cancelled occurrence by \(eventId) was not reported not found") {
                _ = try await provider.splitSeries(
                    calendarId: W.calendarId, eventId: eventId, recurrenceId: recurrenceId,
                    recurrenceIdZone: fixture.zone, patch: patch, sendUpdates: "all")
            } throws: { error in
                Self.isNotFound(error)
            }
        }
        #expect(store.recordedPuts().isEmpty, "an edit at a cancelled occurrence wrote: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: W.seriesPath) == fixture.ics, "the series is not on the server as it was")
    }

    @Test("a series the expansion can't read (EXRULE) refuses this_only and this_and_following, and nothing is written")
    func scopedEditOfAnUnreadableSeriesWritesNothing() async throws {
        let base = try W.make()
        let fixture = OccurrenceWireFixture(
            zone: base.zone, first: base.first,
            ics: base.ics.replacingOccurrences(of: "RRULE:FREQ=WEEKLY", with: "RRULE:FREQ=WEEKLY\r\nEXRULE:FREQ=MONTHLY"))
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let recurrenceId = OccurrenceFixture.naive(try fixture.occurrence(2), fixture.zone)

        await #expect("this_only on an unreadable series was not refused") {
            _ = try await provider.updateOccurrence(
                calendarId: W.calendarId, eventId: W.seriesPath, recurrenceId: recurrenceId,
                recurrenceIdZone: fixture.zone, event: GCalEventInput(), sendUpdates: "all")
        } throws: { error in
            Self.isRefusal(error, saying: "can't work out the occurrences")
        }
        await #expect("this_and_following on an unreadable series was not refused") {
            _ = try await provider.splitSeries(
                calendarId: W.calendarId, eventId: W.seriesPath, recurrenceId: recurrenceId,
                recurrenceIdZone: fixture.zone, patch: GCalEventInput(), sendUpdates: "all")
        } throws: { error in
            Self.isRefusal(error, saying: "can't work out the occurrences")
        }
        #expect(store.recordedPuts().isEmpty, "a scoped edit of an unreadable series wrote: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: W.seriesPath) == fixture.ics, "the series is not on the server as it was")
    }

    // MARK: A resource that holds only changed occurrences

    @Test("this_only by the id of an occurrence in a resource that holds only changed occurrences changes that occurrence on the server, and says so")
    func thisOnlyInAnOverrideOnlyResourceChangesThatOccurrence() async throws {
        let fixture = try W.make()
        let path = "/cal/invite.ics"
        for form in W.overrideOnlyForms {
            let invite = try fixture.overrideOnly(form: form)
            let (store, http) = W.serve(fixture)
            defer { http.close() }
            store.seed(path: path, ics: invite.ics)
            let provider = W.makeProvider(http)
            let eventId = CalDAVOccurrences.OccurrenceId.make(seriesHref: path, key: invite.key)
            // The recurrence_id the listing gives it: its start_iso, where it is now.
            let recurrenceId = form == "date"
                ? OccurrenceFixture.isoDate(invite.start, fixture.zone)
                : OccurrenceFixture.naive(invite.start, fixture.zone)
            var patch = GCalEventInput()
            patch.summary = "Planning (agenda)"

            let edited = try await provider.updateOccurrence(
                calendarId: W.calendarId, eventId: eventId, recurrenceId: recurrenceId,
                recurrenceIdZone: fixture.zone, event: patch, sendUpdates: "all")

            #expect(edited.id == eventId && edited.summary == "Planning (agenda)", "\(form): the result does not report the change: \(edited.id ?? "nil") \(edited.summary ?? "nil")")
            #expect(store.recordedPuts().map(\.path) == [path], "\(form): the edit was not written into the resource")
            let stored = try #require(store.storedICS(path: path))
            #expect(Self.lines(of: stored, named: "BEGIN:VEVENT").count == 1, "\(form): the edit added a VEVENT")
            for name in ["RECURRENCE-ID", "DTSTART", "DTEND", "ORGANIZER", "ATTENDEE"] {
                #expect(Self.lines(of: stored, named: name) == Self.lines(of: invite.ics, named: name),
                        "\(form): the edit changed the occurrence's \(name): \(Self.lines(of: stored, named: name))")
            }
            #expect(Self.lines(of: stored, named: "SUMMARY") == ["SUMMARY:Planning (agenda)"], "\(form): the occurrence's title was not changed on the server")
            let read = try await provider.getEvent(calendarId: W.calendarId, eventId: eventId)
            #expect(read.summary == "Planning (agenda)", "\(form): the occurrence does not read back changed")
        }
    }

    @Test("a resource that holds only changed occurrences refuses this_only by its own id, any split and a read of its own id, as its series not being in this calendar, and nothing is written")
    func overrideOnlyResourceRefusesWhatItCannotAddress() async throws {
        let fixture = try W.make()
        let path = "/cal/invite.ics"
        let invite = try fixture.overrideOnly(form: "tzid")
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        store.seed(path: path, ics: invite.ics)
        let provider = W.makeProvider(http)
        let occurrenceId = CalDAVOccurrences.OccurrenceId.make(seriesHref: path, key: invite.key)
        let recurrenceId = OccurrenceFixture.naive(invite.start, fixture.zone)

        await #expect("this_only by the resource's own id was not refused") {
            _ = try await provider.updateOccurrence(
                calendarId: W.calendarId, eventId: path, recurrenceId: recurrenceId,
                recurrenceIdZone: fixture.zone, event: GCalEventInput(), sendUpdates: "all")
        } throws: { error in
            Self.isRefusal(error, saying: "is not in this calendar")
        }
        for eventId in [path, occurrenceId] {
            await #expect("this_and_following by \(eventId) was not refused") {
                _ = try await provider.splitSeries(
                    calendarId: W.calendarId, eventId: eventId, recurrenceId: recurrenceId,
                    recurrenceIdZone: fixture.zone, patch: GCalEventInput(), sendUpdates: "all")
            } throws: { error in
                Self.isRefusal(error, saying: "is not in this calendar")
            }
        }
        // Read by its own id, as an edit of every occurrence and a split read their series: the
        // final answer that the series is not in this calendar, every time (#720).
        for attempt in 1...2 {
            await #expect("read \(attempt) of the resource's own id was not refused as holding no series") {
                _ = try await provider.getEvent(calendarId: W.calendarId, eventId: path)
            } throws: { error in
                // The neutral case, which each caller words for what it was asked (#694).
                guard case CalendarProviderError.seriesNotInThisCalendar = error else { return false }
                return Self.isRefusal(error, saying: "is not in this calendar")
            }
        }
        #expect(store.recordedPuts().isEmpty, "a refused edit wrote: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: path) == invite.ics, "the resource is not on the server as it was")
    }

    @Test("a read of a resource with no VEVENT at all stays a parse error, never the refusal that its series is not in this calendar")
    func resourceWithNoEventStaysAParseError() async throws {
        let fixture = try W.make()
        let path = "/cal/empty.ics"
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        store.seed(path: path, ics: OccurrenceFixture.ics([]))
        let provider = W.makeProvider(http)
        await #expect("a resource with no VEVENT was not read as a parse error") {
            _ = try await provider.getEvent(calendarId: W.calendarId, eventId: path)
        } throws: { error in
            if case CalDAVError.parseError = error { return true }
            return false
        }
    }

    @Test("this_only and this_and_following on an event that does not repeat are refused, and nothing is written")
    func scopedEditOfAnEventThatDoesNotRepeatWritesNothing() async throws {
        let fixture = try W.make()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let start = try fixture.occurrence(2)
        let path = "/cal/dentist.ics"
        let ics = OccurrenceFixture.ics(["""
            UID:dentist-1
            DTSTAMP:\(OccurrenceFixture.utcValue(start))
            DTSTART;TZID=America/New_York:\(OccurrenceFixture.wall(start, fixture.zone))
            DTEND;TZID=America/New_York:\(OccurrenceFixture.wall(start.addingTimeInterval(60 * 60), fixture.zone))
            SUMMARY:Dentist
            """])
        store.seed(path: path, ics: ics)
        let recurrenceId = OccurrenceFixture.naive(start, fixture.zone)
        var patch = GCalEventInput()
        patch.location = "Room 2"

        await #expect("this_only on an event that does not repeat was not refused") {
            _ = try await provider.updateOccurrence(
                calendarId: W.calendarId, eventId: path, recurrenceId: recurrenceId,
                recurrenceIdZone: fixture.zone, event: patch, sendUpdates: "all")
        } throws: { error in
            Self.isRefusal(error, saying: "does not repeat")
        }
        await #expect("this_and_following on an event that does not repeat was not refused") {
            _ = try await provider.splitSeries(
                calendarId: W.calendarId, eventId: path, recurrenceId: recurrenceId,
                recurrenceIdZone: fixture.zone, patch: patch, sendUpdates: "all")
        } throws: { error in
            if case CalendarProviderError.notSupported = error { return true }
            return false
        }
        #expect(store.recordedPuts().isEmpty, "a scoped edit of an event that does not repeat wrote: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: path) == ics, "the event is not on the server as it was")
    }

    @Test("an id with a damaged occurrence key is refused before any request")
    func damagedOccurrenceIdSendsNothing() async throws {
        let fixture = try W.make()
        let (_, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let damaged = "\(W.seriesPath)#next-week"

        await #expect(throws: CalendarProviderError.self) {
            _ = try await provider.getEvent(calendarId: W.calendarId, eventId: damaged)
        }
        await #expect(throws: CalendarProviderError.self) {
            try await provider.deleteEvent(calendarId: W.calendarId, eventId: damaged, sendUpdates: "all")
        }
        #expect(http.recordedCalls().isEmpty, "a request went out for a damaged id: \(http.servedCallSequence())")
    }
}
