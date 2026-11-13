/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Outlook's change reader (`ExchangeProviderChanges.swift`) against the stateful
/// Graph fake (`StatefulExchangeActionServer`), with a real `DatabasePool` and the
/// engine's own apply. Every test asserts what the user sees (rows, flags) or a
/// bound the read must keep (requests sent, bookmark position), never how the
/// reader gets there.
///
/// Two drivers:
/// - `World.read`: one read with a frozen clock and an exact request allowance,
///   each folder applied with `SyncEngine.applyFolderChanges`, as the engine does;
/// - `World.delta` / `World.foregroundPass`: the engine's own entries.
///
/// `.serialized, .processGlobalState`: these tests replace `AppDatabase.shared`.
@Suite("Outlook change reader", .serialized, .processGlobalState)
struct OutlookChangeReadingTests {

    static let inbox = "fld-inbox"
    static let archive = "fld-archive"
    static let sent = "fld-sent"
    static let drafts = "fld-drafts"
    static let trash = "fld-trash"

    // MARK: - World

    struct World: Sendable {
        let pool: DatabasePool
        let accountId: String
        let server: StatefulExchangeActionServer
        let provider: ExchangeProvider

        func folderId(_ path: String) -> String { "\(accountId):\(path)" }

        func account() throws -> Account {
            try #require(try pool.read { db in try Account.fetchOne(db, key: accountId) })
        }

        func folder(_ path: String) throws -> Folder {
            try #require(try pool.read { db in try Folder.fetchOne(db, key: folderId(path)) })
        }

        func cursor(_ path: String) throws -> OutlookFolderCursor? {
            OutlookFolderCursor(raw: try folder(path).changeCursor)
        }

        func row(_ messageId: String, in path: String) throws -> MessageHeader? {
            try pool.read { db in
                try MessageHeader.filter(Column("messageId") == messageId && Column("folderId") == folderId(path)).fetchOne(db)
            }
        }

        func rowIds(in path: String) throws -> Set<String> {
            try pool.read { db in
                Set(try MessageHeader.filter(Column("folderId") == folderId(path)).fetchAll(db).map(\.messageId))
            }
        }

        func recheck(_ path: String) throws -> [String] {
            FolderChangeState(raw: try folder(path).changeState).recheck
        }

