/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import PhotosUI
import SwiftUI

/// A new email as an empty chat (ADR-IOS-114): with the chat view on, every new email opens it (a
/// compose button, a contact pill, a `mailto:` link, with what the request brought), and a saved
/// draft of one reopens it. The header is where every chat's header is, with one empty
/// avatar and "Add recipient" until people are picked; the chat area says what to do; the field is
/// the chat's reply field with "Write your message" and a paperclip at the text's end;
/// attachments wait above the field, each with an x. Nothing is asked when leaving: Back and the
/// app going to the background save the draft when there is something to keep
/// (`ChatNewDraft.needsSave`), and Back leaves once that save is durable. The screen going away
/// any other way (the mailbox list it sits on replaced) saves it too.
///
/// After the compose card's Send the chat stays: its saved draft is discarded, and it goes on as a
/// new email to the same people with an empty field (`ChatNewThreadModel.init(after:)`), showing
/// the send as its "Sending" bubble (`ChatNewEmailSend`) with the bubble's Undo, Retry and Delete.
/// Once the sent email's copy is in the Sent folder, the chat becomes that email's thread
/// (`ChatThreadView`) for good; Back closes it. Undo reopens the compose over the chat
/// (`undoOutcomesPresented`); closed unsent, it leaves the chat as it was before the card's Send,
/// with the people and an empty field.
struct ChatNewThreadView: View {
    /// The new email the chat writes: the one it opened with, then the next one after each send.
    @State private var model: ChatNewThreadModel

    @State private var ownAddresses: Set<String> = []
    @State private var chatExpanded = false
    @State private var chatInputFocused = false
    @State private var chatWorking = false
    /// A drag up on the collapsed field, which opens the TabMail panel as a thread's field does
    /// (`ChatFieldDrag`, `ChatFieldPan`); read only in modifiers, never in this body.
    @State private var fieldDrag = ChatFieldDrag.Model()
    /// Cuts off a drag on the field the panel opened under (`ChatFieldPan.Cut`).
    @State private var fieldPanCut = ChatFieldPan.Cut()
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
    @State private var agentCompose: AgentCard?
    /// A card opened for the field's latest Send: the agent's closing words then open nothing.
    @State private var cardOpened = false
    /// The user's own message the field's Send put up at the bottom of the chat (`ChatFieldMessage`):
    /// from Send until its card is taken or the send ends.
    @State private var fieldMessage: ChatFieldMessage?
    /// That message held while its card is up, and after the card's Send until the send shows
    /// (`ChatHeldGhost`).
    @State private var heldMessage: ChatHeldGhost?
    /// The held message turning into the card's Sending bubble (`ChatOutgoingRows`).
    @Namespace private var sentMorph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The card's Send has a durable outbox row: once the card has gone, the chat goes on as the
    /// next new email (`cardClosed`).
    @State private var cardSent = false
    /// The card's send the chat shows (`ChatNewEmailSend`): the card's draft, and the email its row
    /// named once seen.
    @State private var sendKey: ChatNewEmailSend.Key?
    /// That send, as last read.
    @State private var cardSend: ChatNewEmailSend?
    /// The sent email's thread, read whole (`ChatThreadOpened`): the chat is that thread from then
    /// on, never back.
    @State private var thread: ChatThreadOpened?
    /// The thread read again on the row that replaced the copy the chat became (`followSend`),
    /// which the thread takes in place (`ChatThreadView.adoptReopened`).
    @State private var reopened: ChatThreadOpened?
    /// The Sent copy whose thread is being read, for the swap or for its replacement (`readThread`).
    @State private var readingCopy: String?
    /// This screen's own id among the chat modals (`undoOutcomesPresented`).
    @State private var modalId = UUID()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(model: ChatNewThreadModel) {
        _model = State(initialValue: model)
    }

