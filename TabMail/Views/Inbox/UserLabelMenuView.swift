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
    /// Whether this message's account can carry user labels REMOTELY. Set by
    /// `loadLabels`, drives the sheet's disabled state. Presentation only — every
    /// durable write re-asks the question inside its OWN transaction rather than
    /// trusting this flag, because `applyLabel`/`removeLabel` are also entered
    /// directly (tests, and any future non-menu caller).
    var supportsRemoteUserLabels = false

    init(messageSnapshot: MessageSnapshot) {
        self.messageSnapshot = messageSnapshot
    }

    // MARK: - Provider Capability

    /// Whether this provider's mail adapter implements REMOTE user-label
    /// mutations. CalDAV does not, so a label op admitted for it can never
    /// execute — it would sit in the queue being retried forever while the menu
    /// showed a checkmark for a label the server will never carry. Refusing at
    /// admission is the honest answer; nothing is queued and nothing is shown.
    ///
    /// ⚑ `.outlook` USED TO BE IN THAT REFUSING ARM AND NO LONGER IS. Outlook's
    /// user label is a Graph message `category` (`ExchangeProvider.setUserLabel`
    /// / `parseGraphMessage`), so its adapter now mutates labels remotely exactly
    /// as Gmail's and IMAP's do, and gating it hid an Outlook account's own
    /// existing label rows behind an empty, disabled sheet. `.caldav` stays
    /// `false` for a categorically different reason: it carries no mail at all,
    /// so the question is inapplicable rather than merely unimplemented.
    ///
    /// ⚑ PORT of `v2final`'s `AccountProvider.supportsRemoteUserLabels`
    /// (declared on the enum in `TabMail/Models/Account.swift`), with TWO
    /// deliberate differences:
    ///
    /// 1. v3 carries no such member on `AccountProvider`, and this change's file
    ///    scope does not include `Account.swift`. The ladder belongs on the enum
    ///    beside `contentKeySpace` — lift it there when that file is in scope,
    ///    replace the four call sites, and delete this.
    /// 2. 🚨 **THE VALUES DIVERGE.** `v2final` returns `false` for `.outlook`
    ///    (its `AccountProviderTests` assert it), because `v2final` never
    ///    implemented a Graph category write either. v3 does
    ///    (`IOS-LABEL-002`), so `.outlook` is `true` here. **A lift must NOT
    ///    copy `v2final`'s arm** — doing so would silently re-hide every Outlook
    ///    account's labels.
    ///
    /// ⚑ Exhaustive with no `default:` clause on purpose, exactly like
    /// `AccountProvider.contentKeySpace`: a sixth provider must be a compile error
    /// here, not a silent "labels work on it".
    ///
    /// `nonisolated` because three of its four call sites run inside a GRDB
    /// database-queue closure, off the MainActor this type is isolated to — the
    /// same treatment `AccountManager.newGestureRefusedForUnknownEpoch` gets.
    nonisolated static func supportsRemoteUserLabels(_ provider: AccountProvider) -> Bool {
        switch provider {
        case .gmail, .imap, .icloud, .outlook: return true
        case .caldav: return false
        }
    }

    // MARK: - Data Loading

    func loadLabels() {
        do {
            let accountId = messageSnapshot.accountId
            let messageId = messageSnapshot.id
            // ONE read, not two. The gate and the rows it gates must observe one
            // consistent database state, and the two separate `dbPool.read` calls
            // this replaced could not even guarantee that for the inbox-folder
            // frequency input.
            let state = try AppDatabase.dbPool.read { db -> (
                supportsRemoteUserLabels: Bool,
                entries: [(label: UserLabel, isApplied: Bool)]
            ) in
                // Provider gate — an account whose adapter cannot mutate labels
                // remotely gets an EMPTY, disabled menu rather than a list of taps
                // that could only ever queue an op nothing will execute.
                guard let account = try Account.fetchOne(db, key: accountId),
                      Self.supportsRemoteUserLabels(account.provider)
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

    /// 🚨 **THE OP'S TARGET IS THE ROW, READ INSIDE THIS TRANSACTION — there is no
    /// default folder and there must never be one.**
    ///
    /// This replaced a `resolvedFolderPath()` helper that read the header in its
    /// own EARLIER `dbPool.read`, and whose first form defaulted to `?? "INBOX"`
    /// when the row was missing. Both halves of that were wrong, and the second
    /// outlives the first:
    ///
    /// * *The default.* A guessed `"INBOX"` queued a label op against a folder the
    ///   user was not acting on. On IMAP the op resolves a UID inside that folder,
    ///   so it mutates whichever message that mailbox's numbering put there —
    ///   `C3`, the wrong-message mutation this codebase refuses outright. An
    ///   unknown folder is an ABSENCE of evidence; it may fail closed, but it may
    ///   never become a silent default.
    /// * *The separate transaction.* Even returning the honest path, reading it in
    ///   a prior transaction meant the value could be stale by the time the op was
    ///   written: `MessageIdentity.headerId` embeds `folderPath`, so a MOVE
    ///   landing in between retires this row and re-inserts the message under a
    ///   DIFFERENT id — and the op would have named the folder the message has
    ///   since LEFT. Same C3 outcome by a slower route. Reading the row here makes
    ///   the guard, the local join row and the queued op observe one state.
    ///
    /// A vanished row therefore fails CLOSED — nothing queued, nothing written
    /// locally — and the refusal is **RETRYABLE**: it latches nothing, so the
    /// user's next tap re-runs this whole transaction. `AccountManager
    /// .newGestureRefusedForUnknownEpoch` cites this caller as the reason its
    /// missing-`Folder`-row case is safe to fail closed.
    ///
    /// Returns whether the write was ADMITTED. `false` means nothing was queued and
    /// nothing changed locally, so the caller must reconcile its optimistic UI.
    func applyLabel(_ label: UserLabel) async -> Bool {
        do {
            let admitted = try await AppDatabase.dbPool.write { db -> Bool in
                guard let header = try MessageHeader.fetchOne(db, key: messageSnapshot.id) else { return false }
                // Provider gate — the last of the three, and the only one a direct
                // (non-menu) caller passes through. See `supportsRemoteUserLabels(_:)`.
                guard let account = try Account.fetchOne(db, key: header.accountId),
                      Self.supportsRemoteUserLabels(account.provider)
                else { return false }
                // T1.3 — see InboxViewModel.removeUserLabel. Refuse before the local
                // insert so neither half lands.
                guard try !AccountManager.newGestureRefusedForUnknownEpoch(
                    accountId: header.accountId, folderPath: header.folderPath, db: db) else { return false }
                // 🚨 ADMIT THROUGH THE PROVIDER-ADDRESS PREDICATE (audit A-6).
                // This used to enqueue `header.stableId` — an rfc822 Message-ID on
                // IMAP — with no epoch. The drain's checkpoint A can only refuse
                // that shape, so every IMAP label gesture was accepted here,
                // checkmarked in the UI, and then never executed: a deterministic
                // loss of an action `v1.6.38` performed. ⚠ CORRECTED (audit round
                // 2): this said "DELETED unexecuted", which described checkpoint A
                // as it stood WHEN THE DEFECT SHIPPED. Checkpoint A now SKIPS an
                // unprovable op instead of deleting it — an absence of evidence is
                // not an exit — so the accurate description of this shape today is
                // a PERMANENTLY UNCLAIMABLE ROW: the gesture never reaches the
                // server and the row never leaves the queue. The user-visible loss
                // is identical; only the wreckage differs. Admitting
                // through the same helper the other ordinary actions use records
                // the provider's native address and the epoch that proved it.
                guard let admission = try AccountManager.admittedOrdinaryActionTargets(
                    [header], accountId: header.accountId,
                    folderPath: header.folderPath, db: db) else { return false }
                try MessageUserLabel(messageId: header.id, userLabelId: label.id)
                    .insert(db, onConflict: .ignore)
                // 🚨 `providerLabelId`, NEVER `id` — THIS VALUE GOES ON THE WIRE.
                // The drain hands `PendingOperation.userLabelId` straight to the
                // provider as a raw argument: Gmail `addLabelIds:`, IMAP
                // `STORE +FLAGS (<keyword>)`. `UserLabel.id` is the
                // account-prefixed surrogate (D10 / `IOS-LABEL-001`) and would be
                // a value the server has never heard of. On IMAP that writes a
                // bogus custom keyword to the real message — a wrong-value server
                // mutation. On Gmail it is worse than a loud failure: the API
                // replies `"Invalid label"`, which
                // `GmailProvider.isAuthoritativeActionRejection` matches as a
                // PROVIDER-AUTHORITATIVE no-op, so the op leaves the queue as if
                // it had succeeded and the user's label action is silently
                // discarded — the cardinal sin of this codebase.
                let op = PendingOperation(
                    type: .addUserLabel,
                    messageIds: admission.providerIds,
                    accountId: header.accountId,
                    folderPath: header.folderPath,
                    userLabelId: label.providerLabelId,
                    observedUidValidity: admission.observedUidValidity
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

    /// Returns whether the write was ADMITTED — see `applyLabel`, whose doc comment
    /// also states why this transaction resolves the target row itself instead of
    /// being handed a folder path read earlier.
    func removeLabel(_ label: UserLabel) async -> Bool {
        do {
            let admitted = try await AppDatabase.dbPool.write { db -> Bool in
                guard let header = try MessageHeader.fetchOne(db, key: messageSnapshot.id) else { return false }
                // Provider gate — see `applyLabel`'s identical guard.
                guard let account = try Account.fetchOne(db, key: header.accountId),
                      Self.supportsRemoteUserLabels(account.provider)
                else { return false }
                // T1.3 — see InboxViewModel.removeUserLabel. Refuse before the local
                // delete so neither half lands.
                guard try !AccountManager.newGestureRefusedForUnknownEpoch(
                    accountId: header.accountId, folderPath: header.folderPath, db: db) else { return false }
                // 🚨 ADMIT THROUGH THE PROVIDER-ADDRESS PREDICATE (audit A-6) —
                // see the identical comment in `applyLabel`, including its round-2
                // correction. An rfc822 id with no epoch is a shape checkpoint A
                // can only refuse, so this gesture was accepted, un-checkmarked in
                // the UI, and then never executed.
                guard let admission = try AccountManager.admittedOrdinaryActionTargets(
                    [header], accountId: header.accountId,
                    folderPath: header.folderPath, db: db) else { return false }
                try MessageUserLabel
                    .filter(Column("messageId") == header.id && Column("userLabelId") == label.id)
                    .deleteAll(db)
                // 🚨 `providerLabelId`, NEVER `id` — see the identical comment in
                // `applyLabel`, including the Gmail authoritative-rejection trap
                // that turns a prefixed wire value into a SILENT drop of the
                // user's intention rather than a visible failure.
                let op = PendingOperation(
                    type: .removeUserLabel,
                    messageIds: admission.providerIds,
                    accountId: header.accountId,
                    folderPath: header.folderPath,
                    userLabelId: label.providerLabelId,
                    observedUidValidity: admission.observedUidValidity
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

            // Provider gate — an account whose adapter cannot mutate labels
            // remotely must not even get the local `UserLabel` row created below:
            // nothing would ever carry it to the server, so it would be a label
            // that exists on this device only, silently. Returning false keeps the
            // user's typed text in the field rather than clearing it on a
            // create that did not happen.
            guard let account = try await AppDatabase.dbPool.read({ db in
                try Account.fetchOne(db, key: accountId)
            }), Self.supportsRemoteUserLabels(account.provider) else { return false }

            switch account.provider {
            case .gmail:
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
            case .imap, .icloud:
                // IMAP: keyword name (lowercased) IS the ID — no server call needed
                labelId = name.lowercased()
            case .outlook:
                // Outlook: the Graph category's DISPLAY NAME is the ID. Mints
                // locally like the IMAP arm above rather than blocking on a
                // catalog round-trip like the Gmail arm, because Graph has no
                // catalog to call: PATCHing a category name onto a message is
                // what makes it exist there (`ExchangeProvider.setUserLabel`).
                //
                // 🚨 VERBATIM — deliberately NOT `.lowercased()`, the one place
                // this arm diverges from the IMAP arm it otherwise copies. IMAP
                // lowercases because RFC 3501 keywords are case-INsensitive;
                // Graph category names are case-SENSITIVE display strings that
                // must round-trip byte-identically. The read path
                // (`ExchangeProvider.parseGraphMessage`) maps the server's
                // `categories` strings verbatim into `userLabelIds`, and the sync
                // arms mint a `UserLabel` from each, so lowercasing here would
                // make the user's `Receipts` and the server's echoed `Receipts`
                // derive two different `UserLabel.id`s — one category, two menu
                // rows.
                //
                // `tm_*` never reaches here: `UserLabelStore.isReservedName`
                // refuses that prefix at this function's only caller, which is
                // deliberate — the server would accept such a category and
                // `ExchangeProvider.stripLegacyCategories` would later silently
                // delete it.
                labelId = name
            case .caldav:
                // Unreachable — the gate above already returned for CalDAV.
                // Spelled as an explicit case rather than `default:` for the same
                // reason `supportsRemoteUserLabels(_:)` is exhaustive: a sixth
                // provider must be a compile error here, not a silent keyword-id
                // guess.
                return false
            }

            // `labelId` is the BARE provider value — a Gmail label id from
            // `createLabel`, or the lowercased IMAP keyword. The deterministic
            // initializer mints the account-prefixed surrogate primary key from it
            // (D10 / `IOS-LABEL-001`).
            let newLabel = UserLabel(
                accountId: accountId, providerLabelId: labelId,
                name: name, isSystem: false
            )

            // Insert locally
            try await AppDatabase.dbPool.write { db in
                try newLabel.save(db)
            }

            // Apply to message
            let admitted = await applyLabel(newLabel)
            // Add to list — the label row itself was created above regardless, so it
            // belongs in the menu either way. Mark it APPLIED only if the write was
            // admitted: a refusal queued nothing and inserted no join row, and a
            // checkmark here would be the same phantom success `toggleLabel` closes.
            //
            // 🚨 `newLabel.id`, not `labelId`. `appliedIds` is compared against
            // `label.id` by `toggleLabel` and rebuilt from `label.id` by
            // `reconcileAppliedIdsFromDatabase`; inserting the BARE provider value
            // here would put a member in the set that nothing else can ever match,
            // so the freshly created label's checkmark would not draw.
            sortedLabels.insert(newLabel, at: 0)
            if admitted { appliedIds.insert(newLabel.id) }
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
                if model.supportsRemoteUserLabels && !searchText.isEmpty && !matchesExisting {
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
            // Provider gate — on an account whose adapter cannot mutate labels
            // remotely the list is empty anyway (`loadLabels` returns no entries),
            // and this makes the sheet visibly inert rather than merely blank.
            .disabled(!model.supportsRemoteUserLabels)
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
