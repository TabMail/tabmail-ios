/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Queued calendar operations with arguments the builder refuses
//
// The calendar queue replays an operation's stored tool arguments through
// `CalendarToolHelpers.buildGCalEventInput` on every drain. An operation whose recurrence the
// builder refuses can never succeed, so the drain must retire it with a reason (the agent and the
// card are told) instead of retrying it on every drain, and nothing may reach the provider.
// The tools refuse such arguments before queueing; these operations stand for rows stored by an
// earlier build.

@Suite("Calendar queue: recurrence argument validation", .serialized, .processGlobalState)
struct CalendarQueueArgumentValidationTests {

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

    @Test("a queued create or edit whose recurrence count is not a whole number of 1 or more is retired with a reason and never sent",
          arguments: [CalendarOperationType.create, .edit], [JSONValue.double(2.5), .double(1e300)])
    func refusedRecurrenceIsRetired(type: CalendarOperationType, count: JSONValue) async throws {
        let accountId = "cal-arg-\(type.rawValue)"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        // `all_day` is stated so the edit path never needs to read the event first.
        let args: [String: JSONValue] = [
            "title": .string("Standup"),
            "all_day": .bool(false),
            "recurrence": .dictionary(["freq": .string("weekly"), "count": count]),
        ]
        let op = PendingCalendarOperation(
            operationType: type, accountId: accountId,
            eventId: type == .edit ? "evt-1" : nil,
            calendarId: "primary", arguments: args)
        try await pool.write { db in try op.insert(db) }

        async let outcome = AccountManager.shared.awaitCalendarOpOutcome(opId: op.id, timeoutSeconds: 5.0)
        // Let the awaiter register before the drain can signal it.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await AccountManager.shared.drainCalendarQueue()
        let result = await outcome

        if case .permanentFailure(let reason) = result {
            #expect(reason.contains("recurrence.count must be a whole number of 1 or more"), "reason: \(reason)")
        } else {
            #expect(Bool(false), "the drain reported \(result) for an operation whose recurrence the builder refuses")
        }

        let created = await mock.createdEvents
        let updated = await mock.updatedEvents
        #expect(created.isEmpty && updated.isEmpty,
                "nothing should reach the provider: \(created.count) create(s), \(updated.count) update(s)")

        // The row must leave the claimable states, or every later drain retries it.
        let remaining = try await pool.read { db in try PendingCalendarOperation.fetchAll(db) }
        #expect(!remaining.contains { $0.status == PendingStatus.queued.rawValue })
        #expect(!remaining.contains { $0.status == PendingStatus.inFlight.rawValue })
    }
}
