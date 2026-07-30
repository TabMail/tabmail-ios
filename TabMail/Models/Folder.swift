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
    /// IMAP UIDVALIDITY — **the epoch the LOCAL UIDs in this folder belong to**,
    /// NOT "the epoch the server most recently reported". It is the
    /// deletion-reconcile walk's abort guard (ADR-IOS-051): the walk compares this
    /// against its live SELECT and ABORTS on a mismatch, because every local UID
    /// would then be from an invalidated numbering (never delete on uncertainty —
    /// the UID-remap/resync machinery owns that case).
    ///
    /// **Write rule — BOOTSTRAP-ONLY.** Written only while it is nil, by whichever
    /// path first observes a non-zero UIDVALIDITY: the folder-list pass and delta
    /// sync's STATUS (`SyncEngine.uidValidityBootstrapWrite` /
    /// `bootstrapFolderUidValidity`), or the walk's own first SELECT
    /// (`SyncEngineDeletionReconcile.swift:428`). NEVER overwritten afterwards — an
    /// observation that DIFFERS is a turnover, and advancing this column without
    /// first purging the rows that belong to the old epoch silently disarms the
    /// guard above and turns the walk into a mass-deleter. `0` is "the server did
    /// not report a value" and is never stored (`SyncEngine.knownUidValidity`).
    ///
    /// **nil means UNKNOWN — it is NOT proof of an empty/fresh folder.** A folder
    /// populated before this column existed, or one whose row was deleted and
    /// re-created for the same path (folder rows are deleted on a remote
    /// disappearance; their headers are NOT — migration v2 dropped the
    /// `messageHeader.folderId` FK, so they survive orphaned and re-attach under the
    /// deterministic `accountId:path` id), holds OLD-epoch headers under a nil
    /// epoch. The first bootstrap then ASSERTS those headers belong to the observed
    /// epoch. Closing that needs a whole-folder epoch-ADVANCEMENT protocol
    /// (quarantine → purge → stamp → resync, ADR-IOS-061 in the `v2final` line);
    /// until one exists this is an accepted, documented residual, unchanged from
    /// the walk's own pre-existing nil-bootstrap branch.
    var lastKnownUidValidity: Int?
    /// IMAP CONDSTORE (RFC 7162): last observed HIGHESTMODSEQ — the flag-aware
    /// change cursor for delta/full sync. When `uidNext`+`totalCount` are unchanged
    /// but this bumped, a \Seen/flag change happened on an EXISTING message (which
    /// STATUS-count-only detection misses today). Only comparable WITHIN one
    /// UIDVALIDITY epoch. It is NOT reset on a turnover: under the bootstrap-only
    /// rule above the stored epoch stays behind until an epoch-advancement protocol
    /// exists, so a reset-on-mismatch rule would re-fire every cycle and destroy the
    /// CONDSTORE signal for that folder permanently. Nor does the epoch gate the
    /// CONDSTORE fetch-SKIP: forcing a fetch across a turnover hands the folder to
    /// `runSyncMessages`, whose stale sweep has no epoch guard, so "fetch more" is
    /// the DESTRUCTIVE direction there, not the safe one. A turnover moves
    /// uidNext/count anyway, so a stale-epoch modseq self-corrects on the following
    /// cycle. Nil until the first STATUS on a CONDSTORE server; nil also means "no
    /// CONDSTORE" → callers fall back to the uidNext+count comparison.
    var lastKnownHighestModSeq: Int?

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
