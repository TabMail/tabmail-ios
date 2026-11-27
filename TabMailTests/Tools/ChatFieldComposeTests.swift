/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import os
import Testing
@testable import TabMail

/// The chat view's closed field's Send (ADR-IOS-114 decision 10, amended 2026-11-26), through
/// `ChatFieldCompose` with the compose-text request answered as the backend would.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The words are the user's own message: they reach the request exactly as sent, in the mode
///     the email shown asks for (a reply to someone else's email, a follow-up to the user's own,
///     a new email), and the card opens with the email written, its text version the words.
///  2. The email written stays to be read (`ToolInvocation.fieldWritten`) before any card is
///     queued; Stop during that hold opens nothing.
///  3. Nothing is stored: the AI Suggestion and the on-device AI cache are as they were, whatever
///     the Send came to.
///  4. Nothing written opens nothing: a failed request, an answer with no email, or a row that is
///     no longer the email shown (a UIDVALIDITY reset), which is never even asked about.
///  5. The card goes to whom the field's reply goes: the suggestion's envelope, or only the people
///     chosen in Reply to, with the changes the answer gives; it saves to a draft of its own. An
///     own-only email's addresses stay on it only while the answer adds nobody else.
@Suite("The closed field's words are the user's own message")
@MainActor
struct ChatFieldComposeTests {

