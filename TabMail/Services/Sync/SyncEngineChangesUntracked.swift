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
// (`Folder.uidValidityResetPendingAt`) and was interrupted is re-driven by every
// change pass after its read, every armed folder of the account (count the
// predicate, not the call sites: Memory 114), while the read's budget lasts
// (#1287). A folder the pass does not reach stays armed for the next pass.

extension SyncEngine {

    /// Re-drive the account's armed folders, one after another, after the pass
    /// has read. A reaction starts only before `end` (the pass's read budget,
    /// `changeReadEnd`, which ends before the caller's own deadline); one already
    /// running at `end` finishes or is cancelled with its pass, and its flag stays
    /// set until a reaction completes.
    func redriveArmedTurnovers(accountId: String, until end: Date) async {
        let armed = ((try? await dbPool.read { db in
            try Folder
                .filter(Column("accountId") == accountId && Column("uidValidityResetPendingAt") != nil)
                .fetchAll(db)
        }) ?? []).filter { !$0.path.isEmpty }
        for (index, folder) in armed.enumerated() {
            guard changeReadClock() < end else {
                BackgroundSyncLogger.logDebug("[Sync] Change pass: read budget spent; \(armed.count - index) armed folder(s) wait for the next pass")
                return
            }
            BackgroundSyncLogger.logDebug("[Sync] Change pass: re-driving the turnover reaction of \(folder.name)")
            await AccountManager.shared.runUidValidityResetReaction(accountId: accountId, folderPath: folder.path)
        }
    }

    /// Whether the counters a reader observed for an untracked folder say it
    /// changed since the folder row's own: a new UID, a different count, or a
    /// different HIGHESTMODSEQ (both known). Pure, for tests.
    nonisolated static func untrackedFolderChanged(
        observation: UntrackedObservation, lastKnownUidNext: Int?, totalCount: Int, lastKnownHighestModSeq: Int?,
        listingDue: Bool = false
    ) -> Bool {
        // A count check that did not finish asks for the next listing (#755).
        if listingDue { return true }
        // No stored UIDNEXT: no listing has written the folder's counters yet,
        // so nothing proves it unchanged.
        let uidNextChanged = lastKnownUidNext == nil || observation.uidNext != lastKnownUidNext
        let countChanged = observation.messageCount != totalCount
        // A HIGHESTMODSEQ the server reports while the last listing stored none
        // (a listing on a session without CONDSTORE) proves nothing unchanged:
        // a flag-only change would otherwise stay unseen (#755).
        let modSeqChanged = modSeqIndicatesChange(server: observation.highestModSeq, cached: lastKnownHighestModSeq)
            || (knownModSeq(observation.highestModSeq) != nil && knownModSeq(lastKnownHighestModSeq) == nil)
        return uidNextChanged || countChanged || modSeqChanged
    }

    /// One untracked folder: the turnover trigger, the epoch bootstrap, and for a
    /// changed folder the window listing (which writes the folder's counters)
    /// and the deletion check on that listing's count. Returns what the refresh
    /// did (`UntrackedRefresh`).
    func refreshUntrackedFolder(
        folderId: String, observation: UntrackedObservation, account: Account, provider: any EmailProvider,
        deadline: Date? = nil, pass: UUID? = nil
    ) async throws -> UntrackedRefresh {
        guard let folder = try await dbPool.read({ db in try Folder.fetchOne(db, key: folderId) }),
              !folder.path.isEmpty, folder.uidValidityResetPendingAt == nil else { return .notListed }

        // The free turnover trigger: both epochs KNOWN and different. A trigger,
        // not a guard: the reaction re-reads everything fresh.
        if let observed = Self.knownUidValidity(observation.uidValidity).flatMap({ UInt32(exactly: $0) }),
           let stored = Self.knownUidValidity(folder.lastKnownUidValidity).flatMap({ UInt32(exactly: $0) }),
           observed != stored {
            AccountManager.shared.fireUidValidityChangeHandler(
                accountId: account.id, folderPath: folder.path, storedValue: stored, observedValue: observed)
            return .notListed
        }

        guard Self.untrackedFolderChanged(
            observation: observation, lastKnownUidNext: folder.lastKnownUidNext,
            totalCount: folder.totalCount, lastKnownHighestModSeq: folder.lastKnownHighestModSeq,
            listingDue: FolderChangeState(raw: folder.changeState).listingDue || observation.mustList) else {
            BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name) unchanged (uidNext=\(observation.uidNext), count=\(observation.messageCount), modseq=\(observation.highestModSeq.map(String.init) ?? "-"))")
            // A quiet folder is the one that would otherwise never get an epoch.
            // Bootstrap only (never an overwrite); the binding predicates are
            // inside the UPDATE (a folder holding rows is the verified door's).
            if Self.uidValidityBootstrapWrite(observed: observation.uidValidity, stored: folder.lastKnownUidValidity) != nil {
                try await bootstrapFolderUidValidity(folderId: folder.id, observed: observation.uidValidity)
            }
            return .notListed
        }

        BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name) changed (uidNext: \(folder.lastKnownUidNext ?? 0)→\(observation.uidNext), count: \(folder.totalCount)→\(observation.messageCount))")
        let newCount = max(0, observation.messageCount - folder.totalCount)
        if newCount > 0 { publishDownloading(newCount, forAccount: account.id) }
        // The listing writes the folder's counters from its own selection, with
        // its rows (`runSyncMessages`); this observation only decided to list.
        // One classifier (`listFolder` → `runListing`): no error escapes it.
        let outcome = await listFolder(folder, provider: provider, limit: SyncConfig.syncMessageLimit, pass: pass)
        try Task.checkCancellation()
        // ADR-IOS-051 phase 2: the live local count against the count of the
        // listing that just ran, never the observation's. A listing that
        // proved nothing has no count: no phase 2 this pass, and the folder
        // was not listed (the next pass lists it again).
        let result: SyncMessagesResult
        switch outcome {
        case .proven(let proven): result = proven
        case .notListable:
            BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name): not listable — skipping")
            return .notListed
        case .unproven:
            BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name): listing unproven — skipping")
            return .unproven
        case .folderGone:
            BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name): folder gone — skipping")
            return .notListed
        }
        guard let serverCount = result.listedCounters?.messageCount else { return .unproven }
        // Bounded by the pass's deadline: this runs inside the account's turn.
        await reconcileDeletionsAfterListing(
            folder: folder, provider: provider, serverCount: serverCount, logPrefix: "[Sync] Untracked", deadline: deadline)
        return .listed
    }
}

/// What one untracked refresh did, by this pass's server answer (#755).
enum UntrackedRefresh: Sendable, Equatable {
    /// The folder was listed and the listing proved its window.
    case listed
    /// Not listed: unchanged, a turnover, or the server made it not listable
    /// (SELECT refused, no usable EXISTS).
    case notListed
    /// A listing started and failed to prove its window (a short FETCH, an
    /// EXISTS 0 not confirmed): the pass's full-sync stamp is withheld.
    case unproven
}
