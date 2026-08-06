/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - R12-T2 — a destructive calendar op needs a PROVEN target
//
// INVARIANT (system property): **no irreversible calendar delete is ever issued —
// or persisted for later issue — against an event whose current occupant was
// never read.** `CalDAVProvider.deleteEvent` is a WebDAV `DELETE` on the event's
// own `.ics` resource, and RFC 4918 §9.6 / RFC 4791 define no trash, no undelete
// and no restore for it. Being wrong there is unrecoverable, which puts it under
// C3 next to the `COPYUID`-gated expunge.
//
// The defect this pins: `CalendarEventDeleteTool` used to fall through a failed
// `getEvent` with `try?`, leaving the confirmation card's placeholder title
// "(Event)" and `Date()` for both ends. The user confirmed THAT, and the tool then
// queued a delete against an href it had never dereferenced. Its sibling
// `CalendarEventEditTool` already refused in exactly this situation — the two
// tools disagreed and the DESTRUCTIVE one was the permissive one.
//
// ⚠️ TWO-SIDED, and both directions are asserted here:
//   * REFUSAL side — nothing reaches the wire (`deletedEvents` empty) AND nothing
//     is left durably queued to reach it later (`PendingCalendarOperation` empty).
//     A wire count alone is defeatable: an op that merely sits in the queue would
//     still be executed on the next drain.
//   * CONTROL side — when the event IS readable the delete still goes through, so
//     the refusal cannot be satisfied by a tool that refuses everything. This also
//     anchors the fixture (`MIS-030`): it proves the harness can produce a wire
//     delete at all, so the absence asserted above is meaningful.
//
// ⚠️ NOT A DROPPED INTENTION. The refusal happens BEFORE `queueCalendarOperation`,
// so no durable row and no user-visible acknowledgement exists. Never-drop governs
// intentions that were persisted or acknowledged; this one is neither.

@Suite("Calendar delete — the target identity must be established before confirming", .serialized, .processGlobalState)
struct CalendarDeleteIdentityProofTests {

