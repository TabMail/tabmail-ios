/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Outlook's change reader (ADR-IOS-111): one Graph message delta per folder,
/// read below the seam. It only reads; the engine's generic apply writes.
///
/// **Bookmarks.** Each folder keeps its own (`ChangeFolder.cursor`, an
/// `OutlookFolderCursor`): the link to read next, whether the folder is still in
/// its first round (its baseline) or tracking, and which `$select` its round
/// chain uses. The account part (`ChangeCursor.account`, an
/// `OutlookAccountCursor`) holds the mail-folder delta link only.
///
/// **Two selections, chosen by role when a folder's chain starts.** A delta chain
/// keeps the `$select` it started with, so the choice is stored in the cursor:
/// - the Inbox selects the header fields (`GraphAPI.headerOnlySelection`), so new
///   Inbox mail arrives in the delta page itself;
/// - every other folder selects the message state (`GraphAPI.stateSelection`).
///   A change to a message the phone holds applies from that record. A message
///   the folder does not hold, whose record carries `receivedDateTime` (a new or
///   moved-in message), gets its headers fetched (`fetchMessageDetails`, in
///   `$batch`es) when the folder is tracking, or during its baseline when the
///   message is within the folder's held range (`ChangeFolder.heldSince`). The
///   folder's bookmark never passes a page until every such header is in, read
///   as gone, or reported unreadable (`rereadLater`); a page cut short is read
///   again on the next pass, which fetches only what is still missing.
///
/// **Network.** A state baseline on an expensive network (cellular, a hotspot)
/// waits, at most `SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds` counted from
/// when the folder first needed it, then runs on any network, as the catch-up
/// does. The Inbox baseline runs on any network.
///
/// **Budget.** No request starts after `ChangeContext.deadline`, every request is
/// given up after `SyncConfig.changeReadRequestTimeoutSeconds`, and one read
/// sends at most `SyncConfig.graphChangeReadRequestsPerSecond` times its read
/// budget, a `$batch` charged its width before it is sent.
///
/// **Folder list** (scope `.all`): the mail-folder delta is a change signal. A
/// record for a folder already stored updates its name and counts
/// (`FolderListUpdate.updated`); a new folder, a removed one or no link yet runs
/// the complete tree listing (`fetchFolders`, `FolderListUpdate.complete`), with
/// the new link minted before it.
///
/// **Failures.** A refused folder bookmark (`graphRefusedDeltaToken`) is that
/// folder's `.refused(.rejected(status))`; a refused saved baseline continuation
/// first restarts the baseline at page 1, once per pass. A server error, a page
/// that cannot be decoded, a next link that repeats or a round longer than
/// `SyncConfig.changeReadMaxRoundPages` counts towards
/// `SyncConfig.changeReadFailureLapseSeconds`, after which the folder is
/// `.refused(.failingTooLong)`. A throttle, a timeout, an authorization failure
/// or a dropped connection keeps the bookmark and counts nothing.
extension ExchangeProvider {

