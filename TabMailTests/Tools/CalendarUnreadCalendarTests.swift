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
//  * `calendar_read`, `calendar_search` and `calendar_event_read` (by start time) name
//    every calendar whose events could not be listed, and every account whose calendars
//    could not be listed, next to whatever the other calendars returned, and never answer
//    with their plain "nothing found" text while a calendar was not read.
//  * `calendar_event_read` by id, when it scans every account, names an account whose
//    calendars could not be listed instead of answering that the event is in no calendar.
//  * When every calendar was read, the results are exactly what they were.
//
// Each case installs its own database holding active accounts A and B and registers a mock
// calendar for each through the real tool entry points; nothing is retried, so each
// failing listing is asked for exactly once.

private let unreadPhrase = "could not be read"

@MainActor
@Suite("Calendar read tools report a calendar they could not read", .serialized, .processGlobalState)
struct CalendarUnreadCalendarTests {

    private struct Fixture {
        let accountA: String
        let accountB: String
        let mockA: MockCalendarProvider
        let mockB: MockCalendarProvider
    }

    private static let emailA = "reader-a@example.com"
    private static let emailB = "reader-b@example.com"

    /// Installs a fresh shared database holding active accounts A and B, each with one
    /// primary calendar ("Home" on A, "Work" on B) and no events, runs `body`, then
    /// restores every global it touched.
    private func withCalendars(_ body: (Fixture) async throws -> Void) async throws {
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
            accountA: "cal-unread-a-\(UUID().uuidString)",
            accountB: "cal-unread-b-\(UUID().uuidString)",
            mockA: MockCalendarProvider(),
            mockB: MockCalendarProvider()
        )
        let priorDemoActive = DemoModeStore.shared.isActive
        let manager = AccountManager.shared
        CalendarVisibilityStore._resetForTesting()

        var failure: Error?
        do {
            let accounts = [(fixture.accountA, Self.emailA), (fixture.accountB, Self.emailB)]
            try await pool.write { db in
                for (accountId, email) in accounts {
                    var account = Account(emailAddress: email, displayName: "Test", provider: .gmail)
                    account.id = accountId
                    account.isActive = true
                    try account.insert(db)
                }
            }
            await fixture.mockA.setListCalendarsResult([Self.calendar(id: "cal-home", summary: "Home")])
            await fixture.mockB.setListCalendarsResult([Self.calendar(id: "cal-work", summary: "Work")])
            await manager.registerCalendarProviderForTesting(accountId: fixture.accountA, provider: fixture.mockA)
            await manager.registerCalendarProviderForTesting(accountId: fixture.accountB, provider: fixture.mockB)
            DemoModeStore.shared.isActive = false
            try await body(fixture)
        } catch {
            failure = error
        }

