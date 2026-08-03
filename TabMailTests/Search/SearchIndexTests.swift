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
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: "acc1:INBOX:1"),
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
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: "acc2:Sent:42"),
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
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: ""),
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
        let result = FTSSearchResult( contentKey: ContentKey(rawValue: "acc1:INBOX:99"),
            messageId: "<msg99@example.com>",
            snippet: "...quarterly [budget] review...",
            rank: -8.5,
            dateMs: 1_710_000_000_000
        )
        #expect(result.contentKey.rawValue == "acc1:INBOX:99")
        #expect(result.messageId == "<msg99@example.com>")
        #expect(result.snippet == "...quarterly [budget] review...")
        #expect(result.rank == -8.5)
        #expect(result.dateMs == 1_710_000_000_000)
    }

    @Test("BM25 rank is typically negative")
    func bm25RankNegative() {
        let result = FTSSearchResult( contentKey: ContentKey(rawValue: ""), messageId: "", snippet: "", rank: -3.14, dateMs: 0)
        #expect(result.rank < 0)
    }

    @Test("Zero rank is valid for date-range-only results")
    func zeroRank() {
        let result = FTSSearchResult( contentKey: ContentKey(rawValue: ""), messageId: "", snippet: "", rank: 0, dateMs: 0)
        #expect(result.rank == 0)
    }

    @Test("Empty snippet is valid for vector-only results")
    func emptySnippet() {
        let result = FTSSearchResult( contentKey: ContentKey(rawValue: "h1"), messageId: "m1", snippet: "", rank: -1.0, dateMs: 100)
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
            FTSHeaderRecord( contentKey: ContentKey(rawValue: "test_crud_1:INBOX:1"),
                headerId: "test_crud_1:INBOX:1",
                messageId: "<msg1@test.com>",
                subject: "First Message",
                from: "alice@test.com",
                to: "bob@test.com",
                dateMs: 1_700_000_000_000
            ),
            FTSHeaderRecord( contentKey: ContentKey(rawValue: "test_crud_1:INBOX:2"),
                headerId: "test_crud_1:INBOX:2",
                messageId: "<msg2@test.com>",
                subject: "Second Message",
                from: "carol@test.com",
                to: "dave@test.com",
                dateMs: 1_710_000_000_000
            ),
        ]

        // Clean up any leftovers from a previous failed run
        try await index.removeMessages( contentKeys: records.map(\.headerId).map(ContentKey.init(rawValue:)))

        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 2)

        // Dedup: re-inserting same records should insert 0
        let reinserted = try await index.indexHeaders(records)
        #expect(reinserted == 0)

        // Cleanup
        try await index.removeMessages( contentKeys: records.map(\.headerId).map(ContentKey.init(rawValue:)))
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
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid, messageId: "<emailq1@test.com>",
            subject: "Aggregate report", from: "noreply-dmarc-helper@domain.com",
            to: "admin@domain.com", dateMs: 1_700_000_000_000
        )

        // The test-host's persistent fts.db may carry shards from older runs that
        // the background tokenizer migration hasn't converted yet — convert them
        // now so the insert below lands in a new-tokenizer shard (idempotent).
        await index.rebuildStaleTokenizerShards()

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        // Mid-address part (could never match under glued tokenchars indexing)
        let part = try await index.keywordSearch(query: "dmarc")
        #expect(part.contains { $0.contentKey.rawValue == hid }, "mid-address part must match")

        // Partial with trailing hyphen, as typed mid-flight
        let midway = try await index.keywordSearch(query: "dmarc-help")
        #expect(midway.contains { $0.contentKey.rawValue == hid }, "mid-typing partial must match")

        // Multi-part partial from the start
        let partial = try await index.keywordSearch(query: "noreply-dmarc-")
        #expect(partial.contains { $0.contentKey.rawValue == hid }, "partial local-part must match")

        // Full address (adjacency phrase under the splitting tokenizer)
        let full = try await index.keywordSearch(query: "noreply-dmarc-helper@domain.com")
        #expect(full.contains { $0.contentKey.rawValue == hid }, "full address must match")

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
    }

    @Test("Tokenizer migration rebuilds old-tokenchars shards in place, preserving rowids")
    func tokenizerShardRebuild() async throws {
        // Seed a fake old-tokenizer shard for a year no real data uses (2001),
        // aligned with message_meta/message_ids the way indexHeaders would write,
        // then run the migration and verify: new tokenizer in sqlite_master,
        // rowids preserved, and part-queries match.
        let hid = "test_retok:INBOX:1"
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let oldTokenize = "porter unicode61 remove_diacritics 2 tokenchars '-_.@'"
        let rowid: Int64 = try await index.testSeedLegacyShard(
            year: 2001, tokenize: oldTokenize, contentKey: ContentKey(rawValue: hid), msgId: "<retok1@test.com>",
            subject: "Weekly digest", from: "billing-alerts@domain.com",
            body: "full body text here", dateMs: 980_000_000_000 // 2001 epoch ms
        )

        await index.rebuildStaleTokenizerShards()

        let sql = try await index.testShardCreateSQL(year: 2001)
        #expect(!(sql?.contains("tokenchars") ?? true), "shard must use the new tokenizer, got: \(sql ?? "nil")")

        // rowid alignment with message_meta must survive the rebuild
        let newRowid = try await index.testRowidForHeader(ContentKey(rawValue: hid))
        #expect(newRowid == rowid, "rowid must be preserved across rebuild")

        // Part-query now matches content indexed under the old scheme
        let hits = try await index.keywordSearch(query: "billing")
        #expect(hits.contains { $0.contentKey.rawValue == hid }, "address part must match after rebuild")
        let bodyHits = try await index.keywordSearch(query: "\"full body text\"")
        #expect(bodyHits.contains { $0.contentKey.rawValue == hid }, "body must survive rebuild")

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        try await index.testDropShard(year: 2001)
    }

    @Test("Tokenizer migration honors the deadline and resumes; hasStaleTokenizerShards tracks it")
    func tokenizerRebuildDeadline() async throws {
        let hid = "test_retok_dl:INBOX:1"
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let oldTokenize = "porter unicode61 remove_diacritics 2 tokenchars '-_.@'"
        _ = try await index.testSeedLegacyShard(
            year: 2002, tokenize: oldTokenize, contentKey: ContentKey(rawValue: hid), msgId: "<retokdl@test.com>",
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

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        try await index.testDropShard(year: 2002)
    }

    @Test("Tokenizer migration converts an EMPTY legacy shard")
    func tokenizerRebuildEmptyShard() async throws {
        let hid = "test_retok_empty:INBOX:1"
        let oldTokenize = "porter unicode61 remove_diacritics 2 tokenchars '-_.@'"
        _ = try await index.testSeedLegacyShard(
            year: 2003, tokenize: oldTokenize, contentKey: ContentKey(rawValue: hid), msgId: "<retokempty@test.com>",
            subject: "Empty test", from: "x@domain.com",
            body: "body", dateMs: 1_041_400_000_000 // 2003 epoch ms
        )
        // Empty the shard — removeMessages deletes the FTS row but leaves the table
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))

        await index.rebuildStaleTokenizerShards()

        let sql = try await index.testShardCreateSQL(year: 2003)
        #expect(sql?.contains("tokenchars") == false, "empty shard must still convert, got: \(sql ?? "nil")")

        try await index.testDropShard(year: 2003)
    }

    @Test("updateBody writes body text to FTS")
    func updateBodyWritesToFTS() async throws {
        let hid = "test_body_1:INBOX:1"
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid, messageId: "<body1@test.com>",
            subject: "Body Test", from: "a@test.com", to: "b@test.com",
            dateMs: 1_700_000_000_000
        )

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        try await index.updateBody( contentKey: ContentKey(rawValue: hid), body: "This is the full email body text for testing.")

        // Verify body is searchable
        let results = try await index.keywordSearch(query: "\"full email body text\"")
        #expect(results.contains { $0.contentKey.rawValue == hid })

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
    }

    @Test("updateBody for non-existent header is a no-op")
    func updateBodyNonExistent() async throws {
        try await index.updateBody( contentKey: ContentKey(rawValue: "nonexistent_test:INBOX:999"), body: "some body")
    }

    @Test("removeMessages removes indexed headers")
    func removeMessages() async throws {
        let hid = "test_remove_1:INBOX:1"
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid, messageId: "<remove1@test.com>",
            subject: "To Be Removed", from: "x@test.com", to: "y@test.com",
            dateMs: 1_700_000_000_000
        )

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let isIndexedBefore = try await index.isIndexed( contentKey: ContentKey(rawValue: hid))
        #expect(isIndexedBefore == true)

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))

        let isIndexedAfter = try await index.isIndexed( contentKey: ContentKey(rawValue: hid))
        #expect(isIndexedAfter == false)
    }

    @Test("removeMessages with empty array is a no-op")
    func removeMessagesEmpty() async throws {
        try await index.removeMessages( contentKeys: [])
    }

    @Test("isIndexed returns false for non-existent header")
    func isIndexedNonExistent() async throws {
        let result = try await index.isIndexed( contentKey: ContentKey(rawValue: "nonexistent_test:INBOX:999"))
        #expect(result == false)
    }

    @Test("documentCountForAccount uses headerId prefix matching")
    func documentCountForAccount() async throws {
        let records = [
            FTSHeaderRecord( contentKey: ContentKey(rawValue: "test_acct_count_a:INBOX:1"),headerId: "test_acct_count_a:INBOX:1", messageId: "m1", subject: "S1",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000),
            FTSHeaderRecord( contentKey: ContentKey(rawValue: "test_acct_count_a:INBOX:2"),headerId: "test_acct_count_a:INBOX:2", messageId: "m2", subject: "S2",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000),
            FTSHeaderRecord( contentKey: ContentKey(rawValue: "test_acct_count_b:INBOX:1"),headerId: "test_acct_count_b:INBOX:1", messageId: "m3", subject: "S3",
                            from: "c@c.com", to: "d@d.com", dateMs: 1_700_000_000_000),
        ]
        try await index.removeMessages( contentKeys: records.map(\.headerId).map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 3)

        let countA = try await index.documentCountForAccount(accountId: "test_acct_count_a")
        #expect(countA == 2)

        let countB = try await index.documentCountForAccount(accountId: "test_acct_count_b")
        #expect(countB == 1)

        let countNone = try await index.documentCountForAccount(accountId: "test_acct_count_nonexistent")
        #expect(countNone == 0)

        try await index.removeMessages( contentKeys: records.map(\.headerId).map(ContentKey.init(rawValue:)))
    }

    @Test("removeMessagesForAccount removes all messages for given account")
    func removeMessagesForAccount() async throws {
        let records = [
            FTSHeaderRecord( contentKey: ContentKey(rawValue: "test_acct_rm_a:INBOX:1"),headerId: "test_acct_rm_a:INBOX:1", messageId: "m1", subject: "S1",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000),
            FTSHeaderRecord( contentKey: ContentKey(rawValue: "test_acct_rm_a:INBOX:2"),headerId: "test_acct_rm_a:INBOX:2", messageId: "m2", subject: "S2",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000),
            FTSHeaderRecord( contentKey: ContentKey(rawValue: "test_acct_rm_b:INBOX:1"),headerId: "test_acct_rm_b:INBOX:1", messageId: "m3", subject: "S3",
                            from: "c@c.com", to: "d@d.com", dateMs: 1_700_000_000_000),
        ]
        try await index.removeMessages( contentKeys: records.map(\.headerId).map(ContentKey.init(rawValue:)))
        try await index.removeMessagesForAccount(accountId: "test_acct_rm_a")
        try await index.removeMessagesForAccount(accountId: "test_acct_rm_b")

        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 3)

        try await index.removeMessagesForAccount(accountId: "test_acct_rm_a")

        let countA = try await index.documentCountForAccount(accountId: "test_acct_rm_a")
        #expect(countA == 0)

        let countB = try await index.documentCountForAccount(accountId: "test_acct_rm_b")
        #expect(countB == 1)

        try await index.removeMessages( contentKeys: ["test_acct_rm_b:INBOX:1"].map(ContentKey.init(rawValue:)))
    }

    @Test("updateBodies batch updates body text for multiple messages")
    func updateBodies() async throws {
        let records = [
            FTSHeaderRecord( contentKey: ContentKey(rawValue: "test_bulk_body:INBOX:1"),headerId: "test_bulk_body:INBOX:1", messageId: "m1",
                            subject: "Bulk 1", from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000),
            FTSHeaderRecord( contentKey: ContentKey(rawValue: "test_bulk_body:INBOX:2"),headerId: "test_bulk_body:INBOX:2", messageId: "m2",
                            subject: "Bulk 2", from: "a@a.com", to: "b@b.com", dateMs: 1_710_000_000_000),
        ]
        try await index.removeMessages( contentKeys: records.map(\.headerId).map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 2)

        try await index.updateBodies([
            (headerId: "test_bulk_body:INBOX:1", body: "Body text one"),
            (headerId: "test_bulk_body:INBOX:2", body: "Body text two"),
        ].map { (contentKey: ContentKey(rawValue: $0.headerId), body: $0.body) })

        // Verify bodies are searchable
        let r1 = try await index.keywordSearch(query: "\"Body text one\"")
        let r2 = try await index.keywordSearch(query: "\"Body text two\"")
        #expect(r1.contains { $0.contentKey.rawValue == "test_bulk_body:INBOX:1" })
        #expect(r2.contains { $0.contentKey.rawValue == "test_bulk_body:INBOX:2" })

        try await index.removeMessages( contentKeys: records.map(\.headerId).map(ContentKey.init(rawValue:)))
    }

    @Test("updateBodies with empty array is a no-op")
    func updateBodiesEmpty() async throws {
        try await index.updateBodies([])
    }

    @Test("clearBodies removes body text from FTS")
    func clearBodies() async throws {
        let hid = "test_clear_body:INBOX:1"
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid, messageId: "m1", subject: "Clear Test",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        try await index.updateBody( contentKey: ContentKey(rawValue: hid), body: "Uniquecleartestbodytext here")
        let beforeClear = try await index.keywordSearch(query: "uniquecleartestbodytext")
        #expect(beforeClear.contains { $0.contentKey.rawValue == hid })

        try await index.clearBodies( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let afterClear = try await index.keywordSearch(query: "uniquecleartestbodytext")
        #expect(!afterClear.contains { $0.contentKey.rawValue == hid })

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
    }

    @Test("clearBodies with empty array is a no-op")
    func clearBodiesEmpty() async throws {
        try await index.clearBodies( contentKeys: [])
    }

    @Test("updateCcBcc updates cc and bcc fields")
    func updateCcBcc() async throws {
        let hid = "test_ccbcc:INBOX:1"
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid, messageId: "m1", subject: "CcBcc Test",
            from: "a@a.com", to: "b@b.com", cc: "", bcc: "",
            dateMs: 1_700_000_000_000
        )
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        try await index.updateCcBcc([(headerId: hid, cc: "cc@test.com", bcc: "bcc@test.com")].map { (contentKey: ContentKey(rawValue: $0.headerId), cc: $0.cc, bcc: $0.bcc) })

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
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
        let body = try await index.bodyText( contentKey: ContentKey(rawValue: "nonexistent_test:INBOX:999"))
        #expect(body == nil)
    }

    @Test("bodyText returns nil when body is empty")
    func bodyTextEmpty() async throws {
        let hid = "test_bodytext:INBOX:1"
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid, messageId: "m1", subject: "Body Text Test",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let body = try await index.bodyText( contentKey: ContentKey(rawValue: hid))
        #expect(body == nil)

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
    }

    @Test("bodyText returns text after updateBody")
    func bodyTextAfterUpdate() async throws {
        let hid = "test_bodytext2:INBOX:1"
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid, messageId: "m1", subject: "Body Text Test",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        try await index.updateBody( contentKey: ContentKey(rawValue: hid), body: "The actual email body content")
        let body = try await index.bodyText( contentKey: ContentKey(rawValue: hid))
        #expect(body == "The actual email body content")

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
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
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid, messageId: "m1",
            subject: "Zephyranthes Budgeticus Forecasticus",
            from: "finance@company.com", to: "team@company.com",
            dateMs: 1_700_000_000_000
        )
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        // Use a unique word to avoid matching other indexed messages
        let results = try await index.keywordSearch(query: "zephyranthes")
        let found = results.contains { $0.contentKey.rawValue == hid }
        #expect(found)

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
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
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid, messageId: "m1", subject: "Zero Date Test",
            from: "a@a.com", to: "b@b.com", dateMs: 0
        )
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let years = await index.sortedShardYears
        #expect(years.contains(2000))

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
    }

    @Test("Year shard for negative dateMs uses fallback year 2000")
    func yearShardNegativeDate() async throws {
        let hid = "test_negdate:INBOX:1"
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid, messageId: "m1", subject: "Negative Date Test",
            from: "a@a.com", to: "b@b.com", dateMs: -1000
        )
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let years = await index.sortedShardYears
        #expect(years.contains(2000))

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
    }

    // headerIdsNeedingEmbeddings, textForEmbedding removed — embeddings logic moved out of SearchIndex

    @Test("storeEmbedding does not crash for non-existent header")
    func storeEmbeddingNonExistent() async throws {
        let fakeEmbedding = [Float](repeating: 0.1, count: SearchConfig.embeddingDims)
        try await index.storeEmbedding( contentKey: ContentKey(rawValue: "nonexistent_test:INBOX:999"), embedding: fakeEmbedding)
    }

    @Test("storeEmbedding stores embedding for indexed message")
    func storeEmbedding() async throws {
        let hid = "test_store_emb:INBOX:1"
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid, messageId: "m1", subject: "Embed Store Test",
            from: "a@a.com", to: "b@b.com", dateMs: 1_700_000_000_000
        )
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let embedding = [Float](repeating: 0.5, count: SearchConfig.embeddingDims)
        try await index.storeEmbedding( contentKey: ContentKey(rawValue: hid), embedding: embedding)

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
    }

    @Test("keywordSearch with date range filters results")
    func keywordSearchWithDateRange() async throws {
        let records = [
            FTSHeaderRecord( contentKey: ContentKey(rawValue: "test_date_range:INBOX:1"),headerId: "test_date_range:INBOX:1", messageId: "m1",
                            subject: "Xylophone Zygote January Report",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_704_067_200_000),
            FTSHeaderRecord( contentKey: ContentKey(rawValue: "test_date_range:INBOX:2"),headerId: "test_date_range:INBOX:2", messageId: "m2",
                            subject: "Xylophone Zygote June Report",
                            from: "a@a.com", to: "b@b.com", dateMs: 1_719_792_000_000),
        ]
        try await index.removeMessages( contentKeys: records.map(\.headerId).map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == 2)

        let results = try await index.keywordSearch(
            query: "xylophone",
            fromDateMs: 1_704_067_200_000,
            toDateMs: 1_711_929_600_000
        )
        let foundJan = results.contains { $0.contentKey.rawValue == "test_date_range:INBOX:1" }
        let foundJun = results.contains { $0.contentKey.rawValue == "test_date_range:INBOX:2" }
        if !results.isEmpty {
            #expect(foundJan)
            #expect(!foundJun)
        }

        try await index.removeMessages( contentKeys: records.map(\.headerId).map(ContentKey.init(rawValue:)))
    }

    @Test("search with field-scoped query does not crash")
    func searchWithFieldScope() async throws {
        let hid = "test_field_search:INBOX:1"
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid, messageId: "m1", subject: "Important Report",
            from: "alice@company.com", to: "team@company.com",
            dateMs: 1_700_000_000_000
        )
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        let results = try await index.keywordSearch(query: "from:alice")
        #expect(results.count >= 0)

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
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

