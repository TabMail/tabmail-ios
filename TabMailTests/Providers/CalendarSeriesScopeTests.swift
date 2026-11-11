/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - An edit of every occurrence reaches the series
//
// **INVARIANT 1 (#560).** *An edit of every occurrence (`edit_scope` "all") changes the series,
// whichever of its occurrences the event id names.* On Google, Outlook and CalDAV the listings and
// `calendar_event_read` give an occurrence its own id; `updateEvent` given that id changed that
// occurrence alone, and the result still said the change applied to the entire series.
//
// **INVARIANT 2 (#559).** *A time change of every occurrence goes where Google Calendar takes it:*
// named from the series' first occurrence, the whole series moves; named from a later one, a new
// time of day on the date it is on now is the whole series' new time, and a new date changes that
// occurrence and the ones after it, the earlier ones staying; with no occurrence named and a new date
// other than the series' own, nothing is written and the assistant is told to ask the user. The
// series is never moved to start on a later occurrence's date. A change of an occurrence and the
// following ones named at the first occurrence is a change of the whole series. Dates are the
// series' own, in its zone.
//
// **INVARIANT 3.** *A series whose rule names its days or dates (BYDAY, BYMONTHDAY, BYYEARDAY,
// BYWEEKNO, BYMONTH, BYSETPOS) is never moved to another date with its stored rule:* every provider
// keeps the stored rule when the start moves, so it would go on repeating on the old days. Such an
// edit is refused before the card and before the write, with nothing written, unless it gives the new
// rule. A move to another time on the same date, and a move of a rule that names no days, pass.
//
// **INVARIANT 4 (the property).** *An occurrence is named by where it is now* (`recurrence_id` is
// the start the listing shows), *and an edit is either refused before its card (no card, nothing
// queued, nothing written) or, once the queue has drained, the calendar holds what the card said.*
// Never a refusal after the user confirmed, with one exception: a split at a later occurrence moved
// from its place in the series is not supported (#563, #687): its card is shown, and the write is a
// plain error with nothing written. A change of a moved FIRST occurrence and the following ones is
// an edit of the whole series, and is written.
//
// The assertions run on what the provider ends up holding (the Google and Graph fakes apply PATCH and
// POST to stored events, the CalDAV fake PUT), on the durable row, and, for the edit tool, on its card
// and its output. Every date is relative to today, in UTC.

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

/// The instant a stored start or end names: Google's `dateTime` with its offset, or Graph's wall time
/// read in the zone it is labelled with.
private func instant(_ value: Any?) -> Date? {
    guard let stored = value as? [String: Any], let dateTime = stored["dateTime"] as? String else { return nil }
    if let date = Date.fromISO8601(dateTime) { return date }
    guard let zone = (stored["timeZone"] as? String).flatMap({ CalendarTimeZoneResolver.zone(named: $0, in: .none) }) else { return nil }
    return EKEventStoreHelper.parseNaiveISO(String(dateTime.prefix(19)), timeZone: zone)
}

/// `yyyy-MM-ddTHH:mm:ss` in UTC as an instant.
private func utcAt(_ naive: String) -> Date? { Date.fromISO8601(naive + "Z") }

private func reasons(_ rows: [PendingCalendarOperation]) -> [String] { rows.map { "\($0.status) \($0.failureReason ?? "")" } }

/// The RFC 5545 weekday code (`MO`) of a `yyyy-MM-dd` date, in UTC.
private func weekdayCode(_ d: String) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    guard let date = EKEventStoreHelper.parseNaiveISO(d, timeZone: utc) else { return "" }
    return ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][cal.component(.weekday, from: date) - 1]
}

/// The words every refusal of a move to another date of a series on named days carries.
private let namedDaysRefusal = "repeats on named days"

private func timed(_ d: String, _ time: String = "09:00:00") -> GCalDateTime {
    GCalDateTime(dateTime: "\(d)T\(time)Z", date: nil, timeZone: "UTC")
}

private func gcalEvent(id: String, start: GCalDateTime?, end: GCalDateTime?, recurrence: [String]?,
                       series: String? = nil, original: GCalDateTime? = nil) -> GCalEvent {
    var e = GCalEvent(id: id, summary: "Standup", location: nil, description: nil, start: start, end: end,
                      attendees: nil, organizer: nil, recurrence: recurrence, transparency: nil, status: nil,
                      htmlLink: nil, created: nil, updated: nil, recurringEventId: series)
    e.originalStartTime = original
    return e
}

// MARK: - Google fixtures

/// A weekly Google series at 09:00 UTC from day 0, and its instances on day 0 (its first) and day 7,
/// each with its own id, as `events.instances` gives them.
private enum GoogleSeries {
    static let id = "ser-g"
    static func instanceId(_ d: String) -> String { "\(id)_\(compact(d))T090000Z" }
    static let first = instanceId(day(0))
    static let later = instanceId(day(7))
    /// A rule that names no days: the series repeats on its start's weekday.
    static let weekly = "RRULE:FREQ=WEEKLY"
    /// The same series' rule naming its weekday, as Google Calendar writes a weekly series.
    static let onItsWeekday = "RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(0)))"

    static func series(rule: String) -> [String: Any] { [
        "id": id, "summary": "Standup", "status": "confirmed",
        "start": ["dateTime": "\(day(0))T09:00:00Z", "timeZone": "UTC"],
        "end": ["dateTime": "\(day(0))T09:30:00Z", "timeZone": "UTC"],
        "recurrence": [rule],
    ] }

    static func instance(_ d: String) -> [String: Any] { [
        "id": instanceId(d), "summary": "Standup", "status": "confirmed", "recurringEventId": id,
        "start": ["dateTime": "\(d)T09:00:00Z", "timeZone": "UTC"],
        "end": ["dateTime": "\(d)T09:30:00Z", "timeZone": "UTC"],
        "originalStartTime": ["dateTime": "\(d)T09:00:00Z", "timeZone": "UTC"],
    ] }

    /// The instance at `d`'s place, moved on its own to `start`-`end` (UTC): Google keeps its place
    /// in `originalStartTime`, and its id names that place, so the id stays the same across the move.
    static func moved(_ d: String, start: String, end: String) -> [String: Any] {
        var e = instance(d)
        e["start"] = ["dateTime": "\(start)Z", "timeZone": "UTC"]
        e["end"] = ["dateTime": "\(end)Z", "timeZone": "UTC"]
        return e
    }

    /// The instance at `d`'s place, deleted: Google keeps it as a cancelled instance, which GET by
    /// its id returns and the instances list leaves out.
    static func deleted(_ d: String) -> [String: Any] {
        var e = instance(d)
        e["status"] = "cancelled"
        return e
    }

    static var calendar: [[String: Any]] { calendar(rule: weekly) }

    static func calendar(rule: String) -> [[String: Any]] { [series(rule: rule), instance(day(0)), instance(day(7))] }
}

/// `loseNext`: the first write of that method (`PATCH`, `POST`) is applied and its response lost.
private func google(_ seed: [[String: Any]], eventId: String, _ arguments: [String: JSONValue], account: String,
                    loseNext: String? = nil, drains: Int = 1)
    async throws -> (calendar: FakeGoogleCalendar, rows: [PendingCalendarOperation]) {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    let calendar = FakeGoogleCalendar(seed)
    calendar.install(on: http)
    if let loseNext { calendar.loseNextResponse(loseNext) }
    let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
    let rows = try await drainEdit(accountId: account, eventId: eventId, calendarId: "primary",
                                   arguments: arguments, provider: provider, drains: drains)
    return (calendar, rows)
}

// MARK: - Outlook fixtures

/// Graph's `ser-1` series (`GraphFixture`), with its first occurrence and a later one as Graph lists
/// them: each with its own id, `seriesMasterId`, and `originalStart`, its place in the series, written
/// with the series' offset as Graph writes it. Starts and ends are rendered as Graph renders them for
/// the device (`request` asks for the device's zone): its wall time, labelled with its zone.
private enum GraphSeries {
    static let first = "ser-1-occ-1"
    static let later = "ser-1-occ-2"

    static func onDevice(_ event: [String: Any], start: Date) -> [String: Any] {
        let zone = TimeZone.current.identifier
        var e = event
        e["start"] = ["dateTime": GraphFixture.wall(start, in: zone) + ".0000000", "timeZone": zone]
        e["end"] = ["dateTime": GraphFixture.wall(start.addingTimeInterval(1_800), in: zone) + ".0000000", "timeZone": zone]
        return e
    }

    static func occurrence(id: String, at start: Date) -> [String: Any] {
        var e = onDevice(GraphFixture.event(id: id, start: start, seriesMasterId: "ser-1"), start: start)
        e["originalStart"] = start.iso8601String(timeZone: eventZone)
        return e
    }

    /// The occurrence at `place`, moved on its own to `start`: Graph keeps its place in
    /// `originalStart`, and its id.
    static func moved(id: String, from place: Date, to start: Date) -> [String: Any] {
        onDevice(occurrence(id: id, at: place), start: start)
    }

    /// The series' own zone (its range's `recurrenceTimeZone`), whose offset Graph writes
    /// `originalStart` with.
    static let eventZone = TimeZone(identifier: "America/Los_Angeles")!

    /// The series, weekly on its weekday (Graph names the day), or with `daily` every seventh day
    /// (Graph's `daily` pattern, which names no days).
    static func series(daily: Bool = false) -> [String: Any] {
        var series = onDevice(GraphFixture.event(id: "ser-1", recurring: true), start: GraphFixture.start)
        if daily, var recurrence = series["recurrence"] as? [String: Any] {
            recurrence["pattern"] = ["type": "daily", "interval": 7, "month": 0, "dayOfMonth": 0,
                                     "firstDayOfWeek": "sunday", "index": "first"]
            series["recurrence"] = recurrence
        }
        return series
    }

    /// The series, its first occurrence, and `occurrences`.
    static func calendar(_ occurrences: [[String: Any]], daily: Bool = false) -> FakeGraphCalendar {
        FakeGraphCalendar([series(daily: daily), occurrence(id: first, at: GraphFixture.start)] + occurrences)
    }

    /// The series, its first occurrence, and the one a week later.
    static func calendar(daily: Bool = false) -> FakeGraphCalendar {
        calendar([occurrence(id: later, at: GraphFixture.occurrenceStart)], daily: daily)
    }
}

private func outlook(_ graph: FakeGraphCalendar, eventId: String, _ arguments: [String: JSONValue], account: String,
                     drains: Int = 1)
    async throws -> [PendingCalendarOperation] {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    graph.install(on: http)
    let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                            session: http.session)
    return try await drainEdit(accountId: account, eventId: eventId, calendarId: "primary",
                               arguments: arguments, provider: provider, drains: drains)
}

/// What the queue's drain records for an edit the provider says names no occurrence there now.
private let notFoundOnServer = "not found"

// MARK: - The queue: Google

@Suite("An edit of every occurrence reaches the series: Google", .serialized, .processGlobalState)
struct GoogleCalendarSeriesScopeTests {

