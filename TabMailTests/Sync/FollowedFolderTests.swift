/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
import UIKit
@testable import TabMail

// MARK: - The mark, the syncable set and the IMAP access check

/// A folder a user action lands in is followed (#1109): `Folder.isFollowed`,
/// written only by `SyncEngine.markFollowed`, puts it in the syncable set
/// (`SyncEngine.isSyncable`), and on a server with no mod-sequences an access
/// lists it again when its counters moved (`IMAPProvider.catchUpPlan`).
@Suite("Followed folders: the mark and the syncable set (#1109)")
struct FollowedFolderMarkTests {

    /// Every column of the folder's row but the follow mark.
    static func otherColumns(_ db: DatabaseQueue, _ id: String) throws -> [String: DatabaseValue] {
        let fetched = try db.read { try Row.fetchOne($0, sql: "SELECT * FROM folder WHERE id = ?", arguments: [id]) }
        let row = try #require(fetched, "the folder is stored")
        var columns = Dictionary(uniqueKeysWithValues: zip(row.columnNames, row.databaseValues))
        columns.removeValue(forKey: Folder.followedColumn)
        return columns
    }

    static func isFollowed(_ db: DatabaseQueue, _ id: String) throws -> Bool? {
        try db.read { try Bool.fetchOne($0, sql: "SELECT isFollowed FROM folder WHERE id = ?", arguments: [id]) }
    }

    @Test("markFollowed marks each named folder not followed yet, once, writes no other column, and a followed folder stays followed")
    func markFollowedSetsOnlyTheMark() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inbox = try TestDatabase.insertFolder(db)
        let projects = try TestDatabase.insertFolder(db, name: "Projects", path: "Projects", role: .custom)
        let plain = try TestDatabase.insertFolder(db, name: "Plain", path: "Plain", role: .custom)
        let before = try Self.otherColumns(db, projects.id)
        #expect(try Self.isFollowed(db, projects.id) == false, "precondition: a new folder is not followed")

        let marked = try db.write {
            try SyncEngine.markFollowed(folderIds: [projects.id, projects.id, inbox.id, "acc1:Missing"], db: $0)
        }
        #expect(Set(marked) == [projects.id, inbox.id], "each named folder that exists: \(marked)")
        #expect(marked.count == 2, "each folder once: \(marked)")
        #expect(try Self.isFollowed(db, projects.id) == true)
        #expect(try Self.isFollowed(db, inbox.id) == true)
        #expect(try Self.isFollowed(db, plain.id) == false, "a folder not named stays as it was")
        let after = try Self.otherColumns(db, projects.id)
        #expect(after == before, "no other column moved, the backfill version included")

        let again = try db.write { try SyncEngine.markFollowed(folderIds: [projects.id], db: $0) }
        #expect(again.isEmpty, "a followed folder is not marked again")
        #expect(try Self.isFollowed(db, projects.id) == true, "and stays followed")
        let none = try db.write { try SyncEngine.markFollowed(folderIds: [], db: $0) }
        #expect(none.isEmpty)
    }

    @Test("A followed folder is in the syncable set, after the secondary roles; a custom folder neither followed nor a favourite is not")
    func followedFolderIsSyncable() {
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let sent = Folder(name: "Sent", path: "Sent", role: .sent, accountId: "acc1")
        let plain = Folder(name: "Plain", path: "Plain", role: .custom, accountId: "acc1")
        var favourite = Folder(name: "Starred", path: "Starred", role: .custom, accountId: "acc1")
        favourite.isFavorite = true
        var followed = Folder(name: "Projects", path: "Projects", role: .custom, accountId: "acc1")
        followed.isFollowed = true

        #expect(!SyncEngine.isSyncable(plain))
        #expect(SyncEngine.isSyncable(followed))
        let order = SyncEngine().syncableFoldersInOrder([followed, plain, sent, favourite, inbox]).map(\.path)
        #expect(order == ["INBOX", "Starred", "Sent", "Projects"])
    }

    @Test("IMAP: an access lists an untracked folder when its counters moved since its last completed listing started (with or without MODSEQ), or, with no MODSEQ pair to compare, when that listing is older than the access age; nothing else does")
    func accessCheckPlan() {
        typealias P = IMAPProvider
        typealias Counters = IMAPCatchUpState.Counters
        let now = Date()
        let recent = now.addingTimeInterval(-60)
        let old = now.addingTimeInterval(-SyncConfig.catchUpAccessCheckAgeSeconds - 60)
        let counters = Counters(exists: 118, uidNext: 121)
        let fewer = Counters(exists: 117, uidNext: 121)
        let arrived = Counters(exists: 118, uidNext: 122)
        func state(_ completed: Date, _ recorded: Counters?, stamp: Int? = nil) -> IMAPCatchUpState {
            IMAPCatchUpState(epoch: 1, completionStamp: stamp, lastCompletedAt: completed, completionCounters: recorded)
        }
        func list(_ start: Counters?) -> P.CatchUpPlan { .list(.init(firstCounters: start, nextUid: 1)) }

        // No access: the daily schedule alone decides.
        #expect(P.catchUpPlan(state: state(recent, counters), freshModSeq: nil, now: now, counters: fewer) == .none)
        // An access with nothing moved and a recent listing: nothing.
        #expect(P.catchUpPlan(state: state(recent, counters), freshModSeq: nil, now: now, counters: counters, accessed: true) == .none)
        // A message removed elsewhere lowers EXISTS (`fewer`). With EXISTS equal, a
        // moved UIDNEXT means one message arrived and another was removed
        // (`arrived`). Either moved counter lists the folder.
        #expect(P.catchUpPlan(state: state(recent, counters), freshModSeq: nil, now: now, counters: fewer, accessed: true) == list(fewer))
        #expect(P.catchUpPlan(state: state(recent, counters), freshModSeq: nil, now: now, counters: arrived, accessed: true) == list(arrived))
        // A flag change moves no counter: past the access age the folder is listed anyway.
        #expect(P.catchUpPlan(state: state(old, counters), freshModSeq: nil, now: now, counters: counters, accessed: true) == list(counters))
        // A listing completed with no counters recorded is listed at the first access.
        #expect(P.catchUpPlan(state: state(recent, nil), freshModSeq: nil, now: now, counters: counters, accessed: true) == list(counters))
        // With an equal MODSEQ pair, moved counters still list: a server with
        // CONDSTORE alone need not move HIGHESTMODSEQ on an expunge.
        let pairMoved = P.catchUpPlan(state: state(recent, counters, stamp: 9), freshModSeq: 9, now: now, counters: fewer, accessed: true)
        #expect(pairMoved == .list(.init(firstStamp: 9, firstCounters: fewer, nextUid: 1)))
        // With a MODSEQ pair and nothing moved, the age does not list it: the MODSEQ check covers a flag change.
        let pairOld = P.catchUpPlan(state: state(old, counters, stamp: 9), freshModSeq: 9, now: now, counters: counters, accessed: true)
        #expect(pairOld == .none)
        // A MODSEQ now, but none when the last completed listing started: no pair, so the counters and the age decide.
        let noPair = P.catchUpPlan(state: state(recent, counters), freshModSeq: 9, now: now, counters: fewer, accessed: true)
        #expect(noPair == .list(.init(firstStamp: 9, firstCounters: fewer, nextUid: 1)))
        let noPairUnmoved = P.catchUpPlan(state: state(recent, counters), freshModSeq: 9, now: now, counters: counters, accessed: true)
        #expect(noPairUnmoved == .none)
        let noPairOld = P.catchUpPlan(state: state(old, counters), freshModSeq: 9, now: now, counters: counters, accessed: true)
        #expect(noPairOld == .list(.init(firstStamp: 9, firstCounters: counters, nextUid: 1)))
        // A stamp from the last completed listing, but no MODSEQ now: no pair either.
        let noFreshOld = P.catchUpPlan(state: state(old, counters, stamp: 9), freshModSeq: nil, now: now, counters: counters, accessed: true)
        #expect(noFreshOld == list(counters))
        // A tracked folder's changes come through its change read.
        #expect(P.catchUpPlan(state: state(recent, counters), freshModSeq: nil, now: now, isTracked: true, counters: fewer, accessed: true) == .none)
        // A first listing records the counters it starts from.
        #expect(P.catchUpPlan(state: nil, freshModSeq: nil, now: now, counters: counters) == list(counters))
    }

    @Test("A catch-up state stored before the counters were recorded decodes with none; its listing resumes, and once one completes with none the next access lists the folder")
    func stateStoredWithoutCountersDecodes() throws {
        typealias Counters = IMAPCatchUpState.Counters
        let counters = Counters(exists: 118, uidNext: 121)
        let now = Date()
        var written = IMAPCatchUpState(epoch: 1, completionStamp: 9, lastCompletedAt: now, completionCounters: counters)
        written.listing = .init(firstStamp: 9, firstCounters: counters, nextUid: 5)
        // The same state as an older build stored it: no counters, in the state or its listing.
        let raw = try #require(written.encoded())
        let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        var object = try #require(parsed as? [String: Any])
        var listingObject = try #require(object["listing"] as? [String: Any])
        object.removeValue(forKey: "completionCounters")
        listingObject.removeValue(forKey: "firstCounters")
        object["listing"] = listingObject
        let olderData = try JSONSerialization.data(withJSONObject: object)
        let decoded = IMAPCatchUpState.decode(String(decoding: olderData, as: UTF8.self))
        let older = try #require(decoded, "a state stored before the counters decodes")
        let inProgress = try #require(older.listing, "with its listing in progress")
        #expect(older.completionCounters == nil && inProgress.firstCounters == nil)
        #expect(older.completionStamp == 9 && inProgress.firstStamp == 9 && inProgress.nextUid == 5, "the rest is kept")

        let resumed = IMAPProvider.catchUpPlan(state: older, freshModSeq: 9, now: now, counters: counters, accessed: true)
        #expect(resumed == .list(inProgress), "the listing in progress resumes where it was")
        var completed = older
        completed.listing = nil
        let next = IMAPProvider.catchUpPlan(state: completed, freshModSeq: 9, now: now, counters: counters, accessed: true)
        #expect(next == .list(.init(firstStamp: 9, firstCounters: counters, nextUid: 1)),
                "a completion with no counters recorded: the next access lists the folder, recording them")
    }
}

