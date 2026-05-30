/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for `BackfillMemoryEmbeddingQueue` (v3 per-turn). Covers repopulate,
/// process-batch, epoch-stamp race, missing/empty turns.
///
/// EmbeddingService is a singleton initialized from bundle resources; on a dev
/// machine without the tokenizer.json + mlmodelc, `EmbeddingService.shared` is
/// nil and the queue short-circuits gracefully. Tests that need the embed path
/// skip gracefully and assert service-nil branches instead.
///
/// See ADR-IOS-034.
@Suite("BackfillMemoryEmbeddingQueue", .serialized)
struct BackfillMemoryEmbeddingQueueTests {

    // MARK: - Fixtures

    private func makeMemoryIndex() async throws -> URL {
        await MemoryIndex.shared._testReset()
        await BackfillMemoryEmbeddingQueue.shared._testReset()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("memory.db").path
        var config = Configuration()
        config.prepareDatabase { db in
            if let sqliteConn = db.sqliteConnection {
                _ = tabmail_register_sqlite_vec_on_db(UnsafeMutableRawPointer(sqliteConn))
            }
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA busy_timeout = 2000")
        }
        let pool = try DatabasePool(path: path, configuration: config)
        try await MemoryIndex.shared._testInstallPool(pool)
        return dir
    }

