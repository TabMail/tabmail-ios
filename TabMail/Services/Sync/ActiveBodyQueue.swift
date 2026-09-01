/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Test-only snapshot of a body queue's `QueueStorage` bookkeeping, shared by
/// `ActiveBodyQueue` and `BackfillBodyQueue`.
///
/// Every field is already readable through `QueueStorage`'s `private(set)` getters;
/// this type only bundles them so a test can assert the whole disposition of one
/// oversized item at once — that it left the queue, was NOT recorded as completed,
/// and never touched `activeJobs` (which these two queues do not use — they track
/// `activeBatchCount` instead, so a stray decrement would drive it negative).
struct BodyQueueStorageSnapshot: Sendable {
    let queueCount: Int
    let enqueuedCount: Int
    let recentlyCompletedCount: Int
    let activeJobs: Int
}

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

    /// Per-folder batch size cap. Fixed (default `batchSize`); NO longer
    /// auto-halved/restored on PayloadTooLarge. That auto-adjust was keyed only by
    /// `folderPath` and RESTORED on ANY successful batch (incl. another account's
    /// INBOX), so a sibling success reset it and it could not reliably slice an
    /// oversized batch down to a single item → retry-exhaust → repopulate HOT LOOP.
    /// Oversized-item isolation is now FAILURE-LOCAL via `isolationPending` below.
    /// Kept as a plain per-folder safety cap + test seam.
    private var folderMaxBatch: [String: Int] = [:]
    /// Per-(account,folder) active batch count. Max 2 per account-folder (1
    /// running + 1 queued). Keyed by BOTH accountId AND folderPath: separate
    /// accounts fetch over separate IMAP connections, so their same-named folders
    /// (every account has an "INBOX") must NOT share this cap. A folderPath-only
    /// key let one account's 50-item batches perpetually hold both "INBOX" slots
    /// and starve ANOTHER account's isolation singleton (size-1 groups sort last
    /// under the size-descending dispatch order) — which would leave a genuinely
    /// oversized message never size-tested alone, i.e. never reaching the defer.
    private struct FolderCapKey: Hashable { let accountId: String; let folderPath: String }
    private var folderActiveBatches: [FolderCapKey: Int] = [:]
    private let maxBatchesPerFolder = 2

    /// headerIds from a PayloadTooLarge batch whose `items.count > 1` — one (or a
    /// few) of them is oversized, but the batch error doesn't say which. Each is
    /// dispatched ALONE (a forced single-item batch, via
    /// `groupCandidatesForDispatch`) so it is size-tested in isolation INDEPENDENT
    /// of `folderMaxBatch`. A lone PayloadTooLarge then defers it
    /// (`oversizedDeferredThisSession`); a resolution drops it here. Being
    /// failure-local, a sibling success can never let an oversized item escape
    /// single-item testing — so it reaches the defer instead of hot-looping.
    /// Cleared for a folder on UIDVALIDITY reset (`clearOversizedDeferred`).
    private var isolationPending: Set<String> = []

    /// Bodies that consumed their retry budget during the current drain. Their
    /// GRDB rows remain honestly incomplete, but drain-time recovery must not
    /// immediately give the same item a fresh budget forever. A real external
    /// enqueue/repopulation/cancellation boundary clears this memory so a later
    /// sync or foreground cycle can try again; the on-demand reader never consults
    /// it and can fetch immediately once the background item leaves storage.
    private var retryExhaustedThisDrain: Set<String> = []

    /// Bumped by `clearOversizedDeferred` on every UIDVALIDITY reset. A batch
    /// captures this at DISPATCH (before the fetch await) and passes it to
    /// `handlePayloadTooLarge`, which skips inserting into
    /// `oversizedDeferredThisSession` / `isolationPending` if the generation changed
    /// meanwhile — i.e. a reset landed during this batch's fetch window and already
    /// cleared the sets. Without this, a batch that started BEFORE the reset could
    /// resume AFTER the clear and re-insert the now-stale OLD-epoch headerId,
    /// wrongly rejecting a new-epoch message reusing that UID until relaunch.
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

    /// Test-only seam: snapshot of the underlying `QueueStorage` bookkeeping so the
    /// oversized-defer tests can assert the item was removed, was NOT marked
    /// recentlyCompleted, and `activeJobs` was left untouched. Same internal
    /// visibility as `dbPoolPriorityForTesting`.
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

    /// Test seam for the exact admission step used by drain-time database
    /// recovery. The database selector itself has separate stateful SQL tests.
    func admitDrainCandidatesForTesting(_ items: [Item]) -> Int {
        admitDrainCandidates(items)
    }

    /// Test-only seam: pre-set the per-folder batch cap so the disposition tests can
    /// pin that the defer decision keys on THIS batch's `items.count` and NOT on the
    /// shared cap — a concurrent fast-failing batch lowering the cap to 1 must not
    /// cause a genuine multi-item batch of ordinary messages to defer.
    func setFolderMaxBatchForTesting(_ n: Int, folderPath: String) {
        folderMaxBatch[folderPath] = n
    }

    /// Test-only seam: the isolation-pending set — items from a multi-item
    /// PayloadTooLarge awaiting single-item testing.
    var isolationPendingForTesting: Set<String> { isolationPending }

    /// Test-only seam: the current reset generation (what a batch captures at dispatch).
    var resetGenerationForTesting: Int { resetGeneration }

    /// Test-only seam for the drain-exhaustion regression.
    var retryExhaustedHeaderIdsForTesting: Set<String> { retryExhaustedThisDrain }

    /// Test-only seam: drive an item's batch-completion disposition (what a real
    /// isolation-singleton batch applies on success/retry) without the live
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
    /// TabMail/Services/Sync/ActiveBodyQueue.swift` → **6** lines = this definition
    /// plus **5** enqueue sites, and there is no insertion into
    /// `oversizedDeferredThisSession` / the pending set outside them. A NEW enqueue
    /// path that does not call `admit` silently re-admits a deferred oversized item
    /// for the rest of the process lifetime, which is exactly what this gate exists
    /// to prevent — so re-run the predicate rather than trusting the word SINGLE.
    ///
    /// The gate itself: skip a headerId already deferred as oversized for this
    /// process, or ordinarily retry-exhausted for this drain. The
    /// repopulate/drain SELECTs still return the row (`bodyComplete = 0 /
    /// bodyEmptyConfirmed = 0` is truthfully retryable — the row is NOT lied
    /// about), but this gate keeps it out of the immediate self-repopulation
    /// cycle. Returns true iff the item was actually enqueued.
    @discardableResult
    func admit(_ item: Item) -> Bool {
        guard !oversizedDeferredThisSession.contains(item.headerId) else { return false }
        guard !retryExhaustedThisDrain.contains(item.headerId) else { return false }
        return storage.enqueue(item)
    }

    private func admitDrainCandidates(_ items: [Item]) -> Int {
        var added = 0
        for item in items where admit(item) { added += 1 }
        return added
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
    /// it of its body until relaunch. The purge-and-resync is the correct
    /// invalidation point — ADR-IOS-061, specifically the **purge-and-resync
    /// carve-out**, which is one of the two clauses of 061 that ADR-IOS-070 leaves
    /// STANDING rather than withdrawing. ⚠️ This cited `ADR-IOS-061/062` until R16-7
    /// (corrected 2026-08-06): **`ADR-IOS-062` has never existed.** `DECISIONS.md`
    /// §ADR-IOS-070 states it outright — it appears in no `DECISIONS.md` at either
    /// tag, has no detail file, and exists only in an untracked draft; the number is
    /// unused and must not be cited. The principle a reader reaches for when they
    /// cite it is **ADR-IOS-068** (native provider id is the durable action key),
    /// which is NOT what licenses this function — the licence here is 061's
    /// carve-out. Predicate: `rg -n 'ADR-IOS-062|061/062' TabMail/ Shared/
    /// TabMailNotificationService/ TabMailTests/` → **no output, exit 1**; the only
    /// surviving mentions anywhere are the two that exist to say the number is
    /// void (`DECISIONS.md`, `Companion/Decisions/V3/Active/adr-ios-070.md` §5).
    /// Colon-hierarchy safe via
    /// `MessageIdentity.headerIdBelongsToFolder` — a nested `:`-delimited sibling
    /// folder is not matched.
    func clearOversizedDeferred(accountId: String, folderPath: String) {
        // Bump FIRST (the generation guard): any in-flight batch that captured the
        // pre-reset generation and resumes after this clear will now skip its stale
        // insert instead of re-populating the just-cleared sets.
        resetGeneration &+= 1
        let before = oversizedDeferredThisSession.count + isolationPending.count
        oversizedDeferredThisSession = oversizedDeferredThisSession.filter {
            !MessageIdentity.headerIdBelongsToFolder($0, accountId: accountId, folderPath: folderPath)
        }
        isolationPending = isolationPending.filter {
            !MessageIdentity.headerIdBelongsToFolder($0, accountId: accountId, folderPath: folderPath)
        }
        retryExhaustedThisDrain = retryExhaustedThisDrain.filter {
            !MessageIdentity.headerIdBelongsToFolder($0, accountId: accountId, folderPath: folderPath)
        }
        let removed = before - (oversizedDeferredThisSession.count + isolationPending.count)
        if removed > 0, DebugModeManager.isLoggingEnabled() {
            print("[ActiveBody] Cleared \(removed) oversized-deferred/isolation key(s) for \(folderPath) after UIDVALIDITY reset")
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

    func enqueue(header: MessageHeader) {
        let item = Item(
            headerId: header.id, accountId: header.accountId,
            folderPath: header.folderPath, messageId: header.messageId,
            isInInbox: header.isInInbox
        )
        retryExhaustedThisDrain.remove(item.headerId)
        guard admit(item) else { return }
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
            retryExhaustedThisDrain.remove(item.headerId)
            if admit(item) { added += 1 }
        }
        guard added > 0 else { return }
        print("[ActiveBody] Enqueued \(added) items (total: \(storage.count))")
        scheduleDispatch()
    }

    func repopulateFromDatabase() async {
        // This method is called by a real launch/foreground/sync recovery cycle,
        // not by the drain-time safety net. Give exhausted rows one fresh budget.
        retryExhaustedThisDrain.removeAll()
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let items: [Item] = try await dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, accountId, folderPath, messageId, isInInbox
                    FROM messageHeader
                    WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0
                      AND bodyIndexingFailureReason IS NULL AND isInInbox = 1
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
                if admit(item) { added += 1 }
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
        retryExhaustedThisDrain.removeAll()
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
        print("[ActiveBody] Dispatching \(dispatchCount) items in \(groupsToDispatch.count) folder groups (deferred=\(deferredCount), activeBatches=\(activeBatchCount))")

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

                } catch {
                    let desc = "\(error)"
                    if let providerError = error as? ProviderError,
                       case .bodyIndexingUnsupported(let messageId) = providerError,
                       let failedItem = items.first(where: { $0.messageId == messageId }) {
                        let processorItem = BodyFetchProcessor.Item(
                            headerId: failedItem.headerId,
                            accountId: failedItem.accountId,
                            folderPath: failedItem.folderPath,
                            messageId: failedItem.messageId,
                            isInInbox: failedItem.isInInbox
                        )
                        let terminalized = await BodyFetchProcessor.markBodyUnindexed(
                            item: processorItem,
                            reason: .partialFetchUnsupported
                        )
                        print("[ActiveBody] Partial fetch unsupported — \(terminalized ? "recorded terminal-unindexed state" : "row changed; retrying")")
                        self.batchItemDone(item: failedItem, shouldRetry: !terminalized)
                        for item in items where item.headerId != failedItem.headerId {
                            self.batchItemDone(item: item, shouldRetry: true)
                        }
                    } else if desc.contains("PayloadTooLargeError") {
                        // Defer a genuinely single oversized item WITHOUT marking it
                        // empty; a multi-item batch isolates its members so a later
                        // dispatch slices each one singly. The decision keys on THIS
                        // batch's actual `items.count`, NOT the shared folderMaxBatch
                        // cap — a concurrent fast-failing batch could lower that cap
                        // to 1, which would wrongly defer a whole batch of ordinary
                        // messages for the process lifetime.
                        self.handlePayloadTooLarge(
                            items: items, folderPath: key.folderPath,
                            capturedGeneration: capturedResetGeneration
                        )
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
                let remaining = (self.folderActiveBatches[capKey] ?? 1) - 1
                if remaining <= 0 {
                    self.folderActiveBatches.removeValue(forKey: capKey)
                } else {
                    self.folderActiveBatches[capKey] = remaining
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
        // An item that RESOLVES (shouldRetry=false — fetched OK, confirmed gone,
        // or re-keyed) is no longer an oversize suspect; drop it
        // from isolation so it isn't needlessly single-item-dispatched again. (A
        // lone oversized item defers via handlePayloadTooLarge, which clears it
        // there.) Set.remove is a no-op for non-members.
        if !shouldRetry { isolationPending.remove(item.headerId) }
        let exhausted = shouldRetry
            && storage.retryCount(for: item) >= SyncConfig.maxQueueRetries
        _ = storage.batchItemCompleted(item, shouldRetry: shouldRetry, maxRetries: SyncConfig.maxQueueRetries)
        if exhausted {
            isolationPending.remove(item.headerId)
            retryExhaustedThisDrain.insert(item.headerId)
        }
    }

    /// PayloadTooLarge disposition. Factored out of `dispatchBatch`'s catch so the
    /// defer/isolate decision is directly testable (driving the full dispatch
    /// pipeline needs live network + provider scaffolding). Runs SYNCHRONOUSLY on
    /// the actor — there is deliberately no `await` anywhere in it, so no producer
    /// can slip an enqueue in between the set insert and the queue removal.
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
    ///    set `recentlyCompleted` (no false 30s repopulate suppression), and do NOT
    ///    call `abandonWithoutCompletion` (it decrements `activeJobs`, which this
    ///    queue never uses — it tracks `activeBatchCount`). The batch counter still
    ///    decrements once in the dispatch task below.
    ///  - `items.count > 1`: mark every item ISOLATION-PENDING and retry it — a later
    ///    dispatch tests each ALONE (a forced single-item batch, via
    ///    `groupCandidatesForDispatch`), INDEPENDENT of `folderMaxBatch`; each
    ///    genuinely oversized single then defers here, ordinary siblings fetch
    ///    normally. Failure-local, so a sibling success can never undo the isolation
    ///    (the removed folderMaxBatch halving could — any success reset it).
    func handlePayloadTooLarge(items: [Item], folderPath: String, capturedGeneration: Int? = nil) {
        // Generation guard: a UIDVALIDITY reset landed during this batch's fetch
        // window (`clearOversizedDeferred` bumped `resetGeneration` and already
        // cleared the sets). The items in hand are OLD-epoch; re-adding their
        // headerIds would UNDO the clear and starve a new-epoch message reusing the
        // UID. Skip BOTH set inserts and just release the items retryable (their rows
        // were purged → they resolve as gone / are superseded by the resync).
        // `capturedGeneration == nil` = a direct/test call with no reset-guard
        // context → never stale.
        let stale = capturedGeneration.map { $0 != resetGeneration } ?? false
        if items.count == 1 {
            let item = items[0]
            if stale {
                if DebugModeManager.isLoggingEnabled() {
                    print("[ActiveBody] Oversized single item in \(folderPath) raced a UIDVALIDITY reset — NOT deferring stale \(item.headerId.prefix(30)); retrying")
                }
                batchItemDone(item: item, shouldRetry: true)
                return
            }
            if DebugModeManager.isLoggingEnabled() {
                print("[ActiveBody] Single item too large in \(folderPath) — deferring \(item.headerId.prefix(30)) in-memory (bodyComplete=0, NOT marked empty)")
            }
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
                    print("[ActiveBody] PayloadTooLarge for \(folderPath) raced a UIDVALIDITY reset — NOT isolating \(items.count) stale items; retrying")
                } else {
                    print("[ActiveBody] PayloadTooLarge for \(folderPath) — isolating \(items.count) items for single-item testing")
                }
            }
        }
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
                        if admit(newItem) { scheduleDispatch() }
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
                    WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0
                      AND bodyIndexingFailureReason IS NULL AND isInInbox = 1
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
            let added = admitDrainCandidates(items)
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