    func fetchChanges(since cursor: ChangeCursor, request: ChangeRequest) async throws -> ChangeSet? {
        let context = request.context
        // A pass whose turn started with no read budget left reads nothing and
        // keeps every bookmark (`SyncEngine.changeReadEnd`).
        guard context.hasBudget() else {
            return .uniform(request, account: .keep, status: .notRun)
        }
        adoptWellKnownFolderIds(request.folders)
        var allowance = ChangeReadAllowance(context: context)

        var account: AccountCursorUpdate = .unchanged
        var folderList: FolderListUpdate?
        if request.scope == .all {
            (account, folderList) = try await readFolderList(
                stored: cursor.account, folders: request.folders, allowance: &allowance)
        }

        var results: [String: FolderChanges] = [:]
        for folder in Self.foldersToRead(request) {
            results[folder.id] = try await readFolder(folder, request: request, allowance: &allowance)
        }
        let folders = request.folders.map { results[$0.id] ?? FolderChanges(folderId: $0.id, status: .notRun) }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[Exchange] change read: \(results.count) folder(s) read, \(allowance.requestsLeft) request(s) of the allowance left")
        }
        return ChangeSet(account: account, folderList: folderList, folders: folders)
    }

    /// The folders this read covers, in order: those already tracking before
    /// those in their baseline, the Inbox first in each. Scope `.all` reads every
    /// folder the full sync syncs; `.inboxOnly` reads the Inbox only.
    nonisolated static func foldersToRead(_ request: ChangeRequest) -> [ChangeFolder] {
        let eligible = request.folders.filter { folder in
            switch request.scope {
            case .all: return folder.isSynced
            case .inboxOnly: return folder.role == .inbox
            }
        }
        return eligible.enumerated().sorted { lhs, rhs in
            let l = (Self.isBaselinePhase(lhs.element) ? 1 : 0, lhs.element.role == .inbox ? 0 : 1, lhs.offset)
            let r = (Self.isBaselinePhase(rhs.element) ? 1 : 0, rhs.element.role == .inbox ? 0 : 1, rhs.offset)
            return l < r
        }.map(\.element)
    }

    private nonisolated static func isBaselinePhase(_ folder: ChangeFolder) -> Bool {
        OutlookFolderCursor(raw: folder.cursor)?.phase != .tracking
    }

    /// The well-known folder ids, from the stored folders' roles (a Graph folder's
    /// path is its id), so a process whose full sync skipped discovery still has
    /// the Inbox id the legacy category strip needs (ADR-IOS-036).
    private func adoptWellKnownFolderIds(_ folders: [ChangeFolder]) {
        for folder in folders {
            switch folder.role {
            case .inbox: inboxFolderId = folder.path
            case .archive: archiveFolderId = folder.path
            case .trash: deletedItemsFolderId = folder.path
            default: break
            }
        }
    }

    // MARK: - One folder

    private func readFolder(
        _ folder: ChangeFolder, request: ChangeRequest, allowance: inout ChangeReadAllowance
    ) async throws -> FolderChanges {
        let context = request.context
        let stored = OutlookFolderCursor(raw: folder.cursor)
        var state = stored ?? OutlookFolderCursor.fresh(role: folder.role, now: context.clock())
        var changes = FolderChanges(folderId: folder.id, status: .notRun)
        var collected = CollectedChanges()

        // A state baseline on an expensive network waits, within its bound.
        if state.phase == .baseline, state.select == .state, context.isExpensiveNetwork,
           context.clock().timeIntervalSince(state.baselineSince) < SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds {
            BackgroundSyncLogger.logDebug("[Exchange] change read: folder \(folder.id.suffix(12)) baseline waits for a non-expensive network")
            changes.status = .baselining
            changes.cursor = state != stored ? state.encoded : nil
            return changes
        }

        var ending = FolderReadEnding.cut
        var restartedBaseline = false
        pages: while true {
            guard allowance.canSend(1) else { ending = .cut; break }
            let link = state.next
            allowance.charge(1)
            let page: DeltaPage
            do {
                page = try await readDeltaPage(folder: folder, link: link, select: state.select)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                if Self.graphRefusedDeltaToken(error) {
                    if state.phase == .baseline, link != nil, !restartedBaseline {
                        // A saved baseline continuation Graph no longer serves:
                        // start the baseline again from page 1, once this pass.
                        BackgroundSyncLogger.logDebug("[Exchange] change read: baseline continuation refused, starting again")
                        restartedBaseline = true
                        collected = CollectedChanges()
                        state.restartBaseline()
                        continue
                    }
                    ending = .refused(httpStatus(of: error) ?? 0)
                } else {
                    ending = .failed(error, counted: Self.countsAsFolderFailure(error))
                }
                break
            }

            // The page's records, with the headers it is missing.
            let held: Set<String>
            do {
                held = try await heldIds(folder: folder, ids: page.records.map(\.id), request: request)
            } catch {
                ending = .failed(error, counted: false)
                break
            }
            var missing: [String] = []
            for record in page.records {
                if record.removed != nil {
                    // A baseline lists the folder as it is: it never removes.
                    if state.phase == .tracking { collected.remove(record.id) }
                    continue
                }
                if held.contains(record.id) || state.select == .header {
                    collected.add(Self.changeRecord(record, header: page.headers[record.id]))
                } else if Self.needsHeader(record, phase: state.phase, heldSince: folder.heldSince) {
                    missing.append(record.id)
                }
            }

            var pageHeld = false
            var heldError: (any Error)?
            var heldCounted = false
            var pending = missing[...]
            while !pending.isEmpty {
                let width = min(pending.count, SyncConfig.graphBatchMaxRequests, allowance.requestsLeft)
                guard width > 0, context.hasBudget() else {
                    // The budget ends inside the page: it is read again next pass,
                    // which fetches only what is still missing.
                    pageHeld = true
                    break
                }
                let ids = Array(pending.prefix(width))
                pending = pending.dropFirst(width)
                allowance.charge(width)
                context.onProgress(width)
                let batch: ExchangeDetailBatch
                do {
                    batch = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                        try await self.fetchMessageDetails(ids: ids)
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled { throw error }
                    pageHeld = true
                    heldError = error
                    heldCounted = heldCounted || Self.countsAsFolderFailure(error)
                    continue
                }
                for detail in batch.details where detail.parentFolderId == folder.path {
                    collected.add(ChangeRecord(header: detail.header))
                }
                // Gone, or now in another folder: that folder's own round reports
                // it. Nothing is inserted here and the page may pass.
                changes.rereadLater += batch.unreadable
                if !batch.unanswered.isEmpty {
                    pageHeld = true
                    heldCounted = heldCounted || batch.unanswered.values.contains { $0 >= 500 }
                    heldError = heldError ?? ProviderError.networkError(
                        underlying: HTTPError.networkError(statusCode: batch.unanswered.values.max() ?? 0))
                }
            }
            if pageHeld {
                ending = heldError.map { .failed($0, counted: heldCounted) } ?? .cut
                break
            }

            // Every header the page needed is in: the bookmark passes it.
            guard let next = page.nextLink ?? page.deltaLink else {
                ending = .failed(Self.unreadablePage("no next or delta link"), counted: true)
                break
            }
            if page.nextLink != nil, next == link {
                ending = .failed(Self.unreadablePage("next link repeats"), counted: true)
                break
            }
            state.roundPages += 1
            if state.roundPages > SyncConfig.changeReadMaxRoundPages {
                ending = .failed(Self.unreadablePage("round longer than the page limit"), counted: true)
                break
            }
            state.next = next
            state.failingSince = nil
            if page.deltaLink != nil {
                state.roundPages = 0
                if state.phase == .baseline {
                    state.phase = .tracking
                    ending = .baselineDone
                } else {
                    ending = .roundDone
                }
                break pages
            }
        }

        // Messages kept back on an earlier pass, read again.
        if !Self.isRefusal(ending) {
            let alreadyAnswered = collected.answeredIds
            let asked = (request.recheck[folder.id] ?? []).filter { !alreadyAnswered.contains($0) }
            try await reread(asked, folder: folder, context: context, allowance: &allowance,
                             collected: &collected, changes: &changes)
        }

        return Self.finish(
            changes, collected: collected, state: state, stored: stored, ending: ending, now: context.clock())
    }

    /// The folder's result from how its read ended. Records and the bookmark
    /// travel together: what was read up to the bookmark is applied with it.
    private nonisolated static func finish(
        _ changes: FolderChanges, collected: CollectedChanges, state: OutlookFolderCursor,
        stored: OutlookFolderCursor?, ending: FolderReadEnding, now: Date
    ) -> FolderChanges {
        var changes = changes
        var state = state
        changes.records = collected.records
        changes.removals = collected.removals
        switch ending {
        case .baselineDone:
            changes.status = .baselineReady
        case .roundDone:
            changes.status = .tracked
        case .cut:
            changes.status = state.phase == .tracking ? .tracked : .baselining
        case .refused(let status):
            return refused(changes, .rejected(status))
        case .failed(let error, let counted):
            if counted {
                let since = state.failingSince ?? now
                state.failingSince = since
                if now.timeIntervalSince(since) >= SyncConfig.changeReadFailureLapseSeconds {
                    return refused(changes, .failingTooLong)
                }
            }
            // A baseline's records stay baseline records (applied within the held
            // range only), so a baseline that read something reports its progress;
            // one that read nothing reports the failure.
            if state.phase == .baseline, !(collected.records.isEmpty && collected.removals.isEmpty) {
                changes.status = .baselining
            } else {
                changes.status = .failed(error)
            }
        }
        changes.cursor = state != stored ? state.encoded : nil
        return changes
    }

    /// A refused bookmark: nothing read under it is applied, and the engine
    /// clears it with the folder's coverage.
    private nonisolated static func refused(_ changes: FolderChanges, _ reason: ChangeRefusal) -> FolderChanges {
        FolderChanges(folderId: changes.folderId, status: .refused(reason), rereadLater: changes.rereadLater)
    }

    private nonisolated static func isRefusal(_ ending: FolderReadEnding) -> Bool {
        if case .refused = ending { return true }
        return false
    }

    /// Re-read messages a change was kept back for: in this folder = a full
    /// record; gone or in another folder = a removal here; an unusable answer =
    /// read again later. Ids not asked for within the budget stay listed.
    private func reread(
        _ ids: [String], folder: ChangeFolder, context: ChangeContext, allowance: inout ChangeReadAllowance,
        collected: inout CollectedChanges, changes: inout FolderChanges
    ) async throws {
        var pending = ids[...]
        while !pending.isEmpty {
            let width = min(pending.count, SyncConfig.graphBatchMaxRequests, allowance.requestsLeft)
            guard width > 0, context.hasBudget() else { return }
            let chunk = Array(pending.prefix(width))
            pending = pending.dropFirst(width)
            allowance.charge(width)
            context.onProgress(width)
            let batch: ExchangeDetailBatch
            do {
                batch = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                    try await self.fetchMessageDetails(ids: chunk)
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                return
            }
            for detail in batch.details {
                if detail.parentFolderId == folder.path {
                    collected.add(ChangeRecord(header: detail.header))
                } else {
                    collected.remove(detail.header.messageId)
                }
            }
            for id in batch.gone { collected.remove(id) }
            changes.rereadLater += batch.unreadable
        }
    }

    // MARK: - Records

    /// The record for a message the apply can take as it is: a full record when
    /// the page carried its header fields (the Inbox's selection), otherwise the
    /// state fields present (absent ones are left out and never overwrite).
    private nonisolated static func changeRecord(_ record: GraphDeltaMessage, header: MessageHeaderInfo?) -> ChangeRecord {
        if let header { return ChangeRecord(header: header) }
        var change = ChangeRecord(messageId: record.id)
        change.isRead = record.isRead
        if let flag = record.flag { change.isFlagged = flag.flagStatus == "flagged" }
        return change
    }

    /// A message the folder does not hold needs its headers fetched when its
    /// record carries `receivedDateTime` (a new or moved-in message; an update
    /// carries only what changed) and, during the baseline, that date is within
    /// the folder's held range. Below the range, or with no range yet, the apply
    /// would insert nothing, so nothing is fetched.
    nonisolated static func needsHeader(_ record: GraphDeltaMessage, phase: OutlookFolderCursor.Phase, heldSince: Date?) -> Bool {
        guard let raw = record.receivedDateTime, let date = Date.fromISO8601(raw) else { return false }
        switch phase {
        case .tracking: return true
        case .baseline:
            guard let heldSince else { return false }
            return date >= heldSince
        }
    }

    private func heldIds(folder: ChangeFolder, ids: [String], request: ChangeRequest) async throws -> Set<String> {
        guard let localRows = request.localRows, !ids.isEmpty else { return [] }
        return Set(try await localRows.rows(folderId: folder.id, ids: ids).map(\.messageId))
    }

    // MARK: - Requests

    /// One page of a folder's message delta. Page 1 of a new round chain is built
    /// from the folder id and the chain's selection; every later page is the link
    /// Graph returned, which carries the selection itself.
    private func readDeltaPage(folder: ChangeFolder, link: String?, select: OutlookFolderCursor.Selection) async throws -> DeltaPage {
        let pageSize = ["Prefer": "odata.maxpagesize=\(SyncConfig.graphChangeReadPageSize)"]
        let selection = select.selection
        let data: Data
        if let link {
            data = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                try await self.requestAbsolute(url: link, extraHeaders: pageSize)
            }
        } else {
            let encodedFolder = try Self.encodedGraphPathSegment(folder.path, context: "Graph folder id")
            let path = "/mailFolders/\(encodedFolder)/messages/delta?\(selection.queryParameter)"
            data = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                try await self.request(path: path, extraHeaders: pageSize)
            }
        }
        let response = try JSONDecoder().decode(GraphDeltaResponse<GraphDeltaMessage>.self, from: data)
        var headers: [String: MessageHeaderInfo] = [:]
        if select == .header {
            // The header fields are on the page: a record with `receivedDateTime`
            // is a full record; one without is an update.
            let full = try JSONDecoder().decode(GraphDeltaResponse<GraphDeltaFullMessage>.self, from: data)
            for entry in full.value where entry.removed == nil {
                guard let message = entry.message, message.receivedDateTime != nil,
                      let header = parseGraphMessage(message, selection: selection) else { continue }
                headers[message.id] = header
            }
        }
        return DeltaPage(
            records: response.value, headers: headers,
            nextLink: response.odataNextLink, deltaLink: response.odataDeltaLink)
    }

    /// A server error or an answer that cannot be decoded counts towards the
    /// folder's failure lapse; a throttle, a timeout, an authorization failure or
    /// a dropped connection does not.
    nonisolated static func countsAsFolderFailure(_ error: any Error) -> Bool {
        if error is DecodingError { return true }
        if case ProviderError.networkError(let underlying) = error,
           case HTTPError.networkError(let status) = underlying {
            return status >= 500
        }
        return false
    }

    private nonisolated static func unreadablePage(_ reason: String) -> any Error {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Graph delta page: \(reason)"))
    }

    // MARK: - Folder list

    /// The folder list for scope `.all` and the account part to store.
    private func readFolderList(
        stored: String?, folders: [ChangeFolder], allowance: inout ChangeReadAllowance
    ) async throws -> (AccountCursorUpdate, FolderListUpdate?) {
        if let link = OutlookAccountCursor(raw: stored)?.folders {
            let round: FolderDeltaRound
            do {
                round = try await readFolderDeltaRound(from: link, allowance: &allowance)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                guard Self.graphRefusedDeltaToken(error) else {
                    BackgroundSyncLogger.logDebug("[Exchange] change read: folder delta failed: \(error)")
                    return (.unchanged, nil)
                }
                BackgroundSyncLogger.logDebug("[Exchange] change read: folder delta link refused, listing again")
                return try await mintFolderLinkAndList(allowance: &allowance)
            }
            guard let round else { return (.unchanged, nil) }
            let account: AccountCursorUpdate = round.deltaLink == link
                ? .unchanged : .set(OutlookAccountCursor(folders: round.deltaLink).encoded)
            let known = Dictionary(folders.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            var updates: [FolderInfo] = []
            for record in round.records where record.odataType != Self.mailSearchFolderType {
                guard record.removed == nil, let folder = known[record.id],
                      let name = record.displayName, let total = record.totalItemCount else {
                    // A new folder, a removed one, or a record without its name and
                    // count: the complete listing decides.
                    let listed = try await completeFolderList(context: allowance.context)
                    return listed.map { (.set(OutlookAccountCursor(folders: round.deltaLink).encoded), .complete($0)) }
                        ?? (.unchanged, nil)
                }
                updates.append(FolderInfo(
                    name: name, path: folder.path, role: folder.role,
                    unreadCount: record.unreadItemCount ?? 0, totalCount: total))
            }
            return (account, .updated(updates))
        }
        return try await mintFolderLinkAndList(allowance: &allowance)
    }

    /// No folder link yet, or a refused one: mint the link FIRST (its whole first
    /// round, whose records the listing supersedes), then list every folder, so a
    /// change made during the listing is in the next round.
    private func mintFolderLinkAndList(allowance: inout ChangeReadAllowance) async throws -> (AccountCursorUpdate, FolderListUpdate?) {
        let round: FolderDeltaRound
        do {
            round = try await readFolderDeltaRound(from: nil, allowance: &allowance)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            BackgroundSyncLogger.logDebug("[Exchange] change read: folder delta link not minted: \(error)")
            return (.unchanged, nil)
        }
        guard let round, let listed = try await completeFolderList(context: allowance.context) else { return (.unchanged, nil) }
        return (.set(OutlookAccountCursor(folders: round.deltaLink).encoded), .complete(listed))
    }

    /// The complete folder tree (`fetchFolders`), bounded so it ends by the read
    /// budget plus one request's timeout. Nil when it could not finish: the full
    /// sync then runs its own discovery.
    private func completeFolderList(context: ChangeContext) async throws -> [FolderInfo]? {
        guard context.hasBudget() else { return nil }
        let seconds = context.secondsLeft + SyncConfig.changeReadRequestTimeoutSeconds
        do {
            return try await withTimeout(seconds: seconds) { try await self.fetchFolders() }
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            BackgroundSyncLogger.logDebug("[Exchange] change read: folder listing failed: \(error)")
            return nil
        }
    }

    /// One whole round of the mail-folder delta, from `link` (nil: a new chain).
    /// Nil when the budget ends before the round does: nothing is stored and the
    /// next read starts it again (a folder round is a few pages).
    private func readFolderDeltaRound(from link: String?, allowance: inout ChangeReadAllowance) async throws -> FolderDeltaRound {
        var records: [GraphDeltaFolder] = []
        var next = link
        var seen = Set<String>()
        while true {
            guard allowance.canSend(1) else { return nil }
            allowance.charge(1)
            let current = next
            let data: Data
            if let current {
                data = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                    try await self.requestAbsolute(url: current)
                }
            } else {
                data = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                    try await self.request(path: "/mailFolders/delta?$select=displayName,unreadItemCount,totalItemCount")
                }
            }
            let page = try JSONDecoder().decode(GraphDeltaResponse<GraphDeltaFolder>.self, from: data)
            records += page.value
            if let deltaLink = page.odataDeltaLink {
                return (records, deltaLink)
            }
            guard let nextLink = page.odataNextLink, seen.insert(nextLink).inserted else {
                throw Self.unreadablePage("folder delta has no next link, or repeats one")
            }
            next = nextLink
        }
    }
}

