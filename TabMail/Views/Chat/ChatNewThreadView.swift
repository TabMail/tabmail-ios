/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import PhotosUI
import SwiftUI

/// A new email as an empty chat (ADR-IOS-114): with the chat view on, every new email opens it (a
/// compose button, a contact pill, a `mailto:` link, with what the request brought), and a saved
/// draft of one reopens it. The header is where every chat's header is, with one empty
/// avatar and "Add recipient" until people are picked; the chat area says what to do; the field is
/// the chat's reply field with "Message or ask anything" and a paperclip at the text's end;
/// attachments wait above the field, each with an x. Nothing is asked when leaving: Back and the
/// app going to the background save the draft when there is something to keep
/// (`ChatNewDraft.needsSave`), and Back leaves once that save is durable. The screen going away
/// any other way (the mailbox list it sits on replaced) saves it too.
struct ChatNewThreadView: View {
    let model: ChatNewThreadModel

    /// The field's "e.g." example, picked once as the chat opens, from the new-email set.
    @State private var example = ChatSuggestionConfig.randomExample(from: ChatSuggestionConfig.newEmailExamples)
    @State private var ownAddresses: Set<String> = []
    @State private var chatExpanded = false
    @State private var chatInputFocused = false
    @State private var chatWorking = false
    /// What the agent is doing about a Send from the field, shown above it (`ChatFieldStatusKey`).
    @State private var fieldStatus: String?
    @State private var showsAddRecipient = false
    @State private var asksForRecipient = false
    /// A save that did not happen, Back's or the background's: shown until the user chooses.
    @State private var saveRefusal: String?
    @State private var isLeaving = false
    /// "Leave without saving" was chosen: the screen closes with no save.
    @State private var leavesWithoutSaving = false
    /// Between the screen's opening and its closing; the camera's cover does not close it.
    @State private var isOpen = false
    /// A reopened draft's attachments could not be read: said once, as the chat opens.
    @State private var showsAttachmentLoadFailure = false
    @State private var showsPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showsFilePicker = false
    @State private var showsCamera = false
    /// The app's accounts, read as the chat opens: a card opens only from an account still here
    /// (`AgentToolRouter.canOpen`).
    @State private var accounts: [Account] = []
    /// The compose card the agent wrote from the field's words (`email_compose`), taken by this
    /// chat's pill for this chat's own session only.
    @State private var agentCompose: AgentToolRouter.ComposeRequest?
    /// A card opened for the field's latest Send: the agent's closing words then open nothing.
    @State private var cardOpened = false
    /// The card's Send has a durable outbox row: once the card has gone, the chat closes.
    @State private var cardSent = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// The field, as tests find it.
    static let fieldId = "chatNewEmailField"
    /// The chat area's line, as tests find it.
    static let hintId = "chatNewEmailHint"
    static let savedLineId = "chatNewEmailSaved"
    static let backId = "chatNewEmailBack"
    static let ccLineId = "chatNewEmailCc"
    static let bccLineId = "chatNewEmailBcc"

