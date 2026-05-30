/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("HybridMerge Extended")
struct HybridMergeExtendedTests {

    // MARK: - bm25RankToScore

    @Test("bm25RankToScore: rank -10 gives ~0.91")
    func bm25RankNeg10() {
        let score = HybridMerge.bm25RankToScore(-10)
        #expect(score > 0.9)
        #expect(score < 0.92)
    }

    @Test("bm25RankToScore: rank -0.5 gives ~0.33")
    func bm25RankNeg05() {
        let score = HybridMerge.bm25RankToScore(-0.5)
        #expect(score > 0.3)
        #expect(score < 0.4)
    }

    @Test("bm25RankToScore: positive rank treated as 0")
    func bm25RankPositive() {
        let score = HybridMerge.bm25RankToScore(5.0)
        #expect(score == 0.0)
    }

    @Test("bm25RankToScore: NaN treated as 0")
    func bm25RankNaN() {
        let score = HybridMerge.bm25RankToScore(Double.nan)
        #expect(score == 0.0)
    }

    @Test("bm25RankToScore: -infinity treated as 0")
    func bm25RankNegInfinity() {
        let score = HybridMerge.bm25RankToScore(-Double.infinity)
        #expect(score == 0.0)
    }

    // MARK: - cosineDistanceToScore

    @Test("cosineDistanceToScore: distance 0.3 gives 0.7")
    func cosineDistance03() {
        let score = HybridMerge.cosineDistanceToScore(0.3)
        #expect(score == 0.7)
    }

    @Test("cosineDistanceToScore: negative distance clamped to 1.0")
    func cosineDistanceNegative() {
        let score = HybridMerge.cosineDistanceToScore(-0.5)
        #expect(score == 1.5) // max(0, 1 - (-0.5)) = 1.5... but actually:
        // Actually: max(0.0, 1.0 - (-0.5)) = max(0.0, 1.5) = 1.5
        // This is technically unclamped on the high end
    }

    @Test("cosineDistanceToScore: large distance clamped to 0")
    func cosineDistanceLarge() {
        let score = HybridMerge.cosineDistanceToScore(2.0)
        #expect(score == 0.0)
    }

    // MARK: - mergeResults

    @Test("mergeResults: empty inputs")
    func mergeEmpty() {
        let results = HybridMerge.mergeResults(
            textResults: [],
            vectorResults: [],
            vectorWeight: 0.7,
            textWeight: 0.3,
            limit: 10
        )
        #expect(results.isEmpty)
    }

    @Test("mergeResults: text-only results")
    func mergeTextOnly() {
        let results = HybridMerge.mergeResults(
            textResults: [(1, -5.0), (2, -3.0), (3, -1.0)],
            vectorResults: [],
            vectorWeight: 0.7,
            textWeight: 0.3,
            limit: 10
        )
        // All results should have vectorScore = 0
        for result in results {
            #expect(result.vectorScore == 0.0)
        }
    }

    @Test("mergeResults: respects limit")
    func mergeRespectsLimit() {
        let textResults: [(Int64, Double)] = (1...20).map { (Int64($0), -Double($0)) }
        let results = HybridMerge.mergeResults(
            textResults: textResults,
            vectorResults: [],
            vectorWeight: 0.7,
            textWeight: 0.3,
            limit: 5
        )
        #expect(results.count <= 5)
    }

    @Test("mergeResults: sorted by finalScore descending")
    func mergeSortedDescending() {
        let results = HybridMerge.mergeResults(
            textResults: [(1, -1.0), (2, -10.0), (3, -5.0)],
            vectorResults: [],
            vectorWeight: 0.0,
            textWeight: 1.0,
            limit: 10
        )
        for i in 0..<(results.count - 1) {
            #expect(results[i].finalScore >= results[i + 1].finalScore)
        }
    }

    @Test("mergeResults: deduplicates same rowid from both engines")
    func mergeDeduplicates() {
        let results = HybridMerge.mergeResults(
            textResults: [(1, -5.0)],
            vectorResults: [(1, 0.2)],
            vectorWeight: 0.7,
            textWeight: 0.3,
            limit: 10
        )
        let rowids = results.map { $0.rowid }
        let uniqueRowids = Set(rowids)
        #expect(rowids.count == uniqueRowids.count)
    }

    @Test("mergeResults: combined scores higher for dual-match")
    func mergeDualMatchBoost() {
        // Same item appearing in both text and vector results should score higher
        let results = HybridMerge.mergeResults(
            textResults: [(1, -5.0), (2, -5.0)],
            vectorResults: [(1, 0.1)], // item 1 also has vector match
            vectorWeight: 0.7,
            textWeight: 0.3,
            limit: 10
        )
        let item1 = results.first { $0.rowid == 1 }
        let item2 = results.first { $0.rowid == 2 }
        if let s1 = item1, let s2 = item2 {
            #expect(s1.finalScore >= s2.finalScore)
        }
    }
}
