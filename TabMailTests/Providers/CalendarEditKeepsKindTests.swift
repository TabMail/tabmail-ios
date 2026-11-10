/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

// MARK: - A calendar edit keeps the event's kind
//
// **INVARIANT.** *An edit that leaves `all_day` out keeps the event's kind.* An all-day event given
// new dates stays all-day on those dates (a time of day in them is dropped); a timed event given a
// date alone stays timed, at midnight. Only an `all_day` the edit states changes the kind, both ways.
// `calendar_event_edit` documents `all_day` as "Omit to keep existing".
//
// The defect: `AccountManagerCalendarQueue`'s `.edit` case resolved a missing `all_day` from the event
// only when an RRULE UNTIL was at stake, so a plain move rendered its dates as `startDateTime` /
// `endDateTime`. Google and Outlook then saved the all-day event as a timed one, and CalDAV left it
// where it was. The Thunderbird add-on had the same defect and the same rule fixes it there.
//
// **A SECOND INVARIANT, its companion.** *No all-day edit is written whose end is on or before its
// start* (an all-day end is the day after the last day). Once a missing `all_day` resolves to all-day,
// a move given times of one day would otherwise write a zero-length event; `all_day: true` with a
// same-day end already did. Refused before anything is written, on every `edit_scope`; an edit that
// gives no times is not checked.
//
// The assertions run on what the PROVIDER ends up holding (Google and Graph fakes that apply PATCH
// semantics, a CalDAV resource store) or, where only the queue can say it, on what reached the
// provider and on the durable row. Every date is relative to today, in UTC.

private let utc = TimeZone(identifier: "UTC")!

/// The UTC date `offset` days after the day two weeks from today, as `yyyy-MM-dd`.
private func day(_ offset: Int) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    let base = cal.startOfDay(for: Date().addingTimeInterval(14 * 86_400))
    let date = cal.date(byAdding: .day, value: offset, to: base)!
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = utc
    fmt.dateFormat = "yyyy-MM-dd"
    return fmt.string(from: date)
}

private func compact(_ day: String) -> String { day.replacingOccurrences(of: "-", with: "") }

/// The refusal the queue and the edit tool give an all-day end on or before its start.
private let allDayEndHint = "an all-day event's end_iso is the day after its last day, so it must be later than start_iso"

// MARK: - A stateful Google calendar

/// An in-memory Google calendar: `GET` returns the stored event (or a series' instances), `PATCH`
/// replaces each top-level property the body names (Google's patch semantics: a supplied `start`
/// replaces the stored `start` whole), and `POST` stores a new event under the `id` it carries.
final class FakeGoogleCalendar: Sendable {
    private let events: Mutex<[String: Data]>
    private let writeLog = Mutex<[String]>([])

    init(_ seed: [[String: Any]]) {
        var map: [String: Data] = [:]
        for event in seed {
            // swiftlint:disable:next force_try force_cast
            map[event["id"] as! String] = try! JSONSerialization.data(withJSONObject: event)
        }
        events = Mutex(map)
    }

    func event(_ id: String) -> [String: Any]? {
        guard let data = events.withLock({ $0[id] }) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `"PATCH <id>"` / `"POST <id>"` for every write that landed, in order.
    var writes: [String] { writeLog.withLock { $0 } }

    var ids: Set<String> { events.withLock { Set($0.keys) } }

    func install(on http: FakeHTTP.Scenario) {
        let prefix = "/calendar/v3/calendars/primary/events"
        http.register(path: prefix + "/", method: "GET") { [self] request in
            let parts = Self.pathParts(request.url)
            if parts.count == 2, parts[1] == "instances" {
                let items = events.withLock { Array($0.values) }
                    .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                    .filter { $0["recurringEventId"] as? String == parts[0] }
                return Self.json(["items": items])
            }
            guard parts.count == 1, let stored = event(parts[0]) else { return .status(404) }
            return Self.json(stored)
        }
        http.register(path: prefix + "/", method: "PATCH") { [self] request in
            let parts = Self.pathParts(request.url)
            guard parts.count == 1, var stored = event(parts[0]), let body = request.body,
                  let patch = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            else { return .status(400) }
            for (key, value) in patch { stored[key] = value }
            store(stored)
            writeLog.withLock { $0.append("PATCH \(parts[0])") }
            return Self.json(stored)
        }
        http.register(path: prefix, method: "POST") { [self] request in
            guard let body = request.body,
                  let created = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let id = created["id"] as? String
            else { return .status(400) }
            store(created)
            writeLog.withLock { $0.append("POST \(id)") }
            return Self.json(created)
        }
    }

    private func store(_ event: [String: Any]) {
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: event)
        // swiftlint:disable:next force_cast
        events.withLock { $0[event["id"] as! String] = data }
    }

    private static func pathParts(_ url: URL) -> [String] {
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "events") else { return [] }
        return Array(components[(index + 1)...])
    }

    private static func json(_ object: [String: Any]) -> FakeHTTP.CannedResponse {
        // swiftlint:disable:next force_try
        .raw(statusCode: 200, headers: ["Content-Type": "application/json"],
             body: try! JSONSerialization.data(withJSONObject: object))
    }

    static func allDay(id: String, start: String, end: String, recurring: Bool = false, master: String? = nil) -> [String: Any] {
        var e: [String: Any] = [
            "id": id, "summary": "Offsite", "status": "confirmed",
            "start": ["date": start], "end": ["date": end],
        ]
        if recurring { e["recurrence"] = ["RRULE:FREQ=WEEKLY"] }
        if let master { e["recurringEventId"] = master }
        return e
    }

    static func timed(id: String, day: String) -> [String: Any] {
        [
            "id": id, "summary": "Standup", "status": "confirmed",
            "start": ["dateTime": "\(day)T09:00:00Z", "timeZone": "UTC"],
            "end": ["dateTime": "\(day)T09:30:00Z", "timeZone": "UTC"],
        ]
    }
}

// MARK: - Driving the real queue

