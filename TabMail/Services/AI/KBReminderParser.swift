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

    /// Parse [Reminder] entries from KB text. Returns ALL reminders, including
    /// overdue ones — no expiry (see `filterActiveReminders`).
    /// Regex results are cached keyed on kbText hash — repeated calls with the same text skip regex.
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

    /// Returns all parsed reminders unchanged. Overdue reminders are
    /// intentionally retained — they must stay visible in the reminders menu
    /// and chat cards rather than silently vanish a day after their due date
    /// (changed 2026-06-13; previously dropped reminders more than 1 day
    /// overdue). Over-notification is guarded independently downstream:
    /// `ProactiveNotifyService` only fires an overdue reminder that is still
    /// `isWithinWindow`, `enabled`, and not already in `ReachedOutStore`.
    /// Kept as a named policy seam in lockstep with TB's
    /// `kbReminderGenerator.js` `filterActiveReminders()` (ADR-IOS-008 parity).
    private static func filterActiveReminders(_ reminders: [KBReminder]) -> [KBReminder] {
        reminders
    }
}
