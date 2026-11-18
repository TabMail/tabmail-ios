/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import os
@testable import TabMail

/// The compose edit at protocol 2.0.0 (ADR-IOS-114): the backend answers a client that sends the
/// 2.0.0 marker with the compose edit as JSON, so this app's marker and its JSON reader ship
/// together.
///
/// THE SYSTEM PROPERTY pinned here: whatever version this build sends, a compose edit the backend
/// sends it never puts raw JSON into a draft. At 2.0.0 or later the edit's body is the JSON's
/// `body`; labelled text is not read as an edit.
@Suite("The 2.0.0 marker travels with the compose edit JSON reader", .serialized, .processGlobalState)
struct ComposeEditMarkerTests {

    static let body = "Hi Sam,\n\nThank you for the invitation. I will attend.\n\nBest regards,\nAlex"

    /// Answers `/completions/chat` with `assistant` as the backend's final event, and keeps the
    /// protocol version the request carried.
    static func backend(_ assistant: String, version: OSAllocatedUnfairLock<String?>) -> FakeHTTP.Scenario {
        let http = FakeHTTP.Scenario()
        http.register(path: "/completions/chat", method: "POST") { request in
            let sent = request.headers.first { $0.key.lowercased() == "x-client-version" }?.value
            version.withLock { $0 = sent }
            let final = (try? JSONSerialization.data(withJSONObject: ["assistant": assistant])) ?? Data()
            let stream = "event: final\ndata: " + String(decoding: final, as: UTF8.self) + "\n\n"
            return .bytes(Data(stream.utf8), contentType: "text/event-stream")
        }
        return http
    }

    static let context = ComposeEditContext(
        recipients: ["sam@example.com"], toRecipients: ["sam@example.com"], ccRecipients: [], bccRecipients: [],
        toDisplayNames: [:], ccDisplayNames: [:], bccDisplayNames: [:],
        senderName: "Alex", senderEmail: "alex@example.com", mode: "edit_reply",
        compositionPrompt: "", kbText: "", relatedDate: "", relatedSubject: "Offsite",
        relatedFrom: "Sam <sam@example.com>", relatedTo: "alex@example.com", relatedCc: "", bodyText: "Are you in?")

    static func edit(_ assistant: String) async throws -> (InlineEditResult, String?) {
        let saved = AIService.optOutStore.object(forKey: AIService.optOutAllAIKey)
        AIService.optOutStore.set(false, forKey: AIService.optOutAllAIKey)
        defer { AIService.optOutStore.set(saved, forKey: AIService.optOutAllAIKey) }
        let version = OSAllocatedUnfairLock<String?>(initialState: nil)
        let http = backend(assistant, version: version)
        defer { http.close() }
        let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        let result = try await service.performInlineEdit(
            currentSubject: "Re: Offsite", currentBody: "Count me in.", context: context,
            instruction: "more formal", chatHistory: [])
        return (result, version.withLock { $0 })
    }

    static func atLeast2(_ version: String) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        return (parts.first ?? 0) >= 2
    }

    @Test("At 2.0.0 the backend's compose edit JSON becomes the draft's body, never raw JSON")
    func markerAndReader() async throws {
        let json = ComposeEditJSON.make(
            response: "Made it more formal.", subject: "Re: Offsite", body: Self.body,
            textMessage: "I will attend, thank you.", changeCommand: "decline instead")
        let (result, version) = try await Self.edit(json)

        let sent = try #require(version)
        #expect(sent == BackendClient.clientVersion, "the edit carries this build's marker")
        // The marker this build sends is the one the backend answers with JSON.
        #expect(Self.atLeast2(sent), "this build sends the JSON protocol marker; its reader is required")
        #expect(result.body == Self.body)
        #expect(result.textMessage == "I will attend, thank you.")
        #expect(result.changeCommand == "decline instead")
        for (name, value) in [("response", result.response), ("subject", result.subject), ("body", result.body),
                              ("text", result.textMessage), ("command", result.changeCommand)] {
            let text = value ?? ""
            #expect(!text.hasPrefix("{") && !text.contains("\"body\"") && !text.contains("text_message"),
                    "\(name) holds raw JSON: \(text)")
        }
    }

    @Test("Labelled text from the backend changes no draft field")
    func labelledTextChangesNothing() async throws {
        let (result, _) = try await Self.edit("Response: Done.\nSubject: Re: Offsite\nBody: \(Self.body)")
        #expect(result.body == nil)
        #expect(result.subject == nil)
        #expect(result.textMessage == nil)
        #expect(result.toDelta == nil && result.ccDelta == nil && result.bccDelta == nil)
    }
}