    @Test("a rename given an occurrence's id renames the series, not that occurrence")
    func renameGivenAnOccurrenceRenamesTheSeries() async throws {
        let r = try await google(GoogleSeries.calendar, eventId: GoogleSeries.later, [
            "title": .string("Team standup"),
        ], account: "series-g-rename")
        #expect(r.calendar.event(GoogleSeries.id)?["summary"] as? String == "Team standup",
                "the series kept its title; writes: \(r.calendar.writes)")
        #expect(r.calendar.writes == ["PATCH \(GoogleSeries.id)"], "writes: \(r.calendar.writes)")
        #expect(r.rows.isEmpty, "rows: \(reasons(r.rows))")
    }

    @Test("a new time named from the first occurrence's id moves the whole series")
    func firstOccurrenceNamedMovesTheSeries() async throws {
        let r = try await google(GoogleSeries.calendar, eventId: GoogleSeries.first, [
            "start_iso": .string("\(day(0))T11:00:00"), "timezone": .string("UTC"),
        ], account: "series-g-first")
        let series = r.calendar.event(GoogleSeries.id)
        #expect(instant(series?["start"]) == utcAt("\(day(0))T11:00:00"),
                "the series did not move: \(series?["start"] ?? "none"); writes: \(r.calendar.writes)")
        #expect(r.calendar.writes == ["PATCH \(GoogleSeries.id)"], "writes: \(r.calendar.writes)")
        #expect(r.rows.isEmpty, "rows: \(reasons(r.rows))")
    }

    @Test("a new date named from the first occurrence's id moves the whole series to that date")
    func firstOccurrenceNamedMovesTheSeriesToAnotherDay() async throws {
        let r = try await google(GoogleSeries.calendar, eventId: GoogleSeries.first, [
            "start_iso": .string("\(day(1))T09:00:00"), "timezone": .string("UTC"),
        ], account: "series-g-first-day")
        let series = r.calendar.event(GoogleSeries.id)
        #expect(instant(series?["start"]) == utcAt("\(day(1))T09:00:00"),
                "the series did not move: \(series?["start"] ?? "none"); writes: \(r.calendar.writes)")
        #expect(r.calendar.writes == ["PATCH \(GoogleSeries.id)"], "writes: \(r.calendar.writes)")
    }

    @Test("a new date named from a later occurrence's id is not written as a move of the series or of that occurrence")
    func laterOccurrenceNamedIsNotAMoveOfTheSeries() async throws {
        let r = try await google(GoogleSeries.calendar, eventId: GoogleSeries.later, [
            "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC"),
        ], account: "series-g-later")
        #expect(r.calendar.writes.isEmpty, "writes: \(r.calendar.writes)")
        #expect(instant(r.calendar.event(GoogleSeries.id)?["start"]) == utcAt("\(day(0))T09:00:00"))
        #expect(r.rows.count == 1 && r.rows.first?.status == PendingStatus.failed.rawValue, "rows: \(reasons(r.rows))")
        #expect(r.rows.first?.failureReason?.contains(
            "a move from it on is edit_scope 'this_and_following' with recurrence_id '\(day(7))T09:00:00'") == true,
                "reason: \(r.rows.first?.failureReason ?? "<none>")")
    }

    @Test("a new time of day named from a later occurrence's id is the whole series' new time")
    func laterOccurrenceTimeOfDayMovesTheSeries() async throws {
        let r = try await google(GoogleSeries.calendar, eventId: GoogleSeries.later, [
            "start_iso": .string("\(day(7))T11:00:00"), "end_iso": .string("\(day(7))T11:45:00"), "timezone": .string("UTC"),
        ], account: "series-g-later-time")
        let series = r.calendar.event(GoogleSeries.id)
        #expect(instant(series?["start"]) == utcAt("\(day(0))T11:00:00"),
                "the series did not take the new time on its own date: \(series?["start"] ?? "none"); rows: \(reasons(r.rows))")
        #expect(instant(series?["end"]) == utcAt("\(day(0))T11:45:00"), "end: \(series?["end"] ?? "none")")
        #expect(r.calendar.writes == ["PATCH \(GoogleSeries.id)"], "writes: \(r.calendar.writes)")
        #expect(r.rows.isEmpty, "rows: \(reasons(r.rows))")
    }

    @Test("a new time of day named from a moved later occurrence, by the start the listing shows for it, is the whole series' new time")
    func movedLaterOccurrenceTimeOfDayMovesTheSeries() async throws {
        // Day 14's occurrence, moved on its own to day 16 at 13:00: the listing shows it there.
        let seed = GoogleSeries.calendar + [GoogleSeries.moved(day(14), start: "\(day(16))T13:00:00", end: "\(day(16))T13:30:00")]
        let r = try await google(seed, eventId: GoogleSeries.instanceId(day(14)), [
            "start_iso": .string("\(day(16))T11:00:00"), "timezone": .string("UTC"),
        ], account: "series-g-moved-time")
        #expect(instant(r.calendar.event(GoogleSeries.id)?["start"]) == utcAt("\(day(0))T11:00:00"),
                "the series did not take the new time on its own date: \(r.calendar.event(GoogleSeries.id)?["start"] ?? "none"); rows: \(reasons(r.rows))")
        #expect(r.calendar.writes == ["PATCH \(GoogleSeries.id)"], "writes: \(r.calendar.writes)")
        #expect(r.rows.isEmpty, "rows: \(reasons(r.rows))")
    }

    @Test("a change of an occurrence and the following ones named at the first occurrence moves the whole series")
    func followingAtTheFirstOccurrenceMovesTheSeries() async throws {
        let r = try await google(GoogleSeries.calendar, eventId: GoogleSeries.id, [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(0))T09:00:00"),
            "start_iso": .string("\(day(1))T10:00:00"), "timezone": .string("UTC"),
        ], account: "series-g-following-first")
        #expect(instant(r.calendar.event(GoogleSeries.id)?["start"]) == utcAt("\(day(1))T10:00:00"),
                "the series did not move: \(r.calendar.event(GoogleSeries.id)?["start"] ?? "none"); writes: \(r.calendar.writes)")
        #expect(r.calendar.writes == ["PATCH \(GoogleSeries.id)"], "split instead of moved: \(r.calendar.writes)")
        #expect(r.rows.isEmpty, "rows: \(reasons(r.rows))")
    }

    @Test("a change of an occurrence and the following ones before the series' first, or at a time no occurrence starts now, is refused as not found, with nothing written")
    func followingAtNoOccurrenceIsRefused() async throws {
        for (account, rid) in [("series-g-before", "\(day(-7))T09:00:00"), ("series-g-between", "\(day(7))T09:30:00"),
                               ("series-g-off-day", "\(day(3))T09:00:00")] {
            let r = try await google(GoogleSeries.calendar, eventId: GoogleSeries.id, [
                "edit_scope": .string("this_and_following"), "recurrence_id": .string(rid),
                "title": .string("Team standup"), "timezone": .string("UTC"),
            ], account: account)
            #expect(r.calendar.writes.isEmpty, "\(rid): writes \(r.calendar.writes)")
            #expect(r.rows.first?.failureReason?.contains(notFoundOnServer) == true, "\(rid): rows \(reasons(r.rows))")
        }
    }

    @Test("an occurrence moved onto another's time, named by its id and that time, is the one changed, never the other")
    func movedOntoAnothersTimeNamesItself() async throws {
        // Day 14's occurrence, moved on its own onto day 7's time, where day 7's occurrence still is.
        let seed = GoogleSeries.calendar + [GoogleSeries.moved(day(14), start: "\(day(7))T09:00:00", end: "\(day(7))T09:30:00")]
        let r = try await google(seed, eventId: GoogleSeries.instanceId(day(14)), [
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T09:00:00"),
            "title": .string("Team standup"), "timezone": .string("UTC"),
        ], account: "series-g-collision")
        #expect(r.calendar.writes == ["PATCH \(GoogleSeries.instanceId(day(14)))"], "writes: \(r.calendar.writes); rows \(reasons(r.rows))")
        #expect(r.calendar.event(GoogleSeries.later)?["summary"] as? String == "Standup", "the other occurrence was changed")
        #expect(r.rows.isEmpty, "rows: \(reasons(r.rows))")
        // Named by the series' id and that time, two occurrences start there: refused, nothing written.
        let ambiguous = try await google(seed, eventId: GoogleSeries.id, [
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T09:00:00"),
            "title": .string("Team standup"), "timezone": .string("UTC"),
        ], account: "series-g-collision-series")
        #expect(ambiguous.calendar.writes.isEmpty, "writes: \(ambiguous.calendar.writes)")
        #expect(ambiguous.rows.first?.status == PendingStatus.failed.rawValue, "rows: \(reasons(ambiguous.rows))")
    }

    @Test("an occurrence id with a recurrence_id that is not where it is now is refused as naming another occurrence, or none, with nothing written")
    func occurrenceIdWithAnotherStartIsRefused() async throws {
        let seed = GoogleSeries.calendar + [GoogleSeries.moved(day(14), start: "\(day(14))T13:00:00", end: "\(day(14))T13:30:00")]
        // Its place in the series: no occurrence starts there now.
        let atPlace = try await google(seed, eventId: GoogleSeries.instanceId(day(14)), [
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(14))T09:00:00"),
            "title": .string("Team standup"), "timezone": .string("UTC"),
        ], account: "series-g-place")
        #expect(atPlace.calendar.writes.isEmpty, "writes: \(atPlace.calendar.writes)")
        #expect(atPlace.rows.first?.failureReason?.contains(notFoundOnServer) == true, "rows: \(reasons(atPlace.rows))")
        // Another occurrence's start.
        let other = try await google(seed, eventId: GoogleSeries.instanceId(day(14)), [
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T09:00:00"),
            "title": .string("Team standup"), "timezone": .string("UTC"),
        ], account: "series-g-other")
        #expect(other.calendar.writes.isEmpty, "writes: \(other.calendar.writes)")
        #expect(other.rows.first?.failureReason?.contains(
            RecurrenceOccurrenceResolver.namesAnotherOccurrence("\(day(7))T09:00:00")) == true, "rows: \(reasons(other.rows))")
    }

    @Test("a new date with no occurrence named is refused, asking the user which occurrences")
    func newDateWithNoOccurrenceIsRefused() async throws {
        let r = try await google(GoogleSeries.calendar, eventId: GoogleSeries.id, [
            "start_iso": .string("\(day(3))T09:00:00"), "timezone": .string("UTC"),
        ], account: "series-g-ask")
        #expect(r.calendar.writes.isEmpty, "writes: \(r.calendar.writes)")
        #expect(instant(r.calendar.event(GoogleSeries.id)?["start"]) == utcAt("\(day(0))T09:00:00"))
        #expect(r.rows.first?.failureReason?.contains(CalendarSeriesScope.askWhichOccurrences) == true,
                "rows: \(reasons(r.rows))")
    }

    @Test("a new time on the series' own date with no occurrence named moves the series (control)")
    func sameDateWithNoOccurrenceMovesTheSeries() async throws {
        let r = try await google(GoogleSeries.calendar, eventId: GoogleSeries.id, [
            "start_iso": .string("\(day(0))T10:00:00"), "timezone": .string("UTC"),
        ], account: "series-g-same")
        #expect(instant(r.calendar.event(GoogleSeries.id)?["start"]) == utcAt("\(day(0))T10:00:00"),
                "writes: \(r.calendar.writes) rows: \(reasons(r.rows))")
    }

    @Test("recurrence_id naming the first occurrence with edit_scope all moves the series (control)")
    func recurrenceIdOfTheFirstMovesTheSeries() async throws {
        let r = try await google(GoogleSeries.calendar, eventId: GoogleSeries.id, [
            "edit_scope": .string("all"), "recurrence_id": .string("\(day(0))T09:00:00"),
            "start_iso": .string("\(day(2))T09:00:00"), "timezone": .string("UTC"),
        ], account: "series-g-rid-first")
        #expect(instant(r.calendar.event(GoogleSeries.id)?["start"]) == utcAt("\(day(2))T09:00:00"),
                "writes: \(r.calendar.writes) rows: \(reasons(r.rows))")
    }

    @Test("recurrence_id naming a later occurrence with edit_scope all is not written as a move of the series")
    func recurrenceIdOfALaterOccurrenceIsNotAMoveOfTheSeries() async throws {
        let r = try await google(GoogleSeries.calendar, eventId: GoogleSeries.id, [
            "edit_scope": .string("all"), "recurrence_id": .string("\(day(7))T09:00:00"),
            "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC"),
        ], account: "series-g-rid-later")
        #expect(r.calendar.writes.isEmpty, "writes: \(r.calendar.writes)")
        #expect(r.rows.first?.failureReason?.contains("this_and_following") == true, "rows: \(reasons(r.rows))")
    }

    @Test("recurrence_id before the series' first occurrence is refused as not found")
    func recurrenceIdBeforeTheSeriesIsRefused() async throws {
        let r = try await google(GoogleSeries.calendar, eventId: GoogleSeries.id, [
            "edit_scope": .string("all"), "recurrence_id": .string("\(day(-7))T09:00:00"),
            "start_iso": .string("\(day(-6))T09:00:00"), "timezone": .string("UTC"),
        ], account: "series-g-rid-before")
        #expect(r.calendar.writes.isEmpty, "writes: \(r.calendar.writes)")
        #expect(r.rows.first?.failureReason?.contains(notFoundOnServer) == true, "rows: \(reasons(r.rows))")
    }
}

// MARK: - The queue: Outlook

@Suite("An edit of every occurrence reaches the series: Outlook", .serialized, .processGlobalState)
struct ExchangeCalendarSeriesScopeTests {

    @Test("a rename given an occurrence's id renames the series, not that occurrence")
    func renameGivenAnOccurrenceRenamesTheSeries() async throws {
        let graph = GraphSeries.calendar()
        let rows = try await outlook(graph, eventId: GraphSeries.later, [
            "title": .string("Planning (renamed)"),
        ], account: "series-x-rename")
        #expect(graph.event("ser-1")?["subject"] as? String == "Planning (renamed)",
                "the series kept its subject; rows: \(reasons(rows))")
        #expect(graph.patches(GraphSeries.later).isEmpty, "the occurrence was patched: \(graph.patches(GraphSeries.later))")
        #expect(graph.event(GraphSeries.later)?["subject"] as? String == "Planning")
        #expect(rows.isEmpty, "rows: \(reasons(rows))")
    }

    @Test("a new time named from the first occurrence's id moves the whole series")
    func firstOccurrenceNamedMovesTheSeries() async throws {
        let graph = GraphSeries.calendar()
        let moved = GraphFixture.start.addingTimeInterval(3_600)
        let rows = try await outlook(graph, eventId: GraphSeries.first, [
            "start_iso": .string(GraphFixture.naive(moved)), "timezone": .string("UTC"),
        ], account: "series-x-first")
        #expect(instant(graph.event("ser-1")?["start"]) == moved,
                "the series did not move: \(graph.event("ser-1")?["start"] ?? "none"); rows: \(reasons(rows))")
        #expect(graph.patches(GraphSeries.first).isEmpty, "the occurrence was patched instead")
        #expect(rows.isEmpty, "rows: \(reasons(rows))")
    }

    @Test("a new date named from a later occurrence's id is not written as a move of the series or of that occurrence")
    func laterOccurrenceNamedIsNotAMoveOfTheSeries() async throws {
        let graph = GraphSeries.calendar()
        let rows = try await outlook(graph, eventId: GraphSeries.later, [
            "start_iso": .string(GraphFixture.naive(GraphFixture.occurrenceStart.addingTimeInterval(86_400))),
            "timezone": .string("UTC"),
        ], account: "series-x-later")
        #expect(graph.patches("ser-1").isEmpty && graph.patches(GraphSeries.later).isEmpty,
                "patched: series \(graph.patches("ser-1").count), occurrence \(graph.patches(GraphSeries.later).count)")
        #expect(rows.first?.failureReason?.contains(
            "recurrence_id '\(GraphFixture.naive(GraphFixture.occurrenceStart))'") == true, "rows: \(reasons(rows))")
    }

    @Test("a new date with no occurrence named is refused, asking the user which occurrences")
    func newDateWithNoOccurrenceIsRefused() async throws {
        let graph = GraphSeries.calendar()
        let rows = try await outlook(graph, eventId: "ser-1", [
            "start_iso": .string(GraphFixture.naive(GraphFixture.start.addingTimeInterval(2 * 86_400))),
            "timezone": .string("UTC"),
        ], account: "series-x-ask")
        #expect(graph.patches("ser-1").isEmpty, "the series was moved: \(graph.patches("ser-1"))")
        #expect(rows.first?.failureReason?.contains(CalendarSeriesScope.askWhichOccurrences) == true, "rows: \(reasons(rows))")
    }

    @Test("a moved occurrence named by its id and a time where it is not now is refused, with nothing written")
    func movedOccurrenceAtNoOccurrenceIsRefused() async throws {
        let place = GraphFixture.occurrenceStart
        let graph = GraphSeries.calendar([GraphSeries.moved(id: GraphSeries.later, from: place, to: place.addingTimeInterval(4 * 3_600))])
        // Its place in the series, and a time between.
        for (account, rid) in [("series-x-moved-place", place), ("series-x-moved-none", place.addingTimeInterval(2 * 3_600))] {
            let rows = try await outlook(graph, eventId: GraphSeries.later, [
                "edit_scope": .string("this_only"), "recurrence_id": .string(GraphFixture.naive(rid)),
                "title": .string("Planning (renamed)"), "timezone": .string("UTC"),
            ], account: account)
            #expect(graph.created.isEmpty && graph.patches("ser-1").isEmpty && graph.patches(GraphSeries.later).isEmpty,
                    "\(account): written")
            #expect(rows.first?.failureReason?.contains(notFoundOnServer) == true, "\(account): rows \(reasons(rows))")
        }
    }

    @Test("an all-day occurrence named by its id is placed on the date its place begins in the series' own zone, read there as Graph names it, a zone TabMail does not recognize included")
    func allDayOccurrenceIsPlacedInTheSeriesZone() async throws {
        // Measured: Graph gives an all-day occurrence's place as the instant its date begins in
        // the series' zone, and names that zone on the series only (its range's
        // `recurrenceTimeZone`); read in that zone, its date is the place. Tokyo's and Kathmandu's
        // date begins on the day before in UTC; Los Angeles' on the same day. A zone the server
        // knows by a name TabMail does not is read the same way.
        let date = GraphFixture.utcDay(GraphFixture.occurrenceStart)
        let moved = GraphFixture.utcDay(GraphFixture.occurrenceStart.addingTimeInterval(2 * 86_400))
        let kathmandu = try #require(TimeZone(identifier: "Asia/Kathmandu"))
        for (zone, name) in [("Asia/Tokyo", "Tokyo Standard Time"), ("Asia/Kathmandu", "Asia/Kathmandu"),
                             ("America/Los_Angeles", "Pacific Standard Time"), ("Asia/Kathmandu", "Custom Server Zone")] {
            var series = GraphFixture.event(id: "ser-ad", online: false, recurring: true, allDay: true)
            if var recurrence = series["recurrence"] as? [String: Any], var range = recurrence["range"] as? [String: Any] {
                range["recurrenceTimeZone"] = name
                recurrence["range"] = range
                series["recurrence"] = recurrence
            }
            var occurrence = GraphFixture.event(id: "ser-ad-occ", start: GraphFixture.occurrenceStart, online: false,
                                                seriesMasterId: "ser-ad", allDay: true)
            occurrence["originalStart"] = GraphFixture.allDayPlace(date, in: zone)
            let graph = FakeGraphCalendar([series, occurrence], zones: ["Custom Server Zone": kathmandu])
            let rows = try await outlook(graph, eventId: "ser-ad-occ", [
                "start_iso": .string("\(moved)T00:00:00"), "timezone": .string("UTC"),
            ], account: "series-x-all-day-\(name)")
            #expect(graph.patches("ser-ad").isEmpty && graph.patches("ser-ad-occ").isEmpty && graph.created.isEmpty,
                    "\(name): written")
            let reason = rows.first?.failureReason ?? "<none>"
            #expect(reason.contains(CalendarSeriesScope.laterOccurrenceRefusal("\(date)T00:00:00")), "\(name): \(reason)")
            #expect(graph.readZones("ser-ad-occ").contains(name), "\(name): the occurrence was not read in the series' zone: \(graph.readZones("ser-ad-occ"))")
        }
    }
}

