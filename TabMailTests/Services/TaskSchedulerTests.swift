/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - parseScheduleTime Tests

@Suite("TaskScheduler.parseScheduleTime")
struct TaskSchedulerParseTimeTests {

    @Test("Valid time parses correctly")
    func validTime() {
        let result = TaskScheduler.parseScheduleTime("09:30")
        #expect(result != nil)
        #expect(result?.hour == 9)
        #expect(result?.minute == 30)
    }

    @Test("Midnight parses correctly")
    func midnight() {
        let result = TaskScheduler.parseScheduleTime("00:00")
        #expect(result != nil)
        #expect(result?.hour == 0)
        #expect(result?.minute == 0)
    }

    @Test("End of day parses correctly")
    func endOfDay() {
        let result = TaskScheduler.parseScheduleTime("23:59")
        #expect(result != nil)
        #expect(result?.hour == 23)
        #expect(result?.minute == 59)
    }

    @Test("Hour out of range returns nil")
    func hourOutOfRange() {
        #expect(TaskScheduler.parseScheduleTime("24:00") == nil)
        #expect(TaskScheduler.parseScheduleTime("25:00") == nil)
    }

    @Test("Minute out of range returns nil")
    func minuteOutOfRange() {
        #expect(TaskScheduler.parseScheduleTime("09:60") == nil)
        #expect(TaskScheduler.parseScheduleTime("12:99") == nil)
    }

    @Test("Non-numeric input returns nil")
    func nonNumeric() {
        #expect(TaskScheduler.parseScheduleTime("ab:cd") == nil)
        #expect(TaskScheduler.parseScheduleTime("nine:thirty") == nil)
    }

    @Test("Missing colon returns nil")
    func missingColon() {
        #expect(TaskScheduler.parseScheduleTime("0930") == nil)
    }

    @Test("Empty string returns nil")
    func emptyString() {
        #expect(TaskScheduler.parseScheduleTime("") == nil)
    }

    @Test("Single digit parts still parse")
    func singleDigit() {
        // "9:5" → should parse (Int("9") = 9, Int("5") = 5)
        let result = TaskScheduler.parseScheduleTime("9:5")
        #expect(result != nil)
        #expect(result?.hour == 9)
        #expect(result?.minute == 5)
    }

    @Test("Negative values return nil")
    func negativeValues() {
        #expect(TaskScheduler.parseScheduleTime("-1:30") == nil)
        #expect(TaskScheduler.parseScheduleTime("09:-5") == nil)
    }
}

// MARK: - resolveScheduleDays Tests

@Suite("TaskScheduler.resolveScheduleDays")
struct TaskSchedulerResolveDaysTests {

