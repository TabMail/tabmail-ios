/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import os
@testable import TabMail

/// The Gmail and Exchange backfill page walk (`SyncEngine.runBackfill`): how
/// long a page is held while some of its messages keep failing with a failure
/// that is not about that message alone, and what the backfill worker does
/// after a call that only held a page.
///
/// The properties asserted: a held page is never passed over inside the hold
/// bound, wherever the bound is counted from, and is passed over once the
/// bound has run out, so the folder completes. The bound is counted from the
/// first hold of the page the saved token names now: it survives a relaunch,
/// and it starts again when the token has moved (the walk advanced, a reset,
/// a refused token's restart). A token another writer saved meanwhile is kept.
/// A page-list request that gets no answer is retried after the connection
/// backoff in the same call. A call that only held a page did no work, and the
/// worker waits its idle delay before the next one. Each call has a deadline
/// only so a regression ends with failed assertions instead of hanging.
@Suite("Backfill page walk — the hold bound", .serialized, .processGlobalState)
struct BackfillPageWalkHoldBoundTests {
    private typealias F = BackfillPageWalkFixture

    private static var bound: TimeInterval { SyncConfig.backfillPageHoldSeconds }
    /// A step well inside the bound, so "just before" and "just after" it are
    /// unambiguous whatever the bound is configured to.
    private static var margin: TimeInterval { bound / 60 }

