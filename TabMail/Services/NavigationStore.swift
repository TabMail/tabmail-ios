/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

enum AccountEditableField: String, CaseIterable, Sendable {
    case displayName
    case emailAddress
    case signatureBelowQuote
    case imapUsername
    case signature

    var displayLabel: String {
        switch self {
        case .displayName: "Name"
        case .emailAddress: "Email"
        case .signatureBelowQuote: "Signature placement"
        case .imapUsername: "IMAP username"
        case .signature: "Signature"
        }
    }
}

enum AccountEditableValue: Sendable, Equatable {
    case text(String?)
    case boolean(Bool)

    func apply(field: AccountEditableField, to account: inout Account) {
        switch (field, self) {
        case (.displayName, .text(let value)):
            account.displayName = value ?? ""
        case (.emailAddress, .text(let value)):
            account.emailAddress = value ?? ""
        case (.signatureBelowQuote, .boolean(let value)):
            account.signatureBelowQuote = value
        case (.imapUsername, .text(let value)):
            account.imapUsername = value
        case (.signature, .text(let value)):
            account.signature = value
        case (.displayName, .boolean), (.emailAddress, .boolean),
             (.signatureBelowQuote, .text), (.imapUsername, .boolean),
             (.signature, .boolean):
            assertionFailure("Invalid value type for account field \(field.rawValue)")
        }
    }

    func matches(field: AccountEditableField, account: Account) -> Bool {
        switch (field, self) {
        case (.displayName, .text(let value)):
            account.displayName == value ?? ""
        case (.emailAddress, .text(let value)):
            account.emailAddress == value ?? ""
        case (.signatureBelowQuote, .boolean(let value)):
            account.signatureBelowQuote == value
        case (.imapUsername, .text(let value)):
            account.imapUsername == value
        case (.signature, .text(let value)):
            account.signature == value
        case (.displayName, .boolean), (.emailAddress, .boolean),
             (.signatureBelowQuote, .text), (.imapUsername, .boolean),
             (.signature, .boolean):
            false
        }
    }
}

struct AccountFieldKey: Hashable, Sendable {
    let accountId: String
    let field: AccountEditableField
}

struct AccountFieldSaveFailure: Identifiable, Sendable {
    let key: AccountFieldKey
    let isRetrying: Bool

    var id: AccountFieldKey { key }
    var field: AccountEditableField { key.field }
}

enum AccountFieldPersistenceError: Error {
    case accountMissing
}

/// App-lifetime owner for accepted account-field writes and their optimistic values.
///
/// Account-detail views are disposable navigation destinations. Keeping this owner on
/// `NavigationStore` preserves accepted ordering, refresh overlays, and field-specific
/// failures when one view disappears and another is created for the same account.
@Observable
@MainActor
final class AccountFieldPersistenceStore {
    /// The application-lifetime owner used by every navigation store and by
    /// account-removal boundaries. Tests can still instantiate isolated stores.
    static let production = AccountFieldPersistenceStore()

    private enum Phase: Equatable {
        case pending
        case committedAwaitingObservation
        case failed
    }

    private struct Entry {
        let generation: Int
        let value: AccountEditableValue
        var phase: Phase
        let persist: @MainActor () async throws -> Void
    }

    private struct AccountTail {
        let generation: Int
        let task: Task<Void, Never>
    }

    private struct QueuedPersist {
        let accountId: String
        let persist: @MainActor () async throws -> Void
    }

    private var tails: [String: AccountTail] = [:]
    private var queuedPersists: [Int: QueuedPersist] = [:]
    private var nextGeneration = 0
    private var nextTailGeneration = 0
    private var lifecycleGenerations: [String: Int] = [:]
    private var discardedAccountIds: Set<String> = []
    private var entries: [AccountFieldKey: Entry] = [:]
    private var failedKeys: Set<AccountFieldKey> = []
    private var retryingKeys: Set<AccountFieldKey> = []

    var hasOutstandingValues: Bool { !entries.isEmpty }

    func failures(accountId: String) -> [AccountFieldSaveFailure] {
        AccountEditableField.allCases.compactMap { field in
            let key = AccountFieldKey(accountId: accountId, field: field)
            guard failedKeys.contains(key) else { return nil }
            return AccountFieldSaveFailure(key: key, isRetrying: retryingKeys.contains(key))
        }
    }