/// A request from the chat's reply field while its AI Suggestion shows (ADR-IOS-114).
///
/// THE SYSTEM PROPERTIES pinned here, through `EmailReplyTool` with the compose edit answered as
/// the backend would:
///  1. The request is a compose edit OF the suggestion shown, in the draft its card would open
///     with: the suggestion's envelope (sender, subject, To/Cc/Bcc by role) and its body.
///  2. In place, only while the edited draft is still that envelope: the edit, its text version
///     and command replace the suggestion through the one writer; no card opens. Otherwise the
///     card opens with exactly the edited envelope and the stored suggestion is unchanged.
///  3. A failed edit, a newer suggestion stored meanwhile, or a row that is no longer the email
///     shown leaves the stored suggestion as it is.
///  4. The field's audience applies to the email's copies in the same account, never another
///     account's; its suggestion belongs to the displayed row alone.
@Suite("A field request edits the AI Suggestion showing")
@MainActor
struct SuggestionRewriteRouteTests {

    nonisolated static let shown = "Hi Sam,\n\nCount me in!\n\nAlex"
    nonisolated static let shownText = "Count me in!"
    nonisolated static let shownReply = ReplyResult(body: shown, textMessage: shownText)
    nonisolated static let editedBody = "Dear Sam,\n\nThank you for the invitation. I will attend.\n\nKind regards,\nAlex"
    nonisolated static let editedText = "Thank you, I will attend."
    nonisolated static let editedCommand = "ask for the agenda"

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
        let translator: MockChatIdTranslator
        let ctx: ToolContext
    }

    func fixture() async throws -> Fixture {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "s1", subject: "Offsite", rfc822MessageId: "<offsite@example.com>")
        try await db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET cachedReply = ?, replyTextMessage = ? WHERE id = ?",
                           arguments: [Self.shown, Self.shownText, header.id])
        }
        let translator = MockChatIdTranslator()
        await translator.seed(header.id, as: 1)
        let router = AgentToolRouter()
        return Fixture(db: db, router: router, header: header, translator: translator,
                       ctx: ToolContext(db: db, translator: translator, router: router))
    }

    /// The one writer, into the test's database.
    static func store(_ db: DatabaseQueue) -> EmailReplyTool.StoreSuggestionEdit {
        { edit, shown, email in await ComposeView.writeCachedReplyToDB(edit, replacing: shown, replyTo: email, db: db) }
    }

    func tool(_ fixture: Fixture, calls: Calls, answer: InlineEditResult?) -> EmailReplyTool {
        EmailReplyTool(context: fixture.ctx, composeEdit: { context, subject, body, request in
            calls.add(.init(context: context, subject: subject, body: body, request: request))
            if let answer { return answer }
            throw InlineEditFailure(message: "The edit could not be read. Please try again.")
        }, storeSuggestionEdit: Self.store(fixture.db))
    }

    nonisolated static func edit(subject: String = "Re: Offsite", addCc: [[String: Any]] = [], removeTo: [String] = []) -> InlineEditResult {
        AIService.parseInlineEditResponse(ComposeEditJSON.make(
            response: "Done.", removeTo: removeTo, addCc: addCc, subject: subject, body: editedBody,
            textMessage: editedText, changeCommand: editedCommand))!
    }

    func invocation(_ header: MessageHeader, onlyTo: [String]? = nil, suggestion: ReplyResult? = shownReply) -> ToolInvocation {
        ToolInvocation(fieldReply: ChatFieldReply(email: header, onlyTo: onlyTo, suggestion: suggestion))
    }

    func row(_ db: DatabaseQueue, _ id: MessageHeader.ID) async throws -> MessageHeader {
        try #require(try await db.read { try MessageHeader.fetchOne($0, key: id) })
    }

    func waitForCard(_ router: AgentToolRouter) async -> AgentToolRouter.ComposeRequest? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let request = router.pendingCompose { return request }
            await Task.yield()
        }
        return router.pendingCompose
    }

    let request: [String: JSONValue] = ["unique_id": .int(1), "request": .string("more formal")]

    @Test("In place: the edit of the shown suggestion, asked in its own envelope, replaces it; no card opens")
    func rewritesInPlace() async throws {
        let fixture = try await fixture()
        let calls = Calls()
        let output = try await tool(fixture, calls: calls, answer: Self.edit()).run(
            arguments: request, invocation: invocation(fixture.header), rewritesInPlace: true)

        let call = try #require(calls.all.first)
        #expect(call.body == Self.shown, "the suggestion shown is the draft edited")
        #expect(call.request == "more formal", "the user's words are the request, as written")
        #expect(call.subject == "Re: Offsite", "the draft's own subject, not an empty one")
        #expect(call.context.senderEmail == "test@example.com", "the email's own account sends it")
        let envelope = ChatReplyCompose.suggestionEnvelope(for: fixture.header, accounts: [])
        #expect(call.context.toRecipients == envelope.to && call.context.ccRecipients == envelope.cc,
                "To and Cc by role, as the card holds them")
        let row = try await row(fixture.db, fixture.header.id)
        #expect(row.suggestion == ReplyResult(body: Self.editedBody, textMessage: Self.editedText, changeCommand: Self.editedCommand))
        #expect(ChatReplyField.suggestionText(newest: row, usersTurn: false, onlyTo: nil) == Self.editedText,
                "the ghost shows the edit's text version")
        #expect(fixture.router.pendingCompose == nil, "no compose card opens")
        #expect(output.contains("in place") && output.contains(Self.editedText) && output.contains("Nothing was sent"))
    }

    @Test("End to end: a field request dispatched through the tool registry edits the suggestion shown, in place")
    func fieldThroughRegistryEditsInPlace() async throws {
        let fixture = try await fixture()
        let calls = Calls()
        let registry = ToolRegistry()
        await registry.registerAll([tool(fixture, calls: calls, answer: Self.edit())])
        let result = await registry.execute(name: "email_reply", arguments: request, invocation: invocation(fixture.header))

        #expect(result.ok)
        #expect(calls.all.first?.body == Self.shown, "the field's suggestion reaches the edit through dispatch")
        #expect(try await row(fixture.db, fixture.header.id).cachedReply == Self.editedBody)
        #expect(fixture.router.pendingCompose == nil)
        #expect(result.output.contains("in place"))
    }

    @Test("Not in place: the card opens with the edited envelope, and the stored suggestion is unchanged")
    func opensTheCard() async throws {
        let fixture = try await fixture()
        let tool = tool(fixture, calls: Calls(), answer: Self.edit())
        let invocation = invocation(fixture.header)
        let task = Task { @MainActor in try await tool.run(arguments: request, invocation: invocation, rewritesInPlace: false) }
        let card = try #require(await waitForCard(fixture.router))
        #expect(card.body == Self.editedBody && card.subject == "Re: Offsite")
        #expect(try await row(fixture.db, fixture.header.id).suggestion == Self.shownReply)
        card.onOutcome(.cancelled)
        #expect(try await task.value.contains("Opened the reply card"))
    }

    @Test("An edit that changes the subject or empties To opens the card with exactly that envelope")
    func editBeyondTheSuggestionOpensTheCard() async throws {
        let cases: [(InlineEditResult, (AgentToolRouter.ComposeRequest) -> Bool)] = [
            (Self.edit(subject: "Re: New plan"), { $0.subject == "Re: New plan" }),
            (Self.edit(addCc: [["name": "Pat", "email": "pat@example.com"]], removeTo: ["*"]),
             { $0.to.isEmpty && $0.cc.contains { $0.contains("pat@example.com") } }),
        ]
        for (answer, check) in cases {
            let fixture = try await fixture()
            let tool = tool(fixture, calls: Calls(), answer: answer)
            let invocation = invocation(fixture.header)
            let task = Task { @MainActor in try await tool.run(arguments: request, invocation: invocation, rewritesInPlace: true) }
            let card = try #require(await waitForCard(fixture.router))
            #expect(check(card), "the request carries the edited subject and recipients")
            // The card shows them exactly: an empty To stays empty, the subject is kept, and the
            // saved reply draft is not loaded over it.
            let reply = ChatReplyCompose.make(agent: card, accounts: [])
            let view = reply.composeView(
                replyTo: card.replyTo, suggestedBody: card.body,
                draftId: Draft.separateReplyKey(replyTo: "\(fixture.header.accountId):\(fixture.header.stableId)"),
                onAgentOutcome: { _ in })
            #expect(view.prefillTo == card.to && view.prefillSubject == card.subject)
            #expect(view.prefillDraftId != nil)
            #expect(try await row(fixture.db, fixture.header.id).suggestion == Self.shownReply)
            card.onOutcome(.cancelled)
            #expect(try await task.value.contains("Opened the reply card"), "the outcome says which path ran")
        }
    }

    @Test("The reply tool's own recipient changes count: they open the card, never the ghost")
    func toolRecipientChangesOpenTheCard() async throws {
        let fixture = try await fixture()
        let tool = tool(fixture, calls: Calls(), answer: Self.edit())
        let arguments = request.merging(["remove_recipients": .array([.string("recipient@example.com")])]) { $1 }
        let invocation = invocation(fixture.header)
        let task = Task { @MainActor in try await tool.run(arguments: arguments, invocation: invocation, rewritesInPlace: true) }
        let card = try #require(await waitForCard(fixture.router))
        #expect(!card.to.contains("recipient@example.com"))
        #expect(try await row(fixture.db, fixture.header.id).suggestion == Self.shownReply)
        card.onOutcome(.cancelled)
        _ = try await task.value
    }

    @Test("A failed edit leaves the suggestion as it was, and opens no card")
    func failedEditChangesNothing() async throws {
        let fixture = try await fixture()
        let output = try await tool(fixture, calls: Calls(), answer: nil).run(
            arguments: request, invocation: invocation(fixture.header), rewritesInPlace: true)
        #expect(try await row(fixture.db, fixture.header.id).suggestion == Self.shownReply)
        #expect(fixture.router.pendingCompose == nil)
        #expect(output.lowercased().contains("unchanged"))
    }

    @Test("A newer suggestion stored while the edit ran wins; the edit is not kept")
    func newerSuggestionWins() async throws {
        let fixture = try await fixture()
        let db = fixture.db
        let id = fixture.header.id
        let tool = EmailReplyTool(context: fixture.ctx, composeEdit: { _, _, _, _ in
            try await db.write { db in
                try db.execute(sql: "UPDATE messageHeader SET replyChangeCommand = 'newer' WHERE id = ?", arguments: [id])
            }
            return Self.edit()
        }, storeSuggestionEdit: Self.store(db))
        let output = try await tool.run(arguments: request, invocation: invocation(fixture.header), rewritesInPlace: true)
        #expect(try await row(db, id).cachedReply == Self.shown, "a change of the command alone is a newer suggestion")
        #expect(output.contains("not kept"))
    }

    @Test("With no suggestion showing, the request writes a fresh reply on the card, as before")
    func noSuggestionOpensAFreshReply() async throws {
        let fixture = try await fixture()
        let calls = Calls()
        let tool = tool(fixture, calls: calls, answer: Self.edit())
        let invocation = invocation(fixture.header, suggestion: nil)
        let task = Task { @MainActor in try await tool.run(arguments: request, invocation: invocation, rewritesInPlace: true) }
        let card = try #require(await waitForCard(fixture.router))
        #expect(calls.all.first?.body == "", "no draft: a fresh reply")
        #expect(calls.all.first?.request.hasPrefix("Reply to email with subject") == true)
        #expect(card.body == Self.editedBody)
        #expect(try await row(fixture.db, fixture.header.id).suggestion == Self.shownReply)
        card.onOutcome(.cancelled)
        _ = try await task.value
    }

    @Test("A swapped occupant of the shown row refuses the field's edit")
    func swappedRowRefuses() async throws {
        let fixture = try await fixture()
        let db = fixture.db
        let id = fixture.header.id
        // Between the request's resolve and its read, a resync seats another email at the address.
        await fixture.translator.setOnResolve {
            try? await db.write { db in
                try db.execute(sql: "UPDATE messageHeader SET messageId = 'other', rfc822MessageId = '<other@example.com>' WHERE id = ?",
                               arguments: [id])
            }
        }
        let calls = Calls()
        let output = try await tool(fixture, calls: calls, answer: Self.edit()).run(
            arguments: request, invocation: invocation(fixture.header), rewritesInPlace: true)
        #expect(calls.all.isEmpty, "the edit is never asked against another email")
        #expect(try await row(db, id).cachedReply == Self.shown)
        #expect(fixture.router.pendingCompose == nil)
        #expect(output.lowercased().contains("unchanged"))
    }

    @Test("The field's audience applies to a same-account copy and never to another account's; its suggestion to the shown row only")
    func audienceByAccountSuggestionByRow() async throws {
        let fixture = try await fixture()
        try TestDatabase.insertFolder(fixture.db, name: "Archive", path: "Archive", role: .archive)
        try TestDatabase.insertAccount(fixture.db, id: "acc2", email: "second@example.com")
        try TestDatabase.insertFolder(fixture.db, accountId: "acc2")
        let sameAccount = try TestDatabase.insertMessageHeader(
            fixture.db, messageId: "s2", subject: "Offsite", folderId: "acc1:Archive", folderPath: "Archive",
            rfc822MessageId: "<offsite@example.com>")
        let otherAccount = try TestDatabase.insertMessageHeader(
            fixture.db, messageId: "s3", subject: "Offsite", folderId: "acc2:INBOX", accountId: "acc2",
            rfc822MessageId: "<offsite@example.com>")
        for copy in [sameAccount, otherAccount] {
            try await fixture.db.write { db in
                try db.execute(sql: "UPDATE messageHeader SET cachedReply = ?, replyTextMessage = ? WHERE id = ?",
                               arguments: [Self.shown, Self.shownText, copy.id])
            }
        }
        await fixture.translator.seed(sameAccount.id, as: 2)
        await fixture.translator.seed(otherAccount.id, as: 3)
        let field = invocation(fixture.header, onlyTo: ["sender@example.com"])
        for (number, copy, keepsAudience) in [(2, sameAccount, true), (3, otherAccount, false)] {
            let calls = Calls()
            let tool = tool(fixture, calls: calls, answer: Self.edit())
            let arguments: [String: JSONValue] = ["unique_id": .int(number), "request": .string("more formal")]
            let task = Task { @MainActor in try await tool.run(arguments: arguments, invocation: field, rewritesInPlace: true) }
            let card = try #require(await waitForCard(fixture.router))
            #expect((card.fieldReply?.onlyTo == ["sender@example.com"]) == keepsAudience)
            #expect(calls.all.first?.body == "", "the field's suggestion is not this copy's draft")
            #expect(try await row(fixture.db, copy.id).suggestion == Self.shownReply, "no suggestion edit stored on a copy")
            card.onOutcome(.cancelled)
            _ = try await task.value
            fixture.router.pendingCompose = nil
        }
    }

    @Test("The writer replaces only the exact suggestion expected: body, text and command each count")
    func writerComparesEachField() async throws {
        let edit = ReplyResult(body: Self.editedBody, textMessage: Self.editedText, changeCommand: Self.editedCommand)
        for expected in [ReplyResult(body: "other", textMessage: Self.shownText),
                         ReplyResult(body: Self.shown, textMessage: "other"),
                         ReplyResult(body: Self.shown, textMessage: Self.shownText, changeCommand: "other")] {
            let fixture = try await fixture()
            let outcome = await ComposeView.writeCachedReplyToDB(edit, replacing: expected, replyTo: fixture.header, db: fixture.db)
            #expect(outcome == .dropped)
            #expect(try await row(fixture.db, fixture.header.id).suggestion == Self.shownReply)
            let cache = try await fixture.db.read { try MessageAICache.fetchAll($0) }
            #expect(cache.allSatisfy { $0.cachedReply != Self.editedBody }, "the losing write touches neither store")
        }
        let fixture = try await fixture()
        #expect(await ComposeView.writeCachedReplyToDB(edit, replacing: Self.shownReply, replyTo: fixture.header, db: fixture.db) == .written)
        #expect(try await row(fixture.db, fixture.header.id).suggestion == edit)
    }

    @Test("A stored edit is in the on-device AI cache: a header rebuilt from it gets the edit")
    func editWritesThroughToTheCache() async throws {
        let fixture = try await fixture()
        let edit = ReplyResult(body: Self.editedBody, textMessage: Self.editedText, changeCommand: Self.editedCommand)
        #expect(await ComposeView.writeCachedReplyToDB(edit, replacing: Self.shownReply, replyTo: fixture.header, db: fixture.db) == .written)
        var cleared = fixture.header
        cleared.cachedReply = nil
        cleared.replyTextMessage = nil
        cleared.replyChangeCommand = nil
        let base = cleared
        let rebuilt = try await fixture.db.write { db in
            var fresh = base
            try MessageAICache.restoreIfCached(into: &fresh, accountId: base.accountId, folderPath: base.folderPath, db: db)
            return fresh
        }
        #expect(rebuilt.suggestion == edit)
    }

    @Test("A late automatic reply never lands over an accepted edit; a new email's empty slot is filled")
    func lateAutomaticReplyLoses() async throws {
        let fixture = try await fixture()
        let edit = ReplyResult(body: Self.editedBody, textMessage: Self.editedText)
        #expect(await ComposeView.writeCachedReplyToDB(edit, replacing: Self.shownReply, replyTo: fixture.header, db: fixture.db) == .written)
        let late = ReplyResult(body: "Late automatic reply", textMessage: "Late")
        // The automatic job read the slot before the edit: it expects what it read.
        let lateOutcome = try await fixture.db.write { db -> AIWriteOutcome in
            let target = try #require(try AIWriteTarget.capture(message: fixture.header, db: db))
            return try AccountManager.storeSuggestion(late, replacing: Self.shownReply, target: target, db: db)
        }
        #expect(lateOutcome == .dropped)
        #expect(try await row(fixture.db, fixture.header.id).suggestion == edit)

        // A new email in the thread is a new row with an empty slot; its job fills it, and the
        // filtered sentinel is refilled by a later job.
        let newer = try TestDatabase.insertMessageHeader(fixture.db, messageId: "s9", subject: "Re: Offsite")
        for (value, expected) in [(ReplyResult.filtered, nil), (late, ReplyResult.filtered)] as [(ReplyResult, ReplyResult?)] {
            let outcome = try await fixture.db.write { db -> AIWriteOutcome in
                let target = try #require(try AIWriteTarget.capture(message: newer, db: db))
                return try AccountManager.storeSuggestion(value, replacing: expected, target: target, db: db)
            }
            #expect(outcome == .written)
        }
        #expect(try await row(fixture.db, newer.id).suggestion == late)
    }

    @Test("A card edit for another audience stays in the card: the ghost keeps the Reply All suggestion")
    func narrowedCardEditNeverReachesTheGhost() async throws {
        let fixture = try await fixture()
        let envelope = ChatReplyCompose.suggestionEnvelope(for: fixture.header, accounts: [])
        let subject = try #require(envelope.subject)
        #expect(envelope.holds(recipients: envelope.recipients, subject: subject, accountId: "acc1", of: fixture.header),
                "control: the Reply All draft is the suggestion's")
        let narrowed = envelope.recipients.applying(
            to: AIService.parseInlineEditResponse(ComposeEditJSON.make(removeTo: ["recipient@example.com"]))?.toDelta,
            cc: nil, bcc: nil)
        #expect(!envelope.holds(recipients: narrowed, subject: subject, accountId: "acc1", of: fixture.header))
        #expect(!envelope.holds(recipients: envelope.recipients, subject: "Fwd: Offsite", accountId: "acc1", of: fixture.header))
        #expect(!envelope.holds(recipients: envelope.recipients, subject: subject, accountId: "acc2", of: fixture.header))
        // Tapping the ghost again opens the Reply All draft with the stored suggestion.
        let ghost = ChatReadyReply(message: try await row(fixture.db, fixture.header.id),
                                   compose: ChatReplyCompose.make(replyAllTo: fixture.header, accounts: []))
        #expect(ghost.compose.isReplyAll && Set(ghost.compose.to) == Set(envelope.to))
        #expect(ghost.message.suggestion == Self.shownReply)
    }
}
