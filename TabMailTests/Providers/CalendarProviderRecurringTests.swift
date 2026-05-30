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
