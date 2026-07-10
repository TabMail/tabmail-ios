/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Forward/UX body-fetch queue for inbox messages (delta/full sync new messages).
/// Uses shared BodyFetchProcessor: full message fetch → render → FTS → flags → AI.
/// Runs at full speed (no power-aware delay) — this is the user-facing queue.
///
/// Batched dispatch: groups items by (account, folder), batch-fetches from provider
/// (single IMAP SELECT + bulk BODYSTRUCTURE), processes all results, writes FTS in one batch.
actor ActiveBodyQueue {
    static let shared = ActiveBodyQueue()

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
    private var folderMaxBatch: [String: Int] = [:]
    /// Per-folder active batch count. Max 2 per folder (1 running + 1 queued).
    private var folderActiveBatches: [String: Int] = [:]
    private let maxBatchesPerFolder = 2

    // .normal-tier (ADR-IOS-056): higher than deep backfill (.background) but
    // below the merge/user-action/badge tier (.priority) — this queue drains
    // NEWLY-synced inbox mail during the boot/push herd, which is sync-level
    // work, not a privileged phase. The shared `BodyFetchProcessor` is tagged
    // separately at its call sites below via `PriorityGate.normal` (mirrors
    // `BackfillBodyQueue`'s `.background` wrap — it's also used by the priority
    // on-demand fetch, so it can't be blanket-tagged). A privileged merge
    // context still wins regardless of this tag — `PrioritizedDatabase.
    // effectivePriority` checks `inPrivilegedContext` before any override.
    private var dbPool: PrioritizedDatabase { AppDatabase.syncPool }

    /// Test-only seam (ADR-IOS-056): expose the write tier for pinning.
    /// Internal (not `#if DEBUG`) — same visibility as other hoisted test
    /// seams in this file set (see `NSEDataBridge.resetStageMemoForTesting`).
    var dbPoolPriorityForTesting: WritePriority { dbPool.priority }

    // MARK: - Public API

    func enqueue(header: MessageHeader) {
        let item = Item(
            headerId: header.id, accountId: header.accountId,
            folderPath: header.folderPath, messageId: header.messageId,
            isInInbox: header.isInInbox
        )
        guard storage.enqueue(item) else { return }
        scheduleDispatch()
    }

    func enqueueBatch(_ headers: [MessageHeader]) {
        var added = 0
        for header in headers {
            let item = Item(
                headerId: header.id, accountId: header.accountId,
                folderPath: header.folderPath, messageId: header.messageId,
                isInInbox: header.isInInbox
            )
            if storage.enqueue(item) { added += 1 }
        }
        guard added > 0 else { return }
        print("[ActiveBody] Enqueued \(added) items (total: \(storage.count))")
        scheduleDispatch()
    }

    func repopulateFromDatabase() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let items: [Item] = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, accountId, folderPath, messageId, isInInbox
                    FROM messageHeader
                    WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 1
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
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            guard !items.isEmpty else {
                print("[ActiveBody] Repopulate: 0 inbox messages need body fetch (\(ms)ms)")
                return
            }
            var added = 0
            for item in items {
                if storage.enqueue(item) { added += 1 }
            }
            if added > 0 {
                print("[ActiveBody] Repopulated \(added) inbox items in \(ms)ms")
                scheduleDispatch()
            }
        } catch {
            print("[ActiveBody] Repopulate failed: \(error)")
        }
    }

    func cancelAllInFlight() {
        let itemCount = storage.inFlight.count
        storage.cancelAllInFlight()
        // Cancel actual batch Tasks — frees dead IMAP connections from previous cycles.
        let taskCount = batchTasks.count
        for task in batchTasks { task.cancel() }
        batchTasks.removeAll()
        // Reset counters — cancelled Tasks won't decrement (they check Task.isCancelled).
        activeBatchCount = 0
        folderActiveBatches.removeAll()
        debounceTask?.cancel()
        debounceTask = nil
        connectivityWatchTask?.cancel()
        connectivityWatchTask = nil
        if itemCount > 0 || taskCount > 0 {
            print("[ActiveBody] Cancelled \(taskCount) batch tasks, \(itemCount) in-flight items")
        }
    }

    var isIdle: Bool {
        storage.isEmpty && activeBatchCount == 0
    }

    /// Whether a message is queued or in-flight for body fetch.
    /// Used by on-demand fetchBody to avoid competing with the background queue.
    func isQueuedOrInFlight(headerId: String) -> Bool {
        storage.enqueued.contains { $0.headerId == headerId }
    }

    func awaitDrain() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        var lastHeartbeat = t0
        while !storage.isEmpty || activeBatchCount > 0 {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(200))
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastHeartbeat >= 5.0 {
                let elapsed = Int(now - t0)
                BackgroundSyncLogger.logBGProcessing("ActiveBodyQueue draining... (depth=\(storage.count), batches=\(activeBatchCount), elapsed=\(elapsed)s)")
                lastHeartbeat = now
            }
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
        guard !batch.isEmpty else { return }

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
        print("[ActiveBody] Dispatching \(dispatchCount) items in \(groupsToDispatch.count) folder groups (deferred=\(deferredCount), activeBatches=\(activeBatchCount))")

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
                print("[ActiveBody] Batch START: \(itemCount) items in \(key.folderPath)")

                do {
                    // 1. Batch fetch from provider (single SELECT + bulk BODYSTRUCTURE for IMAP)
                    let tFetch = CFAbsoluteTimeGetCurrent()
                    let fetched = try await provider.fetchMessagesBatch(
                        ids: items.map(\.messageId), folder: key.folderPath
                    )
                    let fetchMs = Int((CFAbsoluteTimeGetCurrent() - tFetch) * 1000)
                    print("[ActiveBody] Batch FETCH: \(fetched.count)/\(itemCount) succeeded in \(fetchMs)ms")

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
                                        // .normal-tagged (ADR-IOS-056): `BodyFetchProcessor` is
                                        // shared with the on-demand / priority fetch (fetchBody,
                                        // SnippetLoader tier-2) — only THIS active queue's caller
                                        // tags it .normal so its main-pool writes beat deep
                                        // backfill but still yield to the merge/user actions.
                                        let (result, processed) = await PriorityGate.normal {
                                            await BodyFetchProcessor.process(
                                                fetchResult: fetchResult, enableAI: true
                                            )
                                        }
                                        return (item, processed, result == .retry)
                                    case .failure:
                                        return (item, nil, true)
                                    }
                                }
                            } else {
                                print("[ActiveBody] Item \(item.messageId) not in batch result — will retry")
                            }
                        }
                        var collected: [BodyFetchProcessor.ProcessedItem] = []
                        for await (item, processed, shouldRetry) in group {
                            if let processed { collected.append(processed) }
                            self.batchItemDone(item: item, shouldRetry: shouldRetry)
                        }
                        return collected
                    }
                    // Handle items not in fetch result — same miss-count + confirm-gone
                    // machinery as BackfillBodyQueue. Inbox rows count toward
                    // pendingBodyCount too; a plain retry here let a dead UID
                    // (remap / deletion outside the sync window) cycle forever.
                    let missedItems = items.filter { fetched[$0.messageId] == nil }
                    if !missedItems.isEmpty {
                        await self.handleMissedItems(missedItems, provider: provider)
                    }
                    let processMs = Int((CFAbsoluteTimeGetCurrent() - tProcess) * 1000)

                    // 3. Write ALL to FTS + update headers in one batch.
                    // .normal-tagged (ADR-IOS-056) — see the process() call above.
                    if !processedItems.isEmpty {
                        await PriorityGate.normal {
                            await BodyFetchProcessor.flushBatch(processedItems, enableAI: true)
                        }
                    }

                    let totalMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    print("[ActiveBody] Batch DONE: \(itemCount) items (\(processedItems.count) with body) in \(totalMs)ms (fetch=\(fetchMs)ms, process=\(processMs)ms)")

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
                            print("[ActiveBody] Single item too large for \(key.folderPath) — marking bodyEmptyConfirmed")
                            for item in items {
                                // .normal-tier (ADR-IOS-056) — same tag as this queue's dbPool.
                                try? await AppDatabase.syncPool.write { db in
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
                            print("[ActiveBody] PayloadTooLarge for \(key.folderPath) — halving batch to \(halved)")
                            for item in items {
                                self.batchItemDone(item: item, shouldRetry: true)
                            }
                        }
                    } else {
                        // Connection-level error — retry all items
                        print("[ActiveBody] Batch FAILED for \(key.folderPath): \(error)")
                        for item in items {
                            self.batchItemDone(item: item, shouldRetry: true)
                        }
                    }
                }

                // If cancelled by cancelAllInFlight(), counters are already reset to 0.
                // Skip decrement to avoid negative counts.
                guard !Task.isCancelled else { return }

                activeBatchCount -= 1
                let remaining = (self.folderActiveBatches[key.folderPath] ?? 1) - 1
                if remaining <= 0 {
                    self.folderActiveBatches.removeValue(forKey: key.folderPath)
                } else {
                    self.folderActiveBatches[key.folderPath] = remaining
                }
                notifyActiveStateIfNeeded()

                if storage.pendingCount > 0 {
                    scheduleDispatch()
                } else if storage.isEmpty && activeBatchCount == 0 {
                    // Drain-time safety net: re-query GRDB for anything missed
                    // by the push path (headerComplete=1 set but enqueue lost,
                    // body queue cancelled mid-fetch, etc.). Only when this
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

    /// Missed-UID handling for inbox items — the same counter / confirm-gone /
    /// re-key wiring as `BackfillBodyQueue.handleMissedItems`, applied to THIS
    /// queue's storage. Classification (`confirmGoneAtThreshold`) and the UID
    /// re-key (`rekeyRemappedHeader`) are reused from `BackfillBodyQueue.shared`
    /// — both only touch the DB/FTS, never queue storage, so cross-actor reuse
    /// is safe.
    func handleMissedItems(_ missedItems: [Item], provider: any EmailProvider) async {
        let threshold = SyncConfig.backfillBodyMissThreshold
        let partitioned: (toConfirm: [Item], toRetry: [Item])
        do {
            partitioned = try await dbPool.write { db -> (toConfirm: [Item], toRetry: [Item]) in
                var toConfirm: [Item] = []
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
                        toConfirm.append(item)
                    } else {
                        toRetry.append(item)
                    }
                }
                return (toConfirm, toRetry)
            }
        } catch {
            // Idempotent fallback for ANY failure (incl. a benign ADR-IOS-041
            // suspension abort — retries next wake).
            if !error.isDatabaseSuspensionAbort {
                print("[ActiveBody] missFetchCount update failed: \(error) — treating all as retry")
            }
            for item in missedItems { self.batchItemDone(item: item, shouldRetry: true) }
            return
        }

        for item in partitioned.toRetry {
            print("[ActiveBody] UID miss \(item.messageId) folder=\(item.folderPath) — retrying")
            self.batchItemDone(item: item, shouldRetry: true)
        }
        for item in partitioned.toConfirm {
            let backfillItem = BackfillBodyQueue.Item(
                headerId: item.headerId, accountId: item.accountId,
                folderPath: item.folderPath, messageId: item.messageId,
                isInInbox: item.isInInbox
            )
            let confirmation = await BackfillBodyQueue.shared.confirmGoneAtThreshold(item: backfillItem, provider: provider)
            switch confirmation {
            case .gone:
                print("[ActiveBody] CONFIRMED GONE \(item.messageId) folder=\(item.folderPath) — deleting header")
                BackgroundSyncLogger.logBackfill("[ActiveBody] CONFIRMED GONE \(item.messageId) folder=\(item.folderPath) — deleting header")
                await AccountManager.shared.deleteConfirmedGoneHeader(
                    headerId: item.headerId,
                    reason: "activeBody miss>=\(threshold)"
                )
                self.batchItemDone(item: item, shouldRetry: false)
            case .stillExists(let newUID):
                if let newUID {
                    switch await BackfillBodyQueue.shared.rekeyRemappedHeader(item: backfillItem, newUID: newUID) {
                    case .migrated(let migrated):
                        print("[ActiveBody] UID remap re-key \(item.messageId)→\(newUID) in \(item.folderPath) — fetching under new UID")
                        BackgroundSyncLogger.logBackfill("[ActiveBody] UID remap re-key \(item.messageId)→\(newUID) folder=\(item.folderPath)")
                        self.batchItemDone(item: item, shouldRetry: false)
                        let newItem = Item(
                            headerId: migrated.headerId, accountId: migrated.accountId,
                            folderPath: migrated.folderPath, messageId: migrated.messageId,
                            isInInbox: migrated.isInInbox
                        )
                        if storage.enqueue(newItem) { scheduleDispatch() }
                    case .duplicateDropped:
                        print("[ActiveBody] UID remap \(item.messageId)→\(newUID) in \(item.folderPath) — new UID already has a row, old duplicate dropped")
                        self.batchItemDone(item: item, shouldRetry: false)
                    case .failed:
                        self.batchItemDone(item: item, shouldRetry: true)
                    }
                } else {
                    // Same UID still present on the server — the miss was transient.
                    print("[ActiveBody] Threshold reached but \(item.messageId) still at same UID in \(item.folderPath) — transient miss, resetting counter")
                    try? await dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE messageHeader SET missFetchCount = 0 WHERE id = ?",
                            arguments: [item.headerId]
                        )
                    }
                    self.batchItemDone(item: item, shouldRetry: true)
                }
            case .cannotConfirm:
                print("[ActiveBody] Threshold reached for \(item.messageId) but cannot confirm gone — keeping for retry / full-sync")
                self.batchItemDone(item: item, shouldRetry: true)
            }
        }
    }

    /// Drain-time self-repopulate: re-run the work-remaining query and enqueue any
    /// hits. Called only when `storage.isEmpty && activeBatchCount == 0`, so no
    /// in-flight overlap. `QueueStorage.enqueue` dedups against `enqueued`, which
    /// already contains any in-flight items, as an extra safety net.
    private func repopulateOnDrain() async {
        do {
            let items: [Item] = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, accountId, folderPath, messageId, isInInbox
                    FROM messageHeader
                    WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 1
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
                print("[ActiveBody] Drain-time self-repopulate enqueued \(added) items")
                scheduleDispatch()
            }
        } catch {
            print("[ActiveBody] Drain-time repopulate failed: \(error)")
        }
    }

    // MARK: - Active State Notification

    private var lastReportedActive: Bool?

    private func notifyActiveStateIfNeeded() {
        let isActive = !storage.isEmpty || activeBatchCount > 0
        guard isActive != lastReportedActive else { return }
        lastReportedActive = isActive
        Task { @MainActor in
            AccountManagerState.shared.isBodyFetchActive = isActive
        }
    }
}
