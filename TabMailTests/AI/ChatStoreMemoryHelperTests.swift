/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for `ChatStore` memory helpers:
///   - `historyTurnIdsForSelfHeal(olderThan:)`
///   - `allHistoryTurnIds()`
///   - `loadHistoryTurns(ids:)`
///   - `loadHistoryTurns(forSessionId:)` (kept from v2)
///
/// Uses `.serialized` because we rebind `AppDatabase.shared`.
@Suite("ChatStore Memory Helpers", .serialized)
struct ChatStoreMemoryHelperTests {

    // MARK: - Fixtures

    @MainActor
    private func installTempDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("tabmail.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        return (pool, dir, previous)
    }

    @MainActor
    private func tearDown(pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        AppDatabase.shared.withLock { $0 = previous }
        TestDatabaseTeardown.retire(pool: pool, directory: dir)
    }

    @MainActor
    @discardableResult
    private func insertHistoryTurn(
        _ pool: DatabasePool,
        id: String = UUID().uuidString,
        timestamp: Double,
        role: String = "user",
        content: String = "content",
        userMessage: String? = "userMessage",
        sessionId: String?,
        type: String = "normal"
    ) throws -> String {
        try pool.writeWithoutTransaction { db in
            let turn = ChatHistoryTurn(
                id: id,
                timestamp: timestamp,
                role: role,
                content: content,
                userMessage: userMessage,
                sessionId: sessionId,
                chars: content.count,
                type: type
            )
            try turn.insert(db)
        }
        return id
    }

    // MARK: - historyTurnIdsForSelfHeal

