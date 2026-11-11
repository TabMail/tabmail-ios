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
// gone out as a DELETE of the series. The delete by an occurrence id is refused with no
// request sent, and the series stays on the server exactly as it was; reads and edits
// by an occurrence id address that occurrence inside its series' resource.
//
// A second property for the edits: one occurrence's edit or a split writes only at an
// occurrence the series has (the one an occurrence id names, or one a series id's
// `recurrence_id` names), and an edit of the whole series through an occurrence id sets
// nothing that places the series in time. Anything else is refused with nothing written,
// asserted on what the fake server holds afterwards and on what a listing then shows.
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

    /// Where `makeChanged()` moved week `movedWeek`'s occurrence: the next day, 10:00 New York time.
    func movedStart() throws -> Date {
        let calendar = OccurrenceFixture.calendar(zone)
        let slot = try occurrence(Self.movedWeek)
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: slot))
        return try #require(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: nextDay))
    }

    func occurrenceId(_ weeks: Int) throws -> String {
        CalDAVOccurrences.OccurrenceId.make(
            seriesHref: Self.seriesPath, key: OccurrenceFixture.utcValue(try occurrence(weeks)))
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

    /// A provider refusal (`notSupported`) whose reason contains `phrase`.
    private static func isRefusal(_ error: any Error, saying phrase: String) -> Bool {
        guard case CalendarProviderError.notSupported(let reason) = error else { return false }
        return reason.contains(phrase)
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

    @Test("deleting by an occurrence id is refused, sends no DELETE, and leaves the series on the server unchanged")
    func deleteByOccurrenceIdSendsNoDelete() async throws {
        let fixture = try W.make()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let oneDay = try fixture.occurrenceId(2)

        await #expect {
            try await W.makeProvider(http).deleteEvent(
                calendarId: W.calendarId, eventId: oneDay, sendUpdates: "all")
        } throws: { error in
            guard case CalendarProviderError.notSupported(let reason) = error else { return false }
            return reason.contains("not supported yet") && reason.contains("nothing was deleted")
        }

        #expect(Self.deletes(http).isEmpty, "a DELETE reached the server for one occurrence: \(Self.deletes(http))")
        #expect(store.storedICS(path: W.seriesPath) == fixture.ics, "the series is not on the server as it was")
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

    @Test("an edit of the whole series (edit_scope all) by an occurrence id sets its title, location, description and busy status, and moves nothing")
    func allEditByOccurrenceIdSetsFieldsThatPlaceNothingInTime() async throws {
        let fixture = try W.makeChanged()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        var patch = GCalEventInput()
        patch.summary = "Team standup"
        patch.location = "Room 2"
        patch.description = "Bring notes"
        patch.transparency = "transparent"
        let secondId = try fixture.occurrenceId(2)
        let movedId = try fixture.occurrenceId(W.movedWeek)
        let before = try await Self.listWeeks(provider, fixture, through: 4)

        // `updateEvent` is what the calendar queue runs for edit_scope "all".
        _ = try await provider.updateEvent(
            calendarId: W.calendarId, eventId: secondId, event: patch, sendUpdates: "all")

        #expect(store.recordedPuts().map(\.path) == [W.seriesPath], "the edit was not written into the series' resource")
        let after = try await Self.listWeeks(provider, fixture, through: 4)
        #expect(after.compactMap(\.id) == before.compactMap(\.id), "the edit added, removed or renamed an occurrence")
        #expect(after.compactMap(\.startDate) == before.compactMap(\.startDate), "the edit moved an occurrence")
        #expect(after.compactMap(\.endDate) == before.compactMap(\.endDate), "the edit changed an occurrence's end")
        let series = after.filter { $0.id != movedId }
        #expect(series.count == 3, "setup: weeks 0, 2 and 4 are the series' own occurrences in range, got \(series.count)")
        #expect(series.allSatisfy {
            $0.summary == "Team standup" && $0.location == "Room 2" && $0.description == "Bring notes" && $0.transparency == "transparent"
        }, "the series' occurrences do not show the edit: \(series.map { [$0.summary, $0.location, $0.description, $0.transparency] })")
        let stored = try #require(store.storedICS(path: W.seriesPath))
        for name in ["DTSTART", "DTEND", "RRULE", "EXDATE", "RECURRENCE-ID"] {
            #expect(Self.lines(of: stored, named: name) == Self.lines(of: fixture.ics, named: name),
                    "the edit changed the series' \(name): \(Self.lines(of: stored, named: name))")
        }
    }

    @Test("an edit of the whole series by an occurrence id that sets a start, an end, guests or a rule is refused before any request")
    func allEditByOccurrenceIdCannotPlaceTheSeries() async throws {
        let fixture = try W.makeChanged()
        let shown = try fixture.occurrence(2)
        let hour: TimeInterval = 60 * 60
        var start = GCalEventInput()
        start.startDateTime = shown.addingTimeInterval(hour).iso8601String()
        start.startTimeZone = "America/New_York"
        var end = GCalEventInput()
        end.endDateTime = shown.addingTimeInterval(45 * 60).iso8601String()
        end.endTimeZone = "America/New_York"
        var allDay = GCalEventInput()
        allDay.startDate = OccurrenceFixture.isoDate(shown, fixture.zone)
        var guests = GCalEventInput()
        guests.attendees = [(email: "guest@example.com", name: nil)]
        var rule = GCalEventInput()
        rule.recurrence = ["RRULE:FREQ=DAILY"]
        var titleAndStart = start
        titleAndStart.summary = "Standup, an hour later"
        let patches: [(label: String, patch: GCalEventInput)] = [
            ("a start", start), ("an end", end), ("an all-day date", allDay), ("guests", guests),
            ("a repeat rule", rule), ("a title with a start", titleAndStart),
        ]
        let secondId = try fixture.occurrenceId(2)

        for entry in patches {
            let (store, http) = W.serve(fixture)
            defer { http.close() }
            await #expect("an edit by an occurrence id setting \(entry.label) was not refused") {
                _ = try await W.makeProvider(http).updateEvent(
                    calendarId: W.calendarId, eventId: secondId, event: entry.patch, sendUpdates: "all")
            } throws: { error in
                Self.isRefusal(error, saying: "nothing was changed")
            }
            #expect(http.recordedCalls().isEmpty, "\(entry.label): a request went out: \(http.servedCallSequence())")
            #expect(store.storedICS(path: W.seriesPath) == fixture.ics, "\(entry.label): the series is not on the server as it was")
        }
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

    @Test("this_and_following from a moved occurrence's id, with the start the listing showed, keeps the later occurrences' day and time")
    func splitFromMovedOccurrenceKeepsLaterTimes() async throws {
        let fixture = try W.makeChanged()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let moved = try fixture.movedStart()
        let movedId = try fixture.occurrenceId(W.movedWeek)
        let slot = OccurrenceFixture.naive(try fixture.occurrence(W.movedWeek), fixture.zone)
        let expectedStarts = [try fixture.occurrence(0), try fixture.occurrence(2), moved,
                              try fixture.occurrence(4), try fixture.occurrence(5), try fixture.occurrence(6)]

        _ = try await provider.splitSeries(
            calendarId: W.calendarId, eventId: movedId,
            recurrenceId: OccurrenceFixture.naive(moved, fixture.zone), recurrenceIdZone: fixture.zone,
            patch: GCalEventInput(), sendUpdates: "all")

        let newPart = "/cal/\(GoogleCalendarProvider.deterministicSplitEventId(masterId: W.seriesPath, recurrenceId: slot)).ics"
        #expect(store.recordedPuts().map(\.path) == [newPart, W.seriesPath],
                "the split did not start its new part at the moved occurrence's place in the series")
        let rows = try await Self.listWeeks(provider, fixture, through: 6)
        #expect(rows.compactMap(\.startDate) == expectedStarts,
                "after the split the occurrences are not where they were: \(rows.map { $0.start?.dateTime ?? "nil" })")
        let calendar = OccurrenceFixture.calendar(fixture.zone)
        let weekday = calendar.component(.weekday, from: fixture.first)
        let unmoved = rows.filter { $0.startDate != moved }
        #expect(unmoved.allSatisfy { row in
            guard let start = row.startDate else { return false }
            let wall = calendar.dateComponents([.weekday, .hour, .minute], from: start)
            return wall.weekday == weekday && wall.hour == 9 && wall.minute == 0
        }, "an occurrence after the split left its weekday at 09:00")
        #expect(rows.filter { $0.startDate == moved }.map(\.summary) == ["Standup (moved)"], "the moved occurrence is not listed once, as it was")
    }

    @Test("a recurrence_id that names another occurrence than the event_id does is refused, and nothing is written")
    func recurrenceIdDisagreeingWithTheIdIsRefused() async throws {
        let fixture = try W.makeChanged()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let secondId = try fixture.occurrenceId(2)
        let movedId = try fixture.occurrenceId(W.movedWeek)
        let fourth = OccurrenceFixture.naive(try fixture.occurrence(4), fixture.zone)
        let besideMoved = OccurrenceFixture.naive(try fixture.movedStart().addingTimeInterval(60 * 60), fixture.zone)
        let cases: [(label: String, eventId: String, recurrenceId: String)] = [
            ("week 2's id with week 4's start", secondId, fourth),
            ("the moved occurrence's id an hour after where it is", movedId, besideMoved),
        ]

        for entry in cases {
            await #expect("this_only, \(entry.label), was not refused") {
                _ = try await provider.updateOccurrence(
                    calendarId: W.calendarId, eventId: entry.eventId, recurrenceId: entry.recurrenceId,
                    recurrenceIdZone: fixture.zone, event: GCalEventInput(), sendUpdates: "all")
            } throws: { error in
                Self.isRefusal(error, saying: "is not an occurrence of this repeating event")
            }
            await #expect("this_and_following, \(entry.label), was not refused") {
                _ = try await provider.splitSeries(
                    calendarId: W.calendarId, eventId: entry.eventId, recurrenceId: entry.recurrenceId,
                    recurrenceIdZone: fixture.zone, patch: GCalEventInput(), sendUpdates: "all")
            } throws: { error in
                Self.isRefusal(error, saying: "is not an occurrence of this repeating event")
            }
        }
        #expect(store.recordedPuts().isEmpty, "a refused edit wrote: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: W.seriesPath) == fixture.ics, "the series is not on the server as it was")
    }

    @Test("the series id with a recurrence_id that names no occurrence (a moved one's new time, a removed one, a time between) writes nothing")
    func seriesIdWithNoOccurrenceAtTheTimeWritesNothing() async throws {
        let fixture = try W.makeChanged()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        let naive = { (date: Date) in OccurrenceFixture.naive(date, fixture.zone) }
        let cases: [(label: String, recurrenceId: String)] = [
            ("the moved occurrence's new time", naive(try fixture.movedStart())),
            ("the removed occurrence's time", naive(try fixture.occurrence(W.excludedWeek))),
            ("an hour after an occurrence", naive(try fixture.occurrence(2).addingTimeInterval(60 * 60))),
        ]
        var patch = GCalEventInput()
        patch.location = "Room 2"

        for entry in cases {
            await #expect("this_only at \(entry.label) was not refused") {
                _ = try await provider.updateOccurrence(
                    calendarId: W.calendarId, eventId: W.seriesPath, recurrenceId: entry.recurrenceId,
                    recurrenceIdZone: fixture.zone, event: patch, sendUpdates: "all")
            } throws: { error in
                Self.isRefusal(error, saying: "use the event_id listed for it")
            }
            await #expect("this_and_following at \(entry.label) was not refused") {
                _ = try await provider.splitSeries(
                    calendarId: W.calendarId, eventId: W.seriesPath, recurrenceId: entry.recurrenceId,
                    recurrenceIdZone: fixture.zone, patch: patch, sendUpdates: "all")
            } throws: { error in
                Self.isRefusal(error, saying: "use the event_id listed for it")
            }
        }
        #expect(store.recordedPuts().isEmpty, "a recurrence_id that names no occurrence wrote: \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: W.seriesPath) == fixture.ics, "the series is not on the server as it was")

        // Control: the series id with the moved occurrence's place in the series edits it.
        let slot = naive(try fixture.occurrence(W.movedWeek))
        _ = try await provider.updateOccurrence(
            calendarId: W.calendarId, eventId: W.seriesPath, recurrenceId: slot,
            recurrenceIdZone: fixture.zone, event: patch, sendUpdates: "all")
        let stored = try #require(store.storedICS(path: W.seriesPath))
        #expect(store.recordedPuts().map(\.path) == [W.seriesPath], "the harness must be able to write, or the refusals prove nothing")
        #expect(Self.lines(of: stored, named: "BEGIN:VEVENT").count == 2, "the edit at the moved occurrence's place added an occurrence")
        let rows = try await Self.listWeeks(provider, fixture, through: 4)
        let movedId = try fixture.occurrenceId(W.movedWeek)
        #expect(rows.filter { $0.location == "Room 2" }.compactMap(\.id) == [movedId], "the series id at the moved occurrence's place did not edit it")
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
