/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// These tests reset/reuse keys on the real process-wide UserDefaults.standard.
// `.serialized` prevents sibling overlap; `.processGlobalState` prevents the
// separate visibility-store suite from resetting the same keys concurrently.
@Suite("CalendarToolHelpers visibility filter", .serialized, .processGlobalState)
struct CalendarVisibilityFilterTests {

    private func makeCal(_ id: String, primary: Bool = false) -> GCalCalendar {
        GCalCalendar(
            id: id,
            summary: "Cal \(id)",
            primary: primary,
            accessRole: "owner",
            backgroundColor: nil,
            selected: nil
        )
    }

    private func makeEvent(_ id: String) -> GCalEvent {
        GCalEvent(
            id: id, summary: "Event \(id)", location: nil, description: nil,
            start: nil, end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
    }

    private func makeAccount(id: String) -> Account {
        var a = Account(emailAddress: "test-\(id)@example.com", displayName: "Test", provider: .gmail)
        a.id = id
        return a
    }

    @Test("Non-primary calendars are skipped by default; only primary is visible")
    func nonPrimarySkippedByDefault() async {
        CalendarVisibilityStore._resetForTesting()
        defer { CalendarVisibilityStore._resetForTesting() }

        let provider = MockCalendarProvider()
        await provider.setListCalendarsResult([
            makeCal("cal-primary", primary: true),
            makeCal("cal-shared-1"),  // primary: false default
            makeCal("cal-shared-2"),
        ])
        await provider.setListEventsResult([makeEvent("evt")])

        let account = makeAccount(id: "acct-1")
        let result = await CalendarToolHelpers.fetchEventsFromAllCalendars(
            backends: [(provider: provider, account: account)],
            timeMin: nil, timeMax: nil, query: nil
        )

        #expect(result.events.count == 1) // primary only
        let calls = await provider.callLog
        #expect(calls.contains("listEvents(calendarId:cal-primary)"))
        #expect(!calls.contains("listEvents(calendarId:cal-shared-1)"))
        #expect(!calls.contains("listEvents(calendarId:cal-shared-2)"))
    }

    @Test("User override true opts a non-primary calendar in")
    func overrideTrueOpensNonPrimary() async {
        CalendarVisibilityStore._resetForTesting()
        defer { CalendarVisibilityStore._resetForTesting() }

        let provider = MockCalendarProvider()
        await provider.setListCalendarsResult([
            makeCal("cal-primary", primary: true),
            makeCal("cal-shared"),  // primary: false default-hidden
        ])
        await provider.setListEventsResult([makeEvent("evt")])

        // User explicitly opts cal-shared in.
        CalendarVisibilityStore.setOverride(true, accountId: "acct-1", calendarId: "cal-shared")

        let account = makeAccount(id: "acct-1")
        let result = await CalendarToolHelpers.fetchEventsFromAllCalendars(
            backends: [(provider: provider, account: account)],
            timeMin: nil, timeMax: nil, query: nil
        )

        #expect(result.events.count == 2) // primary + opted-in shared
        let calls = await provider.callLog
        #expect(calls.contains("listEvents(calendarId:cal-shared)"))
    }

    @Test("User override false hides the primary calendar")
    func overrideFalseHidesPrimary() async {
        CalendarVisibilityStore._resetForTesting()
        defer { CalendarVisibilityStore._resetForTesting() }

        let provider = MockCalendarProvider()
        await provider.setListCalendarsResult([
            makeCal("cal-primary", primary: true),
            makeCal("cal-other-primary", primary: true),
        ])
        await provider.setListEventsResult([makeEvent("evt")])

        // User hides one primary calendar.
        CalendarVisibilityStore.setOverride(false, accountId: "acct-1", calendarId: "cal-primary")

        let account = makeAccount(id: "acct-1")
        let result = await CalendarToolHelpers.fetchEventsFromAllCalendars(
            backends: [(provider: provider, account: account)],
            timeMin: nil, timeMax: nil, query: nil
        )

        #expect(result.events.count == 1)
        let calls = await provider.callLog
        #expect(!calls.contains("listEvents(calendarId:cal-primary)"))
        #expect(calls.contains("listEvents(calendarId:cal-other-primary)"))
    }

    @Test("Multiple primary calendars across mocked accounts are all default-visible")
    func multiplePrimariesAllVisible() async {
        CalendarVisibilityStore._resetForTesting()
        defer { CalendarVisibilityStore._resetForTesting() }

        let provider = MockCalendarProvider()
        await provider.setListCalendarsResult([
            makeCal("cal-1", primary: true),
            makeCal("cal-2", primary: true),
        ])
        await provider.setListEventsResult([makeEvent("evt")])

        let account = makeAccount(id: "acct-1")
        let result = await CalendarToolHelpers.fetchEventsFromAllCalendars(
            backends: [(provider: provider, account: account)],
            timeMin: nil, timeMax: nil, query: nil
        )

        #expect(result.events.count == 2)
    }
}

// MARK: - MockCalendarProvider helpers

extension MockCalendarProvider {
    func setListCalendarsResult(_ value: [GCalCalendar]) { listCalendarsResult = value }
    func setListEventsResult(_ value: [GCalEvent]) { listEventsResult = value }
}