    @Test("historyTurnIdsForSelfHeal filters by cutoff, type=normal, role in {user, assistant}")
    func historyTurnIdsForSelfHeal_filters() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        defer { Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) } }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let cutoff = nowMs - 60_000
        let oldTs = Double(cutoff - 30_000)
        let newTs = Double(cutoff + 10_000)

        try await MainActor.run {
            try insertHistoryTurn(pool, id: "keep-user", timestamp: oldTs, sessionId: "s")
            try insertHistoryTurn(pool, id: "keep-asst", timestamp: oldTs, role: "assistant", sessionId: "s")
            try insertHistoryTurn(pool, id: "skip-recent", timestamp: newTs, sessionId: "s")
            try insertHistoryTurn(pool, id: "skip-greet", timestamp: oldTs, sessionId: "s", type: "greeting")
            try insertHistoryTurn(pool, id: "skip-tool", timestamp: oldTs, role: "tool", sessionId: "s")
        }

        let result = try await ChatStore.shared.historyTurnIdsForSelfHeal(olderThan: cutoff)
        #expect(result == Set(["keep-user", "keep-asst"]))
    }

    @Test("historyTurnIdsForSelfHeal includes every scope (inbox + msg: + compose:)")
    func historyTurnIdsForSelfHeal_includesEveryScope() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        defer { Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) } }

        let oldTs = Double(Int64(Date().timeIntervalSince1970 * 1000) - 10_000_000)
        try await MainActor.run {
            try insertHistoryTurn(pool, id: "inbox-t", timestamp: oldTs, sessionId: "inbox-sess")
            try insertHistoryTurn(pool, id: "msg-t", timestamp: oldTs, sessionId: "msg:acc1:foo")
            try insertHistoryTurn(pool, id: "compose-t", timestamp: oldTs, sessionId: "compose:new:bar")
        }
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000)
        let result = try await ChatStore.shared.historyTurnIdsForSelfHeal(olderThan: cutoff)
        #expect(result == Set(["inbox-t", "msg-t", "compose-t"]))
    }

    // MARK: - allHistoryTurnIds

    @Test("allHistoryTurnIds returns every row regardless of age / type / role")
    func allHistoryTurnIds_returnsEverything() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        defer { Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) } }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await MainActor.run {
            try insertHistoryTurn(pool, id: "t1", timestamp: Double(nowMs - 1_000_000), sessionId: "s")
            try insertHistoryTurn(pool, id: "t2", timestamp: Double(nowMs - 1_000), sessionId: "s", type: "greeting")
            try insertHistoryTurn(pool, id: "t3", timestamp: Double(nowMs), role: "tool", sessionId: nil)
        }
        let all = try await ChatStore.shared.allHistoryTurnIds()
        #expect(all == Set(["t1", "t2", "t3"]))
    }

    // MARK: - loadHistoryTurns(ids:)

    @Test("loadHistoryTurns(ids:) returns requested rows")
    func loadHistoryTurnsByIds_returnsRequested() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        defer { Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) } }

        try await MainActor.run {
            try insertHistoryTurn(pool, id: "a", timestamp: 1000, sessionId: "s1")
            try insertHistoryTurn(pool, id: "b", timestamp: 2000, sessionId: "s1")
            try insertHistoryTurn(pool, id: "c", timestamp: 3000, sessionId: "s2")
        }
        let turns = try await ChatStore.shared.loadHistoryTurns(ids: ["a", "c"])
        let ids = Set(turns.map(\.id))
        #expect(ids == Set(["a", "c"]))
    }

    @Test("loadHistoryTurns(ids: []) returns empty without DB hit")
    func loadHistoryTurnsByIds_emptyNoOp() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        defer { Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) } }
        let turns = try await ChatStore.shared.loadHistoryTurns(ids: [])
        #expect(turns.isEmpty)
    }

    // MARK: - loadHistoryTurns(forSessionId:) (kept from v2)

    @Test("loadHistoryTurns(forSessionId:) returns only matching session, sorted ASC")
    func loadHistoryTurns_returnsOrderedAndScoped() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        defer { Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) } }

        try await MainActor.run {
            try insertHistoryTurn(pool, timestamp: 3000, content: "third", sessionId: "sess-a")
            try insertHistoryTurn(pool, timestamp: 1000, content: "first", sessionId: "sess-a")
            try insertHistoryTurn(pool, timestamp: 2000, content: "second", sessionId: "sess-a")
            try insertHistoryTurn(pool, timestamp: 999, content: "cross", sessionId: "sess-b")
        }
        let turns = try await ChatStore.shared.loadHistoryTurns(forSessionId: "sess-a")
        #expect(turns.count == 3)
        guard turns.count == 3 else { return }
        #expect(turns[0].content == "first")
        #expect(turns[1].content == "second")
        #expect(turns[2].content == "third")
        #expect(turns.allSatisfy { $0.sessionId == "sess-a" })
    }

    // MARK: - appendTurn (v52 sanity + v3 memory.db dual-write)

    @Test("appendTurn writes type column to chatHistory")
    func appendTurn_writesTypeToChatHistory() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        defer { Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) } }

        // Reset MemoryIndex — appendTurn's memory.db side-effect is a separate integration concern;
        // here we only verify chatHistory.type is written.
        await MemoryIndex.shared._testReset()

        let chatTurn = ChatTurn(
            id: "append1",
            timestamp: 12345,
            role: "user",
            content: "chat_converse",
            userMessage: "hi",
            type: "welcome_back",
            chars: 2,
            renderedContent: nil,
            sessionId: "sess-append",
            remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        _ = try await ChatStore.shared.appendTurn(chatTurn)

        let stored = try await pool.read { db in
            try ChatHistoryTurn.fetchOne(db, key: "append1")
        }
        #expect(stored?.type == "welcome_back")
    }

    // MARK: - evictHistoryBeyondCap returns evicted IDs (for memory.db cascade)

    @Test("evictHistoryBeyondCap returns the IDs of the oldest evicted turns")
    func evictHistoryBeyondCap_returnsEvictedIds() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        defer { Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) } }

        // Seed 5 chatHistory turns with ascending timestamps.
        for i in 1...5 {
            try await MainActor.run {
                try insertHistoryTurn(pool, id: "t\(i)", timestamp: Double(i * 1000), sessionId: "s")
            }
        }

        // Cap to 3 — oldest 2 (t1, t2) should be evicted.
        let evicted = try await ChatStore.shared.evictHistoryBeyondCap(maxTurns: 3)
        #expect(Set(evicted) == Set(["t1", "t2"]))

        let remaining = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM chatHistory ORDER BY timestamp ASC")
        }
        #expect(remaining == ["t3", "t4", "t5"])
    }

    @Test("evictHistoryBeyondCap returns empty when count is at/under cap")
    func evictHistoryBeyondCap_noOpWhenAtCap() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        defer { Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) } }

        for i in 1...3 {
            try await MainActor.run {
                try insertHistoryTurn(pool, id: "t\(i)", timestamp: Double(i * 1000), sessionId: "s")
            }
        }
        let evicted = try await ChatStore.shared.evictHistoryBeyondCap(maxTurns: 3)
        #expect(evicted.isEmpty)
        let evictedAgain = try await ChatStore.shared.evictHistoryBeyondCap(maxTurns: 10)
        #expect(evictedAgain.isEmpty)
    }

    // MARK: - Integration: appendTurn → MemoryIndex dual-write

    /// Install a fresh memory.db pool alongside the tabmail.sqlite pool, so that
    /// `ChatStore.appendTurn` exercises the memory.db side of the dual-write.
    private func installMemoryPool() async throws -> (pool: DatabasePool, dir: URL) {
        await MemoryIndex.shared._testReset()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("memory.db").path
        var config = Configuration()
        config.prepareDatabase { db in
            if let sqliteConn = db.sqliteConnection {
                _ = tabmail_register_sqlite_vec_on_db(UnsafeMutableRawPointer(sqliteConn))
            }
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let pool = try DatabasePool(path: path, configuration: config)
        try await MemoryIndex.shared._testInstallPool(pool)
        return (pool, dir)
    }

    /// Close the memory.db pool before unlinking its directory — see
    /// `TestDatabaseTeardown`.
    private func tearDownMemoryPool(pool: DatabasePool, dir: URL) async {
        await MemoryIndex.shared._testReset()
        TestDatabaseTeardown.retire(pool: pool, directory: dir)
    }

    @Test("Integration: appendTurn(normal user) writes to memory.db with v3 fields")
    func appendTurn_dualWritesToMemoryDB() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        let (memPool, memDir) = try await installMemoryPool()
        defer {
            Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) }
            Task { await tearDownMemoryPool(pool: memPool, dir: memDir) }
        }

        let userTurn = ChatTurn(
            id: "int-user-1",
            timestamp: 100_000,
            role: "user",
            content: "chat_converse",
            userMessage: "what's the status of Kyle's onboarding?",
            type: "normal",
            chars: 40,
            renderedContent: nil,
            sessionId: "int-sess",
            remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        _ = try await ChatStore.shared.appendTurn(userTurn)

        let row = await MemoryIndex.shared._testMetaRow(chatHistoryId: "int-user-1")
        #expect(row != nil)
        #expect(row?.role == "user")
        #expect(row?.sessionId == "int-sess")
        // userMessage is what gets indexed (defensive against 'chat_converse' template leak).
        let fts = await MemoryIndex.shared._testFTSContent(chatHistoryId: "int-user-1")
        #expect(fts?.contains("Kyle") == true)
        #expect(fts?.contains("chat_converse") == false)
    }

    @Test("Integration: appendTurn(non-normal type) does NOT write to memory.db")
    func appendTurn_skipsMemoryDBForNonNormal() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        let (memPool, memDir) = try await installMemoryPool()
        defer {
            Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) }
            Task { await tearDownMemoryPool(pool: memPool, dir: memDir) }
        }

        let greeting = ChatTurn(
            id: "int-greet",
            timestamp: 100_000,
            role: "assistant",
            content: "Welcome back!",
            userMessage: nil,
            type: "greeting",
            chars: 13,
            renderedContent: nil,
            sessionId: "int-sess",
            remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        _ = try await ChatStore.shared.appendTurn(greeting)

        // chatHistory row exists (dual-write happens before the memoryText filter).
        let stored = try await pool.read { db in
            try ChatHistoryTurn.fetchOne(db, key: "int-greet")
        }
        #expect(stored?.type == "greeting")

        // memory.db row does NOT — `memoryText(for:)` returned nil for type=greeting.
        let row = await MemoryIndex.shared._testMetaRow(chatHistoryId: "int-greet")
        #expect(row == nil)
    }

    @Test("Integration: deleteHistoryTurns cascades to memory.db")
    func deleteHistoryTurns_cascadesToMemoryDB() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        let (memPool, memDir) = try await installMemoryPool()
        defer {
            Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) }
            Task { await tearDownMemoryPool(pool: memPool, dir: memDir) }
        }

        // Append two turns.
        for i in 1...2 {
            let t = ChatTurn(
                id: "del-\(i)", timestamp: Double(i * 1000), role: "user",
                content: "chat_converse", userMessage: "msg \(i)", type: "normal",
                chars: 5, renderedContent: nil, sessionId: "del-sess",
                remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil
            )
            _ = try await ChatStore.shared.appendTurn(t)
        }
        #expect(await MemoryIndex.shared.knownChatHistoryIds() == Set(["del-1", "del-2"]))

        try await ChatStore.shared.deleteHistoryTurns(ids: ["del-1"])
        #expect(await MemoryIndex.shared.knownChatHistoryIds() == Set(["del-2"]))
    }

    @Test("Integration: clearAll wipes both chatHistory and memory.db")
    func clearAll_cascadesToMemoryDB() async throws {
        let (pool, dir, previous) = try await MainActor.run { try installTempDB() }
        let (memPool, memDir) = try await installMemoryPool()
        defer {
            Task { @MainActor in tearDown(pool: pool, dir: dir, previous: previous) }
            Task { await tearDownMemoryPool(pool: memPool, dir: memDir) }
        }

        let t = ChatTurn(
            id: "clear-1", timestamp: 1000, role: "user",
            content: "chat_converse", userMessage: "hi", type: "normal",
            chars: 2, renderedContent: nil, sessionId: "s",
            remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil
        )
        _ = try await ChatStore.shared.appendTurn(t)
        #expect(await MemoryIndex.shared._testMetaRowCount() == 1)

        try await ChatStore.shared.clearAll()
        #expect(await MemoryIndex.shared._testMetaRowCount() == 0)
        let remaining = try await pool.read { db in
            try ChatHistoryTurn.fetchCount(db)
        }
        #expect(remaining == 0)
    }
}