        DemoModeStore.shared.isActive = priorDemoActive
        CalendarVisibilityStore._resetForTesting()
        await manager.unregisterCalendarProviderForTesting(accountId: fixture.accountA)
        await manager.unregisterCalendarProviderForTesting(accountId: fixture.accountB)
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        if let failure { throw failure }
    }

    private static func calendar(id: String, summary: String) -> GCalCalendar {
        GCalCalendar(id: id, summary: summary, primary: true, accessRole: "owner", backgroundColor: nil, selected: nil)
    }

    /// A timed event an hour long, `hoursFromNow` hours from now.
    private static func event(id: String, summary: String, hoursFromNow: Double = 1) -> GCalEvent {
        let fmt = ISO8601DateFormatter()
        let start = Date().addingTimeInterval(hoursFromNow * 3600)
        return GCalEvent(
            id: id, summary: summary, location: nil, description: nil,
            start: GCalDateTime(dateTime: fmt.string(from: start), date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: fmt.string(from: start.addingTimeInterval(3600)), date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: "confirmed", htmlLink: nil, created: nil, updated: nil
        )
    }

    private struct ListingFailed: Error {}

    private static let workCalendarLabel = "\"Work\" (\(emailB))"
    private static let accountBLabel = "every calendar of \(emailB)"

    // MARK: - calendar_read

    @Test("calendar_read lists the calendars it read and names the calendar whose events could not be listed")
    func readNamesTheCalendarWhoseEventsFailed() async throws {
        try await withCalendars { f in
            await f.mockA.setListEventsResult([Self.event(id: "evt-home", summary: "Dentist")])
            await f.mockB.setListEventsThrows(ListingFailed())

            let output = try await CalendarReadTool().execute(arguments: [:])

            #expect(output.contains("Dentist"), "the calendar that was read is still listed: \(output)")
            #expect(output.contains(unreadPhrase), "\(output)")
            #expect(output.contains(Self.workCalendarLabel), "\(output)")
            #expect(!output.contains(Self.emailA), "a calendar that was read is not named as unread: \(output)")
            let callsB = await f.mockB.callLog
            #expect(callsB.filter { $0 == "listEvents(calendarId:cal-work)" }.count == 1, "no retry: \(callsB)")
        }
    }

    @Test("calendar_read with nothing it could read and nothing found never says only that no events were found")
    func readWithNoEventsStillNamesTheUnreadAccount() async throws {
        try await withCalendars { f in
            await f.mockB.setListCalendarsThrows(ListingFailed())

            let output = try await CalendarReadTool().execute(arguments: [:])

            #expect(output != "No calendar events found in the requested date range.")
            #expect(output.contains(unreadPhrase), "\(output)")
            #expect(output.contains(Self.accountBLabel), "\(output)")
            let callsB = await f.mockB.callLog
            #expect(callsB.filter { $0 == "listCalendars" }.count == 1, "no retry: \(callsB)")
            #expect(!callsB.contains { $0.hasPrefix("listEvents") }, "\(callsB)")
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
            #expect(none.contains(unreadPhrase), "\(none)")
            #expect(none.contains(Self.workCalendarLabel), "\(none)")

            await f.mockA.setListEventsResult([Self.event(id: "evt-home", summary: "Dentist")])
            let some = try await CalendarSearchTool().execute(arguments: ["query": .string("Dentist")])
            #expect(some.contains("Dentist"), "\(some)")
            #expect(some.contains(unreadPhrase), "\(some)")
            #expect(some.contains(Self.workCalendarLabel), "\(some)")
        }
    }

    @Test("calendar_search with every calendar read answers exactly as before")
    func searchWithEveryCalendarReadIsUnchanged() async throws {
        try await withCalendars { _ in
            let output = try await CalendarSearchTool().execute(arguments: ["query": .string("Dentist")])
            #expect(output == "No calendar events found matching 'Dentist' in the requested date range.")
        }
    }

    // MARK: - calendar_event_read

    @Test("calendar_event_read by start time names the calendar it could not read")
    func eventReadByStartNamesTheCalendarWhoseEventsFailed() async throws {
        try await withCalendars { f in
            await f.mockB.setListEventsThrows(ListingFailed())
            let start = Date().addingTimeInterval(3 * 3600)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            fmt.timeZone = TimeZone(identifier: "UTC")
            fmt.locale = Locale(identifier: "en_US_POSIX")
            let args: [String: JSONValue] = [
                "start_iso": .string(fmt.string(from: start)),
                "timezone": .string("UTC"),
            ]

            let output = try await CalendarEventReadTool().execute(arguments: args)

            #expect(output != "No entries matched.")
            #expect(output.contains(unreadPhrase), "\(output)")
            #expect(output.contains(Self.workCalendarLabel), "\(output)")
        }
    }

    @Test("calendar_event_read by id names an account whose calendars could not be listed")
    func eventReadByIdNamesTheUnreadAccount() async throws {
        try await withCalendars { f in
            await f.mockB.setListCalendarsThrows(ListingFailed())
            // A compound id on account A: the scan of the other accounts reaches B.
            let id = CompoundEventId.make(accountId: f.accountA, eventId: "evt-missing")

            let output = try await CalendarEventReadTool().execute(arguments: ["event_id": .string(id)])

            let data = Data(output.utf8)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = object?["error"] as? String
            let message = try #require(error, "\(output)")
            #expect(message != "Event not found in any calendar.")
            #expect(message.contains(unreadPhrase), "\(message)")
            #expect(message.contains(Self.accountBLabel), "\(message)")
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
