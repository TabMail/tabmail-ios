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

    /// A start and end the assistant spells with an offset name the instants they spell, so the
    /// card shows them and the calendar gets them, never the current time in their place.
    @Test("A create with a start and end spelled with or without an offset is shown and created at those times",
          arguments: StartSpelling.allCases)
    func createAtSpelledTimes(_ spelling: StartSpelling) async throws {
        let zone = "America/Los_Angeles"
        let start = GraphFixture.onDevice(days: 0, hour: 23).addingTimeInterval(1_800)
        try await withCalendars(registered: [.a], preferred: .a) { f in
            await f.mockA.setCreateEventResult(Self.event(id: "evt-spelled", summary: "Planning review"))

            let sink = RecordingConfirmSink()
            let tool = CalendarEventCreateTool(context: ToolContext(db: f.pool, translator: MockChatIdTranslator()))
            let output = try await tool.execute(
                arguments: [
                    "title": .string("Planning review"),
                    "start_iso": .string(spelling.spell(start, label: zone)),
                    "end_iso": .string(spelling.spell(start.addingTimeInterval(3_600), label: zone)),
                    "timezone": .string(zone),
                ],
                invocation: ToolInvocation(uiSink: sink, sessionKey: "cal-tool-create-spelled"))

            #expect(sink.calendarEvents.count == 1, "setup: no create card — got \(sink.calendarEvents.count)")
            guard sink.calendarEvents.count == 1 else { return }
            #expect(sink.calendarEvents[0].startDate == start, "the card shows \(sink.calendarEvents[0].startDate)")
            #expect(sink.calendarEvents[0].endDate == start.addingTimeInterval(3_600), "the card shows \(sink.calendarEvents[0].endDate)")
            let created = await f.mockA.createdEvents
            #expect(created.count == 1, "tool said: \(output)")
            guard created.count == 1 else { return }
            #expect(created[0].event.startDateTime.flatMap(Date.fromISO8601) == start, "\(created[0].event.startDateTime ?? "nil")")
            #expect(created[0].event.endDateTime.flatMap(Date.fromISO8601) == start.addingTimeInterval(3_600), "\(created[0].event.endDateTime ?? "nil")")
        }
    }

    /// An all-day create is dated as spelled: the card and the created event show the spelled
    /// date, never the day an offset's instant falls on in the event's zone.
    @Test("An all-day create spelled with a time and an offset is shown and created on the spelled dates",
          arguments: AllDaySpelling.allCases)
    func createAllDayOnSpelledDates(_ spelling: AllDaySpelling) async throws {
        let zone = AllDaySpelling.label
        try await withCalendars(registered: [.a], preferred: .a) { f in
            await f.mockA.setCreateEventResult(Self.event(id: "evt-all-day", summary: "Offsite"))

            let sink = RecordingConfirmSink()
            let tool = CalendarEventCreateTool(context: ToolContext(db: f.pool, translator: MockChatIdTranslator()))
            let output = try await tool.execute(
                arguments: [
                    "title": .string("Offsite"),
                    "start_iso": .string(spelling.spell(AllDaySpelling.day)),
                    "end_iso": .string(spelling.spell(AllDaySpelling.nextDay)),
                    "all_day": .bool(true),
                    "timezone": .string(zone),
                ],
                invocation: ToolInvocation(uiSink: sink, sessionKey: "cal-tool-create-all-day"))

            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: zone)
            fmt.dateFormat = "yyyy-MM-dd"
            #expect(sink.calendarEvents.count == 1, "setup: no create card — got \(sink.calendarEvents.count)")
            guard sink.calendarEvents.count == 1 else { return }
            #expect(fmt.string(from: sink.calendarEvents[0].startDate) == AllDaySpelling.day, "the card shows \(sink.calendarEvents[0].startDate)")
            #expect(fmt.string(from: sink.calendarEvents[0].endDate) == AllDaySpelling.nextDay, "the card shows \(sink.calendarEvents[0].endDate)")
            let created = await f.mockA.createdEvents
            #expect(created.count == 1, "tool said: \(output)")
            guard created.count == 1 else { return }
            #expect(created[0].event.startDate == AllDaySpelling.day, "\(created[0].event.startDate ?? "nil")")
            #expect(created[0].event.endDate == AllDaySpelling.nextDay, "\(created[0].event.endDate ?? "nil")")
        }
    }

    /// A timed create spelled as a bare date starts at midnight in the event's zone: the card
    /// shows that instant and the created event carries it spelled with the zone's own offset.
    @Test("A timed create spelled as a bare date starts at midnight in the event's zone")
    func createTimedFromBareDate() async throws {
        let zone = "America/Los_Angeles"
        let tz = try #require(TimeZone(identifier: zone))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let start = try #require(cal.date(from: DateComponents(year: 2099, month: 3, day: 2)))
        let end = try #require(cal.date(from: DateComponents(year: 2099, month: 3, day: 3)))
        try await withCalendars(registered: [.a], preferred: .a) { f in
            await f.mockA.setCreateEventResult(Self.event(id: "evt-bare-date", summary: "Planning review"))

            let sink = RecordingConfirmSink()
            let tool = CalendarEventCreateTool(context: ToolContext(db: f.pool, translator: MockChatIdTranslator()))
            let output = try await tool.execute(
                arguments: [
                    "title": .string("Planning review"),
                    "start_iso": .string("2099-03-02"),
                    "end_iso": .string("2099-03-03"),
                    "all_day": .bool(false),
                    "timezone": .string(zone),
                ],
                invocation: ToolInvocation(uiSink: sink, sessionKey: "cal-tool-create-bare-date"))

            #expect(sink.calendarEvents.count == 1, "setup: no create card — got \(sink.calendarEvents.count)")
            guard sink.calendarEvents.count == 1 else { return }
            #expect(sink.calendarEvents[0].startDate == start, "the card shows \(sink.calendarEvents[0].startDate)")
            #expect(sink.calendarEvents[0].endDate == end, "the card shows \(sink.calendarEvents[0].endDate)")
            let created = await f.mockA.createdEvents
            #expect(created.count == 1, "tool said: \(output)")
            guard created.count == 1 else { return }
            let startDateTime = created[0].event.startDateTime ?? "nil"
            #expect(Date.fromISO8601(startDateTime) == start, "\(startDateTime)")
            #expect(startDateTime.hasSuffix("-08:00"), "\(startDateTime)")
            #expect(created[0].event.endDateTime.flatMap(Date.fromISO8601) == end, "\(created[0].event.endDateTime ?? "nil")")
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

    // MARK: - The card of a rule edit

    /// A weekly series a week from today at 10:00 UTC, on that day's weekday; a one-off
    /// event at the same time when `recurring` is false.
    private static func series(recurring: Bool = true, attendees: [GCalAttendee]? = nil) -> GCalEvent {
        let start = isoDay(7, hour: 10)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = cal.timeZone
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let weekday = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][cal.component(.weekday, from: fmt.date(from: start) ?? Date()) - 1]
        return GCalEvent(
            id: "evt-bare", summary: "Weekly sync", location: nil, description: nil,
            start: GCalDateTime(dateTime: start + "Z", date: nil, timeZone: "UTC"),
            end: GCalDateTime(dateTime: isoDay(7, hour: 11) + "Z", date: nil, timeZone: "UTC"),
            attendees: attendees, organizer: nil, recurrence: recurring ? ["RRULE:FREQ=WEEKLY;BYDAY=\(weekday)"] : nil,
            transparency: nil, status: "confirmed", htmlLink: nil, created: nil, updated: nil
        )
    }

    /// The lines of the card an edit of `series` with `arguments` presents, with the series'
    /// calendar answering `answer` to whether the edit resets changed occurrences, the edits it
    /// was asked about, and the guest list the card shows.
    private func cardLines(
        series: GCalEvent, arguments: [String: JSONValue], answer: Bool
    ) async throws -> (lines: [String], asked: [GCalEventInput], attendees: [String]) {
        var lines: [String] = []
        var asked: [GCalEventInput] = []
        var attendees: [String] = []
        try await withCalendars(registered: [.a], preferred: .a) { f in
            await f.mockA.setGetEventResult(series)
            f.mockA.resetsAnswer.withLock { $0 = answer }
            let sink = RecordingConfirmSink()
            let output = try await CalendarEventEditTool(context: ToolContext(db: f.pool, translator: MockChatIdTranslator())).execute(
                arguments: ["event_id": .string("evt-bare"), "timezone": .string("UTC")].merging(arguments) { $1 },
                invocation: ToolInvocation(uiSink: sink, sessionKey: "cal-tool-rule-card"))
            #expect(sink.calendarEvents.count == 1, "setup: the edit card was not shown; tool said: \(output)")
            lines = sink.calendarEvents.first?.changes ?? []
            attendees = sink.calendarEvents.first?.attendees ?? []
            asked = f.mockA.resetsAsked.withLock { $0 }
        }
        return (lines, asked, attendees)
    }

    /// The card of a guest change names the guests added and removed, as the Thunderbird add-on's
    /// does, and never a resulting list: the write applies the change to each item the edit
    /// covers, whose guests can differ (#620). Each added guest shows the address the invitation
    /// goes to, after the name when one is given, so a wrong address is caught before the user
    /// confirms (ADR-IOS-024).
    @Test("A guest change's card names the guests added, with their addresses, and removed, never a resulting list")
    func guestChangeCardNamesTheChange() async throws {
        let stored = ["alice@example.com", "bob@example.com"].map {
            GCalAttendee(email: $0, displayName: nil, responseStatus: "accepted", organizer: nil, self: nil)
        }
        let adds: [JSONValue] = [
            .dictionary(["email": .string("carol@example.com"), "name": .string("Carol")]),
            .string("dave@example.com"),
            .string("erin@example.com"),
            .string("frank@example.com"),
            .string("grace@example.com"),
        ]
        let card = try await cardLines(
            series: Self.series(attendees: stored),
            arguments: ["add_attendees": .array(adds),
                        "remove_attendees": .array([.string("mailto:Bob@Example.com"), .string("*")])],
            answer: false)
        #expect(card.lines == [
            "attendees + Carol <carol@example.com>", "attendees + dave@example.com", "attendees + erin@example.com",
            "attendees + and 2 more",
            "attendees − all attendees", "attendees − bob@example.com",
        ], "the card shows \(card.lines)")
        #expect(card.attendees.isEmpty, "the card shows a guest list: \(card.attendees)")
    }

    /// A guest named twice (the same address in another letter case, under another name) is one
    /// added guest and one card line, and so is an address removed twice: the card's rows are keyed
    /// by their text, so a repeated line could drop a row. Four guests added show three and
    /// "and 1 more".
    @Test("A guest change's card names a guest added or removed twice once, and four added as three and 1 more")
    func guestChangeCardNamesEachGuestOnce() async throws {
        let adds: [JSONValue] = [
            .dictionary(["email": .string("carol@example.com"), "name": .string("Carol")]),
            .dictionary(["email": .string("Carol@Example.com"), "name": .string("Carol Two")]),
            .string("dave@example.com"),
            .string("erin@example.com"),
            .string("frank@example.com"),
        ]
        let card = try await cardLines(
            series: Self.series(attendees: []),
            arguments: ["add_attendees": .array(adds),
                        "remove_attendees": .array([.string("bob@example.com"), .string("Bob@Example.com")])],
            answer: false)
        #expect(card.lines == [
            "attendees + Carol <carol@example.com>", "attendees + dave@example.com", "attendees + erin@example.com",
            "attendees + and 1 more",
            "attendees − bob@example.com",
        ], "the card shows \(card.lines)")
    }

    /// Outlook resets a series' deleted and moved occurrences when a whole-series edit
    /// changes its rule (its end, interval or kind) or moves its start or end (measured), so
    /// a whole-series edit the series' calendar says resets them says so on the card.
    enum ResettingEdit: String, CaseIterable, CustomTestStringConvertible {
        case daily, weeklyWithCount, everyOtherWeek, monthly, yearly, timeOnlyMove
        var testDescription: String { rawValue }

        /// The rule the edit gives; none for a time-only move.
        var rule: [String: JSONValue]? {
            switch self {
            case .daily: ["freq": .string("DAILY")]
            case .weeklyWithCount: ["freq": .string("WEEKLY"), "count": .int(9)]
            case .everyOtherWeek: ["freq": .string("WEEKLY"), "interval": .int(2)]
            case .monthly: ["freq": .string("MONTHLY")]
            case .yearly: ["freq": .string("YEARLY")]
            case .timeOnlyMove: nil
            }
        }
    }

    @Test("A whole-series edit the calendar says resets changed occurrences says so on its card",
          arguments: ResettingEdit.allCases)
    func resettingEditCardWarns(_ resetting: ResettingEdit) async throws {
        // A time-only move puts the series an hour later on the same day.
        let edit: [String: JSONValue] = if let rule = resetting.rule {
            ["recurrence": .dictionary(rule)]
        } else {
            ["start_iso": .string(Self.isoDay(7, hour: 11)), "end_iso": .string(Self.isoDay(7, hour: 12))]
        }
        let card = try await cardLines(series: Self.series(), arguments: edit, answer: true)
        #expect(card.lines.filter { $0 == CalendarToolHelpers.ruleChangeResetNote }.count == 1, "the card shows \(card.lines)")
        #expect(card.lines.contains("Occurrences you changed individually may be reset."), "the card shows \(card.lines)")
        guard card.asked.count == 1 else {
            Issue.record("the calendar was asked \(card.asked.count) times")
            return
        }
        if edit["recurrence"] != nil {
            #expect(card.asked[0].recurrence?.first?.hasPrefix("RRULE:FREQ=") == true,
                    "the calendar was asked about \(String(describing: card.asked[0].recurrence)), not the edit's rule")
        } else {
            #expect(card.asked[0].recurrence == nil && card.asked[0].startDateTime != nil && card.asked[0].endDateTime != nil,
                    "the calendar was not asked about the edit's new times")
        }
    }

    enum QuietEdit: String, CaseIterable, CustomTestStringConvertible {
        case resentRule, renameOnly
        var testDescription: String { rawValue }
    }

    /// The assistant re-sends the rule it read with other edits, or only renames the series;
    /// the calendar says neither resets anything, so the card has no line.
    @Test("A whole-series edit the calendar says resets nothing shows no reset line", arguments: QuietEdit.allCases)
    func quietEditCardHasNoWarning(_ edit: QuietEdit) async throws {
        var arguments: [String: JSONValue] = ["title": .string("Weekly sync (renamed)")]
        if edit == .resentRule { arguments["recurrence"] = .dictionary(["freq": .string("WEEKLY")]) }
        let card = try await cardLines(series: Self.series(), arguments: arguments, answer: false)
        #expect(!card.lines.contains(CalendarToolHelpers.ruleChangeResetNote), "\(edit): the card shows \(card.lines)")
        #expect(card.lines.contains("title → Weekly sync (renamed)"), "setup: the edit was not on the card: \(card.lines)")
        if edit == .resentRule {
            #expect(card.lines.contains { $0.hasPrefix("recurrence → ") }, "setup: the rule was not on the card: \(card.lines)")
        }
        #expect(card.asked.count == 1, "\(edit): the calendar was asked \(card.asked.count) times")
    }

    enum NoLineEdit: String, CaseIterable, CustomTestStringConvertible {
        case oneOffMadeRecurring, thisAndFollowing
        var testDescription: String { rawValue }
    }

    /// No line, and the calendar is not asked, for an event that has no rule (it has no
    /// occurrences to reset) and for an edit of part of a series (it writes nothing on the
    /// series).
    @Test("An edit of an event with no rule, or of part of a series, shows no reset line",
          arguments: NoLineEdit.allCases)
    func noLineEditCardHasNoWarning(_ edit: NoLineEdit) async throws {
        var arguments: [String: JSONValue] = [
            "title": .string("Weekly sync (renamed)"), "recurrence": .dictionary(["freq": .string("DAILY")]),
        ]
        if edit == .thisAndFollowing {
            arguments["edit_scope"] = .string("this_and_following")
            arguments["recurrence_id"] = .string(Self.isoDay(14, hour: 10))
        }
        let card = try await cardLines(
            series: Self.series(recurring: edit != .oneOffMadeRecurring), arguments: arguments, answer: true)
        #expect(!card.lines.contains(CalendarToolHelpers.ruleChangeResetNote), "\(edit): the card shows \(card.lines)")
        #expect(card.lines.contains("title → Weekly sync (renamed)"), "setup: the edit was not on the card: \(card.lines)")
        #expect(card.asked.isEmpty, "\(edit): the calendar was asked about \(card.asked.count) edits")
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
