/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Backfill embedding queue for historical messages. Power-aware — throttled by BackfillProfile.
/// Generates vector embeddings for messages with body text in FTS but no embedding.
///
/// Fed by BackfillBodyQueue via BodyFetchProcessor.flushBatch(enableAI: false).
/// Repopulated from GRDB on foreground return (catch-up for missed items).
///
/// Runs at utility priority with inter-batch delay based on power state.
actor BackfillEmbeddingQueue {
    static let shared = BackfillEmbeddingQueue()

    struct Item: Hashable {
        let headerId: String
    }

    /// Shared queue bookkeeping (FIFO, dedup, retry, concurrency).
    private var storage = QueueStorage<Item>()

    /// One batch at a time — CoreML is CPU-bound, no benefit from concurrent batches.
    private let maxActiveBatches = 1
    private let batchSize = SyncConfig.embeddingBatchSize

    private var debounceTask: Task<Void, Never>?

    /// One-shot flag so the EXPLAIN QUERY PLAN probe only logs once per process.
    /// Diagnostic for persistent 1.4-4.2s repopulate times even when 0 rows match.
    private var explainLogged = false

    // MARK: - Public API

    /// Enqueue a single header for embedding generation.
    func enqueue(headerId: String) {
        let item = Item(headerId: headerId)
        guard storage.enqueue(item) else { return }
        scheduleDispatch()
    }

    /// Enqueue a batch of headers (e.g., from body fetch completion).
    func enqueueBatch(_ headerIds: [String]) {
        let items = headerIds.map { Item(headerId: $0) }
        let added = storage.enqueueBatch(items)
        guard added > 0 else { return }
        print("[BackfillEmbeddingQueue] Enqueued \(added) items (total: \(storage.count))")
        scheduleDispatch()
    }

    /// Repopulate queue from GRDB on app launch / foreground return.
    /// Discovers messages with body indexed (bodyComplete=1) but no embedding (embeddingComplete=0).
    /// GRDB is sole authority — no cross-DB FTS query needed.
    func repopulateFromDatabase() async {
        guard EmbeddingService.shared != nil else { return }
        let t0 = CFAbsoluteTimeGetCurrent()

        let sql: String = """
            SELECT id FROM messageHeader
            WHERE bodyComplete = 1 AND embeddingComplete = 0 AND bodyEmptyConfirmed = 0
            ORDER BY isInInbox DESC, date DESC
            LIMIT \(SyncConfig.embeddingRepopulateChunk)
            """

        // One-shot EXPLAIN QUERY PLAN probe. Isolates whether the 1.4-4.2s
        // repopulate cost is planner picking the wrong index vs something else.
        if !explainLogged {
            explainLogged = true
            let probeT0 = CFAbsoluteTimeGetCurrent()
            do {
                let rows: [(id: Int64, parent: Int64, detail: String)] = try await AppDatabase.dbPool.read { db in
                    try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { row in
                        ((row["id"] as? Int64) ?? -1, (row["parent"] as? Int64) ?? -1, (row["detail"] as? String) ?? "?")
                    }
                }
                let probeMs = Int((CFAbsoluteTimeGetCurrent() - probeT0) * 1000)
                print("[BackfillEmbeddingQueue:EXPLAIN] probe \(probeMs)ms — plan:")
                for row in rows {
                    print("[BackfillEmbeddingQueue:EXPLAIN]   id=\(row.id) parent=\(row.parent) \(row.detail)")
                }
            } catch {
                print("[BackfillEmbeddingQueue:EXPLAIN] failed: \(error)")
            }
        }

        do {
            let headerIds: [String] = try await AppDatabase.dbPool.read { db in
                try Row.fetchAll(db, sql: sql)
                .map { $0["id"] as String }
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            guard !headerIds.isEmpty else {
                print("[BackfillEmbeddingQueue] Repopulate: 0 items (\(ms)ms)")
                return
            }

            let added = storage.enqueueBatch(headerIds.map { Item(headerId: $0) })
            if added > 0 {
                print("[BackfillEmbeddingQueue] Repopulated \(added) items from GRDB in \(ms)ms")
            }
            // Re-kick on every wake — items left pending by a suspend-abandoned
            // cycle (ADR-IOS-046) are already enqueued, so `added` (new rows only)
            // would skip them. scheduleDispatch is idempotent/guarded.
            if storage.pendingCount > 0 { scheduleDispatch() }
        } catch {
            print("[BackfillEmbeddingQueue] Repopulate failed: \(error)")
        }
    }

    /// Cancel all in-flight embedding tasks and reset queue state.
    /// Called on foreground return for consistency with other queues.
    func cancelAllInFlight() {
        let count = storage.inFlight.count
        storage.cancelAllInFlight()
        debounceTask?.cancel()
        debounceTask = nil
        if count > 0 {
            print("[BackfillEmbeddingQueue] Cancelled \(count) in-flight items on foreground return")
        }
    }

    /// Wait for all current embedding work to complete (used by BGProcessingTask).
    /// Respects Task cancellation for prompt BGProcessingTask exit.
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
                BackgroundSyncLogger.logBGProcessing("BackfillEmbeddingQueue draining... (depth=\(storage.count), active=\(storage.activeJobs), elapsed=\(elapsed)s)")
                lastHeartbeat = now
            }
        }
    }

    // MARK: - Dispatch

    /// Dispatch immediately when idle, debounce rapid subsequent enqueues.
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

        // ADR-IOS-046: abandon if the GRDB/FTS pool is suspended — the vector
        // write would only abort; candidates stay pending and re-dispatch next wake.
        guard !DatabaseSuspension.isSuspended else {
            #if DEBUG
            print("[BackfillEmbeddingQueue] DB suspended — abandoning dispatch (ADR-IOS-046)")
            #endif
            return
        }

        let candidates = storage.collectCandidates(maxJobs: batchSize)
        guard !candidates.isEmpty else { return }

        storage.incrementActiveJobs()
        print("[BackfillEmbeddingQueue] Dispatching batch of \(candidates.count) items (pending: \(storage.pendingCount))")

        Task { [self] in
            await processBatch(candidates)
        }
    }

    private func processBatch(_ items: [Item]) async {
        // Yield to a privileged merge before CoreML inference + the FTS vector
        // write (SearchIndex is a separate pool with sync `@noasync` writes).
        await PriorityGate.shared.yield("backfill-embed")
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let embeddingService = EmbeddingService.shared else {
            for item in items { storage.batchItemCompleted(item, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries) }
            storage.decrementActiveJobs()
            return
        }

        let headerIds = items.map(\.headerId)

        // 1. Bulk read headers from GRDB (1 query instead of N)
        let headersById: [String: MessageHeader]
        do {
            headersById = try await AppDatabase.dbPool.read { db in
                let headers = try MessageHeader
                    .filter(headerIds.contains(Column("id")))
                    .fetchAll(db)
                return Dictionary(uniqueKeysWithValues: headers.map { ($0.id, $0) })
            }
        } catch {
            print("[BackfillEmbeddingQueue] Bulk header read failed: \(error)")
            for item in items { storage.batchItemCompleted(item, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries) }
            storage.decrementActiveJobs()
            if storage.pendingCount > 0 { await dispatchBatch() }
            return
        }

        // 2. Bulk read body texts from FTS (1 transaction instead of N)
        let bodiesById: [String: String]
        do {
            bodiesById = try await SearchIndex.shared.bodyTexts(headerIds: headerIds)
        } catch {
            print("[BackfillEmbeddingQueue] Bulk body read failed: \(error)")
            for item in items { storage.batchItemCompleted(item, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries) }
            storage.decrementActiveJobs()
            if storage.pendingCount > 0 { await dispatchBatch() }
            return
        }

        // 3. Generate embeddings per item + collect results
        var succeeded: [(headerId: String, embedding: [Float])] = []
        var emptyBodyIds: [String] = []

        for item in items {
            guard let header = headersById[item.headerId] else {
                // Header deleted — mark done
                storage.batchItemCompleted(item, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries)
                continue
            }
            guard let body = bodiesById[item.headerId], !body.isEmpty else {
                // No body — mark embeddingComplete so we don't retry
                emptyBodyIds.append(item.headerId)
                storage.batchItemCompleted(item, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries)
                continue
            }

            do {
                let embedText = EmbeddingService.prepareEmailText(
                    subject: header.subject,
                    from: "\(header.from) <\(header.fromAddress)>",
                    to: header.to,
                    body: body
                )
                let embedding = try embeddingService.embed(embedText)
                succeeded.append((headerId: item.headerId, embedding: embedding))
                storage.batchItemCompleted(item, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries)
            } catch {
                print("[BackfillEmbeddingQueue] Embed failed for \(item.headerId.prefix(30)): \(error)")
                let hasMore = storage.batchItemCompleted(item, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
                _ = hasMore
            }
        }

        // 4. Bulk write embeddings to FTS (1 transaction instead of N)
        if !succeeded.isEmpty {
            do {
                try await SearchIndex.shared.storeEmbeddings(succeeded)
            } catch {
                print("[BackfillEmbeddingQueue] Bulk embedding write failed: \(error)")
            }
        }

        // 5. Bulk update embeddingComplete flags in GRDB (1 write instead of N)
        let allDoneIds = succeeded.map(\.headerId) + emptyBodyIds
        if !allDoneIds.isEmpty {
            // Background-tagged: yields to foreground/UI work.
            try? await AppDatabase.backgroundPool.write { db in
                try db.execute(
                    sql: "UPDATE messageHeader SET embeddingComplete = 1 WHERE id IN (\(allDoneIds.map { _ in "?" }.joined(separator: ",")))",
                    arguments: StatementArguments(allDoneIds)
                )
            }
        }

        storage.decrementActiveJobs()
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[BackfillEmbeddingQueue] Batch done: \(succeeded.count) embedded, \(emptyBodyIds.count) empty in \(ms)ms")

        // Power-aware inter-batch delay (turbo=0s, normal=3s, low=10s)
        let delay = await BackfillProfile.current().interCycleActiveDelay
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }

        if storage.pendingCount > 0 {
            await dispatchBatch()
        } else if storage.isEmpty && storage.activeJobs == 0 {
            // Drain-time safety net: re-query GRDB for any embedding work that
            // slipped past the push path (bodyComplete set but enqueue lost,
            // crash between body-write and embed-enqueue, etc.). Only when this
            // returns zero rows is the queue truly idle.
            await repopulateOnDrain()
        }
    }

    /// Drain-time self-repopulate: re-run the work-remaining query and enqueue any
    /// hits. Called only when `storage.isEmpty && storage.activeJobs == 0`, so no
    /// in-flight overlap. `QueueStorage.enqueue` dedups against `enqueued`
    /// (contains in-flight items) as a safety net.
    /// Mirrors `ActiveEmbeddingQueue.repopulateOnDrain` — same pattern, same scope.
    /// LIMIT 500 matches the Active variant — safety-net for missed items, not
    /// a bulk backfill load.
    private func repopulateOnDrain() async {
        guard EmbeddingService.shared != nil else { return }
        do {
            let ids: [String] = try await AppDatabase.dbPool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT id FROM messageHeader
                    WHERE bodyComplete = 1 AND embeddingComplete = 0 AND bodyEmptyConfirmed = 0
                    ORDER BY isInInbox DESC, date DESC
                    LIMIT 500
                    """)
            }
            guard !ids.isEmpty else { return }
            let items = ids.map { Item(headerId: $0) }
            let added = storage.enqueueBatch(items)
            if added > 0 {
                print("[BackfillEmbeddingQueue] Drain-time self-repopulate enqueued \(added) items")
                scheduleDispatch()
            }
        } catch {
            print("[BackfillEmbeddingQueue] Drain-time repopulate failed: \(error)")
        }
    }
}
