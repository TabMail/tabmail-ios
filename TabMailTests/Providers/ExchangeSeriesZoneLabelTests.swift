/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// INVARIANT (system property, #719): a time written to an existing Outlook series is accepted, and
// once the queue has drained the calendar holds what the card said, whatever zone the device or the
// edit names. Exchange refuses a series PATCH whose start is labelled with a zone other than the one
// the series is kept in (measured 2026-11-11: `America/Vancouver`, whose rules no longer match
// `Pacific Standard Time` since British Columbia moved to UTC-7 all year, and `America/New_York`, each
// on a series kept in `Pacific Standard Time`: 400 `ErrorPropertyValidationFailure`;
// `FakeGraphCalendar.seriesStartZoneRefusal`). So every timed start and end the app writes to a series
// is labelled with the series' stored zone, as Graph names it, at the same instant. All dates are
// relative to today; the fixtures play a device in each zone through the labels Graph returns.
// An all-day series' dates are labelled the same way (#747, `ExchangeAllDaySeriesLengthTests` below).

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

private func zone(_ name: String) -> TimeZone { CalendarTimeZoneResolver.zone(named: name, in: .none)! }

/// `day` at the wall time `time` (`HH:mm:ss`) in `zoneName`.
private func at(_ day: String, _ time: String, in zoneName: String) -> Date {
    EKEventStoreHelper.parseNaiveISO("\(day)T\(time)", timeZone: zone(zoneName))!
}

/// `date`'s wall time in `zoneName`, `yyyy-MM-ddTHH:mm:ss`.
private func wall(_ date: Date, in zoneName: String) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.calendar = Calendar(identifier: .gregorian)
    fmt.timeZone = zone(zoneName)
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return fmt.string(from: date)
}

/// The instant a stored or written Graph start or end names: its wall time read in its label.
private func instant(_ value: Any?) -> Date? {
    guard let side = value as? [String: Any], let dateTime = side["dateTime"] as? String,
          let label = side["timeZone"] as? String,
          let tz = CalendarTimeZoneResolver.zone(named: label, in: .none) else { return nil }
    return EKEventStoreHelper.parseNaiveISO(String(dateTime.prefix(19)), timeZone: tz)
}

private func label(_ value: Any?) -> String? { (value as? [String: Any])?["timeZone"] as? String }

private func rangeOf(_ event: [String: Any]?) -> [String: Any]? {
    (event?["recurrence"] as? [String: Any])?["range"] as? [String: Any]
}

private func reasons(_ rows: [PendingCalendarOperation]) -> [String] { rows.map { "\($0.status) \($0.failureReason ?? "")" } }

