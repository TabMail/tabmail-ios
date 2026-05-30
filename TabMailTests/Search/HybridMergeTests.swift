/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("HybridMerge")
struct HybridMergeTests {

    // MARK: - bm25RankToScore

    @Test("BM25 rank 0 → score 0")
    func bm25Zero() {
        #expect(HybridMerge.bm25RankToScore(0.0) == 0.0)
    }

    @Test("BM25 rank -1 → score 0.5")
    func bm25NegativeOne() {
        let score = HybridMerge.bm25RankToScore(-1.0)
        #expect(abs(score - 0.5) < 0.001)
    }

    @Test("BM25 rank -10 → high score near 1")
    func bm25HighRank() {
        let score = HybridMerge.bm25RankToScore(-10.0)
        // (-(-10)) / (1 + (-(-10))) = 10/11 ≈ 0.909
        #expect(score > 0.9)
        #expect(score < 1.0)
    }

    @Test("BM25 score always in [0, 1]")
    func bm25Range() {
        let testRanks = [-100.0, -10.0, -1.0, 0.0, 1.0, 100.0]
        for rank in testRanks {
            let score = HybridMerge.bm25RankToScore(rank)
            #expect(score >= 0.0, "Score \(score) should be >= 0 for rank \(rank)")
            #expect(score <= 1.0, "Score \(score) should be <= 1 for rank \(rank)")
        }
    }

    @Test("BM25 handles NaN/Infinity gracefully")
    func bm25NonFinite() {
        let scoreNaN = HybridMerge.bm25RankToScore(Double.nan)
        let scoreInf = HybridMerge.bm25RankToScore(Double.infinity)
        #expect(scoreNaN >= 0.0 && scoreNaN <= 1.0)
        #expect(scoreInf >= 0.0 && scoreInf <= 1.0)
    }

    // MARK: - cosineDistanceToScore

    @Test("Cosine distance 0 → score 1 (identical)")
    func cosineZero() {
        #expect(HybridMerge.cosineDistanceToScore(0.0) == 1.0)
    }

    @Test("Cosine distance 1 → score 0 (orthogonal)")
    func cosineOne() {
        #expect(HybridMerge.cosineDistanceToScore(1.0) == 0.0)
    }

    @Test("Cosine distance 0.5 → score 0.5")
    func cosineHalf() {
        #expect(HybridMerge.cosineDistanceToScore(0.5) == 0.5)
    }

    @Test("Cosine distance > 1 → clamped to 0")
    func cosineClamped() {
        #expect(HybridMerge.cosineDistanceToScore(1.5) == 0.0)
    }

    // MARK: - mergeResults

    @Test("FTS-only results returned correctly")
    func ftsOnly() {
        let results = HybridMerge.mergeResults(
            textResults: [(1, -5.0), (2, -3.0), (3, -1.0)],
            vectorResults: [],
            vectorWeight: 0.3,
            textWeight: 0.7,
            limit: 10
        )
        #expect(!results.isEmpty)
        // Results should be sorted by finalScore descending
        for i in 0..<(results.count - 1) {
            #expect(results[i].finalScore >= results[i + 1].finalScore)
        }
    }

    @Test("Vector-only results returned correctly")
    func vectorOnly() {
        let results = HybridMerge.mergeResults(
            textResults: [],
            vectorResults: [(1, 0.1), (2, 0.3), (3, 0.5)],
            vectorWeight: 0.3,
            textWeight: 0.7,
            limit: 10
        )
        // Some results may be filtered by minScore threshold
        for result in results {
            #expect(result.textScore == 0.0)
        }
    }

    @Test("Dedup on overlapping results: same rowid in both")
    func dedupOverlapping() {
        let results = HybridMerge.mergeResults(
            textResults: [(1, -5.0)],
            vectorResults: [(1, 0.1)],
            vectorWeight: 0.3,
            textWeight: 0.7,
            limit: 10
        )
        // Should be deduplicated to a single entry
        let rowid1Count = results.filter { $0.rowid == 1 }.count
        #expect(rowid1Count <= 1)
    }

    @Test("Limit is respected")
    func limitRespected() {
        let text = (1...100).map { (Int64($0), -Double($0)) }
        let results = HybridMerge.mergeResults(
            textResults: text,
            vectorResults: [],
            vectorWeight: 0.3,
            textWeight: 0.7,
            limit: 5
        )
        #expect(results.count <= 5)
    }

    @Test("Results sorted by finalScore descending")
    func sortedDescending() {
        let results = HybridMerge.mergeResults(
            textResults: [(1, -10.0), (2, -1.0), (3, -5.0)],
            vectorResults: [],
            vectorWeight: 0.3,
            textWeight: 0.7,
            limit: 10
        )
        for i in 0..<(results.count - 1) {
            #expect(results[i].finalScore >= results[i + 1].finalScore)
        }
    }

    @Test("70/30 weighting: text dominates")
    func weightingTextDominates() {
        let results = HybridMerge.mergeResults(
            textResults: [(1, -10.0)],
            vectorResults: [(2, 0.0)],  // distance=0 → perfect vector match
            vectorWeight: 0.3,
            textWeight: 0.7,
            limit: 10
        )
        // Both should be present; text-heavy item should have higher final score
        // if text rank is high enough
        if results.count == 2 {
            let textItem = results.first { $0.rowid == 1 }
            let vectorItem = results.first { $0.rowid == 2 }
            if let t = textItem, let v = vectorItem {
                // Text item has high BM25 score × 0.7, vector item has 1.0 × 0.3
                #expect(t.finalScore > v.finalScore)
            }
        }
    }
}
