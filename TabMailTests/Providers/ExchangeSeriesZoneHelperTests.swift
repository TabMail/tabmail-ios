/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// `ExchangeCalendarProvider.inSeriesZone` (#719, #747): a timed start or end written to an Outlook series,
// labelled with the series' stored zone name as Graph gives it, at the same instant. Every date is
// relative to today. An all-day date keeps its date and only takes the label (#747).

private func zone(_ name: String) -> TimeZone { CalendarTimeZoneResolver.zone(named: name, in: .none)! }

private func wall(_ date: Date, in name: String) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.calendar = Calendar(identifier: .gregorian)
    fmt.timeZone = zone(name)
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return fmt.string(from: date)
}

/// The instant a Graph `{dateTime, timeZone}` names.
private func instant(_ time: [String: Any]) -> Date? {
    guard let dateTime = time["dateTime"] as? String, let label = time["timeZone"] as? String,
          let tz = CalendarTimeZoneResolver.zone(named: label, in: .none) else { return nil }
    return EKEventStoreHelper.parseNaiveISO(String(dateTime.prefix(19)), timeZone: tz)
}

/// Whether `date`'s wall time in `name` names another instant too (the hour a clock change repeats):
/// read back, it is not `date`.
private func isRepeated(_ date: Date, in name: String) -> Bool {
    EKEventStoreHelper.parseNaiveISO(wall(date, in: name), timeZone: zone(name)) != date
}

private func written(_ date: Date, in name: String) -> [String: Any] { ["dateTime": wall(date, in: name), "timeZone": name] }

/// The next `month`/`day` after today, at `hour`:`minute` in `name`.
private func next(month: Int, day: Int, hour: Int, minute: Int = 0, in name: String) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone(name)
    let match = DateComponents(month: month, day: day, hour: hour, minute: minute)
    return cal.nextDate(after: Date(), matching: match, matchingPolicy: .strict)!
}

/// The `ordinal`-th Sunday of `month` next year, at `hour` UTC.
private func sunday(_ ordinal: Int, of month: Int, hour: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let year = cal.component(.year, from: Date()) + 1
    let comps = DateComponents(year: year, month: month, hour: hour, weekday: 1, weekdayOrdinal: ordinal)
    return cal.date(from: comps)!
}

@Suite("A time written to an Outlook series carries the series' stored zone at the same instant (#719)")
struct ExchangeSeriesZoneHelperTests {

    @Test("U1: a Vancouver time on a series kept in Pacific Standard Time, in winter and in summer")
    func britishColumbia() throws {
        for date in [next(month: 1, day: 15, hour: 10, in: "America/Vancouver"),
                     next(month: 7, day: 15, hour: 10, in: "America/Vancouver")] {
            let given = written(date, in: "America/Vancouver")
            let out = ExchangeCalendarProvider.inSeriesZone(given, seriesZone: "Pacific Standard Time", allDay: false)
            #expect(out["timeZone"] as? String == "Pacific Standard Time", "labelled \(out)")
            #expect(out["dateTime"] as? String == wall(date, in: "America/Los_Angeles"), "\(given) became \(out)")
            #expect(instant(out) == date, "\(given) became \(out), another instant")
        }
    }

    @Test("U2: across the US daylight saving changes of next year, each time is its instant's wall time in the series' zone")
    func daylightSavingEdges() throws {
        // 05:00 to 09:00 UTC spans 01:00 to 04:00 on the US east coast on each change day. The hour
        // repeated in autumn is one wall time for two instants in any `{dateTime, timeZone}`, so
        // there the wall time is checked, and the instant wherever the wall time names one.
        for change in [sunday(2, of: 3, hour: 5), sunday(1, of: 11, hour: 5)] {
            for step in 0...8 {
                let date = change.addingTimeInterval(Double(step) * 1_800)
                let out = ExchangeCalendarProvider.inSeriesZone(written(date, in: "UTC"), seriesZone: "Eastern Standard Time", allDay: false)
                #expect(out["timeZone"] as? String == "Eastern Standard Time", "labelled \(out)")
                #expect(out["dateTime"] as? String == wall(date, in: "America/New_York"), "\(date) became \(out)")
                if !isRepeated(date, in: "America/New_York") {
                    #expect(instant(out) == date, "\(date) became \(out)")
                }
            }
        }
    }

