/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB
import TipKit

/// Set to `true` to force both consent gate and AI consent to show on every launch (for UI testing).
/// Resets the AppStorage flags at init so the real flow runs each time.
/// Set to `false` (or remove) once testing is done.
private let DEBUG_ALWAYS_SHOW_GATES = false

struct RootView: View {
    @Environment(NavigationStore.self) private var navigationStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasTabMailSession = ScreenshotMode.isActive || TabMailAuthService.hasSession()
    @AppStorage("hasCompletedConsentGate") private var hasCompletedConsentGate = false
    @AppStorage("hasSeenAIConsent") private var hasSeenAIConsent = false
    @AppStorage("hasSeenPushConsent") private var hasSeenPushConsent = false
    // Demo Mode gate persistence.
    // Production gates above stay untouched while demo runs.
    @AppStorage("demo.hasCompletedConsentGate") private var demoHasCompletedConsentGate = false
    @AppStorage("demo.hasSeenAIConsent") private var demoHasSeenAIConsent = false
    @AppStorage("demo.aiEnabled") private var demoAiEnabled = false
    @State private var demoSeedingComplete = false
    @State private var demoStartError: String?
    @Bindable private var demoStore = DemoModeStore.shared
    /// Stays false until one-time migrations finish.
    /// Provider connections + sync run in the background after the UI is visible.
    /// For returning users (system-kill restart), defaults to true so the inbox
    /// appears immediately without a splash screen flash.
    @State private var isStartupComplete: Bool
    /// Pending account deletion state (checked on every launch)
    @State private var pendingDeletionDate: String?
    /// iCloud setup prompt state (Feature 2 — post-Apple sign-in)
    @State private var showAccountGoneAlert = false
    @State private var showSignedOutAlert = false
    /// True while checking /whoami for prior consent — show splash instead of consent gate
    @State private var isCheckingConsent = false

    // MARK: - Undo-send toast state
    /// Snapshot of the cancelled send's contents. PendingSendService.undo()
    /// deletes the Draft row + discards the outbox row; this snapshot is what
    /// RootView uses to present a fresh ComposeView with prefill args so the
    /// user's content is restored. Because the Draft is gone, the reopened
    /// compose's close-action runs through the normal save-draft prompt.
    @State private var reopenSnapshot: PendingSendService.ReopenSnapshot?
    private var pendingSendService: PendingSendService { PendingSendService.shared }

    /// Sync status values — observed once here and published to descendants via
    /// Environment. Centralising here keeps the observer alive across sidebar
    /// unmounts and gives both InboxView and MailNavigationView the same feed.
    @State private var syncStatusPhase: SyncPhase?
    @State private var syncStatusLast: Date?
    @State private var syncStatusFailed = false
    @State private var syncStatusNow = Date()

    private let syncScheduler = SyncScheduler.shared

    init() {
        // Debug: reset gate flags on every launch so all gate screens show
        if DEBUG_ALWAYS_SHOW_GATES {
            UserDefaults.standard.set(false, forKey: "hasCompletedConsentGate")
            UserDefaults.standard.set(false, forKey: "hasSeenAIConsent")
            UserDefaults.standard.set(false, forKey: "hasSeenPushConsent")
        }

        // For returning users (system-kill restart), skip the splash screen entirely.
        // The GRDB data is already on disk — show the inbox immediately with cached data.
        // Fresh installs (no DB, no consent) will go through the normal gated flow.
        let onboardingDone = UserDefaults.standard.bool(forKey: "hasCompletedConsentGate")
            && UserDefaults.standard.bool(forKey: "hasSeenAIConsent")
            && UserDefaults.standard.bool(forKey: "hasSeenPushConsent")
            && !DEBUG_ALWAYS_SHOW_GATES
        let isReturningUser = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
            && onboardingDone
        _isStartupComplete = State(initialValue: isReturningUser)

    }

    private var hasEmailAccounts: Bool {
        navigationStore.isInitialLoadComplete && !navigationStore.accounts.isEmpty
    }

