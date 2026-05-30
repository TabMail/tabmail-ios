/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - MockChatIdTranslator Event Detail Caching

@Suite("Event Detail Caching via MockChatIdTranslator")
struct EventDetailCachingTests {

    private func makeTranslator() -> MockChatIdTranslator {
        MockChatIdTranslator()
    }

    @Test("cacheEventDetail stores and resolveEventDetail retrieves")
    func cacheAndResolve() async {
        let translator = makeTranslator()
        let realId = "google-event-abc123"
        let numericId = await translator.toNumericId(realId)

        await translator.cacheEventDetail(
            realId: realId,
            accountId: nil, calendarId: nil, calendarName: nil,
            title: "Team Standup",
            startDate: Date(timeIntervalSince1970: 1000),
            endDate: Date(timeIntervalSince1970: 2000),
            isAllDay: false,
            location: "Room 42",
            attendees: [],
            isRecurring: false,
            recurrenceRule: nil,
            availability: "busy",
            htmlLink: nil,
            eventTimeZone: nil
        )

        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail != nil)
        #expect(detail?.title == "Team Standup")
        #expect(detail?.realId == realId)
        #expect(detail?.isAllDay == false)
        #expect(detail?.location == "Room 42")
    }

    @Test("resolveEventDetail returns nil for uncached event")
    func uncachedReturnsNil() async {
        let translator = makeTranslator()
        await translator.seed("some-event", as: 1)

        let detail = await translator.resolveEventDetail(1)
        #expect(detail == nil)
    }

    @Test("resolveEventDetail returns nil for unknown numeric ID")
    func unknownIdReturnsNil() async {
        let translator = makeTranslator()
        let detail = await translator.resolveEventDetail(999)
        #expect(detail == nil)
    }

    @Test("evictEventDetail removes cached entry")
    func evictRemovesCache() async {
        let translator = makeTranslator()
        let realId = "event-to-delete"
        let numericId = await translator.toNumericId(realId)

        await translator.cacheEventDetail(
            realId: realId,
            accountId: nil, calendarId: nil, calendarName: nil,
            title: "Doomed Meeting",
            startDate: Date(),
            endDate: Date(),
            isAllDay: false,
            location: nil,
            attendees: [],
            isRecurring: false,
            recurrenceRule: nil,
            availability: "busy",
            htmlLink: nil,
            eventTimeZone: nil
        )

        // Verify it exists
        let before = await translator.resolveEventDetail(numericId)
        #expect(before != nil)

        // Evict
        await translator.evictEventDetail(realId: realId)

        // Verify it's gone
        let after = await translator.resolveEventDetail(numericId)
        #expect(after == nil)
    }

    @Test("evictEventDetail on non-existent key is safe")
    func evictNonExistentIsSafe() async {
        let translator = makeTranslator()
        // Should not crash
        await translator.evictEventDetail(realId: "does-not-exist")
    }

    @Test("cacheEventDetail overwrites previous entry")
    func cacheOverwritesPrevious() async {
        let translator = makeTranslator()
        let realId = "overwrite-event"
        let numericId = await translator.toNumericId(realId)

        await translator.cacheEventDetail(
            realId: realId, accountId: nil, calendarId: nil, calendarName: nil,
            title: "V1", startDate: nil, endDate: nil,
            isAllDay: false, location: nil, attendees: [], isRecurring: false,
            recurrenceRule: nil, availability: "busy", htmlLink: nil,
            eventTimeZone: nil
        )

        await translator.cacheEventDetail(
            realId: realId, accountId: nil, calendarId: nil, calendarName: nil,
            title: "V2", startDate: nil, endDate: nil,
            isAllDay: true, location: "Updated Location", attendees: [], isRecurring: false,
            recurrenceRule: nil, availability: "free", htmlLink: nil,
            eventTimeZone: nil
        )

        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail?.title == "V2")
        #expect(detail?.isAllDay == true)
        #expect(detail?.location == "Updated Location")
    }

    @Test("cacheEventDetail carries notes through to resolveEventDetail")
    func notesRoundTrip() async {
        // Regression: notes (Zoom/Meet links) were dropped at every pill layer.
        let translator = makeTranslator()
        let realId = "notes-event"
        let numericId = await translator.toNumericId(realId)

        await translator.cacheEventDetail(
            realId: realId, accountId: nil, calendarId: nil, calendarName: nil,
            title: "1:1", startDate: nil, endDate: nil,
            isAllDay: false, location: nil,
            notes: "Join Zoom: https://zoom.us/j/9999",
            attendees: [], isRecurring: false,
            recurrenceRule: nil, availability: "busy", htmlLink: nil,
            eventTimeZone: nil
        )

        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail?.notes == "Join Zoom: https://zoom.us/j/9999")
    }

    @Test("cacheEventDetailsForPills propagates notes and attendees from the event")
    func pillsCacheNotesAndAttendees() async {
        // Regression: the read/search cache path must carry both the event's
        // description (notes) and its attendees so a pill tap shows them without
        // a separate live re-fetch.
        let translator = makeTranslator()
        let event = GCalEvent(
            id: "evt-pills", summary: "Planning", location: "HQ",
            description: "Agenda + https://meet.google.com/abc-defg-hij",
            start: nil, end: nil,
            attendees: [
                GCalAttendee(email: "lead@test.com", displayName: "Lead", responseStatus: "accepted", organizer: nil, self: nil),
                GCalAttendee(email: "", displayName: "Ghost", responseStatus: "accepted", organizer: nil, self: nil),
            ],
            organizer: nil, recurrence: nil, transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil
        )

        await CalendarToolHelpers.cacheEventDetailsForPills(
            [(event: event, accountId: "acct-1", calendarId: "cal-1", accessRole: "owner")],
            translator: translator
        )

        let numericId = await translator.toNumericId(CompoundEventId.make(accountId: "acct-1", eventId: "evt-pills"))
        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail?.notes == "Agenda + https://meet.google.com/abc-defg-hij")
        #expect(detail?.attendees.count == 1)  // empty-email attendee dropped
        #expect(detail?.attendees.first?.email == "lead@test.com")
        #expect(detail?.location == "HQ")
    }

    @Test("cacheTemplateName stores and is retrievable via seed pattern")
    func templateNameCache() async {
        let translator = makeTranslator()
        await translator.seed("template-uuid-123", as: 5)
        await translator.cacheTemplateName(numericId: 5, name: "My Template")

        // Verify the mapping works (template names are used by processResponseForDisplay)
        let realId = await translator.toRealId(5)
        #expect(realId == "template-uuid-123")
    }
}

