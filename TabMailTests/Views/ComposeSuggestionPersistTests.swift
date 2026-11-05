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
        let changes = try #require(body.range(of: "|| hasVisibleSuggestion"))
        let decision = try #require(body.range(of: "switch ComposeDraftGuards.closeAction"))

        #expect(transition.lowerBound < visible.lowerBound
            && visible.lowerBound < content.lowerBound
            && content.lowerBound < changes.lowerBound
            && changes.lowerBound < decision.lowerBound,
            "Close must derive one visible-suggestion fact and feed both content and change classification before deciding")
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
        let send = try #require(body.range(of: "Task { await send() }"))
        #expect(gate.lowerBound < accept.lowerBound && accept.lowerBound < send.lowerBound,
                "tutorial gate, then adoption, then the send task")

        #expect(!source.contains("Use Suggestion & Send"))
        #expect(!source.contains("You have an AI suggestion that hasn't been accepted"))
    }

    @Test("Updates cachedReply on messageHeader for the given id")
    func updatesCachedReplyColumn() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        await ComposeView.writeCachedReplyToDB("edited reply", headerId: header.id, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == "edited reply")
    }

    @Test("No-op when headerId does not match any row")
    func noOpOnMissingHeader() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        await ComposeView.writeCachedReplyToDB("ghost", headerId: "nonexistent", db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == nil)
    }

    @Test("Overwrites a prior cachedReply value")
    func overwritesPriorValue() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        await ComposeView.writeCachedReplyToDB("first", headerId: header.id, db: db)
        await ComposeView.writeCachedReplyToDB("second", headerId: header.id, db: db)

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

        await ComposeView.writeCachedReplyToDB("new reply", headerId: header.id, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.subject == "Untouched subject")
        #expect(fetched?.from == "alice@example.com")
        #expect(fetched?.snippet == "Untouched snippet")
        #expect(fetched?.cachedReply == "new reply")
    }
}
