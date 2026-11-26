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

/// What one catch-up slice did (`SyncEngine.runCatchUp`), by folder id.
struct CatchUpSliceResult: Sendable, Equatable {
    /// The folders whose applied result made progress
    /// (`CatchUpFolderResult.madeProgress`).
    var progressedFolderIds: Set<String> = []
    /// The folders whose call left a request that may still be in flight
    /// (`CatchUpFolderResult.requestMayBeInFlight`, #1062), whether or not the
    /// result was applied: abandoning a request that was on the wire ended that
    /// folder's session, whatever the apply did (a request that timed out still
    /// waiting for its connection sent nothing, and is reported the same way).
    /// *Superseded (#1062):* "the request may still hold that folder's connection".
    var inFlightFolderIds: Set<String> = []
    /// A slice of an other-folder run (#1110, `SyncEngine.readOtherFolders`):
    /// the folders whose change read is done for this run, never asked again in
    /// it (a subset of `progressedFolderIds`). Its `inFlightFolderIds` are the
    /// folders whose read failed, left out of the rest of the run too.
    var finishedFolderIds: Set<String> = []
    /// An applied folder result made progress.
    var progressed: Bool { !progressedFolderIds.isEmpty }
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

    func rows(folderId: String, numericIdsBelow upper: Int, limit: Int) async throws -> [CatchUpLocalRow] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM messageHeader
                WHERE folderId = ? AND CAST(messageId AS INTEGER) < ?
                ORDER BY CAST(messageId AS INTEGER) DESC LIMIT ?
                """, arguments: [folderId, upper, limit]).map(Self.localRow)
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

    func lastNumericId(folderId: String) async throws -> Int? {
        try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT MAX(CAST(messageId AS INTEGER)) FROM messageHeader WHERE folderId = ?
                """, arguments: [folderId])
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

    /// Served by the same index, read backwards from the bound. A listing calls this
    /// once per range, each time with the previous range's oldest date, so the bounded
    /// read must start at its bound: written as `(? IS NULL OR providerDate < ?)`, the
    /// bound is no index range, and every call started at the folder's newest row and
    /// stepped over every row newer than the bound.
    func newestRows(folderId: String, orderDatesBefore upper: Date?, limit: Int) async throws -> [CatchUpLocalRow] {
        try await pool.read { db -> [CatchUpLocalRow] in
            if let upper {
                return try Row.fetchAll(db, sql: Self.newestRowsBeforeSQL, arguments: [folderId, upper, limit])
                    .map(Self.datedRow)
            }
            return try Row.fetchAll(db, sql: Self.newestRowsSQL, arguments: [folderId, limit]).map(Self.datedRow)
        }
    }

    /// The newest rows of a folder: the first range of a listing.
    static let newestRowsSQL = """
        SELECT \(columns), providerDate FROM messageHeader
        WHERE folderId = ?
        ORDER BY providerDate DESC, messageId DESC LIMIT ?
        """

    /// The newest rows of a folder before a date: every later range of a listing.
    static let newestRowsBeforeSQL = """
        SELECT \(columns), providerDate FROM messageHeader
        WHERE folderId = ? AND providerDate < ?
        ORDER BY providerDate DESC, messageId DESC LIMIT ?
        """
}

extension SyncEngine {

    /// One catch-up run's snapshot (#766): everything the run reads that can
    /// change while it runs, taken once as the run's first step (root rule:
    /// snapshot settings at operation start). Every slice reads only this.
    struct CatchUpRun: Sendable {
        /// Whether the Email Index Limit (the storage budget) was finite when the
        /// run started.
        let storageLimitInForce: Bool
        /// The background processing job's deadline: slices run until it. Nil for
        /// a foreground backfill cycle, which runs exactly one slice, and for an
        /// access run, which runs on its working time (`workSeconds`).
        let deadline: Date?
        /// How long one slice may spend (`SyncConfig.catchUpSliceSeconds`), and the
        /// window the next slice of the account waits for.
        let sliceSeconds: TimeInterval
        /// The gap between the starts of two slices of the account, the pacing
        /// window (`SyncConfig.catchUpSliceIntervalSeconds`, real time).
        let intervalSeconds: TimeInterval
        /// Most requests one slice may send (`SyncConfig.catchUpSliceMaxRequests`).
        var sliceMaxRequests = SyncConfig.catchUpSliceMaxRequests
        /// About how many messages one listing range holds
        /// (`CatchUpContext.listingRangeMessages`).
        var listingRangeMessages = SyncConfig.catchUpListingRangeMessages
        /// Longest one catch-up request may take (`CatchUpContext.requestTimeoutSeconds`).
        var requestTimeoutSeconds = SyncConfig.catchUpRequestTimeoutSeconds
        /// The folders this run is for (#1109): a run a user action started asks
        /// only these (`CatchUpContext.accessedFolderIds`), the syncable ones among
        /// them. Nil for the backfill worker's run, which asks every syncable
        /// folder.
        var accessedFolderIds: Set<String>?
        /// An access run's time (#1109, `SyncConfig.accessCatchUpRunSeconds`):
        /// its slices run until their working time (each from when its provider
        /// work starts) adds up to this. A wait for the turn, a wait for a slot
        /// of the provider work queue, and the pacing wait between slices, are
        /// not counted: waiting is not working time. Nil for the backfill
        /// worker's runs.
        var workSeconds: TimeInterval?
        /// An other-folder run (#1110, `SyncEngine.startOtherFolderRun`): its
        /// slices read the changes of the folders outside the syncable set
        /// (`readOtherFolders`), not older mail, until each has been read once
        /// (`CatchUpSliceResult.finishedFolderIds`), a slice reads nothing new,
        /// or its working time (`workSeconds`) is spent.
        var readsOtherFolders = false
        /// The clock the slices and the deadline are measured on. Injectable so a
        /// test can spend a slice deterministically; production passes `Date.init`.
        let clock: @Sendable () -> Date

