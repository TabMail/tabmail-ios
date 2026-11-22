/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Folders a user action lands in (#1109). Such a folder is FOLLOWED from then
/// on (`Folder.isFollowed`): it joins the syncable set (`SyncEngine.isSyncable`)
/// and so gets what a favourite gets, change reads, the catch-up and the epoch
/// re-drive, with no provider code above the boundary. The action also starts a
/// catch-up run for the folders it landed in, so the whole folder is reconciled
/// soon after the newest messages are listed, not at the backfill worker's next
/// turn. The access points: opening a folder (`AccountManager.syncFolders`), a
/// move, archive or delete that drained (its source and destination,
/// `AccountOperationExecutor.finishDrain`), and opening a message
/// (`MessageDetailViewModel`), from a search result, a chat or AI answer or a
/// folder alike.
extension SyncEngine {

    /// The one writer of `Folder.isFollowed`: marks every folder of `folderIds`
    /// that is not followed yet, column-scoped (no other column, so no backfill
    /// version bump). Never clears a mark. Returns the folders marked now.
    @discardableResult
    nonisolated static func markFollowed(folderIds: [String], db: Database) throws -> [String] {
        let ids = Array(Set(folderIds))
        guard !ids.isEmpty else { return [] }
        let unfollowed = Folder.filter(keys: ids).filter(Column(Folder.followedColumn) == false)
        let marked = try String.fetchAll(db, unfollowed.select(Column("id")))
        guard !marked.isEmpty else { return [] }
        try Folder.filter(keys: marked).updateAll(db, Column(Folder.followedColumn).set(to: true))
        return marked
    }

    /// Marks the folders followed (`markFollowed`). A failed write is logged and
    /// marks nothing: the folders stay as they were until the next action that
    /// lands in them.
    func followFolders(_ folderIds: [String]) async {
        guard !folderIds.isEmpty else { return }
        do {
            let marked = try await dbPool.write { db in try Self.markFollowed(folderIds: folderIds, db: db) }
            if !marked.isEmpty, DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[Follow] followed now: \(marked)")
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[Follow] could not mark \(folderIds) followed: \(error)")
            }
        }
    }

    /// A user action landed in these folders of the account: they are followed
    /// (`followFolders`), then reconciled by a catch-up run (`startAccessCatchUp`).
    /// Returns once the mark is written; the run goes on without the caller.
    func folderAccessed(accountId: String, folderIds: [String]) async {
        guard !folderIds.isEmpty else { return }
        await followFolders(folderIds)
        startAccessCatchUp(accountId: accountId, folderIds: folderIds)
    }

    /// Starts the account's access catch-up run for `folderIds`, or hands them
    /// to the one already running, which takes them when its current run ends.
    /// Each run asks only its folders (the syncable ones among them, so a
    /// folder whose mark did not land is not asked), under the account's turn
    /// and slice pacing like every catch-up slice, until they make no progress
    /// or `SyncConfig.accessCatchUpRunSeconds` is up.
    func startAccessCatchUp(accountId: String, folderIds: [String]) {
        guard !folderIds.isEmpty else { return }
        accessCatchUpPending[accountId, default: []].formUnion(folderIds)
        guard accessCatchUpTasks[accountId] == nil else { return }
        accessCatchUpTasks[accountId] = Task { await self.runAccessCatchUps(accountId: accountId) }
    }

    /// The access runs of one account, one after the other, until no folder is
    /// waiting. The task's entry is cleared in the same actor turn as the last
    /// empty check, so a folder handed over after it starts a new task.
    private func runAccessCatchUps(accountId: String) async {
        while !Task.isCancelled, let folderIds = accessCatchUpPending.removeValue(forKey: accountId), !folderIds.isEmpty {
            let account: Account?
            do {
                account = try await dbPool.read { db in try Account.fetchOne(db, key: accountId) }
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[Follow] access catch-up: account read failed: \(error)")
                }
                continue
            }
            guard let account else { break }
            var run = CatchUpRun.snapshot(deadline: Date().addingTimeInterval(SyncConfig.accessCatchUpRunSeconds))
            run.accessedFolderIds = folderIds
            let progressed = await runCatchUpRun(account: account, run: run)
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[Follow] access catch-up for \(folderIds.sorted()): progressed=\(progressed)")
            }
        }
        if !Task.isCancelled { accessCatchUpTasks[accountId] = nil }
    }

    #if DEBUG
    /// Test seam: waits until the account's access catch-up runs are done.
    func awaitAccessCatchUpForTesting(accountId: String) async {
        while let task = accessCatchUpTasks[accountId] { await task.value }
    }
    #endif
}