// MARK: - The queue: a series on named days

/// A timed CalDAV series at 09:00 UTC from day 0, repeating by `rule`. Written in UTC with no
/// `TZID` it names no zone (#679); with `tzid` its times name that zone.
private func calDAVSeries(uid: String, rule: String, tzid: String? = nil) -> String {
    let (start, end) = tzid.map { ("DTSTART;TZID=\($0):\(compact(day(0)))T090000", "DTEND;TZID=\($0):\(compact(day(0)))T093000") }
        ?? ("DTSTART:\(compact(day(0)))T090000Z", "DTEND:\(compact(day(0)))T093000Z")
    return [
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
        "UID:\(uid)", "DTSTAMP:\(compact(day(-14)))T000000Z",
        start, end,
        rule, "SUMMARY:Standup", "END:VEVENT", "END:VCALENDAR",
    ].joined(separator: "\r\n")
}

private func calDAV(_ store: FakeCalDAVStore, eventId: String, _ arguments: [String: JSONValue], account: String)
    async throws -> [PendingCalendarOperation] {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
    http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
    let home = URL(string: "https://caldav.example.com/cal/")!
    let provider = CalDAVProvider(
        client: CalDAVClient(username: "user@example.com", password: "pw", session: http.session),
        calendarHomeURL: home, serverBaseURL: home)
    return try await drainEdit(accountId: account, eventId: eventId, calendarId: "/cal/",
                               arguments: arguments, provider: provider)
}

@Suite("A series whose rule names its days is not moved to another date without its new rule", .serialized, .processGlobalState)
struct CalendarSeriesDayMoveTests {

    private func refused(_ rows: [PendingCalendarOperation]) -> Bool {
        rows.count == 1 && rows.first?.status == PendingStatus.failed.rawValue
            && rows.first?.failureReason?.contains(namedDaysRefusal) == true
    }

    @Test("Google: every occurrence, named from the first, moved to another date is refused, with nothing written")
    func googleEveryOccurrenceToAnotherDateIsRefused() async throws {
        let r = try await google(GoogleSeries.calendar(rule: GoogleSeries.onItsWeekday), eventId: GoogleSeries.first, [
            "start_iso": .string("\(day(1))T09:00:00"), "timezone": .string("UTC"),
        ], account: "days-g-all")
        #expect(r.calendar.writes.isEmpty, "writes: \(r.calendar.writes)")
        #expect(instant(r.calendar.event(GoogleSeries.id)?["start"]) == utcAt("\(day(0))T09:00:00"))
        #expect(refused(r.rows), "rows: \(reasons(r.rows))")
    }

    @Test("Google: an occurrence and the following ones moved to another date are refused, with no split")
    func googleFollowingToAnotherDateIsRefused() async throws {
        let r = try await google(GoogleSeries.calendar(rule: GoogleSeries.onItsWeekday), eventId: GoogleSeries.id, [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(7))T09:00:00"),
            "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC"),
        ], account: "days-g-following")
        #expect(r.calendar.writes.isEmpty, "writes: \(r.calendar.writes)")
        #expect(refused(r.rows), "rows: \(reasons(r.rows))")
    }

    @Test("Google: every occurrence moved to another time on the same date moves the series and keeps its days")
    func googleEveryOccurrenceToAnotherTimeMoves() async throws {
        let r = try await google(GoogleSeries.calendar(rule: GoogleSeries.onItsWeekday), eventId: GoogleSeries.first, [
            "start_iso": .string("\(day(0))T11:00:00"), "timezone": .string("UTC"),
        ], account: "days-g-time")
        let series = r.calendar.event(GoogleSeries.id)
        #expect(instant(series?["start"]) == utcAt("\(day(0))T11:00:00"),
                "the series did not move: \(series?["start"] ?? "none"); rows: \(reasons(r.rows))")
        #expect(series?["recurrence"] as? [String] == [GoogleSeries.onItsWeekday], "rule: \(series?["recurrence"] ?? "none")")
        #expect(r.rows.isEmpty, "rows: \(reasons(r.rows))")
    }

    @Test("Google: an occurrence and the following ones moved to another time on its date split there")
    func googleFollowingToAnotherTimeSplits() async throws {
        let rid = "\(day(7))T09:00:00"
        let r = try await google(GoogleSeries.calendar(rule: GoogleSeries.onItsWeekday), eventId: GoogleSeries.id, [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string(rid),
            "start_iso": .string("\(day(7))T11:00:00"), "timezone": .string("UTC"),
        ], account: "days-g-following-time")
        let successor = r.calendar.event(
            GoogleCalendarProvider.deterministicSplitEventId(masterId: GoogleSeries.id, recurrenceId: rid))
        #expect(instant(successor?["start"]) == utcAt("\(day(7))T11:00:00"),
                "no following part at the new time: \(successor?["start"] ?? "none"); writes: \(r.calendar.writes); rows: \(reasons(r.rows))")
        #expect(r.rows.isEmpty, "rows: \(reasons(r.rows))")
    }

    @Test("Google: a move to another date that gives the new rule moves the series and writes that rule")
    func googleNewRuleWithTheMoveMoves() async throws {
        let r = try await google(GoogleSeries.calendar(rule: GoogleSeries.onItsWeekday), eventId: GoogleSeries.first, [
            "start_iso": .string("\(day(1))T09:00:00"), "timezone": .string("UTC"),
            "recurrence": .dictionary(["freq": .string("WEEKLY")]),
        ], account: "days-g-rule")
        let series = r.calendar.event(GoogleSeries.id)
        #expect(instant(series?["start"]) == utcAt("\(day(1))T09:00:00"),
                "the series did not move: \(series?["start"] ?? "none"); rows: \(reasons(r.rows))")
        #expect(series?["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY"], "rule: \(series?["recurrence"] ?? "none")")
        #expect(r.rows.isEmpty, "rows: \(reasons(r.rows))")
    }

    @Test("Google: a series kept in another zone, moved to the next of its own dates, is refused though the edit's zone sees the same date")
    func googleDatesAreTheSeriesOwn() async throws {
        // A series at 23:00 in Tokyo (14:00 UTC) on its weekday, named from its first occurrence.
        let id = "ser-t"
        let start: [String: Any] = ["dateTime": "\(day(0))T23:00:00+09:00", "timeZone": "Asia/Tokyo"]
        let end: [String: Any] = ["dateTime": "\(day(0))T23:30:00+09:00", "timeZone": "Asia/Tokyo"]
        let seed: [[String: Any]] = [
            ["id": id, "summary": "Standup", "status": "confirmed", "start": start, "end": end,
             "recurrence": [GoogleSeries.onItsWeekday]],
            ["id": "\(id)_first", "summary": "Standup", "status": "confirmed", "recurringEventId": id,
             "start": start, "end": end, "originalStartTime": start],
        ]
        // 16:00 UTC is the same date in UTC and the next date in Tokyo.
        let moved = try await google(seed, eventId: "\(id)_first", [
            "start_iso": .string("\(day(0))T16:00:00"), "timezone": .string("UTC"),
        ], account: "days-g-zone")
        #expect(moved.calendar.writes.isEmpty, "writes: \(moved.calendar.writes)")
        #expect(refused(moved.rows), "rows: \(reasons(moved.rows))")
        #expect(moved.rows.first?.failureReason?.contains("from \(day(0)) to \(day(1))") == true, "rows: \(reasons(moved.rows))")
        // 10:00 UTC is 19:00 the same day in Tokyo (control).
        let kept = try await google(seed, eventId: "\(id)_first", [
            "start_iso": .string("\(day(0))T10:00:00"), "timezone": .string("UTC"),
        ], account: "days-g-zone-control")
        #expect(instant(kept.calendar.event(id)?["start"]) == utcAt("\(day(0))T10:00:00"),
                "the series did not move: \(kept.calendar.event(id)?["start"] ?? "none"); rows: \(reasons(kept.rows))")
        #expect(kept.rows.isEmpty, "rows: \(reasons(kept.rows))")
    }

    @Test("Outlook: every occurrence of a weekly series (its weekday named), named from the first, moved to another date is refused")
    func outlookEveryOccurrenceToAnotherDateIsRefused() async throws {
        let graph = GraphSeries.calendar()
        let rows = try await outlook(graph, eventId: GraphSeries.first, [
            "start_iso": .string(GraphFixture.naive(GraphFixture.start.addingTimeInterval(86_400))),
            "timezone": .string("UTC"),
        ], account: "days-x-all")
        #expect(graph.patches("ser-1").isEmpty && graph.patches(GraphSeries.first).isEmpty,
                "patched: series \(graph.patches("ser-1").count), occurrence \(graph.patches(GraphSeries.first).count)")
        #expect(refused(rows), "rows: \(reasons(rows))")
    }

    @Test("CalDAV: a series on named weekdays moved to another date is refused, with nothing PUT")
    func calDAVToAnotherDateIsRefused() async throws {
        let rule = "RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(0)))"
        for (account, arguments): (String, [String: JSONValue]) in [
            ("days-c-all", ["edit_scope": .string("all"),
                            "start_iso": .string("\(day(0))T09:00:00"), "timezone": .string("UTC")]),
            ("days-c-following", ["edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(7))T09:00:00"),
                                  "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC")]),
        ] {
            let store = FakeCalDAVStore(servesETags: true)
            let ics = calDAVSeries(uid: "wk-1", rule: rule)
            store.seed(path: "/cal/wk-1.ics", ics: ics)
            // A series kept in UTC names no zone (#679): its dates can't be told, so even the move to
            // its own date is refused; one on another date is refused all the more.
            let rows = try await calDAV(store, eventId: "/cal/wk-1.ics", arguments, account: account)
            #expect(store.recordedPuts().isEmpty, "\(account): \(store.recordedPuts().count) PUT")
            #expect(store.storedICS(path: "/cal/wk-1.ics") == ics, "\(account): the series changed")
            #expect(rows.count == 1 && rows.first?.status == PendingStatus.failed.rawValue, "\(account): rows \(reasons(rows))")
        }
    }

    @Test("CalDAV: a series whose rule names no days moves to another time on its date (control)")
    func calDAVWithoutNamedDaysMoves() async throws {
        let store = FakeCalDAVStore(servesETags: true)
        // Its zone named: a series kept in UTC names none (#679), so its dates can't be told.
        store.seed(path: "/cal/wk-2.ics", ics: calDAVSeries(uid: "wk-2", rule: "RRULE:FREQ=WEEKLY", tzid: "Etc/UTC"))
        let rows = try await calDAV(store, eventId: "/cal/wk-2.ics", [
            "edit_scope": .string("all"),
            "start_iso": .string("\(day(0))T10:00:00"), "timezone": .string("UTC"),
        ], account: "days-c-control")
        let start = store.storedICS(path: "/cal/wk-2.ics")?.components(separatedBy: "\r\n").first { $0.hasPrefix("DTSTART") }
        #expect(start?.contains("\(compact(day(0)))T100000") == true, "start: \(start ?? "<none>"); rows: \(reasons(rows))")
        #expect(rows.isEmpty, "rows: \(reasons(rows))")
    }
}

// MARK: - The edit tool

/// Confirms every card and keeps what each showed.
@MainActor
private final class RecordingCardSink: AgentUISink {
    var cards: [AgentToolRouter.ActionConfirmation.CalendarEventDetail] = []
    func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
        cards.append(contentsOf: confirmation.calendarEvents)
        confirmation.onRespond(true)
    }
}

private struct ToolRun {
    let out: String
    let cards: [AgentToolRouter.ActionConfirmation.CalendarEventDetail]
    let queued: [PendingCalendarOperation]
    /// Declined before anything was read (`ToolDeclinedError`): the tool's own argument check.
    var declined: Bool = false
}

/// Runs `calendar_event_edit` for `eventId` on `account`, with `provider` registered for it and the
/// app's database installed (the tool queues its edit there, and waits for the drain to write it).
private func runTool(_ arguments: [String: JSONValue], eventId: String, account: String,
                     provider: any CalendarProvider) async throws -> ToolRun {
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
    await AccountManager.shared.registerCalendarProviderForTesting(accountId: account, provider: provider)
    defer {
        Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: account) }
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }
    let db = try TestDatabase.make()
    var args = arguments
    args["event_id"] = .string(CompoundEventId.make(accountId: account, eventId: eventId))
    let sink = RecordingCardSink()
    let out: String
    var declined = false
    do {
        out = try await CalendarEventEditTool(context: ToolContext(db: db, translator: MockChatIdTranslator()))
            .execute(arguments: args, invocation: ToolInvocation(uiSink: sink, sessionKey: "series-tool-\(account)"))
    } catch let error as ToolDeclinedError {
        out = error.output
        declined = true
    }
    let queued = try await pool.read { try PendingCalendarOperation.fetchAll($0) }
    return ToolRun(out: out, cards: await sink.cards, queued: queued, declined: declined)
}

private func googleTool(_ arguments: [String: JSONValue], eventId: String, account: String,
                        rule: String = GoogleSeries.weekly, seed: [[String: Any]]? = nil)
    async throws -> (calendar: FakeGoogleCalendar, run: ToolRun) {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    let calendar = FakeGoogleCalendar(seed ?? GoogleSeries.calendar(rule: rule))
    calendar.install(on: http)
    let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
    return (calendar, try await runTool(arguments, eventId: eventId, account: account, provider: provider))
}

private func outlookTool(_ graph: FakeGraphCalendar, _ arguments: [String: JSONValue], eventId: String,
                         account: String) async throws -> ToolRun {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    graph.install(on: http)
    let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                            session: http.session)
    return try await runTool(arguments, eventId: eventId, account: account, provider: provider)
}

@Suite("calendar_event_edit takes a time change of every occurrence where Google Calendar does", .serialized, .processGlobalState)
struct CalendarEditToolSeriesScopeTests {

