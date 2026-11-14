/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import os

// MARK: - Catch-up of older mail (ADR-IOS-107)
//
// The provider-blind seam through which the backfill worker learns about server-side
// changes to mail no other sync path looks at again: a read or flag change, or a
// removal, on a message older than every sync window. The worker calls
// `EmailProvider.catchUp` ONCE per slice with all of the account's syncable folders
// and applies whatever comes back through the existing paths (`SyncEngine.runCatchUpRun`;
// before #766 the full sync called it once per pass). Everything provider-specific
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

/// What one catch-up call (one slice) may spend and on what kind of network. Its
/// network state and storage-limit flag come from the run's snapshot, taken when the
/// run started (`SyncEngine.CatchUpRun`; root rule: snapshot settings at operation
/// start); neither the provider nor the apply re-reads the network state or the
/// storage limit itself.
struct CatchUpContext: Sendable {
    /// `NetworkMonitor.checkExpensive()` as it stood when the run began.
    let isExpensiveNetwork: Bool
    /// No request may START at or after this instant.
    let deadline: Date
    /// The clock the budget is measured on. Injectable so a test can spend the
    /// budget deterministically; production passes `Date.init`.
    let clock: @Sendable () -> Date
    /// Whether the user's Email Index Limit (`StorageEstimator.budgetMB`) was a
    /// finite limit when the run began. The limit means old mail is not kept:
    /// the storage prune deletes the oldest rows once the store passes it
    /// (ADR-IOS-006). So while it holds, a provider lists no mail older than the
    /// folder's oldest local row, and so loads none back (ADR-IOS-107 decision 8).
    var storageLimitInForce = false
    /// Most requests this call may send (`SyncConfig.catchUpSliceMaxRequests` for a
    /// slice of the backfill worker's catch-up). `Int.max` bounds it by time only.
    var maxRequests = Int.max
    /// Requests charged so far, shared by every copy of this context.
    private let charged = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Whether the call may go on: time is left and the request count is not
    /// spent. Charges nothing; a provider asks it before starting a folder.
    /// *Superseded:* "Checked before EVERY request: false once the slice is spent"
    /// (now `hasBudget(cost:)`, which also counts).
    func hasBudget() -> Bool {
        clock() < deadline && charged.withLock { $0 < maxRequests }
    }

    /// Checked before EVERY request, with `cost` the requests about to be sent (the
    /// whole width of a batch of concurrent loads). True, and `cost` charged,
    /// only when time is left and the count stays within `maxRequests`; false
    /// otherwise, and nothing is charged.
    /// Requests this call may still send by its count (`maxRequests`).
    var requestsLeft: Int { charged.withLock { max(0, maxRequests - $0) } }

    func hasBudget(cost: Int) -> Bool {
        guard clock() < deadline else { return false }
        return charged.withLock { spent in
            guard cost <= maxRequests - spent else { return false }
            spent += cost
            return true
        }
    }
}

/// A read/flag state the server reported for one existing message.
struct CatchUpFlagUpdate: Sendable, Equatable {
    let messageId: String
    let isRead: Bool
    let isFlagged: Bool
}

/// The provider-blind result for one folder. The apply (`SyncEngine.applyCatchUpResult`)
/// writes it in one write transaction together with `newState`.
struct CatchUpFolderResult: Sendable {
    let folderId: String
    /// The id epoch every id below belongs to (IMAP: the UIDVALIDITY of the SELECTs
    /// that produced them), or nil for a provider whose ids carry no epoch. The apply
    /// writes nothing unless this equals the folder's stored known epoch; a
    /// result whose epoch DIFFERS from a known stored one reports a turnover.
    let epoch: UInt32?
    /// Changes to rows the device already holds.
    var flagUpdates: [CatchUpFlagUpdate] = []
    /// Provider ids the server has PROVEN absent. They go through the one removal
    /// path (`SyncEngine.deleteConfirmedGhostHeaders`).
    var removedIds: [String] = []
    /// The folder's new opaque state, written in the same transaction as the
    /// results. Nil clears it.
    var newState: String?
    /// Messages the provider fetched, with their bodies, for ids the server lists
    /// in the folder that no local row in the folder holds (mail moved in, or new
    /// mail beyond the sync window after a lapse). Only the ones that loaded (a
    /// header). The apply inserts them through the backfill page walk's own insert
    /// tail (`SyncEngine.insertFetchedBackfillMessages`) BEFORE it writes
    /// `newState`, so a crash between the two lists them again rather than losing
    /// them (ADR-IOS-107 decision 8, the direct load).
    var loaded: [BackfillResult] = []
    /// The missing ids that did not load, each with the page walk's own
    /// classification of its failure (`SyncEngine.backfillFetchFailureKind`).
    var loadFailures: [String: SyncEngine.BackfillFetchFailureKind] = [:]
    /// The folder's catch-up moved forward in this call: its listing advanced or
    /// completed, or it found something to apply. False when the call only recorded
    /// an attempt (a request that failed or timed out before anything moved, a page
    /// still held) or a first sight on an expensive network. The backfill worker
    /// runs another slice only after one in which an applied result made progress,
    /// so a folder whose requests keep failing is tried again at the worker's next
    /// cycle, never at network rate (#766).
    var madeProgress = false
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
    /// completed at least `interval` ago. A provider with a periodic check passes
    /// its own interval from `SyncConfig`, below the provider boundary (IMAP:
    /// daily). Gmail has no periodic check (`GmailProvider.catchUpPlan`).
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

    /// `folders` in the order a slice works them: never-tried first, then by the
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
    /// their own catch-up lands) returns nothing, and the backfill worker then writes
    /// nothing and runs no further slice.
    func catchUp(
        folders: [Folder], localRows: any CatchUpLocalRowReader, context: CatchUpContext
    ) async -> [CatchUpFolderResult] {
        []
    }
}
