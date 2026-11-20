/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The authoritative writes of the two Settings resets (#1062, ADR-IOS-104
/// amendment 2026-11-20). The views call these and nothing else writes the
/// resets, so every reset takes the sync turn of each account it writes
/// (`withSyncTurns`) before the write transaction opens: no pass of those
/// accounts writes what it read before the reset after it.
extension SyncEngine {
    /// "Reset message data" for one account: `AccountDetailView.resetMessageDataTxn`
    /// in one transaction, inside the account's sync turn.
    func resetMessageData(accountId: String) async throws {
        let pool = AppDatabase.dbPool
        try await withSyncTurns(accountIds: [accountId]) {
            try await pool.write { db in
                try AccountDetailView.resetMessageDataTxn(db, accountId: accountId)
            }
        }
    }

    /// "Delete All Email Index Data": `SettingsView.localIndexWipeTxn` in one
    /// transaction, inside the sync turn of every account it wipes. The account
    /// ids are read again inside the turns; if the set changed meanwhile (an
    /// account was added or removed), the turns are released and taken again for
    /// the new set, so no account is wiped without its turn.
    func wipeLocalIndex() async throws {
        let pool = AppDatabase.dbPool
        var accountIds = try await pool.read { db in try String.fetchAll(db, sql: "SELECT id FROM account ORDER BY id") }
        while true {
            let held = accountIds
            let current: [String]? = try await withSyncTurns(accountIds: held) {
                try await pool.write { db -> [String]? in
                    let now = try String.fetchAll(db, sql: "SELECT id FROM account ORDER BY id")
                    guard Set(now) == Set(held) else { return now }
                    try SettingsView.localIndexWipeTxn(db)
                    return nil
                }
            }
            guard let current else { return }
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[SyncTurn] wipe: the accounts changed while waiting (\(held.count) -> \(current.count)), taking the turns again")
            }
            accountIds = current
        }
    }
}
