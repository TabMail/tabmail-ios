/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// A this-and-following split on Google hands its NEW series the original
/// series' end: the same UNTIL, or what is left of its COUNT. Before this, the
/// new series was written with UNTIL and COUNT stripped, so a series meant to
/// end ran forever from the split on.
///
/// When the original series already ends before the split there is no tail to
/// move: the split is refused, and refused before the cap PATCH, so the master
/// on the server is untouched.
///
/// The series is timed in Pacific/Auckland at 07:00, which is the previous day
/// in UTC, and the split's `recurrence_id` is declared in UTC. Its BYDAY rule
/// counts different occurrences when read in the wrong frame. Dates are
/// relative to now.
@Suite("GoogleCalendarProvider splitSeries — the new series keeps the original end", .serialized)
struct GoogleSplitSeriesTailTests {

    private static let auckland = TimeZone(identifier: "Pacific/Auckland")!
    private static let utc = TimeZone(identifier: "UTC")!
    private static let masterId = "tail-master"
    private static let masterPath = "/calendar/v3/calendars/primary/events/\(masterId)"
    private static let createPath = "/calendar/v3/calendars/primary/events"

    /// A Monday 07:00 in Auckland at least a week from now.
    private static func mondayInAuckland() throws -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = auckland
        let weekFromNow = Date().addingTimeInterval(7 * 86_400)
        let monday = DateComponents(hour: 7, minute: 0, second: 0, weekday: 2)
        return try #require(cal.nextDate(after: weekFromNow, matching: monday, matchingPolicy: .nextTime))
    }

    /// The same wall clock `days` days later in Auckland.
    private static func aucklandDays(_ days: Int, after date: Date) throws -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = auckland
        return try #require(cal.date(byAdding: .day, value: days, to: date))
    }

    private static func format(_ date: Date, _ pattern: String, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        f.timeZone = zone
        return f.string(from: date)
    }

    private static func masterJSON(rrule: String, start: Date) -> Data {
        let iso = ISO8601DateFormatter()
        iso.timeZone = auckland
        let s = iso.string(from: start)
        let e = iso.string(from: start.addingTimeInterval(3_600))
        return Data("""
        {"id":"\(masterId)","summary":"Standup","status":"confirmed",
         "start":{"dateTime":"\(s)","timeZone":"Pacific/Auckland"},
         "end":{"dateTime":"\(e)","timeZone":"Pacific/Auckland"},
         "recurrence":["\(rrule)"]}
        """.utf8)
    }

    private struct Outcome {
        let error: Error?
        let wire: [String]
        /// The `recurrence` the new series was created with, or nil if no create was sent.
        let created: [String]?
        let recurrenceId: String
    }

    /// Split a Monday/Wednesday/Friday series the following Monday. Three
    /// occurrences fall before the split in Auckland (Monday, Wednesday,
    /// Friday); read in UTC the same days are Sunday, Tuesday and Thursday.
    private func split(rrule: String, patch: GCalEventInput = GCalEventInput()) async throws -> Outcome {
        let start = try Self.mondayInAuckland()
        let splitAt = try Self.aucklandDays(7, after: start)
        let recurrenceId = Self.format(splitAt, "yyyy-MM-dd'T'HH:mm:ss", Self.utc)
        let master = Self.masterJSON(rrule: rrule, start: start)
        let json = ["Content-Type": "application/json"]

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: Self.masterPath, method: "GET", response: .raw(statusCode: 200, headers: json, body: master))
        http.register(path: Self.masterPath, method: "PATCH", response: .raw(statusCode: 200, headers: json, body: master))
        http.register(path: Self.createPath, method: "POST",
                      response: .raw(statusCode: 200, headers: json, body: Data(#"{"id":"successor","status":"confirmed"}"#.utf8)))
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)

        var thrown: Error?
        do {
            _ = try await provider.splitSeries(
                calendarId: "primary", eventId: Self.masterId,
                recurrenceId: recurrenceId, recurrenceIdZone: Self.utc,
                patch: patch, sendUpdates: "none")
        } catch {
            thrown = error
        }
        let created = http.recordedCalls()
            .first { $0.method == "POST" }
            .flatMap { $0.body }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["recurrence"] as? [String] }
        return Outcome(error: thrown, wire: http.servedCallSequence(), created: created, recurrenceId: recurrenceId)
    }

    private func isRefusal(_ error: Error?) -> Bool {
        if case CalendarProviderError.notSupported(let message)? = error { return !message.isEmpty }
        return false
    }

    @Test("A COUNT series' new half gets the occurrences the original had left")
    func countCarriesOver() async throws {
        let out = try await split(rrule: "RRULE:FREQ=WEEKLY;COUNT=10;BYDAY=MO,WE,FR")
        #expect(out.error == nil, "got \(String(describing: out.error))")
        #expect(out.created == ["RRULE:FREQ=WEEKLY;COUNT=7;BYDAY=MO,WE,FR"], """
            ten occurrences, three of them (Monday, Wednesday, Friday in Auckland) before the split: \
            the new series has seven. An unbounded rule is the defect; COUNT=6 means the rule was \
            read in UTC, where the series starts on a Sunday. got \(String(describing: out.created))
            """)
    }

    @Test("A COUNT already used up before the split is refused with nothing written")
    func usedUpCountIsRefusedBeforeAnyWrite() async throws {
        let out = try await split(rrule: "RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=MO,WE,FR")
        #expect(isRefusal(out.error), "got \(String(describing: out.error))")
        #expect(out.wire == ["GET \(Self.masterPath)"], """
            the refusal must come before the cap PATCH: a capped master with no new series \
            loses the rest of the user's series. got \(out.wire)
            """)
    }

    @Test("An UNTIL before the split is refused with nothing written")
    func earlierUntilIsRefusedBeforeAnyWrite() async throws {
        let start = try Self.mondayInAuckland()
        let until = Self.format(try Self.aucklandDays(3, after: start), "yyyyMMdd'T'HHmmss'Z'", Self.utc)
        let out = try await split(rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=\(until)")
        #expect(isRefusal(out.error), "got \(String(describing: out.error))")
        #expect(out.wire == ["GET \(Self.masterPath)"], "got \(out.wire)")
    }

    @Test("An UNTIL after the split is carried over verbatim")
    func laterUntilCarriesOver() async throws {
        let start = try Self.mondayInAuckland()
        let until = Self.format(try Self.aucklandDays(30, after: start), "yyyyMMdd'T'HHmmss'Z'", Self.utc)
        let rule = "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=\(until)"
        let out = try await split(rrule: rule)
        #expect(out.error == nil, "got \(String(describing: out.error))")
        #expect(out.created == [rule], "the new series must end where the original did. got \(String(describing: out.created))")
    }

    @Test("A master already carrying this split's cap is a retry: the new series is written without an end")
    func ownCapIsARetry() async throws {
        let start = try Self.mondayInAuckland()
        let recurrenceId = Self.format(try Self.aucklandDays(7, after: start), "yyyy-MM-dd'T'HH:mm:ss", Self.utc)
        let cap = try #require(GoogleCalendarProvider.googleUntilString(beforeNaiveISO: recurrenceId, allDay: false, zone: Self.utc))
        let out = try await split(rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=\(cap)")
        #expect(out.recurrenceId == recurrenceId, "setup: the cap must be the one this split computes")
        #expect(out.error == nil, """
            refusing here retires the operation while the master stays capped with no new \
            series. got \(String(describing: out.error))
            """)
        #expect(out.created == ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"], "got \(String(describing: out.created))")
    }

    @Test("A patch that brings its own recurrence is written as given, even when the original COUNT is used up")
    func patchRecurrenceIsNotChecked() async throws {
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=DAILY;COUNT=4"]
        let out = try await split(rrule: "RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=MO,WE,FR", patch: patch)
        #expect(out.error == nil, "got \(String(describing: out.error))")
        #expect(out.created == ["RRULE:FREQ=DAILY;COUNT=4"], "got \(String(describing: out.created))")
    }

    @Test("An all-day COUNT series counts on its own dates")
    func allDayCountCarriesOver() async throws {
        let first = Date().addingTimeInterval(7 * 86_400)
        let startDate = Self.format(first, "yyyy-MM-dd", Self.utc)
        let endDate = Self.format(first.addingTimeInterval(86_400), "yyyy-MM-dd", Self.utc)
        let splitDate = Self.format(first.addingTimeInterval(14 * 86_400), "yyyy-MM-dd", Self.utc)
        let master = Data("""
        {"id":"\(Self.masterId)","summary":"Bins","status":"confirmed",
         "start":{"date":"\(startDate)"},"end":{"date":"\(endDate)"},
         "recurrence":["RRULE:FREQ=WEEKLY;COUNT=5"]}
        """.utf8)
        let json = ["Content-Type": "application/json"]
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: Self.masterPath, method: "GET", response: .raw(statusCode: 200, headers: json, body: master))
        http.register(path: Self.masterPath, method: "PATCH", response: .raw(statusCode: 200, headers: json, body: master))
        http.register(path: Self.createPath, method: "POST",
                      response: .raw(statusCode: 200, headers: json, body: Data(#"{"id":"successor","status":"confirmed"}"#.utf8)))
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)

        _ = try await provider.splitSeries(
            calendarId: "primary", eventId: Self.masterId,
            recurrenceId: splitDate, recurrenceIdZone: .current,
            patch: GCalEventInput(), sendUpdates: "none")
        let created = http.recordedCalls()
            .first { $0.method == "POST" }
            .flatMap { $0.body }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["recurrence"] as? [String] }
        #expect(created == ["RRULE:FREQ=WEEKLY;COUNT=3"],
                "two weekly occurrences fall before the split, three are left. got \(String(describing: created))")
    }
}
