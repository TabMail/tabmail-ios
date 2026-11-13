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
// **INVARIANT 3.** *A series whose rule names its days or dates (BYDAY, BYMONTHDAY, BYMONTH) moves
// them with a move to another date*, as Google Calendar does: the whole series' rule, or the new
// part's of a split, repeats on the new day. A day named by its position keeps its rule; a day of the
// year, a week number and a series whose own zone is not known are refused before the card and before
// the write, with nothing written, unless the edit gives the new rule.
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

/// The wall time `yyyy-MM-ddTHH:mm:ss` the UTC wall time `naive` is at in `zone`.
private func wallTime(_ naive: String, in zone: String) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = CalendarTimeZoneResolver.zone(named: zone, in: .none)
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return utcAt(naive).map(fmt.string(from:)) ?? naive
}

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

    /// `events` with every start, end and place labelled `zone`, at the same instants.
    static func rezoned(_ events: [[String: Any]], _ zone: String) -> [[String: Any]] {
        events.map { event in
            var e = event
            for key in ["start", "end", "originalStartTime"] {
                guard var time = e[key] as? [String: Any] else { continue }
                time["timeZone"] = zone
                e[key] = time
            }
            return e
        }
    }

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

// MARK: - Outlook: an all-day occurrence is named by its date

/// An Outlook all-day series, daily or weekly from `day(0)`, kept in `zone` (its range's
/// `recurrenceTimeZone`), with its occurrences around `day(named)`: each stored at midnight of its
/// date in that zone, with that instant as its place (`originalStart`, measured). Every read returns
/// an all-day start as midnight of its own date, labelled with the zone the read names
/// (`FakeGraphCalendar`, measured).
///
/// The zones are chosen from the device's, so every row crosses a date boundary on any host: the
/// series' zone is east of the device's (an occurrence's midnight there is the day before on the
/// device), and the edit names either the device's zone or one west of it (the device's midnight
/// is the day before there).
///
/// Internal, not private: `calendar_event_edit`'s `exdates_add` tests delete through the same lookup
/// with the same series (`CalendarEditExdatesOutlookTests`).
enum GraphAllDaySeries {
    static let id = "ser-ad-zoned"
    /// The date every test names.
    static let named = 7
    /// How many hours the series' zone is east of the device's, and the west zone west of it.
    static let hoursAcross = 5
    /// The offsets, in hours, the `Etc/GMT` zones span.
    static let eastmost = 14
    static let westmost = -12

    static func occurrence(_ offset: Int) -> String { "\(id)-\(day(offset))" }

    /// The offsets of the occurrences stored: a daily series has one on each neighbouring day, a
    /// weekly one none there.
    static func offsets(daily: Bool) -> [Int] { daily ? [named - 1, named, named + 1] : [named - 7, named, named + 7] }

    /// The device's offset from UTC, in hours, on the named date.
    static var deviceHours: Double {
        let at = EKEventStoreHelper.parseNaiveISO(day(named), timeZone: utc) ?? Date()
        return Double(TimeZone.current.secondsFromGMT(for: at)) / 3_600
    }

    /// The `Etc/GMT` zone `hours` from UTC: whole hours, no daylight saving time, and named with the
    /// POSIX sign, the reverse of the offset's.
    static func etcZone(_ hours: Int) -> String { hours == 0 ? "Etc/GMT" : "Etc/GMT\(hours > 0 ? "-" : "+")\(abs(hours))" }

    static var seriesHours: Int { min(Int(deviceHours.rounded(.down)) + hoursAcross, eastmost) }
    static var westHours: Int { max(Int(deviceHours.rounded(.up)) - hoursAcross, westmost) }

    /// The series' zone, east of the device's.
    static var seriesZone: String { etcZone(seriesHours) }

    /// The zones an edit or read names: the device's, and one west of it.
    static var editZones: [String] { [TimeZone.current.identifier, etcZone(westHours)] }

    /// Whether this host's zone leaves room for both crossings (every zone but the two ends of the
    /// world's offsets).
    static var crossesOnThisHost: Bool { Double(seriesHours) > deviceHours && Double(westHours) < deviceHours }

    static func calendar(daily: Bool) -> FakeGraphCalendar {
        let zone = seriesZone
        func atMidnight(_ e: inout [String: Any], _ offset: Int) {
            e["start"] = ["dateTime": "\(day(offset))T00:00:00.0000000", "timeZone": zone]
            e["end"] = ["dateTime": "\(day(offset + 1))T00:00:00.0000000", "timeZone": zone]
        }
        var series = GraphFixture.event(id: id, online: false, recurring: true, allDay: true)
        atMidnight(&series, 0)
        if var recurrence = series["recurrence"] as? [String: Any], var range = recurrence["range"] as? [String: Any] {
            range["startDate"] = day(0)
            range["recurrenceTimeZone"] = zone
            recurrence["range"] = range
            if daily {
                recurrence["pattern"] = ["type": "daily", "interval": 1, "month": 0, "dayOfMonth": 0,
                                         "firstDayOfWeek": "monday", "index": "first"]
            }
            series["recurrence"] = recurrence
        }
        let occurrences = offsets(daily: daily).map { offset -> [String: Any] in
            var e = GraphFixture.event(id: occurrence(offset), online: false, seriesMasterId: id, allDay: true)
            atMidnight(&e, offset)
            e["originalStart"] = GraphFixture.allDayPlace(day(offset), in: zone)
            return e
        }
        return FakeGraphCalendar([series] + occurrences)
    }

    /// The two ways an edit names `day(named)` directly: its date, and its start as the read tools
    /// show an all-day start (`allDayNaiveISO`).
    static var names: [String] { [day(named), CalendarToolHelpers.allDayNaiveISO(day(named))] }

    /// Every (daily, edit zone) pair.
    static var rows: [(daily: Bool, zone: String)] { [true, false].flatMap { daily in editZones.map { (daily, $0) } } }

    static func label(_ daily: Bool, _ zone: String, _ rest: String) -> String {
        "series \(seriesZone), device \(TimeZone.current.identifier), edit \(zone), \(daily ? "daily" : "weekly"), \(rest)"
    }
}

/// The occurrence on `day(shown)` was the only thing written: renamed by one PATCH, its
/// neighbours and the series untouched, nothing created, no row left.
private func onlyOccurrencePatched(_ shown: Int, daily: Bool, graph: FakeGraphCalendar, rows: [PendingCalendarOperation], _ label: String) {
    let named = GraphAllDaySeries.occurrence(shown)
    #expect(graph.patches(named).count == 1 && graph.event(named)?["subject"] as? String == "Holiday (renamed)",
            "\(label): the occurrence shown on \(day(shown)) was not changed; rows \(reasons(rows))")
    for offset in GraphAllDaySeries.offsets(daily: daily) where offset != shown {
        #expect(graph.patches(GraphAllDaySeries.occurrence(offset)).isEmpty, "\(label): the occurrence on \(day(offset)) was changed")
    }
    #expect(graph.patches(GraphAllDaySeries.id).isEmpty && graph.created.isEmpty, "\(label): the series was written")
    #expect(rows.isEmpty, "\(label): rows \(reasons(rows))")
}

@Suite("An Outlook all-day occurrence is named by its date (#647)", .serialized, .processGlobalState)
struct ExchangeAllDayOccurrenceDateTests {

    @Test("a this_only edit naming a date changes that date's occurrence and no other, whatever zone the edit names")
    func thisOnlyEditChangesTheNamedDate() async throws {
        #expect(GraphAllDaySeries.crossesOnThisHost, "device offset \(GraphAllDaySeries.deviceHours)h")
        for (index, row) in GraphAllDaySeries.rows.enumerated() {
            for (form, rid) in GraphAllDaySeries.names.enumerated() {
                let label = GraphAllDaySeries.label(row.daily, row.zone, rid)
                let graph = GraphAllDaySeries.calendar(daily: row.daily)
                let rows = try await outlook(graph, eventId: GraphAllDaySeries.id, [
                    "edit_scope": .string("this_only"), "recurrence_id": .string(rid),
                    "title": .string("Holiday (renamed)"), "timezone": .string(row.zone),
                ], account: "allday-date-\(index)-\(form)")
                onlyOccurrencePatched(GraphAllDaySeries.named, daily: row.daily, graph: graph, rows: rows, label)
            }
        }
    }

