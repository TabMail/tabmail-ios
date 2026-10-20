/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Shared formatting helpers for AI agent tool responses.
/// Extracted from duplicated implementations across InboxReadTool, EmailReadTool,
/// EmailSearchTool, MemoryReadTool, MemorySearchTool.
enum ToolFormatters {

    // MARK: - Date Formatting

    /// Format a Date as ISO8601 for tool responses.
    /// Used by email tools (InboxRead, EmailRead, EmailSearch).
    static func formatDate(_ date: Date) -> String {
        date.iso8601String()
    }

    /// Format an epoch-millisecond timestamp as ISO8601.
    /// Used by memory tools (MemoryRead, MemorySearch).
    static func formatDateMs(_ timestampMs: Double) -> String {
        Date(timeIntervalSince1970: timestampMs / 1000).iso8601String()
    }

    // MARK: - Email Formatting

    /// Format sender as "Name <email>" for tool responses.
    /// Returns just the address if name is empty or identical to address.
    static func formatFrom(_ header: MessageHeader) -> String {
        if header.fromAddress.isEmpty { return header.from }
        if header.from == header.fromAddress || header.from.isEmpty { return header.fromAddress }
        return "\(header.from) <\(header.fromAddress)>"
    }

    // MARK: - Date Parsing

    /// Parse a date string from tool arguments. Supports YYYY-MM-DD and full ISO8601.
    static func parseDate(_ value: JSONValue?) -> Date? {
        guard case .string(let str) = value, !str.isEmpty else { return nil }
        // A full ISO8601 timestamp first (with or without fractional seconds):
        // the date-only parser also accepts a timestamp's date part, as midnight.
        if let date = Date.fromISO8601(str) { return date }
        // Then an ISO date: YYYY-MM-DD
        return Date.fromISO8601FullDate(str)
    }
}
