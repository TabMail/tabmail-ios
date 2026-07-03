/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for `MemoryIndex` actor (v3 per-turn model).
///
/// Each test creates a fresh temporary file-backed DatabasePool with sqlite-vec
/// registered, installs it via `_testInstallPool`, runs assertions, and tears down.
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

    private func makeIndex() async throws -> URL {
        await MemoryIndex.shared._testReset()
        let (pool, dir) = try makePool()
        try await MemoryIndex.shared._testInstallPool(pool)
        return dir
    }

    private func cleanup(_ dir: URL) async {
        await MemoryIndex.shared._testReset()
        try? FileManager.default.removeItem(at: dir)
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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

        await MemoryIndex.shared.indexTurn(
            chatHistoryId: "real1", sessionId: "real-session", role: "user",
            dateMs: 1_700_000_000_000, text: "real turn about budget"
        )
        await MemoryIndex.shared.indexTurn(
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

    // MARK: - indexTurn writes FTS + meta (no vec)

    @Test("indexTurn writes single row: meta + fts, epoch=1, embeddingComplete=0, no vec")
    func indexTurn_writesSingleRow() async throws {
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }
        await MemoryIndex.shared.indexTurns([])
        #expect(await MemoryIndex.shared._testMetaRowCount() == 0)
    }

    // MARK: - Delete

    @Test("deleteTurns evicts matching turns and their vec rows")
    func deleteTurns_evictsMatching() async throws {
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }
        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "x")
        await MemoryIndex.shared.deleteTurns(chatHistoryIds: [])
        #expect(await MemoryIndex.shared._testMetaRowCount() == 1)
    }

    @Test("deleteAll wipes every row across all three tables")
    func deleteAll_wipesEverything() async throws {
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "x", sessionId: "s", role: "user", dateMs: 1000, text: "hello epoch")
        let map = await MemoryIndex.shared.ftsContentWithEpochs(chatHistoryIds: ["x", "nonexistent"])
        #expect(map["x"]?.indexEpoch == 1)
        #expect(map["x"]?.content == "hello epoch")
        #expect(map["nonexistent"] == nil)
    }

    @Test("storeEmbeddings with stale observedEpoch is skipped (race)")
    func storeEmbeddings_epochMismatchSkipped() async throws {
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }
        let vec = Array(repeating: Float(0.0), count: SearchConfig.embeddingDims)
        let result = await MemoryIndex.shared.storeEmbeddings([(chatHistoryId: "ghost", observedEpoch: 1, embedding: vec)])
        #expect(result.committed.isEmpty)
        #expect(result.skippedRace.isEmpty)
    }

    // MARK: - listTurns

    @Test("listTurns returns reverse-chronological per-turn rows up to limit")
    func listTurns_reverseChrono() async throws {
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

        for i in 0..<5 {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "t\(i)", sessionId: "s", role: i % 2 == 0 ? "user" : "assistant", dateMs: Int64(i * 1000), text: "m\(i)")
        }
        let hits = await MemoryIndex.shared.listTurns(limit: 3)
        #expect(hits.count == 3)
        #expect(hits.map(\.chatHistoryId) == ["t4", "t3", "t2"])
        #expect(hits.allSatisfy { $0.snippet.isEmpty })   // no FTS match, snippet empty
    }

    // MARK: - Search: per-turn hits

    @Test("search returns per-turn hits — session with 2 matches yields 2 hits")
    func search_perTurnHits() async throws {
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "the quarterly kyle update")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "t2", sessionId: "s", role: "assistant", dateMs: 1100, text: "Kyle's status looks good")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "t3", sessionId: "s", role: "user", dateMs: 1200, text: "what about Jane?")

        let hits = await MemoryIndex.shared.search(query: "kyle", limit: 10)
        let ids = Set(hits.map(\.chatHistoryId))
        #expect(ids == Set(["t1", "t2"]))
        #expect(hits.allSatisfy { $0.snippet.contains("[") && $0.snippet.contains("]") })
    }

    @Test("search returns empty on empty query or no match")
    func search_emptyQueryOrNoMatch() async throws {
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }
        #expect(await MemoryIndex.shared.search(query: "", limit: 10).isEmpty)
        #expect(await MemoryIndex.shared.search(query: "   ", limit: 10).isEmpty)
        #expect(await MemoryIndex.shared.search(query: "nothing", limit: 10).isEmpty)
    }

    @Test("search respects date filter")
    func search_dateFilter() async throws {
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

        let baseMs: Int64 = 1_700_000_000_000
        await MemoryIndex.shared.indexTurn(chatHistoryId: "jan", sessionId: "s1", role: "user", dateMs: baseMs, text: "january keyword")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "feb", sessionId: "s2", role: "user", dateMs: baseMs + 30 * 86_400_000, text: "february keyword")

        let from: Int64 = baseMs + 20 * 86_400_000
        let to: Int64 = baseMs + 40 * 86_400_000
        let hits = await MemoryIndex.shared.search(query: "keyword", fromMs: from, toMs: to, limit: 10)
        let ids = Set(hits.map(\.chatHistoryId))
        #expect(ids == Set(["feb"]))
        #expect(ids.contains("jan") == false)
    }

    @Test("search prefix-matches short query tokens")
    func search_prefixMatchTokens() async throws {
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "Melanie sent the report")
        // Short token "mel" should prefix-match "melanie" via our ftsQuery (mel*).
        let hits = await MemoryIndex.shared.search(query: "mel", limit: 10)
        #expect(hits.contains { $0.chatHistoryId == "t1" })
    }

    // MARK: - knownChatHistoryIds

    @Test("knownChatHistoryIds returns all indexed IDs")
    func knownChatHistoryIds_returnsAll() async throws {
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }
        for id in ["a", "b", "c"] {
            await MemoryIndex.shared.indexTurn(chatHistoryId: id, sessionId: "s", role: "user", dateMs: 1000, text: "x")
        }
        #expect(await MemoryIndex.shared.knownChatHistoryIds() == Set(["a", "b", "c"]))
    }

    // MARK: - readByTimestamp (session-bounded context window)

    @Test("readByTimestamp centers window on matched turn within same session")
    func readByTimestamp_sessionBoundedWindow() async throws {
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }

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
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }
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

        await cleanup(dir)
    }

    // MARK: - Schema version gate (v3 init)

    @Test("_testInstallPool stamps PRAGMA user_version to schemaVersion")
    func schemaVersion_stamped() async throws {
        let dir = try await makeIndex()
        defer { Task { await cleanup(dir) } }
        #expect(await MemoryIndex.shared._testSchemaVersion() == 4)  // v4: tokenizer drops tokenchars
    }

    @Test("Schema gate: pre-current schema with data is dropped and rebuilt at the current version")
    func v2ToV3SchemaUpgrade_dropsAndRebuilds() async throws {
        await MemoryIndex.shared._testReset()
        let (pool, dir) = try makePool()
        defer {
            Task { await MemoryIndex.shared._testReset() }
            try? FileManager.default.removeItem(at: dir)
        }

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
        defer {
            Task { await MemoryIndex.shared._testReset() }
            try? FileManager.default.removeItem(at: dir)
        }
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
        defer {
            Task { await MemoryIndex.shared._testReset() }
            try? FileManager.default.removeItem(at: dir)
        }

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