    @Test("Google: named from a later occurrence, that occurrence and the following ones change, and the earlier ones stay")
    func laterOccurrenceIsSplitOnGoogle() async throws {
        let rid = "\(day(7))T09:00:00"
        let r = try await googleTool([
            "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "series-tool-g-later")
        let successorId = GoogleCalendarProvider.deterministicSplitEventId(masterId: GoogleSeries.id, recurrenceId: rid)
        let successor = r.calendar.event(successorId)
        #expect(instant(successor?["start"]) == utcAt("\(day(8))T09:00:00"),
                "no following part starts on the new date: \(successor?["start"] ?? "none"); writes: \(r.calendar.writes); \(r.run.out)")
        let master = r.calendar.event(GoogleSeries.id)
        #expect(instant(master?["start"]) == utcAt("\(day(0))T09:00:00"),
                "the earlier occurrences moved: \(master?["start"] ?? "none")")
        #expect((master?["recurrence"] as? [String])?.contains { $0.contains("UNTIL=\(compact(day(7)))") || $0.contains("UNTIL=\(compact(day(6)))") } == true,
                "the earlier part does not end before the split: \(master?["recurrence"] ?? "none")")
        #expect(r.run.cards.first?.changes.contains("scope → this and all future occurrences (starting \(rid))") == true,
                "card: \(r.run.cards.first?.changes ?? [])")
        #expect(r.run.out.contains("edit_scope: this_and_following"), "\(r.run.out)")
    }

    @Test("Google: a new date with no occurrence named is refused before the card, asking the user")
    func newDateWithNoOccurrenceIsRefusedBeforeTheCard() async throws {
        let r = try await googleTool([
            "start_iso": .string("\(day(3))T09:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.id, account: "series-tool-g-ask")
        #expect(r.run.out.contains(CalendarSeriesScope.askWhichOccurrences) && r.run.out.contains("NOT changed"), "\(r.run.out)")
        #expect(r.run.cards.isEmpty && r.run.queued.isEmpty && r.calendar.writes.isEmpty,
                "cards \(r.run.cards.count) queued \(r.run.queued.count) writes \(r.calendar.writes)")
    }

    @Test("Google: named from the first occurrence's id, the card shows the series and the series moves to the new date")
    func firstOccurrenceMovesTheSeriesThroughTheTool() async throws {
        let r = try await googleTool([
            "start_iso": .string("\(day(1))T09:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.first, account: "series-tool-g-first")
        #expect(instant(r.calendar.event(GoogleSeries.id)?["start"]) == utcAt("\(day(1))T09:00:00"),
                "the series did not move; writes: \(r.calendar.writes); \(r.run.out)")
        #expect(r.calendar.writes == ["PATCH \(GoogleSeries.id)"], "writes: \(r.calendar.writes)")
        #expect(r.run.out.contains("edit_scope: all"), "\(r.run.out)")
    }

    @Test("Google: a rename given a later occurrence's id shows the series on the card and renames it")
    func renameShowsTheSeriesOnTheCard() async throws {
        let r = try await googleTool(["title": .string("Team standup")], eventId: GoogleSeries.later,
                                     account: "series-tool-g-rename")
        let seriesStart = try #require(Date.fromISO8601("\(day(0))T09:00:00Z"))
        #expect(r.run.cards.first?.startDate == seriesStart,
                "the card shows \(String(describing: r.run.cards.first?.startDate)), not the series' start")
        #expect(r.calendar.event(GoogleSeries.id)?["summary"] as? String == "Team standup", "writes: \(r.calendar.writes)")
        #expect(r.calendar.event(GoogleSeries.later)?["summary"] as? String == "Standup")
    }

    @Test("Outlook: named from a later occurrence, a new time of day on its date is the whole series' new time")
    func laterOccurrenceTimeOfDayMovesTheSeriesOnOutlook() async throws {
        let graph = GraphSeries.calendar()
        let seriesStart = GraphFixture.start.addingTimeInterval(3_600)
        let r = try await outlookTool(graph, [
            "start_iso": .string(GraphFixture.naive(GraphFixture.occurrenceStart.addingTimeInterval(3_600))),
            "timezone": .string("UTC"),
        ], eventId: GraphSeries.later, account: "series-tool-x-later-time")
        #expect(instant(graph.event("ser-1")?["start"]) == seriesStart,
                "the series did not take the new time on its own date: \(graph.event("ser-1")?["start"] ?? "none"); \(r.out)")
        #expect(graph.created.isEmpty, "a following part was created: \(graph.created.count)")
        let range = ((graph.event("ser-1")?["recurrence"] as? [String: Any])?["range"] as? [String: Any])
        #expect(range?["type"] as? String == "noEnd", "the series was capped: \(range ?? [:])")
        #expect(graph.patches(GraphSeries.later).isEmpty, "the occurrence was moved on its own")
        #expect(r.cards.first?.changes.contains("start → \(GraphFixture.naive(seriesStart))") == true,
                "card: \(r.cards.first?.changes ?? [])")
        #expect(r.out.contains("edit_scope: all"), "\(r.out)")
    }

    @Test("Outlook: named from a later occurrence, a new date changes it and the following ones, and the earlier ones stay")
    func laterOccurrenceToAnotherDateIsSplitOnOutlook() async throws {
        // A series every seventh day names no days, so a move to another date is not refused for them.
        let graph = GraphSeries.calendar(daily: true)
        let newStart = GraphFixture.occurrenceStart.addingTimeInterval(86_400 + 3_600)
        let r = try await outlookTool(graph, [
            "start_iso": .string(GraphFixture.naive(newStart)), "timezone": .string("UTC"),
        ], eventId: GraphSeries.later, account: "series-tool-x-later-day")
        #expect(graph.created.count == 1, "no following part was created: \(r.out)")
        #expect(instant(graph.created.first?["start"]) == newStart,
                "the following part starts \(graph.created.first?["start"] ?? "none")")
        let range = ((graph.event("ser-1")?["recurrence"] as? [String: Any])?["range"] as? [String: Any])
        #expect(range?["type"] as? String == "endDate", "the earlier part was not capped: \(range ?? [:])")
        #expect(instant(graph.event("ser-1")?["start"]) == GraphFixture.start,
                "the earlier occurrences moved: \(graph.event("ser-1")?["start"] ?? "none")")
        #expect(graph.patches(GraphSeries.later).isEmpty, "the occurrence was moved on its own")
        #expect(r.out.contains("edit_scope: this_and_following"), "\(r.out)")
    }

    @Test("Google: named from a later occurrence, a new time of day on its date is the whole series' new time")
    func laterOccurrenceTimeOfDayMovesTheSeriesOnGoogle() async throws {
        let r = try await googleTool([
            "start_iso": .string("\(day(7))T11:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "series-tool-g-later-time", rule: GoogleSeries.onItsWeekday)
        let series = r.calendar.event(GoogleSeries.id)
        #expect(instant(series?["start"]) == utcAt("\(day(0))T11:00:00"),
                "the series did not take the new time on its own date: \(series?["start"] ?? "none"); \(r.run.out)")
        #expect(series?["recurrence"] as? [String] == [GoogleSeries.onItsWeekday], "rule: \(series?["recurrence"] ?? "none")")
        #expect(r.calendar.writes == ["PATCH \(GoogleSeries.id)"], "writes: \(r.calendar.writes)")
        #expect(r.run.cards.first?.changes.contains("start → \(day(0))T11:00:00") == true,
                "card: \(r.run.cards.first?.changes ?? [])")
        #expect(r.run.out.contains("edit_scope: all"), "\(r.run.out)")
    }

    @Test("Google: a change of an occurrence and the following ones named at the first occurrence moves the whole series")
    func followingAtTheFirstOccurrenceMovesTheSeriesThroughTheTool() async throws {
        let r = try await googleTool([
            "edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(0))T09:00:00"),
            "start_iso": .string("\(day(0))T10:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.id, account: "series-tool-g-following-first")
        #expect(instant(r.calendar.event(GoogleSeries.id)?["start"]) == utcAt("\(day(0))T10:00:00"),
                "the series did not move; writes: \(r.calendar.writes); \(r.run.out)")
        #expect(r.calendar.writes == ["PATCH \(GoogleSeries.id)"], "writes: \(r.calendar.writes)")
        #expect(r.run.out.contains("edit_scope: all"), "\(r.run.out)")
        #expect(r.run.cards.first?.changes.contains { $0.hasPrefix("scope → this and all future") } == false,
                "card: \(r.run.cards.first?.changes ?? [])")
    }

    @Test("Google: the card names an occurrence by one time, where it is now")
    func cardNamesAnOccurrenceByWhereItIsNow() async throws {
        // Day 14's occurrence, moved on its own to 13:00; changed on its own, by where it is now.
        let seed = GoogleSeries.calendar + [GoogleSeries.moved(day(14), start: "\(day(14))T13:00:00", end: "\(day(14))T13:30:00")]
        let r = try await googleTool([
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(14))T13:00:00"),
            "title": .string("Team standup"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.instanceId(day(14)), account: "series-tool-g-moved-card", seed: seed)
        let card = r.run.cards.first
        #expect(card?.changes.contains("scope → just this occurrence (\(day(14))T13:00:00)") == true, "card: \(card?.changes ?? [])")
        #expect(card?.changes.contains { $0.contains("originally") } == false, "card: \(card?.changes ?? [])")
        #expect(card?.startDate == utcAt("\(day(14))T13:00:00"), "the card shows \(String(describing: card?.startDate))")
        #expect(r.calendar.event(GoogleSeries.instanceId(day(14)))?["summary"] as? String == "Team standup",
                "writes: \(r.calendar.writes); \(r.run.out)")
    }

    @Test("Google: a change of a moved later occurrence and the following ones shows its card, then errors at the write with nothing written (#563)")
    func followingAtAMovedLaterOccurrenceErrorsAtTheWrite() async throws {
        // Day 14's occurrence, moved on its own to 13:00, named by its id and where it is now.
        let seed = GoogleSeries.calendar + [GoogleSeries.moved(day(14), start: "\(day(14))T13:00:00", end: "\(day(14))T13:30:00")]
        let r = try await googleTool([
            "edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(14))T13:00:00"),
            "title": .string("Team standup"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.instanceId(day(14)), account: "series-tool-g-moved-following", seed: seed)
        #expect(r.run.cards.count == 1 && r.run.cards.first.map { Extent(changes: $0.changes) } == .fromHereOn,
                "no card for the split: \(r.run.cards.map(\.changes)); \(r.run.out)")
        #expect(r.calendar.writes.isEmpty, "writes: \(r.calendar.writes)")
        #expect(r.run.queued.count == 1 && r.run.queued.allSatisfy { $0.status == PendingStatus.failed.rawValue },
                "the split did not end failed: \(reasons(r.run.queued))")
    }

    @Test("Outlook: a new date of every occurrence named at a moved later occurrence shows the split's card, then errors at the write with nothing written (#563)")
    func everyOccurrenceToAnotherDateAtAMovedOccurrenceErrorsAtTheWrite() async throws {
        // The later occurrence, moved on its own two days on, named by its id; the series every seventh
        // day names no days. Its new date is a split there, which is not supported.
        let place = GraphFixture.occurrenceStart
        let now = place.addingTimeInterval(2 * 86_400)
        let graph = GraphSeries.calendar([GraphSeries.moved(id: GraphSeries.later, from: place, to: now)], daily: true)
        let r = try await outlookTool(graph, [
            "edit_scope": .string("all"), "start_iso": .string(GraphFixture.naive(now.addingTimeInterval(86_400))),
            "timezone": .string("UTC"),
        ], eventId: GraphSeries.later, account: "series-tool-x-moved-all")
        #expect(r.cards.count == 1 && r.cards.first.map { Extent(changes: $0.changes) } == .fromHereOn,
                "no card for the split: \(r.cards.map(\.changes)); \(r.out)")
        #expect(graph.created.isEmpty && graph.patches("ser-1").isEmpty && graph.patches(GraphSeries.later).isEmpty,
                "written: created \(graph.created.count); \(r.out)")
        #expect(r.queued.count == 1 && r.queued.allSatisfy { $0.status == PendingStatus.failed.rawValue },
                "the split did not end failed: \(reasons(r.queued))")
    }

    @Test("Google: a change of the series' first occurrence and the following ones, moved from its place, is an edit of the whole series and is written")
    func followingAtAMovedFirstOccurrenceEditsTheSeries() async throws {
        // The first occurrence, moved on its own a day on, named by its id and where it is now. From the
        // first occurrence on is every occurrence: no split is written, so its move does not matter.
        let seed = GoogleSeries.calendar.filter { $0["id"] as? String != GoogleSeries.first }
            + [GoogleSeries.moved(day(0), start: "\(day(1))T09:00:00", end: "\(day(1))T09:30:00")]
        let r = try await googleTool([
            "edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(1))T09:00:00"),
            "title": .string("Team standup"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.first, account: "series-tool-g-moved-first-following", seed: seed)
        #expect(r.run.cards.count == 1 && r.run.cards.first.map { Extent(changes: $0.changes) } == .whole,
                "not shown as the whole series: \(r.run.cards.map(\.changes)); \(r.run.out)")
        #expect(r.calendar.event(GoogleSeries.id)?["summary"] as? String == "Team standup",
                "the series was not renamed; writes: \(r.calendar.writes); \(r.run.out)")
        #expect(r.calendar.writes == ["PATCH \(GoogleSeries.id)"], "writes: \(r.calendar.writes)")
        #expect(r.run.queued.isEmpty, "rows: \(reasons(r.run.queued))")
        #expect(r.run.out.contains("edit_scope: all"), "\(r.run.out)")
    }

    @Test("Google: a series on named weekdays, named from a later occurrence and moved to another date, is refused before the card")
    func laterOccurrenceToAnotherDateIsRefusedOnNamedDays() async throws {
        let r = try await googleTool([
            "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "series-tool-g-byday", rule: GoogleSeries.onItsWeekday)
        #expect(r.run.out.contains(namedDaysRefusal) && r.run.out.contains("NOT changed"), "\(r.run.out)")
        #expect(r.run.cards.isEmpty && r.run.queued.isEmpty && r.calendar.writes.isEmpty,
                "cards \(r.run.cards.count) queued \(r.run.queued.count) writes \(r.calendar.writes)")
    }

    @Test("Outlook: a weekly series (its weekday named), named from a later occurrence and moved to another date, is refused before the card")
    func laterOccurrenceToAnotherDateIsRefusedOnOutlook() async throws {
        let graph = GraphSeries.calendar()
        let r = try await outlookTool(graph, [
            "start_iso": .string(GraphFixture.naive(GraphFixture.occurrenceStart.addingTimeInterval(86_400))),
            "timezone": .string("UTC"),
        ], eventId: GraphSeries.later, account: "series-tool-x-byday")
        #expect(r.out.contains(namedDaysRefusal) && r.out.contains("NOT changed"), "\(r.out)")
        #expect(r.cards.isEmpty && r.queued.isEmpty, "cards \(r.cards.count) queued \(r.queued.count)")
        #expect(graph.created.isEmpty && graph.patches("ser-1").isEmpty,
                "created \(graph.created.count), series patches \(graph.patches("ser-1").count)")
    }
}

// MARK: - The card's reset note is the series' (PROOF P2)

/// PROOF P2: the card's reset note (`editResetsChangedOccurrences`, #423) is asked of the series the
/// edit writes (`CalendarSeriesScope.Named.series`) with the edit as routed. An "all" time edit given
/// an occurrence's id warns on the card AND the write resets, both from the resolved series. Asked
/// of the occurrence the id names (which carries no rule on Google and Outlook) with the edit as
/// given, the card would show no note while the write resets.
@Suite("The card's reset note is asked of the series the edit writes", .serialized, .processGlobalState)
struct CalendarSeriesScopeResetNoteTests {

