/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import GRDB
import SwiftUI
import TipKit

#if DEBUG
extension Notification.Name {
    /// Test seam only: a scroll phase delivered to the open chat as if its scroll view reported it.
    static let chatScrollPhaseForTesting = Notification.Name("chatScrollPhaseForTesting")
    /// Test fixture only: the jump button was tapped (its animated scroll starts now).
    static let chatJumpTappedForTesting = Notification.Name("chatJumpTappedForTesting")
    /// Test seam only: a pick for the reply field's paperclip (a `ComposeAttachmentPick`), as if a
    /// picker gave it and closed.
    static let chatPaperclipPickForTesting = Notification.Name("chatPaperclipPickForTesting")
    /// Test seam only: a choice in the reply field's paperclip menu (a
    /// `ChatNewEmailField.AttachSource`), which opens its picker as the menu does.
    static let chatPaperclipOpenForTesting = Notification.Name("chatPaperclipOpenForTesting")
}
#endif

extension ChatViewConfig {
    /// Whether an open goes to the chat now. Demo mode with AI declined counts as AI off. A
    /// tutorial run follows what it teaches (`followingTutorial`).
    @MainActor static var opensInChat: Bool {
        let tutorial = TutorialCoordinator.shared
        return opensInChat(active: isActive,
                           demoHidesAI: DemoModeStore.shared.hidesAIContent,
                           tutorialRunning: tutorial.isRunning,
                           tutorialTeachesChat: tutorial.teachesChat)
    }

    static func opensInChat(active: Bool, demoHidesAI: Bool, tutorialRunning: Bool, tutorialTeachesChat: Bool) -> Bool {
        followingTutorial(active && !demoHidesAI, tutorialRunning: tutorialRunning, tutorialTeachesChat: tutorialTeachesChat)
    }

    /// The chat view's one tutorial-aware gate: while a tutorial runs, what the run teaches
    /// (`TutorialCoordinator.teachesChat`, decided when it started); otherwise `live`, the app's own
    /// value. Opens (`opensInChat`, and `SentEmailSummary.mayRun` through it), the inbox rows' chat
    /// preview and the Enable Chat View switch all go through it, so a run shows one view
    /// everywhere, before the AI choice too.
    ///
    /// Read in a view's body, it observes the run (`TutorialCoordinator` is `@Observable`; both
    /// `isRunning` and `teachesChat` are read), so the view repaints when a run starts or ends.
    @MainActor static func followingTutorial(_ live: Bool) -> Bool {
        let tutorial = TutorialCoordinator.shared
        return followingTutorial(live, tutorialRunning: tutorial.isRunning, tutorialTeachesChat: tutorial.teachesChat)
    }

    static func followingTutorial(_ live: Bool, tutorialRunning: Bool, tutorialTeachesChat: Bool) -> Bool {
        tutorialRunning ? tutorialTeachesChat : live
    }
}

/// A thread as a chat: every email as a bubble, oldest at the top, the newest just above the
/// reply field. Tap a bubble for today's detail of that email, as a card from the bottom.
/// Reuses `MessageDetailViewModel` for loading, thread detection, live AI updates and mark-read.
/// The reply field (`ChatReplyField`) is today's Chat pill on the newest email, shown as
/// [mic] [field] [Send].
struct ChatThreadView: View {
    @State var viewModel: MessageDetailViewModel
    let highlightsOpenedMessage: Bool

    @State private var context = ChatThreadContext()
    /// Emails that were unread when they first showed here; marked read as they show.
    @State private var unreadAtOpen: Set<String> = []
    @State private var seenIds: Set<String> = []
    @State private var didInitialScroll = false
    /// Whether the chat is on screen (`onAppear` to `onDisappear`): a pushed screen covers it.
    @State private var isOnScreen = false
    /// Emails whose bubble has come on screen during this presentation. With the newest
    /// `ChatViewConfig.summaryWindow`, the emails the chat checks for their summary. Only which rows
    /// are checked: whether a row still needs its summary is read from the database at each check.
    @State private var shownIds: Set<String> = []
    @State private var highlightedId: String?
    @State private var showsJumpButton = false
    @State private var cardMessage: MessageHeader?

    // The reply field: today's Chat pill on the newest email.
    @State private var chatExpanded = false
    /// The collapsed field's height, notices and chips included: the height of the bottom bar,
    /// whose inset keeps the last bubble and the jump button above the field. The field grows to six
    /// lines, so it is measured; the open panel keeps the last resting height, and a drag's swell
    /// never reaches it (`pill(on:)` takes the swell back out of the layout, and a floating-point
    /// remainder of that is the same height, `pillHeightMoved`), so the chat does not move under
    /// either.
    @State private var pillHeight = ChatViewLayout.pillStartHeight
    /// What the agent is doing about a Send from the field, shown above it (`ChatFieldStatusKey`).
    @State private var fieldStatus: String?
    /// A drag up on the collapsed field (`ChatFieldDrag`, `ChatFieldPan`): reset however the drag
    /// ends, a cancelled one included, with the pill's spring, so the swell always springs back
    /// (`fieldDragEnded`). Its progress is read only in modifiers (`ChatFieldDrag.Model`), never
    /// in this body.
    @State private var fieldDrag = ChatFieldDrag.Model()
    /// Cuts off a drag on the field the panel opened under (`ChatFieldPan.Cut`).
    @State private var fieldPanCut = ChatFieldPan.Cut()
    @State private var chatInputFocused = false
    @State private var chatWorking = false
    /// The ready AI Suggestion's compose card: the email it answers, and how it opens.
    @State private var readyReply: ChatReadyReply?
    /// The ghost tapped open, held in its place while its card is up (`ChatHeldGhost`).
    @State private var heldGhost: ChatHeldGhost?
    /// The held ghost turning into the sent reply's bubble.
    @Namespace private var sentMorph
    /// The field's "e.g." example, picked once as the chat opens.
    @State private var example = ChatSuggestionConfig.randomExample()
    @State private var agentCompose: AgentToolRouter.ComposeRequest?
    /// A compose card opened for the field's last request, so the agent's closing words open
    /// no sheet.
    @State private var fieldComposeOpened = false
    /// The chat's replies still in the outbox (`ChatUnsentReply`), read from the database.
    @State private var unsentReplies: [ChatUnsentReply] = []
    /// Who the next reply goes to; Reply All until changed in Reply to.
    @State private var replyTarget = ChatReplyTarget.replyAll
    @State private var showsReplyTo = false
    @State private var showsOnlyList = false
    @State private var forwardMessage: MessageHeader?
    /// What is open among the chat's swipes (`ChatSwipeOpen`).
    @State private var swipeOpen = ChatSwipeOpen()
    /// Where the header ends and the reply field starts, in the swipes' space (`ChatSwipeOpen.reach`).
    @State private var headerBottom = -CGFloat.infinity
    @State private var pillTop = CGFloat.infinity
    @State private var showsMove = false
    /// A new email asked for by a contact pill or a `mailto:` link while this chat is on top
    /// (`ChatNewEmailCover`).
    @State private var newEmailCover: ChatNewEmailCover?
    @Environment(\.hasTabMailSession) private var hasTabMailSession
    /// The reply field's paperclip (ADR-IOS-114 decision 10): its pickers, and the card a pick
    /// made, held until its picker has closed.
    @State private var showsPhotoPicker = false
    @State private var showsFilePicker = false
    @State private var showsCamera = false
    @State private var pendingAttachCard: ChatReadyReply?
    /// A paperclip picker is open: from the menu's choice until its `onDismiss`. A pick that lands
    /// while it is waits for that `onDismiss`; one a picker reports after it (the Files picker can
    /// close itself first) opens at once, since nothing is closing any more.
    @State private var paperclipPickerOpen = false
    @Environment(\.dismiss) private var dismiss
    /// The app's accounts: a new email's card opens from its bound account, looked up here.
    @Environment(NavigationStore.self) private var navigationStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// In the detail column: whether the list beside it has a sheet or cover up (`ListPresentationState`).
    @Environment(\.listPresentationBesideDetail) private var listPresentationBesideDetail
    /// Held only while a grow is pending: set when the AI Suggestion's row becomes Writing, cleared
    /// inside the fill's `withAnimation` (`showSuggestion`), so the working bubble filling in is one
    /// animated transaction with its re-pin. A ready suggestion with nothing held is the ghost, so
    /// opening on one never shows the working bubble.
    @State private var suggestionGrowPending = false
    /// Set by `showSuggestion` on the fill under Reduce Motion: the ghost fades in. Every other
    /// insertion of the ghost, and every removal, follows its transaction (at once).
    @State private var ghostFadesIn = false
    @AppStorage(AIService.optOutAllAIKey, store: AIService.optOutStore) private var optOutAllAI = false

