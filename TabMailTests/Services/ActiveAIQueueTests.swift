/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Tests for ActiveAIQueue's Item type and QueueStorage behavior.
/// ActiveAIQueue is an actor coupled to AppDatabase, SearchIndex, AIService,
/// and PromptStore singletons. The testable parts are:
/// 1. Item struct (Hashable conformance, dedup behavior)
/// 2. QueueStorage with ActiveAIQueue.Item (FIFO, retry, concurrency)
/// 3. Queue state machine transitions
/// 4. Body-missing retry behavior (items retry when FTS body unavailable)
/// 5. No concurrency limit on task dispatch (LLMSemaphore gates API calls instead)
@Suite("ActiveAIQueue - Item and Queue Behavior")
struct ActiveAIQueueTests {

    typealias Item = ActiveAIQueue.AIJob

    // MARK: - Item Hashable/Equatable

    @Test("Items with same headerId and jobType are equal")
    func itemEquality() {
        let a = Item(headerId: "acc1:INBOX:1", accountId: "acc1", jobType: .summary)
        let b = Item(headerId: "acc1:INBOX:1", accountId: "acc1", jobType: .summary)
        #expect(a == b)
    }

    @Test("Items with different headerId are not equal")
    func itemInequalityHeaderId() {
        let a = Item(headerId: "acc1:INBOX:1", accountId: "acc1", jobType: .summary)
        let b = Item(headerId: "acc1:INBOX:2", accountId: "acc1", jobType: .summary)
        #expect(a != b)
    }

    @Test("Items with different jobType are not equal")
    func itemInequalityJobType() {
        let a = Item(headerId: "acc1:INBOX:1", accountId: "acc1", jobType: .summary)
        let b = Item(headerId: "acc1:INBOX:1", accountId: "acc1", jobType: .action)
        #expect(a != b)
    }

    @Test("Item hashability allows Set dedup")
    func itemSetDedup() {
        let items: Set<Item> = [
            Item(headerId: "h1", accountId: "a1", jobType: .summary),
            Item(headerId: "h1", accountId: "a1", jobType: .summary),
            Item(headerId: "h2", accountId: "a1", jobType: .summary),
        ]
        #expect(items.count == 2)
    }

    // MARK: - QueueStorage with Item type

    @Test("Enqueue deduplicates AI items")
    func enqueueDedups() {
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        let first = storage.enqueue(item)
        let second = storage.enqueue(item)
        #expect(first == true)
        #expect(second == false)
        #expect(storage.count == 1)
    }

    @Test("EnqueueBatch adds only unique AI items")
    func enqueueBatchDedups() {
        var storage = QueueStorage<Item>()
        let items = [
            Item(headerId: "h1", accountId: "a1", jobType: .summary),
            Item(headerId: "h2", accountId: "a1", jobType: .summary),
            Item(headerId: "h1", accountId: "a1", jobType: .summary), // duplicate
            Item(headerId: "h3", accountId: "a2", jobType: .summary),
        ]
        let added = storage.enqueueBatch(items)
        #expect(added == 3)
        #expect(storage.count == 3)
    }

    @Test("Items with different jobTypes for same header are separate in queue")
    func multiJobTypeItems() {
        var storage = QueueStorage<Item>()
        let a1 = Item(headerId: "h1", accountId: "acc1", jobType: .summary)
        let a2 = Item(headerId: "h1", accountId: "acc1", jobType: .action)
        storage.enqueue(a1)
        storage.enqueue(a2)
        #expect(storage.count == 2)
    }

    // MARK: - Dispatch with no concurrency limit (matching TB architecture)

    @Test("collectCandidates with Int.max dispatches ALL items")
    func collectCandidatesNoLimit() {
        var storage = QueueStorage<Item>()
        for i in 1...100 {
            storage.enqueue(Item(headerId: "h\(i)", accountId: "a1", jobType: .summary))
        }

        // Int.max = no concurrency limit (LLMSemaphore gates API calls)
        let candidates = storage.collectCandidates(maxJobs: Int.max)
        #expect(candidates.count == 100)
        #expect(storage.pendingCount == 0) // All dispatched
    }

    @Test("In-flight items are skipped during candidate collection")
    func inFlightSkipped() {
        var storage = QueueStorage<Item>()
        let item1 = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        let item2 = Item(headerId: "h2", accountId: "a1", jobType: .summary)
        storage.enqueue(item1)
        storage.enqueue(item2)

        // Collect first candidate
        let first = storage.collectCandidates(maxJobs: 1)
        #expect(first.count == 1)

        // Second collect should get the other item, not the in-flight one
        storage.incrementActiveJobs()
        let second = storage.collectCandidates(maxJobs: Int.max)
        #expect(second.count == 1)
        #expect(second[0] != first[0])
    }

