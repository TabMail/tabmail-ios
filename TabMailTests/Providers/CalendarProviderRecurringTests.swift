/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// Tests for the CalendarProvider protocol's new recurring-event methods
// (updateOccurrence + splitSeries). Verifies:
//   - MockCalendarProvider correctly records calls + arguments for both methods.
//   - The default protocol extension (used by Demo, and any provider that
//     hasn't been updated) throws CalendarProviderError.notSupported with a
//     human-readable message — exactly what the queue's error classifier keys
//     off to surface a clean "not supported on this provider" error to the LLM.

@Suite("CalendarProvider — recurring-event method dispatch via mock")
struct MockCalendarProviderRecurringTests {

    @Test("updateOccurrence is recorded with all arguments")
    func updateOccurrenceRecorded() async throws {
        let mock = MockCalendarProvider()
        await mock.setUpdateOccurrenceResult(GCalEvent(
            id: "occ-1", summary: "Override", location: nil, description: nil,
            start: nil, end: nil, attendees: nil, organizer: nil,
            recurrence: nil, transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil
        ))
        var input = GCalEventInput()
        input.summary = "Override title"
        _ = try await mock.updateOccurrence(
            calendarId: "cal-1", eventId: "evt-1",
            recurrenceId: "2026-05-20T17:00:00",
            recurrenceIdZone: .current,
            event: input, sendUpdates: "all"
        )
        let calls = await mock.updatedOccurrences
        #expect(calls.count == 1)
        guard calls.count == 1 else { return }
        #expect(calls[0].calendarId == "cal-1")
        #expect(calls[0].eventId == "evt-1")
        #expect(calls[0].recurrenceId == "2026-05-20T17:00:00")
        #expect(calls[0].sendUpdates == "all")
        #expect(calls[0].event.summary == "Override title")
    }

    @Test("splitSeries is recorded with all arguments including the patch")
    func splitSeriesRecorded() async throws {
        let mock = MockCalendarProvider()
        await mock.setSplitSeriesResult(GCalEvent(
            id: "new-series", summary: "New series", location: nil, description: nil,
            start: nil, end: nil, attendees: nil, organizer: nil,
            recurrence: ["RRULE:FREQ=WEEKLY"], transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil
        ))
        var patch = GCalEventInput()
        patch.summary = "New series title"
        patch.location = "Room 5"
        _ = try await mock.splitSeries(
            calendarId: "cal-1", eventId: "evt-1",
            recurrenceId: "2026-05-20T17:00:00",
            recurrenceIdZone: .current,
            patch: patch, sendUpdates: "all"
        )
        let calls = await mock.splitSeriesCalls
        #expect(calls.count == 1)
        guard calls.count == 1 else { return }
        #expect(calls[0].calendarId == "cal-1")
        #expect(calls[0].eventId == "evt-1")
        #expect(calls[0].recurrenceId == "2026-05-20T17:00:00")
        #expect(calls[0].sendUpdates == "all")
        #expect(calls[0].patch.summary == "New series title")
        #expect(calls[0].patch.location == "Room 5")
    }

    @Test("updateOccurrence rethrows configured error")
    func updateOccurrenceThrows() async {
        let mock = MockCalendarProvider()
        await mock.setUpdateOccurrenceThrows(NSError(domain: "test", code: 1))
        do {
            _ = try await mock.updateOccurrence(
                calendarId: "c", eventId: "e", recurrenceId: "r",
                recurrenceIdZone: .current,
                event: GCalEventInput(), sendUpdates: "all"
            )
            Issue.record("expected throw")
        } catch {
            // expected
        }
    }
}

@Suite("CalendarProvider — default extension throws notSupported")
struct CalendarProviderDefaultExtensionTests {

    /// A bare-minimum CalendarProvider conformance that only implements the
    /// required methods. updateOccurrence + splitSeries fall through to the
    /// protocol's default extension, which must throw notSupported.
    private actor MinimalProvider: CalendarProvider {
        nonisolated func editResetsChangedOccurrences(_ event: GCalEvent, edit: GCalEventInput) -> Bool { false }
        func listCalendars() async throws -> [GCalCalendar] { [] }
        func primaryCalendarId() async throws -> String { "primary" }
        func listEvents(calendarId: String, timeMin: Date?, timeMax: Date?, query: String?, singleEvents: Bool, maxResults: Int, orderBy: String) async throws -> [GCalEvent] { [] }
        func getEvent(calendarId: String, eventId: String) async throws -> GCalEvent {
            throw GoogleCalendarError.eventNotFound
        }
        func createEvent(calendarId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
            throw GoogleCalendarError.eventNotFound
        }
        func updateEvent(calendarId: String, eventId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
            throw GoogleCalendarError.eventNotFound
        }
        func deleteEvent(calendarId: String, eventId: String, sendUpdates: String) async throws {}
    }

