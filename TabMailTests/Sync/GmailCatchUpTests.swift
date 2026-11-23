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
        syncFollowUp: @escaping @Sendable (_ accountId: String) -> Void = { _ in },
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
        let engine = SyncEngine(syncFollowUp: syncFollowUp)
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
        storageLimit: Bool = false, at clock: @escaping @Sendable () -> Date = { Date() }
    ) -> CatchUpContext {
        CatchUpContext(deadline: .distantFuture, clock: clock, storageLimitInForce: storageLimit)
    }

    /// A budget of exactly `requests` requests: the clock advances one second per
    /// request the server has seen since the pass began, from `base`.
    private static func requestBudget(
        _ server: StatefulGmailActionServer, _ requests: Int, at base: Date = Date()
    ) -> CatchUpContext {
        let before = server.http.recordedCalls().count
        return CatchUpContext(
            deadline: base.addingTimeInterval(TimeInterval(requests)),
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

    /// A message in Trash or Spam keeps its user labels on the server, and no
    /// listing outside Trash and Spam returns it. Each row is a candidate whose
    /// own GET decides; a message carrying TRASH or SPAM is a member of no other
    /// folder, so the GET proves it left the label. (Sent is pinned by the
    /// change-reader and full-app tests.)
    @Test("An older labelled message in Trash or Spam is removed by the catch-up")
    func trashOrSpamMailLeavesLabels() async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("label-steady", clock.daysAgo(42), [labelPath]),
            Self.seed("label-trashed", clock.daysAgo(43), [labelPath, "TRASH"]),
            Self.seed("label-spam", clock.daysAgo(44), [labelPath, "SPAM"]),
        ]
        let local = [
            Local(id: "label-steady", path: labelPath, date: clock.daysAgo(42)),
            Local(id: "label-trashed", path: labelPath, date: clock.daysAgo(43)),
            Local(id: "label-spam", path: labelPath, date: clock.daysAgo(44)),
        ]
        let folders: [(path: String, role: FolderRole)] = [(inboxPath, .inbox), (labelPath, .custom)]
        try await Self.withWorld("gcu-trash-spam-exclusive", seeds: seeds, local: local, folders: folders) { world async throws in
            await Self.pass(world, [labelPath])

            #expect(Set(world.server.messageGets()).isSuperset(of: ["label-trashed", "label-spam"]),
                    "precondition: each GET decided")
            let label = try Self.rows(world, labelPath)
            #expect(label["label-trashed"] == nil, "a message carrying TRASH is not in a user label")
            #expect(label["label-spam"] == nil, "a message carrying SPAM is not in a user label")
            #expect(label["label-steady"] != nil)
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
        #expect(showsRemoval(["SENT", "TRASH"], "SENT"))
        #expect(showsRemoval([labelPath, "SPAM"], labelPath))
        #expect(!showsRemoval(["SENT", "TRASH"], "TRASH"))
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

    /// A Gmail folder is listed in exactly three cases: its first listing (no
    /// listing completed yet), a listing in progress, and a lapse after the last
    /// completed listing started. There is no periodic re-check, however long ago
    /// the last listing completed. A lapse makes a new listing due at once, but
    /// never interrupts one in progress. The plan reads no network (#1063).
    @Test("The per-folder plan")
    func catchUpPlan() {
        let now = Clock().now
        let maxWait = Self.week
        let fresh = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-60))
        let old = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-4 * maxWait))
        let running = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-60), listing: .init(nextBeforeSecond: 42))
        let lapsed = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-60), lapseCount: 3, listedLapseCount: 2)
        let lapseListed = GmailCatchUpState(lastCompletedAt: now.addingTimeInterval(-60), lapseCount: 3, listedLapseCount: 3)
        let lapsedNeverListed = GmailCatchUpState(lastAttemptAt: now.addingTimeInterval(-60), lapseCount: 1)
        let lapsedWhileRunning = GmailCatchUpState(
            lastCompletedAt: now.addingTimeInterval(-60), listing: .init(nextBeforeSecond: 42, lapseCountAtStart: 3),
            lapseCount: 4, listedLapseCount: 2)
        let neverListed = GmailCatchUpState(lastAttemptAt: now.addingTimeInterval(-60))

        #expect(GmailProvider.catchUpPlan(state: nil) == .list(.init()))
        #expect(GmailProvider.catchUpPlan(state: neverListed) == .list(.init()),
                "a folder with no completed listing is listed")
        #expect(GmailProvider.catchUpPlan(state: fresh) == .none, "not every pass")
        #expect(GmailProvider.catchUpPlan(state: old) == .none,
                "no periodic re-check, however long ago the last listing completed")
        #expect(GmailProvider.catchUpPlan(state: running) == .list(.init(nextBeforeSecond: 42)))
        #expect(GmailProvider.catchUpPlan(state: lapsed) == .list(.init(lapseCountAtStart: 3)),
                "a lapse after the last listing started makes a new one due at once, recording the count it covers")
        #expect(GmailProvider.catchUpPlan(state: lapseListed) == .none,
                "a lapse a completed listing already covered asks for nothing")
        #expect(GmailProvider.catchUpPlan(state: lapsedNeverListed) == .list(.init(lapseCountAtStart: 1)))
        #expect(GmailProvider.catchUpPlan(state: lapsedWhileRunning)
                == .list(.init(nextBeforeSecond: 42, lapseCountAtStart: 3)), "a lapse never interrupts a listing in progress")
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
                freshModSeq: 7, now: now)
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
            lastAttemptAt: now.addingTimeInterval(-30))
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
        #expect(!engine.contains("NetworkMonitor"),
                "a scan reads no network state (#1063); superseded: the engine read it once, in the run's snapshot")
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
            "TabMail/Services/Sync/SyncEngineResetSyncState.swift": (
                2, "the one sync-state reset both Settings resets call (Reset message data, Delete All Email Index Data)"),
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
                        // 0 to 2 weeks. A check lists a folder only on its first
                        // listing, a listing in progress, or after a lapse.
                        now = now.addingTimeInterval(TimeInterval(rng.pick(Int(2 * Self.week) + 1)))
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

    /// The user moves a message out of a label while the check is loading it
    /// (the label lacked it locally once the move was made on the phone): the
    /// move completes after the check fetched the message and before the apply.
    /// The apply never puts the message back in the label, whether the
    /// completion is still under the shared 30 s protection or only in the
    /// completion log. Another missing message in the same insert still loads.
    @Test("A message moved out of a label while the check was loading it is not put back; another missing message still loads",
          .enabled(if: !NetworkMonitor.checkExpensive()), arguments: [false, true])
    func moveDuringTheLoadLeavesNoGhost(liveProtection: Bool) async throws {
        let clock = Clock()
        let seeds = [
            Self.seed("l1", clock.daysAgo(30), [labelPath]),
            Self.seed("m", clock.daysAgo(35), [labelPath]),
            Self.seed("o", clock.daysAgo(37), [labelPath]),
            Self.seed("l3", clock.daysAgo(40), [labelPath]),
        ]
        let local = [
            Local(id: "m", path: inboxPath, date: clock.daysAgo(35)),
            Local(id: "l1", path: labelPath, date: clock.daysAgo(30)),
            Local(id: "l3", path: labelPath, date: clock.daysAgo(40)),
        ]
        try await Self.withWorld("gcu-move-during-load-\(liveProtection)", seeds: seeds, local: local) { world async throws in
            if liveProtection {
                await AccountManager.shared.recordRecentlyCompleted(messageIds: ["m", "m@example.com"])
            }
            let (server, accountId) = (world.server, world.accountId)
            server.onGet(providerMessageId: "m") {
                server.applyLabelChange(providerMessageId: "m", add: [inboxPath], remove: [labelPath])
                if !liveProtection {
                    AccountManager.shared.recordActionCompleted(accountId: accountId, messageKeys: ["m", "m@example.com"])
                }
            }

            await Self.pass(world, [labelPath])

            #expect(world.server.messageGets().contains("m"), "precondition: the check fetched the moved message")
            let label = try Self.rows(world, labelPath)
            #expect(label["m"] == nil, "the apply put the moved message back in the label")
            #expect(label["o"] != nil, "another missing message did not load")
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

    /// One week, the spacing unit of the seeded checks below.
    static let week: TimeInterval = 7 * 86_400

    /// Checks a week and an hour apart. Each check is started by a lapse; the
    /// spacing keeps every check past the previous one's hold bound.
    private static let checkSpacing = week + 3_600

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

    /// Settings' Delete All Email Index Data (`SyncEngine.localIndexWipeTxn`)
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
            try await world.pool.write { db in try SyncEngine.localIndexWipeTxn(db) }
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

    // MARK: - Scans never wait for a download gate (#1063)

    /// A lapsed Inbox whose walk is unfinished: `g0` was marked unread on the
    /// server, `moved` sits inside the local range with no local row (the scan's
    /// direct load), and `old` is older than every local row (the walk's). Under
    /// every download gate, in the worker's cycle and in the background job, the
    /// listing runs in that one call, the change and the missing message arrive,
    /// and the walk stays held (except the job under a low battery, which has no
    /// battery gate).
    @Test("A due Gmail scan runs under every download gate, in the worker and the job; a missing message loads; the walk stays held",
          arguments: DownloadGate.allCases, BackfillRunner.allCases)
    func scanRunsUnderEveryDownloadGate(gate: DownloadGate, runner: BackfillRunner) async throws {
        let clock = Clock()
        var (seeds, local) = Self.rangesWorld(clock, count: 3)
        seeds.append(Self.seed("moved", clock.daysAgo(135), [inboxPath]))
        seeds.append(Self.seed("old", clock.daysAgo(300), [inboxPath]))
        try await Self.withWorld("gcu-gate-\(gate.rawValue)-\(runner.rawValue)", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let folderId = world.folderId(inboxPath)
            let lapsed = GmailCatchUpState(
                lastCompletedAt: Date().addingTimeInterval(-3_600), lapseCount: 1, listedLapseCount: 0).encoded()
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = ?, backfillComplete = 0 WHERE id = ?", arguments: [lapsed, folderId])
            }
            world.server.applyLabelChange(providerMessageId: "g0", add: ["UNREAD"])
            let account = try await Self.account(world)

            try await DownloadGateHarness.runOnce(world.engine, account: account, gate: gate, runner: runner)
            let walkHeld = !DownloadGateHarness.walkExpected(gate, runner)

            #expect(try Self.state(world, inboxPath)?.listedLapseCount == 1, "the lapsed folder was listed under \(gate)")
            let rows = try Self.rows(world, inboxPath)
            #expect(rows["g0"]?.isRead == false, "the lapsed change arrives under \(gate)")
            #expect(rows["moved"] != nil, "a listed message no local row held loads with the scan under \(gate)")
            if walkHeld {
                let pages = world.server.http.recordedCalls().map(\.url).filter { $0.contains("/messages?") && !$0.contains("after") }
                #expect(pages.isEmpty, "the held walk listed no page: \(pages)")
                #expect(rows["old"] == nil, "the held walk loaded nothing older than every local row")
            } else {
                let pages = world.server.http.recordedCalls().map(\.url).filter { $0.contains("/messages?") && !$0.contains("after") }
                #expect(!pages.isEmpty, "the allowed walk listed a page")
                #expect(rows["old"] != nil, "the allowed walk loaded the message older than every local row")
            }
        }
    }

    /// What the job's backfill stage did around its Wi-Fi reading.
    private final class JobReadingRecord: Sendable {
        /// Catch-up lists sent before the reading landed (nil: never awaited).
        let listsAtReading = Mutex<Int?>(nil)
        /// The budget left (seconds) when each walk-allowed run started.
        let walkBudgets = Mutex<[TimeInterval]>([])
    }

    /// #1064, through the production pipeline (`SyncScheduler.runBackgroundBackfill`
    /// over `performBackfill`): a lapsed Inbox whose listing stays productive far
    /// longer than the job's short budget, and an unfinished walk with `old` to
    /// load. Whether the Wi-Fi reading is known at once or lands after the scans
    /// have run a slice, the walk-allowed run starts with the whole budget and the
    /// walk downloads `old`: the scan-only pre-pass ends when the reading lands and
    /// takes nothing from the walk.
    @Test("In the job, scans start before a late Wi-Fi reading, and the walk then gets the same budget as with a reading known at once",
          .enabled(if: !NetworkMonitor.checkExpensive()), arguments: [false, true])
    func jobWalkBudgetIsTheSameWhetherTheReadingIsEarlyOrLate(readingLate: Bool) async throws {
        let clock = Clock()
        let slice = SyncConfig.catchUpSliceSeconds
        var (seeds, local) = Self.rangesWorld(clock, count: 12)
        seeds.append(Self.seed("old", clock.daysAgo(300), [inboxPath]))
        try await Self.withWorld("gcu-job-reading-\(readingLate)", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let folderId = world.folderId(inboxPath)
            let lapsed = GmailCatchUpState(
                lastCompletedAt: Date().addingTimeInterval(-3_600), lapseCount: 1, listedLapseCount: 0).encoded()
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = ?, backfillComplete = 0 WHERE id = ?", arguments: [lapsed, folderId])
            }
            // 36 lists at slice / 8 each outlast the budget below.
            world.server.holdEveryList(forSeconds: slice / 8)
            let account = try await Self.account(world)
            let engine = world.engine
            let server = world.server
            let record = JobReadingRecord()
            // A short job budget: a few slices, while the listing keeps progressing.
            let budget = slice * 4
            await SyncScheduler.runBackgroundBackfill(
                accounts: [account], isLowPowerMode: false, wifiOnly: true,
                onWiFi: readingLate ? nil : true, budget: budget,
                awaitOnWiFi: {
                    // Lands only after the scans have started and run a slice.
                    _ = await Self.eventually(seconds: 30) { !server.listRequests().isEmpty }
                    try? await Task.sleep(for: .seconds(slice))
                    record.listsAtReading.withLock { $0 = server.listRequests().count }
                    return true
                }
            ) { account, walkAllowed, deadline in
                if walkAllowed { record.walkBudgets.withLock { $0.append(deadline.timeIntervalSinceNow) } }
                _ = await engine.performBackfill(account: account, deadline: deadline, walkAllowed: walkAllowed)
            }

            if readingLate {
                let lists = record.listsAtReading.withLock { $0 } ?? 0
                #expect(lists > 0, "the scans waited for the Wi-Fi reading")
            }
            let budgets = record.walkBudgets.withLock { $0 }
            #expect(budgets.count == 1, "one walk-allowed run after the reading: \(budgets)")
            if let left = budgets.first {
                #expect(left >= budget - slice / 4,
                        "the walk started with \(left) s of a \(budget) s budget; the pre-pass took budget from it")
            }
            #expect(try Self.rows(world, inboxPath)["old"] != nil, "the walk did not download the older message")
            #expect(try Self.state(world, inboxPath)?.listing != nil, "precondition: the listing stays productive past the budget")
        }
    }

    /// A lapse that came while a listing ran: the completing pass starts the new
    /// listing at once on an expensive network too, so a change in a range the
    /// first listing had already passed arrives in the same run.
    @Test("On cellular, a listing that completes after a lapse starts the next listing at once")
    func lapseDuringListingRelistsAtOnceOnCellular() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 3)
        try await Self.withWorld("gcu-lapse-cellular", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let folderId = world.folderId(inboxPath)
            // Ranges go newest first: g2's range is already listed.
            let passedNewest = Int(clock.daysAgo(130).timeIntervalSince1970)
            let running = GmailCatchUpState(
                lastCompletedAt: Date().addingTimeInterval(-3_600),
                listing: .init(nextBeforeSecond: passedNewest, lapseCountAtStart: 0),
                lapseCount: 1, listedLapseCount: 0).encoded()
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [running, folderId])
            }
            world.server.applyLabelChange(providerMessageId: "g2", add: ["UNREAD"])
            let account = try await Self.account(world)

            try await DownloadGateHarness.withNetwork(expensive: true) { () async throws in
                let deadline = Date().addingTimeInterval(SyncConfig.backgroundBackfillDeadlineSeconds)
                _ = await world.engine.performBackfill(account: account, deadline: deadline, walkAllowed: false)
            }

            #expect(try Self.state(world, inboxPath)?.listedLapseCount == 1, "the listing after the lapse ran and completed")
            #expect(try Self.rows(world, inboxPath)["g2"]?.isRead == false, "the change in the passed range arrives")
        }
    }

    // MARK: - The worker's wait while the walk is held (#1063)

    /// A lapsed Inbox whose walk is `walkComplete` or not, with `g0` marked unread
    /// on the server.
    private static func heldWalkWorld(
        _ name: String, walkComplete: Bool, _ body: (World, Account) async throws -> Void
    ) async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 3)
        try await Self.withWorld(name, seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let folderId = world.folderId(inboxPath)
            let lapsed = GmailCatchUpState(
                lastCompletedAt: Date().addingTimeInterval(-3_600), lapseCount: 1, listedLapseCount: 0).encoded()
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = ?, backfillComplete = ? WHERE id = ?",
                               arguments: [lapsed, walkComplete ? 1 : 0, folderId])
            }
            world.server.applyLabelChange(providerMessageId: "g0", add: ["UNREAD"])
            try await body(world, try await Self.account(world))
        }
    }

    /// The real worker with its walk held, by a power gate or by Wi-Fi-only on
    /// cellular. The first cycle's scan repairs the lapsed change before any wait,
    /// and the wait after it is the normal one (the catch-up made progress). The
    /// next cycle has nothing to do, so the worker waits 60 s (a power gate) or
    /// 30 s (Wi-Fi-only); no cycle starts inside that wait, and the next one runs
    /// after it. The walk never sends a request.
    @Test("With the walk held, the worker scans first, then waits 60 s for a power gate or 30 s for Wi-Fi-only, and retries after the wait",
          arguments: [DownloadGate.lowPowerMode, .lowBattery, .expensiveNetwork])
    func heldWalkWaitsThenRetries(gate: DownloadGate) async throws {
        try await Self.heldWalkWorld("gcu-held-wait-\(gate.rawValue)", walkComplete: false) { world, account in
            try await DownloadGateHarness.withNetwork(expensive: gate == .expensiveNetwork) { () async throws in
                try await DownloadGateHarness.withWorker(world.engine, account: account, power: DownloadGateHarness.power(gate)) { sleeps async throws in
                    #expect(await sleeps.waitFor(count: 1), "the first cycle never ended")
                    #expect(try Self.state(world, inboxPath)?.listedLapseCount == 1, "the scan ran before the first wait")
                    #expect(try Self.rows(world, inboxPath)["g0"]?.isRead == false, "the lapsed change arrived before the first wait")
                    let profile = await world.engine.getBackfillProfile()
                    let productive = SyncEngine.backfillInterCycleDelay(
                        cycle: .init(walked: false, caughtUp: true), walkComplete: false, profile: profile)
                    #expect(sleeps.recorded.first == productive, "a productive cycle waits the normal delay: \(sleeps.recorded)")

                    sleeps.release()
                    #expect(await sleeps.waitFor(count: 2), "the idle cycle never ended")
                    let held: TimeInterval = gate == .expensiveNetwork ? 30 : 60
                    #expect(sleeps.recorded.dropFirst().first == held, "the held walk's wait under \(gate): \(sleeps.recorded)")

                    // A lapse makes the next cycle list again; inside the wait, no cycle starts.
                    try await Self.lapse(world)
                    try? await Task.sleep(for: .milliseconds(500))
                    #expect(try Self.state(world, inboxPath)?.listedLapseCount == 1, "a cycle started inside the wait")
                    #expect(sleeps.recorded.count == 2)

                    sleeps.release()
                    let retried = try await Self.eventually(seconds: 30, poll: .milliseconds(20)) {
                        try Self.state(world, inboxPath)?.listedLapseCount == 2
                    }
                    #expect(retried, "the worker never retried after the wait")
                }
            }
            let pages = world.server.http.recordedCalls().map(\.url).filter { $0.contains("/messages?") && !$0.contains("after") }
            #expect(pages.isEmpty, "the held walk listed a page: \(pages)")
        }
    }

    /// The control: with the walk complete, a cycle with nothing to do ends the
    /// worker; it does not wait for a held walk.
    @Test("With the walk complete, the worker stops after an idle cycle instead of waiting for a held walk")
    func completedWalkStopsTheWorker() async throws {
        try await Self.heldWalkWorld("gcu-held-wait-done", walkComplete: true) { world, account in
            try await DownloadGateHarness.withNetwork(expensive: false) { () async throws in
                try await DownloadGateHarness.withWorker(world.engine, account: account, power: DownloadGateHarness.power(.lowPowerMode)) { sleeps async throws in
                    #expect(await sleeps.waitFor(count: 1), "the first cycle never ended")
                    #expect(try Self.rows(world, inboxPath)["g0"]?.isRead == false, "the scan ran")
                    sleeps.release()
                    #expect(await sleeps.waitFor(count: 2, seconds: 2) == false,
                            "the worker waited again with its walk complete: \(sleeps.recorded)")
                }
            }
        }
    }

    // MARK: - A worker alive during the background job (#1064)

    /// What the background job in `workerDuringJob` exposes to the test.
    private final class JobWindow: Sendable {
        let entered = Mutex(false)
        let done = Mutex(false)
    }

    /// The worker's inputs during the job: the job's Wi-Fi reading (nil: never
    /// lands while the worker runs), the device power, and whether the walk may run.
    struct WorkerJobCase: Sendable, CustomTestStringConvertible {
        let name: String
        let reading: Bool?
        let power: (fastSync: Bool, lowPowerMode: Bool, onPower: Bool, batteryLevel: Float)
        let walks: Bool
        var testDescription: String { name }

        static let all: [WorkerJobCase] = [
            WorkerJobCase(name: "reading-unknown", reading: nil,
                          power: (fastSync: false, lowPowerMode: false, onPower: false, batteryLevel: 0.8), walks: false),
            WorkerJobCase(name: "job-measured-metered", reading: false,
                          power: (fastSync: false, lowPowerMode: false, onPower: false, batteryLevel: 0.8), walks: false),
            WorkerJobCase(name: "low-power-mode-on-power", reading: true,
                          power: (fastSync: false, lowPowerMode: true, onPower: true, batteryLevel: 1), walks: false),
            WorkerJobCase(name: "job-measured-unmetered", reading: true,
                          power: (fastSync: false, lowPowerMode: false, onPower: false, batteryLevel: 0.8), walks: true),
        ]
    }

    /// A backfill worker that is still alive when the background processing job
    /// starts decides its walk by the job's rule and the job's one network
    /// measurement, never by NetworkMonitor's cached path or the job's synthetic
    /// Fast Sync. NetworkMonitor reports unmetered Wi-Fi throughout, so a worker
    /// on the foreground rule would walk in every case. The scan runs in every case.
    @Test("A backfill worker running during the background job walks only when the job's reading and rule allow it; its scan always runs",
          arguments: WorkerJobCase.all)
    func workerDuringJobFollowsTheJobDecision(_ input: WorkerJobCase) async throws {
        try await Self.heldWalkWorld("gcu-worker-job-\(input.name)", walkComplete: false) { world, account in
            try await DownloadGateHarness.withNetwork(expensive: false) { () async throws in
                let window = JobWindow()
                let reading = input.reading
                SyncScheduler.jobOnWiFiMeasurementHoldForTesting.withLock {
                    $0 = {
                        guard let reading else {
                            while !window.done.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(20)) }
                            return true
                        }
                        return reading
                    }
                }
                defer { SyncScheduler.jobOnWiFiMeasurementHoldForTesting.withLock { $0 = nil } }
                let (scheduler, context) = await MainActor.run {
                    let context = BGTaskContext(label: "gcu-worker-job-\(input.name)", completion: { _ in })
                    let scheduler = SyncScheduler(
                        backgroundReadiness: { true },
                        backgroundWork: { _ in
                            window.entered.withLock { $0 = true }
                            while !window.done.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(20)) }
                        },
                        processingHasWork: { false },
                        backgroundSchedule: { _ in },
                        refreshNetworkAvailable: true
                    )
                    scheduler.handleBackgroundAIProcessing(context: context) { _ in }
                    return (scheduler, context)
                }
                let entered = await Self.eventually(seconds: 30, poll: .milliseconds(20)) {
                    window.entered.withLock { $0 }
                }
                #expect(entered, "the job never started")
                if input.reading != nil {
                    let known = await Self.eventually(seconds: 30, poll: .milliseconds(20)) {
                        SyncEngine.backgroundProcessingJobOnWiFi.withLock { $0 } != nil
                    }
                    #expect(known, "the job's reading never landed")
                }
                do {
                    try await DownloadGateHarness.withWorker(world.engine, account: account, power: input.power) { sleeps async throws in
                        #expect(await sleeps.waitFor(count: 1), "the worker's first cycle never ended")
                    }
                } catch {
                    window.done.withLock { $0 = true }
                    await context.waitForTaskForTesting()
                    throw error
                }
                window.done.withLock { $0 = true }
                await context.waitForTaskForTesting()
                withExtendedLifetime(scheduler) {}
            }
            #expect(try Self.state(world, inboxPath)?.listedLapseCount == 1, "the worker's scan ran during the job (\(input.name))")
            #expect(try Self.rows(world, inboxPath)["g0"]?.isRead == false, "the lapsed change arrived during the job (\(input.name))")
            let pages = world.server.http.recordedCalls().map(\.url).filter { $0.contains("/messages?") && !$0.contains("after") }
            #expect(pages.isEmpty != input.walks, "the worker's walk during the job (\(input.name)): pages \(pages)")
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
            storageLimitInForce: false,
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

    /// The follow-up stage 2 the scheduler runs in the foreground for each ask
    /// (`SyncScheduler.runSyncFollowUp` → `SyncEngine.followUpPass`), for a test
    /// whose engine is made inside its world.
    final class FollowUpRunner: Sendable {
        let engine = Mutex<SyncEngine?>(nil)
        let started = Mutex<[Task<Bool?, Error>]>([])

        func ask(_ accountId: String) {
            guard let engine = engine.withLock({ $0 }) else { return }
            let followUp = Task { try await engine.followUpPass(accountId: accountId, mayStart: { true }) }
            started.withLock { $0.append(followUp) }
        }

        /// Waits for every follow-up started; how many ran a stage 2.
        func ran() async throws -> Int {
            var ran = 0
            for followUp in started.withLock({ $0 }) {
                let result = try await followUp.value
                if result != nil { ran += 1 }
            }
            return ran
        }
    }

    /// The catch-up takes the account's one-sync-at-a-time turn one slice at a
    /// time: a silent-push delta that arrives while a slice is running reads
    /// nothing and sets the account's follow-up flag (it never waits); the
    /// follow-up stage 2 it asks for waits in line and reads as soon as that
    /// slice ends, and the run goes on after it.
    @Test("A catch-up slice hands the turn on: a delta that arrives during the catch-up gets its follow-up read after at most one slice")
    func sliceHandsTheTurnOn() async throws {
        let clock = Clock()
        let count = 8
        let slice = 3
        let (seeds, local) = Self.rangesWorld(clock, count: count)
        let followUps = FollowUpRunner()
        try await Self.withWorld(
            "gcu-slice-turn", seeds: seeds, local: local, folders: Self.inboxOnly,
            concurrency: SyncConfig.imapMaxConnectionCeiling,
            syncFollowUp: { followUps.ask($0) }
        ) { world async throws in
            world.server.serveProfile()
            try Self.setAccount(world, cursor: world.server.currentHistoryId(), lastFullSyncAt: Date())
            world.server.holdEveryList(forSeconds: 0.2)
            let account = try await Self.account(world)
            let engine = world.engine
            let server = world.server
            followUps.engine.withLock { $0 = engine }
            // The engine's callback holds the runner, and the runner the engine.
            defer { followUps.engine.withLock { $0 = nil } }
            let run = Self.requestRun(server, slice: slice, deadline: nil)
            let catchUp = Task { await engine.runCatchUpRun(account: account, run: run) }

            // The delta arrives while the third slice's first list is in flight.
            let inThirdSlice = await Self.eventually(seconds: 30) { server.listRequests().count >= 2 * slice + 1 }
            #expect(inThirdSlice, "precondition: the catch-up reached its third slice")
            let arrival = server.http.recordedCalls().count
            let read = try await engine.backgroundDeltaSync(account: account)
            let readNothing = read == nil
            #expect(readNothing, "a delta during a slice must set the follow-up flag, not wait for the slice")

            #expect(await catchUp.value, "the run made progress")
            let ran = try await followUps.ran()
            #expect(ran == 1, "the delta's flag got \(ran) follow-up stage 2s; it gets one")
            let calls = server.http.recordedCalls()
            let changeReads = calls.indices.filter { calls[$0].url.contains("/history") }
            #expect(changeReads.count == 1, "\(changeReads.count) change reads: the busy delta reads nothing and its follow-up reads once")
            guard let readAt = changeReads.first, readAt >= arrival else {
                Issue.record("no change read started after the delta at request \(arrival): \(changeReads)")
                return
            }
            let waited = calls[arrival..<readAt].filter { $0.url.contains("/messages") }.count
            #expect(waited <= slice, "the follow-up read after \(waited) catch-up requests; a slice is \(slice)")
            // Every slice here is one range's three lists, so a read at the end
            // of a slice finds a whole number of slices before it.
            let before = calls[..<readAt].filter { $0.url.contains("/messages") }.count
            #expect(before % slice == 0, "the follow-up read inside a slice, after \(before) catch-up requests")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil,
                    "the run goes on after the follow-up and completes the listing")
            let inboxListings = server.listRequests().filter { $0.labelId == inboxPath }.count
            #expect(inboxListings == count, "no range is listed twice")
        }
    }

    /// The same through the production entry: the background processing job
    /// (`performBackfill`, real clock and the job's deadline) releases the
    /// account's turn between its slices, so a delta that arrives while the job
    /// runs gets its follow-up read within one slice plus one request timeout,
    /// never at the job's end.
    @Test("The background job hands the turn on between slices: a delta that arrives during it gets its follow-up read within one slice",
          .enabled(if: !NetworkMonitor.checkExpensive()))
    func jobHandsTheTurnOnBetweenSlices() async throws {
        let clock = Clock()
        let count = 20
        let roundTrip = SyncConfig.catchUpSliceSeconds / 10
        let (seeds, local) = Self.rangesWorld(clock, count: count)
        let followUps = FollowUpRunner()
        try await Self.withWorld(
            "gcu-job-turn", seeds: seeds, local: local, folders: Self.inboxOnly,
            concurrency: SyncConfig.imapMaxConnectionCeiling,
            syncFollowUp: { followUps.ask($0) }
        ) { world async throws in
            world.server.serveProfile()
            try Self.setAccount(world, cursor: world.server.currentHistoryId(), lastFullSyncAt: Date())
            world.server.holdEveryList(forSeconds: roundTrip)
            #expect(Double(count * 3) * roundTrip > 2 * (SyncConfig.catchUpSliceSeconds + SyncConfig.catchUpRequestTimeoutSeconds),
                    "precondition: the job's lists take far longer than one slice")
            let account = try await Self.account(world)
            let engine = world.engine
            let server = world.server
            followUps.engine.withLock { $0 = engine }
            // The engine's callback holds the runner, and the runner the engine.
            defer { followUps.engine.withLock { $0 = nil } }
            let deadline = Date().addingTimeInterval(SyncConfig.backgroundBackfillDeadlineSeconds)
            let job = Task { await engine.performBackfill(account: account, deadline: deadline) }

            let started = await Self.eventually(seconds: 30) { server.listRequests().count >= 2 }
            #expect(started, "precondition: the job's catch-up is listing")
            let arrival = Date()
            let read = try await engine.backgroundDeltaSync(account: account)
            let readNothing = read == nil
            #expect(readNothing, "a delta during the job must set the follow-up flag, not wait for a slice")
            let bound = SyncConfig.catchUpSliceSeconds + SyncConfig.catchUpRequestTimeoutSeconds
            let followUpRead = await Self.eventually(seconds: bound * 2) {
                server.http.recordedCalls().contains { $0.url.contains("/history") }
            }
            let waited = Date().timeIntervalSince(arrival)
            let listingOpen = try Self.state(world, inboxPath)?.listing != nil

            #expect(followUpRead, "the delta's follow-up never read")
            #expect(listingOpen, "precondition: the follow-up read while the job's listing was in progress")
            #expect(waited <= bound,
                    "the follow-up read after \(waited) s; one slice is at most \(SyncConfig.catchUpSliceSeconds) s plus one request timeout")
            #expect(await job.value, "the job made progress")
            let ran = try await followUps.ran()
            #expect(ran == 1, "the delta's flag got \(ran) follow-up stage 2s; it gets one")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt != nil, "the job goes on after the follow-up and completes the listing")
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
    /// network rate until the deadline. That slice still got its slot and ran, so
    /// it opened the account's pacing window again from its slot (#1109). RED
    /// with the window opened again only by a slice that made progress.
    @Test("A run stops after a slice that made no progress; it does not retry a failing folder until its deadline")
    func runStopsWithoutProgress() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 3)
        try await Self.withWorld("gcu-run-stuck", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            world.server.failListings(status: 503)
            let account = try await Self.account(world)
            let engine = world.engine
            let accountId = world.accountId
            let deadline = 40
            let slice = 3
            // When each slice started: inside its turn, after the turn opened
            // the window, before the slice asked for its slot.
            let sliceStarts = Mutex<[Date]>([])
            await engine.setCatchUpSliceStartHookForTesting { _ in sliceStarts.withLock { $0.append(Date()) } }
            _ = await engine.runCatchUpRun(
                account: account, run: Self.requestRun(world.server, slice: slice, deadline: deadline))
            await engine.setCatchUpSliceStartHookForTesting(nil)
            let lists = world.server.listRequests().count
            let windowAfter = await engine.catchUpSliceWindowEnds[accountId]
            let lastStart = sliceStarts.withLock { $0.last }
            #expect(lists >= 1, "precondition: the folder was tried")
            #expect(lists <= 2, "the run stopped once a slice made no progress: \(lists) list requests")
            #expect(try Self.state(world, inboxPath)?.lastCompletedAt == nil)
            // requestRun's window is one slice long.
            guard let window = windowAfter, let started = lastStart else {
                Issue.record("the run started a slice and the account has a pacing window")
                return
            }
            let reopened = window >= started.addingTimeInterval(TimeInterval(slice))
            #expect(reopened, "the slice that made no progress opened the window again from its slot")
        }
    }

    // MARK: - An access run's working time (#1109)

    /// Time a test adds to a run's clock while the run waits.
    final class AddedTime: Sendable {
        private let seconds = Mutex<TimeInterval>(0)
        /// Each read of the run's clock: when it was made (real time) and how
        /// many requests the run had sent before it.
        private let reads = Mutex<[(at: Date, sent: Int)]>([])
        func add(_ value: TimeInterval) { seconds.withLock { $0 += value } }
        var total: TimeInterval { seconds.withLock { $0 } }

        /// Records a read of the run's clock (the run helpers below call it).
        func noteRead(sent: Int) {
            let now = Date()
            reads.withLock { $0.append((at: now, sent: sent)) }
        }

        /// The last read of the run's clock made at or after `start` while the run
        /// had sent `sent` requests: with `sent` 0, the slice's check before its
        /// first request, after it got its slot.
        func lastRead(sent: Int, since start: Date) -> Date? {
            reads.withLock { $0.filter { $0.sent == sent && $0.at >= start }.map(\.at).max() }
        }
    }

    /// An access run (#1109) of the Inbox whose slices are `slice` requests long
    /// and whose working time is `work` requests: its clock advances one second
    /// per request the server has seen since the run began, from `base`, plus
    /// the time the test adds to `added` (time that passes while the run waits).
    /// Its pacing window is `interval` seconds of real time.
    private static func accessRun(
        _ world: World, slice: Int, work: Int, interval: TimeInterval, added: AddedTime, at base: Date = Date()
    ) -> SyncEngine.CatchUpRun {
        let server = world.server
        let before = server.http.recordedCalls().count
        var run = SyncEngine.CatchUpRun(
            storageLimitInForce: false, deadline: nil,
            sliceSeconds: TimeInterval(slice), intervalSeconds: interval,
            clock: {
                let sent = server.http.recordedCalls().count - before
                added.noteRead(sent: sent)
                return base.addingTimeInterval(TimeInterval(sent) + added.total)
            })
        run.workSeconds = TimeInterval(work)
        run.accessedFolderIds = [world.folderId(inboxPath)]
        return run
    }

    /// An access run's slices go on until their working time is spent, and the
    /// last slice is cut to what is left: with slices of six requests (two
    /// ranges) and nine requests of working time, the run sends six, then
    /// three, and ends with that slice. It never takes the turn again only to
    /// find its time spent: a pass that queued behind the last slice holds the
    /// turn, and the run has already ended. RED with the slices' time not added
    /// up, with the last slice not cut, with an access run that stops after one
    /// slice, and with a run that asks for the turn again once its time is spent.
    @Test("An access run's slices go on until their working time is spent; the last slice is cut to what is left, and the run ends with it")
    func accessRunSpendsItsWorkingTime() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 8)
        try await Self.withWorld("gcu-access-work", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let account = try await Self.account(world)
            let engine = world.engine
            let accountId = world.accountId
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            let releaseStream = release.stream
            let starts = Mutex(0)
            let queued = Mutex<Task<Void, Never>?>(nil)
            // A pass queues behind the second slice, inside that slice's turn.
            await engine.setCatchUpSliceStartHookForTesting { _ in
                let slice = starts.withLock { $0 += 1; return $0 }
                guard slice == 2 else { return }
                let pass = OneSyncAtATimeTests.heldPass(
                    engine: engine, accountId: accountId, name: "after", log: log, release: releaseStream)
                queued.withLock { $0 = pass }
                _ = await OneSyncAtATimeTests.eventually { await engine.syncPassWaiters[accountId]?.count == 1 }
            }
            let ended = Mutex(false)
            let run = Self.accessRun(world, slice: 6, work: 9, interval: 0.05, added: AddedTime())
            let catchUp = Task {
                let progressed = await engine.runCatchUpRun(account: account, run: run)
                ended.withLock { $0 = true }
                return progressed
            }
            let endedWhileHeld = await OneSyncAtATimeTests.eventually {
                let runEnded = ended.withLock { $0 }
                return runEnded && log.snapshot == ["start after"]
            }
            release.continuation.finish()
            if let pass = queued.withLock({ $0 }) { await pass.value }
            let progressed = await catchUp.value
            await engine.setCatchUpSliceStartHookForTesting(nil)

            let slices = starts.withLock { $0 }
            let sent = world.server.http.recordedCalls().count
            let ranges = world.server.listRequests().filter { $0.labelId == inboxPath }.count
            let listingOpen = try Self.state(world, inboxPath)?.listing != nil
            #expect(progressed, "the run made progress")
            #expect(slices == 2, "the run took two slices: \(slices)")
            #expect(sent == 9, "the run sent its nine requests of working time: \(sent)")
            #expect(ranges == 3, "two ranges in the first slice and one in the cut last slice: \(ranges)")
            #expect(listingOpen, "precondition: the listing needs more than the run's time")
            #expect(endedWhileHeld, "the run ended with the slice that spent its time, while a pass that queued behind that slice held the turn")
        }
    }

    /// An access run's working time is its slices' time inside the turn (sync
    /// timing promise 2): time that passes while the run waits for the turn
    /// before a later slice, and while it waits for the pacing window between
    /// slices, is not counted. The run's clock moves on 100 s in each of those
    /// waits, far past its nine seconds; the run still sends its three slices
    /// of three requests. RED with a later slice's time measured from before its
    /// wait for the turn, and with the pacing wait counted.
    @Test("An access run's waits for the turn and for the pacing window between its slices are not working time")
    func accessRunWaitsAreNotWorkingTime() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 8)
        let window = 2.0
        try await Self.withWorld("gcu-access-waits", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let account = try await Self.account(world)
            let engine = world.engine
            let accountId = world.accountId
            let added = AddedTime()
            let log = OneSyncAtATimeTests.PassLog()
            let releases = (0..<3).map { _ in AsyncStream<Void>.makeStream() }
            let turnStream = releases[0].stream
            let pacingStream = releases[1].stream
            let starts = Mutex(0)
            let queued = Mutex<[Task<Void, Never>]>([])
            // A pass queues behind each of the first two slices, inside its turn.
            await engine.setCatchUpSliceStartHookForTesting { _ in
                let slice = starts.withLock { $0 += 1; return $0 }
                guard slice <= 2 else { return }
                let pass = OneSyncAtATimeTests.heldPass(
                    engine: engine, accountId: accountId, name: slice == 1 ? "turn" : "pacing", log: log,
                    release: slice == 1 ? turnStream : pacingStream)
                queued.withLock { $0.append(pass) }
                _ = await OneSyncAtATimeTests.eventually { await engine.syncPassWaiters[accountId]?.count == 1 }
            }
            let run = Self.accessRun(world, slice: 3, work: 9, interval: window, added: added)
            let catchUp = Task { await engine.runCatchUpRun(account: account, run: run) }
            // A precondition that fails ends the test here: every held pass is
            // let go, and the run and the passes are waited for.
            // The run is waited for before the passes are read, so a pass its
            // hook queued late is waited for too.
            func finish() async -> Bool {
                for release in releases { release.continuation.finish() }
                let progressed = await catchUp.value
                for pass in queued.withLock({ $0 }) { await pass.value }
                await engine.setCatchUpSliceStartHookForTesting(nil)
                return progressed
            }
            func stop(_ reason: Comment) async {
                Issue.record(reason)
                _ = await finish()
            }

            // The wait for the turn: the first pass holds it after the first
            // slice, with the run in line behind it, until the first slice's
            // window has ended, so the run's next turn runs a slice.
            guard await OneSyncAtATimeTests.eventually({
                guard log.snapshot == ["start turn"] else { return false }
                return await engine.syncPassWaiters[accountId]?.count == 1
            }) else { return await stop("precondition: the run waits for the turn behind a pass after its first slice") }
            added.add(100)
            try? await Task.sleep(for: .seconds(window))
            releases[0].continuation.finish()

            // The pacing wait: the second pass holds the turn after the second
            // slice, with the run in line behind it. The run takes the turn when
            // the pass ends, finds the second slice's window open and waits for
            // it outside the turn. A third pass, in line behind the run, takes
            // the turn then: while it holds it with the run out of line and no
            // third slice started, the run is in its pacing wait.
            guard await OneSyncAtATimeTests.eventually({
                guard log.snapshot.contains("start pacing"), starts.withLock({ $0 }) == 2 else { return false }
                return await engine.syncPassWaiters[accountId]?.count == 1
            }) else { return await stop("precondition: the run's second slice ran at once, and the run waits for the turn behind a pass after it") }
            releases[1].continuation.finish()
            let third = OneSyncAtATimeTests.heldPass(
                engine: engine, accountId: accountId, name: "sleep", log: log, release: releases[2].stream)
            queued.withLock { $0.append(third) }
            guard await OneSyncAtATimeTests.eventually({
                guard log.snapshot.contains("start sleep"), starts.withLock({ $0 }) == 2 else { return false }
                return (await engine.syncPassWaiters[accountId]?.count ?? 0) == 0
            }) else { return await stop("precondition: the run waits for the second slice's window while a pass holds the turn") }
            added.add(100)

            let progressed = await finish()
            let slices = starts.withLock { $0 }
            let sent = world.server.http.recordedCalls().count
            let ranges = world.server.listRequests().filter { $0.labelId == inboxPath }.count
            #expect(progressed, "the run made progress")
            #expect(slices == 3, "the run took its three slices, whatever its clock did while it waited: \(slices)")
            #expect(sent == 9, "the run sent its nine requests of working time: \(sent)")
            #expect(ranges == 3, "one range in each slice: \(ranges)")
        }
    }

    /// Other provider work holding the one slot of the world's provider work
    /// queue (the world registers a queue one slot wide) from `take()` until
    /// `release()`. As it lets the slot go it adds `seconds` to the run's clock:
    /// time that passes while a slice waits for the slot.
    ///
    /// The test makes it before the run starts and calls `release()` on every
    /// way out, so nothing is left holding or waiting for the slot: a `take()`
    /// that comes after `release()` (from a hook that ran late) asks for
    /// nothing, and a request for the slot not yet granted is cancelled.
    final class SlotHolder: Sendable {
        private let queue: ProviderWorkQueue
        private let seconds: TimeInterval
        private let added: AddedTime
        private let stream: AsyncStream<Void>
        private let gate: AsyncStream<Void>.Continuation
        private let held = Mutex(false)
        private let state = Mutex<(task: Task<Void, Never>?, released: Bool)>((task: nil, released: false))

        init(_ queue: ProviderWorkQueue, adding seconds: TimeInterval, to added: AddedTime) {
            self.queue = queue
            self.seconds = seconds
            self.added = added
            let made = AsyncStream<Void>.makeStream()
            stream = made.stream
            gate = made.continuation
        }

        /// Whether the other work got the slot. It stays true after `release()`,
        /// so the tests read it before they let the slot go.
        var isHeld: Bool { held.withLock { $0 } }

        /// Whether `release()` was called.
        private var isReleased: Bool { state.withLock { $0.released } }

        /// Asks for the slot once, and returns once it is held (true), or once
        /// it was released or the bounded wait ended (false). Asks for nothing
        /// after `release()`.
        @discardableResult
        func take() async -> Bool {
            let asked: Bool = state.withLock {
                guard !$0.released, $0.task == nil else { return false }
                $0.task = Task { await self.hold() }
                return true
            }
            guard asked else { return false }
            _ = await OneSyncAtATimeTests.eventually { self.isHeld || self.isReleased }
            return isHeld
        }

        /// Lets the slot go (adding the time) and waits for the other work to
        /// end. A request for the slot not yet granted is cancelled.
        func release() async {
            let task: Task<Void, Never>? = state.withLock {
                $0.released = true
                return $0.task
            }
            gate.finish()
            task?.cancel()
            await task?.value
        }

        /// The cancellable request for the slot (the throwing `execute`): a
        /// cancelled request ends without the slot.
        private func hold() async {
            let stream = self.stream
            _ = try? await queue.execute(priority: .userAction) { () async -> Bool in
                self.held.withLock { $0 = true }
                for await _ in stream { break }
                self.added.add(self.seconds)
                return true
            }
        }
    }

    /// The world's provider work queue.
    private static func workQueue(_ world: World) async throws -> ProviderWorkQueue {
        let registered = await world.engine.workQueues[world.accountId]
        return try #require(registered, "the world's account has a work queue")
    }

    /// A run of the Inbox whose clock advances one second per request the
    /// server has seen since the run began, from `base`, plus the time the test
    /// adds to `added`. A background job's run when `deadline` (seconds of that
    /// clock) is set, else one foreground backfill cycle.
    private static func clockedRun(
        _ world: World, slice: Int, deadline: TimeInterval?, interval: TimeInterval, added: AddedTime, at base: Date = Date()
    ) -> SyncEngine.CatchUpRun {
        let server = world.server
        let before = server.http.recordedCalls().count
        return SyncEngine.CatchUpRun(
            storageLimitInForce: false, deadline: deadline.map { base.addingTimeInterval($0) },
            sliceSeconds: TimeInterval(slice), intervalSeconds: interval,
            clock: {
                let sent = server.http.recordedCalls().count - before
                added.noteRead(sent: sent)
                return base.addingTimeInterval(TimeInterval(sent) + added.total)
            })
    }

    /// An access run's slice starts when its provider work starts (sync timing
    /// promise 2): the wait for a slot of the account's provider work queue,
    /// inside the turn, is not working time, and the slice has all of its time
    /// once it has the slot. The queue's one slot is held by other provider
    /// work while the run's first slice waits in the queue for it, having sent
    /// nothing, and the run's clock moves on 100 s before the slot is free; the
    /// run still sends its two slices of three requests. RED with the slice's
    /// clock started at its turn: the slice reached the provider with no time
    /// left, and the run sent nothing.
    @Test("An access run's wait for a slot of the provider work queue is not working time")
    func accessRunQueueWaitIsNotWorkingTime() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 8)
        try await Self.withWorld("gcu-access-queue", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let account = try await Self.account(world)
            let engine = world.engine
            let queue = try await Self.workQueue(world)
            let added = AddedTime()
            let holder = SlotHolder(queue, adding: 100, to: added)
            guard await holder.take() else {
                await holder.release()
                Issue.record("precondition: other provider work holds the queue's slot")
                return
            }
            let starts = Mutex(0)
            await engine.setCatchUpSliceStartHookForTesting { _ in starts.withLock { $0 += 1 } }
            let run = Self.accessRun(world, slice: 3, work: 6, interval: 0.05, added: added)
            let catchUp = Task { await engine.runCatchUpRun(account: account, run: run) }
            // The first slice has its turn and waits in the queue for the slot.
            let queued = await OneSyncAtATimeTests.eventually {
                guard starts.withLock({ $0 }) == 1 else { return false }
                return await queue.waitingCount == 1
            }
            let sentWhileHeld = world.server.http.recordedCalls().count
            await holder.release()
            let progressed = await catchUp.value
            await engine.setCatchUpSliceStartHookForTesting(nil)

            let slices = starts.withLock { $0 }
            let sent = world.server.http.recordedCalls().count
            #expect(queued, "precondition: the run's first slice waited in the queue for the slot")
            #expect(sentWhileHeld == 0, "nothing was sent while the slot was held: \(sentWhileHeld)")
            #expect(progressed, "the run made progress")
            #expect(slices == 2, "the run took two slices: \(slices)")
            #expect(sent == 6, "the run sent its six requests of working time, its first slice's wait for the slot not counted: \(sent)")
        }
    }

    /// A backfill slice's time also starts when its provider work starts (sync
    /// timing promise 2, every catch-up slice since #1109): a foreground cycle's
    /// one slice of three requests waits in the queue for its only slot, held by
    /// other provider work, while its clock moves on 100 s; it still sends its
    /// three requests, and opens the account's pacing window again from when it
    /// got the slot. RED with the slice's clock started at its turn (the slice
    /// reached the provider with no time left and sent nothing), and with the
    /// window left as the turn opened it for a foreground cycle.
    @Test("A backfill slice's wait for a slot of the provider work queue is not part of its time")
    func backfillSliceQueueWaitIsNotItsTime() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 8)
        let interval = 0.05
        try await Self.withWorld("gcu-backfill-queue", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let account = try await Self.account(world)
            let engine = world.engine
            let accountId = world.accountId
            let queue = try await Self.workQueue(world)
            let added = AddedTime()
            let holder = SlotHolder(queue, adding: 100, to: added)
            guard await holder.take() else {
                await holder.release()
                Issue.record("precondition: other provider work holds the queue's slot")
                return
            }
            let starts = Mutex(0)
            await engine.setCatchUpSliceStartHookForTesting { _ in starts.withLock { $0 += 1 } }
            let run = Self.clockedRun(world, slice: 3, deadline: nil, interval: interval, added: added)
            let catchUp = Task { await engine.runCatchUpRun(account: account, run: run) }
            let queued = await OneSyncAtATimeTests.eventually {
                guard starts.withLock({ $0 }) == 1 else { return false }
                return await queue.waitingCount == 1
            }
            let sentWhileHeld = world.server.http.recordedCalls().count
            let freed = Date()
            await holder.release()
            let progressed = await catchUp.value
            await engine.setCatchUpSliceStartHookForTesting(nil)

            let slices = starts.withLock { $0 }
            let sent = world.server.http.recordedCalls().count
            let windowAfter = await engine.catchUpSliceWindowEnds[accountId]
            #expect(queued, "precondition: the cycle's slice waited in the queue for the slot")
            #expect(sentWhileHeld == 0, "nothing was sent while the slot was held: \(sentWhileHeld)")
            #expect(progressed, "the slice made progress")
            #expect(slices == 1, "a foreground cycle takes one slice: \(slices)")
            #expect(sent == 3, "the slice sent its three requests, its wait for the slot not counted: \(sent)")
            guard let window = windowAfter else {
                Issue.record("the account has a pacing window")
                return
            }
            let afterFreed = window >= freed.addingTimeInterval(interval)
            let firstCheck = added.lastRead(sent: 0, since: freed) ?? .distantPast
            let byFirstRequest = window <= firstCheck.addingTimeInterval(interval)
            #expect(afterFreed, "the cycle's slice opened the window again after the slot came free")
            #expect(byFirstRequest, "the cycle's slice opened the window again no later than its first request")
        }
    }

    /// A later slice of the background job also starts its clock at its slot:
    /// the job's first slice runs freely; its second slice waits in the queue
    /// for the slot, held by other provider work, while the job's clock moves on
    /// 100 s (its deadline is far away); that slice still sends its three
    /// requests, opens the account's pacing window again from when it got the
    /// slot, and the job goes on. The window is read while a pass that queued
    /// behind the second slice holds the turn, so nothing else can change it.
    /// RED with a slice's clock started at its turn, for every slice, for the
    /// job's slices, or for later slices only, and with the window opened again
    /// only by a run's first slice.
    @Test("A later slice of the background job does not count its wait for a slot of the provider work queue")
    func jobLaterSliceQueueWaitIsNotItsTime() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 8)
        let interval = 0.05
        try await Self.withWorld("gcu-job-queue", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let account = try await Self.account(world)
            let engine = world.engine
            let accountId = world.accountId
            let queue = try await Self.workQueue(world)
            let server = world.server
            let added = AddedTime()
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            let releaseStream = release.stream
            let behind = Mutex<Task<Void, Never>?>(nil)
            // The requests sent before each slice started.
            let sentAtStart = Mutex<[Int]>([])
            // Made before the run and let go on every way out (a hook that runs
            // late then asks for nothing).
            let holder = SlotHolder(queue, adding: 100, to: added)
            // The second slice: other work takes the slot, and a pass queues
            // behind the slice, inside its turn.
            await engine.setCatchUpSliceStartHookForTesting { _ in
                let slice = sentAtStart.withLock { $0.append(server.http.recordedCalls().count); return $0.count }
                guard slice == 2 else { return }
                await holder.take()
                let pass = OneSyncAtATimeTests.heldPass(
                    engine: engine, accountId: accountId, name: "behind", log: log, release: releaseStream)
                behind.withLock { $0 = pass }
                _ = await OneSyncAtATimeTests.eventually { await engine.syncPassWaiters[accountId]?.count == 1 }
            }
            let run = Self.clockedRun(world, slice: 3, deadline: 1000, interval: interval, added: added)
            let catchUp = Task { await engine.runCatchUpRun(account: account, run: run) }
            let queued = await OneSyncAtATimeTests.eventually {
                guard sentAtStart.withLock({ $0.count }) == 2, holder.isHeld else { return false }
                guard await engine.syncPassWaiters[accountId]?.count == 1 else { return false }
                return await queue.waitingCount == 1
            }
            let sentWhileHeld = server.http.recordedCalls().count
            let freed = Date()
            await holder.release()
            // The second slice ran and handed its turn to the pass: the window
            // stays as the slice left it until the pass ends.
            let passHolds = await OneSyncAtATimeTests.eventually { log.snapshot == ["start behind"] }
            let windowAfterSecond = await engine.catchUpSliceWindowEnds[accountId]
            release.continuation.finish()
            _ = await catchUp.value
            if let pass = behind.withLock({ $0 }) { await pass.value }
            await engine.setCatchUpSliceStartHookForTesting(nil)

            let starts = sentAtStart.withLock { $0 }
            #expect(queued, "precondition: the job's second slice waited in the queue for a held slot, a pass in line behind it")
            #expect(passHolds, "precondition: the pass took the turn when the second slice ended")
            guard starts.count >= 3 else {
                Issue.record("the job went on after its second slice: \(starts)")
                return
            }
            #expect(sentWhileHeld == starts[1], "the second slice sent nothing while the slot was held")
            #expect(starts[2] - starts[1] == 3, "the second slice sent its three requests, its wait for the slot not counted: \(starts)")
            guard let window = windowAfterSecond else {
                Issue.record("the account has a pacing window after the second slice")
                return
            }
            let afterFreed = window >= freed.addingTimeInterval(interval)
            #expect(afterFreed, "the second slice opened the window again after the slot came free")
        }
    }

    /// The background job's deadline is a fixed instant, checked when a slice
    /// gets its slot: a slice that got it 48 s into a job with 51 s has three
    /// seconds left and sends three requests; one that got it 49 s in has two
    /// seconds, less than a slice, and sends two; one that got it 100 s in finds
    /// the job over and sends nothing. A slice that ran opens the account's
    /// pacing window again from when it got its slot (after the slot came free,
    /// no later than its first request); one that found the job over leaves the
    /// window its turn opened. RED with the context made at the turn (the slice
    /// reached the provider with no time left), with a fresh slice given
    /// whatever the deadline at the slot, with the slice not cut to the deadline
    /// at its slot (the 49 s row sends three), with the window left as the turn
    /// opened it after a slice that ran, with it opened from the slice's end, and
    /// with it opened again for a slice that found the job over.
    @Test("A background job whose deadline passes while its slice waits for its slot ends there",
          arguments: zip([48.0, 49.0, 100.0], [3, 2, 0]))
    func jobDeadlineIsCheckedAtTheSlot(waited: TimeInterval, expected: Int) async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 8)
        let interval = 0.05
        try await Self.withWorld("gcu-job-deadline-\(Int(waited))", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let account = try await Self.account(world)
            let engine = world.engine
            let accountId = world.accountId
            let queue = try await Self.workQueue(world)
            let added = AddedTime()
            let holder = SlotHolder(queue, adding: waited, to: added)
            guard await holder.take() else {
                await holder.release()
                Issue.record("precondition: other provider work holds the queue's slot")
                return
            }
            let starts = Mutex(0)
            // The window the first slice's turn opened.
            let reserved = Mutex<Date?>(nil)
            await engine.setCatchUpSliceStartHookForTesting { _ in
                let first = starts.withLock { $0 += 1; return $0 == 1 }
                guard first else { return }
                let window = await engine.catchUpSliceWindowEnds[accountId]
                reserved.withLock { $0 = window }
            }
            let run = Self.clockedRun(world, slice: 3, deadline: 51, interval: interval, added: added)
            let catchUp = Task { await engine.runCatchUpRun(account: account, run: run) }
            let queued = await OneSyncAtATimeTests.eventually {
                guard starts.withLock({ $0 }) == 1 else { return false }
                return await queue.waitingCount == 1
            }
            // The window the turn opened is over well before the slot comes free.
            try? await Task.sleep(for: .milliseconds(100))
            let freed = Date()
            await holder.release()
            let progressed = await catchUp.value
            await engine.setCatchUpSliceStartHookForTesting(nil)

            let sent = world.server.http.recordedCalls().count
            let windowAfter = await engine.catchUpSliceWindowEnds[accountId]
            let turnWindowSeen = reserved.withLock { $0 }
            #expect(queued, "precondition: the first slice waited in the queue for the slot")
            #expect(sent == expected, "\(sent) requests after the slot came \(waited) s into a job of 51 s")
            #expect(turnWindowSeen != nil, "precondition: the slice's turn opened the account's pacing window")
            guard let window = windowAfter, let turnWindow = turnWindowSeen else {
                Issue.record("the account has a pacing window")
                return
            }
            if expected == 0 {
                #expect(!progressed, "no progress when the slice found the job over")
                #expect(window == turnWindow, "a slice that found the job over left the window its turn opened")
                return
            }
            if expected == 3 { #expect(progressed, "the slice that ran made progress") }
            // The window's end against the two bounds moved on by the same
            // interval: no tolerance, and no subtraction from the stored end.
            let afterFreed = window >= freed.addingTimeInterval(interval)
            let firstCheck = added.lastRead(sent: 0, since: freed) ?? .distantPast
            let byFirstRequest = window <= firstCheck.addingTimeInterval(interval)
            let sinceFreed = window.timeIntervalSince(freed) - interval
            #expect(afterFreed, "the window was opened again after the slot came free: \(sinceFreed) s")
            #expect(byFirstRequest, "the window was opened again no later than the slice's first request")
        }
    }

    /// The kind of run a pacing test drives.
    enum PacingKind: String, Sendable {
        /// An access run (#1109), its working time two slices.
        case access
        /// The background job, its deadline two slices away.
        case job
    }

    /// A slice that waited for its slot opens the account's pacing window again
    /// from when it got the slot: after the slot came free and no later than its
    /// first request, whether its wait was longer than the window (the window its
    /// turn opened had run out) or shorter (it had not), for an access run and
    /// for the background job. The run's next slice starts no earlier than the
    /// window's end. The window is read while a pass that queued behind the
    /// first slice holds the turn, so nothing else can change it. Each row checks
    /// its own case: the long wait ends after the turn's window, the short one
    /// before it, and the pass lets the turn go before the slice's window ends,
    /// so the next slice has a window to wait for. RED with the window left as
    /// the turn opened it (either wait), with it opened again only once it had
    /// run out (the short wait), only for access runs (the job's rows), or from
    /// the slice's end (it is then later than the slice's first request), and
    /// with the next slice not waiting for the window.
    @Test("A slice that waited for its slot paces the next slice from when it got its slot",
          arguments: zip([PacingKind.access, .access, .job, .job], [1.2, 0.15, 1.2, 0.15]))
    func aSliceThatWaitedForItsSlotPacesTheNext(kind: PacingKind, waitedWindows: Double) async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 8)
        let window = 2.0
        try await Self.withWorld("gcu-pacing-slot-\(kind.rawValue)-\(Int(waitedWindows * 100))", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let account = try await Self.account(world)
            let engine = world.engine
            let accountId = world.accountId
            let queue = try await Self.workQueue(world)
            let added = AddedTime()
            let holder = SlotHolder(queue, adding: 0, to: added)
            guard await holder.take() else {
                await holder.release()
                Issue.record("precondition: other provider work holds the queue's slot")
                return
            }
            let log = OneSyncAtATimeTests.PassLog()
            let release = AsyncStream<Void>.makeStream()
            let releaseStream = release.stream
            let behind = Mutex<Task<Void, Never>?>(nil)
            let startedAt = Mutex<[Date]>([])
            // The window the first slice's turn opened.
            let reserved = Mutex<Date?>(nil)
            // A pass queues behind the first slice, inside its turn.
            await engine.setCatchUpSliceStartHookForTesting { _ in
                let slice = startedAt.withLock { $0.append(Date()); return $0.count }
                guard slice == 1 else { return }
                let turnWindow = await engine.catchUpSliceWindowEnds[accountId]
                reserved.withLock { $0 = turnWindow }
                let pass = OneSyncAtATimeTests.heldPass(
                    engine: engine, accountId: accountId, name: "behind", log: log, release: releaseStream)
                behind.withLock { $0 = pass }
                _ = await OneSyncAtATimeTests.eventually { await engine.syncPassWaiters[accountId]?.count == 1 }
            }
            let run = kind == .access
                ? Self.accessRun(world, slice: 3, work: 6, interval: window, added: added)
                : Self.clockedRun(world, slice: 3, deadline: 6, interval: window, added: added)
            let catchUp = Task { await engine.runCatchUpRun(account: account, run: run) }
            // Every way out lets the slot and the pass go and waits for the run,
            // then for the pass, so a pass its hook queued late is waited for too.
            func finish() async {
                release.continuation.finish()
                await holder.release()
                _ = await catchUp.value
                if let pass = behind.withLock({ $0 }) { await pass.value }
                await engine.setCatchUpSliceStartHookForTesting(nil)
            }

            guard await OneSyncAtATimeTests.eventually({
                guard startedAt.withLock({ $0.count }) == 1, await engine.syncPassWaiters[accountId]?.count == 1 else { return false }
                return await queue.waitingCount == 1
            }) else {
                Issue.record("precondition: the first slice waits in the queue for the slot, a pass in line behind it")
                return await finish()
            }
            try? await Task.sleep(for: .seconds(window * waitedWindows))
            let freed = Date()
            await holder.release()
            // The first slice ran and handed its turn to the pass: the window
            // stays as the slice left it until the pass ends.
            guard await OneSyncAtATimeTests.eventually({ log.snapshot == ["start behind"] }) else {
                Issue.record("precondition: the pass took the turn when the first slice ended")
                return await finish()
            }
            let windowAfterSlice = await engine.catchUpSliceWindowEnds[accountId]
            let passReleased = Date()
            await finish()

            let starts = startedAt.withLock { $0 }
            let sent = world.server.http.recordedCalls().count
            let turnWindowSeen = reserved.withLock { $0 }
            #expect(starts.count == 2, "the run took two slices: \(starts.count)")
            #expect(sent == 6, "both slices sent their three requests: \(sent)")
            guard let end = windowAfterSlice, let turnWindow = turnWindowSeen, starts.count == 2 else {
                Issue.record("the turn opened a pacing window, the account has one after the first slice, and a second slice")
                return
            }
            if waitedWindows < 1 {
                #expect(freed < turnWindow, "precondition: the window the turn opened was still open when the slot came free")
            } else {
                #expect(freed >= turnWindow, "precondition: the window the turn opened had run out when the slot came free")
            }
            #expect(passReleased < end, "precondition: the pass let the turn go before the slice's window ended")
            // The window's end against the two bounds moved on by the same
            // interval: no tolerance, and no subtraction from the stored end.
            let afterFreed = end >= freed.addingTimeInterval(window)
            let firstCheck = added.lastRead(sent: 0, since: freed) ?? .distantPast
            let byFirstRequest = end <= firstCheck.addingTimeInterval(window)
            let nextWaited = starts[1] >= end
            let sinceFreed = end.timeIntervalSince(freed) - window
            let nextAfterEnd = starts[1].timeIntervalSince(end)
            #expect(afterFreed, "the window was opened again after the slot came free: \(sinceFreed) s")
            #expect(byFirstRequest, "the window was opened again no later than the slice's first request")
            #expect(nextWaited, "the next slice started \(nextAfterEnd) s after the window's end")
        }
    }

    /// The pacing window is the account's, whatever run opened it: an access
    /// run's slice that waited a little for its slot (less than the window)
    /// opens it again from its slot, and the background job that comes next
    /// waits for it. A job whose deadline falls inside that window ends at its
    /// turn without a request; one whose deadline is later starts its slice
    /// once the window has ended. The first job's deadline is a tenth of a
    /// request away, so it falls inside the window unless nearly all of it has
    /// passed; the later job has exactly one slice of time, so its next turn
    /// ends it whatever the window. RED with the window opened again only once
    /// it had run out, with a job that does not wait for a window another run
    /// opened, and with a job that waits for a window past its deadline.
    @Test("The background job waits for the pacing window an access run's slice opened")
    func aJobWaitsForTheWindowAnAccessSliceOpened() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 8)
        let window = 3.0
        try await Self.withWorld("gcu-pacing-cross-run", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let account = try await Self.account(world)
            let engine = world.engine
            let accountId = world.accountId
            let queue = try await Self.workQueue(world)
            let added = AddedTime()
            let holder = SlotHolder(queue, adding: 0, to: added)
            guard await holder.take() else {
                await holder.release()
                Issue.record("precondition: other provider work holds the queue's slot")
                return
            }
            let startedAt = Mutex<[Date]>([])
            await engine.setCatchUpSliceStartHookForTesting { _ in startedAt.withLock { $0.append(Date()) } }
            let access = Self.accessRun(world, slice: 3, work: 3, interval: window, added: added)
            let accessRun = Task { await engine.runCatchUpRun(account: account, run: access) }
            let queued = await OneSyncAtATimeTests.eventually {
                guard startedAt.withLock({ $0.count }) == 1 else { return false }
                return await queue.waitingCount == 1
            }
            try? await Task.sleep(for: .milliseconds(300))
            let freed = Date()
            await holder.release()
            _ = await accessRun.value
            let windowAfterAccess = await engine.catchUpSliceWindowEnds[accountId]
            let sentByAccess = world.server.http.recordedCalls().count

            // Its deadline a tenth of a request away: inside the window.
            let short = Self.clockedRun(world, slice: 3, deadline: 0.1, interval: window, added: AddedTime())
            let shortProgressed = await engine.runCatchUpRun(account: account, run: short)
            let shortEnded = Date()
            let sentByShort = world.server.http.recordedCalls().count - sentByAccess
            // Its deadline three requests away: past what is left of the window
            // at its turn, and exactly one slice, so the turn after that slice
            // ends the job (its clock has reached the deadline).
            let long = Self.clockedRun(world, slice: 3, deadline: 3, interval: window, added: AddedTime())
            let longProgressed = await engine.runCatchUpRun(account: account, run: long)
            await engine.setCatchUpSliceStartHookForTesting(nil)

            let starts = startedAt.withLock { $0 }
            let sentByLong = world.server.http.recordedCalls().count - sentByAccess - sentByShort
            #expect(queued, "precondition: the access run's slice waited in the queue for the slot")
            #expect(sentByAccess == 3, "precondition: the access run's slice sent its three requests: \(sentByAccess)")
            #expect(sentByShort == 0, "the job whose deadline falls inside the window sent nothing: \(sentByShort)")
            #expect(!shortProgressed, "the job whose deadline falls inside the window made no progress")
            #expect(sentByLong == 3, "the later job sent one slice once the window ended: \(sentByLong)")
            #expect(longProgressed, "the later job made progress")
            #expect(starts.count == 2, "one slice for the access run, one for the later job: \(starts.count)")
            guard let end = windowAfterAccess, starts.count == 2 else {
                Issue.record("the account has a pacing window after the access run, and two slices")
                return
            }
            let afterFreed = end >= freed.addingTimeInterval(window)
            let shortDidNotWait = shortEnded < end
            let longWaited = starts[1] >= end
            let sinceFreed = end.timeIntervalSince(freed) - window
            #expect(afterFreed, "the access slice opened the window again from its slot: \(sinceFreed) s after the slot came free")
            #expect(shortDidNotWait, "the job whose deadline falls inside the window ended without waiting for it")
            #expect(longWaited, "the later job's slice started before the window the access run's slice opened had ended")
        }
    }

    /// A run that waits for the account's turn reads the pacing window when it
    /// gets the turn: a job asks for the turn while an access run's slice holds
    /// it and waits for its slot longer than the window. The window the access
    /// slice's turn opened has run out by then, and the slice opens it again
    /// from its slot; the job, taking the turn next, waits for that window and
    /// starts its slice no earlier than one window after the slot came free.
    /// RED with the window read before the wait for the turn (the job sees the
    /// turn's window, run out, and starts at once), and with the window left as
    /// the turn opened it.
    @Test("A run that waited for the turn waits for the pacing window the slice before it opened")
    func aRunThatWaitedForTheTurnReadsTheWindowAtItsTurn() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 8)
        let window = 1.0
        try await Self.withWorld("gcu-pacing-queued-run", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let account = try await Self.account(world)
            let engine = world.engine
            let accountId = world.accountId
            let queue = try await Self.workQueue(world)
            let added = AddedTime()
            let holder = SlotHolder(queue, adding: 0, to: added)
            guard await holder.take() else {
                await holder.release()
                Issue.record("precondition: other provider work holds the queue's slot")
                return
            }
            // The job's clock also counts the access slice's three requests, so
            // its deadline six is one slice of its own.
            let jobRun = Self.clockedRun(world, slice: 3, deadline: 6, interval: window, added: AddedTime())
            let job = Mutex<Task<Bool, Never>?>(nil)
            let startedAt = Mutex<[Date]>([])
            // The job asks for the turn inside the access slice's turn.
            await engine.setCatchUpSliceStartHookForTesting { _ in
                let slice = startedAt.withLock { $0.append(Date()); return $0.count }
                guard slice == 1 else { return }
                let task = Task { await engine.runCatchUpRun(account: account, run: jobRun) }
                job.withLock { $0 = task }
                _ = await OneSyncAtATimeTests.eventually { await engine.syncPassWaiters[accountId]?.count == 1 }
            }
            let access = Self.accessRun(world, slice: 3, work: 3, interval: window, added: added)
            let accessRun = Task { await engine.runCatchUpRun(account: account, run: access) }
            // Every way out lets the slot go and waits for the access run, then
            // for the job its hook started.
            func finish() async -> Bool {
                await holder.release()
                _ = await accessRun.value
                let jobTask = job.withLock { $0 }
                let jobProgressed = await jobTask?.value ?? false
                await engine.setCatchUpSliceStartHookForTesting(nil)
                return jobProgressed
            }

            guard await OneSyncAtATimeTests.eventually({
                guard startedAt.withLock({ $0.count }) == 1, await engine.syncPassWaiters[accountId]?.count == 1 else { return false }
                return await queue.waitingCount == 1
            }) else {
                Issue.record("precondition: the access slice waits in the queue for the slot, the job in line for the turn")
                _ = await finish()
                return
            }
            try? await Task.sleep(for: .seconds(window * 1.2))
            let freed = Date()
            let jobProgressed = await finish()

            let starts = startedAt.withLock { $0 }
            let sent = world.server.http.recordedCalls().count
            #expect(sent == 6, "the access slice and the job's slice sent three requests each: \(sent)")
            #expect(jobProgressed, "the job made progress")
            #expect(starts.count == 2, "one slice for the access run, one for the job: \(starts.count)")
            guard starts.count == 2 else { return }
            let jobWaited = starts[1] >= freed.addingTimeInterval(window)
            let startedAfterFreed = starts[1].timeIntervalSince(freed)
            #expect(jobWaited, "the job's slice started \(startedAfterFreed) s after the slot came free, before the window the access slice opened again had ended")
        }
    }

    /// A run cancelled while its slice waits in the queue for a slot ends there:
    /// it does not wait for the slot, sends nothing more, keeps the progress of
    /// its earlier slice, frees the account's turn, and leaves the pacing window
    /// the slice's turn opened. RED with a slot wait that ignores cancellation,
    /// and with the window opened again for a slice that never got its slot.
    @Test("A run cancelled while its slice waits for a slot ends at once, keeps its progress and frees the turn")
    func aRunCancelledInTheQueueEnds() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 8)
        try await Self.withWorld("gcu-queue-cancel", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let account = try await Self.account(world)
            let engine = world.engine
            let accountId = world.accountId
            let queue = try await Self.workQueue(world)
            let added = AddedTime()
            let starts = Mutex(0)
            // The window the second slice's turn opened.
            let reserved = Mutex<Date?>(nil)
            // Made before the run and let go on every way out (a hook that runs
            // late then asks for nothing).
            let holder = SlotHolder(queue, adding: 0, to: added)
            await engine.setCatchUpSliceStartHookForTesting { _ in
                let slice = starts.withLock { $0 += 1; return $0 }
                guard slice == 2 else { return }
                let window = await engine.catchUpSliceWindowEnds[accountId]
                reserved.withLock { $0 = window }
                await holder.take()
            }
            let run = Self.accessRun(world, slice: 3, work: 9, interval: 0.05, added: added)
            let catchUp = Task { await engine.runCatchUpRun(account: account, run: run) }
            let ended = Mutex(false)
            let watcher = Task {
                let progressed = await catchUp.value
                ended.withLock { $0 = true }
                return progressed
            }
            let queued = await OneSyncAtATimeTests.eventually {
                guard starts.withLock({ $0 }) == 2, holder.isHeld else { return false }
                return await queue.waitingCount == 1
            }
            let sentBefore = world.server.http.recordedCalls().count
            catchUp.cancel()
            let endedWhileHeld = await OneSyncAtATimeTests.eventually { ended.withLock { $0 } }
            let turnFree = !(await engine.syncPassRunning.contains(accountId))
            let windowAfterCancel = await engine.catchUpSliceWindowEnds[accountId]
            await holder.release()
            let progressed = await watcher.value
            await engine.setCatchUpSliceStartHookForTesting(nil)

            let sent = world.server.http.recordedCalls().count
            let turnWindow = reserved.withLock { $0 }
            #expect(queued, "precondition: the run's second slice waited in the queue for a held slot")
            #expect(endedWhileHeld, "the cancelled run ended while the slot was still held")
            #expect(turnFree, "the run freed the account's turn")
            #expect(progressed, "the first slice's progress is kept")
            #expect(sentBefore == 3, "precondition: the first slice sent its three requests: \(sentBefore)")
            #expect(sent == sentBefore, "nothing was sent after the cancel: \(sent)")
            #expect(turnWindow != nil, "precondition: the second slice's turn opened the account's pacing window")
            #expect(windowAfterCancel == turnWindow, "the slice that never got its slot left the window its turn opened")
        }
    }

    /// A background job whose deadline passed before it got the turn ends at the
    /// turn: it opens no pacing window, starts no slice, asks for no slot of the
    /// provider work queue, and sends nothing. RED with the deadline checked
    /// only at the slot (the job opens a window and starts a slice first).
    @Test("A background job whose deadline passed before its turn ends at the turn, opening no window")
    func jobOverAtItsTurnOpensNoWindow() async throws {
        let clock = Clock()
        let (seeds, local) = Self.rangesWorld(clock, count: 8)
        try await Self.withWorld("gcu-job-over-at-turn", seeds: seeds, local: local, folders: Self.inboxOnly) { world async throws in
            let account = try await Self.account(world)
            let engine = world.engine
            let accountId = world.accountId
            let starts = Mutex(0)
            await engine.setCatchUpSliceStartHookForTesting { _ in starts.withLock { $0 += 1 } }
            let windowBefore = await engine.catchUpSliceWindowEnds[accountId]
            let sentBefore = world.server.http.recordedCalls().count
            // Its deadline a second before it starts.
            let run = Self.clockedRun(world, slice: 3, deadline: -1, interval: 0.05, added: AddedTime())
            let progressed = await engine.runCatchUpRun(account: account, run: run)
            await engine.setCatchUpSliceStartHookForTesting(nil)

            let slices = starts.withLock { $0 }
            let sent = world.server.http.recordedCalls().count - sentBefore
            let windowAfter = await engine.catchUpSliceWindowEnds[accountId]
            #expect(!progressed, "the job made no progress")
            #expect(slices == 0, "the job started no slice: \(slices)")
            #expect(sent == 0, "the job sent nothing: \(sent)")
            #expect(windowAfter == windowBefore, "the job opened no pacing window")
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

    /// One foreground poll.
    private static func syncPass(_ world: World, engine: SyncEngine? = nil) async throws {
        let accountId = world.accountId
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
            world.server.expireHistory()

            try await Self.syncPass(world)
            try await Self.backfillCycles(world)

            let inbox = try Self.rows(world, inboxPath)
            #expect(inbox["o0"]?.isRead == true, "the read change")
            #expect(inbox["o1"] == nil, "the archive")
            #expect(inbox["o2"] == nil, "the deletion")
            #expect(inbox["o3"] != nil && inbox["o4"] != nil)
            let captured = try #require(try Self.cursor(world))
            #expect(captured == world.server.currentHistoryId())

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
