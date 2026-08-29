/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB
import TipKit

enum InboxMode: String, CaseIterable {
    case normal
    case triage
}

/// Presentation decision for the inbox error banner — BOTH halves in one place.
///
/// 🚨 **The debug flag is an ARGUMENT here, never a branch condition in `body`.**
/// Until 2026-08-04 the banner read
/// `if let error = viewModel.error, DebugModeManager.isLoggingEnabled()`, which put
/// the gate in the BRANCH CONDITION: it suppressed no log, it decided whether the
/// banner was built at all. `InboxView` is the ONLY render site of
/// `InboxViewModel.error` in `TabMail/Views/`, so in a production build the banner
/// was unreachable and a user whose sync or infinite-scroll pagination failed got a
/// silent no-op — the list simply stopped growing with no explanation.
/// See `Companion/Memory/Current/105-a-print-is-not-production-observability-on-ios.md`
/// §3 and its 2026-08-04 correction, which names this exact site.
///
/// Shape taken from the sibling that already solved this correctly —
/// `MessageCardView.bodyContent`, byte-identical in shipped `07a4bb703`, in
/// `v2final` and at HEAD: **the BRANCH is ungated so the user always learns
/// something failed, and only the DETAIL is debug-gated**, because
/// `error.localizedDescription` — what both `InboxViewModel` write sites store — is
/// developer text, not user copy.
enum InboxErrorBanner {
    /// Generic production copy. Reuses `MessageCardView`'s existing register
    /// ("Unable to load message. Pull to retry.") rather than inventing a new one;
    /// the inbox and every folder list carry `.refreshable`, so pull-to-refresh is
    /// genuinely the recovery gesture.
    static let genericMessage = "Unable to refresh mail. Pull to retry."

    /// The banner's text, or `nil` when there is nothing to show.
    ///
    /// **Presence depends ONLY on `error`; `loggingEnabled` selects the WORDING.**
    /// That split IS the invariant — a debug unlock must never change whether the
    /// user is told a failure happened. Pinned by `InboxErrorBannerTests`.
    static func text(for error: String?, loggingEnabled: Bool) -> String? {
        guard let error else { return nil }
        return loggingEnabled ? error : genericMessage
    }
}

/// Keeps the already-large InboxView modifier chain below Swift's type-check
/// limit while applying committed primary-key changes to view-owned bindings.
/// The model observes the same notification directly for its loaded/pending
/// state so that production notification delivery is unit-testable.
struct HeaderRekeyReceiver: ViewModifier {
    @Binding var dismissedMessages: Set<String>
    @Binding var swipeFadingMessages: Set<String>
    @Binding var selectedMessageId: String?
    @Binding var pushedMessageId: String?

    func body(content: Content) -> some View {
        // Both production publishers post this notification from MainActor.
        // Keep delivery synchronous so model and view-owned bindings apply one
        // committed transition before the publisher returns.
        content.onReceive(
            NotificationCenter.default.publisher(for: .messageHeadersRekeyed)
        ) { notification in
            handle(notification)
        }
    }

    private func handle(_ notification: Notification) {
        guard let records = notification.object as? [HeaderRekeyRecord],
              !records.isEmpty else { return }
        var dismissed = dismissedMessages
        var fading = swipeFadingMessages
        var selected = selectedMessageId
        var pushed = pushedMessageId
        Self.apply(
            records,
            dismissedMessages: &dismissed,
            swipeFadingMessages: &fading,
            selectedMessageId: &selected,
            pushedMessageId: &pushed)
        dismissedMessages = dismissed
        swipeFadingMessages = fading
        selectedMessageId = selected
        pushedMessageId = pushed
    }

    /// Pure transition seam for the authority split between optimistic action
    /// state and presentation/navigation identity.
    static func apply(
        _ records: [HeaderRekeyRecord],
        dismissedMessages: inout Set<String>,
        swipeFadingMessages: inout Set<String>,
        selectedMessageId: inout String?,
        pushedMessageId: inout String?
    ) {
        // Weak sync correlation may keep presentation identity coherent, but
        // it must not carry optimistic action state across keys. Otherwise an
        // already-deferred gesture can leave the new row hidden even though no
        // provider-authorized operation was recorded.
        let actionRecords = records.filter(\.carriesProviderAuthority)
        dismissedMessages = InboxViewModel.rekeyedHeaderIDs(
            dismissedMessages, using: actionRecords)
        swipeFadingMessages = InboxViewModel.rekeyedHeaderIDs(
            swipeFadingMessages, using: actionRecords)
        let byOldId = Dictionary(
            records.map { ($0.oldHeaderId, $0.newHeaderId) },
            uniquingKeysWith: { first, _ in first })
        if let existingSelected = selectedMessageId, let newId = byOldId[existingSelected] {
            selectedMessageId = newId
        }
        if let existingPushed = pushedMessageId, let newId = byOldId[existingPushed] {
            pushedMessageId = newId
        }
    }
}

struct InboxView: View {
    let title: String
    let folders: [Folder]
    let selection: MailboxSelection
    /// Holder wrapping the `@Observable InboxViewModel` so we can use
    /// `@StateObject` to get Apple's `@autoclosure @escaping`-based
    /// one-time-only initialization. Plain `@State(initialValue: InboxViewModel(...))`
    /// eagerly builds a new VM on every parent re-render — source of the
    /// phantom-VM / rapid-nav stuck-state bug. See `InboxViewModelHolder`.
    @StateObject private var holder: InboxViewModelHolder
    /// Computed shim so existing `viewModel.X` / `$viewModel.X` syntax keeps
    /// working inside `body`. `$vm.X` bindings are obtained via `@Bindable var
    /// vm = viewModel` at the top of `body`.
    private var viewModel: InboxViewModel { holder.vm }
    @State private var moveMessageId: String?
    /// Set when the user taps Move on a collapsed thread row — moves every member
    /// as one grouped action (single undo entry), mirroring archive/delete-thread.
    @State private var moveThreadGroup: ThreadGroup?
    @State private var chatExpanded = false
    @State private var chatInputFocused = false
    @State private var chatWorking = false
    @State private var showSearch = false
    @State private var agentCompose: AgentToolRouter.ComposeRequest?
    @State private var sideButtonsReady = true
    @Binding var selectedMessageId: String?
    /// Real navigation-stack push target for PROGRAMMATIC opens (chat
    /// email-pill taps only). Decoupled from `selectedMessageId` / this
    /// view's `List(selection:)` binding — a pill-opened message id is often
    /// NOT any row in this list (Sent/Archive/All-Mail), and writing a
    /// foreign value into `selectedMessageId` gets reconciled away by
    /// SwiftUI during a concurrent List re-render (e.g. the chat-collapse
    /// spring animation here), silently revoking the open. See the
    /// `pushedMessageId` doc comment on `MailNavigationView` for full
    /// rationale + on-device evidence. Bound through from `MailNavigationView`
    /// via `MailContentColumn` → `InboxColumnResolver`.
    @Binding var pushedMessageId: String?
    @Environment(NavigationStore.self) private var navigationStore
    @Environment(\.hasTabMailSession) private var hasTabMailSession
    // Read sync-status env at struct level so InboxView's body re-runs on any
    // change — needed so the `.toolbar { ... }` content closure re-invokes and
    // the UIKit navigation bar picks up the refreshed subtitle. Reading these
    // inside the ToolbarItem-hosted subview doesn't invalidate reliably.
    @Environment(\.syncPhase) private var syncPhaseEnv
    @Environment(\.lastSync) private var lastSyncEnv
    @Environment(\.syncFailed) private var syncFailedEnv
    @Environment(\.syncNow) private var syncNowEnv

    private var isInboxView: Bool { folders.contains { $0.role == .inbox } }
    @State private var contactComposeRequest: MailtoRequest?
    private var contactComposePresented: Binding<Bool> {
        Binding(
            get: { contactComposeRequest != nil },
            set: { if !$0 { contactComposeRequest = nil } }
        )
    }

    init(title: String, folders: [Folder], selection: MailboxSelection, selectedMessageId: Binding<String?>, pushedMessageId: Binding<String?>) {
        self.title = title
        self.folders = folders
        self.selection = selection
        self._selectedMessageId = selectedMessageId
        self._pushedMessageId = pushedMessageId
        // StateObject(wrappedValue:) is @autoclosure @escaping — the holder
        // (and its inner InboxViewModel) is constructed EXACTLY ONCE per
        // InboxView lifetime, even if the parent re-renders many times.
        self._holder = StateObject(wrappedValue: InboxViewModelHolder(folders: folders, selection: selection))
    }

    /// True when viewing a user-authored folder (Drafts, Sent). Row displays
    /// the recipient instead of the sender — the sender is always the user.
    private var isUserAuthoredFolder: Bool {
        switch selection {
        case .unified(let role):
            return role == .drafts || role == .sent
        case .folder(let f):
            return f.role == .drafts || f.role == .sent
        default:
            return false
        }
    }

    /// True when the current folder is the Drafts folder. Tapping a row here
    /// should open ComposeView as a modal (fullScreenCover from below) instead
    /// of pushing MessageDetailView into the detail pane. Pushing causes the
    /// iPhone-compact NavigationSplitView slide-in-from-right glitch and
    /// inconsistent UX vs. every other compose entry point (Reply, Forward,
    /// new compose — all fullScreenCover).
    private var isDraftsContext: Bool {
        switch selection {
        case .unified(let role):
            return role == .drafts
        case .folder(let f):
            return f.role == .drafts
        default:
            return false
        }
    }

    /// Trash/archive folder contexts: the same-role swipe button stays VISIBLE
    /// but renders grayed out; tapping it no-ops (guards in the handlers) and
    /// just closes the swipe-reveal menu. The Trash button must additionally
    /// drop its `.destructive` role in trash contexts: SwiftUI plays its
    /// automatic row-removal animation for destructive buttons when activated
    /// even if the action body does nothing — in the Trash view this yanked
    /// the row and snapped it back, leaving ghost selection/expansion
    /// artifacts (2026-06-09 report). Archive never showed it because its
    /// button carries no destructive role.
    private var isTrashContext: Bool {
        switch selection {
        case .unified(let role):
            return role == .trash
        case .folder(let f):
            return f.role == .trash
        default:
            return false
        }
    }

