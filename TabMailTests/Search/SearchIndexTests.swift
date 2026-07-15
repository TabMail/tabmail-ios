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
            from: "alice@example.com",
            to: "bob@example.com",
            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)
        )
        #expect(record.cc == "")
        #expect(record.bcc == "")
    }

    @Test("All fields stored correctly")
    func allFields() {
        let dateMs = TestFixtureDate.milliseconds(daysFromAnchor: -15)
        let record = FTSHeaderRecord(
            headerId: "acc2:Sent:42",
            messageId: "<msg42@example.com>",
            subject: "Quarterly Budget Review",
            from: "cfo@company.com",
            to: "team@company.com",
            cc: "manager@company.com",
            bcc: "auditor@company.com",
            dateMs: dateMs
        )
        #expect(record.headerId == "acc2:Sent:42")
        #expect(record.messageId == "<msg42@example.com>")
        #expect(record.subject == "Quarterly Budget Review")
        #expect(record.from == "cfo@company.com")
        #expect(record.to == "team@company.com")
        #expect(record.cc == "manager@company.com")
        #expect(record.bcc == "auditor@company.com")
        #expect(record.dateMs == dateMs)
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
        let dateMs = TestFixtureDate.milliseconds(daysFromAnchor: -15)
        let result = FTSSearchResult(
            headerId: "acc1:INBOX:99",
            messageId: "<msg99@example.com>",
            snippet: "...quarterly [budget] review...",
            rank: -8.5,
            dateMs: dateMs
        )
        #expect(result.headerId == "acc1:INBOX:99")
        #expect(result.messageId == "<msg99@example.com>")
        #expect(result.snippet == "...quarterly [budget] review...")
        #expect(result.rank == -8.5)
        #expect(result.dateMs == dateMs)
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

@Suite("SearchIndex CRUD Operations", .serialized, .processGlobalState)
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
                dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)
            ),
            FTSHeaderRecord(
                headerId: "test_crud_1:INBOX:2",
                messageId: "<msg2@test.com>",
                subject: "Second Message",
                from: "carol@test.com",
                to: "dave@test.com",
                dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -15)
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
        // Regression: the old tokenchars '-_.@' scheme indexed the whole address
        // as ONE token, so partial-address queries matched nothing. With the
        // splitting tokenizer, any address PART is matchable too.
        let hid = "test_email_q:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "<emailq1@test.com>",
            subject: "Aggregate report", from: "noreply-dmarc-helper@domain.com",
            to: "admin@domain.com",
            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)
        )

        // The test-host's persistent fts.db may carry shards from older runs that
        // the background tokenizer migration hasn't converted yet — convert them
        // now so the insert below lands in a new-tokenizer shard (idempotent).
        await index.rebuildStaleTokenizerShards()

        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        // Mid-address part (could never match under glued tokenchars indexing)
        let part = try await index.keywordSearch(query: "dmarc")
        #expect(part.contains { $0.headerId == hid }, "mid-address part must match")

        // Partial with trailing hyphen, as typed mid-flight
        let midway = try await index.keywordSearch(query: "dmarc-help")
        #expect(midway.contains { $0.headerId == hid }, "mid-typing partial must match")

        // Multi-part partial from the start
        let partial = try await index.keywordSearch(query: "noreply-dmarc-")
        #expect(partial.contains { $0.headerId == hid }, "partial local-part must match")

        // Full address (adjacency phrase under the splitting tokenizer)
        let full = try await index.keywordSearch(query: "noreply-dmarc-helper@domain.com")
        #expect(full.contains { $0.headerId == hid }, "full address must match")

        try await index.removeMessages(headerIds: [hid])
    }

    @Test("Tokenizer migration rebuilds old-tokenchars shards in place, preserving rowids")
    func tokenizerShardRebuild() async throws {
        // Seed a fake old-tokenizer shard for a year no real data uses (2001),
        // aligned with message_meta/message_ids the way indexHeaders would write,
        // then run the migration and verify: new tokenizer in sqlite_master,
        // rowids preserved, and part-queries match.
        let hid = "test_retok:INBOX:1"
        try await index.removeMessages(headerIds: [hid])
        let oldTokenize = "porter unicode61 remove_diacritics 2 tokenchars '-_.@'"
        let rowid: Int64 = try await index.testSeedLegacyShard(
            year: 2001, tokenize: oldTokenize,
            headerId: hid, msgId: "<retok1@test.com>",
            subject: "Weekly digest", from: "billing-alerts@domain.com",
            body: "full body text here", dateMs: 980_000_000_000 // 2001 epoch ms
        )

        await index.rebuildStaleTokenizerShards()

        let sql = try await index.testShardCreateSQL(year: 2001)
        #expect(!(sql?.contains("tokenchars") ?? true), "shard must use the new tokenizer, got: \(sql ?? "nil")")

        // rowid alignment with message_meta must survive the rebuild
        let newRowid = try await index.testRowidForHeader(hid)
        #expect(newRowid == rowid, "rowid must be preserved across rebuild")

        // Part-query now matches content indexed under the old scheme
        let hits = try await index.keywordSearch(query: "billing")
        #expect(hits.contains { $0.headerId == hid }, "address part must match after rebuild")
        let bodyHits = try await index.keywordSearch(query: "\"full body text\"")
        #expect(bodyHits.contains { $0.headerId == hid }, "body must survive rebuild")

        try await index.removeMessages(headerIds: [hid])
        try await index.testDropShard(year: 2001)
    }

    @Test("Tokenizer migration honors the deadline and resumes; hasStaleTokenizerShards tracks it")
    func tokenizerRebuildDeadline() async throws {
        let hid = "test_retok_dl:INBOX:1"
        try await index.removeMessages(headerIds: [hid])
        let oldTokenize = "porter unicode61 remove_diacritics 2 tokenchars '-_.@'"
        _ = try await index.testSeedLegacyShard(
            year: 2002, tokenize: oldTokenize,
            headerId: hid, msgId: "<retokdl@test.com>",
            subject: "Deadline test", from: "alerts@domain.com",
            body: "body", dateMs: 1_010_000_000_000 // 2002 epoch ms
        )
        #expect(await index.hasStaleTokenizerShards(), "seeded legacy shard must read as stale")

        // Past deadline: no shard may start — shard stays stale (short BG windows
        // rely on this to never hog the window).
        await index.rebuildStaleTokenizerShards(deadline: Date(timeIntervalSinceNow: -1))
        let sqlAfterPast = try await index.testShardCreateSQL(year: 2002)
        #expect(sqlAfterPast?.contains("tokenchars") == true, "past deadline must not convert anything")
        #expect(await index.hasStaleTokenizerShards(), "still stale after budget-exhausted run")

        // Future deadline: converts (resume semantics — same call, later window)
        await index.rebuildStaleTokenizerShards(deadline: Date(timeIntervalSinceNow: 60))
        let sqlAfterFuture = try await index.testShardCreateSQL(year: 2002)
        #expect(sqlAfterFuture?.contains("tokenchars") == false, "future deadline must convert")
        #expect(!(await index.hasStaleTokenizerShards()), "no stale shards after full run")

        try await index.removeMessages(headerIds: [hid])
        try await index.testDropShard(year: 2002)
    }

    @Test("Tokenizer migration converts an EMPTY legacy shard")
    func tokenizerRebuildEmptyShard() async throws {
        let hid = "test_retok_empty:INBOX:1"
        let oldTokenize = "porter unicode61 remove_diacritics 2 tokenchars '-_.@'"
        _ = try await index.testSeedLegacyShard(
            year: 2003, tokenize: oldTokenize,
            headerId: hid, msgId: "<retokempty@test.com>",
            subject: "Empty test", from: "x@domain.com",
            body: "body", dateMs: 1_041_400_000_000 // 2003 epoch ms
        )
        // Empty the shard — removeMessages deletes the FTS row but leaves the table
        try await index.removeMessages(headerIds: [hid])

        await index.rebuildStaleTokenizerShards()

        let sql = try await index.testShardCreateSQL(year: 2003)
        #expect(sql?.contains("tokenchars") == false, "empty shard must still convert, got: \(sql ?? "nil")")

        try await index.testDropShard(year: 2003)
    }

    @Test("updateBody writes body text to FTS")
    func updateBodyWritesToFTS() async throws {
        let hid = "test_body_1:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "<body1@test.com>",
            subject: "Body Test", from: "a@test.com", to: "b@test.com",
            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)
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
            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)
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
                            from: "sender@example.com", to: "recipient@example.com",
                            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)),
            FTSHeaderRecord(headerId: "test_acct_count_a:INBOX:2", messageId: "m2", subject: "S2",
                            from: "sender@example.com", to: "recipient@example.com",
                            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)),
            FTSHeaderRecord(headerId: "test_acct_count_b:INBOX:1", messageId: "m3", subject: "S3",
                            from: "other-sender@example.com", to: "other-recipient@example.com",
                            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)),
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
                            from: "sender@example.com", to: "recipient@example.com",
                            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)),
            FTSHeaderRecord(headerId: "test_acct_rm_a:INBOX:2", messageId: "m2", subject: "S2",
                            from: "sender@example.com", to: "recipient@example.com",
                            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)),
            FTSHeaderRecord(headerId: "test_acct_rm_b:INBOX:1", messageId: "m3", subject: "S3",
                            from: "other-sender@example.com", to: "other-recipient@example.com",
                            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)),
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
                            subject: "Bulk 1", from: "sender@example.com", to: "recipient@example.com",
                            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)),
            FTSHeaderRecord(headerId: "test_bulk_body:INBOX:2", messageId: "m2",
                            subject: "Bulk 2", from: "sender@example.com", to: "recipient@example.com",
                            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -15)),
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
            from: "sender@example.com", to: "recipient@example.com",
            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)
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
            from: "sender@example.com", to: "recipient@example.com", cc: "", bcc: "",
            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)
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
            from: "sender@example.com", to: "recipient@example.com",
            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)
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
            from: "sender@example.com", to: "recipient@example.com",
            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)
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
            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)
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
            from: "sender@example.com", to: "recipient@example.com",
            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let embedding = [Float](repeating: 0.5, count: SearchConfig.embeddingDims)
        try await index.storeEmbedding(headerId: hid, embedding: embedding)

        try await index.removeMessages(headerIds: [hid])
    }

    // MARK: - rekeyHeaders collision richness
    // Round G candidate 5 (FTS collision selection): the richer body/vector must
    // win a rekey collision, not whichever entry happened to land first.

    @Test("rekeyHeaders collision prefers a persisted vector before body length")
    func rekeyCollisionPrefersPersistedVector() async throws {
        let oldId = "test_rekey_vector:Source:old"
        let newId = "test_rekey_vector:Destination:new"
        let headerIds = [oldId, newId]
        let dateMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let oldBody = "Short body with vector."
        let newBody = String(repeating: "Longer body without vector. ", count: 8)

        try await index.removeMessages(headerIds: headerIds)
        let inserted = try await index.indexHeaders([
            FTSHeaderRecord(
                headerId: oldId, messageId: "old-provider-id",
                subject: "Old vector generation", from: "sender@example.com",
                to: "recipient@example.com", dateMs: dateMs
            ),
            FTSHeaderRecord(
                headerId: newId, messageId: "new-provider-id",
                subject: "New skeletal generation", from: "sender@example.com",
                to: "recipient@example.com", dateMs: dateMs
            ),
        ])
        #expect(inserted == 2)

        try await index.updateBody(headerId: oldId, body: oldBody)
        try await index.updateBody(headerId: newId, body: newBody)
        try await index.storeEmbedding(
            headerId: oldId,
            embedding: [Float](repeating: 0.25, count: SearchConfig.embeddingDims)
        )
        let oldRowid = try await index.testRowidForHeader(oldId)
        let originalNewRowid = try await index.testRowidForHeader(newId)
        #expect(oldRowid != nil)
        #expect(originalNewRowid != nil)
        #expect(oldRowid != originalNewRowid)

        try await index.rekeyHeaders([(
            oldId: oldId,
            newId: newId,
            newMessageId: "new-provider-id"
        )])

        #expect(try await index.isIndexed(headerId: oldId) == false)
        #expect(try await index.isIndexed(headerId: newId))
        #expect(try await index.testRowidForHeader(newId) == oldRowid,
                "the vector-bearing rowid must survive the collision")
        #expect(try await index.bodyText(headerId: newId) == oldBody,
                "vector precedence must beat the competing longer body")

        try await index.removeMessages(headerIds: headerIds)
    }

    @Test("rekeyHeaders collision uses body length when neither entry has a vector")
    func rekeyCollisionUsesBodyLengthWithoutVectors() async throws {
        let oldId = "test_rekey_length:Source:old"
        let newId = "test_rekey_length:Destination:new"
        let headerIds = [oldId, newId]
        let dateMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let oldBody = String(repeating: "Richer complete body text. ", count: 8)
        let newBody = "Short complete body."

        try await index.removeMessages(headerIds: headerIds)
        let inserted = try await index.indexHeaders([
            FTSHeaderRecord(
                headerId: oldId, messageId: "old-provider-id",
                subject: "Old complete generation", from: "sender@example.com",
                to: "recipient@example.com", dateMs: dateMs
            ),
            FTSHeaderRecord(
                headerId: newId, messageId: "new-provider-id",
                subject: "New complete generation", from: "sender@example.com",
                to: "recipient@example.com", dateMs: dateMs
            ),
        ])
        #expect(inserted == 2)

        try await index.updateBody(headerId: oldId, body: oldBody)
        try await index.updateBody(headerId: newId, body: newBody)
        let oldRowid = try await index.testRowidForHeader(oldId)
        let originalNewRowid = try await index.testRowidForHeader(newId)
        #expect(oldRowid != nil)
        #expect(originalNewRowid != nil)
        #expect(oldRowid != originalNewRowid)

        try await index.rekeyHeaders([(
            oldId: oldId,
            newId: newId,
            newMessageId: "new-provider-id"
        )])

        #expect(try await index.isIndexed(headerId: oldId) == false)
        #expect(try await index.isIndexed(headerId: newId))
        #expect(try await index.testRowidForHeader(newId) == oldRowid,
                "the longer equal-presence body must keep its original rowid")
        #expect(try await index.bodyText(headerId: newId) == oldBody)

        try await index.removeMessages(headerIds: headerIds)
    }

    // MARK: - Round G candidate 6: vector-table existence check before mutation

    /// Round G candidate 6 (`deleteEntry`). On a connection where the sqlite-vec
    /// vec0 module never registered `messages_vec` doesn't exist at all.
    /// `deleteEntry` must check `sqlite_master` before issuing
    /// `DELETE FROM messages_vec` rather than assume the table is there —
    /// this is exercised through the real `removeMessages` production path
    /// used by sync pruning and account deletion.
    @Test("removeMessages tolerates a missing sqlite-vec table")
    func removeMessagesToleratesMissingVectorTable() async throws {
        let hid = "test_novec_remove:INBOX:1"
        try? await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([
            FTSHeaderRecord(
                headerId: hid, messageId: "m1", subject: "No vec table remove test",
                from: "a@a.com", to: "b@b.com",
                dateMs: Int64(Date().timeIntervalSince1970 * 1_000)
            ),
        ])
        #expect(inserted == 1)
        _ = try await index.updateBodies([(headerId: hid, body: "novecremovaltoken content")])

        try await index.testDropVectorTable()
        do {
            // Must not throw despite messages_vec being absent — a bare
            // (non-optional) DELETE against the missing table would abort
            // the whole removeMessages write transaction.
            try await index.removeMessages(headerIds: [hid])
            #expect(try await index.isIndexed(headerId: hid) == false)
        } catch {
            try? await index.testRecreateVectorTable()
            Issue.record("removeMessages threw with messages_vec absent: \(error)")
            return
        }
        try await index.testRecreateVectorTable()
    }

    /// Round G candidate 6 (`entryRichness`). The richness comparison used by
    /// `rekeyHeaders` collisions must also tolerate a missing `messages_vec`
    /// — it falls back to body-length comparison instead of throwing.
    @Test("rekeyHeaders collision richness tolerates a missing sqlite-vec table")
    func rekeyCollisionRichnessToleratesMissingVectorTable() async throws {
        let oldId = "test_novec_rekey:Source:old"
        let newId = "test_novec_rekey:Destination:new"
        let headerIds = [oldId, newId]
        let dateMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let oldBody = String(repeating: "Richer complete body text without a vec table. ", count: 8)
        let newBody = "Short complete body."

        try? await index.removeMessages(headerIds: headerIds)
        let inserted = try await index.indexHeaders([
            FTSHeaderRecord(
                headerId: oldId, messageId: "old-provider-id",
                subject: "Old generation no vec table", from: "sender@example.com",
                to: "recipient@example.com", dateMs: dateMs
            ),
            FTSHeaderRecord(
                headerId: newId, messageId: "new-provider-id",
                subject: "New generation no vec table", from: "sender@example.com",
                to: "recipient@example.com", dateMs: dateMs
            ),
        ])
        #expect(inserted == 2)
        try await index.updateBody(headerId: oldId, body: oldBody)
        try await index.updateBody(headerId: newId, body: newBody)

        try await index.testDropVectorTable()
        do {
            try await index.rekeyHeaders([(
                oldId: oldId,
                newId: newId,
                newMessageId: "new-provider-id"
            )])
            #expect(try await index.isIndexed(headerId: oldId) == false)
            #expect(try await index.isIndexed(headerId: newId))
            #expect(try await index.bodyText(headerId: newId) == oldBody,
                    "richer body wins on presence/length even without a vec table to compare")
        } catch {
            try? await index.testRecreateVectorTable()
            Issue.record("rekeyHeaders threw with messages_vec absent: \(error)")
            return
        }
        try await index.testRecreateVectorTable()
        try await index.removeMessages(headerIds: headerIds)
    }

    @Test("keywordSearch with date range filters results")
    func keywordSearchWithDateRange() async throws {
        let includedDateMs = TestFixtureDate.milliseconds(daysFromAnchor: -2)
        let excludedDateMs = TestFixtureDate.milliseconds(daysFromAnchor: -30)
        let fromDateMs = TestFixtureDate.milliseconds(daysFromAnchor: -7)
        let toDateMs = TestFixtureDate.milliseconds(daysFromAnchor: 1)
        let records = [
            FTSHeaderRecord(headerId: "test_date_range:INBOX:1", messageId: "m1",
                            subject: "Xylophone Zygote Included Report",
                            from: "sender@example.com", to: "recipient@example.com",
                            dateMs: includedDateMs),
            FTSHeaderRecord(headerId: "test_date_range:INBOX:2", messageId: "m2",
                            subject: "Xylophone Zygote Excluded Report",
                            from: "sender@example.com", to: "recipient@example.com",
                            dateMs: excludedDateMs),
        ]
        try await index.removeMessages(headerIds: records.map(\.headerId))
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 2)

        let results = try await index.keywordSearch(
            query: "xylophone",
            fromDateMs: fromDateMs,
            toDateMs: toDateMs
        )
        #expect(results.contains { $0.headerId == "test_date_range:INBOX:1" })
        #expect(!results.contains { $0.headerId == "test_date_range:INBOX:2" })

        try await index.removeMessages(headerIds: records.map(\.headerId))
    }

    @Test("search with field-scoped query does not crash")
    func searchWithFieldScope() async throws {
        let hid = "test_field_search:INBOX:1"
        let record = FTSHeaderRecord(
            headerId: hid, messageId: "m1", subject: "Important Report",
            from: "alice@example.com", to: "team@example.com",
            dateMs: TestFixtureDate.milliseconds(daysFromAnchor: -30)
        )
        try await index.removeMessages(headerIds: [hid])
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let results = try await index.keywordSearch(query: "from:alice")
        #expect(results.contains { $0.headerId == hid })

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