private func canonical(_ value: Any?) -> String {
    guard let value, JSONSerialization.isValidJSONObject([value]),
          let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
    else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

/// A weekly series of five occurrences ending on a date, its start and end labelled with the zone a
/// read names (`label`: Graph renders a timed series in the zone `Prefer` asks for, the device's),
/// kept in `stored` (its range's `recurrenceTimeZone`, as Graph names it), the range dated in it.
private enum ZoneSeries {
    static let id = "zs-1"
    static func occurrenceId(_ week: Int) -> String { "zs-1-occ-w\(week)" }

    /// The first occurrence's start `week` weeks on, by the calendar in `stored`.
    static func place(_ start: Date, week: Int, stored: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone(stored)
        return cal.date(byAdding: .day, value: 7 * week, to: start)!
    }

    static func calendar(start: Date, label: String, stored: String, allDay: Bool = false) -> FakeGraphCalendar {
        func dated(_ e: inout [String: Any], _ at: Date) {
            if allDay {
                let date = String(wall(at, in: stored).prefix(10))
                let next = String(wall(at.addingTimeInterval(86_400), in: stored).prefix(10))
                e["start"] = ["dateTime": date + "T00:00:00.0000000", "timeZone": label]
                e["end"] = ["dateTime": next + "T00:00:00.0000000", "timeZone": label]
                e["isAllDay"] = true
            } else {
                e["start"] = ["dateTime": wall(at, in: label) + ".0000000", "timeZone": label]
                e["end"] = ["dateTime": wall(at.addingTimeInterval(3_600), in: label) + ".0000000", "timeZone": label]
                e["isAllDay"] = false
            }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone(stored)
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        var series = GraphFixture.event(id: id, start: start, online: false, recurring: true)
        dated(&series, start)
        series["recurrence"] = [
            "pattern": ["type": "weekly", "interval": 1, "month": 0, "dayOfMonth": 0,
                        "daysOfWeek": [names[cal.component(.weekday, from: start) - 1]],
                        "firstDayOfWeek": "monday", "index": "first"],
            "range": ["type": "endDate", "startDate": String(wall(start, in: stored).prefix(10)),
                      "endDate": String(wall(place(start, week: 4, stored: stored), in: stored).prefix(10)),
                      "recurrenceTimeZone": stored, "numberOfOccurrences": 0],
        ]
        let occurrences = (0...4).map { week -> [String: Any] in
            let at = place(start, week: week, stored: stored)
            var e = GraphFixture.event(id: occurrenceId(week), start: at, online: false, seriesMasterId: id)
            dated(&e, at)
            e["originalStart"] = at.iso8601String(timeZone: zone(stored))
            return e
        }
        return FakeGraphCalendar([series] + occurrences)
    }

    /// A zone Graph keeps a series in whose rules are not the device's: `Pacific Standard Time`,
    /// or `Eastern Standard Time` on a device in Pacific time.
    static var storedOtherThanDevice: String {
        let device = zone(TimeZone.current.identifier).identifier
        return zone("Pacific Standard Time").identifier == device ? "Eastern Standard Time" : "Pacific Standard Time"
    }

    /// An instant on `day` in both `stored` and the device's zone: noon in `stored`, less half the
    /// device's offset from it (whole quarter hours), so the wall time is between about 01:00 and
    /// 23:00 in each at any device offset.
    static func sameDay(_ day: String, stored: String) -> Date {
        let noon = at(day, "12:00:00", in: stored)
        let diff = TimeZone.current.secondsFromGMT(for: noon) - zone(stored).secondsFromGMT(for: noon)
        return noon.addingTimeInterval(-Double(diff / 2 / 900 * 900))
    }
}

private func outlook(_ graph: FakeGraphCalendar, eventId: String = ZoneSeries.id, _ arguments: [String: JSONValue],
                     account: String) async throws -> [PendingCalendarOperation] {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    graph.install(on: http)
    let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                            session: http.session)
    return try await drainEdit(accountId: account, eventId: eventId, calendarId: "primary",
                               arguments: arguments, provider: provider)
}

@Suite("Times written to an Outlook series carry the series' own zone (#719)", .serialized, .processGlobalState)
struct ExchangeSeriesZoneLabelTests {

    static let vancouver = "America/Vancouver"
    static let pacific = "Pacific Standard Time"

    /// The series at 10:00 in Vancouver two weeks from today, read on a Vancouver device, kept in
    /// Pacific Standard Time (as every series made in British Columbia before 2026-11-01 is).
    static var vancouverStart: Date { at(day(0), "10:00:00", in: vancouver) }

    @Test("T1: a time change of every occurrence from a Vancouver device is written in the series' zone at the card's instant")
    func allFromVancouver() async throws {
        let graph = ZoneSeries.calendar(start: Self.vancouverStart, label: Self.vancouver, stored: Self.pacific)
        let rows = try await outlook(graph, [
            "edit_scope": .string("all"), "start_iso": .string("\(day(0))T12:00:00"),
            "end_iso": .string("\(day(0))T13:00:00"), "timezone": .string(Self.vancouver),
        ], account: "zone-719-t1")

        #expect(rows.isEmpty, "the edit was not written: \(reasons(rows))")
        let series = graph.event(ZoneSeries.id)
        #expect(instant(series?["start"]) == at(day(0), "12:00:00", in: Self.vancouver),
                "the series starts \(canonical(series?["start"])), the card said 12:00 in Vancouver")
        #expect(instant(series?["end"]) == at(day(0), "13:00:00", in: Self.vancouver),
                "the series ends \(canonical(series?["end"]))")
        #expect(rangeOf(series)?["recurrenceTimeZone"] as? String == Self.pacific, "the series' zone changed: \(canonical(rangeOf(series)))")
        let sent = graph.patches(ZoneSeries.id).last
        #expect(label(sent?["start"]) == Self.pacific && label(sent?["end"]) == Self.pacific,
                "the write is labelled \(canonical(sent?["start"])) to \(canonical(sent?["end"])), not the series' zone")
    }

    @Test("T2: a change of an occurrence and the following ones is written in the series' zone, no occurrence lost or doubled")
    func thisAndFollowingFromTheDevice() async throws {
        let stored = ZoneSeries.storedOtherThanDevice
        let device = TimeZone.current.identifier
        let start = ZoneSeries.sameDay(day(0), stored: stored)
        let graph = ZoneSeries.calendar(start: start, label: device, stored: stored)
        let before = try #require(graph.event(ZoneSeries.id))
        let days = try #require(FakeGraphCalendar.rangeDays(before))
        let split = ZoneSeries.place(start, week: 1, stored: stored)
        let newStart = split.addingTimeInterval(-3_600)
        let rows = try await outlook(graph, [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string(wall(split, in: device)),
            "start_iso": .string(wall(newStart, in: device)), "end_iso": .string(wall(split, in: device)),
            "timezone": .string(device),
        ], account: "zone-719-t2")

        let what = "series kept in \(stored), device \(device)"
        #expect(rows.isEmpty, "\(what): the split was not written: \(reasons(rows))")
        #expect(graph.created.count == 1, "\(what): \(graph.created.count) new parts")
        guard graph.created.count == 1 else { return }
        let created = graph.created[0]
        #expect(instant(created["start"]) == newStart, "\(what): the new part starts \(canonical(created["start"]))")
        #expect(label(created["start"]) == stored && label(created["end"]) == stored,
                "\(what): the new part is labelled \(canonical(created["start"])), not the series' zone")
        let series = graph.event(ZoneSeries.id)
        #expect(instant(series?["start"]) == start, "\(what): the series moved: \(canonical(series?["start"]))")
        let cap = graph.patches(ZoneSeries.id).first
        #expect(label(cap?["start"]) == stored, "\(what): the cap is labelled \(canonical(cap?["start"]))")
        let kept = series.flatMap(FakeGraphCalendar.rangeDays) ?? []
        let following = FakeGraphCalendar.rangeDays(created) ?? []
        #expect(kept + following == days, "\(what): the series holds \(kept), the new part \(following), the series held \(days)")
    }

    @Test("T3: a time change of every occurrence named in another zone keeps the series' zone, at the card's instant")
    func allNamedInNewYork() async throws {
        let graph = ZoneSeries.calendar(start: Self.vancouverStart, label: Self.vancouver, stored: Self.pacific)
        let newYork = "America/New_York"
        let rows = try await outlook(graph, [
            "edit_scope": .string("all"), "start_iso": .string("\(day(0))T15:00:00"),
            "end_iso": .string("\(day(0))T16:00:00"), "timezone": .string(newYork),
        ], account: "zone-719-t3")

        #expect(rows.isEmpty, "the edit was not written: \(reasons(rows))")
        let series = graph.event(ZoneSeries.id)
        #expect(instant(series?["start"]) == at(day(0), "15:00:00", in: newYork),
                "the series starts \(canonical(series?["start"])), the card said 15:00 in New York")
        #expect(label(series?["start"]) == Self.pacific, "the series was re-zoned: \(canonical(series?["start"]))")
        #expect(rangeOf(series)?["recurrenceTimeZone"] as? String == Self.pacific, "the series' zone changed")
    }

    @Test("T4: a rename from a Vancouver device sends no start and resets nothing")
    func renameSendsNoStart() async throws {
        let graph = ZoneSeries.calendar(start: Self.vancouverStart, label: Self.vancouver, stored: Self.pacific)
        let rows = try await outlook(graph, [
            "edit_scope": .string("all"), "title": .string("Renamed"), "timezone": .string(Self.vancouver),
        ], account: "zone-719-t4")

        #expect(rows.isEmpty, "the rename was not written: \(reasons(rows))")
        let sent = graph.patches(ZoneSeries.id)
        #expect(sent.count == 1 && sent.first?["start"] == nil && sent.first?["end"] == nil,
                "the rename sent \(sent.map { canonical($0["start"]) })")
        #expect(graph.seriesResets == 0, "the rename reset the series' changed occurrences")
        #expect(graph.event(ZoneSeries.id)?["subject"] as? String == "Renamed", "the series was not renamed")
    }

    @Test("T5: the series' own instant under another zone's name is no move: no start sent, nothing reset")
    func sameInstantOtherLabelIsNoMove() async throws {
        let graph = ZoneSeries.calendar(start: Self.vancouverStart, label: Self.vancouver, stored: Self.pacific)
        let losAngeles = "America/Los_Angeles"
        let rows = try await outlook(graph, [
            "edit_scope": .string("all"), "title": .string("Renamed"),
            "start_iso": .string(wall(Self.vancouverStart, in: losAngeles)),
            "end_iso": .string(wall(Self.vancouverStart.addingTimeInterval(3_600), in: losAngeles)),
            "timezone": .string(losAngeles),
        ], account: "zone-719-t5")

        #expect(rows.isEmpty, "the edit was not written: \(reasons(rows))")
        let sent = graph.patches(ZoneSeries.id)
        #expect(sent.allSatisfy { $0["start"] == nil && $0["end"] == nil }, "a start was sent: \(sent.map { canonical($0["start"]) })")
        #expect(graph.seriesResets == 0, "the series' changed occurrences were reset")
    }

    @Test("T6: a series kept in a zone TabMail does not recognize keeps today's label on a time move (#746)")
    func unrecognizedStoredZoneKeepsTodaysLabel() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let custom = "Customized Time Zone"
        #expect(CalendarTimeZoneResolver.zone(named: custom, in: .none) == nil, "non-vacuity: the zone is not recognized")
        // Read in Vancouver, kept in the zone TabMail does not know; its range dated as Pacific.
        let graph = ZoneSeries.calendar(start: Self.vancouverStart, label: Self.vancouver, stored: Self.pacific)
        var series = try #require(graph.event(ZoneSeries.id))
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        range["recurrenceTimeZone"] = custom
        recurrence["range"] = range
        series["recurrence"] = recurrence
        let customGraph = FakeGraphCalendar([series])
        customGraph.install(on: http)
        var patch = GCalEventInput()
        let newStart = at(day(0), "12:00:00", in: Self.vancouver)
        patch.startDateTime = newStart.iso8601String(timeZone: zone(Self.vancouver))
        patch.startTimeZone = Self.vancouver
        patch.endDateTime = newStart.addingTimeInterval(3_600).iso8601String(timeZone: zone(Self.vancouver))
        patch.endTimeZone = Self.vancouver
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                session: http.session)
        _ = try await provider.updateEvent(eventId: ZoneSeries.id, event: patch)

        let sent = customGraph.patches(ZoneSeries.id).last
        #expect(label(sent?["start"]) == Self.vancouver && label(sent?["end"]) == Self.vancouver,
                "the write is labelled \(canonical(sent?["start"]))")
        #expect(instant(sent?["start"]) == newStart, "the write starts \(canonical(sent?["start"]))")
    }

    @Test("T7: a series read in Los Angeles and kept in Pacific Standard Time is written under the stored name, same instant")
    func losAngelesControl() async throws {
        let losAngeles = "America/Los_Angeles"
        let start = at(day(0), "10:00:00", in: losAngeles)
        let graph = ZoneSeries.calendar(start: start, label: losAngeles, stored: Self.pacific)
        let rows = try await outlook(graph, [
            "edit_scope": .string("all"), "start_iso": .string("\(day(0))T12:00:00"),
            "end_iso": .string("\(day(0))T13:00:00"), "timezone": .string(losAngeles),
        ], account: "zone-719-t7")

        #expect(rows.isEmpty, "the edit was not written: \(reasons(rows))")
        let series = graph.event(ZoneSeries.id)
        #expect(instant(series?["start"]) == at(day(0), "12:00:00", in: losAngeles), "the series starts \(canonical(series?["start"]))")
        let sent = graph.patches(ZoneSeries.id).last
        #expect(label(sent?["start"]) == Self.pacific && label(sent?["end"]) == Self.pacific,
                "the write is labelled \(canonical(sent?["start"])) to \(canonical(sent?["end"])), not the series' stored name")
    }

    @Test("T10: a split whose new part fails puts the series back as it was, through a revert the server accepts")
    func splitWhoseCreateFailsIsReverted() async throws {
        let stored = ZoneSeries.storedOtherThanDevice
        let device = TimeZone.current.identifier
        let start = ZoneSeries.sameDay(day(0), stored: stored)
        let graph = ZoneSeries.calendar(start: start, label: device, stored: stored)
        let before = try #require(graph.event(ZoneSeries.id))
        let split = ZoneSeries.place(start, week: 1, stored: stored)
        graph.failNext("POST", with: 500)
        _ = try await outlook(graph, [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string(wall(split, in: device)),
            "start_iso": .string(wall(split.addingTimeInterval(-3_600), in: device)),
            "end_iso": .string(wall(split, in: device)), "timezone": .string(device),
        ], account: "zone-719-t10")

        let what = "series kept in \(stored), device \(device)"
        let sent = graph.patches(ZoneSeries.id)
        #expect(sent.count == 2, "\(what): \(sent.count) series writes, not a cap and its revert")
        #expect(sent.allSatisfy { label($0["start"]) == stored }, "\(what): labelled \(sent.map { canonical($0["start"]) })")
        let after = graph.event(ZoneSeries.id)
        #expect(canonical(after?["recurrence"]) == canonical(before["recurrence"]),
                "\(what): the series' recurrence is \(canonical(after?["recurrence"]))")
        #expect(instant(after?["start"]) == start, "\(what): the series moved: \(canonical(after?["start"]))")
        #expect(graph.created.isEmpty, "\(what): a new part was stored")
    }
}

