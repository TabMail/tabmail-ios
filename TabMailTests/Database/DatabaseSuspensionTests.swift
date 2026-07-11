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

    @Test("Non-WAL reads are NOT suspension-exempt (WAL reads are) — why BodyAssetStore maintenance is foreground-only (ADR-IOS-046)")
    func nonWALReadsAreNotSuspensionExempt() throws {
        // The BodyAssetStore manifest is a NON-WAL App-Group `DatabaseQueue` (it opens
        // with a default `Configuration()`, no WAL — like below). A WAL read keeps
        // working while suspended (`suspendedPoolAbortsWritesAllowsReads`), but a
        // non-WAL read is interrupted. At REAL process suspension that read can be
        // blocked in `pread` and unable to abort in time, so its held SQLite lock
        // becomes a `0xdead10cc` kill. THAT asymmetry is why
        // `SyncEngine.runBodyAssetMaintenance` gates on `isAppActive` (foreground-only)
        // while `runWALMaintenance` does not. If this ever starts allowing reads while
        // suspended (e.g. the manifest is moved to WAL), revisit that gate.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("suspension-nonwal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            Self.postResume()
            try? FileManager.default.removeItem(at: dir)
        }

        // Default Configuration() == rollback journal (NON-WAL), matching BodyAssetStore.
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.observesSuspensionNotifications = true
        let queue = try DatabaseQueue(
            path: dir.appendingPathComponent("manifest.sqlite").path,
            configuration: config
        )
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE bodyAsset (id INTEGER PRIMARY KEY, sizeBytes INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO bodyAsset (sizeBytes) VALUES (10), (20), (30)")
        }

        // Active baseline: the usedBytes-style SUM read works.
        Self.postResume()
        let before = try queue.read {
            try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM bodyAsset")
        }
        #expect(before == 60)

        // Suspended: the SAME non-WAL read now throws (the WAL pool allows it — this is
        // the whole point). This read is the one that holds the lock at the kill site.
        Self.postSuspend()
        do {
            _ = try queue.read {
                try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM bodyAsset")
            }
            Issue.record("Non-WAL read succeeded while suspended — it should be interrupted; running it backgrounded is the 0xdead10cc liability")
        } catch {
            #expect(Self.isSuspensionAbort(error), "Unexpected error type: \(error)")
        }

        // Resume restores reads.
        Self.postResume()
        let after = try queue.read {
            try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM bodyAsset")
        }
        #expect(after == 60)
    }

    // MARK: - GAP4: live suspension through the REAL AccountManager.move() action path

    /// Schema-correct harness — mirrors `CoordinatedToolActionTests.makeTestDB()`
    /// (swaps `AppDatabase.shared` so `AccountManager.shared.move()` operates on
    /// this pool, with an account + inbox/archive folder pre-seeded) but ADDITIONALLY
    /// flags `observesSuspensionNotifications = true`. A SEPARATE harness variant
    /// (not a change to `CoordinatedToolActionTests`/`AccountManagerQueueDrainTests`/
    /// `NotificationActionRouterTests`'s own `makeTestDB()`) so their tests — which
    /// never expect a process-wide suspend/resume post — are completely untouched.
    private func makeSuspendableAccountDB() throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.observesSuspensionNotifications = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let i = inbox; try i.insert(db)
            let a = archive; try a.insert(db)
        }
        return (pool, inbox, archive, dir, previous)
    }

    /// See `CoordinatedToolActionTests.restoreTestDB`: production paths driven
    /// here (`AccountManager.move`'s unstructured recount/drain `Task`s) can
    /// run AFTER this returns, so a test with no prior `AppDatabase` leaves the
    /// test DB alive rather than let `AppDatabase.rawPool`'s force-unwrap crash
    /// the process on a later unrelated access.
    private func restoreAccountDB(previous: AppDatabase?, dir: URL) {
        if previous != nil {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("Live suspension through AccountManager.move(): a suspend posted BEFORE the call aborts the whole write (row move + PendingOperation insert, one transaction) atomically — no PendingOperation, folderId unchanged; after resume the SAME move() call succeeds")
    func moveAbortsAtomicallyDuringSuspensionThenSucceedsAfterResume() async throws {
        let (pool, inbox, archive, dir, previous) = try makeSuspendableAccountDB()
        // Suspend/resume must be balanced even on test failure: the defer's
        // postResume() runs regardless of how the test exits. Idempotent —
        // safe even if the explicit mid-test postResume() below already ran.
        defer {
            Self.postResume()
            restoreAccountDB(previous: previous, dir: dir)
        }

        var newHeader = MessageHeader(
            messageId: "m-suspend-move", subject: "Subj", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: inbox.id, accountId: inbox.accountId, folderPath: inbox.path,
            isInInbox: true
        )
        newHeader.headerComplete = true
        let header = newHeader
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        Self.postSuspend()

        // AccountManager.move() wraps its `dbPool.write` in do/catch and never
        // rethrows (AccountManagerActions.swift: "print(...); affectedFolderIds
        // = []") — verified by reading the function before writing this test.
        // A suspension abort must therefore be a silent no-op here, not a
        // crash/hang. move()'s own reads (resolveHeadersForAction,
        // ensureDurable) run first — WAL reads are suspension-EXEMPT (see
        // `suspendedPoolAbortsWritesAllowsReads` above), so they succeed and
        // the function proceeds to the write, which is where the abort hits.
        await AccountManager.shared.move([header], to: archive.path)

        let duringOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(duringOps.isEmpty, "the write (row move + PendingOperation insert, same transaction) must have rolled back atomically — nothing committed")
        let duringHeader = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(duringHeader?.folderId == inbox.id, "folderId must be UNCHANGED — the transaction never committed")
        #expect(duringHeader?.folderPath == inbox.path)

        Self.postResume()

        // The SAME move() call, retried after resume, succeeds normally.
        await AccountManager.shared.move([header], to: archive.path)

        let afterOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(afterOps.count == 1)
        guard afterOps.count == 1 else { return }
        #expect(afterOps[0].type == .move)
        #expect(afterOps[0].destinationPath == archive.path)

        let afterHeader = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(afterHeader?.folderId == archive.id, "after resume, the SAME move() call lands the row in Archive")
        #expect(afterHeader?.folderPath == archive.path)
    }
}
