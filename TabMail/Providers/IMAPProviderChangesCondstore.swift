/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

// MARK: - IMAP change reading with CONDSTORE, without QRESYNC (#755, ADR-IOS-111)
//
// A CONDSTORE server reports changed flags (`UID FETCH … (CHANGEDSINCE m)`) but
// not expunges, and may leave HIGHESTMODSEQ unchanged by one. Removals are
// therefore counted: the bookmark (V, m, N0, M0) carries the selection's EXISTS,
// and owed = M0 + |A| - M1, A being the arrivals in [N0, N1). Owed above 0 starts
// a removal check over the newest held UIDs below N0 (up to
// `SyncConfig.imapChangeRemovalCheckWindow`): a UID a chunk SEARCH leaves out is
// a candidate, removed only when a FETCH and a confirming SEARCH on the same
// selection both leave it out (`rereadIds`). Older held rows are the catch-up's,
// armed with the check. A check that does not fit the budget is resumed on later
// passes (its progress rides in the bookmark, `pendingCheck`); a slice of an
// other-folder run takes one step of it at most (`runRemovalCheck`, #1110); every pass
// that does not finish lists the folder (`UntrackedObservation.mustList`) with the
// bookmark unchanged. A finished check commits the new bookmark of the pass that
// STARTED it, so every change after that checkpoint is read again.

/// A CONDSTORE removal check that has not finished (#755).
struct IMAPRemovalCheckProgress: Codable, Equatable, Sendable {
    /// The new bookmark of the pass that started the check: (V, m1, N1, M1).
    let pending: Bookmark
    /// The held UIDs below this are not yet checked.
    var nextBelow: UInt32
    /// How many more held rows the check searches.
    var remaining: Int
    /// Candidates found and not yet proven gone.
    var unproven: [UInt32]

    struct Bookmark: Codable, Equatable, Sendable {
        let highestModSeq: UInt64
        let uidNext: UInt32
        let messageCount: Int
    }
}

extension IMAPProvider {

    #if DEBUG
    func setRemovalCheckWindowForTesting(_ window: Int?) { removalCheckWindowForTesting = window }
    #endif

    private var removalCheckWindow: Int {
        #if DEBUG
        if let removalCheckWindowForTesting { return removalCheckWindowForTesting }
        #endif
        return SyncConfig.imapChangeRemovalCheckWindow
    }

