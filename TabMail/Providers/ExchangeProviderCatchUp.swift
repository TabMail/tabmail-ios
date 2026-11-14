/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import os

/// Outlook's opaque per-folder catch-up state (ADR-IOS-107), stored as JSON in
/// `Folder.catchUpState`. Only `ExchangeProvider` reads or writes it. Graph ids
/// carry no epoch. It holds ids, dates and counts only, never message content
/// (ADR-004), and never a page link or an offset: a listing resumes at a date.
struct ExchangeCatchUpState: Codable, Equatable, Sendable {
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
    /// `SyncEngine.markCatchUpLapse`, inside this JSON under
    /// `CatchUpLapse.countKey` (the property name must stay equal to it); the
    /// catch-up carries it forward unchanged.
    var lapseCount: Int?
    /// `lapseCount` as it stood when the last COMPLETED listing started.
    var listedLapseCount: Int?
    /// The catch-up saw the folder's backfill walk unfinished since the last
    /// listing started while the walk was complete. Once the walk completes, a
    /// new listing is due: the walk pages by offset, so a message deleted or
    /// moved in between two of its pages can leave a hole, and the walk passes
    /// over a message whose fetch kept failing past the page hold bound. Each
    /// hole is inside the folder's local range once the walk completes, where a
    /// listing to the epoch finds and loads it.
    var walkIncompleteSeen = false

    /// A lapse came after the last completed listing started (before any listing
    /// completed: any lapse at all). Changes the lost history held may sit in
    /// ranges that listing had already passed, so a new listing is due.
    var lapsedSinceLastListing: Bool { (lapseCount ?? 0) > (listedLapseCount ?? 0) }

    struct Listing: Codable, Equatable, Sendable {
        /// The next range ends just before this epoch second; nil starts at the
        /// folder's newest local row. Ranges go from the newest local row to the
        /// oldest, so recent mail is checked first.
        var nextBeforeSecond: Int?
        /// The folder's walk was complete when this listing started, so its oldest
        /// range may reach down to the epoch (an unfinished walk reaches older
        /// mail itself). Frozen for the listing. The storage-limit half is not
        /// saved: each run's snapshot (`CatchUpContext.storageLimitInForce`)
        /// decides it when a range is cut, so a limit turned on during a long
        /// listing holds from the next run.
        var toEpoch = false
        /// `ExchangeCatchUpState.lapseCount` when this listing started.
        var lapseCountAtStart: Int?
        /// Local rows of the ranges listed so far that the listing left out and
        /// whose own answer has not come yet. Proved before the next range is cut.
        var pendingCandidates: [String] = []
        /// When a candidate's answer first came back unusable (or not at all), on
        /// the page walk's hold clock (`SyncEngine.backfillPageHoldNow`). Cleared
        /// when no candidate is left, and when held candidates are let go past
        /// the hold bound.
        var candidateHeldSince: Date?
        /// The range being listed, if any.
        var range: RangeScan?
    }

    /// One range's listing in progress. It resumes at a date (`upperSecond`),
    /// never at a page link or an offset, so a message delivered or removed
    /// between two pages, two slices or two runs never shifts what a later page
    /// holds.
    struct RangeScan: Codable, Equatable, Sendable {
        let range: CatchUpRange
        /// The next page lists the range's messages received before this epoch
        /// second (exclusive). Starts at `range.upTo` and only goes down.
        var upperSecond: Int
        /// The local rows the range's pages named so far.
        var namedIds: [String] = []
        /// The page hold of the direct load (`CatchUpDirectLoad.pageVerdict`):
        /// when a missing id of the current page first failed with a `hold`
        /// failure. Cleared whenever the page moves on.
        var loadHeldSince: Date?
    }

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Nil for no state or an unreadable one (including another provider's).
    /// Either way the folder starts over, which can only cost a re-listing.
    static func decode(_ raw: String?) -> ExchangeCatchUpState? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExchangeCatchUpState.self, from: data)
    }
}

