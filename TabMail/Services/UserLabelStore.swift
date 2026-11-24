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
    ///
    /// 🚨 `id:` MEANS THE BARE PROVIDER VALUE — pass `UserLabel.providerLabelId`, NEVER
    /// `UserLabel.id`. Every test in the `id` branch below (`excludedNames.contains`, the
    /// `[imap]` / `[gmail]` / `category_` prefixes) is a statement about what the PROVIDER
    /// called the label. `UserLabel.id` is the account-prefixed surrogate
    /// `"<accountId>:<providerLabelId>"` (D10 / `IOS-LABEL-001`), so handing it here makes
    /// every one of those tests silently stop matching and leaks system labels into the
    /// chips. The parameter keeps its name because the other callers
    /// (`isGmailSystemLabel`, the sync arms) already pass raw provider values.
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
    ///
    /// ⚑ NO `accountId` PREDICATE, AND IT MUST NOT GAIN ONE (D10 / `IOS-LABEL-001`). The
    /// unified inbox batches messages from EVERY account into one call, so a single
    /// `accountId` argument would be wrong here, not merely awkward. Account scoping is
    /// instead carried by `userLabel.id` itself, which is `"<accountId>:<providerLabelId>"`
    /// — a join through `messageUserLabel.userLabelId` can only reach the owning account's
    /// row. That is stronger than a predicate: the predicate could be forgotten at a call
    /// site, the key cannot.
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
                    .filter { !shouldExcludeLabel(id: $0.providerLabelId, name: $0.name) }
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
            .filter { !shouldExcludeLabel(id: $0.providerLabelId, name: $0.name) }
    }

    /// Labels applied to a specific message (non-system only, excluded keywords filtered).
    ///
    /// ⚑ No `accountId` predicate, for the reason spelled out on `loadLabels` — the
    /// surrogate `userLabel.id` carries the account, so the join cannot cross the
    /// boundary (D10 / `IOS-LABEL-001`).
    static func labelsForMessage(_ messageId: String, in db: Database) throws -> [UserLabel] {
        let rows = try MessageUserLabel
            .filter(Column("messageId") == messageId)
            .including(required: MessageUserLabel.userLabel
                .filter(Column("isSystem") == false))
            .asRequest(of: MessageUserLabelWithUserLabel.self)
            .fetchAll(db)
        return rows.map(\.userLabel)
            .filter { !shouldExcludeLabel(id: $0.providerLabelId, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Menu

    enum Config {
        /// How many recently used labels the label menu lists above the A-to-Z list.
        static let menuRecentCount = 3
    }

    /// The label menu's rows for one message (#1386).
    struct Menu: Sendable {
        /// Up to `Config.menuRecentCount` labels the user applied in this app, most
        /// recently applied first. Empty until the user applies a label here.
        let recent: [UserLabel]
        /// Every label of the account, A to Z (`allLabels`); the recent ones appear in
        /// it again.
        let all: [UserLabel]
        /// The labels of `all` on this message: the menu's checkmarks.
        let appliedIds: Set<String>
    }

    /// The label menu for `messageId` in `accountId` (#1386, ADR-IOS-118). It reads the
    /// account's labels, the times in `userLabelLastUsed`, and this message's own label
    /// rows, and no other message: the menu used to rank labels by how many inbox
    /// messages carried each, which read every inbox message and its label rows each
    /// time the menu opened.
    ///
    /// `recent` keeps only labels that are also in `all`, so a system label, an excluded
    /// keyword or another account's label never reaches the top even if it has a time.
    /// That is also why the read of `userLabelLastUsed` names no account: the table
    /// holds one row per label the user has applied in this app, so all of it is a
    /// small read, and the lookup in `all` keeps this account's labels.
    static func menu(accountId: String, messageId: String, in db: Database) throws -> Menu {
        let all = try allLabels(accountId: accountId, in: db)
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let usedIds = try String.fetchAll(db, sql: """
            SELECT userLabelId FROM userLabelLastUsed ORDER BY lastUsedAt DESC, userLabelId
            """)
        let recent = Array(usedIds.compactMap { byId[$0] }.prefix(Config.menuRecentCount))
        let appliedIds = try Set(String.fetchAll(
            db, MessageUserLabel.select(Column("userLabelId")).filter(Column("messageId") == messageId)))
            .intersection(byId.keys)
        return Menu(recent: recent, all: all, appliedIds: appliedIds)
    }

    /// Records that the user applied `labelId` (`UserLabel.id`) in this app at `time`
    /// (#1386, ADR-IOS-118). Only the label menu's apply calls it, inside the transaction
    /// that writes the label's join row and queues its operation, so a label has a time
    /// exactly when such an apply was admitted. Removing a label, a label applied on
    /// another device, and a label sync brings in leave it alone.
    static func recordUse(of labelId: String, at time: Date, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO userLabelLastUsed (userLabelId, lastUsedAt) VALUES (?, ?)
            ON CONFLICT(userLabelId) DO UPDATE SET lastUsedAt = excluded.lastUsedAt
            """, arguments: [labelId, time])
    }
}
