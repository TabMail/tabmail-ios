/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - R13-U3 — a 409 is not proof, and only proof may retire an intention
//
// INVARIANT (system property): **the durable `PendingCalendarOperation` row
// survives every create outcome except one the provider has POSITIVELY told us
// already landed.** The row IS the user's intention; deleting it is the exit,
// and never-drop clause 2 admits an exit only on a provider-AUTHORITATIVE
// stale/no-op result. *"We could not determine the answer"* is not that.
//
// What this pins, per provider:
//   * EXCHANGE — retires on NOTHING at 409. Microsoft documents no 409 for a
//     repeated `transactionId`; the `event` resource defines it as a value "for
//     the server to AVOID REDUNDANT POST operations in case of client retries",
//     so a deduped retry receives the ORIGINAL success response and a 409 is
//     evidence against the dedup reading, not for it. Graph's observed
//     calendar-POST 409s are store-level save conflicts (`ConcurrentItemSave`,
//     `IrresolvableConflict`) that say nothing about whether the item exists.
//   * GOOGLE — retires ONLY on reason `"duplicate"` ("The requested identifier
//     already exists"), and only when we supplied the id. Google's other
//     documented 409, reason `"conflict"`, is an `events.batch` operational
//     conflict and is retryable by Google's own guidance.
//     (developers.google.com/workspace/calendar/api/guides/errors)
//
// ⚠️ THE ASSERTION IS ON THE DURABLE ROW, NOT ON A LOG LINE OR A RETURN VALUE.
// A wire count alone is defeatable and so is an outcome enum: what decides
// whether the user's create eventually happens is whether the row is still there
// for the next drain. Every test below reads it back out of the database.
//
// ⚠️ TWO-SIDED. `aSuccessfulCreateStillRetiresTheOp` is the control: without it
// "the row survives" is satisfiable by a drain that never deletes anything, and
// the four absences would be vacuous (`MIS-030`).

@Suite("R13-U3 — calendar create conflict dispositions", .serialized, .processGlobalState)
struct CalendarConflictDispositionTests {

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

    /// Insert one `.create` against a mock whose `createEvent` behaves as
    /// configured, drain once, and report how many durable rows are left.
    ///
    /// The row is inserted DIRECTLY rather than through `queueCalendarOperation`,
    /// which fires its own `Task { await drainCalendarQueue() }`: that background
    /// drain wins the `!isDrainingCalendar` guard, the test's explicit drain
    /// returns immediately ("Skipped drain — already draining"), and the durable
    /// row is read while the real drain is still mid-flight. Same shape and same
    /// reason as `CalendarQueueOutcomeTests.unexecutableOpIsNotReportedAsSuccess`.
    private func drainOneCreate(
        accountId: String,
        pregenEventId: String?,
        configure: (MockCalendarProvider) async -> Void
    ) async throws -> (remaining: Int, createAttempts: Int, outcome: CalendarOpOutcome) {
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await configure(mock)
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: accountId,
            eventId: pregenEventId,
            calendarId: "primary",
            arguments: ["summary": .string("Quarterly review")]
        )
        try await pool.write { db in try op.insert(db) }

        async let outcome = AccountManager.shared.awaitCalendarOpOutcome(opId: op.id, timeoutSeconds: 5.0)
        // Let the awaiter register before the drain can signal it.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await AccountManager.shared.drainCalendarQueue()
        let result = await outcome

