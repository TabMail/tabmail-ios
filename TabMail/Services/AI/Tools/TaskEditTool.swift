/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `task_edit` tool matching TB addon's `task_edit.js`.
/// Finds an existing [Task] entry by substring and updates it in place.
/// Only provided fields are changed; omitted fields keep their current values.
struct TaskEditTool: AgentTool, Sendable {
    let name = "task_edit"

    // Regex patterns matching kbTaskParser
    nonisolated(unsafe) private static let schedPattern = /^\[Task\]\s*Schedule\s+([\w,]+)\s+(\d{2}:\d{2})(?:\s+\[([^\]]+)\])?,\s*(.+)$/
        .ignoresCase()
    nonisolated(unsafe) private static let oncePattern = /^\[Task\]\s*Once\s+(\d{4}\/\d{2}\/\d{2})\s+(\d{2}:\d{2})(?:\s+\[([^\]]+)\])?,\s*(.+)$/
        .ignoresCase()

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard case .string(let findText) = arguments["find_text"],
              !findText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"{"error": "missing find_text"}"#
        }

        let find = findText.trimmingCharacters(in: .whitespaces).lowercased()

        // Load KB and find matching task
        let current = PromptStore.kbTextSnapshot()
        let lines = current.components(separatedBy: "\n")
        var matches: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.localizedCaseInsensitiveContains("[Task]"),
                  trimmed.lowercased().contains(find) else { continue }
            matches.append(trimmed)
        }

        if matches.isEmpty {
            return ToolJSON.string(from: ["error": "No scheduled task found matching '\(findText)'."])
        }
        if matches.count > 1 {
            return ToolJSON.string(from: [
                "error": "Multiple tasks match '\(findText)'. Please be more specific.",
                "matches": matches.map { $0.replacingOccurrences(of: "^-\\s*\\[Task\\]\\s*", with: "", options: .regularExpression) }
            ])
        }

        let oldLine = matches[0]
        let oldStatement = oldLine.replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression)

        // Parse existing task
        var currentDays: String?
        var currentDate: String?
        var currentTime: String = ""
        var currentTz: String?
        var currentInstruction: String = ""
        var isOneOff = false

        if let m = oldStatement.wholeMatch(of: Self.schedPattern) {
            currentDays = String(m.1)
            currentTime = String(m.2)
            currentTz = m.3.map(String.init)
            currentInstruction = String(m.4).trimmingCharacters(in: .whitespaces)
        } else if let m = oldStatement.wholeMatch(of: Self.oncePattern) {
            isOneOff = true
            currentDate = String(m.1)
            currentTime = String(m.2)
            currentTz = m.3.map(String.init)
            currentInstruction = String(m.4).trimmingCharacters(in: .whitespaces)
        } else {
            return ToolJSON.string(from: ["error": "Could not parse the existing task format."])
        }

        // Apply updates
        let newInstruction: String
        if case .string(let t) = arguments["text"], !t.trimmingCharacters(in: .whitespaces).isEmpty {
            newInstruction = AIService.normalizeUnicode(t).trimmingCharacters(in: .whitespaces)
        } else {
            newInstruction = currentInstruction
        }

        let newTime: String
        if case .string(let t) = arguments["schedule_time"], !t.isEmpty {
            newTime = t.trimmingCharacters(in: .whitespaces)
        } else {
            newTime = currentTime
        }

        let tz = currentTz ?? TimeZone.current.identifier

        let newEntry: String
        if case .string(let d) = arguments["schedule_date"], !d.isEmpty {
            newEntry = "[Task] Once \(d) \(newTime) [\(tz)], \(newInstruction)"
        } else if case .string(let d) = arguments["schedule_days"], !d.isEmpty {
            newEntry = "[Task] Schedule \(d) \(newTime) [\(tz)], \(newInstruction)"
        } else if isOneOff, let date = currentDate {
            newEntry = "[Task] Once \(date) \(newTime) [\(tz)], \(newInstruction)"
        } else if let days = currentDays {
            newEntry = "[Task] Schedule \(days) \(newTime) [\(tz)], \(newInstruction)"
        } else {
            return ToolJSON.string(from: ["error": "Could not determine task schedule type."])
        }

        // Apply DEL + ADD
        guard let afterDel = KBPatchApplier.applyKBPatch(content: current, patchText: "DEL\n\(oldStatement)"),
              afterDel != current else {
            return ToolJSON.string(from: ["error": "Failed to remove old task entry."])
        }
        guard let updated = KBPatchApplier.applyKBPatch(content: afterDel, patchText: "ADD\n\(newEntry)") else {
            return ToolJSON.string(from: ["error": "Failed to add updated task entry."])
        }

        await MainActor.run { PromptStore.shared.rawKB = updated }
        print("[TaskEditTool] Updated: '\(oldStatement.prefix(60))' → '\(newEntry.prefix(60))'")

        // Clear execution state for both old and new hash
        let oldHash = KBTaskParser.taskHash(KBTaskEntry(
            instruction: currentInstruction, scheduleDays: nil, scheduleDate: nil,
            scheduleTime: "", timezone: nil, rawLine: oldStatement
        ))
        let newHash = KBTaskParser.taskHash(KBTaskEntry(
            instruction: newInstruction, scheduleDays: nil, scheduleDate: nil,
            scheduleTime: "", timezone: nil, rawLine: newEntry
        ))
        await MainActor.run {
            TaskScheduler.clearExecutionState(for: oldHash)
            if newHash != oldHash { TaskScheduler.clearExecutionState(for: newHash) }
        }

        return ToolJSON.string(from: ["ok": true, "previous": oldStatement, "updated": newEntry])
    }
}
