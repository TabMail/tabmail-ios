/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import UserNotifications

/// Centralized, debounced unread count manager.
/// Instead of fragile increment/decrement, recounts from the database.
/// Every request to recount is debounced — rapid actions coalesce
/// into a single efficient DB query.
///
/// Actor isolation replaces @MainActor — debounce state is protected by
/// actor serial execution without occupying the main thread. GRDB writes
/// run on the actor's executor (off MainActor). Notifications are posted
/// via MainActor hop (UI listeners expect main thread delivery).
actor UnreadCountManager {
    static let shared = UnreadCountManager()

    private var pendingFolderIds: Set<String> = []
    private var debounceTask: Task<Void, Never>?
    /// True while a recount is in-flight or the cooldown window is open.
    private var isActive = false

    private var dbPool: DatabasePool { AppDatabase.dbPool }

    /// Request a recount of unread messages for the given folder IDs.
    /// First request fires immediately. Subsequent requests within the
    /// cooldown window are coalesced and fire once the window expires.
    ///
    /// - Parameter notifyImmediately: Post `.unreadCountsDidChange` right away,
    ///   before the async recount completes. Use for optimistic UI paths (user actions)
    ///   where the DB write already happened and the list needs to refresh NOW.
    ///   Sync paths should pass `false` (default) — the recount posts after counts update.
    func requestRecount(folderIds: Set<String>, notifyImmediately: Bool = false) {
        if notifyImmediately {
            Task { @MainActor in
                NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            }
            // Badge can update immediately — folder.unreadCount was already set
            // by the optimistic write in the same transaction as the user action.
            Task { await updateBadge() }
        }
        pendingFolderIds.formUnion(folderIds)
        if !isActive {
            // Leading edge — fire immediately, then fixed cooldown.
            // No trailing reset: cooldown always runs to completion,
            // preventing starvation during rapid sync activity.
            isActive = true
            debounceTask = Task {
                await performRecount()
                // Fixed cooldown — requests during this window are collected
                try? await Task.sleep(for: .seconds(SyncConfig.unreadRecountDebounceSeconds))
                // Drain anything that accumulated during the cooldown
                if !pendingFolderIds.isEmpty {
                    await performRecount()
                }
                isActive = false
            }
        }
        // Else: already active — folderIds collected in pendingFolderIds,
        // will be drained when the fixed cooldown expires. No timer reset.
    }

    /// Convenience for a single folder ID.
    func requestRecount(folderId: String, notifyImmediately: Bool = false) {
        requestRecount(folderIds: [folderId], notifyImmediately: notifyImmediately)
    }

    private func performRecount() async {
        let folderIdArray = Array(pendingFolderIds)
        pendingFolderIds.removeAll()
        guard !folderIdArray.isEmpty else { return }

        do {
            try await dbPool.write { db in
                // Single grouped query: count unread per folder
                let placeholders = folderIdArray.map { _ in "?" }.joined(separator: ", ")
                let sql = """
                    SELECT folderId, COUNT(*) as cnt
                    FROM messageHeader
                    WHERE folderId IN (\(placeholders)) AND isRead = 0
                    GROUP BY folderId
                    """
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(folderIdArray))
                var counts: [String: Int] = [:]
                for row in rows {
                    let fid: String = row["folderId"]
                    let cnt: Int = row["cnt"]
                    counts[fid] = cnt
                }

                // Update each folder — folders with all-read messages get 0
                for folderId in folderIdArray {
                    let count = counts[folderId] ?? 0
                    try db.execute(
                        sql: "UPDATE folder SET unreadCount = ? WHERE id = ?",
                        arguments: [count, folderId]
                    )
                }
            }
        } catch {
            print("[UnreadCount] Recount failed: \(error)")
            return
        }

        // Refresh sidebar folder badges — post on MainActor for UI listeners
        await MainActor.run {
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
        }

        // Badge update — fire-and-forget (don't block notification flow)
        Task { await updateBadge() }
    }

    /// Update app icon badge from current inbox unread counts.
    func updateBadge() async {
        do {
            let totalUnread = try await dbPool.read { db -> Int in
                let activeAccountIds = try String.fetchAll(db,
                    Account.select(Column("id")).filter(Column("isActive") == true)
                )
                guard !activeAccountIds.isEmpty else { return 0 }

                return try Int.fetchOne(db,
                    sql: """
                        SELECT COALESCE(SUM(unreadCount), 0)
                        FROM folder
                        WHERE accountId IN (\(activeAccountIds.map { _ in "?" }.joined(separator: ", ")))
                          AND role = ?
                        """,
                    arguments: StatementArguments(activeAccountIds + [FolderRole.inbox.rawValue])
                ) ?? 0
            }

            try await UNUserNotificationCenter.current().setBadgeCount(totalUnread)
            // Mirror to app-group suite so NSE can read the authoritative count
            // as its increment/decrement base (see NSEState badge accessors).
            UserDefaults(suiteName: "group.ai.tabmail")?.set(totalUnread, forKey: "nse.unreadBadge")
            print("[UnreadCount] Badge set to \(totalUnread)")
            BackgroundSyncLogger.log("badge: \(totalUnread)")
        } catch {
            print("[UnreadCount] Badge update error: \(error)")
        }
    }
}