        /// The production snapshot, taken now.
        static func snapshot(deadline: Date?, clock: @escaping @Sendable () -> Date = { Date() }) -> CatchUpRun {
            CatchUpRun(
                storageLimitInForce: StorageEstimator.budgetMB != Int.max,
                deadline: deadline, sliceSeconds: SyncConfig.catchUpSliceSeconds,
                intervalSeconds: SyncConfig.catchUpSliceIntervalSeconds, clock: clock)
        }

        /// The context of a slice that starts now, when the run has `worked` so
        /// far: it ends one slice from now, or at the run's deadline, or when its
        /// working time is spent, whichever comes first. Nil once the deadline
        /// has passed or the working time is spent.
        func sliceStartingNow(worked: TimeInterval = 0) -> CatchUpContext? {
            let now = clock()
            var end = now.addingTimeInterval(sliceSeconds)
            if let deadline {
                guard now < deadline else { return nil }
                end = min(end, deadline)
            }
            if let workSeconds {
                guard worked < workSeconds else { return nil }
                end = min(end, now.addingTimeInterval(workSeconds - worked))
            }
            return CatchUpContext(
                deadline: end, clock: clock,
                storageLimitInForce: storageLimitInForce, maxRequests: sliceMaxRequests,
                listingRangeMessages: listingRangeMessages, requestTimeoutSeconds: requestTimeoutSeconds,
                accessedFolderIds: accessedFolderIds ?? [])
        }
    }

