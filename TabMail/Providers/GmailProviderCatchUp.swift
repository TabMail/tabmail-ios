/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import os

/// Gmail's opaque per-folder catch-up state (ADR-IOS-107), stored as JSON in
/// `Folder.catchUpState`. Only `GmailProvider` reads or writes it. Gmail ids carry
/// no epoch, so unlike IMAP's there is none here.
struct GmailCatchUpState: Codable, Equatable, Sendable {
    /// When the last listing completed. Until one has, the folder's first
    /// listing is due; after it, the expensive-network wait counts from here.
    var lastCompletedAt: Date?
    /// The listing in progress, if any.
    var listing: Listing?
    /// When the catch-up first saw the folder. Until a listing completes, the
    /// expensive-network wait is counted from here.
    var createdAt: Date?
    /// When the catch-up last tried a listing for the folder, whether or not it
    /// succeeded. Drives the order (`CatchUpSchedule.leastRecentlyAttemptedFirst`).
    var lastAttemptAt: Date?
    /// How many delta-cursor lapses the folder's state has seen. Written only by
    /// `SyncEngine.lapseDeltaCursor`, inside this JSON under
    /// `CatchUpLapse.countKey` (the property name must stay equal to it); the
    /// catch-up carries it forward unchanged.
    var lapseCount: Int?
    /// `lapseCount` as it stood when the last COMPLETED listing started.
    var listedLapseCount: Int?

    /// A lapse came after the last completed listing started (before any listing
    /// completed: any lapse at all). Changes the lost history held may sit in
    /// ranges that listing had already passed, so a new listing is due at once.
    var lapsedSinceLastListing: Bool { (lapseCount ?? 0) > (listedLapseCount ?? 0) }

    struct Listing: Codable, Equatable, Sendable {
        /// The next range ends just before this epoch second; nil starts at the
        /// folder's newest local row. Ranges go from the newest local row to the
        /// oldest, so recent mail is checked first.
        var nextBeforeSecond: Int?
        /// Whether the oldest range reaches down to the epoch, so the listing
        /// also covers mail older than every local row. Set when the listing
        /// starts: true while the folder's backfill walk is complete and no
        /// storage limit is in force (`CatchUpContext.storageLimitInForce`).
        var toEpoch = false
        /// `GmailCatchUpState.lapseCount` when this listing started.
        var lapseCountAtStart: Int?
        /// Local rows of the ranges listed so far that their listing left out and
        /// whose own answer has not come yet. Verified before the next range, so
        /// a range's lists never run again because its GETs ran out of budget.
        var pendingCandidates: [String] = []
        /// The range whose lists are in progress, if any. Each list resumes at its
        /// saved page, so a range whose lists take more than one pass's budget
        /// still completes over several passes.
        var range: RangeScan?
    }

    /// One range's lists in progress: the folder's membership list, then the
    /// account-wide unread and starred lists over the same dates, page by page.
    /// It keeps only what concerns the range's own local rows, so its size is
    /// bounded by the range's row count however long the lists are.
    struct RangeScan: Codable, Equatable, Sendable {
        enum Step: String, Codable, Sendable { case membership, unread, starred }