/// One edit drained through `AccountManager.drainCalendarQueue` against `provider`, and the durable
/// row afterwards.
private func drainEdit(
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
        operationType: .edit, accountId: accountId, eventId: eventId,
        calendarId: calendarId, arguments: arguments)
    try await pool.write { db in try op.insert(db) }

    await AccountManager.shared.drainCalendarQueue()

    return try await pool.read { db in try PendingCalendarOperation.fetchAll(db) }
}

private func start(_ event: [String: Any]?) -> [String: Any]? { event?["start"] as? [String: Any] }
private func end(_ event: [String: Any]?) -> [String: Any]? { event?["end"] as? [String: Any] }

// MARK: - Google

@Suite("A calendar edit without all_day keeps the event's kind: Google", .serialized, .processGlobalState)
struct GoogleCalendarEditKeepsKindTests {

    private func run(_ seed: [[String: Any]], eventId: String, _ arguments: [String: JSONValue], account: String)
        async throws -> (calendar: FakeGoogleCalendar, rows: [PendingCalendarOperation]) {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let calendar = FakeGoogleCalendar(seed)
        calendar.install(on: http)
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        let rows = try await drainEdit(accountId: account, eventId: eventId, calendarId: "primary",
                                       arguments: arguments, provider: provider)
        return (calendar, rows)
    }

