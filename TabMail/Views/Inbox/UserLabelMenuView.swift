/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

/// The label menu's mutable state and every write that touches it.
///
/// Extracted out of `UserLabelMenuView` for ONE reason: the invariant below is a
/// property of `appliedIds` after a sequence of taps, and a `View`'s `@State`
/// cannot be observed from a test. The view is now a pure rendering of this
/// object; no behaviour moved or changed in the extraction.
///
/// 🚨 **THE INVARIANT — on a refused or failed write, RECONCILE `appliedIds` FROM
/// THE DATABASE. Never restore a captured snapshot, and never undo a delta.**
///
/// Both of those compose WRONGLY under concurrent taps, and this menu is a
/// persistent `List` of `Button`s (not a dismissing `Menu`), so a second tap
/// inside the first write's window is an ordinary thing for a user to do:
///
/// * *Snapshot restore* (what this used to do): start with L applied. Tap 1
///   captures `wasApplied = true` and displays L absent. Tap 2 captures
///   `wasApplied = false` and displays L applied. Both writes are refused.
///   Rollback 1 re-inserts L, rollback 2 removes it. The DB still holds L and the
///   checkmark is gone — a phantom success, the exact defect the rollback was
///   added to eliminate.
/// * *Delta replay* ("each task undoes its own flip") is no better: tap 2 took its
///   baseline from tap 1's UNPERSISTED optimistic state, so undoing tap 2's delta
///   returns the display to a state that was never durable.
///
/// Re-reading the join rows is authoritative and race-free under every
/// interleaving, because it does not depend on what any tap observed: whichever
/// task completes last leaves the checkmarks equal to the durable truth.
///
/// The reconcile therefore runs on EVERY completion, admitted or refused — a
/// deliberate strengthening of "reconcile on refusal". Reconciling only on
/// refusal does not converge: if the last task to finish was ADMITTED, nothing
/// re-reads, and an earlier task's reconcile that raced ahead of this task's
/// commit leaves a stale checkmark standing until the sheet is reopened. Running
/// it unconditionally makes the LAST completion authoritative whatever mix of
/// outcomes preceded it, and costs one small indexed read on a path that already
/// awaits `drainPendingQueue`.
@Observable
@MainActor
final class UserLabelMenuModel {
    let messageSnapshot: MessageSnapshot
    /// Sorted once on load — remains stable during the session (no re-sorting on
    /// toggle, and the reconcile below deliberately does not disturb it).
    var sortedLabels: [UserLabel] = []
    /// Applied label IDs — mutated optimistically on toggle, drives checkmark display.
    var appliedIds: Set<String> = []

    init(messageSnapshot: MessageSnapshot) {
        self.messageSnapshot = messageSnapshot
    }

    // MARK: - Data Loading

