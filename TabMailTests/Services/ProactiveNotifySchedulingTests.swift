/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Test Helper

/// Build a Reminder with defaults for testing. All dates generated dynamically.
private func makeReminder(
    content: String = "Test reminder",
    dueDate: String? = nil,
    dueTime: String? = nil,
    source: String = "kb",
    hash: String? = nil,
    enabled: Bool = true,
    action: String? = nil,
    messageId: String? = nil
) -> Reminder {
    Reminder(
        type: "reminder",
        content: content,
        dueDate: dueDate,
        dueTime: dueTime,
        source: source,
        hash: hash ?? "h_\(content.hashValue)",
        enabled: enabled,
        action: action,
        messageId: messageId,
        uniqueId: nil,
        subject: nil,
        from: nil,
        instruction: nil,
        scheduleDays: nil,
        scheduleDate: nil,
        scheduleTime: nil,
        timezone: nil,
        rawLine: nil
    )
}

/// Format a Date as "YYYY-MM-DD" for reminder due dates.
private func dateString(_ date: Date) -> String {
    let cal = Calendar.current
    let y = cal.component(.year, from: date)
    let m = cal.component(.month, from: date)
    let d = cal.component(.day, from: date)
    return String(format: "%04d-%02d-%02d", y, m, d)
}

/// Format a Date's time as "HH:MM" for reminder due times.
private func timeString(_ date: Date) -> String {
    let cal = Calendar.current
    let h = cal.component(.hour, from: date)
    let m = cal.component(.minute, from: date)
    return String(format: "%02d:%02d", h, m)
}

@Suite("ProactiveNotifyService.buildDueNotificationCandidates")
struct ProactiveNotifySchedulingTests {

    // MARK: - Basic filtering

