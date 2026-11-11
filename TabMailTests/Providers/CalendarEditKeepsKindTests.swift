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
// new dates stays all-day on those dates; a timed event given a date alone stays timed, at midnight.
// Only an `all_day` the edit states changes the kind, both ways. `calendar_event_edit` documents
// `all_day` as "Omit to keep existing".
//
// **AND NEVER GUESSES.** *An all-day event given a time of day with `all_day` left out is refused,
// with nothing written, and the assistant is told to ask the user* whether it should stay all-day or
// become timed. Dropping the time kept it all-day without asking. A date at midnight (`…T00:00:00`,
// the shape the read tools print for an all-day date) is a date.
//
// The defect: `AccountManagerCalendarQueue`'s `.edit` case resolved a missing `all_day` from the event
// only when an RRULE UNTIL was at stake, so a plain move rendered its dates as `startDateTime` /
// `endDateTime`. Google and Outlook then saved the all-day event as a timed one, and CalDAV left it
// where it was. The Thunderbird add-on had the same defect and the same rule fixes it there.
//
// **A SECOND INVARIANT, its companion.** *No all-day edit is written whose end is on or before its
// start* (an all-day end is the day after the last day). Once a missing `all_day` resolves to all-day,
// a move given times of one day would otherwise write a zero-length event; `all_day: true` with a
// same-day end already did. Refused before anything is written, on every `edit_scope`, asking the
// user how many days it should last; an edit that gives no times is not checked.
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
private let allDayEndHint = "this is an all-day event, so its end_iso is the day after its last day and must be later than start_iso. Ask the user how many days it should last"

/// The refusal the queue gives an all-day event a time of day when the edit leaves `all_day` out.
private let allDayTimeHint = "this is an all-day event, and the edit gives a time of day without all_day. Ask the user whether it should stay all-day"

/// The refusal the edit tool gives a stated `all_day` of the other kind when the edit gives no start or end.
private let kindChangeTimesHint = "to change this event between all-day and timed, give its new start_iso and end_iso"

// MARK: - A stateful Google calendar

/// An in-memory Google calendar: `GET` returns the stored event (or a series' instances: the
/// occurrences stored with its `recurringEventId` that overlap, where they are now, the window the
/// request names, as Google filters them; a deleted one, kept with `status` "cancelled", is left out
/// of the list while GET by its id still returns it), `PATCH`
/// replaces each top-level property the body names (Google's patch semantics: a supplied `start`
/// replaces the stored `start` whole), and `POST` stores a new event under the `id` it carries.
/// A PATCH of a series that changes its `recurrence`, or its start or end (another date or
/// instant, or another zone), resets the series: its stored occurrences, the ones changed one by
/// one, are dropped, as Google did when a series was moved from 08:00 to 13:00 (measured on a
/// personal account, 2026-11-10).
final class FakeGoogleCalendar: Sendable {
    private let events: Mutex<[String: Data]>
    private let writeLog = Mutex<[String]>([])
    private let resets = Mutex(0)

    /// How many PATCHes reset a series' changed occurrences.
    var seriesResets: Int { resets.withLock { $0 } }

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
                let window = Self.window(request.url)
                let items = events.withLock { Array($0.values) }
                    .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                    .filter { $0["recurringEventId"] as? String == parts[0] }
                    .filter { $0["status"] as? String != "cancelled" }
                    .filter { Self.overlaps($0, window) }
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
            let isSeries = (stored["recurrence"] as? [String])?.isEmpty == false
            let changesRule = patch["recurrence"].map { ($0 as? [String]) != (stored["recurrence"] as? [String]) } ?? false
            let movesTime = ["start", "end"].contains { key in patch[key].map { !Self.sameTime($0, stored[key]) } ?? false }
            if isSeries, changesRule || movesTime {
                resets.withLock { $0 += 1 }
                events.withLock { all in
                    all = all.filter { _, data in
                        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["recurringEventId"] as? String != parts[0]
                    }
                }
            }
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

