/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Reminder Struct Tests

@Suite("Reminder Struct")
struct ReminderTests {

    @Test("Reminder init with all fields")
    func initAllFields() {
        let r = Reminder(
            type: "reminder",
            content: "Follow up with Bob",
            dueDate: "2024-03-20",
            dueTime: "14:00",
            source: "message",
            hash: "abc123",
            enabled: true,
            action: "reply",
            messageId: "msg1",
            uniqueId: "u1",
            subject: "Re: Budget",
            from: "bob@test.com",
            instruction: nil,
            scheduleDays: nil,
            scheduleDate: nil,
            scheduleTime: nil,
            timezone: nil, rawLine: nil
        )
        #expect(r.content == "Follow up with Bob")
        #expect(r.dueDate == "2024-03-20")
        #expect(r.dueTime == "14:00")
        #expect(r.source == "message")
        #expect(r.hash == "abc123")
        #expect(r.enabled == true)
        #expect(r.action == "reply")
        #expect(r.messageId == "msg1")
        #expect(r.subject == "Re: Budget")
    }

    @Test("Reminder with minimal fields (KB source)")
    func kbSourceReminder() {
        let r = Reminder(
            type: "reminder",
            content: "Weekly standup every Monday",
            dueDate: nil,
            dueTime: nil,
            source: "kb",
            hash: "kb_hash_1",
            enabled: true,
            action: nil,
            messageId: nil,
            uniqueId: nil,
            subject: nil,
            from: nil,
            instruction: nil,
            scheduleDays: nil,
            scheduleDate: nil,
            scheduleTime: nil,
            timezone: nil, rawLine: nil
        )
        #expect(r.source == "kb")
        #expect(r.dueDate == nil)
        #expect(r.messageId == nil)
    }

    @Test("Reminder disabled state")
    func disabledReminder() {
        let r = Reminder(
            type: "reminder",
            content: "Disabled reminder",
            dueDate: nil, dueTime: nil,
            source: "message", hash: "h1", enabled: false,
            action: nil, messageId: nil, uniqueId: nil,
            subject: nil, from: nil,
            instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil
        )
        #expect(r.enabled == false)
    }
}

// MARK: - isUrgent Tests

@Suite("ReminderBuilder.isUrgent")
struct IsUrgentTests {

    /// Helper to make a Reminder with a given dueDate string.
    private func makeReminder(dueDate: String?, dueTime: String? = nil) -> Reminder {
        Reminder(
            type: "reminder",
            content: "test",
            dueDate: dueDate,
            dueTime: dueTime,
            source: "kb",
            hash: "h",
            enabled: true,
            action: nil,
            messageId: nil,
            uniqueId: nil,
            subject: nil,
            from: nil,
            instruction: nil,
            scheduleDays: nil,
            scheduleDate: nil,
            scheduleTime: nil,
            timezone: nil, rawLine: nil
        )
    }

    @Test("No due date is not urgent")
    func noDueDate() {
        #expect(ReminderBuilder.isUrgent(makeReminder(dueDate: nil)) == false)
    }

    @Test("Malformed date is not urgent")
    func malformedDate() {
        #expect(ReminderBuilder.isUrgent(makeReminder(dueDate: "not-a-date")) == false)
    }

    @Test("Incomplete date parts is not urgent")
    func incompleteDateParts() {
        #expect(ReminderBuilder.isUrgent(makeReminder(dueDate: "2024-03")) == false)
    }

    @Test("Non-numeric date parts is not urgent")
    func nonNumericDateParts() {
        #expect(ReminderBuilder.isUrgent(makeReminder(dueDate: "abc-def-ghi")) == false)
    }

    @Test("Today's date is urgent")
    func todayIsUrgent() {
        let calendar = Calendar.current
        let today = Date()
        let y = calendar.component(.year, from: today)
        let m = calendar.component(.month, from: today)
        let d = calendar.component(.day, from: today)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        #expect(ReminderBuilder.isUrgent(makeReminder(dueDate: dateStr)) == true)
    }

