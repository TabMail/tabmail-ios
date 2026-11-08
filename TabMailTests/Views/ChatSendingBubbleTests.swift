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
///     send says "Not sent". Another reply of the user's to the same email never ends it. A filed
///     row whose Message-ID no email carries any more ends it: with a provider that files its own
///     copy under a Message-ID of its own (Outlook) the bubble ends, with no chat on screen, and is
///     not the user's turn. A reply sent from another account than the email it answers (compose's
///     From) is found in that account: its bubble stays until the chat shows it.
///  5. The wiring: a sent compose card reports its queued email's outbox row, and a queued (not
///     deduplicated) send summarizes at once, through the real `queueSend`, only with the chat view
///     on and AI allowed. The gate is driven through each of its real inputs; the compose card
///     cannot be driven from a unit test, so its trigger is read from the source.
///  6. A send that failed for good shows the red mark beside its bubble (owner 2026-11-07); the
///     mark's Retry puts the same outbox row back in the queue and the bubble back to "Sending",
///     and its Delete removes the row and the bubble. Driven through the hosted chat's own actions.
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

    /// The server's listing of `header`, as a Sent folder sync reads it.
    private static func serverInfo(_ header: MessageHeader) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: header.messageId, rfc822MessageId: header.rfc822MessageId,
            inReplyTo: header.inReplyTo, references: [], threadId: nil,
            subject: header.subject, from: header.from, fromAddress: header.fromAddress, to: header.to, cc: "", bcc: "",
            replyTo: nil, date: header.date, snippet: header.snippet, isRead: true,
            isFlagged: false, hasAttachments: false, isReplied: false, isForwarded: false, actionTag: nil)
    }

    /// Claims and sends the row through the real send path with a mock provider. The provider's
    /// Sent folder then lists the sent email under its own server id, plus `alsoListed`, as a
    /// server does after the append: the send's own Sent folder sync runs on its own schedule and
    /// replaces the optimistic copy with that one, so the tests hold whichever copy is there.
    private static func send(_ row: OutboxMessage, alsoListed: [MessageHeader] = []) async throws -> MockEmailProvider {
        #expect(await AccountManager.shared.atomicClaimForTesting(row), "control: the row is claimed")
        let claimed = try #require(try await AppDatabase.dbPool.read { try OutboxMessage.fetchOne($0, key: row.id) })
        let provider = MockEmailProvider()
        var serverCopy = Self.header("server-\(row.id)", folder: "Sent", from: "me@example.com", inReplyTo: row.inReplyTo.map(EmailFilter.normalizeMessageId))
        serverCopy.rfc822MessageId = claimed.sentMessageId.map(EmailFilter.normalizeMessageId)
        serverCopy.subject = row.subject
        await provider.setFetchMessagesResult([Self.serverInfo(serverCopy)] + alsoListed.map(Self.serverInfo))
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

        let provider = try await Self.send(row, alsoListed: [other])
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
        let final = try await Self.sentHeaders(pool)
        #expect(final.map(\.summaryTextMessage) == ["I said Tuesday works."],
                "Sent copies: \(final.map { "\($0.id) \($0.rfc822MessageId ?? "-") \($0.summaryBlurb ?? "-")" })")
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

        // Filed as the send files it: its Sent copy, under its own Message-ID, is written first.
        let copy: MessageHeader = {
            var header = Self.header("sent-\(row.id)", folder: "Sent", from: fixture.account.emailAddress,
                                     inReplyTo: fixture.parent.rfc822MessageId)
            header.rfc822MessageId = EmailFilter.normalizeMessageId(messageId)
            return header
        }()
        try await pool.write { db in try copy.insert(db) }
        _ = try await pool.write { db in try OutboxMessage.deleteOne(db, key: row.id) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(replies.entries.map(\.id) == [row.id], "a filed row keeps its bubble until the email is in the chat")

        // Another reply of the user's to the same email, from this send's time: not this email.
        let another = Self.header("sent-another", folder: "Sent", from: fixture.account.emailAddress,
                                  inReplyTo: fixture.parent.rfc822MessageId)
        replies.settle([Self.ownItem(another)])
        #expect(replies.entries.map(\.id) == [row.id], "another email of the user's never ends it")
        replies.settle([Self.ownItem(copy)])
        #expect(replies.entries.isEmpty, "its own email ends it")

        // The provider filed its own copy under a Message-ID of its own, and the Sent sync replaced
        // ours: no email carries ours any more, so the bubble ends with no chat on screen.
        let replaced = try await Self.queueReply(fixture, draftId: "draft-replaced", holdsForUndo: true)
        replies.composeEnded(.sent(outboxId: replaced.id), replyTo: fixture.parent)
        try await waitFor { replies.progress[replaced.id] != nil }
        try await pool.write { db in try db.execute(sql: "UPDATE outboxMessage SET sentAt = ? WHERE id = ?", arguments: [Date(), replaced.id]) }
        try await waitFor { replies.progress[replaced.id]?.caption == "Sent" }
        let oursId = EmailFilter.normalizeMessageId(try #require(replaced.sentMessageId))
        let ours: MessageHeader = {
            var header = Self.header("sent-\(replaced.id)", folder: "Sent", from: fixture.account.emailAddress,
                                     inReplyTo: fixture.parent.rfc822MessageId)
            header.rfc822MessageId = oursId
            return header
        }()
        try await pool.write { db in try ours.insert(db) }
        _ = try await pool.write { db in try OutboxMessage.deleteOne(db, key: replaced.id) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(replies.entries.map(\.id) == [replaced.id], "control: filed with its copy there, the bubble is kept")
        _ = try await pool.write { db in try MessageHeader.deleteOne(db, key: ours.id) }
        try await waitFor { replies.entries.isEmpty }
        #expect(replies.entries.isEmpty, "no email carries its Message-ID any more: its bubble ends")

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
        let sentNow = try await Self.sentHeaders(pool).map { "\($0.id) \($0.rfc822MessageId ?? "-")" }
        #expect(replies.entries.isEmpty, "control: the email reached the chat; progress \(replies.progress), Sent copies \(sentNow)")
        try await waitFor { count("Sending") == 0 }
        #expect(count(text) == 1, "the email shows the same summary, once: \(labels().prefix(20))")
        #expect(count("Sending") == 0 && count("Summarizing") == 0 && count("You said: summarizing") == 0,
                "no second bubble and no flash back: \(labels().prefix(20))")
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
    }

    /// A provider that files the sent email in Sent under a Message-ID of its own, as Outlook's
    /// sendMail does, and one that keeps ours. No chat is on screen while the email goes out. Once
    /// the email is in Sent, the chat holds it, so no bubble may be left for it and it may not be
    /// the user's turn.
    @Test("A reply's bubble ends once its email is in Sent, also when the provider files it under a Message-ID of its own",
          arguments: [true, false])
    func bubbleEndsWhateverIdTheProviderFilesUnder(providerAssigned: Bool) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let replies = ChatSentReplies()
        defer {
            replies.removeAllForTesting()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        let fixture = try await Self.makeFixture(pool)
        func waitFor(_ done: () -> Bool) async throws {
            for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(100)) }
        }
        let row = try await Self.queueReply(fixture, draftId: "draft-provider-id", holdsForUndo: false)
        let ours = EmailFilter.normalizeMessageId(try #require(row.sentMessageId))
        #expect(replies.composeEnded(.sent(outboxId: row.id), replyTo: fixture.parent))
        try await waitFor { replies.progress[row.id] != nil }
        #expect(replies.progress[row.id]?.caption == "Sending", "control: the bubble follows the queued email")

        #expect(await AccountManager.shared.atomicClaimForTesting(row), "control: the row is claimed")
        let claimed = try #require(try await AppDatabase.dbPool.read { try OutboxMessage.fetchOne($0, key: row.id) })
        let provider = MockEmailProvider()
        var serverCopy = Self.header("server-\(row.id)", folder: "Sent", from: fixture.account.emailAddress,
                                     inReplyTo: fixture.parent.rfc822MessageId)
        serverCopy.rfc822MessageId = providerAssigned ? "provider-assigned-\(row.id)@example.com" : ours
        serverCopy.subject = row.subject
        serverCopy.date = Date()
        await provider.setFetchMessagesResult([Self.serverInfo(serverCopy)])
        let sentFolder = try #require(try await pool.read { db in
            try Folder.filter(Column("accountId") == Self.account && Column("role") == FolderRole.sent.rawValue).fetchOne(db)
        })
        try await TestProviderRegistry.withRegisteredProvider(accountId: Self.account, provider: provider) {
            await AccountManager.shared.sendClaimedOutboxMessageForTesting(claimed, messageId: try! #require(claimed.sentMessageId))
            // The post-send Sent folder sync, run here so the test does not race the send's own.
            try await SyncEngine().syncFolderMessages(folder: sentFolder, provider: provider)
        }
        let sent = try await Self.sentHeaders(pool)
        let copy = try #require(sent.first { $0.rfc822MessageId == serverCopy.rfc822MessageId },
                                "control: the provider's copy is in Sent: \(sent.map(\.rfc822MessageId))")
        #expect(sent.contains { $0.rfc822MessageId == ours } == !providerAssigned,
                "control: an email in Sent carries our Message-ID only when the provider kept it: \(sent.map(\.rfc822MessageId))")
        #expect(try await pool.read { try OutboxMessage.fetchOne($0, key: row.id) } == nil, "control: the row was filed")

        if providerAssigned {
            // No email carries ours any more: the bubble ends with no chat on screen.
            try await waitFor { replies.entries.isEmpty }
            #expect(replies.entries.isEmpty, "the provider's copy is the email, so its bubble ended: \(replies.entries.map(\.id)) \(replies.progress)")
        }
        // As the chat view computes it once it holds the email (pendingReplies, then
        // unmatchedReplies): any left would be shown under the email and taken as the user's turn.
        let chatIds = Set([fixture.parent.rfc822MessageId, copy.rfc822MessageId].compactMap { $0 })
        let unmatched = replies.entries(accountId: Self.account, messageIds: chatIds)
            .filter { !replies.isInChat($0, items: [Self.ownItem(copy)]) }
        #expect(unmatched.isEmpty, "no Sent bubble and not the user's turn: \(unmatched.map(\.id))")
        replies.settle([Self.ownItem(copy)])
        #expect(replies.entries.isEmpty, "a chat showing the email ends its bubble")
    }

    @Test("A reply sent from another account than the email it answers keeps its bubble until its email is in the chat")
    func bubbleFollowsAReplyFromAnotherAccount() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let replies = ChatSentReplies()
        defer {
            replies.removeAllForTesting()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        let fixture = try await Self.makeFixture(pool)
        // Compose's From picker chose the user's other account.
        let from = "acc-sending-from"
        _ = try FolderEpochTestFixture.makeAccount(id: from, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: from, path: "Sent", role: .sent, pool: pool)
        func queue(_ draftId: String) async throws -> OutboxMessage {
            try await pool.write { db in
                var draft = Draft(
                    id: draftId, accountId: from, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                    subject: "Re: Lunch plans", body: "Tuesday works", replyToId: nil, isForward: false,
                    editHistoryJSON: nil, createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
                draft.instanceEpoch = "E1"
                try draft.insert(db)
            }
            let queued = try await AccountManager.persistQueuedSend(
                draft: DraftMessage(to: ["sender@example.com"], subject: "Re: Lunch plans", body: "Tuesday works for me.",
                                    inReplyTo: fixture.parent.rfc822MessageId),
                accountId: from, replyToHeaderId: fixture.parent.id, isForward: false, serverDraftId: nil,
                draftId: draftId, instanceEpoch: "E1", holdsForUndo: false)
            return try #require(try await pool.read { try OutboxMessage.fetchOne($0, key: queued.outboxId) })
        }
        let row = try await queue("draft-other-account")
        // A witness filed at the same moment, whose Message-ID no email carries: its bubble ending
        // shows the observation has read the filing.
        let witness = try await queue("draft-other-account-witness")
        #expect(replies.composeEnded(.sent(outboxId: row.id), replyTo: fixture.parent))
        #expect(replies.composeEnded(.sent(outboxId: witness.id), replyTo: fixture.parent))
        for _ in 0..<100 where replies.progress[row.id] == nil || replies.progress[witness.id] == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(replies.progress[row.id]?.caption == "Sending", "control: the bubble follows the queued email")

        // The provider took both ("Sent"), then filing deletes their rows, and the reply's Sent copy
        // is in the sending account's Sent.
        try await pool.write { db in
            try db.execute(sql: "UPDATE outboxMessage SET sentAt = ? WHERE id IN (?, ?)", arguments: [Date(), row.id, witness.id])
        }
        for _ in 0..<100 where replies.progress[row.id]?.caption != "Sent" || replies.progress[witness.id]?.caption != "Sent" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(replies.progress[row.id]?.caption == "Sent" && replies.progress[witness.id]?.caption == "Sent",
                "control: both were sent")
        var copy = MessageHeader(
            messageId: "sent-\(row.id)", subject: "Re: Lunch plans", from: "\(from)@example.com",
            fromAddress: "\(from)@example.com", to: "sender@example.com", date: Date(), snippet: "Tuesday",
            folderId: MessageIdentity.folderId(accountId: from, folderPath: "Sent"),
            accountId: from, folderPath: "Sent", isInInbox: false)
        copy.rfc822MessageId = EmailFilter.normalizeMessageId(try #require(row.sentMessageId))
        copy.inReplyTo = fixture.parent.rfc822MessageId
        let sentCopy = copy
        try await pool.write { db in
            try sentCopy.insert(db)
            _ = try OutboxMessage.deleteAll(db, keys: [row.id, witness.id])
        }
        for _ in 0..<100 where replies.entries.contains(where: { $0.id == witness.id }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!replies.entries.contains { $0.id == witness.id }, "control: the observation read the filing")
        #expect(replies.entries.map(\.id) == [row.id],
                "its email exists, in the account it was sent from, so the bubble stays until the chat shows it")
        replies.settle([Self.ownItem(sentCopy)])
        #expect(replies.entries.isEmpty, "a chat showing the email ends its bubble")
    }

    // MARK: - 5. The gate of the summary at Send

    enum GateInput: String, CaseIterable, Sendable {
        case none, chatViewOff, optedOut, noPlan, signedOut, noConsent
    }

    /// Every input on, the summary at Send may run; any one off, it may not. Each input is set
    /// through its real store.
    @Test("The summary at Send runs only with the chat view on, AI on, a plan, a session and consent", arguments: GateInput.allCases)
    func summaryAtSendGate(off: GateInput) throws {
        let restore = try Self.openGate(except: off)
        defer { restore() }
        #expect(SentEmailSummary.mayRun() == (off == .none), "with \(off.rawValue) off")
    }

    /// Sets every input of the summary gate on through its real store, except `off`, and returns
    /// what restores them.
    private static func openGate(except off: GateInput) throws -> () -> Void {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let standard = UserDefaults.standard
        let consentBefore = standard.object(forKey: AgeAndTermsConsent.completedKey)
        let previousSession = TabMailSessionStore.shared.loadActiveSession()?.data
        let previousDemo = DemoModeStore.shared.isActive
        let restore = {
            _ = TabMailAuthService.completeSession(mode: .deactivate, notify: false)
            if let previousSession { _ = try? TabMailSessionStore.shared.installNewSession(previousSession) }
            DemoModeStore.shared.isActive = previousDemo
            if let consentBefore { standard.set(consentBefore, forKey: AgeAndTermsConsent.completedKey) } else {
                standard.removeObject(forKey: AgeAndTermsConsent.completedKey)
            }
            saved.restore()
        }
        saved.setChatView(on: true)
        DemoModeStore.shared.isActive = false
        standard.set(true, forKey: AgeAndTermsConsent.completedKey)
        let sessionData = try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-worker-token", "refresh_token": "synthetic-refresh-token",
            "expires_at": Int(Date().addingTimeInterval(86400).timeIntervalSince1970),
            "user": ["id": "11111111-1111-4111-8111-111111111111", "email": "user@example.com"],
        ])
        _ = try TabMailSessionStore.shared.installNewSession(sessionData)
        #expect(!TutorialCoordinator.shared.isRunning, "control: no tutorial running")

        switch off {
        case .none: break
        case .chatViewOff: standard.set(false, forKey: ChatViewConfig.enabledKey)
        case .optedOut: AIService.optOutStore.set(true, forKey: AIService.optOutAllAIKey)
        case .noPlan: AISubscriptionGate.shared.closeGate()
        case .signedOut: _ = TabMailAuthService.completeSession(mode: .deactivate, notify: false)
        case .noConsent: standard.set(false, forKey: AgeAndTermsConsent.completedKey)
        }
        return restore
    }

    /// The real producer: `queueSend` summarizes a new queued email with the gate open, under its
    /// Sent folder and Message-ID; a deduplicated second Send makes no second summary, and with the
    /// gate closed there is none at all.
    @Test("A queued send summarizes its email once, and only with the gate open", arguments: [true, false])
    func queueSendSummarizes(gateOpen: Bool) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let restore = try Self.openGate(except: gateOpen ? .none : .chatViewOff)
        defer { restore() }
        let fixture = try await Self.makeFixture(pool)
        let http = Self.summaryBackend(textMessage: "I said Tuesday works.")
        defer { http.close() }
        let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        try await pool.write { db in
            var draft = Draft(
                id: "draft-queue", accountId: Self.account, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Re: Lunch plans", body: "Tuesday works", replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        func send() async throws -> String {
            try await AccountManager.shared.queueSend(
                draft: DraftMessage(to: ["sender@example.com"], subject: "Re: Lunch plans", body: "Tuesday works for me.",
                                    inReplyTo: fixture.parent.rfc822MessageId),
                from: fixture.account, replyToHeaderId: fixture.parent.id, draftId: "draft-queue", instanceEpoch: "E1",
                summaryService: service).outboxId
        }
        let outboxId = try await send()
        #expect(try await send() == outboxId, "control: the second Send is deduplicated")
        let row = try #require(try await pool.read { try OutboxMessage.fetchOne($0, key: outboxId) })
        let sentMessageId = try #require(row.sentMessageId)
        let key = try #require(MessageAICache.cacheKey(
            accountId: Self.account, folderPath: "Sent",
            rfc822MessageId: EmailFilter.normalizeMessageId(sentMessageId)))
        func cached() async throws -> MessageAICache? {
            try await pool.read { try MessageAICache.filter(Column("key") == key).fetchOne($0) }
        }
        if gateOpen {
            for _ in 0..<100 where try await cached() == nil { try await Task.sleep(for: .milliseconds(100)) }
            #expect(try await cached()?.summaryTextMessage == "I said Tuesday works.",
                    "the queued email's summary, under its Sent folder and Message-ID")
        }
        // Long enough for a second summary, or a gated one, to have been asked.
        try await Task.sleep(for: .seconds(2))
        #expect(http.recordedCalls().count == (gateOpen ? 1 : 0), "one summary per queued email, none when gated")
        if !gateOpen { #expect(try await cached() == nil, "nothing written when gated") }
    }

    // MARK: - 6. A send that failed for good

    @Test("A send that failed for good shows the red mark; its Retry queues the same email again and its Delete removes it and the bubble")
    func failedSendRetryAndDelete() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation { try await failedSendRetryAndDeleteBody() }
    }

    private func failedSendRetryAndDeleteBody() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
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
        let mark = ChatSentReplyBubble.notSentMarkId
        func hasMark() -> Bool { HostedAccessibility.identifiers(in: controller.view).contains(mark) }
        func count(_ words: String) -> Int { HostedAccessibility.labels(in: controller.view).filter { $0.contains(words) }.count }
        func waitFor(_ done: () -> Bool) async throws {
            for _ in 0..<80 where !done() { try await Task.sleep(for: .milliseconds(100)) }
        }
        func rows() async throws -> [OutboxMessage] { try await pool.read { try OutboxMessage.fetchAll($0) } }
        // The send fails for good. The hold keeps the drain off the row while the test reads it.
        func fail(_ id: String) async throws {
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE outboxMessage SET status = ?, retryCount = 3, errorMessage = 'Refused', holdUntil = ? WHERE id = ?",
                    arguments: [OutboxStatus.failed.rawValue, Date().addingTimeInterval(3600), id])
            }
        }
        try await waitFor { count("Lunch plans") > 0 }

        let row = try await Self.queueReply(fixture, draftId: "draft-failed-chat", holdsForUndo: true)
        replies.composeEnded(.sent(outboxId: row.id), replyTo: fixture.parent)
        try await waitFor { count("Sending") == 1 }
        #expect(count("Sending") == 1 && !hasMark(), "control: a send in progress has no mark")

        try await fail(row.id)
        try await waitFor { hasMark() }
        #expect(hasMark() && count("Not sent") >= 1, "a send that failed for good shows the red mark and Not sent")

        #expect(HostedAccessibility.perform("Retry", on: mark, in: controller.view), "the mark offers Retry")
        let retried = try await rows()
        #expect(retried.map(\.id) == [row.id], "Retry queues the same email, no second one")
        #expect(retried.first?.outboxStatus == .queued && retried.first?.retryCount == 0 && retried.first?.sentAt == nil,
                "the same row is queued again with fresh retries")
        try await waitFor { !hasMark() && count("Sending") == 1 }
        #expect(!hasMark() && count("Sending") == 1, "the bubble follows it back to Sending")

        try await fail(row.id)
        try await waitFor { hasMark() }
        #expect(hasMark(), "control: failed again")
        #expect(HostedAccessibility.perform("Delete", on: mark, in: controller.view), "the mark offers Delete")
        #expect(try await rows().isEmpty, "Delete removes the queued email")
        try await waitFor { replies.entries.isEmpty }
        #expect(replies.entries.isEmpty, "and its bubble")
        try await waitFor { !hasMark() && count("Not sent") == 0 }
        #expect(!hasMark() && count("Not sent") == 0 && count("You said: summarizing") == 0, "nothing of it is left on screen")
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

    @Test("A sent compose card reports its outbox row")
    func summaryAtSendWiring() throws {
        let compose = try Self.source("TabMail/Views/Compose/ComposeView.swift")
        #expect(Self.count("onAgentOutcome?(.sent(outboxId: queued.outboxId))", in: compose) == 1)
        #expect(Self.count("onAgentOutcome?(.sent", in: compose) == 1, "no other sent report")

        // queueSend's summary is driven for real in `queueSendSummarizes`, and its gate through its
        // real inputs in `summaryAtSendGate`.
    }
}
