/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB
import UIKit

struct SettingsView: View {
    @Environment(NavigationStore.self) private var navigationStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var accountToDelete: Account?
    @State private var settingsErrorMessage = ""
    @State private var showSettingsError = false
    @AppStorage(SyncScheduler.wifiOnlyKey) private var backgroundSyncWiFiOnly = true
    @AppStorage("isLargeInbox") private var isLargeInbox = false
    @State private var storageBudgetMB: Int = StorageEstimator.budgetMB
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
                            if state.backfillCapReachedAccounts.contains(account.id) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                            }
                            Text(account.provider.displayName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            accountToDelete = account
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
                Toggle("Enable Inbox Push Notifications", isOn: $pushEnabled)
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
                    Text(storageUsageText)
                        .foregroundStyle(.secondary)
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
                let totalUnindexed = allProgress.reduce(0) { $0 + $1.unindexedBodyCount }
                let isComplete = !allProgress.isEmpty && allProgress.allSatisfy(\.isFullyComplete)

                if !allProgress.isEmpty {
                    let totalUidScope = allProgress.reduce(0) { $0 + $1.uidTotal }
                    let totalUidWalked = allProgress.reduce(0) { $0 + $1.uidWalked }
                    let allHeadersDone = allProgress.allSatisfy(\.headersDone)
                    // During header walk: show UID progress. After: show FTS indexing.
                    let fraction: Double = isComplete ? 1.0 : (!allHeadersDone && totalUidScope > 0)
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
                            } else if isComplete && totalUnindexed > 0 {
                                Text(BodyIndexingProgressText.completion(unindexedCount: totalUnindexed))
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
            Button("Remove", role: .destructive) {
                if let account = accountToDelete {
                    accountToDelete = nil
                    Task {
                        do {
                            try await AccountManager.shared.removeAccount(account)
                        } catch let error as AccountRemovalError {
                            print("[Settings] Account removal completed with derived cleanup failure: \(error)")
                            settingsErrorMessage = error.localizedDescription
                            showSettingsError = true
                        } catch {
                            print("[Settings] Account removal failed before commit: \(error)")
                            settingsErrorMessage = "TabMail couldn’t remove the account’s local data. Nothing was removed. Please try again."
                            showSettingsError = true
                        }
                    }
                }
            }
        } message: {
            Text("This will remove \(accountToDelete?.emailAddress ?? "this account") and all its local data.")
        }
        .task {
            await loadOldMessageCount()
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

    /// The exact GRDB statements "Delete All Email Index Data" runs, in order.
    ///
    /// Named and separated so the boundary of this gesture is a thing that can be
    /// EXECUTED by a test against the real schema, rather than a list buried in a
    /// closure that no test can reach.
    ///
    /// ⚠ **`outboxMessage` IS NOT HERE, and that is the point.** It was, until
    /// 2026-08-05. An Outbox row is a send the user composed that has **never
    /// reached a server**, so it cannot "re-sync automatically from your servers"
    /// — deleting it destroyed the message outright while the confirmation alert
    /// promised the opposite. `Companion/Rules/Active/never-drop-user-intention.md`
    /// states the limit of the lifecycle carve-out outright: it "does not extend
    /// past queue state: Outbox sends, user-authored drafts, bodies, attachments
    /// and FTS content are never dropped under it." An `outboxMessage` row is also
    /// self-contained — it carries its own payload and its own attachment subtree
    /// and references none of the tables below — so keeping it costs no
    /// consistency.
    ///
    /// ⚠ **`pendingCalendarOperation` IS NOT HERE EITHER, for the same reason.**
    /// It was, until 2026-08-05. A queued `.create` carries the user's authored
    /// event — title, time, location, attendees — in its `argumentsJSON` for an
    /// event that exists on **no server**, and a queued `.edit` carries the new
    /// values the user chose. Deleting those destroys authored content that
    /// exists nowhere else, exactly as `outboxMessage` did.
    ///
    /// It also has none of `pendingOperation`'s consistency justification. Its
    /// only foreign key is `accountId → account`, and accounts survive this
    /// transaction (`v8_createPendingCalendarOperation`); its `eventId` and
    /// `calendarId` name SERVER-side resources; and the list below contains no
    /// calendar table at all. So a calendar op addresses nothing this wipe
    /// destroys, and purging it bought exactly zero consistency — the same
    /// asymmetry that made the `outboxMessage` line indefensible.
    ///
    /// `pendingOperation` DOES stay — but **not `.saveDraft`**, and that
    /// exception is the same principle a third time (added 2026-08-05).
    ///
    /// The consistency argument for purging `pendingOperation` is that those rows
    /// address `messageHeader` rows this same transaction destroys, so leaving
    /// them would queue mutations against addresses that no longer exist locally.
    /// **That argument does not reach `.saveDraft`.** A save producer addresses a
    /// `draft` row by `draftId` plus its `instanceEpoch`
    /// (`AccountManager.executeOperation`'s `.saveDraft` arm →
    /// `DraftStore.pushDraftToServer(draftId:expectedInstanceEpoch:…)`); it never
    /// reads the placeholder header, and `draft` is not in this list.
    ///
    /// And it is the ONLY route back. For an authored draft that has never
    /// reached a server, this transaction deletes the placeholder `messageHeader`
    /// that surfaces it in the Drafts folder and the `messageBody` beside it,
    /// while nothing re-downloads it, because it is on no server to re-download
    /// from. The `draft` row survives but no view lists it and no drain pushes
    /// it: purging the producer strands authored content in a table nothing
    /// reads. Keeping the producer means the very next drain pushes the draft to
    /// the server, after which ordinary sync restores the header — i.e. keeping
    /// it is precisely what makes the alert's "re-downloaded from your servers"
    /// true of drafts.
    ///
    /// The filter interpolates `OperationType.saveDraft.rawValue` rather than a
    /// literal so renaming the case cannot silently un-protect the drafts.
    nonisolated static let localIndexWipeStatements: [String] = [
        "DELETE FROM messageHeader",
        "DELETE FROM messageBody",
        "DELETE FROM messageAICache",
        // ⚠ Agent Chat turns are user-authored and exist on NO server, so these
        // two lines are a PERMANENT deletion, not a cache drop. They are kept
        // deliberately — this gesture also wipes `memory.db`
        // (`MemoryIndex.shared.deleteAllThrowing()` in `nukeDatabase`), and `chatHistory`
        // IS that memory store, so excising chat here would leave the two halves
        // of one feature inconsistent; chat turns also carry raw `[Email](N)`
        // references into the `messageHeader` rows this transaction destroys.
        // What was wrong was that the confirmation alert never said so. The alert
        // now names Agent Chat as permanently deleted (`IOS-SETTINGS-001`), which
        // is the consent defect actually at issue. Do not remove these lines
        // without also revisiting `MemoryIndex.deleteAllThrowing()`.
        "DELETE FROM chatTurn",
        "DELETE FROM chatHistory",
        "DELETE FROM pendingOperation WHERE type != '\(OperationType.saveDraft.rawValue)'",
        "DELETE FROM pendingRender",
        // Reset folder cursors so backfill re-walks from top
        """
        UPDATE folder SET
            backfillComplete = 0,
            oldestSyncedDate = NULL,
            backfillUidCursor = NULL,
            backfillPageToken = NULL
        WHERE path != ''
        """
    ]

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
        do {
            try await AppDatabase.dbPool.write { db in
                try Self.localIndexWipeTxn(db)
            }
        } catch {
            print("[NukeDB] Authoritative database wipe failed: \(error)")
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
            print("[NukeDB] Memory index reset failed after GRDB commit: \(error)")
            derivedIndexFailures.append("conversation memory")
        }
        // 3. Reset sync-related UserDefaults
        UserDefaults.standard.set(false, forKey: "ccBccBackfillDone")

        // 4. Compact GRDB — checkpoint WAL then VACUUM to reclaim disk space
        do {
            try await AppDatabase.dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                try db.execute(sql: "VACUUM")
            }
        } catch {
            // Compaction is optional after the authoritative rows are gone.
            print("[NukeDB] Database compaction deferred: \(error)")
        }
        print("[NukeDB] Deleted all email data from GRDB")

        // 5. Delete FTS database
        do {
            try await SearchIndex.shared.resetAll()
            print("[NukeDB] Reset FTS database")
        } catch {
            print("[NukeDB] FTS reset failed after GRDB commit: \(error)")
            derivedIndexFailures.append("email search")
        }
        if !derivedIndexFailures.isEmpty {
            settingsErrorMessage = "Email data was deleted, but some local index data could not be cleared. Please try Delete All Email Index Data again."
            showSettingsError = true
        }

        // 5b. Sweep BodyAssetStore — every bodyAsset row now references a
        // deleted messageHeader, so the cross-DB sweep deletes them. The
        // associated files (no row → orphan after the row delete) are then
        // removed by the same sweep's filesystem walk. Inline / attachment
        // assets are part of the "cached data" the user just opted to wipe.
        await BodyAssetMaintenance.pruneOrphans()
        print("[NukeDB] Pruned BodyAssetStore orphans")

        // 6. `defer` restarts sync — fresh backfill from top — on every exit.
        print("[NukeDB] Sync restarted — backfill will re-walk all folders")
    }

    /// Execute the user-visible local-index deletion as one transaction.
    nonisolated static func localIndexWipeTxn(_ db: Database) throws {
        for sql in localIndexWipeStatements {
            try db.execute(sql: sql)
        }
    }

    private var storageUsageText: String {
        let usedMB = StorageEstimator.totalSizeMB()
        let used = formatStorageMB(usedMB)
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

        guard let oldMessages = try? await AppDatabase.dbPool.read({ db in
            try MessageHeader
                .filter(inboxFolderIds.contains(Column("folderId")))
                .filter(Column("date") < archiveCutoff)
                .order(Column("date").asc)
                .fetchAll(db)
        }), !oldMessages.isEmpty else { return }

        let byAccount = Dictionary(grouping: oldMessages, by: \.accountId)
        var totalArchived = 0

        for (accountId, messages) in byAccount {
            guard let archivePath = try? await AppDatabase.dbPool.read({ db in
                try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.archive.rawValue).fetchOne(db)?.path
            }) else {
                print("[ArchiveOld] No archive folder for account \(accountId)")
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
            await AccountManager.shared.markReadBeforeRoleMove(ids: messages.map(\.id))
            await AccountManager.shared.move(messages, to: archivePath)
            totalArchived += messages.count
        }

        print("[ArchiveOld] Archived \(totalArchived) messages older than \(SyncConfig.archiveAgeDays) days")

        // Refresh state
        isLargeInbox = false
        UserDefaults.standard.set(false, forKey: "isLargeInbox")
        oldMessageCount = 0
    }

    private func formatStorageMB(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
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
