/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// `RecurrenceTail.occurrences` against the worked examples of RFC 5545
/// §3.8.5.3, whose occurrence lists are the oracle. The examples' 1997 dates
/// are kept because the RFC lists their occurrences; the functions under test
/// read no clock, so nothing here can go stale.
@Suite("RecurrenceTail — counting occurrences before a split")
struct RecurrenceTailCountTests {

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let rrule: String
        let start: String
        let split: String
        let expected: Int?
        var testDescription: String { name }
    }

    static let rfcCases: [Case] = [
        Case(name: "daily for 10: 2, 3, 4 Sep before the 5th",
             rrule: "RRULE:FREQ=DAILY;COUNT=10", start: "1997-09-02", split: "1997-09-05", expected: 3),
        Case(name: "every other day: 2, 4, 6, 8 Sep before the 9th",
             rrule: "RRULE:FREQ=DAILY;INTERVAL=2", start: "1997-09-02", split: "1997-09-09", expected: 4),
        Case(name: "every 10 days, 5 occurrences: 2, 12, 22 Sep before 2 Oct",
             rrule: "RRULE:FREQ=DAILY;INTERVAL=10;COUNT=5", start: "1997-09-02", split: "1997-10-02", expected: 3),
        Case(name: "every day in January, as DAILY limited by BYMONTH",
             rrule: "RRULE:FREQ=DAILY;BYMONTH=1", start: "1998-01-01", split: "1999-01-03", expected: 33),
        Case(name: "every day in January, as YEARLY expanded by BYDAY",
             rrule: "RRULE:FREQ=YEARLY;BYMONTH=1;BYDAY=SU,MO,TU,WE,TH,FR,SA", start: "1998-01-01", split: "1999-01-03", expected: 33),
        Case(name: "weekly for 10: 2, 9, 16 Sep before the 23rd",
             rrule: "RRULE:FREQ=WEEKLY;COUNT=10", start: "1997-09-02", split: "1997-09-23", expected: 3),
        Case(name: "weekly on Tuesday and Thursday: 2, 4, 9, 11 Sep before the 16th",
             rrule: "RRULE:FREQ=WEEKLY;COUNT=10;WKST=SU;BYDAY=TU,TH", start: "1997-09-02", split: "1997-09-16", expected: 4),
        Case(name: "every other week on MO, WE, FR: 1, 3, 5, 15, 17, 19, 29 Sep, 1, 3 Oct before the 13th",
             rrule: "RRULE:FREQ=WEEKLY;INTERVAL=2;WKST=SU;UNTIL=19971224T000000Z;BYDAY=MO,WE,FR", start: "1997-09-01", split: "1997-10-13", expected: 9),
        Case(name: "WKST=MO: 5, 10, 19, 24 Aug before the 25th",
             rrule: "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=MO", start: "1997-08-05", split: "1997-08-25", expected: 4),
        Case(name: "WKST=SU on the same rule: 5, 17, 19 Aug before the 25th",
             rrule: "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU", start: "1997-08-05", split: "1997-08-25", expected: 3),
        Case(name: "monthly on the first Friday: 5 Sep, 3 Oct, 7 Nov, 5 Dec before 1998",
             rrule: "RRULE:FREQ=MONTHLY;COUNT=10;BYDAY=1FR", start: "1997-09-05", split: "1998-01-01", expected: 4),
        Case(name: "every other month on the first and last Sunday: 7, 28 Sep, 2, 30 Nov, 4, 25 Jan before 26 Jan",
             rrule: "RRULE:FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=1SU,-1SU", start: "1997-09-07", split: "1998-01-26", expected: 6),
        Case(name: "monthly on the second-to-last Monday: 22 Sep, 20 Oct, 17 Nov before 22 Dec",
             rrule: "RRULE:FREQ=MONTHLY;COUNT=6;BYDAY=-2MO", start: "1997-09-22", split: "1997-12-22", expected: 3),
        Case(name: "monthly on the third-to-last day: 28 Sep, 29 Oct, 28 Nov, 29 Dec before 1998",
             rrule: "RRULE:FREQ=MONTHLY;BYMONTHDAY=-3", start: "1997-09-28", split: "1998-01-01", expected: 4),
        Case(name: "monthly on the 2nd and 15th: 2, 15 Sep, 2, 15 Oct before 2 Nov",
             rrule: "RRULE:FREQ=MONTHLY;COUNT=10;BYMONTHDAY=2,15", start: "1997-09-02", split: "1997-11-02", expected: 4),
        Case(name: "monthly on the 15th and 30th skips 30 Feb: 15, 30 Jan, 15 Feb, 15 Mar before the 16th",
             rrule: "RRULE:FREQ=MONTHLY;BYMONTHDAY=15,30;COUNT=5", start: "2007-01-15", split: "2007-03-16", expected: 4),
        Case(name: "yearly in June and July: 10 Jun, 10 Jul in 1997 and 1998",
             rrule: "RRULE:FREQ=YEARLY;COUNT=10;BYMONTH=6,7", start: "1997-06-10", split: "1999-01-01", expected: 4),
        Case(name: "every Thursday in March: 13, 20, 27 Mar 1997, 5, 12 Mar 1998 before the 19th",
             rrule: "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=TH", start: "1997-03-13", split: "1998-03-19", expected: 5),
        Case(name: "the 20th Monday of the year: 19 May 1997, 18 May 1998",
             rrule: "RRULE:FREQ=YEARLY;BYDAY=20MO", start: "1997-05-19", split: "1999-01-01", expected: 2),
        Case(name: "Friday the 13th: DTSTART counts though it is not one, then 13 Feb, 13 Mar, 13 Nov 1998",
             rrule: "RRULE:FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13", start: "1997-09-02", split: "1998-12-01", expected: 4),
        Case(name: "US election day every 4 years: 5 Nov 1996, 7 Nov 2000 before 2 Nov 2004",
             rrule: "RRULE:FREQ=YEARLY;INTERVAL=4;BYMONTH=11;BYDAY=TU;BYMONTHDAY=2,3,4,5,6,7,8", start: "1996-11-05", split: "2004-11-02", expected: 2),
        Case(name: "the third Tuesday, Wednesday or Thursday of the month: 4 Sep, 7 Oct before November",
             rrule: "RRULE:FREQ=MONTHLY;COUNT=3;BYDAY=TU,WE,TH;BYSETPOS=3", start: "1997-09-04", split: "1997-11-01", expected: 2),
        Case(name: "the last weekday of the month: 30 Sep, 31 Oct, 28 Nov, 31 Dec, 30 Jan, 27 Feb before March",
             rrule: "RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", start: "1997-09-30", split: "1998-03-01", expected: 6),
    ]

    static let derivedCases: [Case] = [
        Case(name: "a step almost as long as every four-digit year still places its second occurrence",
             rrule: "RRULE:FREQ=DAILY;INTERVAL=3652423;COUNT=3", start: "0000-01-01", split: "9999-12-31", expected: 2),
        Case(name: "monthly from the 31st skips the shorter months: 31 Jan, 31 Mar, 31 May",
             rrule: "RRULE:FREQ=MONTHLY", start: "1997-01-31", split: "1997-06-01", expected: 3),
        Case(name: "yearly from 29 Feb lands only in leap years: 2000, 2004, 2008",
             rrule: "RRULE:FREQ=YEARLY", start: "2000-02-29", split: "2009-01-01", expected: 3),
        Case(name: "the first Monday of March, yearly: 3 Mar 1997, 2 Mar 1998 before 1 Mar 1999",
             rrule: "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=MO;BYSETPOS=1", start: "1997-03-03", split: "1999-03-01", expected: 2),
        Case(name: "weekly with no BYDAY repeats DTSTART's weekday, every 3rd week",
             rrule: "RRULE:FREQ=WEEKLY;INTERVAL=3", start: "1997-09-02", split: "1997-10-15", expected: 3),
        Case(name: "the rule's own spelling is case-insensitive and needs no RRULE: prefix",
             rrule: "freq=daily;count=10", start: "1997-09-02", split: "1997-09-05", expected: 3),
        Case(name: "a split on the first day keeps nothing before it",
             rrule: "RRULE:FREQ=DAILY;COUNT=10", start: "1997-09-02", split: "1997-09-02", expected: 0),
        Case(name: "a split before the first day keeps nothing before it",
             rrule: "RRULE:FREQ=DAILY;COUNT=10", start: "1997-09-02", split: "1997-08-30", expected: 0),
        Case(name: "the day after the first keeps only DTSTART",
             rrule: "RRULE:FREQ=DAILY;COUNT=10", start: "1997-09-02", split: "1997-09-03", expected: 1),
        Case(name: "daily on weekdays: two working weeks",
             rrule: "RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR", start: "1997-09-01", split: "1997-09-15", expected: 10),
        Case(name: "daily limited to the 1st and 15th: 1 and 15 Sep, 1 and 15 Oct",
             rrule: "RRULE:FREQ=DAILY;BYMONTHDAY=1,15", start: "1997-09-01", split: "1997-11-01", expected: 4),
        Case(name: "weekly on Tuesdays, January only: the four January Tuesdays of 1998",
             rrule: "RRULE:FREQ=WEEKLY;BYMONTH=1;BYDAY=TU", start: "1998-01-06", split: "1998-03-01", expected: 4),
        Case(name: "monthly on the 15th, January and July only: 15 Jan and 15 Jul 1998",
             rrule: "RRULE:FREQ=MONTHLY;BYMONTH=1,7;BYMONTHDAY=15", start: "1998-01-15", split: "1999-01-01", expected: 2),
        Case(name: "yearly with BYMONTHDAY expands to every month: 1 Jan, 1 Feb, 1 Mar",
             rrule: "RRULE:FREQ=YEARLY;BYMONTHDAY=1", start: "1998-01-01", split: "1998-04-01", expected: 3),
    ]

    static let unsupportedCases: [Case] = [
        Case(name: "BYYEARDAY", rrule: "RRULE:FREQ=YEARLY;INTERVAL=3;COUNT=10;BYYEARDAY=1,100,200", start: "1997-01-01", split: "2000-01-01", expected: nil),
        Case(name: "BYWEEKNO", rrule: "RRULE:FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO", start: "1997-05-12", split: "1999-01-01", expected: nil),
        Case(name: "BYHOUR", rrule: "RRULE:FREQ=DAILY;BYHOUR=9,10;COUNT=4", start: "1997-09-02", split: "1997-09-05", expected: nil),
        Case(name: "FREQ below DAILY", rrule: "RRULE:FREQ=HOURLY;INTERVAL=3;COUNT=4", start: "1997-09-02", split: "1997-09-05", expected: nil),
        Case(name: "an unknown part", rrule: "RRULE:FREQ=DAILY;X-NAME=1;COUNT=4", start: "1997-09-02", split: "1997-09-05", expected: nil),
        Case(name: "BYMONTHDAY with WEEKLY", rrule: "RRULE:FREQ=WEEKLY;BYMONTHDAY=2;COUNT=4", start: "1997-09-02", split: "1997-12-05", expected: nil),
        Case(name: "a numbered BYDAY with DAILY", rrule: "RRULE:FREQ=DAILY;BYDAY=1MO;COUNT=4", start: "1997-09-02", split: "1997-12-05", expected: nil),
        Case(name: "a numbered BYDAY with WEEKLY", rrule: "RRULE:FREQ=WEEKLY;BYDAY=1MO;COUNT=4", start: "1997-09-02", split: "1997-12-05", expected: nil),
        Case(name: "a numbered BYDAY with BYMONTHDAY", rrule: "RRULE:FREQ=MONTHLY;BYDAY=1FR;BYMONTHDAY=13;COUNT=4", start: "1997-09-02", split: "1997-12-05", expected: nil),
        Case(name: "BYSETPOS with WEEKLY", rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO,TU;BYSETPOS=1;COUNT=4", start: "1997-09-01", split: "1997-12-05", expected: nil),
        Case(name: "BYSETPOS with YEARLY and no BYMONTH", rrule: "RRULE:FREQ=YEARLY;BYDAY=MO;BYSETPOS=1;COUNT=4", start: "1997-01-06", split: "1999-12-05", expected: nil),
        Case(name: "BYSETPOS over numbered BYDAY", rrule: "RRULE:FREQ=MONTHLY;BYDAY=1MO,2TU;BYSETPOS=1;COUNT=4", start: "1997-09-01", split: "1997-12-05", expected: nil),
        Case(name: "BYSETPOS over BYMONTHDAY", rrule: "RRULE:FREQ=MONTHLY;BYMONTHDAY=1,2;BYSETPOS=1;COUNT=4", start: "1997-09-01", split: "1997-12-05", expected: nil),
        Case(name: "BYSETPOS with no BYDAY", rrule: "RRULE:FREQ=MONTHLY;BYSETPOS=1;COUNT=4", start: "1997-09-01", split: "1997-12-05", expected: nil),
        Case(name: "a month out of range", rrule: "RRULE:FREQ=YEARLY;BYMONTH=13;COUNT=4", start: "1997-09-02", split: "1999-12-05", expected: nil),
        Case(name: "a zero INTERVAL", rrule: "RRULE:FREQ=DAILY;INTERVAL=0;COUNT=4", start: "1997-09-02", split: "1997-09-05", expected: nil),
        Case(name: "a part given twice", rrule: "RRULE:FREQ=DAILY;INTERVAL=2;INTERVAL=3;COUNT=4", start: "1997-09-02", split: "1997-09-05", expected: nil),
        Case(name: "a weekday code that does not exist", rrule: "RRULE:FREQ=WEEKLY;BYDAY=XX;COUNT=4", start: "1997-09-02", split: "1997-09-05", expected: nil),
        Case(name: "no FREQ", rrule: "RRULE:COUNT=4", start: "1997-09-02", split: "1997-09-05", expected: nil),
        // Numbers that would overflow the counter's arithmetic, or trap in `abs`.
        Case(name: "a YEARLY INTERVAL past any four-digit year", rrule: "RRULE:FREQ=YEARLY;INTERVAL=30000000000000000;COUNT=3", start: "1997-09-02", split: "1999-09-05", expected: nil),
        Case(name: "a DAILY INTERVAL of Int.max", rrule: "RRULE:FREQ=DAILY;INTERVAL=9223372036854775807;COUNT=3", start: "1997-09-02", split: "1997-09-05", expected: nil),
        Case(name: "a WEEKLY INTERVAL of Int.max", rrule: "RRULE:FREQ=WEEKLY;INTERVAL=9223372036854775807;COUNT=3", start: "1997-09-02", split: "1997-09-05", expected: nil),
        Case(name: "a MONTHLY INTERVAL of Int.max", rrule: "RRULE:FREQ=MONTHLY;INTERVAL=9223372036854775807;COUNT=3", start: "1997-09-02", split: "1997-12-05", expected: nil),
        Case(name: "a BYMONTH of Int.min", rrule: "RRULE:FREQ=YEARLY;BYMONTH=-9223372036854775808;COUNT=3", start: "1997-09-02", split: "1999-12-05", expected: nil),
        Case(name: "a BYMONTHDAY of Int.min", rrule: "RRULE:FREQ=MONTHLY;BYMONTHDAY=-9223372036854775808;COUNT=3", start: "1997-09-02", split: "1997-12-05", expected: nil),
        Case(name: "a BYSETPOS of Int.min", rrule: "RRULE:FREQ=MONTHLY;BYDAY=MO;BYSETPOS=-9223372036854775808;COUNT=3", start: "1997-09-01", split: "1997-12-05", expected: nil),
        Case(name: "a BYDAY number of Int.min", rrule: "RRULE:FREQ=MONTHLY;BYDAY=-9223372036854775808MO;COUNT=3", start: "1997-09-01", split: "1997-12-05", expected: nil),
    ]

    @Test("RFC 5545 examples", arguments: rfcCases)
    func rfcExamples(_ c: Case) throws {
        try check(c)
    }

    @Test("Edges the RFC states in prose", arguments: derivedCases)
    func derivedEdges(_ c: Case) throws {
        try check(c)
    }

    @Test("Rules outside the supported subset are not counted", arguments: unsupportedCases)
    func unsupportedRules(_ c: Case) throws {
        try check(c)
    }

    @Test("INTERVAL is counted up to its bound and not above it")
    func intervalBound() throws {
        let start = try #require(RecurrenceTail.Day(iso: "1997-09-02"))
        let split = try #require(RecurrenceTail.Day(iso: "1997-09-05"))
        for freq in ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"] {
            let atBound = "RRULE:FREQ=\(freq);INTERVAL=\(RecurrenceTail.maxInterval)"
            let aboveBound = "RRULE:FREQ=\(freq);INTERVAL=\(RecurrenceTail.maxInterval + 1)"
            #expect(RecurrenceTail.occurrences(of: atBound, seriesStart: start, before: split) == 1,
                    "\(freq): only DTSTART falls before the split")
            #expect(RecurrenceTail.occurrences(of: aboveBound, seriesStart: start, before: split) == nil, "\(freq)")
        }
    }

    private func check(_ c: Case) throws {
        let start = try #require(RecurrenceTail.Day(iso: c.start))
        let split = try #require(RecurrenceTail.Day(iso: c.split))
        #expect(RecurrenceTail.occurrences(of: c.rrule, seriesStart: start, before: split) == c.expected)
    }

    @Test("Days parse from both value spellings and reject days a month does not have")
    func dayParsing() {
        #expect(RecurrenceTail.Day(iso: "2099-02-28T17:00:00") == RecurrenceTail.Day(ical: "20990228T170000Z"))
        #expect(RecurrenceTail.Day(ical: "20990228")?.description == "2099-02-28")
        #expect(RecurrenceTail.Day(iso: "2099-02-29") == nil, "2099 is not a leap year")
        #expect(RecurrenceTail.Day(iso: "2100-02-29") == nil, "a century not divisible by 400 is not a leap year")
        #expect(RecurrenceTail.Day(iso: "2400-02-29") != nil, "a century divisible by 400 is")
        #expect(RecurrenceTail.Day(iso: "2099-13-01") == nil)
        #expect(RecurrenceTail.Day(iso: "20990228") == nil, "an iCalendar value is not an ISO one")
        #expect(RecurrenceTail.Day(ical: "2099-02-28") == nil, "an ISO value is not an iCalendar one")
    }
}