    /// The catch-up of older mail, run by the backfill worker after the folders'
    /// walk (ADR-IOS-107, #766), in slices. Each slice takes the account's
    /// one-sync-at-a-time turn (`oneSyncAtATime`, ADR-IOS-104), so it never runs
    /// beside a delta, a full sync or a lapse, and releases it at the slice's end:
    /// a sync trigger that arrives meanwhile does not wait, it sets the account's
    /// follow-up flag (#1289), and the stage 2 it asks for joins the turn line
    /// ahead of every slice waiting, this run's and other readers' alike
    /// (`SyncTurnPlace`, #1360), as does the folder view's listing (opening a
    /// folder, pulling to refresh it). Each waits at most for the running work
    /// and for any work that is not a slice and queued before the first
    /// waiting slice.
    /// *Superseded (#1289):* "so a push or silent-push delta that arrives
    /// meanwhile waits at most one slice". The slice's clock starts when its
    /// provider work starts, once the account's provider work queue gives it a
    /// slot, never while it waits for the turn or the slot (sync timing promise
    /// 2). *Superseded (#1109):* "The slice's clock starts when its turn starts,
    /// never while it waits": a slice that waited for a slot inside its turn
    /// reached the provider with less of its time. An access run's time
    /// (`CatchUpRun.workSeconds`, #1109) is its slices' working time: neither the
    /// wait for the turn, the wait for the slot, nor the pacing wait between
    /// slices counts, and the run ends with the slice that spends it.
    /// An other-folder run (`CatchUpRun.readsOtherFolders`, #1110) runs the same
    /// slices, turn, slot, window and working time, but each reads the changes
    /// of the folders outside the syncable set (`readOtherFolders`): those not
    /// yet done in this run, in `otherFolderReadOrder`. A folder read once, or
    /// whose read failed, is not asked again in the run, which ends at the turn
    /// that finds none left (before it opens a window or asks for a slot), after
    /// a slice that read nothing, or when its working time is spent.
    /// A foreground cycle (`run.deadline == nil`, no working time) runs one slice; the background
    /// processing job runs slices until its deadline, and stops after a slice
    /// whose folders made no progress and that left no folder out it had not
    /// left out before, so a folder whose requests keep failing is retried at
    /// the next cycle, not at network rate.
    /// *Superseded (#1062, in place):* "Either stops after a slice that made no
    /// progress": a background slice that adds a folder to the left-out set
    /// takes another, and a foreground cycle stops after its one slice whatever
    /// it made. The run never asks a folder again after
    /// its call left a request that may still be in flight
    /// (`CatchUpFolderResult.requestMayBeInFlight`, #1062; IMAP: a request that
    /// timed out), whatever progress that call made: abandoning a request that
    /// was on the wire ended the folder's session (a cancelled IMAP command
    /// closes it at once; one that timed out still waiting for its connection
    /// sent nothing, and counts the same), so another request to the folder in this run would first log in again on
    /// the link that just timed out, and a second timeout there would cap the
    /// width for a reason that is not the range's size. Later slices of the run
    /// leave the folder out and go on with the others: the run takes another
    /// slice when any folder the slice asked made progress, or when the slice
    /// added a folder to the left-out set (at most one slice per folder per run,
    /// each with its window and request cap). A left-out folder is never asked
    /// again, so the run ends once only left-out folders have work. The set lives
    /// in this run's memory alone. The state the
    /// folder's call saved is kept, and its
    /// next call, in a later run, asks at most the capped width. Other callers that
    /// reach the folder meanwhile (the worker's next cycle, the walk) are the
    /// connection's own issue (#1133), open. Generic: a provider without catch-up
    /// returns nothing, and the run stops after one slice. True when a slice's
    /// applied result made progress, a folder left out afterwards included (the
    /// worker's `didWork`).
    /// *Superseded (#1062):* "the request may still hold the folder's connection
    /// until its late answer": nothing waits for the late answer, which is never
    /// read.
    /// *Superseded (#1062):* "only the progress of folders still asked decides
    /// whether the run takes another slice, so a slice whose only progress came
    /// from such a folder ends the run": a timeout spends its slice, so the run
    /// ended whenever the timed-out folder came first in it, and the other folders
    /// waited for the next run.
    /// *Superseded (#1062):* "the run takes another slice when a folder still
    /// asked made progress, or when the slice left a folder out that was not left
    /// out before. The left-out folder's own progress never keeps the run going":
    /// a slice asks only folders outside the set, so a progressed folder it left
    /// out is one it added, and that distinction never decided anything.
    ///
    /// The request rate: a slice sends at most `run.sliceMaxRequests`, and opens a
    /// window of `run.intervalSeconds` (real time) in `catchUpSliceWindowEnds`,
    /// from its turn and, once it ran, again from when it got its slot of the
    /// provider work queue, before its folder read and its first request (#1109:
    /// a slice that waited for its slot still has its whole slice, so its
    /// window must not have run out meanwhile); no
    /// slice of the account, from this run or another, starts before the window
    /// ends. The wait happens outside the turn, so a delta is never held by it,
    /// and never reaches past the run's deadline: a window that ends at or after
    /// the deadline ends the run.
    func runCatchUpRun(account: Account, run: CatchUpRun) async -> Bool {
        guard let queue = workQueues[account.id] else { return false }
        let provider = queue.provider
        let accountId = account.id
        var madeProgress = false
        // The folders whose request may still be in flight (#1062): never asked
        // again in this run. In memory only, gone when the run ends.
        var inFlight = Set<String>()
        // An other-folder run's folders whose read is done for this run
        // (#1110): never asked again in it. In memory only.
        var finished = Set<String>()
        // The run's working time so far (`CatchUpRun.workSeconds`): only the
        // slices' time from their slot of the provider work queue, so neither
        // a wait for the turn nor a wait for the slot is counted.
        var worked: TimeInterval = 0
        runLoop: while !Task.isCancelled {
            let leftOut = inFlight.union(finished)
            let workedSoFar = worked
            // A background chunk in the turn line: an owed new-mail follow-up
            // and the folder view's listing go ahead of it (#1360).
            let slice: CatchUpSliceOutcome = await oneSyncAtATime(accountId: accountId, place: .backgroundChunk) {
                let turnTaken = ContinuousClock.now
                if let end = self.catchUpSliceWindowEnds[accountId], end > Date() {
                    // No slice can start before the run's deadline: the run ends
                    // now rather than wait past it.
                    if let deadline = run.deadline, run.clock().addingTimeInterval(end.timeIntervalSinceNow) >= deadline {
                        return .runOver
                    }
                    return .windowOpen(until: end)
                }
                guard run.sliceStartingNow(worked: workedSoFar) != nil else { return .runOver }
                // An other-folder run asks its folders not done yet, in its
                // order (#1110), and ends here, before it opens a window or
                // asks for a slot, once none is left.
                var otherFolderOrder: [String]?
                if run.readsOtherFolders {
                    do {
                        otherFolderOrder = try await self.otherFolderReadOrder(accountId: accountId).filter { !leftOut.contains($0) }
                    } catch {
                        BackgroundSyncLogger.logDebug("[OtherFolders] folder read failed: \(error)")
                        return .runOver
                    }
                    if otherFolderOrder?.isEmpty ?? true { return .runOver }
                }
                self.catchUpSliceWindowEnds[accountId] = Date().addingTimeInterval(run.intervalSeconds)
                let folderIds: [String]
                let otherFolderIds: Set<String>
                if let otherFolderOrder {
                    folderIds = otherFolderOrder
                    otherFolderIds = []
                } else {
                    do {
                        let folders = try await self.catchUpFolderIds(accountId: accountId)
                        folderIds = folders.ids.filter {
                            !leftOut.contains($0) && (run.accessedFolderIds?.contains($0) ?? true)
                        }
                        otherFolderIds = folders.otherFolderIds
                    } catch {
                        BackgroundSyncLogger.logDebug("[CatchUp] folder read failed: \(error)")
                        return .ran(CatchUpSliceResult(), spent: 0)
                    }
                }
                #if DEBUG
                await self.catchUpSliceStartHookForTesting?(folderIds)
                #endif
                // The slice's clock starts when its provider work starts, once
                // the account's provider work queue gives it a slot: the wait
                // for the slot, like the wait for the turn, is not working time
                // (sync timing promise 2). The slice's time and an access run's
                // working time count from here, and the background job's
                // deadline, a fixed instant, is checked here: a job whose
                // deadline passed during the wait ends.
                // *Superseded (#1109):* the slice's context was made, and its
                // clock started, at its turn, before the wait for the slot, so a
                // slice that waited reached the provider with less time, or none.
                let asked = ContinuousClock.now
                let sliceWork: CatchUpSliceWork
                do {
                    sliceWork = try await queue.execute(priority: .headerFetch) { () -> CatchUpSliceWork in
                        let admitted = ContinuousClock.now
                        guard var context = run.sliceStartingNow(worked: workedSoFar) else {
                            return CatchUpSliceWork(queueWait: asked.duration(to: admitted))
                        }
                        context.otherFolderIds = otherFolderIds
                        let admittedAt = Date()
                        let start = run.clock()
                        let result = run.readsOtherFolders
                            ? await self.readOtherFolders(account: account, provider: provider, folderIds: folderIds, context: context)
                            : await self.runCatchUp(provider: provider, folderIds: folderIds, context: context)
                        return CatchUpSliceWork(
                            result: result, spent: run.clock().timeIntervalSince(start), admittedAt: admittedAt,
                            queueWait: asked.duration(to: admitted), work: admitted.duration(to: .now))
                    }
                } catch {
                    Self.logCatchUpSlice(
                        accountId: accountId, run: run, outcome: "notRun", error: error,
                        work: CatchUpSliceWork(queueWait: asked.duration(to: .now)), turnTaken: turnTaken)
                    return .ran(CatchUpSliceResult(), spent: 0)
                }
                Self.logCatchUpSlice(
                    accountId: accountId, run: run, outcome: sliceWork.result == nil ? "runOver" : "ran",
                    work: sliceWork, turnTaken: turnTaken)
                guard let result = sliceWork.result else { return .runOver }
                // A slice that ran opens its window again from when it got its
                // slot (before its folder read and its first request), so the
                // next slice of the account starts at least one window after
                // that, however long this one waited for its slot. The window
                // opened at the turn stays for a slice that found the run over at
                // its slot.
                if let admittedAt = sliceWork.admittedAt {
                    self.catchUpSliceWindowEnds[accountId] = admittedAt.addingTimeInterval(run.intervalSeconds)
                }
                return .ran(result, spent: sliceWork.spent)
            }
            switch slice {
            case .windowOpen(until: let end):
                try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            case .runOver:
                break runLoop
            case .ran(let ran, spent: let spent):
                worked += spent
                madeProgress = madeProgress || ran.progressed
                // Abandoning a request that may still be in flight ended its
                // folder's session when it was on the wire (one still waiting
                // for its connection sent nothing): either way the folder is
                // left out of the rest of the run (#1062). The run takes another slice when any folder the slice
                // asked made progress, or when the slice added a folder to the
                // set. The slice asks only folders outside the set, so a slice
                // whose only progress came from a folder it left out goes on
                // because it added that folder (a timeout spends its slice, and
                // the folders still asked go on in the next one). The set only
                // grows and its folders are never asked again, so that adds at
                // most one slice per folder to the run, each with its own window
                // and request cap. A slice with no folder left to ask, or whose
                // folders made no progress and added none, ends the run.
                // *Superseded (#1062):* "holds its folder's connection": a
                // cancelled request closes its session at once.
                // *Superseded (#1062):* the run took another slice only when a
                // folder still asked progressed, so it ended whenever the
                // timed-out folder came first in its slice.
                // *Superseded (#1062):* "its progress does not keep the run
                // going", with the set subtracted from the slice's progressed
                // folders: that never decided anything, since a progressed folder
                // the slice left out is one it added.
                let addedInFlight = !ran.inFlightFolderIds.isSubset(of: inFlight)
                inFlight.formUnion(ran.inFlightFolderIds)
                // An other-folder run's folders read once are done for the run
                // (#1110): the next slice asks the rest, and the run ends at the
                // turn that finds none left.
                finished.formUnion(ran.finishedFolderIds)
                // A foreground cycle (no deadline, no working time) ends here.
                guard !ran.progressedFolderIds.isEmpty || addedInFlight,
                      run.deadline != nil || run.workSeconds != nil else { break runLoop }
                // An access run ends with the slice that spends its working
                // time: it never takes another turn, or waits for another
                // window, only to find its time spent.
                if let workSeconds = run.workSeconds, worked >= workSeconds { break runLoop }
            }
        }
        return madeProgress
    }

