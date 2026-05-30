/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("CalendarToolHelpers free/busy rendering")
struct CalendarFreeBusyRenderingTests {

    private let utc = TimeZone(identifier: "UTC")!

    private func makeEvent(id: String, summary: String? = nil, hourOffset: Double = 0) -> GCalEvent {
        let start = Date(timeIntervalSince1970: 1_800_000_000 + hourOffset * 3600)
        let end = start.addingTimeInterval(1800)
        return GCalEvent(
            id: id,
            summary: summary,
            location: nil,
            description: nil,
            start: GCalDateTime(dateTime: start.iso8601String(timeZone: utc), date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: end.iso8601String(timeZone: utc), date: nil, timeZone: nil),
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: nil,
            htmlLink: nil,
            created: nil,
            updated: nil
        )
    }

    @Test("formatGroupedSummary — freeBusyReader event renders as Busy with calendar local-part")
    func freeBusyRendering() {
        let event = makeEvent(id: "evt-1")  // empty summary on purpose
        let acct = "acct-1"
        let calId = "casey.lee@calendar.example"
        let tuples: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (event: event, accountId: acct, calendarId: calId, accessRole: "freeBusyReader")
        ]
        let names = [CompoundEventId.make(accountId: acct, eventId: calId): "casey.lee@calendar.example"]