// MARK: - IMAP, end to end

/// The wall limit of each test case in `FollowedFolderIMAPTests`. At file
/// scope because a trait of `@Suite` cannot name a member of its own type.
let followedFolderIMAPTestTimeLimit: TimeLimitTrait.Duration = .minutes(5)

/// A custom folder that is neither a favourite nor followed holds 120 messages
/// on the server. While the app did not follow it, another client deleted two
/// messages below the newest 50, moved one away, and marked one read and one
/// flagged; one message there was never loaded on the device. The system
/// property: after a user action lands in the folder (opening it, a move into
/// it, opening one of its messages from a search result) and the catch-up run
/// that action starts has ended, the device holds exactly the messages the
/// server holds there, each with the server's read and flag state, and the
/// folder is followed. Driven end to end against `FakeIMAPServer` (wire oracle
/// on) through `AccountManager.shared`, on a server with no mod-sequences and
/// on a QRESYNC server.
@Suite("Followed folders: a user action reconciles the whole folder, IMAP (#1109)", .serialized, .processGlobalState,
       .timeLimit(followedFolderIMAPTestTimeLimit))
struct FollowedFolderIMAPTests {

    static let epoch = 47
    static let path = "Projects"
    static let serverUIDs = Array(1...120)
    /// Below the newest 50 (UIDs 71...120): what the folder's own listing never reaches.
    static let deleted = [5, 20]
    static let movedAway = [11]
    static let readElsewhere = [30]
    static let flaggedElsewhere = [40]
    static let neverLoaded = 60
    /// The Inbox message the move scenario moves into the folder.
    static let inboxUID = 7
    static let inboxMessage = "followed-inbox"
    /// Bounded waits for the access run a message open starts on its own task.
    static let openPolls = 300
    /// How long (in 50 ms polls) a message's body request waits for an access
    /// run that may have started with the open: 2 s.
    static let bodyRequestPolls = 40
    /// The pause between two accesses handed over during a run.
    static let handoverGap = Duration.milliseconds(200)
    /// The role folders an archive and a delete move a message to.
    static let archivePath = "Archive"
    static let trashPath = "Trash"

    /// A user action that takes a message out of the folder.
    enum Action: String, CaseIterable, Sendable {
        case move, archive, delete

        /// Where the message lands.
        var destination: String {
            switch self {
            case .move: "INBOX"
            case .archive: FollowedFolderIMAPTests.archivePath
            case .delete: FollowedFolderIMAPTests.trashPath
            }
        }

        @MainActor
        func perform(_ message: MessageHeader) async {
            switch self {
            case .move: await AccountManager.shared.move([message], to: destination)
            case .archive: _ = await AccountManager.shared.archive([message])
            case .delete: await AccountManager.shared.delete([message])
            }
        }
    }

    enum Server: String, CaseIterable, Sendable {
        /// No CONDSTORE: no change read; the access check compares counters.
        case plain
        /// QRESYNC: the change reader tracks the folder once it is followed.
        case qresync