    /// Auto-responding confirmation sink so the tool's confirmation wait resolves
    /// inline. Mirrors `CoordinatedToolActionTests.AutoConfirmSink`.
    @MainActor
    private final class AutoConfirmSink: AgentUISink {
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            confirmation.onRespond(true)
        }
    }

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

    /// Seed the translator so the tool resolves numeric id → compound id →
    /// (accountId, calendarId), i.e. the ordinary post-`calendar_search` state.
    private func seedTranslator(
        _ translator: MockChatIdTranslator, numericId: Int, accountId: String, eventId: String
    ) async {
        let compound = CompoundEventId.make(accountId: accountId, eventId: eventId)
        await translator.seed(numericId, realId: compound)
        await translator.cacheEventDetail(
            realId: eventId, accountId: accountId, calendarId: "primary", calendarName: "Work",
            title: "Quarterly review", startDate: nil, endDate: nil, isAllDay: false,
            location: nil, notes: nil, attendees: [], isRecurring: false, recurrenceRule: nil,
            availability: "busy", htmlLink: nil, eventTimeZone: nil
        )
    }

    @Test("An event the tool cannot dereference is REFUSED — nothing reaches the wire and nothing is left queued to reach it later")
    func unreadableEventIsRefusedAndNeverQueued() async throws {
        let accountId = "cal-r12-t2-refuse"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        // The provider is present and answering — it simply cannot resolve THIS id.
        // That is the reachable shape: a stale id from an earlier turn, or an event
        // another client already replaced.
        await mock.setGetEventThrows(GoogleCalendarError.eventNotFound)
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let translator = MockChatIdTranslator()
        await seedTranslator(translator, numericId: 71, accountId: accountId, eventId: "evt-never-read")

        let tool = CalendarEventDeleteTool(context: ToolContext(db: pool, translator: translator))
        let sink = AutoConfirmSink()
        let output = try await tool.execute(
            arguments: ["event_id": .string("71")],
            invocation: ToolInvocation(uiSink: sink, sessionKey: "r12-t2-refuse"))

        let wireDeletes = await mock.deletedEvents
        #expect(wireDeletes.isEmpty,
                "an irreversible calendar delete reached the wire for an event whose current occupant was never read — the user confirmed a placeholder card. Got \(wireDeletes.count) delete(s): \(wireDeletes.map { $0.eventId })")

        let queued = try await pool.read { db in try PendingCalendarOperation.fetchAll(db) }
        #expect(queued.isEmpty,
                "the delete was persisted rather than refused — the next drain will issue it, so an empty wire count alone proves nothing. Got \(queued.count) queued op(s): \(queued.map { $0.operationType })")

        #expect(output.contains("could not find event"),
                "the agent must be told to re-look-up the id rather than be told the delete succeeded — got: \(output)")
    }

    @Test("R13-U1 — a numeric event_id the translator cannot resolve is REFUSED, not used as a literal event id")
    func unresolvableNumericIdIsRefusedAndNeverQueued() async throws {
        // The same INVARIANT as the suite header, reached one step earlier: the
        // delete's target must be an event the app can name, not a numeral the
        // model emitted. `ChatIdTranslator` evicts orphan mappings at
        // `Config.maxMappings`, so `toRealId` returning nil is ordinary in a long
        // session — and the pre-fix `else` branch then used the numeral ITSELF as
        // the event id, i.e. it would delete whatever event happens to be called
        // "71" on the server. All four mail tools already refused here
        // (`EmailReadTool`: `guard let realId = … else { return … }`); the three
        // calendar tools did not, and the DESTRUCTIVE one was again among the
        // permissive ones.
        //
        // The translator is deliberately left UNSEEDED — that is the whole
        // fixture. The control test below shares this harness and seeds it, which
        // is what makes the two absences here non-vacuous (`MIS-030`).
        let accountId = "cal-r13-u1-unresolvable"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await mock.setGetEventResult(GCalEvent(
            id: "71", summary: "Whatever event is called 71", location: nil, description: nil,
            start: nil, end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: "confirmed", htmlLink: nil, created: nil, updated: nil
        ))
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let translator = MockChatIdTranslator()
        let tool = CalendarEventDeleteTool(context: ToolContext(db: pool, translator: translator))
        let sink = AutoConfirmSink()
        let output = try await tool.execute(
            arguments: ["event_id": .string("71")],
            invocation: ToolInvocation(uiSink: sink, sessionKey: "r13-u1-unresolvable"))

        let wireDeletes = await mock.deletedEvents
        #expect(wireDeletes.isEmpty,
                "the numeral was used as a literal event id and an irreversible delete reached the wire against it. Got \(wireDeletes.count): \(wireDeletes.map { $0.eventId })")

        let queued = try await pool.read { db in try PendingCalendarOperation.fetchAll(db) }
        #expect(queued.isEmpty,
                "the delete was persisted rather than refused — the next drain issues it, so an empty wire count alone proves nothing. Got \(queued.count) queued op(s)")

        #expect(output.contains("no event found"),
                "the agent must be told to re-look-up the id rather than be told the delete succeeded — got: \(output)")
    }

    @Test("Control: an event the tool CAN dereference is still deleted — the refusal is not 'refuse everything'")
    func readableEventIsStillDeleted() async throws {
        let accountId = "cal-r12-t2-control"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await mock.setGetEventResult(GCalEvent(
            id: "evt-readable", summary: "Quarterly review", location: nil, description: nil,
            start: nil, end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: "confirmed", htmlLink: nil, created: nil, updated: nil
        ))
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let translator = MockChatIdTranslator()
        await seedTranslator(translator, numericId: 72, accountId: accountId, eventId: "evt-readable")

        let tool = CalendarEventDeleteTool(context: ToolContext(db: pool, translator: translator))
        let sink = AutoConfirmSink()
        _ = try await tool.execute(
            arguments: ["event_id": .string("72")],
            invocation: ToolInvocation(uiSink: sink, sessionKey: "r12-t2-control"))

        let wireDeletes = await mock.deletedEvents
        #expect(wireDeletes.count == 1,
                "the fixture must be able to produce a wire delete at all, or the absence asserted by the refusal test is vacuous (MIS-030) — got \(wireDeletes.count)")
        guard wireDeletes.count == 1 else { return }
        #expect(wireDeletes[0].eventId == "evt-readable")
    }
}
