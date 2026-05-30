/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Cross-process lease for AI processing of a single push/message.
///
/// The NSE and the main-app AI queue both compute summary/action and either
/// would happily run the LLM calls. Without coordination every push produces
/// two identical backend calls. Coordination uses columns on the shared
/// `nse_processed_message` staging table in the App Group container:
///
///   aiOwner        TEXT  — "nse" | "mainApp" | NULL
///   aiHeartbeatMs  INTEGER — wall-clock ms when the holder last beat
///
/// Claim is atomic: `UPDATE ... WHERE aiOwner IS NULL OR aiOwner = :me OR
/// (now - heartbeat) > staleMs`. Inspect `changes()` to confirm this process
/// won the race. The winner refreshes `aiHeartbeatMs` every
/// `heartbeatIntervalMs` while working; a gap > `staleMs` tells the other
/// side the holder died and it may take over.
///
/// The staging table itself is created by the main app
/// (`AppDatabase.createNSEStagingDBIfNeeded`) with the `aiOwner` and
/// `aiHeartbeatMs` columns — NSE only reads/writes.
enum AIOwnershipLease {
    /// Possible lease holders. Raw values are the literal strings stored in
    /// `aiOwner` — keep stable across releases.
    enum Owner: String, Sendable {
        case nse = "nse"
        case mainApp = "mainApp"
    }

    /// Composite id used in `nse_processed_message.id` — must match the format
    /// written by `NSEStagingDB.persistProcessedMessage`.
    private static func compositeId(accountId: String, messageId: String) -> String {
        "\(accountId):\(messageId)"
    }

    /// Ensure a staging row exists for `(accountId, messageId)` before writing
    /// ownership. NSE fills the rest in step 5/7 later; we just need a row the
    /// UPDATE can target. INSERT OR IGNORE so we never clobber a populated
    /// row (if main app already saw an earlier NSE run or vice versa).
    static func ensureRow(db: DatabaseWriter, accountId: String, messageId: String) {
        let id = compositeId(accountId: accountId, messageId: messageId)
        do {
            try db.write { db in
                try db.execute(sql: """
                    INSERT OR IGNORE INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, processedAt)
                    VALUES (?, ?, '', '', ?, ?)
                    """, arguments: [id, accountId, messageId, Date().timeIntervalSince1970])
            }
        } catch {
            // Log via the caller's logger — this module has no provider.
            // Upstream log messages already cover the surrounding step.
            _ = error
        }
    }

    /// Try to atomically claim the lease. Returns `true` iff this call won.
    /// The WHERE clause accepts:
    ///   1. `aiOwner IS NULL` — unclaimed.
    ///   2. `aiOwner = :me` — already mine, idempotent re-claim after retry.
    ///   3. `now - heartbeat > staleMs` — prior owner died, take over.
    /// Fresh foreign heartbeats leave the row untouched; the caller falls
    /// into the poll-or-skip path.
    static func tryClaim(
        db: DatabaseWriter,
        accountId: String, messageId: String,
        owner: Owner,
        staleMs: Int64 = staleMs
    ) -> Bool {
        ensureRow(db: db, accountId: accountId, messageId: messageId)
        let id = compositeId(accountId: accountId, messageId: messageId)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            return try db.write { db in
                try db.execute(sql: """
                    UPDATE nse_processed_message
                    SET aiOwner = ?, aiHeartbeatMs = ?
                    WHERE id = ?
                      AND (aiOwner IS NULL
                           OR aiOwner = ?
                           OR (? - COALESCE(aiHeartbeatMs, 0)) > ?)
                    """, arguments: [
                        owner.rawValue, nowMs,
                        id,
                        owner.rawValue,
                        nowMs, staleMs
                    ])
                return db.changesCount > 0
            }
        } catch {
            return false
        }
    }

    /// Refresh the heartbeat while still working. Conditional on still owning
    /// the lease — guards against clobbering another process that took over
    /// after a stale gap (our Task.sleep may have been delayed past staleMs).
    static func refresh(
        db: DatabaseWriter,
        accountId: String, messageId: String,
        owner: Owner
    ) {
        let id = compositeId(accountId: accountId, messageId: messageId)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try? db.write { db in
            try db.execute(sql: """
                UPDATE nse_processed_message
                SET aiHeartbeatMs = ?
                WHERE id = ? AND aiOwner = ?
                """, arguments: [nowMs, id, owner.rawValue])
        }
    }

    /// Release the lease after work completes (or fails). Conditional on still
    /// owning so a stale takeover elsewhere isn't wiped by our teardown.
    static func release(
        db: DatabaseWriter,
        accountId: String, messageId: String,
        owner: Owner
    ) {
        let id = compositeId(accountId: accountId, messageId: messageId)
        try? db.write { db in
            try db.execute(sql: """
                UPDATE nse_processed_message
                SET aiOwner = NULL, aiHeartbeatMs = NULL
                WHERE id = ? AND aiOwner = ?
                """, arguments: [id, owner.rawValue])
        }
    }

    /// Current ownership state: `(owner, heartbeatMs)` or `nil` if no row / no
    /// owner. Callers inspect this to decide: wait (fresh foreign claim), take
    /// over (stale foreign claim), or claim fresh (no owner).
    static func state(
        db: DatabaseReader,
        accountId: String, messageId: String
    ) -> (owner: Owner, heartbeatMs: Int64)? {
        let id = compositeId(accountId: accountId, messageId: messageId)
        return try? db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT aiOwner, aiHeartbeatMs
                FROM nse_processed_message WHERE id = ?
                """, arguments: [id]) else { return nil }
            guard let ownerStr: String = row["aiOwner"],
                  let owner = Owner(rawValue: ownerStr),
                  let hb: Int64 = row["aiHeartbeatMs"] else { return nil }
            return (owner, hb)
        }
    }

    /// True when `heartbeatMs` is recent enough to trust. Used by both sides
    /// to decide whether an observed foreign claim should be respected or
    /// treated as abandoned.
    static func isFresh(heartbeatMs: Int64, staleMs: Int64 = staleMs) -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return (nowMs - heartbeatMs) <= staleMs
    }

    /// Poll predicate: has the other side finished AI? Main app uses this
    /// while NSE holds a fresh claim — once `summaryBlurb` lands (or
    /// `aiCompleted=1`), main app skips its own LLM call and trusts the
    /// subsequent merge (`NSEDataBridge.mergeNSEStagingData`) to bring it in.
    static func hasResult(
        db: DatabaseReader,
        accountId: String, messageId: String
    ) -> Bool {
        let id = compositeId(accountId: accountId, messageId: messageId)
        return (try? db.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT (aiCompleted = 1
                        OR (summaryBlurb IS NOT NULL AND summaryBlurb != ''))
                FROM nse_processed_message WHERE id = ?
                """, arguments: [id])
        }) ?? false
    }

    // MARK: - Lease tuning
    //
    // Numbers tuned around the NSE's ~30 s hard budget. `staleMs` must exceed
    // `heartbeatIntervalMs` by enough margin that scheduling jitter on either
    // side doesn't trigger a spurious takeover. `pollMaxMs` caps main-app
    // waiting at just under NSE's budget so a stuck NSE can't deadlock the
    // main-app AI queue.
    static let heartbeatIntervalMs: UInt64 = 1000
    static let staleMs: Int64 = 4000
    static let mainAppPollIntervalMs: UInt64 = 1000
    static let mainAppPollMaxMs: UInt64 = 28000
}
