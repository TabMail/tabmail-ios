/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Integration tests for `MemorySelfHealDriver` (v3 per-turn set-diff both ways).
/// Exercises Stage A (FTS+meta) against a temp AppDatabase + MemoryIndex pair.
/// Stage B (embedding queue repopulate) is covered by `BackfillMemoryEmbeddingQueueTests`.
///
/// See ADR-IOS-034.
@Suite("MemorySelfHealDriver", .serialized, .processGlobalState)
struct MemorySelfHealDriverTests {

    // MARK: - Fixtures

    @MainActor
    private func installTempAppDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
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
    private func tearDownAppDB(pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        AppDatabase.shared.withLock { $0 = previous }
        try? pool.close()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeMemoryDB() async throws -> URL {
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

    @MainActor
    private func insertHistoryTurn(
        _ pool: DatabasePool,
        id: String = UUID().uuidString,
        timestamp: Double,
        sessionId: String?,
        role: String = "user",
        content: String = "content",
        userMessage: String? = "userMessage",
        type: String = "normal"
    ) throws {
        try pool.writeWithoutTransaction { db in
            let turn = ChatHistoryTurn(
                id: id, timestamp: timestamp, role: role,
                content: content, userMessage: userMessage,
                sessionId: sessionId, chars: content.count, type: type
            )
            try turn.insert(db)
        }
    }

    // MARK: - Stage A: A−B picks up missing turns

    @Test("Stage A indexes turns in chatHistory but not in memory_meta (older than idle cutoff)")
    func stageA_indexesMissingTurns() async throws {
        let (pool, appDir, previous) = try await MainActor.run { try installTempAppDB() }
        let memDir = try await makeMemoryDB()
        defer {
            Task { @MainActor in tearDownAppDB(pool: pool, dir: appDir, previous: previous) }
            Task { await MemoryIndex.shared._testReset(); try? FileManager.default.removeItem(at: memDir) }
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let oldTs = Double(nowMs - 10 * 60_000)
        try await MainActor.run {
            try insertHistoryTurn(pool, id: "a1", timestamp: oldTs, sessionId: "heal-a", userMessage: "hi from a")
            try insertHistoryTurn(pool, id: "b1", timestamp: oldTs, sessionId: "heal-b", userMessage: "hi from b")
        }

        await MemorySelfHealDriver.runStageA()

        let known = await MemoryIndex.shared.knownChatHistoryIds()
        #expect(known.contains("a1"))
        #expect(known.contains("b1"))
    }

    @Test("Stage A respects idle cutoff — skips in-progress turns")
    func stageA_idleCutoffRespected() async throws {
        let (pool, appDir, previous) = try await MainActor.run { try installTempAppDB() }
        let memDir = try await makeMemoryDB()
        defer {
            Task { @MainActor in tearDownAppDB(pool: pool, dir: appDir, previous: previous) }
            Task { await MemoryIndex.shared._testReset(); try? FileManager.default.removeItem(at: memDir) }
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let active = Double(nowMs - 1_000)
        let stale = Double(nowMs - 10 * 60_000)
        try await MainActor.run {
            try insertHistoryTurn(pool, id: "eligible", timestamp: stale, sessionId: "sess", userMessage: "old")
            try insertHistoryTurn(pool, id: "inprogress", timestamp: active, sessionId: "sess", userMessage: "new")
        }

        await MemorySelfHealDriver.runStageA()

        let known = await MemoryIndex.shared.knownChatHistoryIds()
        #expect(known.contains("eligible"))
        #expect(known.contains("inprogress") == false)
    }

    @Test("Stage A indexes every scope (inbox + msg: + compose:)")
    func stageA_indexesEveryScope() async throws {
        let (pool, appDir, previous) = try await MainActor.run { try installTempAppDB() }
        let memDir = try await makeMemoryDB()
        defer {
            Task { @MainActor in tearDownAppDB(pool: pool, dir: appDir, previous: previous) }
            Task { await MemoryIndex.shared._testReset(); try? FileManager.default.removeItem(at: memDir) }
        }

        let oldTs = Double(Int64(Date().timeIntervalSince1970 * 1000) - 10 * 60_000)
        try await MainActor.run {
            try insertHistoryTurn(pool, id: "inbox-ok", timestamp: oldTs, sessionId: "inbox", userMessage: "x")
            try insertHistoryTurn(pool, id: "msg-ok", timestamp: oldTs, sessionId: "msg:acc1:abc", userMessage: "y")
            try insertHistoryTurn(pool, id: "compose-ok", timestamp: oldTs, sessionId: "compose:new:xyz", userMessage: "z")
        }

        await MemorySelfHealDriver.runStageA()

        let known = await MemoryIndex.shared.knownChatHistoryIds()
        #expect(known.contains("inbox-ok"))
        #expect(known.contains("msg-ok"))
        #expect(known.contains("compose-ok"))
    }

    @Test("Stage A filters non-normal / unknown-role turns")
    func stageA_filtersNonAllowlisted() async throws {
        let (pool, appDir, previous) = try await MainActor.run { try installTempAppDB() }
        let memDir = try await makeMemoryDB()
        defer {
            Task { @MainActor in tearDownAppDB(pool: pool, dir: appDir, previous: previous) }
            Task { await MemoryIndex.shared._testReset(); try? FileManager.default.removeItem(at: memDir) }
        }

        let oldTs = Double(Int64(Date().timeIntervalSince1970 * 1000) - 10 * 60_000)
        try await MainActor.run {
            try insertHistoryTurn(pool, id: "greet", timestamp: oldTs, sessionId: "s", type: "greeting")
            try insertHistoryTurn(pool, id: "sess-break", timestamp: oldTs, sessionId: "s", type: "session_break")
            try insertHistoryTurn(pool, id: "tool-turn", timestamp: oldTs, sessionId: "s", role: "tool", type: "normal")
            try insertHistoryTurn(pool, id: "normal-user", timestamp: oldTs, sessionId: "s", role: "user", userMessage: "real", type: "normal")
        }

        await MemorySelfHealDriver.runStageA()
        let known = await MemoryIndex.shared.knownChatHistoryIds()
        #expect(known == Set(["normal-user"]))
    }

    @Test("Stage A is idempotent — double-run produces no re-index")
    func stageA_idempotent() async throws {
        let (pool, appDir, previous) = try await MainActor.run { try installTempAppDB() }
        let memDir = try await makeMemoryDB()
        defer {
            Task { @MainActor in tearDownAppDB(pool: pool, dir: appDir, previous: previous) }
            Task { await MemoryIndex.shared._testReset(); try? FileManager.default.removeItem(at: memDir) }
        }

        let oldTs = Double(Int64(Date().timeIntervalSince1970 * 1000) - 10 * 60_000)
        try await MainActor.run {
            try insertHistoryTurn(pool, id: "dup", timestamp: oldTs, sessionId: "s", userMessage: "once")
        }
        await MemorySelfHealDriver.runStageA()
        let firstEpoch = await MemoryIndex.shared._testMetaRow(chatHistoryId: "dup")?.indexEpoch
        #expect(firstEpoch == 1)

        await MemorySelfHealDriver.runStageA()
        let secondEpoch = await MemoryIndex.shared._testMetaRow(chatHistoryId: "dup")?.indexEpoch
        // Second run must not re-index (set-diff is empty) → epoch stays 1.
        #expect(secondEpoch == 1)
        #expect(await MemoryIndex.shared._testMetaRowCount() == 1)
    }

    // MARK: - Stage A: B − allChatHistory → delete orphans

    @Test("Stage A deletes memory.db orphans whose chatHistoryId is not in chatHistory")
    func stageA_deletesOrphans() async throws {
        let (pool, appDir, previous) = try await MainActor.run { try installTempAppDB() }
        let memDir = try await makeMemoryDB()
        defer {
            Task { @MainActor in tearDownAppDB(pool: pool, dir: appDir, previous: previous) }
            Task { await MemoryIndex.shared._testReset(); try? FileManager.default.removeItem(at: memDir) }
        }

        // Seed memory.db with two rows — one also in chatHistory, one orphan.
        let oldTs = Double(Int64(Date().timeIntervalSince1970 * 1000) - 10 * 60_000)
        try await MainActor.run {
            try insertHistoryTurn(pool, id: "kept", timestamp: oldTs, sessionId: "s", userMessage: "keep me")
        }
        await MemoryIndex.shared.indexTurn(chatHistoryId: "kept", sessionId: "s", role: "user", dateMs: Int64(oldTs), text: "keep me")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "orphan", sessionId: "s", role: "user", dateMs: Int64(oldTs), text: "delete me")

        #expect(await MemoryIndex.shared.knownChatHistoryIds() == Set(["kept", "orphan"]))

        await MemorySelfHealDriver.runStageA()
        let known = await MemoryIndex.shared.knownChatHistoryIds()
        #expect(known == Set(["kept"]))
    }

    @Test("Stage A does NOT delete memory.db rows for still-active (within idle cutoff) chatHistory turns")
    func stageA_preservesActiveRowsInMemoryDB() async throws {
        let (pool, appDir, previous) = try await MainActor.run { try installTempAppDB() }
        let memDir = try await makeMemoryDB()
        defer {
            Task { @MainActor in tearDownAppDB(pool: pool, dir: appDir, previous: previous) }
            Task { await MemoryIndex.shared._testReset(); try? FileManager.default.removeItem(at: memDir) }
        }

        // "active" chatHistory row (within idle cutoff) AND indexed in memory.db via appendTurn.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let active = Double(nowMs - 1_000)
        try await MainActor.run {
            try insertHistoryTurn(pool, id: "active", timestamp: active, sessionId: "s", userMessage: "still active")
        }
        await MemoryIndex.shared.indexTurn(chatHistoryId: "active", sessionId: "s", role: "user", dateMs: Int64(active), text: "still active")

        await MemorySelfHealDriver.runStageA()
        // Active row is NOT in `eligibleA` (within cutoff), but it IS in `allChatHistory` →
        // orphan detection must not delete it.
        let known = await MemoryIndex.shared.knownChatHistoryIds()
        #expect(known.contains("active"))
    }

    // MARK: - Stage A + B together

    @Test("runStageAPlusB: turns FTS+meta indexed and enqueued for embedding")
    func stageAPlusB_endToEnd() async throws {
        let (pool, appDir, previous) = try await MainActor.run { try installTempAppDB() }
        let memDir = try await makeMemoryDB()
        defer {
            Task { @MainActor in tearDownAppDB(pool: pool, dir: appDir, previous: previous) }
            Task { await MemoryIndex.shared._testReset(); try? FileManager.default.removeItem(at: memDir) }
        }

        let oldTs = Double(Int64(Date().timeIntervalSince1970 * 1000) - 10 * 60_000)
        try await MainActor.run {
            try insertHistoryTurn(pool, id: "e2e", timestamp: oldTs, sessionId: "s", userMessage: "hello e2e")
        }

        await MemorySelfHealDriver.runStageAPlusB()

        let row = await MemoryIndex.shared._testMetaRow(chatHistoryId: "e2e")
        #expect(row != nil)
        #expect(row?.embeddingComplete == 0)

        let pending = await MemoryIndex.shared.pendingEmbeddingChatHistoryIds(limit: 10)
        #expect(pending.contains("e2e"))
    }
}