    @ViewBuilder
    private var routedContent: some View {
        // Demo mode wins over all other routing. Runs the SAME consent + AI
        // gates as production but writes to demo-prefixed AppStorage so
        // production flags survive demo entry/exit untouched.
        if demoStore.isActive {
            if !demoHasCompletedConsentGate {
                ConsentGateView(persistsToBackend: false) {
                    withAnimation { demoHasCompletedConsentGate = true }
                }
            } else if !demoHasSeenAIConsent {
                AIConsentView { aiEnabled in
                    demoAiEnabled = aiEnabled
                    // Critical: NEVER write to AIService.optOutAllAIKey here.
                    // Demo's AI choice lives entirely in demo.aiEnabled.
                    withAnimation { demoHasSeenAIConsent = true }
                }
            } else if !demoSeedingComplete {
                DemoSeedingSplash()
                    .task(id: demoStore.isActive) {
                        guard demoStore.isActive, !demoSeedingComplete else { return }
                        do {
                            try await DemoModeService.shared.completeSetup()
                            withAnimation { demoSeedingComplete = true }
                        } catch {
                            print("[RootView] Demo setup failed: \(error)")
                            demoStartError = error.localizedDescription
                            await DemoModeService.shared.exit()
                        }
                    }
            } else {
                MailNavigationView()
            }
        } else if hasEmailAccounts && !hasTabMailSession {
                // Email-only mode: accounts exist but no TabMail session (post-sign-out).
                // Skip all TabMail gates (consent, AI consent) — go straight to sidebar.
                // AI features are gated by hasTabMailSession in child views.
                // nil selection shows sidebar (not auto-navigated into inbox content).
                if !isStartupComplete {
                    SplashView()
                } else {
                    VStack(spacing: 0) {
                        if let deletionDate = pendingDeletionDate {
                            DeletionBanner(deletionDate: deletionDate) {
                                await cancelDeletion()
                            }
                        }
                        MailNavigationView(initialSelection: nil)
                    }
                }
            } else if !navigationStore.isInitialLoadComplete {
                // Still loading accounts from GRDB — show splash (not login)
                // to avoid a flash of LoginView when accounts exist but haven't loaded yet.
                SplashView()
            } else if !hasTabMailSession {
                // No email accounts AND no session → onboarding login
                TabMailLoginView {
                    withAnimation { hasTabMailSession = true }
                }
            } else if !hasCompletedConsentGate {
                if isCheckingConsent {
                    SplashView()
                } else {
                    ConsentGateView {
                        withAnimation { hasCompletedConsentGate = true }
                    }
                }
            } else if let pending = PendingAccountAdd.shared.pending {
                // Deferred Gmail/Outlook account-add gate. Set by
                // `TabMailLoginView.signInMergedGoogle/Microsoft`,
                // committed here on Connect, discarded on Later.
                pendingAccountGate(pending)
            } else if navigationStore.accounts.isEmpty {
                AddAccountGeneralView()
            } else if !hasSeenAIConsent {
                AIConsentView { aiEnabled in
                    // Persist the user's AI opt-out decision. Pre-refactor
                    // the view called `AIService.writeOptOutFlag` internally;
                    // we moved it here so demo mode can write to its own flag
                    // instead.
                    AIService.writeOptOutFlag(!aiEnabled)
                    if !aiEnabled {
                        UserDefaults.standard.set(false, forKey: "pending_plan_navigation")
                    } else if !AISubscriptionGate.shared.isActive {
                        // AI enabled but no subscription — go to plan page
                        UserDefaults.standard.set(true, forKey: "pending_plan_navigation")
                    }
                    withAnimation { hasSeenAIConsent = true }
                }
            } else if !hasSeenPushConsent {
                PushConsentView { _ in
                    withAnimation { hasSeenPushConsent = true }
                }
        } else if !isStartupComplete {
            SplashView()
        } else {
            VStack(spacing: 0) {
                if let deletionDate = pendingDeletionDate {
                    DeletionBanner(deletionDate: deletionDate) {
                        await cancelDeletion()
                    }
                }
                MailNavigationView()
            }
        }
    }

    /// True when the user has cleared every onboarding gate. Drives
    /// `OnboardingTipGate.onboardingComplete` so TipKit tips stay
    /// suppressed during the consent flow (each tip has a
    /// `#Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }`
    /// rule). Mirrors the same conditions `routedContent` uses to
    /// decide whether to show the inbox.
    private var allOnboardingGatesPassed: Bool {
        hasTabMailSession
            && hasCompletedConsentGate
            && PendingAccountAdd.shared.pending == nil
            && !navigationStore.accounts.isEmpty
            && hasSeenAIConsent
            && hasSeenPushConsent
    }

