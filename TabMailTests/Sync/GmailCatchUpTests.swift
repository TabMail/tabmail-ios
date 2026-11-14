/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

private let inboxPath = "INBOX"
private let allMailPath = GmailProvider.archivePath
private let labelPath = "Label_7"

/// ADR-IOS-107 for Gmail: the catch-up of server-side changes to OLDER mail (a
/// read or starred change, or a message leaving a folder) that no sync window and
/// no delta reaches. Since #766 the backfill worker runs it after the folders'
/// walk, in slices (`SyncEngine.runBackfill` → `runCatchUpRun`); before, the full
/// sync ran it.
///
/// Every case drives the real `GmailProvider.catchUp` against
/// `StatefulGmailActionServer` (the REST oracle) and applies through the real
/// `SyncEngine.runCatchUp`, or runs the real run of slices or backfill cycle, or
/// the whole foreground poll (`SyncEngine.sync(account:)`: delta, due full sync,
/// cursor capture) followed by the worker's cycles, then asserts
/// what the user would see: the local rows' read/starred state, which rows exist,
/// and which missing messages the check loaded. The wire is asserted only where
/// the invariant IS about the wire (bounds, budget, no request when nothing is due).
///
/// `.serialized, .processGlobalState`: every case swaps `AppDatabase.shared`, and
/// the trait clears `recentlyCompleted`, which these fixtures write.
@Suite("ADR-IOS-107 — Gmail catch-up of older mail", .serialized, .processGlobalState)
struct GmailCatchUpTests {

    // MARK: - Fixture

    /// Whole-second dates relative to now (the provider windows by epoch second).
    private struct Clock {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        func daysAgo(_ days: Double) -> Date {
            Date(timeIntervalSince1970: (now.timeIntervalSince1970 - days * 86_400).rounded(.down))
        }
        func hoursAgo(_ hours: Double) -> Date {
            Date(timeIntervalSince1970: (now.timeIntervalSince1970 - hours * 3_600).rounded(.down))
        }
    }

    private static func seed(_ id: String, _ date: Date, _ labels: Set<String>) -> StatefulGmailActionServer.Seed {
        StatefulGmailActionServer.Seed(
            rfc822MessageId: "\(id)@example.com", providerMessageId: id, labels: labels, internalDate: date)
    }

    /// One local row. `date` is both the display date and the provider order date.
    private struct Local {
        let id: String
        let path: String
        let date: Date
        var isRead = true
        var isFlagged = false
    }

    private struct World {
        let server: StatefulGmailActionServer
        let provider: GmailProvider
        let engine: SyncEngine
        let pool: DatabasePool
        let accountId: String
        func folderId(_ path: String) -> String { "\(accountId):\(path)" }
    }

    private static let catchUpFolders: [(path: String, role: FolderRole)] = [
        (inboxPath, .inbox), (allMailPath, .archive), (labelPath, .custom),
    ]
    /// The folders a real full sync of the fake keeps (it serves INBOX, and the
    /// provider adds All Mail).
    private static let syncFolders: [(path: String, role: FolderRole)] = [(inboxPath, .inbox), (allMailPath, .archive)]

    /// One prepared world. Every folder starts with its backfill complete, so no
    /// background walk runs unless a test starts one. `concurrency` is the work
    /// queue's width: 1 by default; a test of the one-sync-at-a-time turn passes
    /// production's (`SyncConfig.imapMaxConnectionCeiling`), so that a width-1
    /// queue cannot serialize a delta behind a slice in the lock's place.
    private static func withWorld(
        _ name: String,
        seeds: [StatefulGmailActionServer.Seed],
        local: [Local],
        folders: [(path: String, role: FolderRole)] = GmailCatchUpTests.catchUpFolders,
        userLabels: [String: String] = [labelPath: "Projects"],
        concurrency: Int = 1,
        _ body: (World) async throws -> Void
    ) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let server = StatefulGmailActionServer(messages: seeds, userLabels: userLabels, systemLabels: [inboxPath])
        defer { server.close() }

        _ = try FolderEpochTestFixture.makeAccount(id: name, provider: .gmail, pool: pool)
        for folder in folders {
            try FolderEpochTestFixture.insertFolder(accountId: name, path: folder.path, role: folder.role, pool: pool)
        }
        try await pool.write { db in
            try db.execute(sql: "UPDATE folder SET backfillComplete = 1 WHERE accountId = ?", arguments: [name])
        }
        try insert(local, accountId: name, pool: pool)