    @Test("U3: across the date line, the date moves with the instant")
    func acrossTheDateLine() throws {
        let date = next(month: 3, day: 10, hour: 8, in: "Asia/Tokyo")
        let given = written(date, in: "Asia/Tokyo")
        let out = ExchangeCalendarProvider.inSeriesZone(given, seriesZone: "Pacific Standard Time", allDay: false)
        #expect(instant(out) == date, "\(given) became \(out)")
        #expect((out["dateTime"] as? String)?.prefix(10) != (given["dateTime"] as? String)?.prefix(10),
                "the date did not move: \(given) became \(out)")
    }

    @Test("U4: zones a quarter or half hour off keep their minutes", arguments: ["Asia/Kolkata", "Asia/Kathmandu"])
    func fractionalOffsets(_ name: String) throws {
        let date = next(month: 2, day: 1, hour: 10, in: name)
        let out = ExchangeCalendarProvider.inSeriesZone(written(date, in: name), seriesZone: "Pacific Standard Time", allDay: false)
        #expect(instant(out) == date, "\(name): became \(out)")
        #expect(out["dateTime"] as? String == wall(date, in: "America/Los_Angeles"), "\(name): became \(out)")
    }

    @Test("U5: a series kept under an IANA name gets that name back verbatim")
    func storedIANAName() throws {
        let date = next(month: 5, day: 5, hour: 9, in: "America/Vancouver")
        let out = ExchangeCalendarProvider.inSeriesZone(written(date, in: "America/Vancouver"), seriesZone: "America/Los_Angeles", allDay: false)
        #expect(out["timeZone"] as? String == "America/Los_Angeles" && instant(out) == date, "became \(out)")
    }

    @Test("U6: a series kept in a zone TabMail does not recognize, or in none, keeps the time as given (#746)")
    func unknownStoredZoneKeepsTheTime() throws {
        let given = written(next(month: 4, day: 2, hour: 9, in: "America/Vancouver"), in: "America/Vancouver")
        for stored in ["Customized Time Zone", nil] as [String?] {
            let out = ExchangeCalendarProvider.inSeriesZone(given, seriesZone: stored, allDay: false)
            #expect(NSDictionary(dictionary: out).isEqual(to: given), "\(stored ?? "none"): \(given) became \(out)")
        }
        let unreadable: [String: Any] = ["dateTime": "not a time", "timeZone": "America/Vancouver"]
        let out = ExchangeCalendarProvider.inSeriesZone(unreadable, seriesZone: "Pacific Standard Time", allDay: false)
        #expect(NSDictionary(dictionary: out).isEqual(to: unreadable), "an unreadable time became \(out)")
    }

    @Test("U7: an all-day date keeps its date and takes the series' stored name verbatim, any name; none keeps it as given (#747)")
    func allDayIsRelabelledOnly() throws {
        let date = String(wall(next(month: 6, day: 1, hour: 0, in: "UTC"), in: "UTC").prefix(10))
        let given: [String: Any] = ["dateTime": "\(date)T00:00:00", "timeZone": "UTC"]
        for stored in ["Pacific Standard Time", "Tokyo Standard Time", "America/Los_Angeles", "Customized Time Zone"] {
            let out = ExchangeCalendarProvider.inSeriesZone(given, seriesZone: stored, allDay: true)
            #expect(out["dateTime"] as? String == "\(date)T00:00:00" && out["timeZone"] as? String == stored, "\(stored): became \(out)")
        }
        for stored in [nil, ""] as [String?] {
            let out = ExchangeCalendarProvider.inSeriesZone(given, seriesZone: stored, allDay: true)
            #expect(NSDictionary(dictionary: out).isEqual(to: given), "\(stored ?? "none"): became \(out)")
        }
    }

    @Test("property: every sampled (label, stored zone, date) keeps its instant and takes the stored name verbatim")
    func instantAndNameProperty() throws {
        let labels = ["America/Vancouver", "America/New_York", "UTC", "Asia/Tokyo", "Asia/Kathmandu",
                      "Pacific/Kiritimati", "Pacific/Pago_Pago", "Australia/Lord_Howe", "Europe/London"]
        let stored = ["Pacific Standard Time", "Eastern Standard Time", "Tokyo Standard Time",
                      "GMT Standard Time", "America/Los_Angeles", "Asia/Kathmandu"]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.startOfDay(for: Date())
        for days in stride(from: 0, through: 365, by: 23) {
            for hour in [0, 7, 13, 23] {
                let date = today.addingTimeInterval(Double(days) * 86_400 + Double(hour) * 3_600 + 900)
                for label in labels {
                    for name in stored {
                        guard !isRepeated(date, in: label) else { continue }
                        let out = ExchangeCalendarProvider.inSeriesZone(written(date, in: label), seriesZone: name, allDay: false)
                        #expect(out["timeZone"] as? String == name && out["dateTime"] as? String == wall(date, in: name),
                                "\(label) at \(date) in \(name) became \(out)")
                        if !isRepeated(date, in: name) {
                            #expect(instant(out) == date, "\(label) at \(date) in \(name) became \(out), another instant")
                        }
                    }
                }
            }
        }
    }
}