    @Test("the occurrence read naming a date gives that date's occurrence, whatever zone the read names")
    func occurrenceReadGivesTheNamedDate() async throws {
        #expect(GraphAllDaySeries.crossesOnThisHost, "device offset \(GraphAllDaySeries.deviceHours)h")
        for row in GraphAllDaySeries.rows {
            for rid in GraphAllDaySeries.names {
                let label = GraphAllDaySeries.label(row.daily, row.zone, rid)
                let graph = GraphAllDaySeries.calendar(daily: row.daily)
                let http = FakeHTTP.Scenario()
                defer { http.close() }
                graph.install(on: http)
                let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                        session: http.session)
                let zone = try #require(TimeZone(identifier: row.zone))
                do {
                    let found = try await provider.occurrence(
                        calendarId: "primary", eventId: GraphAllDaySeries.id, recurrenceId: rid, recurrenceIdZone: zone)
                    #expect(found.id == GraphAllDaySeries.occurrence(GraphAllDaySeries.named) && found.start?.date == day(GraphAllDaySeries.named),
                            "\(label): read \(found.id ?? "none") starting \(found.start?.date ?? "none")")
                } catch {
                    Issue.record("\(label): \(error)")
                }
                #expect(graph.patches(GraphAllDaySeries.id).isEmpty && graph.created.isEmpty, "\(label): written")
            }
        }
    }

    /// Where the read tools show an occurrence: the listing (`listEvents`) or a read by its id
    /// (`getEvent`), rendered as the tools render it (`formatDetailedEvent`) in the edit's zone.
    private enum Shown: CaseIterable { case listing, read }

    private func shownStart(_ shown: Shown, graph: FakeGraphCalendar, zone: TimeZone) async throws -> String? {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                session: http.session)
        let id = GraphAllDaySeries.occurrence(GraphAllDaySeries.named)
        let event: GCalEvent?
        switch shown {
        case .listing:
            // A listing names a window (`calendarView`), as the read tools' does.
            let from = EKEventStoreHelper.parseNaiveISO(day(GraphAllDaySeries.named - 1), timeZone: utc)
            let to = EKEventStoreHelper.parseNaiveISO(day(GraphAllDaySeries.named + 2), timeZone: utc)
            event = try await provider.listEvents(timeMin: from, timeMax: to).first { $0.id == id }
        case .read: event = try await provider.getEvent(eventId: id)
        }
        let text = event.map { CalendarToolHelpers.formatDetailedEvent($0, timeZone: zone) } ?? ""
        return text.split(separator: "\n").first { $0.hasPrefix("start_iso: ") }.map { String($0.dropFirst("start_iso: ".count)) }
    }

    @Test("an edit naming an occurrence by the start the read tools show for it, with the series' id or its own, changes that occurrence and no other")
    func startTheReadToolsShowNamesThatOccurrence() async throws {
        #expect(GraphAllDaySeries.crossesOnThisHost, "device offset \(GraphAllDaySeries.deviceHours)h")
        let named = GraphAllDaySeries.occurrence(GraphAllDaySeries.named)
        var account = 0
        for row in GraphAllDaySeries.rows {
            for shown in Shown.allCases {
                for eventId in [GraphAllDaySeries.id, named] {
                    account += 1
                    let graph = GraphAllDaySeries.calendar(daily: row.daily)
                    let zone = try #require(TimeZone(identifier: row.zone))
                    let start = try await shownStart(shown, graph: graph, zone: zone)
                    let label = GraphAllDaySeries.label(row.daily, row.zone, "\(shown) shows \(start ?? "no start"), event \(eventId)")
                    guard let start else {
                        Issue.record("\(label): the read tools show no start")
                        continue
                    }
                    let rows = try await outlook(graph, eventId: eventId, [
                        "edit_scope": .string("this_only"), "recurrence_id": .string(start),
                        "title": .string("Holiday (renamed)"), "timezone": .string(row.zone),
                    ], account: "allday-shown-\(account)")
                    onlyOccurrencePatched(GraphAllDaySeries.named, daily: row.daily, graph: graph, rows: rows, label)
                }
            }
        }
    }

    @Test("an edit of every occurrence naming an occurrence by its own id alone, read where the read tools show it, renames the series and no occurrence")
    func occurrenceIdAloneNamesThatOccurrence() async throws {
        // With no recurrence_id the occurrence is named by the start the read tools show for it
        // (`CalendarSeriesScope.shownStart`); the lookup must find it there, or the edit is
        // refused as naming none.
        #expect(GraphAllDaySeries.crossesOnThisHost, "device offset \(GraphAllDaySeries.deviceHours)h")
        for (index, row) in GraphAllDaySeries.rows.enumerated() {
            let label = GraphAllDaySeries.label(row.daily, row.zone, "own id, no recurrence_id")
            let graph = GraphAllDaySeries.calendar(daily: row.daily)
            let rows = try await outlook(graph, eventId: GraphAllDaySeries.occurrence(GraphAllDaySeries.named), [
                "title": .string("Holiday (renamed)"), "timezone": .string(row.zone),
            ], account: "allday-own-\(index)")
            #expect(graph.patches(GraphAllDaySeries.id).count == 1 && graph.event(GraphAllDaySeries.id)?["subject"] as? String == "Holiday (renamed)",
                    "\(label): the series was not renamed; rows \(reasons(rows))")
            for offset in GraphAllDaySeries.offsets(daily: row.daily) {
                #expect(graph.patches(GraphAllDaySeries.occurrence(offset)).isEmpty, "\(label): the occurrence on \(day(offset)) was changed")
            }
            #expect(graph.created.isEmpty && rows.isEmpty, "\(label): rows \(reasons(rows))")
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

@Suite("A series whose rule names its days moves them with a move to another date", .serialized, .processGlobalState)
struct CalendarSeriesDayMoveTests {

    private func refused(_ rows: [PendingCalendarOperation]) -> Bool {
        rows.count == 1 && rows.first?.status == PendingStatus.failed.rawValue
            && rows.first?.failureReason?.contains(namedDaysRefusal) == true
    }

    @Test("Google: every occurrence, named from the first, moved to another date moves the series onto the new weekday")
    func googleEveryOccurrenceToAnotherDateTurnsItsDays() async throws {
        let r = try await google(GoogleSeries.calendar(rule: GoogleSeries.onItsWeekday), eventId: GoogleSeries.first, [
            "start_iso": .string("\(day(1))T09:00:00"), "timezone": .string("UTC"),
        ], account: "days-g-all")
        let series = r.calendar.event(GoogleSeries.id)
        #expect(instant(series?["start"]) == utcAt("\(day(1))T09:00:00"),
                "the series did not move: \(series?["start"] ?? "none"); rows: \(reasons(r.rows))")
        #expect(series?["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(1)))"],
                "the series repeats on its old day: \(series?["recurrence"] ?? "none")")
        #expect(r.rows.isEmpty, "rows: \(reasons(r.rows))")
    }

    @Test("Google: an occurrence and the following ones moved to another date split there onto the new weekday, the earlier ones kept")
    func googleFollowingToAnotherDateTurnsTheNewPartsDays() async throws {
        let rid = "\(day(7))T09:00:00"
        let r = try await google(GoogleSeries.calendar(rule: GoogleSeries.onItsWeekday), eventId: GoogleSeries.id, [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string(rid),
            "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC"),
        ], account: "days-g-following")
        let successor = r.calendar.event(
            GoogleCalendarProvider.deterministicSplitEventId(masterId: GoogleSeries.id, recurrenceId: rid))
        #expect(instant(successor?["start"]) == utcAt("\(day(8))T09:00:00"),
                "no following part on the new date: \(successor?["start"] ?? "none"); rows: \(reasons(r.rows))")
        #expect(successor?["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(8)))"],
                "the following part repeats on the old day: \(successor?["recurrence"] ?? "none")")
        let master = r.calendar.event(GoogleSeries.id)
        let rule = (master?["recurrence"] as? [String])?.first ?? ""
        #expect(rule.contains("BYDAY=\(weekdayCode(day(0)))") && rule.contains("UNTIL="), "the earlier part changed: \(rule)")
        #expect(r.rows.isEmpty, "rows: \(reasons(r.rows))")
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

    @Test("Google: a series kept in another zone, moved to the next of its own dates, turns its days though the edit's zone sees the same date")
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
        #expect(moved.calendar.event(id)?["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(1)))"],
                "not turned by Tokyo's date: \(moved.calendar.event(id)?["recurrence"] ?? "none"); rows: \(reasons(moved.rows))")
        #expect(moved.rows.isEmpty, "rows: \(reasons(moved.rows))")
        // 10:00 UTC is 19:00 the same day in Tokyo (control).
        let kept = try await google(seed, eventId: "\(id)_first", [
            "start_iso": .string("\(day(0))T10:00:00"), "timezone": .string("UTC"),
        ], account: "days-g-zone-control")
        #expect(instant(kept.calendar.event(id)?["start"]) == utcAt("\(day(0))T10:00:00"),
                "the series did not move: \(kept.calendar.event(id)?["start"] ?? "none"); rows: \(reasons(kept.rows))")
        #expect(kept.calendar.event(id)?["recurrence"] as? [String] == [GoogleSeries.onItsWeekday],
                "the same date in Tokyo kept no days: \(kept.calendar.event(id)?["recurrence"] ?? "none")")
        #expect(kept.rows.isEmpty, "rows: \(reasons(kept.rows))")
    }

    @Test("Outlook: every occurrence of a weekly series (its weekday named), named from the first, moved to another date moves its weekday")
    func outlookEveryOccurrenceToAnotherDateTurnsItsDays() async throws {
        let graph = GraphSeries.calendar()
        let before = (graph.event("ser-1")?["recurrence"] as? [String: Any])?["pattern"] as? [String: Any]
        let rows = try await outlook(graph, eventId: GraphSeries.first, [
            "start_iso": .string(GraphFixture.naive(GraphFixture.start.addingTimeInterval(86_400))),
            "timezone": .string("UTC"),
        ], account: "days-x-all")
        let days = try #require(before?["daysOfWeek"] as? [String])
        let names = ExchangeCalendarProvider.graphWeekdays
        let turned = days.compactMap { names.firstIndex(of: $0).map { names[($0 + 1) % names.count] } }
        let pattern = (graph.event("ser-1")?["recurrence"] as? [String: Any])?["pattern"] as? [String: Any]
        #expect(pattern?["daysOfWeek"] as? [String] == turned, "pattern: \(pattern ?? [:]); rows: \(reasons(rows))")
        #expect(pattern?["firstDayOfWeek"] as? String == before?["firstDayOfWeek"] as? String, "a weekly series' week start moved")
        #expect(rows.isEmpty, "rows: \(reasons(rows))")
    }

    @Test("Google: a series with a deleted occurrence moved to another weekday and back keeps that occurrence back, as Google's own editor leaves it")
    func googleDayMoveThereAndBackKeepsTheDeletedOccurrenceBack() async throws {
        let exdate = "EXDATE:\(compact(day(14)))T090000Z"
        var series = GoogleSeries.series(rule: GoogleSeries.onItsWeekday)
        series["recurrence"] = [GoogleSeries.onItsWeekday, exdate]
        let there = try await google(GoogleSeries.calendar(rule: GoogleSeries.onItsWeekday).map { $0["id"] as? String == GoogleSeries.id ? series : $0 },
                                     eventId: GoogleSeries.first, [
            "start_iso": .string("\(day(1))T09:00:00"), "timezone": .string("UTC"),
        ], account: "days-g-exdate-there")
        let moved = try #require(there.calendar.event(GoogleSeries.id), "rows: \(reasons(there.rows))")
        let back = try await google([moved, GoogleSeries.instance(day(1))], eventId: GoogleSeries.instanceId(day(1)), [
            "start_iso": .string("\(day(0))T09:00:00"), "timezone": .string("UTC"),
        ], account: "days-g-exdate-back")
        let recurrence = back.calendar.event(GoogleSeries.id)?["recurrence"] as? [String]
        #expect(recurrence == [GoogleSeries.onItsWeekday], "after there and back: \(recurrence ?? []); rows \(reasons(there.rows + back.rows))")
    }

    @Test("CalDAV: a series on named weekdays kept in UTC, its zone not named, is refused a new start, with nothing PUT")
    func calDAVWithoutItsZoneIsRefused() async throws {
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

    @Test("CalDAV: a series on named weekdays moved to another date moves onto the new weekday, its following part too")
    func calDAVToAnotherDateTurnsItsDays() async throws {
        let rule = "RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(0)))"
        for (account, arguments, path, from): (String, [String: JSONValue], String?, Int) in [
            ("days-c-turn-all", ["edit_scope": .string("all"), "recurrence_id": .string("\(day(0))T09:00:00"),
                                 "start_iso": .string("\(day(1))T09:00:00"), "timezone": .string("UTC")], "/cal/wk-3.ics", 1),
            ("days-c-turn-following", ["edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(7))T09:00:00"),
                                       "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC")], nil, 8),
        ] {
            let store = FakeCalDAVStore(servesETags: true)
            store.seed(path: "/cal/wk-3.ics", ics: calDAVSeries(uid: "wk-3", rule: rule, tzid: "Etc/UTC"))
            let rows = try await calDAV(store, eventId: "/cal/wk-3.ics", arguments, account: account)
            #expect(rows.isEmpty, "\(account): rows \(reasons(rows))")
            // The following part is the resource the split PUT besides the series.
            let target = path ?? store.recordedPuts().first { $0.path != "/cal/wk-3.ics" }?.path
            let written = target.flatMap { store.storedICS(path: $0) }
            let rules = written?.components(separatedBy: "\r\n").filter { $0.hasPrefix("RRULE:") } ?? []
            #expect(rules == ["RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(from)))"], "\(account): \(rules)")
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

/// Confirms every card and keeps what each showed; runs `beforeConfirming`, when given, after the
/// card is shown and before it is confirmed (another client's change in between).
@MainActor
private final class RecordingCardSink: AgentUISink {
    var cards: [AgentToolRouter.ActionConfirmation.CalendarEventDetail] = []
    private let beforeConfirming: (@Sendable () -> Void)?
    nonisolated init(beforeConfirming: (@Sendable () -> Void)? = nil) { self.beforeConfirming = beforeConfirming }
    func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
        cards.append(contentsOf: confirmation.calendarEvents)
        beforeConfirming?()
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
                     provider: any CalendarProvider,
                     beforeConfirming: (@Sendable () -> Void)? = nil) async throws -> ToolRun {
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
    let sink = RecordingCardSink(beforeConfirming: beforeConfirming)
    let out: String
    var declined = false
    do {
        // The recurrence_ids these tests give are printed as the read tools print them, in the
        // device's zone (#794): the zone each edit names, so the device is in that zone here.
        let printedZone = CalendarToolHelpers.stringArgOpt(args, "timezone").flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) }
        out = try await CalendarEventEditTool(context: ToolContext(db: db, translator: MockChatIdTranslator(), deviceZone: printedZone))
            .execute(arguments: args, invocation: ToolInvocation(uiSink: sink, sessionKey: "series-tool-\(account)"))
    } catch let error as ToolDeclinedError {
        out = error.output
        declined = true
    }
    let queued = try await pool.read { try PendingCalendarOperation.fetchAll($0) }
    return ToolRun(out: out, cards: await sink.cards, queued: queued, declined: declined)
}

