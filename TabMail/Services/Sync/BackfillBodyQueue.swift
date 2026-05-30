/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Backward body-fetch queue for backfill (all non-inbox messages).
/// Uses shared BodyFetchProcessor: full message fetch → render → FTS → flags.
/// No AI processing (forward ActiveBodyQueue handles inbox AI).
///
/// Batched dispatch: groups items by (account, folder), batch-fetches from provider
/// (single IMAP SELECT + bulk BODYSTRUCTURE), processes all results, writes FTS in one batch.
actor BackfillBodyQueue {
    static let shared = BackfillBodyQueue()

    struct Item: Hashable {
        let headerId: String
        let accountId: String
        let folderPath: String
        let messageId: String
        let isInInbox: Bool
    }

    private var storage = QueueStorage<Item>()

    private var debounceTask: Task<Void, Never>?
    private var connectivityWatchTask: Task<Void, Never>?
    /// Tracked batch Tasks — cancelled by cancelAllInFlight() to free dead IMAP connections.
    private var batchTasks: [Task<Void, Never>] = []

    /// Concurrency is per-batch (not per-item). Each batch task holds one IMAP connection.
    /// Limit to a few concurrent batches (e.g. different folders/accounts in parallel).
    private var activeBatchCount = 0
    private let maxConcurrentBatches = 3
    private let batchSize = SyncConfig.backfillBodyDispatchBatch // 50

    /// Per-folder batch size cap. Halved on PayloadTooLargeError, restored on success.
    /// Missing entry = use default batchSize.
    private var folderMaxBatch: [String: Int] = [:]
    /// Per-folder active batch count. Max 2 per folder (1 running + 1 queued).
    private var folderActiveBatches: [String: Int] = [:]
    private let maxBatchesPerFolder = 2

    private var dbPool: DatabasePool { AppDatabase.dbPool }

    // MARK: - Public API

    func enqueue(_ items: [Item]) {
        var added = 0
        for item in items {
            if storage.enqueue(item) { added += 1 }
        }
        guard added > 0 else { return }
        print("[BackfillBody] Enqueued \(added) items (total: \(storage.count))")
        scheduleDispatch()
    }

    func enqueueItems(ftsRecords: [FTSHeaderRecord], accountId: String, folderPath: String, isInInbox: Bool) {
        var added = 0
        for record in ftsRecords {
            let item = Item(
                headerId: record.headerId, accountId: accountId,
                folderPath: folderPath, messageId: record.messageId,
                isInInbox: isInInbox
            )
            if storage.enqueue(item) { added += 1 }
        }
        guard added > 0 else { return }
        print("[BackfillBody] Enqueued \(added) backfill items (total: \(storage.count))")
        scheduleDispatch()
    }

    func enqueueSingle(_ item: Item) {
        guard storage.enqueue(item) else { return }
        scheduleDispatch()
    }

    func repopulateFromDatabase() async {
        let t0 = CFAbsoluteTimeGetCurrent()

        do {
            // Single query — no OFFSET pagination (OFFSET re-reads all preceding rows).
            // 5 columns * 200K rows ≈ 30MB, acceptable for one-time startup load.
            let items: [Item] = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, accountId, folderPath, messageId, isInInbox
                    FROM messageHeader
                    WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 0
                    ORDER BY date DESC
                    """)
                .map { row in
                    Item(
                        headerId: row["id"],
                        accountId: row["accountId"],
                        folderPath: row["folderPath"],
                        messageId: row["messageId"],
                        isInInbox: row["isInInbox"]
                    )
                }
            }

            var totalAdded = 0
            for item in items {
                if storage.enqueue(item) { totalAdded += 1 }
            }

            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if totalAdded > 0 {
                print("[BackfillBody] Repopulated \(totalAdded) items in \(ms)ms")
                scheduleDispatch()
            } else {
                print("[BackfillBody] Repopulate: 0 non-inbox messages need body fetch (\(ms)ms)")
            }
        } catch {
            print("[BackfillBody] Repopulate failed: \(error)")
        }
    }

    func cancelAllInFlight() {
        let itemCount = storage.inFlight.count
        storage.cancelAllInFlight()
        let taskCount = batchTasks.count
        for task in batchTasks { task.cancel() }
        batchTasks.removeAll()
        activeBatchCount = 0
        folderActiveBatches.removeAll()
        debounceTask?.cancel()
        debounceTask = nil
        connectivityWatchTask?.cancel()
        connectivityWatchTask = nil
        if itemCount > 0 || taskCount > 0 {
            print("[BackfillBody] Cancelled \(taskCount) batch tasks, \(itemCount) in-flight items")
        }
    }

    var isIdle: Bool {
        storage.isEmpty && activeBatchCount == 0
    }

    func awaitDrain() async {
        while !storage.isEmpty || activeBatchCount > 0 {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Dispatch

    private func scheduleDispatch() {
        guard activeBatchCount < maxConcurrentBatches else { return }
        guard storage.pendingCount > 0 else { return }
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await dispatchBatch()
            debounceTask = nil
        }
    }

    private func scheduleDispatchOnReconnect() {
        guard connectivityWatchTask == nil else { return }
        connectivityWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                if NetworkMonitor.checkConnected() {
                    await self?.scheduleDispatch()
                    return
                }
            }
        }
    }

    /// Batched dispatch: groups items by (account, folder), launches one Task per group.
    /// Each Task does: batch IMAP fetch → render → process → FTS write in one shot.
    /// No deferred FTS buffer — the IMAP batch IS the write batch.
    /// Concurrency is per-batch (not per-item) — always collects full batches.
    private func dispatchBatch() async {
        guard NetworkMonitor.checkConnected() else {
            if !storage.isEmpty { scheduleDispatchOnReconnect() }
            return
        }
        connectivityWatchTask?.cancel()
        connectivityWatchTask = nil

        // Always collect a full batch — concurrency is limited by activeBatchCount, not per-item
        let batch = storage.collectCandidates(maxJobs: storage.activeJobs + batchSize)
        guard !batch.isEmpty else { print("[BackfillBody] dispatchBatch: no candidates"); return }

        // Resolve providers
        var providerByAccount: [String: any EmailProvider] = [:]
        for accountId in Set(batch.map(\.accountId)) {
            if let provider = await AccountManager.shared.workQueues[accountId]?.provider {
                providerByAccount[accountId] = provider
            }
        }

        // Group by (accountId, folderPath) for batched IMAP fetch.
        // Skip folders already at max batches (1 running + 1 queued) — items go back to pending.
        struct GroupKey: Hashable { let accountId: String; let folderPath: String }
        var groups: [GroupKey: [Item]] = [:]
        for item in batch {
            guard providerByAccount[item.accountId] != nil else {
                storage.releaseInFlightOnly(item)
                continue
            }
            let active = folderActiveBatches[item.folderPath] ?? 0
            guard active < maxBatchesPerFolder else {
                storage.releaseInFlightOnly(item)
                continue
            }
            let key = GroupKey(accountId: item.accountId, folderPath: item.folderPath)
            groups[key, default: []].append(item)
        }

        // Sort groups by size descending — dispatch largest groups first for best throughput.
        // Only launch up to maxConcurrentBatches groups to avoid pool/NIO saturation.
        // Remaining items stay in-flight and get released back for next dispatch.
        let sortedGroups = groups.sorted { $0.value.count > $1.value.count }
        let slotsAvailable = maxConcurrentBatches - activeBatchCount
        let groupsToDispatch = Array(sortedGroups.prefix(slotsAvailable))
        let groupsDeferred = Array(sortedGroups.dropFirst(slotsAvailable))

        // Release deferred groups back to pending
        for (_, items) in groupsDeferred {
            for item in items { storage.releaseInFlightOnly(item) }
        }

        let dispatchCount = groupsToDispatch.reduce(0) { $0 + $1.value.count }
        let deferredCount = groupsDeferred.reduce(0) { $0 + $1.value.count }
        print("[BackfillBody] Dispatching \(dispatchCount) items in \(groupsToDispatch.count) folder groups (deferred=\(deferredCount), activeBatches=\(activeBatchCount))")

        for (key, allItems) in groupsToDispatch {
            guard let provider = providerByAccount[key.accountId] else { continue }

            // Cap folder group by per-folder batch limit (halved on PayloadTooLarge)
            let maxForFolder = folderMaxBatch[key.folderPath] ?? batchSize
            let items: [Item]
            if allItems.count > maxForFolder {
                items = Array(allItems.prefix(maxForFolder))
                let excess = Array(allItems.dropFirst(maxForFolder))
                for item in excess { storage.releaseInFlightOnly(item) }
            } else {
                items = allItems
            }

            let itemCount = items.count
            activeBatchCount += 1
            folderActiveBatches[key.folderPath, default: 0] += 1

            let batchTask = Task { [self] in
                let t0 = CFAbsoluteTimeGetCurrent()
                print("[BackfillBody] Batch START: \(itemCount) items in \(key.folderPath)")

                do {
                    // 1. Batch fetch from provider (single SELECT + bulk BODYSTRUCTURE for IMAP)
                    let tFetch = CFAbsoluteTimeGetCurrent()
                    let fetched = try await provider.fetchMessagesBatch(
                        ids: items.map(\.messageId), folder: key.folderPath
                    )
                    let fetchMs = Int((CFAbsoluteTimeGetCurrent() - tFetch) * 1000)
                    print("[BackfillBody] Batch FETCH: \(fetched.count)/\(itemCount) succeeded in \(fetchMs)ms")

                    // 2. Render + process each result (parallel — renders are independent)
                    let tProcess = CFAbsoluteTimeGetCurrent()
                    let processedItems: [BodyFetchProcessor.ProcessedItem] = await withTaskGroup(
                        of: (Item, BodyFetchProcessor.ProcessedItem?, Bool).self
                    ) { group in
                        for item in items {
                            if let fullMessage = fetched[item.messageId] {
                                group.addTask {
                                    let processorItem = BodyFetchProcessor.Item(
                                        headerId: item.headerId, accountId: item.accountId,
                                        folderPath: item.folderPath, messageId: item.messageId,
                                        isInInbox: item.isInInbox
                                    )
                                    let renderResult = await BodyFetchProcessor.renderFetched(
                                        item: processorItem, fullMessage: fullMessage
                                    )
                                    switch renderResult {
                                    case .success(let fetchResult):
                                        let (result, processed) = await BodyFetchProcessor.process(
                                            fetchResult: fetchResult, enableAI: false
                                        )
                                        return (item, processed, result == .retry)
                                    case .failure:
                                        return (item, nil, true)
                                    }
                                }
                            } else {
                                print("[BackfillBody] Item \(item.messageId) not in batch result — will retry")
                            }
                        }
                        var collected: [BodyFetchProcessor.ProcessedItem] = []
                        for await (item, processed, shouldRetry) in group {
                            if let processed { collected.append(processed) }
                            self.batchItemDone(item: item, shouldRetry: shouldRetry)
                        }
                        return collected
                    }
                    // Handle items not in fetch result — confirmed-gone detection.
                    // After EmailProvider's fetchMessagesBatch fix, "missing from result"
                    // is authoritative for Gmail/Exchange (only 404s are omitted). For
                    // IMAP, we additionally confirm via rfc822 SEARCH before deleting
                    // (disambiguates UIDVALIDITY remap from actual deletion).
                    let missedItems = items.filter { fetched[$0.messageId] == nil }
                    if !missedItems.isEmpty {
                        await self.handleMissedItems(missedItems, provider: provider)
                    }
                    let processMs = Int((CFAbsoluteTimeGetCurrent() - tProcess) * 1000)

                    // 3. Write ALL to FTS + update headers in one batch
                    if !processedItems.isEmpty {
                        await BodyFetchProcessor.flushBatch(processedItems, enableAI: false)
                    }

                    let totalMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    print("[BackfillBody] Batch DONE: \(itemCount) items (\(processedItems.count) with body) in \(totalMs)ms (fetch=\(fetchMs)ms, process=\(processMs)ms)")

                    // Success — restore folder batch size if it was halved
                    if self.folderMaxBatch[key.folderPath] != nil {
                        self.folderMaxBatch.removeValue(forKey: key.folderPath)
                    }

                } catch {
                    let desc = "\(error)"
                    if desc.contains("PayloadTooLargeError") {
                        let current = self.folderMaxBatch[key.folderPath] ?? self.batchSize
                        if current <= 1 {
                            // Single message too large — mark all items as empty
                            print("[BackfillBody] Single item too large for \(key.folderPath) — marking bodyEmptyConfirmed")
                            for item in items {
                                try? await AppDatabase.dbPool.write { db in
                                    try db.execute(
                                        sql: "UPDATE messageHeader SET bodyEmptyConfirmed = 1 WHERE id = ?",
                                        arguments: [item.headerId]
                                    )
                                }
                                self.batchItemDone(item: item, shouldRetry: false)
                            }
                        } else {
                            let halved = max(1, current / 2)
                            self.folderMaxBatch[key.folderPath] = halved
                            print("[BackfillBody] PayloadTooLarge for \(key.folderPath) — halving batch to \(halved)")
                            for item in items {
                                self.batchItemDone(item: item, shouldRetry: true)
                            }
                        }
                    } else {
                        // Connection-level error — retry all items
                        print("[BackfillBody] Batch FAILED for \(key.folderPath): \(error)")
                        for item in items {
                            self.batchItemDone(item: item, shouldRetry: true)
                        }
                    }
                }

                // If cancelled by cancelAllInFlight(), counters are already reset to 0.
                guard !Task.isCancelled else { return }

                activeBatchCount -= 1
                let remaining = (self.folderActiveBatches[key.folderPath] ?? 1) - 1
                if remaining <= 0 {
                    self.folderActiveBatches.removeValue(forKey: key.folderPath)
                } else {
                    self.folderActiveBatches[key.folderPath] = remaining
                }

                // Power-aware inter-batch delay (turbo=0s, normal=3s, low=10s)
                let delay = await BackfillProfile.current().interCycleActiveDelay
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }

                if storage.pendingCount > 0 {
                    scheduleDispatch()
                } else if storage.isEmpty && activeBatchCount == 0 {
                    // Drain-time safety net: re-query GRDB for anything missed
                    // by the push path (headerComplete=1 set but enqueue lost,
                    // crash between DB write and enqueue, etc.). Only when this
                    // returns zero rows is the queue truly idle.
                    await self.repopulateOnDrain()
                }
            }
            batchTasks.removeAll { $0.isCancelled }
            batchTasks.append(batchTask)
        }
    }

    private func batchItemDone(item: Item, shouldRetry: Bool) {
        _ = storage.batchItemCompleted(item, shouldRetry: shouldRetry, maxRetries: SyncConfig.maxQueueRetries)
    }

    /// Handle items that the IMAP batch fetch did NOT return (UID not in result dict,
    /// as opposed to returning an empty body). Increments each row's `missFetchCount`
    /// inside a single write transaction. After `backfillBodyMissThreshold` consecutive
    /// misses the message is treated as confirmed-gone from the server — matches the
    /// REST-provider 404 semantics — and deleted via the same helper used by the
    /// PendingOperation drain.
    ///
    /// Success path (fetch returns a body) resets `missFetchCount` to 0, so a
    /// transient blip followed by recovery won't accidentally delete the header.
    /// Outcome of the pre-delete "is the message actually gone?" check at threshold.
    enum GoneConfirmation {
        /// Server confirmed the message is gone. Safe to delete the local header.
        case gone
        /// Message still exists under a different identifier (e.g. IMAP UID remap
        /// after UIDVALIDITY change). Do NOT delete — full-sync will realign.
        case stillExists
        /// Could not verify (no rfc822MessageId on file, or SEARCH failed). Do NOT
        /// delete. Defer the decision to the next cycle or to full-sync.
        case cannotConfirm
    }

    /// Exposed as `internal` (not private) so tests can verify the full wiring:
    /// counter increment, threshold partitioning, and per-branch action
    /// (delete on `.gone`, reset-counter on `.stillExists`, keep-as-is on
    /// `.cannotConfirm`).
    func handleMissedItems(_ missedItems: [Item], provider: any EmailProvider) async {
        let threshold = SyncConfig.backfillBodyMissThreshold
        let partitioned: (toDelete: [Item], toRetry: [Item])
        do {
            partitioned = try await dbPool.write { db -> (toDelete: [Item], toRetry: [Item]) in
                var toDelete: [Item] = []
                var toRetry: [Item] = []
                for item in missedItems {
                    let newCount = (try Int.fetchOne(
                        db,
                        sql: "SELECT missFetchCount FROM messageHeader WHERE id = ?",
                        arguments: [item.headerId]
                    ) ?? 0) + 1
                    try db.execute(
                        sql: "UPDATE messageHeader SET missFetchCount = ? WHERE id = ?",
                        arguments: [newCount, item.headerId]
                    )
                    if newCount >= threshold {
                        toDelete.append(item)
                    } else {
                        toRetry.append(item)
                    }
                }
                return (toDelete, toRetry)
            }
        } catch {
            print("[BackfillBody] missFetchCount update failed: \(error) — treating all as retry")
            for item in missedItems { self.batchItemDone(item: item, shouldRetry: true) }
            return
        }

        for item in partitioned.toRetry {
            print("[BackfillBody] UID miss \(item.messageId) folder=\(item.folderPath) — retrying")
            self.batchItemDone(item: item, shouldRetry: true)
        }
        for item in partitioned.toDelete {
            // At threshold, confirm before deleting. For Gmail/Exchange the batch-miss
            // is already authoritative (post-fix fetchMessagesBatch only omits 404s).
            // For IMAP we need to distinguish "UIDVALIDITY remap" from "genuinely gone"
            // via rfc822MessageId SEARCH — same confirmation full-sync uses.
            let confirmation = await self.confirmGoneAtThreshold(item: item, provider: provider)
            switch confirmation {
            case .gone:
                print("[BackfillBody] CONFIRMED GONE \(item.messageId) folder=\(item.folderPath) — deleting header")
                await AccountManager.shared.deleteConfirmedGoneHeader(
                    headerId: item.headerId,
                    reason: "backfill miss>=\(threshold)"
                )
                self.batchItemDone(item: item, shouldRetry: false)
            case .stillExists:
                print("[BackfillBody] Threshold reached but rfc822 FOUND \(item.messageId) in \(item.folderPath) — UID remap, resetting counter (full-sync will realign)")
                try? await dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE messageHeader SET missFetchCount = 0 WHERE id = ?",
                        arguments: [item.headerId]
                    )
                }
                self.batchItemDone(item: item, shouldRetry: true)
            case .cannotConfirm:
                print("[BackfillBody] Threshold reached for \(item.messageId) but cannot confirm gone — keeping for retry / full-sync")
                self.batchItemDone(item: item, shouldRetry: true)
            }
        }
    }

    /// Pre-delete confirmation. REST providers (Gmail/Exchange) already produced a
    /// clean 404 signal via fetchMessagesBatch's per-ID error classification, so
    /// `missing from result` is authoritative and we short-circuit to `.gone`.
    /// For providers that conform to `MessageExistenceProbe` (IMAP in production),
    /// look up `rfc822MessageId` and SEARCH the folder. Mirrors the full-sync
    /// UID-remap detection path (SyncEngineFullSync.swift:418+).
    ///
    /// Exposed as `internal` (not private) so tests can drive it with a mock
    /// conforming to `MessageExistenceProbe` — the actor-private dispatch pipeline
    /// needs too much scaffolding to exercise the classification directly.
    func confirmGoneAtThreshold(item: Item, provider: any EmailProvider) async -> GoneConfirmation {
        guard let prober = provider as? any MessageExistenceProbe else {
            return .gone
        }
        let rfc822: String?
        do {
            rfc822 = try await dbPool.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT rfc822MessageId FROM messageHeader WHERE id = ?",
                    arguments: [item.headerId]
                )
            }
        } catch {
            print("[BackfillBody] confirmGone: rfc822 lookup failed for \(item.headerId): \(error)")
            return .cannotConfirm
        }
        guard let rfc822 = rfc822, !rfc822.isEmpty else {
            print("[BackfillBody] confirmGone: \(item.messageId) has no rfc822MessageId — cannot confirm")
            return .cannotConfirm
        }
        do {
            let exists = try await prober.messageExistsInFolder(rfc822MessageId: rfc822, folderPath: item.folderPath)
            return exists ? .stillExists : .gone
        } catch {
            print("[BackfillBody] confirmGone: existence probe failed for \(rfc822): \(error)")
            return .cannotConfirm
        }
    }

    /// Drain-time self-repopulate: re-run the work-remaining query and enqueue any
    /// hits. Called only when `storage.isEmpty && activeBatchCount == 0`, so no
    /// in-flight overlap. `QueueStorage.enqueue` dedups against `enqueued`
    /// (already contains any in-flight items) as a safety net.
    /// Mirrors `ActiveBodyQueue.repopulateOnDrain` — same pattern, different scope
    /// (non-inbox instead of inbox).
    private func repopulateOnDrain() async {
        do {
            let items: [Item] = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, accountId, folderPath, messageId, isInInbox
                    FROM messageHeader
                    WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 0
                    ORDER BY date DESC
                    """)
                .map { row in
                    Item(
                        headerId: row["id"],
                        accountId: row["accountId"],
                        folderPath: row["folderPath"],
                        messageId: row["messageId"],
                        isInInbox: row["isInInbox"]
                    )
                }
            }
            guard !items.isEmpty else { return }
            var added = 0
            for item in items {
                if storage.enqueue(item) { added += 1 }
            }
            if added > 0 {
                print("[BackfillBody] Drain-time self-repopulate enqueued \(added) items")
                scheduleDispatch()
            }
        } catch {
            print("[BackfillBody] Drain-time repopulate failed: \(error)")
        }
    }
}
