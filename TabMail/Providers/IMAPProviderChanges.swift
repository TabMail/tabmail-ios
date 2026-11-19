/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

// MARK: - IMAP change reading with QRESYNC (#751, ADR-IOS-111)
//
// `EmailProvider.fetchChanges` for IMAP. Below the provider boundary: the engine
// applies what this returns with the one generic apply and never learns it talks
// to IMAP.
//
// One pass, on the change connection (`withChangeConnection`, the only connection
// that ever sends `ENABLE QRESYNC`, once per session):
// - a server without QRESYNC, or one that did not acknowledge it, reports every
//   folder `.untracked` with its STATUS counters (the engine lists a changed
//   one). CONDSTORE alone is not QRESYNC and is never inferred from it (#755);
// - per synced folder (inbox first, the rest rotated each pass), with a stored
//   bookmark (`IMAPChangeCursor`): STATUS; an unchanged HIGHESTMODSEQ reads
//   nothing; otherwise `SELECT … (QRESYNC (uidValidity modseq))`:
//   - another UIDVALIDITY (STATUS or SELECT) refuses with
//     `.addressEpochChanged`, and nothing of that SELECT applies;
//   - `VANISHED (EARLIER)` and live VANISHED become removals, intersected with the
//     folder's local rows range by range, never expanded (a server may report a
//     superset, RFC 7162 §3.2.6 and §5.1);
//   - a changed message marked `\Deleted` becomes a removal of the folder's row
//     for it wherever its UID sits (IOS-IMAP-001 D3), at or above the bookmark's
//     UIDNEXT too (a moved-in row re-keyed there); one it does not hold is ignored;
//   - other changed FLAGS below the bookmark's UIDNEXT become partial records (the
//     whole flag and keyword set); a changed message the folder does not hold,
//     inside the range the older-mail walk has downloaded (`heldRangeStart`,
//     never the lowest row held now), is fetched in full (an un-deleted one);
//   - UIDs at or above the bookmark's UIDNEXT are arrivals, fetched in full on
//     the same selection; more than `SyncConfig.imapChangeArrivalsLimit` refuses
//     with `.tooFarBehind`; a `\Deleted` arrival is not inserted;
//   - the new bookmark is that SELECT's (UIDVALIDITY, HIGHESTMODSEQ, UIDNEXT), and
//     the records carry that UIDVALIDITY as their address epoch;
// - without a bookmark: a plain SELECT on the QRESYNC session gives the baseline
//   bookmark (`.baselineReady`, with one catch-up check armed for when the folder
//   becomes tracked); a folder holding rows under an unknown UIDVALIDITY starts no
//   baseline (IOS-EPOCH-001);
// - a folder's re-read list (`ChangeRequest.recheck`, every listed folder on a
//   `.all` pass) is read on that folder's selection: a UID the FETCH did not
//   return is removed only when `UID SEARCH` on the same selection confirms it is
//   gone (a short FETCH is a real server shape, MIS-IOS-002); that answer is asked
//   about each missing UID, never expanded.
// Nothing here writes the database, and nothing here sends a STORE, COPY, MOVE or
// EXPUNGE. A folder whose read fails (a refused command, a request that timed out
// or lost the connection) keeps its failure time and lapses after
// `SyncConfig.changeReadFailureLapseSeconds`; after a lost connection the pass goes
// on with the folders after it on a new session. Every folder of a pass whose first
// session never opened (its pass-start NOOP included) keeps its failure time too; a
// session that cannot be opened again mid-pass fails the folders not yet read
// (`.failed`, bookmark kept, no failure time); a budget run out leaves them `.notRun`.

/// IMAP's opaque per-folder change bookmark, stored as JSON in
/// `Folder.changeCursor`. Three server-assigned integers about the mailbox
/// (metadata, not email content: ADR-004). Only `IMAPProvider` reads or writes it.
/// Never an epoch writer: `Folder.lastKnownUidValidity` stays the folder's epoch
/// authority (IOS-EPOCH-001).
struct IMAPChangeCursor: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var v: Int = IMAPChangeCursor.currentVersion
    let uidValidity: UInt32
    let highestModSeq: UInt64
    let uidNext: UInt32
    /// When the folder's reads started failing (a request on it that timed out
    /// or lost the connection, a refused command, a change session that cannot
    /// be opened), nil while they succeed. After
    /// `SyncConfig.changeReadFailureLapseSeconds` the bookmark is refused
    /// (`.failingTooLong`). A connection lost mid-pass never sets it for the
    /// folders not yet read.
    var failingSince: Date?

    init(uidValidity: UInt32, highestModSeq: UInt64, uidNext: UInt32, failingSince: Date? = nil) {
        self.uidValidity = uidValidity
        self.highestModSeq = highestModSeq
        self.uidNext = uidNext
        self.failingSince = failingSince
    }

    /// Nil for no bookmark or an unreadable one (the folder starts a baseline).
    static func decode(_ raw: String?) -> IMAPChangeCursor? {
        guard let raw, let data = raw.data(using: .utf8),
              let cursor = try? JSONDecoder().decode(IMAPChangeCursor.self, from: data),
              cursor.v == currentVersion, cursor.uidValidity > 0, cursor.highestModSeq > 0, cursor.uidNext > 0
        else { return nil }
        return cursor
    }

    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// One message's whole flag set as a change read reported it (a QRESYNC
