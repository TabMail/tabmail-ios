/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - CompoundEventId

@Suite("CompoundEventId")
struct CompoundEventIdTests {

    @Test("make produces accountId:eventId format")
    func makeCompound() {
        let result = CompoundEventId.make(accountId: "acc1", eventId: "evt123")
        #expect(result == "acc1:evt123")
    }

    @Test("split extracts accountId and eventId")
    func splitCompound() {
        let result = CompoundEventId.split("acc1:evt123")
        #expect(result?.accountId == "acc1")
        #expect(result?.eventId == "evt123")
    }

    @Test("split returns nil for bare ID without colon")
    func splitBareId() {
        #expect(CompoundEventId.split("evt123") == nil)
    }

    @Test("split handles CalDAV paths with slashes")
    func splitCalDAVPath() {
        let result = CompoundEventId.split("caldav-acc:/calendars/user/abc-123.ics")
        #expect(result?.accountId == "caldav-acc")
        #expect(result?.eventId == "/calendars/user/abc-123.ics")
    }

    @Test("split handles accountId with no eventId after colon")
    func splitEmptyEventId() {
        let result = CompoundEventId.split("acc1:")
        #expect(result?.accountId == "acc1")
        #expect(result?.eventId == "")
    }

    @Test("round-trip: make then split returns original values")
    func roundTrip() {
        let accountId = "google-acc-123"
        let eventId = "long-event-id-abc"
        let compound = CompoundEventId.make(accountId: accountId, eventId: eventId)
        let parts = CompoundEventId.split(compound)
        #expect(parts?.accountId == accountId)
        #expect(parts?.eventId == eventId)
    }
}

// MARK: - formatGroupedSummary with compound IDs

@Suite("formatGroupedSummary Multi-Calendar")
struct FormatGroupedSummaryMultiCalendarTests {

    @Test("Events from multiple accounts emit compound event_id")
    func multiAccountCompoundIds() {
        let now = Date()
        let event1 = GCalEvent(
            id: "evt-1", summary: "Meeting", location: nil, description: nil,
            start: GCalDateTime(dateTime: now.iso8601String(), date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: now.addingTimeInterval(3600).iso8601String(), date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil, transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil
        )
        let event2 = GCalEvent(
            id: "evt-2", summary: "Lunch", location: nil, description: nil,
            start: GCalDateTime(dateTime: now.addingTimeInterval(7200).iso8601String(), date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: now.addingTimeInterval(10800).iso8601String(), date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil, transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil
        )

        let tuples: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (event: event1, accountId: "google-acc", calendarId: "primary", accessRole: nil),
            (event: event2, accountId: "exchange-acc", calendarId: "work-cal", accessRole: nil),
        ]

        let output = CalendarToolHelpers.formatGroupedSummary(tuples)
        #expect(output.contains("event_id: google-acc:evt-1"))
        #expect(output.contains("event_id: exchange-acc:evt-2"))
        #expect(output.contains("Meeting"))
        #expect(output.contains("Lunch"))
    }

    @Test("Empty accountId falls back to bare event_id")
    func emptyAccountFallback() {
        let now = Date()
        let event = GCalEvent(
            id: "evt-bare", summary: "Test", location: nil, description: nil,
            start: GCalDateTime(dateTime: now.iso8601String(), date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: now.addingTimeInterval(3600).iso8601String(), date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil, transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil
        )

        let tuples: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (event: event, accountId: "", calendarId: "", accessRole: nil),
        ]

        let output = CalendarToolHelpers.formatGroupedSummary(tuples)
        #expect(output.contains("event_id: evt-bare"))
        // Should NOT have colon prefix
        #expect(!output.contains("event_id: :evt-bare"))
    }
}

// MARK: - formatDetailedEvent with accountId

@Suite("formatDetailedEvent Multi-Calendar")
struct FormatDetailedEventMultiCalendarTests {

