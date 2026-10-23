/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import SQLite3
import Synchronization
@testable import TabMail

/// Whether the memory pool's authorizer refuses `json_each` reads (only the vector-only date read uses
/// it), and how many it refused.
private let memoryDateReadFault = Mutex((deny: false, refused: 0))

/// Tests for `MemoryIndex` actor (v3 per-turn model).
///
/// Database-backed tests create a fresh temporary file-backed DatabasePool with
/// sqlite-vec registered and install it via `_testInstallPool`. `_testReset`
/// drops the singleton actor's reference but does not close the pool, so those
/// ordinary fixtures register their exact pool/directory for process-exit
/// close-before-unlink. The explicit reinstall test separately proves and owns
/// its two-pool handoff after awaiting each actor reset.
/// `.serialized` because `MemoryIndex.shared` is a singleton.
///
/// See ADR-IOS-034.
@Suite("MemoryIndex", .serialized)
struct MemoryIndexTests {

    // MARK: - Fixtures

    private func makePool() throws -> (pool: DatabasePool, dir: URL) {
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
        return (pool, dir)
    }

    private func makeIndex() async throws -> (pool: DatabasePool, directory: URL) {
        await MemoryIndex.shared._testReset()
        let (pool, dir) = try makePool()
        try await MemoryIndex.shared._testInstallPool(pool)
        return (pool, dir)
    }

    /// Build a ChatHistoryTurn for memoryText extractor tests.
    private func historyTurn(
        id: String = UUID().uuidString,
        role: String = "user",
        content: String = "",
        userMessage: String? = nil,
        sessionId: String? = "sess-default",
        type: String = "normal",
        timestamp: Double = Date().timeIntervalSince1970 * 1000
    ) -> ChatHistoryTurn {
        ChatHistoryTurn(
            id: id,
            timestamp: timestamp,
            role: role,
            content: content,
            userMessage: userMessage,
            sessionId: sessionId,
            chars: content.count + (userMessage?.count ?? 0),
            type: type
        )
    }

    // MARK: - memoryText extractor

    @Test("memoryText: user turn prefers userMessage over content")
    func memoryText_userPrefersUserMessage() async throws {
        let t = historyTurn(role: "user", content: "chat_converse", userMessage: "real user text")
        #expect(MemoryIndex.memoryText(for: t) == "real user text")
    }

    @Test("memoryText: user turn falls back to content when userMessage is nil or empty")
    func memoryText_userFallbackToContent() async throws {
        #expect(MemoryIndex.memoryText(for: historyTurn(role: "user", content: "fallback body", userMessage: nil)) == "fallback body")
        #expect(MemoryIndex.memoryText(for: historyTurn(role: "user", content: "fallback body", userMessage: "")) == "fallback body")
    }

    @Test("memoryText: assistant turn reads content")
    func memoryText_assistantReadsContent() async throws {
        let t = historyTurn(role: "assistant", content: "assistant reply", userMessage: nil)
        #expect(MemoryIndex.memoryText(for: t) == "assistant reply")
    }

    @Test("memoryText: non-normal type returns nil")
    func memoryText_nonNormalReturnsNil() async throws {
        #expect(MemoryIndex.memoryText(for: historyTurn(role: "user", content: "x", type: "greeting")) == nil)
        #expect(MemoryIndex.memoryText(for: historyTurn(role: "assistant", content: "x", type: "welcome_back")) == nil)
        #expect(MemoryIndex.memoryText(for: historyTurn(role: "assistant", content: "x", type: "session_break")) == nil)
    }

    @Test("memoryText: unknown role returns nil")
    func memoryText_unknownRoleReturnsNil() async throws {
        #expect(MemoryIndex.memoryText(for: historyTurn(role: "tool", content: "x")) == nil)
        #expect(MemoryIndex.memoryText(for: historyTurn(role: "system", content: "x")) == nil)
    }

    @Test("memoryText: empty text returns nil")
    func memoryText_emptyTextReturnsNil() async throws {
        #expect(MemoryIndex.memoryText(for: historyTurn(role: "user", content: "", userMessage: "")) == nil)
        #expect(MemoryIndex.memoryText(for: historyTurn(role: "assistant", content: "")) == nil)
    }

    // MARK: - Vec KNN demo scope (ADR-IOS-038)

    /// The demo-scope change rewrote the KNN query as a vec0 subquery JOINed
    /// to memory_meta. If the planner rejected that shape, the vector leg
    /// would silently die (do/catch → []) in NORMAL mode too — so this test
    /// asserts the query executes and returns rows, and that the demo scope
    /// filters both directions.
    @Test("searchVecCandidates: KNN subquery+JOIN executes; demo scope filters both ways")
    func vecCandidates_demoScope() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        await MemoryIndex.shared.indexTurn(
            chatHistoryId: "real1", sessionId: "real-session", role: "user",
            dateMs: 1_700_000_000_000, text: "real turn about budget"
        )
        await DemoRunFixture.indexTurn(
            chatHistoryId: "demo1", sessionId: "demo:abc", role: "user",
            dateMs: 1_700_000_001_000, text: "demo turn about budget"
        )
        let vec = Array(repeating: Float(0.5), count: SearchConfig.embeddingDims)
        _ = await MemoryIndex.shared.storeEmbeddings([
            (chatHistoryId: "real1", observedEpoch: 1, embedding: vec),
            (chatHistoryId: "demo1", observedEpoch: 1, embedding: vec),
        ])
        #expect(await MemoryIndex.shared._testVecRowCount() == 2)

        let normalHits = await MemoryIndex.shared.searchVecCandidates(
            queryEmbedding: vec, limit: 10, demoActive: false)
        let demoHits = await MemoryIndex.shared.searchVecCandidates(
            queryEmbedding: vec, limit: 10, demoActive: true)

