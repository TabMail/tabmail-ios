/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB
import TipKit

// MARK: - Mailbox Selection

enum MailboxSelection: Hashable {
    case unified(FolderRole)
    case folder(Folder)
    case outbox
    case outboxForAccount(String) // accountId
    case account
    case planPicker
    case prompts
    case settings
    case scheduledTasks
    case reminders
    case calendar
    case contacts
    case debug
}

/// Identifiable wrapper so `.sheet(item:)` can drive `TemplateDetailView`
/// presentation off `MailNavigationView`'s state.
private struct TemplateSheetItem: Identifiable {
    let id: String
}

struct MailNavigationView: View {
    @Environment(NavigationStore.self) private var navigationStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.hasTabMailSession) private var hasTabMailSession
    @Environment(\.scenePhase) private var scenePhase
    var initialSelection: MailboxSelection? = .unified(.inbox)
    @State private var showSignInSheet = false
    /// Mirror of `AISubscriptionGate.shared.isActive`. `@Observable` tracking is
    /// unreliable inside `NavigationSplitView` sidebar content, so we observe the
    /// gate at the body root via `.onChange` below and drive the banner from this
    /// local `@State`. Initial value reads the gate at view-init; `.onChange` and
    /// `.task` keep it in sync as the gate opens/closes.
    @State private var hasActiveSubscription = AISubscriptionGate.shared.isActive
    /// Mirror of `AISubscriptionGate.shared.hasCheckedOnce` (same observation
    /// caveat as `hasActiveSubscription`). Gates the "Start Your Free Trial"
    /// banner: until whoami has authoritatively reported subscription state
    /// at least once (ever, persisted across launches), the banner stays
    /// hidden for signed-in users. Prevents the boot-time flash caused by the
    /// default-closed gate being read before the backend responds.
    @State private var hasCheckedSubscription = AISubscriptionGate.shared.hasCheckedOnce
    /// Emails whose server-side push consent is in `error`/`missing` state per
    /// the most recent foreground scan (or a consent-error notification tap).
    /// Populated by `.pushConsentErrorsDetected`. Empty → banner hidden.
    /// Scan covers Gmail + Outlook.
    @State private var pushConsentErrorEmails: [String] = []
    /// True once the initial consent-status scan for this view has produced
    /// at least one authoritative per-account result (or a cold-start consent-
    /// error notification tap has been consumed). Gates the NSE consent banner
    /// so it doesn't flash on boot when the first scan times out before the
    /// network is warm. See `PushNotificationService.checkPushConsentStatusForForeground`
    /// for the matching first-scan-safety logic on the service side.
    @State private var hasCompletedFirstConsentScan = false
    /// True when the in-app push toggle is ON but iOS has no visual surface
    /// enabled (Banners / Lock Screen / Notification Center all off), so
    /// notifications can't present and the NSE can't run. Drives the "Turn On
    /// Alerts" hint. Local check (reads `UNUserNotificationCenter`), independent
    /// of the network-gated consent scan.
    @State private var visualAlertsHintVisible = false
    /// Gates the hint until `visualAlertsEnabled()` has returned at least once,
    /// so it doesn't flash before the async settings read resolves. Mirrors the
    /// `hasCompletedFirstConsentScan` boot-flash guard above.
    @State private var hasCheckedVisualAlerts = false
    /// Serializes the re-consent sheet. Prevents double-taps from stacking
    /// multiple `ASWebAuthenticationSession` presentations.
    @State private var isFixingPushConsent = false
    /// Address of a newly-added Gmail account awaiting metadata-consent
    /// confirmation. Set by `.pushConsentExplainerNeeded` with
    /// `provider == "gmail"`. Drives the Gmail modal alert below; on
    /// Continue calls `ensurePushConsentAfterAccountAdd`.
    @State private var pendingConsentExplainerEmail: String?
    /// Outlook analogue — set by `.pushConsentExplainerNeeded` with
    /// `provider == "outlook"`. Separate state because the explainer copy +
    /// brand differ per provider; the underlying consent call is unified.
    @State private var pendingOutlookConsentExplainerEmail: String?
    @State private var selection: MailboxSelection?
    @State private var selectedMessageId: String?
    /// Drives a REAL navigation-stack push (`.navigationDestination(item:)`) for
    /// PROGRAMMATIC message opens (chat email-pill taps), completely decoupled
    /// from `selectedMessageId` / the inbox `List(selection:)` binding.
    ///
    /// Why this exists: `selectedMessageId` is also the inbox List's selection
    /// binding (via `listSelectionBinding` in InboxView). A pill open can target
    /// a Sent/Archive/All-Mail message id that is NOT any row in the currently
    /// rendered inbox List. If that happens while the List is mid re-render
    /// (e.g. the concurrent chat-collapse spring animation), SwiftUI reconciles
    /// the foreign selection value away — silently revoking the push within
    /// ~10ms-1s (on-device 2026-07-07, logmain.log lines 918-960 / 1012-1098:
    /// VM created fine, but the row view never evaluates and the VM is
    /// deinit'd). `navigationDestination(item:)` is a genuine stack push the
    /// List has no way to touch, so it survives the concurrent re-render.
    ///
    /// Popping the pushed view (back button / swipe-back) writes `nil` into
    /// this binding automatically — no manual reset needed.
    @State private var pushedMessageId: String?
    /// One-shot guard for `onChange(of: selection)` to suppress the default
    /// "clear detail pane" behavior during programmatic notification-tap
    /// navigation. The handler sets selection + selectedMessageId together
    /// once the async merge+lookup resolves; without this flag the onChange
    /// nils selectedMessageId one render before the assignment lands,
    /// causing a visible inbox-then-detail flash on every tap.
    @State private var isHandlingNotificationDeepLink = false
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var expandedAccounts: Set<String> = []
    @State private var templateSheetItem: TemplateSheetItem?
    private var manager: AccountManager { AccountManager.shared }
    private var state: AccountManagerState { AccountManagerState.shared }

    init(initialSelection: MailboxSelection? = .unified(.inbox)) {
        self.initialSelection = initialSelection
        // If a plan navigation is pending (e.g. from "Start Free Trial" banner),
        // start with nil selection to avoid flashing inbox before navigating to plan.
        if UserDefaults.standard.bool(forKey: "pending_plan_navigation") {
            _selection = State(initialValue: nil)
        } else {
            _selection = State(initialValue: initialSelection)
        }
    }

    /// Roles shown in the unified section, in display order
    private let unifiedRoles: [FolderRole] = [.inbox, .archive, .sent, .drafts, .trash, .spam]

    // Sync status values come from RootView via @Environment so they survive
    // sidebar collapse/unmount. See SyncStatusObservationModifier.
    @Environment(\.syncPhase) private var statusPhase
    @Environment(\.lastSync) private var statusLast
    @Environment(\.syncFailed) private var statusFailed
    @Environment(\.syncNow) private var statusNow

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Group {
                    // Free trial / subscription prompt.
                    // - Signed-out users: always show (the tap routes to sign-in).
                    // - Signed-in users: show only after whoami has authoritatively
                    //   reported subscription state at least once (persisted across
                    //   launches). Before that, `hasActiveSubscription` defaults to
                    //   the last-known value from UserDefaults — on first-ever launch
                    //   that's `false`, which would flash the banner. Gating on
                    //   `hasCheckedSubscription` hides the banner until we know.
                    if !hasTabMailSession || (hasCheckedSubscription && !hasActiveSubscription) {
                        Section {
                            Button {
                                if hasTabMailSession {
                                    selection = .planPicker
                                } else {
                                    UserDefaults.standard.set(true, forKey: "pending_plan_navigation")
                                    showSignInSheet = true
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "sparkles")
                                        .font(.title3)
                                        .foregroundStyle(Palette.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Start Your Free Trial")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Palette.textColor)
                                        Text("Subscribe to unlock AI-powered features")
                                            .font(.caption)
                                            .foregroundStyle(Palette.textMuted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Palette.textMuted)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    // Fix Smart Notifications banner — shown only when the
                    // server-side Gmail push classifier has flagged at least
                    // one account in error state (refresh revoked / Gmail 401/
                    // 404/5xx / etc.). Mirrors the Free Trial banner layout
                    // above. Tap runs the metadata-scope OAuth flow again.
                    // Hidden while offline: the tap launches an OAuth flow
                    // that cannot complete without network, and a consent
                    // banner shown to a user with no internet is a misleading
                    // call-to-action — the real fix is "reconnect to WiFi"
                    // not "re-consent". `NetworkMonitor` is `@Observable`, so
                    // the view re-renders when connectivity flips.
                    if hasCompletedFirstConsentScan
                        && !pushConsentErrorEmails.isEmpty
                        && NetworkMonitor.shared.isConnected {
                        Section {
                            Button {
                                Task { @MainActor in
                                    guard !isFixingPushConsent else { return }
                                    isFixingPushConsent = true
                                    defer { isFixingPushConsent = false }
                                    // Provider-agnostic consent sweep —
                                    // iterates every push-capable account
                                    // (Gmail + Outlook today) and dispatches
                                    // to the correct per-provider OAuth
                                    // flow for any account in error/missing.
                                    _ = await PushNotificationService.shared
                                        .ensurePushConsentForAllAccounts(auth: OAuthService())
                                    // Let the scan's `.onReceive` handler be
                                    // authoritative for banner state — it
                                    // posts the current error-email list,
                                    // which correctly stays populated when
                                    // any account failed to consent (transient
                                    // errors, server misconfiguration, etc).
                                    // Previously we force-cleared to empty
                                    // here, which raced the onReceive and
                                    // hid the banner after failed re-consent
                                    // attempts.
                                    await PushNotificationService.shared
                                        .checkPushConsentStatusForForeground()
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.bubble.fill")
                                        .font(.title3)
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Fix Smart Notifications")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Palette.textColor)
                                        Text(pushConsentErrorEmails.count == 1
                                             ? "Reconnect \(pushConsentErrorEmails[0])"
                                             : "\(pushConsentErrorEmails.count) accounts need to reconnect")
                                            .font(.caption)
                                            .foregroundStyle(Palette.textMuted)
                                    }
                                    Spacer()
                                    if isFixingPushConsent {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Palette.textMuted)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .disabled(isFixingPushConsent)
                        }
                    }

                    // Unified mailboxes
                    if !navigationStore.accounts.isEmpty {
                        Section {
                            ForEach(unifiedRoles, id: \.self) { role in
                                NavigationLink(value: MailboxSelection.unified(role)) {
                                    UnifiedFolderRow(role: role, unreadCount: unreadCount(for: role))
                                }
                            }
                            if !navigationStore.outboxMessages.isEmpty {
                                NavigationLink(value: MailboxSelection.outbox) {
                                    OutboxSidebarRow(count: navigationStore.outboxMessages.count,
                                                     hasFailures: navigationStore.outboxMessages.contains { $0.outboxStatus == .failed })
                                }
                            }
                        }
                    }

                    // Favorite folders
                    if !favoriteFolders.isEmpty {
                        Section("Favorites") {
                            ForEach(favoriteFolders) { folder in
                                NavigationLink(value: MailboxSelection.folder(folder)) {
                                    FolderRow(folder: folder)
                                }
                                .contextMenu {
                                    Button {
                                        Task { await navigationStore.setFavorite(folder, isFavorite: false) }
                                    } label: {
                                        Label("Remove from Favorites", systemImage: "star.slash")
                                    }
                                }
                            }
                        }
                    }

                    // App sections
                    Section {
                        if hasTabMailSession {
                            NavigationLink(value: MailboxSelection.account) {
                                Label("TabMail Account", systemImage: "person.crop.circle")
                            }

                            NavigationLink(value: MailboxSelection.prompts) {
                                Label("TabMail Settings", systemImage: "brain")
                            }
                        } else {
                            Button {
                                showSignInSheet = true
                            } label: {
                                Label("Sign in to TabMail", systemImage: "sparkles")
                            }
                        }

                        NavigationLink(value: MailboxSelection.settings) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label("Email Accounts", systemImage: "at")
                                    Spacer()
                                    // Visual-alerts warning — push is ON but iOS
                                    // has no visual surface enabled, so the NSE
                                    // can't run. Trailing marker (before the
                                    // chevron); the full warning + fix lives in
                                    // Email Accounts settings.
                                    if hasCheckedVisualAlerts && visualAlertsHintVisible {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                            .font(.caption)
                                    }
                                    if UserDefaults.standard.bool(forKey: "isLargeInbox") {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .foregroundStyle(.orange)
                                            .font(.caption)
                                    }
                                }
                                if isBackfillInProgress {
                                    ProgressView(value: aggregateBackfillFraction)
                                        .tint(Theme.accent)
                                        .padding(.top, 2)
                                        .padding(.leading, 8)
                                    Text(backfillStatusText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 8)
                                }
                            }
                        }

                        if hasTabMailSession {
                            // MARK: Scheduled Tasks — HIDDEN on iOS (platform limitation)
                            // Scheduled tasks require client-side tool execution (GRDB, FTS, multi-round
                            // LLM↔tool loop) which cannot run reliably in the background on iOS.
                            // Silent pushes are throttled/dropped overnight by iOS, and the NSE runs in a
                            // separate process without access to the main app's database or actors.
                            // Scheduled tasks remain a Thunderbird-only feature (persistent desktop process).
                            // The code is preserved (not deleted) for potential future use if server-side
                            // tool execution becomes available.
                            // NavigationLink(value: MailboxSelection.scheduledTasks) {
                            //     Label("Scheduled Tasks", systemImage: "calendar.badge.clock")
                            // }

                            NavigationLink(value: MailboxSelection.reminders) {
                                Label("Reminders", systemImage: "bell")
                            }
                            .popoverTip(RemindersMenuTip(), arrowEdge: .bottom)
                        }

                        NavigationLink(value: MailboxSelection.calendar) {
                            Label("Calendar", systemImage: "calendar")
                        }

                        NavigationLink(value: MailboxSelection.contacts) {
                            Label("Contacts", systemImage: "person.crop.circle")
                        }

                        if DebugModeManager.shared.isUnlocked {
                            NavigationLink(value: MailboxSelection.debug) {
                                Label("Debug", systemImage: "ladybug")
                            }
                        }
                    }

                    // Per-account folders (collapsible)
                    ForEach(navigationStore.accounts) { account in
                        Section(isExpanded: Binding(
                            get: { expandedAccounts.contains(account.id) },
                            set: { isExpanded in
                                if isExpanded {
                                    expandedAccounts.insert(account.id)
                                } else {
                                    expandedAccounts.remove(account.id)
                                }
                            }
                        )) {
                            ForEach(foldersFor(account)) { folder in
                                NavigationLink(value: MailboxSelection.folder(folder)) {
                                    FolderRow(folder: folder)
                                }
                                .contextMenu {
                                    Button {
                                        Task { await navigationStore.toggleFavorite(folder) }
                                    } label: {
                                        if folder.isFavorite {
                                            Label("Remove from Favorites", systemImage: "star.slash")
                                        } else {
                                            Label("Add to Favorites", systemImage: "star")
                                        }
                                    }
                                }
                            }
                            let accountOutbox = navigationStore.outboxMessages.filter { $0.accountId == account.id }
                            if !accountOutbox.isEmpty {
                                NavigationLink(value: MailboxSelection.outboxForAccount(account.id)) {
                                    OutboxSidebarRow(count: accountOutbox.count,
                                                     hasFailures: accountOutbox.contains { $0.outboxStatus == .failed })
                                }
                            }
                        } header: {
                            Text(account.emailAddress)
                        }
                    }
                }
                .listRowBackground(Palette.boxBg)
            }
            .navigationTitle("Mailboxes")
            .navigationSubtitle(Text(SyncStatusFormatter.statusText(
                syncPhase: statusPhase,
                lastSyncCompletedAt: statusLast,
                lastSyncFailed: statusFailed,
                now: statusNow
            )).font(.subheadline))
            .scrollContentBackground(.hidden)
            .background(Palette.previewPaneBg)
        } content: {
            // Extracted into separate structs so NavigationStore refreshes in
            // MailNavigationView don't cascade into the content pane.
            // Without this, GRDB ValueObservation updates destroy the
            // NavigationStack in TabMailSettingsView, wiping pushed views.
            //
            // `.navigationDestination(item:)` is attached here — on the content
            // column's root view, outside the `MailContentColumn` selection
            // switch — so it's registered for every content-column selection
            // (inbox, folder, settings, etc), not just the inbox case. See
            // `pushedMessageId` doc comment above for why pill opens use this
            // instead of `selectedMessageId`.
            MailContentColumn(selection: selection, selectedMessageId: $selectedMessageId, pushedMessageId: $pushedMessageId)
                .navigationDestination(item: $pushedMessageId) { id in
                    PushedMessageDestination(messageId: id)
                }
        } detail: {
            // Extracted into a separate struct so NavigationStore refreshes in
            // MailNavigationView don't cascade into the detail pane.
            // SwiftUI skips MessageDetailContainer.body when selectedMessageId
            // hasn't changed, even if the parent re-renders.
            MessageDetailContainer(selectedMessageId: selectedMessageId)
        }
        .background(Palette.previewPaneBg)
        .onChange(of: selection) { _, _ in
            // Clear the detail pane when the user navigates between folders
            // / mailboxes. EXCEPT: when a notification-tap handler programm-
            // atically sets `selection = .unified(.inbox)` alongside a
            // `selectedMessageId` in the same tick, we must not clobber
            // the assignment. `isHandlingNotificationDeepLink` is raised
            // by the handler right before the selection change and lowered
            // right after — gives us a tight window of "this selection
            // change is mine, leave it alone."
            if isHandlingNotificationDeepLink {
                isHandlingNotificationDeepLink = false
            } else {
                selectedMessageId = nil
            }
        }
        .modifier(NavigationNotificationHandlers(selection: $selection))
        .sheet(isPresented: $showSignInSheet) {
            TabMailLoginView {
                showSignInSheet = false
                NotificationCenter.default.post(name: .tabMailDidSignIn, object: nil)
            }
        }
        .onChange(of: AISubscriptionGate.shared.isActive, initial: true) { _, newValue in
            hasActiveSubscription = newValue
        }
        .onChange(of: AISubscriptionGate.shared.hasCheckedOnce, initial: true) { _, newValue in
            hasCheckedSubscription = newValue
        }
        .task {
            // Check if user arrived here after tapping "Start Your Free Trial" banner
            guard UserDefaults.standard.bool(forKey: "pending_plan_navigation") else { return }
            UserDefaults.standard.set(false, forKey: "pending_plan_navigation")
            let aiDisabled = AIService.optOutStore.bool(forKey: AIService.optOutAllAIKey)
            guard !aiDisabled else { return }
            // Brief yield to let the view mount before navigating
            try? await Task.sleep(for: .milliseconds(100))
            selection = .planPicker
        }
        .onReceive(NotificationCenter.default.publisher(for: .emailPillTapped).receive(on: DispatchQueue.main)) { notification in
            // Fallback handler: ensures email navigation works even when InboxView
            // isn't mounted (e.g., user is viewing Settings/Calendar/Contacts).
            // When InboxView IS mounted, both handlers fire — harmless (same state).
            // Uses `pushedMessageId`, NOT `selectedMessageId` — see doc comment
            // on `pushedMessageId` above.
            guard let realId = notification.userInfo?["realId"] as? String else { return }
            pushedMessageId = realId
        }
        .onReceive(NotificationCenter.default.publisher(for: .templatePillOpenTapped).receive(on: DispatchQueue.main)) { notification in
            // Sole sheet host for template-detail. InboxView's matching listener
            // collapses the chat surface; this one presents the detail sheet.
            guard let templateId = notification.userInfo?["templateId"] as? String else { return }
            templateSheetItem = TemplateSheetItem(id: templateId)
            print("[MailNavigationView] Template pill Open Template: \(templateId.prefix(30))")
        }
        .sheet(item: $templateSheetItem) { item in
            NavigationStack {
                TemplateDetailView(templateId: item.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { templateSheetItem = nil }
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .proactiveNotificationTapped).receive(on: DispatchQueue.main)) { notification in
            handleNotificationDeepLink(notification.userInfo)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushConsentErrorsDetected).receive(on: DispatchQueue.main)) { notification in
            if let emails = notification.userInfo?["emails"] as? [String] {
                pushConsentErrorEmails = emails
            }
            // Any post on this notification = authoritative server data
            // (either a consent_error notification tap or a successful scan).
            // The service suppresses posts when no probe was authoritative, so
            // reaching this handler means it's safe to unhide the banner.
            hasCompletedFirstConsentScan = true
            // Drain the cold-start store here too — if the app was ALREADY
            // running when the tap fired (warm path), `.onReceive` handles
            // it immediately, but `AppDelegate.didReceive` still stashed a
            // copy for cold-start safety. Consume so it doesn't leak into
            // a future cold-launch and replay stale state.
            _ = PendingConsentErrorStore.consume()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushConsentExplainerNeeded).receive(on: DispatchQueue.main)) { notification in
            guard let email = notification.userInfo?["email"] as? String,
                  let providerRaw = notification.userInfo?["provider"] as? String else { return }
            // Two alert modifiers because the explainer copy + OAuth
            // provider differ per provider; the notification itself is
            // provider-agnostic.
            switch providerRaw {
            case "gmail":   pendingConsentExplainerEmail = email
            case "outlook": pendingOutlookConsentExplainerEmail = email
            default: break
            }
        }
        .modifier(GmailPushConsentExplainerAlert(email: $pendingConsentExplainerEmail))
        .modifier(OutlookPushConsentExplainerAlert(email: $pendingOutlookConsentExplainerEmail))
        .task {
            // Drain any cold-start consent-error emails stashed by the
            // AppDelegate tap handler (see PendingConsentErrorStore). If
            // the app was launched by tapping a consent_error push, the
            // NotificationCenter event fired before this view mounted, so
            // the live `.onReceive` above missed it.
            let pending = PendingConsentErrorStore.consume()
            if !pending.isEmpty {
                pushConsentErrorEmails = pending
                // Cold-start tap is authoritative (server pushed consent_error
                // to the device). Unhide the banner immediately without waiting
                // for the initial scan below.
                hasCompletedFirstConsentScan = true
            }
            // Initial, non-interactive scan on first appear. Posts
            // `.pushConsentErrorsDetected` when any account is in error;
            // the onReceive above populates the banner state.
            await PushNotificationService.shared.checkPushConsentStatusForForeground()
        }
        // Separate task so the (local, fast) hint check is NOT blocked behind
        // the network-gated consent scan above. See PLAN_NSE_ENHANCE §3.4.
        .task { await refreshVisualAlertsHint() }
        .onChange(of: scenePhase) { _, newPhase in
            // Returning from iOS Settings (where the user may have just toggled
            // Banners / Lock Screen / Notification Center) comes back through
            // scenePhase `.active`. Re-check so the Email Accounts warning icon
            // reflects the current settings. Local + non-blocking. (The
            // silent↔nse re-registration rides the foreground resub in
            // SyncScheduler.startForegroundPolling — see PLAN_NSE_ENHANCE §3.3.)
            if newPhase == .active {
                Task { await refreshVisualAlertsHint() }
            }
        }
        .onChange(of: navigationStore.accounts.isEmpty) { _, isEmpty in
            // Sign-out (or last-account-removed) path: clear banner state.
            // Without this, a pending consent-error from before sign-out
            // would remain visible even though no accounts exist to re-
            // consent. The banner's button would no-op on tap (ensure*
            // iterates an empty account list).
            if isEmpty {
                pushConsentErrorEmails = []
            } else {
                // Sign-back-in or first-account-add path. `.task` above
                // only fires on view mount — when the account list
                // transitions from empty → non-empty while the view is
                // already on screen (e.g., Settings sheet dismissed with a
                // fresh sign-in), re-run the scan so the banner reflects
                // fresh server state.
                Task {
                    await PushNotificationService.shared.checkPushConsentStatusForForeground()
                }
            }
        }
        .onAppear {
            // Consume any deep link stored during cold start (notification tap
            // before MailNavigationView was mounted).
            if let pending = PendingDeepLinkStore.consume() {
                switch pending {
                case .message(let id, let accountId):
                    // Route cold-start message taps through the SAME handler as the
                    // warm path (`.proactiveNotificationTapped`) so they get the
                    // provider-id resolve ladder + account scoping. The old naive
                    // `fetchOne(key: id)` used the PROVIDER id as a composite PK
                    // (never matched) and silently fell back to inbox.
                    var info: [AnyHashable: Any] = ["messageId": id]
                    if let accountId { info["accountId"] = accountId }
                    handleNotificationDeepLink(info)
                case .taskResult(let taskHash):
                    // Navigate to inbox — InboxView handles expanding chat pill via notification
                    selection = .unified(.inbox)
                    print("[MailNav] Cold-start deep link: navigating to inbox for task result \(taskHash)")
                case .inbox:
                    selection = .unified(.inbox)
                    print("[MailNav] Cold-start deep link: navigating to inbox")
                }
            }
        }
    }

    // MARK: - Notification visibility hint

    /// Refresh the visual-alerts warning state from the live iOS notification
    /// settings. `visualAlertsHintVisible` is true when the in-app push toggle
    /// is ON but no visual surface is enabled (so notifications can't present /
    /// the NSE can't run) — it drives the warning icon on the Email Accounts
    /// row. Local + cheap — safe to call on appear and on every foreground.
    @MainActor
    private func refreshVisualAlertsHint() async {
        let toggleOn = UserDefaults.standard.object(forKey: PushConfig.pushNotificationsEnabledKey) as? Bool ?? false
        guard toggleOn else {
            visualAlertsHintVisible = false
            hasCheckedVisualAlerts = true
            return
        }
        let visualOn = await PushNotificationService.shared.visualAlertsEnabled()
        visualAlertsHintVisible = !visualOn
        hasCheckedVisualAlerts = true
    }

    // MARK: - Deep Link

    private func handleNotificationDeepLink(_ userInfo: [AnyHashable: Any]?) {
        // Consume the pending store so onAppear doesn't double-navigate
        _ = PendingDeepLinkStore.consume()

        guard let messageId = userInfo?["messageId"] as? String, !messageId.isEmpty else {
            // No messageId → just land in inbox (no detail to open).
            selection = .unified(.inbox)
            print("[MailNav] Notification deep link: navigating to inbox")
            return
        }

        // Push the detail view IMMEDIATELY — no resolve gates navigation
        // (2026-07-04, boot_logs 7: the old resolve-then-push held the user on
        // the inbox for the whole ladder — 586ms stagedWait, 1.5s+ merge
        // fallback — with nothing on screen). The push payload's `messageId`
        // is the PROVIDER id (Gmail id / Graph AQMk… / IMAP UID), NOT the
        // composite MessageHeader.id the detail view expects:
        // - In-memory staged snapshot hit (fresh push, the common case) →
        //   push the composite id directly, content in the first frame.
        // - Miss → push the sentinel-prefixed provider id; the detail view
        //   shows the loading skeleton while MessageDetailViewModel runs the
        //   resolve ladder (`resolveProviderTap` — durable indexed read →
        //   bounded staged/durable poll → merge fallback) and dissolves to
        //   content. A genuinely-gone message now shows Message-Not-Found
        //   (with Retry) instead of silently landing on the inbox.
        BootProfiler.mark("notifTap: deep link received \(messageId.prefix(24))")
        // `accountId` disambiguates the provider id: an IMAP UID is a per-mailbox
        // small integer that COLLIDES across accounts, so without it a tap on
        // account A's push could open account B's message. Present in the push
        // payload (proven by MARK_READ, `AppDelegate.swift:124`); `nil` only for
        // legacy payloads, which fall back to messageId-only (today's behavior).
        let accountId = userInfo?["accountId"] as? String
        let stagedComposite = NSEDataBridge.latestStagedRows.withLock { rows in
            rows.first {
                $0.messageId == messageId && (accountId == nil || $0.accountId == accountId)
            }?.headerId
        }
        // Commit both state changes in the same tick. Raise the flag first so
        // `.onChange(of: selection)` skips its `selectedMessageId = nil` wipe —
        // otherwise the wipe fires between the two assignments and the detail
        // view momentarily goes blank. ONLY raise it when `selection` actually
        // changes: if it's already `.inbox` (cold-start default, or a tap while
        // already on the inbox), the assignment is a no-op → `.onChange` never
        // fires to lower the flag → it stays stuck `true` and suppresses the NEXT
        // genuine folder-nav wipe, stranding the detail pane on a stale message
        // (multi-column layouts).
        if selection != .unified(.inbox) {
            isHandlingNotificationDeepLink = true
            selection = .unified(.inbox)
        }
        if let id = stagedComposite {
            BootProfiler.mark("notifTap: pushed instantly (staged) \(messageId.prefix(24))")
            selectedMessageId = id
        } else {
            BootProfiler.mark("notifTap: pushed instantly (pending resolve → skeleton) \(messageId.prefix(24))")
            // Sentinel carries accountId so the async resolve ladder stays
            // account-scoped: `notifTap::<accountId>::<providerId>` (accountId is
            // `:`-free per MessageIdentity, so the first `::` is the boundary).
            // Legacy shape `notifTap::<providerId>` when accountId is absent.
            let sentinelPayload = accountId.map { "\($0)::\(messageId)" } ?? messageId
            selectedMessageId = MessageDetailViewModel.notificationTapIdPrefix + sentinelPayload
        }
        print("[MailNav] Notification deep link: navigating to message \(messageId.prefix(30))")
    }

    // MARK: - Helpers

    /// True when ActiveBodyQueue has pending items. Drives sidebar indexing indicator.
    private var isBackfillInProgress: Bool {
        state.isBodyFetchActive
    }

    /// Aggregate backfill fraction across all accounts (folder scan fraction × FTS fraction).
    private var aggregateBackfillFraction: Double {
        let values = Array(state.backfillProgressByAccount.values)
        guard !values.isEmpty else { return 1.0 }
        let totalEmails = values.reduce(0) { $0 + $1.totalEmails }
        let totalIndexed = values.reduce(0) { $0 + $1.ftsIndexed }
        guard totalEmails > 0 else { return 0.0 }
        return min(1.0, Double(totalIndexed) / Double(totalEmails))
    }

    private var backfillStatusText: String {
        let values = Array(state.backfillProgressByAccount.values)
        let totalEmails = values.reduce(0) { $0 + $1.totalEmails }
        let totalIndexed = values.reduce(0) { $0 + $1.ftsIndexed }
        if totalEmails > 0 {
            let pct = Int(Double(totalIndexed) / Double(totalEmails) * 100)
            return "\(totalIndexed.formatted())/\(totalEmails.formatted()) indexed (\(pct)%)"
        }
        return "Email indexing in progress"
    }

    private var favoriteFolders: [Folder] {
        navigationStore.folders.filter { $0.isFavorite }
    }

    private func unreadCount(for role: FolderRole) -> Int {
        navigationStore.folders.filter { $0.role == role }.reduce(0) { $0 + $1.unreadCount }
    }

    private func foldersFor(_ account: Account) -> [Folder] {
        let filtered = navigationStore.folders
            .filter { $0.accountId == account.id }
        let roleOrder: [FolderRole] = [.inbox, .sent, .drafts, .archive, .trash, .spam, .custom]
        return filtered.sorted { a, b in
            let ai = roleOrder.firstIndex(of: a.role) ?? roleOrder.count
            let bi = roleOrder.firstIndex(of: b.role) ?? roleOrder.count
            return ai < bi
        }
    }

}