// MARK: - Bookmarks

/// The account part of an Outlook change bookmark (`Account.lastHistoryId`):
/// `{"v":1,"folders":"<mail-folder delta link>"}`. Anything else stored there
/// (an older build's Inbox delta link) reads as no bookmark.
struct OutlookAccountCursor: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var v = OutlookAccountCursor.currentVersion
    let folders: String

    init(folders: String) { self.folders = folders }

    init?(raw: String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(OutlookAccountCursor.self, from: data),
              decoded.v == Self.currentVersion else { return nil }
        self = decoded
    }

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self), let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("OutlookAccountCursor always encodes")
        }
        return text
    }
}

/// One folder's Outlook change bookmark (`Folder.changeCursor`).
struct OutlookFolderCursor: Codable, Equatable, Sendable {
    static let currentVersion = 1

    enum Phase: String, Codable, Sendable {
        /// The chain's first round: every message in the folder.
        case baseline
        /// Later rounds: what changed since the last one.
        case tracking
    }

    enum Selection: String, Codable, Sendable {
        /// The header fields (`ExchangeGraphMessageRequest.readChanges`, the Inbox).
        case header
        /// `GraphAPI.stateSelection` (every other folder).
        case state

        var selection: GraphMessageSelection {
            switch self {
            case .header: return ExchangeGraphMessageRequest.readChanges.selection
            case .state: return GraphAPI.stateSelection
            }
        }
    }

