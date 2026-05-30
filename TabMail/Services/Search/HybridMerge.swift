/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// Score normalization and result merging for hybrid FTS5 + vector search.
// Ported from tabmail-native-fts/src/fts/hybrid.rs.

struct HybridCandidate {
    let rowid: Int64
    var textScore: Double
    var vectorScore: Double
}

struct HybridResult {
    let rowid: Int64
    let finalScore: Double
    let textScore: Double
    let vectorScore: Double
}

enum HybridMerge {

    /// Convert FTS5 BM25 rank to 0..1 score.
    /// BM25 rank from SQLite is negative (lower = better match).
    /// score = (-rank) / (1 + (-rank))
    static func bm25RankToScore(_ rank: Double) -> Double {
        let positiveRank = rank.isFinite ? max(-rank, 0.0) : 0.0
        return positiveRank / (1.0 + positiveRank)
    }

    /// Convert cosine distance to 0..1 score.
    /// distance=0 → 1.0 (identical), distance=1 → 0.0 (orthogonal).
    static func cosineDistanceToScore(_ distance: Double) -> Double {
        max(0.0, 1.0 - distance)
    }

    /// Merge FTS5 and vector search results into a single ranked list.
    ///
    /// - Parameters:
    ///   - textResults: (rowid, bm25Rank) from FTS5 search
    ///   - vectorResults: (rowid, cosineDistance) from vector search
    ///   - vectorWeight: weight for semantic score (0.0..1.0)
    ///   - textWeight: weight for keyword score (0.0..1.0)
    ///   - limit: maximum number of results to return
    static func mergeResults(
        textResults: [(Int64, Double)],
        vectorResults: [(Int64, Double)],
        vectorWeight: Double,
        textWeight: Double,
        limit: Int
    ) -> [HybridResult] {
        var candidates = [Int64: HybridCandidate]()

        for (rowid, rank) in textResults {
            let score = bm25RankToScore(rank)
            if var existing = candidates[rowid] {
                existing.textScore = score
                candidates[rowid] = existing
            } else {
                candidates[rowid] = HybridCandidate(rowid: rowid, textScore: score, vectorScore: 0.0)
            }
        }

        for (rowid, distance) in vectorResults {
            let score = cosineDistanceToScore(distance)
            if var existing = candidates[rowid] {
                existing.vectorScore = score
                candidates[rowid] = existing
            } else {
                candidates[rowid] = HybridCandidate(rowid: rowid, textScore: 0.0, vectorScore: score)
            }
        }

        var results = candidates.values.compactMap { c -> HybridResult? in
            // Rescale vector score: scores below threshold → 0, above → 0..1
            let th = SearchConfig.vectorScoreThreshold
            let adjustedVector = max(0.0, (c.vectorScore - th) / (1.0 - th))
            let finalScore = vectorWeight * adjustedVector + textWeight * c.textScore
            guard finalScore >= SearchConfig.minScore else { return nil }
            return HybridResult(
                rowid: c.rowid,
                finalScore: finalScore,
                textScore: c.textScore,
                vectorScore: c.vectorScore
            )
        }

        results.sort { $0.finalScore > $1.finalScore }
        if results.count > limit {
            results = Array(results.prefix(limit))
        }
        return results
    }
}
