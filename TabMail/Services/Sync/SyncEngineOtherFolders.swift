/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - The other-folder run (#1110)
//
// The folders outside the syncable set (`SyncEngine.isSyncable`: not a main
// role, not a favourite, not followed) get their changes read every 15 minutes
// while the app is open: a foreground pass whose full sync was due by its clock
// (`lastFullSyncAt`, `fullSyncInterval`) starts the account's run when it ends,
// beside the older-mail worker. The run is a catch-up run
// (`CatchUpRun.readsOtherFolders`, `runCatchUpRun`): each slice takes the
// account's turn, a `.headerFetch` slot and at most one slice of work, hands the
// turn on and waits outside it, so a new-mail read waits at most one slice. No
// timer, scheduler, queue, gate or turn of its own. The passes (poll, IDLE, push,
// pull, return) are unchanged.
//
// A slice reads the run's pending folders through the provider's change reader,
// scope `.otherFolders`, and applies the answer with the passes' one generic
// apply (`applyChangeSet`). The run never writes the folder list, the account's
// bookmark, `lastSyncedAt` or `lastFullSyncAt`, and never turns a folder's
// coverage flag (`FolderChangeState.tracking`) on. Provider-blind: no provider
// cast and no provider test (`ChangeSeamFenceTests`).
//
// End rule of a run, whichever comes first: every other folder has been read
// once in it (a folder whose first read is still going, an Outlook baseline cut
// by the slice's end, stays pending), a slice reads nothing new, its working time
// (`SyncConfig.otherFolderRunSeconds`, slice time only) is spent, or the account
// is removed. A folder the run did not finish is read in the next run.

extension SyncEngine {

    /// Starts the account's other-folder run, unless one is running: at most
    /// one per account, so a clock-due pass that ends while a run goes on
    /// starts none. Called by a foreground pass whose full sync was due by the
    /// clock (`foregroundPass`), when it ends.
    func startOtherFolderRun(account: Account) {
        let accountId = account.id
        guard workQueues[accountId] != nil, otherFolderRunTasks[accountId] == nil else { return }
        otherFolderRunTasks[accountId] = Task { await self.runOtherFolders(account: account) }
    }

    /// One run. Its settings are taken first and the run reads only this
    /// snapshot. An account with no other folder takes no turn. The task's
    /// entry is cleared when the run ends.
    private func runOtherFolders(account: Account) async {
        var run = CatchUpRun.snapshot(deadline: nil, clock: otherFolderRunClock)
        run.workSeconds = SyncConfig.otherFolderRunSeconds
        run.readsOtherFolders = true
        let hasOtherFolders: Bool
        do {
            let order = try await otherFolderReadOrder(accountId: account.id)
            hasOtherFolders = !order.isEmpty
        } catch {
            BackgroundSyncLogger.logDebug("[OtherFolders] \(account.id.prefix(8)): folder read failed: \(error)")
            hasOtherFolders = false
        }
        if hasOtherFolders {
            let progressed = await runCatchUpRun(account: account, run: run)
            BackgroundSyncLogger.logDebug("[OtherFolders] \(account.id.prefix(8)): run ended, progressed=\(progressed)")
        }
        otherFolderRunTasks[account.id] = nil
    }

    /// The account's other folders as they are now (`isSyncable` false, a
    /// non-empty path), those whose read finished or failed longest ago first
    /// (never first of all), else in stored order.
    func otherFolderReadOrder(accountId: String) async throws -> [String] {
        let folders = try await dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId).fetchAll(db)
        }
        let others = folders.filter { !Self.isSyncable($0) && !$0.path.isEmpty }
        let attempted = otherFolderAttemptedAt[accountId] ?? [:]
        return CatchUpSchedule.leastRecentlyAttemptedFirst(others) { attempted[$0.id] }.map(\.id)
    }

    /// One slice of an other-folder run, inside the account's turn and its
    /// `.headerFetch` slot: the change read of `folderIds` (those still other
    /// folders now), in that order, for its share of the slice
    /// (`SyncConfig.otherFolderReadShare`), then the passes' apply, then the
    /// listing of each changed folder no bookmark covers while the slice
    /// (`context.deadline`) has time to start one. A changed folder not listed
    /// stays pending: a later slice of the run reads it again, and each slice
    /// lists the first changed folder it reads.
    ///
    /// The result, by folder: read once (`finishedFolderIds`, also progressed):
    /// a read with a bookmark, a first or refused bookmark, an untracked folder
    /// unchanged, listed, or whose listing proved nothing (listed again next
    /// run). Progressed and still pending: a baseline that moved. Failed
    /// (`inFlightFolderIds`, left out of the rest of the run): a read or a
    /// listing that failed. Pending with nothing: not reached, or changed with
    /// no time left to start its listing. A read that throws, or a provider
    /// with no change reader, reads nothing new, and the run ends.
    func readOtherFolders(
        account: Account, provider: any EmailProvider, folderIds: [String], context: CatchUpContext
    ) async -> CatchUpSliceResult {
        let accountId = account.id
        let folders: [Folder]
        do {
            let rows = try await dbPool.read { db in try Folder.filter(keys: folderIds).fetchAll(db) }
            let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // A folder followed since the run's order was read is the passes'.
            folders = folderIds.compactMap { byId[$0] }.filter { !Self.isSyncable($0) && !$0.path.isEmpty }
        } catch {
            BackgroundSyncLogger.logDebug("[OtherFolders] \(accountId.prefix(8)): folder read failed: \(error)")
            return CatchUpSliceResult()
        }
        guard !folders.isEmpty else { return CatchUpSliceResult() }

        // The read may use its share of the slice (`SyncConfig.otherFolderReadShare`),
        // so a listing can still start before the slice's end; the listings
        // use the rest.
        let now = context.clock()
        let readEnd = now.addingTimeInterval(max(0, context.deadline.timeIntervalSince(now)) * SyncConfig.otherFolderReadShare)
        let sliceContext = ChangeContext(deadline: context.deadline, clock: context.clock, onProgress: { _ in })
        let request = ChangeRequest(
            folders: folders.map { Self.changeFolder($0, isSynced: true) },
            scope: .otherFolders, recheck: [:],
            context: ChangeContext(deadline: readEnd, clock: context.clock, onProgress: { _ in }),
            localRows: SyncEngineCatchUpRowReader(pool: dbPool))
        var changeSet: ChangeSet
        do {
            guard let read = try await provider.fetchChanges(
                since: ChangeCursor(account: account.lastHistoryId), request: request) else { return CatchUpSliceResult() }
            changeSet = read
        } catch {
            BackgroundSyncLogger.logDebug("[OtherFolders] \(accountId.prefix(8)): read failed: \(error)")
            return CatchUpSliceResult()
        }
        #if DEBUG
        await catchUpAfterReadHookForTesting?(changeSet.folders.map(\.folderId))
        #endif
        // The run never writes the folder list or the account's bookmark,
        // whatever the reader answered: those are the passes'.
        changeSet.account = .keep
        changeSet.folderList = nil

        var slice = CatchUpSliceResult()
        do {
            _ = try await applyChangeSet(changeSet, account: account, request: request)
        } catch {
            // Every folder the slice read failed, or a write failed: the failed
            // folders are left out, the rest stay pending.
            BackgroundSyncLogger.logDebug("[OtherFolders] \(accountId.prefix(8)): apply failed: \(error)")
            for changes in changeSet.folders {
                if case .failed = changes.status { slice.inFlightFolderIds.insert(changes.folderId) }
            }
            stampOtherFolderAttempts(accountId: accountId, folderIds: slice.inFlightFolderIds)
            return slice
        }

        for changes in changeSet.folders {
            let folderId = changes.folderId
            switch changes.status {
            case .notRun:
                continue
            case .failed:
                slice.inFlightFolderIds.insert(folderId)
            case .baselining:
                if changes.cursor != nil || !changes.records.isEmpty { slice.progressedFolderIds.insert(folderId) }
            case .tracked, .baselineReady, .refused:
                slice.finishedFolderIds.insert(folderId)
            case .untracked(let observation):
                do {
                    let refresh = try await refreshUntrackedFolder(
                        folderId: folderId, observation: observation, account: account, provider: provider,
                        deadline: Date().addingTimeInterval(sliceContext.secondsLeft), pass: nil,
                        otherFolderSlice: sliceContext)
                    if refresh != .listingNotStarted { slice.finishedFolderIds.insert(folderId) }
                } catch {
                    BackgroundSyncLogger.logDebug("[OtherFolders] \(accountId.prefix(8)): listing of \(folderId.suffix(12)) failed: \(error)")
                    slice.inFlightFolderIds.insert(folderId)
                }
            }
        }
        slice.progressedFolderIds.formUnion(slice.finishedFolderIds)
        stampOtherFolderAttempts(accountId: accountId, folderIds: slice.finishedFolderIds.union(slice.inFlightFolderIds))
        BackgroundSyncLogger.logDebug(
            "[OtherFolders] \(accountId.prefix(8)): slice asked \(folders.count), finished \(slice.finishedFolderIds.count), "
            + "moved \(slice.progressedFolderIds.count - slice.finishedFolderIds.count), failed \(slice.inFlightFolderIds.count)")
        return slice
    }

    /// Records that these folders' reads finished or failed now, for the order
    /// of the next runs (`otherFolderReadOrder`).
    private func stampOtherFolderAttempts(accountId: String, folderIds: Set<String>) {
        guard !folderIds.isEmpty else { return }
        let now = Date()
        for folderId in folderIds { otherFolderAttemptedAt[accountId, default: [:]][folderId] = now }
    }

    /// The clock an other-folder run is measured on: the real one, or in a test
    /// the one it installed (`setOtherFolderRunClockForTesting`).
    private var otherFolderRunClock: @Sendable () -> Date {
        #if DEBUG
        if let clock = otherFolderRunClockForTesting { return clock }
        #endif
        return { Date() }
    }

    #if DEBUG
    /// Test seam: waits until the account's other-folder run is done.
    func awaitOtherFolderRunForTesting(accountId: String) async {
        while let task = otherFolderRunTasks[accountId] { await task.value }
    }

    /// Test seam: the clock the next other-folder runs are measured on (nil:
    /// the real one).
    func setOtherFolderRunClockForTesting(_ clock: (@Sendable () -> Date)?) {
        otherFolderRunClockForTesting = clock
    }
    #endif
}
