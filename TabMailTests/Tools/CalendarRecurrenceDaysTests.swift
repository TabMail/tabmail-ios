/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - A repeat rule's days reach the calendar
//
// **INVARIANT.** *Every repeat field the calendar tools take (`freq`, `interval`, `count`, `until`,
// `byDay`, `byMonthDay`, `byMonth`, `wkst`) is written to the calendar, on create and on edit, on
// every provider.* A Monday-and-Wednesday weekly series is saved on Monday and Wednesday, "the first
// Monday of each month" on the first Monday, and so on.
//
// **AND NOTHING IS DROPPED SILENTLY.** *An invalid field is refused before the confirmation card,
// naming the field and the value, with nothing sent; a rule a calendar can't hold (Outlook's pattern
// types) is refused the same way for that calendar.* The confirmation card names the days.
//
// **AND A GOOGLE RULE WRITE KEEPS THE SERIES' EXCLUDED AND ADDED DATES** (EXDATE, RDATE), as CalDAV
// does: Google replaces the whole `recurrence` array, so a rule written alone brought back every
// deleted occurrence.
//
// The defect: `CalendarToolHelpers.buildGCalEventInput` wrote only FREQ, INTERVAL, COUNT and UNTIL,
// so every other field was dropped on every provider and the card did not show it.
//
// Dates are in 2099 (never stale) and in UTC; addresses are example.com.

/// One representative rule: the tool fields, the RRULE Google and CalDAV must hold, the Graph
/// pattern Outlook must hold, and what the card says.
struct RecurrenceDaysCase: CustomTestStringConvertible, Sendable {
    let name: String
    let fields: [String: JSONValue]
    let rrule: String
    let graph: [String: String]
    let card: String
    var testDescription: String { name }

    static let all: [RecurrenceDaysCase] = [
        .init(name: "weekly on Monday and Wednesday",
              fields: ["freq": .string("WEEKLY"), "byDay": .array([.string("MO"), .string("WE")])],
              rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO,WE",
              graph: ["type": "weekly", "daysOfWeek": "monday,wednesday"],
              card: "weekly on Monday, Wednesday"),
        .init(name: "monthly on the first Monday",
              fields: ["freq": .string("MONTHLY"), "byDay": .array([.string("1MO")])],
              rrule: "RRULE:FREQ=MONTHLY;BYDAY=1MO",
              graph: ["type": "relativeMonthly", "daysOfWeek": "monday", "index": "first"],
              card: "monthly on the first Monday"),
        .init(name: "monthly on the last Friday",
              fields: ["freq": .string("MONTHLY"), "byDay": .array([.string("-1FR")])],
              rrule: "RRULE:FREQ=MONTHLY;BYDAY=-1FR",
              graph: ["type": "relativeMonthly", "daysOfWeek": "friday", "index": "last"],
              card: "monthly on the last Friday"),
        .init(name: "monthly on the 15th",
              fields: ["freq": .string("MONTHLY"), "byMonthDay": .array([.int(15)])],
              rrule: "RRULE:FREQ=MONTHLY;BYMONTHDAY=15",
              graph: ["type": "absoluteMonthly", "dayOfMonth": "15"],
              card: "monthly on day 15"),
        .init(name: "yearly on 10 March",
              fields: ["freq": .string("YEARLY"), "byMonth": .array([.int(3)]), "byMonthDay": .array([.int(10)])],
              rrule: "RRULE:FREQ=YEARLY;BYMONTHDAY=10;BYMONTH=3",
              graph: ["type": "absoluteYearly", "month": "3", "dayOfMonth": "10"],
              card: "yearly on day 10 in March"),
        .init(name: "every other week on Tuesday and Thursday, weeks starting Monday",
              fields: ["freq": .string("WEEKLY"), "interval": .int(2),
                       "byDay": .array([.string("TU"), .string("TH")]), "wkst": .string("MO")],
              rrule: "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;WKST=MO",
              graph: ["type": "weekly", "interval": "2", "daysOfWeek": "tuesday,thursday", "firstDayOfWeek": "monday"],
              card: "every 2 weeks on Tuesday, Thursday week starts Monday"),
    ]
}

/// One invalid field: the tool fields, and the field and value the refusal must name.
struct InvalidRecurrenceCase: CustomTestStringConvertible, Sendable {
    let fields: [String: JSONValue]
    let field: String
    let value: String
    var testDescription: String { "\(field) \(value)" }

