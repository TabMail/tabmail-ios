/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Gmail's opaque per-folder catch-up state (ADR-IOS-107), stored as JSON in
/// `Folder.catchUpState`. Only `GmailProvider` reads or writes it. Gmail ids carry
/// no epoch, so unlike IMAP's there is none here.
struct GmailCatchUpState: Codable, Equatable, Sendable {
    /// When the last listing completed. Drives the full-check interval.
    var lastCompletedAt: Date?
    /// The listing in progress, if any.
    var listing: Listing?
    /// When the catch-up first saw the folder. Until a listing completes, the
    /// expensive-network wait is counted from here.
    var createdAt: Date?
    /// When the catch-up last tried a listing for the folder, whether or not it
    /// succeeded. Drives the order (`CatchUpSchedule.leastRecentlyAttemptedFirst`).
    var lastAttemptAt: Date?

    struct Listing: Codable, Equatable, Sendable {
        /// The next range starts at this epoch second; nil starts at the folder's
        /// oldest local row. A listing that starts while the folder's backfill
        /// walk is complete starts at 0, so it also lists mail older than every
        /// local row.
        var nextFromSecond: Int?
        /// Whether a range listed so far found a missing id: one the server lists
        /// in the folder that no local row in the folder holds.
        var foundMissing = false
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
    /// way the folder starts over, which can only cost a re-listing and, at most,
    /// one extra re-arm of its backfill.
    static func decode(_ raw: String?) -> GmailCatchUpState? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GmailCatchUpState.self, from: data)
    }
}

extension GmailProvider {

    /// What a folder needs this pass. Pure, so the decision is testable on its own.
    enum CatchUpPlan: Equatable {
        /// Nothing: the full check is not due, or an expensive network holds it back.
        case none
        /// List the folder by provider-date ranges, starting at or continuing `listing`.
        case list(GmailCatchUpState.Listing)
    }

    /// The per-folder decision: IMAP's without the HIGHESTMODSEQ signal (Gmail has
    /// none). A folder lists when its full check is due (weekly,
    /// `SyncConfig.gmailCatchUpFullCheckIntervalSeconds`, or at once when a lapse
    /// cleared its state), or continues a listing in progress; on an expensive
    /// network only once it has waited `SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds`.
    /// A folder with no state on an expensive network gets `.none`; the caller
    /// writes a state carrying `createdAt` so the wait has a start.
    nonisolated static func catchUpPlan(state: GmailCatchUpState?, isExpensiveNetwork: Bool, now: Date) -> CatchUpPlan {
        let waitedTooLong = CatchUpSchedule.waitedTooLong(
            hasState: state != nil, lastCompletedAt: state?.lastCompletedAt, createdAt: state?.createdAt, now: now)
        if isExpensiveNetwork && !waitedTooLong { return .none }
        if let listing = state?.listing { return .list(listing) }
        if CatchUpSchedule.fullCheckDue(
            lastCompletedAt: state?.lastCompletedAt, now: now, interval: SyncConfig.gmailCatchUpFullCheckIntervalSeconds) {
            return .list(GmailCatchUpState.Listing())
        }
        return .none
    }

    /// One listing range, in whole epoch seconds. Ranges tile the folder's local
    /// range without gaps: each starts where the previous one ended.
    struct CatchUpRange: Codable, Equatable, Sendable {
        /// Where the range starts (inclusive): the previous range's end, or the
        /// first range's first local row.
        let from: Int
        /// The second of the range's first local row (`>= from`). The stretch
        /// before it holds no local row.
        let firstLocal: Int
        /// Where the range ends (exclusive).
        let upTo: Int
    }

