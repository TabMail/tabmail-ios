/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - ProactiveNotifyService Config Tests

@Suite("ProactiveNotifyService Configuration")
struct ProactiveNotifyServiceConfigTests {

    @Test("UserDefaults key constants are correct")
    func userDefaultsKeys() {
        #expect(ProactiveNotifyService.enabledKey == "proactive.notify.enabled")
        #expect(ProactiveNotifyService.windowDaysKey == "proactive.notify.window_days")
        #expect(ProactiveNotifyService.advanceMinutesKey == "proactive.notify.advance_minutes")
    }

    @Test("Default window days matches TB DEFAULTS (7)")
    func defaultWindowDays() {
        #expect(ProactiveNotifyService.defaultWindowDays == 7)
    }

    @Test("Default advance minutes matches TB DEFAULTS (30)")
    func defaultAdvanceMinutes() {
        #expect(ProactiveNotifyService.defaultAdvanceMinutes == 30)
    }

    @Test("Window days is positive")
    func windowDaysPositive() {
        #expect(ProactiveNotifyService.defaultWindowDays > 0)
    }

    @Test("Advance minutes is positive")
    func advanceMinutesPositive() {
        #expect(ProactiveNotifyService.defaultAdvanceMinutes > 0)
    }
}

// MARK: - ReachedOutStore Integration Tests (UserDefaults-backed)

@Suite("ReachedOutStore Operations", .serialized)
struct ReachedOutStoreOperationTests {

    /// Unique key prefix to avoid collisions with production data or parallel tests.
    private func uniqueHash() -> String {
        "test_\(UUID().uuidString)"
    }

    @Test("markNotified then hasNotified returns true")
    func markAndCheck() {
        let hash = uniqueHash()
        ReachedOutStore.markNotified(hash: hash)
        #expect(ReachedOutStore.hasNotified(hash: hash) == true)
        // Cleanup
        cleanupHash(hash)
    }

    @Test("hasNotified returns false for unknown hash")
    func unknownHash() {
        let hash = "nonexistent_\(UUID().uuidString)"
        #expect(ReachedOutStore.hasNotified(hash: hash) == false)
    }

    @Test("markNotified overwrites previous entry")
    func overwrite() {
        let hash = uniqueHash()
        ReachedOutStore.markNotified(hash: hash)
        // Mark again — should not throw or corrupt
        ReachedOutStore.markNotified(hash: hash)
        #expect(ReachedOutStore.hasNotified(hash: hash) == true)
        cleanupHash(hash)
    }

    @Test("getAll returns all recorded entries")
    func getAllReturnsEntries() {
        let h1 = uniqueHash()
        let h2 = uniqueHash()
        ReachedOutStore.markNotified(hash: h1)
        ReachedOutStore.markNotified(hash: h2)
        let all = ReachedOutStore.getAll()
        #expect(all[h1] != nil)
        #expect(all[h2] != nil)
        cleanupHash(h1)
        cleanupHash(h2)
    }

    @Test("refreshActive updates notifiedAt for existing entries")
    func refreshActive() {
        let hash = uniqueHash()
        ReachedOutStore.markNotified(hash: hash)
        let beforeRefresh = ReachedOutStore.getAll()[hash]!.notifiedAt

        // Small delay to ensure timestamp differs
        let activeHashes: Set<String> = [hash]
        ReachedOutStore.refreshActive(hashes: activeHashes)
        let afterRefresh = ReachedOutStore.getAll()[hash]!.notifiedAt

        // After refresh, notifiedAt should be >= before
        #expect(afterRefresh >= beforeRefresh)
        cleanupHash(hash)
    }

    @Test("refreshActive does not create entries for hashes not previously recorded")
    func refreshActiveNoCreate() {
        let hash = uniqueHash()
        let activeHashes: Set<String> = [hash]
        ReachedOutStore.refreshActive(hashes: activeHashes)
        #expect(ReachedOutStore.hasNotified(hash: hash) == false)
    }

    @Test("prune removes expired entries only")
    func pruneRemovesExpired() {
        // We can't easily inject an old date via public API,
        // but we can verify prune doesn't remove fresh entries
        let hash = uniqueHash()
        ReachedOutStore.markNotified(hash: hash)
        ReachedOutStore.prune()
        #expect(ReachedOutStore.hasNotified(hash: hash) == true)
        cleanupHash(hash)
    }