    var v = OutlookFolderCursor.currentVersion
    var phase: Phase
    var select: Selection
    /// The link to read next: a baseline's next page, a round's next page, or the
    /// delta link of the last completed round. Nil = page 1 of a new chain.
    var next: String?
    /// Pages read in the current round.
    var roundPages = 0
    /// The first counted failure since the folder's last good page.
    var failingSince: Date?
    /// When the folder first needed this baseline; an expensive network holds a
    /// state baseline back for at most `SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds`
    /// from here.
    var baselineSince: Date

    static func fresh(role: FolderRole, now: Date) -> OutlookFolderCursor {
        OutlookFolderCursor(phase: .baseline, select: role == .inbox ? .header : .state, baselineSince: now)
    }

    init(phase: Phase, select: Selection, next: String? = nil, roundPages: Int = 0,
         failingSince: Date? = nil, baselineSince: Date) {
        self.phase = phase
        self.select = select
        self.next = next
        self.roundPages = roundPages
        self.failingSince = failingSince
        self.baselineSince = baselineSince
    }

    /// Nil when absent, unreadable or of another version: the folder starts a
    /// new chain.
    init?(raw: String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(OutlookFolderCursor.self, from: data),
              decoded.v == Self.currentVersion else { return nil }
        self = decoded
    }

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self), let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("OutlookFolderCursor always encodes")
        }
        return text
    }

    /// Page 1 of the same baseline, keeping when it was first needed.
    mutating func restartBaseline() {
        next = nil
        roundPages = 0
    }
}