/// What one `ExchangeProvider.catchUp` call may send: its share of the
/// mailbox's Graph request limit (`SyncConfig.graphCatchUpRequestsPerSecond`)
/// over one slice interval, shared by every folder of the call. Each request,
/// and each batch at its full width, is charged here and against the slice's
/// own budget (`CatchUpContext.hasBudget(cost:)`) before it is sent; when
/// either does not fit, neither is charged.
struct GraphCatchUpAllowance: Sendable {
    private let context: CatchUpContext
    private let left: OSAllocatedUnfairLock<Int>

    init(context: CatchUpContext) {
        self.context = context
        let allowed = (SyncConfig.graphCatchUpRequestsPerSecond * SyncConfig.catchUpSliceIntervalSeconds).rounded(.down)
        left = OSAllocatedUnfairLock(initialState: Int(min(allowed, Double(Int.max / 2))))
    }

    /// Requests this call may still send: the fewer of this allowance's and the
    /// slice's own count.
    var requestsLeft: Int { min(left.withLock { $0 }, context.requestsLeft) }

    /// Whether the call may go on at all.
    func hasBudget() -> Bool { requestsLeft > 0 && context.hasBudget() }

    /// Charges `requests` before they are sent: true when both this allowance
    /// and the slice's budget hold them, false (and nothing charged) otherwise.
    func charge(_ requests: Int) -> Bool {
        left.withLock { remaining in
            guard requests <= remaining, context.hasBudget(cost: requests) else { return false }
            remaining -= requests
            return true
        }
    }
}

extension ExchangeProvider {

    /// What a folder needs this slice. Pure, so the decision is testable on its own.
    enum CatchUpPlan: Equatable {
        /// Nothing: no listing is due, or something holds it back.
        case none
        /// List the folder by provider-date ranges, starting at or continuing `listing`.
        case list(ExchangeCatchUpState.Listing)
    }

    /// The per-folder decision, in order:
    /// 1. on an expensive network, nothing until the folder has waited
    ///    `SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds` since its last
    ///    completed listing (or since the catch-up first saw it);
    /// 2. a listing in progress continues (a lapse never interrupts one);
    /// 3. no new listing starts while the tracking gate is closed
    ///    (`catchUpTrackingGateOpen`);
    /// 4. a new listing starts when none has completed yet, when a lapse came
    ///    after the last one started (`ExchangeCatchUpState.lapsedSinceLastListing`),
    ///    or when the walk is complete and was seen unfinished since the last
    ///    listing started (`ExchangeCatchUpState.walkIncompleteSeen`);
    /// 5. otherwise nothing: while the folder's change cursor is valid the delta
    ///    follows it, and a lapse is what loses changes.
    nonisolated static func catchUpPlan(
        state: ExchangeCatchUpState?, trackingGateOpen: Bool, walkComplete: Bool,
        isExpensiveNetwork: Bool, now: Date
    ) -> CatchUpPlan {
        let waitedTooLong = CatchUpSchedule.waitedTooLong(
            hasState: state != nil, lastCompletedAt: state?.lastCompletedAt, createdAt: state?.createdAt, now: now)
        if isExpensiveNetwork && !waitedTooLong { return .none }
        if let listing = state?.listing { return .list(listing) }
        guard trackingGateOpen else { return .none }
        if state?.lastCompletedAt == nil || state?.lapsedSinceLastListing == true
            || (walkComplete && state?.walkIncompleteSeen == true) {
            return .list(ExchangeCatchUpState.Listing(lapseCountAtStart: state?.lapseCount))
        }
        return .none
    }

    /// The tracking gate: a new listing starts only while the folder's change
    /// cursor is tracking (its delta baseline has completed). A baseline never
    /// removes a row, so a message deleted between a listing's pass over its
    /// range and the start of the folder's baseline would be reported by
    /// neither. Once the folder is tracking, every deletion is either before the
    /// listing (which sees it) or after the baseline started (whose delta
    /// reports it); the same holds for a message moved in, which tracking
    /// inserts at any age. The one place this policy lives.
    nonisolated static func catchUpTrackingGateOpen(_ folder: Folder) -> Bool {
        OutlookFolderCursor(raw: folder.changeCursor)?.phase == .tracking
    }