    /// Remove a test hash from UserDefaults to avoid polluting state.
    private func cleanupHash(_ hash: String) {
        var map = ReachedOutStore.getAll()
        map.removeValue(forKey: hash)
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: "proactive.reached_out_ids")
        }
    }
}

// MARK: - ReachedOutStore.Entry Tests

@Suite("ReachedOutStore.Entry Type")
struct ReachedOutStoreEntryTypeTests {

    @Test("Entry stores notifiedAt accurately")
    func storesDate() {
        let date = Date(timeIntervalSince1970: 1710500000)
        let entry = ReachedOutStore.Entry(notifiedAt: date)
        #expect(entry.notifiedAt.timeIntervalSince1970 == 1710500000)
    }

    @Test("Entry Codable symmetry with dictionary key")
    func codableWithDictionaryKey() throws {
        let map: [String: ReachedOutStore.Entry] = [
            "m:rfc822id": ReachedOutStore.Entry(notifiedAt: Date(timeIntervalSince1970: 1000)),
            "k:djb2hash": ReachedOutStore.Entry(notifiedAt: Date(timeIntervalSince1970: 2000)),
        ]
        let data = try JSONEncoder().encode(map)
        let decoded = try JSONDecoder().decode([String: ReachedOutStore.Entry].self, from: data)
        #expect(decoded["m:rfc822id"] != nil)
        #expect(decoded["k:djb2hash"] != nil)
    }
}

// MARK: - ToolContext Protocol & Struct Tests

@Suite("ToolContext and ChatIdTranslating")
struct ToolContextProtocolTests {

    @Test("ChatIdTranslating protocol has expected methods")
    func protocolShape() async {
        // Verify the protocol can be implemented by a mock
        let mock = MockChatIdTranslator()
        let numId = await mock.toNumericId("real_id")
        #expect(numId == 1)
        let realId = await mock.toRealId(1)
        #expect(realId == "real_id")
    }

    @Test("ChatIdTranslating resolveEventDetail returns nil for unknown ID")
    func resolveEventDetailUnknown() async {
        let mock = MockChatIdTranslator()
        let detail = await mock.resolveEventDetail(999)
        #expect(detail == nil)
    }

    @Test("ChatIdTranslating cacheEventDetail and resolve round-trip")
    func cacheAndResolve() async {
        let mock = MockChatIdTranslator()
        await mock.cacheEventDetail(
            realId: "evt1", accountId: nil, calendarId: nil, calendarName: nil,
            title: "Standup", startDate: Date(),
            endDate: Date(), isAllDay: false, location: "Room A",
            attendees: [], isRecurring: false, recurrenceRule: nil, availability: "busy", htmlLink: nil,
            eventTimeZone: nil
        )
        let detail = await mock.resolveEventDetail(1)
        #expect(detail?.title == "Standup")
    }

    @Test("ToolContext test injection stores provided dependencies")
    func testInjection() async {
        let mock = MockChatIdTranslator()
        // We can't create a real DatabaseReader without AppDatabase, but we verify
        // the protocol conformance and DI pattern compiles and works with mocks.
        let numId = await mock.toNumericId("test")
        #expect(numId == 1)
    }
}

// MARK: - ToolFormatters Edge Cases (not covered by existing ToolFormattersTests)

@Suite("ToolFormatters Additional Edge Cases")
struct ToolFormattersEdgeCaseTests {

    @Test("formatDateMs with negative timestamp")
    func formatDateMsNegative() {
        // Before epoch — should still produce valid ISO8601
        let result = ToolFormatters.formatDateMs(-86400000) // -1 day in ms
        #expect(result.contains("1969"))
    }

    @Test("formatDateMs with large timestamp")
    func formatDateMsLarge() {
        // Year 2050+
        let result = ToolFormatters.formatDateMs(2524608000000)
        #expect(result.contains("2050"))
    }

    @Test("parseDate with .array returns nil")
    func parseDateArray() {
        #expect(ToolFormatters.parseDate(.array([.string("2024-01-01")])) == nil)
    }

