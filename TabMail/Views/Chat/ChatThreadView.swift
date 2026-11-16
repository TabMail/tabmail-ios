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
    /// The ready AI Reply's compose card: the email it answers, and how it opens.
    @State private var readyReply: ChatReadyReply?
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

    /// The Message-IDs of the chat's emails, normalized.
    private var messageIds: Set<String> {
        Set(members.compactMap { $0.rfc822MessageId.map(EmailFilter.normalizeMessageId) })
    }

    private var isAnyPresentation: Bool {
        cardMessage != nil || readyReply != nil || agentCompose != nil
            || forwardMessage != nil || showsReplyTo
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
            ToolbarItem(placement: .topBarTrailing) {
                // Forward the newest email, in today's forward compose.
                Button { forwardMessage = thread.newest } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                }
                .disabled(thread.newest == nil)
                .accessibilityLabel("Forward")
            }
        }
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
            // Today's reply compose, with the AI Reply in its suggestion box: Reply All, or a reply
            // to only the people chosen in Reply to.
            ready.compose.composeView(
                replyTo: ready.message, onAgentOutcome: { outcome in composeEnded(outcome, replyTo: ready.message) })
        }
        .fullScreenCover(item: $agentCompose) { composeView(for: $0) }
        .fullScreenCover(item: $forwardMessage) { ComposeView(replyTo: $0, isForward: true) }
        .sheet(isPresented: $showsReplyTo) {
            ChatReplyToSheet(
                replyPeople: thread.replyPeople, target: replyTarget,
                ownAddresses: context.ownAddresses) { replyTarget = $0 }
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
                        // Replies still in the outbox.
                        ForEach(unsentReplies) { reply in
                            ChatUnsentReplyBubble(reply: reply, retry: { reply.retry() }, delete: { reply.delete() })
                        }
                        Color.clear.frame(height: pillHeight + ChatViewLayout.pillGap).id(Self.bottomId)
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
            .safeAreaInset(edge: .top, spacing: 0) {
                ChatHeaderView(thread: thread, subject: subject(thread), labels: context.labels) {
                    showsReplyTo = true
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

    // MARK: - Reply field

    private func pill(on newest: MessageHeader) -> some View {
        let isOwn = thread.items.last?.isOwn ?? false
        // The user's turn: their email is the newest, or a reply of theirs is still in the outbox
        // below it. No AI Reply is offered on the user's turn.
        let usersTurn = isOwn || !unsentReplies.isEmpty
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
                    readyText: ChatReplyField.readyText(newest: newest, isOwn: usersTurn),
                    isNoReply: isNoReply,
                    clearCount: fieldClearCount,
                    onlyTo: replyTarget.only),
                onSendReadyReply: {
                    readyReply = ChatReadyReply(message: newest, compose: ChatReplyCompose.make(
                        replyTo: newest, target: replyTarget, accounts: context.accounts))
                },
                onFieldSend: { _ in fieldComposeOpened = false })
        }
        .padding(.horizontal, chatExpanded ? 0 : 12)
        .padding(.bottom, chatExpanded ? 8 : 34)
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
            ComposeView(
                suggestedBody: req.body, account: context.accounts.first { $0.id == viewModel.message?.accountId },
                prefillTo: req.to, prefillCc: req.cc, prefillBcc: req.bcc, prefillSubject: req.subject,
                onAgentOutcome: onOutcome)
        case .reply:
            card.reply.composeView(replyTo: req.replyTo, suggestedBody: req.body, onAgentOutcome: onOutcome)
        case .forward:
            ComposeView(
                replyTo: req.replyTo, suggestedBody: req.body, isForward: true,
                prefillTo: req.to, prefillCc: req.cc, prefillBcc: req.bcc, onAgentOutcome: onOutcome)
        }
    }
}

/// The chat's header: who the reply goes to, the subject, the thread's labels.
struct ChatHeaderView: View {
    let thread: ChatThread
    let subject: String
    let labels: [UserLabel]
    /// Tapping the names changes who gets the reply.
    var onTapNames: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: -8) {
                ForEach(Array(thread.replyPeople.prefix(ChatViewLayout.headerNameCount + 1).enumerated()), id: \.offset) { _, person in
                    ChatAvatar(person: person, size: ChatViewLayout.headerAvatarSize)
                        .overlay(Circle().stroke(Palette.previewPaneBg, lineWidth: 2))
                }
            }
            if !thread.replyPeople.isEmpty {
                Button { onTapNames?() } label: {
                    HStack(spacing: 2) {
                        Text(ChatThread.headerTitle(thread.replyPeople))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(onTapNames == nil)
                .accessibilityHint("Changes who gets your reply")
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
        .accessibilityElement(children: .contain)
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
