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
        // The call belongs to the mode it started in (DS-DEMO): the demo-switch count is taken before anything
        // awaits and the prompt store compares it when the call's turn comes.
        let entered = PromptStore.switchesSeen
        // The email-reminder fallback awaits the reminder build before it writes, so it carries the change
        // counter the call started with (DS-DEMO): a demo switch in between refuses its write.
        let started = ChangeCounter.device.current
        guard case .string(let rawText) = arguments["text"] else {
            BackgroundSyncLogger.logDebug("[ReminderDelTool] Missing or empty 'text'")
            return #"{"error": "missing text"}"#
        }

        let text = AIService.normalizeUnicode(rawText).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            BackgroundSyncLogger.logDebug("[ReminderDelTool] Empty text after normalization")
            return #"{"error": "missing text"}"#
        }

        BackgroundSyncLogger.logDebug("[ReminderDelTool] Searching for reminder matching '\(text.prefix(140))'")

        // The search and the delete in one hold of the prompt store: the reminder deleted is one the
        // search found in the knowledge base as it is now, never one that arrived after an earlier read
        // (DS-CAPTURE). The commit sends it (Device Sync).
        let textLower = text.lowercased()
        let found = await { @MainActor () async -> (matches: [String], outcome: PromptEditOutcome) in
            var matches: [String] = []
            let outcome = await PromptStore.shared.edit("reminder_del tool", entered: entered) { hold in
                try hold.editText(.kb) { current in
                    matches = Self.reminderStatements(in: current, matching: textLower)
                    guard matches.count == 1 else { return nil }
                    BackgroundSyncLogger.logDebug("[ReminderDelTool] Found match, deleting: '\(matches[0].prefix(140))'")
                    return KBPatchApplier.applyKBPatch(content: current, patchText: "DEL\n\(matches[0])")
                }
            }
            return (matches, outcome)
        }()

        // Refused before the search ran: the model is told why.
        if let refusal = KBToolEdit.refusal(found.outcome) { return refusal }

        if found.matches.isEmpty && found.outcome == .unchanged {
            // No KB match — search email-based (message) reminders and snooze if found
            BackgroundSyncLogger.logDebug("[ReminderDelTool] No KB match, searching message reminders...")
            return await handleMessageReminderDeletion(text: text, textLower: textLower, since: started)
        }

        if found.matches.count > 1 {
            BackgroundSyncLogger.logDebug("[ReminderDelTool] \(found.matches.count) matching reminders found, returning list for clarification")
            // Strip [Reminder] prefix for cleaner display
            let cleaned = found.matches.map { m in
                m.replacingOccurrences(of: "^(?:Reminder:\\s*|\\[Reminder\\]\\s*)", with: "", options: .regularExpression)
            }
            let resultDict: [String: Any] = [
                "error": "Multiple reminders match '\(text)'. Please be more specific.",
                "matches": cleaned,
            ]
            return ToolJSON.string(from: resultDict)
        }

        guard found.outcome == .saved, let statement = found.matches.first else {
            BackgroundSyncLogger.logDebug("[ReminderDelTool] applyKBPatch failed or no change (\(found.outcome))")
            return #"{"error": "failed to delete reminder from knowledge base"}"#
        }
        BackgroundSyncLogger.logDebug("[ReminderDelTool] Persisted user_kb.md")

        BackgroundSyncLogger.logDebug("[ReminderDelTool] Success")
        let resultDict: [String: Any] = ["ok": true, "removed": statement]
        return ToolJSON.string(from: resultDict)
    }

    /// The KB reminder lines ("- Reminder: …" or "- [Reminder] …") containing `textLower`, without their
    /// leading "- ".
    private static func reminderStatements(in kb: String, matching textLower: String) -> [String] {
        let reminderPattern = /^-\s*(?:Reminder:|\[Reminder\])/.ignoresCase()
        var matches: [String] = []
        for line in kb.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.prefixMatch(of: reminderPattern) != nil else { continue }
            if trimmed.lowercased().contains(textLower) {
                matches.append(trimmed.replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression))
            }
        }
        return matches
    }

    // MARK: - Message Reminder Snoozing

    /// Search message reminders and snooze (disable) if found.
    /// Matches TB's email-reminder fallback path in `reminder_del.js`.
    private func handleMessageReminderDeletion(text: String, textLower: String, since started: UUID) async -> String {
        let allReminders = await ReminderBuilder.buildReminderList(includeDisabled: false)
        let messageMatches = allReminders.filter {
            $0.source == "message" && $0.content.lowercased().contains(textLower)
        }

        if messageMatches.count == 1 {
            let reminder = messageMatches[0]
            BackgroundSyncLogger.logDebug("[ReminderDelTool] Found email-reminder, snoozing: '\(reminder.content.prefix(140))'")
            // Refused, with nothing written, when the change counter moved since the call started (DS-DEMO).
            guard DisabledRemindersStore.setEnabled(hash: reminder.hash, enabled: false, since: started) else {
                return #"{"error": "could not save the change; try again"}"#
            }
            BackgroundSyncLogger.logDebug("[ReminderDelTool] Success (email-reminder snoozed)")
            let resultDict: [String: Any] = ["ok": true, "snoozed": reminder.content, "source": "email"]
            return ToolJSON.string(from: resultDict)
        }

        if messageMatches.count > 1 {
            BackgroundSyncLogger.logDebug("[ReminderDelTool] \(messageMatches.count) matching email-reminders found")
            let resultDict: [String: Any] = [
                "error": "Multiple email reminders match '\(text)'. Please be more specific.",
                "matches": messageMatches.map(\.content),
            ]
            return ToolJSON.string(from: resultDict)
        }

        BackgroundSyncLogger.logDebug("[ReminderDelTool] No matching reminder found for '\(text)'")
        return #"{"error": "No reminder found matching '\#(text)'."}"#
    }
}
