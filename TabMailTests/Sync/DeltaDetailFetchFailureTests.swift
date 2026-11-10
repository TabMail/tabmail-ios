/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// A delta lists what changed, then fetches each changed message by id.
/// THE PROPERTY: a change the delta could not fetch is never lost to a failure
/// that clears. Only a 404 (the message is gone) may be skipped; any other
/// failure leaves the cursor where it was, so the next pass fetches the same
/// change again and applies it once the fetch succeeds. And a message whose
/// fetch never succeeds does not stop the account's sync: the full sync
/// completes past it and moves the cursor, so later changes land.
///
/// These drive production `SyncEngine.performDeltaSync` (and, for the bound,
/// the foreground poll `SyncEngine.sync(account:)`, which runs the delta, the
/// due full sync and the cursor capture) end to end on `FakeHTTP` with a real
/// provider and a real `DatabasePool`, for both providers whose delta fetches
/// messages by id (Gmail and Outlook).
@Suite("A delta never loses a change whose message fetch failed", .serialized, .processGlobalState)
struct DeltaDetailFetchFailureTests {
    enum Failure: String, Sendable, CaseIterable {
        /// `undatedRecord` is a 200 whose record the provider's parser refuses
        /// (no usable date): a failed fetch, not a gone message.
        case serverError, clientError, unreadableBody, undatedRecord, transportError

        func response(id: String, provider: AccountProvider) -> FakeHTTP.CannedResponse {
            switch self {
            case .serverError: return .status(503)
            case .clientError: return .status(400)
            case .unreadableBody: return .json(raw: "not a message")
            case .undatedRecord:
                return .json(raw: provider == .gmail
                    ? DeltaDetailFetchFailureTests.gmailMessageJSON(id: id, dated: false)
                    : DeltaDetailFetchFailureTests.outlookMessageJSON(id: id, dated: false))
            case .transportError: return .transportError(.networkConnectionLost)
            }
        }

        /// The failures that are an answer about the one message: the server
        /// replied, and the reply cannot be used.
        static let answers: [Failure] = [.serverError, .clientError, .unreadableBody, .undatedRecord]
    }