    @Test("Google: a new time of every occurrence named from a later occurrence warns on the card, and the series is reset")
    func googleLaterOccurrenceTimeWarnsAndResets() async throws {
        let r = try await googleTool([
            "start_iso": .string("\(day(7))T11:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "series-note-g-later")
        #expect(r.run.cards.first?.changes.contains(CalendarToolHelpers.ruleChangeResetNote) == true,
                "card: \(r.run.cards.first?.changes ?? [])")
        #expect(r.calendar.seriesResets == 1, "the write did not reset the series: \(r.calendar.writes)")
    }

    @Test("Google: a plain shift named from the first occurrence's id warns on the card, and the series is reset")
    func googleFirstOccurrenceShiftWarnsAndResets() async throws {
        let r = try await googleTool([
            "start_iso": .string("\(day(1))T09:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.first, account: "series-note-g-first")
        #expect(r.run.cards.first?.changes.contains(CalendarToolHelpers.ruleChangeResetNote) == true,
                "card: \(r.run.cards.first?.changes ?? [])")
        #expect(r.calendar.seriesResets == 1, "the write did not reset the series: \(r.calendar.writes)")
    }

    @Test("Google: a later occurrence's own time given back as every occurrence's moves nothing: no note, no reset")
    func googleSameInstantEchoIsQuiet() async throws {
        let r = try await googleTool([
            "start_iso": .string("\(day(7))T09:00:00"), "end_iso": .string("\(day(7))T09:30:00"),
            "title": .string("Team standup"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "series-note-g-echo")
        #expect(r.run.cards.first?.changes.contains(CalendarToolHelpers.ruleChangeResetNote) == false,
                "card: \(r.run.cards.first?.changes ?? [])")
        #expect(r.calendar.seriesResets == 0, "the series was reset: \(r.calendar.writes)")
        #expect(r.calendar.event(GoogleSeries.id)?["summary"] as? String == "Team standup", "\(r.run.out)")
    }

    @Test("Outlook: a new time of every occurrence named from a later occurrence warns on the card, and the series is reset")
    func outlookLaterOccurrenceTimeWarnsAndResets() async throws {
        let graph = GraphSeries.calendar()
        let r = try await outlookTool(graph, [
            "start_iso": .string(GraphFixture.naive(GraphFixture.occurrenceStart.addingTimeInterval(3_600))),
            "timezone": .string("UTC"),
        ], eventId: GraphSeries.later, account: "series-note-x-later")
        #expect(r.cards.first?.changes.contains(CalendarToolHelpers.ruleChangeResetNote) == true,
                "card: \(r.cards.first?.changes ?? [])")
        #expect(graph.seriesResets == 1, "the write did not reset the series: \(graph.patches("ser-1").count) PATCHes")
    }
}

// MARK: - The routing rule

@Suite("CalendarSeriesScope.route")
struct CalendarSeriesScopeRouteTests {

    private static let timedSeries = gcalEvent(id: "ser", start: timed(day(0)), end: timed(day(0), "09:30:00"),
                                               recurrence: ["RRULE:FREQ=WEEKLY"])
    private static let allDaySeries = gcalEvent(
        id: "ser", start: GCalDateTime(dateTime: nil, date: day(0), timeZone: nil),
        end: GCalDateTime(dateTime: nil, date: day(1), timeZone: nil), recurrence: ["RRULE:FREQ=WEEKLY"])
    /// A timed series whose zone is not known: a CalDAV series kept in UTC names none.
    private static let zonelessSeries = gcalEvent(
        id: "ser", start: GCalDateTime(dateTime: "\(day(0))T09:00:00Z", date: nil, timeZone: nil),
        end: GCalDateTime(dateTime: "\(day(0))T09:30:00Z", date: nil, timeZone: nil), recurrence: ["RRULE:FREQ=WEEKLY"])

    /// The series named by its own id, with the occurrence its `recurrence_id` names when given.
    private static func named(_ series: GCalEvent, at occurrence: GCalEvent? = nil) -> CalendarSeriesScope.Named {
        .init(eventId: "ser", event: series, seriesId: "ser", series: series, occurrence: occurrence)
    }

    /// An occurrence named by its own id.
    private static func named(_ series: GCalEvent, occurrence: GCalEvent) -> CalendarSeriesScope.Named {
        .init(eventId: occurrence.id ?? "", event: occurrence, seriesId: "ser", series: series, occurrence: occurrence)
    }

    /// An occurrence at its place `original`, now at `start` (its place when not given).
    private static func occurrence(_ original: GCalDateTime?, now start: GCalDateTime? = nil) -> GCalEvent {
        gcalEvent(id: "ser_occ", start: start ?? original, end: nil, recurrence: nil, series: "ser", original: original)
    }

    /// Where `route` sent an edit.
    private struct Went: Equatable, CustomStringConvertible {
        let scope: String
        var recurrenceId: String?
        var start: String?
        var end: String?
        var eventId: String = "ser"

        var description: String { "\(scope) of \(eventId) at \(recurrenceId ?? "-") start \(start ?? "-") end \(end ?? "-")" }
    }

    private func route(_ args: [String: JSONValue], _ named: CalendarSeriesScope.Named, scope: String = "all",
                       zone: TimeZone = utc) throws -> Went {
        let routed = try CalendarSeriesScope.route(args, scope: scope, named: named, zone: zone)
        #expect(CalendarToolHelpers.stringArgOpt(routed.args, "edit_scope") ?? scope == routed.scope,
                "the arguments' edit_scope is not the scope written")
        // Routed again, it routes to itself: the queue decides what the card said. The queue reads
        // what the routed edit names: the series' own id with no `recurrence_id` names no occurrence.
        let reread: CalendarSeriesScope.Named
        if routed.eventId == named.eventId, !(routed.recurrenceId == nil && routed.eventId == named.seriesId) {
            reread = named
        } else {
            reread = Self.named(named.series)
        }
        let again = try CalendarSeriesScope.route(routed.args, scope: routed.scope, named: reread, zone: zone)
        #expect(again.scope == routed.scope && again.args == routed.args, "routed again: \(again.scope), not \(routed.scope)")
        return Went(scope: routed.scope, recurrenceId: routed.recurrenceId,
                    start: CalendarToolHelpers.stringArgOpt(routed.args, "start_iso"),
                    end: CalendarToolHelpers.stringArgOpt(routed.args, "end_iso"), eventId: routed.eventId)
    }

    private func refusal(_ args: [String: JSONValue], _ named: CalendarSeriesScope.Named, scope: String = "all",
                         zone: TimeZone = utc) -> String? {
        do {
            _ = try CalendarSeriesScope.route(args, scope: scope, named: named, zone: zone)
            return nil
        } catch CalendarProviderError.notSupported(let reason) {
            return reason
        } catch {
            return "unexpected \(error)"
        }
    }

    @Test("an edit that changes no time, or of an event that does not repeat, goes as given")
    func noTimeOrNoRuleGoesAsGiven() throws {
        #expect(try route(["title": .string("Renamed")], Self.named(Self.timedSeries)) == Went(scope: "all"))
        let oneOff = gcalEvent(id: "ser", start: timed(day(0)), end: nil, recurrence: nil)
        #expect(try route(["start_iso": .string("\(day(5))T09:00:00")], Self.named(oneOff))
                == Went(scope: "all", start: "\(day(5))T09:00:00"))
        #expect(try route(["recurrence_id": .string("\(day(7))T09:00:00"), "start_iso": .string("\(day(8))T09:00:00")],
                          Self.named(Self.timedSeries, at: Self.occurrence(timed(day(7)))), scope: "this_only")
                == Went(scope: "this_only", recurrenceId: "\(day(7))T09:00:00", start: "\(day(8))T09:00:00"))
    }

    @Test("a later occurrence moved to another date than the one it is on now is a change of it and the following ones, named where it is, shown in the edit's zone")
    func laterOccurrenceToAnotherDateIsSplit() throws {
        let moved = ["start_iso": JSONValue.string("\(day(8))T09:00:00")]
        let later = Self.named(Self.timedSeries, occurrence: Self.occurrence(timed(day(7))))
        #expect(try route(moved, later)
                == Went(scope: "this_and_following", recurrenceId: "\(day(7))T09:00:00", start: "\(day(8))T09:00:00", eventId: "ser_occ"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(try route(moved, later, zone: tokyo)
                == Went(scope: "this_and_following", recurrenceId: "\(day(7))T18:00:00", start: "\(day(8))T09:00:00", eventId: "ser_occ"))
    }

    @Test("the first occurrence named by its id is the whole series, a plain move, at the first occurrence")
    func firstOccurrenceIsTheSeries() throws {
        let first = Self.occurrence(timed(day(0)))
        #expect(try route(["start_iso": .string("\(day(8))T09:00:00")], Self.named(Self.timedSeries, occurrence: first))
                == Went(scope: "all", recurrenceId: "\(day(0))T09:00:00", start: "\(day(8))T09:00:00", eventId: "ser_occ"))
    }

    @Test("a later occurrence given a new time of day on the date it is on now is the whole series, the new times moved to the first occurrence's date")
    func laterOccurrenceTimeOfDayIsTheSeries() throws {
        let later = Self.named(Self.timedSeries, occurrence: Self.occurrence(timed(day(7))))
        #expect(try route(["start_iso": .string("\(day(7))T11:00:00"), "end_iso": .string("\(day(7))T12:15:00")], later)
                == Went(scope: "all", start: "\(day(0))T11:00:00", end: "\(day(0))T12:15:00"))
        #expect(try route(["end_iso": .string("\(day(7))T10:00:00")], later)
                == Went(scope: "all", end: "\(day(0))T10:00:00"))
        // Moved on its own to day 9: its date now is the one compared, and the days counted.
        let moved = Self.named(Self.timedSeries, occurrence: Self.occurrence(timed(day(7)), now: timed(day(9), "13:00:00")))
        #expect(try route(["start_iso": .string("\(day(9))T11:00:00")], moved)
                == Went(scope: "all", start: "\(day(0))T11:00:00"))
        // Named by recurrence_id, read in the edit's zone (Tokyo, 9 hours ahead of the series' UTC).
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(try route(["recurrence_id": .string("\(day(7))T18:00:00"), "start_iso": .string("\(day(7))T20:00:00")],
                          Self.named(Self.timedSeries, at: Self.occurrence(timed(day(7)))), zone: tokyo)
                == Went(scope: "all", start: "\(day(0))T20:00:00"))
    }

    @Test("the days back to the first occurrence are calendar days in the series' zone, so a time of day across a change of summer time is kept")
    func movedToFirstCountsCalendarDays() throws {
        // A New York series from a week before its next change of summer time, at 09:00 there, and
        // its occurrence two weeks later, at 09:00 again: the days between are not a multiple of
        // 24 hours. Placed by the next change from today, so the two weeks always cross one.
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let change = try #require(zone.nextDaylightSavingTimeTransition(after: Date()))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let weekBefore = try #require(cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: change)))
        let first = try #require(cal.date(bySettingHour: 9, minute: 0, second: 0, of: weekBefore))
        let laterAt = try #require(cal.date(byAdding: .day, value: 14, to: first))
        #expect(laterAt.timeIntervalSince(first) != 14 * 86_400, "setup: the two weeks cross no change of summer time")
        let series = gcalEvent(id: "ser", start: GCalDateTime(dateTime: first.iso8601String(), date: nil, timeZone: zone.identifier),
                               end: nil, recurrence: ["RRULE:FREQ=WEEKLY"])
        let occurrence = Self.occurrence(GCalDateTime(dateTime: laterAt.iso8601String(), date: nil, timeZone: zone.identifier))
        let firstDay = EKEventStoreHelper.dayKey(first, timeZone: zone)
        let laterDay = EKEventStoreHelper.dayKey(laterAt, timeZone: zone)
        let went = try route(["start_iso": .string("\(laterDay)T10:00:00")], Self.named(series, occurrence: occurrence), zone: zone)
        #expect(went == Went(scope: "all", start: "\(firstDay)T10:00:00"), "\(went)")
    }

    @Test("a start written without seconds is read for the date comparison, as the tools read a start")
    func startWithoutSecondsIsRead() throws {
        let later = Self.named(Self.timedSeries, occurrence: Self.occurrence(timed(day(7))))
        #expect(try route(["start_iso": .string("\(day(7))T11:00")], later)
                == Went(scope: "all", start: "\(day(0))T11:00:00"))
        #expect(try route(["start_iso": .string("\(day(8))T11:00")], later)
                == Went(scope: "this_and_following", recurrenceId: "\(day(7))T09:00:00", start: "\(day(8))T11:00", eventId: "ser_occ"))
    }

    @Test("whether a later occurrence keeps its date is judged in the series' own zone, not the edit's")
    func laterOccurrenceDateIsTheSeriesZones() throws {
        // A series at 23:00 in Tokyo (14:00 UTC). 16:00 UTC is the same date in UTC and the next
        // date in Tokyo, where the series repeats: a move to another date. 10:00 UTC is 19:00 the
        // same day in Tokyo: a new time of day.
        let series = gcalEvent(id: "ser", start: GCalDateTime(dateTime: "\(day(0))T14:00:00Z", date: nil, timeZone: "Asia/Tokyo"),
                               end: nil, recurrence: ["RRULE:FREQ=WEEKLY"])
        let later = Self.named(series, occurrence: Self.occurrence(timed(day(7), "14:00:00")))
        #expect(try route(["start_iso": .string("\(day(7))T16:00:00")], later)
                == Went(scope: "this_and_following", recurrenceId: "\(day(7))T14:00:00", start: "\(day(7))T16:00:00", eventId: "ser_occ"))
        #expect(try route(["start_iso": .string("\(day(7))T10:00:00")], later)
                == Went(scope: "all", start: "\(day(0))T10:00:00"))
    }

    @Test("one series zone: Outlook's recurrence zone wins over the zone its start is shown in")
    func seriesZoneIsTheRecurrenceZone() throws {
        // Shown in UTC, kept in Tokyo by its rule (Outlook's `recurrenceTimeZone`).
        var series = Self.timedSeries
        series.recurrenceTimeZoneName = "Tokyo Standard Time"
        #expect(series.seriesZone?.identifier == "Asia/Tokyo")
        var unknown = Self.timedSeries
        unknown.recurrenceTimeZoneName = "Not a zone"
        #expect(unknown.seriesZone == nil)
        #expect(Self.timedSeries.seriesZone?.identifier == "UTC" || Self.timedSeries.seriesZone?.secondsFromGMT() == 0)
        #expect(Self.zonelessSeries.seriesZone == nil)
    }

    @Test("a series whose zone is not known: a later occurrence's new time is taken to be on another date, and a new time with no occurrence named asks")
    func unknownZoneTakesTheRefusingSide() throws {
        let later = Self.named(Self.zonelessSeries, occurrence: Self.occurrence(timed(day(7))))
        #expect(try route(["start_iso": .string("\(day(7))T11:00:00")], later)
                == Went(scope: "this_and_following", recurrenceId: "\(day(7))T09:00:00", start: "\(day(7))T11:00:00", eventId: "ser_occ"))
        #expect(refusal(["start_iso": .string("\(day(0))T11:00:00")], Self.named(Self.zonelessSeries))?
            .contains(CalendarSeriesScope.askWhichOccurrences) == true)
        let first = Self.named(Self.zonelessSeries, occurrence: Self.occurrence(timed(day(0))))
        #expect(try route(["start_iso": .string("\(day(0))T11:00:00")], first)
                == Went(scope: "all", recurrenceId: "\(day(0))T09:00:00", start: "\(day(0))T11:00:00", eventId: "ser_occ"))
    }

    @Test("an all-day series' occurrences are compared by date")
    func allDayOccurrencesAreDates() throws {
        let later = Self.named(Self.allDaySeries, occurrence: Self.occurrence(GCalDateTime(dateTime: nil, date: day(7), timeZone: nil)))
        #expect(try route(["start_iso": .string("\(day(9))T00:00:00")], later)
                == Went(scope: "this_and_following", recurrenceId: "\(day(7))T00:00:00", start: "\(day(9))T00:00:00", eventId: "ser_occ"))
        #expect(try route(["start_iso": .string("\(day(7))T00:00:00"), "end_iso": .string("\(day(9))T00:00:00")], later)
                == Went(scope: "all", start: "\(day(0))T00:00:00", end: "\(day(2))T00:00:00"))
    }

    @Test("an all-day series' place is a date and needs no zone: a series in a zone TabMail does not recognize routes as any other; a time given as its place can't be compared, and is refused")
    func allDayPlaceNeedsNoZone() throws {
        // Every provider gives an all-day occurrence's place as a date (Outlook's read in the
        // series' own zone, `ExchangeCalendarProvider.allDayOccurrence`).
        let now = GCalDateTime(dateTime: nil, date: day(7), timeZone: nil)
        for name in ["Tokyo Standard Time", "Custom Server Zone"] {
            var series = Self.allDaySeries
            series.recurrenceTimeZoneName = name
            #expect(try route(["start_iso": .string("\(day(9))T00:00:00")], Self.named(series, occurrence: Self.occurrence(now)))
                    == Went(scope: "this_and_following", recurrenceId: "\(day(7))T00:00:00", start: "\(day(9))T00:00:00", eventId: "ser_occ"),
                    "\(name)")
        }
        let instant = GCalDateTime(dateTime: "\(day(6))T15:00:00Z", date: nil, timeZone: "UTC")
        #expect(refusal(["start_iso": .string("\(day(9))T00:00:00")],
                        Self.named(Self.allDaySeries, occurrence: Self.occurrence(instant, now: now)))?
            .contains("can't be compared") == true)
    }

    @Test("a recurrence_id given as a date names the occurrence on that date")
    func recurrenceIdAsADate() throws {
        let first = Self.named(Self.timedSeries, at: Self.occurrence(timed(day(0))))
        #expect(try route(["recurrence_id": .string(day(0)), "start_iso": .string("\(day(1))T09:00:00")], first)
                == Went(scope: "all", recurrenceId: day(0), start: "\(day(1))T09:00:00"))
        let later = Self.named(Self.timedSeries, at: Self.occurrence(timed(day(14))))
        #expect(try route(["recurrence_id": .string(day(14)), "start_iso": .string("\(day(15))T09:00:00")], later)
                == Went(scope: "this_and_following", recurrenceId: day(14), start: "\(day(15))T09:00:00"))
    }

    @Test("with no occurrence named, an end on the series' own end date moves the series and another date asks")
    func endOnlyComparesTheEnd() throws {
        #expect(try route(["end_iso": .string("\(day(0))T10:00:00")], Self.named(Self.timedSeries))
                == Went(scope: "all", end: "\(day(0))T10:00:00"))
        #expect(refusal(["end_iso": .string("\(day(1))T10:00:00")], Self.named(Self.timedSeries))?
            .contains(CalendarSeriesScope.askWhichOccurrences) == true)
        #expect(try route(["end_iso": .string("\(day(1))T00:00:00")], Self.named(Self.allDaySeries))
                == Went(scope: "all", end: "\(day(1))T00:00:00"))
        #expect(refusal(["end_iso": .string("\(day(3))T00:00:00")], Self.named(Self.allDaySeries))?
            .contains(CalendarSeriesScope.askWhichOccurrences) == true)
    }

    @Test("an occurrence whose place is not given, and a series whose start can't be read, are refused")
    func unplaceableIsRefused() {
        let moved = ["start_iso": JSONValue.string("\(day(8))T09:00:00")]
        #expect(refusal(moved, Self.named(Self.timedSeries, occurrence: Self.occurrence(nil, now: timed(day(7)))))?
            .contains("the place in its series of the occurrence named can't be read") == true)
        let unreadable = gcalEvent(id: "ser", start: nil, end: nil, recurrence: ["RRULE:FREQ=WEEKLY"])
        #expect(refusal(moved, Self.named(unreadable))?.contains("can't be read") == true)
    }

    @Test("an occurrence placed before the series' first is refused, naming none")
    func beforeTheFirstIsRefused() {
        let early = Self.occurrence(timed(day(-7)))
        #expect(refusal(["start_iso": .string("\(day(1))T09:00:00")], Self.named(Self.timedSeries, occurrence: early))?
            .contains("names none of its occurrences") == true)
    }

    @Test("a change of an occurrence and the following ones at the first occurrence is the whole series; at a later one it goes as given")
    func followingAtTheFirstIsTheSeries() throws {
        let args: (String) -> [String: JSONValue] = { rid in
            ["edit_scope": .string("this_and_following"), "recurrence_id": .string(rid), "start_iso": .string("\(day(1))T10:00:00")]
        }
        #expect(try route(args("\(day(0))T09:00:00"), Self.named(Self.timedSeries, at: Self.occurrence(timed(day(0)))),
                          scope: "this_and_following")
                == Went(scope: "all", recurrenceId: "\(day(0))T09:00:00", start: "\(day(1))T10:00:00"))
        #expect(try route(args("\(day(7))T09:00:00"), Self.named(Self.timedSeries, at: Self.occurrence(timed(day(7)))),
                          scope: "this_and_following")
                == Went(scope: "this_and_following", recurrenceId: "\(day(7))T09:00:00", start: "\(day(1))T10:00:00"))
        #expect(try route(args("\(day(0))T00:00:00"),
                          Self.named(Self.allDaySeries, at: Self.occurrence(GCalDateTime(dateTime: nil, date: day(0), timeZone: nil))),
                          scope: "this_and_following")
                == Went(scope: "all", recurrenceId: "\(day(0))T00:00:00", start: "\(day(1))T10:00:00"))
    }
}