    static let all: [InvalidRecurrenceCase] = [
        .init(fields: ["freq": .string("WEEKLY"), "byDay": .array([.string("XX")])], field: "byDay", value: "\"XX\""),
        .init(fields: ["freq": .string("MONTHLY"), "byDay": .array([.string("0MO")])], field: "byDay", value: "\"0MO\""),
        .init(fields: ["freq": .string("MONTHLY"), "byDay": .array([.string("54MO")])], field: "byDay", value: "\"54MO\""),
        .init(fields: ["freq": .string("WEEKLY"), "byDay": .array([.string("1MO")])], field: "byDay", value: "\"1MO\""),
        .init(fields: ["freq": .string("WEEKLY"), "byDay": .string("MO,WE")], field: "byDay", value: "\"MO,WE\""),
        .init(fields: ["freq": .string("MONTHLY"), "byMonthDay": .array([.int(0)])], field: "byMonthDay", value: "0"),
        .init(fields: ["freq": .string("MONTHLY"), "byMonthDay": .array([.int(32)])], field: "byMonthDay", value: "32"),
        .init(fields: ["freq": .string("MONTHLY"), "byMonthDay": .array([.double(1.5)])], field: "byMonthDay", value: "1.5"),
        .init(fields: ["freq": .string("WEEKLY"), "byMonthDay": .array([.int(15)])], field: "byMonthDay", value: "[15]"),
        .init(fields: ["freq": .string("YEARLY"), "byMonth": .array([.int(13)])], field: "byMonth", value: "13"),
        .init(fields: ["freq": .string("WEEKLY"), "wkst": .string("XX")], field: "wkst", value: "\"XX\""),
        .init(fields: ["freq": .string("FORTNIGHTLY")], field: "freq", value: "\"FORTNIGHTLY\""),
        .init(fields: ["byDay": .array([.string("MO")])], field: "freq", value: "missing"),
    ] + until

    /// An invalid `until` is refused like every other field, never dropped (which would save an
    /// endless series in place of a bounded one).
    static let until: [InvalidRecurrenceCase] = [
        .init(fields: ["freq": .string("WEEKLY"), "until": .string("next friday")], field: "until", value: "\"next friday\""),
        .init(fields: ["freq": .string("WEEKLY"), "until": .string("2099-02-30")], field: "until", value: "\"2099-02-30\""),
        .init(fields: ["freq": .string("WEEKLY"), "until": .string("2099-12-31T25:00:00")], field: "until", value: "\"2099-12-31T25:00:00\""),
        .init(fields: ["freq": .string("WEEKLY"), "until": .int(20991231)], field: "until", value: "20991231"),
    ]
}

private func args(_ fields: [String: JSONValue]) -> [String: JSONValue] {
    [
        "title": .string("Sync"),
        "start_iso": .string("2099-03-02T10:00:00"),
        "end_iso": .string("2099-03-02T11:00:00"),
        "timezone": .string("UTC"),
        "recurrence": .dictionary(fields),
    ]
}

/// A Graph pattern's values as the cases spell them: a list joined by commas, anything else as text.
private func graphPattern(_ recurrence: Any?) -> [String: String] {
    guard let pattern = (recurrence as? [String: Any])?["pattern"] as? [String: Any] else { return [:] }
    return pattern.mapValues { value in
        if let list = value as? [String] { return list.joined(separator: ",") }
        return "\(value)"
    }
}

private func matches(_ pattern: [String: String], _ expected: [String: String]) -> Bool {
    expected.allSatisfy { pattern[$0.key] == $0.value }
}

// MARK: - The writer and the card

@Suite("A repeat rule's days: the writer, the card and the refusals")
struct RecurrenceDaysWriterTests {

    @Test("the writer keeps every field", arguments: RecurrenceDaysCase.all)
    func writerKeepsEveryField(_ c: RecurrenceDaysCase) throws {
        let input = try CalendarToolHelpers.buildGCalEventInput(args(c.fields), isAllDay: false)
        #expect(input.recurrence == [c.rrule], "written: \(input.recurrence ?? [])")
    }

    @Test("the confirmation card names the days", arguments: RecurrenceDaysCase.all)
    func cardNamesTheDays(_ c: RecurrenceDaysCase) throws {
        #expect(try CalendarToolHelpers.recurrenceSummary(args(c.fields)) == c.card)
    }

    @Test("an end and a lowercase token are kept beside the days")
    func endAndCaseAreKept() throws {
        let fields: [String: JSONValue] = [
            "freq": .string("weekly"), "count": .int(6), "byDay": .array([.string("mo"), .string("+2we")]),
        ]
        // A position is refused with WEEKLY; the same tokens with MONTHLY are written canonically.
        #expect(throws: CalendarProviderError.self) { try CalendarToolHelpers.buildGCalEventInput(args(fields), isAllDay: false) }
        var monthly = fields
        monthly["freq"] = .string("monthly")
        let input = try CalendarToolHelpers.buildGCalEventInput(args(monthly), isAllDay: false)
        #expect(input.recurrence == ["RRULE:FREQ=MONTHLY;COUNT=6;BYDAY=MO,2WE"], "written: \(input.recurrence ?? [])")
        let until = try CalendarToolHelpers.buildGCalEventInput(
            args(["freq": .string("WEEKLY"), "until": .string("2099-06-30"), "byDay": .array([.string("FR")])]), isAllDay: true)
        #expect(until.recurrence == ["RRULE:FREQ=WEEKLY;UNTIL=20990630;BYDAY=FR"], "written: \(until.recurrence ?? [])")
    }

