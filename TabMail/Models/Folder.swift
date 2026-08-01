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
    /// `bootstrapFolderUidValidity`), the message-sync pass's own SELECT
    /// (`SyncEngine.runSyncMessages`, via `IMAPProvider.selectMailboxTracked` and
    /// `EmailProvider.lastObservedUidValidity(folderPath:)` — T1.2b), the backfill
    /// crawl's own walk-start SELECT (`SyncEngine.bootstrapCrawledFolderUidValidity`,
    /// called from `SyncEngine.runBackfill` — the T1.3 anti-brick), or the walk's
    /// own first SELECT (`persistFolderUidValidity` in
    /// `SyncEngineDeletionReconcile.swift`).
    ///
    /// ⚠ Round 7 claimed the backfill crawl was the ONLY one of these that can
    /// reach a custom NON-FAVOURITE folder. That is FALSE and is retracted (round
    /// 8): `syncableFolders` does exclude such a folder from full sync, delta sync
    /// and self-heal, but ON-DEMAND NAVIGATION reaches any folder through
    /// `AccountManager.syncFolders(_:)`, which filters on `!folder.path.isEmpty`
    /// alone, and lands in `runSyncMessages` with its T1.2b bootstrap. Without the
    /// crawl's bootstrap the epoch stayed nil INDEFINITELY — until the user opened
    /// that folder — not forever; the crawl's bootstrap matters because backfill
    /// makes the folder's mail account-wide searchable long before that. See
    /// `SyncEngine.bootstrapCrawledFolderUidValidity` for the full retraction.
    ///
    /// The SELECT source is not redundant
    /// with STATUS: SwiftMail asks for the `UIDVALIDITY` STATUS attribute only on a
    /// UIDPLUS server, whereas `OK [UIDVALIDITY n]` on SELECT is core IMAP4rev1 —
    /// so without it a non-UIDPLUS account would leave every folder here nil
    /// forever. An observation that DIFFERS is a turnover, and advancing this column
    /// without first purging the rows that belong to the old epoch silently disarms
    /// the guard above and turns the walk into a mass-deleter. `0` is "the server did
    /// not report a value" and is never stored (`SyncEngine.knownUidValidity`).
    ///
    /// **EXACTLY ONE path overwrites a non-nil value (T4.S6):**
    /// `AccountManager.uidValidityResetStampFreshEpoch`, step 5 of the
    /// purge-and-resync reaction. It is allowed to because it discharges the very
    /// precondition the bootstrap-only rule protects: by the time it runs, step 3
    /// has DELETED every `messageHeader` row of this folder in its own committed
    /// transaction, so the stamp it advances describes an empty set and can be wrong
    /// about nothing. It is gated on `uidValidityResetPendingAt != nil` — i.e. only
    /// reachable from inside a reaction that armed the quarantine — and it clears
    /// that flag in the SAME write. Any OTHER advancing writer would have to
    /// reproduce both halves; do not add one.
    ///
    /// **One path CLEARS it back to nil, and only for a folder holding ZERO
    /// headers:** `SyncEngine.resetEmptyFolderCrawlEpoch` (in the FILE
    /// `SyncEngineBackfillWalk.swift`). "Never overwritten" is a rule about rows —
    /// with no rows there is nothing the stamp can be wrong about, nothing to
    /// purge, and no guard to disarm (the deletion-reconcile walk needs
    /// `localHeaderCount > messageCount` to fire at all, which zero can never
    /// satisfy). Without that clearer a stale stamp on an empty folder refuses its
    /// crawl on EVERY later cycle, permanently. The count is taken inside the same
    /// write transaction as the clear; the re-stamp is an ordinary bootstrap
    /// afterwards.
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
    ///
    /// ⚠ T4.S6 ported that protocol and it does NOT close this residual. The
    /// reaction's own trigger validation REFUSES to start on a folder whose stored
    /// epoch is nil (`AccountManager.runUidValidityResetReaction`), because with no
    /// stored epoch there is nothing to prove a turnover against — purging on that
    /// evidence would destroy a folder's local mail whenever a first observation
    /// happened to be taken. So a nil epoch over pre-existing headers still
    /// bootstraps by assertion. Unchanged residual, now with a named refusal.
    var lastKnownUidValidity: Int?
    /// **UIDVALIDITY reset quarantine (T4.S6).** Non-nil ⇒ this folder is mid-way
    /// through `AccountManager.runUidValidityResetReaction` — its rows either still
    /// belong to an epoch the server has abandoned, or have already been purged and
    /// not yet resynced. Armed in the reaction's step 1 and cleared in step 5, in
    /// the SAME gated write that stamps the fresh epoch (never one without the
    /// other).
    ///
    /// It is **re-drive state, not admission arbitration**: every abort leg of the
    /// reaction leaves it SET, so the folder is retryable rather than half-reset.
    /// Two consumers act on it, and both are the reason the column exists rather
    /// than the reaction relying on "stored epoch still disagrees with live":
    ///  - `SyncEngine.fullSync`'s per-folder loop BRANCHES INTO the reaction for a
    ///    quarantined folder instead of running an ordinary pass. Ordinary sync on a
    ///    purged-but-unstamped folder would insert NEW-epoch headers under the OLD
    ///    stamp, and a durable op holding a bare UID from the old epoch would then
    ///    address whichever new message occupies it — C3.
    ///  - `AccountManager.drainPendingQueue` PARKS (never drops) this folder's
    ///    durable ops while it is set, and
    ///    `AccountManager.newGestureRefusedForUnknownEpoch` refuses new ones.
    ///
    /// The value is a `Date` for diagnostics ("how long has this folder been
    /// quarantined") and to keep the shape identical to the reference's; nothing
    /// compares it. `v2final`'s companion column `lastUidValidityResetAt` is
    /// deliberately NOT ported — its sole purpose there is to be the monotonic
    /// authority sidecar producers compare against, and v3 has no such producer.
    var uidValidityResetPendingAt: Date?
    /// IMAP CONDSTORE (RFC 7162): last observed HIGHESTMODSEQ — the flag-aware
    /// change cursor for delta/full sync. When `uidNext`+`totalCount` are unchanged
    /// but this bumped, a \Seen/flag change happened on an EXISTING message (which
    /// STATUS-count-only detection misses today). Only comparable WITHIN one
    /// UIDVALIDITY epoch. It is NOT reset merely on OBSERVING a mismatch: such a
    /// rule would re-fire every cycle for as long as the stored epoch stayed behind
    /// and destroy the CONDSTORE signal for that folder permanently. It IS cleared,
    /// once, by the epoch-advancement protocol T4.S6 added —
    /// `AccountManager.uidValidityResetPurgeTxn` nulls it in the same transaction
    /// that deletes the folder's headers, i.e. only where the whole local population
    /// is being rebuilt anyway. Nor does the epoch gate the
    /// CONDSTORE fetch-SKIP: forcing a fetch across a turnover hands the folder to
    /// `runSyncMessages`, whose stale sweep had no epoch guard when this was written
    /// (T4.S6 has since added one, which ABANDONS the pass rather than widening it),
    /// so "fetch more" is the DESTRUCTIVE direction there, not the safe one. A turnover moves
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