// MARK: - removeMessagesForFolder: the id table has no folder column

/// `message_meta` carries the authoritative folder relation, but `message_ids` does
/// not — so a folder purge driven purely by that relation cannot see an ORPHANED id
/// (one whose `message_meta` / shard rows are already gone from an earlier
/// partially-failed purge).
///
/// THE INVARIANT (the system end state, not the sweep's mechanism): after
/// `(accountId, folderPath)` is purged, no orphaned id keeps claiming a key in that
/// folder, and re-indexing a key belonging to it REALLY LANDS.
///
/// ⚑ ONE HALF OF THIS SUITE'S ORIGINAL RATIONALE WAS RETIRED BY T5.2 (ADR-IOS-066),
/// AND SAYING SO IS LOAD-BEARING. It used to read: *"`indexHeaders` is
/// `INSERT OR IGNORE` plus skip-if-unchanged, so a surviving orphan id turns the
/// post-purge resync's re-index into a silent no-op and the message occupying that
/// address under the new epoch is never searchable again."* `indexHeaders` is now an
/// upsert whose insert leg ADOPTS an orphan's rowid, so the re-index lands whether or
/// not the sweep ran. **The `reIndexed == 1` expectation below therefore no longer
/// discriminates the sweep's presence — `testContentKeyIsMinted(...) == false` is the
/// assertion that still goes RED without it.** Do not delete that one believing the
/// count covers it.
///
/// 🚨 THE TWO TRIPWIRES, both anti-mirror-image. The sweep is scoped by the composite
/// key's prefix, which is only sound with the no-deeper-colon guard (a ':'-delimiter
/// IMAP server makes `acct:INBOX:Sub:3` share `acct:INBOX:`), and it must fail CLOSED
/// where the two folder relations disagree: deleting an id whose `message_meta` row is
/// still live would strand a searchable entry with no id, which the next index of that
/// key turns into a second rowid whose stale twin keeps answering searches.
@Suite("SearchIndex folder purge clears orphaned ids", .serialized, .processGlobalState)
struct SearchIndexFolderPurgeOrphanTests {