    @Test("Tomorrow's date is urgent")
    func tomorrowIsUrgent() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        let y = calendar.component(.year, from: tomorrow)
        let m = calendar.component(.month, from: tomorrow)
        let d = calendar.component(.day, from: tomorrow)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        #expect(ReminderBuilder.isUrgent(makeReminder(dueDate: dateStr)) == true)
    }

    @Test("Yesterday (overdue) is urgent")
    func overdueIsUrgent() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let y = calendar.component(.year, from: yesterday)
        let m = calendar.component(.month, from: yesterday)
        let d = calendar.component(.day, from: yesterday)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        #expect(ReminderBuilder.isUrgent(makeReminder(dueDate: dateStr)) == true)
    }

    @Test("Far past overdue is urgent")
    func farPastIsUrgent() {
        let calendar = Calendar.current
        let pastDate = calendar.date(byAdding: .day, value: -30, to: Date())!
        let y = calendar.component(.year, from: pastDate)
        let m = calendar.component(.month, from: pastDate)
        let d = calendar.component(.day, from: pastDate)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        #expect(ReminderBuilder.isUrgent(makeReminder(dueDate: dateStr)) == true)
    }

    @Test("Day after tomorrow is not urgent")
    func dayAfterTomorrowNotUrgent() {
        let calendar = Calendar.current
        let future = calendar.date(byAdding: .day, value: 2, to: Date())!
        let y = calendar.component(.year, from: future)
        let m = calendar.component(.month, from: future)
        let d = calendar.component(.day, from: future)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        #expect(ReminderBuilder.isUrgent(makeReminder(dueDate: dateStr)) == false)
    }

    @Test("Far future date is not urgent")
    func farFutureNotUrgent() {
        #expect(ReminderBuilder.isUrgent(makeReminder(dueDate: "2099-12-31")) == false)
    }
}

// MARK: - formatDueLabelForCard Tests

@Suite("ReminderBuilder.formatDueLabelForCard")
struct FormatDueLabelForCardTests {

    private func makeReminder(dueDate: String?, dueTime: String? = nil) -> Reminder {
        Reminder(
            type: "reminder",
            content: "test",
            dueDate: dueDate,
            dueTime: dueTime,
            source: "kb",
            hash: "h",
            enabled: true,
            action: nil,
            messageId: nil,
            uniqueId: nil,
            subject: nil,
            from: nil,
            instruction: nil,
            scheduleDays: nil,
            scheduleDate: nil,
            scheduleTime: nil,
            timezone: nil, rawLine: nil
        )
    }

    @Test("No due date returns nil")
    func noDueDate() {
        #expect(ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: nil)) == nil)
    }

    @Test("Malformed date returns nil")
    func malformedDate() {
        #expect(ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: "bad")) == nil)
    }

    @Test("Incomplete date parts returns nil")
    func incompleteParts() {
        #expect(ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: "2024-03")) == nil)
    }

    @Test("Non-numeric parts returns nil")
    func nonNumericParts() {
        #expect(ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: "abc-def-ghi")) == nil)
    }

    @Test("Today shows 'Today'")
    func today() {
        let calendar = Calendar.current
        let now = Date()
        let y = calendar.component(.year, from: now)
        let m = calendar.component(.month, from: now)
        let d = calendar.component(.day, from: now)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        #expect(ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: dateStr)) == "Today")
    }

    @Test("Today with time shows 'Today at HH:MM'")
    func todayWithTime() {
        let calendar = Calendar.current
        let now = Date()
        let y = calendar.component(.year, from: now)
        let m = calendar.component(.month, from: now)
        let d = calendar.component(.day, from: now)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        #expect(ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: dateStr, dueTime: "14:30")) == "Today at 14:30")
    }

    @Test("Tomorrow shows 'Tomorrow'")
    func tomorrow() {
        let calendar = Calendar.current
        let tmrw = calendar.date(byAdding: .day, value: 1, to: Date())!
        let y = calendar.component(.year, from: tmrw)
        let m = calendar.component(.month, from: tmrw)
        let d = calendar.component(.day, from: tmrw)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        #expect(ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: dateStr)) == "Tomorrow")
    }

    @Test("Tomorrow with time shows 'Tomorrow at HH:MM'")
    func tomorrowWithTime() {
        let calendar = Calendar.current
        let tmrw = calendar.date(byAdding: .day, value: 1, to: Date())!
        let y = calendar.component(.year, from: tmrw)
        let m = calendar.component(.month, from: tmrw)
        let d = calendar.component(.day, from: tmrw)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        #expect(ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: dateStr, dueTime: "09:00")) == "Tomorrow at 09:00")
    }

