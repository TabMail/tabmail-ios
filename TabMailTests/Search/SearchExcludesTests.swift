/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// A search that excludes (a kept NOT) answers by keyword, and the vector leg's field filter keeps each
/// alternative between ORs (tabmail-ios#301, mirroring tabmail-native-fts #21, ADR-NF-019). The
/// messages are dated in a year shard no other fixture uses, so the keyword scores are their own.
@Suite("SearchIndex excluding and OR searches", .serialized, .processGlobalState)
struct SearchExcludesTests {

    private var index: SearchIndex { SearchIndex.shared }
    private static let prefix = "test_search_excludes:INBOX:"

    /// March 1st, 160 years ahead.
    private static func start() throws -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let year = calendar.component(.year, from: Date()) + 160
        let date = try #require(calendar.date(from: DateComponents(year: year, month: 3, day: 1)))
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private struct Message {
        let id: String
        let from: String
        let subject: String
        let body: String
    }

    /// Indexes the messages on one day, each with the vector the indexer gives it, runs `run` with that
    /// day, and removes them.
    private func withMessages(_ messages: [Message], model: EmbeddingService,
                              _ run: (Int64) async throws -> Void) async throws {
        let start = try Self.start()
        let keys = messages.map { ContentKey(rawValue: Self.prefix + $0.id) }
        try await index.removeMessages(contentKeys: keys)
        #expect(try await index.indexHeaders(messages.map {
            FTSHeaderRecord(contentKey: ContentKey(rawValue: Self.prefix + $0.id), headerId: Self.prefix + $0.id, messageId: $0.id,
                            subject: $0.subject, from: $0.from, to: "team@example.com", dateMs: start)
        }) == messages.count)
        for m in messages {
            try await index.updateBody(contentKey: ContentKey(rawValue: Self.prefix + m.id), body: m.body)
        }
        try await index.storeEmbeddings(try messages.map {
            let text = EmbeddingService.prepareEmailText(subject: $0.subject, from: $0.from, to: "team@example.com", body: $0.body)
            return (contentKey: ContentKey(rawValue: Self.prefix + $0.id), embedding: try model.embed(text))
        })
        do {
            try await run(start)
        } catch {
            try await index.removeMessages(contentKeys: keys)
            throw error
        }
        try await index.removeMessages(contentKeys: keys)
    }

    private func ids(_ results: [FTSSearchResult]) -> [String] {
        results.map { String($0.contentKey.rawValue.dropFirst(Self.prefix.count)) }
    }

    /// native-fts `search_excluding_a_sender_or_a_word_returns_none_of_it`.
    @Test("a search excluding a sender or a word returns none of it, in every sort")
    func searchExcludingASenderOrAWordReturnsNoneOfIt() async throws {
        EmbeddingService.initialize()
        defer { EmbeddingService._testUnload() }
        let model = try #require(EmbeddingService.shared)
        let messages = [Message(id: "erin", from: "erin@example.com", subject: "Lunch", body: "Lunch on Friday at noon"),
                        Message(id: "frank", from: "frank@example.com", subject: "Lunch", body: "Lunch on Friday at noon"),
                        Message(id: "itinerary", from: "erin@example.com", subject: "Vacation", body: "The vacation itinerary and hotels"),
                        Message(id: "plans", from: "erin@example.com", subject: "Vacation", body: "Vacation plans for the summer")]
        try await withMessages(messages, model: model) { day in
            for (q, expected) in [
                ("lunch NOT from:erin@example.com", ["frank"]),
                ("lunch NOT from:frank@example.com", ["erin"]),
                ("lunch on friday NOT from:erin@example.com", ["frank"]),
                // An operator after the NOT leaves it excluding.
                ("lunch NOT from:erin@example.com AND lunch", ["frank"]),
                ("lunch NOT from:erin@example.com OR dinner", ["frank"]),
                ("vacation NOT itinerary", ["plans"]),
                ("vacation NOT from:erin@example.com", []),
            ] {
                for sort in [SearchSort.relevance, .dateDesc, .dateAsc] {
                    let results = try await index.search(query: q, fromDateMs: day, toDateMs: day, limit: 10, sort: sort)
                    #expect(ids(results) == expected, "\(q) \(sort)")
                }
            }
        }
    }

    /// native-fts `search_with_an_or_finds_by_meaning_within_what_each_alternative_allows`.
    @Test("a search with an OR finds by meaning within what each alternative allows")
    func searchWithAnOrFindsByMeaningWithinEachAlternative() async throws {
        EmbeddingService.initialize()
        defer { EmbeddingService._testUnload() }
        let model = try #require(EmbeddingService.shared)
        // Near the queries by meaning, with none of their words: one from b, one from c.
        let messages = [Message(id: "from-b", from: "b@example.com", subject: "Holiday", body: "The route and hotels for our summer holiday"),
                        Message(id: "from-c", from: "c@example.com", subject: "Holiday", body: "The route and hotels for our summer trip")]
        try await withMessages(messages, model: model) { day in
            for (q, expected) in [
                ("from:a@example.com OR from:b@example.com plan the vacation itinerary", ["from-b"]),
                ("subject:launch OR plan the vacation itinerary", ["from-b", "from-c"]),
            ] {
                let results = try await index.search(query: q, fromDateMs: day, toDateMs: day, limit: 10, sort: .relevance)
                #expect(ids(results).sorted() == expected, "\(q)")
                #expect(results.allSatisfy { $0.snippet.isEmpty }, "found by meaning, not by their words: \(q)")
            }
        }
    }

    /// native-fts `test_extract_column_scope_filter_keeps_each_alternative_between_ors`.
    @Test("the vector filter keeps each alternative between ORs")
    func filterKeepsEachAlternativeBetweenOrs() {
        // Each alternative keeps the AND of its own fields; free terms match anything.
        #expect(SearchIndex.extractColumnScopeFilter(#"from_:"a@example.com" OR from_:"b@example.com" "budget"*"#)
                == #"from_:"a@example.com" OR from_:"b@example.com""#)
        #expect(SearchIndex.extractColumnScopeFilter(#"from_:"a@example.com" "budget"* OR from_:"b@example.com" subject:launch"#)
                == #"from_:"a@example.com" OR from_:"b@example.com" subject:launch"#)
        // An alternative without a field allows every row: no filter.
        #expect(SearchIndex.extractColumnScopeFilter(#""itinerary"* OR subject:"launch"*"#) == "")
        #expect(SearchIndex.extractColumnScopeFilter(#"from_:"a@example.com" AND "budget"* OR "lunch"*"#) == "")
        // An OR inside a group is not between alternatives.
        #expect(SearchIndex.extractColumnScopeFilter(#"from_:"a@example.com" AND ("hiring" OR "recruit")"#)
                == #"from_:"a@example.com""#)
    }

    /// native-fts `a_query_that_keeps_a_not_excludes`.
    @Test("a query excludes when it keeps a NOT; a NOT dropped, quoted, lower-case or a field's value excludes nothing")
    func aQueryThatKeepsANotExcludes() {
        for q in ["lunch NOT from:erin@example.com", "subject:budget NOT from:bob@example.com", "vacation NOT itinerary",
                  #"vacation NOT "summer itinerary""#, "invoice NOT receipt", "abcd NOT don't",
                  "lunch OR dinner NOT from:erin@example.com", "lunch NOT from:erin@example.com AND lunch",
                  "vacation NOT itinerary OR summer"] {
            let built = SearchQueryParser.buildFTSMatch(q)
            #expect(SearchIndex.queryExcludes(built), "\(q) -> \(built)")
        }
        for q in ["lunch", "NOT receipt", "abcd NOT", "abcd OR NOT efgh", #""lunch NOT dinner""#, "lunch not dinner",
                  "subject:NOT lunch", "from:a@example.com OR to:a@example.com", ""] {
            let built = SearchQueryParser.buildFTSMatch(q)
            #expect(!SearchIndex.queryExcludes(built), "\(q) -> \(built)")
        }
    }
}
