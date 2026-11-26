/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB
import UIKit

struct SettingsView: View {
    @Environment(NavigationStore.self) private var navigationStore
    @Environment(\.scenePhase) private var scenePhase
    /// Push is delivered through the TabMail push worker, which needs a
    /// TabMail session to register the device. Without one the controls are
    /// greyed out (#109) — the same gate that hides AI features elsewhere.
    @Environment(\.hasTabMailSession) private var hasTabMailSession
    @State private var accountToDelete: Account?
    /// The files of changed calendar occurrences the account's queued or failed calendar changes
    /// still hold on this device (#718), read when its removal is asked; the alert warns of them.
    @State private var accountHeldFiles: [LateCalendarFailureStore.HeldFiles] = []
    @State private var exportedHeldFiles: SavedPutBackFilesWarning.Export?
    @State private var settingsErrorMessage = ""
    @State private var showSettingsError = false
    @AppStorage(SyncScheduler.wifiOnlyKey) private var backgroundSyncWiFiOnly = true
    @AppStorage("isLargeInbox") private var isLargeInbox = false
    @State private var storageBudgetMB: Int = StorageEstimator.budgetMB
    /// "Email Index Used", measured off the main thread, and the Optimize Storage row (#1448).
    @State private var optimizer = StorageOptimizer()
    @State private var attachmentsBudgetMB: Int = BodyAssetStore.attachmentsBudgetMB
    @State private var showAttachmentsWipeConfirm = false
    @State private var isWipingAttachments = false
    /// Bind directly to the UserDefault so background writes
    /// (e.g. `disableNSEGlobally` on consent decline) re-render the
    /// toggle. `@AppStorage` registers a KVO observer against
    /// UserDefaults.standard; a manual `Binding(get:set:)` would
    /// only re-read on explicit view invalidation.
    @AppStorage(PushConfig.pushNotificationsEnabledKey) private var pushEnabled: Bool = false
    @State private var showingPushEnableConfirm: Bool = false
    /// True when iOS has no visual surface enabled (Banners / Lock Screen /
    /// Notification Center) — visible push can't present and the NSE can't run.
    /// Drives the warning shown under the push toggle. Local check; see
    /// `refreshVisualAlertsWarning`. `hasCheckedVisualAlerts` gates the first
    /// render so the warning doesn't flash before the async read resolves.
    @State private var visualAlertsOff = false
    @State private var hasCheckedVisualAlerts = false
    @State private var showFastSync = false
    @State private var showArchiveConfirm = false
    @State private var showArchiveFinalConfirm = false
    @State private var showNukeConfirm = false
    @State private var isNuking = false
    @State private var showReindexConfirm = false
    @State private var reindexTriggered = false
    @State private var oldMessageCount = 0
    private var manager: AccountManager { AccountManager.shared }
    private var state: AccountManagerState { AccountManagerState.shared }

