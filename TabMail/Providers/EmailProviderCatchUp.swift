/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// MARK: - Catch-up of older mail (ADR-IOS-107)
//
// The provider-blind seam through which a full-sync pass learns about server-side
// changes to mail no other sync path looks at again: a read or flag change, or a
// removal, on a message older than every sync window. The full sync calls
// `EmailProvider.catchUp` ONCE per pass with all of the pass's syncable folders and
// applies whatever comes back through its existing paths. Everything provider-specific
// (whether a folder needs a listing, how a listing resumes, what proves a removal)
// lives below this seam, encoded in an opaque per-folder state string only the
// provider reads.

/// One local row as `CatchUpLocalRowReader` returns it: the provider id and the two
/// flags the catch-up compares. Never message content (ADR-004).
struct CatchUpLocalRow: Sendable, Equatable {
    /// `MessageHeader.messageId` — the UID as a string for IMAP, the provider's own
    /// message id elsewhere.
    let messageId: String
    let isRead: Bool
    let isFlagged: Bool
    /// `MessageHeader.providerDate`, the key the provider orders and windows by.
    /// Set only by the order-date accessor; nil from the others.
    var orderDate: Date? = nil
}

/// Read access to a folder's local rows, by range, so a provider can compare a
/// listing against them a slice at a time instead of loading a whole folder.
protocol CatchUpLocalRowReader: Sendable {
    /// Rows whose id, read as an integer, lies in `lower...upper`, ascending by
    /// that integer (IMAP: a UID range).
    func rows(folderId: String, numericIdsFrom lower: Int, through upper: Int) async throws -> [CatchUpLocalRow]
    /// The smallest id, read as an integer, that is `>= lower`, or nil when none is.
    func firstNumericId(folderId: String, atLeast lower: Int) async throws -> Int?
    /// Rows for exactly these provider ids. Ids with no local row are absent.
    func rows(folderId: String, ids: [String]) async throws -> [CatchUpLocalRow]
    /// Up to `limit` rows in ascending provider-id order, after `afterId`
    /// (nil starts at the beginning) — an ordered scan of the whole folder.
    func rows(folderId: String, after afterId: String?, limit: Int) async throws -> [CatchUpLocalRow]
    /// Every row whose provider order date (`MessageHeader.providerDate`) is at or
    /// after `lower` and before `upper`, ascending by that date and then by id.
    /// Each row carries its `orderDate`. For a provider that windows by date.
    func rows(folderId: String, orderDatesFrom lower: Date, before upper: Date) async throws -> [CatchUpLocalRow]
    /// The newest `limit` rows whose provider order date is before `upper` (nil: no
    /// upper bound), descending by that date and then by id. Each row carries its
    /// `orderDate`. For a provider that lists a folder newest first.
    func newestRows(folderId: String, orderDatesBefore upper: Date?, limit: Int) async throws -> [CatchUpLocalRow]
}

/// What one catch-up call may spend and on what kind of network. A value snapshot
/// taken by the caller at the start of the operation (root rule: snapshot settings
/// at operation start); neither the provider nor the apply re-reads the network
/// state or the storage limit itself.
struct CatchUpContext: Sendable {
    /// `NetworkMonitor.checkExpensive()` as it stood when the pass began.
    let isExpensiveNetwork: Bool
    /// No request may START at or after this instant.
    let deadline: Date
    /// The clock the budget is measured on. Injectable so a test can spend the
    /// budget deterministically; production passes `Date.init`.
    let clock: @Sendable () -> Date
    /// Whether the user's Email Index Limit (`StorageEstimator.budgetMB`) was a
    /// finite limit when the pass began. The limit means old mail is not kept:
    /// the storage prune deletes the oldest rows once the store passes it
    /// (ADR-IOS-006). So while it holds, no catch-up loads old mail back: the
    /// apply re-arms no backfill walk, and a provider lists no mail older than the
    /// folder's oldest local row (ADR-IOS-107 decision 8).
    var storageLimitInForce = false

    /// The production snapshot: the budget starts now.
    static func forPass(isExpensiveNetwork: Bool, storageLimitInForce: Bool) -> CatchUpContext {
        let now = Date()
        return CatchUpContext(
            isExpensiveNetwork: isExpensiveNetwork,
            deadline: now.addingTimeInterval(SyncConfig.catchUpPassBudgetSeconds),
            clock: { Date() },
            storageLimitInForce: storageLimitInForce)
    }

    /// Checked before EVERY request: false once the pass budget is spent.
    func hasBudget() -> Bool { clock() < deadline }
}