    @Test("an all-day event given new dates without all_day stays all-day on those dates")
    func allDayMovedStaysAllDay() async throws {
        let r = try await run([FakeGoogleCalendar.allDay(id: "ad-1", start: day(0), end: day(1))], eventId: "ad-1", [
            "start_iso": .string("\(day(7))T00:00:00"), "end_iso": .string("\(day(8))T00:00:00"),
            "timezone": .string("UTC"),
        ], account: "kind-g-move")
        let after = r.calendar.event("ad-1")
        #expect(r.calendar.writes == ["PATCH ad-1"], "writes: \(r.calendar.writes)")
        #expect(start(after)?["date"] as? String == day(7), "start is \(start(after) ?? [:])")
        #expect(end(after)?["date"] as? String == day(8), "end is \(end(after) ?? [:])")
        #expect(start(after)?["dateTime"] == nil && end(after)?["dateTime"] == nil,
                "the all-day event was saved as a timed one: \(start(after) ?? [:]) to \(end(after) ?? [:])")
        #expect(r.rows.isEmpty, "the edit did not complete: \(r.rows.map { $0.failureReason ?? $0.status })")
    }

    @Test("an all-day event given only a new start stays all-day and keeps its length in days")
    func allDayStartAloneKeepsLength() async throws {
        let r = try await run([FakeGoogleCalendar.allDay(id: "ad-2", start: day(0), end: day(2))], eventId: "ad-2", [
            "start_iso": .string("\(day(7))T00:00:00"), "timezone": .string("UTC"),
        ], account: "kind-g-start")
        let after = r.calendar.event("ad-2")
        #expect(start(after)?["date"] as? String == day(7), "start is \(start(after) ?? [:])")
        #expect(end(after)?["date"] as? String == day(9), "a two-day event's end did not follow: \(end(after) ?? [:])")
        #expect(start(after)?["dateTime"] == nil, "saved as timed: \(start(after) ?? [:])")
    }

    @Test("an all-day event given a start with a time of day stays all-day on that start's date")
    func allDayStartWithTimeOfDayKeepsTheDate() async throws {
        let r = try await run([FakeGoogleCalendar.allDay(id: "ad-3", start: day(0), end: day(1))], eventId: "ad-3", [
            "start_iso": .string("\(day(7))T15:30:00"), "timezone": .string("UTC"),
        ], account: "kind-g-time")
        let after = r.calendar.event("ad-3")
        #expect(start(after)?["date"] as? String == day(7), "start is \(start(after) ?? [:])")
        #expect(end(after)?["date"] as? String == day(8), "end is \(end(after) ?? [:])")
        #expect(start(after)?["dateTime"] == nil, "the time of day made the event timed: \(start(after) ?? [:])")
    }

    @Test("moving one occurrence of an all-day series keeps that occurrence all-day")
    func allDayOccurrenceStaysAllDay() async throws {
        let r = try await run([
            FakeGoogleCalendar.allDay(id: "ser-ad", start: day(0), end: day(1), recurring: true),
            FakeGoogleCalendar.allDay(id: "ser-ad_occ", start: day(7), end: day(8), master: "ser-ad"),
        ], eventId: "ser-ad", [
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T00:00:00"),
            "start_iso": .string("\(day(9))T00:00:00"), "end_iso": .string("\(day(10))T00:00:00"),
            "timezone": .string("UTC"),
        ], account: "kind-g-occ")
        let occ = r.calendar.event("ser-ad_occ")
        #expect(r.calendar.writes == ["PATCH ser-ad_occ"], "writes: \(r.calendar.writes)")
        #expect(start(occ)?["date"] as? String == day(9), "occurrence start is \(start(occ) ?? [:])")
        #expect(end(occ)?["date"] as? String == day(10), "occurrence end is \(end(occ) ?? [:])")
        #expect(start(occ)?["dateTime"] == nil, "the occurrence was saved as timed: \(start(occ) ?? [:])")
    }

    @Test("splitting an all-day series with a move starts the new series all-day on the given date")
    func allDaySplitStartsOnTheGivenDate() async throws {
        let rid = "\(day(7))T00:00:00"
        let r = try await run([FakeGoogleCalendar.allDay(id: "ser-sp", start: day(0), end: day(1), recurring: true)],
                              eventId: "ser-sp", [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string(rid),
            "start_iso": .string("\(day(9))T00:00:00"), "end_iso": .string("\(day(10))T00:00:00"),
            "timezone": .string("UTC"),
        ], account: "kind-g-split")
        let successorId = GoogleCalendarProvider.deterministicSplitEventId(masterId: "ser-sp", recurrenceId: rid)
        let successor = r.calendar.event(successorId)
        #expect(successor != nil, "no successor series was created; writes: \(r.calendar.writes)")
        #expect(start(successor)?["date"] as? String == day(9),
                "the new series starts \(start(successor) ?? [:]), not on the date the edit gave")
        #expect(end(successor)?["date"] as? String == day(10), "the new series ends \(end(successor) ?? [:])")
        #expect(start(successor)?["dateTime"] == nil, "the new series is timed: \(start(successor) ?? [:])")
        #expect(start(r.calendar.event("ser-sp"))?["date"] as? String == day(0), "the capped master moved or became timed")
    }

    // Controls: each holds on the pre-fix code too, and bounds the fix from the other side.

    @Test("a timed event given a date alone, without all_day, stays timed at midnight")
    func timedGivenADateStaysTimed() async throws {
        let r = try await run([FakeGoogleCalendar.timed(id: "tm-1", day: day(0))], eventId: "tm-1", [
            "start_iso": .string("\(day(7))T00:00:00"), "timezone": .string("UTC"),
        ], account: "kind-g-timed")
        let after = r.calendar.event("tm-1")
        #expect(start(after)?["date"] == nil, "a timed event became all-day: \(start(after) ?? [:])")
        #expect((start(after)?["dateTime"] as? String)?.hasPrefix("\(day(7))T00:00:00") == true,
                "start is \(start(after) ?? [:])")
    }

    @Test("an explicit all_day: true makes a timed event all-day")
    func explicitTrueConvertsTimed() async throws {
        let r = try await run([FakeGoogleCalendar.timed(id: "tm-2", day: day(0))], eventId: "tm-2", [
            "all_day": .bool(true), "start_iso": .string(day(7)), "end_iso": .string(day(8)),
        ], account: "kind-g-true")
        let after = r.calendar.event("tm-2")
        #expect(start(after)?["date"] as? String == day(7), "start is \(start(after) ?? [:])")
        #expect(end(after)?["date"] as? String == day(8), "end is \(end(after) ?? [:])")
    }

    @Test("an explicit all_day: false makes an all-day event timed")
    func explicitFalseConvertsAllDay() async throws {
        let r = try await run([FakeGoogleCalendar.allDay(id: "ad-4", start: day(0), end: day(1))], eventId: "ad-4", [
            "all_day": .bool(false), "start_iso": .string("\(day(7))T09:00:00"),
            "end_iso": .string("\(day(7))T10:00:00"), "timezone": .string("UTC"),
        ], account: "kind-g-false")
        let after = r.calendar.event("ad-4")
        #expect(start(after)?["date"] == nil, "still all-day: \(start(after) ?? [:])")
        #expect((start(after)?["dateTime"] as? String)?.hasPrefix("\(day(7))T09:00:00") == true,
                "start is \(start(after) ?? [:])")
    }

    // The all-day end refusal, on the wire.

    @Test("an all-day event given times of one day, without all_day, is refused with nothing written")
    func timesOfOneDayAreRefused() async throws {
        let seed = FakeGoogleCalendar.allDay(id: "ad-5", start: day(0), end: day(1))
        let r = try await run([seed], eventId: "ad-5", [
            "start_iso": .string("\(day(7))T09:00:00"), "end_iso": .string("\(day(7))T17:00:00"),
            "timezone": .string("UTC"),
        ], account: "kind-g-refuse")
        #expect(r.calendar.writes.isEmpty, "a zero-length all-day event was written: \(r.calendar.writes)")
        #expect(start(r.calendar.event("ad-5"))?["date"] as? String == day(0), "the stored event changed")
        #expect(r.rows.count == 1 && r.rows.first?.status == PendingStatus.failed.rawValue,
                "the refusal was not retired: \(r.rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        #expect(r.rows.first?.failureReason?.contains(allDayEndHint) == true,
                "reason: \(r.rows.first?.failureReason ?? "<none>")")
    }

    @Test("an explicit all_day: true with the end on the start's day is refused with nothing written")
    func explicitAllDaySameDayEndIsRefused() async throws {
        let r = try await run([FakeGoogleCalendar.timed(id: "tm-3", day: day(0))], eventId: "tm-3", [
            "all_day": .bool(true), "start_iso": .string(day(7)), "end_iso": .string(day(7)),
        ], account: "kind-g-refuse-true")
        #expect(r.calendar.writes.isEmpty, "a zero-length all-day event was written: \(r.calendar.writes)")
        #expect(r.rows.first?.failureReason?.contains(allDayEndHint) == true,
                "reason: \(r.rows.first?.failureReason ?? "<none>")")
    }

    @Test("an edit giving no times still saves an all-day event stored with its end on its start")
    func editWithoutTimesIsNotChecked() async throws {
        let r = try await run([FakeGoogleCalendar.allDay(id: "ad-6", start: day(0), end: day(0))], eventId: "ad-6", [
            "title": .string("Renamed offsite"),
        ], account: "kind-g-rename")
        #expect(r.calendar.writes == ["PATCH ad-6"], "the rename was not written: \(r.calendar.writes)")
        #expect(r.calendar.event("ad-6")?["summary"] as? String == "Renamed offsite")
        #expect(r.rows.isEmpty, "the rename was refused: \(r.rows.map { $0.failureReason ?? $0.status })")
    }
}

// MARK: - Outlook (Microsoft Graph)

@Suite("A calendar edit without all_day keeps the event's kind: Outlook", .serialized, .processGlobalState)
struct ExchangeCalendarEditKeepsKindTests {

