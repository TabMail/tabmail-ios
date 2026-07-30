/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// Measures the REAL latency of a PRIORITY (foreground/UI) DB write — the
/// stand-in for the unread-badge flag flip / NSE-merge write — while a
/// BACKGROUND batch-write stream (the stand-in for a backfill `insertBackfillBatch`)
/// is running. This is the empirical backstop for the "badge/render lags behind
/// backfill" diagnosis and the chunking fix.
///
/// The central fact under test: SQLite serializes writers and CANNOT preempt an
/// in-flight transaction. So a priority write's worst-case latency tracks the
/// size of whatever background transaction is in flight when it arrives — NOT the
/// total amount of background work. Therefore the lever is CHUNKING the big
/// background batch (smaller in-flight txn), not (only) queue ordering: a priority
/// write already lands right after the in-flight batch because the background loop
/// awaits each batch (only one is ever submitted at a time), so nothing piles up
/// ahead of it in GRDB's writer FIFO.
///
/// Prints timings so we have a concrete before/after artifact.
@Suite("Prioritized write contention", .serialized)
@MainActor
struct PrioritizedWriteContentionTests {

    // MARK: - Harness (mirrors NSEGradualMergeTests.makeAppDatabase)

    private func makeAppDatabase() throws -> (dir: URL, pool: DatabasePool, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        config.maximumReaderCount = 64
        let pool = try DatabasePool(path: dir.appendingPathComponent("tabmail.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "user@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
        }
        return (dir, pool, previous)
    }

    private func restore(_ pool: DatabasePool, _ previous: AppDatabase?, _ dir: URL) {
        AppDatabase.shared.withLock { $0 = previous }
        TestDatabaseTeardown.retire(pool: pool, directory: dir)
    }

    // MARK: - Probes

    /// One BACKGROUND batch: insert `count` throwaway folders in ONE transaction —
    /// a stand-in for a backfill batch insert (many rows, one write, holds the
    /// single writer for the whole batch).
    private func backgroundBatch(_ count: Int, tag: String) async {
        try? await AppDatabase.backgroundPool.write { db in
            for i in 0..<count {
                try Folder(name: "bg", path: "bg-\(tag)-\(i)", role: .archive, accountId: "acc1").insert(db)
            }
        }
    }

    /// One tiny PRIORITY write (stand-in for the badge/merge flag flip). Returns
    /// its end-to-end latency in milliseconds (enqueue → committed).
    private func priorityWriteLatencyMs() async -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try? await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE account SET displayName = displayName WHERE id = 'acc1'")
        }
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    /// Run a background stream of `batches` × `rowsPerBatch`, and DURING it fire
    /// `probes` priority writes; return their max + avg latency (ms).
    private func measure(rowsPerBatch: Int, batches: Int, probes: Int) async -> (maxMs: Double, avgMs: Double) {
        let stream = Task {
            for b in 0..<batches {
                await backgroundBatch(rowsPerBatch, tag: "\(rowsPerBatch)x\(b)")
                if Task.isCancelled { return }
            }
        }
        // Let the stream get going so probes land mid-contention.
        try? await Task.sleep(for: .milliseconds(8))
        var latencies: [Double] = []
        for _ in 0..<probes {
            latencies.append(await priorityWriteLatencyMs())
            try? await Task.sleep(for: .milliseconds(3))
        }
        await stream.value
        let maxMs = latencies.max() ?? 0
        let avgMs = latencies.reduce(0, +) / Double(max(1, latencies.count))
        return (maxMs, avgMs)
    }

    // MARK: - Tests

    @Test("Priority-write latency tracks the IN-FLIGHT background batch size — chunking is the lever")
    func chunkingReducesPriorityLatency() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        defer { restore(pool, previous, dir) }

        let totalRows = 8000
        // BIG: a few huge batches (today's unchunked insertBackfillBatch shape).
        let big = await measure(rowsPerBatch: totalRows / 4, batches: 4, probes: 12)
        // CHUNKED: many small batches, SAME total rows.
        let chunked = await measure(rowsPerBatch: 50, batches: totalRows / 50, probes: 12)

        let r = { (x: Double) in Int(x.rounded()) }
        print("[ContentionTest] BIG batch (\(totalRows / 4) rows/txn): priority maxMs=\(r(big.maxMs)) avgMs=\(r(big.avgMs))")
        print("[ContentionTest] CHUNKED  (50 rows/txn):          priority maxMs=\(r(chunked.maxMs)) avgMs=\(r(chunked.avgMs))")
        print("[ContentionTest] max-latency improvement: \(r(big.maxMs)) → \(r(chunked.maxMs)) ms (\(big.maxMs > 0 ? r(big.maxMs / max(chunked.maxMs, 0.001)) : 0)×)")

        // A priority write can't preempt the in-flight big batch, so its worst-case
        // latency is much higher with big batches than with chunked ones.
        #expect(chunked.maxMs < big.maxMs)
    }
}