    @Test("Yesterday shows overdue 1 day")
    func yesterdayOverdue() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let y = calendar.component(.year, from: yesterday)
        let m = calendar.component(.month, from: yesterday)
        let d = calendar.component(.day, from: yesterday)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        #expect(ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: dateStr)) == "Overdue (1 day)")
    }

    @Test("3 days overdue shows plural days")
    func threeDaysOverdue() {
        let calendar = Calendar.current
        let past = calendar.date(byAdding: .day, value: -3, to: Date())!
        let y = calendar.component(.year, from: past)
        let m = calendar.component(.month, from: past)
        let d = calendar.component(.day, from: past)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        #expect(ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: dateStr)) == "Overdue (3 days)")
    }

    @Test("Future date shows 'Due EEE, MMM d'")
    func futureDate() {
        let calendar = Calendar.current
        let future = calendar.date(byAdding: .day, value: 7, to: Date())!
        let y = calendar.component(.year, from: future)
        let m = calendar.component(.month, from: future)
        let d = calendar.component(.day, from: future)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        let result = ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: dateStr))
        #expect(result != nil)
        #expect(result!.hasPrefix("Due "))
    }

    @Test("Future date with time includes time suffix")
    func futureDateWithTime() {
        let calendar = Calendar.current
        let future = calendar.date(byAdding: .day, value: 7, to: Date())!
        let y = calendar.component(.year, from: future)
        let m = calendar.component(.month, from: future)
        let d = calendar.component(.day, from: future)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        let result = ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: dateStr, dueTime: "16:00"))
        #expect(result != nil)
        #expect(result!.hasPrefix("Due "))
        #expect(result!.hasSuffix(" at 16:00"))
    }

    @Test("Overdue does not include time suffix")
    func overdueNoTimeSuffix() {
        let calendar = Calendar.current
        let past = calendar.date(byAdding: .day, value: -2, to: Date())!
        let y = calendar.component(.year, from: past)
        let m = calendar.component(.month, from: past)
        let d = calendar.component(.day, from: past)
        let dateStr = String(format: "%04d-%02d-%02d", y, m, d)
        // Overdue format doesn't include time
        let result = ReminderBuilder.formatDueLabelForCard(makeReminder(dueDate: dateStr, dueTime: "10:00"))
        #expect(result == "Overdue (2 days)")
    }
}

// MARK: - formatRemindersJSON Tests

@Suite("ReminderBuilder.formatRemindersJSON")
struct FormatRemindersJSONTests {

    @Test("Empty array returns '[]'")
    func emptyArray() async {
        let result = await ReminderBuilder.formatRemindersJSON([])
        #expect(result == "[]")
    }

    @Test("Single reminder with all fields produces valid JSON")
    func singleReminderAllFields() async {
        let r = Reminder(
            type: "reminder",
            content: "Follow up",
            dueDate: "2024-03-20",
            dueTime: "14:00",
            source: "message",
            hash: "h1",
            enabled: true,
            action: "reply",
            messageId: "msg1",
            uniqueId: "u1",
            subject: "Budget",
            from: "bob@test.com",
            instruction: nil,
            scheduleDays: nil,
            scheduleDate: nil,
            scheduleTime: nil,
            timezone: nil, rawLine: nil
        )
        let json = await ReminderBuilder.formatRemindersJSON([r])
        #expect(json != "[]")
        // Validate it's parseable JSON
        let data = json.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        #expect(parsed.count == 1)
        let item = parsed[0]
        #expect(item["content"] as? String == "Follow up")
        #expect(item["source"] as? String == "message")
        #expect(item["dueDate"] as? String == "2024-03-20")
        #expect(item["dueTime"] as? String == "14:00")
        #expect(item["subject"] as? String == "Budget")
        #expect(item["from"] as? String == "bob@test.com")
        #expect(item["action"] as? String == "reply")
        // uniqueId and messageId are translated to numeric IDs
        #expect(item["uniqueId"] != nil)
        #expect(item["messageId"] != nil)
    }

