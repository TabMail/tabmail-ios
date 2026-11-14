/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - A stored repeat rule, shown in the fields the tools write (#552)
//
// **INVARIANT.** *The read tools show a series' rule in the fields `calendar_event_create` and
// `calendar_event_edit` take, and a rule shown that way, given back to the edit tool unchanged,
// keeps exactly the series' occurrences.* Every part the fields cannot say goes to `other`, which
// the writer refuses, so restating such a rule can never drop a part silently.
//
// The occurrences are worked out by the CalDAV expander (`CalDAVOccurrences.listing`), the
// oracle every series below is compared through: the stored rule's occurrences against those of
// the rule the edit tool writes for the fields shown.
//
// Every date is worked out from `Date()`; none is written as a literal but 2099 ones.

private typealias F = OccurrenceFixture

/// The fields a `recurrence:` JSON object gives back, as the tools take them.
private func toolFields(_ json: String) throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
}

/// The RRULE the edit tool writes for `fields`, in `zone` (the edit's `timezone`).
private func writtenRule(_ fields: [String: JSONValue], zone: TimeZone, allDay: Bool) throws -> String? {
    try CalendarToolHelpers.buildGCalEventInput(
        ["timezone": .string(zone.identifier), "recurrence": .dictionary(fields)], isAllDay: allDay
    ).recurrence?.first
}

/// One part of an RRULE line (`UNTIL`), or nil.
private func rulePart(_ name: String, of rule: String) -> String? {
    rule.dropFirst("RRULE:".count).split(separator: ";").compactMap { part -> String? in
        let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
        return pair.count == 2 && pair[0] == name ? pair[1] : nil
    }.first
}

/// A timed series in `zone` from `first`, half an hour long, with `rule`.
private func timedICS(first: Date, zone: TimeZone, rule: String) -> String {
    F.ics(["""
        UID:rule-format
        DTSTAMP:\(F.utcValue(first))
        DTSTART;TZID=\(zone.identifier):\(F.wall(first, zone))
        DTEND;TZID=\(zone.identifier):\(F.wall(first.addingTimeInterval(1_800), zone))
        SUMMARY:Standup
        \(rule)
        """])
}

/// An all-day series from `day` (a date in UTC), one day long, with `rule`.
private func allDayICS(day: Date, rule: String) -> String {
    F.ics(["""
        UID:rule-format-all-day
        DTSTAMP:\(F.utcValue(day))
        DTSTART;VALUE=DATE:\(F.dateValue(day, .gmt))
        DTEND;VALUE=DATE:\(F.dateValue(day.addingTimeInterval(F.days(1)), .gmt))
        SUMMARY:Holiday
        \(rule)
        """])
}

/// Each listed occurrence's start, as the listing gives it (an instant, or a date).
private func starts(_ rows: [GCalEvent]) -> [String] {
    rows.compactMap { $0.start?.dateTime.flatMap(Date.fromISO8601).map(F.utcValue) ?? $0.start?.date }.sorted()
}

private func series(_ recurrence: [String], start: Date = Date(), zone: String = "UTC") -> GCalEvent {
    GCalEvent(
        id: "ser", summary: "Sync", location: nil, description: nil,
        start: GCalDateTime(dateTime: start.iso8601String(), date: nil, timeZone: zone),
        end: GCalDateTime(dateTime: start.addingTimeInterval(1_800).iso8601String(), date: nil, timeZone: zone),
        attendees: nil, organizer: nil, recurrence: recurrence, transparency: nil, status: "confirmed",
        htmlLink: nil, created: nil, updated: nil
    )
}

@Suite("A stored repeat rule is shown in the fields the tools write (#552)")
struct CalendarRecurrenceFieldsTests {