    /// A "Cc: ..." or "Bcc: ..." line in the chat area, when it has someone in it.
    @ViewBuilder
    private func copyLine(_ text: String?, id: String) -> some View {
        if let text {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(id)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ChatViewLayout.bubbleSpacing) {
                Text(ChatNewDraft.recipientsLine(model.people) ?? ChatNewDraft.emptyHint)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(Self.hintId)
                // Cc and Bcc a link brought or a reopened draft holds: shown, changed on the compose card.
                copyLine(ChatNewDraft.copyLine("Cc", model.carried.cc), id: Self.ccLineId)
                copyLine(ChatNewDraft.copyLine("Bcc", model.carried.bcc), id: Self.bccLineId)
                if let savedAt = model.savedAt {
                    Text(ChatNewDraft.savedLine(savedAt))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier(Self.savedLineId)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.previewPaneBg)
        .dismissKeyboardOnTap()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // Back saves first, so the system's Back (and its swipe) is replaced by this chat's own.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { leave() } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(isLeaving)
                .accessibilityLabel("Back")
                .accessibilityIdentifier(Self.backId)
            }
            ToolbarItem(placement: .principal) {
                ChatHeaderView(people: model.people, emptyTitle: ChatReplyToSheet.addRecipientTitle,
                               hint: ChatHeaderView.newEmailHint) { showsAddRecipient = true }
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) { ChatNewEmailSubjectLine(subject: model.carried.shownSubject) }
        .safeAreaBar(edge: .bottom, spacing: 0) { bottomBar }
        // The user's addresses are captured as the body runs, so the body depends on them and runs
        // again when `loadOwnAddresses` fills them in. Read only inside the sheet's closure, they
        // were not a dependency: the sheet opened with the value from before that read, empty, and
        // added the user's own address.
        .sheet(isPresented: $showsAddRecipient) { [ownAddresses] in
            ChatReplyToSheet(replyPeople: model.people, target: .replyAll, ownAddresses: ownAddresses,
                             title: ChatReplyToSheet.addRecipientTitle,
                             recentPeople: { await ChatRecentPeople.load(pool: AppDatabase.rawPool, ownAddresses: ownAddresses,
                                                                           demoActive: DemoModeStore.isDemoActive) }) { done in
                model.setPeople(ChatNewDraft.people(after: done, current: model.people))
            }
        }
        .alert(ChatNewThreadView.askTitle, isPresented: $asksForRecipient) {
            Button(ChatReplyToSheet.addRecipientTitle) { showsAddRecipient = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ChatNewThreadView.askMessage)
        }
        .alert("This draft couldn't be saved", isPresented: refusalShown) {
            Button("Leave without saving", role: .destructive) { leaveWithoutSaving() }
            Button("Stay", role: .cancel) {}
        } message: {
            Text(saveRefusal ?? "")
        }
        .alert(Self.attachmentLoadTitle, isPresented: $showsAttachmentLoadFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ChatNewThreadModel.attachmentLoadMessage)
        }
        .alert("Couldn't add", isPresented: importFailureShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failedImports.joined(separator: ", "))
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoPickerItems, matching: .any(of: [.images, .videos]))
        .onChange(of: photoPickerItems) { _, items in addPicked(items) }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            addFiles(result)
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPickerView { image in model.addCameraPhoto(image) }
        }
        .fullScreenCover(item: $agentCompose, onDismiss: cardClosed) { cardView(for: $0) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await saveInBackground() } }
        }
        .task { await loadOwnAddresses() }
        .onAppear { opened() }
        // The camera's cover hides this screen without closing it.
        .onDisappear { if !showsCamera { closed() } }
    }

    static let askTitle = "Who is this to?"
    static let askMessage = "Add at least one recipient to send this email."
    static let attachmentLoadTitle = "Attachments couldn't be loaded"

    private var refusalShown: Binding<Bool> {
        Binding(get: { saveRefusal != nil }, set: { if !$0 { saveRefusal = nil } })
    }

    private var importFailureShown: Binding<Bool> {
        Binding(get: { !model.failedImports.isEmpty }, set: { if !$0 { model.failedImports = [] } })
    }

    /// The attachments waiting, then the field: the chat's bottom bar.
    private var bottomBar: some View {
        VStack(spacing: ChatViewLayout.traySpacing) {
            if !model.attachments.isEmpty {
                ChatAttachmentTray(attachments: model.attachments) { model.removeAttachment(at: $0) }
            }
            if let fieldStatus {
                ChatFieldStatusLine(text: fieldStatus)
                    .transition(.opacity)
            }
            DynamicIslandChat(
                isExpanded: $chatExpanded,
                isInputFocused: $chatInputFocused,
                isWorking: $chatWorking,
                onAgentReply: { _ in agentAnswered() },
                replyField: ChatReplyField(
                    example: example,
                    newEmail: ChatNewEmailField(
                        startWords: model.startWords,
                        sessionKey: model.sessionKey,
                        wordsChanged: { model.words = $0 },
                        send: { _ in send() },
                        attach: attach)),
                onFieldSend: { _ in cardOpened = false },
                onAgentCompose: openAgentCompose,
                composeFromAccountId: model.account?.id,
                composeHostCovered: showsAddRecipient || showsCamera || showsPhotoPicker || showsFilePicker
                    || agentCompose != nil)
            // The agent's status on a Send shows above the field (`ChatFieldStatusLine`).
            .onPreferenceChange(ChatFieldStatusKey.self) { status in
                withAnimation(.spring(ChatThreadView.pillSpringModel)) { fieldStatus = status }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(Self.fieldId)
        }
        .padding(.horizontal, ChatViewLayout.fieldSideInset)
        .padding(.bottom, ChatViewLayout.fieldBottomGap)
    }

    /// Send: with nobody to send to, ask, and the words stay. With people picked, the people the
    /// field's words go to the agent for: it writes the email to them and opens the compose card
    /// (`openAgentCompose`), as a reply sent from a chat's field does. The words and attachments
    /// stay until the card's Send.
    private func send() -> [ChatThread.Person]? {
        switch model.sendAction {
        case .askForRecipient:
            asksForRecipient = true
            return nil
        case .write:
            return model.people
        }
    }

    /// The compose card this chat's agent asked for, taken by this chat's pill (ADR-IOS-053 Phase
    /// 2). A new email opens from the account bound when its turn started; when that account is
    /// gone the request ends and nothing opens.
    private func openAgentCompose(_ req: AgentToolRouter.ComposeRequest) {
        guard AgentToolRouter.shared.canOpen(req, accounts: accounts) else { return }
        cardOpened = true
        agentCompose = req
    }

    /// The card, as the chat's reply cards open: today's compose. The email the agent wrote goes
    /// to this chat's people, with its Cc, Bcc, subject and attachments (`ChatNewThreadModel.card`).
    private func cardView(for req: AgentToolRouter.ComposeRequest) -> ComposeView {
        let account = accounts.first { $0.id == req.fromAccountId }
        let ended: @MainActor (ComposeOutcome) -> Void = { outcome in
            req.onOutcome(outcome)
            if case .sent = outcome { cardSent = true }
        }
        guard req.mode == .compose else { return req.composeView(account: account, onOutcome: ended) }
        return model.card(for: req, account: account, onOutcome: ended)
    }

    /// The card has gone. Sent: the email is in the outbox (its Undo is the toast's), so the
    /// chat's own draft is discarded through compose's Discard and the chat closes without saving.
    /// Closed unsent: the words and attachments are still here.
    private func cardClosed() {
        guard cardSent else { return }
        cardSent = false
        Task {
            if case .refused(let message) = await model.discardSavedDraft(), DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatNewEmail] draft discard after send refused for \(model.draftId): \(message)")
            }
            leavesWithoutSaving = true
            dismiss()
        }
    }

    /// The agent answered the field's Send with something to say: the chat rises with the request
    /// and the answer. After a compose card the email was the point, so nothing opens.
    private func agentAnswered() {
        guard !cardOpened else { return }
        withAnimation { chatExpanded = true }
    }

    private func attach(_ source: ChatNewEmailField.AttachSource) {
        switch source {
        case .photos: showsPhotoPicker = true
        case .camera: showsCamera = true
        case .files: showsFilePicker = true
        }
    }

    private func addPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let loading = model.addPicked(items) { item in
            (try await item.loadTransferable(type: Data.self), item.supportedContentTypes.first)
        }
        Task {
            await loading?.value
            photoPickerItems = []
        }
    }

    private func addFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            model.addFiles(urls)
        case .failure(let error):
            model.failedImports.append(error.localizedDescription)
        }
    }

    /// Back: the draft is saved when there is something to keep, then the chat leaves. A save
    /// that does not happen keeps the chat open and says why.
    private func leave() {
        guard !isLeaving else { return }
        isLeaving = true
        Task {
            let outcome = await model.saveIfNeeded()
            isLeaving = false
            switch outcome {
            case .saved: dismiss()
            case .refused(let message): saveRefusal = message
            }
        }
    }

    /// "Leave without saving", after a save was refused: the chat closes and nothing is saved.
    private func leaveWithoutSaving() {
        leavesWithoutSaving = true
        dismiss()
    }

    /// The app went to the background: the draft is saved as Back saves it; the chat stays.
    private func saveInBackground() async {
        if case .refused(let message) = await model.saveIfNeeded() {
            saveRefusal = message
        }
    }

    /// The screen opened: the draft is kept from eviction while the user writes it, as one open in
    /// compose, and a reopened draft whose attachments could not be read says so at once.
    private func opened() {
        guard !isOpen else { return }
        isOpen = true
        DraftSessionRegistry.shared.register(model.draftId)
        if model.attachmentLoadFailed { showsAttachmentLoadFailure = true }
    }

    /// The screen closed, by Back or any other way: the chat's session ends, the draft is saved
    /// when there is something to keep (after Back's save, nothing is left to keep) unless the user
    /// chose to leave without saving, and only then is it given back to eviction. The screen is
    /// gone, so a refusal here is only logged.
    private func closed() {
        guard isOpen else { return }
        isOpen = false
        let model = model
        let saves = !leavesWithoutSaving
        ChatPillState.shared.endSession(for: model.sessionKey)
        Task { @MainActor in
            if saves, case .refused(let message) = await model.saveIfNeeded(),
               DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatNewEmail] save on close refused for \(model.draftId): \(message)")
            }
            DraftSessionRegistry.shared.unregister(model.draftId)
        }
    }

    /// The user's own addresses, which "Add recipient" does not add, and the accounts a card may
    /// open from.
    private func loadOwnAddresses() async {
        do {
            let accounts = try await AppDatabase.dbPool.read { db in try Account.fetchAll(db) }
            self.accounts = accounts
            ownAddresses = Set(accounts.map { $0.emailAddress.lowercased() })
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatNewEmail] own addresses read failed: \(error)")
            }
        }
    }
}