        let remaining = try await pool.read { db in try PendingCalendarOperation.fetchCount(db) }
        let attempts = await mock.createdEvents.count
        return (remaining, attempts, result)
    }

    private func isStillQueued(_ o: CalendarOpOutcome) -> Bool {
        if case .stillQueued = o { return true }
        return false
    }

    private func isSuccess(_ o: CalendarOpOutcome) -> Bool {
        if case .success = o { return true }
        return false
    }

    // MARK: Exchange

    @Test("An Exchange 409 leaves the create queued — Graph documents no 409 for a repeated transactionId, so it is not proof the event exists")
    func exchangeConflictKeepsTheIntentionQueued() async throws {
        let result = try await drainOneCreate(
            accountId: "cal-r13-u3-exchange-409", pregenEventId: "pre-ex-409"
        ) { mock in
            await mock.setCreateEventThrows(ExchangeCalendarError.httpError(409, nil))
        }
        #expect(result.createAttempts == 1, "setup: the drain never reached the provider")
        #expect(isStillQueued(result.outcome),
                "the agent was told the create had settled — got \(result.outcome)")
        #expect(result.remaining == 1,
                "the 409 was converted to success and the durable row was deleted — if the write never landed, the user's create is gone with no queued work to make it happen and nothing to sync it back. The retry is duplicate-safe because `createEventJSON` stamps `transactionId` from the durable op id.")
    }

    // MARK: Google

    /// Google's documented duplicate-identifier 409 payload shape.
    private func googleErrorBody(reason: String, message: String) -> Data {
        Data("""
        {"error":{"errors":[{"domain":"global","reason":"\(reason)","message":"\(message)"}],"code":409,"message":"\(message)"}}
        """.utf8)
    }

    @Test("A Google 409 that positively says the identifier already exists retires the op — the event is there")
    func googleDuplicateIdentifierRetiresTheOp() async throws {
        let result = try await drainOneCreate(
            accountId: "cal-r13-u3-google-dup", pregenEventId: "pre-goog-dup"
        ) { mock in
            await mock.setCreateEventThrows(GoogleCalendarError.httpError(
                409, googleErrorBody(reason: "duplicate", message: "The requested identifier already exists.")))
        }
        #expect(result.createAttempts == 1, "setup: the drain never reached the provider")
        #expect(isSuccess(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 0,
                "Google told us OUR client-supplied id is already on the calendar; requeueing that forever is the wedge, the mirror image of the drop this suite guards")
    }

    @Test("A Google 409 that is a BATCH conflict leaves the create queued — the same status code, a different fact")
    func googleBatchConflictKeepsTheIntentionQueued() async throws {
        let result = try await drainOneCreate(
            accountId: "cal-r13-u3-google-conflict", pregenEventId: "pre-goog-conflict"
        ) { mock in
            await mock.setCreateEventThrows(GoogleCalendarError.httpError(
                409, googleErrorBody(reason: "conflict", message: "Conflict")))
        }
        #expect(isStillQueued(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 1,
                "reason `conflict` is an events.batch operational conflict which Google's own guidance says to retry; it is not a statement that the event exists")
    }

    @Test("A Google 409 with no body leaves the create queued — an unreadable answer is not an authoritative one")
    func googleBodylessConflictKeepsTheIntentionQueued() async throws {
        let result = try await drainOneCreate(
            accountId: "cal-r13-u3-google-nobody", pregenEventId: "pre-goog-nobody"
        ) { mock in
            await mock.setCreateEventThrows(GoogleCalendarError.httpError(409, nil))
        }
        #expect(isStillQueued(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 1,
                "the discriminator must fail CLOSED: an unparseable body means we could not determine the answer, which clause 2 makes retryable, and the retry is duplicate-safe because Google rejects a second insert of the same client-supplied id")
    }

    @Test("A Google duplicate-identifier 409 for an op that supplied NO id leaves the create queued — 'the identifier exists' is not about our event")
    func googleDuplicateWithoutAPregeneratedIdKeepsTheIntentionQueued() async throws {
        let result = try await drainOneCreate(
            accountId: "cal-r13-u3-google-noid", pregenEventId: nil
        ) { mock in
            await mock.setCreateEventThrows(GoogleCalendarError.httpError(
                409, googleErrorBody(reason: "duplicate", message: "The requested identifier already exists.")))
        }
        #expect(isStillQueued(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 1,
                "with no client-supplied id the server minted its own, so a duplicate-identifier conflict cannot be evidence that OUR create landed")
    }

    // MARK: Control

    @Test("CONTROL — an ordinary successful create still retires the op, so the four survivals above are not 'the drain never deletes'")
    func aSuccessfulCreateStillRetiresTheOp() async throws {
        let result = try await drainOneCreate(
            accountId: "cal-r13-u3-control", pregenEventId: "pre-ok"
        ) { mock in
            await mock.setCreateEventResult(GCalEvent(
                id: "server-assigned-id", summary: "Quarterly review", location: nil, description: nil,
                start: nil, end: nil, attendees: nil, organizer: nil, recurrence: nil,
                transparency: nil, status: "confirmed", htmlLink: nil, created: nil, updated: nil))
        }
        #expect(result.createAttempts == 1)
        #expect(isSuccess(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 0,
                "the fixture must be able to retire an op at all, or every 'the row survives' assertion above is vacuous (MIS-030)")
    }
}

extension MockCalendarProvider {
    func setCreateEventThrows(_ e: Error) { createEventThrows = e }
    func setCreateEventResult(_ ev: GCalEvent) { createEventResult = ev }
}
