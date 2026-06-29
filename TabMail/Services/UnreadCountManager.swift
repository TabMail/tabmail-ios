/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import UIKit
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

    private var dbPool: PrioritizedDatabase { AppDatabase.dbPool }

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
            // Protected by a background-task assertion so a user who reads an
            // email and IMMEDIATELY backgrounds still gets the badge decrement:
            // without it, the read+setBadgeCount races iOS suspension and the
            // badge stays stale until the next foreground recount.
            Task { await updateBadgeProtected() }
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
            // A write aborted by GRDB database suspension (ADR-IOS-041) is
            // EXPECTED at the background-suspension instant and benign — the
            // counts recompute on the next wake's recount. Don't log it as a
            // failure; only log genuine recount failures.
            if !error.isDatabaseSuspensionAbort {
                print("[UnreadCount] Recount failed: \(error)")
            }
            return
        }

        // Refresh sidebar folder badges — post on MainActor for UI listeners
        await MainActor.run {
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
        }

        // Badge update — fire-and-forget (don't block notification flow)
        Task { await updateBadge() }
    }

    /// Recompute unread counts for ALL inbox-role folders, then update the badge.
    /// Use after a batch mutation whose exact affected folders aren't worth
    /// tracking (e.g. the NSE staging merge): that merge only ever changes inbox
    /// membership and the badge sums inbox folders, so a blanket inbox recount is
    /// both sufficient and self-healing — no per-message bookkeeping needed.
    func recountInboxFolders() async {
        let inboxFolderIds: Set<String> = (try? await dbPool.read { db in
            try Set(String.fetchAll(db,
                sql: "SELECT id FROM folder WHERE role = ?",
                arguments: [FolderRole.inbox.rawValue]))
        }) ?? []
        guard !inboxFolderIds.isEmpty else { return }
        requestRecount(folderIds: inboxFolderIds)
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
            // as its increment/decrement base (see NSEBadge / NSEState).
            UserDefaults(suiteName: "group.ai.tabmail")?.set(totalUnread, forKey: NSEBadge.badgeCountKey)
            print("[UnreadCount] Badge set to \(totalUnread)")
            BackgroundSyncLogger.log("badge: \(totalUnread)")
            // Record the recently-arrived unread inbox messages this count
            // already includes into the NSE's dedup table, so a concurrent NSE
            // delivery for the same message doesn't increment on top (the
            // main-app-overlap "+2 for one email"). See NSEBadge.markCounted.
            if totalUnread > 0 { await recordRecentUnreadForNSE() }
        } catch {
            // Suspension aborts (ADR-IOS-041) are benign — the badge re-syncs on
            // the next wake's recount; don't surface them as errors.
            if !error.isDatabaseSuspensionAbort {
                print("[UnreadCount] Badge update error: \(error)")
            }
        }
    }

    /// `updateBadge()` wrapped in a UIKit background-task assertion so it completes
    /// even when the user backgrounds the app immediately after the action that
    /// triggered it (read an email → flick to the home screen). The assertion
    /// delays iOS suspension for the ~ms the read + `setBadgeCount` need, so the
    /// badge reflects the new count instead of staying stale until the next
    /// foreground recount. The atomic `Mutex` lets the expiration handler and the
    /// `defer` end the task race-safely (whoever runs first wins; the other
    /// no-ops). Mirrors `ActiveAIQueue.executeJob`'s bg-task pattern.
    func updateBadgeProtected() async {
        let bgTaskId = Mutex<UIBackgroundTaskIdentifier>(.invalid)
        let beginId = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "badge-update") {
                let toEnd = bgTaskId.withLock { v -> UIBackgroundTaskIdentifier in let was = v; v = .invalid; return was }
                if toEnd != .invalid {
                    Task { @MainActor in UIApplication.shared.endBackgroundTask(toEnd) }
                }
            }
        }
        bgTaskId.withLock { $0 = beginId }
        defer {
            let toEnd = bgTaskId.withLock { v -> UIBackgroundTaskIdentifier in let was = v; v = .invalid; return was }
            if toEnd != .invalid {
                Task { @MainActor in UIApplication.shared.endBackgroundTask(toEnd) }
            }
        }
        await updateBadge()
    }

    /// Stamp the most-recent unread inbox messages into the NSE's
    /// `nse_badge_counted` dedup table (keyed by `NSEBadge.countedId`, rfc822-
    /// preferred so it matches the NSE side for all providers). Bounded to
    /// `SyncConfig.nseBadgeDedupRecentLimit` — only recently-arrived unread can
    /// race a concurrent NSE delivery. Best-effort: any read/open failure just
    /// skips the optimization (the NSE then over-counts transiently and the
    /// next recount corrects it).
    private func recordRecentUnreadForNSE() async {
        // Foreground-only. The main-app/NSE badge overlap this guards against
        // can only happen while the app is actively counting (foreground) as an
        // NSE delivery lands. When backgrounded/suspended there's no such race,
        // AND opening a fresh staging connection to write here would either
        // abort under GRDB suspension or — worse, if the connection is opened
        // after the suspend notification and misses it — write while suspended
        // and risk a 0xdead10cc kill (ADR-IOS-041). So skip unless active.
        let isActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        guard isActive else { return }

        let ids: [String]
        do {
            ids = try await dbPool.read { db -> [String] in
                let inboxFolderIds = try String.fetchAll(db,
                    sql: "SELECT id FROM folder WHERE role = ?",
                    arguments: [FolderRole.inbox.rawValue])
                guard !inboxFolderIds.isEmpty else { return [] }
                let placeholders = inboxFolderIds.map { _ in "?" }.joined(separator: ", ")
                // LIMIT is a trusted compile-time Int constant (not user input),
                // inlined to avoid mixing String + Int statement arguments.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT accountId, messageId, rfc822MessageId
                    FROM messageHeader
                    WHERE folderId IN (\(placeholders)) AND isRead = 0
                    ORDER BY date DESC
                    LIMIT \(SyncConfig.nseBadgeDedupRecentLimit)
                    """, arguments: StatementArguments(inboxFolderIds))
                return rows.map { row in
                    NSEBadge.countedId(
                        accountId: row["accountId"],
                        messageId: row["messageId"],
                        rfc822MessageId: row["rfc822MessageId"])
                }
            }
        } catch {
            return
        }
        guard !ids.isEmpty, let stagingDB = NSEDataBridge.openStagingDB() else { return }
        NSEBadge.markCounted(db: stagingDB, ids: ids)
    }
}