    var body: some View {
        // ZStack, NOT bare `routedContent`: the `.task`s below must hang on a
        // stable node. `routedContent` is a @ViewBuilder conditional, and a
        // branch flip fires disappear/appear on it — cancelling and
        // restarting every `.task` in this chain. Two of those tasks write
        // the very state routedContent branches on (isCheckingConsent,
        // isStartupComplete), the same self-cancellation footgun that caused
        // the Account-page infinite spinner (see ADR-IOS-054 amendment /
        // PROJECT_MEMORY stuck-isLoading rule).
        ZStack {
            routedContent
        }
        // Demo with AI enabled is treated as having a TabMail session so
        // chat / inline-edit surfaces don't render "Sign in to TabMail" locks.
        // Demo without AI keeps the env false, which cooperates with the
        // AI-disabled rendering of those surfaces.
        .environment(\.hasTabMailSession, hasTabMailSession || (demoStore.isActive && demoAiEnabled))
        .publishSyncStatusEnvironment(phase: syncStatusPhase, last: syncStatusLast, failed: syncStatusFailed, now: syncStatusNow)
        .observeSyncStatus(phase: $syncStatusPhase, last: $syncStatusLast, failed: $syncStatusFailed, now: $syncStatusNow, tag: "Root")
        .task(id: allOnboardingGatesPassed) {
            // Flip the global TipKit gate once all consent screens
            // are cleared. Parameter writes are persisted by TipKit,
            // so on subsequent launches the value stays `true` and
            // tips behave normally. Setting `false` while gates are
            // pending re-suppresses tips on a fresh install or after
            // a sign-out that reset the gates.
            // Tips fire normally during demo. The formula is
            // `passed || isActive` so demo gets ambient discovery cues from
            // the start without needing to clear production gates.
            OnboardingTipGate.onboardingComplete = allOnboardingGatesPassed || demoStore.isActive
        }
        .task(id: demoStore.isActive) {
            // Demo entry/exit also flips the tip gate.
            OnboardingTipGate.onboardingComplete = allOnboardingGatesPassed || demoStore.isActive
        }
        // Undo-send toast (Gmail-style) — mounted at RootView so it persists
        // across compose dismiss + navigation. Positioning matches the inbox
        // undo chip (InboxView.swift:283-284): ignore the bottom safe area
        // and use negative padding to sit where other app toasts sit.
        .overlay(alignment: .bottom) {
            if let pending = pendingSendService.current {
                PendingSendToast(
                    pending: pending,
                    onUndo: {
                        if let snapshot = pendingSendService.undo() {
                            reopenSnapshot = snapshot
                        }
                    },
                    onDismiss: { pendingSendService.dismiss() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .ignoresSafeArea(.container, edges: .bottom)
                .padding(.bottom, -12)
            }
        }
        // Demo Mode banner — bottom overlay; persists across all in-app
        // navigation. Compose's `fullScreenCover` covers it during edit;
        // banner re-appears on dismiss. Suppressed for debug-menu entry
        // (demo recording) — exit + counter reset live in the debug menu.
        .overlay(alignment: .bottom) {
            if demoStore.isActive && demoSeedingComplete && !demoStore.enteredFromDebugMenu {
                DemoBanner(aiEnabled: demoAiEnabled)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: pendingSendService.current?.id)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: demoStore.isActive)
        .alert("Could not start demo", isPresented: Binding(
            get: { demoStartError != nil },
            set: { if !$0 { demoStartError = nil } }
        )) {
            Button("OK", role: .cancel) { demoStartError = nil }
        } message: {
            Text(demoStartError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .demoModeDidExit)) { _ in
            demoSeedingComplete = false
        }
        // Undo-Send reopen: present a fresh ComposeView with prefill args.
        // The Draft row has been deleted (see PendingSendService.undo) so the
        // compose isn't bound to an existing draft — close → save prompt fires
        // normally through saveDraftAndDismiss.
        .fullScreenCover(item: $reopenSnapshot) { snapshot in
            UndoReopenCompose(snapshot: snapshot)
        }
        // loadInitialData() is called eagerly in TabMailApp.init() (after DB creation)
        // so isInitialLoadComplete is already true before the first render.
        .task(id: navigationStore.accounts.isEmpty) {
            // Re-trigger when accounts transition from empty → non-empty
            guard !navigationStore.accounts.isEmpty else { return }

            // Start lightweight setup immediately (these are fast and don't block UI).
            KeychainHelper.migrateAccessibility()
            NetworkMonitor.shared.start()
            ReminderBuilder.setupCacheInvalidation()

            // For returning users, isStartupComplete is already true from init —
            // inbox is visible immediately with cached GRDB data.
            // For new users, show inbox now (one-time data resets already ran
            // synchronously in AppDatabase.init, so the DB is already migrated).
            isStartupComplete = true

            // In screenshot mode, skip all provider connections and sync —
            // the seeded GRDB data is sufficient for rendering screenshots.
            guard !ScreenshotMode.isActive else {
                return
            }

            let manager = AccountManager.shared
            let accounts = navigationStore.accounts

            // Connect providers + reconcile, then let the foreground poll sync.
            // Startup data resets already happened at DB-open (StartupMigrations
            // runs in AppDatabase.init before the pool is exposed), so there's no
            // migrate-vs-sync ordering to manage here anymore.
            Task {
                // Connect all active accounts CONCURRENTLY. connectAccount blocks up
                // to SyncConfig.connectTimeoutSeconds on a slow/flaky network; the old
                // serial loop meant N accounts = up to N×timeout before any provider
                // was live — and sync (which needs a connected provider) waited that
                // long. The AccountManager actor serializes the per-account bookkeeping
                // while the provider.connect() network waits OVERLAP (actor reentrancy),
                // so providers come up in ~one timeout total and new mail starts flowing
                // as soon as the first account connects.
                // This whole block is fire-and-forget (a detached Task), so it does
                // NOT gate first paint — the marks below time the NETWORK path (the
                // prime cold-boot-slow suspect), which runs in parallel with paint.
                let connectT0 = CFAbsoluteTimeGetCurrent()
                BootProfiler.mark("RootView: connect loop START (\(accounts.filter { $0.isActive }.count) active accounts) — async, does NOT gate paint")
                await withTaskGroup(of: Void.self) { group in
                    for account in accounts where account.isActive {
                        group.addTask {
                            if await manager.provider(for: account) == nil {
                                try? await manager.connectAccount(account)
                            }
                        }
                    }
                }
                BootProfiler.mark("RootView: connect loop DONE in \(Int((CFAbsoluteTimeGetCurrent() - connectT0) * 1000))ms (all providers connect-attempted)")

                // If any account failed auth, navigate to settings
                if !AccountManagerState.shared.authFailedAccounts.isEmpty {
                    NotificationCenter.default.post(name: .navigateToSettings, object: nil)
                }

                // iCloud setup is now handled inline in the consent
                // flow (via `PendingAccountAdd` set in
                // `TabMailLoginView` after Apple sign-in), so no
                // post-onboarding sheet is needed here anymore.

                await manager.reconcilePendingOperations()
                BootProfiler.mark("RootView: reconcilePendingOperations done")
                await BackfillAIQueue.shared.repopulateFromDatabase()
                BootProfiler.mark("RootView: BackfillAIQueue.repopulate done")
                // Notify UI before sync — background push may have already synced
                // data while app was suspended. Reload from GRDB immediately so
                // the user sees current state, then sync finds any remaining changes.
                NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
                BootProfiler.mark("RootView: posted inboxDataDidChange (UI reload from GRDB)")
                // Sync is handled by startForegroundPolling() (triggered by scenePhase → .active).
                // Do NOT call foregroundSyncAll() here — it races with the poll's sync,
                // causing every full sync to run twice (doubled API calls, IMAP connections, DB writes).
            }

            // Wire up AI cache probe handler (Device Sync: respond to peer probes with local GRDB cache)
            // Probe keys are RFC 2822 Message-ID headers without angle brackets (device-independent)
            DeviceSyncService.shared.aiCacheProbeHandler = { keys, fields in
                let wantSummary = fields == nil || fields!.contains("summary")
                let wantAction = fields == nil || fields!.contains("action")
                let wantReply = fields == nil || fields!.contains("reply")
                var results = [String: AICacheResult]()
                let dbPool = AppDatabase.dbPool
                for key in keys {
                    print("[AIProbe] Looking up key: \"\(key)\" (fields=\(fields ?? ["all"]))")
                    // Match by rfc822MessageId (stored normalized, no angle brackets).
                    // Fetch ALL copies (inbox + all mail + etc.) because fetchLimit=1
                    // could return the All Mail copy which has no AI data (AI is inbox-scoped).
                    let headers: [MessageHeader]
                    let normalizedKey = EmailFilter.normalizeMessageId(key)
                    do {
                        headers = try dbPool.read { db in
                            try MessageHeader
                                .filter(Column("rfc822MessageId") == normalizedKey)
                                .limit(5)
                                .fetchAll(db)
                        }
                    } catch {
                        print("[AIProbe] Fetch error for key \"\(key)\": \(error)")
                        continue
                    }

                    // Pick the best copy: prefer the one with the most AI data.
                    // Gmail stores the same message in Inbox + All Mail; only the
                    // inbox copy has AI data. Without this, fetchLimit=1 could
                    // return the empty All Mail copy.
                    var bestHeader: MessageHeader?
                    var bestScore = 0
                    for h in headers {
                        var score = 0
                        if h.summaryBlurb != nil { score += 1 }
                        if h.actionTag != nil { score += 1 }
                        if h.cachedReply != nil { score += 1 }
                        if score > bestScore {
                            bestScore = score
                            bestHeader = h
                        }
                    }

                    if let header = bestHeader, bestScore > 0 {
                        let hasSummary = wantSummary && header.summaryBlurb != nil
                        let hasAction = wantAction && header.actionTag != nil
                        let hasReply = wantReply && header.cachedReply != nil
                        print("[AIProbe] Found \(headers.count) match(es) for key \"\(key)\" — best: summary=\(hasSummary ? "present" : "nil"), action=\(header.actionTag?.rawValue ?? "nil"), reply=\(hasReply ? "present" : "nil")")

                        var result = AICacheResult()
                        if hasSummary {
                            var summary = AICacheSummary(blurb: header.summaryBlurb ?? "")
                            summary.todos = header.summaryTodos
                            summary.reminderDate = header.reminderDate
                            summary.reminderTime = header.reminderTime
                            summary.reminderContent = header.reminderContent
                            result.summary = summary
                        }
                        if hasAction, let action = header.actionTag {
                            result.action = action.rawValue
                        }
                        if hasReply, let reply = header.cachedReply, !reply.isEmpty {
                            result.reply = reply
                        }
                        if result.summary != nil || result.action != nil || result.reply != nil {
                            results[key] = result
                        } else {
                            print("[AIProbe] Header matched but no requested fields populated for key \"\(key)\" — skipping")
                        }
                        continue
                    }

                    // No MessageHeader with AI data — fall through to MessageAICache
                    // (survives header deletion from stale detection)
                    print("[AIProbe] Found \(headers.count) header(s) but none with AI data for key \"\(key)\" — checking MessageAICache")
                    do {
                        if let cached = try dbPool.read({ db in
                            try MessageAICache
                                .filter(Column("rfc822MessageId") == normalizedKey)
                                .fetchOne(db)
                        }) {
                            var result = AICacheResult()
                            if wantSummary, let blurb = cached.summaryBlurb, !blurb.isEmpty {
                                var summary = AICacheSummary(blurb: blurb)
                                summary.todos = cached.summaryTodos
                                summary.reminderDate = cached.reminderDate
                                summary.reminderTime = cached.reminderTime
                                summary.reminderContent = cached.reminderContent
                                result.summary = summary
                            }
                            if wantAction, let action = cached.actionTag {
                                result.action = action.rawValue
                            }
                            if wantReply, let reply = cached.cachedReply, !reply.isEmpty {
                                result.reply = reply
                            }
                            if result.summary != nil || result.action != nil || result.reply != nil {
                                results[key] = result
                                print("[AIProbe] Cache hit for key \"\(key)\" (from MessageAICache)")
                            } else {
                                print("[AIProbe] Cache entry found but no matching fields for key \"\(key)\"")
                            }
                        } else {
                            print("[AIProbe] No match for key \"\(key)\" in headers or cache")
                        }
                    } catch {
                        print("[AIProbe] Cache lookup error for key \"\(key)\": \(error)")
                    }
                }
                return results
            }

            // Auto-connect Device Sync (requires TabMail session for JWT auth)
            if hasTabMailSession {
                DeviceSyncService.shared.connect()
            }
        }
        .task(id: hasTabMailSession) {
            // Check if user already consented on web/TB — auto-skip consent gate
            guard hasTabMailSession, !hasCompletedConsentGate, !DEBUG_ALWAYS_SHOW_GATES, !ScreenshotMode.isActive else { return }
            isCheckingConsent = true
            defer { isCheckingConsent = false }
            do {
                let accountInfo = try await BackendClient().fetchAccountInfo()
                if accountInfo.consentRequired == false {
                    print("[RootView] User already consented (web/TB) — skipping consent gate")
                    withAnimation { hasCompletedConsentGate = true }
                }
            } catch BackendError.accountGone {
                print("[RootView] Account no longer exists — showing account gone alert")
                NotificationCenter.default.post(name: .tabMailAccountGone, object: nil)
                return
            } catch BackendError.unauthorized {
                // Check if auth permanently failed (account deleted/token revoked)
                let tokenState = await TabMailTokenCoordinator.shared.validToken()
                if case .permanentFailure = tokenState {
                    print("[RootView] Auth permanently failed — showing account gone alert")
                    NotificationCenter.default.post(name: .tabMailAccountGone, object: nil)
                    return
                }
                print("[RootView] /whoami unauthorized (transient) — showing consent gate")
            } catch {
                // Non-fatal — user will see the consent gate and can consent natively
                print("[RootView] /whoami consent check failed: \(error) — showing consent gate")
            }

            // Check for pending account deletion (non-fatal)
            do {
                let status = try await BillingClient().checkDeletionStatus()
                pendingDeletionDate = status.pending ? status.deletion_date : nil
            } catch {
                print("[RootView] Deletion status check failed: \(error)")
            }
        }
        .onChange(of: hasTabMailSession) { old, new in
            if DebugModeManager.isLoggingEnabled() {
                print("[RootView] hasTabMailSession \(old) -> \(new)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tabMailDidSignOut).receive(on: DispatchQueue.main)) { _ in
            if DebugModeManager.isLoggingEnabled() {
                print("[RootView] received .tabMailDidSignOut")
            }
            // Save consent gate state for the current user before clearing (per-account)
            saveConsentStateForCurrentUser()
            withAnimation {
                hasTabMailSession = false
                hasCompletedConsentGate = false
                // AI consent (hasSeenAIConsent) is device-level — not cleared on sign-out.
                // Apple 5.1.2(i) disclosure is about app behavior, not account identity.
                pendingDeletionDate = nil
            }
            showSignedOutAlert = true
        }
        .alert("Signed Out", isPresented: $showSignedOutAlert) {
            Button("OK") {}
        } message: {
            Text("You have been signed out of TabMail. Your email accounts and messages remain on this device. Sign in again to use AI features.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .tabMailAccountGone).receive(on: DispatchQueue.main)) { _ in
            if DebugModeManager.isLoggingEnabled() {
                print("[RootView] received .tabMailAccountGone")
            }
            showAccountGoneAlert = true
        }
        .alert("Account No Longer Available", isPresented: $showAccountGoneAlert) {
            Button("OK") {
                TabMailAuthService.clearSession()
                NotificationCenter.default.post(name: .tabMailDidSignOut, object: nil)
            }
        } message: {
            Text("Your TabMail account no longer exists. You have been signed out. Your email accounts and messages remain on this device.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .tabMailDidSignIn).receive(on: DispatchQueue.main)) { _ in
            withAnimation { hasTabMailSession = true }
            // Restore consent state for the signed-in user (avoids re-showing consent)
            restoreConsentStateForCurrentUser()
            // Reconnect Device Sync after re-authentication
            DeviceSyncService.shared.connect()
            // Reopen AI subscription gate — new login may have active subscription
            Task { await Self.revalidateAISubscriptionGate() }
        }
        .onChange(of: scenePhase) { _, phase in
            let phaseName = phase == .active ? "active" : (phase == .background ? "background" : "inactive")
            BootProfiler.mark("◐ scenePhase → \(phaseName) (accounts=\(navigationStore.accounts.count))")
            switch phase {
            case .active:
                if !navigationStore.accounts.isEmpty {
                    syncScheduler.startForegroundPolling()
                }
                // IOS-OUTBOX-001: the launch `.task` above is reconciliation's
                // only other trigger, so a send stranded `.sending`/`sentAt ==
                // nil` stayed stranded for the whole session — the drain selects
                // `.queued` only and the Outbox UI offers no gesture for a
                // `sending` row. Foreground is the second trigger. The drain
                // latch checked inside is what keeps the double-send firewall
                // intact; see `reconcileOutboxOnForeground`.
                Task { await AccountManager.shared.reconcileOutboxOnForeground() }
                // Reconnect Device Sync if needed (e.g., returning from background)
                DeviceSyncService.shared.reconnectIfNeeded()
                // Check for overdue reminders that may have been missed while backgrounded
                Task { await ProactiveNotifyService.shared.onForegroundReturn() }
                // Start task evaluation loop (fires every 5 min while in foreground)
                // Also registers wake times with push worker for background execution
                Task {
                    await TaskEvaluationService.shared.startTimer()
                    await TaskEvaluationService.shared.registerAlarmsWithPushWorker()
                }
                // Revalidate AI subscription gate if closed (user may have subscribed externally)
                Task { await Self.revalidateAISubscriptionGate() }
            case .background:
                syncScheduler.stopPolling()
                // Stop task evaluation loop (saves resources in background)
                Task { await TaskEvaluationService.shared.stopTimer() }
                // Give in-flight backfill ~30s to finish its current chunk
                syncScheduler.requestBackgroundGracePeriod()
                syncScheduler.scheduleBackgroundSync()
                syncScheduler.scheduleBackgroundAIProcessing()
                // Disconnect Device Sync to save resources in background
                DeviceSyncService.shared.disconnect()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    /// Revalidate AI subscription gate via whoami.
    /// Opens the gate if subscription is active, closes it if not.
    private static func revalidateAISubscriptionGate() async {
        do {
            let info = try await BackendClient().fetchAccountInfo()
            if info.hasSubscription == true {
                AISubscriptionGate.shared.openGate()
            } else {
                AISubscriptionGate.shared.closeGate()
            }
            // Feed the inbox usage-throttle banner from this same always-on
            // foreground /whoami fetch — no extra poll.
            UsageThrottleStore.shared.update(from: info)
        } catch {
            print("[AISubscriptionGate] Revalidation failed: \(error)")
        }
    }

    @ViewBuilder
    private func pendingAccountGate(_ pending: PendingAccountAdd.Pending) -> some View {
        switch pending.provider {
        case .gmail:
            AddAccountGmailOutlookView(
                provider: .gmail,
                email: pending.email,
                onConnect: { try await commitGmailOutlookAdd(provider: .gmail, email: pending.email) },
                onLater: {
                    withAnimation { PendingAccountAdd.shared.clear() }
                }
            )
        case .outlook:
            AddAccountGmailOutlookView(
                provider: .outlook,
                email: pending.email,
                onConnect: { try await commitGmailOutlookAdd(provider: .outlook, email: pending.email) },
                onLater: {
                    withAnimation { PendingAccountAdd.shared.clear() }
                }
            )
        case .icloud:
            AddAccountICloudView(
                detectedEmail: pending.email,
                onConnected: {
                    await finishPendingAccountAdd()
                },
                onLater: {
                    withAnimation { PendingAccountAdd.shared.clear() }
                }
            )
        }
    }

    /// Finish a successful account-add: refresh the sidebar store BEFORE
    /// clearing `PendingAccountAdd`. The router re-evaluates synchronously
    /// when `pending` clears, but `navigationStore.accounts` is otherwise
    /// only repopulated ~100ms later via the debounced
    /// `.backgroundDataDidChange` listener (see `NavigationStore.loadInitialData`).
    /// Without refreshing first, the router falls through to
    /// `navigationStore.accounts.isEmpty` and briefly flashes
    /// `AddAccountGeneralView` (the generic "Add Account" screen) in that gap —
    /// the intermittent "blink, looks like nothing happened" after adding an
    /// iCloud account. Refreshing first guarantees `accounts` is populated, so
    /// the router moves straight to the next gate.
    @MainActor
    private func finishPendingAccountAdd() async {
        await navigationStore.refresh()
        withAnimation { PendingAccountAdd.shared.clear() }
    }

    /// Commit the deferred Gmail/Outlook add. Caller is the
    /// **Connect** button on `AddAccountGmailOutlookView`. This is
    /// where the *second* OAuth fires: the first one (in
    /// `TabMailLoginView`) only requested identity scopes, so we now
    /// run a full-scope OAuth (Gmail/Calendar) with `loginHint` set
    /// to the user's email so they don't see an account picker.
    ///
    /// Throws on real failures (network, server, OAuth error) so the
    /// gate can display them inline. Cancellations (ASWebAuth Code=1
    /// or `CancellationError`) are also thrown — the view catches
    /// them silently and keeps the gate visible. **Later** is the
    /// only route to `AddAccountGeneralView`; failure does not
    /// silently drop the user there.
    private func commitGmailOutlookAdd(
        provider: AddAccountGmailOutlookView.Provider,
        email: String
    ) async throws {
        let oauth = await AccountManager.shared.oauthService
        switch provider {
        case .gmail:
            let tokens = try await oauth.authenticateGoogle(loginHint: email)
            _ = try await AccountManager.shared.addGmailAccountWithTokens(tokens)
        case .outlook:
            let tokens = try await oauth.authenticateMicrosoft(loginHint: email)
            _ = try await AccountManager.shared.addOutlookAccountWithTokens(tokens)
        }
        // Success: refresh the sidebar store, then clear pending so the gate
        // dismisses straight to the next step (no stale-empty-accounts flash).
        await finishPendingAccountAdd()
    }

    // MARK: - Per-Account Consent Gate Persistence

    /// Save consent gate state keyed by the signed-in user's ID.
    /// Called before sign-out so re-signing in can restore it.
    /// AI consent (hasSeenAIConsent) is device-level and not saved per-user.
    private func saveConsentStateForCurrentUser() {
        guard let userId = TabMailAuthService.getSession()?.userId else { return }
        UserDefaults.standard.set(hasCompletedConsentGate, forKey: "consent_gate_\(userId)")
    }

    /// Restore consent gate state for the newly signed-in user.
    /// If this user previously completed the consent gate, skip it.
    private func restoreConsentStateForCurrentUser() {
        guard let userId = TabMailAuthService.getSession()?.userId else { return }
        let consentKey = "consent_gate_\(userId)"
        if UserDefaults.standard.object(forKey: consentKey) != nil {
            hasCompletedConsentGate = UserDefaults.standard.bool(forKey: consentKey)
        }
    }

    private func cancelDeletion() async -> Bool {
        do {
            _ = try await BillingClient().cancelAccountDeletion()
            pendingDeletionDate = nil
            print("[RootView] Account deletion cancelled")
            return true
        } catch BackendError.requestFailed(let statusCode) where statusCode == 409 || statusCode == 404 {
            // 409 = cron already processed; 404 = no pending deletion (cancelled elsewhere)
            pendingDeletionDate = nil
            print("[RootView] Cancel deletion: already resolved (status \(statusCode)) — dismissing banner")
            return true
        } catch {
            print("[RootView] Cancel deletion failed: \(error)")
            return false
        }
    }
}

/// Banner shown when user has a pending account deletion.
private struct DeletionBanner: View {
    let deletionDate: String
    let onCancel: () async -> Bool
    @State private var isCancelling = false
    @State private var showError = false

    private var formattedDate: String {
        if let date = Date.fromISO8601(deletionDate) {
            return date.formatted(date: .long, time: .omitted)
        }
        return deletionDate
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Account deletion scheduled")
                    .font(.subheadline.bold())
                Text("Your account will be deleted on \(formattedDate).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isCancelling = true
                showError = false
                Task {
                    let success = await onCancel()
                    isCancelling = false
                    if !success {
                        showError = true
                    }
                }
            } label: {
                if isCancelling {
                    ProgressView()
                        .controlSize(.small)
                } else if showError {
                    Text("Retry")
                        .font(.subheadline.bold())
                } else {
                    Text("Cancel")
                        .font(.subheadline.bold())
                }
            }
            .buttonStyle(.bordered)
            .tint(showError ? .red : .orange)
            .disabled(isCancelling)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
    }
}

extension Notification.Name {
    static let tabMailDidSignOut = Notification.Name("tabMailDidSignOut")
    static let tabMailDidSignIn = Notification.Name("tabMailDidSignIn")
    static let navigateToSettings = Notification.Name("navigateToSettings")
    static let navigateToAccount = Notification.Name("navigateToAccount")
    /// Posted by the inbox usage-throttle banner (Basic, budget exhausted) to
    /// open the plan picker. MailNavigationView routes to `.planPicker`.
    static let navigateToPlanPicker = Notification.Name("navigateToPlanPicker")
    /// Posted by the inbox usage-throttle banner (BYOK, no own key) to open the
    /// AI Provider settings — provider selection AND key management both live
    /// there. MailNavigationView routes to `.prompts` (TabMail Settings) and
    /// scrolls to the "AI Provider" section.
    static let navigateToAIProvider = Notification.Name("navigateToAIProvider")
    /// Posted after GRDB writes that affect visible UI (e.g., backfill inserts).
    /// Views should reload data when receiving this notification.
    /// Reserved for rare structural changes (account add/remove, outbox, app launch).
    static let backgroundDataDidChange = Notification.Name("backgroundDataDidChange")
    /// Posted when folder unread counts are updated (recount complete or optimistic write).
    /// Sidebar refreshes folder badges; app badge updates. Lightweight — no message list reload.
    static let unreadCountsDidChange = Notification.Name("unreadCountsDidChange")
    /// Posted when inbox message list data changes (new headers from sync/backfill).
    /// InboxViewModel reloads message list. NavigationStore refreshes folders.
    static let inboxDataDidChange = Notification.Name("inboxDataDidChange")
    /// `userInfo` key on `.inboxDataDidChange`. When `true`, the inbox reload
    /// runs IMMEDIATELY, bypassing the 500ms coalescing debounce that the noisy
    /// background producers (sync, backfill, AI, user actions) ride.
    ///
    /// Reserved for the PRIVILEGED NSE→inbox merge-complete signal: the merge is
    /// a boot-priority, single-threaded step (see `NSEMergeCoordinator`) whose
    /// result must paint at once. Background producers MUST NOT set this key.
    static let inboxReloadImmediateKey = "inboxReloadImmediate"
    /// Posted by `PushNotificationService.checkPushConsentStatusForForeground`
    /// (and the consent-error notification-tap handler) when one or more push
    /// accounts — Gmail **or** Outlook — have an `error`/`missing` state on
    /// the server-side inbox-add classifier. `userInfo["emails"]` is a
    /// `[String]` of affected addresses. UI layer (a settings banner / inbox
    /// toast) uses this to surface a "Fix smart notifications" affordance
    /// that, on tap, re-runs the appropriate per-provider consent flow.
    static let pushConsentErrorsDetected = Notification.Name("pushConsentErrorsDetected")
    /// Posted when a newly-added push-capable account (Gmail or Outlook)
    /// needs the user to confirm metadata-scope consent (NSE toggle is ON;
    /// primary OAuth just succeeded). `userInfo["email"]` is the address;
    /// `userInfo["provider"]` is the raw provider string (`"gmail"` /
    /// `"outlook"`) so the receiver can pick the right explainer alert.
    /// The UI presents a modal alert; on Continue it runs the unified
    /// `ensurePushConsentAfterAccountAdd`. Decoupled from AccountManagerSetup
    /// so the alert can be presented from a stable view (MailNavigationView)
    /// regardless of where account-add was initiated.
    static let pushConsentExplainerNeeded = Notification.Name("pushConsentExplainerNeeded")
    /// Posted when archive/delete/move is performed from the detail view.
    /// Object is the message ID (String) so the list can dismiss it immediately.
    static let messageDismissedFromDetail = Notification.Name("messageDismissedFromDetail")
    /// Posted when a single message's data changes (AI processing, reply/forward flags, tag updates, etc.).
    /// Object is the message ID (String) so observers can refresh that message in-place from GRDB.
    static let messageDataDidChange = Notification.Name("messageDataDidChange")
    /// Posted when AI processing fails for a message (network error, empty response, etc.).
    /// Object is the header ID (String) so SummaryBubbleView can show failure state.
    static let aiDidFailForMessage = Notification.Name("aiDidFailForMessage")
    /// Posted when undo restores dismissed messages.
    /// Object is [String] array of message IDs to un-dismiss.
    static let messagesUndone = Notification.Name("messagesUndone")
    /// Posted by the NSE merge with just-read staged mail so the inbox can render
    /// it IN-MEMORY without waiting for the durable header write (ADR-IOS-049).
    /// Object is `[StagedInboxRow]`.
    static let messagesStaged = Notification.Name("messagesStaged")
    /// Posted by the NSE merge when staged rows have become DURABLE and queryable
    /// in GRDB — at the phase-1 header surface (headers + reference junctions
    /// newly visible) and again at end-of-merge (bodies/AI/removals landed).
    /// Companion to `.messagesStaged` (ADR-IOS-049): a quick-rendered open
    /// (header/body synthesized from the staged snapshot) ran thread detection
    /// against GRDB BEFORE the merge wrote the rows, so related messages came up
    /// empty. `MessageDetailViewModel` observes this to re-run thread detection
    /// once the rows are actually queryable (it deliberately does NOT re-read
    /// the focused header — phase-1 rows are header-only with nil AI fields and
    /// would wipe the staged summary/tag; see `refreshAfterMergeCommit`).
    static let nseMergeDidCommit = Notification.Name("nseMergeDidCommit")
    /// Posted when the server confirms the user's account no longer exists (deleted or token permanently revoked).
    /// RootView shows an explanatory alert and then signs out.
    static let tabMailAccountGone = Notification.Name("tabMailAccountGone")
    /// Posted by `MessageDetailViewModel.loadBody()` when a notification-tap
    /// open's resolve ladder (`resolveProviderTap`) exhausts without finding
    /// the message — the NSE never staged it AND sync hasn't landed it yet.
    /// `userInfo["messageId"]` is the VM's sentinel-prefixed id
    /// (`notifTap::<accountId>::<providerId>`). `MailNavigationView` pops the
    /// detail view and falls back to the inbox (the message appears there
    /// once sync lands) instead of leaving the user on Message-Not-Found —
    /// only for tap opens; this notification is never posted for other opens.
    static let notificationTapUnresolved = Notification.Name("notificationTapUnresolved")
}
