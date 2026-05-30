/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `task_del` tool matching TB addon's `task_del.js`.
/// Deletes a [Task] entry from user_kb.md by text match.
/// Registered in `ToolRegistry` at app startup.
struct TaskDelTool: AgentTool, Sendable {
    let name = "task_del"

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard case .string(let rawText) = arguments["text"] else {
            print("[TaskDelTool] Missing or empty 'text'")
            return #"{"error": "missing text"}"#
        }

        let text = AIService.normalizeUnicode(rawText).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            print("[TaskDelTool] Empty text after normalization")
            return #"{"error": "missing text"}"#
        }

        print("[TaskDelTool] Searching for task matching '\(text.prefix(140))'")

        // Load current KB
        let current = PromptStore.kbTextSnapshot()

        if current.isEmpty {
            print("[TaskDelTool] Knowledge base is empty")
            return ToolJSON.string(from: ["error": "No scheduled task found matching '\(text)'."])
        }

        // Optional schedule_time for disambiguation
        let scheduleTime: String?
        if case .string(let t) = arguments["schedule_time"], !t.trimmingCharacters(in: .whitespaces).isEmpty {
            scheduleTime = t.trimmingCharacters(in: .whitespaces)
        } else {
            scheduleTime = nil
        }

        // Find matching [Task] lines.
        // If text starts with "[Task]", it's an exact rawLine match (from settings UI).
        // Otherwise, do substring search optionally filtered by schedule_time.
        let isExactMatch = text.hasPrefix("[Task]")
        let textLower = text.lowercased()
        let lines = current.components(separatedBy: "\n")
        let taskPattern = /^-\s*\[Task\]/.ignoresCase()

        var matches: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.prefixMatch(of: taskPattern) != nil else { continue }
            let statement = trimmed.replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression)
            if isExactMatch {
                if statement.lowercased() == textLower { matches.append(statement) }
            } else {
                guard trimmed.lowercased().contains(textLower) else { continue }
                if let time = scheduleTime, !trimmed.contains(time) { continue }
                matches.append(statement)
            }
        }

        if matches.isEmpty {
            print("[TaskDelTool] No matching task found for '\(text)'")
            return ToolJSON.string(from: ["error": "No scheduled task found matching '\(text)'."])
        }

        if matches.count > 1 && !isExactMatch {
            print("[TaskDelTool] \(matches.count) matching tasks found, returning list for clarification")
            // Strip [Task] Schedule/Once prefix but keep time for disambiguation
            let cleaned = matches.map { m in
                m.replacingOccurrences(of: "^\\[Task\\]\\s*(?:Schedule|Once)\\s*", with: "", options: .regularExpression)
            }
            let resultDict: [String: Any] = [
                "error": "Multiple scheduled tasks match '\(text)'. Include the schedule time to disambiguate.",
                "matches": cleaned,
            ]
            return ToolJSON.string(from: resultDict)
        }

        // Exactly one match — delete it
        let statement = matches[0]
        print("[TaskDelTool] Found match, deleting: '\(statement.prefix(140))'")

        let patchText = "DEL\n\(statement)"
        guard let updated = KBPatchApplier.applyKBPatch(content: current, patchText: patchText),
              updated != current else {
            print("[TaskDelTool] applyKBPatch failed or no change")
            return #"{"error": "failed to delete scheduled task from knowledge base"}"#
        }

        // Persist — Device Sync triggers automatically
        await MainActor.run { PromptStore.shared.rawKB = updated }
        print("[TaskDelTool] Persisted user_kb.md (\(updated.count) chars)")

        // Clear execution state so the task can fire fresh if recreated
        if let instrMatch = statement.range(of: ",\\s*(.+)$", options: .regularExpression) {
            let instruction = String(statement[instrMatch]).replacingOccurrences(of: "^,\\s*", with: "", options: .regularExpression)
            let hash = KBTaskParser.taskHash(KBTaskEntry(
                instruction: instruction, scheduleDays: nil, scheduleDate: nil,
                scheduleTime: "", timezone: nil, rawLine: statement
            ))
            await MainActor.run { TaskScheduler.clearExecutionState(for: hash) }
        }

        print("[TaskDelTool] Success")
        let resultDict: [String: Any] = ["ok": true, "removed": statement]
        return ToolJSON.string(from: resultDict)
    }
}