    @Test("an empty or null day field writes nothing and a null-only rule sets none")
    func emptyFieldsWriteNothing() throws {
        let input = try CalendarToolHelpers.buildGCalEventInput(
            args(["freq": .string("DAILY"), "byDay": .array([]), "byMonthDay": .null, "wkst": .null]), isAllDay: false)
        #expect(input.recurrence == ["RRULE:FREQ=DAILY"])
        let none = try CalendarToolHelpers.buildGCalEventInput(args(["freq": .null]), isAllDay: false)
        #expect(none.recurrence == nil)
    }

    @Test("the card names a day counted from the month's end and a fifth weekday plainly", arguments: [
        (["freq": JSONValue.string("MONTHLY"), "byMonthDay": .array([.int(-1)])], "monthly on the last day"),
        (["freq": JSONValue.string("MONTHLY"), "byMonthDay": .array([.int(-2)])], "monthly on the second to last day"),
        (["freq": JSONValue.string("MONTHLY"), "byDay": .array([.string("5MO")])], "monthly on the fifth Monday"),
        (["freq": JSONValue.string("MONTHLY"), "byDay": .array([.string("-2FR")])], "monthly on the second to last Friday"),
    ] as [([String: JSONValue], String)])
    func cardNamesPositions(_ fields: [String: JSONValue], _ card: String) throws {
        #expect(try CalendarToolHelpers.recurrenceSummary(args(fields)) == card)
    }

    @Test("the card shows a valid until, and a count instead of an until when both are given", arguments: [
        (["freq": JSONValue.string("WEEKLY"), "until": .string("2099-12-31")], "weekly (until 2099-12-31)"),
        (["freq": JSONValue.string("WEEKLY"), "count": .int(5), "until": .string("2099-12-31")], "weekly (5 times)"),
    ] as [([String: JSONValue], String)])
    func cardShowsUntil(_ fields: [String: JSONValue], _ card: String) throws {
        #expect(try CalendarToolHelpers.recurrenceSummary(args(fields)) == card)
    }

    @Test("an invalid field is refused by the writer and the card, naming the field and the value",
          arguments: InvalidRecurrenceCase.all)
    func invalidFieldIsRefused(_ c: InvalidRecurrenceCase) {
        for (label, run) in [
            ("writer", { _ = try CalendarToolHelpers.buildGCalEventInput(args(c.fields), isAllDay: false) }),
            ("card", { _ = try CalendarToolHelpers.recurrenceSummary(args(c.fields)) }),
        ] as [(String, () throws -> Void)] {
            do {
                try run()
                Issue.record("the \(label) accepted recurrence.\(c.field) \(c.value)")
            } catch CalendarProviderError.notSupported(let reason) {
                #expect(reason.contains("recurrence.\(c.field)"), "\(label) reason: \(reason)")
                #expect(reason.contains(c.value), "\(label) reason does not name the value: \(reason)")
            } catch {
                Issue.record("the \(label) threw \(error)")
            }
        }
    }
}

// MARK: - What Outlook can hold

@Suite("A repeat rule Outlook can't hold is refused by name; everyday rules are not")
struct GraphRecurrenceRefusalTests {

    @Test("every everyday rule maps to a Graph pattern", arguments: RecurrenceDaysCase.all)
    func everydayRulesAreHeld(_ c: RecurrenceDaysCase) throws {
        #expect(ExchangeCalendarProvider.graphRecurrenceRefusal(c.rrule) == nil)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "t" })
        let mapped = provider.parseRRULEToGraphRecurrence(c.rrule, eventStart: nil, timeZone: TimeZone(identifier: "UTC")!, startWallTime: nil)
        let pattern = graphPattern(mapped)
        #expect(matches(pattern, c.graph), "pattern: \(pattern)")
    }

