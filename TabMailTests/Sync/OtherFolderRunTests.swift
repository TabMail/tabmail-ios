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

/// Whether the folder's next full sync lists it deep: what
/// `SyncEngine.fullSyncIsDeepPass` would answer, read without counting a full
/// sync, so the witness leaves the count a later run reads as it was.
func otherFolderOwesDeepListing(_ folderId: String) -> Bool {
    (SyncEngine.fullSyncSkipStreakForTesting(folderId: folderId) ?? 0) + 1 >= max(1, SyncConfig.fullSyncDeepEveryN)
}

/// The folders' full-sync counts, to set back when a test ends (the counts are
/// process-wide).
func otherFolderSkipStreaks(_ folderIds: [String]) -> [(folderId: String, streak: Int?)] {
    folderIds.map { ($0, SyncEngine.fullSyncSkipStreakForTesting(folderId: $0)) }
}

func restoreOtherFolderSkipStreaks(_ streaks: [(folderId: String, streak: Int?)]) {
    for saved in streaks { SyncEngine.setFullSyncSkipStreakForTesting(folderId: saved.folderId, saved.streak) }
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
        #expect(weekly == 7 * 24 * 60 * 60, "the other folders' whole-folder check is weekly")
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

    /// What one request under `bound` came to.
    static func outcome(_ bound: ListingRequestBound, _ operation: @escaping @Sendable () async throws -> Int) async -> String {
        do {
            let value = try await bound.request(operation)
            return "answered \(value)"
        } catch is ListingRequestBound.Cut {
            return "cut"
        } catch is TimeoutError {
            return "timed out"
        } catch {
            return "failed: \(error)"
        }
    }

    @Test("A run's listing request starts only while the slice has time, and is given up at its request limit")
    func listingRequestBound() async {
        let started = OtherFolderShared<Bool>(false)
        let over = ListingRequestBound(
            slice: ChangeContext(deadline: Date().addingTimeInterval(-1), clock: { Date() }, onProgress: { _ in }),
            timeoutSeconds: 60)
        let afterTheEnd = await Self.outcome(over) {
            started.set(true)
            return 1
        }
        #expect(afterTheEnd == "cut", "a request after the slice's end is not started")
        #expect(!started.get, "and nothing of it ran")

        let open = ListingRequestBound(
            slice: ChangeContext(deadline: Date().addingTimeInterval(60), clock: { Date() }, onProgress: { _ in }),
            timeoutSeconds: 0.2)
        let answered = await Self.outcome(open) { 7 }
        let asked = Date()
        let stalled = await Self.outcome(open) {
            try await Task.sleep(for: .seconds(30))
            return 0
        }
        let gaveUpAfter = Date().timeIntervalSince(asked)
        #expect(answered == "answered 7", "a request within the slice is sent and answered")
        #expect(stalled == "timed out", "a request with no answer is given up at its limit")
        // The bound's own limit (0.2 s), not the default request limit.
        #expect(gaveUpAfter < SyncConfig.catchUpRequestTimeoutSeconds,
                "given up at the bound's limit, before the default one: \(gaveUpAfter) s")
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
        func teardown() async {
            // The slice hook first, so no slice of a run still going holds a
            // read while the account is removed.
            await engine.setCatchUpSliceStartHookForTesting(nil)
            await engine.remove(accountId: accountId)
            await BackfillBodyQueue.shared.emptyForTesting()
            await BackfillBodyQueue.shared.setDispatchSuppressedForTesting(false)
            await ActiveBodyQueue.shared.emptyForTesting()
            try? await provider.disconnect()
            // A recount the sync queued ends before this world's database is retired.
            await UnreadCountManager.shared.awaitIdleForTesting()
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

    @Test("A pass due by its clock whose full sync fails starts no run: nothing is asked of the other folders")
    func aFailedFullSyncStartsNoRun() async throws {
        try await Self.withWorld("full-sync-failed", .plain) { w in
            let uid = w.nextUid(in: Self.alpha)
            w.deliver(uid, to: Self.alpha)
            try await w.setFullSyncDue()
            let account = try w.account()
            let start = w.server.recordedCommands().count
            // The full sync's folder list is refused, so the full sync fails.
            let refused = "LIST"
            w.server.failEveryCommand(containing: refused, message: "Injected full sync failure")
            var threw = false
            do {
                _ = try await w.engine.sync(account: account)
            } catch {
                threw = true
            }
            w.server.stopFailingCommands(containing: refused)
            await w.settle()

            let listed = w.server.recordedCommands().dropFirst(start).contains { $0.uppercased().contains(refused) }
            let sent = Self.others.flatMap { w.commands(naming: $0, since: start) }
            let arrived = try w.holds(uid, in: Self.alpha)
            #expect(listed && threw, "precondition: the pass's full sync asked for the folder list, and the pass failed")
            #expect(w.runSlices.isEmpty, "the pass started no run")
            #expect(sent.isEmpty, "and nothing was asked of the other folders: \(sent)")
            #expect(!arrived, "so the message filed into Alpha waits for a later run")
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
            let keptItsRun = OtherFolderShared<Bool>(false)
            let account = try w.account()
            let accountId = w.accountId
            let engine = w.engine
            await w.watchSlices { _ in
                guard !secondStart.set() else { return }
                // A pass due by its clock ends while the run's first slice goes on.
                let running = await engine.otherFolderRunTasks[accountId]
                await engine.startOtherFolderRun(account: account)
                let after = await engine.otherFolderRunTasks[accountId]
                keptItsRun.set(running != nil && after == running)
            }
            let start = w.server.recordedCommands().count
            try await w.runOnce()
            #expect(secondStart.isSet, "setup: a second start came during the run")
            #expect(keptItsRun.get, "the second start left the running run as the account's one run")
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

    @Test("With no change tracking, a run lists a changed folder and runs no deletion check after it: the check's walk could outlast the slice, and the weekly whole-folder check removes what it would")
    func aRunsListingRunsNoDeletionCheck() async throws {
        try await Self.withWorld("no-deletion-check", .plain) { w in
            // Alpha owes a deletion check (a due mark), and a rule files a new
            // message there, so the run lists it.
            let alphaId = w.id(Self.alpha)
            try await w.pool.write { db in
                var state = FolderChangeState(raw: nil)
                state.markListingDue()
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [state.encoded, alphaId])
            }
            let uid = w.nextUid(in: Self.alpha)
            w.deliver(uid, to: Self.alpha)
            let start = w.server.recordedCommands().count
            try await w.runOnce()
            let arrived = try w.holds(uid, in: Self.alpha)
            #expect(arrived, "the run listed Alpha, and its new message arrived")
            let searches = w.commands(naming: Self.alpha, since: start).filter { $0.uppercased().contains("SEARCH") }
            #expect(searches.isEmpty, "no deletion check in the run: \(searches)")
            let alpha = try w.folder(Self.alpha)
            let stillOwed = FolderChangeState(raw: alpha.changeState).listingDue
            #expect(stillOwed, "the owed check is left as it was")
        }
    }

    // MARK: Timing (sync timing promises 1, 2, 3 and 8)

    /// A new-mail signal's way into the engine, as the app sends it, each with
    /// its caller's deadline: the foreground poll (`AccountManager.foregroundSyncOne`),
    /// an IDLE new-mail event (`SyncScheduler.backgroundPoll` ->
    /// `AccountManager.backgroundPollRun`) and a silent push
    /// (`SyncScheduler.syncStartup(inboxOnly: true)` -> `backgroundPollRun`).
    enum TriggerEntry: String, CaseIterable, Sendable {
        case poll
        case idle
        case push

        /// Sends the trigger. True when it found another pass of the account
        /// holding the turn and returned at once.
        func send(to engine: SyncEngine, account: Account) async throws -> Bool {
            switch self {
            case .poll:
                let deadline = Date().addingTimeInterval(SyncConfig.perAccountSyncTimeoutSeconds)
                return try await engine.syncOrFollowUp(account: account, deadline: deadline) == nil
            case .idle, .push:
                let deadline = Date().addingTimeInterval(SyncConfig.backgroundPerAccountTimeoutSeconds)
                return try await engine.backgroundDeltaSync(account: account, inboxOnly: self == .push, deadline: deadline) == nil
            }
        }
    }

    @Test("A new-mail trigger that finds a run's slice holding the turn asks for its stage 2 without waiting, and that stage 2 reads when the slice ends, before the run's next slice: from the poll, an IDLE event and a push",
          arguments: TriggerEntry.allCases)
    func aTriggerDuringASliceWaitsAtMostThatSlice(_ entry: TriggerEntry) async throws {
        try await Self.withWorld("trigger-\(entry.rawValue)", .plain) { w in
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
            // A failure path disarms the slice hook first, so no later slice
            // holds a read nobody releases.
            func stop(_ reason: Comment) async {
                Issue.record(reason)
                await w.watchSlices()
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

            let foundBusy: Bool
            do {
                foundBusy = try await entry.send(to: engine, account: account)
            } catch {
                await w.watchSlices()
                w.releaseStatus(of: first.get)
                await w.settle()
                throw error
            }
            let wanted = await engine.syncFollowUpWanted.contains(accountId)
            #expect(foundBusy, "the \(entry) trigger found the account busy and did not wait")
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
                await w.watchSlices()
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
                await w.watchSlices()
                if let path = first.get { server.releaseFetchAfterSnapshot(in: path) }
                await w.settle()
                return
            }
            guard let firstPath = first.get else {
                Issue.record("precondition: the first slice named its first folder")
                await w.watchSlices()
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

    // MARK: Progress on a slow link (#1358)

    /// Runs in a row whose first folder's read the slice's time cuts.
    static let cutRuns = 2

    @Test("A run whose first folder's read the slice's time cuts counts that folder as tried and reads the next folders, run after run; a later run reads the cut folder first and brings its mail",
          arguments: Server.allCases)
    func aCutFolderDoesNotStopTheRun(server kind: Server) async throws {
        try await Self.withWorld("cut", kind) { w in
            if kind == .qresync {
                // Each folder's bookmark first, as in `ruleFiledMailArrives`, so
                // every read below is a read from a bookmark.
                try await w.runOnce()
                try await w.drainCatchUp()
            }
            var cutPath: String?
            var cutUids: [Int] = []
            for runNumber in 1...Self.cutRuns {
                w.recorder.reset()
                let uids = Self.others.map { w.nextUid(in: $0) }
                for (path, uid) in zip(Self.others, uids) { w.deliver(uid, to: path) }
                // The run's first slice: its first folder's read is held.
                let first = OtherFolderShared<String?>(nil)
                await w.watchSlices { folderIds in
                    guard first.get == nil, folderIds.count == Self.others.count else { return }
                    let path = w.path(ofId: folderIds[0])
                    first.set(path)
                    w.holdStatus(of: path)
                }
                let account = try w.account()
                await w.engine.startOtherFolderRun(account: account)
                guard await OneSyncAtATimeTests.eventually({ w.isHoldingStatus(of: first.get) }) else {
                    Issue.record("run \(runNumber): precondition: the run's first slice holds its first folder's read")
                    await w.watchSlices()
                    w.releaseStatus(of: first.get)
                    await w.settle()
                    return
                }
                // The slice's time runs out while that read is held.
                w.offset.add(SyncConfig.catchUpSliceSeconds + 1)
                w.releaseStatus(of: first.get)
                await w.settle()
                await w.watchSlices()

                let held = try #require(first.get)
                let otherPath = Self.others.first { $0 != held }
                let other = try #require(otherPath)
                if let cutPath {
                    #expect(held == cutPath, "run \(runNumber): the folder cut last run is read first again")
                }
                cutPath = held
                let heldUid = uids[Self.others.firstIndex(of: held) ?? 0]
                let otherUid = uids[Self.others.firstIndex(of: other) ?? 0]
                cutUids.append(heldUid)
                let otherArrived = try w.holds(otherUid, in: other)
                let heldArrived = try w.holds(heldUid, in: held)
                let asked = w.runSlices.map(\.folderIds)
                let expected = [[w.id(held), w.id(other)], [w.id(other)]]
                #expect(otherArrived, "run \(runNumber): the run went on past the cut folder and brought \(other)'s new mail")
                #expect(!heldArrived, "run \(runNumber): precondition: the cut folder's read brought nothing")
                #expect(asked == expected,
                        "run \(runNumber): a slice for both folders, then one for the folder after the cut one: \(asked)")
            }

            // The next run, on a link that answers: the cut folder first, and its mail arrives.
            let cut = try #require(cutPath)
            w.recorder.reset()
            try await w.runOnce()
            let firstAsked = w.runSlices.first?.folderIds.first
            let cutId = w.id(cut)
            #expect(firstAsked == cutId, "the next run reads the folder cut in every earlier run first")
            for uid in cutUids {
                let arrived = try w.holds(uid, in: cut)
                #expect(arrived, "\(cut): its message \(uid) arrived")
            }
        }
    }

    /// One change read of the other folders in `scope`, straight from the
    /// reader, whose first folder's STATUS the server holds until the read's
    /// time has run out (the read's clock moved past its end), then answers.
    /// The folders' changes by folder id; nil on a failed precondition.
    static func readCutAtTheFirstFolder(_ w: World, scope: ChangeScope) async throws -> [String: FolderChanges]? {
        let account = try w.account()
        let folders = try others.map { SyncEngine.changeFolder(try w.folder($0), isSynced: true) }
        let offset = w.offset
        let context = ChangeContext(
            deadline: offset.now().addingTimeInterval(SyncConfig.catchUpSliceSeconds),
            clock: { offset.now() }, onProgress: { _ in })
        let request = ChangeRequest(
            folders: folders, scope: scope, recheck: [:], context: context,
            localRows: SyncEngineCatchUpRowReader(pool: PrioritizedDatabase(pool: w.pool)))
        let first = others[0]
        w.holdStatus(of: first)
        let provider = w.provider
        let since = ChangeCursor(account: account.lastHistoryId)
        let read = Task { try await provider.fetchChanges(since: since, request: request) }
        guard await OneSyncAtATimeTests.eventually({ w.isHoldingStatus(of: first) }) else {
            Issue.record("precondition: \(scope): \(first)'s STATUS is held")
            w.releaseStatus(of: first)
            _ = await read.result
            return nil
        }
        offset.add(SyncConfig.catchUpSliceSeconds + 1)
        w.releaseStatus(of: first)
        let set = try await read.value
        return set.map { answer in Dictionary(answer.folders.map { ($0.folderId, $0) }, uniquingKeysWith: { a, _ in a }) }
    }

    @Test("The IMAP reader reports a run's folder whose STATUS it sent and the slice's time cut apart from a folder it never reached, and never on a pass")
    func theReaderReportsACutReadApart() async throws {
        try await Self.withWorld("reader-cut", .qresync) { w in
            for path in Self.others { w.deliver(w.nextUid(in: path), to: path) }
            let first = w.id(Self.others[0])
            let second = w.id(Self.others[1])

            let run = try await Self.readCutAtTheFirstFolder(w, scope: .otherFolders)
            let runFirst = run?[first]
            let runSecond = run?[second]
            var runFirstNotRun = false
            if case .notRun = runFirst?.status { runFirstNotRun = true }
            #expect(runFirstNotRun && runFirst?.readCut == true,
                    "a run: the folder whose STATUS answered after the read's end is cut")
            // Reported, not left out: an absent second folder would pass a bare
            // "not cut" check.
            var runSecondNotRun = false
            if case .notRun = runSecond?.status { runSecondNotRun = true }
            #expect(runSecondNotRun && runSecond?.readCut == false,
                    "a run: the folder never reached is reported not run, with no cut mark")

            let pass = try await Self.readCutAtTheFirstFolder(w, scope: .all)
            let passFirst = pass?[first]
            var passFirstNotRun = false
            if case .notRun = passFirst?.status { passFirstNotRun = true }
            #expect(passFirstNotRun && passFirst?.readCut == false,
                    "a pass: the same cut folder is not run, with no cut mark")
        }
    }

    // MARK: A slow session check (sync timing: the slice's whole time for its first folder)

    /// One change read of the other folders, made as a run's slice makes it
    /// (`SyncEngine.otherFolderReadContext`), on a clock that stands still until
    /// the test moves it. The server holds the pass-start NOOP until the clock
    /// is `heldFor` past the slice's start, then answers it. The folders'
    /// changes by folder id, and the commands sent after that NOOP; nil on a
    /// failed precondition.
    static func readAfterASlowSessionCheck(
        _ w: World, heldFor: TimeInterval
    ) async throws -> (folders: [String: FolderChanges], afterCheck: [String])? {
        let account = try w.account()
        let folders = try others.map { SyncEngine.changeFolder(try w.folder($0), isSynced: true) }
        let start = Date()
        let clock = IMAPChangeEngineTests.StillClock(start)
        let context = SyncEngine.otherFolderReadContext(
            sliceDeadline: start.addingTimeInterval(SyncConfig.catchUpSliceSeconds), clock: { clock.read() })
        let request = ChangeRequest(
            folders: folders, scope: .otherFolders, recheck: [:], context: context,
            localRows: SyncEngineCatchUpRowReader(pool: PrioritizedDatabase(pool: w.pool)))
        let logStart = w.server.recordedCommands().count
        w.server.holdNextCommand(containing: "NOOP")
        let provider = w.provider
        let since = ChangeCursor(account: account.lastHistoryId)
        let read = Task { try await provider.fetchChanges(since: since, request: request) }
        guard await OneSyncAtATimeTests.eventually({ w.server.isHoldingCommand(containing: "NOOP") }) else {
            Issue.record("precondition: the pass-start NOOP is held")
            w.server.releaseHeldCommand(containing: "NOOP")
            _ = await read.result
            return nil
        }
        clock.set(start.addingTimeInterval(heldFor))
        w.server.releaseHeldCommand(containing: "NOOP")
        let set = try await read.value
        let sent = Array(w.server.recordedCommands().dropFirst(logStart))
        guard let check = sent.firstIndex(where: { $0.uppercased().hasPrefix("NOOP") }) else {
            Issue.record("precondition: the read sent its NOOP: \(sent)")
            return nil
        }
        let changes = Dictionary(
            (set?.folders ?? []).map { ($0.folderId, $0) }, uniquingKeysWith: { a, _ in a })
        return (changes, Array(sent[(check + 1)...]))
    }

    /// A request about a mailbox (its STATUS, SELECT, a FETCH or SEARCH on it),
    /// as opposed to the session's own NOOP or LOGOUT.
    static func isFolderRequest(_ command: String) -> Bool {
        let upper = command.uppercased()
        return ["STATUS", "SELECT", "EXAMINE", "UID", "FETCH", "SEARCH"].contains { upper.hasPrefix($0) }
            || (["INBOX"] + others).contains { names(command, $0) }
    }

    /// Sync timing (the turn's bound; owner: "use the whole turn"). A slice
    /// whose pass-start NOOP answers after the read's share of the slice, but
    /// before the slice's end, still reads its first folder, and starts no
    /// folder after it; a slice whose NOOP answers after the slice's end
    /// starts no request at all. So a slow session check never leaves a slice
    /// with nothing read, and no request starts after the slice's end: the
    /// turn ends by the slice's end plus one request. RED while the first
    /// folder, like the rest, could start only within the read's share.
    @Test("A slice whose session check answers late still reads its first folder, and starts no request after the slice's end",
          arguments: Server.allCases)
    func aSlowSessionCheckStillReadsTheFirstFolder(_ kind: Server) async throws {
        try await Self.withWorld("slow-check", kind) { w in
            let first = Self.others[0]
            let second = Self.others[1]
            let readEnd = SyncConfig.catchUpSliceSeconds * SyncConfig.otherFolderReadShare
            let betweenReadEndAndSliceEnd = (readEnd + SyncConfig.catchUpSliceSeconds) / 2

            guard let late = try await Self.readAfterASlowSessionCheck(w, heldFor: betweenReadEndAndSliceEnd)
            else { return }
            let firstRead = late.folders[w.id(first)]
            var firstNotRun = firstRead == nil
            if case .notRun = firstRead?.status { firstNotRun = true }
            let firstAsked = late.afterCheck.contains { Self.names($0, first) }
            #expect(firstAsked && !firstNotRun && firstRead?.readCut == false,
                    "the NOOP answered after the read's share, before the slice's end: \(first) is still read: \(late.afterCheck)")
            let secondRead = late.folders[w.id(second)]
            var secondNotRun = false
            if case .notRun = secondRead?.status { secondNotRun = true }
            let secondAsked = late.afterCheck.contains { Self.names($0, second) }
            #expect(!secondAsked && secondNotRun && secondRead?.readCut == false,
                    "a folder after the first still starts only within the read's share: \(late.afterCheck)")

            guard let past = try await Self.readAfterASlowSessionCheck(w, heldFor: SyncConfig.catchUpSliceSeconds + 1)
            else { return }
            let requests = past.afterCheck.filter(Self.isFolderRequest)
            #expect(requests.isEmpty, "the NOOP answered after the slice's end: no request starts: \(requests)")
            for path in Self.others {
                let read = past.folders[w.id(path)]
                var notRun = false
                if case .notRun = read?.status { notRun = true }
                #expect(notRun && read?.readCut == false, "\(path): reported not run, with no cut mark")
            }
        }
    }

    // MARK: The listing's bound (sync timing promise 1)

    /// The request limit a test gives a run's listing: long enough for the
    /// listing to reach its held FETCH, short enough that the limit plus
    /// `stageTwoReadSeconds` stays under the default limit.
    static let shortRequestSeconds: TimeInterval = 0.75

    /// The room the follow-up's stage 2 has, after the listing's limit ends the
    /// slice and before the default limit could have: the rest of the slice and
    /// the stage 2's own read of the Inbox, against the local server.
    static let stageTwoReadSeconds: TimeInterval = 1

    /// What the bounded-listing test's slice hook saw and started, and what the
    /// test waits on: each is an event, set once.
    struct HeldListingProbe: Sendable {
        /// The changed folder whose listing's answer the server holds.
        let held = OtherFolderShared<String?>(nil)
        /// Whether the trigger sent inside the slice found the turn held: it
        /// asked for a follow-up and returned without a pass.
        let triggerFoundTheTurnHeld = OtherFolderShared<Bool?>(nil)
        /// The follow-up stage 2, started inside the slice.
        let followUp = OtherFolderShared<Task<Bool?, any Error>?>(nil)
        /// Whether the follow-up was in line for the turn before the slice went on.
        let followUpInLine = OtherFolderShared<Bool>(false)
        /// When the hook returned: the slice's provider work, and so the
        /// listing's request, starts after this.
        let listingMayStart = OtherFolderShared<Date?>(nil)
        let followUpEnded = OtherFolderShared<Bool>(false)
        let runEnded = OtherFolderShared<Bool>(false)
    }

    @Test("With no change tracking, a run's listing is bounded as an older-mail request: while the server holds its answer, a new-mail trigger finds the slice holding the turn and its read waits at most the request limit, the run ends without the answer, owes no deep listing and marks nothing due, still lists the other folder, and a later run lists the folder before the old answer comes")
    func aRunsListingIsBoundedLikeAnOlderMailRequest() async throws {
        #expect(Self.shortRequestSeconds + Self.stageTwoReadSeconds < SyncConfig.catchUpRequestTimeoutSeconds,
                "precondition: a read bounded by the listing's limit is told apart from one bounded by the default")
        #expect(SyncConfig.fullSyncDeepEveryN > 1, "precondition: an owed deep listing is told apart from none")
        try await Self.withWorld("listing-bound", .plain) { w in
            let server = w.server
            let uids = Self.others.map { w.nextUid(in: $0) }
            for (path, uid) in zip(Self.others, uids) { w.deliver(uid, to: path) }
            let account = try w.account()
            let engine = w.engine
            let accountId = w.accountId
            let inboxUid = w.nextUid(in: "INBOX")
            let probe = HeldListingProbe()
            let streaks = otherFolderSkipStreaks(try Self.others.map { try w.folder($0).id })
            defer { restoreOtherFolderSkipStreaks(streaks) }
            #expect(!streaks.contains { otherFolderOwesDeepListing($0.folderId) },
                    "precondition: no folder owes a deep listing before the run")
            // Inside the run's first slice, holding the turn, before its provider
            // work: the server will hold the first changed folder's listing
            // answer, and new mail comes. The poll's trigger, sent from its own
            // task as the scheduler sends it, finds the turn held, so it asks for
            // the follow-up stage 2 and returns at once; the follow-up then waits
            // in line for the turn (sync timing promise 1).
            await w.watchSlices { folderIds in
                guard probe.held.get == nil, folderIds.count == Self.others.count else { return }
                let path = w.path(ofId: folderIds[0])
                probe.held.set(path)
                server.holdNextFetchAfterSnapshot(in: path)
                w.deliver(inboxUid, to: "INBOX")
                let trigger = await Task.detached { try await engine.syncOrFollowUp(account: account, deadline: nil) }.result
                var foundTheTurnHeld = false
                if case .success(.none) = trigger { foundTheTurnHeld = true }
                probe.triggerFoundTheTurnHeld.set(foundTheTurnHeld)
                probe.followUp.set(Task.detached { () async throws -> Bool? in
                    defer { probe.followUpEnded.set(true) }
                    return try await engine.followUpPass(accountId: accountId, mayStart: { true })
                })
                let inLine = await OneSyncAtATimeTests.eventually {
                    await engine.syncPassWaiterCountForTesting(accountId: accountId) > 0
                }
                probe.followUpInLine.set(inLine)
                probe.listingMayStart.set(Date())
            }
            var run = SyncEngine.CatchUpRun(
                storageLimitInForce: false, deadline: nil, sliceSeconds: SyncConfig.catchUpSliceSeconds,
                intervalSeconds: 0, clock: { Date() })
            run.workSeconds = SyncConfig.otherFolderRunSeconds
            run.readsOtherFolders = true
            run.requestTimeoutSeconds = Self.shortRequestSeconds
            let theRun = run
            let runTask = Task {
                _ = await engine.runCatchUpRun(account: account, run: theRun)
                probe.runEnded.set(true)
            }
            // Every exit, a failed check or a throw included, lets the held answer
            // go BEFORE it joins the run and the follow-up, so neither join can
            // wait on the withheld answer.
            func releaseAndEnd() async {
                await w.watchSlices()
                if let path = probe.held.get { server.releaseFetchAfterSnapshot(in: path) }
                await runTask.value
                _ = try? await probe.followUp.get?.value
            }
            do {
                try await Self.checkTheBoundedListing(w, run: theRun, account: account, uids: uids, inboxUid: inboxUid, probe: probe)
            } catch {
                await releaseAndEnd()
                throw error
            }
            await releaseAndEnd()
        }
    }

    /// The body of `aRunsListingIsBoundedLikeAnOlderMailRequest`, from the
    /// slice's hook on. It never joins the run or the follow-up while the answer
    /// may be held: it waits for events with a bound, and returns after a failed
    /// check that a later step would wait on; the caller releases the answer,
    /// then joins.
    static func checkTheBoundedListing(
        _ w: World, run: SyncEngine.CatchUpRun, account: Account, uids: [Int], inboxUid: Int,
        probe: HeldListingProbe
    ) async throws {
        let engine = w.engine
        func holdingListing() -> Bool {
            guard let path = probe.held.get else { return false }
            return w.server.isHoldingFetchAfterSnapshot(in: path)
        }
        guard await OneSyncAtATimeTests.eventually({ probe.listingMayStart.get != nil }),
              let held = probe.held.get, let listingMayStart = probe.listingMayStart.get else {
            Issue.record("precondition: the run's first slice asked for the changed folders")
            return
        }
        let otherPath = others.first { $0 != held }
        let heldUid = uids[others.firstIndex(of: held) ?? 0]
        let triggerFoundTheTurnHeld = probe.triggerFoundTheTurnHeld.get
        let followUpInLine = probe.followUpInLine.get
        #expect(triggerFoundTheTurnHeld == true, "the trigger found the run's slice holding the turn and asked for a follow-up")
        #expect(followUpInLine, "the follow-up waited in line for the turn")

        // The follow-up gets the turn when the slice ends. The listing's request
        // started after `listingMayStart`, and its answer stays withheld until the
        // test releases it, so a slice that only the default limit ended would
        // let the follow-up in no earlier than `catchUpRequestTimeoutSeconds`
        // after it. A follow-up done before then was let in by the listing's own
        // limit (sync timing promise 1).
        let room = SyncConfig.catchUpRequestTimeoutSeconds - Date().timeIntervalSince(listingMayStart)
        let followedUp = await OneSyncAtATimeTests.eventually(seconds: room) { probe.followUpEnded.get }
        let answerStillHeld = holdingListing()
        let newMailRead = try w.holds(inboxUid, in: "INBOX")
        #expect(followedUp, "the follow-up's read ended within the listing's request limit, not the default one")
        #expect(answerStillHeld, "while the listing's answer was still held")
        #expect(newMailRead, "the follow-up's read brought the new mail")
        guard followedUp, let followUp = probe.followUp.get else { return }
        let ranStageTwo = try await followUp.value
        #expect(ranStageTwo != nil, "the follow-up ran stage 2: the trigger was not dropped")

        // A second run would wait in line behind a run still holding the turn,
        // which only the withheld answer could end: none after a failed check.
        let endedWhileHeld = await OneSyncAtATimeTests.eventually { probe.runEnded.get }
        #expect(endedWhileHeld, "the run ended while the listing's answer was still held: the listing did not hold the turn")
        guard endedWhileHeld else { return }

        // The answer is still withheld: the listing given up owes nothing, and a
        // later run lists the folder again without waiting for it.
        let heldBefore = try w.holds(heldUid, in: held)
        let heldFolder = try w.folder(held)
        let markedDue = FolderChangeState(raw: heldFolder.changeState).listingDue
        let owesDeepListing = otherFolderOwesDeepListing(heldFolder.id)
        let otherArrived = try otherPath.map { try w.holds(uids[others.firstIndex(of: $0) ?? 0], in: $0) }
        _ = await engine.runCatchUpRun(account: account, run: run)
        let relisted = try w.holds(heldUid, in: held)

        #expect(!heldBefore, "the listing given up wrote nothing")
        #expect(heldFolder.lastKnownUidNext == OtherFolderIMAPTests.held.count + 1, "and \(held)'s counters stayed as they were, so it stayed changed")
        #expect(!markedDue, "it marked nothing due")
        #expect(!owesDeepListing, "and owes no deep listing")
        #expect(otherArrived == true, "the run still listed the other folder, and its new mail arrived")
        #expect(relisted, "a later run listed \(held) while the old answer was still withheld, and its new mail arrived")
    }

    /// The forms of a SELECT or EXAMINE of `path`, as `statusFragments` names a STATUS.
    static func selectFragments(_ path: String) -> [String] {
        ["SELECT", "EXAMINE"].flatMap { verb in ["\(verb) \(path)", "\(verb) \"\(path)\""] }
    }

    @Test("With no change tracking, a run's listing is bounded as one whole request, its SELECT included: while the server holds the folder's SELECT, the listing is given up at its request limit, writes nothing, the run still lists the other folder, and a later run lists the folder")
    func aListingsSelectIsWithinItsBound() async throws {
        #expect(Self.shortRequestSeconds < SyncConfig.catchUpRequestTimeoutSeconds,
                "precondition: a listing bounded by its own limit is told apart from one bounded by the default")
        try await Self.withWorld("listing-select", .plain) { w in
            let server = w.server
            let uids = Self.others.map { w.nextUid(in: $0) }
            for (path, uid) in zip(Self.others, uids) { w.deliver(uid, to: path) }
            let account = try w.account()
            let engine = w.engine
            let streaks = otherFolderSkipStreaks(try Self.others.map { try w.folder($0).id })
            defer { restoreOtherFolderSkipStreaks(streaks) }
            // Inside the run's first slice, before its provider work: the server
            // will hold the SELECT of the first changed folder's listing.
            let held = OtherFolderShared<String?>(nil)
            let listingMayStart = OtherFolderShared<Date?>(nil)
            await w.watchSlices { folderIds in
                guard held.get == nil, folderIds.count == Self.others.count else { return }
                let path = w.path(ofId: folderIds[0])
                held.set(path)
                for fragment in Self.selectFragments(path) { server.holdNextCommand(containing: fragment) }
                listingMayStart.set(Date())
            }
            var run = SyncEngine.CatchUpRun(
                storageLimitInForce: false, deadline: nil, sliceSeconds: SyncConfig.catchUpSliceSeconds,
                intervalSeconds: 0, clock: { Date() })
            run.workSeconds = SyncConfig.otherFolderRunSeconds
            run.readsOtherFolders = true
            run.requestTimeoutSeconds = Self.shortRequestSeconds
            let theRun = run
            let runEnded = OtherFolderShared<Bool>(false)
            let runTask = Task {
                _ = await engine.runCatchUpRun(account: account, run: theRun)
                runEnded.set(true)
            }
            func holdingSelect() -> Bool {
                guard let path = held.get else { return false }
                return Self.selectFragments(path).contains { server.isHoldingCommand(containing: $0) }
            }
            // Every exit lets the held SELECT go before it joins the run.
            func release() {
                guard let path = held.get else { return }
                for fragment in Self.selectFragments(path) { server.releaseHeldCommand(containing: fragment) }
            }
            func releaseAndEnd() async {
                await w.watchSlices()
                release()
                await runTask.value
            }
            guard await OneSyncAtATimeTests.eventually({ holdingSelect() }),
                  let heldPath = held.get, let mayStart = listingMayStart.get else {
                Issue.record("precondition: the run's listing sent its SELECT, and the server holds it")
                return await releaseAndEnd()
            }

            // The SELECT stays held until the test lets it go, so a run that only
            // the default limit, or none, could end would still be running
            // `catchUpRequestTimeoutSeconds` after the listing could start.
            let room = SyncConfig.catchUpRequestTimeoutSeconds - Date().timeIntervalSince(mayStart)
            let ended = await OneSyncAtATimeTests.eventually(seconds: room) { runEnded.get }
            let stillHeld = holdingSelect()
            #expect(ended, "the run ended within the listing's request limit, not the default one")
            #expect(stillHeld, "while the folder's SELECT was still held")
            guard ended else { return await releaseAndEnd() }

            let heldUid = uids[Self.others.firstIndex(of: heldPath) ?? 0]
            let heldBefore = try w.holds(heldUid, in: heldPath)
            let heldFolder = try w.folder(heldPath)
            let otherPath = Self.others.first { $0 != heldPath }
            let otherArrived = try otherPath.map { try w.holds(uids[Self.others.firstIndex(of: $0) ?? 0], in: $0) }
            await releaseAndEnd()
            _ = await engine.runCatchUpRun(account: account, run: theRun)
            let relisted = try w.holds(heldUid, in: heldPath)

            #expect(!heldBefore, "the listing given up wrote nothing")
            #expect(heldFolder.lastKnownUidNext == OtherFolderIMAPTests.held.count + 1, "and \(heldPath)'s counters stayed as they were, so it stayed changed")
            #expect(otherArrived == true, "the run still listed the other folder, and its new mail arrived")
            #expect(relisted, "a later run listed \(heldPath), and its new mail arrived")
        }
    }

    // MARK: The weekly whole-folder check, end to end

    @Test("With no change tracking, the older-mail check removes a message gone from a syncable folder a day after the folder's last check, and one gone from an other folder only a week after")
    func otherFolderWholeCheckIsWeeklyEndToEnd() async throws {
        try await Self.withWorld("weekly", .plain) { w in
            let gone = Self.held[2]
            for path in ["INBOX", Self.alpha] {
                w.server.setMessages(w.server.messages(in: path).filter { $0.uid != gone }, in: path)
            }
            let accountId = w.accountId
            let epoch = UInt32(Self.epoch)
            func lastCheck(daysAgo days: Double, _ paths: [String]) async throws {
                let state = IMAPCatchUpState(epoch: epoch, lastCompletedAt: Date().addingTimeInterval(-days * 86_400)).encoded()
                try await w.pool.write { db in
                    for path in paths {
                        try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [state, "\(accountId):\(path)"])
                    }
                }
            }
            try await lastCheck(daysAgo: 2, ["INBOX", Self.alpha])
            try await w.drainCatchUp()
            let inboxKept = try w.holds(gone, in: "INBOX")
            let alphaKeptAfterADay = try w.holds(gone, in: Self.alpha)
            #expect(!inboxKept, "the Inbox's check, due a day after its last, removed the message gone from it")
            #expect(alphaKeptAfterADay, "Alpha's check is not due before a week: its row stays")

            try await lastCheck(daysAgo: 8, [Self.alpha])
            try await w.drainCatchUp()
            let alphaKeptAfterAWeek = try w.holds(gone, in: Self.alpha)
            #expect(!alphaKeptAfterAWeek, "a week after Alpha's last check, its check removed the message gone from it")
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

    /// Delta records per page in `aBaselinePageNotPassedIsCut`: two, so the
    /// second page holds one message the device holds and one it does not.
    static let twoPerPage = 2

    /// One read of `path` as a slice of a run reads it (scope `.otherFolders`),
    /// with an allowance of one request (one delta page, no header batch) on a
    /// frozen clock, applied as the run applies it.
    static func runSliceRead(_ w: R.World, path: String) async throws -> FolderChanges {
        let folder = try w.folder(path)
        let account = try w.account()
        let now = Date()
        let context = ChangeContext(deadline: R.deadline(requests: 1, from: now), clock: { now }, onProgress: { _ in })
        let request = ChangeRequest(
            folders: [ChangeFolder(id: folder.id, path: folder.path, role: folder.role, cursor: folder.changeCursor,
                                   isSynced: true, heldSince: folder.oldestSyncedDate)],
            scope: .otherFolders, recheck: [:], context: context,
            localRows: SyncEngineCatchUpRowReader(pool: AppDatabase.syncPool))
        let read = try await w.provider.fetchChanges(since: ChangeCursor(account: account.lastHistoryId), request: request)
        let set = try #require(read)
        let found = set.folders.first { $0.folderId == folder.id }
        let changes = try #require(found)
        _ = try await w.pool.write { db in try SyncEngine.applyFolderChanges(changes, db: db) }
        return changes
    }

    @Test("Outlook: a run's baseline read that passes no page is reported cut, whatever held rows its page applies, so the run does not stay on that page; one that passed a page is not")
    func aBaselinePageNotPassedIsCut() async throws {
        let ids = ["c-1", "c-2", "c-3", "c-4"]
        try await R.withWorld(seeds: ids.map { R.seed($0, in: R.archive, daysAgo: 1) }) { w in
            // The device holds c-1 to c-3; c-4, within the held range, needs its header.
            for id in ids.dropLast() { try w.insertRow(id, in: w.archive, date: R.daysAgo(1)) }
            w.server.setDeltaMaxPageSize(Self.twoPerPage)

            // Page 1 (c-1, c-2: both held) passes; no request is left for page 2.
            let passed = try await Self.runSliceRead(w, path: w.archive)
            var passedIsBaseline = false
            if case .baselining = passed.status { passedIsBaseline = true }
            let passedMoved = passed.cursor != nil
            #expect(passedIsBaseline && passedMoved, "a page passed: the baseline moved")
            #expect(!passed.readCut, "a baseline that passed a page is not cut")

            // Page 2 (c-3 held, c-4 not): no request is left for c-4's header,
            // so the page is held back with c-3's record applied.
            let held = try await Self.runSliceRead(w, path: w.archive)
            var heldIsBaseline = false
            if case .baselining = held.status { heldIsBaseline = true }
            let heldRecords = held.records.map(\.messageId)
            let heldMoved = held.cursor != nil
            let rows = try w.rowIds(in: w.archive)
            #expect(heldIsBaseline && heldRecords == ["c-3"] && !heldMoved,
                    "precondition: the held page applies c-3 and keeps its place")
            #expect(held.readCut, "a baseline read that passed no page is cut")
            #expect(!rows.contains("c-4"), "c-4 is not in yet")
        }
    }
}