    private static func withAppDB(_ body: (DatabasePool) async throws -> Void) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        try await body(pool)
    }

    private static func makeAccount(
        id: String, provider: AccountProvider, cursor: String, folderPath: String, role: FolderRole, pool: DatabasePool
    ) throws -> Account {
        var account = Account(emailAddress: "\(id)@example.com", displayName: "Delta detail", provider: provider)
        account.id = id
        account.lastHistoryId = cursor
        let toInsert = account
        try pool.write { db in
            try toInsert.insert(db)
            try Folder(name: folderPath, path: folderPath, role: role, accountId: id).insert(db)
        }
        return account
    }

    private static func headerExists(accountId: String, folderPath: String, messageId: String, pool: DatabasePool) throws -> Bool {
        let id = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: messageId)
        return try pool.read { db in try MessageHeader.fetchOne(db, key: id) != nil }
    }

    private static func storedAccount(id: String, pool: DatabasePool) throws -> Account? {
        try pool.read { db in try Account.fetchOne(db, key: id) }
    }

    private static func cursor(accountId: String, pool: DatabasePool) throws -> String? {
        try pool.read { db in try Account.fetchOne(db, key: accountId) }?.lastHistoryId
    }

    /// One foreground poll, as the app runs it: the account is read afresh and
    /// `SyncEngine.sync(account:)` runs on the provider's registered work queue.
    private static func foregroundPoll(engine: SyncEngine, accountId: String, pool: DatabasePool) async throws {
        let account = try #require(try storedAccount(id: accountId, pool: pool))
        _ = try await engine.sync(account: account)
    }

    /// Moves the account's last poll and last full sync one poll interval back,
    /// so the next poll runs (past the recent-sync guard) without a full sync
    /// being due: only the delta can land what changed.
    private static func lastPolledOneIntervalAgo(accountId: String, pool: DatabasePool) throws {
        let earlier = Date().addingTimeInterval(-SyncConfig.foregroundPollIntervalSeconds)
        try pool.write { db in
            _ = try Account.filter(Column("id") == accountId).updateAll(db,
                Column("lastSyncedAt").set(to: earlier),
                Column("lastFullSyncAt").set(to: earlier))
        }
    }

    // MARK: - Gmail

    private static let gmailAccountId = "gmail-delta-detail"

    private static func gmailHistoryPage(addedIds: [String]) -> String {
        let records = addedIds.enumerated().map { index, id in
            #"{ "id": "\#(1001 + index)", "messagesAdded": [ { "message": { "id": "\#(id)", "labelIds": ["INBOX"] } } ] }"#
        }
        return #"{ "historyId": "1002", "history": [ \#(records.joined(separator: ", ")) ] }"#
    }

    static func gmailMessageJSON(id: String, dated: Bool = true) -> String {
        let internalDate = dated ? #""internalDate": "\#(Int64(Date().timeIntervalSince1970 * 1000))","# : ""
        return """
        {
          "id": "\(id)",
          "threadId": "thread-\(id)",
          "labelIds": ["INBOX"],
          "snippet": "",
          \(internalDate)
          "payload": {
            "mimeType": "text/plain",
            "headers": [
              { "name": "Subject", "value": "delta \(id)" },
              { "name": "From", "value": "Sender <sender@example.com>" },
              { "name": "To", "value": "recipient@example.com" },
              { "name": "Message-Id", "value": "<\(id)@example.com>" }
            ]
          }
        }
        """
    }

    /// RED before the fix: the failed fetch was taken for a deleted message,
    /// the pass succeeded, the cursor moved past the change and the message was
    /// never fetched again.
    @Test("A Gmail message whose fetch fails keeps the cursor and lands on the next pass",
          arguments: Failure.allCases)
    func gmailFailedFetchIsRetried(failure: Failure) async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(
                id: Self.gmailAccountId, provider: .gmail, cursor: "1000", folderPath: "INBOX", role: .inbox, pool: pool)
            let failing = Mutex(true)
            let scenario = FakeHTTP.Scenario()
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET",
                              response: .json(raw: Self.gmailHistoryPage(addedIds: ["steady-1", "flaky-1"])))
            scenario.register(path: "/messages/steady-1", method: "GET",
                              response: .json(raw: Self.gmailMessageJSON(id: "steady-1")))
            scenario.register(path: "/messages/flaky-1", method: "GET") { _ in
                failing.withLock { $0 } ? failure.response(id: "flaky-1", provider: .gmail) : .json(raw: Self.gmailMessageJSON(id: "flaky-1"))
            }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            await #expect(throws: (any Error).self, "a failed message fetch must fail the delta") {
                _ = try await SyncEngine().performDeltaSync(account: account, provider: provider)
            }
            #expect(try Self.cursor(accountId: Self.gmailAccountId, pool: pool) == "1000",
                    "the cursor moved past a change that was never fetched")

            failing.withLock { $0 = false }
            let retried = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(retried.succeeded)
            #expect(try Self.headerExists(accountId: Self.gmailAccountId, folderPath: "INBOX", messageId: "flaky-1", pool: pool),
                    "the change whose fetch failed was lost")
            #expect(try Self.headerExists(accountId: Self.gmailAccountId, folderPath: "INBOX", messageId: "steady-1", pool: pool))
            #expect(try Self.cursor(accountId: Self.gmailAccountId, pool: pool) == "1002")
        }
    }

    /// A message deleted between the history listing and its fetch answers
    /// 404. That is the one failure that is skipped: the rest of the delta is
    /// applied and the cursor moves, so the gone message is not asked for again.
    @Test("A Gmail message that is gone (404) is skipped and the rest of the delta lands")
    func gmailGoneMessageIsSkipped() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(
                id: Self.gmailAccountId, provider: .gmail, cursor: "1000", folderPath: "INBOX", role: .inbox, pool: pool)
            let scenario = FakeHTTP.Scenario()
            defer { scenario.close() }
            scenario.register(path: "/history", method: "GET",
                              response: .json(raw: Self.gmailHistoryPage(addedIds: ["steady-1", "gone-1"])))
            scenario.register(path: "/messages/steady-1", method: "GET",
                              response: .json(raw: Self.gmailMessageJSON(id: "steady-1")))
            scenario.register(path: "/messages/gone-1", method: "GET", response: .status(404))
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(outcome.succeeded)
            #expect(try Self.headerExists(accountId: Self.gmailAccountId, folderPath: "INBOX", messageId: "steady-1", pool: pool))
            #expect(try !Self.headerExists(accountId: Self.gmailAccountId, folderPath: "INBOX", messageId: "gone-1", pool: pool))
            #expect(try Self.cursor(accountId: Self.gmailAccountId, pool: pool) == "1002",
                    "a gone message must not hold the cursor back")
        }
    }

    // MARK: - Gmail: a fetch that never succeeds does not stop sync

    private static let gmailStuckId = "301"
    private static let gmailBoundAccountId = "gmail-delta-detail-bound"

    /// One scenario for the delta, the full sync and the capture. The INBOX
    /// list names the stuck message and `ok-1`; every other label is empty.
    /// History from 1000 adds both; history from the captured 2000 adds `ok-2`.
    private static func gmailBoundScenario(stuck: FakeHTTP.CannedResponse) -> FakeHTTP.Scenario {
        let scenario = FakeHTTP.Scenario()
        scenario.register(path: "/labels", method: "GET", response: .json(
            raw: #"{ "labels": [ { "id": "INBOX", "name": "INBOX", "type": "system" } ] }"#))
        scenario.register(path: "/profile", method: "GET", response: .json(
            raw: #"{ "emailAddress": "gmail-delta-detail-bound@example.com", "historyId": "2000" }"#))
        scenario.register(path: "/history", method: "GET") { request in
            let query = request.url.query ?? ""
            if query.contains("startHistoryId=2000") {
                return .json(raw: #"{ "historyId": "2001", "history": [ { "id": "2001", "messagesAdded": [ { "message": { "id": "ok-2", "labelIds": ["INBOX"] } } ] } ] }"#)
            }
            return .json(raw: Self.gmailHistoryPage(addedIds: [Self.gmailStuckId, "ok-1"]))
        }
        scenario.register(path: "/messages", method: "GET") { request in
            let last = request.url.lastPathComponent
            if last == "messages" {
                if (request.url.query ?? "").contains("labelIds=INBOX") {
                    return .json(raw: #"{ "messages": [ { "id": "\#(Self.gmailStuckId)", "threadId": "t-\#(Self.gmailStuckId)" }, { "id": "ok-1", "threadId": "t-ok-1" } ], "resultSizeEstimate": 2 }"#)
                }
                return .json(raw: #"{ "resultSizeEstimate": 0 }"#)
            }
            return last == Self.gmailStuckId ? stuck : .json(raw: Self.gmailMessageJSON(id: last))
        }
        return scenario
    }

    /// RED before the full sync learned to finish past an unreadable message:
    /// the delta failed on the stuck message every pass, the full sync aborted
    /// on the same message, the capture never ran, and no later change for the
    /// account ever landed.
    @Test("A Gmail message whose fetch never succeeds does not stop sync: the full sync completes past it and later changes land",
          arguments: Failure.answers)
    func gmailStuckMessageDoesNotStopSync(failure: Failure) async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(
                id: Self.gmailBoundAccountId, provider: .gmail, cursor: "1000", folderPath: "INBOX", role: .inbox, pool: pool)
            try FolderEpochTestFixture.insertHeaders(
                accountId: Self.gmailBoundAccountId, path: "INBOX", uids: [Int(Self.gmailStuckId)!], pool: pool)
            let scenario = Self.gmailBoundScenario(stuck: failure.response(id: Self.gmailStuckId, provider: .gmail))
            defer { scenario.close() }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)
            let engine = SyncEngine()
            await engine.register(
                accountId: Self.gmailBoundAccountId, provider: provider,
                workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))

            await #expect(throws: (any Error).self, "the stuck message must fail the delta, not be taken for deleted") {
                _ = try await engine.performDeltaSync(account: account, provider: provider)
            }
            #expect(try Self.cursor(accountId: Self.gmailBoundAccountId, pool: pool) == "1000")

            // A foreground poll with a full sync due: its delta fails on the
            // stuck message again, and its full sync and capture bound that.
            try await Self.foregroundPoll(engine: engine, accountId: Self.gmailBoundAccountId, pool: pool)
            #expect(try Self.storedAccount(id: Self.gmailBoundAccountId, pool: pool)?.lastFullSyncAt != nil,
                    "precondition: the poll ran its due full sync")
            #expect(try Self.headerExists(accountId: Self.gmailBoundAccountId, folderPath: "INBOX", messageId: "ok-1", pool: pool),
                    "the full sync must still sync the rest of the folder")
            #expect(try Self.headerExists(accountId: Self.gmailBoundAccountId, folderPath: "INBOX", messageId: Self.gmailStuckId, pool: pool),
                    "a message the server still holds must keep its row")
            #expect(try Self.cursor(accountId: Self.gmailBoundAccountId, pool: pool) == "2000",
                    "the poll must bound the failed delta by moving the cursor")

            // The next ordinary poll, with no full sync due: the delta alone
            // lands a change made after the stuck one.
            try Self.lastPolledOneIntervalAgo(accountId: Self.gmailBoundAccountId, pool: pool)
            try await Self.foregroundPoll(engine: engine, accountId: Self.gmailBoundAccountId, pool: pool)
            #expect(try Self.headerExists(accountId: Self.gmailBoundAccountId, folderPath: "INBOX", messageId: "ok-2", pool: pool),
                    "a change made after the stuck one must land")
            #expect(try Self.cursor(accountId: Self.gmailBoundAccountId, pool: pool) == "2001")
            await engine.remove(accountId: Self.gmailBoundAccountId)
        }
    }

    /// Failures that are not an answer about the one message.
    enum NotAnAnswer: String, Sendable, CaseIterable {
        /// A dropped connection.
        case transportError
        /// A 401 that the token refresh did not cure: the account's
        /// credentials, not the message.
        case unauthorized

        var response: FakeHTTP.CannedResponse {
            switch self {
            case .transportError: return .transportError(.networkConnectionLost)
            case .unauthorized: return .status(401)
            }
        }
    }

    /// The other side of the same line: a failure that is not an answer about
    /// the message fails the folder fetch as a whole, and nothing is read as
    /// covered.
    @Test("A Gmail folder fetch still fails when one message's fetch loses the connection or is unauthorised",
          arguments: NotAnAnswer.allCases)
    func gmailFolderFetchFailsOnANonAnswer(failure: NotAnAnswer) async throws {
        let scenario = Self.gmailBoundScenario(stuck: failure.response)
        defer { scenario.close() }
        let provider = GmailProvider(
            userEmail: "gmail-delta-detail-bound@example.com", accessToken: { _ in "fake-access-token" }, session: scenario.session)

        await #expect(throws: (any Error).self) {
            _ = try await provider.fetchMessagesWithObservedEpoch(folder: "INBOX", limit: SyncConfig.syncMessageLimit, offset: 0)
        }
    }

    /// A folder fetch cancelled while its message fetches wait out Gmail's
    /// rate-limit backoff is not coverage: it must fail, not report the
    /// messages it never read as unmaterialised.
    @Test("A cancelled Gmail folder fetch fails instead of reporting coverage")
    func gmailFolderFetchFailsWhenCancelled() async throws {
        let ids = ["slow-1", "slow-2"]
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }
        scenario.register(path: "/messages", method: "GET") { request in
            if request.url.lastPathComponent == "messages" {
                let refs = ids.map { #"{ "id": "\#($0)", "threadId": "t-\#($0)" }"# }
                return .json(raw: #"{ "messages": [ \#(refs.joined(separator: ", ")) ], "resultSizeEstimate": 2 }"#)
            }
            return .status(429)
        }
        let provider = GmailProvider(
            userEmail: "gmail-delta-detail-cancel@example.com", accessToken: { _ in "fake-access-token" }, session: scenario.session)

        let fetch = Task {
            try await provider.fetchMessagesWithObservedEpoch(folder: "INBOX", limit: SyncConfig.syncMessageLimit, offset: 0)
        }
        // Each message's first 429 starts a backoff of `initialDelay`; cancel
        // once both have been asked for, well inside that wait.
        let backoff = Duration.seconds(HTTPRetryPolicy.gmail.initialDelay)
        let deadline = ContinuousClock.now + backoff
        while ContinuousClock.now < deadline {
            let asked = Set(scenario.recordedCalls().map { URL(string: $0.url)?.lastPathComponent ?? "" })
            if asked.isSuperset(of: ids) { break }
            try await Task.sleep(for: backoff / 100)
        }
        let asked = Set(scenario.recordedCalls().map { URL(string: $0.url)?.lastPathComponent ?? "" })
        #expect(asked.isSuperset(of: ids), "the message fetches never started")
        fetch.cancel()

        if case .success(let page) = await fetch.result {
            Issue.record("a cancelled folder fetch reported coverage; unmaterialised: \(page.coverage.unmaterialisedIds.sorted())")
        }
    }

    /// The delta hands `fetchMessageDetails` its ids in set order, which
    /// varies by process. Calling it directly with the gone message FIRST pins
    /// that a gone message never ends the loop early.
    @Test("A gone Gmail message ahead of a readable one does not stop the detail fetch",
          arguments: [404, 410])
    func gmailGoneMessageFirstIsSkipped(status: Int) async throws {
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }
        scenario.register(path: "/messages/gone-1", method: "GET", response: .status(status))
        scenario.register(path: "/messages/steady-1", method: "GET",
                          response: .json(raw: Self.gmailMessageJSON(id: "steady-1")))
        let provider = GmailProvider(
            userEmail: "gmail-delta-detail@example.com", accessToken: { _ in "fake-access-token" }, session: scenario.session)

        let details = try await provider.fetchMessageDetails(ids: ["gone-1", "steady-1"])

        #expect(details.map(\.header.messageId) == ["steady-1"])
    }

    // MARK: - Outlook

    private static let outlookAccountId = "outlook-delta-detail"
    private static let outlookFolder = "inbox-delta-detail"
    private static let startLink = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=start"
    private static let nextLink = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=next"

    private static func outlookDeltaPage(ids: [String]) -> String {
        let values = ids.map { #"{ "id": "\#($0)" }"# }
        return #"{ "value": [ \#(values.joined(separator: ", ")) ], "@odata.deltaLink": "\#(nextLink)" }"#
    }

    private static func outlookMessageJSON(id: String, dated: Bool = true) -> String {
        let received = dated ? #""receivedDateTime": "\#(ISO8601DateFormatter().string(from: Date()))","# : ""
        return """
        {
          "id": "\(id)",
          "subject": "delta \(id)",
          \(received)
          "isRead": false,
          "hasAttachments": false,
          "internetMessageId": "<\(id)@example.com>",
          "parentFolderId": "\(outlookFolder)"
        }
        """
    }

    /// RED before the fix, the same way as on Gmail: the failed fetch was
    /// skipped and the delta link moved past the change.
    @Test("An Outlook message whose fetch fails keeps the delta link and lands on the next pass",
          arguments: Failure.allCases)
    func outlookFailedFetchIsRetried(failure: Failure) async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(
                id: Self.outlookAccountId, provider: .outlook, cursor: Self.startLink,
                folderPath: Self.outlookFolder, role: .inbox, pool: pool)
            let failing = Mutex(true)
            let scenario = FakeHTTP.Scenario()
            defer { scenario.close() }
            scenario.register(path: "/messages/delta", method: "GET",
                              response: .json(raw: Self.outlookDeltaPage(ids: ["steady-1", "flaky-1"])))
            scenario.register(path: "/messages/steady-1", method: "GET",
                              response: .json(raw: Self.outlookMessageJSON(id: "steady-1")))
            scenario.register(path: "/messages/flaky-1", method: "GET") { _ in
                failing.withLock { $0 } ? failure.response(id: "flaky-1", provider: .outlook) : .json(raw: Self.outlookMessageJSON(id: "flaky-1"))
            }
            let provider = ExchangeProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            await #expect(throws: (any Error).self, "a failed message fetch must fail the delta") {
                _ = try await SyncEngine().performDeltaSync(account: account, provider: provider)
            }
            #expect(try Self.cursor(accountId: Self.outlookAccountId, pool: pool) == Self.startLink,
                    "the delta link moved past a change that was never fetched")

            failing.withLock { $0 = false }
            let retried = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(retried.succeeded)
            #expect(try Self.headerExists(
                accountId: Self.outlookAccountId, folderPath: Self.outlookFolder, messageId: "flaky-1", pool: pool),
                    "the change whose fetch failed was lost")
            #expect(try Self.headerExists(
                accountId: Self.outlookAccountId, folderPath: Self.outlookFolder, messageId: "steady-1", pool: pool))
            #expect(try Self.cursor(accountId: Self.outlookAccountId, pool: pool) == Self.nextLink)
        }
    }

    @Test("An Outlook message that is gone (404) is skipped and the rest of the delta lands")
    func outlookGoneMessageIsSkipped() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(
                id: Self.outlookAccountId, provider: .outlook, cursor: Self.startLink,
                folderPath: Self.outlookFolder, role: .inbox, pool: pool)
            let scenario = FakeHTTP.Scenario()
            defer { scenario.close() }
            scenario.register(path: "/messages/delta", method: "GET",
                              response: .json(raw: Self.outlookDeltaPage(ids: ["steady-1", "gone-1"])))
            scenario.register(path: "/messages/steady-1", method: "GET",
                              response: .json(raw: Self.outlookMessageJSON(id: "steady-1")))
            scenario.register(path: "/messages/gone-1", method: "GET", response: .status(404))
            let provider = ExchangeProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

            #expect(outcome.succeeded)
            #expect(try Self.headerExists(
                accountId: Self.outlookAccountId, folderPath: Self.outlookFolder, messageId: "steady-1", pool: pool))
            #expect(try !Self.headerExists(
                accountId: Self.outlookAccountId, folderPath: Self.outlookFolder, messageId: "gone-1", pool: pool))
            #expect(try Self.cursor(accountId: Self.outlookAccountId, pool: pool) == Self.nextLink,
                    "a gone message must not hold the delta link back")
        }
    }

    /// The detail fetch goes through the provider's ordinary request, so a
    /// Graph refusal still names Graph's error in the debug log.
    @Test("An Outlook detail fetch refused by Graph names Graph's error in the debug log")
    func outlookRefusalIsLogged() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deltadetaillog_\(UUID().uuidString).log")
        AppLogStore.fileURLOverride.withLock { $0 = url }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(
                id: Self.outlookAccountId, provider: .outlook, cursor: Self.startLink,
                folderPath: Self.outlookFolder, role: .inbox, pool: pool)
            let scenario = FakeHTTP.Scenario()
            defer { scenario.close() }
            scenario.register(path: "/messages/delta", method: "GET",
                              response: .json(raw: Self.outlookDeltaPage(ids: ["refused-1"])))
            scenario.register(path: "/messages/refused-1", method: "GET", response: .json(
                raw: #"{"error":{"code":"SomeCode","message":"Some message"}}"#, statusCode: 400))
            let provider = ExchangeProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)

            await #expect(throws: (any Error).self) {
                _ = try await SyncEngine().performDeltaSync(account: account, provider: provider)
            }
            #expect(AppLogStore.read(channel: .debug).contains("SomeCode: Some message"))
        }
    }

    @Test("A gone Outlook message ahead of a readable one does not stop the detail fetch",
          arguments: [404, 410])
    func outlookGoneMessageFirstIsSkipped(status: Int) async throws {
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }
        scenario.register(path: "/messages/gone-1", method: "GET", response: .status(status))
        scenario.register(path: "/messages/steady-1", method: "GET",
                          response: .json(raw: Self.outlookMessageJSON(id: "steady-1")))
        let provider = ExchangeProvider(
            userEmail: "outlook-delta-detail@example.com", accessToken: { _ in "fake-access-token" }, session: scenario.session)

        let details = try await provider.fetchMessageDetails(ids: ["gone-1", "steady-1"])

        #expect(details.map(\.header.messageId) == ["steady-1"])
    }

    // MARK: - Outlook: a fetch that never succeeds does not stop sync

    private static let capturedLink = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=captured"
    private static let afterCaptureLink = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=after"

    /// The bound on Outlook is the cursor capture the foreground poll runs after
    /// its due full sync. Outlook's full sync lists each folder's messages in one
    /// request and never fetches the stuck message by id, so it cannot fail on
    /// it. The capture walks the inbox's delta pages to the end and stores the
    /// final link; the next poll's delta from that link lands what changed
    /// after it.
    @Test("An Outlook message whose fetch never succeeds does not stop sync: the capture moves the delta link and later changes land",
          arguments: Failure.answers)
    func outlookStuckMessageDoesNotStopSync(failure: Failure) async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(
                id: Self.outlookAccountId, provider: .outlook, cursor: Self.startLink,
                folderPath: Self.outlookFolder, role: .inbox, pool: pool)
            let scenario = FakeHTTP.Scenario()
            defer { scenario.close() }
            // The full sync: the folder list, the inbox by its well-known name,
            // and the inbox's messages in one listing.
            scenario.register(path: "/mailFolders", method: "GET", response: .json(
                raw: #"{ "value": [ { "id": "\#(Self.outlookFolder)", "displayName": "Inbox", "totalItemCount": 2, "unreadItemCount": 0, "childFolderCount": 0 } ] }"#))
            scenario.register(path: "/mailFolders/inbox", method: "GET", response: .json(
                raw: #"{ "id": "\#(Self.outlookFolder)", "displayName": "Inbox" }"#))
            scenario.register(path: "/mailFolders/\(Self.outlookFolder)/messages", method: "GET", response: .json(
                raw: #"{ "value": [ \#(Self.outlookMessageJSON(id: "stuck-1")), \#(Self.outlookMessageJSON(id: "ok-1")) ] }"#))
            // Every delta page, under each path it is requested by (the stored
            // links name the inbox by its well-known name, the capture by id),
            // so no shorter folder fixture above answers a delta request.
            let delta: @Sendable (FakeHTTP.Request) -> FakeHTTP.CannedResponse = { request in
                let url = request.url.absoluteString
                if url.contains("deltatoken=start") {
                    return .json(raw: Self.outlookDeltaPage(ids: ["stuck-1", "ok-1"]))
                }
                if url.contains("deltatoken=captured") {
                    return .json(raw: #"{ "value": [ { "id": "ok-2" } ], "@odata.deltaLink": "\#(Self.afterCaptureLink)" }"#)
                }
                if url.contains("skiptoken=page-2") {
                    return .json(raw: #"{ "value": [ { "id": "ok-1" } ], "@odata.deltaLink": "\#(Self.capturedLink)" }"#)
                }
                // The capture's first page, for the inbox folder by id.
                return .json(raw: #"{ "value": [ { "id": "stuck-1" } ], "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$skiptoken=page-2" }"#)
            }
            scenario.register(path: "/mailFolders/inbox/messages/delta", method: "GET", handler: delta)
            scenario.register(path: "/mailFolders/\(Self.outlookFolder)/messages/delta", method: "GET", handler: delta)
            scenario.register(path: "/messages/stuck-1", method: "GET",
                              response: failure.response(id: "stuck-1", provider: .outlook))
            for id in ["ok-1", "ok-2"] {
                scenario.register(path: "/messages/\(id)", method: "GET", response: .json(raw: Self.outlookMessageJSON(id: id)))
            }
            let provider = ExchangeProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)
            let engine = SyncEngine()
            await engine.register(
                accountId: Self.outlookAccountId, provider: provider,
                workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))

            await #expect(throws: (any Error).self, "the stuck message must fail the delta, not be taken for deleted") {
                _ = try await engine.performDeltaSync(account: account, provider: provider)
            }
            #expect(try Self.cursor(accountId: Self.outlookAccountId, pool: pool) == Self.startLink)

            // A foreground poll with a full sync due: its delta fails on the
            // stuck message again, and the capture after its full sync bounds that.
            try await Self.foregroundPoll(engine: engine, accountId: Self.outlookAccountId, pool: pool)
            #expect(try Self.storedAccount(id: Self.outlookAccountId, pool: pool)?.lastFullSyncAt != nil,
                    "precondition: the poll ran its due full sync")
            #expect(try Self.headerExists(
                accountId: Self.outlookAccountId, folderPath: Self.outlookFolder, messageId: "stuck-1", pool: pool),
                    "a message the server still holds must keep its row")
            #expect(try Self.cursor(accountId: Self.outlookAccountId, pool: pool) == Self.capturedLink,
                    "the poll must bound the failed delta by storing the inbox's current delta link")

            // The next ordinary poll, with no full sync due: the delta alone
            // lands a change made after the stuck one.
            try Self.lastPolledOneIntervalAgo(accountId: Self.outlookAccountId, pool: pool)
            try await Self.foregroundPoll(engine: engine, accountId: Self.outlookAccountId, pool: pool)
            #expect(try Self.headerExists(
                accountId: Self.outlookAccountId, folderPath: Self.outlookFolder, messageId: "ok-2", pool: pool),
                    "a change made after the stuck one must land")
            #expect(try Self.cursor(accountId: Self.outlookAccountId, pool: pool) == Self.afterCaptureLink)
            await engine.remove(accountId: Self.outlookAccountId)
        }
    }
}