        let range: GmailProvider.CatchUpRange
        var step: Step = .membership
        /// The page the current list resumes at; nil is its first page.
        var pageToken: String?
        /// While the membership list runs: the range's local rows it named so far.
        var namedIds: [String] = []
        /// Once the membership list is complete: the rows it named, with their
        /// flags as the device held them then. A row whose local flags changed
        /// since (a delta, the user) gets no update from the flag lists, whose
        /// pages may be older than that change.
        var named: [NamedRow] = []
        /// The named rows the unread list named so far.
        var unreadIds: [String] = []
        /// The named rows the starred list named so far.
        var starredIds: [String] = []
        /// When a missing id of this range first failed to load with a `hold`
        /// failure (`SyncEngine.BackfillFetchFailureKind`), on the page walk's
        /// hold clock (`SyncEngine.backfillPageHoldNow`). The range is held while
        /// less than `SyncConfig.backfillPageHoldMinutes` has passed since; after
        /// that such an id counts as done, like a per-message failure. Optional,
        /// so a state saved without it decodes. It is cleared whenever the
        /// list's page moves on (its token is saved or restarted), as the walk
        /// clears its page hold time with every token write, so each held page
        /// gets its own bound; it also goes with the range when the range
        /// advances. *Superseded (2026-11-12):* "it goes with the range when the
        /// range advances" alone, which let a page that loaded cleanly keep an
        /// earlier page's clock. *Amended (2026-11-12):* loads that stop on the
        /// pass budget with nothing loaded hold the page too (the clock starts or
        /// is kept, and past the bound the page moves on), and loads that stop on
        /// the budget after loading some clear it.
        var loadHeldSince: Date?
    }

    struct NamedRow: Codable, Equatable, Sendable {
        let id: String
        let isRead: Bool
        let isFlagged: Bool
    }

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Nil for no state or an unreadable one (including another provider's). Either
    /// way the folder starts over, which can only cost a re-listing.
    static func decode(_ raw: String?) -> GmailCatchUpState? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GmailCatchUpState.self, from: data)
    }
}

extension GmailProvider {

    /// What a folder needs this pass. Pure, so the decision is testable on its own.
    enum CatchUpPlan: Equatable {
        /// Nothing: no listing is due, or an expensive network holds it back.
        case none
        /// List the folder by provider-date ranges, starting at or continuing `listing`.
        case list(GmailCatchUpState.Listing)
    }

    /// The per-folder decision. A Gmail folder is listed in exactly three cases:
    /// it continues a listing in progress (a lapse never interrupts one); it
    /// starts its first listing (no listing has completed yet, no state at all
    /// included); or it starts one when a lapse came after its last completed
    /// listing started (`GmailCatchUpState.lapsedSinceLastListing`). There is no
    /// periodic re-check: while the history cursor is valid the delta follows
    /// every folder, All Mail included, and a lapse is what loses changes. On an
    /// expensive network only
    /// once it has waited `SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds` since
    /// its last completed listing (a lapse does not restart the wait). A folder
    /// with no state on an expensive network gets `.none`; the caller writes a
    /// state carrying `createdAt` so the wait has a start.
    nonisolated static func catchUpPlan(state: GmailCatchUpState?, isExpensiveNetwork: Bool, now: Date) -> CatchUpPlan {
        let waitedTooLong = CatchUpSchedule.waitedTooLong(
            hasState: state != nil, lastCompletedAt: state?.lastCompletedAt, createdAt: state?.createdAt, now: now)
        if isExpensiveNetwork && !waitedTooLong { return .none }
        if let listing = state?.listing { return .list(listing) }
        if state?.lastCompletedAt == nil || state?.lapsedSinceLastListing == true {
            return .list(GmailCatchUpState.Listing(lapseCountAtStart: state?.lapseCount))
        }
        return .none
    }

