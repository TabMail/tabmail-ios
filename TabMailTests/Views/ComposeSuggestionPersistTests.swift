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

        await ComposeView.writeCachedReplyToDB("edited reply", replyTo: header, db: db)

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
        await ComposeView.writeCachedReplyToDB("ghost", replyTo: ghost, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == nil)
    }

    @Test("Overwrites a prior cachedReply value")
    func overwritesPriorValue() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        await ComposeView.writeCachedReplyToDB("first", replyTo: header, db: db)
        await ComposeView.writeCachedReplyToDB("second", replyTo: header, db: db)

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

        await ComposeView.writeCachedReplyToDB("new reply", replyTo: header, db: db)

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

        await ComposeView.writeCachedReplyToDB("my edit", replyTo: opened, db: db)

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

        await ComposeView.writeCachedReplyToDB("my edit", replyTo: opened, db: db)

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

        await ComposeView.writeCachedReplyToDB("my edit", replyTo: opened, db: db)

        let after = try row(db, opened.id)
        #expect(after.observedUidValidity == 222)
        #expect(after.cachedReply == "the replacement's own suggestion", "the edit was stored on another email")
    }

    @Test("An email without a Message-ID takes the edit while its numbering is proven", arguments: epochProviders)
    func editLandsWithoutMessageIDWhenNumberingIsProven(provider: AccountProvider) async throws {
        let db = try epochFixture(provider, folderEpoch: 111)
        let opened = header(rfc822: nil, epoch: 111)
        try await db.write { try opened.insert($0) }

        await ComposeView.writeCachedReplyToDB("my edit", replyTo: opened, db: db)

        #expect(try row(db, opened.id).cachedReply == "my edit")
    }

    @Test("An email without a Message-ID refuses the edit once the numbering has moved", arguments: epochProviders)
    func editRefusedWithoutMessageIDWhenNumberingMoved(provider: AccountProvider) async throws {
        let db = try epochFixture(provider, folderEpoch: 222)
        let opened = header(rfc822: nil, epoch: 111)
        try await db.write { try opened.insert($0) }

        await ComposeView.writeCachedReplyToDB("my edit", replyTo: opened, db: db)

        #expect(try row(db, opened.id).cachedReply == Self.earlier)
    }

    @Test("An email without a Message-ID refuses the edit when its numbering was never observed", arguments: epochProviders)
    func editRefusedWithoutMessageIDWhenNumberingUnknown(provider: AccountProvider) async throws {
        let db = try epochFixture(provider, folderEpoch: nil)
        let opened = header(rfc822: nil, epoch: nil)
        try await db.write { try opened.insert($0) }

        await ComposeView.writeCachedReplyToDB("my edit", replyTo: opened, db: db)

        #expect(try row(db, opened.id).cachedReply == Self.earlier)
    }

    /// The edit reaches the writer: an inline edit of the visible suggestion in reply mode (not forward,
    /// not a new message) saves through `writeCachedReplyToDB` with the message compose opened for.
    @Test("An inline edit of the visible reply suggestion is saved with the message compose opened for")
    func inlineEditReachesTheWriterWithTheOpenedMessage() throws {
        let source = try composeSource()
        let persist = try functionBody(
            "private func persistCachedReply(", before: "static func writeCachedReplyToDB(", in: source)
        #expect(persist.contains("guard let reply = replyTo else { return }"))
        #expect(persist.contains("writeCachedReplyToDB(text, replyTo: reply, db: dbPool.pool)"))

        let edit = try functionBody("private func applyInlineEdit(", before: "private func persistCachedReply(", in: source)
        let suggestion = try #require(edit.range(of: "if showingSuggestion {"))
        let gate = try #require(edit.range(of: "if replyTo != nil && !isForward {"))
        let save = try #require(edit.range(of: "persistCachedReply(b)"))
        #expect(suggestion.lowerBound < gate.lowerBound && gate.lowerBound < save.lowerBound)
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

        await ComposeView.writeCachedReplyToDB("my edit", replyTo: seeded, db: db)

        let fetched = try await db.read { try MessageHeader.fetchOne($0, key: seeded.id) }
        #expect(fetched?.cachedReply == "my edit")
        #expect(fetched?.replyTextMessage == nil)
        #expect(fetched?.summaryTextMessage == "Summary text message")
    }
}
