/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `task_add` tool matching TB addon's `task_add.js`.
/// Creates a scheduled task in user_kb.md with automatic formatting.
/// Recurring format: `[Task] Schedule <schedule_days> <schedule_time> [<timezone>], <text>`
/// One-off format: `[Task] Once <schedule_date> <schedule_time> [<timezone>], <text>`
/// Registered in `ToolRegistry` at app startup.
struct TaskAddTool: AgentTool, Sendable {
    let name = "task_add"

    private static let validDays: Set<String> = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    private static let validPresets: Set<String> = ["daily", "weekdays", "weekends"]
    private static let maxTasks = 100

    func execute(arguments: [String: JSONValue]) async throws -> String {
        // Extract text (required)
        guard case .string(let rawText) = arguments["text"] else {
            print("[TaskAddTool] Missing or empty 'text'")
            return #"{"error": "missing text"}"#
        }

        let text = AIService.normalizeUnicode(rawText).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            print("[TaskAddTool] Empty text after normalization")
            return #"{"error": "missing text"}"#
        }

        // Reject instructions that reference specific emails, events, or contacts by ID.
        // Scheduled tasks run in the background without access to any specific items —
        // the instruction must be self-contained and describe WHAT to do, not WHICH item.
        if let idError = Self.checkForIdReferences(text) {
            print("[TaskAddTool] Rejected — instruction references specific items")
            return ToolJSON.string(from: ["error": idError])
        }

        // Extract schedule_days and schedule_date (mutually exclusive)
        let hasScheduleDays = {
            if case .string(let s) = arguments["schedule_days"], !s.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            return false
        }()
        let hasScheduleDate = {
            if case .string(let s) = arguments["schedule_date"], !s.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            return false
        }()

        guard hasScheduleDays || hasScheduleDate else {
            print("[TaskAddTool] Missing both 'schedule_days' and 'schedule_date'")
            return #"{"error": "Either schedule_days (for recurring) or schedule_date (for one-off) is required."}"#
        }

        guard !(hasScheduleDays && hasScheduleDate) else {
            print("[TaskAddTool] Both 'schedule_days' and 'schedule_date' provided")
            return #"{"error": "schedule_days and schedule_date are mutually exclusive. Use schedule_days for recurring tasks, schedule_date for one-off tasks."}"#
        }

        // Validate schedule_time (HH:MM, required)
        guard case .string(let rawTime) = arguments["schedule_time"],
              !rawTime.trimmingCharacters(in: .whitespaces).isEmpty else {
            print("[TaskAddTool] Missing 'schedule_time'")
            return #"{"error": "missing schedule_time"}"#
        }

        let scheduleTime = rawTime.trimmingCharacters(in: .whitespaces)
        let timePattern = /^\d{2}:\d{2}$/
        guard scheduleTime.wholeMatch(of: timePattern) != nil else {
            print("[TaskAddTool] Invalid schedule_time format '\(scheduleTime)'")
            return #"{"error": "invalid schedule_time format, expected HH:MM"}"#
        }

        // Build formatted KB entry
        let entry: String

        if hasScheduleDays {
            guard case .string(let rawDays) = arguments["schedule_days"],
                  let scheduleDays = Self.validateScheduleDays(rawDays) else {
                print("[TaskAddTool] Invalid schedule_days")
                return #"{"error": "invalid schedule_days, expected daily, weekdays, weekends, or comma-separated mon/tue/wed/thu/fri/sat/sun"}"#
            }
            entry = formatTaskEntry(text: text, scheduleDays: scheduleDays, scheduleTime: scheduleTime)
        } else {
            guard case .string(let rawDate) = arguments["schedule_date"] else {
                return #"{"error": "missing schedule_date"}"#
            }
            let scheduleDate = rawDate.trimmingCharacters(in: .whitespaces)
            let datePattern = /^\d{4}\/\d{2}\/\d{2}$/
            guard scheduleDate.wholeMatch(of: datePattern) != nil else {
                print("[TaskAddTool] Invalid schedule_date format '\(scheduleDate)'")
                return #"{"error": "invalid schedule_date format, expected YYYY/MM/DD"}"#
            }
            entry = formatTaskEntry(text: text, scheduleDate: scheduleDate, scheduleTime: scheduleTime)
        }

        print("[TaskAddTool] Formatted entry='\(entry.prefix(140))' len=\(entry.count)")

