/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// A value one context sets and another reads.
final class OtherFolderShared<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ initial: Value) { value = Mutex(initial) }
    func set(_ new: Value) { value.withLock { $0 = new } }
    var get: Value { value.withLock { $0 } }
}

// MARK: - The rules

/// The rules the other-folder run (#1110) rests on: the catch-up checks an other
/// folder after the syncable ones, and a whole-folder check of an other folder
/// with no change tracking comes weekly; a Gmail read sends nothing for a run;
/// an Outlook read reads exactly the run's folders; a dropped bookmark of an
/// other folder leaves the account's full sync as it was.
@Suite("Other folders: the rules (#1110)", .serialized, .processGlobalState)
struct OtherFolderRuleTests {

    static func lists(_ plan: IMAPProvider.CatchUpPlan) -> Bool {
        if case .list = plan { return true }
        return false
    }

    @Test("IMAP: an other folder's whole-folder check with no change tracking comes weekly, a syncable folder's daily; a first check and an armed one are not held back")
    func otherFolderFullCheckIsWeekly() {
        typealias P = IMAPProvider
        let now = Date()
        let daily = SyncConfig.catchUpFullCheckIntervalSeconds
        let weekly = SyncConfig.catchUpOtherFolderFullCheckIntervalSeconds
        #expect(weekly > daily, "precondition: the other folders' check is the rarer one")
        let pastDaily = IMAPCatchUpState(epoch: 1, lastCompletedAt: now.addingTimeInterval(-daily - 60))
        let pastWeekly = IMAPCatchUpState(epoch: 1, lastCompletedAt: now.addingTimeInterval(-weekly - 60))
        let armed = IMAPCatchUpState(epoch: 1, lastCompletedAt: now, lapseCount: 1)

        let syncableDue = Self.lists(P.catchUpPlan(state: pastDaily, freshModSeq: nil, now: now))
        let otherHeld = Self.lists(P.catchUpPlan(state: pastDaily, freshModSeq: nil, now: now, otherFolder: true))
        let otherDue = Self.lists(P.catchUpPlan(state: pastWeekly, freshModSeq: nil, now: now, otherFolder: true))
        let otherFirst = Self.lists(P.catchUpPlan(state: nil, freshModSeq: nil, now: now, otherFolder: true))
        let otherArmed = Self.lists(P.catchUpPlan(state: armed, freshModSeq: nil, now: now, otherFolder: true))
        #expect(syncableDue, "a syncable folder is checked a day after its last check")
        #expect(!otherHeld, "an other folder is not checked a day after its last check")
        #expect(otherDue, "an other folder is checked a week after its last check")
        #expect(otherFirst, "an other folder never checked is checked")
        #expect(otherArmed, "an other folder whose bookmark was dropped is checked at once")
    }