    /// `EmailProvider.catchUp` for Outlook (ADR-IOS-107). For each folder whose
    /// listing is due (`catchUpPlan`) or in progress: a listing by
    /// provider-date ranges cut from the local rows, newest first, resuming
    /// across slices. Each range is listed with date-filtered folder listings
    /// newest first, paged by date (never by a saved link or offset). A local
    /// row a page names whose read or flag state differs gets a flag update in
    /// this slice; an id a page names that no local row in the folder holds is
    /// loaded at once (the direct load); a local row of a listed range that no
    /// page named is a candidate, removed only when its own answer proves it
    /// gone or in another folder. Least recently attempted folder first; every
    /// request is charged to the call's Graph allowance (`GraphCatchUpAllowance`)
    /// before it is sent and bounded by `SyncConfig.catchUpRequestTimeoutSeconds`.
    /// Never throws, writes nothing (the apply does), and never names a
    /// synthetic placeholder id.
    func catchUp(
        folders: [Folder], localRows: any CatchUpLocalRowReader, context: CatchUpContext
    ) async -> [CatchUpFolderResult] {
        let ordered = CatchUpSchedule.leastRecentlyAttemptedFirst(folders) {
            ExchangeCatchUpState.decode($0.catchUpState)?.lastAttemptAt
        }
        let allowance = GraphCatchUpAllowance(context: context)
        var results: [CatchUpFolderResult] = []
        for folder in ordered {
            guard allowance.hasBudget() else { break }
            if let result = await catchUpFolder(folder, localRows: localRows, context: context, allowance: allowance) {
                results.append(result)
            }
        }
        return results
    }

    /// One record of a catch-up listing page.
    struct CatchUpListedMessage: Decodable, Sendable {
        let id: String
        let receivedDateTime: String?
        let isRead: Bool?
        let flag: GraphFlag?

        /// `receivedDateTime` as a whole epoch second (Graph's precision).
        var receivedSecond: Int? {
            receivedDateTime.flatMap(Date.fromISO8601).map { Int($0.timeIntervalSince1970.rounded(.down)) }
        }
    }

    private struct CatchUpListResponse: Decodable {
        let value: [CatchUpListedMessage]
        let odataNextLink: String?

        enum CodingKeys: String, CodingKey {
            case value
            case odataNextLink = "@odata.nextLink"
        }
    }

    /// One page of a folder's messages received in `[fromSecond, beforeSecond)`
    /// (no lower bound when `fromSecond <= 0`), newest first, at most
    /// `SyncConfig.catchUpGraphListPageSize` of them; or, with `nextLink`, the
    /// page Graph linked from the previous one (a link `GraphAPI.isGraphPageLink`
    /// refuses throws).
    func catchUpListingPage(
        folder: String, fromSecond: Int, beforeSecond: Int, nextLink: String?
    ) async throws -> (messages: [CatchUpListedMessage], nextLink: String?) {
        try Task.checkCancellation()
        let data: Data
        if let nextLink {
            data = try await requestAbsolute(url: nextLink)
        } else {
            let encodedFolder = try Self.encodedGraphPathSegment(folder, context: "Graph folder id")
            let before = Date(timeIntervalSince1970: TimeInterval(beforeSecond)).iso8601String()
            var filter = "receivedDateTime lt \(before)"
            if fromSecond > 0 {
                let from = Date(timeIntervalSince1970: TimeInterval(fromSecond)).iso8601String()
                filter = "receivedDateTime ge \(from) and \(filter)"
            }
            let path = "/mailFolders/\(encodedFolder)/messages?"
                + "\(GraphAPI.catchUpListingSelection.queryParameter)&$filter=\(filter)"
                + "&\(topParam(SyncConfig.catchUpGraphListPageSize))&\(orderByReceived)"
            data = try await request(path: path)
        }
        let response = try JSONDecoder().decode(CatchUpListResponse.self, from: data)
        return (response.value, response.odataNextLink)
    }

