/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - Catch-up of older mail: the generic apply path (ADR-IOS-107)
//
// The backfill worker's step after the folders' walk (#766; before it, the full
// sync's end-of-pass step), run in slices under the account's one-sync-at-a-time
// turn (`runCatchUpRun`). Each slice asks the provider ONCE for every syncable
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

    /// One catch-up run's snapshot (#766): everything the run reads that can
    /// change while it runs, taken once as the run's first step (root rule:
    /// snapshot settings at operation start). Every slice reads only this.
    struct CatchUpRun: Sendable {
        /// Whether the network was expensive (cellular, a hotspot) when the run
        /// started.
        let isExpensiveNetwork: Bool
        /// Whether the Email Index Limit (the storage budget) was finite when the
        /// run started.
        let storageLimitInForce: Bool
        /// The background processing job's deadline: slices run until it. Nil for
        /// a foreground backfill cycle, which runs exactly one slice.
        let deadline: Date?
        /// How long one slice may spend (`SyncConfig.catchUpSliceSeconds`), and the
        /// window the next slice of the account waits for.
        let sliceSeconds: TimeInterval
        /// The gap between the starts of two slices of the account, the pacing
        /// window (`SyncConfig.catchUpSliceIntervalSeconds`, real time).
        let intervalSeconds: TimeInterval
        /// Most requests one slice may send (`SyncConfig.catchUpSliceMaxRequests`).
        var sliceMaxRequests = SyncConfig.catchUpSliceMaxRequests
        /// The clock the slices and the deadline are measured on. Injectable so a
        /// test can spend a slice deterministically; production passes `Date.init`.
        let clock: @Sendable () -> Date

        /// The production snapshot, taken now.
        static func snapshot(deadline: Date?) -> CatchUpRun {
            CatchUpRun(
                isExpensiveNetwork: NetworkMonitor.checkExpensive(),
                storageLimitInForce: StorageEstimator.budgetMB != Int.max,
                deadline: deadline, sliceSeconds: SyncConfig.catchUpSliceSeconds,
                intervalSeconds: SyncConfig.catchUpSliceIntervalSeconds, clock: { Date() })
        }

        /// The context of a slice that starts now: it ends one slice from now, or
        /// at the run's deadline if that comes first. Nil once the deadline has
        /// passed.
        func sliceStartingNow() -> CatchUpContext? {
            let now = clock()
            var end = now.addingTimeInterval(sliceSeconds)
            if let deadline {
                guard now < deadline else { return nil }
                end = min(end, deadline)
            }
            return CatchUpContext(
                isExpensiveNetwork: isExpensiveNetwork, deadline: end, clock: clock,
                storageLimitInForce: storageLimitInForce, maxRequests: sliceMaxRequests)
        }
    }

    /// The catch-up of older mail, run by the backfill worker after the folders'
    /// walk (ADR-IOS-107, #766), in slices. Each slice takes the account's
    /// one-sync-at-a-time turn (`oneSyncAtATime`, ADR-IOS-104), so it never runs
    /// beside a delta, a full sync or a lapse, and releases it at the slice's end,
    /// so a push or silent-push delta that arrives meanwhile waits at most one
    /// slice. The slice's clock starts when its turn starts, never while it waits.
    /// A foreground cycle (`run.deadline == nil`) runs one slice; the background
    /// processing job runs slices until its deadline. Either stops after a slice
    /// that made no progress, so a folder whose requests keep failing is retried at
    /// the next cycle, not at network rate. Generic: a provider without catch-up
    /// returns nothing, and the run stops after one slice. True when a slice made
    /// progress (the worker's `didWork`).
    ///
    /// The request rate: a slice sends at most `run.sliceMaxRequests`, and opens a
    /// window of `run.intervalSeconds` (real time) in `catchUpSliceWindowEnds`; no
    /// slice of the account, from this run or another, starts before the window
    /// ends. The wait happens outside the turn, so a delta is never held by it,
    /// and never reaches past the run's deadline: a window that ends at or after
    /// the deadline ends the run.
    func runCatchUpRun(account: Account, run: CatchUpRun) async -> Bool {
        guard let queue = workQueues[account.id] else { return false }
        let provider = queue.provider
        let accountId = account.id
        var madeProgress = false
        runLoop: while !Task.isCancelled {
            let slice: CatchUpSliceOutcome = await oneSyncAtATime(accountId: accountId) {
                if let end = self.catchUpSliceWindowEnds[accountId], end > Date() {
                    // No slice can start before the run's deadline: the run ends
                    // now rather than wait past it.
                    if let deadline = run.deadline, run.clock().addingTimeInterval(end.timeIntervalSinceNow) >= deadline {
                        return .runOver
                    }
                    return .windowOpen(until: end)
                }
                guard let context = run.sliceStartingNow() else { return .runOver }
                self.catchUpSliceWindowEnds[accountId] = Date().addingTimeInterval(run.intervalSeconds)
                let folderIds: [String]
                do {
                    folderIds = try await self.syncableFolderIds(accountId: accountId)
                } catch {
                    BackgroundSyncLogger.logDebug("[CatchUp] folder read failed: \(error)")
                    return .ran(progressed: false)
                }
                let progressed = (try? await queue.execute(priority: .headerFetch) {
                    await self.runCatchUp(provider: provider, folderIds: folderIds, context: context)
                }) ?? false
                return .ran(progressed: progressed)
            }
            switch slice {
            case .windowOpen(until: let end):
                try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            case .runOver:
                break runLoop
            case .ran(let progressed):
                madeProgress = madeProgress || progressed
                guard progressed, run.deadline != nil else { break runLoop }
            }
        }
        return madeProgress
    }

    /// What one turn of `runCatchUpRun` did.
    private enum CatchUpSliceOutcome {
        /// The account's previous slice window is still open: nothing was sent.
        case windowOpen(until: Date)
        /// The run's deadline has passed, or the account's open window ends at
        /// or after it.
        case runOver
        /// A slice ran; whether an applied result made progress.
        case ran(progressed: Bool)
    }

    /// The account's syncable folders as they are now (`syncableFoldersInOrder`,
    /// the folders the full sync syncs), in the full sync's order.
    private func syncableFolderIds(accountId: String) async throws -> [String] {
        let folders = try await dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId).fetchAll(db)
        }
        return syncableFoldersInOrder(folders).map(\.id)
    }

    /// One slice of the catch-up. `folderIds` are the syncable folders, re-read
    /// here so the provider sees their latest STATUS values and epochs. Never
    /// throws: a failure costs this slice. `context` comes from the run's snapshot
    /// (`CatchUpRun`): the network state and whether a storage limit is in force
    /// were read once, when the run started. True when a folder's applied result
    /// made progress (`CatchUpFolderResult.madeProgress`).
    /// *Superseded (#766):* "The full sync's catch-up step [...] `context` defaults
    /// to the production snapshot taken right now".
    @discardableResult
    func runCatchUp(provider: any EmailProvider, folderIds: [String], context: CatchUpContext) async -> Bool {
        let ids = folderIds
        let folders: [Folder]
        do {
            let rows = try await dbPool.read { db in try Folder.filter(keys: ids).fetchAll(db) }
            let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            folders = ids.compactMap { byId[$0] }
        } catch {
            BackgroundSyncLogger.logDebug("[CatchUp] folder read failed: \(error)")
            return false
        }
        guard !folders.isEmpty else { return false }

        // Just before the provider reads: every value it returns was read after
        // this, so an action that completed at or after it may be newer than
        // what the result carries (`applyCatchUpTransaction`).
        let readStartedAt = CatchUpWallClock.now()
        let results = await provider.catchUp(
            folders: folders, localRows: SyncEngineCatchUpRowReader(pool: dbPool), context: context)
        let windowMode = provider.staleWindowMode
        var madeProgress = false
        for result in results {
            let outcome = await applyCatchUpResult(result, windowMode: windowMode, readStartedAt: readStartedAt)
            if result.madeProgress, case .applied = outcome { madeProgress = true }
        }
        return madeProgress
    }

    /// Apply one folder's catch-up result: first the messages the provider loaded
    /// (`result.loaded`), through the backfill page walk's insert tail; then ONE
    /// write transaction for the flag updates, the removals and the new state.
    /// The loads go first so the state that moves the listing past them is never
    /// written without them: a crash in between lists them again, and the insert
    /// skips what is already there. A load that did not land (a write chunk
    /// failed, or the folder could take nothing) writes nothing at all, the
    /// state included: the listing stays where it was and the provider lists
    /// those ranges again on a later pass. `readStartedAt` is when the read that
    /// produced `result` began, on `CatchUpWallClock`. A load the user's own
    /// newer action stands on (`catchUpReadPredatesAction`), and every load of an
    /// over-age read (`catchUpReadIsOverAge`), is not inserted. That is not a
    /// failure: the state is written, and the message, if the server still lists
    /// it in the folder, is missing again at the next listing.
    @discardableResult
    func applyCatchUpResult(
        _ result: CatchUpFolderResult, windowMode: StaleWindowMode, readStartedAt: Date
    ) async -> CatchUpApplyOutcome {
        let folderId = result.folderId
        if !result.loadFailures.isEmpty && DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): \(result.loadFailures.count) missing id(s) did not load: \(result.loadFailures.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        }
        if !result.loaded.isEmpty, !(await insertCatchUpLoads(result, readStartedAt: readStartedAt)) {
            BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): \(result.loaded.count) loaded message(s) did not all land — nothing written, the listing stays where it was")
            return .skipped
        }

        let outcome: CatchUpApplyOutcome
        let appliedAt = CatchUpWallClock.now()
        do {
            outcome = try await dbPool.write { db in
                try Self.applyCatchUpTransaction(
                    result, windowMode: windowMode, readStartedAt: readStartedAt, now: appliedAt, db: db)
            }
        } catch {
            BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): apply failed: \(error)")
            return .skipped
        }

        switch outcome {
        case .applied(let updatedFlags, let removedIds):
            let readAge = appliedAt.timeIntervalSince(readStartedAt)
            if Self.catchUpReadIsOverAge(readStartedAt: readStartedAt, now: appliedAt)
                && !(result.flagUpdates.isEmpty && result.loaded.isEmpty) && DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): read began \(Int(readAge)) s ago — \(result.flagUpdates.count) read/flag update(s) and \(result.loaded.count) load(s) not applied")
            }
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
    /// when every write chunk landed. `readStartedAt` makes the insert skip what
    /// the user's own newer action stands on (`insertBackfillBatch`).
    private func insertCatchUpLoads(_ result: CatchUpFolderResult, readStartedAt: Date) async -> Bool {
        let folderId = result.folderId
        guard let folder = try? await dbPool.read({ db in try Folder.fetchOne(db, key: folderId) }),
              folder.uidValidityResetPendingAt == nil else { return false }
        let headers = result.loaded.compactMap(\.header)
        let bodies = Dictionary(
            result.loaded.map { ($0.id, (htmlBody: $0.htmlBody, textBody: $0.textBody)) },
            uniquingKeysWith: { first, _ in first })
        let insert = await insertFetchedBackfillMessages(
            headers, bodies: bodies, folder: folder, catchUpReadStartedAt: readStartedAt)
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

    /// A user action on this message is newer than a catch-up read that began at
    /// `readStartedAt`: the shared 30 s protection still holds one of its keys
    /// (`recentlyCompleted`, which the caller reads inside its write transaction,
    /// Memory 127), or the completion log (`AccountManager.actionCompletedAt`) has
    /// an action on one of them completing at or after the read began. The keys
    /// are the provider message id and the RFC Message-ID, as the queue records
    /// them. What the read carries for the message is then older than the user's
    /// change: its read or flag state is not applied, and a message it loaded is
    /// not inserted (the user moved it out of the folder after the read listed it).
    nonisolated static func catchUpReadPredatesAction(
        accountId: String, messageId: String, rfc822MessageId: String?,
        readStartedAt: Date, recentlyCompleted: [String: Date]
    ) -> Bool {
        let keys = [messageId] + (rfc822MessageId.map { [$0] } ?? [])
        return keys.contains { key in
            recentlyCompleted[key] != nil
                || (AccountManager.shared.actionCompletedAt(accountId: accountId, messageKey: key).map { $0 >= readStartedAt } ?? false)
        }
    }

    /// A catch-up read at least as old as the completion log's retention may
    /// predate an entry the log already dropped, so nothing it carries per
    /// message (a read or flag update, a load) applies; its removals and its
    /// state do, so the listing always moves on. `now` is on `CatchUpWallClock`.
    nonisolated static func catchUpReadIsOverAge(readStartedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(readStartedAt) >= SyncConfig.catchUpCompletionLogRetentionSeconds
    }

    /// The transaction itself. Everything it decides on is read INSIDE it: the folder
    /// row (quarantine, epoch), the pending operations and the recent completions.
    /// `now` is the wall clock (`CatchUpWallClock`) at the apply.
    nonisolated static func applyCatchUpTransaction(
        _ result: CatchUpFolderResult, windowMode: StaleWindowMode, readStartedAt: Date, now: Date, db: Database
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
        // A user action that completed at or after the read began is newer than
        // what the read carries for that message, however long the read took to
        // get here (the 30 s protection above may have run out). A read as old as
        // the completion log's retention may predate an entry already dropped, so
        // it applies no read or flag update at all; its removals and state still
        // apply, so the listing moves on.
        let readIsOverAge = catchUpReadIsOverAge(readStartedAt: readStartedAt, now: now)

        var updatedFlags = 0
        for update in result.flagUpdates where !readIsOverAge {
            let canonicalId = MessageIdentity.headerId(
                accountId: folder.accountId, folderPath: folder.path, messageId: update.messageId)
            guard var row = try MessageHeader.fetchOne(db, key: canonicalId),
                  providerAddressOwnershipProven(
                    row: row, accountId: folder.accountId, folderPath: folder.path,
                    folderId: folder.id, messageId: update.messageId, canonicalId: canonicalId,
                    windowMode: windowMode, sourceBoundEpoch: sourceBoundEpoch) else { continue }
            if pendingFlags.containsAnyKey(messageId: row.messageId, rfc822MessageId: row.rfc822MessageId) { continue }
            if catchUpReadPredatesAction(
                accountId: folder.accountId, messageId: row.messageId, rfc822MessageId: row.rfc822MessageId,
                readStartedAt: readStartedAt, recentlyCompleted: recentlyCompleted) { continue }
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
