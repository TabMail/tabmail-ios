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

    @Test("T8: an all-day series moved to another date is still written as a plain date (UTC), and accepted")
    func allDaySeriesDateMoveUntouched() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = ZoneSeries.calendar(start: at(day(0), "00:00:00", in: Self.pacific), label: Self.vancouver,
                                        stored: Self.pacific, allDay: true)
        graph.install(on: http)
        var patch = GCalEventInput()
        patch.startDate = day(1)
        patch.endDate = day(2)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                session: http.session)
        _ = try await provider.updateEvent(eventId: ZoneSeries.id, event: patch)

        let sent = graph.patches(ZoneSeries.id).last
        #expect(sent?["isAllDay"] as? Bool == true, "the write is not all-day: \(canonical(sent))")
        #expect(canonical(sent?["start"]) == canonical(["dateTime": "\(day(1))T00:00:00", "timeZone": "UTC"]),
                "the all-day start is written \(canonical(sent?["start"]))")
        #expect(canonical(sent?["end"]) == canonical(["dateTime": "\(day(2))T00:00:00", "timeZone": "UTC"]),
                "the all-day end is written \(canonical(sent?["end"]))")
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
