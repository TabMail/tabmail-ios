/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for the 0xdead10cc defense (ADR-IOS-041): GRDB database suspension
/// via `Configuration.observesSuspensionNotifications` + the process-wide
/// `Database.suspendNotification` / `Database.resumeNotification` posts.
///
/// IMPORTANT: the suspend/resume notifications are PROCESS-WIDE — every
/// flagged database in the test host (including the host app's live pools)
/// observes them. The suite is `.serialized` and every test resumes in a
/// `defer` so a failure can never leave the process suspended for other
/// suites.
@Suite("Database Suspension (0xdead10cc defense)", .serialized)
struct DatabaseSuspensionTests {

    private static func postSuspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    private static func postResume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    /// Temp-dir WAL pool configured exactly like the production stores.
    private static func makeSuspendablePool() throws -> (pool: DatabasePool, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("suspension-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        config.observesSuspensionNotifications = true
        let pool = try DatabasePool(
            path: dir.appendingPathComponent("test.sqlite").path,
            configuration: config
        )
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE item (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
        }
        return (pool, dir)
    }

    private static func isSuspensionAbort(_ error: any Error) -> Bool {
        guard let dbError = error as? DatabaseError else { return false }
        return dbError.resultCode == .SQLITE_ABORT || dbError.resultCode == .SQLITE_INTERRUPT
    }

    @Test("Suspended WAL pool: writes abort, reads keep working, resume restores writes")
    func suspendedPoolAbortsWritesAllowsReads() throws {
        let (pool, dir) = try Self.makeSuspendablePool()
        defer {
            Self.postResume()
            try? FileManager.default.removeItem(at: dir)
        }

        try pool.write { db in
            try db.execute(sql: "INSERT INTO item (value) VALUES ('before')")
        }

        Self.postSuspend()

        // Write while suspended → SQLITE_ABORT / SQLITE_INTERRUPT
        do {
            try pool.write { db in
                try db.execute(sql: "INSERT INTO item (value) VALUES ('during')")
            }
            Issue.record("Write succeeded while suspended — suspension is not effective")
        } catch {
            #expect(Self.isSuspensionAbort(error), "Unexpected error type: \(error)")
        }

        // Reads in WAL mode keep working while suspended (GRDB-documented exception)
        let countDuring = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") }
        #expect(countDuring == 1)

        Self.postResume()

        // Writes work again after resume
        try pool.write { db in
            try db.execute(sql: "INSERT INTO item (value) VALUES ('after')")
        }
        let countAfter = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") }
        #expect(countAfter == 2)
    }

    @Test("Transaction straddling suspension aborts and rolls back atomically")
    func straddlingTransactionRollsBack() throws {
        let (pool, dir) = try Self.makeSuspendablePool()
        defer {
            Self.postResume()
            try? FileManager.default.removeItem(at: dir)
        }

        // Suspension arrives mid-transaction (the BGTask-expiration scenario:
        // a maintenance write is in flight when postSuspendImmediately fires).
        do {
            try pool.write { db in
                try db.execute(sql: "INSERT INTO item (value) VALUES ('first')")
                Self.postSuspend()
                // Next statement hits checkForSuspensionViolation → abort + rollback
                try db.execute(sql: "INSERT INTO item (value) VALUES ('second')")
            }
            Issue.record("Transaction completed despite mid-flight suspension")
        } catch {
            #expect(Self.isSuspensionAbort(error), "Unexpected error type: \(error)")
        }

        Self.postResume()

        // The whole transaction rolled back — no partial write survived
        let count = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") }
        #expect(count == 0)
    }

    @Test("Non-WAL DatabaseQueue (BodyAssetStore-style): suspended writes abort, resume restores")
    func suspendedNonWALQueueAbortsWrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("suspension-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            Self.postResume()
            try? FileManager.default.removeItem(at: dir)
        }

        // Mirror BodyAssetStore.manifestQueue(): rollback-journal DatabaseQueue
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.observesSuspensionNotifications = true
        let queue = try DatabaseQueue(
            path: dir.appendingPathComponent("manifest.sqlite").path,
            configuration: config
        )
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE asset (id INTEGER PRIMARY KEY)")
        }

        Self.postSuspend()

