/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
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

    static func folders(_ w: World, cursors: [String: String?] = [:], archiveSynced: Bool = false) -> [ChangeFolder] {
        [
            ChangeFolder(id: w.inboxId, path: inboxPath, role: .inbox,
                         cursor: cursors[w.inboxId] ?? nil, isSynced: true, addressEpoch: epoch),
            ChangeFolder(id: w.archiveId, path: archivePath, role: .archive,
                         cursor: cursors[w.archiveId] ?? nil, isSynced: archiveSynced, addressEpoch: epoch),
        ]
    }

    static func read(
        _ w: World, cursors: [String: String?] = [:], scope: ChangeScope = .all,
        recheck: [String: [String]] = [:], archiveSynced: Bool = false,
        context: ChangeContext = ChangeContext(onProgress: { _ in })
    ) async throws -> ChangeSet {
        let request = ChangeRequest(
            folders: folders(w, cursors: cursors, archiveSynced: archiveSynced),
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
            #expect(changes.armCatchUpOnCommit)
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

    @Test("Short FETCH on an arrival: the message is read again later, never lost while the bookmark moves (r1 #1)")
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

    @Test("STATUS without MESSAGES or UIDNEXT: the untracked folder is unreadable this pass, never changed, never 0 (r1 #3)")
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

    @Test("A QRESYNC SELECT that times out on every pass keeps its failure time and lapses to the listing (r2 #1)")
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

    @Test("A change session that never opens fails every tracked folder under the same lapse rule (r2 #2)")
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

    /// Polls `condition` (detached logouts land asynchronously).
    static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
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

    @Test("A changed message older than the oldest held one is ignored: no record, no fetch")
    func changedBelowLowestHeldIsIgnored() async throws {
        try await Self.withWorld(inbox: [1, 2, 3, 4, 5, 6]) { w in
            w.local.set(w.inboxId, [5, 6])
            let cursor = try await Self.baseline(w)
            w.server.setFlags(["\\Seen"], in: Self.inboxPath, uid: 2)
            let start = w.server.recordedCommands().count
            let changes = try await Self.inbox(w, Self.read(w, cursors: [w.inboxId: cursor]))
            #expect(Self.isTracked(changes.status))
            #expect(!changes.records.contains { $0.messageId == "2" })
            #expect(Self.uidFetches(w, since: start).isEmpty, "nothing below the held range is fetched: \(Self.uidFetches(w, since: start))")
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
}
