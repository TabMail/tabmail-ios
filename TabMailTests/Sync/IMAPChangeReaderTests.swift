/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail
import Synchronization
import Testing
@testable import TabMail

/// The IMAP change reader (ADR-IOS-111, IMAP half): the real `IMAPProvider.fetchChanges`
/// against `FakeIMAPServer`'s QRESYNC model (RFC 7162). Every case asserts what the
/// reader reports to the engine (records, removals, status, bookmark) and, where the
/// invariant is about the wire, the server's oracle (ENABLE per connection, no
/// mutation command, no wrong-message violation).
@Suite("IMAP change reader (QRESYNC)", .serialized, .processGlobalState)
struct IMAPChangeReaderTests {

    static let epoch = 52_017
    static let inboxPath = "INBOX"
    static let archivePath = "Archive"
    static let qresyncCapabilities = FakeIMAPServer.defaultCapabilities + ["ENABLE", "CONDSTORE", "QRESYNC"]

    static func message(_ uid: Int) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: change fixture \(uid)\r
        Date: \(TestFixtureDate.rfc2822(daysFromAnchor: -uid))\r
        Message-ID: <change-\(uid)@example.com>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        body\r

        """)
    }

    /// The local rows the reader is told the device holds (ids only, ADR-004).
    final class LocalRows: CatchUpLocalRowReader, @unchecked Sendable {
        private let held = Mutex<[String: Set<Int>]>([:])
        func set(_ folderId: String, _ uids: [Int]) { held.withLock { $0[folderId] = Set(uids) } }
        func remove(_ folderId: String, _ uids: [Int]) { held.withLock { $0[folderId]?.subtract(uids) } }
        func add(_ folderId: String, _ uids: [Int]) { held.withLock { $0[folderId, default: []].formUnion(uids) } }
        func uids(_ folderId: String) -> Set<Int> { held.withLock { $0[folderId] ?? [] } }
        private func row(_ uid: Int) -> CatchUpLocalRow { CatchUpLocalRow(messageId: String(uid), isRead: false, isFlagged: false) }
        func rows(folderId: String, numericIdsFrom lower: Int, through upper: Int) async throws -> [CatchUpLocalRow] {
            uids(folderId).filter { $0 >= lower && $0 <= upper }.sorted().map(row)
        }
        func firstNumericId(folderId: String, atLeast lower: Int) async throws -> Int? {
            uids(folderId).filter { $0 >= lower }.min()
        }
        func rows(folderId: String, ids: [String]) async throws -> [CatchUpLocalRow] {
            let mine = uids(folderId)
            return ids.compactMap(Int.init).filter(mine.contains).map(row)
        }
        func rows(folderId: String, after afterId: String?, limit: Int) async throws -> [CatchUpLocalRow] {
            let floor = afterId.flatMap(Int.init) ?? 0
            return Array(uids(folderId).filter { $0 > floor }.sorted().prefix(limit)).map(row)
        }
        func rows(folderId: String, orderDatesFrom lower: Date, before upper: Date) async throws -> [CatchUpLocalRow] { [] }
        func newestRows(folderId: String, orderDatesBefore upper: Date?, limit: Int) async throws -> [CatchUpLocalRow] { [] }
    }

    struct World {
        let server: FakeIMAPServer
        let provider: IMAPProvider
        let local: LocalRows
        let accountId = "acct-751"
        var inboxId: String { "\(accountId):\(IMAPChangeReaderTests.inboxPath)" }
        var archiveId: String { "\(accountId):\(IMAPChangeReaderTests.archivePath)" }
    }

    static func withWorld(
        capabilities: [String] = qresyncCapabilities,
        inbox: [Int], archive: [Int] = [],
        _ body: (World) async throws -> Void
    ) async throws {
        let server = FakeIMAPServer(capabilities: capabilities, mailboxes: [
            inboxPath: inbox.map(message), archivePath: archive.map(message),
        ])
        server.setUidValidity(epoch, for: inboxPath)
        server.setUidValidity(epoch, for: archivePath)
        try server.start()
        defer { server.stop() }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        let world = World(server: server, provider: provider, local: LocalRows())
        world.local.set(world.inboxId, inbox)
        world.local.set(world.archiveId, archive)
        try await body(world)
        #expect(server.wrongMessageViolations().isEmpty)
        let mutations = server.recordedCommands().filter {
            let upper = $0.uppercased()
            return ["STORE", "COPY", "MOVE", "EXPUNGE", "APPEND"].contains { upper.contains("UID \($0)") || upper.hasPrefix($0) }
        }
        #expect(mutations.isEmpty, "the reader never mutates the mailbox: \(mutations)")
    }

    // MARK: - Helpers

    /// The folders' older-mail download progress. The world's device holds every
    /// message the server starts with, so by default the walk has completed.
    enum OlderMail {
        case complete
        case walkedDownTo(Int)
        case notStarted
    }

    static func folders(_ w: World, cursors: [String: String?] = [:], archiveSynced: Bool = false,
                        olderMail: OlderMail = .complete) -> [ChangeFolder] {
        let complete: Bool
        let walkCursor: Int?
        switch olderMail {
        case .complete: (complete, walkCursor) = (true, nil)
        case .walkedDownTo(let position): (complete, walkCursor) = (false, position)
        case .notStarted: (complete, walkCursor) = (false, nil)
        }
        return [
            ChangeFolder(id: w.inboxId, path: inboxPath, role: .inbox,
                         cursor: cursors[w.inboxId] ?? nil, isSynced: true, addressEpoch: epoch,
                         olderMailComplete: complete, olderMailCursor: walkCursor),
            ChangeFolder(id: w.archiveId, path: archivePath, role: .archive,
                         cursor: cursors[w.archiveId] ?? nil, isSynced: archiveSynced, addressEpoch: epoch,
                         olderMailComplete: complete, olderMailCursor: walkCursor),
        ]
    }

    static func read(
        _ w: World, cursors: [String: String?] = [:], scope: ChangeScope = .all,
        recheck: [String: [String]] = [:], archiveSynced: Bool = false, olderMail: OlderMail = .complete,
        context: ChangeContext = ChangeContext(onProgress: { _ in })
    ) async throws -> ChangeSet {
        let request = ChangeRequest(
            folders: folders(w, cursors: cursors, archiveSynced: archiveSynced, olderMail: olderMail),
            scope: scope, recheck: recheck, context: context, localRows: w.local)
        return try #require(try await w.provider.fetchChanges(since: ChangeCursor(account: nil), request: request))
    }

    static func inbox(_ w: World, _ set: ChangeSet) throws -> FolderChanges {
        try #require(set.folders.first { $0.folderId == w.inboxId })
    }

    /// A baseline read of the inbox; returns its bookmark.
    static func baseline(_ w: World) async throws -> String {
        let first = try await inbox(w, read(w))
        guard case .baselineReady = first.status else {
            Issue.record("precondition: a first read is a baseline, got \(first.status)")
            return ""
        }
        return try #require(first.cursor)
    }

    static func isTracked(_ status: FolderChangeStatus) -> Bool {
        if case .tracked = status { return true } else { return false }
    }

    // MARK: - Baseline and bookmark

    @Test("Baseline: a folder with no bookmark gets one from the server's numbers, arms the catch-up, and reports no change")
    func baselineStartsBookmark() async throws {
        try await Self.withWorld(inbox: [1, 2, 3]) { w in
            let changes = try await Self.inbox(w, Self.read(w))
            guard case .baselineReady = changes.status else {
                Issue.record("expected baselineReady, got \(changes.status)"); return
            }
            #expect(changes.armCatchUpWithBookmark)
            #expect(changes.records.isEmpty && changes.removals.isEmpty)
            #expect(changes.addressEpoch == Self.epoch)
            let cursor = try #require(IMAPChangeCursor.decode(changes.cursor))
            #expect(Int(cursor.uidValidity) == Self.epoch)
            #expect(Int(cursor.highestModSeq) == w.server.qresyncHighestModSeq(for: Self.inboxPath))
            #expect(cursor.uidNext == 4)
        }
    }

    @Test("Unchanged: an unchanged HIGHESTMODSEQ reports the folder tracked with no record and selects nothing with QRESYNC")
    func unchangedFolderReadsNothing() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            let selectsBefore = w.server.qresyncSelectCountByConnection.values.reduce(0, +)
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(Self.isTracked(changes.status))
            #expect(changes.records.isEmpty && changes.removals.isEmpty)
            #expect(w.server.qresyncSelectCountByConnection.values.reduce(0, +) == selectsBefore)
        }
    }

    // MARK: - Changes

    @Test("Flags: a read and a flag set on another device arrive as partial records for held messages only")
    func flagChangesArrive() async throws {
        try await Self.withWorld(inbox: [1, 2, 3]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: 1)
            w.server.setFlags(["\\Flagged", "\\Answered"], in: Self.inboxPath, uid: 2)
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(Self.isTracked(changes.status))
            let byId = Dictionary(uniqueKeysWithValues: changes.records.map { ($0.messageId, $0) })
            #expect(byId["1"]?.isRead == true)
            #expect(byId["1"]?.isFlagged == false)
            #expect(byId["2"]?.isFlagged == true)
            #expect(byId["2"]?.isRead == false)
            #expect(byId["2"]?.isReplied == true)
            #expect(byId["3"] == nil, "an unchanged message is not reported")
            #expect(byId["1"]?.header == nil, "a held message's flag change carries no header fetch")
            let next = try #require(IMAPChangeCursor.decode(changes.cursor))
            #expect(Int(next.highestModSeq) == w.server.qresyncHighestModSeq(for: Self.inboxPath))
        }
    }

    @Test("Removals: an expunge elsewhere removes the held message, and only held messages are reported")
    func expungeIsRemoval() async throws {
        try await Self.withWorld(inbox: [1, 2, 3, 4]) { w in
            let cursor = try await Self.baseline(w)
            w.local.remove(w.inboxId, [4])
            w.server.setMessages([1, 3].map(Self.message), in: Self.inboxPath)
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(Self.isTracked(changes.status))
            #expect(Set(changes.removals) == ["2"], "4 vanished too but the device does not hold it")
            #expect(changes.records.isEmpty)
        }
    }

    @Test("Removals: a message marked \\Deleted elsewhere is a removal, not a flag record")
    func deletedFlagIsRemoval() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setFlags(["\\Deleted"], in: Self.inboxPath, uid: 2)
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(changes.removals == ["2"])
            #expect(changes.records.isEmpty)
        }
    }

    @Test("Arrivals: a new message arrives as a full record with its header")
    func arrivalIsFullRecord() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setMessages([1, 2, 3].map(Self.message), in: Self.inboxPath)
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(Self.isTracked(changes.status))
            let record = try #require(changes.records.first { $0.messageId == "3" })
            #expect(record.header?.subject == "change fixture 3")
            let next = try #require(IMAPChangeCursor.decode(changes.cursor))
            #expect(next.uidNext == 4)
        }
    }

    @Test("Arrivals: more new messages than the limit refuse the bookmark (too far behind) and fetch no header")
    func tooManyArrivalsRefuse() async throws {
        let limit = SyncConfig.imapChangeArrivalsLimit
        try await Self.withWorld(inbox: [1]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setMessages((1...(limit + 2)).map(Self.message), in: Self.inboxPath)
            let fetchesBefore = w.server.recordedCommands().filter { $0.uppercased().contains("UID FETCH") }.count
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            guard case .refused(.tooFarBehind) = changes.status else {
                Issue.record("expected refused(tooFarBehind), got \(changes.status)"); return
            }
            #expect(changes.records.isEmpty)
            #expect(w.server.recordedCommands().filter { $0.uppercased().contains("UID FETCH") }.count == fetchesBefore)
        }
    }

    @Test("Changed but not held, inside the held range: the message is fetched in full so it comes back")
    func changedNotHeldIsFetched() async throws {
        try await Self.withWorld(inbox: [1, 2, 3]) { w in
            let cursor = try await Self.baseline(w)
            w.local.remove(w.inboxId, [2])
            w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: 2)
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            let record = try #require(changes.records.first { $0.messageId == "2" })
            #expect(record.header != nil, "only a full record can bring a message back")
            #expect(record.isRead == true)
        }
    }

    @Test("Changed but not held, no new UID: the limit holds for these fetches too; one over refuses and fetches no header",
          arguments: [0, 1])
    func changedNotHeldObeysTheLimit(over: Int) async throws {
        let limit = SyncConfig.imapChangeArrivalsLimit
        let count = limit + over
        try await Self.withWorld(inbox: Array(1...count)) { w in
            let cursor = try await Self.baseline(w)
            // Un-deleted elsewhere in bulk: changed, inside the held range, held no longer here.
            w.local.remove(w.inboxId, Array(1...count))
            for uid in 1...count { w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: uid) }
            let fetchesBefore = w.server.recordedCommands().filter { $0.uppercased().contains("UID FETCH") }.count
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            let fetches = w.server.recordedCommands().filter { $0.uppercased().contains("UID FETCH") }.count - fetchesBefore
            if over == 0 {
                #expect(Self.isTracked(changes.status), "exactly the limit is read: \(changes.status)")
                #expect(changes.records.filter { $0.header != nil }.count == limit)
            } else {
                guard case .refused(.tooFarBehind) = changes.status else {
                    Issue.record("expected refused(tooFarBehind), got \(changes.status)"); return
                }
                #expect(changes.records.isEmpty)
                #expect(fetches == 0, "no header is fetched over the limit")
            }
        }
    }

    @Test("Superset VANISHED: a server without an exact expunge history removes only held, gone messages")
    func lossyVanishedIsSafe() async throws {
        try await Self.withWorld(inbox: [1, 2, 3, 5]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setLossyExpungeHistory(true, for: Self.inboxPath)
            w.server.setMessages([1, 2, 5].map(Self.message), in: Self.inboxPath)
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(Set(changes.removals) == ["3"])
        }
    }

    @Test("Short FETCH on an arrival: the message is read again later, never lost while the bookmark moves")
    func shortFetchArrivalIsReadLater() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setMessages([1, 2, 3].map(Self.message), in: Self.inboxPath)
            w.server.suppressFetchRecord(in: Self.inboxPath, uids: [3])
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(Self.isTracked(changes.status))
            #expect(changes.rereadLater.contains("3"), "the unreturned arrival goes on the re-read list")
            #expect(!changes.removals.contains("3"), "UID SEARCH still finds it: never a removal")
            #expect(try #require(IMAPChangeCursor.decode(changes.cursor)).uidNext == 4)
        }
    }

    @Test("Arrivals the QRESYNC SELECT does not report are found by UID from the bookmark's UIDNEXT (RFC 7162 §3.2.5.1)")
    func arrivalsOutsideTheSelectStream() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setQResyncOmitsArrivals(true, for: Self.inboxPath)
            w.server.setMessages([1, 2, 3, 4].map(Self.message), in: Self.inboxPath)
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(Set(changes.records.compactMap { $0.header?.messageId }) == ["3", "4"])
        }
    }

    @Test("STATUS without MESSAGES or UIDNEXT: the untracked folder is unreadable this pass, never changed, never 0")
    func missingStatusFieldIsUnreadable() async throws {
        for omitted in ["MESSAGES", "UIDNEXT"] {
            try await Self.withWorld(capabilities: FakeIMAPServer.defaultCapabilities + ["CONDSTORE"], inbox: [1, 2]) { w in
                w.server.setStatusOmits([omitted], for: Self.inboxPath)
                let changes = try await Self.inbox(w, Self.read(w))
                guard case .failed = changes.status else {
                    Issue.record("\(omitted) left out: expected failed, got \(changes.status)"); return
                }
            }
        }
    }

    @Test("The selected folder, selected again without UIDVALIDITY and nothing else changed: never taken as unchanged; the folder fails with its bookmark kept, and the next complete SELECT tracks it again")
    func reselectWithoutUidValidityIsNotUnchanged() async throws {
        try await Self.withWorld(inbox: [1, 2, 3]) { w in
            // Only INBOX is read, so it stays the change connection's selected mailbox.
            let cursor = try await Self.baseline(w)
            let bookmark = try #require(IMAPChangeCursor.decode(cursor))
            w.server.suppressSelectUidValidity(for: Self.inboxPath)
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            guard case .failed = changes.status else {
                Issue.record("a selection without UIDVALIDITY proves nothing about the bookmark's numbering: expected failed, got \(changes.status)")
                return
            }
            #expect(changes.removals.isEmpty && changes.records.isEmpty, "nothing of the read applies")
            let kept = try #require(IMAPChangeCursor.decode(changes.cursor))
            #expect(kept.uidValidity == bookmark.uidValidity && kept.highestModSeq == bookmark.highestModSeq
                    && kept.uidNext == bookmark.uidNext, "the bookmark is kept")
            #expect(kept.failingSince != nil, "the failure time is set")
            w.server.restoreSelectUidValidity(for: Self.inboxPath)
            let next = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: changes.cursor]))
            #expect(Self.isTracked(next.status), "a complete SELECT tracks it again: \(next.status)")
            #expect(try #require(IMAPChangeCursor.decode(next.cursor)).failingSince == nil, "the failure time is cleared")
        }
    }

    @Test("No STATUS for the mailbox selected on the change connection (RFC 3501 §6.3.10)")
    func noStatusForSelectedMailbox() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: 1)
            _ = try await Self.read(w, cursors: [w.inboxId: cursor], scope: .inboxOnly)
            let before = w.server.recordedCommands().count
            w.server.setFlags(["\\Seen", "\\Flagged"], in: Self.inboxPath, uid: 1)
            let next = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor], scope: .inboxOnly))
            let sent = w.server.recordedCommands().dropFirst(before)
            #expect(!sent.contains { $0.uppercased().contains("STATUS") && $0.uppercased().contains("INBOX") },
                    "INBOX was selected: \(Array(sent))")
            #expect(next.records.first { $0.messageId == "1" }?.isFlagged == true)
        }
    }

    // MARK: - Pure pieces

    @Test("A folder whose reads keep failing keeps its bookmark with the time they started, and is refused once that is the lapse ago")
    func failedFolderLapse() throws {
        let start = Date()
        let folder = ChangeFolder(id: "f", path: "INBOX", role: .inbox,
                                  cursor: IMAPChangeCursor(uidValidity: 1, highestModSeq: 5, uidNext: 9).encoded, isSynced: true)
        let first = IMAPProvider.failedFolder(folder, error: TimeoutError(duration: 1), now: start)
        guard case .failed = first.status else { Issue.record("expected failed, got \(first.status)"); return }
        let since = try #require(IMAPChangeCursor.decode(first.cursor)?.failingSince)
        #expect(since == start)
        var later = folder
        later.cursor = first.cursor
        let lapse = SyncConfig.changeReadFailureLapseSeconds
        if case .failed = IMAPProvider.failedFolder(later, error: TimeoutError(duration: 1), now: start.addingTimeInterval(lapse - 1)).status {} else {
            Issue.record("refused before the lapse")
        }
        guard case .refused(.failingTooLong) = IMAPProvider.failedFolder(later, error: TimeoutError(duration: 1), now: start.addingTimeInterval(lapse)).status else {
            Issue.record("not refused at the lapse"); return
        }
    }

    @Test("The read order: inbox first, the rest rotated by one each pass")
    func readOrderRotates() async throws {
        try await Self.withWorld(inbox: [1]) { w in
            let folders = ["A", "B", "C"].map { ChangeFolder(id: "x:\($0)", path: $0, role: .custom, isSynced: true) }
                + [ChangeFolder(id: "x:INBOX", path: "INBOX", role: .inbox, isSynced: true)]
            let request = ChangeRequest(folders: folders, scope: .all, recheck: [:], context: ChangeContext(onProgress: { _ in }))
            var orders: [[String]] = []
            for _ in 0..<3 { orders.append(await w.provider.changeReadOrder(request).map(\.path)) }
            #expect(orders.allSatisfy { $0.first == "INBOX" })
            #expect(Set(orders.map { $0[1] }) == ["A", "B", "C"], "each folder leads the rest once in three passes: \(orders)")
        }
    }

    @Test("The QRESYNC SELECT's timeout is its own setting, cut to the budget left plus one request")
    func selectTimeoutCap() {
        let own = SyncConfig.imapChangeSelectTimeoutSeconds
        let request = SyncConfig.changeReadRequestTimeoutSeconds
        #expect(IMAPProvider.changeSelectTimeout(secondsLeft: 1_000) == own)
        #expect(IMAPProvider.changeSelectTimeout(secondsLeft: 1) == min(own, 1 + request))
        #expect(IMAPProvider.changeSelectTimeout(secondsLeft: 0) == min(own, request))
    }

    // MARK: - Refusals and untracked

    @Test("Epoch: a UIDVALIDITY change refuses the bookmark with the served epoch and reports nothing else")
    func epochChangeRefuses() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setUidValidity(Self.epoch + 1, for: Self.inboxPath)
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            guard case .refused(.addressEpochChanged(let served)) = changes.status else {
                Issue.record("expected refused(addressEpochChanged), got \(changes.status)"); return
            }
            #expect(served == Self.epoch + 1)
            #expect(changes.records.isEmpty && changes.removals.isEmpty)
        }
    }

    @Test("Epoch: a new UIDVALIDITY is refused even when the server's HIGHESTMODSEQ equals the bookmark's")
    func epochChangeWithEqualModSeqRefuses() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            _ = try await Self.baseline(w)
            w.server.setUidValidity(Self.epoch + 1, for: Self.inboxPath)
            // A bookmark under the old numbering whose modseq happens to be the
            // new numbering's: "unchanged" would read the folder under the wrong epoch.
            let served = w.server.qresyncHighestModSeq(for: Self.inboxPath)
            let cursor = IMAPChangeCursor(uidValidity: UInt32(Self.epoch), highestModSeq: UInt64(served), uidNext: 3).encoded
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            guard case .refused(.addressEpochChanged(let epoch)) = changes.status else {
                Issue.record("expected refused(addressEpochChanged), got \(changes.status)"); return
            }
            #expect(epoch == Self.epoch + 1)
        }
    }

    @Test("Epoch: a server whose STATUS leaves UIDVALIDITY out has a new UIDVALIDITY refused by the QRESYNC SELECT (RFC 7162 §3.2.5)")
    func epochChangeSeenOnlyBySelectRefuses() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setStatusOmits(["UIDVALIDITY"], for: Self.inboxPath)
            w.server.setUidValidity(Self.epoch + 1, for: Self.inboxPath)
            w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: 1)
            // A new session has nothing selected, so the inbox is observed by STATUS.
            await w.provider.markDirty()
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            guard case .refused(.addressEpochChanged(let served)) = changes.status else {
                Issue.record("expected refused(addressEpochChanged), got \(changes.status)"); return
            }
            #expect(served == Self.epoch + 1)
            #expect(changes.records.isEmpty && changes.removals.isEmpty)
            #expect(w.server.recordedCommands().contains { $0.uppercased().contains("QRESYNC (") },
                    "the refusal came from the QRESYNC SELECT, not from STATUS")
        }
    }

    @Test("No QRESYNC: a CONDSTORE-only server leaves every folder untracked with its STATUS observation and sends no ENABLE")
    func noQResyncIsUntracked() async throws {
        try await Self.withWorld(capabilities: FakeIMAPServer.defaultCapabilities + ["CONDSTORE"], inbox: [1, 2]) { w in
            let changes = try await Self.inbox(w, Self.read(w))
            guard case .untracked(let observation) = changes.status else {
                Issue.record("expected untracked, got \(changes.status)"); return
            }
            #expect(observation.messageCount == 2)
            #expect(observation.uidNext == 3)
            #expect(changes.cursor == nil)
            #expect(w.server.enableQResyncCountByConnection.isEmpty)
        }
    }

    @Test("QRESYNC without CONDSTORE advertised: the reader still enables QRESYNC (never inferred the other way)")
    func qresyncWithoutCondstore() async throws {
        try await Self.withWorld(capabilities: FakeIMAPServer.defaultCapabilities + ["ENABLE", "QRESYNC"], inbox: [1]) { w in
            _ = try await Self.read(w)
            #expect(w.server.enableQResyncCountByConnection.values.reduce(0, +) == 1)
        }
    }

    @Test("QRESYNC advertised without ENABLE: the folder is untracked, no ENABLE is sent, and the pass does not fail")
    func qresyncWithoutEnableIsUntracked() async throws {
        try await Self.withWorld(capabilities: FakeIMAPServer.defaultCapabilities + ["CONDSTORE", "QRESYNC"], inbox: [1, 2]) { w in
            for _ in 0..<2 {
                let changes = try await Self.inbox(w, Self.read(w))
                guard case .untracked(let observation) = changes.status else {
                    Issue.record("expected untracked, got \(changes.status)"); return
                }
                #expect(observation.messageCount == 2)
                #expect(changes.cursor == nil, "no failing-since bookmark builds up")
            }
            #expect(!w.server.recordedCommands().contains { $0.uppercased().contains("ENABLE") })
        }
    }

    @Test("ENABLE not acknowledged: the folder stays untracked and no QRESYNC SELECT is sent")
    func enableIgnoredIsUntracked() async throws {
        try await Self.withWorld(inbox: [1]) { w in
            w.server.setIgnoresEnableQResync(true)
            let changes = try await Self.inbox(w, Self.read(w))
            guard case .untracked = changes.status else {
                Issue.record("expected untracked, got \(changes.status)"); return
            }
            #expect(w.server.qresyncSelectWithoutEnableCount == 0)
        }
    }

    @Test("NOMODSEQ: a mailbox that keeps no modseqs gets no bookmark")
    func noModSeqIsUntracked() async throws {
        try await Self.withWorld(inbox: [1]) { w in
            w.server.setNoModSeq(true, for: Self.inboxPath)
            let changes = try await Self.inbox(w, Self.read(w))
            guard case .untracked = changes.status else {
                Issue.record("expected untracked, got \(changes.status)"); return
            }
            #expect(changes.cursor == nil)
        }
    }

    @Test("Unknown epoch: a folder holding rows under no known UIDVALIDITY starts no bookmark")
    func unknownEpochStartsNoBookmark() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            var folders = Self.folders(w)
            folders[0].addressEpoch = nil
            let request = ChangeRequest(folders: folders, scope: .all, recheck: [:],
                                        context: ChangeContext(onProgress: { _ in }), localRows: w.local)
            let set = try #require(try await w.provider.fetchChanges(since: ChangeCursor(account: nil), request: request))
            let changes = try Self.inbox(w, set)
            guard case .untracked = changes.status else {
                Issue.record("expected untracked, got \(changes.status)"); return
            }
            #expect(changes.cursor == nil)
        }
    }

    // MARK: - Session and scope

    @Test("Session: QRESYNC is enabled once per session, on one connection, across passes")
    func enableOncePerSession() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: 1)
            _ = try await Self.read(w, cursors: [w.inboxId: cursor])
            _ = try await Self.read(w, cursors: [w.inboxId: cursor])
            let enables = w.server.enableQResyncCountByConnection
            #expect(enables.count == 1, "one connection enabled QRESYNC: \(enables)")
            #expect(enables.values.allSatisfy { $0 == 1 })
            let selects = w.server.qresyncSelectCountByConnection
            #expect(Set(selects.keys).isSubset(of: Set(enables.keys)), "QRESYNC SELECTs only on the enabled connection")
            #expect(w.server.qresyncSelectWithoutEnableCount == 0)
        }
    }

    @Test("Scope: a push pass reads the inbox only")
    func inboxOnlyScope() async throws {
        try await Self.withWorld(inbox: [1], archive: [1]) { w in
            let set = try await Self.read(w, scope: .inboxOnly, archiveSynced: true)
            let archive = try #require(set.folders.first { $0.folderId == w.archiveId })
            guard case .notRun = archive.status else {
                Issue.record("expected the archive notRun on a push pass, got \(archive.status)"); return
            }
        }
    }

    @Test("Scope: a push pass answers the inbox's re-read list, on an unchanged bookmark too; a gone message is removed")
    func inboxOnlyAnswersInboxRecheck() async throws {
        try await Self.withWorld(inbox: [1, 2, 3]) { w in
            let cursor = try await Self.baseline(w)
            // Nothing changed since the bookmark: only the re-read list names 2 and 5.
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor], scope: .inboxOnly,
                                                            recheck: [w.inboxId: ["2", "5"]]))
            #expect(Self.isTracked(changes.status), "\(changes.status)")
            #expect(changes.records.map(\.messageId) == ["2"], "the held message is read again")
            #expect(changes.removals == ["5"], "the gone one is removed")
        }
    }

    @Test("Recheck: a non-synced folder's re-read list is answered, a gone message removed, and no bookmark started")
    func recheckOnUnsyncedFolder() async throws {
        try await Self.withWorld(inbox: [1], archive: [10, 11]) { w in
            w.server.setFlags(["\\Seen"], in: Self.archivePath, uid: 10)
            let set = try await Self.read(w, recheck: [w.archiveId: ["10", "12"]])
            let archive = try #require(set.folders.first { $0.folderId == w.archiveId })
            #expect(archive.records.map(\.messageId) == ["10"])
            #expect(archive.records.first?.isRead == true)
            #expect(archive.removals == ["12"])
            #expect(archive.cursor == nil, "a recheck never moves or starts a bookmark")
        }
    }

    @Test("Recheck: a compact confirming SEARCH answer spanning millions of UIDs is not expanded; it still decides read-again versus removed")
    func recheckCompactConfirmingAnswerIsNotExpanded() async throws {
        try await Self.withWorld(inbox: [1], archive: [10, 11]) { w in
            // The FETCH returns neither 10 (a short FETCH) nor 50000001 (gone);
            // the confirming SEARCH answers with one compact range holding 10.
            w.server.suppressFetchRecord(in: Self.archivePath, uids: [10])
            w.server.answerNextUIDSearch(in: Self.archivePath, all: "1:50000000")
            let start = ContinuousClock.now
            let set = try await Self.read(w, recheck: [w.archiveId: ["10", "50000001"]])
            let elapsed = ContinuousClock.now - start
            #expect(w.server.compactUIDSearchAnswersServed() == 1, "setup: the confirming SEARCH got the compact answer")
            let archive = try #require(set.folders.first { $0.folderId == w.archiveId })
            #expect(archive.rereadLater == ["10"], "still on the server: read again, never removed")
            #expect(archive.removals == ["50000001"], "not on the server: removed")
            #expect(elapsed < .seconds(5), "bounded work: the answer is never expanded (took \(elapsed))")
        }
    }

    @Test("Connection lost: folders not yet read fail with their bookmark kept, never read as unchanged")
    func connectionLostFailsRest() async throws {
        try await Self.withWorld(inbox: [1], archive: [1]) { w in
            let first = try await Self.read(w, archiveSynced: true)
            let inboxCursor = try #require(try Self.inbox(w, first).cursor)
            let archiveCursor = try #require(first.folders.first { $0.folderId == w.archiveId }?.cursor)
            w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: 1)
            w.server.stop()
            let set = try await Self.read(w, cursors: [w.inboxId: inboxCursor, w.archiveId: archiveCursor], archiveSynced: true)
            for folder in set.folders {
                if case .tracked = folder.status { Issue.record("\(folder.folderId) reported tracked with the server gone") }
                #expect(folder.records.isEmpty && folder.removals.isEmpty)
            }
        }
    }

    // MARK: - r2: lapses through the real reader path

    /// A context whose clock reads `now` (fixed) with budget always left: the
    /// QRESYNC SELECT's timeout is then one ordinary request's timeout.
    static func fixedClock(_ now: Date) -> ChangeContext {
        ChangeContext(deadline: now.addingTimeInterval(0.001), clock: { now }, onProgress: { _ in })
    }

    static func status(_ set: ChangeSet, _ folderId: String) throws -> FolderChanges {
        try #require(set.folders.first { $0.folderId == folderId })
    }

    @Test("A QRESYNC SELECT that times out on every pass keeps its failure time and lapses to the listing")
    func repeatedSelectTimeoutLapses() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: 1)
            let start = Date()
            let stall = SyncConfig.changeReadRequestTimeoutSeconds + 1
            w.server.stallNextCommand(containing: "QRESYNC (", seconds: stall)
            let first = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor], context: Self.fixedClock(start)))
            guard case .failed = first.status else { Issue.record("pass 1: expected failed, got \(first.status)"); return }
            #expect(try #require(IMAPChangeCursor.decode(first.cursor)).failingSince == start,
                    "the timed-out folder keeps the time its reads started failing")

            w.server.stallNextCommand(containing: "QRESYNC (", seconds: stall)
            let later = start.addingTimeInterval(SyncConfig.changeReadFailureLapseSeconds)
            let second = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: first.cursor], context: Self.fixedClock(later)))
            guard case .refused(.failingTooLong) = second.status else {
                Issue.record("pass 2: expected refused(failingTooLong), got \(second.status)"); return
            }
        }
    }

    @Test("A change session that never opens fails every tracked folder under the same lapse rule")
    func sessionNeverOpensLapses() async throws {
        try await Self.withWorld(inbox: [1], archive: [1]) { w in
            let bookmark = IMAPChangeCursor(uidValidity: UInt32(Self.epoch), highestModSeq: 1, uidNext: 2).encoded
            let cursors: [String: String?] = [w.inboxId: bookmark, w.archiveId: bookmark]
            let start = Date()
            w.server.failNextCommand(containing: "ENABLE")
            let first = try await Self.read(w, cursors: cursors, archiveSynced: true, context: Self.fixedClock(start))
            var stamped: [String: String?] = [:]
            for id in [w.inboxId, w.archiveId] {
                let folder = try Self.status(first, id)
                guard case .failed = folder.status else { Issue.record("pass 1 \(id): expected failed, got \(folder.status)"); return }
                #expect(try #require(IMAPChangeCursor.decode(folder.cursor)).failingSince == start)
                stamped[id] = folder.cursor
            }

            w.server.failNextCommand(containing: "ENABLE")
            let later = start.addingTimeInterval(SyncConfig.changeReadFailureLapseSeconds)
            let second = try await Self.read(w, cursors: stamped, archiveSynced: true, context: Self.fixedClock(later))
            for id in [w.inboxId, w.archiveId] {
                let folder = try Self.status(second, id)
                guard case .refused(.failingTooLong) = folder.status else {
                    Issue.record("pass 2 \(id): expected refused(failingTooLong), got \(folder.status)"); return
                }
            }
        }
    }

    // MARK: - r2: the budget running out after the QRESYNC SELECT

    @Test("Budget spent after the QRESYNC SELECT: the folder is not run, keeps its old bookmark, and nothing applies")
    func budgetSpentAfterSelect() async throws {
        enum Shape: CaseIterable { case arrivals, changedNotHeld, recheck }
        for shape in Shape.allCases {
            try await Self.withWorld(inbox: [1, 2, 3]) { w in
                let cursor = try await Self.baseline(w)
                var recheck: [String: [String]] = [:]
                switch shape {
                case .arrivals:
                    w.server.setMessages([1, 2, 3, 4].map(Self.message), in: Self.inboxPath)
                case .changedNotHeld:
                    w.local.remove(w.inboxId, [2])
                    w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: 2)
                case .recheck:
                    w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: 1)
                    recheck = [w.inboxId: ["3"]]
                }
                // Budget left until the QRESYNC SELECT has been sent, none after.
                let server = w.server
                let start = Date()
                let context = ChangeContext(
                    deadline: start.addingTimeInterval(60),
                    clock: {
                        server.recordedCommands().contains { $0.uppercased().contains("QRESYNC (") }
                            ? start.addingTimeInterval(120) : start
                    },
                    onProgress: { _ in })
                let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor], recheck: recheck, context: context))
                guard case .notRun = changes.status else { Issue.record("\(shape): expected notRun, got \(changes.status)"); return }
                #expect(changes.cursor == nil, "\(shape): the old bookmark stays")
                #expect(changes.records.isEmpty && changes.removals.isEmpty && changes.rereadLater.isEmpty, "\(shape): nothing applies")
            }
        }
    }

    // MARK: - r2: arrivals boundaries

    @Test("Arrivals: exactly the limit is read in full; the refusal starts one over it")
    func arrivalsExactlyAtTheLimit() async throws {
        let limit = SyncConfig.imapChangeArrivalsLimit
        try await Self.withWorld(inbox: [1]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setMessages((1...(limit + 1)).map(Self.message), in: Self.inboxPath)
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(Self.isTracked(changes.status), "exactly \(limit) arrivals are within the limit: \(changes.status)")
            #expect(changes.records.compactMap(\.header).count == limit)
        }
    }

    @Test("Arrivals: a server whose UID SEARCH ignores the range never refetches held messages below the bookmark")
    func arrivalsSearchBelowTheBookmarkIgnored() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            // The fake's UID SEARCH answers the whole mailbox by default, as a
            // server ignoring the UID set would.
            w.server.setMessages([1, 2, 3].map(Self.message), in: Self.inboxPath)
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(Set(changes.records.compactMap { $0.header?.messageId }) == ["3"],
                    "only the arrival is fetched in full")
        }
    }

    // MARK: - r3 coverage

    static func uidFetches(_ w: World, since start: Int) -> [String] {
        w.server.recordedCommands().dropFirst(start).filter { $0.uppercased().contains("UID FETCH") }
    }

    static func logouts(_ w: World) -> Int {
        w.server.recordedCommands().filter { $0.uppercased().hasPrefix("LOGOUT") }.count
    }

    /// Polls `condition` for up to `timeout` seconds (detached logouts land asynchronously).
    static func eventually(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// `eventually` for a condition read from an actor.
    static func eventuallyAsync(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    @Test("markDirty and disconnect drop the change connection and log it out; the next pass opens a new session")
    func teardownDropsChangeConnection() async throws {
        for teardown in ["markDirty", "disconnect"] {
            try await Self.withWorld(inbox: [1]) { w in
                _ = try await Self.baseline(w)
                #expect(await w.provider.changeServer != nil, "setup: the pass opened the change connection")
                let logoutsBefore = Self.logouts(w)
                if teardown == "markDirty" { await w.provider.markDirty() } else { try await w.provider.disconnect(); try await w.provider.connect() }
                #expect(await w.provider.changeServer == nil, "\(teardown) dropped the change connection")
                #expect(await Self.eventually { Self.logouts(w) > logoutsBefore }, "\(teardown) logged the change session out")
                let enablesBefore = w.server.recordedCommands().filter { $0.uppercased().hasPrefix("ENABLE") }.count
                _ = try await Self.read(w)
                #expect(w.server.recordedCommands().filter { $0.uppercased().hasPrefix("ENABLE") }.count == enablesBefore + 1,
                        "\(teardown): the next pass opened a new QRESYNC session")
            }
        }
    }

    @Test("A change session torn down while it opens is never kept: the pass fails and the opened session is logged out")
    func teardownWhileOpeningIsNotPlanted() async throws {
        try await Self.withWorld(inbox: [1]) { w in
            w.server.holdGreetings()
            let pass = Task { try await Self.read(w) }
            #expect(await Self.eventually { w.server.heldGreetingCount() >= 1 }, "setup: the change connection is opening")
            await w.provider.markDirty()
            let logoutsBefore = Self.logouts(w)
            w.server.releaseGreetings()
            let set = try await pass.value
            let inbox = try Self.inbox(w, set)
            guard case .failed = inbox.status else { Issue.record("expected failed, got \(inbox.status)"); return }
            #expect(await w.provider.changeServer == nil, "a session opened across a teardown is never planted")
            #expect(await Self.eventually { Self.logouts(w) > logoutsBefore }, "the refused session is logged out")
        }
    }

    @Test("Baseline: a plain SELECT serving another UIDVALIDITY than the folder stores refuses, and starts no bookmark")
    func baselineEpochChangeRefuses() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            w.server.setUidValidity(Self.epoch + 5, for: Self.inboxPath)
            let changes = try await Self.inbox(w, Self.read(w))
            guard case .refused(.addressEpochChanged(let served)) = changes.status else {
                Issue.record("expected refused(addressEpochChanged), got \(changes.status)"); return
            }
            #expect(served == Self.epoch + 5)
            #expect(changes.cursor == nil)
        }
    }

    @Test("A changed message below what the older-mail walk has downloaded is ignored: no record, no fetch (the walk's to download)")
    func changedBelowTheWalkIsIgnored() async throws {
        for olderMail in [IMAPChangeReaderTests.OlderMail.walkedDownTo(4), .notStarted] {
            try await Self.withWorld(inbox: [1, 2, 3, 4, 5, 6]) { w in
                w.local.set(w.inboxId, [5, 6])
                let cursor = try await Self.baseline(w)
                w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: 2)
                let start = w.server.recordedCommands().count
                let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor], olderMail: olderMail))
                #expect(Self.isTracked(changes.status))
                #expect(!changes.records.contains { $0.messageId == "2" }, "\(olderMail)")
                #expect(Self.uidFetches(w, since: start).isEmpty, "\(olderMail): nothing below the held range is fetched: \(Self.uidFetches(w, since: start))")
            }
        }
    }

    @Test("The held range starts where the older-mail walk is, never at the lowest row held now")
    func heldRangeStartComesFromTheWalk() {
        func folder(_ complete: Bool, _ walkCursor: Int?) -> ChangeFolder {
            ChangeFolder(id: "f", path: "INBOX", role: .inbox, olderMailComplete: complete, olderMailCursor: walkCursor)
        }
        #expect(IMAPProvider.heldRangeStart(folder(true, nil)) == 1, "a completed walk: every UID")
        #expect(IMAPProvider.heldRangeStart(folder(false, 40)) == 41, "a walk in progress: above its position")
        #expect(IMAPProvider.heldRangeStart(folder(false, nil)) == nil, "no walk yet: none")
    }

    @Test("Arrivals: a compact SEARCH answer of billions of UIDs is walked only up to one past the limit, never expanded")
    func arrivalsAreBoundedBeforeExpansion() {
        let limit = SyncConfig.imapChangeArrivalsLimit
        let huge = MessageIdentifierSet<UID>(UID(1)...UID(4_000_000_000))
        let start = ContinuousClock.now
        let taken = IMAPProvider.arrivals(in: huge, from: 10, excluding: [11], room: limit)
        #expect(ContinuousClock.now - start < .seconds(1), "bounded work: the answer is never expanded")
        #expect(taken.count == limit + 1, "one past the room, enough to refuse")
        #expect(taken.first == 10, "from the bookmark's UIDNEXT, in UID order")
        #expect(!taken.contains(11), "an excluded UID is skipped")
        #expect(taken == Array(10...UInt32(limit + 11)).filter { $0 != 11 })
        // Within the room: every eligible UID across ranges, in order, none below `from`.
        var sparse = MessageIdentifierSet<UID>()
        sparse.insert(ranges: 2...4, 8...9, 20...20)
        #expect(IMAPProvider.arrivals(in: sparse, from: 3, excluding: [8], room: limit) == [3, 4, 9, 20])
        #expect(IMAPProvider.arrivals(in: sparse, from: 21, excluding: [], room: limit).isEmpty)
    }

    @Test("Re-read confirmation: a compact SEARCH answer spanning millions of UIDs is asked per missing UID, never expanded")
    func confirmingSearchAnswerIsNeverExpanded() {
        let huge = MessageIdentifierSet<UID>(UID(1)...UID(50_000_000))
        let start = ContinuousClock.now
        let answer = IMAPProvider.confirmMissing([7, 49_999_999, 50_000_001], present: huge)
        #expect(ContinuousClock.now - start < .seconds(1), "bounded work: the answer is never expanded")
        #expect(answer.unreadable == ["7", "49999999"], "still on the server: read again")
        #expect(answer.removals == ["50000001"], "not on the server: removed")
        // A sparse answer: membership across ranges, in the missing list's order.
        var sparse = MessageIdentifierSet<UID>()
        sparse.insert(ranges: 2...4, 9...9)
        let mixed = IMAPProvider.confirmMissing([9, 5, 3, 1], present: sparse)
        #expect(mixed.unreadable == ["9", "3"])
        #expect(mixed.removals == ["5", "1"])
        let none = IMAPProvider.confirmMissing([], present: huge)
        #expect(none.unreadable.isEmpty && none.removals.isEmpty)
    }

    @Test("The oldest held message, deleted elsewhere and then un-deleted, comes back on the next pass")
    func undeletedOldestHeldComesBack() async throws {
        try await Self.withWorld(inbox: [1, 2, 3]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setFlags(["\\Deleted"], in: Self.inboxPath, uid: 1)
            let first = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(first.removals == ["1"], "setup: the deleted message is removed")
            // The apply removed the row: the device's lowest held message is now 2.
            w.local.remove(w.inboxId, [1])
            w.server.setFlags([], in: Self.inboxPath, uid: 1)
            let second = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: first.cursor]))
            #expect(Self.isTracked(second.status))
            let record = try #require(second.records.first { $0.messageId == "1" }, "the un-deleted message is read again")
            #expect(record.header != nil, "a full record, so the apply inserts it")
        }
    }

    @Test("A pass-start NOOP that keeps failing: every tracked folder keeps its failure time and lapses to the listing")
    func failingNoopLapses() async throws {
        try await Self.withWorld(inbox: [1], archive: [1]) { w in
            let bookmark = IMAPChangeCursor(uidValidity: UInt32(Self.epoch), highestModSeq: 1, uidNext: 2).encoded
            let cursors: [String: String?] = [w.inboxId: bookmark, w.archiveId: bookmark]
            let start = Date()
            w.server.failNextCommand(containing: "NOOP")
            let first = try await Self.read(w, cursors: cursors, archiveSynced: true, context: Self.fixedClock(start))
            var stamped: [String: String?] = [:]
            for id in [w.inboxId, w.archiveId] {
                let folder = try Self.status(first, id)
                guard case .failed = folder.status else { Issue.record("pass 1 \(id): expected failed, got \(folder.status)"); return }
                #expect(try #require(IMAPChangeCursor.decode(folder.cursor)).failingSince == start,
                        "pass 1 \(id): the failure time is kept")
                stamped[id] = folder.cursor
            }

            w.server.failNextCommand(containing: "NOOP")
            let later = start.addingTimeInterval(SyncConfig.changeReadFailureLapseSeconds)
            let second = try await Self.read(w, cursors: stamped, archiveSynced: true, context: Self.fixedClock(later))
            for id in [w.inboxId, w.archiveId] {
                let folder = try Self.status(second, id)
                guard case .refused(.failingTooLong) = folder.status else {
                    Issue.record("pass 2 \(id): expected refused(failingTooLong), got \(folder.status)"); return
                }
            }
        }
    }

    @Test("A server that answers STATUS from a cached view: the pass-start NOOP lets a change made elsewhere be seen")
    func staleStatusIsRefreshedByTheNoop() async throws {
        try await Self.withWorld(inbox: [1, 2], archive: [1]) { w in
            w.server.setStatusStaleUntilNoop(true)
            // Both folders read once: the change connection's cached view now
            // holds the inbox's STATUS, and the archive is the one selected.
            let first = try await Self.read(w, archiveSynced: true)
            let inboxCursor = try #require(try Self.inbox(w, first).cursor)
            let archiveCursor = try #require(first.folders.first { $0.folderId == w.archiveId }?.cursor)
            #expect(await w.provider.changeSelectedPath == Self.archivePath, "setup: the inbox is read by STATUS next")
            w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: 1)
            let second = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: inboxCursor, w.archiveId: archiveCursor],
                                                           archiveSynced: true))
            #expect(Self.isTracked(second.status))
            #expect(second.records.first { $0.messageId == "1" }?.isRead == true, "the read made elsewhere is seen")
        }
    }

    // MARK: - c4 #3: the connection budget

    /// A provider against a server allowing `maxSessions` logged-in sessions,
    /// under a username of its own (the learned limit is kept per user).
    static func withLimitedWorld(
        maxSessions: Int, extraMailboxes: [String] = [], _ body: (World) async throws -> Void
    ) async throws {
        var mailboxes: [String: [FakeIMAPServer.Message]] = [inboxPath: [1, 2, 3].map(message), archivePath: []]
        for extra in extraMailboxes { mailboxes[extra] = [] }
        let server = FakeIMAPServer(
            username: "budget-\(UUID().uuidString.lowercased())", capabilities: qresyncCapabilities,
            mailboxes: mailboxes)
        server.setUidValidity(epoch, for: inboxPath)
        server.setUidValidity(epoch, for: archivePath)
        server.setMaxLoggedInSessions(maxSessions)
        try server.start()
        defer { server.stop() }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        let world = World(server: server, provider: provider, local: LocalRows())
        world.local.set(world.inboxId, [1, 2, 3])
        try await body(world)
        #expect(server.wrongMessageViolations().isEmpty)
        #expect(server.liveSessionCount() <= maxSessions)
    }

    @Test("A server allowing two connections: a change pass, a folder fetch and an action all complete, again and again")
    func twoConnectionServerRunsEverything() async throws {
        try await Self.withLimitedWorld(maxSessions: 2) { w in
            // The action connection (connect) and the change connection.
            var cursor = try await Self.baseline(w)
            for round in 0..<2 {
                // The folder fetch needs a third login: the idle change connection makes room.
                let fetched = try await w.provider.fetchMessages(folder: Self.inboxPath, limit: 10, offset: 0)
                #expect(Set(fetched.map(\.messageId)) == ["1", "2", "3"], "round \(round): the folder fetch completes")
                #expect(await w.provider.changeServer == nil, "round \(round): the idle change connection was evicted")
                try await w.provider.markRead(ids: ["2"], folder: Self.inboxPath, admittedUidValidity: UInt32(Self.epoch))
                #expect(w.server.flags(in: Self.inboxPath, uid: 2).contains("\\Seen"), "round \(round): the action completes")
                w.server.setFlags(round == 0 ? ["\\Flagged"] : [], in: Self.inboxPath, uid: 3)
                // The next pass needs a login again: the idle folder connection makes room.
                let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
                #expect(Self.isTracked(changes.status), "round \(round): the change pass completes: \(changes.status)")
                #expect(changes.records.first { $0.messageId == "3" }?.isFlagged == (round == 0), "round \(round): the change is read")
                cursor = try #require(changes.cursor)
            }
            #expect(w.server.refusedLoginCount() >= 1, "the limit was reached and learned")
            #expect(await w.provider.detectedServerLimit() == 2)
        }
    }

    @Test("Opening the change connection: a retry refused again fails the pass after two logins, keeps no session and keeps the failure time")
    func changeOpenRefusedTwiceFailsThePass() async throws {
        try await Self.withLimitedWorld(maxSessions: 2) { w in
            let cursor = try await Self.baseline(w)
            func logins() -> Int { w.server.recordedCommands().filter { $0.uppercased().hasPrefix("LOGIN") }.count }
            let start = Date()
            var stamped = cursor
            for (pass, now) in [start, start.addingTimeInterval(1)].enumerated() {
                // A folder connection: it evicts the idle change connection and is itself evictable.
                _ = try await w.provider.fetchMessages(folder: Self.inboxPath, limit: 10, offset: 0)
                #expect(await w.provider.changeServer == nil, "pass \(pass) setup: the change connection is closed")
                w.server.refuseNextLogins(2)
                let refusedBefore = w.server.refusedLoginCount()
                let loginsBefore = logins()
                let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: stamped], context: Self.fixedClock(now)))
                #expect(logins() - loginsBefore == 2, "pass \(pass): one login and one retry, no third")
                #expect(w.server.refusedLoginCount() - refusedBefore == 2, "pass \(pass): both refused")
                #expect(await w.provider.changeServer == nil, "pass \(pass): no change session is kept")
                guard case .failed = changes.status else { Issue.record("pass \(pass): expected failed, got \(changes.status)"); return }
                #expect(changes.records.isEmpty)
                #expect(try #require(IMAPChangeCursor.decode(changes.cursor)).failingSince == start,
                        "pass \(pass): the failure time is the first failure's")
                stamped = try #require(changes.cursor)
            }
        }
    }

    @Test("Eviction order: an idle change connection makes room before IDLE, never during a pass")
    func idleChangeConnectionIsEvictedBeforeIdle() async throws {
        try await Self.withLimitedWorld(maxSessions: 3) { w in
            await w.provider.startIdle { _, _ in }
            #expect(await Self.eventuallyAsync { await w.provider.currentIdleServerForTesting() != nil }, "setup: IDLE is open")
            let cursor = try await Self.baseline(w)
            #expect(await w.provider.changeServer != nil, "setup: action, IDLE and the change connection fill the limit")
            let fetched = try await w.provider.fetchMessages(folder: Self.inboxPath, limit: 10, offset: 0)
            #expect(fetched.count == 3, "the folder fetch completes")
            #expect(await w.provider.changeServer == nil, "the idle change connection was evicted")
            #expect(await w.provider.currentIdleServerForTesting() != nil, "IDLE kept its connection")

            // During a pass the change connection is never evicted: a folder
            // fetch that needs a slot then takes IDLE's, and the pass completes.
            let start = w.server.recordedCommands().count
            w.server.stallNextCommand(containing: "NOOP", seconds: 1)
            let pass = Task { try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor])) }
            #expect(await Self.eventually {
                w.server.recordedCommands().dropFirst(start).contains { $0.uppercased().hasPrefix("NOOP") }
            }, "setup: the pass holds the change connection")
            #expect(await w.provider.currentIdleServerForTesting() != nil,
                    "opening the change connection evicted the folder connection, not IDLE")
            let archive = try await w.provider.fetchMessages(folder: Self.archivePath, limit: 10, offset: 0)
            #expect(archive.isEmpty, "the folder fetch completes")
            let changes = try await pass.value
            #expect(Self.isTracked(changes.status), "the pass completes on its connection: \(changes.status)")
            #expect(await w.provider.changeServer != nil, "the change connection was kept through the pass")
            #expect(await w.provider.currentIdleServerForTesting() == nil, "IDLE made room instead")
            await w.provider.stopIdle()
        }
    }

    @Test("IDLE eviction: the session's IDLE is ended before its logout, so the login made after it is never refused")
    func idleEvictionEndsIdleBeforeTheLogout() async throws {
        try await Self.withLimitedWorld(maxSessions: 3) { w in
            await w.provider.startIdle { _, _ in }
            #expect(await Self.eventuallyAsync { await w.provider.currentIdleServerForTesting() != nil }, "setup: IDLE is open")
            let cursor = try await Self.baseline(w)
            // Learn the limit (3); the idle change connection makes room.
            _ = try await w.provider.fetchMessages(folder: Self.inboxPath, limit: 10, offset: 0)
            // DONE is held back past the moment the eviction ends IDLE's turn,
            // so the IDLE listener has every chance to act first.
            let doneHeldBack: Duration = .milliseconds(300)
            await w.provider.setIdleEvictionBeforeDoneTestHookForTesting { try? await Task.sleep(for: doneHeldBack) }
            // A pass holds the change connection: a folder fetch needing a slot takes IDLE's.
            let start = w.server.recordedCommands().count
            w.server.stallNextCommand(containing: "NOOP", seconds: 1)
            let pass = Task { try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor])) }
            #expect(await Self.eventually {
                w.server.recordedCommands().dropFirst(start).contains { $0.uppercased().hasPrefix("NOOP") }
            }, "setup: the pass holds the change connection")
            #expect(await w.provider.currentIdleServerForTesting() != nil, "setup: IDLE holds the third slot")
            let refusedBefore = w.server.refusedLoginCount()
            let archive = try? await w.provider.fetchMessages(folder: Self.archivePath, limit: 10, offset: 0)
            #expect(archive != nil, "the folder fetch that took IDLE's slot completes")
            #expect(w.server.refusedLoginCount() - refusedBefore <= 1,
                    "at most the one refusal that makes IDLE give up its slot; the login after it is never refused")
            #expect(await w.provider.currentIdleServerForTesting() == nil, "IDLE made room")
            let changes = try await pass.value
            #expect(Self.isTracked(changes.status), "the pass completes: \(changes.status)")
            await w.provider.setIdleEvictionBeforeDoneTestHookForTesting(nil)
            await w.provider.stopIdle()
        }
    }

    @Test("IDLE eviction: a DONE the server does not answer within the bound closes the session, so the login made after it is never refused")
    func idleEvictionDoneWaitIsBounded() async throws {
        try await Self.withLimitedWorld(maxSessions: 3) { w in
            await w.provider.startIdle { _, _ in }
            #expect(await Self.eventuallyAsync { await w.provider.currentIdleServerForTesting() != nil }, "setup: IDLE is open")
            let cursor = try await Self.baseline(w)
            _ = try await w.provider.fetchMessages(folder: Self.inboxPath, limit: 10, offset: 0)
            // The server answers DONE only after the login's whole wait for the logout.
            let doneAnswered = SyncConfig.imapEvictionLogoutWaitSeconds + 2
            w.server.delayNextIdleDoneReply(seconds: doneAnswered)
            let start = w.server.recordedCommands().count
            w.server.stallNextCommand(containing: "NOOP", seconds: 1)
            let pass = Task { try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor])) }
            #expect(await Self.eventually {
                w.server.recordedCommands().dropFirst(start).contains { $0.uppercased().hasPrefix("NOOP") }
            }, "setup: the pass holds the change connection")
            let refusedBefore = w.server.refusedLoginCount()
            let began = Date()
            let archive = try? await w.provider.fetchMessages(folder: Self.archivePath, limit: 10, offset: 0)
            #expect(archive != nil, "the folder fetch that took IDLE's slot completes")
            #expect(Date().timeIntervalSince(began) < doneAnswered, "it did not wait for the DONE answer")
            #expect(w.server.refusedLoginCount() - refusedBefore <= 1,
                    "at most the one refusal that makes IDLE give up its slot; the login after it is never refused")
            _ = try await pass.value
            await w.provider.stopIdle()
        }
    }

    @Test("Capacity eviction: a folder login made after the idle change connection was evicted waits for its logout, so it is never refused")
    func capacityEvictionWaitsForTheLogout() async throws {
        try await Self.withLimitedWorld(maxSessions: 3) { w in
            _ = try await Self.baseline(w)
            // Learn the limit (3): the inbox login is refused once, the idle change connection makes room.
            w.server.refuseNextLogins(1)
            _ = try await w.provider.fetchMessages(folder: Self.inboxPath, limit: 10, offset: 0)
            // Action, inbox and change connection: the limit is full again.
            _ = try await Self.inbox(w, Self.read(w))
            #expect(await w.provider.changeServer != nil, "setup: the change connection is open")
            #expect(w.server.liveSessionCount() == 3, "setup: three sessions")

            // The archive fetch evicts the idle change connection before its login
            // (the pool is full); that connection's LOGOUT answers late.
            w.server.stallNextCommand(containing: "LOGOUT", seconds: 0.5)
            let refusedBefore = w.server.refusedLoginCount()
            let archive = try await w.provider.fetchMessages(folder: Self.archivePath, limit: 10, offset: 0)
            #expect(archive.isEmpty, "the folder fetch completes")
            #expect(await w.provider.changeServer == nil, "the idle change connection made room")
            #expect(w.server.refusedLoginCount() == refusedBefore,
                    "the login waited for the evicted session's logout and was not refused")
        }
    }

    @Test("Capacity eviction of several connections: the login waits for every evicted session's logout, answered at different times")
    func capacityEvictionWaitsForEveryLogout() async throws {
        try await Self.withLimitedWorld(maxSessions: 10, extraMailboxes: ["Drafts", "Sent"]) { w in
            for path in [Self.inboxPath, Self.archivePath, "Drafts"] {
                _ = try await w.provider.fetchMessages(folder: path, limit: 10, offset: 0)
            }
            #expect(w.server.liveSessionCount() == 4, "setup: the action and three folder connections")
            // The server now allows two: the next login is refused, the provider
            // learns the limit and its one retry is refused again.
            w.server.setMaxLoggedInSessions(2)
            do {
                _ = try await w.provider.fetchMessages(folder: "Sent", limit: 10, offset: 0)
                Issue.record("setup: the retry should be refused with three sessions still open")
            } catch {}
            // Two folder connections are left over the learned limit: the next
            // fetch evicts both before its login, and their LOGOUTs answer late.
            w.server.stallNextCommand(containing: "LOGOUT", seconds: 0.3)
            w.server.stallNextCommand(containing: "LOGOUT", seconds: 0.6)
            let refusedBefore = w.server.refusedLoginCount()
            let sent = try await w.provider.fetchMessages(folder: "Sent", limit: 10, offset: 0)
            #expect(sent.isEmpty, "the folder fetch completes")
            #expect(w.server.refusedLoginCount() == refusedBefore, "the login waited for both logouts and was not refused")
        }
    }

    @Test("Limit retry: an evicted connection whose LOGOUT never answers holds the folder login only up to the wait bound; the next fetch works")
    func folderRetryWaitIsBounded() async throws {
        try await Self.withLimitedWorld(maxSessions: 2) { w in
            _ = try await Self.baseline(w)
            // Action and change connection fill the limit; the inbox login is refused
            // and the idle change connection is evicted, its LOGOUT stalled past the bound.
            let stall = SyncConfig.imapEvictionLogoutWaitSeconds + 2
            w.server.stallNextCommand(containing: "LOGOUT", seconds: stall)
            let start = Date()
            do {
                _ = try await w.provider.fetchMessages(folder: Self.inboxPath, limit: 10, offset: 0)
                Issue.record("the retry logged in while the evicted session still counted")
            } catch {
                #expect("\(error)".contains("max_userip_connections"), "the server's refusal decides: \(error)")
            }
            #expect(Date().timeIntervalSince(start) < stall, "the retry went ahead before the stalled logout answered")
            #expect(await Self.eventually(timeout: stall) { w.server.liveSessionCount() == 1 }, "setup: the stalled logout answered")
            let fetched = try await w.provider.fetchMessages(folder: Self.inboxPath, limit: 10, offset: 0)
            #expect(fetched.count == 3, "the next fetch works")
        }
    }

    @Test("Change-connection retry: an evicted connection whose LOGOUT never answers holds the pass only up to the wait bound; the next pass works")
    func changeRetryWaitIsBounded() async throws {
        try await Self.withLimitedWorld(maxSessions: 2) { w in
            // Action and an idle inbox connection fill the limit.
            _ = try await w.provider.fetchMessages(folder: Self.inboxPath, limit: 10, offset: 0)
            let stall = SyncConfig.imapEvictionLogoutWaitSeconds + 2
            w.server.stallNextCommand(containing: "LOGOUT", seconds: stall)
            let start = Date()
            let first = try await Self.inbox(w, Self.read(w))
            guard case .failed = first.status else { Issue.record("expected failed, got \(first.status)"); return }
            #expect(Date().timeIntervalSince(start) < stall, "the retry went ahead before the stalled logout answered")
            #expect(await Self.eventually(timeout: stall) { w.server.liveSessionCount() == 1 }, "setup: the stalled logout answered")
            let next = try await Self.inbox(w, Self.read(w))
            guard case .baselineReady = next.status else { Issue.record("the next pass: expected baselineReady, got \(next.status)"); return }
        }
    }

    @Test("Epoch: a STATUS without UIDVALIDITY never reads a renumbered folder whose HIGHESTMODSEQ restarted at the same value as unchanged")
    func coincidingModSeqUnderANewEpochRefuses() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            let bookmark = try #require(IMAPChangeCursor.decode(cursor))
            w.server.setStatusOmits(["UIDVALIDITY"], for: Self.inboxPath)
            w.server.setUidValidity(Self.epoch + 1, for: Self.inboxPath, highestModSeq: Int(bookmark.highestModSeq))
            #expect(w.server.qresyncHighestModSeq(for: Self.inboxPath) == Int(bookmark.highestModSeq),
                    "setup: the new epoch's HIGHESTMODSEQ equals the bookmark's")
            await w.provider.markDirty()
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            guard case .refused(.addressEpochChanged(let served)) = changes.status else {
                Issue.record("expected refused(addressEpochChanged), got \(changes.status)"); return
            }
            #expect(served == Self.epoch + 1)
        }
    }

    @Test("A new arrival already marked \\Deleted is neither fetched nor reported")
    func deletedArrivalIsExcluded() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            w.server.setMessages([1, 2, 3].map(Self.message), in: Self.inboxPath)
            w.server.setFlags(["\\Deleted"], in: Self.inboxPath, uid: 3)
            let start = w.server.recordedCommands().count
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(Self.isTracked(changes.status))
            #expect(!changes.records.contains { $0.messageId == "3" })
            #expect(!changes.removals.contains("3"))
            #expect(Self.uidFetches(w, since: start).isEmpty, "the deleted arrival is not fetched: \(Self.uidFetches(w, since: start))")
        }
    }

    @Test("A held message at or above the bookmark's UIDNEXT (a moved-in row) marked \\Deleted is a removal; an unheld one beside it is not")
    func deletedHeldArrivalIsRemoved() async throws {
        try await Self.withWorld(inbox: [1, 2]) { w in
            let cursor = try await Self.baseline(w)
            // 3 (at the bookmark's UIDNEXT) and 5 (above it) came in by moves the
            // device already re-keyed to them; 4 is new.
            #expect(IMAPChangeCursor.decode(cursor)?.uidNext == 3, "setup: 3 sits at the bookmark's UIDNEXT, 5 above it")
            w.server.setMessages([1, 2, 3, 4, 5].map(Self.message), in: Self.inboxPath)
            w.local.set(w.inboxId, [1, 2, 3, 5])
            for uid in [3, 4, 5] { w.server.setFlags(["\\Deleted"], in: Self.inboxPath, uid: uid) }
            let start = w.server.recordedCommands().count
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(Self.isTracked(changes.status))
            #expect(changes.removals.contains("3"), "the held message the server holds as \\Deleted is removed: \(changes.removals)")
            #expect(changes.removals.contains("5"), "above UIDNEXT too: \(changes.removals)")
            #expect(!changes.removals.contains("4"), "a message the folder does not hold is not reported")
            #expect(!changes.records.contains { ["3", "4", "5"].contains($0.messageId) })
            #expect(Self.uidFetches(w, since: start).isEmpty, "none is fetched: \(Self.uidFetches(w, since: start))")
        }
    }
}