    @Test("The catch-up works the syncable folders before the other folders, each group never-tried first, then by its last try")
    func otherFoldersComeAfterTheSyncableSet() {
        let now = Date()
        let otherNever = Folder(name: "Other never", path: "OtherNever", role: .custom, accountId: "acc1")
        let syncableRecent = Folder(name: "Sent", path: "Sent", role: .sent, accountId: "acc1")
        let otherOld = Folder(name: "Other old", path: "OtherOld", role: .custom, accountId: "acc1")
        let syncableNever = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let tried: [String: Date] = [
            syncableRecent.id: now.addingTimeInterval(-600),
            otherOld.id: now.addingTimeInterval(-86_400),
        ]
        let folders = [otherNever, syncableRecent, otherOld, syncableNever]
        let later: Set<String> = [otherNever.id, otherOld.id]

        let ordered = CatchUpSchedule.leastRecentlyAttemptedFirst(folders, later: later) { tried[$0.id] }.map(\.id)
        #expect(ordered == [syncableNever.id, syncableRecent.id, otherNever.id, otherOld.id])
        let unsplit = CatchUpSchedule.leastRecentlyAttemptedFirst(folders) { tried[$0.id] }.map(\.id)
        #expect(unsplit == [otherNever.id, syncableNever.id, otherOld.id, syncableRecent.id],
                "with no other folders named, the order is by last try alone")
    }

    @Test("Outlook: a run's read covers exactly the folders it names, the Inbox included only when named")
    func outlookReadsTheRunsFolders() {
        let named = ChangeFolder(id: "acc1:fld-a", path: "fld-a", role: .custom, isSynced: true)
        let notNamed = ChangeFolder(id: "acc1:fld-b", path: "fld-b", role: .custom, isSynced: false)
        let inbox = ChangeFolder(id: "acc1:inbox", path: "inbox", role: .inbox, isSynced: false)
        let request = ChangeRequest(
            folders: [inbox, notNamed, named], scope: .otherFolders, recheck: [:],
            context: ChangeContext(deadline: Date().addingTimeInterval(60), clock: { Date() }, onProgress: { _ in }),
            localRows: IMAPChangeReaderTests.LocalRows())
        let read = ExchangeProvider.foldersToRead(request).map(\.id)
        #expect(read == [named.id])
    }

    @Test("Outlook: a run reads its folders in the order the engine gave, a folder still in its baseline before a tracked one; a pass still reads tracked folders first")
    func outlookRunKeepsTheEnginesOrder() {
        let tracking = OutlookFolderCursor(phase: .tracking, select: .state, next: "https://graph.example.com/delta-link").encoded
        let baselining = ChangeFolder(id: "acc1:fld-new", path: "fld-new", role: .custom, isSynced: true)
        let tracked = ChangeFolder(id: "acc1:fld-old", path: "fld-old", role: .custom, cursor: tracking, isSynced: true)
        func request(_ scope: ChangeScope) -> ChangeRequest {
            ChangeRequest(
                folders: [baselining, tracked], scope: scope, recheck: [:],
                context: ChangeContext(deadline: Date().addingTimeInterval(60), clock: { Date() }, onProgress: { _ in }),
                localRows: IMAPChangeReaderTests.LocalRows())
        }
        let run = ExchangeProvider.foldersToRead(request(.otherFolders)).map(\.id)
        let pass = ExchangeProvider.foldersToRead(request(.all)).map(\.id)
        #expect(run == [baselining.id, tracked.id], "the run keeps the engine's order")
        #expect(pass == [tracked.id, baselining.id], "a pass reads the tracked folder first, as before")
    }

    @Test("Gmail: a run's read sends nothing and reads nothing, since every pass's history read already reports every label")
    func gmailRunReadsNothing() async throws {
        try await GmailDeltaApplyInvariantTests.withWorld(seeds: []) { w in
            let callsBefore = w.server.http.recordedCalls().count
            let account = try w.account()
            let set = try await GmailChangeReadingTests.read(w, cursor: account.lastHistoryId, scope: .otherFolders)
            let callsAfter = w.server.http.recordedCalls().count
            let accountPart = set.account
            let noFolderList = set.folderList == nil
            let notRun = set.folders.allSatisfy { changes in
                if case .notRun = changes.status { return true }
                return false
            }
            #expect(callsAfter == callsBefore, "the read sent no request")
            #expect(accountPart == .unchanged, "and leaves the account's bookmark")
            #expect(noFolderList, "and reports no folder list")
            #expect(notRun && set.folders.count == w.folders.count, "every folder: not read")
        }
    }

    @Test("A dropped bookmark of an other folder arms its catch-up check and leaves the account's full sync as it was; a syncable folder's makes the full sync due")
    func droppedBookmarkOfAnOtherFolder() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "other-drop"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
                                                lastKnownUidNext: 1, lastKnownUidValidity: 1)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "Alpha", role: .custom, pool: pool,
                                                lastKnownUidNext: 1, lastKnownUidValidity: 1)
        let otherId = "\(accountId):Alpha"
        let inboxId = "\(accountId):INBOX"
        let stamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 60)
        let completed = IMAPCatchUpState(epoch: 1, lastCompletedAt: stamp).encoded()
        try await pool.write { db in
            try db.execute(sql: "UPDATE folder SET changeCursor = 'bookmark', catchUpState = ? WHERE accountId = ?",
                           arguments: [completed, accountId])
            try db.execute(sql: "UPDATE account SET lastFullSyncAt = ? WHERE id = ?", arguments: [stamp, accountId])
        }
        func fullSyncAt() throws -> Date? { try pool.read { db in try Account.fetchOne(db, key: accountId)?.lastFullSyncAt } }
        func folder(_ id: String) throws -> Folder? { try pool.read { db in try Folder.fetchOne(db, key: id) } }

        try await pool.write { db in
            try SyncEngine.dropChangeBookmark(folderId: otherId, onlyIfHeld: false, listedByFullSync: false, db: db)
        }
        let afterOther = try fullSyncAt()
        let other = try folder(otherId)
        #expect(afterOther == stamp, "the account's full sync is not made due for an other folder")
        #expect(other?.changeCursor == nil, "the other folder's bookmark is gone")
        #expect(CatchUpLapse.read(other?.catchUpState) == 1, "and its catch-up check is armed")

        try await pool.write { db in
            try SyncEngine.dropChangeBookmark(folderId: inboxId, onlyIfHeld: false, db: db)
        }
        let afterSyncable = try fullSyncAt()
        #expect(afterSyncable == nil, "a syncable folder's dropped bookmark makes the full sync due")
    }
}

// MARK: - IMAP, end to end

/// The wall limit of each test case in `OtherFolderIMAPTests`. At file scope
/// because a trait of `@Suite` cannot name a member of its own type.
let otherFolderIMAPTestTimeLimit: TimeLimitTrait.Duration = .minutes(5)

/// Two custom folders, neither a favourite nor followed, are outside the
/// syncable set. The system property: mail filed there on the server (a rule,
/// another client) reaches the device by the run a foreground pass due by its
/// 15-minute clock starts, never by the passes themselves; the run takes the
/// account's turn one bounded slice at a time, so a new-mail trigger that comes
/// during a slice waits at most that slice; waiting is not the run's working
/// time; a folder a run did not reach is read first by the next. Driven against
/// `FakeIMAPServer` through a registered engine of its own.
@Suite("Other folders: a run reads their changes, IMAP (#1110)", .serialized, .processGlobalState,
       .timeLimit(otherFolderIMAPTestTimeLimit))
struct OtherFolderIMAPTests {

    static let epoch = 52_110
    static let alpha = "Alpha"
    static let beta = "Beta"
    static let others = [alpha, beta]
    /// The UIDs each mailbox holds at the start, on the server and the device.
    static let held = Array(1...5)

    enum Server: String, CaseIterable, Sendable {
        /// No CONDSTORE: the run reads each folder's STATUS and lists one whose counters moved.
        case plain
        /// QRESYNC: the run stores each folder's bookmark, then reads from it.
        case qresync

        var capabilities: [String] {
            switch self {
            case .plain: FakeIMAPServer.defaultCapabilities
            case .qresync: FakeIMAPServer.defaultCapabilities + ["ENABLE", "CONDSTORE", "QRESYNC"]
            }
        }
    }

    static func rfc(_ uid: Int, in path: String) -> String { "other-\(path.lowercased())-\(uid)@example.com" }