/// The length of an all-day start and end (`{dateTime, timeZone}`), in whole days of their dates.
private func days(_ start: Any?, _ end: Any?) -> Int? {
    func date(_ side: Any?) -> Date? {
        ((side as? [String: Any])?["dateTime"] as? String).flatMap {
            EKEventStoreHelper.parseNaiveISO(String($0.prefix(10)) + "T00:00:00", timeZone: utc)
        }
    }
    guard let from = date(start), let to = date(end) else { return nil }
    return Int((to.timeIntervalSince(from) / 86_400).rounded())
}

private func dateOf(_ side: Any?) -> String? { ((side as? [String: Any])?["dateTime"] as? String).map { String($0.prefix(10)) } }

// INVARIANT (system property, #747): an edit of an existing Outlook all-day series keeps every
// occurrence the length the series has, or the length the edit asks for, and keeps the series'
// zone. Graph stores an all-day series whose start and end are written labelled with a zone other
// than its range's `recurrenceTimeZone` with every occurrence two days longer (measured 2026-11-11;
// `FakeGraphCalendar.allDaySeriesLengthened`), so the app writes them labelled with the stored zone,
// on the same dates. The series is read as Graph reads it with no `Prefer`: start and end labelled
// `UTC`, the range kept in the series' zone.
@Suite("An all-day Outlook series keeps its occurrences' length when edited (#747)", .serialized, .processGlobalState)
struct ExchangeAllDaySeriesLengthTests {
    static let zones = ["Pacific Standard Time", "Tokyo Standard Time", "America/Los_Angeles"]

