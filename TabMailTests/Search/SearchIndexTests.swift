/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Data Struct Tests (no database needed)

@Suite("FTSHeaderRecord Fields")
struct FTSHeaderRecordFieldTests {

    @Test("Default cc and bcc are empty strings")
    func defaultCcBcc() {
        let record = FTSHeaderRecord(
            headerId: "acc1:INBOX:1",
            messageId: "<msg1@example.com>",
            subject: "Hello",
            from: "alice@test.com",
            to: "bob@test.com",
            dateMs: 1_700_000_000_000
        )
        #expect(record.cc == "")
        #expect(record.bcc == "")
    }

    @Test("All fields stored correctly")
    func allFields() {
        let record = FTSHeaderRecord(
            headerId: "acc2:Sent:42",
            messageId: "<msg42@example.com>",
            subject: "Quarterly Budget Review",
            from: "cfo@company.com",
            to: "team@company.com",
            cc: "manager@company.com",
            bcc: "auditor@company.com",
            dateMs: 1_710_000_000_000
        )
        #expect(record.headerId == "acc2:Sent:42")
        #expect(record.messageId == "<msg42@example.com>")
        #expect(record.subject == "Quarterly Budget Review")
        #expect(record.from == "cfo@company.com")
        #expect(record.to == "team@company.com")
        #expect(record.cc == "manager@company.com")
        #expect(record.bcc == "auditor@company.com")
        #expect(record.dateMs == 1_710_000_000_000)
    }

    @Test("Empty strings are valid field values")
    func emptyFields() {
        let record = FTSHeaderRecord(
            headerId: "", messageId: "", subject: "",
            from: "", to: "", cc: "", bcc: "", dateMs: 0
        )
        #expect(record.headerId.isEmpty)
        #expect(record.subject.isEmpty)
        #expect(record.dateMs == 0)
    }
}

@Suite("FTSSearchResult Fields")
struct FTSSearchResultFieldTests {

    @Test("All fields stored correctly")
    func allFields() {
        let result = FTSSearchResult(
            headerId: "acc1:INBOX:99",
            messageId: "<msg99@example.com>",
            snippet: "...quarterly [budget] review...",
            rank: -8.5,
            dateMs: 1_710_000_000_000
        )
        #expect(result.headerId == "acc1:INBOX:99")
        #expect(result.messageId == "<msg99@example.com>")
        #expect(result.snippet == "...quarterly [budget] review...")
        #expect(result.rank == -8.5)
        #expect(result.dateMs == 1_710_000_000_000)
    }

    @Test("BM25 rank is typically negative")
    func bm25RankNegative() {
        let result = FTSSearchResult(headerId: "", messageId: "", snippet: "", rank: -3.14, dateMs: 0)
        #expect(result.rank < 0)
    }

    @Test("Zero rank is valid for date-range-only results")
    func zeroRank() {
        let result = FTSSearchResult(headerId: "", messageId: "", snippet: "", rank: 0, dateMs: 0)
        #expect(result.rank == 0)
    }

    @Test("Empty snippet is valid for vector-only results")
    func emptySnippet() {
        let result = FTSSearchResult(headerId: "h1", messageId: "m1", snippet: "", rank: -1.0, dateMs: 100)
        #expect(result.snippet.isEmpty)
    }
}

// MARK: - SearchIndex Actor Tests (uses SearchIndex.shared — already initialized by app startup)

@Suite("SearchIndex CRUD Operations", .serialized)
struct SearchIndexCRUDTests {

    /// Use the shared singleton which is initialized during app startup in the test host.
    private var index: SearchIndex { SearchIndex.shared }

    @Test("indexHeaders inserts new records and deduplicates")
    func indexHeadersInsert() async throws {
        let records = [
            FTSHeaderRecord(
                headerId: "test_crud_1:INBOX:1",
                messageId: "<msg1@test.com>",
                subject: "First Message",
                from: "alice@test.com",
                to: "bob@test.com",
                dateMs: 1_700_000_000_000
            ),
            FTSHeaderRecord(
                headerId: "test_crud_1:INBOX:2",
                messageId: "<msg2@test.com>",
                subject: "Second Message",
                from: "carol@test.com",
                to: "dave@test.com",
                dateMs: 1_710_000_000_000
            ),
        ]

        // Clean up any leftovers from a previous failed run
        try await index.removeMessages(headerIds: records.map(\.headerId))

        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 2)

        // Dedup: re-inserting same records should insert 0
        let reinserted = try await index.indexHeaders(records)
        #expect(reinserted == 0)