    private var isArchiveContext: Bool {
        switch selection {
        case .unified(let role):
            return role == .archive
        case .folder(let f):
            return f.role == .archive
        default:
            return false
        }
    }

    /// Disabled-look background tint for a same-role no-op swipe button.
    private var disabledSwipeTint: Color { Color(.systemGray3) }

    /// Label for a same-role no-op swipe button. Swipe actions force white
    /// symbol rendering and ignore `foregroundStyle` on the label (verified on
    /// device 2026-06-09), so the disabled gray must be baked into the image
    /// itself via `withTintColor(_:renderingMode: .alwaysOriginal)` — the one
    /// rendering path the system can't re-tint. Force-unwrap: the symbol names
    /// are compile-time constants; a typo should fail loudly.
    private func disabledSwipeLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(uiImage: UIImage(systemName: systemImage)!
                .withTintColor(.systemGray, renderingMode: .alwaysOriginal))
        }
    }

    /// Wraps `$selectedMessageId` so a tap inside the Drafts folder is
    /// redirected to `draftHeaderToOpen` (which drives a fullScreenCover),
    /// leaving `selectedMessageId` nil so the detail pane does NOT push.
    private var listSelectionBinding: Binding<String?> {
        Binding(
            get: { selectedMessageId },
            set: { newValue in
                if DebugModeManager.isLoggingEnabled() {
                    print("[DetailRender] listSelectionBinding.set \(String(describing: selectedMessageId?.prefix(40))) -> \(String(describing: newValue?.prefix(40)))")
                }
                if let newId = newValue, isDraftsContext {
                    // Capture the header VALUE at tap time. The cover content must
                    // NOT re-fetch by header id: pushing a draft rekeys its header
                    // (DraftStore.pushDraftToServer migration) and the next Drafts
                    // sync stale-deletes the old row — an id-keyed re-fetch inside
                    // the cover then returns nil and the presented cover renders
                    // empty (solid black, 2026-07-08 bug).
                    if let header = try? AppDatabase.dbPool.read({ db in
                        try MessageHeader.fetchOne(db, key: newId)
                    }) {
                        draftHeaderToOpen = header
                    } else if DebugModeManager.isLoggingEnabled() {
                        print("[DetailRender] drafts tap: header already gone, not presenting id=\(newId.prefix(40))")
                    }
                } else {
                    selectedMessageId = newValue
                }
            }
        )
    }

    @State private var showUndoAlert = false
    @State private var undoAlertActionID: UUID?
    @State private var undoAlertLabel = "Undo last action?"
    @State private var undoAlertStackCount = 0
    /// Reply-all compose target. Holds a VALUE copy of the header captured at
    /// action time (same rule as `draftHeaderToOpen`): the row can be deleted
    /// or UID-rekeyed by sync while the reply compose is open, so the cover
    /// content must never re-fetch it.
    @State private var replyMessage: MessageHeader?
    @State private var dismissedMessages: Set<String> = []
    @State private var swipeFadingMessages: Set<String> = []
    @State private var labelMenuMessage: MessageSnapshot?
    @State private var showLabelFilterPicker = false
    @State private var showFilterBar = false
    @State private var agentToast: AgentToastPayload?
    @State private var agentToastDismiss: Task<Void, Never>?
    @State private var agentDraftIdToOpen: String?
    @State private var showAgentDraft = false
    /// Drafts-folder tap target. Setting this presents ComposeView as a
    /// fullScreenCover (matching every other compose entry point) instead of
    /// pushing MessageDetailView via `selectedMessageId`. Holds a VALUE copy
    /// of the tapped header: the header row itself may be rekeyed/deleted by
    /// draft-push migration + Drafts sync while compose is open, so the
    /// presentation must never depend on re-fetching it.
    @State private var draftHeaderToOpen: MessageHeader?
    private var archiveOldEmailsTip = ArchiveOldEmailsTip()
    private var enableInboxPushTip = EnableInboxPushTip()
    private var undoService: UndoService { UndoService.shared }
    var body: some View {
        // @Bindable creates property-wrapper-style bindings to the inner
        // @Observable's properties. Required so `$vm.filterUnread` etc. work
        // for child views that take `Binding<T>`. Since the inner VM is
        // always non-nil (holder is @StateObject = eager-once init), this
        // is a simple shadow, not an optional unwrap.
        @Bindable var vm = viewModel
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if let bannerText = InboxErrorBanner.text(
                    for: viewModel.error,
                    loggingEnabled: DebugModeManager.isLoggingEnabled()
                ) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(bannerText)
                            .font(.caption)
                        Spacer()
                        Button {
                            viewModel.error = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Theme.errorBg)
                    .foregroundStyle(Theme.errorFg)
                }

                // Usage-throttle banner — surfaces when background AI
                // processing is being throttled (monthly budget exhausted /
                // BYOK on the shared queue). Subtle, non-dismissible; tapping
                // routes to the relevant upgrade/setup screen. Inbox only.
                // Reading the @Observable store directly re-renders on change
                // (same pattern as DemoModeStore.shared below).
                if isInboxView, let throttleKind = UsageThrottleStore.shared.banner {
                    UsageThrottleBanner(kind: throttleKind) {
                        switch throttleKind {
                        case .upgradeToPro:
                            NotificationCenter.default.post(name: .navigateToPlanPicker, object: nil)
                        case .configureKeys:
                            NotificationCenter.default.post(name: .navigateToAIProvider, object: nil)
                        }
                    }
                }

                if isInboxView {
                    TipView(archiveOldEmailsTip)
                        .padding(.horizontal)
                    // Inbox push is a real-account feature with no meaning in
                    // demo mode (no real push registration). Suppress the tip
                    // there — otherwise it shows over the demo inbox AND burns
                    // its single MaxDisplayCount(1) before the user ever has a
                    // real inbox where the tip is actionable.
                    if !DemoModeStore.shared.isActive {
                        TipView(enableInboxPushTip) { action in
                            if action.id == EnableInboxPushTip.openSettingsActionId {
                                enableInboxPushTip.invalidate(reason: .actionPerformed)
                                NotificationCenter.default.post(name: .navigateToSettings, object: nil)
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                Group {
                    switch viewModel.mode {
                    case .normal:
                        normalListView
                            .transition(.blurReplace)
                    case .triage:
                        triageView
                            .transition(.blurReplace)
                    }
                }
            }
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

            // Hit shield: absorbs stray taps in the bottom band so they don't
            // fall through to the list. Sits below the bar/toasts in Z, so
            // buttons, filter chips, "mark all as read", and toasts stay tappable.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 130)
                .contentShape(Rectangle())
                .onTapGesture { }
                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in })
                .padding(.bottom, -40)
                .ignoresSafeArea()

            // Bottom bar + filter chips + mark all as read
            VStack(spacing: 8) {
                // Mark all as read (when unread filter active)
                if viewModel.filterUnread && !chatExpanded && sideButtonsReady && !viewModel.loadedMessages.isEmpty {
                    Button {
                        viewModel.markAllAsRead()
                    } label: {
                        Label("Mark all as read", systemImage: "envelope.open")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Capsule())
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Filter chip bar (when visible)
                if showFilterBar && !chatExpanded && sideButtonsReady {
                    FilterChipBar(
                        filterUnread: $vm.filterUnread,
                        filterLabelIds: $vm.filterLabelIds,
                        accountId: folders.first?.accountId ?? "",
                        onFilterChanged: {
                            viewModel.expandedThreads.removeAll()
                            viewModel.resetMessages()
                        },
                        onOpenLabelPicker: {
                            showLabelFilterPicker = true
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(spacing: 12) {
                if !chatExpanded && sideButtonsReady {
                    // Filter icon — tap to toggle filter bar
                    Button {
                        if showFilterBar {
                            // Hide bar and clear all filters
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                showFilterBar = false
                            }
                            viewModel.clearFilters()
                        } else {
                            // Show bar and activate unread filter
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                showFilterBar = true
                                viewModel.filterUnread = true
                            }
                            viewModel.expandedThreads.removeAll()
                            viewModel.resetMessages()
                        }
                    } label: {
                        Image(systemName: showFilterBar ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.title3)
                            .fontWeight(.medium)
                            .foregroundStyle(showFilterBar ? Theme.accent : .primary)
                            .frame(width: 56, height: 56)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Chat pill hidden when demo + AI off.
                if !(DemoModeStore.shared.isActive && !DemoModeStore.shared.aiEnabled) {
                    DynamicIslandChat(isExpanded: $chatExpanded, isInputFocused: $chatInputFocused, isWorking: $chatWorking, onAgentReply: { text in
                        showAgentToast(text, sessionKey: "inbox")
                    })
                }

                if !chatExpanded && sideButtonsReady {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .frame(width: 56, height: 56)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, chatExpanded ? 8 : 34)
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: chatExpanded)
            }
            // Compact undo chip (below the bottom bar pills)
            if undoService.showToast, let action = undoService.currentAction {
                HStack(spacing: 8) {
                    Text(undoService.undoStack.count > 1 ? "\(action.label) (\(undoService.undoStack.count))" : action.label)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Button("Undo") {
                        let actionID = action.id
                        Task {
                            await undoService.undo(
                                expectedActionID: actionID,
                                source: .compactToast)
                        }
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.archive)
                    Button {
                        undoService.dismissToast()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color(hex: 0x323232))
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                )
                // A new action is a new undo offer, not an update to the old
                // button. Without explicit identity SwiftUI can reuse the
                // transitioning control and retarget an already-recognized
                // touch to the newly pushed action.
                .id(action.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .ignoresSafeArea(.container, edges: .bottom)
                .padding(.bottom, -12)
            }
            // Agent reply toast — tapping deep-links to the relevant chat
            if let toast = agentToast {
                Button {
                    let payload = toast
                    dismissAgentToast()
                    handleAgentToastTap(payload)
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
                .ignoresSafeArea(.container, edges: .bottom)
                .padding(.bottom, -12)
            }
        }
        .background(Color(.systemBackground))
        .dismissKeyboardOnTap()
        .onReceive(NotificationCenter.default.publisher(for: .emailPillTapped).receive(on: DispatchQueue.main)) { notification in
            guard let realId = notification.userInfo?["realId"] as? String else { return }
            // Collapse chat and navigate to the email
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                chatExpanded = false
            }
            // `pushedMessageId`, NOT `selectedMessageId` — see doc comment on
            // `pushedMessageId` above (List(selection:) reconciliation revokes
            // foreign selection values during this concurrent collapse animation).
            pushedMessageId = realId
            print("[DynamicIslandChat] Email pill Open Email: navigating to \(realId.prefix(30))")
        }
        .modifier(CollapseChatOnNavigateModifier(chatExpanded: $chatExpanded))
        .onReceive(NotificationCenter.default.publisher(for: .contactPillComposeTapped).receive(on: DispatchQueue.main)) { notification in
            // When MessageDetailView is pushed (selectedMessageId != nil), let
            // its listener handle the compose so we don't present two covers.
            guard selectedMessageId == nil else { return }
            guard let request = MailtoRequest.from(userInfo: notification.userInfo) else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                chatExpanded = false
            }
            contactComposeRequest = request
            print("[DynamicIslandChat] Contact pill compose: \(request.to.first ?? "")")
        }
        .fullScreenCover(isPresented: contactComposePresented) {
            if let request = contactComposeRequest {
                ComposeView(
                    account: viewModel.primaryAccount,
                    prefillTo: request.to,
                    prefillCc: request.cc.isEmpty ? nil : request.cc,
                    prefillBcc: request.bcc.isEmpty ? nil : request.bcc,
                    prefillSubject: request.subject,
                    prefillBody: request.body
                )
            }
        }
        .toolbarVisibility(chatExpanded && chatInputFocused ? .hidden : .automatic, for: .navigationBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // Toolbar items are wrapped in a .transaction { $0.disablesAnimations
        // = true } inside each ToolbarItem's content view. This is a scoped
        // workaround for a known SwiftUI bug where NavigationSplitView's
        // identity-change-driven view reconstruction fires toolbar-item entry
        // animations on every folder switch. Under rapid nav, those animations
        // get interrupted mid-flight and stick at their first few frames,
        // producing "elongated / half-visible" top-bar buttons. The transaction
        // suppresses the nav-transition-triggered entry animation without
        // affecting the list's `.transition(.blurReplace)` (lives above this
        // scope) or any `withAnimation { }` the buttons themselves invoke
        // (explicit user-triggered animations override the transaction).
        // Refs:
        //   - https://developer.apple.com/forums/thread/728132 (Apple-acknowledged bug)
        //   - https://developer.apple.com/documentation/swiftui/transaction/disablesanimations
        //   - https://www.avanderlee.com/swiftui/disable-animations-transactions/
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(alignment: .leading, spacing: 0) {
                    // DIAGNOSTIC: traces every invocation of the principal
                    // toolbar content closure. If UIKit renders the nav bar
                    // during a stuck state, this log fires each time SwiftUI
                    // hands a toolbar view to UIKit — independent signal from
                    // `normalListView body eval` which sits in the main body
                    // and may be gated/suppressed separately.
                    let _ = BackgroundSyncLogger.logInbox("[\(viewModel.instanceTag)] toolbar.principal eval title=\(title)")
                    Text(title)
                    SyncStatusSubtitle(phase: syncPhaseEnv, last: lastSyncEnv, failed: syncFailedEnv, now: syncNowEnv)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if chatExpanded {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                            chatExpanded = false
                        }
                    }
                }
                .transaction { $0.disablesAnimations = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    collapseChat()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        viewModel.mode = viewModel.mode == .normal ? .triage : .normal
                    }
                    viewModel.expandedThreads.removeAll()
                    viewModel.resetMessages()
                } label: {
                    Image(systemName: viewModel.mode == .normal ? "rectangle.stack" : "list.bullet")
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(viewModel.mode == .normal ? "Switch to triage" : "Switch to list")
                .popoverTip(TriageModeTip(), arrowEdge: .top)
                .transaction { $0.disablesAnimations = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ComposeToolbarButton(onNewCompose: {
                    collapseChat()
                    viewModel.showCompose = true
                })
                .transaction { $0.disablesAnimations = true }
            }
        }
        .fullScreenCover(isPresented: $vm.showCompose) {
            ComposeView(account: viewModel.primaryAccount)
        }
        .sheet(isPresented: Binding(
            get: { moveMessageId != nil || moveThreadGroup != nil },
            set: { if !$0 { moveMessageId = nil; moveThreadGroup = nil } }
        )) {
            moveSheetContent
        }
        .fullScreenCover(item: $replyMessage) { message in
            replyAllComposeView(for: message)
        }
        .fullScreenCover(item: $draftHeaderToOpen) { header in
            ServerDraftComposeLoader(header: header)
        }
        .fullScreenCover(item: $agentCompose) { req in
            composeViewForAgentRequest(req)
        }
        .fullScreenCover(isPresented: $showAgentDraft) {
            if let draftId = agentDraftIdToOpen {
                DraftComposePresenter(draftId: draftId)
            }
        }
        .onChange(of: AgentToolRouter.shared.pendingCompose?.id) { _, newId in
            if newId != nil {
                agentCompose = AgentToolRouter.shared.pendingCompose
                AgentToolRouter.shared.pendingCompose = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentSessionDidFinish).receive(on: DispatchQueue.main)) { notification in
            guard let sessionKey = notification.userInfo?["sessionKey"] as? String else { return }
            if let response = ActiveAgentTracker.shared.consumePendingResponse(sessionKey) {
                showAgentToast(response, sessionKey: sessionKey)
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchView(folders: folders, scopeTitle: title)
        }
        .sheet(item: $labelMenuMessage) { message in
            UserLabelMenuView(messageSnapshot: message)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLabelFilterPicker) {
            LabelFilterPickerView(
                selectedLabelIds: $vm.filterLabelIds,
                accountId: folders.first?.accountId ?? "",
                onChanged: {
                    viewModel.expandedThreads.removeAll()
                    viewModel.resetMessages()
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: navigationStore.folderKeySet) {
            // Re-resolve matching folders when folder list structure OR any folder role changes.
            // Key is a Set so ORDER churn from NavigationStore doesn't trigger spurious reloads
            // — only genuine membership or role changes matter. Without Set, every reorder of
            // the same 5 folders (e.g., NS emits in creation order, VO writes in accountId
            // order) triggered a full reset + fetchPage on MainActor.
            //
            // Note: the folder ValueObservation in InboxViewModel is the authoritative path;
            // this .onChange remains as belt-and-suspenders — updateFolders dedupes by the
            // same Set so double-firing is a no-op.
            let updated: [Folder]
            switch selection {
            case .unified(let role):
                updated = navigationStore.folders.filter { $0.role == role }
            case .folder(let folder):
                if let fresh = navigationStore.folders.first(where: { $0.id == folder.id }) {
                    updated = [fresh]
                } else {
                    updated = [folder]
                }
            default:
                return
            }
            viewModel.updateFolders(updated)
        }
        .onReceive(NotificationCenter.default.publisher(for: .messageDismissedFromDetail).receive(on: DispatchQueue.main)) { notification in
            if let messageId = notification.object as? String {
                // `dismissMessage()`'s MOVE caller (`MessageDetailView.handleMove`) can
                // name a destination THIS list renders — Archive → Inbox from a
                // search-opened detail view — and a dismissal then hides a row that is
                // still a legitimate member of the list. There is no un-dismiss path for
                // a row that simply came back, so it stayed invisible for the life of
                // this `@State`; exit-and-re-enter was the only recovery.
                let destinationFolderId = notification.userInfo?[
                    MessageDetailView.dismissDestinationFolderIdKey] as? String
                if let destinationFolderId, viewModel.displaysFolder(destinationFolderId) {
                    BackgroundSyncLogger.logInbox(
                        "[NoOpGuard] messageDismissedFromDetail suppressed — destination \(destinationFolderId) is a displayed folder: \(messageId)")
                    return
                }
                withAnimation(.easeIn(duration: 0.25)) {
                    _ = dismissedMessages.insert(messageId)
                }
            }
        }
        // ADR-IOS-049: render NSE-staged mail IN-MEMORY before the merge's durable
        // write. Extracted to a ViewModifier so the (already-heavy) body's modifier
        // chain stays under the SwiftUI type-checker's complexity limit.
        .modifier(StagedRowsReceiver(viewModel: viewModel))
        .onReceive(NotificationCenter.default.publisher(for: .messagesUndone).receive(on: DispatchQueue.main)) { notification in
            if let ids = notification.object as? [String] {
                print("[MoveTrace] InboxView.messagesUndone — ids=\(ids) dismissedMessages=\(dismissedMessages)")
                let missing = ids.filter { id in !viewModel.loadedMessages.contains { $0.id == id } }
                print("[MoveTrace] InboxView.messagesUndone — missing from loadedMessages=\(missing.count) loadedCount=\(viewModel.loadedMessages.count)")
                // Single animation transaction: insert missing messages first,
                // then un-dismiss — SwiftUI sees an incremental list change.
                withAnimation(.easeOut(duration: 0.35)) {
                    if !missing.isEmpty {
                        viewModel.insertUndoneMessages(missing)
                    }
                    for id in ids {
                        dismissedMessages.remove(id)
                        swipeFadingMessages.remove(id)
                    }
                }
            }
        }
        .modifier(HeaderRekeyReceiver(
            dismissedMessages: $dismissedMessages,
            swipeFadingMessages: $swipeFadingMessages,
            selectedMessageId: $selectedMessageId,
            pushedMessageId: $pushedMessageId))
        .onDisappear {
            let detailPushed: Bool = selectedMessageId != nil || pushedMessageId != nil
            BackgroundSyncLogger.logInbox("[\(viewModel.instanceTag)] InboxView.onDisappear sideButtonsReady=\(sideButtonsReady) chatExpanded=\(chatExpanded) selection=\(String(describing: selection)) detailPushed=\(detailPushed)")
            // Only hide the side buttons when a detail view is actually being
            // pushed over this (still-alive) view — identifiable by a non-nil
            // selectedMessageId / pushedMessageId at disappear time. The
            // collapsed-split-view push transition fires one SPURIOUS
            // onDisappear on the freshly-appeared page with no re-appear
            // (ADR-IOS-054 amendment; on-device 2026-07-09: every sidebar →
            // inbox entry logs onAppear → listDidAppear → onDisappear in the
            // same runloop while the view stays visible and keeps evaluating
            // body). An unconditional hide here stranded sideButtonsReady=false
            // until the next real pop-back onAppear. Skipping the hide on the
            // remaining non-detail disappears is harmless: a sidebar return
            // DESTROYS this view (fresh @State on next entry), and a
            // pushedShowsAccount cover hides the buttons by covering them.
            if detailPushed {
                sideButtonsReady = false
                chatExpanded = false
            }
            viewModel.listDidDisappear()
        }
        .onAppear {
            BackgroundSyncLogger.logInbox("[\(viewModel.instanceTag)] InboxView.onAppear sideButtonsReady=\(sideButtonsReady) selection=\(String(describing: selection)) hasLoaded=\(viewModel.hasLoadedInitialPage) loadedCount=\(viewModel.loadedMessages.count) folders=\(viewModel.folders.count)")
            // start() registers observers + folder VO, idempotent. Only the VM
            // SwiftUI actually appearance-hooks reaches this — phantom VMs
            // created by SwiftUI's eager @State(initialValue:) evaluation on
            // parent re-renders never get onAppear and therefore never set up
            // observers/VO. See InboxViewModel.init + start() for context.
            viewModel.start()
            // loadInitialPage already ran in VM init — this call is a no-op
            // guard via hasLoadedInitialPage. Kept defensively in case a future
            // refactor moves loadInitialPage out of init.
            viewModel.loadInitialPage()
            viewModel.startSync()
            if isInboxView {
                Task { await viewModel.checkLargeInbox() }
                // Refresh push-enabled parameter so the tip's display rule
                // reflects the current UserDefaults value. Written here (not
                // @AppStorage) to keep the tip gate centralized — the Settings
                // toggle's onChange also pushes the new value.
                EnableInboxPushTip.pushEnabled = UserDefaults.standard.bool(forKey: PushConfig.pushNotificationsEnabledKey)
            }
            Task { await SwipeActionsTip.inboxVisitCount.donate() }

            viewModel.listDidAppear()
            if !sideButtonsReady {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8).delay(0.15)) {
                    sideButtonsReady = true
                }
            }
            // Check for agent responses that arrived while this view was offscreen.
            // The `.onReceive(… .agentSessionDidFinish)` subscription above is torn
            // down when this view leaves the hierarchy, so notifications fired while
            // offscreen are missed. Pending responses are stored in
            // `ActiveAgentTracker` and consumed here on reappear.
            // (⚠ This cited `.task { observeAgentFinish() }` until R17-5. No such
            // symbol has ever existed — `rg 'observeAgentFinish'` returned exactly
            // two hits, this comment and the one in `DynamicIslandChatButton` that
            // pointed back at it. `MIS-009` / `MIS-010`.)
            if let response = ActiveAgentTracker.shared.consumePendingResponse("inbox") {
                showAgentToast(response, sessionKey: "inbox")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .proactiveNotificationTapped).receive(on: DispatchQueue.main)) { notification in
            // Task result deep link — expand chat pill and navigate to the task session
            if notification.userInfo?["expandChat"] as? Bool == true {
                let session = ChatPillState.shared.session(for: "inbox")
                // Force session reload from GRDB
                session.hasLoadedHistory = false

                // If a specific session was specified (task result), navigate to it after load
                if let sessionId = notification.userInfo?["cronHash"] as? String ?? notification.userInfo?["taskHash"] as? String {
                    // After sessions load, find and navigate to this session's page
                    session.pendingNavigateToSession = sessionId
                }

                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    chatExpanded = true
                }
            }
        }
        .onShake {
            if let action = undoService.currentAction {
                undoAlertActionID = action.id
                undoAlertLabel = action.label
                undoAlertStackCount = undoService.undoStack.count
                showUndoAlert = true
            }
        }
        .alert("Undo", isPresented: $showUndoAlert) {
            Button("Undo") {
                guard let actionID = undoAlertActionID else { return }
                undoAlertActionID = nil
                Task {
                    await undoService.undo(
                        expectedActionID: actionID,
                        source: .shakeAlert)
                }
            }
            Button("Cancel", role: .cancel) {
                undoAlertActionID = nil
            }
        } message: {
            Text(undoAlertStackCount > 1
                 ? "\(undoAlertLabel)\n\(undoAlertStackCount) actions remaining"
                 : undoAlertLabel)
        }
    }

    private func collapseChat() {
        if chatExpanded {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                chatExpanded = false
            }
        }
    }

    private func showAgentToast(_ text: String, sessionKey: String? = nil) {
        agentToastDismiss?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            agentToast = AgentToastPayload(text: text, sessionKey: sessionKey)
        }
        agentToastDismiss = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismissAgentToast()
        }
    }

    private func handleAgentToastTap(_ payload: AgentToastPayload) {
        let sessionKey = payload.sessionKey ?? "inbox"
        switch AgentToastPayload.destination(forSessionKey: sessionKey) {
        case .message(let accountId, let stableId):
            // Message-detail session — navigate to the message with chat open.
            Task {
                guard let messageId = try? await lookupMessageId(accountId: accountId, stableId: stableId) else { return }
                // If already viewing this message, just reload + open chat.
                // If different, navigate first (view creation triggers .task { loadBody() }).
                if selectedMessageId != messageId {
                    selectedMessageId = messageId
                    // Wait for new MessageDetailView to mount
                    try? await Task.sleep(for: .milliseconds(400))
                }
                // Tell MessageDetailView to reload body and expand chat
                NotificationCenter.default.post(
                    name: .openMessageWithChat,
                    object: nil,
                    userInfo: ["messageId": messageId]
                )
            }
        case .composeDraft(let draftId):
            // R15-FIX-4b — the draft id now arrives already decoded by the tracker's
            // own parser (see `AgentToastPayload.destination`). This site used to run
            // `String(sessionKey.dropFirst("compose:".count))`, which after PORT
            // 3f2cc4c34 handed `DraftComposePresenter` the whole
            // `<epochByteCount>:<epoch><draftId>` blob: the presenter resolved
            // `.notFound` and dismissed instantly, so the "Draft updated — tap to
            // review" toast opened nothing, for EVERY compose agent session.
            // `v1.6.38` was correct because both ends spelled the same bare format —
            // this is a regression relative to shipped, not a latent edge.
            agentDraftIdToOpen = draftId
            showAgentDraft = true
        case .chatPill:
            // Inbox session or unknown — open the chat pill
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                chatExpanded = true
            }
        }
    }

    /// Look up a message's current GRDB PK by accountId + stableId.
    private func lookupMessageId(accountId: String, stableId: String) async throws -> String? {
        try await AppDatabase.dbPool.read { db in
            try Self.resolveMessageIdByStableId(accountId: accountId, stableId: stableId, db: db)
        }
    }

    /// The RFC arm of the agent-toast lookup, named so plan coverage executes
    /// production SQL. The provider-messageId fallback remains separately expressed.
    nonisolated static let stableIdRfcLookupSQL = """
        SELECT * FROM messageHeader
        WHERE accountId = ? AND rfc822MessageId = ?
        LIMIT 1
        """

    nonisolated static func resolveMessageIdByStableId(
        accountId: String, stableId: String, db: Database
    ) throws -> String? {
        // Try rfc822MessageId first (IMAP stableId)
        let normalized = EmailFilter.normalizeMessageId(stableId)
        if let header = try MessageHeader.fetchOne(
            db, sql: Self.stableIdRfcLookupSQL, arguments: [accountId, normalized]) {
            return header.id
        }
        // Try messageId (Gmail/Exchange)
        if let header = try MessageHeader
            .filter(Column("accountId") == accountId && Column("messageId") == stableId)
            .fetchOne(db) {
            return header.id
        }
        return nil
    }

    private func dismissAgentToast() {
        agentToastDismiss?.cancel()
        agentToastDismiss = nil
        withAnimation(.easeOut(duration: 0.25)) {
            agentToast = nil
        }
    }

    // MARK: - Normal list (iOS Mail style)

    private var normalListView: some View {
        let visibleGroups = viewModel.displayGroups.filter { !dismissedMessages.contains($0.representative.id) }
        // Unconditional render trace — fires on every body eval of normalListView.
        // Distinguishes four states:
        //   EMPTY    : hasLoaded=true, 0 messages (legit empty inbox)
        //   BLANKBUG : hasLoaded=false, 0 messages (pre-load race, should never fire)
        //   FILTERED : has messages but all hidden (dismissed/filter)
        //   OK       : non-empty list rendering normally
        // Frequent, so keep concise.
        let renderState: String
        if viewModel.loadedMessages.isEmpty {
            renderState = viewModel.hasLoadedInitialPage ? "EMPTY" : "BLANKBUG"
        } else if visibleGroups.isEmpty {
            renderState = "FILTERED"
        } else {
            renderState = "OK"
        }
        BackgroundSyncLogger.logInbox("[\(viewModel.instanceTag)] normalListView body eval — \(renderState) loaded=\(viewModel.loadedMessages.count) groups=\(viewModel.displayGroups.count) visible=\(visibleGroups.count) hasLoaded=\(viewModel.hasLoadedInitialPage) dismissed=\(dismissedMessages.count) filterUnread=\(viewModel.filterUnread) chatExpanded=\(chatExpanded)")
        return List(selection: listSelectionBinding) {
            ForEach(visibleGroups) { group in
                let snapshot = group.representative
                let isExpanded = viewModel.expandedThreads.contains(group.id)

                // Thread header row
                ZStack {
                    // Skip the invisible NavigationLink for drafts rows —
                    // `listSelectionBinding` redirects drafts taps to a
                    // fullScreenCover. Leaving the NavigationLink in place
                    // would still push the detail column in parallel,
                    // stranding the user there when the cover dismisses.
                    if !isDraftsContext {
                        NavigationLink(value: snapshot.id) { EmptyView() }
                            .opacity(0)
                    }
                    MessageRowView(
                        message: snapshot, threadInfo: isExpanded ? nil : group.displayInfo,
                        onTagAction: { executeTaggedAction(snapshot, group: isExpanded ? nil : group, expandedGroup: isExpanded && group.isThread ? group : nil) },
                        onRetag: { tag in viewModel.applyManualTag(snapshot.id, tag: tag) },
                        isThread: group.isThread, isExpanded: isExpanded,
                        onThreadToggle: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                viewModel.toggleThreadExpansion(group.id)
                            }
                        },
                        showsRecipientInsteadOfSender: isUserAuthoredFolder
                    )
                }
                .compositingGroup()
                .tag(snapshot.id)
                .opacity(swipeFadingMessages.contains(snapshot.id) ? 0 : 1)
                .onAppear {
                    viewModel.requestSnippetIfNeeded(for: snapshot)
                    if snapshot.actionTag != nil {
                        Task { await TriageModeTip.tagSeen.donate() }
                    }
                }
                .popoverTip(group.id == visibleGroups.first?.id ? SwipeActionsTip() : nil, arrowEdge: .top)
                .contextMenu {
                    Button {
                        labelMenuMessage = snapshot
                    } label: {
                        SwiftUI.Label("Manage Labels...", systemImage: "tag")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    // Same-role no-op buttons stay visible but gray out; the tap
                    // no-ops (handler guards) and just closes the swipe menu.
                    // See isTrashContext for why the destructive role is dropped.
                    Button {
                        if group.isThread && !isExpanded {
                            swipeAndArchiveThread(group)
                        } else {
                            swipeAndArchive(snapshot, expandedGroup: isExpanded && group.isThread ? group : nil)
                        }
                    } label: {
                        if isArchiveContext {
                            disabledSwipeLabel("Archive", systemImage: "archivebox")
                        } else {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                    .tint(isArchiveContext ? disabledSwipeTint : Theme.archive)
                    Button(role: isTrashContext ? nil : .destructive) {
                        if group.isThread && !isExpanded {
                            swipeAndDeleteThread(group)
                        } else {
                            swipeAndDelete(snapshot, expandedGroup: isExpanded && group.isThread ? group : nil)
                        }
                    } label: {
                        if isTrashContext {
                            disabledSwipeLabel("Trash", systemImage: "trash")
                        } else {
                            Label("Trash", systemImage: "trash")
                        }
                    }
                    .tint(isTrashContext ? disabledSwipeTint : .red)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        viewModel.toggleRead(snapshot.id)
                    } label: {
                        Label(
                            snapshot.isRead ? "Unread" : "Read",
                            systemImage: snapshot.isRead ? "envelope.badge" : "envelope.open"
                        )
                    }
                    .tint(Theme.accent)
                    Button {
                        if group.isThread && !isExpanded {
                            moveThreadGroup = group
                        } else {
                            moveMessageId = snapshot.id
                        }
                    } label: {
                        Label("Move", systemImage: "folder")
                    }
                    .tint(Palette.untagged)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 16))
                .modifier(MessageRowBackgroundModifier(
                    members: group.members.map { ($0.accountId, $0.stableId) },
                    isThreadExpanded: isExpanded
                ))
                .listRowSeparator(isExpanded ? .hidden : .automatic, edges: .bottom)
                .listRowSeparator(isExpanded ? .hidden : .automatic, edges: .top)

                // Expanded thread children (compact rows with grouped background)
                if group.isThread && isExpanded {
                    ForEach(group.members.filter { $0.id != snapshot.id && !dismissedMessages.contains($0.id) }) { child in
                        ZStack {
                            if !isDraftsContext {
                                NavigationLink(value: child.id) { EmptyView() }
                                    .opacity(0)
                            }
                            VStack(spacing: 0) {
                                Color(.secondarySystemFill)
                                    .frame(height: 0.5)
                                    .padding(.leading, 40)
                                ThreadChildCardView(message: child, onTagAction: {
                                    executeTaggedAction(child)
                                }, onRetag: { tag in viewModel.applyManualTag(child.id, tag: tag) })
                                    .padding(.leading, 24)
                                    .contextMenu {
                                        Button {
                                            labelMenuMessage = child
                                        } label: {
                                            SwiftUI.Label("Manage Labels...", systemImage: "tag")
                                        }
                                    }
                            }
                        }
                        .compositingGroup()
                        .tag(child.id)
                        .onAppear { viewModel.requestSnippetIfNeeded(for: child) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            // Gray no-op buttons — see head-row swipe actions.
                            Button {
                                swipeAndArchive(child)
                            } label: {
                                if isArchiveContext {
                                    disabledSwipeLabel("Archive", systemImage: "archivebox")
                                } else {
                                    Label("Archive", systemImage: "archivebox")
                                }
                            }
                            .tint(isArchiveContext ? disabledSwipeTint : Theme.archive)
                            Button(role: isTrashContext ? nil : .destructive) {
                                swipeAndDelete(child)
                            } label: {
                                if isTrashContext {
                                    disabledSwipeLabel("Trash", systemImage: "trash")
                                } else {
                                    Label("Trash", systemImage: "trash")
                                }
                            }
                            .tint(isTrashContext ? disabledSwipeTint : .red)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                viewModel.toggleRead(child.id)
                            } label: {
                                Label(
                                    child.isRead ? "Unread" : "Read",
                                    systemImage: child.isRead ? "envelope.badge" : "envelope.open"
                                )
                            }
                            .tint(Theme.accent)
                            Button {
                                viewModel.beginInteraction()
                                moveMessageId = child.id
                                viewModel.endInteraction()
                            } label: {
                                Label("Move", systemImage: "folder")
                            }
                            .tint(Palette.untagged)
                        }
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 16))
                        .listRowBackground(Color(.tertiarySystemFill))
                        .listRowSeparator(.hidden)
                    }
                }
            }

            // Infinite scroll sentinel
            if viewModel.hasMoreMessages {
                Group {
                    if viewModel.isLoadingOlder {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding()
                    } else {
                        Color.clear.frame(height: 1)
                            .onAppear { viewModel.loadMoreMessages() }
                    }
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 106, for: .scrollContent)
        .refreshable { await viewModel.refreshSync() }
        .overlay {
            if viewModel.hasLoadedInitialPage && viewModel.loadedMessages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "tray")
            }
        }
    }

    // MARK: - Triage view (compact tag-sorted list)

    @ViewBuilder
    private var triageView: some View {
        let filtered = viewModel.loadedMessages.filter { !dismissedMessages.contains($0.id) }
        List(selection: listSelectionBinding) {
            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, snapshot in
                // Tags are retained across folders (ADR-IOS-036) but only
                // DISPLAYED for inbox rows — gate every tag used for this
                // row's visuals (stripe, cross-fade, background tint) through
                // ActionTagDisplay.displayedTag so a row that has transiently
                // left the inbox (e.g. mid-drain of an optimistic move still
                // on-screen) cannot leak its retained tag's color.
                let effectiveTag: ActionTag? = ActionTagDisplay.displayedTag(for: snapshot)
                let prevTag: ActionTag? = index > 0 ? ActionTagDisplay.displayedTag(for: filtered[index - 1]) : nil
                let nextTag: ActionTag? = index < filtered.count - 1 ? ActionTagDisplay.displayedTag(for: filtered[index + 1]) : nil
                let fadeTop = effectiveTag != nil && prevTag != effectiveTag
                let fadeBottom = effectiveTag != nil && nextTag != effectiveTag
                ZStack {
                    if !isDraftsContext {
                        NavigationLink(value: snapshot.id) { EmptyView() }
                            .opacity(0)
                    }
                    TriageRowView(message: snapshot, isSelected: selectedMessageId == snapshot.id,
                                  fadeTop: fadeTop, fadeBottom: fadeBottom,
                                  prevTag: prevTag, nextTag: nextTag,
                                  onStripeAction: { executeTaggedAction(snapshot) },
                                  onRetag: { tag in viewModel.applyManualTag(snapshot.id, tag: tag) })
                }
                .compositingGroup()
                .agentWorkingGlow(active: ActiveAgentTracker.shared.isMessageWorking(
                    accountId: snapshot.accountId, stableId: snapshot.stableId
                ))
                .opacity(swipeFadingMessages.contains(snapshot.id) ? 0 : 1)
                .listRowInsets(EdgeInsets())
                .listRowBackground(
                    triageRowBackground(tag: effectiveTag, isSelected: selectedMessageId == snapshot.id,
                                        fadeTop: fadeTop, fadeBottom: fadeBottom,
                                        prevTag: prevTag, nextTag: nextTag)
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    // Gray no-op buttons — see head-row swipe actions.
                    Button {
                        swipeAndArchive(snapshot)
                    } label: {
                        if isArchiveContext {
                            disabledSwipeLabel("Archive", systemImage: "archivebox")
                        } else {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                    .tint(isArchiveContext ? disabledSwipeTint : Theme.archive)
                    Button(role: isTrashContext ? nil : .destructive) {
                        swipeAndDelete(snapshot)
                    } label: {
                        if isTrashContext {
                            disabledSwipeLabel("Trash", systemImage: "trash")
                        } else {
                            Label("Trash", systemImage: "trash")
                        }
                    }
                    .tint(isTrashContext ? disabledSwipeTint : .red)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        viewModel.toggleRead(snapshot.id)
                    } label: {
                        Label(
                            snapshot.isRead ? "Unread" : "Read",
                            systemImage: snapshot.isRead ? "envelope.badge" : "envelope.open"
                        )
                    }
                    .tint(Theme.accent)
                    Button {
                        moveMessageId = snapshot.id
                    } label: {
                        Label("Move", systemImage: "folder")
                    }
                    .tint(Palette.untagged)
                }
            }

            // Infinite scroll sentinel
            if viewModel.hasMoreMessages {
                Group {
                    if viewModel.isLoadingOlder {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding()
                    } else {
                        Color.clear.frame(height: 1)
                            .onAppear { viewModel.loadMoreMessages() }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 106, for: .scrollContent)
        .refreshable { await viewModel.refreshSync() }
        .overlay {
            if viewModel.hasLoadedInitialPage && viewModel.loadedMessages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "tray")
            }
        }
    }

    // MARK: - Triage row background

    @ViewBuilder
    private func triageRowBackground(tag: ActionTag?, isSelected: Bool,
                                     fadeTop: Bool, fadeBottom: Bool,
                                     prevTag: ActionTag?, nextTag: ActionTag?) -> some View {
        if let tag {
            let color = isSelected ? Theme.tagTintSelected(tag) : Theme.tagTint(tag)

            if !fadeTop && !fadeBottom {
                color
            } else {
                ZStack {
                    // Own color — T/2 (0.125) to transparent at list edges, T/4 (0.0625) to half at inter-group
                    LinearGradient(stops: {
                        var stops: [Gradient.Stop] = []
                        if fadeTop {
                            let len: Double = prevTag != nil ? 0.0625 : 0.125
                            let edge: Double = prevTag != nil ? 0.5 : 0
                            stops.append(.init(color: color.opacity(edge), location: 0))
                            stops.append(.init(color: color, location: len))
                        } else {
                            stops.append(.init(color: color, location: 0))
                        }
                        if fadeBottom {
                            let len: Double = nextTag != nil ? 0.0625 : 0.125
                            let edge: Double = nextTag != nil ? 0.5 : 0
                            stops.append(.init(color: color, location: 1 - len))
                            stops.append(.init(color: color.opacity(edge), location: 1))
                        } else {
                            stops.append(.init(color: color, location: 1))
                        }
                        return stops
                    }(), startPoint: .top, endPoint: .bottom)

                    // Previous tag bleeding in at half intensity over T/4
                    if fadeTop, let pt = prevTag {
                        LinearGradient(stops: [
                            .init(color: Theme.tagTint(pt).opacity(0.5), location: 0),
                            .init(color: Theme.tagTint(pt).opacity(0), location: 0.0625),
                        ], startPoint: .top, endPoint: .bottom)
                    }

                    // Next tag bleeding in at half intensity over T/4
                    if fadeBottom, let nt = nextTag {
                        LinearGradient(stops: [
                            .init(color: Theme.tagTint(nt).opacity(0), location: 0.9375),
                            .init(color: Theme.tagTint(nt).opacity(0.5), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                }
            }
        } else {
            Color.clear
        }
    }

    // MARK: - Execute tagged action

    private func executeTaggedAction(_ snapshot: MessageSnapshot, group: ThreadGroup? = nil, expandedGroup: ThreadGroup? = nil) {
        // The badge shown on a collapsed thread row is the thread's highest-priority
        // tag (`group.threadTag`, computed in ThreadGroupBuilder), which can differ
        // from the representative/head message's own tag. Act on the tag the user
        // actually sees and taps — not the head's. For a single message or an
        // expanded thread's individual row, use the message's own tag.
        let tag: ActionTag?
        if let group, group.isThread {
            tag = group.threadTag
        } else {
            tag = snapshot.actionTag
        }
        guard let tag else { return }
        switch tag {
        case .reply:
            // Mark as read — user is actively dismissing (matches TB behavior).
            // Thread reply: set-read on every member so unread siblings don't linger.
            if let group, group.isThread {
                viewModel.markRead(group.members.map(\.id))
            } else if !snapshot.isRead {
                viewModel.toggleRead(snapshot.id)
            }
            // For threads, reply to the most recent message (representative).
            // Capture the header VALUE now (lookupMessage = fresh GRDB read, or
            // the ADR-IOS-049 staged-row synthesis) — the cover must not
            // re-fetch it later.
            replyMessage = viewModel.lookupMessage(snapshot.id)
        case .archive:
            if let group, group.isThread {
                dismissAndArchiveThread(group)
            } else {
                dismissAndArchive(snapshot, markRead: !snapshot.isRead, expandedGroup: expandedGroup)
            }
        case .delete:
            if let group, group.isThread {
                dismissAndDeleteThread(group)
            } else {
                dismissAndDelete(snapshot, markRead: !snapshot.isRead, expandedGroup: expandedGroup)
            }
        case .none:
            // Mark as read — user is actively dismissing (matches TB behavior)
            if !snapshot.isRead { viewModel.toggleRead(snapshot.id) }
        }
    }

    // MARK: - Dismiss animation helpers

    private func logDeleteGestureReceived(
        _ snapshot: MessageSnapshot,
        surface: String,
        fadingBefore: Bool? = nil
    ) {
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] view action=delete surface=\(surface) "
                + "phase=received id=\(snapshot.id)")
        let fading = fadingBefore.map { String($0) } ?? "n/a"
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] view action=delete phase=receivedState "
                + "id=\(snapshot.id) isInInbox=\(snapshot.isInInbox)")
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] view action=delete phase=receivedState "
                + "id=\(snapshot.id) "
                + "dismissedBefore=\(dismissedMessages.contains(snapshot.id)) "
                + "fadingBefore=\(fading)")
    }

    private func dismissAndArchive(_ snapshot: MessageSnapshot, markRead: Bool = false, expandedGroup: ThreadGroup? = nil) {
        // Archive-from-Archive is a no-op — never hide the row.
        guard !viewModel.archiveIsNoOp(snapshot.id) else {
            BackgroundSyncLogger.logInbox("[NoOpGuard] dismissAndArchive suppressed — already archived: \(snapshot.id)")
            return
        }
        withAnimation(.easeIn(duration: 0.25)) {
            _ = dismissedMessages.insert(snapshot.id)
        }
        // Defer model mutations to next run-loop tick so the DB write doesn't
        // trigger a non-animated view invalidation that swallows the dismiss
        // animation of a consecutively-tapped message.
        Task { @MainActor in
            if let group = expandedGroup {
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.evictAndRebuild(snapshot.id, collapseThread: group.id)
                }
            }
            if markRead { viewModel.toggleRead(snapshot.id) }
            // archive() returns false when nothing was recorded (e.g. no
            // archive folder for this account, resolved after the pre-check
            // above raced a concurrent change) — un-hide the row rather than
            // let it vanish forever with no undo entry.
            if !viewModel.archive(snapshot.id) {
                withAnimation(.easeOut(duration: 0.35)) {
                    _ = dismissedMessages.remove(snapshot.id)
                }
            }
        }
    }

    private func dismissAndDelete(_ snapshot: MessageSnapshot, markRead: Bool = false, expandedGroup: ThreadGroup? = nil) {
        logDeleteGestureReceived(snapshot, surface: "tap")
        // Delete-from-Trash is a no-op — never hide the row.
        guard !viewModel.deleteIsNoOp(snapshot.id) else {
            BackgroundSyncLogger.logInbox("[NoOpGuard] dismissAndDelete suppressed — already in trash: \(snapshot.id)")
            return
        }
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] view action=delete surface=tap phase=guardPassed "
                + "id=\(snapshot.id)")
        withAnimation(.easeIn(duration: 0.25)) {
            _ = dismissedMessages.insert(snapshot.id)
        }
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] view action=delete surface=tap phase=hidden "
                + "id=\(snapshot.id) dismissedNow=\(dismissedMessages.contains(snapshot.id))")
        // Defer model mutations to next run-loop tick so the DB write doesn't
        // trigger a non-animated view invalidation that swallows the dismiss
        // animation of a consecutively-tapped message.
        Task { @MainActor in
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] view action=delete surface=tap phase=taskBegin "
                    + "id=\(snapshot.id)")
            if let group = expandedGroup {
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.evictAndRebuild(snapshot.id, collapseThread: group.id)
                }
            }
            if markRead { viewModel.toggleRead(snapshot.id) }
            // delete() returns false when nothing was recorded (e.g. no trash
            // folder for this account, or a draft whose provider-addressed
            // cleanup failed closed) — un-hide the row rather than let it
            // vanish forever with no undo entry.
            let recorded = await viewModel.delete(snapshot.id)
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] view action=delete surface=tap phase=vmReturned "
                    + "id=\(snapshot.id) recorded=\(recorded)")
            if !recorded {
                withAnimation(.easeOut(duration: 0.35)) {
                    _ = dismissedMessages.remove(snapshot.id)
                }
                BackgroundSyncLogger.logInbox(
                    "[RoleActionTrace] view action=delete surface=tap phase=unhidden "
                        + "id=\(snapshot.id) reason=admissionRefused")
            }
        }
    }

    // MARK: - Thread dismiss helpers (archive/delete entire thread)

    /// Content for the Move-to-folder sheet. Presents the thread picker when a
    /// collapsed thread is the target (grouped move), otherwise the single-message
    /// picker. Extracted from `body` to keep the modifier chain type-checkable.
    @ViewBuilder
    private var moveSheetContent: some View {
        if let group = moveThreadGroup, let rep = viewModel.lookupMessage(group.representative.id) {
            MoveFolderPicker(accountId: rep.accountId, currentFolderPath: rep.folderPath) { destinationPath in
                performThreadMove(group, to: destinationPath)
            }
        } else if let id = moveMessageId, let message = viewModel.lookupMessage(id) {
            MoveFolderPicker(accountId: message.accountId, currentFolderPath: message.folderPath) { destinationPath in
                performSingleMove(id, to: destinationPath)
            }
        }
    }

    /// Move a single message to `destinationPath`. Dismisses just that row.
    private func performSingleMove(_ id: String, to destinationPath: String) {
        print("[MoveTrace] MoveFolderPicker.onMove — id=\(id) dest=\(destinationPath) dismissedMessages.count=\(dismissedMessages.count)")
        viewModel.beginInteraction()
        // Hide the row only when the move takes it OUT of the folders this list
        // renders. `MoveFolderPicker` excludes the message's DURABLE folder, not its
        // overlay-adjusted one, so an ADR-IOS-055 P row (durable elsewhere, pinned into
        // the displayed set) is offered the folder it is already showing in — and a
        // dismissal there is permanent. The move itself is unaffected; only the hide is
        // skipped. See `InboxViewModel.displaysFolder`.
        if !viewModel.moveDestinationIsDisplayed(id, toFolderPath: destinationPath) {
            withAnimation(.easeIn(duration: 0.25)) {
                _ = dismissedMessages.insert(id)
            }
        }
        // move() returns false when nothing was recorded (e.g. the message
        // vanished between the picker opening and this tap) — un-hide the row
        // rather than let it vanish forever with no undo entry.
        if !viewModel.move(id, toFolderPath: destinationPath) {
            withAnimation(.easeOut(duration: 0.35)) {
                _ = dismissedMessages.remove(id)
            }
        }
        viewModel.endInteraction()
    }

    /// Move every member of a collapsed thread to `destinationPath` as one grouped
    /// action (single undo entry). Dismisses all member rows together.
    private func performThreadMove(_ group: ThreadGroup, to destinationPath: String) {
        let allIds = group.members.map(\.id)
        viewModel.beginInteraction()
        // Same guard as `performSingleMove`. Asked once for the representative because
        // `moveThread` itself derives ONE `destFolderId` from the first resolved
        // member's account — the members of a thread move share a destination folder.
        if !viewModel.moveDestinationIsDisplayed(
            group.representative.id, toFolderPath: destinationPath) {
            withAnimation(.easeIn(duration: 0.25)) {
                dismissedMessages.formUnion(allIds)
            }
        }
        // moveThread reports back any ids it did NOT act on — un-hide exactly
        // those; they were never queued, so they'd otherwise vanish forever
        // with no undo entry.
        let skipped = viewModel.moveThread(allIds, toFolderPath: destinationPath)
        if !skipped.isEmpty {
            withAnimation(.easeOut(duration: 0.35)) {
                dismissedMessages.subtract(skipped)
            }
        }
        viewModel.endInteraction()
    }

    private func dismissAndArchiveThread(_ group: ThreadGroup) {
        // FU-1: per-member visibility — a thread can span folders of different
        // roles, so an archive-resident REPRESENTATIVE must NOT short-circuit
        // the whole thread. actionableArchiveIds = the members that are NOT a
        // per-member archive no-op; an archive-resident member is a settled
        // no-op that stays VISIBLE (never hidden — nothing happened to it),
        // while an Inbox member of the same thread is still acted upon.
        let actionable = viewModel.actionableArchiveIds(group.members.map(\.id))
        // Empty = the whole thread is a genuine no-op (matches the old
        // representative guard's pure case — nothing hidden).
        guard !actionable.isEmpty else {
            BackgroundSyncLogger.logInbox("[NoOpGuard] dismissAndArchiveThread suppressed — no actionable members (whole thread settled): \(group.representative.id)")
            return
        }
        withAnimation(.easeIn(duration: 0.25)) {
            dismissedMessages.formUnion(actionable)
        }
        Task { @MainActor in
            viewModel.markRead(actionable)
            // archiveThread reports back any ids it did NOT act on — un-hide
            // exactly those so they don't vanish forever with no undo entry.
            let skipped = viewModel.archiveThread(actionable)
            if !skipped.isEmpty {
                withAnimation(.easeOut(duration: 0.35)) {
                    dismissedMessages.subtract(skipped)
                }
            }
        }
    }

    private func dismissAndDeleteThread(_ group: ThreadGroup) {
        // FU-1: per-member visibility — a thread can span folders of different
        // roles, so a trash-resident REPRESENTATIVE must NOT short-circuit the
        // whole thread. actionableDeleteIds = the members that are NOT a
        // per-member delete no-op; a trash-resident member is a settled no-op
        // that stays VISIBLE (never hidden — nothing happened to it), while an
        // Inbox member of the same thread is still acted upon.
        let actionable = viewModel.actionableDeleteIds(group.members.map(\.id))
        // Empty = the whole thread is a genuine no-op (matches the old
        // representative guard's pure case — nothing hidden).
        guard !actionable.isEmpty else {
            BackgroundSyncLogger.logInbox("[NoOpGuard] dismissAndDeleteThread suppressed — no actionable members (whole thread settled): \(group.representative.id)")
            return
        }
        withAnimation(.easeIn(duration: 0.25)) {
            dismissedMessages.formUnion(actionable)
        }
        Task { @MainActor in
            viewModel.markRead(actionable)
            // deleteThread reports back any ids it did NOT act on — un-hide
            // exactly those so they don't vanish forever with no undo entry.
            let skipped = await viewModel.deleteThread(actionable)
            if !skipped.isEmpty {
                withAnimation(.easeOut(duration: 0.35)) {
                    dismissedMessages.subtract(skipped)
                }
            }
        }
    }

    private func swipeAndArchiveThread(_ group: ThreadGroup) {
        // FU-1: per-member visibility (see dismissAndArchiveThread) — an
        // archive-resident member stays VISIBLE (excluded from the hide/act
        // set); only the genuinely-actionable members fade and archive.
        let actionable = viewModel.actionableArchiveIds(group.members.map(\.id))
        guard !actionable.isEmpty else {
            BackgroundSyncLogger.logInbox("[NoOpGuard] swipeAndArchiveThread suppressed — no actionable members (whole thread settled): \(group.representative.id)")
            return
        }

        viewModel.beginInteraction()
        swipeFadingMessages.formUnion(actionable)
        Task { @MainActor in

            withAnimation(.easeIn(duration: 0.25)) {
                dismissedMessages.formUnion(actionable)
            }
            // archiveThread reports back any ids it did NOT act on — un-hide
            // exactly those (both dismissedMessages and swipeFadingMessages,
            // see the formUnion above) so they don't vanish forever with no
            // undo entry.
            let skipped = viewModel.archiveThread(actionable)
            if !skipped.isEmpty {
                withAnimation(.easeOut(duration: 0.35)) {
                    dismissedMessages.subtract(skipped)
                    swipeFadingMessages.subtract(skipped)
                }
            }
            viewModel.endInteraction()
        }
    }

    private func swipeAndDeleteThread(_ group: ThreadGroup) {
        // FU-1: per-member visibility (see dismissAndDeleteThread) — a
        // trash-resident member stays VISIBLE (excluded from the hide/act
        // set); only the genuinely-actionable members fade and delete.
        let actionable = viewModel.actionableDeleteIds(group.members.map(\.id))
        guard !actionable.isEmpty else {
            BackgroundSyncLogger.logInbox("[NoOpGuard] swipeAndDeleteThread suppressed — no actionable members (whole thread settled): \(group.representative.id)")
            return
        }

        viewModel.beginInteraction()
        swipeFadingMessages.formUnion(actionable)
        Task { @MainActor in
            withAnimation(.easeIn(duration: 0.25)) {
                dismissedMessages.formUnion(actionable)
            }
            // deleteThread reports back any ids it did NOT act on — un-hide
            // exactly those (both dismissedMessages and swipeFadingMessages,
            // see the formUnion above) so they don't vanish forever with no
            // undo entry.
            let skipped = await viewModel.deleteThread(actionable)
            if !skipped.isEmpty {
                withAnimation(.easeOut(duration: 0.35)) {
                    dismissedMessages.subtract(skipped)
                    swipeFadingMessages.subtract(skipped)
                }
            }
            viewModel.endInteraction()
        }
    }

    // Swipe-button-tap variants: immediately hide row content so SwiftUI's
    // built-in swipe-close ("snap-back") animation plays on invisible content,
    // then defer row removal to the next run-loop tick so the collapse
    // animation plays in a clean transaction (not batched with the opacity change).
    private func swipeAndArchive(_ snapshot: MessageSnapshot, expandedGroup: ThreadGroup? = nil) {
        // Archive-from-Archive is a no-op — never hide the row.
        guard !viewModel.archiveIsNoOp(snapshot.id) else {
            BackgroundSyncLogger.logInbox("[NoOpGuard] swipeAndArchive suppressed — already archived: \(snapshot.id)")
            return
        }

        viewModel.beginInteraction()
        swipeFadingMessages.insert(snapshot.id)
        Task { @MainActor in

            withAnimation(.easeIn(duration: 0.25)) {
                _ = dismissedMessages.insert(snapshot.id)
            }
            if let group = expandedGroup {
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.evictAndRebuild(snapshot.id, collapseThread: group.id)
                }
            }
            // archive() returns false when nothing was recorded — un-hide
            // the row (both dismissedMessages and swipeFadingMessages) rather
            // than let it vanish forever with no undo entry.
            if !viewModel.archive(snapshot.id) {
                withAnimation(.easeOut(duration: 0.35)) {
                    dismissedMessages.remove(snapshot.id)
                    swipeFadingMessages.remove(snapshot.id)
                }
            }
            viewModel.endInteraction()
        }
    }

    private func swipeAndDelete(_ snapshot: MessageSnapshot, expandedGroup: ThreadGroup? = nil) {
        logDeleteGestureReceived(
            snapshot, surface: "swipe",
            fadingBefore: swipeFadingMessages.contains(snapshot.id))
        // Delete-from-Trash is a no-op — never hide the row.
        guard !viewModel.deleteIsNoOp(snapshot.id) else {
            BackgroundSyncLogger.logInbox("[NoOpGuard] swipeAndDelete suppressed — already in trash: \(snapshot.id)")
            return
        }
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] view action=delete surface=swipe phase=guardPassed "
                + "id=\(snapshot.id)")

        viewModel.beginInteraction()
        swipeFadingMessages.insert(snapshot.id)
        Task { @MainActor in
            withAnimation(.easeIn(duration: 0.25)) {
                _ = dismissedMessages.insert(snapshot.id)
            }
            if let group = expandedGroup {
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.evictAndRebuild(snapshot.id, collapseThread: group.id)
                }
            }
            // delete() returns false when nothing was recorded — un-hide the
            // row (both dismissedMessages and swipeFadingMessages) rather
            // than let it vanish forever with no undo entry.
            let recorded = await viewModel.delete(snapshot.id)
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] view action=delete surface=swipe phase=vmReturned "
                    + "id=\(snapshot.id) recorded=\(recorded)")
            if !recorded {
                withAnimation(.easeOut(duration: 0.35)) {
                    dismissedMessages.remove(snapshot.id)
                    swipeFadingMessages.remove(snapshot.id)
                }
                BackgroundSyncLogger.logInbox(
                    "[RoleActionTrace] view action=delete surface=swipe phase=unhidden "
                        + "id=\(snapshot.id) reason=admissionRefused")
            }
            viewModel.endInteraction()
        }
    }

    // MARK: - Tag context menu (long-press to teach tags)

    // MARK: - Reply All Compose

    private func replyAllComposeView(for msg: MessageHeader) -> some View {
        let recipients = buildReplyAllRecipients(for: msg, allAccounts: navigationStore.accounts)
        return ComposeView(
            replyTo: msg,
            prefillTo: recipients.to.isEmpty ? nil : recipients.to,
            prefillCc: recipients.cc.isEmpty ? nil : recipients.cc
        )
    }

    // MARK: - Agent Tool Compose

    @ViewBuilder
    private func composeViewForAgentRequest(_ req: AgentToolRouter.ComposeRequest) -> some View {
        switch req.mode {
        case .compose:
            ComposeView(
                suggestedBody: req.body,
                account: viewModel.primaryAccount,
                prefillTo: req.to,
                prefillCc: req.cc,
                prefillBcc: req.bcc,
                prefillSubject: req.subject,
                onAgentOutcome: req.onOutcome
            )
        case .reply:
            ComposeView(
                replyTo: req.replyTo,
                suggestedBody: req.body,
                prefillTo: req.to.isEmpty ? nil : req.to,
                prefillCc: req.cc.isEmpty ? nil : req.cc,
                prefillBcc: req.bcc.isEmpty ? nil : req.bcc,
                onAgentOutcome: req.onOutcome
            )
        case .forward:
            ComposeView(
                replyTo: req.replyTo,
                suggestedBody: req.body,
                isForward: true,
                prefillTo: req.to,
                prefillCc: req.cc,
                prefillBcc: req.bcc,
                onAgentOutcome: req.onOutcome
            )
        }
    }
}

