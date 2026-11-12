/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - Catch-up of older mail: the generic apply path (ADR-IOS-107)
//
// The full sync's end-of-pass step. It asks the provider ONCE for every syncable
// folder's catch-up (`EmailProvider.catchUp`) and applies the provider-blind results
// through the paths the rest of sync already uses:
//   - read/flag updates: the merge rule of `runSyncMessages` (provider-address
//     ownership proven; a queued flag op or a recent completion wins);
//   - removals: `deleteConfirmedGhostHeaders`, the ONE removal path every
//     server-confirmed deletion takes;
//   - the provider's new opaque state, in the SAME transaction as the flag updates
//     and removals, so a crash resumes from the last write.
//   - messages the provider fetched for ids the server lists in the folder that no
//     row holds (the direct load): the backfill page walk's own insert tail
//     (`insertFetchedBackfillMessages`), BEFORE the state is written; if any of
//     them did not land, nothing is written.
// *Superseded (2026-11-12, the direct load):* "It changes or removes only rows the
// device already holds. It never inserts: new mail is the ordinary sync's job and
// older mail is the backfill's. When the provider reports mail inside the folder's
// local range that no row holds (an old message moved in), the same transaction
// re-arms the folder's backfill walk, unless a storage limit is in force." The
// catch-up never writes the walk's bookkeeping.
// No provider is named here: the step does the same thing for every provider, and a
// provider without catch-up returns nothing.

/// What applying one folder's result did.
enum CatchUpApplyOutcome: Sendable, Equatable {
    /// Applied, with the state written in the same transaction.
    case applied(updatedFlags: Int, removedIds: [String])
    /// Nothing written: the folder is gone or quarantined, its epoch is unknown or
    /// unproven for this result, or the write failed (a write of the loaded
    /// messages included). The
    /// provider redoes the work from its previous state on a later pass.
    case skipped
    /// The provider was served a different epoch than the folder's stored one.
    /// Nothing written; the turnover reaction is fired.
    case turnover(accountId: String, folderPath: String, stored: UInt32, observed: UInt32)
}

/// `CatchUpLocalRowReader` over the sync database: ids and the two flags, never
/// content (ADR-004). Every query is bounded by a range, an id list or a limit.
struct SyncEngineCatchUpRowReader: CatchUpLocalRowReader {
    let pool: PrioritizedDatabase

    private static let columns = "messageId, isRead, isFlagged"

    private static func localRow(_ row: Row) -> CatchUpLocalRow {
        CatchUpLocalRow(messageId: row["messageId"], isRead: row["isRead"], isFlagged: row["isFlagged"])
    }

