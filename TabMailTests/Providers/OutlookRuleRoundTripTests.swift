//
//  OutlookRuleRoundTripTests.swift
//  TabMailTests
//
//  Every rule the Outlook reader writes for a stored Graph recurrence is one the
//  Outlook refusal accepts, and the writer encodes it back to the stored recurrence.
//

import Testing
import Foundation
@testable import TabMail

@Suite("An Outlook rule read from a stored recurrence is accepted and written back the same")
struct OutlookRuleRoundTripTests {

    private func makeProvider() -> ExchangeCalendarProvider {
        ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" })
    }

    /// A start relative to today, at 10:00 UTC.
    private static let start: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.startOfDay(for: Date())
        return today.addingTimeInterval(10 * 3600)
    }()

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static let indexes = ["first", "second", "third", "fourth", "last"]

    /// Every stored pattern kind, as Graph returns it (unused properties at their defaults).
    private static var patterns: [(label: String, pattern: [String: Any])] {
        func pattern(_ type: String, interval: Int = 1, days: [String] = [], dayOfMonth: Int = 0, month: Int = 0, index: String = "first") -> [String: Any] {
            ["type": type, "interval": interval, "daysOfWeek": days, "dayOfMonth": dayOfMonth, "month": month, "index": index]
        }
        var all: [(String, [String: Any])] = [
            ("daily", pattern("daily")),
            ("daily every 3 days", pattern("daily", interval: 3)),
            ("weekly on one day", pattern("weekly", days: ["monday"])),
            ("weekly on several days every other week", pattern("weekly", interval: 2, days: ["tuesday", "thursday", "saturday"])),
            ("absoluteMonthly", pattern("absoluteMonthly", dayOfMonth: 15)),
            ("absoluteMonthly every 3 months", pattern("absoluteMonthly", interval: 3, dayOfMonth: 1)),
            ("absoluteYearly", pattern("absoluteYearly", dayOfMonth: 15, month: 3)),
        ]
        for index in indexes {
            all.append(("relativeMonthly \(index) Tuesday", pattern("relativeMonthly", days: ["tuesday"], index: index)))
            all.append(("relativeMonthly \(index) Tuesday or Thursday", pattern("relativeMonthly", days: ["tuesday", "thursday"], index: index)))
            all.append(("relativeYearly \(index) Thursday of November", pattern("relativeYearly", days: ["thursday"], month: 11, index: index)))
            all.append(("relativeYearly \(index) Thursday or Friday of November", pattern("relativeYearly", days: ["thursday", "friday"], month: 11, index: index)))
        }
        return all
    }

    private static var ranges: [(label: String, range: [String: Any])] {
        let startDate = day(start)
        return [
            ("noEnd", ["type": "noEnd", "startDate": startDate, "endDate": "0001-01-01", "numberOfOccurrences": 0, "recurrenceTimeZone": "UTC"]),
            ("endDate", ["type": "endDate", "startDate": startDate, "endDate": day(start.addingTimeInterval(400 * 86_400)),
                         "numberOfOccurrences": 0, "recurrenceTimeZone": "UTC"]),
            ("numbered", ["type": "numbered", "startDate": startDate, "endDate": "0001-01-01", "numberOfOccurrences": 7, "recurrenceTimeZone": "UTC"]),
        ]
    }

    /// The properties that say what a stored recurrence means, for its pattern and range types:
    /// what Graph reads, with a relative pattern's missing index as its default.
    private static func meaning(_ recurrence: [String: Any]) -> [String: String] {
        let pattern = recurrence["pattern"] as? [String: Any] ?? [:]
        let range = recurrence["range"] as? [String: Any] ?? [:]
        let type = pattern["type"] as? String ?? ""
        var out: [String: String] = ["type": type, "interval": "\(pattern["interval"] as? Int ?? 1)",
                                     "firstDayOfWeek": pattern["firstDayOfWeek"] as? String ?? "sunday"]
        if ["weekly", "relativeMonthly", "relativeYearly"].contains(type) {
            out["daysOfWeek"] = (pattern["daysOfWeek"] as? [String] ?? []).sorted().joined(separator: ",")
        }
        if ["absoluteMonthly", "absoluteYearly"].contains(type) { out["dayOfMonth"] = "\(pattern["dayOfMonth"] as? Int ?? 0)" }
        if ["absoluteYearly", "relativeYearly"].contains(type) { out["month"] = "\(pattern["month"] as? Int ?? 0)" }
        if ["relativeMonthly", "relativeYearly"].contains(type) {
            out["index"] = ExchangeCalendarProvider.storedIndex(type: type, index: pattern["index"] as? String)
        }
        let rangeType = range["type"] as? String ?? ""
        out["range"] = rangeType
        if rangeType == "endDate" { out["endDate"] = range["endDate"] as? String }
        if rangeType == "numbered" { out["numberOfOccurrences"] = "\(range["numberOfOccurrences"] as? Int ?? 0)" }
        return out
    }

    @Test("every stored pattern, range and first day of the week reads as a rule Outlook accepts and writes back the same")
    func everyStoredRecurrenceRoundTrips() throws {
        let provider = makeProvider()
        var failures: [String] = []
        var cases = 0
        for (patternLabel, basePattern) in Self.patterns {
            for (rangeLabel, range) in Self.ranges {
                for firstDay in ["sunday", "monday"] {
                    cases += 1
                    let label = "\(patternLabel), \(rangeLabel), weeks from \(firstDay)"
                    var pattern = basePattern
                    pattern["firstDayOfWeek"] = firstDay
                    let stored: [String: Any] = ["pattern": pattern, "range": range]
                    let data = try JSONSerialization.data(withJSONObject: stored)
                    let decoded = try JSONDecoder().decode(MSPatternedRecurrence.self, from: data)
                    guard let rule = ExchangeCalendarProvider.rrule(decoded).first else {
                        failures.append("\(label): no rule read"); continue
                    }
                    if let refusal = provider.recurrenceRuleRefusal(rule) {
                        failures.append("\(label): \(rule) refused: \(refusal)"); continue
                    }
                    var input = GCalEventInput()
                    input.recurrence = [rule]
                    input.startDateTime = ISO8601DateFormatter().string(from: Self.start)
                    input.startTimeZone = "UTC"
                    guard let rebuilt = provider.toGraphEventJSON(input, firstDayOfWeek: firstDay)["recurrence"] as? [String: Any] else {
                        failures.append("\(label): \(rule) wrote no recurrence"); continue
                    }
                    if Self.meaning(rebuilt) != Self.meaning(stored) {
                        failures.append("\(label): \(rule) wrote \(Self.meaning(rebuilt)), stored \(Self.meaning(stored))")
                    }
                    if !ExchangeCalendarProvider.sameRule(rebuilt, as: stored) {
                        failures.append("\(label): \(rule) is not the stored rule to the edit's comparison")
                    }
                }
            }
        }
        #expect(cases == Self.patterns.count * Self.ranges.count * 2)
        #expect(failures.isEmpty, "\(failures.count) of \(cases) cases:\n\(failures.joined(separator: "\n"))")
    }

    @Test("Outlook accepts a position over plain weekdays, monthly or yearly with the month",
          arguments: ["RRULE:FREQ=MONTHLY;BYDAY=TU,TH;BYSETPOS=2", "RRULE:FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1",
                      "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=TH,FR;BYSETPOS=4"])
    func acceptsPositionOverWeekdays(_ rule: String) {
        #expect(makeProvider().recurrenceRuleRefusal(rule) == nil, "\(rule) refused")
    }

    @Test("Outlook refuses every other position by name",
          arguments: ["RRULE:FREQ=WEEKLY;BYDAY=MO;BYSETPOS=1", "RRULE:FREQ=DAILY;BYSETPOS=1",
                      "RRULE:FREQ=MONTHLY;BYDAY=MO,TU;BYSETPOS=1,2", "RRULE:FREQ=MONTHLY;BYDAY=MO;BYSETPOS=5",
                      "RRULE:FREQ=MONTHLY;BYDAY=MO;BYSETPOS=-2", "RRULE:FREQ=MONTHLY;BYSETPOS=1",
                      "RRULE:FREQ=MONTHLY;BYDAY=2MO;BYSETPOS=1", "RRULE:FREQ=MONTHLY;BYMONTHDAY=1;BYSETPOS=1",
                      "RRULE:FREQ=YEARLY;BYDAY=MO;BYSETPOS=1", "RRULE:FREQ=MONTHLY;BYDAY=MO;BYSETPOS=X"])
    func refusesOtherPositions(_ rule: String) {
        let refusal = makeProvider().recurrenceRuleRefusal(rule)
        #expect(refusal?.contains("recurrence.bySetPos") == true, "\(rule): \(refusal ?? "accepted")")
    }
}