    func loadLabels() {
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

    /// Re-derive the displayed checkmarks from the durable join rows. See this
    /// type's doc comment for why this — and not a snapshot or a delta — is the
    /// only correct reaction to a refused or failed write.
    ///
    /// `UserLabelStore.labelsForMessage` applies the same two filters `loadLabels`'
    /// applied set is subject to — `isSystem == false` and `shouldExcludeLabel` —
    /// differing only in that it does not re-apply `labelsSortedForMenu`'s
    /// `accountId` predicate. An id that survives that difference names a label
    /// `sortedLabels` does not contain, and the `ForEach` renders only
    /// `sortedLabels`, so it draws nothing. `sortedLabels` is deliberately
    /// untouched: row ORDER is a presentation choice fixed at load, and re-sorting
    /// under the user's finger is a different bug.
    ///
    /// A failed READ leaves `appliedIds` alone rather than guessing. That is the
    /// only honest answer — this function's whole contract is "show what the
    /// database says", and it has not been told.
    ///
    /// The `dbPool.read` is SYNCHRONOUS on the MainActor on purpose — see the same
    /// note on `InboxViewModel.reconcileUserLabels`. An await between the read and
    /// the assignment would let two overlapping reconciles read in one order and
    /// write in the other, destroying the "last completion is authoritative"
    /// property this whole design rests on. The query is one leading-column-indexed
    /// lookup on `messageUserLabel`'s composite primary key.
    func reconcileAppliedIdsFromDatabase() {
        do {
            let applied = try AppDatabase.dbPool.read { db in
                try UserLabelStore.labelsForMessage(messageSnapshot.id, in: db)
            }
            appliedIds = Set(applied.map(\.id))
        } catch {
            print("[UserLabelMenu] Failed to reconcile applied labels: \(error)")
        }
    }

    // MARK: - Actions

    /// Flip the checkmark synchronously (the tap must feel instant) and complete
    /// the write in a spawned task. The task is returned so tests can await the
    /// exact interleaving they mean to exercise; UI callers discard it.
    @discardableResult
    func toggleLabel(_ label: UserLabel) -> Task<Void, Never> {
        let wasApplied = appliedIds.contains(label.id)
        // Optimistic UI: flip checkmark immediately, no re-sort
        if wasApplied {
            appliedIds.remove(label.id)
        } else {
            appliedIds.insert(label.id)
        }
        return Task { @MainActor in
            // T1.3 — the write can REFUSE admission (unknown folder epoch), in which
            // case no op row was queued and no local row changed. Without a reconcile
            // the checkmark above stays flipped and the user is shown a label state
            // that was never persisted and never will be: a phantom success. Reading
            // the join rows back — rather than reverting — is the only reaction that
            // composes correctly under concurrent taps, and it runs on the admitted
            // path too so that the last completion is authoritative. See this type.
            _ = wasApplied ? await removeLabel(label) : await applyLabel(label)
            reconcileAppliedIdsFromDatabase()
        }
    }

    /// The message's REAL folder path, or nil when its header row is gone.
    ///
    /// This used to fall back to `?? "INBOX"`. It must not: that guess is what made
    /// the admission guard's missing-`Folder`-row case unsafe to fail closed, and a
    /// guessed path is wrong in exactly the situation it fires — the header has
    /// vanished, so there is no message here to label. Callers abort on nil.
    private func resolvedFolderPath() -> String? {
        (try? AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: messageSnapshot.id)?.folderPath
        }) ?? nil
    }

    /// Returns whether the write was ADMITTED. `false` means nothing was queued and
    /// nothing changed locally, so the caller must reconcile its optimistic UI.
    func applyLabel(_ label: UserLabel) async -> Bool {
        guard let folderPath = resolvedFolderPath() else { return false }
        do {
            let admitted = try await AppDatabase.dbPool.write { db -> Bool in
                // T1.3 — see InboxViewModel.removeUserLabel. Refuse before the local
                // insert so neither half lands.
                guard try !AccountManager.newGestureRefusedForUnknownEpoch(
                    accountId: messageSnapshot.accountId, folderPath: folderPath, db: db) else { return false }
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
                return true
            }
            guard admitted else { return false }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            await AccountManager.shared.drainPendingQueue()
            return true
        } catch {
            print("[UserLabelMenu] Apply label failed: \(error)")
            return false
        }
    }

    /// Returns whether the write was ADMITTED — see `applyLabel`.
    func removeLabel(_ label: UserLabel) async -> Bool {
        guard let folderPath = resolvedFolderPath() else { return false }
        do {
            let admitted = try await AppDatabase.dbPool.write { db -> Bool in
                // T1.3 — see InboxViewModel.removeUserLabel. Refuse before the local
                // delete so neither half lands.
                guard try !AccountManager.newGestureRefusedForUnknownEpoch(
                    accountId: messageSnapshot.accountId, folderPath: folderPath, db: db) else { return false }
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
                return true
            }
            guard admitted else { return false }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            await AccountManager.shared.drainPendingQueue()
            return true
        } catch {
            print("[UserLabelMenu] Remove label failed: \(error)")
            return false
        }
    }

    /// Create `name` for this account and apply it to the message. Returns whether
    /// the label row was created (the caller clears its search field on true) —
    /// application is reported through `appliedIds`, which is set only when the
    /// write was admitted, for the same phantom-success reason as `toggleLabel`.
    func createAndApply(name: String) async -> Bool {
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
                guard let gmail = provider as? GmailProvider else { return false }
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
            let admitted = await applyLabel(newLabel)
            // Add to list — the label row itself was created above regardless, so it
            // belongs in the menu either way. Mark it APPLIED only if the write was
            // admitted: a refusal queued nothing and inserted no join row, and a
            // checkmark here would be the same phantom success `toggleLabel` closes.
            sortedLabels.insert(newLabel, at: 0)
            if admitted { appliedIds.insert(labelId) }
            return true
        } catch {
            print("[UserLabelMenu] Create label failed: \(error)")
            return false
        }
    }
}

/// Half-sheet for managing user labels on a message.
/// Shown on long-press of a message row (InboxView) or card header (MessageDetailView).
struct UserLabelMenuView: View {
    @State private var model: UserLabelMenuModel
    @State private var searchText = ""
    @State private var isCreating = false
    @Environment(\.dismiss) private var dismiss

    init(messageSnapshot: MessageSnapshot) {
        _model = State(initialValue: UserLabelMenuModel(messageSnapshot: messageSnapshot))
    }

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
                        model.toggleLabel(label)
                    } label: {
                        HStack {
                            Image(systemName: model.appliedIds.contains(label.id) ? "checkmark.circle.fill" : "circle")
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
        .onAppear { model.loadLabels() }
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
        guard !searchText.isEmpty else { return model.sortedLabels }
        return model.sortedLabels.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var matchesExisting: Bool {
        model.sortedLabels.contains { $0.name.caseInsensitiveCompare(searchText) == .orderedSame }
    }

    // MARK: - Actions

    private func createAndApply() async {
        let name = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !UserLabelStore.isReservedName(name) else { return }

        isCreating = true
        defer { isCreating = false }

        if await model.createAndApply(name: name) {
            searchText = ""
        }
    }
}
