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
    /// not a new message) saves through `writeCachedReplyToDB` on the email the editor was told about
    /// (`relatedEmail`).
    @Test("An inline edit of the visible reply suggestion is saved on the email the editor was told about")
    func inlineEditReachesTheWriterWithTheOpenedMessage() throws {
        let source = try composeSource()
        let persist = try functionBody(
            "private func persistCachedReply(", before: "static func writeCachedReplyToDB(", in: source)
        #expect(persist.contains("private func persistCachedReply(_ text: String, to reply: MessageHeader) {"))
        #expect(persist.contains("writeCachedReplyToDB(text, replyTo: reply, db: dbPool.pool)"))
        for forbidden in ["= replyTo", "updateAll", "execute(", "UPDATE messageHeader"] {
            #expect(!persist.contains(forbidden), "\(forbidden)")
        }

        let edit = try functionBody("private func applyInlineEdit(", before: "private func persistCachedReply(", in: source)
        let suggestion = try #require(edit.range(of: "if showingSuggestion {"))
        let gate = try #require(edit.range(of: "if replyTo != nil && !isForward, let source = relatedEmail {"))
        let save = try #require(edit.range(of: "persistCachedReply(b, to: source.header)"))
        #expect(suggestion.lowerBound < gate.lowerBound && gate.lowerBound < save.lowerBound)
    }

    /// The reply's email was renumbered and a different email now sits at the reply's own address.
    /// Compose confirmed the renumbered copy at open; the editor is told about it and the edit lands on
    /// it, never on the email now at the address compose was opened with.
    @Test("An edit after a renumbering lands on the same email at its new address, not on the email now at the old one", arguments: epochProviders)
    func editAfterARenumberingLandsOnTheSameEmail(provider: AccountProvider) async throws {
        let db = try epochFixture(provider, folderEpoch: 222)
        let held = header(rfc822: "x@example.com", epoch: 111)
        let renumbered = header(rfc822: "x@example.com", epoch: 222, uid: "9")
        let other = replacement(rfc822: "y@example.com", epoch: 222)
        try await db.write { db in
            try renumbered.insert(db)
            try other.insert(db)
        }
        #expect(other.id == held.id, "setup: another email sits at the reply's own address")

        let confirmed = try confirmedAtOpen(for: held, in: db)
        let editor = ComposeDraftGuards.relatedEmail(confirmed: confirmed, composeArgument: held, argumentIsForward: false)
        let target = try #require(editor?.header)
        #expect(target.id == renumbered.id, "setup: compose confirmed the renumbered copy")

        await ComposeView.writeCachedReplyToDB("my edit", replyTo: target, db: db)

        #expect(try row(db, renumbered.id).cachedReply == "my edit")
        #expect(try row(db, other.id).cachedReply == Self.replacementsOwn, "the edit landed on the email now at the old address")
    }

    // MARK: - What compose shows and reads for the reply it opened for (#991)

    /// The reply a fresh reply compose for `held` confirms at open (`Draft.resolveReplyQuote` with the
    /// key a fresh compose uses), kept as compose keeps it.
    private func confirmedAtOpen(for held: MessageHeader, in db: DatabaseQueue) throws -> ComposeDraftGuards.RelatedEmail? {
        let draftKey = Draft.draftKey(replyTo: "\(held.accountId):\(held.stableId)", isForward: false, newId: nil)
        let quote = try db.read { db in
            try Draft.resolveReplyQuote(
                draftKey: draftKey, replyToId: held.id, isForward: false,
                expectedProviderMessageId: held.messageId,
                expectedUidValidity: held.observedUidValidity, db: db)
        }
        return quote.map { ComposeDraftGuards.RelatedEmail(header: $0.header, bodyHTML: $0.bodyHTML, isForward: false) }
    }

    /// What a fresh reply compose shows at open for `held` when the caller gave no suggestion: the
    /// reply compose confirms at open (`confirmedAtOpen`), then `openingSuggestion`.
    private func openingSuggestion(for held: MessageHeader, in db: DatabaseQueue) throws -> String? {
        let confirmed = try confirmedAtOpen(for: held, in: db)
        return ComposeDraftGuards.openingSuggestion(confirmed: confirmed?.header, held: held)
    }

    /// The email at the shared address after a reset seated `replacement` there: present, holding its
    /// own suggestion.
    private func seat(_ replacement: MessageHeader, in db: DatabaseQueue) throws {
        try db.write { db in
            _ = try MessageHeader.deleteOne(db, key: replacement.id)
            try replacement.insert(db)
        }
        let seated = try row(db, replacement.id)
        #expect(seated.rfc822MessageId == replacement.rfc822MessageId, "setup: the replacement holds the address")
    }

    private static let replacementsOwn = "the replacement's own suggestion"

    private func replacement(rfc822: String?, epoch: Int?) -> MessageHeader {
        var other = header(rfc822: rfc822, epoch: epoch)
        other.cachedReply = Self.replacementsOwn
        return other
    }

    @Test("The suggestion shown at open is the stored one while the row is still the email compose opened for", arguments: epochProviders)
    func openingSuggestionTakesTheStoredRowOfTheSameEmail(provider: AccountProvider) throws {
        let db = try epochFixture(provider, folderEpoch: 111)
        let held = header(rfc822: "<x@example.com>", epoch: 111)
        var stored = held
        stored.cachedReply = "updated since the caller captured it"
        let storedRow = stored
        try db.write { try storedRow.insert($0) }
        let updated = try openingSuggestion(for: held, in: db)
        #expect(updated == "updated since the caller captured it")

        // Cleared since the capture: the cleared answer stands.
        try db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET cachedReply = NULL WHERE id = ?", arguments: [held.id])
        }
        let cleared = try openingSuggestion(for: held, in: db)
        #expect(cleared == nil)
    }

    /// The Message-ID is stored without brackets, as sync stores it (`EmailFilter.normalizeMessageId`),
    /// and the renumbered copy sits at another address, so the reply's own address is empty and the
    /// email is found by its Message-ID.
    @Test("The same email seen again under a new numbering still supplies its stored suggestion", arguments: epochProviders)
    func openingSuggestionFollowsTheSameEmailAfterARenumbering(provider: AccountProvider) throws {
        let db = try epochFixture(provider, folderEpoch: 222)
        let held = header(rfc822: "x@example.com", epoch: 111)
        var renumbered = header(rfc822: "x@example.com", epoch: 222, uid: "9")
        renumbered.cachedReply = "updated after the reset"
        let renumberedRow = renumbered
        try db.write { try renumberedRow.insert($0) }
        let atHeldAddress = try db.read { try MessageHeader.fetchOne($0, key: held.id) }
        let heldAddressIsEmpty = atHeldAddress == nil
        #expect(heldAddressIsEmpty, "setup: the reply's own address is empty")
        let shown = try openingSuggestion(for: held, in: db)
        #expect(shown == "updated after the reset")
    }

    @Test("A different email seated at the reply's address never supplies the suggestion", arguments: epochProviders)
    func openingSuggestionRefusesAnotherEmailAtTheAddress(provider: AccountProvider) throws {
        let db = try epochFixture(provider, folderEpoch: 111)
        let held = header(rfc822: "<x@example.com>", epoch: 111)
        try seat(replacement(rfc822: "<y@example.com>", epoch: nil), in: db)
        let shown = try openingSuggestion(for: held, in: db)
        #expect(shown == Self.earlier)
    }

    @Test("A Message-ID-less replacement seated under the new numbering never supplies the suggestion", arguments: epochProviders)
    func openingSuggestionRefusesAMessageIDLessReplacement(provider: AccountProvider) throws {
        let db = try epochFixture(provider, folderEpoch: 222)
        let held = header(rfc822: nil, epoch: 111)
        try seat(replacement(rfc822: nil, epoch: 222), in: db)
        let shown = try openingSuggestion(for: held, in: db)
        #expect(shown == Self.earlier)
    }

    /// The opened email has neither a Message-ID nor a numbering, so nothing can prove the row at its
    /// address is still it: the stored row is never read for the suggestion, whatever sits there.
    @Test("With nothing to prove the opened email, the stored row never supplies the suggestion", arguments: epochProviders)
    func openingSuggestionWithNothingToProveShowsTheHeldCopy(provider: AccountProvider) throws {
        let db = try epochFixture(provider, folderEpoch: 222)
        let held = header(rfc822: nil, epoch: nil)
        try seat(replacement(rfc822: "<y@example.com>", epoch: 222), in: db)
        let shown = try openingSuggestion(for: held, in: db)
        #expect(shown == Self.earlier)
    }

    @Test("With the row gone, the suggestion the caller captured is shown", arguments: epochProviders)
    func openingSuggestionShowsTheHeldCopyWhenTheRowIsGone(provider: AccountProvider) throws {
        let db = try epochFixture(provider, folderEpoch: 111)
        let held = header(rfc822: "<x@example.com>", epoch: 111)
        let shown = try openingSuggestion(for: held, in: db)
        #expect(shown == Self.earlier)
    }

    @Test("Compose takes the opening suggestion from the reply it confirmed at open, never from a read by the reply's id")
    func openingSuggestionWiring() throws {
        let source = try composeSource()
        let prepopulate = try functionBody(
            "private func prepopulate() {",
            before: "/// Download and re-attach the original message's attachments.", in: source)
        let resolve = try #require(prepopulate.range(of: "Draft.resolveReplyQuote("))
        let keep = try #require(prepopulate.range(of: "confirmedAtOpen = quote.map {"))
        let publish = try #require(prepopulate.range(of: "confirmedReply = confirmedAtOpen"))
        let show = try #require(prepopulate.range(of:
            "suggestionToShow = ComposeDraftGuards.openingSuggestion(\n                confirmed: confirmedAtOpen?.header, held: reply)"))
        #expect(resolve.lowerBound < keep.lowerBound && keep.lowerBound < publish.lowerBound
                && publish.lowerBound < show.lowerBound)
        #expect(!prepopulate.contains("MessageHeader.fetchOne"))
        #expect(!prepopulate.contains("freshHeader"))

        // The caller's own suggestion wins; only a reply, never a forward, takes the confirmed one.
        let callerFirst = try #require(prepopulate.range(of:
            "if let suggestedBody, !suggestedBody.isEmpty {\n            suggestionToShow = suggestedBody"))
        let replyOnly = try #require(prepopulate.range(of: "} else if let reply = replyTo, !isForward {"))
        let otherwise = try #require(prepopulate.range(of: "} else {\n            suggestionToShow = nil"))
        #expect(callerFirst.lowerBound < replyOnly.lowerBound && replyOnly.lowerBound < show.lowerBound
                && show.lowerBound < otherwise.lowerBound)
    }

    @Test("The reply model and the inline editor read the body confirmed at open, else the held snippet")
    func replyContextReadsTheConfirmedBody() {
        let text = ComposeDraftGuards.replyContextText(
            confirmedBodyHTML: "<p>Confirmed body</p>", heldSnippet: "held snippet")
        #expect(text.contains("Confirmed body"))
        #expect(!text.contains("<p>"))
        #expect(!text.contains("held snippet"))
        #expect(ComposeDraftGuards.replyContextText(confirmedBodyHTML: nil, heldSnippet: "held snippet") == "held snippet")
        #expect(ComposeDraftGuards.replyContextText(confirmedBodyHTML: "", heldSnippet: "held snippet") == "held snippet")
    }

    // MARK: - What the inline editor is told (#991)

    private static let embeddedEmail =
        "<p>Main text</p><div class=\"tm-eml-section\" data-filename=\"note.eml\"><p>Attached email text</p></div>"

    private func email(subject: String, from: String, snippet: String) -> MessageHeader {
        var email = header(rfc822: "<\(subject)@example.com>", epoch: 111)
        email.subject = subject
        email.from = from
        email.fromAddress = from
        email.snippet = snippet
        return email
    }

    @Test("A saved reply tells the editor about the email it resolved to, header and body together")
    func editorTakesTheResolvedEmailOverTheComposeArgument() {
        let resolved = email(subject: "resolved", from: "first@example.com", snippet: "resolved snippet")
        let argument = email(subject: "argument", from: "second@example.com", snippet: "argument snippet")
        let related = ComposeDraftGuards.relatedEmail(
            confirmed: ComposeDraftGuards.RelatedEmail(header: resolved, bodyHTML: "<p>Resolved body</p>", isForward: false),
            composeArgument: argument, argumentIsForward: false)
        #expect(related?.header.subject == "resolved")
        #expect(related?.header.fromAddress == "first@example.com")
        let text = related?.bodyText ?? ""
        #expect(text.contains("Resolved body"))
        #expect(!text.contains("argument snippet"))
        #expect(ComposeDraftGuards.editorMode(related, argumentIsForward: false) == "edit_reply")
    }

    @Test("A saved reply reopened with no caller email (Undo Send) still gives the editor its email and mode")
    func editorKeepsTheReplyWhenReopenedWithoutAnArgument() {
        let resolved = email(subject: "resolved", from: "first@example.com", snippet: "resolved snippet")
        for isForward in [false, true] {
            let related = ComposeDraftGuards.relatedEmail(
                confirmed: ComposeDraftGuards.RelatedEmail(header: resolved, bodyHTML: "<p>Resolved body</p>", isForward: isForward),
                composeArgument: nil, argumentIsForward: false)
            #expect(related?.header.subject == "resolved")
            #expect(related?.bodyText.contains("Resolved body") == true)
            let expectedMode = isForward ? "edit_forward" : "edit_reply"
            #expect(ComposeDraftGuards.editorMode(related, argumentIsForward: false) == expectedMode)
        }
    }

    @Test("An unresolved reply gives the editor the compose argument with its own snippet; a new message gives none")
    func editorFallsBackToTheArgumentAlone() {
        let argument = email(subject: "argument", from: "second@example.com", snippet: "argument snippet")
        let related = ComposeDraftGuards.relatedEmail(
            confirmed: nil, composeArgument: argument, argumentIsForward: true)
        #expect(related?.header.subject == "argument")
        #expect(related?.bodyText == "argument snippet")
        #expect(ComposeDraftGuards.editorMode(related, argumentIsForward: true) == "edit_forward")

        let none = ComposeDraftGuards.relatedEmail(confirmed: nil, composeArgument: nil, argumentIsForward: false)
        let isNewMessage = none == nil
        #expect(isNewMessage)
        #expect(ComposeDraftGuards.editorMode(none, argumentIsForward: false) == "edit_new")
        #expect(ComposeDraftGuards.editorMode(none, argumentIsForward: true) == "edit_forward")
    }

    @Test("The editor reads only the email's own body, without an attached email's text")
    func editorStripsAnAttachedEmail() {
        let resolved = email(subject: "resolved", from: "first@example.com", snippet: "resolved snippet")
        let related = ComposeDraftGuards.relatedEmail(
            confirmed: ComposeDraftGuards.RelatedEmail(header: resolved, bodyHTML: Self.embeddedEmail, isForward: false),
            composeArgument: resolved, argumentIsForward: false)
        let text = related?.bodyText ?? ""
        #expect(text.contains("Main text"))
        #expect(!text.contains("Attached email text"))
    }

    @Test("A body that arrives after the reply opened reaches the editor when the reply is reopened", arguments: epochProviders)
    func editorReadsALaterBodyOnReopen(provider: AccountProvider) throws {
        let db = try epochFixture(provider, folderEpoch: 111)
        let opened = email(subject: "opened", from: "first@example.com", snippet: "opened snippet")
        try db.write { try opened.insert($0) }
        func editorText() throws -> String? {
            let confirmed = try confirmedAtOpen(for: opened, in: db)
            return ComposeDraftGuards.relatedEmail(
                confirmed: confirmed, composeArgument: nil, argumentIsForward: false)?.bodyText
        }
        let atOpen = try editorText()
        #expect(atOpen == "opened snippet")

        try TestDatabase.insertMessageBody(db, headerId: opened.id, htmlContent: "<p>Body fetched later</p>")
        let reopened = try editorText()
        #expect(reopened?.contains("Body fetched later") == true)
    }

    @Test("Compose gives the editor the email it confirmed at open, with the mode of that email")
    func editorWiring() throws {
        let source = try composeSource()
        let context = try functionBody(
            "private func buildComposeEditContext() -> ComposeEditContext {",
            before: "private func applyInlineEdit(", in: source)
        #expect(context.contains("let related = relatedEmail\n"))
        #expect(context.contains("let mode = ComposeDraftGuards.editorMode(related, argumentIsForward: isForward)"))
        #expect(context.contains("let reply = related.header"))
        #expect(context.contains("bodyText = related.bodyText"))
        #expect(!context.contains("MessageBody"))
        #expect(!context.contains("reply.snippet"))
        #expect(!context.contains("replyTo"), "the editor is told about the selected email only")

        // A saved reply keeps the email its stored claim resolved to, with the forward flag its quote uses.
        let load = try functionBody(
            "private func loadDraftOrPrepopulate() async {",
            before: "private func snapshotInitialState() {", in: source)
        let resolve = try #require(load.range(of: "Draft.resolveReplyQuote("))
        let keep = try #require(load.range(of:
            "ComposeDraftGuards.RelatedEmail(header: $0.header, bodyHTML: $0.bodyHTML, isForward: resolvedForward)"))
        let attribution = try #require(load.range(of: "if resolvedForward {"))
        #expect(resolve.lowerBound < keep.lowerBound && keep.lowerBound < attribution.lowerBound)

        // One selection: the confirmed email, else the compose argument with its own snippet.
        let selection = try functionBody(
            "private var relatedEmail: ComposeDraftGuards.RelatedEmail? {",
            before: "private func recomputeReply() {", in: source)
        #expect(selection.contains(
            "ComposeDraftGuards.relatedEmail(\n            confirmed: confirmedReply, composeArgument: replyTo, argumentIsForward: isForward)"))

        // Nothing else reads the confirmed email: it is set at open and reached only through `relatedEmail`.
        let mentions = source.components(separatedBy: "confirmedReply").count - 1
        let accounted = ["private var confirmedReply:", "confirmed: confirmedReply,", "confirmedReply = "]
            .map { source.components(separatedBy: $0).count - 1 }
            .reduce(0, +)
        #expect(mentions == accounted)
        #expect(mentions == 4, "declaration, selection and the two assignments at open")
    }

    // MARK: - Recompute (#991)

    private struct ModelFailure: Error {}

    private func source(_ header: MessageHeader, bodyHTML: String?) -> ComposeDraftGuards.RelatedEmail {
        ComposeDraftGuards.RelatedEmail(header: header, bodyHTML: bodyHTML, isForward: false)
    }

    @MainActor
    @Test("Recompute gives the model the email's text, shows the answer and stores it on the unchanged email", arguments: epochProviders)
    func recomputeShowsAndStoresOnTheOpenedEmail(provider: AccountProvider) async throws {
        let db = try epochFixture(provider, folderEpoch: 111)
        let opened = header(rfc822: "<x@example.com>", epoch: 111)
        try await db.write { db in try opened.insert(db) }

        var modelText: String?
        var modelHTML: String?
        var shown: [String] = []
        let answered = try await ComposeView.recompute(
            source(opened, bodyHTML: Self.embeddedEmail),
            model: { _, text, html in
                modelText = text
                modelHTML = html
                return "new answer"
            },
            show: { shown.append($0) },
            store: { text, header in
                try? await db.write { db in try ComposeView.storeCachedReply(text, replyTo: header, in: db) }
            })

        #expect(answered)
        #expect(modelText?.contains("Main text") == true)
        #expect(modelText?.contains("Attached email text") == false)
        #expect(modelHTML == Self.embeddedEmail)
        #expect(shown == ["new answer"])
        let stored = try row(db, opened.id)
        #expect(stored.cachedReply == "new answer")
    }

    /// The reply's own address is empty and its email sits, renumbered, at another one. Compose confirms
    /// that row at open; Recompute tells the model about it and stores the answer on it, never on the
    /// address compose was opened with.
    @MainActor
    @Test("Recompute tells the model about the email compose confirmed and stores the answer on that same email", arguments: epochProviders)
    func recomputeStoresOnTheEmailTheModelWasToldAbout(provider: AccountProvider) async throws {
        let db = try epochFixture(provider, folderEpoch: 222)
        let held = header(rfc822: "x@example.com", epoch: 111)
        var renumbered = header(rfc822: "x@example.com", epoch: 222, uid: "9")
        renumbered.subject = "renumbered"
        let renumberedRow = renumbered
        try await db.write { db in try renumberedRow.insert(db) }
        let confirmed = try confirmedAtOpen(for: held, in: db)
        let selected = try #require(ComposeDraftGuards.relatedEmail(
            confirmed: confirmed, composeArgument: held, argumentIsForward: false))

        var toldAbout: [String] = []
        var storedOn: [String] = []
        let answered = try await ComposeView.recompute(
            selected,
            model: { header, _, _ in
                toldAbout.append(header.id)
                return "new answer"
            },
            show: { _ in },
            store: { text, header in
                storedOn.append(header.id)
                try? await db.write { db in try ComposeView.storeCachedReply(text, replyTo: header, in: db) }
            })

        #expect(answered)
        #expect(toldAbout == [renumbered.id])
        #expect(storedOn == [renumbered.id])
        let stored = try row(db, renumbered.id)
        #expect(stored.subject == "renumbered")
        #expect(stored.cachedReply == "new answer")
    }

    @MainActor
    @Test("A different email seated at the address while the model runs keeps its own suggestion", arguments: epochProviders)
    func recomputeDoesNotStoreOnAReplacementSeatedDuringTheModelCall(provider: AccountProvider) async throws {
        let db = try epochFixture(provider, folderEpoch: 111)
        let opened = header(rfc822: "<x@example.com>", epoch: 111)
        try await db.write { db in try opened.insert(db) }
        let other = replacement(rfc822: "<y@example.com>", epoch: nil)

        var shown: [String] = []
        let answered = try await ComposeView.recompute(
            source(opened, bodyHTML: "<p>Confirmed body</p>"),
            model: { _, _, _ in
                try seat(other, in: db)
                return "new answer"
            },
            show: { shown.append($0) },
            store: { text, header in
                try? await db.write { db in try ComposeView.storeCachedReply(text, replyTo: header, in: db) }
            })

        #expect(answered)
        #expect(shown == ["new answer"], "the open compose still shows the answer for the email it opened for")
        let after = try row(db, opened.id)
        #expect(after.rfc822MessageId == "<y@example.com>")
        #expect(after.cachedReply == Self.replacementsOwn, "the answer was stored on another email")

        // Non-vacuity: the replacement is writable, so the check, not a failed write, kept the answer off it.
        try await db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET cachedReply = ? WHERE id = ?", arguments: ["control", opened.id])
        }
        let control = try row(db, opened.id)
        #expect(control.cachedReply == "control")
    }

    @MainActor
    @Test("No answer, an empty answer or a failed model call shows and stores nothing")
    func recomputeWithoutAnAnswerShowsAndStoresNothing() async throws {
        let opened = source(header(rfc822: "<x@example.com>", epoch: 111), bodyHTML: nil)
        var shown: [String] = []
        var stored: [String] = []
        for answer in [nil, ""] as [String?] {
            let answered = try await ComposeView.recompute(
                opened,
                model: { _, _, _ in answer },
                show: { shown.append($0) },
                store: { text, _ in stored.append(text) })
            #expect(!answered)
        }
        var threw = false
        do {
            _ = try await ComposeView.recompute(
                opened,
                model: { _, _, _ in throw ModelFailure() },
                show: { shown.append($0) },
                store: { text, _ in stored.append(text) })
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(shown.isEmpty)
        #expect(stored.isEmpty)
    }

    @MainActor
    @Test("With no confirmed body the model reads the email's own snippet")
    func recomputeWithoutAConfirmedBodyReadsTheSnippet() async throws {
        let opened = header(rfc822: "<x@example.com>", epoch: 111)
        var modelText: String?
        var modelHTML: String?
        _ = try await ComposeView.recompute(
            source(opened, bodyHTML: nil),
            model: { _, text, html in
                modelText = text
                modelHTML = html
                return nil
            },
            show: { _ in }, store: { _, _ in })
        #expect(modelText == opened.snippet)
        #expect(modelHTML == nil)
    }

    @Test("Recompute runs its steps on the email compose selected and stores through the checked, prioritized write")
    func recomputeWiring() throws {
        let source = try composeSource()
        let recompute = try functionBody(
            "private func recomputeReply() {", before: "static func recompute(", in: source)
        #expect(recompute.contains("guard let source = relatedEmail, let account = resolvedAccount else { return }"))
        #expect(recompute.contains("try await Self.recompute(\n                    source,"))
        #expect(recompute.contains("model: { reply, bodyText, bodyHTML in"))
        #expect(recompute.contains("subject: reply.subject,"))
        #expect(recompute.contains("bodyText: bodyText,"))
        #expect(recompute.contains("htmlContent: bodyHTML,"))
        #expect(recompute.contains("show: { currentSuggestion = $0 },"))
        #expect(recompute.contains("store: { await Self.storeRecomputedReply($0, replyTo: $1, db: dbPool) })"))
        let done = try #require(recompute.range(of: "isRecomputing = false"))
        let caught = try #require(recompute.range(of: "} catch {"))
        #expect(caught.lowerBound < done.lowerBound, "the spinner clears after every outcome")
        for forbidden in ["MessageBody", "UPDATE messageHeader", "dbPool.pool", "reply.snippet", "= replyTo", "confirmedReply",
                          "updateAll", "execute(", ".write"] {
            #expect(!recompute.contains(forbidden), "\(forbidden)")
        }

        let steps = try functionBody(
            "static func recompute(", before: "static func storeRecomputedReply(", in: source)
        #expect(steps.contains("try await model(source.header, source.bodyText, source.bodyHTML)"))
        #expect(steps.contains("await store(answer, source.header)"))

        let store = try functionBody(
            "static func storeRecomputedReply(", before: "// MARK: - Agent Toast", in: source)
        #expect(store.contains("try? await db.write { db in try storeCachedReply(text, replyTo: reply, in: db) }"))
        #expect(!store.contains("UPDATE messageHeader"))
        let edit = try functionBody(
            "static func writeCachedReplyToDB(", before: "nonisolated static func storeCachedReply(", in: source)
        #expect(edit.contains("try? await db.write { db in try storeCachedReply(text, replyTo: reply, in: db) }"))
        #expect(!edit.contains("UPDATE messageHeader"))
    }
}