/// `RecurrenceTail.newSeriesRule`: the rule a split's new series is written
/// with. Dates are in 2099 so no clock can make them stale.
@Suite("RecurrenceTail — the new series' end")
struct RecurrenceTailNewSeriesRuleTests {

    private static let start = RecurrenceTail.Day(iso: "2099-03-02")
    /// Four days after `start`: a DAILY series keeps 2, 3, 4 and 5 March before it.
    private static let split = RecurrenceTail.Day(iso: "2099-03-06")
    /// What `googleUntilString` caps a timed series split at 2099-03-06T17:00:00Z with.
    private static let timedCap = "20990306T165959Z"
    /// What it caps an all-day series split on 2099-03-06 with.
    private static let allDayCap = "20990305"

    private func rule(_ rrule: String, start: RecurrenceTail.Day? = start, split: RecurrenceTail.Day? = split, cap: String = timedCap) throws -> String {
        try RecurrenceTail.newSeriesRule(from: rrule, seriesStart: start, split: split, capUntil: cap)
    }

    private func refuses(_ rrule: String, start: RecurrenceTail.Day? = start, split: RecurrenceTail.Day? = split, cap: String = timedCap) -> Bool {
        do {
            _ = try rule(rrule, start: start, split: split, cap: cap)
            return false
        } catch CalendarProviderError.notSupported(let message) {
            return !message.isEmpty
        } catch {
            return false
        }
    }