        let output = CalendarToolHelpers.formatGroupedSummary(tuples, calendarNames: names, timeZone: utc)
        #expect(output.contains("Busy — casey.lee"))
        #expect(!output.contains("(No title)"))
    }

    @Test("formatGroupedSummary — non-freeBusy empty-title event still renders as (No title)")
    func nonFreeBusyEmptyTitleStillFallback() {
        let event = makeEvent(id: "evt-1")
        let tuples: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (event: event, accountId: "acct", calendarId: "primary", accessRole: "owner")
        ]
        let output = CalendarToolHelpers.formatGroupedSummary(tuples, timeZone: utc)
        #expect(output.contains("(No title)"))
    }

    @Test("formatGroupedSummary — freeBusy row suppresses (↻) and [free] marks even on leaky data")
    func freeBusyRowDefensiveMarks() {
        // Pathological: API returns recurrence + transparency on a freeBusy event.
        // Should still render only "Busy — …" with no marks.
        let leaky = GCalEvent(
            id: "evt-leak", summary: nil, location: nil, description: nil,
            start: GCalDateTime(dateTime: Date(timeIntervalSince1970: 1_800_000_000).iso8601String(timeZone: utc), date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: Date(timeIntervalSince1970: 1_800_001_800).iso8601String(timeZone: utc), date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: ["RRULE:FREQ=DAILY"], transparency: "transparent",
            status: nil, htmlLink: nil, created: nil, updated: nil
        )
        let acct = "acct"
        let calId = "casey.lee@calendar.example"
        let tuples: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (event: leaky, accountId: acct, calendarId: calId, accessRole: "freeBusyReader")
        ]
        let names = [CompoundEventId.make(accountId: acct, eventId: calId): "casey.lee@calendar.example"]
        let output = CalendarToolHelpers.formatGroupedSummary(tuples, calendarNames: names, timeZone: utc)
        #expect(output.contains("Busy — casey.lee"))
        #expect(!output.contains("(↻)"))
        #expect(!output.contains("[free]"))
    }

    @Test("formatGroupedSummary — mixed batch renders each row by its accessRole")
    func mixedBatch() {
        let owned = makeEvent(id: "evt-owned", summary: "Real Meeting", hourOffset: 0)
        let busy = makeEvent(id: "evt-busy", hourOffset: 1)
        let acct = "acct"
        let busyCalId = "robin.fox@calendar.example"
        let tuples: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (event: owned, accountId: acct, calendarId: "primary", accessRole: "owner"),
            (event: busy, accountId: acct, calendarId: busyCalId, accessRole: "freeBusyReader"),
        ]
        let names = [CompoundEventId.make(accountId: acct, eventId: busyCalId): "robin.fox@calendar.example"]
        let output = CalendarToolHelpers.formatGroupedSummary(tuples, calendarNames: names, timeZone: utc)
        #expect(output.contains("Real Meeting"))
        #expect(output.contains("Busy — robin.fox"))
    }

    @Test("formatDetailedEvent — freeBusyReader event has Busy title and read-only note")
    func freeBusyDetailed() {
        let event = makeEvent(id: "evt-1")
        let output = CalendarToolHelpers.formatDetailedEvent(
            event,
            accountId: "acct",
            calendarId: "casey.lee@calendar.example",
            accessRole: "freeBusyReader",
            calendarName: "casey.lee@calendar.example",
            timeZone: utc
        )
        #expect(output.contains("title: Busy — casey.lee"))
        #expect(output.contains("note: read-only free/busy block"))
        #expect(output.contains("cannot be edited or deleted"))
        // None of the detail blocks should appear on a freeBusy event, even if
        // partial data ever leaks through from the API.
        #expect(!output.contains("description:"))
        #expect(!output.contains("link:"))
        #expect(!output.contains("Location:"))
        #expect(!output.contains("Organizer:"))
        #expect(!output.contains("attendees:"))
        #expect(!output.contains("recurring:"))
        #expect(!output.contains("RRULE:"))
    }

    @Test("formatDetailedEvent — freeBusy SUPPRESSES detail blocks even if event has data")
    func freeBusyDefensiveSuppression() {
        // Pathological: API returns a freeBusy event that somehow has full detail.
        // Should still be suppressed.
        let leakyEvent = GCalEvent(
            id: "evt-leak",
            summary: "Leaked Title",
            location: "Leaked Location",
            description: "Leaked description.",
            start: GCalDateTime(dateTime: Date(timeIntervalSince1970: 1_800_000_000).iso8601String(timeZone: utc), date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: Date(timeIntervalSince1970: 1_800_001_800).iso8601String(timeZone: utc), date: nil, timeZone: nil),
            attendees: [GCalAttendee(email: "a@x.com", displayName: "A", responseStatus: "accepted", organizer: nil, self: nil)],
            organizer: GCalOrganizer(email: "b@x.com", displayName: "B", self: nil),
            recurrence: ["RRULE:FREQ=WEEKLY"],
            transparency: nil,
            status: "confirmed",
            htmlLink: "https://example.com/event/leak",
            created: nil,
            updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(
            leakyEvent,
            accountId: "acct",
            calendarId: "casey.lee@calendar.example",
            accessRole: "freeBusyReader",
            calendarName: "casey.lee@calendar.example",
            timeZone: utc
        )
        #expect(output.contains("title: Busy — casey.lee"))
        #expect(!output.contains("Leaked Title"))
        #expect(!output.contains("Leaked Location"))
        #expect(!output.contains("Leaked description"))
        #expect(!output.contains("a@x.com"))
        #expect(!output.contains("b@x.com"))
        #expect(!output.contains("RRULE"))
        #expect(!output.contains("https://example.com/event/leak"))
    }

    @Test("formatDetailedEvent — non-freeBusy events do NOT get the read-only note (regression)")
    func ownerEventNoFreeBusyNote() {
        let event = makeEvent(id: "evt-1", summary: "Real Meeting")
        let output = CalendarToolHelpers.formatDetailedEvent(
            event,
            accountId: "acct",
            calendarId: "primary",
            accessRole: "owner",
            calendarName: "primary",
            timeZone: utc
        )
        #expect(!output.contains("note: read-only"))
        #expect(output.contains("title: Real Meeting"))
    }

    @Test("freeBusyDisplayName — strips email local-part, falls through for non-email")
    func displayNameHelper() {
        #expect(CalendarToolHelpers.freeBusyDisplayName(calendarName: "casey.lee@calendar.example", calendarId: "casey.lee@calendar.example") == "casey.lee")
        #expect(CalendarToolHelpers.freeBusyDisplayName(calendarName: nil, calendarId: "robin.fox@calendar.example") == "robin.fox")
        #expect(CalendarToolHelpers.freeBusyDisplayName(calendarName: "primary", calendarId: "primary") == "primary")
        // Group-style id with no @ → returned verbatim
        let groupId = "abc123@group.calendar.google.com"
        #expect(CalendarToolHelpers.freeBusyDisplayName(calendarName: "Holidays", calendarId: groupId) == "Holidays")
        #expect(CalendarToolHelpers.freeBusyDisplayName(calendarName: nil, calendarId: groupId) == "abc123")
    }
}
