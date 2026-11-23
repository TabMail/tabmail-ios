/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Compose suggestion persistence")
struct ComposeSuggestionPersistTests {

    private func composeSource() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectRoot
            .appendingPathComponent("TabMail/Views/Compose/ComposeView.swift"),
            encoding: .utf8)
    }

    private func functionBody(
        _ signature: String,
        before nextSignature: String,
        in source: String
    ) throws -> Substring {
        let start = try #require(source.range(of: signature))
        let tail = source[start.lowerBound...]
        let end = try #require(tail.range(of: nextSignature))
        return tail[..<end.lowerBound]
    }

    @Test("Explicit Save accepts the exact visible suggestion before persistence")
    func explicitSaveAcceptsVisibleSuggestion() {
        let offered = ComposeDraftGuards.SuggestionState(
            messageBody: "",
            showingSuggestion: true,
            currentSuggestion: "the currently visible AI suggestion"
        )
        let transitioned = ComposeDraftGuards.acceptingVisibleSuggestion(offered)

        #expect(transitioned.messageBody == "the currently visible AI suggestion")
        #expect(transitioned.showingSuggestion == false)
        #expect(transitioned.currentSuggestion == "the currently visible AI suggestion")

        let hasContent = ComposeDraftGuards.hasContent(
            subject: "", body: transitioned.messageBody,
            to: [], cc: [], bcc: [],
            toInput: "", ccInput: "", bccInput: "",
            hasAttachments: false)
        let hasChanges = transitioned != offered
        #expect(hasContent)
        #expect(hasChanges)
        #expect(ComposeDraftGuards.closeAction(
            readState: .notFound,
            hasContent: hasContent,
            hasChanges: hasChanges) == .promptSave)
    }

    @Test("Production Save adopts the visible suggestion after its fence and before any suspension or snapshot")
    func productionSaveWiresSuggestionAcceptanceBeforeSnapshot() throws {
        let body = try functionBody(
            "private func saveDraftAndDismiss() async {",
            before: "private func discardDraftAndDismiss(_ scope: ComposeDraftGuards.DiscardScope) async {",
            in: composeSource())
        let claim = try #require(body.range(of: "agentSendFence.claimExclusiveDisposition()"))
        let adoption = try #require(body.range(of: "acceptVisibleSuggestionIfOffered()"))
        let firstAwait = try #require(body.range(of: "await "))
        let attachmentSnapshot = try #require(body.range(of: "await settledAttachmentSnapshot"))
        let bodySnapshot = try #require(body.range(of: "let capBody = messageBody"))

        #expect(claim.lowerBound < adoption.lowerBound,
                "Save must own the disposition before adopting mutable suggestion state")
        #expect(adoption.lowerBound < firstAwait.lowerBound,
                "Save must adopt the visible suggestion synchronously before its first suspension")
        #expect(firstAwait.lowerBound == attachmentSnapshot.lowerBound,
                "attachment settlement must remain Save's first suspension")
        #expect(adoption.lowerBound < bodySnapshot.lowerBound,
                "the durable body snapshot must include the adopted suggestion")
    }

    @Test("Production Close counts a visible suggestion as content and as an unsaved change")
    func productionCloseWiresVisibleSuggestionIntoDecision() throws {
        let body = try functionBody(
            "private func closeCompose() async {",
            before: "private func deleteClearedDraftAndDismiss() async {",
            in: composeSource())
        let transition = try #require(body.range(of:
            "let acceptedSuggestion = ComposeDraftGuards.acceptingVisibleSuggestion"))
        let visible = try #require(body.range(of:
            "let hasVisibleSuggestion = acceptedSuggestion != offeredSuggestion"))
        let content = try #require(body.range(of:
            "subject: subject, body: acceptedSuggestion.messageBody"))
        let decision = try #require(body.range(of: "switch ComposeDraftGuards.closeDecision"))
        // The same fact also reaches the decision as unsettled work, so a visible
        // suggestion counts as an unsaved change.
        #expect(body.contains("hasUnsettledWork: attachmentPreparationIsUnsettled || hasVisibleSuggestion"),
                "Close must hand the visible suggestion to the decision as unsettled work")

        #expect(transition.lowerBound < visible.lowerBound
            && visible.lowerBound < content.lowerBound
            && content.lowerBound < decision.lowerBound,
            "Close must derive one visible-suggestion fact and feed it into content before deciding")
    }

    @Test("Hidden, absent, and already accepted suggestions do not replace the draft body")
    func nonVisibleSuggestionsRemainUnapplied() {
        let hidden = ComposeDraftGuards.acceptingVisibleSuggestion(.init(
            messageBody: "authored body",
            showingSuggestion: false,
            currentSuggestion: "dismissed stale suggestion"
        ))
        #expect(hidden.messageBody == "authored body")
        #expect(hidden.showingSuggestion == false)

        let absent = ComposeDraftGuards.acceptingVisibleSuggestion(.init(
            messageBody: "authored body",
            showingSuggestion: true,
            currentSuggestion: nil
        ))
        #expect(absent.messageBody == "authored body")
        #expect(absent.showingSuggestion == true)

        let empty = ComposeDraftGuards.acceptingVisibleSuggestion(.init(
            messageBody: "authored body",
            showingSuggestion: true,
            currentSuggestion: ""
        ))
        #expect(empty.messageBody == "authored body")
        #expect(empty.showingSuggestion == true)

        let acceptedOnce = ComposeDraftGuards.acceptingVisibleSuggestion(.init(
            messageBody: "older body",
            showingSuggestion: true,
            currentSuggestion: "accepted exactly once"
        ))
        let acceptedTwice = ComposeDraftGuards.acceptingVisibleSuggestion(acceptedOnce)
        #expect(acceptedOnce.messageBody == "accepted exactly once")
        #expect(acceptedTwice == acceptedOnce)
    }

    // MARK: - The chat's AI Suggestion card (ADR-IOS-114 decision 16)
    //
    // The card's suggestion box and its buttons are out of the accessibility tree in the
    // running app (tabmail-ios#1124), so a tap on Use Suggestion cannot be driven: these tests
    // drive the transitions the card runs instead (memory 128).

    private static let cardSuggestion = "Hello Sam,\n\nYes, Tuesday works for me.\n\nThanks."
    private static let laterRowReply = "A rewritten reply."
    private static let savedDraftWords = "My own words, not sent yet"

    @Test("Use Suggestion fills the card's empty body with the suggestion, and the box goes")
    func useSuggestionFillsTheBody() throws {
        let accepted = ComposeDraftGuards.acceptingVisibleSuggestion(.init(
            messageBody: "", showingSuggestion: true, currentSuggestion: Self.cardSuggestion))
        #expect(accepted.messageBody == Self.cardSuggestion)
        #expect(accepted.showingSuggestion == false)

        // The Use Suggestion button runs this one transition.
        let bubble = try functionBody(
            "private func suggestionBubble(text: String) -> some View {",
            before: "// MARK: - Recompute reply", in: composeSource())
        let label = try #require(bubble.range(of: "Text(\"Use Suggestion\")"))
        // The Use Suggestion button's own action: from its tutorial gate to its label, with no other
        // button in between, so a move into Dismiss's action (which comes earlier) fails.
        let gate = try #require(bubble.range(of: ".useSuggestion, accountId: replyTo?.accountId, messageId: replyTo?.messageId)"))
        let action = bubble[gate.upperBound..<label.lowerBound]
        #expect(gate.lowerBound < label.lowerBound)
        #expect(action.contains("acceptVisibleSuggestionIfOffered()"), "the Use Suggestion button's action accepts the suggestion")
        #expect(!action.contains("Button {"), "the accept call sits in the Use Suggestion button's own action")
    }

    @Test("A card opened with a suggestion shows that one, never the email row's later reply")
    func cardShowsTheTappedSuggestionNotTheRowsLaterReply() throws {
        let tapped = ReplyResult(body: Self.cardSuggestion, textMessage: "Yes, Tuesday works for me.")
        // A whole stored value (text version and change command too), so a body-only read of the row fails.
        let later = ReplyResult(
            body: Self.laterRowReply, textMessage: "Thursday works better for me.",
            changeCommand: "Make it Thursday instead.")
        var rowRead = false
        let shown = ComposeDraftGuards.suggestionToShow(
            given: tapped, isReply: true, onlyToChosen: false,
            freshSuggestion: { rowRead = true; return later })
        #expect(shown == tapped)
        #expect(!rowRead, "the row is not consulted when the card was handed a suggestion")
        let accepted = ComposeDraftGuards.acceptingVisibleSuggestion(.init(
            messageBody: "", showingSuggestion: true, currentSuggestion: shown?.body))
        #expect(accepted.messageBody == Self.cardSuggestion, "Use Suggestion uses the tapped suggestion")

        // A card that is not a reply (an agent's new email or forward) still shows the value handed in,
        // and never reads a row.
        #expect(ComposeDraftGuards.suggestionToShow(
            given: tapped, isReply: false, onlyToChosen: false, freshSuggestion: { rowRead = true; return later }) == tapped,
                "a new email or forward shows the suggestion it was handed")
        #expect(!rowRead, "a card that is not a reply never consults a row")

        // Control: with nothing handed in, a reply reads the row's whole value; a new message never does.
        #expect(ComposeDraftGuards.suggestionToShow(
            given: nil, isReply: true, onlyToChosen: false, freshSuggestion: { later }) == later)
        #expect(ComposeDraftGuards.suggestionToShow(
            given: nil, isReply: false, onlyToChosen: false, freshSuggestion: { later }) == nil)

        // A reply only to the people chosen in the chat's Reply to never reads the row: the stored
        // suggestion was written for everyone. What it was handed (its own words) still shows.
        var narrowedRead = false
        #expect(ComposeDraftGuards.suggestionToShow(
            given: nil, isReply: true, onlyToChosen: true, freshSuggestion: { narrowedRead = true; return later }) == nil,
                "a reply only to the people chosen offers no stored suggestion")
        #expect(!narrowedRead, "a reply only to the people chosen never consults the row")
        #expect(ComposeDraftGuards.suggestionToShow(
            given: tapped, isReply: true, onlyToChosen: true, freshSuggestion: { later }) == tapped,
                "a reply only to the people chosen shows the words it was handed")

        let prepopulate = try functionBody(
            "private func prepopulate() {",
            before: "private func carryForwardAttachments", in: composeSource())
        #expect(prepopulate.contains("ComposeDraftGuards.suggestionToShow("),
                "prepopulate takes its suggestion from the decision")
        // A Forward never offers the parent's AI reply, and the reply read is the email compose opened for.
        #expect(prepopulate.contains("given: Self.givenSuggestion(suggestion, suggestedBody: suggestedBody), isReply: replyTo != nil && !isForward,"),
                "only a reply, never a forward, reads the row's reply")
        let decision = try #require(prepopulate.range(of: "ComposeDraftGuards.suggestionToShow("))
        let fresh = try #require(prepopulate.range(of: "freshSuggestion: {"))
        #expect(prepopulate[decision.upperBound..<fresh.lowerBound].contains("onlyToChosen: onlyToChosen,"),
                "the card's own choice decides whether it may read the row's reply")
        let closure = try #require(prepopulate.range(of: "guard let reply = replyTo else { return nil }"))
        let stored = try #require(prepopulate.range(of: "return try MessageHeader.fetchOne(db, key: reply.id)?.suggestion"))
        #expect(closure.lowerBound < stored.lowerBound,
                "the closure reads the stored suggestion from the row at reply.id")
    }

    @Test("Use Suggestion then Save writes the card's own draft with the suggestion; the saved reply draft is untouched")
    func cardSaveWritesItsOwnDraftAndLeavesTheSavedOneAlone() async throws {
        let db = try TestDatabase.make()
        let account = try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let email = try TestDatabase.insertMessageHeader(db, messageId: "1", rfc822MessageId: "<card-1@example.com>")
        let parent = "\(email.accountId):\(email.stableId)"
        let savedKey = Draft.draftKey(replyTo: parent, isForward: false, newId: nil)
        let earlier = Date().addingTimeInterval(-3600).timeIntervalSince1970
        let saved = ComposeDraftGuards.draftToSave(
            existing: nil, id: savedKey, accountId: account.id,
            recipients: (["sender@example.com"], [], []), subject: "Re: Test Subject",
            body: Self.savedDraftWords, replyTo: email, isForward: false, isReplyAll: false,
            attachmentsDirName: nil, now: earlier)
        try await db.write { try saved.insert($0) }

        // The ghost's card, as the chat opens it, then Use Suggestion, then Save.
        let card = ChatReadyReply(
            message: email, suggestion: ReplyResult(body: Self.cardSuggestion, textMessage: nil), accounts: [account])
        let accepted = ComposeDraftGuards.acceptingVisibleSuggestion(.init(
            messageBody: "", showingSuggestion: true, currentSuggestion: Self.cardSuggestion))
        let existing = try await db.read { try Draft.fetchOne($0, key: card.draftId) }
        let row = ComposeDraftGuards.draftToSave(
            existing: existing, id: card.draftId, accountId: account.id,
            recipients: (card.compose.to, card.compose.cc, card.compose.bcc), subject: "Re: Test Subject",
            body: accepted.messageBody, replyTo: email, isForward: false, isReplyAll: false,
            attachmentsDirName: nil, now: Date().timeIntervalSince1970)
        try await db.write { try row.save($0) }

        let drafts = try await db.read { try Draft.fetchAll($0) }
        let own = drafts.filter { $0.id.hasPrefix(Draft.separateReplyPrefix) }
        #expect(own.count == 1, "the card saved one draft of its own: \(drafts.map(\.id))")
        #expect(own.first?.body.contains(Self.cardSuggestion) == true, "holding the suggestion")
        let kept = try #require(drafts.first { $0.id == savedKey }, "the saved reply draft is still there")
        #expect(kept.body == Self.savedDraftWords, "never saved over")
        #expect(kept.updatedAt == earlier, "never touched")

        let save = try functionBody(
            "private func saveDraftAndDismiss() async {",
            before: "private func discardDraftAndDismiss(_ scope: ComposeDraftGuards.DiscardScope) async {",
            in: composeSource())
        #expect(save.contains("ComposeDraftGuards.draftToSave("), "Save persists the row the decision builds")
        #expect(save.contains("body: capBody,"), "with the body Save captured")
    }

    @Test("Save's row: an existing row keeps its history and stamps; an insert takes the stamps from the header")
    func draftToSaveExistingAndInsertRows() throws {
        let now = Date().timeIntervalSince1970
        let earlier = Date().addingTimeInterval(-7200).timeIntervalSince1970
        let reply = header(rfc822: "<parent@example.com>", epoch: 4242)

        // Existing row: server fields, edit history and reply stamps are carried forward.
        var stored = Draft(
            id: "draft-key", accountId: Self.accountId,
            toJSON: Draft.encodeStringArray(["old-to@example.com"]),
            ccJSON: Draft.encodeStringArray(["old-cc@example.com"]),
            bccJSON: Draft.encodeStringArray(["old-bcc@example.com"]),
            subject: "Old subject", body: "old body", replyToId: "stored-parent", isForward: false,
            editHistoryJSON: "[{\"turn\":1}]", createdAt: earlier, updatedAt: earlier)
        stored.serverDraftId = "server-1"
        stored.serverPushStatus = "pushed"
        stored.rfc822MessageId = "<draft@example.com>"
        stored.attachmentsDirName = "old-dir"
        stored.replyToProviderMessageId = "stored-uid"
        stored.replyToUidValidity = 77
        stored.isReplyAll = false

        let edited = ComposeDraftGuards.draftToSave(
            existing: stored, id: "ignored-id", accountId: "ignored-account",
            recipients: (["to@example.com"], ["cc@example.com"], ["bcc@example.com"]),
            subject: "New subject", body: "new body", replyTo: reply, isForward: true, isReplyAll: true,
            attachmentsDirName: "new-dir", now: now)
        #expect(edited.id == "draft-key")
        #expect(edited.accountId == Self.accountId)
        #expect(edited.toJSON == Draft.encodeStringArray(["to@example.com"]))
        #expect(edited.ccJSON == Draft.encodeStringArray(["cc@example.com"]))
        #expect(edited.bccJSON == Draft.encodeStringArray(["bcc@example.com"]))
        #expect(edited.subject == "New subject")
        #expect(edited.body == "new body")
        #expect(edited.updatedAt == now)
        #expect(edited.attachmentsDirName == "new-dir")
        #expect(edited.isReplyAll == true)
        #expect(edited.editHistoryJSON == "[{\"turn\":1}]", "the edit history is never clobbered")
        #expect(edited.replyToProviderMessageId == "stored-uid", "the stamp is decided once, at creation")
        #expect(edited.replyToUidValidity == 77)
        #expect(edited.replyToId == "stored-parent")
        #expect(edited.isForward == false)
        #expect(edited.createdAt == earlier)
        #expect(edited.serverDraftId == "server-1")
        #expect(edited.serverPushStatus == "pushed")
        #expect(edited.rfc822MessageId == "<draft@example.com>")

        // Insert from a header: To, Cc and Bcc are distinct, so a swap fails.
        let inserted = ComposeDraftGuards.draftToSave(
            existing: nil, id: "new-key", accountId: Self.accountId,
            recipients: (["to@example.com"], ["cc@example.com"], ["bcc@example.com"]),
            subject: "Fwd: Subject", body: "forward body", replyTo: reply, isForward: true, isReplyAll: true,
            attachmentsDirName: "insert-dir", now: now)
        #expect(inserted.id == "new-key")
        #expect(inserted.accountId == Self.accountId)
        #expect(inserted.toJSON == Draft.encodeStringArray(["to@example.com"]))
        #expect(inserted.ccJSON == Draft.encodeStringArray(["cc@example.com"]))
        #expect(inserted.bccJSON == Draft.encodeStringArray(["bcc@example.com"]))
        #expect(inserted.subject == "Fwd: Subject")
        #expect(inserted.body == "forward body")
        #expect(inserted.replyToId == reply.id)
        #expect(inserted.isForward == true)
        #expect(inserted.isReplyAll == true)
        #expect(inserted.createdAt == now)
        #expect(inserted.updatedAt == now)
        #expect(inserted.attachmentsDirName == "insert-dir")
        #expect(inserted.editHistoryJSON == nil)
        #expect(inserted.replyToProviderMessageId == reply.messageId)
        #expect(inserted.replyToProviderMessageId == Self.uid)
        #expect(inserted.replyToUidValidity == 4242)
    }

    // MARK: - Send tap with an empty body (#384)

    private func tap(
        body: String,
        showing: Bool,
        suggestion: String?,
        hydrating: Bool = false
    ) -> ComposeDraftGuards.SendTap {
        ComposeDraftGuards.sendTap(
            .init(messageBody: body, showingSuggestion: showing, currentSuggestion: suggestion),
            isHydratingPreparedDraft: hydrating)
    }

    @Test("Send with an empty body and a visible suggestion sends exactly the suggestion and never prompts")
    func emptyBodyVisibleSuggestionSendsSuggestionWithoutPrompt() {
        let offered = ComposeDraftGuards.SuggestionState(
            messageBody: "  \n",
            showingSuggestion: true,
            currentSuggestion: "the visible AI suggestion")
        let decision = ComposeDraftGuards.sendTap(offered, isHydratingPreparedDraft: false)
        #expect(decision == .sendAcceptingSuggestion)

        let sent = ComposeDraftGuards.acceptingVisibleSuggestion(offered)
        #expect(sent.messageBody == "the visible AI suggestion")
        #expect(sent.showingSuggestion == false)
    }

    @Test("Send with an empty body and no usable suggestion still prompts")
    func emptyBodyWithoutUsableSuggestionPrompts() {
        #expect(tap(body: "", showing: false, suggestion: nil) == .promptEmptyBody)
        #expect(tap(body: "", showing: false, suggestion: "dismissed stale suggestion") == .promptEmptyBody)
        #expect(tap(body: "", showing: true, suggestion: nil) == .promptEmptyBody)
        #expect(tap(body: "", showing: true, suggestion: "") == .promptEmptyBody)
        #expect(tap(body: " \n", showing: true, suggestion: "  \n") == .promptEmptyBody)
    }

    @Test("Send with a typed body sends the typed body only, never the suggestion")
    func typedBodyIgnoresSuggestion() {
        #expect(tap(body: "typed reply", showing: true, suggestion: "AI suggestion") == .sendAsTyped)
        #expect(tap(body: "typed reply", showing: false, suggestion: "AI suggestion") == .sendAsTyped)
        #expect(tap(body: "typed reply", showing: false, suggestion: nil) == .sendAsTyped)
    }

    @Test("Send while a prepared draft is hydrating is ignored whatever the body or suggestion")
    func hydratingSendIsIgnored() {
        #expect(tap(body: "", showing: true, suggestion: "AI suggestion", hydrating: true) == .ignore)
        #expect(tap(body: "", showing: false, suggestion: nil, hydrating: true) == .ignore)
        #expect(tap(body: "typed", showing: false, suggestion: nil, hydrating: true) == .ignore)
    }

    @Test("Production Send consults the decision, and the Empty Body alert no longer offers a suggestion button")
    func productionSendWiring() throws {
        let source = try composeSource()
        let body = try functionBody(
            "private func trySend() {",
            before: "\n    }\n",
            in: source)
        #expect(body.contains("ComposeDraftGuards.sendTap("))
        #expect(body.contains("acceptVisibleSuggestionIfOffered()"))

        // Accept-and-send honours the guided tutorial's Use Suggestion lock, and
        // adopts the suggestion synchronously before the send task is created.
        let gate = try #require(body.range(of: ".useSuggestion, accountId: replyTo?.accountId"))
        let accept = try #require(body.range(of: "acceptVisibleSuggestionIfOffered()"))
        let send = try #require(body.range(of: "startSend()"))
        #expect(gate.lowerBound < accept.lowerBound && accept.lowerBound < send.lowerBound,
                "tutorial gate, then adoption, then the send task")

        #expect(!source.contains("Use Suggestion & Send"))
        #expect(!source.contains("You have an AI suggestion that hasn't been accepted"))
    }

    @Test("An edit's text version is stored with it; an edit without one clears the old one")
    func storesTheEditsTextVersion() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        await ComposeView.writeOverCurrent(ReplyResult(body: "Edited body", textMessage: "Edited text", changeCommand: "ask for Friday"), replyTo: header, db: db)
        var fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == "Edited body")
        #expect(fetched?.replyTextMessage == "Edited text", "the text version comes with the body it describes")
        #expect(fetched?.replyChangeCommand == "ask for Friday", "the change command comes with the body it changes")

        await ComposeView.writeOverCurrent(ReplyResult(body: "Earlier body", textMessage: nil, changeCommand: nil), replyTo: header, db: db)
        fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == "Earlier body")
        #expect(fetched?.replyTextMessage == nil, "a text version never describes another body")
        #expect(fetched?.replyChangeCommand == nil, "a change command never belongs to another body")
    }

    /// Resend and rewind put an earlier suggestion back in the card. The suggestion stored for the
    /// chat view must keep its text version, or the ghost disappears with nothing to show.
    @Test("A resend or rewind restore keeps the restored suggestion's text version")
    func restoreKeepsTheTextVersion() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        await ComposeView.writeOverCurrent(ReplyResult(body: "Original body", textMessage: "Original text", changeCommand: "say no"), replyTo: header, db: db)

        // The edit is requested on the suggestion shown, carried with its text version and command,
        // then lands.
        let shown = ReplyResult(body: "Original body", textMessage: "Original text", changeCommand: "say no")
        let turn = InlineEditTurn(userRequest: "Make it shorter", bodyAtRequest: shown.body,
                                  subjectAtRequest: "Subject", assistantResponse: "{}",
                                  textMessageAtRequest: shown.textMessage,
                                  changeCommandAtRequest: shown.changeCommand)
        await ComposeView.writeOverCurrent(ReplyResult(body: "Shorter body", textMessage: "Shorter text", changeCommand: "add a date"), replyTo: header, db: db)

        // The edit history survives the draft round trip, as on a reopened card.
        let draft = Self.draft(history: Draft.encodeEditHistory([turn]))
        let restored = try #require(draft.editHistory.first)

        await ComposeView.writeOverCurrent(ReplyResult(body: restored.bodyAtRequest, textMessage: restored.textMessageAtRequest, changeCommand: restored.changeCommandAtRequest), replyTo: header, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == "Original body")
        #expect(fetched?.replyTextMessage == "Original text", "the restored suggestion keeps its ghost")
        #expect(fetched?.replyChangeCommand == "say no", "and its field example")
    }

    /// Resend and rewind put an earlier draft back, then send the request again. The request must
    /// edit that restored draft, not the card's draft from before the restore reached it.
    @Test("A resend or rewind edits the restored draft", arguments: ["resend", "rewind"])
    func restoreEditsTheRestoredDraft(_ restore: String) throws {
        let source = try #require(Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift"))
        let signature = restore == "resend"
            ? "private func resendLastUserComposeEdit(" : "private func rewindComposeEditToMessage("
        let start = try #require(source.range(of: signature))
        let tail = source[start.upperBound...]
        let end = try #require(tail.range(of: "\n    }\n"))
        #expect(tail[..<end.lowerBound].contains("sendComposeEdit(text, agentAdmissionAcquired: true, from: anchor)"),
                "the \(restore) sends the request on the restored turn")
        let send = try #require(source.range(of: "private func sendComposeEdit("))
        let body = source[send.upperBound...].prefix(4000)
        #expect(body.contains("Self.editBase(anchor: anchor, draftSubject: draftSubject, draftBody: draftBody,"),
                "the edit reads the draft the one choice gives")
        // The restore and the result are both applied, awaited, inside the request's task, which
        // holds the compose fence admission until it ends: the restore lands before the result.
        let rest = source[send.upperBound...]
        let task = try #require(rest.range(of: "activeChatTask = Task {\n            defer { composeAgentSendFence?.finishAgent() }"))
        let restore = try #require(rest.range(of: "if let anchor, let onDraftUpdate {\n"))
        let result = try #require(rest.range(of: "await onDraftUpdate?(result.subject, result.body,"))
        #expect(task.lowerBound < restore.lowerBound && restore.lowerBound < result.lowerBound)
        #expect(rest[restore.upperBound...].prefix(400).contains("await Self.restoreDraft(anchor, through: onDraftUpdate)"))
        // The accepted edit records its turn with the text version and command it was requested on
        // (the base's, read once), so a later resend or rewind restores the whole suggestion.
        let base = try #require(rest.range(of: "let atRequest = base.atRequest\n"))
        let record = try #require(rest.range(of: """
            editHistory.append(Self.editTurn(
                                instruction: instruction, subject: currentSubject, body: currentBody,
                                atRequest: atRequest, assistantResponse: result.raw))
            """))
        #expect(base.lowerBound < record.lowerBound && result.lowerBound < record.lowerBound,
                "the accepted edit records its turn with the request's text version")
    }

    /// The choice itself, without the view: a restored turn wins over the card's draft, which a
    /// restore may not have reached yet.
    @Test("With a restored turn the edit reads that turn's draft, not the card's stale one")
    func editBaseTakesTheRestoredTurn() {
        let turn = InlineEditTurn(userRequest: "Make it shorter", bodyAtRequest: "Restored body",
                                  subjectAtRequest: "Re: Restored", assistantResponse: "{}",
                                  textMessageAtRequest: "Restored text", changeCommandAtRequest: "say no")
        let stale = ReplyResult(body: "Stale body", textMessage: "Stale text", changeCommand: "stale command")
        let restored = DynamicIslandChat.editBase(
            anchor: turn, draftSubject: "Re: Stale", draftBody: stale.body, draftSuggestion: stale)
        #expect(restored.subject == "Re: Restored")
        #expect(restored.body == "Restored body")
        #expect(restored.atRequest.textMessage == "Restored text" && restored.atRequest.changeCommand == "say no")
        // Control: no restore, the card's draft and its suggestion.
        let current = DynamicIslandChat.editBase(
            anchor: nil, draftSubject: "Re: Stale", draftBody: stale.body, draftSuggestion: stale)
        #expect(current.body == "Stale body" && current.subject == "Re: Stale")
        #expect(current.atRequest.textMessage == "Stale text" && current.atRequest.changeCommand == "stale command")
    }

    private static func source(_ path: String) -> String? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("Edit history saved before the text version was kept decodes it as nil")
    func olderHistoryDecodesNil() throws {
        let draft = Self.draft(history: #"[{"userRequest":"r","bodyAtRequest":"b","subjectAtRequest":"s","assistantResponse":"a"}]"#)
        let turn = try #require(draft.editHistory.first)
        #expect(turn.bodyAtRequest == "b")
        #expect(turn.textMessageAtRequest == nil)
        #expect(turn.changeCommandAtRequest == nil)
    }

    private static func draft(history: String?) -> Draft {
        Draft(
            id: "d1", accountId: "acc1",
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "Subject", body: "",
            replyToId: nil, isForward: false,
            editHistoryJSON: history,
            createdAt: 0, updatedAt: 0,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil)
    }

    @Test("Updates cachedReply on messageHeader for the given id")
    func updatesCachedReplyColumn() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        await ComposeView.writeOverCurrent(ReplyResult(body: "edited reply", textMessage: nil, changeCommand: nil), replyTo: header, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == "edited reply")
    }

    @Test("No-op when headerId does not match any row")
    func noOpOnMissingHeader() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        var ghost = header
        ghost.id = "nonexistent"
        await ComposeView.writeOverCurrent(ReplyResult(body: "ghost", textMessage: nil, changeCommand: nil), replyTo: ghost, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == nil)
    }

    @Test("Overwrites a prior cachedReply value")
    func overwritesPriorValue() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        await ComposeView.writeOverCurrent(ReplyResult(body: "first", textMessage: nil, changeCommand: nil), replyTo: header, db: db)
        await ComposeView.writeOverCurrent(ReplyResult(body: "second", textMessage: nil, changeCommand: nil), replyTo: header, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == "second")
    }

    @Test("Touches only cachedReply — other fields unchanged")
    func leavesOtherFieldsAlone() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "1",
            subject: "Untouched subject",
            from: "alice@example.com",
            snippet: "Untouched snippet"
        )

        await ComposeView.writeOverCurrent(ReplyResult(body: "new reply", textMessage: nil, changeCommand: nil), replyTo: header, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.subject == "Untouched subject")
        #expect(fetched?.from == "alice@example.com")
        #expect(fetched?.snippet == "Untouched snippet")
        #expect(fetched?.cachedReply == "new reply")
    }

    // MARK: - The email compose opened for must still be the row written (#400)

    /// IMAP and iCloud: the id is an address (`account:folder:uid`), so the same id can name a different
    /// email after a UIDVALIDITY reset. The default test account is Gmail, whose address is the identity
    /// and bypasses the epoch checks, so these run on both epoch-addressed providers.
    private static let accountId = "acc1"
    private static let folderPath = "INBOX"
    private static let uid = "7"
    private static let epochProviders: [AccountProvider] = [.imap, .icloud]
    private static let earlier = "earlier suggestion"

    private func epochFixture(_ provider: AccountProvider, folderEpoch: Int?) throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: Self.accountId, email: "user@example.com", provider: provider)
        var folder = Folder(name: "INBOX", path: Self.folderPath, role: .inbox, accountId: Self.accountId)
        folder.lastKnownUidValidity = folderEpoch
        try db.write { try folder.insert($0) }
        return db
    }

    /// An email at the shared address, already holding a cached suggestion.
    private func header(rfc822: String?, epoch: Int?, uid: String = ComposeSuggestionPersistTests.uid) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid,
            subject: "Subject \(rfc822 ?? "none")",
            from: "Sender <sender@example.com>",
            fromAddress: "sender@example.com",
            to: "user@example.com",
            date: Date().addingTimeInterval(-3600),
            snippet: "snippet",
            folderId: MessageIdentity.folderId(accountId: Self.accountId, folderPath: Self.folderPath),
            accountId: Self.accountId,
            folderPath: Self.folderPath,
            isInInbox: true
        )
        header.rfc822MessageId = rfc822
        header.observedUidValidity = epoch
        header.cachedReply = Self.earlier
        return header
    }

    /// The row at `id` must exist (a refusal that deleted it must not read as "nothing written").
    private func row(_ db: DatabaseQueue, _ id: String) throws -> MessageHeader {
        try #require(try db.read { try MessageHeader.fetchOne($0, key: id) })
    }

    @Test("An edit lands on the email compose opened for", arguments: epochProviders)
    func editLandsOnTheOpenedEmail(provider: AccountProvider) async throws {
        let db = try epochFixture(provider, folderEpoch: 111)
        let opened = header(rfc822: "<x@example.com>", epoch: 111)
        let bystander = header(rfc822: "<z@example.com>", epoch: 111, uid: "8")
        try await db.write { db in
            try opened.insert(db)
            try bystander.insert(db)
        }

        await ComposeView.writeOverCurrent(ReplyResult(body: "my edit", textMessage: nil, changeCommand: nil), replyTo: opened, db: db)

        #expect(try row(db, opened.id).cachedReply == "my edit")
        #expect(try row(db, bystander.id).cachedReply == Self.earlier, "the save touched another email")
    }

    @Test("An edit does not land on a different email seated at the same address", arguments: epochProviders)
    func editDoesNotLandOnTheReplacement(provider: AccountProvider) async throws {
        let db = try epochFixture(provider, folderEpoch: 111)
        let opened = header(rfc822: "<x@example.com>", epoch: 111)
        try await db.write { try opened.insert($0) }

        // A reset purged the opened email and a resync seated another at the same folder and UID.
        let replacement: MessageHeader = {
            var other = header(rfc822: "<y@example.com>", epoch: nil)
            other.cachedReply = "the replacement's own suggestion"
            return other
        }()
        try await db.write { db in
            _ = try MessageHeader.deleteOne(db, key: opened.id)
            try replacement.insert(db)
        }

        // Non-vacuity: the unguarded statement this replaced lands on the replacement.
        try await db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET cachedReply = ? WHERE id = ?", arguments: ["control", opened.id])
        }
        #expect(try row(db, opened.id).cachedReply == "control", "the replacement must be present and writable")
        try await db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET cachedReply = ? WHERE id = ?",
                           arguments: [replacement.cachedReply, opened.id])
        }

        await ComposeView.writeOverCurrent(ReplyResult(body: "my edit", textMessage: nil, changeCommand: nil), replyTo: opened, db: db)

        // The replacement is still there, still itself, and still holds its own suggestion.
        let after = try row(db, opened.id)
        #expect(after.rfc822MessageId == "<y@example.com>")
        #expect(after.subject == replacement.subject)
        #expect(after.cachedReply == "the replacement's own suggestion", "the edit was stored on another email")
    }

    @Test("An edit does not land on a Message-ID-less replacement seated under the new numbering", arguments: epochProviders)
    func editDoesNotLandOnAMessageIDLessReplacement(provider: AccountProvider) async throws {
        // Neither email carries a Message-ID, so only the numbering can tell them apart. The reset moved
        // the folder to 222 and the replacement was stamped with it; the opened email was seen under 111.
        let db = try epochFixture(provider, folderEpoch: 222)
        let opened = header(rfc822: nil, epoch: 111)
        let replacement: MessageHeader = {
            var other = header(rfc822: nil, epoch: 222)
            other.cachedReply = "the replacement's own suggestion"
            return other
        }()
        try await db.write { db in
            try replacement.insert(db)
        }

        // Non-vacuity: the replacement is present at the opened email's address and writable.
        #expect(opened.id == replacement.id)
        try await db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET cachedReply = ? WHERE id = ?", arguments: ["control", opened.id])
        }
        #expect(try row(db, opened.id).cachedReply == "control")
        try await db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET cachedReply = ? WHERE id = ?",
                           arguments: [replacement.cachedReply, opened.id])
        }

        await ComposeView.writeOverCurrent(ReplyResult(body: "my edit", textMessage: nil, changeCommand: nil), replyTo: opened, db: db)

        let after = try row(db, opened.id)
        #expect(after.observedUidValidity == 222)
        #expect(after.cachedReply == "the replacement's own suggestion", "the edit was stored on another email")
    }

    @Test("An email without a Message-ID takes the edit while its numbering is proven", arguments: epochProviders)
    func editLandsWithoutMessageIDWhenNumberingIsProven(provider: AccountProvider) async throws {
        let db = try epochFixture(provider, folderEpoch: 111)
        let opened = header(rfc822: nil, epoch: 111)
        try await db.write { try opened.insert($0) }

        await ComposeView.writeOverCurrent(ReplyResult(body: "my edit", textMessage: nil, changeCommand: nil), replyTo: opened, db: db)

        #expect(try row(db, opened.id).cachedReply == "my edit")
    }

    @Test("An email without a Message-ID refuses the edit once the numbering has moved", arguments: epochProviders)
    func editRefusedWithoutMessageIDWhenNumberingMoved(provider: AccountProvider) async throws {
        let db = try epochFixture(provider, folderEpoch: 222)
        let opened = header(rfc822: nil, epoch: 111)
        try await db.write { try opened.insert($0) }

        await ComposeView.writeOverCurrent(ReplyResult(body: "my edit", textMessage: nil, changeCommand: nil), replyTo: opened, db: db)

        #expect(try row(db, opened.id).cachedReply == Self.earlier)
    }

    @Test("An email without a Message-ID refuses the edit when its numbering was never observed", arguments: epochProviders)
    func editRefusedWithoutMessageIDWhenNumberingUnknown(provider: AccountProvider) async throws {
        let db = try epochFixture(provider, folderEpoch: nil)
        let opened = header(rfc822: nil, epoch: nil)
        try await db.write { try opened.insert($0) }

        await ComposeView.writeOverCurrent(ReplyResult(body: "my edit", textMessage: nil, changeCommand: nil), replyTo: opened, db: db)

        #expect(try row(db, opened.id).cachedReply == Self.earlier)
    }

    /// The edit reaches the writer: an inline edit of the visible suggestion in reply mode (not forward,
    /// not a new message) saves through `writeCachedReplyToDB` with the message compose opened for,
    /// awaited inside the edit (so under the chat's compose fence), before the fade that only
    /// presents it.
    @Test("An inline edit of the visible reply suggestion is saved, awaited, with the message compose opened for")
    func inlineEditReachesTheWriterWithTheOpenedMessage() throws {
        let source = try composeSource()
        let edit = try functionBody("private func applyInlineEdit(", before: "struct SuggestionEdit {", in: source)
        let gate = try #require(edit.range(of: "let edit = Self.suggestionEdit("))
        let save = try #require(edit.range(of: "await Self.writeCachedReplyToDB(value, replacing: previous, replyTo: reply, db: dbPool)"))
        let fade = try #require(edit.range(of: "withAnimation(.easeOut(duration: 0.4)) {"))
        #expect(gate.lowerBound < save.lowerBound && save.lowerBound < fade.lowerBound)
        // The one write runs only for the email the decision named, never the card's own email
        // in its place: an edit the decision keeps in the card is never stored.
        let target = try #require(edit.range(of: "if let value = edit.edited, let reply = edit.target {"))
        let between = String(edit[target.upperBound..<save.lowerBound])
        #expect(gate.lowerBound < target.lowerBound && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the write sits directly inside the decision's target: \(between)")
        #expect(edit.components(separatedBy: "writeCachedReplyToDB").count - 1 == 1, "one write, the gated one")
        #expect(!edit.contains("edit.target ??"), "no other email stands in for the decision's target")
        #expect(!edit.contains("Task {"), "the save is awaited by the edit, never detached")
        // The card shows the stored whole value, so a second edit starts from (and replaces) this one.
        let shown = try #require(edit.range(of: "if showingSuggestion {"))
        let assign = try #require(edit[shown.upperBound...].range(of: "shownSuggestion = edit.edited\n"))
        #expect(gate.lowerBound < assign.lowerBound && assign.lowerBound < save.lowerBound,
                "the card's shown suggestion becomes the edited value before its save")
        #expect(!source.contains("persistCachedReply"), "the retired second writer")
        // The suggestion replaced is the one shown when the edit started: read before the decision
        // and before the card shows the edited value, else the edit compares against itself.
        let previous = try #require(edit.range(of: "let previous = shownSuggestion\n"))
        #expect(previous.lowerBound < gate.lowerBound && previous.lowerBound < assign.lowerBound,
                "the replaced suggestion is read before the card shows the edit")
        #expect(edit.components(separatedBy: "shownSuggestion").count - 1 == 2,
                "the edit reads the shown suggestion once (as previous) and assigns it once")
    }

    /// Backstop for the hosted card's pill, which no active test can drive: each compose edit's
    /// context is read when the edit is sent, through the identity-checked read, and a nil read
    /// refuses the edit before the model call.
    @Test("A card's compose edit sends the context read at request time, and refuses a nil read")
    func cardEditReadsItsContextAtRequestTime() throws {
        let compose = try composeSource()
        let chat = try #require(compose.range(of: "DynamicIslandChat(\n"))
        let wiring = compose[chat.upperBound...].prefix(1200)
        #expect(wiring.contains("composeEditContext: { await composeEditContextForRequest() },"),
                "the card hands the chat its request-time context read")
        let reader = try functionBody("private func composeEditContextForRequest()", before: "\n    }\n", in: compose)
        #expect(reader.contains("ComposeEditContext.relatedBodyText(of: reply, db: db)"), "the identity-checked body read")
        let source = try #require(Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift"))
        let send = try functionBody("private func sendComposeEdit(", before: "private func finishAutoSave(", in: source)
        let capture = try #require(send.range(of: "let contextSource = composeEditContext\n"))
        let task = try #require(send.range(of: "let editTask = Task {"))
        let read = try #require(send.range(of: "guard let read = await contextSource() else {\n"))
        let refuse = try #require(send[read.upperBound...].range(of: "throw InlineEditFailure("))
        let adopt = try #require(send.range(of: "requestContext = read\n"))
        let call = try #require(send.range(of: "aiService.performInlineEdit("))
        #expect(capture.lowerBound < task.lowerBound && task.lowerBound < read.lowerBound
                && read.lowerBound < refuse.lowerBound && refuse.lowerBound < adopt.lowerBound
                && adopt.lowerBound < call.lowerBound,
                "the context is read inside the request's task, refused on nil, then used")
        #expect(send[read.upperBound..<adopt.lowerBound].count < 300, "the refusal is the nil read's own branch")
        #expect(send[call.upperBound...].prefix(300).contains("context: requestContext,"),
                "the model gets the request-time context, never the render-time one")
    }

    /// Backstop for `prepopulate`'s view-private read: a reply card opened without a given
    /// suggestion shows the stored one only while the row is still the email replied to.
    @Test("A reply card's stored-suggestion prefill is read only while the row is the email replied to")
    func prefillReadsTheStoredSuggestionThroughTheIdentityCheck() throws {
        let source = try composeSource()
        let prepopulate = try functionBody("private func prepopulate() {", before: "private func clearAttachmentPreparationFailures() {", in: source)
        let branch = try #require(prepopulate.range(of: "freshSuggestion: {\n"))
        let rest = prepopulate[branch.upperBound...]
        let read = try #require(rest.range(of: "return try? dbPool.read { db -> ReplyResult? in\n"))
        let guardLine = try #require(rest.range(of: "guard try AIWriteTarget.stillHolds(reply, db: db) else { return nil }\n"))
        let fetch = try #require(rest.range(of: "return try MessageHeader.fetchOne(db, key: reply.id)?.suggestion"))
        // The end of the stored-suggestion read's closure.
        let otherwise = try #require(rest.range(of: "})\n"))
        #expect(read.lowerBound < guardLine.lowerBound && guardLine.lowerBound < fetch.lowerBound
                && fetch.lowerBound < otherwise.lowerBound,
                "the identity check guards the stored-suggestion read, inside it, before the value")
        let shown = try #require(rest.range(of: "shownSuggestion = suggested"))
        #expect(fetch.lowerBound < shown.lowerBound, "the guarded value is the one shown")
        #expect(rest[..<otherwise.lowerBound].components(separatedBy: "MessageHeader.fetchOne").count == 2,
                "the branch has one read of the stored suggestion, the guarded one")
    }

    /// Backstop for what no active test can drive (the hosted card's pill and Recompute take no
    /// accessibility activation): the card's edit decides with the card's OWN live inputs, the From
    /// chosen in the card, its recipients after this edit's deltas and the subject after this edit,
    /// never the email's; and the card's disappearance runs its close step. The decisions themselves
    /// are pinned behaviourally (`cardEditReachesTheGhostOnlyFromItsEnvelope`, `cardCloseEndsTheRecompute`).
    @Test("A card's edit decides with the card's own From, recipients after the edit and subject; its disappearance closes its Recompute")
    func cardEditUsesTheCardsOwnInputs() throws {
        let source = try composeSource()
        let edit = try functionBody("private func applyInlineEdit(", before: "struct SuggestionEdit {", in: source)
        let deltas = try #require(edit.range(of: "setRecipients(recipients.applying(to: toDelta, cc: ccDelta, bcc: bccDelta))"))
        let gate = try #require(edit.range(of: "let edit = Self.suggestionEdit("))
        #expect(deltas.lowerBound < gate.lowerBound, "the decision reads the recipients after this edit's deltas")
        let call = String(edit[gate.lowerBound...].prefix(400))
        #expect(call.contains("recipients: recipients.pendingCommitted"), "the card's recipients: \(call)")
        #expect(call.contains("subject: newSubject ?? subject"), "the subject after this edit: \(call)")
        #expect(call.contains("accountId: selectedAccount?.id"), "the From chosen in the card, never the email's account: \(call)")
        #expect(!call.contains("replyTo?.accountId") && !call.contains("reply.accountId"))
        #expect(call.contains("onlyToChosen: onlyToChosen,"),
                "a card replying only to the people chosen decides as one, for its whole life: \(call)")
        let disappear = try functionBody("private func performDisappear()", before: "static func cardClosed(", in: source)
        #expect(disappear.contains("Self.cardClosed(recompute: recomputeTask)"), "the card's disappearance closes its Recompute")
    }

    @Test("A user edit clears the reply's text message, which described the AI's body")
    func editClearsReplyTextMessage() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        header.cachedReply = "AI reply"
        header.replyTextMessage = "AI text message"
        header.summaryTextMessage = "Summary text message"
        let seeded = header
        try await db.write { try seeded.update($0) }

        await ComposeView.writeOverCurrent(ReplyResult(body: "my edit", textMessage: nil, changeCommand: nil), replyTo: seeded, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: seeded.id) }
        #expect(fetched?.cachedReply == "my edit")
        #expect(fetched?.replyTextMessage == nil)
        #expect(fetched?.summaryTextMessage == "Summary text message")
    }
}