    private func run(_ graph: FakeGraphCalendar, eventId: String, _ arguments: [String: JSONValue], account: String)
        async throws -> [PendingCalendarOperation] {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                session: http.session)
        return try await drainEdit(accountId: account, eventId: eventId, calendarId: "primary",
                                   arguments: arguments, provider: provider)
    }

    private func dateTime(_ value: Any?) -> String? { (value as? [String: Any])?["dateTime"] as? String }

    @Test("an all-day event given new dates without all_day stays all-day on those dates")
    func allDayMovedStaysAllDay() async throws {
        let graph = FakeGraphCalendar([GraphFixture.event(id: "ev-ad", online: false, allDay: true)])
        let rows = try await run(graph, eventId: "ev-ad", [
            "start_iso": .string("\(day(7))T00:00:00"), "end_iso": .string("\(day(8))T00:00:00"),
            "timezone": .string("UTC"),
        ], account: "kind-x-move")
        let after = try #require(graph.event("ev-ad"))
        #expect(after["isAllDay"] as? Bool == true, "the all-day event was saved as a timed one: \(after["start"] ?? "none")")
        #expect(dateTime(after["start"])?.hasPrefix(day(7)) == true, "start is \(after["start"] ?? "none")")
        #expect(dateTime(after["end"])?.hasPrefix(day(8)) == true, "end is \(after["end"] ?? "none")")
        #expect(rows.isEmpty)
    }

    @Test("an all-day event given only a new start stays all-day and keeps its length in days")
    func allDayStartAloneKeepsLength() async throws {
        let graph = FakeGraphCalendar([GraphFixture.event(id: "ev-ad2", online: false, allDay: true)])
        _ = try await run(graph, eventId: "ev-ad2", [
            "start_iso": .string("\(day(7))T00:00:00"), "timezone": .string("UTC"),
        ], account: "kind-x-start")
        let after = try #require(graph.event("ev-ad2"))
        #expect(after["isAllDay"] as? Bool == true, "saved as timed: \(after["start"] ?? "none")")
        #expect(dateTime(after["start"])?.hasPrefix(day(7)) == true, "start is \(after["start"] ?? "none")")
        #expect(dateTime(after["end"])?.hasPrefix(day(8)) == true, "end did not follow: \(after["end"] ?? "none")")
    }

    @Test("moving one occurrence of an all-day series keeps that occurrence all-day")
    func allDayOccurrenceStaysAllDay() async throws {
        let occurrenceDay = GraphFixture.utcDay(GraphFixture.occurrenceStart)
        let graph = FakeGraphCalendar([
            GraphFixture.event(id: "ser-ad", online: false, recurring: true, allDay: true),
            GraphFixture.event(id: "ser-ad-occ", start: GraphFixture.occurrenceStart, online: false,
                               seriesMasterId: "ser-ad", allDay: true),
        ])
        let rows = try await run(graph, eventId: "ser-ad", [
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(occurrenceDay)T00:00:00"),
            "start_iso": .string("\(day(9))T00:00:00"), "end_iso": .string("\(day(10))T00:00:00"),
            "timezone": .string("UTC"),
        ], account: "kind-x-occ")
        let occ = try #require(graph.event("ser-ad-occ"))
        #expect(graph.patches("ser-ad-occ").count == 1, "rows: \(rows.map { $0.failureReason ?? $0.status })")
        #expect(occ["isAllDay"] as? Bool == true, "the occurrence was saved as timed: \(occ["start"] ?? "none")")
        #expect(dateTime(occ["start"])?.hasPrefix(day(9)) == true, "occurrence start is \(occ["start"] ?? "none")")
        #expect(dateTime(occ["end"])?.hasPrefix(day(10)) == true, "occurrence end is \(occ["end"] ?? "none")")
    }

    @Test("an explicit all_day: false makes an all-day event timed (control)")
    func explicitFalseConvertsAllDay() async throws {
        let graph = FakeGraphCalendar([GraphFixture.event(id: "ev-ad3", online: false, allDay: true)])
        _ = try await run(graph, eventId: "ev-ad3", [
            "all_day": .bool(false), "start_iso": .string("\(day(7))T09:00:00"),
            "end_iso": .string("\(day(7))T10:00:00"), "timezone": .string("UTC"),
        ], account: "kind-x-false")
        let after = try #require(graph.event("ev-ad3"))
        #expect(after["isAllDay"] as? Bool == false, "still all-day: \(after["start"] ?? "none")")
        #expect(dateTime(after["start"])?.hasPrefix("\(day(7))T09:00:00") == true, "start is \(after["start"] ?? "none")")
    }
}

// MARK: - CalDAV

@Suite("A calendar edit without all_day keeps the event's kind: CalDAV", .serialized, .processGlobalState)
struct CalDAVCalendarEditKeepsKindTests {

    private static let home = URL(string: "https://caldav.example.com/cal/")!

    private static func allDayICS(uid: String, start: String, end: String, recurring: Bool) -> String {
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
            "UID:\(uid)", "DTSTAMP:\(compact(day(-14)))T000000Z",
            "DTSTART;VALUE=DATE:\(compact(start))", "DTEND;VALUE=DATE:\(compact(end))", "SUMMARY:Offsite",
        ]
        if recurring { lines.append("RRULE:FREQ=WEEKLY") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n")
    }

    private func run(_ store: FakeCalDAVStore, eventId: String, _ arguments: [String: JSONValue], account: String)
        async throws -> [PendingCalendarOperation] {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
        let provider = CalDAVProvider(
            client: CalDAVClient(username: "user@example.com", password: "pw", session: http.session),
            calendarHomeURL: Self.home, serverBaseURL: Self.home)
        return try await drainEdit(accountId: account, eventId: eventId, calendarId: "/cal/",
                                   arguments: arguments, provider: provider)
    }

    private func line(_ ics: String?, _ name: String) -> String? {
        ics?.components(separatedBy: "\r\n").first { $0.hasPrefix(name) }
    }