        /// One read with a frozen clock at `now`: `requests` is the exact request
        /// allowance (nil: the foreground budget's). Each folder's changes are
        /// applied in its own transaction, and a new account part is stored.
        @discardableResult
        func read(
            scope: ChangeScope = .all, now: Date = Date(), requests: Int? = nil, expensive: Bool = false,
            reader: ExchangeProvider? = nil
        ) async throws -> ChangeSet {
            let account = try account()
            let folders = try await pool.read { db in
                try Folder.filter(Column("accountId") == accountId).fetchAll(db)
            }
            let synced = Set(SyncEngine().syncableFoldersInOrder(folders).map(\.id))
            var recheck: [String: [String]] = [:]
            for folder in folders {
                let ids = FolderChangeState(raw: folder.changeState).recheck
                if !ids.isEmpty { recheck[folder.id] = ids }
            }
            let deadline = requests.map { OutlookChangeReadingTests.deadline(requests: $0, from: now) }
                ?? now.addingTimeInterval(SyncConfig.changeReadBudgetSeconds)
            let context = ChangeContext(deadline: deadline, clock: { now }, isExpensiveNetwork: expensive, onProgress: { _ in })
            let request = ChangeRequest(
                folders: folders.map {
                    ChangeFolder(id: $0.id, path: $0.path, role: $0.role, cursor: $0.changeCursor,
                                 isSynced: synced.contains($0.id), heldSince: $0.oldestSyncedDate)
                },
                scope: scope, recheck: recheck, context: context,
                localRows: SyncEngineCatchUpRowReader(pool: AppDatabase.syncPool))
            let set = try #require(try await (reader ?? provider).fetchChanges(
                since: ChangeCursor(account: account.lastHistoryId), request: request))
            for changes in set.folders {
                _ = try await pool.write { db in try SyncEngine.applyFolderChanges(changes, db: db) }
            }
            if case .set(let value) = set.account {
                try await pool.write { db in
                    _ = try Account.filter(Column("id") == accountId).updateAll(db, Column("lastHistoryId").set(to: value))
                }
            }
            return set
        }

        /// Reads until every synced folder tracks (its first round done).
        func baselineAll(now: Date = Date()) async throws {
            for _ in 0..<10 {
                try await read(now: now)
                let phases = try [inbox, archive].map { try cursor($0)?.phase }
                if phases.allSatisfy({ $0 == .tracking }) { return }
            }
            Issue.record("precondition: the baselines completed")
        }

        var inbox: String { OutlookChangeReadingTests.inbox }
        var archive: String { OutlookChangeReadingTests.archive }

        /// One engine change pass (`SyncEngine.performDeltaSync`).
        @discardableResult
        func delta(inboxOnly: Bool = false, deadline: Date? = nil) async throws -> (succeeded: Bool, hadChanges: Bool) {
            try await SyncEngine().performDeltaSync(
                account: try account(), provider: provider, inboxOnly: inboxOnly, deadline: deadline)
        }

        /// One foreground pass with the full sync due.
        func foregroundPass() async throws {
            try await pool.write { db in
                _ = try Account.filter(Column("id") == accountId).updateAll(db,
                    Column("lastSyncedAt").set(to: nil as Date?),
                    Column("lastFullSyncAt").set(to: nil as Date?))
            }
            let engine = SyncEngine()
            await engine.register(
                accountId: accountId, provider: provider,
                workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
            _ = try await engine.sync(account: try account())
            await engine.remove(accountId: accountId)
        }

        /// A local row as a sync would have left it.
        func insertRow(_ messageId: String, in path: String, date: Date = OutlookChangeReadingTests.daysAgo(3),
                       isRead: Bool = false, isFlagged: Bool = false) throws {
            var header = MessageHeader(
                messageId: messageId, subject: "Held \(messageId)", from: "Fixture",
                fromAddress: "sender@example.com", to: "recipient@example.com", date: date,
                snippet: "held", folderId: folderId(path), accountId: accountId, folderPath: path,
                isInInbox: path == inbox, providerDate: date)
            header.rfc822MessageId = EmailFilter.normalizeMessageId("<\(messageId)@example.com>")
            header.isRead = isRead
            header.isFlagged = isFlagged
            header.headerComplete = true
            let toInsert = header
            try pool.write { db in try toInsert.insert(db) }
        }

        func setHeldSince(_ date: Date?, of path: String) throws {
            try pool.write { db in
                try db.execute(sql: "UPDATE folder SET oldestSyncedDate = ? WHERE id = ?", arguments: [date, folderId(path)])
            }
        }

        /// Message GETs by id (`/messages/{id}`), batched or not.
        func messageFetches() -> Int {
            server.batchWidths().reduce(0, +)
                + server.http.recordedCalls().filter {
                    $0.method == "GET" && $0.url.contains("/messages/") && !$0.url.contains("/messages/delta")
                        && !$0.url.contains("/mailFolders/")
                }.count
        }

        /// Ids sent in `$batch` items, in order.
        func batchedIds() -> [String] {
            server.http.recordedCalls().filter { $0.url == GraphAPI.batchURL }.flatMap { call -> [String] in
                guard let body = call.body,
                      let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let items = root["requests"] as? [[String: Any]] else { return [] }
                return items.compactMap { item in
                    (item["url"] as? String).flatMap { URL(string: "https://graph.microsoft.com/v1.0" + $0) }
                        .flatMap { StatefulExchangeActionServer.messageId(from: $0, move: false) }
                }
            }
        }

        func deltaPageRequests(_ path: String) -> Int {
            server.http.recordedCalls().filter { $0.url.contains("/mailFolders/\(path)/messages/delta") }.count
        }
    }

    static func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }

    /// A deadline giving exactly `requests` requests of allowance at `now`.
    static func deadline(requests: Int, from now: Date) -> Date {
        now.addingTimeInterval((Double(requests) + 0.5) / SyncConfig.graphChangeReadRequestsPerSecond)
    }

    static func seed(_ id: String, in folderId: String, daysAgo days: Double = 3, isRead: Bool = false,
                     isFlagged: Bool = false) -> StatefulExchangeActionServer.Seed {
        StatefulExchangeActionServer.Seed(
            rfc822MessageId: "\(id)@example.com", providerMessageId: id, folderId: folderId,
            isRead: isRead, isFlagged: isFlagged, receivedAt: daysAgo(days))
    }

    static func withWorld(
        seeds: [StatefulExchangeActionServer.Seed] = [], heldSince: Date? = daysAgo(30),
        _ body: (World) async throws -> Void
    ) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let accountId = "olc-\(UUID().uuidString.prefix(8).lowercased())"
        let server = StatefulExchangeActionServer(messages: seeds)
        server.addFolder(id: inbox, name: "Inbox", wellKnownName: "inbox")
        server.addFolder(id: archive, name: "Archive", wellKnownName: "archive")
        server.addFolder(id: sent, name: "Sent Items", wellKnownName: "sentitems")
        server.addFolder(id: drafts, name: "Drafts", wellKnownName: "drafts")
        server.addFolder(id: trash, name: "Deleted Items", wellKnownName: "deleteditems")
        defer {
            server.close()
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        var account = Account(emailAddress: "\(accountId)@example.com", displayName: "Outlook reader", provider: .outlook)
        account.id = accountId
        account.lastFullSyncAt = Date()
        account.lastSyncedAt = Date()
        let folders = [
            (inbox, "Inbox", FolderRole.inbox), (archive, "Archive", .archive), (sent, "Sent Items", .sent),
            (drafts, "Drafts", .drafts), (trash, "Deleted Items", .trash),
        ].map { path, name, role -> Folder in
            var folder = Folder(name: name, path: path, role: role, accountId: accountId)
            folder.oldestSyncedDate = heldSince
            return folder
        }
        let toInsert = account
        try await pool.write { db in
            try toInsert.insert(db)
            for folder in folders { try folder.insert(db) }
        }
        let world = World(pool: pool, accountId: accountId, server: server, provider: server.provider())
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        try await body(world)
        await UnreadCountManager.shared.awaitIdleForTesting()
    }

    // MARK: - J10: the state set for every folder but the Inbox

    @Test("A read or flag change on a held Archive message lands from the delta record, with no message fetch")
    func stateChangeLandsWithoutAFetch() async throws {
        try await Self.withWorld(seeds: [Self.seed("a-1", in: Self.archive), Self.seed("a-2", in: Self.archive)]) { w in
            try w.insertRow("a-1", in: w.archive)
            try w.insertRow("a-2", in: w.archive)
            try await w.baselineAll()
            #expect(w.messageFetches() == 0, "precondition: an in-step baseline fetches nothing")

            w.server.setReadFromOtherClient(providerMessageId: "a-1", isRead: true)
            w.server.setFlagFromOtherClient(providerMessageId: "a-2", isFlagged: true)
            try await w.read()

            #expect(try w.row("a-1", in: w.archive)?.isRead == true, "the read change landed")
            #expect(try w.row("a-2", in: w.archive)?.isFlagged == true, "the flag change landed")
            #expect(w.messageFetches() == 0, "a change to a held message needs no fetch")
        }
    }

    @Test("A message another client moves into the Archive gets its headers and appears, at any age")
    func movedInMessageAppears() async throws {
        try await Self.withWorld(seeds: [Self.seed("old-1", in: Self.inbox, daysAgo: 400)], heldSince: Self.daysAgo(30)) { w in
            try await w.baselineAll()
            let movedId = try #require(w.server.moveFromOtherClient(providerMessageId: "old-1", to: Self.archive))
            try await w.read()

            let row = try #require(try w.row(movedId, in: w.archive), "the moved-in message appears in the Archive")
            #expect(row.subject == "Stateful action message", "with its headers")
            #expect(w.batchedIds() == [movedId], "its headers were fetched once")
        }
    }

    @Test("A new Inbox message is inserted from its delta record, with no message fetch")
    func newInboxMessageNeedsNoFetch() async throws {
        try await Self.withWorld { w in
            try await w.baselineAll()
            w.server.deliver(Self.seed("new-1", in: Self.inbox, daysAgo: 0))
            try await w.read()
            #expect(try w.row("new-1", in: w.inbox) != nil)
            #expect(w.messageFetches() == 0)
        }
    }

    @Test("An in-step folder's baseline costs its pages only")
    func inStepBaselineCostsPagesOnly() async throws {
        let ids = (0..<250).map { String(format: "s-%03d", $0) }
        try await Self.withWorld(seeds: ids.map { Self.seed($0, in: Self.archive) }) { w in
            for id in ids { try w.insertRow(id, in: w.archive) }
            try await w.baselineAll()
            let pageSize = SyncConfig.graphChangeReadPageSize
            #expect(w.deltaPageRequests(Self.archive) == (ids.count + pageSize - 1) / pageSize)
            #expect(w.messageFetches() == 0)
        }
    }

    @Test("Baseline: an unknown message below the held range gets no fetch; one within it is fetched and inserted")
    func baselineFetchesOnlyWithinTheHeldRange() async throws {
        try await Self.withWorld(
            seeds: [Self.seed("old", in: Self.archive, daysAgo: 60), Self.seed("recent", in: Self.archive, daysAgo: 5)],
            heldSince: Self.daysAgo(30)
        ) { w in
            try await w.baselineAll()
            #expect(w.batchedIds() == ["recent"])
            #expect(try w.row("recent", in: w.archive) != nil)
            #expect(try w.row("old", in: w.archive) == nil, "older mail is the backfill's")
        }
    }

    @Test("A baseline with no held range inserts nothing and fetches nothing")
    func baselineWithNoHeldRangeInsertsNothing() async throws {
        try await Self.withWorld(seeds: [Self.seed("i-1", in: Self.inbox), Self.seed("a-1", in: Self.archive)], heldSince: nil) { w in
            try await w.baselineAll()
            #expect(try w.rowIds(in: w.inbox).isEmpty)
            #expect(try w.rowIds(in: w.archive).isEmpty)
            #expect(w.messageFetches() == 0)
        }
    }

    @Test("A read-state-only record for a message the folder does not hold is neither fetched nor inserted")
    func readOnlyRecordForUnknownMessage() async throws {
        try await Self.withWorld(seeds: [Self.seed("x-1", in: Self.archive, daysAgo: 60)]) { w in
            try await w.baselineAll()
            #expect(try w.row("x-1", in: w.archive) == nil, "precondition: below the held range, not inserted")
            w.server.setReadFromOtherClient(providerMessageId: "x-1", isRead: true)
            try await w.read()
            #expect(try w.row("x-1", in: w.archive) == nil)
            #expect(w.messageFetches() == 0)
        }
    }

    @Test("A header fetch that finds the message gone or in another folder inserts nothing, and the bookmark passes the page",
          arguments: ["gone", "elsewhere"])
    func goneOrElsewhereInsertsNothing(kind: String) async throws {
        try await Self.withWorld { w in
            try await w.baselineAll()
            w.server.deliver(Self.seed("m-1", in: Self.archive, daysAgo: 1))
            if kind == "gone" {
                w.server.answerBatchItem(providerMessageId: "m-1", status: 404, body: nil)
            } else {
                // The message as another client has just moved it to Sent.
                w.server.answerBatchItem(providerMessageId: "m-1", status: 200, body: """
                    {"id":"m-1","subject":"moved on","receivedDateTime":"\(Date().iso8601String())","isRead":false,
                     "hasAttachments":false,"internetMessageId":"<m-1@example.com>","parentFolderId":"\(Self.sent)"}
                    """)
            }
            let before = try w.cursor(w.archive)
            try await w.read()
            #expect(try w.row("m-1", in: w.archive) == nil)
            #expect(try w.cursor(w.archive)?.next != before?.next, "the page was passed")
            #expect(try w.recheck(w.archive).isEmpty)
        }
    }

    /// J10 (1): the bookmark never passes a page until the page's missing
    /// headers are in, also when the read budget ends inside the page; the next
    /// read fetches only what is still missing.
    @Test("The bookmark never passes a page until its missing headers are in, across a budget cut")
    func bookmarkWaitsForThePageHeaders() async throws {
        try await Self.withWorld { w in
            try await w.baselineAll()
            let ids = (0..<30).map { String(format: "in-%02d", $0) }
            for id in ids { w.server.deliver(Self.seed(id, in: Self.archive, daysAgo: 1)) }
            let tracked = try #require(try w.cursor(w.archive))
            let now = Date()
            // Allowance: the folder-list page, the Inbox's page, the Archive's
            // page, and one batch.
            try await w.read(now: now, requests: 3 + SyncConfig.graphBatchMaxRequests)
            #expect(try w.cursor(w.archive)?.next == tracked.next, "the cut page was not passed")
            #expect(try w.rowIds(in: w.archive).count == SyncConfig.graphBatchMaxRequests, "what was fetched landed")

            try await w.read(now: now.addingTimeInterval(60))
            #expect(try w.rowIds(in: w.archive) == Set(ids), "every message of the page landed")
            #expect(try w.cursor(w.archive)?.next != tracked.next, "and then the page was passed")
            let fetched = w.batchedIds()
            #expect(fetched.count == ids.count && Set(fetched) == Set(ids), "each header fetched once")
        }
    }

    /// J10 (5): a large burst of missing messages is fetched in batches charged
    /// their width, every read within its allowance, and none is dropped.
    @Test("A burst of moved-in messages is paced under the request allowance and none is dropped")
    func burstIsPacedAndKept() async throws {
        let ids = (0..<150).map { String(format: "b-%03d", $0) }
        try await Self.withWorld(seeds: ids.map { Self.seed($0, in: Self.inbox, daysAgo: 2) }) { w in
            for id in ids { try w.insertRow(id, in: w.inbox) }
            try await w.baselineAll()
            var moved: [String] = []
            for id in ids {
                moved.append(try #require(w.server.moveFromOtherClient(providerMessageId: id, to: Self.archive)))
            }
            let allowance = 41
            var now = Date()
            for _ in 0..<40 {
                let before = w.server.http.recordedCalls().count
                let widthsBefore = w.server.batchWidths().count
                try await w.read(now: now, requests: allowance)
                let calls = Array(w.server.http.recordedCalls().dropFirst(before))
                let widths = Array(w.server.batchWidths().dropFirst(widthsBefore))
                let pages = calls.filter { $0.url.contains("/delta") }.count
                #expect(pages + widths.reduce(0, +) <= allowance, "a read sends at most its allowance")
                #expect(widths.allSatisfy { $0 <= SyncConfig.graphBatchMaxRequests })
                if try w.rowIds(in: w.archive) == Set(moved) { break }
                now = now.addingTimeInterval(60)
            }
            #expect(try w.rowIds(in: w.archive) == Set(moved), "no moved-in message was dropped")
            #expect(try w.rowIds(in: w.inbox).isEmpty, "and each left the Inbox")
        }
    }

    // MARK: - J10 (4): the expensive-network wait

    @Test("A non-Inbox baseline waits on an expensive network for at most the bound, counted from first sight; the Inbox does not wait")
    func expensiveNetworkWaitIsBounded() async throws {
        try await Self.withWorld(seeds: [Self.seed("a-1", in: Self.archive), Self.seed("i-1", in: Self.inbox)]) { w in
            let start = Date()
            try await w.read(now: start, expensive: true)
            #expect(w.deltaPageRequests(Self.archive) == 0, "the Archive baseline waits")
            #expect(w.deltaPageRequests(Self.inbox) > 0, "the Inbox baseline does not")
            #expect(try w.cursor(w.archive)?.baselineSince == start, "first sight is stored with the folder")

            // A new provider (a relaunch) just before the bound: still waits.
            let bound = SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds
            try await w.read(now: start.addingTimeInterval(bound - 60), expensive: true, reader: w.server.provider())
            #expect(w.deltaPageRequests(Self.archive) == 0)

            try await w.read(now: start.addingTimeInterval(bound), expensive: true, reader: w.server.provider())
            #expect(w.deltaPageRequests(Self.archive) > 0, "past the bound it runs on any network")
            #expect(try w.row("a-1", in: w.archive) != nil)
        }
    }

    @Test("The Wi-Fi-only setting does not hold back a change read")
    func wifiOnlyIsIgnored() async throws {
        let defaults = UserDefaults.standard
        let key = await MainActor.run { SyncScheduler.wifiOnlyKey }
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(previous, forKey: key) }
        try await Self.withWorld(seeds: [Self.seed("a-1", in: Self.archive)]) { w in
            try await w.delta()
            #expect(w.deltaPageRequests(Self.archive) > 0)
            #expect(try w.row("a-1", in: w.archive) != nil)
        }
    }

    // MARK: - J8: the caller's deadline

    @Test("A pass whose turn leaves too little of the caller's deadline reads nothing, and the next pass lands the change")
    func tooLittleTimeReadsNothing() async throws {
        try await Self.withWorld { w in
            try await w.baselineAll()
            w.server.deliver(Self.seed("late-1", in: Self.inbox, daysAgo: 0))
            let before = w.server.http.recordedCalls().count
            let tooSoon = Date().addingTimeInterval(SyncConfig.changeReadRequestTimeoutSeconds + SyncConfig.changeReadApplyMarginSeconds - 1)
            _ = try await w.delta(inboxOnly: true, deadline: tooSoon)
            #expect(w.server.http.recordedCalls().count == before, "nothing was read")
            #expect(try w.row("late-1", in: w.inbox) == nil)

            try await w.delta(inboxOnly: true, deadline: Date().addingTimeInterval(SyncConfig.backgroundPerAccountTimeoutSeconds))
            #expect(try w.row("late-1", in: w.inbox) != nil, "the next pass lands the change")
        }
    }

    /// Whatever the turn wait, a pass either applies what it read before the
    /// caller's deadline or reads nothing: run as the caller runs it, under a
    /// timeout ending at the deadline, with slow pages.
    @Test("A pass applies what it read before the caller's deadline")
    func passAppliesBeforeTheCallerDeadline() async throws {
        let ids = (0..<600).map { String(format: "p-%03d", $0) }
        try await Self.withWorld(seeds: ids.map { Self.seed($0, in: Self.inbox, daysAgo: 1) }) { w in
            w.server.setDeltaPageLatency(1.5)
            let readSeconds = 2.0
            let window = readSeconds + SyncConfig.changeReadRequestTimeoutSeconds + SyncConfig.changeReadApplyMarginSeconds
            let deadline = Date().addingTimeInterval(window)
            let finished = try await withTimeout(seconds: window) {
                try await w.delta(inboxOnly: true, deadline: deadline)
                return true
            }
            #expect(finished)
            let pages = w.deltaPageRequests(Self.inbox)
            #expect(pages >= 1, "precondition: the pass read")
            #expect(try w.rowIds(in: w.inbox).count == min(ids.count, pages * SyncConfig.graphChangeReadPageSize),
                    "every page read was applied")
        }
    }

    // MARK: - Bookmarks and refusals

    @Test("A folder bookmark is discarded only when Graph refuses it",
          arguments: [(410, true), (400, true), (401, false), (403, false), (408, false), (429, false), (500, false), (503, false)])
    func bookmarkKeptUnlessRefused(status: Int, refuses: Bool) async throws {
        try await Self.withWorld { w in
            try await w.baselineAll()
            let tracked = try #require(try w.cursor(w.archive))
            w.server.refuseIssuedLinks(folderId: Self.archive, status: status)
            try await w.read(scope: .all)
            if refuses {
                #expect(try w.folder(w.archive).changeCursor == nil, "a refused bookmark is cleared")
            } else {
                #expect(try w.cursor(w.archive)?.next == tracked.next, "the bookmark survives \(status)")
            }
            #expect(try w.cursor(w.inbox)?.phase == .tracking, "another folder's bookmark survives")
        }
    }

    @Test("A refused folder untracks and lapses only that folder; the folder-list link and the other folders survive")
    func refusedFolderTouchesOnlyItself() async throws {
        try await Self.withWorld { w in
            try await w.delta()
            try await w.delta()
            try await w.pool.write { db in
                for path in [Self.inbox, Self.archive] {
                    try db.execute(sql: "UPDATE folder SET changeState = ?, catchUpState = '{}' WHERE id = ?",
                                   arguments: [FolderChangeState(tracking: true).encoded, w.folderId(path)])
                }
            }
            let link = try w.account().lastHistoryId
            #expect(OutlookAccountCursor(raw: link) != nil, "precondition: the account holds the folder-list link")
            w.server.refuseIssuedLinks(folderId: Self.archive)
            try await w.delta()
            #expect(try FolderChangeState(raw: w.folder(w.archive).changeState).tracking == false)
            #expect(try FolderChangeState(raw: w.folder(w.inbox).changeState).tracking == true)
            #expect(try w.folder(w.inbox).catchUpState == "{}", "no lapse for the Inbox")
            #expect(try w.folder(w.archive).catchUpState != "{}", "a lapse for the Archive")
            #expect(OutlookAccountCursor(raw: try w.account().lastHistoryId) != nil, "the folder-list link survives")
            #expect(try w.account().lastFullSyncAt == nil, "the full sync is due")
        }
    }

    @Test("A refused saved baseline continuation starts the baseline again in the same read")
    func refusedContinuationRestarts() async throws {
        let ids = (0..<250).map { String(format: "c-%03d", $0) }
        try await Self.withWorld(seeds: ids.map { Self.seed($0, in: Self.archive) }) { w in
            for id in ids { try w.insertRow(id, in: w.archive) }
            let now = Date()
            try await w.read(now: now, requests: 3)
            #expect(try w.cursor(w.archive)?.next != nil, "precondition: a baseline continuation is saved")
            w.server.refuseIssuedLinks(folderId: Self.archive)
            try await w.read(now: now)
            #expect(try w.cursor(w.archive)?.phase == .tracking, "the restarted baseline completed")
        }
    }

    @Test("A folder whose reads keep failing with a server error is started again after the lapse")
    func failingFolderLapses() async throws {
        try await Self.withWorld { w in
            try await w.baselineAll()
            let start = Date()
            w.server.failDeltaPages(Array(repeating: .status(500), count: 2))
            try await w.read(scope: .inboxOnly, now: start)
            #expect(try w.cursor(w.inbox)?.failingSince == start)
            try await w.read(scope: .inboxOnly, now: start.addingTimeInterval(SyncConfig.changeReadFailureLapseSeconds))
            #expect(try w.folder(w.inbox).changeCursor == nil, "the folder starts a new baseline")
        }
    }

    @Test("A message whose header fetch keeps failing with a server error holds its page until the lapse, then the folder starts again")
    func serverErrorOnAHeaderHoldsThePage() async throws {
        try await Self.withWorld { w in
            try await w.baselineAll()
            w.server.deliver(Self.seed("s-1", in: Self.archive, daysAgo: 1))
            w.server.answerBatchItem(providerMessageId: "s-1", status: 503, body: nil)
            let tracked = try #require(try w.cursor(w.archive))
            let start = Date()
            try await w.read(now: start)
            #expect(try w.cursor(w.archive)?.next == tracked.next, "the page is held")
            #expect(try w.recheck(w.archive).isEmpty, "and the message waits on the page, not the re-read list")
            try await w.read(now: start.addingTimeInterval(SyncConfig.changeReadFailureLapseSeconds))
            #expect(try w.folder(w.archive).changeCursor == nil)
            w.server.clearBatchItemAnswers()
            try await w.baselineAll(now: start.addingTimeInterval(SyncConfig.changeReadFailureLapseSeconds + 60))
            #expect(try w.row("s-1", in: w.archive) != nil, "it lands once the server answers")
        }
    }

    // MARK: - Re-read lists

    @Test("Re-read ids beyond the read budget stay listed; the rest are read")
    func rereadBeyondBudgetStaysListed() async throws {
        let ids = (0..<45).map { String(format: "r-%02d", $0) }
        try await Self.withWorld(seeds: ids.map { Self.seed($0, in: Self.archive, isRead: true) }) { w in
            for id in ids { try w.insertRow(id, in: w.archive) }
            try await w.baselineAll()
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                               arguments: [FolderChangeState(recheck: ids).encoded, w.folderId(Self.archive)])
            }
            // Allowance: the folder-list page, the Inbox's page, the Archive's
            // page, and one batch.
            try await w.read(now: Date(), requests: 3 + SyncConfig.graphBatchMaxRequests)
            let left = try w.recheck(w.archive)
            #expect(left.count == ids.count - SyncConfig.graphBatchMaxRequests, "the ids not read stay listed")
            #expect(Set(left).isSubset(of: Set(ids)))
        }
    }

    // MARK: - Engine entries

    @Test("An Outlook push pass reports success and records the poll")
    func inboxOnlyPassSucceeds() async throws {
        try await Self.withWorld { w in
            try await w.delta()
            let before = Date().addingTimeInterval(-3_600)
            try await w.pool.write { db in
                _ = try Account.filter(Column("id") == w.accountId).updateAll(db, Column("lastSyncedAt").set(to: before))
            }
            let engine = SyncEngine()
            await engine.register(
                accountId: w.accountId, provider: w.provider,
                workQueue: ProviderWorkQueue(provider: w.provider, maxConcurrency: 1))
            let outcome = try await engine.backgroundDeltaSync(account: try w.account(), inboxOnly: true)
            await engine.remove(accountId: w.accountId)
            #expect(outcome.reason != "noCursor", "an Outlook push pass is not taken for one with no bookmark")
            #expect(try w.account().lastSyncedAt.map { $0 > before } == true, "the poll is recorded")
        }
    }

    @Test("The first pass stores the folder-list link and keeps every hidden folder")
    func folderListKeepsHiddenFolders() async throws {
        try await Self.withWorld { w in
            w.server.addFolder(id: "fld-hidden", name: "Hidden", hidden: true)
            try await w.delta()
            #expect(OutlookAccountCursor(raw: try w.account().lastHistoryId) != nil)
            let stored = try await w.pool.read { db in
                Set(try Folder.filter(Column("accountId") == w.accountId).fetchAll(db).map(\.path))
            }
            #expect(stored.contains("fld-hidden"))

            // A rename (a known folder) and a quiet round keep it too.
            w.server.renameFolder(id: Self.archive, to: "Old mail")
            try await w.delta()
            try await w.delta()
            #expect(try w.folder(Self.archive).name == "Old mail")
            let hidden = try await w.pool.read { db in try Folder.fetchOne(db, key: w.folderId("fld-hidden")) }
            #expect(hidden != nil)
        }
    }

    @Test("A new folder runs the complete listing; a removed parent takes its sub-folders with it")
    func structuralChangesRunTheCompleteListing() async throws {
        try await Self.withWorld { w in
            try await w.delta()
            w.server.addFolder(id: "fld-parent", name: "Projects")
            w.server.addFolder(id: "fld-child", name: "Alpha", parentId: "fld-parent")
            try await w.delta()
            func stored() throws -> Set<String> {
                try w.pool.read { db in Set(try Folder.filter(Column("accountId") == w.accountId).fetchAll(db).map(\.path)) }
            }
            #expect(try stored().isSuperset(of: ["fld-parent", "fld-child"]))
            w.server.removeFolder(id: "fld-parent")
            try await w.delta()
            #expect(try stored().isDisjoint(with: ["fld-parent", "fld-child"]))
        }
    }

    @Test("After a Settings reset the next foreground pass shows the newest mail, and no folder stays tracked without a bookmark")
    func settingsResetShowsNewestMail() async throws {
        try await Self.withWorld(seeds: [Self.seed("before", in: Self.inbox, daysAgo: 1)]) { w in
            try await w.foregroundPass()
            try await w.foregroundPass()
            try await w.pool.write { db in
                try db.execute(sql: "DELETE FROM messageHeader WHERE accountId = ?", arguments: [w.accountId])
                try db.execute(sql: "UPDATE account SET lastFullSyncAt = NULL, lastHistoryId = NULL WHERE id = ?", arguments: [w.accountId])
                try db.execute(sql: "UPDATE folder SET oldestSyncedDate = NULL, changeState = NULL, changeCursor = NULL WHERE accountId = ?",
                               arguments: [w.accountId])
            }
            w.server.deliver(Self.seed("after", in: Self.inbox, daysAgo: 0))
            try await w.foregroundPass()
            #expect(try w.row("after", in: w.inbox) != nil, "the newest mail shows")
            #expect(try w.row("before", in: w.inbox) != nil)
            let folders = try await w.pool.read { db in try Folder.filter(Column("accountId") == w.accountId).fetchAll(db) }
            for folder in folders where FolderChangeState(raw: folder.changeState).tracking {
                #expect(folder.changeCursor != nil, "\(folder.path) is tracked without a bookmark")
            }
        }
    }

    @Test("The legacy category strip finds the Inbox in a process whose full sync skipped discovery")
    func inboxIdComesFromTheRequest() async throws {
        try await Self.withWorld(seeds: [Self.seed("tagged", in: Self.inbox)]) { w in
            let fresh = w.server.provider()
            try await w.read(scope: .inboxOnly, reader: fresh)
            #expect(await fresh.inboxFolderId == Self.inbox)
            #expect(await fresh.archiveFolderId == Self.archive)
            #expect(await fresh.deletedItemsFolderId == Self.trash)
        }
    }

    // MARK: - Partial records

    @Test("A partial record never overwrites a field it does not carry")
    func absentFieldKeepsStored() async throws {
        try await Self.withWorld(seeds: [Self.seed("p-1", in: Self.archive, isFlagged: true)]) { w in
            try w.insertRow("p-1", in: w.archive, isRead: false, isFlagged: true)
            try await w.baselineAll()
            w.server.setReadFromOtherClient(providerMessageId: "p-1", isRead: true)
            try await w.read()
            let row = try #require(try w.row("p-1", in: w.archive))
            #expect(row.isRead == true)
            #expect(row.isFlagged == true, "the read-only record carried no flag and left it")
            #expect(row.subject == "Held p-1", "nor any header field")
        }
    }
}
