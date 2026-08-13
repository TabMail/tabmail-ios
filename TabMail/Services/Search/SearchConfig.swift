/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// All numeric constants for the search subsystem.
// Repo rule: no hardcoded numeric values scattered around.

enum SearchConfig {

    // MARK: - FTS5

    /// No tokenchars (ADR-024): unicode61 treats ALL non-alphanumeric characters
    /// as separators by default; the old `tokenchars '-_.@'` option made exactly
    /// those four token-INTERNAL, gluing addresses into single tokens that could
    /// only be prefix-matched from the token start — "dmarc-" never matched
    /// "noreply-dmarc-support@…". Without it, addresses index as parts
    /// (noreply / dmarc / support / domain / com) and any part is matchable;
    /// full-address queries are adjacency phrases.
    /// Changing this string triggers a background shard rebuild (SearchIndex
    /// detects stale shards via their CREATE statement in sqlite_master).
    /// Keep in lockstep with tabmail-native-fts config.rs FTS_TOKENIZE.
    static let ftsTokenize = "porter unicode61 remove_diacritics 2"
    static let ftsPrefixes = "2 3 4"

    /// BM25 column weights: msgId=0, subject=5, from_=3, to_=2, cc=1, bcc=1, body=1
    /// Matches TB's 7-column FTS schema (db.rs search_fts_candidates)
    static let bm25Weights = "0.0, 5.0, 3.0, 2.0, 1.0, 1.0, 1.0"

    static let searchDefaultLimit = 50
    static let snippetTokens = 16

    /// Row budget for `SearchView.legacyLocalSearch`'s substring scan — the size of the
    /// most-recent page the in-memory `localizedCaseInsensitiveContains` filter runs over.
    /// Was an inline literal at three sites after the scoped query was split per folder.
    static let legacySubstringScanRows = 200

    // MARK: - Hybrid Search

    static let vectorWeight: Double = 0.7
    static let textWeight: Double = 0.3

    /// Fetch N× candidates from each engine, merge to final limit.
    static let candidateMultiplier = 4

    /// Minimum combined score to return (filters noise).
    static let minScore: Double = 0.1

    /// Vector score threshold for rescaling. Scores below this map to 0;
    /// scores above are rescaled to 0..1 via max(0, (score - th) / (1 - th)).
    /// Prevents weak semantic associations from inflating final scores.
    static let vectorScoreThreshold: Double = 0.45

    // MARK: - Embeddings

    static let embeddingDims = 384
    static let maxTokens = 256

    /// Max words from body to include in embedding text prep.
    static let bodyMaxWords = 150

    // MARK: - FTS5 Migration

    /// Chunk size for one-time FTS shard migration (rows per transaction).
    static let shardMigrationChunkSize = 500

    /// Post-sync time budget for tokenizer shard conversion inside SHORT
    /// background windows (BGAppRefresh / silent push, ~30s total). Bounds how
    /// much of the window the migration may take after sync work completes;
    /// remaining shards resume in later windows or foreground. BGProcessing
    /// (minutes-scale) runs without this budget.
    static let retokenizeShortWindowBudgetSec: TimeInterval = 8

    // MARK: - FTS5 Write Tuning

    /// FTS5 automerge: merge segments when N accumulate at a level.
    /// Default=4, lower=more aggressive merging (slower writes, faster reads).
    /// Higher=deferred merging (faster writes, slightly slower reads).
    /// At 2.4GB+, automerge=2 causes 60ms/body writes. 8 cuts to ~20ms/body.
    static let ftsAutomerge = 8

    // MARK: - SQLite Pragmas

    static let busyTimeoutMs = 2000
    static let cacheSizeKiB = -64000  // negative = KiB
    static let mmapSizeBytes = 268_435_456

    // MARK: - Memory Search
    //
    // Slot-for-slot mirror of tabmail-native-fts/src/config.rs memory-specific constants.
    // TB keeps `MEMORY_VECTOR_WEIGHT` / `MEMORY_TEXT_WEIGHT` separate from the email pair
    // even though values are identical today — we match to preserve upstream-intent parity.

    /// Embedding-input word cap for memory documents (matches TB prepare_memory_text).
    /// Applied ONLY to the embedding input, not to the stored FTS content (CLAUDE.md rule 11).
    /// Sibling to `bodyMaxWords = 150` for email.
    static let memoryMaxWords = 200

    /// Mirrors TB `MEMORY_VECTOR_WEIGHT` at `config.rs:81`. Sibling to email `vectorWeight`.
    static let memoryVectorWeight: Double = 0.7

    /// Mirrors TB `MEMORY_TEXT_WEIGHT` at `config.rs:82`. Sibling to email `textWeight`.
    static let memoryTextWeight: Double = 0.3

    /// Pagination defaults — mirror TB `CHAT_SETTINGS.searchPageSizeDefault` and siblings.
    static let memoryPageSizeDefault = 5
    static let memoryPageSizeMax = 50
    static let memoryPrefetchPagesDefault = 4
    static let memoryPrefetchMaxResults = 200

    /// Fallback snippet length cap when FTS5 snippet is unavailable. Matches TB
    /// `memory_search.js:202` `content.slice(0, 400)`.
    static let memorySnippetMaxLength = 400

    /// MemoryReadTool LIMIT matching TB `memory_db.rs:850`.
    static let memoryReadLimit = 50

    /// MemoryReadTool DEFAULT_MAX_TURNS matching TB `memory_read.js:15`.
    static let memoryReadMaxTurns = 20

    /// MemoryReadTool DEFAULT_TOLERANCE_MS matching TB `memory_read.js:7`.
    static let memoryReadDefaultToleranceMs = 600_000

    /// Minimum seconds since a session's last turn for that session to be eligible
    /// for self-heal indexing. Protects in-progress sessions from being indexed
    /// prematurely — the natural session-end hook owns them until they idle out.
    static let memorySelfHealIdleSec = 60

    /// Max concurrent FTS-write Tasks during Stage-A self-heal. CLAUDE.md BOUNDED MEMORY rule.
    /// MemoryIndex actor serializes writes internally anyway; this cap bounds Task-struct memory.
    static let memorySelfHealMaxConcurrent = 4

    /// Number of chatHistory turns materialized per Stage A self-heal chunk (v3).
    /// Each chunk is one `MemoryIndex.indexTurns` write transaction. Bounded so that
    /// a first-launch-after-upgrade with thousands of turns doesn't spike memory or
    /// hold the write lock too long. CLAUDE.md BOUNDED MEMORY rule.
    static let memorySelfHealChunkSize = 200
}
