/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// A reply sent from the chat, from the queue write to its email in the chat (owner 2026-11-07),
/// through the real outbox, AI cache, send path and hosted chat.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The queued email has its own Message-ID from the queue write, and the send uses it.
///  2. The summary made at Send is the email's own: written under its Sent folder and Message-ID,
///     its Sent copy shows it, and no other email does, even one in Sent without a summary.
///  3. The chat shows the reply from the queue write: "Summarizing" and "Sending", the summary as
///     soon as it is made while still sending, and once the email is in the chat it shows that
///     same summary with no second bubble.
///  4. The bubble follows its own outbox row: "Sent" once the provider took the email, kept after
///     the row is filed until the email is in the chat; Undo of an unsent row removes it; a failed
///     send says "Not sent". Another reply of the user's to the same email never ends it.
///  5. The wiring: a sent compose card reports its queued email's outbox row, and a queued (not
///     deduplicated) send summarizes at once only with the chat view on and AI allowed. Read from
///     the source: the compose card and the queue write cannot be driven from a unit test.
@Suite("Sending bubble", .serialized, .processGlobalState)
@MainActor
struct ChatSendingBubbleTests {
    nonisolated private static let account = "acc-sending"

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

    /// The chat's item for `header`, written by the user.
    private static func ownItem(_ header: MessageHeader) -> ChatThread.Item {
        ChatThread(
            members: [header], replyAddresses: { [$0.fromAddress] }, ownAddresses: [header.fromAddress],
            draftFolderIds: [], sentFolderIds: [], unreadAtOpen: [], preferredId: nil
        ).items[0]
    }

    private struct Fixture {
        let pool: DatabasePool
        let account: Account
        let parent: MessageHeader
    }

    private static func header(_ id: String, folder: String, from: String, inReplyTo: String? = nil) -> MessageHeader {
        var header = MessageHeader(
            messageId: id, subject: "Lunch plans", from: from, fromAddress: from, to: "someone@example.com",
            date: Date().addingTimeInterval(-600), snippet: "Note \(id)",
            folderId: MessageIdentity.folderId(accountId: account, folderPath: folder),
            accountId: account, folderPath: folder, isInInbox: folder == "INBOX")
        header.rfc822MessageId = "\(id)@example.com"
        header.inReplyTo = inReplyTo
        header.headerComplete = true
        header.bodyComplete = true
        header.isRead = true
        return header
    }

