/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail

/// `splitSeries` as the tests that are not about its `SplitRecord` call it: the record is
/// handed to nobody. Tests about the record pass their own (`SplitRecordBox`).
extension CalendarProvider {
    func splitSeries(
        calendarId: String, eventId: String, recurrenceId: String, recurrenceIdZone: TimeZone,
        patch: GCalEventInput, sendUpdates: String
    ) async throws -> GCalEvent {
        try await splitSeries(
            calendarId: calendarId, eventId: eventId, recurrenceId: recurrenceId,
            recurrenceIdZone: recurrenceIdZone, patch: patch, sendUpdates: sendUpdates, record: { _ in })
    }
}

extension GoogleCalendarProvider {
    func splitSeries(
        calendarId: String = "primary", eventId: String, recurrenceId: String, recurrenceIdZone: TimeZone,
        patch: GCalEventInput, sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        try await splitSeries(
            calendarId: calendarId, eventId: eventId, recurrenceId: recurrenceId,
            recurrenceIdZone: recurrenceIdZone, patch: patch, sendUpdates: sendUpdates, record: { _ in })
    }
}

extension ExchangeCalendarProvider {
    func splitSeries(
        calendarId: String = "primary", eventId: String, recurrenceId: String, recurrenceIdZone: TimeZone,
        patch: GCalEventInput, sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        try await splitSeries(
            calendarId: calendarId, eventId: eventId, recurrenceId: recurrenceId,
            recurrenceIdZone: recurrenceIdZone, patch: patch, sendUpdates: sendUpdates, record: { _ in })
    }
}

/// The records a split handed over, in order, with an optional failure to throw instead.
final class SplitRecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [SplitRecord] = []
    private var failure: Error?

    init(failWith failure: Error? = nil) {
        self.failure = failure
    }

    var records: [SplitRecord] {
        lock.withLock { kept }
    }

    var recorder: SplitRecorder {
        { [self] record in
            try lock.withLock {
                if let failure { throw failure }
                kept.append(record)
            }
        }
    }
}
