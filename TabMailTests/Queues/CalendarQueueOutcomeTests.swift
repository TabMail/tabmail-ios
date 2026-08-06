/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

// MARK: - R12-T6 / R12-T8 — what the calendar drain tells the agent
//
// Two invariants, both about the OUTCOME channel rather than about any
// particular classifier:
//
//  * **T6 — a bounded wait must actually end.** `awaitCalendarOpOutcome` is
//    documented to resolve "or after `timeoutSeconds` elapses", and all three
//    calendar tools pass 10 s. Nothing above them bounds a hung tool
//    (`ToolRegistry.execute` has no timeout), so a wait that never returns hangs
//    the user's chat turn outright. The primary trigger is ORDINARY — offline:
//    `drainCalendarQueue` returns on `guard NetworkMonitor.checkConnected()`
//    before any `signalCalendarOpOutcome`.
//  * **T8 — work that never happened is never reported as success.** A normal
//    return from `executeCalendarOperation` IS the drain's success path, so the
//    guards that logged "dropping" were signalling `.success` and the tool told
//    the LLM "Calendar event deleted successfully."

@Suite("Calendar queue — outcome delivery", .serialized, .processGlobalState)
struct CalendarQueueOutcomeTests {

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

    // MARK: - T6

    @Test("a calendar-op wait that nobody ever signals still RETURNS — the timeout is deliverable, not merely computed")
    func unsignalledWaitReturnsInsteadOfHanging() async {
        // Nothing is ever queued under this id, so no drain can signal it. That
        // is the offline shape: `drainCalendarQueue` returns before any
        // `signalCalendarOpOutcome` and the tool is left waiting.
        //
        // ⚠️ Deliberately run DETACHED and polled rather than awaited inline.
        // The pre-fix failure mode is a HANG, not a wrong value — `withTaskGroup`
        // awaits its remaining children at scope exit and `withCheckedContinuation`
        // is not cancellation-aware, so an inline `await` would hang the whole
        // test process instead of failing. Polling turns "never returns" into a
        // clean, attributable failure.
        let outcome = Mutex<CalendarOpOutcome?>(nil)
        let waiter = Task.detached {
            let result = await AccountManager.shared.awaitCalendarOpOutcome(
                opId: "r12-t6-never-signalled-\(UUID().uuidString)", timeoutSeconds: 0.25)
            outcome.withLock { $0 = result }
        }
        defer { waiter.cancel() }

        for _ in 0..<60 {
            if outcome.withLock({ $0 }) != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let settled = outcome.withLock { $0 }
        #expect(settled != nil,
                "awaitCalendarOpOutcome never returned after its own 0.25s timeout elapsed — the timeout arm took the continuation out of the awaiter table and discarded it without resuming, so neither it nor a later signal could ever resolve the wait. Every agent calendar create/edit/delete issued offline hangs the chat turn.")
        if case .timedOut = settled { } else {
            #expect(Bool(false), "expected the wait to settle as .timedOut, got \(String(describing: settled))")
        }
    }

    // MARK: - T8

    @Test("an unexecutable queued op is reported as a PERMANENT FAILURE with a reason — never as success, and nothing reaches the wire")
    func unexecutableOpIsNotReportedAsSuccess() async throws {
        let accountId = "cal-r12-t8"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        // A persisted delete that carries no event id. `executeCalendarOperation`
        // cannot address anything, so the only honest outcomes are "permanently
        // failed, here is why" or "retry" — and retry would wedge the account's
        // calendar lane forever, since the row can never gain an id.
        let op = PendingCalendarOperation(
            operationType: .delete, accountId: accountId, eventId: nil,
            calendarId: "primary", arguments: [:])
        try await pool.write { db in try op.insert(db) }

        async let outcome = AccountManager.shared.awaitCalendarOpOutcome(opId: op.id, timeoutSeconds: 5.0)
        // Let the awaiter register before the drain can signal it.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await AccountManager.shared.drainCalendarQueue()
        let result = await outcome

        if case .permanentFailure(let reason) = result {
            #expect(!reason.isEmpty, "a permanent failure must carry a reason the agent can act on")
        } else {
            #expect(Bool(false),
                    "the drain reported \(result) for an op it could not execute. A normal return from executeCalendarOperation IS the success path, so the agent was told the calendar event was deleted successfully while nothing reached the wire.")
        }

        let wire = await mock.deletedEvents
        #expect(wire.isEmpty, "nothing should have reached the provider — got \(wire.count) delete(s)")

        // DURABLE side: the row must not be left queued either, or the same
        // unexecutable op re-enters every future drain and head-of-line-blocks
        // the account's calendar lane (the wedge, which never recovers via sync).
        let remaining = try await pool.read { db in try PendingCalendarOperation.fetchAll(db) }
        #expect(remaining.isEmpty, "the unexecutable op is still queued — it will starve the lane forever")
    }
}