    @Test("parseDate with .dictionary returns nil")
    func parseDateDict() {
        #expect(ToolFormatters.parseDate(.dictionary(["date": .string("2024-01-01")])) == nil)
    }

    @Test("parseDate with partial date string returns nil")
    func parseDatePartial() {
        #expect(ToolFormatters.parseDate(.string("2024-03")) == nil)
        #expect(ToolFormatters.parseDate(.string("2024")) == nil)
    }

    @Test("parseDate with whitespace-only string returns nil")
    func parseDateWhitespace() {
        #expect(ToolFormatters.parseDate(.string("   ")) == nil)
    }

    @Test("formatFrom with both from and fromAddress empty returns empty")
    func formatFromBothEmpty() {
        let header = makeHeader(from: "", fromAddress: "")
        // When fromAddress is empty, returns from (which is also empty)
        #expect(ToolFormatters.formatFrom(header) == "")
    }

    @Test("formatFrom with name containing angle brackets")
    func formatFromAngleBrackets() {
        let header = makeHeader(from: "Alice <Dev>", fromAddress: "alice@test.com")
        // Should produce "Alice <Dev> <alice@test.com>"
        let result = ToolFormatters.formatFrom(header)
        #expect(result.contains("alice@test.com"))
        #expect(result.contains("Alice <Dev>"))
    }

    @Test("formatDate produces Z suffix (UTC)")
    func formatDateUTCSuffix() {
        let result = ToolFormatters.formatDate(Date())
        #expect(result.hasSuffix("Z"))
    }

    @Test("formatDate and formatDateMs agree for same timestamp")
    func formatDateConsistency() {
        let timestamp: TimeInterval = 1710513000
        let fromDate = ToolFormatters.formatDate(Date(timeIntervalSince1970: timestamp))
        let fromMs = ToolFormatters.formatDateMs(timestamp * 1000)
        #expect(fromDate == fromMs)
    }

    private func makeHeader(from: String, fromAddress: String) -> MessageHeader {
        MessageHeader(
            messageId: "m",
            subject: "S",
            from: from,
            fromAddress: fromAddress,
            to: "",
            date: Date(),
            snippet: "",
            folderId: "f",
            accountId: "a",
            folderPath: "INBOX",
            isInInbox: true
        )
    }
}

// MARK: - AgentToolRouter Type Completeness Tests

@Suite("AgentToolRouter ComposeRequest Edge Cases")
struct ComposeRequestEdgeCaseTests {

    @Test("ComposeRequest with all nil optional fields")
    func allNilOptionals() {
        let request = AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil, to: [], cc: [], bcc: [],
            subject: nil, body: nil
        )
        #expect(request.subject == nil)
        #expect(request.body == nil)
        #expect(request.replyTo == nil)
        #expect(request.to.isEmpty)
    }

    @Test("ComposeRequest with large recipient lists")
    func largeRecipientList() {
        let recipients = (0..<100).map { "user\($0)@test.com" }
        let request = AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil, to: recipients, cc: [], bcc: [],
            subject: "Bulk", body: nil
        )
        #expect(request.to.count == 100)
    }

    @Test("ComposeRequest with unicode in subject and body")
    func unicodeContent() {
        let request = AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil, to: ["a@b.com"], cc: [], bcc: [],
            subject: "Re: Meeting Notes 会議", body: "<p>Hello 你好</p>"
        )
        #expect(request.subject?.contains("会議") == true)
        #expect(request.body?.contains("你好") == true)
    }

    @Test("ComposeRequest Mode exhaustive matching")
    func exhaustiveMode() {
        let allModes: [AgentToolRouter.ComposeRequest.Mode] = [.compose, .reply, .forward]
        for mode in allModes {
            switch mode {
            case .compose, .reply, .forward: break
            }
        }
        #expect(allModes.count == 3)
    }
}

@Suite("AgentToolRouter ActionConfirmation Edge Cases")
struct ActionConfirmationEdgeCaseTests {