    @Test("a rule outside Graph's pattern types is refused naming the field", arguments: [
        ("RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15", "byMonthDay"),
        ("RRULE:FREQ=MONTHLY;BYMONTHDAY=-1", "byMonthDay"),
        ("RRULE:FREQ=MONTHLY;BYDAY=MO", "byDay"),
        ("RRULE:FREQ=MONTHLY;BYDAY=1MO,3MO", "byDay"),
        ("RRULE:FREQ=MONTHLY;BYDAY=5MO", "byDay"),
        ("RRULE:FREQ=MONTHLY;BYDAY=-2FR", "byDay"),
        ("RRULE:FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13", "byMonthDay"),
        ("RRULE:FREQ=MONTHLY;BYMONTHDAY=15;BYMONTH=3", "byMonth"),
        ("RRULE:FREQ=YEARLY;BYMONTH=3,9;BYMONTHDAY=10", "byMonth"),
        ("RRULE:FREQ=YEARLY;BYMONTHDAY=10", "byMonthDay"),
        ("RRULE:FREQ=YEARLY;BYDAY=1MO", "byDay"),
        ("RRULE:FREQ=DAILY;BYDAY=MO,TU", "byDay"),
        ("RRULE:FREQ=DAILY;BYMONTHDAY=1", "byMonthDay"),
        ("RRULE:FREQ=WEEKLY;BYDAY=MO;BYMONTH=3", "byMonth"),
    ])
    func unrepresentableRuleIsRefused(_ rrule: String, _ field: String) {
        let reason = ExchangeCalendarProvider.graphRecurrenceRefusal(rrule)
        #expect(reason?.contains("recurrence.\(field)") == true, "\(rrule): \(reason ?? "<held>")")
    }

    @Test("Outlook names the last day of the month plainly")
    func lastDayOfTheMonthIsNamedPlainly() {
        let last = ExchangeCalendarProvider.graphRecurrenceRefusal("RRULE:FREQ=MONTHLY;BYMONTHDAY=-1")
        #expect(last?.contains("can't repeat on the last day of the month, so recurrence.byMonthDay [-1]") == true, "\(last ?? "<held>")")
        let other = ExchangeCalendarProvider.graphRecurrenceRefusal("RRULE:FREQ=MONTHLY;BYMONTHDAY=-2")
        #expect(other?.contains("can't repeat on a day counted from the end of the month, so recurrence.byMonthDay [-2]") == true,
                "\(other ?? "<held>")")
    }

    @Test("Google and CalDAV hold every valid rule")
    func otherProvidersHoldEveryRule() {
        let google = GoogleCalendarProvider(accessToken: { _ in "t" })
        #expect(google.recurrenceRuleRefusal("RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15") == nil)
    }
}

// MARK: - On the wire, through the queue

/// One operation drained through `AccountManager.drainCalendarQueue` against `provider`, and the
/// durable rows afterwards.
private func drain(
    _ type: CalendarOperationType,
    accountId: String,
    eventId: String,
    calendarId: String,
    arguments: [String: JSONValue],
    provider: any CalendarProvider
) async throws -> [PendingCalendarOperation] {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var config = Configuration()
    config.foreignKeysEnabled = true
    let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
    let appDb = try AppDatabase(dbPool: pool)
    let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
        let prev = current; current = appDb; return prev
    }
    try await pool.write { db in
        var acc = Account(emailAddress: "cal@example.com", displayName: "Cal", provider: .gmail)
        acc.id = accountId
        try acc.insert(db)
    }
    await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: provider)
    defer {
        Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }
    let op = PendingCalendarOperation(
        operationType: type, accountId: accountId, eventId: eventId,
        calendarId: calendarId, arguments: arguments)
    try await pool.write { db in try op.insert(db) }
    await AccountManager.shared.drainCalendarQueue()
    return try await pool.read { db in try PendingCalendarOperation.fetchAll(db) }
}

private let exdate = "EXDATE:20990309T100000Z"
private let rdate = "RDATE:20990311T100000Z"

@Suite("A repeat rule's days reach the calendar: Google", .serialized, .processGlobalState)
struct GoogleRecurrenceDaysWireTests {

    private func provider(_ http: FakeHTTP.Scenario) -> GoogleCalendarProvider {
        GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
    }

    private static func series() -> [String: Any] {
        [
            "id": "ser-g", "summary": "Sync", "status": "confirmed",
            "start": ["dateTime": "2099-03-02T10:00:00Z", "timeZone": "UTC"],
            "end": ["dateTime": "2099-03-02T11:00:00Z", "timeZone": "UTC"],
            "recurrence": ["RRULE:FREQ=WEEKLY", exdate, rdate],
        ]
    }