    /// Accepts one value synchronously, then persists every accepted value in that
    /// same order. A superseded failure cannot replace the latest field state.
    @discardableResult
    func accept(
        accountId: String,
        field: AccountEditableField,
        value: AccountEditableValue,
        persist: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never> {
        let key = AccountFieldKey(accountId: accountId, field: field)
        return enqueue(key: key, value: value, persist: persist, isRetry: false)
    }

    @discardableResult
    func retry(_ key: AccountFieldKey) -> Task<Void, Never>? {
        guard let entry = entries[key], entry.phase == .failed else { return nil }
        return enqueue(key: key, value: entry.value, persist: entry.persist, isRetry: true)
    }

    /// Applies accepted values to a freshly-read account snapshot. A successful
    /// write remains overlaid until a refresh actually observes that value on disk;
    /// this prevents a refresh that started before commit from reverting the UI.
    func applyingOverlay(to freshAccounts: [Account]) -> [Account] {
        var accounts = freshAccounts
        var observed: [AccountFieldKey] = []

        for (key, entry) in entries {
            guard let index = accounts.firstIndex(where: { $0.id == key.accountId }) else { continue }
            if entry.phase == .committedAwaitingObservation,
               entry.value.matches(field: key.field, account: accounts[index]) {
                observed.append(key)
            } else {
                entry.value.apply(field: key.field, to: &accounts[index])
            }
        }

        for key in observed {
            entries.removeValue(forKey: key)
            failedKeys.remove(key)
            retryingKeys.remove(key)
        }
        return accounts
    }

    /// Makes row removal authoritative for this account. Already-admitted work
    /// is allowed to finish before this method returns, while work that was only
    /// queued behind it is fenced by the lifecycle generation and never runs.
    /// Purging the entries also releases their retry closures immediately.
    func discardAccount(_ accountId: String) async {
        lifecycleGenerations[accountId, default: 0] += 1
        discardedAccountIds.insert(accountId)
        purgeState(accountId: accountId)

        guard let tail = tails[accountId] else { return }
        await tail.task.value
        if tails[accountId]?.generation == tail.generation {
            tails.removeValue(forKey: accountId)
        }
    }

    /// Opens a newly-created row that intentionally reuses an old identifier
    /// (the demo account). No state from the discarded lifetime is retained.
    func reactivateAccount(_ accountId: String) {
        lifecycleGenerations[accountId, default: 0] += 1
        discardedAccountIds.remove(accountId)
        purgeState(accountId: accountId)
    }

    /// One indexed single-row update. The field enum is the column allow-list.
    nonisolated static func persist(
        accountId: String,
        field: AccountEditableField,
        value: AccountEditableValue,
        database: PrioritizedDatabase
    ) async throws {
        try await database.write(label: "account.settings.\(field.rawValue)") { db in
            switch value {
            case .text(let text):
                try db.execute(
                    sql: "UPDATE account SET \(field.rawValue) = ? WHERE id = ?",
                    arguments: [text, accountId]
                )
            case .boolean(let flag):
                try db.execute(
                    sql: "UPDATE account SET \(field.rawValue) = ? WHERE id = ?",
                    arguments: [flag.databaseValue, accountId.databaseValue]
                )
            }
            guard db.changesCount == 1 else {
                throw AccountFieldPersistenceError.accountMissing
            }
        }
    }

    private func enqueue(
        key: AccountFieldKey,
        value: AccountEditableValue,
        persist: @escaping @MainActor () async throws -> Void,
        isRetry: Bool
    ) -> Task<Void, Never> {
        guard !discardedAccountIds.contains(key.accountId) else {
            return Task { }
        }

        nextGeneration += 1
        let generation = nextGeneration
        let lifecycleGeneration = lifecycleGenerations[key.accountId, default: 0]
        entries[key] = Entry(
            generation: generation,
            value: value,
            phase: .pending,
            persist: persist
        )
        queuedPersists[generation] = QueuedPersist(
            accountId: key.accountId,
            persist: persist
        )
        if isRetry {
            retryingKeys.insert(key)
        } else {
            failedKeys.remove(key)
            retryingKeys.remove(key)
        }

        let predecessor = tails[key.accountId]?.task
        let task = Task { @MainActor in
            await predecessor?.value
            guard lifecycleGenerations[key.accountId, default: 0] == lifecycleGeneration,
                  !discardedAccountIds.contains(key.accountId),
                  let persist = queuedPersists.removeValue(forKey: generation)?.persist else { return }
            do {
                try await persist()
                guard entries[key]?.generation == generation else { return }
                entries[key]?.phase = .committedAwaitingObservation
                failedKeys.remove(key)
                retryingKeys.remove(key)
            } catch AccountFieldPersistenceError.accountMissing {
                lifecycleGenerations[key.accountId, default: 0] += 1
                discardedAccountIds.insert(key.accountId)
                purgeState(accountId: key.accountId)
            } catch {
                guard entries[key]?.generation == generation else { return }
                entries[key]?.phase = .failed
                failedKeys.insert(key)
                retryingKeys.remove(key)
            }
        }
        nextTailGeneration += 1
        tails[key.accountId] = AccountTail(generation: nextTailGeneration, task: task)
        return task
    }

    private func purgeState(accountId: String) {
        queuedPersists = queuedPersists.filter { $0.value.accountId != accountId }
        let keys = entries.keys.filter { $0.accountId == accountId }
        for key in keys {
            entries.removeValue(forKey: key)
            failedKeys.remove(key)
            retryingKeys.remove(key)
        }
    }
}

/// Store for sidebar navigation data — accounts, folders, outbox.
/// Uses explicit refresh (pull model) instead of GRDB ValueObservation.
/// Refresh is gated by RenderGate — deferred while user is interacting.
@Observable
@MainActor
final class NavigationStore {
    var accounts: [Account] = []
    var folders: [Folder] = []
    let accountFieldPersistence: AccountFieldPersistenceStore
    /// Outbox messages for display in sidebar/message list.
    var outboxMessages: [OutboxMessage] = []
    /// True when ANY active account exists, including calendar-only accounts
    /// that `accounts` filters out. Drives gates that should care about
    /// "user has connected something to TabMail" rather than email-only state
    /// (e.g. the "Try the demo" button on TabMailLoginView, which hides as
    /// soon as the user has any account).
    var hasAnyAccount: Bool = false