        let provider = server.provider()
        let engine = SyncEngine()
        await engine.register(
            accountId: name, provider: provider, workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: concurrency))
        let world = World(server: server, provider: provider, engine: engine, pool: pool, accountId: name)
        do {
            try await body(world)
        } catch {
            await engine.remove(accountId: name)
            throw error
        }
        await engine.remove(accountId: name)
    }

    private static func insert(_ rows: [Local], accountId: String, pool: DatabasePool) throws {
        try pool.write { db in
            for row in rows {
                var header = MessageHeader(
                    messageId: row.id, subject: "catch-up \(row.id)", from: "Sender",
                    fromAddress: "sender@example.com", to: "recipient@example.com", date: row.date,
                    snippet: "", folderId: "\(accountId):\(row.path)", accountId: accountId,
                    folderPath: row.path, isInInbox: row.path == inboxPath, providerDate: row.date)
                header.rfc822MessageId = "\(row.id)@example.com"
                header.headerComplete = true
                header.isRead = row.isRead
                header.isFlagged = row.isFlagged
                try header.insert(db)
            }
        }
    }

    private static func pass(
        _ world: World, _ paths: [String] = [inboxPath, allMailPath, labelPath], context: CatchUpContext = unlimited()
    ) async {
        await world.engine.runCatchUp(provider: world.provider, folderIds: paths.map(world.folderId), context: context)
    }

    /// A budget that never runs out, on `clock`.
    private static func unlimited(
        expensive: Bool = false, storageLimit: Bool = false, at clock: @escaping @Sendable () -> Date = { Date() }
    ) -> CatchUpContext {
        CatchUpContext(isExpensiveNetwork: expensive, deadline: .distantFuture, clock: clock, storageLimitInForce: storageLimit)
    }

    /// A budget of exactly `requests` requests: the clock advances one second per
    /// request the server has seen since the pass began, from `base`.
    private static func requestBudget(
        _ server: StatefulGmailActionServer, _ requests: Int, at base: Date = Date()
    ) -> CatchUpContext {
        let before = server.http.recordedCalls().count
        return CatchUpContext(
            isExpensiveNetwork: false, deadline: base.addingTimeInterval(TimeInterval(requests)),
            clock: { base.addingTimeInterval(TimeInterval(server.http.recordedCalls().count - before)) })
    }

    private static func rows(_ world: World, _ path: String) throws -> [String: (isRead: Bool, isFlagged: Bool)] {
        let folderId = world.folderId(path)
        return try world.pool.read { db in
            var out: [String: (isRead: Bool, isFlagged: Bool)] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT messageId, isRead, isFlagged FROM messageHeader WHERE folderId = ?", arguments: [folderId]) {
                out[row["messageId"]] = (row["isRead"], row["isFlagged"])
            }
            return out
        }
    }

    private static func headerCount(_ world: World) throws -> Int {
        let accountId = world.accountId
        return try world.pool.read { db in try MessageHeader.filter(Column("accountId") == accountId).fetchCount(db) }
    }

    private static func folder(_ world: World, _ path: String) throws -> Folder {
        try #require(try FolderEpochTestFixture.readFolder(accountId: world.accountId, path: path, pool: world.pool))
    }

    private static func state(_ world: World, _ path: String) throws -> GmailCatchUpState? {
        GmailCatchUpState.decode(try folder(world, path).catchUpState)
    }

    /// Runs the real backfill walk until no folder of the account is left to walk.
    private static func backfillUntilComplete(_ world: World) async throws {
        let accountId = world.accountId
        let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
        for _ in 0..<5 {
            let open = try await world.pool.read { db in
                try Folder.filter(Column("accountId") == accountId && Column("backfillComplete") == false).fetchCount(db)
            }
            if open == 0 { return }
            _ = await world.engine.runBackfill(account: account)
        }
        Issue.record("the backfill walk did not complete")
    }

    private static func cursor(_ world: World) throws -> String? {
        let accountId = world.accountId
        return try world.pool.read { db in try Account.fetchOne(db, key: accountId) }?.lastHistoryId
    }

    private static func setAccount(_ world: World, cursor: String?, lastFullSyncAt: Date?) throws {
        let accountId = world.accountId
        try world.pool.write { db in
            _ = try Account.filter(Column("id") == accountId).updateAll(db,
                Column("lastHistoryId").set(to: cursor),
                Column("lastFullSyncAt").set(to: lastFullSyncAt))
        }
    }

    private static func queue(_ world: World, _ type: OperationType, _ ids: [String], in path: String, to destination: String? = nil) throws {
        let accountId = world.accountId
        try world.pool.write { db in
            var op = PendingOperation(
                type: type, messageIds: ids, accountId: accountId, folderPath: path, destinationPath: destination)
            try op.insert(db)
        }
    }

    // MARK: - Flags

    @Test("Read and starred changes to older Inbox and All Mail mail are applied")
    func flagChangesAreApplied() async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("i1", clock.daysAgo(30), [inboxPath, "UNREAD"]),
            Self.seed("i2", clock.daysAgo(31), [inboxPath, "STARRED"]),
            Self.seed("i3", clock.daysAgo(32), [inboxPath]),
            Self.seed("a1", clock.daysAgo(40), []),
            Self.seed("a2", clock.daysAgo(41), ["UNREAD", "STARRED"]),
        ]
        let local = [
            Local(id: "i1", path: inboxPath, date: clock.daysAgo(30)),
            Local(id: "i2", path: inboxPath, date: clock.daysAgo(31)),
            Local(id: "i3", path: inboxPath, date: clock.daysAgo(32)),
            Local(id: "a1", path: allMailPath, date: clock.daysAgo(40), isRead: false),
            Local(id: "a2", path: allMailPath, date: clock.daysAgo(41)),
        ]
        try await Self.withWorld("gcu-flags", seeds: seeds, local: local) { world async throws in
            await Self.pass(world)

            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["i1"]?.isRead == false, "an old Inbox message marked unread elsewhere")
            #expect(inbox["i2"]?.isFlagged == true, "an old Inbox message starred elsewhere")
            #expect(inbox["i3"]?.isRead == true && inbox["i3"]?.isFlagged == false)
            let allMail = try Self.rows(world, allMailPath)
            #expect(allMail["a1"]?.isRead == true, "an old All Mail message read elsewhere")
            #expect(allMail["a2"]?.isRead == false && allMail["a2"]?.isFlagged == true)
            #expect(try Self.headerCount(world) == local.count, "the catch-up never inserts")
            let state = try #require(try Self.state(world, inboxPath))
            #expect(state.lastCompletedAt != nil && state.listing == nil)
        }
    }

    // MARK: - Removal needs proof

    /// The listing leaving a row out is only a candidate. Its own GET decides:
    /// gone (404) or labels without the folder remove it; labels still holding the
    /// folder, or an answer that says nothing (503), keep it. The fixture leaves
    /// the kept rows out of the listing by giving them a server date newer than
    /// the newest local row (a folder whose walk is complete is listed from the
    /// epoch, so an older date would still be listed). No write path is known to
    /// store such a date; this stands in for any listing that leaves out a row
    /// still in the folder.
    @Test("A row the listing leaves out is removed only when its own GET proves it left")
    func removalNeedsProof() async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("steady", clock.daysAgo(30), [inboxPath]),
            Self.seed("moved", clock.daysAgo(32), [labelPath]),
            Self.seed("kept200", clock.daysAgo(2), [inboxPath]),
            Self.seed("kept503", clock.daysAgo(3), [inboxPath]),
        ]
        let local = [
            Local(id: "steady", path: inboxPath, date: clock.daysAgo(30)),
            Local(id: "gone", path: inboxPath, date: clock.daysAgo(31)),
            Local(id: "moved", path: inboxPath, date: clock.daysAgo(32)),
            Local(id: "kept200", path: inboxPath, date: clock.daysAgo(33)),
            Local(id: "kept503", path: inboxPath, date: clock.daysAgo(34)),
        ]
        try await Self.withWorld("gcu-proof", seeds: seeds, local: local) { world async throws in
            world.server.injectGetFailure(providerMessageId: "kept503", .status(503))
            await Self.pass(world)

            #expect(Set(world.server.messageGets()) == ["gone", "moved", "kept200", "kept503"],
                    "every left-out row is asked about, and only those")
            #expect(world.server.getFailuresServedCount(providerMessageId: "kept503") >= 1, "precondition: kept503's answer was a 503")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["gone"] == nil, "a 404 proves the message is gone")
            #expect(inbox["moved"] == nil, "labels without INBOX prove it left the Inbox")
            #expect(inbox["kept200"] != nil, "a message whose labels still hold the folder keeps its row")
            #expect(inbox["kept503"] != nil, "an answer that proves nothing keeps the row")
            #expect(inbox["steady"] != nil)
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil)
        }
    }

    @Test("All Mail: a message back in Inbox, in Trash or Sent leaves All Mail; one with a user label stays")
    func allMailRemovalRule() async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("back", clock.daysAgo(40), [inboxPath]),
            Self.seed("trashed", clock.daysAgo(41), ["TRASH"]),
            Self.seed("sent", clock.daysAgo(42), ["SENT"]),
            Self.seed("steady", clock.daysAgo(43), []),
            // Newer than the newest local row, so the listing leaves it out.
            Self.seed("labelled", clock.daysAgo(2), [labelPath]),
        ]
        let local = [
            Local(id: "back", path: allMailPath, date: clock.daysAgo(40)),
            Local(id: "trashed", path: allMailPath, date: clock.daysAgo(41)),
            Local(id: "sent", path: allMailPath, date: clock.daysAgo(42)),
            Local(id: "steady", path: allMailPath, date: clock.daysAgo(43)),
            Local(id: "labelled", path: allMailPath, date: clock.daysAgo(44)),
        ]
        try await Self.withWorld("gcu-allmail", seeds: seeds, local: local) { world async throws in
            await Self.pass(world)

            let allMail = try Self.rows(world, allMailPath)
            #expect(allMail["back"] == nil)
            #expect(allMail["trashed"] == nil)
            #expect(allMail["sent"] == nil)
            #expect(allMail["steady"] != nil)
            #expect(allMail["labelled"] != nil, "a user label keeps a message in All Mail")
            #expect(world.server.messageGets().contains("labelled"), "precondition: its GET decided")
        }
    }

    /// The catch-up removes a candidate only when its labels no longer place it in
    /// the folder, through the one membership rule the delta also uses.
    @Test("The removal rule, per folder kind")
    func labelsShowRemovalRule() {
        let showsRemoval = { (labels: [String], path: String) in
            !GmailProvider.folder(path, containsMessageWithLabels: labels)
        }
        #expect(!showsRemoval([inboxPath, "UNREAD"], inboxPath))
        #expect(showsRemoval([labelPath], inboxPath))
        #expect(showsRemoval([], labelPath))
        #expect(!showsRemoval([], allMailPath))
        #expect(!showsRemoval([labelPath, "UNREAD", "STARRED"], allMailPath))
        for excluded in ["INBOX", "SENT", "TRASH", "SPAM", "DRAFT"] {
            #expect(showsRemoval([excluded], allMailPath), "\(excluded)")
        }
    }

    // MARK: - Bounds: the local range, no inserts, no placeholder ids

    /// Server mail older and newer than the local rows, and a placeholder row.
    private static func boundsWorld(_ clock: Clock) -> (seeds: [StatefulGmailActionServer.Seed], local: [Local]) {
        let seeds = [
            Self.seed("oldest", clock.daysAgo(40), [inboxPath]),
            Self.seed("sent-server-1", clock.daysAgo(34), [inboxPath]),
            Self.seed("newest", clock.daysAgo(30), [inboxPath]),
            Self.seed("recent", clock.daysAgo(1), [inboxPath]),
            Self.seed("ancient", clock.daysAgo(400), [inboxPath]),
        ]
        let local = [
            Local(id: "oldest", path: inboxPath, date: clock.daysAgo(40)),
            Local(id: "sent-local-1", path: inboxPath, date: clock.daysAgo(35)),
            Local(id: "newest", path: inboxPath, date: clock.daysAgo(30)),
        ]
        return (seeds, local)
    }

    /// While the folder's walk is unfinished the walk itself reaches older mail,
    /// so the check lists only the local range.
    @Test("While the walk is unfinished, every list request stays inside the local range; nothing is inserted; placeholder ids are never named")
    func requestsStayInsideTheLocalRange() async throws {
        let clock = Clock()
        let (seeds, local) = Self.boundsWorld(clock)
        try await Self.withWorld("gcu-bounds", seeds: seeds, local: local) { world async throws in
            let walkToken = "1"
            try Self.setPartialWalk(world, inboxPath, pageToken: walkToken)
            await Self.pass(world, [inboxPath])

            let low = Int(clock.daysAgo(40).timeIntervalSince1970) - SyncConfig.catchUpGmailRangeSlackSeconds
            let high = Int(clock.daysAgo(30).timeIntervalSince1970) + 1 + SyncConfig.catchUpGmailRangeSlackSeconds
            let lists = world.server.listRequests()
            #expect(!lists.isEmpty, "precondition: the folder was listed")
            for list in lists {
                let after = try #require(list.bound("after"), "an unbounded list: \(list.query)")
                let before = try #require(list.bound("before"), "an unbounded list: \(list.query)")
                #expect(after >= low && before <= high, "a list outside the local range: \(list.query)")
            }
            #expect(!world.server.messageGets().contains("sent-local-1"), "a placeholder id is never named")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["sent-local-1"] != nil, "a placeholder row is never removed")
            #expect(Set(inbox.keys) == ["oldest", "sent-local-1", "newest"], "nothing is inserted")
            let folder = try Self.folder(world, inboxPath)
            #expect(!folder.backfillComplete && folder.backfillPageToken == walkToken,
                    "mail outside the local range, and a placeholder id, leave the walk where it was")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil)
        }
    }

    /// A folder whose walk is complete is listed down to the epoch: its oldest
    /// range (listed last, newest first) starts at 0, so a message older than
    /// every local row (moved in from another device) is missing and the check
    /// loads it. Nothing newer than the newest local row is listed.
    @Test("A completed folder is listed down to the epoch: the check loads mail older than every local row; placeholder ids are never named",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func completedFolderIsListedFromTheEpoch() async throws {
        let clock = Clock()
        let (seeds, local) = Self.boundsWorld(clock)
        try await Self.withWorld("gcu-bounds-epoch", seeds: seeds, local: local) { world async throws in
            await Self.pass(world, [inboxPath])

            let low = Int(clock.daysAgo(40).timeIntervalSince1970) - SyncConfig.catchUpGmailRangeSlackSeconds
            let high = Int(clock.daysAgo(30).timeIntervalSince1970) + 1 + SyncConfig.catchUpGmailRangeSlackSeconds
            let lists = world.server.listRequests()
            let membership = lists.filter { $0.labelId == inboxPath }
            #expect(membership.count > 1, "precondition: the folder takes more than one range")
            #expect(membership.last?.bound("after") == 0, "the oldest range's membership list starts at the epoch: \(membership.last?.query ?? "none")")
            #expect(membership.dropLast().allSatisfy { ($0.bound("after") ?? 0) > 0 }, "only the oldest range reaches the epoch")
            for list in lists {
                let after = try #require(list.bound("after"), "an unbounded list: \(list.query)")
                let before = try #require(list.bound("before"), "an unbounded list: \(list.query)")
                #expect(after >= 0 && before <= high, "a list past the newest local row: \(list.query)")
                if list.labelId == nil {
                    #expect(after >= low, "a flag list below the local range: \(list.query)")
                }
            }
            #expect(!world.server.messageGets().contains("sent-local-1"), "a placeholder id is never named")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["sent-local-1"] != nil, "a placeholder row is never removed")
            #expect(Set(inbox.keys) == ["oldest", "sent-local-1", "newest", "ancient"],
                    "the check loads the message older than every local row, and nothing newer than the newest")
            let folder = try Self.folder(world, inboxPath)
            #expect(folder.backfillComplete && folder.backfillPageToken == nil, "the walk is left as it was")
        }
    }

    // MARK: - Budget and timeout

    @Test("A pass makes no request past its budget, and the listing resumes where it stopped")
    func budgetBoundsEveryPass() async throws {
        let clock = Clock()
        let days: [Double] = [100, 90, 80, 70, 60]
        let seeds = days.enumerated().map { Self.seed("b\($0.offset)", clock.daysAgo($0.element), [inboxPath]) }
        let local = days.enumerated().map { Local(id: "b\($0.offset)", path: inboxPath, date: clock.daysAgo($0.element), isRead: false) }
        let budget = 4
        try await Self.withWorld("gcu-budget", seeds: seeds, local: local) { world async throws in
            var passes = 0
            while try Self.state(world, inboxPath)?.lastCompletedAt == nil, passes < 12 {
                let before = world.server.http.recordedCalls().count
                await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, budget))
                let spent = world.server.http.recordedCalls().count - before
                #expect(spent <= budget, "pass \(passes) made \(spent) requests on a budget of \(budget)")
                if passes == 0 {
                    let inbox = try Self.rows(world, inboxPath)
                    #expect(inbox["b4"]?.isRead == true, "the first pass's finished range, the newest, is applied")
                    #expect(inbox["b0"]?.isRead == false, "precondition: one pass cannot finish the folder")
                    #expect(try Self.state(world, inboxPath)?.listing?.nextBeforeSecond != nil, "the listing is saved")
                }
                passes += 1
            }
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "the listing completes across passes")
            #expect(try Self.rows(world, inboxPath).values.allSatisfy(\.isRead))
        }
    }

    @Test("A removal check the budget cut short runs on the next pass without listing the range again")
    func removalCheckCarriesAcrossPasses() async throws {
        let clock = Clock()
        let seeds = [Self.seed("steady", clock.daysAgo(30), [inboxPath])]
        let local = [
            Local(id: "steady", path: inboxPath, date: clock.daysAgo(30)),
            Local(id: "gone", path: inboxPath, date: clock.daysAgo(31)),
        ]
        try await Self.withWorld("gcu-carry", seeds: seeds, local: local) { world async throws in
            // Three requests: the membership list and the two flag lists.
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 3))
            #expect(world.server.messageGets().isEmpty, "no GET starts after the budget is spent")
            #expect(try Self.rows(world, inboxPath)["gone"] != nil, "an unproven removal applies nothing")
            #expect(try Self.state(world, inboxPath)?.listing?.pendingCandidates == ["gone"])

            let listsBefore = world.server.listRequests().count
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 3))
            #expect(world.server.listRequests().count == listsBefore, "the range is not listed again")
            #expect(world.server.messageGets() == ["gone"])
            #expect(try Self.rows(world, inboxPath)["gone"] == nil, "the next pass proves and applies the removal")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil)
        }
    }

    /// The account-wide unread list over one range takes more pages than a pass
    /// may request. Each pass resumes the list at its saved page, so the range
    /// completes, no page is requested twice, and the flags it decides arrive.
    @Test("An unread list longer than one pass's budget completes over several passes")
    func longUnreadListCompletesAcrossPasses() async throws {
        let clock = Clock()
        let noise = (0..<12).map { Self.seed("n\($0)", clock.daysAgo(30.05).addingTimeInterval(TimeInterval($0)), [labelPath, "UNREAD"]) }
        let seeds = [
            Self.seed("t1", clock.daysAgo(30), [inboxPath, "UNREAD"]),
            Self.seed("t2", clock.daysAgo(30.1), [inboxPath, "STARRED"]),
        ] + noise
        let local = [
            Local(id: "t1", path: inboxPath, date: clock.daysAgo(30)),
            Local(id: "t2", path: inboxPath, date: clock.daysAgo(30.1)),
        ]
        let pageIds = 2
        let budget = 3
        try await Self.withWorld("gcu-long-unread", seeds: seeds, local: local) { world async throws in
            world.server.limitSearchListPages(to: pageIds)
            let unreadPages = (noise.count + 1 + pageIds - 1) / pageIds
            #expect(1 + unreadPages + 1 > budget, "precondition: one pass cannot request every page of the range")

            var passes = 0
            while try Self.state(world, inboxPath)?.lastCompletedAt == nil, passes < 12 {
                let before = world.server.http.recordedCalls().count
                await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, budget))
                let spent = world.server.http.recordedCalls().count - before
                #expect(spent <= budget, "pass \(passes) made \(spent) requests on a budget of \(budget)")
                passes += 1
            }

            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "the range completes across passes")
            #expect(passes > 1, "precondition: it took more than one pass")
            let lists = world.server.listRequests()
            #expect(lists.filter { $0.labelId == inboxPath }.count == 1, "the membership list never starts over")
            #expect(lists.filter { $0.query.contains("is:unread") }.count == unreadPages, "no unread page is requested twice")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["t1"]?.isRead == false, "the unread state the long list decides arrives")
            #expect(inbox["t2"]?.isFlagged == true)
            #expect(try Self.headerCount(world) == local.count, "the catch-up never inserts")
        }
    }

    /// A list page read in one pass can be older than a change the device learns
    /// before the range completes (the delta of a later pass). That change wins.
    @Test("A flag change the device learned after a list page was read is not overwritten by that page")
    func newerLocalFlagBeatsAnOlderPage() async throws {
        let clock = Clock()
        let noise = (0..<6).map { Self.seed("n\($0)", clock.daysAgo(30.05).addingTimeInterval(TimeInterval($0)), [labelPath, "UNREAD"]) }
        let seeds = [
            Self.seed("x", clock.daysAgo(30), [inboxPath, "UNREAD"]),
            Self.seed("y", clock.daysAgo(30.1), [inboxPath]),
        ] + noise
        let local = [
            Local(id: "x", path: inboxPath, date: clock.daysAgo(30), isRead: false),
            Local(id: "y", path: inboxPath, date: clock.daysAgo(30.1), isRead: false),
        ]
        try await Self.withWorld("gcu-newer-local", seeds: seeds, local: local) { world async throws in
            world.server.limitSearchListPages(to: 2)
            // The membership list and the unread list's first page, which names x.
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 2))
            #expect(world.server.listRequests().filter { $0.query.contains("is:unread") }.count == 1,
                    "precondition: the first unread page was read before the change")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == nil, "precondition: the range is still in progress")

            // x is read elsewhere, and the device learns it (as a delta would).
            world.server.applyLabelChange(providerMessageId: "x", remove: ["UNREAD"])
            let xId = MessageIdentity.headerId(accountId: world.accountId, folderPath: inboxPath, messageId: "x")
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE id = ?", arguments: [xId])
            }

            await Self.pass(world, [inboxPath])
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "precondition: the range completed")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["x"]?.isRead == true, "the older page does not undo the newer read")
            #expect(inbox["y"]?.isRead == true, "a row nothing changed locally still takes the lists' value")
        }
    }

    /// The same for the starred list: a starred page read in one pass is older
    /// than an unstar the device learns before the range completes.
    @Test("An unstar the device learned after a starred page was read is not overwritten by that page")
    func newerLocalUnstarBeatsAnOlderPage() async throws {
        let clock = Clock()
        let noise = (0..<6).map { Self.seed("n\($0)", clock.daysAgo(30.05).addingTimeInterval(TimeInterval($0)), [labelPath, "STARRED"]) }
        let seeds = [
            Self.seed("x", clock.daysAgo(30), [inboxPath, "STARRED"]),
            Self.seed("y", clock.daysAgo(30.1), [inboxPath]),
        ] + noise
        let local = [
            Local(id: "x", path: inboxPath, date: clock.daysAgo(30), isFlagged: true),
            Local(id: "y", path: inboxPath, date: clock.daysAgo(30.1), isFlagged: true),
        ]
        try await Self.withWorld("gcu-newer-local-unstar", seeds: seeds, local: local) { world async throws in
            world.server.limitSearchListPages(to: Self.tokenWorldUnreadPageIds)
            // The membership list, the (single-page) unread list and the starred
            // list's first page, which names x.
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, Self.tokenSavingBudget + 1))
            #expect(world.server.listRequests().filter { $0.query.contains("is:starred") }.count == 1,
                    "precondition: the first starred page was read before the change")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == nil, "precondition: the range is still in progress")

            // x is unstarred elsewhere, and the device learns it (as a delta would).
            world.server.applyLabelChange(providerMessageId: "x", remove: ["STARRED"])
            let xId = MessageIdentity.headerId(accountId: world.accountId, folderPath: inboxPath, messageId: "x")
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET isFlagged = 0 WHERE id = ?", arguments: [xId])
            }

            await Self.pass(world, [inboxPath])
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "precondition: the range completed")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["x"]?.isFlagged == false, "the older page does not undo the newer unstar")
            #expect(inbox["y"]?.isFlagged == false, "a row nothing changed locally still takes the lists' value")
        }
    }

    /// Rows that arrived in a range's stretch outside its local rows after the
    /// range was cut (newer than its newest local row, up to where the previous
    /// range started, or older than its oldest, down to the epoch) are named by
    /// the membership list, whose window is the whole range, but lie outside the
    /// flag lists' window. Their silence about such a row says nothing, so its
    /// flags stay as they are.
    @Test("A row dated outside the flag lists' window keeps its flags")
    func rowBeforeTheFlagWindowKeepsItsFlags() async throws {
        let clock = Clock()
        let late = clock.daysAgo(90)
        let early = clock.daysAgo(150)
        let seeds = [
            Self.seed("r1", clock.daysAgo(100), [inboxPath]),
            Self.seed("r2", clock.daysAgo(80), [inboxPath]),
            Self.seed("x", late, [inboxPath, "UNREAD"]),
            Self.seed("y", early, [inboxPath, "STARRED"]),
        ]
        let local = [
            Local(id: "r1", path: inboxPath, date: clock.daysAgo(100)),
            Local(id: "r2", path: inboxPath, date: clock.daysAgo(80)),
        ]
        try await Self.withWorld("gcu-outside-flag-window", seeds: seeds, local: local) { world async throws in
            // The newest range's three lists; the next range (r1's, down to the
            // epoch) is cut, and its membership list stops on the budget.
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 3))
            let cut = try #require(try Self.state(world, inboxPath)?.listing?.range, "precondition: the second range is in progress")
            let slack = SyncConfig.catchUpGmailRangeSlackSeconds
            let lateSecond = Int(late.timeIntervalSince1970)
            let earlySecond = Int(early.timeIntervalSince1970)
            #expect(lateSecond >= cut.range.localEnd + slack && lateSecond < cut.range.upTo,
                    "precondition: x lies in the range after the flag lists' window")
            #expect(earlySecond >= cut.range.from && earlySecond < cut.range.firstLocal - slack,
                    "precondition: y lies in the range before the flag lists' window")
            try Self.insert([
                Local(id: "x", path: inboxPath, date: late, isRead: false),
                Local(id: "y", path: inboxPath, date: early, isFlagged: true),
            ], accountId: world.accountId, pool: world.pool)

            await Self.pass(world, [inboxPath])
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "precondition: the range completed")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["x"]?.isRead == false, "an unread row the flag lists never covered is not marked read")
            #expect(inbox["y"]?.isFlagged == true, "a starred row the flag lists never covered is not unstarred")
        }
    }

    /// Gmail stops accepting a saved page token (it expired between passes). The
    /// list it belongs to starts again from the range's start with a fresh
    /// token: one extra listing, and the range still completes.
    /// One range of two Inbox rows, t1 server-unread and t2 read, under an unread
    /// list several pages long (other labels' unread mail on the same dates).
    private static func tokenWorld(_ clock: Clock, flag: String = "UNREAD") -> (seeds: [StatefulGmailActionServer.Seed], local: [Local]) {
        let noise = (0..<6).map { Self.seed("n\($0)", clock.daysAgo(30.05).addingTimeInterval(TimeInterval($0)), [labelPath, flag]) }
        let seeds = [
            Self.seed("t1", clock.daysAgo(30), [inboxPath, flag]),
            Self.seed("t2", clock.daysAgo(30.1), [inboxPath]),
        ] + noise
        let local = [
            Local(id: "t1", path: inboxPath, date: clock.daysAgo(30)),
            Local(id: "t2", path: inboxPath, date: clock.daysAgo(30.1)),
        ]
        return (seeds, local)
    }

    /// Requests the first pass may make: the membership list and the unread
    /// list's first page, so the unread list's next page token is saved.
    private static let tokenSavingBudget = 2
    /// Ids per unread list page, so the unread list takes several pages.
    private static let tokenWorldUnreadPageIds = 2

    @Test("A saved page token Gmail rejects restarts that list, and the range completes")
    func rejectedPageTokenRestartsTheList() async throws {
        let (seeds, local) = Self.tokenWorld(Clock())
        try await Self.withWorld("gcu-rejected-token", seeds: seeds, local: local) { world async throws in
            world.server.limitSearchListPages(to: Self.tokenWorldUnreadPageIds)
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, Self.tokenSavingBudget))
            let saved = try #require(try Self.state(world, inboxPath)?.listing?.range?.pageToken, "precondition: a page token is saved")

            world.server.expireIssuedPageTokens()
            var passes = 0
            while try Self.state(world, inboxPath)?.lastCompletedAt == nil, passes < 6 {
                await Self.pass(world, [inboxPath])
                passes += 1
            }

            #expect(world.server.rejectedPageTokens() == [saved], "the saved token was rejected once")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "the range completes")
            let unreadLists = world.server.listRequests().filter { $0.query.contains("is:unread") }
            #expect(unreadLists.filter { $0.pageToken == nil }.count == 2, "the unread list started again once from the range's start")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["t1"]?.isRead == false)
            #expect(inbox["t2"]?.isRead == true)
        }
    }

    /// A restarted list drops what its pages named so far: a page read before the
    /// restart may be older than the server. t1 is named by the first page, then
    /// read (or unstarred) on the server before the refused token's pass, and the
    /// restarted list no longer names it.
    @Test("A restarted list drops the pages it read before the restart",
          arguments: [("UNREAD", "is:unread"), ("STARRED", "is:starred")])
    func restartDropsTheListsEarlierPages(flag: String, search: String) async throws {
        let (seeds, local) = Self.tokenWorld(Clock(), flag: flag)
        let starred = flag == "STARRED"
        try await Self.withWorld("gcu-restart-drops-\(flag.lowercased())", seeds: seeds, local: local) { world async throws in
            world.server.limitSearchListPages(to: Self.tokenWorldUnreadPageIds)
            // Up to the flag's list's first page, which names t1; its token is saved.
            let budget = Self.tokenSavingBudget + (starred ? 1 : 0)
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, budget))
            let saved = try #require(try Self.state(world, inboxPath)?.listing?.range, "precondition: the range is in progress")
            #expect(saved.pageToken != nil && saved.step == (starred ? .starred : .unread), "precondition: the flag's list saved a token")
            #expect((starred ? saved.starredIds : saved.unreadIds) == ["t1"], "precondition: the first page named t1")

            world.server.applyLabelChange(providerMessageId: "t1", remove: [flag])
            world.server.expireIssuedPageTokens()
            await Self.pass(world, [inboxPath])

            #expect(world.server.rejectedPageTokens().count == 1, "precondition: the saved token was refused")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "precondition: the range completed")
            #expect(world.server.listRequests().filter { $0.query.contains(search) && $0.pageToken == nil }.count == 2,
                    "precondition: the list started over once")
            let t1 = try #require(try Self.rows(world, inboxPath)["t1"])
            if starred {
                #expect(t1.isFlagged == false, "t1, unstarred on the server, is not starred from the dropped page")
            } else {
                #expect(t1.isRead == true, "t1, read on the server, is not marked unread from the dropped page")
            }
        }
    }

    /// Gmail documents no wording for a page token it no longer accepts, so a
    /// `400` about anything else, answered to a request carrying the saved token,
    /// restarts that list the same way; the range completes in that pass.
    @Test("A 400 with unrelated wording on a saved page token also restarts that list once")
    func unrelatedBadRequestOnASavedTokenRestartsTheList() async throws {
        let (seeds, local) = Self.tokenWorld(Clock())
        try await Self.withWorld("gcu-unrelated-400", seeds: seeds, local: local) { world async throws in
            world.server.limitSearchListPages(to: Self.tokenWorldUnreadPageIds)
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, Self.tokenSavingBudget))
            let saved = try #require(try Self.state(world, inboxPath)?.listing?.range?.pageToken, "precondition: a page token is saved")

            world.server.answerTokenedListsWithUnrelatedBadRequest(count: 1)
            await Self.pass(world, [inboxPath])

            #expect(world.server.badRequestedPageTokens() == [saved], "precondition: the saved token got the unrelated 400")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "the range completes in the same pass")
            let unreadLists = world.server.listRequests().filter { $0.query.contains("is:unread") }
            #expect(unreadLists.filter { $0.pageToken == nil }.count == 2, "the unread list started again once from the range's start")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["t1"]?.isRead == false)
            #expect(inbox["t2"]?.isRead == true)
        }
    }

    /// A list starts over at most once: a second `400` in the restarted list stops
    /// the pass like any other failure, its place kept, and the next pass resumes
    /// that list where it stopped.
    @Test("A list restarts at most once on a 400; a second 400 in the same list stops the pass")
    func badRequestRestartIsBoundedToOncePerList() async throws {
        let (seeds, local) = Self.tokenWorld(Clock())
        try await Self.withWorld("gcu-400-once", seeds: seeds, local: local) { world async throws in
            world.server.limitSearchListPages(to: Self.tokenWorldUnreadPageIds)
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, Self.tokenSavingBudget))
            _ = try #require(try Self.state(world, inboxPath)?.listing?.range?.pageToken, "precondition: a page token is saved")

            // The saved token's request, then the restarted list's second page.
            world.server.answerTokenedListsWithUnrelatedBadRequest(count: 2)
            await Self.pass(world, [inboxPath])

            #expect(world.server.badRequestedPageTokens().count == 2, "precondition: both 400s were answered")
            let unreadLists = world.server.listRequests().filter { $0.query.contains("is:unread") }
            #expect(unreadLists.filter { $0.pageToken == nil }.count == 2, "the list started over once, not twice")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == nil, "the second 400 stopped the pass")
            let kept = try #require(try Self.state(world, inboxPath)?.listing?.range)
            #expect(kept.step == .unread && kept.pageToken != nil, "the restarted list keeps its place")

            await Self.pass(world, [inboxPath])
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "the next pass resumes and completes the range")
            #expect(world.server.listRequests().filter { $0.query.contains("is:unread") && $0.pageToken == nil }.count == 2,
                    "the next pass resumes where the list stopped, never from the range's start")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["t1"]?.isRead == false)
            #expect(inbox["t2"]?.isRead == true)
        }
    }

    /// The once-per-list bound holds within a pass only. A list that started over
    /// and then ran out of budget saves a fresh token; if a later pass finds that
    /// token refused too, that pass starts the list over again and completes the
    /// range, rather than the list stopping on every pass from then on.
    @Test("A later pass whose saved token is refused again restarts the list once more, and the range completes")
    func laterPassRestartsTheListAgain() async throws {
        let (seeds, local) = Self.tokenWorld(Clock())
        try await Self.withWorld("gcu-400-later-pass", seeds: seeds, local: local) { world async throws in
            world.server.limitSearchListPages(to: Self.tokenWorldUnreadPageIds)
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, Self.tokenSavingBudget))
            let first = try #require(try Self.state(world, inboxPath)?.listing?.range?.pageToken, "precondition: a page token is saved")

            // The refused request and the restarted list's first page; the budget
            // then runs out mid-list with a fresh token saved.
            world.server.expireIssuedPageTokens()
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, Self.tokenSavingBudget))
            let second = try #require(try Self.state(world, inboxPath)?.listing?.range?.pageToken, "precondition: the restarted list saved a token")
            #expect(second != first)
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == nil, "precondition: the budget ran out mid-list")

            world.server.expireIssuedPageTokens()
            await Self.pass(world, [inboxPath])

            #expect(world.server.rejectedPageTokens() == [first, second], "precondition: both saved tokens were refused")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "the later pass completes the range")
            let unreadLists = world.server.listRequests().filter { $0.query.contains("is:unread") }
            #expect(unreadLists.filter { $0.pageToken == nil }.count == 3, "each pass that met a refused token started the list over once")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["t1"]?.isRead == false)
            #expect(inbox["t2"]?.isRead == true)
        }
    }

    /// Spam and Trash rows are in Gmail's account-wide lists only when the request
    /// asks for them, so the unread and starred lists must, or such a row's server
    /// state never reaches it.
    @Test("The account-wide flag lists include Spam and Trash, so their rows' flags are applied")
    func flagListsIncludeSpamAndTrash() async throws {
        let clock = Clock()
        let trashPath = "TRASH", spamPath = "SPAM"
        let seeds = [
            Self.seed("tr", clock.daysAgo(30), [trashPath, "UNREAD"]),
            Self.seed("sp", clock.daysAgo(31), [spamPath, "STARRED"]),
        ]
        let local = [
            Local(id: "tr", path: trashPath, date: clock.daysAgo(30)),
            Local(id: "sp", path: spamPath, date: clock.daysAgo(31)),
        ]
        let folders: [(path: String, role: FolderRole)] = [(inboxPath, .inbox), (trashPath, .trash), (spamPath, .spam)]
        try await Self.withWorld("gcu-spam-trash", seeds: seeds, local: local, folders: folders) { world async throws in
            await Self.pass(world, [trashPath, spamPath])

            let flagLists = world.server.listRequests().filter { $0.query.contains("is:unread") || $0.query.contains("is:starred") }
            #expect(!flagLists.isEmpty, "precondition: the flag lists ran")
            #expect(flagLists.allSatisfy { $0.includeSpamTrash }, "every account-wide flag list asks for Spam and Trash")
            #expect(try Self.rows(world, trashPath)["tr"]?.isRead == false, "a Trash row marked unread elsewhere")
            #expect(try Self.rows(world, spamPath)["sp"]?.isFlagged == true, "a Spam row starred elsewhere")
        }
    }

    @Test("A stalled list request is abandoned at the request timeout and applies nothing")
    func stalledListIsAbandoned() async throws {
        let clock = Clock()
        let seeds = [Self.seed("i1", clock.daysAgo(30), [inboxPath, "UNREAD"])]
        let local = [Local(id: "i1", path: inboxPath, date: clock.daysAgo(30))]
        try await Self.withWorld("gcu-stall-list", seeds: seeds, local: local) { world async throws in
            let timeout = SyncConfig.catchUpRequestTimeoutSeconds
            world.server.holdSearchLists(forSeconds: timeout * 2)

            let started = Date()
            await Self.pass(world, [inboxPath])
            let elapsed = Date().timeIntervalSince(started)

            #expect(elapsed < timeout * 1.5, "the pass waited \(elapsed) s for a request whose timeout is \(timeout) s")
            #expect(try Self.rows(world, inboxPath)["i1"]?.isRead == true, "an unanswered list applies nothing")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == nil, "and completes nothing")
        }
    }

    @Test("A stalled removal check is abandoned at the request timeout and removes nothing")
    func stalledRemovalCheckIsAbandoned() async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("steady", clock.daysAgo(30), [inboxPath]),
            Self.seed("slow", clock.daysAgo(300), [labelPath]),
        ]
        let local = [
            Local(id: "steady", path: inboxPath, date: clock.daysAgo(30)),
            Local(id: "slow", path: inboxPath, date: clock.daysAgo(31)),
        ]
        try await Self.withWorld("gcu-stall-get", seeds: seeds, local: local) { world async throws in
            let timeout = SyncConfig.catchUpRequestTimeoutSeconds
            world.server.holdGet(providerMessageId: "slow", forSeconds: timeout * 2)

            let started = Date()
            await Self.pass(world, [inboxPath])
            let elapsed = Date().timeIntervalSince(started)

            #expect(elapsed < timeout * 1.5, "the pass waited \(elapsed) s for a request whose timeout is \(timeout) s")
            #expect(try Self.rows(world, inboxPath)["slow"] != nil, "an unanswered check removes nothing")
            #expect(try Self.state(world, inboxPath)?.listing?.pendingCandidates == ["slow"], "it is asked again next pass")
        }
    }

    // MARK: - Schedule

    @Test("On an expensive network a new folder records when its wait began and makes no request, until it has waited too long")
    func expensiveNetworkWaits() async throws {
        let clock = Clock()
        let seeds = [Self.seed("i1", clock.daysAgo(30), [inboxPath, "UNREAD"])]
        let local = [Local(id: "i1", path: inboxPath, date: clock.daysAgo(30))]
        try await Self.withWorld("gcu-expensive", seeds: seeds, local: local) { world async throws in
            // On the test's clock: the wait is counted from `createdAt`, so a wall
            // clock that ran on during setup would leave `later` short of it.
            let start = clock.now
            await Self.pass(world, context: Self.unlimited(expensive: true, at: { start }))
            await Self.pass(world, context: Self.unlimited(expensive: true, at: { start }))
            #expect(world.server.http.recordedCalls().isEmpty, "no request on an expensive network before the wait is over")
            let waiting = try #require(try Self.state(world, inboxPath))
            #expect(waiting.createdAt != nil && waiting.lastCompletedAt == nil)
            #expect(try Self.rows(world, inboxPath)["i1"]?.isRead == true)

            let later = clock.now.addingTimeInterval(SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds + 1)
            await Self.pass(world, context: Self.unlimited(expensive: true, at: { later }))
            #expect(try Self.rows(world, inboxPath)["i1"]?.isRead == false, "after the wait the folder is listed anyway")
        }
    }

    /// A Gmail folder is listed in exactly three cases: its first listing (no
    /// listing completed yet), a listing in progress, and a lapse after the last
    /// completed listing started. There is no periodic re-check, however long ago
    /// the last listing completed. A lapse makes a new listing due at once, but
    /// never interrupts one in progress and never restarts or skips the
    /// expensive-network wait, which is counted from the last completed listing
    /// (before the first, from `createdAt`).
    @Test("The per-folder plan")
    func catchUpPlan() {
        let now = Clock().now
        let maxWait = SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds
        let fresh = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-60))
        let old = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-4 * maxWait))
        let running = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-60), listing: .init(nextBeforeSecond: 42))
        let lapsed = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-60), lapseCount: 3, listedLapseCount: 2)
        let lapsedLongAgo = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-maxWait - 1), lapseCount: 3, listedLapseCount: 2)
        let lapseListed = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-60), lapseCount: 3, listedLapseCount: 3)
        let lapsedNeverListed = GmailCatchUpState(createdAt: now.addingTimeInterval(-60), lapseCount: 1)
        let lapsedWhileRunning = GmailCatchUpState(
            lastCompletedAt: now.addingTimeInterval(-60), listing: .init(nextBeforeSecond: 42, lapseCountAtStart: 3),
            lapseCount: 4, listedLapseCount: 2)
        let waiting = GmailCatchUpState(createdAt: now.addingTimeInterval(-60))
        let longWait = GmailCatchUpState(createdAt: now.addingTimeInterval(-maxWait - 1))

        #expect(GmailProvider.catchUpPlan(state: nil, isExpensiveNetwork: false, now: now) == .list(.init()))
        #expect(GmailProvider.catchUpPlan(state: nil, isExpensiveNetwork: true, now: now) == .none)
        #expect(GmailProvider.catchUpPlan(state: waiting, isExpensiveNetwork: false, now: now) == .list(.init()),
                "a folder whose first listing waited for the network is listed once it may be")
        #expect(GmailProvider.catchUpPlan(state: fresh, isExpensiveNetwork: false, now: now) == .none, "not every pass")
        #expect(GmailProvider.catchUpPlan(state: old, isExpensiveNetwork: false, now: now) == .none,
                "no periodic re-check, however long ago the last listing completed")
        #expect(GmailProvider.catchUpPlan(state: old, isExpensiveNetwork: true, now: now) == .none,
                "the expensive-network wait being over makes nothing due")
        #expect(GmailProvider.catchUpPlan(state: waiting, isExpensiveNetwork: true, now: now) == .none,
                "a folder with no completed listing waits for a non-expensive network")
        #expect(GmailProvider.catchUpPlan(state: running, isExpensiveNetwork: false, now: now) == .list(.init(nextBeforeSecond: 42)))
        #expect(GmailProvider.catchUpPlan(state: longWait, isExpensiveNetwork: true, now: now) == .list(.init()))
        #expect(GmailProvider.catchUpPlan(state: lapsed, isExpensiveNetwork: false, now: now) == .list(.init(lapseCountAtStart: 3)),
                "a lapse after the last listing started makes a new one due at once, recording the count it covers")
        #expect(GmailProvider.catchUpPlan(state: lapseListed, isExpensiveNetwork: false, now: now) == .none,
                "a lapse a completed listing already covered asks for nothing")
        #expect(GmailProvider.catchUpPlan(state: lapsedNeverListed, isExpensiveNetwork: false, now: now) == .list(.init(lapseCountAtStart: 1)))
        #expect(GmailProvider.catchUpPlan(state: lapsedWhileRunning, isExpensiveNetwork: false, now: now)
                == .list(.init(nextBeforeSecond: 42, lapseCountAtStart: 3)), "a lapse never interrupts a listing in progress")
        #expect(GmailProvider.catchUpPlan(state: lapsed, isExpensiveNetwork: true, now: now) == .none,
                "a lapse does not restart the expensive-network wait, and does not skip it")
        #expect(GmailProvider.catchUpPlan(state: lapsedLongAgo, isExpensiveNetwork: true, now: now) == .list(.init(lapseCountAtStart: 3)),
                "a lapsed folder that has waited as long as the wait allows is listed on any network")
        #expect(GmailProvider.catchUpPlan(state: lapsedNeverListed, isExpensiveNetwork: true, now: now) == .none)
    }

    /// The schedule end to end: a tracked Gmail folder whose listing completed
    /// and that no lapse touched is never listed again, 8 days later included
    /// (no request, a change made elsewhere stays unapplied); a lapse makes the
    /// next pass list it. IMAP keeps its daily check, pinned through its plan.
    @Test("A tracked, completed Gmail folder with no lapse runs no check 8 days later; a lapse lists it; an IMAP folder is still checked daily",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func gmailHasNoPeriodicCheckAndIMAPIsDaily() async throws {
        let day: TimeInterval = 86_400
        #expect(SyncConfig.catchUpFullCheckIntervalSeconds == day, "IMAP: daily")

        let clock = Clock()
        let seeds = [Self.seed("i1", clock.daysAgo(30), [inboxPath])]
        let local = [Local(id: "i1", path: inboxPath, date: clock.daysAgo(30))]
        try await Self.withWorld("gcu-no-periodic", seeds: seeds, local: local) { world async throws in
            let start = clock.now
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { start }))
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == start, "precondition: the first check completed")

            // Read elsewhere; no delta in this test, so only a check can bring it.
            world.server.applyLabelChange(providerMessageId: "i1", add: ["UNREAD"])
            for offset in [day + 3_600, 7 * day, 8 * day] {
                let at = start.addingTimeInterval(offset)
                let before = world.server.http.recordedCalls().count
                await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))
                #expect(world.server.http.recordedCalls().count == before, "no request \(offset) s after the last check")
                #expect(try Self.rows(world, inboxPath)["i1"]?.isRead == true, "nothing applied \(offset) s after the last check")
            }
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == start, "no listing ran")

            try await Self.lapse(world)
            let lapsedAt = start.addingTimeInterval(8 * day + 60)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { lapsedAt }))
            #expect(try Self.rows(world, inboxPath)["i1"]?.isRead == false, "the listing after the lapse applies the change")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == lapsedAt)
        }

        // IMAP keeps its daily full check (nothing else signals a change: the stamp is unchanged).
        let now = clock.now
        func imapPlan(completedAgo: TimeInterval) -> IMAPProvider.CatchUpPlan {
            IMAPProvider.catchUpPlan(
                state: IMAPCatchUpState(epoch: 1, completionStamp: 7, lastCompletedAt: now.addingTimeInterval(-completedAgo), listing: nil),
                freshModSeq: 7, isExpensiveNetwork: false, now: now)
        }
        #expect(imapPlan(completedAgo: day - 60) == .none, "IMAP: not again within the day")
        #expect(imapPlan(completedAgo: day) == .list(.init(firstStamp: 7, nextUid: 1)), "IMAP: again after a day")
    }

    @Test("Ranges tile the local rows newest first: bounded rows, whole seconds, a span cap, ties kept together, the epoch only for the rest")
    func catchUpRanges() {
        let base = Int(Clock().daysAgo(100).timeIntervalSince1970)
        let at = { (second: Int) in Date(timeIntervalSince1970: TimeInterval(second)) }
        let week = SyncConfig.catchUpGmailRangeMaxSpanSeconds
        func range(_ before: Int?, _ head: [Int], limit: Int = 500, toEpoch: Bool = false) -> CatchUpRange {
            CatchUpRange.cut(
                nextBeforeSecond: before, head: head.map(at), rowLimit: limit, maxSpanSeconds: week, toEpoch: toEpoch)
        }

        // Fewer rows than the limit: from the oldest row's second to just past the newest.
        #expect(range(nil, [base + 10, base], limit: 2) == .init(from: base, firstLocal: base, localEnd: base + 11, upTo: base + 11))
        // More rows than the limit: the cut second goes to the next (older) range.
        #expect(range(nil, [base + 20, base + 10, base], limit: 2)
                == .init(from: base + 1, firstLocal: base + 10, localEnd: base + 21, upTo: base + 21))
        // More rows than the limit share the newest second: the range is that second.
        #expect(range(nil, [base, base, base], limit: 2) == .init(from: base, firstLocal: base, localEnd: base + 1, upTo: base + 1))
        // The span cap, counted back from the newest local row.
        #expect(range(nil, [base + 3 * week, base])
                == .init(from: base + 2 * week + 1, firstLocal: base + 3 * week, localEnd: base + 3 * week + 1, upTo: base + 3 * week + 1))
        // A later range ends where the previous (newer) one started, even past its newest row.
        #expect(range(base + 50, [base]) == .init(from: base, firstLocal: base, localEnd: base + 1, upTo: base + 50))
        // A fractional order date belongs to its whole second.
        #expect(CatchUpRange.cut(
            nextBeforeSecond: nil, head: [Date(timeIntervalSince1970: TimeInterval(base) + 0.5)], rowLimit: 500,
            maxSpanSeconds: week, toEpoch: false) == .init(from: base, firstLocal: base, localEnd: base + 1, upTo: base + 1))
        // Reaching the epoch: only the range that holds every remaining row starts at 0.
        #expect(range(nil, [base + 10, base], limit: 2, toEpoch: true)
                == .init(from: 0, firstLocal: base, localEnd: base + 11, upTo: base + 11))
        #expect(range(nil, [base + 20, base + 10, base], limit: 2, toEpoch: true).from == base + 1,
                "a range the row limit cut does not reach the epoch")
        #expect(range(nil, [base + 3 * week, base], toEpoch: true).from == base + 2 * week + 1,
                "a range the span cap cut does not reach the epoch")
    }

    // MARK: - The reader accessor and the lapse helper

    @Test("The order-date accessors: rows in [from, before) ascending, and the newest rows before a bound descending, by date then id, with their order date")
    func orderDateAccessor() async throws {
        let clock = Clock()
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "gcu-reader"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: inboxPath, role: .inbox, pool: pool)
        try Self.insert([
            Local(id: "r1", path: inboxPath, date: clock.daysAgo(4)),
            Local(id: "r2b", path: inboxPath, date: clock.daysAgo(3)),
            Local(id: "r2a", path: inboxPath, date: clock.daysAgo(3)),
            Local(id: "r3", path: inboxPath, date: clock.daysAgo(2)),
            Local(id: "r4", path: inboxPath, date: clock.daysAgo(1)),
        ], accountId: accountId, pool: pool)
        let reader = SyncEngineCatchUpRowReader(pool: PrioritizedDatabase(pool: pool))
        let folderId = "\(accountId):\(inboxPath)"

        let bounded = try await reader.rows(folderId: folderId, orderDatesFrom: clock.daysAgo(3), before: clock.daysAgo(1))
        #expect(bounded.map(\.messageId) == ["r2a", "r2b", "r3"])
        #expect(bounded.map(\.orderDate) == [clock.daysAgo(3), clock.daysAgo(3), clock.daysAgo(2)])
        let newest = try await reader.newestRows(folderId: folderId, orderDatesBefore: nil, limit: 2)
        #expect(newest.map(\.messageId) == ["r4", "r3"])
        #expect(newest.map(\.orderDate) == [clock.daysAgo(1), clock.daysAgo(2)])
        let below = try await reader.newestRows(folderId: folderId, orderDatesBefore: clock.daysAgo(2), limit: 2)
        #expect(below.map(\.messageId) == ["r2b", "r2a"], "before the bound, newest first, ties by id descending")
        let all = try await reader.newestRows(folderId: folderId, orderDatesBefore: nil, limit: 10)
        #expect(all.map(\.messageId) == ["r4", "r3", "r2b", "r2a", "r1"])
    }

    /// The lapse marker: the cursor moves, and every catch-up state of that
    /// account counts one more lapse and keeps everything else (a listing in
    /// progress, its schedule). No state stays no state (a full check is due);
    /// a state that is not a JSON object starts over. Another account is untouched.
    @Test("A cursor lapse replaces the cursor and adds one lapse to every catch-up state of that account, and nothing else")
    func lapseHelper() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let paths = [inboxPath, allMailPath, labelPath, "Label_8", "Label_9"]
        for id in ["gcu-lapse-a", "gcu-lapse-b"] {
            _ = try FolderEpochTestFixture.makeAccount(id: id, provider: .gmail, pool: pool)
            for path in paths {
                try FolderEpochTestFixture.insertFolder(
                    accountId: id, path: path, role: path == inboxPath ? .inbox : path == allMailPath ? .archive : .custom, pool: pool)
            }
        }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let running = GmailCatchUpState(
            lastCompletedAt: now.addingTimeInterval(-60), listing: .init(nextBeforeSecond: 42, toEpoch: true, pendingCandidates: ["c1"]),
            createdAt: now.addingTimeInterval(-600), lastAttemptAt: now.addingTimeInterval(-30))
        let runningJSON = try #require(running.encoded())
        let states: [String: String?] = [
            inboxPath: runningJSON, allMailPath: nil, labelPath: "not json", "Label_8": "[1]", "Label_9": "{}",
        ]
        try await pool.write { db in
            try db.execute(sql: "UPDATE account SET lastHistoryId = '5'")
            for (path, state) in states {
                try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE path = ?", arguments: [state, path])
            }
        }

        try await pool.write { db in try SyncEngine.lapseDeltaCursor(accountId: "gcu-lapse-a", newCursor: "9", db: db) }
        try await pool.write { db in try SyncEngine.lapseDeltaCursor(accountId: "gcu-lapse-a", newCursor: nil, db: db) }

        let accounts = try await pool.read { db in try Account.fetchAll(db) }
        #expect(accounts.first { $0.id == "gcu-lapse-a" }?.lastHistoryId == nil)
        #expect(accounts.first { $0.id == "gcu-lapse-b" }?.lastHistoryId == "5")
        let folders = try await pool.read { db in try Folder.fetchAll(db) }
        #expect(folders.count == 2 * paths.count)
        let lapsed = Dictionary(uniqueKeysWithValues: folders.filter { $0.accountId == "gcu-lapse-a" }.map { ($0.path, $0.catchUpState) })
        var expected = running
        expected.lapseCount = 2
        #expect(GmailCatchUpState.decode(lapsed[inboxPath] ?? nil) == expected,
                "the listing in progress and the schedule are kept; the count under CatchUpLapse.countKey decodes as lapseCount")
        #expect(GmailCatchUpState.decode(lapsed[inboxPath] ?? nil)?.lapsedSinceLastListing == true)
        #expect(lapsed[allMailPath] == .some(nil), "no state stays no state: a full check is already due")
        #expect(lapsed[labelPath] == .some(nil), "a state that is not JSON starts over")
        #expect(lapsed["Label_8"] == .some(nil), "a state that is not a JSON object starts over")
        #expect(GmailCatchUpState.decode(lapsed["Label_9"] ?? nil) == GmailCatchUpState(lapseCount: 2))
        let untouched = Dictionary(uniqueKeysWithValues: folders.filter { $0.accountId == "gcu-lapse-b" }.map { ($0.path, $0.catchUpState) })
        #expect(untouched == states, "another account's states are untouched")
    }

    // MARK: - The user's newer action wins

    @Test("A queued flag op beats the catch-up's server value (IntentionLedger)")
    func queuedFlagOpWins() async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("x", clock.daysAgo(30), [inboxPath]),
            Self.seed("y", clock.daysAgo(31), [inboxPath]),
        ]
        let local = [
            Local(id: "x", path: inboxPath, date: clock.daysAgo(30), isRead: false),
            Local(id: "y", path: inboxPath, date: clock.daysAgo(31), isRead: false),
        ]
        try await Self.withWorld("gcu-queued", seeds: seeds, local: local) { world async throws in
            let ledger = IntentionLedger()
            let xId = MessageIdentity.headerId(accountId: world.accountId, folderPath: inboxPath, messageId: "x")
            ledger.record(label: "mark x unread", durableIdentity: "x") { db in
                try MessageHeader.fetchOne(db, key: xId)?.isRead == false
            }
            try Self.queue(world, .markUnread, ["x"], in: inboxPath)

            await Self.pass(world)
            #expect(try Self.rows(world, inboxPath)["y"]?.isRead == true,
                    "precondition: the catch-up applied the server's value where no intention stands")

            // The op drains: the server takes the user's value and the op retires.
            world.server.applyLabelChange(providerMessageId: "x", add: ["UNREAD"])
            _ = try await world.pool.write { db in try PendingOperation.deleteAll(db) }
            await ledger.settle(pool: world.pool, reportedIds: [])
        }
    }

    @Test("A recent completion beats the catch-up's older server value (IntentionLedger)")
    func recentCompletionWins() async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("x", clock.daysAgo(30), [inboxPath, "UNREAD"]),
            Self.seed("y", clock.daysAgo(31), [inboxPath, "UNREAD"]),
        ]
        let local = [
            Local(id: "x", path: inboxPath, date: clock.daysAgo(30)),
            Local(id: "y", path: inboxPath, date: clock.daysAgo(31)),
        ]
        try await Self.withWorld("gcu-recent", seeds: seeds, local: local) { world async throws in
            let ledger = IntentionLedger()
            let xId = MessageIdentity.headerId(accountId: world.accountId, folderPath: inboxPath, messageId: "x")
            ledger.record(label: "mark x read", durableIdentity: "x") { db in
                try MessageHeader.fetchOne(db, key: xId)?.isRead == true
            }
            await AccountManager.shared.recordRecentlyCompleted(messageIds: ["x"])

            await Self.pass(world)
            #expect(try Self.rows(world, inboxPath)["y"]?.isRead == false,
                    "precondition: the catch-up applied the server's value where no intention stands")

            world.server.applyLabelChange(providerMessageId: "x", remove: ["UNREAD"])
            await ledger.settle(pool: world.pool, reportedIds: [])
        }
    }

    // MARK: - Lexical fence

    @Test("The seam stays provider-blind, and the Gmail and Outlook catch-ups never read the network state, the storage limit or a setting themselves")
    func lexicalFence() throws {
        let sources = try DiagnosticPrintGateTests.appTargetSources()
        func source(_ path: String) throws -> String {
            try #require(sources.first { $0.relativePath == path }?.source, "missing \(path)")
        }
        for path in ["TabMail/Services/Sync/SyncEngineCatchUp.swift", "TabMail/Providers/EmailProviderCatchUp.swift"] {
            let text = try source(path)
            #expect(!text.contains("account.provider =="), "\(path) switches on the provider")
            for type in ["GmailProvider", "IMAPProvider", "ExchangeProvider", "DemoProvider"] {
                #expect(!text.contains("as? \(type)") && !text.contains("as! \(type)") && !text.contains("is \(type)"),
                        "\(path) casts to \(type)")
            }
        }
        let gmail = try source("TabMail/Providers/GmailProviderCatchUp.swift")
        #expect(!gmail.contains("NetworkMonitor"), "the network state comes only from the CatchUpContext snapshot")
        #expect(!gmail.contains("StorageEstimator"), "the storage limit comes only from the CatchUpContext snapshot")
        let engine = try source("TabMail/Services/Sync/SyncEngineCatchUp.swift")
        #expect(engine.components(separatedBy: "StorageEstimator").count == 2,
                "the engine reads the storage limit once, in the run's snapshot (CatchUpRun.snapshot)")
        #expect(engine.components(separatedBy: "NetworkMonitor").count == 2,
                "the engine reads the network state once, in the run's snapshot (CatchUpRun.snapshot); no slice re-reads it")
        #expect(!gmail.contains("UserDefaults"), "no setting is read mid-pass: what the pass needs comes from the CatchUpContext snapshot")
        for path in ["TabMail/Providers/ExchangeProviderCatchUp.swift", "TabMail/Providers/CatchUpListing.swift"] {
            let text = try source(path)
            for name in ["NetworkMonitor", "StorageEstimator", "UserDefaults"] {
                #expect(!text.contains(name), "\(path) reads \(name): what the pass needs comes from the CatchUpContext snapshot")
            }
        }
    }

    /// The walk's two bookkeeping columns, `backfillComplete` and
    /// `backfillPageToken`, are written by NAME (a GRDB column assignment or a
    /// SQL or Swift assignment of a literal) outside the walk's own
    /// compare-and-set (`advanceBackfillPageWalk`) only at the sites named here:
    /// the IMAP walk's completions, user and maintenance resets, and migrations.
    /// The catch-up writes none (2026-11-12: it loads missing mail itself; its
    /// re-arm is gone). None of them is a periodic check that could restart an
    /// unfinished walk. A new writer of that shape is added here with its
    /// reason, or the fence fails. This is a lexical census and cannot see a
    /// whole-record write (`record.update(db)`), which writes both columns with
    /// whatever the record holds: `SyncEngine.fullSync`'s folder upsert and the
    /// `AccountManagerUidValidityReset` writes are such writers, each of a row it
    /// read in the same transaction (ADR-IOS-107's writer list). The property
    /// itself is proven by the seeded property tests and the walk tests; this
    /// fence only supplements them.
    @Test("Every write of the walk's columns outside the walk's compare-and-set is a named site")
    func walkColumnWritesAreNamedSites() throws {
        let named: [String: (lines: Int, site: String)] = [
            "TabMail/Services/AppDatabase.swift": (5, "migrations that re-walk folders"),
            "TabMail/Services/StartupMigrations.swift": (4, "startup re-walk resets"),
            "TabMail/Services/Account/AccountManagerUidValidityReset.swift": (2, "the IMAP UIDVALIDITY purge"),
            "TabMail/Services/Demo/DemoSeed.swift": (1, "demo folders start complete"),
            "TabMail/Services/Sync/SyncEngineBackfill.swift": (2, "the fast-sync reset"),
            "TabMail/Services/Sync/SyncEngineBackfillWalk.swift": (
                3, "the IMAP walk's completions, compare-and-set on the version through `writeUIDWalkPosition` (2); the walk's refused-token restart (compare-and-set on the saved token) (1)"),
            "TabMail/Views/Settings/SettingsView.swift": (2, "the Settings reset"),
            "TabMail/Views/Settings/AccountDetailView.swift": (1, "the account's re-sync reset"),
        ]
        // A write: a GRDB column assignment, or a SQL or Swift assignment of a
        // literal (`= 0`, `= NULL`, `= ?`, `= false`). The text of a line from
        // `WHERE` on is a condition, not a write.
        let write = try NSRegularExpression(
            pattern: #"Column\("backfill(Complete|PageToken)"\)\.set\(to:|\bbackfill(Complete|PageToken) = (0|1|NULL|\?|true|false|nil)(?!\w)"#)
        var found: [String: Int] = [:]
        var excludedWalkWrites = 0
        for file in try DiagnosticPrintGateTests.appTargetSources() {
            var text = file.source
            if let start = text.range(of: "func advanceBackfillPageWalk(") {
                // The walk's own compare-and-set: its body, by brace matching.
                guard let open = text[start.upperBound...].firstIndex(of: "{") else { continue }
                var depth = 0
                var end = open
                for index in text[open...].indices {
                    if text[index] == "{" { depth += 1 }
                    if text[index] == "}" { depth -= 1; if depth == 0 { end = index; break } }
                }
                let body = String(text[open...end])
                excludedWalkWrites += body.components(separatedBy: "\n").filter {
                    write.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
                }.count
                text.removeSubrange(open...end)
            }
            for rawLine in text.components(separatedBy: "\n") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let line = rawLine.range(of: "WHERE").map { String(rawLine[..<$0.lowerBound]) } ?? rawLine
                if write.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    found[file.relativePath, default: 0] += 1
                }
            }
        }
        #expect(excludedWalkWrites == 2, "precondition: the walk's compare-and-set writes were found and excluded")
        for (path, count) in found.sorted(by: { $0.key < $1.key }) where named[path]?.lines != count {
            Issue.record("\(path) writes the walk's columns on \(count) lines; named: \(named[path].map { "\($0.lines) (\($0.site))" } ?? "none")")
        }
        for (path, site) in named.sorted(by: { $0.key < $1.key }) where found[path] == nil {
            Issue.record("\(path) (\(site.site)) no longer writes the walk's columns; update the census")
        }
    }

    // MARK: - Seeded property

    /// Random server-side changes (read, star, archive, move, delete) to an old
    /// Inbox spread over several ranges, then budgeted passes until the listing
    /// completes. Afterwards every local row carries the server's flags, every row
    /// whose message left the Inbox is gone, no row whose message is still there
    /// was removed, and nothing was inserted.
    @Test("Seeded: a finished catch-up leaves exactly the server's flags and membership",
          arguments: [UInt64(1), 2, 3, 4, 5, 6])
    func seededProperty(seed: UInt64) async throws {
        var rng = SplitMix64(seed: seed)
        let clock = Clock()
        let count = 24
        var seeds: [StatefulGmailActionServer.Seed] = []
        var local: [Local] = []
        for index in 0..<count {
            let date = clock.daysAgo(Double(10 + index * 2) + Double(rng.pick(86_400)) / 86_400)
            let unread = rng.pick(2) == 0
            let starred = rng.pick(3) == 0
            var labels: Set<String> = [inboxPath]
            if unread { labels.insert("UNREAD") }
            if starred { labels.insert("STARRED") }
            seeds.append(Self.seed("p\(index)", date, labels))
            local.append(Local(id: "p\(index)", path: inboxPath, date: date, isRead: !unread, isFlagged: starred))
        }
        let changes = (0..<count).map { _ in rng.pick(7) }
        let budget = 3 + rng.pick(4)
        let ids = Set(local.map(\.id))

        try await Self.withWorld("gcu-prop-\(seed)", seeds: seeds, local: local) { world async throws in
            for (index, change) in changes.enumerated() {
                let id = "p\(index)"
                let labels = world.server.snapshot(providerMessageId: id)?.labels ?? []
                switch change {
                case 0: world.server.applyLabelChange(providerMessageId: id, add: labels.contains("UNREAD") ? [] : ["UNREAD"], remove: labels.contains("UNREAD") ? ["UNREAD"] : [])
                case 1: world.server.applyLabelChange(providerMessageId: id, add: labels.contains("STARRED") ? [] : ["STARRED"], remove: labels.contains("STARRED") ? ["STARRED"] : [])
                case 2: world.server.applyLabelChange(providerMessageId: id, remove: [inboxPath])
                case 3: world.server.removeMessage(providerMessageId: id)
                case 4: world.server.applyLabelChange(providerMessageId: id, add: [labelPath], remove: [inboxPath])
                default: break
                }
            }

            var passes = 0
            while try Self.state(world, inboxPath)?.lastCompletedAt == nil, passes < 60 {
                await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, budget))
                passes += 1
            }
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "seed \(seed): the listing never completed")

            let inbox = try Self.rows(world, inboxPath)
            #expect(Set(inbox.keys).isSubset(of: ids), "seed \(seed): the catch-up inserted a row")
            for id in ids {
                let server = world.server.snapshot(providerMessageId: id)
                if let server, server.labels.contains(inboxPath) {
                    let row = inbox[id]
                    #expect(row != nil, "seed \(seed): \(id) is still in the Inbox but its row was removed")
                    #expect(row?.isRead == server.isRead && row?.isFlagged == server.isFlagged,
                            "seed \(seed): \(id) flags differ from the server's")
                } else {
                    #expect(inbox[id] == nil, "seed \(seed): \(id) left the Inbox but kept its row")
                }
            }
        }
    }

    // MARK: - Seeded direct-load property

    /// Runs a backfill walk one iteration at a time: between steps the walk waits
    /// in its next page request, held at the fake server, so a check or another
    /// write can land while that iteration is in flight.
    private final class WalkStepper: @unchecked Sendable {
        private let server: StatefulGmailActionServer
        private var task: Task<Void, Never>?
        private var parked: StatefulGmailActionServer.WalkListHold?
        private let ended = Mutex(false)

        init(server: StatefulGmailActionServer) { self.server = server }

        /// Whether a walk iteration is held at its page request.
        var isParked: Bool { parked != nil }

        /// Lets the walk on `engine` run one iteration (starting a walk if none
        /// runs) and holds it at its next page request. False when the walk ended
        /// instead, having nothing left to walk.
        func step(engine: SyncEngine, account: Account) async -> Bool {
            let next = server.holdNextWalkList()
            if let parked {
                self.parked = nil
                parked.release.signal()
            } else if task == nil {
                ended.withLock { $0 = false }
                task = Task { [self] in
                    _ = await engine.runBackfill(account: account)
                    ended.withLock { $0 = true }
                }
            }
            let deadline = Date().addingTimeInterval(GmailCatchUpTests.holdArrivalSeconds)
            while Date() < deadline {
                // A non-blocking poll: the walk's iteration runs on in its own task.
                if next.waitUntilReached(seconds: 0) {
                    parked = next
                    return true
                }
                if ended.withLock({ $0 }) {
                    task = nil
                    // Nothing took the hold; a later walk list passes straight through it.
                    next.release.signal()
                    return false
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            Issue.record("the walk neither reached its next page request nor ended")
            return false
        }

        /// Ends the walk: cancels it and lets its held request go.
        func stop() async {
            guard let task else { return }
            task.cancel()
            if let parked {
                self.parked = nil
                parked.release.signal()
            }
            await task.value
            self.task = nil
        }
    }

    /// One random step of the direct-load property.
    private enum RearmStep: CaseIterable {
        case moveIn, moveOut, delete, trash, queueOp, removeOp, failGet, healGets
        case walk, check, deltaInsert, lapse, newEngine, settingsReset, otherWalkCompletes

        /// Walk iterations, checks and moves are drawn more often than the rest.
        static let weights: [RearmStep: Int] = [.walk: 5, .check: 4, .moveIn: 3, .moveOut: 2]

        static func pick(_ rng: inout SplitMix64) -> RearmStep {
            let table = allCases.flatMap { Array(repeating: $0, count: weights[$0] ?? 1) }
            return table[rng.pick(table.count)]
        }
    }

    private static let rearmPropertyIdCount = 40
    private static let rearmPropertySteps = 80
    /// A check's request budget: from a few requests (a listing stops part way
    /// and resumes at a later check) to enough for both folders in one pass.
    private static let rearmPropertyMinCheckBudget = 4
    private static let rearmPropertyCheckBudgetSpread = 120
    private static let rearmPropertyMaxCheckPasses = 5
    /// Rounds at rest: a missing id loads at the first check that lists its
    /// range; a walk reset by a random step completes in the first round.
    private static let rearmPropertyRestRounds = 4

    /// Random server changes, queued and removed actions, failing and healing
    /// GETs, single walk iterations (each held at its next page request while
    /// later steps run), budgeted checks over a clock that moves 0 to 2 days per
    /// check, delta-style inserts, lapses, a new `SyncEngine` on the same
    /// database, the Settings reset, and a second walk completing a folder. After
    /// every check:
    /// - P3: the check never writes the walk's bookkeeping (completion, page
    ///   token, page hold time, row version), whatever the walk's state.
    /// - P2: the check's requests stay within its budget plus one batch of
    ///   concurrent loads (the budget is checked before each batch).
    /// Then, with the server and the faults at rest, `rearmPropertyRestRounds`
    /// rounds of "lapse, check to completion, walk to completion":
    /// - P1: every id the folder's walk lists, dated up to the newest local row
    ///   and protected by no queued action, has a row: no loadable missing id
    ///   is lost. (Replaces the re-arm property of 2026-11-11: re-arms bounded,
    ///   never moving an unfinished walk, never lost.)
    @Test("Seeded: the direct load stays bounded, never writes the walk's bookkeeping, and every loadable missing id loads",
          .enabled(if: !NetworkMonitor.checkExpensive()),
          arguments: Array(UInt64(1)...UInt64(24)))
    func seededDirectLoadProperty(seed: UInt64) async throws {
        var rng = SplitMix64(seed: seed)
        let clock = Clock()
        let paths = [inboxPath, labelPath]
        let folders: [(path: String, role: FolderRole)] = [(inboxPath, .inbox), (labelPath, .custom)]
        let ids = (0..<Self.rearmPropertyIdCount).map { "r\($0)" }
        let memberships: [Set<String>] = [[inboxPath], [labelPath], [inboxPath, labelPath], []]
        var dates: [String: Date] = [:]
        var seeds: [StatefulGmailActionServer.Seed] = []
        var local: [Local] = []
        for (index, id) in ids.enumerated() {
            let date = clock.daysAgo(Double(5 + 2 * index) + Double(rng.pick(86_400)) / 86_400)
            let labels = memberships[rng.pick(memberships.count)]
            dates[id] = date
            seeds.append(Self.seed(id, date, labels))
            local += labels.sorted().map { Local(id: id, path: $0, date: date) }
        }
        let pageIds = 1 + rng.pick(3)

        try await Self.withWorld("gcu-rearm-prop-\(seed)", seeds: seeds, local: local, folders: folders) { world async throws in
            world.server.limitWalkListPages(to: pageIds)
            let accountId = world.accountId
            let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
            var engine = world.engine
            let stepper = WalkStepper(server: world.server)
            var now = clock.now
            let batch = BackfillProfile.normal.gmailBodyConcurrency

            func folderRows() throws -> [String: Folder] {
                Dictionary(uniqueKeysWithValues: try paths.map { ($0, try Self.folder(world, $0)) })
            }
            func protectedIds(_ path: String) throws -> Set<String> {
                let ops = try world.pool.read { db in try PendingOperation.fetchAll(db) }
                return Set(ops.filter { $0.folderPath == path && PendingOperationSnapshot.destructiveTypes.contains($0.type) }
                    .flatMap(\.messageIds))
            }
            func finish() async {
                await stepper.stop()
                if engine !== world.engine { await engine.remove(accountId: accountId) }
            }

            do {
                for stepIndex in 0..<Self.rearmPropertySteps {
                    let kind = RearmStep.pick(&rng)
                    let id = ids[rng.pick(ids.count)]
                    let path = paths[rng.pick(paths.count)]
                    let label = "seed \(seed) step \(stepIndex) \(kind)"
                    let before = try folderRows()

                    switch kind {
                    case .moveIn:
                        world.server.applyLabelChange(providerMessageId: id, add: [path])
                    case .moveOut:
                        world.server.applyLabelChange(providerMessageId: id, remove: [path])
                    case .delete:
                        world.server.removeMessage(providerMessageId: id)
                    case .trash:
                        world.server.applyLabelChange(providerMessageId: id, add: ["TRASH"])
                    case .queueOp:
                        try Self.queue(world, .archive, [id], in: path, to: allMailPath)
                    case .removeOp:
                        let ops = try await world.pool.read { db in try PendingOperation.fetchAll(db) }
                        if !ops.isEmpty {
                            let op = ops[rng.pick(ops.count)]
                            _ = try await world.pool.write { db in try PendingOperation.deleteOne(db, key: op.id) }
                        }
                    case .failGet:
                        world.server.injectGetFailure(providerMessageId: id, .status(503))
                    case .healGets:
                        world.server.clearGetFailures()
                    case .walk:
                        _ = await stepper.step(engine: engine, account: account)
                    case .check:
                        // 0 to 2 expensive-network waits. A check lists a folder only
                        // on its first listing, a listing in progress, or after a lapse.
                        now = now.addingTimeInterval(TimeInterval(rng.pick(Int(2 * SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds) + 1)))
                        let budget = Self.rearmPropertyMinCheckBudget + rng.pick(Self.rearmPropertyCheckBudgetSpread)
                        let requestsBefore = world.server.http.recordedCalls().count
                        await engine.runCatchUp(
                            provider: world.provider, folderIds: paths.map(world.folderId),
                            context: Self.requestBudget(world.server, budget, at: now))
                        let spent = world.server.http.recordedCalls().count - requestsBefore
                        #expect(spent <= budget + batch - 1, "\(label): \(spent) requests on a budget of \(budget)")
                        now = now.addingTimeInterval(TimeInterval(budget + 1))
                    case .deltaInsert:
                        // A row for a message the server has in the folder, as a delta inserts it.
                        let labels = world.server.snapshot(providerMessageId: id)?.labels ?? []
                        if labels.contains(path), labels.isDisjoint(with: ["TRASH", "SPAM"]),
                           try Self.rows(world, path)[id] == nil, try !protectedIds(path).contains(id), let date = dates[id] {
                            try Self.insert([Local(id: id, path: path, date: date)], accountId: accountId, pool: world.pool)
                        }
                    case .lapse:
                        try await world.pool.write { db in
                            try SyncEngine.lapseDeltaCursor(accountId: accountId, newCursor: nil, db: db)
                        }
                    case .newEngine:
                        await stepper.stop()
                        await engine.remove(accountId: accountId)
                        engine = SyncEngine()
                        await engine.register(
                            accountId: accountId, provider: world.provider,
                            workQueue: ProviderWorkQueue(provider: world.provider, maxConcurrency: 1))
                    case .settingsReset:
                        // The Settings reset's folder write.
                        try await world.pool.write { db in
                            try db.execute(sql: """
                                UPDATE folder SET backfillComplete = 0, oldestSyncedDate = NULL,
                                    backfillUidCursor = NULL, backfillPageToken = NULL
                                WHERE path != ''
                                """)
                        }
                    case .otherWalkCompletes:
                        // A second walk (two walks are not serialized) completes the folder.
                        try Self.completeWalk(world, path)
                    }

                    let after = try folderRows()
                    guard kind == .check else { continue }
                    for path in paths {
                        guard let old = before[path], let new = after[path] else { continue }
                        #expect(new.backfillComplete == old.backfillComplete && new.backfillPageToken == old.backfillPageToken
                                    && new.backfillPageHeldSince == old.backfillPageHeldSince
                                    && new.backfillVersion == old.backfillVersion,
                                "\(label) \(path): a check wrote the walk's bookkeeping")
                    }
                }

                // P1: the server and the faults at rest, rounds each started by a lapse.
                await stepper.stop()
                world.server.clearGetFailures()
                for _ in 0..<Self.rearmPropertyRestRounds {
                    try await Self.lapse(world)
                    now = now.addingTimeInterval(Self.checkSpacing)
                    let at = now
                    for _ in 0..<Self.rearmPropertyMaxCheckPasses {
                        await engine.runCatchUp(
                            provider: world.provider, folderIds: paths.map(world.folderId), context: Self.unlimited(at: { at }))
                        if try paths.allSatisfy({ try Self.state(world, $0)?.listing == nil }) { break }
                    }
                    for _ in 0..<Self.rearmPropertyMaxCheckPasses {
                        let open = try await world.pool.read { db in
                            try Folder.filter(Column("accountId") == accountId && Column("backfillComplete") == false).fetchCount(db)
                        }
                        if open == 0 { break }
                        _ = await engine.runBackfill(account: account)
                    }
                }
                for path in paths {
                    let held = try Self.rows(world, path)
                    let protected = try protectedIds(path)
                    // Mail newer than the newest local row is the sync's to load, not the backfill's.
                    guard let newestLocal = held.keys.compactMap({ dates[$0] }).max() else { continue }
                    for id in ids {
                        guard let labels = world.server.snapshot(providerMessageId: id)?.labels, labels.contains(path),
                              labels.isDisjoint(with: ["TRASH", "SPAM"]), let date = dates[id], date <= newestLocal,
                              !protected.contains(id) else { continue }
                        #expect(held[id] != nil, "seed \(seed): \(id) is in \(path) on the server and can load, but has no row")
                    }
                }
            } catch {
                await finish()
                throw error
            }
            await finish()
        }
    }

    // MARK: - Moved-in mail is loaded by the check

    @Test("An old message moved from Inbox to a label is loaded into the label by the check",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func moveToLabelIsLoadedByTheCheck() async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("l1", clock.daysAgo(30), [labelPath]),
            Self.seed("m", clock.daysAgo(35), [labelPath]),
            Self.seed("l3", clock.daysAgo(40), [labelPath]),
        ]
        let local = [
            Local(id: "m", path: inboxPath, date: clock.daysAgo(35)),
            Local(id: "l1", path: labelPath, date: clock.daysAgo(30)),
            Local(id: "l3", path: labelPath, date: clock.daysAgo(40)),
        ]
        try await Self.withWorld("gcu-move-label", seeds: seeds, local: local) { world async throws in
            await Self.pass(world)
            #expect(try Self.rows(world, inboxPath)["m"] == nil, "precondition: the move left the Inbox")
            #expect(try Self.rows(world, labelPath)["m"] != nil, "the check loads the moved message into the label")
            #expect(try Self.folder(world, labelPath).backfillComplete, "the label's walk is left as it was")
        }
    }

    /// A server id the membership list names in a range whose local rows do not
    /// hold it can still be in the folder locally, under a stored date in another
    /// range (its local date differs from Gmail's). It is not missing: the
    /// folder's own lookup finds it, so nothing is loaded.
    @Test("A listed id held locally in the folder under a date in another range is not missing",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func idHeldUnderAnotherRangeIsNotMissing() async throws {
        let clock = Clock()
        let spanDays = Double(SyncConfig.catchUpGmailRangeMaxSpanSeconds) / 86_400
        let oldest = 40.0
        let seeds = [
            Self.seed("a", clock.daysAgo(oldest), [labelPath]),
            Self.seed("b", clock.daysAgo(oldest - spanDays / 4), [labelPath]),
            // Inside the first range on the server.
            Self.seed("h", clock.daysAgo(oldest - spanDays / 2), [labelPath]),
        ]
        let local = [
            Local(id: "a", path: labelPath, date: clock.daysAgo(oldest)),
            Local(id: "b", path: labelPath, date: clock.daysAgo(oldest - spanDays / 4)),
            // Locally past the first range's span, so in a later range.
            Local(id: "h", path: labelPath, date: clock.daysAgo(oldest - 2 * spanDays)),
        ]
        try await Self.withWorld("gcu-held-elsewhere", seeds: seeds, local: local) { world async throws in
            var passes = 0
            repeat {
                await Self.pass(world, [labelPath])
                passes += 1
            } while try Self.state(world, labelPath)?.lastCompletedAt == nil && passes < 4
            #expect(try Self.state(world, labelPath)?.lastCompletedAt != nil, "precondition: the check completed")
            #expect(world.server.fullMessageGets().isEmpty, "nothing is loaded")
            #expect(try Self.rows(world, labelPath)["h"] != nil, "the row stays")
        }
    }

    @Test("An old message archived from Inbox is loaded into All Mail by the check",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func archiveIsLoadedIntoAllMail() async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("a1", clock.daysAgo(30), []),
            Self.seed("m", clock.daysAgo(35), []),
            Self.seed("a3", clock.daysAgo(40), []),
        ]
        let local = [
            Local(id: "m", path: inboxPath, date: clock.daysAgo(35)),
            Local(id: "a1", path: allMailPath, date: clock.daysAgo(30)),
            Local(id: "a3", path: allMailPath, date: clock.daysAgo(40)),
        ]
        try await Self.withWorld("gcu-archive", seeds: seeds, local: local) { world async throws in
            await Self.pass(world)
            #expect(try Self.rows(world, inboxPath)["m"] == nil, "precondition: the archive left the Inbox")
            #expect(try Self.rows(world, allMailPath)["m"] != nil, "the check loads the archived message into All Mail")
            #expect(try Self.folder(world, allMailPath).backfillComplete, "All Mail's walk is left as it was")
        }
    }

    /// The check never writes the walk's bookkeeping: a walk held at a page keeps
    /// its page token and the time that page was first held, while the check
    /// loads the missing message itself. (Replaces "a re-arm clears the page hold
    /// time together with the page token", 2026-11-11: there is no re-arm.)
    @Test("A check loads a missing message and leaves the walk's page token and page hold time as they were",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func checkKeepsThePageHoldTime() async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("l1", clock.daysAgo(30), [labelPath]),
            Self.seed("m", clock.daysAgo(35), [labelPath]),
            Self.seed("l3", clock.daysAgo(40), [labelPath]),
        ]
        let local = [
            Local(id: "l1", path: labelPath, date: clock.daysAgo(30)),
            Local(id: "l3", path: labelPath, date: clock.daysAgo(40)),
        ]
        try await Self.withWorld("gcu-check-keeps-hold", seeds: seeds, local: local) { world async throws in
            let folderId = world.folderId(labelPath)
            let heldSince = clock.hoursAgo(2)
            try await world.pool.write { db in
                try db.execute(
                    sql: "UPDATE folder SET backfillComplete = 0, backfillPageToken = '1', backfillPageHeldSince = ? WHERE id = ?",
                    arguments: [heldSince, folderId])
            }
            let before = try Self.folder(world, labelPath)

            await Self.pass(world, [labelPath])
            let after = try Self.folder(world, labelPath)
            #expect(try Self.rows(world, labelPath)["m"] != nil, "the check loads m")
            #expect(!after.backfillComplete && after.backfillPageToken == "1", "the walk stays where it was")
            #expect(after.backfillPageHeldSince == before.backfillPageHeldSince, "the page hold time is kept")
            #expect(after.backfillVersion == before.backfillVersion, "the walk's bookkeeping was not written")
        }
    }

    /// A message in a label that is also in Trash (or Spam) is not in the label's
    /// walk: Gmail leaves Spam and Trash mail out of a list that does not ask for
    /// it. The label's check lists what its walk lists, so such a message is not
    /// missing there and is not loaded into it. The Trash folder's own list still
    /// asks for Trash mail, so its row stays.
    @Test("A message in a label that is also in Trash is not loaded into the label; the Trash folder still lists it",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func labelledTrashMailIsNotLoadedIntoTheLabel() async throws {
        let clock = Clock()
        let trashPath = "TRASH"
        let seeds = [
            Self.seed("l1", clock.daysAgo(30), [labelPath]),
            Self.seed("t", clock.daysAgo(35), [labelPath, trashPath]),
            Self.seed("l3", clock.daysAgo(40), [labelPath]),
        ]
        let local = [
            Local(id: "l1", path: labelPath, date: clock.daysAgo(30)),
            Local(id: "l3", path: labelPath, date: clock.daysAgo(40)),
            Local(id: "t", path: trashPath, date: clock.daysAgo(35)),
        ]
        let folders: [(path: String, role: FolderRole)] = [(inboxPath, .inbox), (labelPath, .custom), (trashPath, .trash)]
        try await Self.withWorld("gcu-labelled-trash", seeds: seeds, local: local, folders: folders) { world async throws in
            await Self.pass(world, [labelPath, trashPath])

            #expect(try Self.state(world, labelPath)?.lastCompletedAt != nil, "precondition: the label's check completed")
            #expect(try Self.rows(world, labelPath)["t"] == nil, "the Trash message is not loaded into the label")

            #expect(try Self.state(world, trashPath)?.lastCompletedAt != nil, "precondition: the Trash folder's check completed")
            #expect(try Self.rows(world, trashPath)["t"] != nil, "the Trash row stays")
            #expect(world.server.fullMessageGets().isEmpty, "nothing is loaded")

            let membership = world.server.listRequests().filter {
                !$0.query.contains("is:unread") && !$0.query.contains("is:starred")
            }
            let labelLists = membership.filter { $0.labelId == labelPath }
            let trashLists = membership.filter { $0.labelId == trashPath }
            #expect(!labelLists.isEmpty && !trashLists.isEmpty, "precondition: both folders were listed")
            #expect(labelLists.allSatisfy { !$0.includeSpamTrash }, "the label's list does not ask for Spam and Trash")
            #expect(trashLists.allSatisfy { $0.includeSpamTrash }, "the Trash folder's own list does")
        }
    }

    /// Checks an expensive-network wait and an hour apart. Each check is started
    /// by a lapse; the spacing keeps every check past the previous one's hold
    /// bound.
    private static let checkSpacing = SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds + 3_600

    /// The clock of check `check`.
    private static func checkDay(_ clock: Clock, _ check: Int) -> Date {
        clock.now.addingTimeInterval(Double(check) * checkSpacing)
    }

    /// One check of the label, started by a lapse (a Gmail folder has no
    /// periodic check), with an unlimited budget, run until its listing
    /// completes. With `pastLoadHolds`, the check's first pass runs at its time on
    /// the hold clock (`SyncEngine.backfillPageHoldNowForTesting`) and a second
    /// pass past the hold bound, so a missing id whose load keeps failing with a
    /// `hold` failure is passed over. The caller resets the hold clock.
    private static func labelCheckAfterLapse(
        _ world: World, _ clock: Clock, _ check: Int, pastLoadHolds: Bool = false
    ) async throws {
        try await lapse(world)
        let at = checkDay(clock, check)
        let completedBefore = try state(world, labelPath)?.lastCompletedAt
        if pastLoadHolds { SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = at } }
        await pass(world, [labelPath], context: unlimited(at: { at }))
        if pastLoadHolds, try state(world, labelPath)?.lastCompletedAt == completedBefore {
            #expect(try state(world, labelPath)?.listing?.range?.loadHeldSince == at, "precondition: the range is held")
            SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = at.addingTimeInterval(SyncConfig.backfillPageHoldSeconds + 1) }
            await pass(world, [labelPath], context: unlimited(at: { at }))
        }
        #expect(try state(world, labelPath)?.lastCompletedAt != completedBefore, "precondition: check \(check) completed")
    }

    /// What keeps a moved-in message from loading for a while.
    enum LoadBlock: String, CaseIterable, Sendable {
        /// A destructive op queued for it in the folder, removed later.
        case queuedArchive
        /// Its `format=full` GET answers `503` until the fault passes.
        case failingGet
    }

    /// A missing id the check cannot load never stops the rest: the check loads
    /// everything else and completes (a queued destructive op keeps the insert
    /// from writing it; a `503` holds the range only until the hold bound). A
    /// message moved in later loads at the next check, and once the cause passes
    /// the id loads at the next check. (Replaces "re-arms once per check",
    /// 2026-11-11: there is no re-arm.)
    @Test("A missing id the check cannot load never stops the rest; a message moved in later loads; once it can load it loads at the next check",
          .enabled(if: !NetworkMonitor.checkExpensive()),
          arguments: LoadBlock.allCases)
    func unloadableMissingIdNeverStopsTheRest(block: LoadBlock) async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("l1", clock.daysAgo(30), [labelPath]),
            Self.seed("m", clock.daysAgo(35), [labelPath]),
            Self.seed("n", clock.daysAgo(36), [inboxPath]),
            Self.seed("k", clock.daysAgo(37), [labelPath]),
            Self.seed("l3", clock.daysAgo(40), [labelPath]),
        ]
        let local = [
            Local(id: "l1", path: labelPath, date: clock.daysAgo(30)),
            Local(id: "l3", path: labelPath, date: clock.daysAgo(40)),
        ]
        try await Self.withWorld("gcu-unloadable-\(block.rawValue)", seeds: seeds, local: local) { world async throws in
            switch block {
            case .queuedArchive: try Self.queue(world, .archive, ["m"], in: labelPath, to: allMailPath)
            case .failingGet: world.server.injectGetFailure(providerMessageId: "m", .status(503))
            }
            defer { SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = nil } }
            let pastLoadHolds = block == .failingGet

            try await Self.labelCheckAfterLapse(world, clock, 0, pastLoadHolds: pastLoadHolds)
            #expect(try Self.rows(world, labelPath)["m"] == nil, "precondition: m could not load")
            #expect(try Self.rows(world, labelPath)["k"] != nil, "the check loaded the rest")
            if block == .failingGet {
                #expect(world.server.getFailuresServedCount(providerMessageId: "m") >= 2, "precondition: m's GET was answered 503")
            }

            world.server.applyLabelChange(providerMessageId: "n", add: [labelPath], remove: [inboxPath])
            try await Self.labelCheckAfterLapse(world, clock, 1, pastLoadHolds: pastLoadHolds)
            #expect(try Self.rows(world, labelPath)["n"] != nil, "a message moved in later loads at the next check")
            #expect(try Self.rows(world, labelPath)["m"] == nil, "precondition: m still could not load")

            switch block {
            case .queuedArchive:
                let accountId = world.accountId
                try await world.pool.write { db in
                    try db.execute(sql: "DELETE FROM pendingOperation WHERE accountId = ?", arguments: [accountId])
                }
            case .failingGet:
                world.server.clearGetFailures()
            }
            try await Self.labelCheckAfterLapse(world, clock, 2)
            #expect(try Self.rows(world, labelPath)["m"] != nil, "once m can load, the next check loads it")
            #expect(try Self.folder(world, labelPath).backfillComplete, "the walk is never touched")
        }
    }

    /// How the walk comes to pass over a message whose fetch failed.
    enum PassedOverFetch: String, CaseIterable, Sendable {
        /// Its GET answers a 400 about the message: the walk moves past it at once.
        case perMessage
        /// Its GET answers 503: the page is held, and once the page hold bound
        /// has passed the walk moves past it.
        case heldPastTheBound
    }

    /// A fetch that failed during the walk leaves an id missing: the walk
    /// completes without the message, and the next check (after a lapse) finds it
    /// missing and loads it.
    @Test("An id the walk passed over because its fetch failed loads at the next check",
          .enabled(if: !NetworkMonitor.checkExpensive()),
          arguments: PassedOverFetch.allCases)
    func idPassedOverByTheWalkLoadsAtTheNextCheck(failure: PassedOverFetch) async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("l1", clock.daysAgo(30), [labelPath]),
            Self.seed("m", clock.daysAgo(35), [labelPath]),
            Self.seed("k", clock.daysAgo(37), [labelPath]),
            Self.seed("l3", clock.daysAgo(40), [labelPath]),
        ]
        let local = [
            Local(id: "l1", path: labelPath, date: clock.daysAgo(30)),
            Local(id: "l3", path: labelPath, date: clock.daysAgo(40)),
        ]
        try await Self.withWorld("gcu-passed-over-\(failure.rawValue)", seeds: seeds, local: local) { world async throws in
            defer { SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = nil } }
            switch failure {
            case .perMessage:
                world.server.injectUnclassified400OnGet(providerMessageId: "m")
            case .heldPastTheBound:
                SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = clock.now }
                world.server.injectGetFailure(providerMessageId: "m", .status(503))
            }

            // The label's walk runs from the top.
            let labelId = world.folderId(labelPath)
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE folder SET backfillComplete = 0, backfillPageToken = NULL WHERE id = ?", arguments: [labelId])
            }
            if failure == .heldPastTheBound {
                let accountId = world.accountId
                let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
                _ = await world.engine.runBackfill(account: account)
                #expect(try !Self.folder(world, labelPath).backfillComplete, "precondition: inside the bound the page is held")
                SyncEngine.backfillPageHoldNowForTesting.withLock {
                    $0 = clock.now.addingTimeInterval(SyncConfig.backfillPageHoldSeconds + 1)
                }
            }
            try await Self.backfillUntilComplete(world)
            #expect(try Self.rows(world, labelPath)["k"] != nil, "precondition: the walk loaded the rest")
            #expect(try Self.rows(world, labelPath)["m"] == nil, "precondition: the walk passed over m")
            switch failure {
            case .perMessage:
                #expect(world.server.unclassified400OnGetServedCount() >= 1, "precondition: m's GET was answered 400")
                world.server.clearUnclassified400sOnGet()
            case .heldPastTheBound:
                #expect(world.server.getFailuresServedCount(providerMessageId: "m") >= 2, "precondition: m's GET was answered 503")
                world.server.clearGetFailures()
            }

            try await Self.labelCheckAfterLapse(world, clock, 1)
            #expect(try Self.rows(world, labelPath)["m"] != nil, "the next check loads m")
        }
    }

    /// Completes the folder's backfill walk, as the walk's last page does.
    private static func completeWalk(_ world: World, _ path: String) throws {
        let folderId = world.folderId(path)
        try world.pool.write { db in
            try db.execute(sql: "UPDATE folder SET backfillComplete = 1, backfillPageToken = NULL WHERE id = ?",
                           arguments: [folderId])
        }
    }

    /// Sets the folder's backfill walk to unfinished at `pageToken`, as a walk
    /// part way through the folder leaves it.
    private static func setPartialWalk(_ world: World, _ path: String, pageToken: String) throws {
        let folderId = world.folderId(path)
        try world.pool.write { db in
            try db.execute(sql: "UPDATE folder SET backfillComplete = 0, backfillPageToken = ? WHERE id = ?",
                           arguments: [pageToken, folderId])
        }
    }

    /// A check never writes an unfinished walk's bookkeeping: a message moved in
    /// above the walk's position is loaded by the check itself, and the walk
    /// goes on from where it was. (Replaces "the first check after the walk
    /// completes re-arms once", 2026-11-11: there is no re-arm.)
    @Test("A check loads a message moved in above an unfinished walk's position and leaves the walk where it was",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func checkLoadsAboveAnUnfinishedWalk() async throws {
        let clock = Clock()
        // The walk lists newest first, one id per page: l1, l2, l3, l4 before the
        // move; l1, m, l2, l3, l4 after it.
        let seeds = [
            Self.seed("l1", clock.daysAgo(10), [labelPath]),
            Self.seed("l2", clock.daysAgo(20), [labelPath]),
            Self.seed("l3", clock.daysAgo(30), [labelPath]),
            Self.seed("l4", clock.daysAgo(40), [labelPath]),
            Self.seed("m", clock.daysAgo(15), [inboxPath]),
        ]
        let local = [
            Local(id: "l1", path: labelPath, date: clock.daysAgo(10)),
            Local(id: "l2", path: labelPath, date: clock.daysAgo(20)),
        ]
        try await Self.withWorld("gcu-unfinished-walk", seeds: seeds, local: local) { world async throws in
            world.server.limitWalkListPages(to: 1)
            // The walk has loaded l1 and l2 and resumes past them.
            let walkToken = "2"
            try Self.setPartialWalk(world, labelPath, pageToken: walkToken)
            world.server.applyLabelChange(providerMessageId: "m", add: [labelPath], remove: [inboxPath])

            try await Self.labelCheckAfterLapse(world, clock, 0)
            let during = try Self.folder(world, labelPath)
            #expect(!during.backfillComplete && during.backfillPageToken == walkToken,
                    "the check leaves the unfinished walk where it was")
            #expect(try Self.rows(world, labelPath)["m"] != nil, "the check loads m")

            try await Self.backfillUntilComplete(world)
            #expect(Set(try Self.rows(world, labelPath).keys) == ["l1", "l2", "l3", "l4", "m"], "the walk loads the rest")
        }
    }

    /// The huge-folder case: many not-yet-walked ids are missing (an old message
    /// gave the folder a local row far below the walk's position). No check
    /// moves the walk's position backwards; the check loads them itself.
    @Test("No check moves an unfinished walk's position backwards, even with many missing ids",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func checksNeverMoveAnUnfinishedWalkBack() async throws {
        let clock = Clock()
        let unwalkedCount = 200
        let first = clock.daysAgo(50).timeIntervalSince1970
        let step = (clock.daysAgo(10).timeIntervalSince1970 - first) / Double(unwalkedCount)
        let unwalked = (0...unwalkedCount).map { "u\($0)" }
        var seeds = [
            Self.seed("top", clock.daysAgo(5), [labelPath]),
            Self.seed("old", clock.daysAgo(60), [labelPath]),
        ]
        for (index, id) in unwalked.enumerated() {
            seeds.append(Self.seed(id, Date(timeIntervalSince1970: (first + Double(index) * step).rounded(.down)), [labelPath]))
        }
        let local = [
            Local(id: "top", path: labelPath, date: clock.daysAgo(5)),
            Local(id: "old", path: labelPath, date: clock.daysAgo(60)),
        ]
        try await Self.withWorld("gcu-walk-never-back", seeds: seeds, local: local) { world async throws in
            let checks = 3
            for check in 0..<checks {
                // The walk has moved on since the last check.
                let position = String(check + 1)
                try Self.setPartialWalk(world, labelPath, pageToken: position)
                // A Gmail folder has no periodic check: a lapse starts each one.
                try await Self.lapse(world)
                let at = Self.checkDay(clock, check)
                let completedBefore = try Self.state(world, labelPath)?.lastCompletedAt
                await Self.pass(world, [labelPath], context: Self.unlimited(at: { at }))
                #expect(try Self.state(world, labelPath)?.lastCompletedAt != completedBefore,
                        "precondition: check \(check) completed")
                let folder = try Self.folder(world, labelPath)
                #expect(!folder.backfillComplete && folder.backfillPageToken == position,
                        "check \(check) left the walk at \(folder.backfillPageToken ?? "the top"), not at \(position)")
                let held = try Self.rows(world, labelPath)
                #expect(unwalked.allSatisfy { held[$0] != nil }, "check \(check) loaded the not-yet-walked ids itself")
            }
        }
    }

    /// How long a test waits for a held request to arrive.
    private static let holdArrivalSeconds: Double = 30

    /// A check lands while a backfill walk iteration is in flight on the same
    /// folder (its page answered from the server before the move). The check
    /// loads the moved-in message itself and writes none of the walk's
    /// bookkeeping, so the walk's write for that page (moving the page token or
    /// completing the folder) lands and the walk goes on from its page. Each case
    /// holds a different write site: a page with or without new mail, and a
    /// middle or the last page. (Replaces "a re-arm landing during a walk
    /// iteration is not overwritten", 2026-11-11: there is no re-arm.)
    @Test("A check landing during a backfill walk iteration loads the moved-in mail; the walk's write lands and the walk goes on",
          .enabled(if: !NetworkMonitor.checkExpensive()),
          arguments: [(false, false), (true, false), (false, true), (true, true)])
    func checkDuringWalkIterationLetsTheWalkGoOn(pageHasNewMail: Bool, lastPage: Bool) async throws {
        let clock = Clock()
        // The walk lists newest first, one id per page: l1, l2, l3 before the
        // move; l1, m, l2, l3 after it.
        let seeds = [
            Self.seed("l1", clock.daysAgo(10), [labelPath]),
            Self.seed("l2", clock.daysAgo(20), [labelPath]),
            Self.seed("l3", clock.daysAgo(30), [labelPath]),
            Self.seed("m", clock.daysAgo(15), [inboxPath]),
        ]
        let heldId = lastPage ? "l3" : "l2"
        let local = ["l1", "l2", "l3"].filter { !(pageHasNewMail && $0 == heldId) }.map { id in
            Local(id: id, path: labelPath, date: seeds.first { $0.providerMessageId == id }!.internalDate!)
        }
        let name = "gcu-walk-rearm-\(pageHasNewMail ? "new" : "old")-\(lastPage ? "last" : "middle")"
        try await Self.withWorld(name, seeds: seeds, local: local) { world async throws in
            world.server.limitWalkListPages(to: 1)
            let readToken = lastPage ? "2" : "1"
            let labelId = world.folderId(labelPath)
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE folder SET backfillComplete = 0, backfillPageToken = ? WHERE id = ?",
                               arguments: [readToken, labelId])
            }
            let accountId = world.accountId
            let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })

            let hold = world.server.holdNextWalkList()
            defer { hold.release.signal() }
            let walk = Task { await world.engine.runBackfill(account: account) }
            let arrived = await Task.detached { hold.waitUntilReached(seconds: Self.holdArrivalSeconds) }.value
            try #require(arrived, "precondition: the walk's page request is held")

            // Meanwhile: the message moves into the label and the check runs.
            let before = try Self.folder(world, labelPath)
            world.server.applyLabelChange(providerMessageId: "m", add: [labelPath], remove: [inboxPath])
            await Self.pass(world, [labelPath])
            #expect(try Self.rows(world, labelPath)["m"] != nil, "the check loads the moved-in message")
            #expect(try Self.folder(world, labelPath).backfillVersion == before.backfillVersion,
                    "the check wrote none of the walk's bookkeeping")

            hold.release.signal()
            _ = await walk.value

            #expect(try Self.rows(world, labelPath)["m"] != nil)
            #expect(try Self.rows(world, labelPath)[heldId] != nil)
            #expect(try Self.folder(world, labelPath).backfillComplete, "the walk completes")
            let walkLists = world.server.listRequests().filter { $0.labelId == labelPath && $0.bound("after") == nil }
            #expect(walkLists.first?.pageToken == readToken, "precondition: the held page was the iteration's")
            #expect(walkLists.dropFirst().allSatisfy { $0.pageToken != nil },
                    "the walk goes on from its page, never from the top: \(walkLists.map { $0.pageToken ?? "top" })")
        }
    }

    /// The same interleaving at the top of a folder: the walk's iteration read the
    /// folder with no page token and not complete. The page was answered before
    /// the move, and the moved-in message sorts before where that page ends, so
    /// walking on from it never reaches the message: the check loads it, and the
    /// walk's write lands. (Replaces "a re-arm at the top of the walk is not
    /// overwritten", 2026-11-11: there is no re-arm.)
    @Test("A check landing while the walk is at the top of a folder loads the moved-in mail; the walk's write lands",
          .enabled(if: !NetworkMonitor.checkExpensive()),
          arguments: [false, true])
    func checkAtTheTopOfTheWalkLetsTheWalkGoOn(lastPage: Bool) async throws {
        let clock = Clock()
        // Newest first: z, y, l before the move; z, m, y, l after it.
        let seeds = [
            Self.seed("z", clock.daysAgo(5), [labelPath]),
            Self.seed("y", clock.daysAgo(12), [labelPath]),
            Self.seed("l", clock.daysAgo(20), [labelPath]),
            Self.seed("m", clock.daysAgo(8), [inboxPath]),
        ]
        let local = ["z", "y", "l"].map { id in
            Local(id: id, path: labelPath, date: seeds.first { $0.providerMessageId == id }!.internalDate!)
        }
        let name = "gcu-walk-rearm-top-\(lastPage ? "last" : "middle")"
        try await Self.withWorld(name, seeds: seeds, local: local) { world async throws in
            // The held first page: z and y, or the whole folder.
            world.server.limitWalkListPages(to: lastPage ? local.count : local.count - 1)
            let labelId = world.folderId(labelPath)
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE folder SET backfillComplete = 0, backfillPageToken = NULL WHERE id = ?",
                               arguments: [labelId])
            }
            let accountId = world.accountId
            let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })

            let hold = world.server.holdNextWalkList()
            defer { hold.release.signal() }
            let walk = Task { await world.engine.runBackfill(account: account) }
            let arrived = await Task.detached { hold.waitUntilReached(seconds: Self.holdArrivalSeconds) }.value
            try #require(arrived, "precondition: the walk's page request is held")

            // Meanwhile: the message moves into the label and the check runs.
            let before = try Self.folder(world, labelPath)
            world.server.applyLabelChange(providerMessageId: "m", add: [labelPath], remove: [inboxPath])
            await Self.pass(world, [labelPath])
            #expect(try Self.rows(world, labelPath)["m"] != nil, "the check loads the moved-in message")
            #expect(try Self.folder(world, labelPath).backfillVersion == before.backfillVersion,
                    "the check wrote none of the walk's bookkeeping")

            hold.release.signal()
            _ = await walk.value

            #expect(try Self.folder(world, labelPath).backfillComplete, "the walk completes")
            let walkLists = world.server.listRequests().filter { $0.labelId == labelPath && $0.bound("after") == nil }
            #expect(walkLists.first?.pageToken == nil, "precondition: the held page was the folder's first")
            #expect(walkLists.dropFirst().allSatisfy { $0.pageToken != nil },
                    "the walk goes on from its page, never from the top again: \(walkLists.map { $0.pageToken ?? "top" })")
        }
    }

    /// Settings' Delete All Email Index Data (`SettingsView.localIndexWipeTxn`)
    /// lands while a backfill walk iteration is in flight: the iteration has
    /// read the folder (its page token and row version) and is held at its page
    /// request, before its page-outcome write. The wipe deletes every header row,
    /// `l1` (on the page before the held one) among them, and resets the walk to
    /// the top. Once released, the iteration's stale write must not land over the
    /// reset: the walk starts again from the top, so `l1` comes back. A stale
    /// token written over the reset would walk on from the page after the held
    /// one and never list `l1` again. (ADR-IOS-107: the walk's page-outcome
    /// writes are compare-and-set on `Folder.backfillVersion`.)
    @Test("A Settings reset landing during a walk iteration is not overwritten: the walk restarts from the top and reloads the deleted rows",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func settingsResetDuringWalkIterationRestartsTheWalk() async throws {
        let clock = Clock()
        // The walk lists newest first, one id per page: l1, l2, l3.
        let seeds = [
            Self.seed("l1", clock.daysAgo(10), [labelPath]),
            Self.seed("l2", clock.daysAgo(20), [labelPath]),
            Self.seed("l3", clock.daysAgo(30), [labelPath]),
        ]
        let local = seeds.map { Local(id: $0.providerMessageId, path: labelPath, date: $0.internalDate!) }
        try await Self.withWorld("gcu-walk-settings-reset", seeds: seeds, local: local) { world async throws in
            world.server.limitWalkListPages(to: 1)
            // The iteration reads the page after l1's.
            let readToken = "1"
            let labelId = world.folderId(labelPath)
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE folder SET backfillComplete = 0, backfillPageToken = ? WHERE id = ?",
                               arguments: [readToken, labelId])
            }
            let accountId = world.accountId
            let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })

            let hold = world.server.holdNextWalkList()
            defer { hold.release.signal() }
            let walk = Task { await world.engine.runBackfill(account: account) }
            let arrived = await Task.detached { hold.waitUntilReached(seconds: Self.holdArrivalSeconds) }.value
            try #require(arrived, "precondition: the walk's page request is held")

            // Meanwhile: the Settings reset.
            let before = try Self.folder(world, labelPath)
            try await world.pool.write { db in try SettingsView.localIndexWipeTxn(db) }
            let reset = try Self.folder(world, labelPath)
            #expect(try Self.rows(world, labelPath)["l1"] == nil, "precondition: the reset deleted l1's row")
            #expect(reset.backfillPageToken == nil && !reset.backfillComplete, "precondition: the reset put the walk at the top")
            #expect(reset.backfillVersion != before.backfillVersion, "precondition: the reset moved the row version")

            hold.release.signal()
            _ = await walk.value
            try await Self.backfillUntilComplete(world)

            let walkLists = world.server.listRequests().filter { $0.labelId == labelPath && $0.bound("after") == nil }
            #expect(walkLists.first?.pageToken == readToken, "precondition: the held page was the iteration's")
            #expect(walkLists.dropFirst().first?.pageToken == nil,
                    "the walk restarts from the top after the reset, its stale token not written: \(walkLists.map { $0.pageToken ?? "top" })")
            #expect(try Self.folder(world, labelPath).backfillComplete, "the walk completes")
            let rows = try Self.rows(world, labelPath)
            #expect(rows["l1"] != nil, "the row the reset deleted comes back on the walk's next pass")
            #expect(rows["l2"] != nil && rows["l3"] != nil)
        }
    }

    /// The folder row is deleted and created again under the same id while a
    /// walk iteration is in flight (`Folder.id` is `"\(accountId):\(path)"`, so
    /// a folder that disappears and comes back reuses it), and the new row then
    /// goes through as many bookkeeping writes as the old one had. The
    /// iteration read the OLD row's version; its stale page-outcome write must
    /// not land on the NEW row because the new row happens to hold the same
    /// number. The new row's walk starts from the top, so `l1`, whose row went
    /// with the old folder, loads again. A stale token written onto the new row
    /// would walk on from the page after the held one and never list `l1`.
    /// (`Folder.backfillVersion` values never repeat, migration v101.)
    @Test("A folder row deleted and re-created mid-iteration never takes the stale iteration's write: the new walk starts from the top",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func recreatedFolderRowNeverTakesAStaleWalkWrite() async throws {
        let clock = Clock()
        // The walk lists newest first, one id per page: l1, l2, l3.
        let seeds = [
            Self.seed("l1", clock.daysAgo(10), [labelPath]),
            Self.seed("l2", clock.daysAgo(20), [labelPath]),
            Self.seed("l3", clock.daysAgo(30), [labelPath]),
        ]
        let local = seeds.map { Local(id: $0.providerMessageId, path: labelPath, date: $0.internalDate!) }
        try await Self.withWorld("gcu-walk-recreated-row", seeds: seeds, local: local) { world async throws in
            world.server.limitWalkListPages(to: 1)
            // The iteration reads the page after l1's.
            let readToken = "1"
            let labelId = world.folderId(labelPath)
            let accountId = world.accountId
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE folder SET backfillComplete = 0, backfillPageToken = ? WHERE id = ?",
                               arguments: [readToken, labelId])
            }
            let read = try Self.folder(world, labelPath)
            let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })

            let hold = world.server.holdNextWalkList()
            defer { hold.release.signal() }
            let walk = Task { await world.engine.runBackfill(account: account) }
            let arrived = await Task.detached { hold.waitUntilReached(seconds: Self.holdArrivalSeconds) }.value
            try #require(arrived, "precondition: the walk's page request is held")

            // Meanwhile: the folder goes away with its rows, and comes back.
            try await world.pool.write { db in
                try db.execute(sql: "DELETE FROM messageHeader WHERE folderId = ?", arguments: [labelId])
                try db.execute(sql: "DELETE FROM folder WHERE id = ?", arguments: [labelId])
            }
            try FolderEpochTestFixture.insertFolder(accountId: accountId, path: labelPath, role: .custom, pool: world.pool)
            // The new row's own bookkeeping writes, as many as it takes to reach
            // the version the iteration read if the numbering repeats (each write
            // gives it a fresh version; with repeating numbers that climbs back to
            // the old row's).
            var recreated = try Self.folder(world, labelPath)
            for _ in 0..<(read.backfillVersion + 1) where recreated.backfillVersion < read.backfillVersion {
                try await world.pool.write { db in
                    try db.execute(sql: "UPDATE folder SET backfillComplete = 0 WHERE id = ?", arguments: [labelId])
                }
                recreated = try Self.folder(world, labelPath)
            }
            #expect(recreated.backfillPageToken == nil && !recreated.backfillComplete,
                    "precondition: the new row's walk is at the top")
            #expect(try Self.rows(world, labelPath).isEmpty, "precondition: the old folder's rows went with it")

            hold.release.signal()
            _ = await walk.value
            try await Self.backfillUntilComplete(world)

            let walkLists = world.server.listRequests().filter { $0.labelId == labelPath && $0.bound("after") == nil }
            #expect(walkLists.first?.pageToken == readToken, "precondition: the held page was the iteration's")
            #expect(try Self.folder(world, labelPath).backfillComplete, "the walk completes")
            let rows = try Self.rows(world, labelPath)
            #expect(rows["l1"] != nil,
                    "the new folder's walk never listed its first page (the stale iteration's token landed on the new row; versions read \(read.backfillVersion), new row \(recreated.backfillVersion)): \(walkLists.map { $0.pageToken ?? "top" })")
            #expect(rows["l2"] != nil && rows["l3"] != nil)
        }
    }

    // MARK: - Under a storage limit (ADR-IOS-107 decision 8, ADR-IOS-006)

    /// A folder the storage prune thinned: three kept Inbox rows within one
    /// week, and two server messages no row holds any more, one between the
    /// kept rows (inside the kept range, so it loads like any missing id; the
    /// prune deletes oldest first, so a pruned message is never there) and one
    /// older than all of them.
    private static func prunedWorld(_ clock: Clock) -> (seeds: [StatefulGmailActionServer.Seed], local: [Local]) {
        let kept: [(String, Double)] = [("k1", 30), ("k2", 31), ("k3", 33)]
        let seeds = kept.map { Self.seed($0.0, clock.daysAgo($0.1), [inboxPath]) } + [
            Self.seed("pruned-mid", clock.daysAgo(32), [inboxPath]),
            Self.seed("pruned-old", clock.daysAgo(300), [inboxPath]),
        ]
        return (seeds, kept.map { Local(id: $0.0, path: inboxPath, date: clock.daysAgo($0.1)) })
    }

    private static func restoreStorageBudget(_ saved: Any?) {
        if let saved {
            UserDefaults.standard.set(saved, forKey: StorageEstimator.storageBudgetKey)
        } else {
            UserDefaults.standard.removeObject(forKey: StorageEstimator.storageBudgetKey)
        }
    }

    /// With a storage limit the pruned mail is what the limit dropped: the check
    /// lists nothing below the oldest kept row, so it loads nothing older back.
    /// Without a limit the same check lists down to the epoch and loads both.
    /// The walk is never touched. (Superseded 2026-11-12: "re-arms nothing"; the
    /// re-arm is gone, and the message between the kept rows loads either way.)
    @Test("Under a storage limit the check lists and loads nothing older than the oldest kept row; without one it loads both",
          arguments: [true, false])
    func storageLimitLoadsNothingBelowTheOldestKeptRow(limit: Bool) async throws {
        let clock = Clock()
        let (seeds, local) = Self.prunedWorld(clock)
        try await Self.withWorld("gcu-pruned-\(limit)", seeds: seeds, local: local) { world async throws in
            await Self.pass(world, [inboxPath], context: Self.unlimited(storageLimit: limit))
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "precondition: the check completed")

            let oldestKept = Int(clock.daysAgo(33).timeIntervalSince1970) - SyncConfig.catchUpGmailRangeSlackSeconds
            let lowest = try #require(world.server.listRequests().compactMap { $0.bound("after") }.min(), "precondition: the folder was listed")
            if limit {
                #expect(lowest >= oldestKept, "no list goes below the oldest kept row: \(lowest)")
            } else {
                #expect(lowest == 0, "without a limit the oldest range reaches the epoch")
            }
            #expect(try Self.folder(world, inboxPath).backfillComplete, "the walk is left as it was")
            let inbox = Set(try Self.rows(world, inboxPath).keys)
            if limit {
                #expect(inbox == ["k1", "k2", "k3", "pruned-mid"], "nothing older than the oldest kept row is loaded")
                #expect(!world.server.messageGets().contains("pruned-old"), "the old pruned message is never downloaded")
            } else {
                #expect(inbox == ["k1", "k2", "k3", "pruned-mid", "pruned-old"], "the check loads both")
            }
        }
    }

    /// The production snapshot (`CatchUpRun.snapshot`, taken by a backfill cycle)
    /// takes the storage limit from the user's Email Index Limit when the run
    /// starts. *Superseded (#766):* "(`runCatchUp` with no context) [...] when the
    /// step starts".
    @Test("The production snapshot takes the storage limit from the Email Index Limit",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func productionSnapshotTakesTheStorageLimit() async throws {
        let clock = Clock()
        let (seeds, local) = Self.prunedWorld(clock)
        let saved = UserDefaults.standard.object(forKey: StorageEstimator.storageBudgetKey)
        defer { Self.restoreStorageBudget(saved) }
        // Finite, and far above anything a test store reaches: no prune runs.
        StorageEstimator.budgetMB = 1_000_000
        try await Self.withWorld("gcu-pruned-snapshot", seeds: seeds, local: local) { world async throws in
            try await Self.backfillCycles(world)
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "precondition: the check completed")
            let oldestKept = Int(clock.daysAgo(33).timeIntervalSince1970) - SyncConfig.catchUpGmailRangeSlackSeconds
            let lowest = try #require(world.server.listRequests().compactMap { $0.bound("after") }.min())
            #expect(lowest >= oldestKept, "no list goes below the oldest kept row")
            #expect(!world.server.messageGets().contains("pruned-old"), "the old pruned message is never downloaded")
        }
    }

    // MARK: - Lapses and the newest-first order

    /// One Inbox row every 10 days from 150 days ago, `g0` the oldest: each
    /// row is a range of its own. Local rows mirror the server.
    private static func rangesWorld(_ clock: Clock, count: Int) -> (seeds: [StatefulGmailActionServer.Seed], local: [Local]) {
        let days = (0..<count).map { 150 - 10 * Double($0) }
        return (days.enumerated().map { Self.seed("g\($0.offset)", clock.daysAgo($0.element), [inboxPath]) },
                days.enumerated().map { Local(id: "g\($0.offset)", path: inboxPath, date: clock.daysAgo($0.element)) })
    }

    private static func lapse(_ world: World) async throws {
        let accountId = world.accountId
        try await world.pool.write { db in try SyncEngine.lapseDeltaCursor(accountId: accountId, newCursor: nil, db: db) }
    }

    // MARK: - The direct load after a lapse

    /// The walk's state when the lapse comes.
    enum LapseWalk: String, CaseIterable, Sendable {
        /// The folder's walk is complete.
        case complete
        /// The folder's walk is unfinished, its page token mid-folder.
        case unfinished
        /// The walk is complete and a finite storage limit is in force.
        case storageLimit
    }

    /// How many new Inbox messages arrive during the lapse, and how many of them
    /// the full sync's window inserts (the newest).
    private static let lapseNewCount = 200
    private static let lapseWindowCount = 50

    /// An Inbox with ten old local rows (30 to 39 days ago) the first listing has
    /// covered, then a lapse during which `lapseNewCount` new messages arrive,
    /// half an hour apart, `n0` the newest. The full sync after the lapse inserts
    /// the newest `lapseWindowCount`; the rest have no row. Returns the new ids,
    /// newest first.
    private static func lapseWithNewMail(_ world: World, _ clock: Clock, walk: LapseWalk) async throws -> [String] {
        await pass(world, [inboxPath], context: unlimited(storageLimit: walk == .storageLimit, at: { clock.now }))
        #expect(try state(world, inboxPath)?.lastCompletedAt != nil, "precondition: the first listing completed")
        if walk == .unfinished { try setPartialWalk(world, inboxPath, pageToken: "5") }

        let ids = (0..<lapseNewCount).map { "n\($0)" }
        var window: [Local] = []
        for (index, id) in ids.enumerated() {
            let date = clock.hoursAgo(1 + Double(index) / 2)
            world.server.addMessage(seed(id, date, [inboxPath]))
            if index < lapseWindowCount { window.append(Local(id: id, path: inboxPath, date: date, isRead: false)) }
        }
        try insert(window, accountId: world.accountId, pool: world.pool)
        try await lapse(world)
        return ids
    }

    private static func lapseWorld(_ clock: Clock) -> (seeds: [StatefulGmailActionServer.Seed], local: [Local]) {
        let days = (0..<10).map { 30 + Double($0) }
        return (days.enumerated().map { seed("o\($0.offset)", clock.daysAgo($0.element), [inboxPath]) },
                days.enumerated().map { Local(id: "o\($0.offset)", path: inboxPath, date: clock.daysAgo($0.element)) })
    }

    /// The history expires (404) and 200 new Inbox messages arrived meanwhile:
    /// the full sync inserts the newest 50, and the listing after the lapse loads
    /// the other 150 itself, whatever the walk's state and under a storage limit
    /// too (they are newer than the oldest kept row). The walk is never touched.
    /// Before the direct load, the check asked for a re-arm, which was declined
    /// for an unfinished walk and under a storage limit, and an accepted re-arm
    /// only restarted a walk that lists from the top down.
    @Test("After a lapse, new Inbox mail beyond the sync window is loaded by the check, whatever the walk's state, under a storage limit too",
          .enabled(if: !NetworkMonitor.checkExpensive()),
          arguments: LapseWalk.allCases)
    func lapseLoadsNewMailBeyondTheWindow(walk: LapseWalk) async throws {
        let clock = Clock()
        let (seeds, local) = Self.lapseWorld(clock)
        try await Self.withWorld("gcu-lapse-load-\(walk.rawValue)", seeds: seeds, local: local) { world async throws in
            let ids = try await Self.lapseWithNewMail(world, clock, walk: walk)
            let before = try Self.folder(world, inboxPath)
            let missing = Array(ids.dropFirst(Self.lapseWindowCount))
            #expect(try Self.rows(world, inboxPath)[missing[0]] == nil, "precondition: beyond the window has no row")

            let at = clock.now.addingTimeInterval(60)
            await Self.pass(world, [inboxPath], context: Self.unlimited(storageLimit: walk == .storageLimit, at: { at }))

            let inbox = try Self.rows(world, inboxPath)
            let absent = ids.filter { inbox[$0] == nil }
            #expect(absent.isEmpty, "all \(ids.count) new messages have a row; absent: \(absent.prefix(10))")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == at, "the listing after the lapse completed")
            #expect(Set(world.server.fullMessageGets()) == Set(missing), "exactly the missing ones were fetched")
            let after = try Self.folder(world, inboxPath)
            #expect(after.backfillComplete == before.backfillComplete && after.backfillPageToken == before.backfillPageToken
                        && after.backfillVersion == before.backfillVersion, "the walk is never touched")
        }
    }

    /// A pass budget that runs out part way through a range's loads: what loaded
    /// stays, newest first; the range is not passed and the next pass lists the
    /// same page again and loads the rest, until all 200 have a row. No pass goes
    /// past its budget by more than one batch of concurrent loads.
    @Test("A budget that runs out mid-range loads the newest first and the next passes load the rest",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func directLoadResumesAcrossPasses() async throws {
        let clock = Clock()
        let (seeds, local) = Self.lapseWorld(clock)
        let batch = BackfillProfile.normal.gmailBodyConcurrency
        let budget = 3 * batch - 1
        try await Self.withWorld("gcu-lapse-load-budget", seeds: seeds, local: local) { world async throws in
            let ids = try await Self.lapseWithNewMail(world, clock, walk: .complete)
            let missing = Array(ids.dropFirst(Self.lapseWindowCount))

            var passes = 0
            while try Self.state(world, inboxPath)?.listing != nil || passes == 0, passes < 2 * missing.count / batch {
                let requestsBefore = world.server.http.recordedCalls().count
                await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, budget))
                let spent = world.server.http.recordedCalls().count - requestsBefore
                #expect(spent <= budget + batch - 1, "pass \(passes) made \(spent) requests on a budget of \(budget)")
                if passes == 0 {
                    let inbox = try Self.rows(world, inboxPath)
                    let loaded = missing.filter { inbox[$0] != nil }
                    #expect(!loaded.isEmpty && loaded.count < missing.count, "precondition: the first pass loads part: \(loaded.count)")
                    #expect(loaded == Array(missing.prefix(loaded.count)), "the first pass loads the newest first")
                    #expect(try Self.state(world, inboxPath)?.listing?.range != nil, "the range is not passed")
                }
                passes += 1
            }
            let inbox = try Self.rows(world, inboxPath)
            #expect(ids.allSatisfy { inbox[$0] != nil }, "all \(ids.count) new messages have a row after \(passes) passes")
            #expect(try Self.state(world, inboxPath)?.listing == nil, "the listing completed")
        }
    }

    /// One missing id that is gone (404) never wedges its range: it counts as
    /// done, the other 199 show and the range completes in the same pass.
    @Test("A missing id answered 404 counts as done: the other 199 show and the listing completes in the same pass",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func goneMissingIdNeverWedgesARange() async throws {
        let clock = Clock()
        let (seeds, local) = Self.lapseWorld(clock)
        try await Self.withWorld("gcu-lapse-load-404", seeds: seeds, local: local) { world async throws in
            let ids = try await Self.lapseWithNewMail(world, clock, walk: .complete)
            let gone = ids[ids.count / 2 + Self.lapseWindowCount / 2]
            world.server.injectGetFailure(providerMessageId: gone, .status(404))

            let at = clock.now.addingTimeInterval(60)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))

            let inbox = try Self.rows(world, inboxPath)
            #expect(ids.filter { inbox[$0] != nil }.count == ids.count - 1, "the other \(ids.count - 1) show")
            #expect(inbox[gone] == nil)
            #expect(world.server.getFailuresServedCount(providerMessageId: gone) == 1, "precondition: its GET was answered 404, once")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == at, "the listing completes in the same pass")
        }
    }

    /// One missing id whose GET keeps answering 503 holds its range, as a held
    /// page holds the walk, for `SyncConfig.backfillPageHoldMinutes` wall-clock
    /// from the range's first hold; once the clock passes the bound it counts as
    /// done and the range completes. The other 199 show from the first pass.
    @Test("A missing id answered 503 holds its range until the hold bound, then the range completes; the other 199 show",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func failingMissingIdHoldsTheRangeUntilTheBound() async throws {
        let clock = Clock()
        let (seeds, local) = Self.lapseWorld(clock)
        try await Self.withWorld("gcu-lapse-load-503", seeds: seeds, local: local) { world async throws in
            defer { SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = nil } }
            let ids = try await Self.lapseWithNewMail(world, clock, walk: .complete)
            let failing = ids[ids.count / 2 + Self.lapseWindowCount / 2]
            world.server.injectGetFailure(providerMessageId: failing, .status(503))
            let completedBefore = try Self.state(world, inboxPath)?.lastCompletedAt
            let at = clock.now.addingTimeInterval(60)
            func holdClock(_ offset: TimeInterval) {
                SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = at.addingTimeInterval(offset) }
            }

            holdClock(0)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))
            #expect(try Self.state(world, inboxPath)?.listing?.range?.loadHeldSince == at, "the range is held from now")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == completedBefore, "the listing does not complete")
            var inbox = try Self.rows(world, inboxPath)
            #expect(ids.filter { inbox[$0] != nil }.count == ids.count - 1, "the other \(ids.count - 1) show")

            holdClock(SyncConfig.backfillPageHoldSeconds - 1)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))
            #expect(try Self.state(world, inboxPath)?.listing?.range?.loadHeldSince == at, "inside the bound it stays held from its first hold")

            holdClock(SyncConfig.backfillPageHoldSeconds + 1)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))
            #expect(try Self.state(world, inboxPath)?.listing == nil, "past the bound the range completes")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == at)
            inbox = try Self.rows(world, inboxPath)
            #expect(inbox[failing] == nil && ids.filter { inbox[$0] != nil }.count == ids.count - 1)
            #expect(world.server.getFailuresServedCount(providerMessageId: failing) == 3, "precondition: answered 503 at each pass")
        }
    }

    // MARK: - An id listed twice in one pass, and loads that do not land

    /// Two local Inbox rows, `l0` a day old and `l1` two days old (one range),
    /// and two server messages no row holds: `m` between them, `x` older.
    private static func twoMissingWorld(_ clock: Clock) -> (seeds: [StatefulGmailActionServer.Seed], local: [Local]) {
        let dates = (l0: clock.daysAgo(1), m: clock.daysAgo(1.5), l1: clock.daysAgo(2), x: clock.daysAgo(2.5))
        return ([seed("l0", dates.l0, [inboxPath]), seed("m", dates.m, [inboxPath]),
                 seed("l1", dates.l1, [inboxPath]), seed("x", dates.x, [inboxPath])],
                [Local(id: "l0", path: inboxPath, date: dates.l0), Local(id: "l1", path: inboxPath, date: dates.l1)])
    }

    /// How many `format=full` GETs named `id`.
    private static func fullGets(_ world: World, _ id: String) -> Int {
        world.server.fullMessageGets().filter { $0 == id }.count
    }

    /// Make every insert of a message header with `messageId` fail, as a write
    /// that throws inside the insert's transaction does.
    private static func failInserts(of messageId: String, _ world: World) throws {
        try world.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER test_failInsert BEFORE INSERT ON messageHeader
                WHEN NEW.messageId = '\(messageId)'
                BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END
                """)
        }
    }

    private static func healInserts(_ world: World) throws {
        try world.pool.write { db in try db.execute(sql: "DROP TRIGGER test_failInsert") }
    }

    /// The property every pass keeps: each id it listed as missing is present
    /// locally after it. Here the two ranges' membership windows meet: each is
    /// widened by `catchUpGmailRangeSlackSeconds`, so a message dated exactly
    /// at the newer range's start is listed by both, in the same pass. It loads
    /// once, and it and every other missing message have a row.
    @Test("Every id a pass lists as missing is present after it; an id where two ranges' lists meet loads once",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func idWhereTwoRangesMeetLoadsOnce() async throws {
        let clock = Clock()
        let (l0, l1) = (clock.daysAgo(1), clock.daysAgo(30))
        let newer = CatchUpRange.cut(
            nextBeforeSecond: nil, head: [l0, l1], rowLimit: SyncConfig.catchUpGmailRangeRowLimit,
            maxSpanSeconds: SyncConfig.catchUpGmailRangeMaxSpanSeconds, toEpoch: true)
        let seam = Date(timeIntervalSince1970: TimeInterval(newer.from))
        let missing = [("x1", clock.daysAgo(2)), ("x2", clock.daysAgo(3)), ("x3", clock.daysAgo(4)),
                       ("seam", seam), ("y", clock.daysAgo(20))]
        let seeds = [Self.seed("l0", l0, [inboxPath]), Self.seed("l1", l1, [inboxPath])]
            + missing.map { Self.seed($0.0, $0.1, [inboxPath]) }
        let local = [Local(id: "l0", path: inboxPath, date: l0), Local(id: "l1", path: inboxPath, date: l1)]
        try await Self.withWorld("gcu-seam-once", seeds: seeds, local: local) { world async throws in
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { clock.now }))

            let seamSecond = newer.from
            let listingSeam = world.server.listRequests().filter { request in
                guard request.labelId == inboxPath, let after = request.bound("after"), let before = request.bound("before") else { return false }
                return after < seamSecond && seamSecond < before
            }
            #expect(listingSeam.count == 2, "precondition: both ranges' membership lists cover the seam: \(listingSeam.count)")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == clock.now, "precondition: the listing completed")
            let inbox = try Self.rows(world, inboxPath)
            let absent = missing.map(\.0).filter { inbox[$0] == nil }
            #expect(absent.isEmpty, "every id the pass listed as missing has a row; absent: \(absent)")
            #expect(Self.fullGets(world, "seam") == 1, "the id both ranges list loads once")
        }
    }

    /// A listing in progress when a lapse comes completes in the next pass, and
    /// a new listing starts at once in the same pass and lists the same range
    /// again. The missing ids the first listing loaded are not inserted until the
    /// pass returns; they count as held, so they load once and both show.
    @Test("A listing restarted in the same pass after a lapse loads a missing id once, and nothing is lost",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func lapseRestartInOnePassLoadsOnce() async throws {
        let clock = Clock()
        let (seeds, local) = Self.twoMissingWorld(clock)
        try await Self.withWorld("gcu-lapse-restart-once", seeds: seeds, local: local) { world async throws in
            // The first listing's membership list, then the budget runs out
            // before its loads: the listing is in progress.
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 1))
            #expect(try Self.state(world, inboxPath)?.listing?.range != nil, "precondition: the listing is in progress")
            try await Self.lapse(world)

            let listsBefore = world.server.listRequests().filter { $0.labelId == inboxPath }.count
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { clock.now }))

            let membership = world.server.listRequests().filter { $0.labelId == inboxPath }.count - listsBefore
            #expect(membership == 2, "precondition: the listing completed and a new one listed the range again: \(membership)")
            let done = try #require(try Self.state(world, inboxPath))
            #expect(done.listing == nil && !done.lapsedSinceLastListing, "the new listing completed and covers the lapse")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["m"] != nil && inbox["x"] != nil, "both missing messages show")
            #expect(Self.fullGets(world, "m") == 1 && Self.fullGets(world, "x") == 1,
                    "each loads once: m \(Self.fullGets(world, "m")), x \(Self.fullGets(world, "x"))")
        }
    }

    /// The membership list's first page loads `m`; the request for its second
    /// page, carrying the saved token, gets a `400`, so the list starts again
    /// from the range's start and lists `m` again in the same pass. It loads
    /// once, and everything shows.
    @Test("A membership list restarted after a 400 on its token, after a page that loaded, loads that id once",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func badRequestRestartAfterALoadLoadsOnce() async throws {
        let clock = Clock()
        let (seeds, local) = Self.twoMissingWorld(clock)
        try await Self.withWorld("gcu-400-after-load", seeds: seeds, local: local) { world async throws in
            world.server.servePagedListings(pageSize: 2)
            world.server.answerTokenedListsWithUnrelatedBadRequest(count: 1)

            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { clock.now }))

            #expect(world.server.badRequestedPageTokens().count == 1, "precondition: the second page's request got the 400")
            #expect(world.server.listRequests().filter { $0.labelId == inboxPath && $0.pageToken == nil }.count == 2,
                    "precondition: the membership list started over once")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == clock.now, "precondition: the listing completed")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["m"] != nil && inbox["x"] != nil, "both missing messages show")
            #expect(Self.fullGets(world, "m") == 1, "the id the first page loaded loads once: \(Self.fullGets(world, "m"))")
        }
    }

    /// A batch of loads whose timeout fires before one GET answers: the answered
    /// id loads, and the unanswered one is held (no answer is a `hold`), so the
    /// range waits for it instead of passing it over; once it answers it loads.
    @Test("A load batch that times out holds its unanswered ids; they load at a later pass",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func batchTimeoutHoldsUnansweredIds() async throws {
        let clock = Clock()
        let (seeds, local) = Self.twoMissingWorld(clock)
        try await Self.withWorld("gcu-batch-timeout", seeds: seeds, local: local) { world async throws in
            defer { SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = nil } }
            let at = clock.now
            SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = at }
            world.server.holdGet(providerMessageId: "m", forSeconds: SyncConfig.catchUpRequestTimeoutSeconds + 2)

            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))

            var inbox = try Self.rows(world, inboxPath)
            #expect(inbox["x"] != nil && inbox["m"] == nil, "precondition: the answered id loaded, the unanswered one did not")
            #expect(try Self.state(world, inboxPath)?.listing?.range?.loadHeldSince == at, "the unanswered id holds the range")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == nil, "the listing does not pass it over")

            world.server.holdGet(providerMessageId: "m", forSeconds: 0)
            SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = at.addingTimeInterval(60) }
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))

            inbox = try Self.rows(world, inboxPath)
            #expect(inbox["m"] != nil, "the held id loads once it answers")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == at, "then the listing completes")
        }
    }

    /// The insert of a loaded message fails (its write transaction throws), so
    /// its chunk rolls back. The pass writes no catch-up state: the range stays
    /// unlisted and the next pass lists it again, and once the write succeeds
    /// both messages show.
    @Test("A failed insert of loaded mail writes no catch-up state; the range is listed and loaded again",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func failedInsertKeepsTheRangeUnlisted() async throws {
        let clock = Clock()
        let (seeds, local) = Self.twoMissingWorld(clock)
        try await Self.withWorld("gcu-insert-fails", seeds: seeds, local: local) { world async throws in
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 1))
            let before = try Self.folder(world, inboxPath).catchUpState
            #expect(GmailCatchUpState.decode(before)?.listing?.range != nil, "precondition: the listing is in progress")
            try Self.failInserts(of: "m", world)

            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { clock.now }))

            #expect(Self.fullGets(world, "m") == 1, "precondition: m was loaded")
            #expect(try Self.rows(world, inboxPath)["m"] == nil, "precondition: its insert failed")
            #expect(try Self.folder(world, inboxPath).catchUpState == before, "the state is as it was: the range stays unlisted")

            try Self.healInserts(world)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { clock.now }))

            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["m"] != nil && inbox["x"] != nil, "the next pass lists the range again and both show")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == clock.now)
        }
    }

    /// The hold clock is per page. Page A holds at T and loads at a later pass,
    /// so its page moves on; page B of the same range then holds more than the
    /// bound after T. It is held from its own first hold, not passed over.
    @Test("A hold on a later page starts its own bound once an earlier page of the range has loaded",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func laterPageHoldStartsItsOwnBound() async throws {
        let clock = Clock()
        let dates = (l0: clock.daysAgo(1), a: clock.daysAgo(2), b: clock.daysAgo(3), l1: clock.daysAgo(4))
        let seeds = [Self.seed("l0", dates.l0, [inboxPath]), Self.seed("a", dates.a, [inboxPath]),
                     Self.seed("b", dates.b, [inboxPath]), Self.seed("l1", dates.l1, [inboxPath])]
        let local = [Local(id: "l0", path: inboxPath, date: dates.l0), Local(id: "l1", path: inboxPath, date: dates.l1)]
        try await Self.withWorld("gcu-hold-per-page", seeds: seeds, local: local) { world async throws in
            defer { SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = nil } }
            // Page A is [l0, a], page B is [b, l1].
            world.server.servePagedListings(pageSize: 2)
            let at = clock.now
            func holdClock(_ offset: TimeInterval) {
                SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = at.addingTimeInterval(offset) }
            }

            world.server.injectGetFailure(providerMessageId: "a", .status(503))
            holdClock(0)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))
            #expect(try Self.state(world, inboxPath)?.listing?.range?.loadHeldSince == at, "precondition: page A holds at T")

            world.server.clearGetFailure(providerMessageId: "a")
            world.server.injectGetFailure(providerMessageId: "b", .status(503))
            let later = SyncConfig.backfillPageHoldSeconds + 60
            holdClock(later)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))

            #expect(try Self.rows(world, inboxPath)["a"] != nil, "precondition: page A loaded and its page moved on")
            #expect(world.server.getFailuresServedCount(providerMessageId: "b") == 1, "precondition: page B's id failed")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == nil, "page B's id is held, not passed over")
            #expect(try Self.state(world, inboxPath)?.listing?.range?.loadHeldSince == at.addingTimeInterval(later),
                    "page B is held from its own first hold")

            world.server.clearGetFailures()
            holdClock(later + 60)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))
            #expect(try Self.rows(world, inboxPath)["b"] != nil, "page B's id loads once it answers")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == at)
        }
    }

    /// The hold clock belongs to the page token: a held page whose saved token
    /// then gets a `400` starts its list over, and the clock goes with the token.
    /// Page B holds at T. More than the bound later, a new message `c` arrives
    /// on the first page and its GET fails too, and the saved token gets a `400`.
    /// The list starts over, and the first page's hold is held from its own
    /// first hold, not passed over on page B's old clock; once `c` answers it
    /// loads.
    @Test("A held page whose saved token gets a 400 clears its hold clock; the restarted list's hold starts its own bound",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func badRequestRestartOfAHeldPageClearsItsHoldClock() async throws {
        let clock = Clock()
        let dates = (l0: clock.daysAgo(1), c: clock.daysAgo(1.5), a: clock.daysAgo(2), b: clock.daysAgo(3), l1: clock.daysAgo(4))
        let seeds = [Self.seed("l0", dates.l0, [inboxPath]), Self.seed("a", dates.a, [inboxPath]),
                     Self.seed("b", dates.b, [inboxPath]), Self.seed("l1", dates.l1, [inboxPath])]
        let local = [Local(id: "l0", path: inboxPath, date: dates.l0), Local(id: "l1", path: inboxPath, date: dates.l1)]
        try await Self.withWorld("gcu-400-held-page", seeds: seeds, local: local) { world async throws in
            defer { SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = nil } }
            // Page A is [l0, a], page B is [b, l1].
            world.server.servePagedListings(pageSize: 2)
            let at = clock.now
            func holdClock(_ offset: TimeInterval) {
                SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = at.addingTimeInterval(offset) }
            }

            world.server.injectGetFailure(providerMessageId: "b", .status(503))
            holdClock(0)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))
            let held = try Self.state(world, inboxPath)?.listing?.range
            #expect(held?.loadHeldSince == at && held?.pageToken != nil, "precondition: page B, on a saved token, holds at T")
            #expect(try Self.rows(world, inboxPath)["a"] != nil, "precondition: page A loaded")

            // Past the bound: b answers, c arrives on the first page (now
            // [l0, c]) and fails, and the saved token gets a 400.
            world.server.clearGetFailure(providerMessageId: "b")
            world.server.addMessage(Self.seed("c", dates.c, [inboxPath]))
            world.server.injectGetFailure(providerMessageId: "c", .status(503))
            world.server.answerTokenedListsWithUnrelatedBadRequest(count: 1)
            let later = SyncConfig.backfillPageHoldSeconds + 60
            holdClock(later)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))

            #expect(world.server.badRequestedPageTokens().count == 1, "precondition: the saved token got the 400")
            #expect(world.server.getFailuresServedCount(providerMessageId: "c") == 1, "precondition: c's GET failed")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == nil, "c is held, not passed over")
            #expect(try Self.state(world, inboxPath)?.listing?.range?.loadHeldSince == at.addingTimeInterval(later),
                    "the restarted list's hold starts its own bound")

            world.server.clearGetFailures()
            holdClock(later + 60)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["c"] != nil && inbox["b"] != nil, "c and b load once they answer")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == at)
        }
    }

    // MARK: - Loads that stop on the pass budget

    /// Two local Inbox rows, one and three days old (one range: inside
    /// `catchUpGmailRangeMaxSpanSeconds`), and more server messages between
    /// them that no row holds than one load batch
    /// (`BackfillProfile.normal.gmailBodyConcurrency`) takes.
    private static func pastOneBatchWorld(_ clock: Clock) -> (seeds: [StatefulGmailActionServer.Seed], local: [Local], missing: [String]) {
        let batch = BackfillProfile.normal.gmailBodyConcurrency
        let missing = (0..<(batch + 2)).map { (id: "s\($0)", date: clock.daysAgo(1.1 + 0.15 * Double($0))) }
        let local = [Local(id: "l0", path: inboxPath, date: clock.daysAgo(1)), Local(id: "l1", path: inboxPath, date: clock.daysAgo(3))]
        return (local.map { Self.seed($0.id, $0.date, [inboxPath]) } + missing.map { Self.seed($0.id, $0.date, [inboxPath]) },
                local, missing.map(\.id))
    }

    /// Every load GET of `ids` answers only after the request timeout.
    private static func stallLoads(_ world: World, _ ids: [String]) {
        for id in ids { world.server.holdGet(providerMessageId: id, forSeconds: SyncConfig.catchUpRequestTimeoutSeconds + 2) }
    }

    /// The pass budget covers the membership list and one batch of loads, and
    /// every GET of the batch times out: the loads stop on the budget with every
    /// id they asked for held. The page is held, so its hold clock starts.
    @Test("Loads that time out under a pass budget smaller than one batch start the hold clock",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func budgetStoppedHoldStartsTheClock() async throws {
        let clock = Clock()
        let (seeds, local, missing) = Self.pastOneBatchWorld(clock)
        try await Self.withWorld("gcu-budget-hold", seeds: seeds, local: local) { world async throws in
            defer { SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = nil } }
            let at = clock.now
            SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = at }
            Self.stallLoads(world, missing)

            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 2))

            let gets = world.server.fullMessageGets().count
            #expect(gets > 0 && gets <= BackfillProfile.normal.gmailBodyConcurrency,
                    "precondition: one batch was asked for, then the budget was spent: \(gets) GETs")
            let state = try #require(try Self.state(world, inboxPath))
            #expect(state.lastCompletedAt == nil && state.listing?.range?.step == .membership, "precondition: the page is not passed over")
            #expect(state.listing?.range?.loadHeldSince == at, "the held page starts the hold clock")
        }
    }

    /// A link where every load times out, under a pass budget smaller than one
    /// batch: the page is held from its first hold; once the hold bound has
    /// passed, the held ids and the ids never asked for count as done, the page
    /// moves on, and the listing completes without asking for them again.
    @Test("On a link where every load times out, past the hold bound the page moves on and the listing completes",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func slowLinkHoldEndsAtTheBound() async throws {
        let clock = Clock()
        let (seeds, local, missing) = Self.pastOneBatchWorld(clock)
        try await Self.withWorld("gcu-slow-link", seeds: seeds, local: local) { world async throws in
            defer { SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = nil } }
            let at = clock.now
            func holdClock(_ offset: TimeInterval) {
                SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = at.addingTimeInterval(offset) }
            }
            Self.stallLoads(world, missing)

            holdClock(0)
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 2))
            #expect(try Self.state(world, inboxPath)?.listing?.range?.loadHeldSince == at, "precondition: the page is held from now")

            holdClock(SyncConfig.backfillPageHoldSeconds + 1)
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 2))
            let moved = try #require(try Self.state(world, inboxPath)?.listing?.range, "precondition: the range is in progress")
            #expect(moved.step == .unread && moved.loadHeldSince == nil, "past the bound the page moves on")

            let getsBefore = world.server.fullMessageGets().count
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == at, "the listing completes")
            #expect(world.server.fullMessageGets().count == getsBefore, "the ids counted done are not asked for again in this listing")
            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["l0"] != nil && inbox["l1"] != nil && missing.allSatisfy { inbox[$0] == nil })
        }
    }

    /// Loads that stop on the budget with nothing loaded hold the page; loads
    /// that stop on it after loading some show the page is moving, so its clock
    /// starts again at its next hold. A page whose loads keep moving is never
    /// passed over for an earlier hold, however long it takes, and every id
    /// loads.
    @Test("Loads that stop on the budget after loading some restart the hold clock, so a moving page is never passed over",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func budgetStopAfterLoadsRestartsTheHoldClock() async throws {
        let clock = Clock()
        let (seeds, local, missing) = Self.pastOneBatchWorld(clock)
        try await Self.withWorld("gcu-budget-moving", seeds: seeds, local: local) { world async throws in
            defer { SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = nil } }
            let at = clock.now
            func holdClock(_ offset: TimeInterval) {
                SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = at.addingTimeInterval(offset) }
            }
            let bound = SyncConfig.backfillPageHoldSeconds

            // The list alone spends the budget: no id is asked for.
            holdClock(0)
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 1))
            #expect(world.server.fullMessageGets().isEmpty, "precondition: no load was asked for")
            #expect(try Self.state(world, inboxPath)?.listing?.range?.loadHeldSince == at, "loads that loaded nothing hold the page")

            // Past the bound, one batch loads before the budget is spent.
            holdClock(bound + 1)
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 2))
            let afterOneBatch = try Self.rows(world, inboxPath)
            #expect(missing.filter { afterOneBatch[$0] != nil }.count == BackfillProfile.normal.gmailBodyConcurrency,
                    "precondition: one batch loaded")
            let moving = try #require(try Self.state(world, inboxPath)?.listing?.range, "precondition: the range is in progress")
            #expect(moving.step == .membership && moving.loadHeldSince == nil, "the page moved: it is listed again, its clock cleared")

            // The list alone spends the budget again: held from now, not from the first hold.
            holdClock(bound + 2)
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 1))
            let held = try #require(try Self.state(world, inboxPath)?.listing?.range, "the page is not passed over")
            #expect(held.step == .membership && held.loadHeldSince == at.addingTimeInterval(bound + 2))

            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))
            let inbox = try Self.rows(world, inboxPath)
            #expect(missing.allSatisfy { inbox[$0] != nil }, "every id loads: absent \(missing.filter { inbox[$0] == nil })")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == at)
        }
    }

    /// A lapse keeps the listing's place: the listing goes on from where it
    /// stopped, and because the lapse came after it started, a new listing
    /// starts as soon as it completes and repairs a change in a range the first
    /// had already passed.
    @Test("A lapse during a listing keeps its progress, and a new listing starts as soon as it completes")
    func lapseKeepsTheListingsProgress() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 5)
        try await Self.withWorld("gcu-lapse-progress", seeds: seeds, local: local) { world async throws in
            // The newest range's three lists and the next range's membership list.
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 4))
            let before = try #require(try Self.state(world, inboxPath)?.listing, "precondition: the listing is in progress")
            #expect(before.nextBeforeSecond != nil && before.range != nil, "precondition: a range was listed and the next is in progress")

            try await Self.lapse(world)
            let lapsed = try #require(try Self.state(world, inboxPath))
            #expect(lapsed.listing == before, "the lapse keeps the listing's place")
            #expect(lapsed.lapseCount == 1)

            // Changed elsewhere, in the history the lapse lost: the newest
            // message, whose range the listing already passed.
            world.server.applyLabelChange(providerMessageId: "g4", add: ["UNREAD"])
            let listsBefore = world.server.listRequests().count
            await Self.pass(world, [inboxPath])
            let membership = world.server.listRequests().dropFirst(listsBefore).filter { $0.labelId == inboxPath }
            #expect(membership.count == 3 + 5,
                    "the listing goes on from its place (three more ranges), then a new listing lists all five")
            #expect(try Self.rows(world, inboxPath)["g4"]?.isRead == false,
                    "the new listing repairs a change in a range the first had passed")
            let done = try #require(try Self.state(world, inboxPath))
            #expect(done.listing == nil && done.lastCompletedAt != nil && !done.lapsedSinceLastListing,
                    "the new listing completed and covers the lapse")
        }
    }

    /// Lapses every second pass never push the repair back: the listing keeps
    /// its place across them, so the oldest message's change is repaired within
    /// one listing, and a change behind the listing (to the newest message, just
    /// after its range was listed) is repaired by the listing that starts at once.
    @Test("With a lapse every second pass, changes to the oldest and the newest message are still repaired within two listings")
    func changesAreRepairedDespiteRecurringLapses() async throws {
        let clock = Clock()
        let count = 8
        let budget = 4
        let passesPerListing = (count * 3 + budget - 1) / budget
        let (seeds, local) = Self.rangesWorld(clock, count: count)
        let newest = "g\(count - 1)"
        try await Self.withWorld("gcu-lapse-every-2", seeds: seeds, local: local) { world async throws in
            world.server.applyLabelChange(providerMessageId: "g0", add: ["UNREAD"])
            var oldestRepairedAt: Int?
            var newestRepairedAt: Int?
            for index in 0..<(3 * passesPerListing) {
                if index > 0 && index % 2 == 0 { try await Self.lapse(world) }
                await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, budget))
                if index == 0 {
                    #expect(try Self.state(world, inboxPath)?.listing?.nextBeforeSecond != nil,
                            "precondition: the newest range was listed in the first pass")
                    world.server.applyLabelChange(providerMessageId: newest, add: ["STARRED"])
                }
                let inbox = try Self.rows(world, inboxPath)
                if oldestRepairedAt == nil, inbox["g0"]?.isRead == false { oldestRepairedAt = index }
                if newestRepairedAt == nil, inbox[newest]?.isFlagged == true { newestRepairedAt = index }
            }
            #expect(try Self.state(world, inboxPath)?.lapseCount ?? 0 >= 3, "precondition: the lapses came")
            #expect(oldestRepairedAt.map { $0 < passesPerListing } == true,
                    "the oldest message is repaired within one listing: \(String(describing: oldestRepairedAt))")
            #expect(newestRepairedAt.map { $0 <= 2 * passesPerListing } == true,
                    "a change behind the listing is repaired by the next one: \(String(describing: newestRepairedAt))")
        }
    }

    @Test("Newest first: a change to recent mail is repaired by a pass that lists no older range")
    func newestRangeIsListedFirst() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 5)
        try await Self.withWorld("gcu-newest-first", seeds: seeds, local: local) { world async throws in
            world.server.applyLabelChange(providerMessageId: "g4", add: ["UNREAD"])
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 3))
            #expect(try Self.rows(world, inboxPath)["g4"]?.isRead == false, "the recent change is repaired by the first range")
            let floor = Int(clock.daysAgo(110).timeIntervalSince1970) + 1
                - SyncConfig.catchUpGmailRangeMaxSpanSeconds - SyncConfig.catchUpGmailRangeSlackSeconds
            let lists = world.server.listRequests()
            #expect(lists.count == 3, "precondition: one range's three lists")
            for list in lists {
                #expect((list.bound("after") ?? 0) >= floor, "no older range is listed first: \(list.query)")
            }
            #expect(try Self.rows(world, inboxPath)["g0"] != nil)
        }
    }

    /// A lapse neither restarts nor skips the expensive-network wait: it is
    /// still counted from when the catch-up first saw the folder.
    @Test("A lapse does not restart the expensive-network wait")
    func lapseKeepsTheExpensiveNetworkWait() async throws {
        let clock = Clock()
        let seeds = [Self.seed("i1", clock.daysAgo(30), [inboxPath, "UNREAD"])]
        let local = [Local(id: "i1", path: inboxPath, date: clock.daysAgo(30))]
        try await Self.withWorld("gcu-lapse-wait", seeds: seeds, local: local) { world async throws in
            let start = clock.now
            let wait = SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds
            await Self.pass(world, [inboxPath], context: Self.unlimited(expensive: true, at: { start }))
            #expect(try Self.state(world, inboxPath)?.createdAt == start, "precondition: the wait began")

            try await Self.lapse(world)
            let almost = start.addingTimeInterval(wait - 60)
            await Self.pass(world, [inboxPath], context: Self.unlimited(expensive: true, at: { almost }))
            #expect(world.server.http.recordedCalls().isEmpty, "a lapse does not skip the wait")

            try await Self.lapse(world)
            let over = start.addingTimeInterval(wait + 1)
            await Self.pass(world, [inboxPath], context: Self.unlimited(expensive: true, at: { over }))
            #expect(try Self.rows(world, inboxPath)["i1"]?.isRead == false,
                    "the wait counted from before the lapses is over: the folder is listed")
        }
    }

    // MARK: - In the backfill worker, in slices (#766)

    private static let inboxOnly: [(path: String, role: FolderRole)] = [(inboxPath, .inbox)]

    private static func account(_ world: World) async throws -> Account {
        let accountId = world.accountId
        return try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
    }

    /// A run whose slices are `slice` requests long: its clock advances one second
    /// per request the server has seen since the run began, from `base`. The run
    /// ends after `deadline` requests, or never when nil (a background job whose
    /// deadline is far away).
    private static func requestRun(
        _ server: StatefulGmailActionServer, slice: Int, deadline: Int?, at base: Date = Date()
    ) -> SyncEngine.CatchUpRun {
        let before = server.http.recordedCalls().count
        return SyncEngine.CatchUpRun(
            isExpensiveNetwork: false, storageLimitInForce: false,
            deadline: deadline.map { base.addingTimeInterval(TimeInterval($0)) } ?? .distantFuture,
            sliceSeconds: TimeInterval(slice), intervalSeconds: TimeInterval(slice),
            clock: { base.addingTimeInterval(TimeInterval(server.http.recordedCalls().count - before)) })
    }

    private static func eventually(
        seconds: Double, poll: Duration = .milliseconds(10), _ condition: () throws -> Bool
    ) async rethrows -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if try condition() { return true }
            try? await Task.sleep(for: poll)
        }
        return try condition()
    }

    /// The catch-up takes the account's one-sync-at-a-time turn one slice at a
    /// time: a silent-push delta that arrives while a slice is running starts as
    /// soon as that slice ends, and the run goes on after it.
    @Test("A catch-up slice hands the turn on: a delta that arrives during the catch-up waits at most one slice")
    func sliceHandsTheTurnOn() async throws {
        let clock = Clock()
        let count = 8
        let slice = 3
        let (seeds, local) = Self.rangesWorld(clock, count: count)
        try await Self.withWorld(
            "gcu-slice-turn", seeds: seeds, local: local, folders: Self.inboxOnly,
            concurrency: SyncConfig.imapMaxConnectionCeiling
        ) { world async throws in
            world.server.serveProfile()
            try Self.setAccount(world, cursor: world.server.currentHistoryId(), lastFullSyncAt: Date())
            world.server.holdEveryList(forSeconds: 0.2)
            let account = try await Self.account(world)
            let engine = world.engine
            let server = world.server
            let run = Self.requestRun(server, slice: slice, deadline: nil)
            let catchUp = Task { await engine.runCatchUpRun(account: account, run: run) }

            // The delta arrives while the third slice's first list is in flight.
            let inThirdSlice = await Self.eventually(seconds: 30) { server.listRequests().count >= 2 * slice + 1 }
            #expect(inThirdSlice, "precondition: the catch-up reached its third slice")
            let arrival = server.http.recordedCalls().count
            _ = try await engine.backgroundDeltaSync(account: account)

            let calls = server.http.recordedCalls()
            let history = try #require(
                calls.indices.first { $0 >= arrival && calls[$0].url.contains("/history") }, "precondition: the delta ran")
            let waited = calls[arrival..<history].filter { $0.url.contains("/messages") }.count
            #expect(waited <= slice, "the delta waited for \(waited) catch-up requests; a slice is \(slice)")
            // Every slice here is one range's three lists, so a delta that runs
            // between slices finds a whole number of slices before it.
            let before = calls[..<history].filter { $0.url.contains("/messages") }.count
            #expect(before % slice == 0, "the delta ran inside a slice, after \(before) catch-up requests")

            #expect(await catchUp.value, "the run made progress")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil,
                    "the run goes on after the delta and completes the listing")
            #expect(server.listRequests().filter { $0.labelId == inboxPath }.count == count, "no range is listed twice")
        }
    }

    /// The same through the production entry: the background processing job
    /// (`performBackfill`, real clock and the job's deadline) releases the
    /// account's turn between its slices, so a delta that arrives while the job
    /// runs waits at most one slice plus one request timeout, never the job.
    @Test("The background job hands the turn on between slices: a delta that arrives during it waits at most one slice",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func jobHandsTheTurnOnBetweenSlices() async throws {
        let clock = Clock()
        let count = 20
        let roundTrip = SyncConfig.catchUpSliceSeconds / 10
        let (seeds, local) = Self.rangesWorld(clock, count: count)
        try await Self.withWorld(
            "gcu-job-turn", seeds: seeds, local: local, folders: Self.inboxOnly,
            concurrency: SyncConfig.imapMaxConnectionCeiling
        ) { world async throws in
            world.server.serveProfile()
            try Self.setAccount(world, cursor: world.server.currentHistoryId(), lastFullSyncAt: Date())
            world.server.holdEveryList(forSeconds: roundTrip)
            #expect(Double(count * 3) * roundTrip > 2 * (SyncConfig.catchUpSliceSeconds + SyncConfig.catchUpRequestTimeoutSeconds),
                    "precondition: the job's lists take far longer than one slice")
            let account = try await Self.account(world)
            let engine = world.engine
            let server = world.server
            let deadline = Date().addingTimeInterval(SyncConfig.backgroundBackfillDeadlineSeconds)
            let job = Task { await engine.performBackfill(account: account, deadline: deadline) }

            let started = await Self.eventually(seconds: 30) { server.listRequests().count >= 2 }
            #expect(started, "precondition: the job's catch-up is listing")
            let arrival = Date()
            _ = try await engine.backgroundDeltaSync(account: account)
            let waited = Date().timeIntervalSince(arrival)
            let listingOpen = try Self.state(world, inboxPath)?.listing != nil

            #expect(listingOpen, "precondition: the delta ran while the job's listing was in progress")
            #expect(waited <= SyncConfig.catchUpSliceSeconds + SyncConfig.catchUpRequestTimeoutSeconds,
                    "the delta waited \(waited) s; one slice is at most \(SyncConfig.catchUpSliceSeconds) s plus one request timeout")
            #expect(await job.value, "the job made progress")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "the job goes on after the delta and completes the listing")
        }
    }

    /// A deadline that falls inside a slice cuts that slice short: the slice
    /// ends at the job's deadline, not one slice length after it started.
    @Test("A job's deadline that falls inside a slice ends the slice at the deadline",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func deadlineCutsTheSliceShort() async throws {
        let clock = Clock()
        let slice = SyncConfig.catchUpSliceSeconds
        let roundTrip = slice / 20
        let (seeds, local) = Self.rangesWorld(clock, count: 12)
        try await Self.withWorld("gcu-deadline-in-slice", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            world.server.holdEveryList(forSeconds: roundTrip)
            let account = try await Self.account(world)
            let start = Date()
            let deadline = start.addingTimeInterval(slice / 2)
            #expect(await world.engine.performBackfill(account: account, deadline: deadline))
            let end = Date()
            #expect(try Self.state(world, inboxPath)?.listing != nil, "precondition: the listing needs more than the job")
            #expect(end <= deadline.addingTimeInterval(slice / 4),
                    "the job ran \(end.timeIntervalSince(start)) s; its deadline was \(slice / 2) s")
        }
    }

    /// A background job's deadline that comes mid-listing ends the run there; the
    /// listing is saved and the next run resumes it, so no range is listed twice
    /// and every change arrives.
    @Test("A run that reaches its deadline mid-listing stops there, and the next run resumes from the saved range")
    func deadlineMidListingResumes() async throws {
        let clock = Clock()
        let count = 5
        let slice = 3
        let deadline = 7
        let (seeds, local) = Self.rangesWorld(clock, count: count)
        try await Self.withWorld("gcu-run-deadline", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            world.server.applyLabelChange(providerMessageId: "g0", add: ["UNREAD"])
            world.server.applyLabelChange(providerMessageId: "g\(count - 1)", add: ["STARRED"])
            let account = try await Self.account(world)

            #expect(await world.engine.runCatchUpRun(
                account: account, run: Self.requestRun(world.server, slice: slice, deadline: deadline)))
            #expect(world.server.http.recordedCalls().count <= deadline, "no request starts past the deadline")
            #expect(try Self.state(world, inboxPath)?.listing != nil, "precondition: the deadline came mid-listing")
            #expect(try Self.rows(world, inboxPath)["g\(count - 1)"]?.isFlagged == true,
                    "what the run listed before its deadline is applied")
            #expect(try Self.rows(world, inboxPath)["g0"]?.isRead == true, "precondition: the oldest range was not reached")

            #expect(await world.engine.runCatchUpRun(
                account: account, run: Self.requestRun(world.server, slice: slice, deadline: nil)))
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "the next run completes the listing")
            #expect(world.server.listRequests().filter { $0.labelId == inboxPath }.count == count,
                    "each range's membership list ran once: the next run resumed where the first stopped")
            #expect(try Self.rows(world, inboxPath)["g0"]?.isRead == false, "the oldest range's change arrives")
        }
    }

    /// A run stops after a slice that moved nothing forward, so a folder whose
    /// requests keep failing is tried again at the worker's next cycle, never at
    /// network rate until the deadline.
    @Test("A run stops after a slice that made no progress; it does not retry a failing folder until its deadline")
    func runStopsWithoutProgress() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 3)
        try await Self.withWorld("gcu-run-stuck", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            world.server.failListings(status: 503)
            let account = try await Self.account(world)
            let deadline = 40
            _ = await world.engine.runCatchUpRun(
                account: account, run: Self.requestRun(world.server, slice: 3, deadline: deadline))
            let lists = world.server.listRequests().count
            #expect(lists >= 1, "precondition: the folder was tried")
            #expect(lists <= 2, "the run stopped once a slice made no progress: \(lists) list requests")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == nil)
        }
    }

    /// One foreground backfill cycle (`runBackfill`, no deadline: the production
    /// snapshot and slice) moves the listing forward by one slice, newest range
    /// first, and the worker's next cycles complete it.
    @Test("A foreground backfill cycle makes catch-up progress, one slice per cycle, and the worker completes the listing",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func foregroundCycleMakesProgress() async throws {
        let clock = Clock()
        let count = 3
        let (seeds, local) = Self.rangesWorld(clock, count: count)
        try await Self.withWorld("gcu-fg-cycle", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            // A round trip long enough that one slice cannot list every range.
            let roundTrip = SyncConfig.catchUpSliceSeconds / 4
            world.server.holdEveryList(forSeconds: roundTrip)
            #expect(Double(count * 3) * roundTrip > SyncConfig.catchUpSliceSeconds, "precondition: one slice cannot list the folder")
            world.server.applyLabelChange(providerMessageId: "g0", add: ["UNREAD"])
            world.server.applyLabelChange(providerMessageId: "g\(count - 1)", add: ["UNREAD"])
            let account = try await Self.account(world)

            #expect(await world.engine.runBackfill(account: account), "the cycle reports work, so the worker keeps cycling")
            #expect(try Self.rows(world, inboxPath)["g\(count - 1)"]?.isRead == false, "the newest range's change arrives in the first cycle")
            #expect(try Self.state(world, inboxPath)?.listing != nil, "one cycle runs one slice; the listing is saved")

            await world.engine.startBackfill(account: account)
            let completed = try await Self.eventually(seconds: 60, poll: .milliseconds(100)) {
                try Self.state(world, inboxPath)?.lastCompletedAt != nil
            }
            #expect(completed, "the worker's cycles complete the listing")
            #expect(try Self.rows(world, inboxPath)["g0"]?.isRead == false, "the oldest range's change arrives")
        }
    }

    /// The background processing job (`performBackfill` with the job's deadline,
    /// `SyncConfig.backgroundBackfillDeadlineSeconds`) runs the catch-up after the
    /// walk, slice after slice, until the listing is done.
    @Test("The background processing job runs the catch-up in slices until the listing completes",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func backgroundJobRunsTheCatchUp() async throws {
        let clock = Clock()
        let count = 3
        let (seeds, local) = Self.rangesWorld(clock, count: count)
        try await Self.withWorld("gcu-bg-job", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let roundTrip = SyncConfig.catchUpSliceSeconds / 4
            world.server.holdEveryList(forSeconds: roundTrip)
            #expect(Double(count * 3) * roundTrip > SyncConfig.catchUpSliceSeconds, "precondition: one slice cannot list the folder")
            world.server.applyLabelChange(providerMessageId: "g0", add: ["UNREAD"])
            let account = try await Self.account(world)

            let deadline = Date().addingTimeInterval(SyncConfig.backgroundBackfillDeadlineSeconds)
            #expect(await world.engine.performBackfill(account: account, deadline: deadline))
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "one job completes the listing")
            #expect(try Self.rows(world, inboxPath)["g0"]?.isRead == false, "the oldest range's change arrives")
        }
    }

    /// A slice's request count is charged before each request goes out, and a
    /// batch of concurrent loads is charged its whole width first: a batch that
    /// does not fit in what is left of the count is not sent, not even in part,
    /// so no slice passes its cap. The loads it held back come in a later call.
    @Test("A batch of loads that does not fit in the slice's request count is not sent; no slice passes its cap")
    func loadBatchIsChargedItsWidthFirst() async throws {
        let clock = Clock()
        let width = BackfillProfile.normal.gmailBodyConcurrency
        let missing = (0..<(width + 2)).map { "x\($0)" }
        let seeds = [Self.seed("a", clock.daysAgo(30), [inboxPath]), Self.seed("z", clock.daysAgo(31), [inboxPath])]
            + missing.enumerated().map { Self.seed($0.element, clock.daysAgo(30.1 + 0.05 * Double($0.offset)), [inboxPath]) }
        let local = [Local(id: "a", path: inboxPath, date: clock.daysAgo(30)), Local(id: "z", path: inboxPath, date: clock.daysAgo(31))]
        let cap = width / 2
        try await Self.withWorld("gcu-batch-charge", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            var capped = Self.unlimited()
            capped.maxRequests = cap
            await Self.pass(world, [inboxPath], context: capped)
            let sent = world.server.http.recordedCalls().count
            #expect(sent >= 1, "precondition: the folder was listed")
            #expect(sent <= cap, "a slice capped at \(cap) requests sent \(sent)")
            #expect(world.server.fullMessageGets().isEmpty, "a batch wider than what is left is not sent in part")

            await Self.pass(world, [inboxPath])
            #expect(Set(try Self.rows(world, inboxPath).keys) == Set(["a", "z"] + missing),
                    "the loads held back by the cap come in a later call")
        }
    }

    /// The background processing job runs slices back to back. Each slice sends
    /// at most `SyncConfig.catchUpSliceMaxRequests`, and the next one waits for
    /// the previous slice's window, so the job's request rate stays within
    /// `SyncConfig.catchUpMaxRequestsPerSecond` (half of Gmail's per-user quota),
    /// however fast the link.
    @Test("Back-to-back slices of the background job stay within the catch-up's request rate on a fast link",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func backToBackSlicesStayWithinTheRate() async throws {
        let clock = Clock()
        let cap = SyncConfig.catchUpSliceMaxRequests
        let window = SyncConfig.catchUpSliceIntervalSeconds
        // One message every eight days: a range each, three lists each, far more
        // than three slices can send.
        let count = 2 * cap
        let days = (0..<count).map { 8 * Double($0 + 1) }
        let seeds = days.enumerated().map { Self.seed("r\($0.offset)", clock.daysAgo($0.element), [inboxPath]) }
        let local = days.enumerated().map { Local(id: "r\($0.offset)", path: inboxPath, date: clock.daysAgo($0.element)) }
        try await Self.withWorld("gcu-rate", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let account = try await Self.account(world)
            let start = Date()
            // The deadline falls inside the third window; a fourth could not start before it.
            let deadline = start.addingTimeInterval(2.25 * window)
            #expect(await world.engine.performBackfill(account: account, deadline: deadline))
            let elapsed = Date().timeIntervalSince(start)
            let sent = world.server.http.recordedCalls().count
            let windows = Int((elapsed / window).rounded(.down)) + 1
            #expect(sent > cap, "precondition: the job ran more than one slice (\(sent) requests)")
            #expect(sent <= cap * windows, "\(sent) requests in \(windows) slice windows of at most \(cap)")
            #expect(Double(sent) <= SyncConfig.catchUpMaxRequestsPerSecond * elapsed + Double(cap),
                    "\(sent) requests in \(elapsed) s pass the catch-up's rate")
            #expect(try Self.state(world, inboxPath)?.listing != nil, "precondition: the listing needs more slices")
            #expect(Date() <= deadline.addingTimeInterval(window / 4),
                    "the job never waits for a slice window past its deadline")
        }
    }

    // MARK: - The Wi-Fi-only setting holds back the walk, not the catch-up (#766)

    /// Runs `body` on a simulated expensive (cellular) network with the Wi-Fi-only
    /// setting on, then restores both.
    static func withCellularAndWiFiOnly(_ body: () async throws -> Void) async throws {
        let key = "backgroundSyncWiFiOnly"
        let savedSetting = UserDefaults.standard.object(forKey: key)
        let savedExpensive = NetworkMonitor.checkExpensive()
        UserDefaults.standard.set(true, forKey: key)
        NetworkMonitor.setExpensiveForTesting(true)
        defer {
            UserDefaults.standard.set(savedSetting, forKey: key)
            NetworkMonitor.setExpensiveForTesting(savedExpensive)
        }
        try await body()
    }

    /// A folder whose last listing completed longer ago than the expensive-network
    /// wait, with a lapse since: a listing is due, and on an expensive network it
    /// no longer waits for a non-expensive one.
    private static func lapsedPastTheWait(_ world: World, _ path: String) throws {
        let state = GmailCatchUpState(
            lastCompletedAt: Date().addingTimeInterval(-SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds - 60),
            lapseCount: 1, listedLapseCount: 0)
        let raw = state.encoded()
        let folderId = world.folderId(path)
        try world.pool.write { db in
            try db.execute(sql: "UPDATE folder SET catchUpState = ?, backfillComplete = 0 WHERE id = ?", arguments: [raw, folderId])
        }
    }

    /// The walk's own requests: its page lists (no `after:` bound) and its
    /// `format=full` loads.
    private static func walkRequests(_ server: StatefulGmailActionServer) -> [String] {
        server.http.recordedCalls().map(\.url).filter {
            ($0.contains("/messages?") && !$0.contains("after")) || $0.contains("format=full")
        }
    }

    /// The foreground backfill worker on a cellular network with Wi-Fi-only on:
    /// the walk stays paused, as before; the catch-up runs under its own network
    /// rule, so a lapsed folder whose expensive-network wait has passed is listed
    /// and its changes arrive (ADR-IOS-107 decision 2, 2026-11-12).
    @Test("With Wi-Fi-only on and only cellular, the worker's catch-up lists a lapsed folder past its wait; the walk stays paused")
    func wifiOnlyHoldsTheWorkerWalkNotTheCatchUp() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 3)
        try await Self.withWorld("gcu-wifi-only-worker", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            try await Self.withCellularAndWiFiOnly {
                try Self.lapsedPastTheWait(world, inboxPath)
                world.server.applyLabelChange(providerMessageId: "g0", add: ["UNREAD"])
                let account = try await Self.account(world)

                await world.engine.startBackfill(account: account)
                let listed = try await Self.eventually(seconds: 30, poll: .milliseconds(100)) {
                    try Self.state(world, inboxPath)?.listedLapseCount == 1
                }
                await world.engine.remove(accountId: world.accountId)

                #expect(listed, "the catch-up listed the lapsed folder on cellular with Wi-Fi-only on")
                #expect(try Self.rows(world, inboxPath)["g0"]?.isRead == false, "the lapsed change arrives")
                #expect(Self.walkRequests(world.server).isEmpty,
                        "the walk stays paused on cellular with Wi-Fi-only on: \(Self.walkRequests(world.server))")
            }
        }
    }

    /// The background processing job on a cellular network with Wi-Fi-only on:
    /// its decision (`SyncScheduler.backgroundBackfillPlan`) holds back the walk
    /// only, and the backfill it runs lists the lapsed folder. Low Power Mode
    /// still skips the whole backfill.
    @Test("With Wi-Fi-only on and off Wi-Fi, the background job runs the catch-up, not the walk; Low Power Mode skips both")
    func wifiOnlyHoldsTheJobWalkNotTheCatchUp() async throws {
        typealias S = SyncScheduler
        #expect(S.backgroundBackfillPlan(isLowPowerMode: true, wifiOnly: true, onWiFi: false) == .skip)
        #expect(S.backgroundBackfillPlan(isLowPowerMode: true, wifiOnly: false, onWiFi: true) == .skip)
        #expect(S.backgroundBackfillPlan(isLowPowerMode: false, wifiOnly: true, onWiFi: true) == .run(walkAllowed: true))
        #expect(S.backgroundBackfillPlan(isLowPowerMode: false, wifiOnly: false, onWiFi: false) == .run(walkAllowed: true))
        let offWiFi = S.backgroundBackfillPlan(isLowPowerMode: false, wifiOnly: true, onWiFi: false)
        #expect(offWiFi == .run(walkAllowed: false), "Wi-Fi-only off Wi-Fi still runs the backfill, without the walk")
        guard case .run(let walkAllowed) = offWiFi else { return }

        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 3)
        try await Self.withWorld("gcu-wifi-only-job", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            try await Self.withCellularAndWiFiOnly {
                try Self.lapsedPastTheWait(world, inboxPath)
                world.server.applyLabelChange(providerMessageId: "g0", add: ["UNREAD"])
                let account = try await Self.account(world)

                let deadline = Date().addingTimeInterval(SyncConfig.backgroundBackfillDeadlineSeconds)
                #expect(await world.engine.performBackfill(account: account, deadline: deadline, walkAllowed: walkAllowed))
                #expect(try Self.state(world, inboxPath)?.listedLapseCount == 1, "the job listed the lapsed folder")
                #expect(try Self.rows(world, inboxPath)["g0"]?.isRead == false, "the lapsed change arrives")
                #expect(Self.walkRequests(world.server).isEmpty, "the job's walk stays held back off Wi-Fi")
            }
        }
    }

    /// Not a check: the #766 measurement. Wall time of the real foreground worker
    /// (`startBackfill`) for one full listing of a 10-year Inbox (one message every
    /// two days), with each list request held for `roundTrip` seconds. Runs only
    /// when the test runner's environment sets `TABMAIL_CATCHUP_MEASURE`.
    @Test("Measurement: foreground time for one full listing of a 10-year Inbox",
          .enabled(if: ProcessInfo.processInfo.environment["TABMAIL_CATCHUP_MEASURE"] != nil),
          arguments: [0.0, 0.2])
    func measureForegroundListing(roundTrip: Double) async throws {
        let clock = Clock()
        let days = Array(stride(from: 3650.0, to: 0, by: -2))
        let seeds = days.enumerated().map { Self.seed("m\($0.offset)", clock.daysAgo($0.element), [inboxPath]) }
        let local = days.enumerated().map { Local(id: "m\($0.offset)", path: inboxPath, date: clock.daysAgo($0.element)) }
        try await Self.withWorld("gcu-measure-\(Int(roundTrip * 1000))", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            world.server.holdEveryList(forSeconds: roundTrip)
            let account = try await Self.account(world)
            let profile = await world.engine.getBackfillProfile()
            let start = Date()
            await world.engine.startBackfill(account: account)
            let completed = try await Self.eventually(seconds: 3600, poll: .milliseconds(250)) {
                try Self.state(world, inboxPath)?.lastCompletedAt != nil
            }
            let elapsed = Date().timeIntervalSince(start)
            print("[766-measure] roundTrip=\(roundTrip)s messages=\(days.count) listRequests=\(world.server.listRequests().count) profile=\(profile) seconds=\(String(format: "%.1f", elapsed)) completed=\(completed)")
            #expect(completed)
        }
    }

    // MARK: - Through the foreground poll

    /// The sync world: a full window of recent mail in Inbox and All Mail, and
    /// older mail beyond it. Local rows mirror the server.
    private static func syncWorld(_ clock: Clock) -> (seeds: [StatefulGmailActionServer.Seed], local: [Local]) {
        var seeds: [StatefulGmailActionServer.Seed] = []
        var local: [Local] = []
        for index in 0..<SyncConfig.syncMessageLimit {
            let recent = clock.hoursAgo(Double(index + 1))
            seeds.append(Self.seed("r\(index)", recent, [inboxPath]))
            local.append(Local(id: "r\(index)", path: inboxPath, date: recent))
            let archived = clock.hoursAgo(Double(index + 1) + 0.5)
            seeds.append(Self.seed("ar\(index)", archived, []))
            local.append(Local(id: "ar\(index)", path: allMailPath, date: archived))
        }
        for index in 0..<5 {
            let old = clock.daysAgo(Double(30 + index))
            seeds.append(Self.seed("o\(index)", old, [inboxPath, "UNREAD"]))
            local.append(Local(id: "o\(index)", path: inboxPath, date: old, isRead: false))
        }
        for index in 0..<3 {
            let old = clock.daysAgo(Double(40 + index))
            seeds.append(Self.seed("ao\(index)", old, ["UNREAD"]))
            local.append(Local(id: "ao\(index)", path: allMailPath, date: old, isRead: false))
        }
        return (seeds, local)
    }

    /// One foreground poll, past the recent-sync guard.
    private static func syncPass(_ world: World, engine: SyncEngine? = nil) async throws {
        let accountId = world.accountId
        try await world.pool.write { db in
            _ = try Account.filter(Column("id") == accountId).updateAll(db, Column("lastSyncedAt").set(to: nil as Date?))
        }
        let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
        _ = try await (engine ?? world.engine).sync(account: account)
    }

    /// The backfill worker's cycles (`runBackfill` with no deadline: the walk, then
    /// one catch-up slice), until one does no work, as the worker every poll starts
    /// runs them (#766).
    private static func backfillCycles(_ world: World, engine: SyncEngine? = nil) async throws {
        let accountId = world.accountId
        let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
        for _ in 0..<20 {
            if !(await (engine ?? world.engine).runBackfill(account: account)) { return }
        }
        Issue.record("the backfill cycles kept working")
    }

    /// Every folder's catch-up completed at `at`.
    private static func completeCatchUp(_ world: World, at: Date) async throws {
        await Self.pass(world, [inboxPath, allMailPath], context: Self.unlimited(at: { at }))
        for path in [inboxPath, allMailPath] {
            #expect(try Self.state(world, path)?.lastCompletedAt != nil, "precondition: \(path)'s catch-up completed")
        }
    }

    @Test("G2: after a lapse, an older Inbox read change, an archive and a deletion are applied; the next delta starts at the captured id",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func lapseAppliesOlderChanges() async throws {
        let clock = Clock()
        let (seeds, local) = Self.syncWorld(clock)
        try await Self.withWorld("gcu-g2", seeds: seeds, local: local, folders: Self.syncFolders, userLabels: [:]) { world async throws in
            world.server.serveProfile()
            try await Self.completeCatchUp(world, at: Date())
            try Self.setAccount(world, cursor: world.server.currentHistoryId(), lastFullSyncAt: nil)

            world.server.applyLabelChange(providerMessageId: "o0", remove: ["UNREAD"])
            world.server.applyLabelChange(providerMessageId: "o1", remove: [inboxPath])
            world.server.removeMessage(providerMessageId: "o2")
            world.server.answerHistoryTooLong(true)

            try await Self.syncPass(world)
            try await Self.backfillCycles(world)

            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["o0"]?.isRead == true, "the read change")
            #expect(inbox["o1"] == nil, "the archive")
            #expect(inbox["o2"] == nil, "the deletion")
            #expect(inbox["o3"] != nil && inbox["o4"] != nil)
            let captured = try #require(try Self.cursor(world))
            #expect(captured == world.server.currentHistoryId())

            world.server.answerHistoryTooLong(false)
            world.server.applyLabelChange(providerMessageId: "r0", add: ["UNREAD"])
            let accountId = world.accountId
            let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
            let before = world.server.http.recordedCalls().count
            let outcome = try await world.engine.performDeltaSync(account: account, provider: world.provider)
            #expect(outcome.succeeded)
            let history = world.server.http.recordedCalls().dropFirst(before).filter { $0.url.contains("/history") }
            #expect(history.first?.url.contains("startHistoryId=\(captured)") == true, "the next delta starts at the captured id")
            #expect(try Self.rows(world, inboxPath)["r0"]?.isRead == false)
        }
    }

    /// The relaunched app's foreground pass lists the window, and its backfill
    /// cycles run the catch-up that applies the change to older mail. The
    /// background pass that reads the refusal starts no backfill worker, so
    /// nothing lists before the relaunch. *Superseded (#766):* the relaunched
    /// app's next foreground pass applied the change through the full sync's
    /// catch-up; the catch-up now runs in the backfill worker, which every poll
    /// starts.
    @Test("G3: a refusal read in a background pass survives a relaunch, and the relaunched app's foreground pass and backfill cycles re-list and apply the change",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func lapseSurvivesRelaunch() async throws {
        let clock = Clock()
        let (seeds, local) = Self.syncWorld(clock)
        try await Self.withWorld("gcu-g3", seeds: seeds, local: local, folders: Self.syncFolders, userLabels: [:]) { world async throws in
            world.server.serveProfile()
            try await Self.completeCatchUp(world, at: Date())
            try Self.setAccount(world, cursor: world.server.currentHistoryId(), lastFullSyncAt: Date())

            world.server.applyLabelChange(providerMessageId: "o0", remove: ["UNREAD"])
            world.server.expireHistory()
            // A background pass reads the refusal; it lists nothing and stores
            // no new bookmark.
            let accountId = world.accountId
            let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
            _ = try await world.engine.performDeltaSync(account: account, provider: world.provider)
            #expect(try Self.cursor(world) == nil, "precondition: the expired history cleared the cursor")
            #expect(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) }?.lastFullSyncAt == nil,
                    "the refusal makes the full sync due")
            for path in [inboxPath, allMailPath] {
                let state = try #require(try Self.state(world, path), "the lapse keeps \(path)'s state")
                #expect(state.lapsedSinceLastListing && state.lastCompletedAt != nil,
                        "the lapse marker is written with the cursor, and the schedule is kept")
            }

            let relaunched = SyncEngine()
            let provider = world.server.provider()
            await relaunched.register(
                accountId: world.accountId, provider: provider, workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
            try await Self.syncPass(world, engine: relaunched)
            try await Self.backfillCycles(world, engine: relaunched)
            await relaunched.remove(accountId: world.accountId)

            #expect(try Self.rows(world, inboxPath)["o0"]?.isRead == true, "the change in the lost history is applied")
            #expect(try Self.cursor(world) == world.server.currentHistoryId())
        }
    }

    @Test("G4: a change whose GET keeps failing never holds the bookmark back, and lands on the first pass that reads it",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func failedDeltaFetchIsCaughtUp() async throws {
        let clock = Clock()
        let (seeds, local) = Self.syncWorld(clock)
        try await Self.withWorld("gcu-g4", seeds: seeds, local: local, folders: Self.syncFolders, userLabels: [:]) { world async throws in
            world.server.serveProfile()
            try await Self.completeCatchUp(world, at: Date())
            try Self.setAccount(world, cursor: world.server.currentHistoryId(), lastFullSyncAt: nil)

            world.server.applyLabelChange(providerMessageId: "o0", remove: ["UNREAD"])
            world.server.injectGetFailure(providerMessageId: "o0", .status(503))
            try await Self.syncPass(world)
            #expect(world.server.getFailuresServedCount(providerMessageId: "o0") >= 1, "precondition: the delta's GET of the change failed")
            #expect(try Self.cursor(world) == world.server.currentHistoryId(),
                    "the bookmark moves past the change it could not read")
            #expect(try Self.rows(world, inboxPath)["o0"]?.isRead == false, "precondition: the change has not landed")

            try await Self.syncPass(world)
            #expect(try Self.rows(world, inboxPath)["o0"]?.isRead == false, "still unreadable: still waiting")

            world.server.clearGetFailures()
            try await Self.syncPass(world)
            #expect(try Self.rows(world, inboxPath)["o0"]?.isRead == true, "the first pass that reads it applies the change")
        }
    }
}