/// The line under a new email's header, where a chat's subject is, drawn as a thread's
/// (`ChatSubjectText`): the subject a `mailto:` link brought or a reopened draft holds, else
/// "New email". The subject is written on the compose card.
struct ChatNewEmailSubjectLine: View {
    static let text = "New email"
    var subject: String?

    var body: some View {
        ChatSubjectText(subject: subject ?? Self.text)
    }
}

/// The field's paperclip, at the end of its text on Send's row: Photos, Camera or Files. A new
/// email's chat and every thread's chat show it (`ChatReplyField.paperclip`).
///
/// Its choices open in a pop-up over the field, and the field stays as it is. A system menu here
/// grows out of the field's glass and takes the field's place while it is open.
struct ChatPaperclipButton: View {
    let attach: (ChatNewEmailField.AttachSource) -> Void
    @ScaledMetric(relativeTo: .body) private var lineHeight = ChatViewLayout.fieldLineHeight
    /// The choices' pop-up is open.
    @State private var showsChoices = false
    /// The choice made in the pop-up, taken once the pop-up has gone: UIKit refuses a picker
    /// presented while the pop-up is still closing.
    @State private var chosen: ChatNewEmailField.AttachSource?

    var body: some View {
        Button { showsChoices = true } label: {
            Image(systemName: "paperclip")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: ChatViewLayout.fieldPaperclipTapWidth, height: ChatViewLayout.fieldTapSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(FieldButtonSlot(
            glyphWidth: ChatViewLayout.fieldPaperclipGlyphWidth, tapWidth: ChatViewLayout.fieldPaperclipTapWidth,
            lineHeight: lineHeight))
        .accessibilityLabel("Attach")
        .accessibilityIdentifier(Self.id)
        .popover(isPresented: $showsChoices, arrowEdge: .bottom) {
            ChatAttachChoices { source in
                chosen = source
                showsChoices = false
            }
            .onDisappear {
                guard let source = chosen else { return }
                chosen = nil
                attach(source)
            }
        }
    }

    static let id = "chatPaperclip"
}

/// The paperclip's pop-up: Photos, Camera and Files, one row each.
struct ChatAttachChoices: View {
    let choose: (ChatNewEmailField.AttachSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ChatNewEmailField.AttachSource.allCases, id: \.self) { source in
                Button { choose(source) } label: {
                    Label(source.title, systemImage: source.systemImage)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: ChatViewLayout.fieldTapSize, alignment: .leading)
                        .padding(.horizontal, ChatViewLayout.attachChoicePadding)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(Self.id(source))
                if source != ChatNewEmailField.AttachSource.allCases.last {
                    Divider()
                }
            }
        }
        .frame(width: ChatViewLayout.attachChoicesWidth)
        .presentationCompactAdaptation(.popover)
    }

    /// Each choice's row, as tests find it.
    static func id(_ source: ChatNewEmailField.AttachSource) -> String {
        "chatAttachChoice.\(source.title)"
    }
}

