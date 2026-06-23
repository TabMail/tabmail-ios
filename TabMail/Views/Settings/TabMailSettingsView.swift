/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Combine

struct TabMailSettingsView: View {
    @AppStorage(AIService.optOutAllAIKey, store: AIService.optOutStore) private var optOutAllAI = false
    @AppStorage(AIService.webSearchEnabledKey) private var webSearchEnabled = false
    @AppStorage(ChatPillState.maxSessionsKey) private var maxChatSessions = ChatPillState.defaultMaxSessions
    @AppStorage(ChatPillState.maxMemoryTurnsKey) private var maxMemoryTurns = ChatPillState.defaultMaxMemoryTurns
    @AppStorage(ChatPillState.autoDictationKey) private var autoDictation = false
    @AppStorage(ProactiveNotifyService.enabledKey) private var proactiveEnabled = true
    @AppStorage(ProactiveNotifyService.windowDaysKey) private var windowDays = ProactiveNotifyService.defaultWindowDays
    @AppStorage(ProactiveNotifyService.advanceMinutesKey) private var advanceMinutes = ProactiveNotifyService.defaultAdvanceMinutes
    @State private var syncService = DeviceSyncService.shared
    @State private var debugMode = DebugModeManager.shared
    @State private var showDebugUnlocked = false
    @State private var showAcknowledgments = false
    @Environment(NavigationStore.self) private var navigationStore

    // BYOK provider state — drives whether we bother fetching the model catalog.
    @AppStorage(AIService.byokProviderKey(tier: "background")) private var byokBackgroundProvider = "tabmail"
    @AppStorage(AIService.byokProviderKey(tier: "interactive")) private var byokInteractiveProvider = "tabmail"
    @State private var demoStore = DemoModeStore.shared
    @State private var byokCatalog: BYOKModelCatalog?

    /// Set by the inbox usage-throttle banner (BYOK) before navigating here, so
    /// this view scrolls to the AI Provider section on appear. See ADR-IOS-044.
    static let pendingScrollAIProviderKey = "pending_scroll_ai_provider"
    /// ScrollViewReader anchor for the "AI Provider" section.
    private static let aiProviderAnchorID = "aiProviderSection"

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Group {
            Section("Personalization") {
                NavigationLink {
                    CompositionPromptView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Email Composition")
                            Text("Writing style, language, useful links")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "pencil.line")
                            .foregroundStyle(.primary)
                    }
                }

