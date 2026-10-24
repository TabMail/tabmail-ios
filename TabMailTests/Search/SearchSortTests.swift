/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The merge puts its matches in the sort's order before it takes its limit (tabmail-ios#265,
/// mirroring tabmail-native-fts#46, ADR-NF-017): relevance ties newer first, date ties the better
/// match first, then rowid; a candidate without a date is left out.
@Suite("HybridMerge sort")
struct HybridMergeSortTests {

    private func merge(_ text: [(Int64, Double)], _ vector: [(Int64, Double)] = [], dates: [Int64: Int64],
                       sort: SearchSort, limit: Int = 10) -> [Int64] {
        HybridMerge.mergeResults(textResults: text, vectorResults: vector, dates: dates,
                                 vectorWeight: SearchConfig.vectorWeight, textWeight: SearchConfig.textWeight,
                                 sort: sort, limit: limit).map(\.rowid)
    }

    @Test("a sort is one of three names")
    func sortNames() {
        #expect(SearchSort(rawValue: "relevance") == .relevance)
        #expect(SearchSort(rawValue: "date_desc") == .dateDesc)
        #expect(SearchSort(rawValue: "date_asc") == .dateAsc)
        for name in ["", "date", "newest", "Relevance", "DATE_DESC"] {
            #expect(SearchSort(rawValue: name) == nil, "\(name)")
        }
    }

    @Test("relevance puts the better match first, and equal matches newer first")
    func relevanceTiesGoNewerFirst() {
        // 1 and 2 score the same; 1 is older, so rowid order alone would put it first.
        let text: [(Int64, Double)] = [(1, -1), (2, -1), (3, -5)]
        #expect(merge(text, dates: [1: 100, 2: 200, 3: 50], sort: .relevance) == [3, 2, 1])
        #expect(merge(text, dates: [1: 100, 2: 200, 3: 50], sort: .relevance, limit: 2) == [3, 2])
    }

    @Test("a date sort orders by date, and equal dates the better match first, both directions")
    func dateSortsOrderByDateAndTiesBetterFirst() {
        // 1 and 2 share a date; 2 is the better match, so rowid order alone would put 1 first.
        let text: [(Int64, Double)] = [(1, -1), (2, -5), (3, -2)]
        let dates: [Int64: Int64] = [1: 100, 2: 100, 3: 200]
        #expect(merge(text, dates: dates, sort: .dateDesc) == [3, 2, 1])
        #expect(merge(text, dates: dates, sort: .dateAsc) == [2, 1, 3])
        #expect(merge(text, dates: dates, sort: .dateDesc, limit: 1) == [3])
        #expect(merge(text, dates: dates, sort: .dateAsc, limit: 1) == [2])
    }

    @Test("equal matches on one date come in rowid order in every sort")
    func equalScoreAndDateComeInRowidOrder() {
        let text: [(Int64, Double)] = [(5, -1), (3, -1), (4, -1)]
        for sort in [SearchSort.relevance, .dateDesc, .dateAsc] {
            #expect(merge(text, dates: [3: 7, 4: 7, 5: 7], sort: sort) == [3, 4, 5], "\(sort)")
        }
    }

    @Test("a candidate without a date is left out")
    func candidateWithoutADateIsLeftOut() {
        #expect(merge([(1, -5), (2, -5)], [(3, 0)], dates: [1: 10, 3: 30], sort: .relevance) == [3, 1])
    }
}

/// A search sorts every match before it takes its limit (tabmail-ios#265, mirroring
/// tabmail-native-fts#46). Each test's messages are dated in a year shard no other fixture uses, so the
/// keyword scores (FTS5 statistics are per shard) are its own, and its vector searches are within its
/// dates, along axes no other fixture uses.
@Suite("SearchIndex sort before the limit", .serialized, .processGlobalState)
struct SearchSortTests {

    private var index: SearchIndex { SearchIndex.shared }
    private static let day: Int64 = 86_400_000
    private static let prefix = "test_search_sort:INBOX:"