    /// The refusal's message; fails the test when the rule is not refused.
    private func refusal(_ rrule: String, start: RecurrenceTail.Day? = start, split: RecurrenceTail.Day? = split) throws -> String {
        do {
            let written = try rule(rrule, start: start, split: split)
            Issue.record("expected a refusal, got \(written)")
            return ""
        } catch CalendarProviderError.notSupported(let message) {
            return message
        }
    }

    @Test("A series with no end keeps its rule unchanged")
    func noEnd() throws {
        #expect(try rule("RRULE:FREQ=WEEKLY;BYDAY=MO,WE") == "RRULE:FREQ=WEEKLY;BYDAY=MO,WE")
        #expect(try rule("FREQ=WEEKLY;BYDAY=MO,WE") == "RRULE:FREQ=WEEKLY;BYDAY=MO,WE")
    }

    @Test("COUNT becomes what is left after the occurrences before the split, in place")
    func countIsReduced() throws {
        #expect(try rule("RRULE:FREQ=DAILY;COUNT=10;INTERVAL=1") == "RRULE:FREQ=DAILY;COUNT=6;INTERVAL=1")
        #expect(try rule("RRULE:freq=daily;count=10") == "RRULE:freq=daily;COUNT=6")
        #expect(try rule("RRULE:FREQ=DAILY;COUNT=5") == "RRULE:FREQ=DAILY;COUNT=1",
                "the split occurrence itself is the last one")
    }

    @Test("A COUNT used up before the split is refused, not clamped")
    func countUsedUpIsRefused() {
        #expect(refuses("RRULE:FREQ=DAILY;COUNT=4"), "2, 3, 4 and 5 March are all four occurrences")
        #expect(refuses("RRULE:FREQ=DAILY;COUNT=1"))
    }

    @Test("A COUNT that cannot be counted is refused")
    func uncountableCountIsRefused() {
        #expect(refuses("RRULE:FREQ=YEARLY;BYYEARDAY=1;COUNT=10"))
        #expect(refuses("RRULE:FREQ=DAILY;COUNT=10", start: nil))
        #expect(refuses("RRULE:FREQ=DAILY;COUNT=10", split: nil))
        #expect(refuses("RRULE:FREQ=DAILY;COUNT=0"))
        #expect(refuses("RRULE:FREQ=DAILY;COUNT=ten"))
    }

    @Test("The refusal names its cause: dates that can't be read, or a rule that can't be counted")
    func uncountableRefusalNamesItsCause() throws {
        let datesPhrase = "the dates of its first occurrence"
        for message in [try refusal("RRULE:FREQ=DAILY;COUNT=10", start: nil),
                        try refusal("RRULE:FREQ=DAILY;COUNT=10", split: nil)] {
            #expect(message.contains(datesPhrase), "got \(message)")
            #expect(!message.contains("not one TabMail can count"), "got \(message)")
        }
        let uncountable = try refusal("RRULE:FREQ=YEARLY;BYYEARDAY=1;COUNT=10")
        #expect(uncountable.contains("(FREQ=YEARLY;BYYEARDAY=1;COUNT=10) is not one TabMail can count"), "got \(uncountable)")
        #expect(!uncountable.contains(datesPhrase), "got \(uncountable)")
    }

    @Test("A COUNT rule whose numbers would overflow the counter is refused, not a crash")
    func overflowingCountIsRefused() {
        #expect(refuses("RRULE:FREQ=YEARLY;INTERVAL=30000000000000000;COUNT=3"))
        #expect(refuses("RRULE:FREQ=DAILY;INTERVAL=9223372036854775807;COUNT=3"))
        #expect(refuses("RRULE:FREQ=MONTHLY;BYMONTHDAY=-9223372036854775808;COUNT=3"))
    }

    @Test("A UTC UNTIL at or after the split is kept verbatim")
    func utcUntilAfterIsKept() throws {
        #expect(try rule("RRULE:FREQ=DAILY;UNTIL=20991231T235959Z") == "RRULE:FREQ=DAILY;UNTIL=20991231T235959Z")
        // The split instant itself: UNTIL is inclusive, so the split occurrence is in the series.
        #expect(try rule("RRULE:FREQ=DAILY;UNTIL=20990306T170000Z") == "RRULE:FREQ=DAILY;UNTIL=20990306T170000Z")
    }

    @Test("A UTC UNTIL before the split is refused")
    func utcUntilBeforeIsRefused() {
        #expect(refuses("RRULE:FREQ=DAILY;UNTIL=20990306T165958Z"), "one second before the cap")
        #expect(refuses("RRULE:FREQ=DAILY;UNTIL=20990304T170000Z"))
    }

    @Test("An UNTIL equal to this split's own cap ends the series before the split: refused, never an open end (#601)")
    func ownCapIsRefused() {
        // A series that already carries the split's cap is finished from the split's record
        // (`finishSplit`), never by running the split again; a new part with no end would be a
        // series the user never had.
        #expect(refuses("RRULE:FREQ=DAILY;UNTIL=20990306T165959Z"))
        #expect(refuses("RRULE:FREQ=DAILY;until=20990306t165959z"))
        #expect(refuses("RRULE:FREQ=DAILY;UNTIL=20990305", cap: Self.allDayCap))
    }

    @Test("endsBeforeSplit: a series already ending at or before the split's cap ends before it (#601)")
    func endsBeforeSplitReadsEveryEnd() throws {
        func ends(_ rrule: String, start: RecurrenceTail.Day? = Self.start, cap: String = Self.timedCap,
                  anchor: RecurrenceTail.Anchor = .dtstart, missingDay: RecurrenceTail.MissingMonthDay = .skip) throws -> Bool {
            try RecurrenceTail.endsBeforeSplit(
                rrule, seriesStart: start, split: Self.split, capUntil: cap, anchor: anchor, missingDay: missingDay)
        }
        // No end: never.
        #expect(try ends("RRULE:FREQ=DAILY") == false)
        // UNTIL: its own cap, and anything before it, ends before; the split instant and later do not.
        #expect(try ends("RRULE:FREQ=DAILY;UNTIL=20990306T165959Z"))
        #expect(try ends("RRULE:FREQ=DAILY;UNTIL=20990306T165958Z"))
        #expect(try ends("RRULE:FREQ=DAILY;UNTIL=20990306T170000Z") == false)
        #expect(try ends("RRULE:FREQ=DAILY;UNTIL=20991231T235959Z") == false)
        // A DATE UNTIL covers its whole day.
        #expect(try ends("RRULE:FREQ=DAILY;UNTIL=20990305", cap: Self.allDayCap))
        #expect(try ends("RRULE:FREQ=DAILY;UNTIL=20990306", cap: Self.allDayCap) == false)
        // COUNT: 2, 3, 4 and 5 March are before the split, so four ends before it and five does not.
        #expect(try ends("RRULE:FREQ=DAILY;COUNT=4"))
        #expect(try ends("RRULE:FREQ=DAILY;COUNT=3"))
        #expect(try ends("RRULE:FREQ=DAILY;COUNT=5") == false)
    }

    @Test("endsBeforeSplit refuses what it can't tell, rather than guessing either way")
    func endsBeforeSplitRefusesTheUndecidable() {
        for (rrule, start) in [("RRULE:FREQ=DAILY;COUNT=4", nil as RecurrenceTail.Day?),
                               ("RRULE:FREQ=YEARLY;BYYEARDAY=1;COUNT=4", Self.start),
                               ("RRULE:FREQ=DAILY;COUNT=0", Self.start),
                               ("RRULE:FREQ=DAILY;COUNT=4;UNTIL=20990310", Self.start)] {
            #expect(throws: CalendarProviderError.self, "\(rrule)") {
                try RecurrenceTail.endsBeforeSplit(rrule, seriesStart: start, split: Self.split, capUntil: Self.timedCap)
            }
        }
    }

    @Test("A DATE UNTIL covers its whole day")
    func dateUntilIsInclusive() throws {
        #expect(try rule("RRULE:FREQ=DAILY;UNTIL=20990306") == "RRULE:FREQ=DAILY;UNTIL=20990306",
                "an UNTIL on the split day includes the split occurrence")
        #expect(try rule("RRULE:FREQ=DAILY;UNTIL=20990310", cap: Self.allDayCap) == "RRULE:FREQ=DAILY;UNTIL=20990310")
        #expect(refuses("RRULE:FREQ=DAILY;UNTIL=20990305"), "against a timed cap, the day before the split is before it")
        #expect(refuses("RRULE:FREQ=DAILY;UNTIL=20990304", cap: Self.allDayCap))
        #expect(refuses("RRULE:FREQ=DAILY;UNTIL=20990310", split: nil), "a DATE UNTIL needs the split's day")
    }

    @Test("A rule with two ends is refused")
    func twoEndsAreRefused() {
        #expect(refuses("RRULE:FREQ=DAILY;COUNT=10;UNTIL=20991231T235959Z"))
        #expect(refuses("RRULE:FREQ=DAILY;COUNT=10;COUNT=12"))
    }
}