    /// Order-independent identity of the folder set for `.onChange(of:)` watchers
    /// that only care about membership + role, not order or metadata churn.
    /// Computing `Set(folders.map { "\($0.id):\($0.role.rawValue)" })` inline at a
    /// SwiftUI `.onChange(of:)` site overwhelms Swift's type checker — expose as
    /// a computed property instead.
    var folderKeySet: Set<String> {
        Set(folders.map { "\($0.id):\($0.role.rawValue)" })
    }
    /// True once the initial synchronous DB load has completed.
    /// RootView uses this to show a splash screen until data is ready.
    private(set) var isInitialLoadComplete = false

    private var changeObserver: NSObjectProtocol?
    private var unreadObserver: NSObjectProtocol?
    private var inboxObserver: NSObjectProtocol?
    private var refreshDebounceTask: Task<Void, Never>?
    private var refreshRequestedGeneration = 0
    private var refreshAppliedGeneration = 0
    private var refreshFlight: Task<Void, Never>?
    private let beforeSidebarReadForTesting: (@MainActor @Sendable () async -> Void)?

    init(
        accountFieldPersistence: AccountFieldPersistenceStore = .production,
        beforeSidebarReadForTesting: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        self.accountFieldPersistence = accountFieldPersistence
        self.beforeSidebarReadForTesting = beforeSidebarReadForTesting
    }

    var refreshRequestCountForTesting: Int { refreshRequestedGeneration }

