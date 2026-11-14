/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// INVARIANT (system property, #681): a change of an Outlook occurrence and the following ones
// splits the series at that occurrence, whatever zone the device or the edit is in: read in the
// series' own zone, every occurrence before the split stays on the old part only, and the split
// occurrence and every later one are on the new part only. Graph reads a range's `startDate` and
// `endDate` as dates in its `recurrenceTimeZone`, whatever `Prefer` names (measured 2026-11-11), and
// applies the pattern from `startDate` (`FakeGraphCalendar.rangeDays`). So the series is asserted as
// the fake holds it, never as the request was built. All dates are relative to today.

private func zone(_ name: String) -> TimeZone { CalendarTimeZoneResolver.zone(named: name, in: .none)! }

/// The UTC date `offset` days after the day two weeks from today, as `yyyy-MM-dd`.
private func day(_ offset: Int) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone("UTC")
    let base = cal.startOfDay(for: Date().addingTimeInterval(14 * 86_400))
    return String(GraphFixture.naive(cal.date(byAdding: .day, value: offset, to: base)!).prefix(10))
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

private func dayIn(_ date: Date, _ zoneName: String) -> String { String(wall(date, in: zoneName).prefix(10)) }

private func canonical(_ value: Any?) -> String {
    guard let value, JSONSerialization.isValidJSONObject([value]),
          let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
    else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

private func rangeOf(_ event: [String: Any]?) -> [String: Any]? {
    (event?["recurrence"] as? [String: Any])?["range"] as? [String: Any]
}

/// A series of five occurrences, weekly on its first day or daily, kept in `stored` (its range's
/// `recurrenceTimeZone`, the range dated there and ending on the last occurrence's day); its
/// occurrences read as Graph renders them for a device in `device`.
struct CrossZoneSeries: CustomTestStringConvertible, Sendable {
    let name: String
    let stored: String
    let device: String
    let daily: Bool
    /// The first occurrence's wall time in `stored`, `HH:mm:ss`.
    let time: String

    var testDescription: String { name }
    static let id = "cz-1"

    var start: Date { EKEventStoreHelper.parseNaiveISO("\(day(0))T\(time)", timeZone: zone(stored))! }

    /// The `index`-th occurrence's start, by the calendar in `stored`.
    func place(_ index: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone(stored)
        return cal.date(byAdding: .day, value: (daily ? 1 : 7) * index, to: start)!
    }

    /// The occurrence the split names.
    var split: Date { place(2) }

    /// The series' start and end are stored labelled with its own zone, as the app writes them
    /// since #719, so the fake returns them in the zone `Prefer` names (the test process's).
    /// `storedName` replaces the name the range gives the zone. `eventZone` names the series' zone
    /// as the event's own (`originalStartTimeZone`) instead, with a range that names none.
    /// `alsoEventZone` keeps the range's zone and gives the event another one of its own.
    func calendar(storedName: String? = nil, eventZone: String? = nil, alsoEventZone: String? = nil) -> FakeGraphCalendar {
        func dated(_ e: inout [String: Any], _ at: Date, in label: String) {
            e["start"] = ["dateTime": wall(at, in: label) + ".0000000", "timeZone": label]
            e["end"] = ["dateTime": wall(at.addingTimeInterval(3_600), in: label) + ".0000000", "timeZone": label]
            e["isAllDay"] = false
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone(stored)
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        var series = GraphFixture.event(id: Self.id, start: start, online: false, recurring: true)
        dated(&series, start, in: stored)
        series["recurrence"] = [
            "pattern": daily
                ? ["type": "daily", "interval": 1, "month": 0, "dayOfMonth": 0, "firstDayOfWeek": "sunday", "index": "first"]
                : ["type": "weekly", "interval": 1, "month": 0, "dayOfMonth": 0,
                   "daysOfWeek": [names[cal.component(.weekday, from: start) - 1]], "firstDayOfWeek": "sunday", "index": "first"],
            "range": ["type": "endDate", "startDate": dayIn(start, stored), "endDate": dayIn(place(4), stored),
                      "recurrenceTimeZone": storedName ?? stored, "numberOfOccurrences": 0],
        ]
        if let eventZone {
            var recurrence = series["recurrence"] as! [String: Any]
            var range = recurrence["range"] as! [String: Any]
            range.removeValue(forKey: "recurrenceTimeZone")
            recurrence["range"] = range
            series["recurrence"] = recurrence
            series["originalStartTimeZone"] = eventZone
        }
        if let alsoEventZone { series["originalStartTimeZone"] = alsoEventZone }
        let occurrences = (0...4).map { index -> [String: Any] in
            let at = place(index)
            var e = GraphFixture.event(id: "\(Self.id)-occ-\(index)", start: at, online: false, seriesMasterId: Self.id)
            dated(&e, at, in: device)
            e["originalStart"] = at.iso8601String(timeZone: zone(stored))
            return e
        }
        return FakeGraphCalendar([series] + occurrences)
    }

    /// The split occurrence is on the next day on the device. Dated on the device, the cap kept it
    /// on the old part as well.
    static let pacificFromTokyo = CrossZoneSeries(
        name: "weekly 17:00 Pacific from Tokyo", stored: "Pacific Standard Time", device: "Asia/Tokyo", daily: false, time: "17:00:00")
    /// The split occurrence is on the day before on the device. Dated on the device, the cap
    /// dropped the occurrence before it from both parts.
    static let tokyoFromPacific = CrossZoneSeries(
        name: "daily 10:00 Tokyo from Pacific", stored: "Tokyo Standard Time", device: "America/Los_Angeles", daily: true, time: "10:00:00")
    /// Each direction again, 26 hours apart, and from a zone with a quarter-hour offset.
    static let bakerIslandFromKiritimati = CrossZoneSeries(
        name: "daily 20:00 UTC-12 from Kiritimati", stored: "Etc/GMT+12", device: "Pacific/Kiritimati", daily: true, time: "20:00:00")
    static let kiritimatiFromBakerIsland = CrossZoneSeries(
        name: "daily 06:00 Kiritimati from UTC-12", stored: "Pacific/Kiritimati", device: "Etc/GMT+12", daily: true, time: "06:00:00")
    static let kathmanduFromHonolulu = CrossZoneSeries(
        name: "weekly 06:00 Kathmandu from Honolulu", stored: "Asia/Kathmandu", device: "Pacific/Honolulu", daily: false, time: "06:00:00")

    static let all = [pacificFromTokyo, tokyoFromPacific, bakerIslandFromKiritimati, kiritimatiFromBakerIsland, kathmanduFromHonolulu]
}

private func provider(_ http: FakeHTTP.Scenario) -> ExchangeCalendarProvider {
    ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" }, session: http.session)
}

@Suite("An Outlook split from another zone caps the series on the day before the split in the series' zone (#681)",
       .serialized, .processGlobalState)
struct ExchangeSplitCapSeriesDayTests {

    @Test("a split through the queue leaves every earlier occurrence on the old part only and the rest on the new part only",
          arguments: CrossZoneSeries.all)
    func splitPartitionsTheSeries(_ fixture: CrossZoneSeries) async throws {
        #expect(dayIn(fixture.split, fixture.device) != dayIn(fixture.split, fixture.stored),
                "non-vacuity: the device and the series date the split occurrence alike")
        let graph = fixture.calendar()
        let days = try #require(graph.rangeDays(of: CrossZoneSeries.id))
        let splitDay = dayIn(fixture.split, fixture.stored)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        let rows = try await drainEdit(
            accountId: "split-681-\(fixture.name)", eventId: CrossZoneSeries.id, calendarId: "primary",
            arguments: [
                "edit_scope": .string("this_and_following"), "recurrence_id": .string(wall(fixture.split, in: fixture.device)),
                "title": .string("Renamed"), "timezone": .string(fixture.device),
            ], provider: provider(http))

        #expect(rows.isEmpty, "the split was not written: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        #expect(graph.created.count == 1, "\(graph.created.count) new parts")
        guard graph.created.count == 1 else { return }
        let created = graph.created[0]
        let kept = graph.rangeDays(of: CrossZoneSeries.id) ?? []
        let following = FakeGraphCalendar.rangeDays(created) ?? []
        #expect(kept == days.filter { $0 < splitDay },
                "the old part holds \(kept); the series held \(days), split on \(splitDay) in its zone (cap \(canonical(rangeOf(graph.event(CrossZoneSeries.id)))))")
        #expect(following == days.filter { $0 >= splitDay }, "the new part holds \(following), from \(canonical(rangeOf(created)))")
        #expect(GraphFixture.instant(created["start"] as? [String: Any]) == fixture.split,
                "the new part starts \(canonical(created["start"])), the split occurrence is \(wall(fixture.split, in: fixture.stored)) in the series' zone")
    }

    @Test("a split interrupted after its new part is finished with the same cap, and a cap already written is not written again",
          arguments: CrossZoneSeries.all)
    func retryCapsOnTheSameDay(_ fixture: CrossZoneSeries) async throws {
        let graph = fixture.calendar()
        let days = try #require(graph.rangeDays(of: CrossZoneSeries.id))
        let splitDay = dayIn(fixture.split, fixture.stored)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        // The split is interrupted at its cap, its last write, with its new part made and its record kept.
        graph.failNext("PATCH", with: 400)
        let records = SplitRecordBox()
        var patch = GCalEventInput()
        patch.summary = "Renamed"
        await #expect(throws: (any Error).self) {
            _ = try await provider(http).splitSeries(
                eventId: CrossZoneSeries.id, recurrenceId: wall(fixture.split, in: fixture.device),
                recurrenceIdZone: zone(fixture.device), patch: patch, record: records.recorder)
        }
        #expect(graph.created.count == 1 && graph.patches(CrossZoneSeries.id).isEmpty, "the split was not interrupted at its cap")
        let record = try #require(records.records.first, "the split kept no record before its cap")

        try await provider(http).finishSplit(calendarId: "primary", record: record, zone: zone(fixture.device), guests: nil)
        let kept = graph.rangeDays(of: CrossZoneSeries.id) ?? []
        #expect(kept == days.filter { $0 < splitDay },
                "the retry's cap leaves \(kept) on the old part (\(canonical(rangeOf(graph.event(CrossZoneSeries.id))))); the series held \(days), split on \(splitDay)")

        // Another retry finds the series ending on that cap and writes nothing.
        let written = graph.patches(CrossZoneSeries.id).count
        try await provider(http).finishSplit(calendarId: "primary", record: record, zone: zone(fixture.device), guests: nil)
        #expect(graph.patches(CrossZoneSeries.id).count == written,
                "a series already capped was capped again: \(graph.patches(CrossZoneSeries.id).map { canonical(rangeOf($0)) })")
        #expect(graph.rangeDays(of: CrossZoneSeries.id) == kept, "the second retry changed the old part")
    }

    @Test("a timed series kept in a zone TabMail does not recognize is not split: a plain error and nothing written (#746)")
    func unrecognizedZoneIsRefused() async throws {
        let custom = "Customized Time Zone"
        #expect(CalendarTimeZoneResolver.zone(named: custom, in: .none) == nil, "non-vacuity: the zone is not recognized")
        let fixture = CrossZoneSeries.pacificFromTokyo
        let graph = fixture.calendar(storedName: custom)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        var refusal: String?
        do {
            var patch = GCalEventInput()
            patch.summary = "Renamed"
            _ = try await provider(http).splitSeries(
                eventId: CrossZoneSeries.id, recurrenceId: wall(fixture.split, in: fixture.device),
                recurrenceIdZone: zone(fixture.device), patch: patch, record: .unused)
        } catch let error as CalendarProviderError {
            refusal = error.reason
        }
        #expect(refusal?.contains(custom) == true, "the split was not refused naming the zone: \(refusal ?? "no error")")
        #expect(graph.writes.isEmpty, "written: \(graph.writes)")
        #expect(graph.created.isEmpty)

        // A retry finishing a split of such a series is refused the same way, writing nothing.
        let record = SplitRecord(
            seriesId: CrossZoneSeries.id, newPartId: "cz-new", splitAt: wall(fixture.split, in: fixture.device), mode: .carry, fields: [.summary])
        await #expect(throws: CalendarProviderError.self) {
            try await provider(http).finishSplit(calendarId: "primary", record: record, zone: zone(fixture.device), guests: nil)
        }
        #expect(graph.writes.isEmpty, "written: \(graph.writes)")
    }

    @Test("a series whose range names no zone is split on the day before the split in the event's own zone (originalStartTimeZone)",
          arguments: [CrossZoneSeries.pacificFromTokyo, CrossZoneSeries.tokyoFromPacific])
    func splitOfASeriesInTheEventsZone(_ fixture: CrossZoneSeries) async throws {
        #expect(dayIn(fixture.split, fixture.device) != dayIn(fixture.split, fixture.stored),
                "non-vacuity: the device and the series date the split occurrence alike")
        let graph = fixture.calendar(eventZone: fixture.stored)
        let days = try #require(graph.rangeDays(of: CrossZoneSeries.id))
        let splitDay = dayIn(fixture.split, fixture.stored)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        let rows = try await drainEdit(
            accountId: "split-681-ez-\(fixture.daily)", eventId: CrossZoneSeries.id, calendarId: "primary",
            arguments: [
                "edit_scope": .string("this_and_following"), "recurrence_id": .string(wall(fixture.split, in: fixture.device)),
                "title": .string("Renamed"), "timezone": .string(fixture.device),
            ], provider: provider(http))

        #expect(rows.isEmpty, "the split was not written: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        #expect(graph.created.count == 1, "\(graph.created.count) new parts")
        guard graph.created.count == 1 else { return }
        let kept = graph.rangeDays(of: CrossZoneSeries.id) ?? []
        #expect(kept == days.filter { $0 < splitDay },
                "the old part holds \(kept); the series held \(days), split on \(splitDay) in the event's zone (cap \(canonical(rangeOf(graph.event(CrossZoneSeries.id)))))")
        // The new part is dated in the event's zone too: it holds the split occurrence and every
        // later one, and starts at the split occurrence.
        let created = graph.created[0]
        let following = FakeGraphCalendar.rangeDays(created) ?? []
        #expect(following == days.filter { $0 >= splitDay }, "the new part holds \(following), from \(canonical(rangeOf(created)))")
        #expect(GraphFixture.instant(created["start"] as? [String: Any]) == fixture.split,
                "the new part starts \(canonical(created["start"])), the split occurrence is \(wall(fixture.split, in: fixture.stored)) in the event's zone")
    }

    @Test("a series whose range names a zone and whose event names another is split in the range's zone",
          arguments: [CrossZoneSeries.pacificFromTokyo, CrossZoneSeries.tokyoFromPacific])
    func rangeZoneComesBeforeTheEventsZone(_ fixture: CrossZoneSeries) async throws {
        let other = fixture.device
        #expect(dayIn(fixture.split, other) != dayIn(fixture.split, fixture.stored),
                "non-vacuity: the event's zone and the range's date the split occurrence alike")
        let graph = fixture.calendar(alsoEventZone: other)
        let days = try #require(graph.rangeDays(of: CrossZoneSeries.id))
        let splitDay = dayIn(fixture.split, fixture.stored)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        let rows = try await drainEdit(
            accountId: "split-681-both-\(fixture.daily)", eventId: CrossZoneSeries.id, calendarId: "primary",
            arguments: [
                "edit_scope": .string("this_and_following"), "recurrence_id": .string(wall(fixture.split, in: fixture.device)),
                "title": .string("Renamed"), "timezone": .string(fixture.device),
            ], provider: provider(http))

        #expect(rows.isEmpty, "the split was not written: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        let kept = graph.rangeDays(of: CrossZoneSeries.id) ?? []
        #expect(kept == days.filter { $0 < splitDay },
                "the old part holds \(kept); the series held \(days), split on \(splitDay) in the range's zone")
    }

    @Test("a series whose range names no zone and whose own zone TabMail does not recognize is not split: nothing written (#746)")
    func unrecognizedEventZoneIsRefused() async throws {
        let custom = "Customized Time Zone"
        let fixture = CrossZoneSeries.pacificFromTokyo
        let graph = fixture.calendar(eventZone: custom)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        var refusal: String?
        do {
            var patch = GCalEventInput()
            patch.summary = "Renamed"
            _ = try await provider(http).splitSeries(
                eventId: CrossZoneSeries.id, recurrenceId: wall(fixture.split, in: fixture.device),
                recurrenceIdZone: zone(fixture.device), patch: patch, record: .unused)
        } catch let error as CalendarProviderError {
            refusal = error.reason
        }
        #expect(refusal?.contains(custom) == true, "the split was not refused naming the zone: \(refusal ?? "no error")")
        #expect(graph.writes.isEmpty, "written: \(graph.writes)")
        #expect(graph.created.isEmpty)
    }

    @Test("an all-day split from a far zone caps on the day before the date it names", arguments: ["Tokyo Standard Time", "Pacific Standard Time"])
    func allDaySplitFromAFarZone(_ stored: String) async throws {
        let device = stored == "Tokyo Standard Time" ? "America/Los_Angeles" : "Asia/Tokyo"
        let graph = ExchangeAllDaySeriesLengthTests.series(kept: stored)
        let days = try #require(graph.rangeDays(of: "zs-1"))
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        let rows = try await drainEdit(
            accountId: "split-681-allday-\(stored)", eventId: "zs-1", calendarId: "primary",
            arguments: [
                "edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(7))T00:00:00"),
                "title": .string("Renamed"), "all_day": .bool(true), "timezone": .string(device),
            ], provider: provider(http))

        #expect(rows.isEmpty, "\(stored): the split was not written: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        let kept = graph.rangeDays(of: "zs-1") ?? []
        let following = graph.created.first.flatMap(FakeGraphCalendar.rangeDays) ?? []
        #expect(kept == days.filter { $0 < day(7) } && following == days.filter { $0 >= day(7) },
                "\(stored): the old part holds \(kept), the new part \(following); the series held \(days), split on \(day(7))")
    }

    @Test("the cap is the day before the split occurrence's day in the series' zone, for every zone pair and across a clock change")
    func capIsTheSeriesZoneDayBefore() throws {
        let zones = ["Etc/GMT+12", "Pacific/Kiritimati", "Asia/Kathmandu", "America/Los_Angeles", "Asia/Tokyo", "UTC",
                     "Australia/Lord_Howe"]
        // Across the next clock change in Los Angeles, every five hours for six days.
        let change = try #require(zone("America/Los_Angeles").nextDaylightSavingTimeTransition(after: Date()))
        let instants = stride(from: -72, through: 72, by: 5).map { change.addingTimeInterval(Double($0) * 3_600) }
        for series in zones {
            var event = GCalEvent(id: "series", summary: nil, location: nil, description: nil,
                                  start: GCalDateTime(dateTime: wall(change, in: series), date: nil, timeZone: series), end: nil,
                                  attendees: nil, organizer: nil, recurrence: ["RRULE:FREQ=DAILY"], transparency: nil,
                                  status: nil, htmlLink: nil, created: nil, updated: nil)
            event.recurrenceTimeZoneName = series
            let stored = ExchangeCalendarProvider.EditSnapshot(event: event, raw: [:])
            for operation in zones {
                for at in instants {
                    let naive = wall(at, in: operation)
                    let expected = try #require(GraphFixture.capEndDate(naive, zone: zone(operation), keptIn: series))
                    let cap = try ExchangeCalendarProvider.splitCapEndDate(stored: stored, splitNaiveISO: naive, splitZone: zone(operation))
                    #expect(cap == expected, "series in \(series), split at \(naive) in \(operation): cap \(cap), expected \(expected)")
                }
            }
        }
    }
}
