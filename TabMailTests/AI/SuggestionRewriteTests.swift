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
        // The AI choice made, AI on (`AIService.isAIOff`), restored after.
        let restore = AITestSetting.save()
        defer { restore() }
        AITestSetting.set(aiOff: false)
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

    /// The producer's own example of the compose edit (the backend's
    /// `email_edit_json_response_format` v1.0.0, example B, verbatim): the shape the backend
    /// answers a 2.0.0 client with, not one written beside this reader.
    static let producerExample = #"{"response": "Swapped Bob for Alice in To.", "add_to": [{"name": "Alice Anderson", "email": "alice@example.com"}], "remove_to": ["bob@example.com"], "add_cc": [], "remove_cc": [], "add_bcc": [], "remove_bcc": [], "subject": "Re: Q1 budget review", "body": "Hi Alice,\n\nCould you take over the Q1 budget review from here?\n\nBest,\nUser Sign Off", "text_message": "Could you take over the Q1 budget review from here?", "change_command": "ask Alice to start later"}"#

    @Test("At 2.0.0 the backend's compose edit JSON becomes the draft's body, never raw JSON")
    func markerAndReader() async throws {
        let (result, version) = try await Self.edit(Self.producerExample)

        let sent = try #require(version)
        #expect(sent == BackendClient.clientVersion, "the edit carries this build's marker")
        // The marker this build sends is the one the backend answers with JSON.
        #expect(Self.atLeast2(sent), "this build sends the JSON protocol marker; its reader is required")
        #expect(result.response == "Swapped Bob for Alice in To.")
        #expect(result.subject == "Re: Q1 budget review")
        #expect(result.body == "Hi Alice,\n\nCould you take over the Q1 budget review from here?\n\nBest,\nUser Sign Off")
        #expect(result.textMessage == "Could you take over the Q1 budget review from here?")
        #expect(result.changeCommand == "ask Alice to start later")
        // The recipient changes by role: Alice added to To with her name, Bob removed from To.
        let to = try #require(result.toDelta)
        #expect(to.adds.recipients == [RecipientEntry.Recipient(address: "alice@example.com", name: "Alice Anderson")])
        #expect(to.removes == ["bob@example.com"] && !to.clearsField)
        #expect(result.ccDelta == nil && result.bccDelta == nil, "Cc and Bcc unchanged")
        for (name, value) in [("response", result.response), ("subject", result.subject), ("body", result.body),
                              ("text", result.textMessage), ("command", result.changeCommand)] {
            let text = value ?? ""
            #expect(!text.hasPrefix("{") && !text.contains("\"body\"") && !text.contains("text_message"),
                    "\(name) holds raw JSON: \(text)")
        }
    }

    @Test("Labelled text from the backend is a failed edit, shown as the other AI failures; no draft field changes")
    func labelledTextChangesNothing() async throws {
        await #expect(throws: InlineEditFailure.self) {
            _ = try await Self.edit("Response: Done.\nSubject: Re: Offsite\nBody: \(Self.body)")
        }
    }

    /// The context a new email's or a forward's compose edit sends (`EmailComposeTool.runComposeEdit`
    /// builds these modes; reply has its own case above).
    static func context(mode: String) -> ComposeEditContext {
        ComposeEditContext(
            recipients: ["pat@example.com"], toRecipients: ["pat@example.com"], ccRecipients: [], bccRecipients: [],
            toDisplayNames: [:], ccDisplayNames: [:], bccDisplayNames: [:],
            senderName: "Alex", senderEmail: "alex@example.com", mode: mode,
            compositionPrompt: "", kbText: "",
            relatedDate: mode == "edit_forward" ? "yesterday" : "",
            relatedSubject: mode == "edit_forward" ? "Offsite" : "",
            relatedFrom: mode == "edit_forward" ? "Sam <sam@example.com>" : "",
            relatedTo: mode == "edit_forward" ? "alex@example.com" : "", relatedCc: "",
            bodyText: mode == "edit_forward" ? "Are you in?" : "")
    }

    /// Every `"mode"` value anywhere in a request's JSON.
    static func modes(in value: Any) -> [String] {
        if let object = value as? [String: Any] {
            let own = (object["mode"] as? String).map { [$0] } ?? []
            return own + object.values.flatMap { modes(in: $0) }
        }
        if let array = value as? [Any] { return array.flatMap { modes(in: $0) } }
        return []
    }

    /// THE SYSTEM PROPERTY: the shared compose editor reads the 2.0.0 JSON for every mode its callers
    /// send (a new email, a forward), not only a reply; a malformed edit fails and puts no field in a
    /// draft. Through the real `performInlineEdit` request path against a fake backend.
    @Test("A new email's and a forward's compose edit read the backend's JSON; a malformed one fails",
          arguments: ["edit_new", "edit_forward"], [true, false])
    func everyModeReadsTheJSON(mode: String, wellFormed: Bool) async throws {
        let restore = AITestSetting.save()
        defer { restore() }
        AITestSetting.set(aiOff: false)
        let version = OSAllocatedUnfairLock<String?>(initialState: nil)
        let answer = wellFormed
            ? ComposeEditJSON.make(response: "Wrote it.", subject: "Offsite plans", body: Self.body,
                                   textMessage: "I will attend.", changeCommand: "")
            : ComposeEditJSON.make(response: "Wrote it.", subject: "Offsite plans", body: Self.body,
                                   textMessage: "I will attend.", changeCommand: "", drop: "body")
        let http = Self.backend(answer, version: version)
        defer { http.close() }
        let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        let edit: () async throws -> InlineEditResult = {
            try await service.performInlineEdit(
                currentSubject: "", currentBody: "", context: Self.context(mode: mode),
                instruction: "tell Pat I will attend", chatHistory: [])
        }
        if wellFormed {
            let result = try await edit()
            #expect(result.response == "Wrote it.")
            #expect(result.subject == "Offsite plans")
            #expect(result.body == Self.body, "the JSON's body becomes the draft's body")
            #expect(result.textMessage == "I will attend.")
            #expect(result.changeCommand == nil, "an empty command is no command")
            #expect(result.toDelta == nil && result.ccDelta == nil && result.bccDelta == nil)
        } else {
            await #expect(throws: InlineEditFailure.self, "a malformed edit fails; no draft field changes") {
                _ = try await edit()
            }
        }
        // The request went out once, as this mode (positive control that the mode reached the wire).
        let calls = http.recordedCalls()
        #expect(calls.count == 1)
        let sent = calls.first?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        #expect(sent.map { Self.modes(in: $0) }?.contains(mode) == true, "the request carries mode \(mode)")
    }
}