// MARK: - Navigation Notification Handlers

/// Bundles the sidebar navigation notifications into one modifier. Extracted
/// from `MailNavigationView.body` so the four `.onReceive` handlers don't bloat
/// the already-large body modifier chain past the Swift type-checker's limit.
private struct NavigationNotificationHandlers: ViewModifier {
    @Binding var selection: MailboxSelection?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .navigateToSettings).receive(on: DispatchQueue.main)) { _ in
                selection = .settings
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToAccount).receive(on: DispatchQueue.main)) { _ in
                selection = .account
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToPlanPicker).receive(on: DispatchQueue.main)) { _ in
                selection = .planPicker
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToAIProvider).receive(on: DispatchQueue.main)) { _ in
                // BYOK setup needs BOTH provider selection and keys, which live
                // together in TabMail Settings' "AI Provider" section. Land on
                // that page and flag it to scroll to the section.
                UserDefaults.standard.set(true, forKey: TabMailSettingsView.pendingScrollAIProviderKey)
                selection = .prompts
            }
    }
}

// MARK: - Content Column Container

/// Isolated from MailNavigationView's NavigationStore observation so that GRDB
/// writes don't cascade into the content pane's NavigationStack (which would
/// destroy pushed views like PromptHistoryView).
private struct MailContentColumn: View {
    let selection: MailboxSelection?
    @Binding var selectedMessageId: String?
    @Binding var pushedMessageId: String?