    @Test("each stored part is shown in its field, in the tools' order; what no field says goes to other", arguments: [
        (["RRULE:FREQ=WEEKLY;BYDAY=MO,WE"], #"{"freq":"WEEKLY","byDay":["MO","WE"]}"#),
        (["RRULE:FREQ=WEEKLY;INTERVAL=1;WKST=MO;BYDAY=MO"], #"{"freq":"WEEKLY","byDay":["MO"]}"#),
        (["RRULE:BYMONTHDAY=1,-1;COUNT=6;INTERVAL=2;FREQ=MONTHLY"], #"{"freq":"MONTHLY","interval":2,"count":6,"byMonthDay":[1,-1]}"#),
        (["RRULE:FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=10;WKST=SU"], #"{"freq":"YEARLY","byMonthDay":[10],"byMonth":[3],"wkst":"SU"}"#),
        (["rrule:freq=monthly;byday=-1fr"], #"{"freq":"MONTHLY","byDay":["-1FR"]}"#),
        (["EXDATE:20990105T100000Z", "RRULE:FREQ=DAILY;COUNT=3", "RDATE:20990110T100000Z"], #"{"freq":"DAILY","count":3}"#),
        (["RRULE:FREQ=HOURLY;INTERVAL=2"], #"{"interval":2,"other":"FREQ=HOURLY"}"#),
        (["RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=9,17"], #"{"freq":"WEEKLY","byDay":["MO"],"other":"BYHOUR=9,17"}"#),
        (["RRULE:FREQ=MONTHLY;BYDAY=TU,TH;BYSETPOS=2"], #"{"freq":"MONTHLY","byDay":["TU","TH"],"other":"BYSETPOS=2"}"#),
        (["RRULE:FREQ=WEEKLY;BYDAY=MO", "RRULE:FREQ=MONTHLY;BYMONTHDAY=1"], #"{"freq":"WEEKLY","byDay":["MO"],"other":"RRULE:FREQ=MONTHLY;BYMONTHDAY=1"}"#),
        (["RRULE:FREQ=WEEKLY;INTERVAL=0;BYDAY=XX"], #"{"freq":"WEEKLY","other":"INTERVAL=0;BYDAY=XX"}"#),
        // A part with no name, kept as stored rather than read.
        (["RRULE:FREQ=DAILY;=;COUNT=3"], #"{"freq":"DAILY","count":3,"other":"="}"#),
        // Parts the writer refuses with this FREQ: a numbered day outside MONTHLY and YEARLY, days
        // of the month with WEEKLY; and a part given twice.
        (["RRULE:FREQ=WEEKLY;BYDAY=1MO;BYMONTHDAY=15"], #"{"freq":"WEEKLY","other":"BYDAY=1MO;BYMONTHDAY=15"}"#),
        (["RRULE:FREQ=WEEKLY;BYDAY=MO;BYDAY=TU"], #"{"freq":"WEEKLY","byDay":["MO"],"other":"BYDAY=TU"}"#),
        // An UNTIL beside a COUNT (which the writer writes in its place), or in a rule of several
        // times a day, is kept as stored.
        (["RRULE:FREQ=DAILY;COUNT=3;UNTIL=20991231T235959Z"], #"{"freq":"DAILY","count":3,"other":"UNTIL=20991231T235959Z"}"#),
        (["RRULE:FREQ=DAILY;BYHOUR=9,17;UNTIL=20991231T235959Z"], #"{"freq":"DAILY","other":"BYHOUR=9,17;UNTIL=20991231T235959Z"}"#),
        (["RRULE:FREQ=DAILY;BYMINUTE=0,30;UNTIL=20991231T235959Z"], #"{"freq":"DAILY","other":"BYMINUTE=0,30;UNTIL=20991231T235959Z"}"#),
        (["RRULE:FREQ=DAILY;BYSECOND=0;UNTIL=20991231T235959Z"], #"{"freq":"DAILY","other":"BYSECOND=0;UNTIL=20991231T235959Z"}"#),
        (["RRULE:FREQ=HOURLY;UNTIL=20991231T235959Z"], #"{"other":"FREQ=HOURLY;UNTIL=20991231T235959Z"}"#),
        (["RRULE:INTERVAL=2;UNTIL=20991231T235959Z"], #"{"interval":2,"other":"UNTIL=20991231T235959Z"}"#),
    ] as [([String], String)])
    func fieldMapping(_ recurrence: [String], _ json: String) throws {
        let fields = try #require(CalendarRecurrenceFormat.fields(recurrence, series: series(recurrence), zone: .gmt))
        #expect(fields.json == json, "\(recurrence) is shown as \(fields.json)")
    }

    @Test("a series with no rule shows none")
    func noRuleNoFields() {
        #expect(CalendarRecurrenceFormat.fields(["RDATE:20990110T100000Z"], series: series([]), zone: .gmt) == nil)
        #expect(CalendarRecurrenceFormat.fields(nil, series: series([]), zone: .gmt) == nil)
    }

    /// The shown fields are what the writer takes back: every rule with no `other` restates to
    /// the same RRULE, parts in the writer's order.
    @Test("a rule with no other part is written back as stored", arguments: [
        "RRULE:FREQ=WEEKLY;BYDAY=MO,WE",
        "RRULE:FREQ=MONTHLY;INTERVAL=2;COUNT=6;BYMONTHDAY=1,-1",
        "RRULE:FREQ=YEARLY;BYDAY=-1FR;BYMONTH=3;WKST=SU",
        "RRULE:FREQ=DAILY;INTERVAL=3",
    ])
    func restatesToTheStoredRule(_ rule: String) throws {
        let fields = try #require(CalendarRecurrenceFormat.fields([rule], series: series([rule]), zone: .gmt))
        #expect(fields.other.isEmpty)
        #expect(try writtenRule(toolFields(fields.json), zone: .gmt, allDay: false) == rule)
    }

    @Test("the read shows the rule's fields, the series' excluded and added dates as stored, and no RRULE text")
    func detailedReadShowsFields() {
        let event = series(["RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=9", "EXDATE:20990105T090000Z"])
        let lines = CalendarToolHelpers.formatDetailedEvent(event, timeZone: .gmt).split(separator: "\n").map(String.init)
        #expect(lines.contains("recurring: yes"))
        #expect(lines.contains(#"recurrence: {"freq":"WEEKLY","byDay":["MO"],"other":"BYHOUR=9"} (\#(CalendarRecurrenceFormat.otherPartsNote))"#),
                "\(lines)")
        #expect(lines.contains("EXDATE:20990105T090000Z"), "\(lines)")
        #expect(!lines.contains { $0.contains("RRULE") }, "\(lines)")

        let plain = CalendarToolHelpers.formatDetailedEvent(series(["RRULE:FREQ=DAILY"]), timeZone: .gmt)
        #expect(plain.contains(#"recurrence: {"freq":"DAILY"}"#) && !plain.contains(CalendarRecurrenceFormat.otherPartsNote), "\(plain)")
    }
}

// MARK: - BYSETPOS over one weekday

@Suite("A position over one weekday is shown as a numbered day where RFC 5545 makes them the same (#552)")
struct CalendarRecurrenceSetPositionTests {

    /// **INVARIANT.** *The numbered day shown for `BYDAY=<day>;BYSETPOS=<n>` gives the same
    /// occurrences.* Every weekday and position, monthly, every other month, and yearly in one
    /// month, over three years, compared through the CalDAV expander.
    @Test("the numbered day shown has the stored rule's occurrences", arguments: [
        "FREQ=MONTHLY", "FREQ=MONTHLY;INTERVAL=2", "FREQ=YEARLY;BYMONTH=11", "FREQ=MONTHLY;BYMONTH=2,5",
        "FREQ=MONTHLY;COUNT=7", "FREQ=MONTHLY;WKST=SU",
    ])
    func foldKeepsOccurrences(_ head: String) throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let firstDay = try #require(utc.date(byAdding: .month, value: 1, to: utc.startOfDay(for: Date())))
        let monthStart = try #require(utc.date(from: utc.dateComponents([.year, .month], from: firstDay)))
        let first = try #require(utc.date(bySettingHour: 9, minute: 0, second: 0, of: monthStart))
        let to = first.addingTimeInterval(F.days(3 * 366))
        var failures: [String] = []
        var occurrences = 0
        for day in CalendarToolHelpers.rruleWeekdays {
            for position in [1, 2, 3, 4, 5, -1, -2] {
                let stored = "RRULE:\(head);BYDAY=\(day);BYSETPOS=\(position)"
                let fields = try #require(CalendarRecurrenceFormat.fields([stored], series: series([stored], start: first), zone: .gmt))
                guard fields.other.isEmpty, fields.byDay == ["\(position)\(day)"] else {
                    failures.append("\(stored) is shown as \(fields.json)"); continue
                }
                guard let written = try writtenRule(toolFields(fields.json), zone: .gmt, allDay: false) else {
                    failures.append("\(stored): nothing written"); continue
                }
                let wasRows = F.listing(timedICS(first: first, zone: .gmt, rule: stored), from: first, to: to)
                let nowRows = F.listing(timedICS(first: first, zone: .gmt, rule: written), from: first, to: to)
                guard !(wasRows + nowRows).contains(where: { $0.occurrencesNotListed == true }) else {
                    failures.append("\(stored) or \(written) was not expanded"); continue
                }
                let was = starts(wasRows)
                let now = starts(nowRows)
                occurrences += was.count
                if was != now { failures.append("\(stored) gives \(was.count) occurrences, \(written) gives \(now.count)") }
            }
        }
        #expect(occurrences > 0, "no occurrence was listed")
        #expect(failures.isEmpty, "\(failures.count) rules:\n\(failures.joined(separator: "\n"))")
    }

    /// Where a position is not one weekday's place in a month, no numbered day says it, and
    /// BYSETPOS stays in `other`.
    @Test("a position the numbered days cannot say stays in other", arguments: [
        "RRULE:FREQ=MONTHLY;BYDAY=TH,FR;BYSETPOS=2",
        "RRULE:FREQ=MONTHLY;BYDAY=TU;BYSETPOS=1,3",
        "RRULE:FREQ=MONTHLY;BYDAY=2TU;BYSETPOS=1",
        "RRULE:FREQ=MONTHLY;BYDAY=TU;BYMONTHDAY=1,2,3,4,5,6,7;BYSETPOS=1",
        "RRULE:FREQ=YEARLY;BYDAY=TU;BYSETPOS=2",
        "RRULE:FREQ=YEARLY;BYMONTH=3,9;BYDAY=TU;BYSETPOS=2",
        "RRULE:FREQ=WEEKLY;BYDAY=TU;BYSETPOS=1",
        "RRULE:FREQ=MONTHLY;BYDAY=TU;BYSETPOS=0",
        "RRULE:FREQ=MONTHLY;BYDAY=TU;BYSETPOS=-60",
    ])
    func noFoldKeepsSetPosition(_ rule: String) throws {
        let fields = try #require(CalendarRecurrenceFormat.fields([rule], series: series([rule]), zone: .gmt))
        #expect(fields.other.contains { $0.hasPrefix("BYSETPOS=") }, "\(rule) is shown as \(fields.json)")
    }
}

// MARK: - UNTIL as the last day

@Suite("A stored end is shown as the last day, which the edit tool writes back to the same occurrences (#552)")
struct CalendarRecurrenceUntilTests {

    static let seriesZones = ["Asia/Tokyo", "America/Los_Angeles", "Europe/London", "Australia/Lord_Howe", "Asia/Kolkata"]
    static let displayZones = ["UTC", "Asia/Tokyo", "America/Los_Angeles", "Europe/London", "Australia/Lord_Howe",
                               "America/St_Johns", "Pacific/Kiritimati"]

    /// Whether `zone` changes its clocks within three days of `day`.
    private static func nearClockChange(_ zone: TimeZone, _ day: Date) -> Bool {
        guard let next = zone.nextDaylightSavingTimeTransition(after: day.addingTimeInterval(-F.days(3))) else { return false }
        return next < day.addingTimeInterval(F.days(3))
    }

    /// The days a series ends on: one far from any clock change, and the days around the next
    /// two clock changes of the series' zone and of the zone the read prints in.
    private static func lastDays(_ seriesCal: Calendar, display: TimeZone) -> [Date] {
        let from = Date().addingTimeInterval(F.days(30))
        var days = [seriesCal.startOfDay(for: Date().addingTimeInterval(F.days(40)))]
        for zone in [seriesCal.timeZone, display] {
            var after = from
            for _ in 0..<2 {
                guard let change = zone.nextDaylightSavingTimeTransition(after: after) else { break }
                after = change
                for offset in -1...1 {
                    if let day = seriesCal.date(byAdding: .day, value: offset, to: seriesCal.startOfDay(for: change)) { days.append(day) }
                }
            }
        }
        return days
    }

    /// **INVARIANT.** *A shown `until`, given back in the zone the read printed in, keeps exactly
    /// the stored series' occurrences, and is the date its last occurrence falls on there.* Daily
    /// series in five zones, at 00:30, 10:00 and 23:30, ending on days near and far from a clock
    /// change, read in seven zones, with the end stored as: the last slot itself, a split's cap
    /// (a second before a slot), the end of the day in the series' zone, `T235959Z`, `T050000Z`, a
    /// floating noon, a bare date (Outlook's range end, also checked through
    /// `ExchangeCalendarProvider.graphEndDate`), and the end of the day in the read's zone. Every
    /// end is shown; where the day would not restate exactly (only near a clock change) it is the
    /// last occurrence's instant in UTC, which restates exactly too.
    @Test("a shown until is the last occurrence's day and restates to the same occurrences", arguments: seriesZones)
    func untilRoundTrips(_ seriesZoneId: String) throws {
        let (failures, shown, exact) = try Self.roundTrip(seriesZoneId)
        #expect(shown > 0, "no end was shown")
        #expect(failures.isEmpty, "\(failures.count) cases (\(shown) shown, \(exact) as a date-time):\n\(failures.prefix(40).joined(separator: "\n"))")
    }

    /// The exact form is reached: a series in each zone, read in every zone, near clock changes,
    /// shows at least one end as the last occurrence's UTC instant (each checked by `roundTrip`).
    @Test("near a clock change some end is shown as the last occurrence's instant, and restates exactly")
    func exactUntilIsReached() throws {
        var exact = 0
        for id in Self.seriesZones { exact += try Self.roundTrip(id).exact }
        #expect(exact > 0, "no end needed the exact form, so that branch went unchecked")
    }

    private static func roundTrip(_ seriesZoneId: String) throws -> (failures: [String], shown: Int, exact: Int) {
        let seriesZone = try #require(TimeZone(identifier: seriesZoneId))
        let seriesCal = F.calendar(seriesZone)
        var failures: [String] = []
        var shown = 0
        var exact = 0
        for displayId in Self.displayZones {
            let display = try #require(TimeZone(identifier: displayId))
            for target in Self.lastDays(seriesCal, display: display) {
                for (hour, minute) in [(0, 30), (10, 0), (23, 30)] {
                    let slot = try #require(seriesCal.date(bySettingHour: hour, minute: minute, second: 0, of: target))
                    let firstDay = try #require(seriesCal.date(byAdding: .day, value: -4, to: target))
                    let first = try #require(seriesCal.date(bySettingHour: hour, minute: minute, second: 0, of: firstDay))
                    let endOfDay = try #require(seriesCal.date(byAdding: .day, value: 1, to: target)).addingTimeInterval(-1)
                    let displayDay = F.dateValue(slot, display)
                    let displayEnd = try #require(CalendarToolHelpers.validatedRRuleUntil(displayDay, allDay: false, zone: display))
                    let date = F.dateValue(target, seriesZone)
                    let bounds: [(String, String)] = [
                        ("the last slot", F.utcValue(slot)),
                        ("a split's cap", F.utcValue(slot.addingTimeInterval(-1))),
                        ("the end of the day in the series' zone", F.utcValue(endOfDay)),
                        ("T235959Z", "\(date)T235959Z"),
                        ("T050000Z", "\(date)T050000Z"),
                        ("a floating noon", "\(date)T120000"),
                        ("a bare date", date),
                        ("the end of the day in the read's zone", displayEnd),
                    ]
                    let to = target.addingTimeInterval(F.days(3))
                    for (label, bound) in bounds {
                        let rows = F.listing(timedICS(first: first, zone: seriesZone, rule: "RRULE:FREQ=DAILY;UNTIL=\(bound)"),
                                             from: first.addingTimeInterval(-F.days(1)), to: to)
                        let was = starts(rows)
                        let at = "\(seriesZoneId) \(hour):\(minute) until \(bound) (\(label)), read in \(displayId)"
                        guard let row = rows.first, let lastStart = rows.compactMap(\.startDate).max() else {
                            failures.append("\(at): nothing listed"); continue
                        }
                        guard let fields = CalendarRecurrenceFormat.fields(row.recurrence, series: row, zone: display) else {
                            failures.append("\(at): no fields"); continue
                        }
                        guard let until = fields.until, fields.other.isEmpty else {
                            failures.append("\(at): the end was not shown: \(fields.json)"); continue
                        }
                        shown += 1
                        if until.contains("T") {
                            exact += 1
                            if until != Self.utcInstant(lastStart) {
                                failures.append("\(at): shown \(until), the last occurrence is at \(Self.utcInstant(lastStart))")
                            }
                            if !Self.nearClockChange(seriesZone, target) && !Self.nearClockChange(display, target) {
                                failures.append("\(at): a date-time away from a clock change: \(until)")
                            }
                        } else if until != F.isoDate(lastStart, display) {
                            failures.append("\(at): shown \(until), the last occurrence is on \(F.isoDate(lastStart, display))")
                        }
                        guard let written = try writtenRule(["freq": .string("DAILY"), "until": .string(until)], zone: display, allDay: false),
                              let writtenUntil = rulePart("UNTIL", of: written) else {
                            failures.append("\(at): \(until) was not written"); continue
                        }
                        let now = starts(F.listing(timedICS(first: first, zone: seriesZone, rule: written),
                                                   from: first.addingTimeInterval(-F.days(1)), to: to))
                        if now != was { failures.append("\(at): shown \(until), written \(writtenUntil): \(was.count) occurrences became \(now.count)") }
                        if label == "a bare date" {
                            let graph = ExchangeCalendarProvider.graphEndDate(until: writtenUntil, in: seriesZone, startWallTime: F.naive(first, seriesZone))
                            if graph != F.isoDate(target, seriesZone) {
                                failures.append("\(at): Outlook's end \(F.isoDate(target, seriesZone)) is written back as \(graph ?? "nil")")
                            }
                        }
                    }
                }
            }
        }
        return (failures, shown, exact)
    }

    /// An instant as the exact `until` form: `yyyy-MM-ddTHH:mm:ssZ`.
    private static func utcInstant(_ date: Date) -> String {
        FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss'Z'", timeZone: .gmt).string(from: date)
    }

    /// A CalDAV series whose start names no zone: in UTC (`Z`) or floating.
    private static func zonelessICS(first: Date, utc: Bool, rule: String) -> String {
        let start = utc ? F.utcValue(first) : F.wall(first, .current)
        let end = utc ? F.utcValue(first.addingTimeInterval(1_800)) : F.wall(first.addingTimeInterval(1_800), .current)
        return F.ics(["""
            UID:rule-format-zoneless
            DTSTAMP:\(F.utcValue(first))
            DTSTART:\(start)
            DTEND:\(end)
            SUMMARY:Standup
            \(rule)
            """])
    }

    /// **INVARIANT.** *A CalDAV series whose start is in UTC or floating shows its end too, and the
    /// end shown restates to the same occurrences.* Such a start names no zone (`seriesZone` is
    /// nil), so the zone the rule repeats in is carried as `GCalEvent.ruleZone` on the series read
    /// (`ICSParser.parse`) and on every listed row; without it the end stayed in `other` and the
    /// rule could not be restated.
    @Test("a CalDAV series in UTC or floating shows its end, which restates to the same occurrences", arguments: [true, false])
    func zonelessCalDAVUntilRoundTrips(_ utc: Bool) throws {
        let seriesZone: TimeZone = utc ? .gmt : .current
        let seriesCal = F.calendar(seriesZone)
        var failures: [String] = []
        var checked = 0
        for displayId in Self.displayZones {
            let display = try #require(TimeZone(identifier: displayId))
            for target in Self.lastDays(seriesCal, display: display) {
                for (hour, minute) in [(0, 30), (10, 0), (23, 30)] {
                    let slot = try #require(seriesCal.date(bySettingHour: hour, minute: minute, second: 0, of: target))
                    let firstDay = try #require(seriesCal.date(byAdding: .day, value: -4, to: target))
                    let first = try #require(seriesCal.date(bySettingHour: hour, minute: minute, second: 0, of: firstDay))
                    let bounds = [F.utcValue(slot), F.utcValue(slot.addingTimeInterval(-1)), F.wall(slot, seriesZone)]
                    let from = first.addingTimeInterval(-F.days(1))
                    let to = target.addingTimeInterval(F.days(3))
                    for bound in bounds {
                        let ics = Self.zonelessICS(first: first, utc: utc, rule: "RRULE:FREQ=DAILY;UNTIL=\(bound)")
                        let rows = F.listing(ics, from: from, to: to)
                        let at = "\(utc ? "UTC" : "floating") \(hour):\(minute) until \(bound), read in \(displayId)"
                        guard let row = rows.first, let lastStart = rows.compactMap(\.startDate).max() else {
                            failures.append("\(at): nothing listed"); continue
                        }
                        let master = try #require(ICSParser.parse(icsText: ics, resourceHref: "/cal/zoneless.ics", etag: nil).first)
                        for (label, event) in [("listed row", row), ("series read", master)] {
                            checked += 1
                            guard let fields = CalendarRecurrenceFormat.fields(event.recurrence, series: event, zone: display),
                                  let until = fields.until, fields.other.isEmpty else {
                                failures.append("\(at) (\(label)): the end was not shown"); continue
                            }
                            if !until.contains("T"), until != F.isoDate(lastStart, display) {
                                failures.append("\(at) (\(label)): shown \(until), the last occurrence is on \(F.isoDate(lastStart, display))")
                            }
                            guard let written = try writtenRule(toolFields(fields.json), zone: display, allDay: false) else {
                                failures.append("\(at) (\(label)): \(until) was not written"); continue
                            }
                            let now = starts(F.listing(Self.zonelessICS(first: first, utc: utc, rule: written), from: from, to: to))
                            if now != starts(rows) { failures.append("\(at) (\(label)): shown \(until), written \(written): \(rows.count) occurrences became \(now.count)") }
                        }
                    }
                }
            }
        }
        #expect(checked > 0, "nothing was checked")
        #expect(failures.isEmpty, "\(failures.count) cases:\n\(failures.prefix(40).joined(separator: "\n"))")
    }

    /// **INVARIANT.** *Every row of a series shows the same `until`, a changed occurrence's row
    /// too.* An occurrence changed on its own is listed with its own start but the series' rule:
    /// moved two hours, or made all-day (its kind is not the series'), in a series in Los Angeles,
    /// in UTC and floating. Its `until` is read from its place in the series, so it is the series'
    /// last day, and writing it back keeps the same occurrences.
    @Test("a changed occurrence's row shows the series' end", arguments: ["zoned", "utc", "floating"])
    func changedOccurrenceShowsTheSeriesEnd(_ kind: String) throws {
        let zone: TimeZone = kind == "zoned" ? try #require(TimeZone(identifier: "America/Los_Angeles")) : kind == "utc" ? .gmt : .current
        let cal = F.calendar(zone)
        let firstDay = try #require(cal.date(byAdding: .day, value: 40, to: cal.startOfDay(for: Date())))
        let first = try #require(cal.date(bySettingHour: 17, minute: 0, second: 0, of: firstDay))
        let last = try #require(cal.date(byAdding: .day, value: 6, to: first))
        let moved = try #require(cal.date(byAdding: .day, value: 2, to: first))
        let allDay = try #require(cal.date(byAdding: .day, value: 4, to: first))
        func value(_ date: Date) -> String { kind == "utc" ? F.utcValue(date) : F.wall(date, zone) }
        let tz = kind == "zoned" ? ";TZID=\(zone.identifier)" : ""
        func ics(_ rule: String) -> String {
            F.ics(["""
                UID:rule-format-changed
                DTSTAMP:\(F.utcValue(first))
                DTSTART\(tz):\(value(first))
                DTEND\(tz):\(value(first.addingTimeInterval(1_800)))
                SUMMARY:Standup
                \(rule)
                """, """
                UID:rule-format-changed
                DTSTAMP:\(F.utcValue(first))
                RECURRENCE-ID\(tz):\(value(moved))
                DTSTART\(tz):\(value(moved.addingTimeInterval(7_200)))
                DTEND\(tz):\(value(moved.addingTimeInterval(9_000)))
                SUMMARY:Standup moved
                """, """
                UID:rule-format-changed
                DTSTAMP:\(F.utcValue(first))
                RECURRENCE-ID\(tz):\(value(allDay))
                DTSTART;VALUE=DATE:\(F.dateValue(allDay, zone))
                DTEND;VALUE=DATE:\(F.dateValue(allDay.addingTimeInterval(F.days(1)), zone))
                SUMMARY:Standup all day
                """])
        }
        let display = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let from = first.addingTimeInterval(-F.days(1))
        let to = last.addingTimeInterval(F.days(3))
        let rows = F.listing(ics("RRULE:FREQ=DAILY;UNTIL=\(F.utcValue(last))"), from: from, to: to)
        #expect(rows.count == 7, "listed \(rows.count)")
        let shown = rows.map { CalendarRecurrenceFormat.fields($0.recurrence, series: $0, zone: display)?.until }
        #expect(Set(shown).count == 1 && shown.first == F.isoDate(last, display), "\(kind): rows show \(shown)")
        for (row, until) in zip(rows, shown) {
            guard let until else { continue }
            let written = try #require(try writtenRule(["freq": .string("DAILY"), "until": .string(until)], zone: display, allDay: false))
            #expect(starts(F.listing(ics(written), from: from, to: to)) == starts(rows), "\(kind) \(row.summary ?? ""): \(until) written as \(written)")
        }
    }

    @Test("an all-day series' end is its date, which the edit tool writes back to the same occurrences")
    func allDayUntilRoundTrips() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let first = try #require(utc.date(byAdding: .day, value: 30, to: utc.startOfDay(for: Date())))
        let target = try #require(utc.date(byAdding: .day, value: 5, to: first))
        let date = F.dateValue(target, .gmt)
        for bound in [date, "\(date)T235959Z", "\(date)T000000Z"] {
            let rows = F.listing(allDayICS(day: first, rule: "RRULE:FREQ=DAILY;UNTIL=\(bound)"), from: first, to: target.addingTimeInterval(F.days(3)))
            let row = try #require(rows.first)
            for zone in ["UTC", "Pacific/Kiritimati", "America/Los_Angeles"].compactMap(TimeZone.init(identifier:)) {
                let fields = try #require(CalendarRecurrenceFormat.fields(row.recurrence, series: row, zone: zone))
                #expect(fields.until == F.isoDate(target, .gmt), "\(bound) in \(zone.identifier): \(fields.json)")
                let written = try #require(try writtenRule(toolFields(fields.json), zone: zone, allDay: true))
                let now = F.listing(allDayICS(day: first, rule: written), from: first, to: target.addingTimeInterval(F.days(3)))
                #expect(starts(now) == starts(rows), "\(bound) written as \(written)")
                #expect(starts(rows).last == F.isoDate(target, .gmt), "listed \(starts(rows))")
            }
        }
    }

    @Test("an end that can't be read, or a timed series with no zone, keeps its end in other", arguments: [
        ("RRULE:FREQ=DAILY;UNTIL=2099-12-31", "America/Los_Angeles"),
        ("RRULE:FREQ=DAILY;UNTIL=20990230T000000Z", "America/Los_Angeles"),
        ("RRULE:FREQ=DAILY;UNTIL=20991231T250000Z", "America/Los_Angeles"),
        ("RRULE:FREQ=DAILY;UNTIL=20991231T235959Z", "Not/AZone"),
    ])
    func unreadableUntilStaysInOther(_ rule: String, _ zone: String) throws {
        let fields = try #require(CalendarRecurrenceFormat.fields([rule], series: series([rule], zone: zone), zone: .gmt))
        #expect(fields.until == nil && fields.other.contains { $0.hasPrefix("UNTIL=") }, "\(rule) in \(zone): \(fields.json)")
    }
}
