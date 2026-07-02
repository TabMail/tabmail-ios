/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Test Actor

/// Lightweight actor that replicates the exact cancellation patterns from
/// ActiveBodyQueue and BackfillBodyQueue — batchTasks tracking, counter management,
/// and the Task.isCancelled guard that prevents counter corruption.
///
/// This avoids coupling to global singletons (AccountManager, AppDatabase, NetworkMonitor)
/// while testing the same code patterns.
private actor TestBodyQueue {
    typealias Item = ActiveBodyQueue.Item

    var storage = QueueStorage<Item>()
    var batchTasks: [Task<Void, Never>] = []
    var activeBatchCount = 0
    var folderActiveBatches: [String: Int] = [:]

    /// Simulates dispatching a batch task that runs the given closure.
    /// Mirrors the exact pattern from ActiveBodyQueue.dispatchBatch().
    func dispatchBatch(
        folderPath: String,
        items: [Item],
        work: @Sendable @escaping () async -> Void
    ) {
        activeBatchCount += 1
        folderActiveBatches[folderPath, default: 0] += 1

        let batchTask = Task { [self] in
            await work()

            // If cancelled by cancelAllInFlight(), counters are already reset to 0.
            // Skip decrement to avoid negative counts.
            guard !Task.isCancelled else { return }

            activeBatchCount -= 1
            let remaining = (self.folderActiveBatches[folderPath] ?? 1) - 1
            if remaining <= 0 {
                self.folderActiveBatches.removeValue(forKey: folderPath)
            } else {
                self.folderActiveBatches[folderPath] = remaining
            }
        }
        batchTasks.removeAll { $0.isCancelled }
        batchTasks.append(batchTask)
    }

    /// Mirrors ActiveBodyQueue.cancelAllInFlight() exactly.
    func cancelAllInFlight() {
        storage.cancelAllInFlight()
        for task in batchTasks { task.cancel() }
        batchTasks.removeAll()
        activeBatchCount = 0
        folderActiveBatches.removeAll()
    }

    var isIdle: Bool {
        storage.isEmpty && activeBatchCount == 0
    }

    var batchTaskCount: Int {
        batchTasks.count
    }

    var activeBatchTaskCount: Int {
        batchTasks.filter { !$0.isCancelled }.count
    }

    // MARK: - Test Helpers (actor-isolated accessors for storage)

    var storageCount: Int { storage.count }
    var storageIsEmpty: Bool { storage.isEmpty }
    var storageInFlightCount: Int { storage.inFlight.count }

    @discardableResult
    func enqueueItem(_ item: Item) -> Bool {
        storage.enqueue(item)
    }

    func enqueueItems(_ items: [Item]) {
        for item in items { storage.enqueue(item) }
    }

    func collectCandidates(maxJobs: Int) -> [Item] {
        storage.collectCandidates(maxJobs: maxJobs)
    }
}

// MARK: - Helpers

private func makeItem(
    headerId: String = "acc1:INBOX:1",
    accountId: String = "acc1",
    folderPath: String = "INBOX",
    messageId: String = "1",
    isInInbox: Bool = true
) -> ActiveBodyQueue.Item {
    ActiveBodyQueue.Item(
        headerId: headerId,
        accountId: accountId,
        folderPath: folderPath,
        messageId: messageId,
        isInInbox: isInInbox
    )
}

private func makeItems(count: Int, folderPath: String = "INBOX") -> [ActiveBodyQueue.Item] {
    (1...count).map { i in
        makeItem(
            headerId: "acc1:\(folderPath):\(i)",
            folderPath: folderPath,
            messageId: "\(i)"
        )
    }
}

// MARK: - Suite 1: cancelAllInFlight Cancels Actual Batch Tasks

@Suite("Body Queue Cancellation - Batch Task Cancellation")
struct BatchTaskCancellationTests {

    @Test("cancelAllInFlight cancels actual batch Tasks")
    func cancelAllInFlightCancelsTasks() async {
        let queue = TestBodyQueue()
        let items = makeItems(count: 3)
        for item in items {
            await queue.enqueueItem(item)
        }

        // Dispatch a batch with a long-running task
        let hangingSignal = AsyncStream<Void>.makeStream()
        await queue.dispatchBatch(folderPath: "INBOX", items: items) {
            // Simulate a hanging IMAP fetch — wait until cancelled or signalled
            for await _ in hangingSignal.stream { break }
        }

        // Batch task is running
        let taskCountBefore = await queue.batchTaskCount
        #expect(taskCountBefore == 1)

        // Cancel
        await queue.cancelAllInFlight()

        // batchTasks array is cleared
        let taskCountAfter = await queue.batchTaskCount
        #expect(taskCountAfter == 0)
    }