        do {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO asset DEFAULT VALUES")
            }
            Issue.record("Write succeeded while suspended")
        } catch {
            #expect(Self.isSuspensionAbort(error), "Unexpected error type: \(error)")
        }

        Self.postResume()

        try queue.write { db in
            try db.execute(sql: "INSERT INTO asset DEFAULT VALUES")
        }
        let count = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM asset") }
        #expect(count == 1)
    }

    @Test("Unflagged database ignores suspension notifications")
    func unflaggedDatabaseIgnoresSuspension() throws {
        // TestDatabase.make() does not set observesSuspensionNotifications —
        // verifies the flag is opt-in and the notification can't break
        // unrelated databases (e.g. the NSE process never posts/observes).
        let db = try TestDatabase.make()
        defer { Self.postResume() }

        Self.postSuspend()

        try db.write { conn in
            try conn.execute(sql: "CREATE TABLE IF NOT EXISTS probe (id INTEGER PRIMARY KEY)")
            try conn.execute(sql: "INSERT INTO probe DEFAULT VALUES")
        }
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM probe") }
        #expect(count == 1)
    }

    @Test("Error.isDatabaseSuspensionAbort: true for a suspended write, false for real failures")
    func suspensionAbortClassification() throws {
        let (pool, dir) = try Self.makeSuspendablePool()
        defer {
            Self.postResume()
            try? FileManager.default.removeItem(at: dir)
        }

        // (1) A write aborted by suspension classifies as a suspension abort.
        Self.postSuspend()
        var suspendErr: (any Error)?
        do {
            try pool.write { db in try db.execute(sql: "INSERT INTO item (value) VALUES ('x')") }
            Issue.record("write should have aborted while suspended")
        } catch {
            suspendErr = error
        }
        #expect(suspendErr?.isDatabaseSuspensionAbort == true)
        Self.postResume()

        // (2) A genuine DatabaseError (constraint violation) is NOT a suspension abort.
        var constraintErr: (any Error)?
        do {
            try pool.write { db in
                try db.execute(sql: "INSERT INTO item (id, value) VALUES (1, 'a')")
                try db.execute(sql: "INSERT INTO item (id, value) VALUES (1, 'b')") // PK clash
            }
            Issue.record("constraint write should have thrown")
        } catch {
            constraintErr = error
        }
        #expect(constraintErr?.isDatabaseSuspensionAbort == false)

        // (3) Non-DatabaseError errors are never suspension aborts.
        #expect((URLError(.notConnectedToInternet) as any Error).isDatabaseSuspensionAbort == false)
        #expect((CancellationError() as any Error).isDatabaseSuspensionAbort == false)
    }

    @Test("NSEBadge.markCounted on a suspended staging connection is a graceful no-op")
    func markCountedSuspendedIsNoOp() throws {
        // Mirrors the fresh staging connection the main app writes through
        // (UnreadCountManager.recordRecentUnreadForNSE → NSEBadge.markCounted).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nsebadge-susp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suiteName = "nse-badge-susp-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer {
            Self.postResume()
            suite.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: dir)
        }
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.observesSuspensionNotifications = true
        let db = try DatabaseQueue(
            path: dir.appendingPathComponent("staging.sqlite").path,
            configuration: config
        )
        let id = NSEBadge.countedId(accountId: "acct", messageId: "uid-1", rfc822MessageId: "<m@x>")

        // While suspended: the markCounted write aborts internally — must be
        // swallowed (no throw, no crash), recording nothing.
        Self.postSuspend()
        NSEBadge.markCounted(db: db, ids: [id])
        Self.postResume()

        // After resume: recording works, and a subsequent NSE delivery for the
        // same message is deduped (no bump) — proving the suspended call was a
        // clean no-op, not a corrupting partial write.
        NSEBadge.markCounted(db: db, ids: [id])
        let badge = NSEBadge.badgeForDelivery(
            db: db, suite: suite, accountId: "acct",
            messageId: "different-uid", rfc822MessageId: "<m@x>")
        #expect(badge == 0)
    }

    @Test("isSuspended flag mirrors the suspend/resume notifications (ADR-IOS-046)")
    func isSuspendedFlagTracksNotifications() {
        // The pollable flag background drain loops read (abandon-on-suspend) is
        // driven by OBSERVING the same process-wide posts GRDB observes — so it is
        // authoritative. Install (idempotent) then drive it via the notifications.
        DatabaseSuspension.installSuspensionStateObserver()
        defer { Self.postResume() }

        Self.postResume() // known baseline
        #expect(DatabaseSuspension.isSuspended == false)

        Self.postSuspend()
        #expect(DatabaseSuspension.isSuspended == true)

        Self.postResume()
        #expect(DatabaseSuspension.isSuspended == false)

        // Re-installing must NOT detach or double-register: still tracks correctly.
        DatabaseSuspension.installSuspensionStateObserver()
        Self.postSuspend()
        #expect(DatabaseSuspension.isSuspended == true)
        Self.postResume()
        #expect(DatabaseSuspension.isSuspended == false)
    }

    @Test("Suspension abort mid-maintenance leaves prior committed data intact and retryable")
    func abortedMaintenanceIsRetryable() throws {
        // Models the SyncEngine.scheduleMaintenanceInBackground pattern: each
        // maintenance step is its own transaction; an aborted step loses only
        // itself, and re-running after resume completes the work (idempotent
        // double work is the accepted contract).
        let (pool, dir) = try Self.makeSuspendablePool()
        defer {
            Self.postResume()
            try? FileManager.default.removeItem(at: dir)
        }

        for i in 0..<5 {
            try pool.write { db in
                try db.execute(sql: "INSERT INTO item (value) VALUES (?)", arguments: ["row\(i)"])
            }
        }

        // "Maintenance": delete rows one transaction at a time; suspension
        // hits after the second step.
        var deleted = 0
        do {
            for _ in 0..<5 {
                if deleted == 2 { Self.postSuspend() }
                try pool.write { db in
                    try db.execute(sql: """
                        DELETE FROM item WHERE id = (SELECT MIN(id) FROM item)
                        """)
                }
                deleted += 1
            }
            Issue.record("Maintenance loop completed despite suspension")
        } catch {
            #expect(Self.isSuspensionAbort(error), "Unexpected error type: \(error)")
            #expect(deleted == 2, "Committed steps before suspension must persist")
        }

        // Next wake: resume + re-run the remaining work to completion.
        Self.postResume()
        let remainingBefore = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") } ?? -1
        #expect(remainingBefore == 3, "Aborted step rolled back; committed steps kept")
        for _ in 0..<remainingBefore {
            try pool.write { db in
                try db.execute(sql: "DELETE FROM item WHERE id = (SELECT MIN(id) FROM item)")
            }
        }
        let remainingAfter = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") }
        #expect(remainingAfter == 0)
    }
}