    /// A compose card the agent asked for, with a draft of its own for a new email
    /// (`ChatNewThreadModel.card`).
    struct AgentCard: Identifiable {
        let request: AgentToolRouter.ComposeRequest
        let draftId = ChatNewThreadModel.newCardDraftId()
        var id: UUID { request.id }
    }

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
        // One container for both, never a Group: a Group gives its modifiers to each child, so the
        // swap would run this screen's close and open, and take down a cover presented over it
        // (a reopened compose included). The ZStack keeps one host for the whole presentation.
        ZStack {
            if let thread {
                // The sent email's thread, with its own header, Forward and reply field.
                ChatThreadView(opened: thread, reopened: reopened)
            } else {
                newEmail
            }
        }
        // Back saves first, so the system's Back (and its swipe) is replaced by this chat's own,
        // on the sent email's thread too: Back closes the chat.
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
            // Who the email goes to, then, once the chat is the sent email's thread, who its reply
            // goes to: one item for the screen's whole life, so the bar keeps a header through the
            // swap. Each branch bringing its own item, the new email's left with it and the
            // thread's came into the bar some commits after the thread's content.
            ToolbarItem(placement: .principal) {
                if let thread {
                    if thread.viewModel.message != nil {
                        ChatHeaderView(people: thread.header.people) { thread.header.asksReplyTo = true }
                    }
                } else {
                    ChatHeaderView(people: model.people, emptyTitle: ChatReplyToSheet.addRecipientTitle,
                                   hint: ChatHeaderView.newEmailHint) { showsAddRecipient = true }
                }
            }
        }
        .undoOutcomesPresented(by: modalId)
        // Followed only until the chat is the sent email's thread on a row no sync replaces
        // (`followsSend`): then its read of the Sent folder's headers ends (memory 021).
        .task(id: followsSend ? sendKey : nil) { await followSend() }
        .task(id: readingCopy) { await readThread() }
        .onChange(of: newEmailCovered) { _, covered in if !covered { swapToThread() } }
        // A held message whose card sent waits for the send to show, then goes.
        .onChange(of: cardSendShows) { _, _ in endHeldMessageIfDone() }
        // The field's Send ended with no card up (nothing written, or Stop): the user's bubble
        // goes, and its words are back in the field.
        .onChange(of: chatWorking) { _, working in if !working { fieldMessage = nil } }
        // The TabMail panel closing lets a waiting swap to the sent email's thread happen.
        .onChange(of: chatExpanded) { _, open in if !open { swapToThread() } }
        .onAppear { opened() }
        // The camera's cover hides this screen without closing it.
        .onDisappear { if !showsCamera { closed() } }
    }

    /// The new email being written: the chat area, its header and the field.
    private var newEmail: some View {
        ScrollView {
            VStack(spacing: ChatViewLayout.bubbleSpacing) {
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
                // The user's side, as a thread's chat shows it (`ChatOutgoingRows`): the field's
                // Send puts the user's own message up at once, pulsing while its email is written,
                // then holds it while its card is up; the card's send turns it into the email's
                // Sending bubble; then the gap above the field.
                ChatOutgoingRows(unsentReplies: cardSend?.reply.map { [$0] } ?? [], heldGhost: heldMessage,
                                 fieldMessage: fieldMessage, morph: sentMorph, undoScreen: .newEmailChat) {
                    EmptyView()
                }
            }
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.previewPaneBg)
        .dismissKeyboardOnTap()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
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
        // The field's Send writes the email itself; asking TabMail is the drag up, as in a thread.
        let opensPanel = !chatExpanded
        return VStack(spacing: ChatViewLayout.traySpacing) {
            if !model.attachments.isEmpty {
                ChatAttachmentTray(attachments: model.attachments) { model.removeAttachment(at: $0) }
            }
            DynamicIslandChat(
                isExpanded: $chatExpanded,
                isInputFocused: $chatInputFocused,
                isWorking: $chatWorking,
                onAgentReply: { _ in agentAnswered() },
                replyField: ChatReplyField(
                    drag: fieldDrag,
                    // The drag's VoiceOver equivalent, as in a thread's chat; not over the panel.
                    showChat: opensPanel ? { withAnimation(.spring(ChatThreadView.pillSpringModel)) { chatExpanded = true } } : nil,
                    newEmail: ChatNewEmailField(
                        startWords: model.startWords,
                        sessionKey: model.sessionKey,
                        wordsChanged: { model.words = $0 },
                        send: { _ in send() },
                        attach: attach)),
                onFieldSend: { fieldSent($0) },
                onFieldWritten: { await fieldMessageWritten() },
                onAgentCompose: openAgentCompose,
                composeFromAccountId: model.account?.id,
                composeHostCovered: newEmailCovered)
            // Drag the field up: it swells under the finger and opens the TabMail panel, as a
            // thread's field does (`ChatThreadView`). The swell grows the field's glass upward and
            // is taken back out of the layout here, so nothing moves under the drag.
            .modifier(ChatFieldDrag.Swell(model: fieldDrag, sign: -1))
            .gesture(ChatFieldPan(isEnabled: opensPanel,
                                  cut: fieldPanCut, moved: fieldDragMoved, ended: fieldDragEnded))
            .modifier(ChatFieldDrag.Watch(model: fieldDrag) { fieldDragChanged($0) })
            // The panel opening under a held drag (the agent answering) cuts that drag off.
            .onChange(of: chatExpanded) { _, expanded in if expanded { fieldPanCut() } }
            // The field gone mid-drag (the swap to the sent email's thread, the screen closing):
            // its drag's freeze ends with it.
            .onDisappear { ChatSwipeHold.shared.releaseNow(ChatThreadView.fieldDragHoldId) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(Self.fieldId)
        }
        .padding(.horizontal, ChatViewLayout.fieldSideInset)
        .padding(.bottom, ChatViewLayout.fieldBottomGap)
    }

    /// Send: with nobody to send to, ask, and the words stay. With people picked, the people the
    /// field's words write the email to, under the subject the chat shows: the words are the user's
    /// own message, never a turn for the agent, and the compose card opens with the email written
    /// (`openAgentCompose`), as a reply sent from a chat's field does. The words and attachments stay
    /// until the card's Send.
    private func send() -> ChatNewEmailField.Write? {
        switch model.sendAction {
        case .askForRecipient:
            asksForRecipient = true
            return nil
        case .write:
            return ChatNewEmailField.Write(people: model.people, subject: model.carried.shownSubject ?? "")
        }
    }

    /// The field's Send: the words go up at once, verbatim, as the user's own bubble at the bottom
    /// of the chat (`ChatFieldMessage`), pulsing while the email that says them is written.
    private func fieldSent(_ text: String) {
        cardOpened = false
        fieldMessage = ChatFieldMessage(text: text)
    }

    /// The email the field's Send wrote is ready: the user's bubble stops pulsing and stays
    /// `ChatSuggestionConfig.writtenHold` to be read before the card opens
    /// (`ToolInvocation.fieldWritten`). Stop ends the hold early, and no card opens.
    private func fieldMessageWritten() async {
        guard fieldMessage != nil else { return }
        fieldMessage?.written = true
        try? await Task.sleep(for: .seconds(ChatSuggestionConfig.writtenHold))
    }

    /// The card's send shows in the chat: its outbox bubble, or its Sent copy.
    private var cardSendShows: Bool {
        cardSend?.reply != nil || cardSend?.sentCopyId != nil
    }

    /// The held message goes once its card has closed: at once when nothing was sent, else once
    /// the send shows, turning into its Sending bubble as a thread's held bubble does.
    private func endHeldMessageIfDone() {
        guard let held = heldMessage, held.ends(replyShows: cardSendShows) else { return }
        withAnimation(ChatOutgoing.endAnimation(held, reduceMotion: reduceMotion)) {
            heldMessage = nil
        }
    }

    /// The drag up on the collapsed field moved (`ChatFieldPan`): the field swells under the finger.
    private func fieldDragMoved(_ drag: ChatHorizontalPan.Sample) {
        fieldDrag.progress = ChatFieldDrag.progress(translation: drag.travel)
    }

    /// The drag up let go, or was cancelled: the swell springs back however it ended, and a
    /// finished drag that reaches the open distance (or a flick's predicted one) opens the panel in
    /// the same transaction, as in a thread's chat (`ChatThreadView.fieldDragEnded`).
    private func fieldDragEnded(_ drag: ChatHorizontalPan.Sample, finished: Bool) {
        let opens = finished && ChatFieldDrag.opens(letGo: drag)
        withAnimation(.spring(ChatThreadView.pillSpringModel)) {
            fieldDrag.progress = ChatFieldDrag.Progress()
            if opens { chatExpanded = true }
        }
    }

    /// A drag on the field began or ended: it holds the interaction freeze from its start, and
    /// after its let-go while the swell settles and the freeze rule's cooldown, under the thread's
    /// field drag's id, as there (`ChatThreadView.fieldDragChanged`). A drag also ends the drag tip.
    private func fieldDragChanged(_ dragging: Bool) {
        if dragging {
            ChatSwipeHold.shared.begin(ChatThreadView.fieldDragHoldId)
            ChatFieldDragTip.close()
            return
        }
        ChatSwipeHold.shared.release(
            ChatThreadView.fieldDragHoldId, after: ChatThreadView.fieldDragSettle + ChatViewLayout.freezeCooldown)
    }

    /// The compose card this chat's field (or, with the panel open, its agent) asked for, taken by
    /// this chat's pill (ADR-IOS-053 Phase
    /// 2). A new email opens from the account bound when its turn started; when that account is
    /// gone the request ends and nothing opens.
    private func openAgentCompose(_ req: AgentToolRouter.ComposeRequest) {
        guard AgentToolRouter.shared.canOpen(req, accounts: accounts) else { return }
        cardOpened = true
        // The field's own card: its Send's message is held in its place while the card is up.
        if let message = fieldMessage {
            heldMessage = ChatHeldGhost(text: message.text, isMessage: true, showsBubble: true)
            fieldMessage = nil
        }
        agentCompose = AgentCard(request: req)
    }

    /// The card, as the chat's reply cards open: today's compose. The new email written goes to
    /// this chat's people, with its Cc, Bcc, subject and attachments, in the card's own
    /// draft (`ChatNewThreadModel.card`), and its Send is this chat's send. A card the agent opens
    /// for another email (a reply or a forward) is the agent's presenter's, and its send is not
    /// this chat's.
    private func cardView(for card: AgentCard) -> ComposeView {
        let req = card.request
        let account = accounts.first { $0.id == req.fromAccountId }
        guard req.mode == .compose else { return req.composeView(account: account, onOutcome: req.onOutcome) }
        return model.card(for: req, account: account, draftId: card.draftId) { outcome in
            req.onOutcome(outcome)
            guard case .sent = outcome else { return }
            heldMessage?.sent = true
            cardSent = true
            sendKey = ChatNewEmailSend.Key(draftId: card.draftId)
        }
    }

    /// The card has gone. Sent: the email is in the outbox, shown as this chat's bubble
    /// (`sendKey`), and the chat goes on as the next new email to the same people with an empty
    /// field (`ChatNewThreadModel.init(after:)`), in a draft and agent session of its own; the
    /// sent email's saved draft is discarded through compose's Discard, unless its attachments
    /// could not be read, when it is kept (`discardSavedDraft`). Closed unsent: the words and
    /// attachments are still here.
    private func cardClosed() {
        heldMessage?.cardClosed = true
        endHeldMessageIfDone()
        guard cardSent else { return }
        cardSent = false
        let sent = model
        let next = ChatNewThreadModel(after: sent)
        model = next
        DraftSessionRegistry.shared.register(next.draftId)
        ChatPillState.shared.endSession(for: sent.sessionKey)
        Task {
            if case .refused(let message) = await sent.discardSavedDraft(), DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatNewEmail] draft discard after send refused for \(sent.draftId): \(message)")
            }
            DraftSessionRegistry.shared.unregister(sent.draftId)
        }
    }

    /// Follows the card's send (`sendKey`): its bubble while its row is in the outbox, then the
    /// sent email's thread once its Sent copy is read (`swapToThread`). The email the row names
    /// goes into the key, so the copy is found after the row has gone, and a send again from the
    /// compose its Undo reopened (a new row, the same draft) is followed too. The copy the chat
    /// first becomes is usually the send's optimistic one, which a sync replaces with the server's
    /// copy of the same email under another id; the follow goes on until the thread is on that copy
    /// (`followsSend`), which the thread then takes in place, so a Send from its field writes to
    /// the row that is there. Then nothing here reads the send again, and the follow ends.
    private func followSend() async {
        guard followsSend, let key = sendKey else { return }
        do {
            for try await found in ChatNewEmailSend.changes(key) {
                cardSend = found
                if let email = found.email, email != key.email {
                    sendKey?.email = email
                    return
                }
                swapToThread()
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatNewEmail] send observation ended: \(error)")
            }
        }
    }

    /// The sent email's copy is in the Sent folder: the chat becomes its thread for good, once
    /// nothing is open over the new email (a card, a picker, "Add recipient" or the TabMail panel,
    /// which the field's drag opens at will), which the change would take down. The panel is kept
    /// out of `newEmailCovered`, which also decides whether a compose card may present. The thread
    /// is read first (`readThread`), so it shows whole from its first frame.
    /// Once the chat is the thread, a copy other than the one it shows (the server's, which replaced
    /// the optimistic copy) is read for the thread to take in place: nothing over it is taken down.
    private func swapToThread() {
        guard let copy = cardSend?.sentCopyId else { return }
        if let shown = reopened ?? thread {
            guard followsSend, copy != shown.viewModel.messageId else { return }
        } else {
            guard !newEmailCovered, !chatExpanded else { return }
        }
        readingCopy = copy
    }

    /// The chat still follows its send: until it is the sent email's thread on a row no sync
    /// replaces. The send's optimistic Sent copy (`isSyntheticPlaceholderId`) is replaced by the
    /// server's under another id, and a thread on a copy not yet read is followed too.
    private var followsSend: Bool {
        guard let shown = (reopened ?? thread)?.viewModel.message else { return true }
        return isSyntheticPlaceholderId(shown.messageId)
    }

    /// Reads the sent email's thread (`ChatThreadOpened.read`), then becomes it, unless something
    /// came over the new email while it read: then the next `swapToThread` reads it again. On the
    /// thread already, the read of the copy that replaced the shown one goes to the thread, which
    /// takes it in place (`ChatThreadView.adoptReopened`).
    private func readThread() async {
        guard let copy = readingCopy else { return }
        let read = await ChatThreadOpened.read(messageId: copy)
        guard !Task.isCancelled else { return }
        readingCopy = nil
        if thread != nil {
            guard read.viewModel.message != nil else { return }
            reopened = read
            return
        }
        guard !newEmailCovered, !chatExpanded else { return }
        thread = read
    }

    /// Something is open over the new email: a picker, "Add recipient" or a compose card.
    private var newEmailCovered: Bool {
        showsAddRecipient || showsCamera || showsPhotoPicker || showsFilePicker || agentCompose != nil
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
