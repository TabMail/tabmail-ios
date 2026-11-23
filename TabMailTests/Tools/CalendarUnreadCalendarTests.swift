/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// INVARIANT (#1293): a calendar the assistant's read tools could not read is reported in
// the tool's result as not read. It is never left out as if it had no events.
//
//  * `calendar_read`, `calendar_search` (every page) and `calendar_event_read` (by start
//    time) name every calendar whose events could not be listed, and every account whose
//    calendars could not be listed, in one sorted list next to whatever the other calendars
//    returned, and never answer with their plain "nothing found" text while a calendar was
//    not read. A calendar that was read is never in that list.
//  * `calendar_event_read` by id, when it scans every account, names each account whose
//    calendars could not be listed instead of answering that the event is in no calendar.
//  * When every calendar is read, the results are exactly what they were.
//
// Each case installs its own database holding active accounts (A, B, ...), each with one
// primary calendar and a mock provider, and runs the real tool entry points; nothing is
// retried, so each failing listing is asked for exactly once.

private let unreadPhrase = "could not be read"

@MainActor
@Suite("Calendar read tools report a calendar they could not read", .serialized, .processGlobalState)
struct CalendarUnreadCalendarTests {

    private struct Fixture {
        let ids: [String]
        let mocks: [MockCalendarProvider]
        var accountA: String { ids[0] }
        var mockA: MockCalendarProvider { mocks[0] }
        var mockB: MockCalendarProvider { mocks[1] }
    }

    private static let letters = ["a", "b", "c", "d", "e", "f"]

    /// The address of the account at `index` (0 is A).
    private static func email(_ index: Int) -> String { "reader-\(letters[index])@example.com" }

    /// Installs a fresh shared database holding `count` active accounts, each with one
    /// primary calendar ("Home" on A, "Work" on every other) and no events, runs `body`,
    /// then restores every global it touched.
    private func withCalendars(accounts count: Int = 2, _ body: (Fixture) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }

        let fixture = Fixture(
            ids: (0..<count).map { "cal-unread-\(Self.letters[$0])-\(UUID().uuidString)" },
            mocks: (0..<count).map { _ in MockCalendarProvider() }
        )
        let priorDemoActive = DemoModeStore.shared.isActive
        let manager = AccountManager.shared
        CalendarVisibilityStore._resetForTesting()

        var failure: Error?
        do {
            let accounts = fixture.ids.enumerated().map { ($0.element, Self.email($0.offset)) }
            try await pool.write { db in
                for (accountId, email) in accounts {
                    var account = Account(emailAddress: email, displayName: "Test", provider: .gmail)
                    account.id = accountId
                    account.isActive = true
                    try account.insert(db)
                }
            }
            for (index, mock) in fixture.mocks.enumerated() {
                let calendar = index == 0
                    ? Self.calendar(id: "cal-home", summary: "Home")
                    : Self.calendar(id: "cal-work", summary: "Work")
                await mock.setListCalendarsResult([calendar])
                await manager.registerCalendarProviderForTesting(accountId: fixture.ids[index], provider: mock)
            }
            DemoModeStore.shared.isActive = false
            try await body(fixture)
        } catch {
            failure = error
        }