    @Test("Emits compound event_id when accountId provided")
    func compoundEventId() {
        let event = GCalEvent(
            id: "evt-detail", summary: "Detail Test", location: nil, description: nil,
            start: GCalDateTime(dateTime: nil, date: "2026-03-30", timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: "2026-03-31", timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil, transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event, accountId: "myacc")
        #expect(output.contains("event_id: myacc:evt-detail"))
    }

    @Test("Emits bare event_id when accountId empty")
    func bareEventId() {
        let event = GCalEvent(
            id: "evt-bare", summary: "Bare Test", location: nil, description: nil,
            start: GCalDateTime(dateTime: nil, date: "2026-03-30", timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: "2026-03-31", timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil, transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil
        )
        let output = CalendarToolHelpers.formatDetailedEvent(event)
        #expect(output.contains("event_id: evt-bare"))
        #expect(!output.contains("event_id: :evt-bare"))
    }
}

// MARK: - isEventNotFoundError

@Suite("isEventNotFoundError")
struct IsEventNotFoundErrorTests {

    @Test("Google 404 is event not found")
    func google404() {
        #expect(CalendarToolHelpers.isEventNotFoundError(GoogleCalendarError.httpError(404, nil)))
    }

    @Test("Google eventNotFound is event not found")
    func googleEventNotFound() {
        #expect(CalendarToolHelpers.isEventNotFoundError(GoogleCalendarError.eventNotFound))
    }

    @Test("Exchange 404 is event not found")
    func exchange404() {
        #expect(CalendarToolHelpers.isEventNotFoundError(ExchangeCalendarError.httpError(404, nil)))
    }

    @Test("CalDAV notFound is event not found")
    func caldavNotFound() {
        #expect(CalendarToolHelpers.isEventNotFoundError(CalDAVError.notFound))
    }

    @Test("Google 403 is NOT event not found")
    func google403() {
        #expect(!CalendarToolHelpers.isEventNotFoundError(GoogleCalendarError.httpError(403, nil)))
    }

    @Test("Google missingScope is NOT event not found")
    func googleMissingScope() {
        #expect(!CalendarToolHelpers.isEventNotFoundError(GoogleCalendarError.missingScope))
    }
}

// MARK: - EventCalendarInfo + ChatIdTranslator cache

@Suite("EventCalendarInfo Caching")
struct EventCalendarInfoCachingTests {

    @Test("cacheEventDetail stores calendar info, resolveEventCalendarInfo retrieves it")
    func cacheAndResolve() async {
        let translator = MockChatIdTranslator()
        let compoundId = CompoundEventId.make(accountId: "acc1", eventId: "evt-test")

        // Register the compound ID (this is what processToolOutputForLLM does with compound event_id in output)
        let numericId = await translator.toNumericId(compoundId)

        // Cache event detail with bare realId + accountId (cacheEventDetail builds compound key internally)
        await translator.cacheEventDetail(
            realId: "evt-test", accountId: "acc1", calendarId: "work-cal", calendarName: "Work Calendar",
            title: "Test Event", startDate: nil, endDate: nil, isAllDay: false,
            location: nil, attendees: [], isRecurring: false, recurrenceRule: nil, availability: "busy", htmlLink: nil,
            eventTimeZone: nil
        )

        // Resolve calendar info via numericId → compound key → cache lookup
        let info = await translator.resolveEventCalendarInfo(numericId)
        #expect(info?.accountId == "acc1")
        #expect(info?.calendarId == "work-cal")
        #expect(info?.calendarName == "Work Calendar")
    }

    @Test("resolveEventCalendarInfo returns nil for unknown numericId")
    func resolveUnknown() async {
        let translator = MockChatIdTranslator()
        let info = await translator.resolveEventCalendarInfo(999)
        #expect(info == nil)
    }

    @Test("evictEventDetail clears both eventDetailCache and eventCalendarCache")
    func evictClearsBoth() async {
        let translator = MockChatIdTranslator()
        let compoundId = CompoundEventId.make(accountId: "acc1", eventId: "evt-evict")
        let numericId = await translator.toNumericId(compoundId)

        await translator.cacheEventDetail(
            realId: "evt-evict", accountId: "acc1", calendarId: "cal1", calendarName: "Work",
            title: "Evict Me", startDate: nil, endDate: nil, isAllDay: false,
            location: nil, attendees: [], isRecurring: false, recurrenceRule: nil, availability: "busy", htmlLink: nil,
            eventTimeZone: nil
        )

        // Both should exist
        #expect(await translator.resolveEventDetail(numericId) != nil)
        #expect(await translator.resolveEventCalendarInfo(numericId) != nil)

        // Evict using compound key (what delete tool passes)
        await translator.evictEventDetail(realId: compoundId)

        // Both should be gone
        #expect(await translator.resolveEventDetail(numericId) == nil)
        #expect(await translator.resolveEventCalendarInfo(numericId) == nil)
    }

    @Test("Legacy bare ID: resolveEventCalendarInfo returns nil, split returns nil")
    func legacyBareId() async {
        let translator = MockChatIdTranslator()
        // Simulate old idMap entry — bare event ID without colon
        let numericId = await translator.toNumericId("bare-event-id-no-colon")

        // No calendar info was cached for this bare ID
        let info = await translator.resolveEventCalendarInfo(numericId)
        #expect(info == nil)

        // CompoundEventId.split returns nil for bare IDs
        let realId = await translator.toRealId(numericId)
        #expect(realId == "bare-event-id-no-colon")
        #expect(CompoundEventId.split(realId!) == nil)
    }
}

// MARK: - PendingCalendarOperation calendarId

@Suite("PendingCalendarOperation calendarId")
struct PendingCalendarOperationCalendarIdTests {

    @Test("Init with calendarId preserves it")
    func initWithCalendarId() {
        let op = PendingCalendarOperation(
            operationType: .edit,
            accountId: "acc1",
            eventId: "evt-1",
            calendarId: "work-cal",
            arguments: ["title": .string("Updated")]
        )
        #expect(op.calendarId == "work-cal")
        #expect(op.accountId == "acc1")
        #expect(op.eventId == "evt-1")
    }

    @Test("Init without calendarId defaults to nil")
    func initWithoutCalendarId() {
        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: "acc1",
            arguments: ["title": .string("New Event")]
        )
        #expect(op.calendarId == nil)
    }

    @Test("Insert and fetch round-trip preserves calendarId")
    func persistenceRoundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = PendingCalendarOperation(
            operationType: .edit,
            accountId: "acc1",
            eventId: "evt-persist",
            calendarId: "my-calendar-id",
            arguments: ["title": .string("Persist Test")]
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingCalendarOperation.fetchOne($0, key: op.id) }
        #expect(fetched != nil)
        #expect(fetched?.calendarId == "my-calendar-id")
    }

