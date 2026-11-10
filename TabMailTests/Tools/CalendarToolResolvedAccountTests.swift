/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// INVARIANT: the calendar chat tools act on the calendar that
// `CalendarProviderDispatch.resolve` names, through the real tool entry point.
//
//  * A confirmed create reaches the resolved account's calendar, and no other
//    registered calendar sees it. When nothing resolves, the tool says so and
//    nothing is queued.
//  * An edit or delete handed a bare event id (no account prefix) reads the event
//    through the resolved calendar, so the confirmation card shows the real
//    event. The bare id still names no account, so nothing is queued and nothing
//    reaches the wire. When nothing resolves, the tool refuses before any card.
//
// `CalendarProviderDispatchResolveTests` pins the resolver's own answer; this
// suite pins what the tools do with it, which a resolver test alone cannot.
//
// Each case installs its own database (the create tool resolves through the
// shared one), registers mock calendars under unique account ids, and restores
// demo mode, the calendar preferences and the registry afterwards. A calendar
// another suite left registered has no account row here and cannot be picked.

@MainActor
@Suite("Calendar tools act on the resolved calendar account", .serialized, .processGlobalState)
struct CalendarToolResolvedAccountTests {

    /// Confirms every card and records what it showed.
    @MainActor
    private final class RecordingConfirmSink: AgentUISink {
        var calendarEvents: [AgentToolRouter.ActionConfirmation.CalendarEventDetail] = []
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            calendarEvents.append(contentsOf: confirmation.calendarEvents)
            confirmation.onRespond(true)
        }
    }

    private struct Fixture {
        let pool: DatabasePool
        let accountA: String
        let accountB: String
        let mockA: MockCalendarProvider
        let mockB: MockCalendarProvider
    }

    private enum Role { case a, b }

    private static let preferenceKeys = [
        CalendarProviderDispatch.preferredCalendarAccountKey,
        CalendarProviderDispatch.preferredGoogleAccountKey,
        CalendarProviderDispatch.preferredCalendarKey,
        CalendarProviderDispatch.preferredGoogleCalendarKey,
    ]

    /// Installs a fresh shared database holding active accounts A and B, registers
    /// the calendars in `registered`, sets the preferred calendar account, runs
    /// `body`, then restores every global it touched.
    private func withCalendars(
        registered: Set<Role>,
        preferred: Role?,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }

        let fixture = Fixture(
            pool: pool,
            accountA: "cal-tool-a-\(UUID().uuidString)",
            accountB: "cal-tool-b-\(UUID().uuidString)",
            mockA: MockCalendarProvider(),
            mockB: MockCalendarProvider()
        )
        func id(_ role: Role) -> String { role == .a ? fixture.accountA : fixture.accountB }
        func mock(_ role: Role) -> MockCalendarProvider { role == .a ? fixture.mockA : fixture.mockB }

        let defaults = UserDefaults.standard
        let priorPreferences = Self.preferenceKeys.map { defaults.string(forKey: $0) }
        let priorDemoActive = DemoModeStore.shared.isActive
        let manager = AccountManager.shared

        var failure: Error?
        do {
            let accounts = [(id(.a), "a@example.com"), (id(.b), "b@example.com")]
            try await pool.write { db in
                for (accountId, email) in accounts {
                    var account = Account(emailAddress: email, displayName: "Test", provider: .gmail)
                    account.id = accountId
                    account.isActive = true
                    try account.insert(db)
                }
            }
            for role in registered {
                await manager.registerCalendarProviderForTesting(accountId: id(role), provider: mock(role))
            }
            DemoModeStore.shared.isActive = false
            for key in Self.preferenceKeys { defaults.removeObject(forKey: key) }
            if let preferred {
                defaults.set(id(preferred), forKey: CalendarProviderDispatch.preferredCalendarAccountKey)
            }
            try await body(fixture)
        } catch {
            failure = error
        }

        for (key, value) in zip(Self.preferenceKeys, priorPreferences) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        DemoModeStore.shared.isActive = priorDemoActive
        await manager.unregisterCalendarProviderForTesting(accountId: fixture.accountA)
        await manager.unregisterCalendarProviderForTesting(accountId: fixture.accountB)
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        if let failure { throw failure }
    }

    private static func event(id: String, summary: String) -> GCalEvent {
        GCalEvent(
            id: id, summary: summary, location: nil, description: nil,
            start: nil, end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: "confirmed", htmlLink: nil, created: nil, updated: nil
        )
    }

    /// `yyyy-MM-dd'T'HH:mm:ss` in UTC, `daysFromNow` days ahead at `hour`:00.
    private static func isoDay(_ daysFromNow: Int, hour: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = cal.date(byAdding: .day, value: daysFromNow, to: cal.startOfDay(for: Date())) ?? Date()
        let at = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: at)
    }

    private static var createArguments: [String: JSONValue] {
        [
            "title": .string("Planning review"),
            "start_iso": .string(isoDay(7, hour: 10)),
            "end_iso": .string(isoDay(7, hour: 11)),
            "timezone": .string("UTC"),
        ]
    }

    // MARK: - Create

    @Test("A confirmed create reaches the preferred account's calendar, and no other registered calendar")
    func confirmedCreateReachesTheResolvedCalendar() async throws {
        try await withCalendars(registered: [.a, .b], preferred: .b) { f in
            await f.mockB.setCreateEventResult(Self.event(id: "evt-created", summary: "Planning review"))

            let sink = RecordingConfirmSink()
            let tool = CalendarEventCreateTool(context: ToolContext(db: f.pool, translator: MockChatIdTranslator()))
            let output = try await tool.execute(
                arguments: Self.createArguments,
                invocation: ToolInvocation(uiSink: sink, sessionKey: "cal-tool-create"))

            #expect(sink.calendarEvents.count == 1,
                    "setup: the tool never presented the create card — got \(sink.calendarEvents.count)")

            let created = await f.mockB.createdEvents
            #expect(created.count == 1,
                    "the user confirmed a create while a calendar was resolvable, but it never reached that calendar — got \(created.count) create(s); tool said: \(output)")
            guard created.count == 1 else { return }
            #expect(created[0].calendarId == "primary")
            #expect(created[0].event.summary == "Planning review")

            let createdElsewhere = await f.mockA.createdEvents
            #expect(createdElsewhere.isEmpty,
                    "the create reached a calendar the resolver did not name — got \(createdElsewhere.count)")

            #expect(output.contains("event_id: \(CompoundEventId.make(accountId: f.accountB, eventId: ""))"),
                    "the event id handed back must name the account that holds the event — got: \(output)")
        }
    }

    @Test("A confirmed create with no resolvable calendar says so and queues nothing")
    func confirmedCreateWithNoCalendarQueuesNothing() async throws {
        try await withCalendars(registered: [], preferred: .a) { f in
            let sink = RecordingConfirmSink()
            let tool = CalendarEventCreateTool(context: ToolContext(db: f.pool, translator: MockChatIdTranslator()))
            let output = try await tool.execute(
                arguments: Self.createArguments,
                invocation: ToolInvocation(uiSink: sink, sessionKey: "cal-tool-create-none"))

            #expect(sink.calendarEvents.count == 1,
                    "setup: the tool never presented the create card, so the answer below was not reached after a confirmation — got \(sink.calendarEvents.count)")
            #expect(output == CalendarProviderDispatch.notAvailableMessage, "got: \(output)")

            let queued = try await f.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
            #expect(queued.isEmpty,
                    "a create with no calendar to run on was persisted anyway — got \(queued.count) queued op(s)")
        }
    }

    // MARK: - Edit and delete with a bare event id

    enum BareIdTool: String, CaseIterable, CustomTestStringConvertible {
        case edit, delete
        var testDescription: String { rawValue }
    }

    private func runBareId(_ kind: BareIdTool, pool: DatabasePool, sink: RecordingConfirmSink) async throws -> String {
        let ctx = ToolContext(db: pool, translator: MockChatIdTranslator())
        let invocation = ToolInvocation(uiSink: sink, sessionKey: "cal-tool-bare-\(kind.rawValue)")
        switch kind {
        case .edit:
            return try await CalendarEventEditTool(context: ctx).execute(
                arguments: ["event_id": .string("evt-bare"), "title": .string("Renamed review")],
                invocation: invocation)
        case .delete:
            return try await CalendarEventDeleteTool(context: ctx).execute(
                arguments: ["event_id": .string("evt-bare")],
                invocation: invocation)
        }
    }

    @Test("A bare event id is read through the resolved calendar, and still queues nothing", arguments: BareIdTool.allCases)
    func bareIdIsReadThroughTheResolvedCalendar(_ kind: BareIdTool) async throws {
        try await withCalendars(registered: [.a, .b], preferred: .a) { f in
            await f.mockA.setGetEventResult(Self.event(id: "evt-bare", summary: "Quarterly review"))

            let sink = RecordingConfirmSink()
            let output = try await runBareId(kind, pool: f.pool, sink: sink)

            let logA = await f.mockA.callLog
            let readsA = logA.filter { $0.hasPrefix("getEvent(") }
            #expect(readsA == ["getEvent(calendarId:primary,eventId:evt-bare)"],
                    "the bare id must be looked up on the resolved calendar — got \(readsA); tool said: \(output)")
            let readsB = await f.mockB.callLog
            #expect(readsB.isEmpty, "a calendar the resolver did not name was used — got \(readsB)")

            #expect(sink.calendarEvents.map(\.title) == ["Quarterly review"],
                    "the card must show the event read through the resolved calendar — got \(sink.calendarEvents.map(\.title)); tool said: \(output)")

            #expect(output == CalendarProviderDispatch.notAvailableMessage, "got: \(output)")
            let queued = try await f.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
            #expect(queued.isEmpty, "a bare id names no account, yet an op was queued — got \(queued.count)")
            let updated = await f.mockA.updatedEvents
            let deleted = await f.mockA.deletedEvents
            #expect(updated.isEmpty && deleted.isEmpty,
                    "a bare id reached the wire — \(updated.count) update(s), \(deleted.count) delete(s)")
        }
    }

    @Test("A bare event id with no resolvable calendar is refused before any card", arguments: BareIdTool.allCases)
    func bareIdWithNoCalendarIsRefused(_ kind: BareIdTool) async throws {
        try await withCalendars(registered: [], preferred: .a) { f in
            let sink = RecordingConfirmSink()
            let output = try await runBareId(kind, pool: f.pool, sink: sink)

            #expect(sink.calendarEvents.isEmpty,
                    "a card was shown for an event no calendar could read — got \(sink.calendarEvents.map(\.title))")
            #expect(output.contains("could not find event with id 'evt-bare'"), "got: \(output)")
            let queued = try await f.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
            #expect(queued.isEmpty, "got \(queued.count) queued op(s)")
        }
    }
}
