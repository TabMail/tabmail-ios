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
/// reply field. Tap a bubble for today's detail of that email, as a card from the bottom (N3).
/// Reuses `MessageDetailViewModel` for loading, thread detection, live AI updates and mark-read.
/// The reply field (`ChatReplyField`) is today's Chat pill on the newest email, shown as
/// [mic] [field] [Send].
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

    // The reply field: today's Chat pill on the newest email.
    @State private var chatExpanded = false
    /// The collapsed pill's height, notices and chips included: the room the thread keeps under its
    /// last bubble and the jump button (N2.10). The field grows to six lines, so it is measured;
    /// the open sheet keeps the last collapsed height, so the thread does not move under it.
    @State private var pillHeight = ChatViewLayout.pillStartHeight
    @State private var chatInputFocused = false
    @State private var chatWorking = false
    /// The ready AI Reply's compose card (N2.6): the email it answers.
    @State private var readyReplyMessage: MessageHeader?
    @State private var agentCompose: AgentToolRouter.ComposeRequest?
    /// The words last sent from the field to the agent; the Sent bubble shows them (N7).
    @State private var fieldWords: String?
    /// A compose card opened for the field's last request, so the agent's closing words open
    /// no sheet (N5, N6).
    @State private var fieldComposeOpened = false
    /// Bumps to empty the field.
    @State private var fieldClearCount = 0
    /// Who the next reply goes to (R1, R2); Reply All until changed in Reply to.
    @State private var replyTarget = ChatReplyTarget.replyAll
    @State private var showsReplyTo = false
    @State private var showsOnlyList = false
    @State private var forwardMessage: MessageHeader?
    private let sentReplies = ChatSentReplies.shared

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
        cardMessage != nil || readyReplyMessage != nil || agentCompose != nil
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
        .onChange(of: memberKey) { _, _ in
            noteMembers()
            sentReplies.settle(thread.items)
        }
        // A new newest email has its own people: the next reply is a Reply All to them.
        .onChange(of: thread.newest?.stableId) { _, _ in replyTarget = .replyAll }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // R1.2: Forward the newest email, in today's forward compose.
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
            // Asked from the field (not the open sheet): the agent's closing words open nothing.
            fieldComposeOpened = !chatExpanded
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
        .fullScreenCover(item: $readyReplyMessage) { msg in
            // N6: today's reply compose, Reply All, with the AI Reply in its suggestion box.
            let recipients = buildReplyAllRecipients(for: msg, allAccounts: context.accounts)
            let words = ChatReplyField.readyText(newest: msg, isOwn: false)
            ComposeView(
                replyTo: msg,
                prefillTo: recipients.to.isEmpty ? nil : recipients.to,
                prefillCc: recipients.cc.isEmpty ? nil : recipients.cc,
                onAgentOutcome: { outcome in composeEnded(outcome, replyTo: msg, words: words) })
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
                    LazyVStack(spacing: ChatViewLayout.bubbleSpacing) {
                        ForEach(thread.items) { item in
                            row(item, thread: thread)
                        }
                        // Sent replies whose email has not reached this iPhone yet (N7).
                        ForEach(unmatchedReplies(thread)) { entry in
                            ChatSentReplyBubble(text: entry.text)
                        }
                        Color.clear.frame(height: pillHeight + ChatViewLayout.pillGap).id(Self.bottomId)
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
                // again on every size change until it has settled or a scroll begins.
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
            standInText: item.isOwn && item.textMessage == nil
                ? ChatSentReplies.entry(for: item.header, in: pendingReplies(thread))?.text : nil,
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
        .padding(.bottom, pillHeight + ChatViewLayout.pillGap)
        .transition(.opacity)
        .accessibilityLabel("Jump to the newest email")
    }

    // MARK: - Opening rules

    private struct ScrollTarget: Equatable {
        let id: String
        let anchor: UnitPoint
    }

    /// Where the open lands (`scrollOnceLoaded`). Held while the rows lay out, so their late
    /// measuring cannot move the chat off it, and released once the screen has settled with
    /// emails on it (`askOnceSettled`) or a scroll of any kind begins. Held any longer, it would
    /// scroll again on every later size change (a smaller screen, the keyboard) and the chat would
    /// stop seeing which emails are on screen.
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
            if !visibleIds.isEmpty { scrollTarget = nil }
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

    // MARK: - Reply field (N2.6 to N2.9)

    private func pill(on newest: MessageHeader) -> some View {
        let isOwn = thread.items.last?.isOwn ?? false
        let isNoReply = !isOwn && EmailFilter.isNoReply(newest.fromAddress)
        return VStack(spacing: 8) {
            if let only = replyTarget.only, !chatExpanded {
                replyingOnlyTo(only)
            }
            if isNoReply && !chatExpanded {
                // E1.1: the field stays usable (the agent declines to reply, E1.2).
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
                    readyText: ChatReplyField.readyText(newest: newest, isOwn: isOwn),
                    isNoReply: isNoReply,
                    clearCount: fieldClearCount,
                    onlyTo: replyTarget.only),
                onSendReadyReply: { readyReplyMessage = newest },
                onFieldSend: { words in
                    fieldWords = words
                    fieldComposeOpened = false
                })
        }
        .padding(.horizontal, chatExpanded ? 0 : 12)
        .padding(.bottom, chatExpanded ? 8 : 34)
        .animation(Self.pillSpring, value: chatExpanded)
    }

    /// R2.3: the gray line above the field when the reply is not a Reply All; tap for everyone.
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
    /// the request and the answer, and the field empties (A3.1). After a compose card the reply
    /// was the point, so nothing opens.
    private func agentAnswered() {
        guard !fieldComposeOpened else { return }
        fieldClearCount += 1
        withAnimation(Self.pillSpring) { chatExpanded = true }
    }

    /// A compose card from the chat closed. Sent: the field empties and, for a reply, the chat
    /// shows the words until the sent email's own text message arrives (N6.3, N7).
    private func composeEnded(_ outcome: ComposeOutcome, replyTo: MessageHeader?, words: String?) {
        guard sentReplies.composeEnded(outcome, replyTo: replyTo, words: words) else { return }
        // R2.4: a reply sent clears "Replying only to"; the next one is a Reply All again.
        if replyTo != nil { replyTarget = .replyAll }
        fieldClearCount += 1
    }

    /// This chat's sent replies still waiting for their email's text message.
    private func pendingReplies(_ thread: ChatThread) -> [ChatSentReplies.Entry] {
        guard let accountId = thread.newest?.accountId else { return [] }
        return sentReplies.entries(
            accountId: accountId, messageIds: Set(thread.items.compactMap(\.header.rfc822MessageId)))
    }

    /// Sent replies whose email is not in the chat yet.
    private func unmatchedReplies(_ thread: ChatThread) -> [ChatSentReplies.Entry] {
        let matched = Set(thread.items.compactMap { ChatSentReplies.entry(for: $0.header, in: pendingReplies(thread))?.id })
        return pendingReplies(thread).filter { !matched.contains($0.id) }
    }

    @ViewBuilder
    private func composeView(for req: AgentToolRouter.ComposeRequest) -> some View {
        // A reply asked for in the field shows the field's words as its Sent bubble (N7).
        let words = req.mode == .reply && fieldComposeOpened ? fieldWords : nil
        let onOutcome: @MainActor (ComposeOutcome) -> Void = { outcome in
            req.onOutcome(outcome)
            composeEnded(outcome, replyTo: req.mode == .reply ? req.replyTo : nil, words: words)
        }
        switch req.mode {
        case .compose:
            ComposeView(
                suggestedBody: req.body, account: context.accounts.first { $0.id == viewModel.message?.accountId },
                prefillTo: req.to, prefillCc: req.cc, prefillBcc: req.bcc, prefillSubject: req.subject,
                onAgentOutcome: onOutcome)
        case .reply:
            // R1: a reply asked for in the field goes to the people chosen in Reply to.
            let only = fieldComposeOpened ? replyTarget.only?.map(\.address) : nil
            let to = only ?? req.to
            let cc = only == nil ? req.cc : []
            ComposeView(
                replyTo: req.replyTo, suggestedBody: req.body,
                prefillTo: to.isEmpty ? nil : to, prefillCc: cc.isEmpty ? nil : cc,
                prefillBcc: req.bcc.isEmpty ? nil : req.bcc, onAgentOutcome: onOutcome)
        case .forward:
            ComposeView(
                replyTo: req.replyTo, suggestedBody: req.body, isForward: true,
                prefillTo: req.to, prefillCc: req.cc, prefillBcc: req.bcc, onAgentOutcome: onOutcome)
        }
    }
}

/// The chat's header: who the reply goes to (N2.1), the subject, the thread's labels (N2.L).
struct ChatHeaderView: View {
    let thread: ChatThread
    let subject: String
    let labels: [UserLabel]
    /// Tapping the names changes who gets the reply (R1.1).
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