    @Test("an all-day event given new dates without all_day moves to those dates and stays all-day")
    func allDayMoveLands() async throws {
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: "/cal/ad-1.ics", ics: Self.allDayICS(uid: "ad-1", start: day(0), end: day(1), recurring: false))
        let rows = try await run(store, eventId: "/cal/ad-1.ics", [
            "start_iso": .string("\(day(7))T00:00:00"), "end_iso": .string("\(day(8))T00:00:00"),
            "timezone": .string("UTC"),
        ], account: "kind-c-move")
        let ics = store.storedICS(path: "/cal/ad-1.ics")
        #expect(line(ics, "DTSTART") == "DTSTART;VALUE=DATE:\(compact(day(7)))",
                "the move did not land: \(line(ics, "DTSTART") ?? "<none>")")
        #expect(line(ics, "DTEND") == "DTEND;VALUE=DATE:\(compact(day(8)))", "end: \(line(ics, "DTEND") ?? "<none>")")
        #expect(rows.isEmpty)
    }

    @Test("an all-day event given only a new start, without all_day, keeps its length in days")
    func allDayStartAloneKeepsItsDays() async throws {
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: "/cal/ad-2.ics", ics: Self.allDayICS(uid: "ad-2", start: day(0), end: day(2), recurring: false))
        let rows = try await run(store, eventId: "/cal/ad-2.ics", [
            "start_iso": .string("\(day(7))T00:00:00"), "timezone": .string("UTC"),
        ], account: "kind-c-start")
        let ics = store.storedICS(path: "/cal/ad-2.ics")
        #expect(line(ics, "DTSTART") == "DTSTART;VALUE=DATE:\(compact(day(7)))",
                "start: \(line(ics, "DTSTART") ?? "<none>")")
        #expect(line(ics, "DTEND") == "DTEND;VALUE=DATE:\(compact(day(9)))",
                "a two-day event's end stayed behind: \(line(ics, "DTEND") ?? "<none>")")
        #expect(rows.isEmpty)
    }

    @Test("a timed event given only a new start keeps its length across the March daylight-saving change")
    func timedStartAloneKeepsItsLength() async throws {
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: "/cal/tm-1.ics", ics: [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
            "UID:tm-1", "DTSTAMP:20990101T000000Z",
            "DTSTART;TZID=America/Los_Angeles:20990302T100000", "DTEND;TZID=America/Los_Angeles:20990302T113000",
            "SUMMARY:Planning", "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n"))
        // 2099-03-08 is the change; a week later the event still runs 10:00 to 11:30.
        let rows = try await run(store, eventId: "/cal/tm-1.ics", [
            "start_iso": .string("2099-03-09T10:00:00"), "timezone": .string("America/Los_Angeles"),
        ], account: "kind-c-timed-start")
        let ics = store.storedICS(path: "/cal/tm-1.ics")
        #expect(line(ics, "DTSTART") == "DTSTART;TZID=America/Los_Angeles:20990309T100000",
                "start: \(line(ics, "DTSTART") ?? "<none>")")
        #expect(line(ics, "DTEND") == "DTEND;TZID=America/Los_Angeles:20990309T113000",
                "the end stayed behind: \(line(ics, "DTEND") ?? "<none>")")
        #expect(rows.isEmpty)
    }

    @Test("a timed event whose DTSTART states VALUE=DATE-TIME, given only a new start, moves as a timed event")
    func explicitDateTimeStartAloneMovesTimed() async throws {
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: "/cal/tm-2.ics", ics: [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
            "UID:tm-2", "DTSTAMP:20990101T000000Z",
            "DTSTART;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990302T113000",
            "SUMMARY:Planning", "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n"))
        let rows = try await run(store, eventId: "/cal/tm-2.ics", [
            "start_iso": .string("2099-03-02T14:00:00"), "timezone": .string("America/Los_Angeles"),
        ], account: "kind-c-explicit-datetime")
        let ics = store.storedICS(path: "/cal/tm-2.ics")
        let start = line(ics, "DTSTART")
        let end = line(ics, "DTEND")
        #expect(start?.hasSuffix(":20990302T140000") == true, "start: \(start ?? "<none>")")
        #expect(start?.contains("TZID=America/Los_Angeles") == true, "start: \(start ?? "<none>")")
        #expect(end?.hasSuffix(":20990302T153000") == true, "the event did not keep its length: \(end ?? "<none>")")
        #expect(rows.isEmpty, "the move was refused: \(rows.first?.failureReason ?? "<none>")")
    }

    @Test("a timed series whose DTSTART states VALUE=DATE-TIME splits as a timed series")
    func explicitDateTimeSeriesSplitsTimed() async throws {
        let store = FakeCalDAVStore(servesETags: true)
        // 2099-03-02 is a Monday; weekly from there.
        store.seed(path: "/cal/tm-3.ics", ics: [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
            "UID:tm-3", "DTSTAMP:20990101T000000Z",
            "DTSTART;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990302T113000",
            "RRULE:FREQ=WEEKLY", "SUMMARY:Planning", "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n"))
        let rid = "2099-03-16T10:00:00"
        let rows = try await run(store, eventId: "/cal/tm-3.ics", [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string(rid),
            "start_iso": .string("2099-03-16T14:00:00"), "timezone": .string("America/Los_Angeles"),
        ], account: "kind-c-explicit-datetime-split")
        #expect(rows.isEmpty, "the split was refused: \(rows.first?.failureReason ?? "<none>")")
        // Read inside the VEVENT: a written VTIMEZONE carries its own DTSTART and RRULE lines.
        func eventLine(_ ics: String?, _ name: String) -> String? {
            guard let ics, let begin = ics.range(of: "BEGIN:VEVENT") else { return nil }
            return line(String(ics[begin.lowerBound...]), name)
        }
        let capped = eventLine(store.storedICS(path: "/cal/tm-3.ics"), "RRULE")
        #expect(capped?.contains("UNTIL=") == true, "the series was not capped: \(capped ?? "<none>")")
        #expect(capped?.range(of: #"UNTIL=\d{8}T\d{6}Z"#, options: .regularExpression) != nil,
                "a timed series needs a date-time UNTIL: \(capped ?? "<none>")")
        let newUid = GoogleCalendarProvider.deterministicSplitEventId(masterId: "/cal/tm-3.ics", recurrenceId: rid)
        let successor = store.storedICS(path: "/cal/\(newUid).ics")
        #expect(successor != nil, "no successor series was written; PUTs: \(store.recordedPuts().map(\.path))")
        let start = eventLine(successor, "DTSTART")
        let end = eventLine(successor, "DTEND")
        #expect(start?.hasSuffix(":20990316T140000") == true, "new series start: \(start ?? "<none>")")
        #expect(start?.contains("TZID=America/Los_Angeles") == true, "new series start: \(start ?? "<none>")")
        #expect(end?.hasSuffix(":20990316T153000") == true, "the new series did not keep the length: \(end ?? "<none>")")
    }

    @Test("one occurrence of a timed series whose DTSTART states VALUE=DATE-TIME, given only a new start, keeps a timed end")
    func explicitDateTimeOccurrenceKeepsTimedEnd() async throws {
        let store = FakeCalDAVStore(servesETags: true)
        // 2099-03-02 is a Monday; weekly from there.
        store.seed(path: "/cal/tm-4.ics", ics: [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
            "UID:tm-4", "DTSTAMP:20990101T000000Z",
            "DTSTART;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990302T100000",
            "DTEND;VALUE=DATE-TIME;TZID=America/Los_Angeles:20990302T113000",
            "RRULE:FREQ=WEEKLY", "SUMMARY:Planning", "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n"))
        let rows = try await run(store, eventId: "/cal/tm-4.ics", [
            "edit_scope": .string("this_only"), "recurrence_id": .string("2099-03-16T10:00:00"),
            "start_iso": .string("2099-03-16T14:00:00"), "timezone": .string("America/Los_Angeles"),
        ], account: "kind-c-explicit-datetime-occurrence")
        #expect(rows.isEmpty, "the change was refused: \(rows.first?.failureReason ?? "<none>")")
        // The changed occurrence is the VEVENT that carries a RECURRENCE-ID.
        let blocks = (store.storedICS(path: "/cal/tm-4.ics") ?? "").components(separatedBy: "BEGIN:VEVENT")
        let override = blocks.first { $0.contains("RECURRENCE-ID") }
        #expect(override != nil, "no changed occurrence was written")
        let start = line(override, "DTSTART")
        let end = line(override, "DTEND")
        #expect(start?.hasSuffix(":20990316T140000") == true, "occurrence start: \(start ?? "<none>")")
        #expect(end?.hasSuffix(":20990316T153000") == true, "the occurrence did not keep a timed end of its length: \(end ?? "<none>")")
    }

    @Test("splitting an all-day series with a move starts the new series on the given date")
    func allDaySplitStartsOnTheGivenDate() async throws {
        let store = FakeCalDAVStore(servesETags: true)
        let master = Self.allDayICS(uid: "ser-ad", start: day(0), end: day(1), recurring: true)
        store.seed(path: "/cal/ser-ad.ics", ics: master)
        let rid = "\(day(7))T00:00:00"
        _ = try await run(store, eventId: "/cal/ser-ad.ics", [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string(rid),
            "start_iso": .string("\(day(9))T00:00:00"), "end_iso": .string("\(day(10))T00:00:00"),
            "timezone": .string("UTC"),
        ], account: "kind-c-split")
        let newUid = GoogleCalendarProvider.deterministicSplitEventId(masterId: "/cal/ser-ad.ics", recurrenceId: rid)
        let successor = store.storedICS(path: "/cal/\(newUid).ics")
        #expect(successor != nil, "no successor series was written; PUTs: \(store.recordedPuts().map(\.path))")
        #expect(line(successor, "DTSTART") == "DTSTART;VALUE=DATE:\(compact(day(9)))",
                "the new series starts \(line(successor, "DTSTART") ?? "<none>"), not on the date the edit gave")
    }

    @Test("splitting an all-day series with times of one day writes nothing, not even the cap")
    func splitWithTimesOfOneDayWritesNothing() async throws {
        let store = FakeCalDAVStore(servesETags: true)
        let master = Self.allDayICS(uid: "ser-rf", start: day(0), end: day(1), recurring: true)
        store.seed(path: "/cal/ser-rf.ics", ics: master)
        let rows = try await run(store, eventId: "/cal/ser-rf.ics", [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(7))T00:00:00"),
            "start_iso": .string("\(day(7))T09:00:00"), "end_iso": .string("\(day(7))T17:00:00"),
            "timezone": .string("UTC"),
        ], account: "kind-c-refuse")
        #expect(store.recordedPuts().isEmpty,
                "the split wrote \(store.recordedPuts().map(\.path)); the cap PUT cuts the series, so the refusal must come first")
        #expect(store.storedICS(path: "/cal/ser-rf.ics") == master, "the master changed")
        #expect(rows.first?.failureReason?.contains(allDayEndHint) == true,
                "reason: \(rows.first?.failureReason ?? "<none>")")
    }
}