/// `RecurrenceTail.newSeriesEnd` and its two anchors: RFC 5545's DTSTART, always the first
/// occurrence, and Outlook's range `startDate`, an occurrence only when the pattern names its day.
/// Dates are in 2099 so no clock can make them stale: 2099-03-02 is a Monday, 2099-03-03 and
/// 2099-03-31 are Tuesdays.
@Suite("RecurrenceTail — what is left of a numbered series")
struct RecurrenceTailNewSeriesEndTests {

    private static let monday = RecurrenceTail.Day(iso: "2099-03-02")
    private static let tuesday = RecurrenceTail.Day(iso: "2099-03-03")
    /// Four Tuesdays after `tuesday`'s: the 3rd, 10th, 17th and 24th come before it.
    private static let split = RecurrenceTail.Day(iso: "2099-03-31")
    private static let tuesdays = "RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=6"

    @Test("A range starting before the pattern's first day does not count that day; DTSTART always counts")
    func anchorsCountTheStartDayDifferently() throws {
        let monday = try #require(Self.monday)
        let tuesday = try #require(Self.tuesday)
        let split = try #require(Self.split)
        #expect(RecurrenceTail.occurrences(of: Self.tuesdays, seriesStart: monday, before: split, anchor: .patternStart) == 4,
                "the Monday the range starts on is no occurrence of a Tuesday series")
        #expect(RecurrenceTail.occurrences(of: Self.tuesdays, seriesStart: monday, before: split, anchor: .dtstart) == 5,
                "RFC 5545: DTSTART is the first occurrence whatever the rule names")
        #expect(RecurrenceTail.occurrences(of: Self.tuesdays, seriesStart: tuesday, before: split, anchor: .patternStart) == 4)
        #expect(RecurrenceTail.occurrences(of: Self.tuesdays, seriesStart: tuesday, before: split, anchor: .dtstart) == 4)
    }

    @Test("The new series gets the count less the occurrences before the split, so the two hold the count between them")
    func whatIsLeft() throws {
        #expect(try RecurrenceTail.newSeriesEnd(count: 6, of: Self.tuesdays, seriesStart: Self.monday, split: Self.split, anchor: .patternStart) == 2)
        #expect(try RecurrenceTail.newSeriesEnd(count: 6, of: Self.tuesdays, seriesStart: Self.tuesday, split: Self.split, anchor: .patternStart) == 2)
        #expect(try RecurrenceTail.newSeriesEnd(count: 5, of: Self.tuesdays, seriesStart: Self.tuesday, split: Self.split) == 1,
                "the split occurrence itself is the last one")
    }

    @Test("Nothing left from the split on, or a count that can't be worked out, is refused")
    func refusals() {
        func refuses(_ count: Int, start: RecurrenceTail.Day?, split: RecurrenceTail.Day?, rule: String = Self.tuesdays) -> Bool {
            do {
                _ = try RecurrenceTail.newSeriesEnd(count: count, of: rule, seriesStart: start, split: split, anchor: .patternStart)
                return false
            } catch CalendarProviderError.notSupported(let message) {
                return !message.isEmpty
            } catch {
                return false
            }
        }
        #expect(refuses(4, start: Self.monday, split: Self.split), "the 3rd, 10th, 17th and 24th are all four")
        #expect(refuses(3, start: Self.monday, split: Self.split))
        #expect(refuses(6, start: nil, split: Self.split))
        #expect(refuses(6, start: Self.monday, split: nil))
        #expect(refuses(6, start: Self.monday, split: Self.split, rule: "RRULE:FREQ=YEARLY;BYYEARDAY=1;COUNT=6"))
    }
}