    /// February 1st, 150 years ahead.
    private static func start() throws -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let year = calendar.component(.year, from: Date()) + 150
        let date = try #require(calendar.date(from: DateComponents(year: year, month: 2, day: 1)))
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// A unit vector at cosine `cos` from axis `i`, leaning towards axis `j`.
    private static func vector(_ i: Int, _ j: Int, cos: Float) -> [Float] {
        var v = [Float](repeating: 0, count: SearchConfig.embeddingDims)
        v[i] = cos
        v[j] = (1 - cos * cos).squareRoot()
        return v
    }

    private struct Message {
        let id: String
        var subject: String
        var from = "a@example.com"
        let dateMs: Int64
        var vector: [Float]? = nil
    }

    /// Indexes the messages in order (rowids ascending), runs `body`, and removes them.
    private func withMessages(_ messages: [Message], _ body: () async throws -> Void) async throws {
        let keys = messages.map { ContentKey(rawValue: Self.prefix + $0.id) }
        try await index.removeMessages(contentKeys: keys)
        #expect(try await index.indexHeaders(messages.map {
            FTSHeaderRecord(contentKey: ContentKey(rawValue: Self.prefix + $0.id), headerId: Self.prefix + $0.id, messageId: $0.id,
                            subject: $0.subject, from: $0.from, to: "b@example.com", dateMs: $0.dateMs)
        }) == messages.count)
        try await index.storeEmbeddings(messages.compactMap { m in
            m.vector.map { (contentKey: ContentKey(rawValue: Self.prefix + m.id), embedding: $0) }
        })
        do {
            try await body()
        } catch {
            try await index.removeMessages(contentKeys: keys)
            throw error
        }
        try await index.removeMessages(contentKeys: keys)
    }

    private func ids(_ results: [FTSSearchResult]) -> [String] {
        results.map { String($0.contentKey.rawValue.dropFirst(Self.prefix.count)) }
    }

    /// Messages without the word, so that a word in a few messages scores well by keyword.
    private func filler(_ count: Int, from start: Int64) -> [Message] {
        (0..<count).map { Message(id: "filler\($0)", subject: "Different", dateMs: start + 300 * Self.day) }
    }

    /// native-fts `a_query_of_only_fields_is_field_only`, plus a lone phrase and lowercase `and`.
    @Test("a query of only fields is field-only; a free word, phrase or group is not")
    func queryOfOnlyFieldsIsFieldOnly() {
        for q in ["from:alice@example.com", "from: alice@example.com", "from:\"Alice Example\"",
                  "from:a@example.com OR to:a@example.com", "subject:budget NOT from:bob@example.com",
                  "To:bob@example.com cc:carol@example.com bcc:dan@example.com", "body:quarterly"] {
            let built = SearchQueryParser.buildFTSMatch(q)
            #expect(SearchIndex.queryIsFieldOnly(built), "\(q) -> \(built)")
        }
        for q in ["budget", "from:alice@example.com budget", "from:alice@example.com \"quarterly budget\"",
                  "from:alice@example.com meeting", "from:alice@example.com don't", "note:launch", "from:", "AND", "",
                  "\"exact phrase\"", "and"] {
            let built = SearchQueryParser.buildFTSMatch(q)
            #expect(!SearchIndex.queryIsFieldOnly(built), "\(q) -> \(built)")
        }
    }

    @Test("a search of only fields sorts every match by date, newest first under relevance")
    func searchOfOnlyFieldsSortsEveryMatchByDate() async throws {
        let start = try Self.start()
        // 12 messages from carol a day apart (more than the limit times the candidate multiplier), the
        // newest with the longest sender field: the worst by keyword.
        var messages = (0..<12).map { i in
            Message(id: "carol\(i)", subject: "Hello", from: "carol@example.com", dateMs: start + Int64(i) * Self.day)
        }
        messages[11].from = "Carol Jane Smith of the Accounts Department <carol@example.com>"
        messages += (0..<4).map { Message(id: "dave\($0)", subject: "Hello", from: "dave@example.com", dateMs: start + 20 * Self.day) }
        try await withMessages(messages + filler(10, from: start)) {
            let from = start, to = start + 30 * Self.day
            for (sort, expected) in [(SearchSort.relevance, ["carol11", "carol10"]), (.dateDesc, ["carol11", "carol10"]),
                                     (.dateAsc, ["carol0", "carol1"])] {
                let results = try await index.search(query: "from:carol@example.com", fromDateMs: from, toDateMs: to,
                                                     limit: 2, sort: sort)
                #expect(ids(results) == expected, "\(sort)")
            }
        }
    }

    /// The tool's path: `search` with the model loaded hands its sort to the hybrid search. The best
    /// match lies between the oldest and the newest, all three with the query's own vector.
    @Test("a search with the model sorts every match before the limit")
    func searchWithTheModelSortsBeforeTheLimit() async throws {
        EmbeddingService.initialize()
        defer { EmbeddingService._testUnload() }
        let model = try #require(EmbeddingService.shared)
        let start = try Self.start()
        let vector = try model.embed("kinkajou")
        let weak = "kinkajou " + String(repeating: "weather ", count: 30)
        let messages = [Message(id: "oldest", subject: weak, dateMs: start, vector: vector),
                        Message(id: "best", subject: "kinkajou", dateMs: start + 5 * Self.day, vector: vector),
                        Message(id: "newest", subject: weak, dateMs: start + 10 * Self.day, vector: vector)]
        try await withMessages(messages + filler(20, from: start)) {
            for (sort, expected) in [(SearchSort.relevance, ["best"]), (.dateDesc, ["newest"]), (.dateAsc, ["oldest"])] {
                let results = try await index.search(query: "kinkajou", fromDateMs: start, toDateMs: start + 20 * Self.day,
                                                     limit: 1, sort: sort)
                #expect(ids(results) == expected, "\(sort)")
            }
        }
    }

    @Test("fetchDates reads each rowid's date, leaves out a rowid with no row, and throws when the read fails")
    func fetchDatesThrowsWhenTheReadFails() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE message_meta(rowid INTEGER PRIMARY KEY, dateMs INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO message_meta VALUES (1, 1000), (2, 2000)")
            #expect(try SearchIndex.fetchDates(db, metaTable: "message_meta", rowids: [1, 99]) == [1: 1000])
            #expect(try SearchIndex.fetchDates(db, metaTable: "message_meta", rowids: []).isEmpty)
            #expect(throws: DatabaseError.self) {
                try SearchIndex.fetchDates(db, metaTable: "no_such_meta", rowids: [1])
            }
        }
    }

    @Test("a keyword search sorts every match before the limit, without vectors and without the model")
    func keywordSearchSortsEveryMatchBeforeTheLimit() async throws {
        let start = try Self.start()
        let weak = "Kinkajou " + String(repeating: "weather ", count: 30)
        // Written so that rowid order breaks no tie the right way: wOld before sOld (same date, sOld
        // the better match), sOld before sNew (same match, sNew newer), wOld before wNew.
        let messages = [
            Message(id: "wOld", subject: weak, dateMs: start + Self.day),
            Message(id: "sOld", subject: "Kinkajou", dateMs: start + Self.day),
            Message(id: "sNew", subject: "Kinkajou", dateMs: start + 2 * Self.day),
            Message(id: "wNew", subject: weak, dateMs: start + 3 * Self.day),
            // A vector outside the dates, so the hybrid search has none within them.
            Message(id: "outside", subject: "Different", dateMs: start + 200 * Self.day, vector: Self.vector(20, 21, cos: 1)),
        ]
        try await withMessages(messages + filler(10, from: start)) {
            let from = start, to = start + 10 * Self.day
            let expected: [SearchSort: [String]] = [
                .relevance: ["sNew", "sOld", "wNew", "wOld"],
                .dateDesc: ["wNew", "sNew", "sOld", "wOld"],
                .dateAsc: ["sOld", "wOld", "sNew", "wNew"],
            ]
            let model = EmbeddingService.shared
            for (sort, order) in expected {
                let hybrid = try await index.hybridSearch(
                    ftsQuery: SearchQueryParser.buildFTSMatch("kinkajou"), queryEmbedding: Self.vector(20, 21, cos: 1),
                    fromDateMs: from, toDateMs: to, limit: 4, folderIds: nil, sort: sort)
                #expect(ids(hybrid) == order, "no vector within the dates, \(sort)")
                let limited = try await index.hybridSearch(
                    ftsQuery: SearchQueryParser.buildFTSMatch("kinkajou"), queryEmbedding: Self.vector(20, 21, cos: 1),
                    fromDateMs: from, toDateMs: to, limit: 2, folderIds: nil, sort: sort)
                #expect(ids(limited) == Array(order.prefix(2)), "no vector within the dates, limit 2, \(sort)")
                if model == nil {
                    let keyword = try await index.search(query: "kinkajou", fromDateMs: from, toDateMs: to, limit: 2, sort: sort)
                    #expect(ids(keyword) == Array(order.prefix(2)), "no model, \(sort)")
                }
            }
            // The typing path (SearchView) stays newest first.
            #expect(ids(try await index.keywordSearch(query: "kinkajou", fromDateMs: from, toDateMs: to, limit: 4))
                    == expected[.dateDesc])
        }
    }

    @Test("a search with no limit, as the inbox search screen's, keeps the newest 100 of more matches")
    func searchWithNoLimitKeepsOneHundred() async throws {
        let start = try Self.start()
        let count = 105
        let messages = (0..<count).map { Message(id: "okapi\($0)", subject: "Okapi", dateMs: start + Int64($0) * Self.day) }
        try await withMessages(messages) {
            let found = try await index.keywordSearch(query: "okapi", fromDateMs: start, toDateMs: start + Int64(count) * Self.day)
            #expect(ids(found) == (5..<count).reversed().map { "okapi\($0)" })
        }
    }

    @Test("a search of only dates lists the oldest first for date_asc, and otherwise the newest first")
    func searchOfOnlyDatesSortsByDate() async throws {
        let start = try Self.start()
        let messages = (0..<6).map { Message(id: "dated\($0)", subject: "Hello", dateMs: start + Int64($0) * Self.day) }
        try await withMessages(messages) {
            for (sort, expected) in [(SearchSort.dateAsc, ["dated0", "dated1"]), (.dateDesc, ["dated5", "dated4"]),
                                     (.relevance, ["dated5", "dated4"])] {
                let results = try await index.search(query: "*", fromDateMs: start, toDateMs: start + 10 * Self.day,
                                                     limit: 2, sort: sort)
                #expect(ids(results) == expected, "\(sort)")
            }
        }
    }

    @Test("a date-sorted search finds the newest and the oldest match past the relevance pool")
    func dateSortedSearchFindsTheNewestAndOldestMatch() async throws {
        let start = try Self.start()
        let query = Self.vector(22, 23, cos: 1)
        let weak = "Kinkajou " + String(repeating: "weather ", count: 30)
        // 12 strong matches (by keyword and by meaning) in the middle, and a weak one on each side,
        // farther by meaning too: with limit 1, relevance reads 4 candidates per leg and never sees them.
        var messages = (0..<12).map { i in
            Message(id: "strong\(i)", subject: "Kinkajou", dateMs: start + Int64(10 + i) * Self.day, vector: query)
        }
        messages.append(Message(id: "newest", subject: weak, dateMs: start + 40 * Self.day, vector: Self.vector(22, 23, cos: 0.8)))
        messages.append(Message(id: "oldest", subject: weak, dateMs: start + Self.day, vector: Self.vector(22, 23, cos: 0.8)))
        try await withMessages(messages + filler(30, from: start)) {
            func top(_ sort: SearchSort) async throws -> [String] {
                ids(try await index.hybridSearch(
                    ftsQuery: SearchQueryParser.buildFTSMatch("kinkajou"), queryEmbedding: query,
                    fromDateMs: start, toDateMs: start + 50 * Self.day, limit: 1, folderIds: nil, sort: sort))
            }
            #expect(try await top(.dateDesc) == ["newest"])
            #expect(try await top(.dateAsc) == ["oldest"])
            let best = try await top(.relevance)
            #expect(best.count == 1 && best[0].hasPrefix("strong"))
        }
    }

    @Test("a date-sorted search orders a match by meaning alone by its date")
    func dateSortedSearchOrdersAMatchByMeaningByItsDate() async throws {
        let start = try Self.start()
        let query = Self.vector(24, 25, cos: 1)
        // Keyword matches with the query's vector, and a newer message without the word, farther by
        // meaning: found by meaning alone, so its date is read for the merge.
        var messages = (0..<3).map { i in
            Message(id: "word\(i)", subject: "Kinkajou", dateMs: start + Int64(i) * Self.day, vector: query)
        }
        messages.append(Message(id: "meaning", subject: "Quokka", dateMs: start + 5 * Self.day, vector: Self.vector(24, 25, cos: 0.8)))
        try await withMessages(messages + filler(30, from: start)) {
            let results = try await index.hybridSearch(
                ftsQuery: SearchQueryParser.buildFTSMatch("kinkajou"), queryEmbedding: query,
                fromDateMs: start, toDateMs: start + 10 * Self.day, limit: 4, folderIds: nil, sort: .dateDesc)
            #expect(ids(results) == ["meaning", "word2", "word1", "word0"])
            #expect(results.first?.snippet == "")
            #expect(results.first?.dateMs == start + 5 * Self.day)
            let ascending = try await index.hybridSearch(
                ftsQuery: SearchQueryParser.buildFTSMatch("kinkajou"), queryEmbedding: query,
                fromDateMs: start, toDateMs: start + 10 * Self.day, limit: 4, folderIds: nil, sort: .dateAsc)
            #expect(ids(ascending) == ["word0", "word1", "word2", "meaning"])
        }
    }

    @Test("a date sort reads 4,096 keyword candidates")
    func dateSortReads4096KeywordCandidates() async throws {
        let start = try Self.start()
        let pool = SearchConfig.dateSortPool
        #expect(pool == 4096)
        let query = Self.vector(26, 27, cos: 1)
        // Exactly 4,096 keyword matches: 4,095 strong ones and a weak one, the worst by keyword, newest
        // (oldest) for the descending (ascending) sort. One vector keeps the search hybrid (an index
        // part way through its embedding rebuild). The filler keeps the word's keyword score up.
        for (sort, weakDate) in [(SearchSort.dateDesc, start + Int64(pool) * 60_000), (.dateAsc, start - 60_000)] {
            var messages = (0..<(pool - 1)).map { i in
                Message(id: "strong\(i)", subject: "Kinkajou", dateMs: start + Int64(i) * 60_000, vector: i == 0 ? query : nil)
            }
            messages.append(Message(id: "weak", subject: "Kinkajou " + String(repeating: "weather ", count: 6), dateMs: weakDate))
            let filler = (0..<(4 * pool)).map { Message(id: "other\($0)", subject: "Different", dateMs: start) }
            try await withMessages(messages + filler) {
                let from = start - Self.day, to = start + 10 * Self.day
                #expect(try await index.keywordSearch(query: "kinkajou", fromDateMs: from, toDateMs: to, limit: pool + 1).count == pool)
                let results = try await index.hybridSearch(
                    ftsQuery: SearchQueryParser.buildFTSMatch("kinkajou"), queryEmbedding: query,
                    fromDateMs: from, toDateMs: to, limit: 1, folderIds: nil, sort: sort)
                #expect(ids(results) == ["weak"], "\(sort)")
            }
        }
    }

    @Test("a date sort reads 4,096 vector candidates")
    func dateSortReads4096VectorCandidates() async throws {
        let start = try Self.start()
        let pool = SearchConfig.dateSortPool
        let query = Self.vector(28, 29, cos: 1)
        // Exactly 4,096 vectors in the dates: 4,095 on the query and a farther one, a match by meaning
        // alone (no message has the word), newest (oldest) for the descending (ascending) sort.
        for (sort, meaningDate) in [(SearchSort.dateDesc, start + Int64(pool) * 60_000), (.dateAsc, start - 60_000)] {
            var messages = (0..<(pool - 1)).map { i in
                Message(id: "near\(i)", subject: "Quokka", dateMs: start + Int64(i) * 60_000, vector: query)
            }
            messages.append(Message(id: "meaning", subject: "Quokka", dateMs: meaningDate, vector: Self.vector(28, 29, cos: 0.8)))
            try await withMessages(messages) {
                let from = start - Self.day, to = start + 10 * Self.day
                let all = await index.searchVecCandidates(queryEmbedding: query, limit: pool, fromDateMs: from, toDateMs: to, eligible: nil,
                                                          demoActive: false)
                #expect(all.count == pool)
                #expect(all.last.map { $0.1 > 0.1 } == true, "the farthest is the match by meaning")
                let results = try await index.hybridSearch(
                    ftsQuery: SearchQueryParser.buildFTSMatch("zyxwvut"), queryEmbedding: query,
                    fromDateMs: from, toDateMs: to, limit: 1, folderIds: nil, sort: sort)
                #expect(ids(results) == ["meaning"], "\(sort)")
            }
        }
    }

    /// Demo mode (ADR-IOS-038) with a real account's mail on the device: a search answers with the
    /// mode's own matches, up to the limit, in every sort. The other mode's messages found by meaning
    /// alone, newer and older than every match, are no part of the answer and take none of its places.
    @Test("each mode's search answers with its own matches up to the limit in every sort, never the other mode's")
    func eachModeAnswersWithItsOwnMatches() async throws {
        let start = try Self.start()
        let query = Self.vector(30, 31, cos: 1)
        func record(_ key: String, _ subject: String, _ dateMs: Int64) -> FTSHeaderRecord {
            FTSHeaderRecord(contentKey: ContentKey(rawValue: key), headerId: key, messageId: key,
                            subject: subject, from: "a@example.com", to: "b@example.com", dateMs: dateMs)
        }
        let demo = (0..<3).map { record("\(DemoSeed.demoAccountId):INBOX:sortdemo\($0)", "Kinkajou", start + Int64($0) * Self.day) }
        let demoFiller = (0..<10).map { record("\(DemoSeed.demoAccountId):INBOX:sortdemofill\($0)", "Different", start) }
        let newer = (0..<5).map { record("sortrealacct:INBOX:newer\($0)", "Quokka", start + Int64(10 + $0) * Self.day) }
        let older = (0..<5).map { record("sortrealacct:INBOX:older\($0)", "Quokka", start - Int64(10 + $0) * Self.day) }
        let all = demo + demoFiller + newer + older
        let keys = all.map(\.contentKey)
        try await index.removeMessages(contentKeys: keys)
        #expect(try await index.indexHeaders(all) == all.count)
        try await index.storeEmbeddings(demo.map { (contentKey: $0.contentKey, embedding: Self.vector(30, 31, cos: 0.9)) }
                                        + (newer + older).map { (contentKey: $0.contentKey, embedding: Self.vector(30, 31, cos: 0.95)) })
        func search(_ sort: SearchSort, withinDates: Bool) async throws -> [String] {
            try await index.hybridSearch(
                ftsQuery: SearchQueryParser.buildFTSMatch("kinkajou"), queryEmbedding: query,
                fromDateMs: withinDates ? start - 30 * Self.day : nil, toDateMs: withinDates ? start + 30 * Self.day : nil,
                limit: 2, folderIds: nil, sort: sort).map(\.contentKey.rawValue)
        }
        let d = demo.map(\.contentKey.rawValue), n = newer.map(\.contentKey.rawValue), o = older.map(\.contentKey.rawValue)
        var answers: [String: [String]] = [:]
        await MainActor.run { DemoModeStore.shared.isActive = true }
        do {
            for withinDates in [true, false] {
                for sort in [SearchSort.relevance, .dateDesc, .dateAsc] {
                    answers["demo \(sort.rawValue) \(withinDates)"] = try await search(sort, withinDates: withinDates)
                }
            }
        } catch {
            await MainActor.run { DemoModeStore.shared.isActive = false }
            try await index.removeMessages(contentKeys: keys)
            throw error
        }
        await MainActor.run { DemoModeStore.shared.isActive = false }
        for withinDates in [true, false] {
            for sort in [SearchSort.relevance, .dateDesc, .dateAsc] {
                answers["real \(sort.rawValue) \(withinDates)"] = try await search(sort, withinDates: withinDates)
            }
        }
        try await index.removeMessages(contentKeys: keys)

        for withinDates in [true, false] {
            #expect(answers["demo relevance \(withinDates)"] == [d[2], d[1]], "\(answers)")
            #expect(answers["demo date_desc \(withinDates)"] == [d[2], d[1]], "\(answers)")
            #expect(answers["demo date_asc \(withinDates)"] == [d[0], d[1]], "\(answers)")
            #expect(answers["real relevance \(withinDates)"] == [n[4], n[3]], "\(answers)")
            #expect(answers["real date_desc \(withinDates)"] == [n[4], n[3]], "\(answers)")
            #expect(answers["real date_asc \(withinDates)"] == [o[4], o[3]], "\(answers)")
        }
    }
}