    @Test("KB reminder with nil optional fields omits them from JSON")
    func kbReminderMinimalFields() async {
        let r = Reminder(
            type: "reminder",
            content: "Weekly standup",
            dueDate: nil,
            dueTime: nil,
            source: "kb",
            hash: "h2",
            enabled: true,
            action: nil,
            messageId: nil,
            uniqueId: nil,
            subject: nil,
            from: nil,
            instruction: nil,
            scheduleDays: nil,
            scheduleDate: nil,
            scheduleTime: nil,
            timezone: nil, rawLine: nil
        )
        let json = await ReminderBuilder.formatRemindersJSON([r])
        let data = json.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        #expect(parsed.count == 1)
        let item = parsed[0]
        #expect(item["content"] as? String == "Weekly standup")
        #expect(item["source"] as? String == "kb")
        // Nil fields should not be present
        #expect(item["dueDate"] == nil)
        #expect(item["dueTime"] == nil)
        #expect(item["subject"] == nil)
        #expect(item["from"] == nil)
        #expect(item["action"] == nil)
        #expect(item["uniqueId"] == nil)
        #expect(item["messageId"] == nil)
    }

    @Test("Multiple reminders produce array with correct count")
    func multipleReminders() async {
        let reminders = [
            Reminder(type: "reminder", content: "First", dueDate: nil, dueTime: nil, source: "kb", hash: "h1", enabled: true, action: nil, messageId: nil, uniqueId: nil, subject: nil, from: nil, instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil),
            Reminder(type: "reminder", content: "Second", dueDate: "2024-06-01", dueTime: nil, source: "message", hash: "h2", enabled: true, action: nil, messageId: nil, uniqueId: nil, subject: nil, from: nil, instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil),
            Reminder(type: "reminder", content: "Third", dueDate: nil, dueTime: nil, source: "kb", hash: "h3", enabled: true, action: nil, messageId: nil, uniqueId: nil, subject: nil, from: nil, instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil),
        ]
        let json = await ReminderBuilder.formatRemindersJSON(reminders)
        let data = json.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        #expect(parsed.count == 3)
    }

    @Test("JSON uses sorted keys")
    func sortedKeys() async {
        let r = Reminder(
            type: "reminder",
            content: "Test",
            dueDate: "2024-01-01",
            dueTime: nil,
            source: "kb",
            hash: "h",
            enabled: true,
            action: nil,
            messageId: nil,
            uniqueId: nil,
            subject: nil,
            from: nil,
            instruction: nil,
            scheduleDays: nil,
            scheduleDate: nil,
            scheduleTime: nil,
            timezone: nil, rawLine: nil
        )
        let json = await ReminderBuilder.formatRemindersJSON([r])
        // With sortedKeys, "content" should appear before "source"
        let contentIndex = json.range(of: "\"content\"")!.lowerBound
        let sourceIndex = json.range(of: "\"source\"")!.lowerBound
        #expect(contentIndex < sourceIndex)
    }
}

// MARK: - Task Integration Tests

@Suite("ReminderBuilder Task Integration")
struct ReminderBuilderTaskIntegrationTests {

    private func makeReminder(type: String = "reminder", content: String, dueDate: String? = nil,
                              source: String = "kb", hash: String, enabled: Bool = true) -> Reminder {
        Reminder(
            type: type, content: content, dueDate: dueDate, dueTime: nil,
            source: source, hash: hash, enabled: enabled,
            action: nil, messageId: nil, uniqueId: nil, subject: nil, from: nil,
            instruction: type == "task" ? content : nil,
            scheduleDays: type == "task" ? "daily" : nil,
            scheduleDate: nil,
            scheduleTime: type == "task" ? "09:00" : nil,
            timezone: nil, rawLine: nil
        )
    }

    @Test("Reminder struct with type='task' has correct isOneOff for recurring")
    func taskReminderRecurring() {
        let r = Reminder(
            type: "task", content: "Morning check", dueDate: nil, dueTime: nil,
            source: "kb", hash: "t:abc", enabled: true,
            action: nil, messageId: nil, uniqueId: nil, subject: nil, from: nil,
            instruction: "Morning check", scheduleDays: "weekdays",
            scheduleDate: nil, scheduleTime: "09:00", timezone: "America/Vancouver", rawLine: "- [Task] Schedule weekdays 09:00, Morning check"
        )
        #expect(r.type == "task")
        #expect(r.isOneOff == false)
        #expect(r.instruction == "Morning check")
        #expect(r.scheduleDays == "weekdays")
    }

    @Test("Reminder struct with type='task' has correct isOneOff for one-off")
    func taskReminderOneOff() {
        let r = Reminder(
            type: "task", content: "Follow up", dueDate: nil, dueTime: nil,
            source: "kb", hash: "t:xyz", enabled: true,
            action: nil, messageId: nil, uniqueId: nil, subject: nil, from: nil,
            instruction: "Follow up", scheduleDays: nil,
            scheduleDate: "2026/04/15", scheduleTime: "15:00", timezone: nil, rawLine: ""
        )
        #expect(r.isOneOff == true)
    }