/// A new email's attachments waiting above the field: photos as thumbnails, files as chips, each
/// with an x that takes it away.
struct ChatAttachmentTray: View {
    let attachments: [DraftAttachment]
    let remove: (Int) -> Void

    static let id = "chatAttachmentTray"
    static let removeId = "chatAttachmentRemove"

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ChatViewLayout.traySpacing) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    item(attachment)
                        .overlay(alignment: .topTrailing) {
                            Button { remove(index) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: ChatViewLayout.trayRemoveSize))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(ChatViewLayout.trayRemoveBackdropOpacity))
                            }
                            .buttonStyle(.plain)
                            .offset(x: ChatViewLayout.trayRemoveOffset, y: -ChatViewLayout.trayRemoveOffset)
                            .accessibilityLabel("Remove \(AttachmentFilename.displayLabel(attachment.filename))")
                            .accessibilityIdentifier(Self.removeId)
                        }
                }
            }
            // Room for the x, which stands out past each item's corner.
            .padding(.top, ChatViewLayout.trayRemoveOffset)
            .padding(.trailing, ChatViewLayout.trayRemoveOffset)
        }
        .accessibilityIdentifier(Self.id)
    }

    @ViewBuilder
    private func item(_ attachment: DraftAttachment) -> some View {
        if attachment.mimeType.lowercased().hasPrefix("image/") {
            ChatTrayThumbnail(attachment: attachment)
        } else {
            HStack(spacing: ChatViewLayout.trayChipIconGap) {
                Image(systemName: "doc")
                    .font(.caption)
                // The label, never the raw name: see `AttachmentFilename.displayLabel`.
                Text(AttachmentFilename.displayLabel(attachment.filename))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, ChatViewLayout.traySpacing)
            .frame(maxWidth: ChatViewLayout.trayChipMaxWidth, minHeight: ChatViewLayout.trayChipHeight)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: ChatViewLayout.trayCornerRadius))
        }
    }
}

/// A photo's thumbnail in the tray, decoded once off the view's body.
private struct ChatTrayThumbnail: View {
    let attachment: DraftAttachment
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.systemGray5)
            }
        }
        .frame(width: ChatViewLayout.trayThumbnailSize, height: ChatViewLayout.trayThumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: ChatViewLayout.trayCornerRadius))
        .accessibilityLabel(AttachmentFilename.displayLabel(attachment.filename))
        // Keyed by the attachment itself, bytes included, as the chat tells a change.
        .task(id: attachment) {
            let side = ChatViewLayout.trayThumbnailSize * displayScale
            image = await UIImage(data: attachment.data)?
                .byPreparingThumbnail(ofSize: CGSize(width: side, height: side))
        }
    }
}
