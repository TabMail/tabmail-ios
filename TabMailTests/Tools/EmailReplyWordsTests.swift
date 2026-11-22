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
/// wrote new ones.
@Suite("Who the agent's reply is written for")
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

    /// The email from sender@example.com to the user's account and alex@example.com, Cc
    /// sam@example.com, holding the stored suggestion (`withSuggestion`). `second`: received in a
    /// second account (second@example.com), neither the first nor the primary one.
    func fixture(second: Bool = false, withSuggestion: Bool = true) async throws -> Fixture {
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
            if withSuggestion {
                try db.execute(
                    sql: "UPDATE messageHeader SET cachedReply = ?, replyTextMessage = ?, replyChangeCommand = ? WHERE id = ?",
                    arguments: [Self.stored.body, Self.stored.textMessage, Self.stored.changeCommand, id])
            }
        }
        let header = try await row(db, id)
        let translator = MockChatIdTranslator()
        await translator.seed(header.id, as: 1)
        let router = AgentToolRouter()
        return Fixture(db: db, router: router, header: header, accounts: accounts, translator: translator,
                       ctx: ToolContext(db: db, translator: translator, router: router))
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

    /// The card the reply tool opens for `arguments` asked from the field, closed again; the
    /// router is cleared for the next card.
    func card(
        _ fixture: Fixture, calls: Calls, answer: Answer, arguments: [String: JSONValue], onlyTo: [String]?
    ) async throws -> AgentToolRouter.ComposeRequest {
        let tool = tool(fixture, calls: calls, answer: answer)
        let invocation = field(fixture.header, onlyTo: onlyTo)
        let task = Task { @MainActor in try await tool.run(arguments: arguments, invocation: invocation, rewritesInPlace: true) }
        var pending: AgentToolRouter.ComposeRequest?
        let deadline = Date().addingTimeInterval(5)
        while pending == nil, Date() < deadline {
            pending = fixture.router.takeCompose(for: Self.chatHost)
            await Task.yield()
        }
        let card = try #require(pending, "the tool opens a reply card")
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

        #expect(card.body == Self.written, "the card opens with the words written for them")
        #expect(card.suggestion == nil, "the stored suggestion is not handed to the card")
        #expect(Set(card.to + card.cc + card.bcc) == Set(chosen) && !card.isReplyAll, "the card goes to the people chosen")
        let view = card.composeView(account: nil, onOutcome: { _ in })
        #expect(view.onlyToChosen, "the card knows it replies only to the people chosen")
        #expect(view.suggestion == nil && view.suggestedBody == Self.written)
        let after = try await row(fixture.db, fixture.header.id).suggestion
        #expect(after == Self.stored, "nothing is stored")
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

    @Test("An edit in a narrowed card is never stored as the email's suggestion, even after its recipients go back to everyone",
          arguments: [true, false])
    func narrowedCardEditIsNeverStored(_ withSuggestion: Bool) async throws {
        let fixture = try await fixture(withSuggestion: withSuggestion)
        let before = try await row(fixture.db, fixture.header.id).suggestion
        let card = try await card(fixture, calls: Calls(), answer: .writes, arguments: Self.noRequest, onlyTo: ["sender@example.com"])
        let view = card.composeView(account: nil, onOutcome: { _ in })
        // What the card shows and later compares an edit against (`ComposeView.prepopulate`).
        let shown = try #require(ComposeDraftGuards.suggestionToShow(
            given: ComposeView.givenSuggestion(view.suggestion, suggestedBody: view.suggestedBody),
            isReply: true, onlyToChosen: view.onlyToChosen, freshSuggestion: { Self.stored }))
        #expect(shown.body == Self.written, "the card shows the words written for the people chosen")

        let subject = card.subject ?? ""
        let opened = ChatReplyCompose(
            isReplyAll: card.isReplyAll, to: card.to, cc: card.cc, bcc: card.bcc, subject: subject).recipients
        let envelope = ChatReplyCompose.suggestionEnvelope(for: fixture.header, accounts: fixture.accounts)
        for (recipients, label) in [(opened, "as opened"), (envelope.recipients, "back to everyone")] {
            // `applyInlineEdit`: the edit and the email whose suggestion it would replace.
            let edit = ComposeView.suggestionEdit(
                body: "Hi Sam,\n\nI will be there.\n\nAlex", textMessage: "I will be there.", changeCommand: nil,
                showingSuggestion: true, isForward: false, replyTo: fixture.header, recipients: recipients,
                subject: subject, accountId: nil, accounts: fixture.accounts)
            if let value = edit.edited, let target = edit.target {
                let outcome = await ComposeView.writeCachedReplyToDB(value, replacing: shown, replyTo: target, db: fixture.db)
                #expect(outcome == .dropped, "\(label): the edit is not stored")
            }
            let after = try await row(fixture.db, fixture.header.id).suggestion
            #expect(after == before, "\(label): the suggestion is unchanged")
        }
        let asOpened = ComposeView.suggestionEditTarget(
            showingSuggestion: true, isForward: false, replyTo: fixture.header, recipients: opened,
            subject: subject, accountId: nil, accounts: fixture.accounts)
        #expect(asOpened == nil, "as opened the card is not the suggestion's envelope")

        // Control: the same writer stores an edit of the stored suggestion itself.
        if let before {
            let edit = ReplyResult(body: "Hi all,\n\nWe will be there.\n\nAlex", textMessage: "We will be there.")
            let outcome = await ComposeView.writeCachedReplyToDB(edit, replacing: before, replyTo: fixture.header, db: fixture.db)
            #expect(outcome == .written)
        }
    }

    @Test("Recompute in a narrowed card writes for the card's people as a reply with no request, and stores nothing")
    func narrowedRecomputeIsWrittenForTheCardsPeople() async throws {
        let fixture = try await fixture()
        let context = ComposeEditContext.make(
            recipients: ChatReplyCompose.onlyTo(["sender@example.com"], replying: fixture.header).recipients,
            account: fixture.accounts[0], mode: "edit_reply", related: fixture.header,
            relatedBodyText: "Are you coming to the offsite?", compositionPrompt: "", kbText: "")
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
        #expect(call.context.bodyText == "Are you coming to the offsite?", "the card's context, as read")
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
        let empty = try #require(AIService.parseInlineEditResponse(ComposeEditJSON.make(body: "")))
        let result = await ComposeView.recomputedReplyForChosen(context: context, composeEdit: { _, _, _, _ in empty })
        #expect(result == nil)
    }
}