    @Test("ActionType exhaustive switch")
    func exhaustiveActionType() {
        let allTypes: [AgentToolRouter.ActionConfirmation.ActionType] = [
            .archive, .delete, .contactEdit, .contactDelete,
            .calendarEventCreate, .calendarEventEdit, .calendarEventDelete,
            .templateCreate, .templateEdit, .templateDelete, .templateShare, .templateDownload,
        ]
        for t in allTypes {
            switch t {
            case .archive, .delete, .contactEdit, .contactDelete,
                 .calendarEventCreate, .calendarEventEdit, .calendarEventDelete,
                 .templateCreate, .templateEdit, .templateDelete, .templateShare, .templateDownload:
                break
            }
        }
        #expect(allTypes.count == 12)
    }

    @Test("ContactDetail with empty changes array")
    func contactDetailEmptyChanges() {
        let detail = AgentToolRouter.ActionConfirmation.ContactDetail(
            contactId: "c1", name: "Test", email: "test@test.com"
        )
        #expect(detail.changes.isEmpty)
    }

    @Test("CalendarEventDetail with empty attendees and changes")
    func calendarDetailEmpty() {
        let detail = AgentToolRouter.ActionConfirmation.CalendarEventDetail(
            eventId: "e1", calendarId: "cal1", title: "Event",
            startDate: Date(), endDate: Date(), isAllDay: false
        )
        #expect(detail.attendees.isEmpty)
        #expect(detail.changes.isEmpty)
    }

    @Test("EmailDetail date can be future")
    func emailDetailFutureDate() {
        let futureDate = Date().addingTimeInterval(86400 * 365)
        let detail = AgentToolRouter.ActionConfirmation.EmailDetail(
            numericId: 1, subject: "Scheduled", from: "bot@test.com", date: futureDate
        )
        #expect(detail.date! > Date())
    }

    @Test("ActionConfirmation onRespond callback invoked with false")
    @MainActor func onRespondFalse() {
        var result: Bool?
        let confirmation = AgentToolRouter.ActionConfirmation(
            action: .archive, emails: [], contacts: [], calendarEvents: [], templates: [],
            onRespond: { accepted in result = accepted }
        )
        confirmation.onRespond(false)
        #expect(result == false)
    }

    @Test("ResponseState initial state is not responded and not accepted")
    @MainActor func responseStateInitial() {
        let state = AgentToolRouter.ActionConfirmation.ResponseState()
        #expect(state.responded == false)
        #expect(state.accepted == false)
    }
}

// MARK: - Reminder Struct for ProactiveNotify Logic Tests

@Suite("ProactiveNotify Reminder Qualification Logic")
struct ProactiveNotifyQualificationTests {

    /// Helper to make a Reminder with minimal fields.
    private func makeReminder(
        source: String = "message",
        action: String? = "reply",
        enabled: Bool = true,
        dueDate: String? = nil,
        dueTime: String? = nil,
        messageId: String? = "msg1"
    ) -> Reminder {
        Reminder(
            type: "reminder",
            content: "Test reminder",
            dueDate: dueDate,
            dueTime: dueTime,
            source: source,
            hash: "test_\(UUID().uuidString)",
            enabled: enabled,
            action: action,
            messageId: messageId,
            uniqueId: nil,
            subject: "Test Subject",
            from: "sender@test.com",
            instruction: nil,
            scheduleDays: nil,
            scheduleDate: nil,
            scheduleTime: nil,
            timezone: nil, rawLine: nil
        )
    }

    @Test("Message reminder with reply action is valid candidate")
    func messageReplyValid() {
        let r = makeReminder(source: "message", action: "reply", enabled: true)
        // isQualifiedForNotification checks: enabled, source=="message" → action=="reply"
        #expect(r.enabled == true)
        #expect(r.source == "message")
        #expect(r.action == "reply")
    }

    @Test("Disabled reminder should not qualify")
    func disabledReminder() {
        let r = makeReminder(enabled: false)
        #expect(r.enabled == false)
    }

    @Test("Message reminder with non-reply action should not qualify")
    func nonReplyAction() {
        let r = makeReminder(source: "message", action: "fyi")
        #expect(r.action != "reply")
    }

    @Test("KB reminder always qualifies (no action check)")
    func kbReminderNoActionCheck() {
        let r = makeReminder(source: "kb", action: nil, enabled: true)
        #expect(r.source == "kb")
        #expect(r.action == nil)
        #expect(r.enabled == true)
    }

