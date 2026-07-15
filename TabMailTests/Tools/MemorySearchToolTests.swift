/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("MemorySearchTool", .serialized, .processGlobalState)
struct MemorySearchToolTests {

    /// Creates a MemorySearchTool with a file-backed DB, runs the body, then restores AppDatabase.shared.
    private func withTool(_ body: (MemorySearchTool) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)

        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        defer { AppDatabase.shared.withLock { $0 = previous } }

        let translator = MockChatIdTranslator()
        let ctx = ToolContext(db: pool, translator: translator)
        let tool = MemorySearchTool(context: ctx)
        try await body(tool)
    }

    /// Creates a fresh MemoryIndex pool for per-turn format tests.
    private func installMemoryIndex() async throws -> URL {
        await MemoryIndex.shared._testReset()
        await MemorySearchCache.shared.reset()
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
        return dir
    }

    private func cleanupMemoryIndex(_ dir: URL) async {
        await MemoryIndex.shared._testReset()
        await MemorySearchCache.shared.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Backwards-compatible helper for tests that just need the tool.
    private func makeTool() throws -> MemorySearchTool {
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
        return MemorySearchTool(context: ctx)
    }

    // MARK: - Argument Validation

    @Test("Missing query returns error")
    func missingQuery() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("error"))
        #expect(result.contains("missing query"))
    }

    @Test("Empty string query returns error")
    func emptyQuery() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["query": .string("")])
        #expect(result.contains("error"))
        #expect(result.contains("missing query"))
    }

    @Test("Whitespace-only query returns error")
    func whitespaceOnlyQuery() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["query": .string("   ")])
        #expect(result.contains("error"))
        #expect(result.contains("missing query"))
    }

    @Test("Non-string query type returns error")
    func nonStringQuery() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["query": .int(42)])
        #expect(result.contains("error"))
        #expect(result.contains("missing query"))
    }

    @Test("Bool query type returns error")
    func boolQuery() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["query": .bool(true)])
        #expect(result.contains("error"))
        #expect(result.contains("missing query"))
    }

    // MARK: - page_index Parsing

    @Test("page_index as int is accepted")
    func pageIndexInt() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "query": .string("hello"),
            "page_index": .int(1),
        ])
        #expect(!result.contains("missing query"))
    }

    @Test("page_index as string is accepted")
    func pageIndexString() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "query": .string("hello"),
            "page_index": .string("2"),
        ])
        #expect(!result.contains("missing query"))
    }

    @Test("Negative page_index clamped to 1")
    func negativePageIndex() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "query": .string("hello"),
            "page_index": .int(-5),
        ])
        #expect(!result.contains("missing query"))
    }

    @Test("Default page_index is 1")
    func defaultPageIndex() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["query": .string("hello")])
        #expect(!result.contains("missing query"))
    }

    // MARK: - Date Filter Parsing

    @Test("from_date and to_date accepted without crash")
    func dateFilters() async throws {
        try await withTool { tool in
            let result = try await tool.execute(arguments: [
                "query": .string("hello"),
                "from_date": .string(TestFixtureDate.iso8601Date(daysFromAnchor: -30)),
                "to_date": .string(TestFixtureDate.iso8601Date()),
            ])
            #expect(!result.contains("missing query"))
        }
    }

    @Test("Invalid from_date ignored gracefully")
    func invalidFromDate() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "query": .string("hello"),
            "from_date": .string("not-a-date"),
        ])
        #expect(!result.contains("missing query"))
    }

    // MARK: - Empty Results

    @Test("Valid query with no matching turns returns no results")
    func noMatchingTurns() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["query": .string("xyznonexistent")])
        #expect(result.contains("No relevant memories found"))
        #expect(result.contains("\"totalItems\":0") || result.contains("\"totalItems\": 0"))
    }

    // MARK: - Per-turn output format

    @Test("Per-turn output tags role as USER / AGENT")
    func perTurnOutputIncludesRoleTag() async throws {
        let memDir = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(memDir) } }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "u1", sessionId: "s", role: "user", dateMs: 1000, text: "please add kylemcgregor to the contacts")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "a1", sessionId: "s", role: "assistant", dateMs: 1100, text: "Added kylemcgregor successfully")

        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["query": .string("kylemcgregor")])
        #expect(result.contains("(USER)"))
        #expect(result.contains("(AGENT)"))
    }

    @Test("Regression: output contains no raw SQL type descriptions (GRDB pitfall)")
    func noSQLTypeLeakInOutput() async throws {
        let memDir = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(memDir) } }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "t1", sessionId: "s", role: "user", dateMs: 1000, text: "unique_leak_probe_token")

        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["query": .string("unique_leak_probe_token")])
        // Guard: the `formatted` string must resolve to Swift String, not GRDB.SQL.
        // If map closure return-type infers to SQL, ToolJSON.bridgeValue stringifies
        // its AST into the output. Caught by logmain.log 2026-04-22.
        #expect(result.contains("SQL(elements:") == false)
        #expect(result.contains("GRDB.SQL.Element") == false)
        #expect(result.contains("SQLExpression") == false)
    }

    // MARK: - Tool Name

    @Test("Tool name is memory_search")
    func toolName() throws {
        let tool = try makeTool()
        #expect(tool.name == "memory_search")
    }
}
