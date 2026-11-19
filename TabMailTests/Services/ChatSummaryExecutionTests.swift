/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// ADR-IOS-114 decision 8: what a chat summary job really sends and writes, end to end.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. A summary of the user's own email (from one of their addresses, or in a Sent folder) tells
///     the backend so (`is_sent_by_user: true`), so its text message is in the user's voice; any
///     other email's request has no such field.
///  2. (Changed 2026-11-15.) The queue keeps no list of chat members waiting for their body: the
///     shown chat observes its rows and asks again once a body lands, whatever writes it, and after
///     every queue rebuild (`ChatThreadViewLifecycleTests`).
///  3. The executor refuses an ordinary summary outside the Inbox (no model call, nothing written)
///     even when its admission was window-exempt; the same setup in the Inbox calls and writes. It
///     refuses a chat summary of a draft the same way, however the job was queued; a chat summary
///     in Sent calls and writes.
///  4. A chat summary is finished only with its text message, at every site that decides it
///     (`ActiveAIQueue.jobDone`): the executor runs it in any folder, on an old summary without a
///     text message, and after another device's summary (which has none), and `readJobOutcome`
///     retries it after a failed call; an ordinary summary job stops at each of those. A call that
///     completed and wrote a summary but no text message ends the job for the process: such an
///     email costs one model call per process, however often the chat asks and whatever sync starts
///     (launch, push wake) follow, and however often a shown chat checks its rows again after the
///     queue is rebuilt; AI re-enable asks once more; never one every backoff.
///  5. (Removed 2026-11-15, with the list of chat members waiting for their body.)
///  6. A chat summary queued behind a full LLM semaphore waits for a slot and runs as soon as a
///     background call frees one; it is never starved.
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

    /// A backend that answers every summary request with one structured result. Also used by the
    /// hosted chat tests.
    static func summaryBackend(textMessage: String) -> FakeHTTP.Scenario {
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

    static func withAIOn<T>(_ body: () async throws -> T) async rethrows -> T {
        let saved = AIService.optOutStore.object(forKey: AIService.optOutAllAIKey)
        AIService.writeOptOutFlag(false)
        defer { AIService.optOutStore.set(saved, forKey: AIService.optOutAllAIKey) }
        return try await body()
    }

    /// Indexes `header` in the search index, with `body` when given; `nil` leaves it without one.
    static func index(_ header: MessageHeader, body: String?) async throws {
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

    @Test("A chat summary of a draft is refused at the executor, however it was queued: no model call, nothing written")
    func chatSummaryRefusesADraft() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        _ = try FolderEpochTestFixture.makeAccount(id: "draftscope", provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "draftscope", path: "Drafts", role: .drafts, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "draftscope", path: "Sent", role: .sent, pool: pool)
        let draft = Self.header("scope-draft", accountId: "draftscope", folder: "Drafts")
        let sent = Self.header("scope-chat-sent", accountId: "draftscope", folder: "Sent")
        try await pool.write { db in try draft.insert(db); try sent.insert(db) }
        try await Self.index(draft, body: "My unsent words")
        try await Self.index(sent, body: "A body for the admitted job")
        let keys = [ContentKey(rawValue: draft.id), ContentKey(rawValue: sent.id)]
        do {
            try await refusesADraft(draft: draft, sent: sent, pool: pool)
        } catch {
            try? await SearchIndex.shared.removeMessages(contentKeys: keys)
            throw error
        }
        try? await SearchIndex.shared.removeMessages(contentKeys: keys)
    }

    private func refusesADraft(draft: MessageHeader, sent: MessageHeader, pool: DatabasePool) async throws {
        let http = Self.summaryBackend(textMessage: "An actual summary text.")
        defer { http.close() }

        try await Self.withAIOn {
            let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
            let queue = ActiveAIQueue()
            await queue.setDispatchSuppressedForTesting(true)

            await queue.executeWholeJobForTesting(
                .init(headerId: draft.id, accountId: draft.accountId, jobType: .summary, windowExempt: true, forChat: true),
                aiService: service)
            #expect(http.recordedCalls().isEmpty, "the draft's text never reaches the backend")
            let refused = try await pool.read { try MessageHeader.fetchOne($0, key: draft.id) }
            #expect(refused?.summaryBlurb == nil && refused?.summaryTextMessage == nil, "nothing written for a draft")

            await queue.executeWholeJobForTesting(
                .init(headerId: sent.id, accountId: sent.accountId, jobType: .summary, windowExempt: true, forChat: true),
                aiService: service)
            #expect(http.recordedCalls().count == 1, "control: a chat summary in Sent calls the model")
            #expect(try await pool.read { try MessageHeader.fetchOne($0, key: sent.id)?.summaryTextMessage } == "An actual summary text.",
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

    @Test("A chat summary runs outside the Inbox, on an old summary and after another device's summary, and is finished once its text message is stored; an ordinary summary job stops")
    func chatSummaryAsksForItsTextMessage() async throws {
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
            try await asksForTextMessage(sent: sent, legacy: legacy, complete: complete,
                                         peerChat: peerChat, peerOrdinary: peerOrdinary, pool: pool)
        } catch {
            try? await SearchIndex.shared.removeMessages(contentKeys: keys)
            throw error
        }
        try? await SearchIndex.shared.removeMessages(contentKeys: keys)
    }

    private func asksForTextMessage(
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
            #expect(!(await queue.jobVerifiedCompleteForTesting(job(legacy, chat: true))), "not finished without its text message")
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

    @Test("A chat summary whose answer has a summary but no text message costs one model call per process however often the chat asks; AI re-enable asks once more")
    func textlessChatSummaryIsAskedOncePerProcess() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        _ = try FolderEpochTestFixture.makeAccount(id: "textless", provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "textless", path: "Archive", role: .archive, pool: pool)
        // An archived email: a chat summary runs there, and the action job it chains stops at the
        // Inbox check without a call, so every call counted is the summary's.
        let email = Self.header("textless", accountId: "textless", folder: "Archive")
        try await pool.write { try email.insert($0) }
        try await Self.index(email, body: "An image and an invitation.")
        let keys = [ContentKey(rawValue: email.id)]
        do {
            try await askedOncePerProcess(email, pool: pool)
        } catch {
            try? await SearchIndex.shared.removeMessages(contentKeys: keys)
            throw error
        }
        try? await SearchIndex.shared.removeMessages(contentKeys: keys)
    }

    private func askedOncePerProcess(_ email: MessageHeader, pool: DatabasePool) async throws {
        // The model answers with a summary and an empty text message, every time.
        let http = Self.summaryBackend(textMessage: "")
        defer { http.close() }
        try await Self.withAIOn {
            let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
            let queue = ActiveAIQueue()
            await queue.setDispatchSuppressedForTesting(true)
            // The chat asks (an open, its observation and re-checks, a row on screen, a joining
            // email, the walk all ask through the same admission), then the drain runs what is
            // queued and finishes it as it does.
            func askAndDrain() async {
                await queue.enqueueChatSummaries([email])
                for job in await queue.takePendingIntoFlightForTesting() {
                    await queue.executeWholeJobForTesting(job, aiService: service)
                    await queue.finishInFlightForTesting(job)
                }
            }
            for _ in 0..<3 { await askAndDrain() }
            let written = try await pool.read { try MessageHeader.fetchOne($0, key: email.id) }
            #expect(written?.summaryBlurb == "A plan." && written?.summaryTextMessage == nil,
                    "control: the call completed and wrote a summary without a text message")
            #expect(http.recordedCalls().count == 1,
                    "one model call in this process, however often the chat asks: \(http.recordedCalls().count)")

            // AI re-enable (the Settings switch's entry point) asks once more, and again only once.
            await queue.aiReenabled(chatViewActive: true)
            for _ in 0..<3 { await askAndDrain() }
            #expect(http.recordedCalls().count == 2, "one more call after AI re-enable: \(http.recordedCalls().count)")
        }
    }

    @Test("A textless chat answer is not asked again by a later sync start or the shown chat's check after it: a launch and then a push wake cost one summary model call in all")
    func textlessChatSummaryIsNotAskedAgainBySyncStarts() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        _ = try FolderEpochTestFixture.makeAccount(id: "textless-sync", provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "textless-sync", path: "INBOX", role: .inbox, pool: pool)
        // An Inbox email with its body indexed. Its action tag and reply are already made, so the
        // only model call either pass can make is its summary's.
        var email = Self.header("textless-sync", accountId: "textless-sync", folder: "INBOX")
        email.actionTag = ActionTag.none
        email.actionTagSetAt = Date()
        email.cachedReply = "Thanks."
        try await pool.write { [email] db in try email.insert(db) }
        try await Self.index(email, body: "An image and an invitation.")
        let keys = [ContentKey(rawValue: email.id)]
        do {
            try await notAskedAgainBySyncStarts(email, pool: pool)
        } catch {
            try? await SearchIndex.shared.removeMessages(contentKeys: keys)
            throw error
        }
        try? await SearchIndex.shared.removeMessages(contentKeys: keys)
    }

    private func notAskedAgainBySyncStarts(_ email: MessageHeader, pool: DatabasePool) async throws {
        // The model answers with a summary and an empty text message, every time.
        let http = Self.summaryBackend(textMessage: "")
        defer { http.close() }
        try await Self.withAIOn {
            let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
            let queue = ActiveAIQueue()
            await queue.setDispatchSuppressedForTesting(true)
            // One sync start (`SyncScheduler.syncStartup`: launch, foreground return, a push wake)
            // with the chat view on, the shown chat's check after the rebuild (`.aiQueueRebuilt`),
            // then the drain runs what they queued and finishes each job.
            func syncStartAndDrain() async {
                await queue.repopulateFromDatabase(chatViewActive: true)
                await queue.enqueueChatSummaries([email], requestBodies: { _ in })
                for _ in 0..<5 {
                    let jobs = await queue.takePendingIntoFlightForTesting()
                    guard !jobs.isEmpty else { return }
                    for job in jobs {
                        await queue.executeWholeJobForTesting(job, aiService: service)
                        await queue.finishInFlightForTesting(job)
                    }
                }
            }
            await syncStartAndDrain()  // launch
            let written = try await pool.read { try MessageHeader.fetchOne($0, key: email.id) }
            #expect(written?.summaryBlurb == "A plan." && written?.summaryTextMessage == nil,
                    "control: the launch's call completed and wrote a summary without a text message")
            #expect(http.recordedCalls().count == 1, "control: the launch asked once: \(http.recordedCalls().count)")

            await syncStartAndDrain()  // a push wake
            #expect(http.recordedCalls().count == 1,
                    "a push wake in the same process asks no more: \(http.recordedCalls().count) summary calls")
        }
    }

    // MARK: - 6. A chat summary behind a full LLM semaphore

    /// A completions reply whose final event carries `assistant`.
    private static func finalEvent(_ assistant: String) -> FakeHTTP.CannedResponse {
        let final = String(decoding: try! JSONSerialization.data(withJSONObject: ["assistant": assistant]), as: UTF8.self)
        return .bytes(Data("event: final\ndata: \(final)\n\n".utf8), contentType: "text/event-stream")
    }

    private static func eventually(within seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test("A chat summary queued behind a full LLM semaphore runs once a background call frees a slot")
    func chatSummaryBehindAFullSemaphoreRuns() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        _ = try FolderEpochTestFixture.makeAccount(id: "busy", provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "busy", path: "INBOX", role: .inbox, pool: pool)
        let row = Self.header("busy-chat", accountId: "busy", folder: "INBOX")
        try await pool.write { db in try row.insert(db) }
        try await Self.index(row, body: "Let us meet on Tuesday.")
        let key = ContentKey(rawValue: row.id)
        do {
            try await runsBehindAFullSemaphore(row, pool: pool)
        } catch {
            try? await SearchIndex.shared.removeMessages(contentKeys: [key])
            throw error
        }
        try? await SearchIndex.shared.removeMessages(contentKeys: [key])
    }

    private func runsBehindAFullSemaphore(_ row: MessageHeader, pool: DatabasePool) async throws {
        // Every slot is held by a background call the backend answers only when the gate opens.
        let background = "busy-background-call"
        let gate = DispatchSemaphore(value: 0)
        let slots = SyncConfig.maxConcurrentLLMCalls
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let summary = try JSONSerialization.data(withJSONObject: [
            "summary": "A plan.", "todos": [], "reminder": NSNull(), "text_message": "See you Tuesday.",
        ])
        http.register(path: "/completions/chat", method: "POST") { request in
            guard String(decoding: request.body ?? Data(), as: UTF8.self).contains(background) else {
                return Self.finalEvent(String(decoding: summary, as: UTF8.self))
            }
            return .parked { gate.wait(); return Self.finalEvent("Done.") }
        }
        let backend = BackendClient(llmSession: http.session)
        let held = (0..<slots).map { _ in
            Task {
                _ = try? await backend.sendCompletions(CompletionsRequest(
                    messages: [CompletionsMessage(role: "system", content: background, vars: [:])],
                    client_timezone: nil, disable_tools: true))
            }
        }
        #expect(await Self.eventually { http.recordedCalls().count == slots }, "every slot is held")
        func textMessage() async -> String? {
            try? await pool.read { try MessageHeader.fetchOne($0, key: row.id) }?.summaryTextMessage
        }

        try await Self.withAIOn {
            let service = AIService(backendClient: backend, peerProbe: { _ in nil })
            let queue = ActiveAIQueue()
            await queue.setDispatchSuppressedForTesting(true)
            let job = ActiveAIQueue.AIJob(
                headerId: row.id, accountId: row.accountId, jobType: .summary, windowExempt: true, forChat: true)
            let chat = Task { await queue.executeWholeJobForTesting(job, aiService: service) }

            // Behind the full semaphore, the chat summary has not reached the backend.
            try await Task.sleep(for: .milliseconds(300))
            #expect(http.recordedCalls().count == slots, "the chat summary waits for a slot")
            #expect(await textMessage() == nil)

            // One background call is answered: its slot goes to the waiting chat summary.
            gate.signal()
            let ran = await Self.eventually { await textMessage() == "See you Tuesday." }
            #expect(ran, "the chat summary runs once a slot frees")
            #expect(http.recordedCalls().count == slots + 1)

            for _ in 1..<slots { gate.signal() }
            for task in held { await task.value }
            // A starved chat summary never returns; only a run that finished is awaited.
            if ran { await chat.value }
        }
    }
}
