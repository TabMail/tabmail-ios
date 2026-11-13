/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - The change pass (ADR-IOS-111)
//
// One provider-blind pass: build the request once, ask the provider what changed
// (`EmailProvider.fetchChanges`), apply the answer with one generic apply
// (`SyncEngineChangesApply.swift`), then store the bookmark. Nothing in this file
// knows which provider it talks to: no cast to a concrete provider and no test of
// the account's provider (source fence in `ChangeSeamFenceTests`).
//
// Order of one pass:
// 1. the request, when the pass's turn starts: every folder of the account with
//    its own bookmark, the scope, the re-read lists (at most
//    `SyncConfig.changeRereadBudgetPerPass` distinct ids), the network and the
//    read budget, which ends early enough for what is read to be applied before
//    the caller's deadline (`changeReadEnd`); a turn with no budget left reads
//    nothing and keeps every bookmark;
// 2. the read;
// 3. a refused account bookmark: one transaction clears it, marks every folder
//    untracked, marks a lapse for the catch-up and makes the full sync due; then
//    the SAME pass reads again without a bookmark, for a candidate taken before
//    its listings. A refused FOLDER bookmark touches that folder only, in its own
//    transaction (step 5);
// 4. the folder list (one transaction);
// 5. one write transaction per folder (shields read inside it), with the
//    folder's own bookmark;
// 6. reply-parent notifications, search, body queue, unread recount;
// 7. the account bookmark, last, in its own transaction (a crash before it
//    replays the same changes, which the apply takes idempotently).
// A candidate bookmark (`.candidate`) is not stored here: the foreground pass
// stores it after its listings (`commitChangeBaseline`); a folder the full sync
// dropped stays untracked and the full sync stays due, so the next foreground
// pass lists it.

