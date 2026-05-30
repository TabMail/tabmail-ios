/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Service for UserLabel CRUD, queries, and validation.
/// All display queries filter `isSystem = false` — system labels are stored for sync bookkeeping
/// but never shown as chips. Filtering happens at this layer, not the view layer.
enum UserLabelStore {

    // MARK: - Label Exclusion (unified — used at insert, display, and creation time)

    /// Known non-user-label names (lowercased). Catches exact matches.
    private static let excludedNames: Set<String> = [
        // IMAP standard flag names (with and without $ prefix)
        "forwarded", "$forwarded", "junk", "$junk",
        "notjunk", "$notjunk", "nonjunk", "$nonjunk",
        "nojunk", "nonspam", "recent", "$recent",
        "mdnsent", "$mdnsent", "phishing", "$phishing",
        "hasattachment", "$hasattachment", "hasnoattachment", "$hasnoattachment",
        "$submitpending", "$submitted",
        "$label1", "$label2", "$label3", "$label4", "$label5",
        // Gmail system label IDs
        "inbox", "sent", "trash", "draft", "spam",
        "starred", "important", "unread", "chat", "notes",
        // Gmail auto-created label names
        "all mail", "conversation history", "external",
    ]

    /// Unified check: should this label/keyword be hidden from user display?
    /// Works for IMAP keywords, Gmail label IDs, Gmail label names, and folder paths.
    /// Used at insert time (sync), display time (loadLabels), and creation time (isReservedName).
    static func shouldExcludeLabel(id: String? = nil, name: String) -> Bool {
        let lower = name.lowercased()
        // Prefix patterns — catches entire families
        if lower.hasPrefix("tm_") { return true }        // TabMail internal
        if lower.hasPrefix("\\") { return true }         // IMAP standard flags (\Seen, \Recent, etc.)
        if lower.hasPrefix("$") { return true }          // All $-prefixed conventional keywords
        if lower.hasPrefix("[imap]/") { return true }    // IMAP folder paths
        if lower.hasPrefix("[imap]") { return true }     // [Imap] without slash
        if lower.hasPrefix("[gmail]/") { return true }   // Gmail folder paths
        if lower.hasPrefix("[gmail]") { return true }    // [Gmail] without slash
        if lower.hasPrefix("category_") { return true }  // Gmail categories
        // Exact name matches
        if excludedNames.contains(lower) { return true }
        // Gmail internal label ID pattern (Label_N) — catches system labels like Notes,
        // Conversation History, etc. that Gmail assigns Label_N IDs. Checked on the name
        // (not the ID) because user-created labels also have Label_N IDs but always have
        // proper display names. Only the fallback UserLabel rows (created during sync with
        // name = raw label ID) have "Label_N" as the name.
        if isGmailInternalLabelId(lower) { return true }
        // Check ID too if provided
        if let id = id {
            let lowerId = id.lowercased()
            if excludedNames.contains(lowerId) { return true }
            // Recheck prefixes on ID (Gmail system label IDs are uppercase)
            if lowerId.hasPrefix("[imap]") || lowerId.hasPrefix("[gmail]") || lowerId.hasPrefix("category_") { return true }
        }
        return false
    }