    private static func setHoldClock(_ now: Date?) {
        SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = now }
    }

    private static func gmailInbox(
        _ accountId: String, pool: DatabasePool
    ) throws -> (StatefulGmailActionServer, Account) {
        let server = StatefulGmailActionServer(messages: [
            F.gmailSeed("m1", label: "INBOX", daysAgo: 1),
            F.gmailSeed("m2", label: "INBOX", daysAgo: 2),
            F.gmailSeed("m3", label: "INBOX", daysAgo: 3),
        ])
        server.servePagedListings(pageSize: F.pageSize)
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        return (server, account)
    }

    private static func isComplete(_ accountId: String, _ path: String, pool: DatabasePool) throws -> Bool {
        try #require(try F.folder(accountId, path, pool: pool)).backfillComplete
    }

    // MARK: - Which failure decides a page

    /// Page 1's two messages both fail: m2 with an answer about that message
    /// (a 400), m1 with a 503 the server answers later. The per-message
    /// failure reaches the walk first; the page is still held, because one
    /// failure that is not about its message alone holds the page whatever
    /// arrived before it.
    @Test("Gmail: a page whose per-message failure arrives first is still held")
    func gmailPerMessageFailureFirstStillHolds() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        Self.setHoldClock(nil)
        let accountId = "gm-per-message-first"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectUnclassified400OnGet(providerMessageId: "m2")
        server.injectGetFailure(providerMessageId: "m1", .status(503), answeredAfter: 0.5)
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(server.unclassified400OnGetServedCount() == 1)
        #expect(server.getFailuresServedCount(providerMessageId: "m1") == 1)
        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool), "a held page was passed over")
        #expect(F.gmailListPageTokens(server, label: "INBOX") == [nil],
                "the walk moved past the held page: \(F.gmailListPageTokens(server, label: "INBOX"))")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool).isEmpty)
    }

    /// The page's last message fails because the token refresh a 401 triggers
    /// fails (what a refused or unreachable sign-in looks like to the walk).
    /// That is not an answer about the message, so the page is held inside
    /// the bound; once sign-in works again the next call loads the message.
    @Test("Gmail: a message whose token refresh fails mid-page holds its page")
    func gmailFailedTokenRefreshMidPageHolds() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { Self.setHoldClock(nil) }
        let accountId = "gm-refresh-fails"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectGetFailure(providerMessageId: "m3", .status(401))
        server.failTokenRefresh(true)
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())
        let start = Date()

        Self.setHoldClock(start)
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        Self.setHoldClock(start.addingTimeInterval(Self.bound - Self.margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(server.failedTokenRefreshCount() == 2, "refused refreshes: \(server.failedTokenRefreshCount())")
        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool), "a page whose token refresh failed was passed over")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2"])

        server.clearGetFailures()
        server.failTokenRefresh(false)
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try Self.isComplete(accountId, "INBOX", pool: pool))
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2", "m3"])
    }

    // MARK: - Where the bound is counted from

    /// A fresh engine on the same database (a relaunch) counts the bound from
    /// the page's first hold, not from its own first sight of the page: a
    /// relaunch inside the bound still holds, a relaunch past it passes the
    /// message over and completes the folder.
    @Test("Gmail: a relaunch counts the bound from the page's first hold")
    func gmailRelaunchCountsTheBoundFromTheFirstHold() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { Self.setHoldClock(nil) }
        let accountId = "gm-relaunch"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectGetFailure(providerMessageId: "m3", .status(503))
        let start = Date()

        Self.setHoldClock(start)
        let first = await F.registeredEngine(accountId: accountId, provider: server.provider())
        _ = await first.runBackfill(account: account, deadline: F.deadline())

        Self.setHoldClock(start.addingTimeInterval(Self.bound - Self.margin))
        let second = await F.registeredEngine(accountId: accountId, provider: server.provider())
        _ = await second.runBackfill(account: account, deadline: F.deadline())
        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool), "a relaunch inside the bound passed the page over")

        Self.setHoldClock(start.addingTimeInterval(Self.bound + Self.margin))
        let third = await F.registeredEngine(accountId: accountId, provider: server.provider())
        _ = await third.runBackfill(account: account, deadline: F.deadline())

        #expect(try Self.isComplete(accountId, "INBOX", pool: pool), "a relaunch restarted the bound: the page stayed held past it")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2"])
        #expect(server.getFailuresServedCount(providerMessageId: "m3") == 3)
    }

    /// Page 1 is held, then loads just before the bound and the walk moves
    /// on; page 2 is then held. Page 2's bound starts at its own first hold:
    /// it is still held after page 1's bound would have run out, and is passed
    /// over only after its own.
    @Test("Gmail: a page held after the walk advanced starts a fresh bound")
    func gmailPageHeldAfterAdvanceStartsAFreshBound() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { Self.setHoldClock(nil) }
        let accountId = "gm-fresh-after-advance"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectGetFailure(providerMessageId: "m1", .status(503))
        server.injectGetFailure(providerMessageId: "m3", .status(503))
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())
        let start = Date()
        let secondHold = start.addingTimeInterval(Self.bound - Self.margin)

        Self.setHoldClock(start)
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        server.clearGetFailure(providerMessageId: "m1")
        Self.setHoldClock(secondHold)
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2"], "precondition: page 1 loaded and the walk moved on")

        Self.setHoldClock(start.addingTimeInterval(Self.bound + Self.margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool), "page 2 inherited page 1's bound and was passed over early")

        Self.setHoldClock(secondHold.addingTimeInterval(Self.bound + Self.margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        #expect(try Self.isComplete(accountId, "INBOX", pool: pool), "page 2 stayed held past its own bound")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2"])
    }

    /// The first page is held, then a crawl reset (`resetCrawlState`) starts
    /// the walk over. The page held after the reset starts a fresh bound, even
    /// though it is the same first page with the same (absent) token.
    @Test("Gmail: a page held again after a crawl reset starts a fresh bound")
    func gmailPageHeldAfterResetStartsAFreshBound() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { Self.setHoldClock(nil) }
        let ccBccKey = "ccBccBackfillDone"
        let savedCcBcc = UserDefaults.standard.object(forKey: ccBccKey)
        defer { UserDefaults.standard.set(savedCcBcc, forKey: ccBccKey) }
        let accountId = "gm-fresh-after-reset"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectGetFailure(providerMessageId: "m1", .status(503))
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())
        let start = Date()
        let secondHold = start.addingTimeInterval(Self.bound - Self.margin)

        Self.setHoldClock(start)
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        await engine.resetCrawlState()
        Self.setHoldClock(secondHold)
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        Self.setHoldClock(start.addingTimeInterval(Self.bound + Self.margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool), "the page held after the reset kept the old bound and was passed over early")
        #expect(F.gmailListPageTokens(server, label: "INBOX").allSatisfy { $0 == nil },
                "the walk moved past the held first page: \(F.gmailListPageTokens(server, label: "INBOX"))")

        Self.setHoldClock(secondHold.addingTimeInterval(Self.bound + Self.margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        #expect(try Self.isComplete(accountId, "INBOX", pool: pool), "the page stayed held past its fresh bound")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m2", "m3"])
    }

    /// Page 2 is held, then its saved token is refused and the walk restarts
    /// from the top, where page 1 (one of its messages lost locally) is held.
    /// That hold starts a fresh bound: it is still held after page 2's bound
    /// would have run out.
    @Test("Gmail: a page held after a refused token's restart starts a fresh bound")
    func gmailPageHeldAfterRestartStartsAFreshBound() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { Self.setHoldClock(nil) }
        let accountId = "gm-fresh-after-restart"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectGetFailure(providerMessageId: "m3", .status(503))
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())
        let start = Date()
        let secondHold = start.addingTimeInterval(Self.bound - Self.margin)

        Self.setHoldClock(start)
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        #expect(try F.folder(accountId, "INBOX", pool: pool)?.backfillPageToken != nil, "precondition: page 2 is held by its saved token")

        server.expireIssuedPageTokens()
        server.injectGetFailure(providerMessageId: "m1", .status(503))
        try await pool.write { db in
            _ = try MessageHeader
                .filter(Column("folderId") == "\(accountId):INBOX" && Column("messageId") == "m1")
                .deleteAll(db)
        }
        Self.setHoldClock(secondHold)
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        #expect(server.rejectedPageTokenCount() == 1, "precondition: the saved token was refused once")

        Self.setHoldClock(start.addingTimeInterval(Self.bound + Self.margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        #expect(try !Self.isComplete(accountId, "INBOX", pool: pool), "the page held after the restart kept the old bound")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m2"], "the restarted page was passed over early")

        server.clearGetFailures()
        Self.setHoldClock(secondHold.addingTimeInterval(Self.bound + Self.margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        #expect(try Self.isComplete(accountId, "INBOX", pool: pool))
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2", "m3"])
    }

    // MARK: - Another writer, and a page list with no answer

    /// While the walk's request with its saved token is in flight, another
    /// writer saves a newer token and hold time for the folder; then the
    /// provider refuses the walk's token. The walk's restart drops only the
    /// token it listed with: the newer token and its hold time are kept.
    @Test("Gmail: a refused token's restart keeps a token another writer saved meanwhile")
    func gmailRestartKeepsAConcurrentlySavedToken() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { Self.setHoldClock(nil) }
        let accountId = "gm-sibling-token"
        let folderId = "\(accountId):INBOX"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectGetFailure(providerMessageId: "m3", .status(503))
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())
        let start = Date()
        Self.setHoldClock(start)
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        let listedToken = try #require(try F.folder(accountId, "INBOX", pool: pool)?.backfillPageToken)

        let siblingToken = "sibling-page-token"
        let siblingHeldSince = Date(timeIntervalSince1970: (start.timeIntervalSince1970 - Self.margin).rounded())
        let siblingWrote = OSAllocatedUnfairLock(initialState: false)
        server.onRejectedPageToken { refused in
            guard refused == listedToken, !siblingWrote.withLock({ $0 }) else { return }
            // Another writer moves the folder on while this request is in flight.
            try? pool.write { db in
                _ = try Folder.filter(Column("id") == folderId).updateAll(db,
                    Column("backfillPageToken").set(to: siblingToken),
                    Column("backfillPageHeldSince").set(to: siblingHeldSince))
            }
            siblingWrote.withLock { $0 = true }
        }
        server.expireIssuedPageTokens()
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(siblingWrote.withLock { $0 }, "precondition: the other writer ran")
        let inbox = try #require(try F.folder(accountId, "INBOX", pool: pool))
        #expect(inbox.backfillPageToken == siblingToken, "the restart dropped a token another writer saved: \(String(describing: inbox.backfillPageToken))")
        #expect(inbox.backfillPageHeldSince.map { abs($0.timeIntervalSince(siblingHeldSince)) < 1 } == true,
                "the restart dropped the other writer's hold time: \(String(describing: inbox.backfillPageHeldSince))")
        #expect(!inbox.backfillComplete)
    }

    /// Page 2's listing gets no answer once (the connection drops). That is
    /// not a reason to skip the folder: the walk backs off and lists the same
    /// page again with the same token in the same call, and completes.
    @Test("Gmail: a page list with no answer backs off and is listed again in the same call")
    func gmailPageListWithNoAnswerBacksOffAndRetries() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        Self.setHoldClock(nil)
        let accountId = "gm-list-no-answer"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.failListings(transport: .networkConnectionLost, label: "INBOX", onlyWithPageToken: true, times: 1)
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(server.listingFailuresServedCount() == 1)
        let tokens = F.gmailListPageTokens(server, label: "INBOX")
        #expect(tokens.count == 3, "listing requests: \(tokens)")
        guard tokens.count == 3 else { return }
        #expect(tokens[0] == nil)
        #expect(tokens[1] != nil && tokens[2] == tokens[1], "page 2 was not listed again with the same token: \(tokens)")
        #expect(try Self.isComplete(accountId, "INBOX", pool: pool), "a page list with no answer skipped the folder for the call")
        #expect(try F.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2", "m3"])
    }

    // MARK: - Exchange

    /// Exchange: the last page's only message answers 500. The page is held
    /// inside the bound (each later call lists only it), then passed over, and
    /// the folder completes without it.
    @Test("Exchange: a message failing with a 5xx holds its page until the bound, then is passed over")
    func exchangeServerErrorHoldsUntilTheBound() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        defer { Self.setHoldClock(nil) }
        let accountId = "ex-hold-bound"
        let folderId = "inbox-folder"
        let server = StatefulExchangeActionServer(messages: (1...3).map {
            F.exchangeSeed("x\($0)", folderId: folderId, daysAgo: Double($0))
        })
        defer { server.close() }
        server.servePagedListings(pageSize: F.pageSize)
        server.injectGetFailure(providerMessageId: "x3", status: 500)
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .outlook, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: folderId, role: .inbox, pool: pool)
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())
        let start = Date()

        Self.setHoldClock(start)
        _ = await engine.runBackfill(account: account, deadline: F.deadline())
        Self.setHoldClock(start.addingTimeInterval(Self.bound - Self.margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try !Self.isComplete(accountId, folderId, pool: pool), "the page was passed over inside the hold bound")
        #expect(try F.messageIds(accountId, folderId, pool: pool) == ["x1", "x2"])
        #expect(F.graphListRequests(server, folderId: folderId) == 3,
                "the later call re-listed more than the held page: \(F.graphListRequests(server, folderId: folderId))")

        Self.setHoldClock(start.addingTimeInterval(Self.bound + Self.margin))
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try Self.isComplete(accountId, folderId, pool: pool), "the page stayed held past the bound")
        #expect(try F.messageIds(accountId, folderId, pool: pool) == ["x1", "x2"])
        #expect(server.getFailuresServedCount(providerMessageId: "x3") == 3)
    }

    /// Exchange: the last page's only message answers 404 (gone). That is an
    /// answer about the message: the walk moves past it and completes the
    /// folder in the same call, having asked for it once.
    @Test("Exchange: a message answering 404 is passed over and the folder completes")
    func exchangeNotFoundAdvancesAndCompletes() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        Self.setHoldClock(nil)
        let accountId = "ex-per-message"
        let folderId = "inbox-folder"
        let server = StatefulExchangeActionServer(messages: (1...3).map {
            F.exchangeSeed("x\($0)", folderId: folderId, daysAgo: Double($0))
        })
        defer { server.close() }
        server.servePagedListings(pageSize: F.pageSize)
        server.injectGetFailure(providerMessageId: "x3", status: 404)
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .outlook, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: folderId, role: .inbox, pool: pool)
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(try Self.isComplete(accountId, folderId, pool: pool), "a per-message failure kept the folder from completing")
        #expect(try F.messageIds(accountId, folderId, pool: pool) == ["x1", "x2"])
        #expect(server.getFailuresServedCount(providerMessageId: "x3") == 1)
        #expect(F.graphListRequests(server, folderId: folderId) == 2)
    }

    // MARK: - The worker's pace after a call that only held a page

    /// A call that lists a held page again and loads nothing new did no work,
    /// and after a call that did no work the backfill worker waits the
    /// profile's idle delay, not the delay it uses between productive calls.
    @Test("A call that only holds a page did no work, and the worker then waits the idle delay")
    func heldPageCallIsPacedByTheIdleDelay() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        Self.setHoldClock(nil)
        let accountId = "gm-held-pace"
        let (server, account) = try Self.gmailInbox(accountId, pool: pool)
        defer { server.close() }
        server.injectGetFailure(providerMessageId: "m1", .status(503))
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        let firstDidWork = await engine.runBackfill(account: account, deadline: F.deadline())
        let secondDidWork = await engine.runBackfill(account: account, deadline: F.deadline())

        #expect(firstDidWork, "precondition: the first call loaded m2")
        #expect(!secondDidWork, "a call that only held a page again reported work")
        for profile in [BackfillProfile.low, .normal, .aggressive, .turbo] {
            #expect(SyncEngine.backfillInterCycleDelay(didWork: false, profile: profile) == profile.interCycleIdleDelay,
                    "after a call with no work (\(profile))")
            #expect(SyncEngine.backfillInterCycleDelay(didWork: true, profile: profile) == profile.interCycleActiveDelay,
                    "after a call with work (\(profile))")
        }
    }
}
