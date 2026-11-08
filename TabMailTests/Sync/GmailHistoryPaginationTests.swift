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

    /// One page holding a `messagesAdded` record for each of `addedIds`.
    private static func historyPage(historyId: String, addedIds: [String], nextPageToken: String?) -> String {
        let token = nextPageToken.map { #", "nextPageToken": "\#($0)""# } ?? ""
        let records = addedIds.enumerated().map { index, id in
            #"{ "id": "\#(index)", "messagesAdded": [ { "message": { "id": "\#(id)", "labelIds": ["INBOX"] } } ] }"#
        }
        return #"{ "historyId": "\#(historyId)", "history": [ \#(records.joined(separator: ", ")) ]\#(token) }"#
    }

    /// The kinds of history record that make the delta fetch a message, with
    /// the shape Gmail gives each: `messagesAdded` items carry only the
    /// message, label records also name the labels added or removed.
    enum ChangeKind: String, Sendable, CaseIterable {
        case messagesAdded, labelsAdded, labelsRemoved

        func item(messageId: String) -> String {
            switch self {
            case .messagesAdded:
                return #"{ "message": { "id": "\#(messageId)", "labelIds": ["INBOX"] } }"#
            case .labelsAdded:
                return #"{ "message": { "id": "\#(messageId)", "labelIds": ["INBOX", "STARRED"] }, "labelIds": ["STARRED"] }"#
            case .labelsRemoved:
                return #"{ "message": { "id": "\#(messageId)", "labelIds": [] }, "labelIds": ["INBOX"] }"#
            }
        }
    }

    /// One page of `kind` records, each naming every message of one
    /// conversation, as a conversation-wide change on the web does.
    private static func changePage(
        historyId: String, kind: ChangeKind, conversations: [[String]], nextPageToken: String? = nil
    ) -> String {
        let token = nextPageToken.map { #", "nextPageToken": "\#($0)""# } ?? ""
        let records = conversations.enumerated().map { index, ids in
            let items = ids.map { kind.item(messageId: $0) }
            return #"{ "id": "\#(index)", "\#(kind.rawValue)": [ \#(items.joined(separator: ", ")) ] }"#
        }
        return #"{ "historyId": "\#(historyId)", "history": [ \#(records.joined(separator: ", ")) ]\#(token) }"#
    }

    /// One page of `messagesDeleted` records, one per id. The delta fetches
    /// nothing for a deleted message.
    private static func deletionPage(historyId: String, deletedIds: [String]) -> String {
        let records = deletedIds.enumerated().map { index, id in
            #"{ "id": "\#(index)", "messagesDeleted": [ { "message": { "id": "\#(id)", "labelIds": ["INBOX"] } } ] }"#
        }
        return #"{ "historyId": "\#(historyId)", "history": [ \#(records.joined(separator: ", ")) ] }"#
    }

    private static func messageJSON(id: String) -> String {
        """
        {
          "id": "\(id)",
          "threadId": "thread-\(id)",
          "labelIds": ["INBOX"],
          "snippet": "",
          "internalDate": "\(Int64(Date().timeIntervalSince1970 * 1000))",
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

    /// The request's query exactly as it went on the wire, still percent-encoded.
    private static func wireQuery(of request: FakeHTTP.Request) -> String {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
    }

    /// Detail GETs (`users.messages.get`) the provider issued in this scenario.
    private static func detailGETs(_ scenario: FakeHTTP.Scenario) -> Int {
        scenario.recordedCalls().filter { $0.method == "GET" && $0.url.contains("/messages/") }.count
    }

    private static func withAppDB(_ body: (DatabasePool) async throws -> Void) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        try await body(pool)
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

        // A token with characters a query string must encode.
        let secondPageToken = "page/2+next=yes"
        let tokensSeen = Mutex<[String?]>([])
        let secondPageQuery = Mutex<String?>(nil)
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }
        scenario.register(path: "/history", method: "GET") { request in
            let token = Self.pageToken(of: request)
            tokensSeen.withLock { $0.append(token) }
            if token == secondPageToken {
                secondPageQuery.withLock { $0 = Self.wireQuery(of: request) }
                // The mailbox moved on while paging: page 2 reports a newer id.
                return .json(raw: Self.historyPage(historyId: "1005", addedId: "on-page-2", nextPageToken: nil))
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
        #expect(try Self.cursor(pool: pool) == "1002",
                "the cursor must be the FIRST page's historyId: a later page's id can be past records no page returned")

        // Page 2 is the same query plus its token, encoded on the wire.
        let query = secondPageQuery.withLock { $0 } ?? ""
        let items = query.components(separatedBy: "&")
        #expect(items.contains("pageToken=page%2F2%2Bnext%3Dyes"), "page token not percent-encoded on the wire: \(query)")
        #expect(items.contains("startHistoryId=\(Self.startCursor)"), "page 2 lost startHistoryId: \(query)")
        #expect(items.contains("maxResults=\(GmailAPI.historyPageSize)"), "page 2 lost maxResults: \(query)")
        for type in ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"] {
            #expect(items.contains("historyTypes=\(type)"), "page 2 lost historyTypes=\(type): \(query)")
        }
    }

    /// A later page that fails leaves nothing applied and the cursor where it
    /// was, so the next delta reads the same history again: whether Gmail
    /// answers with an error status or the request itself fails on the way.
    @Test("A failure on a later history page applies nothing and keeps the cursor",
          arguments: ["server error", "transport error"])
    func laterPageFailureKeepsTheCursor(failure: String) async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let scenario = FakeHTTP.Scenario()
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET") { request in
                if Self.pageToken(of: request) == "page-2" {
                    return failure == "server error" ? .status(500) : .transportError(.networkConnectionLost)
                }
                return .json(raw: Self.historyPage(historyId: "1002", addedId: "on-page-1", nextPageToken: "page-2"))
            }
            scenario.register(path: "/messages/on-page-1", method: "GET", response: .json(raw: Self.messageJSON(id: "on-page-1")))
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            await #expect(throws: (any Error).self) {
                _ = try await SyncEngine().performDeltaSync(account: account, provider: provider)
            }
            #expect(try Self.cursor(pool: pool) == Self.startCursor, "the cursor moved past a page that was never read")
            #expect(try !Self.headerExists("on-page-1", pool: pool), "part of an unread history was applied")
            #expect(Self.detailGETs(scenario) == 0, "a history that was not read to its end fetched messages")
        }
    }

    /// A 404 on a later page is an expired history like a 404 on the first:
    /// the cursor is cleared for the full sync and nothing is applied.
    @Test("A 404 on a later history page clears the cursor and applies nothing")
    func laterPage404ClearsTheCursor() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let scenario = FakeHTTP.Scenario()
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET") { request in
                if Self.pageToken(of: request) == "page-2" { return .status(404) }
                return .json(raw: Self.historyPage(historyId: "1002", addedId: "on-page-1", nextPageToken: "page-2"))
            }
            scenario.register(path: "/messages/on-page-1", method: "GET", response: .json(raw: Self.messageJSON(id: "on-page-1")))
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(!outcome.succeeded, "an expired history must not count as synced")
            #expect(try Self.cursor(pool: pool) == nil, "the cursor must be cleared for a full sync")
            #expect(try !Self.headerExists("on-page-1", pool: pool), "part of an expired history was applied")
        }
    }

    /// THE WORK BOUND. The delta fetches every changed message, one GET at a
    /// time, before it saves them or moves its cursor, all under the
    /// per-account sync deadline. A delta bigger than that deadline can carry
    /// would time out before its cursor moves and fail identically on every
    /// poll, starving the full sync. So history
    /// over `GmailAPI.historyMaxChanges` records (counted across pages) issues
    /// no detail GET at all and clears the cursor for the full sync, and stops
    /// reading at the page that crosses the budget rather than reading the
    /// rest of the history first.
    @Test("History over the record budget fetches no message and hands over to the full sync")
    func historyOverTheRecordBudgetFetchesNothing() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let perPage = GmailAPI.historyMaxChanges / 2 + 1
            let firstPage = (0..<perPage).map { "budget-a\($0)" }
            let secondPage = (0..<perPage).map { "budget-b\($0)" }
            let tokensSeen = Mutex<[String?]>([])
            let scenario = FakeHTTP.Scenario()
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET") { request in
                let token = Self.pageToken(of: request)
                tokensSeen.withLock { $0.append(token) }
                switch token {
                case nil:
                    return .json(raw: Self.historyPage(historyId: "1002", addedIds: firstPage, nextPageToken: "page-2"))
                case "page-2":
                    return .json(raw: Self.historyPage(historyId: "1002", addedIds: secondPage, nextPageToken: "page-3"))
                default:
                    return .json(raw: Self.historyPage(historyId: "1002", addedIds: [], nextPageToken: nil))
                }
            }
            for id in firstPage + secondPage {
                scenario.register(path: "/messages/\(id)", method: "GET", response: .json(raw: Self.messageJSON(id: id)))
            }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(Self.detailGETs(scenario) == 0,
                    "an over-budget delta committed to \(Self.detailGETs(scenario)) message GETs")
            #expect(!outcome.succeeded, "an over-budget delta must hand over to the full sync")
            #expect(try Self.cursor(pool: pool) == nil, "the cursor must be cleared for a full sync")
            #expect(tokensSeen.withLock { $0 } == [nil, "page-2"],
                    "reading must stop at the page that crosses the budget, read \(tokensSeen.withLock { $0 })")
        }
    }

    /// One history record can name many messages: a conversation-wide archive,
    /// label change or a batch of new mail names every message in it, and the
    /// delta fetches each of them. So the budget counts the distinct messages
    /// the delta would fetch, of every kind that makes it fetch one, across
    /// every page read: a delta naming exactly `GmailAPI.historyMaxChanges`
    /// messages is applied, one naming more fetches nothing and hands over to
    /// the full sync, even when no single page names more than the budget.
    struct MessageBudgetCase: Sendable, CustomTestStringConvertible {
        let kind: ChangeKind
        let pages: Int
        var testDescription: String { "\(kind.rawValue) over \(pages) page(s)" }
    }

    static let messageBudgetCases: [MessageBudgetCase] =
        ChangeKind.allCases.map { MessageBudgetCase(kind: $0, pages: 1) }
        + [MessageBudgetCase(kind: .labelsRemoved, pages: 2), MessageBudgetCase(kind: .messagesAdded, pages: 2)]

    @Test("The budget counts the messages a delta would fetch, not only its records",
          arguments: GmailHistoryPaginationTests.messageBudgetCases, [0, 1])
    func budgetCountsChangedMessages(budgetCase: MessageBudgetCase, overBudget: Int) async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let messageCount = GmailAPI.historyMaxChanges + overBudget
            let perConversation = 4
            let ids = (0..<messageCount).map { "conv-msg-\($0)" }
            let conversations = stride(from: 0, to: ids.count, by: perConversation).map {
                Array(ids[$0..<min($0 + perConversation, ids.count)])
            }
            try #require(conversations.count <= GmailAPI.historyMaxChanges, "fixture: within the record budget")
            // Split the conversations across the pages, each page under the budget on its own.
            let perPage = (conversations.count + budgetCase.pages - 1) / budgetCase.pages
            let pageChunks = stride(from: 0, to: conversations.count, by: perPage).map {
                Array(conversations[$0..<min($0 + perPage, conversations.count)])
            }
            try #require(pageChunks.count == budgetCase.pages, "fixture: \(budgetCase.pages) page(s)")
            for chunk in pageChunks {
                try #require(chunk.joined().count <= GmailAPI.historyMaxChanges || budgetCase.pages == 1,
                             "fixture: no single page crosses the budget")
            }
            let scenario = FakeHTTP.Scenario()
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET") { request in
                let index = Self.pageToken(of: request).flatMap { Int($0.dropFirst("page-".count)) } ?? 0
                let next = index + 1 < pageChunks.count ? "page-\(index + 1)" : nil
                return .json(raw: Self.changePage(
                    historyId: "1002", kind: budgetCase.kind, conversations: pageChunks[index], nextPageToken: next))
            }
            for id in ids {
                scenario.register(path: "/messages/\(id)", method: "GET", response: .json(raw: Self.messageJSON(id: id)))
            }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            if overBudget > 0 {
                #expect(Self.detailGETs(scenario) == 0,
                        "\(conversations.count) records naming \(messageCount) messages committed to \(Self.detailGETs(scenario)) GETs")
                #expect(!outcome.succeeded, "an over-budget delta must hand over to the full sync")
                #expect(try Self.cursor(pool: pool) == nil, "the cursor must be cleared for a full sync")
            } else {
                #expect(Self.detailGETs(scenario) == messageCount, "a delta at the budget fetches every message it names")
                #expect(outcome.succeeded, "a delta at the budget is applied")
                #expect(try Self.cursor(pool: pool) == "1002", "a delta at the budget moves the cursor")
            }
        }
    }

    /// The record budget binds on its own: a history of many records that
    /// name few messages to fetch (a bulk delete, or the same messages
    /// relabelled over and over) is applied at exactly
    /// `GmailAPI.historyMaxChanges` records and handed over to the full sync
    /// past it.
    @Test("The record budget binds even when the records name few messages to fetch", arguments: [0, 1])
    func recordBudgetBindsOnItsOwn(overBudget: Int) async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let recordCount = GmailAPI.historyMaxChanges + overBudget
            let scenario = FakeHTTP.Scenario()
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET", response: .json(raw: Self.deletionPage(
                historyId: "1002", deletedIds: (0..<recordCount).map { "deleted-\($0)" })))
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(Self.detailGETs(scenario) == 0, "a deleted message is never fetched")
            if overBudget > 0 {
                #expect(!outcome.succeeded, "\(recordCount) records must hand over to the full sync")
                #expect(try Self.cursor(pool: pool) == nil, "the cursor must be cleared for a full sync")
            } else {
                #expect(outcome.succeeded, "a delta of exactly the record budget is applied")
                #expect(try Self.cursor(pool: pool) == "1002", "a delta at the record budget moves the cursor")
            }
        }
    }

    /// Gmail leaves `history` out of a page when nothing changed, which is
    /// what most polls get. That is an empty delta, not a malformed page: the
    /// pass succeeds, fetches nothing and moves the cursor to the page's id.
    @Test("A history page with no changes is an empty delta that moves the cursor")
    func pageWithoutHistoryIsAnEmptyDelta() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let scenario = FakeHTTP.Scenario()
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET", response: .json(raw: #"{ "historyId": "1009" }"#))
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(outcome.succeeded, "a quiet poll must count as synced")
            #expect(Self.detailGETs(scenario) == 0)
            #expect(try Self.cursor(pool: pool) == "1009", "a quiet poll moves the cursor to Gmail's current id")
        }
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

        // One record per page: the page limit, not the record budget, stops this loop.
        try #require(GmailAPI.historyMaxPages <= GmailAPI.historyMaxChanges, "fixture: page limit must bind first")
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
    }
}
