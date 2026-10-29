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
    /// Found by keyword: a result whatever its score (#304, native-fts #51).
    var keywordMatch: Bool
}

struct HybridResult {
    let rowid: Int64
    let finalScore: Double
    let textScore: Double
    let vectorScore: Double
    let dateMs: Int64
}

/// The order a search puts its matches in before it takes its limit. Mirrors tabmail-native-fts
/// `SearchSort` (#46, ADR-NF-017): relevance ties go newer first, date ties the better match first.
enum SearchSort: String, Sendable {
    case relevance
    case dateDesc = "date_desc"
    case dateAsc = "date_asc"
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

    /// A vector score rescaled: under `SearchConfig.vectorScoreThreshold` 0, above it 0..1.
    static func adjustedVectorScore(_ score: Double) -> Double {
        let th = SearchConfig.vectorScoreThreshold
        return max(0.0, (score - th) / (1.0 - th))
    }

    /// Merge FTS5 and vector search results into one list in `sort` order, then take `limit`. Every
    /// keyword match is a result; a candidate found by meaning alone needs `SearchConfig.minScore`.
    ///
    /// - Parameters:
    ///   - textResults: (rowid, bm25Rank) from FTS5 search
    ///   - vectorResults: (rowid, cosineDistance) from vector search
    ///   - dates: each candidate's dateMs; a candidate without one (its row is gone) is left out
    ///   - vectorWeight: weight for semantic score (0.0..1.0)
    ///   - textWeight: weight for keyword score (0.0..1.0)
    ///   - sort: relevance (ties newer first), or by date (ties the better match first); then rowid
    ///   - limit: maximum number of results to return
    static func mergeResults(
        textResults: [(Int64, Double)],
        vectorResults: [(Int64, Double)],
        dates: [Int64: Int64],
        vectorWeight: Double,
        textWeight: Double,
        sort: SearchSort,
        limit: Int
    ) -> [HybridResult] {
        var candidates = [Int64: HybridCandidate]()

        for (rowid, rank) in textResults {
            let score = bm25RankToScore(rank)
            if var existing = candidates[rowid] {
                existing.textScore = score
                candidates[rowid] = existing
            } else {
                candidates[rowid] = HybridCandidate(rowid: rowid, textScore: score, vectorScore: 0.0, keywordMatch: true)
            }
        }

        for (rowid, distance) in vectorResults {
            let score = cosineDistanceToScore(distance)
            if var existing = candidates[rowid] {
                existing.vectorScore = score
                candidates[rowid] = existing
            } else {
                candidates[rowid] = HybridCandidate(rowid: rowid, textScore: 0.0, vectorScore: score, keywordMatch: false)
            }
        }

        var results = candidates.values.compactMap { c -> HybridResult? in
            guard let dateMs = dates[c.rowid] else { return nil }
            // Rescale vector score: scores below threshold → 0, above → 0..1
            let adjustedVector = adjustedVectorScore(c.vectorScore)
            let finalScore = vectorWeight * adjustedVector + textWeight * c.textScore
            // Every keyword match is a result, however low it scores: a word in at least half the rows
            // scores about 0 by keyword (FTS5 clamps its IDF), and dropping those returned fewer
            // matches than a keyword-only search (#304, native-fts #51, ADR-NF-020). `minScore` gates
            // only the candidates found by meaning alone.
            guard c.keywordMatch || finalScore >= SearchConfig.minScore else { return nil }
            return HybridResult(
                rowid: c.rowid,
                finalScore: finalScore,
                textScore: c.textScore,
                vectorScore: c.vectorScore,
                dateMs: dateMs
            )
        }

        results.sort { a, b in
            let better = a.finalScore != b.finalScore ? a.finalScore > b.finalScore : nil
            let newer = a.dateMs != b.dateMs ? a.dateMs > b.dateMs : nil
            let first: Bool?
            switch sort {
            case .relevance: first = better ?? newer
            case .dateDesc: first = newer ?? better
            case .dateAsc: first = newer.map { !$0 } ?? better
            }
            return first ?? (a.rowid < b.rowid)
        }
        if results.count > limit {
            results = Array(results.prefix(limit))
        }
        return results
    }
}