    static func series(kept stored: String) -> FakeGraphCalendar {
        ZoneSeries.calendar(start: at(day(0), "00:00:00", in: stored), label: "UTC", stored: stored, allDay: true)
    }

    @Test("a whole-series move to another date lands there, one day long, in the series' zone", arguments: zones)
    func moveKeepsTheLength(_ stored: String) async throws {
        // The provider's whole-series write, as the issue's start-only date move reaches it (the
        // queue asks first when the new date is not the first occurrence's).
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = Self.series(kept: stored)
        graph.install(on: http)
        var patch = GCalEventInput()
        patch.startDate = day(1)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                session: http.session)
        _ = try await provider.updateEvent(eventId: ZoneSeries.id, event: patch)

        let series = graph.event(ZoneSeries.id)
        #expect(dateOf(series?["start"]) == day(1), "\(stored): the series starts \(canonical(series?["start"]))")
        #expect(days(series?["start"], series?["end"]) == 1,
                "\(stored): each occurrence is \(days(series?["start"], series?["end"]).map(String.init) ?? "?") days long, the series' was 1")
        #expect(rangeOf(series)?["recurrenceTimeZone"] as? String == stored, "\(stored): the series' zone is \(canonical(rangeOf(series)))")
        #expect(rangeOf(series)?["startDate"] as? String == day(1), "\(stored): the range starts \(canonical(rangeOf(series)))")
    }

    @Test("a length edit of every occurrence stores exactly the length asked", arguments: zones)
    func lengthEditKeepsTheAskedLength(_ stored: String) async throws {
        let graph = Self.series(kept: stored)
        let rows = try await outlook(graph, [
            "edit_scope": .string("all"), "start_iso": .string(day(0)), "end_iso": .string(day(2)), "all_day": .bool(true),
        ], account: "allday-747-length-\(stored)")

        #expect(rows.isEmpty, "\(stored): the edit was not written: \(reasons(rows))")
        let series = graph.event(ZoneSeries.id)
        #expect(dateOf(series?["start"]) == day(0), "\(stored): the series starts \(canonical(series?["start"]))")
        #expect(days(series?["start"], series?["end"]) == 2,
                "\(stored): each occurrence is \(days(series?["start"], series?["end"]).map(String.init) ?? "?") days long, the edit asked 2")
        #expect(rangeOf(series)?["recurrenceTimeZone"] as? String == stored, "\(stored): the series' zone is \(canonical(rangeOf(series)))")
    }

    @Test("a change of an occurrence and the following ones keeps both parts' length", arguments: zones)
    func splitKeepsTheLength(_ stored: String) async throws {
        let graph = Self.series(kept: stored)
        let rows = try await outlook(graph, [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(7))T00:00:00"),
            "title": .string("Renamed"), "all_day": .bool(true),
        ], account: "allday-747-split-\(stored)")

        #expect(rows.isEmpty, "\(stored): the split was not written: \(reasons(rows))")
        #expect(graph.created.count == 1, "\(stored): \(graph.created.count) new parts")
        guard graph.created.count == 1 else { return }
        let created = graph.created[0]
        #expect(dateOf(created["start"]) == day(7), "\(stored): the new part starts \(canonical(created["start"]))")
        #expect(days(created["start"], created["end"]) == 1,
                "\(stored): each new occurrence is \(days(created["start"], created["end"]).map(String.init) ?? "?") days long, the series' was 1")
        #expect(rangeOf(created)?["recurrenceTimeZone"] as? String == stored, "\(stored): the new part's zone is \(canonical(rangeOf(created)))")
        let series = graph.event(ZoneSeries.id)
        #expect(dateOf(series?["start"]) == day(0) && days(series?["start"], series?["end"]) == 1,
                "\(stored): the capped series is \(canonical(series?["start"])) to \(canonical(series?["end"]))")
    }
}