// MARK: - A move to another date of a series on named days

@Suite("CalendarSeriesScope.dayMoveRefusal")
struct CalendarSeriesScopeDayMoveRefusalTests {

    private static let byDay = "RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(0)))"

    private static func series(_ recurrence: [String]?) -> GCalEvent {
        gcalEvent(id: "ser", start: timed(day(0)), end: timed(day(0), "09:30:00"), recurrence: recurrence)
    }

    private static func named(_ series: GCalEvent, occurrence: GCalEvent? = nil) -> CalendarSeriesScope.Named {
        .init(eventId: "ser", event: series, seriesId: "ser", series: series, occurrence: occurrence)
    }

    private func refusal(_ args: [String: JSONValue], rule: String = CalendarSeriesScopeDayMoveRefusalTests.byDay, scope: String = "all",
                         zone: TimeZone = utc, occurrence: GCalEvent? = nil) -> String? {
        CalendarSeriesScope.dayMoveRefusal(args, named: Self.named(Self.series([rule]), occurrence: occurrence), scope: scope, zone: zone)
    }

    private static let toAnotherDate: [String: JSONValue] = ["start_iso": .string("\(day(1))T09:00:00")]

    @Test("each rule part that names days or dates refuses a move to another date, and the refusal names it")
    func everyNamedPartRefuses() {
        for (rule, part) in [
            ("RRULE:FREQ=WEEKLY;BYDAY=MO,WE", "BYDAY=MO,WE"),
            ("RRULE:FREQ=MONTHLY;BYMONTHDAY=15", "BYMONTHDAY=15"),
            ("RRULE:FREQ=YEARLY;BYYEARDAY=100", "BYYEARDAY=100"),
            ("RRULE:FREQ=YEARLY;BYWEEKNO=20", "BYWEEKNO=20"),
            ("RRULE:FREQ=YEARLY;BYMONTH=3", "BYMONTH=3"),
            ("RRULE:FREQ=MONTHLY;BYSETPOS=1", "BYSETPOS=1"),
            ("rrule:freq=weekly;byday=mo", "byday=mo"),
        ] {
            let reason = refusal(Self.toAnotherDate, rule: rule)
            #expect(reason?.contains(namedDaysRefusal) == true && reason?.contains(part) == true, "\(rule): \(reason ?? "passed")")
            #expect(reason?.contains("from \(day(0)) to \(day(1))") == true, "\(rule): \(reason ?? "passed")")
        }
    }

    @Test("a rule that names no days passes: its days follow the start")
    func ruleWithoutNamedDaysPasses() {
        for rule in ["RRULE:FREQ=DAILY", "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=5", "RRULE:FREQ=MONTHLY;UNTIL=20991231T000000Z",
                     "RRULE:FREQ=YEARLY;WKST=SU"] {
            #expect(refusal(Self.toAnotherDate, rule: rule) == nil, "\(rule)")
        }
        let exdate = Self.series(["RRULE:FREQ=WEEKLY", "EXDATE:\(compact(day(7)))T090000Z"])
        #expect(CalendarSeriesScope.dayMoveRefusal(Self.toAnotherDate, named: Self.named(exdate), scope: "all", zone: utc) == nil)
        #expect(CalendarSeriesScope.dayMoveRefusal(Self.toAnotherDate, named: Self.named(Self.series(nil)), scope: "all", zone: utc) == nil)
    }

    @Test("another time on the same date, an end alone, one occurrence, and an edit that moves nothing pass")
    func sameDateEndOnlyAndOneOccurrencePass() {
        #expect(refusal(["start_iso": .string("\(day(0))T15:00:00")]) == nil)
        #expect(refusal(["end_iso": .string("\(day(3))T10:00:00")]) == nil)
        #expect(refusal(["recurrence_id": .string("\(day(7))T09:00:00"), "start_iso": .string("\(day(8))T09:00:00")],
                        scope: "this_only") == nil)
        #expect(refusal(["title": .string("Renamed")]) == nil)
    }

    @Test("a new rule given with the move passes; a recurrence the builder writes no rule from is no new rule")
    func givenRulePasses() {
        var withRule = Self.toAnotherDate
        withRule["recurrence"] = .dictionary(["freq": .string("WEEKLY")])
        #expect(refusal(withRule) == nil)
        withRule["recurrence"] = .dictionary(["freq": .string("FORTNIGHTLY")])
        #expect(refusal(withRule)?.contains(namedDaysRefusal) == true)
        withRule["recurrence"] = .string("weekly")
        #expect(refusal(withRule)?.contains(namedDaysRefusal) == true)
    }

    @Test("an occurrence and the following ones are compared with the start the occurrence has now, not the series' first, nor its place")
    func followingComparesWithItsOccurrenceNow() {
        let rid = JSONValue.string("\(day(7))T09:00:00")
        let unmoved = gcalEvent(id: "ser_occ", start: timed(day(7)), end: nil, recurrence: nil, series: "ser", original: timed(day(7)))
        #expect(refusal(["recurrence_id": rid, "start_iso": .string("\(day(7))T11:00:00")], scope: "this_and_following",
                        occurrence: unmoved) == nil)
        #expect(refusal(["recurrence_id": rid, "start_iso": .string("\(day(8))T09:00:00")], scope: "this_and_following",
                        occurrence: unmoved)?.contains("from \(day(7)) to \(day(8))") == true)
        // Moved on its own to day 9 (its place still day 7): a new time on day 9 keeps its date.
        let moved = gcalEvent(id: "ser_occ", start: timed(day(9)), end: nil, recurrence: nil, series: "ser", original: timed(day(7)))
        #expect(refusal(["recurrence_id": .string("\(day(9))T09:00:00"), "start_iso": .string("\(day(9))T11:00:00")],
                        scope: "this_and_following", occurrence: moved) == nil)
        #expect(refusal(["recurrence_id": .string("\(day(0))T09:00:00"), "start_iso": .string("\(day(1))T09:00:00")])?
            .contains(namedDaysRefusal) == true)
    }

    @Test("an all-day series is compared by date")
    func allDayByDate() {
        let allDay = gcalEvent(id: "ser", start: GCalDateTime(dateTime: nil, date: day(0), timeZone: nil),
                               end: GCalDateTime(dateTime: nil, date: day(1), timeZone: nil), recurrence: [Self.byDay])
        let occurrence = gcalEvent(id: "ser_occ", start: GCalDateTime(dateTime: nil, date: day(7), timeZone: nil), end: nil,
                                   recurrence: nil, series: "ser", original: GCalDateTime(dateTime: nil, date: day(7), timeZone: nil))
        func allDayRefusal(_ args: [String: JSONValue], scope: String = "all") -> String? {
            CalendarSeriesScope.dayMoveRefusal(args, named: Self.named(allDay, occurrence: occurrence), scope: scope, zone: utc)
        }
        #expect(allDayRefusal(["start_iso": .string("\(day(0))T00:00:00")]) == nil)
        #expect(allDayRefusal(["start_iso": .string("\(day(2))T00:00:00")])?.contains(namedDaysRefusal) == true)
        #expect(allDayRefusal(["recurrence_id": .string(day(7)), "start_iso": .string("\(day(7))T00:00:00")],
                              scope: "this_and_following") == nil)
    }

    @Test("the dates are the series' own, in its zone, not the edit's")
    func datesAreReadInTheSeriesZone() throws {
        // A series at 23:00 in Tokyo (14:00 UTC) on its weekday. 16:00 UTC is the same date in UTC,
        // the edit's zone, and the next date in Tokyo, where the series repeats: a move to another
        // date. 10:00 UTC is 19:00 the same day in Tokyo.
        let series = gcalEvent(id: "ser", start: GCalDateTime(dateTime: "\(day(0))T14:00:00Z", date: nil, timeZone: "Asia/Tokyo"),
                               end: nil, recurrence: [Self.byDay])
        func tokyoRefusal(_ start: String, zone: TimeZone = utc) -> String? {
            CalendarSeriesScope.dayMoveRefusal(["start_iso": .string(start)], named: Self.named(series), scope: "all", zone: zone)
        }
        #expect(tokyoRefusal("\(day(0))T16:00:00")?.contains("from \(day(0)) to \(day(1))") == true,
                "\(tokyoRefusal("\(day(0))T16:00:00") ?? "passed")")
        #expect(tokyoRefusal("\(day(0))T10:00:00") == nil)
        // The edit's zone reads the naive start; the date is still Tokyo's.
        let honolulu = try #require(TimeZone(identifier: "Pacific/Honolulu"))
        #expect(tokyoRefusal("\(day(0))T06:00:00", zone: honolulu)?.contains(namedDaysRefusal) == true,
                "06:00 in Honolulu is 01:00 the next day in Tokyo")
        #expect(tokyoRefusal("\(day(-1))T20:00:00", zone: honolulu) == nil, "20:00 the day before in Honolulu is 15:00 in Tokyo")
    }

    @Test("a series whose own zone is not known is refused a new start, even on its date")
    func unknownZoneIsRefused() {
        // A CalDAV series kept in UTC names no zone (#679); an Outlook series whose recurrence zone
        // TabMail does not recognize has none it can read either.
        let zoneless = gcalEvent(id: "ser", start: GCalDateTime(dateTime: "\(day(0))T09:00:00Z", date: nil, timeZone: nil),
                                 end: nil, recurrence: [Self.byDay])
        var outlook = Self.series([Self.byDay])
        outlook.recurrenceTimeZoneName = "Not a zone"
        for series in [zoneless, outlook] {
            let reason = CalendarSeriesScope.dayMoveRefusal(["start_iso": .string("\(day(0))T15:00:00")], named: Self.named(series),
                                                            scope: "all", zone: utc)
            #expect(reason?.contains("its own time zone is not known") == true, "\(reason ?? "passed")")
        }
        outlook.recurrenceTimeZoneName = "UTC"
        #expect(CalendarSeriesScope.dayMoveRefusal(["start_iso": .string("\(day(0))T15:00:00")], named: Self.named(outlook),
                                                   scope: "all", zone: utc) == nil, "a series naming its zone (control)")
    }
}

// MARK: - Outlook's occurrence place

@Suite("Outlook gives an occurrence its place in the series")
struct ExchangeOriginalStartTests {

    private func mapped(_ json: [String: Any]) async throws -> GCalEvent {
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" })
        let event = try JSONDecoder().decode(MSEvent.self, from: JSONSerialization.data(withJSONObject: json))
        return await provider.toGCalEvent(event)
    }

    @Test("a timed occurrence's originalStart, written with the event's offset as Graph writes it, is its instant")
    func timedOriginalStartIsTheInstant() async throws {
        let instant = GraphFixture.occurrenceStart
        let offsets = ["America/Los_Angeles", "Asia/Tokyo", "UTC"].compactMap(TimeZone.init(identifier:))
        #expect(offsets.count == 3)
        for written in offsets.map({ instant.iso8601String(timeZone: $0) }) {
            var json = GraphFixture.event(id: "occ", start: instant, seriesMasterId: "ser-1")
            json["originalStart"] = written
            let event = try await mapped(json)
            #expect(event.originalStartTime?.dateTime.flatMap(Date.fromISO8601) == instant, "\(written) → \(String(describing: event.originalStartTime))")
        }
    }

