/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// email_search hands its sort to the search, which sorts every match before it takes the tool's
/// limit (tabmail-ios#265, mirroring tabmail-native-fts#46); relevance is the default.
@Suite("EmailSearchTool sort", .serialized, .processGlobalState)
struct EmailSearchToolSortTests {

    private static let day: Int64 = 86_400_000

    /// 2 January of last year (UTC), so every match is in the past and the 120 days the tests use stay in
    /// one year shard: matches in two shards are scored against different statistics, so a weaker match
    /// alone in its shard can score the same as the better one.
    private func base() throws -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let year = calendar.component(.year, from: Date()) - 1
        let date = try #require(calendar.date(from: DateComponents(year: year, month: 1, day: 2)))
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Indexes the messages (subject, dateMs), each with the marker word, runs `body`, then removes them.
    private func withMessages(_ messages: [(subject: String, dateMs: Int64)],
                              _ body: (EmailSearchTool, String) async throws -> Void) async throws {
        let marker = "emailsort\(UUID().uuidString.prefix(8).lowercased())"
        let records = messages.enumerated().map { i, m in
            FTSHeaderRecord(contentKey: ContentKey(rawValue: "emailsort:INBOX:\(marker)-\(i)"),
                            headerId: "emailsort:INBOX:\(marker)-\(i)", messageId: "m\(i)",
                            subject: "\(marker) \(m.subject)", from: "a@example.com", to: "b@example.com",
                            dateMs: m.dateMs, folderId: "emailsort:INBOX")
        }
        let keys = records.map(\.contentKey)
        defer { Task { try? await SearchIndex.shared.removeMessages(contentKeys: keys) } }
        _ = try await SearchIndex.shared.indexHeaders(records)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
        defer { TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        _ = try AppDatabase(dbPool: pool) // the schema the tool reads headers from
        try await body(EmailSearchTool(context: ToolContext(db: pool, translator: MockChatIdTranslator())), marker)
    }

    private func object(_ result: String) throws -> [String: Any] {
        let data = try #require(result.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The dates of the listed results, in order (no header is stored, so each is the index's date).
    private func dates(_ result: String) throws -> [String] {
        let list = try #require(try object(result)["results"] as? String)
        return list.components(separatedBy: "\n").filter { $0.hasPrefix("date: ") }.map { String($0.dropFirst(6)) }
    }

    private func formatted(_ ms: Int64) -> String {
        ToolFormatters.formatDate(Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    @Test("a date sort lists the oldest (newest) of more matches than the tool fetches first")
    func dateSortFindsTheOldestAndNewestMatch() async throws {
        let base = try base()
        let count = 120 // more than the 100 the tool fetches
        try await withMessages((0..<count).map { (subject: "report", dateMs: base + Int64($0) * Self.day) }) { tool, marker in
            let ascending = try await tool.execute(arguments: ["query": .string(marker), "sort": .string("date_asc")])
            #expect(try dates(ascending).first == formatted(base))
            let descending = try await tool.execute(arguments: ["query": .string(marker), "sort": .string("date_desc")])
            #expect(try dates(descending).first == formatted(base + Int64(count - 1) * Self.day))
        }
    }

    @Test("without a sort the better match comes first, before a newer weaker one")
    func relevanceIsTheDefault() async throws {
        let base = try base()
        let messages = [(subject: "report", dateMs: base),
                        (subject: "report " + String(repeating: "weather ", count: 30), dateMs: base + Self.day)]
        try await withMessages(messages) { tool, marker in
            let result = try await tool.execute(arguments: ["query": .string(marker)])
            #expect(try dates(result) == [formatted(base), formatted(base + Self.day)])
            let relevance = try await tool.execute(arguments: ["query": .string(marker), "sort": .string("relevance")])
            #expect(try dates(relevance) == [formatted(base), formatted(base + Self.day)])
        }
    }

    @Test("a sort the tool does not know is relevance: the better match first, before a newer weaker one")
    func unknownSortIsRelevance() async throws {
        let base = try base()
        let messages = [(subject: "report", dateMs: base),
                        (subject: "report " + String(repeating: "weather ", count: 30), dateMs: base + Self.day)]
        try await withMessages(messages) { tool, marker in
            for sort in ["newest", "DATE_DESC", ""] {
                let result = try await tool.execute(arguments: ["query": .string(marker), "sort": .string(sort)])
                #expect(try object(result)["error"] == nil, "\(sort)")
                #expect(try dates(result) == [formatted(base), formatted(base + Self.day)], "\(sort)")
            }
        }
    }

    @Test("the tool fetches its 100 best matches and serves them in pages of 20, the last page past the end")
    func fetchesOneHundredInPagesOfTwenty() async throws {
        let base = try base()
        let count = 105
        // Equal matches, so the best 100 are the newest 100, newest first.
        try await withMessages((0..<count).map { (subject: "report", dateMs: base + Int64($0) * Self.day) }) { tool, marker in
            var shown: [String] = []
            for page in 1...5 {
                let result = try await tool.execute(arguments: ["query": .string(marker), "page_index": .int(page)])
                let info = try object(result)
                #expect(info["totalItems"] as? Int == 100)
                #expect(info["totalPages"] as? Int == 5)
                let listed = try dates(result)
                #expect(listed.count == 20)
                shown += listed
            }
            #expect(shown == (5..<count).reversed().map { formatted(base + Int64($0) * Self.day) })
            // Past the last page the tool answers with the last page: the agent narrows its query instead.
            let past = try await tool.execute(arguments: ["query": .string(marker), "page_index": .int(6)])
            #expect(try object(past)["page"] as? Int == 5)
            #expect(try dates(past) == Array(shown.suffix(20)))
        }
    }
}