    /// The instances window a request names (`timeMin`, `timeMax`), nil when it names none.
    private static func window(_ url: URL) -> (from: Date, to: Date)? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> Date? { items.first { $0.name == name }?.value.flatMap { Date.fromISO8601($0) } }
        guard let from = value("timeMin"), let to = value("timeMax") else { return nil }
        return (from, to)
    }

    /// Whether `event`, where it is NOW (its `start` and `end`, not its place in the series),
    /// overlaps `window`, as Google's instances list filters; every event when there is no window.
    /// An all-day date is read from UTC midnight.
    private static func overlaps(_ event: [String: Any], _ window: (from: Date, to: Date)?) -> Bool {
        guard let window else { return true }
        func instant(_ value: Any?) -> Date? {
            guard let value = value as? [String: Any] else { return nil }
            if let dateTime = value["dateTime"] as? String { return Date.fromISO8601(dateTime) }
            return (value["date"] as? String).flatMap { EKEventStoreHelper.parseNaiveISO($0, timeZone: .gmt) }
        }
        guard let start = instant(event["start"]) else { return false }
        let end = instant(event["end"]) ?? start
        return start < window.to && (end > window.from || start >= window.from)
    }

    /// Whether a written start or end is the stored one as Google reads it: the same date, or the
    /// same instant, and the same zone.
    private static func sameTime(_ written: Any, _ stored: Any?) -> Bool {
        guard let written = written as? [String: Any], let stored = stored as? [String: Any] else { return false }
        func instant(_ value: [String: Any]) -> Date? { (value["dateTime"] as? String).flatMap { Date.fromISO8601($0) } }
        return written["date"] as? String == stored["date"] as? String
            && instant(written) == instant(stored)
            && (written["dateTime"] == nil) == (stored["dateTime"] == nil)
            && written["timeZone"] as? String == stored["timeZone"] as? String
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
        if let master {
            e["recurringEventId"] = master
            // Its place in the series, as `events.instances` gives every occurrence.
            e["originalStartTime"] = ["date": start]
        }
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
/// row afterwards. Shared with `CalDAVAlarmIsNotTheEventWriteTests` and `CalendarSeriesScopeTests`.
func drainEdit(
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

    @Test("an all-day event given a start with a time of day, without all_day, is refused asking the user")
    func allDayStartWithTimeOfDayIsRefused() async throws {
        let r = try await run([FakeGoogleCalendar.allDay(id: "ad-3", start: day(0), end: day(1))], eventId: "ad-3", [
            "start_iso": .string("\(day(7))T15:30:00"), "timezone": .string("UTC"),
        ], account: "kind-g-time")
        let after = r.calendar.event("ad-3")
        #expect(r.calendar.writes.isEmpty, "the edit was written with the time dropped or kept: \(r.calendar.writes)")
        #expect(start(after)?["date"] as? String == day(0) && end(after)?["date"] as? String == day(1),
                "the stored event changed: \(start(after) ?? [:]) to \(end(after) ?? [:])")
        #expect(r.rows.count == 1 && r.rows.first?.status == PendingStatus.failed.rawValue,
                "the refusal was not retired: \(r.rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        #expect(r.rows.first?.failureReason?.contains(allDayTimeHint) == true,
                "reason: \(r.rows.first?.failureReason ?? "<none>")")
    }

    @Test("an explicit all_day: true with a time of day keeps the date, all-day (control)")
    func explicitTrueWithTimeOfDayKeepsTheDate() async throws {
        let r = try await run([FakeGoogleCalendar.allDay(id: "ad-7", start: day(0), end: day(1))], eventId: "ad-7", [
            "all_day": .bool(true), "start_iso": .string("\(day(7))T15:30:00"), "timezone": .string("UTC"),
        ], account: "kind-g-time-stated")
        let after = r.calendar.event("ad-7")
        #expect(start(after)?["date"] as? String == day(7), "start is \(start(after) ?? [:])")
        #expect(start(after)?["dateTime"] == nil, "the stated all-day edit was saved as timed: \(start(after) ?? [:])")
        #expect(r.rows.isEmpty, "the stated edit was refused: \(r.rows.map { $0.failureReason ?? $0.status })")
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

    @Test("an end alone on one all-day occurrence is checked against the day it starts on: refused on it, written after it")
    func occurrenceEndAloneIsCheckedAgainstItsDay() async throws {
        // Google addresses an occurrence by the start it has now, so the day it keeps is
        // recurrence_id's own (the protocol's default answer, with no request of its own).
        let seed = [
            FakeGoogleCalendar.allDay(id: "ser-end", start: day(0), end: day(1), recurring: true),
            FakeGoogleCalendar.allDay(id: "ser-end_occ", start: day(7), end: day(8), master: "ser-end"),
        ]
        func edit(endingOn end: String) -> [String: JSONValue] {
            ["edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T00:00:00"),
             "end_iso": .string(end), "timezone": .string("UTC")]
        }
        let refused = try await run(seed, eventId: "ser-end", edit(endingOn: day(7)), account: "kind-g-occ-end-refuse")
        #expect(refused.calendar.writes.isEmpty, "an occurrence ending on its start was written: \(refused.calendar.writes)")
        #expect(refused.rows.count == 1 && refused.rows.first?.status == PendingStatus.failed.rawValue
                    && refused.rows.first?.failureReason?.contains(allDayEndHint) == true,
                "rows: \(refused.rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        let written = try await run(seed, eventId: "ser-end", edit(endingOn: day(9)), account: "kind-g-occ-end-ok")
        let occ = written.calendar.event("ser-end_occ")
        #expect(written.calendar.writes == ["PATCH ser-end_occ"], "writes: \(written.calendar.writes)")
        #expect(written.rows.isEmpty, "the change was refused: \(written.rows.map { $0.failureReason ?? $0.status })")
        #expect(start(occ)?["date"] as? String == day(7), "the occurrence's start moved: \(start(occ) ?? [:])")
        #expect(end(occ)?["date"] as? String == day(9), "occurrence end is \(end(occ) ?? [:])")
    }

    @Test("splitting an all-day series with a move starts the new series all-day on the given date")
    func allDaySplitStartsOnTheGivenDate() async throws {
        let rid = "\(day(7))T00:00:00"
        let r = try await run([FakeGoogleCalendar.allDay(id: "ser-sp", start: day(0), end: day(1), recurring: true),
                               FakeGoogleCalendar.allDay(id: "ser-sp_occ", start: day(7), end: day(8), master: "ser-sp")],
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

    @Test("an all-day event given dates of one day, without all_day, is refused with nothing written")
    func datesOfOneDayAreRefused() async throws {
        let seed = FakeGoogleCalendar.allDay(id: "ad-5", start: day(0), end: day(1))
        let r = try await run([seed], eventId: "ad-5", [
            "start_iso": .string("\(day(7))T00:00:00"), "end_iso": .string("\(day(7))T00:00:00"),
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

    @Test("an end alone on one all-day occurrence is checked against the day it starts on: refused on it, written after it")
    func occurrenceEndAloneIsCheckedAgainstItsDay() async throws {
        // Outlook addresses an occurrence by the start it has now, so the day it keeps is
        // recurrence_id's own (the protocol's default answer, with no request of its own).
        let occurrenceDay = GraphFixture.utcDay(GraphFixture.occurrenceStart)
        let twoDaysLater = GraphFixture.utcDay(GraphFixture.occurrenceStart.addingTimeInterval(2 * 86_400))
        func graph() -> FakeGraphCalendar {
            FakeGraphCalendar([
                GraphFixture.event(id: "ser-end", online: false, recurring: true, allDay: true),
                GraphFixture.event(id: "ser-end-occ", start: GraphFixture.occurrenceStart, online: false,
                                   seriesMasterId: "ser-end", allDay: true),
            ])
        }
        func edit(endingOn end: String) -> [String: JSONValue] {
            ["edit_scope": .string("this_only"), "recurrence_id": .string("\(occurrenceDay)T00:00:00"),
             "end_iso": .string(end), "timezone": .string("UTC")]
        }
        let refusedGraph = graph()
        let refused = try await run(refusedGraph, eventId: "ser-end", edit(endingOn: occurrenceDay), account: "kind-x-occ-end-refuse")
        #expect(refusedGraph.patches("ser-end-occ").isEmpty, "an occurrence ending on its start was written")
        #expect(refused.count == 1 && refused.first?.status == PendingStatus.failed.rawValue
                    && refused.first?.failureReason?.contains(allDayEndHint) == true,
                "rows: \(refused.map { "\($0.status) \($0.failureReason ?? "")" })")
        let writtenGraph = graph()
        let written = try await run(writtenGraph, eventId: "ser-end", edit(endingOn: twoDaysLater), account: "kind-x-occ-end-ok")
        let occ = try #require(writtenGraph.event("ser-end-occ"))
        #expect(writtenGraph.patches("ser-end-occ").count == 1, "rows: \(written.map { $0.failureReason ?? $0.status })")
        #expect(written.isEmpty, "the change was refused: \(written.map { $0.failureReason ?? $0.status })")
        #expect(dateTime(occ["start"])?.hasPrefix(occurrenceDay) == true, "the occurrence's start moved: \(occ["start"] ?? "none")")
        #expect(dateTime(occ["end"])?.hasPrefix(twoDaysLater) == true, "occurrence end is \(occ["end"] ?? "none")")
        #expect(occ["isAllDay"] as? Bool == true, "the occurrence was saved as timed: \(occ["start"] ?? "none")")
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

    @Test("splitting an all-day series with times of one day, without all_day, writes nothing, not even the cap")
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
        #expect(rows.first?.failureReason?.contains(allDayTimeHint) == true,
                "reason: \(rows.first?.failureReason ?? "<none>")")
    }

    /// A weekly all-day series from day 0 whose occurrence of day 7 was moved on its own to day 9.
    private static func seriesWithMovedOccurrence(uid: String) -> String {
        [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
            "UID:\(uid)", "DTSTAMP:\(compact(day(-14)))T000000Z",
            "DTSTART;VALUE=DATE:\(compact(day(0)))", "DTEND;VALUE=DATE:\(compact(day(1)))", "SUMMARY:Offsite",
            "RRULE:FREQ=WEEKLY", "END:VEVENT", "BEGIN:VEVENT",
            "UID:\(uid)", "DTSTAMP:\(compact(day(-14)))T000000Z",
            "RECURRENCE-ID;VALUE=DATE:\(compact(day(7)))",
            "DTSTART;VALUE=DATE:\(compact(day(9)))", "DTEND;VALUE=DATE:\(compact(day(10)))", "SUMMARY:Offsite",
            "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n")
    }

    @Test("an end alone on a moved occurrence is compared with the day it starts on now, not its original day",
          arguments: [8, 9], [false, true])
    func endOnOrBeforeTheMovedStartIsRefused(_ endOffset: Int, _ statesAllDay: Bool) async throws {
        // The occurrence of day 7 now starts on day 9: an end on day 8 or 9 is after its original
        // day and on or before the start it keeps. A stated `all_day: true` skips the queue's read
        // of the event, so the kind the rule needs is the stated one.
        let store = FakeCalDAVStore(servesETags: true)
        let series = Self.seriesWithMovedOccurrence(uid: "mv-\(endOffset)")
        store.seed(path: "/cal/mv.ics", ics: series)
        var arguments: [String: JSONValue] = [
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(9))T00:00:00"),
            "end_iso": .string(day(endOffset)), "timezone": .string("UTC"),
        ]
        if statesAllDay { arguments["all_day"] = .bool(true) }
        let rows = try await run(store, eventId: "/cal/mv.ics", arguments,
                                 account: "kind-c-moved-refuse-\(endOffset)-\(statesAllDay)")
        #expect(store.recordedPuts().isEmpty, "an occurrence ending on or before its start was written")
        #expect(store.storedICS(path: "/cal/mv.ics") == series, "the series changed")
        #expect(rows.count == 1 && rows.first?.failureReason?.contains(allDayEndHint) == true,
                "rows: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
    }

    @Test("by the occurrence id a listing gave, an end alone on a moved occurrence is checked against the day it starts on now: refused on it, written after it",
          arguments: [9, 12])
    func endAloneByOccurrenceIdIsCheckedAgainstTheMovedStart(_ endOffset: Int) async throws {
        // The occurrence of day 7 now starts on day 9. The edit names it by its occurrence id
        // (series href + its slot's date key), so the read of the day it starts on goes to the
        // series' resource for that same occurrence.
        let store = FakeCalDAVStore(servesETags: true)
        let series = Self.seriesWithMovedOccurrence(uid: "mv-occ-\(endOffset)")
        store.seed(path: "/cal/mv.ics", ics: series)
        let eventId = CalDAVOccurrences.OccurrenceId.make(seriesHref: "/cal/mv.ics", key: compact(day(7)))
        let rows = try await run(store, eventId: eventId, [
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(9))T00:00:00"),
            "end_iso": .string(day(endOffset)), "timezone": .string("UTC"),
        ], account: "kind-c-moved-occ-\(endOffset)")
        if endOffset <= 9 {
            #expect(store.recordedPuts().isEmpty, "an occurrence ending on or before its start was written")
            #expect(store.storedICS(path: "/cal/mv.ics") == series, "the series changed")
            #expect(rows.count == 1 && rows.first?.failureReason?.contains(allDayEndHint) == true,
                    "rows: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        } else {
            #expect(rows.isEmpty, "the change was refused: \(rows.first?.failureReason ?? "<none>")")
            let blocks = (store.storedICS(path: "/cal/mv.ics") ?? "").components(separatedBy: "BEGIN:VEVENT")
            let override = blocks.first { $0.contains("RECURRENCE-ID") }
            #expect(line(override, "DTSTART") == "DTSTART;VALUE=DATE:\(compact(day(9)))")
            #expect(line(override, "DTEND") == "DTEND;VALUE=DATE:\(compact(day(12)))")
        }
    }

    @Test("an end alone after a moved occurrence's start is written, and the occurrence keeps that start")
    func endAfterTheMovedStartIsWritten() async throws {
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: "/cal/mv.ics", ics: Self.seriesWithMovedOccurrence(uid: "mv-ok"))
        let rows = try await run(store, eventId: "/cal/mv.ics", [
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(9))T00:00:00"),
            "end_iso": .string(day(12)), "timezone": .string("UTC"),
        ], account: "kind-c-moved-ok")
        #expect(rows.isEmpty, "the change was refused: \(rows.first?.failureReason ?? "<none>")")
        let blocks = (store.storedICS(path: "/cal/mv.ics") ?? "").components(separatedBy: "BEGIN:VEVENT")
        let override = blocks.first { $0.contains("RECURRENCE-ID") }
        #expect(line(override, "DTSTART") == "DTSTART;VALUE=DATE:\(compact(day(9)))",
                "occurrence start: \(line(override, "DTSTART") ?? "<none>")")
        #expect(line(override, "DTEND") == "DTEND;VALUE=DATE:\(compact(day(12)))",
                "occurrence end: \(line(override, "DTEND") ?? "<none>")")
    }

    @Test("an occurrence moved to an earlier day takes an end its original day would have refused",
          arguments: [false, true])
    func endAfterAnEarlierMovedStartIsWritten(_ statesAllDay: Bool) async throws {
        // The occurrence of day 7 now starts on day 5 and ends on day 6; a new end on day 7 is on
        // its original day and after the start it keeps. A stated `all_day: true` skips the queue's
        // read of the event, so the kind the rule needs is the stated one.
        let store = FakeCalDAVStore(servesETags: true)
        let series = Self.seriesWithMovedOccurrence(uid: "mv-early")
            .replacingOccurrences(of: "DTSTART;VALUE=DATE:\(compact(day(9)))", with: "DTSTART;VALUE=DATE:\(compact(day(5)))")
            .replacingOccurrences(of: "DTEND;VALUE=DATE:\(compact(day(10)))", with: "DTEND;VALUE=DATE:\(compact(day(6)))")
        store.seed(path: "/cal/mv.ics", ics: series)
        var arguments: [String: JSONValue] = [
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(5))T00:00:00"),
            "end_iso": .string(day(7)), "timezone": .string("UTC"),
        ]
        if statesAllDay { arguments["all_day"] = .bool(true) }
        let rows = try await run(store, eventId: "/cal/mv.ics", arguments, account: "kind-c-moved-early-\(statesAllDay)")
        #expect(rows.isEmpty, "the change was refused: \(rows.first?.failureReason ?? "<none>")")
        let blocks = (store.storedICS(path: "/cal/mv.ics") ?? "").components(separatedBy: "BEGIN:VEVENT")
        let override = blocks.first { $0.contains("RECURRENCE-ID") }
        #expect(line(override, "DTSTART") == "DTSTART;VALUE=DATE:\(compact(day(5)))")
        #expect(line(override, "DTEND") == "DTEND;VALUE=DATE:\(compact(day(7)))")
    }

    @Test("the day an occurrence starts on now: its own start when it was changed, else its slot; nil when timed")
    func occurrenceStartDayReadsTheResource() {
        let moved = Self.seriesWithMovedOccurrence(uid: "mv-read")
        #expect(CalDAVProvider.occurrenceStartDay(storedICS: moved, recurrenceIdNaive: "\(day(7))T00:00:00") == day(9))
        #expect(CalDAVProvider.occurrenceStartDay(storedICS: moved, recurrenceIdNaive: day(7)) == day(9))
        #expect(CalDAVProvider.occurrenceStartDay(storedICS: moved, recurrenceIdNaive: "\(day(14))T00:00:00") == day(14),
                "an occurrence with no changes of its own starts on its slot")
        let timed = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
            "UID:tm-read", "DTSTAMP:20990101T000000Z",
            "DTSTART:20990302T100000Z", "DTEND:20990302T113000Z",
            "RRULE:FREQ=WEEKLY", "SUMMARY:Planning", "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n")
        #expect(CalDAVProvider.occurrenceStartDay(storedICS: timed, recurrenceIdNaive: "2099-03-09T10:00:00") == nil)
    }

    // A stated all_day that differs from the stored kind: the event changes kind, or the edit is
    // refused with nothing written. It never reports success with the event as it was.

    private static func timedICS(uid: String, day start: String, end: String, recurring: Bool = false,
                                 extra: [String] = []) -> String {
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
            "UID:\(uid)", "DTSTAMP:\(compact(day(-14)))T000000Z",
            "DTSTART:\(compact(start))T090000Z", end, "SUMMARY:Planning",
        ]
        if recurring { lines.append("RRULE:FREQ=WEEKLY") }
        lines += extra
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n")
    }

    @Test("an explicit all_day: false with a start and an end makes an all-day event timed at those times")
    func explicitFalseConvertsAllDay() async throws {
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: "/cal/cv-1.ics", ics: Self.allDayICS(uid: "cv-1", start: day(0), end: day(1), recurring: false))
        let rows = try await run(store, eventId: "/cal/cv-1.ics", [
            "all_day": .bool(false), "start_iso": .string("\(day(7))T09:00:00"),
            "end_iso": .string("\(day(7))T10:30:00"), "timezone": .string("UTC"),
        ], account: "kind-c-to-timed")
        let ics = store.storedICS(path: "/cal/cv-1.ics")
        #expect(line(ics, "DTSTART") == "DTSTART:\(compact(day(7)))T090000Z", "start: \(line(ics, "DTSTART") ?? "<none>")")
        #expect(line(ics, "DTEND") == "DTEND:\(compact(day(7)))T103000Z", "end: \(line(ics, "DTEND") ?? "<none>")")
        #expect(line(ics, "SUMMARY") == "SUMMARY:Offsite", "the rest of the event is kept")
        #expect(rows.isEmpty)
    }

    @Test("an explicit all_day: true with a start and an end makes a timed event all-day on those dates",
          arguments: ["DTEND:\(compact(day(0)))T100000Z", "DURATION:PT1H"])
    func explicitTrueConvertsTimed(_ storedEnd: String) async throws {
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: "/cal/cv-2.ics", ics: Self.timedICS(uid: "cv-2", day: day(0), end: storedEnd))
        let rows = try await run(store, eventId: "/cal/cv-2.ics", [
            "all_day": .bool(true), "start_iso": .string(day(7)), "end_iso": .string(day(9)),
        ], account: "kind-c-to-allday-\(storedEnd.prefix(3))")
        let ics = store.storedICS(path: "/cal/cv-2.ics")
        #expect(line(ics, "DTSTART") == "DTSTART;VALUE=DATE:\(compact(day(7)))", "start: \(line(ics, "DTSTART") ?? "<none>")")
        #expect(line(ics, "DTEND") == "DTEND;VALUE=DATE:\(compact(day(9)))", "end: \(line(ics, "DTEND") ?? "<none>")")
        #expect(line(ics, "DURATION") == nil, "a length in hours was left on an all-day event")
        #expect(rows.isEmpty)
    }

    /// Both directions, each with only a start or only an end. A timed event made all-day with only an
    /// end gives an end after the stored start, so the queue's own end check passes it to the provider.
    @Test("a change of kind that gives only a start or only an end is refused with nothing written, both ways",
          arguments: [true, false], ["start", "end"])
    func kindChangeWithoutAnEndIsRefused(_ toAllDay: Bool, _ given: String) async throws {
        let store = FakeCalDAVStore(servesETags: true)
        let stored = toAllDay
            ? Self.timedICS(uid: "cv-3", day: day(0), end: "DTEND:\(compact(day(0)))T100000Z")
            : Self.allDayICS(uid: "cv-3", start: day(0), end: day(1), recurring: false)
        store.seed(path: "/cal/cv-3.ics", ics: stored)
        var arguments: [String: JSONValue] = ["all_day": .bool(toAllDay), "timezone": .string("UTC")]
        switch (toAllDay, given) {
        case (true, "start"): arguments["start_iso"] = .string(day(7))
        case (true, _): arguments["end_iso"] = .string(day(8))
        case (false, "start"): arguments["start_iso"] = .string("\(day(7))T09:00:00")
        default: arguments["end_iso"] = .string("\(day(7))T10:00:00")
        }
        let label = "\(toAllDay ? "to all-day" : "to timed"), \(given) only"
        let rows = try await run(store, eventId: "/cal/cv-3.ics", arguments,
                                 account: "kind-c-one-end-\(toAllDay)-\(given)")
        #expect(store.recordedPuts().isEmpty, "\(label): wrote \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: "/cal/cv-3.ics") == stored, "\(label): the event changed")
        #expect(rows.first?.failureReason?.contains(CalDAVProvider.kindChangeNeedsBothMessage) == true,
                "\(label): reason: \(rows.first?.failureReason ?? "<none>")")
    }

    /// A timed weekly series made all-day, or an all-day weekly series made timed at times of one day.
    @Test("a change of kind on a repeating event is refused with nothing written, on every edit_scope, both ways",
          arguments: ["all", "this_only", "this_and_following"], [true, false])
    func kindChangeOnASeriesIsRefused(_ scope: String, _ toAllDay: Bool) async throws {
        let store = FakeCalDAVStore(servesETags: true)
        let stored = toAllDay
            ? Self.timedICS(uid: "cv-4", day: day(0), end: "DTEND:\(compact(day(0)))T100000Z", recurring: true)
            : Self.allDayICS(uid: "cv-4", start: day(0), end: day(1), recurring: true)
        store.seed(path: "/cal/cv-4.ics", ics: stored)
        var arguments: [String: JSONValue] = toAllDay
            ? ["all_day": .bool(true), "start_iso": .string(day(7)), "end_iso": .string(day(8))]
            : ["all_day": .bool(false), "start_iso": .string("\(day(7))T09:00:00"),
               "end_iso": .string("\(day(7))T10:00:00")]
        arguments["edit_scope"] = .string(scope)
        arguments["timezone"] = .string("UTC")
        if scope != "all" {
            arguments["recurrence_id"] = .string(toAllDay ? "\(day(7))T09:00:00" : "\(day(7))T00:00:00")
        }
        let label = "\(scope) \(toAllDay ? "to all-day" : "to timed")"
        let rows = try await run(store, eventId: "/cal/cv-4.ics", arguments,
                                 account: "kind-c-series-\(scope)-\(toAllDay)")
        #expect(store.recordedPuts().isEmpty, "\(label): wrote \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: "/cal/cv-4.ics") == stored, "\(label): the series changed")
        #expect(rows.first?.failureReason?.contains(CalDAVProvider.kindChangeOnRepeatingMessage) == true,
                "\(label): reason: \(rows.first?.failureReason ?? "<none>")")
    }

    /// A timed event that repeats only by added dates (RDATE), or whose master has no rule or dates
    /// at all but whose resource holds a changed occurrence (a second VEVENT with RECURRENCE-ID).
    @Test("a change of kind on an event that repeats only by added dates, or only by a changed occurrence, is refused with nothing written",
          arguments: ["rdate", "changed occurrence"])
    func kindChangeOnAnRDateSeriesIsRefused(_ fixture: String) async throws {
        let store = FakeCalDAVStore(servesETags: true)
        let stored: String
        if fixture == "rdate" {
            stored = Self.timedICS(uid: "cv-5", day: day(0), end: "DTEND:\(compact(day(0)))T100000Z",
                                   extra: ["RDATE:\(compact(day(7)))T090000Z"])
        } else {
            stored = [
                "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN",
                "BEGIN:VEVENT", "UID:cv-5", "DTSTAMP:\(compact(day(-14)))T000000Z",
                "DTSTART:\(compact(day(0)))T090000Z", "DTEND:\(compact(day(0)))T100000Z", "SUMMARY:Planning",
                "END:VEVENT",
                "BEGIN:VEVENT", "UID:cv-5", "DTSTAMP:\(compact(day(-14)))T000000Z",
                "RECURRENCE-ID:\(compact(day(0)))T090000Z",
                "DTSTART:\(compact(day(0)))T110000Z", "DTEND:\(compact(day(0)))T120000Z", "SUMMARY:Planning",
                "END:VEVENT", "END:VCALENDAR",
            ].joined(separator: "\r\n")
        }
        store.seed(path: "/cal/cv-5.ics", ics: stored)
        let rows = try await run(store, eventId: "/cal/cv-5.ics", [
            "all_day": .bool(true), "start_iso": .string(day(7)), "end_iso": .string(day(8)), "edit_scope": .string("all"),
        ], account: "kind-c-repeats-\(fixture)")
        #expect(store.recordedPuts().isEmpty, "\(fixture): wrote \(store.recordedPuts().map(\.path))")
        #expect(store.storedICS(path: "/cal/cv-5.ics") == stored, "\(fixture): the event changed")
        #expect(rows.first?.failureReason?.contains(CalDAVProvider.kindChangeOnRepeatingMessage) == true,
                "\(fixture): reason: \(rows.first?.failureReason ?? "<none>")")
    }

    @Test("a zoned event that does not repeat, stored with a VTIMEZONE whose rules repeat, becomes all-day")
    func zonedEventWithAVTimezoneConverts() async throws {
        let vtimezone = [
            "BEGIN:VTIMEZONE", "TZID:America/Vancouver",
            "BEGIN:DAYLIGHT", "TZOFFSETFROM:-0800", "TZOFFSETTO:-0700", "TZNAME:PDT",
            "DTSTART:19700308T020000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU", "END:DAYLIGHT",
            "BEGIN:STANDARD", "TZOFFSETFROM:-0700", "TZOFFSETTO:-0800", "TZNAME:PST",
            "DTSTART:19701101T020000", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU", "END:STANDARD",
            "END:VTIMEZONE",
        ].joined(separator: "\r\n")
        let stored = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", vtimezone, "BEGIN:VEVENT",
            "UID:cv-6", "DTSTAMP:\(compact(day(-14)))T000000Z",
            "DTSTART;TZID=America/Vancouver:\(compact(day(0)))T090000",
            "DTEND;TZID=America/Vancouver:\(compact(day(0)))T100000", "SUMMARY:Planning",
            "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n")
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: "/cal/cv-6.ics", ics: stored)
        let rows = try await run(store, eventId: "/cal/cv-6.ics", [
            "all_day": .bool(true), "start_iso": .string(day(7)), "end_iso": .string(day(8)), "edit_scope": .string("all"),
        ], account: "kind-c-vtimezone")
        let ics = store.storedICS(path: "/cal/cv-6.ics")
        // The VTIMEZONE has DTSTART lines of its own, so the event's are read after BEGIN:VEVENT.
        let event = ics?.components(separatedBy: "BEGIN:VEVENT").last
        #expect(line(event, "DTSTART") == "DTSTART;VALUE=DATE:\(compact(day(7)))", "start: \(line(event, "DTSTART") ?? "<none>")")
        #expect(line(event, "DTEND") == "DTEND;VALUE=DATE:\(compact(day(8)))", "end: \(line(event, "DTEND") ?? "<none>")")
        #expect(ics?.contains(vtimezone) == true, "the VTIMEZONE was not kept byte for byte: \(ics ?? "<none>")")
        #expect(rows.isEmpty, "the conversion did not complete: \(rows.map { $0.failureReason ?? $0.status })")
    }
}