    var body: some View {
        switch selection {
        case .unified, .folder:
            if let selection {
                InboxColumnResolver(selection: selection, selectedMessageId: $selectedMessageId, pushedMessageId: $pushedMessageId)
                    .id(selection)
            }
        case .outbox:
            OutboxView(accountId: nil)
        case .outboxForAccount(let accountId):
            OutboxView(accountId: accountId)
        default:
            SettingsContentColumn(selection: selection)
        }
    }
}

/// Handles non-inbox content selections. Has no NavigationStore dependency,
/// so its body is skipped entirely when selection hasn't changed.
/// No NavigationStack here — the NavigationSplitView provides its own
/// navigation for each column. Adding one causes invisible navigation
/// (no animation, no back button) in compact mode.
private struct SettingsContentColumn: View {
    let selection: MailboxSelection?

    var body: some View {
        switch selection {
        case .account:
            // Show the demo-specific dashboard
            // (calls remaining, exit demo, AI status) when demo is active.
            if DemoModeStore.shared.isActive {
                DemoAccountDashboardView()
            } else {
                AccountDashboardView()
            }
        case .planPicker:
            PlanPickerView()
        case .prompts:
            TabMailSettingsView()
        case .settings:
            SettingsView()
        case .scheduledTasks:
            ScheduledTasksSettingsView()
        case .reminders:
            RemindersSettingsView()
        case .calendar:
            CalendarPickerView()
        case .contacts:
            ContactContainerPickerView()
        case .debug:
            DebugMenuView()
        default:
            ContentUnavailableView("Select a Mailbox", systemImage: "tray", description: Text("Choose a folder from the sidebar"))
        }
    }
}

