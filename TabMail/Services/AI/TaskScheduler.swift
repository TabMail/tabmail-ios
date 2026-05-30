/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Schedule evaluation for [Task] entries (both recurring and one-off).
/// Determines when tasks should fire, detects missed fires,
/// and manages per-task execution state (device-local, not synced).
///
/// Port of TB's `taskScheduler.js`. iOS uses T-3min pre-fire offset
/// (TB uses T-5min) for staggered execution.
struct TaskScheduler: Sendable {

    // MARK: - Constants

    /// iOS pre-fire offset: 3 minutes before scheduled time
    static let prefireOffsetMinutes = 3

    /// Grace window: 30 minutes after scheduled time
    static let graceWindowMinutes = 30

    /// UserDefaults key for per-task execution state
    private static let executionStateKey = "task_execution_state"

    // MARK: - Day Resolution

    private static let dayMap: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
    ]

    /// Resolve schedule_days string to Calendar weekday numbers (1=Sun, 7=Sat).
    static func resolveScheduleDays(_ scheduleDays: String) -> [Int] {
        let lower = scheduleDays.lowercased().trimmingCharacters(in: .whitespaces)
        switch lower {
        case "daily": return [1, 2, 3, 4, 5, 6, 7]
        case "weekdays": return [2, 3, 4, 5, 6]
        case "weekends": return [1, 7]
        default:
            let parts = lower.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var days: [Int] = []
            for part in parts {
                if let d = dayMap[part], !days.contains(d) { days.append(d) }
            }
            return days.sorted()
        }
    }

    // MARK: - Schedule Time Parsing

    /// Parse "HH:MM" to (hour, minute) tuple.
    static func parseScheduleTime(_ time: String) -> (hour: Int, minute: Int)? {
        let parts = time.split(separator: ":").map(String.init)
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              h >= 0, h <= 23, m >= 0, m <= 59 else { return nil }
        return (h, m)
    }

    // MARK: - Fire Evaluation

    struct FireResult: Sendable {
        let shouldFire: Bool
        let isPrefire: Bool
        let reason: String
    }

    /// Determine if a task should fire now.
    static func shouldFire(
        task: KBTaskEntry,
        taskHash: String,
        isEnabled: Bool,
        executionState: ExecutionState?
    ) -> FireResult {
        guard isEnabled else {
            return FireResult(shouldFire: false, isPrefire: false, reason: "disabled")
        }

        // Stop retrying after 3 consecutive errors within the CURRENT fire window.
        // If the errors are from a past window (lastFiredTs beyond grace), they're stale — ignore.
        if let state = executionState, state.consecutiveErrors >= 3 {
            if let lastTs = state.lastFiredTs {
                let errorAge = Date().timeIntervalSince1970 * 1000 - lastTs
                if errorAge < Double(graceWindowMinutes * 60 * 1000) {
                    return FireResult(shouldFire: false, isPrefire: false, reason: "too many consecutive errors (\(state.consecutiveErrors))")
                }
            }
            // Errors are stale (from a past window) — allow retry
        }

        let tz = task.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let now = Date()

        guard let parsed = parseScheduleTime(task.scheduleTime) else {
            return FireResult(shouldFire: false, isPrefire: false, reason: "invalid schedule_time")
        }

        // Use timezone-aware calendar
        var tzCalendar = Calendar(identifier: .gregorian)
        tzCalendar.timeZone = tz

        if task.isOneOff {
            // One-off task: check date match
            guard let scheduleDate = task.scheduleDate else {
                return FireResult(shouldFire: false, isPrefire: false, reason: "missing schedule_date")
            }

            let todayComponents = tzCalendar.dateComponents([.year, .month, .day], from: now)
            let todayStr = String(format: "%04d/%02d/%02d", todayComponents.year!, todayComponents.month!, todayComponents.day!)

            guard scheduleDate == todayStr else {
                return FireResult(shouldFire: false, isPrefire: false, reason: "not the scheduled date")
            }
        } else {
            // Recurring task: check day of week
            guard let scheduleDays = task.scheduleDays else {
                return FireResult(shouldFire: false, isPrefire: false, reason: "missing schedule_days")
            }
            let tzWeekday = tzCalendar.component(.weekday, from: now)
            let scheduledDays = resolveScheduleDays(scheduleDays)
            guard scheduledDays.contains(tzWeekday) else {
                return FireResult(shouldFire: false, isPrefire: false, reason: "not a scheduled day")
            }
        }

        // Current time in task's timezone
        let tzHour = tzCalendar.component(.hour, from: now)
        let tzMinute = tzCalendar.component(.minute, from: now)
        let nowMinutes = tzHour * 60 + tzMinute
        let schedMinutes = parsed.hour * 60 + parsed.minute

        // Fire window: (schedMinutes - prefireOffset) to (schedMinutes + graceWindow)
        let windowStart = schedMinutes - prefireOffsetMinutes
        let windowEnd = schedMinutes + graceWindowMinutes

        guard nowMinutes >= windowStart, nowMinutes <= windowEnd else {
            return FireResult(shouldFire: false, isPrefire: false, reason: "outside fire window")
        }

        // Already fired today?
        // Dedup: skip if fired within the grace window (not date-based — allows rescheduled tasks to fire same day)
        if let state = executionState, let lastTs = state.lastFiredTs {
            let elapsed = Date().timeIntervalSince1970 * 1000 - lastTs
            if elapsed < Double(graceWindowMinutes * 60 * 1000) {
                return FireResult(shouldFire: false, isPrefire: false, reason: "fired recently (dedup window)")
            }
        }

        let isPrefire = nowMinutes < schedMinutes
        return FireResult(shouldFire: true, isPrefire: isPrefire, reason: "within fire window")
    }

    // MARK: - Missed Fire Detection

    struct MissResult: Sendable {
        let missed: Bool
        let missedDate: String?
    }

    /// Detect if a task was missed today.
    static func detectMiss(
        task: KBTaskEntry,
        taskHash: String,
        executionState: ExecutionState?
    ) -> MissResult {
        let tz = task.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let now = Date()
        var tzCalendar = Calendar(identifier: .gregorian)
        tzCalendar.timeZone = tz

        guard let parsed = parseScheduleTime(task.scheduleTime) else {
            return MissResult(missed: false, missedDate: nil)
        }

        if task.isOneOff {
            // One-off: check if the scheduled date has passed
            guard let scheduleDate = task.scheduleDate else {
                return MissResult(missed: false, missedDate: nil)
            }
            let todayComponents = tzCalendar.dateComponents([.year, .month, .day], from: now)
            let todayStr = String(format: "%04d/%02d/%02d", todayComponents.year!, todayComponents.month!, todayComponents.day!)

            // If today is past the scheduled date, it was missed
            // If today is the scheduled date, check if past the grace window
            if todayStr > scheduleDate {
                // Past the date entirely
                let todayDash = String(format: "%04d-%02d-%02d", todayComponents.year!, todayComponents.month!, todayComponents.day!)
                if let state = executionState, let lastTs = state.lastFiredTs {
                    let elapsed = Date().timeIntervalSince1970 * 1000 - lastTs
                    if elapsed < Double(graceWindowMinutes * 60 * 1000) {
                        return MissResult(missed: false, missedDate: nil)
                    }
                }
                return MissResult(missed: true, missedDate: todayDash)
            } else if todayStr < scheduleDate {
                return MissResult(missed: false, missedDate: nil)
            }
            // todayStr == scheduleDate — fall through to time check below
        } else {
            // Recurring: check day of week
            guard let scheduleDays = task.scheduleDays else {
                return MissResult(missed: false, missedDate: nil)
            }
            let tzWeekday = tzCalendar.component(.weekday, from: now)
            let scheduledDays = resolveScheduleDays(scheduleDays)
            guard scheduledDays.contains(tzWeekday) else {
                return MissResult(missed: false, missedDate: nil)
            }
        }

        let tzHour = tzCalendar.component(.hour, from: now)
        let tzMinute = tzCalendar.component(.minute, from: now)
        let nowMinutes = tzHour * 60 + tzMinute
        let schedMinutes = parsed.hour * 60 + parsed.minute

        // Window not yet passed?
        if nowMinutes <= schedMinutes + graceWindowMinutes {
            return MissResult(missed: false, missedDate: nil)
        }

        // Check if fired today
        let todayComponents = tzCalendar.dateComponents([.year, .month, .day], from: now)
        let todayStr = String(format: "%04d-%02d-%02d", todayComponents.year!, todayComponents.month!, todayComponents.day!)

        if let state = executionState, let lastTs = state.lastFiredTs {
            let elapsed = Date().timeIntervalSince1970 * 1000 - lastTs
            if elapsed < Double(graceWindowMinutes * 60 * 1000) {
                return MissResult(missed: false, missedDate: nil)
            }
        }

        return MissResult(missed: true, missedDate: todayStr)
    }

    // MARK: - Execution State (device-local, NOT synced)

    struct ExecutionState: Codable, Sendable {
        var lastFiredTs: Double?  // epoch ms — timestamp-based dedup (not date-based)
        var lastMissed: String?
        var consecutiveErrors: Int

        init(lastFiredTs: Double? = nil, lastMissed: String? = nil, consecutiveErrors: Int = 0) {
            self.lastFiredTs = lastFiredTs
            self.lastMissed = lastMissed
            self.consecutiveErrors = consecutiveErrors
        }
    }

    @MainActor
    static func getExecutionStates() -> [String: ExecutionState] {
        guard let data = UserDefaults.standard.data(forKey: executionStateKey),
              let states = try? JSONDecoder().decode([String: ExecutionState].self, from: data) else {
            return [:]
        }
        return states
    }

    @MainActor
    static func getExecutionState(for taskHash: String) -> ExecutionState? {
        getExecutionStates()[taskHash]
    }

    /// Clear execution state for a task hash. Called when a task is created or deleted
    /// so that a recreated task with the same instruction fires fresh.
    @MainActor
    static func clearExecutionState(for taskHash: String) {
        var states = getExecutionStates()
        guard states.removeValue(forKey: taskHash) != nil else { return }
        saveStates(states)
        print("[TaskScheduler] Cleared execution state for \(taskHash)")
    }

    /// Mark a task as fired. Stores timezone-aware date string (YYYY-MM-DD)
    /// so "already fired today" comparisons work correctly across timezones.
    /// Matches TB's `markFired(taskHash, success, timezone)`.
    @MainActor
    static func markFired(_ taskHash: String, success: Bool) {
        var states = getExecutionStates()
        let existing = states[taskHash] ?? ExecutionState()
        states[taskHash] = ExecutionState(
            // Only set lastFiredTs on SUCCESS — failed fires should be retryable
            lastFiredTs: success ? Date().timeIntervalSince1970 * 1000 : existing.lastFiredTs,
            lastMissed: nil,
            consecutiveErrors: success ? 0 : existing.consecutiveErrors + 1
        )
        saveStates(states)
        print("[TaskScheduler] Marked \(taskHash) as fired (success=\(success))")
    }

    @MainActor
    static func markMissed(_ taskHash: String, date: String) {
        var states = getExecutionStates()
        let existing = states[taskHash] ?? ExecutionState()
        guard existing.lastMissed != date else { return }
        states[taskHash] = ExecutionState(
            lastFiredTs: existing.lastFiredTs,
            lastMissed: date,
            consecutiveErrors: existing.consecutiveErrors
        )
        saveStates(states)
        print("[TaskScheduler] Marked \(taskHash) as missed on \(date)")
    }

    @MainActor
    static func consumeMissed(_ taskHash: String) {
        var states = getExecutionStates()
        guard states[taskHash]?.lastMissed != nil else { return }
        states[taskHash]?.lastMissed = nil
        saveStates(states)
        print("[TaskScheduler] Consumed missed marker for \(taskHash)")
    }

    @MainActor
    static func gcOrphanedStates(activeTaskHashes: Set<String>) {
        var states = getExecutionStates()
        let gcThreshold: TimeInterval = 90 * 24 * 3600
        let now = Date()
        var removed = 0

        for (hash, state) in states {
            if activeTaskHashes.contains(hash) { continue }
            let lastFiredDate = state.lastFiredTs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date.distantPast
            if now.timeIntervalSince(lastFiredDate) > gcThreshold {
                states.removeValue(forKey: hash)
                removed += 1
            }
        }

        if removed > 0 {
            saveStates(states)
            print("[TaskScheduler] GC: removed \(removed) orphaned execution states")
        }
    }

    @MainActor
    private static func saveStates(_ states: [String: ExecutionState]) {
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: executionStateKey)
        }
    }
}
