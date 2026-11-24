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
    /// Up to `limit` rows whose id, read as an integer, is below `upper`,
    /// descending by that integer (IMAP: the newest UIDs below a bound; never
    /// by date).
    func rows(folderId: String, numericIdsBelow upper: Int, limit: Int) async throws -> [CatchUpLocalRow]
    /// The smallest id, read as an integer, that is `>= lower`, or nil when none is.
    func firstNumericId(folderId: String, atLeast lower: Int) async throws -> Int?
    /// The largest id, read as an integer, or nil when the folder holds none.
    func lastNumericId(folderId: String) async throws -> Int?
    /// Rows for exactly these provider ids. Ids with no local row are absent.
    func rows(folderId: String, ids: [String]) async throws -> [CatchUpLocalRow]
    /// Every row whose provider order date (`MessageHeader.providerDate`) is at or
    /// after `lower` and before `upper`, ascending by that date and then by id.
    /// Each row carries its `orderDate`. For a provider that windows by date.
    func rows(folderId: String, orderDatesFrom lower: Date, before upper: Date) async throws -> [CatchUpLocalRow]
    /// The newest `limit` rows whose provider order date is before `upper` (nil: no
    /// upper bound), descending by that date and then by id. Each row carries its
    /// `orderDate`. For a provider that lists a folder newest first.
    func newestRows(folderId: String, orderDatesBefore upper: Date?, limit: Int) async throws -> [CatchUpLocalRow]
}

/// What one catch-up call (one slice) may spend. Its storage-limit flag comes from
/// the run's snapshot, taken when the run started (`SyncEngine.CatchUpRun`; root
/// rule: snapshot settings at operation start); neither the provider nor the apply
/// re-reads the storage limit itself. A scan reads no download gate (#1063).
struct CatchUpContext: Sendable {
    /// No request may START at or after this instant.
    let deadline: Date
    /// The clock the budget is measured on. Injectable so a test can spend the
    /// budget deterministically; production passes `Date.init`.
    let clock: @Sendable () -> Date
    /// Whether the user's Email Index Limit (`StorageEstimator.budgetMB`) was a
    /// finite limit when the run began. The limit means old mail is not kept:
    /// the storage prune deletes the oldest rows once the store passes it
    /// (ADR-IOS-006). So while it holds, a UID-windowed provider loads nothing
    /// at or below the folder's prune cutoff of its epoch (`CatchUpPruneCutoff`),
    /// and still reconciles local rows below it; a date-windowed one lists no
    /// mail older than the folder's oldest local row (ADR-IOS-107 decision 8).
    /// Above the cutoff, mail a prune removed can load again ONCE, within the
    /// limit and stamped: a gap a date-ordered prune left above a seeded cutoff,
    /// or a deleted row that carried no epoch stamp (the floor rule,
    /// ADR-IOS-006).
    /// *Superseded (#1062):* "a provider loads nothing the prune removed",
    /// which the cutoff cannot promise for those two cases.
    /// *Superseded (#1062):* "a provider lists no mail older than the folder's
    /// oldest local row, and so loads none back", for every provider.
    var storageLimitInForce = false
    /// Most requests this call may send (`SyncConfig.catchUpSliceMaxRequests` for a
    /// slice of the backfill worker's catch-up). `Int.max` bounds it by time only.
    var maxRequests = Int.max
    /// About how many messages one listing range holds where the provider sizes
    /// its ranges by message count (IMAP, `SyncConfig.catchUpListingRangeMessages`).
    /// A test narrows it to list a small folder in several ranges.
    var listingRangeMessages = SyncConfig.catchUpListingRangeMessages
    /// Longest one catch-up request may take (`SyncConfig.catchUpRequestTimeoutSeconds`).
    /// A test shortens it to time a request out without waiting seconds.
    var requestTimeoutSeconds = SyncConfig.catchUpRequestTimeoutSeconds
    /// Requests charged so far, shared by every copy of this context.
    private let charged = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Whether the call may go on: time is left and the request count is not
    /// spent. Charges nothing; a provider asks it before starting a folder.
    /// *Superseded:* "Checked before EVERY request: false once the slice is spent"
    /// (now `hasBudget(cost:)`, which also counts).
    func hasBudget() -> Bool {
        clock() < deadline && charged.withLock { $0 < maxRequests }
    }