    /// One folder with a bookmark carrying its count, on a CONDSTORE session.
    func readCondstoreFolder(
        _ folder: ChangeFolder, cursor: IMAPChangeCursor, observation: FolderObservation,
        recheckIds: [UInt32], server: IMAPServer, request: ChangeRequest
    ) async throws -> FolderChanges {
        let context = request.context
        if let served = observation.uidValidity, served != Int(cursor.uidValidity) {
            return FolderChanges(folderId: folder.id, status: .refused(.addressEpochChanged(served)))
        }
        // S-13: nothing changed only when every counter equals the bookmark's (an
        // expunge may leave HIGHESTMODSEQ as it was) and no check is pending.
        if cursor.pendingCheck == nil, recheckIds.isEmpty, observation.uidValidity == Int(cursor.uidValidity),
           observation.messageCount == cursor.messageCount, observation.uidNext == Int(cursor.uidNext),
           let modseq = observation.highestModSeq, UInt64(modseq) == cursor.highestModSeq {
            return FolderChanges(
                folderId: folder.id, status: .tracked, cursor: cursor.failingSince == nil ? nil : cursor.cleared.encoded)
        }
        guard context.hasBudget(), let m0 = cursor.messageCount else {
            return FolderChanges(folderId: folder.id, status: .notRun)
        }

        changeSelectedPath = nil
        let condStoreSelect = changeMode == .condstore(selectParameter: true)
        let selection = try await withTimeout(seconds: Self.changeSelectTimeout(secondsLeft: context.secondsLeft)) {
            condStoreSelect
                ? try await IMAPChangeCommands().selectCondStore(folder.path, on: server)
                : try await server.selectMailbox(folder.path)
        }
        changeSelectedPath = folder.path
        let served = selection.uidValidity.value
        guard served != 0 else { throw IMAPChangeReadIncomplete(folder: folder.path, missing: "UIDVALIDITY") }
        guard served == cursor.uidValidity else {
            return FolderChanges(folderId: folder.id, status: .refused(.addressEpochChanged(Int(served))))
        }
        // S-14: NOMODSEQ, or no EXISTS: untracked this pass, nothing removed.
        guard let modseq = selection.highestModificationSequenceValue, let m1 = selection.reportedMessageCount else {
            return try await untracked(folder, observation: observation, ids: recheckIds, server: server, request: request)
        }
        let uidNext = selection.uidNext.value
        guard uidNext != 0 else { throw IMAPChangeReadIncomplete(folder: folder.path, missing: "UIDNEXT") }
        // S-26: a bookmark stores count 0 only once `UID SEARCH ALL` reads
        // empty. Otherwise the SELECT contradicts the folder: untracked this
        // pass, the prior bookmark kept.
        if m1 == 0, await !searchReadsEmpty(server: server) {
            return try await untracked(folder, observation: observation, ids: recheckIds, server: server, request: request)
        }

        // S-15: changed flags from the lowest held UID (or the held range) up.
        let lowestHeld = try await request.localRows?.firstNumericId(folderId: folder.id, atLeast: 1)
        let lo = UInt32(clamping: [Self.heldRangeStart(folder), lowestHeld].compactMap { $0 }.min() ?? 1)
        var changed: [IMAPChangedFlags] = []
        if uidNext > lo {
            guard context.hasBudget() else { return FolderChanges(folderId: folder.id, status: .notRun) }
            let range = UIDSet(UID(lo)...UID(uidNext - 1))
            changed = try await withTimeout(seconds: Self.changeSelectTimeout(secondsLeft: context.secondsLeft)) {
                try await IMAPChangeCommands().flagsChangedSince(range, modSeq: cursor.highestModSeq, on: server)
            }
        }

        var changes = FolderChanges(folderId: folder.id, status: .tracked, addressEpoch: Int(served))
        let read = try await readChangedAndArrivals(
            changed, folder: folder, cursorUidNext: cursor.uidNext, servedUidNext: uidNext,
            server: server, request: request, into: &changes)
        guard case .read(let arrivals, let toFetch) = read else {
            if case .stopped(let result) = read { return result }
            return FolderChanges(folderId: folder.id, status: .notRun)
        }

        // S-16, S-17: the count, then the check, before the arrivals' FETCH.
        let owed = m0 + arrivals.count - m1
        guard owed >= 0 else { throw IMAPChangeCountMismatch(folder: folder.path) }
        let movedIn = try await heldIds(
            from: cursor.uidNext, below: uidNext, notIn: arrivals, folderId: folder.id, request: request)
        let created = cursor.pendingCheck == nil
        var check = cursor.pendingCheck ?? ((owed > 0 || !movedIn.isEmpty) ? IMAPRemovalCheckProgress(
            pending: .init(highestModSeq: modseq, uidNext: uidNext, messageCount: m1),
            nextBelow: cursor.uidNext, remaining: removalCheckWindow, unproven: []) : nil)
        // The check's own answer, kept apart from `changes`: a cut applies only it.
        var proven = FolderChanges(folderId: folder.id, status: .tracked, addressEpoch: Int(served))
        if var progress = check {
            progress.unproven = Array(Set(progress.unproven).union(movedIn)).sorted()
            let finished = try await runRemovalCheck(
                &progress, folder: folder, server: server, request: request, into: &proven)
            check = progress
            guard finished else {
                // S-19: the cut lists the folder this pass; the bookmark keeps its
                // reading position and carries the check's progress (S-18a).
                var bookmark = cursor.cleared
                bookmark.pendingCheck = progress
                return cutFolder(
                    folder, changes: proven, bookmark: bookmark, arm: created,
                    observation: observation, selection: selection)
            }
        }
        guard try await fetchArrivals(toFetch, server: server, context: context, into: &changes) else {
            return FolderChanges(folderId: folder.id, status: .notRun)
        }
        changes.records += proven.records
        changes.removals += proven.removals
        changes.rereadLater += proven.rereadLater
        changes.heldRowsProof = proven.heldRowsProof

        // A finished check commits the bookmark of the pass that started it.
        let committed = created ? nil : check?.pending
        changes.cursor = IMAPChangeCursor(
            uidValidity: served, highestModSeq: committed?.highestModSeq ?? modseq,
            uidNext: committed?.uidNext ?? uidNext, messageCount: committed?.messageCount ?? m1).encoded
        // The newly covered range holds only rows this read accounted for.
        changes.arrivalRowsProof = Self.arrivalRowsProof(
            from: cursor.uidNext, below: committed?.uidNext ?? uidNext, arrivals: arrivals, movedIn: movedIn)
        if let check, created, owed > 0 {
            // S-18: held rows left below the window are the catch-up's.
            let below = try await request.localRows?.rows(
                folderId: folder.id, numericIdsBelow: Int(check.nextBelow), limit: 1) ?? []
            changes.armCatchUpWithBookmark = !below.isEmpty
        }

        if !recheckIds.isEmpty {
            guard context.hasBudget() else { return FolderChanges(folderId: folder.id, status: .notRun) }
            let answer = try await rereadIds(recheckIds, server: server, context: context)
            changes.records += answer.records
            changes.removals += answer.removals
            changes.rereadLater += answer.unreadable
        }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[IMAPChanges] \(folder.path): CONDSTORE modseq \(cursor.highestModSeq)→\(modseq) uidNext \(cursor.uidNext)→\(uidNext) count \(m0)→\(m1) records=\(changes.records.count) removals=\(changes.removals.count)")
        }
        return changes
    }

    /// The cut (S-19): the folder is listed this pass, its bookmark keeps its
    /// reading position, and what the check proved applies. The catch-up is
    /// armed only by the pass that starts the check (once per check).
    private func cutFolder(
        _ folder: ChangeFolder, changes: FolderChanges, bookmark: IMAPChangeCursor, arm: Bool,
        observation: FolderObservation, selection: Mailbox.Selection
    ) -> FolderChanges {
        var observed = UntrackedObservation(
            messageCount: observation.messageCount ?? selection.reportedMessageCount ?? 0,
            uidNext: observation.uidNext ?? Int(selection.uidNext.value),
            highestModSeq: observation.highestModSeq, uidValidity: observation.uidValidity)
        observed.mustList = true
        var cut = changes
        cut.status = .untracked(observed)
        cut.cursor = bookmark.encoded
        cut.armCatchUpWithBookmark = arm
        return cut
    }

    /// Runs the check while each step fits the budget: first the saved
    /// candidates' proof, then whole chunks of the window, newest first. Proven
    /// removals and fetched records go into `changes`; `heldRowsProof` covers the
    /// rows searched. True when the window is done.
    ///
    /// A pass takes every step whose requests fit its budget whole. A slice of
    /// an other-folder run (`.otherFolders`, #1110) takes at most ONE step (the
    /// proof, or one chunk's SEARCH), started only while the slice has time and
    /// with each request waiting at most `SyncConfig.catchUpRequestTimeoutSeconds`,
    /// as a request of the older-mail check: its share of the slice is shorter
    /// than any step's price, so the priced gate would never let the check move.
    /// The progress rides in the bookmark (the cut), and later slices and runs
    /// take the next steps until the window is done.
    private func runRemovalCheck(
        _ progress: inout IMAPRemovalCheckProgress, folder: ChangeFolder, server: IMAPServer,
        request: ChangeRequest, into changes: inout FolderChanges
    ) async throws -> Bool {
        let context = request.context
        let oneStep = request.scope == .otherFolders
        let step = oneStep ? SyncConfig.catchUpRequestTimeoutSeconds : SyncConfig.changeReadRequestTimeoutSeconds
        let top = Int(progress.nextBelow) - 1
        var searched = Set<Int>()
        var stepTaken = false
        // Whether the next step, sending `requests` requests, may start.
        func mayStart(requests: Double) -> Bool {
            oneStep ? !stepTaken && context.hasBudget() : context.secondsLeft >= requests * step
        }
        while true {
            if !progress.unproven.isEmpty {
                guard mayStart(requests: 2) else { return false }
                stepTaken = true
                let answer = try await rereadIds(progress.unproven, server: server, context: context, requestTimeout: step)
                changes.records += answer.records
                changes.removals += answer.removals
                changes.rereadLater += answer.unreadable
                progress.unproven = []
            }
            guard progress.remaining > 0 else { return true }
            guard mayStart(requests: 3) else { return false }
            stepTaken = true
            let rows = try await request.localRows?.rows(
                folderId: folder.id, numericIdsBelow: Int(progress.nextBelow),
                limit: min(SyncConfig.deletionReconcileChunkSize, progress.remaining)) ?? []
            let uids = rows.compactMap { UInt32($0.messageId) }
            guard let lowest = uids.min() else {
                progress.remaining = 0
                return true
            }
            var set = UIDSet()
            for uid in uids { set.insert(UID(uid)) }
            let asked = set
            let found: ExtendedSearchResult<UID> = try await withTimeout(seconds: step) {
                try await server.extendedSearch(identifierSet: asked, criteria: [.all])
            }
            let present = try found.listed(within: asked)
            progress.unproven = uids.filter { !present.contains(UID($0)) }.sorted()
            progress.nextBelow = lowest
            progress.remaining -= uids.count
            searched.formUnion(uids.map { Int($0) })
            changes.heldRowsProof = .init(lowerId: Int(lowest), upperId: top, checkedIds: searched)
        }
    }

    /// The proof for the UIDs a new bookmark newly covers, [lower, upper): the
    /// arrivals the server listed and the moved-in rows the read's own lookup
    /// found there (each fetched or re-read by this read). A row inserted after
    /// that lookup is in neither, so the apply keeps the stored bookmark (#755).
    nonisolated static func arrivalRowsProof(
        from lower: UInt32, below upper: UInt32, arrivals: MessageIdentifierSet<UID>, movedIn: [UInt32]
    ) -> FolderChanges.HeldRowsProof? {
        guard upper > lower else { return nil }
        var checked = Set(movedIn.map { Int($0) })
        for range in arrivals.ranges {
            let low = max(range.lowerBound, Int(lower)), high = min(range.upperBound, Int(upper) - 1)
            if low <= high { checked.formUnion(low...high) }
        }
        return .init(lowerId: Int(lower), upperId: Int(upper) - 1, checkedIds: checked)
    }

    /// The folder's held UIDs in [lower, upper) the arrivals set does not hold:
    /// moved-in rows the server may no longer have (S-18).
    private func heldIds(
        from lower: UInt32, below upper: UInt32, notIn arrivals: MessageIdentifierSet<UID>,
        folderId: String, request: ChangeRequest
    ) async throws -> [UInt32] {
        guard upper > lower, let localRows = request.localRows else { return [] }
        return try await localRows.rows(folderId: folderId, numericIdsFrom: Int(lower), through: Int(upper) - 1)
            .compactMap { UInt32($0.messageId) }.filter { !arrivals.contains(UID($0)) }
    }
}