    /// One listing range, in whole epoch seconds. Ranges tile the folder's local
    /// range without gaps, newest first: each ends where the previous (newer)
    /// one started.
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
    }

    /// The range ending just before `nextBeforeSecond` (nil: just after the newest
    /// local row), given the order dates of the newest local rows before it
    /// (`head`, descending, non-empty, at most `rowLimit + 1` of them). The range
    /// holds at most `rowLimit` rows unless more than that share its newest
    /// second, starts on a whole second (rows sharing the cut second go to the
    /// next range), and its local rows span at most `maxSpanSeconds`. When it
    /// holds every remaining row and `toEpoch` is set, it starts at 0.
    nonisolated static func catchUpRange(
        nextBeforeSecond: Int?, head: [Date], rowLimit: Int, maxSpanSeconds: Int, toEpoch: Bool
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
        if from < localEnd - maxSpanSeconds {
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
    private nonisolated static func listsToEpoch(_ folder: Folder, context: CatchUpContext) -> Bool {
        folder.backfillComplete && !context.storageLimitInForce
    }

    /// `EmailProvider.catchUp` for Gmail (ADR-IOS-107). For each folder whose
    /// listing is due (its first, or after a lapse) or in progress: a listing by
    /// provider-date ranges taken from the local rows, newest first, resuming across passes.
    /// Per range, the folder's membership list, then the account-wide `is:unread`
    /// and `is:starred` lists over the same dates (so a message moved between two
    /// requests can never get a wrong flag), each resuming at its saved page, then
    /// a `format=minimal` GET for every local row the membership list left out:
    /// only a 404 or labels that no longer place the message in the folder remove
    /// it. An id a membership page names that no local row in the folder holds is
    /// loaded at once (the direct load, `loadMissing`): the page's token moves on
    /// only once every such id has loaded or been classified done. Least recently
    /// attempted folder first; every request (every batch of concurrent loads) is
    /// preceded by a budget check and bounded by
    /// `SyncConfig.catchUpRequestTimeoutSeconds`. Read-only on the wire; never
    /// names a synthetic placeholder id. *Superseded (2026-11-12):* "never
    /// inserts"; a missing id asked the apply to re-arm the folder's backfill walk.
    func catchUp(
        folders: [Folder], localRows: any CatchUpLocalRowReader, context: CatchUpContext
    ) async -> [CatchUpFolderResult] {
        let ordered = CatchUpSchedule.leastRecentlyAttemptedFirst(folders) {
            GmailCatchUpState.decode($0.catchUpState)?.lastAttemptAt
        }
        var results: [CatchUpFolderResult] = []
        for folder in ordered {
            guard context.hasBudget() else { break }
            if let result = await catchUpFolder(folder, localRows: localRows, context: context) {
                results.append(result)
            }
        }
        return results
    }

    /// Why one range's listing stopped short.
    private enum RangeStop: Error {
        /// The pass budget is spent.
        case budget
        /// A request failed with something that is not an answer for one message
        /// (a dropped connection, a timeout, a whole-request error).
        case failure(any Error)
        /// A missing id of the range failed to load with a `hold` failure, inside
        /// the hold bound: the page is listed and loaded again on a later pass.
        /// (A page held when its loads stopped on the budget stops with `budget`.)
        case loadHeld
    }

    /// What loading one membership page's missing ids found.
    private struct MissingLoad {
        var loaded: [BackfillResult] = []
        var failures: [String: SyncEngine.BackfillFetchFailureKind] = [:]
        /// False when the budget ran out before every id was asked for.
        var complete = true
    }

    /// The direct load: fetches `ids` (in the membership list's order, newest
    /// first) through the backfill's own fetch (`fetchBackfillBatch`: header and
    /// body in one `format=full` GET each), `BackfillProfile.normal.gmailBodyConcurrency`
    /// at a time, the width the provider uses for every body fetch. Each batch is
    /// preceded by a budget check and bounded by the request timeout, so the pass's
    /// added hold stays the budget plus one timeout. A failed id is classified by
    /// the page walk's own rule (`SyncEngine.backfillFetchFailureKind`); an id with
    /// no answer when the timeout fires is a `hold` (no answer at all).
    private func loadMissing(_ ids: [String], context: CatchUpContext) async -> MissingLoad {
        var load = MissingLoad()
        let batchSize = BackfillProfile.normal.gmailBodyConcurrency
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let batch = Array(ids[start..<min(start + batchSize, ids.count)])
            // The whole batch is charged before any of it is sent.
            guard context.hasBudget(cost: batch.count) else {
                load.complete = false
                break
            }
            let answered = OSAllocatedUnfairLock<[BackfillResult]>(initialState: [])
            do {
                try await withTimeout(seconds: SyncConfig.catchUpRequestTimeoutSeconds) {
                    for await result in await self.fetchBackfillBatch(ids: batch, concurrency: batchSize) {
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

    /// One page of a list, preceded by a budget check and bounded by the request
    /// timeout.
    private func catchUpListPage(
        context: CatchUpContext, token: String?,
        page: @escaping @Sendable (_ token: String?) async throws -> (ids: [String], nextPageToken: String?)
    ) async throws(RangeStop) -> (ids: [String], nextPageToken: String?) {
        guard context.hasBudget(cost: 1) else { throw .budget }
        do {
            return try await withTimeout(seconds: SyncConfig.catchUpRequestTimeoutSeconds) {
                try await page(token)
            }
        } catch {
            throw .failure(error)
        }
    }

    /// One folder's catch-up. Nil when the folder needs nothing or is not eligible
    /// (an empty path, a quarantined folder).
    private func catchUpFolder(
        _ folder: Folder, localRows: any CatchUpLocalRowReader, context: CatchUpContext
    ) async -> CatchUpFolderResult? {
        guard !folder.path.isEmpty, folder.uidValidityResetPendingAt == nil else { return nil }

        let state = GmailCatchUpState.decode(folder.catchUpState)
        let plan = Self.catchUpPlan(state: state, isExpensiveNetwork: context.isExpensiveNetwork, now: context.clock())
        guard case .list(var listing) = plan else {
            guard state == nil else { return nil }
            // First sight of the folder, held back by the network: record when the
            // wait began. No request is made.
            var waiting = CatchUpFolderResult(folderId: folder.id, epoch: nil)
            waiting.newState = GmailCatchUpState(createdAt: context.clock()).encoded()
            return waiting
        }
        // A new listing of a folder whose walk is complete reaches down to the
        // epoch, not only to the oldest local row: a message older than every
        // local row that moved in is missing too, and the listing loads it. An
        // unfinished walk reaches that mail itself. Under a storage limit the
        // oldest local row is where kept mail ends, so the listing stops there.
        if state?.listing == nil { listing.toEpoch = Self.listsToEpoch(folder, context: context) }

        var result = CatchUpFolderResult(folderId: folder.id, epoch: nil)
        var newState = state ?? GmailCatchUpState(createdAt: context.clock())
        let path = folder.path
        let rowLimit = SyncConfig.catchUpGmailRangeRowLimit
        let slack = SyncConfig.catchUpGmailRangeSlackSeconds
        let pageSize = SyncConfig.catchUpGmailListPageSize
        // The listing covered the folder and no new one started after it.
        var listingDone = false
        // Ids this pass loaded. They are inserted only after the pass returns,
        // so the local rows do not hold them yet; they count as held, so an id
        // listed again in the same pass (a listing restarted after a lapse, a
        // list restarted after a `400`, the slack where two ranges meet) is
        // never loaded twice.
        var loadedThisPass = Set<String>()

        rangeLoop: while true {
            // A row the listing left out is only a candidate: its own answer
            // decides. Gone (404/410), or labels that no longer place it in the
            // folder, removes it; any other answer keeps it. Without the budget, or
            // on a failure that is no answer, the rest wait in the state for the
            // next pass.
            while let id = listing.pendingCandidates.first {
                guard context.hasBudget(cost: 1) else { break rangeLoop }
                let labels: [String]?
                do {
                    labels = try await withTimeout(seconds: SyncConfig.catchUpRequestTimeoutSeconds) {
                        try await self.fetchMessageLabelIds(id: id)
                    }
                } catch where Self.isUnreadableAnswerForOneMessage(error) {
                    listing.pendingCandidates.removeFirst()
                    continue
                } catch {
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[CatchUp] \(path): GET \(id) failed (\(error)) — stopping this folder for the pass")
                    }
                    break rangeLoop
                }
                listing.pendingCandidates.removeFirst()
                // The labels prove a removal only when they no longer place the
                // message in the folder (the one All Mail membership rule).
                if let labels, Self.folder(path, containsMessageWithLabels: labels) { continue }
                result.removedIds.append(id)
            }

            // The range whose lists are in progress, or the next older one: from
            // the local rows, never past them.
            if listing.range == nil {
                do {
                    let upper = listing.nextBeforeSecond.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    let head = try await localRows.newestRows(folderId: folder.id, orderDatesBefore: upper, limit: rowLimit + 1)
                    let headDates = head.compactMap(\.orderDate)
                    guard !headDates.isEmpty, headDates.count == head.count else {
                        guard head.isEmpty else { break rangeLoop }
                        // The listing covered the folder; every missing id it found
                        // has loaded or been classified done, range by range. What
                        // leaves an id missing: mail moved in from elsewhere that no
                        // delta brought (a lapse), new mail beyond the sync window
                        // after a lapse, and a fetch that failed during the walk
                        // (the walk passes over an id whose GET fails about the
                        // message itself, or keeps failing past the page hold
                        // bound). *Superseded (2026-11-12):* a completed listing
                        // that found a missing id asked the apply to re-arm the
                        // folder's backfill walk, declined while the walk was
                        // unfinished or a storage limit was in force.
                        newState.lastCompletedAt = context.clock()
                        newState.listedLapseCount = listing.lapseCountAtStart
                        guard newState.lapsedSinceLastListing, !context.isExpensiveNetwork else {
                            listingDone = true
                            break rangeLoop
                        }
                        // A lapse came after this listing started, so a change the
                        // lost history held may sit in a range it had already
                        // listed: a new listing starts at once, newest first. On an
                        // expensive network it waits instead, like every listing,
                        // for `SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds`
                        // after this completion (`catchUpPlan`).
                        listing = GmailCatchUpState.Listing(
                            toEpoch: Self.listsToEpoch(folder, context: context), lapseCountAtStart: newState.lapseCount)
                        continue rangeLoop
                    }
                    listing.range = GmailCatchUpState.RangeScan(range: Self.catchUpRange(
                        nextBeforeSecond: listing.nextBeforeSecond, head: headDates,
                        rowLimit: rowLimit, maxSpanSeconds: SyncConfig.catchUpGmailRangeMaxSpanSeconds,
                        toEpoch: listing.toEpoch))
                } catch {
                    break rangeLoop
                }
            }
            guard var scan = listing.range else { break rangeLoop }
            let range = scan.range

            // The range's rows as the device holds them now. More than `rowLimit`
            // rows only when more than that share the range's newest second.
            let rangeRows: [CatchUpLocalRow]
            do {
                rangeRows = try await localRows.rows(
                    folderId: folder.id,
                    orderDatesFrom: Date(timeIntervalSince1970: TimeInterval(range.from)),
                    before: Date(timeIntervalSince1970: TimeInterval(range.upTo)))
            } catch {
                break rangeLoop
            }
            let rangeRowsById = Dictionary(rangeRows.map { ($0.messageId, $0) }, uniquingKeysWith: { first, _ in first })

            // Never before the epoch: a range from 0 has no slack below it. The
            // flag lists cover only the stretch the range's local rows held when
            // it was cut, so a sparse folder never asks for the account's flags
            // over a long empty stretch.
            let membershipWindow = ListWindow(after: max(0, range.from - slack), before: range.upTo + slack)
            let flagWindow = ListWindow(after: range.firstLocal - slack, before: range.localEnd + slack)
            var listsComplete = false
            // The lists of this range that started over in this pass after a
            // `400`. In memory only: each pass may start a list over once, so a
            // token that a later pass finds refused again never stalls the list.
            var restartedThisPass = Set<GmailCatchUpState.RangeScan.Step>()
            do {
                while !listsComplete {
                    let step = scan.step
                    let page: (ids: [String], nextPageToken: String?)
                    do {
                        page = try await catchUpListPage(context: context, token: scan.pageToken) { token in
                            switch step {
                            case .membership:
                                return try await self.listMessageIdsPage(folder: path, pageToken: token, pageSize: pageSize, window: membershipWindow)
                            case .unread:
                                return try await self.listAccountMessageIdsPage(search: "is:unread", window: flagWindow, pageToken: token, pageSize: pageSize)
                            case .starred:
                                return try await self.listAccountMessageIdsPage(search: "is:starred", window: flagWindow, pageToken: token, pageSize: pageSize)
                            }
                        }
                    } catch RangeStop.failure(let error) where scan.pageToken != nil && !restartedThisPass.contains(step) {
                        // Any `400` to a request carrying a saved page token: Gmail
                        // documents no wording for a token it no longer accepts, so
                        // this list starts again from the range's start, its pages
                        // so far dropped. Once per list per pass: a second `400`
                        // in the same pass stops it like any other failure.
                        guard let reason = Self.badRequestReason(error) else { throw RangeStop.failure(error) }
                        if DebugModeManager.isLoggingEnabled() {
                            BackgroundSyncLogger.logDebug("[CatchUp] \(step.rawValue) list: HTTP 400 (\(reason)) on a saved page token — restarting that list once")
                        }
                        scan.pageToken = nil
                        scan.loadHeldSince = nil
                        restartedThisPass.insert(step)
                        switch step {
                        case .membership: scan.namedIds = []
                        case .unread: scan.unreadIds = []
                        case .starred: scan.starredIds = []
                        }
                        listing.range = scan
                        continue
                    }

                    switch step {
                    case .membership:
                        // Server ids in the range with no local row in the folder
                        // (mail moved in, or new mail past the sync window after a
                        // lapse) are loaded now, before the page's token moves on.
                        let unseen = page.ids.filter {
                            rangeRowsById[$0] == nil && !loadedThisPass.contains($0) && !isSyntheticPlaceholderId($0)
                        }
                        var held = Set<String>()
                        if !unseen.isEmpty {
                            do {
                                held = Set(try await localRows.rows(folderId: folder.id, ids: unseen).map(\.messageId))
                            } catch {
                                throw RangeStop.failure(error)
                            }
                        }
                        let missing = unseen.filter { !held.contains($0) }
                        if !missing.isEmpty {
                            let load = await loadMissing(missing, context: context)
                            result.loaded += load.loaded
                            loadedThisPass.formUnion(load.loaded.map(\.id))
                            result.loadFailures.merge(load.failures) { _, latest in latest }
                            // Out of budget part way after loading some of the
                            // page's ids: the page is listed again on the next pass,
                            // where what loaded is no longer missing. It moved, so it
                            // is not held, and its hold clock starts again at its
                            // next hold: a page whose loads keep moving is never
                            // passed over for an earlier hold.
                            if !load.complete && !load.loaded.isEmpty {
                                scan.loadHeldSince = nil
                                listing.range = scan
                                throw RangeStop.budget
                            }
                            // The page is held: a `hold` failure (a transient error,
                            // or no answer within the timeout), as it holds the walk's
                            // page, or loads that stopped on the budget with nothing
                            // loaded (every id asked for held, or a slow link where
                            // the list alone spent the budget and none was asked
                            // for). Inside the bound the page is listed and loaded
                            // again later; past it the held ids and the ids not yet
                            // asked for count as done and the page moves on. Gone or
                            // per-message failures count as done at once.
                            // *Superseded (2026-11-12):* the budget stop came first,
                            // so a page whose loads always ran out of budget never
                            // started the clock and was listed again forever.
                            if load.failures.values.contains(.hold) || !load.complete {
                                let now = SyncEngine.backfillPageHoldNow()
                                let firstHeld = scan.loadHeldSince ?? now
                                scan.loadHeldSince = firstHeld
                                if case .hold = SyncEngine.decideBackfillPage(strictestFailure: .hold, firstHeld: firstHeld, now: now) {
                                    listing.range = scan
                                    throw load.complete ? RangeStop.loadHeld : RangeStop.budget
                                }
                            }
                        }
                        let namedSoFar = Set(scan.namedIds)
                        scan.namedIds += Set(page.ids.filter { rangeRowsById[$0] != nil }).subtracting(namedSoFar)
                    case .unread:
                        let named = Set(scan.named.map(\.id))
                        scan.unreadIds += page.ids.filter { named.contains($0) }
                    case .starred:
                        let named = Set(scan.named.map(\.id))
                        scan.starredIds += page.ids.filter { named.contains($0) }
                    }

                    // The page moves on, and its hold clock goes with it, as the
                    // walk clears its page hold time with every token write: a
                    // later page's first hold starts its own bound.
                    scan.pageToken = page.nextPageToken
                    scan.loadHeldSince = nil
                    if scan.pageToken == nil {
                        switch step {
                        case .membership:
                            // Local rows the listing names: their flags come from
                            // the account-wide lists over dates that hold them. Rows
                            // it leaves out are only candidates for removal, each
                            // decided by its own answer (above, from the next
                            // iteration on).
                            let named = Set(scan.namedIds)
                            let live = rangeRows.filter { !isSyntheticPlaceholderId($0.messageId) }
                            listing.pendingCandidates += live.filter { !named.contains($0.messageId) }.map(\.messageId)
                            scan.named = live.filter { named.contains($0.messageId) }.map {
                                GmailCatchUpState.NamedRow(id: $0.messageId, isRead: $0.isRead, isFlagged: $0.isFlagged)
                            }
                            scan.namedIds = []
                            scan.step = .unread
                            listsComplete = scan.named.isEmpty
                        case .unread:
                            scan.step = .starred
                        case .starred:
                            listsComplete = true
                        }
                    }
                    listing.range = scan
                }
            } catch {
                // The range's pages so far stay in the state; the next pass
                // resumes its current list at the saved page.
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CatchUp] \(path) \(range.from)..<\(range.upTo): \(scan.step.rawValue) list stopped (\(error)) — stopping this folder for the pass")
                }
                break rangeLoop
            }

            // The range's lists are complete: its flags count for every named row
            // whose local flags are what they were when the membership list
            // completed and whose date the flag lists covered, and the cursor
            // moves past it. A row dated outside the flag window (one that arrived
            // in the range's stretch before its oldest or after its newest local
            // row after the range was cut) was never asked about, so its absence
            // from them says nothing.
            let unread = Set(scan.unreadIds)
            let starred = Set(scan.starredIds)
            let flagWindowStart = Date(timeIntervalSince1970: TimeInterval(flagWindow.after))
            let flagWindowEnd = Date(timeIntervalSince1970: TimeInterval(flagWindow.before))
            for named in scan.named {
                guard let row = rangeRowsById[named.id], row.isRead == named.isRead, row.isFlagged == named.isFlagged else { continue }
                guard let orderDate = row.orderDate, orderDate >= flagWindowStart, orderDate < flagWindowEnd else { continue }
                let isRead = !unread.contains(named.id)
                let isFlagged = starred.contains(named.id)
                if isRead != row.isRead || isFlagged != row.isFlagged {
                    result.flagUpdates.append(CatchUpFlagUpdate(messageId: named.id, isRead: isRead, isFlagged: isFlagged))
                }
            }
            listing.range = nil
            listing.nextBeforeSecond = range.from
        }

        newState.lastAttemptAt = context.clock()
        newState.listing = listingDone ? nil : listing
        result.newState = newState.encoded()
        // Progress: the listing moved (a page, a range, a candidate answered, a
        // hold clock started) or completed, or something loaded or applies. A
        // request that failed before anything moved, or a page still held, is no
        // progress, so the worker does not list it again at once.
        result.madeProgress = listingDone || listing != state?.listing
            || !result.loaded.isEmpty || !result.removedIds.isEmpty || !result.flagUpdates.isEmpty
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CatchUp] \(path): flags=\(result.flagUpdates.count) removed=\(result.removedIds.count) loaded=\(result.loaded.count) failed=\(result.loadFailures.count) \(listingDone ? "listing complete" : "resumes before \(listing.nextBeforeSecond.map(String.init) ?? "the newest row")")")
        }
        return result
    }
}
