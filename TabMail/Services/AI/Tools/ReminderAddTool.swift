/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `reminder_add` tool matching TB addon's `reminder_add.js`.
/// Creates a reminder in user_kb.md with automatic formatting.
/// Format: `[Reminder] Due YYYY/MM/DD HH:MM [TZ], text`
/// Registered in `ToolRegistry` at app startup.
struct ReminderAddTool: AgentTool, Sendable {
    let name = "reminder_add"

    func execute(arguments: [String: JSONValue]) async throws -> String {
        // Extract text (required)
        guard case .string(let rawText) = arguments["text"] else {
            print("[ReminderAddTool] Missing or empty 'text'")
            return #"{"error": "missing text"}"#
        }

        let text = AIService.normalizeUnicode(rawText).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            print("[ReminderAddTool] Empty text after normalization")
            return #"{"error": "missing text"}"#
        }

        // Extract optional due_date (YYYY/MM/DD)
        let dueDate: String?
        if case .string(let d) = arguments["due_date"], !d.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = d.trimmingCharacters(in: .whitespaces)
            let datePattern = /^\d{4}\/\d{2}\/\d{2}$/
            guard trimmed.wholeMatch(of: datePattern) != nil else {
                print("[ReminderAddTool] Invalid due_date format '\(trimmed)'")
                return #"{"error": "invalid due_date format, expected YYYY/MM/DD"}"#
            }
            dueDate = trimmed
        } else {
            dueDate = nil
        }

        // Extract optional due_time (HH:MM)
        let dueTime: String?
        if case .string(let t) = arguments["due_time"], !t.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = t.trimmingCharacters(in: .whitespaces)
            let timePattern = /^\d{2}:\d{2}$/
            guard trimmed.wholeMatch(of: timePattern) != nil else {
                print("[ReminderAddTool] Invalid due_time format '\(trimmed)'")
                return #"{"error": "invalid due_time format, expected HH:MM"}"#
            }
            dueTime = trimmed
        } else {
            dueTime = nil
        }

        // Build formatted KB entry (matching TB's formatReminderEntry)
        let entry = formatReminderEntry(text: text, dueDate: dueDate, dueTime: dueTime)
        print("[ReminderAddTool] Formatted entry='\(entry.prefix(140))' len=\(entry.count)")

        // Load current KB
        let current = PromptStore.kbTextSnapshot()

        let patchText = "ADD\n\(entry)"
        guard let updated = KBPatchApplier.applyKBPatch(content: current, patchText: patchText) else {
            print("[ReminderAddTool] applyKBPatch returned nil")
            return #"{"error": "failed to update knowledge base"}"#
        }

        if updated == current {
            print("[ReminderAddTool] No-op (duplicate)")
            return "No change (duplicate reminder)."
        }

        // Persist — Device Sync triggers automatically
        await MainActor.run { PromptStore.shared.rawKB = updated }
        print("[ReminderAddTool] Persisted user_kb.md (\(updated.count) chars)")

        print("[ReminderAddTool] Success")
        // Return JSON matching TB's return format
        let resultDict: [String: Any] = ["ok": true, "reminder": entry]
        return ToolJSON.string(from: resultDict)
    }

    // MARK: - Formatting

    /// Build a formatted KB reminder entry from structured params.
    /// Includes the user's IANA timezone when a due date is present.
    /// Matches TB's `formatReminderEntry()` in `reminder_add.js`.
    private func formatReminderEntry(text: String, dueDate: String?, dueTime: String?) -> String {
        let tz = dueDate != nil ? TimeZone.current.identifier : nil
        let tzSuffix = tz.map { " [\($0)]" } ?? ""

        if let dueDate, let dueTime {
            return "[Reminder] Due \(dueDate) \(dueTime)\(tzSuffix), \(text)"
        }
        if let dueDate {
            return "[Reminder] Due \(dueDate)\(tzSuffix), \(text)"
        }
        return "[Reminder] \(text)"
    }
}