    @Test("an all-day occurrence's place is the instant Graph gives, whatever date its text names")
    func allDayOriginalStartIsTheInstant() async throws {
        // Measured: the UTC instant the date begins in the series' zone. Tokyo's December 1 is
        // written on November 30; `CalendarSeriesScope` dates it from the series' zone.
        let date = GraphFixture.utcDay(GraphFixture.occurrenceStart)
        for zone in ["Asia/Tokyo", "America/Los_Angeles", "UTC"] {
            let tz = try #require(TimeZone(identifier: zone))
            let begins = try #require(EKEventStoreHelper.parseNaiveISO(date, timeZone: tz))
            var json = GraphFixture.event(id: "occ", start: GraphFixture.occurrenceStart, seriesMasterId: "ser-1", allDay: true)
            json["originalStart"] = begins.iso8601String(timeZone: .gmt)
            let event = try await mapped(json)
            #expect(event.originalStartTime?.date == nil && event.originalStartTime?.dateTime.flatMap(Date.fromISO8601) == begins,
                    "\(zone) → \(String(describing: event.originalStartTime))")
        }
    }

    @Test("a series' own zone is its recurrence zone")
    func seriesZoneIsTheRecurrenceZone() async throws {
        var series = GraphFixture.event(id: "ser-1", recurring: true)
        if var recurrence = series["recurrence"] as? [String: Any], var range = recurrence["range"] as? [String: Any] {
            range["recurrenceTimeZone"] = "Tokyo Standard Time"
            recurrence["range"] = range
            series["recurrence"] = recurrence
        }
        #expect(try await mapped(series).seriesZone?.identifier == "Asia/Tokyo")
    }

    @Test("a read through Graph selects an occurrence's place")
    func readSelectsThePlace() async throws {
        // The fake returns only what `$select` names, as Graph does.
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        GraphSeries.calendar().install(on: http)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                session: http.session)
        let occurrence = try await provider.getEvent(calendarId: "primary", eventId: GraphSeries.later)
        #expect(occurrence.originalStartTime?.dateTime.flatMap(Date.fromISO8601) == GraphFixture.occurrenceStart,
                "\(String(describing: occurrence.originalStartTime))")
        #expect(occurrence.recurringEventId == "ser-1")
        let selects = http.recordedCalls().map { call in
            Set((URLComponents(string: call.url)?.queryItems?.first { $0.name == "$select" }?.value ?? "")
                .split(separator: ",").map(String.init))
        }
        #expect(selects.count == 1 && selects.allSatisfy { $0.contains("originalStart") }, "\(selects)")
    }

    @Test("an originalStart that is no ISO 8601 date-time gives no place")
    func unreadableOriginalStartIsNil() async throws {
        for written in ["", "tomorrow", GraphFixture.naive(GraphFixture.occurrenceStart)] {
            var json = GraphFixture.event(id: "occ", start: GraphFixture.occurrenceStart, seriesMasterId: "ser-1")
            json["originalStart"] = written
            #expect(try await mapped(json).originalStartTime == nil, "\(written)")
        }
    }

    @Test("a series and a one-off event have no place")
    func noOriginalStartIsNil() async throws {
        #expect(try await mapped(GraphFixture.event(id: "ser-1", recurring: true)).originalStartTime == nil)
        #expect(try await mapped(GraphFixture.event(id: "ev")).originalStartTime == nil)
    }
}

// MARK: - CalDAV: an occurrence's place, and a stored zone TabMail does not recognize

@Suite("CalDAV gives an occurrence its place in the series, and refuses an unrecognized stored zone before the card", .serialized, .processGlobalState)
struct CalDAVSeriesScopeTests {
    typealias W = OccurrenceWireFixture
    typealias H = CalDAVToolWire

    /// Every row a listing shows from the series' first occurrence through week `weeks`.
    private static func listing(_ fixture: W, http: FakeHTTP.Scenario, through weeks: Int = 6) async throws -> [GCalEvent] {
        try await W.makeProvider(http).listEvents(
            calendarId: W.calendarId, timeMin: fixture.first.addingTimeInterval(-60),
            timeMax: try fixture.occurrence(weeks).addingTimeInterval(-60),
            query: nil, singleEvents: true, maxResults: 250, orderBy: "startTime")
    }

    @Test("a listed occurrence carries its place in the series: an unmoved one where it is, a moved one where the series puts it")
    func listedOccurrencesCarryTheirPlace() async throws {
        let fixture = try W.makeMoved(week: 2, toWeek: 4)
        let (_, http) = W.serve(fixture)
        defer { http.close() }
        let rows = try await Self.listing(fixture, http: http)
        let movedStart = try fixture.movedStart(toWeek: 4)
        let moved = rows.first { $0.startDate == movedStart }
        #expect(moved?.originalStartTime?.dateTime.flatMap(Date.fromISO8601) == (try fixture.occurrence(2)),
                "the moved occurrence's place: \(String(describing: moved?.originalStartTime))")
        let unmoved = rows.first { $0.startDate == (try? fixture.occurrence(3)) }
        #expect(unmoved?.originalStartTime?.dateTime.flatMap(Date.fromISO8601) == (try fixture.occurrence(3)),
                "an unmoved occurrence's place: \(String(describing: unmoved?.originalStartTime))")
        // Read by its id, as the edit tool reads it, the same.
        let read = try await W.makeProvider(http).getEvent(calendarId: W.calendarId, eventId: try fixture.occurrenceId(2))
        #expect(read.originalStartTime?.dateTime.flatMap(Date.fromISO8601) == (try fixture.occurrence(2)),
                "read by id: \(String(describing: read.originalStartTime))")
    }

    /// The series as `W.make()` keeps it, with its zone named by a TZID TabMail does not recognize.
    private static func unrecognizedZone() throws -> W {
        let base = try W.make()
        let ics = base.ics.replacingOccurrences(of: "TZID=America/New_York", with: "TZID=Not/AZone")
        return W(zone: base.zone, first: base.first, ics: ics)
    }

    enum Form: String, CaseIterable, CustomTestStringConvertible {
        case occurrenceId, occurrenceIdAndStart, seriesIdAndStart
        var testDescription: String { rawValue }
    }

    struct ZoneCase: CustomTestStringConvertible, Sendable {
        let form: Form
        let scope: String
        let moves: Bool
        var testDescription: String { "\(form.rawValue), \(scope), \(moves ? "a new time" : "a rename")" }
    }

    static let zoneCases: [ZoneCase] = Form.allCases.flatMap { form in
        ["all", "this_and_following", "this_only"].flatMap { scope in
            [false, true].compactMap { moves in
                // The occurrence's own id with no recurrence_id names no occurrence for one scope.
                form == .occurrenceId && scope != "all" ? nil : ZoneCase(form: form, scope: scope, moves: moves)
            }
        }
    }

    @Test("an edit naming an occurrence of a series whose stored zone TabMail does not recognize is refused before the card, by that check's own words",
          arguments: zoneCases)
    func unrecognizedStoredZoneIsRefusedBeforeTheCard(_ entry: ZoneCase) async throws {
        let session = "caldav-zone-\(entry.form.rawValue)-\(entry.scope)-\(entry.moves)"
        let harness = try await H.makeHarness(accountId: session, fixture: try Self.unrecognizedZone())
        defer { H.tearDown(harness) }
        let fixture = harness.fixture

        // The control (#649): a listing still shows the series, and gives the pair the edit names.
        let rows = try await Self.listing(fixture, http: harness.http, through: 3)
        let listed = try #require(rows.first { $0.recurringEventId == W.seriesPath && $0.startDate != nil && $0.startDate != fixture.first },
                                  "the listing showed no later occurrence: \(rows.map { $0.id ?? "nil" })")
        let shown = try #require(listed.startDate)
        let eventId = entry.form == .seriesIdAndStart ? W.seriesPath : try #require(listed.id)

        let translator = ChatIdTranslator.createIsolated()
        let compound = CompoundEventId.make(accountId: harness.accountId, eventId: eventId)
        let forModel = await translator.processToolOutputForLLM("event_id: \(compound)")
        let numericId = try #require(H.eventIds(in: forModel).first.flatMap { Int($0) })
        await H.recordCalendar(of: eventId, accountId: harness.accountId, translator: translator)
        var arguments: [String: JSONValue] = [
            "event_id": .string(String(numericId)), "edit_scope": .string(entry.scope),
            "timezone": .string(fixture.zone.identifier),
        ]
        if entry.form != .occurrenceId {
            arguments["recurrence_id"] = .string(OccurrenceFixture.naive(shown, fixture.zone))
        }
        if entry.moves {
            arguments["start_iso"] = .string(OccurrenceFixture.naive(shown.addingTimeInterval(3_600), fixture.zone))
        } else {
            arguments["title"] = .string("Retitled")
        }
        let before = harness.http.recordedCalls().count
        let sink = H.ConfirmingSink(http: harness.http)
        let output = try await CalendarEventEditTool(context: ToolContext(db: harness.pool, translator: translator)).execute(
            arguments: arguments, invocation: ToolInvocation(uiSink: sink, sessionKey: session))
        let cards = await MainActor.run { sink.confirmations.count }
        #expect(cards == 0, "a card was shown: \(output)")
        // The output is JSON, which may write the zone's slash escaped (`Not\/AZone`): read the error.
        let error = (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])?["error"] as? String ?? ""
        #expect(error.contains("NOT changed") && error.contains("Not/AZone") && error.contains("which TabMail does not recognize"),
                "not refused by the stored zone's check: \(output)")
        let sent = harness.http.recordedCalls().dropFirst(before).map(\.method)
        #expect(sent.allSatisfy { $0 == "GET" || $0 == "REPORT" || $0 == "PROPFIND" }, "written: \(sent)")
        #expect(harness.store.recordedPuts().isEmpty, "PUT: \(harness.store.recordedPuts().map(\.path))")
        let ops = try await harness.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
        #expect(ops.isEmpty, "queued: \(ops.count)")
    }
}

// MARK: - The property: refused before the card, or the calendar holds what the card said

/// Where an occurrence is in the invariant suites' series.
enum OccurrenceState: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// A later occurrence where the series puts it.
    case unmoved
    /// A later occurrence moved on its own more than a day (25 hours) later.
    case movedFar
    /// A later occurrence moved on its own onto another occurrence's time (Google only: Graph refuses it).
    case movedOntoAnother
    /// The series' first occurrence, moved on its own a day later.
    case firstMoved
    /// A deleted occurrence, named by the id and start it had.
    case deleted
    var testDescription: String { rawValue }
}

/// How an edit names the occurrence.
enum NamingForm: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// Its own id, no recurrence_id.
    case ownId
    /// Its own id and the start the listing shows for it.
    case ownIdAndStart
    /// The series' id and that start.
    case seriesIdAndStart
    var testDescription: String { rawValue }
}

/// What the edit changes, and the series' rule.
enum ChangeKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// A rename.
    case rename
    /// A new time of day, two hours later on the date it is on now.
    case timeOfDay
    /// A day later, the series repeating on a named day.
    case dateNamedDays
    /// A day later, the series' rule naming no days.
    case datePlain
    /// A day later with a new rule, the series repeating on a named day.
    case dateWithRule
    var testDescription: String { rawValue }
    var namesDays: Bool { self != .datePlain }
}

/// How much of the series an edit changes, as its card says; `refused` before any card; `error` a
/// split at a later occurrence moved from its place, not supported (#563, #687): the split's card,
/// then an error at the write, with nothing written and the row left failed.
enum Extent: String, Sendable {
    case refused, error, whole, one, fromHereOn

    init(changes: [String]) {
        if changes.contains(where: { $0.hasPrefix("scope → just this occurrence") }) {
            self = .one
        } else if changes.contains(where: { $0.hasPrefix("scope → this and all future occurrences") }) {
            self = .fromHereOn
        } else {
            self = .whole
        }
    }
}

struct InvariantCase: CustomTestStringConvertible, Sendable {
    let state: OccurrenceState
    let form: NamingForm
    let scope: String
    let kind: ChangeKind
    var testDescription: String { "\(state.rawValue), \(form.rawValue), \(scope), \(kind.rawValue)" }

    /// The oracle: what Google Calendar does with the edit, or that it is refused before the card.
    var expected: Extent {
        if state == .deleted { return .refused }
        // The tool requires recurrence_id for one occurrence, or it and the following ones.
        if form == .ownId, scope != "all" { return .refused }
        // Two occurrences start at that time: the series' id with it names neither.
        if form == .seriesIdAndStart, state == .movedOntoAnother { return .refused }
        switch scope {
        case "this_only":
            return .one
        case "this_and_following":
            // A series on named days to another date with no new rule, refused before the card.
            if kind == .dateNamedDays { return .refused }
            switch state {
            case .unmoved: return .fromHereOn
            // From the first occurrence on is every occurrence: an edit of the whole series.
            case .firstMoved: return .whole
            // A split at a later occurrence moved from its place (#563): its card, then an error
            // at the write, with nothing written.
            case .movedFar, .movedOntoAnother: return .error
            case .deleted: return .refused
            }
        default:
            switch kind {
            case .rename, .timeOfDay: return .whole
            case .dateNamedDays: return .refused
            case .datePlain, .dateWithRule:
                switch state {
                case .unmoved: return .fromHereOn
                case .firstMoved: return .whole
                // A new date from a later occurrence is a split there; it was moved (#563): its card,
                // then an error at the write.
                case .movedFar, .movedOntoAnother: return .error
                case .deleted: return .refused
                }
            }
        }
    }

    static func all(states: [OccurrenceState]) -> [InvariantCase] {
        states.flatMap { state in
            NamingForm.allCases.flatMap { form in
                ["all", "this_and_following", "this_only"].flatMap { scope in
                    ChangeKind.allCases.compactMap { kind in
                        // A new rule is no edit of one occurrence.
                        scope == "this_only" && kind == .dateWithRule ? nil : InvariantCase(state: state, form: form, scope: scope, kind: kind)
                    }
                }
            }
        }
    }
}

/// The arguments an edit of `kind` gives for an occurrence that starts at `now`, written in UTC.
private func invariantArguments(_ entry: InvariantCase, now: Date) -> [String: JSONValue] {
    var arguments: [String: JSONValue] = ["edit_scope": .string(entry.scope), "timezone": .string("UTC")]
    if entry.form != .ownId { arguments["recurrence_id"] = .string(GraphFixture.naive(now)) }
    switch entry.kind {
    case .rename:
        arguments["title"] = .string("Renamed")
    case .timeOfDay:
        arguments["start_iso"] = .string(GraphFixture.naive(now.addingTimeInterval(2 * 3_600)))
    case .dateNamedDays, .datePlain:
        arguments["start_iso"] = .string(GraphFixture.naive(now.addingTimeInterval(86_400)))
    case .dateWithRule:
        arguments["start_iso"] = .string(GraphFixture.naive(now.addingTimeInterval(86_400)))
        arguments["recurrence"] = .dictionary(["freq": .string("DAILY"), "interval": .int(7)])
    }
    return arguments
}