// MARK: - The queue's own decisions

@Suite("A calendar edit without all_day keeps the event's kind: the queue", .serialized, .processGlobalState)
struct CalendarQueueEditKindTests {

    private func allDayResource(start: String = day(0), end: String = day(1)) -> GCalEvent {
        GCalEvent(
            id: "ev-1", summary: "Offsite", location: nil, description: nil,
            start: GCalDateTime(dateTime: nil, date: start, timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: end, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: ["RRULE:FREQ=WEEKLY"],
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil)
    }

    private func timedResource(day start: String = day(0)) -> GCalEvent {
        GCalEvent(
            id: "ev-1", summary: "Standup", location: nil, description: nil,
            start: GCalDateTime(dateTime: "\(start)T09:00:00Z", date: nil, timeZone: "UTC"),
            end: GCalDateTime(dateTime: "\(start)T09:30:00Z", date: nil, timeZone: "UTC"),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil)
    }

    private struct Drained {
        let rows: [PendingCalendarOperation]
        let writes: Int
        let updates: [(calendarId: String, eventId: String, event: GCalEventInput, sendUpdates: String)]
        let getEventCalls: Int
    }

    private func drain(_ arguments: [String: JSONValue], account: String, resource: GCalEvent?,
                       getEventThrows: Error? = nil) async throws -> Drained {
        let mock = MockCalendarProvider()
        if let resource { await mock.setGetEventResult(resource) }
        if let getEventThrows { await mock.setGetEventThrows(getEventThrows) }
        await mock.setUpdateEventResult(allDayResource())
        await mock.setUpdateOccurrenceResult(allDayResource())
        await mock.setSplitSeriesResult(allDayResource())
        let rows = try await drainEdit(accountId: account, eventId: "ev-1", calendarId: "primary",
                                       arguments: arguments, provider: mock)
        let updates = await mock.updatedEvents
        let writes = updates.count + (await mock.updatedOccurrences.count) + (await mock.splitSeriesCalls.count)
        let log = await mock.callLog
        return Drained(rows: rows, writes: writes, updates: updates,
                       getEventCalls: log.filter { $0.hasPrefix("getEvent(") }.count)
    }

    @Test("a move without all_day learns the kind from the event and renders all-day dates")
    func moveLearnsTheKind() async throws {
        let r = try await drain([
            "start_iso": .string("\(day(7))T00:00:00"), "end_iso": .string("\(day(8))T00:00:00"),
        ], account: "kind-q-learn", resource: allDayResource())
        #expect(r.getEventCalls == 1, "the kind was assumed, not learned from the event")
        guard r.updates.count == 1 else { Issue.record("updates: \(r.updates.count)"); return }
        #expect(r.updates[0].event.startDate == day(7) && r.updates[0].event.endDate == day(8),
                "patch: start \(r.updates[0].event.startDate ?? "nil") end \(r.updates[0].event.endDate ?? "nil")")
        #expect(r.updates[0].event.startDateTime == nil && r.updates[0].event.endDateTime == nil,
                "the patch carries timed values: \(r.updates[0].event.startDateTime ?? "nil")")
    }

    @Test("times of one day on an all-day event are refused on every edit_scope, with nothing written",
          arguments: ["all", "this_only", "this_and_following"])
    func refusedOnEveryScope(_ scope: String) async throws {
        var args: [String: JSONValue] = [
            "edit_scope": .string(scope),
            "start_iso": .string("\(day(7))T09:00:00"), "end_iso": .string("\(day(7))T17:00:00"),
        ]
        if scope != "all" { args["recurrence_id"] = .string("\(day(7))T00:00:00") }
        let r = try await drain(args, account: "kind-q-refuse-\(scope)", resource: allDayResource())
        #expect(r.writes == 0, "\(scope): \(r.writes) write(s) reached the provider")
        #expect(r.rows.count == 1 && r.rows.first?.status == PendingStatus.failed.rawValue,
                "\(scope): not retired: \(r.rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        #expect(r.rows.first?.failureReason?.contains(allDayEndHint) == true,
                "\(scope): reason \(r.rows.first?.failureReason ?? "<none>")")
    }

    @Test("an explicit all_day: true giving only an end on the stored start's day is refused")
    func explicitEndOnlyOnStoredStartDayIsRefused() async throws {
        let r = try await drain([
            "all_day": .bool(true), "end_iso": .string(day(0)),
        ], account: "kind-q-endonly", resource: allDayResource())
        #expect(r.writes == 0, "a zero-length all-day event was written")
        #expect(r.rows.first?.failureReason?.contains(allDayEndHint) == true,
                "reason \(r.rows.first?.failureReason ?? "<none>")")
    }

    @Test("an all-day event given only a new end after its start is written (control)")
    func endOnlyAfterTheStartIsWritten() async throws {
        let r = try await drain(["end_iso": .string(day(3))], account: "kind-q-endok", resource: allDayResource())
        #expect(r.updates.count == 1 && r.rows.isEmpty, "rows: \(r.rows.map { $0.failureReason ?? $0.status })")
        #expect(r.updates.first?.event.endDate == day(3))
        #expect(r.getEventCalls == 1, "the event was read \(r.getEventCalls) times; the kind's read also gives the start")
    }

    @Test("an end alone on one occurrence's own day is refused: the occurrence keeps its own start, not the series'",
          arguments: ["this_only", "this_and_following", "omitted"])
    func endOnlyOnTheOccurrenceDayIsRefused(_ scope: String) async throws {
        // The series starts on day 0, so the end is after the series' start but on the occurrence's.
        // "omitted" leaves edit_scope out: a recurrence_id alone means this_only.
        var args: [String: JSONValue] = [
            "recurrence_id": .string("\(day(7))T00:00:00"), "end_iso": .string("\(day(7))T23:59:59"),
        ]
        if scope != "omitted" { args["edit_scope"] = .string(scope) }
        let r = try await drain(args, account: "kind-q-occ-end-\(scope)", resource: allDayResource())
        #expect(r.writes == 0, "\(scope): \(r.writes) write(s) reached the provider, a zero-length occurrence or series")
        #expect(r.rows.count == 1 && r.rows.first?.status == PendingStatus.failed.rawValue,
                "\(scope): not retired: \(r.rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        #expect(r.rows.first?.failureReason?.contains(allDayEndHint) == true,
                "\(scope): reason \(r.rows.first?.failureReason ?? "<none>")")
    }

    @Test("a start given on one occurrence or a split is what the end is compared with, not the occurrence's date",
          arguments: ["this_only", "this_and_following"])
    func givenStartWinsOnAScopedEdit(_ scope: String) async throws {
        let rid = "\(day(7))T00:00:00"
        // Moved later, to day 9, with an end on day 8: after the occurrence's date, before the given start.
        let inverted = try await drain([
            "edit_scope": .string(scope), "recurrence_id": .string(rid),
            "start_iso": .string("\(day(9))T00:00:00"), "end_iso": .string("\(day(8))T00:00:00"),
        ], account: "kind-q-scoped-start-bad-\(scope)", resource: allDayResource())
        #expect(inverted.writes == 0, "\(scope): an end before the given start was written")
        #expect(inverted.rows.first?.failureReason?.contains(allDayEndHint) == true,
                "\(scope): reason \(inverted.rows.first?.failureReason ?? "<none>")")
        // Moved earlier, to day 5, ending on day 6: before the occurrence's date, after the given start.
        let earlier = try await drain([
            "edit_scope": .string(scope), "recurrence_id": .string(rid),
            "start_iso": .string("\(day(5))T00:00:00"), "end_iso": .string("\(day(6))T00:00:00"),
        ], account: "kind-q-scoped-start-ok-\(scope)", resource: allDayResource())
        #expect(earlier.writes == 1 && earlier.rows.isEmpty,
                "\(scope): a valid move was refused: \(earlier.rows.map { $0.failureReason ?? $0.status })")
    }

    @Test("all_day: true with a start and an end reads nothing: the kind and the start are both given (control)")
    func statedKindAndStartReadNothing() async throws {
        let r = try await drain([
            "all_day": .bool(true), "start_iso": .string(day(7)), "end_iso": .string(day(8)),
        ], account: "kind-q-stated", resource: allDayResource())
        #expect(r.getEventCalls == 0, "an edit that states its kind and start read the event \(r.getEventCalls) time(s)")
        #expect(r.updates.count == 1 && r.rows.isEmpty, "rows: \(r.rows.map { $0.failureReason ?? $0.status })")
    }

    @Test("all_day: true with an end on a timed event's start day is refused")
    func explicitAllDayEndOnATimedStartDayIsRefused() async throws {
        let r = try await drain([
            "all_day": .bool(true), "end_iso": .string(day(0)),
        ], account: "kind-q-timed-end", resource: timedResource())
        #expect(r.writes == 0, "a zero-length all-day event was written over a timed one")
        #expect(r.rows.first?.failureReason?.contains(allDayEndHint) == true,
                "reason \(r.rows.first?.failureReason ?? "<none>")")
    }

    @Test("an edit that moves nothing and sets no UNTIL makes no getEvent call (control)")
    func noFetchWhenNothingMoves() async throws {
        let r = try await drain([
            "title": .string("Renamed"), "description": .string("Notes"), "location": .string("Room 2"),
        ], account: "kind-q-nofetch", resource: allDayResource())
        #expect(r.getEventCalls == 0, "an edit that moves nothing paid a round trip")
        #expect(r.updates.count == 1)
    }

    @Test("a failed read on a moving edit writes nothing and keeps the edit queued")
    func failedReadOnAMoveWritesNothing() async throws {
        let r = try await drain([
            "start_iso": .string("\(day(7))T00:00:00"), "end_iso": .string("\(day(8))T00:00:00"),
        ], account: "kind-q-throws", resource: nil, getEventThrows: URLError(.notConnectedToInternet))
        #expect(r.writes == 0, "an edit whose kind could not be learned was written with a guessed kind")
        #expect(r.rows.count == 1 && r.rows.first?.status == PendingStatus.queued.rawValue,
                "the edit did not stay queued: \(r.rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        #expect(r.rows.first?.failureReason == nil)
    }
}