    #if DEBUG
    /// Test-only seam: install `catchUpSliceStartHookForTesting`, called with
    /// the folders a slice of `runCatchUpRun` asks, as the slice starts (inside
    /// the account's turn, before its first request), so a test can tell which
    /// slice sent each request (the hook is awaited). Compiled out of Release.
    /// *Superseded (#1062):* "or hold the slice inside its turn": a slice held
    /// there had read and written nothing; `catchUpAfterReadHookForTesting`
    /// holds one whose read is done.
    func setCatchUpSliceStartHookForTesting(_ hook: (@Sendable ([String]) async -> Void)?) {
        catchUpSliceStartHookForTesting = hook
    }

    /// Test-only seam: install `catchUpAfterReadHookForTesting`, called with the
    /// folders a slice (`runCatchUp`) read, once the provider has returned and
    /// before the slice applies anything (inside the account's turn when the
    /// slice runs in `runCatchUpRun`), so a test can hold a slice whose read is
    /// done and whose writes are not (the hook is awaited). Compiled out of
    /// Release.
    func setCatchUpAfterReadHookForTesting(_ hook: (@Sendable ([String]) async -> Void)?) {
        catchUpAfterReadHookForTesting = hook
    }
    #endif

    /// What one turn of `runCatchUpRun` did.
    private enum CatchUpSliceOutcome {
        /// The account's previous slice window is still open: nothing was sent.
        case windowOpen(until: Date)
        /// The run's deadline has passed (also while the slice waited for its
        /// slot), or the account's open window ends at or after it; or an access
        /// run's working time is spent.
        case runOver
        /// A slice ran: the folders whose applied result made progress, and
        /// those whose request may still be in flight; and the time its provider
        /// work took (an access run's working time).
        case ran(CatchUpSliceResult, spent: TimeInterval)
    }