    private static func makeFixture(_ pool: DatabasePool) async throws -> Fixture {
        let account = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "Sent", role: .sent, pool: pool)
        let parent = header("sending-parent", folder: "INBOX", from: "sender@example.com")
        try await pool.write { db in try parent.insert(db) }
        return Fixture(pool: pool, account: account, parent: parent)
    }

    /// Queues a reply to the parent as the compose card does, and returns its outbox row.
    private static func queueReply(_ fixture: Fixture, draftId: String, holdsForUndo: Bool) async throws -> OutboxMessage {
        try await fixture.pool.write { db in
            var draft = Draft(
                id: draftId, accountId: Self.account, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Re: Lunch plans", body: "Tuesday works", replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        let queued = try await AccountManager.persistQueuedSend(
            draft: DraftMessage(to: ["sender@example.com"], subject: "Re: Lunch plans", body: "Tuesday works for me.",
                                inReplyTo: fixture.parent.rfc822MessageId),
            accountId: Self.account, replyToHeaderId: fixture.parent.id, isForward: false, serverDraftId: nil,
            draftId: draftId, instanceEpoch: "E1", holdsForUndo: holdsForUndo)
        return try #require(try await fixture.pool.read { try OutboxMessage.fetchOne($0, key: queued.outboxId) })
    }

    /// Claims and sends the row through the real send path with a mock provider.
    private static func send(_ row: OutboxMessage) async throws -> MockEmailProvider {
        #expect(await AccountManager.shared.atomicClaimForTesting(row), "control: the row is claimed")
        let claimed = try #require(try await AppDatabase.dbPool.read { try OutboxMessage.fetchOne($0, key: row.id) })
        let provider = MockEmailProvider()
        await TestProviderRegistry.withRegisteredProvider(accountId: Self.account, provider: provider) {
            await AccountManager.shared.sendClaimedOutboxMessageForTesting(claimed, messageId: try! #require(claimed.sentMessageId))
        }
        return provider
    }

    private static func sentHeaders(_ pool: DatabasePool) async throws -> [MessageHeader] {
        try await pool.read { db in
            try MessageHeader.filter(Column("folderPath") == "Sent").fetchAll(db)
        }
    }

    // MARK: - 1, 2. The summary at Send

    @Test("The summary made at Send is the queued email's own: its Sent copy shows it, no other email does")
    func summaryAtSendIsTheEmailsOwn() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let fixture = try await Self.makeFixture(pool)
        let row = try await Self.queueReply(fixture, draftId: "draft-own", holdsForUndo: false)
        let messageId = try #require(row.sentMessageId, "the queued email has its Message-ID from the queue write")
        // Another email of the user's in Sent, not summarized: another device's, or an older one.
        let other = Self.header("sent-elsewhere", folder: "Sent", from: fixture.account.emailAddress,
                                inReplyTo: fixture.parent.rfc822MessageId)
        try await pool.write { db in try other.insert(db) }

        let http = Self.summaryBackend(textMessage: "I said Tuesday works.")
        defer { http.close() }
        await SentEmailSummary.summarize(
            outboxId: row.id,
            aiService: AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil }))
        let calls = http.recordedCalls()
        #expect(calls.count == 1, "one summary call at Send")
        let body = try #require(calls.first?.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let first = try #require((object["messages"] as? [[String: Any]])?.first)
        #expect(first["is_sent_by_user"] as? Bool == true, "summarized as the user's own email")

        let provider = try await Self.send(row)
        #expect(await provider.sentDrafts.first?.messageId == messageId, "the send uses the Message-ID of the queue write")
        let sent = try await Self.sentHeaders(pool)
        let copy = try #require(sent.first { $0.rfc822MessageId == EmailFilter.normalizeMessageId(messageId) },
                                "control: the Sent copy is there: \(sent.map(\.rfc822MessageId))")
        #expect(copy.summaryTextMessage == "I said Tuesday works.", "the sent email's first row shows the summary made at Send")
        #expect(sent.first { $0.id == other.id }?.summaryBlurb == nil, "another email never gets it")
    }

    @Test("A Sent copy that arrives before the summary returns takes it when it does")
    func lateSummaryReachesTheSentCopy() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let fixture = try await Self.makeFixture(pool)
        let row = try await Self.queueReply(fixture, draftId: "draft-late", holdsForUndo: false)

        // The backend holds its answer until the email has gone out and its Sent copy is in.
        let asked = DispatchSemaphore(value: 0)
        let answer = DispatchSemaphore(value: 0)
        let http = FakeHTTP.Scenario()
        http.register(path: "/completions/chat", method: "POST") { _ in
            asked.signal()
            answer.wait()
            let object: [String: Any] = ["summary": "A plan.", "todos": [], "reminder": NSNull(), "text_message": "I said Tuesday works."]
            let assistant = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let final = String(decoding: try! JSONSerialization.data(withJSONObject: ["assistant": assistant]), as: UTF8.self)
            return .bytes(Data("event: final\ndata: \(final)\n\n".utf8), contentType: "text/event-stream")
        }
        defer { http.close() }
        let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        let summarizing = Task { await SentEmailSummary.summarize(outboxId: row.id, aiService: service) }
        let wasAsked = await Task.detached { Self.waited(for: asked) }.value
        #expect(wasAsked, "control: the summary was asked at Send")

        _ = try await Self.send(row)
        #expect(try await Self.sentHeaders(pool).map(\.summaryBlurb) == [nil], "control: the copy arrived unsummarized")
        answer.signal()
        await summarizing.value
        #expect(try await Self.sentHeaders(pool).map(\.summaryTextMessage) == ["I said Tuesday works."])
    }

    /// Waits on `semaphore` off the main actor, up to ten seconds.
    nonisolated private static func waited(for semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 10) == .success
    }

    // MARK: - 4. The bubble follows its outbox row

    @Test("The bubble follows its own outbox row: Sending, Sent, kept until its email is in the chat; Undo removes it; a failed send says Not sent")
    func bubbleFollowsItsOutboxRow() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let replies = ChatSentReplies()
        defer {
            replies.removeAllForTesting()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        let fixture = try await Self.makeFixture(pool)
        func waitFor(_ done: () -> Bool) async throws {
            for _ in 0..<50 where !done() { try await Task.sleep(for: .milliseconds(100)) }
        }

        let row = try await Self.queueReply(fixture, draftId: "draft-follow", holdsForUndo: true)
        #expect(replies.composeEnded(.sent(outboxId: row.id), replyTo: fixture.parent), "the field empties")
        try await waitFor { replies.progress[row.id] != nil }
        #expect(replies.progress[row.id]?.caption == "Sending")
        #expect(replies.progress[row.id]?.textMessage == nil, "Summarizing until the summary is made")

        let messageId = try #require(row.sentMessageId)
        try await pool.write { db in
            try MessageAICache.writeThrough(
                accountId: Self.account, folderPath: "Sent", rfc822MessageId: EmailFilter.normalizeMessageId(messageId),
                summaryBlurb: "A plan.", summaryTextMessage: "I said Tuesday works.", db: db)
        }
        try await waitFor { replies.progress[row.id]?.textMessage != nil }
        #expect(replies.progress[row.id]?.textMessage == "I said Tuesday works.", "the summary shows while still sending")
        #expect(replies.progress[row.id]?.caption == "Sending")

        try await pool.write { db in try db.execute(sql: "UPDATE outboxMessage SET sentAt = ? WHERE id = ?", arguments: [Date(), row.id]) }
        try await waitFor { replies.progress[row.id]?.caption == "Sent" }
        #expect(replies.progress[row.id]?.caption == "Sent", "Sent once the provider took it")
        _ = try await pool.write { db in try OutboxMessage.deleteOne(db, key: row.id) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(replies.entries.map(\.id) == [row.id], "a filed row keeps its bubble until the email is in the chat")

        // Another reply of the user's to the same email, from this send's time: not this email.
        let another = Self.header("sent-another", folder: "Sent", from: fixture.account.emailAddress,
                                  inReplyTo: fixture.parent.rfc822MessageId)
        replies.settle([Self.ownItem(another)])
        #expect(replies.entries.map(\.id) == [row.id], "another email of the user's never ends it")
        var copy = another
        copy.rfc822MessageId = EmailFilter.normalizeMessageId(messageId)
        replies.settle([Self.ownItem(copy)])
        #expect(replies.entries.isEmpty, "its own email ends it")

        // Undo of an unsent row removes its bubble.
        let undone = try await Self.queueReply(fixture, draftId: "draft-undo", holdsForUndo: true)
        replies.composeEnded(.sent(outboxId: undone.id), replyTo: fixture.parent)
        try await waitFor { replies.progress[undone.id] != nil }
        #expect(AccountManager.shared.discardOutboxMessageConfirmed(undone.id), "control: Undo cancelled the send")
        try await waitFor { replies.entries.isEmpty }
        #expect(replies.entries.isEmpty, "Undo removes the bubble")

        // A failed send says so.
        let failed = try await Self.queueReply(fixture, draftId: "draft-failed", holdsForUndo: true)
        replies.composeEnded(.sent(outboxId: failed.id), replyTo: fixture.parent)
        try await pool.write { db in
            try db.execute(sql: "UPDATE outboxMessage SET status = ? WHERE id = ?", arguments: [OutboxStatus.failed.rawValue, failed.id])
        }
        try await waitFor { replies.progress[failed.id]?.caption == "Not sent" }
        #expect(replies.progress[failed.id]?.caption == "Not sent")
    }

    // MARK: - 3. In the chat

    @Test("The chat shows a sent reply from the queue write, its summary while still sending, and then the email itself with the same summary and no second bubble")
    func sendingBubbleHandsOver() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation { try await sendingBubbleHandsOverBody() }
    }

    private func sendingBubbleHandsOverBody() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        let replies = ChatSentReplies.shared
        replies.removeAllForTesting()
        defer {
            replies.removeAllForTesting()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        let fixture = try await Self.makeFixture(pool)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: NavigationStack { ChatThreadView(messageId: fixture.parent.id) })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func labels() -> [String] { HostedAccessibility.labels(in: controller.view) }
        func count(_ words: String) -> Int { labels().filter { $0.contains(words) }.count }
        func waitFor(_ done: () -> Bool) async throws {
            for _ in 0..<80 where !done() { try await Task.sleep(for: .milliseconds(100)) }
        }
        try await waitFor { count("Lunch plans") > 0 }

        let row = try await Self.queueReply(fixture, draftId: "draft-chat", holdsForUndo: false)
        replies.composeEnded(.sent(outboxId: row.id), replyTo: fixture.parent)
        try await waitFor { count("You said: summarizing") == 1 && count("Sending") == 1 }
        #expect(count("You said: summarizing") == 1 && count("Sending") == 1,
                "from the queue write: Summarizing, Sending: \(labels().prefix(20))")

        let text = "I said Tuesday works."
        let http = Self.summaryBackend(textMessage: text)
        defer { http.close() }
        await SentEmailSummary.summarize(
            outboxId: row.id,
            aiService: AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil }))
        try await waitFor { count(text) == 1 }
        #expect(count(text) == 1 && count("Sending") == 1, "the summary shows while still sending: \(labels().prefix(20))")

        _ = try await Self.send(row)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
        try await waitFor { replies.entries.isEmpty }
        #expect(replies.entries.isEmpty, "control: the email reached the chat")
        try await waitFor { count("Sending") == 0 }
        #expect(count(text) == 1, "the email shows the same summary, once: \(labels().prefix(20))")
        #expect(count("Sending") == 0 && count("Summarizing") == 0 && count("You said: summarizing") == 0,
                "no second bubble and no flash back: \(labels().prefix(20))")
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
    }

    // MARK: - 5. Wiring

    private static func source(_ path: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("A sent compose card reports its outbox row, and only a new queued send summarizes, only with the chat view on and AI allowed")
    func summaryAtSendWiring() throws {
        let compose = try Self.source("TabMail/Views/Compose/ComposeView.swift")
        #expect(Self.count("onAgentOutcome?(.sent(outboxId: queued.outboxId))", in: compose) == 1)
        #expect(Self.count("onAgentOutcome?(.sent", in: compose) == 1, "no other sent report")

        let outbox = try Self.source("TabMail/Services/Account/AccountManagerOutbox.swift")
        #expect(Self.count("if !result.deduped { Task { await AppDatabase.checkpointForDurability() } "
            + "// The chat view summarizes the email now, for its Sending bubble and its Sent copy. "
            + "let outboxId = result.outboxId Task { guard await SentEmailSummary.mayRun() else { return } "
            + "await SentEmailSummary.summarize(outboxId: outboxId) } }", in: outbox) == 1)
        #expect(Self.count("SentEmailSummary.summarize(", in: outbox) == 1, "nothing else summarizes at Send")

        let summary = try Self.source("TabMail/Services/AI/SentEmailSummary.swift")
        #expect(Self.count("ChatViewConfig.opensInChat && TabMailAuthService.hasSession() "
            + "&& UserDefaults.standard.bool(forKey: AgeAndTermsConsent.completedKey) "
            + "&& !AIService.optOutStore.bool(forKey: AIService.optOutAllAIKey) "
            + "&& AISubscriptionGate.shared.isActive", in: summary) == 1)
    }
}