/// SELECT's FETCH responses, or a CHANGEDSINCE FETCH).
struct IMAPChangedFlags: Sendable {
    let uid: UInt32
    let flags: [Flag]
}

/// A folder's counters as one read observed them; nil = not reported.
struct FolderObservation: Sendable {
    let messageCount: Int?
    let uidNext: Int?
    let highestModSeq: Int?
    let uidValidity: Int?
}

/// The server answered a selection without a value the reader needs (UIDVALIDITY
/// or UIDNEXT): the folder fails closed for this pass.
struct IMAPChangeReadIncomplete: Error, CustomStringConvertible {
    let folder: String
    let missing: String
    var description: String { "IMAP change read: \(folder) SELECT reported no \(missing)" }
}

extension IMAPProvider {

    func fetchChanges(since cursor: ChangeCursor, request: ChangeRequest) async throws -> ChangeSet? {
        let context = request.context
        var results: [String: FolderChanges] = [:]
        let work = changeReadOrder(request)
        guard !work.isEmpty else { return .uniform(request, account: .unchanged, status: .notRun) }
        guard context.hasBudget() else { return .uniform(request, account: .keep, status: .notRun) }

        var sessionOpened = false
        var next = 0
        var budgetSpent = false
        // A connection the server closed during one folder's read fails that
        // folder only: the pass goes on with the folders after it on a fresh
        // session. Each new session follows a folder that has been read and
        // failed, so a pass opens at most one session per folder, and the read
        // budget bounds them all. A read that timed out ends the pass instead:
        // the reader has closed its side, but a server that stopped answering
        // still counts that session until it notices, so a new login could hold
        // two sessions to the account. The folders not yet read wait for the next
        // pass. A teardown (`markDirty`, `disconnect`), or a dropped session whose
        // LOGOUT does not end in time, ends the pass too.
        let generationAtStart = generation
        while next < work.count, !budgetSpent {
            var closedByServer = false
            var timedOut: String?
            do {
                try await withChangeConnection(openingIn: generationAtStart) { server, qresync in
                    // Let the session catch up with other connections' changes before
                    // the STATUS reads (some servers answer STATUS from a cached view).
                    try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                        _ = try await server.noop()
                    }
                    // Open only once the NOOP has answered: a session whose NOOP keeps
                    // failing is one that cannot be used, under the lapse rule below,
                    // never a connection lost mid-pass that leaves no failure time.
                    sessionOpened = true
                    while next < work.count {
                        guard context.hasBudget() else { budgetSpent = true; return }
                        let folder = work[next]
                        changeReadFirst.remove(folder.id)
                        if changeReadLast == folder.id { changeReadLast = nil }
                        do {
                            results[folder.id] = try await self.readChangeFolder(
                                folder, server: server, qresync: qresync, request: request)
                            if folder.role == .inbox { changeInboxTimeouts = 0 }
                        } catch {
                            // The folder's read failed, whatever the cause: it keeps its
                            // failure time, so a folder whose SELECT or FETCH always
                            // fails or ends the session lapses to the listing
                            // (`.failingTooLong`) instead of wedging.
                            results[folder.id] = Self.failedFolder(folder, error: error, now: context.clock())
                            if Self.changeConnectionLost(after: error) {
                                // The session is gone (`withChangeConnection` drops it).
                                // Closed by the server: the folders after this one are
                                // read on a new session. Timed out: the pass ends.
                                next += 1
                                closedByServer = !(error is TimeoutError)
                                if error is TimeoutError {
                                    timedOut = folder.id
                                    if folder.role == .inbox { changeInboxTimeouts += 1 }
                                }
                                throw error
                            }
                        }
                        next += 1
                    }
                }
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[IMAPChanges] session ended on \(error)")
                }
                if closedByServer, generation == generationAtStart { continue }
                if let timedOut {
                    // The next pass reads the folders left unread first and the one
                    // that timed out last (the inbox stays first until its read has
                    // timed out on several passes in a row).
                    changeReadFirst.formUnion(work[next...].map(\.id))
                    changeReadLast = timedOut
                }
                for folder in work[next...] where results[folder.id] == nil {
                    // No session could be opened (connect, CAPABILITY, ENABLE or the
                    // pass-start NOOP failed). On the pass's first session every
                    // folder's read failed, under the same lapse rule, so a change
                    // connection the server always refuses never freezes the tracked
                    // folders. After a session was opened (one that cannot be opened
                    // again, a read that timed out, a dropped one that did not end in
                    // time), or after a teardown that ended the pass at any point, the
                    // folders not yet read fail with no failure time and are read on
                    // the next pass.
                    results[folder.id] = sessionOpened || generation != generationAtStart
                        ? FolderChanges(folderId: folder.id, status: .failed(error))
                        : Self.failedFolder(folder, error: error, now: context.clock())
                }
                break
            }
        }
        return ChangeSet(
            account: .unchanged, folderList: nil,
            folders: request.folders.map { results[$0.id] ?? FolderChanges(folderId: $0.id, status: .notRun) })
    }

    /// The folders this pass reads, in order: on a `.all` pass every synced folder
    /// and every folder with a re-read list, inbox first, the rest rotated by one
    /// each pass; on `.inboxOnly` the inbox only. After a pass that ended on a
    /// read that timed out, the folders it left unread come first and the folder
    /// that timed out comes last, except that the inbox stays first until its read
    /// has timed out on several passes in a row
    /// (`readFirst(_:first:last:inboxTimeouts:)`).
    func changeReadOrder(_ request: ChangeRequest) -> [ChangeFolder] {
        // Hints for folders the account no longer has are dropped.
        changeReadFirst.formIntersection(request.folders.map(\.id))
        if let last = changeReadLast, !request.folders.contains(where: { $0.id == last }) { changeReadLast = nil }
        let candidates = request.folders.filter { folder in
            guard !folder.path.isEmpty else { return false }
            switch request.scope {
            case .inboxOnly: return folder.role == .inbox
            case .all: return folder.isSynced || !(request.recheck[folder.id] ?? []).isEmpty
            }
        }
        let inbox = candidates.filter { $0.role == .inbox }
        let rest = candidates.filter { $0.role != .inbox }
        guard !rest.isEmpty else { return inbox }
        let start = changeRotation % rest.count
        changeRotation &+= 1
        return Self.readFirst(
            inbox + Array(rest[start...] + rest[..<start]),
            first: changeReadFirst, last: changeReadLast, inboxTimeouts: changeInboxTimeouts)
    }

    /// `order` with the folders in `first` moved to the front and the folder
    /// `last` moved to the end, each group keeping its order. The inbox stays at
    /// the front until its read has timed out on
    /// `SyncConfig.imapChangeInboxTimeoutsBeforeReadLast` passes in a row
    /// (`inboxTimeouts`): one timeout never delays new mail behind the others.
    nonisolated static func readFirst(
        _ order: [ChangeFolder], first: Set<String>, last: String?, inboxTimeouts: Int
    ) -> [ChangeFolder] {
        let lead = order.filter { first.contains($0.id) && $0.id != last }
        let middle = order.filter { !first.contains($0.id) && $0.id != last }
        let moved = lead + middle + order.filter { $0.id == last }
        guard inboxTimeouts < SyncConfig.imapChangeInboxTimeoutsBeforeReadLast else { return moved }
        return moved.filter { $0.role == .inbox } + moved.filter { $0.role != .inbox }
    }

    /// A folder-level failure: the bookmark is kept, with the time its reads
    /// started failing, and refused once they have failed for too long.
    nonisolated static func failedFolder(_ folder: ChangeFolder, error: Error, now: Date) -> FolderChanges {
        guard var cursor = IMAPChangeCursor.decode(folder.cursor) else {
            return FolderChanges(folderId: folder.id, status: .failed(error))
        }
        let since = cursor.failingSince ?? now
        if now.timeIntervalSince(since) >= SyncConfig.changeReadFailureLapseSeconds {
            return FolderChanges(folderId: folder.id, status: .refused(.failingTooLong))
        }
        cursor.failingSince = since
        return FolderChanges(folderId: folder.id, status: .failed(error), cursor: cursor.encoded)
    }

    /// The lowest UID of the range the device holds the folder in, from the
    /// older-mail walk's progress (`ChangeFolder.olderMailComplete`,
    /// `olderMailCursor`): every UID once the walk has completed; above its
    /// position while it runs (it walks down from UIDNEXT); nil before it starts.
    /// A UID below this is the walk's to download, not the change reader's.
    /// Never the lowest row the folder holds now: a message removed through
    /// `\Deleted` elsewhere moves that row, and once un-deleted it would fall
    /// outside the range for good while the bookmark moves past it.
    nonisolated static func heldRangeStart(_ folder: ChangeFolder) -> Int? {
        heldRangeStart(olderMailComplete: folder.olderMailComplete, olderMailCursor: folder.olderMailCursor)
    }

    /// The same rule from the walk's two values (the catch-up's lower bound, #1062).
    nonisolated static func heldRangeStart(olderMailComplete: Bool, olderMailCursor: Int?) -> Int? {
        if olderMailComplete { return 1 }
        return olderMailCursor.map { $0 + 1 }
    }

    /// The arrivals in a UID SEARCH answer, in UID order: every UID from `from`
    /// up that is not in `excluding`, and at most `room + 1` of them. The answer
    /// is walked range by range and never expanded: a compact `ALL 1:4000000000`
    /// costs one range, and the walk stops at the first UID past the room, which
    /// is enough for the caller to refuse the bookmark as too far behind.
    nonisolated static func arrivals(
        in found: MessageIdentifierSet<UID>, from: UInt32, excluding: Set<UInt32>, room: Int
    ) -> [UInt32] {
        var out: [UInt32] = []
        for range in found.ranges {
            let lower = max(range.lowerBound, Int(from))
            guard lower <= range.upperBound else { continue }
            for value in lower...range.upperBound {
                let uid = UInt32(value)
                guard !excluding.contains(uid) else { continue }
                out.append(uid)
                if out.count > room { return out }
            }
        }
        return out
    }

    /// The QRESYNC SELECT's timeout: its own setting, never past the read
    /// budget by more than one ordinary request's timeout.
    nonisolated static func changeSelectTimeout(secondsLeft: TimeInterval) -> TimeInterval {
        min(SyncConfig.imapChangeSelectTimeoutSeconds, secondsLeft + SyncConfig.changeReadRequestTimeoutSeconds)
    }

    /// The change session cannot be used any more: a lost or aborted connection,
    /// or a request given up mid-answer (the session's state is unknown).
    nonisolated static func changeConnectionLost(after error: Error) -> Bool {
        error is TimeoutError || pooledConnectionUnusable(after: error)
    }

    // MARK: - One folder

    private func readChangeFolder(
        _ folder: ChangeFolder, server: IMAPServer, qresync: Bool, request: ChangeRequest
    ) async throws -> FolderChanges {
        let context = request.context
        // Both scopes answer the folder's re-read list: the scope narrows which
        // folders are read (`changeReadOrder`), never what a read folder answers.
        let recheckIds = (request.recheck[folder.id] ?? []).compactMap { UInt32($0) }.filter { $0 > 0 }
        let readsChanges = folder.isSynced || (request.scope == .inboxOnly && folder.role == .inbox)

        guard readsChanges else {
            // Only the re-read list: answered on a plain selection, whatever the
            // folder's window or bookmark, which this never moves.
            return try await recheckOnly(folder, ids: recheckIds, server: server, request: request)
        }

        let observation = try await observe(folder, server: server)

        guard qresync else {
            return try await untracked(folder, observation: observation, ids: recheckIds, server: server, request: request)
        }

        guard let cursor = IMAPChangeCursor.decode(folder.cursor) else {
            return try await baseline(folder, observation: observation, ids: recheckIds, server: server, request: request)
        }

        if let served = observation.uidValidity, served != Int(cursor.uidValidity) {
            return FolderChanges(folderId: folder.id, status: .refused(.addressEpochChanged(served)))
        }
        // An unchanged HIGHESTMODSEQ under the bookmark's own UIDVALIDITY:
        // nothing changed. A STATUS without either is never read as "unchanged":
        // a MODSEQ means nothing outside its UIDVALIDITY (a renumbered folder can
        // restart at the same value); the QRESYNC SELECT below reports both.
        if observation.uidValidity == Int(cursor.uidValidity), let modseq = observation.highestModSeq,
           UInt64(modseq) == cursor.highestModSeq, recheckIds.isEmpty {
            return FolderChanges(
                folderId: folder.id, status: .tracked,
                cursor: cursor.failingSince == nil ? nil : IMAPChangeCursor(
                    uidValidity: cursor.uidValidity, highestModSeq: cursor.highestModSeq, uidNext: cursor.uidNext).encoded)
        }
        guard context.hasBudget() else { return FolderChanges(folderId: folder.id, status: .notRun) }

        let selectTimeout = Self.changeSelectTimeout(secondsLeft: context.secondsLeft)
        changeSelectedPath = nil
        let resync = try await withTimeout(seconds: selectTimeout) {
            try await server.selectMailbox(
                folder.path, resyncingFromUIDValidity: cursor.uidValidity,
                modificationSequence: cursor.highestModSeq)
        }
        changeSelectedPath = folder.path
        let selection = resync.selection
        let served = selection.uidValidity.value
        guard served != 0 else { throw IMAPChangeReadIncomplete(folder: folder.path, missing: "UIDVALIDITY") }
        guard served == cursor.uidValidity else {
            // RFC 7162 §3.2.5: the server treated it as a plain SELECT; nothing
            // it reported describes the bookmark's numbering.
            return FolderChanges(folderId: folder.id, status: .refused(.addressEpochChanged(Int(served))))
        }
        guard let modseq = selection.highestModificationSequenceValue else {
            return try await untracked(folder, observation: observation, ids: recheckIds, server: server, request: request)
        }
        let uidNext = selection.uidNext.value
        guard uidNext != 0 else { throw IMAPChangeReadIncomplete(folder: folder.path, missing: "UIDNEXT") }

        var changes = FolderChanges(
            folderId: folder.id, status: .tracked, addressEpoch: Int(served),
            cursor: IMAPChangeCursor(uidValidity: served, highestModSeq: modseq, uidNext: uidNext).encoded)

        // Removals: VANISHED, never expanded; only UIDs the folder holds.
        var vanished = resync.vanishedEarlier
        for range in resync.vanished.ranges { vanished.insert(ranges: range) }
        changes.removals += try await heldIds(in: vanished, folderId: folder.id, request: request)

        // Changed flags and arrivals.
        let changed = resync.changedFlags.map { IMAPChangedFlags(uid: $0.key.value, flags: $0.value) }
        if case .stopped(let result) = try await readChangedAndArrivals(
            changed, folder: folder, cursorUidNext: cursor.uidNext, servedUidNext: uidNext,
            server: server, request: request, into: &changes) {
            return result
        }

        // The re-read list, on this same selection.
        if !recheckIds.isEmpty {
            guard context.hasBudget() else { return FolderChanges(folderId: folder.id, status: .notRun) }
            let answer = try await rereadIds(recheckIds, server: server, context: context)
            changes.records += answer.records
            changes.removals += answer.removals
            changes.rereadLater += answer.unreadable
        }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[IMAPChanges] \(folder.path): modseq \(cursor.highestModSeq)→\(modseq) uidNext \(cursor.uidNext)→\(uidNext) records=\(changes.records.count) removals=\(changes.removals.count)")
        }
        return changes
    }

    /// How `readChangedAndArrivals` ended.
    enum SelectionReadOutcome {
        /// Read; the arrivals were fetched into the folder's changes.
        case read
        /// The folder's read stops with this result.
        case stopped(FolderChanges)
    }

    /// Changed flags and arrivals on the current selection, one classification
    /// for every change mode: a held `\Deleted` message is a removal wherever
    /// its UID sits (IOS-IMAP-001 D3); a changed message at or above the
    /// bookmark's UIDNEXT is an arrival, fetched in full; a held one gets a
    /// partial record (its whole flag and keyword set); a changed message the
    /// folder does not hold, inside the range the older-mail walk has downloaded
    /// (`heldRangeStart`), is fetched in full. Arrivals are also asked for by
    /// UID from the bookmark's UIDNEXT to the served one. More than
    /// `SyncConfig.imapChangeArrivalsLimit` to fetch refuses with `.tooFarBehind`.
    func readChangedAndArrivals(
        _ changed: [IMAPChangedFlags], folder: ChangeFolder, cursorUidNext: UInt32, servedUidNext: UInt32,
        server: IMAPServer, request: ChangeRequest, into changes: inout FolderChanges
    ) async throws -> SelectionReadOutcome {
        let context = request.context
        let sorted = changed.sorted { $0.uid < $1.uid }
        // Held rows are looked up below the bookmark's UIDNEXT and, for a
        // `\Deleted` message, at or above it too: a moved-in row is re-keyed to
        // its destination UID there before the folder's next read.
        let heldCandidates = sorted.filter { $0.uid < cursorUidNext || $0.flags.contains(.deleted) }.map(\.uid)
        let held = try await heldIdSet(heldCandidates, folderId: folder.id, request: request)
        let heldFrom = Self.heldRangeStart(folder)
        var toFetch: [UInt32] = []
        for message in sorted {
            let value = message.uid
            if message.flags.contains(.deleted) {
                // A message the server holds as `\Deleted` is never shown: the
                // folder's row for it goes, wherever its UID sits. One it does not
                // hold is neither fetched nor inserted.
                if held.contains(value) { changes.removals.append(String(value)) }
            } else if value >= cursorUidNext {
                toFetch.append(value)
            } else if held.contains(value) {
                changes.records.append(Self.flagRecord(uid: value, flags: message.flags))
            } else if let heldFrom, Int(value) >= heldFrom {
                // Changed, not held, within the held range: un-deleted, or removed
                // locally by an earlier read. Only its full record can bring it back.
                toFetch.append(value)
            }
        }
        // Arrivals by UID as well: RFC 7162 §3.2.5.1 requires the QRESYNC SELECT
        // to report flag changes and expunges, not new messages, so every UID
        // from the bookmark's UIDNEXT to the served one is asked for explicitly.
        if servedUidNext > cursorUidNext {
            guard context.hasBudget() else { return .stopped(FolderChanges(folderId: folder.id, status: .notRun)) }
            let range = MessageIdentifierSet<UID>(UID(cursorUidNext)...UID(servedUidNext - 1))
            let found: ExtendedSearchResult<UID> = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                try await server.extendedSearch(identifierSet: range, criteria: [.all])
            }
            let listed = Set(toFetch)
            let deletedArrivals = Set(sorted.filter { $0.uid >= cursorUidNext && $0.flags.contains(.deleted) }.map(\.uid))
            toFetch += Self.arrivals(
                in: try found.listed(within: range), from: cursorUidNext, excluding: listed.union(deletedArrivals),
                room: SyncConfig.imapChangeArrivalsLimit - toFetch.count
            )
        }
        guard toFetch.count <= SyncConfig.imapChangeArrivalsLimit else {
            return .stopped(FolderChanges(folderId: folder.id, status: .refused(.tooFarBehind)))
        }
        if !toFetch.isEmpty {
            guard context.hasBudget() else { return .stopped(FolderChanges(folderId: folder.id, status: .notRun)) }
            context.onProgress(toFetch.count)
            // A UID the FETCH does not return is read again later (or removed
            // once UID SEARCH proves it gone): the bookmark moves past it, so the
            // re-read list is the only place it survives.
            let fetched = try await rereadIds(toFetch, server: server, context: context)
            changes.records += fetched.records
            changes.removals += fetched.removals
            changes.rereadLater += fetched.unreadable
        }
        return .read
    }

    /// No bookmark yet: a plain SELECT on the QRESYNC session.
    private func baseline(
        _ folder: ChangeFolder, observation: FolderObservation, ids: [UInt32],
        server: IMAPServer, request: ChangeRequest
    ) async throws -> FolderChanges {
        // A folder holding rows under an unknown UIDVALIDITY starts no bookmark:
        // the verified door stamps its epoch first (IOS-EPOCH-001, Memory 096).
        if folder.addressEpoch == nil,
           try await request.localRows?.firstNumericId(folderId: folder.id, atLeast: 1) != nil {
            return try await untracked(folder, observation: observation, ids: ids, server: server, request: request)
        }
        guard request.context.hasBudget() else { return FolderChanges(folderId: folder.id, status: .notRun) }
        let selection = try await selectPlain(folder.path, server: server)
        let served = selection.uidValidity.value
        guard served != 0 else { throw IMAPChangeReadIncomplete(folder: folder.path, missing: "UIDVALIDITY") }
        if let stored = folder.addressEpoch, stored != Int(served) {
            return FolderChanges(folderId: folder.id, status: .refused(.addressEpochChanged(Int(served))))
        }
        guard let modseq = selection.highestModificationSequenceValue, modseq > 0 else {
            return try await untracked(folder, observation: observation, ids: ids, server: server, request: request)
        }
        let uidNext = selection.uidNext.value
        guard uidNext != 0 else { throw IMAPChangeReadIncomplete(folder: folder.path, missing: "UIDNEXT") }
        var changes = FolderChanges(
            folderId: folder.id, status: .baselineReady, addressEpoch: Int(served),
            cursor: IMAPChangeCursor(uidValidity: served, highestModSeq: modseq, uidNext: uidNext).encoded)
        changes.armCatchUpWithBookmark = true
        if !ids.isEmpty, request.context.hasBudget() {
            let answer = try await rereadIds(ids, server: server, context: request.context)
            changes.records += answer.records
            changes.removals += answer.removals
            changes.rereadLater += answer.unreadable
        }
        return changes
    }

    /// A folder no bookmark can cover, with its re-read list answered.
    private func untracked(
        _ folder: ChangeFolder, observation: FolderObservation, ids: [UInt32],
        server: IMAPServer, request: ChangeRequest
    ) async throws -> FolderChanges {
        // A counter the server left out is unknown, never 0: the folder is
        // unreadable this pass (no count written, never reported as changed).
        guard let messageCount = observation.messageCount else {
            throw IMAPChangeReadIncomplete(folder: folder.path, missing: "MESSAGES")
        }
        guard let uidNext = observation.uidNext else {
            throw IMAPChangeReadIncomplete(folder: folder.path, missing: "UIDNEXT")
        }
        let untracked = UntrackedObservation(
            messageCount: messageCount, uidNext: uidNext,
            highestModSeq: observation.highestModSeq, uidValidity: observation.uidValidity)
        guard !ids.isEmpty, request.context.hasBudget() else {
            return FolderChanges(folderId: folder.id, status: .untracked(untracked))
        }
        var changes = try await recheckOnly(folder, ids: ids, server: server, request: request)
        changes.status = .untracked(untracked)
        return changes
    }

    /// The folder's counters as the server reports them, each nil when not
    /// reported. STATUS, except for the mailbox selected on the change
    /// connection (RFC 3501 §6.3.10: STATUS SHOULD NOT be sent for it), which
    /// is selected again instead.
    private func observe(_ folder: ChangeFolder, server: IMAPServer) async throws -> FolderObservation {
        if changeSelectedPath == folder.path {
            let selection = try await selectPlain(folder.path, server: server)
            return FolderObservation(
                messageCount: selection.messageCount,
                uidNext: selection.uidNext.value == 0 ? nil : Int(selection.uidNext.value),
                highestModSeq: selection.highestModificationSequenceValue.flatMap { Int(exactly: $0) },
                uidValidity: SyncEngine.knownUidValidity(Int(selection.uidValidity.value)))
        }
        let status = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
            try await server.mailboxStatus(folder.path)
        }
        return FolderObservation(
            messageCount: status.messageCount,
            uidNext: status.uidNext.map { Int($0.value) },
            highestModSeq: status.highestModSequence,
            uidValidity: SyncEngine.knownUidValidity(status.uidValidity.map { Int($0.value) }))
    }

    /// A plain SELECT on the change connection, remembering the selection.
    private func selectPlain(_ path: String, server: IMAPServer) async throws -> Mailbox.Selection {
        changeSelectedPath = nil
        let selection = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
            try await server.selectMailbox(path)
        }
        changeSelectedPath = path
        return selection
    }

    /// The re-read list alone, on a plain selection. Never moves the bookmark.
    private func recheckOnly(
        _ folder: ChangeFolder, ids: [UInt32], server: IMAPServer, request: ChangeRequest
    ) async throws -> FolderChanges {
        guard !ids.isEmpty, request.context.hasBudget() else {
            return FolderChanges(folderId: folder.id, status: .notRun)
        }
        let selection = try await selectPlain(folder.path, server: server)
        let served = selection.uidValidity.value
        guard served != 0 else { throw IMAPChangeReadIncomplete(folder: folder.path, missing: "UIDVALIDITY") }
        let answer = try await rereadIds(ids, server: server, context: request.context)
        // The apply takes these only while the folder still stores this epoch.
        return FolderChanges(
            folderId: folder.id, status: .notRun, addressEpoch: Int(served),
            records: answer.records, removals: answer.removals, rereadLater: answer.unreadable)
    }

    // MARK: - Reads on the current selection

    /// Full records for these UIDs (one header FETCH). A `\Deleted` message is
    /// left out (never inserted); a record that cannot be mapped is read later.
    private func fullRecords(
        _ uids: [UInt32], server: IMAPServer
    ) async throws -> (records: [ChangeRecord], returned: Set<UInt32>, deleted: Set<UInt32>, unreadable: [String]) {
        var set = UIDSet()
        for uid in uids { set.insert(UID(uid)) }
        let requested = set
        let infos = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
            try await server.fetchMessageInfosBulk(using: requested)
        }
        var records: [ChangeRecord] = []
        var returned = Set<UInt32>()
        var deleted = Set<UInt32>()
        var unreadable: [String] = []
        for info in infos {
            guard let uid = info.uid?.value else { continue }
            returned.insert(uid)
            if info.flags.contains(.deleted) {
                deleted.insert(uid)
                continue
            }
            guard var header = mapMessageInfo(info) else {
                unreadable.append(String(uid))
                continue
            }
            // A FETCH carries the message's whole keyword set.
            header.userLabelIdsAreAuthoritative = true
            records.append(ChangeRecord(header: header))
        }
        return (records, returned, deleted, unreadable)
    }

    /// The re-read list's answer: full records; a `\Deleted` message is a
    /// removal; a UID the FETCH did not return is removed only when `UID SEARCH`
    /// on the same selection confirms it is gone, otherwise it is read again.
    private func rereadIds(
        _ ids: [UInt32], server: IMAPServer, context: ChangeContext
    ) async throws -> (records: [ChangeRecord], removals: [String], unreadable: [String]) {
        let fetched = try await fullRecords(ids, server: server)
        var removals = fetched.deleted.sorted().map(String.init)
        var unreadable = fetched.unreadable
        let missing = ids.filter { !fetched.returned.contains($0) }
        if !missing.isEmpty {
            guard context.hasBudget() else {
                return (fetched.records, removals, unreadable + missing.map(String.init))
            }
            var set = UIDSet()
            for uid in missing { set.insert(UID(uid)) }
            let missingSet = set
            let found: ExtendedSearchResult<UID> = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                try await server.extendedSearch(identifierSet: missingSet, criteria: [.all])
            }
            let confirmed = Self.confirmMissing(missing, present: try found.listed(within: missingSet))
            unreadable += confirmed.unreadable
            removals += confirmed.removals
        }
        return (fetched.records, removals, unreadable)
    }

    /// The confirming SEARCH's answer for the UIDs a FETCH did not return: one
    /// the server still has is read again, one it does not is removed. The
    /// answer is asked about each missing UID and never expanded: a compact
    /// answer such as `1:4000000000` costs only the missing list's length.
    nonisolated static func confirmMissing(
        _ missing: [UInt32], present: MessageIdentifierSet<UID>
    ) -> (unreadable: [String], removals: [String]) {
        var unreadable: [String] = []
        var removals: [String] = []
        for uid in missing {
            if present.contains(UID(uid)) {
                unreadable.append(String(uid))
            } else {
                removals.append(String(uid))
            }
        }
        return (unreadable, removals)
    }

    /// A partial record from a message's whole flag set.
    nonisolated static func flagRecord(uid: UInt32, flags: [Flag]) -> ChangeRecord {
        var record = ChangeRecord(messageId: String(uid))
        record.isRead = flags.contains(.seen)
        record.isFlagged = flags.contains(.flagged)
        record.isReplied = flags.contains(.answered)
        record.isForwarded = flags.contains(.custom("$Forwarded"))
        record.userLabelIds = userLabelKeywords(flags)
        return record
    }

    // MARK: - Local rows

    /// The folder's local ids inside a UID set, range by range: a superset such
    /// as `1:500000` is never expanded into memory.
    private func heldIds(in set: UIDSet, folderId: String, request: ChangeRequest) async throws -> [String] {
        guard let localRows = request.localRows else { return [] }
        var ids: [String] = []
        for range in set.ranges {
            ids += try await localRows.rows(
                folderId: folderId, numericIdsFrom: range.lowerBound, through: range.upperBound).map(\.messageId)
        }
        return ids
    }

    private func heldIdSet(_ uids: [UInt32], folderId: String, request: ChangeRequest) async throws -> Set<UInt32> {
        guard let localRows = request.localRows, !uids.isEmpty else { return [] }
        let rows = try await localRows.rows(folderId: folderId, ids: uids.map(String.init))
        return Set(rows.compactMap { UInt32($0.messageId) })
    }

    // MARK: - The change connection

    /// Run `body` on the change connection, one pass at a time. The connection is
    /// opened on first use with reconnects inside commands off and, on a server
    /// advertising QRESYNC, `ENABLE QRESYNC` once for the session; `qresync` says
    /// whether the server acknowledged it. A failure that leaves the session
    /// unusable drops the connection; the next pass opens a new session. A
    /// session is used or opened only while `generation` is still
    /// `passGeneration`, the generation the pass started in: after a teardown
    /// (`markDirty`, `disconnect`) at any suspension of the pass, no session logs
    /// in for it.
    func withChangeConnection<T>(
        openingIn passGeneration: Int,
        _ body: (IMAPServer, Bool) async throws -> T
    ) async throws -> T {
        #if DEBUG
        if let hook = beforeChangeLaneTestHook {
            beforeChangeLaneTestHook = nil
            await hook()
        }
        #endif
        while changeLaneBusy {
            await withCheckedContinuation { changeLaneWaiters.append($0) }
        }
        changeLaneBusy = true
        defer {
            changeLaneBusy = false
            if !changeLaneWaiters.isEmpty { changeLaneWaiters.removeFirst().resume() }
        }

        let (server, qresync) = try await changeSession(passGeneration)
        do {
            let result = try await body(server, qresync)
            changeServerLastUsed = Date()
            return result
        } catch {
            if Self.changeConnectionLost(after: error) { dropChangeServer(server) }
            throw error
        }
    }

    /// The live change session, or a new one, for a pass that started in
    /// `passGeneration`.
    private func changeSession(_ passGeneration: Int) async throws -> (IMAPServer, Bool) {
        guard generation == passGeneration else { throw ProviderError.notConnected }
        if let server = changeServer {
            guard Self.shouldCheckConnectionLiveness(lastUsed: changeServerLastUsed, now: Date()) else {
                return (server, changeServerQResync)
            }
            do {
                try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                    _ = try await server.noop()
                }
                if changeServer === server { return (server, changeServerQResync) }
            } catch {
                dropChangeServer(server)
            }
        }
        // A change session dropped while its connection still answers has its
        // LOGOUT answered before a new one logs in. One whose connection is already
        // closed (a timed-out NOOP here aborts it) ends at once, and the session
        // is reopened. A timed-out folder read never gets here: it ends the pass
        // (`fetchChanges`).
        guard await droppedChangeSessionEnded() else { throw ProviderError.notConnected }
        // From its creation until it is kept or discarded here, the session being
        // opened is open to a teardown, which closes it at once
        // (`changeOpening`): whatever it waits for ends with an error. Each
        // command that opens it (LOGIN in `createServer`, then CAPABILITY and
        // ENABLE) is also sent only while the pass's generation holds, so none
        // goes out between a teardown and the moment the closing lands.
        defer { if changeOpening?.generation == passGeneration { changeOpening = nil } }
        let fresh = try await createChangeServer(openingIn: passGeneration)
        var qresync = false
        do {
            guard generation == passGeneration else { throw ProviderError.notConnected }
            let advertised = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                try await fresh.fetchCapabilities()
            }
            if Self.qresyncUsable(advertised: advertised.filter { $0.value == nil }.map(\.name)) {
                guard generation == passGeneration else { throw ProviderError.notConnected }
                let enabled = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                    try await fresh.enable([.qresync])
                }
                qresync = enabled.contains(.qresync)
            }
        } catch {
            detachedTeardownLogout(fresh)
            throw error
        }
        guard generation == passGeneration, changeServer == nil else {
            // Torn down while opening (markDirty/disconnect): never plant.
            detachedTeardownLogout(fresh)
            throw ProviderError.notConnected
        }
        changeServer = fresh
        changeServerQResync = qresync
        changeSelectedPath = nil
        changeServerLastUsed = Date()
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[IMAPChanges] change connection opened (QRESYNC \(qresync ? "enabled" : "not available"))")
        }
        return (fresh, qresync)
    }

    #if DEBUG
    /// Test seam: the change session looks idle since `date`, so the next pass
    /// checks its liveness first (`changeSession`).
    func setChangeServerLastUsedForTesting(_ date: Date?) { changeServerLastUsed = date }
    #endif

    /// QRESYNC can be used only when the server advertises QRESYNC, ENABLE and
    /// UIDPLUS. RFC 7162 §3.2.3 switches QRESYNC on only through ENABLE (RFC
    /// 5161). UIDPLUS (RFC 4315 COPYUID) is what lets a move into a tracked
    /// folder re-key its row to the destination UID; without it every move
    /// would land without proof and end the folder's tracking (ADR-IOS-111). A
    /// server missing any of the three is read as untracked, like a
    /// CONDSTORE-only server: no ENABLE is sent, no pass fails on it.
    nonisolated static func qresyncUsable(advertised: [String]) -> Bool {
        let names = Set(advertised.map { $0.uppercased() })
        return names.contains("QRESYNC") && names.contains("ENABLE") && names.contains("UIDPLUS")
    }

    private func dropChangeServer(_ server: IMAPServer) {
        if changeServer === server {
            changeServer = nil
            changeServerQResync = false
            changeSelectedPath = nil
        }
        changeLogout = detachedTeardownLogoutEnded(server)
    }

    /// Wait, at most `SyncConfig.imapEvictionLogoutWaitSeconds`, for the LOGOUT
    /// of the change session dropped last: true once it has ended (answered, or
    /// failed on a connection already closed); false when it is still running
    /// or timed out, in this wait or in the IMAP library's own command timeout.
    /// The server counts a session until it has ended, against the account's
    /// connection limit.
    private func droppedChangeSessionEnded() async -> Bool {
        guard let logout = changeLogout else { return true }
        let ended = (try? await withTimeout(seconds: SyncConfig.imapEvictionLogoutWaitSeconds, operation: {
            await logout.value
        })) ?? false
        // A dropped session's LOGOUT is waited for once, up to the bound: one that
        // has not ended by then ends this pass only, and the next pass opens a
        // session without waiting for it again.
        if changeLogout == logout { changeLogout = nil }
        return ended
    }
}