                NavigationLink {
                    ActionRulesView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Action Classification")
                            Text("Rules for delete, archive, reply, none")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "tag")
                            .foregroundStyle(.primary)
                    }
                }

                NavigationLink {
                    KnowledgeBaseView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Knowledge Base")
                            Text("Context the AI always considers")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "book")
                            .foregroundStyle(.primary)
                    }
                }

                NavigationLink {
                    TemplatesListView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reply Templates")
                            Text("Reusable email reply patterns")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.primary)
                    }
                }

            }

            // BYOK tier configuration — single "AI Provider" section with
            // both tiers as sibling Menu pickers (Background / Interactive).
            // The "Manage API Keys" row at the top navigates to the centralized
            // per-provider key store (one OpenAI key shared across tiers, etc).
            // Hidden entirely in demo (BYOK is paid-only per gateway
            // rejection).
            if !demoStore.isActive {
                Section {
                    NavigationLink {
                        APIKeysView()
                    } label: {
                        Label("Manage API Keys", systemImage: "key.fill")
                    }
                    BYOKTierRows(
                        tier: "background",
                        pickerLabel: "Light",
                        caption: "Used for background jobs like summaries and classification.",
                        catalog: byokCatalog
                    )
                    BYOKTierRows(
                        tier: "interactive",
                        pickerLabel: "Heavy",
                        caption: "Used for interactive tasks like chat and reply drafts.",
                        catalog: byokCatalog
                    )
                } header: {
                    Text("AI Provider")
                } footer: {
                    Text("Choosing a provider other than TabMail sends requests directly to that provider on your own API key and can incur significant API costs. We strongly recommend TabMail's built-in models unless you have a special pricing agreement with the provider.")
                }
                .id(Self.aiProviderAnchorID)
            }

            Section {
                Stepper(value: $maxChatSessions, in: 1...50) {
                    Label {
                        Text("Sessions: \(maxChatSessions)")
                    } icon: {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(.primary)
                    }
                }
                .disabled(optOutAllAI)
                Stepper(value: $maxMemoryTurns, in: 100...50000, step: 100) {
                    Label {
                        Text("Memory: \(maxMemoryTurns)")
                    } icon: {
                        Image(systemName: "brain")
                            .foregroundStyle(.primary)
                    }
                }
                .disabled(optOutAllAI)
                NavigationLink {
                    ChatHistoryView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chat History")
                            Text("Browse past AI conversations")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .foregroundStyle(.primary)
                    }
                }

                NavigationLink {
                    PromptHistoryView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sync History")
                            Text("Browse and restore previous states")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.primary)
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Sessions: number of inbox sessions to keep as resumable.\nMemory: number of all chat turns to store for recalling.")
            }

            Section("Notifications") {
                Toggle(isOn: $proactiveEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Proactive Reminders")
                            Text("Notify when reminders are new or approaching")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "bell.badge")
                            .foregroundStyle(.primary)
                    }
                }

                if proactiveEnabled {
                    Stepper(value: $windowDays, in: 1...30) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("New reminder window: \(windowDays) days")
                                Text("Only notify for reminders due within this window")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "calendar")
                                .foregroundStyle(.primary)
                        }
                    }

                    Stepper(value: $advanceMinutes, in: 5...120, step: 5) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Notify \(advanceMinutes) min before due")
                                Text("How early to alert before a reminder's due time")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "clock")
                                .foregroundStyle(.primary)
                        }
                    }
                }

            }

            Section("User Interface") {
                Toggle(isOn: $autoDictation) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Enable Dictation")
                            Text("Start dictation when chat pill opens")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "mic")
                            .foregroundStyle(.primary)
                    }
                }
            }

            // Privacy opt-out (matches TB's Settings → Privacy section)
            Section {
                Toggle(isOn: $optOutAllAI) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Opt Out of AI")
                            Text("Block all AI backend calls")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "hand.raised")
                            .foregroundStyle(.primary)
                    }
                }

                if optOutAllAI {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text("Privacy opt-out enabled")
                                .fontWeight(.semibold)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(Palette.archive)

                        Text("This disables **all AI features** — chat, summaries, action classification, and any other AI calls. TabMail UI will still work, but no email data will be sent to the AI backend.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Toggle(isOn: $webSearchEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Web Search")
                            Text("Allow AI to search the web when answering")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "globe")
                            .foregroundStyle(.primary)
                    }
                }
                .disabled(optOutAllAI)

                Toggle(isOn: Binding(
                    get: { syncService.isAutoEnabled },
                    set: { newValue in
                        syncService.isAutoEnabled = newValue
                        NSEDataBridge.mirrorPushSettings()
                    }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Device Sync")
                            Text("Sync AI results across **your own** devices")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.primary)
                    }
                }

                if syncService.isAutoEnabled {
                    HStack(spacing: 6) {
                        if syncService.isConnecting {
                            ProgressView()
                                .controlSize(.small)
                            Text("Connecting...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if syncService.isConnected {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
                            Text("Sync active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "circle")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                            Text("Disconnected — will retry")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 28)
                }

                if !syncService.isAutoEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text("Device sync disabled")
                                .fontWeight(.semibold)
                        } icon: {
                            Image(systemName: "info.circle.fill")
                        }
                        .foregroundStyle(Palette.archive)

                        Text("AI results will not sync between **your own** devices. Each device will generate its own summaries independently.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Privacy")
            }

            Section("Legal") {
                Link(destination: URL(string: "https://tabmail.ai/privacy")!) {
                    HStack {
                        Label("Privacy Policy", systemImage: "hand.raised")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Link(destination: URL(string: "https://tabmail.ai/terms")!) {
                    HStack {
                        Label("Terms of Service", systemImage: "doc.text")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Link(destination: URL(string: "mailto:support@tabmail.ai")!) {
                    HStack {
                        Label("Contact Support", systemImage: "envelope")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Button {
                    showAcknowledgments = true
                } label: {
                    HStack {
                        Label("Acknowledgments", systemImage: "heart")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                        .foregroundStyle(.secondary)
                    if let remaining = debugMode.remainingTaps {
                        Text("(\(remaining))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if debugMode.registerTap() {
                        showDebugUnlocked = true
                    }
                }
            }

            if debugMode.isUnlocked {
                Section {
                    Button(role: .destructive) {
                        debugMode.isUnlocked = false
                        debugMode.resetTapCount()
                    } label: {
                        Label("Lock Debug Mode", systemImage: "lock")
                    }
                }
            }
            }
            .listRowBackground(Palette.boxBg)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle("TabMail Settings")
        .refreshable {
            syncService.syncNow()
            // Brief delay to give UI feedback
            try? await Task.sleep(for: .milliseconds(500))
        }
        .onChange(of: optOutAllAI) { wasOptedOut, isOptedOut in
            // AI re-enabled: queue all inbox messages for processing.
            // Messages already processed (have summary+action) are filtered out naturally.
            if wasOptedOut && !isOptedOut {
                Task { await AccountManager.shared.reprocessInboxMessages(accounts: navigationStore.accounts) }
            }
        }
        .task {
            await loadBYOKCatalogIfNeeded()
        }
        .onChange(of: byokBackgroundProvider) { _, _ in
            Task { await loadBYOKCatalogIfNeeded() }
        }
        .onChange(of: byokInteractiveProvider) { _, _ in
            Task { await loadBYOKCatalogIfNeeded() }
        }
        .onDisappear {
            debugMode.resetTapCount()
        }
        .alert("Debug Mode Unlocked", isPresented: $showDebugUnlocked) {
            Button("OK") { }
        } message: {
            Text("Debug menu is now available in the sidebar.")
        }
        .sheet(isPresented: $showAcknowledgments) {
            AcknowledgmentsView()
        }
        // Force @AppStorage re-read when UserDefaults changes programmatically
        // (e.g., from ChangeSettingTool in agent chat). @AppStorage KVO can miss
        // changes made from non-SwiftUI code paths. Guard against feedback loops:
        // only assign when the value actually differs. For settings whose default
        // is `true`, treat a missing key as `true` — `bool(forKey:)` returns false
        // for missing keys, which would otherwise stomp the AppStorage default
        // back to false on the next UserDefaults change.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
            let ud = UserDefaults.standard
            let newWebSearch = ud.bool(forKey: AIService.webSearchEnabledKey)
            // Opt-out flag lives in the App Group suite (shared with the NSE),
            // not `.standard` — see AIService.optOutStore. Reading `.standard`
            // here would miss external toggles and clobber the SwiftUI binding
            // with a stale `false` whenever any other UserDefaults key changes.
            let newOptOut = AIService.optOutStore.bool(forKey: AIService.optOutAllAIKey)
            let newProactive = ud.object(forKey: ProactiveNotifyService.enabledKey) == nil
                ? true
                : ud.bool(forKey: ProactiveNotifyService.enabledKey)
            let newWindowDays = ud.integer(forKey: ProactiveNotifyService.windowDaysKey)
            let newAdvanceMin = ud.integer(forKey: ProactiveNotifyService.advanceMinutesKey)
            if webSearchEnabled != newWebSearch { webSearchEnabled = newWebSearch }
            if optOutAllAI != newOptOut { optOutAllAI = newOptOut }
            if proactiveEnabled != newProactive { proactiveEnabled = newProactive }
            if windowDays != newWindowDays { windowDays = newWindowDays }
            if advanceMinutes != newAdvanceMin { advanceMinutes = newAdvanceMin }
        }
        .onAppear { maybeScrollToAIProvider(proxy) }
        } // ScrollViewReader
    }

    /// If the inbox throttle banner flagged a deep-link to the AI Provider
    /// section (BYOK setup), scroll to it once the form has laid out, then
    /// clear the flag so it only fires for that one navigation.
    @MainActor
    private func maybeScrollToAIProvider(_ proxy: ScrollViewProxy) {
        guard UserDefaults.standard.bool(forKey: Self.pendingScrollAIProviderKey) else { return }
        UserDefaults.standard.set(false, forKey: Self.pendingScrollAIProviderKey)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation { proxy.scrollTo(Self.aiProviderAnchorID, anchor: .top) }
        }
    }

    /// Fetch the BYOK model catalog if (a) we don't have one yet and (b) at
    /// least one tier is configured for BYOK. Skipped when both tiers default
    /// to TabMail — no point hitting `/byok/models` if the user isn't using BYOK.
    private func loadBYOKCatalogIfNeeded() async {
        guard byokCatalog == nil else { return }
        guard byokBackgroundProvider != "tabmail" || byokInteractiveProvider != "tabmail" else { return }
        do {
            byokCatalog = try await BackendClient().fetchBYOKModels()
        } catch {
            // Tier sections render a "Loading models…" placeholder when nil; a
            // failed fetch just leaves it stuck there. Users can pull-to-retry
            // by closing/reopening Settings. No need to surface this error.
            print("[BYOK] catalog fetch failed: \(error)")
        }
    }
}

