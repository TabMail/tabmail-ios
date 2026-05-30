/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("KBTaskParser")
struct KBTaskParserTests {

    // MARK: - Recurring Tasks

    @Test("Parse recurring task with days and time")
    func parseRecurringBasic() {
        KBTaskParser.invalidateCache()
        let kb = "- [Task] Schedule weekdays 09:00 [America/Vancouver], Summarize overnight emails"
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.count == 1)
        guard tasks.count == 1 else { return }
        #expect(tasks[0].instruction == "Summarize overnight emails")
        #expect(tasks[0].scheduleDays == "weekdays")
        #expect(tasks[0].scheduleTime == "09:00")
        #expect(tasks[0].timezone == "America/Vancouver")
        #expect(tasks[0].scheduleDate == nil)
        #expect(tasks[0].isOneOff == false)
    }

    @Test("Parse recurring task with daily schedule")
    func parseRecurringDaily() {
        KBTaskParser.invalidateCache()
        let kb = "- [Task] Schedule daily 08:00, Check inbox"
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.count == 1)
        guard tasks.count == 1 else { return }
        #expect(tasks[0].scheduleDays == "daily")
        #expect(tasks[0].scheduleTime == "08:00")
        #expect(tasks[0].timezone == nil)
    }

    @Test("Parse recurring task with weekends")
    func parseRecurringWeekends() {
        KBTaskParser.invalidateCache()
        let kb = "[Task] Schedule weekends 10:30 [Europe/London], Weekend summary"
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.count == 1)
        guard tasks.count == 1 else { return }
        #expect(tasks[0].scheduleDays == "weekends")
        #expect(tasks[0].scheduleTime == "10:30")
        #expect(tasks[0].timezone == "Europe/London")
    }

    @Test("Parse recurring task with custom day list")
    func parseRecurringCustomDays() {
        KBTaskParser.invalidateCache()
        let kb = "- [Task] Schedule mon,wed,fri 14:00, Review PR queue"
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.count == 1)
        guard tasks.count == 1 else { return }
        #expect(tasks[0].scheduleDays == "mon,wed,fri")
        #expect(tasks[0].instruction == "Review PR queue")
    }

    // MARK: - One-Off Tasks

    @Test("Parse one-off task with date and time")
    func parseOneOffBasic() {
        KBTaskParser.invalidateCache()
        let kb = "- [Task] Once 2026/04/15 15:00 [America/Vancouver], Check if Bob replied"
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.count == 1)
        guard tasks.count == 1 else { return }
        #expect(tasks[0].instruction == "Check if Bob replied")
        #expect(tasks[0].scheduleDate == "2026/04/15")
        #expect(tasks[0].scheduleTime == "15:00")
        #expect(tasks[0].timezone == "America/Vancouver")
        #expect(tasks[0].scheduleDays == nil)
        #expect(tasks[0].isOneOff == true)
    }

    @Test("Parse one-off task without timezone")
    func parseOneOffNoTimezone() {
        KBTaskParser.invalidateCache()
        let kb = "[Task] Once 2026/12/25 09:00, Send holiday greetings"
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.count == 1)
        guard tasks.count == 1 else { return }
        #expect(tasks[0].scheduleDate == "2026/12/25")
        #expect(tasks[0].timezone == nil)
        #expect(tasks[0].isOneOff == true)
    }

    // MARK: - Multiple Tasks

    @Test("Parse multiple mixed tasks from KB")
    func parseMultipleMixed() {
        KBTaskParser.invalidateCache()
        let kb = """
        Some KB text here about preferences
        - [Task] Schedule weekdays 09:00 [America/Vancouver], Morning summary
        - [Reminder] Due 2026/05/01, Some reminder
        - [Task] Once 2026/04/20 14:00, Follow up with client
        - [Task] Schedule daily 18:00, EOD report
        Other KB text
        """
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.count == 3)
        guard tasks.count == 3 else { return }
        #expect(tasks[0].instruction == "Morning summary")
        #expect(tasks[0].isOneOff == false)
        #expect(tasks[1].instruction == "Follow up with client")
        #expect(tasks[1].isOneOff == true)
        #expect(tasks[2].instruction == "EOD report")
        #expect(tasks[2].isOneOff == false)
    }

    // MARK: - Edge Cases

    @Test("Empty KB text returns empty")
    func emptyKB() {
        KBTaskParser.invalidateCache()
        let tasks = KBTaskParser.parse("")
        #expect(tasks.isEmpty)
    }

    @Test("Whitespace-only KB text returns empty")
    func whitespaceOnlyKB() {
        KBTaskParser.invalidateCache()
        let tasks = KBTaskParser.parse("   \n  \n  ")
        #expect(tasks.isEmpty)
    }

    @Test("KB with no [Task] lines returns empty")
    func noTaskLines() {
        KBTaskParser.invalidateCache()
        let kb = """
        Some KB text
        - [Reminder] Due 2026/05/01, Check something
        More text here
        """
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.isEmpty)
    }

    @Test("Malformed task line is skipped")
    func malformedLineSkipped() {
        KBTaskParser.invalidateCache()
        let kb = """
        - [Task] This is not a valid format
        - [Task] Schedule weekdays 09:00, Valid task here
        """
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.count == 1)
        guard tasks.count == 1 else { return }
        #expect(tasks[0].instruction == "Valid task here")
    }

    @Test("Case insensitive [Task] matching")
    func caseInsensitive() {
        KBTaskParser.invalidateCache()
        let kb = "- [task] Schedule daily 09:00, Case test"
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.count == 1)
        guard tasks.count == 1 else { return }
        #expect(tasks[0].instruction == "Case test")
    }

    @Test("Task without leading dash is parsed")
    func noDash() {
        KBTaskParser.invalidateCache()
        let kb = "[Task] Schedule daily 12:00, Noon check"
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.count == 1)
        guard tasks.count == 1 else { return }
        #expect(tasks[0].instruction == "Noon check")
    }

    @Test("Unrecognized day specifier is skipped")
    func unrecognizedDays() {
        KBTaskParser.invalidateCache()
        let kb = "- [Task] Schedule holidays 09:00, Bad days"
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.isEmpty)
    }

    @Test("Partial valid day list filters to valid days only")
    func partialValidDays() {
        KBTaskParser.invalidateCache()
        // "mon,badday,fri" — expandDays filters to ["mon", "fri"]
        let kb = "- [Task] Schedule mon,badday,fri 09:00, Partial days"
        let tasks = KBTaskParser.parse(kb)
        // The regex captures the entire day string, expandDays filters invalid parts
        // But the entry is still created (expandDays returns non-empty since mon,fri are valid)
        #expect(tasks.count == 1)
        guard tasks.count == 1 else { return }
        #expect(tasks[0].scheduleDays == "mon,badday,fri")
    }

    // MARK: - Cache Behavior

    @Test("Cache hit: same KB text returns same results without re-parsing")
    func cacheHit() {
        KBTaskParser.invalidateCache()
        let kb = "- [Task] Schedule daily 09:00, Cache test task"
        let result1 = KBTaskParser.parse(kb)
        let result2 = KBTaskParser.parse(kb)
        #expect(result1.count == result2.count)
        guard result1.count == 1, result2.count == 1 else { return }
        #expect(result1[0].instruction == result2[0].instruction)
    }

    @Test("Cache miss: different KB text re-parses")
    func cacheMiss() {
        KBTaskParser.invalidateCache()
        let kb1 = "- [Task] Schedule daily 09:00, First task"
        let kb2 = "- [Task] Schedule weekdays 10:00, Second task"
        let result1 = KBTaskParser.parse(kb1)
        let result2 = KBTaskParser.parse(kb2)
        #expect(result1.count == 1)
        #expect(result2.count == 1)
        guard result1.count == 1, result2.count == 1 else { return }
        #expect(result1[0].instruction == "First task")
        #expect(result2[0].instruction == "Second task")
    }

    @Test("invalidateCache clears cached results")
    func invalidateCacheWorks() {
        let kb = "- [Task] Schedule daily 09:00, Invalidate test"
        _ = KBTaskParser.parse(kb)
        KBTaskParser.invalidateCache()
        // After invalidation, parsing same text should work (re-parse)
        let result = KBTaskParser.parse(kb)
        #expect(result.count == 1)
    }

    // MARK: - Task Hash

    @Test("taskHash uses t: prefix")
    func taskHashPrefix() {
        let entry = KBTaskEntry(
            instruction: "Test instruction",
            scheduleDays: "daily",
            scheduleDate: nil,
            scheduleTime: "09:00",
            timezone: nil,
            rawLine: "- [Task] Schedule daily 09:00, Test instruction"
        )
        let hash = KBTaskParser.taskHash(entry)
        #expect(hash.hasPrefix("t:"))
    }

    @Test("taskHash is deterministic for same input")
    func taskHashDeterministic() {
        let entry = KBTaskEntry(
            instruction: "Deterministic test",
            scheduleDays: "weekdays",
            scheduleDate: nil,
            scheduleTime: "10:00",
            timezone: "America/Vancouver",
            rawLine: "- [Task] Schedule weekdays 10:00 [America/Vancouver], Deterministic test"
        )
        let hash1 = KBTaskParser.taskHash(entry)
        let hash2 = KBTaskParser.taskHash(entry)
        #expect(hash1 == hash2)
    }

    @Test("taskHash differs for different instructions")
    func taskHashDiffers() {
        let entry1 = KBTaskEntry(
            instruction: "Task A",
            scheduleDays: "daily",
            scheduleDate: nil,
            scheduleTime: "09:00",
            timezone: nil,
            rawLine: "- [Task] Schedule daily 09:00, Task A"
        )
        let entry2 = KBTaskEntry(
            instruction: "Task B",
            scheduleDays: "daily",
            scheduleDate: nil,
            scheduleTime: "09:00",
            timezone: nil,
            rawLine: "- [Task] Schedule daily 09:00, Task B"
        )
        let hash1 = KBTaskParser.taskHash(entry1)
        let hash2 = KBTaskParser.taskHash(entry2)
        #expect(hash1 != hash2)
    }

    @Test("taskHash uses rawLine when available")
    func taskHashUsesRawLine() {
        let entry1 = KBTaskEntry(
            instruction: "Same instruction",
            scheduleDays: "daily",
            scheduleDate: nil,
            scheduleTime: "09:00",
            timezone: nil,
            rawLine: "- [Task] Schedule daily 09:00, Same instruction"
        )
        let entry2 = KBTaskEntry(
            instruction: "Same instruction",
            scheduleDays: "weekdays",
            scheduleDate: nil,
            scheduleTime: "10:00",
            timezone: nil,
            rawLine: "- [Task] Schedule weekdays 10:00, Same instruction"
        )
        // Different rawLine → different hash, even if instruction is the same
        let hash1 = KBTaskParser.taskHash(entry1)
        let hash2 = KBTaskParser.taskHash(entry2)
        #expect(hash1 != hash2)
    }

    @Test("taskHash falls back to instruction when rawLine is empty")
    func taskHashFallbackToInstruction() {
        let entry = KBTaskEntry(
            instruction: "Fallback instruction",
            scheduleDays: nil,
            scheduleDate: nil,
            scheduleTime: "09:00",
            timezone: nil,
            rawLine: ""
        )
        let hash = KBTaskParser.taskHash(entry)
        #expect(hash.hasPrefix("t:"))
        #expect(!hash.isEmpty)
    }

    // MARK: - KBTaskEntry Properties

    @Test("isOneOff true when scheduleDate is set")
    func isOneOffTrue() {
        let entry = KBTaskEntry(
            instruction: "One-off",
            scheduleDays: nil,
            scheduleDate: "2026/04/15",
            scheduleTime: "15:00",
            timezone: nil,
            rawLine: ""
        )
        #expect(entry.isOneOff == true)
    }

    @Test("isOneOff false when scheduleDays is set")
    func isOneOffFalse() {
        let entry = KBTaskEntry(
            instruction: "Recurring",
            scheduleDays: "daily",
            scheduleDate: nil,
            scheduleTime: "09:00",
            timezone: nil,
            rawLine: ""
        )
        #expect(entry.isOneOff == false)
    }

    // MARK: - rawLine Preservation

    @Test("rawLine preserves the original trimmed line")
    func rawLinePreserved() {
        KBTaskParser.invalidateCache()
        let kb = "  - [Task] Schedule daily 09:00, My task  "
        let tasks = KBTaskParser.parse(kb)
        #expect(tasks.count == 1)
        guard tasks.count == 1 else { return }
        #expect(tasks[0].rawLine == "- [Task] Schedule daily 09:00, My task")
    }
}