    /// Served by the v66 `(folderId, CAST(messageId AS INTEGER))` expression index.
    func rows(folderId: String, numericIdsFrom lower: Int, through upper: Int) async throws -> [CatchUpLocalRow] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM messageHeader
                WHERE folderId = ? AND CAST(messageId AS INTEGER) BETWEEN ? AND ?
                ORDER BY CAST(messageId AS INTEGER)
                """, arguments: [folderId, lower, upper]).map(Self.localRow)
        }
    }

    func firstNumericId(folderId: String, atLeast lower: Int) async throws -> Int? {
        try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT MIN(CAST(messageId AS INTEGER)) FROM messageHeader
                WHERE folderId = ? AND CAST(messageId AS INTEGER) >= ?
                """, arguments: [folderId, lower])
        }
    }

    func rows(folderId: String, ids: [String]) async throws -> [CatchUpLocalRow] {
        guard !ids.isEmpty else { return [] }
        return try await pool.read { db in
            var rows: [CatchUpLocalRow] = []
            let chunkSize = SyncConfig.sqlChunkSize
            for start in stride(from: 0, to: ids.count, by: chunkSize) {
                let chunk = Array(ids[start..<min(start + chunkSize, ids.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                rows += try Row.fetchAll(db, sql: """
                    SELECT \(Self.columns) FROM messageHeader
                    WHERE folderId = ? AND messageId IN (\(placeholders))
                    """, arguments: StatementArguments([folderId] + chunk)).map(Self.localRow)
            }
            return rows
        }
    }

    /// Served by the v64 `(folderId, messageId)` index.
    func rows(folderId: String, after afterId: String?, limit: Int) async throws -> [CatchUpLocalRow] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM messageHeader
                WHERE folderId = ? AND (? IS NULL OR messageId > ?)
                ORDER BY messageId LIMIT ?
                """, arguments: [folderId, afterId, afterId, limit]).map(Self.localRow)
        }
    }

    private static func datedRow(_ row: Row) -> CatchUpLocalRow {
        var local = localRow(row)
        local.orderDate = row["providerDate"]
        return local
    }

    /// Served by the v91 `(folderId, providerDate)` index. `providerDate` is NOT
    /// NULL, so no row falls out of a bound by SQL's three-valued logic.
    func rows(folderId: String, orderDatesFrom lower: Date, before upper: Date) async throws -> [CatchUpLocalRow] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns), providerDate FROM messageHeader
                WHERE folderId = ? AND providerDate >= ? AND providerDate < ?
                ORDER BY providerDate, messageId
                """, arguments: [folderId, lower, upper]).map(Self.datedRow)
        }
    }

    /// Served by the same index, scanned backwards.
    func newestRows(folderId: String, orderDatesBefore upper: Date?, limit: Int) async throws -> [CatchUpLocalRow] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns), providerDate FROM messageHeader
                WHERE folderId = ? AND (? IS NULL OR providerDate < ?)
                ORDER BY providerDate DESC, messageId DESC LIMIT ?
                """, arguments: [folderId, upper, upper, limit]).map(Self.datedRow)
        }
    }
}

extension SyncEngine {

    /// The full sync's catch-up step. `folderIds` are the pass's syncable folders,
    /// re-read here so the provider sees this pass's STATUS values and epochs.
    /// Never throws: a failure costs this pass's catch-up, never the full sync, and
    /// it cannot trigger the full sync's connection-error retry (which would double
    /// the hold). `context` defaults to the production snapshot taken right now,
    /// first, before anything else: the network state and whether a storage limit
    /// is in force are read once and hold for the whole step.
    func runCatchUp(provider: any EmailProvider, folderIds: [String], context: CatchUpContext? = nil) async {
        let context = context ?? .forPass(
            isExpensiveNetwork: NetworkMonitor.checkExpensive(),
            storageLimitInForce: StorageEstimator.budgetMB != Int.max)
        let ids = folderIds
        let folders: [Folder]
        do {
            let rows = try await dbPool.read { db in try Folder.filter(keys: ids).fetchAll(db) }
            let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            folders = ids.compactMap { byId[$0] }
        } catch {
            BackgroundSyncLogger.logDebug("[CatchUp] folder read failed: \(error)")
            return
        }
        guard !folders.isEmpty else { return }

        let results = await provider.catchUp(
            folders: folders, localRows: SyncEngineCatchUpRowReader(pool: dbPool), context: context)
        let windowMode = provider.staleWindowMode
        for result in results {
            await applyCatchUpResult(result, windowMode: windowMode)
        }
    }

    /// Apply one folder's catch-up result: first the messages the provider loaded
    /// (`result.loaded`), through the backfill page walk's insert tail; then ONE
    /// write transaction for the flag updates, the removals and the new state.
    /// The loads go first so the state that moves the listing past them is never
    /// written without them: a crash in between lists them again, and the insert
    /// skips what is already there. A load that did not land (a write chunk
    /// failed, or the folder could take nothing) writes nothing at all, the
    /// state included: the listing stays where it was and the provider lists
    /// those ranges again on a later pass.
    @discardableResult
    func applyCatchUpResult(_ result: CatchUpFolderResult, windowMode: StaleWindowMode) async -> CatchUpApplyOutcome {
        let folderId = result.folderId
        if !result.loadFailures.isEmpty && DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): \(result.loadFailures.count) missing id(s) did not load: \(result.loadFailures.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        }
        if !result.loaded.isEmpty, !(await insertCatchUpLoads(result)) {
            BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): \(result.loaded.count) loaded message(s) did not all land — nothing written, the listing stays where it was")
            return .skipped
        }

        let outcome: CatchUpApplyOutcome
        do {
            outcome = try await dbPool.write { db in
                try Self.applyCatchUpTransaction(result, windowMode: windowMode, db: db)
            }
        } catch {
            BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): apply failed: \(error)")
            return .skipped
        }

        switch outcome {
        case .applied(let updatedFlags, let removedIds):
            if !removedIds.isEmpty { removeHeadersFromFTS(removedIds) }
            if updatedFlags > 0 || !removedIds.isEmpty {
                await UnreadCountManager.shared.requestRecount(folderId: folderId)
            }
            BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): applied flags=\(updatedFlags) removed=\(removedIds.count)")
        case .turnover(let accountId, let folderPath, let stored, let observed):
            // The "stop" half is the transaction writing nothing; this is the
            // "recover" half, exactly as the deletion-reconcile walk does it.
            AccountManager.shared.fireUidValidityChangeHandler(
                accountId: accountId, folderPath: folderPath, storedValue: stored, observedValue: observed)
        case .skipped:
            break
        }
        return outcome
    }

    /// The direct load's insert: the loaded messages go into the folder through the
    /// page walk's own insert tail, read with the folder as it is now. A folder
    /// that is gone or quarantined gets nothing; its transaction below writes
    /// nothing either, so the provider lists the same ids again later. True only
    /// when every write chunk landed.
    private func insertCatchUpLoads(_ result: CatchUpFolderResult) async -> Bool {
        let folderId = result.folderId
        guard let folder = try? await dbPool.read({ db in try Folder.fetchOne(db, key: folderId) }),
              folder.uidValidityResetPendingAt == nil else { return false }
        let headers = result.loaded.compactMap(\.header)
        let bodies = Dictionary(
            result.loaded.map { ($0.id, (htmlBody: $0.htmlBody, textBody: $0.textBody)) },
            uniquingKeysWith: { first, _ in first })
        let insert = await insertFetchedBackfillMessages(headers, bodies: bodies, folder: folder)
        BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): loaded \(headers.count) missing message(s), inserted \(insert.inserted)")
        return insert.allLanded
    }

    /// A delta-cursor lapse, inside the caller's write transaction: the account's
    /// cursor (`Account.lastHistoryId`) becomes `newCursor` (nil clears it) and every
    /// one of the account's folders gets the lapse marker in its catch-up state
    /// (`CatchUpLapse`: the count under `CatchUpLapse.countKey` goes up by one).
    /// Both or neither: the changes the lost history held reach no delta, and the
    /// marker makes the provider list each folder again, in full, once the listing
    /// in progress (if any) completes. The marker never clears the state, so a
    /// listing in progress keeps its place and a folder keeps its schedule (the
    /// expensive-network wait is not restarted). A NULL state stays NULL: no state
    /// already means a full check is due. A state that is not a JSON object
    /// becomes NULL, the same start. Used wherever a cursor is cleared or replaced
    /// by one the delta did not reach. Provider-blind: the cursor column and the
    /// marker are the same for every provider that has a delta cursor. It runs
    /// under the account's one-sync-at-a-time lock, as the catch-up does, so no
    /// catch-up of the account reads a state before a lapse and writes it after.
    nonisolated static func lapseDeltaCursor(accountId: String, newCursor: String?, db: Database) throws {
        try db.execute(sql: "UPDATE account SET lastHistoryId = ? WHERE id = ?", arguments: [newCursor, accountId])
        // CASE evaluates lazily: the JSON functions only see valid JSON objects.
        try db.execute(sql: """
            UPDATE folder SET catchUpState = CASE
                WHEN json_valid(catchUpState) THEN CASE
                    WHEN json_type(catchUpState) = 'object' THEN json_set(
                        catchUpState, '$.' || ?, COALESCE(json_extract(catchUpState, '$.' || ?), 0) + 1)
                    ELSE NULL END
                ELSE NULL END
            WHERE accountId = ? AND catchUpState IS NOT NULL
            """, arguments: [CatchUpLapse.countKey, CatchUpLapse.countKey, accountId])
    }

    /// The transaction itself. Everything it decides on is read INSIDE it: the folder
    /// row (quarantine, epoch), the pending operations and the recent completions.
    nonisolated static func applyCatchUpTransaction(
        _ result: CatchUpFolderResult, windowMode: StaleWindowMode, db: Database
    ) throws -> CatchUpApplyOutcome {
        guard let folder = try Folder.fetchOne(db, key: result.folderId),
              folder.uidValidityResetPendingAt == nil else { return .skipped }

        // Epoch gate (C3: never act under an unknown or turned-over epoch). The ids
        // belong to `result.epoch`; they may be applied only to a folder whose rows
        // belong to that same, known epoch.
        let stored = knownUidValidity(folder.lastKnownUidValidity).flatMap { UInt32(exactly: $0) }
        if let stored, let observed = result.epoch, stored != observed {
            return .turnover(accountId: folder.accountId, folderPath: folder.path, stored: stored, observed: observed)
        }
        guard stored == result.epoch else { return .skipped }
        if windowMode == .uid && result.epoch == nil { return .skipped }

        // The merge rule of `runSyncMessages`: a queued flag op from this folder, or
        // a recent completion, beats the server's value (the user's newer action wins).
        let pendingFlags = PendingOperationSnapshot(ops: try PendingOperation.fetchAll(db).filter {
            $0.accountId == folder.accountId && $0.folderPath == folder.path
        }).flag
        let recentlyCompleted = AccountManager.shared.liveRecentlyCompleted()
        let sourceBoundEpoch = result.epoch.flatMap { Int(exactly: $0) }

        var updatedFlags = 0
        for update in result.flagUpdates {
            let canonicalId = MessageIdentity.headerId(
                accountId: folder.accountId, folderPath: folder.path, messageId: update.messageId)
            guard var row = try MessageHeader.fetchOne(db, key: canonicalId),
                  providerAddressOwnershipProven(
                    row: row, accountId: folder.accountId, folderPath: folder.path,
                    folderId: folder.id, messageId: update.messageId, canonicalId: canonicalId,
                    windowMode: windowMode, sourceBoundEpoch: sourceBoundEpoch) else { continue }
            if pendingFlags.containsAnyKey(messageId: row.messageId, rfc822MessageId: row.rfc822MessageId) { continue }
            if recentlyCompleted[row.messageId] != nil
                || (row.rfc822MessageId.map { recentlyCompleted[$0] != nil } ?? false) { continue }
            let original = row
            row.isRead = update.isRead
            row.isFlagged = update.isFlagged
            if try row.updateChanges(db, from: original) { updatedFlags += 1 }
        }

        let removedIds = try deleteConfirmedGhostHeaders(
            folderId: folder.id, folderPath: folder.path, accountId: folder.accountId,
            folderRole: folder.role, ids: result.removedIds,
            recentlyCompleted: recentlyCompleted, db: db)

        // Mail the server lists that no row holds was loaded before this
        // transaction (`insertCatchUpLoads`); the walk's bookkeeping is never
        // written here. *Superseded (2026-11-12, the direct load):* the re-arm of
        // a completed walk (`backfillComplete = 0, backfillPageToken = NULL,
        // backfillPageHeldSince = NULL` with the state), declined for an
        // unfinished walk and while a storage limit was in force.
        try db.execute(
            sql: "UPDATE folder SET catchUpState = ? WHERE id = ?",
            arguments: [result.newState, folder.id])
        return .applied(updatedFlags: updatedFlags, removedIds: removedIds)
    }
}