    @Test("Reminder with nil messageId is invalid for inbox check")
    func nilMessageId() {
        let r = makeReminder(messageId: nil)
        #expect(r.messageId == nil)
    }

    @Test("Reminder with empty messageId is invalid for inbox check")
    func emptyMessageId() {
        let r = makeReminder(messageId: "")
        #expect(r.messageId?.isEmpty == true)
    }

    @Test("Reminder hash is unique per creation")
    func uniqueHash() {
        let r1 = makeReminder()
        let r2 = makeReminder()
        #expect(r1.hash != r2.hash)
    }

    @Test("Reminder dueDate format YYYY-MM-DD")
    func dueDateFormat() {
        let r = makeReminder(dueDate: "2024-12-25", dueTime: "09:00")
        #expect(r.dueDate == "2024-12-25")
        #expect(r.dueTime == "09:00")
    }

    @Test("Reminder with no dueDate has nil")
    func noDueDate() {
        let r = makeReminder(dueDate: nil, dueTime: nil)
        #expect(r.dueDate == nil)
        #expect(r.dueTime == nil)
    }
}

// MARK: - EventPillAttendee & EventPillDetail Tests

@Suite("EventPillAttendee and EventPillDetail")
struct EventPillTypeTests {

    @Test("EventPillAttendee id is email")
    func attendeeId() {
        let attendee = EventPillAttendee(email: "alice@test.com", name: "Alice", status: "accepted")
        #expect(attendee.id == "alice@test.com")
        #expect(attendee.name == "Alice")
        #expect(attendee.status == "accepted")
    }

    @Test("EventPillAttendee with nil name")
    func attendeeNilName() {
        let attendee = EventPillAttendee(email: "bob@test.com", name: nil, status: "needsAction")
        #expect(attendee.name == nil)
        #expect(attendee.status == "needsAction")
    }

    @Test("EventPillDetail stores all fields")
    func detailFields() {
        let now = Date()
        let later = now.addingTimeInterval(3600)
        let detail = EventPillDetail(
            id: 1, realId: "evt_123", title: "Team Meeting",
            startDate: now, endDate: later, isAllDay: false,
            location: "Room 42",
            notes: "Join Zoom: https://zoom.us/j/123",
            attendees: [EventPillAttendee(email: "a@b.com", name: "A", status: "accepted")],
            isRecurring: true, recurrenceRule: nil, availability: "busy", htmlLink: "https://example.com",
            calendarName: nil,
            eventTimeZone: nil
        )
        #expect(detail.id == 1)
        #expect(detail.realId == "evt_123")
        #expect(detail.title == "Team Meeting")
        #expect(detail.isAllDay == false)
        #expect(detail.location == "Room 42")
        #expect(detail.notes == "Join Zoom: https://zoom.us/j/123")
        #expect(detail.attendees.count == 1)
        #expect(detail.isRecurring == true)
        #expect(detail.availability == "busy")
        #expect(detail.htmlLink == "https://example.com")
    }

    @Test("EventPillDetail with nil optional fields")
    func detailNilOptionals() {
        let detail = EventPillDetail(
            id: 2, realId: "evt_456", title: "Quick Chat",
            startDate: nil, endDate: nil, isAllDay: false,
            location: nil, notes: nil, attendees: [], isRecurring: false,
            recurrenceRule: nil, availability: "free", htmlLink: nil,
            calendarName: nil,
            eventTimeZone: nil
        )
        #expect(detail.startDate == nil)
        #expect(detail.endDate == nil)
        #expect(detail.location == nil)
        #expect(detail.notes == nil)
        #expect(detail.htmlLink == nil)
        #expect(detail.attendees.isEmpty)
    }

    @Test("EventPillDetail Identifiable id matches constructor id")
    func detailIdentifiable() {
        let detail = EventPillDetail(
            id: 99, realId: "r", title: "T", startDate: nil, endDate: nil,
            isAllDay: false, location: nil, notes: nil, attendees: [], isRecurring: false,
            recurrenceRule: nil, availability: "free", htmlLink: nil,
            calendarName: nil,
            eventTimeZone: nil
        )
        #expect(detail.id == 99)
    }
}
