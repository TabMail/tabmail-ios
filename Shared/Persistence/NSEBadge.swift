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

    /// App Group key for the `db == nil` fallback dedup map (`[id: epoch]`).
    /// Only used when no staging DB is available (rare degraded state) so a
    /// duplicate delivery still doesn't double-bump. Pruned by retention.
    static let suiteCountedKey = "nse.badgeCountedIds"

    // MARK: - Cross-process dedup key

    /// Composite id for the `nse_badge_counted` dedup table, shared by the NSE
    /// (`badgeForDelivery`) and the main app (`markCounted`).
    ///
    /// Prefers the **normalized RFC 5322 Message-ID** so the key matches across
    /// processes for ALL providers. The provider `messageId` diverges for IMAP:
    /// the NSE keys off the Message-ID carried in the push payload, while
    /// main-app sync may store the UID as `messageId` (see the merge lookup in
    /// `NSEDataBridge.mergeNSEStagingData`). A `messageId`-only key would
    /// therefore silently never match for IMAP / iCloud — the main-app-overlap
    /// double-count would go un-deduped. Falls back to `messageId` only when no
    /// rfc822 id is available (rare; degrades to NSE-vs-NSE dedup, no main-app
    /// match — i.e. current behavior for that message).
    static func countedId(accountId: String, messageId: String, rfc822MessageId: String?) -> String {
        if let raw = rfc822MessageId {
            let normalized = EmailFilter.normalizeMessageId(raw)
            if !normalized.isEmpty { return "\(accountId):rfc:\(normalized)" }
        }
        return "\(accountId):\(messageId)"
    }

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
        messageId: String,
        rfc822MessageId: String? = nil
    ) -> Int {
        let id = countedId(accountId: accountId, messageId: messageId, rfc822MessageId: rfc822MessageId)
        guard let db else {
            // No staging DB — the per-message table isn't reachable. Fall back
            // to a suite-based dedup so a duplicate delivery doesn't double-bump
            // (best-effort; the main-app recount overwrites any drift on wake).
            return suiteIncrementIfFirst(suite: suite, id: id)
        }

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

    // MARK: - Main-app authoritative-count recording

    /// Record that the main app's authoritative recount has ALREADY accounted
    /// for these messages in the badge — so a subsequent (or concurrent) NSE
    /// delivery for the same message does NOT increment on top. This closes the
    /// main-app-overlap double-count (the "+2 for one new email" the user saw):
    /// previously the only guard was a fresh per-message AI lease (Gate 2),
    /// which is too narrow — the main app frequently has a message synced and
    /// counted WITHOUT holding a fresh AI lease on it at the instant the NSE
    /// delivers, so the NSE bumped on top.
    ///
    /// `ids` are composite keys from `countedId(...)` (rfc822-preferred so they
    /// match the NSE side cross-process). INSERT OR IGNORE is order-independent
    /// vs the NSE's own Gate-1 insert: whoever counts first wins; the other
    /// no-ops. Bounded by the caller (recent unread only — see
    /// `SyncConfig.nseBadgeDedupRecentLimit`). Best-effort: on DB error the NSE
    /// may transiently over-count and the next recount corrects it.
    static func markCounted(db: DatabaseQueue, ids: [String]) {
        guard !ids.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        do {
            try db.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS nse_badge_counted (
                        id TEXT PRIMARY KEY,
                        countedAt REAL NOT NULL
                    )
                    """)
                // Prune so the table stays bounded even if the NSE (which also
                // prunes on every delivery) rarely runs on this device.
                try db.execute(
                    sql: "DELETE FROM nse_badge_counted WHERE countedAt < ?",
                    arguments: [now - countedRetentionSeconds]
                )
                for id in ids {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO nse_badge_counted (id, countedAt) VALUES (?, ?)",
                        arguments: [id, now]
                    )
                }
            }
        } catch {
            // Best-effort; swallow. The next authoritative recount re-records,
            // and a transient NSE over-count self-heals on the following recount.
        }
    }

    // MARK: - Suite-based fallback dedup (no staging DB)

    /// Increment only if `id` hasn't been counted recently, tracked in a small
    /// App Group map. Used solely on the `db == nil` path (no per-message table
    /// reachable) so a duplicate delivery still doesn't double-bump.
    private static func suiteIncrementIfFirst(suite: UserDefaults, id: String) -> Int {
        let now = Date().timeIntervalSince1970
        var map = (suite.dictionary(forKey: suiteCountedKey) as? [String: Double]) ?? [:]
        // Prune expired entries to keep the stored map bounded.
        map = map.filter { now - $0.value < countedRetentionSeconds }
        if map[id] != nil {
            suite.set(map, forKey: suiteCountedKey)
            return currentCount(suite: suite)
        }
        map[id] = now
        suite.set(map, forKey: suiteCountedKey)
        return increment(suite: suite)
    }
}
