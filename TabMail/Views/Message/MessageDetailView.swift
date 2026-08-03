/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct MessageDetailView: View {
    @State var viewModel: MessageDetailViewModel
    @State var chatExpanded = false
    @State var chatInputFocused = false
    @State var chatWorking = false
    @State var replyMessage: MessageHeader?
    @State var replyAllMessage: MessageHeader?
    @State var forwardMessage: MessageHeader?
    @State var moveMessage: MessageHeader?
    @State var sideButtonsReady = true
    @State var agentCompose: AgentToolRouter.ComposeRequest?
    @State private var showCompose = false
    @State var contactComposeRequest: MailtoRequest?
    @State private var labelMenuMessage: MessageHeader?
    /// The message whose card is most visible in the viewport — used as chat context and action target.
    @State var chatContextMessage: MessageHeader?
    /// ID of a card that should flash to indicate a move/state change.
    @State var flashedCardId: String?
    @State private var listHeight: CGFloat = 900
    @State private var focusedCardHeight: CGFloat = 0
    @State private var agentToast: AgentToastPayload?
    @State private var agentToastDismiss: Task<Void, Never>?
    @State private var userHasScrolledDetail = false
    @State private var openAnchorArmed = true
    /// Pushed-pill opens only (`opensWithSkeletonDwell`): the header resolves
    /// ~10-20ms after construction — before the push transition's first
    /// visible frame — so the natural skeleton branch never gets a visible
    /// frame. Draw the skeleton as an OVERLAY on top of the (immediately
    /// mounted, fully live) content for long enough to outlast the push
    /// transition, then dissolve. OVERLAY, never a content gate: gating
    /// content creation on a cosmetic timer slowed normal opens and broke the
    /// laterMessages.count anchor (68ded8e, reverted).
    @State private var skeletonOverlayVisible = false
    /// Must exceed the navigationDestination push transition (~0.5s spring)
    /// so the dissolve tail lands after the view settles.
    private static let pushedSkeletonDwell: Duration = .milliseconds(650)
    /// Whether this instance was opened via the programmatic pushed-pill
    /// destination (`PushedMessageDestination`) rather than an inbox row tap
    /// or notification deep link. Only the pill path dwells the skeleton
    /// overlay — see `skeletonOverlayVisible` doc comment above.
    let opensWithSkeletonDwell: Bool
    var showSideButtons: Bool { !chatExpanded && sideButtonsReady }
    @AppStorage(AIService.optOutAllAIKey, store: AIService.optOutStore) var optOutAllAI = false
    @Environment(\.dismiss) var dismiss
    @Environment(\.hasTabMailSession) var hasTabMailSession

    var anyAISourceEnabled: Bool {
        (!optOutAllAI || DeviceSyncService.shared.isAutoEnabled) && AISubscriptionGate.shared.isActive
    }

    /// True while ANY of this view's sheets/fullScreenCovers is presented.
    /// Combines ALL EIGHT presentation states in one computed value so a
    /// single `.onChange` (see body) keeps `viewModel.hasActivePresentation`
    /// current — covers do NOT fire the presenting view's
    /// `onAppear`/`onDisappear`, and the VM must not post the unresolved-tap
    /// pop while a cover (worst case: an open compose draft) sits on top.
    /// One computed + ONE onChange, not eight — the body's modifier chain is
    /// type-checker-budget-sensitive.
    private var isAnyCoverPresented: Bool {
        showCompose
            || contactComposeRequest != nil
            || replyMessage != nil
            || replyAllMessage != nil
            || forwardMessage != nil
            || agentCompose != nil
            || moveMessage != nil
            || labelMenuMessage != nil
    }

    init(messageId: String, opensWithSkeletonDwell: Bool = false) {
        self._viewModel = State(initialValue: MessageDetailViewModel(messageId: messageId))
        self.opensWithSkeletonDwell = opensWithSkeletonDwell
        self._skeletonOverlayVisible = State(initialValue: opensWithSkeletonDwell)
        if DebugModeManager.isLoggingEnabled() {
            print("[DetailRender] MessageDetailView.init msgId=\(messageId.prefix(40))")
        }
    }

    var body: some View {
        bodyContent
            .overlay {
                if skeletonOverlayVisible && !viewModel.messageNotFound {
                    MessageDetailSkeleton()
                        .transition(.opacity)
                }
            }
            .task {
                guard skeletonOverlayVisible else { return }
                try? await Task.sleep(for: Self.pushedSkeletonDwell)
                withAnimation(Theme.detailContentDissolve) {
                    skeletonOverlayVisible = false
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(chatExpanded && chatInputFocused ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(activeSubject)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if chatExpanded {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                    chatExpanded = false
                                }
                            }
                        }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ComposeToolbarButton(onNewCompose: {
                        if chatExpanded {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                chatExpanded = false
                            }
                        }
                        showCompose = true
                    })
                }
            }
            .fullScreenCover(isPresented: $showCompose) {
                ComposeView()
            }
            .dismissKeyboardOnTap()
            .onReceive(NotificationCenter.default.publisher(for: .openMessageWithChat).receive(on: DispatchQueue.main)) { notification in
                guard let msgId = notification.userInfo?["messageId"] as? String,
                      msgId == viewModel.messageId else { return }
                // Reload body (may be stale if view was cached) and expand chat
                Task {
                    await viewModel.loadBody()
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        chatExpanded = true
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .emailPillTapped).receive(on: DispatchQueue.main)) { _ in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    chatExpanded = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .contactPillComposeTapped).receive(on: DispatchQueue.main)) { notification in
                guard let request = MailtoRequest.from(userInfo: notification.userInfo) else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    chatExpanded = false
                }
                contactComposeRequest = request
                print("[DynamicIslandChat] Contact pill compose: \(request.to.first ?? "")")
            }
            .task {
                // Mark-read runs on its own unstructured Task so that
                // cancellation of this `.task` (common during notification
                // deep-link navigation) does not skip the read-flip. See
                // `MessageDetailViewModel.markReadOnOpenIfNeeded()`.
                Task { await viewModel.markReadOnOpenIfNeeded() }
                await viewModel.loadBody()
            }
            .onReceive(NotificationCenter.default.publisher(for: .agentSessionDidFinish).receive(on: DispatchQueue.main)) { notification in
                guard let sessionKey = notification.userInfo?["sessionKey"] as? String else { return }
                if let myKey = messageSessionKey, sessionKey == myKey {
                    if let response = ActiveAgentTracker.shared.consumePendingResponse(sessionKey) {
                        showAgentToast(response)
                    }
                }
            }
            .onAppear {
                // Visibility flag for the VM's unresolved-tap pop suppression:
                // a disappeared VM's late ladder exhaustion must not pop a
                // newer same-sentinel view (see isViewVisible's doc).
                viewModel.isViewVisible = true
                chatContextMessage = viewModel.message
                // Redundant loadBody trigger — covers edge cases where SwiftUI's .task
                // doesn't fire for programmatically pushed NavigationSplitView detail views
                // (e.g., notification deep links on iPhone). Safe to call unconditionally —
                // loadBody() is guarded by loadBodyCalled to prevent duplicate execution.
                Task { await viewModel.loadBody() }
                // Same redundancy for mark-read. Both idempotency latches mean the
                // first caller wins; if `.task`'s inner Task already fired, this is
                // a no-op. Guarantees read-flip even when `.task` never fires.
                Task { await viewModel.markReadOnOpenIfNeeded() }
                // Check for agent responses that arrived while this view was offscreen.
                if let key = messageSessionKey,
                   let response = ActiveAgentTracker.shared.consumePendingResponse(key) {
                    showAgentToast(response)
                }
            }
            .onDisappear {
                // See .onAppear — a hidden VM must not pop a newer
                // same-sentinel view when its abandoned ladder exhausts late.
                viewModel.isViewVisible = false
                chatExpanded = false
                ICSCalendarImporter.dismiss()
                // Never leave the gate stuck frozen if the view goes away
                // mid-scroll — it would freeze height application for every
                // HTMLWebView process-wide.
                ScrollFreezeGate.shared.end()
            }
            .onChange(of: isAnyCoverPresented) { _, active in
                // Sheets/covers do NOT fire onDisappear on this view — this
                // is how the VM learns a presentation is up, so its
                // unresolved-tap pop can't tear down a view (and force-dismiss
                // an open compose draft) beneath a live cover. One combined
                // onChange for all eight presentation states — see
                // isAnyCoverPresented.
                viewModel.hasActivePresentation = active
            }
    }

    @ViewBuilder
    private var bodyContent: some View {
        Group {
            let _ = {
                if DebugModeManager.isLoggingEnabled() {
                    let branch = viewModel.message != nil ? "content"
                        : (viewModel.messageNotFound ? "notFound" : "skeleton")
                    print("[DetailRender] bodyContent eval branch=\(branch) vm=\(ObjectIdentifier(viewModel)) vmMsgId=\(viewModel.messageId.prefix(40)) header=\(viewModel.message == nil ? "nil" : "set") body=\(viewModel.messageBody == nil ? "nil" : "set")")
                }
            }()
            if let message = viewModel.message {
                messageContent(message)
            } else if viewModel.messageNotFound {
                ContentUnavailableView {
                    Label("Message Not Found", systemImage: "envelope.badge.shield.half.filled")
                } description: {
                    Text("This message may have been moved or deleted.")
                } actions: {
                    Button("Retry") {
                        // retryLoad (NOT loadBody): resets the loadBodyCalled
                        // latch + the memoized failed tap-resolve task — a bare
                        // loadBody() after a failed run is a permanent no-op.
                        Task { await viewModel.retryLoad() }
                    }
                }
            } else {
                // Zero-I/O init: `message` resolves asynchronously (loadBody),
                // typically within the push animation — skeleton, not a spinner,
                // so the swap to content doesn't jump.
                MessageDetailSkeleton()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { contactComposeRequest != nil },
            set: { if !$0 { contactComposeRequest = nil } }
        )) {
            if let request = contactComposeRequest {
                ComposeView(
                    prefillTo: request.to,
                    prefillCc: request.cc.isEmpty ? nil : request.cc,
                    prefillBcc: request.bcc.isEmpty ? nil : request.bcc,
                    prefillSubject: request.subject,
                    prefillBody: request.body
                )
            }
        }
        .fullScreenCover(item: $replyMessage) { msg in
            ComposeView(replyTo: msg)
        }
        .fullScreenCover(item: $replyAllMessage) { msg in
            replyAllComposeView(for: msg)
        }
        .fullScreenCover(item: $forwardMessage) { msg in
            ComposeView(replyTo: msg, isForward: true)
        }
        .fullScreenCover(item: $agentCompose) { req in
            composeViewForAgentRequest(req)
        }
        .onChange(of: AgentToolRouter.shared.pendingCompose?.id) { _, newId in
            if newId != nil {
                agentCompose = AgentToolRouter.shared.pendingCompose
                AgentToolRouter.shared.pendingCompose = nil
            }
        }
        .sheet(item: $moveMessage) { msg in
            MoveFolderPicker(accountId: msg.accountId, currentFolderPath: msg.folderPath) { destinationPath in
                handleMove(msg, toFolderPath: destinationPath)
            }
        }
        .sheet(item: $labelMenuMessage) { msg in
            UserLabelMenuView(messageSnapshot: MessageSnapshot(from: msg))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Main Content (Threaded Conversation)

    /// Build a MessageCardView with all standard callbacks wired up.
    @ViewBuilder
    private func cardView(for msg: MessageHeader, isFocused: Bool) -> some View {
        MessageCardView(
            message: msg,
            viewModel: viewModel,
            isFocused: isFocused,
            isSelected: chatContextMessage?.id == msg.id || (isFocused && chatContextMessage == nil),
            shouldFlash: flashedCardId == msg.id,
            onTagAction: { executeTaggedAction($0) },
            onSelected: { chatContextMessage = $0 },
            onFlashComplete: { flashedCardId = nil },
            onManageLabels: { labelMenuMessage = $0 }
        )
    }

    /// Apply List row styling and native swipe actions to a card.
    @ViewBuilder
    private func cardRow(for msg: MessageHeader, isFocused: Bool) -> some View {
        cardView(for: msg, isFocused: isFocused)
            .id(msg.stableId)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { handleArchive(msg) } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(Theme.archive)
                Button(role: .destructive) { handleDelete(msg) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { handleToggleRead(msg) } label: {
                    Label(msg.isRead ? "Unread" : "Read", systemImage: msg.isRead ? "envelope.badge" : "envelope.open")
                }
                .tint(Theme.accent)
                Button { moveMessage = msg } label: {
                    Label("Move", systemImage: "folder")
                }
                .tint(Palette.untagged)
            }
    }

    /// Pin the focused card to the viewport top without animation (disabled
    /// to avoid a visible snap/flash of the reply bubble).
    private func reanchorFocusedCard(_ proxy: ScrollViewProxy, to stableId: String) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            proxy.scrollTo(stableId, anchor: .top)
        }
    }

    @ViewBuilder
    private func messageContent(_ message: MessageHeader) -> some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                List {
                    // Later/newer messages at top (newest first)
                    ForEach(viewModel.laterMessages.reversed()) { msg in
                        cardRow(for: msg, isFocused: false)
                    }

                    // Focused message (always expanded)
                    cardRow(for: message, isFocused: true)
                        .background(GeometryReader { geo in
                            Color.clear.onAppear { focusedCardHeight = geo.size.height }
                                .onChange(of: geo.size.height) { _, h in focusedCardHeight = h }
                        })

                    // Earlier/older messages below (newest first)
                    ForEach(viewModel.earlierMessages.reversed()) { msg in
                        cardRow(for: msg, isFocused: false)
                    }

                    // Bottom padding — just tall enough so scrollTo(.top) can pin the
                    // focused message at the viewport top, but no taller. This prevents
                    // short messages from having excessive empty space below.
                    Color.clear.frame(height: max(88, listHeight - focusedCardHeight))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable {
                    await viewModel.refetchBody()
                }
                .coordinateSpace(name: "messageList")
                // Drive ScrollFreezeGate: while the user pans/decelerates,
                // AutoSizingHTMLView defers APPLYING changed WKWebView height
                // measurements (a row resizing mid-gesture makes List
                // self-sizing reposition rows under the finger → overlapping
                // cards). Deferred heights flush on return to .idle.
                .onScrollPhaseChange { _, newPhase in
                    if newPhase == .idle {
                        ScrollFreezeGate.shared.end()
                    } else {
                        ScrollFreezeGate.shared.begin()
                    }
                    // .interacting is the user-touch phase — programmatic
                    // scrolls (our own scrollTo calls) don't produce it. Once
                    // the user has taken the wheel, the opening re-anchor
                    // must never fight them again.
                    if newPhase == .interacting {
                        userHasScrolledDetail = true
                        openAnchorArmed = false
                    }
                }
                .background(GeometryReader { geo in Color.clear.onAppear { listHeight = geo.size.height }.onChange(of: geo.size.height) { _, h in listHeight = h } })
                .onPreferenceChange(CardVisibilityKey.self) { cards in
                    // Pick the card with the most visible area in the viewport.
                    let viewportMax = listHeight
                    guard let best = cards.max(by: {
                        let i1 = max(0, min($0.maxY, viewportMax) - max($0.minY, 0))
                        let i2 = max(0, min($1.maxY, viewportMax) - max($1.minY, 0))
                        return i1 < i2
                    }) else { return }
                    guard best.id != chatContextMessage?.id else { return }
                    let allMessages = viewModel.laterMessages + (viewModel.message.map { [$0] } ?? []) + viewModel.earlierMessages
                    if let msg = allMessages.first(where: { $0.id == best.id }) {
                        chatContextMessage = msg
                    }
                }
                .onChange(of: viewModel.laterMessages.count) { _, _ in
                    // Re-anchor when later messages load above (prevents focused card from jumping down).
                    // TWO-PASS: the immediate pass runs in the same transaction as the
                    // bulk insertion, when the List still has ESTIMATED heights for the
                    // inserted rows — a long thread (chat pill opening an old mid-thread
                    // message inserts 30+ collapsed cards above the focused one) lands
                    // the anchor pages off (logmain.log 2026-07-07). The second pass
                    // re-fires on the next run-loop tick, after UIKit laid the inserted
                    // rows out with real heights; one tick is imperceptible, so it
                    // cannot fight a user-initiated scroll.
                    reanchorFocusedCard(proxy, to: message.stableId)
                    Task { @MainActor in
                        reanchorFocusedCard(proxy, to: message.stableId)
                    }
                }
                .onChange(of: focusedCardHeight) { _, _ in
                    // Late-layout re-anchor: on-device the focused row
                    // materializes AFTER the laterMessages insertion (List row
                    // creation + webview sizing land later), so the two-pass
                    // anchor above fires against not-yet-final layout and the
                    // view rests on the thread cards above (logmain.log
                    // 2026-07-07). Every focused-card height change while the
                    // open-anchor is still armed re-pins — armed ends on the
                    // user's first touch (never fights a user scroll) or when
                    // the view goes away.
                    guard openAnchorArmed, !userHasScrolledDetail else { return }
                    guard !viewModel.laterMessages.isEmpty else { return }
                    reanchorFocusedCard(proxy, to: message.stableId)
                }
            }
            .background(Palette.previewPaneBg)
            .overlay {
                // Dimming scrim — blocks all touches behind the expanded chat pill.
                // Tapping the scrim closes the pill. The pill itself is in a higher
                // Z-layer (separate ZStack child) so its elements remain interactive.
                if chatExpanded {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                chatExpanded = false
                            }
                        }
                        .transition(.opacity)
                }
            }

            // Bottom bar: reply + chat + archive/delete/move
            // All actions target the currently active (most-visible) message
            HStack(spacing: chatExpanded ? 0 : 12) {
                Menu {
                    Button { replyMessage = activeMessage } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    Button { replyAllMessage = activeMessage } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                    Button { forwardMessage = activeMessage } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .frame(width: 56, height: 56)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .tint(.primary)
                .menuStyle(.button)
                .accessibilityIdentifier("replyMenu")
                .frame(width: showSideButtons ? nil : 0, height: showSideButtons ? nil : 0)
                .opacity(showSideButtons ? 1 : 0)
                .offset(y: showSideButtons ? 0 : 30)
                .allowsHitTesting(showSideButtons)

                DynamicIslandChat(message: chatContextMessage ?? message, isExpanded: $chatExpanded, isInputFocused: $chatInputFocused, isWorking: $chatWorking, onAgentReply: { text in
                    showAgentToast(text)
                })

                Menu {
                    Button { archiveActiveMessage() } label: { Label("Archive", systemImage: "archivebox") }
                    Button(role: .destructive) { deleteActiveMessage() } label: { Label("Delete", systemImage: "trash") }
                    Button { moveMessage = activeMessage } label: { Label("Move", systemImage: "folder") }
                } label: {
                    Image(systemName: "archivebox")
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .frame(width: 56, height: 56)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .tint(.primary)
                .frame(width: showSideButtons ? nil : 0, height: showSideButtons ? nil : 0)
                .opacity(showSideButtons ? 1 : 0)
                .offset(y: showSideButtons ? 0 : 30)
                .allowsHitTesting(showSideButtons)
            }
            .padding(.bottom, chatExpanded ? 8 : 34)
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: chatExpanded)

            // Agent reply toast — shown when agent finishes while pill is collapsed
            if let toast = agentToast {
                Button {
                    dismissAgentToast()
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        chatExpanded = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(toast.text)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color(hex: 0x323232))
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    )
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, -12)
            }
        }
        .background(Palette.previewPaneBg)
    }

    // MARK: - Agent Toast

    /// Session key for the current message's chat session.
    private var messageSessionKey: String? {
        guard let msg = chatContextMessage ?? viewModel.message else { return nil }
        return "msg:\(msg.accountId):\(msg.stableId)"
    }

    private func showAgentToast(_ text: String) {
        agentToastDismiss?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            agentToast = AgentToastPayload(text: text, sessionKey: messageSessionKey)
        }
        agentToastDismiss = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismissAgentToast()
        }
    }

    private func dismissAgentToast() {
        agentToastDismiss?.cancel()
        agentToastDismiss = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            agentToast = nil
        }
    }

    // MARK: - Active Message (most-visible message for bottom bar actions)

    /// The most-visible message — bottom bar actions target this message.
    var activeMessage: MessageHeader? {
        ActiveMessageResolver.resolve(
            context: chatContextMessage,
            focused: viewModel.message,
            later: viewModel.laterMessages,
            earlier: viewModel.earlierMessages
        )
    }

    /// Subject line of the currently selected (most-visible) message, for the nav bar title.
    var activeSubject: String {
        activeMessage?.subject ?? viewModel.message?.subject ?? ""
    }

    /// Archive the active (most-visible) message. Dismisses if it's the focused message.
    func archiveActiveMessage() {
        guard let msg = activeMessage else { return }
        handleArchive(msg)
    }

    /// Delete the active (most-visible) message. Dismisses if it's the focused message.
    func deleteActiveMessage() {
        guard let msg = activeMessage else { return }
        handleDelete(msg)
    }

    // MARK: - Action Handlers

    private func handleArchive(_ msg: MessageHeader) {
        // archive()/archiveMessage() return false for a no-op (e.g. the message
        // is already in the archive folder) — don't dismiss or flash then.
        if msg.id == viewModel.message?.id {
            if viewModel.archive() {
                dismissMessage()
            }
        } else if viewModel.archiveMessage(msg) {
            flashedCardId = msg.id
        }
    }

    private func handleDelete(_ msg: MessageHeader) {
        // delete()/deleteMessage() return false for a no-op (e.g. the message
        // is already in the trash folder) — don't dismiss or flash then.
        if msg.id == viewModel.message?.id {
            if viewModel.delete() {
                dismissMessage()
            }
        } else if viewModel.deleteMessage(msg) {
            flashedCardId = msg.id
        }
    }

    private func handleMove(_ msg: MessageHeader, toFolderPath: String) {
        // move()/moveMessage() return false when nothing was recorded — don't
        // dismiss or flash then, or the message is hidden from the list with
        // no undo entry (same contract as handleArchive/handleDelete).
        if msg.id == viewModel.message?.id {
            if viewModel.move(toFolderPath: toFolderPath) {
                dismissMessage()
            }
        } else if viewModel.moveMessage(msg, toFolderPath: toFolderPath) {
            flashedCardId = msg.id
        }
    }

    private func handleToggleRead(_ msg: MessageHeader) {
        if msg.id == viewModel.message?.id {
            viewModel.toggleRead()
        } else {
            viewModel.toggleReadForThread(msg)
        }
    }
}