    /// Every Outlook catch-up request but the direct load's goes through here:
    /// `cost` (a `$batch` at its width) is charged to the call's allowance and
    /// the slice's budget before anything is sent, and the request is bounded by
    /// `SyncConfig.catchUpRequestTimeoutSeconds`, so no request starts after the
    /// slice's deadline and none holds the slice past it by more than one
    /// timeout. The direct load charges and bounds each batch the same way
    /// (`CatchUpDirectLoad.load`). Throws `FolderStop.budget` when `cost` does not
    /// fit, nothing charged; otherwise what the request throws.
    private static func catchUpRequest<T: Sendable>(
        cost: Int, allowance: GraphCatchUpAllowance, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard allowance.charge(cost) else { throw FolderStop.budget }
        return try await withTimeout(seconds: SyncConfig.catchUpRequestTimeoutSeconds, operation: operation)
    }

    /// Why a folder stopped for the slice.
    private enum FolderStop: Error {
        case budget
        case failure
        case held
    }

    /// One folder's catch-up. Nil when the folder needs nothing and its state
    /// does not change, or it is not eligible (an empty path, a quarantined folder).
    private func catchUpFolder(
        _ folder: Folder, localRows: any CatchUpLocalRowReader, context: CatchUpContext,
        allowance: GraphCatchUpAllowance
    ) async -> CatchUpFolderResult? {
        guard !folder.path.isEmpty, folder.uidValidityResetPendingAt == nil else { return nil }

        let state = ExchangeCatchUpState.decode(folder.catchUpState)
        var newState = state ?? ExchangeCatchUpState(createdAt: context.clock())
        if !folder.backfillComplete { newState.walkIncompleteSeen = true }
        let gateOpen = Self.catchUpTrackingGateOpen(folder)
        let plan = Self.catchUpPlan(
            state: newState, trackingGateOpen: gateOpen, walkComplete: folder.backfillComplete,
            isExpensiveNetwork: context.isExpensiveNetwork, now: context.clock())
        guard case .list(var listing) = plan else {
            // Nothing to list. The first sight of the folder (so the
            // expensive-network wait has a start, even while the gate holds) and
            // an unfinished walk seen are recorded; no request is made.
            guard newState != state else { return nil }
            var waiting = CatchUpFolderResult(folderId: folder.id, epoch: nil)
            waiting.newState = newState.encoded()
            return waiting
        }
        if newState.listing == nil { Self.start(&listing, state: &newState, folder: folder) }
        let planned = listing

        var result = CatchUpFolderResult(folderId: folder.id, epoch: nil)
        let path = folder.path
        let rowLimit = SyncConfig.catchUpGraphRangeRowLimit
        let pageSize = SyncConfig.catchUpGraphListPageSize
        var listingDone = false
        // Ids this slice loaded. They are inserted only after the call returns,
        // so the local rows do not hold them yet; they count as held, so an id
        // listed again in the same slice is never loaded twice.
        var loadedThisSlice = Set<String>()
        // Rows that got a flag update this slice (a page listed again at its
        // oldest second names some rows twice).
        var flagUpdatedIds = Set<String>()
        // The range this slice cut, as cut: cutting a range is not progress
        // until one of its pages is listed.
        var freshCut: ExchangeCatchUpState.RangeScan?

        do {
            rangeLoop: while true {
                try await proveCandidates(&listing, folder: folder, allowance: allowance, result: &result)

                // The range being listed, or the next older one: from the local
                // rows, never above the newest of them.
                if listing.range == nil {
                    let upper = listing.nextBeforeSecond.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    let head: [CatchUpLocalRow]
                    do {
                        head = try await localRows.newestRows(folderId: folder.id, orderDatesBefore: upper, limit: rowLimit + 1)
                    } catch {
                        throw FolderStop.failure
                    }
                    let headDates = head.compactMap(\.orderDate)
                    guard !headDates.isEmpty, headDates.count == head.count else {
                        guard head.isEmpty else { throw FolderStop.failure }
                        // The listing covered the folder.
                        newState.lastCompletedAt = context.clock()
                        newState.listedLapseCount = listing.lapseCountAtStart
                        var settled = newState
                        settled.listing = nil
                        guard case .list(var next) = Self.catchUpPlan(
                            state: settled, trackingGateOpen: gateOpen, walkComplete: folder.backfillComplete,
                            isExpensiveNetwork: context.isExpensiveNetwork, now: context.clock()) else {
                            listingDone = true
                            break rangeLoop
                        }
                        // A lapse came after this listing started, or the walk
                        // completed after it started: a new listing starts at once.
                        Self.start(&next, state: &newState, folder: folder)
                        listing = next
                        continue rangeLoop
                    }
                    // Under a storage limit the oldest local row is where kept mail
                    // ends, so the listing stops there (this run's snapshot).
                    let range = CatchUpRange.cut(
                        nextBeforeSecond: listing.nextBeforeSecond, head: headDates, rowLimit: rowLimit,
                        maxSpanSeconds: SyncConfig.catchUpGraphRangeMaxSpanSeconds,
                        toEpoch: listing.toEpoch && !context.storageLimitInForce)
                    listing.range = ExchangeCatchUpState.RangeScan(range: range, upperSecond: range.upTo)
                    freshCut = listing.range
                }
                guard var scan = listing.range else { break rangeLoop }
                let range = scan.range

                // The range's pages. A link Graph hands back is followed only
                // inside this slice, and only through one second's messages.
                var nextLink: String?
                var rangeListed = false
                while !rangeListed {
                    let page: (messages: [CatchUpListedMessage], nextLink: String?)
                    do {
                        let upper = scan.upperSecond
                        let link = nextLink
                        page = try await Self.catchUpRequest(cost: 1, allowance: allowance) {
                            try await self.catchUpListingPage(folder: path, fromSecond: range.from, beforeSecond: upper, nextLink: link)
                        }
                    } catch FolderStop.budget {
                        throw FolderStop.budget
                    } catch {
                        if DebugModeManager.isLoggingEnabled() {
                            BackgroundSyncLogger.logDebug("[CatchUp] \(path) \(range.from)..<\(scan.upperSecond): listing failed (\(error)) — stopping this folder for the slice")
                        }
                        throw FolderStop.failure
                    }

                    let ids = page.messages.map(\.id).filter { !isSyntheticPlaceholderId($0) }
                    let held: [String: CatchUpLocalRow]
                    do {
                        held = Dictionary(
                            try await localRows.rows(folderId: folder.id, ids: ids).map { ($0.messageId, $0) },
                            uniquingKeysWith: { first, _ in first })
                    } catch {
                        throw FolderStop.failure
                    }

                    // Rows the device holds: the page's read and flag state, applied
                    // in this slice. A field the record leaves out keeps the local value.
                    for message in page.messages {
                        guard let row = held[message.id], !flagUpdatedIds.contains(message.id) else { continue }
                        let isRead = message.isRead ?? row.isRead
                        let isFlagged = message.flag.map { $0.flagStatus == "flagged" } ?? row.isFlagged
                        guard isRead != row.isRead || isFlagged != row.isFlagged else { continue }
                        flagUpdatedIds.insert(message.id)
                        result.flagUpdates.append(CatchUpFlagUpdate(messageId: message.id, isRead: isRead, isFlagged: isFlagged))
                    }

                    // Ids no local row in the folder holds (mail moved in below the
                    // held range, a hole the walk left) are loaded before the page
                    // moves on.
                    let missing = ids.filter { held[$0] == nil && !loadedThisSlice.contains($0) }
                    if !missing.isEmpty {
                        let load = await CatchUpDirectLoad.load(
                            missing, batchSize: GraphConfig.bodyFetchConcurrency,
                            charge: { allowance.charge($0) },
                            fetch: { ids, concurrency in await self.fetchBackfillBatch(ids: ids, concurrency: concurrency) })
                        result.loaded += load.loaded
                        loadedThisSlice.formUnion(load.loaded.map(\.id))
                        result.loadFailures.merge(load.failures) { _, latest in latest }
                        switch CatchUpDirectLoad.pageVerdict(load, heldSince: &scan.loadHeldSince) {
                        case .passes:
                            break
                        case .stopsOnBudget:
                            listing.range = scan
                            throw FolderStop.budget
                        case .held:
                            listing.range = scan
                            throw FolderStop.held
                        }
                    }
                    // Named: the rows held, and the ids loaded (their rows land
                    // after this call, so a range that resumes in a later slice
                    // finds them local and must not take them for candidates).
                    let namedSoFar = Set(scan.namedIds)
                    let namedNow = Set(held.keys).union(ids.filter { loadedThisSlice.contains($0) })
                    scan.namedIds += namedNow.subtracting(namedSoFar).sorted()
                    scan.loadHeldSince = nil

                    // Where the next page starts. Pages are newest first, Graph
                    // dates have whole-second precision, and a page Graph links
                    // to continues the same query. Whether more follows is read
                    // from the link and the raw page size, never from what the
                    // page held for this folder.
                    let seconds = page.messages.compactMap(\.receivedSecond)
                    let usableLink = page.nextLink.flatMap { GraphAPI.isGraphPageLink($0) ? $0 : nil }
                    if page.nextLink == nil && page.messages.count < pageSize {
                        rangeListed = true
                    } else if seconds.count != page.messages.count {
                        // A record without a usable date: the page cannot be
                        // placed, so the folder stops for the slice.
                        listing.range = scan
                        throw FolderStop.failure
                    } else if let oldest = seconds.min(), seconds.contains(where: { $0 > oldest }) {
                        // List again from the page's oldest second, inclusive:
                        // its messages beyond this page come next, and the ones
                        // this page held are named again (no harm).
                        scan.upperSecond = min(scan.upperSecond, oldest + 1)
                        nextLink = nil
                    } else if let usableLink {
                        // Every message of the page shares one second (or the
                        // page is empty): the date cannot split it, so Graph's own
                        // link goes on, in this slice only. It is never saved.
                        nextLink = usableLink
                    } else if let oldest = seconds.min() {
                        // One second fills the page and no usable link goes on:
                        // the rest of that second is not listed by this listing.
                        // Its local rows are still proved one by one.
                        scan.upperSecond = min(scan.upperSecond, oldest)
                        nextLink = nil
                    } else {
                        // An empty page with a link that cannot be followed.
                        listing.range = scan
                        throw FolderStop.failure
                    }
                    listing.range = scan
                }

                // The range is listed: its local rows no page named are
                // candidates, each decided by its own answer before the next range.
                let rangeRows: [CatchUpLocalRow]
                do {
                    rangeRows = try await localRows.rows(
                        folderId: folder.id,
                        orderDatesFrom: Date(timeIntervalSince1970: TimeInterval(range.from)),
                        before: Date(timeIntervalSince1970: TimeInterval(range.upTo)))
                } catch {
                    throw FolderStop.failure
                }
                let named = Set(scan.namedIds)
                listing.pendingCandidates += rangeRows.map(\.messageId)
                    .filter { !named.contains($0) && !isSyntheticPlaceholderId($0) }
                listing.range = nil
                listing.nextBeforeSecond = range.from
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[CatchUp] \(path): stopped for the slice (\(error))")
            }
        }

        newState.lastAttemptAt = context.clock()
        newState.listing = listingDone ? nil : listing
        result.newState = newState.encoded()
        // Progress: the listing moved (a page, a range, a candidate answered, a
        // hold clock started) or completed, or something loaded or applies. A
        // request that failed before anything moved (a range cut but none of
        // its pages listed), or a page still held, is no progress, so the
        // worker does not list the folder again at once.
        var moved = listing
        if let freshCut, moved.range == freshCut { moved.range = planned.range }
        result.madeProgress = listingDone || moved != planned
            || !result.loaded.isEmpty || !result.removedIds.isEmpty || !result.flagUpdates.isEmpty
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CatchUp] \(path): flags=\(result.flagUpdates.count) removed=\(result.removedIds.count) loaded=\(result.loaded.count) failed=\(result.loadFailures.count) \(listingDone ? "listing complete" : "resumes before \(listing.nextBeforeSecond.map(String.init) ?? "the newest row")")")
        }
        return result
    }

    /// A new listing starts: it may reach down to the epoch only when the walk
    /// is complete (the storage limit is decided per run, at each cut), and once
    /// it starts with the walk complete, the walk's holes are covered.
    private nonisolated static func start(
        _ listing: inout ExchangeCatchUpState.Listing, state: inout ExchangeCatchUpState, folder: Folder
    ) {
        listing.toEpoch = folder.backfillComplete
        if folder.backfillComplete { state.walkIncompleteSeen = false }
    }

    /// Proves the listing's pending candidates, `$batch` by `$batch`
    /// (`fetchMessageDetails`, each batch charged its width first). Gone, or in
    /// another folder, removes the row; in this folder keeps it. An answer that
    /// cannot be used (`unreadable`) keeps the candidate for a later slice, and
    /// no answer (`unanswered`, a failed batch) stops the folder for the slice;
    /// either way the candidate is held on the page walk's hold clock, and past
    /// the hold bound the held candidates are let go with their rows kept.
    /// Returns once no candidate is left; throws when the folder must stop.
    private func proveCandidates(
        _ listing: inout ExchangeCatchUpState.Listing, folder: Folder,
        allowance: GraphCatchUpAllowance, result: inout CatchUpFolderResult
    ) async throws(FolderStop) {
        var askedThisSlice = Set<String>()
        while true {
            let unasked = listing.pendingCandidates.filter { !askedThisSlice.contains($0) }
            if unasked.isEmpty {
                guard !listing.pendingCandidates.isEmpty else {
                    listing.candidateHeldSince = nil
                    return
                }
                // Every candidate left was asked this slice and held.
                guard Self.candidateHoldExpired(&listing.candidateHeldSince) else { throw .held }
                listing.pendingCandidates = []
                listing.candidateHeldSince = nil
                return
            }
            let width = min(unasked.count, SyncConfig.graphBatchMaxRequests, allowance.requestsLeft)
            guard width > 0 else { throw .budget }
            let chunk = Array(unasked.prefix(width))
            let batch: ExchangeDetailBatch
            do {
                batch = try await Self.catchUpRequest(cost: width, allowance: allowance) {
                    try await self.fetchMessageDetails(ids: chunk)
                }
            } catch FolderStop.budget {
                throw .budget
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CatchUp] \(folder.path): proof of \(chunk.count) candidate(s) failed (\(error)) — held")
                }
                batch = ExchangeDetailBatch(unanswered: Dictionary(uniqueKeysWithValues: chunk.map { ($0, 0) }))
            }
            askedThisSlice.formUnion(chunk)
            var settled = Set<String>()
            for detail in batch.details {
                settled.insert(detail.header.messageId)
                if detail.parentFolderId != folder.path { result.removedIds.append(detail.header.messageId) }
            }
            for id in batch.gone {
                settled.insert(id)
                result.removedIds.append(id)
            }
            listing.pendingCandidates.removeAll { settled.contains($0) }
            guard batch.unanswered.isEmpty else {
                if Self.candidateHoldExpired(&listing.candidateHeldSince) {
                    let unproved = Set(batch.unanswered.keys).union(batch.unreadable)
                    listing.pendingCandidates.removeAll { unproved.contains($0) }
                    listing.candidateHeldSince = nil
                }
                throw .held
            }
        }
    }

    /// The hold clock of the candidates: started (or kept) now; true once the
    /// page walk's hold bound has passed since it started.
    private nonisolated static func candidateHoldExpired(_ heldSince: inout Date?) -> Bool {
        let now = SyncEngine.backfillPageHoldNow()
        let firstHeld = heldSince ?? now
        heldSince = firstHeld
        if case .hold = SyncEngine.decideBackfillPage(strictestFailure: .hold, firstHeld: firstHeld, now: now) {
            return false
        }
        return true
    }
}