// INVARIANT (system property, #719 review): a series' start and its range's `startDate` name the
// same day, in the series' zone, and a move writes a new `startDate` exactly when that day changes.
// The series is kept far from the device (`Tokyo Standard Time`; Graph renders its times in the
// device's zone on a read), so its day and the device's differ across most of the day. Not modelled
// by the fake (unmeasured what Graph does with a mismatch), so asserted on the written body.
@Suite("An Outlook series' start and range start name the same day in the series' zone (#719)", .serialized, .processGlobalState)
struct ExchangeSeriesDayTests {
    static let tokyo = "Tokyo Standard Time"
    static var device: String { TimeZone.current.identifier }
    static func dayIn(_ date: Date, _ zoneName: String) -> String { String(wall(date, in: zoneName).prefix(10)) }

    /// Each pair (series start, new start) as Tokyo wall times on `day(0)`/`day(1)`.
    static let intoTheNextSeriesDay = (at(day(0), "20:00:00", in: "Asia/Tokyo"), at(day(1), "08:00:00", in: "Asia/Tokyo"))
    static let intoTheNextDeviceDay = (at(day(0), "08:00:00", in: "Asia/Tokyo"), at(day(0), "20:00:00", in: "Asia/Tokyo"))
    static var seriesDayOnlyCrosses: Bool {
        dayIn(intoTheNextSeriesDay.0, device) == dayIn(intoTheNextSeriesDay.1, device)
    }
    static var deviceDayOnlyCrosses: Bool {
        dayIn(intoTheNextDeviceDay.0, device) != dayIn(intoTheNextDeviceDay.1, device)
    }
    static var deviceDayIsNotTokyos: Bool {
        dayIn(intoTheNextDeviceDay.0, device) != dayIn(intoTheNextDeviceDay.0, "Asia/Tokyo")
    }

