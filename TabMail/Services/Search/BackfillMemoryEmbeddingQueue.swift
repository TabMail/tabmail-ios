/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Backfill embedding queue for memory turns. Clone of `BackfillEmbeddingQueue`
/// (email). Power-aware, foreground-resumable, BGProcessingTask-compatible.
/// Owned by ADR-IOS-034.
///
/// All memory.db access goes through `MemoryIndex` actor methods — the queue never
/// touches the pool directly. Mirrors the email queue's use of
/// `SearchIndex.bodyTexts` / `.storeEmbeddings`.
///
/// Re-index race is handled by the `indexEpoch` stamp (NOT rowid — SQLite can reuse
/// a freshly-deleted rowid). See `MemoryIndex.storeEmbeddings`.
actor BackfillMemoryEmbeddingQueue {
    static let shared = BackfillMemoryEmbeddingQueue()

    struct Item: Hashable {
        let chatHistoryId: String
    }

    /// Shared queue bookkeeping (FIFO, dedup, retry, concurrency).
    private var storage = QueueStorage<Item>()

    /// One batch at a time — CoreML is CPU-bound.
    private let maxActiveBatches = 1
    private let batchSize = SyncConfig.memoryEmbeddingBatchSize

    private var debounceTask: Task<Void, Never>?

    // MARK: - Public API

    /// Enqueue a single turn for embedding generation.
    func enqueue(chatHistoryId: String) {
        let item = Item(chatHistoryId: chatHistoryId)
        guard storage.enqueue(item) else {
            print("[BackfillMemoryEmbeddingQueue] enqueue DUP id=\(chatHistoryId.prefix(20)) (already queued or in-flight)")
            return
        }
        print("[BackfillMemoryEmbeddingQueue] enqueue id=\(chatHistoryId.prefix(20)) (depth=\(storage.count))")
        scheduleDispatch()
    }

    /// Enqueue multiple turns (e.g., from Stage-A self-heal or repopulate).
    func enqueueBatch(_ chatHistoryIds: [String]) {
        let items = chatHistoryIds.map { Item(chatHistoryId: $0) }
        let added = storage.enqueueBatch(items)
        guard added > 0 else { return }
        print("[BackfillMemoryEmbeddingQueue] Enqueued \(added) items (total: \(storage.count))")
        scheduleDispatch()
    }

    /// Repopulate queue from memory.db on app launch / foreground return.
    /// Gated on EmbeddingService.shared — when CoreML isn't loaded yet, no-op
    /// (matches email). Next foreground return retries.
    func repopulateFromDatabase() async {
        guard EmbeddingService.shared != nil else { return }
        let t0 = CFAbsoluteTimeGetCurrent()

        let ids = await MemoryIndex.shared.pendingEmbeddingChatHistoryIds(
            limit: SyncConfig.memoryEmbeddingRepopulateChunk
        )
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        guard !ids.isEmpty else {
            print("[BackfillMemoryEmbeddingQueue] Repopulate: 0 items (\(ms)ms)")
            return
        }

        let added = storage.enqueueBatch(ids.map { Item(chatHistoryId: $0) })
        if added > 0 {
            print("[BackfillMemoryEmbeddingQueue] Repopulated \(added) items from memory.db in \(ms)ms")
        }
        // Re-kick on every wake — items left pending by a suspend-abandoned cycle
        // (ADR-IOS-046) are already enqueued, so `added` (new rows only) skips them.
        if storage.pendingCount > 0 { scheduleDispatch() }
    }

    /// Cancel all in-flight work — called on foreground return for consistency.
    func cancelAllInFlight() {
        let count = storage.inFlight.count
        storage.cancelAllInFlight()
        debounceTask?.cancel()
        debounceTask = nil
        if count > 0 {
            print("[BackfillMemoryEmbeddingQueue] Cancelled \(count) in-flight items on foreground return")
        }
    }

    /// Wait for all current embedding work to complete (used by BGProcessingTask).
    func awaitDrain() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        var lastHeartbeat = t0
        while true {
            if storage.isEmpty && storage.activeJobs == 0 { break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(200))
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastHeartbeat >= 5.0 {
                let elapsed = Int(now - t0)
                print("[BackfillMemoryEmbeddingQueue] draining... (depth=\(storage.count), active=\(storage.activeJobs), elapsed=\(elapsed)s)")
                lastHeartbeat = now
            }
        }
    }

    // MARK: - Dispatch

    private func scheduleDispatch() {
        if storage.activeJobs == 0 && debounceTask == nil {
            debounceTask = Task {
                await dispatchBatch()
                debounceTask = nil
            }
            return
        }
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await dispatchBatch()
            debounceTask = nil
        }
    }

    private func dispatchBatch() async {
        guard EmbeddingService.shared != nil else { return }
        guard storage.activeJobs < maxActiveBatches else { return }

        // ADR-IOS-046: abandon if the memory.db pool is suspended — the vec write
        // would only abort; candidates stay pending and re-dispatch next wake.
        guard !DatabaseSuspension.isSuspended else {
            #if DEBUG
            print("[BackfillMemoryEmbeddingQueue] DB suspended — abandoning dispatch (ADR-IOS-046)")
            #endif
            return
        }

        let candidates = storage.collectCandidates(maxJobs: batchSize)
        guard !candidates.isEmpty else { return }

        storage.incrementActiveJobs()
        print("[BackfillMemoryEmbeddingQueue] Dispatching batch of \(candidates.count) items (pending: \(storage.pendingCount))")

        Task { [self] in
            await processBatch(candidates)
        }
    }

    private func processBatch(_ items: [Item]) async {
        // Yield to a privileged merge before CoreML inference + the memory vec
        // write (MemoryIndex is a separate pool with sync `@noasync` writes).
        await PriorityGate.shared.yield("backfill-memory-embed")
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let embeddingService = EmbeddingService.shared else {
            // Mark all items shouldRetry:false so they don't loop; next
            // repopulateFromDatabase re-enqueues from the DB when CoreML loads.
            print("[BackfillMemoryEmbeddingQueue] processBatch SKIPPING items=\(items.count) (EmbeddingService.shared == nil)")
            for item in items { storage.batchItemCompleted(item, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries) }
            storage.decrementActiveJobs()
            return
        }

        let ids = items.map(\.chatHistoryId)

        // 1. Bulk-read FTS content + epoch stamps from memory.db.
        let contentMap = await MemoryIndex.shared.ftsContentWithEpochs(chatHistoryIds: ids)

        // 2. For each item: generate embedding. Collect (chatHistoryId, observedEpoch, embedding)
        //    for the store call; items with missing rows marked done (shouldRetry:false)
        //    so we don't loop on a deleted turn.
        var toStore: [(chatHistoryId: String, observedEpoch: Int64, embedding: [Float])] = []
        var localCompleted: [Item] = []
        var missingCount = 0
        var emptyContentCount = 0
        var embedErrorCount = 0

        for item in items {
            guard let entry = contentMap[item.chatHistoryId] else {
                // Turn missing (deleted between enqueue and process). Graceful skip.
                missingCount += 1
                storage.batchItemCompleted(item, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries)
                localCompleted.append(item)
                continue
            }
            if entry.content.isEmpty {
                emptyContentCount += 1
                storage.batchItemCompleted(item, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries)
                localCompleted.append(item)
                continue
            }

            let embedInput = EmbeddingService.truncateWords(
                entry.content,
                maxWords: SearchConfig.memoryMaxWords
            )
            do {
                let vec = try embeddingService.embed(embedInput)
                toStore.append((chatHistoryId: item.chatHistoryId, observedEpoch: entry.indexEpoch, embedding: vec))
            } catch {
                embedErrorCount += 1
                print("[BackfillMemoryEmbeddingQueue] Embed failed for \(item.chatHistoryId.prefix(20)): \(error)")
                _ = storage.batchItemCompleted(item, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
                localCompleted.append(item)
            }
        }
        print("[BackfillMemoryEmbeddingQueue] processBatch pre-store items=\(items.count) embedded=\(toStore.count) missing=\(missingCount) empty=\(emptyContentCount) embedErr=\(embedErrorCount)")

        // 3. Bulk-write to memory.db with epoch-stamp race check.
        if !toStore.isEmpty {
            let (committed, skippedRace) = await MemoryIndex.shared.storeEmbeddings(toStore)
            let committedSet = Set(committed)
            let skippedSet = Set(skippedRace)
            for pair in toStore {
                let item = Item(chatHistoryId: pair.chatHistoryId)
                if localCompleted.contains(item) { continue }
                if committedSet.contains(pair.chatHistoryId) {
                    storage.batchItemCompleted(item, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries)
                } else if skippedSet.contains(pair.chatHistoryId) {
                    _ = storage.batchItemCompleted(item, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
                } else {
                    // Turn deleted between ftsContentWithEpochs and storeEmbeddings
                    // (storeEmbeddings found no row). Treat as success — turn is gone.
                    storage.batchItemCompleted(item, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries)
                }
            }
        }

        storage.decrementActiveJobs()
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[BackfillMemoryEmbeddingQueue] Batch done in \(ms)ms")

        // Power-aware inter-batch delay (turbo=0s, normal=3s, low=10s).
        let delay = await BackfillProfile.current().interCycleActiveDelay
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }

        if storage.pendingCount > 0 {
            await dispatchBatch()
        } else if storage.isEmpty && storage.activeJobs == 0 {
            await repopulateOnDrain()
        }
    }

    /// Drain-time self-repopulate: re-run the work-remaining query and enqueue any hits.
    /// Sibling to email's `repopulateOnDrain` at `BackfillEmbeddingQueue.swift:292-313`.
    private func repopulateOnDrain() async {
        guard EmbeddingService.shared != nil else { return }
        let ids = await MemoryIndex.shared.pendingEmbeddingChatHistoryIds(
            limit: SyncConfig.memoryEmbeddingDrainRepopulateLimit
        )
        guard !ids.isEmpty else { return }
        let added = storage.enqueueBatch(ids.map { Item(chatHistoryId: $0) })
        if added > 0 {
            print("[BackfillMemoryEmbeddingQueue] Drain-time self-repopulate enqueued \(added) items")
            scheduleDispatch()
        }
    }
}

// MARK: - Test hooks

extension BackfillMemoryEmbeddingQueue {
    /// Reset storage between tests.
    func _testReset() {
        storage.cancelAllInFlight()
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Current queue depth for tests.
    func _testQueueDepth() -> Int { storage.count }

    /// In-flight count for tests.
    func _testInFlightCount() -> Int { storage.inFlight.count }

    /// Retry count for a specific turn.
    func _testRetryCount(chatHistoryId: String) -> Int {
        storage.retryCount(for: Item(chatHistoryId: chatHistoryId))
    }
}
