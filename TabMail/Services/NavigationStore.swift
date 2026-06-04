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
                        self?.refresh()
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
                    self?.refreshFolders()
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
                    self?.refreshFolders()
                }
            }
        }
    }

    /// Refresh all data from GRDB. Always safe to call — overlay guarantees correctness.
    func refresh() {
        let t0 = CFAbsoluteTimeGetCurrent()
        refreshNow()
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if ms >= 50 {
            BackgroundSyncLogger.logInbox("[NavStore] refresh \(ms)ms (accounts=\(accounts.count) folders=\(folders.count) outbox=\(outboxMessages.count))")
        }
    }

    /// Refresh only folders (lightweight — skips accounts/outbox).
    /// Adjusts unreadCount using the optimistic overlay for pending mutations.
    func refreshFolders() {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if ms >= 50 {
                BackgroundSyncLogger.logInbox("[NavStore] refreshFolders \(ms)ms (folders=\(folders.count))")
            }
        }
        do {
            var freshFolders = try AppDatabase.dbPool.read { db in
                try Folder.order(Column("name")).fetchAll(db)
            }
            // Apply overlay-adjusted unread counts
            let overlay = AccountManager.shared.snapshotOverlay()
            if !overlay.isEmpty {
                // Build folder ID lookup for quick access
                var folderIndex: [String: Int] = [:]
                for (i, f) in freshFolders.enumerated() { folderIndex[f.id] = i }

                for (msgId, mutation) in overlay {
                    // Determine the message's current DB folder by reading the header
                    guard let header = try? AppDatabase.dbPool.read({ db in
                        try MessageHeader.fetchOne(db, key: msgId)
                    }) else { continue }

                    let dbFolderId = header.folderId
                    let dbIsRead = header.isRead

                    // Adjust for isRead change (within same folder)
                    if let overlayRead = mutation.isRead, overlayRead != dbIsRead, mutation.folderId == nil {
                        if let idx = folderIndex[dbFolderId] {
                            if overlayRead && !dbIsRead {
                                freshFolders[idx].unreadCount = max(0, freshFolders[idx].unreadCount - 1)
                            } else if !overlayRead && dbIsRead {
                                freshFolders[idx].unreadCount += 1
                            }
                        }
                    }

                    // Adjust for folderId change (message moved)
                    if let newFolderId = mutation.folderId, newFolderId != dbFolderId {
                        let isUnread = mutation.isRead.map { !$0 } ?? !dbIsRead
                        if isUnread {
                            if let srcIdx = folderIndex[dbFolderId] {
                                freshFolders[srcIdx].unreadCount = max(0, freshFolders[srcIdx].unreadCount - 1)
                            }
                            if let dstIdx = folderIndex[newFolderId] {
                                freshFolders[dstIdx].unreadCount += 1
                            }
                        }
                    }
                }
            }
            self.folders = freshFolders
        } catch {
            print("[NavigationStore] Folder refresh error: \(error)")
        }
    }

    /// Refresh only outbox messages.
    func refreshOutbox() {
        do {
            self.outboxMessages = try AppDatabase.dbPool.read { db in
                try OutboxMessage.order(Column("createdAt").desc).fetchAll(db)
            }
        } catch {
            print("[NavigationStore] Outbox refresh error: \(error)")
        }
    }

    /// Immediate refresh without RenderGate check. Used for initial load
    /// and after user-initiated actions where freshness is required.
    private func refreshNow() {
        let dbPool = AppDatabase.dbPool
        let demoActive = DemoModeStore.shared.isActive
        do {
            try dbPool.read { db in
                let newAccounts = try Account.sidebarRequest(demoActive: demoActive).fetchAll(db)
                let newFolders = try Folder.sidebarRequest(demoActive: demoActive).fetchAll(db)
                let newOutbox = try OutboxMessage.order(Column("createdAt").desc).fetchAll(db)
                let newHasAny = try Account.filter(Column("isActive") == true).fetchCount(db) > 0
                // Always assign — @Observable re-render cost is negligible since
                // refreshNow() only runs on backgroundDataDidChange.
                self.accounts = newAccounts
                self.folders = newFolders
                self.outboxMessages = newOutbox
                self.hasAnyAccount = newHasAny
            }
        } catch {
            print("[NavigationStore] Refresh error: \(error)")
        }
    }

    /// Toggle favorite status for a folder.
    // Sync write on MainActor — intentional. Rare settings operation (single-row UPDATE),
    // negligible contention risk. Async would risk UI state desync if user navigates away.
    func toggleFavorite(_ folder: Folder) {
        try? AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE folder SET isFavorite = NOT isFavorite WHERE id = ?", arguments: [folder.id])
        }
        refreshFolders()
    }

    /// Set favorite status for a folder.
    // Sync write on MainActor — intentional. See toggleFavorite comment.
    func setFavorite(_ folder: Folder, isFavorite: Bool) {
        try? AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE folder SET isFavorite = ? WHERE id = ?", arguments: [isFavorite, folder.id])
        }
        refreshFolders()
    }

    /// Set an account as primary (only one at a time).
    // Sync write on MainActor — intentional. See toggleFavorite comment.
    func setPrimaryAccount(_ account: Account) {
        try? AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE account SET isPrimary = 0 WHERE isPrimary = 1")
            try db.execute(sql: "UPDATE account SET isPrimary = 1 WHERE id = ?", arguments: [account.id])
        }
        refresh()
    }

}
