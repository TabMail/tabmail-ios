/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Guards the invariant the demo-seed / screenshot-seed ordering relies on: the
/// one-time destructive cached-mail resets run once (gated by `UserDefaults`
/// flags) and, once done, re-running them must NOT delete freshly inserted data.
/// In production these run synchronously in `AppDatabase.init` BEFORE any seed,
/// so the seed can never be wiped.
///
/// `.serialized` because the resets read/write process-global
/// `UserDefaults.standard` flags; each test snapshots + restores them. The FTS
/// reset is injected (`resetFTS:`) so tests never touch the real FTS directory.
@Suite("StartupMigrations — one-shot gating", .serialized)
struct StartupMigrationsTests {

    static let flagKeys = [
        "didMigrateHeaderIds_v2",
        "didClearBodiesForAttachmentEncoding_v1",
        "didResetImapDatesForInternalDate_v1",
        "didCleanResetMessageData_v1",
    ]

    static func snapshotFlags() -> [String: Any] {
        var snap: [String: Any] = [:]
        for key in flagKeys where UserDefaults.standard.object(forKey: key) != nil {
            snap[key] = UserDefaults.standard.object(forKey: key)
        }
        return snap
    }

    static func restoreFlags(_ snap: [String: Any]) {
        for key in flagKeys {
            if let value = snap[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// In-memory DB with just the `messageHeader` table — enough for the
    /// `didMigrateHeaderIds_v2` delete. Other branches are skipped via flags.
    static func makeHeaderDB() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()  // in-memory
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE messageHeader (id TEXT)")
        }
        return queue
    }

    /// In-memory DB with every table the clean-reset migration touches.
    static func makeCleanResetDB() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE messageHeader (id TEXT)")
            try db.execute(sql: "CREATE TABLE messageBody (id TEXT)")
            try db.execute(sql: """
                CREATE TABLE folder (
                    id TEXT, backfillComplete INTEGER, oldestSyncedDate DOUBLE,
                    lastKnownUidNext INTEGER, backfillUidCursor INTEGER, backfillPageToken TEXT
                )
                """)
            try db.execute(sql: "CREATE TABLE account (id TEXT, lastFullSyncAt DOUBLE)")
        }
        return queue
    }

    static func count(_ queue: DatabaseQueue, _ table: String) async throws -> Int {
        try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    @Test("All flags set: run() preserves existing data (seed safety)")
    func reRunPreservesData() async throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }

        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }

        let queue = try Self.makeHeaderDB()
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO messageHeader (id) VALUES ('seed-1')")
        }

        var ftsResets = 0
        StartupMigrations.run(queue, resetFTS: { ftsResets += 1 })

        // Seed survives + FTS untouched: this is what makes "seed after the
        // DB-open migrations" safe.
        #expect(try await Self.count(queue, "messageHeader") == 1)
        #expect(ftsResets == 0)
    }

    @Test("First run deletes stale headers, sets flag, and is one-shot")
    func firstRunDeletesThenNoOps() async throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }

        // Only the messageHeader migration is pending.
        UserDefaults.standard.set(false, forKey: "didMigrateHeaderIds_v2")
        UserDefaults.standard.set(true, forKey: "didClearBodiesForAttachmentEncoding_v1")
        UserDefaults.standard.set(true, forKey: "didResetImapDatesForInternalDate_v1")
        UserDefaults.standard.set(true, forKey: "didCleanResetMessageData_v1")

        let queue = try Self.makeHeaderDB()
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO messageHeader (id) VALUES ('stale-1')")
        }

        StartupMigrations.run(queue, resetFTS: {})
        #expect(try await Self.count(queue, "messageHeader") == 0)
        #expect(UserDefaults.standard.bool(forKey: "didMigrateHeaderIds_v2") == true)

        // Data written after the migration ran survives a second run (no-op).
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO messageHeader (id) VALUES ('fresh-1')")
        }
        StartupMigrations.run(queue, resetFTS: {})
        #expect(try await Self.count(queue, "messageHeader") == 1)
    }

    @Test("Clean reset deletes headers + bodies, resets FTS once, then no-ops")
    func cleanResetWipesAndResetsFTSOnce() async throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }

        // Only the clean-reset migration is pending.
        UserDefaults.standard.set(true, forKey: "didMigrateHeaderIds_v2")
        UserDefaults.standard.set(true, forKey: "didClearBodiesForAttachmentEncoding_v1")
        UserDefaults.standard.set(true, forKey: "didResetImapDatesForInternalDate_v1")
        UserDefaults.standard.set(false, forKey: "didCleanResetMessageData_v1")

        let queue = try Self.makeCleanResetDB()
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO messageHeader (id) VALUES ('h1')")
            try db.execute(sql: "INSERT INTO messageBody (id) VALUES ('b1')")
        }

        var ftsResets = 0
        StartupMigrations.run(queue, resetFTS: { ftsResets += 1 })

        #expect(try await Self.count(queue, "messageHeader") == 0)
        #expect(try await Self.count(queue, "messageBody") == 0)
        #expect(ftsResets == 1)  // FTS reset fired in lockstep with the deletes
        #expect(UserDefaults.standard.bool(forKey: "didCleanResetMessageData_v1") == true)

        // Re-run after completion: data preserved AND FTS not reset again.
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO messageHeader (id) VALUES ('fresh')")
        }
        StartupMigrations.run(queue, resetFTS: { ftsResets += 1 })
        #expect(try await Self.count(queue, "messageHeader") == 1)
        #expect(ftsResets == 1)
    }

    // MARK: - Migration-detection (drives the "Updating…" splash gate)

    /// `resetFlagKeys` is the single source of truth that `allResetsComplete`
    /// reads; if it drifts from the keys `run(_:)` actually checks, the splash
    /// gate would mis-fire. Pin it to this test's independently-maintained list.
    @Test("StartupMigrations.resetFlagKeys matches the keys run() gates on")
    func resetFlagKeysMatchCanonicalList() {
        #expect(StartupMigrations.resetFlagKeys == Self.flagKeys)
    }

    @Test("allResetsComplete is true only when every reset flag is set")
    func allResetsCompleteReflectsFlags() {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }

        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }
        #expect(StartupMigrations.allResetsComplete == true)

        // Any single unset flag flips it back to "pending".
        UserDefaults.standard.set(false, forKey: Self.flagKeys[2])
        #expect(StartupMigrations.allResetsComplete == false)
    }

    @Test("hasPendingMigrationWork: unmigrated schema is pending even with all reset flags set")
    func pendingWhenSchemaIncomplete() throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }
        // Rule out the reset path so a true result can only be the schema check.
        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }

        let fresh = try DatabaseQueue()  // in-memory, NO migrations applied
        #expect(try AppDatabase.hasPendingMigrationWork(fresh) == true)
    }

    @Test("hasPendingMigrationWork: fully migrated + all resets done is NOT pending (common launch)")
    func notPendingWhenFullyMigratedAndResetsDone() throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }
        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }

        let migrated = try TestDatabase.make()  // runs the full migration chain
        #expect(try AppDatabase.hasPendingMigrationWork(migrated) == false)
    }

    @Test("hasPendingMigrationWork: fully migrated but a reset still pending IS pending")
    func pendingWhenResetOutstanding() throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }
        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }
        // One destructive reset hasn't run yet (e.g. a newly-shipped reset on an
        // existing install) — that's slow on a populated mailbox, so it counts.
        UserDefaults.standard.set(false, forKey: "didCleanResetMessageData_v1")

        let migrated = try TestDatabase.make()
        #expect(try AppDatabase.hasPendingMigrationWork(migrated) == true)
    }
}