    private func cleanup(_ dir: URL) async {
        await BackfillMemoryEmbeddingQueue.shared._testReset()
        await MemoryIndex.shared._testReset()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Seed a user turn. Returns the chatHistoryId.
    @discardableResult
    private func seedTurn(_ id: String, content: String = "text content", sessionId: String? = "s", dateMs: Int64 = 1_700_000_000_000) async -> String {
        await MemoryIndex.shared.indexTurn(chatHistoryId: id, sessionId: sessionId, role: "user", dateMs: dateMs, text: content)
        return id
    }

    // MARK: - Repopulate picks up incomplete rows

    @Test("repopulateFromDatabase enqueues only embeddingComplete=0 rows")
    func repopulate_enqueuesOnlyIncomplete() async throws {
        let dir = try await makeMemoryIndex()
        defer { Task { await cleanup(dir) } }

        await seedTurn("r1")
        await seedTurn("r2")
        await seedTurn("r3")

        // Mark r2 complete.
        let vec = Array(repeating: Float(0.0), count: SearchConfig.embeddingDims)
        _ = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "r2", observedEpoch: 1, embedding: vec)])

        if EmbeddingService.shared == nil {
            await BackfillMemoryEmbeddingQueue.shared.repopulateFromDatabase()
            #expect(await BackfillMemoryEmbeddingQueue.shared._testQueueDepth() == 0)
            return
        }

        await BackfillMemoryEmbeddingQueue.shared.repopulateFromDatabase()
        let pending = await MemoryIndex.shared.pendingEmbeddingChatHistoryIds(limit: 10)
        #expect(Set(pending) == Set(["r1", "r3"]))
    }

    @Test("repopulate short-circuits when EmbeddingService.shared is nil")
    func repopulate_gatesOnEmbeddingServiceNil() async throws {
        let dir = try await makeMemoryIndex()
        defer { Task { await cleanup(dir) } }

        await seedTurn("g1")
        guard EmbeddingService.shared == nil else { return }

        await BackfillMemoryEmbeddingQueue.shared.repopulateFromDatabase()
        #expect(await BackfillMemoryEmbeddingQueue.shared._testQueueDepth() == 0)
    }

    // MARK: - Missing turn graceful skip

    @Test("processBatch gracefully handles missing turn (mark done, shouldRetry=false)")
    func processBatch_handlesMissingTurn() async throws {
        let dir = try await makeMemoryIndex()
        defer { Task { await cleanup(dir) } }

        await BackfillMemoryEmbeddingQueue.shared.enqueue(chatHistoryId: "ghost")
        try await Task.sleep(for: .milliseconds(750))
        #expect(await BackfillMemoryEmbeddingQueue.shared._testRetryCount(chatHistoryId: "ghost") == 0)
    }

    // MARK: - Reset hooks

    @Test("cancelAllInFlight resets counters")
    func cancelAllInFlight_resets() async throws {
        let dir = try await makeMemoryIndex()
        defer { Task { await cleanup(dir) } }

        await BackfillMemoryEmbeddingQueue.shared.enqueue(chatHistoryId: "c1")
        await BackfillMemoryEmbeddingQueue.shared.enqueue(chatHistoryId: "c2")
        await BackfillMemoryEmbeddingQueue.shared.cancelAllInFlight()
        #expect(await BackfillMemoryEmbeddingQueue.shared._testInFlightCount() == 0)
    }

    // MARK: - Epoch-stamp race (direct storeEmbeddings path, no CoreML)

    @Test("Epoch mismatch returns skippedRace via direct storeEmbeddings call")
    func processBatch_skipsStoreOnEpochMismatch() async throws {
        let dir = try await makeMemoryIndex()
        defer { Task { await cleanup(dir) } }

        await seedTurn("x", content: "first")
        let map1 = await MemoryIndex.shared.ftsContentWithEpochs(chatHistoryIds: ["x"])
        #expect(map1["x"]?.indexEpoch == 1)

        // Re-index bumps epoch to 2.
        await seedTurn("x", content: "second")
        let map2 = await MemoryIndex.shared.ftsContentWithEpochs(chatHistoryIds: ["x"])
        #expect(map2["x"]?.indexEpoch == 2)

        let vec = Array(repeating: Float(0.0), count: SearchConfig.embeddingDims)
        let result = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "x", observedEpoch: 1, embedding: vec)])
        #expect(result.committed.isEmpty)
        #expect(result.skippedRace == ["x"])
    }

    // MARK: - Rowid-reuse edge case

    @Test("Epoch stamp catches rowid-reuse (contiguous rowids, delete/insert reuses)")
    func processBatch_epochStampCatchesRowidReuse() async throws {
        let dir = try await makeMemoryIndex()
        defer { Task { await cleanup(dir) } }

        for i in 1...5 {
            await seedTurn("t\(i)", content: "content\(i)")
        }
        let originalRow = await MemoryIndex.shared._testMetaRow(chatHistoryId: "t5")
        #expect(originalRow?.rowid == 5)

        // Re-index t5. After internal DELETE(5) the max rowid is 4 → next INSERT gets 5.
        // The rowid reuses; the epoch stamp catches.
        await seedTurn("t5", content: "new t5")
        let reindexedRow = await MemoryIndex.shared._testMetaRow(chatHistoryId: "t5")
        #expect(reindexedRow?.rowid == 5, "SQLite reused rowid 5 as expected (max+1 after delete)")
        #expect(reindexedRow?.indexEpoch == 2)

        let vec = Array(repeating: Float(0.0), count: SearchConfig.embeddingDims)
        let result = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "t5", observedEpoch: 1, embedding: vec)])
        #expect(result.skippedRace == ["t5"], "Epoch stamp must catch the race even when rowid is reused")
    }

    // MARK: - awaitDrain

    @Test("awaitDrain returns quickly when queue is empty")
    func awaitDrain_returnsQuicklyWhenEmpty() async throws {
        let dir = try await makeMemoryIndex()
        defer { Task { await cleanup(dir) } }
        let start = Date()
        await BackfillMemoryEmbeddingQueue.shared.awaitDrain()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.5)
    }

    // MARK: - Chunk limit

    @Test("pendingEmbeddingChatHistoryIds respects chunk (large seed)")
    func pending_respectsChunkLimit() async throws {
        let dir = try await makeMemoryIndex()
        defer { Task { await cleanup(dir) } }

        for i in 0..<12 {
            await seedTurn("p\(i)")
        }
        let six = await MemoryIndex.shared.pendingEmbeddingChatHistoryIds(limit: 6)
        #expect(six.count == 6)
    }
}