// MARK: - The edit tool refuses before its card when the kind is stated

@Suite("calendar_event_edit refuses a stated all-day end on its start before the card")
struct CalendarEditToolAllDayEndTests {

    private func makeContext() throws -> ToolContext {
        ToolContext(db: try TestDatabase.make(), translator: MockChatIdTranslator())
    }

    @Test("all_day: true with the end on the start's day is refused before the confirmation card")
    func sameDayEndIsRefused() async throws {
        let out = try await CalendarEventEditTool(context: try makeContext()).execute(arguments: [
            "event_id": .string("evt-1"), "all_day": .bool(true),
            "start_iso": .string(day(7)), "end_iso": .string(day(7)),
        ])
        #expect(out.contains(allDayEndHint), "got \(out)")
        #expect(out.contains("NOT changed"), "got \(out)")
    }

    @Test("all_day: true with the end on the next day is not refused up front (control)")
    func nextDayEndIsNotRefused() async throws {
        let out = try await CalendarEventEditTool(context: try makeContext()).execute(arguments: [
            "event_id": .string("evt-1"), "all_day": .bool(true),
            "start_iso": .string(day(7)), "end_iso": .string(day(8)),
        ])
        #expect(!out.contains(allDayEndHint), "got \(out)")
    }

    @Test("times of one day without all_day are not refused up front: the kind is not known without a read (control)")
    func unstatedKindIsNotRefusedUpFront() async throws {
        let out = try await CalendarEventEditTool(context: try makeContext()).execute(arguments: [
            "event_id": .string("evt-1"),
            "start_iso": .string("\(day(7))T09:00:00"), "end_iso": .string("\(day(7))T17:00:00"),
        ])
        #expect(!out.contains(allDayEndHint), "a possibly timed edit was refused as all-day: \(out)")
    }

