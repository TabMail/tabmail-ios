/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Forward embedding queue for user-facing messages (delta sync, user-opened).
/// Runs at full speed — no power-aware throttling. UX-critical path.
///
/// Fed by ActiveBodyQueue via BodyFetchProcessor.flushBatch(enableAI: true).
/// Architecture: same as BackfillEmbeddingQueue but without inter-batch delay.
actor ActiveEmbeddingQueue {
    static let shared = ActiveEmbeddingQueue()

    struct Item: Hashable {
        let headerId: String
    }

    private var storage = QueueStorage<Item>()

    /// One batch at a time — CoreML is CPU-bound, no benefit from concurrent batches.
    private let maxActiveBatches = 1
    private let batchSize = SyncConfig.embeddingBatchSize

    private var debounceTask: Task<Void, Never>?

    // MARK: - Public API

    func enqueue(headerId: String) {
        let item = Item(headerId: headerId)
        guard storage.enqueue(item) else { return }
        scheduleDispatch()
    }

    func enqueueBatch(_ headerIds: [String]) {
        let items = headerIds.map { Item(headerId: $0) }
        let added = storage.enqueueBatch(items)
        guard added > 0 else { return }
        print("[ActiveEmbed] Enqueued \(added) items (total: \(storage.count))")
        scheduleDispatch()
    }

    func cancelAllInFlight() {
        let count = storage.inFlight.count
        storage.cancelAllInFlight()
        debounceTask?.cancel()
        debounceTask = nil
        if count > 0 {
            print("[ActiveEmbed] Cancelled \(count) in-flight items on foreground return")
        }
    }

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
                BackgroundSyncLogger.logBGProcessing("ActiveEmbeddingQueue draining... (depth=\(storage.count), active=\(storage.activeJobs), elapsed=\(elapsed)s)")
                lastHeartbeat = now
            }
        }
    }

    var isIdle: Bool {
        storage.isEmpty && storage.activeJobs == 0
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

        let candidates = storage.collectCandidates(maxJobs: batchSize)
        guard !candidates.isEmpty else { return }

        storage.incrementActiveJobs()
        print("[ActiveEmbed] Dispatching batch of \(candidates.count) items (pending: \(storage.pendingCount))")

        Task { [self] in
            await processBatch(candidates)
        }
    }

    private func processBatch(_ items: [Item]) async {
        // Yield to a privileged merge before CoreML inference + the FTS vector
        // write (SearchIndex is a separate pool with sync `@noasync` writes, so
        // the async caller yields on its behalf).
        await PriorityGate.shared.yield("active-embed")
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let embeddingService = EmbeddingService.shared else {
            for item in items { storage.batchItemCompleted(item, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries) }
            storage.decrementActiveJobs()
            return
        }

        let headerIds = items.map(\.headerId)

        let headersById: [String: MessageHeader]
        do {
            headersById = try await AppDatabase.dbPool.read { db in
                let headers = try MessageHeader
                    .filter(headerIds.contains(Column("id")))
                    .fetchAll(db)
                return Dictionary(uniqueKeysWithValues: headers.map { ($0.id, $0) })
            }
        } catch {
            print("[ActiveEmbed] Bulk header read failed: \(error)")
            for item in items { storage.batchItemCompleted(item, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries) }
            storage.decrementActiveJobs()
            if storage.pendingCount > 0 { await dispatchBatch() }
            return
        }

        let bodiesById: [String: String]
        do {
            bodiesById = try await SearchIndex.shared.bodyTexts(headerIds: headerIds)
        } catch {
            print("[ActiveEmbed] Bulk body read failed: \(error)")
            for item in items { storage.batchItemCompleted(item, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries) }
            storage.decrementActiveJobs()
            if storage.pendingCount > 0 { await dispatchBatch() }
            return
        }

        var succeeded: [(headerId: String, embedding: [Float])] = []
        var emptyBodyIds: [String] = []

        for item in items {
            guard let header = headersById[item.headerId] else {
                storage.batchItemCompleted(item, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries)
                continue
            }
            guard let body = bodiesById[item.headerId], !body.isEmpty else {
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
                print("[ActiveEmbed] Embed failed for \(item.headerId.prefix(30)): \(error)")
                let hasMore = storage.batchItemCompleted(item, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
                _ = hasMore
            }
        }

        if !succeeded.isEmpty {
            do {
                try await SearchIndex.shared.storeEmbeddings(succeeded)
            } catch {
                print("[ActiveEmbed] Bulk embedding write failed: \(error)")
            }
        }

        let allDoneIds = succeeded.map(\.headerId) + emptyBodyIds
        if !allDoneIds.isEmpty {
            try? await AppDatabase.dbPool.write { db in
                try db.execute(
                    sql: "UPDATE messageHeader SET embeddingComplete = 1 WHERE id IN (\(allDoneIds.map { _ in "?" }.joined(separator: ",")))",
                    arguments: StatementArguments(allDoneIds)
                )
            }
        }

        storage.decrementActiveJobs()
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[ActiveEmbed] Batch done: \(succeeded.count) embedded, \(emptyBodyIds.count) empty in \(ms)ms")

        // No inter-batch delay — forward queue runs at full speed

        if storage.pendingCount > 0 {
            await dispatchBatch()
        } else if storage.isEmpty && storage.activeJobs == 0 {
            // Drain-time safety net: re-query GRDB for any embedding work that
            // slipped past the push path (flushBatch.enqueue lost, crash between
            // body-write and embed-enqueue, etc.). Only when this returns zero
            // rows is the queue truly idle.
            await repopulateOnDrain()
        }
    }

    /// Drain-time self-repopulate. Called only when storage is empty and no batch is
    /// active, so no in-flight overlap. `QueueStorage.enqueue` dedups against `enqueued`
    /// (which contains in-flight items) as a safety net.
    private func repopulateOnDrain() async {
        do {
            let ids: [String] = try await AppDatabase.dbPool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT id FROM messageHeader
                    WHERE bodyComplete = 1 AND embeddingComplete = 0 AND bodyEmptyConfirmed = 0
                    ORDER BY date DESC
                    LIMIT 500
                    """)
            }
            guard !ids.isEmpty else { return }
            let items = ids.map { Item(headerId: $0) }
            let added = storage.enqueueBatch(items)
            if added > 0 {
                print("[ActiveEmbed] Drain-time self-repopulate enqueued \(added) items")
                scheduleDispatch()
            }
        } catch {
            print("[ActiveEmbed] Drain-time repopulate failed: \(error)")
        }
    }
}
