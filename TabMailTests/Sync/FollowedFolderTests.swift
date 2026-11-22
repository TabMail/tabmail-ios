/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
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

    @Test("IMAP with no mod-sequences: an access lists an untracked folder when its counters moved since its last completed listing started, or that listing is older than the access age; nothing else does")
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
        // A message removed elsewhere moves EXISTS; one arriving moves UIDNEXT.
        #expect(P.catchUpPlan(state: state(recent, counters), freshModSeq: nil, now: now, counters: fewer, accessed: true) == list(fewer))
        #expect(P.catchUpPlan(state: state(recent, counters), freshModSeq: nil, now: now, counters: arrived, accessed: true) == list(arrived))
        // A flag change moves no counter: past the access age the folder is listed anyway.
        #expect(P.catchUpPlan(state: state(old, counters), freshModSeq: nil, now: now, counters: counters, accessed: true) == list(counters))
        // A listing completed with no counters recorded is listed at the first access.
        #expect(P.catchUpPlan(state: state(recent, nil), freshModSeq: nil, now: now, counters: counters, accessed: true) == list(counters))
        // With mod-sequences the MODSEQ check decides: unchanged lists nothing, whatever the counters.
        #expect(P.catchUpPlan(state: state(recent, counters, stamp: 9), freshModSeq: 9, now: now, counters: fewer, accessed: true) == .none)
        // A tracked folder's changes come through its change read.
        #expect(P.catchUpPlan(state: state(recent, counters), freshModSeq: nil, now: now, isTracked: true, counters: fewer, accessed: true) == .none)
        // A first listing records the counters it starts from.
        #expect(P.catchUpPlan(state: nil, freshModSeq: nil, now: now, counters: counters) == list(counters))
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

    struct World {
        let server: FakeIMAPServer
        let pool: DatabasePool
        let accountId: String
        var folderId: String { "\(accountId):\(FollowedFolderIMAPTests.path)" }
        var inboxId: String { "\(accountId):INBOX" }

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
        let world = World(server: server, pool: pool, accountId: accountId)
        func teardown() async {
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

            // Later changes elsewhere, below the newest 50.
            w.deleteElsewhere([25])
            w.flagElsewhere("\\Seen", [35])
            try await w.open()
            try w.expectReconciled("second open")

            // Nothing changed: the access lists nothing again.
            let state = try w.folder(w.folderId).catchUpState
            try await w.open()
            let stateAfter = try w.folder(w.folderId).catchUpState
            #expect(stateAfter == state, "an open with nothing changed lists nothing")
            try w.expectReconciled("third open")
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

            let landed = w.server.uids(in: Self.path, rfc822MessageId: "<\(Self.inboxMessage)@example.com>")
            #expect(landed.count == 1, "setup: the move landed on the server: \(landed)")
            try w.expectFollowed([w.folderId, w.inboxId], "move in")
            try w.expectReconciled("move in")
        }
    }

    @Test("Opening one of a folder's messages from a search result reconciles all of the folder",
          arguments: Server.allCases)
    @MainActor
    func openingOneOfItsMessagesReconcilesIt(server: Server) async throws {
        try await Self.withWorld("message-open", server) { w in
            w.changeBelowTheNewest()
            // A search result opens the message by its header id, as any open does.
            let opened = try w.row(uid: 100, in: w.folderId)
            let detail = MessageDetailViewModel(messageId: opened.id, dbPool: w.pool, fetchBodyOverride: { _ in })
            await detail.loadBody()
            #expect(detail.message?.id == opened.id, "setup: the message opened")

            // The open starts the folder's access run on its own task.
            for _ in 0..<Self.openPolls {
                await w.settle()
                if try w.folder(w.folderId).isFollowed, try w.isReconciled() { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try w.expectFollowed([w.folderId], "message open")
            try w.expectReconciled("message open")
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
            let run = SyncEngine.CatchUpRun(
                storageLimitInForce: false, deadline: nil, sliceSeconds: SyncConfig.catchUpSliceSeconds,
                intervalSeconds: 0, clock: { Date() })
            _ = await engine.runCatchUpRun(account: try w.account(), run: run)
            let state = ExchangeCatchUpState.decode(try w.folder(path).catchUpState)
            if state?.lastCompletedAt != nil, state?.listing == nil { return }
        }
    }

    static func readUntilTracking(_ w: R.World, _ path: String) async throws {
        for _ in 0..<passes {
            try await w.read()
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
            #expect(try w.folder(Self.projects).catchUpState == nil, "precondition: no catch-up of it either")
            #expect(try w.rowIds(in: Self.projects) == ["p-keep", "p-gone", "p-read"])

            try await w.pool.write { db in try SyncEngine.markFollowed(folderIds: [customId], db: db) }
            try await Self.readUntilTracking(w, Self.projects)
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
