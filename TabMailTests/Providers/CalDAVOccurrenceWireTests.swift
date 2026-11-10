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
// Dates are worked out from `Date()`; none is written as a literal.

/// One weekly series in New York time on a fake CalDAV server.
struct OccurrenceWireFixture {
    static let calendarHome = URL(string: "https://caldav.example.com/cal/")!
    static let calendarId = "/cal/"
    static let seriesPath = "/cal/standup.ics"

    let zone: TimeZone
    /// The series' first occurrence, 09:00 New York time a week ago.
    let first: Date
    let ics: String

    static func make() throws -> OccurrenceWireFixture {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let calendar = OccurrenceFixture.calendar(zone)
        let weekAgo = try #require(calendar.date(byAdding: .day, value: -7, to: Date()))
        let first = try #require(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: weekAgo))
        let wall = { (date: Date) in OccurrenceFixture.wall(date, zone) }
        let ics = OccurrenceFixture.ics(["""
            UID:standup-1
            DTSTAMP:\(OccurrenceFixture.utcValue(first))
            DTSTART;TZID=America/New_York:\(wall(first))
            DTEND;TZID=America/New_York:\(wall(first.addingTimeInterval(30 * 60)))
            SUMMARY:Standup
            RRULE:FREQ=WEEKLY
            """])
        return OccurrenceWireFixture(zone: zone, first: first, ics: ics)
    }

    /// The `weeks`-th occurrence (0 = the first), at 09:00 New York time.
    func occurrence(_ weeks: Int) throws -> Date {
        try #require(OccurrenceFixture.calendar(zone).date(byAdding: .day, value: 7 * weeks, to: first))
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
            return reason.contains("not supported yet") && reason.contains("series id")
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

    @Test("an edit of the whole series (edit_scope all) by an occurrence id changes the series and every occurrence")
    func allEditByOccurrenceIdChangesTheSeries() async throws {
        let fixture = try W.make()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        let provider = W.makeProvider(http)
        var patch = GCalEventInput()
        patch.summary = "Standup with guests"
        let secondId = try fixture.occurrenceId(2)
        let weeks = [0, 1, 2, 3]
        let starts = try weeks.map { try fixture.occurrence($0) }

        // `updateEvent` is what the calendar queue runs for edit_scope "all".
        _ = try await provider.updateEvent(
            calendarId: W.calendarId, eventId: secondId, event: patch, sendUpdates: "all")

        #expect(store.recordedPuts().map(\.path) == [W.seriesPath], "the edit was not written into the series' resource")
        let rows = try await provider.listEvents(
            calendarId: W.calendarId,
            timeMin: fixture.first.addingTimeInterval(-60),
            timeMax: try fixture.occurrence(4).addingTimeInterval(-60),
            query: nil, singleEvents: true, maxResults: 250, orderBy: "startTime")
        let expectedTitles: [String?] = weeks.map { _ in "Standup with guests" }
        #expect(rows.map(\.summary) == expectedTitles, "an edit of the whole series left occurrences unchanged")
        #expect(rows.compactMap(\.startDate) == starts, "the series' occurrences moved")
        let series = try await provider.getEvent(calendarId: W.calendarId, eventId: W.seriesPath)
        #expect(series.summary == "Standup with guests")
        let stored = try #require(store.storedICS(path: W.seriesPath))
        #expect(!stored.contains("RECURRENCE-ID"), "the edit of the series was written as one occurrence's change")
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

    @Test("a repeat rule can't be changed through one occurrence's id, and nothing is written")
    func ruleChangeByOccurrenceIdIsRefused() async throws {
        let fixture = try W.make()
        let (store, http) = W.serve(fixture)
        defer { http.close() }
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=DAILY"]
        let secondId = try fixture.occurrenceId(2)

        await #expect {
            _ = try await W.makeProvider(http).updateEvent(
                calendarId: W.calendarId, eventId: secondId, event: patch, sendUpdates: "all")
        } throws: { error in
            if case CalendarProviderError.notSupported = error { return true }
            return false
        }
        #expect(store.recordedPuts().isEmpty)
        #expect(store.storedICS(path: W.seriesPath) == fixture.ics)
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