    private static let bottomId = "chat-bottom"
    private static let unreadLineId = "chat-unread-line"
    private static let chatSwipeId = "chat-swipe"
    /// What a drag on the reply field holds the interaction freeze under (`ChatSwipeHold`).
    static let fieldDragHoldId = "chat-field-drag"
    /// The pill's spring, as a model so its settling duration can be read.
    static let pillSpringModel = Spring(
        response: ChatViewLayout.pillSpringResponse, dampingRatio: ChatViewLayout.pillSpringDamping)
    private static let pillSpring = Animation.spring(pillSpringModel)
    /// After a drag on the field lets go, how long its swell takes to spring back: the pill's
    /// spring's own settling duration (about 0.6 s for response 0.45 and damping 0.82). The drag's
    /// freeze holds through it plus the freeze rule's cooldown.
    static let fieldDragSettle: Duration = .seconds(pillSpringModel.settlingDuration)

    init(
        messageId: String, expectedRfc822MessageId: String? = nil, expectedObservedUidValidity: Int? = nil,
        highlightsOpenedMessage: Bool = false
    ) {
        self._viewModel = State(initialValue: MessageDetailViewModel(
            messageId: messageId, expectedRfc822MessageId: expectedRfc822MessageId,
            expectedObservedUidValidity: expectedObservedUidValidity))
        self.highlightsOpenedMessage = highlightsOpenedMessage
    }

    // MARK: - Members

    private var members: [MessageHeader] {
        (viewModel.message.map { [$0] } ?? []) + viewModel.threadMessages
    }

    private var thread: ChatThread {
        let accounts = context.accounts
        return ChatThread(
            members: members,
            replyAddresses: { newest in
                let reply = buildReplyAllRecipients(for: newest, allAccounts: accounts)
                return reply.to + reply.cc
            },
            ownAddresses: context.ownAddresses,
            draftFolderIds: context.draftFolderIds,
            sentFolderIds: context.sentFolderIds,
            unreadAtOpen: unreadAtOpen,
            preferredId: viewModel.message?.id)
    }

    /// Changes whenever a bubble's content can change: a member arrives or leaves, its text
    /// message lands, or its body does (attachments, invite).
    private var memberKey: [String] {
        members.map { "\($0.id)|\($0.summaryTextMessage != nil)|\($0.bodyComplete)" }
    }

    /// The Message-IDs of the chat's emails, normalized.
    private var messageIds: Set<String> {
        Set(members.compactMap { $0.rfc822MessageId.map(EmailFilter.normalizeMessageId) })
    }

    private var isAnyPresentation: Bool {
        cardMessage != nil || readyReply != nil || agentCompose != nil
            || forwardMessage != nil || showsReplyTo || showsMove || newEmailCover != nil
            || showsPhotoPicker || showsFilePicker || showsCamera || pendingAttachCard != nil
    }

    // MARK: - Body