    /// Requests this call may still send by its count (`maxRequests`).
    var requestsLeft: Int { charged.withLock { max(0, maxRequests - $0) } }

    /// Checked before EVERY request, with `cost` the requests about to be sent (the
    /// whole width of a batch of concurrent loads). True, and `cost` charged,
    /// only when time is left and the count stays within `maxRequests`; false
    /// otherwise, and nothing is charged.
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
    /// Messages the provider fetched, with their bodies (IMAP: header only), for ids the server lists
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
    /// still held). The backfill worker
    /// runs another slice only after one in which an applied result made progress,
    /// or in which a folder first left a request in flight (#1062),
    /// so a folder whose requests keep failing is tried again at the worker's next
    /// cycle, never at network rate (#766). A foreground cycle takes one slice
    /// whatever it made.
    /// *Superseded (#1062, in place):* "The progress of a folder whose call left a
    /// request in flight (`requestMayBeInFlight`) does not count toward another
    /// slice": the slice that adds such a folder takes another for that reason.
    /// *Superseded (#1062):* "runs another slice only after one in which an
    /// applied result made progress": a slice whose only progress came from a
    /// folder left out from then on also takes one more, so the folders still
    /// asked go on.
    var madeProgress = false
    /// A request of this call may still be in flight (#1062): the provider
    /// stopped waiting for it. A request that was on the wire ended the
    /// folder's session when abandoned (IMAP: a cancelled command closes its
    /// connection's session at once), so another request to the folder now
    /// would first open a new session on the link that just timed out. A
    /// timeout can also fire while the request still waits for a connection
    /// (the folder's, or pool capacity), before any command is sent; it is
    /// reported the same way. The backfill worker's run never asks this
    /// folder again, whatever progress the call made, and goes on with its other
    /// folders (`SyncEngine.runCatchUpRun`). Independent of `madeProgress`: the
    /// state the call saved (a listing that moved, a top it learned) is kept as
    /// it is. A provider with no per-folder session for an abandoned request to
    /// end leaves it false.
    /// *Superseded (#1062):* "it can hold the folder's connection until its late
    /// answer, so another request to the folder now would wait behind it or
    /// force a new session" and "a provider whose abandoned requests hold no
    /// folder connection": nothing waits for the late answer.
    var requestMayBeInFlight = false
    /// Set only in the call in which a listing of the folder completed (#1062):
    /// the lapse count it started at, and whether it was clean. The apply clears
    /// a folder's owed check with it. A provider may leave it nil.
    var completedListing: CatchUpCompletedListing?
}

/// A completed listing, as `CatchUpFolderResult.completedListing` reports it.
struct CatchUpCompletedListing: Sendable, Equatable {
    /// The folder's lapse count (`CatchUpLapse.countKey`) when the listing started.
    let lapseCountAtStart: Int
    /// Every missing message in the listed range was loaded or proven gone:
    /// none was passed over by the hold bound. An IMAP listing with no load
    /// floor of the folder's epoch and no local row read nothing from the
    /// server and is not clean; one whose mailbox the server reports empty is.
    /// So an owed folder that is empty, before its older-mail walk starts,
    /// stays owed until a window listing records a floor (an empty window names
    /// no UID) or the walk starts; it costs no catch-up request. A listing with
    /// no load floor but local rows reconciles those rows, loads nothing, and
    /// is clean: what is missing there is the walk's and scrolling's to load.
    /// *Superseded (#1062):* "and there was a range to list", which read as if
    /// an empty mailbox could never complete clean.
    let clean: Bool
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

    /// The lapse count recorded in `state`, read from the raw JSON, so a state
    /// a provider cannot decode (a floor-only state, another epoch) still gives
    /// a listing its start count (#1062). Nil when none is recorded.
    static func read(_ state: String?) -> Int? {
        guard let data = state?.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (object[countKey] as? NSNumber)?.intValue
    }
}

/// Loads the engine dropped from a listing in progress (#1062): an apply whose
/// read was over-age (`CatchUpReadLatch`) moved the listing past messages it did
/// not insert. The engine sets this key to `true` in the state's JSON object; a
/// provider carries it while the listing runs, reports the listing's completion
/// unclean (`CatchUpCompletedListing.clean` false) when it is set, and clears it
/// when the listing completes. Provider-neutral, like `CatchUpLapse.countKey`.
enum CatchUpSkippedLoads {
    /// The key of the flag in a state's JSON object.
    static let key = "skippedLoads"
}

