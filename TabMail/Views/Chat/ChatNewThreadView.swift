/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import PhotosUI
import SwiftUI

/// A new email as an empty chat (ADR-IOS-114): the chat view's compose button opens it, and a
/// saved draft of one reopens it. The header is where every chat's header is, with one empty
/// avatar and "Add recipient" until people are picked; the chat area says what to do; the field is
/// the chat's reply field with "Message or ask anything" and a paperclip at the text's end;
/// attachments wait above the field, each with an x. Nothing is asked when leaving: Back and the
/// app going to the background save the draft when there is something to keep
/// (`ChatNewDraft.needsSave`), and Back leaves once that save is durable.
struct ChatNewThreadView: View {
    let model: ChatNewThreadModel

    /// This chat's own agent session, in memory only.
    @State private var sessionKey = ChatNewEmailField.newSessionKey()
    /// The field's "e.g." example, picked once as the chat opens, from the new-email set.
    @State private var example = ChatSuggestionConfig.randomExample(from: ChatSuggestionConfig.newEmailExamples)
    @State private var ownAddresses: Set<String> = []
    @State private var chatExpanded = false
    @State private var chatInputFocused = false
    @State private var chatWorking = false
    @State private var showsAddRecipient = false
    @State private var asksForRecipient = false
    /// A save that did not happen, Back's or the background's: shown until the user chooses.
    @State private var saveRefusal: String?
    @State private var isLeaving = false
    @State private var showsPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showsFilePicker = false
    @State private var showsCamera = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// The field, as tests find it.
    static let fieldId = "chatNewEmailField"
    /// The chat area's line, as tests find it.
    static let hintId = "chatNewEmailHint"
    static let savedLineId = "chatNewEmailSaved"
    static let backId = "chatNewEmailBack"

    var body: some View {
        ScrollView {
            VStack(spacing: ChatViewLayout.bubbleSpacing) {
                Text(ChatNewDraft.recipientsLine(model.people) ?? ChatNewDraft.emptyHint)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(Self.hintId)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.previewPaneBg)
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
        .safeAreaBar(edge: .top, spacing: 0) { ChatNewEmailSubjectLine() }
        .safeAreaBar(edge: .bottom, spacing: 0) { bottomBar }
        .sheet(isPresented: $showsAddRecipient) {
            ChatReplyToSheet(replyPeople: model.people, target: .replyAll, ownAddresses: ownAddresses,
                             title: ChatReplyToSheet.addRecipientTitle) { done in
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
            Button("Leave without saving", role: .destructive) { dismiss() }
            Button("Stay", role: .cancel) {}
        } message: {
            Text(saveRefusal ?? "")
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await saveInBackground() } }
        }
        .task { await loadOwnAddresses() }
        // A draft open here is never evicted while the user writes it, as one open in compose.
        .onAppear { DraftSessionRegistry.shared.register(model.draftId) }
        .onDisappear { DraftSessionRegistry.shared.unregister(model.draftId) }
    }

    static let askTitle = "Who is this to?"
    static let askMessage = "Add at least one recipient to send this email."

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
            DynamicIslandChat(
                isExpanded: $chatExpanded,
                isInputFocused: $chatInputFocused,
                isWorking: $chatWorking,
                replyField: ChatReplyField(
                    example: example, isNoReply: false, clearCount: 0,
                    newEmail: ChatNewEmailField(
                        startWords: model.startWords,
                        sessionKey: sessionKey,
                        wordsChanged: { model.words = $0 },
                        send: { _ in send() },
                        attach: attach)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(Self.fieldId)
        }
        .padding(.horizontal, ChatViewLayout.fieldSideInset)
        .padding(.bottom, ChatViewLayout.fieldBottomGap)
    }

    /// Send: with nobody to send to, ask; the words and attachments stay either way.
    private func send() {
        switch model.sendAction {
        case .askForRecipient:
            asksForRecipient = true
        case .write:
            // Writing the email for its recipients is not handled in this chat yet.
            break
        }
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

    /// The app went to the background: the draft is saved as Back saves it; the chat stays.
    private func saveInBackground() async {
        if case .refused(let message) = await model.saveIfNeeded() {
            saveRefusal = message
        }
    }

    /// The user's own addresses, which "Add recipient" does not add.
    private func loadOwnAddresses() async {
        do {
            let accounts = try await AppDatabase.dbPool.read { db in try Account.fetchAll(db) }
            ownAddresses = Set(accounts.map { $0.emailAddress.lowercased() })
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatNewEmail] own addresses read failed: \(error)")
            }
        }
    }
}

/// The line under a new email's header, where a chat's subject is: it has no subject yet.
struct ChatNewEmailSubjectLine: View {
    static let text = "New email"

    var body: some View {
        Text(Self.text)
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal)
            .padding(.bottom, ChatViewLayout.subjectLineBottomGap)
            .frame(maxWidth: .infinity)
    }
}

/// A new email's paperclip, at the end of the field's text: Photos, Camera or Files.
struct ChatPaperclipButton: View {
    let attach: (ChatNewEmailField.AttachSource) -> Void
    @ScaledMetric(relativeTo: .body) private var lineHeight = ChatViewLayout.fieldLineHeight

    var body: some View {
        Menu {
            ForEach(ChatNewEmailField.AttachSource.allCases, id: \.self) { source in
                Button { attach(source) } label: {
                    Label(source.title, systemImage: source.systemImage)
                }
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: ChatViewLayout.fieldMicTapWidth, height: ChatViewLayout.fieldTapSize)
                .contentShape(Rectangle())
        }
        .modifier(FieldButtonSlot(
            glyphWidth: ChatViewLayout.fieldPaperclipGlyphWidth, tapWidth: ChatViewLayout.fieldMicTapWidth,
            lineHeight: lineHeight))
        .accessibilityLabel("Attach")
        .accessibilityIdentifier(Self.id)
    }

    static let id = "chatPaperclip"
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
        .task(id: ChatNewDraft.fingerprint(attachment)) {
            let side = ChatViewLayout.trayThumbnailSize * displayScale
            image = await UIImage(data: attachment.data)?
                .byPreparingThumbnail(ofSize: CGSize(width: side, height: side))
        }
    }
}