    /// One slice's provider work in `runCatchUpRun`, with its timings.
    private struct CatchUpSliceWork: Sendable {
        /// What the slice did; nil when the run was over by the time the slice
        /// got its slot (`CatchUpSliceOutcome.runOver`).
        var result: CatchUpSliceResult?
        /// The slice's working time on the run's clock (`CatchUpRun.workSeconds`).
        var spent: TimeInterval = 0
        /// When the slice got its slot, before its folder read and its first
        /// request (real time, the pacing window's clock); nil when it did not
        /// run.
        var admittedAt: Date?
        /// How long the slice waited for a slot of the provider work queue.
        var queueWait: Duration
        /// How long its provider work took, for the debug log.
        var work: Duration = .zero
    }

    /// The debug-gated timing line of one catch-up slice (#1109), access run,
    /// backfill or other-folder run (#1110): the wait for a slot of the provider work queue, the slice's
    /// working time, and how long the slice held the account's turn (`turnHoldMs`,
    /// from its turn start: the folder read, the queue wait and the work). A pass
    /// that waited behind it logs `[SyncTurnWait]` when it starts.
    private static func logCatchUpSlice(
        accountId: String, run: CatchUpRun, outcome: String, error: (any Error)? = nil,
        work: CatchUpSliceWork, turnTaken: ContinuousClock.Instant
    ) {
        BackgroundSyncLogger.logDebug({
            let kind = run.readsOtherFolders ? "other-folders"
                : run.workSeconds != nil ? "access" : (run.deadline != nil ? "backfill-background" : "backfill-foreground")
            let shown = error.map { "\(outcome)(\($0))" } ?? outcome
            let turnHold = turnTaken.duration(to: .now)
            return "[CatchUpSlice] \(accountId.prefix(8)): kind=\(kind) outcome=\(shown)"
                + " queueWaitMs=\(MigrationTimingLedger.wholeMilliseconds(work.queueWait))"
                + " workMs=\(MigrationTimingLedger.wholeMilliseconds(work.work))"
                + " turnHoldMs=\(MigrationTimingLedger.wholeMilliseconds(turnHold))"
        }())
    }

