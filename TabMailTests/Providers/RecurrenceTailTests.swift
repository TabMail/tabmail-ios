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

    @Test("An UNTIL equal to this split's own cap gives the new series no end")
    func ownCapIsARetry() throws {
        #expect(try rule("RRULE:FREQ=DAILY;UNTIL=20990306T165959Z") == "RRULE:FREQ=DAILY")
        #expect(try rule("RRULE:FREQ=DAILY;until=20990306t165959z") == "RRULE:FREQ=DAILY")
        #expect(try rule("RRULE:FREQ=DAILY;UNTIL=20990305", cap: Self.allDayCap) == "RRULE:FREQ=DAILY")
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
