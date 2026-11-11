/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

struct AccountDetailView: View {
    @State private var account: Account
    @Environment(NavigationStore.self) private var navigationStore
    private var manager: AccountManager { AccountManager.shared }
    private var state: AccountManagerState { AccountManagerState.shared }
    @State private var showPasswordPrompt = false
    /// The account as it was when the password prompt opened; the update works
    /// from it.
    @State private var passwordPromptAccount: Account?
    @State private var newPassword = ""
    @State private var isReauthenticating = false
    @State private var reauthError: String?
    @State private var showResetConfirmation = false
    @State private var isResetting = false
    @State private var resetError: String?
    @State private var folders: [Folder] = []
    @State private var signatureText = ""
    @FocusState private var signatureFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var dbPool: PrioritizedDatabase { AppDatabase.dbPool }

    /// The assignable roles (excluding .custom which is the default)
    private let assignableRoles: [FolderRole] = [.inbox, .sent, .drafts, .archive, .trash, .spam]

    init(account: Account) {
        self._account = State(initialValue: account)
    }

    private var hasAuthError: Bool {
        state.authFailedAccounts.contains(account.id)
    }

    @ViewBuilder
    private var accountSaveFailureSection: some View {
        let failures = navigationStore.accountFieldPersistence.failures(accountId: account.id)
        if !failures.isEmpty {
            Section {
                ForEach(failures) { failure in
                    HStack {
                        Label(
                            "\(failure.field.displayLabel) couldn’t be saved",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        Spacer()
                        Button(failure.isRetrying ? "Retrying…" : "Retry") {
                            navigationStore.accountFieldPersistence.retry(failure.key)
                        }
                        .disabled(failure.isRetrying)
                    }
                }
            } header: {
                Text("Unsaved Account Changes")
            } footer: {
                Text("Your edits remain visible. Retry each field when you’re ready.")
            }
        }
    }

    var body: some View {
        List {
            Group {
            // Auth error banner
            if hasAuthError {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Authentication failed. Please re-authenticate.")
                            .font(.subheadline)
                    }
                    reauthButton
                }
            }

            Section {
                LabeledContent("Name") {
                    TextField("Name", text: Binding(
                        get: { account.displayName },
                        set: { newValue in
                            applyAccountField(.displayName, value: .text(newValue)) {
                                account.displayName = newValue
                            }
                        }
                    ))
                    .multilineTextAlignment(.trailing)
                    .textContentType(.name)
                }
                LabeledContent("Email") {
                    TextField("Email", text: Binding(
                        get: { account.emailAddress },
                        set: { newValue in
                            applyAccountField(.emailAddress, value: .text(newValue)) {
                                account.emailAddress = newValue
                            }
                        }
                    ))
                    .multilineTextAlignment(.trailing)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                }
                LabeledContent("Provider", value: account.provider.displayName)
                if let lastSync = account.lastSyncedAt {
                    LabeledContent("Last Synced") {
                        Text("\(lastSync, style: .relative) ago")
                    }
                }

                if navigationStore.accounts.count > 1 {
                    if account.isPrimary {
                        HStack {
                            Text("Primary Account")
                            Spacer()
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .font(.subheadline)
                        }
                    } else {
                        Button {
                            Task { await navigationStore.setPrimaryAccount(account) }
                            account.isPrimary = true
                        } label: {
                            Text("Make Primary")
                        }
                    }
                }
            } header: {
                Text("Account Info")
            } footer: {
                if navigationStore.accounts.count > 1 {
                    Text("The primary account is used as the default sender when composing new emails.")
                }
            }

            accountSaveFailureSection

            // Sync progress — shown when backfill is not yet complete for this account
            if folders.contains(where: { !$0.backfillComplete && !$0.path.isEmpty }) {
                Section("Sync Progress") {
                    if let progress = state.backfillProgressByAccount[account.id] {
                        ProgressView(value: progress.fractionComplete)
                            .tint(Theme.accent)
                        if progress.totalEmails > 0 {
                            let pct = Int(Double(progress.ftsIndexed) / Double(progress.totalEmails) * 100)
                            LabeledContent("Indexed") {
                                Text("\(progress.ftsIndexed)/\(progress.totalEmails) (\(pct)%)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let eta = progress.estimatedSecondsRemaining {
                            LabeledContent("Estimated Time") {
                                Text("~\(formatETA(eta))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if progress.isPaused {
                            HStack {
                                Image(systemName: "pause.circle.fill")
                                    .foregroundStyle(.orange)
                                Text("Paused")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    DisclosureGroup("Folder Details") {
                        ForEach(folders.filter { !$0.path.isEmpty }, id: \.id) { folder in
                            HStack {
                                Image(systemName: folder.backfillComplete ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(folder.backfillComplete ? .green : .secondary)
                                    .font(.caption)
                                Text(folder.name)
                                    .font(.caption)
                                Spacer()
                                if folder.backfillComplete {
                                    Text("Done")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else if let oldest = folder.oldestSyncedDate {
                                    Text("to \(oldest, format: .dateTime.month().year())")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Pending")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }

            Section("Signature") {
                // Bound to local @State and committed on focus loss — saving on
                // every keystroke (DB write + navigationStore mutation) invalidates
                // the view mid-edit and resets the TextEditor caret to the end.
                TextEditor(text: $signatureText)
                    .focused($signatureFocused)
                    .scrollDisabled(true)
                    .frame(minHeight: 40)

                Toggle("Place below quote", isOn: Binding(
                    get: { account.signatureBelowQuote },
                    set: { newValue in
                        applyAccountField(.signatureBelowQuote, value: .boolean(newValue)) {
                            account.signatureBelowQuote = newValue
                        }
                    }
                ))
                .font(.subheadline)
            }



            if account.provider == .imap {
                Section("Server Settings") {
                    LabeledContent("Username") {
                        TextField("Same as email", text: Binding(
                            get: { account.imapUsername ?? "" },
                            set: { newValue in
                                let val = newValue.isEmpty ? nil : newValue
                                applyAccountField(.imapUsername, value: .text(val)) {
                                    account.imapUsername = val
                                }
                            }
                        ))
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    }
                    LabeledContent("IMAP Host", value: account.imapHost ?? "—")
                    LabeledContent("IMAP Port", value: "\(account.imapPort ?? 993)")
                    LabeledContent("SMTP Host", value: account.smtpHost ?? "—")
                    LabeledContent("SMTP Port", value: "\(account.smtpPort ?? 587)")
                }
            }

            Section("Authentication") {
                reauthButton
            }

            // Gmail folder roles are standardized — don't allow reassignment
            if account.provider != .gmail {
                Section {
                    ForEach(assignableRoles, id: \.self) { role in
                        let assigned = foldersWithRole(role)
                        HStack {
                            Label(roleLabel(role), systemImage: roleIcon(role))
                            Spacer()
                            if assigned.count > 1 {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("Multiple folders assigned")
                            }
                            Text(folderName(for: role))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .contextMenu {
                            ForEach(folders, id: \.id) { folder in
                                Button {
                                    assignRole(role, to: folder)
                                } label: {
                                    if folder.role == role {
                                        Label(folder.name, systemImage: "checkmark")
                                    } else {
                                        Text(folder.name)
                                    }
                                }
                            }
                            Button("None") {
                                clearRole(role)
                            }
                        }
                    }
                } header: {
                    Text("Folder Roles")
                } footer: {
                    Text("Long press a role to change which folder is assigned to it. If a warning appears, two folders share the same role — pick the correct one above, or change a folder's role in “All Folders” below.")
                }

                Section("All Folders") {
                    ForEach(sortedFolders, id: \.id) { folder in
                        HStack {
                            Label(folder.name, systemImage: roleIcon(folder.role))
                            Spacer()
                            if folder.role != .custom {
                                Text(roleLabel(folder.role))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Menu {
                                ForEach(assignableRoles, id: \.self) { role in
                                    Button {
                                        assignRole(role, to: folder)
                                    } label: {
                                        if folder.role == role {
                                            Label(roleLabel(role), systemImage: "checkmark")
                                        } else {
                                            Text(roleLabel(role))
                                        }
                                    }
                                }
                                Divider()
                                Button("No Role") {
                                    setFolderRole(folder, role: .custom)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        if isResetting {
                            ProgressView()
                                .padding(.leading, 4)
                            Text("Resetting...")
                        } else {
                            Text("Reset All Message Data")
                        }
                    }
                }
                .disabled(isResetting)
            } footer: {
                Text("Deletes all cached messages and search index for this account. Messages will re-sync from the server. Account settings are preserved.")
            }
            }
            .listRowBackground(Palette.boxBg)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .dismissKeyboardOnTap()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(account.emailAddress)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            signatureText = account.signature ?? ""
            reloadAccount()
            reloadFolders()
        }
        .onChange(of: signatureFocused) { _, focused in
            if !focused { commitSignature() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { commitSignature() }
        }
        .onDisappear { commitSignature() }
        .onReceive(NotificationCenter.default.publisher(for: .unreadCountsDidChange).debounce(for: .seconds(0.3), scheduler: RunLoop.main)) { _ in
            reloadAccount()
            reloadFolders()
        }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundDataDidChange).debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
            reloadAccount()
            reloadFolders()
        }
        .confirmationDialog(
            "Reset Message Data?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset All Messages", role: .destructive) {
                resetMessageData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all cached messages, search index, and AI summaries for \(account.emailAddress). Messages will be re-downloaded from the server on next sync.")
        }
        .alert("Reset Message Data", isPresented: Binding(
            get: { resetError != nil },
            set: { if !$0 { resetError = nil } }
        )) {
            Button("OK") { resetError = nil }
        } message: {
            Text(resetError ?? "")
        }
        .alert("Update Password", isPresented: $showPasswordPrompt) {
            SecureField("New Password", text: $newPassword)
            Button("Cancel", role: .cancel) {
                newPassword = ""
                passwordPromptAccount = nil
            }
            Button("Update") { updatePassword() }
        } message: {
            Text(PasswordPrompt.message(for: passwordPromptAccount ?? account))
        }
        .alert("Re-authentication Failed", isPresented: Binding(
            get: { reauthError != nil },
            set: { if !$0 { reauthError = nil } }
        )) {
            Button("OK") { reauthError = nil }
        } message: {
            Text(reauthError ?? "")
        }
    }

    // MARK: - GRDB Helpers

    private func applyAccountField(
        _ field: AccountEditableField,
        value: AccountEditableValue,
        updateUI: () -> Void
    ) {
        let accountId = account.id
        let database = dbPool
        updateUI()
        // Propagate immediately so re-navigation cannot reinitialize this view
        // from stale in-memory data while persistence is queued.
        if let index = navigationStore.accounts.firstIndex(where: { $0.id == accountId }) {
            navigationStore.accounts[index] = account
        }
        navigationStore.accountFieldPersistence.accept(
            accountId: accountId,
            field: field,
            value: value,
            persist: {
                try await AccountFieldPersistenceStore.persist(
                    accountId: accountId,
                    field: field,
                    value: value,
                    database: database
                )
            }
        )
    }

    /// Persist the signature if it changed. Called on focus loss, view
    /// dismissal, and app backgrounding — never per keystroke.
    private func commitSignature() {
        let sig = signatureText.isEmpty ? nil : signatureText
        guard sig != account.signature else { return }
        applyAccountField(.signature, value: .text(sig)) {
            account.signature = sig
        }
    }

    /// Refresh sync-managed fields (lastSyncedAt, etc.) from DB without
    /// clobbering user-edited fields (signature, signatureBelowQuote, displayName).
    private func reloadAccount() {
        guard let fresh = try? dbPool.read({ db in
            try Account.fetchOne(db, key: account.id)
        }) else { return }
        account.lastSyncedAt = fresh.lastSyncedAt
        account.lastFullSyncAt = fresh.lastFullSyncAt
        account.lastHistoryId = fresh.lastHistoryId
        account.isActive = fresh.isActive
        account.isPrimary = fresh.isPrimary
    }

    private func reloadFolders() {
        folders = (try? dbPool.read { db in
            try Folder.filter(Column("accountId") == account.id).order(Column("name")).fetchAll(db)
        }) ?? []
    }

    private func setFolderRole(_ folder: Folder, role: FolderRole) {
        let inboxChanged = try? dbPool.write { db in
            try FolderRoleEdit.set(role, folderId: folder.id, accountId: account.id, db: db)
        }
        reloadFolders()
        syncIfInboxChanged(inboxChanged)
    }

    /// After a role edit that changed which folder is the Inbox, which marked the
    /// account's full sync due (`FolderRoleEdit`), starts the account's sync with
    /// the account read back from the database, so that pass runs the full sync.
    private func syncIfInboxChanged(_ inboxChanged: Bool?) {
        guard inboxChanged == true else { return }
        reloadAccount()
        let account = account
        Task { _ = try? await manager.syncAccount(account) }
    }

    // MARK: - Re-authentication

    @ViewBuilder
    private var reauthButton: some View {
        if isReauthenticating {
            HStack {
                ProgressView()
                Text("Authenticating...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            switch account.provider.signInMethod {
            case .password:
                Button {
                    passwordPromptAccount = account
                    showPasswordPrompt = true
                } label: {
                    Label("Update Password", systemImage: "key")
                }
            case .oauth:
                Button {
                    reauthenticateOAuth()
                } label: {
                    Label("Re-authenticate", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func updatePassword() {
        let password = newPassword
        newPassword = ""
        guard let promptAccount = passwordPromptAccount else { return }
        passwordPromptAccount = nil
        guard !password.isEmpty else { return }
        isReauthenticating = true
        Task {
            do {
                try await manager.updatePassword(password, for: promptAccount)
                try await manager.syncAccount(promptAccount)
            } catch {
                if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Reauth] Password update failed: \(error)") }
                if let line = AccountReauthAlert.passwordUpdateLine(for: error, host: promptAccount.imapHost ?? "") {
                    reauthError = line
                }
            }
            isReauthenticating = false
        }
    }

    private func reauthenticateOAuth() {
        isReauthenticating = true
        Task {
            do {
                try await manager.reauthenticateOAuth(for: account)
                try await manager.syncAccount(account)
            } catch {
                if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Reauth] Re-authentication failed: \(error)") }
                if let line = AccountReauthAlert.oauthLine(for: error) {
                    reauthError = line
                }
            }
            isReauthenticating = false
        }
    }

    // MARK: - Reset

    private func resetMessageData() {
        isResetting = true
        Task {
            let acctId = account.id
            do {
                // This is the authoritative boundary. A failure rolls the whole
                // account-scoped reset back and stops every derived cleanup.
                try await dbPool.write { db in
                    try Self.resetMessageDataTxn(db, accountId: acctId)
                }
            } catch {
                BackgroundSyncLogger.logDebug("[Reset] Account-scoped database reset failed: \(error)")
                resetError = "TabMail couldn’t delete the local message data. Nothing was removed. Please try again."
                isResetting = false
                return
            }

            var derivedCleanupFailed = false
            do {
                try await SearchIndex.shared.removeMessagesForAccount(accountId: acctId)
            } catch {
                derivedCleanupFailed = true
                BackgroundSyncLogger.logDebug("[Reset] Account-scoped search cleanup failed: \(error)")
            }

            BackgroundSyncLogger.logDebug("[Reset] Cleared all message data for \(account.emailAddress)")
            await manager.resetBackfill(accountId: acctId)
            reloadFolders()
            _ = try? await manager.syncAccount(account)

            if derivedCleanupFailed {
                resetError = "Message data was reset, but the search index could not be cleared. Reindexing or the next sync will repair it."
            }
            isResetting = false
        }
    }

    /// Authoritative account-scoped reset in one GRDB transaction. Split-out
    /// for a real injected-ABORT test; no FTS/memory/UI side effect belongs here.
    nonisolated static func resetMessageDataTxn(_ db: Database, accountId: String) throws {
        try db.execute(
            sql: "DELETE FROM messageHeader WHERE accountId = ?",
            arguments: [accountId]
        )
        // Stage D (`v70_dropMessageBodyHeaderFK`) removed the body FK, so the
        // content-key prefix delete must remain in this same transaction.
        try db.execute(
            sql: #"DELETE FROM messageBody WHERE id LIKE ? ESCAPE '\'"#,
            arguments: [MessageIdentity.escapeForLike(accountId) + ":%"]
        )
        try db.execute(
            sql: "DELETE FROM messageAICache WHERE key LIKE ?",
            arguments: [accountId + ":%"]
        )
        try db.execute(
            sql: "UPDATE account SET lastFullSyncAt = NULL WHERE id = ?",
            arguments: [accountId]
        )
        try db.execute(
            sql: "UPDATE folder SET backfillComplete = 0, oldestSyncedDate = NULL, lastKnownUidNext = NULL, backfillUidCursor = NULL, backfillPageToken = NULL, backfillPageHeldSince = NULL WHERE accountId = ?",
            arguments: [accountId]
        )
    }

    // MARK: - Helpers

    private var sortedFolders: [Folder] {
        let roleOrder: [FolderRole] = [.inbox, .sent, .drafts, .archive, .trash, .spam, .custom]
        return folders.sorted { a, b in
            let ai = roleOrder.firstIndex(of: a.role) ?? roleOrder.count
            let bi = roleOrder.firstIndex(of: b.role) ?? roleOrder.count
            if ai != bi { return ai < bi }
            return a.name < b.name
        }
    }

    private func foldersWithRole(_ role: FolderRole) -> [Folder] {
        folders.filter { $0.role == role }
    }

    private func folderName(for role: FolderRole) -> String {
        let matches = foldersWithRole(role)
        if matches.isEmpty { return "Not Set" }
        return matches.map(\.name).joined(separator: ", ")
    }

    private func assignRole(_ role: FolderRole, to folder: Folder) {
        // ⚠️ SYNCHRONOUS BY DESIGN — DO NOT CONVERT TO async. Deliberate design decision from the
        // IOS-PERF-010 audit (Members 1–3, covering setFolderRole / assignRole / clearRole), NOT an
        // oversight and NOT a perf smell a linter should "fix". Gesture order IS durable order ONLY
        // while these writes do not suspend: two unstructured `Task { await write }` dispatched from the
        // @MainActor have no mutual ordering (DatabaseWriteQueue is FIFO by acquire-arrival, set by the
        // cooperative pool, NOT by tap order), so a rapid re-assign — assign Trash to F1, immediately
        // reassign it to F2 — can land the tasks out of order and persist the user's EARLIER intention,
        // silently. That is a NEVER-DROP-USER-INTENTION violation. The synchronous write also keeps
        // write-then-read coherence with the synchronous reloadFolders() (the IOS-SETTINGS-002 "failure
        // visibly reverts" property). Converting safely needs a per-account serial tail (modeled on
        // AccountFieldPersistenceStore), NOT a bare async write. See IOS-PERF-010.
        let inboxChanged = try? dbPool.write { db in
            try FolderRoleEdit.assign(role, to: folder.id, accountId: account.id, db: db)
        }
        reloadFolders()
        syncIfInboxChanged(inboxChanged)
    }

    private func clearRole(_ role: FolderRole) {
        let inboxChanged = try? dbPool.write { db in
            try FolderRoleEdit.clear(role, accountId: account.id, db: db)
        }
        reloadFolders()
        syncIfInboxChanged(inboxChanged)
    }

    private func formatETA(_ seconds: Double) -> String {
        if seconds < 60 { return "<1 min" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        let hours = Int(seconds / 3600)
        let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return mins > 0 ? "\(hours) hr \(mins) min" : "\(hours) hr"
    }

    private func roleLabel(_ role: FolderRole) -> String {
        switch role {
        case .inbox: return "Inbox"
        case .sent: return "Sent"
        case .drafts: return "Drafts"
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .spam: return "Spam"
        case .custom: return "Custom"
        }
    }

    private func roleIcon(_ role: FolderRole) -> String {
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

/// The re-authentication alert's copy: fixed plain lines only, never text
/// derived from the error (which stays in the debug-gated log). The line is
/// chosen by what failed.
enum AccountReauthAlert {
    /// The server refused the new password.
    static let passwordLine = "The server did not accept the sign-in. Check the password and try again."
    /// The password was accepted, then a later step (saving it, the sync) failed.
    static let setupLine = "Couldn't finish setting up the account. Try again."
    /// An OAuth re-authentication failed.
    static let oauthLine = "Sign-in did not complete. Please try again."
    /// The account was removed or changed while the password prompt was open.
    static let accountChangedLine = "This account was removed or changed while the password prompt was open. Nothing was saved."

    /// The server cannot meet TabMail's TLS minimum: the existing fixed copy for
    /// that case, built from the account's own host, not from the error.
    static func tlsLine(host: String) -> String {
        IMAPTransportSecurityError.tlsFloorNotMet(host: host).description
    }

    /// The alert line for a failed password update, or `nil` when the alert stays
    /// closed (offline, as before).
    static func passwordUpdateLine(for error: Error, host: String) -> String? {
        if case ReauthenticationError.accountChanged = error { return accountChangedLine }
        if error is IMAPTransportSecurityError { return tlsLine(host: host) }
        if SyncEngine.isConnectionError(error) { return nil }
        // `updatePassword` reports a refused password as this typed case: the
        // mail probe's own sign-in reporter, or a refused calendar sign-in.
        if case ProviderError.authenticationFailed = error { return passwordLine }
        return setupLine
    }

    /// The alert line for a failed OAuth re-authentication, or `nil` (offline).
    static func oauthLine(for error: Error) -> String? {
        SyncEngine.isConnectionError(error) ? nil : oauthLine
    }
}

/// The password prompt's copy.
enum PasswordPrompt {
    /// Names the password the account signs in with (an app-specific password
    /// for iCloud) and who it is for.
    static func message(for account: Account) -> String {
        "Enter the new \(account.provider.passwordName) for \(account.imapUsername ?? account.emailAddress)."
    }
}