/// The AI Suggestion's card edits, its one writer, and the agent's reply on it (ADR-IOS-114
/// decisions 17 and 18). The chat view's closed field no longer edits the suggestion: its words
/// are the user's own message (decision 10, amended 2026-11-26; `ChatFieldComposeTests`).
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. A card's edit replaces the stored AI Suggestion only from the suggestion's own envelope for
///     the same email, through the one writer, and only over the exact value it edited.
///  2. The agent's reply (`EmailReplyTool`, the panel open) leaves the stored suggestion as it is:
///     its recipient changes and its request go to the card.
///  3. A compose edit's context never carries another email's body.
@Suite("The AI Suggestion's card edits and the agent's reply")
@MainActor
struct SuggestionRewriteRouteTests {

    /// The agent's requests are asked in the chat view, which takes their cards (ADR-IOS-053 Phase 2).
    static let asked = ComposeOrigin(sessionKey: "thread:chat", screen: .chat)
    static let chatHost = AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: [asked.sessionKey])

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

    /// The email, holding the shown suggestion. `imap`: on an IMAP account, at a numeric UID whose
    /// numbering (UIDVALIDITY 111) the folder and the row both observed, so a row that is no
    /// longer this email is told apart by its address's identity, not by a stable id.
    func fixture(imap: Bool = false) async throws -> Fixture {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: imap ? .imap : .gmail)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(
            db, messageId: imap ? "7" : "s1", subject: "Offsite", rfc822MessageId: "<offsite@example.com>")
        let id = header.id, folderId = header.folderId
        try await db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET cachedReply = ?, replyTextMessage = ? WHERE id = ?",
                           arguments: [Self.shown, Self.shownText, id])
            if imap {
                try db.execute(sql: "UPDATE folder SET lastKnownUidValidity = 111 WHERE id = ?", arguments: [folderId])
                try db.execute(sql: "UPDATE messageHeader SET observedUidValidity = 111 WHERE id = ?", arguments: [id])
            }
        }
        if imap {
            let fetched = try await db.read { try MessageHeader.fetchOne($0, key: id) }
            header = try #require(fetched)
        }
        let translator = MockChatIdTranslator()
        await translator.seed(header.id, as: 1)
        let router = AgentToolRouter()
        return Fixture(db: db, router: router, header: header, translator: translator,
                       ctx: ToolContext(db: db, translator: translator, router: router))
    }

    func tool(_ fixture: Fixture, calls: Calls, answer: InlineEditResult?) -> EmailReplyTool {
        EmailReplyTool(context: fixture.ctx, composeEdit: { context, subject, body, request in
            calls.add(.init(context: context, subject: subject, body: body, request: request))
            if let answer { return answer }
            throw InlineEditFailure(message: "The edit could not be read. Please try again.")
        })
    }

    nonisolated static func edit(
        subject: String = "Re: Offsite", addTo: [[String: Any]] = [], addCc: [[String: Any]] = [], removeTo: [String] = []
    ) -> InlineEditResult {
        AIService.parseInlineEditResponse(ComposeEditJSON.make(
            response: "Done.", addTo: addTo, removeTo: removeTo, addCc: addCc, subject: subject, body: editedBody,
            textMessage: editedText, changeCommand: editedCommand))!
    }

    /// The agent's request in the chat view (the panel open): no field travels with it.
    var invocation: ToolInvocation { ToolInvocation(composeOrigin: Self.asked) }

    func row(_ db: DatabaseQueue, _ id: MessageHeader.ID) async throws -> MessageHeader {
        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: id) }
        return try #require(fetched)
    }

    func waitForCard(_ router: AgentToolRouter) async -> AgentToolRouter.ComposeRequest? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let request = router.takeCompose(for: Self.chatHost) { return request }
            await Task.yield()
        }
        return router.takeCompose(for: Self.chatHost)
    }

    let request: [String: JSONValue] = ["unique_id": .int(1), "request": .string("more formal")]

    @Test("The agent's recipient changes count: they open the card, never the ghost")
    func toolRecipientChangesOpenTheCard() async throws {
        let fixture = try await fixture()
        let tool = tool(fixture, calls: Calls(), answer: Self.edit())
        let arguments = request.merging(["remove_recipients": .array([.string("recipient@example.com")])]) { $1 }
        let invocation = invocation
        let task = Task { @MainActor in try await tool.execute(arguments: arguments, invocation: invocation) }
        let card = try #require(await waitForCard(fixture.router))
        #expect(!card.to.contains("recipient@example.com"))
        #expect(try await row(fixture.db, fixture.header.id).suggestion == Self.shownReply)
        card.onOutcome(.cancelled)
        _ = try await task.value
    }

    @Test("The agent's request writes a fresh reply on the card, Thunderbird's call; the suggestion is unchanged")
    func agentRequestOpensAFreshReply() async throws {
        let fixture = try await fixture()
        let calls = Calls()
        let tool = tool(fixture, calls: calls, answer: Self.edit())
        let invocation = invocation
        let request = request
        let task = Task { @MainActor in try await tool.execute(arguments: request, invocation: invocation) }
        let card = try #require(await waitForCard(fixture.router))
        #expect(calls.all.first?.body == "", "no draft: a fresh reply")
        #expect(calls.all.first?.request == "Reply to email with subject \"Offsite\" with request: more formal")
        #expect(card.body == Self.editedBody && card.suggestion == nil, "the agent's card opens on the body alone")
        #expect(!card.isFieldsOwnReply && card.fieldReply == nil && card.draftId == nil, "not the field's: the reply's usual draft")
        #expect(try await row(fixture.db, fixture.header.id).suggestion == Self.shownReply)
        card.onOutcome(.cancelled)
        _ = try await task.value
    }

    @Test("A compose edit's body read refuses a row that is no longer the email; the email's own body is read")
    func bodyReadChecksTheEmail() async throws {
        let fixture = try await fixture(imap: true)
        let db = fixture.db, header = fixture.header
        func read() async throws -> String?? {
            try await db.read { db in try ComposeEditContext.relatedBodyText(of: header, db: db) }
        }
        // No body stored: the read holds, with no text (the context carries the snippet).
        let none = try await read()
        #expect(none != nil && none! == nil)
        try await db.write { db in
            try MessageBody(contentKey: ContentKey(rawValue: header.id), htmlContent: "<p>Are you in for the offsite?</p>").insert(db)
        }
        #expect(try await read() == .some("Are you in for the offsite?"), "control: the email's own body")
        // A reset seats another email, with its own body, at the same row and UID.
        try await db.write { db in
            try db.execute(sql: "UPDATE folder SET lastKnownUidValidity = 222 WHERE id = ?", arguments: [header.folderId])
            try db.execute(sql: "UPDATE messageHeader SET rfc822MessageId = '<other@example.com>', observedUidValidity = 222 WHERE id = ?",
                           arguments: [header.id])
            try db.execute(sql: "UPDATE messageBody SET htmlContent = '<p>Another email</p>' WHERE id = ?", arguments: [header.id])
        }
        let refused = try await read()
        #expect(refused == nil, "another email's body never goes out with this email's context")
    }

    @Test("A Reply-To that is the user's own address with an outside Cc: the ghost's card opens with To empty, never refilled")
    func ownReplyToKeepsToEmpty() async throws {
        let fixture = try await fixture()
        try await fixture.db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET replyTo = 'test@example.com', \"to\" = 'test@example.com', cc = 'pat@example.com' WHERE id = ?",
                           arguments: [fixture.header.id])
        }
        let email = try await row(fixture.db, fixture.header.id)
        let accounts = try await fixture.db.read { try Account.fetchAll($0) }
        let ready = ChatReadyReply(message: email, suggestion: Self.shownReply, accounts: accounts)
        let card = ready.composeView(openedOn: .chat, onOutcome: { _ in })
        // `nil` would let compose fill To from the reply's Reply-To, the user's own address.
        #expect(card.prefillTo == [], "To stays empty")
        #expect(card.prefillCc == ["pat@example.com"], "the outside Cc stays in Cc")
        // The agent's reply starts from the same envelope.
        let calls = Calls()
        let tool = tool(fixture, calls: calls, answer: Self.edit())
        let invocation = invocation
        let request = request
        // Bounded: the card is closed here, never awaited forever.
        let task = Task { @MainActor in try await tool.execute(arguments: request, invocation: invocation) }
        let opened = await waitForCard(fixture.router)
        opened?.onOutcome(.cancelled)
        _ = try await task.value
        let call = try #require(calls.all.first)
        #expect(call.context.toRecipients.isEmpty && call.context.ccRecipients == ["pat@example.com"])
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

    /// A late producer landing over an edit is pinned through the real producers
    /// (`SuggestionProducerOrderingTests`); this pins only how an empty slot fills.
    @Test("A new email's empty slot is filled, and the filtered sentinel is refilled by a later job")
    func emptySlotFills() async throws {
        let fixture = try await fixture()
        let late = ReplyResult(body: "Late automatic reply", textMessage: "Late")
        let newer = try TestDatabase.insertMessageHeader(fixture.db, messageId: "s9", subject: "Re: Offsite")
        for (value, expected) in [(ReplyResult.filtered, nil), (late, ReplyResult.filtered)] as [(ReplyResult, ReplyResult?)] {
            let outcome = try await fixture.db.write { db -> AIWriteOutcome in
                let captured = try AIWriteTarget.capture(message: newer, db: db)
                let target = try #require(captured)
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
        let subject = envelope.subject
        #expect(envelope.holds(recipients: envelope.recipients, subject: subject, accountId: "acc1", of: fixture.header),
                "control: the Reply All draft is the suggestion's")
        let narrowed = envelope.recipients.applying(
            to: AIService.parseInlineEditResponse(ComposeEditJSON.make(removeTo: ["recipient@example.com"]))?.toDelta,
            cc: nil, bcc: nil)
        #expect(!envelope.holds(recipients: narrowed, subject: subject, accountId: "acc1", of: fixture.header))
        #expect(!envelope.holds(recipients: envelope.recipients, subject: "Fwd: Offsite", accountId: "acc1", of: fixture.header))
        #expect(!envelope.holds(recipients: envelope.recipients, subject: subject, accountId: "acc2", of: fixture.header))
        // Tapping the ghost again opens the Reply All draft with the stored suggestion.
        let stored = try await row(fixture.db, fixture.header.id)
        let ghost = ChatReadyReply(message: stored, suggestion: try #require(stored.suggestion), accounts: [])
        #expect(ghost.compose == envelope)
        #expect(ghost.suggestion == Self.shownReply)
    }

    /// What a card's edit of its shown suggestion does to the stored AI Suggestion.
    enum CardEdit: String, CaseIterable, Sendable {
        /// Control: the ghost's own Reply All, unchanged: the edit replaces the suggestion.
        case sameEnvelope
        case narrowedAudience, otherSubject, otherSender, forward, suggestionNotShown
        /// The envelope holds, but another email now sits at the row: nothing is stored.
        case replacedRow
    }

    /// THE SYSTEM PROPERTY: a card's edit replaces the stored AI Suggestion only when the card is
    /// still the suggestion's own Reply All (same sender, subject and audience) for the same email;
    /// any other card keeps its edit to itself. Through the card's own decision
    /// (`ComposeView.suggestionEditTarget`, what `applyInlineEdit` asks) and the one writer it then
    /// calls, with the card's real inputs.
    @Test("A card's edit replaces the AI Suggestion only from the suggestion's own Reply All, for the same email",
          arguments: CardEdit.allCases)
    func cardEditReachesTheGhostOnlyFromItsEnvelope(_ edit: CardEdit) async throws {
        let fixture = try await fixture(imap: true)
        let header = fixture.header
        let envelope = ChatReplyCompose.suggestionEnvelope(for: header, accounts: [])
        var recipients = envelope.recipients
        var subject = envelope.subject
        var accountId: String? = nil
        if edit == .narrowedAudience {
            recipients = recipients.applying(
                to: AIService.parseInlineEditResponse(ComposeEditJSON.make(removeTo: ["recipient@example.com"]))?.toDelta,
                cc: nil, bcc: nil)
            #expect(recipients != envelope.recipients, "control: the audience narrowed")
        }
        if edit == .otherSubject { subject = "Fwd: Offsite" }
        if edit == .otherSender { accountId = "acc2" }
        if edit == .replacedRow {
            try await fixture.db.write { db in
                try db.execute(sql: "UPDATE folder SET lastKnownUidValidity = 222 WHERE id = ?", arguments: [header.folderId])
                try db.execute(sql: "UPDATE messageHeader SET rfc822MessageId = '<other@example.com>', observedUidValidity = 222 WHERE id = ?",
                               arguments: [header.id])
            }
        }
        let target = ComposeView.suggestionEditTarget(
            showingSuggestion: edit != .suggestionNotShown, isForward: edit == .forward, replyTo: header,
            recipients: recipients, subject: subject, accountId: accountId, accounts: [])
        let edited = ReplyResult(body: Self.editedBody, textMessage: Self.editedText, changeCommand: Self.editedCommand)
        if let target {
            await ComposeView.writeCachedReplyToDB(edited, replacing: Self.shownReply, replyTo: target, db: fixture.db)
        }
        let stored = try await row(fixture.db, header.id).suggestion
        switch edit {
        case .sameEnvelope:
            #expect(target?.id == header.id, "control: the suggestion's own card targets its email")
            #expect(stored == edited, "the edit replaces the AI Suggestion whole")
        case .replacedRow:
            #expect(target?.id == header.id, "the card itself still holds the envelope")
            #expect(stored == Self.shownReply, "another email's row is never written")
        default:
            #expect(target == nil, "\(edit.rawValue): the edit stays in its card")
            #expect(stored == Self.shownReply, "\(edit.rawValue): the AI Suggestion is unchanged")
        }
    }

    /// THE SYSTEM PROPERTY: a reply card the agent opens on the stored AI Suggestion (the reply
    /// tool with no request and no body) keeps the user's in-card edit as the suggestion, as the
    /// ghost's own card does; and a suggestion stored meanwhile still wins over that edit.
    @Test("An agent-opened card on the stored suggestion stores the card's edit; a newer suggestion stored meanwhile wins",
          arguments: [false, true])
    func agentOpenedCardEditReplacesTheSuggestion(_ newerStoredMeanwhile: Bool) async throws {
        let fixture = try await fixture()
        let header = fixture.header
        let stored = ReplyResult(body: Self.shown, textMessage: Self.shownText, changeCommand: "decline politely")
        try await fixture.db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET replyChangeCommand = ? WHERE id = ?",
                           arguments: [stored.changeCommand, header.id])
        }
        let calls = Calls()
        let tool = tool(fixture, calls: calls, answer: nil)
        let task = Task { @MainActor in
            try await tool.execute(arguments: ["unique_id": .int(1)], invocation: ToolInvocation(composeOrigin: Self.asked))
        }
        let card = try #require(await waitForCard(fixture.router))
        #expect(calls.all.isEmpty, "no request: no model edit runs")
        // The card as every host presents it, and the suggestion it shows and compares against.
        let view = card.composeView(account: nil, onOutcome: { _ in })
        let shown = try #require(ComposeView.givenSuggestion(view.suggestion, suggestedBody: view.suggestedBody))
        #expect(shown.body == Self.shown)

        if newerStoredMeanwhile {
            try await fixture.db.write { db in
                try db.execute(sql: "UPDATE messageHeader SET replyChangeCommand = 'newer' WHERE id = ?", arguments: [header.id])
            }
        }
        // The user's in-card edit, within the suggestion's own envelope.
        let envelope = ChatReplyCompose.suggestionEnvelope(for: header, accounts: [])
        let target = try #require(ComposeView.suggestionEditTarget(
            showingSuggestion: true, isForward: false, replyTo: header,
            recipients: envelope.recipients, subject: envelope.subject, accountId: nil, accounts: []))
        let edited = ReplyResult(body: Self.editedBody, textMessage: Self.editedText, changeCommand: Self.editedCommand)
        let outcome = await ComposeView.writeCachedReplyToDB(edited, replacing: shown, replyTo: target, db: fixture.db)

        let row = try await row(fixture.db, header.id)
        if newerStoredMeanwhile {
            #expect(outcome == .dropped)
            #expect(row.suggestion == ReplyResult(body: Self.shown, textMessage: Self.shownText, changeCommand: "newer"),
                    "the newer suggestion stays")
        } else {
            #expect(outcome == .written, "the card compared against the stored value whole")
            #expect(row.suggestion == edited, "the header holds the edit")
            var cleared = header
            cleared.cachedReply = nil
            cleared.replyTextMessage = nil
            cleared.replyChangeCommand = nil
            let base = cleared
            let rebuilt = try await fixture.db.write { db in
                var fresh = base
                try MessageAICache.restoreIfCached(into: &fresh, accountId: base.accountId, folderPath: base.folderPath, db: db)
                return fresh
            }
            #expect(rebuilt.suggestion == edited, "the on-device AI cache holds the edit")
        }
        card.onOutcome(.cancelled)
        _ = try await task.value
    }

    /// The on-device AI cache's copy of `header`'s suggestion: the row's columns cleared, then
    /// restored from the cache.
    func cachedSuggestion(_ db: DatabaseQueue, _ header: MessageHeader) async throws -> ReplyResult? {
        var cleared = header
        cleared.cachedReply = nil
        cleared.replyTextMessage = nil
        cleared.replyChangeCommand = nil
        let base = cleared
        return try await db.write { db in
            var fresh = base
            try MessageAICache.restoreIfCached(into: &fresh, accountId: base.accountId, folderPath: base.folderPath, db: db)
            return fresh
        }.suggestion
    }

    /// THE SYSTEM PROPERTY: an accepted card edit of the shown suggestion becomes the AI Suggestion
    /// WHOLE (body, text message and change command as the edit returned them), in the header and
    /// the cache, and the chat's ghost and its "alt: " line show it. Through the card's own
    /// transition (`ComposeView.suggestionEdit`, what `applyInlineEdit` builds and stores), twice:
    /// the second edit compares against the first, so the card's shown value must advance.
    @Test("A card's edits become the whole AI Suggestion in header and cache, and the ghost shows each")
    func cardEditStoresTheWholeEditedValue() async throws {
        let fixture = try await fixture()
        let header = fixture.header
        let envelope = ChatReplyCompose.suggestionEnvelope(for: header, accounts: [])
        let edits = [
            (body: Self.editedBody, text: Self.editedText, command: Self.editedCommand),
            (body: "Dear Sam,\n\nI will attend and bring the slides.\n\nAlex",
             text: "I will bring the slides.", command: "offer to present"),
        ]
        var shown: ReplyResult? = Self.shownReply
        for (index, step) in edits.enumerated() {
            let edit = ComposeView.suggestionEdit(
                body: step.body, textMessage: step.text, changeCommand: step.command,
                showingSuggestion: true, isForward: false, onlyToChosen: false, replyTo: header,
                recipients: envelope.recipients, subject: envelope.subject, accountId: nil, accounts: [])
            let expected = ReplyResult(body: step.body, textMessage: step.text, changeCommand: step.command)
            #expect(edit.edited == expected, "edit \(index): the card shows the whole edited value")
            let value = try #require(edit.edited)
            let target = try #require(edit.target, "control: the suggestion's own card targets its email")
            let outcome = await ComposeView.writeCachedReplyToDB(value, replacing: shown, replyTo: target, db: fixture.db)
            #expect(outcome == .written, "edit \(index): stored over the value the card showed")
            shown = edit.edited

            let row = try await row(fixture.db, header.id)
            #expect(row.suggestion == expected, "edit \(index): the header holds the whole edit")
            #expect(try await cachedSuggestion(fixture.db, header) == expected, "edit \(index): the cache holds the whole edit")
            let ghost = ChatReplyField.shown(newest: row, usersTurn: false, onlyTo: nil)
            #expect(ghost == expected, "edit \(index): the ghost shows the edit")
            #expect(ChatReplyField.alternative(shown: ghost) == step.command,
                    "edit \(index): the alt line is the edit's one-line alternative")
        }
    }

    /// The card's draft as `applyInlineEdit` keeps it: the shown suggestion, replaced by each
    /// update through the card's own transition and stored over the value shown before.
    @MainActor
    final class CardDraft {
        var shown: ReplyResult?
        var subject: String
        var applied: [ReplyResult] = []
        let header: MessageHeader
        let envelope: ChatReplyCompose
        let db: DatabaseQueue
        init(shown: ReplyResult?, header: MessageHeader, db: DatabaseQueue) {
            self.shown = shown
            self.header = header
            self.db = db
            envelope = ChatReplyCompose.suggestionEnvelope(for: header, accounts: [])
            subject = envelope.subject
        }
        func apply(_ newSubject: String?, _ body: String?, _ to: RecipientDelta?, _ cc: RecipientDelta?,
                   _ bcc: RecipientDelta?, _ text: String?, _ command: String?) async {
            let previous = shown
            let edit = ComposeView.suggestionEdit(
                body: body, textMessage: text, changeCommand: command,
                showingSuggestion: true, isForward: false, onlyToChosen: false, replyTo: header,
                recipients: envelope.recipients.applying(to: to, cc: cc, bcc: bcc), subject: newSubject ?? subject,
                accountId: nil, accounts: [])
            if let newSubject { subject = newSubject }
            shown = edit.edited
            if let value = edit.edited {
                applied.append(value)
                if let target = edit.target {
                    await ComposeView.writeCachedReplyToDB(value, replacing: previous, replyTo: target, db: db)
                }
            }
        }
    }

    /// One accepted compose edit as `sendComposeEdit` runs it: the draft it edits (`editBase`),
    /// the result applied through the card's update, then the turn it records (`editTurn`).
    @MainActor
    func acceptedEdit(_ request: String, result: InlineEditResult, anchor: InlineEditTurn? = nil,
                      card: CardDraft) async -> InlineEditTurn {
        let base = DynamicIslandChat.editBase(anchor: anchor, draftSubject: card.subject,
                                              draftBody: card.shown?.body, draftSuggestion: card.shown)
        await card.apply(result.subject, result.body, result.toDelta, result.ccDelta, result.bccDelta,
                         result.textMessage, result.changeCommand)
        return DynamicIslandChat.editTurn(instruction: request, subject: base.subject, body: base.body,
                                          atRequest: base.atRequest, assistantResponse: result.raw)
    }

    nonisolated static func result(body: String, text: String, command: String) -> InlineEditResult {
        AIService.parseInlineEditResponse(ComposeEditJSON.make(
            response: "Done.", subject: "Re: Offsite", body: body, textMessage: text, changeCommand: command))!
    }

    /// Which history replay puts an earlier draft back.
    enum Replay: String, CaseIterable, Sendable { case resend, rewind }

    /// THE SYSTEM PROPERTY: a resend or rewind puts back the WHOLE suggestion its turn edited (body,
    /// text message and change command) in the header and the cache, before its own result lands;
    /// the result then replaces it whole. Starts from real accepted edits, whose recorded turns
    /// carry the suggestion's text and command (`editTurn`, what `sendComposeEdit` appends).
    @MainActor
    @Test("A resend or rewind restores the edited turn's whole suggestion before its held result lands",
          arguments: Replay.allCases)
    func replayRestoresTheWholeSuggestion(_ replay: Replay) async throws {
        let fixture = try await fixture()
        let header = fixture.header
        let original = ReplyResult(body: Self.shown, textMessage: Self.shownText, changeCommand: "decline politely")
        try await fixture.db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET replyChangeCommand = ? WHERE id = ?",
                           arguments: [original.changeCommand, header.id])
        }
        let card = CardDraft(shown: original, header: header, db: fixture.db)
        let first = Self.result(body: Self.editedBody, text: Self.editedText, command: Self.editedCommand)
        let second = Self.result(body: "Dear Sam,\n\nI will attend.\n\nAlex", text: "I will attend.", command: "ask about parking")
        var history = [await acceptedEdit("more formal", result: first, card: card)]
        history.append(await acceptedEdit("shorter", result: second, card: card))
        let firstValue = ReplyResult(body: Self.editedBody, textMessage: Self.editedText, changeCommand: Self.editedCommand)

        // The recorded turns carry the whole suggestion each request edited.
        guard history.count == 2 else { return }
        #expect(history[0].bodyAtRequest == original.body)
        #expect(history[0].textMessageAtRequest == original.textMessage)
        #expect(history[0].changeCommandAtRequest == original.changeCommand)
        #expect(history[1].bodyAtRequest == firstValue.body)
        #expect(history[1].textMessageAtRequest == firstValue.textMessage)
        #expect(history[1].changeCommandAtRequest == firstValue.changeCommand)

        let picked = replay == .resend
            ? DynamicIslandChat.resendAnchor(history)
            : DynamicIslandChat.rewindAnchor(history, userMessagesBefore: 0)
        let anchor = try #require(picked.anchor)
        let restored = replay == .resend ? firstValue : original
        #expect(picked.history.count == (replay == .resend ? 1 : 0), "the restored turn and later ones leave the history")

        // The replay's result is held until the restore has been checked.
        let replayed = Self.result(body: "Dear Sam,\n\nYes, I will attend.\n\nAlex", text: "Yes, I will attend.", command: "suggest a date")
        let (release, held) = AsyncStream<Void>.makeStream()
        let request = Task { @MainActor in
            await DynamicIslandChat.restoreDraft(anchor, through: card.apply)
            for await _ in release { break }
            return await acceptedEdit("again", result: replayed, anchor: anchor, card: card)
        }
        let deadline = Date().addingTimeInterval(2)
        while card.shown != restored, Date() < deadline { await Task.yield() }
        #expect(card.shown == restored, "the card shows the restored suggestion whole")
        #expect(try await row(fixture.db, header.id).suggestion == restored, "the header holds the restored value whole")
        #expect(try await cachedSuggestion(fixture.db, header) == restored, "the cache holds the restored value whole")

        held.yield()
        held.finish()
        let turn = await request.value
        let finalValue = ReplyResult(body: replayed.body ?? "", textMessage: replayed.textMessage, changeCommand: replayed.changeCommand)
        #expect(try await row(fixture.db, header.id).suggestion == finalValue, "the result replaces the restored value")
        #expect(try await cachedSuggestion(fixture.db, header) == finalValue)
        #expect(turn.textMessageAtRequest == restored.textMessage && turn.changeCommandAtRequest == restored.changeCommand,
                "the replayed request edited the restored suggestion")
        #expect(Array(card.applied.suffix(2)) == [restored, finalValue], "the restore lands before the result")
    }

    /// A card whose recipient field holds an entry that is not an address (rejected), one the
    /// suggestion's envelope does not hold, is not that envelope: its edit stays in the card.
    @Test("A card holding a rejected recipient entry keeps its edit; the same card without it is the suggestion's")
    func rejectedEntryIsNotTheEnvelope() async throws {
        let fixture = try await fixture()
        let envelope = ChatReplyCompose.suggestionEnvelope(for: fixture.header, accounts: [])
        #expect(envelope.holds(recipients: envelope.recipients, subject: envelope.subject, accountId: "acc1", of: fixture.header),
                "control: the unchanged card is the suggestion's")
        for role in ComposeDraftGuards.RecipientRole.allCases {
            var recipients = envelope.recipients
            recipients[role].rejected = ["not an address"]
            #expect(!envelope.holds(recipients: recipients, subject: envelope.subject, accountId: "acc1", of: fixture.header),
                    "\(role): a rejected entry")
            #expect(ComposeView.suggestionEditTarget(
                showingSuggestion: true, isForward: false, replyTo: fixture.header,
                recipients: recipients, subject: envelope.subject, accountId: nil, accounts: []) == nil,
                    "\(role): the edit stays in its card")
        }
    }

    /// A Reply-To entry that names no address (`Undisclosed-Recipients:;`) is part of the
    /// suggestion's envelope as its text, in any case. A card edit that keeps every address but
    /// leaves that entry out is another audience: it stays in the card. One that keeps it is the
    /// suggestion's own envelope: the card's edit replaces the suggestion (ADR-IOS-114 decision 17).
    @Test("A card edit that leaves out an audience entry with no address stays in the card; one that keeps it replaces the suggestion",
          arguments: [false, true])
    func audienceEntryWithNoAddressDecidesInPlace(keepsEntry: Bool) async throws {
        let fixture = try await fixture()
        try await fixture.db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET replyTo = ? WHERE id = ?",
                           arguments: ["sender@example.com, Undisclosed-Recipients:;", fixture.header.id])
        }
        let email = try await row(fixture.db, fixture.header.id)
        let envelope = ChatReplyCompose.suggestionEnvelope(for: email, accounts: [])
        #expect(envelope.to == ["sender@example.com", "Undisclosed-Recipients:;", "recipient@example.com"] && envelope.cc.isEmpty,
                "control: the envelope holds the entry as written, beside the addresses")

        let everyAddress: [[String: Any]] = [
            ["name": "", "email": "sender@example.com"], ["name": "", "email": "recipient@example.com"],
        ]
        let answer = keepsEntry ? Self.edit() : Self.edit(addTo: everyAddress, removeTo: ["*"])
        let after = envelope.recipients.applying(to: answer.toDelta, cc: answer.ccDelta, bcc: answer.bccDelta)
        let cardTarget = ComposeView.suggestionEditTarget(
            showingSuggestion: true, isForward: false, replyTo: email,
            recipients: after, subject: envelope.subject, accountId: nil, accounts: [])
        if keepsEntry {
            // An envelope is the same in any order (`ChatReplyCompose.holds`).
            #expect(cardTarget?.id == email.id, "the entry kept: the card's edit replaces the suggestion")
            let otherCase = envelope.recipients.filling(
                to: RecipientEntry(["sender@example.com", "UNDISCLOSED-RECIPIENTS:;", "recipient@example.com"]))
            #expect(otherCase.to.rejected == ["UNDISCLOSED-RECIPIENTS:;"], "control: the entry kept, written in another case")
            let otherCaseTarget = ComposeView.suggestionEditTarget(
                showingSuggestion: true, isForward: false, replyTo: email,
                recipients: otherCase, subject: envelope.subject, accountId: nil, accounts: [])
            #expect(otherCaseTarget?.id == email.id, "the entry kept in another case: still the suggestion's envelope")
            // Another entry in its place: not the suggestion's envelope.
            let otherEntry = envelope.recipients.filling(
                to: RecipientEntry(["sender@example.com", "Private-List:;", "recipient@example.com"]))
            let otherEntryTarget = ComposeView.suggestionEditTarget(
                showingSuggestion: true, isForward: false, replyTo: email,
                recipients: otherEntry, subject: envelope.subject, accountId: nil, accounts: [])
            #expect(otherEntryTarget == nil, "another entry in its place: the edit stays in the card")
            // The entry moved to Cc, every address in its role: not the suggestion's envelope.
            let movedToCc = envelope.recipients.filling(
                to: RecipientEntry(["sender@example.com", "recipient@example.com"]), cc: RecipientEntry(["Undisclosed-Recipients:;"]))
            #expect(movedToCc.cc.rejected == ["Undisclosed-Recipients:;"], "control: the entry moved to Cc")
            let movedTarget = ComposeView.suggestionEditTarget(
                showingSuggestion: true, isForward: false, replyTo: email,
                recipients: movedToCc, subject: envelope.subject, accountId: nil, accounts: [])
            #expect(movedTarget == nil, "the entry in another field: the edit stays in the card")
            // Two entries, in another order: still the suggestion's envelope.
            var twoEntries = email
            twoEntries.replyTo = "sender@example.com, Undisclosed-Recipients:;, Private-List:;"
            let twoEnvelope = ChatReplyCompose.suggestionEnvelope(for: twoEntries, accounts: [])
            let reordered = twoEnvelope.recipients.filling(
                to: RecipientEntry(["sender@example.com", "Private-List:;", "Undisclosed-Recipients:;", "recipient@example.com"]))
            #expect(reordered.to.rejected == ["Private-List:;", "Undisclosed-Recipients:;"], "control: both entries, reordered")
            let reorderedTarget = ComposeView.suggestionEditTarget(
                showingSuggestion: true, isForward: false, replyTo: twoEntries,
                recipients: reordered, subject: twoEnvelope.subject, accountId: nil, accounts: [])
            #expect(reorderedTarget?.id == email.id, "the same entries in another order: still the suggestion's envelope")
        } else {
            #expect(after.to.tokens.map { $0.lowercased() } == ["sender@example.com", "recipient@example.com"]
                    && after.to.rejected.isEmpty, "control: every address kept, the entry left out")
            #expect(cardTarget == nil, "the entry left out: another audience, the edit stays in the card")
        }
    }
}