    private var index: SearchIndex { SearchIndex.shared }

    /// `dateMs` is derived from the current date — a fixed epoch would silently pin
    /// the row to a year shard that drifts out of the fixture's meaning.
    private func record(_ key: String, folderId: String, subject: String) -> FTSHeaderRecord {
        FTSHeaderRecord(
            contentKey: ContentKey(rawValue: key),
            headerId: key,
            messageId: "m-\(key.suffix(6))",
            subject: subject,
            from: "sender@example.com",
            to: "recipient@example.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000),
            folderId: folderId
        )
    }

    @Test("A folder purge clears an orphaned id so the folder's key indexes again")
    func purgeClearsOrphanedId() async throws {
        let account = "ftsorphan-\(UUID().uuidString)"
        let folderId = MessageIdentity.folderId(accountId: account, folderPath: "INBOX")
        let key = MessageIdentity.headerId(accountId: account, folderPath: "INBOX", messageId: "1")
        let contentKey = ContentKey(rawValue: key)

        let inserted = try await index.indexHeaders(
            [record(key, folderId: folderId, subject: "Orphanzarquon subject")])
        try #require(inserted == 1)

        // Manufacture the orphan an interrupted purge leaves behind: the id row
        // survives, its `message_meta` and shard rows do not.
        try await index.testOrphanContentKey(contentKey)
        try #require(try await index.testContentKeyIsMinted(contentKey),
                     "precondition: the orphaned id is still minted")
        try #require(try await index.contentKeysMissingFromFTS([contentKey]).isEmpty == false,
                     "precondition: no message_meta row backs it")

        try await index.removeMessagesForFolder(accountId: account, folderPath: "INBOX")

        #expect(try await index.testContentKeyIsMinted(contentKey) == false,
                "an orphaned id in the purged folder must not survive the purge")

        // THE INVARIANT: the resync's re-index of that same key really lands.
        let reIndexed = try await index.indexHeaders(
            [record(key, folderId: folderId, subject: "Orphanzarquon subject")])
        // ⚑ NO LONGER A TRIPWIRE FOR THE SWEEP — see the suite doc. Since T5.2 the
        // upsert's insert leg adopts an orphan's rowid, so this lands either way. It
        // is kept because it still pins the end state the suite is named for: the
        // resynced message really becomes searchable.
        #expect(reIndexed == 1,
                "the post-purge resync of this key must produce a real FTS document")
        #expect(try await index.contentKeysMissingFromFTS([contentKey]).isEmpty,
                "the re-indexed key must be backed by a message_meta row again")

        try? await index.removeMessages(contentKeys: [contentKey])
    }

    @Test("A folder purge leaves an id whose live entry another folder still claims")
    func purgeLeavesDisputedLiveId() async throws {
        let account = "ftsorphanheld-\(UUID().uuidString)"
        let archiveFolderId = MessageIdentity.folderId(accountId: account, folderPath: "Archive")
        // The key says INBOX; the authoritative relation says Archive. That is a
        // legacy row still awaiting `backfillFolderIdsIfNeeded`, or the window
        // between a `rekeyHeaders` and its `updateFolderIds`.
        let key = MessageIdentity.headerId(accountId: account, folderPath: "INBOX", messageId: "2")
        let contentKey = ContentKey(rawValue: key)

        let inserted = try await index.indexHeaders(
            [record(key, folderId: archiveFolderId, subject: "Disputedzarquon subject")])
        try #require(inserted == 1)

        try await index.removeMessagesForFolder(accountId: account, folderPath: "INBOX")

        #expect(try await index.testContentKeyIsMinted(contentKey),
                "an id whose live entry another folder claims must not be half-deleted here")
        #expect(try await index.contentKeysMissingFromFTS([contentKey]).isEmpty,
                "its message_meta row must survive too — a stranded entry with no id is a wrong-occupant search hit")

        try? await index.removeMessages(contentKeys: [contentKey])
    }

    @Test("A ':'-delimited child folder's orphaned id survives its parent's purge")
    func childFolderOrphanSurvivesParentPurge() async throws {
        let account = "ftsorphanchild-\(UUID().uuidString)"
        let childPath = "INBOX:Sub"
        let childFolderId = MessageIdentity.folderId(accountId: account, folderPath: childPath)
        let key = MessageIdentity.headerId(accountId: account, folderPath: childPath, messageId: "3")
        let contentKey = ContentKey(rawValue: key)

        let inserted = try await index.indexHeaders(
            [record(key, folderId: childFolderId, subject: "Childzarquon subject")])
        try #require(inserted == 1)
        try await index.testOrphanContentKey(contentKey)
        try #require(try await index.testContentKeyIsMinted(contentKey),
                     "precondition: the child folder's orphaned id is still minted")

        try await index.removeMessagesForFolder(accountId: account, folderPath: "INBOX")

        #expect(try await index.testContentKeyIsMinted(contentKey),
                "a ':'-delimited CHILD folder's orphaned id must not be swept by its parent's purge")

        // Two-sided: the guard must scope the sweep, never make the id unreachable.
        try await index.removeMessagesForFolder(accountId: account, folderPath: childPath)
        #expect(try await index.testContentKeyIsMinted(contentKey) == false,
                "the child folder's OWN purge must still clear its orphaned id")
    }
}