/// A month without the rule's day of the month (`RecurrenceTail.MissingMonthDay`): Outlook holds the
/// occurrence on the month's last day and counts it (measured), RFC 5545, and so Google and CalDAV,
/// skip the month. The years are worked out from today: the next common year for the 31st, the
/// next leap year for February 29.
@Suite("RecurrenceTail — a month without the rule's day")
struct RecurrenceTailMissingMonthDayTests {

    private static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }

    /// The first year after this one that is a leap year (`leap`) or a common one.
    private static func nextYear(leap: Bool) -> Int {
        var year = Calendar(identifier: .gregorian).component(.year, from: Date()) + 1
        while isLeap(year) != leap { year += 1 }
        return year
    }

    /// `day` of `month` in `year`.
    private static func on(_ year: Int, _ month: Int, _ day: Int) throws -> RecurrenceTail.Day {
        try #require(RecurrenceTail.Day(year: year, month: month, day: day))
    }

    /// Graph's `absoluteMonthly` on the 31st and `absoluteYearly` on February 29, as the app maps them.
    private static let monthlyOn31st = "RRULE:FREQ=MONTHLY;BYMONTHDAY=31;WKST=SU"
    private static let yearlyOnLeapDay = "RRULE:FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29;WKST=SU"

    @Test("Outlook: monthly on the 31st falls on the last day of a shorter month, as measured")
    func outlookMonthlyOn31st() throws {
        let y = Self.nextYear(leap: false)
        let measured = try [Self.on(y, 1, 31), Self.on(y, 2, 28), Self.on(y, 3, 31), Self.on(y, 4, 30)]
        let rule = try #require(RecurrenceTail.Rule(Self.monthlyOn31st, missingDay: .lastDay))
        let days = rule.days(from: measured[0], through: measured[3], maxSteps: 12)
        #expect(days == measured, "measured: January 31, February 28, March 31, April 30")
    }

    @Test("Outlook: yearly on February 29 falls on February 28 in a common year, as measured")
    func outlookYearlyOnLeapDay() throws {
        let leap = Self.nextYear(leap: true)
        let measured = try [Self.on(leap, 2, 29), Self.on(leap + 1, 2, 28), Self.on(leap + 2, 2, 28)]
        let rule = try #require(RecurrenceTail.Rule(Self.yearlyOnLeapDay, missingDay: .lastDay))
        let days = rule.days(from: measured[0], through: measured[2], maxSteps: 12)
        #expect(days == measured, "measured: the leap day, then February 28 twice")
    }

    @Test("Outlook: a monthly rule with no day of the month repeats the start's 31st on each shorter month's last day")
    func outlookMonthlyFromTheStartDay() throws {
        let y = Self.nextYear(leap: false)
        let expected = try [Self.on(y, 1, 31), Self.on(y, 2, 28), Self.on(y, 3, 31), Self.on(y, 4, 30), Self.on(y, 5, 31), Self.on(y, 6, 30)]
        let rule = try #require(RecurrenceTail.Rule("RRULE:FREQ=MONTHLY;WKST=SU", missingDay: .lastDay))
        #expect(rule.days(from: expected[0], through: expected[5], maxSteps: 12) == expected)
    }

    @Test("Outlook: a yearly rule with no day of the month repeats the start's February 29 on February 28 in a common year")
    func outlookYearlyFromTheStartDay() throws {
        let leap = Self.nextYear(leap: true)
        let expected = try [Self.on(leap, 2, 29), Self.on(leap + 1, 2, 28), Self.on(leap + 2, 2, 28), Self.on(leap + 3, 2, 28), Self.on(leap + 4, 2, 29)]
        let rule = try #require(RecurrenceTail.Rule("RRULE:FREQ=YEARLY;WKST=SU", missingDay: .lastDay))
        #expect(rule.days(from: expected[0], through: expected[4], maxSteps: 12) == expected)
    }

    @Test("Outlook: a month-end occurrence counts toward the number, so a split after a short month leaves N less the ones before it")
    func outlookCountsTheMonthEnd() throws {
        let y = Self.nextYear(leap: false)
        let leap = Self.nextYear(leap: true)
        let jan31 = try Self.on(y, 1, 31)
        let mar31 = try Self.on(y, 3, 31)
        let apr30 = try Self.on(y, 4, 30)
        #expect(RecurrenceTail.occurrences(of: Self.monthlyOn31st, seriesStart: jan31, before: mar31,
                                           anchor: .patternStart, missingDay: .lastDay) == 2,
                "January 31 and February 28 come before March 31")
        let afterFebruary = try RecurrenceTail.newSeriesEnd(
            count: 4, of: Self.monthlyOn31st, seriesStart: jan31, split: mar31, anchor: .patternStart, missingDay: .lastDay)
        #expect(afterFebruary == 2)
        let afterMarch = try RecurrenceTail.newSeriesEnd(
            count: 4, of: Self.monthlyOn31st, seriesStart: jan31, split: apr30, anchor: .patternStart, missingDay: .lastDay)
        #expect(afterMarch == 1)
        let leapDay = try Self.on(leap, 2, 29)
        let secondCommon = try Self.on(leap + 2, 2, 28)
        let yearlyLeft = try RecurrenceTail.newSeriesEnd(
            count: 3, of: Self.yearlyOnLeapDay, seriesStart: leapDay, split: secondCommon, anchor: .patternStart, missingDay: .lastDay)
        #expect(yearlyLeft == 1, "the leap day and the next February 28 come before it")
    }

    @Test("Google and CalDAV keep RFC 5545: a month without the day has no occurrence and is not counted")
    func rfcSkipsTheMonth() throws {
        let y = Self.nextYear(leap: false)
        let leap = Self.nextYear(leap: true)
        let monthEnds = try [Self.on(y, 1, 31), Self.on(y, 3, 31), Self.on(y, 5, 31), Self.on(y, 7, 31)]
        let monthly = try #require(RecurrenceTail.Rule(Self.monthlyOn31st))
        #expect(monthly.days(from: monthEnds[0], through: monthEnds[3], maxSteps: 12) == monthEnds)
        let leapDays = try [Self.on(leap, 2, 29), Self.on(leap + 4, 2, 29)]
        let yearly = try #require(RecurrenceTail.Rule(Self.yearlyOnLeapDay))
        #expect(yearly.days(from: leapDays[0], through: leapDays[1], maxSteps: 12) == leapDays)
        // The rule Google and CalDAV write: January 31 and March 31 come before May 31, so 2 are left.
        // Counting the month ends would put four before it and refuse.
        let written = try RecurrenceTail.newSeriesRule(
            from: "RRULE:FREQ=MONTHLY;BYMONTHDAY=31;COUNT=4", seriesStart: monthEnds[0],
            split: monthEnds[2], capUntil: String(format: "%04d0530T235959Z", y))
        #expect(written == "RRULE:FREQ=MONTHLY;BYMONTHDAY=31;COUNT=2")
        #expect(RecurrenceTail.occurrences(of: Self.monthlyOn31st, seriesStart: monthEnds[0], before: monthEnds[2]) == 2)
    }
}