    var body: some View {
        Form {
            Group {
            Section("Accounts") {
                ForEach(navigationStore.accounts) { account in
                    NavigationLink {
                        AccountDetailView(account: account)
                    } label: {
                        HStack {
                            iconFor(account.provider)
                                .frame(width: 16, height: 16)
                                .foregroundStyle(.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                    .font(.headline)
                                Text(account.emailAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if account.isPrimary && navigationStore.accounts.count > 1 {
                                    Text("Primary")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                }
                                if account.calendarSetupFailed {
                                    Label("Calendar not connected", systemImage: "calendar.badge.exclamationmark")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if state.authFailedAccounts.contains(account.id) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                            }
                            Text(account.provider.displayName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task {
                                accountHeldFiles = await LateCalendarFailureStore.heldFiles(accountId: account.id)
                                accountToDelete = account
                            }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }

                NavigationLink {
                    AddAccountGeneralView()
                } label: {
                    Label("Add Account", systemImage: "plus")
                        .foregroundStyle(.primary)
                }
            }

            if isLargeInbox {
                Section("Inbox Management") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Your inbox works best as a task queue", systemImage: "archivebox")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("You have \(oldMessageCount) email\(oldMessageCount == 1 ? "" : "s") older than \(SyncConfig.archiveAgeDays) days in your inbox. Archiving old emails keeps your inbox focused on what needs your attention now. Emails are processed by AI automatically for your \(SyncConfig.maxRecentEmails) most recent — older ones are still processed when you open them, when they arrive, or when you move them to your inbox.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    Button {
                        showArchiveConfirm = true
                    } label: {
                        Label("Archive Emails Older Than \(SyncConfig.archiveAgeDays) Days", systemImage: "archivebox.fill")
                    }
                }
            }

            Section("Push Notifications") {
                if !hasTabMailSession {
                    Label("Push notifications need a TabMail sign-in", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Toggle("Enable Inbox Push Notifications", isOn: $pushEnabled)
                    .disabled(!hasTabMailSession)
                    .onChange(of: pushEnabled) { oldValue, newValue in
                        // Only act on USER-DRIVEN transitions, not on programmatic
                        // writes (e.g. disableNSEGlobally writing false after a
                        // declined consent sheet — the side effects are already
                        // being run there, we must not re-run them).
                        NSEDataBridge.mirrorPushSettings()
                        // Keep the inbox tip's display gate in sync.
                        EnableInboxPushTip.pushEnabled = newValue
                        Task { @MainActor in
                            await PushNotificationService.shared.registerDeviceWithWorker(force: true)
                            if newValue && !oldValue {
                                // OFF→ON: show confirmation dialog BEFORE popping
                                // the ASWebAuthenticationSession so the user knows
                                // exactly what "tabmail.ai wants to sign in"
                                // means. Actual consent flow runs only on
                                // explicit "Continue".
                                showingPushEnableConfirm = true
                            } else if !newValue && oldValue {
                                // ON→OFF: revoke stored consent for every push-
                                // capable account (Gmail + Outlook). Provider-
                                // agnostic; dispatches per provider internally.
                                await PushNotificationService.shared.revokePushConsentForAllAccounts()
                            }
                        }
                    }
                    .alert(
                        "Enable smart push notifications?",
                        isPresented: $showingPushEnableConfirm
                    ) {
                        Button("Cancel", role: .cancel) {
                            // Revert the toggle. @AppStorage KVO re-renders.
                            pushEnabled = false
                        }
                        Button("Continue") {
                            Task { @MainActor in
                                // Provider-agnostic consent sweep on toggle-ON —
                                // iterates every push-capable account and
                                // dispatches to the correct OAuth flow.
                                _ = await PushNotificationService.shared.ensurePushConsentForAllAccounts(
                                    auth: OAuthService()
                                )
                            }
                        }
                    } message: {
                        Text("To enable smart push notifications, you need to grant access to email metadata (not bodies) to our servers. The token is stored encrypted.")
                    }

                // Visual-alerts warning — push is ON but iOS won't present new
                // mail because no visual surface (Banners / Lock Screen /
                // Notification Center) is enabled, so the NSE can't run. Shown
                // directly under the toggle; tap deep-links to the notification
                // settings page. Local check (see refreshVisualAlertsWarning).
                if pushEnabled && hasCheckedVisualAlerts && visualAlertsOff {
                    Button {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Alerts are turned off in iOS Settings")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Palette.textColor)
                                Text("New email won't appear immediately because Banners, Lock Screen, and Notification Center are all off for TabMail. Turn on at least one — sound or badge alone isn't enough.")
                                    .font(.footnote)
                                    .foregroundStyle(Palette.textMuted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.textMuted)
                        }
                    }
                    .disabled(!hasTabMailSession)
                }

                Text("When enabled, new emails will be delivered immediately as push notifications — TabMail will still analyze and deliver non-important emails passively in your notification center and only buzz you for the important ones.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("Turning this off discards our server-side copy of the authorization immediately. You can also remove the permission directly from your [Google account](https://myaccount.google.com/permissions) or [Outlook account](https://account.microsoft.com/privacy/app-access). For IMAP accounts, we do not store any credentials on our servers — credentials are transient and disabling immediately logs our servers out. See our [Privacy Policy](https://tabmail.ai/privacy) for details.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .tint(Theme.accent)
            }

            Section("Email Index") {
                Picker("Email Index Limit", selection: $storageBudgetMB) {
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("5 GB").tag(5120)
                    Text("Unlimited").tag(Int.max)
                }
                .onChange(of: storageBudgetMB) { _, newValue in
                    StorageEstimator.budgetMB = newValue
                }

                LabeledContent("Email Index Used") {
                    if let usedBytes = optimizer.measure?.usedBytes {
                        Text(storageUsageText(usedBytes: usedBytes))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }

                if let row = optimizer.row {
                    OptimizeStorageRow(row: row, format: formatStorageBytes) {
                        Task { await optimizer.tap() }
                    }
                }

                Button {
                    showReindexConfirm = true
                } label: {
                    HStack {
                        Label("Smart Reindex", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if reindexTriggered {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    showNukeConfirm = true
                } label: {
                    Label("Delete All Email Index Data", systemImage: "trash.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Email Attachments") {
                Picker("Email Attachments Limit", selection: $attachmentsBudgetMB) {
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("5 GB").tag(5120)
                    Text("Unlimited").tag(Int.max)
                }
                .onChange(of: attachmentsBudgetMB) { _, newValue in
                    BodyAssetStore.attachmentsBudgetMB = newValue
                    // Apply the new cap immediately — non-blocking.
                    Task.detached(priority: .utility) {
                        await BodyAssetMaintenance.evictIfOverCap()
                    }
                }

                LabeledContent("Email Attachments Used") {
                    Text(attachmentsUsageText)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    showAttachmentsWipeConfirm = true
                } label: {
                    Label("Delete All Email Attachments", systemImage: "trash.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text("Oldest messages are automatically pruned from the Email Index when it exceeds its limit. \"Smart Reindex\" re-walks all folders and retries failed body fetches — no data is deleted. \"Delete All Email Index Data\" wipes the search index and re-syncs. Email attachments (inline images and files) live in a separate on-disk cache — the oldest-opened message's assets are evicted when the cap is exceeded. Accounts are preserved by all operations.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Sync Status") {
                // Aggregate sync progress across all accounts
                let allProgress = Array(state.backfillProgressByAccount.values)
                let totalEmails = allProgress.reduce(0) { $0 + $1.totalEmails }
                let totalIndexed = allProgress.reduce(0) { $0 + $1.ftsIndexed }
                let isComplete = !allProgress.isEmpty && allProgress.allSatisfy(\.isFullyComplete)

                if !allProgress.isEmpty {
                    let totalUidScope = allProgress.reduce(0) { $0 + $1.uidTotal }
                    let totalUidWalked = allProgress.reduce(0) { $0 + $1.uidWalked }
                    let allHeadersDone = allProgress.allSatisfy(\.headersDone)
                    // During header walk: show UID progress. After: show FTS indexing.
                    let fraction: Double = (!allHeadersDone && totalUidScope > 0)
                        ? min(1.0, Double(totalUidWalked) / Double(totalUidScope))
                        : (totalEmails > 0 ? min(1.0, Double(totalIndexed) / Double(totalEmails)) : 0.0)
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: fraction)
                            .tint(isComplete ? .green : Theme.accent)
                        HStack {
                            if !allHeadersDone && totalUidScope > 0 {
                                let pct = Int(Double(totalUidWalked) / Double(totalUidScope) * 100)
                                Text("\(totalUidWalked.formatted()) / \(totalUidScope.formatted()) UIDs (\(pct)%)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if totalEmails > 0 {
                                let pct = Int(Double(totalIndexed) / Double(totalEmails) * 100)
                                Text("\(totalIndexed.formatted()) / \(totalEmails.formatted()) indexed (\(pct)%)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Starting sync...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isComplete {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                        if !isComplete, let eta = allProgress.compactMap(\.estimatedSecondsRemaining).max() {
                            Text("~\(formatETA(eta)) remaining")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } else {
                    HStack {
                        Text("Sync idle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                Button {
                    showFastSync = true
                } label: {
                    HStack {
                        Label("Fast Sync Mode", systemImage: "bolt.fill")
                        Spacer()
                        if state.fastSyncModeActive {
                            Text("Active")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }

                Toggle("Backfill on Wi-Fi only", isOn: $backgroundSyncWiFiOnly)

                Text("New mail sync, AI processing, and search indexing always run in the background. This setting controls whether history backfill (backward crawl) requires Wi-Fi. Syncs more aggressively on power and pauses below 20% battery.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            }


            }
            .listRowBackground(Palette.boxBg)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle("Email Accounts")
        .task { await refreshVisualAlertsWarning() }
        .onChange(of: scenePhase) { _, newPhase in
            // Returning from the deep-linked iOS Settings may have enabled a
            // visual surface — re-check so the warning clears.
            if newPhase == .active { Task { await refreshVisualAlertsWarning() } }
        }
        .onChange(of: pushEnabled) { _, _ in
            // Toggling push on/off changes whether the warning is relevant.
            Task { await refreshVisualAlertsWarning() }
        }
        .alert("Remove Account", isPresented: Binding(
            get: { accountToDelete != nil },
            set: { if !$0 { accountToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { accountToDelete = nil }
            if !accountHeldFiles.isEmpty {
                let held = accountHeldFiles
                Button(SavedPutBackFilesWarning.saveTitle(LateCalendarFailureStore.heldFileCount(held))) {
                    accountToDelete = nil
                    exportedHeldFiles = SavedPutBackFilesWarning.export { try LateCalendarFailureStore.exportFiles(held) }
                }
            }
            Button("Remove", role: .destructive) {
                if let account = accountToDelete {
                    accountToDelete = nil
                    let warned = LateCalendarFailureStore.heldFileCount(accountHeldFiles)
                    Task {
                        do {
                            try await AccountManager.shared.removeAccount(account, warnedSavedFiles: warned)
                        } catch is AccountRemovalSavedFilesGrew {
                            // More files were saved since the warning: warn again with the new
                            // count and Save File, nothing removed (#718).
                            accountHeldFiles = await LateCalendarFailureStore.heldFiles(accountId: account.id)
                            accountToDelete = account
                        } catch let error as AccountRemovalError {
                            BackgroundSyncLogger.logDebug("[Settings] Account removal completed with derived cleanup failure: \(error)")
                            settingsErrorMessage = error.localizedDescription
                            showSettingsError = true
                        } catch {
                            BackgroundSyncLogger.logDebug("[Settings] Account removal failed before commit: \(error)")
                            settingsErrorMessage = "TabMail couldn’t remove the account’s local data. Nothing was removed. Please try again."
                            showSettingsError = true
                        }
                    }
                }
            }
        } message: {
            let count = LateCalendarFailureStore.heldFileCount(accountHeldFiles)
            if count > 0 {
                Text(SavedPutBackFilesWarning.accountRemovalMessage(count, email: accountToDelete?.emailAddress ?? "this account"))
            } else {
                Text("This will remove \(accountToDelete?.emailAddress ?? "this account") and all its local data.")
            }
        }
        .sheet(item: $exportedHeldFiles) { export in
            SavedPutBackFilesWarning.sheet(export)
        }
        .task {
            await loadOldMessageCount()
        }
        .task { await optimizer.refresh() }
        // The tap's steps run only while Settings shows the row.
        .onDisappear { optimizer.stop() }
        .onChange(of: DatabaseUpgrade.shared.isPresented) { _, isPresented in
            // The upgrade's screen closed: measure again (its VACUUM gives the empty pages back).
            if !isPresented { Task { await optimizer.refresh() } }
        }
        .alert("Archive Old Emails?", isPresented: $showArchiveConfirm) {
            Button("Continue") {
                showArchiveFinalConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move \(oldMessageCount) email\(oldMessageCount == 1 ? "" : "s") older than \(SyncConfig.archiveAgeDays) days from your inbox to the archive folder. You can still find them by searching.")
        }
        .alert("Are you sure?", isPresented: $showArchiveFinalConfirm) {
            Button("Archive \(oldMessageCount) Emails", role: .destructive) {
                Task { await archiveOldMessages() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be easily undone for large numbers of emails. Your archived emails will remain accessible via search and in the Archive folder.")
        }
        .fullScreenCover(isPresented: $showFastSync) {
            FastSyncView()
        }
        .alert("Smart Reindex?", isPresented: $showReindexConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reindex") {
                Task {
                    await manager.syncEngine.resetCrawlState()
                    for account in navigationStore.accounts {
                        await manager.syncEngine.startBackfill(account: account)
                    }
                    withAnimation {
                        reindexTriggered = true
                    }
                    // Auto-dismiss checkmark after 3s
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation {
                        reindexTriggered = false
                    }
                }
            }
        } message: {
            Text("Re-walks all folders and retries failed body fetches. No data is deleted — existing messages are preserved. This may increase network usage temporarily.")
        }
        .alert("Delete All Email Index Data?", isPresented: $showNukeConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                Task { await nukeDatabase() }
            }
        } message: {
            Text("Downloaded emails, the search index and cached data are deleted, then re-downloaded from your servers. Agent Chat history is deleted permanently — it is stored only on this device and cannot be re-downloaded. Queued message actions that haven't reached your server yet — archive, delete, read, flag — are discarded rather than re-synced. Your Outbox, unsent drafts, queued calendar changes, accounts and credentials are preserved.")
        }
        .alert("Delete All Email Attachments?", isPresented: $showAttachmentsWipeConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                Task { await wipeAttachments() }
            }
        } message: {
            Text("This deletes all cached attachment files and inline images. Inline images will re-download next time you open each affected message; file attachments will re-download on next tap. The Email Index is not touched.")
        }
        .alert("Operation Result", isPresented: $showSettingsError) {
            Button("OK") {}
        } message: {
            Text(settingsErrorMessage)
        }
        .overlay {
            if isNuking || isWipingAttachments {
                Color.black.opacity(0.6).ignoresSafeArea()
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
            }
        }
    }

    /// Refresh the visual-alerts warning shown under the push toggle. True when
    /// iOS has no visual surface enabled (Banners / Lock Screen / Notification
    /// Center) — so visible push can't present and the NSE can't run. Local read.
    @MainActor
    private func refreshVisualAlertsWarning() async {
        let visualOn = await PushNotificationService.shared.visualAlertsEnabled()
        visualAlertsOff = !visualOn
        hasCheckedVisualAlerts = true
    }

    private func wipeAttachments() async {
        isWipingAttachments = true
        // The Email Attachments concept covers BOTH kinds (inline images + file
        // attachments). Wipe both: inline first (also drops MessageBody + flips
        // bodyComplete so the body queue refetches affected messages), then
        // attachments (files + manifest rows only).
        await BodyAssetMaintenance.wipeAll(kind: .inlineImage)
        await BodyAssetMaintenance.wipeAll(kind: .attachment)
        isWipingAttachments = false
    }

    private var attachmentsUsageText: String {
        let bytes = BodyAssetStore.usedBytes
        if bytes == 0 { return "0 MB" }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb < 1 { return String(format: "%.0f KB", Double(bytes) / 1024.0) }
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024.0)
    }

    private func nukeDatabase() async {
        isNuking = true

        // 1. Stop all sync activity
        SyncScheduler.shared.stopPolling()
        defer {
            SyncScheduler.shared.startForegroundPolling()
            isNuking = false
        }

        // 2. Authoritative GRDB transaction (preserve accounts + folders).
        // Nothing in a sibling database is touched unless this commits.
        // It runs in every account's sync turn (ADR-IOS-104, #1062).
        do {
            try await AccountManager.shared.syncEngine.wipeLocalIndex()
        } catch {
            BackgroundSyncLogger.logDebug("[NukeDB] Authoritative database wipe failed: \(error)")
            settingsErrorMessage = "TabMail couldn’t delete the local email data. Nothing was removed. Please try again."
            showSettingsError = true
            return
        }

        var derivedIndexFailures: [String] = []
        // Wipe memory.db (ADR-IOS-034). This local-only store cannot repair
        // itself after chatHistory committed absent, so failure must be visible.
        do {
            try await MemoryIndex.shared.deleteAllThrowing()
        } catch {
            BackgroundSyncLogger.logDebug("[NukeDB] Memory index reset failed after GRDB commit: \(error)")
            derivedIndexFailures.append("conversation memory")
        }
        // 3. Compact GRDB — checkpoint WAL then VACUUM to reclaim disk space. The
        // VACUUM also leaves the database on auto_vacuum = INCREMENTAL (ADR-IOS-121).
        do {
            try await AppDatabase.dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                try DatabaseVacuum.vacuum(db)
            }
        } catch {
            // Compaction is optional after the authoritative rows are gone.
            BackgroundSyncLogger.logDebug("[NukeDB] Database compaction deferred: \(error)")
        }
        BackgroundSyncLogger.logDebug("[NukeDB] Deleted all email data from GRDB")

        // 4. Delete FTS database
        do {
            try await SearchIndex.shared.resetAll()
            BackgroundSyncLogger.logDebug("[NukeDB] Reset FTS database")
        } catch {
            BackgroundSyncLogger.logDebug("[NukeDB] FTS reset failed after GRDB commit: \(error)")
            derivedIndexFailures.append("email search")
        }
        if !derivedIndexFailures.isEmpty {
            settingsErrorMessage = "Email data was deleted, but some local index data could not be cleared. Please try Delete All Email Index Data again."
            showSettingsError = true
        }

        // 5b. Wipe BodyAssetStore — every bodyAsset row now references a deleted
        // messageHeader. Inline / attachment assets are part of the "cached data"
        // the user just opted to wipe, so both kinds go now (rows and files),
        // instead of key by key through the pending-delete list (#1376). The
        // entries the header delete queued there are now moot; the worker drops
        // them without a manifest write (no rows remain under their keys).
        await BodyAssetMaintenance.wipeAllAfterLocalIndexWipe()
        BackgroundSyncLogger.logDebug("[NukeDB] Wiped BodyAssetStore")

        // The VACUUM above and the search database's new file are INCREMENTAL, so
        // the one-time upgrade's banner goes when both now are (ADR-IOS-121).
        await DatabaseUpgrade.shared.refresh()
        // "Email Index Used" and the Optimize Storage row measure again (#1448).
        await optimizer.refresh()

        // 5. `defer` restarts sync — fresh backfill from top — on every exit.
        BackgroundSyncLogger.logDebug("[NukeDB] Sync restarted — backfill will re-walk all folders")
    }

    private func storageUsageText(usedBytes: Int64) -> String {
        let used = formatStorageBytes(usedBytes)
        if storageBudgetMB == Int.max {
            return "\(used) (unlimited)"
        }
        let limit = formatStorageMB(Double(storageBudgetMB))
        return "\(used) / \(limit)"
    }

    private func loadOldMessageCount() async {
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: Date()) ?? Date()
        let inboxFolderIds = Set(navigationStore.folders.filter { $0.role == .inbox }.map(\.id))
        guard !inboxFolderIds.isEmpty else { return }

        oldMessageCount = (try? await Self.oldMessageCount(
            folderIds: inboxFolderIds,
            archiveCutoff: archiveCutoff,
            database: AppDatabase.dbPool
        )) ?? 0
    }

    /// The Settings `.task` is main-actor isolated. Keep the database wait in the
    /// async GRDB overload so opening Settings never synchronously occupies the UI
    /// thread, even if the reader pool is contended.
    @MainActor
    static func oldMessageCount(
        folderIds: Set<String>,
        archiveCutoff: Date,
        database: PrioritizedDatabase
    ) async throws -> Int {
        try await database.read { db in
            try MessageHeader
                .filter(folderIds.contains(Column("folderId")))
                .filter(Column("date") < archiveCutoff)
                .fetchCount(db)
        }
    }

    private func archiveOldMessages() async {
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: Date()) ?? Date()
        let inboxFolderIds = Set(navigationStore.folders.filter { $0.role == .inbox }.map(\.id))
        guard !inboxFolderIds.isEmpty else { return }

        guard let totalArchived = await Self.archiveOldMessages(
            inboxFolderIds: inboxFolderIds, archiveCutoff: archiveCutoff) else { return }

        BackgroundSyncLogger.logDebug("[ArchiveOld] Archived \(totalArchived) messages older than \(SyncConfig.archiveAgeDays) days")

        // Refresh state
        isLargeInbox = false
        UserDefaults.standard.set(false, forKey: "isLargeInbox")
        oldMessageCount = 0
    }

    /// The sweep's read: every message dated before `cutoff` in `folderIds`,
    /// one folder after another, each oldest first. Each statement reads one
    /// page of one folder (`oldInboxPage`), so no statement reads more than
    /// `pageSize` rows and none sorts across folders. All pages are read in the
    /// caller's one read transaction, so they come from one snapshot.
    nonisolated static func oldInboxMessages(
        _ db: Database, folderIds: Set<String>, cutoff: Date, pageSize: Int
    ) throws -> [MessageHeader] {
        var messages: [MessageHeader] = []
        for folderId in folderIds.sorted() {
            var after: OldInboxCursor?
            while true {
                let page = try oldInboxPage(db, folderId: folderId, cutoff: cutoff, after: after, limit: pageSize)
                messages += page.headers
                guard page.headers.count == pageSize, let next = page.next else { break }
                after = next
            }
        }
        return messages
    }

    /// Where the next page of `oldInboxPage` starts: the `date` value stored in
    /// the previous page's last row, exactly as read, and that row's rowid.
    struct OldInboxCursor {
        let date: DatabaseValue
        let rowid: Int64
    }

    /// One page of the sweep's read: `folderId`'s messages dated before
    /// `cutoff`, oldest first, starting after `after`, at most `limit` of them.
    ///
    /// It walks `messageHeader_folderId_date` within the one folder, so it reads
    /// only the rows it returns and needs no sort: the index holds them in
    /// `(date, rowid)` order. `INDEXED BY` pins that index because the planner
    /// can choose the plain `date` index instead, and then walks every folder's
    /// mail older than the cutoff to find the inbox's. The cursor carries the
    /// stored `date` value as read, so a page boundary inside a run of equal
    /// dates neither skips nor repeats a row. `nonisolated`: it runs inside the
    /// database's read, off the main actor.
    nonisolated static func oldInboxPage(
        _ db: Database, folderId: String, cutoff: Date, after: OldInboxCursor?, limit: Int
    ) throws -> (headers: [MessageHeader], next: OldInboxCursor?) {
        var sql = """
            SELECT *, rowid AS sweepRowid FROM messageHeader INDEXED BY messageHeader_folderId_date
            WHERE folderId = ? AND date < ?
            """
        var arguments: StatementArguments = [folderId, cutoff]
        if let after {
            sql += " AND (date, rowid) > (?, ?)"
            arguments += [after.date, after.rowid]
        }
        sql += " ORDER BY date, rowid LIMIT ?"
        arguments += [limit]
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        guard let last = rows.last else { return ([], nil) }
        let headers = try rows.map { try MessageHeader(row: $0) }
        return (headers, OldInboxCursor(date: last["date"], rowid: last["sweepRowid"]))
    }

    /// The "Archive old messages" sweep. Returns how many rows it asked to move,
    /// or nil when the read failed or found no old row (nothing was attempted).
    ///
    /// It reads each inbox folder's old messages in pages (`oldInboxMessages`),
    /// then moves them as one operation per account, as before: one Undo
    /// restores an account's whole sweep.
    ///
    /// The sweep is a gesture on the rows it reads (ADR-IOS-115): the folder
    /// reset stamp is taken BEFORE the read and bound around the mark-read and
    /// the move, so a UIDVALIDITY reset that lands between the read and the
    /// move refuses them instead of acting on the replacement email re-seated
    /// at a row's id. `beforeRead` runs after the stamp and before the read,
    /// `afterRead` once the rows are read; both are test seams for those windows
    /// and production passes nothing.
    @MainActor
    @discardableResult
    static func archiveOldMessages(
        inboxFolderIds: Set<String>,
        archiveCutoff: Date,
        beforeRead: () async -> Void = {},
        afterRead: () async -> Void = {}
    ) async -> Int? {
        let stamp = FolderResetGeneration.current()
        await beforeRead()
        guard let oldMessages = try? await AppDatabase.dbPool.read({ db in
            try Self.oldInboxMessages(db, folderIds: inboxFolderIds, cutoff: archiveCutoff,
                                      pageSize: SyncConfig.archiveOldReadPageSize)
        }), !oldMessages.isEmpty else { return nil }
        await afterRead()

        let byAccount = Dictionary(grouping: oldMessages, by: \.accountId)
        var totalArchived = 0

        for (accountId, messages) in byAccount {
            guard let archivePath = try? await AppDatabase.dbPool.read({ db in
                try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.archive.rawValue).fetchOne(db)?.path
            }) else {
                BackgroundSyncLogger.logDebug("[ArchiveOld] No archive folder for account \(accountId)")
                continue
            }
            if let first = messages.first {
                // Overlay-adjusted for the UndoableAction ONLY — a raw fetchAll
                // snapshot predates any still-queued gesture cycle's isRead/
                // isFlagged/actionTag, and undo would silently revert it (the
                // exact bug `overlayAdjustedSnapshot` fixes at the inbox gesture
                // sites; see AccountManager.overlayAdjustedSnapshot). The
                // manager.move call below keeps the raw structs — it re-resolves
                // fresh headers by id internally regardless.
                let undoMessages = messages.map { AccountManager.shared.overlayAdjustedSnapshot($0) }
                UndoService.shared.push(UndoableAction(
                    type: .move(fromPath: first.folderPath, toPath: archivePath), messages: undoMessages,
                    originalFolderId: first.folderId,
                    originalFolderPath: first.folderPath,
                    accountId: accountId, timestamp: Date()
                ))
            }
            // Mark-as-read-on-archive/delete (Settings → User Interface,
            // default ON). Strictly before the move and in the same awaited
            // sequence: a move changes the address the read op would have to
            // name. See `AccountManager.markReadBeforeRoleMove`.
            await FolderResetGeneration.$gestureStamp.withValue(stamp) {
                await AccountManager.shared.markReadBeforeRoleMove(ids: messages.map(\.id))
                await AccountManager.shared.move(messages, to: archivePath)
            }
            totalArchived += messages.count
        }
        return totalArchived
    }

    private func formatStorageMB(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    private func formatStorageBytes(_ bytes: Int64) -> String {
        formatStorageMB(Double(bytes) / (1024 * 1024))
    }

    private func formatCount(_ n: Int) -> String {
        switch n {
        case 1_000_000...:
            let m = Double(n) / 1_000_000
            return m >= 10 ? "\(Int(m))M" : String(format: "%.1fM", m)
        case 1_000...:
            let k = Double(n) / 1_000
            return k >= 10 ? "\(Int(k))k" : String(format: "%.1fk", k)
        default:
            return "\(n)"
        }
    }

    private func formatETA(_ seconds: Double) -> String {
        if seconds < 60 { return "<1 min" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        let hours = Int(seconds / 3600)
        let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return mins > 0 ? "\(hours) hr \(mins) min" : "\(hours) hr"
    }

    @ViewBuilder
    private func iconFor(_ provider: AccountProvider) -> some View {
        switch provider {
        case .gmail:
            Image("GoogleLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
        case .outlook:
            Image("MicrosoftLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
        case .icloud:
            Image(systemName: "apple.logo")
        case .imap:
            Image(systemName: "envelope")
        case .caldav:
            Image(systemName: "calendar")
        }
    }

}
