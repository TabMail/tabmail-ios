/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import PhotosUI
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-114 decision 10: the paperclip in every chat's reply field.
///
/// THE SYSTEM PROPERTY pinned here: something picked with the paperclip opens the reply's compose
/// card with it attached, addressed to whom the field's reply goes (Reply All to the newest email's
/// people, or a plain reply to only the people chosen in Reply to), with the AI Suggestion the chat
/// shows in its box and no other (none while the reply goes only to some people: the suggestion was
/// written for everyone), on a draft of its own. The pick is added after the card's starting state
/// is recorded, so Close counts it as something written.
@Suite("The reply field's paperclip", .serialized, .processGlobalState)
@MainActor
struct ChatReplyAttachTests {
    private static let me = Account(emailAddress: "me@example.com", displayName: "Me", provider: .gmail)
    private static let suggestion = ReplyResult(body: "Hi all,\n\nTuesday works.", textMessage: "Tuesday works")
    private static let david = ChatThread.Person(address: "david@example.com", name: "David Kim")

    /// The newest email: from Alex to the user and David, Cc Sam.
    private static func groupEmail() -> MessageHeader {
        var email = MessageHeader(
            messageId: "attach-1", subject: "Plans", from: "Alex Doe <alex@example.com>",
            fromAddress: "alex@example.com", to: "me@example.com, david@example.com",
            date: Date().addingTimeInterval(-600), snippet: "Tuesday works.",
            folderId: MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX"), accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        email.cc = "sam@example.com"
        email.rfc822MessageId = "<attach-1@example.com>"
        return email
    }

    /// A small photo the camera could have taken.
    private static func photo() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    // MARK: - The card's value

    @Test("Reply All: the paperclip's card is the suggestion's envelope with the suggestion the chat shows, on a draft of its own")
    func replyAllCard() {
        let email = Self.groupEmail()
        let card = ChatReadyReply(attaching: .camera(Self.photo()), to: email, onlyTo: nil,
                                  shown: Self.suggestion, accounts: [Self.me])
        #expect(card.compose == ChatReplyCompose.suggestionEnvelope(for: email, accounts: [Self.me]),
                "the same envelope as the ghost's card")
        #expect(card.compose.isReplyAll && card.compose.to == ["alex@example.com", "david@example.com"]
                    && card.compose.cc == ["sam@example.com"] && card.compose.bcc.isEmpty,
                "everyone on the email: \(card.compose)")
        #expect(card.suggestion == Self.suggestion, "the suggestion the chat shows")
        #expect(card.message.id == email.id)
        // Its own draft: never the reply draft already saved for this email, and a new one per card.
        let parent = "\(email.accountId):\(email.stableId)"
        #expect(card.draftId.hasPrefix(Draft.separateReplyPrefix) && card.draftId.hasSuffix(":\(parent)"), "\(card.draftId)")
        #expect(card.draftId != Draft.draftKey(replyTo: parent, isForward: false, newId: nil))
        let again = ChatReadyReply(attaching: .camera(Self.photo()), to: email, onlyTo: nil,
                                   shown: Self.suggestion, accounts: [Self.me])
        #expect(again.draftId != card.draftId, "each card opens on a draft of its own")
        // No suggestion showing: none in the card.
        let none = ChatReadyReply(attaching: .camera(Self.photo()), to: email, onlyTo: nil, shown: nil, accounts: [Self.me])
        #expect(none.suggestion == nil && none.compose.isReplyAll)
    }

    @Test("Replying only to: a plain reply to only those people, with no suggestion even while one shows")
    func onlyToCard() {
        let email = Self.groupEmail()
        let url = URL(fileURLWithPath: "/tmp/attach/plan.pdf")
        let card = ChatReadyReply(attaching: .files([url]), to: email, onlyTo: [Self.david],
                                  shown: Self.suggestion, accounts: [Self.me])
        #expect(!card.compose.isReplyAll, "a plain reply, so the send records a reply on the original")
        #expect(card.compose.to == ["david@example.com"] && card.compose.cc.isEmpty && card.compose.bcc.isEmpty,
                "only David: \(card.compose)")
        #expect(card.compose.subject == ThreadUtils.replySubject(for: email.subject))
        #expect(card.suggestion == nil, "the suggestion was written for everyone")
        #expect(card.draftId.hasPrefix(Draft.separateReplyPrefix))
    }

    @Test("The card the chat presents carries the pick, its own draft, and the chat's suggestion and no stored one",
          arguments: ["camera", "files", "photos"])
    func presentedCard(_ kind: String) {
        let email = Self.groupEmail()
        let image = Self.photo()
        let url = URL(fileURLWithPath: "/tmp/attach/plan.pdf")
        let item = PhotosPickerItem(itemIdentifier: "attach-photo")
        let pick: ComposeAttachmentPick = switch kind {
        case "camera": .camera(image)
        case "files": .files([url])
        default: .photos([item])
        }
        let card = ChatReadyReply(attaching: pick, to: email, onlyTo: nil, shown: Self.suggestion, accounts: [Self.me])
        let compose = card.composeView(openedOn: .chat, onOutcome: { _ in })
        #expect(!compose.offersStoredSuggestion, "the card shows the chat's suggestion or none, never the row's")
        #expect(compose.suggestion == Self.suggestion)
        #expect(compose.prefillDraftId == card.draftId, "its own draft")
        #expect(compose.replyTo?.id == email.id && !compose.isForward && compose.isReplyAll)
        #expect(compose.prefillTo == card.compose.to && compose.prefillCc == card.compose.cc && compose.prefillBcc == [])
        #expect(compose.prefillSubject == card.compose.subject)
        switch (kind, compose.attachmentPick) {
        case ("camera", .camera(let given)?): #expect(given === image)
        case ("files", .files(let given)?): #expect(given == [url])
        case ("photos", .photos(let given)?): #expect(given == [item])
        default: Issue.record("the card carries the pick as picked: \(kind), \(String(describing: compose.attachmentPick))")
        }

        // The ghost's card: the same builder, nothing picked, nothing stored read either.
        let ghost = ChatReadyReply(message: email, suggestion: Self.suggestion, accounts: [Self.me]).composeView(openedOn: .chat, onOutcome: { _ in })
        #expect(ghost.attachmentPick == nil && !ghost.offersStoredSuggestion && ghost.suggestion == Self.suggestion)
        // Every other reply still reads the row's suggestion.
        #expect(ComposeView(replyTo: email).offersStoredSuggestion)
    }

    @Test("The paperclip shows for a new email's field and a thread's, and its choice reaches the one given")
    func fieldPaperclip() {
        var threadChoices: [ChatNewEmailField.AttachSource] = []
        let thread = ChatReplyField(example: nil, isNoReply: false, clearCount: 0, attach: { threadChoices.append($0) })
        thread.paperclip?(.files)
        #expect(threadChoices == [.files], "a thread's paperclip reaches the chat")
        #expect(ChatReplyField(example: nil, isNoReply: false, clearCount: 0).paperclip == nil, "nothing given: no paperclip")

        var newEmailChoices: [ChatNewEmailField.AttachSource] = []
        let newEmail = ChatReplyField(
            example: nil, isNoReply: false, clearCount: 0,
            newEmail: ChatNewEmailField(startWords: "", sessionKey: "attach-session", wordsChanged: { _ in },
                                        send: { _ in }, attach: { newEmailChoices.append($0) }))
        newEmail.paperclip?(.camera)
        #expect(newEmailChoices == [.camera] && threadChoices == [.files], "a new email's paperclip reaches its own chat")
    }

    // MARK: - Wiring

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("Compose adds the pick once its draft has loaded, after recording the starting state, through its own buttons' steps")
    func composeAddsThePickAfterLoading() throws {
        let compose = try Self.source("TabMail/Views/Compose/ComposeView.swift")
        // Both ways a load ends well record the starting state, then add the pick; a load that
        // fails adds nothing (the card says the draft did not load).
        #expect(Self.count("snapshotInitialState() addAttachmentPick() return }", in: compose) == 1, "a saved draft")
        #expect(Self.count("prepopulate() addAttachmentPick() }", in: compose) == 1, "a new reply (prepopulate records the state last)")
        #expect(Self.count("addAttachmentPick()", in: compose) == 3, "declared once, called on the two loads only")
        #expect(Self.count("snapshotInitialState() } /// Download and re-attach", in: compose) == 1,
                "control: prepopulate ends by recording the starting state")
        #expect(Self.count("guard let attachmentPick else { return }", in: compose) == 1)
        #expect(Self.count("switch attachmentPick { case .photos(let items): handlePhotoPickerItemsChange(items) case .camera(let image): addCameraPhoto(image) case .files(let urls): handleFileImport(.success(urls)) }", in: compose) == 1,
                "each pick goes through the card's own Photos, Camera and Files steps")
    }

    @Test("The chat's paperclip opens its pickers, and a pick opens the reply's card with it")
    func chatWiring() throws {
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(Self.count("suggestion: shown, attach: attachFromField),", in: chat) == 1, "the field shows the paperclip")
        #expect(Self.count("private func attachFromField(_ source: ChatNewEmailField.AttachSource) { guard TutorialCoordinator.shared.admits(.other) else { return } switch source { case .photos: showsPhotoPicker = true case .camera: showsCamera = true case .files: showsFilePicker = true } }", in: chat) == 1,
                "each choice opens its own picker; the tutorial's mail actions are off")
        #expect(Self.count(".photosPicker(isPresented: $showsPhotoPicker, selection: $photoPickerItems, matching: .any(of: [.images, .videos]))", in: chat) == 1)
        #expect(Self.count(".onChange(of: photoPickerItems) { _, items in attachPicked(items) }", in: chat) == 1)
        #expect(Self.count("guard !items.isEmpty else { return } photoPickerItems = [] openAttachCard(.photos(items))", in: chat) == 1)
        #expect(Self.count(".fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in attachFiles(result) }", in: chat) == 1)
        #expect(Self.count("case .success(let urls): guard !urls.isEmpty else { return } openAttachCard(.files(urls)) case .failure(let error): attachFailure = error.localizedDescription", in: chat) == 1,
                "a Files picker that failed says so")
        // The camera's photo waits for its cover to close, so the card's cover never opens over it.
        #expect(Self.count(".fullScreenCover(isPresented: $showsCamera, onDismiss: attachCameraPhoto) { CameraPickerView { image in cameraPhoto = image } }", in: chat) == 1)
        #expect(Self.count("guard let image = cameraPhoto else { return } cameraPhoto = nil openAttachCard(.camera(image))", in: chat) == 1)
        // The card: the one presenter, on the newest email, to whom the field's reply goes, with the
        // suggestion the chat shows.
        #expect(Self.count("readyReply = ChatReadyReply( attaching: pick, to: newest, onlyTo: replyTarget.only, shown: shownSuggestion(on: newest, thread: thread), accounts: context.accounts)", in: chat) == 1)
        #expect(Self.count("readyReply = ", in: chat) == 2, "the ghost's tap and the paperclip's pick")
        // The pickers count as presentations over the chat.
        #expect(Self.count("|| forwardMessage != nil || showsReplyTo || showsMove || showsPhotoPicker || showsFilePicker || showsCamera", in: chat) == 1)
        // The test seam exists only in debug builds.
        let seam = try #require(chat.range(of: ".onReceive(NotificationCenter.default.publisher(for: .chatPaperclipPhotoForTesting))"))
        let opened = try #require(chat.range(of: "#if DEBUG", options: .backwards, range: chat.startIndex..<seam.lowerBound))
        let closed = chat.range(of: "#endif", options: .backwards, range: chat.startIndex..<seam.lowerBound)
        #expect(closed.map { $0.lowerBound < opened.lowerBound } ?? true, "the seam sits inside #if DEBUG")
    }

    // MARK: - In the chat

    /// The paperclip's card, opened through the chat's own presenter (`ChatThreadView.openAttachCard`)
    /// with a camera photo (the system pickers cannot be driven from a hosted test).
    private static func attachPhoto(in chat: ChatReplyRecoveryTests.Chat) async throws -> UIView {
        NotificationCenter.default.post(name: .chatPaperclipPhotoForTesting, object: photo())
        try await ChatReplyRecoveryTests.waitUntil {
            ChatReplyRecoveryTests.composeRecipients(chat.controller.presentedViewController?.view)["to"]?.isEmpty == false
        }
        return try #require(chat.controller.presentedViewController?.view, "the paperclip's card opened")
    }

    private static func cardLabels(_ card: UIView) -> [String] {
        HostedAccessibility.labels(in: card)
    }

    @Test("In the chat, a photo from the paperclip opens the Reply All card with it and the AI Suggestion shown")
    func hostedReplyAll() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        let backend = ChatReplyRecoveryTests.Backend(failure: .serverError, asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await ChatReplyRecoveryTests().withChat(backend, tag: "attach-all", suggestion: ChatReplyRecoveryTests.shownSuggestion) { chat in
                let shown = ChatReplyRecoveryTests.shownSuggestion
                try await ChatReplyRecoveryTests.waitUntil { ChatReplyRecoveryTests.ghosts(in: chat.view).contains { $0.text == shown.textMessage } }
                #expect(HostedAccessibility.identifiers(in: chat.view).contains(ChatPaperclipButton.id),
                        "the reply field shows the paperclip: \(HostedAccessibility.identifiers(in: chat.view))")
                let card = try await Self.attachPhoto(in: chat)
                let recipients = ChatReplyRecoveryTests.composeRecipients(card)
                #expect(ChatReplyRecoveryTests.addresses(recipients["to"]).union(ChatReplyRecoveryTests.addresses(recipients["cc"]))
                            == ["alex@example.com", "david@example.com", "sam@example.com"],
                        "the card goes to everyone on the email: \(recipients)")
                try await ChatReplyRecoveryTests.waitUntil { Self.cardLabels(card).contains { $0.contains("photo_1.jpg") } }
                #expect(Self.cardLabels(card).contains { $0.contains("photo_1.jpg") }, "the photo is attached: \(Self.cardLabels(card).prefix(30))")
                #expect(Self.cardLabels(card).contains("Use Suggestion"), "the suggestion the chat showed is in its box: \(Self.cardLabels(card).prefix(30))")
            }
        }
    }

    @Test("In the chat, replying only to David, a photo from the paperclip opens a plain reply to David with it and no suggestion")
    func hostedOnlyTo() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        let backend = ChatReplyRecoveryTests.Backend(failure: .serverError, asksForReply: false)
        try await HostedAccessibility.withAutomation {
            // The email stores an AI Suggestion, so a card that read it would show it.
            try await ChatReplyRecoveryTests().withChat(backend, tag: "attach-only", suggestion: ChatReplyRecoveryTests.shownSuggestion) { chat in
                try await ChatReplyRecoveryTests.toggle(["alex@example.com", "sam@example.com"], in: chat)
                #expect(ChatReplyRecoveryTests.replyingOnlyTo(in: chat.view) != nil, "control: the chat replies only to David")
                let card = try await Self.attachPhoto(in: chat)
                let recipients = ChatReplyRecoveryTests.composeRecipients(card)
                #expect(ChatReplyRecoveryTests.addresses(recipients["to"]) == ["david@example.com"], "only David: \(recipients)")
                #expect(ChatReplyRecoveryTests.addresses(recipients["cc"]).isEmpty && ChatReplyRecoveryTests.addresses(recipients["bcc"]).isEmpty,
                        "nobody else: \(recipients)")
                try await ChatReplyRecoveryTests.waitUntil { Self.cardLabels(card).contains { $0.contains("photo_1.jpg") } }
                #expect(Self.cardLabels(card).contains { $0.contains("photo_1.jpg") }, "the photo is attached: \(Self.cardLabels(card).prefix(30))")
                #expect(!Self.cardLabels(card).contains("Use Suggestion"),
                        "the suggestion written for everyone stays out of the card: \(Self.cardLabels(card).prefix(30))")
            }
        }
    }
}
