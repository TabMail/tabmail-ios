/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// A hybrid email search whose keyword leg matched never answers with nothing (tabmail-ios#240,
/// mirroring tabmail-native-fts#28). A word in at least half a year shard's rows gets an FTS5 IDF of
/// about 0, so its keyword score is about 0; with weak vector matches every merged score falls under
/// `SearchConfig.minScore`. The rows live in their own far-future year shard, searched within that
/// year only, so the shard's statistics are this fixture's alone. The query embedding is given, so the
/// hybrid path runs without the CoreML model (the unit-test host does not load it by default); the
/// last test loads it to check that `search` hands its arguments to that path.
@Suite("SearchIndex hybrid merge keeping nothing answers by keyword", .serialized, .processGlobalState)
struct SearchEmptyMergeKeywordFallbackTests {

    private var index: SearchIndex { SearchIndex.shared }

    private static func oneHot(_ i: Int) -> [Float] {
        var v = [Float](repeating: 0, count: SearchConfig.embeddingDims)
        v[i] = 1
        return v
    }

    private static func yearBounds() throws -> (from: Int64, to: Int64) {
        let calendar = Calendar(identifier: .gregorian)
        let start = try #require(calendar.date(from: DateComponents(timeZone: .gmt, year: 2099, month: 1, day: 1)))
        let end = try #require(calendar.date(from: DateComponents(timeZone: .gmt, year: 2099, month: 12, day: 31)))
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }

