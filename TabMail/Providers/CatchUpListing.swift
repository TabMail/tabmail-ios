/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import os

// MARK: - Listing by provider-date ranges, and the direct load (ADR-IOS-107)
//
// The pieces every catch-up that lists a folder newest first, in ranges cut from
// its local rows, shares below the seam: the range cut, whether a new listing
// reaches the epoch, and the direct load (a message the server lists in the folder
// that no local row holds is fetched with its body and handed to the apply, which
// inserts it through the backfill page walk's own insert tail), with the page
// hold that bounds a load that keeps failing. Gmail and Outlook use them. Nothing
// here names a provider: the fetch is passed in.

/// One listing range, in whole epoch seconds. Ranges tile the folder's local
/// range without gaps, newest first: each ends where the previous (newer) one
/// started.
struct CatchUpRange: Codable, Equatable, Sendable {
    /// Where the range starts (inclusive): the next (older) range ends here.
    /// The oldest range of a listing that reaches the epoch starts at 0.
    let from: Int
    /// The second of the range's oldest local row (`>= from`). The stretch
    /// before it held no local row when the range was cut.
    let firstLocal: Int
    /// One past the second of the range's newest local row (`<= upTo`). The
    /// stretch from it to `upTo` held no local row when the range was cut.
    let localEnd: Int
    /// Where the range ends (exclusive): the previous (newer) range's start,
    /// or the first range's `localEnd`.
    let upTo: Int

    /// The range ending just before `nextBeforeSecond` (nil: just after the newest
    /// local row), given the order dates of the newest local rows before it
    /// (`head`, descending, non-empty, at most `rowLimit + 1` of them). The range
    /// holds at most `rowLimit` rows unless more than that share its newest
    /// second, starts on a whole second (rows sharing the cut second go to the
    /// next range), and its local rows span at most `maxSpanSeconds` (nil: no
    /// span cap). When it holds every remaining row and `toEpoch` is set, it
    /// starts at 0.
    nonisolated static func cut(
        nextBeforeSecond: Int?, head: [Date], rowLimit: Int, maxSpanSeconds: Int?, toEpoch: Bool
    ) -> CatchUpRange {
        let second = { (date: Date) in Int(date.timeIntervalSince1970.rounded(.down)) }
        let seconds = head.map(second)
        let newest = seconds[0]
        let localEnd = newest + 1
        var from: Int
        var holdsTheRest: Bool
        if seconds.count > rowLimit {
            from = min(seconds[rowLimit] + 1, newest)
            holdsTheRest = false
        } else {
            from = seconds[seconds.count - 1]
            holdsTheRest = true
        }
        if let maxSpanSeconds, from < localEnd - maxSpanSeconds {
            from = localEnd - maxSpanSeconds
            holdsTheRest = false
        }
        let firstLocal = seconds.filter { $0 >= from }.min() ?? newest
        if holdsTheRest && toEpoch { from = min(from, 0) }
        return CatchUpRange(from: from, firstLocal: firstLocal, localEnd: localEnd, upTo: nextBeforeSecond ?? localEnd)
    }

    /// Whether a listing starting now reaches down to the epoch: only while the
    /// folder's walk is complete (an unfinished walk reaches older mail itself)
    /// and no storage limit is in force (the limit means old mail is not kept).
    nonisolated static func listsToEpoch(_ folder: Folder, context: CatchUpContext) -> Bool {
        folder.backfillComplete && !context.storageLimitInForce
    }
}

/// The direct load (ADR-IOS-107 decision 8): fetching, with their bodies, the ids
/// a listing page names that no local row in the folder holds, and deciding
/// whether the page may move on.
enum CatchUpDirectLoad {

    /// What loading one page's missing ids found.
    struct Outcome: Sendable {
        var loaded: [BackfillResult] = []
        var failures: [String: SyncEngine.BackfillFetchFailureKind] = [:]
        /// False when the budget ran out before every id was asked for.
        var complete = true
    }

    /// Fetches `ids` (in the listing's order, newest first) through `fetch` (the
    /// provider's backfill fetch: header and body in one request each),
    /// `batchSize` at a time. Each batch is charged its whole width (`charge`,
    /// which charges nothing and answers false when the width does not fit)
    /// before any of it is sent, and bounded by
    /// `SyncConfig.catchUpRequestTimeoutSeconds`, so the added hold stays the
    /// budget plus one timeout. A failed id is classified by the page walk's own
    /// rule (`SyncEngine.backfillFetchFailureKind`); an id with no answer when the
    /// timeout fires is a `hold` (no answer at all).
    static func load(
        _ ids: [String], batchSize: Int,
        charge: @Sendable (Int) -> Bool,
        fetch: @escaping @Sendable (_ ids: [String], _ concurrency: Int) async -> AsyncStream<BackfillResult>
    ) async -> Outcome {
        var load = Outcome()
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let batch = Array(ids[start..<min(start + batchSize, ids.count)])
            // The whole batch is charged before any of it is sent.
            guard charge(batch.count) else {
                load.complete = false
                break
            }
            let answered = OSAllocatedUnfairLock<[BackfillResult]>(initialState: [])
            do {
                try await withTimeout(seconds: SyncConfig.catchUpRequestTimeoutSeconds) {
                    for await result in await fetch(batch, batchSize) {
                        answered.withLock { $0.append(result) }
                    }
                }
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CatchUp] load of \(batch.count) missing id(s) stopped (\(error)) — the unanswered ones are held")
                }
            }
            let results = answered.withLock { $0 }
            for result in results {
                if result.header != nil {
                    load.loaded.append(result)
                } else {
                    load.failures[result.id] = SyncEngine.backfillFetchFailureKind(result.error)
                }
            }
            let answeredIds = Set(results.map(\.id))
            for id in batch where !answeredIds.contains(id) { load.failures[id] = .hold }
        }
        return load
    }

    /// Whether a page whose missing ids were loaded may move on.
    enum PageVerdict: Equatable, Sendable {
        /// Every missing id loaded or counts as done: the page moves on.
        case passes
        /// The budget ran out: the page is listed again on a later pass.
        case stopsOnBudget
        /// A missing id failed with a `hold` failure inside the hold bound: the
        /// page is listed and loaded again on a later pass.
        case held
    }

    /// The page hold of the direct load, on the page walk's hold clock
    /// (`SyncEngine.backfillPageHoldNow`) and bound
    /// (`SyncEngine.decideBackfillPage`, `SyncConfig.backfillPageHoldMinutes`).
    /// `heldSince` is the page's first hold, updated in place:
    /// - loads that stop on the budget after loading some: the page moved, so it
    ///   is not held, and its clock starts again at its next hold (cleared);
    /// - a `hold` failure, or loads that stopped on the budget with nothing
    ///   loaded: the clock starts (or is kept). Inside the bound the page is held;
    ///   past it the held ids and the ids not yet asked for count as done and the
    ///   page moves on;
    /// - gone or per-message failures count as done at once.
    static func pageVerdict(_ load: Outcome, heldSince: inout Date?) -> PageVerdict {
        if !load.complete && !load.loaded.isEmpty {
            heldSince = nil
            return .stopsOnBudget
        }
        if load.failures.values.contains(.hold) || !load.complete {
            let now = SyncEngine.backfillPageHoldNow()
            let firstHeld = heldSince ?? now
            heldSince = firstHeld
            if case .hold = SyncEngine.decideBackfillPage(strictestFailure: .hold, firstHeld: firstHeld, now: now) {
                return load.complete ? .held : .stopsOnBudget
            }
        }
        return .passes
    }
}