// MARK: - What a slice reports

/// What one slice of an other-folder run reports (#1110, #1358), with a
/// scripted reader. A folder whose read the reader started and the slice's
/// time cut (`FolderChanges.readCut`), or a baseline that neither moved nor
/// failed, is tried (left out of the rest of the run, and behind the others in
/// the next run's order) when the slice did nothing else, and stays pending
/// while the slice moved or failed another folder. A folder the reader sent
/// nothing for stays pending, so a slice that read nothing ends the run. The
/// run never takes the reader's account bookmark or folder list, and a reader
/// that throws, or none, reads nothing.
@Suite("Other folders: what a slice reports (#1110)", .serialized, .processGlobalState)
struct OtherFolderSliceRuleTests {

    struct Failure: Error {}

    struct World: Sendable {
        let pool: DatabasePool
        let accountId: String
        let mock: MockEmailProvider

        var inboxId: String { "\(accountId):INBOX" }
        var alphaId: String { "\(accountId):Alpha" }
        var betaId: String { "\(accountId):Beta" }

        func account() throws -> Account {
            let accountId = accountId
            let account = try pool.read { db in try Account.fetchOne(db, key: accountId) }
            return try #require(account)
        }

        /// One slice over Alpha then Beta on `engine`, the reader answering
        /// with `answer` (nil: no reader).
        func slice(
            on engine: SyncEngine, _ answer: (@Sendable (ChangeRequest) throws -> ChangeSet?)?
        ) async throws -> CatchUpSliceResult {
            if let answer {
                await mock.setChangeReader { _, request in try answer(request) }
            } else {
                await mock.setChangeReader(nil)
            }
            let account = try account()
            return await engine.readOtherFolders(
                account: account, provider: mock, folderIds: [alphaId, betaId],
                context: CatchUpContext(deadline: .distantFuture, clock: { Date() }))
        }
    }