// MARK: - Move Folder Picker

struct MoveFolderPicker: View {
    let accountId: String
    let currentFolderPath: String
    let onMove: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var partitioned: (favorites: [Folder], others: [Folder]) {
        let folders = (try? AppDatabase.dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId).order(Column("name")).fetchAll(db)
        }) ?? []
        return Self.partition(folders: folders, currentFolderPath: currentFolderPath)
    }

    private var favoriteFolders: [Folder] { partitioned.favorites }
    private var otherFolders: [Folder] { partitioned.others }

    /// Pure helper: filter out the current folder, sort by role, then split into
    /// (favorites, others) preserving the role-sorted order within each group.
    /// `nonisolated` so unit tests (running on a cooperative-pool task, not the
    /// main actor) can call it without tripping `_swift_task_checkIsolatedSwift`.
    nonisolated static func partition(folders: [Folder], currentFolderPath: String) -> (favorites: [Folder], others: [Folder]) {
        let sorted = folders
            .filter { $0.path != currentFolderPath }
            .sorted { folderOrder($0.role) < folderOrder($1.role) }
        return (
            favorites: sorted.filter { $0.isFavorite },
            others: sorted.filter { !$0.isFavorite }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if !favoriteFolders.isEmpty {
                    Section("Favorites") {
                        ForEach(favoriteFolders) { folder in
                            folderButton(folder)
                        }
                    }
                    Section("All Folders") {
                        ForEach(otherFolders) { folder in
                            folderButton(folder)
                        }
                    }
                } else {
                    ForEach(otherFolders) { folder in
                        folderButton(folder)
                    }
                }
            }
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func folderButton(_ folder: Folder) -> some View {
        Button {
            onMove(folder.path)
            dismiss()
        } label: {
            HStack {
                Label(folder.name, systemImage: iconFor(folder.role))
                Spacer()
                if folder.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
        }
    }

    nonisolated static func folderOrder(_ role: FolderRole) -> Int {
        switch role {
        case .inbox: return 0
        case .archive: return 1
        case .sent: return 2
        case .drafts: return 3
        case .trash: return 4
        case .spam: return 5
        case .custom: return 6
        }
    }

    private func iconFor(_ role: FolderRole) -> String {
        switch role {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .trash: return "trash"
        case .archive: return "archivebox"
        case .spam: return "xmark.bin"
        case .custom: return "folder"
        }
    }
}

// MARK: - Conditional listRowBackground

private extension View {
    /// Apply `.listRowBackground` only when `condition` is true.
    /// When false, no `.listRowBackground` is called at all, preserving native
    /// tap/selection highlights that get killed by any `.listRowBackground` call.
    @ViewBuilder
    func listRowBackgroundIf<V: View>(_ condition: Bool, @ViewBuilder background: () -> V) -> some View {
        if condition {
            self.listRowBackground(background())
        } else {
            self
        }
    }
}

/// Payload for agent completion toasts. Carries the session key for deep-linking.
struct AgentToastPayload {
    let text: String
    let sessionKey: String?
}

/// Where a tapped agent completion toast sends the user.
enum AgentToastDestination: Equatable {
    case message(accountId: String, stableId: String)
    case composeDraft(draftId: String)
    /// Inbox session, or a key no live decoder recognises.
    case chatPill
}

extension AgentToastPayload {
    /// R15-FIX-4b — the toast's routing decision, as a pure function.
    ///
    /// This lives outside `InboxView.handleAgentToastTap` for exactly one reason:
    /// the compose branch is a DECODER whose encoder lives in another file, and a
    /// decoder no test can call is a decoder that silently rots when the encoder
    /// moves — which is precisely what happened. PORT 3f2cc4c34 re-shaped
    /// `ActiveAgentTracker.composeSessionKey` and ported the tracker's own consumer,
    /// while the view's copy kept decoding the OLD bare format; the round-trip that
    /// would have caught it could not be written because the only consumer was
    /// private to a SwiftUI view. Same extraction rationale as `ComposeDraftGuards`.
    ///
    /// Every branch delegates to the symbol that OWNS the format — never to a
    /// re-spelling of it here. A key neither decoder claims routes to `.chatPill`,
    /// the pre-existing safe landing spot for unknown keys: an undecodable key names
    /// no draft, and opening a presenter that instantly dismisses is worse than
    /// expanding the chat pill.
    /// `@MainActor` only because `ActiveAgentTracker.messageStableId` inherits the
    /// tracker's actor isolation; the decision itself touches no mutable state.
    @MainActor
    static func destination(forSessionKey sessionKey: String) -> AgentToastDestination {
        if let parsed = ActiveAgentTracker.messageStableId(from: sessionKey) {
            return .message(accountId: parsed.accountId, stableId: parsed.stableId)
        }
        if let parsed = ActiveAgentTracker.parseComposeSession(sessionKey) {
            return .composeDraft(draftId: parsed.draftId)
        }
        return .chatPill
    }
}

/// Combined row background: agent glow (accent tint pulse) + thread expanded fill.
/// Uses `.listRowBackground()` so the glow fills the entire row area including insets.
private struct MessageRowBackgroundModifier: ViewModifier {
    let members: [(accountId: String, stableId: String)]
    let isThreadExpanded: Bool

    func body(content: Content) -> some View {
        let sessions = ActiveAgentTracker.shared.workingSessions
        let isAgentActive = members.contains { sessions.contains("msg:\($0.accountId):\($0.stableId)") }

        if isAgentActive {
            content.listRowBackground(AgentWorkingRowBackground(active: true))
        } else if isThreadExpanded {
            content.listRowBackground(Color(.tertiarySystemFill))
        } else {
            content
        }
    }
}

/// Collapses the chat pill when navigation is about to replace/cover this view:
/// a template chip's "Open Template" tap, or the WarningBubble's "TabMail
/// Account" tap (`.navigateToAccount` → a REAL push in MailNavigationView,
/// ADR-IOS-054 pattern — the push survives this concurrent collapse animation;
/// the old `selection = .account` write did not). Extracted as a ViewModifier
/// (and kept to a SINGLE `.modifier()` entry) to keep `InboxView.body`'s
/// modifier chain inside Swift's type-check budget — even one more inline
/// `.onReceive` or `.modifier` pushed it over the edge.
private struct CollapseChatOnNavigateModifier: ViewModifier {
    @Binding var chatExpanded: Bool

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .templatePillOpenTapped)
                .merge(with: NotificationCenter.default.publisher(for: .navigateToAccount))
                .receive(on: DispatchQueue.main)
        ) { _ in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                chatExpanded = false
            }
        }
    }
}

/// ADR-IOS-049: receives `.messagesStaged` (NSE-staged mail) and inserts the rows
/// into the inbox IN-MEMORY, before the merge's durable write. PLAN_INBOX_UNIFIED_READ.md
/// §3: the companion `.stagedRowsInvalidated` eviction path is gone — a staged
/// row later found STALE-BY-MOVE is scrubbed from `NSEDataBridge.latestStagedRows`
/// and suppressed by the reader on the next reload instead (§2.1a). Kept as its
/// own `ViewModifier` (like `CollapseChatOnNavigateModifier`) so this stays a
/// SINGLE entry in `InboxView`'s modifier chain — `InboxView`'s large body
/// stays under the SwiftUI type-checker complexity limit (an inline
/// `.onReceive`, or one more chain entry, tipped it over previously).
private struct StagedRowsReceiver: ViewModifier {
    let viewModel: InboxViewModel
    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .messagesStaged)
                .receive(on: DispatchQueue.main)
        ) { notification in
            if let rows = notification.object as? [StagedInboxRow] {
                viewModel.insertStagedRows(rows)
            }
        }
    }
}