    @Test("the rule compares dates: an end on or before the start is refused, a start alone never is")
    func ruleByDate() {
        func reason(_ args: [String: JSONValue], allDay: Bool?, stored: String? = nil) -> String? {
            CalendarToolHelpers.allDayEditEndRefusal(args, allDay: allDay, targetStartDate: stored)
        }
        let same: [String: JSONValue] = ["start_iso": .string("\(day(7))T09:00:00"), "end_iso": .string("\(day(7))T17:00:00")]
        #expect(reason(same, allDay: true) != nil, "same day")
        #expect(reason(["start_iso": .string(day(7)), "end_iso": .string(day(6))], allDay: true) != nil, "end before start")
        #expect(reason(["start_iso": .string(day(7)), "end_iso": .string(day(8))], allDay: true) == nil, "next day")
        #expect(reason(same, allDay: false) == nil, "a timed edit is not checked")
        #expect(reason(same, allDay: nil) == nil, "an unresolved kind is not checked")
        #expect(reason(["start_iso": .string(day(7))], allDay: true) == nil, "a start alone")
        #expect(reason(["end_iso": .string(day(0))], allDay: true, stored: day(0)) != nil, "end only, on the stored start")
        #expect(reason(["end_iso": .string(day(1))], allDay: true, stored: day(0)) == nil, "end only, after the stored start")
        #expect(reason(["end_iso": .string(day(0))], allDay: true, stored: nil) == nil, "no start to compare")
    }
}