// MARK: - CalendarEventCreateTool Caching

@Suite("CalendarEventCreateTool Caching")
struct CalendarEventCreateToolCachingTests {

    @Test("Tool name is calendar_event_create")
    func toolName() throws {
        let db = try TestDatabase.make()
        let tool = CalendarEventCreateTool(context: ToolContext(db: db, translator: MockChatIdTranslator()))
        #expect(tool.name == "calendar_event_create")
    }
}

// MARK: - CalendarEventEditTool Caching

@Suite("CalendarEventEditTool — event_id validation unchanged")
struct CalendarEventEditToolCachingTests {

    private func makeContext() throws -> ToolContext {
        let db = try TestDatabase.make()
        return ToolContext(db: db, translator: MockChatIdTranslator())
    }

    @Test("Missing event_id still returns error after caching refactor")
    func missingEventId() async throws {
        let tool = CalendarEventEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing event_id"))
    }

    @Test("Empty event_id still returns error after caching refactor")
    func emptyEventId() async throws {
        let tool = CalendarEventEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["event_id": .string("")])
        #expect(result.contains("missing event_id"))
    }
}

// MARK: - CalendarEventDeleteTool Caching

@Suite("CalendarEventDeleteTool — event_id validation unchanged")
struct CalendarEventDeleteToolCachingTests {

    private func makeContext() throws -> ToolContext {
        let db = try TestDatabase.make()
        return ToolContext(db: db, translator: MockChatIdTranslator())
    }

    @Test("Missing event_id still returns error after caching refactor")
    func missingEventId() async throws {
        let tool = CalendarEventDeleteTool(context: try makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing event_id"))
    }

    @Test("Empty event_id still returns error after caching refactor")
    func emptyEventId() async throws {
        let tool = CalendarEventDeleteTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["event_id": .string("")])
        #expect(result.contains("missing event_id"))
    }
}

// MARK: - TemplateEditTool Caching

@Suite("TemplateEditTool Argument Validation")
struct TemplateEditToolCachingTests {

    private func makeContext() throws -> ToolContext {
        let db = try TestDatabase.make()
        return ToolContext(db: db, translator: MockChatIdTranslator())
    }

    @Test("Tool name is template_edit")
    func toolName() throws {
        let tool = TemplateEditTool(context: try makeContext())
        #expect(tool.name == "template_edit")
    }

    @Test("Missing template_id returns error")
    func missingTemplateId() async throws {
        let tool = TemplateEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("Template ID is required"))
    }

    @Test("Non-integer template_id returns error")
    func nonIntTemplateId() async throws {
        let tool = TemplateEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["template_id": .string("abc")])
        #expect(result.contains("Template ID is required"))
    }
}

// MARK: - Contact Tool Output Format

@Suite("Contact Tool Output Format Validation")
struct ContactToolOutputFormatTests {

    private func makeContext() -> ToolContext {
        let db = try! DatabaseQueue()
        return ToolContext(db: db, translator: MockChatIdTranslator())
    }

    @Test("ContactAddTool tool name is contacts_add")
    func addToolName() {
        let tool = ContactAddTool(context: makeContext())
        #expect(tool.name == "contacts_add")
    }

    @Test("ContactEditTool tool name is contacts_edit")
    func editToolName() {
        let tool = ContactEditTool(context: makeContext())
        #expect(tool.name == "contacts_edit")
    }

    @Test("ContactDeleteTool tool name is contacts_delete")
    func deleteToolName() {
        let tool = ContactDeleteTool(context: makeContext())
        #expect(tool.name == "contacts_delete")
    }

    @Test("ContactAddTool missing identity fields still returns error")
    func addMissingFields() async throws {
        let tool = ContactAddTool(context: makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("Provide at least a name or an email"))
    }

    @Test("ContactEditTool missing contact_id still returns error")
    func editMissingId() async throws {
        let tool = ContactEditTool(context: makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing contact_id"))
    }

    @Test("ContactDeleteTool missing contact_id still returns error")
    func deleteMissingId() async throws {
        let tool = ContactDeleteTool(context: makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing contact_id"))
    }
}