    @Test("updateOccurrence default impl throws CalendarProviderError.notSupported with a message")
    func updateOccurrenceDefaultThrows() async {
        let p = MinimalProvider()
        do {
            _ = try await p.updateOccurrence(
                calendarId: "c", eventId: "e", recurrenceId: "r",
                recurrenceIdZone: .current,
                event: GCalEventInput(), sendUpdates: "all"
            )
            Issue.record("expected throw")
        } catch CalendarProviderError.notSupported(let msg) {
            #expect(!msg.isEmpty)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("splitSeries default impl throws CalendarProviderError.notSupported with a message")
    func splitSeriesDefaultThrows() async {
        let p = MinimalProvider()
        do {
            _ = try await p.splitSeries(
                calendarId: "c", eventId: "e", recurrenceId: "r",
                recurrenceIdZone: .current,
                patch: GCalEventInput(), sendUpdates: "all"
            )
            Issue.record("expected throw")
        } catch CalendarProviderError.notSupported(let msg) {
            #expect(!msg.isEmpty)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - MockCalendarProvider test helpers

extension MockCalendarProvider {
    func setUpdateOccurrenceResult(_ ev: GCalEvent) { updateOccurrenceResult = ev }
    func setUpdateOccurrenceThrows(_ e: Error) { updateOccurrenceThrows = e }
    func setSplitSeriesResult(_ ev: GCalEvent) { splitSeriesResult = ev }
    func setSplitSeriesThrows(_ e: Error) { splitSeriesThrows = e }
}

/// Whether a whole-series edit resets the occurrences changed one by one, which Google
/// and CalDAV answer by its rule, as their edits write it: Google replaces the series'
/// whole `recurrence`, CalDAV only its RRULE line. Google also answers yes for a moved start
/// or end, pinned against its fake calendar here; Outlook's answer (its rule, start or end)
/// is pinned against its write in `ExchangeCalendarEditPreservationTests`.
@Suite("CalendarProvider.editResetsChangedOccurrences on Google and CalDAV")
struct CalendarProviderRuleChangedTests {
    private static let stored = ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6", "EXDATE;VALUE=DATE:20991231"]

    private static func series() -> GCalEvent {
        GCalEvent(
            id: "evt-r", summary: "Weekly sync", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2099-01-05T10:00:00Z", date: nil, timeZone: "UTC"),
            end: GCalDateTime(dateTime: "2099-01-05T11:00:00Z", date: nil, timeZone: "UTC"),
            attendees: nil, organizer: nil, recurrence: stored,
            transparency: nil, status: "confirmed", htmlLink: nil, created: nil, updated: nil
        )
    }

    private func caldav() -> CalDAVProvider {
        CalDAVProvider(
            client: CalDAVClient(username: "user@example.com", password: "pw", session: URLSession(configuration: .ephemeral)),
            calendarHomeURL: URL(string: "https://caldav.example.com/calendars/")!,
            serverBaseURL: URL(string: "https://caldav.example.com/")!)
    }

    enum Edit: String, CaseIterable, CustomTestStringConvertible {
        case sameSpelledOtherwise, sameRuleWithoutExdate, newCount, newInterval, newKind, noRule
        var testDescription: String { rawValue }

        var recurrence: [String] {
            switch self {
            case .sameSpelledOtherwise: ["rrule:count=6;byday=WE,MO;INTERVAL=1;FREQ=WEEKLY", "EXDATE;VALUE=DATE:20991231"]
            case .sameRuleWithoutExdate: ["RRULE:FREQ=WEEKLY;BYDAY=WE,MO;COUNT=6"]
            case .newCount: ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=9", "EXDATE;VALUE=DATE:20991231"]
            case .newInterval: ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6;INTERVAL=2", "EXDATE;VALUE=DATE:20991231"]
            case .newKind: ["RRULE:FREQ=DAILY;COUNT=6", "EXDATE;VALUE=DATE:20991231"]
            case .noRule: ["EXDATE;VALUE=DATE:20991231"]
            }
        }

        /// Google writes the whole array: any line it does not hold changes the series.
        var googleChanges: Bool { self != .sameSpelledOtherwise }
        /// CalDAV writes only the RRULE line, and none when the edit gives none.
        var caldavChanges: Bool { [.newCount, .newInterval, .newKind].contains(self) }
    }

    @Test("Google: an edit changes the rule unless it gives the series' recurrence lines, however spelled", arguments: Edit.allCases)
    func google(_ edit: Edit) {
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" })
        var input = GCalEventInput()
        input.recurrence = edit.recurrence
        #expect(provider.editResetsChangedOccurrences(Self.series(), edit: input) == edit.googleChanges, "\(edit)")
    }

    @Test("CalDAV: an edit that moves the series' time and gives no rule answers no reset")
    func timeMoveWithNoRule() {
        var input = GCalEventInput()
        input.startDateTime = "2099-01-05T12:00:00Z"
        input.startTimeZone = "UTC"
        #expect(!caldav().editResetsChangedOccurrences(Self.series(), edit: input))
    }

    enum GoogleTimeEdit: String, CaseIterable, CustomTestStringConvertible {
        case laterStart, rename, ownTimesSpelledOtherwise, sameInstantOtherZone, endOnly, allDayMovedDate, allDayOwnDate
        var testDescription: String { rawValue }

        /// The series is all-day for the all-day cases, from 2099-01-05 for one day; timed otherwise,
        /// 09:00 to 09:30 UTC.
        var allDay: Bool { [.allDayMovedDate, .allDayOwnDate].contains(self) }

        var input: GCalEventInput {
            var input = GCalEventInput()
            switch self {
            case .laterStart:
                input.startDateTime = "2099-01-05T13:00:00Z"
                input.startTimeZone = "UTC"
            case .rename:
                input.summary = "Standup (renamed)"
            case .ownTimesSpelledOtherwise:
                input.startDateTime = "2099-01-05T09:00:00+00:00"
                input.startTimeZone = "UTC"
                input.endDateTime = "2099-01-05T09:30:00+00:00"
                input.endTimeZone = "UTC"
            case .sameInstantOtherZone:
                input.startDateTime = "2099-01-05T18:00:00+09:00"
                input.startTimeZone = "Asia/Tokyo"
                input.endDateTime = "2099-01-05T18:30:00+09:00"
                input.endTimeZone = "Asia/Tokyo"
            case .endOnly:
                input.startDateTime = "2099-01-05T09:00:00Z"
                input.startTimeZone = "UTC"
                input.endDateTime = "2099-01-05T10:00:00Z"
                input.endTimeZone = "UTC"
            case .allDayMovedDate:
                input.startDate = "2099-01-06"
                input.endDate = "2099-01-07"
            case .allDayOwnDate:
                input.startDate = "2099-01-05"
                input.endDate = "2099-01-06"
            }
            return input
        }

        /// A new start or end, or the same instant in another zone, resets the series.
        var resets: Bool { [.laterStart, .sameInstantOtherZone, .endOnly, .allDayMovedDate].contains(self) }
    }

    /// Google resets a series' changed occurrences when a whole-series edit moves its start or
    /// end, even with its rule unchanged (measured), and its edit writes the series' start and
    /// end every time. The card's answer is whether the fake calendar, which resets as Google
    /// did, reset the series, and a moved occurrence is gone exactly then.
    @Test("Google: the card's answer to whether a whole-series edit resets changed occurrences is the write's",
          arguments: GoogleTimeEdit.allCases)
    func googleTimeEdit(_ edit: GoogleTimeEdit) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var master = edit.allDay
            ? FakeGoogleCalendar.allDay(id: "ser-g", start: "2099-01-05", end: "2099-01-06")
            : FakeGoogleCalendar.timed(id: "ser-g", day: "2099-01-05")
        master["recurrence"] = ["RRULE:FREQ=WEEKLY;COUNT=5"]
        // The occurrence of 2099-01-12, moved a day or an hour later.
        var moved = edit.allDay
            ? FakeGoogleCalendar.allDay(id: "ser-g_20990112T090000Z", start: "2099-01-13", end: "2099-01-14")
            : FakeGoogleCalendar.timed(id: "ser-g_20990112T090000Z", day: "2099-01-12")
        if !edit.allDay {
            moved["start"] = ["dateTime": "2099-01-12T10:00:00Z", "timeZone": "UTC"]
            moved["end"] = ["dateTime": "2099-01-12T10:30:00Z", "timeZone": "UTC"]
        }
        moved["recurringEventId"] = "ser-g"
        let calendar = FakeGoogleCalendar([master, moved])
        calendar.install(on: http)
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        let read = try await provider.getEvent(eventId: "ser-g")

        let answer = provider.editResetsChangedOccurrences(read, edit: edit.input)
        _ = try await provider.updateEvent(eventId: "ser-g", event: edit.input)

        let reset = calendar.seriesResets > 0
        #expect(calendar.writes == ["PATCH ser-g"], "\(edit): writes \(calendar.writes)")
        #expect(answer == reset, "\(edit): the card says \(answer ? "a reset" : "no reset"), the write \(reset ? "reset" : "did not reset") the series")
        #expect(answer == edit.resets, "\(edit): the card says \(answer ? "a reset" : "no reset")")
        #expect((calendar.event("ser-g_20990112T090000Z") == nil) == edit.resets, "\(edit): the moved occurrence was \(reset ? "dropped" : "kept")")
    }

    @Test("CalDAV: an edit changes the rule when its RRULE differs from the series' own, however spelled", arguments: Edit.allCases)
    func calDAV(_ edit: Edit) {
        var input = GCalEventInput()
        input.recurrence = edit.recurrence
        #expect(caldav().editResetsChangedOccurrences(Self.series(), edit: input) == edit.caldavChanges, "\(edit)")
    }
}
