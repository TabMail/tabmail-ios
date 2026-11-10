/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// IMAP's opaque per-folder catch-up state (ADR-IOS-107), stored as JSON in
/// `Folder.catchUpState`. Only `IMAPProvider` reads or writes it.
struct IMAPCatchUpState: Codable, Equatable, Sendable {
    /// The UIDVALIDITY every UID and stamp below belongs to. A folder whose known
    /// epoch differs discards the whole state and lists again from UID 1.
    var epoch: UInt32
    /// HIGHESTMODSEQ as it stood BEFORE THE FIRST RANGE of the last completed
    /// listing — the stamp the cheap check compares. Never the last range's: a
    /// change landing in an already-listed range while the listing is still running
    /// moves the server's counter past this value, so the folder is listed again.
    var completionStamp: Int?
    /// When the last listing completed. Drives the full-check interval and the
    /// oldest-first order.
    var lastCompletedAt: Date?
    /// The listing in progress, if any.
    var listing: Listing?

    struct Listing: Codable, Equatable, Sendable {
        /// HIGHESTMODSEQ taken when this listing started, before its first range.
        /// Becomes `completionStamp` when the listing completes.
        var firstStamp: Int?
        /// The next listing range starts at the first local UID `>=` this.
        var nextUid: Int
    }

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Nil for no state or an unreadable one. Either way the folder starts over,
    /// which can only cost a re-listing.
    static func decode(_ raw: String?) -> IMAPCatchUpState? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(IMAPCatchUpState.self, from: data)
    }
}

extension IMAPProvider {

    /// What a folder needs this pass. Pure, so the decision is testable on its own.
    enum CatchUpPlan: Equatable {
        /// Nothing: MODSEQ unchanged and the full check not due, or the network is
        /// expensive and nothing signals a change.
        case none
        /// List the folder by UID ranges, starting at or continuing `listing`.
        case list(IMAPCatchUpState.Listing)
    }

    /// The per-folder decision.
    /// - `freshModSeq` is this pass's HIGHESTMODSEQ (`Folder.lastKnownHighestModSeq`,
    ///   written by the folder upsert from STATUS before any range runs), nil on a
    ///   server without CONDSTORE.
    /// - On an expensive network only a MODSEQ change may list: that is evidence of
    ///   a change, whereas the full check (and continuing one) waits for a
    ///   non-expensive network.
    nonisolated static func catchUpPlan(
        state: IMAPCatchUpState?, freshModSeq: Int?, isExpensiveNetwork: Bool, now: Date
    ) -> CatchUpPlan {
        let modSeqChanged: Bool = {
            guard let stamp = state?.completionStamp, let freshModSeq else { return false }
            return freshModSeq != stamp
        }()
        let fullCheckDue: Bool = {
            guard let last = state?.lastCompletedAt else { return true }
            return now.timeIntervalSince(last) >= SyncConfig.catchUpFullCheckIntervalSeconds
        }()
        if isExpensiveNetwork && !modSeqChanged { return .none }
        if let listing = state?.listing { return .list(listing) }
        if modSeqChanged || fullCheckDue {
            return .list(IMAPCatchUpState.Listing(firstStamp: freshModSeq, nextUid: 1))
        }
        return .none
    }

    /// `EmailProvider.catchUp` for IMAP (ADR-IOS-107). For each folder whose epoch is
    /// known: the cheap check (this pass's HIGHESTMODSEQ against the stored
    /// completion stamp, no request), and when that or the full-check interval
    /// calls for it, a flags-only listing by UID ranges that resumes across passes.
    /// Oldest-completed folder first. Every request is preceded by a budget check
    /// and bounded by `SyncConfig.catchUpRequestTimeoutSeconds`; a timeout or any
    /// failure ends the folder's work for the pass, keeping what was proven.
    func catchUp(
        folders: [Folder], localRows: any CatchUpLocalRowReader, context: CatchUpContext
    ) async -> [CatchUpFolderResult] {
        // Oldest first: never-completed folders, then by completion time. The sort is
        // stable on the caller's order for ties.
        let ordered = folders.enumerated().sorted { lhs, rhs in
            let l = IMAPCatchUpState.decode(lhs.element.catchUpState)?.lastCompletedAt ?? .distantPast
            let r = IMAPCatchUpState.decode(rhs.element.catchUpState)?.lastCompletedAt ?? .distantPast
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)

        var results: [CatchUpFolderResult] = []
        for folder in ordered {
            guard context.hasBudget() else { break }
            if let result = await catchUpFolder(folder, localRows: localRows, context: context) {
                results.append(result)
            }
        }
        return results
    }

