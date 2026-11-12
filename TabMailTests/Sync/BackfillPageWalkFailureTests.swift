/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The Gmail and Exchange backfill page walk (`SyncEngine.runBackfill`) when a
/// page-list request fails, or some of a page's messages fail to load.
///
/// The properties asserted, per test: the requests a call makes are bounded;
/// a folder is never completed while a message it could still load is
/// missing; a message whose failure is not about that message alone is never
/// passed over inside the hold bound; a page that is held costs one listing on
/// a later call, not a re-list from the top; and the folder completes once
/// the failure clears, or past the bound, or (for a failure about one
/// message) at once without it. The bound across token moves, relaunches and
/// Exchange is in `BackfillPageWalkHoldBoundTests`.
/// Each call has a deadline only so a regression ends with failed assertions
/// instead of hanging the suite.
@Suite("Backfill page walk — page-list failures and held pages", .serialized, .processGlobalState)
struct BackfillPageWalkFailureTests {
    private typealias F = BackfillPageWalkFixture

    private static func setHoldClock(_ now: Date?) {
        SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = now }
    }

    private static func gmailInbox(
        _ accountId: String, pool: DatabasePool, extraSent: Bool = false
    ) throws -> (StatefulGmailActionServer, Account) {
        var seeds = [
            F.gmailSeed("m1", label: "INBOX", daysAgo: 1),
            F.gmailSeed("m2", label: "INBOX", daysAgo: 2),
            F.gmailSeed("m3", label: "INBOX", daysAgo: 3),
        ]
        if extraSent { seeds.append(F.gmailSeed("s1", label: "SENT", daysAgo: 4)) }
        let server = StatefulGmailActionServer(messages: seeds)
        server.servePagedListings(pageSize: F.pageSize)
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        if extraSent {
            try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "SENT", role: .sent, pool: pool)
        }
        return (server, account)
    }

    private static func isComplete(_ accountId: String, _ path: String, pool: DatabasePool) throws -> Bool {
        try #require(try F.folder(accountId, path, pool: pool)).backfillComplete
    }

    // MARK: - What a walked page writes

    /// The page walk's insert tail: every loaded message gets its row; a message
    /// served with a body has it written to search, and its row gets the snippet
    /// taken from that body and `bodyComplete`; a message served with no body gets
    /// its row and neither. The same tail inserts the catch-up's direct load
    /// (ADR-IOS-107), so this pins what both write.
    @Test("Gmail: a walked page's messages are inserted, and a fetched body sets the snippet and bodyComplete")
    func gmailWalkedPageWritesBodiesAndSnippets() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "gm-walk-bodies"
        let body = "Quarterly planning notes for the walked page"
        let server = StatefulGmailActionServer(messages: [
            StatefulGmailActionServer.Seed(
                rfc822MessageId: "b1@example.com", providerMessageId: "b1", labels: ["INBOX"],
                internalDate: F.daysAgo(1), bodyText: body),
            F.gmailSeed("b2", label: "INBOX", daysAgo: 2),
        ])
        defer { server.close() }
        server.servePagedListings(pageSize: F.pageSize)
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        let rows = try await pool.read { db in
            try MessageHeader.filter(Column("folderId") == "\(accountId):INBOX").fetchAll(db)
        }
        let byId = Dictionary(rows.map { ($0.messageId, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(Set(byId.keys) == ["b1", "b2"], "rows: \(byId.keys.sorted())")
        let withBody = try #require(byId["b1"])
        #expect(withBody.bodyComplete, "the fetched body was written to search")
        #expect(withBody.snippet.contains("Quarterly planning notes"), "the snippet comes from the body: \(withBody.snippet)")
        let withoutBody = try #require(byId["b2"])
        #expect(!withoutBody.bodyComplete && withoutBody.snippet.isEmpty, "no body: no snippet, not complete")
    }

    private static func headerInfo(_ id: String) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: id, rfc822MessageId: "\(id)@example.com", inReplyTo: nil, references: [],
            threadId: nil, subject: "chunk \(id)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            cc: "", bcc: "", replyTo: nil,
            date: F.daysAgo(1), snippet: "chunk",
            isRead: true, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil)
    }

    /// Make every insert of a message header with `messageId` fail, as a write
    /// that throws inside the insert's transaction does.
    private static func failInserts(of messageId: String, pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER test_failInsert BEFORE INSERT ON messageHeader
                WHEN NEW.messageId = '\(messageId)'
                BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END
                """)
        }
    }

    /// The same id twice in one batch is the same message (a provider id names
    /// one message): the insert tail gives it one row, and its neighbours in the
    /// same write chunk land too.
    @Test("A duplicate id in one insert chunk is skipped as the same message; its neighbours land")
    func duplicateIdInAChunkKeepsItsNeighbours() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "gm-chunk-duplicate"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        let folder = try #require(try F.folder(accountId, "INBOX", pool: pool))
        let engine = SyncEngine()

        _ = await engine.insertFetchedBackfillMessages(
            ["d1", "d2", "d2", "d3"].map(Self.headerInfo), bodies: [:], folder: folder)

        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["d1", "d2", "d3"])
    }

    /// A page whose messages loaded but whose insert failed (the write
    /// transaction threw, so its chunk rolled back) keeps its page token: the
    /// folder is not walked on past messages that have no row, and it is not
    /// listed again in the same call. Once the write succeeds, the next call
    /// lists that page again and the folder completes with every message.
    @Test("Gmail: a page whose insert fails keeps its page token; the next call loads it")
    func gmailFailedInsertKeepsThePageToken() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        Self.setHoldClock(nil)
        let accountId = "gm-insert-fails"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        try Self.failInserts(of: "m1", pool: pool)
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool), "the folder completed past messages that have no row")
        #expect(try F.folder(accountId, "INBOX", pool: pool)?.backfillPageToken == nil, "the page token moved past messages that have no row")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool).isEmpty, "precondition: the first page's insert failed")
        #expect(F.gmailListPageTokens(server, label: "INBOX") == [nil],
                "the folder is listed once in the call: \(F.gmailListPageTokens(server, label: "INBOX"))")

        try await pool.write { db in try db.execute(sql: "DROP TRIGGER test_failInsert") }
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try Self.isComplete(accountId, "INBOX", pool: pool))
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2", "m3"])
    }

    // MARK: - A page-list request that fails

    /// Page 2's request, which carries the token page 1 saved, fails once with
    /// a status that is not a token refusal. The walk does not count it as a
    /// refused token and does not re-list page 1: it lists page 2 again with
    /// the same token (on a later call) and completes.
    @Test("Gmail: a tokened page list failing once with a non-400 is listed again with the same token", arguments: [404, 500])
    func gmailTokenedListFailingOnceIsListedAgain(status: Int) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "gm-list-once-\(status)"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.failListings(status: status, label: "INBOX", onlyWithPageToken: true, times: 1)
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(server.rejectedPageTokenCount() == 0, "refused token requests: \(server.rejectedPageTokenCount())")
        #expect(server.listingFailuresServedCount() == 1)
        let tokens = F.gmailListPageTokens(server, label: "INBOX")
        #expect(tokens.count == 3, "listing requests: \(tokens)")
        guard tokens.count == 3 else { return }
        #expect(tokens[0] == nil, "page 1 is listed without a token")
        #expect(tokens[1] != nil && tokens[2] == tokens[1], "page 2 is listed again with the same token: \(tokens)")
        #expect(try Self.isComplete(accountId, "INBOX", pool: pool))
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2", "m3"])
    }

    /// Every INBOX listing fails (a 400 with no token, or a 5xx). The call
    /// lists INBOX once, leaves it incomplete and still walks Sent; once the
    /// failure clears, the next call completes INBOX.
    @Test("Gmail: a failing page list skips the folder for the call and the folders behind it run", arguments: [400, 500])
    func gmailFailingPageListSkipsTheFolderForTheCall(status: Int) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "gm-list-fails-\(status)"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool, extraSent: true)
        defer { server.close() }
        server.failListings(status: status, label: "INBOX")
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(F.gmailListRequests(server, label: "INBOX") == 1,
                "INBOX listing requests: \(F.gmailListRequests(server, label: "INBOX"))")
        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool))
        #expect(try Self.isComplete(accountId, "SENT", pool: pool), "the folder behind the failing one was never walked")
        #expect(try F.messageIds(accountId, "SENT", pool: pool) == ["s1"])

        server.clearListingFailures()
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try Self.isComplete(accountId, "INBOX", pool: pool))
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2", "m3"])
    }

    /// Exchange: the `@odata.nextLink` request fails with a 5xx. The call
    /// stops the folder after that one request, and the next call completes it.
    @Test("Exchange: a tokened page list failing with a non-400 is bounded and skipped for the call")
    func exchangeTokenedListFailureIsBoundedAndSkipped() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "ex-list-fails"
        let folderId = "inbox-folder"
        let server = StatefulExchangeActionServer(messages: (1...3).map {
            F.exchangeSeed("x\($0)", folderId: folderId, daysAgo: Double($0))
        })
        defer { server.close() }
        server.servePagedListings(pageSize: F.pageSize)
        server.failListings(status: 500, onlyWithSkipToken: true)
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .outlook, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: folderId, role: .inbox, pool: pool)
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(F.graphListRequests(server, folderId: folderId) == 2,
                "listing requests: \(F.graphListRequests(server, folderId: folderId))")
        #expect(server.listingFailuresServedCount() == 1)
        #expect(try !Self.isComplete(accountId, folderId, pool: pool))
        #expect(try F.messageIds(accountId, folderId, pool: pool) == ["x1", "x2"])

        server.clearListingFailures()
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(F.graphListRequests(server, folderId: folderId) == 3)
        #expect(try Self.isComplete(accountId, folderId, pool: pool))
        #expect(try F.messageIds(accountId, folderId, pool: pool) == ["x1", "x2", "x3"])
    }

    // MARK: - A page whose messages fail to load

    /// The first page's newest message answers 503. The page is held: the
    /// walk does not move on to page 2, so the folder cannot complete without
    /// that message. Once the server recovers, the next call loads it.
    @Test("Gmail: a middle page whose missing message fails transiently is held until it loads")
    func gmailMiddlePageTransientFailureIsHeld() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        Self.setHoldClock(nil)
        let accountId = "gm-middle-hold"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectGetFailure(providerMessageId: "m1", .status(503))
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool), "the folder completed without a message that failed transiently")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m2"])
        #expect(F.gmailListPageTokens(server, label: "INBOX") == [nil, nil],
                "the walk moved past the held page: \(F.gmailListPageTokens(server, label: "INBOX"))")
        #expect(server.getFailuresServedCount(providerMessageId: "m1") == 2)

        server.clearGetFailures()
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try Self.isComplete(accountId, "INBOX", pool: pool))
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2", "m3"])
    }

    /// The last page's only message answers 503, and Sent sits behind INBOX.
    /// The first call lists each INBOX page once, asks for the failing message
    /// once, leaves INBOX incomplete and completes Sent. Once the server
    /// recovers, the next call costs ONE listing (the held last page, by its
    /// saved token), not a re-list from page 1.
    @Test("Gmail: a last page that fails transiently costs one listing on the next call")
    func gmailLastPageTransientFailureCostsOneListingNextCall() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        Self.setHoldClock(nil)
        let accountId = "gm-last-page-hold"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool, extraSent: true)
        defer { server.close() }
        server.injectGetFailure(providerMessageId: "m3", .status(503))
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(F.gmailListRequests(server, label: "INBOX") == 2,
                "listing requests: \(F.gmailListRequests(server, label: "INBOX"))")
        #expect(server.getFailuresServedCount(providerMessageId: "m3") == 1,
                "failed fetches of the last page: \(server.getFailuresServedCount(providerMessageId: "m3"))")
        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool), "a folder whose last page failed was marked complete")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2"])
        #expect(try Self.isComplete(accountId, "SENT", pool: pool), "the folder behind INBOX was not walked in the first call")
        #expect(try F.messageIds(accountId, "SENT", pool: pool) == ["s1"])

        server.clearGetFailures()
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        let tokens = F.gmailListPageTokens(server, label: "INBOX")
        #expect(tokens.count == 3, "the next call re-listed more than the held page: \(tokens)")
        guard tokens.count == 3 else { return }
        #expect(tokens[2] != nil && tokens[2] == tokens[1], "the held page was not listed by its saved token: \(tokens)")
        #expect(try Self.isComplete(accountId, "INBOX", pool: pool))
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2", "m3"])
    }

    /// The last page's only message fails with an answer about that message
    /// (a 400 on its GET). The walk moves past it and completes the folder in
    /// the same call, without it, having asked for it once.
    @Test("Gmail: a message that fails per message is passed over and the folder completes")
    func gmailPerMessageFailureAdvancesAndCompletes() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        Self.setHoldClock(nil)
        let accountId = "gm-per-message"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectUnclassified400OnGet(providerMessageId: "m3")
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try Self.isComplete(accountId, "INBOX", pool: pool), "a per-message failure kept the folder from completing")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2"])
        #expect(server.unclassified400OnGetServedCount() == 1)
        #expect(F.gmailListRequests(server, label: "INBOX") == 2)
    }

    /// One message on the page answers 503 and the other fails per message:
    /// the stricter kind decides, so the page is held and the walk does not
    /// move on. When the 503 clears, the per-message failure is passed over
    /// and the folder completes without that one message.
    @Test("Gmail: a page with a transient and a per-message failure is held")
    func gmailMixedPageIsHeld() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        Self.setHoldClock(nil)
        let accountId = "gm-mixed-page"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectGetFailure(providerMessageId: "m1", .status(503))
        server.injectUnclassified400OnGet(providerMessageId: "m2")
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool), "a page with a transient failure was passed over")
        #expect(F.gmailListPageTokens(server, label: "INBOX") == [nil],
                "the walk moved past the held page: \(F.gmailListPageTokens(server, label: "INBOX"))")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool).isEmpty)

        server.clearGetFailures()
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try Self.isComplete(accountId, "INBOX", pool: pool))
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m3"])
    }

    /// The last page's only message answers 503 for good. The page is held
    /// while the hold is younger than the bound, then the walk passes the
    /// message over and the folder completes without it.
    @Test("Gmail: a message failing transiently for good holds its page until the bound, then is passed over")
    func gmailTransientFailureHoldsUntilTheBound() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { Self.setHoldClock(nil) }
        let accountId = "gm-hold-bound"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectGetFailure(providerMessageId: "m3", .status(503))
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())
        let start = Date()
        let bound = SyncConfig.backfillPageHoldSeconds
        let margin = bound / 60

        Self.setHoldClock(start)
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        Self.setHoldClock(start.addingTimeInterval(bound - margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool), "the page was passed over inside the hold bound")
        #expect(server.getFailuresServedCount(providerMessageId: "m3") == 2)

        Self.setHoldClock(start.addingTimeInterval(bound + margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try Self.isComplete(accountId, "INBOX", pool: pool), "the page stayed held past the bound")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2"])
        #expect(server.getFailuresServedCount(providerMessageId: "m3") == 3)
        let tokens = F.gmailListPageTokens(server, label: "INBOX")
        #expect(tokens.count == 4 && tokens.dropFirst().allSatisfy { $0 != nil && $0 == tokens[1] },
                "each later call lists only the held page: \(tokens)")
    }

    /// The last page's only message gets no answer at all, call after call
    /// (offline for that request). That is a hold like any other failure that
    /// is not about the message alone: the page is held while the hold is
    /// younger than the bound, each later call costs one listing of the held
    /// page, and past the bound the message is passed over and the folder
    /// completes without it.
    @Test("Gmail: a message that keeps getting no answer holds its page until the bound, then is passed over")
    func gmailRecurringNoAnswerHoldsUntilTheBound() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { Self.setHoldClock(nil) }
        let accountId = "gm-no-answer"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectGetFailure(providerMessageId: "m3", .transport(.notConnectedToInternet))
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())
        let start = Date()
        let bound = SyncConfig.backfillPageHoldSeconds
        let margin = bound / 60

        Self.setHoldClock(start)
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        Self.setHoldClock(start.addingTimeInterval(bound - margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool), "a message with no answer was passed over inside the hold bound")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2"])
        let held = F.gmailListPageTokens(server, label: "INBOX")
        #expect(held.count == 3, "the later call re-listed more than the held page: \(held)")
        guard held.count == 3 else { return }
        #expect(held[2] != nil && held[2] == held[1], "the held page was not listed by its saved token: \(held)")

        Self.setHoldClock(start.addingTimeInterval(bound + margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try Self.isComplete(accountId, "INBOX", pool: pool), "a message with no answer held its page past the bound")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2"])
        #expect(server.getFailuresServedCount(providerMessageId: "m3") == 3)
    }

    // MARK: - The one classification rule

    /// The classification is one rule over error kind and status, the same
    /// whichever provider threw. Only an answer about the one message is
    /// per-message: a 4xx other than 401, 403 and 429, an answer that did not
    /// decode, and an answer the provider could not read as a message (no
    /// header, no error). Everything else holds the page, an error the rule
    /// does not name included.
    @Test("A failed fetch is classified by error kind and status alone")
    func failureKindsFollowOneRule() {
        typealias Kind = SyncEngine.BackfillFetchFailureKind
        func status(_ code: Int) -> Error { ProviderError.networkError(underlying: HTTPError.networkError(statusCode: code)) }
        let cases: [(String, Error?, Kind)] = [
            ("offline", URLError(.notConnectedToInternet), .hold),
            ("connection lost", URLError(.networkConnectionLost), .hold),
            ("timed out", URLError(.timedOut), .hold),
            ("cancelled", CancellationError(), .hold),
            ("500", status(500), .hold),
            ("503", status(503), .hold),
            ("429", status(429), .hold),
            ("403", status(403), .hold),
            ("403 status-coded NSError", ProviderError.networkError(underlying: NSError(domain: "Provider", code: 403)), .hold),
            ("401", status(401), .hold),
            ("token refresh failed", AuthError.refreshFailed(underlying: "the refresh token was refused"), .hold),
            ("unclassified provider error", ProviderError.invalidURL("not a message URL"), .hold),
            ("unclassified error", NSError(domain: "Unclassified", code: 7), .hold),
            ("400", status(400), .perMessage),
            ("404", status(404), .perMessage),
            ("409", status(409), .perMessage),
            ("410", status(410), .perMessage),
            ("404 status-coded NSError", ProviderError.networkError(underlying: NSError(domain: "Provider", code: 404)), .perMessage),
            ("undecodable answer", DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")), .perMessage),
            ("no header, no error", nil, .perMessage),
        ]
        for (name, error, expected) in cases {
            #expect(SyncEngine.backfillFetchFailureKind(error) == expected, "\(name)")
        }
        #expect(Kind.hold > Kind.perMessage)
    }
}
