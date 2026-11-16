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
//     superset, RFC 7162 §3.2.5);
//   - changed FLAGS below the bookmark's UIDNEXT become partial records (the
//     whole flag and keyword set); a `\Deleted` one becomes a removal of the
//     local row (IOS-IMAP-001 D3); a changed message the folder does not hold,
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
//   gone (a short FETCH is a real server shape, MIS-IOS-002).
// Nothing here writes the database, and nothing here sends a STORE, COPY, MOVE or
// EXPUNGE. A connection lost or timed out mid-pass fails the folders not yet read
// (`.failed`, bookmark kept); the folder whose request timed out, and every folder
// of a pass whose session never opened (its pass-start NOOP included), keeps its
// failure time and lapses after
// `SyncConfig.changeReadFailureLapseSeconds`; a budget run out leaves them `.notRun`.

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
    /// When the folder's reads started failing on the server's answers (a
    /// timeout, a refused command, a change session that cannot be opened), nil
    /// while they succeed. After `SyncConfig.changeReadFailureLapseSeconds` the
    /// bookmark is refused (`.failingTooLong`). A connection lost mid-pass never
    /// sets it for the folders not yet read.
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

/// The server answered a selection without a value the reader needs (UIDVALIDITY
/// or UIDNEXT): the folder fails closed for this pass.
/// A folder's counters as one read observed them; nil = not reported.
struct FolderObservation: Sendable {
    let messageCount: Int?
    let uidNext: Int?
    let highestModSeq: Int?
    let uidValidity: Int?
}

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
        do {
            try await withChangeConnection { server, qresync in
                // Let the session catch up with other connections' changes before
                // the STATUS reads (some servers answer STATUS from a cached view).
                try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                    _ = try await server.noop()
                }
                // Open only once the NOOP has answered: a session whose NOOP keeps
                // failing is one that cannot be used, under the lapse rule below,
                // never a connection lost mid-pass that leaves no failure time.
                sessionOpened = true
                for (index, folder) in work.enumerated() {
                    guard context.hasBudget() else { break }
                    do {
                        results[folder.id] = try await self.readChangeFolder(
                            folder, server: server, qresync: qresync, request: request)
                    } catch {
                        if Self.changeConnectionLost(after: error) {
                            // A request given up mid-answer (a SELECT or FETCH that
                            // timed out) is this folder's read failing: it keeps its
                            // failure time, so one that always times out lapses to
                            // the listing (`.failingTooLong`) instead of wedging.
                            if error is TimeoutError {
                                results[folder.id] = Self.failedFolder(folder, error: error, now: context.clock())
                            }
                            // The session is gone: every folder not yet read fails,
                            // bookmark kept; never "no changes" on a new channel.
                            for rest in work[index...] where results[rest.id] == nil {
                                results[rest.id] = FolderChanges(folderId: rest.id, status: .failed(error))
                            }
                            throw error
                        }
                        results[folder.id] = Self.failedFolder(folder, error: error, now: context.clock())
                    }
                }
            }
        } catch {
            for folder in work where results[folder.id] == nil {
                // No session could be opened (connect, CAPABILITY, ENABLE or the
                // pass-start NOOP failed): every folder's read failed, under the same lapse rule,
                // so a change connection the server always refuses never freezes
                // the tracked folders.
                results[folder.id] = sessionOpened
                    ? FolderChanges(folderId: folder.id, status: .failed(error))
                    : Self.failedFolder(folder, error: error, now: context.clock())
            }
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[IMAPChanges] pass ended on \(error)")
            }
        }
        return ChangeSet(
            account: .unchanged, folderList: nil,
            folders: request.folders.map { results[$0.id] ?? FolderChanges(folderId: $0.id, status: .notRun) })
    }

    /// The folders this pass reads, in order: on a `.all` pass every synced folder
    /// and every folder with a re-read list, inbox first, the rest rotated by one
    /// each pass; on `.inboxOnly` the inbox only.
    func changeReadOrder(_ request: ChangeRequest) -> [ChangeFolder] {
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
        return inbox + Array(rest[start...] + rest[..<start])
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
        if folder.olderMailComplete { return 1 }
        return folder.olderMailCursor.map { $0 + 1 }
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
        // An unchanged HIGHESTMODSEQ: nothing changed. A STATUS without one is
        // never read as "unchanged".
        if let modseq = observation.highestModSeq, UInt64(modseq) == cursor.highestModSeq, recheckIds.isEmpty {
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
            // RFC 7162 §3.2.5.2: the server treated it as a plain SELECT; nothing
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
        let changed = resync.changedFlags
        let belowCursor = changed.keys.map(\.value).filter { $0 < cursor.uidNext }
        let held = try await heldIdSet(belowCursor, folderId: folder.id, request: request)
        let heldFrom = Self.heldRangeStart(folder)
        var toFetch: [UInt32] = []
        for (uid, flags) in changed.sorted(by: { $0.key.value < $1.key.value }) {
            let value = uid.value
            let deleted = flags.contains(.deleted)
            if value >= cursor.uidNext {
                if !deleted { toFetch.append(value) }
            } else if held.contains(value) {
                if deleted {
                    changes.removals.append(String(value))
                } else {
                    changes.records.append(Self.flagRecord(uid: value, flags: flags))
                }
            } else if !deleted, let heldFrom, Int(value) >= heldFrom {
                // Changed, not held, within the held range: un-deleted, or removed
                // locally by an earlier read. Only its full record can bring it back.
                toFetch.append(value)
            }
        }
        // Arrivals by UID as well: RFC 7162 §3.2.5.1 requires the QRESYNC SELECT
        // to report flag changes and expunges, not new messages, so every UID
        // from the bookmark's UIDNEXT to the served one is asked for explicitly.
        if uidNext > cursor.uidNext {
            guard context.hasBudget() else { return FolderChanges(folderId: folder.id, status: .notRun) }
            let range = MessageIdentifierSet<UID>(UID(cursor.uidNext)...UID(uidNext - 1))
            let found: ExtendedSearchResult<UID> = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                try await server.extendedSearch(identifierSet: range, criteria: [.all])
            }
            let listed = Set(toFetch)
            let deletedArrivals = Set(changed.filter { $0.key.value >= cursor.uidNext && $0.value.contains(.deleted) }.map(\.key.value))
            toFetch += Self.arrivals(
                in: found.asSet, from: cursor.uidNext, excluding: listed.union(deletedArrivals),
                room: SyncConfig.imapChangeArrivalsLimit - toFetch.count
            )
        }
        guard toFetch.count <= SyncConfig.imapChangeArrivalsLimit else {
            return FolderChanges(folderId: folder.id, status: .refused(.tooFarBehind))
        }
        if !toFetch.isEmpty {
            guard context.hasBudget() else { return FolderChanges(folderId: folder.id, status: .notRun) }
            context.onProgress(toFetch.count)
            // A UID the FETCH does not return is read again later (or removed
            // once UID SEARCH proves it gone): the bookmark moves past it, so the
            // re-read list is the only place it survives.
            let fetched = try await rereadIds(toFetch, server: server, context: context)
            changes.records += fetched.records
            changes.removals += fetched.removals
            changes.rereadLater += fetched.unreadable
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
            let present = Set(found.asSet.toArray().map(\.value))
            for uid in missing {
                if present.contains(uid) {
                    unreadable.append(String(uid))
                } else {
                    removals.append(String(uid))
                }
            }
        }
        return (fetched.records, removals, unreadable)
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
    /// unusable drops the connection; the next pass opens a new session.
    func withChangeConnection<T>(
        _ body: (IMAPServer, Bool) async throws -> T
    ) async throws -> T {
        while changeLaneBusy {
            await withCheckedContinuation { changeLaneWaiters.append($0) }
        }
        changeLaneBusy = true
        defer {
            changeLaneBusy = false
            if !changeLaneWaiters.isEmpty { changeLaneWaiters.removeFirst().resume() }
        }

        let (server, qresync) = try await changeSession()
        do {
            let result = try await body(server, qresync)
            changeServerLastUsed = Date()
            return result
        } catch {
            if Self.changeConnectionLost(after: error) { dropChangeServer(server) }
            throw error
        }
    }

    /// The live change session, or a new one.
    private func changeSession() async throws -> (IMAPServer, Bool) {
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
        let generationAtStart = generation
        let fresh = try await createChangeServer()
        await fresh.setReconnectsInsideCommands(false)
        var qresync = false
        do {
            let advertised = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                try await fresh.fetchCapabilities()
            }
            if Self.qresyncUsable(advertised: advertised.filter { $0.value == nil }.map(\.name)) {
                let enabled = try await withTimeout(seconds: SyncConfig.changeReadRequestTimeoutSeconds) {
                    try await fresh.enable([.qresync])
                }
                qresync = enabled.contains(.qresync)
            }
        } catch {
            detachedTeardownLogout(fresh)
            throw error
        }
        guard generation == generationAtStart, changeServer == nil else {
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
        detachedTeardownLogout(server)
    }
}
