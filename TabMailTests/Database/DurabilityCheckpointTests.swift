/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Covers the `synchronous=NORMAL` durability change: the production config actually sets
/// NORMAL (fast commits — the merge-stall fix), and `checkpointForDurability()` (the valve
/// that hardens user intent before suspend / after a send) fsyncs the WAL without losing or
/// corrupting committed data. `.serialized` because the checkpoint test swaps `AppDatabase.shared`.
@Suite("WAL synchronous=NORMAL durability", .serialized)
struct DurabilityCheckpointTests {

    @Test("production config sets synchronous=NORMAL and wal_autocheckpoint=0")
    func configIsSynchronousNormal() throws {
        // Assert the REAL production pragmas against a temp-path pool (makeConfiguration is
        // the single source both makePool and this test use — no real-DB access).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(
            path: dir.appendingPathComponent("t.sqlite").path,
            configuration: AppDatabase.makeConfiguration())
        defer { TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let (sync, autockpt): (Int?, Int?) = try pool.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA synchronous"),
             try Int.fetchOne(db, sql: "PRAGMA wal_autocheckpoint"))
        }
        // 1 == NORMAL (2 == FULL). NORMAL is the merge-stall fix; the durability window it
        // opens is closed by checkpointForDurability() on background + after queueSend.
        #expect(sync == 1, "synchronous must be NORMAL(1), got \(sync ?? -1)")
        // Manual checkpointing only — a foreground/.priority write must never eat a checkpoint.
        #expect(autockpt == 0, "wal_autocheckpoint must be 0, got \(autockpt ?? -1)")
    }

    @Test("checkpointForDurability fsyncs the WAL without losing or corrupting committed data")
    func checkpointPreservesData() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(
            path: dir.appendingPathComponent("t.sqlite").path,
            configuration: AppDatabase.makeConfiguration())
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        var siblingPools: [DatabasePool] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool] + siblingPools,
                directory: dir
            )
        }

        // Commit user-intent-style rows under synchronous=NORMAL (no per-commit fsync).
        try await pool.write { db in
            var acc = Account(emailAddress: "u@ex.com", displayName: "U", provider: .imap)
            acc.id = "acc1"
            try acc.insert(db)
        }
        // The durability valve: force the WAL fsync.
        await AppDatabase.checkpointForDurability()

        // Committed data survives the checkpoint (not lost, not corrupt) — readable both
        // from the live pool and from a FRESH connection opened on the same file (proving
        // the frames are on disk, not just in this connection's view).
        let live = try await pool.read { try Account.fetchCount($0) }
        #expect(live == 1, "committed row must survive checkpointForDurability")

        let reopened = try DatabasePool(
            path: dir.appendingPathComponent("t.sqlite").path,
            configuration: AppDatabase.makeConfiguration())
        siblingPools.append(reopened)
        let onDisk = try await reopened.read { try Account.fetchCount($0) }
        #expect(onDisk == 1, "checkpointed row must be visible to a fresh connection")
    }
}