    /// The range starting at `nextFromSecond`, given the order dates of the first
    /// local rows at or after it (`head`, ascending, non-empty, at most
    /// `rowLimit + 1` of them). The range holds at most `rowLimit` rows unless more
    /// than that share its first second, ends on a whole second (rows sharing the
    /// cut second go to the next range), and spans at most `maxSpanSeconds` from its
    /// first local row.
    nonisolated static func catchUpRange(
        nextFromSecond: Int?, head: [Date], rowLimit: Int, maxSpanSeconds: Int
    ) -> CatchUpRange {
        let second = { (date: Date) in Int(date.timeIntervalSince1970.rounded(.down)) }
        let firstLocal = second(head[0])
        var upTo = head.count > rowLimit
            ? max(second(head[rowLimit]), firstLocal + 1)
            : second(head[head.count - 1]) + 1
        upTo = min(upTo, firstLocal + maxSpanSeconds)
        return CatchUpRange(from: min(nextFromSecond ?? firstLocal, firstLocal), firstLocal: firstLocal, upTo: upTo)
    }

    /// `EmailProvider.catchUp` for Gmail (ADR-IOS-107). For each folder whose full
    /// check is due (weekly, or after a lapse) or whose listing is in progress: a listing by
    /// provider-date ranges taken from the local rows, resuming across passes.
    /// Per range, the folder's membership list, then the account-wide `is:unread`
    /// and `is:starred` lists over the same dates (so a message moved between two
    /// requests can never get a wrong flag), each resuming at its saved page, then
    /// a `format=minimal` GET for every local row the membership list left out:
    /// only a 404 or labels that no longer place the message in the folder remove
    /// it. Least recently attempted folder
    /// first; every request is preceded by a budget check and bounded by
    /// `SyncConfig.catchUpRequestTimeoutSeconds`. Read-only on the wire; never
    /// inserts; never names a synthetic placeholder id.
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
    }

    /// One page of a list, preceded by a budget check and bounded by the request
    /// timeout.
    private func catchUpListPage(
        context: CatchUpContext, token: String?,
        page: @escaping @Sendable (_ token: String?) async throws -> (ids: [String], nextPageToken: String?)
    ) async throws(RangeStop) -> (ids: [String], nextPageToken: String?) {
        guard context.hasBudget() else { throw .budget }
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
        // A new listing of a folder whose walk is complete starts at the epoch,
        // not at the oldest local row: a message older than every local row that
        // moved in is missing too, and only a re-armed walk loads it. An
        // unfinished walk reaches that mail itself.
        if state?.listing == nil && folder.backfillComplete { listing.nextFromSecond = 0 }

        var result = CatchUpFolderResult(folderId: folder.id, epoch: nil)
        let path = folder.path
        let rowLimit = SyncConfig.catchUpGmailRangeRowLimit
        let slack = SyncConfig.catchUpGmailRangeSlackSeconds
        let pageSize = SyncConfig.catchUpGmailListPageSize
        var completed = false

        rangeLoop: while true {
            // A row the listing left out is only a candidate: its own answer
            // decides. Gone (404/410), or labels that no longer place it in the
            // folder, removes it; any other answer keeps it. Without the budget, or
            // on a failure that is no answer, the rest wait in the state for the
            // next pass.
            while let id = listing.pendingCandidates.first {
                guard context.hasBudget() else { break rangeLoop }
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

            // The range whose lists are in progress, or the next one: from the
            // local rows, never past them.
            if listing.range == nil {
                do {
                    let lower = listing.nextFromSecond.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    let head = try await localRows.rows(folderId: folder.id, orderDatesFrom: lower, before: nil, limit: rowLimit + 1)
                    let headDates = head.compactMap(\.orderDate)
                    guard !headDates.isEmpty, headDates.count == head.count else {
                        completed = head.isEmpty
                        break rangeLoop
                    }
                    listing.range = GmailCatchUpState.RangeScan(range: Self.catchUpRange(
                        nextFromSecond: listing.nextFromSecond, head: headDates,
                        rowLimit: rowLimit, maxSpanSeconds: SyncConfig.catchUpGmailRangeMaxSpanSeconds))
                } catch {
                    break rangeLoop
                }
            }
            guard var scan = listing.range else { break rangeLoop }
            let range = scan.range

            // The range's rows as the device holds them now. More than `rowLimit`
            // rows only when more than that share the range's first second.
            let rangeRows: [CatchUpLocalRow]
            do {
                rangeRows = try await localRows.rows(
                    folderId: folder.id,
                    orderDatesFrom: Date(timeIntervalSince1970: TimeInterval(range.from)),
                    before: Date(timeIntervalSince1970: TimeInterval(range.upTo)),
                    limit: nil)
            } catch {
                break rangeLoop
            }
            let rangeRowsById = Dictionary(rangeRows.map { ($0.messageId, $0) }, uniquingKeysWith: { first, _ in first })

            // Never before the epoch: a listing from 0 has no slack below it.
            let membershipWindow = ListWindow(after: max(0, range.from - slack), before: range.upTo + slack)
            let flagWindow = ListWindow(after: range.firstLocal - slack, before: range.upTo + slack)
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
                        // Server ids in the range with no local row in the folder:
                        // an old message moved in, which the re-armed backfill loads.
                        let unseen = page.ids.filter { rangeRowsById[$0] == nil && !isSyntheticPlaceholderId($0) }
                        var held = Set<String>()
                        if !unseen.isEmpty {
                            do {
                                held = Set(try await localRows.rows(folderId: folder.id, ids: unseen).map(\.messageId))
                            } catch {
                                throw RangeStop.failure(error)
                            }
                        }
                        if unseen.contains(where: { !held.contains($0) }) { listing.foundMissing = true }
                        let namedSoFar = Set(scan.namedIds)
                        scan.namedIds += Set(page.ids.filter { rangeRowsById[$0] != nil }).subtracting(namedSoFar)
                    case .unread:
                        let named = Set(scan.named.map(\.id))
                        scan.unreadIds += page.ids.filter { named.contains($0) }
                    case .starred:
                        let named = Set(scan.named.map(\.id))
                        scan.starredIds += page.ids.filter { named.contains($0) }
                    }

                    scan.pageToken = page.nextPageToken
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
            // moves past it. A row dated before the flag window (one that arrived
            // in the range's stretch before its first local row after the range
            // was cut) was never asked about, so its absence from them says nothing.
            let unread = Set(scan.unreadIds)
            let starred = Set(scan.starredIds)
            let flagWindowStart = Date(timeIntervalSince1970: TimeInterval(flagWindow.after))
            for named in scan.named {
                guard let row = rangeRowsById[named.id], row.isRead == named.isRead, row.isFlagged == named.isFlagged else { continue }
                guard let orderDate = row.orderDate, orderDate >= flagWindowStart else { continue }
                let isRead = !unread.contains(named.id)
                let isFlagged = starred.contains(named.id)
                if isRead != row.isRead || isFlagged != row.isFlagged {
                    result.flagUpdates.append(CatchUpFlagUpdate(messageId: named.id, isRead: isRead, isFlagged: isFlagged))
                }
            }
            listing.range = nil
            listing.nextFromSecond = range.upTo
        }

        var newState = state ?? GmailCatchUpState(createdAt: context.clock())
        newState.lastAttemptAt = context.clock()
        if completed {
            // The listing covered the folder. Ask for a re-arm of the backfill
            // when something is missing; the apply declines it while the
            // folder's walk is unfinished. One completed check asks at most once,
            // so an id that cannot load costs one ids-only re-walk per check
            // (weekly, plus the check after each lapse), and is tried again at
            // each. What leaves an id missing, and so asks: mail moved in from
            // elsewhere (older than the newest rows, which no window reaches), a
            // lapse (the state is cleared), and a fetch that failed during the
            // walk: the walk passes over an id whose GET fails about the message
            // itself, or keeps failing past the page hold bound, and only the
            // next check finds it missing and re-arms for it.
            newState.lastCompletedAt = context.clock()
            newState.listing = nil
            result.rearmBackfill = listing.foundMissing
        } else {
            newState.listing = listing
        }
        result.newState = newState.encoded()
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CatchUp] \(path): flags=\(result.flagUpdates.count) removed=\(result.removedIds.count) rearm=\(result.rearmBackfill) \(completed ? "listing complete" : "resumes at \(listing.nextFromSecond.map(String.init) ?? "start")")")
        }
        return result
    }
}