private func googleTool(_ arguments: [String: JSONValue], eventId: String, account: String,
                        rule: String = GoogleSeries.weekly, seed: [[String: Any]]? = nil,
                        beforeConfirming: (@Sendable (FakeGoogleCalendar) -> Void)? = nil)
    async throws -> (calendar: FakeGoogleCalendar, run: ToolRun) {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    let calendar = FakeGoogleCalendar(seed ?? GoogleSeries.calendar(rule: rule))
    calendar.install(on: http)
    let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
    let hook = beforeConfirming.map { hook in { @Sendable in hook(calendar) } }
    return (calendar, try await runTool(arguments, eventId: eventId, account: account, provider: provider,
                                        beforeConfirming: hook))
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

private func calDAVTool(_ store: FakeCalDAVStore, _ arguments: [String: JSONValue], eventId: String,
                        account: String) async throws -> ToolRun {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
    http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
    let home = URL(string: "https://caldav.example.com/cal/")!
    let provider = CalDAVProvider(
        client: CalDAVClient(username: "user@example.com", password: "pw", session: http.session),
        calendarHomeURL: home, serverBaseURL: home)
    return try await runTool(arguments, eventId: eventId, account: account, provider: provider)
}

/// A Graph recurrence as written, read back as the RRULE the card shows: the week start is named
/// only for a weekly series every few weeks, as Graph keeps it.
private func shownRule(_ recurrence: Any?) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: try #require(recurrence as? [String: Any]))
    let rule = try #require(ExchangeCalendarProvider.rrule(try JSONDecoder().decode(MSPatternedRecurrence.self, from: data)).first)
    return "repeat → " + rule.dropFirst("RRULE:".count)
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

    @Test("Google: a series on named weekdays, named from a later occurrence and moved to another date, splits there onto the new weekday, the card saying so")
    func laterOccurrenceToAnotherDateTurnsTheDaysOnNamedDays() async throws {
        let r = try await googleTool([
            "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "series-tool-g-byday", rule: GoogleSeries.onItsWeekday)
        let turned = "FREQ=WEEKLY;BYDAY=\(weekdayCode(day(8)))"
        #expect(r.run.cards.count == 1 && r.run.cards.first?.changes.contains("repeat → \(turned)") == true,
                "cards: \(r.run.cards.map(\.changes)); \(r.run.out)")
        let successor = r.calendar.event(
            GoogleCalendarProvider.deterministicSplitEventId(masterId: GoogleSeries.id, recurrenceId: "\(day(7))T09:00:00"))
        #expect(successor?["recurrence"] as? [String] == ["RRULE:" + turned],
                "the following part: \(successor?["recurrence"] ?? "none"); writes \(r.calendar.writes); \(r.run.out)")
        #expect(r.run.queued.isEmpty, "rows: \(reasons(r.run.queued))")
    }

    @Test("Google: a whole series on named weekdays moved to another day says on its card that its exceptions are reset")
    func googleWholeSeriesDayMoveCardSaysTheReset() async throws {
        let r = try await googleTool([
            "start_iso": .string("\(day(1))T09:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.first, account: "series-tool-g-reset-note", rule: GoogleSeries.onItsWeekday)
        let changes = r.run.cards.first?.changes ?? []
        #expect(changes.contains(CalendarToolHelpers.dayMoveResetNote) && !changes.contains(CalendarToolHelpers.ruleChangeResetNote),
                "card: \(changes); \(r.run.out)")
    }

    @Test("Google: a split onto another day drops the new part's excluded dates and keeps its added dates, as a move of the whole series does")
    func splitOntoAnotherDayDropsExcludedDates() async throws {
        let exdate = "EXDATE:\(compact(day(14)))T090000Z"
        let rdate = "RDATE:\(compact(day(16)))T090000Z"
        let seed = GoogleSeries.calendar(rule: GoogleSeries.onItsWeekday).map { event -> [String: Any] in
            guard event["id"] as? String == GoogleSeries.id else { return event }
            var series = event
            series["recurrence"] = [GoogleSeries.onItsWeekday, exdate, rdate]
            return series
        }
        let r = try await googleTool([
            "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "series-tool-g-split-exdate", seed: seed)
        let successor = r.calendar.event(
            GoogleCalendarProvider.deterministicSplitEventId(masterId: GoogleSeries.id, recurrenceId: "\(day(7))T09:00:00"))
        let written = try #require(successor?["recurrence"] as? [String], "no new part: \(r.calendar.writes); \(r.run.out)")
        #expect(written.first == "RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(8)))", "written: \(written)")
        #expect(!written.contains { $0.uppercased().hasPrefix("EXDATE") }, "an excluded date stays: \(written)")
        #expect(written.contains { $0.uppercased().hasPrefix("RDATE") }, "the added date is gone: \(written)")
        #expect(r.run.cards.first?.changes.contains(CalendarToolHelpers.dayMoveResetNote) == true,
                "card: \(r.run.cards.first?.changes ?? [])")
    }

    @Test("Google: a split onto another day of a rule named by position keeps its rule and the new part's excluded dates, and its card names neither")
    func positionalSplitOntoAnotherDayKeepsExcludedDates() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let ordinal = (cal.component(.day, from: try #require(Date.fromISO8601("\(day(0))T09:00:00Z"))) - 1) / 7 + 1
        let rule = "RRULE:FREQ=MONTHLY;BYDAY=\(ordinal)\(weekdayCode(day(0)))"
        let exdate = "EXDATE:\(compact(day(14)))T090000Z"
        let seed = GoogleSeries.calendar(rule: rule).map { event -> [String: Any] in
            guard event["id"] as? String == GoogleSeries.id else { return event }
            var series = event
            series["recurrence"] = [rule, exdate]
            return series
        }
        let r = try await googleTool([
            "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "series-tool-g-split-positional", seed: seed)
        let successor = r.calendar.event(
            GoogleCalendarProvider.deterministicSplitEventId(masterId: GoogleSeries.id, recurrenceId: "\(day(7))T09:00:00"))
        let written = try #require(successor?["recurrence"] as? [String], "no new part: \(r.calendar.writes); \(r.run.out)")
        #expect(written.contains { $0.uppercased().hasPrefix("EXDATE") }, "the excluded date was dropped: \(written)")
        let changes = r.run.cards.first?.changes ?? []
        #expect(!changes.contains(CalendarToolHelpers.dayMoveResetNote) && !changes.contains { $0.hasPrefix("repeat → ") },
                "card: \(changes)")
    }

    @Test("Google: the card of a split onto another day shows the rule the new part is written with, its count what is left")
    func splitCardShowsTheWrittenRule() async throws {
        let rule = "RRULE:FREQ=WEEKLY;COUNT=10;BYDAY=\(weekdayCode(day(0)))"
        let r = try await googleTool([
            "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "series-tool-g-card-count", rule: rule)
        let successor = r.calendar.event(
            GoogleCalendarProvider.deterministicSplitEventId(masterId: GoogleSeries.id, recurrenceId: "\(day(7))T09:00:00"))
        let written = try #require((successor?["recurrence"] as? [String])?.first, "no new part: \(r.calendar.writes); \(r.run.out)")
        #expect(written == "RRULE:FREQ=WEEKLY;COUNT=9;BYDAY=\(weekdayCode(day(8)))", "written: \(written)")
        let shown = r.run.cards.first?.changes.first { $0.hasPrefix("repeat → ") }
        #expect(shown == "repeat → " + written.dropFirst("RRULE:".count), "card \(shown ?? "none"), written \(written)")
    }

    @Test("Outlook: the card of a split onto another day shows the week start Graph writes for a series every other week")
    func outlookSplitCardShowsTheWrittenWeekStart() async throws {
        var series = GraphSeries.series()
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var pattern = try #require(recurrence["pattern"] as? [String: Any])
        pattern["interval"] = 2
        pattern["firstDayOfWeek"] = "sunday"
        recurrence["pattern"] = pattern
        series["recurrence"] = recurrence
        let graph = FakeGraphCalendar([series, GraphSeries.occurrence(id: GraphSeries.first, at: GraphFixture.start),
                                       GraphSeries.occurrence(id: GraphSeries.later, at: GraphFixture.occurrenceStart)])
        let r = try await outlookTool(graph, [
            "start_iso": .string(GraphFixture.naive(GraphFixture.occurrenceStart.addingTimeInterval(86_400))),
            "timezone": .string("UTC"),
        ], eventId: GraphSeries.later, account: "series-tool-x-card-wkst")
        let written = (graph.created.first?["recurrence"] as? [String: Any])?["pattern"] as? [String: Any]
        let first = try #require(written?["firstDayOfWeek"] as? String, "no new part: \(r.out)")
        #expect(first == "monday", "Graph's week start did not turn with the days: \(first)")
        let shown = r.cards.first?.changes.first { $0.hasPrefix("repeat → ") } ?? ""
        #expect(shown.hasSuffix(";WKST=MO"), "card \(shown), written week start \(first)")
    }

    /// A whole-number UTC offset (hours) for the series' zone, chosen from the device's own: two to
    /// three hours east of it, or, where that passes the last zone (UTC+14), two to three hours west.
    /// Either way the device's 01:00 and 23:00 on one day fall on two dates in the series' zone.
    static var seriesZoneHours: Int {
        let device = Double(TimeZone.current.secondsFromGMT()) / 3_600
        let east = Int(device.rounded(.up)) + 2
        return east <= 14 ? east : Int(device.rounded(.down)) - 2
    }

    @Test("Outlook: a whole-series move dated the same day on the device and in the edit's zone, but on another in the series' own, turns the pattern")
    func outlookMoveAcrossTheSeriesZoneDateTurnsThePattern() async throws {
        // Stored at 01:00 on day D on the device, moved to 23:00 on D: the same date on the device
        // and in the edit's zone (the device's), another in the series' zone (`seriesZoneHours`).
        let device = TimeZone.current
        let hours = Self.seriesZoneHours
        let seriesZone = hours == 0 ? "Etc/GMT" : "Etc/GMT\(hours > 0 ? "-" : "+")\(abs(hours))"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = device
        let dayD = cal.startOfDay(for: Date().addingTimeInterval(9 * 86_400))
        let start = dayD.addingTimeInterval(3_600)
        let moved = dayD.addingTimeInterval(23 * 3_600)
        let seriesTZ = try #require(TimeZone(identifier: seriesZone))
        var seriesCal = Calendar(identifier: .gregorian)
        seriesCal.timeZone = seriesTZ
        try #require(cal.isDate(start, inSameDayAs: moved) && !seriesCal.isDate(start, inSameDayAs: moved),
                     "the case is not built: series zone \(seriesZone), device \(device.identifier)")
        var series = GraphSeries.onDevice(GraphFixture.event(id: "ser-1", start: start, recurring: true), start: start)
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        range["recurrenceTimeZone"] = seriesZone
        recurrence["range"] = range
        series["recurrence"] = recurrence
        let graph = FakeGraphCalendar([series, GraphSeries.occurrence(id: GraphSeries.first, at: start)])
        let before = try #require((recurrence["pattern"] as? [String: Any])?["daysOfWeek"] as? [String])
        let rows = try await outlook(graph, eventId: GraphSeries.first, [
            "start_iso": .string(EKEventStoreHelper.toNaiveISO(moved, timeZone: device)),
            "timezone": .string(device.identifier),
        ], account: "days-x-series-zone-date")
        let step = seriesCal.dateComponents([.day], from: seriesCal.startOfDay(for: start), to: seriesCal.startOfDay(for: moved)).day ?? 0
        let names = ExchangeCalendarProvider.graphWeekdays
        let turned = before.compactMap { names.firstIndex(of: $0).map { names[($0 + step + names.count) % names.count] } }
        let pattern = (graph.event("ser-1")?["recurrence"] as? [String: Any])?["pattern"] as? [String: Any]
        #expect(pattern?["daysOfWeek"] as? [String] == turned, "pattern: \(pattern ?? [:]); rows: \(reasons(rows))")
        #expect(rows.isEmpty, "rows: \(reasons(rows))")
    }

    @Test("Outlook: the card of a numbered split onto another day shows the count the new part is written with")
    func outlookCountSplitCard() async throws {
        var series = GraphSeries.series()
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        range["type"] = "numbered"
        range["numberOfOccurrences"] = 10
        recurrence["range"] = range
        series["recurrence"] = recurrence
        let graph = FakeGraphCalendar([series, GraphSeries.occurrence(id: GraphSeries.first, at: GraphFixture.start),
                                       GraphSeries.occurrence(id: GraphSeries.later, at: GraphFixture.occurrenceStart)])
        let r = try await outlookTool(graph, [
            "start_iso": .string(GraphFixture.naive(GraphFixture.occurrenceStart.addingTimeInterval(86_400))),
            "timezone": .string("UTC"),
        ], eventId: GraphSeries.later, account: "series-tool-x-card-count")
        let written = try #require(graph.created.first?["recurrence"], "no new part: \(r.out)")
        #expect(((written as? [String: Any])?["range"] as? [String: Any])?["numberOfOccurrences"] as? Int == 9, "written: \(written)")
        let shown = r.cards.first?.changes.first { $0.hasPrefix("repeat → ") }
        #expect(shown == (try shownRule(written)), "card \(shown ?? "none"), written \(written)")
        #expect(r.cards.first?.changes.contains(CalendarToolHelpers.dayMoveResetNote) == true,
                "card: \(r.cards.first?.changes ?? [])")
    }

    @Test("Outlook: a split moved past the end date of its series is refused before the card, with nothing queued")
    func outlookSplitPastTheSeriesEndIsRefusedBeforeTheCard() async throws {
        // The series ends on its second occurrence's date; that occurrence and the following ones
        // are moved two days on, past the end, in the series' zone and in UTC alike.
        var series = GraphSeries.series()
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        range["type"] = "endDate"
        range["endDate"] = GraphFixture.utcDay(GraphFixture.occurrenceStart)
        recurrence["range"] = range
        series["recurrence"] = recurrence
        let graph = FakeGraphCalendar([series, GraphSeries.occurrence(id: GraphSeries.first, at: GraphFixture.start),
                                       GraphSeries.occurrence(id: GraphSeries.later, at: GraphFixture.occurrenceStart)])
        let r = try await outlookTool(graph, [
            "start_iso": .string(GraphFixture.naive(GraphFixture.occurrenceStart.addingTimeInterval(2 * 86_400))),
            "timezone": .string("UTC"),
        ], eventId: GraphSeries.later, account: "series-tool-x-past-end")
        #expect(r.out.contains("NOT changed") && r.out.contains("already ends before it"), "\(r.out)")
        #expect(r.cards.isEmpty, "a card was shown: \(r.cards.map(\.changes))")
        #expect(r.queued.isEmpty, "queued: \(r.queued.map(\.argumentsJSON))")
        #expect(graph.created.isEmpty, "a new part was written: \(graph.created)")
    }

    @Test("Outlook: the card of a split every week onto another day names no week start, as Graph's rule has none")
    func outlookWeeklySplitCardHasNoWeekStart() async throws {
        let graph = GraphSeries.calendar()
        let r = try await outlookTool(graph, [
            "start_iso": .string(GraphFixture.naive(GraphFixture.occurrenceStart.addingTimeInterval(86_400))),
            "timezone": .string("UTC"),
        ], eventId: GraphSeries.later, account: "series-tool-x-card-no-wkst")
        let written = try #require(graph.created.first?["recurrence"], "no new part: \(r.out)")
        let shown = r.cards.first?.changes.first { $0.hasPrefix("repeat → ") }
        #expect(shown == (try shownRule(written)) && shown?.contains("WKST") == false, "card \(shown ?? "none"), written \(written)")
    }

    @Test("Outlook: an all-day series kept in a zone TabMail does not recognize, moved to another day, shows the turned repeat the write makes")
    func outlookUnrecognizedRangeZoneCardShowsTheTurn() async throws {
        var series = GraphFixture.event(id: "ser-ad", online: false, recurring: true, allDay: true)
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        range["recurrenceTimeZone"] = "Custom Server Zone"
        recurrence["range"] = range
        series["recurrence"] = recurrence
        var first = GraphFixture.event(id: "ser-ad-occ", start: GraphFixture.start, online: false,
                                       seriesMasterId: "ser-ad", allDay: true)
        first["originalStart"] = GraphFixture.allDayPlace(GraphFixture.utcDay(GraphFixture.start), in: "UTC")
        let graph = FakeGraphCalendar([series, first], zones: ["Custom Server Zone": utc])
        let next = GraphFixture.utcDay(GraphFixture.start.addingTimeInterval(86_400))
        let r = try await outlookTool(graph, [
            "edit_scope": .string("all"), "start_iso": .string("\(next)T00:00:00"), "timezone": .string("UTC"),
        ], eventId: "ser-ad-occ", account: "series-tool-x-card-unknown-zone")
        let written = graph.event("ser-ad")?["recurrence"] as? [String: Any]
        let names = ExchangeCalendarProvider.graphWeekdays
        let turned = names.firstIndex(of: GraphFixture.weekday(GraphFixture.start)).map { [names[($0 + 1) % names.count]] }
        #expect((written?["pattern"] as? [String: Any])?["daysOfWeek"] as? [String] == turned, "written: \(written ?? [:]); \(r.out)")
        let shown = r.cards.first?.changes.first { $0.hasPrefix("repeat → ") }
        #expect(shown != nil && shown == (try? shownRule(written)), "card \(shown ?? "none"), written \(written ?? [:])")
    }

    @Test("CalDAV: the card of a numbered split onto another day shows the rule the new part is written with, its count what is left")
    func calDAVSplitCardShowsTheWrittenRule() async throws {
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: "/cal/wk-c.ics", ics: calDAVSeries(
            uid: "wk-c", rule: "RRULE:FREQ=WEEKLY;COUNT=10;BYDAY=\(weekdayCode(day(0)))", tzid: "Etc/UTC"))
        let r = try await calDAVTool(store, [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(7))T09:00:00"),
            "start_iso": .string("\(day(8))T09:00:00"), "timezone": .string("UTC"),
        ], eventId: "/cal/wk-c.ics", account: "series-tool-c-card-count")
        let part = store.recordedPuts().first { $0.path != "/cal/wk-c.ics" }?.path
        let written = try #require(part.flatMap { store.storedICS(path: $0) }?.components(separatedBy: "\r\n")
            .first { $0.hasPrefix("RRULE:") }, "no new part: \(r.out)")
        #expect(written == "RRULE:FREQ=WEEKLY;COUNT=9;BYDAY=\(weekdayCode(day(8)))", "written: \(written)")
        let shown = r.cards.first?.changes.first { $0.hasPrefix("repeat → ") }
        #expect(shown == "repeat → " + written.dropFirst("RRULE:".count), "card \(shown ?? "none"), written \(written)")
        #expect(r.cards.first?.changes.contains(CalendarToolHelpers.dayMoveResetNote) == true,
                "card: \(r.cards.first?.changes ?? [])")
    }

    /// A CalDAV series repeating by `rule` from day 0, its occurrence on day 14 deleted (an EXDATE),
    /// the one on day 21 changed to an hour later (an override) and an extra one added on day 17
    /// (an RDATE), moved as a whole a day on through the edit tool, or edited by `arguments` when
    /// given: the resource's lines after the write, and the run.
    private func calDAVMoveWithExceptions(rule: String, account: String, split: Bool = false,
                                          splitTo: String = "\(day(8))T09:00:00",
                                          arguments: [String: JSONValue]? = nil) async throws -> (lines: [String], run: ToolRun) {
        let series = calDAVSeries(uid: "wk-x", rule: rule, tzid: "Etc/UTC")
            .replacingOccurrences(of: "SUMMARY:Standup\r\nEND:VEVENT",
                                  with: "EXDATE;TZID=Etc/UTC:\(compact(day(14)))T090000\r\n"
                                      + "RDATE;TZID=Etc/UTC:\(compact(day(17)))T090000\r\nSUMMARY:Standup\r\nEND:VEVENT")
            .replacingOccurrences(of: "END:VCALENDAR", with: [
                "BEGIN:VEVENT", "UID:wk-x", "DTSTAMP:\(compact(day(-14)))T000000Z",
                "RECURRENCE-ID;TZID=Etc/UTC:\(compact(day(21)))T090000",
                "DTSTART;TZID=Etc/UTC:\(compact(day(21)))T100000", "DTEND;TZID=Etc/UTC:\(compact(day(21)))T103000",
                "SUMMARY:Standup (changed)", "END:VEVENT", "END:VCALENDAR",
            ].joined(separator: "\r\n"))
        let store = FakeCalDAVStore(servesETags: true)
        store.seed(path: "/cal/wk-x.ics", ics: series)
        // A split is made at day 7 and moved to day 8; its new part is the resource the split PUT
        // besides the series.
        let r = try await calDAVTool(store, arguments ?? (split ? [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(7))T09:00:00"),
            "start_iso": .string(splitTo), "timezone": .string("UTC"),
        ] : [
            "edit_scope": .string("all"), "recurrence_id": .string("\(day(0))T09:00:00"),
            "start_iso": .string("\(day(1))T09:00:00"), "timezone": .string("UTC"),
        ]), eventId: "/cal/wk-x.ics", account: account)
        let path = split ? store.recordedPuts().first { $0.path != "/cal/wk-x.ics" }?.path : "/cal/wk-x.ics"
        return (path.flatMap { store.storedICS(path: $0) }?.components(separatedBy: "\r\n") ?? [], r)
    }

    @Test("CalDAV: a whole series moved to another day with its rule's days resets every exception, as Google does, and the card says so")
    func calDAVDayMoveResetsExceptions() async throws {
        // The deleted week comes back on its new day and the changed one's edit is dropped.
        let (lines, r) = try await calDAVMoveWithExceptions(
            rule: "RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(0)))", account: "series-tool-c-day-move-resets")
        #expect(lines.contains("RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(1)))"), "not moved: \(lines); \(r.out)")
        #expect(!lines.contains { $0.hasPrefix("EXDATE") || $0.hasPrefix("RECURRENCE-ID") },
                "an exception outside the new rule remains: \(lines)")
        // An added date is the user's own occurrence, not an exception to the rule: it stays,
        // moved the day on with the series' start, as every date tied to the start is.
        #expect(lines.contains { $0.hasPrefix("RDATE") && $0.hasSuffix(":\(compact(day(18)))T090000") },
                "the added date was dropped: \(lines)")
        #expect(r.cards.first?.changes.contains(CalendarToolHelpers.dayMoveResetNote) == true,
                "card: \(r.cards.first?.changes ?? [])")
    }

    @Test("CalDAV: a whole series made all-day resets every occurrence changed or deleted on its own, keeps its added date, and the card says so")
    func calDAVKindChangeResetsExceptions() async throws {
        let (lines, r) = try await calDAVMoveWithExceptions(
            rule: "RRULE:FREQ=WEEKLY", account: "series-tool-c-kind-resets", arguments: [
                "edit_scope": .string("all"), "all_day": .bool(true),
                "start_iso": .string(day(0)), "end_iso": .string(day(1)), "timezone": .string("UTC"),
            ])
        #expect(lines.contains("DTSTART;VALUE=DATE:\(compact(day(0)))"), "not made all-day: \(lines); \(r.out)")
        #expect(!lines.contains { $0.hasPrefix("EXDATE") || $0.hasPrefix("RECURRENCE-ID") },
                "an occurrence changed or deleted on its own was kept: \(lines)")
        #expect(lines.contains("RDATE;VALUE=DATE:\(compact(day(17)))"), "the added date was not kept as a date: \(lines)")
        #expect(r.cards.first?.changes.contains(CalendarToolHelpers.kindChangeResetNote) == true,
                "card: \(r.cards.first?.changes ?? [])")
    }

    @Test("CalDAV: a split onto another day that turns its rule drops the new part's exceptions, and the card says so")
    func calDAVSplitDayMoveResetsExceptions() async throws {
        let (lines, r) = try await calDAVMoveWithExceptions(
            rule: "RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(0)))", account: "series-tool-c-split-resets", split: true)
        #expect(lines.contains { $0.hasPrefix("RRULE:FREQ=WEEKLY") && $0.contains("BYDAY=\(weekdayCode(day(8)))") },
                "the new part is not on the new day: \(lines); \(r.out)")
        #expect(!lines.contains { $0.hasPrefix("EXDATE") || $0.hasPrefix("RECURRENCE-ID") },
                "an exception outside the new rule remains in the new part: \(lines)")
        // Kept, moved the day on with the new part's start.
        #expect(lines.contains { $0.hasPrefix("RDATE") && $0.hasSuffix(":\(compact(day(18)))T090000") },
                "the added date was dropped from the new part: \(lines)")
        #expect(r.cards.first?.changes.contains(CalendarToolHelpers.dayMoveResetNote) == true,
                "card: \(r.cards.first?.changes ?? [])")
    }

    @Test("CalDAV: a split that does not turn its rule (a new time on its own day) keeps the new part's exceptions, and the card names neither")
    func calDAVUnturnedSplitKeepsExceptions() async throws {
        let (lines, r) = try await calDAVMoveWithExceptions(
            rule: "RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(0)))", account: "series-tool-c-split-unturned", split: true,
            splitTo: "\(day(7))T11:00:00")
        #expect(lines.contains { $0.hasPrefix("EXDATE") } && lines.contains { $0.hasPrefix("RECURRENCE-ID") },
                "an exception was dropped from the new part: \(lines); \(r.out)")
        let changes = r.cards.first?.changes ?? []
        #expect(!changes.contains(CalendarToolHelpers.dayMoveResetNote) && !changes.contains { $0.hasPrefix("repeat → ") },
                "card: \(changes)")
    }

    @Test("CalDAV: a whole series named by position moved to another day keeps its rule and every exception, and the card names neither")
    func calDAVPositionalMoveKeepsExceptions() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let ordinal = (cal.component(.day, from: try #require(Date.fromISO8601("\(day(0))T09:00:00Z"))) - 1) / 7 + 1
        let rule = "RRULE:FREQ=MONTHLY;BYDAY=\(ordinal)\(weekdayCode(day(0)))"
        let (lines, r) = try await calDAVMoveWithExceptions(rule: rule, account: "series-tool-c-positional-keeps")
        #expect(lines.contains(rule), "the rule changed: \(lines); \(r.out)")
        #expect(lines.contains { $0.hasPrefix("EXDATE") } && lines.contains { $0.hasPrefix("RECURRENCE-ID") },
                "an exception was dropped: \(lines)")
        let changes = r.cards.first?.changes ?? []
        #expect(!changes.contains(CalendarToolHelpers.dayMoveResetNote) && !changes.contains { $0.hasPrefix("repeat → ") },
                "card: \(changes)")
    }

    @Test("Google: a split onto another day at an occurrence moved from its place is refused with nothing written, so a move counted from its place is never written from where it is now")
    func splitAtAMovedOccurrenceOntoAnotherDayIsRefused() async throws {
        // The day move of a split is counted from the occurrence's place (`CalendarSeriesScope.dayMove`),
        // which is right only because no split is made at a moved one.
        let seed = GoogleSeries.calendar(rule: GoogleSeries.onItsWeekday).filter { $0["id"] as? String != GoogleSeries.later }
            + [GoogleSeries.moved(day(7), start: "\(day(9))T09:00:00", end: "\(day(9))T09:30:00")]
        let r = try await googleTool([
            "edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(9))T09:00:00"),
            "start_iso": .string("\(day(10))T09:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "series-tool-g-moved-split-days", seed: seed)
        #expect(r.calendar.writes.isEmpty, "written: \(r.calendar.writes); \(r.run.out)")
        // The edit reached the split, which refused it for its moved occurrence.
        try #require(r.run.queued.count == 1, "the edit did not reach the split: \(r.run.out)")
        #expect(r.run.queued.first?.status == PendingStatus.failed.rawValue
                && r.run.queued.first?.failureReason?.contains("split at a moved occurrence") == true,
                "rows: \(reasons(r.run.queued)); \(r.run.out)")
    }

    @Test("Outlook: a weekly series (its weekday named), named from a later occurrence and moved to another date, splits there onto the new weekday")
    func laterOccurrenceToAnotherDateTurnsTheDaysOnOutlook() async throws {
        let graph = GraphSeries.calendar()
        let r = try await outlookTool(graph, [
            "start_iso": .string(GraphFixture.naive(GraphFixture.occurrenceStart.addingTimeInterval(86_400))),
            "timezone": .string("UTC"),
        ], eventId: GraphSeries.later, account: "series-tool-x-byday")
        #expect(r.cards.count == 1 && r.queued.isEmpty, "cards \(r.cards.count) queued \(reasons(r.queued)); \(r.out)")
        let names = ExchangeCalendarProvider.graphWeekdays
        let own = GraphFixture.weekday(GraphFixture.start)
        let next = names.firstIndex(of: own).map { names[($0 + 1) % names.count] }
        let pattern = (graph.created.first?["recurrence"] as? [String: Any])?["pattern"] as? [String: Any]
        #expect(next != nil && pattern?["daysOfWeek"] as? [String] == next.map { [$0] },
                "the following part: \(pattern ?? [:]); created \(graph.created.count); \(r.out)")
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

    @Test("Google: a series kept in Etc/UTC, its later occurrence's own time given back in UTC, moves nothing: no note, no reset")
    func googleEtcUTCEchoInUTCIsQuiet() async throws {
        // Etc/UTC and UTC are two zones Foundation tells apart; neither changes its clocks and both
        // are at UTC+0, so every occurrence repeats at the same instant in either.
        let r = try await googleTool([
            "start_iso": .string("\(day(7))T09:00:00"), "end_iso": .string("\(day(7))T09:30:00"),
            "title": .string("Team standup"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "series-note-g-etc-utc",
           seed: GoogleSeries.rezoned(GoogleSeries.calendar, "Etc/UTC"))
        #expect(r.run.cards.first?.changes.contains(CalendarToolHelpers.ruleChangeResetNote) == false,
                "card: \(r.run.cards.first?.changes ?? [])")
        #expect(r.calendar.seriesResets == 0, "the series was reset: \(r.calendar.writes)")
        #expect(r.calendar.event(GoogleSeries.id)?["summary"] as? String == "Team standup", "\(r.run.out)")
    }

    /// An edit of every occurrence named from the occurrence `eventId` at `start`-`end` in `zone`
    /// warns on the card, resets the series, and leaves it in `zone`.
    private func expectZoneMove(_ start: String, _ end: String, zone: String, eventId: String,
                                account: String, seed: [[String: Any]]? = nil) async throws {
        let r = try await googleTool([
            "start_iso": .string(start), "end_iso": .string(end),
            "title": .string("Team standup"), "timezone": .string(zone),
        ], eventId: eventId, account: account, seed: seed)
        #expect(r.run.cards.first?.changes.contains(CalendarToolHelpers.ruleChangeResetNote) == true,
                "card: \(r.run.cards.first?.changes ?? [])")
        #expect(r.calendar.seriesResets == 1, "the write did not reset the series: \(r.calendar.writes)")
        let stored = r.calendar.event(GoogleSeries.id)?["start"] as? [String: Any]
        #expect(stored?["timeZone"] as? String == zone, "start: \(String(describing: stored))")
    }

    @Test("Google: a later occurrence's own clock time given in a zone at another offset is a move: the note, and the series is reset")
    func googleSameDigitsInAnotherOffsetWarnsAndResets() async throws {
        try await expectZoneMove("\(day(7))T09:00:00", "\(day(7))T09:30:00", zone: "Asia/Kolkata",
                                 eventId: GoogleSeries.later, account: "series-note-g-digits")
    }

    @Test("Google: a later occurrence's own instant given in a zone with no clock changes at another offset is a move: the note, and the series is reset")
    func googleSameInstantAtAnotherFixedOffsetWarnsAndResets() async throws {
        // Asia/Kolkata (UTC+5:30) changes no clocks, as UTC does not; the offsets differ.
        try await expectZoneMove(wallTime("\(day(7))T09:00:00", in: "Asia/Kolkata"),
                                 wallTime("\(day(7))T09:30:00", in: "Asia/Kolkata"), zone: "Asia/Kolkata",
                                 eventId: GoogleSeries.later, account: "series-note-g-fixed-offset")
    }

    @Test("Google: a series kept in a zone that changes its clocks, its first occurrence's own time given in another such zone at the same offset, is a move")
    func googleSameOffsetInAnotherClockChangingZoneWarnsAndResets() async throws {
        // America/New_York and America/Toronto are at one offset now and change their clocks:
        // their rules may part later, so the series would repeat at other instants.
        let seed = GoogleSeries.rezoned(GoogleSeries.calendar, "America/New_York")
        let zone = try #require(CalendarTimeZoneResolver.zone(named: "America/Toronto", in: .none))
        let newYork = try #require(CalendarTimeZoneResolver.zone(named: "America/New_York", in: .none))
        let at = try #require(utcAt("\(day(0))T09:00:00"))
        try #require(zone.secondsFromGMT(for: at) == newYork.secondsFromGMT(for: at)
                     && zone.nextDaylightSavingTimeTransition(after: at) != nil,
                     "setup: the two zones are not at one offset that day, or Toronto changes no clocks")
        try await expectZoneMove(wallTime("\(day(0))T09:00:00", in: "America/Toronto"),
                                 wallTime("\(day(0))T09:30:00", in: "America/Toronto"), zone: "America/Toronto",
                                 eventId: GoogleSeries.first, account: "series-note-g-clock-pair", seed: seed)
    }

    @Test("Google: a Tokyo series given its own instants in Asia/Seoul with a new title PATCHes no start or end, and the card shows no reset")
    func googleSameZoneUnderAnotherNameSendsNoTimes() async throws {
        // Asia/Tokyo and Asia/Seoul are both UTC+9 with no clock changes: one zone (`googleZone`).
        let seed = GoogleSeries.rezoned(GoogleSeries.calendar, "Asia/Tokyo")
        let r = try await googleTool([
            "start_iso": .string(wallTime("\(day(7))T09:00:00", in: "Asia/Seoul")),
            "end_iso": .string(wallTime("\(day(7))T09:30:00", in: "Asia/Seoul")),
            "title": .string("Team standup"), "timezone": .string("Asia/Seoul"),
        ], eventId: GoogleSeries.later, account: "series-note-g-seoul", seed: seed)
        #expect(r.run.cards.first?.changes.contains(CalendarToolHelpers.ruleChangeResetNote) == false,
                "card: \(r.run.cards.first?.changes ?? [])")
        let bodies = r.calendar.patchBodies(GoogleSeries.id)
        #expect(bodies.count == 1, "writes: \(r.calendar.writes)")
        #expect(bodies.first?["summary"] as? String == "Team standup", "body: \(bodies)")
        #expect(bodies.first?["start"] == nil && bodies.first?["end"] == nil, "a start or end was sent: \(bodies)")
        #expect(r.calendar.seriesResets == 0, "the series was reset: \(r.calendar.writes)")
        let start = r.calendar.event(GoogleSeries.id)?["start"] as? [String: Any]
        #expect(start?["timeZone"] as? String == "Asia/Tokyo", "start: \(String(describing: start))")
    }

    @Test("Google: a new time of every occurrence PATCHes the series' start and end together")
    func googleMoveSendsStartAndEnd() async throws {
        let r = try await googleTool([
            "start_iso": .string("\(day(7))T11:00:00"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "series-note-g-move-body")
        let bodies = r.calendar.patchBodies(GoogleSeries.id)
        #expect(bodies.count == 1, "writes: \(r.calendar.writes)")
        let start = bodies.first?["start"] as? [String: Any], end = bodies.first?["end"] as? [String: Any]
        #expect(instant(start) == utcAt("\(day(0))T11:00:00") && instant(end) == utcAt("\(day(0))T11:30:00"),
                "start \(String(describing: start)), end \(String(describing: end))")
        #expect(r.calendar.seriesResets == 1, "the write did not reset the series: \(r.calendar.writes)")
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

    /// A change between all-day and timed of every occurrence, or of a split's new part, changes the
    /// series as a whole and resets its occurrences changed or deleted on their own; one occurrence's
    /// own change of kind resets nothing.
    @Test("Google: a change of kind warns on the card on every occurrence and on a split, never on one occurrence",
          arguments: ["all", "this_and_following", "this_only"])
    func googleKindChangeWarns(_ scope: String) async throws {
        var arguments: [String: JSONValue] = [
            "edit_scope": .string(scope), "all_day": .bool(true), "timezone": .string("UTC"),
            "start_iso": .string(day(scope == "all" ? 0 : 7)), "end_iso": .string(day(scope == "all" ? 1 : 8)),
        ]
        if scope != "all" { arguments["recurrence_id"] = .string("\(day(7))T09:00:00") }
        let r = try await googleTool(arguments, eventId: scope == "all" ? GoogleSeries.first : GoogleSeries.later,
                                     account: "series-note-g-kind-\(scope)")
        let changes = try #require(r.run.cards.first?.changes, "no card: \(r.run.out)")
        #expect(changes.contains(CalendarToolHelpers.kindChangeResetNote) == (scope != "this_only"), "\(scope): card: \(changes)")
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
        let routed = try CalendarSeriesScope.route(args, scope: scope, named: named, zone: zone, recurrenceIdZone: zone)
        #expect(CalendarToolHelpers.stringArgOpt(routed.args, "edit_scope") ?? scope == routed.scope,
                "the arguments' edit_scope is not the scope written")
        // Routed again, it routes to itself: the queue decides what the card said. The queue reads
        // what the routed edit names: the series' own id with no `recurrence_id` names no occurrence.
        let reread: CalendarSeriesScope.Named
        if routed.eventId == named.eventId, !(routed.recurrenceId == nil && routed.eventId == named.seriesId) {
            reread = named
        } else {
            reread = Self.named(try named.readSeries())
        }
        let again = try CalendarSeriesScope.route(routed.args, scope: routed.scope, named: reread, zone: zone, recurrenceIdZone: zone)
        #expect(again.scope == routed.scope && again.args == routed.args, "routed again: \(again.scope), not \(routed.scope)")
        return Went(scope: routed.scope, recurrenceId: routed.recurrenceId,
                    start: CalendarToolHelpers.stringArgOpt(routed.args, "start_iso"),
                    end: CalendarToolHelpers.stringArgOpt(routed.args, "end_iso"), eventId: routed.eventId)
    }

    private func refusal(_ args: [String: JSONValue], _ named: CalendarSeriesScope.Named, scope: String = "all",
                         zone: TimeZone = utc) -> String? {
        do {
            _ = try CalendarSeriesScope.route(args, scope: scope, named: named, zone: zone, recurrenceIdZone: zone)
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

    @Test("a recurrence_id route names for a later occurrence is in the recurrence_id's zone, not the edit's (#794)")
    func mintedRecurrenceIdIsInTheRecurrenceIdZone() throws {
        let later = Self.named(Self.timedSeries, occurrence: Self.occurrence(timed(day(7))))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let routed = try CalendarSeriesScope.route(
            ["start_iso": .string("\(day(8))T09:00:00")], scope: "all", named: later, zone: utc, recurrenceIdZone: tokyo)
        #expect(routed.scope == "this_and_following" && routed.recurrenceId == "\(day(7))T18:00:00",
                "\(routed.scope) at \(routed.recurrenceId ?? "-")")
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

@Suite("CalendarSeriesScope.dayMove")
struct CalendarSeriesScopeDayMoveUnitTests {

    private static let byDay = "RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(day(0)))"

    private static func series(_ recurrence: [String]?) -> GCalEvent {
        gcalEvent(id: "ser", start: timed(day(0)), end: timed(day(0), "09:30:00"), recurrence: recurrence)
    }

    private static func named(_ series: GCalEvent, occurrence: GCalEvent? = nil) -> CalendarSeriesScope.Named {
        .init(eventId: "ser", event: series, seriesId: "ser", series: series, occurrence: occurrence)
    }

    private static func move(_ from: Int, _ to: Int) -> RecurrenceDayShift.Move? {
        guard let a = RecurrenceTail.Day(iso: day(from)), let b = RecurrenceTail.Day(iso: day(to)) else { return nil }
        return .init(from: a, to: b)
    }

    private func dayMove(_ args: [String: JSONValue], rule: String = CalendarSeriesScopeDayMoveUnitTests.byDay, scope: String = "all",
                         zone: TimeZone = utc, occurrence: GCalEvent? = nil) throws -> RecurrenceDayShift.Move? {
        try CalendarSeriesScope.dayMove(args, named: Self.named(Self.series([rule]), occurrence: occurrence), scope: scope, zone: zone)
    }

    private func reason(_ body: () throws -> RecurrenceDayShift.Move?) -> String? {
        do { _ = try body(); return nil } catch CalendarProviderError.notSupported(let reason) { return reason } catch { return "\(error)" }
    }

    private static let toAnotherDate: [String: JSONValue] = ["start_iso": .string("\(day(1))T09:00:00")]

    @Test("a move to another date of a series on named days or dates is the move from its date to the new one")
    func namedDaysMove() throws {
        for rule in ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE", "RRULE:FREQ=MONTHLY;BYMONTHDAY=15", "RRULE:FREQ=YEARLY;BYMONTH=3",
                     "RRULE:FREQ=MONTHLY;BYDAY=2TU", "RRULE:FREQ=MONTHLY;BYSETPOS=1;BYDAY=MO", "rrule:freq=weekly;byday=mo"] {
            #expect(try dayMove(Self.toAnotherDate, rule: rule) == Self.move(0, 1), "\(rule)")
        }
    }

    @Test("a day of the year or a week number is refused, naming it: no move by whole days carries it")
    func unmovablePartsAreRefused() {
        for (rule, part) in [("RRULE:FREQ=YEARLY;BYYEARDAY=100", "BYYEARDAY=100"), ("RRULE:FREQ=YEARLY;BYWEEKNO=20", "BYWEEKNO=20"),
                             ("RRULE:FREQ=MONTHLY;BYMONTHDAY=-1", "BYMONTHDAY=-1")] {
            let refusal = reason { try dayMove(Self.toAnotherDate, rule: rule) }
            #expect(refusal?.contains(part) == true, "\(rule): \(refusal ?? "passed")")
        }
    }

    @Test("a rule that names no days is no move: its days follow the start")
    func ruleWithoutNamedDaysIsNoMove() throws {
        for rule in ["RRULE:FREQ=DAILY", "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=5", "RRULE:FREQ=MONTHLY;UNTIL=20991231T000000Z",
                     "RRULE:FREQ=YEARLY;WKST=SU"] {
            #expect(try dayMove(Self.toAnotherDate, rule: rule) == nil, "\(rule)")
        }
        let exdate = Self.series(["RRULE:FREQ=WEEKLY", "EXDATE:\(compact(day(7)))T090000Z"])
        #expect(try CalendarSeriesScope.dayMove(Self.toAnotherDate, named: Self.named(exdate), scope: "all", zone: utc) == nil)
        #expect(try CalendarSeriesScope.dayMove(Self.toAnotherDate, named: Self.named(Self.series(nil)), scope: "all", zone: utc) == nil)
    }

    @Test("another time on the same date, an end alone, one occurrence, and an edit that moves nothing are no move")
    func sameDateEndOnlyAndOneOccurrenceAreNoMove() throws {
        #expect(try dayMove(["start_iso": .string("\(day(0))T15:00:00")]) == nil)
        #expect(try dayMove(["end_iso": .string("\(day(3))T10:00:00")]) == nil)
        #expect(try dayMove(["recurrence_id": .string("\(day(7))T09:00:00"), "start_iso": .string("\(day(8))T09:00:00")],
                            scope: "this_only") == nil)
        #expect(try dayMove(["title": .string("Renamed")]) == nil)
    }

    @Test("a new rule given with the move is written as given; a recurrence the builder writes no rule from is no new rule")
    func givenRuleIsNoMove() throws {
        var withRule = Self.toAnotherDate
        withRule["recurrence"] = .dictionary(["freq": .string("WEEKLY")])
        #expect(try dayMove(withRule) == nil)
        withRule["recurrence"] = .dictionary(["freq": .string("FORTNIGHTLY")])
        #expect(try dayMove(withRule) == Self.move(0, 1))
        withRule["recurrence"] = .string("weekly")
        #expect(try dayMove(withRule) == Self.move(0, 1))
    }

    @Test("an occurrence and the following ones: the date is judged where the occurrence is now, the move counted from its place in the series")
    func followingMovesFromItsPlace() throws {
        // Scheduled on day 7, moved on its own to day 9: a new time on day 9 keeps its date; day 10
        // moves the days from day 7, the place the new part's rule repeats from.
        let moved = gcalEvent(id: "ser_occ", start: timed(day(9)), end: nil, recurrence: nil, series: "ser", original: timed(day(7)))
        #expect(try dayMove(["recurrence_id": .string("\(day(9))T09:00:00"), "start_iso": .string("\(day(9))T11:00:00")],
                            scope: "this_and_following", occurrence: moved) == nil)
        #expect(try dayMove(["recurrence_id": .string("\(day(9))T09:00:00"), "start_iso": .string("\(day(10))T09:00:00")],
                            scope: "this_and_following", occurrence: moved) == Self.move(7, 10))
        // Back onto its own date from where it is now is a move of its days by none.
        #expect(try dayMove(["recurrence_id": .string("\(day(9))T09:00:00"), "start_iso": .string("\(day(7))T09:00:00")],
                            scope: "this_and_following", occurrence: moved) == nil)
    }

    @Test("a split at an occurrence still at its place moves the days from it; a split with no occurrence read is no move, left to the scope's own refusal")
    func splitMovesFromItsOccurrence() throws {
        // A split's retry after its new part was written never comes here: the queue finishes it
        // from its `SplitRecord`, whose new part already carries the turned rule.
        let rid = JSONValue.string("\(day(7))T09:00:00")
        let unmoved = gcalEvent(id: "ser_occ", start: timed(day(7)), end: nil, recurrence: nil, series: "ser", original: timed(day(7)))
        for target in [8, 10, 13] {
            let args: [String: JSONValue] = ["recurrence_id": rid, "start_iso": .string("\(day(target))T09:00:00")]
            #expect(try dayMove(args, scope: "this_and_following", occurrence: unmoved) == Self.move(7, target), "to day \(target)")
            #expect(try dayMove(args, scope: "this_and_following") == nil, "to day \(target), no occurrence read")
        }
    }

    @Test("an all-day series is moved by date")
    func allDayByDate() throws {
        let allDay = gcalEvent(id: "ser", start: GCalDateTime(dateTime: nil, date: day(0), timeZone: nil),
                               end: GCalDateTime(dateTime: nil, date: day(1), timeZone: nil), recurrence: [Self.byDay])
        let occurrence = gcalEvent(id: "ser_occ", start: GCalDateTime(dateTime: nil, date: day(7), timeZone: nil), end: nil,
                                   recurrence: nil, series: "ser", original: GCalDateTime(dateTime: nil, date: day(7), timeZone: nil))
        func allDayMove(_ args: [String: JSONValue], scope: String = "all") throws -> RecurrenceDayShift.Move? {
            try CalendarSeriesScope.dayMove(args, named: Self.named(allDay, occurrence: occurrence), scope: scope, zone: utc)
        }
        #expect(try allDayMove(["start_iso": .string("\(day(0))T00:00:00")]) == nil)
        #expect(try allDayMove(["start_iso": .string("\(day(2))T00:00:00")]) == Self.move(0, 2))
        #expect(try allDayMove(["recurrence_id": .string(day(7)), "start_iso": .string("\(day(7))T00:00:00")],
                               scope: "this_and_following") == nil)
    }

    @Test("the dates are the series' own, in its zone, not the edit's")
    func datesAreReadInTheSeriesZone() throws {
        // A series at 23:00 in Tokyo (14:00 UTC) on its weekday. 16:00 UTC is the same date in UTC,
        // the edit's zone, and the next date in Tokyo, where the series repeats: a move to another
        // date. 10:00 UTC is 19:00 the same day in Tokyo.
        let series = gcalEvent(id: "ser", start: GCalDateTime(dateTime: "\(day(0))T14:00:00Z", date: nil, timeZone: "Asia/Tokyo"),
                               end: nil, recurrence: [Self.byDay])
        func tokyoMove(_ start: String, zone: TimeZone = utc) throws -> RecurrenceDayShift.Move? {
            try CalendarSeriesScope.dayMove(["start_iso": .string(start)], named: Self.named(series), scope: "all", zone: zone)
        }
        #expect(try tokyoMove("\(day(0))T16:00:00") == Self.move(0, 1))
        #expect(try tokyoMove("\(day(0))T10:00:00") == nil)
        // The edit's zone reads the naive start; the date is still Tokyo's.
        let honolulu = try #require(TimeZone(identifier: "Pacific/Honolulu"))
        #expect(try tokyoMove("\(day(0))T06:00:00", zone: honolulu) == Self.move(0, 1),
                "06:00 in Honolulu is 01:00 the next day in Tokyo")
        #expect(try tokyoMove("\(day(-1))T20:00:00", zone: honolulu) == nil, "20:00 the day before in Honolulu is 15:00 in Tokyo")
    }

    @Test("a series whose own zone is not known is refused a new start, even on its date")
    func unknownZoneIsRefused() throws {
        // A CalDAV series kept in UTC names no zone (#679); an Outlook series whose recurrence zone
        // TabMail does not recognize has none it can read either.
        let zoneless = gcalEvent(id: "ser", start: GCalDateTime(dateTime: "\(day(0))T09:00:00Z", date: nil, timeZone: nil),
                                 end: nil, recurrence: [Self.byDay])
        var outlook = Self.series([Self.byDay])
        outlook.recurrenceTimeZoneName = "Not a zone"
        for series in [zoneless, outlook] {
            let refusal = reason {
                try CalendarSeriesScope.dayMove(["start_iso": .string("\(day(0))T15:00:00")], named: Self.named(series),
                                                scope: "all", zone: utc)
            }
            #expect(refusal?.contains("its own time zone is not known") == true, "\(refusal ?? "passed")")
        }
        outlook.recurrenceTimeZoneName = "UTC"
        #expect(try CalendarSeriesScope.dayMove(["start_iso": .string("\(day(0))T15:00:00")], named: Self.named(outlook),
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
        let output = try await CalendarEventEditTool(context: ToolContext(db: harness.pool, translator: translator, deviceZone: fixture.zone)).execute(
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

// MARK: - An occurrence deleted after the card

/// An occurrence deleted by another client after the card was shown is the provider's not-found at
/// the drain: the row is retired as stale (`AccountManager.isCalendarNotFoundError`), nothing is
/// written, and no row stays queued.
@Suite("An occurrence deleted after the card is retired as stale at the drain", .serialized, .processGlobalState)
struct DeletedAfterTheCardTests {
    typealias W = OccurrenceWireFixture
    typealias H = CalDAVToolWire

    /// The drain's retirement of an edit whose event is not found on the server.
    private static let staleReason = "event not found on server"

    @Test("Google: the occurrence deleted after its card, the drain retires the row as stale and writes nothing")
    func googleDeletedAfterTheCard() async throws {
        let r = try await googleTool([
            "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T09:00:00"),
            "title": .string("Team standup"), "timezone": .string("UTC"),
        ], eventId: GoogleSeries.later, account: "deleted-after-card-g",
           beforeConfirming: { $0.store(GoogleSeries.deleted(day(7))) })
        #expect(r.run.cards.count == 1, "no card: \(r.run.out)")
        #expect(r.calendar.writes.isEmpty, "writes: \(r.calendar.writes)")
        #expect(r.run.queued.count == 1 && r.run.queued.allSatisfy {
            $0.status == PendingStatus.failed.rawValue && $0.failureReason == Self.staleReason
        }, "rows: \(reasons(r.run.queued))")
        #expect(r.calendar.event(GoogleSeries.later)?["summary"] as? String == "Standup")
    }

    @Test("CalDAV: the occurrence deleted after its card, the drain retires the row as stale and writes nothing")
    func calDAVDeletedAfterTheCard() async throws {
        let session = "deleted-after-card-c"
        let harness = try await H.makeHarness(accountId: session)
        defer { H.tearDown(harness) }
        let fixture = harness.fixture
        let occurrence = try fixture.occurrence(2)
        let eventId = try fixture.occurrenceId(2)
        // The series with that occurrence deleted, as another client leaves it: an EXDATE.
        let wall = OccurrenceFixture.wall(occurrence, fixture.zone)
        let deleted = fixture.ics.replacingOccurrences(
            of: "RRULE:FREQ=WEEKLY", with: "RRULE:FREQ=WEEKLY\r\nEXDATE;TZID=America/New_York:\(wall)")
        try #require(deleted != fixture.ics, "the fixture has no rule line to add the EXDATE after")

        let translator = ChatIdTranslator.createIsolated()
        let compound = CompoundEventId.make(accountId: harness.accountId, eventId: eventId)
        let forModel = await translator.processToolOutputForLLM("event_id: \(compound)")
        let numericId = try #require(H.eventIds(in: forModel).first.flatMap { Int($0) })
        await H.recordCalendar(of: eventId, accountId: harness.accountId, translator: translator)
        let store = harness.store
        let sink = RecordingCardSink(beforeConfirming: { store.seed(path: W.seriesPath, ics: deleted) })
        let output = try await CalendarEventEditTool(context: ToolContext(db: harness.pool, translator: translator, deviceZone: fixture.zone)).execute(
            arguments: [
                "event_id": .string(String(numericId)), "edit_scope": .string("this_only"),
                "recurrence_id": .string(OccurrenceFixture.naive(occurrence, fixture.zone)),
                "title": .string("Retitled"), "timezone": .string(fixture.zone.identifier),
            ],
            invocation: ToolInvocation(uiSink: sink, sessionKey: session))
        let cards = await sink.cards
        #expect(cards.count == 1, "no card: \(output)")
        #expect(harness.store.recordedPuts().isEmpty, "PUT: \(harness.store.recordedPuts().map(\.path))")
        #expect(H.deletes(harness.http).isEmpty, "DELETE: \(H.deletes(harness.http))")
        let ops = try await harness.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
        #expect(ops.count == 1 && ops.allSatisfy {
            $0.status == PendingStatus.failed.rawValue && $0.failureReason == Self.staleReason
        }, "rows: \(reasons(ops))")
        #expect(harness.store.storedICS(path: W.seriesPath) == deleted, "the series was changed")
    }
}