// MARK: - The queue's own decisions

@Suite("A calendar edit without all_day keeps the event's kind: the queue", .serialized, .processGlobalState)
struct CalendarQueueEditKindTests {

    /// A weekly all-day series, or with `recurring: false` a one-off all-day event: an edit of every
    /// occurrence of a series that moves it to another date with no occurrence named is a question
    /// for the user (`CalendarSeriesScopeTests`), so the moves of every occurrence here move a
    /// one-off event.
    private func allDayResource(start: String = day(0), end: String = day(1), recurring: Bool = true) -> GCalEvent {
        GCalEvent(
            id: "ev-1", summary: "Offsite", location: nil, description: nil,
            start: GCalDateTime(dateTime: nil, date: start, timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: end, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: recurring ? ["RRULE:FREQ=WEEKLY"] : nil,
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
        let occurrenceReads: Int
        let occurrenceEnds: [String?]
    }

    private func drain(_ arguments: [String: JSONValue], account: String, resource: GCalEvent?,
                       getEventThrows: Error? = nil, occurrenceStartDay: String? = nil,
                       occurrenceReadThrows: Error? = nil) async throws -> Drained {
        let mock = MockCalendarProvider()
        await mock.setOccurrenceStartDayResult(occurrenceStartDay)
        await mock.setOccurrenceStartDayThrows(occurrenceReadThrows)
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
                       getEventCalls: log.filter { $0.hasPrefix("getEvent(") }.count,
                       occurrenceReads: log.filter { $0.hasPrefix("occurrenceStartDay(") }.count,
                       occurrenceEnds: await mock.updatedOccurrences.map(\.event.endDate))
    }

    @Test("a move without all_day learns the kind from the event and renders all-day dates")
    func moveLearnsTheKind() async throws {
        let r = try await drain([
            "start_iso": .string("\(day(7))T00:00:00"), "end_iso": .string("\(day(8))T00:00:00"),
        ], account: "kind-q-learn", resource: allDayResource(recurring: false))
        #expect(r.getEventCalls == 1, "the kind was assumed, not learned from the event")
        guard r.updates.count == 1 else { Issue.record("updates: \(r.updates.count)"); return }
        #expect(r.updates[0].event.startDate == day(7) && r.updates[0].event.endDate == day(8),
                "patch: start \(r.updates[0].event.startDate ?? "nil") end \(r.updates[0].event.endDate ?? "nil")")
        #expect(r.updates[0].event.startDateTime == nil && r.updates[0].event.endDateTime == nil,
                "the patch carries timed values: \(r.updates[0].event.startDateTime ?? "nil")")
    }

    /// Start and end pairs that name a time of day; "" leaves that side out of the edit.
    private static let timedPairs: [[String]] = [
        ["\(day(7))T09:00:00", "\(day(7))T17:00:00"], ["\(day(7))T15:00:00", ""], ["", "\(day(8))T10:30:00"],
        ["\(day(7))T00:00:00", "\(day(7))T00:00:01"],
    ]

    @Test("a time of day on an all-day event without all_day is refused on every edit_scope, with nothing written",
          arguments: ["all", "this_only", "this_and_following"], Array(0..<4))
    func timeOfDayRefusedOnEveryScope(_ scope: String, _ pair: Int) async throws {
        let times = (start: Self.timedPairs[pair][0].isEmpty ? nil : Self.timedPairs[pair][0],
                     end: Self.timedPairs[pair][1].isEmpty ? nil : Self.timedPairs[pair][1])
        var args: [String: JSONValue] = ["edit_scope": .string(scope)]
        if let s = times.start { args["start_iso"] = .string(s) }
        if let e = times.end { args["end_iso"] = .string(e) }
        if scope != "all" { args["recurrence_id"] = .string("\(day(7))T00:00:00") }
        let label = "\(scope) \(times.start ?? "-") \(times.end ?? "-")"
        let r = try await drain(args, account: "kind-q-time-\(scope)-\(pair)", resource: allDayResource())
        #expect(r.writes == 0, "\(label): \(r.writes) write(s) reached the provider")
        #expect(r.rows.count == 1 && r.rows.first?.status == PendingStatus.failed.rawValue,
                "\(label): not retired: \(r.rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        #expect(r.rows.first?.failureReason?.contains(allDayTimeHint) == true,
                "\(label): reason \(r.rows.first?.failureReason ?? "<none>")")
    }

    @Test("dates of one day on an all-day event are refused on every edit_scope, with nothing written",
          arguments: ["all", "this_only", "this_and_following"])
    func refusedOnEveryScope(_ scope: String) async throws {
        var args: [String: JSONValue] = [
            "edit_scope": .string(scope),
            "start_iso": .string("\(day(7))T00:00:00"), "end_iso": .string(day(7)),
        ]
        if scope != "all" { args["recurrence_id"] = .string("\(day(7))T00:00:00") }
        let r = try await drain(args, account: "kind-q-refuse-\(scope)", resource: allDayResource())
        #expect(r.writes == 0, "\(scope): \(r.writes) write(s) reached the provider")
        #expect(r.rows.count == 1 && r.rows.first?.status == PendingStatus.failed.rawValue,
                "\(scope): not retired: \(r.rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        #expect(r.rows.first?.failureReason?.contains(allDayEndHint) == true,
                "\(scope): reason \(r.rows.first?.failureReason ?? "<none>")")
    }

    @Test("a stated all_day is taken at its word: true keeps the date, false converts (controls)")
    func statedKindIsNotAsked() async throws {
        let kept = try await drain([
            "all_day": .bool(true), "start_iso": .string("\(day(7))T15:00:00"), "end_iso": .string("\(day(8))T15:00:00"),
        ], account: "kind-q-stated-true", resource: allDayResource(recurring: false))
        #expect(kept.rows.isEmpty && kept.updates.first?.event.startDate == day(7),
                "rows: \(kept.rows.map { $0.failureReason ?? $0.status })")
        let timed = try await drain([
            "all_day": .bool(false), "start_iso": .string("\(day(7))T15:00:00"), "end_iso": .string("\(day(7))T16:00:00"),
        ], account: "kind-q-stated-false", resource: allDayResource(recurring: false))
        #expect(timed.rows.isEmpty && timed.updates.first?.event.startDateTime != nil,
                "rows: \(timed.rows.map { $0.failureReason ?? $0.status })")
    }

    @Test("a timed event given a time of day without all_day is written (control)")
    func timedEventWithTimeIsWritten() async throws {
        let r = try await drain([
            "start_iso": .string("\(day(7))T15:00:00"),
        ], account: "kind-q-timed-time", resource: timedResource())
        #expect(r.rows.isEmpty && r.updates.count == 1, "rows: \(r.rows.map { $0.failureReason ?? $0.status })")
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
        let r = try await drain(["end_iso": .string(day(3))], account: "kind-q-endok", resource: allDayResource(recurring: false))
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
            "recurrence_id": .string("\(day(7))T00:00:00"), "end_iso": .string("\(day(7))T00:00:00"),
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

    @Test("all_day: true with a start and an end reads only what finds the series: the kind and the start are both given (control)")
    func statedKindAndStartReadNothing() async throws {
        let r = try await drain([
            "all_day": .bool(true), "start_iso": .string(day(7)), "end_iso": .string(day(8)),
        ], account: "kind-q-stated", resource: allDayResource(recurring: false))
        // An edit of every occurrence reads the event once, to find whether it is an occurrence
        // and so which event to write (#560); the kind and the start are not read again.
        #expect(r.getEventCalls == 1, "an edit that states its kind and start read the event \(r.getEventCalls) time(s)")
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

    @Test("an edit that moves nothing and sets no UNTIL reads the event only to find its series (control)")
    func noFetchWhenNothingMoves() async throws {
        let r = try await drain([
            "title": .string("Renamed"), "description": .string("Notes"), "location": .string("Room 2"),
        ], account: "kind-q-nofetch", resource: allDayResource())
        // One read, which tells an occurrence from its series (#560); none for the kind.
        #expect(r.getEventCalls == 1, "an edit that moves nothing paid \(r.getEventCalls) round trip(s)")
        #expect(r.updates.count == 1)
    }

    @Test("an end alone on a moved occurrence is compared with the day it starts on now",
          arguments: [8, 9])
    func endOnOrBeforeAMovedOccurrencesStartIsRefused(_ endOffset: Int) async throws {
        // The occurrence of day 7 was moved to day 9. Both ends are after day 7.
        let r = try await drain([
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T00:00:00"),
            "end_iso": .string(day(endOffset)),
        ], account: "kind-q-moved-\(endOffset)", resource: allDayResource(), occurrenceStartDay: day(9))
        #expect(r.writes == 0, "\(r.writes) write(s): an occurrence ending on or before the start it keeps")
        #expect(r.rows.count == 1 && r.rows.first?.status == PendingStatus.failed.rawValue
                    && r.rows.first?.failureReason?.contains(allDayEndHint) == true,
                "rows: \(r.rows.map { "\($0.status) \($0.failureReason ?? "")" })")
    }

    @Test("an end alone after a moved occurrence's start is written, even one on or before its original day")
    func endAfterAMovedOccurrencesStartIsWritten() async throws {
        let later = try await drain([
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T00:00:00"),
            "end_iso": .string(day(11)),
        ], account: "kind-q-moved-later", resource: allDayResource(), occurrenceStartDay: day(9))
        #expect(later.occurrenceEnds == [day(11)] && later.rows.isEmpty,
                "rows: \(later.rows.map { $0.failureReason ?? $0.status })")
        #expect(later.occurrenceReads == 1)
        // Moved to day 5: an end on day 7 is on the original day and after the start it keeps.
        let earlier = try await drain([
            "recurrence_id": .string("\(day(7))T00:00:00"), "end_iso": .string(day(7)),
        ], account: "kind-q-moved-earlier", resource: allDayResource(), occurrenceStartDay: day(5))
        #expect(earlier.occurrenceEnds == [day(7)] && earlier.rows.isEmpty,
                "rows: \(earlier.rows.map { $0.failureReason ?? $0.status })")
    }

    @Test("the occurrence is read only for an end given alone on one all-day occurrence (controls)")
    func occurrenceIsReadOnlyWhenTheRuleNeedsIt() async throws {
        let rid = JSONValue.string("\(day(7))T00:00:00")
        let withStart = try await drain([
            "edit_scope": .string("this_only"), "recurrence_id": rid,
            "start_iso": .string(day(9)), "end_iso": .string(day(10)),
        ], account: "kind-q-noread-start", resource: allDayResource(), occurrenceStartDay: day(20))
        #expect(withStart.occurrenceReads == 0 && withStart.writes == 1)
        let split = try await drain([
            "edit_scope": .string("this_and_following"), "recurrence_id": rid, "end_iso": .string(day(9)),
        ], account: "kind-q-noread-split", resource: allDayResource(), occurrenceStartDay: day(20))
        #expect(split.occurrenceReads == 0 && split.writes == 1, "a split starts on recurrence_id's own day")
        let series = try await drain(["end_iso": .string(day(3))],
                                     account: "kind-q-noread-all", resource: allDayResource(), occurrenceStartDay: day(20))
        #expect(series.occurrenceReads == 0 && series.writes == 1)
        let timed = try await drain([
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T09:00:00"),
            "end_iso": .string("\(day(7))T10:00:00"),
        ], account: "kind-q-noread-timed", resource: timedResource(), occurrenceStartDay: day(20))
        #expect(timed.occurrenceReads == 0 && timed.writes == 1)
        // No end, no read: a stated all-day kind and one occurrence are not enough on their own.
        let titleOnly = try await drain([
            "edit_scope": .string("this_only"), "recurrence_id": rid, "all_day": .bool(true),
            "title": .string("Renamed"),
        ], account: "kind-q-noread-title", resource: allDayResource(), occurrenceStartDay: day(20))
        #expect(titleOnly.occurrenceReads == 0 && titleOnly.writes == 1,
                "reads \(titleOnly.occurrenceReads) writes \(titleOnly.writes)")
    }

    @Test("a failed read of the occurrence writes nothing and keeps the edit queued")
    func failedOccurrenceReadWritesNothing() async throws {
        let r = try await drain([
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T00:00:00"),
            "end_iso": .string(day(11)),
        ], account: "kind-q-moved-throws", resource: allDayResource(),
           occurrenceReadThrows: URLError(.notConnectedToInternet))
        #expect(r.writes == 0, "an end was written without knowing the start it is compared with")
        #expect(r.rows.count == 1 && r.rows.first?.status == PendingStatus.queued.rawValue,
                "the edit did not stay queued: \(r.rows.map { "\($0.status) \($0.failureReason ?? "")" })")
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

