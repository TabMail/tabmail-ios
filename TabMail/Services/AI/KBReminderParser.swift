/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// A reminder parsed from KB text (e.g., `- [Reminder] Due 2026/02/23 14:00 [America/Vancouver], Reply to Prof.`).
struct KBReminder: Sendable {
    let content: String
    let dueDate: String?  // "YYYY-MM-DD" (normalized from YYYY/MM/DD in KB)
    let dueTime: String?  // "HH:MM"
    let timezone: String? // IANA timezone (e.g., "America/Vancouver")
}

/// Parses `[Reminder]` entries from knowledge base text.
/// Port of TB's `kbReminderGenerator.js` — simplified: no browser.storage caching,
/// just parse on demand from PromptStore's KB text.
/// ADR-IOS-008: AI processing MUST exactly replicate TB addon architecture.
enum KBReminderParser {

    // MARK: - Parse Cache

    private struct ParseCache: Sendable {
        var inputHash: Int = 0
        var result: [KBReminder] = []  // unfiltered — all parsed reminders
    }

    private static let parseCache = Mutex(ParseCache())

    /// Clear cached parse results. Called when KB text changes.
    static func invalidateCache() {
        parseCache.withLock { $0 = ParseCache() }
    }

    // MARK: - Public API

    /// Parse [Reminder] entries from KB text. Filters out reminders > 1 day overdue.
    /// Regex results are cached keyed on kbText hash — repeated calls with the same text skip regex.
    /// `filterActiveReminders` (cheap date comparisons) runs on every call since it's date-sensitive.
    /// Matches TB's `parseRemindersFromKB()` + `filterActiveReminders()`.
    static func parse(_ kbText: String) -> [KBReminder] {
        guard !kbText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let textHash = kbText.hashValue
        if let hit = parseCache.withLock({ $0.inputHash == textHash ? $0.result : nil }) {
            let active = filterActiveReminders(hit)
            return active
        }

        let all = parseRemindersFromKB(kbText)
        parseCache.withLock { $0 = ParseCache(inputHash: textHash, result: all) }
        let active = filterActiveReminders(all)
        print("[KBReminderParser] Found \(all.count) reminder entries, \(active.count) active after filtering")
        return active
    }

    // MARK: - Parsing

    /// Regex: `- [Reminder] Due YYYY/MM/DD [HH:MM] [TZ], text` or `- Reminder: Due YYYY/MM/DD [HH:MM] [TZ], text`
    nonisolated(unsafe) private static let reminderWithDatePattern = /^-\s*(?:\[Reminder\]|Reminder:)\s*Due\s+(\d{4})\/(\d{2})\/(\d{2})(?:\s+(\d{2}):(\d{2}))?(?:\s+\[([^\]]+)\])?,\s*(.+)$/.ignoresCase()

    /// Regex: `- [Reminder] text` or `- Reminder: text` (no due date)
    nonisolated(unsafe) private static let reminderNoDuePattern = /^-\s*(?:\[Reminder\]|Reminder:)\s+(?!Due\s)(.+)$/.ignoresCase()

    private static func parseRemindersFromKB(_ kbContent: String) -> [KBReminder] {
        var reminders: [KBReminder] = []
        let lines = kbContent.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let match = trimmed.wholeMatch(of: reminderWithDatePattern) {
                let year = String(match.1)
                let month = String(match.2)
                let day = String(match.3)
                let dueDate = "\(year)-\(month)-\(day)"
                let dueTime: String? = match.4.map { "\($0):\(match.5!)" }
                let timezone: String? = match.6.map(String.init)
                let content = String(match.7).trimmingCharacters(in: .whitespaces)

                reminders.append(KBReminder(
                    content: content,
                    dueDate: dueDate,
                    dueTime: dueTime,
                    timezone: timezone
                ))
                continue
            }

            if let match = trimmed.wholeMatch(of: reminderNoDuePattern) {
                let content = String(match.1).trimmingCharacters(in: .whitespaces)
                reminders.append(KBReminder(
                    content: content,
                    dueDate: nil,
                    dueTime: nil,
                    timezone: nil
                ))
            }
        }

        return reminders
    }

    // MARK: - Filtering

    /// Filter out past-due reminders (more than 1 day old).
    /// Matches TB's `filterActiveReminders()`.
    private static func filterActiveReminders(_ reminders: [KBReminder]) -> [KBReminder] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let cutoffDate = calendar.date(byAdding: .day, value: -1, to: today)!

        return reminders.filter { reminder in
            guard let dueDateStr = reminder.dueDate else {
                // No due date = always active
                return true
            }

            // Parse YYYY-MM-DD
            let parts = dueDateStr.split(separator: "-")
            guard parts.count == 3,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let day = Int(parts[2]) else {
                // Invalid date = keep it
                return true
            }

            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            guard let dueDate = calendar.date(from: components) else {
                return true
            }

            // Keep if due date is after cutoff (today - 1 day)
            return dueDate >= cutoffDate
        }
    }
}
