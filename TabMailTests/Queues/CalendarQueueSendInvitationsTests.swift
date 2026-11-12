/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - The assistant's send_invitations decides whether guests are notified
//
// The calendar tools' `send_invitations` "Defaults to false". A queued create, edit or delete asks
// the provider to notify guests (`sendUpdates` "all") only when the tool call said
// `send_invitations: true`; when it said false, or nothing, nobody is notified ("none"). This is the
// Thunderbird add-on's rule. The choice is read from the arguments stored on the queued row, so it
// is the one the call made when it was queued.

@Suite("Calendar queue: send_invitations decides who is notified", .serialized, .processGlobalState)
struct CalendarQueueSendInvitationsTests {

    /// A one-off, timed event the edit names. Dates are relative to today.
    private static func oneOff() -> GCalEvent {
        let start = Date().addingTimeInterval(14 * 86_400)
        let fmt = ISO8601DateFormatter()
        return GCalEvent(
            id: "evt-1", summary: "Standup", location: nil, description: nil,
            start: GCalDateTime(dateTime: fmt.string(from: start), date: nil, timeZone: "UTC"),
            end: GCalDateTime(dateTime: fmt.string(from: start.addingTimeInterval(1_800)), date: nil, timeZone: "UTC"),
            attendees: [GCalAttendee(email: "guest@example.com", displayName: nil, responseStatus: "needsAction", organizer: nil, self: nil)],
            organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil)
    }

    /// The three things a call can say, and the notification each must give.
    static let cases: [(given: JSONValue?, expected: String)] = [
        (nil, "none"), (.bool(false), "none"), (.bool(true), "all"),
    ]

    private func makeTestDB(accountId: String) throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "cal@example.com", displayName: "Cal", provider: .gmail)
            acc.id = accountId
            try acc.insert(db)
        }
        return (pool, dir, previous)
    }

    /// Queues one operation, drains it, and returns the `sendUpdates` the provider was asked for.
    private func drain(type: CalendarOperationType, sendInvitations: JSONValue?, index: Int) async throws -> [String] {
        let accountId = "cal-sendinv-\(type.rawValue)-\(index)"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        var args: [String: JSONValue]
        switch type {
        case .create:
            let start = Date().addingTimeInterval(14 * 86_400)
            let fmt = ISO8601DateFormatter()
            args = [
                "title": .string("Standup"), "all_day": .bool(false),
                "start_iso": .string(fmt.string(from: start)),
                "end_iso": .string(fmt.string(from: start.addingTimeInterval(1_800))),
                "attendees": .array([.string("guest@example.com")]),
            ]
        case .edit:
            await mock.setGetEventResult(Self.oneOff())
            args = ["title": .string("Standup moved"), "all_day": .bool(false)]
        case .delete:
            args = ["event_id": .string("evt-1")]
        }
        if let sendInvitations { args["send_invitations"] = sendInvitations }

        let op = PendingCalendarOperation(
            operationType: type, accountId: accountId,
            eventId: type == .create ? PendingCalendarOperation.generateGoogleEventId(from: UUID().uuidString) : "evt-1",
            calendarId: "primary", arguments: args)
        try await pool.write { db in try op.insert(db) }

        async let outcome = AccountManager.shared.awaitCalendarOpOutcome(opId: op.id, timeoutSeconds: 5.0)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await AccountManager.shared.drainCalendarQueue()
        // What the provider was asked is the property here, not how the drain reports the outcome.
        _ = await outcome

        switch type {
        case .create: return await mock.createdEvents.map(\.sendUpdates)
        case .edit: return await mock.updatedEvents.map(\.sendUpdates)
        case .delete: return await mock.deletedEvents.map(\.sendUpdates)
        }
    }

    @Test("a queued create notifies guests only when send_invitations is true", arguments: Array(cases.enumerated()))
    func create(entry: (offset: Int, element: (given: JSONValue?, expected: String))) async throws {
        let sent = try await drain(type: .create, sendInvitations: entry.element.given, index: entry.offset)
        #expect(sent == [entry.element.expected], "send_invitations \(String(describing: entry.element.given)) sent \(sent)")
    }

    @Test("a queued edit notifies guests only when send_invitations is true", arguments: Array(cases.enumerated()))
    func edit(entry: (offset: Int, element: (given: JSONValue?, expected: String))) async throws {
        let sent = try await drain(type: .edit, sendInvitations: entry.element.given, index: entry.offset)
        #expect(sent == [entry.element.expected], "send_invitations \(String(describing: entry.element.given)) sent \(sent)")
    }

    @Test("a queued delete notifies guests only when send_invitations is true", arguments: Array(cases.enumerated()))
    func delete(entry: (offset: Int, element: (given: JSONValue?, expected: String))) async throws {
        let sent = try await drain(type: .delete, sendInvitations: entry.element.given, index: entry.offset)
        #expect(sent == [entry.element.expected], "send_invitations \(String(describing: entry.element.given)) sent \(sent)")
    }
}