    func move(_ graph: FakeGraphCalendar, to newStart: Date) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        var patch = GCalEventInput()
        patch.startDateTime = newStart.iso8601String(timeZone: zone("Asia/Tokyo"))
        patch.startTimeZone = "Asia/Tokyo"
        patch.endDateTime = newStart.addingTimeInterval(3_600).iso8601String(timeZone: zone("Asia/Tokyo"))
        patch.endTimeZone = "Asia/Tokyo"
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                session: http.session)
        _ = try await provider.updateEvent(eventId: ZoneSeries.id, event: patch)
    }

    @Test("a move into the next day in the series' zone, the same day on the device, writes the range start on the series' new day",
          .enabled(if: seriesDayOnlyCrosses))
    func moveCrossesTheSeriesDayOnly() async throws {
        let (from, to) = Self.intoTheNextSeriesDay
        let graph = ZoneSeries.calendar(start: from, label: Self.device, stored: Self.tokyo)
        try await move(graph, to: to)

        let sent = graph.patches(ZoneSeries.id).last
        let range = (sent?["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        #expect(range?["startDate"] as? String == Self.dayIn(to, "Asia/Tokyo"),
                "the series moved to \(Self.dayIn(to, "Asia/Tokyo")) in its zone; the write's range: \(canonical(range))")
        #expect(range?["startDate"] as? String == dateOf(sent?["start"]),
                "the range starts \(range?["startDate"] as? String ?? "none"), the start \(canonical(sent?["start"]))")
        #expect(label(sent?["start"]) == Self.tokyo && label(sent?["end"]) == Self.tokyo,
                "the write is labelled \(canonical(sent?["start"])) to \(canonical(sent?["end"]))")
    }

    @Test("a move into the next day on the device, the same day in the series' zone, writes no recurrence",
          .enabled(if: deviceDayOnlyCrosses))
    func moveCrossesTheDeviceDayOnly() async throws {
        let (from, to) = Self.intoTheNextDeviceDay
        let graph = ZoneSeries.calendar(start: from, label: Self.device, stored: Self.tokyo)
        try await move(graph, to: to)

        let sent = graph.patches(ZoneSeries.id)
        #expect(sent.count == 1 && sent.allSatisfy { $0["recurrence"] == nil },
                "the series stays on its day in its zone, yet the write carried \(sent.map { canonical($0["recurrence"]) })")
        #expect(dateOf(sent.last?["start"]) == Self.dayIn(from, "Asia/Tokyo"), "the start is written \(canonical(sent.last?["start"]))")
        #expect(instant(graph.event(ZoneSeries.id)?["start"]) == to, "the series starts \(canonical(graph.event(ZoneSeries.id)?["start"]))")
    }

    @Test("a split's new part, renamed or moved within the series' day across the device's midnight, starts its range on its start's day",
          .enabled(if: deviceDayIsNotTokyos), arguments: [false, true])
    func splitRangeStartsOnTheStartsDay(_ moved: Bool) async throws {
        // Weekly from day(0) at 20:00 Tokyo, or 08:00 for the rename; split at the second occurrence.
        let first = moved ? Self.intoTheNextDeviceDay.1 : Self.intoTheNextDeviceDay.0
        let graph = ZoneSeries.calendar(start: first, label: Self.device, stored: Self.tokyo)
        let split = ZoneSeries.place(first, week: 1, stored: Self.tokyo)
        let newStart = moved ? split.addingTimeInterval(-12 * 3_600) : split
        var arguments: [String: JSONValue] = [
            "edit_scope": .string("this_and_following"), "recurrence_id": .string(wall(split, in: Self.device)),
            "title": .string("Renamed"), "timezone": .string(Self.device),
        ]
        if moved {
            arguments["start_iso"] = .string(wall(newStart, in: Self.device))
            arguments["end_iso"] = .string(wall(newStart.addingTimeInterval(3_600), in: Self.device))
        }
        let rows = try await outlook(graph, arguments, account: "seriesday-split-\(moved)")

        #expect(rows.isEmpty, "the split was not written: \(reasons(rows))")
        #expect(graph.created.count == 1, "\(graph.created.count) new parts")
        guard graph.created.count == 1 else { return }
        let created = graph.created[0]
        #expect(instant(created["start"]) == newStart, "the new part starts \(canonical(created["start"]))")
        #expect(rangeOf(created)?["startDate"] as? String == dateOf(created["start"]),
                "the new part's range starts \(canonical(rangeOf(created))), its start \(canonical(created["start"]))")
        #expect(rangeOf(created)?["startDate"] as? String == Self.dayIn(newStart, "Asia/Tokyo"),
                "the new part's range starts \(canonical(rangeOf(created))), on \(Self.dayIn(newStart, "Asia/Tokyo")) in the series' zone")
        #expect(label(created["end"]) == Self.tokyo, "the new part's end is labelled \(canonical(created["end"]))")
    }
}