    @Test("Insert with nil calendarId, fetch returns nil")
    func persistenceNilCalendarId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: "acc1",
            arguments: [:]
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingCalendarOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.calendarId == nil)
    }
}

// MARK: - Edit/delete compound ID resolution flow

@Suite("Edit/Delete Compound ID Resolution")
struct EditDeleteCompoundIdResolutionTests {

    @Test("Compound ID round-trip: create → cache → resolve for edit")
    func createThenEditFlow() async {
        let translator = MockChatIdTranslator()
        let accountId = "google-acc-123"
        let rawEventId = "generated-event-id"
        let calendarId = "primary"

        // 1. Create tool stores compound ID and caches calendar info
        let compoundId = CompoundEventId.make(accountId: accountId, eventId: rawEventId)
        let numericId = await translator.toNumericId(compoundId)
        await translator.cacheEventDetail(
            realId: rawEventId, accountId: accountId, calendarId: calendarId, calendarName: "My Calendar",
            title: "Test", startDate: nil, endDate: nil, isAllDay: false,
            location: nil, attendees: [], isRecurring: false, recurrenceRule: nil, availability: "busy", htmlLink: nil,
            eventTimeZone: nil
        )

        // 2. Edit tool resolves: numericId → compound → split → accountId + rawEventId
        let resolvedCompound = await translator.toRealId(numericId)
        #expect(resolvedCompound == compoundId)

        let parts = CompoundEventId.split(resolvedCompound!)
        #expect(parts?.accountId == accountId)
        #expect(parts?.eventId == rawEventId)

        // 3. Edit tool gets calendarId from cache
        let calInfo = await translator.resolveEventCalendarInfo(numericId)
        #expect(calInfo?.accountId == accountId)
        #expect(calInfo?.calendarId == calendarId)
        #expect(calInfo?.calendarName == "My Calendar")
    }

    @Test("Compound ID after app restart: idMap persisted but calendar cache lost")
    func appRestartScenario() async {
        let translator = MockChatIdTranslator()
        let compoundId = CompoundEventId.make(accountId: "acc1", eventId: "evt-restart")

        // Simulate persisted idMap entry (survives restart)
        let numericId = await translator.toNumericId(compoundId)

        // Calendar cache is ephemeral — NOT populated after restart
        // resolveEventCalendarInfo returns nil (triggers fallback in tools)
        let calInfo = await translator.resolveEventCalendarInfo(numericId)
        #expect(calInfo == nil)

        // But we still have accountId from the compound ID
        let realId = await translator.toRealId(numericId)
        let parts = CompoundEventId.split(realId!)
        #expect(parts?.accountId == "acc1")
        #expect(parts?.eventId == "evt-restart")
    }
}

// MARK: - Legacy overload cacheEventDetailsForPills

@Suite("cacheEventDetailsForPills Legacy Overload")
struct CacheEventDetailsLegacyOverloadTests {

    @Test("Legacy overload with accountId passes through to tuple version")
    func legacyWithAccountId() async {
        let translator = MockChatIdTranslator()
        let event = GCalEvent(
            id: "evt-legacy", summary: "Legacy Test", location: nil, description: nil,
            start: GCalDateTime(dateTime: nil, date: "2026-04-01", timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: "2026-04-02", timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil, transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil
        )

        // Register compound ID first (simulating processToolOutputForLLM)
        let compoundId = CompoundEventId.make(accountId: "acc1", eventId: "evt-legacy")
        let numericId = await translator.toNumericId(compoundId)

        // Call legacy overload with accountId (used by edit/delete fallback)
        await CalendarToolHelpers.cacheEventDetailsForPills(
            [event], accountId: "acc1", calendarId: "cal1",
            calendarName: "Work", translator: translator
        )

        // Should be resolvable via compound key
        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail?.title == "Legacy Test")
        #expect(detail?.calendarName == "Work")

        let calInfo = await translator.resolveEventCalendarInfo(numericId)
        #expect(calInfo?.accountId == "acc1")
        #expect(calInfo?.calendarId == "cal1")
    }
}