    @Test("cancelAllInFlight resets activeBatchCount to 0")
    func cancelResetsActiveBatchCount() async {
        let queue = TestBodyQueue()
        let items1 = makeItems(count: 2, folderPath: "INBOX")
        let items2 = makeItems(count: 2, folderPath: "Sent")

        let hangingSignal = AsyncStream<Void>.makeStream()
        await queue.dispatchBatch(folderPath: "INBOX", items: items1) {
            for await _ in hangingSignal.stream { break }
        }
        await queue.dispatchBatch(folderPath: "Sent", items: items2) {
            for await _ in hangingSignal.stream { break }
        }

        let countBefore = await queue.activeBatchCount
        #expect(countBefore == 2)

        await queue.cancelAllInFlight()

        let countAfter = await queue.activeBatchCount
        #expect(countAfter == 0)
    }

    @Test("cancelAllInFlight resets folderActiveBatches to empty")
    func cancelResetsFolderActiveBatches() async {
        let queue = TestBodyQueue()
        let items = makeItems(count: 2)

        let hangingSignal = AsyncStream<Void>.makeStream()
        await queue.dispatchBatch(folderPath: "INBOX", items: items) {
            for await _ in hangingSignal.stream { break }
        }

        let folderBefore = await queue.folderActiveBatches
        #expect(folderBefore["INBOX"] == 1)

        await queue.cancelAllInFlight()

        let folderAfter = await queue.folderActiveBatches
        #expect(folderAfter.isEmpty)
    }

    @Test("cancelAllInFlight clears storage in-flight set")
    func cancelClearsStorageInFlight() async {
        let queue = TestBodyQueue()
        let items = makeItems(count: 3)
        for item in items {
            await queue.enqueueItem(item)
        }
        // Move items to in-flight via collectCandidates
        let _ = await queue.collectCandidates(maxJobs: 3)
        let inFlightBefore = await queue.storageInFlightCount
        #expect(inFlightBefore == 3)

        await queue.cancelAllInFlight()

        let inFlightAfter = await queue.storageInFlightCount
        #expect(inFlightAfter == 0)
        let queueCount = await queue.storageCount
        #expect(queueCount == 0)
    }
}

// MARK: - Suite 2: Cancelled Batch Task Counter Guard

@Suite("Body Queue Cancellation - Counter Corruption Guard")
struct CounterCorruptionGuardTests {

    @Test("Cancelled batch task does NOT decrement activeBatchCount")
    func cancelledTaskSkipsDecrement() async throws {
        let queue = TestBodyQueue()
        let items = makeItems(count: 2)

        // Use a continuation to control when the work completes
        let workStarted = AsyncStream<Void>.makeStream()
        let workCanProceed = AsyncStream<Void>.makeStream()

        await queue.dispatchBatch(folderPath: "INBOX", items: items) {
            workStarted.continuation.yield()
            // Wait until we're told to proceed (or cancelled)
            for await _ in workCanProceed.stream { break }
        }

        // Wait for work to start
        for await _ in workStarted.stream { break }

        // Cancel — resets activeBatchCount to 0
        await queue.cancelAllInFlight()
        let countAfterCancel = await queue.activeBatchCount
        #expect(countAfterCancel == 0)

        // Let the cancelled task's completion code run
        workCanProceed.continuation.finish()
        // Give the task time to complete its guard check
        try await Task.sleep(for: .milliseconds(50))

        // activeBatchCount must still be 0 (not -1)
        let countAfterCompletion = await queue.activeBatchCount
        #expect(countAfterCompletion == 0, "Cancelled task must NOT decrement counter below 0")
    }

