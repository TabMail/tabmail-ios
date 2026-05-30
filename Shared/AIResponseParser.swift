/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Shared AI response parsing between main app and NSE.
/// Port of TB's `processSummaryResponse()` in llm.js.
/// Single source of truth — both targets reference this file.
enum AIResponseParser {

    struct SummaryResult {
        let blurb: String?
        let todos: String?
        let reminderDate: String?
        let reminderTime: String?
        let reminderContent: String?
    }

    /// Parse summary response from the backend.
    /// Matches TB's `processSummaryResponse()` in llm.js.
    static func parseSummaryResponse(_ text: String) -> SummaryResult {
        // 1. Pre-clean: strip markdown heading markers (## Todos: → Todos:)
        // Matches TB: text.replace(/^#+\s*/gm, "")
        let preCleaned = text.replacingOccurrences(
            of: #"(?m)^#+\s*"#, with: "", options: .regularExpression
        )

        // 2. Regex-based section extraction (matches TB's regex approach)
        let todosSection = extractSection(preCleaned, pattern: #"(?i)Todos:\s*([\s\S]*?)(?:Two-line summary:|$)"#)
        let twoLineSection = extractSection(preCleaned, pattern: #"(?i)Two-line summary:\s*([\s\S]*?)(?:Reminder due date:|$)"#)
        let reminderDueDateSection = extractSection(preCleaned, pattern: #"(?i)Reminder due date:\s*([\s\S]*?)(?:Reminder due time:|Reminder content:|$)"#)
        let reminderDueTimeSection = extractSection(preCleaned, pattern: #"(?i)Reminder due time:\s*([\s\S]*?)(?:Reminder content:|$)"#)
        let reminderContentSection = extractSection(preCleaned, pattern: #"(?i)Reminder content:\s*([\s\S]*)$"#)

        // 3. Normalize todos into bullet-delimited format (matches TB exactly)
        var todosClean = ""
        if !todosSection.isEmpty {
            let rawItems = todosSection.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let cleanedItems = rawItems.map { line in
                line.replacingOccurrences(
                    of: #"^(\d+[\.)]|[-*•])\s*"#, with: "", options: .regularExpression
                ).trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            if !cleanedItems.isEmpty {
                todosClean = cleanedItems.map { "• \($0)" }.joined(separator: " ")
            }
        }
        if todosClean.isEmpty {
            todosClean = todosSection.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }

        // 4. Blurb: newlines → spaces
        let blurbClean = twoLineSection.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        // 5. Reminder parsing
        let dueDateClean = reminderDueDateSection.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let dueTimeClean = reminderDueTimeSection.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let contentClean = reminderContentSection.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)

        func isNoneOrEmpty(_ value: String) -> Bool {
            let lower = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return lower == "none" || lower == "\"none\"" || lower.isEmpty
        }

        var reminderDate: String?
        var reminderTime: String?
        var reminderContent: String?

        if !isNoneOrEmpty(contentClean) {
            if !isNoneOrEmpty(dueDateClean) { reminderDate = dueDateClean }
            if !isNoneOrEmpty(dueTimeClean),
               dueTimeClean.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil {
                reminderTime = dueTimeClean
            }
            reminderContent = contentClean
        }

        return SummaryResult(
            blurb: blurbClean.isEmpty ? nil : blurbClean,
            todos: todosClean.isEmpty ? nil : todosClean,
            reminderDate: reminderDate,
            reminderTime: reminderTime,
            reminderContent: reminderContent
        )
    }

    /// Parse action tag from backend response JSON.
    /// Resilient to truncated responses — regex-based extraction.
    static func parseActionTag(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #""action"\s*:\s*"(\w+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else { return nil }
        let value = String(trimmed[range]).lowercased()
        guard ["delete", "archive", "reply", "none"].contains(value) else { return nil }
        return value
    }

    /// Extract first capture group from a regex pattern.
    private static func extractSection(_ text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return ""
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