    /// One folder's catch-up. Nil when the folder needs nothing, or is not eligible:
    /// an empty path, a quarantined folder, or an UNKNOWN epoch (C3 — nothing is
    /// ever decided about a UID whose numbering is unproven).
    private func catchUpFolder(
        _ folder: Folder, localRows: any CatchUpLocalRowReader, context: CatchUpContext
    ) async -> CatchUpFolderResult? {
        guard !folder.path.isEmpty, folder.uidValidityResetPendingAt == nil,
              let stored = folder.lastKnownUidValidity, stored > 0,
              let epoch = UInt32(exactly: stored) else { return nil }

        // A state from another epoch describes UIDs that no longer exist: drop it.
        let state = IMAPCatchUpState.decode(folder.catchUpState).flatMap { $0.epoch == epoch ? $0 : nil }
        let plan = Self.catchUpPlan(
            state: state, freshModSeq: folder.lastKnownHighestModSeq,
            isExpensiveNetwork: context.isExpensiveNetwork, now: context.clock())
        guard case .list(var listing) = plan else { return nil }

        var result = CatchUpFolderResult(folderId: folder.id, epoch: epoch)
        let span = SyncConfig.catchUpListingRangeSpan
        let timeout = SyncConfig.catchUpRequestTimeoutSeconds
        let path = folder.path
        var completed = false

        rangeLoop: while true {
            let lo: Int
            do {
                guard let next = try await localRows.firstNumericId(folderId: folder.id, atLeast: listing.nextUid) else {
                    completed = true
                    break rangeLoop
                }
                lo = next
            } catch {
                break rangeLoop
            }
            let hi = min(lo + span - 1, Int(UInt32.max))
            guard context.hasBudget() else { break rangeLoop }

            let listed: (flags: [UInt32: (isRead: Bool, isFlagged: Bool)], uidValidity: UInt32)
            let local: [CatchUpLocalRow]
            do {
                local = try await localRows.rows(folderId: folder.id, numericIdsFrom: lo, through: hi)
                listed = try await withTimeout(seconds: timeout) {
                    try await self.listFlagsInUIDRange(folder: path, from: lo, to: hi)
                }
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CatchUp] \(path) \(lo):\(hi): listing failed (\(error)) — stopping this folder for the pass")
                }
                break rangeLoop
            }
            guard listed.uidValidity == epoch else {
                // The server is serving another numbering (or none): nothing listed
                // here may be applied. Report what was observed so the full sync can
                // run the turnover reaction; the state is left as it was.
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CatchUp] \(path): SELECT reported UIDVALIDITY \(listed.uidValidity), folder holds \(epoch) — applying nothing")
                }
                return CatchUpFolderResult(folderId: folder.id, epoch: listed.uidValidity == 0 ? nil : listed.uidValidity)
            }

            var candidates: [UInt32] = []
            for row in local {
                guard let uid = UInt32(row.messageId) else { continue }
                if let server = listed.flags[uid] {
                    if server.isRead != row.isRead || server.isFlagged != row.isFlagged {
                        result.flagUpdates.append(CatchUpFlagUpdate(
                            messageId: row.messageId, isRead: server.isRead, isFlagged: server.isFlagged))
                    }
                } else {
                    candidates.append(uid)
                }
            }

            if !candidates.isEmpty {
                // A UID missing from the FETCH is only a candidate: a short FETCH is a
                // real server shape. The walk's own absence proof decides, under the
                // same epoch. Without the budget for it, the range's flags still
                // count, but the cursor stays so the next pass re-lists it.
                guard context.hasBudget() else { break rangeLoop }
                let confirmed: UIDExistenceResult
                do {
                    let toConfirm = candidates
                    confirmed = try await withTimeout(seconds: timeout) {
                        try await self.searchExistingUIDs(folder: path, uids: toConfirm)
                    }
                } catch {
                    break rangeLoop
                }
                guard confirmed.uidValidity == epoch else {
                    return CatchUpFolderResult(folderId: folder.id, epoch: confirmed.uidValidity == 0 ? nil : confirmed.uidValidity)
                }
                result.removedIds += candidates.filter { !confirmed.found.contains($0) }.map(String.init)
            }
            listing.nextUid = hi + 1
        }

        var newState = state ?? IMAPCatchUpState(epoch: epoch)
        if completed {
            newState.completionStamp = listing.firstStamp
            newState.lastCompletedAt = context.clock()
            newState.listing = nil
        } else {
            newState.listing = listing
        }
        result.newState = newState.encoded()
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CatchUp] \(path): flags=\(result.flagUpdates.count) removed=\(result.removedIds.count) \(completed ? "listing complete" : "resumes at UID \(listing.nextUid)")")
        }
        return result
    }
}
