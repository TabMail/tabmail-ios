/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Gmail's `users.history.list` is paginated: "If you receive no
/// `nextPageToken` in the response, there are no updates to retrieve", and a
/// page holds at most 500 records. THE PROPERTY: delta sync applies every
/// history record after the stored cursor before the cursor moves, and the
/// cursor never moves past a page that was not read.
///
/// These drive production `SyncEngine.performDeltaSync` end to end (`FakeHTTP`,
/// a real `GmailProvider` and a real `DatabasePool`), so they hold for the
/// whole path: `GmailAPI.historyList` → `GmailProvider.fetchHistory` →
/// `gmailDeltaSync`'s cursor write.
@Suite("Gmail delta sync reads every history page before its cursor moves", .serialized, .processGlobalState)
struct GmailHistoryPaginationTests {
    private static let accountId = "gmail-history-pages"
    private static let startCursor = "1000"

    private static func makeAccount(pool: DatabasePool) throws -> Account {
        var account = Account(
            emailAddress: "\(accountId)@example.com", displayName: "History pages", provider: .gmail)
        account.id = accountId
        account.lastHistoryId = startCursor
        let toInsert = account
        try pool.write { db in
            try toInsert.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId).insert(db)
        }
        return account
    }

    private static func historyPage(historyId: String, addedId: String, nextPageToken: String?) -> String {
        let token = nextPageToken.map { #", "nextPageToken": "\#($0)""# } ?? ""
        return """
        {
          "historyId": "\(historyId)",
          "history": [
            { "id": "\(historyId)", "messagesAdded": [ { "message": { "id": "\(addedId)", "labelIds": ["INBOX"] } } ] }
          ]\(token)
        }
        """
    }

    private static func messageJSON(id: String) -> String {
        """
        {
          "id": "\(id)",
          "threadId": "thread-\(id)",
          "labelIds": ["INBOX"],
          "snippet": "",
          "internalDate": "1700000000000",
          "payload": {
            "mimeType": "text/plain",
            "headers": [
              { "name": "Subject", "value": "history \(id)" },
              { "name": "From", "value": "Sender <sender@example.com>" },
              { "name": "To", "value": "recipient@example.com" },
              { "name": "Message-Id", "value": "<\(id)@example.com>" }
            ]
          }
        }
        """
    }

    private static func pageToken(of request: FakeHTTP.Request) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "pageToken" })?.value
    }

    private static func headerExists(_ messageId: String, pool: DatabasePool) throws -> Bool {
        let id = MessageIdentity.headerId(accountId: accountId, folderPath: "INBOX", messageId: messageId)
        return try pool.read { db in try MessageHeader.fetchOne(db, key: id) != nil }
    }

    private static func cursor(pool: DatabasePool) throws -> String? {
        try pool.read { db in try Account.fetchOne(db, key: accountId) }?.lastHistoryId
    }

    /// RED before the fix: only page 1 was read, its message was inserted, and
    /// the cursor moved on, so page 2's message was never seen again.
    @Test("A message on the second history page is applied before the cursor moves")
    func everyPageIsApplied() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let account = try Self.makeAccount(pool: pool)

        // A token with characters a query string must encode, so the test also
        // proves the token reaches Gmail intact.
        let secondPageToken = "page/2+next=yes"
        let tokensSeen = Mutex<[String?]>([])
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }
        scenario.register(path: "/history", method: "GET") { request in
            let token = Self.pageToken(of: request)
            tokensSeen.withLock { $0.append(token) }
            if token == secondPageToken {
                return .json(raw: Self.historyPage(historyId: "1002", addedId: "on-page-2", nextPageToken: nil))
            }
            return .json(raw: Self.historyPage(historyId: "1002", addedId: "on-page-1", nextPageToken: secondPageToken))
        }
        scenario.register(path: "/messages/on-page-1", method: "GET", response: .json(raw: Self.messageJSON(id: "on-page-1")))
        scenario.register(path: "/messages/on-page-2", method: "GET", response: .json(raw: Self.messageJSON(id: "on-page-2")))
        let provider = GmailProvider(
            userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

        let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

        #expect(outcome.succeeded, "precondition: the delta pass must have run")
        #expect(tokensSeen.withLock { $0 } == [nil, secondPageToken],
                "expected page 1 and then page 2 by its token: \(tokensSeen.withLock { $0 })")
        #expect(try Self.headerExists("on-page-1", pool: pool))
        #expect(try Self.headerExists("on-page-2", pool: pool),
                "the second page's message was skipped")
        #expect(try Self.cursor(pool: pool) == "1002", "the cursor did not move after both pages were applied")
    }

    /// The page loop is bounded. History longer than `GmailAPI.historyMaxPages`
    /// pages is handled like an expired history: the cursor is cleared so the
    /// next sync is a full sync, never moved past the pages that were not read.
    @Test("History longer than the page limit clears the cursor rather than moving it past unread pages")
    func historyBeyondThePageLimitFallsBackToFullSync() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let account = try Self.makeAccount(pool: pool)

        let pagesServed = Mutex(0)
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }
        scenario.register(path: "/history", method: "GET") { _ in
            let page = pagesServed.withLock { count -> Int in
                count += 1
                return count
            }
            return .json(raw: Self.historyPage(
                historyId: "\(2000 + page)", addedId: "endless-\(page)", nextPageToken: "token-\(page)"))
        }
        let provider = GmailProvider(
            userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

        let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

        #expect(!outcome.succeeded, "a history that was not read to its end must not count as synced")
        #expect(pagesServed.withLock { $0 } == GmailAPI.historyMaxPages, "the page loop is not bounded")
        #expect(try Self.cursor(pool: pool) == nil,
                "the cursor must be cleared for a full sync, never moved past unread pages")
        #expect(try !Self.headerExists("endless-1", pool: pool),
                "a history that was not read to its end must not be applied in part")
    }
}