    static let asked = ComposeOrigin(sessionKey: "thread:chat", screen: .chat)
    static let chatHost = AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: [asked.sessionKey])

    nonisolated static let shown = ReplyResult(body: "Hi Sam,\n\nCount me in!\n\nAlex", textMessage: "Count me in!")
    nonisolated static let words = "did the first test go through?"
    nonisolated static let writtenBody = "Hi Sam,\n\nDid my first test email come through?\n\nBest,\nAlex"
    nonisolated static let alternative = "No rush, reply whenever you can"

    /// The compose-text requests asked, in order.
    final class Asked: @unchecked Sendable {
        struct Call { let mode: ComposeTextMode; let words: String; let subject: String; let context: ComposeEditContext }
        private let lock = NSLock()
        private var items: [Call] = []
        func add(_ call: Call) { lock.withLock { items.append(call) } }
        var all: [Call] { lock.withLock { items } }
    }

    /// What the hold saw: the cards queued each time the email written was held.
    @MainActor
    final class Hold {
        var queuedAtHold: [Int] = []
    }

    struct Fixture {
        let db: DatabaseQueue
        let router: AgentToolRouter
        let header: MessageHeader
        let ctx: ToolContext
    }

    /// The email the field shows, holding an AI Suggestion. `imap`: at a numeric UID whose
    /// numbering the folder and the row both observed, so another email seated at the row is told
    /// apart by its identity. `fromAddress`/`folder`: whose email it is.
    func fixture(imap: Bool = false, fromAddress: String = "sender@example.com", sent: Bool = false) async throws -> Fixture {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: imap ? .imap : .gmail)
        try TestDatabase.insertFolder(db)
        if sent { try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent) }
        var header = try TestDatabase.insertMessageHeader(
            db, messageId: imap ? "7" : "s1", subject: "Offsite", from: fromAddress, fromAddress: fromAddress,
            folderId: sent ? "acc1:Sent" : "acc1:INBOX", folderPath: sent ? "Sent" : "INBOX", isInInbox: !sent,
            rfc822MessageId: "<offsite@example.com>")
        let id = header.id, folderId = header.folderId
        try await db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET cachedReply = ?, replyTextMessage = ? WHERE id = ?",
                           arguments: [Self.shown.body, Self.shown.textMessage, id])
            if imap {
                try db.execute(sql: "UPDATE folder SET lastKnownUidValidity = 111 WHERE id = ?", arguments: [folderId])
                try db.execute(sql: "UPDATE messageHeader SET observedUidValidity = 111 WHERE id = ?", arguments: [id])
            }
        }
        header = try await row(db, id)
        let router = AgentToolRouter()
        return Fixture(db: db, router: router, header: header,
                       ctx: ToolContext(db: db, translator: MockChatIdTranslator(), router: router))
    }

    nonisolated static func answer(
        subject: String = "Re: Offsite", addTo: [[String: Any]] = [], addCc: [[String: Any]] = [], removeTo: [String] = []
    ) -> InlineEditResult {
        AIService.parseInlineEditResponse(ComposeEditJSON.make(
            response: "Wrote it.", addTo: addTo, removeTo: removeTo, addCc: addCc, subject: subject, body: writtenBody,
            textMessage: "Did my first test email come through?", changeCommand: alternative))!
    }

    /// The field's compose, the request answered with `answer` (nil: it fails).
    func compose(_ fixture: Fixture, asked: Asked, answer: InlineEditResult?) -> ChatFieldCompose {
        ChatFieldCompose(context: fixture.ctx, composeText: { mode, words, subject, context in
            asked.add(.init(mode: mode, words: words, subject: subject, context: context))
            if let answer { return answer }
            throw InlineEditFailure(message: "The edit could not be read. Please try again.")
        })
    }

    /// The closed field's Send on `header`: who was chosen in Reply to, and the hold.
    func invocation(
        _ header: MessageHeader, onlyTo: [String]? = nil, origin: ComposeOrigin = asked,
        fieldWritten: (@MainActor @Sendable () async -> Void)? = nil
    ) -> ToolInvocation {
        ToolInvocation(
            fieldReply: ChatFieldReply(email: header, onlyTo: onlyTo), composeOrigin: origin, fieldWritten: fieldWritten)
    }

    func row(_ db: DatabaseQueue, _ id: MessageHeader.ID) async throws -> MessageHeader {
        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: id) }
        return try #require(fetched)
    }

    func cache(_ db: DatabaseQueue) async throws -> [String] {
        try await db.read { db in try MessageAICache.fetchAll(db).map { "\($0.cachedReply ?? "")|\($0.replyTextMessage ?? "")" } }
    }

    func waitForCard(_ router: AgentToolRouter, host: AgentToolRouter.ComposeHost = chatHost) async -> AgentToolRouter.ComposeRequest? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let request = router.takeCompose(for: host) { return request }
            await Task.yield()
        }
        return router.takeCompose(for: host)
    }

    // MARK: - The words and the email written

    @Test("A reply: the words reach the request as sent, the email written opens on its card with the words as its text version, nothing stored")
    func replyWritesTheWords() async throws {
        let fixture = try await fixture()
        let cacheBefore = try await cache(fixture.db)
        let asked = Asked()
        let compose = compose(fixture, asked: asked, answer: Self.answer())
        let router = fixture.router
        let hold = Hold()
        let invocation = invocation(fixture.header, fieldWritten: { hold.queuedAtHold.append(router.composeQueueDepth) })
        let task = Task { @MainActor in await compose.reply(Self.words, invocation: invocation) }
        let card = try #require(await waitForCard(router), "the card opens")

        #expect(hold.queuedAtHold == [0], "the email written is held once, before its card is queued")
        let call = try #require(asked.all.first)
        #expect(asked.all.count == 1)
        #expect(call.mode == .reply, "someone else's email: a reply")
        #expect(call.words == Self.words, "the words as sent, never wrapped")
        #expect(call.subject == "Re: Offsite")
        let envelope = ChatReplyCompose.suggestionEnvelope(for: fixture.header, accounts: [])
        #expect(call.context.toRecipients == envelope.to && call.context.ccRecipients == envelope.cc, "the suggestion's envelope, by role")
        #expect(call.context.senderEmail == "test@example.com", "the email's own account sends it")
        #expect(call.context.relatedSubject == "Offsite" && call.context.mode == "text_reply")

        #expect(card.mode == .reply && card.replyTo?.id == fixture.header.id)
        #expect(card.body == Self.writtenBody)
        #expect(card.suggestion == ReplyResult(body: Self.writtenBody, textMessage: Self.words, changeCommand: Self.alternative),
                "the card's text version is the words themselves; the alternative rides with it")
        #expect(card.subject == "Re: Offsite" && card.isReplyAll, "the whole audience: a Reply All")
        #expect(card.isFieldsOwnReply && card.fieldReply == ChatFieldReply(email: fixture.header, onlyTo: nil))
        let parent = "\(fixture.header.accountId):\(fixture.header.stableId)"
        let key = try #require(card.draftId, "a draft of its own")
        #expect(key != "reply:\(parent)" && Draft.replyKeyTail(draftKey: key, isForward: false).map(String.init) == parent)

        card.onOutcome(.cancelled)
        let written = await task.value
        #expect(written == .done(ComposeOutcome.cancelled.describeForLLM), "closed unsent: the words stay")
        #expect(try await row(fixture.db, fixture.header.id).suggestion == Self.shown, "the AI Suggestion is not touched")
        #expect(try await cache(fixture.db) == cacheBefore, "nor the on-device AI cache")
    }

    /// Whose email the field shows decides the mode (`PromptVariables.isSentByUser`).
    enum Whose: String, CaseIterable, CustomTestStringConvertible {
        case someoneElses, usersOwnAddress, inSentFolder
        var testDescription: String { rawValue }
    }

    @Test("The user's own email, by its sender or its Sent folder, is followed up; someone else's is replied to",
          arguments: Whose.allCases)
    func modeFollowsWhoseEmail(_ whose: Whose) async throws {
        let fixture = try await fixture(
            fromAddress: whose == .usersOwnAddress ? "TEST@example.com" : "sender@example.com", sent: whose == .inSentFolder)
        let asked = Asked()
        let compose = compose(fixture, asked: asked, answer: Self.answer())
        let invocation = invocation(fixture.header)
        let task = Task { @MainActor in await compose.reply(Self.words, invocation: invocation) }
        let card = await waitForCard(fixture.router)
        card?.onOutcome(.cancelled)
        _ = await task.value
        #expect(card != nil, "control: the card opened")
        let expected: ComposeTextMode = whose == .someoneElses ? .reply : .followup
        #expect(asked.all.map(\.mode) == [expected])
        #expect(asked.all.first?.context.mode == expected.rawValue)
    }

    @Test("Stop while the email written is held opens no card and stores nothing")
    func stopDuringTheHoldOpensNothing() async throws {
        let fixture = try await fixture()
        let compose = compose(fixture, asked: Asked(), answer: Self.answer())
        let hold = Hold()
        let router = fixture.router
        let invocation = invocation(fixture.header, fieldWritten: {
            hold.queuedAtHold.append(router.composeQueueDepth)
            // Stop, while the email is held to be read.
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let task = Task { @MainActor in await compose.reply(Self.words, invocation: invocation) }
        // A card that opens anyway is taken and closed, so a failure never leaves the run waiting.
        let opened = await waitForCard(router)
        opened?.onOutcome(.cancelled)
        _ = await task.value
        #expect(hold.queuedAtHold == [0], "control: the email was written and held")
        #expect(opened == nil && router.composeQueueDepth == 0, "no card opens")
        #expect(try await row(fixture.db, fixture.header.id).suggestion == Self.shown)
    }

    // MARK: - Nothing written

    /// An answer with no email: what the request returns with AI turned off.
    @Test("A failed request, or an answer with no email (AI off), opens nothing: no hold, no card, nothing stored", arguments: [false, true])
    func failureOpensNothing(answersWithNoEmail: Bool) async throws {
        let fixture = try await fixture()
        let asked = Asked()
        let compose = compose(fixture, asked: asked, answer: answersWithNoEmail ? AIService.inlineEditWithAIOff : nil)
        let hold = Hold()
        let invocation = invocation(fixture.header, fieldWritten: { hold.queuedAtHold.append(0) })
        let written = await compose.reply(Self.words, invocation: invocation)
        #expect(asked.all.count == 1, "control: the request was asked")
        guard case .nothing = written else {
            Issue.record("nothing written: \(written)")
            return
        }
        #expect(hold.queuedAtHold.isEmpty, "no email, no hold")
        #expect(fixture.router.composeQueueDepth == 0, "no card")
        #expect(try await row(fixture.db, fixture.header.id).suggestion == Self.shown)
    }

    @Test("On IMAP, another email seated at the row the field showed is never asked about: nothing written, no card",
          arguments: [true, false])
    func swappedRowWritesNothing(swapped: Bool) async throws {
        let fixture = try await fixture(imap: true)
        if swapped {
            // After the Send read the row, the folder's numbering is reset and a resync seats
            // another email at the same row and UID, under the new numbering.
            try await fixture.db.write { db in
                try db.execute(sql: "UPDATE folder SET lastKnownUidValidity = 222 WHERE id = ?", arguments: [fixture.header.folderId])
                try db.execute(sql: "UPDATE messageHeader SET rfc822MessageId = '<other@example.com>', observedUidValidity = 222 WHERE id = ?",
                               arguments: [fixture.header.id])
            }
        }
        let asked = Asked()
        let compose = compose(fixture, asked: asked, answer: Self.answer())
        let invocation = invocation(fixture.header)
        let task = Task { @MainActor in await compose.reply(Self.words, invocation: invocation) }
        let card = await waitForCard(fixture.router)
        card?.onOutcome(.cancelled)
        let written = await task.value
        if swapped {
            #expect(asked.all.isEmpty, "the AI is never asked about another email")
            #expect(card == nil, "no card opens for another email")
            #expect(written == .failed("the email changed since the message was sent; nothing was done"))
        } else {
            #expect(asked.all.count == 1 && card != nil, "control: the same email under the same numbering is written")
        }
    }

    @Test("A Send with no screen to open the card on asks nothing")
    func noOriginAsksNothing() async throws {
        let fixture = try await fixture()
        let asked = Asked()
        let compose = compose(fixture, asked: asked, answer: Self.answer())
        let invocation = ToolInvocation(fieldReply: ChatFieldReply(email: fixture.header, onlyTo: nil))
        let written = await compose.reply(Self.words, invocation: invocation)
        #expect(written == .failed(ComposeOrigin.noScreenReason))
        #expect(asked.all.isEmpty)
        let newEmail = await compose.newEmail(Self.words, to: ["pat@example.com"], subject: "", invocation: .noninteractive)
        #expect(newEmail == .failed(ComposeOrigin.noScreenReason))
        #expect(asked.all.isEmpty)
    }

    @Test("The card's outcome: nothing written only when it never opened")
    func cardOutcome() {
        let refusal = ComposeOutcome.failed("the account was removed")
        #expect(ChatFieldCompose.Written.card(refusal) == .nothing(refusal.describeForLLM), "refused before it showed: nothing written")
        #expect(ChatFieldCompose.Written.card(.sent) == .sent(ComposeOutcome.sent.describeForLLM))
        #expect(ChatFieldCompose.Written.card(.cancelled) == .done(ComposeOutcome.cancelled.describeForLLM))
    }

    // MARK: - Who the card goes to

    @Test("Only the people chosen in Reply to: the request and the card go to them alone, a plain reply")
    func onlyToChosen() async throws {
        let fixture = try await fixture()
        let asked = Asked()
        let compose = compose(fixture, asked: asked, answer: Self.answer())
        let invocation = invocation(fixture.header, onlyTo: ["sender@example.com"])
        let task = Task { @MainActor in await compose.reply(Self.words, invocation: invocation) }
        let card = try #require(await waitForCard(fixture.router))
        let call = try #require(asked.all.first)
        #expect(call.context.toRecipients == ["sender@example.com"] && call.context.ccRecipients.isEmpty)
        #expect(RecipientEntry(card.to).addresses.map { $0.lowercased() } == ["sender@example.com"] && card.cc.isEmpty)
        #expect(!card.isReplyAll && card.fieldReply?.onlyTo == ["sender@example.com"])
        card.onOutcome(.cancelled)
        _ = await task.value
    }

    /// What the card for one answer holds.
    struct Envelope: Sendable, CustomTestStringConvertible {
        let name: String
        let answer: InlineEditResult
        let subject: String
        let to: [String]
        let cc: [String]
        let isReplyAll: Bool
        var testDescription: String { name }
    }

    nonisolated static let envelopes: [Envelope] = [
        Envelope(name: "unchanged", answer: answer(), subject: "Re: Offsite",
                 to: ["sender@example.com", "recipient@example.com"], cc: [], isReplyAll: true),
        // No subject from the model (blank): the card keeps the draft's "Re:" subject.
        Envelope(name: "no subject", answer: answer(subject: ""), subject: "Re: Offsite",
                 to: ["sender@example.com", "recipient@example.com"], cc: [], isReplyAll: true),
        Envelope(name: "added", answer: answer(addCc: [["name": "Pat", "email": "pat@example.com"]]), subject: "Re: Offsite",
                 to: ["sender@example.com", "recipient@example.com"], cc: ["pat@example.com"], isReplyAll: true),
        // Narrowed to one person: a plain reply, so the send records a reply on the original.
        Envelope(name: "narrowed", answer: answer(removeTo: ["recipient@example.com"]), subject: "Re: Offsite",
                 to: ["sender@example.com"], cc: [], isReplyAll: false),
        Envelope(name: "To emptied", answer: answer(addCc: [["name": "Pat", "email": "pat@example.com"]], removeTo: ["*"]),
                 subject: "Re: Offsite", to: [], cc: ["pat@example.com"], isReplyAll: false),
    ]

    @Test("The card goes to the suggestion's envelope with the changes the answer gives, on a draft of its own each time",
          arguments: envelopes)
    func cardEnvelope(_ expected: Envelope) async throws {
        let fixture = try await fixture()
        var keys: [String] = []
        for _ in 0..<2 {
            let compose = compose(fixture, asked: Asked(), answer: expected.answer)
            let invocation = invocation(fixture.header)
            let task = Task { @MainActor in await compose.reply(Self.words, invocation: invocation) }
            let card = try #require(await waitForCard(fixture.router))
            // Through the presenter every host uses.
            let view = card.composeView(account: nil, onOutcome: { _ in })
            #expect(view.prefillSubject == expected.subject)
            #expect(RecipientEntry(view.prefillTo ?? []).addresses.map { $0.lowercased() } == expected.to)
            #expect(RecipientEntry(view.prefillCc ?? []).addresses.map { $0.lowercased() } == expected.cc)
            #expect(view.prefillBcc == [])
            #expect(view.isReplyAll == expected.isReplyAll && card.isReplyAll == expected.isReplyAll)
            keys.append(try #require(view.prefillDraftId))
            card.onOutcome(.cancelled)
            _ = await task.value
            fixture.router.resetComposeQueueForTesting()
        }
        #expect(Set(keys).count == 2, "each card has its own draft: \(keys)")
    }

    @Test("A Reply-To that is the user's own address with an outside Cc: the request's draft keeps To empty, never refilled")
    func ownReplyToKeepsToEmpty() async throws {
        let fixture = try await fixture()
        try await fixture.db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET replyTo = 'test@example.com', \"to\" = 'test@example.com', cc = 'pat@example.com' WHERE id = ?",
                           arguments: [fixture.header.id])
        }
        let email = try await row(fixture.db, fixture.header.id)
        let asked = Asked()
        let compose = compose(fixture, asked: asked, answer: Self.answer())
        let invocation = invocation(email)
        let task = Task { @MainActor in await compose.reply(Self.words, invocation: invocation) }
        let card = await waitForCard(fixture.router)
        card?.onOutcome(.cancelled)
        _ = await task.value
        let call = try #require(asked.all.first)
        #expect(call.context.toRecipients.isEmpty && call.context.ccRecipients == ["pat@example.com"])
        #expect(card?.to == [] && card?.cc == ["pat@example.com"])
    }

    /// One answer on the field's reply to an own-only email, and the card it opens.
    struct OwnOnly: Sendable, CustomTestStringConvertible {
        let name: String
        let onlyTo: [String]?
        let answer: InlineEditResult
        let to: [String]
        let cc: [String]
        let isReplyAll: Bool
        /// The subject the card opens with: the one the answer wrote.
        var subject = "Re: Offsite"
        var testDescription: String { name }
    }

    nonisolated static let ownOnly: [OwnOnly] = [
        OwnOnly(name: "the words add someone else to To, under a subject they wrote", onlyTo: nil,
                answer: answer(subject: "Plans for Friday", addTo: [["name": "Bob", "email": "bob@example.com"]]),
                to: ["bob@example.com"], cc: [], isReplyAll: true, subject: "Plans for Friday"),
        OwnOnly(name: "the words add someone else to Cc", onlyTo: nil,
                answer: answer(addCc: [["name": "Bob", "email": "bob@example.com"]]),
                to: [], cc: ["bob@example.com"], isReplyAll: true),
        // Controls: with nobody else added, the user's own addresses are the reply's audience; and
        // the people the user chose in Reply to stay as chosen when someone is added.
        OwnOnly(name: "no change", onlyTo: nil, answer: answer(),
                to: ["b@example.com", "test@example.com"], cc: [], isReplyAll: true),
        OwnOnly(name: "chosen in Reply to, then someone else added", onlyTo: ["b@example.com"],
                answer: answer(addTo: [["name": "Bob", "email": "bob@example.com"]]),
                to: ["b@example.com", "bob@example.com"], cc: [], isReplyAll: false),
    ]

    /// The user forwards an email from their other account (b@) to this one and writes in the field
    /// on the copy this account received. Its Reply All holds nobody, so the field's reply goes to
    /// b@, then this account (`ChatThread.replyAllAudience`). Once the words add someone else, the
    /// card opens to them alone: the person added is never shown the user's other addresses.
    @Test("An own-only email's field reply keeps the user's addresses only while nobody else is added",
          arguments: ownOnly)
    func ownOnlyFallbackWithTheWordsChange(_ expected: OwnOnly) async throws {
        let fixture = try await fixture()
        try TestDatabase.insertAccount(fixture.db, id: "acc2", email: "b@example.com")
        try await fixture.db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET \"from\" = 'b@example.com', fromAddress = 'b@example.com', \"to\" = 'test@example.com' WHERE id = ?",
                           arguments: [fixture.header.id])
        }
        let email = try await row(fixture.db, fixture.header.id)
        let compose = compose(fixture, asked: Asked(), answer: expected.answer)
        let invocation = invocation(email, onlyTo: expected.onlyTo)
        let task = Task { @MainActor in await compose.reply(Self.words, invocation: invocation) }
        let card = try #require(await waitForCard(fixture.router))
        let to = RecipientEntry(card.to).addresses.map { $0.lowercased() }
        let cc = RecipientEntry(card.cc).addresses.map { $0.lowercased() }
        #expect(to == expected.to && cc == expected.cc && card.bcc.isEmpty, "To \(to), Cc \(cc), Bcc \(card.bcc)")
        #expect(card.isReplyAll == expected.isReplyAll)
        #expect(card.subject == expected.subject)
        card.onOutcome(.cancelled)
        _ = await task.value
    }

    // MARK: - A new email's chat

    @Test("A new email: the words written into a new email to the people picked, from the account bound, under the chat's subject or the one written",
          arguments: ["", "Friday plans"])
    func newEmailWritesTheWords(subject: String) async throws {
        let fixture = try await fixture()
        try TestDatabase.insertAccount(fixture.db, id: "acc2", email: "second@example.com")
        let asked = Asked()
        let written = ComposeEditJSON.make(
            response: "Wrote it.", subject: subject.isEmpty ? "Quick question" : subject, body: Self.writtenBody,
            textMessage: "Did my first test email come through?", changeCommand: Self.alternative)
        let compose = compose(fixture, asked: asked, answer: AIService.parseInlineEditResponse(written))
        let origin = ComposeOrigin(sessionKey: "new:chat", screen: .chat, fromAccountId: "acc2")
        let host = AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: [origin.sessionKey])
        let hold = Hold()
        let router = fixture.router
        let invocation = ToolInvocation(
            composeOrigin: origin, fieldWritten: { hold.queuedAtHold.append(router.composeQueueDepth) })
        let task = Task { @MainActor in
            await compose.newEmail(Self.words, to: ["Pat Lee <pat@example.com>"], subject: subject, invocation: invocation)
        }
        let card = try #require(await waitForCard(router, host: host))
        #expect(hold.queuedAtHold == [0], "held before the card is queued")
        let call = try #require(asked.all.first)
        #expect(call.mode == .new && call.words == Self.words && call.subject == subject)
        #expect(call.context.senderEmail == "second@example.com", "the account bound as the Send started")
        #expect(call.context.toRecipients == ["pat@example.com"] && call.context.toDisplayNames["pat@example.com"] == "Pat Lee")
        #expect(call.context.bodyText.isEmpty && call.context.relatedSubject.isEmpty, "no email")
        #expect(card.mode == .compose && card.replyTo == nil && card.to == ["Pat Lee <pat@example.com>"])
        #expect(card.subject == (subject.isEmpty ? "Quick question" : subject))
        #expect(card.suggestion == ReplyResult(body: Self.writtenBody, textMessage: Self.words, changeCommand: Self.alternative))
        #expect(card.fromAccountId == "acc2")
        card.onOutcome(.sent)
        #expect(await task.value == .sent(ComposeOutcome.sent.describeForLLM))
    }

    @Test("A new email whose request fails, or answers with no email (AI off), opens nothing: no hold, no card", arguments: [false, true])
    func newEmailFailureOpensNothing(answersWithNoEmail: Bool) async throws {
        let fixture = try await fixture()
        let asked = Asked()
        let compose = compose(fixture, asked: asked, answer: answersWithNoEmail ? AIService.inlineEditWithAIOff : nil)
        let hold = Hold()
        let invocation = ToolInvocation(
            composeOrigin: ComposeOrigin(sessionKey: "new:chat", screen: .chat), fieldWritten: { hold.queuedAtHold.append(0) })
        let written = await compose.newEmail(Self.words, to: ["pat@example.com"], subject: "", invocation: invocation)
        #expect(asked.all.map(\.mode) == [.new], "control: the request was asked once, for a new email")
        guard case .nothing = written else {
            Issue.record("nothing written: \(written)")
            return
        }
        #expect(hold.queuedAtHold.isEmpty, "no email, no hold")
        #expect(fixture.router.composeQueueDepth == 0, "no card")
    }
}