// MARK: - A series rewritten to hold only changed occurrences after the card

/// The card is built while the CalDAV resource holds its series; before the user confirms, the server
/// rewrites it to hold only the one changed occurrence the user is still invited to, with no series
/// VEVENT (a scheduling server does this when the organizer keeps the user on one occurrence and
/// drops them from the series). A second calendar operation on the same account is queued after it.
///
/// PROPERTY (never-drop's wedge corollary, memory 146 invariant 4): after ONE drain nothing is left
/// queued, the second operation ran, and the edit ended terminally: a `this_only` edit written to
/// the occurrence the card named, any other scope retired with nothing written. Neither the error
/// type, the reason text nor the drain arm is asserted.
///
/// Also the row a build before the series read existed could have left: a `this_only` edit of an
/// occurrence in a resource that already held only changed occurrences, put straight into the queue.
@Suite("A resource rewritten to hold only changed occurrences after the card never wedges the calendar queue", .serialized, .processGlobalState)
struct RewrittenAfterTheCardTests {
    typealias W = OccurrenceWireFixture
    typealias H = CalDAVToolWire

    private static let newTitle = "Retitled"
    /// The second operation's event: a one-off on the same account, renamed.
    private static let otherPath = "/cal/lunch.ics"
    private static let otherTitle = "Team lunch"

