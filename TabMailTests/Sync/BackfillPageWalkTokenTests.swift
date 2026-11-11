/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The Gmail and Exchange backfill page walk (`SyncEngine.runBackfill`)
/// against the stateful provider fakes, on a saved page token the provider
/// refuses with a `400`, which used to keep the walk re-listing one folder for
/// the whole call.
///
/// Each test asserts a bounded number of listing requests and where the folder
/// ends up (complete, or left incomplete for the next call); the test with a
/// second folder also asserts that folder is still walked. Each call is given a
/// deadline only so a regression ends at the deadline with failed assertions
/// instead of hanging the suite; a passing walk finishes far inside it.
/// Failures other than a refused token are in `BackfillPageWalkFailureTests`.
@Suite("Backfill page walk — rejected page tokens", .serialized, .processGlobalState)
struct BackfillPageWalkTokenTests {
    private typealias F = BackfillPageWalkFixture

    /// A token the fake never handed out: what a saved token looks like once
    /// the provider has dropped it.
    private static let staleGmailToken = "stale-page-token"

    private static func deadline() -> Date { F.deadline() }
    private static var pageSize: Int { F.pageSize }
    private static func daysAgo(_ days: Double) -> Date { F.daysAgo(days) }
    private static func gmailSeed(_ id: String, label: String, daysAgo days: Double) -> StatefulGmailActionServer.Seed {
        F.gmailSeed(id, label: label, daysAgo: days)
    }
    private static func registeredEngine(accountId: String, provider: any EmailProvider) async -> SyncEngine {
        await F.registeredEngine(accountId: accountId, provider: provider)
    }
    private static func setSavedToken(_ token: String, accountId: String, path: String, pool: DatabasePool) throws {
        try F.setSavedToken(token, accountId: accountId, path: path, pool: pool)
    }
    private static func folder(_ accountId: String, _ path: String, pool: DatabasePool) throws -> Folder {
        try #require(try F.folder(accountId, path, pool: pool))
    }
    private static func messageIds(_ accountId: String, _ path: String, pool: DatabasePool) throws -> Set<String> {
        try F.messageIds(accountId, path, pool: pool)
    }
    private static func gmailListRequests(_ server: StatefulGmailActionServer, label: String) -> Int {
        F.gmailListRequests(server, label: label)
    }
    private static func graphListRequests(_ server: StatefulExchangeActionServer, folderId: String) -> Int {
        F.graphListRequests(server, folderId: folderId)
    }

    // MARK: - A saved page token the provider rejects

