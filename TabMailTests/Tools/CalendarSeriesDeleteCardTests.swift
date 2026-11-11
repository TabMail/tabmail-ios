/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - The delete card says when a repeating series goes with every occurrence (#639)
//
// INVARIANT (system property): the confirmation card for a delete that removes a repeating
// series says so, and names its rule, before any delete request is sent; a card for one
// occurrence says the rest of the series stays instead, true on every provider (Google and
// Outlook delete only it, CalDAV refuses); an event that does not repeat gets no line. Google
// Calendar asks the same question in its delete dialog. The event the card is built from is
// the one the tool reads, so the shapes below are the ones each provider reads back: a series
// (a rule, no series it belongs to), a Google or Outlook occurrence (no rule, its series
// named), a CalDAV occurrence (its series' rule AND its series named, or no rule on a row of a
// resource holding only changed occurrences), and a single event. The CalDAV cases, end to end
// on a fake server, are pinned in `CalDAVOccurrenceDeleteToolToWireTests`.

@Suite("calendar_event_delete: the card says when a repeating series is deleted", .serialized, .processGlobalState)
struct CalendarSeriesDeleteCardTests {

    /// Keeps each card and declines it, so nothing is queued and the card alone is tested.
    @MainActor
    private final class DecliningSink: AgentUISink {
        var confirmations: [AgentToolRouter.ActionConfirmation] = []
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            confirmations.append(confirmation)
            confirmation.onRespond(false)
        }
    }

    private static func event(id: String, recurrence: [String]?, recurringEventId: String?) -> GCalEvent {
        let start = Date().addingTimeInterval(7 * 24 * 60 * 60)
        return GCalEvent(
            id: id, summary: "Standup", location: nil, description: nil,
            start: GCalDateTime(dateTime: start.iso8601String(), date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: start.addingTimeInterval(30 * 60).iso8601String(), date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: recurrence, transparency: nil,
            status: "confirmed", htmlLink: nil, created: nil, updated: nil,
            recurringEventId: recurringEventId)
    }

    /// The lines on the card `calendar_event_delete` shows for `event`, read through a mock
    /// provider; the card is declined, and the test checks that no delete was sent.
    private func cardLines(for event: GCalEvent, accountId: String) async throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try await pool.writeWithoutTransaction { db in
            var account = Account(emailAddress: "cal@example.com", displayName: "Cal", provider: .gmail)
            account.id = accountId
            try account.insert(db)
        }
        let mock = MockCalendarProvider()
        await mock.setGetEventResult(event)
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let compound = CompoundEventId.make(accountId: accountId, eventId: event.id ?? "")
        let sink = DecliningSink()
        await #expect(throws: ToolDeclinedError.self) {
            _ = try await CalendarEventDeleteTool(context: ToolContext(db: pool, translator: MockChatIdTranslator())).execute(
                arguments: ["event_id": .string(compound)],
                invocation: ToolInvocation(uiSink: sink, sessionKey: accountId))
        }
        let deleted = await mock.deletedEvents
        #expect(deleted.isEmpty, "a delete was sent for a card the user declined: \(deleted.map(\.eventId))")
        let cards = await MainActor.run { sink.confirmations.map { $0.calendarEvents.flatMap(\.changes) } }
        #expect(cards.count == 1, "expected one confirmation card, got \(cards.count)")
        return cards.first ?? []
    }

    @Test("a series read by its own id: the card says every occurrence will be deleted and names the rule")
    func seriesCardSaysItRepeats() async throws {
        let series = Self.event(
            id: "series-1", recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=10"], recurringEventId: nil)
        let lines = try await cardLines(for: series, accountId: "series-delete-card")
        #expect(lines == [CalendarToolHelpers.seriesDeleteNote, "Repeats weekly on Monday, Wednesday (10 times)"],
                "the card for deleting a repeating series does not say it repeats: \(lines)")
    }

    /// The occurrence card's line, written out so this suite also compiles, and fails, on the code
    /// before the line existed (the red-first run for #639).
    static let occurrenceLine = "One occurrence of a repeating event; the rest of the series stays."

    @Test("one occurrence, on Google or Outlook (no rule) and on CalDAV (its series' rule, or none on a changed-only row): the card says the rest of the series stays")
    func occurrenceCardsSayTheRestStays() async throws {
        let shapes = [
            ("google-outlook-occurrence", Self.event(id: "series-1_occurrence", recurrence: nil, recurringEventId: "series-1")),
            ("caldav-occurrence", Self.event(
                id: CalDAVOccurrences.OccurrenceId.make(seriesHref: "/cal/standup.ics", key: "20990105T140000Z"),
                recurrence: ["RRULE:FREQ=WEEKLY"], recurringEventId: "/cal/standup.ics")),
            ("caldav-changed-only-row", Self.event(
                id: CalDAVOccurrences.OccurrenceId.make(seriesHref: "/cal/invite.ics", key: "20990105T140000Z"),
                recurrence: nil, recurringEventId: "/cal/invite.ics")),
        ]
        for (name, event) in shapes {
            let lines = try await cardLines(for: event, accountId: "occurrence-delete-card-\(name)")
            #expect(lines == [Self.occurrenceLine], "the \(name) card does not say only one occurrence is meant: \(lines)")
        }
    }

    @Test("an event that does not repeat: no line")
    func singleEventCardHasNoLine() async throws {
        let single = Self.event(id: "single-1", recurrence: nil, recurringEventId: nil)
        let lines = try await cardLines(for: single, accountId: "single-delete-card")
        #expect(lines.isEmpty, "the card for an event that does not repeat has a line: \(lines)")
    }

    @Test("a stored rule in the card's words: interval, days, months, count, until; an unreadable rule is still a series")
    func storedRuleInWords() throws {
        #expect(CalendarToolHelpers.storedRecurrenceSummary(["RRULE:FREQ=DAILY"]) == "daily")
        #expect(CalendarToolHelpers.storedRecurrenceSummary(["RRULE:FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR"])
                == "every 2 months on the last Friday")
        #expect(CalendarToolHelpers.storedRecurrenceSummary(["EXDATE:20990105", "RRULE:FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=1"])
                == "yearly in March on day 1")
        // A month out of range is left out, not read past the month list.
        #expect(CalendarToolHelpers.storedRecurrenceSummary(["RRULE:FREQ=YEARLY;BYMONTH=13"]) == "yearly")

        // UNTIL as a date is that date; as a UTC date-time, the day it is in the device's zone.
        let utc = try #require(TimeZone(identifier: "UTC"))
        let day = Date().addingTimeInterval(30 * 24 * 60 * 60)
        let basic = DateFormatter()
        basic.locale = Locale(identifier: "en_US_POSIX")
        basic.timeZone = utc
        basic.dateFormat = "yyyyMMdd"
        let shown = DateFormatter()
        shown.locale = Locale(identifier: "en_US_POSIX")
        shown.timeZone = utc
        shown.dateFormat = "yyyy-MM-dd"
        #expect(CalendarToolHelpers.storedRecurrenceSummary(["RRULE:FREQ=WEEKLY;UNTIL=\(basic.string(from: day))"])
                == "weekly (until \(shown.string(from: day)))")
        basic.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        shown.timeZone = .current
        #expect(CalendarToolHelpers.storedRecurrenceSummary(["RRULE:FREQ=WEEKLY;UNTIL=\(basic.string(from: day))"])
                == "weekly (until \(shown.string(from: day)))")

        // No RRULE line, or a FREQ RFC 5545 does not name: no words for the rule, but a series
        // is still said to be one.
        #expect(CalendarToolHelpers.storedRecurrenceSummary(["RDATE:20990105"]) == nil)
        #expect(CalendarToolHelpers.storedRecurrenceSummary(["RRULE:FREQ=FORTNIGHTLY"]) == nil)
        let rdateOnly = Self.event(id: "series-2", recurrence: ["RDATE:20990105"], recurringEventId: nil)
        #expect(CalendarToolHelpers.seriesDeleteLines(rdateOnly) == [CalendarToolHelpers.seriesDeleteNote])

        // A frequency the popover's phrase does not name keeps its token on the card.
        #expect(CalendarToolHelpers.storedRecurrenceSummary(["RRULE:FREQ=HOURLY;INTERVAL=2"]) == "every 2 hourly")
    }

    /// The event popover's line, exactly as `EventPillPopover.describeRecurrence` gave it before
    /// it moved to `CalendarToolHelpers` (#639): the move must not change it. The old function was
    /// private to the view, so this pin was checked against its removed source by a side-by-side
    /// run over these same inputs before the move landed.
    @Test("the event popover's rule line is unchanged by the move", arguments: [
        (nil, "Recurring"),
        ("", "Recurring"),
        ("RRULE:FREQ=WEEKLY", "Repeats weekly"),
        ("RRULE:FREQ=WEEKLY;INTERVAL=2", "Repeats every 2 weeks"),
        ("rrule:freq=monthly;interval=3", "Repeats every 3 months"),
        ("FREQ=DAILY", "Repeats daily"),
        ("RRULE:FREQ=YEARLY;INTERVAL=1", "Repeats yearly"),
        ("RRULE:FREQ=HOURLY;INTERVAL=2", "Recurring"),
        ("RRULE:INTERVAL=2", "Recurring"),
        ("RRULE:FREQ=DAILY;INTERVAL=0", "Repeats daily"),
        ("RRULE:FREQ=DAILY;INTERVAL=x", "Repeats daily"),
        ("RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=10;INTERVAL=4", "Repeats every 4 weeks"),
        ("RRULE:FREQ", "Recurring"),
        ("RRULE:FREQ=MINUTELY", "Recurring"),
    ] as [(String?, String)])
    func popoverLineUnchanged(_ rrule: String?, _ expected: String) {
        #expect(CalendarToolHelpers.popoverRecurrenceLine(rrule) == expected)
    }
}
