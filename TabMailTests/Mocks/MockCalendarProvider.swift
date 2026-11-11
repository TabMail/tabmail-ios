/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
@testable import TabMail

/// Configurable mock CalendarProvider for testing services that depend on calendar operations.
/// Records all method calls for assertion. Can be configured to throw errors or return specific results.
actor MockCalendarProvider: CalendarProvider {
    // MARK: - Rule comparison

    /// What `editResetsChangedOccurrences` answers, and the edits it was asked about.
    nonisolated let resetsAnswer = Mutex(false)
    nonisolated let resetsAsked = Mutex<[GCalEventInput]>([])

    nonisolated func editResetsChangedOccurrences(_ event: GCalEvent, edit: GCalEventInput) -> Bool {
        resetsAsked.withLock { $0.append(edit) }
        return resetsAnswer.withLock { $0 }
    }

    // MARK: - Call Recording

    var callLog: [String] = []

    // MARK: - Configurable Results

    var listCalendarsResult: [GCalCalendar] = []
    var listCalendarsThrows: Error?
    var primaryCalendarIdResult: String = "primary"
    var primaryCalendarIdThrows: Error?
    var listEventsResult: [GCalEvent] = []
    var listEventsThrows: Error?
    var getEventResult: GCalEvent?
    var getEventThrows: Error?
    var createEventResult: GCalEvent?
    var createEventThrows: Error?
    var updateEventResult: GCalEvent?
    var updateEventThrows: Error?
    var deleteEventThrows: Error?
    private var deleteEventHook: (@Sendable () async -> Void)?

    func setDeleteEventHook(_ hook: @escaping @Sendable () async -> Void) {
        deleteEventHook = hook
    }

    // MARK: - Parameter Tracking

    var createdEvents: [(calendarId: String, event: GCalEventInput, sendUpdates: String)] = []
    var updatedEvents: [(calendarId: String, eventId: String, event: GCalEventInput, sendUpdates: String)] = []
    var deletedEvents: [(calendarId: String, eventId: String, sendUpdates: String)] = []
    var updatedOccurrences: [(calendarId: String, eventId: String, recurrenceId: String, recurrenceIdZone: TimeZone, event: GCalEventInput, sendUpdates: String)] = []
    var splitSeriesCalls: [(calendarId: String, eventId: String, recurrenceId: String, recurrenceIdZone: TimeZone, patch: GCalEventInput, sendUpdates: String)] = []
    var updateOccurrenceResult: GCalEvent?
    /// What `occurrenceStartDay` returns; nil gives `recurrenceId`'s own date, the protocol default.
    var occurrenceStartDayResult: String?
    var occurrenceStartDayThrows: Error?
    var updateOccurrenceThrows: Error?
    var splitSeriesResult: GCalEvent?
    var splitSeriesThrows: Error?

    // MARK: - CalendarProvider Protocol

    func listCalendars() async throws -> [GCalCalendar] {
        callLog.append("listCalendars")
        if let error = listCalendarsThrows { throw error }
        return listCalendarsResult
    }

    func primaryCalendarId() async throws -> String {
        callLog.append("primaryCalendarId")
        if let error = primaryCalendarIdThrows { throw error }
        return primaryCalendarIdResult
    }

    func listEvents(calendarId: String, timeMin: Date?, timeMax: Date?, query: String?, singleEvents: Bool, maxResults: Int, orderBy: String) async throws -> [GCalEvent] {
        callLog.append("listEvents(calendarId:\(calendarId))")
        if let error = listEventsThrows { throw error }
        return listEventsResult
    }

    func getEvent(calendarId: String, eventId: String) async throws -> GCalEvent {
        callLog.append("getEvent(calendarId:\(calendarId),eventId:\(eventId))")
        if let error = getEventThrows { throw error }
        guard let result = getEventResult else {
            throw NSError(domain: "MockCalendarProvider", code: 404, userInfo: [NSLocalizedDescriptionKey: "Event not found"])
        }
        return result
    }

    func createEvent(calendarId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
        callLog.append("createEvent(calendarId:\(calendarId),sendUpdates:\(sendUpdates))")
        createdEvents.append((calendarId: calendarId, event: event, sendUpdates: sendUpdates))
        if let error = createEventThrows { throw error }
        guard let result = createEventResult else {
            throw NSError(domain: "MockCalendarProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "No mock result configured"])
        }
        return result
    }

    func updateEvent(calendarId: String, eventId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
        callLog.append("updateEvent(calendarId:\(calendarId),eventId:\(eventId),sendUpdates:\(sendUpdates))")
        updatedEvents.append((calendarId: calendarId, eventId: eventId, event: event, sendUpdates: sendUpdates))
        if let error = updateEventThrows { throw error }
        guard let result = updateEventResult else {
            throw NSError(domain: "MockCalendarProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "No mock result configured"])
        }
        return result
    }

    func deleteEvent(calendarId: String, eventId: String, sendUpdates: String) async throws {
        callLog.append("deleteEvent(calendarId:\(calendarId),eventId:\(eventId),sendUpdates:\(sendUpdates))")
        deletedEvents.append((calendarId: calendarId, eventId: eventId, sendUpdates: sendUpdates))
        if let deleteEventHook { await deleteEventHook() }
        if let error = deleteEventThrows { throw error }
    }

    func setOccurrenceStartDayResult(_ day: String?) { occurrenceStartDayResult = day }
    func setOccurrenceStartDayThrows(_ error: Error?) { occurrenceStartDayThrows = error }

    func occurrenceStartDay(calendarId: String, eventId: String, recurrenceId: String, recurrenceIdZone: TimeZone) async throws -> String? {
        callLog.append("occurrenceStartDay(calendarId:\(calendarId),eventId:\(eventId),recurrenceId:\(recurrenceId),recurrenceIdZone:\(recurrenceIdZone.identifier))")
        if let error = occurrenceStartDayThrows { throw error }
        return occurrenceStartDayResult ?? String(recurrenceId.prefix(10))
    }

    func updateOccurrence(calendarId: String, eventId: String, recurrenceId: String, recurrenceIdZone: TimeZone, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
        callLog.append("updateOccurrence(calendarId:\(calendarId),eventId:\(eventId),recurrenceId:\(recurrenceId),recurrenceIdZone:\(recurrenceIdZone.identifier),sendUpdates:\(sendUpdates))")
        updatedOccurrences.append((calendarId: calendarId, eventId: eventId, recurrenceId: recurrenceId, recurrenceIdZone: recurrenceIdZone, event: event, sendUpdates: sendUpdates))
        if let error = updateOccurrenceThrows { throw error }
        guard let result = updateOccurrenceResult else {
            throw NSError(domain: "MockCalendarProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "No mock result configured"])
        }
        return result
    }

    func splitSeries(calendarId: String, eventId: String, recurrenceId: String, recurrenceIdZone: TimeZone, patch: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
        callLog.append("splitSeries(calendarId:\(calendarId),eventId:\(eventId),recurrenceId:\(recurrenceId),recurrenceIdZone:\(recurrenceIdZone.identifier),sendUpdates:\(sendUpdates))")
        splitSeriesCalls.append((calendarId: calendarId, eventId: eventId, recurrenceId: recurrenceId, recurrenceIdZone: recurrenceIdZone, patch: patch, sendUpdates: sendUpdates))
        if let error = splitSeriesThrows { throw error }
        guard let result = splitSeriesResult else {
            throw NSError(domain: "MockCalendarProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "No mock result configured"])
        }
        return result
    }

    // MARK: - Test Helpers

    /// Reset all recorded state.
    func reset() {
        callLog.removeAll()
        createdEvents.removeAll()
        updatedEvents.removeAll()
        deletedEvents.removeAll()
    }
}
