/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

/// Half-sheet for managing user labels on a message.
/// Shown on long-press of a message row (InboxView) or card header (MessageDetailView).
struct UserLabelMenuView: View {
    let messageSnapshot: MessageSnapshot
    @State private var searchText = ""
    /// Sorted once on appear — remains stable during the session (no re-sorting on toggle).
    @State private var sortedLabels: [UserLabel] = []
    /// Applied label IDs — mutated optimistically on toggle, drives checkmark display.
    @State private var appliedIds: Set<String> = []
    @State private var isCreating = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Search / create field
                if !searchText.isEmpty && !matchesExisting {
                    createRow
                }

                // Label list (sort order is stable — set once on appear)
                ForEach(filteredLabels) { label in
                    Button {
                        toggleLabel(label)
                    } label: {
                        HStack {
                            Image(systemName: appliedIds.contains(label.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.secondary)
                            Text(label.name)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $searchText, prompt: "Search or create label...")
            .navigationTitle("Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { loadLabels() }
        .dismissKeyboardOnTap()
    }

    // MARK: - Create Row

    @ViewBuilder
    private var createRow: some View {
        if UserLabelStore.isReservedName(searchText) {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("'\(searchText)' is a reserved name")
                    .foregroundStyle(.secondary)
            }
        } else {
            Button {
                Task { await createAndApply() }
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.secondary)
                    Text("Create \"\(searchText)\"")
                        .foregroundStyle(.primary)
                    if isCreating {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isCreating)
        }
    }

    // MARK: - Filtering

    private var filteredLabels: [UserLabel] {
        guard !searchText.isEmpty else { return sortedLabels }
        return sortedLabels.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var matchesExisting: Bool {
        sortedLabels.contains { $0.name.caseInsensitiveCompare(searchText) == .orderedSame }
    }

    // MARK: - Data Loading

    private func loadLabels() {
        do {
            let accountId = messageSnapshot.accountId
            let messageId = messageSnapshot.id
            let inboxFolderIds = try AppDatabase.dbPool.read { db in
                try String.fetchAll(db,
                    Folder.select(Column("id"))
                        .filter(Column("accountId") == accountId && Column("role") == FolderRole.inbox.rawValue)
                )
            }
            let entries = try AppDatabase.dbPool.read { db in
                try UserLabelStore.labelsSortedForMenu(
                    accountId: accountId,
                    messageId: messageId,
                    inboxFolderIds: inboxFolderIds,
                    in: db
                )
            }
            // Sort order set once — stable during session
            sortedLabels = entries.map(\.label)
            appliedIds = Set(entries.filter(\.isApplied).map(\.label.id))
        } catch {
            print("[UserLabelMenu] Failed to load labels: \(error)")
        }
    }

    // MARK: - Actions

    private func toggleLabel(_ label: UserLabel) {
        let wasApplied = appliedIds.contains(label.id)
        // Optimistic UI: flip checkmark immediately, no re-sort
        if wasApplied {
            appliedIds.remove(label.id)
        } else {
            appliedIds.insert(label.id)
        }
        // DB write + queue drain in background
        Task {
            if wasApplied {
                await removeLabel(label)
            } else {
                await applyLabel(label)
            }
        }
    }

    /// Look up the real folder path from DB (MessageSnapshot doesn't carry folderPath).
    private func resolvedFolderPath() -> String {
        (try? AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: messageSnapshot.id)?.folderPath
        }) ?? "INBOX"
    }

    private func applyLabel(_ label: UserLabel) async {
        let folderPath = resolvedFolderPath()
        do {
            try await AppDatabase.dbPool.write { db in
                // T1.3 — see InboxViewModel.removeUserLabel. Refuse before the local
                // insert so neither half lands.
                guard try !AccountManager.newGestureRefusedForUnknownEpoch(
                    accountId: messageSnapshot.accountId, folderPath: folderPath, db: db) else { return }
                try MessageUserLabel(messageId: messageSnapshot.id, userLabelId: label.id)
                    .insert(db, onConflict: .ignore)
                let op = PendingOperation(
                    type: .addUserLabel,
                    messageIds: [messageSnapshot.stableId],
                    accountId: messageSnapshot.accountId,
                    folderPath: folderPath,
                    userLabelId: label.id
                )
                try op.insert(db)
            }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            await AccountManager.shared.drainPendingQueue()
        } catch {
            print("[UserLabelMenu] Apply label failed: \(error)")
        }
    }

    private func removeLabel(_ label: UserLabel) async {
        let folderPath = resolvedFolderPath()
        do {
            try await AppDatabase.dbPool.write { db in
                // T1.3 — see InboxViewModel.removeUserLabel. Refuse before the local
                // delete so neither half lands.
                guard try !AccountManager.newGestureRefusedForUnknownEpoch(
                    accountId: messageSnapshot.accountId, folderPath: folderPath, db: db) else { return }
                try MessageUserLabel
                    .filter(Column("messageId") == messageSnapshot.id && Column("userLabelId") == label.id)
                    .deleteAll(db)
                let op = PendingOperation(
                    type: .removeUserLabel,
                    messageIds: [messageSnapshot.stableId],
                    accountId: messageSnapshot.accountId,
                    folderPath: folderPath,
                    userLabelId: label.id
                )
                try op.insert(db)
            }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            await AccountManager.shared.drainPendingQueue()
        } catch {
            print("[UserLabelMenu] Remove label failed: \(error)")
        }
    }

    private func createAndApply() async {
        let name = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !UserLabelStore.isReservedName(name) else { return }

        isCreating = true
        defer { isCreating = false }

        do {
            let accountId = messageSnapshot.accountId
            let labelId: String

            // Check provider type from account
            let account = try await AppDatabase.dbPool.read { db in
                try Account.fetchOne(db, key: accountId)
            }

            if account?.provider == .gmail {
                // Gmail: create label on server synchronously (with timeout)
                let provider = await AccountManager.shared.providers[accountId]
                guard let gmail = provider as? GmailProvider else { return }
                labelId = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        do {
                            return try await gmail.createLabel(name: name, visible: true)
                        } catch let error as NSError where error.code == 409 {
                            guard let existingId = try await gmail.findLabelIdByName(name) else { throw error }
                            return existingId
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(10))
                        throw UserLabelCreationTimeoutError()
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
            } else {
                // IMAP: keyword name (lowercased) IS the ID — no server call needed
                labelId = name.lowercased()
            }

            // Insert locally
            try await AppDatabase.dbPool.write { db in
                try UserLabel(id: labelId, accountId: accountId, name: name, isSystem: false)
                    .save(db)
            }

            // Apply to message
            let newLabel = UserLabel(id: labelId, accountId: accountId, name: name, isSystem: false)
            await applyLabel(newLabel)
            // Add to list + mark applied (no full re-sort)
            sortedLabels.insert(newLabel, at: 0)
            appliedIds.insert(labelId)
            searchText = ""
        } catch {
            print("[UserLabelMenu] Create label failed: \(error)")
        }
    }
}
