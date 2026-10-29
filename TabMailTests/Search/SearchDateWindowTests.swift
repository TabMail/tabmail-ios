/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// A date-sorted search is exact however many messages match (tabmail-ios#294, mirroring
/// tabmail-native-fts#47, ADR-NF-023): it walks the dates in windows from the end the sort starts at and
/// stops at its limit, so the newest (oldest) matches are found past the 4,096-candidate pool of a leg.
/// The invariant every test pins: the answer is the true list in date order, the one a single query over
/// every match gives. Each test's messages are dated in a year shard no other fixture uses (151 years
/// ahead), and its vectors lie along axes no other fixture uses.
@Suite("SearchIndex date windows", .serialized, .processGlobalState)
struct SearchDateWindowTests {

    private var index: SearchIndex { SearchIndex.shared }
    private static let day: Int64 = 86_400_000
    private static let minute: Int64 = 60_000
    private static let prefix = "test_search_window:INBOX:"

    /// February 1st, 151 years ahead.
    private static func start() throws -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let year = calendar.component(.year, from: Date()) + 151
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
        let dateMs: Int64
        var vector: [Float]? = nil
    }

    /// Indexes the messages in order (rowids ascending), runs `body`, and removes them.
    private func withMessages(_ messages: [Message], _ body: () async throws -> Void) async throws {
        let keys = messages.map { ContentKey(rawValue: Self.prefix + $0.id) }
        try await index.removeMessages(contentKeys: keys)
        #expect(try await index.indexHeaders(messages.map {
            FTSHeaderRecord(contentKey: ContentKey(rawValue: Self.prefix + $0.id), headerId: Self.prefix + $0.id, messageId: $0.id,
                            subject: $0.subject, from: "a@example.com", to: "b@example.com", dateMs: $0.dateMs)
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
    private func filler(_ count: Int, at date: Int64) -> [Message] {
        (0..<count).map { Message(id: "filler\($0)", subject: "Different", dateMs: date) }
    }

    private func search(_ word: String, _ query: [Float], from: Int64?, to: Int64?, limit: Int,
                        sort: SearchSort) async throws -> [FTSSearchResult] {
        try await index.hybridSearch(ftsQuery: SearchQueryParser.buildFTSMatch(word), queryEmbedding: query,
                                     fromDateMs: from, toDateMs: to, limit: limit, folderIds: nil, sort: sort)
    }

    /// The exact answer by keyword: one query over every match, in the sort's order.
    private func exactKeyword(_ word: String, from: Int64?, to: Int64?, limit: Int,
                              sort: SearchSort) async throws -> [String] {
        ids(try await index.searchFTSOnly(ftsQuery: SearchQueryParser.buildFTSMatch(word), fromDateMs: from, toDateMs: to,
                                          limit: limit, sort: sort))
    }

    @Test("a date sort finds the newest and the oldest match past the keyword pool")
    func exactPastTheKeywordPool() async throws {
        let start = try Self.start()
        let query = Self.vector(32, 33, cos: 1)
        let strongCount = SearchConfig.dateSortPool + 904
        // 5,000 strong matches a minute apart, and a weak one (the worst by keyword) on each side: the best
        // 4,096 by keyword leave out both, whichever end the sort starts at.
        var messages = (0..<strongCount).map { i in
            Message(id: "strong\(i)", subject: "Pangolin", dateMs: start + Int64(i + 1) * Self.minute, vector: i == 0 ? query : nil)
        }
        let weak = "Pangolin " + String(repeating: "weather ", count: 6)
        messages.append(Message(id: "newest", subject: weak, dateMs: start + Int64(strongCount + 5) * Self.minute))
        messages.append(Message(id: "oldest", subject: weak, dateMs: start))
        try await withMessages(messages + filler(2 * strongCount, at: start - Self.day)) {
            let from = start - Self.day, to = start + 10 * Self.day
            for sort in [SearchSort.dateDesc, .dateAsc] {
                let results = try await search("pangolin", query, from: from, to: to, limit: 10, sort: sort)
                #expect(ids(results).first == (sort == .dateDesc ? "newest" : "oldest"), "\(sort)")
                let exact = try await exactKeyword("pangolin", from: from, to: to, limit: 10, sort: sort)
                #expect(ids(results) == exact, "\(sort)")
            }
        }
    }

    @Test("a date sort walks on to the next window when its limit is more than the first window holds")
    func exactAcrossTwoWindows() async throws {
        let start = try Self.start()
        let query = Self.vector(34, 35, cos: 1)
        let pool = SearchConfig.dateSortPool
        // 4,090 matches newest, 20 matches at one date after them (the pool ends 6 into them), and 100
        // older: the edge date's matches belong to the second window together, in the order of their ranks
        // (the more words, the worse the rank).
        let newer = pool - 6
        var messages = (0..<newer).map { i in
            Message(id: "newer\(i)", subject: "Pangolin", dateMs: start + Int64(1_000 + i) * Self.minute, vector: i == 0 ? query : nil)
        }
        messages += (0..<20).map { i in
            Message(id: "edge\(i)", subject: "Pangolin " + String(repeating: "weather ", count: i), dateMs: start + 500 * Self.minute)
        }
        messages += (0..<100).map { i in Message(id: "older\(i)", subject: "Pangolin", dateMs: start + Int64(i) * Self.minute) }
        let limit = newer + 20 + 100
        try await withMessages(messages + filler(3 * limit, at: start - Self.day)) {
            let from = start - Self.day, to = start + 100 * Self.day
            // The total, and a limit the first window cannot fill: the second window gives only what is left.
            for sort in [SearchSort.dateDesc, .dateAsc] {
                for wanted in [limit, newer + 5] {
                    let results = try await search("pangolin", query, from: from, to: to, limit: wanted, sort: sort)
                    #expect(ids(results).count == wanted, "\(sort) \(wanted)")
                    let exact = try await exactKeyword("pangolin", from: from, to: to, limit: wanted, sort: sort)
                    #expect(ids(results) == exact, "\(sort) \(wanted)")
                }
            }
        }
    }

    @Test("a date sort finds the newest and the oldest match past the vector pool")
    func exactPastTheVectorPool() async throws {
        let start = try Self.start()
        let pool = SearchConfig.dateSortPool
        let query = Self.vector(36, 37, cos: 1)
        // 5,000 messages on the query's vector and one farther, a match by meaning alone (no message has
        // the word), newest (oldest) for the descending (ascending) sort: the nearest 4,096 leave it out.
        for (sort, farDate) in [(SearchSort.dateDesc, start + Int64(pool + 2_000) * Self.minute), (.dateAsc, start - Self.minute)] {
            var messages = (0..<(pool + 904)).map { i in
                Message(id: "near\(i)", subject: "Quokka", dateMs: start + Int64(i) * Self.minute, vector: query)
            }
            messages.append(Message(id: "far", subject: "Quokka", dateMs: farDate, vector: Self.vector(36, 37, cos: 0.8)))
            try await withMessages(messages) {
                let from = start - Self.day, to = start + 10 * Self.day
                let results = try await search("zyxwvut", query, from: from, to: to, limit: 10, sort: sort)
                let near = sort == .dateDesc ? (0..<9).map { "near\(pool + 903 - $0)" } : (0..<9).map { "near\($0)" }
                #expect(ids(results) == ["far"] + near, "\(sort)")
            }
        }
    }

    @Test("a date sort scores a keyword match by its own meaning, whatever window found it")
    func scoresAreTheirOwn() async throws {
        let start = try Self.start()
        let pool = SearchConfig.dateSortPool
        let query = Self.vector(38, 39, cos: 1)
        // A pool of weak neighbours (cosine 0.50: above the threshold, under what a match by meaning alone
        // needs) nearer than two keyword matches at 0.48 and 0.47: the matches are outside the vector pool,
        // and each still counts its own meaning, as when the dates hold only it.
        var messages = (0..<(pool + 104)).map { i in
            Message(id: "weak\(i)", subject: "Quokka", dateMs: start + Int64(10 + i) * Self.minute, vector: Self.vector(38, 39, cos: 0.5))
        }
        messages.append(Message(id: "matchA", subject: "Pangolin", dateMs: start + 1 * Self.minute, vector: Self.vector(38, 39, cos: 0.48)))
        messages.append(Message(id: "matchB", subject: "Pangolin", dateMs: start + 2 * Self.minute, vector: Self.vector(38, 39, cos: 0.47)))
        try await withMessages(messages + filler(20, at: start - Self.day)) {
            let from = start - Self.day, to = start + 100 * Self.day
            for sort in [SearchSort.dateDesc, .dateAsc] {
                let all = try await search("pangolin", query, from: from, to: to, limit: 10, sort: sort)
                #expect(ids(all) == (sort == .dateDesc ? ["matchB", "matchA"] : ["matchA", "matchB"]), "\(sort)")
                for result in all {
                    let alone = try await search("pangolin", query, from: result.dateMs, to: result.dateMs, limit: 10, sort: sort)
                    #expect(ids(alone) == ids([result]), "\(sort)")
                    #expect(alone.first?.rank == result.rank, "the score of \(ids([result])) does not depend on the window, \(sort)")
                }
            }
        }
    }

    @Test("a date sort with a pool of keyword matches at one date terminates, answers and walks on")
    func poolOfMatchesAtOneDateTerminates() async throws {
        let start = try Self.start()
        let query = Self.vector(40, 41, cos: 1)
        let pool = SearchConfig.dateSortPool
        var messages = (0..<(pool + 4)).map { i in
            Message(id: "same\(i)", subject: "Pangolin", dateMs: start, vector: i == 0 ? query : nil)
        }
        // 30 matches before that date: a limit past the pool gets the walk's next window, for either sort.
        messages += (0..<30).map { i in Message(id: "older\(i)", subject: "Pangolin", dateMs: start - Self.day / 2 + Int64(i) * Self.minute) }
        try await withMessages(messages + filler(2 * pool, at: start - Self.day)) {
            for sort in [SearchSort.dateDesc, .dateAsc] {
                let results = try await search("pangolin", query, from: start - Self.day, to: start + Self.day, limit: 10, sort: sort)
                #expect(results.count == 10, "\(sort)")
                let more = ids(try await search("pangolin", query, from: start - Self.day, to: start + Self.day, limit: pool + 20, sort: sort))
                #expect(more.count == pool + 20, "\(sort)")
                guard more.count == pool + 20 else { continue }
                let older = (0..<30).map { "older\($0)" }
                #expect(sort == .dateDesc ? Array(more.suffix(20)) == Array(older.reversed().prefix(20)) : Array(more.prefix(30)) == older, "\(sort)")
            }
        }
    }

    @Test("a date sort answers by keyword, ranks included, when no vector is within the dates")
    func keywordOnlyWhenNoVectorIsWithinTheDates() async throws {
        let start = try Self.start()
        let query = Self.vector(44, 45, cos: 1)
        let messages = (0..<12).map { i in
            Message(id: "kw\(i)", subject: "Pangolin " + String(repeating: "weather ", count: i), dateMs: start + Int64(i) * Self.minute)
        }
        try await withMessages(messages + filler(60, at: start - Self.day)) {
            for sort in [SearchSort.dateDesc, .dateAsc] {
                let results = try await search("pangolin", query, from: start - Self.day, to: start + Self.day, limit: 10, sort: sort)
                let exact = try await index.searchFTSOnly(ftsQuery: SearchQueryParser.buildFTSMatch("pangolin"), fromDateMs: start - Self.day,
                                                          toDateMs: start + Self.day, limit: 10, sort: sort)
                #expect(ids(results) == ids(exact), "\(sort)")
                #expect(results.map(\.rank) == exact.map(\.rank), "\(sort)")
            }
        }
    }

    @Test("a date sort whose limit is reached before the dates holding the only vector still counts that vector")
    func vectorOnlyInTheDatesNotWalked() async throws {
        let start = try Self.start()
        let pool = SearchConfig.dateSortPool
        let query = Self.vector(46, 47, cos: 1)
        for sort in [SearchSort.dateDesc, .dateAsc] {
            // A pool and more of keyword matches without a vector at the end the sort starts at; the one
            // vector is on a match at the other end, in the dates the first window does not reach.
            let vectorDate = sort == .dateDesc ? start : start + Int64(pool + 20) * Self.minute
            var messages = (0..<(pool + 10)).map { i in
                Message(id: "kw\(i)", subject: "Pangolin", dateMs: start + Int64(i + 1) * Self.minute)
            }
            messages.append(Message(id: "vec", subject: "Pangolin", dateMs: vectorDate, vector: query))
            try await withMessages(messages + filler(3 * pool, at: start - Self.day)) {
                let from = start - Self.day, to = start + Int64(pool + 100) * Self.minute
                let results = try await search("pangolin", query, from: from, to: to, limit: 10, sort: sort)
                let exact = try await index.searchFTSOnly(ftsQuery: SearchQueryParser.buildFTSMatch("pangolin"), fromDateMs: from,
                                                          toDateMs: to, limit: 10, sort: sort)
                #expect(ids(results).count == 10, "\(sort)")
                // Scored with a vector in the dates (hybrid scores), as a search that reaches it scores them,
                // not by keyword alone.
                #expect(results.map(\.rank) != exact.map(\.rank), "\(sort)")
            }
        }
    }

    @Test("a date sort reads the demo mode once, at the start of its walk")
    func demoModeIsReadOnce() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("TabMail/Services/Search/SearchIndex.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private func dateWindowCandidates("))
        let end = try #require(source.range(of: "// MARK: - Internal Search Helpers", range: start.upperBound..<source.endIndex))
        let walk = source[start.lowerBound..<end.lowerBound]
        // One read, bound once to a constant: a computed property reading it again would pass a count alone.
        #expect(walk.components(separatedBy: "DemoModeStore.isDemoActive").count - 1 == 1)
        #expect(walk.contains("let demoActive = DemoModeStore.isDemoActive"))
    }

    @Test("a date sort over more weak semantic matches than a pool stays within its dates and demo mode")
    func denseWeakSemanticMatchesStayInScope() async throws {
        let start = try Self.start()
        let pool = SearchConfig.dateSortPool
        let query = Self.vector(48, 49, cos: 1)
        func record(_ key: String, _ dateMs: Int64) -> FTSHeaderRecord {
            FTSHeaderRecord(contentKey: ContentKey(rawValue: key), headerId: key, messageId: key,
                            subject: "Quokka", from: "a@example.com", to: "b@example.com", dateMs: dateMs)
        }
        // More than a pool of weak matches by meaning alone (just over what such a match needs), and stronger
        // vectors that are not to be answered: before and after the dates, and of the demo account.
        let weak = (0..<(pool + 904)).map { record("windowweakacct:INBOX:w\($0)", start + Int64($0) * Self.minute) }
        let outside = [record("windowweakacct:INBOX:before", start - 3 * Self.day), record("windowweakacct:INBOX:after", start + 20 * Self.day)]
        let demo = (0..<3).map { record("\(DemoSeed.demoAccountId):INBOX:windowweakdemo\($0)", start + Int64($0) * Self.minute) }
        let all = weak + outside + demo
        let keys = all.map(\.contentKey)
        try await index.removeMessages(contentKeys: keys)
        #expect(try await index.indexHeaders(all) == all.count)
        try await index.storeEmbeddings(weak.map { (contentKey: $0.contentKey, embedding: Self.vector(48, 49, cos: 0.53)) }
                                        + (outside + demo).map { (contentKey: $0.contentKey, embedding: Self.vector(48, 49, cos: 0.9)) })
        var answers: [SearchSort: [String]] = [:]
        do {
            for sort in [SearchSort.dateDesc, .dateAsc] {
                answers[sort] = try await search("zyxwvut", query, from: start - Self.day, to: start + 10 * Self.day, limit: 10, sort: sort)
                    .map(\.contentKey.rawValue)
            }
        } catch {
            try await index.removeMessages(contentKeys: keys)
            throw error
        }
        try await index.removeMessages(contentKeys: keys)
        let w = weak.map(\.contentKey.rawValue)
        #expect(answers[.dateDesc] == Array(w.suffix(10).reversed()), "\(answers)")
        #expect(answers[.dateAsc] == Array(w.prefix(10)), "\(answers)")
    }

    @Test("a date sort that stops early answers by keyword, ranks included, when the only vectors are outside its dates")
    func keywordOnlyWhenVectorsAreOutsideTheDates() async throws {
        let start = try Self.start()
        let pool = SearchConfig.dateSortPool
        let query = Self.vector(50, 51, cos: 1)
        for outsideVector in [false, true] {
            var messages = (0..<(pool + 10)).map { i in
                Message(id: "kw\(i)", subject: "Pangolin", dateMs: start + Int64(i + 1) * Self.minute)
            }
            messages.append(Message(id: "outside", subject: "Quokka", dateMs: start - 5 * Self.day, vector: outsideVector ? query : nil))
            try await withMessages(messages + filler(3 * pool, at: start - Self.day)) {
                let from = start - Self.day, to = start + 10 * Self.day
                for sort in [SearchSort.dateDesc, .dateAsc] {
                    let results = try await search("pangolin", query, from: from, to: to, limit: 10, sort: sort)
                    let exact = try await index.searchFTSOnly(ftsQuery: SearchQueryParser.buildFTSMatch("pangolin"), fromDateMs: from,
                                                              toDateMs: to, limit: 10, sort: sort)
                    #expect(ids(results).count == 10, "\(sort) \(outsideVector)")
                    #expect(ids(results) == ids(exact), "\(sort) \(outsideVector)")
                    #expect(results.map(\.rank) == exact.map(\.rank), "\(sort) \(outsideVector)")
                }
            }
        }
    }

    @Test("a date sort answers by keyword when the vector read fails")
    func keywordOnlyWhenTheVectorReadFails() async throws {
        let start = try Self.start()
        let messages = (0..<12).map { i in
            Message(id: "kw\(i)", subject: "Pangolin " + String(repeating: "weather ", count: i), dateMs: start + Int64(i) * Self.minute,
                    vector: Self.vector(52, 53, cos: 1))
        }
        try await withMessages(messages + filler(60, at: start - Self.day)) {
            // An embedding of the wrong size: sqlite-vec refuses it.
            let wrongSize = [Float](repeating: 1, count: 8)
            for sort in [SearchSort.dateDesc, .dateAsc] {
                let results = try await search("pangolin", wrongSize, from: start - Self.day, to: start + Self.day, limit: 10, sort: sort)
                let exact = try await index.searchFTSOnly(ftsQuery: SearchQueryParser.buildFTSMatch("pangolin"), fromDateMs: start - Self.day,
                                                          toDateMs: start + Self.day, limit: 10, sort: sort)
                #expect(ids(results).count == 10, "\(sort)")
                #expect(ids(results) == ids(exact), "\(sort)")
                #expect(results.map(\.rank) == exact.map(\.rank), "\(sort)")
            }
        }
    }

    @Test("every sort keeps a keyword match's snippet and leaves a match by meaning alone without one")
    func snippetsSurviveEverySort() async throws {
        let start = try Self.start()
        let query = Self.vector(54, 55, cos: 1)
        let messages = [
            Message(id: "keyword", subject: "Pangolin", dateMs: start + Self.minute, vector: Self.vector(54, 55, cos: 0.9)),
            Message(id: "meaning", subject: "Quokka", dateMs: start + 2 * Self.minute, vector: Self.vector(54, 55, cos: 0.9)),
        ]
        try await withMessages(messages + filler(20, at: start - Self.day)) {
            for sort in [SearchSort.relevance, .dateDesc, .dateAsc] {
                let results = try await search("pangolin", query, from: start - Self.day, to: start + Self.day, limit: 10, sort: sort)
                let byId = Dictionary(uniqueKeysWithValues: results.map { (String($0.contentKey.rawValue.dropFirst(Self.prefix.count)), $0) })
                #expect(Set(byId.keys) == ["keyword", "meaning"], "\(sort)")
                #expect(byId["keyword"]?.snippet.contains("[") == true, "\(sort)")
                #expect(byId["keyword"]?.dateMs == start + Self.minute, "\(sort)")
                #expect(byId["meaning"]?.snippet == "", "\(sort)")
            }
        }
    }

    @Test("a date sort in the demo mode finds the demo vectors past a pool of nearer real ones")
    func demoScopeInsideTheVectorSearch() async throws {
        let start = try Self.start()
        let pool = SearchConfig.dateSortPool
        let query = Self.vector(44, 45, cos: 1)
        func record(_ key: String, _ dateMs: Int64) -> FTSHeaderRecord {
            FTSHeaderRecord(contentKey: ContentKey(rawValue: key), headerId: key, messageId: key,
                            subject: "Quokka", from: "a@example.com", to: "b@example.com", dateMs: dateMs)
        }
        // More than a pool of real vectors on the query, and 5 demo vectors farther (matches by meaning
        // alone): the nearest pool, scoped after the search, holds only real ones, none in the demo mode.
        let real = (0..<(pool + 904)).map { record("windowrealacct:INBOX:r\($0)", start + Int64($0) * Self.minute) }
        let demo = (0..<5).map { record("\(DemoSeed.demoAccountId):INBOX:windowdemo\($0)", start + Int64($0) * Self.minute) }
        let all = real + demo
        let keys = all.map(\.contentKey)
        try await index.removeMessages(contentKeys: keys)
        #expect(try await index.indexHeaders(all) == all.count)
        try await index.storeEmbeddings(real.map { (contentKey: $0.contentKey, embedding: query) }
                                        + demo.map { (contentKey: $0.contentKey, embedding: Self.vector(44, 45, cos: 0.8)) })
        await MainActor.run { DemoModeStore.shared.isActive = true }
        var answers: [SearchSort: [String]] = [:]
        do {
            for sort in [SearchSort.dateDesc, .dateAsc] {
                answers[sort] = try await search("zyxwvut", query, from: start - Self.day, to: start + 10 * Self.day, limit: 10, sort: sort)
                    .map(\.contentKey.rawValue)
            }
        } catch {
            await MainActor.run { DemoModeStore.shared.isActive = false }
            try await index.removeMessages(contentKeys: keys)
            throw error
        }
        await MainActor.run { DemoModeStore.shared.isActive = false }
        try await index.removeMessages(contentKeys: keys)
        let d = demo.map(\.contentKey.rawValue)
        #expect(answers[.dateDesc] == d.reversed(), "\(answers)")
        #expect(answers[.dateAsc] == d, "\(answers)")
    }

    @Test("a date sort at the ends of time answers nothing outside its dates")
    func endsOfTime() async throws {
        let start = try Self.start()
        let query = Self.vector(42, 43, cos: 1)
        let messages = (0..<5).map { i in
            Message(id: "end\(i)", subject: "Pangolin", dateMs: start + Int64(i) * Self.minute, vector: query)
        }
        try await withMessages(messages + filler(20, at: start - Self.day)) {
            for sort in [SearchSort.dateDesc, .dateAsc] {
                let afterEnd = try await search("pangolin", query, from: Int64.max, to: nil, limit: 10, sort: sort)
                let beforeStart = try await search("pangolin", query, from: nil, to: Int64.min, limit: 10, sort: sort)
                let everything = try await search("pangolin", query, from: Int64.min, to: Int64.max, limit: 10, sort: sort)
                #expect(afterEnd.isEmpty, "\(sort)")
                #expect(beforeStart.isEmpty, "\(sort)")
                #expect(everything.count == 5, "\(sort)")
            }
        }
    }
}
