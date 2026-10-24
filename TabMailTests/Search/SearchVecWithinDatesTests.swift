/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// A hybrid email search with dates or a field looks for vectors only within them (tabmail-ios#242,
/// mirroring tabmail-native-fts#26, ADR-NF-016): nearer messages outside them never take the places
/// of a match inside them. The rows are dated from about a year ahead (plus one long before 1970), and
/// the query vectors lie along axes no other fixture uses, so other suites' rows are never nearer.
@Suite("SearchIndex vector search within the dates and the field", .serialized, .processGlobalState)
struct SearchVecWithinDatesTests {

    private var index: SearchIndex { SearchIndex.shared }
    private static let day: Int64 = 86_400_000

    /// A unit vector at cosine `cos` from axis `i`, leaning towards axis `j`.
    private static func vector(_ i: Int, _ j: Int, cos: Float) -> [Float] {
        var v = [Float](repeating: 0, count: SearchConfig.embeddingDims)
        v[i] = cos
        v[j] = (1 - cos * cos).squareRoot()
        return v
    }

    /// About a year ahead, so a missing end date standing for now would exclude every row.
    private static func start() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000) + 400 * day
    }

    /// February 1st a century ahead: a year shard no other fixture uses, so the keyword scores
    /// (FTS5 statistics are per shard) are this fixture's alone.
    private static func ownYearStart() throws -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let year = calendar.component(.year, from: Date()) + 100
        let date = try #require(calendar.date(from: DateComponents(year: year, month: 2, day: 1)))
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func indexRows(_ rows: [(key: String, from: String, dateMs: Int64, vector: [Float])]) async throws {
        try await index.removeMessages(contentKeys: rows.map { ContentKey(rawValue: $0.key) })
        let records = rows.map {
            FTSHeaderRecord(contentKey: ContentKey(rawValue: $0.key), headerId: $0.key, messageId: $0.key,
                            subject: "Quokka", from: $0.from, to: "b@example.com", dateMs: $0.dateMs)
        }
        #expect(try await index.indexHeaders(records) == rows.count)
        for row in rows {
            try await index.storeEmbedding(contentKey: ContentKey(rawValue: row.key), embedding: row.vector)
        }
    }

    @Test("the vector search keeps the nearest within both bounds, either bound alone and the field's rowids")
    func vecCandidatesWithinTheDatesAndTheField() async throws {
        let start = Self.start()
        // Row i at distance i/100 from the query, so a result's distance names its row (other suites'
        // rows are much farther and are left out). Rows 1 to 20 are dated i days after the start, 21
        // long before 1970, 22 later than all of them.
        let dates = (1...20).map { start + Int64($0) * Self.day } + [-5_000_000_000_000, start + 300 * Self.day]
        let rows = dates.enumerated().map { i, dateMs in
            (key: "test_vec_dates:INBOX:k\(i + 1)", from: "a@example.com", dateMs: dateMs,
             vector: Self.vector(7, 8, cos: 1 - Float(i + 1) / 100))
        }
        try await indexRows(rows)
        let query = Self.vector(7, 8, cos: 1)
        func nearest(_ k: Int, _ from: Int64?, _ to: Int64?, _ eligible: Set<Int64>? = nil) async -> [Int] {
            await index.searchVecCandidates(queryEmbedding: query, limit: k, fromDateMs: from, toDateMs: to, eligible: eligible)
                .map { Int(($0.1 * 100).rounded()) }.filter { (1...22).contains($0) }
        }
        let rowids = Dictionary(uniqueKeysWithValues: await index.searchVecCandidates(
            queryEmbedding: query, limit: 22, fromDateMs: -5_000_000_000_000, toDateMs: start + 300 * Self.day, eligible: nil)
            .map { (Int(($0.1 * 100).rounded()), $0.0) }.filter { (1...22).contains($0.0) })
        #expect(rowids.keys.sorted() == Array(1...22))

        #expect(await nearest(3, nil, nil) == [1, 2, 3])
        #expect(await nearest(5, start + 10 * Self.day, start + 12 * Self.day) == [10, 11, 12])
        #expect(await nearest(5, start + 15 * Self.day, start + 15 * Self.day) == [15])
        #expect(await nearest(4, start + 18 * Self.day, nil) == [18, 19, 20, 22])
        #expect(await nearest(3, nil, start + 2 * Self.day) == [1, 2, 21])
        #expect(await nearest(3, start + 20 * Self.day + 1, start + 21 * Self.day) == [])
        let field = Set([17, 5, 2].compactMap { rowids[$0] })
        #expect(await nearest(5, nil, nil, field) == [2, 5, 17])
        #expect(await nearest(5, start + 10 * Self.day, nil, field) == [17])
        #expect(await nearest(5, nil, nil, []) == [])

        try await index.removeMessages(contentKeys: rows.map { ContentKey(rawValue: $0.key) })
    }

    @Test("a match by meaning inside the dates or the field is found past nearer messages outside them")
    func matchByMeaningPastNearerMessagesOutsideTheDatesOrTheField() async throws {
        let start = Self.start()
        let limit = 2
        // More nearer messages on each side than the vector search asks for (limit x 4), from
        // someone else, before and after the dates; the match is at cosine 0.8 from the query.
        let nearer = limit * SearchConfig.candidateMultiplier * 2 + 4
        let inside = "test_vec_dates:INBOX:inside"
        let query = Self.vector(5, 6, cos: 1)
        var rows = [(key: inside, from: "carol@example.com", dateMs: start + 10 * Self.day, vector: Self.vector(5, 6, cos: 0.8))]
        for i in 0..<nearer {
            rows.append((key: "test_vec_dates:INBOX:before\(i)", from: "dave@example.com",
                         dateMs: start + Int64(i) * 3_600_000, vector: query))
            rows.append((key: "test_vec_dates:INBOX:after\(i)", from: "dave@example.com",
                         dateMs: start + 20 * Self.day + Int64(i) * 3_600_000, vector: query))
        }
        try await indexRows(rows)

        // Without dates or a field, the nearer messages take every place the search asks for.
        let unfiltered = await index.searchVecCandidates(
            queryEmbedding: query, limit: limit * SearchConfig.candidateMultiplier, fromDateMs: nil, toDateMs: nil, eligible: nil)
        #expect(unfiltered.count == limit * SearchConfig.candidateMultiplier)
        #expect(unfiltered.allSatisfy { $0.1 < 0.1 })

        // No keyword matches: the match is found by meaning alone.
        let dated = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("zyxwvut"), queryEmbedding: query,
            fromDateMs: start + 9 * Self.day + Self.day / 2, toDateMs: start + 10 * Self.day + Self.day / 2,
            limit: limit, folderIds: nil)
        #expect(dated.map(\.contentKey.rawValue) == [inside])
        let field = try await index.hybridSearch(
            ftsQuery: SearchQueryParser.buildFTSMatch("from:carol@example.com zyxwvut"), queryEmbedding: query,
            fromDateMs: nil, toDateMs: nil, limit: limit, folderIds: nil)
        #expect(field.map(\.contentKey.rawValue) == [inside])

        try await index.removeMessages(contentKeys: rows.map { ContentKey(rawValue: $0.key) })
    }

    @Test("with no vector within the dates or the field, every keyword match within them is the answer")
    func noVectorWithinTheDatesOrTheFieldAnswersByKeyword() async throws {
        let start = try Self.ownYearStart()
        let prefix = "test_vec_dates:INBOX:"
        // A strong and a weak keyword match (a short subject and a long one) within the dates and from
        // carol, neither with a vector yet (as during embedding backfill); one message with the query's
        // own vector outside the dates and from someone else; and enough short messages without the word,
        // also from carol (so `from:carol` adds about nothing by keyword), that the weak match alone
        // scores under `SearchConfig.minScore` in the hybrid merge.
        var records = [
            (id: "strong", subject: "Kinkajou", from: "carol@example.com", dateMs: start),
            (id: "weak", subject: "Kinkajou " + String(repeating: "weather ", count: 2000), from: "carol@example.com", dateMs: start + Self.day),
            (id: "outside", subject: "Different", from: "dave@example.com", dateMs: start + 10 * Self.day),
        ]
        records += (0..<400).map { (id: "other\($0)", subject: "Different", from: "carol@example.com", dateMs: start + 20 * Self.day) }
        let keys = records.map { ContentKey(rawValue: prefix + $0.id) }
        try await index.removeMessages(contentKeys: keys)
        #expect(try await index.indexHeaders(records.map {
            FTSHeaderRecord(contentKey: ContentKey(rawValue: prefix + $0.id), headerId: prefix + $0.id, messageId: $0.id,
                            subject: $0.subject, from: $0.from, to: "b@example.com", dateMs: $0.dateMs)
        }) == records.count)
        let query = Self.vector(10, 11, cos: 1)
        try await index.storeEmbedding(contentKey: ContentKey(rawValue: prefix + "outside"), embedding: query)
        let from = start, to = start + 2 * Self.day
        let expected: Set = [prefix + "strong", prefix + "weak"]

        // The vector exists, but not within the dates; both messages match by keyword within them.
        #expect(await index.searchVecCandidates(queryEmbedding: query, limit: 1, fromDateMs: nil, toDateMs: nil, eligible: nil)
            .allSatisfy { $0.1 < 0.01 })
        #expect(await index.searchVecCandidates(queryEmbedding: query, limit: 10, fromDateMs: from, toDateMs: to, eligible: nil).isEmpty)
        #expect(Set(try await index.keywordSearch(query: "kinkajou", fromDateMs: from, toDateMs: to, limit: 10).map(\.contentKey.rawValue)) == expected)

        for (q, from, to) in [("kinkajou", Optional(from), Optional(to)),
                              ("from:carol@example.com kinkajou", nil, nil),
                              ("from:carol@example.com kinkajou", Optional(from), Optional(to))] {
            let results = try await index.hybridSearch(
                ftsQuery: SearchQueryParser.buildFTSMatch(q), queryEmbedding: query,
                fromDateMs: from, toDateMs: to, limit: 10, folderIds: nil)
            #expect(Set(results.map(\.contentKey.rawValue)) == expected, "\(q)")
        }

        try await index.removeMessages(contentKeys: keys)
    }
}