        // Load current KB and check max tasks
        let current = PromptStore.kbTextSnapshot()

        let taskCount = current.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression)
            return trimmed.range(of: "^\\[Task\\]", options: [.regularExpression, .caseInsensitive]) != nil
        }.count

        if taskCount >= Self.maxTasks {
            print("[TaskAddTool] Max tasks reached (\(taskCount)/\(Self.maxTasks))")
            return ToolJSON.string(from: ["error": "Maximum number of scheduled tasks reached (\(Self.maxTasks)). Please delete some before adding new ones."])
        }

        let patchText = "ADD\n\(entry)"
        guard let updated = KBPatchApplier.applyKBPatch(content: current, patchText: patchText) else {
            print("[TaskAddTool] applyKBPatch returned nil")
            return #"{"error": "failed to update knowledge base"}"#
        }

        if updated == current {
            print("[TaskAddTool] No-op (duplicate)")
            return "No change (duplicate task entry)."
        }

        // Persist — Device Sync triggers automatically
        await MainActor.run { PromptStore.shared.rawKB = updated }
        print("[TaskAddTool] Persisted user_kb.md (\(updated.count) chars)")

        // Clear stale execution state — a recreated task with the same instruction
        // should fire fresh, not be blocked by stale dedup timestamp.
        // taskHash only uses instruction text, so a minimal entry suffices.
        let hash = KBTaskParser.taskHash(KBTaskEntry(
            instruction: text, scheduleDays: nil, scheduleDate: nil,
            scheduleTime: "", timezone: nil, rawLine: entry
        ))
        await MainActor.run { TaskScheduler.clearExecutionState(for: hash) }

        print("[TaskAddTool] Success")
        let resultDict: [String: Any] = ["ok": true, "task": entry]
        return ToolJSON.string(from: resultDict)
    }

    // MARK: - ID Reference Check

    /// Reject instructions that reference specific items by ID.
    /// Scheduled tasks run without access to specific emails/events/contacts,
    /// so the instruction must describe a general task.
    /// Returns error message if rejected, nil if OK.
    private static func checkForIdReferences(_ text: String) -> String? {
        // [Email](N) references (case-insensitive to match TB)
        if text.range(of: #"(?i)\[Email\]\(\d+\)"#, options: .regularExpression) != nil {
            return "Scheduled task instructions must not reference specific emails. Describe what to look for instead (e.g., 'check for unread emails from Alice' rather than referencing a specific email)."
        }
        // [Event](N) or [Contact](N) references (case-insensitive)
        if text.range(of: #"(?i)\[(Event|Contact)\]\(\d+\)"#, options: .regularExpression) != nil {
            return "Scheduled task instructions must not reference specific events or contacts by ID. Describe what to look for instead (e.g., 'check my calendar for meetings' rather than referencing a specific event)."
        }
        // Raw ID patterns
        if text.range(of: #"(?i)\b(?:unique_id|message_id|event_id|contact_id)\s*[:=]\s*\S+"#, options: .regularExpression) != nil {
            return "Scheduled task instructions must not include item IDs. Describe the task in general terms so it works every time it runs."
        }
        return nil
    }

    // MARK: - Validation

    /// Validate schedule_days: must be "daily", "weekdays", "weekends",
    /// or a comma-separated list of mon/tue/wed/thu/fri/sat/sun.
    /// Matches TB's `validateScheduleDays()` in `task_add.js`.
    private static func validateScheduleDays(_ raw: String) -> String? {
        let val = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if validPresets.contains(val) { return val }

        let parts = val.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        for part in parts {
            guard validDays.contains(part) else { return nil }
        }
        return parts.joined(separator: ",")
    }

    // MARK: - Formatting

    /// Build a formatted KB task entry for a recurring task.
    /// Includes the user's IANA timezone so the task remains correct across timezones.
    private func formatTaskEntry(text: String, scheduleDays: String, scheduleTime: String) -> String {
        let tz = TimeZone.current.identifier
        return "[Task] Schedule \(scheduleDays) \(scheduleTime) [\(tz)], \(text)"
    }

    /// Build a formatted KB task entry for a one-off task.
    /// Includes the user's IANA timezone so the task remains correct across timezones.
    private func formatTaskEntry(text: String, scheduleDate: String, scheduleTime: String) -> String {
        let tz = TimeZone.current.identifier
        return "[Task] Once \(scheduleDate) \(scheduleTime) [\(tz)], \(text)"
    }
}