    /// A one-off event at `otherPath`, an hour after the fixture's first occurrence.
    private static func oneOff(_ fixture: W) -> String {
        let wall = { (date: Date) in OccurrenceFixture.wall(date, fixture.zone) }
        let start = fixture.first.addingTimeInterval(3 * 60 * 60)
        return OccurrenceFixture.ics([[
            "UID:lunch-1",
            "DTSTAMP:\(OccurrenceFixture.utcValue(fixture.first))",
            "DTSTART;TZID=America/New_York:\(wall(start))",
            "DTEND;TZID=America/New_York:\(wall(start.addingTimeInterval(60 * 60)))",
            "SUMMARY:Lunch",
        ].joined(separator: "\n")])
    }

    /// The second operation, put straight into the queue (no drain of its own): a rename of the
    /// one-off event.
    private static func queueSecondOperation(_ harness: H.Harness) async throws -> PendingCalendarOperation {
        let op = PendingCalendarOperation(
            operationType: .edit, accountId: harness.accountId, eventId: otherPath, calendarId: W.calendarId,
            arguments: ["title": .string(otherTitle), "timezone": .string(harness.fixture.zone.identifier)])
        try await harness.pool.write { db in try op.insert(db) }
        return op
    }

    /// Waits for a drain another trigger started (the tool's own, after its card) to finish, so the
    /// test's one drain is not skipped as "already draining".
    private static func waitForTheRunningDrain() async {
        for _ in 0..<400 {
            if await !AccountManager.shared.isDrainingCalendar { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// The edit's state on the server after the drain, and what is left in the queue.
    private struct Outcome {
        let rows: [PendingCalendarOperation]
        let second: PendingCalendarOperation
        let stored: String?
        let otherStored: String?
        let puts: [String]
        let deletes: [String]
    }

    private static func drainOnce(_ harness: H.Harness, second: PendingCalendarOperation, path: String) async throws -> Outcome {
        await AccountManager.shared.drainCalendarQueue()
        let rows = try await harness.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
        return Outcome(
            rows: rows, second: second, stored: harness.store.storedICS(path: path),
            otherStored: harness.store.storedICS(path: otherPath),
            puts: harness.store.recordedPuts().map(\.path), deletes: H.deletes(harness.http))
    }

    /// The property, for an edit expected written (`written`) or retired.
    private static func expectTerminal(
        _ outcome: Outcome, label: String, written: Bool, before rewritten: String, path: String
    ) {
        let queued = outcome.rows.filter { $0.status != PendingStatus.failed.rawValue }
        #expect(queued.isEmpty, "\(label): left queued after a drain: \(reasons(queued)) retry \(queued.map(\.retryCount))")
        #expect(!outcome.rows.contains { $0.id == outcome.second.id },
                "\(label): the next operation on the account did not run: \(reasons(outcome.rows))")
        #expect(outcome.otherStored?.contains("SUMMARY:\(otherTitle)") == true,
                "\(label): the next operation's write is not on the server")
        #expect(outcome.deletes.isEmpty, "\(label): DELETE: \(outcome.deletes)")
        let edits = outcome.rows.filter { $0.id != outcome.second.id }
        if written {
            #expect(edits.isEmpty, "\(label): the edit did not complete: \(reasons(edits))")
            #expect(outcome.puts.filter { $0 == path } == [path], "\(label): not one write of the resource: \(outcome.puts)")
            let stored = outcome.stored ?? ""
            #expect(stored.components(separatedBy: "BEGIN:VEVENT").count - 1 == 1, "\(label): the write added a VEVENT: \(stored)")
            #expect(stored.contains("SUMMARY:\(newTitle)"), "\(label): the occurrence was not changed: \(stored)")
            for name in ["RECURRENCE-ID", "DTSTART", "DTEND"] {
                #expect(lines(stored, named: name) == lines(rewritten, named: name),
                        "\(label): the write changed the occurrence's \(name): \(lines(stored, named: name))")
            }
        } else {
            #expect(edits.count == 1 && edits.allSatisfy { $0.status == PendingStatus.failed.rawValue },
                    "\(label): the edit was not retired: \(reasons(edits))")
            #expect(!outcome.puts.contains(path), "\(label): written: \(outcome.puts)")
            #expect(outcome.stored == rewritten, "\(label): the resource is not on the server as it was")
        }
    }

    private static func lines(_ ics: String, named name: String) -> [String] {
        ics.components(separatedBy: .newlines).filter { $0.hasPrefix("\(name):") || $0.hasPrefix("\(name);") }
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let scope: String
        let written: Bool
        var testDescription: String { scope }
    }

    static let cases = [
        Case(scope: "this_only", written: true),
        Case(scope: "all", written: false),
        Case(scope: "this_and_following", written: false),
    ]

    @Test("rewritten between the card and the drain: after one drain nothing is queued, the next operation ran, and the edit is written (this_only) or retired",
          arguments: cases)
    func rewrittenBetweenTheCardAndTheDrain(_ entry: Case) async throws {
        let session = "caldav-rewritten-\(entry.scope)"
        let harness = try await H.makeHarness(accountId: session)
        defer { H.tearDown(harness) }
        let fixture = harness.fixture
        harness.store.seed(path: Self.otherPath, ics: Self.oneOff(fixture))
        let slot = try fixture.occurrence(2)
        let eventId = try fixture.occurrenceId(2)
        // The same resource, holding only that occurrence where it is, as the server rewrites it.
        let rewritten = try fixture.overrideOnly(form: "tzid", moved: false)
        try #require(rewritten.key == OccurrenceFixture.utcValue(slot), "the rewrite names another occurrence")

        let translator = ChatIdTranslator.createIsolated()
        let compound = CompoundEventId.make(accountId: harness.accountId, eventId: eventId)
        let forModel = await translator.processToolOutputForLLM("event_id: \(compound)")
        let numericId = try #require(H.eventIds(in: forModel).first.flatMap { Int($0) })
        await H.recordCalendar(of: eventId, accountId: harness.accountId, translator: translator)
        var arguments: [String: JSONValue] = [
            "event_id": .string(String(numericId)), "edit_scope": .string(entry.scope),
            "title": .string(Self.newTitle), "timezone": .string(fixture.zone.identifier),
        ]
        if entry.scope != "all" {
            arguments["recurrence_id"] = .string(OccurrenceFixture.naive(slot, fixture.zone))
        }
        let store = harness.store
        let sink = RecordingCardSink(beforeConfirming: { store.seed(path: W.seriesPath, ics: rewritten.ics) })
        let output = try await CalendarEventEditTool(context: ToolContext(db: harness.pool, translator: translator, deviceZone: fixture.zone)).execute(
            arguments: arguments, invocation: ToolInvocation(uiSink: sink, sessionKey: session))
        let cards = await sink.cards
        #expect(cards.count == 1, "\(entry.scope): no card, so the edit never reached the queue: \(output)")

        // The id the listing gave at the card still names that occurrence after the rewrite.
        let listed = try await W.makeProvider(harness.http).listEvents(
            calendarId: W.calendarId, timeMin: slot.addingTimeInterval(-60), timeMax: slot.addingTimeInterval(60),
            query: nil, singleEvents: true, maxResults: 250, orderBy: "startTime")
        #expect(listed.contains { $0.id == eventId && $0.startDate == slot },
                "\(entry.scope): after the rewrite no occurrence is listed with the card's id at its start: \(listed.map { "\($0.id ?? "nil") \($0.start?.dateTime ?? "nil")" })")

        await Self.waitForTheRunningDrain()
        let second = try await Self.queueSecondOperation(harness)
        let outcome = try await Self.drainOnce(harness, second: second, path: W.seriesPath)
        Self.expectTerminal(outcome, label: entry.scope, written: entry.written, before: rewritten.ics, path: W.seriesPath)
    }

    @Test("a this_only edit of an occurrence in a resource that holds only changed occurrences, already in the queue: written in one drain, and the next operation ran")
    func queuedThisOnlyOnAnOverrideOnlyResource() async throws {
        let harness = try await H.makeHarness(accountId: "caldav-queued-override-only")
        defer { H.tearDown(harness) }
        let fixture = harness.fixture
        harness.store.seed(path: Self.otherPath, ics: Self.oneOff(fixture))
        let (path, ics, occurrenceId) = try H.seedOverrideOnly(harness, form: "tzid", moved: false)
        let edit = PendingCalendarOperation(
            operationType: .edit, accountId: harness.accountId, eventId: occurrenceId, calendarId: W.calendarId,
            arguments: [
                "edit_scope": .string("this_only"),
                "recurrence_id": .string(OccurrenceFixture.naive(try fixture.occurrence(2), fixture.zone)),
                "title": .string(Self.newTitle), "timezone": .string(fixture.zone.identifier),
            ])
        try await harness.pool.write { db in try edit.insert(db) }
        let second = try await Self.queueSecondOperation(harness)
        let outcome = try await Self.drainOnce(harness, second: second, path: path)
        Self.expectTerminal(outcome, label: "queued this_only", written: true, before: ics, path: path)
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
            // A series on named days moved to another date moves its days with it, as Google
            // Calendar does: the same extent as a series naming none.
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
            case .dateNamedDays, .datePlain, .dateWithRule:
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
        // A deleted occurrence is refused as one the edit names none of: the lookup finds no
        // deleted occurrence. (Its own id with no recurrence_id is refused for one occurrence, or
        // it and the following ones, by the tool's argument check first.)
        if entry.state == .deleted, entry.form != .ownId || entry.scope == "all" {
            let error = (try? JSONSerialization.jsonObject(with: Data(r.run.out.utf8)) as? [String: Any])?["error"] as? String ?? ""
            let recurrenceId = entry.form == .ownId ? nil : GraphFixture.naive(now)
            #expect(error.contains(CalendarSeriesScope.namesNoOccurrence(recurrenceId)),
                    "\(entry.testDescription): not refused as naming no occurrence: \(r.run.out)")
        }
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

