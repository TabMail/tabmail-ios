/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("Search Index FTS Schema")
struct SearchIndexSchemaTests {

    @Test("Year shard table name format")
    func yearShardFormat() {
        let year = 2024
        let tableName = "messages_fts_\(year)"
        #expect(tableName == "messages_fts_2024")
    }

    @Test("FTSHeaderRecord stores expected fields")
    func ftsHeaderRecordFields() {
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: "acc1:INBOX:1"),
            headerId: "acc1:INBOX:1",
            messageId: "1",
            subject: "Budget Review",
            from: "alice@test.com",
            to: "bob@test.com",
            cc: "",
            bcc: "",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        #expect(record.headerId == "acc1:INBOX:1")
        #expect(record.from == "alice@test.com")
        #expect(record.subject == "Budget Review")
    }

    @Test("FTSSearchResult stores score and snippet")
    func ftsSearchResult() {
        let result = FTSSearchResult( contentKey: ContentKey(rawValue: "acc1:INBOX:1"),
            messageId: "1",
            snippet: "...budget review...",
            rank: -5.2,
            dateMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        #expect(result.contentKey.rawValue == "acc1:INBOX:1")
        #expect(result.rank < 0) // BM25 scores are negative (higher magnitude = better match)
        #expect(result.snippet.contains("budget"))
    }
}

@Suite("SearchConfig Embedding Constants")
struct SearchConfigEmbeddingTests {

    @Test("Embedding dimension matches MiniLM-L6-v2")
    func embeddingDimension() {
        #expect(SearchConfig.embeddingDims == 384)
    }

    @Test("Vector weight is between 0 and 1")
    func vectorWeight() {
        #expect(SearchConfig.vectorWeight > 0)
        #expect(SearchConfig.vectorWeight <= 1.0)
    }

    @Test("Text weight is between 0 and 1")
    func textWeight() {
        #expect(SearchConfig.textWeight > 0)
        #expect(SearchConfig.textWeight <= 1.0)
    }

    @Test("BM25 weights string is non-empty")
    func bm25WeightsString() {
        #expect(!SearchConfig.bm25Weights.isEmpty)
        #expect(SearchConfig.bm25Weights.contains(","))
    }

    @Test("Max search default limit is reasonable")
    func searchDefaultLimit() {
        #expect(SearchConfig.searchDefaultLimit > 0)
        #expect(SearchConfig.searchDefaultLimit <= 200)
    }

    @Test("Max embedding tokens positive")
    func maxTokens() {
        #expect(SearchConfig.maxTokens > 0)
    }
}
