/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// A hybrid email search returns every keyword match, however low it scores (tabmail-ios#304,
/// mirroring tabmail-native-fts #51, ADR-NF-020; it replaced the #240 fallback that answered by
/// keyword only when the merge kept nothing). A word in at least half a year shard's rows gets an FTS5
/// IDF of about 0, so its keyword score is about 0, under `SearchConfig.minScore`. The rows live in
/// their own far-future year shards, searched within that year only, so the shard's statistics are
/// the fixture's alone. Most tests give the query embedding, so the hybrid path runs without the
/// CoreML model; the ones that need real vectors load it.
@Suite("SearchIndex hybrid search keeps every keyword match", .serialized, .processGlobalState)
struct SearchHybridKeywordMatchesTests {

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
    func wordInMostMessagesReturnsEveryKeywordMatch() async throws {
        let (from, to) = try Self.yearBounds()
        let (budget, weather) = try await indexFixture(from: from)

        // Query vector orthogonal to every stored one: vector score 0 for all.
        let results = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("budget"), queryEmbedding: Self.oneHot(0),
            fromDateMs: from, toDateMs: to, limit: 100, folderIds: nil, sort: .relevance)
        #expect(Set(results.map(\.contentKey.rawValue)) == Set(budget))

        // Within dates covering budget messages 5 to 9 (a day apart), with matches on both sides: those 5.
        let dated = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("budget"), queryEmbedding: Self.oneHot(0),
            fromDateMs: from + 4 * 86_400_000 + 43_200_000, toDateMs: from + 9 * 86_400_000 + 43_200_000,
            limit: 100, folderIds: nil, sort: .relevance)
        #expect(Set(dated.map(\.contentKey.rawValue)) == Set(budget[5..<10]))

        // Fewer than the matches: `limit` of them, best keyword match first (equal here, so newest first).
        let limited = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("budget"), queryEmbedding: Self.oneHot(0),
            fromDateMs: from, toDateMs: to, limit: 5, folderIds: nil, sort: .relevance)
        #expect(limited.map(\.contentKey.rawValue) == Array(budget.suffix(5).reversed()))
        // In date order, both directions (tabmail-ios#265).
        for (sort, expected) in [(SearchSort.dateDesc, Array(budget.suffix(5).reversed())), (.dateAsc, Array(budget.prefix(5)))] {
            let sorted = try await index.hybridSearch(
                ftsQuery: SearchQueryParser.buildFTSMatch("budget"), queryEmbedding: Self.oneHot(0),
                fromDateMs: from, toDateMs: to, limit: 5, folderIds: nil, sort: sort)
            #expect(sorted.map(\.contentKey.rawValue) == expected, "\(sort)")
        }

        try await index.removeMessages(contentKeys: (budget + weather).map(ContentKey.init(rawValue:)))
    }

    @Test("matches by meaning come first, then every keyword match scoring about 0")
    func matchesByMeaningThenKeywordMatches() async throws {
        let (from, to) = try Self.yearBounds()
        let (budget, weather) = try await indexFixture(from: from)

        // Query vector equal to most weather messages' vectors: they are found by meaning and come
        // first; the budget messages (keyword score about 0, vector score 0) follow, newest first.
        let results = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("budget"), queryEmbedding: Self.oneHot(2),
            fromDateMs: from, toDateMs: to, limit: 100, folderIds: nil, sort: .relevance)
        #expect(Set(results.prefix(9).map(\.contentKey.rawValue)) == Set(weather.dropFirst()))
        #expect(results.dropFirst(9).map(\.contentKey.rawValue) == Array(budget.reversed()))

        // One match by meaning, then the 30 keyword matches (until #304 only that one was returned).
        let single = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("budget"), queryEmbedding: Self.oneHot(3),
            fromDateMs: from, toDateMs: to, limit: 100, folderIds: nil, sort: .relevance)
        #expect(single.map(\.contentKey.rawValue) == [weather[0]] + budget.reversed())

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
        let results = try await index.search(query: "invoice", fromDateMs: fromDateMs, toDateMs: toDateMs, limit: 100, sort: .relevance)
        #expect(Set(results.map(\.contentKey.rawValue)) == Set([invoice[3], invoice[4], invoice[5], meaning]))
        let limited = try await index.search(query: "invoice", fromDateMs: fromDateMs, toDateMs: toDateMs, limit: 2, sort: .relevance)
        #expect(limited.count == 2)

        try await index.removeMessages(contentKeys: all.map(ContentKey.init(rawValue:)))
    }

    /// The topics of the release smoke test's rows (native-fts `COMMON_WORD_TOPICS`): every message
    /// says "we talked about <topic> and the meeting notes".
    private static let commonWordTopics = [
        "the quarterly budget review with finance", "a dentist appointment next week", "planning the team offsite in the mountains",
        "debugging the login page timeout", "the budget for the offsite catering", "renewing the car insurance",
        "notes on the product launch email", "the meeting about hiring a designer",
    ]

    /// March 1st, `years` ahead: a year shard of the test's own.
    private static func dayInYearAhead(_ years: Int) throws -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let year = calendar.component(.year, from: Date()) + years
        let date = try #require(calendar.date(from: DateComponents(year: year, month: 3, day: 1)))
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// native-fts `search_returns_every_keyword_match_of_a_word_in_most_messages`: a hybrid search never
    /// returns fewer keyword matches than a keyword-only search with the same dates, limit and sort, and
    /// returns all of them when the limit has room.
    @Test("a hybrid search returns every keyword match a keyword-only search does, for a word in every message")
    func hybridReturnsEveryKeywordMatchOfACommonWord() async throws {
        EmbeddingService.initialize()
        defer { EmbeddingService._testUnload() }
        let model = try #require(EmbeddingService.shared)
        let day: Int64 = 86_400_000
        let first = try Self.dayInYearAhead(170)
        let yearEnd = first + 300 * day
        let ids = Self.commonWordTopics.indices.map { "test_common_word:INBOX:m\($0)" }
        try await index.removeMessages(contentKeys: ids.map(ContentKey.init(rawValue:)))
        _ = try await index.indexHeaders(ids.enumerated().map { i, hid in
            FTSHeaderRecord(contentKey: ContentKey(rawValue: hid), headerId: hid, messageId: "m\(i)", subject: "Notes",
                            from: "a@example.com", to: "b@example.com", dateMs: first + Int64(i) * day)
        })
        for (i, hid) in ids.enumerated() {
            let body = "we talked about \(Self.commonWordTopics[i]) and the meeting notes"
            try await index.updateBody(contentKey: ContentKey(rawValue: hid), body: body)
            let text = EmbeddingService.prepareEmailText(subject: "Notes", from: "a@example.com", to: "b@example.com", body: body)
            try await index.storeEmbedding(contentKey: ContentKey(rawValue: hid), embedding: try model.embed(text))
        }
        for q in ["meeting", "notes", "talked"] {
            let fts = SearchQueryParser.buildFTSMatch(q)
            let queryVector = try model.embed(q)
            for sort in [SearchSort.relevance, .dateDesc, .dateAsc] {
                for (from, to, limit, room) in [(first, yearEnd, 100, true), (first + 3 * day + day / 2, yearEnd, 100, true),
                                                (first, yearEnd, 3, false)] {
                    let keyword = try await index.searchFTSOnly(ftsQuery: fts, fromDateMs: from, toDateMs: to, limit: limit, sort: sort)
                    let hybrid = try await index.hybridSearch(ftsQuery: fts, queryEmbedding: queryVector, fromDateMs: from,
                                                              toDateMs: to, limit: limit, folderIds: nil, sort: sort)
                    let keywordIds = keyword.map(\.contentKey.rawValue), hybridIds = hybrid.map(\.contentKey.rawValue)
                    #expect(hybridIds.count >= keywordIds.count, "\(q) \(sort) \(limit): \(hybridIds) < \(keywordIds)")
                    if room {
                        #expect(Set(keywordIds).isSubset(of: Set(hybridIds)), "\(q) \(sort): \(hybridIds) lacks some of \(keywordIds)")
                    }
                }
            }
            let all = try await index.searchFTSOnly(ftsQuery: fts, fromDateMs: first, toDateMs: yearEnd, limit: 100, sort: .relevance)
            #expect(all.count == 8, "every message has \(q)")
        }
        try await index.removeMessages(contentKeys: ids.map(ContentKey.init(rawValue:)))
    }

    /// native-fts `search_returns_a_keyword_match_that_scores_0`: the query matches only the message
    /// id, a column weighted 0, so its keyword score is exactly 0 and its vector is far from the query.
    @Test("a keyword match that scores exactly 0 is a result")
    func keywordMatchScoringZeroIsAResult() async throws {
        let first = try Self.dayInYearAhead(171)
        let hid = "test_keyword_zero:INBOX:quasarmarker"
        try await index.removeMessages(contentKeys: [ContentKey(rawValue: hid)])
        _ = try await index.indexHeaders([FTSHeaderRecord(contentKey: ContentKey(rawValue: hid), headerId: hid,
                                                          messageId: "quasarmarker", subject: "Penguin", from: "a@example.com",
                                                          to: "b@example.com", dateMs: first)])
        try await index.updateBody(contentKey: ContentKey(rawValue: hid), body: "The penguin walks across the ice and eats fish.")
        try await index.storeEmbedding(contentKey: ContentKey(rawValue: hid), embedding: Self.oneHot(1))
        let fts = SearchQueryParser.buildFTSMatch("quasarmarker")
        let hybrid = try await index.hybridSearch(ftsQuery: fts, queryEmbedding: Self.oneHot(0), fromDateMs: first,
                                                  toDateMs: first, limit: 100, folderIds: nil, sort: .relevance)
        #expect(hybrid.map(\.contentKey.rawValue) == [hid])
        let keyword = try await index.searchFTSOnly(ftsQuery: fts, fromDateMs: first, toDateMs: first, limit: 100, sort: .relevance)
        #expect(keyword.map(\.contentKey.rawValue) == [hid])
        try await index.removeMessages(contentKeys: [ContentKey(rawValue: hid)])
    }

    /// native-fts `keyword_candidates_of_equal_rank_are_the_newest`: with more equal keyword matches
    /// than the keyword candidates a search takes, the candidates are the newest, whatever order the
    /// messages were indexed in; each one is a result, so the candidates decide which are answered.
    @Test("keyword candidates of equal rank are the newest")
    func keywordCandidatesOfEqualRankAreTheNewest() async throws {
        let hour: Int64 = 3_600_000
        let first = try Self.dayInYearAhead(172)
        let limit = 2
        let count = limit * SearchConfig.candidateMultiplier * 3
        // Indexed oldest first: the oldest have the lowest rowids.
        let ids = (0..<count).map { "test_tied_candidates:INBOX:t\($0)" }
        try await index.removeMessages(contentKeys: ids.map(ContentKey.init(rawValue:)))
        _ = try await index.indexHeaders(ids.enumerated().map { i, hid in
            FTSHeaderRecord(contentKey: ContentKey(rawValue: hid), headerId: hid, messageId: "t\(i)", subject: "Budget",
                            from: "a@example.com", to: "b@example.com", dateMs: first + Int64(i) * hour)
        })
        for hid in ids { try await index.storeEmbedding(contentKey: ContentKey(rawValue: hid), embedding: Self.oneHot(1)) }
        let results = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("budget"), queryEmbedding: Self.oneHot(0),
            fromDateMs: first, toDateMs: first + Int64(count) * hour, limit: limit, folderIds: nil, sort: .relevance)
        #expect(results.map(\.contentKey.rawValue) == Array(ids.suffix(limit).reversed()))
        try await index.removeMessages(contentKeys: ids.map(ContentKey.init(rawValue:)))
    }
}
