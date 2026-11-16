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
/// history record after the stored cursor before the cursor moves past it,
/// and the cursor never moves past a record that was not read. A pass that
/// stops early (its read budget spent, or `GmailAPI.historyMaxPages` read)
/// stores the id of the last record it took, and the next pass resumes there
/// (#491).
///
/// These drive production `SyncEngine.performDeltaSync` end to end (`FakeHTTP`,
/// a real `GmailProvider` and a real `DatabasePool`), so they hold for the
/// whole path: `GmailAPI.historyPage` → `GmailProvider.readHistory` →
/// Gmail's change reader → the engine's bookmark write.
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
    private static func deletionPage(historyId: String, deletedIds: [String], nextPageToken: String? = nil) -> String {
        let token = nextPageToken.map { #", "nextPageToken": "\#($0)""# } ?? ""
        let records = deletedIds.enumerated().map { index, id in
            #"{ "id": "\#(index)", "messagesDeleted": [ { "message": { "id": "\#(id)", "labelIds": ["INBOX"] } } ] }"#
        }
        return #"{ "historyId": "\#(historyId)", "history": [ \#(records.joined(separator: ", ")) ]\#(token) }"#
    }

    /// One page of records with the given ids, each adding the message of the
    /// same name (`added-<id>`).
    private static func recordPage(historyId: String, recordIds: [String], nextPageToken: String?) -> String {
        let token = nextPageToken.map { #", "nextPageToken": "\#($0)""# } ?? ""
        let records = recordIds.map { id in
            #"{ "id": "\#(id)", "messagesAdded": [ { "message": { "id": "added-\#(id)", "labelIds": ["INBOX"] } } ] }"#
        }
        return #"{ "historyId": "\#(historyId)", "history": [ \#(records.joined(separator: ", ")) ]\#(token) }"#
    }

    private static func messageJSON(id: String, labelIds: [String] = ["INBOX"]) -> String {
        let labels = labelIds.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "id": "\(id)",
          "threadId": "thread-\(id)",
          "labelIds": [\(labels)],
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

    /// The account-level routes every pass may call: the label list (a `.all`
    /// read starts with it) and the profile (a refused history is read again in
    /// the same pass with no bookmark, which takes the current history id as a
    /// candidate). Gmail's current id is far past every history page here.
    private static func registerAccountRoutes(on scenario: FakeHTTP.Scenario, pool: DatabasePool) {
        FolderEpochTestFixture.registerGmailLabels(on: scenario, listingFoldersOf: accountId, pool: pool)
        scenario.register(path: "/profile", method: "GET", response: .json(
            raw: #"{ "emailAddress": "\#(accountId)@example.com", "historyId": "9000" }"#))
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
        Self.registerAccountRoutes(on: scenario, pool: pool)
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
    /// answers with an error status, the request fails on the way or is
    /// cancelled, or Gmail answers 200 with a body that is not a history page.
    @Test("A failure on a later history page applies nothing and keeps the cursor",
          arguments: ["server error", "transport error", "cancelled", "malformed page"])
    func laterPageFailureKeepsTheCursor(failure: String) async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let reachedPage2 = Mutex(false)
            let scenario = FakeHTTP.Scenario()
            Self.registerAccountRoutes(on: scenario, pool: pool)
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET") { request in
                if Self.pageToken(of: request) == "page-2" {
                    reachedPage2.withLock { $0 = true }
                    switch failure {
                    case "server error": return .status(500)
                    case "transport error": return .transportError(.networkConnectionLost)
                    case "cancelled": return .transportError(.cancelled)
                    default: return .json(raw: "{ this is not a history page")
                    }
                }
                return .json(raw: Self.historyPage(historyId: "1002", addedId: "on-page-1", nextPageToken: "page-2"))
            }
            scenario.register(path: "/messages/on-page-1", method: "GET", response: .json(raw: Self.messageJSON(id: "on-page-1")))
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            await #expect(throws: (any Error).self) {
                _ = try await SyncEngine().performDeltaSync(account: account, provider: provider)
            }
            #expect(reachedPage2.withLock { $0 }, "precondition: the second page was requested")
            #expect(try Self.cursor(pool: pool) == Self.startCursor, "the cursor moved past a page that was never read")
            #expect(try !Self.headerExists("on-page-1", pool: pool), "part of an unread history was applied")
        }
    }

    /// A 404 on a later page is an expired history like a 404 on the first:
    /// the cursor is cleared for the full sync and nothing is applied.
    @Test("A 404 on a later history page clears the cursor and applies nothing")
    func laterPage404ClearsTheCursor() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let scenario = FakeHTTP.Scenario()
            Self.registerAccountRoutes(on: scenario, pool: pool)
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

    /// No fixed count bounds a pass (#491): a history naming more messages than
    /// one page of Gmail's default size is read and applied in one pass when
    /// its read budget allows, page after page, and the cursor moves to the
    /// first page's id.
    @Test("A history naming many messages over several pages is applied in one pass")
    func longHistoryIsAppliedInOnePass() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let perPage = GmailAPI.historyMaxChanges / 2 + 1
            let firstPage = (0..<perPage).map { "long-a\($0)" }
            let secondPage = (0..<perPage).map { "long-b\($0)" }
            let tokensSeen = Mutex<[String?]>([])
            let scenario = FakeHTTP.Scenario()
            Self.registerAccountRoutes(on: scenario, pool: pool)
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

            #expect(outcome.succeeded)
            #expect(Self.detailGETs(scenario) == firstPage.count + secondPage.count, "every message named is fetched")
            let missing = try (firstPage + secondPage).filter { try !Self.headerExists($0, pool: pool) }
            #expect(missing.isEmpty, "messages the history named were not applied: \(missing.prefix(5)) of \(missing.count)")
            #expect(tokensSeen.withLock { $0 } == [nil, "page-2", "page-3"], "every page is read")
            #expect(try Self.cursor(pool: pool) == "1002", "the cursor is the first page's id")
        }
    }

    /// One history record can name many messages: a conversation-wide archive,
    /// label change or a batch of new mail names every message in it. Every
    /// message of every kind of record that makes the delta fetch one is
    /// fetched and applied, however many there are and however the records
    /// fall across pages (no fixed count, #491).
    struct MessageBudgetCase: Sendable, CustomTestStringConvertible {
        let kind: ChangeKind
        let pages: Int
        var testDescription: String { "\(kind.rawValue) over \(pages) page(s)" }
    }

    static let messageBudgetCases: [MessageBudgetCase] =
        ChangeKind.allCases.map { MessageBudgetCase(kind: $0, pages: 1) }
        + [MessageBudgetCase(kind: .labelsRemoved, pages: 2), MessageBudgetCase(kind: .messagesAdded, pages: 2)]

    @Test("Every message a record names is fetched, of every kind of change",
          arguments: GmailHistoryPaginationTests.messageBudgetCases, [0, 1])
    func everyNamedMessageIsFetched(budgetCase: MessageBudgetCase, extra: Int) async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let messageCount = GmailAPI.historyMaxChanges + extra
            let perConversation = 4
            let ids = (0..<messageCount).map { "conv-msg-\($0)" }
            let conversations = stride(from: 0, to: ids.count, by: perConversation).map {
                Array(ids[$0..<min($0 + perConversation, ids.count)])
            }
            let perPage = (conversations.count + budgetCase.pages - 1) / budgetCase.pages
            let pageChunks = stride(from: 0, to: conversations.count, by: perPage).map {
                Array(conversations[$0..<min($0 + perPage, conversations.count)])
            }
            try #require(pageChunks.count == budgetCase.pages, "fixture: \(budgetCase.pages) page(s)")
            let scenario = FakeHTTP.Scenario()
            Self.registerAccountRoutes(on: scenario, pool: pool)
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

            #expect(Self.detailGETs(scenario) == messageCount, "every message the records name is fetched")
            #expect(outcome.succeeded)
            #expect(try Self.cursor(pool: pool) == "1002")
        }
    }

    /// Deletions cost no fetch: a history of many deletion records over two
    /// pages is applied in one pass. Every deleted row goes, a bystander's
    /// stays, and the cursor moves to the first page's id.
    @Test("A history of many deletions is applied in one pass with no fetch")
    func deletionsAreApplied() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let recordCount = GmailAPI.historyMaxChanges * 3
            let perPage = recordCount / 2
            try #require(perPage <= GmailAPI.historyPageSize, "fixture: each page within Gmail's page size")
            let deletedUIDs = Array(1...recordCount)
            let bystanderUID = recordCount + 1
            let deletedIds = deletedUIDs.map(String.init)
            try FolderEpochTestFixture.insertHeaders(
                accountId: Self.accountId, path: "INBOX", uids: deletedUIDs + [bystanderUID], pool: pool)
            for id in deletedIds + [String(bystanderUID)] {
                try #require(try Self.headerExists(id, pool: pool), "fixture: message \(id) is stored before the delta")
            }
            let tokensSeen = Mutex<[String?]>([])
            let scenario = FakeHTTP.Scenario()
            Self.registerAccountRoutes(on: scenario, pool: pool)
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET") { request in
                let token = Self.pageToken(of: request)
                tokensSeen.withLock { $0.append(token) }
                if token == "page-2" {
                    return .json(raw: Self.deletionPage(historyId: "1002", deletedIds: Array(deletedIds[perPage...])))
                }
                return .json(raw: Self.deletionPage(
                    historyId: "1002", deletedIds: Array(deletedIds[..<perPage]), nextPageToken: "page-2"))
            }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(Self.detailGETs(scenario) == 0, "a deleted message is never fetched")
            #expect(outcome.succeeded)
            let kept = try deletedIds.filter { try Self.headerExists($0, pool: pool) }
            #expect(kept.isEmpty, "deletions the history named were not applied: \(kept.prefix(5)) of \(kept.count)")
            #expect(try Self.headerExists(String(bystanderUID), pool: pool), "a message no record named was removed")
            #expect(tokensSeen.withLock { $0 } == [nil, "page-2"], "the whole history is read")
            #expect(try Self.cursor(pool: pool) == "1002", "an applied deletion delta moves the cursor")
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
            Self.registerAccountRoutes(on: scenario, pool: pool)
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

    /// The page loop is bounded. A pass reads at most `GmailAPI.historyMaxPages`
    /// pages; one that stops there stores the id of the last record it took,
    /// never a later one, and the next pass resumes after it.
    @Test("A history longer than the page limit stops after the last record read, and the next pass resumes there")
    func pageLimitStopsAndResumes() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let account = try Self.makeAccount(pool: pool)
        let firstRecord = 2000
        let lastRecord = firstRecord + GmailAPI.historyMaxPages + 1
        let starts = Mutex<[String]>([])
        let scenario = FakeHTTP.Scenario()
        Self.registerAccountRoutes(on: scenario, pool: pool)
        defer { scenario.close() }
        // One record per page; its id is the page's history id, past the cursor.
        scenario.register(path: "/history", method: "GET") { request in
            let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let start = items.first(where: { $0.name == "startHistoryId" })?.value ?? ""
            if Self.pageToken(of: request) == nil { starts.withLock { $0.append(start) } }
            let after = Self.pageToken(of: request).flatMap { Int($0.dropFirst("after-".count)) }
                ?? max(Int(start) ?? 0, firstRecord)
            let id = after + 1
            return .json(raw: Self.historyPage(
                historyId: "\(id)", addedId: "endless-\(id)", nextPageToken: id < lastRecord ? "after-\(id)" : nil))
        }
        for id in (firstRecord + 1)...lastRecord {
            scenario.register(path: "/messages/endless-\(id)", method: "GET", response: .json(raw: Self.messageJSON(id: "endless-\(id)")))
        }
        let provider = GmailProvider(
            userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

        let first = try await SyncEngine().performDeltaSync(account: account, provider: provider)

        let stopAt = String(firstRecord + GmailAPI.historyMaxPages)
        #expect(first.succeeded, "a pass that stops at the page limit is not refused")
        #expect(Self.detailGETs(scenario) == GmailAPI.historyMaxPages, "the page loop is not bounded")
        #expect(try Self.cursor(pool: pool) == stopAt, "the cursor is the last record read, never past it")
        #expect(try Self.headerExists("endless-\(stopAt)", pool: pool))
        #expect(try !Self.headerExists("endless-\(lastRecord)", pool: pool))

        let resumedAccount = try #require(try await pool.read { db in try Account.fetchOne(db, key: Self.accountId) })
        let second = try await SyncEngine().performDeltaSync(account: resumedAccount, provider: provider)
        #expect(second.succeeded)
        #expect(starts.withLock { $0 } == [Self.startCursor, stopAt], "the next pass reads from where the last one stopped")
        #expect(try Self.headerExists("endless-\(lastRecord)", pool: pool), "the rest of the history is applied")
        #expect(try Self.cursor(pool: pool) == String(lastRecord), "a read to the end stores its first page's id")
    }

    /// The id a pass stores when it stops early must be a history id past the
    /// cursor it read from (`users.history.list` returns the records after
    /// `startHistoryId`, in increasing id). One that is not is a history the
    /// reader cannot resume: the pass is refused like an expired history.
    @Test("A pass that stops early resumes only from a record id past its cursor",
          arguments: ["1001", "1000", "999", "not-a-number"])
    func cutBookmarkMustBeAHistoryIdPastTheCursor(recordId: String) async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let scenario = FakeHTTP.Scenario()
            Self.registerAccountRoutes(on: scenario, pool: pool)
            defer { scenario.close() }
            let now = Mutex(Date())
            scenario.register(path: "/history", method: "GET") { _ in
                // The read budget is spent as the first page is served.
                now.withLock { $0 = $0.addingTimeInterval(SyncConfig.changeReadBudgetSeconds + 1) }
                return .json(raw: Self.recordPage(historyId: "1002", recordIds: [recordId], nextPageToken: "page-2"))
            }
            scenario.register(path: "/messages/added-\(recordId)", method: "GET",
                              response: .json(raw: Self.messageJSON(id: "added-\(recordId)")))
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine(changeReadClock: { now.withLock { $0 } })
                .performDeltaSync(account: account, provider: provider)

            if recordId == "1001" {
                #expect(outcome.succeeded)
                #expect(try Self.cursor(pool: pool) == "1001", "the pass resumes after the last record it took")
                #expect(try Self.headerExists("added-1001", pool: pool))
            } else {
                #expect(!outcome.succeeded, "a record id that is not past the cursor cannot be resumed from")
                #expect(try Self.cursor(pool: pool) == nil, "the cursor is cleared as for an expired history")
            }
        }
    }

    /// A message already read in this pass is read again when a later record,
    /// written after the pass's first page was served (an id past that page's
    /// `historyId`), names it: the first answer may predate that change, and the
    /// newer answer is what the pass stores. Page 1 names a full window of
    /// messages, so they are read before page 2 is.
    @Test("A message named again by a record written during the pass is read again")
    func messageChangedDuringThePassIsReadAgain() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let firstWindow = ["twice"] + (1..<GmailAPI.maxConcurrentRequests).map { "window-\($0)" }
            let scenario = FakeHTTP.Scenario()
            Self.registerAccountRoutes(on: scenario, pool: pool)
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET") { request in
                if Self.pageToken(of: request) == "page-2" {
                    return .json(raw: #"{ "historyId": "1004", "history": [ { "id": "1003", "labelsAdded": [ "# +
                        #"{ "message": { "id": "twice", "labelIds": ["INBOX", "STARRED"] }, "labelIds": ["STARRED"] } ] } ] }"#)
                }
                return .json(raw: Self.historyPage(historyId: "1002", addedIds: firstWindow, nextPageToken: "page-2"))
            }
            for id in firstWindow.dropFirst() {
                scenario.register(path: "/messages/\(id)", method: "GET", response: .json(raw: Self.messageJSON(id: id)))
            }
            // The first answer predates the star; the second carries it.
            let twiceAnswers = Mutex(0)
            scenario.register(path: "/messages/twice", method: "GET") { _ in
                let answer = twiceAnswers.withLock { count -> Int in
                    count += 1
                    return count
                }
                return .json(raw: Self.messageJSON(id: "twice", labelIds: answer == 1 ? ["INBOX"] : ["INBOX", "STARRED"]))
            }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(outcome.succeeded)
            let headerId = MessageIdentity.headerId(accountId: Self.accountId, folderPath: "INBOX", messageId: "twice")
            let stored = try await pool.read { db in try MessageHeader.fetchOne(db, key: headerId) }
            #expect(stored?.isFlagged == true, "the pass stores the answer read after the change, not the first one")
            let twiceGETs = scenario.recordedCalls().filter { $0.method == "GET" && $0.url.contains("/messages/twice") }.count
            #expect(twiceGETs == 2, "the change written during the pass is read")
            #expect(Self.detailGETs(scenario) == firstWindow.count + 1, "no other message is read again")
            #expect(try Self.cursor(pool: pool) == "1002")
        }
    }

    /// Deletions are part of the history like any other record. One read on a
    /// later page is applied: the deleted message's row goes and a bystander's
    /// stays. A message added on one page and deleted on a later one is never
    /// fetched and never kept. The cursor is the first page's id.
    @Test("A deletion on a later history page is applied, and a message added then deleted is never fetched")
    func laterPageDeletionIsApplied() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            try FolderEpochTestFixture.insertHeaders(accountId: Self.accountId, path: "INBOX", uids: [501, 502], pool: pool)
            try #require(try Self.headerExists("501", pool: pool), "fixture: the message to delete exists locally")
            let scenario = FakeHTTP.Scenario()
            Self.registerAccountRoutes(on: scenario, pool: pool)
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET") { request in
                if Self.pageToken(of: request) == "page-2" {
                    return .json(raw: Self.deletionPage(historyId: "1005", deletedIds: ["501", "added-then-deleted"]))
                }
                return .json(raw: Self.historyPage(
                    historyId: "1002", addedIds: ["on-page-1", "added-then-deleted"], nextPageToken: "page-2"))
            }
            for id in ["on-page-1", "added-then-deleted"] {
                scenario.register(path: "/messages/\(id)", method: "GET", response: .json(raw: Self.messageJSON(id: id)))
            }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(outcome.succeeded)
            #expect(try !Self.headerExists("501", pool: pool), "a deletion on a later page was not applied")
            #expect(try Self.headerExists("502", pool: pool), "a message no record named was removed")
            #expect(try Self.headerExists("on-page-1", pool: pool))
            #expect(try !Self.headerExists("added-then-deleted", pool: pool), "a message deleted later in the history was kept")
            #expect(!scenario.recordedCalls().contains { $0.url.contains("/messages/added-then-deleted") },
                    "a message deleted later in the history was fetched")
            #expect(try Self.cursor(pool: pool) == "1002")
        }
    }

    /// A message read earlier in a pass and deleted by a later record of the
    /// same pass is gone: the answer read before the deletion is not stored.
    /// Page 1 names a full window of messages, so they are read before page 2
    /// deletes one of them.
    @Test("A message read earlier in the pass and deleted by a later record is not stored")
    func messageReadThenDeletedInThePassIsNotStored() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let firstWindow = ["read-then-deleted"] + (1..<GmailAPI.maxConcurrentRequests).map { "kept-\($0)" }
            let scenario = FakeHTTP.Scenario()
            Self.registerAccountRoutes(on: scenario, pool: pool)
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET") { request in
                if Self.pageToken(of: request) == "page-2" {
                    return .json(raw: Self.deletionPage(historyId: "1007", deletedIds: ["read-then-deleted"]))
                }
                return .json(raw: Self.historyPage(historyId: "1006", addedIds: firstWindow, nextPageToken: "page-2"))
            }
            for id in firstWindow {
                scenario.register(path: "/messages/\(id)", method: "GET", response: .json(raw: Self.messageJSON(id: id)))
            }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(outcome.succeeded)
            #expect(scenario.recordedCalls().contains { $0.url.contains("/messages/read-then-deleted") },
                    "precondition: the message was read before its deletion")
            #expect(try !Self.headerExists("read-then-deleted", pool: pool),
                    "a message deleted later in the pass was stored from its earlier answer")
            for id in firstWindow.dropFirst() {
                #expect(try Self.headerExists(id, pool: pool))
            }
            #expect(try Self.cursor(pool: pool) == "1006")
        }
    }

    /// A pass that takes no record keeps its bookmark (ADR-IOS-111, #491): here
    /// the first page holds no record but has a next page, and the budget is
    /// spent before that page. Storing the first page's id would skip the
    /// records on the pages not read. The next pass reads them.
    @Test("A pass that takes no record keeps its cursor, and the next pass reads the rest")
    func passThatTakesNoRecordKeepsTheCursor() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let tokensSeen = Mutex<[String?]>([])
            let budgetSpent = Mutex(false)
            let now = Mutex(Date())
            let scenario = FakeHTTP.Scenario()
            Self.registerAccountRoutes(on: scenario, pool: pool)
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET") { request in
                let token = Self.pageToken(of: request)
                tokensSeen.withLock { $0.append(token) }
                if token == "page-2" {
                    return .json(raw: Self.recordPage(historyId: "1009", recordIds: ["1008"], nextPageToken: nil))
                }
                // The first pass's read budget is spent as its first page is served.
                if budgetSpent.withLock({ $0 }) {
                    now.withLock { $0 = $0.addingTimeInterval(SyncConfig.changeReadBudgetSeconds + 1) }
                }
                return .json(raw: #"{ "historyId": "1009", "nextPageToken": "page-2" }"#)
            }
            scenario.register(path: "/messages/added-1008", method: "GET",
                              response: .json(raw: Self.messageJSON(id: "added-1008")))
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            budgetSpent.withLock { $0 = true }
            _ = try await SyncEngine(changeReadClock: { now.withLock { $0 } })
                .performDeltaSync(account: account, provider: provider)

            #expect(tokensSeen.withLock { $0 } == [nil], "no page starts after the budget is spent")
            #expect(try Self.cursor(pool: pool) == Self.startCursor,
                    "a pass that took no record must keep its cursor, not skip the pages it did not read")

            budgetSpent.withLock { $0 = false }
            let resumedAccount = try #require(try await pool.read { db in try Account.fetchOne(db, key: Self.accountId) })
            let second = try await SyncEngine().performDeltaSync(account: resumedAccount, provider: provider)

            #expect(second.succeeded)
            #expect(try Self.headerExists("added-1008", pool: pool), "the record on the page not read is applied")
            #expect(try Self.cursor(pool: pool) == "1009", "a read to the end stores its first page's id")
        }
    }

    /// A message that is both added and relabelled, on different pages, by
    /// records the first page already covered (ids up to its `historyId`), is
    /// fetched once: one answer read after the first page holds both changes.
    @Test("A message named by several records the first page covered is fetched once")
    func budgetCountsDistinctMessages() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let ids = (0..<GmailAPI.historyMaxChanges).map { "twice-\($0)" }
            let conversations = stride(from: 0, to: ids.count, by: 4).map { Array(ids[$0..<min($0 + 4, ids.count)]) }
            let scenario = FakeHTTP.Scenario()
            Self.registerAccountRoutes(on: scenario, pool: pool)
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET") { request in
                if Self.pageToken(of: request) == "page-2" {
                    return .json(raw: Self.changePage(historyId: "1005", kind: .labelsAdded, conversations: conversations))
                }
                return .json(raw: Self.changePage(
                    historyId: "1002", kind: .messagesAdded, conversations: conversations, nextPageToken: "page-2"))
            }
            for id in ids {
                scenario.register(path: "/messages/\(id)", method: "GET", response: .json(raw: Self.messageJSON(id: id)))
            }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(outcome.succeeded)
            #expect(Self.detailGETs(scenario) == ids.count, "one fetch per distinct message")
            for id in [ids.first!, ids.last!] {
                #expect(try Self.headerExists(id, pool: pool))
            }
            #expect(try Self.cursor(pool: pool) == "1002")
        }
    }

    /// Every page request is the original query plus exactly one page token,
    /// the CURRENT one, over three pages; and the page size on the wire is
    /// one Gmail accepts (`users.history.list` takes a `maxResults` of at
    /// most 500).
    @Test("Each page request carries the original query and only the current page token")
    func eachPageCarriesOnlyItsOwnToken() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let queries = Mutex<[String]>([])
            let scenario = FakeHTTP.Scenario()
            Self.registerAccountRoutes(on: scenario, pool: pool)
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET") { request in
                queries.withLock { $0.append(Self.wireQuery(of: request)) }
                switch Self.pageToken(of: request) {
                case nil: return .json(raw: Self.historyPage(historyId: "1002", addedId: "p1", nextPageToken: "token-1"))
                case "token-1": return .json(raw: Self.historyPage(historyId: "1004", addedId: "p2", nextPageToken: "token-2"))
                default: return .json(raw: Self.historyPage(historyId: "1006", addedId: "p3", nextPageToken: nil))
                }
            }
            for id in ["p1", "p2", "p3"] {
                scenario.register(path: "/messages/\(id)", method: "GET", response: .json(raw: Self.messageJSON(id: id)))
            }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(outcome.succeeded)
            let seen = queries.withLock { $0 }
            try #require(seen.count == 3, "expected three page requests, got \(seen)")
            let expectedTokens: [String?] = [nil, "token-1", "token-2"]
            for (query, expected) in zip(seen, expectedTokens) {
                let items = query.components(separatedBy: "&")
                let tokens = items.filter { $0.hasPrefix("pageToken=") }
                #expect(tokens == (expected.map { ["pageToken=\($0)"] } ?? []), "wrong page tokens: \(query)")
                #expect(items.contains("startHistoryId=\(Self.startCursor)"), "lost startHistoryId: \(query)")
                let sizes = items.filter { $0.hasPrefix("maxResults=") }.compactMap { Int($0.dropFirst("maxResults=".count)) }
                #expect(sizes.count == 1 && (1...500).contains(sizes[0]), "maxResults Gmail does not accept: \(query)")
                for type in ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"] {
                    #expect(items.contains("historyTypes=\(type)"), "lost historyTypes=\(type): \(query)")
                }
            }
            for id in ["p1", "p2", "p3"] {
                #expect(try Self.headerExists(id, pool: pool), "page change \(id) was not applied")
            }
            #expect(try Self.cursor(pool: pool) == "1002", "the cursor must be the first page's id")
        }
    }
}
