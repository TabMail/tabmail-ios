/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// A reply the chat's reply field writes with only some people chosen in Reply to (ADR-IOS-114
/// decisions 10 and 11): its words are written for the people chosen, as the account the email was
/// received in; the email's stored AI Suggestion, written for its whole Reply All audience, never
/// stands in for them; and none of the card's words is stored as that suggestion, whether the user
/// edited them or Recompute wrote new ones. `.processGlobalState`: the field's compose reads the
/// shared prompt store (`PromptStore.shared`), which other suites change.
@Suite("Who the field's narrowed reply is written for", .serialized, .processGlobalState)
@MainActor
struct EmailReplyWordsTests {
    static let asked = ComposeOrigin(sessionKey: "thread:chat", screen: .chat)
    static let chatHost = AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: [asked.sessionKey])

    /// The email's stored AI Suggestion, written for everyone.
    nonisolated static let stored = ReplyResult(
        body: "Hi all,\n\nCount us in!\n\nAlex", textMessage: "Count us in!", changeCommand: "decline instead")
    /// The words the user sent from the field.
    nonisolated static let words = "count me in"
    nonisolated static let written = "Hi Sam,\n\nCount me in!\n\nAlex"
    nonisolated static let writtenText = "Count me in!"
    nonisolated static let writtenCommand = "ask for the agenda"
    /// A reply stored with the very value a narrowed field card shows (the email written, the words
    /// as its text version, its alternative): the value the card shows (`ComposeView.givenSuggestion`)
    /// equals it, so only the narrowed rule keeps an edit from being stored over it.
    nonisolated static let sameWords = ReplyResult(body: written, textMessage: words, changeCommand: writtenCommand)
    /// The email's own text, distinct from its snippet.
    static let emailText = "Are you coming to the offsite on Friday?"

    final class Calls: @unchecked Sendable {
        struct Call { let context: ComposeEditContext; let subject: String; let body: String; let request: String }
        private let lock = NSLock()
        private var items: [Call] = []
        func add(_ call: Call) { lock.withLock { items.append(call) } }
        var all: [Call] { lock.withLock { items } }
    }

    struct Fixture {
        let db: DatabaseQueue
        let router: AgentToolRouter
        let header: MessageHeader
        let accounts: [Account]
        let ctx: ToolContext
    }

    struct NoCard: Error {}

    /// The email from sender@example.com to the user's account and alex@example.com, Cc
    /// sam@example.com, holding `stored` as its AI Suggestion. `second`: received in a second
    /// account (second@example.com), neither the first nor the primary one.
    func fixture(second: Bool = false, stored: ReplyResult? = Self.stored) async throws -> Fixture {
        let db = try TestDatabase.make()
        var accounts = [try TestDatabase.insertAccount(db)]
        try TestDatabase.insertFolder(db)
        if second {
            accounts.append(try TestDatabase.insertAccount(db, id: "acc2", email: "second@example.com"))
            try TestDatabase.insertFolder(db, accountId: "acc2")
        }
        let own = second ? "second@example.com" : "test@example.com"
        let inserted = try TestDatabase.insertMessageHeader(
            db, messageId: "w1", subject: "Offsite", to: "\(own), alex@example.com",
            folderId: second ? "acc2:INBOX" : "acc1:INBOX", accountId: second ? "acc2" : "acc1",
            rfc822MessageId: "<offsite@example.com>")
        let id = inserted.id
        try await db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET cc = ? WHERE id = ?", arguments: ["sam@example.com", id])
            if let stored {
                try db.execute(
                    sql: "UPDATE messageHeader SET cachedReply = ?, replyTextMessage = ?, replyChangeCommand = ? WHERE id = ?",
                    arguments: [stored.body, stored.textMessage, stored.changeCommand, id])
            }
        }
        let header = try await row(db, id)
        let router = AgentToolRouter()
        return Fixture(db: db, router: router, header: header, accounts: accounts,
                       ctx: ToolContext(db: db, translator: MockChatIdTranslator(), router: router))
    }

    /// How the model answers: writes the reply, fails, or returns no email.
    enum Answer { case writes, fails, noEmail }

    nonisolated static func result(_ answer: Answer) throws -> InlineEditResult {
        switch answer {
        case .writes:
            return AIService.parseInlineEditResponse(ComposeEditJSON.make(
                response: "Done.", subject: "Re: Offsite", body: written, textMessage: writtenText,
                changeCommand: writtenCommand))!
        case .fails: throw InlineEditFailure(message: "The edit could not be read. Please try again.")
        case .noEmail: return AIService.inlineEditWithAIOff
        }
    }

    func row(_ db: DatabaseQueue, _ id: MessageHeader.ID) async throws -> MessageHeader {
        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: id) }
        return try #require(fetched)
    }

    /// The AI Suggestion the email's cache keeps (`MessageAICache`, restored on a resync).
    func cached(_ db: DatabaseQueue, _ header: MessageHeader) async throws -> ReplyResult? {
        let key = try #require(MessageAICache.cacheKey(
            accountId: header.accountId, folderPath: header.folderPath, rfc822MessageId: header.rfc822MessageId))
        return try await db.read { try MessageAICache.fetchOne($0, key: key)?.suggestion }
    }

    /// The card the field's Send opens for `words` with `onlyTo` chosen in Reply to, closed again;
    /// the router is cleared for the next card. With no card the compose's task is cancelled and
    /// drained before the test fails, so no request stays queued.
    func card(
        _ fixture: Fixture, calls: Calls, answer: Answer, onlyTo: [String]?
    ) async throws -> AgentToolRouter.ComposeRequest {
        let compose = ChatFieldCompose(context: fixture.ctx, composeText: { _, words, subject, context in
            calls.add(.init(context: context, subject: subject, body: "", request: words))
            return try Self.result(answer)
        })
        let invocation = ToolInvocation(
            fieldReply: ChatFieldReply(email: fixture.header, onlyTo: onlyTo), composeOrigin: Self.asked)
        let task = Task { @MainActor in await compose.reply(Self.words, invocation: invocation) }
        var pending: AgentToolRouter.ComposeRequest?
        let deadline = Date().addingTimeInterval(5)
        while pending == nil, Date() < deadline {
            pending = fixture.router.takeCompose(for: Self.chatHost)
            await Task.yield()
        }
        guard let card = pending else {
            task.cancel()
            _ = await task.value
            fixture.router.resetComposeQueueForTesting()
            Issue.record("the field's Send opens a reply card")
            throw NoCard()
        }
        card.onOutcome(.cancelled)
        _ = await task.value
        fixture.router.resetComposeQueueForTesting()
        return card
    }

    @Test("A reply narrowed in the field is written as the account it was received in, not the first or primary one")
    func narrowedReplyIsWrittenAsItsOwnAccount() async throws {
        let fixture = try await fixture(second: true)
        let calls = Calls()
        let card = try await card(fixture, calls: calls, answer: .writes, onlyTo: ["sender@example.com"])
        #expect(calls.all.count == 1)
        guard calls.all.count == 1 else { return }
        #expect(calls.all[0].context.senderEmail == "second@example.com")
        #expect(calls.all[0].request == Self.words, "the words as sent")
        #expect(card.body == Self.written && card.suggestion?.textMessage == Self.words,
                "the words written for the people chosen, never the stored suggestion")
        #expect(card.composeView(account: nil, onOutcome: { _ in }).onlyToChosen)
    }

    /// What the email stores before the narrowed card opens: the Reply All suggestion, nothing, or
    /// a reply holding the very value the card shows.
    enum Stored { case forEveryone, none, sameWords }

    @Test("An edit in a narrowed card is never stored as the email's suggestion, even after its recipients go back to everyone with the stored words showing",
          arguments: [Stored.forEveryone, .none, .sameWords])
    func narrowedCardEditIsNeverStored(_ storedCase: Stored) async throws {
        let seeded: ReplyResult? = switch storedCase {
        case .forEveryone: Self.stored
        case .none: nil
        case .sameWords: Self.sameWords
        }
        let fixture = try await fixture(stored: seeded)
        let before = try await row(fixture.db, fixture.header.id).suggestion
        let cachedBefore = try await cached(fixture.db, fixture.header)
        let card = try await card(fixture, calls: Calls(), answer: .writes, onlyTo: ["sender@example.com"])
        let view = card.composeView(account: nil, onOutcome: { _ in })
        // What the card shows and later compares an edit against (`ComposeView.prepopulate`).
        let shown = try #require(ComposeDraftGuards.suggestionToShow(
            given: ComposeView.givenSuggestion(view.suggestion, suggestedBody: view.suggestedBody),
            isReply: true, onlyToChosen: view.onlyToChosen, freshSuggestion: { Self.stored }))
        #expect(shown.body == Self.written, "the card shows the words written for the people chosen")
        if storedCase == .sameWords {
            #expect(shown == before, "control: the card shows exactly the value stored")
        }

        let subject = card.subject ?? ""
        let opened = ChatReplyCompose(
            isReplyAll: card.isReplyAll, to: card.to, cc: card.cc, bcc: card.bcc, subject: subject).recipients
        let envelope = ChatReplyCompose.suggestionEnvelope(for: fixture.header, accounts: fixture.accounts)
        let editBody = "Hi Sam,\n\nI will be there.\n\nAlex"
        let edited = ReplyResult(body: editBody, textMessage: "I will be there.", changeCommand: nil)
        for (recipients, editSubject, label) in [(opened, subject, "as opened"), (envelope.recipients, envelope.subject, "back to everyone")] {
            // `applyInlineEdit`: the edit and the email whose suggestion it would replace.
            let edit = ComposeView.suggestionEdit(
                body: editBody, textMessage: "I will be there.", changeCommand: nil,
                showingSuggestion: true, isForward: false, onlyToChosen: view.onlyToChosen, replyTo: fixture.header,
                recipients: recipients, subject: editSubject, accountId: nil, accounts: fixture.accounts)
            #expect(edit.edited == edited, "\(label): the card shows the edit")
            #expect(edit.target == nil, "\(label): the edit stays in the card")
            if let value = edit.edited, let target = edit.target {
                await ComposeView.writeCachedReplyToDB(value, replacing: shown, replyTo: target, db: fixture.db)
            }
            let after = try await row(fixture.db, fixture.header.id).suggestion
            #expect(after == before, "\(label): the suggestion is unchanged")
            let cachedAfter = try await cached(fixture.db, fixture.header)
            #expect(cachedAfter == cachedBefore, "\(label): the cached suggestion is unchanged")
        }

        // Control: an ordinary Reply All card showing the same value, in the same envelope,
        // decides through the same function and stores through the same writer.
        guard let before else { return }
        let eligible = ComposeView.suggestionEdit(
            body: editBody, textMessage: "I will be there.", changeCommand: nil,
            showingSuggestion: true, isForward: false, onlyToChosen: false, replyTo: fixture.header,
            recipients: envelope.recipients, subject: envelope.subject, accountId: nil, accounts: fixture.accounts)
        let target = try #require(eligible.target, "control: the Reply All card targets the email")
        let value = try #require(eligible.edited)
        let outcome = await ComposeView.writeCachedReplyToDB(value, replacing: before, replyTo: target, db: fixture.db)
        #expect(outcome == .written)
        let stored = try await row(fixture.db, fixture.header.id).suggestion
        #expect(stored == edited, "control: the Reply All card's edit replaces the suggestion")
        let cachedStored = try await cached(fixture.db, fixture.header)
        #expect(cachedStored == edited, "control: and the cache")
    }

    @Test("Recompute in a narrowed card writes for the card's people as a reply with no request, and stores nothing")
    func narrowedRecomputeIsWrittenForTheCardsPeople() async throws {
        let fixture = try await fixture()
        let context = ComposeEditContext.make(
            recipients: ChatReplyCompose.onlyTo(["sender@example.com"], replying: fixture.header).recipients,
            account: fixture.accounts[0], mode: "edit_reply", related: fixture.header,
            relatedBodyText: Self.emailText, compositionPrompt: "", kbText: "")
        let calls = Calls()
        let result = await ComposeView.recomputedReplyForChosen(context: context, composeEdit: { context, subject, body, request in
            calls.add(.init(context: context, subject: subject, body: body, request: request))
            return try Self.result(.writes)
        })
        #expect(result == ReplyResult(body: Self.written, textMessage: Self.writtenText, changeCommand: Self.writtenCommand),
                "the new reply, whole, for the card")
        #expect(calls.all.count == 1)
        guard calls.all.count == 1 else { return }
        let call = calls.all[0]
        #expect(call.request == "" && call.subject == "" && call.body == "", "a reply asked for with no request")
        #expect(call.context.toRecipients == ["sender@example.com"] && call.context.ccRecipients.isEmpty,
                "written for the card's people")
        #expect(call.context.bodyText == Self.emailText, "the card's context, as read")
        let after = try await row(fixture.db, fixture.header.id).suggestion
        #expect(after == Self.stored, "nothing is stored")
    }

    @Test("Recompute in a narrowed card that writes nothing gives no new suggestion",
          arguments: [Answer.fails, .noEmail])
    func narrowedRecomputeFailureGivesNothing(_ answer: Answer) async throws {
        let fixture = try await fixture()
        let context = ComposeEditContext.make(
            recipients: ChatReplyCompose.onlyTo(["sender@example.com"], replying: fixture.header).recipients,
            account: fixture.accounts[0], mode: "edit_reply", related: fixture.header,
            relatedBodyText: nil, compositionPrompt: "", kbText: "")
        let result = await ComposeView.recomputedReplyForChosen(context: context, composeEdit: { _, _, _, _ in
            try Self.result(answer)
        })
        #expect(result == nil)
        let after = try await row(fixture.db, fixture.header.id).suggestion
        #expect(after == Self.stored)
    }

    @Test("Recompute in a narrowed card that writes an empty email gives no new suggestion")
    func narrowedRecomputeEmptyBodyGivesNothing() async throws {
        let fixture = try await fixture()
        let context = ComposeEditContext.make(
            recipients: ChatReplyCompose.onlyTo(["sender@example.com"], replying: fixture.header).recipients,
            account: fixture.accounts[0], mode: "edit_reply", related: fixture.header,
            relatedBodyText: nil, compositionPrompt: "", kbText: "")
        // The edit's own result with an empty body (a parsed answer never has one), with the other
        // fields set, so only the empty body decides.
        let empty = InlineEditResult(
            response: "Done.", subject: "Re: Offsite", body: "", toDelta: nil, ccDelta: nil, bccDelta: nil,
            textMessage: Self.writtenText, changeCommand: Self.writtenCommand, raw: "")
        let result = await ComposeView.recomputedReplyForChosen(context: context, composeEdit: { _, _, _, _ in empty })
        #expect(result == nil)
    }
}
