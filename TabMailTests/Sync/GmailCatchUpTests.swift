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

/// ADR-IOS-107 for Gmail: the full sync's catch-up of server-side changes to OLDER
/// mail (a read or starred change, or a message leaving a folder) that no sync
/// window and no delta reaches.
///
/// Every case drives the real `GmailProvider.catchUp` against
/// `StatefulGmailActionServer` (the REST oracle) and applies through the real
/// `SyncEngine.runCatchUp`, or runs the whole foreground poll
/// (`SyncEngine.sync(account:)`: delta, due full sync, cursor capture), then asserts
/// what the user would see: the local rows' read/starred state, which rows exist,
/// and whether the folder's backfill was re-armed. The wire is asserted only where
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

    /// One prepared world. Every folder starts with its backfill complete, so a
    /// re-arm is observable and no background walk runs unless one is re-armed.
    private static func withWorld(
        _ name: String,
        seeds: [StatefulGmailActionServer.Seed],
        local: [Local],
        folders: [(path: String, role: FolderRole)] = GmailCatchUpTests.catchUpFolders,
        userLabels: [String: String] = [labelPath: "Projects"],
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
            accountId: name, provider: provider, workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
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
        expensive: Bool = false, at clock: @escaping @Sendable () -> Date = { Date() }
    ) -> CatchUpContext {
        CatchUpContext(isExpensiveNetwork: expensive, deadline: .distantFuture, clock: clock)
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

    /// Reads and clears the folder's re-armed backfill: true when the catch-up
    /// re-armed it since the last call. Clearing stands in for the walk finishing.
    private static func takeRearm(_ world: World, _ path: String) throws -> Bool {
        let rearmed = try !folder(world, path).backfillComplete
        if rearmed {
            let folderId = world.folderId(path)
            try world.pool.write { db in
                try db.execute(sql: "UPDATE folder SET backfillComplete = 1 WHERE id = ?", arguments: [folderId])
            }
        }
        return rearmed
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

    /// A folder whose walk is complete is listed from the epoch: a message older
    /// than every local row (moved in from another device) is missing, re-arms the
    /// walk, and loads. Nothing newer than the newest local row is listed.
    @Test("A completed folder is listed from the epoch: mail older than every local row re-arms the walk and loads; placeholder ids are never named",
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
            #expect(membership.first?.bound("after") == 0, "the first membership list starts at the epoch: \(membership.first?.query ?? "none")")
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
            #expect(Set(inbox.keys) == ["oldest", "sent-local-1", "newest"], "the check itself inserts nothing")
            let folder = try Self.folder(world, inboxPath)
            #expect(!folder.backfillComplete && folder.backfillPageToken == nil, "the walk is re-armed")

            try await Self.backfillUntilComplete(world)
            #expect(try Self.rows(world, inboxPath)["ancient"] != nil, "the re-armed walk loads the message")
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
                    #expect(inbox["b0"]?.isRead == true, "the first pass's finished range is applied")
                    #expect(inbox["b4"]?.isRead == false, "precondition: one pass cannot finish the folder")
                    #expect(try Self.state(world, inboxPath)?.listing?.nextFromSecond != nil, "the listing is saved")
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

    /// A row that arrived in a range's stretch before its first local row after
    /// the range was cut is named by the membership list (whose window starts at
    /// the range's start) but lies before the flag lists' window. Their silence
    /// about it says nothing, so its flags stay as they are.
    @Test("A row dated before the flag lists' window keeps its flags")
    func rowBeforeTheFlagWindowKeepsItsFlags() async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("r1", clock.daysAgo(100), [inboxPath]),
            Self.seed("r2", clock.daysAgo(80), [inboxPath]),
            Self.seed("x", clock.daysAgo(90), [inboxPath, "UNREAD"]),
            Self.seed("y", clock.daysAgo(90).addingTimeInterval(3_600), [inboxPath, "STARRED"]),
        ]
        let local = [
            Local(id: "r1", path: inboxPath, date: clock.daysAgo(100)),
            Local(id: "r2", path: inboxPath, date: clock.daysAgo(80)),
        ]
        try await Self.withWorld("gcu-before-flag-window", seeds: seeds, local: local) { world async throws in
            // The first range's three lists; the second range is cut, and its
            // membership list stops on the budget.
            await Self.pass(world, [inboxPath], context: Self.requestBudget(world.server, 3))
            let cut = try #require(try Self.state(world, inboxPath)?.listing?.range, "precondition: the second range is in progress")
            let lateRows = [
                Local(id: "x", path: inboxPath, date: clock.daysAgo(90), isRead: false),
                Local(id: "y", path: inboxPath, date: clock.daysAgo(90).addingTimeInterval(3_600), isFlagged: true),
            ]
            for row in lateRows {
                let second = Int(row.date.timeIntervalSince1970)
                #expect(second >= cut.range.from && second < cut.range.firstLocal - SyncConfig.catchUpGmailRangeSlackSeconds,
                        "precondition: \(row.id) lies before the flag lists' window")
            }
            try Self.insert(lateRows, accountId: world.accountId, pool: world.pool)

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

    /// The Gmail full check is weekly, and the expensive-network wait is counted
    /// from the last completed listing and is as long as that week: a due weekly
    /// check has already waited as long as the wait allows, so it runs on any
    /// network. Only a folder with no completed listing yet (a new folder, or one
    /// whose state a lapse cleared) still waits for a non-expensive network.
    @Test("The per-folder plan")
    func catchUpPlan() {
        let now = Clock().now
        let week = SyncConfig.gmailCatchUpFullCheckIntervalSeconds
        let fresh = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-60))
        let stale = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-week - 1))
        let running = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-60), listing: .init(nextFromSecond: 42))
        let waiting = GmailCatchUpState(createdAt: now.addingTimeInterval(-60))
        let longWait = GmailCatchUpState(createdAt: now.addingTimeInterval(-SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds - 1))

        #expect(week >= SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds, "precondition: the wait is no longer than the week")
        #expect(GmailProvider.catchUpPlan(state: nil, isExpensiveNetwork: false, now: now) == .list(.init()))
        #expect(GmailProvider.catchUpPlan(state: nil, isExpensiveNetwork: true, now: now) == .none)
        #expect(GmailProvider.catchUpPlan(state: fresh, isExpensiveNetwork: false, now: now) == .none, "weekly, not every pass")
        #expect(GmailProvider.catchUpPlan(state: stale, isExpensiveNetwork: false, now: now) == .list(.init()))
        #expect(GmailProvider.catchUpPlan(state: stale, isExpensiveNetwork: true, now: now) == .list(.init()),
                "a due weekly check has waited as long as the wait allows")
        #expect(GmailProvider.catchUpPlan(state: waiting, isExpensiveNetwork: true, now: now) == .none,
                "a folder with no completed listing waits for a non-expensive network")
        #expect(GmailProvider.catchUpPlan(state: running, isExpensiveNetwork: false, now: now) == .list(.init(nextFromSecond: 42)))
        #expect(GmailProvider.catchUpPlan(state: longWait, isExpensiveNetwork: true, now: now) == .list(.init()))
    }

    /// The schedule: a Gmail folder's full check runs weekly (plus at once
    /// after a lapse clears its state), while IMAP keeps its daily check. Pinned
    /// end to end for Gmail (no request before the week is over, the listing at
    /// it) and through the plan for IMAP.
    @Test("A Gmail folder is checked again only after 7 days; an IMAP folder still daily",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func gmailFullCheckIsWeeklyAndIMAPDaily() async throws {
        let day: TimeInterval = 86_400
        #expect(SyncConfig.gmailCatchUpFullCheckIntervalSeconds == 7 * day, "Gmail: weekly")
        #expect(SyncConfig.catchUpFullCheckIntervalSeconds == day, "IMAP: daily")

        let clock = Clock()
        let seeds = [Self.seed("i1", clock.daysAgo(30), [inboxPath])]
        let local = [Local(id: "i1", path: inboxPath, date: clock.daysAgo(30))]
        try await Self.withWorld("gcu-weekly", seeds: seeds, local: local) { world async throws in
            let start = clock.now
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { start }))
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == start, "precondition: the first check completed")

            // Read elsewhere; no delta in this test, so only a check can bring it.
            world.server.applyLabelChange(providerMessageId: "i1", add: ["UNREAD"])
            for offset in [day + 3_600, 7 * day - 1] {
                let at = start.addingTimeInterval(offset)
                let before = world.server.http.recordedCalls().count
                await Self.pass(world, [inboxPath], context: Self.unlimited(at: { at }))
                #expect(world.server.http.recordedCalls().count == before, "no request \(offset) s after the last check")
                #expect(try Self.rows(world, inboxPath)["i1"]?.isRead == true, "nothing applied \(offset) s after the last check")
            }

            let dueAt = start.addingTimeInterval(7 * day)
            await Self.pass(world, [inboxPath], context: Self.unlimited(at: { dueAt }))
            #expect(try Self.rows(world, inboxPath)["i1"]?.isRead == false, "the check 7 days after the last one applies the change")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == dueAt)
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

    @Test("Ranges tile the local rows: bounded rows, whole seconds, a span cap, ties kept together")
    func catchUpRanges() {
        let base = Int(Clock().daysAgo(100).timeIntervalSince1970)
        let at = { (second: Int) in Date(timeIntervalSince1970: TimeInterval(second)) }
        let week = SyncConfig.catchUpGmailRangeMaxSpanSeconds

        // Fewer rows than the limit: up to the last row's second, inclusive.
        #expect(GmailProvider.catchUpRange(nextFromSecond: nil, head: [at(base), at(base + 10)], rowLimit: 2, maxSpanSeconds: week)
                == .init(from: base, firstLocal: base, upTo: base + 11))
        // More rows than the limit: the cut second goes to the next range.
        #expect(GmailProvider.catchUpRange(nextFromSecond: nil, head: [at(base), at(base + 10), at(base + 20)], rowLimit: 2, maxSpanSeconds: week)
                == .init(from: base, firstLocal: base, upTo: base + 20))
        // More rows than the limit share the first second: the range is that second.
        #expect(GmailProvider.catchUpRange(nextFromSecond: nil, head: [at(base), at(base), at(base)], rowLimit: 2, maxSpanSeconds: week)
                == .init(from: base, firstLocal: base, upTo: base + 1))
        // The span cap, counted from the first local row.
        #expect(GmailProvider.catchUpRange(nextFromSecond: nil, head: [at(base), at(base + 3 * week)], rowLimit: 500, maxSpanSeconds: week)
                == .init(from: base, firstLocal: base, upTo: base + week))
        // A later range starts where the previous one ended, even before its first row.
        #expect(GmailProvider.catchUpRange(nextFromSecond: base - 50, head: [at(base)], rowLimit: 500, maxSpanSeconds: week)
                == .init(from: base - 50, firstLocal: base, upTo: base + 1))
        // A fractional order date belongs to its whole second.
        #expect(GmailProvider.catchUpRange(nextFromSecond: nil, head: [Date(timeIntervalSince1970: TimeInterval(base) + 0.5)], rowLimit: 500, maxSpanSeconds: week)
                == .init(from: base, firstLocal: base, upTo: base + 1))
    }

    // MARK: - The reader accessor and the lapse helper

    @Test("The order-date accessor returns rows in [from, before), by date then id, with their order date")
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

        let bounded = try await reader.rows(folderId: folderId, orderDatesFrom: clock.daysAgo(3), before: clock.daysAgo(1), limit: nil)
        #expect(bounded.map(\.messageId) == ["r2a", "r2b", "r3"])
        #expect(bounded.map(\.orderDate) == [clock.daysAgo(3), clock.daysAgo(3), clock.daysAgo(2)])
        let limited = try await reader.rows(folderId: folderId, orderDatesFrom: clock.daysAgo(3), before: nil, limit: 2)
        #expect(limited.map(\.messageId) == ["r2a", "r2b"])
        let all = try await reader.rows(folderId: folderId, orderDatesFrom: nil, before: nil, limit: nil)
        #expect(all.map(\.messageId) == ["r1", "r2a", "r2b", "r3", "r4"])
    }

    @Test("A cursor lapse clears the cursor and every catch-up state of that account, and nothing else")
    func lapseHelper() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        for id in ["gcu-lapse-a", "gcu-lapse-b"] {
            _ = try FolderEpochTestFixture.makeAccount(id: id, provider: .gmail, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: id, path: inboxPath, role: .inbox, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: id, path: allMailPath, role: .archive, pool: pool)
        }
        try await pool.write { db in
            try db.execute(sql: "UPDATE account SET lastHistoryId = '5'")
            try db.execute(sql: "UPDATE folder SET catchUpState = '{}'")
        }

        try await pool.write { db in try SyncEngine.lapseDeltaCursor(accountId: "gcu-lapse-a", newCursor: "9", db: db) }

        let accounts = try await pool.read { db in try Account.fetchAll(db) }
        #expect(accounts.first { $0.id == "gcu-lapse-a" }?.lastHistoryId == "9")
        #expect(accounts.first { $0.id == "gcu-lapse-b" }?.lastHistoryId == "5")
        let folders = try await pool.read { db in try Folder.fetchAll(db) }
        #expect(folders.filter { $0.accountId == "gcu-lapse-a" }.allSatisfy { $0.catchUpState == nil })
        #expect(folders.filter { $0.accountId == "gcu-lapse-b" }.allSatisfy { $0.catchUpState == "{}" })
        #expect(folders.count == 4)
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

    @Test("The seam stays provider-blind, and the Gmail catch-up never reads the network state itself")
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
        #expect(!gmail.contains("UserDefaults"), "no setting is read mid-pass: what the pass needs comes from the CatchUpContext snapshot")
    }

    /// The walk's two bookkeeping columns, `backfillComplete` and
    /// `backfillPageToken`, are written outside the walk's own compare-and-set
    /// (`advanceBackfillPageWalk`) only at the sites named here: the catch-up
    /// re-arm of a completed walk, the IMAP walk's completions, user and
    /// maintenance resets, and migrations. None of them is a periodic check that
    /// could restart an unfinished walk, so between two re-arms a walk always
    /// completes. A new writer is added here with its reason, or the fence fails.
    @Test("Every write of the walk's columns outside the walk's compare-and-set is a named site")
    func walkColumnWritesAreNamedSites() throws {
        let named: [String: (lines: Int, site: String)] = [
            "TabMail/Services/AppDatabase.swift": (5, "migrations that re-walk folders"),
            "TabMail/Services/StartupMigrations.swift": (4, "startup re-walk resets"),
            "TabMail/Services/Account/AccountManagerUidValidityReset.swift": (2, "the IMAP UIDVALIDITY purge"),
            "TabMail/Services/Demo/DemoSeed.swift": (1, "demo folders start complete"),
            "TabMail/Services/Sync/SyncEngineBackfill.swift": (2, "the fast-sync reset"),
            "TabMail/Services/Sync/SyncEngineBackfillWalk.swift": (
                3, "the IMAP walk's completions (2); the walk's refused-token restart (compare-and-set on the saved token) (1)"),
            "TabMail/Services/Sync/SyncEngineCatchUp.swift": (1, "the catch-up re-arm of a completed walk"),
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

    // MARK: - Seeded re-arm property

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

    /// One random step of the re-arm property.
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
    /// Rounds at rest: a missing id needs at most one check to re-arm a completed
    /// walk, one walk, and one more of each after a walk it overtook.
    private static let rearmPropertyRestRounds = 4

    /// Random server changes, queued and removed actions, failing and healing
    /// GETs, single walk iterations (each held at its next page request while
    /// later steps run), budgeted checks over a clock that moves 0 to 2 days per
    /// check, delta-style inserts, lapses, a new `SyncEngine` on the same
    /// database, the Settings reset, and a second walk completing a folder. After
    /// every step:
    /// - P3: a check never changes the walk position or completion of a folder
    ///   whose walk was unfinished before it.
    /// - P4: a re-arm made while an iteration was held leaves the folder
    ///   unfinished at the top once the iteration is released.
    /// - P2: every re-arm comes with a completed check; re-arms never outnumber
    ///   completed checks.
    /// Then, with the server and the faults at rest, `rearmPropertyRestRounds`
    /// weekly rounds of "check to completion, walk to completion":
    /// - P1: every id the folder's walk lists, dated up to the newest local row
    ///   and protected by no queued action, has a row.
    @Test("Seeded: re-arms stay bounded, never move an unfinished walk, are never lost, and every loadable missing id loads",
          .enabled(if: !NetworkMonitor.checkExpensive()),
          arguments: Array(UInt64(1)...UInt64(24)))
    func seededRearmProperty(seed: UInt64) async throws {
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
            var rearms: [String: Int] = [:]
            var completedChecks: [String: Int] = [:]
            // Folders re-armed while a walk iteration was held; the next step releases it.
            var rearmedWhileHeld: Set<String> = []

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
                    let kind = rearmedWhileHeld.isEmpty ? RearmStep.pick(&rng) : .walk
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
                        // 0 to 2 full-check intervals, so about half the checks are due.
                        now = now.addingTimeInterval(TimeInterval(rng.pick(Int(2 * SyncConfig.gmailCatchUpFullCheckIntervalSeconds) + 1)))
                        let budget = Self.rearmPropertyMinCheckBudget + rng.pick(Self.rearmPropertyCheckBudgetSpread)
                        await engine.runCatchUp(
                            provider: world.provider, folderIds: paths.map(world.folderId),
                            context: Self.requestBudget(world.server, budget, at: now))
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
                    let releasedHeld = kind == .walk ? rearmedWhileHeld : []
                    rearmedWhileHeld = []
                    for path in paths {
                        guard let old = before[path], let new = after[path] else { continue }
                        let oldState = GmailCatchUpState.decode(old.catchUpState)
                        let newState = GmailCatchUpState.decode(new.catchUpState)
                        let rearmed = kind == .check && old.backfillComplete && !new.backfillComplete
                        if releasedHeld.contains(path) {
                            #expect(!new.backfillComplete && new.backfillPageToken == nil,
                                    "\(label) \(path): the released iteration overwrote a re-arm made while it was held")
                        }
                        guard kind == .check else { continue }
                        if !old.backfillComplete {
                            #expect(!new.backfillComplete && new.backfillPageToken == old.backfillPageToken,
                                    "\(label) \(path): a check moved an unfinished walk from \(old.backfillPageToken ?? "the top")")
                        }
                        let completed = newState?.lastCompletedAt != nil && newState?.lastCompletedAt != oldState?.lastCompletedAt
                        if completed { completedChecks[path, default: 0] += 1 }
                        guard rearmed else { continue }
                        rearms[path, default: 0] += 1
                        #expect(completed && new.backfillPageToken == nil, "\(label) \(path): a re-arm without a completed check")
                        if stepper.isParked { rearmedWhileHeld.insert(path) }
                    }
                    for path in paths {
                        #expect(rearms[path, default: 0] <= completedChecks[path, default: 0],
                                "\(label) \(path): \(rearms[path, default: 0]) re-arms, \(completedChecks[path, default: 0]) completed checks")
                    }
                }

                // P1: the server and the faults at rest, weekly rounds.
                await stepper.stop()
                world.server.clearGetFailures()
                for _ in 0..<Self.rearmPropertyRestRounds {
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

    // MARK: - Moved-in mail re-arms the backfill

    @Test("An old message moved from Inbox to a label is loaded into the label by the re-armed backfill",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func moveToLabelRearmsBackfill() async throws {
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
            #expect(try !Self.folder(world, labelPath).backfillComplete, "the label's backfill is re-armed")
            #expect(try Self.rows(world, labelPath)["m"] == nil, "the catch-up itself never inserts")

            try await Self.backfillUntilComplete(world)
            #expect(try Self.rows(world, labelPath)["m"] != nil, "the backfill loads the moved message into the label")
        }
    }

    /// A server id the membership list names in a range whose local rows do not
    /// hold it can still be in the folder locally, under a stored date in another
    /// range (its local date differs from Gmail's). It is not missing: the
    /// folder's own lookup finds it, so nothing is recorded and nothing re-arms.
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
            #expect(try Self.folder(world, labelPath).backfillComplete, "nothing re-armed the backfill")
            #expect(try Self.rows(world, labelPath)["h"] != nil, "the row stays")
        }
    }

    @Test("An old message archived from Inbox is loaded into All Mail by the re-armed backfill",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func archiveRearmsAllMailBackfill() async throws {
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
            #expect(try !Self.folder(world, allMailPath).backfillComplete, "All Mail's backfill is re-armed")

            try await Self.backfillUntilComplete(world)
            #expect(try Self.rows(world, allMailPath)["m"] != nil, "the backfill loads the archived message into All Mail")
        }
    }

    /// A re-arm moves the walk back to the top, so the time the old page was
    /// first held goes with its token: a page the re-armed walk holds later
    /// starts its own hold bound instead of inheriting the old one.
    @Test("A re-arm clears the page hold time together with the page token",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func rearmClearsThePageHoldTime() async throws {
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
        try await Self.withWorld("gcu-rearm-clears-hold", seeds: seeds, local: local) { world async throws in
            let folderId = world.folderId(labelPath)
            let heldSince = clock.hoursAgo(2)
            try await world.pool.write { db in
                try db.execute(
                    sql: "UPDATE folder SET backfillPageHeldSince = ? WHERE id = ?", arguments: [heldSince, folderId])
            }
            #expect(try Self.folder(world, labelPath).backfillPageHeldSince != nil, "precondition: a hold time is stored")

            await Self.pass(world, [labelPath])
            let folder = try Self.folder(world, labelPath)
            #expect(!folder.backfillComplete, "precondition: the check re-armed the walk for m")
            #expect(folder.backfillPageToken == nil, "the walk restarts at the top")
            #expect(folder.backfillPageHeldSince == nil, "the hold time of the cleared token is cleared with it")
        }
    }

    /// A message in a label that is also in Trash (or Spam) is not in the label's
    /// walk: Gmail leaves Spam and Trash mail out of a list that does not ask for
    /// it. The label's check lists what its walk lists, so such a message is not
    /// missing there and re-arms nothing. The Trash folder's own list still asks
    /// for Trash mail, so its row stays.
    @Test("A message in a label that is also in Trash re-arms nothing; the Trash folder still lists it",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func labelledTrashMailRearmsNothing() async throws {
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
            #expect(try Self.folder(world, labelPath).backfillComplete, "nothing re-armed the label's walk")

            #expect(try Self.state(world, trashPath)?.lastCompletedAt != nil, "precondition: the Trash folder's check completed")
            #expect(try Self.rows(world, trashPath)["t"] != nil, "the Trash row stays")
            #expect(try Self.folder(world, trashPath).backfillComplete, "nothing re-armed the Trash folder's walk")

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

    /// Weekly checks a week and an hour apart, so each is due even when its listing
    /// completed a few (request-count) seconds after the check began.
    private static let checkSpacing = SyncConfig.gmailCatchUpFullCheckIntervalSeconds + 3_600

    /// The clock of weekly check `check`.
    private static func checkDay(_ clock: Clock, _ check: Int) -> Date {
        clock.now.addingTimeInterval(Double(check) * checkSpacing)
    }

    /// Removes the folder's row of `id`, as the delta does when the message leaves it.
    private static func removeRow(_ world: World, _ id: String, from path: String) throws {
        let folderId = world.folderId(path)
        try world.pool.write { db in
            _ = try MessageHeader.filter(Column("folderId") == folderId && Column("messageId") == id).deleteAll(db)
        }
    }

    /// One weekly check of the label with an unlimited budget; when it re-armed the
    /// walk, the walk runs to completion. True when it re-armed. With
    /// `pastPageHolds`, the walk's first call runs at the check's time on the
    /// page hold clock (`SyncEngine.backfillPageHoldNowForTesting`) and the rest
    /// past the hold bound, as a week later would: a page held by a failing
    /// fetch is passed over instead of holding the walk. The caller resets the
    /// hold clock.
    private static func weeklyLabelCheck(
        _ world: World, _ clock: Clock, _ check: Int, pastPageHolds: Bool = false
    ) async throws -> Bool {
        let at = checkDay(clock, check)
        let completedBefore = try state(world, labelPath)?.lastCompletedAt
        await pass(world, [labelPath], context: unlimited(at: { at }))
        #expect(try state(world, labelPath)?.lastCompletedAt != completedBefore, "precondition: check \(check) completed")
        guard try !folder(world, labelPath).backfillComplete else { return false }
        if pastPageHolds {
            let accountId = world.accountId
            let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
            SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = at }
            _ = await world.engine.runBackfill(account: account)
            SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = at.addingTimeInterval(SyncConfig.backfillPageHoldSeconds + 1) }
        }
        try await backfillUntilComplete(world)
        return true
    }

    /// What keeps a moved-in message from loading for a while.
    enum LoadBlock: String, CaseIterable, Sendable {
        /// A destructive op queued for it in the folder, removed later.
        case queuedArchive
        /// Its `format=full` GET answers `503` until the fault passes.
        case failingGet
    }

    /// A missing id the backfill cannot load re-arms the backfill once per weekly
    /// check, never more; the walk still loads everything else, and a message moved in later
    /// loads at the next check. Once the cause passes (the queued archive is
    /// removed, the GET answers again) the id loads at the next check.
    @Test("A missing id the backfill cannot load re-arms once per weekly check; a message moved in later loads; once it can load it loads at the next check",
          .enabled(if: !NetworkMonitor.checkExpensive()),
          arguments: LoadBlock.allCases)
    func unloadableMissingIdRearmsOncePerCheck(block: LoadBlock) async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("l1", clock.daysAgo(30), [labelPath]),
            Self.seed("m", clock.daysAgo(35), [labelPath]),
            Self.seed("n", clock.daysAgo(36), [inboxPath]),
            // Loads with m's first re-arm, so that walk's page loads something
            // even when m's GET fails.
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
            var rearmChecks: [Int] = []
            func weeklyCheck(_ check: Int) async throws {
                if try await Self.weeklyLabelCheck(world, clock, check, pastPageHolds: block == .failingGet) {
                    rearmChecks.append(check)
                }
            }

            for check in 0..<2 { try await weeklyCheck(check) }
            #expect(rearmChecks == [0, 1], "an id the backfill cannot load re-armed it at checks \(rearmChecks) of 2 weekly checks")
            #expect(try Self.rows(world, labelPath)["m"] == nil, "precondition: the backfill could not load it")
            #expect(try Self.rows(world, labelPath)["k"] != nil, "precondition: the walk loaded the rest")
            if block == .failingGet {
                #expect(world.server.getFailuresServedCount(providerMessageId: "m") >= 1, "precondition: m's GET was answered 503")
            }

            world.server.applyLabelChange(providerMessageId: "n", add: [labelPath], remove: [inboxPath])
            try await weeklyCheck(2)
            #expect(rearmChecks == [0, 1, 2], "the check after a message moved in re-arms once: \(rearmChecks)")
            #expect(try Self.rows(world, labelPath)["n"] != nil, "and the backfill loads it")

            switch block {
            case .queuedArchive:
                let accountId = world.accountId
                try await world.pool.write { db in
                    try db.execute(sql: "DELETE FROM pendingOperation WHERE accountId = ?", arguments: [accountId])
                }
            case .failingGet:
                world.server.clearGetFailures()
            }
            try await weeklyCheck(3)
            #expect(rearmChecks == [0, 1, 2, 3], "once m can load, the next check re-arms: \(rearmChecks)")
            #expect(try Self.rows(world, labelPath)["m"] != nil, "m loads")
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

    /// A fetch that failed during the walk is one of the catch-up's triggers:
    /// the walk completes without the message, and the next check finds it
    /// missing, re-arms the walk, and it loads.
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

            let at = Self.checkDay(clock, 0)
            await Self.pass(world, [labelPath], context: Self.unlimited(at: { at }))
            #expect(try !Self.folder(world, labelPath).backfillComplete, "precondition: the first check re-armed the walk")
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

            #expect(try await Self.weeklyLabelCheck(world, clock, 1), "the next check re-arms the walk for m")
            #expect(try Self.rows(world, labelPath)["m"] != nil, "m loads")
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

    /// A check never restarts an unfinished walk: a message moved in above the
    /// walk's position is not re-armed for while the walk runs on, so the first
    /// check after the walk completes re-arms once and the
    /// message loads. The check after that finds nothing new.
    @Test("A check never restarts an unfinished walk; the first check after the walk completes re-arms once",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func unfinishedWalkIsNotRearmedUntilItCompletes() async throws {
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
            let interval = SyncConfig.gmailCatchUpFullCheckIntervalSeconds + 1
            func weeklyCheck(_ check: Int) async throws {
                let at = clock.now.addingTimeInterval(Double(check) * interval)
                let completedBefore = try Self.state(world, labelPath)?.lastCompletedAt
                await Self.pass(world, [labelPath], context: Self.unlimited(at: { at }))
                #expect(try Self.state(world, labelPath)?.lastCompletedAt != completedBefore,
                        "precondition: check \(check) completed")
            }

            try await weeklyCheck(0)
            let during = try Self.folder(world, labelPath)
            #expect(!during.backfillComplete && during.backfillPageToken == walkToken,
                    "the check leaves the unfinished walk where it was")

            try await Self.backfillUntilComplete(world)
            #expect(try Self.rows(world, labelPath)["m"] == nil,
                    "precondition: the walk went on from its position and never reached m")

            try await weeklyCheck(1)
            let after = try Self.folder(world, labelPath)
            #expect(!after.backfillComplete && after.backfillPageToken == nil,
                    "the first check after the walk completes re-arms it")
            try await Self.backfillUntilComplete(world)
            #expect(try Self.rows(world, labelPath)["m"] != nil, "the re-armed walk loads m")

            try await weeklyCheck(2)
            #expect(try Self.folder(world, labelPath).backfillComplete, "the next check re-arms nothing")
        }
    }

    /// The huge-folder case: many not-yet-walked ids are missing (an old message
    /// gave the folder a local row far below the walk's position). No weekly
    /// check moves the walk's position backwards.
    @Test("No weekly check moves an unfinished walk's position backwards, even with many missing ids",
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
            let interval = SyncConfig.gmailCatchUpFullCheckIntervalSeconds + 1
            let checks = 3
            for check in 0..<checks {
                // The walk has moved on since the last check.
                let position = String(check + 1)
                try Self.setPartialWalk(world, labelPath, pageToken: position)
                let at = clock.now.addingTimeInterval(Double(check) * interval)
                let completedBefore = try Self.state(world, labelPath)?.lastCompletedAt
                await Self.pass(world, [labelPath], context: Self.unlimited(at: { at }))
                #expect(try Self.state(world, labelPath)?.lastCompletedAt != completedBefore,
                        "precondition: check \(check) completed")
                let folder = try Self.folder(world, labelPath)
                #expect(!folder.backfillComplete && folder.backfillPageToken == position,
                        "check \(check) left the walk at \(folder.backfillPageToken ?? "the top"), not at \(position)")
            }
        }
    }

    /// How long a test waits for a held request to arrive.
    private static let holdArrivalSeconds: Double = 30

    /// A catch-up re-arm lands while a backfill walk iteration is in flight on the
    /// same folder (its page answered from the server before the move). The
    /// walk's bookkeeping write for that page, whether it moves the page token or
    /// completes the folder, must not overwrite the re-arm: the walk starts again
    /// from the top and loads the moved-in message. Each case holds a different
    /// write site: a page with or without new mail, and a middle or the last page.
    @Test("A re-arm landing during a backfill walk iteration is not overwritten; the walk restarts and loads the moved-in mail",
          .enabled(if: !NetworkMonitor.checkExpensive()),
          arguments: [(false, false), (true, false), (false, true), (true, true)])
    func rearmDuringWalkIterationIsKept(pageHasNewMail: Bool, lastPage: Bool) async throws {
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

            // Meanwhile: a second walk (nothing serializes two walks) completes the
            // folder, the message moves into the label, and the catch-up re-arms
            // the completed walk.
            try Self.completeWalk(world, labelPath)
            world.server.applyLabelChange(providerMessageId: "m", add: [labelPath], remove: [inboxPath])
            await Self.pass(world, [labelPath])
            let rearmed = try Self.folder(world, labelPath)
            #expect(!rearmed.backfillComplete && rearmed.backfillPageToken == nil,
                    "precondition: the catch-up re-armed the walk while its iteration was in flight")

            hold.release.signal()
            _ = await walk.value

            #expect(try Self.rows(world, labelPath)["m"] != nil, "the moved-in message is loaded")
            #expect(try Self.rows(world, labelPath)[heldId] != nil)
            #expect(try Self.folder(world, labelPath).backfillComplete, "the walk completes")
            let walkLists = world.server.listRequests().filter { $0.labelId == labelPath && $0.bound("after") == nil }
            #expect(walkLists.first?.pageToken == readToken, "precondition: the held page was the iteration's")
            #expect(walkLists.dropFirst().first.map { $0.pageToken == nil } == true,
                    "after the re-arm the walk starts again from the top")
        }
    }

    /// The same interleaving at the top of a folder: the walk's iteration read the
    /// folder with no page token and not complete, which is exactly what a re-arm
    /// writes. The page was answered before the move, and the moved-in message
    /// sorts before where that page ends, so walking on from it never reaches the
    /// message. The walk's write, whether it moves the page token or completes the
    /// folder, must still miss and the walk start again from the top.
    @Test("A re-arm landing while the walk is at the top of a folder is not overwritten; the walk restarts and loads the moved-in mail",
          .enabled(if: !NetworkMonitor.checkExpensive()),
          arguments: [false, true])
    func rearmAtTheTopOfTheWalkIsKept(lastPage: Bool) async throws {
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

            // Meanwhile: a second walk completes the folder, the message moves into
            // the label, and the catch-up re-arms the completed walk. The re-arm
            // writes the very state this iteration read.
            try Self.completeWalk(world, labelPath)
            let before = try Self.folder(world, labelPath)
            world.server.applyLabelChange(providerMessageId: "m", add: [labelPath], remove: [inboxPath])
            await Self.pass(world, [labelPath])
            let rearmed = try Self.folder(world, labelPath)
            #expect(rearmed.backfillVersion > before.backfillVersion && !rearmed.backfillComplete && rearmed.backfillPageToken == nil,
                    "precondition: the catch-up re-armed the walk while its iteration was in flight")

            hold.release.signal()
            _ = await walk.value

            #expect(try Self.rows(world, labelPath)["m"] != nil, "the moved-in message is loaded")
            #expect(try Self.folder(world, labelPath).backfillComplete, "the walk completes")
            let walkLists = world.server.listRequests().filter { $0.labelId == labelPath && $0.bound("after") == nil }
            #expect(walkLists.count >= 2)
            guard walkLists.count >= 2 else { return }
            #expect(walkLists[0].pageToken == nil, "precondition: the held page was the folder's first")
            #expect(walkLists[1].pageToken == nil, "after the re-arm the walk starts again from the top")
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

    /// Every folder's catch-up completed at `at`.
    private static func completeCatchUp(_ world: World, at: Date) async throws {
        await Self.pass(world, [inboxPath, allMailPath], context: Self.unlimited(at: { at }))
        for path in [inboxPath, allMailPath] {
            #expect(try Self.state(world, path)?.lastCompletedAt != nil, "precondition: \(path)'s catch-up completed")
        }
    }

    @Test("G1: an All Mail read change beyond the window that no delta reads arrives at the weekly check while the cursor stays valid",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func weeklyCheckWithValidCursor() async throws {
        let clock = Clock()
        let (seeds, local) = Self.syncWorld(clock)
        try await Self.withWorld("gcu-g1", seeds: seeds, local: local, folders: Self.syncFolders, userLabels: [:]) { world async throws in
            world.server.serveProfile()
            let lastWeek = clock.now.addingTimeInterval(-SyncConfig.gmailCatchUpFullCheckIntervalSeconds - 1)
            try await Self.completeCatchUp(world, at: lastWeek)

            // Read elsewhere, in history the delta will never be asked for.
            world.server.applyLabelChange(providerMessageId: "ao0", remove: ["UNREAD"])
            let reached = world.server.currentHistoryId()
            try Self.setAccount(world, cursor: reached, lastFullSyncAt: nil)
            world.server.setProfileAhead(5)

            try await Self.syncPass(world)

            #expect(try Self.rows(world, allMailPath)["ao0"]?.isRead == true, "the weekly check applied the change")
            #expect(try Self.cursor(world) == reached, "the cursor this pass's delta reached is kept")
            let state = try #require(try Self.state(world, allMailPath))
            #expect((state.lastCompletedAt ?? .distantPast) > lastWeek, "the check's state persists past the capture")
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

    @Test("G3: a lapse with no full sync due survives a relaunch, and the next due full sync applies the change",
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
            try await Self.syncPass(world)
            #expect(try Self.cursor(world) == nil, "precondition: the expired history cleared the cursor")
            #expect(try Self.state(world, inboxPath) == nil && Self.state(world, allMailPath) == nil,
                    "the lapse is written with the cursor")

            let relaunched = SyncEngine()
            let provider = world.server.provider()
            await relaunched.register(
                accountId: world.accountId, provider: provider, workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
            try Self.setAccount(world, cursor: nil, lastFullSyncAt: nil)
            try await Self.syncPass(world, engine: relaunched)
            await relaunched.remove(accountId: world.accountId)

            #expect(try Self.rows(world, inboxPath)["o0"]?.isRead == true, "the change in the lost history is applied")
            #expect(try Self.cursor(world) == world.server.currentHistoryId())
        }
    }

    @Test("G4: a change whose GET failed in a pass with a due full sync is applied by a later pass",
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
                    "precondition: the full sync's capture moved the cursor past the change")

            try Self.setAccount(world, cursor: try Self.cursor(world), lastFullSyncAt: nil)
            try await Self.syncPass(world)
            #expect(try Self.rows(world, inboxPath)["o0"]?.isRead == true, "a later pass applies the change")
        }
    }
}