        // Each mode sees exactly its own row — and crucially neither is empty,
        // proving the subquery+JOIN shape is accepted by the vendored vec0.
        #expect(normalHits.count == 1)
        #expect(demoHits.count == 1)
        #expect(Set(normalHits.map(\.0)).isDisjoint(with: Set(demoHits.map(\.0))))
    }

    /// A unit vector at cosine `cos` from axis 0, leaning towards axis 1.
    private func vector(cos: Float) -> [Float] {
        var v = [Float](repeating: 0, count: SearchConfig.embeddingDims)
        v[0] = cos
        v[1] = (1 - cos * cos).squareRoot()
        return v
    }

    /// With dates, the vector search looks only among the turns dated within them (tabmail-ios#242,
    /// mirroring tabmail-native-fts#26, ADR-NF-016): both bounds and either bound alone, inclusive.
    @Test("searchVecCandidates: keeps the nearest turns within both bounds or either bound alone")
    func vecCandidates_withinTheDates() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        // Turn i at distance i/100 from the query, dated i days after the base (a month ahead, so a
        // missing end date standing for now would exclude them), and turn 6 long before 1970.
        let day: Int64 = 86_400_000, base = Int64(Date().timeIntervalSince1970 * 1000) + 30 * day
        let dates = (1...5).map { base + Int64($0) * day } + [-5_000_000_000_000]
        for (i, dateMs) in dates.enumerated() {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "t\(i + 1)", sessionId: "s", role: "user", dateMs: dateMs, text: "turn")
        }
        _ = await MemoryIndex.shared.storeEmbeddings(dates.indices.map {
            (chatHistoryId: "t\($0 + 1)", observedEpoch: 1, embedding: vector(cos: 1 - Float($0 + 1) / 100))
        })
        func nearest(_ k: Int, _ from: Int64?, _ to: Int64?) async -> [Int] {
            await MemoryIndex.shared.searchVecCandidates(queryEmbedding: vector(cos: 1), limit: k, demoActive: false, fromMs: from, toMs: to)
                .map { Int(($0.1 * 100).rounded()) }
        }

        #expect(await nearest(2, nil, nil) == [1, 2])
        #expect(await nearest(5, base + 2 * day, base + 3 * day) == [2, 3])
        #expect(await nearest(5, base + 4 * day, base + 4 * day) == [4])
        #expect(await nearest(5, base + 4 * day, nil) == [4, 5])
        #expect(await nearest(5, nil, base + day) == [1, 6])
        #expect(await nearest(5, base + 5 * day + 1, nil) == [])
    }

    /// A dated memory search finds a turn by meaning alone past more nearer turns outside the dates
    /// than its vector search asks for (tabmail-ios#242, mirroring tabmail-native-fts#26).
    @Test("hybridSearch: a match by meaning inside the dates is found past nearer turns outside them")
    func hybridSearch_matchByMeaningPastNearerTurnsOutsideTheDates() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        let day: Int64 = 86_400_000, limit = 2, base = Int64(Date().timeIntervalSince1970 * 1000) + 30 * day
        let nearer = limit * SearchConfig.candidateMultiplier * 2 + 4
        await MemoryIndex.shared.indexTurn(chatHistoryId: "inside", sessionId: "s", role: "user", dateMs: base + 10 * day, text: "turn")
        var embeddings: [(chatHistoryId: String, observedEpoch: Int64, embedding: [Float])] = [
            (chatHistoryId: "inside", observedEpoch: 1, embedding: vector(cos: 0.8))
        ]
        for i in 0..<nearer {
            for (id, dateMs) in [("before\(i)", base + Int64(i) * 3_600_000), ("after\(i)", base + 20 * day + Int64(i) * 3_600_000)] {
                await MemoryIndex.shared.indexTurn(chatHistoryId: id, sessionId: "s", role: "user", dateMs: dateMs, text: "turn")
                embeddings.append((chatHistoryId: id, observedEpoch: 1, embedding: vector(cos: 1)))
            }
        }
        _ = await MemoryIndex.shared.storeEmbeddings(embeddings)

        // Without dates, the nearer turns take every place the vector search asks for.
        let unfiltered = await MemoryIndex.shared.searchVecCandidates(
            queryEmbedding: vector(cos: 1), limit: limit * SearchConfig.candidateMultiplier, demoActive: false)
        #expect(unfiltered.count == limit * SearchConfig.candidateMultiplier)
        #expect(unfiltered.allSatisfy { $0.1 < 0.1 })

        // No keyword matches: the turn is found by meaning alone.
        let hits = await MemoryIndex.shared.hybridSearch(
            query: "zyxwvut", queryEmbedding: vector(cos: 1), fromMs: base + 9 * day, toMs: base + 11 * day,
            limit: limit, demoActive: false)
        #expect(hits.map(\.chatHistoryId) == ["inside"])
    }

    /// With no vector within the dates (as during embedding backfill), a dated memory search answers
    /// with every keyword match within them, the weak one too (tabmail-ios#242, native-fts #25 item 5).
    @Test("hybridSearch: with no vector within the dates, every keyword match within them is the answer")
    func hybridSearch_noVectorWithinTheDatesAnswersByKeyword() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        let day: Int64 = 86_400_000, base = Int64(Date().timeIntervalSince1970 * 1000) + 30 * day
        // A strong and a weak keyword match (a short turn and a long one) within the dates, one turn with
        // the query's own vector outside them, and turns without the word.
        await MemoryIndex.shared.indexTurn(chatHistoryId: "strong", sessionId: "s", role: "user", dateMs: base, text: "kinkajou")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "weak", sessionId: "s", role: "user", dateMs: base + day,
                                           text: "kinkajou " + String(repeating: "weather ", count: 2000))
        await MemoryIndex.shared.indexTurn(chatHistoryId: "outside", sessionId: "s", role: "user", dateMs: base + 10 * day, text: "different")
        for i in 0..<40 {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "other\(i)", sessionId: "s", role: "user", dateMs: base + 20 * day, text: "different")
        }
        #expect(await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "outside", observedEpoch: 1, embedding: vector(cos: 1))]).committed == ["outside"])

        // The vector exists, but not within the dates.
        #expect(await MemoryIndex.shared.searchVecCandidates(queryEmbedding: vector(cos: 1), limit: 1, demoActive: false).count == 1)
        #expect(await MemoryIndex.shared.searchVecCandidates(
            queryEmbedding: vector(cos: 1), limit: 10, demoActive: false, fromMs: base, toMs: base + 2 * day).isEmpty)

        let hits = await MemoryIndex.shared.hybridSearch(
            query: "kinkajou", queryEmbedding: vector(cos: 1), fromMs: base, toMs: base + 2 * day, limit: 10, demoActive: false)
        #expect(Set(hits.map(\.chatHistoryId)) == ["strong", "weak"])
    }

    // MARK: - indexTurn writes FTS + meta (no vec)

    @Test("indexTurn writes single row: meta + fts, epoch=1, embeddingComplete=0, no vec")
    func indexTurn_writesSingleRow() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        await MemoryIndex.shared.indexTurn(
            chatHistoryId: "t1",
            sessionId: "sess-a",
            role: "user",
            dateMs: 1_700_000_000_000,
            text: "how is the Q2 budget?"
        )
        #expect(await MemoryIndex.shared._testMetaRowCount() == 1)
        #expect(await MemoryIndex.shared._testVecRowCount() == 0)

        guard let row = await MemoryIndex.shared._testMetaRow(chatHistoryId: "t1") else {
            Issue.record("Expected a memory_meta row for t1")
            return
        }
        #expect(row.sessionId == "sess-a")
        #expect(row.role == "user")
        #expect(row.dateMs == 1_700_000_000_000)
        #expect(row.indexEpoch == 1)
        #expect(row.embeddingComplete == 0)

        let content = await MemoryIndex.shared._testFTSContent(chatHistoryId: "t1")
        #expect(content == "how is the Q2 budget?")
    }

    @Test("indexTurn upsert: same chatHistoryId bumps epoch, clears vec, replaces fts")
    func indexTurn_upsertBumpsEpoch() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "first")
        let v1 = await MemoryIndex.shared._testMetaRow(chatHistoryId: "t1")
        #expect(v1?.indexEpoch == 1)

        // Simulate a prior embed completing.
        let fakeVec = Array(repeating: Float(0.0), count: SearchConfig.embeddingDims)
        _ = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "t1", observedEpoch: 1, embedding: fakeVec)])
        #expect(await MemoryIndex.shared._testVecRowCount() == 1)

        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "second")
        let v2 = await MemoryIndex.shared._testMetaRow(chatHistoryId: "t1")
        #expect(v2?.indexEpoch == 2)
        #expect(v2?.embeddingComplete == 0)
        #expect(await MemoryIndex.shared._testVecRowCount() == 0)
        #expect(await MemoryIndex.shared._testFTSContent(chatHistoryId: "t1") == "second")
    }

    @Test("indexEpoch is per-turn, not shared across turns")
    func indexTurn_epochIsPerTurn() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        for i in 1...3 {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "v\(i)")
            let row = await MemoryIndex.shared._testMetaRow(chatHistoryId: "t1")
            #expect(row?.indexEpoch == Int64(i))
        }
        await MemoryIndex.shared.indexTurn(chatHistoryId: "t2", sessionId: "s", role: "user", dateMs: 2000, text: "other")
        let otherRow = await MemoryIndex.shared._testMetaRow(chatHistoryId: "t2")
        #expect(otherRow?.indexEpoch == 1)
    }

    // MARK: - indexTurns bulk

    @Test("indexTurns bulk writes all turns in one transaction")
    func indexTurns_bulkWrites() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        let entries: [(chatHistoryId: String, sessionId: String?, role: String, dateMs: Int64, text: String)] = [
            ("t1", "s", "user", 1000, "first"),
            ("t2", "s", "assistant", 1100, "second"),
            ("t3", "s", "user", 1200, "third"),
        ]
        await MemoryIndex.shared.indexTurns(entries)
        #expect(await MemoryIndex.shared._testMetaRowCount() == 3)
        #expect(await MemoryIndex.shared._testFTSContent(chatHistoryId: "t2") == "second")
    }

    @Test("indexTurns empty input is a no-op")
    func indexTurns_emptyNoOp() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        await MemoryIndex.shared.indexTurns([])
        #expect(await MemoryIndex.shared._testMetaRowCount() == 0)
    }

    // MARK: - Delete

    @Test("deleteTurns evicts matching turns and their vec rows")
    func deleteTurns_evictsMatching() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        for (i, id) in ["t1", "t2", "t3"].enumerated() {
            await MemoryIndex.shared.indexTurn(chatHistoryId: id, sessionId: "s", role: "user", dateMs: Int64(1000 + i), text: "c\(i)")
        }
        let vec = Array(repeating: Float(0.0), count: SearchConfig.embeddingDims)
        _ = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "t2", observedEpoch: 1, embedding: vec)])

        await MemoryIndex.shared.deleteTurns(chatHistoryIds: ["t2", "t3"])
        let known = await MemoryIndex.shared.knownChatHistoryIds()
        #expect(known == Set(["t1"]))
        #expect(await MemoryIndex.shared._testVecRowCount() == 0)
    }

    @Test("deleteTurns([]) is a no-op")
    func deleteTurns_emptyNoOp() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "x")
        await MemoryIndex.shared.deleteTurns(chatHistoryIds: [])
        #expect(await MemoryIndex.shared._testMetaRowCount() == 1)
    }

    @Test("deleteAll wipes every row across all three tables")
    func deleteAll_wipesEverything() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        for id in ["t1", "t2", "t3"] {
            await MemoryIndex.shared.indexTurn(chatHistoryId: id, sessionId: "s", role: "user", dateMs: 1000, text: "x")
        }
        let vec = Array(repeating: Float(0.0), count: SearchConfig.embeddingDims)
        _ = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "t2", observedEpoch: 1, embedding: vec)])
        #expect(await MemoryIndex.shared._testMetaRowCount() == 3)
        #expect(await MemoryIndex.shared._testVecRowCount() == 1)

        await MemoryIndex.shared.deleteAll()
        #expect(await MemoryIndex.shared._testMetaRowCount() == 0)
        #expect(await MemoryIndex.shared._testVecRowCount() == 0)
        #expect(await MemoryIndex.shared.knownChatHistoryIds().isEmpty)
    }

    // MARK: - Queue helpers (chatHistoryId-keyed)

    @Test("pendingEmbeddingChatHistoryIds returns only embeddingComplete=0 rows")
    func pendingEmbeddingIds_returnsOnlyIncomplete() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        for id in ["p1", "p2", "p3"] {
            await MemoryIndex.shared.indexTurn(chatHistoryId: id, sessionId: "s", role: "user", dateMs: 1000, text: "text")
        }
        let vec = Array(repeating: Float(0.0), count: SearchConfig.embeddingDims)
        _ = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "p2", observedEpoch: 1, embedding: vec)])
        let pending = await MemoryIndex.shared.pendingEmbeddingChatHistoryIds(limit: 100)
        #expect(Set(pending) == Set(["p1", "p3"]))
    }

    @Test("pendingEmbeddingChatHistoryIds respects LIMIT")
    func pendingEmbeddingIds_respectsLimit() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        for i in 0..<8 {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "t\(i)", sessionId: "s", role: "user", dateMs: Int64(i * 1000), text: "x")
        }
        let top3 = await MemoryIndex.shared.pendingEmbeddingChatHistoryIds(limit: 3)
        #expect(top3.count == 3)
        // ORDER BY dateMs DESC → most-recent first.
        #expect(top3 == ["t7", "t6", "t5"])
    }

    @Test("ftsContentWithEpochs returns content + rowid + epoch by chatHistoryId")
    func ftsContentWithEpochs_returns() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "x", sessionId: "s", role: "user", dateMs: 1000, text: "hello epoch")
        let map = await MemoryIndex.shared.ftsContentWithEpochs(chatHistoryIds: ["x", "nonexistent"])
        #expect(map["x"]?.indexEpoch == 1)
        #expect(map["x"]?.content == "hello epoch")
        #expect(map["nonexistent"] == nil)
    }

    @Test("storeEmbeddings with stale observedEpoch is skipped (race)")
    func storeEmbeddings_epochMismatchSkipped() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "first")
        // Bump epoch via re-index.
        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "second")
        let vec = Array(repeating: Float(0.0), count: SearchConfig.embeddingDims)
        let result = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "t1", observedEpoch: 1, embedding: vec)])
        #expect(result.committed.isEmpty)
        #expect(result.skippedRace == ["t1"])
        let row = await MemoryIndex.shared._testMetaRow(chatHistoryId: "t1")
        #expect(row?.embeddingComplete == 0)
    }

    @Test("storeEmbeddings with current observedEpoch commits and flips flag")
    func storeEmbeddings_epochMatchCommits() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "x")
        let vec = Array(repeating: Float(0.0), count: SearchConfig.embeddingDims)
        let result = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "t1", observedEpoch: 1, embedding: vec)])
        #expect(result.committed == ["t1"])
        let row = await MemoryIndex.shared._testMetaRow(chatHistoryId: "t1")
        #expect(row?.embeddingComplete == 1)
        #expect(await MemoryIndex.shared._testVecRowCount() == 1)
    }

    @Test("storeEmbeddings with missing turn is no-op")
    func storeEmbeddings_missingNoOp() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        let vec = Array(repeating: Float(0.0), count: SearchConfig.embeddingDims)
        let result = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "ghost", observedEpoch: 1, embedding: vec)])
        #expect(result.committed.isEmpty)
        #expect(result.skippedRace.isEmpty)
    }

    // MARK: - listTurns

    @Test("listTurns returns reverse-chronological per-turn rows up to limit")
    func listTurns_reverseChrono() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        for i in 0..<5 {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "t\(i)", sessionId: "s", role: i % 2 == 0 ? "user" : "assistant", dateMs: Int64(i * 1000), text: "m\(i)")
        }
        let hits = await MemoryIndex.shared.listTurns(limit: 3)
        #expect(hits.count == 3)
        #expect(hits.map(\.chatHistoryId) == ["t4", "t3", "t2"])
        #expect(hits.allSatisfy { $0.snippet.isEmpty })   // no FTS match, snippet empty
    }

    /// The chat-history listing shows every turn kept, whatever its session:
    /// real, legacy (no session) and demo, newest first.
    @Test("listTurns lists every session's turns, newest first")
    func listTurns_everySession() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "real", sessionId: "s", role: "user", dateMs: 3000, text: "real")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "legacy", sessionId: nil, role: "user", dateMs: 2000, text: "legacy")
        await DemoRunFixture.indexTurn(chatHistoryId: "demo", sessionId: "demo:a", role: "user", dateMs: 1000, text: "demo")
        let hits = await MemoryIndex.shared.listTurns(limit: 10)
        #expect(hits.map(\.chatHistoryId) == ["real", "legacy", "demo"])
    }

    /// An empty query lists the newest turns first, within the dateMs window,
    /// and in the search's demo scope (normal mode never sees demo turns).
    @Test("search with an empty query lists the newest turns in the window, demo turns left out")
    func search_emptyQueryListsRecent() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let day: Int64 = 86_400_000
        for i in 0..<5 {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "t\(i)", sessionId: "s", role: "user", dateMs: now - Int64(5 - i) * day, text: "turn \(i)")
        }
        await DemoRunFixture.indexTurn(chatHistoryId: "demo", sessionId: "demo:abc", role: "user", dateMs: now, text: "demo turn")

        for query in ["", "   ", "\n", "\r\n"] {
            let all = await MemoryIndex.shared.search(query: query, limit: 10, demoActive: false)
            #expect(all.map(\.chatHistoryId) == ["t4", "t3", "t2", "t1", "t0"])
            let capped = await MemoryIndex.shared.search(query: query, limit: 2, demoActive: false)
            #expect(capped.map(\.chatHistoryId) == ["t4", "t3"])
            let window = await MemoryIndex.shared.search(query: query, fromMs: now - 4 * day, toMs: now - 2 * day, limit: 10, demoActive: false)
            #expect(window.map(\.chatHistoryId) == ["t3", "t2", "t1"])
        }
    }

    // MARK: - Search: per-turn hits

    @Test("search returns per-turn hits — session with 2 matches yields 2 hits")
    func search_perTurnHits() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "the quarterly kyle update")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "t2", sessionId: "s", role: "assistant", dateMs: 1100, text: "Kyle's status looks good")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "t3", sessionId: "s", role: "user", dateMs: 1200, text: "what about Jane?")

        let hits = await MemoryIndex.shared.search(query: "kyle", limit: 10, demoActive: false)
        let ids = Set(hits.map(\.chatHistoryId))
        #expect(ids == Set(["t1", "t2"]))
        #expect(hits.allSatisfy { $0.snippet.contains("[") && $0.snippet.contains("]") })
    }

    @Test("search returns empty on empty query or no match")
    func search_emptyQueryOrNoMatch() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        #expect(await MemoryIndex.shared.search(query: "", limit: 10, demoActive: false).isEmpty)
        #expect(await MemoryIndex.shared.search(query: "   ", limit: 10, demoActive: false).isEmpty)
        #expect(await MemoryIndex.shared.search(query: "nothing", limit: 10, demoActive: false).isEmpty)
    }

    @Test("search respects date filter")
    func search_dateFilter() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        let baseMs: Int64 = 1_700_000_000_000
        await MemoryIndex.shared.indexTurn(chatHistoryId: "jan", sessionId: "s1", role: "user", dateMs: baseMs, text: "january keyword")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "feb", sessionId: "s2", role: "user", dateMs: baseMs + 30 * 86_400_000, text: "february keyword")

        let from: Int64 = baseMs + 20 * 86_400_000
        let to: Int64 = baseMs + 40 * 86_400_000
        let hits = await MemoryIndex.shared.search(query: "keyword", fromMs: from, toMs: to, limit: 10, demoActive: false)
        let ids = Set(hits.map(\.chatHistoryId))
        #expect(ids == Set(["feb"]))
        #expect(ids.contains("jan") == false)
    }

    @Test("search prefix-matches short query tokens")
    func search_prefixMatchTokens() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "Melanie sent the report")
        // Short token "mel" should prefix-match "melanie" via our ftsQuery (mel*).
        let hits = await MemoryIndex.shared.search(query: "mel", limit: 10, demoActive: false)
        #expect(hits.contains { $0.chatHistoryId == "t1" })
    }

    // MARK: - Search: a merge that keeps nothing answers by keyword (tabmail-ios#240)

    private static func oneHot(_ i: Int) -> [Float] {
        var v = [Float](repeating: 0, count: SearchConfig.embeddingDims)
        v[i] = 1
        return v
    }

    /// 30 turns naming "budget" (vector along axis 1) and 10 without (axis 2, or 3 for the first). A
    /// word in at least half the rows gets an FTS5 IDF of about 0, so its keyword score is about 0.
    private func indexBudgetFixture() async -> (budget: Set<String>, weather: Set<String>) {
        let budget = (0..<30).map { "b\($0)" }
        let weather = (0..<10).map { "w\($0)" }
        for (i, id) in budget.enumerated() {
            await MemoryIndex.shared.indexTurn(chatHistoryId: id, sessionId: "s", role: "user", dateMs: 1000 + Int64(i),
                                               text: "we talked about the parking, the lunch order \(i), the train and the budget")
        }
        for (i, id) in weather.enumerated() {
            await MemoryIndex.shared.indexTurn(chatHistoryId: id, sessionId: "s", role: "user", dateMs: 2000 + Int64(i),
                                               text: "rain tomorrow \(i)")
        }
        _ = await MemoryIndex.shared.storeEmbeddings(
            budget.map { (chatHistoryId: $0, observedEpoch: 1, embedding: Self.oneHot(1)) }
                + weather.map { (chatHistoryId: $0, observedEpoch: 1, embedding: Self.oneHot($0 == "w0" ? 3 : 2)) })
        return (Set(budget), Set(weather))
    }

    @Test("search: a word in most turns with no near vector returns every keyword match")
    func search_emptyMergeAnswersByKeyword() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        let (budget, _) = await indexBudgetFixture()
        #expect(await MemoryIndex.shared._testVecRowCount() == 40)

        // Query vector orthogonal to every stored one: vector score 0 for all.
        let hits = await MemoryIndex.shared.hybridSearch(query: "budget", queryEmbedding: Self.oneHot(0),
                                                         fromMs: nil, toMs: nil, limit: 100, demoActive: false)
        #expect(Set(hits.map(\.chatHistoryId)) == budget)

        // Within dates covering budget turns 5 to 9, with matches on both sides: those 5.
        let dated = await MemoryIndex.shared.hybridSearch(query: "budget", queryEmbedding: Self.oneHot(0),
                                                          fromMs: 1005, toMs: 1009, limit: 100, demoActive: false)
        #expect(Set(dated.map(\.chatHistoryId)) == Set((5..<10).map { "b\($0)" }))

        // Fewer than the matches: `limit` of them, best keyword match first (equal here, so newest first).
        let limited = await MemoryIndex.shared.hybridSearch(query: "budget", queryEmbedding: Self.oneHot(0),
                                                            fromMs: nil, toMs: nil, limit: 5, demoActive: false)
        #expect(limited.map(\.chatHistoryId) == (25..<30).reversed().map { "b\($0)" })
    }

    @Test("search: a merge that keeps nothing answers with the best keyword match first, not the newest")
    func search_emptyMergeAnswersBestKeywordMatchFirst() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        let hour: Int64 = 3_600_000
        // "budget" in half the turns: its keyword scores are about 0 but still ordered, the short
        // older turn ahead of the long newer one.
        let rows: [(id: String, text: String, dateMs: Int64)] = [
            ("strong", "budget", 1000),
            ("weak", "budget " + String(repeating: "weather ", count: 100), 1000 + hour),
            ("other1", "other words", 1000 + hour),
            ("other2", "different words", 1000 + hour),
        ]
        for row in rows {
            await MemoryIndex.shared.indexTurn(chatHistoryId: row.id, sessionId: "s", role: "user", dateMs: row.dateMs, text: row.text)
        }
        _ = await MemoryIndex.shared.storeEmbeddings(rows.map { (chatHistoryId: $0.id, observedEpoch: 1, embedding: Self.oneHot(1)) })
        #expect(await MemoryIndex.shared._testVecRowCount() == 4)

        // Query vector orthogonal to every stored one: the merge keeps nothing.
        let hits = await MemoryIndex.shared.hybridSearch(query: "budget", queryEmbedding: Self.oneHot(0),
                                                         fromMs: nil, toMs: nil, limit: 1, demoActive: false)
        #expect(hits.map(\.chatHistoryId) == ["strong"])
    }

    @Test("search: when the merge keeps results, those are the answer")
    func search_nonEmptyMergeIsTheAnswer() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        let (_, weather) = await indexBudgetFixture()

        // Query vector equal to most weather turns' vectors: they are kept by meaning, the budget
        // turns (keyword score about 0, vector score 0) are not.
        let hits = await MemoryIndex.shared.hybridSearch(query: "budget", queryEmbedding: Self.oneHot(2),
                                                         fromMs: nil, toMs: nil, limit: 100, demoActive: false)
        #expect(Set(hits.map(\.chatHistoryId)) == weather.subtracting(["w0"]))

        // A merge that keeps a single turn is the answer too.
        let single = await MemoryIndex.shared.hybridSearch(query: "budget", queryEmbedding: Self.oneHot(3),
                                                           fromMs: nil, toMs: nil, limit: 100, demoActive: false)
        #expect(single.map(\.chatHistoryId) == ["w0"])
    }

    /// Equal matches go newer first (tabmail-ios#265, mirroring tabmail-native-fts#46): two turns found
    /// by meaning alone with the same vector, the older written first. Their dates are read for the merge.
    @Test("hybridSearch: equal matches come newer first")
    func hybridSearch_equalMatchesComeNewerFirst() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        await MemoryIndex.shared.indexTurn(chatHistoryId: "older", sessionId: "s", role: "user", dateMs: 1000, text: "turn")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "newer", sessionId: "s", role: "user", dateMs: 2000, text: "turn")
        _ = await MemoryIndex.shared.storeEmbeddings(["older", "newer"].map { (chatHistoryId: $0, observedEpoch: 1, embedding: vector(cos: 1)) })

        let hits = await MemoryIndex.shared.hybridSearch(query: "zyxwvut", queryEmbedding: vector(cos: 1),
                                                         fromMs: nil, toMs: nil, limit: 2, demoActive: false)
        #expect(hits.map(\.chatHistoryId) == ["newer", "older"])
        #expect(hits.map(\.dateMs) == [2000, 1000])
    }

    @Test("hybridSearch: the better match comes before a newer weaker one")
    func hybridSearch_betterMatchBeforeNewerWeaker() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        await MemoryIndex.shared.indexTurn(chatHistoryId: "better", sessionId: "s", role: "user", dateMs: 1000, text: "turn")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "newer", sessionId: "s", role: "user", dateMs: 2000, text: "turn")
        _ = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "better", observedEpoch: 1, embedding: vector(cos: 1)),
                                                      (chatHistoryId: "newer", observedEpoch: 1, embedding: vector(cos: 0.8))])

        let hits = await MemoryIndex.shared.hybridSearch(query: "zyxwvut", queryEmbedding: vector(cos: 1),
                                                         fromMs: nil, toMs: nil, limit: 1, demoActive: false)
        #expect(hits.map(\.chatHistoryId) == ["better"])
    }

    /// A failed date read of the vector-only candidates leaves them out and keeps the keyword matches,
    /// as a failed `fetchMetaForRowids` does; the next search reads them again (tabmail-ios#265).
    @Test("hybridSearch: a failed date read keeps the keyword matches and leaves out the vector-only ones")
    func hybridSearch_failedDateReadKeepsKeywordMatches() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.prepareDatabase { db in
            if let sqliteConn = db.sqliteConnection {
                _ = tabmail_register_sqlite_vec_on_db(UnsafeMutableRawPointer(sqliteConn))
                sqlite3_set_authorizer(sqliteConn, { _, action, table, _, _, _ in
                    guard action == SQLITE_READ, let table, String(cString: table) == "json_each" else { return SQLITE_OK }
                    return memoryDateReadFault.withLock { state in
                        guard state.deny else { return SQLITE_OK }
                        state.refused += 1
                        return SQLITE_DENY
                    }
                }, nil)
            }
        }
        let pool = try DatabasePool(path: dir.appendingPathComponent("memory.db").path, configuration: config)
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        await MemoryIndex.shared._testReset()
        try await MemoryIndex.shared._testInstallPool(pool)

        // "keyword" matches the word; "meaning" is found by its vector alone. Filler keeps the word rare.
        await MemoryIndex.shared.indexTurn(chatHistoryId: "keyword", sessionId: "s", role: "user", dateMs: 1000, text: "quokka")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "meaning", sessionId: "s", role: "user", dateMs: 2000, text: "turn")
        for i in 0..<12 {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "filler\(i)", sessionId: "s", role: "user", dateMs: 1000, text: "turn")
        }
        _ = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "meaning", observedEpoch: 1, embedding: vector(cos: 1))])
        func search() async -> [String] {
            await MemoryIndex.shared.hybridSearch(query: "quokka", queryEmbedding: vector(cos: 1), fromMs: nil, toMs: nil,
                                                  limit: 4, demoActive: false).map(\.chatHistoryId)
        }

        memoryDateReadFault.withLock { $0 = (false, 0) }
        #expect(await search() == ["meaning", "keyword"])
        memoryDateReadFault.withLock { $0.deny = true }
        let failed = await search()
        memoryDateReadFault.withLock { $0.deny = false }
        #expect(memoryDateReadFault.withLock { $0.refused } > 0)
        #expect(failed == ["keyword"])
        #expect(await search() == ["meaning", "keyword"])
        await MemoryIndex.shared._testReset()
    }

    @Test("search answers by the hybrid path within its dates and its limit")
    func search_handsItsArgumentsToTheHybridPath() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        let day: Int64 = 86_400_000
        for i in 0..<6 {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "k\(i)", sessionId: "s", role: "user",
                                               dateMs: 1000 + Int64(i) * day, text: "kyle note \(i)")
            await MemoryIndex.shared.indexTurn(chatHistoryId: "o\(i)", sessionId: "s", role: "user",
                                               dateMs: 1000 + Int64(i) * day, text: "other words \(i)")
        }
        let dated = await MemoryIndex.shared.search(query: "kyle", fromMs: 1000 + day + day / 2,
                                                    toMs: 1000 + 3 * day + day / 2, limit: 10, demoActive: false)
        #expect(Set(dated.map(\.chatHistoryId)) == ["k2", "k3"])
        let limited = await MemoryIndex.shared.search(query: "kyle", limit: 1, demoActive: false)
        #expect(limited.count == 1)
    }

    // MARK: - knownChatHistoryIds

    @Test("knownChatHistoryIds returns all indexed IDs")
    func knownChatHistoryIds_returnsAll() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        for id in ["a", "b", "c"] {
            await MemoryIndex.shared.indexTurn(chatHistoryId: id, sessionId: "s", role: "user", dateMs: 1000, text: "x")
        }
        #expect(await MemoryIndex.shared.knownChatHistoryIds() == Set(["a", "b", "c"]))
    }

    // MARK: - readByTimestamp (session-bounded context window)

    @Test("readByTimestamp centers window on matched turn within same session")
    func readByTimestamp_sessionBoundedWindow() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        let t0: Int64 = 1_700_000_000_000
        // 7 turns in session "s", spaced 10s apart.
        for i in 0..<7 {
            await MemoryIndex.shared.indexTurn(
                chatHistoryId: "t\(i)",
                sessionId: "s",
                role: i % 2 == 0 ? "user" : "assistant",
                dateMs: t0 + Int64(i * 10_000),
                text: "turn \(i)"
            )
        }
        // Target = t3 (middle), maxTurns = 5 → should return t1..t5 (t3 + 2 before + 2 after).
        let target = t0 + Int64(3 * 10_000)
        let hits = await MemoryIndex.shared.readByTimestamp(
            timestampMs: target,
            toleranceMs: 60_000,
            maxTurns: 5
        )
        let ids = hits.map(\.chatHistoryId)
        #expect(ids == ["t1", "t2", "t3", "t4", "t5"])
        #expect(hits.allSatisfy { $0.sessionId == "s" })
    }

    @Test("readByTimestamp does not leak across sessions")
    func readByTimestamp_noCrossSessionLeak() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        let t0: Int64 = 1_700_000_000_000
        // Session A has 3 turns around t0.
        for i in 0..<3 {
            await MemoryIndex.shared.indexTurn(
                chatHistoryId: "a\(i)",
                sessionId: "A",
                role: "user",
                dateMs: t0 + Int64(i * 1_000),
                text: "A\(i)"
            )
        }
        // Session B has 3 turns interleaved in time (adjacent ms).
        for i in 0..<3 {
            await MemoryIndex.shared.indexTurn(
                chatHistoryId: "b\(i)",
                sessionId: "B",
                role: "user",
                dateMs: t0 + Int64(i * 1_000) + 500,
                text: "B\(i)"
            )
        }

        // Target right at A0, tolerance covers both sessions. Window should stay in A.
        let hits = await MemoryIndex.shared.readByTimestamp(
            timestampMs: t0,
            toleranceMs: 10_000,
            maxTurns: 10
        )
        #expect(hits.allSatisfy { $0.sessionId == "A" })
        #expect(hits.count == 3)
    }

    @Test("readByTimestamp with NULL sessionId falls back to time-window walk")
    func readByTimestamp_nullSessionIdFallback() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        let t0: Int64 = 1_700_000_000_000
        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: nil, role: "user", dateMs: t0, text: "one")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "t2", sessionId: nil, role: "assistant", dateMs: t0 + 1000, text: "two")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "t3", sessionId: nil, role: "user", dateMs: t0 + 2000, text: "three")

        let hits = await MemoryIndex.shared.readByTimestamp(timestampMs: t0 + 1000, toleranceMs: 5000, maxTurns: 10)
        #expect(hits.count == 3)
        #expect(hits.map(\.dateMs) == [t0, t0 + 1000, t0 + 2000])
    }

    @Test("readByTimestamp empty window returns empty array")
    func readByTimestamp_emptyWindow() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        let hits = await MemoryIndex.shared.readByTimestamp(timestampMs: 0, toleranceMs: 0, maxTurns: 10)
        #expect(hits.isEmpty)
    }

    // MARK: - Pool survives re-init

    @Test("Pool survives reinstall — rows persist across _testReset + reinstall")
    func pool_survivesRelaunch() async throws {
        await MemoryIndex.shared._testReset()
        let (pool, dir) = try makePool()
        try await MemoryIndex.shared._testInstallPool(pool)
        await MemoryIndex.shared.indexTurn(chatHistoryId: "persist", sessionId: "s", role: "user", dateMs: 1000, text: "hello persistence")
        #expect(await MemoryIndex.shared.knownChatHistoryIds().contains("persist"))

        await MemoryIndex.shared._testReset()

        var config = Configuration()
        config.prepareDatabase { db in
            if let sqliteConn = db.sqliteConnection {
                _ = tabmail_register_sqlite_vec_on_db(UnsafeMutableRawPointer(sqliteConn))
            }
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA busy_timeout = 2000")
        }
        let reopened = try DatabasePool(path: dir.appendingPathComponent("memory.db").path, configuration: config)
        try await MemoryIndex.shared._testInstallPool(reopened)
        #expect(await MemoryIndex.shared.knownChatHistoryIds().contains("persist"))

        await MemoryIndex.shared._testReset()
        // Two pools were opened on this one file. The superseded one is done
        // with, so close it outright; the live one is retired (closed, then
        // unlinked on a later retirement). Unlinking `dir` with either still
        // open is the `vnode unlinked while in use` violation.
        try pool.close()
        TestDatabaseTeardown.retire(pool: reopened, directory: dir)
    }

    // MARK: - Schema version gate (v3 init)

    @Test("_testInstallPool stamps PRAGMA user_version to schemaVersion")
    func schemaVersion_stamped() async throws {
        let (pool, dir) = try await makeIndex()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        #expect(await MemoryIndex.shared._testSchemaVersion() == 4)  // v4: tokenizer drops tokenchars
    }

    @Test("Schema gate: pre-current schema with data is dropped and rebuilt at the current version")
    func v2ToV3SchemaUpgrade_dropsAndRebuilds() async throws {
        await MemoryIndex.shared._testReset()
        let (pool, dir) = try makePool()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        // Seed v2-shaped memory.db: `memory_meta` with v2 `memId` column (not `chatHistoryId`),
        // no `role` column. Simulates what a dev-device v2 memory.db looks like.
        _ = try await pool.write { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE memory_fts USING fts5(
                    content,
                    tokenize = "porter unicode61 remove_diacritics 2 tokenchars '-_.@'",
                    prefix = '2 3 4'
                )
            """)
            try db.execute(sql: """
                CREATE TABLE memory_meta (
                    rowid INTEGER PRIMARY KEY,
                    memId TEXT UNIQUE NOT NULL,
                    dateMs INTEGER NOT NULL,
                    sessionId TEXT,
                    indexEpoch INTEGER NOT NULL DEFAULT 1,
                    embeddingComplete INTEGER NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE memory_vec USING vec0(
                    embedding FLOAT[\(SearchConfig.embeddingDims)] distance_metric=cosine
                )
            """)
            try db.execute(sql: "INSERT INTO memory_fts(content) VALUES ('stale v2 content')")
            let rowid = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO memory_meta(rowid, memId, dateMs, sessionId) VALUES (?, 'chat:old', 1000, 'old-sess')",
                arguments: [rowid]
            )
            try db.execute(sql: "PRAGMA user_version = 2")
        }

        // Run the schema gate (current version) (mirrors production `initialize()`).
        try await MemoryIndex.shared._testInstallPoolWithGate(pool)

        // The v2 row must be gone (memory_meta was DROPped).
        #expect(await MemoryIndex.shared._testMetaRowCount() == 0)

        // v3 schema must be in place — exercise a write that requires v3's columns.
        await MemoryIndex.shared.indexTurn(chatHistoryId: "v3new", sessionId: "s", role: "user", dateMs: 1000, text: "v3 content")
        let row = await MemoryIndex.shared._testMetaRow(chatHistoryId: "v3new")
        #expect(row != nil)
        // `role` is v3-only — v2 memory_meta didn't have it. This assertion proves the schema was rebuilt.
        #expect(row?.role == "user")
        #expect(await MemoryIndex.shared._testSchemaVersion() == 4)  // v4: tokenizer drops tokenchars
    }

    @Test("memory_fts tokenizer matches SearchConfig.ftsTokenize (lockstep pin)")
    func memoryFtsUsesSearchConfigTokenizer() async throws {
        await MemoryIndex.shared._testReset()
        let (pool, dir) = try makePool()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }
        try await MemoryIndex.shared._testInstallPoolWithGate(pool)

        let sql = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'memory_fts'")
        }
        let createSQL = try #require(sql)
        // memory_fts shares the email index's tokenizer via SearchConfig —
        // a divergence would make memory search behave differently (ADR-024).
        #expect(createSQL.contains(SearchConfig.ftsTokenize),
                "memory_fts must use SearchConfig.ftsTokenize, got: \(createSQL)")
        #expect(!createSQL.contains("tokenchars"),
                "tokenchars must not reappear (ADR-024), got: \(createSQL)")
    }

    @Test("Schema gate no-op: already-current pool is not touched")
    func v3GateNoOpOnCurrentSchema() async throws {
        await MemoryIndex.shared._testReset()
        let (pool, dir) = try makePool()
        defer { TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir) }

        // First install stamps the current schema version.
        try await MemoryIndex.shared._testInstallPoolWithGate(pool)
        await MemoryIndex.shared.indexTurn(chatHistoryId: "keep", sessionId: "s", role: "user", dateMs: 1000, text: "preserve me")
        #expect(await MemoryIndex.shared._testMetaRowCount() == 1)

        // Second install: gate should see the current user_version and do nothing.
        await MemoryIndex.shared._testReset()
        try await MemoryIndex.shared._testInstallPoolWithGate(pool)

        // Row survived — the gate did NOT drop tables when schema was already current.
        let row = await MemoryIndex.shared._testMetaRow(chatHistoryId: "keep")
        #expect(row != nil)
        #expect(await MemoryIndex.shared._testMetaRowCount() == 1)
    }
}
