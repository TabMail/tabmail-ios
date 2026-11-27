/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import TabMail

/// A reply in the outbox, from the queue write to its email in the chat, through the real outbox,
/// AI cache, send path and hosted chat. The bubble is read from the database, and nothing about a
/// send is kept in memory but the Message-ID a provider gave its Sent copy (`SentCopyLink`).
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The queued email has its own Message-ID from the queue write, and the send uses it.
///  2. The summary made at Send is the email's own: written under its Sent folder and Message-ID,
///     its Sent copy shows it, and no other email does, even one in Sent without a summary. A copy
///     its provider gave a Message-ID of its own (Gmail) shows it too, and keeps it under that one.
///  3. The chat shows the reply from the queue write: "Summarizing" and "Sending", the summary as
///     soon as it is made while still sending, and once sent the email itself with that same
///     summary and no second bubble, whatever Message-ID the provider gave the copy; a new email's
///     chat finds its copy the same way.
///  4. Which rows show (I5): every unsent row answering an email of the chat, from any account,
///     "Sending", or "Not sent" once failed; a sent row, a deleted row and a reply to an email of
///     another chat show nothing.
///  5. A queued (not deduplicated) send summarizes at once, through the real `queueSend`, only with
///     the chat view on and AI allowed; the gate is driven through each of its real inputs. A send
///     with its text version in hand keeps it as the user's words with the queue write, behind the
///     same gate, and is summarized all the same: the summary's to-dos and reminder land on its Sent
///     copy, even when the summary returns after the copy arrived, and its bubbles show the user's
///     words before and after the summary lands, a copy a sync stores again included. The gate is
///     read once per send: the words and the summary follow that one answer, even when the chat view
///     turns off or on while the queue write waits. The chat's concern report sends the summaries,
///     never the words.
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

    nonisolated private static func header(_ id: String, folder: String, from: String, inReplyTo: String? = nil) -> MessageHeader {
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
    /// Message-ID by default), with `textVersion` in hand when given, and returns its outbox row.
    private static func queueReply(
        _ fixture: Fixture, draftId: String, holdsForUndo: Bool,
        from account: String = Self.account, inReplyTo: String? = nil, textVersion: String? = nil
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
            draftId: draftId, instanceEpoch: "E1", holdsForUndo: holdsForUndo, textVersion: textVersion)
        return try #require(try await fixture.pool.read { try OutboxMessage.fetchOne($0, key: queued.outboxId) })
    }

    /// Queues a new email as a new email's compose card does (no In-Reply-To), with `textVersion` in
    /// hand when given, and returns its outbox row.
    private static func queueNewEmail(
        _ fixture: Fixture, draftId: String, textVersion: String? = nil
    ) async throws -> OutboxMessage {
        try await fixture.pool.write { db in
            var draft = Draft(
                id: draftId, accountId: Self.account, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Lunch on Friday", body: "Friday?", replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        let queued = try await AccountManager.persistQueuedSend(
            draft: DraftMessage(to: ["friend@example.com"], subject: "Lunch on Friday", body: "Friday works for lunch?"),
            accountId: Self.account, replyToHeaderId: nil, isForward: false, serverDraftId: nil,
            draftId: draftId, instanceEpoch: "E1", holdsForUndo: false, textVersion: textVersion)
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

    /// How the provider keeps the sent email's copy in its Sent folder.
    enum CopyShape: String, CaseIterable, Sendable {
        /// Under the Message-ID the send wrote; the send names no copy (IMAP, Exchange).
        case sendsMessageId
        /// Under a Message-ID of the provider's own, the copy the send's answer names (Gmail).
        case providersMessageId
    }

    /// The normalized Message-ID the provider's Sent copy of `row` carries.
    nonisolated private static func copyMessageId(of row: OutboxMessage, _ shape: CopyShape) throws -> String {
        let sent = try #require(row.sentMessageId, "control: the queued email has its Message-ID")
        switch shape {
        case .sendsMessageId: return EmailFilter.normalizeMessageId(sent)
        case .providersMessageId: return "gm-\(row.id)@mail.example.com"
        }
    }

    /// Claims and sends the row through the real send path with a mock provider. The provider's
    /// Sent folder then lists the sent email under its own server id, plus `alsoListed`, as a
    /// server does after the append: the send's own Sent folder sync runs on its own schedule and
    /// replaces the optimistic copy with that one, so the tests hold whichever copy is there.
    /// `shape` is how the provider keeps the copy; with `.providersMessageId` its send names the copy
    /// and its header listing reads it, as Gmail's does. `keepsRow`: the Sent append is refused, so
    /// the outbox row stays, sent, as it is between the Sent copy and the send's cleanup.
    private static func send(
        _ row: OutboxMessage, alsoListed: [MessageHeader] = [], shape: CopyShape = .sendsMessageId, keepsRow: Bool = false
    ) async throws -> MockEmailProvider {
        #expect(await AccountManager.shared.atomicClaimForTesting(row), "control: the row is claimed")
        let claimed = try #require(try await AppDatabase.dbPool.read { try OutboxMessage.fetchOne($0, key: row.id) })
        let provider = MockEmailProvider()
        var serverCopy = Self.header(
            shape == .providersMessageId ? "gm-\(row.id)" : "server-\(row.id)", folder: "Sent", from: "me@example.com",
            inReplyTo: row.inReplyTo.map(EmailFilter.normalizeMessageId))
        serverCopy.rfc822MessageId = try Self.copyMessageId(of: claimed, shape)
        serverCopy.subject = row.subject
        await provider.setFetchMessagesResult([Self.serverInfo(serverCopy)] + alsoListed.map(Self.serverInfo))
        if shape == .providersMessageId {
            await provider.setSendResult(SentCopyIdentity(providerMessageId: serverCopy.messageId, threadId: nil))
            await provider.setFetchMessageHeadersResult([Self.serverInfo(serverCopy)])
        }
        if keepsRow { await provider.setAppendToSentResult(false) }
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

    @Test("The summary made at Send is the queued email's own: its Sent copy shows it, whatever Message-ID the provider gave the copy, and keeps it with the email; no other email gets it",
          arguments: CopyShape.allCases)
    func summaryAtSendIsTheEmailsOwn(_ shape: CopyShape) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let restoreAISetting = AITestSetting.save()
        AITestSetting.set(aiOff: false)
        defer { restoreAISetting() }
        let fixture = try await Self.makeFixture(pool)
        let row = try await Self.queueReply(fixture, draftId: "draft-own-\(shape.rawValue)", holdsForUndo: false)
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

        let provider = try await Self.send(row, alsoListed: [other], shape: shape)
        #expect(await provider.sentDrafts.first?.messageId == messageId, "the send uses the Message-ID of the queue write")
        let sent = try await Self.sentHeaders(pool)
        let copyMessageId = try Self.copyMessageId(of: row, shape)
        let copy = try #require(sent.first { $0.rfc822MessageId == copyMessageId },
                                "control: the Sent copy is there: \(sent.map(\.rfc822MessageId))")
        #expect(copy.summaryTextMessage == "I said Tuesday works.", "the sent email's first row shows the summary made at Send")
        #expect(sent.first { $0.id == other.id }?.summaryBlurb == nil, "another email never gets it")
        // The summary lives with the email: a copy the sync stores again restores it by its own Message-ID.
        let kept = try await pool.read { db in
            try MessageAICache.cacheKey(accountId: Self.account, folderPath: "Sent", rfc822MessageId: copyMessageId)
                .flatMap { try MessageAICache.fetchOne(db, key: $0) }?.summaryTextMessage
        }
        #expect(kept == "I said Tuesday works.", "the AI cache keeps the summary under the copy's own Message-ID")
    }

    @Test("A Sent copy that arrives before the summary returns takes it when it does, whatever Message-ID the provider gave the copy",
          arguments: CopyShape.allCases)
    func lateSummaryReachesTheSentCopy(_ shape: CopyShape) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let restoreAISetting = AITestSetting.save()
        AITestSetting.set(aiOff: false)
        defer { restoreAISetting() }
        let fixture = try await Self.makeFixture(pool)
        let row = try await Self.queueReply(fixture, draftId: "draft-late-\(shape.rawValue)", holdsForUndo: false)

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

        _ = try await Self.send(row, shape: shape)
        #expect(try await Self.sentHeaders(pool).map(\.summaryBlurb) == [nil], "control: the copy arrived unsummarized")
        let copyMessageId = try Self.copyMessageId(of: row, shape)
        #expect(try await Self.sentHeaders(pool).map(\.rfc822MessageId) == [copyMessageId],
                "control: the copy carries the Message-ID its provider gave it")
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

    /// A slow summary call at Send: the backend signals `asked`, then holds its answer until
    /// `answer` is signalled, at most `slowSummaryHold` (the caller signals it on every exit). The
    /// answer has a to-do and a reminder due `reminderDue`, and a text message of its own ("I said
    /// Tuesday works.").
    private static func slowSummaryBackend(
        asked: DispatchSemaphore, answer: DispatchSemaphore, reminderDue: String
    ) -> FakeHTTP.Scenario {
        let http = FakeHTTP.Scenario()
        http.register(path: "/completions/chat", method: "POST") { _ in
            .parked {
                asked.signal()
                _ = answer.wait(timeout: .now() + Self.slowSummaryHold)
                let object: [String: Any] = [
                    "summary": "A plan.", "todos": ["Book a table for Tuesday"],
                    "reminder": ["due_date": reminderDue, "due_time": Self.reminderTime, "content": "Lunch on Tuesday"],
                    "text_message": "I said Tuesday works."]
                let assistant = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                let final = String(decoding: try! JSONSerialization.data(withJSONObject: ["assistant": assistant]), as: UTF8.self)
                return .bytes(Data("event: final\ndata: \(final)\n\n".utf8), contentType: "text/event-stream")
            }
        }
        return http
    }

    /// The longest a slow summary holds its answer when the test never releases it.
    nonisolated private static let slowSummaryHold: DispatchTimeInterval = .seconds(30)

    /// The time of day of the slow summary's reminder.
    nonisolated private static let reminderTime = "12:30"

    /// A reminder date a week from today, as the summary writes it.
    private static func reminderDueInAWeek() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: Date().addingTimeInterval(7 * 24 * 3600))
    }

    /// How the summary made at Send ends, against the send of its email.
    enum SummaryEnd: String, CaseIterable, Sendable {
        /// It lands before the email goes out.
        case beforeTheCopy
        /// It lands after the Sent copy arrived.
        case afterTheCopy
        /// The backend fails it.
        case fails
    }

    @Test("An email sent with the user's own words still gets the summary made at Send: its to-dos and reminder land on the Sent copy whether the summary ends before or after the copy arrives, the chat shows the user's words on the copy throughout, and a copy a sync stores again under its own Message-ID gets them all back; a failed summary leaves the words, whatever Message-ID the provider gave the copy",
          arguments: CopyShape.allCases, SummaryEnd.allCases)
    func ownWordsKeepTheSummarysTodosAndReminder(_ shape: CopyShape, _ end: SummaryEnd) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let restore = try Self.openGate(except: .none)
        defer { restore() }
        let fixture = try await Self.makeFixture(pool)
        let words = "Tuesday works!"
        let row = try await Self.queueReply(
            fixture, draftId: "draft-words-\(shape.rawValue)-\(end.rawValue)", holdsForUndo: false, textVersion: words)
        let sentFolderId = MessageIdentity.folderId(accountId: Self.account, folderPath: "Sent")
        // The sent email's bubble, as the thread's chat builds it from its emails.
        func copyBubble() async throws -> String? {
            let sent = try await Self.sentHeaders(pool)
            let thread = ChatThread(
                members: [fixture.parent] + sent, replyAddresses: { _ in [] },
                ownAddresses: [], draftFolderIds: [], sentFolderIds: [sentFolderId], unreadAtOpen: [], preferredId: nil)
            return thread.items.first { $0.isOwn }?.textMessage
        }
        let due = Self.reminderDueInAWeek()
        // The summary's results on `copy`, or none when the summary failed.
        func expectSummary(on copy: MessageHeader, _ label: String) {
            guard end != .fails else {
                #expect(copy.summaryBlurb == nil && copy.summaryTodos == nil && copy.reminderContent == nil,
                        "\(label): control: no summary was made")
                return
            }
            #expect(copy.summaryTodos?.contains("Book a table for Tuesday") == true,
                    "\(label): the summary's to-dos: \(copy.summaryTodos ?? "none")")
            #expect(copy.reminderContent == "Lunch on Tuesday" && copy.reminderDate == due && copy.reminderTime == Self.reminderTime,
                    "\(label): and its reminder: \(copy.reminderContent ?? "none") \(copy.reminderDate ?? "none") \(copy.reminderTime ?? "none")")
        }

        let asked = DispatchSemaphore(value: 0)
        let answer = DispatchSemaphore(value: 0)
        let http: FakeHTTP.Scenario
        if end == .fails {
            http = FakeHTTP.Scenario()
            http.register(path: "/completions/chat", method: "POST", response: .status(500))
        } else {
            http = Self.slowSummaryBackend(asked: asked, answer: answer, reminderDue: due)
        }
        defer { http.close() }
        defer { answer.signal() }
        let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        let summarizing = Task { await SentEmailSummary.summarize(outboxId: row.id, aiService: service) }
        if end == .afterTheCopy {
            let wasAsked = await Task.detached { Self.waited(for: asked) }.value
            #expect(wasAsked, "control: the summary was asked at Send")
        } else {
            answer.signal()
            await summarizing.value
        }

        _ = try await Self.send(row, shape: shape)
        let arrived = try await Self.sentHeaders(pool)
        #expect(arrived.count == 1, "control: the Sent copy arrived")
        let atArrival = try await copyBubble()
        #expect(atArrival == words, "the Sent copy shows the user's words when it arrives")
        if end == .afterTheCopy {
            answer.signal()
            await summarizing.value
        }
        #expect(http.recordedCalls().count == 1, "control: one summary call at Send")

        let copies = try await Self.sentHeaders(pool)
        #expect(copies.count == 1, "one Sent copy: \(copies.map(\.id))")
        guard copies.count == 1 else { return }
        let copy = copies[0]
        expectSummary(on: copy, "the Sent copy")
        let afterSummary = try await copyBubble()
        #expect(afterSummary == words, "the Sent copy still shows the user's words once the summary ended")

        // A sync stores the copy again, as it lists it: under the Message-ID the copy carries, with
        // nothing of the AI's. Its restore finds everything under that Message-ID alone.
        let again = try await pool.write { db -> MessageHeader in
            _ = try MessageHeader.deleteOne(db, key: copy.id)
            var again = Self.header(copy.messageId, folder: "Sent", from: "me@example.com", inReplyTo: copy.inReplyTo)
            again.rfc822MessageId = copy.rfc822MessageId
            try MessageAICache.restoreIfCached(into: &again, accountId: Self.account, folderPath: "Sent", db: db)
            try again.insert(db)
            return again
        }
        #expect(again.id == copy.id && again.rfc822MessageId == copy.rfc822MessageId, "control: the same email, stored again")
        #expect(again.userTextMessage == words, "the copy stored again gets the user's words back")
        expectSummary(on: again, "the copy stored again")
        let storedAgain = try await copyBubble()
        #expect(storedAgain == words, "and its bubble shows them")
    }

    @Test("A Sent copy a sync stored before the send filed it shows the user's words and the summary made at Send once the send files it, the summary having landed before the copy existed, whatever Message-ID the provider gave the copy",
          arguments: CopyShape.allCases)
    func copyASyncStoredFirstGetsTheWords(_ shape: CopyShape) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let restore = try Self.openGate(except: .none)
        defer { restore() }
        let fixture = try await Self.makeFixture(pool)
        let words = "Tuesday works!"
        let row = try await Self.queueReply(
            fixture, draftId: "draft-synced-first-\(shape.rawValue)", holdsForUndo: false, textVersion: words)
        // The summary made at Send lands, and finds no Sent copy to hand itself to.
        let http = Self.summaryBackend(textMessage: "I said Tuesday works.")
        defer { http.close() }
        await SentEmailSummary.summarize(
            outboxId: row.id,
            aiService: AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil }))
        #expect(http.recordedCalls().count == 1, "control: the summary was made")
        #expect(try await Self.sentHeaders(pool).isEmpty, "control: no Sent copy yet")

        // A sync lists the provider's copy before the send's filing write, and stores it as it
        // stores any listed email: under the Message-ID the copy carries, restored from there.
        let copyMessageId = try Self.copyMessageId(of: row, shape)
        let serverId = shape == .providersMessageId ? "gm-\(row.id)" : "server-\(row.id)"
        let synced = try await pool.write { db -> MessageHeader in
            var copy = Self.header(serverId, folder: "Sent", from: "me@example.com",
                                   inReplyTo: row.inReplyTo.map(EmailFilter.normalizeMessageId))
            copy.rfc822MessageId = copyMessageId
            copy.subject = row.subject
            try MessageAICache.restoreIfCached(into: &copy, accountId: Self.account, folderPath: "Sent", db: db)
            try copy.insert(db)
            return copy
        }
        if shape == .providersMessageId {
            #expect(synced.userTextMessage == nil && synced.summaryBlurb == nil,
                    "control: nothing is kept under the provider's Message-ID before the send files the copy")
        }

        _ = try await Self.send(row, shape: shape)
        let sent = try await Self.sentHeaders(pool)
        #expect(sent.map(\.id) == [synced.id], "control: the send filed the copy onto the row the sync stored")
        guard sent.count == 1 else { return }
        #expect(sent[0].userTextMessage == words, "the copy keeps the user's words")
        #expect(sent[0].summaryTextMessage == "I said Tuesday works.", "and the summary made at Send")
        let sentFolderId = MessageIdentity.folderId(accountId: Self.account, folderPath: "Sent")
        let thread = ChatThread(
            members: [fixture.parent] + sent, replyAddresses: { _ in [] },
            ownAddresses: [], draftFolderIds: [], sentFolderIds: [sentFolderId], unreadAtOpen: [], preferredId: nil)
        #expect(thread.items.first { $0.isOwn }?.textMessage == words, "the chat's bubble shows the words the user typed")
    }

    @Test("The Sending bubble of an email sent with the user's own words shows them from the queue write, while its summary is made, and after the summary lands")
    func sendingBubbleKeepsTheUserWords() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let restore = try Self.openGate(except: .none)
        defer { restore() }
        let fixture = try await Self.makeFixture(pool)
        let words = "Tuesday works!"
        let row = try await Self.queueReply(fixture, draftId: "draft-words-sending", holdsForUndo: false, textVersion: words)
        let parentMessageId = try #require(fixture.parent.rfc822MessageId)
        let chat: Set<String> = [EmailFilter.normalizeMessageId(parentMessageId)]
        func sendingReply() async throws -> ChatUnsentReply? {
            let replies = try await pool.read { try ChatUnsentReply.fetch(answering: chat, db: $0) }
            return replies.first { $0.id == row.id }
        }
        func sendingBubble() async throws -> String? { try await sendingReply()?.textMessage }
        let atQueue = try await sendingBubble()
        #expect(atQueue == words, "from the queue write")

        let asked = DispatchSemaphore(value: 0)
        let answer = DispatchSemaphore(value: 0)
        let http = Self.slowSummaryBackend(asked: asked, answer: answer, reminderDue: Self.reminderDueInAWeek())
        defer { http.close() }
        defer { answer.signal() }
        let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        let summarizing = Task { await SentEmailSummary.summarize(outboxId: row.id, aiService: service) }
        let wasAsked = await Task.detached { Self.waited(for: asked) }.value
        #expect(wasAsked, "control: the summary was asked at Send")
        let whileMade = try await sendingBubble()
        #expect(whileMade == words, "while the summary is made")
        answer.signal()
        await summarizing.value

        let sentMessageId = try #require(row.sentMessageId)
        let key = try #require(MessageAICache.cacheKey(
            accountId: Self.account, folderPath: "Sent", rfc822MessageId: EmailFilter.normalizeMessageId(sentMessageId)))
        let landed = try await pool.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(landed?.summaryTodos?.contains("Book a table for Tuesday") == true, "control: the summary landed")
        let afterLanded = try await sendingBubble()
        #expect(afterLanded == words, "after the summary lands, still the user's words")
        let reported = try await sendingReply()?.summaryTextMessage
        #expect(reported == "I said Tuesday works.", "the reply carries the summary's own text apart, for the concern report")
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
        let controller = UIHostingController(rootView: NavigationStack { ChatThreadView(messageId: fixture.parent.id) }
            .environment(NavigationStore()))
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
        // tells the chat (no merge signal is posted here). The bubble, "Sent" once filed, goes as the
        // email shows.
        _ = try await Self.send(row)
        func bubbleShows() -> Bool {
            HostedAccessibility.identifiers(in: controller.view).contains(ChatUnsentReplyBubble.bubbleId)
        }
        try await waitFor { !bubbleShows() && count(text) == 1 }
        #expect(!bubbleShows() && count(text) == 1, "the email shows the same summary, once: \(labels().prefix(20))")
        #expect(count("Sending") == 0 && count("Summarizing") == 0 && count("You said: summarizing") == 0,
                "no second bubble and no flash back: \(labels().prefix(20))")
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
    }

    @Test("Through the real send, from a reply's Sending bubble to the sent email in the thread's chat, every frame shows the user's words, whatever Message-ID the provider gave the copy: the bubble stays until the chat shows the sent email, even once the send's cleanup has deleted its row",
          arguments: CopyShape.allCases, 0..<3)
    func sentReplyKeepsTheWordsOnScreen(_ shape: CopyShape, attempt: Int) async throws {
        // Each attempt sends once: where the row's delete falls between two frames varies.
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await sentReplyKeepsTheWordsOnScreenBody(shape, attempt: attempt)
        }
    }

    private func sentReplyKeepsTheWordsOnScreenBody(_ shape: CopyShape, attempt: Int) async throws {
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
        let controller = UIHostingController(rootView: NavigationStack { ChatThreadView(messageId: fixture.parent.id) }
            .environment(NavigationStore()))
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

        // The reply with its summary made, so its bubble and its email in the chat read the same words.
        // Held, so no drain of the app's own sends it before the test does; the hold ends just before.
        let row = try await Self.queueReply(fixture, draftId: "draft-frames", holdsForUndo: true)
        let text = "I said Tuesday works."
        let http = Self.summaryBackend(textMessage: text)
        defer { http.close() }
        await SentEmailSummary.summarize(
            outboxId: row.id,
            aiService: AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil }))
        try await waitFor { count(text) == 1 && count("Sending") == 1 }
        #expect(count(text) == 1 && count("Sending") == 1, "control: the reply's Sending bubble shows its summary: \(labels().prefix(20))")

        let frames = OwnWordsFrames(view: controller.view)
        frames.start()
        try await pool.write { db in
            try db.execute(sql: "UPDATE outboxMessage SET holdUntil = ? WHERE id = ?",
                           arguments: [Date().addingTimeInterval(-1), row.id])
        }
        _ = try await Self.send(row, shape: shape)
        let rowGone = try await pool.read { try OutboxMessage.fetchOne($0, key: row.id) } == nil
        #expect(rowGone, "control: the send's cleanup deleted the row")
        // The send's bubble, "Sent" once filed, hands over to the sent email.
        func bubbleShows() -> Bool {
            HostedAccessibility.identifiers(in: controller.view).contains(ChatUnsentReplyBubble.bubbleId)
        }
        try await waitFor { !bubbleShows() && count(text) == 1 }
        try await Task.sleep(for: .milliseconds(300))
        frames.stop()
        print("[OwnWordsFrames] thread reply shape=\(shape.rawValue) attempt=\(attempt) \(frames.summary)")

        #expect(!bubbleShows() && count("Sending") == 0 && count(text) == 1,
                "control: the chat ends on the sent email: \(labels().prefix(20))")
        let none = frames.frames.filter(OwnWordsFrames.showsNone).count
        #expect(none == 0, "every frame shows the user's words; \(none) of \(frames.frames.count) show none: \(frames.summary)")
        let apart = frames.frames.filter(OwnWordsFrames.showsTwoApart).count
        #expect(apart == 0, "and never twice: \(frames.summary)")
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
    }

    /// When the send's Sent copy reaches the database against the filing's move (`MailPointerMove.sent`).
    enum CopyOrder: String, CaseIterable, Sendable {
        /// The copy, then the move, then the row's cleanup: the send's own order.
        case beforeItsMove
        /// The move, then the copy, then the row's cleanup.
        case afterItsMove
    }

    @Test("A sent reply's words show once in the thread's chat in every frame, whether its Sent copy reaches the database before or after the filing's move: the chat shows the copy only once the bubble points at it, and the bubble never comes back after",
          arguments: CopyOrder.allCases)
    func copyAndItsMoveShowTheWordsOnce(_ order: CopyOrder) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation { try await copyAndItsMoveShowTheWordsOnceBody(order) }
    }

    private func copyAndItsMoveShowTheWordsOnceBody(_ order: CopyOrder) async throws {
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
        let controller = UIHostingController(rootView: NavigationStack { ChatThreadView(messageId: fixture.parent.id) }
            .environment(NavigationStore()))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func labels() -> [String] { HostedAccessibility.labels(in: controller.view) }
        func count(_ words: String) -> Int { labels().filter { $0.contains(words) }.count }
        func waitFor(tries: Int = 80, _ done: () -> Bool) async throws {
            for _ in 0..<tries where !done() { try await Task.sleep(for: .milliseconds(100)) }
        }
        func bubbleShows() -> Bool {
            HostedAccessibility.identifiers(in: controller.view).contains(ChatUnsentReplyBubble.bubbleId)
        }
        try await waitFor { count("Lunch plans") > 0 }

        // Held, so no drain of the app's own sends it: the test makes the send's database writes and
        // its post itself, in the order under test.
        let row = try await Self.queueReply(fixture, draftId: "draft-order-\(order.rawValue)", holdsForUndo: true)
        let text = "I said Tuesday works."
        let http = Self.summaryBackend(textMessage: text)
        defer { http.close() }
        await SentEmailSummary.summarize(
            outboxId: row.id,
            aiService: AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil }))
        try await waitFor { count(text) == 1 && count("Sending") == 1 }
        #expect(count(text) == 1 && count("Sending") == 1, "control: the reply's Sending bubble shows its summary: \(labels().prefix(20))")

        // The optimistic Sent copy as the send writes it: in Sent, under the row's Message-ID, answering
        // the chat's email, to the reply's recipient (so the chat reads it "You said: ..."), with the
        // summary made at Send.
        var copy = Self.header("copy-\(order.rawValue)", folder: "Sent", from: fixture.account.emailAddress,
                               inReplyTo: fixture.parent.rfc822MessageId)
        copy.to = "sender@example.com"
        copy.rfc822MessageId = EmailFilter.normalizeMessageId(try #require(row.sentMessageId))
        copy.date = Date()
        copy.summaryBlurb = "A plan."
        copy.summaryTextMessage = text
        let sentCopy = copy
        let filing = MailPointerMoves([.sent(outboxId: row.id, copyHeaderId: sentCopy.id)])
        let rowId = row.id

        let frames = OwnWordsFrames(view: controller.view)
        frames.start()
        try await pool.write { db in
            try db.execute(sql: "UPDATE outboxMessage SET sentAt = ? WHERE id = ?", arguments: [Date(), rowId])
        }
        switch order {
        case .beforeItsMove:
            try await pool.write { db in try sentCopy.insert(db) }
            // Time for a reload of the chat to draw the copy, were one to run before the move.
            try await waitFor(tries: 15) { count(text) > 1 }
            #expect(count(text) == 1 && count("Sending") == 1,
                    "the copy is not shown before its move reaches the bubble: \(labels().prefix(20))")
            MailPointerMoves.publish(filing)
            try await waitFor { !bubbleShows() && count(text) == 1 }
            #expect(!bubbleShows() && count(text) == 1,
                    "the filing alone shows the email, while its row still waits: \(labels().prefix(20))")
            _ = try await pool.write { db in try OutboxMessage.deleteOne(db, key: rowId) }
        case .afterItsMove:
            MailPointerMoves.publish(filing)
            try await waitFor { bubbleShows() && count("Sending") == 0 }
            #expect(bubbleShows() && count(text) == 1 && count("Sending") == 0,
                    "filed with its copy not in yet: the bubble stays, Sent: \(labels().prefix(20))")
            try await pool.write { db in try sentCopy.insert(db) }
            _ = try await pool.write { db in try OutboxMessage.deleteOne(db, key: rowId) }
            try await waitFor { !bubbleShows() && count(text) == 1 }
        }
        // The row's cleanup and the reads after it: the chat stays on the email.
        try await Task.sleep(for: .milliseconds(300))
        frames.stop()
        print("[OwnWordsFrames] copy order=\(order.rawValue) \(frames.summary)")

        #expect(!bubbleShows() && count("Sending") == 0 && count(text) == 1,
                "control: the chat ends on the sent email: \(labels().prefix(20))")
        let none = frames.frames.filter(OwnWordsFrames.showsNone).count
        #expect(none == 0, "every frame shows the user's words; \(none) of \(frames.frames.count) show none: \(frames.summary)")
        let apart = frames.frames.filter(OwnWordsFrames.showsTwoApart).count
        #expect(apart == 0, "and never twice: \(frames.summary)")

        // The sent email then leaves the chat (its copy gone, the chat's emails read again): the send's
        // bubble, ended once the chat showed the email, does not come back.
        let copyId = sentCopy.id
        _ = try await pool.write { db in try MessageHeader.deleteOne(db, key: copyId) }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
        try await waitFor { count(text) == 0 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(count(text) == 0 && !bubbleShows(),
                "the email left the chat and its send's bubble stays ended: \(labels().prefix(20))")
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
    }

    // MARK: - 4. Which rows show

    @Test("Every reply to an email of the chat shows until the chat shows it, from any account: Sending, or Not sent once failed; a sent reply stays until its Sent copy is one of the chat's emails; a deleted or another chat's reply shows nothing")
    func whichRowsShow() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let fixture = try await Self.makeFixture(pool)
        // The test checks the read alone, so no drain may finish a row under it. In the test host the
        // app's own launch work can connect this account earlier in the process (it connects the
        // accounts of the installed database when the sidebar's account list fills, after a
        // `backgroundDataDidChange` post), and the connect keeps the account's work queue; with a queue,
        // a drain appends a sent row's Sent copy and deletes the row between two reads here. So the
        // account has no queue, and the deleted row goes through Undo's database half, which starts no
        // drain and posts nothing.
        await AccountManager.shared.unregisterProviderForTesting(accountId: Self.account)
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
        let deletedId = deleted.id
        let undone = try await pool.write { db in try AccountManager.cancelHeldOutboxRow(db: db, messageId: deletedId) }
        #expect(undone.deleted, "control: Undo deleted the row")
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
        #expect(rows[sent.id]?.caption == "Sending", "sent, its Sent copy not written yet: the row still shows")
        #expect(rows[sending.id]?.textMessage == "I said Tuesday works.", "the summary made at Send")
        #expect(rows[failed.id]?.textMessage == nil, "Summarizing until its summary is made")

        // The send writes the optimistic Sent copy under the row's Message-ID.
        let sentId = EmailFilter.normalizeMessageId(try #require(sent.sentMessageId))
        var copy = Self.header("sent-copy", folder: "Sent", from: fixture.account.emailAddress, inReplyTo: parentId)
        copy.rfc822MessageId = sentId
        let ownCopy = copy
        try await pool.write { db in try ownCopy.insert(db) }
        let afterCopy = try await shown()
        if afterCopy[sent.id] == nil {
            // What the outbox row is when the read leaves it out.
            let row = try await pool.read { db in try OutboxMessage.fetchOne(db, key: sent.id) }
            print("[whichRowsShow] sent row after its copy: exists=\(row != nil) sentAt=\(row?.sentAt != nil) status=\(row.map { "\($0.outboxStatus)" } ?? "nil") sentMessageId=\(row?.sentMessageId ?? "nil") parent=\(row.flatMap { AccountManager.queuedParentRfc822MessageId(of: $0) } ?? "nil") chat=\(chat.sorted()) shown=\(afterCopy.keys.sorted()) sent=\(sent.id)")
        }
        #expect(afterCopy[sent.id] != nil, "its copy is in the database, not yet one of the chat's emails: the row still shows")
        #expect(try await shown(chat.union([sentId]))[sent.id] == nil, "once the copy is one of the chat's emails, the bubble ends")
    }

    @Test("A sent reply's row shows until the Sent copy the send wrote is one of the chat's emails, whatever Message-ID the provider gave the copy",
          arguments: CopyShape.allCases)
    func sentReplyHandsOverToItsCopy(_ shape: CopyShape) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let fixture = try await Self.makeFixture(pool)
        let parentId = try #require(fixture.parent.rfc822MessageId)
        let chat: Set<String> = [EmailFilter.normalizeMessageId(parentId)]
        let row = try await Self.queueReply(fixture, draftId: "draft-handover-\(shape.rawValue)", holdsForUndo: false)

        _ = try await Self.send(row, shape: shape, keepsRow: true)
        let copyMessageId = try Self.copyMessageId(of: row, shape)
        let sent = try await Self.sentHeaders(pool)
        #expect(sent.map(\.rfc822MessageId) == [copyMessageId], "control: the send wrote the copy as its provider keeps it")
        let bubbles = try await pool.read { try ChatUnsentReply.fetch(answering: chat, db: $0) }
        #expect(bubbles.map(\.id) == [row.id], "the sent row waits for its cleanup and shows: its copy is not one of the chat's emails yet")
        let handedOver = try await pool.read { try ChatUnsentReply.fetch(answering: chat.union([copyMessageId]), db: $0) }
        #expect(handedOver.isEmpty, "once the copy is one of the chat's emails, the bubble ends: the email shows once")
    }

    @Test("A new email's chat finds its email's Sent copy, whatever Message-ID the provider gave the copy, while the send's row waits and after the row is gone",
          arguments: CopyShape.allCases)
    func newEmailFollowFindsItsCopy(_ shape: CopyShape) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let fixture = try await Self.makeFixture(pool)
        let draftId = "draft-new-email-\(shape.rawValue)"
        let row = try await Self.queueNewEmail(fixture, draftId: draftId)

        _ = try await Self.send(row, shape: shape, keepsRow: true)
        let sent = try await Self.sentHeaders(pool)
        let copyMessageId = try Self.copyMessageId(of: row, shape)
        #expect(sent.map(\.rfc822MessageId) == [copyMessageId], "control: the send wrote the copy as its provider keeps it")
        let copyId = try #require(sent.first?.id)
        let waiting = try await pool.read { try ChatNewEmailSend.fetch(ChatNewEmailSend.Key(draftId: draftId), db: $0) }
        #expect(waiting.reply != nil, "control: the sent row waits for its cleanup")
        #expect(waiting.sentCopyId == copyId, "the chat becomes the sent email's thread")

        // The send's cleanup removes the row; the chat keeps the email the row named.
        _ = try await pool.write { try OutboxMessage.deleteOne($0, key: row.id) }
        let cleaned = try await pool.read {
            try ChatNewEmailSend.fetch(ChatNewEmailSend.Key(draftId: draftId, email: waiting.email), db: $0)
        }
        #expect(cleaned.reply == nil, "control: the row is gone")
        #expect(cleaned.sentCopyId == copyId, "the chat still finds the sent email's copy")
    }

    @Test("A new email sent with the user's own words shows them in its chat from the queue write, after its summary lands, and on its Sent copy once the chat becomes its thread, whatever Message-ID the provider gave the copy",
          arguments: CopyShape.allCases)
    func newEmailKeepsTheUserWords(_ shape: CopyShape) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let restore = try Self.openGate(except: .none)
        defer { restore() }
        let fixture = try await Self.makeFixture(pool)
        let words = "Lunch on Friday?"
        let draftId = "draft-new-email-words-\(shape.rawValue)"
        let row = try await Self.queueNewEmail(fixture, draftId: draftId, textVersion: words)
        func fetched() async throws -> ChatNewEmailSend {
            try await pool.read { try ChatNewEmailSend.fetch(ChatNewEmailSend.Key(draftId: draftId), db: $0) }
        }
        let atQueue = try await fetched()
        #expect(atQueue.reply?.textMessage == words, "the Sending bubble shows the user's words from the queue write")
        #expect(atQueue.reply?.summaryTextMessage == nil, "control: no summary yet")

        let http = Self.summaryBackend(textMessage: "I asked about lunch on Friday.")
        defer { http.close() }
        await SentEmailSummary.summarize(
            outboxId: row.id,
            aiService: AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil }))
        #expect(http.recordedCalls().count == 1, "control: the summary was made")
        let summarized = try await fetched()
        #expect(summarized.reply?.textMessage == words, "still the user's words once the summary landed")
        #expect(summarized.reply?.summaryTextMessage == "I asked about lunch on Friday.",
                "the summary's own text apart, for the concern report")

        _ = try await Self.send(row, shape: shape, keepsRow: true)
        let sent = try await Self.sentHeaders(pool)
        let copyMessageId = try Self.copyMessageId(of: row, shape)
        #expect(sent.map(\.rfc822MessageId) == [copyMessageId], "control: the send wrote the copy as its provider keeps it")
        guard sent.count == 1 else { return }
        let filed = try await fetched()
        #expect(filed.sentCopyId == sent[0].id, "control: the chat becomes the sent email's thread")
        let sentFolderId = MessageIdentity.folderId(accountId: Self.account, folderPath: "Sent")
        let thread = ChatThread(
            members: sent, replyAddresses: { _ in [] },
            ownAddresses: [], draftFolderIds: [], sentFolderIds: [sentFolderId], unreadAtOpen: [], preferredId: nil)
        #expect(thread.items.map(\.textMessage) == [words], "the thread's chat shows the sent email with the user's words")
        #expect(thread.items.map(\.summaryTextMessage) == ["I asked about lunch on Friday."],
                "and keeps the summary's text apart")
    }

    @Test("A chat's Report a concern sends the summaries of its sent and sending emails, never the user's words their bubbles show, and the sent email's inbox preview stays its summary")
    func reportSendsTheSummariesOfTheChatsSends() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let restore = try Self.openGate(except: .none)
        defer { restore() }
        let fixture = try await Self.makeFixture(pool)
        let filedRow = try await Self.queueReply(fixture, draftId: "draft-report-filed", holdsForUndo: false, textVersion: "Tuesday works!")
        let sendingRow = try await Self.queueReply(fixture, draftId: "draft-report-sending", holdsForUndo: false, textVersion: "See you there!")
        for (row, summary) in [(filedRow, "I said Tuesday works."), (sendingRow, "I said I will be there.")] {
            let http = Self.summaryBackend(textMessage: summary)
            defer { http.close() }
            await SentEmailSummary.summarize(
                outboxId: row.id,
                aiService: AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil }))
            #expect(http.recordedCalls().count == 1, "control: \(summary)")
        }
        _ = try await Self.send(filedRow)
        let sent = try await Self.sentHeaders(pool)
        #expect(sent.count == 1, "control: the first reply is filed")
        guard sent.count == 1 else { return }

        // The chat as its view reads it: its emails, and the sends still showing.
        let sentFolderId = MessageIdentity.folderId(accountId: Self.account, folderPath: "Sent")
        let thread = ChatThread(
            members: [fixture.parent] + sent, replyAddresses: { _ in [] },
            ownAddresses: [], draftFolderIds: [], sentFolderIds: [sentFolderId], unreadAtOpen: [], preferredId: nil)
        let chat = Set(([fixture.parent] + sent).compactMap { $0.rfc822MessageId.map(EmailFilter.normalizeMessageId) })
        let unsent = try await pool.read { try ChatUnsentReply.fetch(answering: chat, db: $0) }
        #expect(thread.items.first { $0.isOwn }?.textMessage == "Tuesday works!", "control: the sent email's bubble shows the user's words")
        #expect(unsent.map(\.textMessage) == ["See you there!"], "control: the sending reply's bubble shows the user's words")

        let content = AISummariesNotice.reportContent(items: thread.items, unsent: unsent)
        #expect(content == "I said I will be there.\n\nI said Tuesday works.", "only the summaries, newest first: \(content)")
        let preview = MessageSnapshot(from: sent[0]).preview(chatViewActive: true)
        #expect(preview == "I said Tuesday works.", "the inbox preview is the summary's text, not the user's words")

        // The chat's notice reports exactly this content.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("TabMail/Views/Chat/ChatThreadView.swift"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(view.components(separatedBy: "reportContent: { AISummariesNotice.reportContent(items: thread.items, unsent: unsentReplies) }").count == 2,
                "the chat's notice reports its emails and its sends through reportContent(items:unsent:)")
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

    /// A send's text version as `queueSend` is given it.
    enum InHand: String, CaseIterable, Sendable {
        /// A text version, with the gate open.
        case written
        /// A text version, with the gate closed (the chat view off).
        case gated
        /// A text version that says nothing, with the gate open.
        case blank
    }

    /// The real producer with the text version in hand (ADR-IOS-114 decision 10): with the gate
    /// open it is kept as the user's words in the queue write itself, under the email's Sent folder
    /// and Message-ID, so the Sending bubble's first value has it; the summary is asked all the same
    /// and lands beside the words without replacing them. With the gate closed nothing is written or
    /// asked; one that says nothing is summarized as before, with no words kept.
    @Test("A send with its text version in hand keeps it as the user's words with the queue write, and its summary is made all the same, only with the gate open",
          arguments: InHand.allCases)
    func queueSendWritesTheTextVersionInHand(_ inHand: InHand) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let restore = try Self.openGate(except: inHand == .gated ? .chatViewOff : .none)
        defer { restore() }
        let fixture = try await Self.makeFixture(pool)
        // The summary is held until the queue write's state is read, so that read is its first value.
        let asked = DispatchSemaphore(value: 0)
        let answer = DispatchSemaphore(value: 0)
        let http = Self.slowSummaryBackend(asked: asked, answer: answer, reminderDue: Self.reminderDueInAWeek())
        defer { http.close() }
        defer { answer.signal() }
        let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        try await pool.write { db in
            var draft = Draft(
                id: "draft-in-hand", accountId: Self.account, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Re: Lunch plans", body: "Tuesday works for me.", replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        let textVersion = inHand == .blank ? "  " : "Tuesday works!"
        let outboxId = try await AccountManager.shared.queueSend(
            draft: DraftMessage(to: ["sender@example.com"], subject: "Re: Lunch plans", body: "Tuesday works for me.",
                                inReplyTo: fixture.parent.rfc822MessageId),
            from: fixture.account, replyToHeaderId: fixture.parent.id, draftId: "draft-in-hand", instanceEpoch: "E1",
            textVersion: textVersion, summaryService: service).outboxId
        let row = try #require(try await pool.read { try OutboxMessage.fetchOne($0, key: outboxId) })
        let sentMessageId = try #require(row.sentMessageId)
        let key = try #require(MessageAICache.cacheKey(
            accountId: Self.account, folderPath: "Sent",
            rfc822MessageId: EmailFilter.normalizeMessageId(sentMessageId)))
        func cached() async throws -> MessageAICache? {
            try await pool.read { try MessageAICache.filter(Column("key") == key).fetchOne($0) }
        }
        let parentMessageId = try #require(fixture.parent.rfc822MessageId)
        let chat: Set<String> = [EmailFilter.normalizeMessageId(parentMessageId)]
        if inHand != .gated {
            let wasAsked = await Task.detached { Self.waited(for: asked) }.value
            #expect(wasAsked, "control: the summary was asked at Send")
        }
        // Read while the summary's answer is held: as the queue write left it.
        let atQueue = try await cached()
        let bubbles = try await pool.read { try ChatUnsentReply.fetch(answering: chat, db: $0) }
        let bubbleText = bubbles.first { $0.id == outboxId }?.textMessage
        switch inHand {
        case .written:
            #expect(atQueue?.userTextMessage == "Tuesday works!", "kept as the user's words with the queue write")
            #expect(atQueue?.summaryBlurb == nil, "control: read before the summary landed")
            #expect(bubbleText == "Tuesday works!", "the Sending bubble's first value, never Summarizing")
        case .gated:
            #expect(atQueue == nil, "nothing written with the gate closed")
        case .blank:
            #expect(atQueue == nil, "nothing kept for a text version that says nothing")
        }
        if inHand != .gated {
            answer.signal()
            for _ in 0..<100 where try await cached()?.summaryBlurb == nil { try await Task.sleep(for: .milliseconds(100)) }
            let summarized = try await cached()
            #expect(summarized?.summaryBlurb == "A plan.", "the summary is made, words or not")
            #expect(summarized?.summaryTextMessage == "I said Tuesday works.", "the summary's own text message, beside the words")
            #expect(summarized?.userTextMessage == (inHand == .written ? "Tuesday works!" : nil),
                    "the user's words stay as they were, and none are kept without them")
        }
        // Long enough for a second summary, or a gated one, to have been asked.
        try await Task.sleep(for: .seconds(2))
        #expect(http.recordedCalls().count == (inHand == .gated ? 0 : 1), "one summary per queued email, none when gated")
        if inHand == .written {
            let bubbles = try await pool.read { try ChatUnsentReply.fetch(answering: chat, db: $0) }
            let later = bubbles.first { $0.id == outboxId }?.textMessage
            #expect(later == "Tuesday works!", "no summary replaced the words in the bubble")
        } else if inHand == .gated {
            let gated = try await cached()
            #expect(gated == nil, "still nothing with the gate closed")
        }
    }

    /// Holds a send's queue write at its outbox insert, on the database's writer, once armed: the
    /// send has read the gate by then, and its write waits inside its transaction until released.
    private final class QueueWritePause: Sendable {
        private let armed = Mutex(false)
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func arm() { armed.withLock { $0 = true } }
        func record(_ sql: String) {
            guard sql.contains("INSERT INTO \"outboxMessage\"") else { return }
            let holds = armed.withLock { armed -> Bool in
                defer { armed = false }
                return armed
            }
            guard holds else { return }
            reached.signal()
            _ = release.wait(timeout: .now() + .seconds(30))
        }
    }

    /// Which way the chat view turns while a send's queue write waits.
    enum ChatViewTurns: String, CaseIterable, Sendable {
        case off, on
    }

    /// A send decides once whether it summarizes, when it is queued: its words and its summary
    /// follow that one answer. The chat view turns while the queue write is held at its outbox
    /// insert, after the send has read the gate.
    @Test("A send follows the gate it read when queued: turned off during its queue write, it keeps its words and gets its summary; turned on, it keeps neither",
          arguments: ChatViewTurns.allCases)
    func queueSendDecidesOnce(_ turns: ChatViewTurns) async throws {
        let pause = QueueWritePause()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB(trace: { pause.record($0) })
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        defer { pause.release.signal() }
        let restore = try Self.openGate(except: turns == .off ? .none : .chatViewOff)
        defer { restore() }
        let fixture = try await Self.makeFixture(pool)
        let http = Self.summaryBackend(textMessage: "I said Tuesday works.")
        defer { http.close() }
        let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        try await pool.write { db in
            var draft = Draft(
                id: "draft-decides-once", accountId: Self.account, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Re: Lunch plans", body: "Tuesday works for me.", replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        let gateAtQueue = SentEmailSummary.mayRun()
        #expect(gateAtQueue == (turns == .off), "control: the gate as the send reads it")
        pause.arm()
        let parent = fixture.parent
        let account = fixture.account
        let sending = Task {
            try await AccountManager.shared.queueSend(
                draft: DraftMessage(to: ["sender@example.com"], subject: "Re: Lunch plans", body: "Tuesday works for me.",
                                    inReplyTo: parent.rfc822MessageId),
                from: account, replyToHeaderId: parent.id, draftId: "draft-decides-once", instanceEpoch: "E1",
                textVersion: "Tuesday works!", summaryService: service).outboxId
        }
        let held = await Task.detached { Self.waited(for: pause.reached) }.value
        #expect(held, "control: the queue write reached its outbox insert")
        let queuedWhileHeld = try await pool.read { try OutboxMessage.fetchCount($0) }
        #expect(queuedWhileHeld == 0, "control: the queue write has not landed")
        UserDefaults.standard.set(turns == .on, forKey: ChatViewConfig.enabledKey)
        let gateNow = SentEmailSummary.mayRun()
        #expect(gateNow == (turns == .on), "control: the gate turned before the queue write lands")
        pause.release.signal()
        let outboxId = try await sending.value

        let row = try #require(try await pool.read { try OutboxMessage.fetchOne($0, key: outboxId) })
        let sentMessageId = try #require(row.sentMessageId)
        let key = try #require(MessageAICache.cacheKey(
            accountId: Self.account, folderPath: "Sent", rfc822MessageId: EmailFilter.normalizeMessageId(sentMessageId)))
        func cached() async throws -> MessageAICache? {
            try await pool.read { try MessageAICache.filter(Column("key") == key).fetchOne($0) }
        }
        switch turns {
        case .off:
            for _ in 0..<100 where try await cached()?.summaryBlurb == nil { try await Task.sleep(for: .milliseconds(100)) }
            let landed = try await cached()
            #expect(landed?.userTextMessage == "Tuesday works!", "the words the send decided to keep")
            #expect(landed?.summaryBlurb == "A plan.", "and the summary it decided to make: \(landed?.summaryBlurb ?? "none")")
            #expect(http.recordedCalls().count == 1, "one summary asked")
        case .on:
            // Long enough for a summary to have been asked.
            try await Task.sleep(for: .seconds(2))
            let none = try await cached()
            #expect(none == nil, "no words kept and no summary made: \(none?.userTextMessage ?? "-") \(none?.summaryBlurb ?? "-")")
            #expect(http.recordedCalls().isEmpty, "no summary asked")
        }
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
        let controller = UIHostingController(rootView: NavigationStack { ChatThreadView(messageId: fixture.parent.id) }
            .environment(NavigationStore()))
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