// MARK: - Header upsert: correct a stale record, never destroy unproven content

/// `indexHeaders` used to be `INSERT OR IGNORE INTO message_meta` plus an explicit
/// skip-if-present, so a record left behind by a PREVIOUS occupant of a reused
/// content key could never be corrected. After a UIDVALIDITY reset, search returned
/// the NEW message carrying the OLD message's subject and sender — permanently.
///
/// 🚨 **A NULL identity stamp means RE-FETCH, NEVER DESTROY.** The reference guarded
/// this WRITE with a rule meant for READS and unrecoverably wiped the FTS body of
/// every pre-upgrade row. Only a POSITIVE mismatch — two values that are both
/// present and DIFFER — may clear anything. Absence of evidence is never evidence of
/// mismatch.
///
/// Every test pins the END STATE of the index (what a search returns, whether the
/// body survives), never the disposition enum's shape — a mechanism-pinning test
/// inherits a wrong spec's error and stays green on a broken system. Every preserve
/// case carries a positive-mismatch control that DOES clear IN THE SAME RUN, so a
/// system that never clears anything cannot pass it vacuously.
@Suite("SearchIndex header upsert identity disposition", .serialized, .processGlobalState)
struct SearchIndexHeaderUpsertTests {

    private var index: SearchIndex { SearchIndex.shared }