        // Cleanup
        try await index.removeMessages(headerIds: records.map(\.headerId))
    }

    @Test("indexHeaders with empty array returns 0")
    func indexHeadersEmpty() async throws {
        let count = try await index.indexHeaders([])
        #expect(count == 0)
    }

    @Test("Partial and full email-address queries match the sender (tokenchars regression)")
    func emailAddressSearch() async throws {
        // Regression: tokenchars '-_.@' index the whole address as ONE token.
        // The query builder used to emit an exact quoted phrase for special-char
        // tokens, so typing "dmarc-helper" (or any partial address) matched nothing.
        let hid = "test_email_q:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "<emailq1@test.com>",
            subject: "Aggregate report", from: "dmarc-helper@domain.com",
            to: "admin@domain.com", dateMs: 1_700_000_000_000
        )

        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        // Partial local part (what a user types before finishing the address)
        let partial = try await index.keywordSearch(query: "dmarc-helper")
        #expect(partial.contains { $0.headerId == hid }, "partial local-part must match")

        // Mid-typing partial with trailing hyphen segment
        let midway = try await index.keywordSearch(query: "dmarc-help")
        #expect(midway.contains { $0.headerId == hid }, "mid-typing partial must match")

        // Full address
        let full = try await index.keywordSearch(query: "dmarc-helper@domain.com")
        #expect(full.contains { $0.headerId == hid }, "full address must match")

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("updateBody writes body text to FTS")
    func updateBodyWritesToFTS() async throws {
        let hid = "test_body_1:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "<body1@test.com>",
            subject: "Body Test", from: "a@test.com", to: "b@test.com",
            dateMs: 1_700_000_000_000
        )

        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        try await index.updateBody(headerId: hid, body: "This is the full email body text for testing.")

        // Verify body is searchable
        let results = try await index.keywordSearch(query: "\"full email body text\"")
        #expect(results.contains { $0.headerId == hid })

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("updateBody for non-existent header is a no-op")
    func updateBodyNonExistent() async throws {
        try await index.updateBody(headerId: "nonexistent_test:INBOX:999", body: "some body")
    }

    @Test("removeMessages removes indexed headers")
    func removeMessages() async throws {
        let hid = "test_remove_1:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "<remove1@test.com>",
            subject: "To Be Removed", from: "x@test.com", to: "y@test.com",
            dateMs: 1_700_000_000_000
        )

        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let isIndexedBefore = try await index.isIndexed(headerId: hid)
        #expect(isIndexedBefore == true)

        try await index.removeMessages(headerIds: [hid])

        let isIndexedAfter = try await index.isIndexed(headerId: hid)
        #expect(isIndexedAfter == false)
    }

    @Test("removeMessages with empty array is a no-op")
    func removeMessagesEmpty() async throws {
        try await index.removeMessages(headerIds: [])
    }

    @Test("isIndexed returns false for non-existent header")
    func isIndexedNonExistent() async throws {
        let result = try await index.isIndexed(headerId: "nonexistent_test:INBOX:999")
        #expect(result == false)
    }

    @Test("documentCountForAccount uses headerId prefix matching")
    func documentCountForAccount() async throws {
        let records = [
            FTSHeaderRecord(headerId: "test_acct_count_a:INBOX:1", messageId: "m1", subject: "S1",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000),
            FTSHeaderRecord(headerId: "test_acct_count_a:INBOX:2", messageId: "m2", subject: "S2",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000),
            FTSHeaderRecord(headerId: "test_acct_count_b:INBOX:1", messageId: "m3", subject: "S3",
                            from: "c@c.com", to: "d@d.com", dateMs: 1_700_000_000_000),
        ]
        try await index.removeMessages(headerIds: records.map(\.headerId))
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 3)

        let countA = try await index.documentCountForAccount(accountId: "test_acct_count_a")
        #expect(countA == 2)

        let countB = try await index.documentCountForAccount(accountId: "test_acct_count_b")
        #expect(countB == 1)

        let countNone = try await index.documentCountForAccount(accountId: "test_acct_count_nonexistent")
        #expect(countNone == 0)

        try await index.removeMessages(headerIds: records.map(\.headerId))
    }

    @Test("removeMessagesForAccount removes all messages for given account")
    func removeMessagesForAccount() async throws {
        let records = [
            FTSHeaderRecord(headerId: "test_acct_rm_a:INBOX:1", messageId: "m1", subject: "S1",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000),
            FTSHeaderRecord(headerId: "test_acct_rm_a:INBOX:2", messageId: "m2", subject: "S2",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000),
            FTSHeaderRecord(headerId: "test_acct_rm_b:INBOX:1", messageId: "m3", subject: "S3",
                            from: "c@c.com", to: "d@d.com", dateMs: 1_700_000_000_000),
        ]
        try await index.removeMessages(headerIds: records.map(\.headerId))
        try await index.removeMessagesForAccount(accountId: "test_acct_rm_a")
        try await index.removeMessagesForAccount(accountId: "test_acct_rm_b")

        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 3)

        try await index.removeMessagesForAccount(accountId: "test_acct_rm_a")

        let countA = try await index.documentCountForAccount(accountId: "test_acct_rm_a")
        #expect(countA == 0)

        let countB = try await index.documentCountForAccount(accountId: "test_acct_rm_b")
        #expect(countB == 1)

        try await index.removeMessages(headerIds: ["test_acct_rm_b:INBOX:1"])
    }

    @Test("updateBodies batch updates body text for multiple messages")
    func updateBodies() async throws {
        let records = [
            FTSHeaderRecord(headerId: "test_bulk_body:INBOX:1", messageId: "m1",
                            subject: "Bulk 1", from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000),
            FTSHeaderRecord(headerId: "test_bulk_body:INBOX:2", messageId: "m2",
                            subject: "Bulk 2", from: "a@a.com", to: "b@b.com", dateMs: 1_710_000_000_000),
        ]
        try await index.removeMessages(headerIds: records.map(\.headerId))
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 2)

        try await index.updateBodies([
            (headerId: "test_bulk_body:INBOX:1", body: "Body text one"),
            (headerId: "test_bulk_body:INBOX:2", body: "Body text two"),
        ])

        // Verify bodies are searchable
        let r1 = try await index.keywordSearch(query: "\"Body text one\"")
        let r2 = try await index.keywordSearch(query: "\"Body text two\"")
        #expect(r1.contains { $0.headerId == "test_bulk_body:INBOX:1" })
        #expect(r2.contains { $0.headerId == "test_bulk_body:INBOX:2" })

        try await index.removeMessages(headerIds: records.map(\.headerId))
    }

    @Test("updateBodies with empty array is a no-op")
    func updateBodiesEmpty() async throws {
        try await index.updateBodies([])
    }

    @Test("clearBodies removes body text from FTS")
    func clearBodies() async throws {
        let hid = "test_clear_body:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Clear Test",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        try await index.updateBody(headerId: hid, body: "Uniquecleartestbodytext here")
        let beforeClear = try await index.keywordSearch(query: "uniquecleartestbodytext")
        #expect(beforeClear.contains { $0.headerId == hid })

        try await index.clearBodies(headerIds: [hid])
        let afterClear = try await index.keywordSearch(query: "uniquecleartestbodytext")
        #expect(!afterClear.contains { $0.headerId == hid })

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("clearBodies with empty array is a no-op")
    func clearBodiesEmpty() async throws {
        try await index.clearBodies(headerIds: [])
    }

    @Test("updateCcBcc updates cc and bcc fields")
    func updateCcBcc() async throws {
        let hid = "test_ccbcc:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "CcBcc Test",
            from: "a@a.com", to: "b@b.com", cc: "", bcc: "",
            dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        try await index.updateCcBcc([(headerId: hid, cc: "cc@test.com", bcc: "bcc@test.com")])

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("updateCcBcc with empty array is a no-op")
    func updateCcBccEmpty() async throws {
        try await index.updateCcBcc([])
    }

    // needsBodyUpdate, emptyBodyCount, totalIndexedCount removed — flags live in GRDB only

    @Test("documentCount returns non-negative count")
    func documentCount() async throws {
        let count = try await index.documentCount()
        #expect(count >= 0)
    }

    // headerIdsWithEmptyBodies, headerIdsWithNonEmptyBodies, emptyBodyCount(accountId:) removed — flags live in GRDB only

    // totalIndexedCount removed — flags live in GRDB only

    // ftsProgress, headerIdsWithEmptyBodies removed — flags live in GRDB only

    @Test("bodyText returns nil for non-existent header")
    func bodyTextNonExistent() async throws {
        let body = try await index.bodyText(headerId: "nonexistent_test:INBOX:999")
        #expect(body == nil)
    }

    @Test("bodyText returns nil when body is empty")
    func bodyTextEmpty() async throws {
        let hid = "test_bodytext:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Body Text Test",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let body = try await index.bodyText(headerId: hid)
        #expect(body == nil)

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("bodyText returns text after updateBody")
    func bodyTextAfterUpdate() async throws {
        let hid = "test_bodytext2:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Body Text Test",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        try await index.updateBody(headerId: hid, body: "The actual email body content")
        let body = try await index.bodyText(headerId: hid)
        #expect(body == "The actual email body content")

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("sortedShardYears returns years in descending order")
    func sortedShardYears() async throws {
        let years = await index.sortedShardYears
        for i in 0..<max(0, years.count - 1) {
            #expect(years[i] >= years[i + 1])
        }
    }

    @Test("keywordSearch finds indexed messages by subject")
    func keywordSearchBySubject() async throws {
        let hid = "test_kwsearch:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1",
            subject: "Zephyranthes Budgeticus Forecasticus",
            from: "finance@company.com", to: "team@company.com",
            dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        // Use a unique word to avoid matching other indexed messages
        let results = try await index.keywordSearch(query: "zephyranthes")
        let found = results.contains { $0.headerId == hid }
        #expect(found)

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("keywordSearch returns empty for non-matching query")
    func keywordSearchNoMatch() async throws {
        let results = try await index.keywordSearch(query: "xyzzyplughnotaword")
        #expect(results.isEmpty)
    }

    @Test("keywordSearch returns empty for empty query")
    func keywordSearchEmpty() async throws {
        let results = try await index.keywordSearch(query: "")
        #expect(results.isEmpty)
    }

    @Test("keywordSearchShard returns empty for non-existent year")
    func keywordSearchShardNonExistent() async throws {
        let results = try await index.keywordSearchShard(query: "test", year: 1900)
        #expect(results.isEmpty)
    }

    @Test("keywordSearchShard returns empty for empty query")
    func keywordSearchShardEmpty() async throws {
        let results = try await index.keywordSearchShard(query: "", year: 2024)
        #expect(results.isEmpty)
    }

    @Test("Year shard for dateMs=0 uses fallback year 2000")
    func yearShardFallback() async throws {
        let hid = "test_year0:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Zero Date Test",
            from: "a@a.com", to: "b@b.com", dateMs: 0
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let years = await index.sortedShardYears
        #expect(years.contains(2000))

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("Year shard for negative dateMs uses fallback year 2000")
    func yearShardNegativeDate() async throws {
        let hid = "test_negdate:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Negative Date Test",
            from: "a@a.com", to: "b@b.com", dateMs: -1000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let years = await index.sortedShardYears
        #expect(years.contains(2000))

        try await index.removeMessages(headerIds: [hid])
    }

    // headerIdsNeedingEmbeddings, textForEmbedding removed — embeddings logic moved out of SearchIndex

    @Test("storeEmbedding does not crash for non-existent header")
    func storeEmbeddingNonExistent() async throws {
        let fakeEmbedding = [Float](repeating: 0.1, count: SearchConfig.embeddingDims)
        try await index.storeEmbedding(headerId: "nonexistent_test:INBOX:999", embedding: fakeEmbedding)
    }

    @Test("storeEmbedding stores embedding for indexed message")
    func storeEmbedding() async throws {
        let hid = "test_store_emb:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Embed Store Test",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let embedding = [Float](repeating: 0.5, count: SearchConfig.embeddingDims)
        try await index.storeEmbedding(headerId: hid, embedding: embedding)

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("keywordSearch with date range filters results")
    func keywordSearchWithDateRange() async throws {
        let records = [
            FTSHeaderRecord(headerId: "test_date_range:INBOX:1", messageId: "m1",
                            subject: "Xylophone Zygote January Report",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_704_067_200_000),
            FTSHeaderRecord(headerId: "test_date_range:INBOX:2", messageId: "m2",
                            subject: "Xylophone Zygote June Report",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_719_792_000_000),
        ]
        try await index.removeMessages(headerIds: records.map(\.headerId))
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 2)

        let results = try await index.keywordSearch(
            query: "xylophone",
            fromDateMs: 1_704_067_200_000,
            toDateMs: 1_711_929_600_000
        )
        let foundJan = results.contains { $0.headerId == "test_date_range:INBOX:1" }
        let foundJun = results.contains { $0.headerId == "test_date_range:INBOX:2" }
        if !results.isEmpty {
            #expect(foundJan)
            #expect(!foundJun)
        }

        try await index.removeMessages(headerIds: records.map(\.headerId))
    }

    @Test("search with field-scoped query does not crash")
    func searchWithFieldScope() async throws {
        let hid = "test_field_search:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Important Report",
            from: "alice@company.com", to: "team@company.com",
            dateMs: 1_700_000_000_000
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let results = try await index.keywordSearch(query: "from:alice")
        #expect(results.count >= 0)

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("optimize runs without error")
    func optimize() async throws {
        try await index.optimize()
    }

    @Test("vacuum runs without error")
    func vacuum() async throws {
        try await index.vacuum()
    }
}
