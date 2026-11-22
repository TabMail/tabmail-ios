/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// A reply the chat's reply field asked for with only some people chosen in Reply to (ADR-IOS-114
/// decision 11): its words are written for the people chosen; the email's stored AI Suggestion,
/// written for its whole Reply All audience, never stands in for them; and none of the card's words
/// is stored as that suggestion, whether the agent wrote them, the user edited them, or Recompute
/// wrote new ones. `.processGlobalState`: the tool reads the shared demo state
/// (`DemoToolGuard.headerAccessible`), which other suites hold across suspensions.
@Suite("Who the agent's reply is written for", .serialized, .processGlobalState)
@MainActor
struct EmailReplyWordsTests {
    static let asked = ComposeOrigin(sessionKey: "thread:chat", screen: .chat)
    static let chatHost = AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: [asked.sessionKey])

    /// The email's stored AI Suggestion, written for everyone.
    nonisolated static let stored = ReplyResult(
        body: "Hi all,\n\nCount us in!\n\nAlex", textMessage: "Count us in!", changeCommand: "decline instead")
    nonisolated static let written = "Hi Sam,\n\nCount me in!\n\nAlex"
    nonisolated static let writtenText = "Count me in!"
    nonisolated static let writtenCommand = "ask for the agenda"
    /// A Device Sync reply that happens to hold the very words written for the people chosen, with
    /// no text message or change command (`AccountManager.processOpenedMessage` stores that shape):
    /// the value a narrowed card shows (`ComposeView.givenSuggestion`) equals it.
    nonisolated static let sameWords = ReplyResult(body: written, textMessage: nil)
    /// Another email's own stored suggestion.
    nonisolated static let otherStored = ReplyResult(
        body: "Hi all,\n\nSee you at lunch.\n\nAlex", textMessage: "See you at lunch.", changeCommand: "suggest noon")
    /// The email's own text, distinct from its snippet.
    static let emailText = "Are you coming to the offsite on Friday?"
    /// Everyone on the email but the user: the sender, the other To and the Cc.
    static let everyone: Set<String> = ["sender@example.com", "alex@example.com", "sam@example.com"]

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
        let translator: MockChatIdTranslator
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
        let translator = MockChatIdTranslator()
        await translator.seed(header.id, as: 1)
        let router = AgentToolRouter()
        return Fixture(db: db, router: router, header: header, accounts: accounts, translator: translator,
                       ctx: ToolContext(db: db, translator: translator, router: router))
    }

    /// A second email in `accountId`, numbered 2, holding its own stored suggestion: another email
    /// (its own Message-ID), or the fixture email's copy in another account (the same one).
    func insertOther(_ fixture: Fixture, accountId: String, own: String, subject: String, rfc822: String) async throws -> MessageHeader {
        let inserted = try TestDatabase.insertMessageHeader(
            fixture.db, messageId: "w2", subject: subject, to: "\(own), alex@example.com",
            folderId: "\(accountId):INBOX", accountId: accountId, rfc822MessageId: rfc822)
        let other = Self.otherStored
        try await fixture.db.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET cc = ?, cachedReply = ?, replyTextMessage = ?, replyChangeCommand = ? WHERE id = ?",
                arguments: ["sam@example.com", other.body, other.textMessage, other.changeCommand, inserted.id])
        }
        let header = try await row(fixture.db, inserted.id)
        await fixture.translator.seed(header.id, as: 2)
        return header
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

    func tool(_ fixture: Fixture, calls: Calls, answer: Answer) -> EmailReplyTool {
        let db = fixture.db
        return EmailReplyTool(context: fixture.ctx, composeEdit: { context, subject, body, request in
            calls.add(.init(context: context, subject: subject, body: body, request: request))
            return try Self.result(answer)
        }, storeSuggestionEdit: { edit, shown, email in
            await ComposeView.writeCachedReplyToDB(edit, replacing: shown, replyTo: email, db: db)
        })
    }

    func field(_ header: MessageHeader, onlyTo: [String]?) -> ToolInvocation {
        // The field shows no AI Suggestion while some people are chosen (`ChatReplyField.shown`).
        ToolInvocation(fieldReply: ChatFieldReply(email: header, onlyTo: onlyTo), composeOrigin: Self.asked)
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

    /// The card the reply tool opens for `arguments` asked from the field showing `fieldEmail` (the
    /// fixture email when nil), closed again; the router is cleared for the next card. With no card
    /// the tool's task is cancelled and drained before the test fails, so no request stays queued.
    func card(
        _ fixture: Fixture, calls: Calls, answer: Answer, arguments: [String: JSONValue], onlyTo: [String]?,
        fieldEmail: MessageHeader? = nil
    ) async throws -> AgentToolRouter.ComposeRequest {
        let tool = tool(fixture, calls: calls, answer: answer)
        let invocation = field(fieldEmail ?? fixture.header, onlyTo: onlyTo)
        let task = Task { @MainActor in try await tool.run(arguments: arguments, invocation: invocation, rewritesInPlace: true) }
        var pending: AgentToolRouter.ComposeRequest?
        let deadline = Date().addingTimeInterval(5)
        while pending == nil, Date() < deadline {
            pending = fixture.router.takeCompose(for: Self.chatHost)
            await Task.yield()
        }
        guard let card = pending else {
            task.cancel()
            _ = try? await task.value
            fixture.router.resetComposeQueueForTesting()
            Issue.record("the tool opens a reply card")
            throw NoCard()
        }
        card.onOutcome(.cancelled)
        _ = try await task.value
        fixture.router.resetComposeQueueForTesting()
        return card
    }

    static let noRequest: [String: JSONValue] = ["unique_id": .int(1)]

    @Test("A reply narrowed in the field with no request is written for the people chosen, never the stored suggestion written for everyone",
          arguments: [["sender@example.com"], ["sender@example.com", "sam@example.com"]])
    func narrowedReplyWithNoRequestIsWrittenForThePeopleChosen(_ chosen: [String]) async throws {
        let fixture = try await fixture()
        try TestDatabase.insertMessageBody(fixture.db, headerId: fixture.header.id, htmlContent: "<p>\(Self.emailText)</p>")
        let calls = Calls()
        let card = try await card(fixture, calls: calls, answer: .writes, arguments: Self.noRequest, onlyTo: chosen)

        #expect(calls.all.count == 1, "the reply is written once")
        guard calls.all.count == 1 else { return }
        let call = calls.all[0]
        #expect(call.request == "" && call.subject == "" && call.body == "",
                "written as a reply asked for with no request: an empty draft and an empty request")
        #expect(call.context.mode == "edit_reply")
        #expect(Set(call.context.toRecipients + call.context.ccRecipients + call.context.bccRecipients) == Set(chosen),
                "the model writes for the people chosen alone: \(call.context.toRecipients) cc \(call.context.ccRecipients)")
        #expect(call.context.senderEmail == "test@example.com", "written as the account the reply is sent from")
        let bodyText = call.context.bodyText ?? ""
        #expect(bodyText.contains(Self.emailText) && !bodyText.contains(fixture.header.snippet),
                "the model reads the email's own text, not its snippet: \(bodyText)")

        #expect(card.body == Self.written, "the card opens with the words written for them")
        #expect(card.suggestion == nil, "the stored suggestion is not handed to the card")
        #expect(Set(card.to + card.cc + card.bcc) == Set(chosen) && !card.isReplyAll, "the card goes to the people chosen")
        let view = card.composeView(account: nil, onOutcome: { _ in })
        #expect(view.onlyToChosen, "the card knows it replies only to the people chosen")
        #expect(view.suggestion == nil && view.suggestedBody == Self.written)
        let after = try await row(fixture.db, fixture.header.id).suggestion
        #expect(after == Self.stored, "nothing is stored")
    }

    @Test("A reply narrowed in the field with a request is written for the people chosen, with the agent's request as Thunderbird wraps it")
    func narrowedReplyWithARequestIsWrittenForThePeopleChosen() async throws {
        let fixture = try await fixture()
        let calls = Calls()
        let card = try await card(fixture, calls: calls, answer: .writes,
                                  arguments: ["unique_id": .int(1), "request": .string("say yes")],
                                  onlyTo: ["sender@example.com"])
        #expect(calls.all.count == 1)
        guard calls.all.count == 1 else { return }
        let call = calls.all[0]
        #expect(call.request == "Reply to email with subject \"Offsite\" with request: say yes",
                "the agent's request, wrapped: \(call.request)")
        #expect(call.subject == "" && call.body == "", "an empty draft")
        #expect(call.context.toRecipients == ["sender@example.com"] && call.context.ccRecipients.isEmpty
                    && call.context.bccRecipients.isEmpty, "written for the people chosen")
        #expect(card.body == Self.written && card.suggestion == nil)
        #expect(card.composeView(account: nil, onOutcome: { _ in }).onlyToChosen)
    }

    @Test("Controls: with nobody chosen the card offers the stored suggestion; a body the agent gave is used as it is")
    func otherRepliesAreUnchanged() async throws {
        let fixture = try await fixture()
        let calls = Calls()
        let everyone = try await card(fixture, calls: calls, answer: .writes, arguments: Self.noRequest, onlyTo: nil)
        #expect(calls.all.isEmpty, "nobody chosen: nothing is written")
        #expect(everyone.suggestion == Self.stored && everyone.body == nil, "the stored suggestion, whole")
        #expect(Set(everyone.to + everyone.cc) == Self.everyone && everyone.isReplyAll)
        #expect(!everyone.composeView(account: nil, onOutcome: { _ in }).onlyToChosen)

        let given = try await card(fixture, calls: calls, answer: .writes,
                                   arguments: ["unique_id": .int(1), "body": .string("Friday works")],
                                   onlyTo: ["sender@example.com"])
        #expect(calls.all.isEmpty, "the agent's own body is not rewritten")
        #expect(given.body == "Friday works" && given.suggestion == nil)
    }

    /// The choice made in the field applies to a reply to the email it showed in that account
    /// alone (`ChatFieldReply.audienceApplies`). A reply with no request and no body to another
    /// email, or to the shown email's copy in another account, is an ordinary reply: nothing is
    /// written, and the card offers that email's own stored suggestion to everyone.
    @Test("Controls: a choice in the field that does not apply (another email, another account's copy) leaves a reply with no request unchanged",
          arguments: [false, true])
    func choiceThatDoesNotApplyLeavesTheReplyUnchanged(_ otherAccountsCopy: Bool) async throws {
        let fixture = try await fixture(second: otherAccountsCopy)
        let target = try await insertOther(
            fixture, accountId: "acc1", own: "test@example.com", subject: otherAccountsCopy ? "Offsite" : "Lunch",
            rfc822: otherAccountsCopy ? "<offsite@example.com>" : "<lunch@example.com>")
        let sameEmail = ChatThread.copyKey(target) == ChatThread.copyKey(fixture.header)
        let sameAccount = target.accountId == fixture.header.accountId
        if otherAccountsCopy {
            #expect(sameEmail && !sameAccount, "control: the same email, in another account")
        } else {
            #expect(!sameEmail && sameAccount, "control: another email, in the same account")
        }
        let choice = ChatFieldReply(email: fixture.header, onlyTo: ["sender@example.com"])
        #expect(!choice.audienceApplies(to: target), "control: the choice does not apply to the target")

        let calls = Calls()
        let card = try await card(fixture, calls: calls, answer: .writes, arguments: ["unique_id": .int(2)],
                                  onlyTo: ["sender@example.com"], fieldEmail: fixture.header)
        #expect(calls.all.isEmpty, "nothing is written")
        #expect(card.suggestion == Self.otherStored && card.body == nil, "the target's own stored suggestion, whole")
        #expect(Set(card.to + card.cc) == Self.everyone && card.isReplyAll, "a Reply All to the target's people")
        #expect(!card.composeView(account: nil, onOutcome: { _ in }).onlyToChosen, "an ordinary card")
        let after = try await row(fixture.db, target.id).suggestion
        #expect(after == Self.otherStored, "nothing is stored")
    }

    @Test("A reply narrowed in the field is written as the account it was received in, not the first or primary one")
    func narrowedReplyIsWrittenAsItsOwnAccount() async throws {
        let fixture = try await fixture(second: true)
        let calls = Calls()
        _ = try await card(fixture, calls: calls, answer: .writes, arguments: Self.noRequest, onlyTo: ["sender@example.com"])
        #expect(calls.all.count == 1)
        guard calls.all.count == 1 else { return }
        #expect(calls.all[0].context.senderEmail == "second@example.com")
    }

    @Test("A reply narrowed in the field whose writing fails opens empty, never with the stored suggestion written for everyone",
          arguments: [Answer.fails, .noEmail])
    func narrowedReplyNeverFallsBackToTheStoredSuggestion(_ answer: Answer) async throws {
        let fixture = try await fixture()
        for arguments in [Self.noRequest, ["unique_id": .int(1), "request": .string("say yes")]] {
            let calls = Calls()
            let card = try await card(fixture, calls: calls, answer: answer, arguments: arguments, onlyTo: ["sender@example.com"])
            #expect(calls.all.count == 1, "the writing was tried")
            #expect(card.body == nil && card.suggestion == nil, "no words, and not the stored ones")
            let view = card.composeView(account: nil, onOutcome: { _ in })
            #expect(view.onlyToChosen, "the card itself does not read the stored suggestion either")
        }
        // Control: with nobody chosen a failed request still opens on the stored suggestion.
        let control = try await card(fixture, calls: Calls(), answer: answer,
                                     arguments: ["unique_id": .int(1), "request": .string("say yes")], onlyTo: nil)
        #expect(control.suggestion == Self.stored)
    }

    /// What the email stores before the narrowed card opens: the Reply All suggestion, nothing, or
    /// a Device Sync reply holding the very words the card shows.
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
        let card = try await card(fixture, calls: Calls(), answer: .writes, arguments: Self.noRequest, onlyTo: ["sender@example.com"])
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