    /// Every folder of the account as it is now, for the catch-up (#1110): the
    /// syncable ones (`syncableFoldersInOrder`, the folders the full sync syncs)
    /// in the full sync's order, then every other folder, whose ids are also
    /// returned on their own (`CatchUpContext.otherFolderIds`): a provider works
    /// the syncable ones first, and gives the others their own schedule. An
    /// other folder owed a check after a move retired without proof
    /// (`FolderChangeState.selfHealDue`, #1062) is among them, so it is always
    /// listed: its mark clears at a clean listing, and stays open after an
    /// unclean one until a later clean one.
    /// *Superseded (#1110):* "The account's syncable folders [...], then every
    /// other folder owed a check after a move retired without proof": the first
    /// check of an other folder, and its later lapses, are the catch-up's too.
    /// *Superseded (#1062, in place):* "so its mark always clears": an unclean
    /// completion leaves it owed.
    private func catchUpFolderIds(accountId: String) async throws -> (ids: [String], otherFolderIds: Set<String>) {
        let folders = try await dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId).fetchAll(db)
        }
        let syncable = syncableFoldersInOrder(folders).map(\.id)
        let listed = Set(syncable)
        let others = folders.map(\.id).filter { !listed.contains($0) }
        return (syncable + others, Set(others))
    }

    /// The one-time prune cutoff of a folder that has none (`CatchUpPruneCutoff`,
    /// #1062). Released versions pruned without recording a cutoff, so a folder
    /// pruned there holds rows whose lowest UID is where its kept mail ends, and
    /// nothing records it. Under a storage limit, for a UID-windowed provider, a
    /// folder with a known epoch, local rows and no cutoff in that epoch gets ONE:
    /// the lower of its first local UID and its window floor in the CURRENT epoch
    /// (`CatchUpWindowFloor`; with none, the first local UID alone), minus one, so
    /// nothing at or below it loads again and an unreadable lowest window UID
    /// still can (*superseded (#1062):* "so nothing pruned there loads again"; see
    /// the gaps below). From then on only the prune moves it. Called by a slice in its turn,
    /// once the slice is admitted with budget and before the provider reads, so
    /// the slice's own read already sees it. A folder whose turnover is pending is
    /// left alone. This is an inference: a date-ordered prune can leave gaps
    /// above the seed, and the catch-up loads those again ONCE, within the limit,
    /// as rows stamped with the epoch, which the UID-ordered prune then counts.
    /// Returns the folders that needed a seed and did not get one (a read or write
    /// failure): the caller leaves them out of this slice, so no slice loads below
    /// an unrecorded legacy prune, and the next slice tries again.
    func seedCatchUpPruneCutoffs(folderIds: [String]) async -> Set<String> {
        let unseeded: [String]
        do {
            unseeded = try await dbPool.read { db in
                try folderIds.filter { try Self.catchUpPruneCutoffSeed(folderId: $0, db: db) != nil }
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[CatchUp] prune cutoff seed read failed (\(error)) — these folders wait for the next slice")
            }
            return Set(folderIds)
        }
        guard !unseeded.isEmpty else { return [] }
        let seeded: [(folderId: String, uid: Int, epoch: Int)]
        do {
            seeded = try await dbPool.write { db in
                var written: [(folderId: String, uid: Int, epoch: Int)] = []
                for folderId in unseeded {
                    guard let seed = try Self.catchUpPruneCutoffSeed(folderId: folderId, db: db) else { continue }
                    try Self.recordCatchUpPruneCutoff(folderId: folderId, highest: seed.uid, epoch: seed.epoch, db: db)
                    written.append((folderId, seed.uid, seed.epoch))
                }
                return written
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[CatchUp] prune cutoff seed failed (\(error)) — these folders wait for the next slice")
            }
            return Set(unseeded)
        }
        // Logged after the commit, so only what was written is reported.
        if DebugModeManager.isLoggingEnabled() {
            for seed in seeded {
                BackgroundSyncLogger.logDebug("[CatchUp] \(seed.folderId): prune cutoff seeded at \(seed.uid) (epoch \(seed.epoch))")
            }
        }
        return []
    }

    /// The cutoff `seedCatchUpPruneCutoffs` writes for the folder now, or nil
    /// when it writes none (a cutoff in the epoch exists, the epoch is unknown, a
    /// turnover is pending, or no row is local).
    nonisolated static func catchUpPruneCutoffSeed(folderId: String, db: Database) throws -> (uid: Int, epoch: Int)? {
        guard let folder = try Folder.fetchOne(db, key: folderId),
              folder.uidValidityResetPendingAt == nil,
              let epoch = knownUidValidity(folder.lastKnownUidValidity),
              CatchUpPruneCutoff.read(folder.catchUpState, epoch: epoch) == nil,
              let firstLocal = try Int.fetchOne(db, sql: """
                  SELECT MIN(CAST(messageId AS INTEGER)) FROM messageHeader
                  WHERE folderId = ? AND CAST(messageId AS INTEGER) >= 1
                  """, arguments: [folderId])
        else { return nil }
        let windowFloor = CatchUpWindowFloor.read(folder.catchUpState, epoch: epoch) ?? firstLocal
        return (min(firstLocal, windowFloor) - 1, epoch)
    }

    /// One slice of the catch-up. `folderIds` are the syncable folders, re-read
    /// here so the provider sees their latest STATUS values and epochs. Never
    /// throws: a failure costs this slice. `context` comes from the run's snapshot
    /// (`CatchUpRun`): the network state and whether a storage limit is in force
    /// were read once, when the run started. Returns, by folder id, the folders
    /// whose applied result made progress (`CatchUpFolderResult.madeProgress`)
    /// and those whose call left a request that may still be in flight, applied
    /// or not (`CatchUpFolderResult.requestMayBeInFlight`, #1062).
    /// *Superseded (#1062):* "True when a folder's applied result made progress":
    /// a Bool, which could not say which folder's request may still be in flight.
    /// *Superseded (#766):* "The full sync's catch-up step [...] `context` defaults
    /// to the production snapshot taken right now".
    @discardableResult
    func runCatchUp(provider: any EmailProvider, folderIds: [String], context: CatchUpContext) async -> CatchUpSliceResult {
        // The legacy prune cutoff seed writes only for a slice that may send a
        // request: a slice whose budget is already spent writes nothing.
        var waitingForSeed = Set<String>()
        if context.storageLimitInForce, provider.staleWindowMode == .uid, context.hasBudget() {
            waitingForSeed = await seedCatchUpPruneCutoffs(folderIds: folderIds)
        }
        let ids = folderIds.filter { !waitingForSeed.contains($0) }
        let folders: [Folder]
        do {
            let rows = try await dbPool.read { db in try Folder.filter(keys: ids).fetchAll(db) }
            let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            folders = ids.compactMap { byId[$0] }
        } catch {
            BackgroundSyncLogger.logDebug("[CatchUp] folder read failed: \(error)")
            return CatchUpSliceResult()
        }
        guard !folders.isEmpty else { return CatchUpSliceResult() }

        // Just before the provider reads: every value it returns was read after
        // this, so an action that completed at or after it may be newer than
        // what the result carries (`applyCatchUpTransaction`).
        let readStartedAt = CatchUpWallClock.now()
        // What each folder was owed when its read began: a mark that lands
        // during the read (an unproven move retired meanwhile) is newer than
        // anything the read carries (`applyCatchUpTransaction`).
        let owedAtRead = Dictionary(
            folders.map { ($0.id, FolderChangeState(raw: $0.changeState).selfHealOwed) },
            uniquingKeysWith: { first, _ in first })
        let results = await provider.catchUp(
            folders: folders, localRows: SyncEngineCatchUpRowReader(pool: dbPool), context: context)
        #if DEBUG
        await catchUpAfterReadHookForTesting?(results.map(\.folderId))
        #endif
        let windowMode = provider.staleWindowMode
        var slice = CatchUpSliceResult()
        for result in results {
            let outcome = await applyCatchUpResult(
                result, windowMode: windowMode, readStartedAt: readStartedAt,
                selfHealOwedAtRead: owedAtRead[result.folderId])
            if result.madeProgress, case .applied = outcome { slice.progressedFolderIds.insert(result.folderId) }
            // Whatever the apply did: abandoning a request that was on the wire
            // ended the folder's session (one still waiting for its connection
            // sent nothing, and counts the same). *Superseded (#1062):* "the request may still hold the connection".
            if result.requestMayBeInFlight { slice.inFlightFolderIds.insert(result.folderId) }
        }
        return slice
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
    /// it in the folder, is missing again at the next listing. Over-age is one
    /// latch (`CatchUpReadLatch`, #1062), checked before the insert, in each insert
    /// chunk and in the transaction: once over-age, everything after it is, and any
    /// load it dropped makes the listing unclean.
    @discardableResult
    func applyCatchUpResult(
        _ result: CatchUpFolderResult, windowMode: StaleWindowMode, readStartedAt: Date,
        selfHealOwedAtRead: Int? = nil
    ) async -> CatchUpApplyOutcome {
        let folderId = result.folderId
        if !result.loadFailures.isEmpty && DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): \(result.loadFailures.count) missing id(s) did not load: \(result.loadFailures.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        }
        let latch = CatchUpReadLatch(readStartedAt: readStartedAt)
        if !result.loaded.isEmpty, latch.checkOverAge() { latch.noteLoadsSkipped() }
        if !result.loaded.isEmpty, !latch.loadsSkipped, !(await insertCatchUpLoads(result, latch: latch)) {
            BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): \(result.loaded.count) loaded message(s) did not all land — nothing written, the listing stays where it was")
            return .skipped
        }

        let outcome: CatchUpApplyOutcome
        do {
            outcome = try await dbPool.write { db in
                try Self.applyCatchUpTransaction(
                    result, windowMode: windowMode, readStartedAt: readStartedAt, latch: latch,
                    selfHealOwedAtRead: selfHealOwedAtRead, db: db)
            }
        } catch {
            BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): apply failed: \(error)")
            return .skipped
        }

        switch outcome {
        case .applied(let updatedFlags, let removedIds):
            let readAge = CatchUpWallClock.now().timeIntervalSince(readStartedAt)
            if latch.checkOverAge()
                && !(result.flagUpdates.isEmpty && result.loaded.isEmpty) && DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): read began \(Int(readAge)) s ago — \(result.flagUpdates.count) read/flag update(s) not applied; of \(result.loaded.count) load(s), \(latch.loadsSkipped ? "those after the over-age latch set were dropped" : "none was dropped")")
            }
            // Logged here, outside the write (no logDebug inside a write context).
            if let completed = result.completedListing, !completed.clean || latch.loadsSkipped,
               DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[CatchUp] \(folderId): listing completed unclean (passed over, top unknown (topUnknown), nothing to check (no load floor of the epoch and no local row), or skipped loads); an owed folder stays owed")
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
    ///
    /// Ids that carry an epoch (`result.epoch`) are inserted under the premise of
    /// that epoch, checked against the folder's stamp inside each insert
    /// transaction, so a turnover between the read and the insert refuses, which
    /// is not landed (C3, #1062). Under a storage limit the provider loads
    /// nothing below where kept mail ends, measured in its own sync order (IMAP:
    /// above the prune cutoff, `CatchUpPruneCutoff`, the only record of what was
    /// pruned), so this insert keeps every load.
    /// *Superseded (#1062, in place):* "IMAP: the lowest held UID, which the
    /// UID-ordered prune keeps a clean floor": a cached scroll page sits below
    /// the pruned UIDs, so the lowest held UID is no such floor.
    /// *Superseded (#1062):* "a loaded message dated older than the folder's
    /// oldest kept row (`date`, the prune's own order) is not inserted and counts
    /// as done" — on IMAP that date skip downloaded every pruned hole again at
    /// each listing (ADR-IOS-006 current note).
    private func insertCatchUpLoads(_ result: CatchUpFolderResult, latch: CatchUpReadLatch) async -> Bool {
        let folderId = result.folderId
        guard let folder = try? await dbPool.read({ db in try Folder.fetchOne(db, key: folderId) }),
              folder.uidValidityResetPendingAt == nil else { return false }
        let headers = result.loaded.compactMap(\.header)
        guard !headers.isEmpty else { return true }
        let bodies = Dictionary(
            result.loaded.map { ($0.id, (htmlBody: $0.htmlBody, textBody: $0.textBody)) },
            uniquingKeysWith: { first, _ in first })
        // The premise is the epoch that produced the result, never the folder's
        // stamp read here: a reset that finished between the read and this
        // insert stamped a new epoch, and the insert's own transaction refuses
        // it (C3). Rebinding to the stamp read here would admit old-epoch rows.
        let premise = result.epoch.map { observed in
            (premise: CrawlEpochPremise(observed), observedEpoch: observed)
        }
        let insert = await insertFetchedBackfillMessages(
            headers, bodies: bodies, folder: folder, catchUpRead: latch, epochPremise: premise)
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
    /// listing in progress keeps its place and a folder keeps its schedule. A NULL
    /// state stays NULL: no state already means a full check is due. A state that
    /// is not a JSON object
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
    /// `latch`: the read's one-way over-age verdict (`CatchUpReadLatch`), checked
    /// again here inside the write; it also says whether a load was dropped (#1062).
    /// `selfHealOwedAtRead`: the folder's `FolderChangeState.selfHealOwed` when
    /// the read began (nil: not known, nothing is re-marked).
    nonisolated static func applyCatchUpTransaction(
        _ result: CatchUpFolderResult, windowMode: StaleWindowMode, readStartedAt: Date, latch: CatchUpReadLatch,
        selfHealOwedAtRead: Int? = nil, db: Database
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

        let readIsOverAge = latch.checkOverAge()
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
        // The new state keeps a lapse count marked after the read began
        // (`markCatchUpLapse`, e.g. an unproven move retired meanwhile): the
        // result carries the count it read, and writing it back would lose the
        // newer mark for good. CASE evaluates lazily: the JSON functions only
        // see valid JSON objects.
        // The window floor (`CatchUpWindowFloor`) is the window merge's and the
        // prune cutoff (`CatchUpPruneCutoff`) the prune's, never the provider's:
        // each is read before the write and carried into the new state with the
        // epoch it was stored under (never rebound to another), so a catch-up's
        // state write never drops or moves them.
        func storedEpochValue(_ key: String) throws -> (uid: Int, epoch: Int)? {
            try Row.fetchOne(db, sql: """
                SELECT json_extract(catchUpState, '$.' || :key || '.uid') AS uid,
                       json_extract(catchUpState, '$.' || :key || '.epoch') AS epoch
                FROM folder WHERE id = :id AND json_valid(catchUpState) AND json_type(catchUpState) = 'object'
                """, arguments: ["key": key, "id": folder.id])
                .flatMap { row -> (uid: Int, epoch: Int)? in
                    guard let uid = row["uid"] as Int?, let epoch = row["epoch"] as Int? else { return nil }
                    return (uid, epoch)
                }
        }
        let windowFloor = try storedEpochValue(CatchUpWindowFloor.key)
        let pruneCutoff = try storedEpochValue(CatchUpPruneCutoff.key)
        try db.execute(sql: """
            UPDATE folder SET catchUpState = CASE
                WHEN :new IS NOT NULL AND json_valid(:new) AND json_type(:new) = 'object'
                    AND json_valid(catchUpState) AND json_type(catchUpState) = 'object'
                    AND COALESCE(json_extract(catchUpState, '$.' || :key), 0) > COALESCE(json_extract(:new, '$.' || :key), 0)
                THEN json_set(:new, '$.' || :key, json_extract(catchUpState, '$.' || :key))
                ELSE :new END
            WHERE id = :id
            """, arguments: ["new": result.newState, "key": CatchUpLapse.countKey, "id": folder.id])
        // Loads this apply dropped as an over-age read make the listing unclean
        // in its SAVED state (#1062): the state moves the listing past them, so a
        // later slice that completes it must not settle the owed mark. The key is
        // provider-neutral (`CatchUpSkippedLoads`); the provider reads it when the
        // listing completes. A completing result needs no mark: `clean` below.
        let skippedLoads = latch.loadsSkipped && !result.loaded.isEmpty
        if skippedLoads, result.completedListing == nil {
            try db.execute(sql: """
                UPDATE folder SET catchUpState = json_set(catchUpState, '$.' || ?, json('true'))
                WHERE id = ? AND json_valid(catchUpState) AND json_type(catchUpState) = 'object'
                """, arguments: [CatchUpSkippedLoads.key, folder.id])
        }
        if let windowFloor {
            try Self.recordCatchUpWindowFloor(folderId: folder.id, lowest: windowFloor.uid, epoch: windowFloor.epoch, db: db)
        }
        if let pruneCutoff {
            try Self.recordCatchUpPruneCutoff(folderId: folder.id, highest: pruneCutoff.uid, epoch: pruneCutoff.epoch, db: db)
        }

        // A folder owed a check after a move retired without proof
        // (`dropChangeBookmark(selfHealDue:)`) is settled by a clean listing that
        // STARTED after the last mark (#1062): one that began before it may have
        // passed the message the move left. Its listing is then made due, so the
        // next full sync lists it, its count check clears the mark, and
        // `commitChangeBaseline` tracks it again from that pass's own read.
        var changeState = FolderChangeState(raw: folder.changeState)
        let markedDuringRead = selfHealOwedAtRead.map { changeState.selfHealOwed > $0 } ?? false
        // Only a CLEAN completion settles the mark (#1062): every missing UID was
        // loaded or proven gone. A listing that passed anything over, or whose
        // loads this apply skipped as an over-age read, is unclean: the folder
        // stays owed and is listed again at the daily full check (an owed folder
        // gets it even with a bookmark, in the provider's catch-up plan), or
        // sooner when the folder's change counter (HIGHESTMODSEQ) moves.
        // *Superseded (#1062, in place):* "never sooner": an owed folder is
        // untracked, so a moved counter lists it before the daily check.
        let clean = result.completedListing.map { $0.clean && !skippedLoads } ?? false
        let startedAfterMark = result.completedListing.map {
            $0.lapseCountAtStart >= (changeState.selfHealLapse ?? 0)
        } ?? false
        let settles = clean && startedAfterMark
        // A clean owed listing that started before the mark may have passed the
        // message the move left: the lapse is re-marked once, so the next listing
        // starts after the mark and can settle it. An unclean completion re-marks
        // nothing itself; the folder stays owed and is listed again at the daily
        // check, or sooner when its HIGHESTMODSEQ moves or a mark lands during the
        // read (`markedDuringRead`, above).
        // *Superseded (#1062, in place):* "it waits for the daily check".
        let completedUnsettled = changeState.selfHealDue && clean && !startedAfterMark
        if markedDuringRead || completedUnsettled {
            // A mark landed while this read ran, or the owed listing completed
            // unsettled. The listing the result carries may have begun before
            // the mark, and a NULL state then had no count for the mark to
            // raise: the lapse is marked again on the state just written, so
            // only a listing that starts after it settles the mark.
            try markCatchUpLapse(folderId: folder.id, db: db)
            changeState.selfHealLapse = try Int.fetchOne(db, sql: """
                SELECT CASE WHEN json_valid(catchUpState) AND json_type(catchUpState) = 'object'
                    THEN COALESCE(json_extract(catchUpState, '$.' || ?), 0) ELSE 0 END
                FROM folder WHERE id = ?
                """, arguments: [CatchUpLapse.countKey, folder.id]) ?? 0
            try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [changeState.encoded, folder.id])
        } else if changeState.selfHealDue, settles {
            changeState.selfHealOwed = 0
            changeState.selfHealLapse = nil
            changeState.markListingDue()
            try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [changeState.encoded, folder.id])
        }
        return .applied(updatedFlags: updatedFlags, removedIds: removedIds)
    }
}