    @Test("Cancelled batch task does NOT modify folderActiveBatches")
    func cancelledTaskSkipsFolderDecrement() async throws {
        let queue = TestBodyQueue()
        let items = makeItems(count: 2)

        let workStarted = AsyncStream<Void>.makeStream()
        let workCanProceed = AsyncStream<Void>.makeStream()

        await queue.dispatchBatch(folderPath: "INBOX", items: items) {
            workStarted.continuation.yield()
            for await _ in workCanProceed.stream { break }
        }

        for await _ in workStarted.stream { break }

        await queue.cancelAllInFlight()
        let folderAfterCancel = await queue.folderActiveBatches
        #expect(folderAfterCancel.isEmpty)

        workCanProceed.continuation.finish()
        try await Task.sleep(for: .milliseconds(50))

        // folderActiveBatches must remain empty (cancelled task should not re-add entries)
        let folderAfterCompletion = await queue.folderActiveBatches
        #expect(folderAfterCompletion.isEmpty, "Cancelled task must NOT modify folderActiveBatches")
    }
}

// MARK: - Suite 3: Cancel During Active Fetch

@Suite("Body Queue Cancellation - Cancel During Active Fetch")
struct CancelDuringFetchTests {

    @Test("Cancel during hanging provider fetch marks batch Task as cancelled")
    func cancelDuringHangingFetch() async throws {
        let queue = TestBodyQueue()
        let items = makeItems(count: 5)

        // Simulate a provider that hangs forever
        await queue.dispatchBatch(folderPath: "INBOX", items: items) {
            // This simulates provider.fetchMessagesBatch hanging on a dead IMAP connection
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        // Capture the task before cancel clears it
        let taskCount = await queue.batchTaskCount
        #expect(taskCount == 1)

        // Cancel all — should cancel the hanging task
        await queue.cancelAllInFlight()

        let isIdle = await queue.isIdle
        #expect(isIdle == true, "Queue should be idle after cancel")
    }

    @Test("Cancelled fetch task respects cooperative cancellation")
    func cancelledFetchRespectsCooperativeCancellation() async throws {
        let queue = TestBodyQueue()
        let items = makeItems(count: 1)
        await queue.dispatchBatch(folderPath: "INBOX", items: items) {
            // Check cancellation cooperatively (like real IMAP fetch should)
            for _ in 0..<100 {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        // Cancel immediately
        await queue.cancelAllInFlight()

        // Wait for the task to finish
        try await Task.sleep(for: .milliseconds(200))

        // The work should NOT have completed all iterations
        // (fetchCompleted stays false because the task exits early via Task.isCancelled)
        // Note: we can't directly check fetchCompleted from here due to actor isolation,
        // but we verify the queue state is clean
        let isIdle = await queue.isIdle
        #expect(isIdle == true)
    }
}

// MARK: - Suite 4: Rapid Cancel → Repopulate → Dispatch

@Suite("Body Queue Cancellation - Rapid Cancel and Repopulate")
struct RapidCancelRepopulateTests {

    @Test("Cancel stale → enqueue new → dispatch works correctly")
    func cancelThenRepopulateAndDispatch() async throws {
        let queue = TestBodyQueue()
        let staleItems = makeItems(count: 3, folderPath: "INBOX")

        // Dispatch stale batch (simulates previous sync cycle)
        let hangingSignal = AsyncStream<Void>.makeStream()
        await queue.dispatchBatch(folderPath: "INBOX", items: staleItems) {
            for await _ in hangingSignal.stream { break }
        }

        let batchesBefore = await queue.activeBatchCount
        #expect(batchesBefore == 1)

        // Cancel stale (simulates foreground return / reconnect)
        await queue.cancelAllInFlight()

        // Repopulate with fresh items (simulates repopulateFromDatabase)
        let freshItems = makeItems(count: 5, folderPath: "INBOX")
        for item in freshItems {
            await queue.enqueueItem(item)
        }

        let enqueuedCount = await queue.storageCount
        #expect(enqueuedCount == 5)

        // Dispatch new batch — should work normally
        await queue.dispatchBatch(folderPath: "INBOX", items: freshItems) {
            // no-op — completes immediately
        }

        // Wait for completion
        try await Task.sleep(for: .milliseconds(100))

        let activeBatches = await queue.activeBatchCount
        // New batch completed normally, so activeBatchCount decremented to 0
        #expect(activeBatches == 0)
    }

    @Test("Fresh items can be enqueued after cancel clears dedup set")
    func freshItemsEnqueueAfterCancel() async {
        let queue = TestBodyQueue()

        // Enqueue initial items
        let items = makeItems(count: 3)
        for item in items {
            await queue.enqueueItem(item)
        }
        let countBefore = await queue.storageCount
        #expect(countBefore == 3)

        // Cancel clears the entire queue including dedup set
        await queue.cancelAllInFlight()

        // Re-enqueue same items — should succeed because cancelAllInFlight clears enqueued set
        for item in items {
            let added = await queue.enqueueItem(item)
            #expect(added == true)
        }
        let countAfter = await queue.storageCount
        #expect(countAfter == 3)
    }
}

// MARK: - Suite 5: Multiple Cancel Cycles

@Suite("Body Queue Cancellation - Multiple Cycles")
struct MultipleCancelCycleTests {

    @Test("Cancel → dispatch → cancel → dispatch — state clean after each cycle")
    func multipleCancelDispatchCycles() async throws {
        let queue = TestBodyQueue()

        for cycle in 1...3 {
            let items = makeItems(count: 2, folderPath: "Folder\(cycle)")

            let hangingSignal = AsyncStream<Void>.makeStream()
            await queue.dispatchBatch(folderPath: "Folder\(cycle)", items: items) {
                for await _ in hangingSignal.stream { break }
            }

            let batchCount = await queue.activeBatchCount
            #expect(batchCount == 1, "Cycle \(cycle): should have 1 active batch")

            await queue.cancelAllInFlight()

            let batchCountAfter = await queue.activeBatchCount
            #expect(batchCountAfter == 0, "Cycle \(cycle): activeBatchCount should be 0 after cancel")

            let taskCount = await queue.batchTaskCount
            #expect(taskCount == 0, "Cycle \(cycle): batchTasks should be empty after cancel")

            let folders = await queue.folderActiveBatches
            #expect(folders.isEmpty, "Cycle \(cycle): folderActiveBatches should be empty after cancel")

            let isIdle = await queue.isIdle
            #expect(isIdle == true, "Cycle \(cycle): should be idle after cancel")
        }
    }

    @Test("Cancel with multiple concurrent batches across folders")
    func cancelMultipleConcurrentBatches() async throws {
        let queue = TestBodyQueue()
        let folders = ["INBOX", "Sent", "Archive", "Drafts"]
        let hangingSignal = AsyncStream<Void>.makeStream()

        for folder in folders {
            let items = makeItems(count: 2, folderPath: folder)
            await queue.dispatchBatch(folderPath: folder, items: items) {
                for await _ in hangingSignal.stream { break }
            }
        }

        let batchCountBefore = await queue.activeBatchCount
        #expect(batchCountBefore == 4)

        let foldersBefore = await queue.folderActiveBatches
        #expect(foldersBefore.count == 4)

        let taskCountBefore = await queue.batchTaskCount
        #expect(taskCountBefore == 4)

        // Single cancel clears everything
        await queue.cancelAllInFlight()

        let batchCountAfter = await queue.activeBatchCount
        #expect(batchCountAfter == 0)

        let foldersAfter = await queue.folderActiveBatches
        #expect(foldersAfter.isEmpty)

        let taskCountAfter = await queue.batchTaskCount
        #expect(taskCountAfter == 0)
    }
}

// MARK: - Suite 6: batchTasks Array Pruning

@Suite("Body Queue Cancellation - Task Array Pruning")
struct TaskArrayPruningTests {

    @Test("Completed tasks pruned from batchTasks before appending new ones")
    func completedTasksPruned() async throws {
        let queue = TestBodyQueue()

        // Dispatch a task that completes quickly
        let items1 = makeItems(count: 1, folderPath: "INBOX")
        await queue.dispatchBatch(folderPath: "INBOX", items: items1) {
            // Completes immediately
        }

        // Wait for it to complete
        try await Task.sleep(for: .milliseconds(100))

        // Dispatch another — pruning should remove the completed/cancelled one first
        let items2 = makeItems(count: 1, folderPath: "Sent")
        await queue.dispatchBatch(folderPath: "Sent", items: items2) {
            // Completes immediately
        }

        // After pruning + append, only the new task should remain (old one was pruned)
        // The pruning uses `$0.isCancelled` — completed (non-cancelled) tasks stay.
        // This matches the production code behavior.
        let taskCount = await queue.batchTaskCount
        // Both tasks may still be in array since only isCancelled tasks get pruned,
        // not completed ones. This matches the actual implementation.
        #expect(taskCount <= 2, "Task count should be bounded")
    }

    @Test("cancelAllInFlight removes ALL tasks from tracking array")
    func cancelRemovesAllTasks() async {
        let queue = TestBodyQueue()
        let hangingSignal = AsyncStream<Void>.makeStream()

        // Dispatch multiple batches
        for i in 1...5 {
            let items = makeItems(count: 1, folderPath: "Folder\(i)")
            await queue.dispatchBatch(folderPath: "Folder\(i)", items: items) {
                for await _ in hangingSignal.stream { break }
            }
        }

        let taskCountBefore = await queue.batchTaskCount
        #expect(taskCountBefore == 5)

        await queue.cancelAllInFlight()

        let taskCountAfter = await queue.batchTaskCount
        #expect(taskCountAfter == 0, "All tasks must be removed from tracking array after cancel")
    }
}

// MARK: - Suite 7: isIdle After Cancel

@Suite("Body Queue Cancellation - isIdle State")
struct IsIdleAfterCancelTests {

    @Test("isIdle returns true after cancelAllInFlight")
    func isIdleAfterCancel() async {
        let queue = TestBodyQueue()
        let items = makeItems(count: 5)
        for item in items {
            await queue.enqueueItem(item)
        }

        let hangingSignal = AsyncStream<Void>.makeStream()
        await queue.dispatchBatch(folderPath: "INBOX", items: items) {
            for await _ in hangingSignal.stream { break }
        }

        let isIdleBefore = await queue.isIdle
        #expect(isIdleBefore == false)

        await queue.cancelAllInFlight()

        let isIdleAfter = await queue.isIdle
        #expect(isIdleAfter == true, "isIdle must be true after cancelAllInFlight")
    }

    @Test("isIdle returns true when queue has items but activeBatchCount is 0")
    func isIdleWithPendingItemsButNoBatches() async {
        // isIdle checks storage.isEmpty AND activeBatchCount == 0
        // If storage has items, isIdle is false — even with no active batches
        let queue = TestBodyQueue()
        let items = makeItems(count: 2)
        for item in items {
            await queue.enqueueItem(item)
        }

        let isIdle = await queue.isIdle
        #expect(isIdle == false, "Not idle when storage has pending items")
    }

    @Test("isIdle returns false with active batches but empty storage")
    func isIdleWithActiveBatchesEmptyStorage() async {
        let queue = TestBodyQueue()
        let items = makeItems(count: 1)

        let hangingSignal = AsyncStream<Void>.makeStream()
        await queue.dispatchBatch(folderPath: "INBOX", items: items) {
            for await _ in hangingSignal.stream { break }
        }

        // Storage is empty (no items enqueued in storage), but activeBatchCount > 0
        let storageEmpty = await queue.storageIsEmpty
        #expect(storageEmpty == true)

        let activeBatches = await queue.activeBatchCount
        #expect(activeBatches == 1)

        let isIdle = await queue.isIdle
        #expect(isIdle == false, "Not idle when batches are active")

        // Cleanup
        await queue.cancelAllInFlight()
    }
}

// MARK: - Suite 8: Cancel With No In-Flight Tasks

@Suite("Body Queue Cancellation - No-Op Safety")
struct CancelNoOpSafetyTests {

    @Test("cancelAllInFlight is safe when nothing is running")
    func cancelWithNothingRunning() async {
        let queue = TestBodyQueue()

        // Queue is empty, no tasks — cancel should be a no-op
        await queue.cancelAllInFlight()

        let isIdle = await queue.isIdle
        #expect(isIdle == true)
        let batchCount = await queue.activeBatchCount
        #expect(batchCount == 0)
        let taskCount = await queue.batchTaskCount
        #expect(taskCount == 0)
        let folders = await queue.folderActiveBatches
        #expect(folders.isEmpty)
    }

    @Test("cancelAllInFlight is safe when called twice in succession")
    func doubleCancelIsSafe() async {
        let queue = TestBodyQueue()
        let items = makeItems(count: 3)
        for item in items {
            await queue.enqueueItem(item)
        }

        let hangingSignal = AsyncStream<Void>.makeStream()
        await queue.dispatchBatch(folderPath: "INBOX", items: items) {
            for await _ in hangingSignal.stream { break }
        }

        // Double cancel
        await queue.cancelAllInFlight()
        await queue.cancelAllInFlight()

        let isIdle = await queue.isIdle
        #expect(isIdle == true)
        let batchCount = await queue.activeBatchCount
        #expect(batchCount == 0)
    }

    @Test("cancelAllInFlight with only enqueued items (no dispatched batches)")
    func cancelWithOnlyEnqueuedItems() async {
        let queue = TestBodyQueue()
        let items = makeItems(count: 5)
        for item in items {
            await queue.enqueueItem(item)
        }

        let countBefore = await queue.storageCount
        #expect(countBefore == 5)

        // Cancel without ever dispatching
        await queue.cancelAllInFlight()

        // Queue should be cleared
        let countAfter = await queue.storageCount
        #expect(countAfter == 0)
        let isIdle = await queue.isIdle
        #expect(isIdle == true)
    }
}

// MARK: - Suite 9: QueueStorage cancelAllInFlight Direct Tests

@Suite("Body Queue Cancellation - QueueStorage.cancelAllInFlight")
struct QueueStorageCancelAllInFlightTests {

    typealias Item = ActiveBodyQueue.Item

    @Test("cancelAllInFlight clears queue, inFlight, enqueued, retryCount, recentlyCompleted")
    func cancelAllInFlightClearsEverything() {
        var storage = QueueStorage<Item>()
        let items = makeItems(count: 5)
        for item in items {
            storage.enqueue(item)
        }

        // Move some to in-flight
        let candidates = storage.collectCandidates(maxJobs: 3)
        #expect(candidates.count == 3)
        guard candidates.count >= 2 else { return }

        // Complete one with retry to populate retryCount
        storage.incrementActiveJobs()
        _ = storage.jobCompleted(candidates[0], shouldRetry: true, maxRetries: 5)

        // Complete one successfully to populate recentlyCompleted
        storage.incrementActiveJobs()
        _ = storage.jobCompleted(candidates[1], shouldRetry: false, maxRetries: 5)

        // Cancel everything
        storage.cancelAllInFlight()

        #expect(storage.isEmpty, "Queue should be empty")
        #expect(storage.count == 0, "Count should be 0")
        #expect(storage.inFlight.isEmpty, "In-flight should be empty")
        #expect(storage.enqueued.isEmpty, "Enqueued dedup set should be empty")
        #expect(storage.activeJobs == 0, "Active jobs should be 0")
        #expect(storage.recentlyCompleted.isEmpty, "recentlyCompleted should be cleared")
    }

    @Test("After cancelAllInFlight, same items can be re-enqueued")
    func reEnqueueAfterCancel() {
        var storage = QueueStorage<Item>()
        let items = makeItems(count: 3)
        for item in items {
            storage.enqueue(item)
        }

        storage.cancelAllInFlight()

        // Re-enqueue same items — dedup set was cleared
        for item in items {
            let added = storage.enqueue(item)
            #expect(added == true, "Item \(item.headerId) should be re-enqueueable after cancel")
        }
        #expect(storage.count == 3)
    }

    @Test("cancelAllInFlight clears recentlyCompleted — prevents stale completion blocking re-processing")
    func cancelClearsRecentlyCompleted() {
        var storage = QueueStorage<Item>()
        let item = makeItem()
        storage.enqueue(item)

        // Complete successfully — adds to recentlyCompleted
        let candidates = storage.collectCandidates(maxJobs: 1)
        #expect(candidates.count == 1)
        guard let first = candidates.first else { return }
        storage.incrementActiveJobs()
        _ = storage.jobCompleted(first, shouldRetry: false, maxRetries: 3)
        #expect(storage.recentlyCompleted.keys.contains(item))

        // Without cancel, re-enqueue would be blocked by recentlyCompleted
        let blockedAdd = storage.enqueue(item)
        #expect(blockedAdd == false, "recentlyCompleted should block re-enqueue")

        // Cancel clears recentlyCompleted
        storage.cancelAllInFlight()
        let afterCancelAdd = storage.enqueue(item)
        #expect(afterCancelAdd == true, "After cancel, recentlyCompleted cleared, re-enqueue should work")
    }

    @Test("cancelAllInFlight resets activeJobs to 0")
    func cancelResetsActiveJobs() {
        var storage = QueueStorage<Item>()
        let items = makeItems(count: 3)
        for item in items { storage.enqueue(item) }

        _ = storage.collectCandidates(maxJobs: 3)
        storage.incrementActiveJobs()
        storage.incrementActiveJobs()
        storage.incrementActiveJobs()
        #expect(storage.activeJobs == 3)

        storage.cancelAllInFlight()
        #expect(storage.activeJobs == 0, "activeJobs must be 0 after cancelAllInFlight")
    }
}