// MARK: - A split interrupted between its writes (#601)

// INVARIANT (system property): a split (`this_and_following`) writes its new part, then caps the
// series. Once the new part is written, a retry of the operation never writes it again, and:
// - while the new part is there, the retry ends the split complete: one new part, the series ends
//   before the split, the row is gone, whichever id (series or occurrence) the edit named;
// - once the user deleted the new part, the retry writes nothing at all (no new part, no cap), the
//   row is `failed` with the ruled reason, and the account's next queued change still drains in the
//   same drain;
// - a series that already ends before the split is left as it is.
// The record of the written new part (`SplitRecord`) is on the row before the cap is sent, and a
// transient failure keeps it. Every provider writes in that order (Outlook used to cap first).

/// The user-visible refusal when the new part of an unfinished split was deleted (as ruled).
private let newPartDeletedReason = "This change to the repeating event wasn't finished because its new part was deleted. Check the event's later occurrences, and make the change again if you still want it."

/// One calendar, faked on the wire, holding a weekly series to split, a one-off event to retitle
/// after it, and what the tests ask of it: the writes as they arrive, in order, and the split's
/// outcome there.
final class SplitHarness: @unchecked Sendable {
    enum Kind: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case google, outlook, calDAV
        var testDescription: String { rawValue }
    }

    let kind: Kind
    let http = FakeHTTP.Scenario()
    let provider: any CalendarProvider
    let calendarId: String
    let seriesId: String
    /// An id naming the split's own occurrence, where the calendar has one (not CalDAV here).
    let occurrenceId: String?
    let recurrenceId: String
    let zone: String
    let nextEventId: String
    private let arrivals = NSLock()
    private var log: [String] = []
    private var capHook: (@Sendable () -> Void)?

    let google: FakeGoogleCalendar?
    let graph: FakeGraphCalendar?
    let store: FakeCalDAVStore?

    static let calDAVSeriesPath = "/cal/ser-c.ics"
    static let calDAVOneOffPath = "/cal/one-off.ics"

    init(_ kind: Kind, googleRule: String = GoogleSeries.weekly, graphRange: [String: Any]? = nil,
         calDAVRule: String = "RRULE:FREQ=WEEKLY") {
        self.kind = kind
        switch kind {
        case .google:
            let calendar = FakeGoogleCalendar(GoogleSeries.calendar(rule: googleRule) + [FakeGoogleCalendar.timed(id: "one-off", day: day(1))])
            calendar.install(on: http)
            google = calendar; graph = nil; store = nil
            provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
            calendarId = "primary"; seriesId = GoogleSeries.id; occurrenceId = GoogleSeries.later
            recurrenceId = "\(day(7))T09:00:00"; zone = "UTC"; nextEventId = "one-off"
        case .outlook:
            var series = GraphSeries.series(daily: true)
            if let graphRange, var recurrence = series["recurrence"] as? [String: Any] {
                var range = recurrence["range"] as? [String: Any] ?? [:]
                for (key, value) in graphRange { range[key] = value }
                recurrence["range"] = range
                series["recurrence"] = recurrence
            }
            let calendar = FakeGraphCalendar([
                series, GraphSeries.occurrence(id: GraphSeries.first, at: GraphFixture.start),
                GraphSeries.occurrence(id: GraphSeries.later, at: GraphFixture.occurrenceStart),
                GraphFixture.event(id: "one-off", online: false),
            ])
            calendar.install(on: http)
            google = nil; graph = calendar; store = nil
            provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                session: http.session)
            calendarId = "primary"; seriesId = "ser-1"; occurrenceId = GraphSeries.later
            zone = "America/Los_Angeles"; recurrenceId = GraphFixture.wall(GraphFixture.occurrenceStart, in: zone)
            nextEventId = "one-off"
        case .calDAV:
            let calendar = FakeCalDAVStore(servesETags: true)
            calendar.seed(path: Self.calDAVSeriesPath, ics: calDAVSeries(uid: "ser-c", rule: calDAVRule))
            calendar.seed(path: Self.calDAVOneOffPath, ics: Self.oneOffICS)
            http.register(path: "/cal/", method: "GET") { calendar.handleGET($0) }
            http.register(path: "/cal/", method: "PUT") { calendar.handlePUT($0) }
            google = nil; graph = nil; store = calendar
            let home = URL(string: "https://caldav.example.com/cal/")!
            provider = CalDAVProvider(
                client: CalDAVClient(username: "user@example.com", password: "pw", session: http.session),
                calendarHomeURL: home, serverBaseURL: home)
            calendarId = "/cal/"; seriesId = Self.calDAVSeriesPath; occurrenceId = nil
            recurrenceId = "\(day(7))T09:00:00"; zone = "UTC"; nextEventId = Self.calDAVOneOffPath
        }
        google?.beforeWrite { [unowned self] method, id in
            self.arrived("\(method) \(id)", cap: method == "PATCH" && id == self.seriesId)
        }
        graph?.beforeWrite { [unowned self] method, id in
            self.arrived(id.isEmpty ? method : "\(method) \(id)", cap: method == "PATCH" && id == self.seriesId)
        }
        store?.beforePUT { [unowned self] path in self.arrived("PUT \(path)", cap: path == self.seriesId) }
    }

    deinit { http.close() }

    static let oneOffICS = [
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TabMail//Test//EN", "BEGIN:VEVENT",
        "UID:one-off", "DTSTAMP:\(compact(day(-14)))T000000Z",
        "DTSTART:\(compact(day(1)))T090000Z", "DTEND:\(compact(day(1)))T093000Z",
        "SUMMARY:Standup", "END:VEVENT", "END:VCALENDAR",
    ].joined(separator: "\r\n")

    private func arrived(_ write: String, cap: Bool) {
        let hook = arrivals.withLock { () -> (@Sendable () -> Void)? in
            log.append(write)
            return cap ? capHook : nil
        }
        hook?()
    }

    /// Every write of the split, as it arrived (refused ones included), in order; the one-off's
    /// own write is left out.
    var splitWrites: [String] { arrivals.withLock { log }.filter { !$0.hasSuffix(nextEventId) } }

    func isCap(_ write: String) -> Bool { write == "PATCH \(seriesId)" || write == "PUT \(seriesId)" }
    func isCreate(_ write: String) -> Bool { !isCap(write) }

    /// Runs as the cap arrives at the calendar, before it is applied.
    func onCap(_ hook: @escaping @Sendable () -> Void) { arrivals.withLock { capHook = hook } }

    var arguments: [String: JSONValue] {
        ["edit_scope": .string("this_and_following"), "recurrence_id": .string(recurrenceId),
         "title": .string("Retitled"), "timezone": .string(zone)]
    }

    /// The next cap is refused with a server error, and changes nothing.
    func failCap() {
        google?.failNext("PATCH", with: 500)
        graph?.failNext("PATCH", with: 500)
        store?.failNextPUT(path: Self.calDAVSeriesPath, with: 500)
    }

    /// The next cap is written and its answer is lost; nil where the fake can't lose one.
    var loseCap: (() -> Void)? {
        if let google { return { google.loseNextResponse("PATCH") } }
        if let graph { return { graph.loseNextResponse("PATCH") } }
        return nil
    }

    var newPartIds: [String] {
        switch kind {
        case .google:
            let id = GoogleCalendarProvider.deterministicSplitEventId(masterId: seriesId, recurrenceId: recurrenceId)
            return google?.event(id).map { $0["status"] as? String == "cancelled" ? [] : [id] } ?? []
        case .outlook:
            return graph?.created.compactMap { $0["id"] as? String } ?? []
        case .calDAV:
            let paths = Set((store?.recordedPuts() ?? []).filter { $0.returnedETag != nil }.map(\.path))
            return paths.filter { $0 != seriesId && $0 != nextEventId && store?.storedICS(path: $0) != nil }.sorted()
        }
    }

    /// The user deletes the split's new part.
    func deleteNewPart(googleReads: FakeGoogleCalendar.DeletedRead = .cancelled, calDAVReads: Int = 404) {
        switch kind {
        case .google:
            google?.userDeletes(GoogleCalendarProvider.deterministicSplitEventId(masterId: seriesId, recurrenceId: recurrenceId),
                                reads: googleReads)
        case .outlook:
            for id in newPartIds { graph?.userDeletes(id) }
        case .calDAV:
            for path in newPartIds { store?.userDeletes(path: path, reads: calDAVReads) }
        }
    }

    /// Whether the series now ends with the split's cap, just before the split.
    var seriesCapped: Bool {
        guard let tz = CalendarTimeZoneResolver.zone(named: zone, in: .none) else { return false }
        switch kind {
        case .google:
            guard let cap = GoogleCalendarProvider.googleUntilString(beforeNaiveISO: recurrenceId, allDay: false, zone: tz) else { return false }
            let rule = (google?.event(seriesId)?["recurrence"] as? [String])?.first { $0.uppercased().hasPrefix("RRULE:") }
            return rule?.uppercased().contains("UNTIL=\(cap)") == true
        case .outlook:
            let cap = ExchangeCalendarProvider.graphEndDateBefore(naiveISO: recurrenceId, allDay: false, zone: tz)
            let range = (graph?.event(seriesId)?["recurrence"] as? [String: Any])?["range"] as? [String: Any]
            return range?["type"] as? String == "endDate" && range?["endDate"] as? String == cap
        case .calDAV:
            guard let cap = GoogleCalendarProvider.googleUntilString(beforeNaiveISO: recurrenceId, allDay: false, zone: tz) else { return false }
            return store?.storedICS(path: seriesId)?.contains("UNTIL=\(cap)") == true
        }
    }

    /// The series' rule (Google and CalDAV) or range (Outlook), as text, to compare before and after.
    var seriesEnd: String {
        switch kind {
        case .google:
            return (google?.event(seriesId)?["recurrence"] as? [String])?.joined(separator: "\n") ?? "none"
        case .outlook:
            let range = (graph?.event(seriesId)?["recurrence"] as? [String: Any])?["range"] as? [String: Any] ?? [:]
            return range.keys.sorted().map { "\($0)=\(range[$0] ?? "")" }.joined(separator: ";")
        case .calDAV:
            return store?.storedICS(path: seriesId)?.split(separator: "\r\n").filter { $0.hasPrefix("RRULE") }.joined() ?? "none"
        }
    }

    /// Whether the one-off queued after the split was retitled.
    var nextWritten: Bool {
        switch kind {
        case .google: return google?.event(nextEventId)?["summary"] as? String == "Renamed"
        case .outlook: return graph?.event(nextEventId)?["subject"] as? String == "Renamed"
        case .calDAV: return store?.storedICS(path: nextEventId)?.contains("SUMMARY:Renamed") == true
        }
    }
}

