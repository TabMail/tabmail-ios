/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// MARK: - ISO 8601

extension Date {

    /// Format as ISO 8601 string (no fractional seconds), UTC: `2024-03-15T14:03:07Z`.
    /// Shared by tool responses, calendar API queries, log timestamps, and any
    /// place that emits ISO 8601.
    func iso8601String() -> String {
        ISO8601Formatters.internetDateTime.string(from: self)
    }

    /// Format as ISO 8601 in a specific time zone (e.g. ICS/Exchange calendar
    /// output where the event carries a TZID). Allocates per call because
    /// `timeZone` is stateful on `ISO8601DateFormatter`.
    func iso8601String(timeZone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        return f.string(from: self)
    }

    /// Parse an ISO 8601 date-time string, tolerating optional fractional seconds.
    /// Accepts both `2024-03-15T14:03:07Z` and `2024-03-15T14:03:07.123Z`.
    static func fromISO8601(_ str: String) -> Date? {
        if let d = ISO8601Formatters.withFractional.date(from: str) { return d }
        return ISO8601Formatters.internetDateTime.date(from: str)
    }

    /// Parse an ISO 8601 full-date string (YYYY-MM-DD), e.g. `"2024-03-15"`.
    /// Used for tool arguments that pass date-only values.
    static func fromISO8601FullDate(_ str: String) -> Date? {
        ISO8601Formatters.fullDate.date(from: str)
    }
}

/// Cached formatters. `ISO8601DateFormatter.string(from:)`/`date(from:)` are
/// documented thread-safe on iOS 7+, so sharing a configured-once instance is
/// fine. `nonisolated(unsafe)` reflects that guarantee (read-only after init,
/// no mutation — the compiler can't verify it, but the runtime is safe).
private enum ISO8601Formatters {
    nonisolated(unsafe) static let internetDateTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let fullDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}

// MARK: - Inbox UI

extension Date {

    /// Format date for inbox/search UI display.
    /// Today → time, Yesterday → "Yesterday", This week → day name,
    /// This year → "MMM d", Older → "MMM d, yyyy".
    func formattedForInbox() -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: self)
        } else if calendar.isDateInYesterday(self) {
            return "Yesterday"
        } else if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date())),
                  self >= weekAgo {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: self)
        } else {
            let formatter = DateFormatter()
            if !calendar.isDate(self, equalTo: Date(), toGranularity: .year) {
                formatter.dateFormat = "MMM d, yyyy"
            } else {
                formatter.dateFormat = "MMM d"
            }
            return formatter.string(from: self)
        }
    }
}