    /// Derived from `Date()` — a hardcoded epoch would silently pin every fixture to
    /// a year shard that drifts out of the fixture's meaning.
    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// The same UTC-year derivation `SearchIndex.yearFromDateMs` uses, so a seeded
    /// shard and an indexed record land in the same table.
    private var currentYear: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.component(.year, from: Date())
    }

    private func key(_ account: String, _ messageId: String) -> ContentKey {
        ContentKey(rawValue: MessageIdentity.headerId(
            accountId: account, folderPath: "INBOX", messageId: messageId))
    }

    private func record(
        _ contentKey: ContentKey,
        subject: String,
        from: String,
        rfc822MessageId: String? = nil,
        uidValidity: Int? = nil,
        resetAtMs: Int64? = nil,
        contentKeySpace: ContentKeySpace? = nil
    ) -> FTSHeaderRecord {
        FTSHeaderRecord(
            contentKey: contentKey,
            headerId: contentKey.rawValue,
            messageId: "1",
            subject: subject,
            from: from,
            to: "recipient@example.com",
            dateMs: nowMs,
            folderId: MessageIdentity.folderId(
                accountId: String(contentKey.rawValue.prefix(while: { $0 != ":" })),
                folderPath: "INBOX"),
            rfc822MessageId: rfc822MessageId,
            uidValidity: uidValidity,
            resetAtMs: resetAtMs,
            contentKeySpace: contentKeySpace
        )
    }

    private func hits(_ query: String) async throws -> Set<String> {
        Set(try await index.keywordSearch(query: query).map(\.contentKey.rawValue))
    }

    // MARK: (a) a disagreeing record IS overwritten

    @Test("A disagreeing record overwrites the stale one — the new occupant's subject answers and the previous occupant's no longer does")
    func disagreeingRecordIsOverwritten() async throws {
        let account = "ftsupsertclear-\(UUID().uuidString)"
        let target = key(account, "1")

        let inserted = try await index.indexHeaders([record(
            target, subject: "Staleoccupantzarquon subject", from: "stale@example.com",
            rfc822MessageId: "<stale@example.com>", uidValidity: 100,
            contentKeySpace: .uidAddressed)])
        try #require(inserted == 1)
        try await index.updateBody(contentKey: target, body: "Staleoccupantbodyzarquon text")
        let seeded = try await index.rawFTSBody(contentKey: target)
        try #require(seeded?.contains("Staleoccupantbodyzarquon") == true,
                     "precondition: the previous occupant's body is indexed")

        // The UID was reused: a DIFFERENT message now occupies this content key, and
        // says so on every identity value it states.
        let reIndexed = try await index.indexHeaders([record(
            target, subject: "Freshoccupantzarquon subject", from: "fresh@example.com",
            rfc822MessageId: "<fresh@example.com>", uidValidity: 200,
            contentKeySpace: .uidAddressed)])
        #expect(reIndexed == 0, "a refreshed entry is not a NEW document")

        let freshHits = try await hits("freshoccupantzarquon")
        let staleHits = try await hits("staleoccupantzarquon")
        #expect(freshHits.contains(target.rawValue),
                "the new occupant's subject must answer searches")
        #expect(staleHits.contains(target.rawValue) == false,
                "the previous occupant's subject must NOT keep answering — this permanent staleness is the whole defect the upsert exists to end")

        let survivingBody = try await index.rawFTSBody(contentKey: target)
        #expect(survivingBody?.isEmpty == true,
                "a POSITIVELY mismatched identity clears the previous occupant's body — it is not this message's content")
        let bodyHits = try await hits("staleoccupantbodyzarquon")
        #expect(bodyHits.contains(target.rawValue) == false,
                "and the cleared body must stop answering searches too")

        try? await index.removeMessages(contentKeys: [target])
    }

    // MARK: (b) a NULL-stamped pre-upgrade row KEEPS ITS BODY

    @Test("A NULL identity stamp means RE-FETCH, NEVER DESTROY — a pre-upgrade row keeps its body while its stale header fields are corrected")
    func nullIdentityStampPreservesTheBody() async throws {
        // A NULL identity stamp means RE-FETCH, NEVER DESTROY.
        //
        // The row seeded here is the shape EVERY row on a device upgrading into
        // ADR-IOS-066 has: written before `message_meta` carried an identity tuple,
        // so all five `identity*` columns are NULL. The reference guarded this WRITE
        // with a rule meant for READS and unrecoverably wiped the FTS body of every
        // one of them — an unrecoverable loss of user content, not a cache miss.
        // Absence of evidence is never evidence of mismatch.
        let account = "ftsupsertnull-\(UUID().uuidString)"
        let target = key(account, "1")

        _ = try await index.testSeedLegacyShard(
            year: currentYear, tokenize: SearchConfig.ftsTokenize, contentKey: target,
            msgId: "1", subject: "Preupgradezarquon subject",
            from: "preupgrade@example.com",
            body: "Preupgradebodyzarquon text", dateMs: nowMs)
        let seeded = try await index.rawFTSBody(contentKey: target)
        try #require(seeded?.contains("Preupgradebodyzarquon") == true,
                     "precondition: the pre-upgrade row carries an indexed body")

        // The incoming record POSITIVELY disagrees on every identity value it
        // states. The STORED side states nothing at all, so there is no mismatch —
        // there is only a message whose identity was never recorded.
        _ = try await index.indexHeaders([record(
            target, subject: "Adoptedzarquon subject", from: "adopted@example.com",
            rfc822MessageId: "<adopted@example.com>", uidValidity: 777,
            contentKeySpace: .uidAddressed)])

        let survivingBody = try await index.rawFTSBody(contentKey: target)
        #expect(survivingBody?.contains("Preupgradebodyzarquon") == true,
                "🚨 THE PRE-UPGRADE ROW'S BODY MUST SURVIVE. A NULL identity stamp means RE-FETCH, NEVER DESTROY — this is the exact write the reference got wrong, and it destroyed user content unrecoverably.")
        let bodyHits = try await hits("preupgradebodyzarquon")
        #expect(bodyHits.contains(target.rawValue),
                "and it must remain SEARCHABLE, not merely present in the row")

        // Preserve applies to CONTENT. The header fields are corrected regardless —
        // otherwise the pre-upgrade row would keep serving a stale subject forever.
        let adoptedHits = try await hits("adoptedzarquon")
        let staleHits = try await hits("preupgradezarquon")
        #expect(adoptedHits.contains(target.rawValue),
                "the incoming subject must answer")
        #expect(staleHits.contains(target.rawValue) == false,
                "the pre-upgrade subject must not keep answering")

        // TWO-SIDED, IN THE SAME RUN: the identical disagreement against a STAMPED
        // row DOES clear. Without this control the preserve above passes vacuously
        // against a system that never clears anything.
        let control = key(account, "2")
        let controlInserted = try await index.indexHeaders([record(
            control, subject: "Controloriginzarquon subject", from: "origin@example.com",
            rfc822MessageId: "<origin@example.com>", uidValidity: 100,
            contentKeySpace: .uidAddressed)])
        try #require(controlInserted == 1)
        try await index.updateBody(contentKey: control, body: "Controlbodyzarquon text")
        let controlSeeded = try await index.rawFTSBody(contentKey: control)
        try #require(controlSeeded?.contains("Controlbodyzarquon") == true,
                     "precondition: the control's body is indexed")

        _ = try await index.indexHeaders([record(
            control, subject: "Controlfreshzarquon subject", from: "fresh@example.com",
            rfc822MessageId: "<fresh@example.com>", uidValidity: 200,
            contentKeySpace: .uidAddressed)])
        let controlBody = try await index.rawFTSBody(contentKey: control)
        #expect(controlBody?.isEmpty == true,
                "the control MUST clear — a stamped row whose identity positively disagrees is a different message, and a run where nothing ever clears proves nothing about the preserve above")

        try? await index.removeMessages(contentKeys: [target, control])
    }

    // MARK: A stored NULL provider-space stamp is also unverified, not mismatched

    @Test("A stored NULL identityStableProvider preserves the body even though both RFC ids are present and differ")
    func nullStoredProviderSpacePreservesTheBody() async throws {
        // Written by a producer that did not state its provider's identity space, so
        // `identityStableProvider` is NULL. That is a second flavour of the same
        // rule: the stored tuple is INCOMPLETE, and an incomplete tuple is not a
        // mismatched one.
        let account = "ftsupsertnospace-\(UUID().uuidString)"
        let target = key(account, "1")

        let inserted = try await index.indexHeaders([record(
            target, subject: "Unstatedspacezarquon subject", from: "unstated@example.com",
            rfc822MessageId: "<unstated@example.com>", uidValidity: 100)])
        try #require(inserted == 1)
        try await index.updateBody(contentKey: target, body: "Unstatedbodyzarquon text")
        let seeded = try await index.rawFTSBody(contentKey: target)
        try #require(seeded?.contains("Unstatedbodyzarquon") == true,
                     "precondition: the unstated-space row carries an indexed body")

        _ = try await index.indexHeaders([record(
            target, subject: "Unstatedfreshzarquon subject", from: "fresh@example.com",
            rfc822MessageId: "<fresh@example.com>", uidValidity: 200,
            contentKeySpace: .uidAddressed)])

        let survivingBody = try await index.rawFTSBody(contentKey: target)
        #expect(survivingBody?.contains("Unstatedbodyzarquon") == true,
                "an incomplete stored tuple must preserve the body — absence of evidence is never evidence of mismatch")
        let adoptedHits = try await hits("unstatedfreshzarquon")
        #expect(adoptedHits.contains(target.rawValue),
                "the header fields are still adopted")

        // TWO-SIDED, IN THE SAME RUN: state the space on the stored side and the
        // very same disagreement clears.
        let control = key(account, "2")
        let controlInserted = try await index.indexHeaders([record(
            control, subject: "Statedspacezarquon subject", from: "stated@example.com",
            rfc822MessageId: "<stated@example.com>", uidValidity: 100,
            contentKeySpace: .uidAddressed)])
        try #require(controlInserted == 1)
        try await index.updateBody(contentKey: control, body: "Statedbodyzarquon text")
        let controlSeeded = try await index.rawFTSBody(contentKey: control)
        try #require(controlSeeded?.contains("Statedbodyzarquon") == true)

        _ = try await index.indexHeaders([record(
            control, subject: "Statedfreshzarquon subject", from: "fresh@example.com",
            rfc822MessageId: "<fresh@example.com>", uidValidity: 200,
            contentKeySpace: .uidAddressed)])
        let controlBody = try await index.rawFTSBody(contentKey: control)
        #expect(controlBody?.isEmpty == true,
                "the control MUST clear — the only difference is that the stored side STATED its space")

        try? await index.removeMessages(contentKeys: [target, control])
    }

    // MARK: The third arm — an older generation may not overwrite newer state

    @Test("An older-generation write is refused outright — its header fields never land on top of newer state")
    func olderGenerationWriteIsRefused() async throws {
        let account = "ftsupsertrefuse-\(UUID().uuidString)"
        let target = key(account, "1")
        let marker = nowMs

        let inserted = try await index.indexHeaders([record(
            target, subject: "Newergenzarquon subject", from: "newer@example.com",
            rfc822MessageId: "<gen@example.com>", uidValidity: 100,
            resetAtMs: marker, contentKeySpace: .uidAddressed)])
        try #require(inserted == 1)

        // A writer that carries NO reset marker against a stored one is an OLDER
        // generation by `resetMarkerOrder`'s ordering, and must not land.
        let refused = try await index.indexHeaders([record(
            target, subject: "Oldergenzarquon subject", from: "older@example.com",
            rfc822MessageId: "<gen@example.com>", uidValidity: 100,
            contentKeySpace: .uidAddressed)])
        #expect(refused == 0)
        let newerHits = try await hits("newergenzarquon")
        let olderHits = try await hits("oldergenzarquon")
        #expect(newerHits.contains(target.rawValue),
                "the newer generation's subject must still answer")
        #expect(olderHits.contains(target.rawValue) == false,
                "an older generation's subject must NOT overwrite it")

        // TWO-SIDED, IN THE SAME RUN: a strictly newer marker IS adopted, so the
        // refusal above is an ordering rule and not a re-introduced skip-if-present.
        _ = try await index.indexHeaders([record(
            target, subject: "Newestgenzarquon subject", from: "newest@example.com",
            rfc822MessageId: "<gen@example.com>", uidValidity: 100,
            resetAtMs: marker + 1000, contentKeySpace: .uidAddressed)])
        let newestHits = try await hits("newestgenzarquon")
        let stillNewerHits = try await hits("newergenzarquon")
        #expect(newestHits.contains(target.rawValue),
                "a strictly newer generation MUST be adopted")
        #expect(stillNewerHits.contains(target.rawValue) == false,
                "and it must replace the previous subject, not sit alongside it")

        try? await index.removeMessages(contentKeys: [target])
    }
}