        DemoModeStore.shared.isActive = priorDemoActive
        CalendarVisibilityStore._resetForTesting()
        for id in fixture.ids {
            await manager.unregisterCalendarProviderForTesting(accountId: id)
        }
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        if let failure { throw failure }
    }

    private static func calendar(id: String, summary: String) -> GCalCalendar {
        GCalCalendar(id: id, summary: summary, primary: true, accessRole: "owner", backgroundColor: nil, selected: nil)
    }

    /// A timed event an hour long, starting at `start`.
    private static func event(id: String, summary: String, start: Date) -> GCalEvent {
        let fmt = ISO8601DateFormatter()
        return GCalEvent(
            id: id, summary: summary, location: nil, description: nil,
            start: GCalDateTime(dateTime: fmt.string(from: start), date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: fmt.string(from: start.addingTimeInterval(3600)), date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: "confirmed", htmlLink: nil, created: nil, updated: nil
        )
    }

    /// A timed event an hour long, `hoursFromNow` hours from now.
    private static func event(id: String, summary: String, hoursFromNow: Double = 1) -> GCalEvent {
        event(id: id, summary: summary, start: Date().addingTimeInterval(hoursFromNow * 3600))
    }

    /// `date` as the naive `yyyy-MM-dd'T'HH:mm:ss` the tools take, in UTC.
    private static func naiveUTC(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    /// Whole seconds, so the event's start and the `start_iso` asked for are the same instant.
    private static func wholeSeconds(hoursFromNow: Double) -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + hoursFromNow * 3600).rounded(.down))
    }

    private struct ListingFailed: Error {}

    private static let workCalendarLabel = "\"Work\" (\(email(1)))"
    private static let accountBLabel = "every calendar of \(email(1))"

    /// The list part of the note, as the tools write it: every label, in order, then a full stop.
    private static func noteList(_ labels: [String]) -> String {
        "could not be read, so their events are not listed: " + labels.joined(separator: "; ") + ". "
    }

    // MARK: - calendar_read

    @Test("calendar_read lists the calendars it read and names the calendar whose events could not be listed")
    func readNamesTheCalendarWhoseEventsFailed() async throws {
        try await withCalendars { f in
            await f.mockA.setListEventsResult([Self.event(id: "evt-home", summary: "Dentist")])
            await f.mockB.setListEventsThrows(ListingFailed())

            let output = try await CalendarReadTool().execute(arguments: [:])

            #expect(output.contains("Dentist"), "the calendar that was read is still listed: \(output)")
            #expect(output.contains(Self.noteList([Self.workCalendarLabel])), "\(output)")
            #expect(!output.contains(Self.email(0)), "a calendar that was read is not named as unread: \(output)")
            let callsB = await f.mockB.callLog
            let workListings = callsB.filter { $0 == "listEvents(calendarId:cal-work)" }.count
            #expect(workListings == 1, "no retry: \(callsB)")
        }
    }

    @Test("calendar_read with nothing it could read and nothing found never says only that no events were found")
    func readWithNoEventsStillNamesTheUnreadAccount() async throws {
        try await withCalendars { f in
            await f.mockB.setListCalendarsThrows(ListingFailed())

            let output = try await CalendarReadTool().execute(arguments: [:])

            #expect(output != "No calendar events found in the requested date range.")
            #expect(output.contains(Self.noteList([Self.accountBLabel])), "\(output)")
            let callsB = await f.mockB.callLog
            let calendarListings = callsB.filter { $0 == "listCalendars" }.count
            let eventListings = callsB.filter { $0.hasPrefix("listEvents") }.count
            #expect(calendarListings == 1, "no retry: \(callsB)")
            #expect(eventListings == 0, "\(callsB)")
        }
    }

    @Test("calendar_read names every calendar and account it could not read, sorted, and none it read")
    func readNamesEveryUnreadCalendarInOrder() async throws {
        try await withCalendars(accounts: 3) { f in
            await f.mockA.setListEventsResult([Self.event(id: "evt-home", summary: "Dentist")])
            // Listed out of order on purpose: the note is sorted, not in listing order.
            await f.mockB.setListCalendarsResult([
                Self.calendar(id: "cal-work", summary: "Work"),
                Self.calendar(id: "cal-team", summary: "Team"),
            ])
            await f.mockB.setListEventsThrows(ListingFailed())
            await f.mocks[2].setListCalendarsThrows(ListingFailed())

            let output = try await CalendarReadTool().execute(arguments: [:])

            let expected = Self.noteList([
                "\"Team\" (\(Self.email(1)))",
                "\"Work\" (\(Self.email(1)))",
                "every calendar of \(Self.email(2))",
            ])
            #expect(output.contains("Dentist"), "\(output)")
            #expect(output.contains(expected), "\(output)")
            #expect(!output.contains(Self.email(0)), "a calendar that was read is not named as unread: \(output)")
        }
    }

    @Test("calendar_read with every calendar read answers exactly as before")
    func readWithEveryCalendarReadIsUnchanged() async throws {
        try await withCalendars { _ in
            let empty = try await CalendarReadTool().execute(arguments: [:])
            #expect(empty == "No calendar events found in the requested date range.")
        }
        try await withCalendars { f in
            await f.mockA.setListEventsResult([Self.event(id: "evt-home", summary: "Dentist")])
            let output = try await CalendarReadTool().execute(arguments: [:])
            #expect(output.contains("Dentist"))
            #expect(!output.contains(unreadPhrase), "\(output)")
        }
    }

    // MARK: - calendar_search

    @Test("calendar_search names the calendar it could not read, with and without matches elsewhere")
    func searchNamesTheCalendarWhoseEventsFailed() async throws {
        try await withCalendars { f in
            await f.mockB.setListEventsThrows(ListingFailed())

            let none = try await CalendarSearchTool().execute(arguments: ["query": .string("Dentist")])
            #expect(!none.hasPrefix("No calendar events found matching 'Dentist' in the requested date range."), "\(none)")
            #expect(none.contains(Self.noteList([Self.workCalendarLabel])), "\(none)")

            await f.mockA.setListEventsResult([Self.event(id: "evt-home", summary: "Dentist")])
            let some = try await CalendarSearchTool().execute(arguments: ["query": .string("Dentist")])
            #expect(some.contains("Dentist"), "\(some)")
            #expect(some.contains(Self.noteList([Self.workCalendarLabel])), "\(some)")
        }
    }

    @Test("calendar_search names the calendar it could not read on a later page too")
    func searchNamesTheUnreadCalendarOnEveryPage() async throws {
        try await withCalendars { f in
            // One more match than a page holds: the last one, in start order, is alone on page 2.
            let matches = (0...100).map { Self.event(id: "evt-\($0)", summary: "Dentist \($0)", hoursFromNow: Double($0 + 1)) }
            await f.mockA.setListEventsResult(matches)
            await f.mockB.setListEventsThrows(ListingFailed())

            let page2 = try await CalendarSearchTool().execute(arguments: [
                "query": .string("Dentist"), "page_index": .int(2),
            ])

            #expect(page2.contains("Dentist 100"), "\(page2)")
            #expect(page2.contains("Page 2 of 2"), "\(page2)")
            #expect(page2.contains(Self.noteList([Self.workCalendarLabel])), "\(page2)")
        }
    }

    @Test("calendar_search with every calendar read answers exactly as before")
    func searchWithEveryCalendarReadIsUnchanged() async throws {
        try await withCalendars { _ in
            let output = try await CalendarSearchTool().execute(arguments: ["query": .string("Dentist")])
            #expect(output == "No calendar events found matching 'Dentist' in the requested date range.")
        }
    }

    // MARK: - calendar_event_read by start time

    @Test("calendar_event_read by start time names the calendar it could not read, with and without a match")
    func eventReadByStartNamesTheCalendarWhoseEventsFailed() async throws {
        try await withCalendars { f in
            await f.mockB.setListEventsThrows(ListingFailed())
            let start = Self.wholeSeconds(hoursFromNow: 3)
            let args: [String: JSONValue] = ["start_iso": .string(Self.naiveUTC(start)), "timezone": .string("UTC")]

            let none = try await CalendarEventReadTool().execute(arguments: args)
            #expect(none != "No entries matched.")
            #expect(none.contains(Self.noteList([Self.workCalendarLabel])), "\(none)")

            await f.mockA.setListEventsResult([Self.event(id: "evt-home", summary: "Dentist", start: start)])
            let match = try await CalendarEventReadTool().execute(arguments: args)
            #expect(match.contains("title: Dentist"), "the match from the calendar that was read: \(match)")
            #expect(match.contains(Self.noteList([Self.workCalendarLabel])), "\(match)")
        }
    }

    @Test("calendar_event_read by start time with every calendar read answers exactly as before")
    func eventReadByStartWithEveryCalendarReadIsUnchanged() async throws {
        try await withCalendars { f in
            let start = Self.wholeSeconds(hoursFromNow: 3)
            let args: [String: JSONValue] = ["start_iso": .string(Self.naiveUTC(start)), "timezone": .string("UTC")]

            let none = try await CalendarEventReadTool().execute(arguments: args)
            #expect(none == "No entries matched.")

            await f.mockA.setListEventsResult([Self.event(id: "evt-home", summary: "Dentist", start: start)])
            let match = try await CalendarEventReadTool().execute(arguments: args)
            #expect(match.contains("title: Dentist"), "\(match)")
            #expect(!match.contains(unreadPhrase), "\(match)")
        }
    }

    // MARK: - calendar_event_read by id

    @Test("calendar_event_read by id names every account whose calendars could not be listed, sorted")
    func eventReadByIdNamesEveryUnreadAccount() async throws {
        // Five failing accounts: their scan order is the registry's, so an unsorted list
        // would match the sorted one only by chance (1 in 120).
        try await withCalendars(accounts: 6) { f in
            for mock in f.mocks.dropFirst() {
                await mock.setListCalendarsThrows(ListingFailed())
            }
            // A compound id on account A: the scan of the other accounts reaches the rest.
            let id = CompoundEventId.make(accountId: f.accountA, eventId: "evt-missing")

            let output = try await CalendarEventReadTool().execute(arguments: ["event_id": .string(id)])

            let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            let error = object?["error"] as? String
            let message = try #require(error, "\(output)")
            let expected = Self.noteList((1...5).map { "every calendar of \(Self.email($0))" })
            #expect(message.hasPrefix("Event not found in the calendars that could be read."), "\(message)")
            #expect(message.contains(expected), "\(message)")
            #expect(!message.contains(Self.email(0)), "\(message)")
        }
    }

    @Test("calendar_event_read by id with every account read answers exactly as before")
    func eventReadByIdWithEveryAccountReadIsUnchanged() async throws {
        try await withCalendars { f in
            let id = CompoundEventId.make(accountId: f.accountA, eventId: "evt-missing")
            let output = try await CalendarEventReadTool().execute(arguments: ["event_id": .string(id)])
            #expect(output == #"{"error": "Event not found in any calendar."}"#)
        }
    }
}
