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
    /// "Reset message data" for one account: `resetMessageDataTxn`
    /// in one transaction, inside the account's sync turn.
    func resetMessageData(accountId: String) async throws {
        let pool = AppDatabase.dbPool
        try await withSyncTurns(accountIds: [accountId]) {
            try await pool.write { db in
                try Self.resetMessageDataTxn(db, accountId: accountId)
            }
        }
    }

    /// "Delete All Email Index Data": `localIndexWipeTxn` in one
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
                    try Self.localIndexWipeTxn(db)
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

    /// Authoritative account-scoped reset in one GRDB transaction. Split-out
    /// for a real injected-ABORT test; no FTS/memory/UI side effect belongs here.
    /// First, while the headers are still here, every chat's unsent field words whose thread
    /// has an email are re-stamped (`ChatFieldWords.restampLive`, ADR-IOS-117), so the orphan
    /// pass gives them the full grace for the resync to bring their thread back.
    nonisolated static func resetMessageDataTxn(_ db: Database, accountId: String) throws {
        try ChatFieldWords.restampLive(db: db, now: Date())
        try db.execute(
            sql: "DELETE FROM messageHeader WHERE accountId = ?",
            arguments: [accountId]
        )
        // Stage D (`v70_dropMessageBodyHeaderFK`) removed the body FK, so the
        // content-key prefix delete must remain in this same transaction.
        try db.execute(
            sql: #"DELETE FROM messageBody WHERE id LIKE ? ESCAPE '\'"#,
            arguments: [MessageIdentity.escapeForLike(accountId) + ":%"]
        )
        try db.execute(
            sql: "DELETE FROM messageAICache WHERE key LIKE ?",
            arguments: [accountId + ":%"]
        )
        // Every cursor and bookmark goes with the rows, through the one list both
        // Settings resets share: a tracked folder gets no window listing, so a kept
        // bookmark would leave it empty until the backfill reached the newest mail
        // (ADR-IOS-111).
        try SyncEngine.resetSyncStateTxn(db, accountId: accountId)
    }


    /// The exact GRDB statements "Delete All Email Index Data" runs, in order.
    ///
    /// Named and separated so the boundary of this gesture is a thing that can be
    /// EXECUTED by a test against the real schema, rather than a list buried in a
    /// closure that no test can reach.
    ///
    /// ⚠ **`outboxMessage` IS NOT HERE, and that is the point.** It was, until
    /// 2026-08-05. An Outbox row is a send the user composed that has **never
    /// reached a server**, so it cannot "re-sync automatically from your servers"
    /// — deleting it destroyed the message outright while the confirmation alert
    /// promised the opposite. `Companion/Rules/Active/never-drop-user-intention.md`
    /// states the limit of the lifecycle carve-out outright: it "does not extend
    /// past queue state: Outbox sends, user-authored drafts, bodies, attachments
    /// and FTS content are never dropped under it." An `outboxMessage` row is also
    /// self-contained — it carries its own payload and its own attachment subtree
    /// and references none of the tables below — so keeping it costs no
    /// consistency.
    ///
    /// ⚠ **`pendingCalendarOperation` IS NOT HERE EITHER, for the same reason.**
    /// It was, until 2026-08-05. A queued `.create` carries the user's authored
    /// event — title, time, location, attendees — in its `argumentsJSON` for an
    /// event that exists on **no server**, and a queued `.edit` carries the new
    /// values the user chose. Deleting those destroys authored content that
    /// exists nowhere else, exactly as `outboxMessage` did.
    ///
    /// It also has none of `pendingOperation`'s consistency justification. Its
    /// only foreign key is `accountId → account`, and accounts survive this
    /// transaction (`v8_createPendingCalendarOperation`); its `eventId` and
    /// `calendarId` name SERVER-side resources; and the list below contains no
    /// calendar table at all. So a calendar op addresses nothing this wipe
    /// destroys, and purging it bought exactly zero consistency — the same
    /// asymmetry that made the `outboxMessage` line indefensible.
    ///
    /// `pendingOperation` DOES stay — but **not `.saveDraft`**, and that
    /// exception is the same principle a third time (added 2026-08-05).
    ///
    /// The consistency argument for purging `pendingOperation` is that those rows
    /// address `messageHeader` rows this same transaction destroys, so leaving
    /// them would queue mutations against addresses that no longer exist locally.
    /// **That argument does not reach `.saveDraft`.** A save producer addresses a
    /// `draft` row by `draftId` plus its `instanceEpoch`
    /// (`AccountManager.executeOperation`'s `.saveDraft` arm →
    /// `DraftStore.pushDraftToServer(draftId:expectedInstanceEpoch:…)`); it never
    /// reads the placeholder header, and `draft` is not in this list.
    ///
    /// And it is the ONLY route back. For an authored draft that has never
    /// reached a server, this transaction deletes the placeholder `messageHeader`
    /// that surfaces it in the Drafts folder and the `messageBody` beside it,
    /// while nothing re-downloads it, because it is on no server to re-download
    /// from. The `draft` row survives but no view lists it and no drain pushes
    /// it: purging the producer strands authored content in a table nothing
    /// reads. Keeping the producer means the very next drain pushes the draft to
    /// the server, after which ordinary sync restores the header — i.e. keeping
    /// it is precisely what makes the alert's "re-downloaded from your servers"
    /// true of drafts.
    ///
    /// The filter interpolates `OperationType.saveDraft.rawValue` rather than a
    /// literal so renaming the case cannot silently un-protect the drafts.
    nonisolated static let localIndexWipeStatements: [String] = [
        "DELETE FROM messageHeader",
        "DELETE FROM messageBody",
        "DELETE FROM messageAICache",
        // ⚠ Agent Chat turns are user-authored and exist on NO server, so these
        // two lines are a PERMANENT deletion, not a cache drop. They are kept
        // deliberately — this gesture also wipes `memory.db`
        // (`MemoryIndex.shared.deleteAllThrowing()` in `nukeDatabase`), and `chatHistory`
        // IS that memory store, so excising chat here would leave the two halves
        // of one feature inconsistent; chat turns also carry raw `[Email](N)`
        // references into the `messageHeader` rows this transaction destroys.
        // What was wrong was that the confirmation alert never said so. The alert
        // now names Agent Chat as permanently deleted (`IOS-SETTINGS-001`), which
        // is the consent defect actually at issue. Do not remove these lines
        // without also revisiting `MemoryIndex.deleteAllThrowing()`.
        "DELETE FROM chatTurn",
        "DELETE FROM chatHistory",
        "DELETE FROM pendingOperation WHERE type != '\(OperationType.saveDraft.rawValue)'",
        "DELETE FROM pendingRender",
    ]

    /// Execute the user-visible local-index deletion as one transaction: the
    /// deletes above, then every account's sync state through the one list both
    /// Settings resets share, so each folder's backfill re-walks from the top and
    /// the change bookmarks go with the rows (ADR-IOS-111). First, while the headers are still
    /// here, every chat's unsent field words whose thread has an email are re-stamped
    /// (`ChatFieldWords.restampLive`, ADR-IOS-117), so the orphan pass gives them the full grace
    /// for the resync to bring their thread back.
    nonisolated static func localIndexWipeTxn(_ db: Database) throws {
        try ChatFieldWords.restampLive(db: db, now: Date())
        for sql in localIndexWipeStatements {
            try db.execute(sql: sql)
        }
        try resetSyncStateTxn(db, accountId: nil)
    }
}
