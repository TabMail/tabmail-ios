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

        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        // Close before unlinking, and install the defer BEFORE the fallible
        // `AppDatabase` init so a throw there still closes the pool.
        defer { TestDatabaseTeardown.retire(pool: pool, directory: dir) }
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
    private func installMemoryIndex() async throws -> (pool: DatabasePool, dir: URL) {
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
        return (pool, dir)
    }

    private func cleanupMemoryIndex(pool: DatabasePool, dir: URL) async {
        await MemoryIndex.shared._testReset()
        await MemorySearchCache.shared.reset()
        TestDatabaseTeardown.retire(pool: pool, directory: dir)
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

    /// "What have we discussed" names no topic: with no query (missing, empty,
    /// blank or not a string) the tool lists the most recent turns, newest
    /// first, as TB's memory_search does.
    @Test("No query lists the most recent turns, newest first", arguments: [
        [String: JSONValue](),
        ["query": .string("")],
        ["query": .string("   ")],
        ["query": .string("\n")],
        ["query": .string("\r\n")],
        ["query": .string(" \t\n")],
        ["query": .int(42)],
        ["query": .bool(true)],
    ])
    func noQueryListsRecent(arguments: [String: JSONValue]) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        await MemoryIndex.shared.indexTurn(chatHistoryId: "old", sessionId: "s1", role: "user", dateMs: now - 3 * 86_400_000, text: "oldest_turn_marker")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "mid", sessionId: "s2", role: "user", dateMs: now - 2 * 86_400_000, text: "middle_turn_marker")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "new", sessionId: "s3", role: "user", dateMs: now - 86_400_000, text: "newest_turn_marker")

        let tool = try makeTool()
        let result = try await tool.execute(arguments: arguments)
        #expect(!result.contains("missing query"))
        #expect(result.contains("\"totalItems\":3") || result.contains("\"totalItems\": 3"))
        let newest = try #require(result.range(of: "newest_turn_marker"))
        let middle = try #require(result.range(of: "middle_turn_marker"))
        let oldest = try #require(result.range(of: "oldest_turn_marker"))
        #expect(newest.lowerBound < middle.lowerBound)
        #expect(middle.lowerBound < oldest.lowerBound)
    }

    // MARK: - No-query listing: what it lists

    /// The turns listed on one page: each one's timestamp and role tag.
    private func listed(_ result: String) throws -> [(dateMs: Int64, role: String)] {
        let data = try #require(result.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = try #require(object["results"] as? String)
        let pattern = try NSRegularExpression(pattern: #"\[timestamp: (\d+)\] [^\n]* \((USER|AGENT)\)"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let ms = Range(match.range(at: 1), in: text), let role = Range(match.range(at: 2), in: text), let dateMs = Int64(text[ms]) else { return nil }
            return (dateMs, String(text[role]))
        }
    }

    /// Noon UTC three days ago, to the second: turns an hour apart from it stay
    /// within one UTC day, so a bound cut to midnight shows.
    private func noonUTCThreeDaysAgo() -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.startOfDay(for: Date().addingTimeInterval(-3 * 86_400))
        return Int64(day.timeIntervalSince1970 + 12 * 3_600) * 1000
    }

    private func isoString(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).iso8601String()
    }

    private func withDemoActive(_ active: Bool, _ body: () async throws -> Void) async rethrows {
        await MainActor.run { DemoModeStore.shared.isActive = active }
        do {
            try await body()
        } catch {
            await MainActor.run { DemoModeStore.shared.isActive = false }
            throw error
        }
        await MainActor.run { DemoModeStore.shared.isActive = false }
    }

    /// With no query the tool pages every turn of the mode in use, newest first:
    /// user and agent turns with their own timestamps and roles (what memory_read
    /// anchors on), a turn kept with no session included, demo turns left out.
    /// Its pages come from the one listing of the user turn: a turn written
    /// between pages shows only once the next user turn resets the listing.
    @Test("No query pages the mode's turns, newest first, with their timestamps and roles")
    func noQueryPagesTurnsWithTimestampsAndRoles() async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        var expected: [(dateMs: Int64, role: String)] = []
        for i in 0..<12 {
            let dateMs = base + Int64(i) * 3_600_000
            let role = i % 2 == 0 ? "user" : "assistant"
            await MemoryIndex.shared.indexTurn(chatHistoryId: "t\(i)", sessionId: i == 3 ? nil : "s\(i / 4)", role: role, dateMs: dateMs, text: "turn \(i)")
            expected.insert((dateMs, role == "user" ? "USER" : "AGENT"), at: 0)
        }
        await MemoryIndex.shared.indexTurn(chatHistoryId: "demo", sessionId: "demo:s", role: "user", dateMs: base + 20 * 3_600_000, text: "demo turn")

        let tool = try makeTool()
        let pageSize = SearchConfig.memoryPageSizeDefault
        var shown: [(dateMs: Int64, role: String)] = []
        for page in 1...3 {
            if page == 2 {
                // Written mid-listing: not on the listing's later pages.
                await MemoryIndex.shared.indexTurn(chatHistoryId: "late", sessionId: "s9", role: "user", dateMs: base + 15 * 3_600_000, text: "late turn")
            }
            shown += try listed(try await tool.execute(arguments: ["page_index": .int(page)]))
        }
        #expect(shown.map(\.dateMs) == expected.map(\.dateMs))
        #expect(shown.map(\.role) == expected.map(\.role))
        #expect(pageSize * 3 >= expected.count)

        // The next user turn lists afresh: the late turn leads.
        await MemorySearchCache.shared.reset()
        let next = try listed(try await tool.execute(arguments: [:]))
        #expect(next.first?.dateMs == base + 15 * 3_600_000)
    }

    @Test("No query in demo mode lists only demo turns")
    func noQueryInDemoModeListsDemoTurns() async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        await MemoryIndex.shared.indexTurn(chatHistoryId: "real", sessionId: "s", role: "user", dateMs: base + 3_600_000, text: "real turn")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "legacy", sessionId: nil, role: "user", dateMs: base + 2 * 3_600_000, text: "legacy turn")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "demo1", sessionId: "demo:a", role: "user", dateMs: base, text: "demo one")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "demo2", sessionId: "demo:b", role: "assistant", dateMs: base - 3_600_000, text: "demo two")

        try await withDemoActive(true) {
            let demo = try listed(try await makeTool().execute(arguments: [:]))
            #expect(demo.map(\.dateMs) == [base, base - 3_600_000])
            #expect(demo.map(\.role) == ["USER", "AGENT"])
        }
    }

    /// The dates asked keep the listing to them, to the second for a full
    /// timestamp; a date-only end includes its whole day.
    @Test("No query lists only the turns within the dates asked", arguments: [
        ("start", 2, nil),
        ("end", nil, 5),
        ("start and end", 2, 5),
    ] as [(String, Int?, Int?)])
    func noQueryKeepsToTheDatesAsked(name: String, from: Int?, to: Int?) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        let hour: Int64 = 3_600_000
        let dates = (0..<10).map { base + Int64($0) * hour }
        for (i, dateMs) in dates.enumerated() {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "t\(i)", sessionId: "s", role: "user", dateMs: dateMs, text: "turn \(i)")
        }

        var arguments: [String: JSONValue] = [:]
        // Half an hour around the turns, so a bound cut to midnight changes what is listed.
        if let from { arguments["from_date"] = .string(isoString(dates[from] - hour / 2)) }
        if let to { arguments["to_date"] = .string(isoString(dates[to] + hour / 2)) }
        let inWindow = dates.indices.filter { i in (from.map { i >= $0 } ?? true) && (to.map { i <= $0 } ?? true) }
        let expected = inWindow.reversed().map { dates[$0] }

        let tool = try makeTool()
        let first = try await tool.execute(arguments: arguments)
        var shown = try listed(first).map(\.dateMs)
        // Every later page too (the last page repeats for a page past it).
        if first.contains("page_index: 2") {
            shown += try listed(try await tool.execute(arguments: arguments.merging(["page_index": .int(2)]) { $1 })).map(\.dateMs)
        }
        #expect(shown == expected, "\(name)")
    }

    @Test("No query with a date-only end lists that whole day")
    func noQueryDateOnlyEndIncludesTheDay() async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        await MemoryIndex.shared.indexTurn(chatHistoryId: "evening", sessionId: "s", role: "user", dateMs: base + 10 * 3_600_000, text: "evening")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "nextDay", sessionId: "s", role: "user", dateMs: base + 14 * 3_600_000, text: "next day")
        let day = String(isoString(base).prefix(10))

        let shown = try listed(try await makeTool().execute(arguments: ["to_date": .string(day)]))
        #expect(shown.map(\.dateMs) == [base + 10 * 3_600_000])
    }

    /// A query still searches: a newer turn that doesn't match is not listed.
    @Test("A query finds its matches, not the most recent turns")
    func queryFindsMatchesNotRecent() async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        await MemoryIndex.shared.indexTurn(chatHistoryId: "match", sessionId: "s", role: "user", dateMs: base, text: "the quarterly budget review")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "newer", sessionId: "s", role: "user", dateMs: base + 3_600_000, text: "lunch plans")

        let shown = try listed(try await makeTool().execute(arguments: ["query": .string("budget")]))
        #expect(shown.map(\.dateMs) == [base])
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
                "from_date": .string("2024-01-01"),
                "to_date": .string("2024-12-31"),
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
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        await MemoryIndex.shared.indexTurn(chatHistoryId: "u1", sessionId: "s", role: "user", dateMs: 1000, text: "please add kylemcgregor to the contacts")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "a1", sessionId: "s", role: "assistant", dateMs: 1100, text: "Added kylemcgregor successfully")

        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["query": .string("kylemcgregor")])
        #expect(result.contains("(USER)"))
        #expect(result.contains("(AGENT)"))
    }

    @Test("Regression: output contains no raw SQL type descriptions (GRDB pitfall)")
    func noSQLTypeLeakInOutput() async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

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
