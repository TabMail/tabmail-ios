/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// ADR-IOS-103: every producer of an AI summary or reply stores its text message with it, on the
/// header and in the AI cache, from the reply the backend actually sends (protocol 2.0.0 JSON).
///
/// THE SYSTEM PROPERTIES pinned here, each through the real producer and a fake backend:
///  1. The AI queue's summary and reply jobs and the opened-email direct path write the summary,
///     the reply and both text messages to the header and the cache.
///  2. A backend-valid reply survives decoding: curly and fullwidth quotes inside the JSON strings,
///     and a reply body that is the word "None".
///  3. A filtered reply (a no-reply sender) stores no reply and no text message, and asks nothing.
///  4. A recomputed reply in compose stores its text message; the extension sends the same
///     protocol version as the app and reads the summary JSON the same way.
///  5. A result another device (Thunderbird) already has is stored as it is, with no text
///     message, and asks the model nothing.
///
/// `.processGlobalState`: the AI opt-out flag and `AppDatabase.shared` are process-wide.
@Suite("AI text messages through their producers", .serialized, .processGlobalState)
struct AITextMessageCallerTests {

    static let blurb = "The team wants the \u{201C}final\u{201D} budget by Friday."
    static let summaryText = "Can you send the \u{201C}final\u{201D} budget? \u{FF02}Thanks\u{FF02}"
    static let replyBody = "None"
    static let replyText = "None from me, thanks"
    static let peerBlurb = "Peer summary of the plans."
    static let peerReply = "Peer reply to the plans."