    @Test("Excludes reminders without due date")
    func noDueDate() {
        let r = makeReminder(content: "no date", dueDate: nil, hash: "a")
        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: [r], advanceMinutes: 30, notifiedHashes: [], now: Date(), windowDays: 7
        )
        #expect(result.isEmpty)
    }

    @Test("Excludes disabled reminders")
    func disabledReminder() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let r = makeReminder(dueDate: dateString(tomorrow), dueTime: "14:00", hash: "b", enabled: false)
        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: [r], advanceMinutes: 30, notifiedHashes: [], now: Date(), windowDays: 7
        )
        #expect(result.isEmpty)
    }

    @Test("Excludes message reminders without reply action")
    func messageNonReply() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let r = makeReminder(
            dueDate: dateString(tomorrow), dueTime: "14:00",
            source: "message", hash: "c", action: "forward"
        )
        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: [r], advanceMinutes: 30, notifiedHashes: [], now: Date(), windowDays: 7
        )
        #expect(result.isEmpty)
    }

    @Test("Includes message reminders with reply action")
    func messageReply() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let r = makeReminder(
            dueDate: dateString(tomorrow), dueTime: "14:00",
            source: "message", hash: "d", action: "reply", messageId: "msg1"
        )
        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: [r], advanceMinutes: 30, notifiedHashes: [], now: Date(), windowDays: 7
        )
        #expect(result.count == 1)
    }

    @Test("Excludes already-notified reminders")
    func alreadyNotified() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let r = makeReminder(dueDate: dateString(tomorrow), dueTime: "14:00", hash: "e")
        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: [r], advanceMinutes: 30, notifiedHashes: ["e"], now: Date(), windowDays: 7
        )
        #expect(result.isEmpty)
    }

    @Test("Excludes past-due reminders")
    func pastDue() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let r = makeReminder(dueDate: dateString(yesterday), dueTime: "08:00", hash: "f")
        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: [r], advanceMinutes: 30, notifiedHashes: [], now: Date(), windowDays: 7
        )
        #expect(result.isEmpty)
    }

    @Test("Excludes reminders outside window")
    func outsideWindow() {
        let farFuture = Calendar.current.date(byAdding: .day, value: 30, to: Date())!
        let r = makeReminder(dueDate: dateString(farFuture), dueTime: "10:00", hash: "g")
        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: [r], advanceMinutes: 30, notifiedHashes: [], now: Date(), windowDays: 7
        )
        #expect(result.isEmpty)
    }

    @Test("Includes reminders within window")
    func withinWindow() {
        let inThreeDays = Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        let r = makeReminder(dueDate: dateString(inThreeDays), dueTime: "10:00", hash: "h")
        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: [r], advanceMinutes: 30, notifiedHashes: [], now: Date(), windowDays: 7
        )
        #expect(result.count == 1)
    }

    @Test("Excludes reminders whose fire date (due - advance) is already past")
    func fireDateAlreadyPast() {
        // Due in 10 minutes, advance is 30 minutes → fire date is 20 minutes ago
        let soonDate = Date().addingTimeInterval(10 * 60)
        let r = makeReminder(
            dueDate: dateString(soonDate),
            dueTime: timeString(soonDate),
            hash: "i"
        )
        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: [r], advanceMinutes: 30, notifiedHashes: [], now: Date(), windowDays: 7
        )
        #expect(result.isEmpty)
    }

    // MARK: - Sorting

    @Test("Results sorted by fire date ascending")
    func sortedByFireDate() {
        let cal = Calendar.current
        let day2 = cal.date(byAdding: .day, value: 2, to: Date())!
        let day5 = cal.date(byAdding: .day, value: 5, to: Date())!
        let day1 = cal.date(byAdding: .day, value: 1, to: Date())!

        let reminders = [
            makeReminder(content: "day2", dueDate: dateString(day2), dueTime: "10:00", hash: "s1"),
            makeReminder(content: "day5", dueDate: dateString(day5), dueTime: "10:00", hash: "s2"),
            makeReminder(content: "day1", dueDate: dateString(day1), dueTime: "10:00", hash: "s3"),
        ]

        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: reminders, advanceMinutes: 0, notifiedHashes: [], now: Date(), windowDays: 7
        )
        #expect(result.count == 3)
        guard result.count == 3 else { return }
        #expect(result[0].reminder.content == "day1")
        #expect(result[1].reminder.content == "day2")
        #expect(result[2].reminder.content == "day5")
    }

    // MARK: - 64-notification cap

    @Test("Caps at maxPendingNotifications")
    func capsAt64() {
        let cal = Calendar.current
        var reminders: [Reminder] = []
        for i in 0..<100 {
            let day = cal.date(byAdding: .day, value: i + 1, to: Date())!
            reminders.append(makeReminder(
                content: "r\(i)", dueDate: dateString(day), dueTime: "10:00", hash: "cap\(i)"
            ))
        }

        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: reminders, advanceMinutes: 0, notifiedHashes: [],
            now: Date(), windowDays: 365
        )
        #expect(result.count == ProactiveNotifyService.maxPendingNotifications)
    }

    @Test("Cap keeps soonest reminders, drops furthest")
    func capKeepsSoonest() {
        let cal = Calendar.current
        var reminders: [Reminder] = []
        for i in 0..<100 {
            let day = cal.date(byAdding: .day, value: i + 1, to: Date())!
            reminders.append(makeReminder(
                content: "r\(i)", dueDate: dateString(day), dueTime: "10:00", hash: "keep\(i)"
            ))
        }

        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: reminders, advanceMinutes: 0, notifiedHashes: [],
            now: Date(), windowDays: 365
        )
        guard result.count == 64 else { return }
        // First should be day+1, last should be day+64
        #expect(result.first?.reminder.content == "r0")
        #expect(result.last?.reminder.content == "r63")
    }

    @Test("Under 64 reminders schedules all")
    func under64() {
        let cal = Calendar.current
        var reminders: [Reminder] = []
        for i in 0..<10 {
            let day = cal.date(byAdding: .day, value: i + 1, to: Date())!
            reminders.append(makeReminder(
                content: "r\(i)", dueDate: dateString(day), dueTime: "10:00", hash: "all\(i)"
            ))
        }

        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: reminders, advanceMinutes: 0, notifiedHashes: [],
            now: Date(), windowDays: 365
        )
        #expect(result.count == 10)
    }

    // MARK: - Advance minutes

    @Test("Advance minutes shifts fire date earlier")
    func advanceMinutesShift() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let r = makeReminder(dueDate: dateString(tomorrow), dueTime: "14:00", hash: "adv")

        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: [r], advanceMinutes: 60, notifiedHashes: [], now: Date(), windowDays: 7
        )
        #expect(result.count == 1)
        guard result.count == 1 else { return }

        // Fire date should be 1 hour before 14:00 = 13:00
        let fireDate = result[0].fireDate
        let hour = Calendar.current.component(.hour, from: fireDate)
        #expect(hour == 13)
    }

    // MARK: - Default time

    @Test("Reminders without dueTime default to 09:00")
    func defaultTime() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let r = makeReminder(dueDate: dateString(tomorrow), dueTime: nil, hash: "def")

        let parsed = ProactiveNotifyService.parseDueDateTimeStatic(r)
        #expect(parsed != nil)
        guard let parsed else { return }
        let hour = Calendar.current.component(.hour, from: parsed)
        let minute = Calendar.current.component(.minute, from: parsed)
        #expect(hour == 9)
        #expect(minute == 0)
    }

    // MARK: - Empty input

    @Test("Empty reminder list returns empty")
    func emptyInput() {
        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: [], advanceMinutes: 30, notifiedHashes: [], now: Date(), windowDays: 7
        )
        #expect(result.isEmpty)
    }

    // MARK: - Mixed scenarios

    @Test("Mixed valid and invalid reminders filters correctly")
    func mixedReminders() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let farFuture = cal.date(byAdding: .day, value: 30, to: Date())!

        let reminders = [
            makeReminder(content: "valid KB", dueDate: dateString(tomorrow), dueTime: "14:00", hash: "m1"),
            makeReminder(content: "no date", dueDate: nil, hash: "m2"),
            makeReminder(content: "disabled", dueDate: dateString(tomorrow), dueTime: "14:00", hash: "m3", enabled: false),
            makeReminder(content: "past due", dueDate: dateString(yesterday), dueTime: "08:00", hash: "m4"),
            makeReminder(content: "outside window", dueDate: dateString(farFuture), dueTime: "10:00", hash: "m5"),
            makeReminder(content: "valid reply", dueDate: dateString(tomorrow), dueTime: "16:00", source: "message", hash: "m6", action: "reply", messageId: "msg1"),
            makeReminder(content: "msg no reply", dueDate: dateString(tomorrow), dueTime: "16:00", source: "message", hash: "m7", action: "forward"),
            makeReminder(content: "already notified", dueDate: dateString(tomorrow), dueTime: "14:00", hash: "m8"),
        ]

        let result = ProactiveNotifyService.buildDueNotificationCandidates(
            reminders: reminders, advanceMinutes: 0, notifiedHashes: ["m8"],
            now: Date(), windowDays: 7
        )
        #expect(result.count == 2)
        guard result.count == 2 else { return }
        // Should be sorted: 14:00 before 16:00
        #expect(result[0].reminder.hash == "m1")
        #expect(result[1].reminder.hash == "m6")
    }
}