    /// Gmail internal label IDs follow the pattern "Label_N" (e.g., "Label_46").
    /// Both system auto-created labels (Notes, Conversation History, External) and
    /// user-created labels share this pattern, but user labels have proper display names
    /// — only the raw ID matches this pattern. Blocking it prevents system labels from
    /// leaking through and stops users from creating labels with raw-ID-style names.
    private static func isGmailInternalLabelId(_ lowered: String) -> Bool {
        guard lowered.hasPrefix("label_") else { return false }
        let suffix = lowered.dropFirst(6) // "label_".count
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// Convenience: check by keyword string only (IMAP extraction path).
    static func isExcludedKeyword(_ keyword: String) -> Bool {
        shouldExcludeLabel(name: keyword)
    }

    /// Convenience: check Gmail label by ID and name.
    static func isGmailSystemLabel(id labelId: String, name labelName: String? = nil) -> Bool {
        shouldExcludeLabel(id: labelId, name: labelName ?? labelId)
    }

    /// Check if a name is reserved and cannot be used for user-created labels.
    static func isReservedName(_ name: String) -> Bool {
        shouldExcludeLabel(name: name)
    }

    // MARK: - Nested Label Splitting

    /// Split nested Gmail label name (e.g., "Work/Projects/Alpha") into individual segments.
    /// Each segment becomes its own UserLabel entry.
    static func splitNestedLabelName(_ name: String) -> [String] {
        let segments = name.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
        return segments.filter { !$0.isEmpty }
    }

    // MARK: - Shared Query Utility

    /// Load labels for a batch of message IDs. Call from any message-loading code path.
    /// Returns a dictionary keyed by messageId, values are arrays of UserLabel (non-system only).
    /// Filters at display time using shouldExcludeLabel to catch keywords that slipped through at insert time.
    static func loadLabels(for messageIds: [String], in db: Database) throws -> [String: [UserLabel]] {
        guard !messageIds.isEmpty else { return [:] }
        let rows = try MessageUserLabel
            .filter(messageIds.contains(Column("messageId")))
            .including(required: MessageUserLabel.userLabel
                .filter(Column("isSystem") == false))
            .asRequest(of: MessageUserLabelWithUserLabel.self)
            .fetchAll(db)
        return Dictionary(grouping: rows, by: \.messageId)
            .mapValues { rows in
                rows.map(\.userLabel)
                    .filter { !shouldExcludeLabel(id: $0.id, name: $0.name) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
    }

    // MARK: - CRUD

    /// Find a user label by name + accountId. Case-insensitive match.
    static func findByName(_ name: String, accountId: String, in db: Database) throws -> UserLabel? {
        try UserLabel
            .filter(Column("accountId") == accountId)
            .filter(Column("isSystem") == false)
            .fetchAll(db)
            .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// All non-system labels for an account (excluded keywords filtered).
    static func allLabels(accountId: String, in db: Database) throws -> [UserLabel] {
        try UserLabel
            .filter(Column("accountId") == accountId && Column("isSystem") == false)
            .order(Column("name").collating(.localizedCaseInsensitiveCompare))
            .fetchAll(db)
            .filter { !shouldExcludeLabel(id: $0.id, name: $0.name) }
    }

    /// Labels applied to a specific message (non-system only, excluded keywords filtered).
    static func labelsForMessage(_ messageId: String, in db: Database) throws -> [UserLabel] {
        let rows = try MessageUserLabel
            .filter(Column("messageId") == messageId)
            .including(required: MessageUserLabel.userLabel
                .filter(Column("isSystem") == false))
            .asRequest(of: MessageUserLabelWithUserLabel.self)
            .fetchAll(db)
        return rows.map(\.userLabel)
            .filter { !shouldExcludeLabel(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Menu Sorting

    /// Returns all non-system labels for an account, sorted for the label management menu:
    /// 1. Labels applied to this message (checkmarked, alphabetical)
    /// 2. Labels appearing on inbox messages (by frequency descending)
    /// 3. Remaining labels (alphabetical)
    static func labelsSortedForMenu(
        accountId: String,
        messageId: String,
        inboxFolderIds: [String],
        in db: Database
    ) throws -> [(label: UserLabel, isApplied: Bool)] {
        // All non-system labels for account (filtered by exclusion rules)
        let allLabels = try UserLabel
            .filter(Column("accountId") == accountId && Column("isSystem") == false)
            .fetchAll(db)
            .filter { !shouldExcludeLabel(id: $0.id, name: $0.name) }

        // Labels applied to this message
        let appliedIds = Set(
            try MessageUserLabel
                .filter(Column("messageId") == messageId)
                .fetchAll(db)
                .map(\.userLabelId)
        )

        // Frequency: count of inbox messages per label
        var frequency: [String: Int] = [:]
        if !inboxFolderIds.isEmpty {
            let sql = """
                SELECT mul.userLabelId, COUNT(DISTINCT mul.messageId) as cnt
                FROM messageUserLabel mul
                JOIN messageHeader mh ON mh.id = mul.messageId
                WHERE mh.folderId IN (\(inboxFolderIds.map { _ in "?" }.joined(separator: ",")))
                GROUP BY mul.userLabelId
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(inboxFolderIds))
            for row in rows {
                frequency[row["userLabelId"]] = row["cnt"]
            }
        }

        // Sort: applied first (alpha), then by frequency desc, then alpha
        let applied = allLabels.filter { appliedIds.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { ($0, true) }
        let unapplied = allLabels.filter { !appliedIds.contains($0.id) }
            .sorted { a, b in
                let fa = frequency[a.id] ?? 0
                let fb = frequency[b.id] ?? 0
                if fa != fb { return fa > fb }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            .map { ($0, false) }
        return applied + unapplied
    }
}