/// The lowest id a window listing of the folder has named, with the epoch it
/// belongs to, for a provider that windows by UID (#1062). The full sync's window
/// merge (`SyncEngine.recordCatchUpWindowFloor`) keeps it under `key` in the
/// folder's catch-up state JSON, only under a known epoch: the lowest value any
/// window listing named in that epoch (a value of another epoch is replaced).
/// The catch-up apply carries it across its own state writes, and a turnover
/// clears it with the state. Rows other paths write (infinite scroll pages by
/// date) never move it. Before the older-mail walk starts, a catch-up loads
/// missing mail only from here up: new mail beyond the window is the catch-up's,
/// older mail is the walk's. Read only when its epoch is the folder's, so a floor
/// never outlives a renumbering it was not learned under.
/// *Superseded (#1062):* a bare number with no epoch, which a path that clears
/// the folder's epoch but keeps its state could carry into the next numbering.
enum CatchUpWindowFloor {
    /// The key of the floor in a state's JSON object: an object holding `uid`
    /// and `epoch`.
    static let key = "windowFloor"

    /// The floor recorded in `state` for `epoch`, or nil when none is (no window
    /// listing recorded one in that epoch, or the state is not a JSON object).
    static func read(_ state: String?, epoch: Int) -> Int? {
        CatchUpEpochValue.read(state, key: key, epoch: epoch)
    }
}

/// A UID stored with the epoch it was learned under, as an object `{uid, epoch}`
/// under one key of a folder's catch-up state JSON (#1062): the shape of every
/// floor and cutoff the catch-up keeps. A value of another epoch reads as absent.
enum CatchUpEpochValue {
    static func read(_ state: String?, key: String, epoch: Int) -> Int? {
        guard let data = state?.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = object[key] as? [String: Any],
              (value["epoch"] as? NSNumber)?.intValue == epoch else { return nil }
        return (value["uid"] as? NSNumber)?.intValue
    }
}

/// The highest id the storage prune removed from the folder, with the epoch it
/// belongs to, for a provider that windows by UID (#1062). It is the ONLY record
/// of what was pruned. The prune (`SyncEngine.runPruneIfOverBudget`) deletes such
/// a folder lowest UID first and records it under `key` in the folder's catch-up
/// state JSON, in the transaction that deletes the rows, from the rows that
/// transaction deleted and that belonged to the folder in its current epoch: the
/// highest value pruned in that epoch (a value of another epoch is replaced).
/// Once, under a storage limit, a folder with local rows and no cutoff in its
/// epoch gets one from the catch-up slice (`SyncEngine.seedCatchUpPruneCutoffs`):
/// released versions pruned without recording it. The catch-up apply carries it
/// across its own state writes, and a turnover clears it with the state. Under a
/// storage limit a catch-up loads nothing at or below it, a never-local UID
/// included (the UID-ordered prune would have deleted it first); the first local
/// UID is no evidence of what was pruned (a cached scroll page sits below the
/// pruned UIDs, an unreadable window UID below the first local one). A seeded
/// value is an inference, and a deleted row with no epoch stamp never raises
/// it, so mail above it that was pruned may load once more, stamped, for the
/// next prune to count. The walk's empty-folder recovery keeps it with the
/// state; it is inert there, read only when its epoch is the folder's.
enum CatchUpPruneCutoff {
    /// The key of the cutoff in a state's JSON object: an object holding `uid`
    /// and `epoch`.
    static let key = "pruneCutoff"

    /// The cutoff recorded in `state` for `epoch`, or nil when none is (nothing
    /// pruned yet, one of another epoch, or the state is not a JSON object).
    static func read(_ state: String?, epoch: Int) -> Int? {
        CatchUpEpochValue.read(state, key: key, epoch: epoch)
    }
}

/// The time rules every provider's catch-up shares: when a folder's full check is
/// due, and the order folders are worked in.
enum CatchUpSchedule {
    /// True when the folder has never completed a listing, or its last one
    /// completed at least `interval` ago. A provider with a periodic check passes
    /// its own interval from `SyncConfig`, below the provider boundary (IMAP:
    /// daily). Gmail has no periodic check (`GmailProvider.catchUpPlan`).
    static func fullCheckDue(lastCompletedAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastCompletedAt else { return true }
        return now.timeIntervalSince(lastCompletedAt) >= interval
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