    /// 30 messages with "budget" and 10 without, with vectors along axis 1 (budget), 2 (weather) and
    /// 3 (the first weather message only).
    private func indexFixture(from: Int64) async throws -> (budget: [String], weather: [String]) {
        let budget = (0..<30).map { "test_empty_merge:INBOX:b\($0)" }
        let weather = (0..<10).map { "test_empty_merge:INBOX:w\($0)" }
        try await index.removeMessages(contentKeys: (budget + weather).map(ContentKey.init(rawValue:)))

        var records = [FTSHeaderRecord]()
        for (i, hid) in budget.enumerated() {
            records.append(FTSHeaderRecord(contentKey: ContentKey(rawValue: hid), headerId: hid, messageId: "b\(i)",
                                           subject: "Budget", from: "a@example.com", to: "b@example.com",
                                           dateMs: from + Int64(i) * 86_400_000))
        }
        for (i, hid) in weather.enumerated() {
            records.append(FTSHeaderRecord(contentKey: ContentKey(rawValue: hid), headerId: hid, messageId: "w\(i)",
                                           subject: "Weather", from: "a@example.com", to: "b@example.com",
                                           dateMs: from + Int64(40 + i) * 86_400_000))
        }
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 40)
        for hid in budget {
            try await index.storeEmbedding(contentKey: ContentKey(rawValue: hid), embedding: Self.oneHot(1))
        }
        for (i, hid) in weather.enumerated() {
            try await index.storeEmbedding(contentKey: ContentKey(rawValue: hid), embedding: Self.oneHot(i == 0 ? 3 : 2))
        }
        return (budget, weather)
    }

    @Test("a word in most messages with no near vector returns every keyword match")
    func emptyMergeAnswersByKeyword() async throws {
        let (from, to) = try Self.yearBounds()
        let (budget, weather) = try await indexFixture(from: from)

        // Query vector orthogonal to every stored one: vector score 0 for all.
        let results = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("budget"), queryEmbedding: Self.oneHot(0),
            fromDateMs: from, toDateMs: to, limit: 100, folderIds: nil)
        #expect(Set(results.map(\.contentKey.rawValue)) == Set(budget))

        // Within dates covering budget messages 5 to 9 (a day apart), with matches on both sides: those 5.
        let dated = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("budget"), queryEmbedding: Self.oneHot(0),
            fromDateMs: from + 4 * 86_400_000 + 43_200_000, toDateMs: from + 9 * 86_400_000 + 43_200_000,
            limit: 100, folderIds: nil)
        #expect(Set(dated.map(\.contentKey.rawValue)) == Set(budget[5..<10]))

        // Fewer than the matches: the newest `limit`, newest first.
        let limited = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("budget"), queryEmbedding: Self.oneHot(0),
            fromDateMs: from, toDateMs: to, limit: 5, folderIds: nil)
        #expect(limited.map(\.contentKey.rawValue) == Array(budget.suffix(5).reversed()))

        try await index.removeMessages(contentKeys: (budget + weather).map(ContentKey.init(rawValue:)))
    }

    @Test("when the merge keeps results, those are the answer")
    func nonEmptyMergeIsTheAnswer() async throws {
        let (from, to) = try Self.yearBounds()
        let (budget, weather) = try await indexFixture(from: from)

        // Query vector equal to most weather messages' vectors: they are kept by meaning, the
        // budget messages (keyword score about 0, vector score 0) are not.
        let results = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("budget"), queryEmbedding: Self.oneHot(2),
            fromDateMs: from, toDateMs: to, limit: 100, folderIds: nil)
        #expect(Set(results.map(\.contentKey.rawValue)) == Set(weather.dropFirst()))

        // A merge that keeps a single message is the answer too.
        let single = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("budget"), queryEmbedding: Self.oneHot(3),
            fromDateMs: from, toDateMs: to, limit: 100, folderIds: nil)
        #expect(single.map(\.contentKey.rawValue) == [weather[0]])

        try await index.removeMessages(contentKeys: (budget + weather).map(ContentKey.init(rawValue:)))
    }

    @Test("search answers by the hybrid path within its dates, its limit and by the query's meaning")
    func searchHandsItsArgumentsToTheHybridPath() async throws {
        EmbeddingService.initialize()
        defer { EmbeddingService._testUnload() }
        let model = try #require(EmbeddingService.shared)
        let (from, _) = try Self.yearBounds()
        let day: Int64 = 86_400_000
        // "Invoice" messages a day apart (the last a week out), and one without the word or a
        // synonym of it, all with the query's own vector: that one is found by meaning alone.
        let invoice = (0..<7).map { "test_empty_merge:INBOX:inv\($0)" }
        let meaning = "test_empty_merge:INBOX:meaning"
        let all = invoice + [meaning]
        try await index.removeMessages(contentKeys: all.map(ContentKey.init(rawValue:)))
        var records = [FTSHeaderRecord]()
        for (i, hid) in invoice.enumerated() {
            records.append(FTSHeaderRecord(contentKey: ContentKey(rawValue: hid), headerId: hid, messageId: "inv\(i)",
                                           subject: "Invoice", from: "a@example.com", to: "b@example.com",
                                           dateMs: from + Int64(i == 6 ? 7 : i) * day))
        }
        records.append(FTSHeaderRecord(contentKey: ContentKey(rawValue: meaning), headerId: meaning, messageId: "meaning",
                                       subject: "Quokka", from: "a@example.com", to: "b@example.com", dateMs: from + 4 * day))
        _ = try await index.indexHeaders(records)
        let queryVector = try model.embed("invoice")
        for hid in all {
            try await index.storeEmbedding(contentKey: ContentKey(rawValue: hid), embedding: queryVector)
        }

        let fromDateMs = from + 2 * day + day / 2, toDateMs = from + 5 * day + day / 2
        let results = try await index.search(query: "invoice", fromDateMs: fromDateMs, toDateMs: toDateMs, limit: 100)
        #expect(Set(results.map(\.contentKey.rawValue)) == Set([invoice[3], invoice[4], invoice[5], meaning]))
        let limited = try await index.search(query: "invoice", fromDateMs: fromDateMs, toDateMs: toDateMs, limit: 2)
        #expect(limited.count == 2)

        try await index.removeMessages(contentKeys: all.map(ContentKey.init(rawValue:)))
    }
}
