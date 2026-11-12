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
// the account's provider (source fence F1).
//
// Order of one pass:
// 1. the request: every folder of the account, the scope, the re-read lists;
// 2. the read;
// 3. a refused bookmark: one transaction clears it, marks every folder untracked,
//    marks a lapse for the catch-up and makes the full sync due; then the SAME pass
//    reads again without a bookmark, for a candidate taken before its listings;
// 4. the folder list (one transaction);
// 5. one write transaction per folder (shields read inside it);
// 6. reply-parent notifications, search, body queue, unread recount;
// 7. the bookmark, last, in its own transaction (a crash before it replays the
//    same changes, which the apply takes idempotently).
// A candidate bookmark (`.candidate`) is not stored here: the foreground pass
// stores it once the folders are listed (`commitChangeBaseline`).

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
    /// again on every pass until the change applies (cap
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
    /// The read completed and the bookmark advanced.
    var succeeded = false
    /// Rows were written.
    var hadChanges = false
    /// The read carried the folder list and it was applied (the MODSEQ-skippable
    /// paths), so the full sync skips its own discovery.
    var appliedFolderList: Set<String>?
    /// A candidate bookmark, stored once the folders are listed.
    var candidate: String?
    /// Folders the read covered (`.tracked` or `.baselineReady`).
    var trackableFolderIds: Set<String> = []
    /// The folders need a listing in this pass (a refusal or a candidate).
    var needsListing = false
}

extension SyncEngine {

    /// Read and apply the provider's changes. Nil = the provider has no change
    /// reader; the caller keeps that provider's remaining change path.
    func readAndApplyChanges(account: Account, provider: any EmailProvider, scope: ChangeScope) async throws -> ChangePassOutcome? {
        let accountId = account.id
        let request = try await makeChangeRequest(accountId: accountId, scope: scope)
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
                folders: request.folders, scope: .inboxOnly, recheck: request.recheck, context: request.context)
            if var again = try await provider.fetchChanges(since: ChangeCursor(account: nil), request: reread) {
                again.folderList = again.folderList ?? firstRead.folderList
                changeSet = again
            } else {
                changeSet = ChangeSet(account: .keep, folderList: firstRead.folderList, folders: [])
            }
        }
        var outcome = try await applyChangeSet(changeSet, account: account, request: request)
        outcome.needsListing = outcome.needsListing || refused
        return outcome
    }

    /// Built ONCE at the start of the pass (snapshot rule).
    private func makeChangeRequest(accountId: String, scope: ChangeScope) async throws -> ChangeRequest {
        let folders = try await dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId).fetchAll(db)
        }
        var recheck: [String: [String]] = [:]
        for folder in folders {
            let ids = FolderChangeState(raw: folder.changeState).recheck
            if !ids.isEmpty { recheck[folder.id] = ids }
        }
        let context = ChangeContext(onProgress: { count in
            guard count > 0 else { return }
            Task { @MainActor in
                AccountManagerState.shared.setSyncPhase(.downloading(count), forAccount: accountId)
            }
        })
        return ChangeRequest(
            folders: folders.map { ChangeFolder(id: $0.id, path: $0.path, role: $0.role) },
            scope: scope, recheck: recheck, context: context)
    }

    /// The refusal handler, ONE transaction: the bookmark cleared, every folder
    /// untracked, a lapse marked for each folder's catch-up (one whole-folder
    /// check of older mail, ADR-IOS-107) and the full sync made due.
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

        if let folderList = changeSet.folderList {
            outcome.appliedFolderList = try await dbPool.write { db in
                try Self.applyFolderList(folderList, account: account, db: db)
            }
        }

        var newHeaders: [MessageHeader] = []
        var removedIds: [String] = []
        var discoveredParents: [String] = []
        var failure: (any Error)?
        var wroteRows = false
        for changes in changeSet.folders {
            if changes.status.isTrackable { outcome.trackableFolderIds.insert(changes.folderId) }
            if case .failed(let error) = changes.status, failure == nil { failure = error }
            guard !changes.records.isEmpty || !changes.removals.isEmpty else { continue }
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

        // The rows the read did get are applied; the bookmark stays (replay-safe).
        if let failure { throw failure }

        outcome.hadChanges = wroteRows
        switch changeSet.account {
        case .set(let cursor):
            try await dbPool.write { db in
                _ = try Account.filter(Column("id") == accountId)
                    .updateAll(db, Column("lastHistoryId").set(to: cursor))
            }
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

    /// After the foreground pass's full sync (its listings and its catch-up):
    /// - every folder whose window listing finished in this pass, and which this
    ///   pass's read covered, becomes tracked;
    /// - a candidate bookmark is stored only when every folder that waited for it
    ///   was listed in full. It is stored WITHOUT a lapse mark: it was read before
    ///   the listings, so nothing between them is lost, and the catch-up is not
    ///   asked to list again (#783).
    func commitChangeBaseline(account: Account, outcome: ChangePassOutcome, listedFolderIds: Set<String>, syncableFolderIds: Set<String>) async throws {
        let accountId = account.id
        let waiting = outcome.trackableFolderIds.intersection(syncableFolderIds)
        if outcome.candidate != nil, !waiting.isSubset(of: listedFolderIds) {
            BackgroundSyncLogger.logDebug("[Sync] Candidate bookmark for \(account.emailAddress) not stored: \(waiting.subtracting(listedFolderIds).count) folder(s) not listed")
            return
        }
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
    }

    /// The syncable set the full sync lists (primary, secondary and favourite folders).
    func syncableFolderIds(accountId: String) async throws -> Set<String> {
        let primary = primaryRoles
        let secondary = secondaryRoles
        return try await dbPool.read { db in
            Set(try Folder.filter(Column("accountId") == accountId).fetchAll(db)
                .filter { primary.contains($0.role) || secondary.contains($0.role) || $0.isFavorite }
                .filter { !$0.path.isEmpty }
                .map(\.id))
        }
    }
}

extension ChangeSet {
    /// A read that refused the bookmark.
    var isRefused: Bool {
        if account == .clear { return true }
        return folders.contains { if case .refused = $0.status { return true } else { return false } }
    }
}