/// A read/flag state the server reported for one existing message.
struct CatchUpFlagUpdate: Sendable, Equatable {
    let messageId: String
    let isRead: Bool
    let isFlagged: Bool
}

/// The provider-blind result for one folder. The full sync applies it in one write
/// transaction together with `newState`.
struct CatchUpFolderResult: Sendable {
    let folderId: String
    /// The id epoch every id below belongs to (IMAP: the UIDVALIDITY of the SELECTs
    /// that produced them), or nil for a provider whose ids carry no epoch. The full
    /// sync applies nothing unless this equals the folder's stored known epoch; a
    /// result whose epoch DIFFERS from a known stored one reports a turnover.
    let epoch: UInt32?
    /// Changes to rows the device already holds. There is no field for a message
    /// without a local row: the catch-up never inserts (ADR-IOS-107).
    var flagUpdates: [CatchUpFlagUpdate] = []
    /// Provider ids the server has PROVEN absent. They go through the one removal
    /// path (`SyncEngine.deleteConfirmedGhostHeaders`).
    var removedIds: [String] = []
    /// The folder's new opaque state, written in the same transaction as the
    /// results. Nil clears it.
    var newState: String?
    /// Re-arm the folder's existing backfill walk (`backfillComplete = false`,
    /// `backfillPageToken = NULL`) in the same transaction: the server lists a
    /// message in the folder that the device holds no row for (an old message
    /// moved into the folder). The catch-up itself never inserts; the
    /// backfill, which only inserts, loads it. The apply re-arms only a folder
    /// whose walk is COMPLETE, read inside its own transaction: a check never
    /// restarts an unfinished walk, which would throw away its position. It
    /// re-arms nothing while a storage limit is in force
    /// (`CatchUpContext.storageLimitInForce`): the missing mail may be what the
    /// storage prune deleted, and loading it back would only be pruned again.
    var rearmBackfill = false
}

/// The delta-cursor lapse marker every provider's catch-up state may carry
/// (ADR-IOS-107). A lapse (`SyncEngine.lapseDeltaCursor`) never clears a folder's
/// state: it adds one to the integer under `countKey` in the state's JSON object,
/// and leaves a NULL state NULL (a folder with no state is due for a full check
/// anyway). The provider decides what a lapse means for its folders; Gmail starts
/// a new listing as soon as the one in progress completes. A state that is not a
/// JSON object becomes NULL. A provider whose state ignores the key loses it at
/// its next write, which is harmless for a provider that has no delta cursor.
enum CatchUpLapse {
    /// The key of the lapse count in a state's JSON object.
    static let countKey = "lapseCount"
}

/// The time rules every provider's catch-up shares: when a folder's full check is
/// due, and whether an expensive network may still hold it back.
enum CatchUpSchedule {
    /// True when the folder has never completed a listing, or its last one
    /// completed at least `interval` ago. Each provider passes its own interval
    /// from `SyncConfig`, below the provider boundary.
    static func fullCheckDue(lastCompletedAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastCompletedAt else { return true }
        return now.timeIntervalSince(lastCompletedAt) >= interval
    }

    /// True when a folder WITH a state has waited for a non-expensive network for
    /// at least `SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds`, counted from its
    /// last completed listing or, before the first, from `createdAt`. A folder with
    /// no state has not started waiting.
    static func waitedTooLong(hasState: Bool, lastCompletedAt: Date?, createdAt: Date?, now: Date) -> Bool {
        guard hasState else { return false }
        guard let since = lastCompletedAt ?? createdAt else { return true }
        return now.timeIntervalSince(since) >= SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds
    }

    /// `folders` in the order a pass works them: never-tried first, then by the
    /// last try (a completion is a try), so a folder whose requests keep failing
    /// goes behind the others and cannot hold their catch-up past its bound.
    /// Stable on the caller's order for ties.
    static func leastRecentlyAttemptedFirst(_ folders: [Folder], lastAttemptAt: (Folder) -> Date?) -> [Folder] {
        folders.enumerated().sorted { lhs, rhs in
            let l = lastAttemptAt(lhs.element) ?? .distantPast, r = lastAttemptAt(rhs.element) ?? .distantPast
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }
}

extension EmailProvider {
    /// Default: no catch-up. A provider without support (Exchange and Demo until
    /// their own catch-up lands) returns nothing, and the full sync then writes
    /// nothing.
    func catchUp(
        folders: [Folder], localRows: any CatchUpLocalRowReader, context: CatchUpContext
    ) async -> [CatchUpFolderResult] {
        []
    }
}