    @Test("daily resolves to all 7 days")
    func daily() {
        let days = TaskScheduler.resolveScheduleDays("daily")
        #expect(days == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test("weekdays resolves to Mon-Fri (2-6)")
    func weekdays() {
        let days = TaskScheduler.resolveScheduleDays("weekdays")
        #expect(days == [2, 3, 4, 5, 6])
    }

    @Test("weekends resolves to Sun and Sat (1, 7)")
    func weekends() {
        let days = TaskScheduler.resolveScheduleDays("weekends")
        #expect(days == [1, 7])
    }

    @Test("Custom day list resolves correctly")
    func customDays() {
        let days = TaskScheduler.resolveScheduleDays("mon,wed,fri")
        #expect(days == [2, 4, 6])
    }

    @Test("Single day resolves correctly")
    func singleDay() {
        let days = TaskScheduler.resolveScheduleDays("tue")
        #expect(days == [3])
    }

    @Test("Case insensitive resolution")
    func caseInsensitive() {
        let days = TaskScheduler.resolveScheduleDays("DAILY")
        #expect(days == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test("Case insensitive custom days")
    func caseInsensitiveCustom() {
        let days = TaskScheduler.resolveScheduleDays("Mon,FRI")
        #expect(days == [2, 6])
    }

    @Test("Invalid days are filtered out")
    func invalidDays() {
        let days = TaskScheduler.resolveScheduleDays("mon,holiday,fri")
        #expect(days == [2, 6])
    }

    @Test("All invalid days returns empty")
    func allInvalid() {
        let days = TaskScheduler.resolveScheduleDays("holiday,vacation")
        #expect(days.isEmpty)
    }

    @Test("Empty string returns empty")
    func emptyString() {
        let days = TaskScheduler.resolveScheduleDays("")
        #expect(days.isEmpty)
    }

    @Test("Duplicate days are deduplicated")
    func dedup() {
        let days = TaskScheduler.resolveScheduleDays("mon,mon,mon")
        #expect(days == [2])
    }

    @Test("Results are sorted")
    func sorted() {
        let days = TaskScheduler.resolveScheduleDays("sat,mon,thu")
        #expect(days == [2, 5, 7])
    }

    @Test("Whitespace around days is trimmed")
    func whitespace() {
        let days = TaskScheduler.resolveScheduleDays(" mon , fri ")
        #expect(days == [2, 6])
    }
}

// MARK: - shouldFire Tests

@Suite("TaskScheduler.shouldFire")
struct TaskSchedulerShouldFireTests {

    private func makeRecurringTask(days: String, time: String, timezone: String? = nil) -> KBTaskEntry {
        KBTaskEntry(
            instruction: "Test task",
            scheduleDays: days,
            scheduleDate: nil,
            scheduleTime: time,
            timezone: timezone,
            rawLine: "- [Task] Schedule \(days) \(time), Test task"
        )
    }

    private func makeOneOffTask(date: String, time: String, timezone: String? = nil) -> KBTaskEntry {
        KBTaskEntry(
            instruction: "Test one-off",
            scheduleDays: nil,
            scheduleDate: date,
            scheduleTime: time,
            timezone: timezone,
            rawLine: "- [Task] Once \(date) \(time), Test one-off"
        )
    }

    @Test("Disabled task does not fire")
    func disabledTask() {
        let task = makeRecurringTask(days: "daily", time: "09:00")
        let result = TaskScheduler.shouldFire(task: task, taskHash: "t:test", isEnabled: false, executionState: nil)
        #expect(result.shouldFire == false)
        #expect(result.reason == "disabled")
    }

    @Test("Too many consecutive errors blocks firing within grace window")
    func tooManyErrors() {
        let task = makeRecurringTask(days: "daily", time: "09:00")
        let recentTs = Date().timeIntervalSince1970 * 1000 // just now
        let state = TaskScheduler.ExecutionState(lastFiredTs: recentTs, consecutiveErrors: 3)
        let result = TaskScheduler.shouldFire(task: task, taskHash: "t:test", isEnabled: true, executionState: state)
        #expect(result.shouldFire == false)
        #expect(result.reason.contains("consecutive errors"))
    }

    @Test("Stale errors (from past window) allow retry")
    func staleErrorsAllowRetry() {
        let task = makeRecurringTask(days: "daily", time: "09:00")
        // Errors from 2 hours ago (well past grace window)
        let oldTs = (Date().timeIntervalSince1970 - 7200) * 1000
        let state = TaskScheduler.ExecutionState(lastFiredTs: oldTs, consecutiveErrors: 5)
        // This won't necessarily fire (depends on current time matching schedule),
        // but the error check should pass
        let result = TaskScheduler.shouldFire(task: task, taskHash: "t:test", isEnabled: true, executionState: state)
        // The reason should NOT be about consecutive errors
        #expect(!result.reason.contains("consecutive errors"))
    }

    @Test("Invalid schedule time does not fire")
    func invalidScheduleTime() {
        let task = KBTaskEntry(
            instruction: "Bad time", scheduleDays: "daily", scheduleDate: nil,
            scheduleTime: "invalid", timezone: nil, rawLine: ""
        )
        let result = TaskScheduler.shouldFire(task: task, taskHash: "t:test", isEnabled: true, executionState: nil)
        #expect(result.shouldFire == false)
        #expect(result.reason == "invalid schedule_time")
    }

    @Test("Missing scheduleDays on recurring returns not fire")
    func missingScheduleDays() {
        let task = KBTaskEntry(
            instruction: "No days", scheduleDays: nil, scheduleDate: nil,
            scheduleTime: "09:00", timezone: nil, rawLine: ""
        )
        let result = TaskScheduler.shouldFire(task: task, taskHash: "t:test", isEnabled: true, executionState: nil)
        #expect(result.shouldFire == false)
    }

    @Test("Missing scheduleDate on one-off returns not fire")
    func missingScheduleDate() {
        let task = KBTaskEntry(
            instruction: "No date", scheduleDays: nil, scheduleDate: nil,
            scheduleTime: "09:00", timezone: nil, rawLine: ""
        )
        // isOneOff = false (scheduleDate is nil), but scheduleDays is also nil
        let result = TaskScheduler.shouldFire(task: task, taskHash: "t:test", isEnabled: true, executionState: nil)
        #expect(result.shouldFire == false)
    }

    @Test("Recently fired task within grace window does not fire again (dedup)")
    func recentlyFiredDedup() {
        // Build a task that would normally fire right now
        let tz = TimeZone.current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let now = Date()
        let h = cal.component(.hour, from: now)
        let m = cal.component(.minute, from: now)
        let timeStr = String(format: "%02d:%02d", h, m)

        let task = makeRecurringTask(days: "daily", time: timeStr)
        let recentTs = Date().timeIntervalSince1970 * 1000 // just fired
        let state = TaskScheduler.ExecutionState(lastFiredTs: recentTs, consecutiveErrors: 0)
        let result = TaskScheduler.shouldFire(task: task, taskHash: "t:test", isEnabled: true, executionState: state)
        #expect(result.shouldFire == false)
        #expect(result.reason == "fired recently (dedup window)")
    }
}

// MARK: - ExecutionState Tests

@Suite("TaskScheduler.ExecutionState")
struct TaskSchedulerExecutionStateTests {

    @Test("Default ExecutionState has no lastFiredTs or lastMissed")
    func defaultState() {
        let state = TaskScheduler.ExecutionState()
        #expect(state.lastFiredTs == nil)
        #expect(state.lastMissed == nil)
        #expect(state.consecutiveErrors == 0)
    }

    @Test("ExecutionState with all fields")
    func allFields() {
        let state = TaskScheduler.ExecutionState(
            lastFiredTs: 1000000.0,
            lastMissed: "2026-04-05",
            consecutiveErrors: 2
        )
        #expect(state.lastFiredTs == 1000000.0)
        #expect(state.lastMissed == "2026-04-05")
        #expect(state.consecutiveErrors == 2)
    }

    @Test("ExecutionState encodes and decodes round-trip")
    func encodeDecode() throws {
        let original = TaskScheduler.ExecutionState(
            lastFiredTs: 1712345678000,
            lastMissed: "2026-04-06",
            consecutiveErrors: 1
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TaskScheduler.ExecutionState.self, from: data)
        #expect(decoded.lastFiredTs == original.lastFiredTs)
        #expect(decoded.lastMissed == original.lastMissed)
        #expect(decoded.consecutiveErrors == original.consecutiveErrors)
    }

    @Test("ExecutionState round-trip with nil fields")
    func encodeDecodeNils() throws {
        let original = TaskScheduler.ExecutionState(lastFiredTs: nil, lastMissed: nil, consecutiveErrors: 0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TaskScheduler.ExecutionState.self, from: data)
        #expect(decoded.lastFiredTs == nil)
        #expect(decoded.lastMissed == nil)
        #expect(decoded.consecutiveErrors == 0)
    }
}

// MARK: - FireResult and MissResult Tests

@Suite("TaskScheduler Result Types")
struct TaskSchedulerResultTypeTests {

    @Test("FireResult fields are accessible")
    func fireResultFields() {
        let result = TaskScheduler.FireResult(shouldFire: true, isPrefire: true, reason: "within fire window")
        #expect(result.shouldFire == true)
        #expect(result.isPrefire == true)
        #expect(result.reason == "within fire window")
    }

    @Test("MissResult fields are accessible")
    func missResultFields() {
        let result = TaskScheduler.MissResult(missed: true, missedDate: "2026-04-06")
        #expect(result.missed == true)
        #expect(result.missedDate == "2026-04-06")
    }

    @Test("MissResult not missed")
    func missResultNotMissed() {
        let result = TaskScheduler.MissResult(missed: false, missedDate: nil)
        #expect(result.missed == false)
        #expect(result.missedDate == nil)
    }
}

// MARK: - Constants Tests

@Suite("TaskScheduler Constants")
struct TaskSchedulerConstantsTests {

    @Test("Pre-fire offset is 3 minutes (iOS-specific)")
    func prefireOffset() {
        #expect(TaskScheduler.prefireOffsetMinutes == 3)
    }

    @Test("Grace window is 30 minutes")
    func graceWindow() {
        #expect(TaskScheduler.graceWindowMinutes == 30)
    }
}
