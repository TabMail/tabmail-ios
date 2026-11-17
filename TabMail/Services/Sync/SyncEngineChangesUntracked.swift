/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - Folders no bookmark covers, and the turnover re-drive (ADR-IOS-111)
//
// Provider-blind (no provider cast, no provider test; `ChangeSeamFenceTests`).
//
// A reader reports a folder it cannot track (`FolderChangeStatus.untracked`: a
// server without change tracking, a mailbox that keeps none) with the counters
// the server reported. The engine compares them with the folder row and runs the
// window listing for a changed folder, then the count-mismatch deletion check
// (ADR-IOS-051 phase 2). This is the 5-minute path such folders always had; it
// is permanent for servers without change tracking.
//
// The turnover re-drive: a folder whose UIDVALIDITY reset reaction is armed
// (`Folder.uidValidityResetPendingAt`) and was interrupted is re-driven at the
// start of every change pass, every armed folder of the account (count the
// predicate, not the call sites: Memory 114).

extension SyncEngine {

    /// Re-drive every armed folder of the account before the pass reads.
    func redriveArmedTurnovers(accountId: String) async {
        let armed = (try? await dbPool.read { db in
            try Folder
                .filter(Column("accountId") == accountId && Column("uidValidityResetPendingAt") != nil)
                .fetchAll(db)
        }) ?? []
        for folder in armed where !folder.path.isEmpty {
            BackgroundSyncLogger.logDebug("[Sync] Change pass: re-driving the turnover reaction of \(folder.name)")
            await AccountManager.shared.runUidValidityResetReaction(accountId: accountId, folderPath: folder.path)
        }
    }

    /// Whether the counters a reader observed for an untracked folder say it
    /// changed since the folder row's own: a new UID, a different count, or a
    /// different HIGHESTMODSEQ (both known). Pure, for tests.
    nonisolated static func untrackedFolderChanged(
        observation: UntrackedObservation, lastKnownUidNext: Int?, totalCount: Int, lastKnownHighestModSeq: Int?
    ) -> Bool {
        let uidNextChanged = lastKnownUidNext != nil && observation.uidNext != lastKnownUidNext
        let countChanged = observation.messageCount != totalCount
        let modSeqChanged = modSeqIndicatesChange(server: observation.highestModSeq, cached: lastKnownHighestModSeq)
        return uidNextChanged || countChanged || modSeqChanged
    }

    /// One untracked folder: the turnover trigger, the epoch bootstrap, and for a
    /// changed folder the window listing, the stored counters and the deletion
    /// check. Returns whether the folder was listed.
    func refreshUntrackedFolder(
        folderId: String, observation: UntrackedObservation, account: Account, provider: any EmailProvider
    ) async throws -> Bool {
        guard let folder = try await dbPool.read({ db in try Folder.fetchOne(db, key: folderId) }),
              !folder.path.isEmpty, folder.uidValidityResetPendingAt == nil else { return false }

        // The free turnover trigger: both epochs KNOWN and different. A trigger,
        // not a guard: the reaction re-reads everything fresh.
        if let observed = Self.knownUidValidity(observation.uidValidity).flatMap({ UInt32(exactly: $0) }),
           let stored = Self.knownUidValidity(folder.lastKnownUidValidity).flatMap({ UInt32(exactly: $0) }),
           observed != stored {
            AccountManager.shared.fireUidValidityChangeHandler(
                accountId: account.id, folderPath: folder.path, storedValue: stored, observedValue: observed)
            return false
        }

        guard Self.untrackedFolderChanged(
            observation: observation, lastKnownUidNext: folder.lastKnownUidNext,
            totalCount: folder.totalCount, lastKnownHighestModSeq: folder.lastKnownHighestModSeq) else {
            BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name) unchanged (uidNext=\(observation.uidNext), count=\(observation.messageCount), modseq=\(observation.highestModSeq.map(String.init) ?? "-"))")
            // A quiet folder is the one that would otherwise never get an epoch.
            // Bootstrap only (never an overwrite); the binding predicates are
            // inside the UPDATE (a folder holding rows is the verified door's).
            if Self.uidValidityBootstrapWrite(observed: observation.uidValidity, stored: folder.lastKnownUidValidity) != nil {
                try await bootstrapFolderUidValidity(folderId: folder.id, observed: observation.uidValidity)
            }
            return false
        }

        BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name) changed (uidNext: \(folder.lastKnownUidNext ?? 0)→\(observation.uidNext), count: \(folder.totalCount)→\(observation.messageCount))")
        let newCount = max(0, observation.messageCount - folder.totalCount)
        if newCount > 0 { publishDownloading(newCount, forAccount: account.id) }
        do {
            try await syncMessages(for: folder, provider: provider, limit: SyncConfig.syncMessageLimit)
        } catch {
            if Self.isSelectFailedError(error) {
                BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name): SELECT failed — skipping")
                return false
            }
            throw error
        }

        try await dbPool.write { db in
            var assignments: [ColumnAssignment] = [
                Column("lastKnownUidNext").set(to: observation.uidNext),
                Column("totalCount").set(to: observation.messageCount)
            ]
            if let modseq = observation.highestModSeq {
                assignments.append(Column("lastKnownHighestModSeq").set(to: modseq))
            }
            _ = try Folder.filter(Column("id") == folder.id).updateAll(db, assignments)
            // Bootstrap as its own conditional statement (never an overwrite).
            try Self.bootstrapFolderUidValidity(db, folderId: folder.id, observed: observation.uidValidity)
        }

        // ADR-IOS-051 phase 2: the live local count against the server's.
        do {
            let localCount = try await dbPool.read { db in
                try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db)
            }
            if Self.shouldReconcileDeletions(
                localCount: localCount, serverCount: observation.messageCount,
                tolerance: SyncConfig.deletionReconcileCountTolerance) {
                BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name) local=\(localCount) > server=\(observation.messageCount) — reconciling external deletions")
                await reconcileExternallyDeletedMessages(
                    folder: folder, provider: provider, expectedGhosts: localCount - observation.messageCount)
            }
        } catch {
            // Best effort: the evidence is durable and re-fires next pass.
            BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name): reconcile trigger check failed: \(error)")
        }
        return true
    }
}
