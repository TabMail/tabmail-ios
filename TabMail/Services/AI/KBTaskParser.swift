/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// A task entry parsed from KB text (e.g., `- [Task] Schedule weekdays 09:00 [America/Vancouver], Summarize overnight emails`).
/// Also supports one-off tasks: `- [Task] Once 2026/03/28 15:00 [America/Vancouver], Check if Bob replied`.
struct KBTaskEntry: Sendable {
    let instruction: String
    let scheduleDays: String?  // raw: "daily", "weekdays", "weekends", "mon,wed,fri" — nil for one-off
    let scheduleDate: String?  // "YYYY/MM/DD" — nil for recurring
    let scheduleTime: String   // "HH:MM"
    let timezone: String?      // IANA timezone or nil
    let rawLine: String

    /// Whether this is a one-off task (has scheduleDate, no scheduleDays).
    var isOneOff: Bool { scheduleDate != nil }
}

/// Parses `[Task]` entries from knowledge base text.
/// Port of TB's `kbTaskParser.js` — pure static functions, no state.
/// ADR-IOS-008: AI processing MUST exactly replicate TB addon architecture.
enum KBTaskParser {

    // MARK: - Parse Cache

    private struct ParseCache: Sendable {
        var inputHash: Int = 0
        var result: [KBTaskEntry] = []
    }

    private static let parseCache = Mutex(ParseCache())

    /// Clear cached parse results. Called when KB text changes.
    static func invalidateCache() {
        parseCache.withLock { $0 = ParseCache() }
    }

    // MARK: - Public API

    /// Parse [Task] entries from KB text. Skips malformed lines with a warning log.
    /// Results are cached keyed on kbText hash — repeated calls with the same text skip regex.
    /// Matches TB's `parseTasksFromKB()`.
    static func parse(_ kbText: String) -> [KBTaskEntry] {
        guard !kbText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let textHash = kbText.hashValue
        if let hit = parseCache.withLock({ $0.inputHash == textHash ? $0.result : nil }) {
            return hit
        }

        let result = performParse(kbText)
        parseCache.withLock { $0 = ParseCache(inputHash: textHash, result: result) }
        return result
    }

    /// The actual regex parsing work — called only on cache miss.
    private static func performParse(_ kbText: String) -> [KBTaskEntry] {
        var results: [KBTaskEntry] = []
        let lines = kbText.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Quick check: skip lines that don't mention [Task]
            guard trimmed.localizedCaseInsensitiveContains("[Task]") else {
                continue
            }

            // Try recurring pattern first
            if let match = trimmed.wholeMatch(of: recurringPattern) {
                let daysStr = String(match.1).lowercased()
                let hour = String(match.2)
                let minute = String(match.3)
                let timezone: String? = match.4.map(String.init)
                let instruction = String(match.5).trimmingCharacters(in: .whitespaces)

                let expandedDays = expandDays(daysStr)
                if expandedDays.isEmpty {
                    print("[KBTaskParser] Skipping task with unrecognized days \"\(daysStr)\": \"\(trimmed)\"")
                    continue
                }

                results.append(KBTaskEntry(
                    instruction: instruction,
                    scheduleDays: daysStr,
                    scheduleDate: nil,
                    scheduleTime: "\(hour):\(minute)",
                    timezone: timezone,
                    rawLine: trimmed
                ))
                continue
            }

            // Try one-off pattern
            if let match = trimmed.wholeMatch(of: oneOffPattern) {
                let dateStr = String(match.1)
                let hour = String(match.2)
                let minute = String(match.3)
                let timezone: String? = match.4.map(String.init)
                let instruction = String(match.5).trimmingCharacters(in: .whitespaces)

                results.append(KBTaskEntry(
                    instruction: instruction,
                    scheduleDays: nil,
                    scheduleDate: dateStr,
                    scheduleTime: "\(hour):\(minute)",
                    timezone: timezone,
                    rawLine: trimmed
                ))
                continue
            }

            print("[KBTaskParser] Skipping malformed task line: \"\(trimmed)\"")
        }

        print("[KBTaskParser] Parsed \(results.count) task entries from KB")
        return results
    }

    /// DJB2 hash for task entry (uses UTF-16 code units for parity with TB/JS).
    /// Returns "t:{hash}" format to distinguish from reminder hashes ("k:").
    /// Matches TB's `getTaskHash()`.
    /// Hash the full entry (instruction + schedule) so tasks with the same
    /// instruction but different times get unique hashes.
    static func taskHash(_ entry: KBTaskEntry) -> String {
        let str = entry.rawLine.isEmpty ? entry.instruction : entry.rawLine
        let hash = DisabledRemindersStore.djb2Hash(str)
        return "t:\(String(hash, radix: 36))"
    }

    // MARK: - Parsing

    /// Regex for recurring: `[Task] Schedule <days> HH:MM [timezone], instruction`
    /// Groups: 1=days, 2=HH, 3=MM, 4=timezone (optional), 5=instruction
    // swiftlint:disable:next line_length
    nonisolated(unsafe) private static let recurringPattern = /^(?:-\s*)?\[Task\]\s*Schedule\s+([\w,]+)\s+(\d{2}):(\d{2})(?:\s+\[([^\]]+)\])?,\s*(.+)$/.ignoresCase()

    /// Regex for one-off: `[Task] Once <YYYY/MM/DD> HH:MM [timezone], instruction`
    /// Groups: 1=date, 2=HH, 3=MM, 4=timezone (optional), 5=instruction
    // swiftlint:disable:next line_length
    nonisolated(unsafe) private static let oneOffPattern = /^(?:-\s*)?\[Task\]\s*Once\s+(\d{4}\/\d{2}\/\d{2})\s+(\d{2}):(\d{2})(?:\s+\[([^\]]+)\])?,\s*(.+)$/.ignoresCase()

    // MARK: - Day Expansion

    private static let allDays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    private static let weekdays = ["mon", "tue", "wed", "thu", "fri"]
    private static let weekends = ["sat", "sun"]

    /// Expand day specifiers into arrays of lowercase day abbreviations.
    /// Matches TB's `expandDays()`.
    private static func expandDays(_ daysStr: String) -> [String] {
        if daysStr == "daily" { return allDays }
        if daysStr == "weekdays" { return weekdays }
        if daysStr == "weekends" { return weekends }

        // Comma-separated day abbreviations
        let parts = daysStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.filter { allDays.contains($0) }
    }
}