    static func withWorld(_ body: (World) async throws -> Void) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "other-slice-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try await pool.write { db in
            try db.execute(sql: "UPDATE account SET lastHistoryId = '100' WHERE id = ?", arguments: [accountId])
        }
        for (path, role) in [("INBOX", FolderRole.inbox), ("Alpha", .custom), ("Beta", .custom)] {
            try FolderEpochTestFixture.insertFolder(
                accountId: accountId, path: path, role: role, pool: pool, lastKnownUidNext: 1, lastKnownUidValidity: 1)
        }
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        // The shared state is cleaned on every exit, a throw included, before
        // the database is restored.
        func cleanUp() async {
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            await UnreadCountManager.shared.awaitIdleForTesting()
        }
        do {
            try await body(World(pool: pool, accountId: accountId, mock: MockEmailProvider()))
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    /// The reader's answer: `statuses` by folder id, `.notRun` (nothing sent) for the rest.
    static func answer(_ request: ChangeRequest, _ statuses: [String: FolderChanges]) -> ChangeSet {
        ChangeSet(account: .keep, folderList: nil, folders: request.folders.map {
            statuses[$0.id] ?? FolderChanges(folderId: $0.id, status: .notRun)
        })
    }

    /// A folder whose read the reader started and the slice's time cut.
    static func cut(_ folderId: String) -> FolderChanges {
        var changes = FolderChanges(folderId: folderId, status: .notRun)
        changes.readCut = true
        return changes
    }

    /// A baseline read that passed no page, which the reader reports cut even
    /// though its bookmark changed (an Outlook page held back: its held rows
    /// apply and its place stays).
    static func cutBaseline(_ folderId: String) -> FolderChanges {
        var changes = FolderChanges(folderId: folderId, status: .baselining, cursor: "same page")
        changes.readCut = true
        return changes
    }

    struct Case: Sendable {
        let name: String
        let statuses: [String: FolderChanges]
        let inFlight: Set<String>
        let progressed: Set<String>
        let finished: Set<String>
        /// The next run's order after this slice.
        let nextOrder: [String]
    }

    @Test("A cut folder is tried when the slice did nothing else and stays pending while it moved or failed another; a folder not reached stays pending, ahead of a baseline that moved")
    func cutFoldersAndFoldersNotReached() async throws {
        try await Self.withWorld { w in
            let alpha = w.alphaId
            let beta = w.betaId
            let cases = [
                Case(name: "a cut read, then a folder not reached",
                     statuses: [alpha: Self.cut(alpha)],
                     inFlight: [alpha], progressed: [], finished: [], nextOrder: [beta, alpha]),
                Case(name: "a baseline that neither moved nor failed, then a folder not reached",
                     statuses: [alpha: FolderChanges(folderId: alpha, status: .baselining)],
                     inFlight: [alpha], progressed: [], finished: [], nextOrder: [beta, alpha]),
                Case(name: "a baseline the reader reports cut, its bookmark changed, then a folder not reached",
                     statuses: [alpha: Self.cutBaseline(alpha)],
                     inFlight: [alpha], progressed: [], finished: [], nextOrder: [beta, alpha]),
                Case(name: "a read, then a cut read",
                     statuses: [alpha: FolderChanges(folderId: alpha, status: .tracked), beta: Self.cut(beta)],
                     inFlight: [], progressed: [alpha], finished: [alpha], nextOrder: [beta, alpha]),
                // A baseline that moved goes behind the folders the slice did
                // not finish, so a long baseline first in the order cannot take
                // every slice's read share before them.
                Case(name: "a baseline that moved, then a cut read",
                     statuses: [alpha: FolderChanges(folderId: alpha, status: .baselining, cursor: "moved"), beta: Self.cut(beta)],
                     inFlight: [], progressed: [alpha], finished: [], nextOrder: [beta, alpha]),
                Case(name: "a baseline that moved, then a folder not reached",
                     statuses: [alpha: FolderChanges(folderId: alpha, status: .baselining, cursor: "moved")],
                     inFlight: [], progressed: [alpha], finished: [], nextOrder: [beta, alpha]),
                Case(name: "a failed read, then a cut read",
                     statuses: [alpha: FolderChanges(folderId: alpha, status: .failed(Failure())), beta: Self.cut(beta)],
                     inFlight: [alpha], progressed: [], finished: [], nextOrder: [beta, alpha]),
                Case(name: "nothing sent to either folder",
                     statuses: [:],
                     inFlight: [], progressed: [], finished: [], nextOrder: [alpha, beta]),
            ]
            for item in cases {
                // A fresh engine: the run's order is kept in memory per engine.
                let engine = SyncEngine()
                let statuses = item.statuses
                let result = try await w.slice(on: engine) { request in Self.answer(request, statuses) }
                let order = try await engine.otherFolderReadOrder(accountId: w.accountId)
                #expect(result.inFlightFolderIds == item.inFlight, "\(item.name): tried or failed")
                #expect(result.progressedFolderIds == item.progressed, "\(item.name): moved")
                #expect(result.finishedFolderIds == item.finished, "\(item.name): read once")
                #expect(order == item.nextOrder, "\(item.name): the next order")
            }
        }
    }

    @Test("The run's order forgets a folder that is gone: its read time is dropped, and a folder made later at its id is read first, as never read")
    func aGoneFolderLeavesTheOrder() async throws {
        try await Self.withWorld { w in
            let engine = SyncEngine()
            let accountId = w.accountId
            let alpha = w.alphaId
            let beta = w.betaId
            _ = try await w.slice(on: engine) { request in
                Self.answer(request, [
                    alpha: FolderChanges(folderId: alpha, status: .tracked),
                    beta: FolderChanges(folderId: beta, status: .failed(Failure())),
                ])
            }
            let stampedBefore = await engine.otherFolderAttemptedAt[accountId].map { Set($0.keys) }
            #expect(stampedBefore == [alpha, beta], "precondition: the slice recorded both folders' reads")

            try await w.pool.write { db in
                try db.execute(sql: "DELETE FROM folder WHERE id = ?", arguments: [alpha])
            }
            let order = try await engine.otherFolderReadOrder(accountId: accountId)
            let stampedAfter = await engine.otherFolderAttemptedAt[accountId].map { Set($0.keys) }
            #expect(order == [beta], "the gone folder is not in the order")
            #expect(stampedAfter == [beta], "and its read time is dropped")

            try FolderEpochTestFixture.insertFolder(
                accountId: accountId, path: "Alpha", role: .custom, pool: w.pool, lastKnownUidNext: 1, lastKnownUidValidity: 1)
            let again = try await engine.otherFolderReadOrder(accountId: accountId)
            #expect(again == [alpha, beta], "a folder made later at its id is read first, as never read")
        }
    }

    @Test("A run's listing whose window read the slice's end leaves unstarted has not started: nothing of it is asked or written, it owes no deep listing and gets no due mark, and the folder stays changed for a later slice")
    func aListingCutBeforeItsReadHasNotStarted() async throws {
        try await Self.withWorld { w in
            #expect(SyncConfig.fullSyncDeepEveryN > 1, "precondition: an owed deep listing is told apart from none")
            let alpha = w.alphaId
            let streaks = otherFolderSkipStreaks([alpha])
            defer { restoreOtherFolderSkipStreaks(streaks) }
            #expect(!otherFolderOwesDeepListing(alpha), "precondition: the folder owes no deep listing before the listing")
            let before = try await w.pool.read { db in try Folder.fetchOne(db, key: alpha) }
            // The slice has time when the listing starts and none when its window
            // read would start: the clock is read once for each.
            let checks = OtherFolderShared<Int>(0)
            let start = Date()
            let sliceEnd = start.addingTimeInterval(SyncConfig.catchUpSliceSeconds)
            let slice = ChangeContext(deadline: sliceEnd, clock: {
                checks.set(checks.get + 1)
                return checks.get == 1 ? start : sliceEnd.addingTimeInterval(1)
            }, onProgress: { _ in })
            // Counters that moved since the folder's last listing.
            let observation = UntrackedObservation(messageCount: 3, uidNext: 4, highestModSeq: nil, uidValidity: 1)
            let refresh = try await SyncEngine().refreshUntrackedFolder(
                folderId: alpha, observation: observation, account: try w.account(), provider: w.mock,
                otherFolderSlice: ListingRequestBound(slice: slice, timeoutSeconds: SyncConfig.catchUpRequestTimeoutSeconds))
            let after = try await w.pool.read { db in try Folder.fetchOne(db, key: alpha) }
            let log = await w.mock.callLog
            let readSent = log.contains { $0.hasPrefix("fetchMessages(") }
            let owesDeepListing = otherFolderOwesDeepListing(alpha)
            let markedDue = FolderChangeState(raw: after?.changeState).listingDue
            #expect(checks.get == 2, "precondition: the listing started, and its window read found the slice over")
            #expect(refresh == .listingNotStarted, "the listing has not started, so a later slice lists the folder")
            #expect(!readSent, "the window read was not sent: \(log)")
            #expect(after?.lastKnownUidNext == before?.lastKnownUidNext && after?.totalCount == before?.totalCount,
                    "the folder's counters are as they were, so it stays changed")
            #expect(!markedDue, "no due mark")
            #expect(!owesDeepListing, "no deep listing owed")
        }
    }

    @Test("A slice takes no account bookmark and no folder list from its reader, and asks for the other-folder scope only, with no re-read list though a folder holds one, which stays for the passes")
    func aSliceIgnoresTheAccountParts() async throws {
        try await Self.withWorld { w in
            let before = try w.account().lastHistoryId
            // Alpha holds ids a pass would read again.
            let alphaId = w.alphaId
            let rereads = ["7", "9"]
            let seeded = FolderChangeState(recheck: rereads).encoded
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [seeded, alphaId])
            }
            func storedRereads() async throws -> [String] {
                let raw = try await w.pool.read { db in
                    try String.fetchOne(db, sql: "SELECT changeState FROM folder WHERE id = ?", arguments: [alphaId])
                }
                return FolderChangeState(raw: raw).recheck
            }
            let rereadsBefore = try await storedRereads()
            #expect(rereadsBefore == rereads, "precondition: Alpha holds its re-read list")
            let result = try await w.slice(on: SyncEngine()) { request in
                ChangeSet(account: .set("999"), folderList: .complete([]), folders: request.folders.map {
                    FolderChanges(folderId: $0.id, status: .tracked)
                })
            }
            let after = try w.account().lastHistoryId
            let accountId = w.accountId
            let folderIds = try await w.pool.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM folder WHERE accountId = ?", arguments: [accountId])
            }
            let asked = await w.mock.changeRequests.last?.request
            let askedIds = asked?.folders.map(\.id)
            let askedRereads = asked?.recheck.isEmpty
            let others: Set<String> = [w.alphaId, w.betaId]
            let all: Set<String> = [w.inboxId, w.alphaId, w.betaId]
            let order = [w.alphaId, w.betaId]
            #expect(result.finishedFolderIds == others, "both folders read once")
            #expect(after == before, "the account's bookmark is untouched")
            #expect(Set(folderIds) == all, "an empty complete folder list removed nothing")
            #expect(asked?.scope == .otherFolders, "the read was asked for the other folders")
            #expect(askedIds == order, "in the run's order")
            #expect(askedRereads == true, "with no re-read list")
            let rereadsAfter = try await storedRereads()
            #expect(rereadsAfter == rereads, "Alpha's re-read list stays for the passes")
        }
    }

    @Test("A slice whose reader throws, or a provider with no reader, reads nothing, so the run ends")
    func aReaderThatThrowsOrNoneReadsNothing() async throws {
        try await Self.withWorld { w in
            let thrown = try await w.slice(on: SyncEngine()) { _ in throw Failure() }
            let none = try await w.slice(on: SyncEngine(), nil)
            #expect(!thrown.progressed && thrown.inFlightFolderIds.isEmpty, "a throwing reader: nothing read, nothing tried")
            #expect(!none.progressed && none.inFlightFolderIds.isEmpty, "no reader: nothing read, nothing tried")
        }
    }

    @Test("A run whose slice reads nothing new ends with that slice, with time left: a reader that throws, one that sends nothing for any folder, or none")
    func aSliceThatReadsNothingEndsTheRun() async throws {
        try await Self.withWorld { w in
            let account = try w.account()
            let readers: [(name: String, answer: (@Sendable (ChangeRequest) throws -> ChangeSet?)?)] = [
                ("a reader that throws", { _ in throw Failure() }),
                ("a reader that sends nothing", { request in Self.answer(request, [:]) }),
                ("no reader", nil),
            ]
            for reader in readers {
                if let answer = reader.answer {
                    await w.mock.setChangeReader { _, request in try answer(request) }
                } else {
                    await w.mock.setChangeReader(nil)
                }
                // A fresh engine: the run's order is kept in memory per engine.
                let engine = SyncEngine()
                await engine.register(
                    accountId: w.accountId, provider: w.mock, workQueue: ProviderWorkQueue(provider: w.mock, maxConcurrency: 1))
                // A run that went on would take slice after slice: the third is
                // cancelled, so the test ends either way.
                let slices = OtherFolderShared<Int>(0)
                let running = OtherFolderShared<Task<Bool, Never>?>(nil)
                await engine.setCatchUpSliceStartHookForTesting { _ in
                    slices.set(slices.get + 1)
                    if slices.get >= 3 { running.get?.cancel() }
                }
                var run = SyncEngine.CatchUpRun(
                    storageLimitInForce: false, deadline: nil, sliceSeconds: SyncConfig.catchUpSliceSeconds,
                    intervalSeconds: 0, clock: { Date() })
                run.workSeconds = SyncConfig.otherFolderRunSeconds
                run.readsOtherFolders = true
                let theRun = run
                let task = Task { await engine.runCatchUpRun(account: account, run: theRun) }
                running.set(task)
                let progressed = await task.value
                await engine.setCatchUpSliceStartHookForTesting(nil)
                await engine.remove(accountId: w.accountId)
                #expect(slices.get == 1, "\(reader.name): the run took one slice and ended: \(slices.get) slices")
                #expect(!progressed, "\(reader.name): and read nothing")
            }
        }
    }
}