/// Whether the split's record was on its row, each time a cap reached the calendar.
private final class KeptAtCap: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [Bool] = []
    func append(_ value: Bool) { lock.withLock { kept.append(value) } }
    var values: [Bool] { lock.withLock { kept } }
}

/// The split's row, as `drainSplit` hands it to `watch`, for a change between two drains.
private final class WatchedRow: @unchecked Sendable {
    private let lock = NSLock()
    private var pool: DatabasePool?
    private var id: String?
    func set(_ pool: DatabasePool, _ id: String) { lock.withLock { self.pool = pool; self.id = id } }

    /// The split's row now, or nil when it is gone or was not watched.
    var row: PendingCalendarOperation? {
        let (pool, id) = lock.withLock { (self.pool, self.id) }
        guard let pool, let id else { return nil }
        return (try? pool.read { db in try PendingCalendarOperation.fetchOne(db, key: id) }) ?? nil
    }

    /// When the row says the calendar first answered "not found" for the split's new part.
    var partNotFoundSince: Double? {
        guard let data = row?.argumentsJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (object[SplitRecord.partNotFoundSinceKey] as? NSNumber)?.doubleValue
    }

    /// Keeps on the row that the calendar first answered "not found" for the split's new part
    /// `seconds` ago, as the queue keeps it.
    func backdatePartNotFound(by seconds: TimeInterval) {
        let (pool, id) = lock.withLock { (self.pool, self.id) }
        guard let pool, let id else {
            Issue.record("the split's row was not watched")
            return
        }
        do {
            try pool.write { db in
                guard var row = try PendingCalendarOperation.fetchOne(db, key: id) else {
                    Issue.record("the split's row is gone")
                    return
                }
                var arguments = row.arguments
                arguments[SplitRecord.partNotFoundSinceKey] = .double(Date().addingTimeInterval(-seconds).timeIntervalSince1970)
                row.argumentsJSON = String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
                try row.update(db)
            }
        } catch {
            Issue.record("could not change the split's row: \(error)")
        }
    }
}

/// What a drain of a split left: its row (nil once it completed) and the next change's.
private struct SplitDrain {
    let split: PendingCalendarOperation?
    let next: PendingCalendarOperation?
}

/// The split `harness` names (`arguments`, by `eventId`) and, queued after it on the same account, a
/// retitle of the harness' one-off, drained `drains` times through the real queue on their own
/// database. `between` runs before every drain after the first: the user's change between two
/// attempts. `watch` gets the database and the split's row id before the first drain.
private func drainSplit(
    _ harness: SplitHarness, account: String, eventId: String? = nil, arguments: [String: JSONValue]? = nil,
    drains: Int, between: () -> Void = {}, watch: (DatabasePool, String) -> Void = { _, _ in }
) async throws -> SplitDrain {
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
    await AccountManager.shared.registerCalendarProviderForTesting(accountId: account, provider: harness.provider)
    defer {
        Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: account) }
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }

    let split = PendingCalendarOperation(
        operationType: .edit, accountId: account, eventId: eventId ?? harness.seriesId,
        calendarId: harness.calendarId, arguments: arguments ?? harness.arguments)
    var later = PendingCalendarOperation(
        operationType: .edit, accountId: account, eventId: harness.nextEventId,
        calendarId: harness.calendarId, arguments: ["title": .string("Renamed")])
    later.createdAt = split.createdAt.addingTimeInterval(1)
    let next = later
    try await pool.write { db in
        try split.insert(db)
        try next.insert(db)
    }
    watch(pool, split.id)

    for attempt in 0..<drains {
        if attempt > 0 { between() }
        await AccountManager.shared.drainCalendarQueue()
    }
    return try await pool.read { db in
        SplitDrain(split: try PendingCalendarOperation.fetchOne(db, key: split.id),
                   next: try PendingCalendarOperation.fetchOne(db, key: next.id))
    }
}

private func describe(_ row: PendingCalendarOperation?) -> String {
    row.map { "\($0.status) \($0.failureReason ?? "")" } ?? "gone"
}

@Suite("A split interrupted between its writes: never written again, finished or refused (#601)", .serialized, .processGlobalState)
struct SplitInterruptedBetweenItsWritesTests {