    /// Load initial data synchronously. Must be called once at startup.
    /// Registers 3 targeted notification listeners:
    /// - `.backgroundDataDidChange` → full refresh (accounts + folders + outbox) — rare events
    /// - `.unreadCountsDidChange` → folders only (lightweight badge update)
    /// - `.inboxDataDidChange` → folders only (counts may have changed with new headers)
    func loadInitialData() {
        let dbPool = AppDatabase.dbPool
        let demoActive = DemoModeStore.shared.isActive
        do {
            try dbPool.read { db in
                self.accounts = try Account.sidebarRequest(demoActive: demoActive).fetchAll(db)
                self.folders = try Folder.sidebarRequest(demoActive: demoActive).fetchAll(db)
                self.outboxMessages = try OutboxMessage.order(Column("createdAt").desc).fetchAll(db)
                self.hasAnyAccount = try Account.filter(Column("isActive") == true).fetchCount(db) > 0
            }
        } catch {
            print("[NavigationStore] Initial load error: \(error)")
        }
        isInitialLoadComplete = true

        // Full refresh — structural changes (account add/remove, outbox).
        if changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(
                forName: .backgroundDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshDebounceTask?.cancel()
                    self?.refreshDebounceTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled else { return }
                        await self?.refresh()
                    }
                }
            }
        }

        // Lightweight — only folder badges need updating.
        if unreadObserver == nil {
            unreadObserver = NotificationCenter.default.addObserver(
                forName: .unreadCountsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshFolders()
                }
            }
        }

        // New message headers — folder counts may have changed.
        if inboxObserver == nil {
            inboxObserver = NotificationCenter.default.addObserver(
                forName: .inboxDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshFolders()
                }
            }
        }
    }

    /// Refresh all data from GRDB. Always safe to call — overlay guarantees correctness.
    func refresh() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        refreshRequestedGeneration += 1
        let flight: Task<Void, Never>
        if let existing = refreshFlight {
            flight = existing
        } else {
            let created = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runRefreshFlight()
            }
            refreshFlight = created
            flight = created
        }
        await flight.value
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if ms >= 50 {
            BackgroundSyncLogger.logInbox("[NavStore] refresh \(ms)ms (accounts=\(accounts.count) folders=\(folders.count) outbox=\(outboxMessages.count))")
        }
    }

    /// Refresh only folders (lightweight — skips accounts/outbox).
    /// Adjusts unreadCount using the optimistic overlay for pending mutations.
    /// Async + single read: folders AND the overlay-relevant message headers are
    /// fetched in ONE off-main GRDB read. Previously this was a synchronous
    /// folder read followed by an N+1 per-overlay-message header read, all on the
    /// main thread — a warm-foreground UI-hang source (Half A / PLAN_HANG_FIX).
    /// The overlay unread-count adjustment then runs on the main actor.
    func refreshFolders() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if ms >= 50 {
                BackgroundSyncLogger.logInbox("[NavStore] refreshFolders \(ms)ms (folders=\(folders.count))")
            }
        }
        let overlay = AccountManager.shared.snapshotOverlay()
        let overlayMsgIds = Array(overlay.keys)
        do {
            let (freshFolders, headersById): ([Folder], [String: MessageHeader]) =
                try await AppDatabase.dbPool.read { db in
                    let folders = try Folder.order(Column("name")).fetchAll(db)
                    var headers: [String: MessageHeader] = [:]
                    if !overlayMsgIds.isEmpty {
                        for h in try MessageHeader.filter(overlayMsgIds.contains(Column("id"))).fetchAll(db) {
                            headers[h.id] = h
                        }
                    }
                    return (folders, headers)
                }
            var adjusted = freshFolders
            // Apply overlay-adjusted unread counts (in-memory, main actor).
            if !overlay.isEmpty {
                var folderIndex: [String: Int] = [:]
                for (i, f) in adjusted.enumerated() { folderIndex[f.id] = i }

                for (msgId, mutation) in overlay {
                    guard let header = headersById[msgId] else { continue }
                    let dbFolderId = header.folderId
                    let dbIsRead = header.isRead

                    // Adjust for isRead change (within same folder)
                    if let overlayRead = mutation.isRead, overlayRead != dbIsRead, mutation.folderId == nil {
                        if let idx = folderIndex[dbFolderId] {
                            if overlayRead && !dbIsRead {
                                adjusted[idx].unreadCount = max(0, adjusted[idx].unreadCount - 1)
                            } else if !overlayRead && dbIsRead {
                                adjusted[idx].unreadCount += 1
                            }
                        }
                    }

                    // Adjust for folderId change (message moved). The source
                    // decrement and dest increment are gated on DIFFERENT
                    // questions — under a coalesced overlay entry (isRead +
                    // folderId merged into one PendingMutation, ADR-IOS-057),
                    // "was this counted in source's unread total" and "will it
                    // be counted in dest's" can diverge (e.g. a read message
                    // moved AND marked unread in the same mutation: it was
                    // never in source's unread count, but WILL be in dest's).
                    if let newFolderId = mutation.folderId, newFolderId != dbFolderId {
                        // Source: raw DB truth — was it unread in the folder it's
                        // leaving? (isRead-in-mutation is a post-move target, not
                        // a description of the source folder's pre-move count.)
                        let wasUnreadInSource = !dbIsRead
                        // Dest: overlay-projected — will it be unread once it lands?
                        let willBeUnreadInDest = mutation.isRead.map { !$0 } ?? !dbIsRead
                        if wasUnreadInSource, let srcIdx = folderIndex[dbFolderId] {
                            adjusted[srcIdx].unreadCount = max(0, adjusted[srcIdx].unreadCount - 1)
                        }
                        if willBeUnreadInDest, let dstIdx = folderIndex[newFolderId] {
                            adjusted[dstIdx].unreadCount += 1
                        }
                    }
                }
            }
            self.folders = adjusted
        } catch {
            print("[NavigationStore] Folder refresh error: \(error)")
        }
    }

    /// Refresh only outbox messages. Async read — never blocks the main thread.
    func refreshOutbox() async {
        do {
            let outbox = try await AppDatabase.dbPool.read { db in
                try OutboxMessage.order(Column("createdAt").desc).fetchAll(db)
            }
            self.outboxMessages = outbox
        } catch {
            print("[NavigationStore] Outbox refresh error: \(error)")
        }
    }

    /// Sendable bundle for the async sidebar read (GRDB's async `read` overload
    /// requires a Sendable return).
    private struct SidebarBundle: Sendable {
        let accounts: [Account]
        let folders: [Folder]
        let outbox: [OutboxMessage]
        let hasAny: Bool
    }

    /// Immediate refresh without RenderGate check. Used for initial load
    /// and after user-initiated actions where freshness is required.
    /// The GRDB read runs off the main thread (async) so it can't block the UI
    /// during the foreground catch-up burst (Half A / PLAN_HANG_FIX); the
    /// @Observable assignments happen on the main actor after it resolves.
    private func runRefreshFlight() async {
        while refreshAppliedGeneration < refreshRequestedGeneration {
            let generation = refreshRequestedGeneration
            let demoActive = DemoModeStore.shared.isActive
            await beforeSidebarReadForTesting?()
            do {
                let bundle = try await AppDatabase.dbPool.read { db -> SidebarBundle in
                    SidebarBundle(
                        accounts: try Account.sidebarRequest(demoActive: demoActive).fetchAll(db),
                        folders: try Folder.sidebarRequest(demoActive: demoActive).fetchAll(db),
                        outbox: try OutboxMessage.order(Column("createdAt").desc).fetchAll(db),
                        hasAny: try Account.filter(Column("isActive") == true).fetchCount(db) > 0
                    )
                }
                // A request that arrived while the read was suspended owns the
                // result. Discard this snapshot and perform its follow-up before
                // completing any waiter joined to the current flight.
                guard generation == refreshRequestedGeneration else { continue }
                self.accounts = accountFieldPersistence.applyingOverlay(to: bundle.accounts)
                self.folders = bundle.folders
                self.outboxMessages = bundle.outbox
                self.hasAnyAccount = bundle.hasAny
                refreshAppliedGeneration = generation
            } catch {
                print("[NavigationStore] Refresh error: \(error)")
                if generation == refreshRequestedGeneration {
                    refreshAppliedGeneration = generation
                }
            }
        }
        refreshFlight = nil
    }

    /// Toggle favorite status for a folder. Async: the write runs OFF the main
    /// actor (the `await` overload suspends, never blocks) so it can't freeze the
    /// UI when a sync / backfill / merge write is in flight on GRDB's single
    /// writer connection. The UPDATE is a single atomic row write (the toggle
    /// happens in SQL), so there is no read-decide-write race across the suspension.
    func toggleFavorite(_ folder: Folder) async {
        try? await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE folder SET isFavorite = NOT isFavorite WHERE id = ?", arguments: [folder.id])
        }
        await refreshFolders()
    }

    /// Set favorite status for a folder. Async — see `toggleFavorite`.
    func setFavorite(_ folder: Folder, isFavorite: Bool) async {
        try? await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE folder SET isFavorite = ? WHERE id = ?", arguments: [isFavorite, folder.id])
        }
        await refreshFolders()
    }

    /// Set an account as primary (only one at a time). Async — see `toggleFavorite`.
    /// Both UPDATEs run in ONE write transaction, so "clear all, then set one"
    /// stays atomic — there is never a committed state with zero or two primaries.
    func setPrimaryAccount(_ account: Account) async {
        try? await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE account SET isPrimary = 0 WHERE isPrimary = 1")
            try db.execute(sql: "UPDATE account SET isPrimary = 1 WHERE id = ?", arguments: [account.id])
        }
        await refresh()
    }

}
