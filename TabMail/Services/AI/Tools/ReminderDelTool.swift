/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `reminder_del` tool matching TB addon's `reminder_del.js`.
/// Dual-path: deletes KB reminders permanently, snoozes email-based reminders.
/// Registered in `ToolRegistry` at app startup.
struct ReminderDelTool: AgentTool, Sendable {
    let name = "reminder_del"

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard case .string(let rawText) = arguments["text"] else {
            print("[ReminderDelTool] Missing or empty 'text'")
            return #"{"error": "missing text"}"#
        }

        let text = AIService.normalizeUnicode(rawText).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            print("[ReminderDelTool] Empty text after normalization")
            return #"{"error": "missing text"}"#
        }

        print("[ReminderDelTool] Searching for reminder matching '\(text.prefix(140))'")

        // Load current KB
        let current = PromptStore.kbTextSnapshot()

        // Find KB lines matching reminders that contain the search text
        let textLower = text.lowercased()
        let lines = current.components(separatedBy: "\n")
        let reminderPattern = /^-\s*(?:Reminder:|\[Reminder\])/.ignoresCase()

        var matches: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match lines that start with "- Reminder:" or "- [Reminder]"
            guard trimmed.prefixMatch(of: reminderPattern) != nil else { continue }
            // Check if the reminder content contains the search text (case-insensitive)
            if trimmed.lowercased().contains(textLower) {
                // Extract the raw statement (without leading "- ")
                let statement = trimmed.replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression)
                matches.append(statement)
            }
        }

        if matches.isEmpty {
            // No KB match — search email-based (message) reminders and snooze if found
            print("[ReminderDelTool] No KB match, searching message reminders...")
            return await handleMessageReminderDeletion(text: text, textLower: textLower)
        }

        if matches.count > 1 {
            print("[ReminderDelTool] \(matches.count) matching reminders found, returning list for clarification")
            // Strip [Reminder] prefix for cleaner display
            let cleaned = matches.map { m in
                m.replacingOccurrences(of: "^(?:Reminder:\\s*|\\[Reminder\\]\\s*)", with: "", options: .regularExpression)
            }
            let resultDict: [String: Any] = [
                "error": "Multiple reminders match '\(text)'. Please be more specific.",
                "matches": cleaned,
            ]
            return ToolJSON.string(from: resultDict)
        }

        // Exactly one match — delete it
        let statement = matches[0]
        print("[ReminderDelTool] Found match, deleting: '\(statement.prefix(140))'")

        let patchText = "DEL\n\(statement)"
        guard let updated = KBPatchApplier.applyKBPatch(content: current, patchText: patchText),
              updated != current else {
            print("[ReminderDelTool] applyKBPatch failed or no change")
            return #"{"error": "failed to delete reminder from knowledge base"}"#
        }

        // Persist
        await MainActor.run { PromptStore.shared.rawKB = updated }
        print("[ReminderDelTool] Persisted user_kb.md (\(updated.count) chars)")

        print("[ReminderDelTool] Success")
        let resultDict: [String: Any] = ["ok": true, "removed": statement]
        return ToolJSON.string(from: resultDict)
    }

    // MARK: - Message Reminder Snoozing

    /// Search message reminders and snooze (disable) if found.
    /// Matches TB's email-reminder fallback path in `reminder_del.js`.
    private func handleMessageReminderDeletion(text: String, textLower: String) async -> String {
        let allReminders = await ReminderBuilder.buildReminderList(includeDisabled: false)
        let messageMatches = allReminders.filter {
            $0.source == "message" && $0.content.lowercased().contains(textLower)
        }

        if messageMatches.count == 1 {
            let reminder = messageMatches[0]
            print("[ReminderDelTool] Found email-reminder, snoozing: '\(reminder.content.prefix(140))'")
            DisabledRemindersStore.setEnabled(hash: reminder.hash, enabled: false)
            print("[ReminderDelTool] Success (email-reminder snoozed)")
            let resultDict: [String: Any] = ["ok": true, "snoozed": reminder.content, "source": "email"]
            return ToolJSON.string(from: resultDict)
        }

        if messageMatches.count > 1 {
            print("[ReminderDelTool] \(messageMatches.count) matching email-reminders found")
            let resultDict: [String: Any] = [
                "error": "Multiple email reminders match '\(text)'. Please be more specific.",
                "matches": messageMatches.map(\.content),
            ]
            return ToolJSON.string(from: resultDict)
        }

        print("[ReminderDelTool] No matching reminder found for '\(text)'")
        return #"{"error": "No reminder found matching '\#(text)'."}"#
    }
}
