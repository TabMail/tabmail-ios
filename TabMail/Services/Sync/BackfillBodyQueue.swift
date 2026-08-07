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

    /// Per-folder batch size cap. Fixed (default `batchSize`); NO longer
    /// auto-halved/restored on PayloadTooLarge. That auto-adjust was keyed only by
    /// `folderPath` and RESTORED on ANY successful batch (incl. another account's
    /// same-named folder), so a sibling success reset it and it could not reliably
    /// slice an oversized batch down to a single item → retry-exhaust → repopulate
    /// HOT LOOP. Oversized-item isolation is now FAILURE-LOCAL via `isolationPending`
    /// below. Kept as a plain per-folder safety cap + test seam. Missing entry = use
    /// default batchSize.
    private var folderMaxBatch: [String: Int] = [:]
    /// Per-(account,folder) active batch count. Max 2 per account-folder (1 running
    /// + 1 queued). Keyed by BOTH accountId AND folderPath: separate accounts fetch
    /// over separate IMAP connections, so their same-named folders must NOT share
    /// this cap. A folderPath-only key let one account's 50-item batches perpetually
    /// hold both slots and starve ANOTHER account's isolation singleton (size-1
    /// groups sort last under the size-descending dispatch order) — which would leave
    /// a genuinely oversized message never size-tested alone, i.e. never reaching the
    /// defer.
    private struct FolderCapKey: Hashable { let accountId: String; let folderPath: String }
    private var folderActiveBatches: [FolderCapKey: Int] = [:]
    private let maxBatchesPerFolder = 2

    /// headerIds from a PayloadTooLarge batch whose `items.count > 1` — one (or a
    /// few) is oversized, but the batch error doesn't say which. Each is dispatched
    /// ALONE (a forced single-item batch, via `groupCandidatesForDispatch`) so it is
    /// size-tested in isolation INDEPENDENT of `folderMaxBatch`. A lone
    /// PayloadTooLarge then defers it (`oversizedDeferredThisSession`); a resolution
    /// drops it here. Being failure-local, a sibling success can never let an
    /// oversized item escape single-item testing. Cleared for a folder on UIDVALIDITY
    /// reset (`clearOversizedDeferred`).
    private var isolationPending: Set<String> = []

    /// Bumped by `clearOversizedDeferred` on every UIDVALIDITY reset. A batch
    /// captures this at DISPATCH (before the fetch await) and passes it to
    /// `handlePayloadTooLarge`, which skips inserting into
    /// `oversizedDeferredThisSession` / `isolationPending` if the generation changed
    /// meanwhile. Prevents a batch that started BEFORE the reset from resuming AFTER
    /// the clear and re-inserting the stale OLD-epoch headerId.
    private var resetGeneration = 0

    /// Process-lifetime set of headerIds deferred because their body overflowed the
    /// fixed NIO buffer (`PayloadTooLargeError` — size-deterministic per binary).
    ///
    /// ⚑ THIS IS A BOUNDED, VISIBLE, RETRYABLE QUARANTINE — NOT A DISCARD. The DB
    /// row is left honestly `bodyComplete = 0 / bodyEmptyConfirmed = 0`, so it stays
    /// in every work-remaining query, stays visible to `StuckMessageDiagnostics`, and
    /// stays fetchable by the on-demand user-open path (`BodyFetchProcessor
    /// .fetchAndProcess`, which never consults this set). Only the BACKGROUND
    /// pre-fetch is suppressed, and only until one of its three releases fires:
    ///   1. process relaunch — the set starts empty, so a new binary (whose NIO
    ///      buffer may be larger) gets one fresh attempt per item;
    ///   2. a UIDVALIDITY reset for the folder — `clearOversizedDeferred`;
    ///   3. a UID remap / cross-folder move — that mints a NEW headerId which is not
    ///      in this set, so `admit` takes it.
    /// NOT cleared per drain cycle: a size-deterministic oversize cannot become
    /// fetchable mid-process, so re-attempting it every cycle is exactly the hot loop
    /// this set exists to stop. `private(set)` so tests can assert membership.
    private(set) var oversizedDeferredThisSession: Set<String> = []

    // Background-tagged: deep-backfill body writes (partition/cleanup flag flips)
    // yield to foreground/UI work. The shared `BodyFetchProcessor` is tagged
    // separately at its call sites via `PriorityGate.background` (it's also used
    // by the priority on-demand / active body fetch).
    private var dbPool: PrioritizedDatabase { AppDatabase.backgroundPool }

    /// Test-only seam: snapshot of the underlying `QueueStorage` bookkeeping so the
    /// oversized-defer tests can assert the item was removed, was NOT marked
    /// recentlyCompleted, and `activeJobs` was left untouched.
    var storageSnapshotForTesting: BodyQueueStorageSnapshot {
        BodyQueueStorageSnapshot(
            queueCount: storage.count,
            enqueuedCount: storage.enqueued.count,
            recentlyCompletedCount: storage.recentlyCompleted.count,
            activeJobs: storage.activeJobs
        )
    }

    /// Test-only seam: the items currently held by the queue, so a convergence test
    /// can drive its passes off the REAL queue contents rather than a model of them.
    var queuedItemsForTesting: [Item] { storage.queue }

    /// Test-only seam: pre-set the per-folder batch cap so the disposition tests can
    /// pin that the defer decision keys on THIS batch's `items.count` and NOT on the
    /// shared cap.
    func setFolderMaxBatchForTesting(_ n: Int, folderPath: String) {
        folderMaxBatch[folderPath] = n
    }

    /// Test-only seam: the isolation-pending set — items from a multi-item
    /// PayloadTooLarge awaiting single-item testing.
    var isolationPendingForTesting: Set<String> { isolationPending }

    /// Test-only seam: the current reset generation (what a batch captures at dispatch).
    var resetGenerationForTesting: Int { resetGeneration }

    /// Test-only seam: drive an item's batch-completion disposition without the live
    /// network/provider scaffolding the full dispatch path needs.
    func completeItemForTesting(_ item: Item, shouldRetry: Bool) {
        batchItemDone(item: item, shouldRetry: shouldRetry)
    }

    /// Test-only seam: mirror ONE real batch dispatch's effect on the
    /// per-(account,folder) cap counter, through the SAME `FolderCapKey` the live
    /// dispatch path uses.
    func noteFolderBatchDispatchedForTesting(accountId: String, folderPath: String) {
        folderActiveBatches[FolderCapKey(accountId: accountId, folderPath: folderPath), default: 0] += 1
    }

    /// Test-only seam: read the per-(account,folder) active-batch count via the SAME
    /// `FolderCapKey` the cap guard uses.
    func folderActiveBatchCountForTesting(accountId: String, folderPath: String) -> Int {
        folderActiveBatches[FolderCapKey(accountId: accountId, folderPath: folderPath)] ?? 0
    }

    // MARK: - Public API

    /// Guarded admission — the SINGLE gate every enqueue site in this actor routes
    /// through. Predicate, comments excluded so this sentence cannot satisfy it
    /// (R16-7): `rg -n --pcre2 '^(?!\s*(///|//)).*(func admit|admit\()'
    /// TabMail/Services/Sync/BackfillBodyQueue.swift` → **6** lines = this
    /// definition plus **5** enqueue sites. Same warning as the identical gate in
    /// `ActiveBodyQueue`: a new enqueue path that skips `admit` re-admits a
    /// deferred oversized item for the whole process lifetime.
    ///
    /// The gate itself: skip a headerId already deferred as oversized so a deferred item is
    /// never re-admitted this process lifetime. The repopulate/drain SELECTs still
    /// return the row (`bodyComplete = 0 / bodyEmptyConfirmed = 0` is truthfully
    /// retryable — the row is NOT lied about), but this gate keeps it out of the
    /// queue, which is what stops the repopulate → dispatch → overflow → repopulate
    /// hot loop. Returns true iff the item was actually enqueued.
    @discardableResult
    func admit(_ item: Item) -> Bool {
        guard !oversizedDeferredThisSession.contains(item.headerId) else { return false }
        return storage.enqueue(item)
    }

    /// Drop every oversized-deferred / isolation-pending key belonging to
    /// (accountId, folderPath). Called by the UIDVALIDITY reset reaction after it
    /// purges + resyncs the folder.
    ///
    /// ⚠ WITHOUT THIS THE QUARANTINE BECOMES A PERMANENT DISCARD BY ANOTHER NAME.
    /// Both sets key by headerId = `accountId:folderPath:UID`, a mutable ADDRESS,
    /// not an identity. A UIDVALIDITY reset renumbers the mailbox, so the resync
    /// re-inserts fresh-epoch rows that MAY reuse a deferred header's UID; a stale
    /// key would make `admit()` reject a message that was never oversized, starving
    /// it of its body until relaunch. Colon-hierarchy safe via
    /// `MessageIdentity.headerIdBelongsToFolder`.
    func clearOversizedDeferred(accountId: String, folderPath: String) {
        // Bump FIRST (the generation guard): any in-flight batch that captured the
        // pre-reset generation and resumes after this clear will skip its stale
        // insert instead of re-populating the just-cleared sets.
        resetGeneration &+= 1
        let before = oversizedDeferredThisSession.count + isolationPending.count
        oversizedDeferredThisSession = oversizedDeferredThisSession.filter {
            !MessageIdentity.headerIdBelongsToFolder($0, accountId: accountId, folderPath: folderPath)
        }
        isolationPending = isolationPending.filter {
            !MessageIdentity.headerIdBelongsToFolder($0, accountId: accountId, folderPath: folderPath)
        }
        let removed = before - (oversizedDeferredThisSession.count + isolationPending.count)
        if removed > 0, DebugModeManager.isLoggingEnabled() {
            print("[BackfillBody] Cleared \(removed) oversized-deferred/isolation key(s) for \(folderPath) after UIDVALIDITY reset")
        }
    }

    /// Dispatch grouping key. `isolationHeaderId` is non-nil only for a forced
    /// single-item ISOLATION batch — its headerId makes the group unique so it never
    /// coalesces with the folder's normal batch or another isolation item.
    struct GroupKey: Hashable {
        let accountId: String
        let folderPath: String
        let isolationHeaderId: String?
    }

    /// Group dispatchable candidates. An item whose headerId is in
    /// `isolationPending` gets a UNIQUE key (its headerId) so it forms a single-item
    /// batch tested ALONE — independent of `folderMaxBatch`. Ordinary items coalesce
    /// per (account, folder). Pure, so the isolation invariant is assertable without
    /// the live-network dispatch scaffolding.
    static func groupCandidatesForDispatch(
        _ candidates: [Item], isolationPending: Set<String>
    ) -> [GroupKey: [Item]] {
        var groups: [GroupKey: [Item]] = [:]
        for item in candidates {
            let key = GroupKey(
                accountId: item.accountId,
                folderPath: item.folderPath,
                isolationHeaderId: isolationPending.contains(item.headerId) ? item.headerId : nil
            )
            groups[key, default: []].append(item)
        }
        return groups
    }

    func enqueue(_ items: [Item]) {
        var added = 0
        for item in items {
            if admit(item) { added += 1 }
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
            if admit(item) { added += 1 }
        }
        guard added > 0 else { return }
        print("[BackfillBody] Enqueued \(added) backfill items (total: \(storage.count))")
        scheduleDispatch()
    }

    func enqueueSingle(_ item: Item) {
        guard admit(item) else { return }
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
                if admit(item) { totalAdded += 1 }
            }

            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if totalAdded > 0 {
                print("[BackfillBody] Repopulated \(totalAdded) items in \(ms)ms")
            } else {
                print("[BackfillBody] Repopulate: 0 non-inbox messages need body fetch (\(ms)ms)")
            }
            BackgroundSyncLogger.logBackfill("[BackfillBody] repopulate loaded=\(totalAdded) pending=\(storage.pendingCount) (\(ms)ms)")
            // Re-kick on every wake. `totalAdded` counts only NEW rows; items left
            // pending by a suspend-abandoned cycle (ADR-IOS-046) are already
            // enqueued, so they'd be dropped from `totalAdded` and never
            // re-dispatched. Dispatching whenever ANY work remains guarantees the
            // queue resumes on the next wake. scheduleDispatch is idempotent/guarded.
            if storage.pendingCount > 0 { scheduleDispatch() }
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

        // ADR-IOS-046: if the GRDB pool is suspended (app backgrounded past its
        // grace window), ABANDON — don't fetch bodies we can't persist. Every
        // write would abort (SQLITE_ABORT); the work is idempotent and
        // re-dispatches on the next wake via repopulateFromDatabase. We do NOT
        // hold a lease to keep going — that would keep the pool write-capable into
        // the freeze (0xdead10cc). Items stay pending (not yet collected), so
        // nothing is lost. Just stop.
        guard !DatabaseSuspension.isSuspended else {
            #if DEBUG
            print("[BackfillBody] DB suspended — abandoning dispatch (ADR-IOS-046)")
            #endif
            return
        }

        // PAUSE THE WHOLE BATCH while a privileged merge holds the gate — the
        // body fetch + render (CPU) + FTS write should all step aside for a
        // foreground NSE→inbox merge, not just the individual GRDB writes.
        // No-op when nothing privileged is active.
        await PriorityGate.shared.yield("backfill-body")

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

        // Filter to dispatchable candidates (provider present, folder under its
        // batch cap), then group. Isolation-pending items each form their OWN
        // single-item group via `groupCandidatesForDispatch`; ordinary items
        // coalesce per (account, folder). Folders already at max batches (1 running
        // + 1 queued) go back to pending.
        var dispatchable: [Item] = []
        for item in batch {
            guard providerByAccount[item.accountId] != nil else {
                storage.releaseInFlightOnly(item)
                continue
            }
            let active = folderActiveBatches[FolderCapKey(accountId: item.accountId, folderPath: item.folderPath)] ?? 0
            guard active < maxBatchesPerFolder else {
                storage.releaseInFlightOnly(item)
                continue
            }
            dispatchable.append(item)
        }
        let groups = Self.groupCandidatesForDispatch(dispatchable, isolationPending: isolationPending)

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

            // Enforce the per-folder batch cap ACROSS the groups dispatched in THIS
            // cycle too — isolation singletons can now yield multiple groups for one
            // folder per cycle (1 normal + N single-item isolation batches); the
            // grouping guard above only saw the pre-cycle folderActiveBatches count.
            let capKey = FolderCapKey(accountId: key.accountId, folderPath: key.folderPath)
            guard (folderActiveBatches[capKey] ?? 0) < maxBatchesPerFolder else {
                for item in allItems { storage.releaseInFlightOnly(item) }
                continue
            }

            // Cap folder group by the fixed per-folder batch limit (default batchSize).
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
            // Generation guard: capture at DISPATCH (before the fetch await) so
            // handlePayloadTooLarge can detect a UIDVALIDITY reset that lands during
            // this batch's fetch window and skip re-populating the just-cleared sets.
            let capturedResetGeneration = resetGeneration
            activeBatchCount += 1
            folderActiveBatches[capKey, default: 0] += 1

            let batchTask = Task { [self] in
                let t0 = CFAbsoluteTimeGetCurrent()
                print("[BackfillBody] Batch START: \(itemCount) items in \(key.folderPath)")
                // Boot-log mirror (debug-gated): backfill batch windows must be
                // correlatable against ⚠ MAIN THREAD STALL marks in ONE file —
                // the "app is sharp once backfill dies" hypothesis needs the
                // batch boundaries in the downloadable boot log, not just the console.
                BootProfiler.mark("backfillBody batch START \(itemCount) items [\(key.folderPath)]")

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
                                        // Background-tagged: `BodyFetchProcessor` is
                                        // shared with the on-demand / active body
                                        // fetch (priority) — only the backfill caller
                                        // wraps it so ITS main-pool writes yield to UI.
                                        let (result, processed) = await PriorityGate.background {
                                            await BodyFetchProcessor.process(
                                                fetchResult: fetchResult, enableAI: false
                                            )
                                        }
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

                    // 3. Write ALL to FTS + update headers in one batch.
                    // Yield to a privileged merge before the write: the FTS write
                    // (SearchIndex) is a SEPARATE pool the `dbPool` wrapper can't
                    // gate, and SearchIndex's writes are sync (`@noasync` — can't be
                    // gated inside the actor), so the async background CALLER yields.
                    if !processedItems.isEmpty {
                        await PriorityGate.shared.yield("backfill-body-write")
                        // Background-tagged so flushBatch's main-pool flag writes
                        // (bodyComplete) yield to UI; the explicit yield above
                        // covers the separate SearchIndex (FTS) sidecar pool.
                        await PriorityGate.background {
                            await BodyFetchProcessor.flushBatch(processedItems, enableAI: false)
                        }
                    }

                    let totalMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    print("[BackfillBody] Batch DONE: \(itemCount) items (\(processedItems.count) with body) in \(totalMs)ms (fetch=\(fetchMs)ms, process=\(processMs)ms)")
                    BootProfiler.mark("backfillBody batch DONE \(itemCount) items in \(totalMs)ms (fetch=\(fetchMs)ms process=\(processMs)ms) [\(key.folderPath)]")
                    BackgroundSyncLogger.logBackfill("[BackfillBody] batch DONE \(itemCount) items (\(processedItems.count) with body, \(missedItems.count) missed) in \(totalMs)ms [\(key.folderPath)] pending=\(storage.pendingCount)")
                    await SyncEngine.checkpointWALThrottled()

                } catch {
                    let desc = "\(error)"
                    if desc.contains("PayloadTooLargeError") {
                        // Defer a genuinely single oversized item WITHOUT marking it
                        // empty; a multi-item batch isolates its members so a later
                        // dispatch slices each one singly. Keys on THIS batch's actual
                        // `items.count`, NOT the shared folderMaxBatch cap.
                        self.handlePayloadTooLarge(
                            items: items, folderPath: key.folderPath,
                            capturedGeneration: capturedResetGeneration
                        )
                    } else {
                        // Connection-level error — retry all items
                        print("[BackfillBody] Batch FAILED for \(key.folderPath): \(error)")
                        // Boot-log mirror: the user-observed "backfill jobs die
                        // after a while" needs its death timestamped next to the
                        // stall marks. Error text deliberately not included
                        // (console print above has it).
                        BootProfiler.mark("backfillBody batch FAILED [\(key.folderPath)] — items retried")
                        BackgroundSyncLogger.logBackfill("[BackfillBody] batch FAILED [\(key.folderPath)] \(itemCount) items retried: \(error)")
                        for item in items {
                            self.batchItemDone(item: item, shouldRetry: true)
                        }
                    }
                }

                // If cancelled by cancelAllInFlight(), counters are already reset to 0.
                guard !Task.isCancelled else { return }

                activeBatchCount -= 1
                let remaining = (self.folderActiveBatches[capKey] ?? 1) - 1
                if remaining <= 0 {
                    self.folderActiveBatches.removeValue(forKey: capKey)
                } else {
                    self.folderActiveBatches[capKey] = remaining
                }

                // Power-aware inter-batch delay (turbo=0s, normal=3s, low=10s)
                let delay = await BackfillProfile.current().interCycleActiveDelay
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }

                if storage.pendingCount > 0 {
                    scheduleDispatch()
                } else if storage.isEmpty && activeBatchCount == 0 {
                    // Boot-log mirror: queue went IDLE — if the user-felt "sharp
                    // again" moments line up with this mark (and stall marks stop
                    // after it), the backfill-contention hypothesis is confirmed.
                    BootProfiler.mark("backfillBody queue IDLE (drained) — running drain-time repopulate check")
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
        // An item that RESOLVES (shouldRetry=false — fetched OK, confirmed gone,
        // re-keyed, or retry-exhausted) is no longer an oversize suspect; drop it
        // from isolation. Set.remove is a no-op for non-members.
        if !shouldRetry { isolationPending.remove(item.headerId) }
        _ = storage.batchItemCompleted(item, shouldRetry: shouldRetry, maxRetries: SyncConfig.maxQueueRetries)
    }

    /// PayloadTooLarge disposition. Factored out of `dispatchBatch`'s catch so the
    /// defer/isolate decision is directly testable. Runs SYNCHRONOUSLY on the actor
    /// — there is deliberately no `await` anywhere in it, so no producer can slip an
    /// enqueue in between the set insert and the queue removal.
    ///
    ///  - `items.count == 1` (a genuinely isolated oversized message): DEFER without
    ///    completion. `PayloadTooLargeError` is size-deterministic (the NIO buffer is
    ///    fixed per binary), so it cannot become fetchable this process lifetime.
    ///    Insert the headerId into the process-lifetime
    ///    `oversizedDeferredThisSession` set, then `storage.removeFromQueue`
    ///    DIRECTLY. We do NOT mark `bodyEmptyConfirmed` (Data Integrity rule 1: an
    ///    oversized body is the OPPOSITE of "content confirmed gone" — the body
    ///    demonstrably exists, it merely did not fit — so the row stays honestly
    ///    incomplete and retryable, just out of the background queue until one of the
    ///    three releases documented on `oversizedDeferredThisSession` fires), do NOT
    ///    set `recentlyCompleted`, and do NOT call `abandonWithoutCompletion` (it
    ///    decrements `activeJobs`, which this queue never uses — it tracks
    ///    `activeBatchCount`). The batch counter still decrements once in the
    ///    dispatch task below.
    ///  - `items.count > 1`: mark every item ISOLATION-PENDING and retry it — a later
    ///    dispatch tests each ALONE (a forced single-item batch, via
    ///    `groupCandidatesForDispatch`), INDEPENDENT of `folderMaxBatch`; each
    ///    genuinely oversized single then defers here, ordinary siblings fetch
    ///    normally. Failure-local, so a sibling success can never undo the isolation.
    func handlePayloadTooLarge(items: [Item], folderPath: String, capturedGeneration: Int? = nil) {
        // Generation guard: a UIDVALIDITY reset landed during this batch's fetch
        // window (`clearOversizedDeferred` bumped `resetGeneration` and already
        // cleared the sets). The items in hand are OLD-epoch; re-adding their
        // headerIds would UNDO the clear and starve a new-epoch message reusing the
        // UID. Skip BOTH set inserts and just release the items retryable.
        // `capturedGeneration == nil` = a direct/test call with no reset-guard
        // context → never stale.
        let stale = capturedGeneration.map { $0 != resetGeneration } ?? false
        if items.count == 1 {
            let item = items[0]
            if stale {
                if DebugModeManager.isLoggingEnabled() {
                    print("[BackfillBody] Oversized single item in \(folderPath) raced a UIDVALIDITY reset — NOT deferring stale \(item.headerId.prefix(30)); retrying")
                }
                batchItemDone(item: item, shouldRetry: true)
                return
            }
            if DebugModeManager.isLoggingEnabled() {
                print("[BackfillBody] Single item too large in \(folderPath) — deferring \(item.headerId.prefix(30)) in-memory (bodyComplete=0, NOT marked empty)")
            }
            BackgroundSyncLogger.logBackfill("[BackfillBody] oversized single item in \(folderPath) — deferring \(item.headerId.prefix(30)) in-memory (bodyComplete=0, NOT marked empty)")
            oversizedDeferredThisSession.insert(item.headerId)
            isolationPending.remove(item.headerId)   // resolved as the oversized one
            storage.removeFromQueue(item)
        } else {
            // One (or a few) of these is oversized, but the batch error doesn't say
            // which. Isolate each so a later dispatch tests it ALONE — reaching the
            // items.count==1 defer above regardless of any sibling success. Insert
            // BEFORE batchItemDone (shouldRetry=true won't clear it). Skip the insert
            // when stale — same reasoning as the single path.
            for item in items {
                if !stale { isolationPending.insert(item.headerId) }
                batchItemDone(item: item, shouldRetry: true)
            }
            if DebugModeManager.isLoggingEnabled() {
                if stale {
                    print("[BackfillBody] PayloadTooLarge for \(folderPath) raced a UIDVALIDITY reset — NOT isolating \(items.count) stale items; retrying")
                } else {
                    print("[BackfillBody] PayloadTooLarge for \(folderPath) — isolating \(items.count) items for single-item testing")
                }
            }
        }
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
    enum GoneConfirmation: Equatable {
        /// Server confirmed the message is gone. Safe to delete the local header.
        case gone
        /// Message still exists in the folder. `newUID` carries the server's
        /// current UID when it differs from the stored one (IMAP UID remap after
        /// UIDVALIDITY change / cross-client move) — the caller re-keys the header
        /// in place. nil = the stored UID itself is still present (transient fetch
        /// miss) — reset the counter and retry.
        case stillExists(newUID: String?)
        /// Could not verify (no rfc822MessageId on file, or SEARCH failed). Do NOT
        /// delete. Defer the decision to the next cycle or to full-sync.
        case cannotConfirm
    }

    /// Exposed as `internal` (not private) so tests can verify the full wiring:
    /// counter increment, threshold partitioning, and per-branch action
    /// (delete on `.gone`, re-key on `.stillExists(newUID:)`, reset-counter on
    /// `.stillExists(nil)`, keep-as-is on `.cannotConfirm`).
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
            // Treat-all-as-retry is the right idempotent fallback for ANY failure
            // (incl. a benign ADR-IOS-041 suspension abort — retries next wake).
            // Only the LOG is gated: a suspension abort isn't a real failure.
            if !error.isDatabaseSuspensionAbort {
                print("[BackfillBody] missFetchCount update failed: \(error) — treating all as retry")
            }
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
                BackgroundSyncLogger.logBackfill("[BackfillBody] CONFIRMED GONE \(item.messageId) folder=\(item.folderPath) — deleting header")
                await AccountManager.shared.deleteConfirmedGoneHeader(
                    headerId: item.headerId,
                    reason: "backfill miss>=\(threshold)"
                )
                self.batchItemDone(item: item, shouldRetry: false)
            case .stillExists(let newUID):
                if let newUID {
                    // UID remap: the stored UID is dead but the message lives under
                    // newUID. Re-key the header NOW — full-sync's remap window only
                    // covers recent messages, so deep-history remaps would retry the
                    // dead UID forever otherwise.
                    switch await self.rekeyRemappedHeader(item: item, newUID: newUID) {
                    case .migrated(let newItem):
                        print("[BackfillBody] UID remap re-key \(item.messageId)→\(newUID) in \(item.folderPath) — fetching under new UID")
                        BackgroundSyncLogger.logBackfill("[BackfillBody] UID remap re-key \(item.messageId)→\(newUID) folder=\(item.folderPath)")
                        self.batchItemDone(item: item, shouldRetry: false)
                        enqueueSingle(newItem)
                    case .duplicateDropped:
                        print("[BackfillBody] UID remap \(item.messageId)→\(newUID) in \(item.folderPath) — new UID already has a row, old duplicate dropped")
                        BackgroundSyncLogger.logBackfill("[BackfillBody] UID remap duplicate dropped \(item.messageId)→\(newUID) folder=\(item.folderPath)")
                        self.batchItemDone(item: item, shouldRetry: false)
                    case .failed:
                        self.batchItemDone(item: item, shouldRetry: true)
                    }
                } else {
                    // Same UID still present on the server — the miss was transient.
                    print("[BackfillBody] Threshold reached but \(item.messageId) still at same UID in \(item.folderPath) — transient miss, resetting counter")
                    try? await dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE messageHeader SET missFetchCount = 0 WHERE id = ?",
                            arguments: [item.headerId]
                        )
                    }
                    self.batchItemDone(item: item, shouldRetry: true)
                }
            case .cannotConfirm:
                print("[BackfillBody] Threshold reached for \(item.messageId) but cannot confirm gone — keeping for retry / full-sync")
                BackgroundSyncLogger.logBackfill("[BackfillBody] cannotConfirm \(item.messageId) folder=\(item.folderPath) — keeping for retry")
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
            let uids = try await prober.currentUIDs(rfc822MessageId: rfc822, folderPath: item.folderPath)
            guard !uids.isEmpty else { return .gone }
            if uids.contains(item.messageId) {
                // The stored UID itself is still on the server — the batch miss
                // was transient, not a remap.
                return .stillExists(newUID: nil)
            }
            // UID remap. When duplicates exist, the highest UID is the newest copy
            // (UIDs are monotonic per folder).
            let newUID = uids.max { (UInt32($0) ?? 0) < (UInt32($1) ?? 0) }
            return .stillExists(newUID: newUID)
        } catch {
            print("[BackfillBody] confirmGone: existence probe failed for \(rfc822): \(error)")
            return .cannotConfirm
        }
    }

    /// Outcome of re-keying a UID-remapped header to its current server UID.
    enum RekeyOutcome {
        /// Header migrated to the new UID — fetch the body under the new identity.
        case migrated(Item)
        /// The new UID already has its own header row (or the old row was already
        /// gone) — the old duplicate has been removed; nothing left to fetch under
        /// the old identity.
        case duplicateDropped
        /// DB write failed — keep the old item for retry.
        case failed
    }

    /// Re-key a header whose stored UID is dead to the server's current UID,
    /// preserving body/flags. Mirrors full-sync's UID-remap migration
    /// (SyncEngineFullSync UID remap block): delete + reinsert, then move the FTS
    /// entry IN PLACE via `SearchIndex.rekeyHeaders` (preserves the indexed body
    /// text and the embedding). Without this, a deep-history remap retries the dead
    /// UID forever — full-sync's remap window only covers recent messages, so
    /// `pendingBodyCount` never reaches 0 (the permanent "99% indexed" stall).
    ///
    /// The delete+reinsert shape originally existed because `messageBody`'s FK
    /// CASCADE forbade a PK UPDATE. Stage D (`v70_dropMessageBodyHeaderFK`) removed
    /// that FK, but the shape is deliberately KEPT here — converting it would be a
    /// behaviour change riding a schema commit, and Stage E1 reshapes this leg
    /// again. What Stage D does change is that the old body row must now be deleted
    /// EXPLICITLY, on every exit including `duplicateDropped`.
    ///
    /// 🚨 **THE DELETE+REINSERT IS NOW DELEGATED TO `MessageHeaderRekey.apply`
    /// (R16-2)**, which owns all four carrier legs. It is the same shape, not a new
    /// one — see the block comment at the call site for what the local copy was
    /// silently destroying, and `MessageHeaderRekey.apply`'s own doc for the two
    /// cascading child tables and why one is carried and the other rebuilt.
    ///
    /// Exposed as `internal` (not private) so tests can drive it directly.
    func rekeyRemappedHeader(item: Item, newUID: String) async -> RekeyOutcome {
        let newHeaderId = MessageIdentity.headerId(
            accountId: item.accountId, folderPath: item.folderPath, messageId: newUID
        )
        let outcome: RekeyOutcome
        do {
            outcome = try await dbPool.write { db -> RekeyOutcome in
                guard let header = try MessageHeader.fetchOne(db, key: item.headerId) else {
                    // Row already gone (raced with sync/prune) — nothing to migrate.
                    return .duplicateDropped
                }
                var migrated = header
                migrated.id = newHeaderId
                migrated.messageId = newUID
                migrated.missFetchCount = 0
                // This unbound body-queue re-key did not observe the replacement
                // UID beside a UIDVALIDITY. Sync must prove it before admission.
                migrated.observedUidValidity = nil
                // 🚨 R16-2 — THE CARRIER IS SHARED, NOT REIMPLEMENTED. This block
                // used to hand-roll fetch-body → delete header → delete body →
                // collision guard → insert → re-insert body. That sequence carried
                // the BODY and nothing else, so `header.delete(db)` fired
                // `ON DELETE CASCADE` on both surviving children of `messageHeader`
                // and the re-insert restored NEITHER:
                //   * `messageUserLabel` (`AppDatabase` `v82`'s create, cascade on
                //     the `messageId` FK) — every label the user applied to a
                //     deep-history message, destroyed with NO rebuild source. Nothing
                //     else in the database knows which labels the user chose.
                //   * `messageReference` (threading edges, cascade on its
                //     `messageId` FK) — rebuildable from the header's own
                //     References/In-Reply-To, but nothing rebuilt them here.
                // Both losses are PERMANENT: every production writer of
                // `MessageUserLabel` and every caller of `insertMessageReferences`
                // sits immediately after a `header.insert(db)`, so once the row
                // exists at the new id later syncs take the merge branch and never
                // re-create them.
                //
                // `MessageHeaderRekey.apply` is the sibling carrier that has always
                // done all four legs (body carry, label CARRY — there is no rebuild
                // source — reference REBUILD, and the collision guard), and it is
                // safe on BOTH legs here: it deletes the old row and its body before
                // the collision check and returns `false` WITHOUT inserting anything,
                // so a dropped duplicate's labels can never be filed onto the
                // survivor. That collision return is exactly `.duplicateDropped`.
                guard try MessageHeaderRekey.apply(from: header, to: migrated, db: db) else {
                    // The new UID was independently backfilled — old row was a duplicate.
                    return .duplicateDropped
                }
                return .migrated(Item(
                    headerId: newHeaderId, accountId: item.accountId,
                    folderPath: item.folderPath, messageId: newUID,
                    isInInbox: item.isInInbox
                ))
            }
        } catch {
            if !error.isDatabaseSuspensionAbort {
                print("[BackfillBody] UID remap re-key failed for \(item.messageId)→\(newUID): \(error)")
                BackgroundSyncLogger.logBackfill("[BackfillBody] UID remap re-key FAILED \(item.messageId)→\(newUID) folder=\(item.folderPath): \(error)")
            }
            return .failed
        }
        // Move the FTS entry to the new id IN PLACE. rekeyHeaders' collision
        // branch drops the old entry when the new id is already indexed — which
        // is exactly the duplicateDropped case.
        try? await SearchIndex.shared.rekeyHeaders([(oldKey: ContentKey(rawValue: item.headerId),
                                                     newKey: ContentKey(rawValue: newHeaderId),
                                                     newMessageId: newUID)])
        // R15-FIX-2 — THE BODY-ASSET MANIFEST IS A THIRD SQLITE POOL KEYED BY THE
        // SAME HEADER ID, so it needs the same two-phase mirror the FTS index just
        // took. This carrier had the FTS half and not this one: a half-port
        // (`MIS-018`).
        //
        // WHY IT MATTERS HERE SPECIFICALLY. The `.migrated` leg carries `oldBody`
        // forward under `newHeaderId`, and that HTML still embeds
        // `tabmail-asset://<oldHeaderId-hash>/…` URLs. Without the mirror the
        // manifest rows keep the OLD `headerId`, so the next `pruneOrphans` sweep
        // sees a key with no `messageHeader` row, judges it dead, and deletes a LIVE
        // message's cached inline images and attachments. `recoverMovedContentKey`
        // cannot save it: that recovery leg is gated `provider == .gmail || .outlook`
        // and returns nil for IMAP, which is the only family that reaches this
        // function. Nor does the replacement body fetch overwrite the carried one —
        // `BodyFetchProcessor` inserts with `onConflict: .ignore`, so the
        // carried-forward body WINS and the stale URLs survive in a body that
        // outlives its assets. `rekeyContentKey` preserves the row `id` (and so the
        // embedded URL) and re-points only `headerId`, which is why this works at
        // all.
        //
        // ⚠ THE SPLIT IS LOAD-BEARING, AND A BLANKET MIRROR IS THE MIRROR-IMAGE BUG.
        // On `.duplicateDropped` the new UID was independently backfilled and owns
        // its own assets; re-keying onto it would file two messages' attachment
        // bytes under one content key, and every later lookup at that key could
        // return the OTHER message's bytes — a content misattribution, C3-adjacent.
        // So the dropped duplicate's assets are DELETED, exactly as the sibling
        // `AccountManager.publishRekeys` disposes of its collided ids, and
        // exactly as `pruneOrphans` would dispose of them later anyway (its `dead`
        // set is "manifest key with no `messageHeader` row", which is precisely what
        // the dropped duplicate's key becomes). `rekeyContentKey` independently makes
        // the same choice if it races (`newExists` ⇒ delete the old key).
        switch outcome {
        case .migrated:
            _ = BodyAssetStore.rekeyContentKey(
                from: ContentKey(rawValue: item.headerId),
                to: ContentKey(rawValue: newHeaderId))
        case .duplicateDropped:
            _ = BodyAssetStore.deleteAllAssets(
                forContentKey: ContentKey(rawValue: item.headerId))
        case .failed:
            // Unreachable: the `catch` above returns `.failed` directly and never
            // falls through to here. Enumerated rather than defaulted so a future
            // non-throwing failure leg has to choose a disposition.
            break
        }
        return outcome
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
                if admit(item) { added += 1 }
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
