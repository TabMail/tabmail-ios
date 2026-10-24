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
    /// `readers` caps the pool's readers (one lets a test hold a search mid-read).
    private func installMemoryIndex(readers: Int? = nil) async throws -> (pool: DatabasePool, dir: URL) {
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
        if let readers { config.maximumReaderCount = readers }
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
    /// A query that every turn matches equally pages the same way, from its one fetch.
    @Test("No query, or a query, pages the mode's turns, newest first, with their timestamps and roles",
          arguments: [nil, "turn"] as [String?])
    func noQueryPagesTurnsWithTimestampsAndRoles(query: String?) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        // Turns an hour apart from three days ago, filling two pages and part of a third.
        let base = noonUTCThreeDaysAgo()
        let pageSize = SearchConfig.memorySearchPageSize
        let count = 2 * pageSize + 2
        var expected: [(dateMs: Int64, role: String)] = []
        for i in 0..<count {
            let dateMs = base + Int64(i) * 3_600_000
            let role = i % 2 == 0 ? "user" : "assistant"
            await MemoryIndex.shared.indexTurn(chatHistoryId: "t\(i)", sessionId: i == 3 ? nil : "s\(i / 4)", role: role, dateMs: dateMs, text: "turn \(i)")
            expected.insert((dateMs, role == "user" ? "USER" : "AGENT"), at: 0)
        }
        await DemoRunFixture.indexTurn(chatHistoryId: "demo", sessionId: "demo:s", role: "user", dateMs: base + Int64(count + 1) * 3_600_000, text: "demo turn")

        let tool = try makeTool()
        let late = base + Int64(count) * 3_600_000
        var shown: [(dateMs: Int64, role: String)] = []
        for page in 1...3 {
            if page == 2 {
                // Written mid-listing, newest of all: not on the listing's later pages.
                await MemoryIndex.shared.indexTurn(chatHistoryId: "late", sessionId: "s9", role: "user", dateMs: late, text: "late turn")
            }
            var arguments: [String: JSONValue] = ["page_index": .int(page)]
            if let query { arguments["query"] = .string(query) }
            shown += try listed(try await tool.execute(arguments: arguments))
        }
        #expect(shown.map(\.dateMs) == expected.map(\.dateMs))
        #expect(shown.map(\.role) == expected.map(\.role))

        // The next user turn lists afresh: the late turn leads.
        await MemorySearchCache.shared.reset()
        let next = try listed(try await tool.execute(arguments: query.map { ["query": .string($0)] } ?? [:]))
        #expect(next.first?.dateMs == late)
    }

    /// A blank query is no query, for its pages too: page one asked with a
    /// line break and later pages with no query come from the one listing,
    /// every turn once, a turn written between pages left out.
    @Test("A blank query and no query page one listing", arguments: ["\n", "\r\n", " \t\n"])
    func blankQueryPagesTheOneListing(blank: String) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        let pageSize = SearchConfig.memorySearchPageSize
        let count = pageSize + 1
        for i in 0..<count {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "t\(i)", sessionId: "s", role: "user", dateMs: base + Int64(i) * 3_600_000, text: "turn \(i)")
        }
        let expected = (0..<count).reversed().map { base + Int64($0) * 3_600_000 }

        let tool = try makeTool()
        var shown = try listed(try await tool.execute(arguments: ["query": .string(blank)])).map(\.dateMs)
        await MemoryIndex.shared.indexTurn(chatHistoryId: "late", sessionId: "s", role: "user", dateMs: base + Int64(count) * 3_600_000, text: "late turn")
        shown += try listed(try await tool.execute(arguments: ["page_index": .int(2)])).map(\.dateMs)
        #expect(shown == expected)
    }

    /// A search still running from an earlier turn never fills the next turn's
    /// listing: a real-history search held mid-read while demo mode starts and
    /// the next turn begins finds real history for its own (canceled) turn, and
    /// the demo turn's listing then shows demo turns only.
    @Test("A search from before a turn's reset never fills that turn's listing", arguments: ["", "budget"])
    func staleSearchNeverFillsTheNextTurn(query: String) async throws {
        let (memPool, memDir) = try await installMemoryIndex(readers: 1)
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        await MemoryIndex.shared.indexTurn(chatHistoryId: "real", sessionId: "s", role: "user", dateMs: base + 3_600_000, text: "budget real_history_marker")
        await DemoRunFixture.indexTurn(chatHistoryId: "demo", sessionId: "demo:a", role: "user", dateMs: base, text: "budget demo_history_marker")
        // Older turns of each mode that don't match the query.
        for i in 0..<4 {
            await DemoRunFixture.indexTurn(chatHistoryId: "other\(i)", sessionId: i % 2 == 0 ? "s" : "demo:a", role: "user", dateMs: base - Int64(i + 1) * 3_600_000, text: "lunch plans \(i)")
        }

        // Hold the one reader, so the search started next waits mid-read.
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = try? memPool.read { _ in
                    held.resume()
                    release.wait()
                }
                finished.signal()
            }
        }
        let tool = try makeTool()
        let arguments: [String: JSONValue] = query.isEmpty ? [:] : ["query": .string(query)]
        let stale = Task { try await tool.execute(arguments: arguments) }
        // Long enough for it to have read real scope and be waiting on the reader:
        // if not, its own result below holds no real history and the test fails.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        try await withDemoActive(true) {
            await MemorySearchCache.shared.reset()
            release.signal()
            let old = try await stale.value
            #expect(old.contains("real_history_marker"), "the held search read real history")
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    finished.wait()
                    done.resume()
                }
            }

            let demo = try await tool.execute(arguments: arguments)
            #expect(demo.contains("demo_history_marker"))
            #expect(!demo.contains("real_history_marker"))
        }
    }

    @Test("No query in demo mode lists only demo turns")
    func noQueryInDemoModeListsDemoTurns() async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        await MemoryIndex.shared.indexTurn(chatHistoryId: "real", sessionId: "s", role: "user", dateMs: base + 3_600_000, text: "real turn")
        await MemoryIndex.shared.indexTurn(chatHistoryId: "legacy", sessionId: nil, role: "user", dateMs: base + 2 * 3_600_000, text: "legacy turn")
        await DemoRunFixture.indexTurn(chatHistoryId: "demo1", sessionId: "demo:a", role: "user", dateMs: base, text: "demo one")
        await DemoRunFixture.indexTurn(chatHistoryId: "demo2", sessionId: "demo:b", role: "assistant", dateMs: base - 3_600_000, text: "demo two")

        try await withDemoActive(true) {
            let demo = try listed(try await makeTool().execute(arguments: [:]))
            #expect(demo.map(\.dateMs) == [base, base - 3_600_000])
            #expect(demo.map(\.role) == ["USER", "AGENT"])
        }
    }

    /// Hits kept for one mode are never served in the other (ADR-IOS-038). A
    /// compose edit runs memory_search with no chat turn starting, so nothing
    /// resets the listing between the calls: warmed in normal mode, then in demo
    /// mode, then in normal mode again, each call shows only its own mode's turns.
    @Test("A listing never crosses into or out of demo mode", arguments: ["", "budget"])
    func listingKeepsToItsMode(query: String) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        await MemoryIndex.shared.indexTurn(chatHistoryId: "real", sessionId: "s", role: "user", dateMs: base + 3_600_000, text: "budget real_history_marker")
        await DemoRunFixture.indexTurn(chatHistoryId: "demo", sessionId: "demo:a", role: "user", dateMs: base, text: "budget demo_history_marker")
        let tool = try makeTool()
        let arguments: [String: JSONValue] = query.isEmpty ? [:] : ["query": .string(query)]

        let real = try await tool.execute(arguments: arguments)
        #expect(real.contains("real_history_marker"))
        #expect(!real.contains("demo_history_marker"))
        try await withDemoActive(true) {
            let demo = try await tool.execute(arguments: arguments)
            #expect(demo.contains("demo_history_marker"))
            #expect(!demo.contains("real_history_marker"))
        }
        let back = try await tool.execute(arguments: arguments)
        #expect(back.contains("real_history_marker"))
        #expect(!back.contains("demo_history_marker"))
    }

    /// The two owners of the demo's memory cleanup: leaving the demo, and the
    /// leftover wipe a demo start runs (after a force-quit the launch wipe clears
    /// the main database only).
    enum DemoCleanup: String, CaseIterable, Sendable {
        case exit
        case leftoverWipe
    }

    private func chatTurn(id: String, sessionId: String, dateMs: Int64, text: String) -> ChatTurn {
        ChatTurn(
            id: id, timestamp: Double(dateMs), role: "user",
            content: text, userMessage: text,
            type: "normal", chars: text.count, renderedContent: nil,
            sessionId: sessionId, remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
    }

    /// Gives the real and the demo turn a vector each, so the cleanup has all
    /// three stores to delete from.
    private func embedRealAndDemo() async {
        let vector = [Float](repeating: 0.5, count: SearchConfig.embeddingDims)
        let stored = await MemoryIndex.shared.storeEmbeddings([
            (chatHistoryId: "real", observedEpoch: 1, embedding: vector),
            (chatHistoryId: "demo", observedEpoch: 1, embedding: vector),
        ])
        #expect(Set(stored.committed) == ["real", "demo"])
    }

    /// The rowids each memory store holds: the turns, their keyword index and their vectors.
    private func storeRowids(_ pool: DatabasePool) throws -> [Set<Int64>] {
        try pool.read { db in
            try ["memory_meta", "memory_fts", "memory_vec"].map { table in
                Set(try Int64.fetchAll(db, sql: "SELECT rowid FROM \(table)"))
            }
        }
    }

    /// The rowid of the turn with this id.
    private func rowid(of chatHistoryId: String, _ pool: DatabasePool) throws -> Int64 {
        try #require(try pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT rowid FROM memory_meta WHERE chatHistoryId = ?", arguments: [chatHistoryId])
        })
    }

    /// Demo turns the demo's cleanup removes are gone from memory_search for good,
    /// though a listing had kept them: the next demo lists none of them, from the
    /// kept listing or afresh, and real history stays.
    @Test("Demo turns the demo's cleanup removes are never listed again", arguments: ["", "budget"], DemoCleanup.allCases)
    func cleanedDemoTurnsAreNeverListedAgain(query: String, cleanup: DemoCleanup) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        try await withTool { tool in
            let base = noonUTCThreeDaysAgo()
            _ = try await ChatStore.shared.appendTurn(chatTurn(id: "real", sessionId: "s", dateMs: base + 3_600_000, text: "budget real_history_marker"), admission: nil)
            _ = try await DemoRunFixture.appendTurn(chatTurn(id: "demo", sessionId: "demo:a", dateMs: base, text: "budget demo_history_marker"))
            #expect(await MemoryIndex.shared.knownChatHistoryIds() == ["real", "demo"])
            await embedRealAndDemo()
            let realRow = try rowid(of: "real", memPool)
            let demoRow = try rowid(of: "demo", memPool)
            #expect(try storeRowids(memPool) == Array(repeating: [realRow, demoRow], count: 3))
            let arguments: [String: JSONValue] = query.isEmpty ? [:] : ["query": .string(query)]

            try await withDemoActive(true) {
                let warmed = try await tool.execute(arguments: arguments)
                #expect(warmed.contains("demo_history_marker"))
            }
            switch cleanup {
            case .exit:
                await MainActor.run { DemoModeStore.shared.isActive = true }
                await DemoModeService.shared.exit()
                #expect(await MainActor.run { DemoModeStore.shared.isActive } == false)
            case .leftoverWipe:
                try await DemoModeService.purgeOrphanedDemoData()
            }
            #expect(await MemoryIndex.shared.knownChatHistoryIds() == ["real"])
            // The demo turn is deleted from every store, its text and vector too.
            #expect(try storeRowids(memPool) == Array(repeating: [realRow], count: 3))

            try await withDemoActive(true) {
                let kept = try await tool.execute(arguments: arguments)
                #expect(!kept.contains("demo_history_marker"))
                #expect(!kept.contains("real_history_marker"))
                let fresh = try await tool.execute(arguments: ["query": .string("demo_history_marker")])
                #expect(!fresh.contains("demo_history_marker"))
            }
            let real = try await tool.execute(arguments: arguments)
            #expect(real.contains("real_history_marker"))
        }
    }

    /// A demo turns on only once the last demo's memory turns are gone: when the
    /// wipe works the new demo lists none of them and real history stays; when
    /// it fails the demo stays off (and starts once the wipe works).
    @Test("A demo turns on only once the last demo's memory turns are gone", arguments: ["", "budget"], [false, true])
    func demoStartsOnlyOverWipedMemory(query: String, wipeFails: Bool) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        try await withTool { tool in
            let base = noonUTCThreeDaysAgo()
            _ = try await ChatStore.shared.appendTurn(chatTurn(id: "real", sessionId: "s", dateMs: base + 3_600_000, text: "budget real_history_marker"), admission: nil)
            _ = try await DemoRunFixture.appendTurn(chatTurn(id: "demo", sessionId: "demo:a", dateMs: base, text: "budget demo_history_marker"))
            #expect(await MemoryIndex.shared.knownChatHistoryIds() == ["real", "demo"])
            await embedRealAndDemo()
            let realRow = try rowid(of: "real", memPool)
            let demoRow = try rowid(of: "demo", memPool)
            #expect(try storeRowids(memPool) == Array(repeating: [realRow, demoRow], count: 3))
            let arguments: [String: JSONValue] = query.isEmpty ? [:] : ["query": .string(query)]
            try await withDemoActive(true) {
                let warmed = try await tool.execute(arguments: arguments)
                #expect(warmed.contains("demo_history_marker"))
            }

            if wipeFails {
                try await memPool.write { db in
                    try db.execute(sql: "CREATE TRIGGER refuse_demo_wipe BEFORE DELETE ON memory_meta BEGIN SELECT RAISE(ABORT, 'refused'); END")
                }
                await #expect(throws: DemoError.self) { try await DemoModeService.shared.activate() }
                #expect(await MainActor.run { DemoModeStore.shared.isActive } == false, "the demo stayed off")
                #expect(await MemoryIndex.shared.knownChatHistoryIds().contains("demo"), "the wipe really failed")
                #expect(try storeRowids(memPool) == Array(repeating: [realRow, demoRow], count: 3), "a failed wipe deletes nothing")
                try await memPool.write { db in try db.execute(sql: "DROP TRIGGER refuse_demo_wipe") }
            }

            try await DemoModeService.shared.activate()
            let active = await MainActor.run { DemoModeStore.shared.isActive }
            await MainActor.run { DemoModeStore.shared.isActive = false }
            #expect(active)
            #expect(await MemoryIndex.shared.knownChatHistoryIds() == ["real"])
            #expect(try storeRowids(memPool) == Array(repeating: [realRow], count: 3))

            try await withDemoActive(true) {
                let kept = try await tool.execute(arguments: arguments)
                #expect(!kept.contains("demo_history_marker"))
                #expect(!kept.contains("real_history_marker"))
                let fresh = try await tool.execute(arguments: ["query": .string("demo_history_marker")])
                #expect(!fresh.contains("demo_history_marker"))
            }
            let real = try await tool.execute(arguments: arguments)
            #expect(real.contains("real_history_marker"))
        }
    }

    /// The two writes a chat append makes after its demo's cleanup may have run.
    enum LateDemoWriter: String, CaseIterable, Sendable {
        /// The chat-history commit itself (a canceled chat task, compose's own
        /// user-turn persistence).
        case commit
        /// The memory.db write after a commit that landed before the cleanup.
        case memoryIndex
    }

    /// A chat write still running from a demo that has ended can't bring its
    /// turn back, even once the next demo has started over a confirmed purge:
    /// the turn's source row is gone, and no derived row is written, so neither
    /// search form finds its text. The new demo's own turns still write (#231).
    @Test("A demo's late chat writes can't bring its turns back in the next demo", arguments: ["", "budget"], LateDemoWriter.allCases)
    func lateDemoWritesCantReturn(query: String, writer: LateDemoWriter) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        try await withTool { tool in
            let base = noonUTCThreeDaysAgo()
            _ = try await ChatStore.shared.appendTurn(chatTurn(id: "real", sessionId: "s", dateMs: base + 3_600_000, text: "budget real_history_marker"), admission: nil)
            let arguments: [String: JSONValue] = query.isEmpty ? [:] : ["query": .string(query)]

            // The first demo writes a turn, keeping its admission as a chat task does.
            let firstRun = await MainActor.run { () -> DemoModeStore.Admission? in
                DemoModeStore.shared.isActive = true
                return DemoModeStore.shared.chatAdmission
            }
            let demoTurn = chatTurn(id: "demo", sessionId: "demo:a", dateMs: base, text: "budget demo_history_marker")
            _ = try await ChatStore.shared.appendTurn(demoTurn, admission: firstRun)
            #expect(await MemoryIndex.shared.knownChatHistoryIds() == ["real", "demo"])

            // It ends, and the next demo starts over a confirmed purge.
            await DemoModeService.shared.exit()
            try await DemoModeService.shared.activate()
            #expect(await MainActor.run { DemoModeStore.shared.isActive })
            #expect(try await ChatStore.shared.allHistoryTurnIds() == ["real"], "the source row is deleted")
            #expect(await MemoryIndex.shared.knownChatHistoryIds() == ["real"])

            // The first demo's writer is released now.
            switch writer {
            case .commit:
                let late = chatTurn(id: "demo-late", sessionId: "demo:a", dateMs: base + 60_000, text: "budget demo_history_marker")
                await #expect(throws: ChatStore.DemoTurnRefused.self) {
                    try await ChatStore.shared.appendTurn(late, admission: firstRun)
                }
            case .memoryIndex:
                await MemoryIndex.shared.indexTurn(
                    chatHistoryId: demoTurn.id, sessionId: demoTurn.sessionId, role: demoTurn.role,
                    dateMs: base, text: "budget demo_history_marker", admission: firstRun)
            }

            #expect(try await ChatStore.shared.allHistoryTurnIds() == ["real"])
            #expect(await MemoryIndex.shared.knownChatHistoryIds() == ["real"])
            let realRow = try rowid(of: "real", memPool)
            #expect(Array(try storeRowids(memPool).prefix(2)) == [[realRow], [realRow]], "no keyword or turn row for the demo")
            let listed = try await tool.execute(arguments: arguments)
            #expect(!listed.contains("demo_history_marker"))
            let searched = try await tool.execute(arguments: ["query": .string("demo_history_marker")])
            #expect(!searched.contains("demo_history_marker"))

            // The running demo's own turns are still written.
            let secondRun = await MainActor.run { DemoModeStore.shared.chatAdmission }
            #expect(secondRun != nil && secondRun != firstRun)
            _ = try await ChatStore.shared.appendTurn(chatTurn(id: "demo-now", sessionId: "demo:b", dateMs: base + 120_000, text: "budget current_demo_marker"), admission: secondRun)
            #expect(await MemoryIndex.shared.knownChatHistoryIds() == ["real", "demo-now"])
            await MemorySearchCache.shared.reset()
            let current = try await tool.execute(arguments: arguments)
            #expect(current.contains("current_demo_marker"))
            #expect(!current.contains("demo_history_marker"))

            await DemoModeService.shared.exit()
            let real = try await tool.execute(arguments: arguments)
            #expect(real.contains("real_history_marker"))
        }
    }

    /// Where a demo's chat append is held while its demo ends and the next one
    /// starts: waiting for the database writer before its chat-history write
    /// (as compose's own user-turn persistence can, never canceled), or after
    /// that write committed, before it reaches memory.db (a canceled chat task).
    enum HeldAppend: CaseIterable, Sendable {
        case beforeWrite
        case afterCommit
    }

    /// The same append, started in a demo and held across that demo's cleanup
    /// and the next demo's start, writes nothing once released: no chat-history
    /// row, no memory.db row, nothing listed or found. The new demo's own turns
    /// still write (#231).
    @Test("A demo's chat append held across the next demo's start writes nothing", arguments: HeldAppend.allCases)
    func heldDemoAppendWritesNothing(held: HeldAppend) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        try await withTool { tool in
            let base = noonUTCThreeDaysAgo()
            _ = try await ChatStore.shared.appendTurn(chatTurn(id: "real", sessionId: "s", dateMs: base + 3_600_000, text: "budget real_history_marker"), admission: nil)
            let firstRun = await MainActor.run { () -> DemoModeStore.Admission? in
                DemoModeStore.shared.isActive = true
                return DemoModeStore.shared.chatAdmission
            }

            // The app's write queue is busy, so the append waits for the writer.
            let writer = Latch()
            let busyWriter = Task { try await DatabaseWriteQueue.shared.execute(priority: .priority) { await writer.wait() } }
            let writerHeld = await waitUntil { await DatabaseWriteQueue.shared.isWriting }
            let old = chatTurn(id: "demo-old", sessionId: "demo:a", dateMs: base, text: "budget demo_history_marker")
            let pending = Task { try await ChatStore.shared.appendTurn(old, admission: firstRun) }
            let appendWaiting = await waitUntil { await DatabaseWriteQueue.shared.queuedCount == 1 }

            let chatStoreRelease = DispatchSemaphore(value: 0)
            var committed = true
            if held == .afterCommit {
                // ChatStore is kept busy, so once its write commits the append
                // waits there before handing the turn to memory.db.
                await withCheckedContinuation { (busy: CheckedContinuation<Void, Never>) in
                    Task.detached { await ChatStore.shared._testHold(held: busy, release: chatStoreRelease) }
                }
                await writer.open()
                committed = await waitUntil { (try? rawHistoryIds())?.contains("demo-old") == true }
                pending.cancel()
            }

            // The demo ends and the next one starts over a confirmed purge.
            await DemoModeService.shared.exit()
            try await DemoModeService.shared.activate()
            #expect(writerHeld && appendWaiting && committed)
            #expect(try rawHistoryIds() == ["real"], "the source row is deleted")

            // The append is released now.
            switch held {
            case .beforeWrite:
                await writer.open()
                await #expect(throws: ChatStore.DemoTurnRefused.self) { try await pending.value }
            case .afterCommit:
                chatStoreRelease.signal()
                _ = try? await pending.value
            }
            _ = try? await busyWriter.value

            #expect(try await ChatStore.shared.allHistoryTurnIds() == ["real"])
            #expect(await MemoryIndex.shared.knownChatHistoryIds() == ["real"])
            let realRow = try rowid(of: "real", memPool)
            #expect(Array(try storeRowids(memPool).prefix(2)) == [[realRow], [realRow]], "no keyword or turn row for the demo")
            await MemorySearchCache.shared.reset()
            let listed = try await tool.execute(arguments: [:])
            #expect(!listed.contains("demo_history_marker"))
            let searched = try await tool.execute(arguments: ["query": .string("demo_history_marker")])
            #expect(!searched.contains("demo_history_marker"))

            // The running demo's own turns are still written.
            let secondRun = await MainActor.run { DemoModeStore.shared.chatAdmission }
            _ = try await ChatStore.shared.appendTurn(chatTurn(id: "demo-now", sessionId: "demo:b", dateMs: base + 120_000, text: "budget current_demo_marker"), admission: secondRun)
            #expect(await MemoryIndex.shared.knownChatHistoryIds() == ["real", "demo-now"])
            await MemorySearchCache.shared.reset()
            #expect(try await tool.execute(arguments: [:]).contains("current_demo_marker"))

            await DemoModeService.shared.exit()
        }
    }

    /// Chat history ids, read straight from the database (not through ChatStore,
    /// which a test may be holding).
    private func rawHistoryIds() throws -> Set<String> {
        try AppDatabase.rawPool.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM chatHistory")) }
    }

    /// A demo's chat write released while that demo is exiting, after exit has
    /// wiped its chat history, doesn't outlive the exit: once exit returns, the
    /// turn is in neither chat history nor memory.db, so real mode can't show
    /// it, and real history is untouched (#231).
    @Test("A demo's chat write during its exit doesn't outlive the exit")
    func demoWriteDuringExitDoesntOutliveIt() async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        try await withTool { _ in
            let base = noonUTCThreeDaysAgo()
            _ = try await ChatStore.shared.appendTurn(chatTurn(id: "real", sessionId: "s", dateMs: base + 3_600_000, text: "budget real_history_marker"), admission: nil)
            let run = await MainActor.run { () -> DemoModeStore.Admission? in
                DemoModeStore.shared.isActive = true
                return DemoModeStore.shared.chatAdmission
            }
            _ = try await ChatStore.shared.appendTurn(chatTurn(id: "demo", sessionId: "demo:a", dateMs: base, text: "budget demo_history_marker"), admission: run)

            // Exit is held at its memory.db cleanup, once it has wiped chat history.
            let release = await holdWriter(memPool)
            let exit = Task { await DemoModeService.shared.exit() }
            let wiped = await waitUntil { (try? await ChatStore.shared.allHistoryTurnIds()) == ["real"] }

            // The demo's writer is released now, while exit is still running, and
            // runs until it has written or been refused.
            let appended = DispatchSemaphore(value: 0)
            let late = chatTurn(id: "demo-late", sessionId: "demo:a", dateMs: base + 60_000, text: "budget demo_late_marker")
            let append = Task {
                defer { appended.signal() }
                _ = try? await ChatStore.shared.appendTurn(late, admission: run)
            }
            let settled = await waitUntil {
                if Self.isSignaled(appended) { return true }
                return (try? await ChatStore.shared.allHistoryTurnIds())?.contains("demo-late") == true
            }
            release.signal()
            await exit.value
            await append.value
            #expect(wiped && settled)

            #expect(try await ChatStore.shared.allHistoryTurnIds() == ["real"])
            #expect(await MemoryIndex.shared.knownChatHistoryIds() == ["real"])
            let realRow = try rowid(of: "real", memPool)
            #expect(Array(try storeRowids(memPool).prefix(2)) == [[realRow], [realRow]], "no keyword or turn row for the demo")
        }
    }

    /// Holds the memory pool's writer on another thread until the returned
    /// semaphore is signaled.
    private func holdWriter(_ pool: DatabasePool) async -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                try? pool.write { _ in
                    held.resume()
                    release.wait()
                }
            }
        }
        return release
    }

    /// Whether `semaphore` has been signaled, without waiting.
    private static func isSignaled(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    /// Polls `condition` until it holds or `timeoutSeconds` pass.
    private func waitUntil(timeoutSeconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while await !condition() {
            if Date() >= deadline { return false }
            await Task.yield()
        }
        return true
    }

    /// Holds the memory pool's one reader on another thread until `release`;
    /// `finished` signals once it has let go.
    private func holdReader(_ pool: DatabasePool) async -> (release: DispatchSemaphore, finished: DispatchSemaphore) {
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = try? pool.read { _ in
                    held.resume()
                    release.wait()
                }
                finished.signal()
            }
        }
        return (release, finished)
    }

    private func waitFor(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                semaphore.wait()
                done.resume()
            }
        }
    }

    /// How the next turn begins: a new chat message, or a resumed one.
    enum TurnStart: String, CaseIterable, Sendable {
        case send
        case resume
    }

    /// Begins the next turn through the chat entry point, with AI turned off so
    /// it goes no further than its start.
    private func beginTurn(_ start: TurnStart) async throws {
        let store = AIService.optOutStore
        let previous = store.object(forKey: AIService.optOutAllAIKey)
        defer {
            if let previous {
                store.set(previous, forKey: AIService.optOutAllAIKey)
            } else {
                store.removeObject(forKey: AIService.optOutAllAIKey)
            }
        }
        AIService.writeOptOutFlag(true)
        switch start {
        case .send:
            #expect(try await AIService.shared.sendChatMessage(userText: "next", history: []) == nil)
        case .resume:
            let request = CompletionsRequest(messages: [], client_timezone: nil, disable_tools: nil)
            #expect(try await AIService.shared.resumeChatMessage(request: request) == nil)
        }
    }

    /// A search still running when the next turn begins (a new message or a
    /// resumed one) stores nothing for that turn in the same mode too: a turn
    /// written after it shows in the next turn's results.
    @Test("A search from before a turn begins never hides a later turn", arguments: ["", "budget"], TurnStart.allCases)
    func staleSearchNeverHidesALaterTurn(query: String, start: TurnStart) async throws {
        let (memPool, memDir) = try await installMemoryIndex(readers: 1)
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        await MemoryIndex.shared.indexTurn(chatHistoryId: "old", sessionId: "s", role: "user", dateMs: base, text: "budget old_history_marker")
        for i in 0..<4 {
            await MemoryIndex.shared.indexTurn(chatHistoryId: "other\(i)", sessionId: "s", role: "user", dateMs: base - Int64(i + 1) * 3_600_000, text: "lunch plans \(i)")
        }
        let held = await holdReader(memPool)
        let tool = try makeTool()
        let arguments: [String: JSONValue] = query.isEmpty ? [:] : ["query": .string(query)]
        let stale = Task { try await tool.execute(arguments: arguments) }
        // Long enough for it to be waiting on the reader inside the search.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        try await beginTurn(start)
        held.release.signal()
        let old = try await stale.value
        #expect(old.contains("old_history_marker"))
        await waitFor(held.finished)

        await MemoryIndex.shared.indexTurn(chatHistoryId: "new", sessionId: "s", role: "user", dateMs: base + 3_600_000, text: "budget new_history_marker")
        #expect(await MemoryIndex.shared.knownChatHistoryIds().isSuperset(of: ["old", "new"]))
        let next = try await tool.execute(arguments: arguments)
        #expect(next.contains("new_history_marker"))
        #expect(next.contains("old_history_marker"))
    }

    /// A search waiting for the index while demo mode starts keeps the mode it
    /// began in: it shows real history only, and so does its kept listing.
    @Test("A search queued behind the index keeps the mode it began in", arguments: ["", "budget"])
    func queuedSearchKeepsItsMode(query: String) async throws {
        let (memPool, memDir) = try await installMemoryIndex(readers: 1)
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        await MemoryIndex.shared.indexTurn(chatHistoryId: "real", sessionId: "s", role: "user", dateMs: base, text: "budget real_history_marker")
        await DemoRunFixture.indexTurn(chatHistoryId: "demo", sessionId: "demo:a", role: "user", dateMs: base + 3_600_000, text: "budget demo_history_marker")
        for i in 0..<4 {
            await DemoRunFixture.indexTurn(chatHistoryId: "other\(i)", sessionId: i % 2 == 0 ? "s" : "demo:a", role: "user", dateMs: base - Int64(i + 1) * 3_600_000, text: "lunch plans \(i)")
        }

        // The index is busy: another call waits on the reader inside it.
        let held = await holdReader(memPool)
        let busy = Task { await MemoryIndex.shared.knownChatHistoryIds() }
        try await Task.sleep(nanoseconds: 500_000_000)
        let tool = try makeTool()
        let arguments: [String: JSONValue] = query.isEmpty ? [:] : ["query": .string(query)]
        let queued = Task { try await tool.execute(arguments: arguments) }
        // Long enough for it to have read the mode and be waiting for the index.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        try await withDemoActive(true) {
            held.release.signal()
            _ = await busy.value
            let result = try await queued.value
            #expect(result.contains("real_history_marker"))
            #expect(!result.contains("demo_history_marker"))
            await waitFor(held.finished)
        }
        let kept = try await tool.execute(arguments: arguments)
        #expect(kept.contains("real_history_marker"))
        #expect(!kept.contains("demo_history_marker"))
    }

    /// A search waiting on the page cache while demo mode starts keeps the mode it
    /// began in too: it shows real history only, and so does its kept listing,
    /// while the demo's own search shows the demo's.
    @Test("A search waiting on the cache keeps the mode it began in", arguments: ["", "budget"])
    func cacheWaitKeepsItsMode(query: String) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        await MemoryIndex.shared.indexTurn(chatHistoryId: "real", sessionId: "s", role: "user", dateMs: base, text: "budget real_history_marker")
        await DemoRunFixture.indexTurn(chatHistoryId: "demo", sessionId: "demo:a", role: "user", dateMs: base + 3_600_000, text: "budget demo_history_marker")

        // The cache is busy, so the search waits on it after reading the mode.
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let busy = Task.detached { await MemorySearchCache.shared._testHold(held: held, release: release) }
        await waitFor(held)
        let tool = try makeTool()
        let arguments: [String: JSONValue] = query.isEmpty ? [:] : ["query": .string(query)]
        let waiting = Task { try await tool.execute(arguments: arguments) }
        // Long enough for it to have read the mode and be waiting on the cache.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        try await withDemoActive(true) {
            release.signal()
            await busy.value
            let result = try await waiting.value
            #expect(result.contains("real_history_marker"))
            #expect(!result.contains("demo_history_marker"))
            let demo = try await tool.execute(arguments: arguments)
            #expect(demo.contains("demo_history_marker"))
            #expect(!demo.contains("real_history_marker"))
        }
        let kept = try await tool.execute(arguments: arguments)
        #expect(kept.contains("real_history_marker"))
        #expect(!kept.contains("demo_history_marker"))
    }

    /// The Chat History search keeps to the mode in use, as the agent's does.
    @Test("The history search keeps to the mode in use")
    func historySearchKeepsToItsMode() async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        await MemoryIndex.shared.indexTurn(chatHistoryId: "real", sessionId: "s", role: "user", dateMs: base, text: "budget real turn")
        await DemoRunFixture.indexTurn(chatHistoryId: "demo", sessionId: "demo:a", role: "user", dateMs: base + 3_600_000, text: "budget demo turn")
        for i in 0..<4 {
            await DemoRunFixture.indexTurn(chatHistoryId: "other\(i)", sessionId: i % 2 == 0 ? "s" : "demo:a", role: "user", dateMs: base - Int64(i + 1) * 3_600_000, text: "lunch plans \(i)")
        }
        #expect(await ChatHistoryView.searchHistory("budget").map(\.chatHistoryId) == ["real"])
        await withDemoActive(true) {
            #expect(await ChatHistoryView.searchHistory("budget").map(\.chatHistoryId) == ["demo"])
        }
    }

    // MARK: - One fetch of 100, in pages of 20 (tabmail-ios#264)

    /// 105 turns a minute apart, each with the word: more than one search fetches. Returns the
    /// timestamps of the 100 a search or a listing keeps: the newest, newest first.
    private func indexMoreTurnsThanOneSearchFetches() async -> [Int64] {
        let base = noonUTCThreeDaysAgo()
        let count = 105
        await MemoryIndex.shared.indexTurns((0..<count).map { i in
            (chatHistoryId: "t\(i)", sessionId: "s", role: "user", dateMs: base + Int64(i) * 60_000, text: "kinkajou note")
        })
        return (5..<count).reversed().map { base + Int64($0) * 60_000 }
    }

    private func pageInfo(_ result: String) throws -> [String: Any] {
        let data = try #require(result.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// One fetch of the 100 best turns, served in pages of 20, a search and a listing alike; past the
    /// last page the tool answers with the last page, so the agent narrows its query instead.
    @Test("memory_search fetches its 100 best turns and serves them in pages of 20", arguments: ["", "kinkajou"])
    func fetchesOneHundredInPagesOfTwenty(query: String) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }
        let expected = await indexMoreTurnsThanOneSearchFetches()

        let tool = try makeTool()
        var shown: [Int64] = []
        for page in 1...5 {
            let result = try await tool.execute(arguments: ["query": .string(query), "page_index": .int(page)])
            let info = try pageInfo(result)
            #expect(info["totalItems"] as? Int == 100)
            #expect(info["totalPages"] as? Int == 5)
            let turns = try listed(result).map(\.dateMs)
            #expect(turns.count == 20)
            shown += turns
        }
        #expect(shown == expected)
        let past = try await tool.execute(arguments: ["query": .string(query), "page_index": .int(6)])
        #expect(try pageInfo(past)["page"] as? Int == 5)
        #expect(try listed(past).map(\.dateMs) == Array(expected.suffix(20)))
    }

    /// The Chat History screen lists the 100 most recent turns and searches for the 100 best; it
    /// does not page, and older turns are found through its search.
    @Test("The chat history screen lists and searches 100 turns")
    func historyListsAndSearchesOneHundred() async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }
        let expected = await indexMoreTurnsThanOneSearchFetches()

        #expect(await ChatHistoryView.listHistory().map(\.dateMs) == expected)
        #expect(await ChatHistoryView.searchHistory("kinkajou").map(\.dateMs) == expected)
    }

    /// The semantic leg keeps to the mode too: with the model loaded, a query
    /// sharing no word with either turn but matching both by meaning finds the
    /// turn of its own mode only, afresh and from the kept listing.
    @Test("A semantic match never crosses into or out of demo mode")
    func semanticMatchKeepsToItsMode() async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        let realText = "real_history_marker quarterly budget forecast spreadsheet for the finance team"
        let demoText = "demo_history_marker quarterly budget forecast spreadsheet for the finance team"
        await MemoryIndex.shared.indexTurn(chatHistoryId: "real", sessionId: "s", role: "user", dateMs: base, text: realText)
        await DemoRunFixture.indexTurn(chatHistoryId: "demo", sessionId: "demo:a", role: "user", dateMs: base + 3_600_000, text: demoText)
        let query = "money planning numbers"
        // No word in common: the keyword leg alone finds nothing.
        #expect(EmbeddingService.shared == nil)
        #expect(await MemoryIndex.shared.search(query: query, limit: 10, demoActive: false).isEmpty)

        EmbeddingService.initialize()
        defer { EmbeddingService._testUnload() }
        let model = try #require(EmbeddingService.shared)
        // Each turn's vector is the query's own, so the semantic leg finds both.
        let queryVector = try model.embed(query)
        let stored = await MemoryIndex.shared.storeEmbeddings([
            (chatHistoryId: "real", observedEpoch: 1, embedding: queryVector),
            (chatHistoryId: "demo", observedEpoch: 1, embedding: queryVector),
        ])
        #expect(Set(stored.committed) == ["real", "demo"])

        let tool = try makeTool()
        let arguments: [String: JSONValue] = ["query": .string(query)]
        let real = try await tool.execute(arguments: arguments)
        #expect(real.contains("real_history_marker"))
        #expect(!real.contains("demo_history_marker"))
        try await withDemoActive(true) {
            let demo = try await tool.execute(arguments: arguments)
            #expect(demo.contains("demo_history_marker"))
            #expect(!demo.contains("real_history_marker"))
        }
        let kept = try await tool.execute(arguments: arguments)
        #expect(kept.contains("real_history_marker"))
        #expect(!kept.contains("demo_history_marker"))
    }

    /// The dates asked keep the listing to them, to the second for a full
    /// timestamp; a date-only end includes its whole day.
    @Test("No query lists only the turns within the dates asked", arguments: [
        ("start", 2, nil, false),
        ("end", nil, 5, false),
        ("start and end", 2, 5, false),
        ("start, demo", 2, nil, true),
        ("end, demo", nil, 5, true),
        ("start and end, demo", 2, 5, true),
    ] as [(String, Int?, Int?, Bool)])
    func noQueryKeepsToTheDatesAsked(name: String, from: Int?, to: Int?, demo: Bool) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        let hour: Int64 = 3_600_000
        let dates = (0..<10).map { base + Int64($0) * hour }
        for (i, dateMs) in dates.enumerated() {
            await DemoRunFixture.indexTurn(chatHistoryId: "t\(i)", sessionId: demo ? "demo:a" : "s", role: "user", dateMs: dateMs, text: "turn \(i)")
            // The other mode's turn a minute later: inside the window, never listed.
            await DemoRunFixture.indexTurn(chatHistoryId: "o\(i)", sessionId: demo ? "s" : "demo:a", role: "user", dateMs: dateMs + 60_000, text: "other \(i)")
        }

        var arguments: [String: JSONValue] = [:]
        // Half an hour around the turns, so a bound cut to midnight changes what is listed.
        if let from { arguments["from_date"] = .string(isoString(dates[from] - hour / 2)) }
        if let to { arguments["to_date"] = .string(isoString(dates[to] + hour / 2)) }
        let inWindow = dates.indices.filter { i in (from.map { i >= $0 } ?? true) && (to.map { i <= $0 } ?? true) }
        let expected = inWindow.reversed().map { dates[$0] }

        try await withDemoActive(demo) {
            let tool = try makeTool()
            let first = try await tool.execute(arguments: arguments)
            var shown = try listed(first).map(\.dateMs)
            // Every later page too (the last page repeats for a page past it).
            if first.contains("page_index: 2") {
                shown += try listed(try await tool.execute(arguments: arguments.merging(["page_index": .int(2)]) { $1 })).map(\.dateMs)
            }
            #expect(shown == expected, "\(name)")
        }
    }

    /// A date-only start and end list that whole day, from its first millisecond
    /// through its last: the millisecond before it and the next midnight are out.
    @Test("No query with a date-only start and end lists that whole day", arguments: [false, true])
    func noQueryDateOnlyBoundsListTheDay(demo: Bool) async throws {
        let (memPool, memDir) = try await installMemoryIndex()
        defer { Task { await cleanupMemoryIndex(pool: memPool, dir: memDir) } }

        let base = noonUTCThreeDaysAgo()
        let hour: Int64 = 3_600_000
        let dayStart = base - 12 * hour
        let nextMidnight = base + 12 * hour
        let turns: [(String, Int64)] = [
            ("before", dayStart - 1), ("first", dayStart), ("evening", base + 10 * hour),
            ("last", nextMidnight - 1), ("nextMidnight", nextMidnight), ("nextDay", base + 14 * hour),
        ]
        for (id, dateMs) in turns {
            await DemoRunFixture.indexTurn(chatHistoryId: id, sessionId: demo ? "demo:a" : "s", role: "user", dateMs: dateMs, text: id)
        }
        let day = String(isoString(base).prefix(10))

        try await withDemoActive(demo) {
            let tool = try makeTool()
            let whole = try listed(try await tool.execute(arguments: ["from_date": .string(day), "to_date": .string(day)]))
            #expect(whole.map(\.dateMs) == [nextMidnight - 1, base + 10 * hour, dayStart])
            let endOnly = try listed(try await tool.execute(arguments: ["to_date": .string(day)]))
            #expect(endOnly.map(\.dateMs) == [nextMidnight - 1, base + 10 * hour, dayStart, dayStart - 1])
        }
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

/// Opens once; every `wait` before or after that returns once it has.
private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

extension ChatStore {
    /// Keeps ChatStore busy until `release`; resumes `held` once it is.
    func _testHold(held: CheckedContinuation<Void, Never>, release: DispatchSemaphore) {
        held.resume()
        release.wait()
    }
}

extension MemorySearchCache {
    /// Keeps the cache busy until `release`; `held` signals once it is.
    func _testHold(held: DispatchSemaphore, release: DispatchSemaphore) {
        held.signal()
        release.wait()
    }
}