    /// Answers `/completions/chat` by prompt: the summary JSON, an action, the reply JSON.
    final class Backend: Sendable {
        let http = FakeHTTP.Scenario()
        var service: AIService { AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil }) }
        /// The service when another device (Thunderbird) already has this email's AI.
        var peerService: AIService { AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: Self.peer) }

        /// Answers the Device Sync probe as Thunderbird would: a summary, an action and a reply,
        /// and no text message for either.
        static let peer: AIService.PeerProbe = { keys in
            Dictionary(uniqueKeysWithValues: keys.map { key in
                (key, AICacheResult(
                    summary: AICacheSummary(blurb: AITextMessageCallerTests.peerBlurb, todos: nil, detailed: nil,
                                            reminderDate: nil, reminderTime: nil, reminderContent: nil),
                    action: "reply", reply: AITextMessageCallerTests.peerReply))
            })
        }

        init() {
            http.register(path: "/completions/chat", method: "POST") { request in
                let prompt = Self.prompt(request.body)
                let object: [String: Any]
                switch prompt {
                case "system_prompt_summary":
                    object = ["summary": AITextMessageCallerTests.blurb, "todos": [],
                              "reminder": ["due_date": NSNull(), "due_time": NSNull(), "content": NSNull()],
                              "text_message": AITextMessageCallerTests.summaryText]
                case "system_prompt_action":
                    object = ["action": "reply"]
                default:
                    object = ["subject": "Re: Plans", "body": AITextMessageCallerTests.replyBody,
                              "text_message": AITextMessageCallerTests.replyText]
                }
                let assistant = String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
                let final = (try? JSONSerialization.data(withJSONObject: ["assistant": assistant])) ?? Data()
                let stream = "event: final\ndata: " + String(decoding: final, as: UTF8.self) + "\n\n"
                return .bytes(Data(stream.utf8), contentType: "text/event-stream")
            }
        }

        static func prompt(_ body: Data?) -> String? {
            let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            return (json["messages"] as? [[String: Any]])?.first?["content"] as? String
        }

        var prompts: [String] { http.recordedCalls().compactMap { Self.prompt($0.body) } }

        func close() { http.close() }
    }

    /// A database with one account, its inbox, and one email from `fromAddress`.
    struct Fixture {
        let pool: DatabasePool
        let dir: URL
        let previous: AppDatabase?
        let account: Account
        let header: MessageHeader
        let target: AIWriteTarget
        static let rfc = "plans@example.com"

        /// `summarized`: the email already has its summary and action, so opening it asks only
        /// for the reply.
        init(fromAddress: String = "sender@example.com", replyTextMessage: String? = nil, summarized: Bool = false) throws {
            (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
            account = try FolderEpochTestFixture.makeAccount(id: "acc1", provider: .imap, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: "acc1", path: "INBOX", role: .inbox, pool: pool)
            var header = MessageHeader(
                messageId: "1", subject: "Plans", from: "Sender", fromAddress: fromAddress,
                to: "acc1@example.com", date: Date(), snippet: "snippet", folderId: "acc1:INBOX",
                accountId: "acc1", folderPath: "INBOX", isInInbox: true)
            header.rfc822MessageId = Self.rfc
            header.replyTextMessage = replyTextMessage
            if summarized {
                header.summaryBlurb = "An earlier summary."
                header.actionTag = .reply
                header.tagSortOrder = ActionTag.reply.sortOrder
            }
            let toInsert = header
            try pool.write { db in
                try toInsert.insert(db)
                try MessageBody(contentKey: ContentKey(rawValue: toInsert.id), htmlContent: "<p>Can you send the budget?</p>").insert(db)
            }
            self.header = header
            target = try #require(try pool.read { try AIWriteTarget.capture(message: toInsert, db: $0) })
        }

        func close() {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        func row() throws -> MessageHeader? {
            try pool.read { try MessageHeader.fetchOne($0, key: header.id) }
        }

        func cache() throws -> MessageAICache? {
            try pool.read { try MessageAICache.fetchOne($0, key: "acc1:INBOX:\(Self.rfc)") }
        }

        var body: MessageBody {
            get throws { try #require(try pool.read { try MessageBody.fetchOne($0, key: ContentKey(rawValue: header.id)) }) }
        }
    }

    private func withAIEnabled<T>(_ body: () async throws -> T) async rethrows -> T {
        let store = AIService.optOutStore
        let previous = store.object(forKey: AIService.optOutAllAIKey)
        defer {
            if let previous {
                store.set(previous, forKey: AIService.optOutAllAIKey)
            } else {
                store.removeObject(forKey: AIService.optOutAllAIKey)
            }
        }
        AIService.writeOptOutFlag(false)
        return try await body()
    }

    private func runJob(_ type: ActiveAIQueue.AIJob.JobType, _ fixture: Fixture, _ service: AIService) async -> Bool {
        let queue = ActiveAIQueue()
        await queue.setDispatchSuppressedForTesting(true)
        return await queue.executeJobForTesting(
            ActiveAIQueue.AIJob(headerId: fixture.header.id, accountId: "acc1", jobType: type),
            message: fixture.header, plainText: "Can you send the budget?", account: fixture.account,
            target: fixture.target, aiService: service)
    }

    // MARK: - 1 and 2. The AI queue

    @Test("The queue's summary job stores the summary and its text message, quotes intact")
    func queueSummaryJob() async throws {
        try await withAIEnabled {
            let fixture = try Fixture()
            let backend = Backend()
            defer { backend.close(); fixture.close() }

            let retry = await runJob(.summary, fixture, backend.service)

            #expect(!retry)
            #expect(backend.prompts == ["system_prompt_summary"])
            let row = try fixture.row()
            #expect(row?.summaryBlurb == Self.blurb)
            #expect(row?.summaryTextMessage == Self.summaryText)
            let cache = try fixture.cache()
            #expect(cache?.summaryBlurb == Self.blurb)
            #expect(cache?.summaryTextMessage == Self.summaryText)
            #expect(cache?.rfc822MessageId == Fixture.rfc)
        }
    }

    @Test("The queue's reply job stores the reply and its text message; a body of \"None\" is a reply")
    func queueReplyJob() async throws {
        try await withAIEnabled {
            let fixture = try Fixture()
            let backend = Backend()
            defer { backend.close(); fixture.close() }

            let retry = await runJob(.reply, fixture, backend.service)

            #expect(!retry)
            #expect(backend.prompts == ["system_prompt_compose"])
            let row = try fixture.row()
            #expect(row?.cachedReply == Self.replyBody)
            #expect(row?.replyTextMessage == Self.replyText)
            let cache = try fixture.cache()
            #expect(cache?.cachedReply == Self.replyBody)
            #expect(cache?.replyTextMessage == Self.replyText)
        }
    }

    @Test("A filtered reply stores no reply and no text message, and asks the backend nothing")
    func queueReplyFiltered() async throws {
        try await withAIEnabled {
            let fixture = try Fixture(fromAddress: "noreply@example.com", replyTextMessage: "stale")
            let backend = Backend()
            defer { backend.close(); fixture.close() }

            _ = await runJob(.reply, fixture, backend.service)

            #expect(backend.prompts.isEmpty)
            let row = try fixture.row()
            #expect(row?.cachedReply == "")
            #expect(row?.replyTextMessage == nil)
            #expect(try fixture.cache()?.cachedReply == nil)
        }
    }

    // MARK: - 1. The opened-email direct path

    @Test("Opening an email stores its summary, reply and both text messages")
    func directPath() async throws {
        try await withAIEnabled {
            let fixture = try Fixture()
            let backend = Backend()
            defer { backend.close(); fixture.close() }

            await AccountManager.shared.processMessage(
                fixture.header, body: try fixture.body, account: fixture.account,
                target: fixture.target, aiService: backend.service)

            // The direct path runs detached; wait for both writes, bounded.
            let deadline = Date().addingTimeInterval(20)
            var row = try fixture.row()
            while (row?.summaryTextMessage == nil || row?.replyTextMessage == nil), Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
                row = try fixture.row()
            }
            #expect(row?.summaryBlurb == Self.blurb)
            #expect(row?.summaryTextMessage == Self.summaryText)
            #expect(row?.cachedReply == Self.replyBody)
            #expect(row?.replyTextMessage == Self.replyText)
            let cache = try fixture.cache()
            #expect(cache?.summaryTextMessage == Self.summaryText)
            #expect(cache?.replyTextMessage == Self.replyText)
            #expect(Set(backend.prompts) == ["system_prompt_summary", "system_prompt_action", "system_prompt_compose"])
        }
    }

    @Test("Opening a summarized email stores only its reply and the reply's text message")
    func directPathReplyOnly() async throws {
        try await withAIEnabled {
            let fixture = try Fixture(summarized: true)
            let backend = Backend()
            defer { backend.close(); fixture.close() }

            await AccountManager.shared.processMessage(
                fixture.header, body: try fixture.body, account: fixture.account,
                target: fixture.target, aiService: backend.service)

            // The direct path runs detached; wait for the reply write, bounded.
            let deadline = Date().addingTimeInterval(20)
            var cache = try fixture.cache()
            while cache?.replyTextMessage == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
                cache = try fixture.cache()
            }
            #expect(backend.prompts == ["system_prompt_compose"])
            #expect(cache?.cachedReply == Self.replyBody)
            #expect(cache?.replyTextMessage == Self.replyText)
            let row = try fixture.row()
            #expect(row?.cachedReply == Self.replyBody)
            #expect(row?.replyTextMessage == Self.replyText)
            #expect(row?.summaryBlurb == "An earlier summary.")
        }
    }

    // MARK: - 5. A result from another device

    @Test("Opening an email another device already summarized stores its results, with no text message and no model call")
    func directPathPeerResult() async throws {
        try await withAIEnabled {
            let fixture = try Fixture()
            let backend = Backend()
            defer { backend.close(); fixture.close() }

            await AccountManager.shared.processMessage(
                fixture.header, body: try fixture.body, account: fixture.account,
                target: fixture.target, aiService: backend.peerService)

            // The direct path runs detached; wait for both writes, bounded.
            let deadline = Date().addingTimeInterval(20)
            var row = try fixture.row()
            while (row?.summaryBlurb == nil || row?.cachedReply == nil), Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
                row = try fixture.row()
            }
            #expect(row?.summaryBlurb == Self.peerBlurb)
            #expect(row?.summaryTextMessage == nil)
            #expect(row?.cachedReply == Self.peerReply)
            #expect(row?.replyTextMessage == nil)
            let cache = try fixture.cache()
            #expect(cache?.summaryBlurb == Self.peerBlurb)
            #expect(cache?.summaryTextMessage == nil)
            #expect(cache?.cachedReply == Self.peerReply)
            #expect(cache?.replyTextMessage == nil)
            #expect(backend.prompts.isEmpty)
        }
    }

    @Test("The queue's reply job stores another device's reply with no text message and no model call")
    func queueReplyPeerResult() async throws {
        try await withAIEnabled {
            let fixture = try Fixture(replyTextMessage: "stale")
            let backend = Backend()
            defer { backend.close(); fixture.close() }

            let retry = await runJob(.reply, fixture, backend.peerService)

            #expect(!retry)
            #expect(backend.prompts.isEmpty)
            let row = try fixture.row()
            #expect(row?.cachedReply == Self.peerReply)
            #expect(row?.replyTextMessage == nil)
            let cache = try fixture.cache()
            #expect(cache?.cachedReply == Self.peerReply)
            #expect(cache?.replyTextMessage == nil)
        }
    }

    // MARK: - 4. Compose and the extension

    @Test("Recomputing a reply in compose stores the reply and its text message")
    func composeRecompute() async throws {
        try await withAIEnabled {
            let fixture = try Fixture(replyTextMessage: "Earlier text")
            let backend = Backend()
            defer { backend.close(); fixture.close() }

            let suggestion = await ComposeView.recomputedReply(
                for: fixture.header, account: fixture.account, kbText: "", compositionPrompt: "",
                aiService: backend.service, dbPool: AppDatabase.dbPool)

            #expect(suggestion == Self.replyBody)
            #expect(backend.prompts == ["system_prompt_compose"])
            let row = try fixture.row()
            #expect(row?.cachedReply == Self.replyBody)
            #expect(row?.replyTextMessage == Self.replyText)
        }
    }

    @Test("The extension sends the app's protocol version and returns the summary the app would read")
    func extensionRequest() async throws {
        let seen = Mutex<URLRequest?>(nil)
        let summary = #"{"summary":"\#(Self.blurb)","todos":[],"reminder":{"due_date":null,"due_time":null,"content":null},"text_message":"\#(Self.summaryText)"}"#
        let final = try JSONSerialization.data(withJSONObject: ["assistant": summary])
        let stream = Data(("event: final\ndata: " + String(decoding: final, as: UTF8.self) + "\n\n").utf8)

        let response = await BackendNSEClient.$transport.withValue({ request in
            seen.withLock { $0 = request }
            return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }) {
            await BackendNSEClient.sendCompletions(
                promptAlias: "system_prompt_summary", variables: BackendNSEClient.Vars([:]),
                authToken: "synthetic-token")
        }

        let request = try #require(seen.withLock { $0 })
        #expect(request.value(forHTTPHeaderField: "X-Client-Version") == "2.0.0")
        #expect(request.value(forHTTPHeaderField: "X-Client-Version") == BackendClient.clientVersion)
        #expect(request.url?.path == "/completions/chat")
        let parsed = NSEResponseParser.parseSummary(try #require(response?.assistant))
        #expect(parsed.blurb == Self.blurb)
        #expect(parsed.textMessage == Self.summaryText)
    }

}
