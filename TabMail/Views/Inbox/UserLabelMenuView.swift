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
    @State private var supportsRemoteUserLabels = false
    @State private var isCreating = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Search / create field
                if supportsRemoteUserLabels && !searchText.isEmpty && !matchesExisting {
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
            .disabled(!supportsRemoteUserLabels)
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
            let state = try AppDatabase.dbPool.read { db -> (
                supportsRemoteUserLabels: Bool,
                entries: [(label: UserLabel, isApplied: Bool)]
            ) in
                guard let account = try Account.fetchOne(db, key: accountId),
                      account.provider.supportsRemoteUserLabels
                else { return (false, []) }
                let inboxFolderIds = try String.fetchAll(db,
                    Folder.select(Column("id"))
                        .filter(Column("accountId") == accountId && Column("role") == FolderRole.inbox.rawValue)
                )
                let entries = try UserLabelStore.labelsSortedForMenu(
                    accountId: accountId,
                    messageId: messageId,
                    inboxFolderIds: inboxFolderIds,
                    in: db
                )
                return (true, entries)
            }
            supportsRemoteUserLabels = state.supportsRemoteUserLabels
            // Sort order set once — stable during session
            sortedLabels = state.entries.map(\.label)
            appliedIds = Set(state.entries.filter(\.isApplied).map(\.label.id))
        } catch {
            print("[UserLabelMenu] Failed to load labels: \(error)")
        }
    }

    // MARK: - Actions

    private func toggleLabel(_ label: UserLabel) {
        guard supportsRemoteUserLabels,
              !label.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              MessageIdentity.durableActionAddress(
            accountId: messageSnapshot.accountId,
            folderPath: messageSnapshot.folderPath,
            rfc822MessageId: messageSnapshot.rfc822MessageId
        ) != nil
        else { return }
        let wasApplied = appliedIds.contains(label.id)
        // Optimistic UI: flip checkmark immediately, no re-sort
        if wasApplied {
            appliedIds.remove(label.id)
        } else {
            appliedIds.insert(label.id)
        }
        // DB write + queue drain in background
        Task {
            let persisted: Bool
            if wasApplied {
                persisted = await removeLabel(label)
            } else {
                persisted = await applyLabel(label)
            }
            guard !persisted else { return }
            if wasApplied {
                appliedIds.insert(label.id)
            } else {
                appliedIds.remove(label.id)
            }
        }
    }

    /// Internal so tests can exercise the real transaction/admission path.
    /// UI callers still enter through `toggleLabel`.
    func applyLabel(_ label: UserLabel) async -> Bool {
        do {
            let persisted = try await AccountManager.shared.retryGatedQueueWrite(
                AppDatabase.dbPool, label: "applyLabel", maxAttempts: 1
            ) { db -> Bool in
                guard let header = try MessageHeader.fetchOne(db, key: messageSnapshot.id),
                      let account = try Account.fetchOne(db, key: header.accountId),
                      account.provider.supportsRemoteUserLabels,
                      let address = MessageIdentity.durableActionAddress(
                          accountId: header.accountId,
                          folderPath: header.folderPath,
                          rfc822MessageId: header.rfc822MessageId
                      ),
                      label.accountId == address.accountId,
                      let op = PendingOperation.durableMessageAction(
                          type: .addUserLabel,
                          messageIds: [address.rfc822MessageId],
                          accountId: address.accountId,
                          folderPath: address.folderPath,
                          userLabelId: label.id
                      )
                else { return false }
                try MessageUserLabel(
                    messageId: messageSnapshot.id,
                    accountId: address.accountId,
                    userLabelId: label.id
                )
                    .insert(db, onConflict: .ignore)
                try op.insert(db)
                return true
            }
            guard persisted else { return false }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            await AccountManager.shared.drainPendingQueue()
            return true
        } catch {
            print("[UserLabelMenu] Apply label failed: \(error)")
            return false
        }
    }

    /// Internal so tests can exercise the real transaction/admission path.
    /// UI callers still enter through `toggleLabel`.
    func removeLabel(_ label: UserLabel) async -> Bool {
        do {
            let persisted = try await AccountManager.shared.retryGatedQueueWrite(
                AppDatabase.dbPool, label: "removeLabel", maxAttempts: 1
            ) { db -> Bool in
                guard let header = try MessageHeader.fetchOne(db, key: messageSnapshot.id),
                      let account = try Account.fetchOne(db, key: header.accountId),
                      account.provider.supportsRemoteUserLabels,
                      let address = MessageIdentity.durableActionAddress(
                          accountId: header.accountId,
                          folderPath: header.folderPath,
                          rfc822MessageId: header.rfc822MessageId
                      ),
                      label.accountId == address.accountId,
                      let op = PendingOperation.durableMessageAction(
                          type: .removeUserLabel,
                          messageIds: [address.rfc822MessageId],
                          accountId: address.accountId,
                          folderPath: address.folderPath,
                          userLabelId: label.id
                      )
                else { return false }
                try MessageUserLabel
                    .filter(Column("messageId") == messageSnapshot.id && Column("userLabelId") == label.id)
                    .deleteAll(db)
                try op.insert(db)
                return true
            }
            guard persisted else { return false }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            await AccountManager.shared.drainPendingQueue()
            return true
        } catch {
            print("[UserLabelMenu] Remove label failed: \(error)")
            return false
        }
    }

    private func createAndApply() async {
        let name = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !UserLabelStore.isReservedName(name),
              MessageIdentity.durableActionAddress(
                  accountId: messageSnapshot.accountId,
                  folderPath: messageSnapshot.folderPath,
                  rfc822MessageId: messageSnapshot.rfc822MessageId
              ) != nil
        else { return }

        isCreating = true
        defer { isCreating = false }

        do {
            let accountId = messageSnapshot.accountId
            let labelId: String

            // Check provider type from account
            guard let account = try await AppDatabase.dbPool.read({ db in
                try Account.fetchOne(db, key: accountId)
            }), account.provider.supportsRemoteUserLabels else { return }

            switch account.provider {
            case .gmail:
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
            case .imap, .icloud:
                // IMAP: keyword name (lowercased) IS the ID — no server call needed
                labelId = name.lowercased()
            case .outlook, .caldav:
                return
            }

            // Insert locally
            try await AppDatabase.dbPool.write { db in
                try UserLabel(id: labelId, accountId: accountId, name: name, isSystem: false)
                    .save(db)
            }

            // Apply to message
            let newLabel = UserLabel(id: labelId, accountId: accountId, name: name, isSystem: false)
            guard await applyLabel(newLabel) else { return }
            // Add to list + mark applied (no full re-sort)
            sortedLabels.insert(newLabel, at: 0)
            appliedIds.insert(labelId)
            searchText = ""
        } catch {
            print("[UserLabelMenu] Create label failed: \(error)")
        }
    }
}
