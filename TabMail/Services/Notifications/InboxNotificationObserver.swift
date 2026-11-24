/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Watches `messageHeader` for rows that leave the inbox (`isInInbox` flips
/// `true → false`, or a previously-inbox row is deleted) and clears the
/// associated `email-{accountId}-{messageId}` notification.
///
/// Complements the time-based `NotificationCleanupService`
/// (`Shared/Notifications/NotificationCleanupService.swift`) — that service
/// ages notifications out at 24 h. This observer reacts to state changes
/// immediately, so a remote archive (e.g. from Thunderbird) clears the iOS
/// banner as soon as delta sync commits.
///
/// The map starts EMPTY (#1385): no read at launch. It learns a row from any
/// insert or update of it after the observer is registered, so an email that
/// arrives (or is touched) after launch and then leaves the inbox has its banner
/// cleared. A row that sat untouched in the inbox since before launch is not in
/// the map; the banners that launch might otherwise leave behind are removed
/// when the user opens the app (`EmailBannerOpenClear`).
///
/// Performance contract:
///   - No full table reads, at launch or at steady state. Per-commit cost is
///     one rowid B-tree `SELECT … WHERE rowid IN (touched rowids)` scoped to
///     the write batch.
///   - Callbacks fire on the GRDB writer queue (background). Never main.
///   - Notification clear is called synchronously on the writer queue.
///     `UNUserNotificationCenter.removeDeliveredNotifications` is documented
///     thread-safe + non-blocking (microseconds per call). Contract: clients
///     injecting `clear` MUST NOT re-enter GRDB writes — would deadlock.
final class InboxNotificationObserver: TransactionObserver, @unchecked Sendable {

    /// Map of rowids → (accountId, messageId) for inbox rows written since the
    /// observer was registered (it starts empty). Touched ONLY by observer
    /// callbacks, which are serialized on the GRDB writer queue, so no Mutex is
    /// needed. `@unchecked Sendable` is correct
    /// per CLAUDE.md rule (single-threaded by construction).
    private var currentlyInInbox: [Int64: (accountId: String, messageId: String)] = [:]

    /// Pending row ids accumulated during the in-flight transaction.
    /// Reset on `databaseDidCommit` / `databaseDidRollback`.
    private var pendingInsertUpdate: Set<Int64> = []
    private var pendingDelete: Set<Int64> = []

    /// Notification clear sink. Production wires this to
    /// `NSEDataBridge.clearNotification`; tests inject a recorder.
    private let clear: @Sendable (String, String) -> Void

    init(clear: @escaping @Sendable (String, String) -> Void) {
        self.clear = clear
    }

    // MARK: - TransactionObserver

    /// Pre-filter — restrict observation to messageHeader insert/update/delete.
    /// All other table writes (folder, pendingOperation, chatTurn, …) skip
    /// the observer entirely.
    ///
    /// An update that writes only `htmlCachedAt` is skipped too. Only the
    /// HTML-cache pair's triggers and its one-time fill write that column
    /// (`HTMLCachePair`), and none of them changes `isInInbox`, so they never
    /// move a row into or out of the inbox. Without this, every body save or
    /// delete, and the fill over every cached header, would put those headers'
    /// rowids into the post-commit read below. GRDB passes the column names an
    /// update statement writes, a trigger's included, so this is decided per
    /// statement: a statement that also writes another `messageHeader` column
    /// is still observed.
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        guard eventKind.tableName == MessageHeader.databaseTableName else { return false }
        if case .update(_, let columnNames) = eventKind,
           columnNames.isSubset(of: Self.ignoredUpdateColumns) {
            return false
        }
        return true
    }

    /// `messageHeader` columns whose updates alone cannot change inbox membership.
    static let ignoredUpdateColumns: Set<String> = [HTMLCachePair.column]

    /// Called once per affected row, INSIDE the in-flight transaction.
    /// Cheap by design — just record the rowid. No SQL.
    func databaseDidChange(with event: DatabaseEvent) {
        switch event.kind {
        case .insert, .update:
            pendingInsertUpdate.insert(event.rowID)
        case .delete:
            pendingDelete.insert(event.rowID)
        }
    }

    /// Called after the transaction commits, on the writer queue, with a
    /// `Database` handle valid for the duration of this callback.
    func databaseDidCommit(_ db: Database) {
        defer {
            pendingInsertUpdate.removeAll(keepingCapacity: true)
            pendingDelete.removeAll(keepingCapacity: true)
        }
        guard !pendingInsertUpdate.isEmpty || !pendingDelete.isEmpty else { return }

        var leaving: [(accountId: String, messageId: String)] = []

        // Deletes: lookup in cached map; if previously in-inbox, that's a leave.
        for rid in pendingDelete {
            if let pair = currentlyInInbox.removeValue(forKey: rid) {
                leaving.append(pair)
            }
        }

        // Inserts/updates: batched rowid-B-tree read for current state.
        if !pendingInsertUpdate.isEmpty {
            do {
                let rids = Array(pendingInsertUpdate)
                let placeholders = repeatElement("?", count: rids.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT rowid, isInInbox, accountId, messageId
                    FROM messageHeader
                    WHERE rowid IN (\(placeholders))
                """, arguments: StatementArguments(rids))

                var seen = Set<Int64>()
                for row in rows {
                    let rid: Int64 = row["rowid"]
                    seen.insert(rid)
                    let inInbox: Bool = row["isInInbox"]
                    let acct: String = row["accountId"]
                    let mid: String = row["messageId"]
                    if inInbox {
                        // Stay in / enter inbox — refresh map.
                        currentlyInInbox[rid] = (acct, mid)
                    } else if let pair = currentlyInInbox.removeValue(forKey: rid) {
                        // Leaving inbox — clear notification, drop from map.
                        leaving.append(pair)
                    }
                    // else: not in map AND not in inbox → ignore.
                }
                // Defensive: rowids in pendingInsertUpdate not returned by the
                // SELECT mean the row was deleted between event and SELECT
                // (shouldn't happen — same writer queue, same txn handle).
                // Treat as a delete to stay coherent.
                for rid in pendingInsertUpdate where !seen.contains(rid) {
                    if let pair = currentlyInInbox.removeValue(forKey: rid) {
                        leaving.append(pair)
                    }
                }
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    print("[InboxNotifObserver] post-commit SELECT failed: \(error)")
                }
            }
        }

        guard !leaving.isEmpty else { return }
        // Call clear synchronously on the writer queue.
        // UNUserNotificationCenter.removeDeliveredNotifications is documented
        // thread-safe + non-blocking (microseconds per call), so this is OK
        // even for batches of hundreds of rows.
        // Contract: `clear` MUST NOT re-enter GRDB writes — would deadlock.
        for (acct, mid) in leaving {
            clear(acct, mid)
        }
    }

    /// Discard pending events. Map is unchanged — its in-memory state matches
    /// the pre-transaction DB state, which the rollback restored.
    func databaseDidRollback(_ db: Database) {
        pendingInsertUpdate.removeAll(keepingCapacity: true)
        pendingDelete.removeAll(keepingCapacity: true)
    }
}
