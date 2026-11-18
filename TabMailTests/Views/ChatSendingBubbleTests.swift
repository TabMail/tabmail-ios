/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// A reply in the outbox, from the queue write to its email in the chat, through the real outbox,
/// AI cache, send path and hosted chat. The bubble is read from the database alone:
/// nothing about a send is kept in memory.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The queued email has its own Message-ID from the queue write, and the send uses it.
///  2. The summary made at Send is the email's own: written under its Sent folder and Message-ID,
///     its Sent copy shows it, and no other email does, even one in Sent without a summary.
///  3. The chat shows the reply from the queue write: "Summarizing" and "Sending", the summary as
///     soon as it is made while still sending, and once sent the email itself with that same
///     summary and no second bubble.
///  4. Which rows show (I5): every unsent row answering an email of the chat, from any account,
///     "Sending", or "Not sent" once failed; a sent row, a deleted row and a reply to an email of
///     another chat show nothing.
///  5. A queued (not deduplicated) send summarizes at once, through the real `queueSend`, only with
///     the chat view on and AI allowed; the gate is driven through each of its real inputs.
///  6. A send that failed for good shows the red mark beside its bubble; the
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

    /// Queues a reply as the compose card does, from `account` to `inReplyTo` (the parent's
    /// Message-ID by default), and returns its outbox row.
    private static func queueReply(
        _ fixture: Fixture, draftId: String, holdsForUndo: Bool,
        from account: String = Self.account, inReplyTo: String? = nil
    ) async throws -> OutboxMessage {
        try await fixture.pool.write { db in
            var draft = Draft(
                id: draftId, accountId: account, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Re: Lunch plans", body: "Tuesday works", replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        let queued = try await AccountManager.persistQueuedSend(
            draft: DraftMessage(to: ["sender@example.com"], subject: "Re: Lunch plans", body: "Tuesday works for me.",
                                inReplyTo: inReplyTo ?? fixture.parent.rfc822MessageId),
            accountId: account, replyToHeaderId: fixture.parent.id, isForward: false, serverDraftId: nil,
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
        defer {
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

        // The real send: it stamps `sentAt`, writes the Sent copy and deletes the row; nothing else
        // tells the chat (no merge signal is posted here).
        _ = try await Self.send(row)
        try await waitFor { count("Sending") == 0 && count(text) == 1 }
        #expect(count(text) == 1, "the email shows the same summary, once: \(labels().prefix(20))")
        #expect(count("Sending") == 0 && count("Summarizing") == 0 && count("You said: summarizing") == 0,
                "no second bubble and no flash back: \(labels().prefix(20))")
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
    }

    // MARK: - 4. Which rows show

    @Test("Every reply to an email of the chat shows until the chat shows it, from any account: Sending, or Not sent once failed; a sent reply stays until its Sent copy is one of the chat's emails; a deleted or another chat's reply shows nothing")
    func whichRowsShow() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let fixture = try await Self.makeFixture(pool)
        let parentId = try #require(fixture.parent.rfc822MessageId)
        let chat: Set<String> = [EmailFilter.normalizeMessageId(parentId)]
        func shown(_ messageIds: Set<String> = chat) async throws -> [String: ChatUnsentReply] {
            try await pool.read { db in
                Dictionary(uniqueKeysWithValues: try ChatUnsentReply.fetch(answering: messageIds, db: db).map { ($0.id, $0) })
            }
        }
        func set(_ sql: String, _ arguments: StatementArguments) async throws {
            try await pool.write { db in try db.execute(sql: sql, arguments: arguments) }
        }

        let sending = try await Self.queueReply(fixture, draftId: "draft-rows-sending", holdsForUndo: true)
        let failed = try await Self.queueReply(fixture, draftId: "draft-rows-failed", holdsForUndo: true)
        let sent = try await Self.queueReply(fixture, draftId: "draft-rows-sent", holdsForUndo: true)
        let sentWithoutId = try await Self.queueReply(fixture, draftId: "draft-rows-sent-no-id", holdsForUndo: true)
        let deleted = try await Self.queueReply(fixture, draftId: "draft-rows-deleted", holdsForUndo: true)
        // Compose's From picker chose the user's other account; the In-Reply-To has its brackets.
        let otherAccount = "acc-sending-from"
        _ = try FolderEpochTestFixture.makeAccount(id: otherAccount, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: otherAccount, path: "Sent", role: .sent, pool: pool)
        let fromOther = try await Self.queueReply(
            fixture, draftId: "draft-rows-other", holdsForUndo: true, from: otherAccount, inReplyTo: "<\(parentId)>")
        let elsewhere = try await Self.queueReply(
            fixture, draftId: "draft-rows-elsewhere", holdsForUndo: true, inReplyTo: "another-chat@example.com")
        let all = [sending, failed, sent, sentWithoutId, deleted, fromOther, elsewhere]
        #expect(try await shown().keys.sorted() == all.filter { $0.id != elsewhere.id }.map(\.id).sorted(),
                "control: every queued reply to this chat shows, and only those")

        try await set("UPDATE outboxMessage SET status = ? WHERE id = ?", [OutboxStatus.failed.rawValue, failed.id])
        try await set("UPDATE outboxMessage SET sentAt = ? WHERE id = ?", [Date(), sent.id])
        try await set("UPDATE outboxMessage SET sentAt = ?, sentMessageId = NULL WHERE id = ?", [Date(), sentWithoutId.id])
        #expect(AccountManager.shared.discardOutboxMessageConfirmed(deleted.id), "control: Undo deleted the row")
        try await pool.write { db in
            try MessageAICache.writeThrough(
                accountId: Self.account, folderPath: "Sent",
                rfc822MessageId: EmailFilter.normalizeMessageId(try #require(sending.sentMessageId)),
                summaryBlurb: "A plan.", summaryTextMessage: "I said Tuesday works.", db: db)
        }

        let rows = try await shown()
        #expect(rows.keys.sorted() == [sending.id, failed.id, sent.id, fromOther.id].sorted(),
                "a deleted reply, another chat's and a sent one that cannot be handed over show nothing")
        #expect(rows[sending.id]?.caption == "Sending" && rows[fromOther.id]?.caption == "Sending")
        #expect(rows[failed.id]?.caption == "Not sent")
        #expect(rows[sent.id]?.caption == "Sending" && rows[sent.id]?.filed == false,
                "sent, its Sent copy not written yet: the bubble stays")
        #expect(rows[sending.id]?.textMessage == "I said Tuesday works.", "the summary made at Send")
        #expect(rows[failed.id]?.textMessage == nil, "Summarizing until its summary is made")

        // The send writes the optimistic Sent copy under the row's Message-ID.
        let sentId = EmailFilter.normalizeMessageId(try #require(sent.sentMessageId))
        var copy = Self.header("sent-copy", folder: "Sent", from: fixture.account.emailAddress, inReplyTo: parentId)
        copy.rfc822MessageId = sentId
        let ownCopy = copy
        try await pool.write { db in try ownCopy.insert(db) }
        #expect(try await shown()[sent.id]?.filed == true, "its copy is in the database, not yet in the chat: the chat reloads")
        #expect(try await shown()[sending.id]?.filed == false, "control: an unsent reply is never filed")
        #expect(try await shown(chat.union([sentId]))[sent.id] == nil, "once the copy is one of the chat's emails, the bubble ends")
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
        defer {
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
        let mark = ChatUnsentReplyBubble.notSentMarkId
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
        try await waitFor { !hasMark() && count("Not sent") == 0 }
        #expect(!hasMark() && count("Not sent") == 0 && count("You said: summarizing") == 0, "nothing of it is left on screen")
    }
}
