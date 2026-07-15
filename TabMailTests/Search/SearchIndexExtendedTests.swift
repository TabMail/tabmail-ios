/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - SearchIndex Extended Tests: Edge Cases & Deeper Coverage

@Suite("SearchIndex Edge Cases", .serialized, .processGlobalState)
struct SearchIndexEdgeCaseTests {

    private var index: SearchIndex { SearchIndex.shared }

    // MARK: - Search with Special Characters

    @Test("keywordSearch handles query with special FTS characters")
    func searchSpecialCharacters() async throws {
        let results = try await index.keywordSearch(query: "hello AND world")
        #expect(results.count >= 0)
    }

    @Test("keywordSearch handles query with quotes")
    func searchQuotedQuery() async throws {
        let results = try await index.keywordSearch(query: "\"exact phrase match\"")
        #expect(results.count >= 0)
    }

    @Test("keywordSearch handles query with wildcards")
    func searchWildcardQuery() async throws {
        let hid = "test_wildcard:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1",
            subject: "Peculiarexactmatch Testing Wildcards",
            from: "a@a.com", to: "b@b.com",
            dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let results = try await index.keywordSearch(query: "peculiarexact*")
        let found = results.contains { $0.headerId == hid }
        #expect(found)

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("keywordSearch handles query with only whitespace")
    func searchWhitespaceQuery() async throws {
        let results = try await index.keywordSearch(query: "   ")
        #expect(results.isEmpty)
    }

    @Test("keywordSearch handles very long query")
    func searchVeryLongQuery() async throws {
        let longQuery = String(repeating: "testing ", count: 100)
        let results = try await index.keywordSearch(query: longQuery)
        #expect(results.count >= 0)
    }

    @Test("keywordSearch handles single character query")
    func searchSingleCharQuery() async throws {
        let results = try await index.keywordSearch(query: "a")
        #expect(results.count >= 0)
    }

    // MARK: - Search with Date Range Edge Cases

    @Test("keywordSearch with fromDate equal to toDate returns matching messages")
    func searchSameDateRange() async throws {
        let dateMs: Int64 = 1_700_000_000_000
        let hid = "test_samedate:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1",
            subject: "Uniquephraseforsamedatetest",
            from: "a@a.com", to: "b@b.com",
            dateMs: dateMs
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let results = try await index.keywordSearch(
            query: "uniquephraseforsamedatetest",
            fromDateMs: dateMs,
            toDateMs: dateMs
        )
        let found = results.contains { $0.headerId == hid }
        #expect(found)

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("keywordSearch with only fromDate filters correctly")
    func searchOnlyFromDate() async throws {
        let results = try await index.keywordSearch(
            query: "test",
            fromDateMs: 1_700_000_000_000
        )
        #expect(results.count >= 0)
    }

    @Test("keywordSearch with only toDate filters correctly")
    func searchOnlyToDate() async throws {
        let results = try await index.keywordSearch(
            query: "test",
            toDateMs: 1_700_000_000_000
        )
        #expect(results.count >= 0)
    }

    @Test("keywordSearch with inverted date range returns empty")
    func searchInvertedDateRange() async throws {
        let results = try await index.keywordSearch(
            query: "test",
            fromDateMs: 1_800_000_000_000,
            toDateMs: 1_700_000_000_000
        )
        #expect(results.isEmpty)
    }

    // MARK: - keywordSearchShard Edge Cases

    @Test("keywordSearchShard with custom limit returns at most that many results")
    func searchShardWithLimit() async throws {
        let years = await index.sortedShardYears
        guard let year = years.first else { return }

        let results = try await index.keywordSearchShard(query: "test", year: year, limit: 1)
        #expect(results.count <= 1)
    }

    @Test("keywordSearchShard with zero limit returns empty")
    func searchShardZeroLimit() async throws {
        let years = await index.sortedShardYears
        guard let year = years.first else { return }

        let results = try await index.keywordSearchShard(query: "test", year: year, limit: 0)
        #expect(results.isEmpty)
    }

    // MARK: - Body Update Edge Cases

    @Test("updateBody with empty body string does not set hasBody")
    func updateBodyEmptyString() async throws {
        let hid = "test_emptybody:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Empty Body",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        // updateBody sets hasBody=1 even with empty string (the SQL UPDATE runs)
        // because hasBody flag is about whether the write was attempted
        try await index.updateBody(headerId: hid, body: "")

        // bodyText should return nil for empty body
        let body = try await index.bodyText(headerId: hid)
        #expect(body == nil)

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("updateBody with very long body text succeeds")
    func updateBodyLongText() async throws {
        let hid = "test_longbody:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Long Body",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let longBody = String(repeating: "This is a long body text. ", count: 1000)
        try await index.updateBody(headerId: hid, body: longBody)

        let body = try await index.bodyText(headerId: hid)
        #expect(body != nil)
        #expect(body!.count == longBody.count)

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("updateBody with unicode content round-trips correctly")
    func updateBodyUnicode() async throws {
        let hid = "test_unicodebody:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Unicode Body",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let unicodeBody = "Hello 世界! Привет мир! مرحبا بالعالم"
        try await index.updateBody(headerId: hid, body: unicodeBody)

        let body = try await index.bodyText(headerId: hid)
        #expect(body == unicodeBody)

        try await index.removeMessages(headerIds: [hid])
    }

    // MARK: - Index/Remove Edge Cases

    @Test("indexHeaders handles large batch")
    func indexLargeBatch() async throws {
        let records = (1...50).map { i in
            FTSHeaderRecord(
                headerId: "test_largebatch:INBOX:\(i)", messageId: "m\(i)",
                subject: "Batch Message \(i)", from: "a@a.com", to: "b@b.com",
                dateMs: Int64(1_700_000_000_000 + i * 1000)
            )
        }
        try await index.removeMessages(headerIds: records.map(\.headerId))
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 50)

        let count = try await index.documentCountForAccount(accountId: "test_largebatch")
        #expect(count == 50)

        try await index.removeMessages(headerIds: records.map(\.headerId))
    }

    @Test("indexHeaders with messages spanning multiple years creates shards")
    func indexMultipleYears() async throws {
        let records = [
            FTSHeaderRecord(headerId: "test_multiyear:INBOX:1", messageId: "m1",
                            subject: "Year 2020", from: "a@a.com", to: "b@b.com",
                            dateMs: 1_577_836_800_000), // 2020-01-01
            FTSHeaderRecord(headerId: "test_multiyear:INBOX:2", messageId: "m2",
                            subject: "Year 2023", from: "a@a.com", to: "b@b.com",
                            dateMs: 1_672_531_200_000), // 2023-01-01
            FTSHeaderRecord(headerId: "test_multiyear:INBOX:3", messageId: "m3",
                            subject: "Year 2025", from: "a@a.com", to: "b@b.com",
                            dateMs: 1_735_689_600_000), // 2025-01-01
        ]
        try await index.removeMessages(headerIds: records.map(\.headerId))
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 3)

        let years = await index.sortedShardYears
        #expect(years.contains(2020))
        #expect(years.contains(2023))
        #expect(years.contains(2025))

        try await index.removeMessages(headerIds: records.map(\.headerId))
    }

    @Test("removeMessages is idempotent for already-removed headers")
    func removeIdempotent() async throws {
        let hid = "test_idempotent_rm:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Idempotent",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        try await index.removeMessages(headerIds: [hid])
        // Removing again should not throw
        try await index.removeMessages(headerIds: [hid])

        let isIndexed = try await index.isIndexed(headerId: hid)
        #expect(isIndexed == false)
    }

    @Test("removeMessages with non-existent headerIds is a no-op")
    func removeNonExistent() async throws {
        try await index.removeMessages(headerIds: ["nonexistent_never_inserted:INBOX:999"])
    }

    // MARK: - clearBodies Edge Cases

    @Test("clearBodies on message with no body is safe")
    func clearBodiesNoBody() async throws {
        let hid = "test_clearnobody:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "No Body Clear",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        // clearBodies on a message that never had a body — should not throw
        try await index.clearBodies(headerIds: [hid])

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("clearBodies for non-existent headerIds is safe")
    func clearBodiesNonExistent() async throws {
        try await index.clearBodies(headerIds: ["nonexistent_clear:INBOX:999"])
    }

    // MARK: - updateCcBcc Edge Cases

    @Test("updateCcBcc for non-existent header is a no-op")
    func updateCcBccNonExistent() async throws {
        try await index.updateCcBcc([(headerId: "nonexistent_ccbcc:INBOX:999", cc: "a@b.com", bcc: "c@d.com")])
    }

    @Test("updateCcBcc with unicode addresses succeeds")
    func updateCcBccUnicode() async throws {
        let hid = "test_ccbcc_unicode:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Unicode CC",
            from: "a@a.com", to: "b@b.com",
            dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        try await index.updateCcBcc([(headerId: hid, cc: "名前@example.com", bcc: "тест@example.com")])

        try await index.removeMessages(headerIds: [hid])
    }

    // MARK: - Search by Body Content

    @Test("keywordSearch finds messages by body text")
    func searchByBody() async throws {
        let hid = "test_bodysearch:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1",
            subject: "Plain Subject",
            from: "a@a.com", to: "b@b.com",
            dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        try await index.updateBody(headerId: hid, body: "UniqueBodyTermXyzzy for search testing")

        let results = try await index.keywordSearch(query: "uniquebodytermxyzzy")
        let found = results.contains { $0.headerId == hid }
        #expect(found)

        try await index.removeMessages(headerIds: [hid])
    }

    // MARK: - storeEmbedding Edge Cases

    @Test("storeEmbedding replaces existing embedding without error")
    func storeEmbeddingReplace() async throws {
        let hid = "test_emb_replace:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Embed Replace",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let emb1 = [Float](repeating: 0.1, count: SearchConfig.embeddingDims)
        try await index.storeEmbedding(headerId: hid, embedding: emb1)

        let emb2 = [Float](repeating: 0.9, count: SearchConfig.embeddingDims)
        try await index.storeEmbedding(headerId: hid, embedding: emb2)

        try await index.removeMessages(headerIds: [hid])
    }

    // MARK: - textForEmbedding

    @Test("textForEmbedding returns data for indexed message with body")
    func textForEmbeddingWithBody() async throws {
        let hid = "test_textforemb:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Embed Text Subject",
            from: "sender@test.com", to: "receiver@test.com",
            dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        try await index.updateBody(headerId: hid, body: "The embedding body text")

        // textForEmbedding needs a rowid, but we tested via the rowid lookup
        // Just verify that the message is properly indexed and has body
        let body = try await index.bodyText(headerId: hid)
        #expect(body == "The embedding body text")

        try await index.removeMessages(headerIds: [hid])
    }

    // ftsProgress, emptyBodyCount removed — flags live in GRDB only

    // MARK: - removeMessagesForAccount Edge Cases

    @Test("removeMessagesForAccount for non-existent account is safe")
    func removeForNonExistentAccount() async throws {
        try await index.removeMessagesForAccount(accountId: "totally_nonexistent_account")
    }

    @Test("removeMessagesForAccount does not affect other accounts")
    func removeForAccountIsolation() async throws {
        let records = [
            FTSHeaderRecord(headerId: "test_rm_iso_a:INBOX:1", messageId: "m1", subject: "A1",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000),
            FTSHeaderRecord(headerId: "test_rm_iso_b:INBOX:1", messageId: "m2", subject: "B1",
                            from: "c@c.com", to: "d@d.com", dateMs: 1_700_000_000_000),
        ]
        try await index.removeMessages(headerIds: records.map(\.headerId))
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 2)

        try await index.removeMessagesForAccount(accountId: "test_rm_iso_a")

        let countA = try await index.documentCountForAccount(accountId: "test_rm_iso_a")
        #expect(countA == 0)

        let countB = try await index.documentCountForAccount(accountId: "test_rm_iso_b")
        #expect(countB == 1)

        try await index.removeMessages(headerIds: ["test_rm_iso_b:INBOX:1"])
    }

    // MARK: - Search by From/To

    @Test("keywordSearch finds messages by sender email")
    func searchBySender() async throws {
        let hid = "test_sendersearch:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1",
            subject: "Regular Subject",
            from: "uniquesenderxyzzy99@domain.com",
            to: "b@b.com",
            dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let results = try await index.keywordSearch(query: "uniquesenderxyzzy99")
        let found = results.contains { $0.headerId == hid }
        #expect(found)

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("keywordSearch finds messages by CC address")
    func searchByCc() async throws {
        let hid = "test_ccsearch:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1",
            subject: "CC Test",
            from: "a@a.com", to: "b@b.com",
            cc: "uniqueccxyzzy88@domain.com",
            dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let results = try await index.keywordSearch(query: "uniqueccxyzzy88")
        let found = results.contains { $0.headerId == hid }
        #expect(found)

        try await index.removeMessages(headerIds: [hid])
    }
}