/// The AI Suggestion has one value, one writer and one envelope builder (ADR-IOS-114 decision 18).
/// These fences keep a second path from coming back: every production Swift file under the app's
/// sources is read, so a new file is covered too.
@Suite("The AI Suggestion keeps one value, one writer and one envelope")
struct SuggestionSinglePathFenceTests {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every Swift file of the app and the shared sources, by path relative to the repository.
    static func sources() throws -> [(path: String, text: String)] {
        var files: [(String, String)] = []
        for folder in ["TabMail", "Shared"] {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let path = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                files.append((path, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return files
    }

    static func lines(matching pattern: String, in files: [(path: String, text: String)]) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return files.flatMap { file in
            file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
                let text = String(line)
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"),
                      regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return nil }
                return "\(file.path):\(index + 1)"
            }
        }
    }

    /// The two files that own the suggestion's columns: the header's and the cache's value accessors.
    static let owners: Set<String> = ["TabMail/Models/MessageHeader.swift", "TabMail/Models/MessageAICache.swift"]

    static func file(of line: String) -> String { String(line.prefix { $0 != ":" }) }

    /// Where `files` name the suggestion's columns, by `path:line`.
    struct Census {
        /// Files that write or compare a column bare (`cachedReply = value.body`).
        let bareFiles: Set<String>
        /// Member reads or writes of a column (dotted, or bare) outside the owners.
        let outside: [String]
        /// SQL naming a column outside the owners, and the part of it that does not only schedule.
        let sql: [String]
        let unscheduled: [String]
    }