/// The property on one run: refused before the card exactly when the oracle says so, and otherwise
/// a card whose extent is the oracle's, the edit written, and no refusal after confirmation.
private func checkProperty(_ entry: InvariantCase, run: ToolRun, wrote: Bool) -> Extent? {
    let label = entry.testDescription
    if entry.expected == .error {
        #expect(run.cards.count == 1 && run.cards.first.map { Extent(changes: $0.changes) } == .fromHereOn,
                "\(label): the split's card was not shown: \(run.cards.map(\.changes)): \(run.out)")
        #expect(!wrote && run.queued.count == 1 && run.queued.allSatisfy { $0.status == PendingStatus.failed.rawValue },
                "\(label): a split at a moved occurrence wrote \(wrote), or did not end failed: \(reasons(run.queued)): \(run.out)")
        return nil
    }
    if entry.expected == .refused {
        #expect(run.cards.isEmpty && run.queued.isEmpty && !wrote,
                "\(label): not refused before the card: cards \(run.cards.count) queued \(run.queued.count) wrote \(wrote): \(run.out)")
        return nil
    }
    #expect(run.cards.count == 1, "\(label): refused, or more than one card: \(run.out)")
    guard run.cards.count == 1 else { return nil }
    let extent = Extent(changes: run.cards[0].changes)
    #expect(extent == entry.expected, "\(label): the card says \(extent.rawValue), Google Calendar does \(entry.expected.rawValue): \(run.cards[0].changes)")
    #expect(!run.out.contains("\"ok\":false") && !run.out.contains("\"ok\" : false") && run.queued.isEmpty,
            "\(label): refused after the user confirmed: \(run.out); queued \(reasons(run.queued))")
    return extent
}

@Suite("calendar_event_edit on Google: refused before the card, or the calendar holds what the card said", .serialized, .processGlobalState)
struct GoogleSeriesScopeInvariantTests {

    /// The weekly series (from day 0, at 09:00 UTC), its occurrences on days 0 to 28, the one
    /// `state` names changed, and the start it is listed at now and its id.
    private static func seed(_ state: OccurrenceState, rule: String) -> (seed: [[String: Any]], id: String, now: String) {
        var events: [[String: Any]] = [GoogleSeries.series(rule: rule)] + [0, 7, 14, 21, 28].map { GoogleSeries.instance(day($0)) }
        func replace(_ d: Int, with event: [String: Any]) {
            events.removeAll { $0["id"] as? String == GoogleSeries.instanceId(day(d)) }
            events.append(event)
        }
        switch state {
        case .unmoved:
            return (events, GoogleSeries.instanceId(day(7)), "\(day(7))T09:00:00")
        case .movedFar:
            replace(14, with: GoogleSeries.moved(day(14), start: "\(day(16))T09:00:00", end: "\(day(16))T09:30:00"))
            return (events, GoogleSeries.instanceId(day(14)), "\(day(16))T09:00:00")
        case .movedOntoAnother:
            replace(21, with: GoogleSeries.moved(day(21), start: "\(day(14))T09:00:00", end: "\(day(14))T09:30:00"))
            return (events, GoogleSeries.instanceId(day(21)), "\(day(14))T09:00:00")
        case .firstMoved:
            replace(0, with: GoogleSeries.moved(day(0), start: "\(day(1))T09:00:00", end: "\(day(1))T09:30:00"))
            return (events, GoogleSeries.instanceId(day(0)), "\(day(1))T09:00:00")
        case .deleted:
            replace(28, with: GoogleSeries.deleted(day(28)))
            return (events, GoogleSeries.instanceId(day(28)), "\(day(28))T09:00:00")
        }
    }

    @Test("every naming form, scope and change of an occurrence in every state",
          arguments: InvariantCase.all(states: OccurrenceState.allCases))
    func refusedBeforeTheCardOrWrittenAsTheCardSaid(_ entry: InvariantCase) async throws {
        let (seed, occurrenceId, nowText) = Self.seed(entry.state, rule: entry.kind.namesDays ? GoogleSeries.onItsWeekday : GoogleSeries.weekly)
        let now = try #require(utcAt(nowText))
        let eventId = entry.form == .seriesIdAndStart ? GoogleSeries.id : occurrenceId
        let r = try await googleTool(invariantArguments(entry, now: now), eventId: eventId,
                                     account: "inv-g-\(entry.testDescription)", seed: seed)
        guard let extent = checkProperty(entry, run: r.run, wrote: !r.calendar.writes.isEmpty) else { return }
        let label = entry.testDescription
        let card = r.run.cards[0]
        let series = r.calendar.event(GoogleSeries.id)
        switch extent {
        case .whole:
            #expect(r.calendar.writes == ["PATCH \(GoogleSeries.id)"], "\(label): writes \(r.calendar.writes)")
            if entry.kind == .rename {
                #expect(series?["summary"] as? String == "Renamed", "\(label): the series kept its title")
            } else {
                #expect(instant(series?["start"]) == card.startDate.addingTimeInterval(0) || card.changes.contains { $0.hasPrefix("start → ") },
                        "\(label): the card shows no new start")
                let written = card.changes.first { $0.hasPrefix("start → ") }.map { String($0.dropFirst("start → ".count)) }
                #expect(instant(series?["start"]) == written.flatMap(utcAt), "\(label): the series starts \(series?["start"] ?? "none"), the card said \(written ?? "none")")
            }
        case .one:
            #expect(r.calendar.writes == ["PATCH \(occurrenceId)"], "\(label): writes \(r.calendar.writes)")
            #expect(card.startDate == now, "\(label): the card shows \(card.startDate), the occurrence is at \(now)")
            let occurrence = r.calendar.event(occurrenceId)
            if entry.kind == .rename {
                #expect(occurrence?["summary"] as? String == "Renamed", "\(label): the occurrence kept its title")
            } else {
                let start = invariantArguments(entry, now: now)["start_iso"].flatMap { if case .string(let s) = $0 { s } else { nil } }
                #expect(instant(occurrence?["start"]) == start.flatMap(utcAt), "\(label): the occurrence starts \(occurrence?["start"] ?? "none")")
            }
            #expect(instant(series?["start"]) == utcAt("\(day(0))T09:00:00") && series?["summary"] as? String == "Standup",
                    "\(label): the series changed")
        case .fromHereOn:
            let successor = r.calendar.event(GoogleCalendarProvider.deterministicSplitEventId(masterId: GoogleSeries.id, recurrenceId: nowText))
            #expect(successor != nil, "\(label): no following part; writes \(r.calendar.writes)")
            #expect(card.startDate == now, "\(label): the card shows \(card.startDate), the occurrence is at \(now)")
            let expectedStart = invariantArguments(entry, now: now)["start_iso"].flatMap { if case .string(let s) = $0 { utcAt(s) } else { nil } } ?? now
            #expect(instant(successor?["start"]) == expectedStart, "\(label): the following part starts \(successor?["start"] ?? "none")")
            #expect((series?["recurrence"] as? [String])?.contains { $0.contains("UNTIL=") } == true, "\(label): the series was not capped")
            #expect(instant(series?["start"]) == utcAt("\(day(0))T09:00:00"), "\(label): the earlier occurrences moved")
        case .refused, .error:
            break
        }
    }
}

@Suite("calendar_event_edit on Outlook: refused before the card, or the calendar holds what the card said", .serialized, .processGlobalState)
struct ExchangeSeriesScopeInvariantTests {

    /// The occurrence a week after `GraphFixture.start` times `week`.
    private static func place(_ week: Int) -> Date { GraphFixture.start.addingTimeInterval(Double(7 * week) * 86_400) }

    private static func occurrenceId(_ week: Int) -> String { "ser-1-occ-w\(week)" }

    /// The series (every week on its weekday, or every seventh day), its occurrences in weeks 0 to 4,
    /// the one `state` names changed, and the start it is listed at now and its id.
    private static func calendar(_ state: OccurrenceState, daily: Bool) -> (graph: FakeGraphCalendar, id: String, now: Date) {
        var occurrences: [Int: [String: Any]] = [:]
        for week in 0...4 { occurrences[week] = GraphSeries.occurrence(id: occurrenceId(week), at: place(week)) }
        let named: (week: Int, now: Date)
        switch state {
        case .unmoved:
            named = (1, place(1))
        case .movedFar, .movedOntoAnother:
            named = (2, place(2).addingTimeInterval(2 * 86_400))
            occurrences[2] = GraphSeries.moved(id: occurrenceId(2), from: place(2), to: named.now)
        case .firstMoved:
            named = (0, place(0).addingTimeInterval(86_400))
            occurrences[0] = GraphSeries.moved(id: occurrenceId(0), from: place(0), to: named.now)
        case .deleted:
            named = (4, place(4))
            occurrences[4] = nil
        }
        let graph = FakeGraphCalendar([GraphSeries.series(daily: daily)] + occurrences.keys.sorted().compactMap { occurrences[$0] })
        return (graph, occurrenceId(named.week), named.now)
    }

    @Test("every naming form, scope and change of an occurrence in every state Outlook holds",
          arguments: InvariantCase.all(states: OccurrenceState.allCases.filter { $0 != .movedOntoAnother }))
    func refusedBeforeTheCardOrWrittenAsTheCardSaid(_ entry: InvariantCase) async throws {
        let (graph, occurrenceId, now) = Self.calendar(entry.state, daily: !entry.kind.namesDays)
        let eventId = entry.form == .seriesIdAndStart ? "ser-1" : occurrenceId
        let seriesBefore = graph.event("ser-1")
        let run = try await outlookTool(graph, invariantArguments(entry, now: now), eventId: eventId,
                                        account: "inv-x-\(entry.testDescription)")
        let wrote = !graph.created.isEmpty || !graph.patches("ser-1").isEmpty || !graph.patches(occurrenceId).isEmpty
        guard let extent = checkProperty(entry, run: run, wrote: wrote) else { return }
        let label = entry.testDescription
        let card = run.cards[0]
        let series = graph.event("ser-1")
        switch extent {
        case .whole:
            #expect(graph.created.isEmpty && graph.patches(occurrenceId).isEmpty, "\(label): not a write of the series")
            if entry.kind == .rename {
                #expect(series?["subject"] as? String == "Renamed", "\(label): the series kept its subject")
            } else {
                let written = card.changes.first { $0.hasPrefix("start → ") }.map { String($0.dropFirst("start → ".count)) }
                #expect(instant(series?["start"]) == written.flatMap(utcAt), "\(label): the series starts \(series?["start"] ?? "none"), the card said \(written ?? "none")")
            }
        case .one:
            #expect(graph.created.isEmpty && graph.patches("ser-1").isEmpty, "\(label): the series was written")
            #expect(card.startDate == now, "\(label): the card shows \(card.startDate), the occurrence is at \(now)")
            let occurrence = graph.event(occurrenceId)
            if entry.kind == .rename {
                #expect(occurrence?["subject"] as? String == "Renamed", "\(label): the occurrence kept its subject")
            } else {
                let start = invariantArguments(entry, now: now)["start_iso"].flatMap { if case .string(let s) = $0 { utcAt(s) } else { nil } }
                #expect(instant(occurrence?["start"]) == start, "\(label): the occurrence starts \(occurrence?["start"] ?? "none")")
            }
            #expect(instant(series?["start"]) == instant(seriesBefore?["start"]), "\(label): the series moved")
        case .fromHereOn:
            #expect(graph.created.count == 1, "\(label): no following part")
            #expect(card.startDate == now, "\(label): the card shows \(card.startDate), the occurrence is at \(now)")
            let expectedStart = invariantArguments(entry, now: now)["start_iso"].flatMap { if case .string(let s) = $0 { utcAt(s) } else { nil } } ?? now
            #expect(instant(graph.created.first?["start"]) == expectedStart, "\(label): the following part starts \(graph.created.first?["start"] ?? "none")")
            let range = (series?["recurrence"] as? [String: Any])?["range"] as? [String: Any]
            #expect(range?["type"] as? String == "endDate", "\(label): the series was not capped")
        case .refused, .error:
            break
        }
    }
}

// MARK: - A split retried after its own cap

// INVARIANT (system property): a split (`this_and_following`) that the queue started and that was
// interrupted after it capped the series ends complete on its retry: the series ends before the
// split, the new part holds the occurrences from it on, and no row is left queued or failed. The
// cap ended the series before the occurrence the split starts at, so the retry does not look that
// occurrence up again (`CalendarProvider.isOwnSplitCap`); looked up, it is not found, and the split
// was retired half done. Outlook writes the cap first, so its interruption lost the new part; Google
// and CalDAV write it last, so theirs lost only the row's success.

@Suite("A split interrupted after its cap ends complete on its retry", .serialized, .processGlobalState)
struct SplitRetriedAfterItsOwnCapTests {

    @Test("Outlook: a split whose cap was written and whose new part was not is written whole on its retry, and the row is not retired")
    func outlookSplitInterruptedAfterItsCapIsFinished() async throws {
        let graph = GraphSeries.calendar(daily: true)
        // Named in the series' own zone, where Graph dates the cap's end.
        let zone = "America/Los_Angeles"
        let rid = GraphFixture.wall(GraphFixture.occurrenceStart, in: zone)
        // The cap is written, then the connection drops before its response arrives: no new part.
        graph.loseNextResponse("PATCH")
        let rows = try await outlook(graph, eventId: "ser-1", [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string(rid),
            "title": .string("Retitled"), "timezone": .string(zone),
        ], account: "own-cap-x", drains: 2)

        #expect(rows.isEmpty, "the split did not end complete: \(reasons(rows))")
        #expect(graph.created.count == 1, "the new part was not written: \(graph.created.count)")
        let created = graph.created.first
        #expect(instant(created?["start"]) == GraphFixture.occurrenceStart,
                "the new part does not start at the split: \(created?["start"] ?? "none")")
        #expect(created?["subject"] as? String == "Retitled", "the new part is not the edit: \(created?["subject"] ?? "none")")
        let cap = try #require(ExchangeCalendarProvider.graphEndDateBefore(
            naiveISO: rid, allDay: false, zone: TimeZone(identifier: zone)!))
        let range = (graph.event("ser-1")?["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        #expect(range?["type"] as? String == "endDate" && range?["endDate"] as? String == cap,
                "the series does not end before the split: \(range ?? [:])")
        #expect(graph.event("ser-1")?["subject"] as? String == "Planning", "the series' own occurrences were changed")
    }

    @Test("Google: a split whose cap's response was lost ends complete on its retry, its new time on a series on named days included")
    func googleSplitWhoseCapResponseWasLostEndsComplete() async throws {
        let rid = "\(day(7))T09:00:00"
        // The new part is written, then the cap, whose response is lost. A series on its weekday,
        // given a new time on the same date: the retry's own-cap read names no occurrence to date it.
        let r = try await google(GoogleSeries.calendar(rule: GoogleSeries.onItsWeekday), eventId: GoogleSeries.id, [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string(rid),
            "start_iso": .string("\(day(7))T11:00:00"), "timezone": .string("UTC"),
        ], account: "own-cap-g", loseNext: "PATCH", drains: 2)

        #expect(r.rows.isEmpty, "the split did not end complete: \(reasons(r.rows)); writes: \(r.calendar.writes)")
        let successor = r.calendar.event(
            GoogleCalendarProvider.deterministicSplitEventId(masterId: GoogleSeries.id, recurrenceId: rid))
        #expect(instant(successor?["start"]) == utcAt("\(day(7))T11:00:00"),
                "no following part at the new time: \(successor?["start"] ?? "none")")
        let cap = try #require(GoogleCalendarProvider.googleUntilString(beforeNaiveISO: rid, allDay: false, zone: utc))
        let master = r.calendar.event(GoogleSeries.id)
        let rule = (master?["recurrence"] as? [String])?.first { $0.uppercased().hasPrefix("RRULE:") }
        #expect(rule.map { RecurrenceTail.isCapped($0, at: cap) } == true, "the series does not end before the split: \(rule ?? "none")")
        #expect(instant(master?["start"]) == utcAt("\(day(0))T09:00:00"), "the series moved: \(master?["start"] ?? "none")")
    }
}