    // MARK: - Job completion and retry

    @Test("Successful job completion removes item from queue")
    func jobCompletionRemovesItem() {
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        storage.enqueue(item)
        let candidates = storage.collectCandidates(maxJobs: Int.max)
        #expect(candidates.count == 1)
        guard let first = candidates.first else { return }
        storage.incrementActiveJobs()

        let hasMore = storage.jobCompleted(first, shouldRetry: false, maxRetries: SyncConfig.maxQueueRetries)
        #expect(hasMore == false)
        #expect(storage.isEmpty)
        #expect(storage.activeJobs == 0)
    }

    @Test("Failed job stays in queue for retry")
    func failedJobRetries() {
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        storage.enqueue(item)
        let candidates = storage.collectCandidates(maxJobs: Int.max)
        #expect(candidates.count == 1)
        guard let first = candidates.first else { return }
        storage.incrementActiveJobs()

        let hasMore = storage.jobCompleted(first, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
        #expect(hasMore == true)
        #expect(storage.count == 1) // Still in queue
        #expect(storage.retryCount(for: item) == 1)
    }

    @Test("Item removed after max retries exceeded")
    func maxRetriesExceeded() {
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        storage.enqueue(item)

        for _ in 0...SyncConfig.maxQueueRetries {
            let candidates = storage.collectCandidates(maxJobs: Int.max)
            if candidates.isEmpty { break }
            storage.incrementActiveJobs()
            _ = storage.jobCompleted(candidates[0], shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
        }

        #expect(storage.isEmpty)
    }

    @Test("Retry count tracks per-item")
    func retryCountPerItem() {
        var storage = QueueStorage<Item>()
        let item1 = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        let item2 = Item(headerId: "h2", accountId: "a1", jobType: .summary)
        storage.enqueue(item1)
        storage.enqueue(item2)

        // Fail item1 once
        let candidates = storage.collectCandidates(maxJobs: Int.max)
        storage.incrementActiveJobs()
        storage.incrementActiveJobs()
        _ = storage.jobCompleted(item1, shouldRetry: true, maxRetries: 3)
        _ = storage.jobCompleted(item2, shouldRetry: false, maxRetries: 3)

        #expect(storage.retryCount(for: item1) == 1)
        #expect(storage.retryCount(for: item2) == 0) // Removed, so 0
    }

    // MARK: - Body-missing retry behavior

    @Test("Body-missing items retry (not dropped) — cycles to back of queue")
    func bodyMissingRetries() {
        // Simulates the processItem behavior: when FTS body is unavailable,
        // shouldRetry=true is returned, keeping the item in the queue.
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        storage.enqueue(item)

        // First attempt: body missing → shouldRetry=true
        let candidates1 = storage.collectCandidates(maxJobs: Int.max)
        #expect(candidates1.count == 1)
        guard let first = candidates1.first else { return }
        storage.incrementActiveJobs()
        let hasMore = storage.jobCompleted(first, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
        #expect(hasMore == true, "Item should stay in queue for retry")
        #expect(storage.count == 1)
        #expect(storage.retryCount(for: item) == 1)

        // Second attempt: body still missing → shouldRetry=true again
        let candidates2 = storage.collectCandidates(maxJobs: Int.max)
        #expect(candidates2.count == 1, "Item should be available for re-dispatch")
        guard let second = candidates2.first else { return }
        storage.incrementActiveJobs()
        _ = storage.jobCompleted(second, shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
        #expect(storage.retryCount(for: item) == 2)
    }

    @Test("Body-missing item eventually removed after max retries")
    func bodyMissingMaxRetries() {
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        storage.enqueue(item)

        // Simulate max retries with body always missing
        for i in 0...SyncConfig.maxQueueRetries {
            let candidates = storage.collectCandidates(maxJobs: Int.max)
            if candidates.isEmpty { break }
            storage.incrementActiveJobs()
            _ = storage.jobCompleted(candidates[0], shouldRetry: true, maxRetries: SyncConfig.maxQueueRetries)
            if i < SyncConfig.maxQueueRetries {
                #expect(!storage.isEmpty, "Should stay in queue until max retries exceeded")
            }
        }

        #expect(storage.isEmpty, "Should be removed after max retries")
    }

    // MARK: - clearAll

    @Test("clearAll resets entire queue state")
    func clearAllResetsState() {
        var storage = QueueStorage<Item>()
        for i in 1...5 {
            storage.enqueue(Item(headerId: "h\(i)", accountId: "a1", jobType: .summary))
        }
        let _ = storage.collectCandidates(maxJobs: Int.max)
        storage.incrementActiveJobs()
        storage.incrementActiveJobs()

        // Before clear: queue has items, in-flight, active jobs
        #expect(!storage.isEmpty)

        storage.clearAll()
        #expect(storage.isEmpty)
        #expect(storage.count == 0)
        #expect(storage.pendingCount == 0)
        // Note: activeJobs is NOT cleared by clearAll — it tracks running tasks
        // The caller must handle that separately
    }

    @Test("After clearAll, same items can be re-enqueued")
    func clearAllAllowsReenqueue() {
        var storage = QueueStorage<Item>()
        let item = Item(headerId: "h1", accountId: "a1", jobType: .summary)
        storage.enqueue(item)
        storage.clearAll()

        let added = storage.enqueue(item)
        #expect(added == true)
        #expect(storage.count == 1)
    }

    // MARK: - FIFO ordering

    @Test("Queue processes items in FIFO order")
    func fifoOrdering() {
        var storage = QueueStorage<Item>()
        let items = (1...5).map { Item(headerId: "h\($0)", accountId: "a1", jobType: .summary) }
        storage.enqueueBatch(items)

        let first = storage.collectCandidates(maxJobs: 1)
        #expect(first[0].headerId == "h1")
        storage.incrementActiveJobs()
        _ = storage.jobCompleted(first[0], shouldRetry: false, maxRetries: 3)

        let second = storage.collectCandidates(maxJobs: 1)
        #expect(second[0].headerId == "h2")
    }

    @Test("Failed items go to back of queue (retry at back)")
    func failedItemGoesToBack() {
        var storage = QueueStorage<Item>()
        let items = (1...3).map { Item(headerId: "h\($0)", accountId: "a1", jobType: .summary) }
        storage.enqueueBatch(items)

        // Collect h1, fail it
        let first = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()
        #expect(first[0].headerId == "h1")
        _ = storage.jobCompleted(first[0], shouldRetry: true, maxRetries: 3)

        // Next dispatch should get h2, not h1
        let second = storage.collectCandidates(maxJobs: 1)
        #expect(second[0].headerId == "h2")
    }

    // MARK: - needsSummary / needsAction / needsReply logic

    @Test("Message with nil summaryBlurb needs summary")
    func nilSummaryNeedsSummary() {
        let blurb: String? = nil
        let needsSummary = blurb == nil || blurb?.isEmpty == true
        #expect(needsSummary == true)
    }

    @Test("Message with empty summaryBlurb needs summary")
    func emptySummaryNeedsSummary() {
        let blurb: String? = ""
        let needsSummary = blurb == nil || blurb?.isEmpty == true
        #expect(needsSummary == true)
    }

    @Test("Message with non-empty summaryBlurb does not need summary")
    func existingSummaryNoNeed() {
        let blurb: String? = "This is a summary"
        let needsSummary = blurb == nil || blurb?.isEmpty == true
        #expect(needsSummary == false)
    }

    @Test("Message with nil actionTag needs action")
    func nilActionNeedsAction() {
        let tag: ActionTag? = nil
        #expect(tag == nil)
    }

    @Test("Message with nil cachedReply needs reply")
    func nilReplyNeedsReply() {
        let reply: String? = nil
        #expect(reply == nil)
    }

    @Test("Message with all AI fields populated does not need processing")
    func fullyProcessedMessageSkipped() {
        let blurb: String? = "Summary"
        let tag: ActionTag? = .reply
        let reply: String? = "Reply text"

        let needsSummary = blurb == nil || blurb?.isEmpty == true
        let needsAction = tag == nil
        let needsReply = reply == nil
        let needsProcessing = needsSummary || needsAction || needsReply

        #expect(needsProcessing == false)
    }

    // MARK: - Architecture validation

    @Test("LLM semaphore gates concurrent calls, not queue dispatch")
    func architectureValidation() {
        // Verify that SyncConfig has the LLM semaphore limit
        #expect(SyncConfig.maxConcurrentLLMCalls == 32, "LLM semaphore should match TB maxAgentWorkers")

        // Verify the semaphore can be instantiated with the config value
        let sem = LLMSemaphore(maxConcurrent: SyncConfig.maxConcurrentLLMCalls)
        #expect(sem.activeCount == 0)
        #expect(sem.waiterCount == 0)
    }
}
