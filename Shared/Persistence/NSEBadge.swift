/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Shared-counter badge logic for NSE-delivered notifications.
///
/// The NSE cannot read main GRDB (app-private container), so it maintains a
/// best-effort incremental counter in the App Group suite (`badgeCountKey`).
/// The main app's `UnreadCountManager.updateBadge()` overwrites the counter
/// with the authoritative inbox unread count on every recount — the counter
/// only has to stay reasonable *between* main-app wakes.
///
/// Historically the NSE incremented unconditionally on every delivery, which
/// double-counted a single email in two ways:
///   1. Duplicate push delivery (APNs/Pub/Sub are at-least-once): the second
///      NSE run hit the staging-cache path and bumped again.
///   2. Main-app overlap: a background-woken main app synced the email and
///      wrote the authoritative count (already including it) to the mirror,
///      then the NSE processed the visible push for the same email and
///      incremented on top.
///
/// `badgeForDelivery` closes both:
///   - Gate 1 (idempotency): each `(accountId, messageId)` bumps the counter
///     at most once, arbitrated by an atomic `INSERT OR IGNORE` into the
///     `nse_badge_counted` table in the shared staging DB. The table is
///     NSE-badge-owned (created lazily here, read by nobody else) and
///     deliberately separate from `nse_processed_message`, whose rows are
///     REPLACEd by re-runs and deleted by the main-app merge.
///   - Gate 2 (main-app overlap): when the main app holds a fresh AI lease on
///     the message (`AIOwnershipLease`), it is awake, has synced the message,
///     and will set the badge authoritatively — the NSE delivers the current
///     counter value without bumping.
///
/// All failure paths degrade to the legacy unconditional increment: the
/// counter is documented best-effort drift that the next main-app recount
/// overwrites, so failing open (possible transient overcount) is preferred
/// over failing closed (missing badge movement entirely).
enum NSEBadge {
    /// App Group key for the shared counter. NSE increments; the main app's
    /// `UnreadCountManager.updateBadge()` overwrites with the real count.
    static let badgeCountKey = "nse.unreadBadge"

    /// Retention for `nse_badge_counted` dedup rows. Must comfortably exceed
    /// the longest plausible duplicate-delivery window (APNs redelivery,
    /// push-worker retry ladder — minutes) while keeping the table bounded.
    static let countedRetentionSeconds: TimeInterval = 7 * 86400

    // MARK: - Counter primitives

    static func currentCount(suite: UserDefaults) -> Int {
        suite.integer(forKey: badgeCountKey)
    }

    static func increment(suite: UserDefaults) -> Int {
        let next = suite.integer(forKey: badgeCountKey) + 1
        suite.set(next, forKey: badgeCountKey)
        return next
    }

    static func decrement(by count: Int, suite: UserDefaults) -> Int {
        let next = max(0, suite.integer(forKey: badgeCountKey) - count)
        suite.set(next, forKey: badgeCountKey)
        return next
    }

    // MARK: - Delivery decision

    /// Badge value to attach to an NSE notification for `(accountId, messageId)`.
    /// Increments the shared counter only the first time a message is counted
    /// and only when the main app isn't actively processing it.
    static func badgeForDelivery(
        db: DatabaseQueue?,
        suite: UserDefaults,
        accountId: String,
        messageId: String
    ) -> Int {
        guard let db else {
            // No staging DB — no arbiter available. Legacy behavior.
            return increment(suite: suite)
        }
        let id = "\(accountId):\(messageId)"

        // Gate 2 — main app is awake and owns this message: it has synced the
        // header and its recount sets the badge (and rewrites this counter)
        // authoritatively. Mark counted so a later duplicate push (after the
        // lease is released) doesn't bump either, and deliver the current
        // value unchanged.
        if let lease = AIOwnershipLease.state(db: db, accountId: accountId, messageId: messageId),
           lease.owner == .mainApp,
           AIOwnershipLease.isFresh(heartbeatMs: lease.heartbeatMs) {
            _ = tryMarkCounted(db: db, id: id)
            return currentCount(suite: suite)
        }

        // Gate 1 — atomic first-counter-wins. INSERT OR IGNORE is the
        // cross-process arbiter: exactly one delivery of this message wins
        // the insert and increments; every other delivery (duplicate push,
        // concurrent NSE) reads the current value.
        switch tryMarkCounted(db: db, id: id) {
        case true:
            return increment(suite: suite)
        case false:
            return currentCount(suite: suite)
        default:
            // DB error — fail open to the legacy increment (best-effort
            // counter; next main-app recount overwrites any drift).
            return increment(suite: suite)
        }
    }

    /// Atomically record that `id` has been accounted for in the badge
    /// counter. Returns `true` if this call won (row inserted), `false` if
    /// the message was already counted, `nil` on DB error.
    private static func tryMarkCounted(db: DatabaseQueue, id: String) -> Bool? {
        let now = Date().timeIntervalSince1970
        do {
            return try db.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS nse_badge_counted (
                        id TEXT PRIMARY KEY,
                        countedAt REAL NOT NULL
                    )
                    """)
                try db.execute(
                    sql: "DELETE FROM nse_badge_counted WHERE countedAt < ?",
                    arguments: [now - countedRetentionSeconds]
                )
                // Must be the last statement — `changesCount` reflects it.
                try db.execute(
                    sql: "INSERT OR IGNORE INTO nse_badge_counted (id, countedAt) VALUES (?, ?)",
                    arguments: [id, now]
                )
                return db.changesCount > 0
            }
        } catch {
            return nil
        }
    }
}
