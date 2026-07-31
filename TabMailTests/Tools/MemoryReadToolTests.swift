/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("MemoryReadTool", .serialized, .processGlobalState)
struct MemoryReadToolTests {

    /// Creates a MemoryReadTool and installs a file-backed AppDatabase.shared.
    private func makeTool() throws -> MemoryReadTool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        AppDatabase.shared.withLock { $0 = appDb }

        let translator = MockChatIdTranslator()
        let ctx = ToolContext(db: pool, translator: translator)
        return MemoryReadTool(context: ctx)
    }

    private func installMemoryIndex() async throws -> (pool: DatabasePool, dir: URL) {
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

    private func cleanupMemoryIndex(pool: DatabasePool, dir: URL) async {
        await MemoryIndex.shared._testReset()
        TestDatabaseTeardown.retire(pool: pool, directory: dir)
    }

    // MARK: - Argument Validation

    @Test("Missing timestamp returns error")
    func missingTimestamp() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("error"))
        #expect(result.contains("Invalid or missing timestamp"))
    }

    @Test("Invalid timestamp type returns error")
    func invalidTimestampType() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["timestamp": .bool(true)])
        #expect(result.contains("error"))
        #expect(result.contains("Invalid or missing timestamp"))
    }

    @Test("Non-numeric string timestamp returns error")
    func nonNumericStringTimestamp() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["timestamp": .string("not-a-number")])
        #expect(result.contains("error"))
        #expect(result.contains("Invalid or missing timestamp"))
    }

    @Test("Integer timestamp accepted")
    func intTimestamp() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["timestamp": .int(1710000000000)])
        #expect(!result.contains("error"))
        #expect(result.contains("No conversation found") || result.contains("count"))
    }

    @Test("String timestamp accepted")
    func stringTimestamp() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["timestamp": .string("1710000000000")])
        #expect(!result.contains("error"))
        #expect(result.contains("No conversation found") || result.contains("count"))
    }

    // MARK: - Optional Parameter Parsing

    @Test("tolerance_minutes as int is accepted")
    func toleranceMinutesInt() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "timestamp": .int(1710000000000),
            "tolerance_minutes": .int(30),
        ])
        #expect(!result.contains("error"))
    }

    @Test("tolerance_minutes as string is accepted")
    func toleranceMinutesString() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "timestamp": .int(1710000000000),
            "tolerance_minutes": .string("30"),
        ])
        #expect(!result.contains("error"))
    }

    @Test("tolerance_minutes clamped to minimum 1")
    func toleranceMinutesClamped() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "timestamp": .int(1710000000000),
            "tolerance_minutes": .int(-5),
        ])
        #expect(!result.contains("error"))
    }

    @Test("max_turns as int is accepted")
    func maxTurnsInt() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "timestamp": .int(1710000000000),
            "max_turns": .int(5),
        ])
        #expect(!result.contains("error"))
    }

    @Test("max_turns as string is accepted")
    func maxTurnsString() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "timestamp": .int(1710000000000),
            "max_turns": .string("5"),
        ])
        #expect(!result.contains("error"))
    }

    @Test("max_turns clamped to minimum 1")
    func maxTurnsClamped() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "timestamp": .int(1710000000000),
            "max_turns": .int(0),
        ])
        #expect(!result.contains("error"))
    }

    // MARK: - Empty Result

    @Test("No matching turns returns TB-parity empty-string literal")
    func noMatchingTurns() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["timestamp": .int(1710000000000)])
        #expect(result == "No conversation found around this timestamp.")
    }

    // MARK: - v3 per-turn output format

    @Test("Output tags each turn with role (USER / AGENT) and date header")
    func perTurnOutputIncludesRoleAndDate() async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let t0: Int64 = 1_710_000_000_000
        await MemoryIndex.shared.indexTurn(chatHistoryId: "u1", sessionId: "s", role: "user", dateMs: t0, text: "please add jane")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "a1", sessionId: "s", role: "assistant", dateMs: t0 + 1000, text: "Added jane successfully")

        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "timestamp": .int(Int(t0)),
            "tolerance_minutes": .int(5),
            "max_turns": .int(10),
        ])
        #expect(result.contains("(USER)"))
        #expect(result.contains("(AGENT)"))
        #expect(result.contains("please add jane"))
        #expect(result.contains("Added jane"))
        // Guard against GRDB SQL type leak (see PROJECT_MEMORY.md pitfall).
        #expect(result.contains("SQL(elements:") == false)
        #expect(result.contains("GRDB.SQL.Element") == false)
    }

    @Test("Context window is session-bounded — does not leak adjacent sessions")
    func contextWindowBoundedToSession() async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let t0: Int64 = 1_710_000_000_000
        // Session A (target): 3 turns clustered around t0.
        for i in 0..<3 {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "A\(i)", sessionId: "A", role: "user", dateMs: t0 + Int64(i * 1000), text: "A_body_\(i)")
        }
        // Session B: interleaved adjacent times — must NOT appear in window.
        for i in 0..<3 {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "B\(i)", sessionId: "B", role: "user", dateMs: t0 + Int64(i * 1000) + 500, text: "B_body_\(i)")
        }

        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "timestamp": .int(Int(t0)),
            "tolerance_minutes": .int(5),
            "max_turns": .int(20),
        ])
        #expect(result.contains("A_body_0"))
        #expect(result.contains("A_body_2"))
        #expect(result.contains("B_body_0") == false)
        #expect(result.contains("B_body_1") == false)
    }

    // MARK: - Tool Name

    @Test("Tool name is memory_read")
    func toolName() throws {
        let tool = try makeTool()
        #expect(tool.name == "memory_read")
    }
}
