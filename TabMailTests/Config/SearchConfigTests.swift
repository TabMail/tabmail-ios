/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SearchConfig")
struct SearchConfigTests {

    @Test("BM25 weights have 7 columns matching FTS schema")
    func bm25WeightColumns() {
        let weights = SearchConfig.bm25Weights.components(separatedBy: ",")
        #expect(weights.count == 7)
    }

    @Test("Subject weight is highest in BM25")
    func subjectWeightHighest() {
        let weights = SearchConfig.bm25Weights.components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        // weights[1] = subject weight (5.0)
        #expect(weights[1] == 5.0)
        // Should be >= all other weights
        for (i, w) in weights.enumerated() where i != 1 {
            #expect(weights[1] >= w)
        }
    }

    @Test("Hybrid weights are complementary")
    func hybridWeightsComplementary() {
        #expect(SearchConfig.vectorWeight + SearchConfig.textWeight == 1.0)
    }

    @Test("Vector score threshold is between 0 and 1")
    func vectorScoreThreshold() {
        #expect(SearchConfig.vectorScoreThreshold > 0)
        #expect(SearchConfig.vectorScoreThreshold < 1)
    }

    @Test("Embedding dims is 384 (MiniLM)")
    func embeddingDims() {
        #expect(SearchConfig.embeddingDims == 384)
    }

    @Test("Max tokens is positive")
    func maxTokensPositive() {
        #expect(SearchConfig.maxTokens > 0)
    }

    @Test("Search default limit is reasonable")
    func defaultLimit() {
        #expect(SearchConfig.searchDefaultLimit > 0)
        #expect(SearchConfig.searchDefaultLimit <= 200)
    }

    @Test("Min score is non-negative")
    func minScoreNonNegative() {
        #expect(SearchConfig.minScore >= 0)
        #expect(SearchConfig.minScore < 1)
    }

    @Test("FTS tokenize config includes porter stemmer")
    func ftsTokenizeIncludesPorter() {
        #expect(SearchConfig.ftsTokenize.contains("porter"))
        #expect(SearchConfig.ftsTokenize.contains("unicode61"))
    }

    @Test("FTS automerge is positive")
    func ftsAutomerge() {
        #expect(SearchConfig.ftsAutomerge > 0)
    }

    @Test("SQLite pragmas are set")
    func sqlitePragmas() {
        #expect(SearchConfig.busyTimeoutMs > 0)
        #expect(SearchConfig.cacheSizeKiB < 0) // Negative = KiB
        #expect(SearchConfig.mmapSizeBytes > 0)
    }
}