/// Resolves inbox/folder selection to title + matching folders via NavigationStore.
/// Isolated so only inbox views observe NavigationStore, not settings views.
private struct InboxColumnResolver: View {
    let selection: MailboxSelection
    @Binding var selectedMessageId: String?
    @Binding var pushedMessageId: String?
    @Environment(NavigationStore.self) private var navigationStore

    var body: some View {
        let (title, matchingFolders) = resolve(selection)
        InboxView(title: title, folders: matchingFolders, selection: selection, selectedMessageId: $selectedMessageId, pushedMessageId: $pushedMessageId)
    }

    private func resolve(_ selection: MailboxSelection) -> (String, [Folder]) {
        switch selection {
        case .unified(let role):
            let matching = navigationStore.folders.filter { $0.role == role }
            return (unifiedTitle(for: role), matching)
        case .folder(let folder):
            let fresh = navigationStore.folders.first { $0.id == folder.id } ?? folder
            return (fresh.name, [fresh])
        case .account, .planPicker, .prompts, .settings, .scheduledTasks, .reminders, .calendar, .contacts, .debug, .outbox, .outboxForAccount:
            return ("", [])
        }
    }

    private func unifiedTitle(for role: FolderRole) -> String {
        switch role {
        case .inbox: return "All Inboxes"
        case .archive: return "All Archive"
        case .sent: return "All Sent"
        case .drafts: return "All Drafts"
        case .trash: return "All Trash"
        case .spam: return "All Spam"
        case .custom: return "All Folders"
        }
    }
}

