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

    private var hasBackfillCap: Bool {
        state.backfillCapReachedAccounts.contains(account.id)
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

            // Backfill cap warning
            if hasBackfillCap {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        Text("This account has an unusually large number of messages. Some older messages may not be synced.")
                            .font(.subheadline)
                    }
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
            Button("Cancel", role: .cancel) { newPassword = "" }
            Button("Update") { updatePassword() }
        } message: {
            Text("Enter the new password for \(account.imapUsername ?? account.emailAddress).")
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
        try? dbPool.write { db in
            try db.execute(
                sql: "UPDATE folder SET role = ? WHERE id = ?",
                arguments: [role.rawValue, folder.id]
            )
        }
        reloadFolders()
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
            Button {
                if account.provider == .imap {
                    showPasswordPrompt = true
                } else {
                    reauthenticateOAuth()
                }
            } label: {
                Label(
                    account.provider == .imap ? "Update Password" : "Re-authenticate",
                    systemImage: account.provider == .imap ? "key" : "arrow.clockwise"
                )
            }
        }
    }

    private func updatePassword() {
        guard !newPassword.isEmpty else { return }
        let password = newPassword
        newPassword = ""
        isReauthenticating = true
        Task {
            do {
                try await manager.updateIMAPPassword(password, for: account)
                try await manager.syncAccount(account)
            } catch {
                if !SyncEngine.isConnectionError(error) {
                    reauthError = error.localizedDescription
                }
            }
            isReauthenticating = false
        }
    }

    private func reauthenticateOAuth() {
        isReauthenticating = true
        Task {
            do {
                switch account.provider {
                case .gmail:
                    try await manager.reauthenticateGmail(for: account)
                case .outlook:
                    try await manager.reauthenticateMicrosoft(for: account)
                case .imap, .icloud, .caldav:
                    break
                }
                try await manager.syncAccount(account)
            } catch {
                if !SyncEngine.isConnectionError(error) {
                    reauthError = error.localizedDescription
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
                print("[Reset] Account-scoped database reset failed: \(error)")
                resetError = "TabMail couldn’t delete the local message data. Nothing was removed. Please try again."
                isResetting = false
                return
            }

            var derivedCleanupFailed = false
            do {
                try await SearchIndex.shared.removeMessagesForAccount(accountId: acctId)
            } catch {
                derivedCleanupFailed = true
                print("[Reset] Account-scoped search cleanup failed: \(error)")
            }

            print("[Reset] Cleared all message data for \(account.emailAddress)")
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
            sql: "UPDATE folder SET backfillComplete = 0, oldestSyncedDate = NULL, lastKnownUidNext = NULL, backfillUidCursor = NULL, backfillPageToken = NULL WHERE accountId = ?",
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
        // Synchronous ON PURPOSE (IOS-PERF-010 Members 1-3, covering setFolderRole/assignRole/clearRole):
        // gesture order IS durable order only while these do not suspend. Two unstructured
        // `Task { await write }` from the @MainActor have no mutual ordering (DatabaseWriteQueue is FIFO
        // by acquire arrival, not by tap order), so a rapid re-assign could persist the EARLIER intention
        // — a never-drop violation. Converting needs a per-account serial tail (see IOS-PERF-010), not a
        // bare async write.
        // Clear the role from any other folder first, then assign
        try? dbPool.write { db in
            try db.execute(
                sql: "UPDATE folder SET role = ? WHERE accountId = ? AND role = ?",
                arguments: [FolderRole.custom.rawValue, account.id, role.rawValue]
            )
            try db.execute(
                sql: "UPDATE folder SET role = ? WHERE id = ?",
                arguments: [role.rawValue, folder.id]
            )
        }
        reloadFolders()
    }

    private func clearRole(_ role: FolderRole) {
        try? dbPool.write { db in
            try db.execute(
                sql: "UPDATE folder SET role = ? WHERE accountId = ? AND role = ?",
                arguments: [FolderRole.custom.rawValue, account.id, role.rawValue]
            )
        }
        reloadFolders()
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