    var body: some View {
        // Lifecycle modifiers hang on this stable container, never on the branches the load
        // itself flips (ADR-IOS-054).
        ZStack {
            if viewModel.message != nil {
                chatContent(thread)
            } else if viewModel.messageNotFound {
                ContentUnavailableView {
                    Label("Message Not Found", systemImage: "envelope.badge.shield.half.filled")
                } description: {
                    Text("This message may have been moved or deleted.")
                } actions: {
                    Button("Retry") { Task { await viewModel.retryLoad() } }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.previewPaneBg)
        .dismissKeyboardOnTap()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // The bar stays while the opened pill has focus, unlike the inbox and the email screen: it
        // holds who the chat is with, and Messages never hides it.
        .task {
            noteMembers()
            await viewModel.loadBody()
        }
        .task(id: memberKey) {
            guard !members.isEmpty else { return }
            let loaded = await ChatThreadContext.load(members: members, pool: AppDatabase.dbPool)
            // A member change cancels this load and starts the next. A cancelled read comes back
            // empty, maybe after the next load has shown its context: never show it.
            guard !Task.isCancelled else { return }
            context = loaded
            scrollOnceLoaded()
        }
        .task(id: SummaryWatch(memberIds: members.map(\.id), landed: didInitialScroll, onScreen: isOnScreen)) {
            await followSummaries()
        }
        .onChange(of: viewModel.threadCopies.map(\.id)) { _, _ in noteCopies() }
        .onChange(of: memberKey) { _, _ in noteMembers() }
        .task(id: messageIds) {
            // One observation per open chat of its outbox replies, keyed by its Message-IDs.
            do {
                for try await found in ChatUnsentReply.changes(answering: messageIds) {
                    // A sent reply's Sent copy is in the database (`filed`), or its row left the
                    // outbox (the send's cleanup can delete it before this saw it filed): the chat
                    // reloads its emails, and a sent reply's bubble ends once its copy is one of
                    // them (its Message-ID joins `messageIds`).
                    let left = unsentReplies.contains { shown in !found.contains { $0.id == shown.id } }
                    unsentReplies = found
                    if left || found.contains(where: \.filed) { viewModel.reloadThread() }
                }
            } catch {
                BackgroundSyncLogger.logDebug("[Chat] unsent reply observation ended: \(error)")
            }
        }
        // A new newest email has its own people: the next reply is a Reply All to them.
        .onChange(of: thread.newest.map(ChatThread.copyKey)) { _, _ in replyTarget = .replyAll }
        // A held ghost whose card sent waits for the reply to show, then turns into its bubble.
        .onChange(of: sentReplyShows) { _, _ in endHeldGhostIfDone() }
        .toolbar {
            // Who the reply goes to, in the navigation bar as in Messages: the avatars level with
            // Back, the names under them.
            ToolbarItem(placement: .principal) {
                if viewModel.message != nil {
                    ChatHeaderView(thread: thread) {
                        guard TutorialCoordinator.shared.admits(.other) else { return }
                        showsReplyTo = true
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Forward the newest email, in today's forward compose. The tutorial's mail
                // actions are off.
                Button {
                    guard TutorialCoordinator.shared.admits(.other) else { return }
                    forwardMessage = thread.newest
                } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                }
                .disabled(thread.newest == nil)
                .accessibilityLabel("Forward")
                .accessibilityIdentifier(Self.forwardId)
            }
        }
        .onChange(of: viewModel.hasLoadedThread) { _, _ in scrollOnceLoaded() }
        // Part 3 of the tutorial: the email reference opened this chat at Jordan's email.
        .task(id: viewModel.message?.id) {
            guard let opened = viewModel.message else { return }
            TutorialCoordinator.shared.messageOpened(accountId: opened.accountId, messageId: opened.messageId)
        }
        .onAppear {
            #if DEBUG
            NSLog("[cv9diag] onAppear didInitialScroll=%d", didInitialScroll ? 1 : 0)
            #endif
            viewModel.isViewVisible = true
            isOnScreen = true
            Task { await viewModel.loadBody() }
        }
        .onDisappear {
            viewModel.isViewVisible = false
            isOnScreen = false
            chatExpanded = false
            ChatSwipeHold.shared.releaseNow(Self.fieldDragHoldId)
            ICSCalendarImporter.dismiss()
        }
        .onChange(of: isAnyPresentation) { _, active in viewModel.hasActivePresentation = active }
        .onReceive(NotificationCenter.default.publisher(for: .openMessageWithChat).receive(on: DispatchQueue.main)) { notification in
            guard let msgId = notification.userInfo?["messageId"] as? String, msgId == viewModel.messageId else { return }
            withAnimation(Self.pillSpring) { chatExpanded = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .emailPillTapped).receive(on: DispatchQueue.main)) { _ in
            withAnimation(Self.pillSpring) { chatExpanded = false }
        }
        // A contact pill or a `mailto:` link: one screen takes each request, the one on top. This
        // chat takes it while it shows and nothing is presented over it; its email card's screen
        // takes it while that card is up, and a pushed screen (`isOnScreen`) takes it itself. In
        // the detail column it takes none while the list beside it has a sheet or cover up (iPad).
        // Nor while a compose, a draft or a preview is up anywhere (`composeOrPreviewIsUp`).
        .onReceive(NotificationCenter.default.publisher(for: .contactPillComposeTapped).receive(on: DispatchQueue.main)) { notification in
            guard isOnScreen, !isAnyPresentation, listPresentationBesideDetail?.isUp != true,
                  !ChatNewEmailCover.composeOrPreviewIsUp else { return }
            guard let request = MailtoRequest.from(userInfo: notification.userInfo) else { return }
            withAnimation(Self.pillSpring) { chatExpanded = false }
            newEmailCover = .make(
                request: request, opensInChat: ChatViewConfig.opensInChat, signedIn: hasTabMailSession,
                chatAccount: Account.primary(), composeAccount: Account.primary())
            // Without the request's recipients: the log is kept on the device and can be shared.
            BackgroundSyncLogger.logDebug("[ChatThread] Contact pill compose")
        }
        // The queue was rebuilt from the database (every sync start, AI re-enable): what it held
        // for this chat may be gone, so the shown chat checks its rows again.
        .onReceive(NotificationCenter.default.publisher(for: .aiQueueRebuilt).receive(on: DispatchQueue.main)) { _ in
            guard didInitialScroll, isOnScreen else { return }
            askForSummaries()
        }
        .sheet(item: $cardMessage) { msg in
            // Today's detail of that email, from the bottom; swipe down to return.
            NavigationStack {
                MessageDetailView(messageId: msg.id, expectedRfc822MessageId: msg.rfc822MessageId)
            }
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $readyReply, onDismiss: readyCardClosed) { ready in
            let _ = ChatThreadView.logReadyCard(ready)
            // Today's reply compose: the ghost's, Reply All with the AI Suggestion in its box (the
            // full reply of the row the ghost showed, read with it, so the card holds the reply
            // that was tapped), or the paperclip's, with what was picked. It leaves the field
            // alone: the field's words are not what it sends, and a sent reply retires the
            // suggestion through the outbox.
            ready.composeView(openedOn: composeScreen(answering: ready.message)) { outcome in readyCardEnded(outcome) }
        }
        .fullScreenCover(item: $agentCompose) { composeView(for: $0) }
        .fullScreenCover(item: $forwardMessage) { ComposeView(replyTo: $0, isForward: true, openedOn: composeScreen(answering: $0)) }
        .fullScreenCover(item: $newEmailCover) { ChatNewEmailCoverView(cover: $0) }
        .sheet(isPresented: $showsReplyTo) {
            ChatReplyToSheet(
                replyPeople: thread.replyPeople, target: replyTarget,
                ownAddresses: context.ownAddresses) { replyTarget = $0 }
        }
        // The reply field's paperclip: a pick makes the reply's card, which opens once its picker
        // has closed (each picker's `onDismiss`): UIKit refuses the card's cover while the picker
        // is still closing.
        .sheet(isPresented: $showsPhotoPicker, onDismiss: openPendingAttachCard) {
            PhotoLibraryPickerView { providers in attachPicked(.photos(providers)) }
        }
        .sheet(isPresented: $showsFilePicker, onDismiss: openPendingAttachCard) {
            FilePickerView { urls in attachPicked(.files(urls)) }
        }
        .fullScreenCover(isPresented: $showsCamera, onDismiss: openPendingAttachCard) {
            CameraPickerView { image in attachPicked(.camera(image)) }
        }
        #if DEBUG
        // Test seam: a hosted test cannot drive the system pickers, so it hands over a pick here
        // and closes the picker as a picker does: the pick, then its `onDismiss`. Production never
        // posts it.
        .onReceive(NotificationCenter.default.publisher(for: .chatPaperclipPickForTesting)) { note in
            guard let pick = note.object as? ComposeAttachmentPick else { return }
            attachPicked(pick)
            openPendingAttachCard()
        }
        // Test seam: the paperclip's pop-up is a UIKit presentation a hosted test cannot drive, so
        // the test makes the pop-up's choice here and then drives the real picker. Production never
        // posts it.
        .onReceive(NotificationCenter.default.publisher(for: .chatPaperclipOpenForTesting)) { note in
            guard let source = note.object as? ChatNewEmailField.AttachSource else { return }
            attachFromField(source)
        }
        #endif
        .sheet(isPresented: $showsMove) {
            if let opened = viewModel.message {
                MoveFolderPicker(accountId: opened.accountId, currentFolderPath: opened.folderPath) { path in
                    moveChat(toFolderPath: path)
                }
            }
        }
    }

    @ViewBuilder
    private func chatContent(_ thread: ChatThread) -> some View {
        let offersArchive = viewModel.chatHasInboxCopy
        let shown = thread.newest.flatMap { shownSuggestion(on: $0, thread: thread) }
        let suggestion = thread.newest.flatMap { suggestionPhase(on: $0, shown: shown, thread: thread) }
        Group {
            ScrollViewReader { proxy in
                ScrollView {
                    // A plain stack: every row has its real height, so one scroll lands where it
                    // aims. A lazy stack starts rows at guessed heights and moves the target while
                    // they measure (memory 036). Threads are short, and the AI work is bounded by
                    // what the chat asks for, not by what it builds.
                    VStack(spacing: ChatViewLayout.bubbleSpacing) {
                        ForEach(thread.items) { item in
                            // Only the arriving newest email rises (or fades in); no other row,
                            // and nothing of the open's own load.
                            row(item, thread: thread, offersArchive: offersArchive)
                                .transition(ChatArrival.transition(
                                    ChatArrival.style(reduceMotion: reduceMotion),
                                    isArrivalRow: item.id == thread.items.last?.id
                                        && ChatArrival.animates(landed: didInitialScroll, newestIsOwn: item.isOwn)))
                                // Debug UI tests only: where the newest row sits during a field drag.
                                .modifier(ChatFieldDragMarker.Row(isNewest: item.id == thread.items.last?.id))
                        }
                        // Replies still in the outbox. Not while a ghost is held: the reply its
                        // card sent shows as the hold ends, the ghost turning into its bubble.
                        if heldGhost == nil {
                            ForEach(unsentReplies) { reply in
                                ChatUnsentReplyBubble(reply: reply, retry: { reply.retry() }, delete: { reply.delete() }, undo: { reply.undo() })
                                    .matchedGeometryEffect(id: Self.sentMorphId(reply, newest: unsentReplies.last), in: sentMorph)
                            }
                        }
                        // The AI Suggestion, where the reply lands once sent: the working bubble
                        // while it is written, then the ghost; the ghost tapped open stays while
                        // its card is up.
                        if let held = heldGhost {
                            ChatSuggestionBubble(text: held.text) {}
                                .matchedGeometryEffect(id: Self.heldGhostMorphId, in: sentMorph)
                                .transition(.opacity)
                        } else if let newest = thread.newest, let suggestion {
                            if !suggestionGrowPending, case .ready(let text) = suggestion {
                                let move = tutorialMove(thread)
                                // A tap opens the suggestion this ghost shows (`shown`: `.ready` comes only from it).
                                ChatSuggestionBubble(text: text, pulses: move == .tapSuggestion) {
                                    if let shown { openSuggestion(shown, on: newest, tutorialMove: move) }
                                }
                                .transition(.asymmetric(
                                    insertion: ghostFadesIn
                                        ? .opacity.animation(.easeInOut(duration: ChatSuggestionConfig.ghostFadeDuration))
                                        : .opacity,
                                    removal: .opacity))
                            } else {
                                ChatSuggestionWorkingBubble()
                                    .transition(.opacity)
                            }
                        }
                        // The bottom bar's inset keeps the field's room; only the gap is added here.
                        Color.clear.frame(height: ChatViewLayout.pillGap).id(Self.bottomId)
                    }
                    .padding(.top, 8)
                    // A new email rises from behind the field and the rows above move up with it,
                    // its height growing inside the same animation. Not the open's own landing, and
                    // not the user's own sent reply.
                    .animation(ChatArrival.animates(landed: didInitialScroll, newestIsOwn: thread.items.last?.isOwn ?? false)
                               ? ChatArrival.animation(ChatArrival.style(reduceMotion: reduceMotion)) : nil,
                               value: thread.items.last?.id)
                }
                // Only the user's hand ends the landing. A programmatic scroll that animates (a
                // late height arriving inside an animated transaction) or its settling is not the
                // user: the chat stays pinned while the ghost and the field's height arrive.
                .onScrollPhaseChange { old, phase in
                    #if DEBUG
                    NSLog("[cv9diag] real phase %@ -> %@", String(describing: old), String(describing: phase))
                    #endif
                    endLanding(on: phase)
                }
                #if DEBUG
                // Test seam: tests cannot make a hand scroll or a programmatic animation phase on
                // demand, so they post one here. Production never posts it.
                .onReceive(NotificationCenter.default.publisher(for: .chatScrollPhaseForTesting)) { note in
                    NSLog("[cv9diag] seam received object=%@", String(describing: note.object))
                    if let phase = note.object as? ScrollPhase { endLanding(on: phase) }
                }
                #endif
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    let isAbove = Self.distanceBelowVisible(contentHeight: geo.contentSize.height, offsetY: geo.contentOffset.y,
                                                            topInset: geo.contentInsets.top, containerHeight: geo.containerSize.height) > ChatViewLayout.jumpButtonThreshold
                    #if DEBUG
                    if isAbove { NSLog("[cv10diag] jump shows at %@", String(describing: geo)) }
                    #endif
                    return isAbove
                } action: { _, isAbove in
                    withAnimation(.easeInOut(duration: 0.2)) { showsJumpButton = isAbove }
                }
                // While the landing still holds the chat at the bottom, an arrival re-pins it in the
                // same animation as the rise (the landing's re-pin path below), so the new email
                // ends fully above the field and the chat never jumps.
                .onChange(of: thread.items.last?.id) { old, new in
                    guard ChatArrival.isArrival(landed: didInitialScroll, oldNewest: old, newNewest: new,
                                                newestIsOwn: thread.items.last?.isOwn ?? false),
                          let target = scrollTarget else { return }
                    withAnimation(ChatArrival.animation(ChatArrival.style(reduceMotion: reduceMotion))) {
                        proxy.scrollTo(target.id, anchor: target.anchor)
                    }
                }
                .onChange(of: suggestion, initial: true) { old, new in
                    showSuggestion(new, from: old, proxy: proxy)
                }
                .onChange(of: scrollTarget) { _, target in
                    #if DEBUG
                    NSLog("[cv9diag] scrollTarget -> %@", String(describing: target?.id))
                    #endif
                    guard let target else { return }
                    proxy.scrollTo(target.id, anchor: target.anchor)
                }
                // The first scroll can be dropped while the screen is still settling (memory 036),
                // and late content (attachment chips, a summary) changes the heights. The first
                // pass shows the opened email alone, which `defaultScrollAnchor(.bottom)` sits at
                // the bottom with a top inset filling the rest; that fill goes a pass or more after
                // the thread lands, and on that inset change the platform keeps the offset plus the
                // top inset, which moves a bottom landing past the bottom by the fill (memory 036).
                // So the landing is issued again on every size or inset change until the user's
                // scroll (`endLanding`) or a jump-button tap ends it. The field's height and the
                // keyboard arrive as the bottom bar's inset, so the bottom inset counts too.
                .onScrollGeometryChange(for: [CGFloat].self) { geo in
                    [geo.containerSize.height, geo.contentSize.height, geo.contentInsets.top, geo.contentInsets.bottom]
                } action: { old, new in
                    #if DEBUG
                    NSLog("[cv9diag] size %@ -> %@ target=%@", String(describing: old), String(describing: new), String(describing: scrollTarget?.id))
                    #endif
                    guard let target = scrollTarget else { return }
                    proxy.scrollTo(target.id, anchor: target.anchor)
                }
                .overlay(alignment: .bottomTrailing) {
                    if showsJumpButton {
                        jumpButton {
                            // The user's tap ends the landing: its animated scroll is not a hand
                            // scroll, and a held target would pull the chat back on the next height.
                            scrollTarget = nil
                            withAnimation { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                            #if DEBUG
                            NSLog("[cv9diag] jump tapped")
                            NotificationCenter.default.post(name: .chatJumpTappedForTesting, object: nil)
                            #endif
                        }
                    }
                }
                // Swiping left anywhere between the header and the pill slides the whole chat. With
                // no Inbox copy there is no Archive, and no full swipe: the gesture that archives
                // everywhere else never trashes.
                .modifier(ChatSwipeReveal(
                    id: Self.chatSwipeId, edge: .trailing, buttons: chatSwipeButtons(offersArchive: offersArchive),
                    allowsFullSwipe: offersArchive, open: swipeOpen))
                .accessibilityActions {
                    ForEach(chatSwipeButtons(offersArchive: offersArchive)) { button in
                        Button(button.title, action: button.action)
                    }
                }
            }
            // A bar inset, not a plain one: the navigation bar's scroll edge reaches under the
            // subject and the tutorial card, so the chat scrolls under the whole header, never
            // through it (Messages).
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ChatSubjectLine(subject: subject(thread), labels: context.labels, landed: didInitialScroll,
                                    reportContent: { AISummariesNotice.reportContent(items: thread.items, unsent: unsentReplies) })
                    tutorialCard(thread)
                }
                // The open swipe is reachable only below the header.
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(ChatSwipeOpen.space)).maxY } action: {
                    headerBottom = $0
                    swipeOpen.reach(top: $0, bottom: pillTop)
                }
            }
            .overlay {
                if chatExpanded {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            ChatFieldDragMarker.dimTapped()
                            withAnimation(Self.pillSpring) { chatExpanded = false }
                        }
                        .transition(.opacity)
                }
            }
            // The reply field is the chat's bottom bar, as in Messages: the chat scrolls under it
            // and the system blurs the strip below it. One field, always here. The bar is a slot
            // of the collapsed field's height, so the inset, and the chat under the opened panel,
            // do not move.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if thread.newest != nil {
                    Color.clear.frame(height: pillHeight)
                }
            }
            // The field itself is drawn over the slot, on the page, not inside the bar: the bar's
            // UIKit container takes touches only inside its own bounds, so a panel opened upward
            // out of it could be seen but not touched above the slot (its history did not scroll,
            // and taps fell through to the dim behind it). Both sit on the same safe-area bottom.
            .overlay(alignment: .bottom) {
                if let newest = thread.newest {
                    pill(on: newest)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if !chatExpanded, Self.pillHeightMoved(from: pillHeight, to: height) { pillHeight = height }
                        }
                        // ...and above the reply field.
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(ChatSwipeOpen.space)).minY } action: {
                            pillTop = $0
                            swipeOpen.reach(top: headerBottom, bottom: $0)
                        }
                }
            }
        }
        // While a swipe is open, a drag or tap anywhere else on the screen only closes it. The
        // closer's anchor fills the space every swipe frame is measured in.
        .background(ChatSwipeCloser(open: swipeOpen))
        .coordinateSpace(.named(ChatSwipeOpen.space))
    }

    @ViewBuilder
    private func row(_ item: ChatThread.Item, thread: ChatThread, offersArchive: Bool) -> some View {
        if item.showsUnreadLine {
            ChatUnreadLine().id(Self.unreadLineId)
        }
        if item.showsTimeStamp {
            Text(ChatTimeStamp.text(for: item.header.date))
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        ChatBubbleView(
            item: item,
            isGroup: thread.isGroup,
            extras: context.extras[item.id],
            isHighlighted: highlightedId == item.id,
            actions: bubbleSwipeButtons(item, thread: thread) + chatSwipeButtons(offersArchive: offersArchive).map { button in
                ChatSwipeButton(title: "\(button.title) chat", systemImage: button.systemImage, tint: button.tint, action: button.action)
            },
            onOpen: { cardMessage = item.header })
        .modifier(ChatSwipeReveal(
            id: item.id, edge: .leading, buttons: bubbleSwipeButtons(item, thread: thread),
            allowsFullSwipe: false, open: swipeOpen))
        .id(item.id)
        // Shown by one rule for every height (`ChatRowVisibility`), measured against the scroll
        // view, so a row taller than the screen is shown too.
        .onGeometryChange(for: Bool.self) { proxy in
            ChatRowVisibility.isShown(proxy)
        } action: { shown in
            guard shown else { return }
            shownIds.insert(item.id)
            askAsShown(item, in: thread)
        }
    }

    private func subject(_ thread: ChatThread) -> String {
        thread.newest?.subject ?? viewModel.message?.subject ?? ""
    }

    private func jumpButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: ChatViewLayout.jumpButtonSize, height: ChatViewLayout.jumpButtonSize)
                .glassEffect(.regular.interactive(), in: .circle)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing)
        // Above the bottom bar, whose inset the overlay already keeps clear.
        .padding(.bottom, ChatViewLayout.pillGap)
        .transition(.opacity)
        .accessibilityLabel("Jump to the newest email")
    }

    // MARK: - Opening rules

    private struct ScrollTarget: Equatable {
        let id: String
        let anchor: UnitPoint
    }

    /// Whether a scroll phase is the user's own scroll, the only thing that ends the landing's pin.
    static func userTookOver(_ phase: ScrollPhase) -> Bool {
        phase == .tracking || phase == .interacting
    }

    /// How far the chat's end sits below the part of the screen between the top bar and the
    /// field: 0 at the bottom, d once scrolled up by d, below 0 when a short chat leaves room.
    /// The scroll geometry's container height leaves out both bars, while its offset counts from
    /// under the top bar, so the top bar's inset is added back. Without it a tall top bar (the
    /// tutorial's coach card) reads as chat below the screen and the jump button shows at the bottom.
    static func distanceBelowVisible(contentHeight: CGFloat, offsetY: CGFloat, topInset: CGFloat, containerHeight: CGFloat) -> CGFloat {
        contentHeight - (offsetY + topInset + containerHeight)
    }

    /// A scroll phase began: the user's own scroll ends the landing.
    private func endLanding(on phase: ScrollPhase) {
        #if DEBUG
        NSLog("[cv9diag] endLanding phase=%@ target=%@ ends=%d", String(describing: phase), String(describing: scrollTarget?.id), Self.userTookOver(phase) ? 1 : 0)
        #endif
        if Self.userTookOver(phase) { scrollTarget = nil }
    }

    /// Where the open lands (`scrollOnceLoaded`). Held until the user's scroll (`userTookOver`) or a
    /// jump-button tap, so the landing is issued again while the screen settles; then the user owns it.
    @State private var scrollTarget: ScrollTarget?

    /// Reads every other copy the thread loaded of an email the chat shows, the first time it
    /// loads, as the shown copy is read: in another folder or account, it is the same email. Each
    /// by its own row (ADR-IOS-068 D4). Copies place no Unread line and ask for no summary.
    private func noteCopies() {
        for copy in viewModel.threadCopies where seenIds.insert(copy.id).inserted {
            viewModel.markReadIfNeeded(copy)
        }
    }

    /// Records each email the first time it shows, then marks it read. Its unread state at
    /// that moment places the Unread line. An email that joins the open chat (a Sent copy the
    /// provider filed under a Message-ID of its own has no summary from Send) changes the member
    /// ids, which restarts the summary observation (`followSummaries`): its first value asks for the
    /// newest emails, the joining one first. A draft that joins is not one of the chat's emails and
    /// is never asked for.
    private func noteMembers() {
        for member in members where seenIds.insert(member.id).inserted {
            if !member.isRead { unreadAtOpen.insert(member.id) }
            if member.id == viewModel.message?.id {
                // Its own unstructured Task, as in today's detail: a cancelled `.task` must not
                // skip the read flip. Carries the opener's identity check.
                Task { await viewModel.markReadOnOpenIfNeeded() }
            } else {
                viewModel.markReadIfNeeded(member)
            }
        }
    }

    /// The first scroll, once the thread and its extras are in: to the opened email when it came
    /// from search or a notification, else to the Unread line, else the bottom.
    private func scrollOnceLoaded() {
        guard !didInitialScroll, viewModel.hasLoadedThread, context.isLoaded else { return }
        // The thread's emails arrive with `hasLoadedThread`, and SwiftUI runs that change and the
        // members change in either order: record their unread state first, or the Unread line can
        // be missing and the chat opens at the bottom.
        noteMembers()
        didInitialScroll = true
        #if DEBUG
        NSLog("[cv9diag] scrollOnceLoaded landing")
        #endif
        let thread = thread
        if highlightsOpenedMessage, let opened = viewModel.message,
           let item = thread.items.first(where: { ChatThread.copyKey($0.header) == ChatThread.copyKey(opened) }) {
            scrollTarget = ScrollTarget(id: item.id, anchor: .center)
            highlightedId = item.id
            Task {
                try? await Task.sleep(for: ChatViewLayout.highlightDuration)
                highlightedId = nil
            }
        } else if thread.items.contains(where: \.showsUnreadLine) {
            scrollTarget = ScrollTarget(id: Self.unreadLineId, anchor: .top)
        } else {
            scrollTarget = ScrollTarget(id: Self.bottomId, anchor: .bottom)
        }
    }

    // MARK: - Summaries

    /// What the summary observation follows: the chat's emails, once the open has landed, while the
    /// chat is on screen. A change restarts it, and its first value checks every row in scope again.
    private struct SummaryWatch: Equatable {
        let memberIds: [String]
        let landed: Bool
        let onScreen: Bool
    }

    /// While the chat is shown, after the landing, its emails' bodies and summaries are observed in
    /// the database (`ChatSummaryState`). The first value, at the open and each time the chat is
    /// shown again, asks for every row in scope; each later value asks for the rows whose state
    /// changed, so a body that lands by any writer gets its summary asked for at the front. Nothing
    /// is kept for a row that still waits: every ask reads the rows again (`enqueueChatSummaries`).
    private func followSummaries() async {
        guard didInitialScroll, isOnScreen else { return }
        let ids = members.map(\.id)
        var previous: [ChatSummaryState]?
        do {
            for try await states in ChatSummaryState.changes(ids: ids) {
                guard !Task.isCancelled else { return }
                askForSummaries(only: previous.map { ChatSummaryState.changedIds(states, since: $0) })
                previous = states
            }
        } catch {
            BackgroundSyncLogger.logDebug("[Chat] summary observation ended: \(error)")
        }
    }

    /// Asks for the summaries of the rows in scope, newest first: the newest
    /// `ChatViewConfig.summaryWindow` emails and every email shown during this presentation
    /// (`shownIds`). `only`: just these of them. The queue reads each row again and asks only for
    /// what is missing. The chat view setting is read once per request, here and in `askAsShown`.
    private func askForSummaries(only changed: Set<String>? = nil) {
        guard ChatViewConfig.isActive else { return }
        let items = thread.items
        let newest = Set(items.suffix(ChatViewConfig.summaryWindow).map(\.id))
        let scope = items.reversed()
            .filter { (newest.contains($0.id) || shownIds.contains($0.id)) && changed?.contains($0.id) != false }
            .map(\.header)
        guard !scope.isEmpty else { return }
        Task { await ActiveAIQueue.shared.enqueueChatSummaries(scope) }
    }

    /// An email older than the newest `ChatViewConfig.summaryWindow` asks for its own summary when
    /// it comes on screen, so scrolling up summarizes as it goes. That includes an email on screen
    /// as the chat lands: SwiftUI reports a view's visibility only when it changes.
    private func askAsShown(_ item: ChatThread.Item, in thread: ChatThread) {
        let items = thread.items
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              index < items.count - ChatViewConfig.summaryWindow,
              ChatViewConfig.isActive else { return }
        let header = item.header
        Task { await ActiveAIQueue.shared.enqueueChatSummaries([header]) }
    }

    // MARK: - Tutorial (parts 2 and 3)

    /// Whether this chat holds Priya's practice email (part 2) or Jordan's source email (part 3).
    private func holdsTutorialEmail(_ thread: ChatThread) -> (practice: Bool, source: Bool) {
        let ids = Set(thread.items.filter { $0.header.accountId == DemoSeed.demoAccountId }.map(\.header.messageId))
        return (ids.contains(DemoSeed.TutorialFixture.priyaOffsite), ids.contains(DemoSeed.TutorialFixture.jordanFlights))
    }

    /// The step's coach card under the header, in the chat the step is about.
    @ViewBuilder
    private func tutorialCard(_ thread: ChatThread) -> some View {
        let tutorial = TutorialCoordinator.shared
        let holds = holdsTutorialEmail(thread)
        if tutorial.isRunning,
           TutorialCoordinator.chatShowsCard(
            step: tutorial.step, teachesChat: tutorial.teachesChat,
            holdsPracticeEmail: holds.practice, holdsSourceEmail: holds.source) {
            TutorialCoachView(host: .chat, onAction: { action in
                // Next goes on in the inbox: part 3 starts there, and so does what else to ask.
                if action == .nextLesson || action == .showMoreToAsk { dismiss() }
            })
            .padding(.vertical, 8)
        }
    }

    // MARK: - Swipes

    /// Left swipe: Trash (the inbox row's word for a move to Trash), then Archive at the edge, so a
    /// full swipe archives; the whole chat. Archive takes the chat's Inbox copies, so a chat with
    /// none (opened from a label, Archive or search) offers Trash only.
    private func chatSwipeButtons(offersArchive: Bool) -> [ChatSwipeButton] {
        var buttons = [ChatSwipeButton(title: "Trash", systemImage: "trash", tint: .red) { deleteChat() }]
        if offersArchive {
            buttons.append(ChatSwipeButton(title: "Archive", systemImage: "archivebox", tint: Theme.archive) { archiveChat() })
        }
        return buttons
    }

    /// Right swipe: Unread from here (or Read up to here) for this email, Move for the whole chat.
    private func bubbleSwipeButtons(_ item: ChatThread.Item, thread: ChatThread) -> [ChatSwipeButton] {
        let action = ChatSwipe.ReadAction(for: item.header)
        return [
            ChatSwipeButton(title: action.title, systemImage: action.systemImage, tint: Theme.accent) {
                setRead(action, at: item, thread: thread)
            },
            ChatSwipeButton(title: "Move", systemImage: "folder", tint: Palette.untagged) {
                guard TutorialCoordinator.shared.admits(.other) else { return }
                showsMove = true
            },
        ]
    }

    private func setRead(_ action: ChatSwipe.ReadAction, at item: ChatThread.Item, thread: ChatThread) {
        guard TutorialCoordinator.shared.admits(.other) else { return }
        let targets = ChatSwipe.readTargets(action, at: item.id, in: thread.items)
        viewModel.setRead(targets, isRead: action.isRead)
        // The Unread line moves to where unread now starts.
        unreadAtOpen = ChatSwipe.unreadIds(after: action, targets: targets, items: thread.items)
    }

    private func archiveChat() {
        guard TutorialCoordinator.shared.admits(.other) else { return }
        let moved = viewModel.archiveChat(viewModel.chatRows)
        if !moved.isEmpty { dismissChat(moved: moved, destinationFolderId: nil) }
    }

    private func deleteChat() {
        guard TutorialCoordinator.shared.admits(.other) else { return }
        let moved = viewModel.deleteChat(viewModel.chatRows)
        if !moved.isEmpty { dismissChat(moved: moved, destinationFolderId: nil) }
    }

    private func moveChat(toFolderPath path: String) {
        guard let opened = viewModel.message else { return }
        let moved = viewModel.moveChat(viewModel.chatRows, toFolderPath: path)
        if !moved.isEmpty {
            // A chosen folder can be one the list behind renders (Archive to Inbox).
            dismissChat(moved: moved, destinationFolderId: MessageIdentity.folderId(accountId: opened.accountId, folderPath: path))
        }
    }

    /// As `MessageDetailView.dismissMessage`: the list behind hides the opened row if it moved, then
    /// the chat closes. A chat opened on a label whose Inbox copies were archived leaves its row in
    /// that label's list, which has no way to show a hidden row again.
    private func dismissChat(moved: Set<String>, destinationFolderId: String?) {
        if moved.contains(viewModel.messageId) {
            NotificationCenter.default.post(
                name: .messageDismissedFromDetail,
                object: viewModel.messageId,
                userInfo: destinationFolderId.map { [MessageDetailView.dismissDestinationFolderIdKey: $0] })
        }
        dismiss()
    }

    // MARK: - Reply field

    /// The reply field's container, as tests find it.
    static let replyPillId = "chatReplyPill"

    /// The toolbar's Forward, as tests find it.
    static let forwardId = "chatForward"

    /// The held ghost's id in `sentMorph`. The newest outbox bubble takes it too, so the ghost turns
    /// into the reply its card sent as the hold ends.
    static let heldGhostMorphId = "chat-held-ghost"

    /// An outbox bubble's id in `sentMorph`: the newest one's is the held ghost's.
    static func sentMorphId(_ reply: ChatUnsentReply, newest: ChatUnsentReply?) -> String {
        reply.id == newest?.id ? heldGhostMorphId : "chat-unsent-\(reply.id)"
    }

    /// The AI Suggestion's row, from `suggestionPhase`. The working bubble filling in grows the row
    /// into the ghost over `ChatSuggestionConfig.fillDuration`, and while the landing holds its
    /// target the re-pin scroll runs in the same transaction, so the growing row stays above the
    /// field. Under Reduce Motion the ghost replaces it at once and fades in (`ghostFadesIn`).
    /// Every other change, opening on a ready suggestion included, shows or removes at once.
    private func showSuggestion(_ new: ChatSuggestionPhase?, from old: ChatSuggestionPhase?, proxy: ScrollViewProxy) {
        guard ChatSuggestionPhase.fills(from: old, to: new) else {
            suggestionGrowPending = new == .writing
            ghostFadesIn = false
            return
        }
        #if DEBUG
        NSLog("[cvwb] working bubble fills, re-pin=%d reduceMotion=%d", scrollTarget != nil ? 1 : 0, reduceMotion ? 1 : 0)
        #endif
        ghostFadesIn = reduceMotion
        // An arriving email in a landed chat is not a fill: the ghost's swap back to the working
        // bubble cross-fades inside the arrival's rise (at once under Reduce Motion), and this function only sets its flags
        // (`suggestionGrowPending`, `ghostFadesIn`) in the guard above. The two re-pins fire on different triggers (the newest email's id
        // for the arrival, Writing to ready here), so they stay separate.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: ChatSuggestionConfig.fillDuration)) {
            suggestionGrowPending = false
            if let target = scrollTarget { proxy.scrollTo(target.id, anchor: target.anchor) }
        }
    }

    /// The ready AI Suggestion on the newest email, as one value (`ChatReplyField.shown`). None on the user's turn (their email is
    /// the newest, or a reply of theirs is still in the outbox below it), and none while the reply
    /// goes only to people chosen in Reply to: the suggestion was written for everyone, and the
    /// field has the agent write one for the people chosen. None until the thread and its accounts
    /// have loaded (the newest email and the Reply All audience, without the user's own address,
    /// are known only then), and none while the agent works on a request from the field (it may
    /// open its own compose card), or while a compose card is open: one that became ready meanwhile
    /// shows when the card closes without sending.
    private func shownSuggestion(on newest: MessageHeader, thread: ChatThread) -> ReplyResult? {
        // `isLoaded` is also set when the context read failed: the email's own account, read,
        // is the proof the audience can leave the user out.
        guard viewModel.hasLoadedThread, context.isLoaded,
              context.accounts.contains(where: { $0.id == newest.accountId }) else { return nil }
        let usersTurn = (thread.items.last?.isOwn ?? false) || !unsentReplies.isEmpty
        let cardOpen = readyReply != nil || agentCompose != nil || forwardMessage != nil
        return ChatReplyField.shown(
            newest: newest, usersTurn: usersTurn, onlyTo: replyTarget.only,
            writing: chatWorking, cardOpen: cardOpen)
    }

    /// The AI Suggestion's row on the newest email: the ghost of the suggestion the chat shows
    /// (`shown`, from `shownSuggestion`), else the working bubble while the AI writes it
    /// (`ChatReplyField.suggestionPhase`, the inbox row's rule). No working bubble on the user's
    /// turn, while the reply goes only to people chosen in Reply to, before the thread and its
    /// accounts have loaded, or while the agent works on a request from the field.
    private func suggestionPhase(on newest: MessageHeader, shown: ReplyResult?, thread: ChatThread) -> ChatSuggestionPhase? {
        if let text = shown?.textMessage { return .ready(text) }
        // `isLoaded` is also set when the context read failed: the email's own account, read,
        // is the proof the audience can leave the user out.
        guard viewModel.hasLoadedThread, context.isLoaded, !chatWorking,
              context.accounts.contains(where: { $0.id == newest.accountId }) else { return nil }
        let usersTurn = (thread.items.last?.isOwn ?? false) || !unsentReplies.isEmpty
        let subscribed = AISubscriptionGate.shared.isActive
        let aiSourceEnabled = AIWorkingRule.anyAISourceEnabled(
            demoHidesAI: DemoModeStore.shared.hidesAIContent, optedOutAllAI: optOutAllAI,
            deviceSyncAuto: DeviceSyncService.shared.isAutoEnabled, subscribed: subscribed)
        return ChatReplyField.suggestionPhase(newest: newest, usersTurn: usersTurn, onlyTo: replyTarget.only,
                                              aiSourceEnabled: aiSourceEnabled, subscribed: subscribed)
    }

    /// The tutorial's move in this chat, if it holds the practice email.
    private func tutorialMove(_ thread: ChatThread) -> TutorialCoordinator.FieldMove? {
        TutorialCoordinator.shared.fieldMove(inPracticeChat: holdsTutorialEmail(thread).practice)
    }

    /// Debug-gated: each build of the ready card's content, with the draft it names.
    static func logReadyCard(_ ready: ChatReadyReply) {
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[Chat] ready card built draftId=\(ready.draftId) suggestionLen=\(ready.suggestion?.body.count ?? -1) picked=\(ready.pick != nil)")
        }
    }

    /// A tap on the AI Suggestion: the Reply All compose card with it written out (the suggestion
    /// shows only while the reply goes to everyone). In the tutorial only the step that asks for it
    /// opens the card.
    private func openSuggestion(_ shown: ReplyResult, on newest: MessageHeader, tutorialMove: TutorialCoordinator.FieldMove?) {
        if TutorialCoordinator.shared.isRunning, tutorialMove != .tapSuggestion {
            _ = TutorialCoordinator.shared.admits(.other)
            return
        }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[Chat] openSuggestion message=\(newest.id) alreadyOpen=\(readyReply != nil)")
        }
        readyReply = ChatReadyReply(message: newest, suggestion: shown, accounts: context.accounts)
        // The ghost stays where it is while its card is up.
        heldGhost = shown.textMessage.map {
            ChatHeldGhost(text: $0, showsBubble: composeScreen(answering: newest) == .chat)
        }
    }

    private func pill(on newest: MessageHeader) -> some View {
        let isOwn = thread.items.last?.isOwn ?? false
        let isNoReply = !isOwn && EmailFilter.isNoReply(newest.fromAddress)
        let shown = shownSuggestion(on: newest, thread: thread)
        // The paperclip's card goes to the reply's people, so the paperclip shows only once the chat
        // can tell the user's own addresses from theirs: the thread loaded and the email's own
        // account read (`isLoaded` alone is also set when the context read failed).
        let knowsAudience = viewModel.hasLoadedThread && context.isLoaded
            && context.accounts.contains(where: { $0.id == newest.accountId })
        return VStack(spacing: 8) {
            if let only = replyTarget.only, !chatExpanded {
                replyingOnlyTo(only)
            }
            if isNoReply && !chatExpanded {
                // The field stays usable (the agent declines to write a reply).
                Text("This is a no-reply email. Replies won't be read.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
            }
            if let fieldStatus {
                ChatFieldStatusLine(text: fieldStatus)
                    .transition(.opacity)
            }
            DynamicIslandChat(
                message: newest,
                isExpanded: $chatExpanded,
                isInputFocused: $chatInputFocused,
                isWorking: $chatWorking,
                onAgentReply: { _ in agentAnswered() },
                replyField: ChatReplyField(
                    example: ChatReplyField.example(shown: shown, configured: example),
                    isNoReply: isNoReply,
                    onlyTo: replyTarget.only,
                    tutorialMove: tutorialMove(thread),
                    drag: fieldDrag,
                    // The drag's VoiceOver equivalent (decision 12: every chat swipe has a named
                    // action), on the text field VoiceOver focuses; not over the panel or the tutorial.
                    showChat: chatExpanded || TutorialCoordinator.shared.isRunning
                        ? nil : { withAnimation(Self.pillSpring) { chatExpanded = true } },
                    suggestion: shown,
                    // A closure, as `showChat`'s: the method itself is MainActor-isolated.
                    attach: knowsAudience ? { attachFromField($0) } : nil),
                onFieldSend: { _ in fieldComposeOpened = false },
                onAgentCompose: openAgentCompose,
                composeFromAccountId: viewModel.message?.accountId,
                composeHostCovered: isAnyPresentation)
            // The agent's status on a Send shows above the field (`ChatFieldStatusLine`); the stack
            // grows by it, so the bar and the chat above move up with the pill's spring.
            .onPreferenceChange(ChatFieldStatusKey.self) { status in
                withAnimation(Self.pillSpring) { fieldStatus = status }
            }
            // Debug UI tests only: the glass's top, swell included (`ChatFieldDragMarker`).
            .modifier(ChatFieldDragMarker.Glass())
            // The swell is not the field's room: its glass grows upward, and the same swell is taken
            // back out of the layout here, springing back in the same transaction, so the field's
            // measured height, the bar, its inset and the chat never move under a drag.
            .modifier(ChatFieldDrag.Swell(model: fieldDrag, sign: -1))
            // Drag the field up: it swells under the finger and opens the TabMail chat panel. A
            // UIKit pan, so once it starts the field's text view loses the touch and a drag never
            // focuses the field (`ChatFieldPan`). Not in the tutorial, whose steps open the chat
            // themselves.
            .gesture(ChatFieldPan(isEnabled: !chatExpanded && !TutorialCoordinator.shared.isRunning,
                                  cut: fieldPanCut, moved: fieldDragMoved, ended: fieldDragEnded))
            .modifier(ChatFieldDrag.Watch(model: fieldDrag) { fieldDragChanged($0) })
            // Debug UI tests only: what the drag did to the chat (`ChatFieldDragMarker`).
            .modifier(ChatFieldDragMarker.Field(model: fieldDrag))
            // A tap on the field (it takes focus) or the panel opening ends the tip. The panel
            // opening under a held drag (an agent answer, a notification) also cuts that drag off.
            .onChange(of: chatInputFocused) { _, focused in if focused { ChatFieldDragTip.close() } }
            .onChange(of: chatExpanded) { _, expanded in if expanded { ChatFieldDragTip.close(); fieldPanCut() } }
            // One container, so its frame is the field's own (ChatThreadLayoutTests).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(Self.replyPillId)
        }
        // Once, above the field and its notices: what the drag up shows. An inline tip in an overlay
        // on the whole stack, outside the field's frame and its accessibility container: it pushes
        // no layout and takes no touch from the field, "Replying only to" or the no-reply notice, so
        // the first tap focuses the field and the first drag opens the panel. Not over the tutorial
        // or the panel.
        // The tip hangs by its bottom from a zero-height anchor on the stack's top edge, so it
        // grows upward from there whatever its height. A custom top alignment guide on the TipView
        // itself did not take: the tip was drawn from the stack's top down, over the field.
        // It shows only while the whole card fits between the header and the stack
        // (`tipRoom`): at the largest text size, in landscape, or over a tall draft it would run
        // off the screen. `ViewThatFits` measures the card without showing it, so a card that
        // does not fit is not shown and keeps its one showing for when it does.
        .overlay(alignment: .top) {
            if !chatExpanded && !TutorialCoordinator.shared.isRunning {
                Color.clear
                    .frame(height: 0)
                    .overlay(alignment: .bottom) {
                        ViewThatFits(in: .vertical) {
                            TipView(ChatFieldDragTip(), arrowEdge: .bottom)
                                .fixedSize(horizontal: false, vertical: true)
                                // Debug UI tests only: where the whole card is (`ChatFieldDragMarker`).
                                .modifier(ChatFieldDragMarker.TipCard(roomTop: headerBottom, roomBottom: pillTop))
                            Color.clear.frame(height: 0)
                                // Debug UI tests only: the tip waits for room (`ChatFieldDragMarker`).
                                .modifier(ChatFieldDragMarker.TipWait())
                        }
                        // VoiceOver can still reach a card waiting for room (tabmail-ios#1255).
                        .frame(height: tipRoom, alignment: .bottom)
                    }
            }
        }
        .padding(.horizontal, chatExpanded ? 0 : ChatViewLayout.fieldSideInset)
        .padding(.bottom, ChatViewLayout.fieldBottomGap)
        .animation(Self.pillSpring, value: chatExpanded)
    }

    /// Whether the collapsed field's measured height moved from `old` to `new`: by at least
    /// `ChatViewLayout.fieldHeightTolerance`. A drag's swell is added inside the field's glass and
    /// taken back out here, which floating point does not always cancel exactly; that remainder
    /// once set the bar's height under a held drag, ran the chat's body and built the reply field
    /// again, and UIKit then scrolled the field's text to its caret (UI run 2026-11-22). The swell
    /// never moves the field's height (`pill(on:)`), so a remainder that small is the same height.
    static func pillHeightMoved(from old: CGFloat, to new: CGFloat) -> Bool {
        abs(new - old) >= ChatViewLayout.fieldHeightTolerance
    }

    /// The room above the field stack for its tip: from the header's bottom to the stack's top,
    /// both measured in the chat's space; none until both are measured.
    private var tipRoom: CGFloat {
        let room = pillTop - headerBottom
        return room.isFinite ? max(0, room) : 0
    }

    /// The drag up on the collapsed field moved (`ChatFieldPan`): the field swells under the finger.
    private func fieldDragMoved(_ drag: ChatHorizontalPan.Sample) {
        fieldDrag.progress = ChatFieldDrag.progress(translation: drag.travel)
    }

    /// The drag up on the collapsed field let go, or was cancelled (`ChatFieldPan`): the swell
    /// springs back with the pill's spring however it ended, and a finished drag whose swell, or a
    /// flick's predicted swell, reaches the open distance opens the panel in the same transaction.
    private func fieldDragEnded(_ drag: ChatHorizontalPan.Sample, finished: Bool) {
        // Debug UI tests only: a let-go or a cut-off (`ChatFieldDragMarker`).
        ChatFieldDragMarker.dragEnded(finished: finished)
        let opens = finished && ChatFieldDrag.opens(letGo: drag)
        withAnimation(Self.pillSpring) {
            fieldDrag.progress = ChatFieldDrag.Progress()
            if opens { chatExpanded = true }
        }
    }

    /// A drag on the field began or ended (finished or cancelled). It holds the interaction freeze
    /// under its own id from its start and ends the tip once; after its let-go the freeze holds
    /// while the swell settles (`fieldDragSettle`) and then the freeze rule's cooldown
    /// (`freezeCooldown`). A newer drag's `begin` cancels an older settle; the chat going away
    /// releases it (`onDisappear`).
    private func fieldDragChanged(_ dragging: Bool) {
        if dragging {
            ChatSwipeHold.shared.begin(Self.fieldDragHoldId)
            ChatFieldDragTip.close()
            return
        }
        ChatSwipeHold.shared.release(Self.fieldDragHoldId, after: Self.fieldDragSettle + ChatViewLayout.freezeCooldown)
    }

    /// The gray line above the field when the reply is not a Reply All; tap for everyone.
    private func replyingOnlyTo(_ people: [ChatThread.Person]) -> some View {
        let chips = ChatReplyTarget.chips(people)
        return Button { showsOnlyList = true } label: {
            HStack(spacing: 6) {
                Text("Replying only to")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                ForEach(Array(chips.names.enumerated()), id: \.offset) { _, name in
                    chip(name)
                }
                if chips.more > 0 { chip("+\(chips.more)") }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Replying only to \(people.map(\.name).joined(separator: ", "))")
        .popover(isPresented: $showsOnlyList) {
            ChatPeopleList(title: "Replying only to", names: people.map(\.name))
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.boxBg))
            .overlay(Capsule().stroke(Palette.separator, lineWidth: 0.5))
    }

    /// A compose card this chat's agent asked for, taken by this chat's pill (ADR-IOS-053 Phase 2),
    /// never one another screen asked for. The reply the reply field asked for
    /// (`ComposeRequest.isFieldsOwnReply`, any copy of its email, in any account): the agent's
    /// closing words open nothing. Who the card goes to travels with the request (`fieldReply`);
    /// this chat's own state decides nothing.
    private func openAgentCompose(_ req: AgentToolRouter.ComposeRequest) {
        // A new email opens from the account bound when its turn started, looked up in the app's
        // accounts as the card is taken; when it is not there the request ends and nothing opens.
        guard AgentToolRouter.shared.canOpen(req, accounts: navigationStore.accounts) else { return }
        fieldComposeOpened = req.isFieldsOwnReply
        agentCompose = req
    }

    /// The agent finished a request from the field with something to say: the sheet rises with
    /// the request and the answer. After a compose card the reply was the point, so nothing opens.
    /// The field's words are the request's to complete, on its own chat key (`ChatFieldWords`,
    /// `.answered`), not this view's.
    private func agentAnswered() {
        guard !fieldComposeOpened else { return }
        withAnimation(Self.pillSpring) { chatExpanded = true }
    }

    /// A choice in the reply field's paperclip (ADR-IOS-114 decision 10): the picker it names. The
    /// tutorial's mail actions are off.
    private func attachFromField(_ source: ChatNewEmailField.AttachSource) {
        guard TutorialCoordinator.shared.admits(.other) else { return }
        paperclipPickerOpen = true
        switch source {
        case .photos: showsPhotoPicker = true
        case .camera: showsCamera = true
        case .files: showsFilePicker = true
        }
    }

    /// Something picked with the paperclip: the reply's compose card with it, read as the pick
    /// lands, as a send from the field is: on the newest email, to whom the field's reply goes, with
    /// the suggestion the chat shows (`ChatReadyReply(attaching:)`). It opens once the picker has
    /// closed (`openPendingAttachCard`), at once if it already has.
    private func attachPicked(_ pick: ComposeAttachmentPick) {
        guard let newest = thread.newest else { return }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[Chat] paperclip pick message=\(newest.id) onlyTo=\(replyTarget.only?.count ?? -1)")
        }
        pendingAttachCard = ChatReadyReply(
            attaching: pick, to: newest, onlyTo: replyTarget.only,
            shown: shownSuggestion(on: newest, thread: thread), accounts: context.accounts)
        if !paperclipPickerOpen { openPendingAttachCard() }
    }

    /// The paperclip's picker has closed: the card its pick made, if any, opens now.
    private func openPendingAttachCard() {
        paperclipPickerOpen = false
        guard let card = pendingAttachCard else { return }
        pendingAttachCard = nil
        readyReply = card
    }

    /// The ghost's or the paperclip's card closed. Its words were never the field's, so the field
    /// stays as it is; a reply sent clears "Replying only to", so the next one is a Reply All again.
    private func readyCardEnded(_ outcome: ComposeOutcome) {
        guard case .sent = outcome else { return }
        heldGhost?.sent = true
        replyTarget = .replyAll
    }

    /// The ghost's or the paperclip's card has finished closing: a held ghost goes now, or once
    /// the reply its card sent shows (`ChatHeldGhost.ends`).
    private func readyCardClosed() {
        heldGhost?.cardClosed = true
        endHeldGhostIfDone()
    }

    /// The chat shows a reply of the user's below the newest email: an outbox bubble, or the sent
    /// email itself.
    private var sentReplyShows: Bool {
        !unsentReplies.isEmpty || (thread.items.last?.isOwn ?? false)
    }

    /// Ends the held ghost once its hold is over. After a send its bubble shows: the ghost turns
    /// into it (at once under Reduce Motion). Otherwise the live ghost is back in its place, the
    /// same words, so the swap is at once.
    private func endHeldGhostIfDone() {
        guard let held = heldGhost, held.ends(replyShows: sentReplyShows) else { return }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[Chat] held ghost ends sent=\(held.sent) showsBubble=\(held.showsBubble) morphs=\(held.morphs)")
        }
        let morph = Animation.spring(
            response: ChatSuggestionConfig.sentMorphResponse, dampingFraction: ChatSuggestionConfig.sentMorphDamping)
        withAnimation(held.morphs && !reduceMotion ? morph : nil) {
            heldGhost = nil
        }
    }

    /// A compose card from the chat closed. Sent: a reply shows as its queued email's bubble, read
    /// from the outbox. The field's words are emptied by the request that opened the card, on its
    /// own chat key (`AgentToolRouter.enqueueComposeAndAwaitOutcome`).
    private func composeEnded(_ outcome: ComposeOutcome, replyTo: MessageHeader?) {
        guard case .sent = outcome else { return }
        // A reply sent clears "Replying only to"; the next one is a Reply All again.
        if replyTo != nil { replyTarget = .replyAll }
    }

    /// A new email opens from the account bound when its turn started (`ComposeRequest.fromAccountId`),
    /// read from the same accounts `openAgentCompose` checked, never whichever email this chat shows.
    private func composeView(for req: AgentToolRouter.ComposeRequest) -> some View {
        req.composeView(account: navigationStore.accounts.first { $0.id == req.fromAccountId },
                        openedOn: composeScreen(answering: req.replyTo)) { outcome in
            req.onOutcome(outcome)
            composeEnded(outcome, replyTo: req.mode == .reply ? req.replyTo : nil)
        }
    }

    /// The screen this chat records for a compose it opens (`ComposeView.openedOn`).
    private func composeScreen(answering target: MessageHeader?) -> ComposeScreen? {
        Self.composeScreen(answering: target, chatMessageIds: messageIds)
    }

    /// The screen a chat records for a compose it opens, as the compose opens: the chat
    /// (`ComposeScreen.chat`) only when it shows that compose's send as its bubble, a reply to or a
    /// forward of one of its own emails. It is decided on the In-Reply-To the send's outbox row will
    /// carry (`ThreadUtils.outgoingInReplyTo`), by the rule the chat finds its bubbles with
    /// (`ChatUnsentReply.answers`), so an email whose Message-ID the send cannot carry as the chat
    /// matches it (blank, or written with spaces inside its brackets) keeps the toast.
    /// Any other records none, and its send keeps the toast: a new email, and an agent's card for an
    /// email of another thread (its tools can name any email), whose send shows only in that
    /// thread's chat. `chatMessageIds`: the normalized Message-IDs of the chat's emails.
    nonisolated static func composeScreen(answering target: MessageHeader?, chatMessageIds: Set<String>) -> ComposeScreen? {
        let inReplyTo = ThreadUtils.outgoingInReplyTo(parentRfc822MessageId: target?.rfc822MessageId)
        return ChatUnsentReply.answers(inReplyTo, in: chatMessageIds) ? .chat : nil
    }
}

/// When a chat row counts as shown: its visible part is at least `ChatViewLayout.shownShareOfRow`
/// of the row, or at least `ChatViewLayout.shownShareOfViewport` of the chat's visible height. One
/// rule for every row height: a short row needs half of itself, and a row taller than twice the
/// screen, which can never show half of itself, counts once it fills half the screen.
enum ChatRowVisibility {
    static func isShown(visibleHeight: CGFloat, rowHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard visibleHeight > 0 else { return false }
        return visibleHeight >= rowHeight * ChatViewLayout.shownShareOfRow
            || visibleHeight >= viewportHeight * ChatViewLayout.shownShareOfViewport
    }

    /// The row's visible part, read against the enclosing scroll view's bounds.
    static func isShown(_ proxy: GeometryProxy) -> Bool {
        guard let viewport = proxy.bounds(of: .scrollView) else { return false }
        let visible = viewport.intersection(CGRect(origin: .zero, size: proxy.size))
        return isShown(visibleHeight: visible.isNull ? 0 : visible.height,
                       rowHeight: proxy.size.height, viewportHeight: viewport.height)
    }
}
