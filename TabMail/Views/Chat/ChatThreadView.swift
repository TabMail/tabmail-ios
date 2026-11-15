/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import GRDB
import SwiftUI

/// Opens a message from any open path (a folder, search, a notification, a reminder, an email
/// reference): a draft in the draft editor, as from Drafts (the chat leaves drafts out);
/// anything else as a chat when the chat view is on, else in today's detail. The chat view
/// setting is snapshotted once per open, so a Settings change applies to the next open.
struct MessageOpenView: View {
    let messageId: String
    var expectedRfc822MessageId: String?
    var opensWithSkeletonDwell = false
    /// Opened from search or a notification: the chat scrolls to this email and its bubble
    /// glows briefly.
    var highlightsMessage = false
    @State private var opensInChat = ChatViewConfig.opensInChat

    /// Where an open goes.
    enum Route: Equatable {
        /// A message in a Drafts folder: the draft editor (`DraftComposePresenter`).
        case draftEditor(MessageHeader)
        case chat
        case detail
    }

    /// The open's route: a Drafts-folder message goes to the draft editor whatever the chat view
    /// setting; anything else, a message not found included, to the chat or today's detail. One
    /// read transaction, so the header and its folder agree. A search result carries the
    /// Message-ID it found (`expectedRfc822MessageId`): a header that no longer has it is not the
    /// draft searched for, so it goes to the chat or the detail, which refuse a replaced message.
    nonisolated static func route(
        messageId: String, expectedRfc822MessageId: String? = nil, opensInChat: Bool, pool: PrioritizedDatabase
    ) -> Route {
        let expected = ExpectedMessageIdentity(capturedRfc822MessageId: expectedRfc822MessageId)
        let draft: MessageHeader? = try? pool.read { db in
            guard let header = try MessageHeader.fetchOne(db, key: messageId),
                  expected?.matches(header) ?? true,
                  try Folder.fetchOne(db, key: header.folderId)?.role == .drafts else { return nil }
            return header
        }
        if let draft { return .draftEditor(draft) }
        return opensInChat ? .chat : .detail
    }

    var body: some View {
        switch Self.route(messageId: messageId, expectedRfc822MessageId: expectedRfc822MessageId,
                          opensInChat: opensInChat, pool: AppDatabase.dbPool) {
        case .draftEditor(let header):
            DraftComposePresenter(source: .header(header))
        case .chat:
            ChatThreadView(
                messageId: messageId,
                expectedRfc822MessageId: expectedRfc822MessageId,
                highlightsOpenedMessage: highlightsMessage)
        case .detail:
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

/// A thread as a chat: every email as a bubble, oldest at the top, the newest just above the
/// pill. Tap a bubble for today's detail of that email, as a card from the bottom. Reuses
/// `MessageDetailViewModel` for loading, thread detection, live AI updates and mark-read.
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
        .dismissKeyboardOnTap()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(chatExpanded && chatInputFocused ? .hidden : .automatic, for: .navigationBar)
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
        .onChange(of: viewModel.hasLoadedThread) { _, _ in scrollOnceLoaded() }
        .onAppear {
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
            guard newId != nil else { return }
            agentCompose = AgentToolRouter.shared.pendingCompose
            AgentToolRouter.shared.pendingCompose = nil
        }
        .sheet(item: $cardMessage) { msg in
            // Today's detail of that email, from the bottom; swipe down to return.
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
                    // A plain stack: every row has its real height, so one scroll lands where it
                    // aims. A lazy stack starts rows at guessed heights and moves the target while
                    // they measure (memory 036). Threads are short, and the AI work is bounded by
                    // what the chat asks for, not by what it builds.
                    VStack(spacing: ChatViewLayout.bubbleSpacing) {
                        ForEach(thread.items) { item in
                            row(item, thread: thread)
                        }
                        Color.clear.frame(height: ChatViewLayout.pillClearance).id(Self.bottomId)
                    }
                    .padding(.top, 8)
                }
                // Any scroll (a hand, the jump button, an animated scroll) ends the landing.
                .onScrollPhaseChange { _, phase in
                    if phase != .idle { scrollTarget = nil }
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
                // The first scroll can be dropped while the screen is still settling (memory 036),
                // and late content (attachment chips, a summary) changes the heights: the landing
                // is issued again on every size change until a scroll begins.
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
        .onScrollVisibilityChange { shown in
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
        .padding(.bottom, ChatViewLayout.pillClearance)
        .transition(.opacity)
        .accessibilityLabel("Jump to the newest email")
    }

    // MARK: - Opening rules

    private struct ScrollTarget: Equatable {
        let id: String
        let anchor: UnitPoint
    }

    /// Where the open lands (`scrollOnceLoaded`). Held until a scroll of any kind begins, so the
    /// landing is issued again while the screen settles; then the user's scroll owns the screen.
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
    /// that moment places the Unread line.
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
        didInitialScroll = true
        // The thread's emails arrive with `hasLoadedThread`, and SwiftUI runs that change and the
        // members change in either order: record their unread state first, or the Unread line can
        // be missing and the chat opens at the bottom.
        noteMembers()
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

    // MARK: - Summaries (owner 2026-11-09)

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
    /// it comes on screen, so scrolling up summarizes as it goes. Only once the open has asked for
    /// the newest (before that, which emails are the newest is not known yet).
    private func askAsShown(_ item: ChatThread.Item, in thread: ChatThread) {
        guard didInitialScroll else { return }
        let items = thread.items
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              index < items.count - ChatViewConfig.summaryWindow,
              ChatViewConfig.isActive else { return }
        let header = item.header
        Task { await ActiveAIQueue.shared.enqueueChatSummaries([header]) }
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

/// The chat's header: who the reply goes to, the subject, the thread's labels.
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