// MARK: - Read state

/// What one read may still send: `SyncConfig.graphChangeReadRequestsPerSecond`
/// times its read budget, and nothing once the budget has ended.
struct ChangeReadAllowance {
    let context: ChangeContext
    private(set) var requestsLeft: Int

    init(context: ChangeContext) {
        self.context = context
        let allowed = (SyncConfig.graphChangeReadRequestsPerSecond * context.secondsLeft).rounded(.down)
        self.requestsLeft = Int(min(allowed, Double(Int.max / 2)))
    }

    func canSend(_ requests: Int) -> Bool { context.hasBudget() && requestsLeft >= requests }

    /// Charged before the requests are sent.
    mutating func charge(_ requests: Int) { requestsLeft -= requests }
}

/// Records and removals collected for one folder, collapsed by message id (the
/// latest wins). A page cut short keeps what it did read: a record never moves
/// the bookmark by itself, so applying it early only saves the next pass a
/// header fetch.
struct CollectedChanges {
    private var order: [String] = []
    private var recordsById: [String: ChangeRecord] = [:]
    private var removed: Set<String> = []

    mutating func add(_ record: ChangeRecord) {
        if recordsById[record.messageId] == nil, !removed.contains(record.messageId) { order.append(record.messageId) }
        removed.remove(record.messageId)
        recordsById[record.messageId] = record
    }