    @Test("a create writes the whole rule", arguments: RecurrenceDaysCase.all)
    func createWritesTheRule(_ c: RecurrenceDaysCase) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let calendar = FakeGoogleCalendar([])
        calendar.install(on: http)
        let rows = try await drain(.create, accountId: "rd-g-create", eventId: "rdgcreate0001", calendarId: "primary",
                                   arguments: args(c.fields), provider: provider(http))
        #expect(rows.isEmpty, "the create did not complete: \(rows.map { $0.failureReason ?? $0.status })")
        #expect(calendar.event("rdgcreate0001")?["recurrence"] as? [String] == [c.rrule],
                "stored: \(calendar.event("rdgcreate0001")?["recurrence"] ?? "none")")
    }

    @Test("an edit writes the whole rule and keeps the series' excluded and added dates", arguments: RecurrenceDaysCase.all)
    func editWritesTheRuleAndKeepsDates(_ c: RecurrenceDaysCase) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let calendar = FakeGoogleCalendar([Self.series()])
        calendar.install(on: http)
        let rows = try await drain(.edit, accountId: "rd-g-edit", eventId: "ser-g", calendarId: "primary",
                                   arguments: ["recurrence": .dictionary(c.fields), "timezone": .string("UTC")],
                                   provider: provider(http))
        #expect(rows.isEmpty, "the edit did not complete: \(rows.map { $0.failureReason ?? $0.status })")
        #expect(calendar.event("ser-g")?["recurrence"] as? [String] == [c.rrule, exdate, rdate],
                "stored: \(calendar.event("ser-g")?["recurrence"] ?? "none")")
    }

    @Test("an invalid field is refused at the drain with nothing sent")
    func invalidFieldSendsNothing() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let calendar = FakeGoogleCalendar([Self.series()])
        calendar.install(on: http)
        let rows = try await drain(.edit, accountId: "rd-g-bad", eventId: "ser-g", calendarId: "primary",
                                   arguments: ["recurrence": .dictionary(["freq": .string("WEEKLY"), "byDay": .array([.string("XX")])])],
                                   provider: provider(http))
        #expect(calendar.writes.isEmpty, "writes: \(calendar.writes)")
        #expect(rows.first?.failureReason?.contains("recurrence.byDay") == true,
                "reason: \(rows.first?.failureReason ?? "<none>")")
    }
}

@Suite("A repeat rule's days reach the calendar: Outlook", .serialized, .processGlobalState)
struct ExchangeRecurrenceDaysWireTests {

    private func provider(_ http: FakeHTTP.Scenario) -> ExchangeCalendarProvider {
        ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" }, session: http.session)
    }

    @Test("a create writes the whole rule", arguments: RecurrenceDaysCase.all)
    func createWritesTheRule(_ c: RecurrenceDaysCase) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar([])
        graph.install(on: http)
        let rows = try await drain(.create, accountId: "rd-x-create", eventId: "rdxcreate0001", calendarId: "primary",
                                   arguments: args(c.fields), provider: provider(http))
        #expect(rows.isEmpty, "the create did not complete: \(rows.map { $0.failureReason ?? $0.status })")
        #expect(graph.created.count == 1)
        guard graph.created.count == 1 else { return }
        let pattern = graphPattern(graph.created[0]["recurrence"])
        #expect(matches(pattern, c.graph), "pattern: \(pattern)")
    }

    @Test("an edit writes the whole rule", arguments: RecurrenceDaysCase.all)
    func editWritesTheRule(_ c: RecurrenceDaysCase) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar([GraphFixture.event(id: "ser-x", online: false, recurring: true)])
        graph.install(on: http)
        let rows = try await drain(.edit, accountId: "rd-x-edit", eventId: "ser-x", calendarId: "primary",
                                   arguments: ["recurrence": .dictionary(c.fields), "timezone": .string("UTC")],
                                   provider: provider(http))
        #expect(rows.isEmpty, "the edit did not complete: \(rows.map { $0.failureReason ?? $0.status })")
        let pattern = graphPattern(graph.event("ser-x")?["recurrence"])
        #expect(matches(pattern, c.graph), "pattern: \(pattern)")
    }

    @Test("a rule Outlook can't hold is refused at the writer with nothing sent")
    func unrepresentableRuleSendsNothing() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar([GraphFixture.event(id: "ser-x2", online: false, recurring: true)])
        graph.install(on: http)
        let rows = try await drain(.edit, accountId: "rd-x-refuse", eventId: "ser-x2", calendarId: "primary",
                                   arguments: ["recurrence": .dictionary(["freq": .string("MONTHLY"), "byMonthDay": .array([.int(1), .int(15)])]),
                                               "timezone": .string("UTC")],
                                   provider: provider(http))
        #expect(graph.patches("ser-x2").isEmpty, "a different series was written: \(graph.patches("ser-x2"))")
        #expect(rows.first?.failureReason?.contains("recurrence.byMonthDay") == true,
                "reason: \(rows.first?.failureReason ?? "<none>")")
    }

    @Test("a create or a this-and-following edit with a rule Outlook can't hold sends nothing", arguments: ["create", "split"])
    func unrepresentableRuleIsRefusedByEveryWriter(_ writer: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar([GraphFixture.event(id: "ser-x3", online: false, recurring: true)])
        graph.install(on: http)
        let outlook = provider(http)
        var input = GCalEventInput()
        input.summary = "Sync"
        input.startDateTime = "2099-03-02T10:00:00Z"
        input.startTimeZone = "UTC"
        input.endDateTime = "2099-03-02T11:00:00Z"
        input.endTimeZone = "UTC"
        input.recurrence = ["RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15"]
        do {
            if writer == "create" {
                _ = try await outlook.createEvent(event: input)
            } else {
                _ = try await outlook.splitSeries(eventId: "ser-x3", recurrenceId: "2099-03-16T10:00:00",
                                                  recurrenceIdZone: TimeZone(identifier: "UTC")!, patch: input)
            }
            Issue.record("\(writer): a rule Outlook can't hold was accepted")
        } catch CalendarProviderError.notSupported(let reason) {
            #expect(reason.contains("recurrence.byMonthDay [1,15]"), "\(writer) reason: \(reason)")
        } catch {
            Issue.record("\(writer) threw \(error)")
        }
        let writes = http.recordedCalls().map(\.method).filter { $0 == "POST" || $0 == "PATCH" }
        #expect(writes.isEmpty, "\(writer): sent \(writes)")
        #expect(graph.created.isEmpty && graph.patches("ser-x3").isEmpty)
    }
}

