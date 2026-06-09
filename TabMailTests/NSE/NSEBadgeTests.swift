/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Regression tests for the NSE badge double-increment fix.
///
/// Two double-count mechanisms existed:
///   1. Duplicate push delivery — every NSE delivery path bumped the shared
///      counter unconditionally, so a redelivered push for the same message
///      added +1 again (via the staging-cache hit path or a full re-run).
///   2. Main-app overlap — a background-woken main app synced the email and
///      wrote the authoritative count to the mirror; the NSE then processed
///      the visible push for the same email and incremented on top.
///
/// `NSEBadge.badgeForDelivery` closes both: per-message idempotency arbitrated
/// by an atomic INSERT OR IGNORE into `nse_badge_counted`, and a skip when the
/// main app holds a fresh `AIOwnershipLease` on the message.
@Suite("NSE badge idempotency gates")
struct NSEBadgeTests {

    // MARK: - Helpers

    /// Staging DB mirroring the production `nse_processed_message` schema
    /// (same shape as NSEStagingMergeBugfixTests.makeStagingDB). NSEBadge
    /// creates its own `nse_badge_counted` table lazily.
    private func makeStagingDB() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_processed_message (
                    id TEXT PRIMARY KEY,
                    accountId TEXT NOT NULL, accountEmail TEXT NOT NULL,
                    provider TEXT NOT NULL, messageId TEXT NOT NULL,
                    rfc822MessageId TEXT, threadId TEXT, folderPath TEXT,
                    subject TEXT DEFAULT '', senderName TEXT DEFAULT '', senderEmail TEXT DEFAULT '',
                    snippet TEXT DEFAULT '', date REAL, isRead INTEGER DEFAULT 0,
                    summaryBlurb TEXT, summaryTodos TEXT, actionTag TEXT,
                    reminderDate TEXT, reminderTime TEXT, reminderContent TEXT,
                    processedAt REAL NOT NULL, historyId TEXT,
                    aiCompleted INTEGER DEFAULT 0, notified INTEGER DEFAULT 0,
                    htmlContent TEXT, textContent TEXT,
                    attachmentsJSON TEXT, icsText TEXT,
                    hasUnresolvedCIDs INTEGER DEFAULT 0,
                    toRaw TEXT DEFAULT '', ccRaw TEXT DEFAULT '', bccRaw TEXT DEFAULT '',
                    replyToRaw TEXT, inReplyTo TEXT, referencesJSON TEXT,
                    isFlagged INTEGER DEFAULT 0, hasAttachments INTEGER DEFAULT 0,
                    providerLabelsJSON TEXT,
                    isReplied INTEGER DEFAULT 0, isForwarded INTEGER DEFAULT 0,
                    aiOwner TEXT, aiHeartbeatMs INTEGER,
                    populated INTEGER NOT NULL DEFAULT 0
                )
                """)
        }
        return db
    }

    /// Fresh, isolated UserDefaults domain per test (no `.standard`/app-group
    /// bleed across parallel suites). Callers must `defer { wipe(suite:) }`.
    private func makeSuite() -> (suite: UserDefaults, name: String) {
        let name = "nse-badge-tests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return (suite, name)
    }

    private func wipe(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }

    private let accountId = "test-account"

    // MARK: - Gate 1: per-message idempotency

    @Test("First delivery increments; distinct messages count independently")
    func firstDeliveryIncrements() throws {
        let db = try makeStagingDB()
        let (suite, name) = makeSuite()
        defer { wipe(name) }

        #expect(NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a") == 1)
        #expect(NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-b") == 2)
        #expect(NSEBadge.currentCount(suite: suite) == 2)
    }

    @Test("Duplicate delivery of the same message does not double-count")
    func duplicateDeliveryDoesNotDoubleCount() throws {
        let db = try makeStagingDB()
        let (suite, name) = makeSuite()
        defer { wipe(name) }

        let first = NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a")
        let second = NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a")
        #expect(first == 1)
        #expect(second == 1)
        #expect(NSEBadge.currentCount(suite: suite) == 1)
    }

    @Test("Idempotency survives staging-row deletion (main-app merge)")
    func idempotencySurvivesMergeDeletion() throws {
        let db = try makeStagingDB()
        let (suite, name) = makeSuite()
        defer { wipe(name) }

        _ = NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a")
        // Simulate mergeNSEStagingData deleting the processed staging row.
        try db.write { db in
            try db.execute(sql: "DELETE FROM nse_processed_message")
        }
        let again = NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a")
        #expect(again == 1)
        #expect(NSEBadge.currentCount(suite: suite) == 1)
    }

    @Test("Same messageId on different accounts counts separately")
    func sameMessageIdDifferentAccounts() throws {
        let db = try makeStagingDB()
        let (suite, name) = makeSuite()
        defer { wipe(name) }

        #expect(NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: "acct-1", messageId: "msg-a") == 1)
        #expect(NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: "acct-2", messageId: "msg-a") == 2)
    }

    // MARK: - Gate 2: main-app overlap

    @Test("Fresh main-app AI lease skips the increment")
    func mainAppFreshLeaseSkipsIncrement() throws {
        let db = try makeStagingDB()
        let (suite, name) = makeSuite()
        defer { wipe(name) }

        // Mirror written by the main app's recount — already includes the
        // message being delivered.
        suite.set(5, forKey: NSEBadge.badgeCountKey)
        #expect(AIOwnershipLease.tryClaim(db: db, accountId: accountId, messageId: "msg-a", owner: .mainApp))

        let badge = NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a")
        #expect(badge == 5)
        #expect(NSEBadge.currentCount(suite: suite) == 5)
    }

    @Test("Main-app-owned message stays counted after lease release")
    func mainAppOwnedStaysCountedAfterRelease() throws {
        let db = try makeStagingDB()
        let (suite, name) = makeSuite()
        defer { wipe(name) }

        suite.set(5, forKey: NSEBadge.badgeCountKey)
        #expect(AIOwnershipLease.tryClaim(db: db, accountId: accountId, messageId: "msg-a", owner: .mainApp))
        _ = NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a")
        AIOwnershipLease.release(db: db, accountId: accountId, messageId: "msg-a", owner: .mainApp)

        // Duplicate push after the main app went back to sleep: still no bump.
        let badge = NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a")
        #expect(badge == 5)
        #expect(NSEBadge.currentCount(suite: suite) == 5)
    }

    @Test("Stale main-app lease does not suppress the increment")
    func mainAppStaleLeaseStillIncrements() throws {
        let db = try makeStagingDB()
        let (suite, name) = makeSuite()
        defer { wipe(name) }

        // Claim, then backdate the heartbeat past staleness — the holder died.
        #expect(AIOwnershipLease.tryClaim(db: db, accountId: accountId, messageId: "msg-a", owner: .mainApp))
        let staleHb = Int64(Date().timeIntervalSince1970 * 1000) - (AIOwnershipLease.staleMs + 1000)
        try db.write { db in
            try db.execute(sql: "UPDATE nse_processed_message SET aiHeartbeatMs = ?", arguments: [staleHb])
        }

        #expect(NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a") == 1)
    }

    @Test("Fresh NSE-owned lease (concurrent NSE) does not suppress — gate 1 arbitrates")
    func nseOwnedLeaseStillCounts() throws {
        let db = try makeStagingDB()
        let (suite, name) = makeSuite()
        defer { wipe(name) }

        #expect(AIOwnershipLease.tryClaim(db: db, accountId: accountId, messageId: "msg-a", owner: .nse))
        // First concurrent delivery wins the counted insert and increments…
        #expect(NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a") == 1)
        // …the second reads the current value without bumping.
        #expect(NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a") == 1)
    }

    // MARK: - Degradation + primitives

    @Test("nil staging DB falls back to legacy unconditional increment")
    func nilDBFallsBackToIncrement() {
        let (suite, name) = makeSuite()
        defer { wipe(name) }

        #expect(NSEBadge.badgeForDelivery(db: nil, suite: suite, accountId: accountId, messageId: "msg-a") == 1)
        // Legacy behavior: no arbiter, so a duplicate does bump (accepted —
        // main-app recount overwrites the drift on next wake).
        #expect(NSEBadge.badgeForDelivery(db: nil, suite: suite, accountId: accountId, messageId: "msg-a") == 2)
    }

    @Test("Decrement floors at zero")
    func decrementFloorsAtZero() {
        let (suite, name) = makeSuite()
        defer { wipe(name) }

        _ = NSEBadge.increment(suite: suite)
        #expect(NSEBadge.decrement(by: 3, suite: suite) == 0)
    }

    @Test("DB error on the dedup table fails open to the legacy increment")
    func dbErrorFailsOpenToIncrement() throws {
        let db = try makeStagingDB()
        let (suite, name) = makeSuite()
        defer { wipe(name) }

        // A VIEW shadowing the dedup table makes CREATE TABLE IF NOT EXISTS
        // throw — tryMarkCounted reports a DB error (nil), so the delivery
        // falls back to the unconditional increment (documented best-effort).
        try db.write { db in
            try db.execute(sql: "CREATE VIEW nse_badge_counted AS SELECT '' AS id, 0.0 AS countedAt")
        }
        #expect(NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a") == 1)
        #expect(NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a") == 2)
    }

    @Test("Counted rows older than retention are pruned and may count again")
    func retentionPruneAllowsRecount() throws {
        let db = try makeStagingDB()
        let (suite, name) = makeSuite()
        defer { wipe(name) }

        #expect(NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a") == 1)
        // Backdate the dedup row beyond retention (dynamic relative to now).
        let expired = Date().timeIntervalSince1970 - NSEBadge.countedRetentionSeconds - 60
        try db.write { db in
            try db.execute(sql: "UPDATE nse_badge_counted SET countedAt = ?", arguments: [expired])
        }
        // The prune runs inside the next delivery's write — the expired row is
        // gone, so the same id wins the insert again.
        #expect(NSEBadge.badgeForDelivery(db: db, suite: suite, accountId: accountId, messageId: "msg-a") == 2)
    }
}
