/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension SyncEngine {
    /// Clears every sync-state column a Settings reset owns, in the caller's
    /// transaction. `accountId` nil means every account. The one list for both
    /// resets, "Reset message data" (`AccountDetailView.resetMessageDataTxn`) and
    /// "Delete All Email Index Data" (`SettingsView.localIndexWipeTxn`): both delete
    /// the mail, so every cursor, bookmark and progress mark that describes the
    /// deleted rows goes with them, and the next sync starts each folder like a new
    /// account's (#501, #848; ADR-IOS-111 amendment 2026-11-14).
    ///
    /// Per folder, every row of the account(s), the empty-path row included:
    /// the backfill walk (`backfillComplete`, `oldestSyncedDate`, `backfillUidCursor`,
    /// `backfillPageToken`, `backfillPageHeldSince`), the IMAP STATUS cache
    /// (`lastKnownUidNext`, and `lastKnownHighestModSeq`, which would otherwise let
    /// the full sync skip a non-Inbox folder whose MODSEQ has not moved), the change
    /// reader (`changeState`, `changeCursor`) and the older-mail check
    /// (`catchUpState`). Per account: the change bookmark (`lastHistoryId`) and the
    /// full-sync time (`lastFullSyncAt`), so the next pass runs the full sync.
    ///
    /// Kept on purpose: `lastKnownUidValidity` and `uidValidityResetPendingAt` (the
    /// epoch and the UIDVALIDITY reaction's quarantine flag, ADR-IOS-061; a reset
    /// does not change the server's numbering) and `backfillVersion` (the trigger
    /// moves it on this write). `SettingsSyncStateResetTests` reads the `folder`
    /// schema, so a new column is checked against this list until it is added here
    /// or named there as kept.
    nonisolated static func resetSyncStateTxn(_ db: Database, accountId: String?) throws {
        let folderReset = """
            UPDATE folder SET
                backfillComplete = 0,
                oldestSyncedDate = NULL,
                lastKnownUidNext = NULL,
                lastKnownHighestModSeq = NULL,
                backfillUidCursor = NULL,
                backfillPageToken = NULL,
                backfillPageHeldSince = NULL,
                changeState = NULL,
                changeCursor = NULL,
                catchUpState = NULL
            """
        let accountReset = "UPDATE account SET lastHistoryId = NULL, lastFullSyncAt = NULL"
        if let accountId {
            try db.execute(sql: folderReset + " WHERE accountId = ?", arguments: [accountId])
            try db.execute(sql: accountReset + " WHERE id = ?", arguments: [accountId])
        } else {
            try db.execute(sql: folderReset)
            try db.execute(sql: accountReset)
        }
    }
}