/// The engine-owned, provider-blind change state of one folder
/// (`Folder.changeState`). Message ids only (ADR-004).
struct FolderChangeState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var v: Int = FolderChangeState.currentVersion
    /// The provider's change bookmark covers this folder: the full sync's window
    /// listing skips it. Turned on only after a window listing that finished in
    /// a pass whose read covered the folder; turned off by a refusal.
    var tracking: Bool = false
    /// Message ids a change was declined for under the user's own action, read
    /// again on later passes, at most `SyncConfig.changeRereadBudgetPerPass` per
    /// pass and in turn, until the change applies (cap
    /// `SyncConfig.changeRecheckLimit`).
    var recheck: [String] = []

    init(tracking: Bool = false, recheck: [String] = []) {
        self.tracking = tracking
        self.recheck = recheck
    }

    /// The stored JSON; unreadable or absent = the untracked default.
    init(raw: String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FolderChangeState.self, from: data) else {
            self.init()
            return
        }
        self = decoded
    }

    /// The JSON to store; nil for the default (untracked, nothing to re-read).
    var encoded: String? {
        guard tracking || !recheck.isEmpty,
              let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// What one change pass did, for the foreground pass that ran it.
struct ChangePassOutcome: Sendable {
    /// The pass ran through a change reader (false: the provider's remaining
    /// delta path, which still captures its cursor after the full sync).
    var fromReader = false
    /// The read completed: the account bookmark advanced, or needed no write.
    var succeeded = false
    /// The turn started with no read budget left: nothing was read.
    var outOfTime = false
    /// Rows were written.
    var hadChanges = false
    /// The read carried the folder list and it was applied (the MODSEQ-skippable
    /// paths), so the full sync skips its own discovery.
    var appliedFolderList: Set<String>?
    /// A candidate bookmark, stored after the foreground pass's listings.
    var candidate: String?
    /// Folders the read covered (`.tracked` or `.baselineReady`).
    var trackableFolderIds: Set<String> = []
    /// The folders need a listing in this pass (a refusal, a candidate or a
    /// completed baseline).
    var needsListing = false
}

extension SyncEngine {

    /// Read and apply the provider's changes. Nil = the provider has no change
    /// reader; the caller keeps that provider's remaining change path.
    /// - Parameter deadline: the caller's own deadline for the whole pass (its
    ///   timeout), or nil when the caller sets none. It is not account sync state.
    func readAndApplyChanges(
        account: Account, provider: any EmailProvider, scope: ChangeScope, deadline: Date? = nil
    ) async throws -> ChangePassOutcome? {
        let accountId = account.id
        let request = try await makeChangeRequest(accountId: accountId, scope: scope, deadline: deadline)
        let outOfTime = !request.context.hasBudget()
        guard let firstRead = try await provider.fetchChanges(
            since: ChangeCursor(account: account.lastHistoryId), request: request) else { return nil }

        var changeSet = firstRead
        var refused = false
        if firstRead.isRefused {
            BackgroundSyncLogger.logDebug("[Sync] Change read refused for \(account.emailAddress) — re-listing in this pass")
            try await dbPool.write { db in try Self.applyChangeRefusal(accountId: accountId, db: db) }
            refused = true
            // The same pass reads again with no bookmark: the candidate is taken
            // BEFORE this pass's listings, so nothing made during them is lost.
            // The folder list was read already.
            let reread = ChangeRequest(
                folders: request.folders, scope: .inboxOnly, recheck: request.recheck,
                context: request.context, localRows: request.localRows)
            if var again = try await provider.fetchChanges(since: ChangeCursor(account: nil), request: reread) {
                again.folderList = again.folderList ?? firstRead.folderList
                changeSet = again
            } else {
                changeSet = ChangeSet(account: .keep, folderList: firstRead.folderList, folders: [])
            }
        }
        var outcome = try await applyChangeSet(changeSet, account: account, request: request)
        outcome.needsListing = outcome.needsListing || refused
        outcome.outOfTime = outOfTime
        if outOfTime {
            BackgroundSyncLogger.logDebug("[Sync] Change read for \(account.emailAddress): no read budget left when the turn started — read nothing")
        }
        return outcome
    }

    /// The end of a pass's read budget, from the start of its turn: the smaller of
    /// `SyncConfig.changeReadBudgetSeconds` and the caller's deadline less one
    /// request's timeout and the apply margin (the arithmetic is beside the
    /// constants in `SyncConfig`). A request may start only before it, so the
    /// last one is given up by `deadline - changeReadApplyMarginSeconds` and what
    /// was read is applied before the caller stops waiting. At or before
    /// `turnStart` the pass reads nothing.
    nonisolated static func changeReadEnd(turnStart: Date, callerDeadline: Date?) -> Date {
        let cap = turnStart.addingTimeInterval(SyncConfig.changeReadBudgetSeconds)
        guard let callerDeadline else { return cap }
        let lastStart = callerDeadline.addingTimeInterval(
            -(SyncConfig.changeReadRequestTimeoutSeconds + SyncConfig.changeReadApplyMarginSeconds))
        return min(cap, lastStart)
    }

    /// Built ONCE when the pass's turn starts (snapshot rule).
    private func makeChangeRequest(accountId: String, scope: ChangeScope, deadline: Date?) async throws -> ChangeRequest {
        let folders = try await dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId).fetchAll(db)
        }
        let readEnd = Self.changeReadEnd(turnStart: Date(), callerDeadline: deadline)
        let synced = Set(syncableFoldersInOrder(folders).map(\.id))
        // At most `SyncConfig.changeRereadBudgetPerPass` distinct ids are read
        // again in one pass, so full re-read lists never push a pass past the
        // background deadline. The ids not asked for stay on their lists for a
        // later pass (the apply drops only ids that applied).
        let lists = folders.map { FolderChangeState(raw: $0.changeState).recheck }
        let chosen = Self.rereadIdsWithinBudget(lists, budget: SyncConfig.changeRereadBudgetPerPass)
        var recheck: [String: [String]] = [:]
        for (folder, ids) in zip(folders, lists) {
            let asked = ids.filter(chosen.contains)
            if !asked.isEmpty { recheck[folder.id] = asked }
        }
        let context = ChangeContext(
            deadline: readEnd, clock: { Date() }, isExpensiveNetwork: NetworkMonitor.checkExpensive(),
            onProgress: { count in
                guard count > 0 else { return }
                Task { @MainActor in
                    AccountManagerState.shared.setSyncPhase(.downloading(count), forAccount: accountId)
                }
            })
        return ChangeRequest(
            folders: folders.map {
                ChangeFolder(
                    id: $0.id, path: $0.path, role: $0.role, cursor: $0.changeCursor,
                    isSynced: synced.contains($0.id), heldSince: $0.oldestSyncedDate)
            },
            scope: scope, recheck: recheck, context: context,
            localRows: SyncEngineCatchUpRowReader(pool: dbPool))
    }

    /// The distinct ids one pass reads again: the folders' lists taken in turn,
    /// position by position from the front, until `budget` ids are chosen, so no
    /// folder's list starves another's. With the apply putting an id it keeps back
    /// again at the back of its list, every id gets its turn.
    nonisolated static func rereadIdsWithinBudget(_ lists: [[String]], budget: Int) -> Set<String> {
        var chosen = Set<String>()
        var position = 0
        while chosen.count < budget, lists.contains(where: { $0.count > position }) {
            for list in lists where list.count > position {
                chosen.insert(list[position])
                if chosen.count == budget { return chosen }
            }
            position += 1
        }
        return chosen
    }

    /// The account refusal handler, ONE transaction: the account bookmark
    /// cleared, every folder untracked, a lapse marked for each folder's catch-up
    /// (one whole-folder check of older mail, ADR-IOS-107) and the full sync made
    /// due. A refused FOLDER bookmark is handled in that folder's transaction
    /// (`applyFolderChanges`) and touches no other folder.
    nonisolated static func applyChangeRefusal(accountId: String, db: Database) throws {
        try lapseDeltaCursor(accountId: accountId, newCursor: nil, db: db)
        let folders = try Folder.filter(Column("accountId") == accountId).fetchAll(db)
        for folder in folders {
            var state = FolderChangeState(raw: folder.changeState)
            guard state.tracking else { continue }
            state.tracking = false
            try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [state.encoded, folder.id])
        }
        try db.execute(sql: "UPDATE account SET lastFullSyncAt = NULL WHERE id = ?", arguments: [accountId])
    }

    private func applyChangeSet(_ changeSet: ChangeSet, account: Account, request: ChangeRequest) async throws -> ChangePassOutcome {
        let accountId = account.id
        var outcome = ChangePassOutcome()
        outcome.fromReader = true

        switch changeSet.folderList {
        case .complete(let folderList):
            outcome.appliedFolderList = try await dbPool.write { db in
                try Self.applyFolderList(folderList, account: account, db: db)
            }
        case .updated(let updates):
            // Folders already stored, matched by path: nothing to add or remove,
            // so the full sync's own discovery is not needed either.
            try await dbPool.write { db in try Self.applyFolderUpdates(updates, accountId: accountId, db: db) }
            outcome.appliedFolderList = []
        case nil:
            break
        }

        var newHeaders: [MessageHeader] = []
        var removedIds: [String] = []
        var discoveredParents: [String] = []
        var failures: [any Error] = []
        var readFolders = 0
        var wroteRows = false
        for changes in changeSet.folders {
            if changes.status.isTrackable { outcome.trackableFolderIds.insert(changes.folderId) }
            switch changes.status {
            case .failed(let error): failures.append(error)
            case .refused, .baselineReady: outcome.needsListing = true
            case .tracked, .baselining, .notRun: break
            }
            if case .notRun = changes.status {} else { readFolders += 1 }
            // A folder with only a message to read later still writes: its re-read
            // list is the only place that message's change survives the bookmark
            // move. So does a folder whose own bookmark or coverage changed.
            guard !changes.records.isEmpty || !changes.removals.isEmpty || !changes.rereadLater.isEmpty
                || changes.cursor != nil || changes.status.changesFolderCoverage else { continue }
            let applied = try await dbPool.write { db in try Self.applyFolderChanges(changes, db: db) }
            newHeaders += applied.newHeaders
            removedIds += applied.removedIds
            discoveredParents += applied.discoveredParents
            wroteRows = wroteRows || applied.wroteRows
            if applied.armedCatchUp {
                BackgroundSyncLogger.logDebug("[Sync] Change apply: re-read list full for folder \(changes.folderId.suffix(12)) — catch-up armed")
            }
        }

        ReplyParentResolver.postParentNotifications(discoveredParents)
        if !removedIds.isEmpty {
            removeHeadersFromFTS(removedIds)
            BackgroundSyncLogger.logDebug("[Sync] Change apply: removed \(removedIds.count) rows")
        }
        if wroteRows {
            // Once, after every row write is committed, before search and bodies.
            await UnreadCountManager.shared.requestRecount(folderIds: Set(request.folders.map(\.id)))
        }
        if !newHeaders.isEmpty {
            await indexHeadersForFTS(newHeaders)
            BackgroundSyncLogger.logDebug("[Sync] Change apply: +\(newHeaders.count) new messages")
            await ActiveBodyQueue.shared.enqueueBatch(newHeaders)
        }

        // The rows the read did get are applied and every bookmark that moved is
        // stored with them. The pass fails only when every folder it read failed
        // (a reader whose read is one call for the whole account fails them all
        // alike); one folder's failure never holds back the others.
        if let failure = failures.first, failures.count == readFolders { throw failure }

        outcome.hadChanges = wroteRows
        switch changeSet.account {
        case .set(let cursor):
            try await dbPool.write { db in
                _ = try Account.filter(Column("id") == accountId)
                    .updateAll(db, Column("lastHistoryId").set(to: cursor))
            }
            outcome.succeeded = true
        case .unchanged:
            outcome.succeeded = true
        case .clear:
            // Only a second read can say this: the refusal is already applied.
            outcome.needsListing = true
        case .candidate(let candidate):
            outcome.candidate = candidate
            outcome.needsListing = true
            try await dbPool.write { db in
                try db.execute(sql: "UPDATE account SET lastFullSyncAt = NULL WHERE id = ?", arguments: [accountId])
            }
        case .keep:
            break
        }
        return outcome
    }

    /// Names and counts of folders already stored, matched by path, column by
    /// column (`updateChanges`, which bumps no backfill version; ADR-IOS-107). A
    /// path not stored is ignored: adding and removing folders is the complete
    /// list's job.
    nonisolated static func applyFolderUpdates(_ updates: [FolderInfo], accountId: String, db: Database) throws {
        for info in updates {
            guard var folder = try Folder
                .filter(Column("accountId") == accountId && Column("path") == info.path)
                .fetchOne(db) else { continue }
            let original = folder
            folder.name = info.name
            folder.totalCount = info.totalCount
            _ = try folder.updateChanges(db, from: original)
        }
    }

    /// After the foreground pass's full sync (its listings and its catch-up):
    /// - every folder whose window listing finished in this pass, and which this
    ///   pass's read covered, becomes tracked;
    /// - a candidate bookmark is stored, WITHOUT a lapse mark: it was read before
    ///   the listings, so nothing between them is lost, and the catch-up is not
    ///   asked to list again (#783). It is stored also when the full sync
    ///   dropped a folder (`FullSyncListing.droppedFolder`: a lost connection
    ///   stops the listing there, so that folder and every later one; a failed
    ///   retry or SELECT, that folder). Those folders stay untracked and the
    ///   caller keeps the full sync due, so the next foreground pass lists them;
    ///   their changes after the candidate arrive by the reads from the bookmark
    ///   (an account-wide reader names every folder, and a full record inserts a
    ///   message the folder does not hold yet). A listing that fails any other
    ///   way (an HTTP status, an answer that cannot be decoded) fails the whole
    ///   pass before this runs, and nothing is stored.
    func commitChangeBaseline(account: Account, outcome: ChangePassOutcome, listedFolderIds: Set<String>) async throws {
        let accountId = account.id
        let nowTracked = outcome.trackableFolderIds.intersection(listedFolderIds)
        try await dbPool.write { db in
            if let candidate = outcome.candidate {
                _ = try Account.filter(Column("id") == accountId)
                    .updateAll(db, Column("lastHistoryId").set(to: candidate))
            }
            for folderId in nowTracked {
                guard let folder = try Folder.fetchOne(db, key: folderId) else { continue }
                var state = FolderChangeState(raw: folder.changeState)
                guard !state.tracking else { continue }
                state.tracking = true
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [state.encoded, folderId])
            }
        }
        if outcome.candidate != nil {
            BackgroundSyncLogger.logDebug("[Sync] Candidate bookmark stored for \(account.emailAddress); \(nowTracked.count) listed folder(s) now tracked")
        }
    }
}

extension ChangeSet {
    /// A read that refused the ACCOUNT bookmark. A folder's own refused bookmark
    /// is that folder's alone (`applyFolderChanges`).
    var isRefused: Bool { account == .clear }
}

extension FolderChangeStatus {
    /// The status itself changes the folder's change state, so its transaction
    /// runs even with no records: a refusal clears its bookmark and coverage, and
    /// a baseline in progress or just completed is not covered yet (a coverage
    /// flag left on by a reset that raced a pass is cleared here).
    var changesFolderCoverage: Bool {
        switch self {
        case .refused, .baselining, .baselineReady: return true
        case .tracked, .failed, .notRun: return false
        }
    }
}