        var capabilities: [String] {
            switch self {
            case .plain: FakeIMAPServer.defaultCapabilities
            case .qresync: FakeIMAPServer.defaultCapabilities + ["ENABLE", "CONDSTORE", "QRESYNC"]
            }
        }
    }

    static func message(_ uid: Int, id: String? = nil) -> FakeIMAPServer.Message {
        let id = id ?? "followed-\(uid)"
        return FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Receiver <receiver@example.com>\r
        Subject: followed \(id)\r
        Date: \(TestFixtureDate.rfc2822(daysFromAnchor: -1 - (uid % 400)))\r
        Message-ID: <\(id)@example.com>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        body\r

        """)
    }

    /// Every catch-up slice the account's engine starts: the folders it asks,
    /// and how many commands the server had seen when it started.
    final class SliceRecorder: Sendable {
        struct Slice: Sendable {
            let folderIds: [String]
            let commandsBefore: Int
        }
        private let slices = Mutex<[Slice]>([])
        func record(_ folderIds: [String], commandsBefore: Int) {
            slices.withLock { $0.append(Slice(folderIds: folderIds, commandsBefore: commandsBefore)) }
        }
        var all: [Slice] { slices.withLock { $0 } }
        func reset() { slices.withLock { $0 = [] } }
    }

    struct World {
        let server: FakeIMAPServer
        let provider: IMAPProvider
        let pool: DatabasePool
        let accountId: String
        let recorder = SliceRecorder()
        var folderId: String { "\(accountId):\(FollowedFolderIMAPTests.path)" }
        var inboxId: String { "\(accountId):INBOX" }
        /// The id of the account's folder at `path`.
        func idOfFolder(_ path: String) -> String { "\(accountId):\(path)" }

        /// Installs the account engine's slice hook: each slice is recorded,
        /// then `action` runs, and the slice waits for it.
        func watchSlices(_ action: (@Sendable ([String]) async -> Void)? = nil) async {
            let recorder = recorder
            let server = server
            await AccountManager.shared.syncEngine.setCatchUpSliceStartHookForTesting { folderIds in
                recorder.record(folderIds, commandsBefore: server.recordedCommandsWithMailbox().count)
                await action?(folderIds)
            }
        }

        /// The listing commands (`UID FETCH`, `UID SEARCH`) sent to the folder's
        /// mailbox from position `index` of the server's log on.
        func folderListingCommands(since index: Int) -> [String] {
            server.recordedCommandsWithMailbox().dropFirst(index)
                .filter { $0.mailbox == FollowedFolderIMAPTests.path }
                .map(\.command)
                .filter { $0.uppercased().hasPrefix("UID FETCH") || $0.uppercased().hasPrefix("UID SEARCH") }
        }

        /// Every command the server has seen that changes a mailbox.
        func mutatingCommands() -> [String] {
            server.recordedCommands().filter(Self.isMutating)
        }

        /// The commands that change a mailbox, sent while `mailbox` was selected.
        func mutatingCommands(in mailbox: String) -> [String] {
            server.recordedCommandsWithMailbox().filter { $0.mailbox == mailbox }.map(\.command).filter(Self.isMutating)
        }

        static func isMutating(_ command: String) -> Bool {
            let upper = command.uppercased()
            return ["STORE ", "EXPUNGE", "COPY ", "MOVE ", "APPEND "].contains { upper.contains($0) }
        }

        func account() throws -> Account {
            let accountId = accountId
            let found = try pool.read { db in try Account.fetchOne(db, key: accountId) }
            return try #require(found)
        }

        func folder(_ id: String) throws -> Folder {
            let found = try pool.read { db in try Folder.fetchOne(db, key: id) }
            return try #require(found)
        }

        func row(uid: Int, in folderId: String) throws -> MessageHeader {
            let found = try pool.read { db in
                try MessageHeader.filter(Column("folderId") == folderId && Column("messageId") == "\(uid)").fetchOne(db)
            }
            return try #require(found)
        }

        /// The folder's local rows: UID to (read, flagged).
        func local() throws -> [Int: (isRead: Bool, isFlagged: Bool)] {
            let folderId = folderId
            let rows = try pool.read { db in
                try Row.fetchAll(db, sql: "SELECT messageId, isRead, isFlagged FROM messageHeader WHERE folderId = ?", arguments: [folderId])
            }
            var out: [Int: (isRead: Bool, isFlagged: Bool)] = [:]
            for row in rows {
                let messageId: String = row["messageId"]
                let isRead: Bool = row["isRead"]
                let isFlagged: Bool = row["isFlagged"]
                guard let uid = Int(messageId) else { continue }
                out[uid] = (isRead, isFlagged)
            }
            return out
        }

        func serverHeld() -> [Int] { server.messages(in: FollowedFolderIMAPTests.path).map(\.uid).sorted() }

        /// UIDs held locally whose read or flag state differs from the server's.
        func wrongFlags() throws -> [Int] {
            try local().filter { uid, row in
                let flags = server.flags(in: FollowedFolderIMAPTests.path, uid: uid)
                return row.isRead != flags.contains("\\Seen") || row.isFlagged != flags.contains("\\Flagged")
            }.keys.sorted()
        }

        func isReconciled() throws -> Bool {
            let held = try local().keys.sorted()
            let wrong = try wrongFlags()
            return held == serverHeld() && wrong.isEmpty
        }

        /// The property: the device holds exactly the messages the server holds
        /// in the folder, each once, with the server's read and flag state.
        func expectReconciled(_ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let held = try local().keys.sorted()
            let onServer = serverHeld()
            let missing = Set(onServer).subtracting(held).sorted()
            let extra = Set(held).subtracting(onServer).sorted()
            let wrong = try wrongFlags()
            #expect(missing.isEmpty, "\(label): messages the server holds are missing: \(missing)", sourceLocation: sourceLocation)
            #expect(extra.isEmpty, "\(label): rows the server no longer holds: \(extra)", sourceLocation: sourceLocation)
            #expect(wrong.isEmpty, "\(label): rows whose read or flag state is not the server's: \(wrong)", sourceLocation: sourceLocation)
            #expect(server.wrongMessageViolations().isEmpty, sourceLocation: sourceLocation)
        }

        /// The same property against the scenario itself (`changeBelowTheNewest`),
        /// not the server's current state: exactly the messages the other client
        /// left (plus the UIDs `plus` that an action moved in, less the UIDs
        /// `minus` it moved out), one row each, with the read and flag state the
        /// other client set, on the device and still on the server; and the only
        /// changes sent to the server are the action's own: its `UID MOVE`
        /// (`move`: the UID it moved, from the mailbox it was in), preceded for a
        /// move out of the Inbox by the legacy `tm_*` keyword removal on that UID;
        /// or none for an open.
        func expectScenarioReconciled(
            _ label: String, plus: [Int] = [], minus: [Int] = [], move: (uid: Int, from: String)? = nil,
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws {
            let t = FollowedFolderIMAPTests.self
            let expected = Set(t.serverUIDs).subtracting(t.deleted).subtracting(t.movedAway)
                .subtracting(minus).union(plus).sorted()
            let held = try local()
            let heldUIDs = held.keys.sorted()
            let folderId = folderId
            let rowCount = try pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE folderId = ?", arguments: [folderId]) ?? 0
            }
            #expect(heldUIDs == expected, "\(label): the device holds what the other client left", sourceLocation: sourceLocation)
            #expect(rowCount == expected.count, "\(label): one row per message, \(rowCount) rows", sourceLocation: sourceLocation)
            #expect(serverHeld() == expected, "\(label): the server still holds what the other client left", sourceLocation: sourceLocation)
            for uid in t.readElsewhere {
                let isRead = held[uid]?.isRead
                let seen = server.flags(in: t.path, uid: uid).contains("\\Seen")
                #expect(isRead == true && seen, "\(label): \(uid), read elsewhere, is read here and there", sourceLocation: sourceLocation)
            }
            for uid in t.flaggedElsewhere {
                let isFlagged = held[uid]?.isFlagged
                let flagged = server.flags(in: t.path, uid: uid).contains("\\Flagged")
                #expect(isFlagged == true && flagged, "\(label): \(uid), flagged elsewhere, is flagged here and there", sourceLocation: sourceLocation)
            }
            let changes = server.recordedCommandsWithMailbox().filter { Self.isMutating($0.command) }
            let sent = changes.map(\.command)
            if let move {
                // The action's own changes, all on the moved message in the
                // mailbox it was in: its one `UID MOVE`, and, for a move out of
                // the Inbox, the removal of the legacy `tm_*` keywords that the
                // provider's move sends first.
                let prefix = "UID MOVE \(move.uid) "
                let legacyStrip = "UID STORE \(move.uid) -FLAGS (TM_REPLY TM_ARCHIVE TM_DELETE TM_NONE)"
                let moves = changes.filter { $0.command.uppercased().hasPrefix(prefix) }
                let ownChanges = changes.allSatisfy { change in
                    let upper = change.command.uppercased()
                    let isStrip = move.from.uppercased() == "INBOX" && upper == legacyStrip
                    return change.mailbox == move.from && (upper.hasPrefix(prefix) || isStrip)
                }
                let onlyTheMove = moves.count == 1 && ownChanges
                #expect(onlyTheMove, "\(label): the action's move is the only change sent to the server: \(sent)", sourceLocation: sourceLocation)
            } else {
                #expect(sent.isEmpty, "\(label): an open changes nothing on the server: \(sent)", sourceLocation: sourceLocation)
            }
        }

        /// The device's rows for the message `rfc` in the folder `folderId`,
        /// compared as the app compares Message-IDs (`EmailFilter.normalizeMessageId`):
        /// a row this world inserted holds the bracketed form, and a row a listing
        /// wrote holds the bare form the app stores.
        func rows(rfc822MessageId rfc: String, in folderId: String) throws -> Int {
            let stored = try pool.read { db in
                try String.fetchAll(db, sql: "SELECT rfc822MessageId FROM messageHeader WHERE folderId = ? AND rfc822MessageId IS NOT NULL",
                                    arguments: [folderId])
            }
            let wanted = EmailFilter.normalizeMessageId(rfc)
            return stored.filter { EmailFilter.normalizeMessageId($0) == wanted }.count
        }

        func expectFollowed(_ folderIds: [String], _ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            for id in folderIds {
                let followed = try folder(id).isFollowed
                #expect(followed, "\(label): \(id) is followed", sourceLocation: sourceLocation)
            }
        }

        /// Another client removes `uids` from the folder.
        func deleteElsewhere(_ uids: [Int]) {
            let path = FollowedFolderIMAPTests.path
            server.setMessages(server.messages(in: path).filter { !uids.contains($0.uid) }, in: path)
        }

        /// Another client moves `uids` to the Inbox, where each gets a new UID.
        func moveAwayElsewhere(_ uids: [Int]) {
            deleteElsewhere(uids)
            var inbox = server.messages(in: "INBOX")
            for uid in uids {
                let next = (inbox.map(\.uid).max() ?? 0) + 1
                inbox.append(FollowedFolderIMAPTests.message(next, id: "followed-\(uid)"))
            }
            server.setMessages(inbox, in: "INBOX")
        }

        /// Another client sets `flag` on `uids` in the folder.
        func flagElsewhere(_ flag: String, _ uids: [Int]) {
            let path = FollowedFolderIMAPTests.path
            for uid in uids { server.setFlags(server.flags(in: path, uid: uid).union([flag]), in: path, uid: uid) }
        }

        /// The changes made elsewhere while the folder was not followed, all
        /// below the newest 50.
        func changeBelowTheNewest() {
            deleteElsewhere(FollowedFolderIMAPTests.deleted)
            moveAwayElsewhere(FollowedFolderIMAPTests.movedAway)
            flagElsewhere("\\Seen", FollowedFolderIMAPTests.readElsewhere)
            flagElsewhere("\\Flagged", FollowedFolderIMAPTests.flaggedElsewhere)
        }

        /// The access run the last user action started has ended.
        func settle() async {
            await AccountManager.shared.syncEngine.awaitAccessCatchUpForTesting(accountId: accountId)
        }

        /// The user opens (or pulls to refresh) the folder, as the folder view
        /// does (`InboxViewModel` → `AccountManager.syncFolders`).
        func open() async throws {
            let opened = try folder(folderId)
            let account = try account()
            try await AccountManager.shared.syncFolders([opened], connecting: [account])
            await settle()
        }

        @MainActor
        func drain() async throws {
            for _ in 0..<300 {
                let empty = try await pool.read { db in try PendingOperation.fetchCount(db) == 0 }
                let quiet = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
                if empty && quiet { return }
                if quiet && !empty { await AccountManager.shared.drainPendingQueue() }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// The server holds `serverUIDs` in the custom folder and one message in
    /// the Inbox; the device holds all of them but `neverLoaded`, each the
    /// server's message at its UID, the older-mail walk complete. The folder is
    /// neither a favourite nor followed. The account is connected as
    /// `connectAccount` connects it, so the user's actions run through
    /// `AccountManager.shared` and its engine.
    @MainActor
    static func withWorld(_ name: String, _ kind: Server, _ body: (World) async throws -> Void) async throws {
        let mailboxes: [String: [FakeIMAPServer.Message]] = [
            "INBOX": [message(inboxUID, id: inboxMessage)],
            path: serverUIDs.map { message($0) },
            archivePath: [],
            trashPath: [],
        ]
        let server = FakeIMAPServer(capabilities: kind.capabilities, mailboxes: mailboxes)
        for mailbox in mailboxes.keys { server.setUidValidity(epoch, for: mailbox) }
        server.honorSearchDateCriteria()
        try server.start()
        defer { server.stop() }

        let accountId = "followed-\(name)-\(kind.rawValue)"
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
                                                totalCount: 1, lastKnownUidNext: inboxUID + 1, lastKnownUidValidity: epoch)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: path, role: .custom, pool: pool,
                                                totalCount: serverUIDs.count, lastKnownUidNext: serverUIDs.count + 1,
                                                lastKnownUidValidity: epoch)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: archivePath, role: .archive, pool: pool,
                                                lastKnownUidNext: 1, lastKnownUidValidity: epoch)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: trashPath, role: .trash, pool: pool,
                                                lastKnownUidNext: 1, lastKnownUidValidity: epoch)
        try FolderEpochTestFixture.insertHeaders(accountId: accountId, path: "INBOX", uids: [inboxUID], pool: pool)
        try FolderEpochTestFixture.insertHeaders(accountId: accountId, path: path, uids: serverUIDs.filter { $0 != neverLoaded }, pool: pool)
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE messageHeader SET rfc822MessageId = '<followed-' || messageId || '@example.com>', observedUidValidity = ?
                WHERE folderId = ?
                """, arguments: [epoch, "\(accountId):\(path)"])
            try db.execute(sql: "UPDATE messageHeader SET rfc822MessageId = ?, observedUidValidity = ?, isInInbox = 1 WHERE folderId = ?",
                           arguments: ["<\(inboxMessage)@example.com>", epoch, "\(accountId):INBOX"])
            try db.execute(sql: "UPDATE folder SET backfillComplete = 1 WHERE accountId = ?", arguments: [accountId])
            try db.execute(sql: "UPDATE account SET lastFullSyncAt = ? WHERE id = ?", arguments: [Date(), accountId])
        }

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        await AccountManager.shared.connectProviderForTesting(account: account, provider: provider)
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        // The body queue is process-wide: start from an empty one, and hold this
        // world's downloads (the loaded message's body) until its items are dropped.
        await BackfillBodyQueue.shared.emptyForTesting()
        await BackfillBodyQueue.shared.setDispatchSuppressedForTesting(true)
        let world = World(server: server, provider: provider, pool: pool, accountId: accountId)
        await world.watchSlices()
        func teardown() async {
            await AccountManager.shared.syncEngine.setCatchUpSliceStartHookForTesting(nil)
            await AccountManager.shared.syncEngine.setAccessCatchUpClockForTesting(nil)
            await AccountManager.shared.disconnectProviderForTesting(accountId: accountId)
            await BackfillBodyQueue.shared.emptyForTesting()
            await BackfillBodyQueue.shared.setDispatchSuppressedForTesting(false)
            try? await provider.disconnect()
        }
        do {
            let initial = try world.folder(world.folderId)
            let syncable = SyncEngine.isSyncable(initial)
            #expect(!initial.isFollowed, "\(name): setup: the folder is not followed")
            #expect(!syncable, "\(name): setup: the folder is not in the syncable set")
            try await body(world)
        } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    @Test("Opening a folder that is not followed reconciles all of it, and every later open keeps it current",
          arguments: Server.allCases)
    @MainActor
    func openingTheFolderReconcilesIt(server: Server) async throws {
        try await Self.withWorld("open", server) { w in
            w.changeBelowTheNewest()
            let behind = try !w.isReconciled()
            #expect(behind, "setup: the device is behind the server below the newest 50")

            try await w.open()
            try w.expectFollowed([w.folderId], "open")
            try w.expectReconciled("open")
            try w.expectScenarioReconciled("open")
            let firstSlices = w.recorder.all.map(\.folderIds)
            let openedId = w.folderId
            let onlyOpened = firstSlices.allSatisfy { $0 == [openedId] }
            #expect(!firstSlices.isEmpty, "the open started an access run")
            #expect(onlyOpened, "the access run asks the opened folder alone: \(firstSlices)")

            // Later changes elsewhere, below the newest 50.
            w.deleteElsewhere([25])
            w.flagElsewhere("\\Seen", [35])
            try await w.open()
            try w.expectReconciled("second open")

            // Nothing changed: the access run sends the folder no listing request.
            w.recorder.reset()
            try await w.open()
            let quietSlices = w.recorder.all
            #expect(!quietSlices.isEmpty, "the quiet open started an access run too")
            guard let quietStart = quietSlices.first?.commandsBefore else { return }
            let listed = w.folderListingCommands(since: quietStart)
            #expect(listed.isEmpty, "an open with nothing changed lists nothing: \(listed)")
            try w.expectReconciled("third open")
        }
    }

    @Test("Accesses that come while the account's access run is going are taken together by its next run; no second run starts beside it")
    @MainActor
    func aSecondAccessDuringARunIsTakenByTheNext() async throws {
        try await Self.withWorld("second-access", .plain) { w in
            let engine = await AccountManager.shared.syncEngine
            let accountId = w.accountId
            let folderId = w.folderId
            let inboxId = w.inboxId
            let handedOver = HeldWorkFlag()
            await w.watchSlices { folderIds in
                // While the open's run is in its first slice, two more accesses
                // come: a drained action lands in the Inbox, then the folder is
                // opened again.
                guard folderIds == [folderId], !handedOver.set() else { return }
                await engine.startAccessCatchUp(accountId: accountId, folderIds: [inboxId])
                // A pause between the two: a second run started beside the one
                // going would take the Inbox alone meanwhile.
                try? await Task.sleep(for: Self.handoverGap)
                await engine.startAccessCatchUp(accountId: accountId, folderIds: [folderId])
            }
            try await w.open()

            let asked = w.recorder.all.map(\.folderIds)
            let both: Set<String> = [folderId, inboxId]
            let tookBoth = asked.contains { Set($0) == both }
            #expect(handedOver.isSet, "setup: two accesses were handed over during the run")
            #expect(asked.first == [folderId], "the open's run asked the opened folder: \(asked)")
            #expect(tookBoth, "the next run took both accesses together: \(asked)")
            #expect(!asked.contains([inboxId]), "no run asked the Inbox alone beside the one going: \(asked)")
        }
    }

    /// Time a test adds to a clock it installed, read from any context.
    final class ClockOffset: Sendable {
        private let seconds = Mutex<TimeInterval>(0)
        func add(_ value: TimeInterval) { seconds.withLock { $0 += value } }
        func now() -> Date { Date().addingTimeInterval(seconds.withLock { $0 }) }
    }

    /// A pull whose change read finds the account busy (a pass that queued
    /// behind the folder's listing takes the turn when the listing ends) still
    /// starts the folder's access run. The pull returns while that pass holds
    /// the turn; the run waits for the turn and asks nothing meanwhile; once
    /// the pass ends it reconciles all of the folder, however long it waited:
    /// its time is its slices' time inside the turn, and the access run's
    /// clock moves on twice that time while it waits. RED while a busy pull
    /// started no access run, and while the run's time ran from when it took
    /// its folders.
    @Test("A pull that finds its account busy still reconciles the folder after the running pass, with all of its run's time")
    @MainActor
    func aBusyPullReconcilesTheFolderAfterTheRunningPass() async throws {
        // The app's scheduler takes the follow-up asks (the busy read's, and the
        // release of each slice while the flag is set) and starts nothing: this
        // test is about the access run. It is restored only after the world's
        // teardown has taken the account out of the engine, so an ask still on
        // its way to the main actor then finds no account.
        let scheduler = SyncScheduler.shared
        let saved = (scheduler.applicationStateForTesting, scheduler.foregroundReadinessHook, scheduler.stageTwoHook)
        scheduler.applicationStateForTesting = .active
        scheduler.foregroundReadinessHook = { true }
        scheduler.stageTwoHook = { _ in }
        defer {
            scheduler.applicationStateForTesting = saved.0
            scheduler.foregroundReadinessHook = saved.1
            scheduler.stageTwoHook = saved.2
        }
        try await Self.withWorld("busy-pull", .plain) { w in
            w.changeBelowTheNewest()
            let engine = await AccountManager.shared.syncEngine
            let accountId = w.accountId
            let offset = ClockOffset()
            await engine.setAccessCatchUpClockForTesting { offset.now() }
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            let opened = try w.folder(w.folderId)
            let account = try w.account()
            var pull: Task<Bool, Error>?
            var holder: Task<Void, Never>?
            // A precondition that fails ends the test here: the held listing and
            // the held pass are let go, and both tasks are waited for.
            func stop(_ reason: Comment) async {
                Issue.record(reason)
                w.server.releaseFetchAfterSnapshot(in: Self.path)
                release.continuation.finish()
                await holder?.value
                _ = await pull?.result
            }

            // The pull's listing of the folder is held at the server, inside its turn.
            w.server.holdNextFetchAfterSnapshot(in: Self.path)
            pull = Task { try await AccountManager.shared.syncFolders([opened], connecting: [account]) }
            guard await OneSyncAtATimeTests.eventually({ w.server.isHoldingFetchAfterSnapshot(in: Self.path) }) else {
                return await stop("precondition: the pull's listing is held at the server")
            }

            // A pass arrives meanwhile: it takes the turn when the listing ends.
            holder = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "held", log: log, release: release.stream)
            guard await OneSyncAtATimeTests.eventually({ await engine.syncPassWaiters[accountId]?.count == 1 }) else {
                return await stop("precondition: the pass waits behind the listing")
            }
            w.server.releaseFetchAfterSnapshot(in: Self.path)
            guard case .success(true) = await pull?.result else {
                return await stop("precondition: the pull returned, its change read having found the account busy")
            }
            guard await OneSyncAtATimeTests.eventually({ log.snapshot == ["start held"] }) else {
                return await stop("precondition: the pass took the turn when the listing ended, and holds it")
            }

            // The pull's access run waits for the turn behind the pass, and its
            // clock moves on twice the run's time meanwhile.
            guard await OneSyncAtATimeTests.eventually({ await engine.syncPassWaiters[accountId]?.count == 1 }) else {
                return await stop("the busy pull started the folder's access run, which waits for the turn")
            }
            offset.add(2 * SyncConfig.accessCatchUpRunSeconds)
            let slicesWhileHeld = w.recorder.all.count
            #expect(slicesWhileHeld == 0, "no slice ran while the pass held the turn")

            release.continuation.yield()
            await holder?.value
            await w.settle()
            try w.expectFollowed([w.folderId], "busy pull")
            try w.expectReconciled("busy pull")
            try w.expectScenarioReconciled("busy pull")
            let asked = w.recorder.all.map(\.folderIds)
            let openedId = w.folderId
            let onlyOpened = !asked.isEmpty && asked.allSatisfy { $0 == [openedId] }
            #expect(onlyOpened, "the access run asked the opened folder alone, after the pass: \(asked)")
        }
    }

    @Test("Opening a folder while its account cannot connect still follows it")
    @MainActor
    func openingAFolderOfflineFollowsIt() async throws {
        try await Self.withWorld("offline-open", .plain) { w in
            // The account is not connected, and connecting it fails (this fixture
            // account has no server settings), as on a device that is offline.
            await AccountManager.shared.disconnectProviderForTesting(accountId: w.accountId)
            let opened = try w.folder(w.folderId)
            let account = try w.account()
            var failed = false
            do {
                try await AccountManager.shared.syncFolders([opened], connecting: [account])
            } catch {
                failed = true
            }
            #expect(failed, "setup: the account could not connect")
            try w.expectFollowed([w.folderId], "open while offline")
        }
    }

    /// Following a folder that is already followed never waits for the
    /// database's one writer: `followFolders` reads first and opens a write
    /// only for a folder not followed yet, so a pull of a followed folder
    /// (`AccountManager.syncFolders` follows its folders before its first read)
    /// is not held behind a write in flight. RED with a write opened every time.
    @Test("Following a folder that is already followed returns while another write holds the database's writer")
    @MainActor
    func followingAFollowedFolderNeverWaitsForTheWriter() async throws {
        try await Self.withWorld("follow-read-first", .plain) { w in
            let engine = await AccountManager.shared.syncEngine
            let folderId = w.folderId
            await engine.followFolders([folderId])
            try w.expectFollowed([folderId], "precondition: the first access follows the folder")
            // Another write holds the writer on a thread of its own until let go
            // (at most 10 s, so a failing run still ends).
            let pool = w.pool
            let writerHeld = Mutex(false)
            let writerEnded = Mutex(false)
            let letGo = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                try? pool.write { _ in
                    writerHeld.withLock { $0 = true }
                    _ = letGo.wait(timeout: .now() + .seconds(10))
                }
                writerEnded.withLock { $0 = true }
            }
            let held = await OneSyncAtATimeTests.eventually(seconds: 5) { writerHeld.withLock { $0 } }
            let followed = Mutex(false)
            let follow = Task {
                await engine.followFolders([folderId])
                followed.withLock { $0 = true }
            }
            let returnedWhileHeld = await OneSyncAtATimeTests.eventually(seconds: 2) { followed.withLock { $0 } }
            let stillHeld = !writerEnded.withLock { $0 }
            letGo.signal()
            await follow.value
            let ended = await OneSyncAtATimeTests.eventually(seconds: 5) { writerEnded.withLock { $0 } }

            #expect(held, "precondition: another write holds the database's writer")
            #expect(returnedWhileHeld && stillHeld, "following a followed folder did not wait for the writer")
            #expect(ended, "the held write ended once let go")
            try w.expectFollowed([folderId], "the folder stays followed")
        }
    }

    @Test("A listing that spans runs records the counters it started from, so a change made during it is listed at the next access")
    @MainActor
    func completionKeepsTheCountersItsListingStartedFrom() async throws {
        try await Self.withWorld("counters", .plain) { w in
            w.changeBelowTheNewest()
            let engine = SyncEngine()
            let folderId = w.folderId
            let start = try w.folder(folderId)
            let first = IMAPCatchUpState.Counters(exists: start.totalCount, uidNext: start.lastKnownUidNext)
            func access(maxRequests: Int) async {
                var context = CatchUpContext(deadline: .distantFuture, clock: { Date() })
                context.maxRequests = maxRequests
                context.accessedFolderIds = [folderId]
                await engine.runCatchUp(provider: w.provider, folderIds: [folderId], context: context)
            }
            func state() throws -> IMAPCatchUpState? {
                IMAPCatchUpState.decode(try w.folder(folderId).catchUpState)
            }
            func fetches() -> Int {
                w.server.recordedCommands().filter { $0.uppercased().hasPrefix("UID FETCH") }.count
            }

            // One request: the listing starts from the stored counters and does not finish.
            await access(maxRequests: 1)
            let begun = try state()
            #expect(begun?.listing?.firstCounters == first, "precondition: the listing is under way, from the stored counters")
            // Meanwhile a window listing stores new counters: a message went elsewhere.
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET totalCount = totalCount - 1 WHERE id = ?", arguments: [folderId])
            }
            await access(maxRequests: .max)
            let completed = try state()
            #expect(completed?.listing == nil, "precondition: the listing completed")
            #expect(completed?.completionCounters == first, "the completion records the counters its listing started from")

            let before = fetches()
            await access(maxRequests: .max)
            let after = fetches()
            #expect(after > before, "the next access lists the folder again: its counters moved during the listing")
        }
    }

    @Test("A move into a folder that is not followed reconciles all of it, and follows both folders",
          arguments: Server.allCases)
    @MainActor
    func movingIntoTheFolderReconcilesIt(server: Server) async throws {
        try await Self.withWorld("move-in", server) { w in
            w.changeBelowTheNewest()
            let moving = try w.row(uid: Self.inboxUID, in: w.inboxId)
            w.server.expectMutation(rfc822MessageId: "<\(Self.inboxMessage)@example.com>")

            await AccountManager.shared.move([moving], to: Self.path)
            try await w.drain()
            await w.settle()

            let rfc = "<\(Self.inboxMessage)@example.com>"
            let landed = w.server.uids(in: Self.path, rfc822MessageId: rfc)
            let leftInInbox = w.server.uids(in: "INBOX", rfc822MessageId: rfc)
            #expect(landed.count == 1, "setup: the move landed on the server: \(landed)")
            #expect(leftInInbox.isEmpty, "setup: the move left nothing in the server's Inbox: \(leftInInbox)")
            let localInbox = try w.rows(rfc822MessageId: rfc, in: w.inboxId)
            #expect(localInbox == 0, "the moved message has left the device's Inbox")
            try w.expectFollowed([w.folderId, w.inboxId], "move in")
            try w.expectReconciled("move in")

            // Against the scenario itself, not the server's current state: the
            // folder holds what the other client left plus the moved message,
            // which kept its state (unread, not flagged) on both sides, and the
            // move, sent from the Inbox, is the only change sent to the server.
            try w.expectScenarioReconciled("move in", plus: landed, move: (uid: Self.inboxUID, from: "INBOX"))
            if let landedUID = landed.first {
                let landedFlags = w.server.flags(in: Self.path, uid: landedUID)
                let landedRow = try w.local()[landedUID]
                #expect(!landedFlags.contains("\\Seen") && !landedFlags.contains("\\Flagged"),
                        "move in: the moved message kept its state on the server: \(landedFlags)")
                #expect(landedRow?.isRead == false && landedRow?.isFlagged == false,
                        "move in: and on the device")
            }
        }
    }

    @Test("A move, archive or delete out of a folder that is not followed reconciles the rest of it, and follows it and the destination",
          arguments: Server.allCases, Action.allCases)
    @MainActor
    func takingAMessageOutReconcilesTheFolder(server: Server, action: Action) async throws {
        try await Self.withWorld("out-\(action.rawValue)", server) { w in
            w.changeBelowTheNewest()
            // One of the folder's newest messages, which its own listing covers.
            let movedUID = 100
            let moving = try w.row(uid: movedUID, in: w.folderId)
            let rfc = "<followed-\(movedUID)@example.com>"
            let label = "\(action.rawValue) out"
            w.server.expectMutation(rfc822MessageId: rfc)

            await action.perform(moving)
            try await w.drain()
            await w.settle()

            let destinationId = w.idOfFolder(action.destination)
            let landed = w.server.uids(in: action.destination, rfc822MessageId: rfc)
            #expect(landed.count == 1, "\(label): setup: the message landed on the server: \(landed)")
            let inDestination = try w.rows(rfc822MessageId: rfc, in: destinationId)
            let inFolder = try w.rows(rfc822MessageId: rfc, in: w.folderId)
            #expect(inDestination == 1, "\(label): the device holds it in the destination, once: \(inDestination)")
            #expect(inFolder == 0, "\(label): and no longer in the folder: \(inFolder)")
            try w.expectFollowed([w.folderId, destinationId], label)
            try w.expectReconciled(label)
            try w.expectScenarioReconciled(label, minus: [movedUID], move: (uid: movedUID, from: Self.path))
        }
    }

    @Test("Opening one of a folder's messages from a search result reconciles all of the folder",
          arguments: Server.allCases)
    @MainActor
    func openingOneOfItsMessagesReconcilesIt(server: Server) async throws {
        try await Self.withWorld("message-open", server) { w in
            w.changeBelowTheNewest()
            // A search result opens the message by its header id, as any open does.
            // Its body is not stored, so the open requests it; that request waits
            // long enough for an access run started with the open to reach its
            // first slice, and notes whether one did.
            let opened = try w.row(uid: 100, in: w.folderId)
            let recorder = w.recorder
            let bodyRequested = HeldWorkFlag()
            let sliceBeforeBody = HeldWorkFlag()
            let detail = MessageDetailViewModel(messageId: opened.id, dbPool: w.pool, fetchBodyOverride: { _ in
                _ = bodyRequested.set()
                for _ in 0..<Self.bodyRequestPolls where recorder.all.isEmpty {
                    try await Task.sleep(for: .milliseconds(50))
                }
                if !recorder.all.isEmpty { _ = sliceBeforeBody.set() }
            }, accessesFolder: true)
            await detail.loadBody()
            #expect(detail.message?.id == opened.id, "setup: the message opened")
            #expect(bodyRequested.isSet, "setup: the open requested the message's body")
            #expect(!sliceBeforeBody.isSet, "the folder's catch-up starts only after the message's body request")

            // The open starts the folder's access run on its own task.
            for _ in 0..<Self.openPolls {
                await w.settle()
                if try w.folder(w.folderId).isFollowed, try w.isReconciled() { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try w.expectFollowed([w.folderId], "message open")
            try w.expectReconciled("message open")
            try w.expectScenarioReconciled("message open")
        }
    }
}

// MARK: - Outlook

/// Outlook keeps its own gate: the catch-up lists a folder only once the change
/// reader has baselined it. A custom folder that becomes followed is read by the
/// change reader (it is synced now) and then listed by the catch-up, through
/// the engine's own run, which asks only syncable folders.
@Suite("Followed folders on Outlook (#1109)", .serialized, .processGlobalState)
struct FollowedFolderOutlookTests {
    typealias R = OutlookChangeReadingTests
    typealias C = OutlookCatchUpTests

    static let projects = "fld-projects"
    /// Bounded reads and catch-up runs.
    static let passes = 20

    /// Engine catch-up runs (one slice each, no pacing gap) until `path`'s
    /// listing has completed, or `passes` runs.
    static func catchUpUntilListed(_ w: R.World, _ engine: SyncEngine, _ path: String) async throws {
        for _ in 0..<passes {
            try await catchUpOnce(w, engine)
            let state = ExchangeCatchUpState.decode(try w.folder(path).catchUpState)
            if state?.lastCompletedAt != nil, state?.listing == nil { return }
        }
    }

    /// One engine catch-up run, one slice, no pacing gap.
    static func catchUpOnce(_ w: R.World, _ engine: SyncEngine) async throws {
        let account = try w.account()
        let run = SyncEngine.CatchUpRun(
            storageLimitInForce: false, deadline: nil, sliceSeconds: SyncConfig.catchUpSliceSeconds,
            intervalSeconds: 0, clock: { Date() })
        _ = await engine.runCatchUpRun(account: account, run: run)
    }

    /// The engine's own change read (`readAndApplyChanges`, the request the
    /// full sync builds), pass by pass, until `path` is tracked, or `passes` passes.
    static func readUntilTracking(_ w: R.World, _ engine: SyncEngine, _ path: String) async throws {
        for _ in 0..<passes {
            let account = try w.account()
            let request = try await engine.makeChangeRequest(accountId: account.id, scope: .all, deadline: nil)
            _ = try await engine.readAndApplyChanges(account: account, provider: w.provider, request: request)
            if try w.cursor(path)?.phase == .tracking { return }
        }
    }

    @Test("Outlook: a custom folder that becomes followed is baselined by the change read and listed by the catch-up, which removes a message deleted on the web before; until then neither touched it")
    func followedCustomFolderIsReadAndListed() async throws {
        let c = C.Clock()
        try await C.withWorld(seeds: [
            C.seed("p-keep", in: Self.projects, at: c.daysAgo(5)),
            C.seed("p-read", in: Self.projects, at: c.daysAgo(6)),
        ]) { w, engine in
            w.server.addFolder(id: Self.projects, name: "Projects")
            var custom = Folder(name: "Projects", path: Self.projects, role: .custom, accountId: w.accountId)
            custom.oldestSyncedDate = R.daysAgo(30)
            let toInsert = custom
            let customId = toInsert.id
            try await w.pool.write { db in try toInsert.insert(db) }
            try C.setWalkComplete(w, Self.projects, true)
            for (id, days) in [("p-keep", 5.0), ("p-gone", 5.5), ("p-read", 6)] {
                try w.insertRow(id, in: Self.projects, date: c.daysAgo(days))
            }
            try await w.baselineAll()
            try await Self.catchUpUntilListed(w, engine, w.archive)
            #expect(try w.cursor(Self.projects) == nil, "precondition: no change read of a folder that is not followed")
            // A folder outside the syncable set is the catch-up's too (#1110), but Outlook's
            // tracking gate holds it: no listing starts before its change read's baseline, and
            // nothing is sent for it.
            let unlisted = ExchangeCatchUpState.decode(try w.folder(Self.projects).catchUpState)
            let sentForIt = w.server.requestCount(containing: Self.projects)
            #expect(unlisted?.listing == nil && unlisted?.lastCompletedAt == nil, "precondition: no catch-up listing of it either")
            #expect(sentForIt == 0, "precondition: nothing was sent for it")
            #expect(try w.rowIds(in: Self.projects) == ["p-keep", "p-gone", "p-read"])

            let marked = try await w.pool.write { db in try SyncEngine.markFollowed(folderIds: [customId], db: db) }
            #expect(marked == [customId], "setup: the folder is followed now")
            // Followed, but the change read has not baselined it: the catch-up does not list it yet.
            let projectsRequestsBefore = w.server.requestCount(containing: Self.projects)
            try await Self.catchUpOnce(w, engine)
            let projectsRequestsGated = w.server.requestCount(containing: Self.projects) - projectsRequestsBefore
            let gated = ExchangeCatchUpState.decode(try w.folder(Self.projects).catchUpState)
            #expect(projectsRequestsGated == 0, "the catch-up sends nothing for a followed folder before its baseline")
            #expect(gated?.listing == nil && gated?.lastCompletedAt == nil,
                    "the catch-up does not list a followed folder before its baseline")
            #expect(try w.rowIds(in: Self.projects) == ["p-keep", "p-gone", "p-read"], "nor remove anything from it")
            try await Self.readUntilTracking(w, engine, Self.projects)
            #expect(try w.cursor(Self.projects)?.phase == .tracking, "the change read baselined the followed folder")
            #expect(try w.rowIds(in: Self.projects) == ["p-keep", "p-gone", "p-read"], "a baseline removes nothing")

            try await Self.catchUpUntilListed(w, engine, Self.projects)
            #expect(try w.rowIds(in: Self.projects) == ["p-keep", "p-read"], "the catch-up's listing removed the message deleted on the web")

            // From now on the change read keeps the folder current.
            w.server.setReadFromOtherClient(providerMessageId: "p-read", isRead: true)
            w.server.deleteFromOtherClient(providerMessageId: "p-keep")
            try await w.read()
            #expect(try w.row("p-read", in: Self.projects)?.isRead == true, "a read change elsewhere shows")
            #expect(try w.rowIds(in: Self.projects) == ["p-read"], "a delete elsewhere shows")
        }
    }
}