@Suite("A repeat rule's days reach the calendar: CalDAV", .serialized, .processGlobalState)
struct CalDAVRecurrenceDaysWireTests {

    private static let home = URL(string: "https://caldav.example.com/cal/")!

    private func provider(_ http: FakeHTTP.Scenario, _ store: FakeCalDAVStore) -> CalDAVProvider {
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
        return CalDAVProvider(
            client: CalDAVClient(username: "user@example.com", password: "pw", session: http.session),
            calendarHomeURL: Self.home, serverBaseURL: Self.home)
    }

    private func rrule(_ ics: String?) -> String? {
        ics?.components(separatedBy: "\r\n").first { $0.hasPrefix("RRULE") }
    }

    @Test("a create writes the whole rule", arguments: RecurrenceDaysCase.all)
    func createWritesTheRule(_ c: RecurrenceDaysCase) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        let rows = try await drain(.create, accountId: "rd-c-create", eventId: "rdccreate0001", calendarId: "/cal/",
                                   arguments: args(c.fields), provider: provider(http, store))
        #expect(rows.isEmpty, "the create did not complete: \(rows.map { $0.failureReason ?? $0.status })")
        let puts = store.recordedPuts()
        #expect(puts.count == 1)
        guard puts.count == 1 else { return }
        #expect(rrule(store.storedICS(path: puts[0].path)) == c.rrule)
    }

    @Test("an edit writes the whole rule and keeps the series' excluded and added dates", arguments: RecurrenceDaysCase.all)
    func editWritesTheRule(_ c: RecurrenceDaysCase) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: "/cal/ser-c.ics", ics: [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
            "UID:ser-c", "DTSTAMP:20990101T000000Z", "DTSTART:20990302T100000Z", "DTEND:20990302T110000Z",
            "SUMMARY:Sync", "RRULE:FREQ=WEEKLY", exdate, rdate, "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n"))
        let rows = try await drain(.edit, accountId: "rd-c-edit", eventId: "/cal/ser-c.ics", calendarId: "/cal/",
                                   arguments: ["recurrence": .dictionary(c.fields), "timezone": .string("UTC")],
                                   provider: provider(http, store))
        #expect(rows.isEmpty, "the edit did not complete: \(rows.map { $0.failureReason ?? $0.status })")
        let ics = store.storedICS(path: "/cal/ser-c.ics")
        #expect(rrule(ics) == c.rrule, "stored: \(rrule(ics) ?? "<none>")")
        let lines = ics?.components(separatedBy: "\r\n") ?? []
        #expect(lines.contains(exdate) && lines.contains(rdate), "dates: \(lines)")
    }
}

// MARK: - Before the card, through the tools

@MainActor
@Suite("A repeat rule is checked before the confirmation card", .serialized, .processGlobalState)
struct RecurrenceDaysToolTests {