    /// The saved token is refused once; the walk drops it, starts the folder
    /// over from the top and completes it in the same call. Three listing
    /// requests: the refused one and the two pages.
    @Test("Gmail: a rejected saved page token restarts the folder once and the walk completes")
    func gmailRejectedTokenRestartsAndCompletes() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "gm-token-restart"
        let server = StatefulGmailActionServer(messages: [
            Self.gmailSeed("m1", label: "INBOX", daysAgo: 1),
            Self.gmailSeed("m2", label: "INBOX", daysAgo: 2),
            Self.gmailSeed("m3", label: "INBOX", daysAgo: 3),
        ])
        defer { server.close() }
        server.servePagedListings(pageSize: Self.pageSize)
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try Self.setSavedToken(Self.staleGmailToken, accountId: accountId, path: "INBOX", pool: pool)
        let engine = await Self.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: Self.deadline())

        let inbox = try Self.folder(accountId, "INBOX", pool: pool)
        #expect(inbox.backfillComplete, "the folder never completed after its saved token was refused")
        #expect(inbox.backfillPageToken == nil)
        #expect(try Self.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2", "m3"])
        #expect(server.rejectedPageTokenCount() == 1, "refused token requests: \(server.rejectedPageTokenCount())")
        #expect(Self.gmailListRequests(server, label: "INBOX") == 3,
                "listing requests: \(Self.gmailListRequests(server, label: "INBOX"))")
    }

    /// The provider refuses every token, so the token the restart itself
    /// saved is refused too. That second refusal ends the folder's walk for
    /// this call: a bounded number of requests, the folder left incomplete,
    /// and the folder behind it (Sent) still walked to completion.
    @Test("Gmail: a second rejection in the same call stops the folder and the folders behind it are walked")
    func gmailSecondRejectionStopsTheFolderWithoutStarvingOthers() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "gm-token-twice"
        let server = StatefulGmailActionServer(messages: [
            Self.gmailSeed("m1", label: "INBOX", daysAgo: 1),
            Self.gmailSeed("m2", label: "INBOX", daysAgo: 2),
            Self.gmailSeed("m3", label: "INBOX", daysAgo: 3),
            Self.gmailSeed("s1", label: "SENT", daysAgo: 4),
        ])
        defer { server.close() }
        server.servePagedListings(pageSize: Self.pageSize)
        server.rejectEveryPageToken(true)
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "SENT", role: .sent, pool: pool)
        try Self.setSavedToken(Self.staleGmailToken, accountId: accountId, path: "INBOX", pool: pool)
        let engine = await Self.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: Self.deadline())

        // The refused saved token, the first page, the refused token that page saved.
        #expect(Self.gmailListRequests(server, label: "INBOX") == 3,
                "INBOX listing requests: \(Self.gmailListRequests(server, label: "INBOX"))")
        #expect(server.rejectedPageTokenCount() == 2, "refused token requests: \(server.rejectedPageTokenCount())")
        let inbox = try Self.folder(accountId, "INBOX", pool: pool)
        #expect(!inbox.backfillComplete, "a folder whose tokens are refused was marked complete")
        #expect(try Self.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2"])
        let sent = try Self.folder(accountId, "SENT", pool: pool)
        #expect(sent.backfillComplete, "the folder behind the rejected one was never walked")
        #expect(try Self.messageIds(accountId, "SENT", pool: pool) == ["s1"])
    }

    /// The once-per-folder bound lives for one call only. After a call that
    /// spent its restart, the provider expires the token that call saved; the
    /// next call may start the folder over again, and completes it.
    @Test("Gmail: the restart bound resets on the next runBackfill call")
    func gmailRestartBoundResetsOnTheNextCall() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "gm-token-next-call"
        let server = StatefulGmailActionServer(messages: [
            Self.gmailSeed("m1", label: "INBOX", daysAgo: 1),
            Self.gmailSeed("m2", label: "INBOX", daysAgo: 2),
            Self.gmailSeed("m3", label: "INBOX", daysAgo: 3),
        ])
        defer { server.close() }
        server.servePagedListings(pageSize: Self.pageSize)
        server.rejectEveryPageToken(true)
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try Self.setSavedToken(Self.staleGmailToken, accountId: accountId, path: "INBOX", pool: pool)
        let engine = await Self.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: Self.deadline())
        let afterFirst = try Self.folder(accountId, "INBOX", pool: pool)
        #expect(!afterFirst.backfillComplete)
        #expect(afterFirst.backfillPageToken != nil, "precondition: the first call left a saved token")
        #expect(server.rejectedPageTokenCount() == 2)

        // Tokens are accepted again, but the one the first call saved has expired.
        server.rejectEveryPageToken(false)
        server.expireIssuedPageTokens()
        _ = await engine.runBackfill(account: account, deadline: Self.deadline())

        let inbox = try Self.folder(accountId, "INBOX", pool: pool)
        #expect(inbox.backfillComplete, "the second call did not start the folder over after its saved token was refused")
        #expect(try Self.messageIds(accountId, "INBOX", pool: pool) == ["m1", "m2", "m3"])
        #expect(server.rejectedPageTokenCount() == 3, "refused token requests: \(server.rejectedPageTokenCount())")
    }

    /// Exchange walks the same loop with an absolute `@odata.nextLink` as its
    /// saved token.
    @Test("Exchange: a rejected saved nextLink restarts the folder once and the walk completes")
    func exchangeRejectedTokenRestartsAndCompletes() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "ex-token-restart"
        let folderId = "inbox-folder"
        let server = StatefulExchangeActionServer(messages: (1...3).map { n in
            StatefulExchangeActionServer.Seed(
                rfc822MessageId: "x\(n)@example.com", providerMessageId: "x\(n)", folderId: folderId,
                receivedAt: Self.daysAgo(Double(n)))
        })
        defer { server.close() }
        server.servePagedListings(pageSize: Self.pageSize)
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .outlook, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: folderId, role: .inbox, pool: pool)
        try Self.setSavedToken(
            "https://graph.microsoft.com/v1.0/me/mailFolders/\(folderId)/messages?$skiptoken=stale-skip-token",
            accountId: accountId, path: folderId, pool: pool)
        let engine = await Self.registeredEngine(accountId: accountId, provider: server.provider())

        _ = await engine.runBackfill(account: account, deadline: Self.deadline())

        let inbox = try Self.folder(accountId, folderId, pool: pool)
        #expect(inbox.backfillComplete, "the folder never completed after its saved nextLink was refused")
        #expect(try Self.messageIds(accountId, folderId, pool: pool) == ["x1", "x2", "x3"])
        #expect(server.rejectedSkipTokenCount() == 1, "refused nextLink requests: \(server.rejectedSkipTokenCount())")
        #expect(Self.graphListRequests(server, folderId: folderId) == 3,
                "listing requests: \(Self.graphListRequests(server, folderId: folderId))")
    }
}