// MARK: - Unified Folder Row

private struct UnifiedFolderRow: View {
    let role: FolderRole
    let unreadCount: Int

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }
        }
    }

    private var title: String {
        switch role {
        case .inbox: return "All Inboxes"
        case .archive: return "All Archive"
        case .sent: return "All Sent"
        case .drafts: return "All Drafts"
        case .trash: return "All Trash"
        case .spam: return "All Spam"
        case .custom: return "All Folders"
        }
    }

    private var icon: String {
        switch role {
        case .inbox: return "tray.2"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .trash: return "trash"
        case .archive: return "archivebox"
        case .spam: return "xmark.bin"
        case .custom: return "folder"
        }
    }
}

// MARK: - Folder Row (per-account)

private struct FolderRow: View {
    let folder: Folder

    var body: some View {
        HStack {
            Image(systemName: iconFor(folder.role))
            Text(folder.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if folder.unreadCount > 0 {
                Text("\(folder.unreadCount)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }
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

// MARK: - Outbox Sidebar Row

private struct OutboxSidebarRow: View {
    let count: Int
    let hasFailures: Bool

    var body: some View {
        HStack {
            Label("Outbox", systemImage: "paperplane.circle")
            Spacer()
            Text("\(count)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(hasFailures ? Color.red : Theme.accent)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Detail Pane Container

/// Isolated from MailNavigationView's observation so that GRDB writes
/// don't cascade into the detail pane. SwiftUI compares `selectedMessageId`
/// (the only stored input) and skips body re-evaluation when it hasn't changed.
private struct MessageDetailContainer: View {
    let selectedMessageId: String?

    var body: some View {
        if let messageId = selectedMessageId {
            MessageDetailResolvedContent(messageId: messageId, opensWithSkeletonDwell: false)
        } else {
            ContentUnavailableView("Select a Message", systemImage: "envelope", description: Text("Choose a message to read"))
        }
    }
}

/// Resolves a concrete (non-nil) message id to its detail content: drafts
/// check + branch between `ServerDraftComposeLoader` (server-draft message,
/// opened as a compose view) and `MessageDetailView` (everything else).
///
/// Shared by two call sites so the drafts-check read logic isn't duplicated:
/// - `MessageDetailContainer` — the detail column's selection-driven content
///   (`selectedMessageId`, i.e. inbox row taps / notification deep links).
/// - `PushedMessageDestination` — the content column's programmatic push
///   (`pushedMessageId`, i.e. chat email-pill opens). See `pushedMessageId`
///   doc comment on `MailNavigationView` for why pill opens use a real
///   navigation push instead of riding `selectedMessageId`.
private struct MessageDetailResolvedContent: View {
    let messageId: String
    let opensWithSkeletonDwell: Bool

    var body: some View {
        // Check if this message is in a Drafts folder — if so, open ComposeView.
        // Single read transaction for consistency (message could be deleted between reads).
        let draftCheck: (header: MessageHeader, isDraft: Bool)? = try? AppDatabase.dbPool.read { db in
            guard let h = try MessageHeader.fetchOne(db, key: messageId) else { return nil }
            let f = try Folder.fetchOne(db, key: h.folderId)
            return (h, f?.role == .drafts)
        }
        if let check = draftCheck, check.isDraft {
            ServerDraftComposeLoader(header: check.header)
                .id(messageId)
        } else {
            MessageDetailView(messageId: messageId, opensWithSkeletonDwell: opensWithSkeletonDwell)
                .id(messageId)
        }
    }
}

/// Destination for programmatic (chat email-pill) message opens, pushed via
/// `.navigationDestination(item: $pushedMessageId)` on the content column's
/// root view. A genuine navigation-stack push — the inbox `List(selection:)`
/// has no way to revoke it. See `pushedMessageId` doc comment on
/// `MailNavigationView` for the full rationale.
private struct PushedMessageDestination: View {
    let messageId: String

    var body: some View {
        MessageDetailResolvedContent(messageId: messageId, opensWithSkeletonDwell: true)
    }
}

/// Loads the body for a server draft message (fetching from server if not cached),
/// then presents ComposeView with the full content. Shows a loading indicator while fetching.
struct ServerDraftComposeLoader: View {
    let header: MessageHeader
    @State private var bodyText: String?
    @State private var matchedDraftId: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading draft...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                composeView
            }
        }
        .task {
            await loadBody()
        }
    }

    /// Resolve the reply-to original message and deterministic draftKey for a draft message.
    /// Uses inReplyTo header to find the original. If not found, falls back to computing
    /// the draftKey from accountId + inReplyTo (which is the parent's rfc822MessageId).
    private func resolveReplyDraft(header: MessageHeader, matchedDraftId: String?) -> (original: MessageHeader?, draftKey: String?) {
        guard let inReplyTo = header.inReplyTo.map({ EmailFilter.normalizeMessageId($0) }), !inReplyTo.isEmpty else {
            return (nil, matchedDraftId)
        }
        let original = try? AppDatabase.dbPool.read { db in
            try MessageHeader.filter(Column("rfc822MessageId") == inReplyTo).fetchOne(db)
        }
        let stableKey: String
        if let original {
            stableKey = "\(original.accountId):\(original.stableId)"
        } else {
            // Original gone — use draft's accountId + inReplyTo as stableKey.
            // inReplyTo IS the parent's rfc822MessageId (same as stableId for IMAP).
            stableKey = "\(header.accountId):\(inReplyTo)"
        }
        let draftKey = matchedDraftId ?? Draft.draftKey(replyTo: stableKey, isForward: false, newId: nil)
        return (original, draftKey)
    }

    private func loadBody() async {
        // Look up matching Draft record — try multiple strategies to link
        // the IMAP draft message back to the local Draft record.
        matchedDraftId = try? await AppDatabase.dbPool.read { db -> String? in
            // Strategy 1: rfc822MessageId match (set by server draft push)
            if let rfc822 = header.rfc822MessageId, !rfc822.isEmpty,
               let draft = try Draft.filter(Column("rfc822MessageId") == rfc822).fetchOne(db) {
                print("[ServerDraftCompose] Matched draft by rfc822MessageId: \(draft.id.prefix(40))")
                return draft.id
            }
            // Strategy 2: serverDraftId match (Gmail/Exchange draft ID stored as messageId)
            let sid = header.messageId
            if let draft = try Draft.filter(Column("serverDraftId") == sid).fetchOne(db) {
                print("[ServerDraftCompose] Matched draft by serverDraftId: \(draft.id.prefix(40))")
                return draft.id
            }
            // Strategy 3: subject + accountId match (fallback when no IMAP headers link)
            // Use exact subject match — draft subject should be identical to IMAP draft.
            if !header.subject.isEmpty,
               let draft = try Draft
                .filter(Column("accountId") == header.accountId)
                .filter(Column("subject") == header.subject)
                .order(Column("updatedAt").desc)
                .fetchOne(db) {
                print("[ServerDraftCompose] Matched draft by subject+account: \(draft.id.prefix(40))")
                return draft.id
            }
            print("[ServerDraftCompose] No draft match found for: subject=\(header.subject.prefix(40)) account=\(header.accountId.prefix(20))")
            return nil
        }

        // Try cached body first
        let cached = try? await AppDatabase.dbPool.read { db in
            try MessageBody.fetchOne(db, key: header.id)?.htmlContent
        }
        if let cached, !cached.isEmpty {
            bodyText = EmailFilter.htmlToPlainText(cached)
            isLoading = false
            return
        }

        // Not cached — fetch from server
        do {
            try await AccountManager.shared.fetchBody(for: header)
            let fetched = try? await AppDatabase.dbPool.read { db in
                try MessageBody.fetchOne(db, key: header.id)?.htmlContent
            }
            bodyText = fetched.map { EmailFilter.htmlToPlainText($0) } ?? ""
        } catch {
            print("[ServerDraftCompose] Failed to fetch body: \(error)")
            bodyText = ""
        }
        isLoading = false
    }

    @ViewBuilder
    private var composeView: some View {
        let text = bodyText ?? ""
        let recipients = Draft.parseRecipients(header.to)
        let resolved = resolveReplyDraft(header: header, matchedDraftId: matchedDraftId)
        let _ = print("[ServerDraftCompose] matchedDraftId=\(matchedDraftId ?? "nil") resolved.draftKey=\(resolved.draftKey ?? "nil") resolved.original=\(resolved.original?.id.prefix(30) ?? "nil") inReplyTo=\(header.inReplyTo ?? "nil")")

        // If a Draft record exists, use DraftComposePresenter which loads all context
        // (reply-to, account, edit history) before creating ComposeView — no black screen.
        if let draftKey = resolved.draftKey ?? matchedDraftId {
            let _ = print("[ServerDraftCompose] Using DraftComposePresenter with key: \(draftKey)")
            DraftComposePresenter(draftId: draftKey, serverDraftHeader: header)
        } else if let original = resolved.original {
            // No Draft record but original message found — fresh compose with reply context
            ComposeView(
                replyTo: original,
                prefillSubject: header.subject,
                prefillBody: text,
                serverDraftHeader: header
            )
        } else {
            // No Draft, no original — fresh compose with prefills from IMAP header
            ComposeView(
                prefillTo: recipients,
                prefillSubject: header.subject,
                prefillBody: text,
                serverDraftHeader: header
            )
        }
    }
}

/// Modal alert presented when a newly-added Gmail account needs metadata
/// consent (NSE toggle is ON). Continue → runs the OAuth + upload flow via
/// `ensurePushConsentAfterAccountAdd`. Cancel → no-op (account stays in
/// `missing` consent state; foreground banner will re-prompt later).
private struct GmailPushConsentExplainerAlert: ViewModifier {
    @Binding var email: String?

    func body(content: Content) -> some View {
        content
            .alert(
                "Enable smart push notifications?",
                isPresented: Binding(
                    get: { email != nil },
                    set: { if !$0 { email = nil } }
                ),
                presenting: email
            ) { presented in
                Button("Cancel", role: .cancel) {
                    email = nil
                }
                Button("Continue") {
                    let target = presented
                    email = nil
                    Task { @MainActor in
                        await runMetadataConsent(forEmail: target)
                    }
                }
            } message: { _ in
                Text("To enable smart push notifications, you need to grant access to email metadata (not bodies) to our servers. The token is stored encrypted.")
            }
    }

    @MainActor
    private func runMetadataConsent(forEmail target: String) async {
        await PushNotificationService.shared.ensurePushConsentAfterAccountAdd(emailAddress: target, auth: OAuthService())
    }
}

/// Outlook analogue of `GmailPushConsentExplainerAlert`.
/// Continue → runs the unified `ensurePushConsentAfterAccountAdd` (which
/// dispatches to the Microsoft OAuth flow for Outlook accounts). Cancel →
/// no-op.
private struct OutlookPushConsentExplainerAlert: ViewModifier {
    @Binding var email: String?

    func body(content: Content) -> some View {
        content
            .alert(
                "Enable smart push notifications?",
                isPresented: Binding(
                    get: { email != nil },
                    set: { if !$0 { email = nil } }
                ),
                presenting: email
            ) { presented in
                Button("Cancel", role: .cancel) {
                    email = nil
                }
                Button("Continue") {
                    let target = presented
                    email = nil
                    Task { @MainActor in
                        await runOutlookMetadataConsent(forEmail: target)
                    }
                }
            } message: { _ in
                Text("To enable smart push notifications, you need to grant access to email metadata (not bodies) to our servers. The token is stored encrypted.")
            }
    }

    @MainActor
    private func runOutlookMetadataConsent(forEmail target: String) async {
        await PushNotificationService.shared.ensurePushConsentAfterAccountAdd(emailAddress: target, auth: OAuthService())
    }
}