    static func message(_ uid: Int, in path: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Receiver <receiver@example.com>\r
        Subject: other \(path) \(uid)\r
        Date: \(TestFixtureDate.rfc2822(daysFromAnchor: -uid))\r
        Message-ID: <\(rfc(uid, in: path))>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        body\r

        """)
    }

    /// The two forms a STATUS of `path` takes on the wire (an atom or a quoted string).
    static func statusFragments(_ path: String) -> [String] { ["STATUS \(path) ", "STATUS \"\(path)\""] }

    static func isStatus(_ command: String, of path: String) -> Bool {
        let upper = command.uppercased()
        return statusFragments(path).contains { upper.hasPrefix($0.uppercased()) }
    }

    static func names(_ command: String, _ path: String) -> Bool {
        let upper = command.uppercased()
        let name = path.uppercased()
        return upper.contains(" \(name) ") || upper.hasSuffix(" \(name)") || upper.contains("\"\(name)\"")
    }

    struct World: Sendable {
        let server: FakeIMAPServer
        let provider: IMAPProvider
        let engine: SyncEngine
        let pool: DatabasePool
        let accountId: String
        let recorder = FollowedFolderIMAPTests.SliceRecorder()
        let offset = FollowedFolderIMAPTests.ClockOffset()
        /// Whether the app is in the foreground, for the engine's other-folder runs.
        let foreground = OtherFolderShared<Bool>(true)

        func id(_ path: String) -> String { "\(accountId):\(path)" }
        func path(ofId folderId: String) -> String { String(folderId.dropFirst(accountId.count + 1)) }
        var otherIds: [String] { OtherFolderIMAPTests.others.map { id($0) } }

        /// Installs the engine's slice hook: each slice is recorded, then
        /// `action` runs, and the slice waits for it.
        func watchSlices(_ action: (@Sendable ([String]) async -> Void)? = nil) async {
            let recorder = recorder
            let server = server
            await engine.setCatchUpSliceStartHookForTesting { folderIds in
                recorder.record(folderIds, commandsBefore: server.recordedCommands().count)
                await action?(folderIds)
            }
        }

        /// The slices of other-folder runs: those that asked other folders only
        /// (a slice of the older-mail worker asks the Inbox too).
        var runSlices: [FollowedFolderIMAPTests.SliceRecorder.Slice] {
            let others = Set(otherIds)
            return recorder.all.filter { !$0.folderIds.isEmpty && $0.folderIds.allSatisfy(others.contains) }
        }

        func account() throws -> Account {
            let accountId = accountId
            let account = try pool.read { db in try Account.fetchOne(db, key: accountId) }
            return try #require(account)
        }

        func folder(_ path: String) throws -> Folder {
            let folderId = id(path)
            let folder = try pool.read { db in try Folder.fetchOne(db, key: folderId) }
            return try #require(folder)
        }

        func uids(in path: String) throws -> Set<Int> {
            let folderId = id(path)
            let ids = try pool.read { db in
                try String.fetchAll(db, sql: "SELECT messageId FROM messageHeader WHERE folderId = ?", arguments: [folderId])
            }
            return Set(ids.compactMap { Int($0) })
        }

        func holds(_ uid: Int, in path: String) throws -> Bool { try uids(in: path).contains(uid) }

        func nextUid(in path: String) -> Int { (server.messages(in: path).map(\.uid).max() ?? 0) + 1 }

        /// The server files a new message at `uid` in `path`, as a rule does.
        func deliver(_ uid: Int, to path: String) {
            server.setMessages(server.messages(in: path) + [OtherFolderIMAPTests.message(uid, in: path)], in: path)
        }

        func statusCount(_ path: String) -> Int {
            server.recordedCommands().filter { OtherFolderIMAPTests.isStatus($0, of: path) }.count
        }

        /// The commands from position `start` of the server's log that name the
        /// mailbox `path`, or were sent while it was selected.
        func commands(naming path: String, since start: Int = 0) -> [String] {
            server.recordedCommandsWithMailbox().dropFirst(start)
                .filter { $0.mailbox == path || OtherFolderIMAPTests.names($0.command, path) }
                .map(\.command)
        }

        func holdStatus(of path: String) {
            for fragment in OtherFolderIMAPTests.statusFragments(path) { server.holdNextCommand(containing: fragment) }
        }

        func isHoldingStatus(of path: String?) -> Bool {
            guard let path else { return false }
            return OtherFolderIMAPTests.statusFragments(path).contains { server.isHoldingCommand(containing: $0) }
        }

        /// Lets a held STATUS of `path` go (and disarms the form not sent).
        func releaseStatus(of path: String?) {
            guard let path else { return }
            for fragment in OtherFolderIMAPTests.statusFragments(path) { server.releaseHeldCommand(containing: fragment) }
        }

        /// Makes the account's full sync due by its clock.
        func setFullSyncDue() async throws {
            let accountId = accountId
            try await pool.write { db in
                try db.execute(sql: "UPDATE account SET lastFullSyncAt = ? WHERE id = ?", arguments: [Date.distantPast, accountId])
            }
        }

        /// The run under way, if any, has ended.
        func settle() async {
            await engine.awaitOtherFolderRunForTesting(accountId: accountId)
        }

        /// One run, from its start to its end.
        func runOnce() async throws {
            let account = try account()
            await engine.startOtherFolderRun(account: account)
            await settle()
        }

        /// The older-mail check of every folder, until it has nothing left to do.
        func drainCatchUp() async throws {
            let account = try account()
            _ = await engine.runCatchUpRun(
                account: account, run: .snapshot(deadline: Date().addingTimeInterval(OtherFolderIMAPTests.drainSeconds)))
        }
    }

    /// The bound of the older-mail check a test drains before it starts.
    static let drainSeconds: TimeInterval = 30

    /// The server holds `held` in the Inbox and in each other folder; the device
    /// holds the same, each row the server's message at its UID, every folder's
    /// older-mail walk complete and its check just done (so the older-mail
    /// worker a pass starts has nothing to do), the account's full sync just
    /// done. The engine is registered for the account; the other-folder runs
    /// are measured on `World.offset`'s clock.
    static func withWorld(_ name: String, _ kind: Server, _ body: (World) async throws -> Void) async throws {
        var mailboxes: [String: [FakeIMAPServer.Message]] = ["INBOX": held.map { message($0, in: "INBOX") }]
        for path in others { mailboxes[path] = held.map { message($0, in: path) } }
        let server = FakeIMAPServer(capabilities: kind.capabilities, mailboxes: mailboxes)
        for mailbox in mailboxes.keys { server.setUidValidity(epoch, for: mailbox) }
        try server.start()
        defer { server.stop() }

        let accountId = "other-\(name)-\(kind.rawValue)"
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        let paths = ["INBOX"] + others
        for path in paths {
            try FolderEpochTestFixture.insertFolder(
                accountId: accountId, path: path, role: path == "INBOX" ? .inbox : .custom, pool: pool,
                totalCount: held.count, lastKnownUidNext: held.count + 1, lastKnownUidValidity: epoch)
            try FolderEpochTestFixture.insertHeaders(accountId: accountId, path: path, uids: held, pool: pool)
        }
        let completed = IMAPCatchUpState(epoch: UInt32(epoch), lastCompletedAt: Date()).encoded()
        try await pool.write { db in
            for path in paths {
                for uid in held {
                    try db.execute(sql: """
                        UPDATE messageHeader SET rfc822MessageId = ?, observedUidValidity = ?
                        WHERE folderId = ? AND messageId = ?
                        """, arguments: [rfc(uid, in: path), epoch, "\(accountId):\(path)", "\(uid)"])
                }
            }
            try db.execute(sql: "UPDATE messageHeader SET isInInbox = 1 WHERE folderId = ?", arguments: ["\(accountId):INBOX"])
            try db.execute(sql: "UPDATE folder SET backfillComplete = 1, catchUpState = ? WHERE accountId = ?",
                           arguments: [completed, accountId])
            try db.execute(sql: "UPDATE account SET lastFullSyncAt = ? WHERE id = ?", arguments: [Date(), accountId])
        }

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        // The body queues are process-wide: start from empty ones, and hold this
        // world's downloads, so the only requests are the sync's own. A listing
        // queues its new rows on the active queue: emptied again at the end, so
        // nothing of this world's account is left there for the next test.
        await BackfillBodyQueue.shared.emptyForTesting()
        await BackfillBodyQueue.shared.setDispatchSuppressedForTesting(true)
        await ActiveBodyQueue.shared.emptyForTesting()
        let world = World(server: server, provider: provider, engine: engine, pool: pool, accountId: accountId)
        await world.watchSlices()
        let offset = world.offset
        await engine.setOtherFolderRunClockForTesting { offset.now() }
        // The app is in the foreground unless a test says otherwise, whatever
        // state the test host's own lifecycle is in.
        let foreground = world.foreground
        await engine.setOtherFolderRunForegroundForTesting { foreground.get }
        func teardown() async {
            await engine.remove(accountId: accountId)
            await engine.setCatchUpSliceStartHookForTesting(nil)
            await BackfillBodyQueue.shared.emptyForTesting()
            await BackfillBodyQueue.shared.setDispatchSuppressedForTesting(false)
            await ActiveBodyQueue.shared.emptyForTesting()
            try? await provider.disconnect()
        }
        do {
            for path in others {
                let folder = try world.folder(path)
                let syncable = SyncEngine.isSyncable(folder)
                #expect(!syncable, "\(name): setup: \(path) is outside the syncable set")
            }
            try await body(world)
            let violations = server.wrongMessageViolations()
            #expect(violations.isEmpty, "\(name): no change reached a wrong message: \(violations)")
        } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    // MARK: Arrival

    @Test("Mail a rule files into a folder outside the syncable set reaches the device after the next pass whose full sync is due by its clock",
          arguments: Server.allCases)
    func ruleFiledMailArrives(server kind: Server) async throws {
        try await Self.withWorld("rule-filed", kind) { w in
            if kind == .qresync {
                // A QRESYNC folder's first run stores its bookmark, and its
                // older-mail check then checks it once: both done here, so the
                // arrival below is the change read's to bring.
                try await w.runOnce()
                let bookmarked = try Self.others.allSatisfy { try w.folder($0).changeCursor != nil }
                #expect(bookmarked, "setup: the first run stored each other folder's bookmark")
                try await w.drainCatchUp()
            }
            let uid = w.nextUid(in: Self.alpha)
            w.deliver(uid, to: Self.alpha)
            let early = try w.holds(uid, in: Self.alpha)
            #expect(!early, "setup: the device does not hold the new message yet")

            try await w.setFullSyncDue()
            let account = try w.account()
            _ = try await w.engine.sync(account: account)
            await w.settle()
            let arrived = try w.holds(uid, in: Self.alpha)
            #expect(arrived, "\(kind): the run the pass started brought the message filed into Alpha")
            let folder = try w.folder(Self.alpha)
            let syncable = SyncEngine.isSyncable(folder)
            #expect(!syncable, "and Alpha is still outside the syncable set")
        }
    }

    @Test("A pass whose full sync is not due by its clock sends nothing for the other folders and starts no run; a pass due by its clock starts the run, which reads each other folder once")
    func passesLeaveTheOtherFoldersAlone() async throws {
        try await Self.withWorld("passes", .plain) { w in
            let uid = w.nextUid(in: Self.alpha)
            w.deliver(uid, to: Self.alpha)
            let start = w.server.recordedCommands().count
            let account = try w.account()
            _ = try await w.engine.sync(account: account)
            _ = try await w.engine.performChangePass(account: account, provider: w.provider)
            await w.settle()
            let sent = Self.others.flatMap { w.commands(naming: $0, since: start) }
            #expect(sent.isEmpty, "the passes sent nothing for the other folders: \(sent)")
            #expect(w.runSlices.isEmpty, "and started no run")
            let early = try w.holds(uid, in: Self.alpha)
            #expect(!early, "the message filed into Alpha waits for the run")

            try await w.setFullSyncDue()
            let dueAccount = try w.account()
            _ = try await w.engine.sync(account: dueAccount)
            await w.settle()
            let arrived = try w.holds(uid, in: Self.alpha)
            #expect(arrived, "the pass due by its clock started the run, which brought it")
            let firstSlice = w.runSlices.first?.commandsBefore ?? Int.max
            for path in Self.others {
                let read = w.server.recordedCommands().dropFirst(firstSlice).filter { Self.isStatus($0, of: path) }
                #expect(read.count == 1, "\(path): the run read it once: \(Array(read))")
            }

            // The next pass is not due by its clock: no run, no read of the other folders.
            let statusesBefore = Self.others.map { w.statusCount($0) }
            let slicesBefore = w.runSlices.count
            let nextAccount = try w.account()
            _ = try await w.engine.sync(account: nextAccount)
            await w.settle()
            let statusesAfter = Self.others.map { w.statusCount($0) }
            #expect(statusesAfter == statusesBefore, "the next pass read no other folder")
            #expect(w.runSlices.count == slicesBefore, "and started no run")
        }
    }

    @Test("A pass whose full sync is due only because its change read stored a first bookmark starts no run")
    func aListingOnlyFullSyncStartsNoRun() async throws {
        try await Self.withWorld("listing-only", .qresync) { w in
            // The Inbox holds no bookmark: the pass's read stores its first one,
            // which needs a listing, so the pass runs the full sync although its
            // clock is not due.
            let start = w.server.recordedCommands().count
            let account = try w.account()
            _ = try await w.engine.sync(account: account)
            await w.settle()
            let inbox = try w.folder("INBOX")
            let covered = FolderChangeState(raw: inbox.changeState).tracking
            #expect(inbox.changeCursor != nil && covered, "setup: the pass stored the Inbox's bookmark and its full sync listed it")
            #expect(w.runSlices.isEmpty, "the pass started no run")
            for path in Self.others {
                let cursor = try w.folder(path).changeCursor
                let selected = w.commands(naming: path, since: start).filter {
                    let upper = $0.uppercased()
                    return upper.hasPrefix("SELECT") || upper.hasPrefix("EXAMINE")
                }
                #expect(cursor == nil, "\(path) got no bookmark")
                #expect(selected.isEmpty, "\(path) was not selected: \(selected)")
            }
        }
    }

    @Test("A run stores an other folder's first bookmark and reads from it after, without touching the account's clocks or bookmark, and never turns the folder's coverage on")
    func aRunLeavesTheAccountsClocks() async throws {
        try await Self.withWorld("clocks", .qresync) { w in
            let fullSyncAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 60)
            let syncedAt = fullSyncAt.addingTimeInterval(30)
            let accountId = w.accountId
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE account SET lastFullSyncAt = ?, lastSyncedAt = ? WHERE id = ?",
                               arguments: [fullSyncAt, syncedAt, accountId])
            }
            let before = try w.account()
            try await w.runOnce()
            let after = try w.account()
            #expect(after.lastFullSyncAt == before.lastFullSyncAt, "the full sync's clock is untouched")
            #expect(after.lastSyncedAt == before.lastSyncedAt, "the change read's clock is untouched")
            #expect(after.lastHistoryId == before.lastHistoryId, "the account's bookmark is untouched")
            for path in Self.others {
                let folder = try w.folder(path)
                let covered = FolderChangeState(raw: folder.changeState).tracking
                let syncable = SyncEngine.isSyncable(folder)
                #expect(folder.changeCursor != nil, "\(path): the run stored its first bookmark")
                #expect(!covered, "\(path): its coverage stays off")
                #expect(!syncable, "\(path): it stays outside the syncable set")
            }

            // The next run reads Beta from its bookmark, and still moves no clock.
            let uid = w.nextUid(in: Self.beta)
            w.deliver(uid, to: Self.beta)
            try await w.runOnce()
            let arrived = try w.holds(uid, in: Self.beta)
            let again = try w.account()
            #expect(arrived, "the next run brought the message filed into Beta")
            #expect(again.lastFullSyncAt == before.lastFullSyncAt && again.lastSyncedAt == before.lastSyncedAt,
                    "and moved no clock of the account")
        }
    }

    // MARK: Cost

    @Test("A run sends a quiet other folder one STATUS and nothing else, a due mark alone lists nothing, and a start while a run goes on starts none beside it")
    func aQuietFolderCostsOneStatus() async throws {
        try await Self.withWorld("quiet", .plain) { w in
            // Alpha carries a due mark, as a deletion check cut short leaves one.
            let alphaId = w.id(Self.alpha)
            try await w.pool.write { db in
                var state = FolderChangeState(raw: nil)
                state.markListingDue()
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [state.encoded, alphaId])
            }
            let secondStart = HeldWorkFlag()
            let account = try w.account()
            let engine = w.engine
            await w.watchSlices { _ in
                guard !secondStart.set() else { return }
                // A pass due by its clock ends while the run's first slice goes on.
                await engine.startOtherFolderRun(account: account)
            }
            let start = w.server.recordedCommands().count
            try await w.runOnce()
            #expect(secondStart.isSet, "setup: a second start came during the run")
            for path in Self.others {
                let sent = w.commands(naming: path, since: start)
                let statuses = sent.filter { Self.isStatus($0, of: path) }
                #expect(statuses.count == 1 && sent.count == 1, "\(path): one STATUS and nothing else: \(sent)")
            }
            let rows = try w.uids(in: Self.alpha)
            #expect(rows == Set(Self.held), "nothing listed, nothing removed")
        }
    }

    @Test("A folder whose read fails is left out of the rest of the run, and the run still reads the other folders")
    func aFailedFolderIsLeftOut() async throws {
        try await Self.withWorld("failed", .plain) { w in
            let uid = w.nextUid(in: Self.beta)
            w.deliver(uid, to: Self.beta)
            // Alpha's counters cannot be read this time (the form sent fails).
            for fragment in Self.statusFragments(Self.alpha) { w.server.failNextCommand(containing: fragment) }
            try await w.runOnce()
            let alphaReads = w.statusCount(Self.alpha)
            let arrived = try w.holds(uid, in: Self.beta)
            #expect(alphaReads == 1, "Alpha's failed read was not asked again in the run")
            #expect(arrived, "Beta was still read, and its new message arrived")
        }
    }

    // MARK: Foreground only

    @Test("A run starts, and takes each slice, only while the app is in the foreground: a pass that ends after the app has left starts none, a slice whose slot comes after the app left reads nothing, and a run whose app leaves during a slice takes no further slice")
    func aRunReadsInTheForegroundOnly() async throws {
        try await Self.withWorld("foreground", .plain) { w in
            let account = try w.account()
            let accountId = w.accountId
            func otherStatuses() -> Int { Self.others.map { w.statusCount($0) }.reduce(0, +) }

            // 1. Out of the foreground: no run is started.
            w.foreground.set(false)
            await w.engine.startOtherFolderRun(account: account)
            let started = await w.engine.otherFolderRunTasks[accountId] != nil
            await w.settle()
            let readOutside = otherStatuses()
            #expect(!started, "no run started out of the foreground")
            #expect(w.runSlices.isEmpty && readOutside == 0, "nothing was read")

            // 2. The app leaves after a slice's turn, before its slot: that
            // slice reads nothing, and the run ends.
            w.foreground.set(true)
            let foreground = w.foreground
            await w.watchSlices { _ in foreground.set(false) }
            await w.engine.startOtherFolderRun(account: account)
            await w.settle()
            let readAtSlot = otherStatuses()
            #expect(w.runSlices.count == 1, "the run took its first slice's turn, then ended")
            #expect(readAtSlot == 0, "and that slice read nothing")

            // 3. The app leaves during a slice: the slice ends as it would, and
            // the run takes no further slice.
            w.recorder.reset()
            w.foreground.set(true)
            let first = OtherFolderShared<String?>(nil)
            await w.watchSlices { folderIds in
                guard first.get == nil, let firstId = folderIds.first else { return }
                let path = w.path(ofId: firstId)
                first.set(path)
                w.holdStatus(of: path)
            }
            await w.engine.startOtherFolderRun(account: account)
            guard await OneSyncAtATimeTests.eventually({ w.isHoldingStatus(of: first.get) }) else {
                Issue.record("precondition: the run's first slice is held at its first folder's read")
                w.releaseStatus(of: first.get)
                await w.settle()
                return
            }
            // The slice's time runs out while its read is held, so it reads
            // this folder only; the app leaves meanwhile.
            w.offset.add(SyncConfig.catchUpSliceSeconds + 1)
            w.foreground.set(false)
            w.releaseStatus(of: first.get)
            await w.settle()
            let slices = w.runSlices.map(\.folderIds)
            #expect(slices.count == 1, "no slice after the app left: \(slices)")
            for path in Self.others where path != first.get {
                let reads = w.statusCount(path)
                #expect(reads == 0, "\(path): not read once the app had left")
            }
        }
    }

    // MARK: Timing (sync timing promises 1, 2, 3 and 8)

    @Test("A new-mail trigger that finds a run's slice holding the turn asks for its stage 2 without waiting, and that stage 2 reads when the slice ends, before the run's next slice")
    func aTriggerDuringASliceWaitsAtMostThatSlice() async throws {
        try await Self.withWorld("trigger", .plain) { w in
            let engine = w.engine
            let accountId = w.accountId
            let pool = w.pool
            let inboxId = w.id("INBOX")
            let newUid = w.nextUid(in: "INBOX")
            let first = OtherFolderShared<String?>(nil)
            let rowAtLaterSlices = OtherFolderShared<[Bool]>([])
            await w.watchSlices { folderIds in
                // Slices of the older-mail worker (which ask the Inbox) are not the run's.
                guard !folderIds.contains(inboxId), let firstId = folderIds.first else { return }
                if first.get == nil {
                    let path = w.path(ofId: firstId)
                    first.set(path)
                    w.holdStatus(of: path)
                    return
                }
                let count = (try? await pool.read { db in
                    try MessageHeader.filter(Column("folderId") == inboxId && Column("messageId") == "\(newUid)").fetchCount(db)
                }) ?? 0
                rowAtLaterSlices.set(rowAtLaterSlices.get + [count == 1])
            }
            func stop(_ reason: Comment) async {
                Issue.record(reason)
                w.releaseStatus(of: first.get)
                await w.settle()
            }

            let account = try w.account()
            await engine.startOtherFolderRun(account: account)
            guard await OneSyncAtATimeTests.eventually({ w.isHoldingStatus(of: first.get) }) else {
                return await stop("precondition: the run's first slice holds the turn, its read held at the server")
            }
            // The slice's time runs out while its read is held: the read stops
            // after this folder, and the run takes another slice.
            w.offset.add(SyncConfig.catchUpSliceSeconds + 1)
            w.deliver(newUid, to: "INBOX")

            let trigger: Bool?
            do {
                trigger = try await engine.syncOrFollowUp(account: account, deadline: nil)
            } catch {
                w.releaseStatus(of: first.get)
                await w.settle()
                throw error
            }
            let wanted = await engine.syncFollowUpWanted.contains(accountId)
            #expect(trigger == nil, "the trigger found the account busy and did not wait")
            #expect(wanted, "it asked for its stage 2")
            let followUp = Task { try await engine.followUpPass(accountId: accountId, mayStart: { true }) }
            guard await OneSyncAtATimeTests.eventually({ await engine.syncPassWaiters[accountId]?.count == 1 }) else {
                await stop("precondition: the stage 2 waits for the slice's turn")
                _ = await followUp.result
                return
            }
            w.releaseStatus(of: first.get)
            let ran = try await followUp.value
            let read = try w.holds(newUid, in: "INBOX")
            #expect(ran != nil, "the stage 2 ran")
            #expect(read, "its read brought the new mail")

            await w.settle()
            let later = rowAtLaterSlices.get
            #expect(!later.isEmpty && later.allSatisfy { $0 }, "every later slice of the run started after the new mail was read: \(later)")
            for path in Self.others {
                let statuses = w.statusCount(path)
                #expect(statuses >= 1, "\(path): the run still read it")
            }
        }
    }

    @Test("A run's working time is its slices' time: a run that waits for the turn behind a pass while its clock moves on twice its working time still reads every other folder")
    func waitingIsNotWorkingTime() async throws {
        try await Self.withWorld("waiting", .plain) { w in
            let engine = w.engine
            let accountId = w.accountId
            let uids = Self.others.map { w.nextUid(in: $0) }
            for (path, uid) in zip(Self.others, uids) { w.deliver(uid, to: path) }
            // Read before the pass holds the turn, so nothing below can throw
            // while it is held.
            let account = try w.account()
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            let holder = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "held", log: log, release: release.stream)
            func stop(_ reason: Comment) async {
                Issue.record(reason)
                release.continuation.finish()
                await holder.value
                await w.settle()
            }
            guard await OneSyncAtATimeTests.eventually({ log.snapshot == ["start held"] }) else {
                return await stop("precondition: the pass holds the turn")
            }
            await engine.startOtherFolderRun(account: account)
            guard await OneSyncAtATimeTests.eventually({ await engine.syncPassWaiters[accountId]?.count == 1 }) else {
                return await stop("precondition: the run waits for the turn behind the pass")
            }
            w.offset.add(2 * SyncConfig.otherFolderRunSeconds)
            let slicesWhileHeld = w.runSlices.count
            #expect(slicesWhileHeld == 0, "no slice ran while the pass held the turn")

            release.continuation.yield()
            await holder.value
            await w.settle()
            for (path, uid) in zip(Self.others, uids) {
                let arrived = try w.holds(uid, in: path)
                #expect(arrived, "\(path): the run read it, and listed its new message, after the wait")
            }
        }
    }

    @Test("A folder a run did not reach before its working time was spent is read first by the next run, and its changes arrive then")
    func aFolderNotReachedIsReadFirstNextRun() async throws {
        try await Self.withWorld("not-reached", .plain) { w in
            let server = w.server
            let first = OtherFolderShared<String?>(nil)
            let second = OtherFolderShared<String?>(nil)
            await w.watchSlices { folderIds in
                guard first.get == nil, folderIds.count == Self.others.count else { return }
                let paths = folderIds.map { w.path(ofId: $0) }
                first.set(paths[0])
                second.set(paths[1])
                // The second folder gets new mail; the first folder's read is held.
                let uid = (server.messages(in: paths[1]).map(\.uid).max() ?? 0) + 1
                server.setMessages(server.messages(in: paths[1]) + [Self.message(uid, in: paths[1])], in: paths[1])
                w.holdStatus(of: paths[0])
            }
            let account = try w.account()
            await w.engine.startOtherFolderRun(account: account)
            guard await OneSyncAtATimeTests.eventually({ w.isHoldingStatus(of: first.get) }) else {
                Issue.record("precondition: the run's first slice is held at its first folder's read")
                w.releaseStatus(of: first.get)
                await w.settle()
                return
            }
            // The run's whole working time is spent inside this slice.
            w.offset.add(SyncConfig.otherFolderRunSeconds)
            w.releaseStatus(of: first.get)
            await w.settle()
            let missedPath = second.get
            let missed = try #require(missedPath)
            let newUid = w.nextUid(in: missed) - 1
            let early = try w.holds(newUid, in: missed)
            #expect(!early, "precondition: the run ended before it reached \(missed)")
            #expect(w.runSlices.count == 1, "the run ended with the slice that spent its time")

            w.recorder.reset()
            try await w.runOnce()
            let firstAsked = w.runSlices.first?.folderIds.first
            let arrived = try w.holds(newUid, in: missed)
            #expect(firstAsked == w.id(missed), "the next run reads the folder not reached first")
            #expect(arrived, "and its new mail arrives")
        }
    }

    @Test("With no change tracking, a slice starts a changed folder's listing only while it has time; a changed folder it could not list is listed by the run's next slice")
    func aListingStartsOnlyWithinTheSlice() async throws {
        try await Self.withWorld("bounded", .plain) { w in
            let server = w.server
            let uids = Self.others.map { w.nextUid(in: $0) }
            for (path, uid) in zip(Self.others, uids) { w.deliver(uid, to: path) }
            let first = OtherFolderShared<String?>(nil)
            await w.watchSlices { folderIds in
                guard first.get == nil, let firstId = folderIds.first else { return }
                let path = w.path(ofId: firstId)
                first.set(path)
                server.holdNextFetchAfterSnapshot(in: path)
            }
            func holdingListing() -> Bool {
                guard let path = first.get else { return false }
                return server.isHoldingFetchAfterSnapshot(in: path)
            }
            let account = try w.account()
            await w.engine.startOtherFolderRun(account: account)
            guard await OneSyncAtATimeTests.eventually({ holdingListing() }) else {
                Issue.record("precondition: the first changed folder's listing is held at the server")
                if let path = first.get { server.releaseFetchAfterSnapshot(in: path) }
                await w.settle()
                return
            }
            guard let firstPath = first.get else {
                Issue.record("precondition: the first slice named its first folder")
                await w.settle()
                return
            }
            let otherId = w.otherIds.first { $0 != w.id(firstPath) }
            let secondPath = otherId.map { w.path(ofId: $0) } ?? ""
            // Both folders' counters were read before the first listing, so the
            // second folder is changed and not listed by its slice's guard, not
            // left unread by its read.
            let secondReadBefore = w.statusCount(secondPath)
            #expect(secondReadBefore == 1, "precondition: the slice read \(secondPath)'s counters before its first listing")
            // The slice's time runs out while that listing is held.
            w.offset.add(SyncConfig.catchUpSliceSeconds + 1)
            server.releaseFetchAfterSnapshot(in: firstPath)
            await w.settle()

            let asked = w.runSlices.map(\.folderIds)
            let secondId = try #require(otherId)
            let firstAskedAll = asked.first.map { Set($0) == Set(w.otherIds) } ?? false
            #expect(asked.count == 2 && firstAskedAll, "two slices, the first asking both folders: \(asked)")
            #expect(asked.last == [secondId], "the second slice asks only the folder not listed yet: \(asked)")
            for (path, uid) in zip(Self.others, uids) {
                let arrived = try w.holds(uid, in: path)
                #expect(arrived, "\(path): its new message arrived")
            }
        }
    }
}

// MARK: - Outlook

/// An Outlook folder outside the syncable set is baselined by the runs, then
/// read from its bookmark: what changed there on the web arrives by the next
/// run. The passes send nothing for it, and neither touches the account's
/// clocks or turns the folder's coverage on.
@Suite("Other folders: a run reads their changes, Outlook (#1110)", .serialized, .processGlobalState)
struct OtherFolderOutlookTests {
    typealias R = OutlookChangeReadingTests
    typealias C = OutlookCatchUpTests

    static let projects = "fld-other-projects"
    /// Bounded runs until the baseline completes.
    static let runs = 10

    /// One other-folder run, its slices back to back.
    static func run(_ w: R.World, _ engine: SyncEngine) async throws {
        var run = SyncEngine.CatchUpRun(
            storageLimitInForce: false, deadline: nil, sliceSeconds: SyncConfig.catchUpSliceSeconds,
            intervalSeconds: 0, clock: { Date() })
        run.workSeconds = SyncConfig.otherFolderRunSeconds
        run.readsOtherFolders = true
        let account = try w.account()
        _ = await engine.runCatchUpRun(account: account, run: run)
    }

    @Test("Outlook: a folder outside the syncable set is baselined by the runs, which then bring what changed there on the web; the passes send nothing for it, and the account's clocks and the folder's coverage stay as they were")
    func otherFolderIsReadByTheRuns() async throws {
        let c = C.Clock()
        try await C.withWorld(seeds: [
            C.seed("o-keep", in: Self.projects, at: c.daysAgo(2)),
            C.seed("o-read", in: Self.projects, at: c.daysAgo(3)),
        ]) { w, engine in
            w.server.addFolder(id: Self.projects, name: "Projects")
            var custom = Folder(name: "Projects", path: Self.projects, role: .custom, accountId: w.accountId)
            custom.oldestSyncedDate = R.daysAgo(30)
            let toInsert = custom
            try await w.pool.write { db in try toInsert.insert(db) }
            try C.setWalkComplete(w, Self.projects, true)
            for (id, days) in [("o-keep", 2.0), ("o-read", 3)] {
                try w.insertRow(id, in: Self.projects, date: c.daysAgo(days))
            }
            try await w.baselineAll()
            let before = try w.account()
            let syncable = SyncEngine.isSyncable(try w.folder(Self.projects))
            #expect(!syncable, "setup: the folder is outside the syncable set")

            // The passes send nothing for it.
            let requestsBefore = w.server.requestCount(containing: Self.projects)
            try await w.read()
            try await w.delta()
            let passRequests = w.server.requestCount(containing: Self.projects) - requestsBefore
            let untouched = try w.cursor(Self.projects)
            #expect(passRequests == 0, "the passes sent no request for it")
            #expect(untouched == nil, "and stored no bookmark for it")

            // The runs baseline it.
            for _ in 0..<Self.runs {
                try await Self.run(w, engine)
                if try w.cursor(Self.projects)?.phase == .tracking { break }
            }
            let phase = try w.cursor(Self.projects)?.phase
            let baselined = try w.rowIds(in: Self.projects)
            #expect(phase == .tracking, "the runs completed its baseline")
            #expect(baselined == ["o-keep", "o-read"], "a baseline removes nothing")

            // What changed on the web arrives by the next run.
            w.server.deliver(C.seed("o-new", in: Self.projects, at: c.daysAgo(0.5)))
            w.server.setReadFromOtherClient(providerMessageId: "o-read", isRead: true)
            w.server.deleteFromOtherClient(providerMessageId: "o-keep")
            try await Self.run(w, engine)
            let rows = try w.rowIds(in: Self.projects)
            let readRow = try w.row("o-read", in: Self.projects)
            #expect(rows == ["o-read", "o-new"], "the new message arrived and the deleted one left: \(rows)")
            #expect(readRow?.isRead == true, "the read change arrived")

            let after = try w.account()
            let folder = try w.folder(Self.projects)
            let covered = FolderChangeState(raw: folder.changeState).tracking
            #expect(after.lastFullSyncAt == before.lastFullSyncAt, "the full sync's clock is untouched")
            #expect(after.lastHistoryId == before.lastHistoryId, "the account's bookmark is untouched")
            #expect(!covered && !folder.isFollowed, "the folder's coverage stays off, and it is not followed")
        }
    }
}
