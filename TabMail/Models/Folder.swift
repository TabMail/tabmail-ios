/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

enum FolderRole: String, Codable, Sendable {
    case inbox
    case sent
    case drafts
    case trash
    case archive
    case spam
    case custom
}

struct Folder: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    // Hash on id only (Set/Dictionary bucket key). Equality compares all UI-visible
    // fields so SwiftUI re-renders rows when unreadCount, name, etc. change.
    // `role` is included because Settings → Account Detail surfaces role icons /
    // labels per folder; without it, ForEach diff caches stale rows after the
    // user re-assigns or clears a role.
    static func == (lhs: Folder, rhs: Folder) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.role == rhs.role &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.totalCount == rhs.totalCount &&
        lhs.isFavorite == rhs.isFavorite &&
        lhs.backfillComplete == rhs.backfillComplete
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let databaseTableName = "folder"

    var id: String
    var accountId: String
    var name: String
    var path: String = "" // Server-side identifier (Gmail: label ID, IMAP: mailbox name)
    var role: FolderRole
    var unreadCount: Int
    var totalCount: Int
    var isFavorite: Bool = false

    /// Whether progressive backfill has completed for this folder (all messages within age limit synced)
    var backfillComplete: Bool = false
    /// How far back we've synced. Nil = never backfilled.
    var oldestSyncedDate: Date?
    /// IMAP: last known UIDNEXT value for delta sync change detection
    var lastKnownUidNext: Int?
    /// IMAP: UID cursor for backward backfill. Walks from UIDNEXT down to 1.
    var backfillUidCursor: Int?
    /// Gmail/Exchange: page token for cursor-based backfill. Resumes listing from stored position.
    var backfillPageToken: String?
    /// IMAP: last observed UIDVALIDITY, used as the deletion-reconcile walk's
    /// abort guard (ADR-IOS-051). Bootstrapped by the walk's first SELECT; a
    /// later mismatch means every local UID is from an invalidated numbering,
    /// so the walk ABORTS (never delete on uncertainty — the UID-remap/resync
    /// machinery owns that case). Nil until the first walk runs.
    var lastKnownUidValidity: Int?

    init(name: String, path: String, role: FolderRole, accountId: String) {
        self.id = "\(accountId):\(path)"
        self.accountId = accountId
        self.name = name
        self.path = path
        self.role = role
        self.unreadCount = 0
        self.totalCount = 0
    }
}
