/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Opens a message that is not a draft: as a chat when the chat view is on (Q20: from any folder,
/// search, a notification or a reminder), else in today's detail. Decided once per open: the
/// setting is snapshotted, so a Settings change applies to the next open.
struct MessageOpenView: View {
    let messageId: String
    var expectedRfc822MessageId: String?
    var opensWithSkeletonDwell = false
    /// Opened from search or a notification: the chat scrolls to this email and its bubble
    /// glows briefly (O2).
    var highlightsMessage = false
    @State private var opensInChat = ChatViewConfig.opensInChat

    var body: some View {
        if opensInChat {
            ChatThreadView(
                messageId: messageId,
                expectedRfc822MessageId: expectedRfc822MessageId,
                highlightsOpenedMessage: highlightsMessage)
        } else {
            MessageDetailView(
                messageId: messageId,
                opensWithSkeletonDwell: opensWithSkeletonDwell,
                expectedRfc822MessageId: expectedRfc822MessageId)
        }
    }
}

extension ChatViewConfig {
    /// Whether an open goes to the chat now. Demo mode with AI declined counts as AI off, and the
    /// tutorial keeps today's view until it moves into the chat view.
    @MainActor static var opensInChat: Bool {
        opensInChat(active: isActive,
                    demoHidesAI: DemoModeStore.shared.hidesAIContent,
                    tutorialRunning: TutorialCoordinator.shared.isRunning)
    }

    static func opensInChat(active: Bool, demoHidesAI: Bool, tutorialRunning: Bool) -> Bool {
        active && !demoHidesAI && !tutorialRunning
    }
}

/// A thread as a chat (N2): every email as a bubble, oldest at the top, the newest just above the
/// pill. Tap a bubble for today's detail of that email, as a card from the bottom (N3). Reuses
/// `MessageDetailViewModel` for loading, thread detection, live AI updates and mark-read.
struct ChatThreadView: View {
    @State var viewModel: MessageDetailViewModel
    let highlightsOpenedMessage: Bool

    @State private var context = ChatThreadContext()
    /// Emails that were unread when they first showed here; marked read as they show (Q21).
    @State private var unreadAtOpen: Set<String> = []
    @State private var seenIds: Set<String> = []
    @State private var didInitialScroll = false
    /// The emails on screen, and whether the scroll is at rest; a scroll has stopped once since
    /// the open (`askForSummaries`).
    @State private var visibleIds: Set<String> = []
    @State private var scrollIsIdle = true
    @State private var hasScrolled = false
    @State private var summaryAsk: Task<Void, Never>?
    @State private var highlightedId: String?
    @State private var showsJumpButton = false
    @State private var cardMessage: MessageHeader?

    // Today's pill, on the newest email (the morphing reply pill replaces it).
    @State private var chatExpanded = false
    @State private var chatInputFocused = false
    @State private var chatWorking = false
    @State private var replyMessage: MessageHeader?
    @State private var replyAllMessage: MessageHeader?
    @State private var forwardMessage: MessageHeader?
    @State private var moveMessage: MessageHeader?
    @State private var agentCompose: AgentToolRouter.ComposeRequest?
    @Environment(\.dismiss) private var dismiss

    private static let bottomId = "chat-bottom"
    private static let unreadLineId = "chat-unread-line"
    private static let pillSpring = Animation.spring(response: 0.45, dampingFraction: 0.82)

    init(messageId: String, expectedRfc822MessageId: String? = nil, highlightsOpenedMessage: Bool = false) {
        self._viewModel = State(initialValue: MessageDetailViewModel(
            messageId: messageId, expectedRfc822MessageId: expectedRfc822MessageId))
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

    private var isAnyPresentation: Bool {
        cardMessage != nil || replyMessage != nil || replyAllMessage != nil
            || forwardMessage != nil || moveMessage != nil || agentCompose != nil
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(chatExpanded && chatInputFocused ? .hidden : .automatic, for: .navigationBar)
        .task {
            noteMembers()
            await viewModel.loadBody()
        }
        .task(id: memberKey) {
            guard !members.isEmpty else { return }
            context = await ChatThreadContext.load(members: members, pool: AppDatabase.dbPool)
            scrollOnceLoaded()
        }
        .onChange(of: memberKey) { _, _ in noteMembers() }
        .onChange(of: viewModel.hasLoadedThread) { _, _ in scrollOnceLoaded() }
        .onAppear {
            viewModel.isViewVisible = true
            Task { await viewModel.loadBody() }
        }
        .onDisappear {
            viewModel.isViewVisible = false
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
        .onChange(of: AgentToolRouter.shared.pendingCompose?.id) { _, newId in
            guard newId != nil else { return }
            agentCompose = AgentToolRouter.shared.pendingCompose
            AgentToolRouter.shared.pendingCompose = nil
        }
        .sheet(item: $cardMessage) { msg in
            // N3: today's detail of that email, from the bottom; swipe down to return.
            NavigationStack {
                MessageDetailView(messageId: msg.id, expectedRfc822MessageId: msg.rfc822MessageId)
            }
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $replyMessage) { ComposeView(replyTo: $0) }
        .fullScreenCover(item: $replyAllMessage) { msg in
            let accounts = context.accounts
            let recipients = buildReplyAllRecipients(for: msg, allAccounts: accounts)
            ComposeView(
                replyTo: msg,
                prefillTo: recipients.to.isEmpty ? nil : recipients.to,
                prefillCc: recipients.cc.isEmpty ? nil : recipients.cc)
        }
        .fullScreenCover(item: $forwardMessage) { ComposeView(replyTo: $0, isForward: true) }
        .fullScreenCover(item: $agentCompose) { composeView(for: $0) }
        .sheet(item: $moveMessage) { msg in
            MoveFolderPicker(accountId: msg.accountId, currentFolderPath: msg.folderPath) { path in
                handleMove(msg, toFolderPath: path)
            }
        }
    }

    @ViewBuilder
    private func chatContent(_ thread: ChatThread) -> some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: ChatViewLayout.bubbleSpacing) {
                        ForEach(thread.items) { item in
                            row(item, thread: thread)
                        }
                        Color.clear.frame(height: ChatViewLayout.pillClearance).id(Self.bottomId)
                    }
                    .scrollTargetLayout()
                    .padding(.top, 8)
                }
                .onScrollTargetVisibilityChange(idType: String.self) { ids in
                    visibleIds = Set(ids)
                    if scrollIsIdle { askOnceSettled() }
                }
                .onScrollPhaseChange { _, phase in
                    if ChatSummaryWindow.userMoved(phase) { hasScrolled = true }
                    // Any scroll (a hand, the jump button, an animated scroll) ends the landing.
                    if phase != .idle { scrollTarget = nil }
                    scrollIsIdle = phase == .idle
                    guard phase == .idle else { summaryAsk?.cancel(); return }
                    askOnceSettled()
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentSize.height - (geo.contentOffset.y + geo.containerSize.height) > ChatViewLayout.jumpButtonThreshold
                } action: { _, isAbove in
                    withAnimation(.easeInOut(duration: 0.2)) { showsJumpButton = isAbove }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target.id, anchor: target.anchor)
                }
                // A one-shot scroll can be dropped or undone while the rows are still laid out
                // (the bottom anchor keeps its place as they measure), so the landing is issued
                // again on every size change until a scroll begins.
                .onScrollGeometryChange(for: [CGFloat].self) { geo in
                    [geo.containerSize.height, geo.contentSize.height]
                } action: { _, _ in
                    guard let target = scrollTarget else { return }
                    proxy.scrollTo(target.id, anchor: target.anchor)
                }
                .overlay(alignment: .bottomTrailing) {
                    if showsJumpButton {
                        jumpButton { withAnimation { proxy.scrollTo(Self.bottomId, anchor: .bottom) } }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ChatHeaderView(thread: thread, subject: subject(thread), labels: context.labels) }
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
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ChatThread.Item, thread: ChatThread) -> some View {
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
            onOpen: { cardMessage = item.header })
        .id(item.id)
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
        .padding(.bottom, ChatViewLayout.pillClearance)
        .transition(.opacity)
        .accessibilityLabel("Jump to the newest email")
    }

    // MARK: - Opening rules

    private struct ScrollTarget: Equatable {
        let id: String
        let anchor: UnitPoint
    }

    /// Where the open lands (`scrollOnceLoaded`). Held until the first scroll of any kind, so a
    /// layout that settles after the first scroll cannot move the chat off it.
    @State private var scrollTarget: ScrollTarget?

    /// Records each email the first time it shows, then marks it read (Q21). Its unread state at
    /// that moment places the Unread line (O1).
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

    /// Asks for the summaries of the emails on screen and those near them, on screen first
    /// (`ChatSummaryWindow`, owner 2026-11-06): until the user first scrolls by hand, the
    /// `ChatViewConfig.summaryWindow` emails above the oldest on screen; after it,
    /// `ChatViewConfig.summaryWindow` on each side. Runs whenever the emails on screen change while
    /// the scroll is at rest, and when a scroll stops. The chat view setting is read once, here.
    /// Asks once the screen has stayed the same for `ChatViewConfig.summaryAskSettle` with the
    /// scroll at rest; each change starts the wait again.
    private func askOnceSettled() {
        summaryAsk?.cancel()
        summaryAsk = Task { @MainActor in
            try? await Task.sleep(for: ChatViewConfig.summaryAskSettle)
            guard !Task.isCancelled, scrollIsIdle else { return }
            askForSummaries()
        }
    }

    private func askForSummaries() {
        guard ChatViewConfig.isActive else { return }
        let items = thread.items
        let ids = ChatSummaryWindow.ids(order: items.map(\.id), visible: visibleIds, handScrolled: hasScrolled)
        let byId = Dictionary(items.map { ($0.id, $0.header) }, uniquingKeysWith: { first, _ in first })
        let headers = ids.compactMap { byId[$0] }
        guard !headers.isEmpty else { return }
        Task { await ActiveAIQueue.shared.enqueueChatSummaries(headers) }
    }

    /// The first scroll, once the thread and its extras are in: to the opened email when it came
    /// from search or a notification (O2), else to the Unread line (O1), else the bottom (N2.10).
    private func scrollOnceLoaded() {
        guard !didInitialScroll, viewModel.hasLoadedThread, context.isLoaded else { return }
        didInitialScroll = true
        // The thread's emails arrive with `hasLoadedThread`, and SwiftUI runs that change and the
        // members change in either order: record their unread state first, or the Unread line can
        // be missing and the chat opens at the bottom.
        noteMembers()
        let thread = thread
        if highlightsOpenedMessage, let opened = viewModel.message,
           let item = thread.items.first(where: { $0.header.stableId == opened.stableId }) {
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

    // MARK: - Pill (today's Reply / Chat / Archive, on the newest email)

    private var showSideButtons: Bool { !chatExpanded }

    private func pill(on newest: MessageHeader) -> some View {
        HStack(spacing: chatExpanded ? 0 : 12) {
            Menu {
                Button { replyMessage = newest } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                Button { replyAllMessage = newest } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                Button { forwardMessage = newest } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            } label: {
                pillCircle("arrowshape.turn.up.left")
            }
            .tint(.primary)
            .menuStyle(.button)
            .modifier(SideButtonVisibility(visible: showSideButtons))

            DynamicIslandChat(message: newest, isExpanded: $chatExpanded, isInputFocused: $chatInputFocused, isWorking: $chatWorking)

            Menu {
                RestrictedMailActionButton(
                    isRestricted: viewModel.folderMoveIsForbidden(newest),
                    action: { handleArchive(newest) }
                ) { Label("Archive", systemImage: "archivebox") }
                Button(role: .destructive) { handleDelete(newest) } label: { Label("Delete", systemImage: "trash") }
                RestrictedMailActionButton(
                    isRestricted: viewModel.folderMoveIsForbidden(newest),
                    action: { moveMessage = newest }
                ) { Label("Move", systemImage: "folder") }
            } label: {
                pillCircle("archivebox")
            }
            .tint(.primary)
            .modifier(SideButtonVisibility(visible: showSideButtons))
        }
        .padding(.bottom, chatExpanded ? 8 : 34)
        .animation(Self.pillSpring, value: chatExpanded)
    }

    private func pillCircle(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.title3)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
            .frame(width: 56, height: 56)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
    }

    // MARK: - Actions (as today's detail: the opened email leaves the screen, others stay)

    private func handleArchive(_ msg: MessageHeader) {
        if msg.id == viewModel.message?.id {
            if viewModel.archive() { dismissChat(destinationFolderId: nil) }
        } else {
            _ = viewModel.archiveMessage(msg)
        }
    }

    private func handleDelete(_ msg: MessageHeader) {
        if msg.id == viewModel.message?.id {
            if viewModel.delete() { dismissChat(destinationFolderId: nil) }
        } else {
            _ = viewModel.deleteMessage(msg)
        }
    }

    private func handleMove(_ msg: MessageHeader, toFolderPath path: String) {
        if msg.id == viewModel.message?.id {
            if viewModel.move(toFolderPath: path) {
                dismissChat(destinationFolderId: MessageIdentity.folderId(accountId: msg.accountId, folderPath: path))
            }
        } else {
            _ = viewModel.moveMessage(msg, toFolderPath: path)
        }
    }

    /// As `MessageDetailView.dismissMessage`: the list behind hides the row, then the chat closes.
    private func dismissChat(destinationFolderId: String?) {
        NotificationCenter.default.post(
            name: .messageDismissedFromDetail,
            object: viewModel.messageId,
            userInfo: destinationFolderId.map { [MessageDetailView.dismissDestinationFolderIdKey: $0] })
        dismiss()
    }

    @ViewBuilder
    private func composeView(for req: AgentToolRouter.ComposeRequest) -> some View {
        switch req.mode {
        case .compose:
            ComposeView(
                suggestedBody: req.body, account: context.accounts.first { $0.id == viewModel.message?.accountId },
                prefillTo: req.to, prefillCc: req.cc, prefillBcc: req.bcc, prefillSubject: req.subject,
                onAgentOutcome: req.onOutcome)
        case .reply:
            ComposeView(
                replyTo: req.replyTo, suggestedBody: req.body,
                prefillTo: req.to.isEmpty ? nil : req.to, prefillCc: req.cc.isEmpty ? nil : req.cc,
                prefillBcc: req.bcc.isEmpty ? nil : req.bcc, onAgentOutcome: req.onOutcome)
        case .forward:
            ComposeView(
                replyTo: req.replyTo, suggestedBody: req.body, isForward: true,
                prefillTo: req.to, prefillCc: req.cc, prefillBcc: req.bcc, onAgentOutcome: req.onOutcome)
        }
    }
}

/// Today's pill side buttons collapse while the chat is open.
private struct SideButtonVisibility: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: visible ? nil : 0, height: visible ? nil : 0)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 30)
            .allowsHitTesting(visible)
    }
}

/// The chat's header: who the reply goes to (N2.1), the subject, the thread's labels (N2.L).
struct ChatHeaderView: View {
    let thread: ChatThread
    let subject: String
    let labels: [UserLabel]

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: -8) {
                ForEach(Array(thread.replyPeople.prefix(ChatViewLayout.headerNameCount + 1).enumerated()), id: \.offset) { _, person in
                    ChatAvatar(person: person, size: ChatViewLayout.headerAvatarSize)
                        .overlay(Circle().stroke(Palette.previewPaneBg, lineWidth: 2))
                }
            }
            if !thread.replyPeople.isEmpty {
                Text(ChatThread.headerTitle(thread.replyPeople))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            Text(subject)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if !labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(UserLabelDisplaySegment.expand(labels)) { segment in
                        UserLabelChip(name: segment.displayName)
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}