// MARK: - The edit tool refuses before its card, with the rule the queue applies

@Suite("calendar_event_edit refuses an all-day edit it cannot write before the card", .serialized, .processGlobalState)
struct CalendarEditToolAllDayEndTests {

    private func stored(allDay: Bool) -> GCalEvent {
        GCalEvent(
            id: "ev-1", summary: "Offsite", location: nil, description: nil,
            start: allDay ? GCalDateTime(dateTime: nil, date: day(0), timeZone: nil)
                          : GCalDateTime(dateTime: "\(day(0))T09:00:00Z", date: nil, timeZone: "UTC"),
            end: allDay ? GCalDateTime(dateTime: nil, date: day(1), timeZone: nil)
                        : GCalDateTime(dateTime: "\(day(0))T09:30:00Z", date: nil, timeZone: "UTC"),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil)
    }

    /// Confirms every card and counts them.
    @MainActor
    private final class CountingConfirmSink: AgentUISink {
        var cards = 0
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            cards += 1
            confirmation.onRespond(true)
        }
    }

    /// Runs the tool against a provider holding `event`, with the app's database installed (the
    /// tool queues its edit there) and the account in it; returns its output, the provider's
    /// writes, the edits left in the queue and the confirmation cards shown.
    /// `knownCalendarId` passes the event as the read tools leave it, a numeric id whose calendar
    /// the translator knows; without it the event id is a compound id and the calendar is found
    /// by the tool.
    private func run(_ arguments: [String: JSONValue], account: String, event: GCalEvent,
                     occurrenceStartDay: String? = nil, occurrenceReadThrows: Error? = nil,
                     knownCalendarId: String? = nil) async throws -> (out: String, writes: Int, queued: Int, cards: Int, log: [String]) {
        let mock = MockCalendarProvider()
        await mock.setGetEventResult(event)
        await mock.setUpdateOccurrenceResult(event)
        await mock.setOccurrenceStartDayResult(occurrenceStartDay)
        await mock.setOccurrenceStartDayThrows(occurrenceReadThrows)
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
            acc.id = account
            try acc.insert(db)
        }
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: account, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: account) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        var args = arguments
        let compoundId = CompoundEventId.make(accountId: account, eventId: "ev-1")
        if let knownCalendarId {
            let numericId = 41
            await translator.seed(compoundId, as: numericId)
            await translator.cacheEventDetail(
                realId: "ev-1", accountId: account, calendarId: knownCalendarId, calendarName: "Team",
                title: event.summary ?? "", startDate: nil, endDate: nil, isAllDay: event.start?.date != nil,
                location: nil, attendees: [], isRecurring: true, recurrenceRule: nil, availability: "busy",
                htmlLink: nil, eventTimeZone: nil)
            args["event_id"] = .string(String(numericId))
        } else {
            args["event_id"] = .string(compoundId)
        }
        let sink = CountingConfirmSink()
        let out = try await CalendarEventEditTool(context: ToolContext(db: db, translator: translator)).execute(
            arguments: args, invocation: ToolInvocation(uiSink: sink, sessionKey: "kind-tool-\(account)"))
        let writes = await mock.updatedEvents.count + (await mock.updatedOccurrences.count) + (await mock.splitSeriesCalls.count)
        let queued = try await pool.read { try PendingCalendarOperation.fetchCount($0) }
        return (out, writes, queued, await sink.cards, await mock.callLog)
    }

    @Test("an all-day event given a time of day without all_day is refused before the card, and nothing is queued")
    func timeOfDayIsRefusedBeforeTheCard() async throws {
        let r = try await run([
            "start_iso": .string("\(day(7))T15:00:00"), "end_iso": .string("\(day(7))T16:00:00"),
        ], account: "kind-tool-time", event: stored(allDay: true))
        #expect(r.out.contains(allDayTimeHint) && r.out.contains("NOT changed"), "got \(r.out)")
        #expect(r.writes == 0 && r.queued == 0 && r.cards == 0, "writes \(r.writes) queued \(r.queued) cards \(r.cards)")
    }

    @Test("all_day: true with the end on the start's day is refused before the card")
    func sameDayEndIsRefused() async throws {
        let r = try await run([
            "all_day": .bool(true), "start_iso": .string(day(7)), "end_iso": .string(day(7)),
        ], account: "kind-tool-end", event: stored(allDay: false))
        #expect(r.out.contains(allDayEndHint) && r.out.contains("NOT changed"), "got \(r.out)")
        #expect(r.writes == 0 && r.queued == 0 && r.cards == 0, "writes \(r.writes) queued \(r.queued) cards \(r.cards)")
    }

    @Test("a scoped end on the occurrence's own day is refused before the card, though the series starts earlier",
          arguments: ["this_only", "this_and_following"])
    func scopedEndOnTheOccurrenceDayIsRefused(_ scope: String) async throws {
        let r = try await run([
            "edit_scope": .string(scope), "recurrence_id": .string("\(day(7))T00:00:00"), "end_iso": .string(day(7)),
        ], account: "kind-tool-scope-\(scope)", event: stored(allDay: true))
        #expect(r.out.contains(allDayEndHint) && r.out.contains("NOT changed"), "got \(r.out)")
        #expect(r.writes == 0 && r.queued == 0 && r.cards == 0, "writes \(r.writes) queued \(r.queued) cards \(r.cards)")
    }

    @Test("an end alone on or before a moved occurrence's start is refused before the card", arguments: [8, 9])
    func endOnOrBeforeAMovedOccurrencesStartIsRefused(_ endOffset: Int) async throws {
        // The occurrence of day 7 was moved to day 9. Both ends are after day 7.
        let r = try await run([
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T00:00:00"),
            "end_iso": .string(day(endOffset)),
        ], account: "kind-tool-moved-\(endOffset)", event: stored(allDay: true), occurrenceStartDay: day(9))
        #expect(r.out.contains(allDayEndHint) && r.out.contains("NOT changed"), "got \(r.out)")
        #expect(r.writes == 0 && r.queued == 0 && r.cards == 0, "writes \(r.writes) queued \(r.queued) cards \(r.cards)")
    }

    @Test("an end alone after a moved occurrence's start reaches the card and is written")
    func endAfterAMovedOccurrencesStartIsWritten() async throws {
        // Moved to day 5: an end on day 7 is on the original day and after the start it keeps.
        let r = try await run([
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T00:00:00"),
            "end_iso": .string(day(7)),
        ], account: "kind-tool-moved-ok", event: stored(allDay: true), occurrenceStartDay: day(5))
        #expect(r.cards == 1 && r.writes == 1, "cards \(r.cards) writes \(r.writes) \(r.out)")
    }

    @Test("an event whose calendar is known is read on that calendar, in the edit's zone")
    func knownCalendarOccurrenceIsReadThere() async throws {
        // Moved to day 5: an end on day 7 is on the original day and after the start it keeps.
        let r = try await run([
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T00:00:00"),
            "end_iso": .string(day(7)), "timezone": .string("America/Vancouver"),
        ], account: "kind-tool-known-cal", event: stored(allDay: true), occurrenceStartDay: day(5),
           knownCalendarId: "team-calendar")
        let read = r.log.first { $0.hasPrefix("occurrenceStartDay(") }
        #expect(read == "occurrenceStartDay(calendarId:team-calendar,eventId:ev-1,recurrenceId:\(day(7))T00:00:00,recurrenceIdZone:America/Vancouver)",
                "read: \(read ?? "<none>")")
        #expect(r.cards == 1 && r.writes == 1, "cards \(r.cards) writes \(r.writes) \(r.out)")
    }

    @Test("an edit of one occurrence that gives no end reads no occurrence, so a failing read does not stop it")
    func editWithoutAnEndReadsNoOccurrence() async throws {
        let r = try await run([
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T00:00:00"),
            "title": .string("Renamed"),
        ], account: "kind-tool-rename", event: stored(allDay: true),
           occurrenceReadThrows: URLError(.notConnectedToInternet))
        #expect(r.cards == 1 && r.writes == 1, "cards \(r.cards) writes \(r.writes) \(r.out)")
    }

    @Test("when the occurrence cannot be read, the edit is not offered")
    func failedOccurrenceReadShowsNoCard() async throws {
        let r = try await run([
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T00:00:00"),
            "end_iso": .string(day(11)),
        ], account: "kind-tool-moved-throws", event: stored(allDay: true),
           occurrenceReadThrows: URLError(.notConnectedToInternet))
        #expect(r.out.contains("could not read the occurrence") && r.out.contains("NOT changed"), "got \(r.out)")
        #expect(r.writes == 0 && r.queued == 0 && r.cards == 0, "writes \(r.writes) queued \(r.queued) cards \(r.cards)")
    }

    @Test("an edit the rule allows reaches the card and is written (control)")
    func allowedEditIsNotRefused() async throws {
        let r = try await run([
            "start_iso": .string("\(day(7))T00:00:00"), "end_iso": .string("\(day(8))T00:00:00"),
        ], account: "kind-tool-allowed", event: stored(allDay: true))
        #expect(r.cards == 1 && r.writes == 1, "an all-day move at midnight did not reach the card and the provider: cards \(r.cards) writes \(r.writes) \(r.out)")
        let timed = try await run([
            "start_iso": .string("\(day(7))T15:00:00"), "end_iso": .string("\(day(7))T16:00:00"),
        ], account: "kind-tool-allowed-timed", event: stored(allDay: false))
        #expect(timed.cards == 1 && timed.writes == 1, "a timed move did not reach the card and the provider: cards \(timed.cards) writes \(timed.writes) \(timed.out)")
    }

    @Test("the shared rule refuses nothing the kind allows (controls)")
    func sharedRuleControls() {
        let allDay = GCalDateTime(dateTime: nil, date: day(0), timeZone: nil)
        let timed = GCalDateTime(dateTime: "\(day(0))T09:00:00Z", date: nil, timeZone: "UTC")
        let times: [String: JSONValue] = ["start_iso": .string("\(day(7))T09:00:00"), "end_iso": .string("\(day(7))T17:00:00")]
        func refusal(_ a: [String: JSONValue], _ s: GCalDateTime?) -> String? {
            CalendarToolHelpers.allDayEditRefusal(a, storedStart: s, scope: "all", recurrenceId: nil)
        }
        #expect(refusal(times, timed) == nil, "a timed event given a time was refused")
        #expect(refusal(times, nil) == nil, "an edit whose event was not read was refused as all-day")
        var toTimed = times; toTimed["all_day"] = .bool(false)
        #expect(refusal(toTimed, allDay) == nil, "a stated conversion to timed was refused")
        #expect(refusal(["start_iso": .string("\(day(7))T00:00:00"), "end_iso": .string("\(day(8))T00:00:00")], allDay) == nil, "midnight dates were refused")
        #expect(refusal(["all_day": .bool(true), "start_iso": .string(day(7)), "end_iso": .string(day(8))], timed) == nil)
        #expect(refusal(["title": .string("Renamed")], allDay) == nil, "an edit giving no times was refused")
        #expect(refusal(times, allDay)?.contains(allDayTimeHint) == true)
        #expect(refusal(["end_iso": .string(day(0))], allDay)?.contains(allDayEndHint) == true, "an end on the stored start was not refused")
    }

    // A stated all_day of the other kind with no start or end: the patch carries the kind only in its
    // start and end, so every provider would write the event as it was and report success.

    @Test("the shared rule refuses a stated all_day of the other kind that gives no start or end, and nothing else")
    func kindChangeWithoutTimesRule() {
        let allDay = GCalDateTime(dateTime: nil, date: day(0), timeZone: nil)
        let timed = GCalDateTime(dateTime: "\(day(0))T09:00:00Z", date: nil, timeZone: "UTC")
        let rid = "\(day(7))T00:00:00"
        let cases: [(label: String, args: [String: JSONValue], stored: GCalDateTime?, scope: String, refused: Bool)] = [
            ("true on a timed event", ["all_day": .bool(true)], timed, "all", true),
            ("false on an all-day event", ["all_day": .bool(false)], allDay, "all", true),
            ("false on an all-day event with a title", ["all_day": .bool(false), "title": .string("Renamed")], allDay, "all", true),
            ("true on one occurrence of a timed series", ["all_day": .bool(true), "recurrence_id": .string(rid)], timed, "this_only", true),
            ("false on a split of an all-day series", ["all_day": .bool(false), "recurrence_id": .string(rid)], allDay, "this_and_following", true),
            ("a title only, all-day", ["title": .string("Renamed")], allDay, "all", false),
            ("a title only, timed", ["title": .string("Renamed")], timed, "all", false),
            ("true on an all-day event", ["all_day": .bool(true), "title": .string("Renamed")], allDay, "all", false),
            ("false on a timed event", ["all_day": .bool(false), "title": .string("Renamed")], timed, "all", false),
            ("true, the event not read", ["all_day": .bool(true)], nil, "all", false),
            ("false, the event not read", ["all_day": .bool(false)], nil, "all", false),
            ("true with dates on a timed event", ["all_day": .bool(true), "start_iso": .string(day(7)), "end_iso": .string(day(8))], timed, "all", false),
            ("false with only a start on an all-day event", ["all_day": .bool(false), "start_iso": .string("\(day(7))T09:00:00")], allDay, "all", false),
            ("true with only a start on a timed event", ["all_day": .bool(true), "start_iso": .string(day(7))], timed, "all", false),
        ]
        for c in cases {
            let reason = CalendarToolHelpers.allDayEditRefusal(
                c.args, storedStart: c.stored, scope: c.scope, recurrenceId: CalendarToolHelpers.stringArgOpt(c.args, "recurrence_id"))
            if c.refused {
                #expect(reason?.contains(kindChangeTimesHint) == true, "\(c.label): \(reason ?? "not refused")")
                #expect(reason?.contains("ask the user") == true, "\(c.label): \(reason ?? "not refused")")
            } else {
                #expect(reason == nil, "\(c.label): refused with \(reason ?? "")")
            }
        }
    }

    /// The event as `provider`'s own `getEvent` reads it from that provider's fake: the shape the
    /// tool compares the stated kind with.
    private func providerShape(_ provider: String, allDay: Bool) async throws -> GCalEvent {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        switch provider {
        case "google":
            FakeGoogleCalendar([allDay ? FakeGoogleCalendar.allDay(id: "ev-1", start: day(0), end: day(1))
                                       : FakeGoogleCalendar.timed(id: "ev-1", day: day(0))]).install(on: http)
            return try await GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
                .getEvent(calendarId: "primary", eventId: "ev-1")
        case "outlook":
            FakeGraphCalendar([GraphFixture.event(id: "ev-1", online: false, allDay: allDay)]).install(on: http)
            return try await ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                      session: http.session)
                .getEvent(calendarId: "primary", eventId: "ev-1")
        default:
            let times = allDay
                ? ["DTSTART;VALUE=DATE:\(compact(day(0)))", "DTEND;VALUE=DATE:\(compact(day(1)))"]
                : ["DTSTART:\(compact(day(0)))T090000Z", "DTEND:\(compact(day(0)))T100000Z"]
            let store = FakeCalDAVStore(servesETags: true)
            store.seed(path: "/cal/ev-1.ics", ics: ([
                "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
                "UID:ev-1", "DTSTAMP:\(compact(day(-14)))T000000Z", "SUMMARY:Offsite",
            ] + times + ["END:VEVENT", "END:VCALENDAR"]).joined(separator: "\r\n"))
            http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
            let home = URL(string: "https://caldav.example.com/cal/")!
            return try await CalDAVProvider(
                client: CalDAVClient(username: "user@example.com", password: "pw", session: http.session),
                calendarHomeURL: home, serverBaseURL: home)
                .getEvent(calendarId: "/cal/", eventId: "/cal/ev-1.ics")
        }
    }

    @Test("all_day alone asking for the other kind is refused before the card and reported as not done, on every provider's event",
          arguments: ["google", "outlook", "caldav"], [true, false])
    func kindChangeWithoutTimesIsRefusedBeforeTheCard(_ provider: String, _ storedAllDay: Bool) async throws {
        let event = try await providerShape(provider, allDay: storedAllDay)
        #expect((event.start?.date != nil) == storedAllDay,
                "setup: \(provider) read the stored event as \(event.start?.date != nil ? "all-day" : "timed")")
        let label = "\(provider), \(storedAllDay ? "all-day made timed" : "timed made all-day")"
        let r = try await run(["all_day": .bool(!storedAllDay)],
                              account: "kind-tool-alone-\(provider)-\(storedAllDay)", event: event)
        #expect(r.out.contains(kindChangeTimesHint) && r.out.contains("NOT changed"), "\(label): got \(r.out)")
        #expect(r.writes == 0 && r.queued == 0 && r.cards == 0,
                "\(label): writes \(r.writes) queued \(r.queued) cards \(r.cards)")
    }

    @Test("a time of day is any non-zero hour, minute or second; a date, or midnight, is none")
    func timeOfDayRule() {
        for iso in ["\(day(7))T09:00:00", "\(day(7))T00:30", "\(day(7))T00:00:01", "\(day(7)) 15:00", "\(day(7))T09:00:00Z"] {
            #expect(CalendarToolHelpers.namesTimeOfDay(iso), "\(iso)")
        }
        for iso in [day(7), "\(day(7))T00:00:00", "\(day(7))T00:00", "\(day(7))T00:00:00Z", "\(day(7))T00:00:00+09:00",
                    "\(day(7))T00:00+09:00", "\(day(7))T00:00:00.000-07:00"] {
            #expect(!CalendarToolHelpers.namesTimeOfDay(iso), "\(iso)")
        }
        #expect(CalendarToolHelpers.allDayEditTimeRefusal(["end_iso": .string("\(day(7))T17:00:00")])?.contains(allDayTimeHint) == true)
        #expect(CalendarToolHelpers.allDayEditTimeRefusal(["start_iso": .string("\(day(7))T00:00:00"), "end_iso": .string(day(8))]) == nil)
        #expect(CalendarToolHelpers.allDayEditTimeRefusal(["title": .string("Renamed")]) == nil)
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
