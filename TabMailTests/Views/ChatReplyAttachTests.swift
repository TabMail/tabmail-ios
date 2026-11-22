/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import PhotosUI
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import TabMail

/// The two orders a Files picker can report a pick and close in (`hostedFilesPicker`). At file
/// scope: a test's arguments cannot name a member of its own suite.
enum PaperclipFilesOrder: CaseIterable, Sendable {
    case reportsThenCloses, closesThenReports
}

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

    /// A JPEG photo as the photo library picker hands it over: an item provider holding its bytes.
    private static func libraryPhoto() -> NSItemProvider {
        let bytes = photo().jpegData(compressionQuality: DraftAttachmentImport.cameraJPEGQuality) ?? Data()
        return NSItemProvider(item: bytes as NSData, typeIdentifier: UTType.jpeg.identifier)
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
        let provider = Self.libraryPhoto()
        let pick: ComposeAttachmentPick = switch kind {
        case "camera": .camera(image)
        case "files": .files([url])
        default: .photos([provider])
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
        case ("photos", .photos(let given)?): #expect(given.count == 1 && given.first === provider)
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
        #expect(Self.count("switch attachmentPick { case .photos(let providers): addPickedPhotos(providers, load: { try await DraftAttachmentImport.providedItem($0) }) case .camera(let image): addCameraPhoto(image) case .files(let urls): handleFileImport(.success(urls)) }", in: compose) == 1,
                "each pick goes through the card's own Photos, Camera and Files steps")
        // The card's own Photos button and the paperclip's photos share the one step.
        #expect(Self.count("private func handlePhotoPickerItemsChange(_ items: [PhotosPickerItem]) { addPickedPhotos( items, load: { item in (try await item.loadTransferable(type: Data.self), item.supportedContentTypes.first) }, then: { photoPickerItems = [] }) }", in: compose) == 1)
        #expect(Self.count("addPickedPhotos(", in: compose) == 2, "used by the card's Photos button and the pick (declared as `addPickedPhotos<Item>(`)")
    }

    @Test("The chat's paperclip opens its pickers, and a pick opens the reply's card with it once its picker has closed")
    func chatWiring() throws {
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        // The paperclip shows only once the chat can tell the user's own addresses from the others.
        #expect(Self.count("attach: knowsAudience ? { attachFromField($0) } : nil),", in: chat) == 1, "the field shows the paperclip")
        #expect(Self.count("let knowsAudience = viewModel.hasLoadedThread && context.isLoaded && context.accounts.contains(where: { $0.id == newest.accountId })", in: chat) == 1)
        #expect(Self.count("private func attachFromField(_ source: ChatNewEmailField.AttachSource) { guard TutorialCoordinator.shared.admits(.other) else { return } paperclipPickerOpen = true switch source { case .photos: showsPhotoPicker = true case .camera: showsCamera = true case .files: showsFilePicker = true } }", in: chat) == 1,
                "each choice opens its own picker; the tutorial's mail actions are off")
        // Each picker hands its pick over, and the card opens from the picker's onDismiss.
        #expect(Self.count(".sheet(isPresented: $showsPhotoPicker, onDismiss: openPendingAttachCard) { PhotoLibraryPickerView { providers in attachPicked(.photos(providers)) } }", in: chat) == 1)
        #expect(Self.count(".sheet(isPresented: $showsFilePicker, onDismiss: openPendingAttachCard) { FilePickerView { urls in attachPicked(.files(urls)) } }", in: chat) == 1)
        #expect(Self.count(".fullScreenCover(isPresented: $showsCamera, onDismiss: openPendingAttachCard) { CameraPickerView { image in attachPicked(.camera(image)) } }", in: chat) == 1)
        #expect(Self.count("onDismiss: openPendingAttachCard", in: chat) == 3, "only the paperclip's pickers open the card")
        #expect(Self.count(".photosPicker(", in: chat) == 0 && Self.count(".fileImporter(", in: chat) == 0,
                "no picker that says nothing of its closing")
        // The card, read as the pick lands: on the newest email, to whom the field's reply goes,
        // with the suggestion the chat shows.
        #expect(Self.count("private func attachPicked(_ pick: ComposeAttachmentPick) { guard let newest = thread.newest else { return }", in: chat) == 1,
                "the newest email, not the opened one")
        #expect(Self.count("pendingAttachCard = ChatReadyReply( attaching: pick, to: newest, onlyTo: replyTarget.only, shown: shownSuggestion(on: newest, thread: thread), accounts: context.accounts)", in: chat) == 1)
        #expect(Self.count("private func openPendingAttachCard() { paperclipPickerOpen = false guard let card = pendingAttachCard else { return } pendingAttachCard = nil readyReply = card }", in: chat) == 1)
        // A pick a picker reports after its onDismiss (the Files picker can close itself first)
        // opens at once; one reported while the picker is open waits for the onDismiss.
        #expect(Self.count("accounts: context.accounts) if !paperclipPickerOpen { openPendingAttachCard() } }", in: chat) == 1)
        #expect(Self.count("paperclipPickerOpen = true", in: chat) == 1, "set only by the menu's choice")
        #expect(Self.count("paperclipPickerOpen = false", in: chat) == 2, "its start, and the picker's onDismiss")
        #expect(Self.count("readyReply = ", in: chat) == 2, "the ghost's tap and the paperclip's pick, through the one presenter")
        // The pickers, and a pick waiting for its picker to close, count as presentations over the chat.
        #expect(Self.count("|| forwardMessage != nil || showsReplyTo || showsMove || showsPhotoPicker || showsFilePicker || showsCamera || pendingAttachCard != nil", in: chat) == 1)
        // The test seam takes the same two steps as a picker, and exists only in debug builds.
        let seamText = ".onReceive(NotificationCenter.default.publisher(for: .chatPaperclipPickForTesting)) { note in guard let pick = note.object as? ComposeAttachmentPick else { return } attachPicked(pick) openPendingAttachCard() }"
        #expect(Self.count(seamText, in: chat) == 1)
        // The seam that opens a picker makes the menu's choice through the menu's own step.
        let openText = ".onReceive(NotificationCenter.default.publisher(for: .chatPaperclipOpenForTesting)) { note in guard let source = note.object as? ChatNewEmailField.AttachSource else { return } attachFromField(source) }"
        #expect(Self.count(openText, in: chat) == 1)
        for text in [seamText, openText] {
            let seam = try #require(chat.range(of: text))
            let opened = try #require(chat.range(of: "#if DEBUG", options: .backwards, range: chat.startIndex..<seam.lowerBound))
            let closed = chat.range(of: "#endif", options: .backwards, range: chat.startIndex..<seam.lowerBound)
            #expect(closed.map { $0.lowerBound < opened.lowerBound } ?? true, "the seam sits inside #if DEBUG: \(text.prefix(80))")
        }
    }

    @Test("The photo library and Files pickers hand over what was picked, nothing on Cancel, then close")
    func pickerViews() throws {
        let pickers = try Self.source("TabMail/Views/Compose/AttachmentPickerViews.swift")
        #expect(Self.count("configuration.filter = .any(of: [.images, .videos])", in: pickers) == 1, "photos and videos, as compose's own Photos button")
        #expect(Self.count("configuration.selectionLimit = 0", in: pickers) == 1, "any number")
        #expect(Self.count("if !results.isEmpty { parent.onPick(results.map(\\.itemProvider)) } parent.dismiss()", in: pickers) == 1)
        #expect(Self.count("UIDocumentPickerViewController(forOpeningContentTypes: [.item])", in: pickers) == 1, "any file, opened in place")
        #expect(Self.count("picker.allowsMultipleSelection = true", in: pickers) == 1)
        #expect(Self.count("if !urls.isEmpty { parent.onPick(urls) } parent.dismiss()", in: pickers) == 1)
        #expect(Self.count("func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.dismiss() }", in: pickers) == 1)
        #expect(Self.count("context.coordinator.parent = self", in: pickers) == 2, "a picker reports to the view as it is now")
        #expect(Self.count("picker.delegate = context.coordinator", in: pickers) == 2, "each picker reports to its coordinator")
    }

    // MARK: - In the chat

    /// The paperclip's card, opened through the chat's own steps (`ChatThreadView.attachPicked`,
    /// then `openPendingAttachCard`, as a picker's pick and its `onDismiss` take them) and its one
    /// presenter, for picks a test cannot make in a real picker (a camera photo, a library photo).
    /// The real pickers, their closing and the card after them: `hostedFilesPicker`,
    /// `hostedPickerClosedWithoutPick`.
    private static func attach(_ pick: ComposeAttachmentPick, in chat: ChatReplyRecoveryTests.Chat) async throws -> UIView {
        NotificationCenter.default.post(name: .chatPaperclipPickForTesting, object: pick)
        try await ChatReplyRecoveryTests.waitUntil {
            ChatReplyRecoveryTests.composeRecipients(chat.controller.presentedViewController?.view)["to"]?.isEmpty == false
        }
        return try #require(chat.controller.presentedViewController?.view, "the paperclip's card opened")
    }

    private static func cardLabels(_ card: UIView) -> [String] {
        HostedAccessibility.labels(in: card)
    }

    // Which suggestion the card's box holds is not read here: the compose card's suggestion box is
    // hidden from accessibility (tabmail-ios#1124), so a hosted test cannot see it either way. The
    // card is given only the suggestion the chat shows, pinned by `replyAllCard`, `onlyToCard` and
    // `presentedCard` (the card's values, `offersStoredSuggestion` false) and the compose fence on
    // its stored-suggestion read.
    @Test("In the chat, a camera photo from the paperclip opens the Reply All card with it")
    func hostedReplyAll() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        let backend = ChatReplyRecoveryTests.Backend(failure: .serverError, asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await ChatReplyRecoveryTests().withChat(backend, tag: "attach-all", suggestion: ChatReplyRecoveryTests.shownSuggestion) { chat in
                let shown = ChatReplyRecoveryTests.shownSuggestion
                try await ChatReplyRecoveryTests.waitUntil { ChatReplyRecoveryTests.ghosts(in: chat.view).contains { $0.text == shown.textMessage } }
                #expect(ChatReplyRecoveryTests.ghosts(in: chat.view).map(\.text) == [shown.textMessage],
                        "control: the chat shows the AI Suggestion: \(ChatReplyRecoveryTests.ghosts(in: chat.view).map(\.text))")
                #expect(HostedAccessibility.identifiers(in: chat.view).contains(ChatPaperclipButton.id),
                        "the reply field shows the paperclip: \(HostedAccessibility.identifiers(in: chat.view))")
                let card = try await Self.attach(.camera(Self.photo()), in: chat)
                let recipients = ChatReplyRecoveryTests.composeRecipients(card)
                #expect(ChatReplyRecoveryTests.addresses(recipients["to"]).union(ChatReplyRecoveryTests.addresses(recipients["cc"]))
                            == ["alex@example.com", "david@example.com", "sam@example.com"],
                        "the card goes to everyone on the email: \(recipients)")
                try await ChatReplyRecoveryTests.waitUntil { Self.cardLabels(card).contains { $0.contains("photo_1.jpg") } }
                #expect(Self.cardLabels(card).contains { $0.contains("photo_1.jpg") }, "the photo is attached: \(Self.cardLabels(card).prefix(30))")
            }
        }
    }

    @Test("In the chat, replying only to David, a library photo from the paperclip opens a plain reply to David with it")
    func hostedOnlyTo() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        let backend = ChatReplyRecoveryTests.Backend(failure: .serverError, asksForReply: false)
        try await HostedAccessibility.withAutomation {
            // The email stores an AI Suggestion, so a card that read it would show it.
            try await ChatReplyRecoveryTests().withChat(backend, tag: "attach-only", suggestion: ChatReplyRecoveryTests.shownSuggestion) { chat in
                let shown = ChatReplyRecoveryTests.shownSuggestion
                try await ChatReplyRecoveryTests.waitUntil { ChatReplyRecoveryTests.ghosts(in: chat.view).contains { $0.text == shown.textMessage } }
                #expect(ChatReplyRecoveryTests.ghosts(in: chat.view).map(\.text) == [shown.textMessage],
                        "control: the email's AI Suggestion is stored and shown before Reply to narrows the reply")
                try await ChatReplyRecoveryTests.toggle(["alex@example.com", "sam@example.com"], in: chat)
                #expect(ChatReplyRecoveryTests.replyingOnlyTo(in: chat.view) != nil, "control: the chat replies only to David")
                let card = try await Self.attach(.photos([Self.libraryPhoto()]), in: chat)
                let recipients = ChatReplyRecoveryTests.composeRecipients(card)
                #expect(ChatReplyRecoveryTests.addresses(recipients["to"]) == ["david@example.com"], "only David: \(recipients)")
                #expect(ChatReplyRecoveryTests.addresses(recipients["cc"]).isEmpty && ChatReplyRecoveryTests.addresses(recipients["bcc"]).isEmpty,
                        "nobody else: \(recipients)")
                // The library photo loads through the card's carry gate (`providedItem`).
                try await ChatReplyRecoveryTests.waitUntil { Self.cardLabels(card).contains { $0.contains("photo_1.jpeg") } }
                #expect(Self.cardLabels(card).contains { $0.contains("photo_1.jpeg") }, "the photo is attached: \(Self.cardLabels(card).prefix(30))")
            }
        }
    }

    // MARK: - The real pickers

    /// How long a card would take to start opening after its picker closed (`onDismiss`), before
    /// a case says none did. The Files case shows one starting well within it.
    private static let cardWouldHaveOpened: Duration = .milliseconds(800)

    /// The first view controller of `type` presented over the chat (in a sheet's own hierarchy too).
    private static func presented<T: UIViewController>(_ type: T.Type, over chat: ChatReplyRecoveryTests.Chat) -> T? {
        var pending: [UIViewController] = chat.controller.presentedViewController.map { [$0] } ?? []
        while let next = pending.popLast() {
            if let match = next as? T { return match }
            pending.append(contentsOf: next.children)
            if let presented = next.presentedViewController { pending.append(presented) }
        }
        return nil
    }

    /// Waits for the chat's paperclip, then makes `source`'s choice in its menu.
    private static func open(_ source: ChatNewEmailField.AttachSource, in chat: ChatReplyRecoveryTests.Chat) async throws {
        try await ChatReplyRecoveryTests.waitUntil { HostedAccessibility.identifiers(in: chat.view).contains(ChatPaperclipButton.id) }
        #expect(HostedAccessibility.identifiers(in: chat.view).contains(ChatPaperclipButton.id),
                "control: the reply field shows the paperclip: \(HostedAccessibility.identifiers(in: chat.view))")
        NotificationCenter.default.post(name: .chatPaperclipOpenForTesting, object: source)
    }

    /// The picked file in the card: its chip, or compose's report that it could not be added (a
    /// test's file is not one the Files picker grants access to). Either shows the card took the
    /// file; a card that dropped it shows neither.
    private static func fileShown(_ name: String, card: UIView, in chat: ChatReplyRecoveryTests.Chat) -> Bool {
        if cardLabels(card).contains(where: { $0.contains(name) }) { return true }
        guard let alert = presented(UIAlertController.self, over: chat) else { return false }
        return alert.title == "Attachments Not Added" || (alert.message ?? "").contains(name)
    }

    @Test("In the chat, a file picked in the paperclip's Files picker opens the Reply All card with it, whether the picker reports before or after it closes",
          arguments: PaperclipFilesOrder.allCases)
    func hostedFilesPicker(order: PaperclipFilesOrder) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        let backend = ChatReplyRecoveryTests.Backend(failure: .serverError, asksForReply: false)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data("Agenda".utf8).write(to: file)
        try await HostedAccessibility.withAutomation {
            try await ChatReplyRecoveryTests().withChat(backend, tag: "attach-files", suggestion: ChatReplyRecoveryTests.shownSuggestion) { chat in
                try await Self.open(.files, in: chat)
                try await ChatReplyRecoveryTests.waitUntil { Self.presented(UIDocumentPickerViewController.self, over: chat) != nil }
                let picker = try #require(Self.presented(UIDocumentPickerViewController.self, over: chat), "control: the Files picker opened")
                let delegate = try #require(picker.delegate, "the Files picker reports its pick to the chat")
                #expect(ChatReplyRecoveryTests.composeRecipients(chat.controller.presentedViewController?.view).isEmpty,
                        "control: no card is open while the picker is")
                switch order {
                case .reportsThenCloses:
                    // The pick while the picker is open; the picker then closes, and only then the card opens.
                    delegate.documentPicker?(picker, didPickDocumentsAt: [file])
                case .closesThenReports:
                    // The Files picker can close itself before it reports, as UIKit's own picker does.
                    picker.dismiss(animated: true)
                    try await ChatReplyRecoveryTests.waitUntil { chat.controller.presentedViewController == nil }
                    #expect(chat.controller.presentedViewController == nil, "control: the picker closed itself")
                    try await Task.sleep(for: Self.cardWouldHaveOpened)
                    #expect(chat.controller.presentedViewController == nil, "control: nothing opened before the pick")
                    delegate.documentPicker?(picker, didPickDocumentsAt: [file])
                }
                try await ChatReplyRecoveryTests.waitUntil {
                    ChatReplyRecoveryTests.composeRecipients(chat.controller.presentedViewController?.view)["to"]?.isEmpty == false
                }
                let card = try #require(chat.controller.presentedViewController?.view, "the reply's card opened after the picker")
                #expect(Self.presented(UIDocumentPickerViewController.self, over: chat) == nil, "the picker has closed")
                let recipients = ChatReplyRecoveryTests.composeRecipients(card)
                #expect(ChatReplyRecoveryTests.addresses(recipients["to"]).union(ChatReplyRecoveryTests.addresses(recipients["cc"]))
                            == ["alex@example.com", "david@example.com", "sam@example.com"],
                        "the card goes to everyone on the email: \(recipients)")
                try await ChatReplyRecoveryTests.waitUntil { Self.fileShown("notes.txt", card: card, in: chat) }
                #expect(Self.fileShown("notes.txt", card: card, in: chat),
                        "the card took the file (its chip, or its report that it could not be added): \(Self.cardLabels(card).prefix(30))")
            }
        }
    }

    @Test("In the chat, a paperclip picker closed without a pick opens no card",
          arguments: [ChatNewEmailField.AttachSource.photos, .files])
    func hostedPickerClosedWithoutPick(source: ChatNewEmailField.AttachSource) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        let backend = ChatReplyRecoveryTests.Backend(failure: .serverError, asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await ChatReplyRecoveryTests().withChat(backend, tag: "attach-none", suggestion: ChatReplyRecoveryTests.shownSuggestion) { chat in
                try await Self.open(source, in: chat)
                switch source {
                case .photos:
                    try await ChatReplyRecoveryTests.waitUntil { Self.presented(PHPickerViewController.self, over: chat) != nil }
                    let picker = try #require(Self.presented(PHPickerViewController.self, over: chat), "control: the photo library picker opened")
                    let delegate = try #require(picker.delegate, "the photo library picker reports to the chat")
                    delegate.picker(picker, didFinishPicking: [])
                case .files:
                    try await ChatReplyRecoveryTests.waitUntil { Self.presented(UIDocumentPickerViewController.self, over: chat) != nil }
                    let picker = try #require(Self.presented(UIDocumentPickerViewController.self, over: chat), "control: the Files picker opened")
                    let delegate = try #require(picker.delegate, "the Files picker reports to the chat")
                    delegate.documentPickerWasCancelled?(picker)
                case .camera:
                    Issue.record("the camera is not available to a hosted test")
                    return
                }
                try await ChatReplyRecoveryTests.waitUntil { chat.controller.presentedViewController == nil }
                #expect(chat.controller.presentedViewController == nil, "the picker closed itself")
                try await Task.sleep(for: Self.cardWouldHaveOpened)
                #expect(chat.controller.presentedViewController == nil, "and no card opened after it")
            }
        }
    }
}
