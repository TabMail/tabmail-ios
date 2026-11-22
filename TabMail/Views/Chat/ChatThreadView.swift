/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import GRDB
import SwiftUI

#if DEBUG
extension Notification.Name {
    /// Test seam only: a scroll phase delivered to the open chat as if its scroll view reported it.
    static let chatScrollPhaseForTesting = Notification.Name("chatScrollPhaseForTesting")
    /// Test fixture only: the jump button was tapped (its animated scroll starts now).
    static let chatJumpTappedForTesting = Notification.Name("chatJumpTappedForTesting")
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
    /// The collapsed pill's height, notices and chips included: the room the thread keeps under its
    /// last bubble and the jump button. The field grows to six lines, so it is measured;
    /// the open sheet keeps the last collapsed height, so the thread does not move under it.
    @State private var pillHeight = ChatViewLayout.pillStartHeight
    @State private var chatInputFocused = false
    @State private var chatWorking = false
    /// The ready AI Suggestion's compose card: the email it answers, and how it opens.
    @State private var readyReply: ChatReadyReply?
    /// The field's "e.g." example, picked once as the chat opens.
    @State private var example = ChatSuggestionConfig.randomExample()
    @State private var agentCompose: ChatAgentCard?
    /// A compose card opened for the field's last request, so the agent's closing words open
    /// no sheet.
    @State private var fieldComposeOpened = false
    /// Bumps to empty the field.
    @State private var fieldClearCount = 0
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    private static let pillSpring = Animation.spring(response: 0.45, dampingFraction: 0.82)

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
            || forwardMessage != nil || showsReplyTo || showsMove
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
        // The queue was rebuilt from the database (every sync start, AI re-enable): what it held
        // for this chat may be gone, so the shown chat checks its rows again.
        .onReceive(NotificationCenter.default.publisher(for: .aiQueueRebuilt).receive(on: DispatchQueue.main)) { _ in
            guard didInitialScroll, isOnScreen else { return }
            askForSummaries()
        }
        .onChange(of: AgentToolRouter.shared.pendingCompose?.id) { _, newId in
            guard newId != nil, let req = AgentToolRouter.shared.pendingCompose else { return }
            // Asked for in a reply field: the agent's closing words open nothing. Who the card goes
            // to travels with the request (`fieldReply`); this chat's own state decides nothing.
            fieldComposeOpened = req.fieldReply != nil
            agentCompose = ChatAgentCard(request: req, reply: ChatReplyCompose.make(agent: req, accounts: context.accounts))
            AgentToolRouter.shared.pendingCompose = nil
        }
        .sheet(item: $cardMessage) { msg in
            // Today's detail of that email, from the bottom; swipe down to return.
            NavigationStack {
                MessageDetailView(messageId: msg.id, expectedRfc822MessageId: msg.rfc822MessageId)
            }
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $readyReply) { ready in
            let _ = ChatThreadView.logReadyCard(ready)
            // Today's Reply All compose, with the AI Suggestion in its box: the full reply of the
            // row the ghost showed, read with it, so the card holds the reply that was tapped. It
            // leaves the field alone: the field's words are not what it sends, and a sent reply retires the
            // suggestion through the outbox.
            ready.compose.composeView(
                replyTo: ready.message, suggestedBody: ready.message.cachedReply, draftId: ready.draftId,
                openedOn: composeScreen(answering: ready.message), onAgentOutcome: { _ in })
        }
        .fullScreenCover(item: $agentCompose) { composeView(for: $0) }
        .fullScreenCover(item: $forwardMessage) { ComposeView(replyTo: $0, isForward: true, openedOn: composeScreen(answering: $0)) }
        .sheet(isPresented: $showsReplyTo) {
            ChatReplyToSheet(
                replyPeople: thread.replyPeople, target: replyTarget,
                ownAddresses: context.ownAddresses) { replyTarget = $0 }
        }
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
        let suggestion = thread.newest.flatMap { suggestionPhase(on: $0, thread: thread) }
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    // A plain stack: every row has its real height, so one scroll lands where it
                    // aims. A lazy stack starts rows at guessed heights and moves the target while
                    // they measure (memory 036). Threads are short, and the AI work is bounded by
                    // what the chat asks for, not by what it builds.
                    VStack(spacing: ChatViewLayout.bubbleSpacing) {
                        ForEach(thread.items) { item in
                            row(item, thread: thread, offersArchive: offersArchive)
                        }
                        // Replies still in the outbox.
                        ForEach(unsentReplies) { reply in
                            ChatUnsentReplyBubble(reply: reply, retry: { reply.retry() }, delete: { reply.delete() }, undo: { reply.undo() })
                        }
                        // The AI Suggestion, where the reply lands once sent: the working bubble
                        // while it is written, then the ghost.
                        if let newest = thread.newest, let suggestion {
                            if !suggestionGrowPending, case .ready(let text) = suggestion {
                                let move = tutorialMove(thread)
                                ChatSuggestionBubble(text: text, pulses: move == .tapSuggestion) {
                                    openSuggestion(on: newest, tutorialMove: move)
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
                        Color.clear.frame(height: pillHeight + ChatViewLayout.pillGap).id(Self.bottomId)
                    }
                    .padding(.top, 8)
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
                    geo.contentSize.height - (geo.contentOffset.y + geo.containerSize.height) > ChatViewLayout.jumpButtonThreshold
                } action: { _, isAbove in
                    withAnimation(.easeInOut(duration: 0.2)) { showsJumpButton = isAbove }
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
                // scroll (`endLanding`) or a jump-button tap ends it.
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
                        .onTapGesture { withAnimation(Self.pillSpring) { chatExpanded = false } }
                        .transition(.opacity)
                }
            }

            if let newest = thread.newest {
                pill(on: newest)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if !chatExpanded { pillHeight = height }
                    }
                    // ...and above the reply field.
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(ChatSwipeOpen.space)).minY } action: {
                        pillTop = $0
                        swipeOpen.reach(top: headerBottom, bottom: $0)
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
        .padding(.bottom, pillHeight + ChatViewLayout.pillGap)
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
        // At rebase onto the reply field's arrival change (its own re-pin inside `withAnimation`
        // for an arriving email), fold both re-pins into one helper and re-check this fill.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: ChatSuggestionConfig.fillDuration)) {
            suggestionGrowPending = false
            if let target = scrollTarget { proxy.scrollTo(target.id, anchor: target.anchor) }
        }
    }

    /// The AI Suggestion's row on the newest email (`ChatReplyField.suggestionPhase`). None on the user's turn (their email is
    /// the newest, or a reply of theirs is still in the outbox below it), and none while the reply
    /// goes only to people chosen in Reply to: the suggestion was written for everyone, and the
    /// field has the agent write one for the people chosen. None until the thread and its accounts
    /// have loaded (the newest email and the Reply All audience, without the user's own address,
    /// are known only then), and none while the agent works on a request from the field (it may
    /// open its own compose card).
    private func suggestionPhase(on newest: MessageHeader, thread: ChatThread) -> ChatSuggestionPhase? {
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
            BackgroundSyncLogger.logDebug("[Chat] ready card built draftId=\(ready.draftId) cachedReplyLen=\(ready.message.cachedReply?.count ?? -1)")
        }
    }

    /// A tap on the AI Suggestion: the Reply All compose card with it written out (the suggestion
    /// shows only while the reply goes to everyone). In the tutorial only the step that asks for it
    /// opens the card.
    private func openSuggestion(on newest: MessageHeader, tutorialMove: TutorialCoordinator.FieldMove?) {
        if TutorialCoordinator.shared.isRunning, tutorialMove != .tapSuggestion {
            _ = TutorialCoordinator.shared.admits(.other)
            return
        }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[Chat] openSuggestion message=\(newest.id) alreadyOpen=\(readyReply != nil)")
        }
        readyReply = ChatReadyReply(message: newest, compose: ChatReplyCompose.make(
            replyAllTo: newest, accounts: context.accounts))
    }

    private func pill(on newest: MessageHeader) -> some View {
        let isOwn = thread.items.last?.isOwn ?? false
        let isNoReply = !isOwn && EmailFilter.isNoReply(newest.fromAddress)
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
            DynamicIslandChat(
                message: newest,
                isExpanded: $chatExpanded,
                isInputFocused: $chatInputFocused,
                isWorking: $chatWorking,
                onAgentReply: { _ in agentAnswered() },
                replyField: ChatReplyField(
                    example: example,
                    isNoReply: isNoReply,
                    clearCount: fieldClearCount,
                    onlyTo: replyTarget.only,
                    tutorialMove: tutorialMove(thread)),
                onFieldSend: { _ in fieldComposeOpened = false })
            // One container, so its frame is the field's own (ChatThreadLayoutTests).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(Self.replyPillId)
        }
        .padding(.horizontal, chatExpanded ? 0 : ChatViewLayout.fieldSideInset)
        .padding(.bottom, ChatViewLayout.fieldBottomGap)
        .animation(Self.pillSpring, value: chatExpanded)
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

    /// The agent finished a request from the field with something to say: the sheet rises with
    /// the request and the answer, and the field empties. After a compose card the reply
    /// was the point, so nothing opens.
    private func agentAnswered() {
        guard !fieldComposeOpened else { return }
        fieldClearCount += 1
        withAnimation(Self.pillSpring) { chatExpanded = true }
    }

    /// A compose card from the chat closed. Sent: the field empties; a reply shows as its queued
    /// email's bubble, read from the outbox.
    private func composeEnded(_ outcome: ComposeOutcome, replyTo: MessageHeader?) {
        guard case .sent = outcome else { return }
        // A reply sent clears "Replying only to"; the next one is a Reply All again.
        if replyTo != nil { replyTarget = .replyAll }
        fieldClearCount += 1
    }

    @ViewBuilder
    private func composeView(for card: ChatAgentCard) -> some View {
        let req = card.request
        let onOutcome: @MainActor (ComposeOutcome) -> Void = { outcome in
            req.onOutcome(outcome)
            composeEnded(outcome, replyTo: req.mode == .reply ? req.replyTo : nil)
        }
        switch req.mode {
        case .compose:
            // A new email: no chat shows it, so it records no screen and keeps the toast.
            ComposeView(
                suggestedBody: req.body, account: context.accounts.first { $0.id == viewModel.message?.accountId },
                prefillTo: req.to, prefillCc: req.cc, prefillBcc: req.bcc, prefillSubject: req.subject,
                onAgentOutcome: onOutcome)
        case .reply:
            card.reply.composeView(
                replyTo: req.replyTo, suggestedBody: req.body, openedOn: composeScreen(answering: req.replyTo),
                onAgentOutcome: onOutcome)
        case .forward:
            ComposeView(
                replyTo: req.replyTo, suggestedBody: req.body, isForward: true,
                prefillTo: req.to, prefillCc: req.cc, prefillBcc: req.bcc,
                openedOn: composeScreen(answering: req.replyTo), onAgentOutcome: onOutcome)
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