    mutating func remove(_ id: String) {
        if recordsById[id] == nil, !removed.contains(id) { order.append(id) }
        recordsById[id] = nil
        removed.insert(id)
    }

    var records: [ChangeRecord] { order.compactMap { recordsById[$0] } }
    var removals: [String] { order.filter { removed.contains($0) } }
    var answeredIds: Set<String> { Set(recordsById.keys).union(removed) }
}

private enum FolderReadEnding {
    case baselineDone
    case roundDone
    case cut
    case refused(Int)
    case failed(any Error, counted: Bool)
}

private struct DeltaPage {
    let records: [GraphDeltaMessage]
    /// Full headers by id, for a page that carried the header fields.
    let headers: [String: MessageHeaderInfo]
    let nextLink: String?
    let deltaLink: String?
}

private typealias FolderDeltaRound = (records: [GraphDeltaFolder], deltaLink: String)?

/// A message delta record decoded as a full message (the Inbox's selection),
/// or a removal.
private struct GraphDeltaFullMessage: Decodable {
    let removed: GraphRemoved?
    let message: GraphMessage?

    enum CodingKeys: String, CodingKey { case removed = "@removed" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        removed = try container.decodeIfPresent(GraphRemoved.self, forKey: .removed)
        message = removed == nil ? try GraphMessage(from: decoder) : nil
    }
}
