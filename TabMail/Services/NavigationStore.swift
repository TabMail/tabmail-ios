/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Store for sidebar navigation data — accounts, folders, outbox.
/// Uses explicit refresh (pull model) instead of GRDB ValueObservation.
/// Refresh is gated by RenderGate — deferred while user is interacting.
@Observable
@MainActor
final class NavigationStore {
    var accounts: [Account] = []
    var folders: [Folder] = []
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
        await refreshNow()
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
    private func refreshNow() async {
        let demoActive = DemoModeStore.shared.isActive
        do {
            let bundle = try await AppDatabase.dbPool.read { db -> SidebarBundle in
                SidebarBundle(
                    accounts: try Account.sidebarRequest(demoActive: demoActive).fetchAll(db),
                    folders: try Folder.sidebarRequest(demoActive: demoActive).fetchAll(db),
                    outbox: try OutboxMessage.order(Column("createdAt").desc).fetchAll(db),
                    hasAny: try Account.filter(Column("isActive") == true).fetchCount(db) > 0
                )
            }
            self.accounts = bundle.accounts
            self.folders = bundle.folders
            self.outboxMessages = bundle.outbox
            self.hasAnyAccount = bundle.hasAny
        } catch {
            print("[NavigationStore] Refresh error: \(error)")
        }
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
