/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// ADR-IOS-103 decision 8: what a chat summary job really sends and writes, end to end.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. A summary of the user's own email (from one of their addresses, or in a Sent folder) tells
///     the backend so (`is_sent_by_user: true`), so its text message is in the user's voice; any
///     other email's request has no such field.
///  2. A real body write releases the chat summary that waited for it, on the shared queue, once.
///  3. The executor refuses an ordinary summary outside the Inbox (no model call, nothing written)
///     even when its admission was window-exempt; the same setup in the Inbox calls and writes.
@Suite("Chat summary execution", .serialized, .processGlobalState)
struct ChatSummaryExecutionTests {

    private static func header(
        _ uid: String, accountId: String, folder: String, fromAddress: String = "sender@example.com",
        bodyComplete: Bool = true
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "Plans", from: "Sender", fromAddress: fromAddress,
            to: "other@example.com", date: Date(), snippet: "",
            folderId: "\(accountId):\(folder)",
            accountId: accountId, folderPath: folder, isInInbox: folder == "INBOX")
        header.rfc822MessageId = "<\(uid)@example.com>"
        header.headerComplete = true
        header.bodyComplete = bodyComplete
        return header
    }

    /// A backend that answers every summary request with one structured result.
    private static func summaryBackend(textMessage: String) -> FakeHTTP.Scenario {
        let http = FakeHTTP.Scenario()
        http.register(path: "/completions/chat", method: "POST") { _ in
            let object: [String: Any] = ["summary": "A plan.", "todos": [], "reminder": NSNull(), "text_message": textMessage]
            let assistant = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let final = String(decoding: try! JSONSerialization.data(withJSONObject: ["assistant": assistant]), as: UTF8.self)
            return .bytes(Data("event: final\ndata: \(final)\n\n".utf8), contentType: "text/event-stream")
        }
        return http
    }

    /// The first message of a recorded request, as JSON.
    private static func firstMessage(_ call: (method: String, url: String, body: Data?)?) throws -> [String: Any] {
        let body = try #require(call?.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require((object["messages"] as? [[String: Any]])?.first)
    }

    private static func withAIOn<T>(_ body: () async throws -> T) async rethrows -> T {
        let saved = AIService.optOutStore.object(forKey: AIService.optOutAllAIKey)
        AIService.writeOptOutFlag(false)
        defer { AIService.optOutStore.set(saved, forKey: AIService.optOutAllAIKey) }
        return try await body()
    }

    private static func index(_ header: MessageHeader, body: String?) async throws {
        let key = ContentKey(rawValue: header.id)
        try await SearchIndex.shared.removeMessages(contentKeys: [key])
        _ = try await SearchIndex.shared.indexHeaders([FTSHeaderRecord(
            contentKey: key, headerId: header.id, messageId: header.messageId, subject: header.subject,
            from: header.fromAddress, to: header.to, dateMs: Int64(header.date.timeIntervalSince1970 * 1000))])
        if let body { try await SearchIndex.shared.updateBody(contentKey: key, body: body) }
    }

    // MARK: - 1. The user's own email

    @Test("A summary of the user's own email says the user wrote it; anyone else's does not")
    func ownEmailSaysTheUserWroteIt() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let account = try FolderEpochTestFixture.makeAccount(id: "own", provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "own", path: "Sent", role: .sent, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "own", path: "Archive", role: .archive, pool: pool)
        // In Sent from an address the account does not list (an alias); from the account's own
        // address in Archive; someone else's in Archive.
        let cases: [(MessageHeader, Bool)] = [
            (Self.header("sent-alias", accountId: "own", folder: "Sent", fromAddress: "alias@example.com"), true),
            (Self.header("archived-own", accountId: "own", folder: "Archive", fromAddress: "OWN@example.com"), true),
            (Self.header("archived-other", accountId: "own", folder: "Archive"), false),
        ]
        try await pool.write { db in for (header, _) in cases { try header.insert(db) } }

        try await Self.withAIOn {
            for (header, ownEmail) in cases {
                let http = Self.summaryBackend(textMessage: "I can do Tuesday.")
                defer { http.close() }
                let target = try #require(try await pool.read { try AIWriteTarget.capture(message: header, db: $0) })
                let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
                let queue = ActiveAIQueue()
                await queue.setDispatchSuppressedForTesting(true)
                _ = await queue.executeJobForTesting(
                    .init(headerId: header.id, accountId: header.accountId, jobType: .summary, windowExempt: true, forChat: true),
                    message: header, plainText: "I can do Tuesday.", account: account, target: target, aiService: service)

                let calls = http.recordedCalls()
                #expect(calls.count == 1, "\(header.messageId): one request")
                let message = try Self.firstMessage(calls.first)
                if ownEmail {
                    #expect(message["is_sent_by_user"] as? Bool == true, "\(header.messageId): the backend's own-email branch needs the boolean")
                } else {
                    #expect(message["is_sent_by_user"] == nil, "\(header.messageId): not the user's email, no field")
                }
                #expect(try await pool.read { try MessageHeader.fetchOne($0, key: header.id)?.summaryTextMessage } == "I can do Tuesday.",
                        "\(header.messageId): the job really ran and stored the result")
            }
        }
    }

    // MARK: - 2. A body write releases the waiting chat summary

    @Test("A real body write releases the chat summary waiting for it, on the shared queue, once")
    func bodyWriteReleasesTheWaitingSummary() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        _ = try FolderEpochTestFixture.makeAccount(id: "flush", provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "flush", path: "Sent", role: .sent, pool: pool)
        let header = Self.header("flush-body", accountId: "flush", folder: "Sent", bodyComplete: false)
        try await pool.write { try header.insert($0) }
        try await Self.index(header, body: nil)
        let key = ContentKey(rawValue: header.id)
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        await ActiveEmbeddingQueue.shared.clearForTesting()
        func cleanUp() async {
            await queue.clearForTesting()
            await queue.setDispatchSuppressedForTesting(false)
            await ActiveEmbeddingQueue.shared.clearForTesting()
            try? await SearchIndex.shared.removeMessages(contentKeys: [key])
        }
        do {
            try await releasesOnce(header, key: key, queue: queue, pool: pool)
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    private func releasesOnce(_ header: MessageHeader, key: ContentKey, queue: ActiveAIQueue, pool: DatabasePool) async throws {
        let asked = Mutex<[String]>([])
        await queue.enqueueChatSummaries([header], requestBodies: { rows in asked.withLock { $0.append(contentsOf: rows.map(\.id)) } })
        #expect(asked.withLock { $0 } == [header.id], "the bodiless member went to the body queue")
        #expect(await queue.queuedJobsForTesting.isEmpty, "no summary before its body")

        let item = BodyFetchProcessor.ProcessedItem(
            contentKey: key, headerId: header.id, accountId: header.accountId,
            isInInbox: false, body: "The real body arrived", snippet: "The real body arrived")
        await BodyFetchProcessor.flushBatch([item], enableAI: true)
        #expect(try await pool.read { try MessageHeader.fetchOne($0, key: header.id)?.bodyComplete } == true,
                "the real writer stored the body")
        #expect(try await SearchIndex.shared.bodyText(contentKey: key) == "The real body arrived")
        let released = await queue.queuedJobsForTesting.filter { $0.headerId == header.id }
        #expect(released.count == 1)
        #expect(released.allSatisfy { $0.jobType == .summary && $0.forChat && $0.windowExempt })

        await BodyFetchProcessor.flushBatch([item], enableAI: true)
        #expect(await queue.queuedJobsForTesting.filter { $0.headerId == header.id }.count == 1, "a second write adds nothing")
    }

    // MARK: - 3. The executor's folder scope

    @Test("An ordinary summary is refused outside the Inbox, even window-exempt; the same job in the Inbox calls and writes")
    func ordinarySummaryKeepsTheInboxScope() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        _ = try FolderEpochTestFixture.makeAccount(id: "scope", provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "scope", path: "Sent", role: .sent, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "scope", path: "INBOX", role: .inbox, pool: pool)
        let sent = Self.header("scope-sent", accountId: "scope", folder: "Sent")
        let inbox = Self.header("scope-inbox", accountId: "scope", folder: "INBOX")
        try await pool.write { db in try sent.insert(db); try inbox.insert(db) }
        try await Self.index(sent, body: "A body for the refused job")
        try await Self.index(inbox, body: "A body for the admitted job")
        let keys = [ContentKey(rawValue: sent.id), ContentKey(rawValue: inbox.id)]
        do {
            try await refusesOutsideTheInbox(sent: sent, inbox: inbox, pool: pool)
        } catch {
            try? await SearchIndex.shared.removeMessages(contentKeys: keys)
            throw error
        }
        try? await SearchIndex.shared.removeMessages(contentKeys: keys)
    }

    private func refusesOutsideTheInbox(sent: MessageHeader, inbox: MessageHeader, pool: DatabasePool) async throws {
        let http = Self.summaryBackend(textMessage: "An actual summary text.")
        defer { http.close() }

        try await Self.withAIOn {
            let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
            let queue = ActiveAIQueue()
            await queue.setDispatchSuppressedForTesting(true)

            await queue.executeWholeJobForTesting(
                .init(headerId: sent.id, accountId: sent.accountId, jobType: .summary, windowExempt: true), aiService: service)
            #expect(http.recordedCalls().isEmpty, "no model call for an ordinary summary outside the Inbox")
            let refused = try await pool.read { try MessageHeader.fetchOne($0, key: sent.id) }
            #expect(refused?.summaryBlurb == nil && refused?.summaryTextMessage == nil, "nothing written outside the Inbox")

            await queue.executeWholeJobForTesting(
                .init(headerId: inbox.id, accountId: inbox.accountId, jobType: .summary, windowExempt: true), aiService: service)
            #expect(http.recordedCalls().count == 1, "the same setup in the Inbox calls the model")
            #expect(try await pool.read { try MessageHeader.fetchOne($0, key: inbox.id)?.summaryTextMessage } == "An actual summary text.",
                    "and writes the result")
        }
    }
}