    @MainActor
    private final class RecordingConfirmSink: AgentUISink {
        var calendarEvents: [AgentToolRouter.ActionConfirmation.CalendarEventDetail] = []
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            calendarEvents.append(contentsOf: confirmation.calendarEvents)
            confirmation.onRespond(true)
        }
    }

    private static let preferenceKeys = [
        CalendarProviderDispatch.preferredCalendarAccountKey,
        CalendarProviderDispatch.preferredGoogleAccountKey,
        CalendarProviderDispatch.preferredCalendarKey,
        CalendarProviderDispatch.preferredGoogleCalendarKey,
    ]

    /// Installs a fresh shared database with one active account whose calendar is `provider`, made
    /// the preferred calendar account, runs `body`, then restores every global it touched.
    private func withCalendar(_ provider: any CalendarProvider, _ body: (DatabasePool) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        let accountId = "rd-tool-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        let priorPreferences = Self.preferenceKeys.map { defaults.string(forKey: $0) }
        let priorDemoActive = DemoModeStore.shared.isActive
        var failure: Error?
        do {
            try await pool.write { db in
                var account = Account(emailAddress: "cal@example.com", displayName: "Test", provider: .gmail)
                account.id = accountId
                account.isActive = true
                try account.insert(db)
            }
            await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: provider)
            DemoModeStore.shared.isActive = false
            for key in Self.preferenceKeys { defaults.removeObject(forKey: key) }
            defaults.set(accountId, forKey: CalendarProviderDispatch.preferredCalendarAccountKey)
            try await body(pool)
        } catch {
            failure = error
        }
        for (key, value) in zip(Self.preferenceKeys, priorPreferences) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        DemoModeStore.shared.isActive = priorDemoActive
        await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId)
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        if let failure { throw failure }
    }

    private static func event(id: String) -> GCalEvent {
        GCalEvent(
            id: id, summary: "Sync", location: nil, description: nil,
            start: nil, end: nil, attendees: nil, organizer: nil, recurrence: ["RRULE:FREQ=WEEKLY"],
            transparency: nil, status: "confirmed", htmlLink: nil, created: nil, updated: nil
        )
    }

    private func create(_ pool: DatabasePool, _ fields: [String: JSONValue], sink: RecordingConfirmSink) async throws -> String {
        try await CalendarEventCreateTool(context: ToolContext(db: pool, translator: MockChatIdTranslator())).execute(
            arguments: args(fields), invocation: ToolInvocation(uiSink: sink, sessionKey: "rd-create"))
    }

    private func edit(_ pool: DatabasePool, _ fields: [String: JSONValue], sink: RecordingConfirmSink) async throws -> String {
        try await CalendarEventEditTool(context: ToolContext(db: pool, translator: MockChatIdTranslator())).execute(
            arguments: ["event_id": .string("evt-series"), "recurrence": .dictionary(fields)],
            invocation: ToolInvocation(uiSink: sink, sessionKey: "rd-edit"))
    }

    @Test("the create and edit cards name the days", arguments: RecurrenceDaysCase.all)
    func cardsNameTheDays(_ c: RecurrenceDaysCase) async throws {
        let mock = MockCalendarProvider()
        await mock.setCreateEventResult(Self.event(id: "evt-created"))
        await mock.setGetEventResult(Self.event(id: "evt-series"))
        try await withCalendar(mock) { pool in
            let sink = RecordingConfirmSink()
            _ = try await create(pool, c.fields, sink: sink)
            _ = try await edit(pool, c.fields, sink: sink)
            #expect(sink.calendarEvents.count == 2, "cards shown: \(sink.calendarEvents.count)")
            guard sink.calendarEvents.count == 2 else { return }
            #expect(sink.calendarEvents[0].changes.contains("recurrence: \(c.card)"), "create card: \(sink.calendarEvents[0].changes)")
            #expect(sink.calendarEvents[1].changes.contains("recurrence → \(c.card)"), "edit card: \(sink.calendarEvents[1].changes)")
            let created = await mock.createdEvents
            #expect(created.count == 1)
            guard created.count == 1 else { return }
            #expect(created[0].event.recurrence == [c.rrule], "created: \(created[0].event.recurrence ?? [])")
        }
    }

    @Test("an invalid field is refused before the create and edit cards, naming it, with nothing sent",
          arguments: InvalidRecurrenceCase.all)
    func invalidFieldRefusedBeforeTheCard(_ c: InvalidRecurrenceCase) async throws {
        let mock = MockCalendarProvider()
        await mock.setGetEventResult(Self.event(id: "evt-series"))
        try await withCalendar(mock) { pool in
            let sink = RecordingConfirmSink()
            for output in [try await create(pool, c.fields, sink: sink), try await edit(pool, c.fields, sink: sink)] {
                #expect(output.contains("recurrence.\(c.field)"), "tool said: \(output)")
                #expect(output.contains(c.value.replacingOccurrences(of: "\"", with: "\\\"")) || output.contains(c.value),
                        "the refusal does not name the value: \(output)")
            }
            #expect(sink.calendarEvents.isEmpty, "a card was shown for an invalid rule")
            let created = await mock.createdEvents
            let updated = await mock.updatedEvents
            #expect(created.isEmpty && updated.isEmpty)
        }
    }

    @Test("an edit whose start or end names no time is refused before the card, naming it, with nothing sent (#719)",
          arguments: ["start_iso", "end_iso"])
    func unreadableTimeRefusedBeforeTheCard(_ key: String) async throws {
        let mock = MockCalendarProvider()
        await mock.setGetEventResult(Self.event(id: "evt-series"))
        try await withCalendar(mock) { pool in
            let sink = RecordingConfirmSink()
            let output = try await CalendarEventEditTool(context: ToolContext(db: pool, translator: MockChatIdTranslator())).execute(
                arguments: ["event_id": .string("evt-series"), key: .string("next Tuesday T9"), "timezone": .string("America/New_York")],
                invocation: ToolInvocation(uiSink: sink, sessionKey: "rd-edit-time"))
            #expect(output.contains(key) && output.contains("next Tuesday T9") && output.contains("NOT changed"), "tool said: \(output)")
            #expect(sink.calendarEvents.isEmpty, "a card was shown for a time that names no instant")
            let updated = await mock.updatedEvents
            #expect(updated.isEmpty)
        }
    }

    @Test("an invalid until is refused before the create and edit cards on Google, Outlook and CalDAV, with nothing sent",
          arguments: ["google", "outlook", "caldav"])
    func invalidUntilRefusedOnEveryCalendar(_ calendar: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let provider: any CalendarProvider
        switch calendar {
        case "google":
            FakeGoogleCalendar([]).install(on: http)
            provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        case "outlook":
            FakeGraphCalendar([]).install(on: http)
            provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" }, session: http.session)
        default:
            let store = FakeCalDAVStore(servesETags: true)
            let home = URL(string: "https://caldav.example.com/cal/")!
            http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
            http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
            provider = CalDAVProvider(
                client: CalDAVClient(username: "user@example.com", password: "pw", session: http.session),
                calendarHomeURL: home, serverBaseURL: home)
        }
        try await withCalendar(provider) { pool in
            for c in InvalidRecurrenceCase.until {
                let sink = RecordingConfirmSink()
                for output in [try await create(pool, c.fields, sink: sink), try await edit(pool, c.fields, sink: sink)] {
                    #expect(output.contains("recurrence.until"), "\(calendar) \(c.value): \(output)")
                    #expect(output.contains(c.value.replacingOccurrences(of: "\"", with: "\\\"")) || output.contains(c.value),
                            "\(calendar): the refusal does not name \(c.value): \(output)")
                }
                #expect(sink.calendarEvents.isEmpty, "\(calendar) \(c.value): a card was shown")
            }
        }
        let writes = http.recordedCalls().map(\.method).filter { $0 != "GET" && $0 != "PROPFIND" && $0 != "REPORT" }
        #expect(writes.isEmpty, "\(calendar): sent \(writes)")
    }

    @Test("a rule Outlook can't hold is refused before the create and edit cards, naming the field")
    func outlookRefusalBeforeTheCard() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar([])
        graph.install(on: http)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" }, session: http.session)
        let fields: [String: JSONValue] = ["freq": .string("MONTHLY"), "byMonthDay": .array([.int(1), .int(15)])]
        try await withCalendar(provider) { pool in
            let sink = RecordingConfirmSink()
            for output in [try await create(pool, fields, sink: sink), try await edit(pool, fields, sink: sink)] {
                #expect(output.contains("recurrence.byMonthDay [1,15]"), "tool said: \(output)")
            }
            #expect(sink.calendarEvents.isEmpty, "a card was shown for a rule Outlook can't hold")
            #expect(graph.created.isEmpty)
        }
    }

    @Test("the same rule is shown and written on a calendar that holds it (control)")
    func otherCalendarsHoldTheRule() async throws {
        let mock = MockCalendarProvider()
        await mock.setCreateEventResult(Self.event(id: "evt-created"))
        let fields: [String: JSONValue] = ["freq": .string("MONTHLY"), "byMonthDay": .array([.int(1), .int(15)])]
        try await withCalendar(mock) { pool in
            let sink = RecordingConfirmSink()
            _ = try await create(pool, fields, sink: sink)
            #expect(sink.calendarEvents.count == 1)
            guard sink.calendarEvents.count == 1 else { return }
            #expect(sink.calendarEvents[0].changes.contains("recurrence: monthly on day 1, day 15"), "\(sink.calendarEvents[0].changes)")
            let created = await mock.createdEvents
            #expect(created.first?.event.recurrence == ["RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15"])
        }
    }
}
