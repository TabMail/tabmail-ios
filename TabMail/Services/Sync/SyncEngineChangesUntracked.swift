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
// change pass whose read did not throw, after that read, every armed folder of
// the account (count the predicate, not the call sites: Memory 114), while the
// read's budget lasts (#1287). A folder the pass does not reach stays armed for
// a later pass.

extension SyncEngine {

    /// Re-drive the account's armed folders, one after another, after the pass
    /// has read. A reaction starts only before `end`, the end of the read budget
    /// the pass sampled for its read (`changeReadEnd`, before the caller's own
    /// deadline). A reaction already running at `end` runs on until it completes
    /// or its pass is cancelled (the caller's timeout). One stopped before it
    /// stamps the new epoch leaves the folder armed for a later re-drive; one
    /// stopped after the stamp leaves it unarmed under the new epoch, its old
    /// rows purged and the new ones not yet listed (unless the listing committed
    /// some before it stopped), until its next listing fills it.
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
    /// - Parameter otherFolderSlice: the request bound of the other-folder run's
    ///   slice this refresh belongs to (#1110), nil for a pass. A listing starts
    ///   only while the slice has budget (`.listingNotStarted` otherwise: the run
    ///   lists the folder in a later slice), and each of its requests is bounded
    ///   as a request of the older-mail check (`ListingRequestBound`): a window
    ///   read the slice's end leaves unstarted (`ListingRequestBound.Cut`, after
    ///   the epoch check) is a listing not started (`.listingNotStarted`); one
    ///   the request limit cuts proves nothing (`.unproven`). Either way the
    ///   folder's counters stay as they were, so it stays changed and a later
    ///   slice or run lists it, and the run's listing owes no deep pass and
    ///   marks nothing due (`listFolder`); the listing shows no download count
    ///   (no pass is running to clear it); and a due mark alone
    ///   (`FolderChangeState.listingDue`) does not list the folder, only counters
    ///   that moved or a check the reader owes (`UntrackedObservation.mustList`).
    ///   The listing runs no deletion check (its walk can take longer than a
    ///   slice) and leaves any due mark as it is; the catch-up's weekly
    ///   whole-folder check of an other folder removes what the check would
    ///   have. *Superseded (#1110):* "A deletion check cut by a slice's end
    ///   leaves that mark, and honouring it would list the folder again in every
    ///   run".
    func refreshUntrackedFolder(
        folderId: String, observation: UntrackedObservation, account: Account, provider: any EmailProvider,
        deadline: Date? = nil, pass: UUID? = nil, otherFolderSlice: ListingRequestBound? = nil
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

        let markedDue = otherFolderSlice == nil && FolderChangeState(raw: folder.changeState).listingDue
        guard Self.untrackedFolderChanged(
            observation: observation, lastKnownUidNext: folder.lastKnownUidNext,
            totalCount: folder.totalCount, lastKnownHighestModSeq: folder.lastKnownHighestModSeq,
            listingDue: markedDue || observation.mustList) else {
            BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name) unchanged (uidNext=\(observation.uidNext), count=\(observation.messageCount), modseq=\(observation.highestModSeq.map(String.init) ?? "-"))")
            // A quiet folder is the one that would otherwise never get an epoch.
            // Bootstrap only (never an overwrite); the binding predicates are
            // inside the UPDATE (a folder holding rows is the verified door's).
            if Self.uidValidityBootstrapWrite(observed: observation.uidValidity, stored: folder.lastKnownUidValidity) != nil {
                try await bootstrapFolderUidValidity(folderId: folder.id, observed: observation.uidValidity)
            }
            return .notListed
        }

        if let otherFolderSlice, !otherFolderSlice.slice.hasBudget() {
            BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name) changed: no slice time left to start its listing — later slice")
            return .listingNotStarted
        }
        BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name) changed (uidNext: \(folder.lastKnownUidNext ?? 0)→\(observation.uidNext), count: \(folder.totalCount)→\(observation.messageCount))")
        let newCount = max(0, observation.messageCount - folder.totalCount)
        if newCount > 0, otherFolderSlice == nil { publishDownloading(newCount, forAccount: account.id) }
        // The listing writes the folder's counters from its own selection, with
        // its rows (`runSyncMessages`); this observation only decided to list.
        // One classifier (`listFolder` → `runListing`): no error escapes it.
        let outcome = await listFolder(
            folder, provider: provider, limit: SyncConfig.syncMessageLimit, pass: pass, bound: otherFolderSlice)
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
        case .unproven(_, _, let error?) where error is ListingRequestBound.Cut:
            // The slice ended before the window read could start (after the
            // epoch check): nothing of the listing was asked, so it has not
            // started, and a later slice lists the folder.
            BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name): slice ended before its window read — later slice")
            return .listingNotStarted
        case .unproven:
            BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name): listing unproven — skipping")
            return .unproven
        case .folderGone:
            BackgroundSyncLogger.logDebug("[Sync] Untracked \(folder.name): folder gone — skipping")
            return .notListed
        }
        guard let serverCount = result.listedCounters?.messageCount else { return .unproven }
        // An other-folder run's listing ends here (#1110): the deletion check
        // can walk the whole folder, longer than a slice, and the catch-up's
        // weekly whole-folder check of an other folder removes what it would.
        guard otherFolderSlice == nil else { return .listed }
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
    /// Changed, but the other-folder run's slice had no time left to start its
    /// listing, or its window read after the epoch check (#1110): the run lists
    /// it in a later slice. Never for a pass.
    case listingNotStarted
}

/// The bound of a listing in an other-folder run's slice (#1110), the same as
/// a request of the older-mail check (each provider's `catchUpFolder`). A request
/// is one provider call (the epoch check's sample, the listing's window read),
/// bounded as a whole: the call starts only while the slice has time, and the
/// listing waits for it at most `timeoutSeconds` (the run's
/// `CatchUpContext.requestTimeoutSeconds`, `SyncConfig.catchUpRequestTimeoutSeconds`).
/// The limit covers everything inside the call: the connection checkout, a
/// connect and login on a cold session, SELECT, and the FETCH or SEARCH, and
/// `withTimeout` returns at the limit whether or not the call stops at once.
/// So a command of a call that started before the slice's end may start after
/// it, and the slice holds the account's turn at most to its end plus one
/// request, as an older-mail slice does. A read cut or timed out throws before
/// the listing writes anything: the listing proved nothing, the folder stays
/// changed, and a later slice or run lists it.
struct ListingRequestBound: Sendable {
    /// The slice's time.
    let slice: ChangeContext
    /// Longest one request may take.
    let timeoutSeconds: TimeInterval

    /// The slice's time ran out before a request of the listing could start.
    struct Cut: Error {}

    /// `operation` as one request: not started once the slice is over, and
    /// abandoned (`TimeoutError`) after `timeoutSeconds`.
    func request<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard slice.hasBudget() else { throw Cut() }
        return try await withTimeout(seconds: timeoutSeconds, operation: operation)
    }
}
