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
///  4. A chat summary is finished only with its text message, at every site that decides it
///     (`ActiveAIQueue.jobDone`): the executor runs it in any folder, on an old summary without a
///     text message, and after another device's summary (which has none), and `readJobOutcome`
///     retries it until the text message is stored; an ordinary summary job stops at each of those.
///  5. Chat members waiting for a body are forgotten when the queue is cancelled.
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

    // MARK: - 4. A chat summary is finished only with its text message

    @Test("One done check: a chat summary needs its text message; an ordinary one, action and reply do not",
          arguments: [ActiveAIQueue.AIJob.JobType.summary, .action, .reply])
    func jobDoneTable(type: ActiveAIQueue.AIJob.JobType) {
        let bare = Self.header("done-table", accountId: "table", folder: "INBOX")
        var legacy = bare
        legacy.summaryBlurb = "An old summary."
        legacy.actionTag = .reply
        legacy.cachedReply = "A reply."
        var complete = legacy
        complete.summaryTextMessage = "A text message."
        var noContent = bare
        noContent.summaryBlurb = MessageHeader.noContentSummary
        func done(_ message: MessageHeader, chat: Bool) -> Bool {
            ActiveAIQueue.jobDone(message, for: .init(headerId: message.id, accountId: "table", jobType: type, forChat: chat))
        }
        for chat in [false, true] {
            #expect(!done(bare, chat: chat), "\(type) chat=\(chat): nothing stored is never done")
            #expect(done(complete, chat: chat), "\(type) chat=\(chat): everything stored is done")
        }
        // The only row the two kinds of job disagree on: a summary without its text message.
        #expect(done(legacy, chat: false))
        #expect(done(legacy, chat: true) == (type != .summary), "\(type): only a chat summary still needs the text message")
        if type == .summary {
            #expect(done(noContent, chat: true), "the no-content summary never gets a text message")
        }
    }

    @Test("A chat summary runs outside the Inbox, on an old summary and after another device's summary, until its text message is stored; an ordinary summary job stops")
    func chatSummaryRunsUntilItsTextMessage() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        _ = try FolderEpochTestFixture.makeAccount(id: "chat", provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "chat", path: "Sent", role: .sent, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "chat", path: "INBOX", role: .inbox, pool: pool)
        let sent = Self.header("chat-sent", accountId: "chat", folder: "Sent")
        var legacy = Self.header("chat-legacy", accountId: "chat", folder: "INBOX")
        legacy.summaryBlurb = "An old summary."
        var complete = Self.header("chat-complete", accountId: "chat", folder: "INBOX")
        complete.summaryBlurb = "A summary."
        complete.summaryTextMessage = "Its text message."
        let peerChat = Self.header("chat-peer", accountId: "chat", folder: "INBOX")
        let peerOrdinary = Self.header("chat-peer-ordinary", accountId: "chat", folder: "INBOX")
        let rows = [sent, legacy, complete, peerChat, peerOrdinary]
        try await pool.write { db in for row in rows { try row.insert(db) } }
        for row in rows { try await Self.index(row, body: "Let us meet on Tuesday.") }
        let keys = rows.map { ContentKey(rawValue: $0.id) }
        do {
            try await runsUntilTextMessage(sent: sent, legacy: legacy, complete: complete,
                                           peerChat: peerChat, peerOrdinary: peerOrdinary, pool: pool)
        } catch {
            try? await SearchIndex.shared.removeMessages(contentKeys: keys)
            throw error
        }
        try? await SearchIndex.shared.removeMessages(contentKeys: keys)
    }

    private func runsUntilTextMessage(
        sent: MessageHeader, legacy: MessageHeader, complete: MessageHeader,
        peerChat: MessageHeader, peerOrdinary: MessageHeader, pool: DatabasePool
    ) async throws {
        let http = Self.summaryBackend(textMessage: "See you Tuesday.")
        defer { http.close() }
        func row(_ header: MessageHeader) async throws -> MessageHeader? {
            try await pool.read { try MessageHeader.fetchOne($0, key: header.id) }
        }
        func job(_ header: MessageHeader, chat: Bool) -> ActiveAIQueue.AIJob {
            .init(headerId: header.id, accountId: header.accountId, jobType: .summary, windowExempt: true, forChat: chat)
        }
        // Another device (Thunderbird) has a summary of the two peer emails, without a text message.
        let peerKeys: Set<String> = [peerChat.rfc822MessageId!, peerOrdinary.rfc822MessageId!]
            .map { $0.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "") }
            .reduce(into: []) { $0.insert($1) }
        let peer: AIService.PeerProbe = { keys in
            Dictionary(uniqueKeysWithValues: keys.filter { peerKeys.contains($0) }.map { key in
                (key, AICacheResult(
                    summary: AICacheSummary(blurb: "A peer summary.", todos: nil, detailed: nil,
                                            reminderDate: nil, reminderTime: nil, reminderContent: nil),
                    action: nil, reply: nil))
            })
        }

        try await Self.withAIOn {
            let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: peer)
            let queue = ActiveAIQueue()
            await queue.setDispatchSuppressedForTesting(true)

            // An old summary without a text message: finished for an ordinary job, not for a chat job.
            #expect(await queue.jobVerifiedCompleteForTesting(job(legacy, chat: false)))
            #expect(!(await queue.jobVerifiedCompleteForTesting(job(legacy, chat: true))), "retried until its text message")
            await queue.executeWholeJobForTesting(job(legacy, chat: false), aiService: service)
            #expect(http.recordedCalls().isEmpty, "an ordinary job takes the old summary")
            await queue.executeWholeJobForTesting(job(legacy, chat: true), aiService: service)
            #expect(http.recordedCalls().count == 1, "a chat job asks for the text message")
            let legacy1 = try await row(legacy)?.summaryTextMessage

            #expect(legacy1 == "See you Tuesday.")
            #expect(await queue.jobVerifiedCompleteForTesting(job(legacy, chat: true)), "and is finished once it is stored")

            // A summary with its text message: no call for either job.
            await queue.executeWholeJobForTesting(job(complete, chat: true), aiService: service)
            #expect(http.recordedCalls().count == 1, "nothing to ask for")
            #expect(await queue.jobVerifiedCompleteForTesting(job(complete, chat: true)))

            // Outside the Inbox: a chat job runs and writes.
            await queue.executeWholeJobForTesting(job(sent, chat: true), aiService: service)
            #expect(http.recordedCalls().count == 2, "a chat summary of a Sent email calls the model")
            let sent2 = try await row(sent)?.summaryTextMessage

            #expect(sent2 == "See you Tuesday.")
            #expect(await queue.jobVerifiedCompleteForTesting(job(sent, chat: true)), "in any folder")

            // Another device's summary: an ordinary job takes it; a chat job still asks for its text message.
            await queue.executeWholeJobForTesting(job(peerOrdinary, chat: false), aiService: service)
            #expect(http.recordedCalls().count == 2, "an ordinary job takes the peer summary")
            let peerOrdinary3 = try await row(peerOrdinary)?.summaryBlurb

            #expect(peerOrdinary3 == "A peer summary.", "the peer summary was really written")
            await queue.executeWholeJobForTesting(job(peerChat, chat: true), aiService: service)
            #expect(http.recordedCalls().count == 3, "a chat job asks for the text message the peer summary lacks")
            let peerChat4 = try await row(peerChat)?.summaryTextMessage

            #expect(peerChat4 == "See you Tuesday.")
        }
    }

    // MARK: - 5. Waiting chat members are forgotten on cancel

    @Test("A chat member waiting for its body is released by the body, unless the queue was cancelled first",
          arguments: [false, true])
    func cancelForgetsWaitingMembers(cancelFirst: Bool) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        _ = try FolderEpochTestFixture.makeAccount(id: "wait", provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "wait", path: "INBOX", role: .inbox, pool: pool)
        let header = Self.header("wait-body", accountId: "wait", folder: "INBOX", bodyComplete: false)
        try await pool.write { try header.insert($0) }
        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        let asked = Mutex<[String]>([])
        await queue.enqueueChatSummaries([header], requestBodies: { rows in asked.withLock { $0.append(contentsOf: rows.map(\.id)) } })
        #expect(asked.withLock { $0 } == [header.id], "the member waits for its body")
        #expect(await queue.queuedJobsForTesting.isEmpty)

        if cancelFirst { await queue.cancelAllInFlight() }
        await queue.chatBodyArrived(headerId: header.id)
        let released = await queue.queuedJobsForTesting.filter { $0.headerId == header.id }
        #expect(released.count == (cancelFirst ? 0 : 1),
                cancelFirst ? "a cancel forgets the waiting member" : "without a cancel the body releases it")
    }
}