    @Test("Sorting: tasks sort after regular reminders")
    func tasksSortAfterReminders() {
        var items = [
            makeReminder(type: "task", content: "Task A", hash: "t:a"),
            makeReminder(content: "Reminder B", dueDate: "2026-04-10", hash: "k:b"),
            makeReminder(type: "task", content: "Task C", hash: "t:c"),
            makeReminder(content: "Reminder D", hash: "k:d"),
        ]
        items.sort { a, b in
            if a.type == "task" && b.type != "task" { return false }
            if a.type != "task" && b.type == "task" { return true }
            if a.dueDate != nil && b.dueDate == nil { return true }
            if a.dueDate == nil && b.dueDate != nil { return false }
            if let aDate = a.dueDate, let bDate = b.dueDate {
                return aDate < bDate
            }
            return false
        }
        // Reminders should come first
        #expect(items[0].type == "reminder")
        #expect(items[1].type == "reminder")
        // Tasks should be at the end
        #expect(items[2].type == "task")
        #expect(items[3].type == "task")
    }

    @Test("Sorting: due-dated reminders before undated reminders, both before tasks")
    func sortingOrder() {
        var items = [
            makeReminder(type: "task", content: "Task", hash: "t:1"),
            makeReminder(content: "Undated reminder", hash: "k:2"),
            makeReminder(content: "Dated reminder", dueDate: "2026-04-08", hash: "k:3"),
        ]
        items.sort { a, b in
            if a.type == "task" && b.type != "task" { return false }
            if a.type != "task" && b.type == "task" { return true }
            if a.dueDate != nil && b.dueDate == nil { return true }
            if a.dueDate == nil && b.dueDate != nil { return false }
            if let aDate = a.dueDate, let bDate = b.dueDate {
                return aDate < bDate
            }
            return false
        }
        #expect(items[0].content == "Dated reminder")
        #expect(items[1].content == "Undated reminder")
        #expect(items[2].content == "Task")
    }

    @Test("invalidateCache clears both parser and list caches with explicit lazy rebuild")
    func invalidateCacheClearsAll() async {
        ReminderBuilder.invalidateCache()
        ReminderBuilder.invalidateCache()
        _ = await ReminderBuilder.buildReminderList(includeDisabled: true)
    }

    @Test("formatRemindersJSON includes task fields when present")
    func formatTaskInJSON() async {
        let r = Reminder(
            type: "task", content: "Check emails", dueDate: nil, dueTime: nil,
            source: "kb", hash: "t:abc", enabled: true,
            action: nil, messageId: nil, uniqueId: nil, subject: nil, from: nil,
            instruction: "Check emails", scheduleDays: "weekdays",
            scheduleDate: nil, scheduleTime: "09:00", timezone: "America/Vancouver", rawLine: ""
        )
        let json = await ReminderBuilder.formatRemindersJSON([r])
        let data = json.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        #expect(parsed.count == 1)
        guard parsed.count == 1 else { return }
        let item = parsed[0]
        #expect(item["content"] as? String == "Check emails")
        #expect(item["source"] as? String == "kb")
    }
}

#if DEBUG
@Suite("ReminderBuilder rebuild policy", .serialized)
struct ReminderBuilderRebuildPolicyTests {
    @Test("injected XCTest environments skip only the proactive warm-up")
    func injectedEnvironmentDecision() {
        #expect(ReminderRebuildPolicy.decision(environment: [:]) == .proactive)
        #expect(ReminderRebuildPolicy.decision(environment: [
            "XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"
        ]) == .skippedUnitTestHost)
        #expect(ReminderRebuildPolicy.decision(environment: [
            "XCTestBundlePath": "/tmp/TabMailTests.xctest"
        ]) == .skippedUnitTestHost)
    }

    @Test("ordinary app-hosted unit-test host skips proactive warm-up")
    func unitTestHostSkipsProactiveWarmup() {
        let environment = ProcessInfo.processInfo.environment
        let isXCTestHost = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        #expect(isXCTestHost, "this invariant must run in the ordinary XCTest app host")
        #expect(ReminderRebuildPolicy.hostDecision == .skippedUnitTestHost)
    }
}
#endif