    static func census(_ files: [(path: String, text: String)]) throws -> Census {
        let columns = #"(cachedReply|replyTextMessage|replyChangeCommand)"#
        // Any member access to a column, read or write, dotted (`x.cachedReply`) or bare inside its
        // owner (`cachedReply = value.body`).
        let access = try Self.lines(matching: #"\.\#(columns)\b"#, in: files)
        let bare = try Self.lines(matching: #"(^|[^\w."])\#(columns)\s*(=[^=]|!=|==)"#, in: files)
        // SQL may name a column only to schedule (IS NULL) or to declare it, never to write or read
        // a value: a raw INSERT or SELECT list bypasses the value.
        let scheduling = try NSRegularExpression(pattern: #"\#(columns)\s+IS\s+(NOT\s+)?NULL"#)
        func text(_ location: String) throws -> String {
            let path = Self.file(of: location)
            let number = Int(location.split(separator: ":").last ?? "") ?? 0
            let source = try #require(files.first { $0.path == path }).text
            return String(source.split(separator: "\n", omittingEmptySubsequences: false)[number - 1])
        }
        func schedules(_ location: String) throws -> Bool {
            let line = try text(location)
            return scheduling.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        let outside = try (access + bare).filter { try !Self.owners.contains(Self.file(of: $0)) && !schedules($0) }
        let sql = try Self.lines(matching: #"(^|[^\w."])\#(columns)\b(?!\s*[:=!])"#, in: files).filter { !Self.owners.contains(Self.file(of: $0)) }
        let unscheduled = try sql.filter { try !schedules($0) }
        return Census(bareFiles: Set(bare.map(Self.file)), outside: outside, sql: sql, unscheduled: unscheduled)
    }

    @Test("The suggestion's columns are read and written only through the one value")
    func columnsWrittenWhole() throws {
        let files = try Self.sources()
        #expect(files.count > 100, "control: the sources were found")
        let census = try Self.census(files)
        #expect(census.bareFiles == Self.owners, "control: both owners write their columns in their accessors")
        #expect(census.outside.isEmpty, "a column read or written outside the one value: \(census.outside)")
        #expect(!census.sql.isEmpty, "control: the scheduling predicates name the column")
        #expect(census.unscheduled.isEmpty, "SQL that writes or reads the suggestion's columns: \(census.unscheduled)")
    }

    @Test("Control: the column census flags a planted read, write, raw INSERT and SELECT, and passes a scheduling predicate")
    func columnCensusFlagsPlantedForms() throws {
        let planted = [
            #"header.cachedReply = "x""#,
            #"let text = message.replyTextMessage"#,
            #"try db.execute(sql: "INSERT INTO messageHeader (id, cachedReply) VALUES (?, ?)")"#,
            #""SELECT replyChangeCommand FROM messageHeader""#,
            #"WHERE cachedReply IS NULL"#,
        ].joined(separator: "\n")
        let census = try Self.census([("TabMail/Planted.swift", planted)])
        #expect(census.outside == ["TabMail/Planted.swift:1", "TabMail/Planted.swift:2"])
        #expect(census.unscheduled == ["TabMail/Planted.swift:3", "TabMail/Planted.swift:4"])
        #expect(census.sql.contains("TabMail/Planted.swift:5"), "the scheduling line names the column and passes")
    }

    /// The one file allowed to REPLACE a stored suggestion (a non-nil expected value): the central
    /// writer `AccountManager.storeSuggestion`, which writes the header and the cache together.
    static let replacer = "TabMail/Services/Account/AccountManagerAI.swift"

    /// `replaceSuggestion(with:ifStill:)` calls whose expected value is not `nil`, by `path:offset`.
    /// A call may span lines, so the whole file is matched; a signature mention in a comment
    /// (`replaceSuggestion(with:ifStill:)`, no space after `with:`) is not a call.
    static func replacements(_ files: [(path: String, text: String)]) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"\.replaceSuggestion\(with:\s[\s\S]*?ifStill:\s*([A-Za-z_][\w.]*)"#)
        return files.flatMap { file -> [String] in
            let range = NSRange(file.text.startIndex..., in: file.text)
            return regex.matches(in: file.text, range: range).compactMap { match in
                guard let token = Range(match.range(at: 1), in: file.text).map({ String(file.text[$0]) }),
                      token != "nil" else { return nil }
                return "\(file.path):\(match.range.location)"
            }
        }
    }

    @Test("Only the central writer replaces a stored suggestion; every other caller only fills an empty one")
    func onlyTheCentralWriterReplaces() throws {
        let files = try Self.sources()
        let found = try Self.replacements(files)
        #expect(found.contains { Self.file(of: $0) == Self.replacer }, "control: the central writer replaces")
        let elsewhere = found.filter { Self.file(of: $0) != Self.replacer }
        #expect(elsewhere.isEmpty, "a suggestion replaced outside AccountManager.storeSuggestion: \(elsewhere)")
    }

    @Test("Control: the replacement census flags a planted multi-line replacement and passes a fill")
    func replacementCensusFlagsPlantedForms() throws {
        let planted = [
            "_ = header.replaceSuggestion(with: ReplyResult(body: \"x\", textMessage: nil), ifStill: nil)",
            "guard header.replaceSuggestion(with: ReplyResult(",
            "    body: \"y\", textMessage: nil),",
            "    ifStill: header.suggestion) else { return }",
        ].joined(separator: "\n")
        let found = try Self.replacements([("TabMail/Planted.swift", planted)])
        #expect(found.count == 1, "only the replacement is flagged: \(found)")
    }

    @Test("One envelope builder: no Reply All re-derivation or re-sorting of a reply card")
    func oneEnvelopeBuilder() throws {
        let files = try Self.sources()
        #expect(try Self.lines(matching: #"make\((replyAllTo|agent):"#, in: files).isEmpty,
                "the retired second builders")
        let constructions = try Self.lines(matching: #"ChatReplyCompose\("#, in: files)
        #expect(!constructions.isEmpty && constructions.allSatisfy { $0.hasPrefix("TabMail/Views/Chat/ChatReplyField.swift:") },
                "an envelope built outside its builder: \(constructions)")
        // The reply tool derives ONE envelope, for the model's context and the card alike, from the
        // builders; the retired second derivations (its own Reply All list arithmetic and the agent
        // envelope rebuilt from loose recipients) are gone.
        let tool = try #require(files.first { $0.path == "TabMail/Services/AI/Tools/EmailReplyTool.swift" }).text
        #expect(tool.components(separatedBy: "ChatReplyCompose.suggestionEnvelope(for: header").count - 1 == 1, "one start derivation")
        #expect(!tool.contains("buildReplyAllRecipients"), "the reply tool's own Reply All arithmetic")
        #expect(try Self.lines(matching: #"agentReply\(|applyRecipientDelta"#, in: files).isEmpty, "a second envelope derivation")
        // Every host opens the agent's card through the one presenter. A new email's chat is a
        // host too: its own new email's card is built by its model (`ChatNewThreadModel.card`,
        // with the chat's people, Cc, Bcc and attachments), and any other card its agent asks for
        // opens through this same presenter.
        let presenters = try Self.lines(matching: #"req\.composeView\(account:"#, in: files)
        #expect(Set(presenters.map { String($0.prefix { $0 != ":" }) }) == [
            "TabMail/Views/Chat/ChatThreadView.swift", "TabMail/Views/Inbox/InboxView.swift",
            "TabMail/Views/Message/MessageDetailView.swift", "TabMail/Views/Chat/ChatNewThreadView.swift",
        ])
        #expect(try Self.lines(matching: #"composeViewForAgentRequest"#, in: files).isEmpty)
    }
}

/// The field's reply card owns the field's sent words (ADR-IOS-117).
///
/// THE SYSTEM PROPERTY pinned here, through `ChatFieldCompose` and the field-words store: the reply
/// card the closed field's Send opens owns the send's completion. Closed unsent, the request's
/// answer hands the sent words back to the user, kept for the next app run.
@Suite("The field's reply card owns the field's sent words", .serialized, .processGlobalState)
@MainActor
struct FieldReplyCardWordsTests {

    /// Field words kept in memory as the database keeps them: a new store on the same rows is the
    /// next app run.
    static func storage(_ rows: OSAllocatedUnfairLock<[String: String]>) -> ChatFieldWords.Storage {
        ChatFieldWords.Storage(
            read: { key in rows.withLock { $0[key] } },
            write: { batch in
                rows.withLock { stored in
                    for (key, write) in batch { stored[key] = write.words.isEmpty ? nil : write.words }
                }
            })
    }

    @Test("The field's reply card, closed unsent, then the answer: the sent words are the user's again, kept for the next run")
    func closedUnsentCardThenAnswer() async throws {
        let routes = SuggestionRewriteRouteTests()
        let fixture = try await routes.fixture()
        let shownEmail = fixture.header
        let rows = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
        let store = ChatFieldWords(storage: Self.storage(rows))
        let previous = ChatFieldWords.shared
        ChatFieldWords.shared = store
        defer { ChatFieldWords.shared = previous }

        // The field sends the user's own message about the email it shows.
        let key = ChatFieldWords.key(for: shownEmail)
        let sent = "did the first test go through?"
        store.apply(.put(sent), to: key)
        store.apply(.sentFromField, to: key)
        let invocation = ToolInvocation(
            fieldReply: ChatFieldReply(email: shownEmail, onlyTo: nil),
            composeOrigin: SuggestionRewriteRouteTests.asked, fieldWordsKey: key)
        let answer = SuggestionRewriteRouteTests.edit(subject: "Re: Offsite")
        let compose = ChatFieldCompose(context: fixture.ctx, composeText: { _, _, _, _ in answer })
        let task = Task { @MainActor in await compose.reply(sent, invocation: invocation) }
        let request = try #require(await routes.waitForCard(fixture.router), "control: the reply card opened")
        #expect(request.draftId != nil, "control: the card opens on a draft of its own")
        // The chat that opens the card reads it too, so after the field's own card its closing
        // answer opens nothing.
        #expect(request.isFieldsOwnReply, "the request carries that it is the field's own reply")
        let composing = store.fill(for: key).composing
        #expect(composing, "the field's own reply card owns the send: \(store.fill(for: key))")
        request.onOutcome(.cancelled)
        _ = await task.value
        let shown = try await routes.row(fixture.db, fixture.header.id).suggestion
        #expect(shown == SuggestionRewriteRouteTests.shownReply, "control: the stored suggestion is unchanged")

        // The request's answer comes once the card is done.
        store.apply(.answered, to: key)
        let fill = store.fill(for: key)
        #expect(fill.words == sent && fill.unsent == sent, "after the answer: \(fill)")
        await store.written()
        let next = ChatFieldWords(storage: Self.storage(rows))
        await next.load(key)
        let nextWords = next.fill(for: key).words
        #expect(nextWords == sent, "the next app run: \(nextWords)")
    }
}
