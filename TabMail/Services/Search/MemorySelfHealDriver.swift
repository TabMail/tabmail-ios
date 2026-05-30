/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Two-stage self-heal for memory indexing. Per-turn model (v3).
///
/// **Stage A — set-diff both directions:**
///
/// - `A = chatHistory.id rows eligible for indexing` (older than idle cutoff,
///    `type = 'normal'`, role ∈ {user, assistant}).
/// - `B = memory_meta.chatHistoryId`.
/// - `allChatHistory = every chatHistory.id` (regardless of age / type / role).
///
/// Work:
/// - **A − B → missing** → load turns, compute memoryText, `indexTurns(...)`,
///   enqueue for embedding.
/// - **B − allChatHistory → orphans** → `deleteTurns(...)`. (Using `A − B` for
///   orphans would wrongly include still-active session rows that memory.db
///   was allowed to index at write time via `appendTurn` — so orphan detection
///   uses the full chatHistory set, not the idle-cutoff subset.)
///
/// **Stage B — embedding queue repopulate:** picks up every
/// `embeddingComplete = 0` row (including those freshly written by Stage A)
/// and drives them to completion via `BackfillMemoryEmbeddingQueue`.
///
/// Called at sync startup (launch + foreground return) via `SyncScheduler`.
/// Non-throwing — logs internally.
///
/// See ADR-IOS-034.
enum MemorySelfHealDriver {

    /// Run both stages. Safe to call concurrently (actors serialize;
    /// `QueueStorage` dedups). Set-diff empties produce no work on re-runs.
    static func runStageAPlusB() async {
        print("[MemorySelfHealDriver] runStageAPlusB BEGIN")
        let t0 = Date()
        await runStageA()
        await BackfillMemoryEmbeddingQueue.shared.repopulateFromDatabase()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[MemorySelfHealDriver] runStageAPlusB END (\(ms)ms)")
    }

    /// Stage A only — exposed for tests.
    static func runStageA() async {
        let idleCutoffMs = Int64(
            Date().addingTimeInterval(-TimeInterval(SearchConfig.memorySelfHealIdleSec))
                .timeIntervalSince1970 * 1000
        )

        // A = eligible chatHistory turn IDs (older than idle cutoff).
        // allChatHistory = every chatHistory.id (for orphan detection).
        // B = memory.db known chatHistoryIds.
        let eligibleA: Set<String>
        let allChatHistory: Set<String>
        do {
            eligibleA = try await ChatStore.shared.historyTurnIdsForSelfHeal(olderThan: idleCutoffMs)
            allChatHistory = try await ChatStore.shared.allHistoryTurnIds()
        } catch {
            print("[MemorySelfHealDriver] ChatStore query failed: \(error)")
            return
        }
        let knownB = await MemoryIndex.shared.knownChatHistoryIds()
        let missing = eligibleA.subtracting(knownB)
        let orphans = knownB.subtracting(allChatHistory)
        print("[MemorySelfHealDriver] Stage A eligible=\(eligibleA.count) allChatHistory=\(allChatHistory.count) known=\(knownB.count) missing=\(missing.count) orphans=\(orphans.count) idleCutoffMs=\(idleCutoffMs)")

        // B − allChatHistory → delete orphans.
        if !orphans.isEmpty {
            await MemoryIndex.shared.deleteTurns(chatHistoryIds: Array(orphans))
        }

        // A − B → index missing turns. Chunk by SearchConfig.memorySelfHealChunkSize
        // so first-launch-after-upgrade doesn't materialize thousands of rows at once.
        guard !missing.isEmpty else { return }
        let missingIds = Array(missing)
        let chunkSize = SearchConfig.memorySelfHealChunkSize
        var chunkStart = 0
        while chunkStart < missingIds.count {
            let chunkEnd = min(chunkStart + chunkSize, missingIds.count)
            let chunk = Array(missingIds[chunkStart..<chunkEnd])
            await indexChunk(chunk)
            chunkStart = chunkEnd
        }
    }

    private static func indexChunk(_ ids: [String]) async {
        let turns: [ChatHistoryTurn]
        do {
            turns = try await ChatStore.shared.loadHistoryTurns(ids: ids)
        } catch {
            print("[MemorySelfHealDriver] loadHistoryTurns(chunk=\(ids.count)) failed: \(error)")
            return
        }

        var entries: [(chatHistoryId: String, sessionId: String?, role: String, dateMs: Int64, text: String)] = []
        entries.reserveCapacity(turns.count)
        for turn in turns {
            guard let text = MemoryIndex.memoryText(for: turn) else { continue }
            entries.append((
                chatHistoryId: turn.id,
                sessionId: turn.sessionId,
                role: turn.role,
                dateMs: Int64(turn.timestamp),
                text: text
            ))
        }

        guard !entries.isEmpty else {
            print("[MemorySelfHealDriver] indexChunk SKIP requested=\(ids.count) indexable=0 (all turns non-normal or empty text)")
            return
        }

        print("[MemorySelfHealDriver] indexChunk requested=\(ids.count) indexable=\(entries.count)")
        await MemoryIndex.shared.indexTurns(entries)
        await BackfillMemoryEmbeddingQueue.shared.enqueueBatch(entries.map { $0.chatHistoryId })
    }
}