    @Test("T1: the cap fails, the user deletes the new part, the retry writes nothing and is refused; the next change drains",
          arguments: SplitHarness.Kind.allCases)
    func newPartDeletedBeforeTheRetry(_ kind: SplitHarness.Kind) async throws {
        let harness = SplitHarness(kind)
        harness.failCap()
        var writesBeforeDelete = 0
        let r = try await drainSplit(harness, account: "split-t1-\(kind)", drains: 2, between: {
            writesBeforeDelete = harness.splitWrites.count
            harness.deleteNewPart()
        })
        let after = Array(harness.splitWrites.dropFirst(writesBeforeDelete))
        #expect(after.isEmpty, "\(kind): the retry wrote after the new part was deleted: \(after)")
        #expect(r.split?.status == PendingStatus.failed.rawValue && r.split?.failureReason == newPartDeletedReason,
                "\(kind): the split was not refused with the ruled reason: \(describe(r.split))")
        #expect(r.next == nil && harness.nextWritten, "\(kind): the account's next change did not drain: \(describe(r.next))")
        #expect(!harness.seriesCapped, "\(kind): the series was capped with its new part gone")
    }

    @Test("T1: Google, a deleted new part read as cancelled, 404 or 410, refuses the same way",
          arguments: [FakeGoogleCalendar.DeletedRead.cancelled, .status(404), .status(410)])
    func googleDeletedPartEveryAnswer(_ reads: FakeGoogleCalendar.DeletedRead) async throws {
        let harness = SplitHarness(.google)
        harness.failCap()
        var writesBeforeDelete = 0
        let r = try await drainSplit(harness, account: "split-t1g-\(reads)", drains: 2, between: {
            writesBeforeDelete = harness.splitWrites.count
            harness.deleteNewPart(googleReads: reads)
        })
        #expect(harness.splitWrites.dropFirst(writesBeforeDelete).isEmpty, "wrote after the delete: \(harness.splitWrites)")
        #expect(r.split?.failureReason == newPartDeletedReason, "\(describe(r.split))")
        #expect(r.next == nil && harness.nextWritten, "the next change did not drain: \(describe(r.next))")
    }

    @Test("T1: CalDAV, a deleted new part read as 404 or 410, refuses the same way", arguments: [404, 410])
    func calDAVDeletedPartEveryAnswer(_ reads: Int) async throws {
        let harness = SplitHarness(.calDAV)
        harness.failCap()
        var writesBeforeDelete = 0
        let r = try await drainSplit(harness, account: "split-t1c-\(reads)", drains: 2, between: {
            writesBeforeDelete = harness.splitWrites.count
            harness.deleteNewPart(calDAVReads: reads)
        })
        #expect(harness.splitWrites.dropFirst(writesBeforeDelete).isEmpty, "wrote after the delete: \(harness.splitWrites)")
        #expect(r.split?.failureReason == newPartDeletedReason, "\(describe(r.split))")
        #expect(r.next == nil && harness.nextWritten, "the next change did not drain: \(describe(r.next))")
    }

    @Test("T2: the cap fails and the new part is intact: the retry writes only the cap and the split ends complete",
          arguments: SplitHarness.Kind.allCases)
    func capFailedPartIntact(_ kind: SplitHarness.Kind) async throws {
        let harness = SplitHarness(kind)
        harness.failCap()
        var writesBeforeRetry = 0
        let r = try await drainSplit(harness, account: "split-t2-\(kind)", drains: 2, between: {
            writesBeforeRetry = harness.splitWrites.count
        })
        let retry = Array(harness.splitWrites.dropFirst(writesBeforeRetry))
        #expect(r.split == nil, "\(kind): the split did not complete: \(describe(r.split))")
        #expect(harness.newPartIds.count == 1, "\(kind): not one new part: \(harness.newPartIds)")
        #expect(harness.seriesCapped, "\(kind): the series does not end before the split: \(harness.seriesEnd)")
        #expect(!retry.isEmpty && retry.allSatisfy(harness.isCap), "\(kind): the retry wrote more than the cap: \(retry)")
        #expect(r.next == nil && harness.nextWritten, "\(kind): the next change did not drain: \(describe(r.next))")
    }

    @Test("T2: a split onto another day whose cap fails is finished from its record: the new part keeps its turned rule with no excluded date, and the series is capped",
          arguments: [SplitHarness.Kind.google, .calDAV])
    func dayMoveSplitFinishedFromItsRecord(_ kind: SplitHarness.Kind) async throws {
        // A weekly series on its first day's weekday, its week-3 occurrence deleted, moved from the
        // week-2 occurrence on to the next day. The new part's rule turns to that day and the
        // excluded date goes (ruling (a)); the retry writes only the cap (`finishSplit`).
        let rule = GoogleSeries.onItsWeekday
        let harness = SplitHarness(kind, googleRule: rule, calDAVRule: rule)
        switch kind {
        case .google:
            var series = try #require(harness.google?.event(harness.seriesId))
            series["recurrence"] = [rule, "EXDATE:\(compact(day(14)))T090000Z"]
            harness.google?.store(series)
        case .calDAV:
            // In a named zone: a series in UTC with no TZID names none, and a move of its days is
            // refused (#679).
            harness.store?.seed(path: SplitHarness.calDAVSeriesPath, ics: calDAVSeries(
                uid: "ser-c", rule: "\(rule)\r\nEXDATE;TZID=Etc/UTC:\(compact(day(14)))T090000", tzid: "Etc/UTC"))
        case .outlook:
            Issue.record("Outlook keeps no excluded dates in its pattern; not a case of this test")
            return
        }
        harness.failCap()
        var arguments = harness.arguments
        arguments["start_iso"] = .string("\(day(8))T09:00:00")
        var writesBeforeRetry = 0
        let r = try await drainSplit(harness, account: "split-day-move-\(kind)", arguments: arguments, drains: 2, between: {
            writesBeforeRetry = harness.splitWrites.count
        })
        let retry = Array(harness.splitWrites.dropFirst(writesBeforeRetry))
        #expect(r.split == nil, "\(kind): the split did not complete: \(describe(r.split))")
        #expect(!retry.isEmpty && retry.allSatisfy(harness.isCap), "\(kind): the retry wrote more than the cap: \(retry)")
        #expect(harness.seriesCapped, "\(kind): the series does not end before the split: \(harness.seriesEnd)")
        let partId = try #require(harness.newPartIds.first, "\(kind): no new part: \(harness.splitWrites)")
        let lines: [String]
        switch kind {
        case .google: lines = harness.google?.event(partId)?["recurrence"] as? [String] ?? []
        default: lines = harness.store?.storedICS(path: partId)?.components(separatedBy: "\r\n") ?? []
        }
        #expect(lines.contains { $0.hasPrefix("RRULE:") && $0.contains("BYDAY=\(weekdayCode(day(8)))") },
                "\(kind): the new part's rule did not turn: \(lines)")
        #expect(!lines.contains { $0.uppercased().hasPrefix("EXDATE") }, "\(kind): an excluded date stays on the new part: \(lines)")
    }

    @Test("T2/T3: the cap's answer is lost, named by the series or by its occurrence: the split ends complete",
          arguments: [SplitHarness.Kind.google, .outlook], [false, true])
    func capAnswerLost(_ kind: SplitHarness.Kind, namedByOccurrence: Bool) async throws {
        let harness = SplitHarness(kind)
        let loseCap = try #require(harness.loseCap)
        loseCap()
        let named = namedByOccurrence ? try #require(harness.occurrenceId) : harness.seriesId
        let r = try await drainSplit(harness, account: "split-t3-\(kind)-\(namedByOccurrence)", eventId: named, drains: 2)
        #expect(r.split == nil, "\(kind) named \(named): the split did not complete: \(describe(r.split))")
        #expect(harness.newPartIds.count == 1, "\(kind): not one new part: \(harness.newPartIds)")
        #expect(harness.seriesCapped, "\(kind): the series does not end before the split: \(harness.seriesEnd)")
        #expect(harness.splitWrites.filter(harness.isCreate).count == 1, "\(kind): the new part was written again: \(harness.splitWrites)")
    }

    @Test("T4: Outlook, a numbered or end-dated series interrupted after its create keeps its end on the new part",
          arguments: ["numbered", "endDate"])
    func outlookNewPartKeepsTheSeriesEnd(_ type: String) async throws {
        let end = GraphFixture.utcDay(GraphFixture.start.addingTimeInterval(70 * 86_400))
        let range: [String: Any] = type == "numbered"
            ? ["type": "numbered", "numberOfOccurrences": 5]
            : ["type": "endDate", "endDate": end]
        let harness = SplitHarness(.outlook, graphRange: range)
        harness.failCap()
        let r = try await drainSplit(harness, account: "split-t4-\(type)", drains: 2)
        #expect(r.split == nil, "\(type): the split did not complete: \(describe(r.split))")
        let part = try #require(harness.graph?.created.first)
        let newRange = (part["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        #expect(newRange?["type"] as? String == type, "\(type): the new part's range is \(newRange ?? [:])")
        if type == "numbered" {
            // Every seventh day from the series' first: the first is before the split, four are left.
            #expect(newRange?["numberOfOccurrences"] as? Int == 4, "the count left is \(newRange ?? [:])")
        } else {
            #expect(newRange?["endDate"] as? String == end, "the original end is not kept: \(newRange ?? [:])")
        }
    }

    @Test("T5: a transient failure of the cap keeps the record on the requeued row", arguments: SplitHarness.Kind.allCases)
    func recordSurvivesTheRequeue(_ kind: SplitHarness.Kind) async throws {
        let harness = SplitHarness(kind)
        harness.failCap()
        let r = try await drainSplit(harness, account: "split-t5-\(kind)", drains: 1)
        let row = try #require(r.split)
        #expect(row.status == PendingStatus.queued.rawValue, "\(kind): \(describe(row))")
        let record = try #require(SplitRecord(row.arguments), "\(kind): the requeue erased the record: \(row.argumentsJSON)")
        #expect(record.seriesId == harness.seriesId && record.splitAt == harness.recurrenceId, "\(kind): \(record)")
        #expect(harness.newPartIds == [record.newPartId], "\(kind): the record names \(record.newPartId), the calendar holds \(harness.newPartIds)")
    }

    @Test("T6: the record is on the row when the cap reaches the calendar", arguments: SplitHarness.Kind.allCases)
    func recordIsKeptBeforeTheCap(_ kind: SplitHarness.Kind) async throws {
        let harness = SplitHarness(kind)
        let seen = KeptAtCap()
        let r = try await drainSplit(harness, account: "split-t6-\(kind)", drains: 1, watch: { pool, id in
            harness.onCap {
                let kept = (try? pool.read { db in try PendingCalendarOperation.fetchOne(db, key: id) })
                    .flatMap { $0 }.flatMap { SplitRecord($0.arguments) } != nil
                seen.append(kept)
            }
        })
        #expect(r.split == nil, "\(kind): \(describe(r.split))")
        #expect(seen.values == [true], "\(kind): the cap was sent before the record was kept: \(seen.values)")
    }

    @Test("T7: Google, the create's answer is lost and the user deletes the new part (read as cancelled): the retry is refused at once, with no cap and no wedge")
    func googleCreateAnswerLostThenDeleted() async throws {
        let harness = SplitHarness(.google)
        harness.google?.loseNextResponse("POST")
        let r = try await drainSplit(harness, account: "split-t7-cancelled", drains: 2, between: {
            harness.deleteNewPart(googleReads: .cancelled)
        })
        #expect(!harness.splitWrites.contains(where: harness.isCap), "the series was capped: \(harness.splitWrites)")
        #expect(harness.newPartIds.isEmpty, "the deleted new part was made again: \(harness.newPartIds)")
        #expect(r.split?.failureReason == newPartDeletedReason, "\(describe(r.split))")
        #expect(r.next == nil && harness.nextWritten, "the next change did not drain: \(describe(r.next))")
    }

    @Test("T7: Google, the create's answer is lost and the new part then reads as not found: within the grace the change stays queued, with no cap",
          arguments: [404, 410])
    func googleCreateAnswerLostThenNotFoundWithinTheGrace(_ code: Int) async throws {
        let harness = SplitHarness(.google)
        harness.google?.loseNextResponse("POST")
        let r = try await drainSplit(harness, account: "split-t7-grace-\(code)", drains: 2, between: {
            harness.deleteNewPart(googleReads: .status(code))
        })
        #expect(!harness.splitWrites.contains(where: harness.isCap), "the series was capped: \(harness.splitWrites)")
        #expect(harness.newPartIds.isEmpty, "the new part was made again: \(harness.newPartIds)")
        #expect(r.split?.status == PendingStatus.queued.rawValue,
                "a not-found answer just after Google said the id exists may be lag: the change stays queued. \(describe(r.split))")
    }

    @Test("T7: Google, the new part still reads as not found past the grace: the change is refused, with no cap, and the next change drains",
          arguments: [404, 410])
    func googleCreateAnswerLostThenNotFoundPastTheGrace(_ code: Int) async throws {
        let harness = SplitHarness(.google)
        harness.google?.loseNextResponse("POST")
        let watched = WatchedRow()
        let grace = TimeInterval(SyncConfig.splitPartNotFoundGraceMinutes * 60)
        let r = try await drainSplit(harness, account: "split-t7-past-\(code)", drains: 2, between: {
            harness.deleteNewPart(googleReads: .status(code))
            // The first not-found answer for this operation came longer ago than the grace.
            watched.backdatePartNotFound(by: grace + 60)
        }, watch: { pool, id in watched.set(pool, id) })
        #expect(!harness.splitWrites.contains(where: harness.isCap), "the series was capped: \(harness.splitWrites)")
        #expect(harness.newPartIds.isEmpty, "the new part was made again: \(harness.newPartIds)")
        #expect(r.split?.status == PendingStatus.failed.rawValue && r.split?.failureReason == newPartDeletedReason,
                "\(describe(r.split))")
        #expect(r.next == nil && harness.nextWritten, "the next change did not drain: \(describe(r.next))")
    }

    @Test("T7: Google, the first not-found answer is kept on the row, later ones within the grace do not move it, and once the grace has passed since it the change is refused")
    func googleFirstNotFoundIsKeptAndCounted() async throws {
        let harness = SplitHarness(.google)
        harness.google?.loseNextResponse("POST")
        let watched = WatchedRow()
        let grace = TimeInterval(SyncConfig.splitPartNotFoundGraceMinutes * 60)
        var statusAfterFirst: String?
        var sinceAfterFirst: Double?
        var statusAfterSecond: String?
        var sinceAfterSecond: Double?
        var drain = 0
        let between: () -> Void = {
            drain += 1
            if drain == 1 {
                // The create landed with its answer lost; the user deletes the new part.
                harness.deleteNewPart(googleReads: .status(404))
            } else if drain == 2 {
                // After the first drain that got a not-found answer, with no time kept before it.
                statusAfterFirst = watched.row?.status
                sinceAfterFirst = watched.partNotFoundSince
            } else {
                // After a second not-found answer within the grace; then the first one is moved
                // back past the grace.
                statusAfterSecond = watched.row?.status
                sinceAfterSecond = watched.partNotFoundSince
                watched.backdatePartNotFound(by: grace + 60)
            }
        }
        let watch: (DatabasePool, String) -> Void = { pool, id in watched.set(pool, id) }
        let r = try await drainSplit(harness, account: "split-t7-first", drains: 4, between: between, watch: watch)

        #expect(statusAfterFirst == PendingStatus.queued.rawValue, "the first not-found answer did not keep the row queued: \(statusAfterFirst ?? "gone")")
        let first = try #require(sinceAfterFirst, "the first not-found answer was not kept on the row")
        #expect(statusAfterSecond == PendingStatus.queued.rawValue, "a not-found answer within the grace did not keep the row queued: \(statusAfterSecond ?? "gone")")
        #expect(sinceAfterSecond == first,
                "a later not-found answer moved the first one's time, so the grace would never end: \(first) then \(String(describing: sinceAfterSecond))")
        #expect(r.split?.status == PendingStatus.failed.rawValue && r.split?.failureReason == newPartDeletedReason,
                "past the grace since the first not-found answer the change was not refused: \(describe(r.split))")
        #expect(!harness.seriesCapped && !harness.splitWrites.contains(where: harness.isCap),
                "the series was capped: \(harness.splitWrites)")
        #expect(harness.newPartIds.isEmpty, "the new part was made again: \(harness.newPartIds)")
        #expect(r.next == nil && harness.nextWritten, "the next change did not drain: \(describe(r.next))")
    }

    @Test("T8: Outlook writes the new part before the cap, and never again after a cap was sent")
    func outlookCreatesBeforeItCaps() async throws {
        let harness = SplitHarness(.outlook)
        harness.failCap()
        let r = try await drainSplit(harness, account: "split-t8", drains: 2)
        let writes = harness.splitWrites
        let firstCap = try #require(writes.firstIndex(where: harness.isCap), "no cap: \(writes)")
        #expect(writes.filter { $0 == "POST" }.count == 1, "\(writes)")
        #expect(!writes[firstCap...].contains("POST"), "a POST after a cap: \(writes)")
        #expect(r.split == nil, "\(describe(r.split))")
    }

    @Test("T10: finishing a split whose series already ends before it writes nothing and keeps the user's end",
          arguments: SplitHarness.Kind.allCases, ["until", "count"])
    func finishWritesNothingOnAnEndedSeries(_ kind: SplitHarness.Kind, end: String) async throws {
        let early = "\(compact(day(3)))T235959Z"
        let googleRule = end == "until" ? "RRULE:FREQ=WEEKLY;UNTIL=\(early)" : "RRULE:FREQ=WEEKLY;COUNT=1"
        let graphRange: [String: Any] = end == "until"
            ? ["type": "endDate", "endDate": GraphFixture.utcDay(GraphFixture.start.addingTimeInterval(2 * 86_400))]
            : ["type": "numbered", "numberOfOccurrences": 1]
        let harness = SplitHarness(kind, googleRule: googleRule, graphRange: graphRange, calDAVRule: googleRule)
        let before = harness.seriesEnd
        // The new part a first attempt made, and its record on the row.
        let partId: String
        switch kind {
        case .google:
            partId = GoogleCalendarProvider.deterministicSplitEventId(masterId: harness.seriesId, recurrenceId: harness.recurrenceId)
            var part = FakeGoogleCalendar.timed(id: partId, day: day(7))
            part["recurrence"] = ["RRULE:FREQ=WEEKLY"]
            harness.google?.store(part)
        case .outlook:
            partId = "part-1"
            harness.graph?.store(GraphFixture.event(id: partId, start: GraphFixture.occurrenceStart, online: false, recurring: true))
        case .calDAV:
            partId = "/cal/part-1.ics"
            harness.store?.seed(path: partId, ics: calDAVSeries(uid: "part-1", rule: "RRULE:FREQ=WEEKLY"))
        }
        var arguments = harness.arguments
        arguments[SplitRecord.argumentKey] = .dictionary(
            SplitRecord(seriesId: harness.seriesId, newPartId: partId, splitAt: harness.recurrenceId).jsonObject.mapValues { .string($0) })
        let r = try await drainSplit(harness, account: "split-t10-\(kind)-\(end)", arguments: arguments, drains: 1)
        #expect(r.split == nil, "\(kind) \(end): \(describe(r.split))")
        #expect(harness.splitWrites.isEmpty, "\(kind) \(end): wrote \(harness.splitWrites)")
        #expect(harness.seriesEnd == before, "\(kind) \(end): the series' end changed from \(before) to \(harness.seriesEnd)")
    }
}

@Suite("The split record is reserved for the queue (#601)", .serialized, .processGlobalState)
struct SplitRecordIsReservedTests {

    @Test("T9: a split record or first not-found time in a tool call's arguments is dropped when the change is queued")
    func forgedRecordIsDropped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir) }
        let account = "split-t9"
        try await pool.write { db in
            var acc = Account(emailAddress: "cal@example.com", displayName: "Cal", provider: .gmail)
            acc.id = account
            try acc.insert(db)
        }
        let forged = SplitRecord(seriesId: "ser-g", newPartId: "ser-g-forged", splitAt: "\(day(7))T09:00:00")
        let op = try await AccountManager.shared.queueCalendarOperation(
            type: .edit, accountId: account, eventId: "ser-g", calendarId: "primary",
            arguments: ["edit_scope": .string("this_and_following"), "recurrence_id": .string(forged.splitAt),
                        "title": .string("Retitled"),
                        SplitRecord.argumentKey: .dictionary(forged.jsonObject.mapValues { .string($0) }),
                        // A forged "first not found long ago" would refuse the split on its first
                        // not-found answer, with no grace.
                        SplitRecord.partNotFoundSinceKey: .double(Date().addingTimeInterval(-86_400).timeIntervalSince1970)])
        let stored = try #require(try await pool.read { db in try PendingCalendarOperation.fetchOne(db, key: op.id) })
        #expect(SplitRecord(stored.arguments) == nil, "the forged record was queued: \(stored.argumentsJSON)")
        #expect(stored.arguments[SplitRecord.partNotFoundSinceKey] == nil,
                "the forged first not-found time was queued: \(stored.argumentsJSON)")
        #expect(stored.arguments["title"] != nil, "the rest of the arguments were not kept: \(stored.argumentsJSON)")
    }

    @Test("A record round-trips through the stored arguments, and a partial one is no record")
    func recordRoundTrips() throws {
        let record = SplitRecord(seriesId: "ser", newPartId: "part", splitAt: "\(day(7))T09:00:00")
        let stored = PendingCalendarOperation(
            operationType: .edit, accountId: "a", eventId: "ser", calendarId: "primary",
            arguments: [SplitRecord.argumentKey: .dictionary(record.jsonObject.mapValues { .string($0) })])
        #expect(SplitRecord(stored.arguments) == record)
        var partial = record.jsonObject
        partial["new_part_id"] = nil
        #expect(SplitRecord([SplitRecord.argumentKey: .dictionary(partial.mapValues { .string($0) })]) == nil)
    }
}
