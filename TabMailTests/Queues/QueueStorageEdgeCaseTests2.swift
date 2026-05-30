/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("QueueStorage Robustness & Edge Cases")
struct QueueStorageRobustnessTests {

    @Test("Re-enqueue after maxRetry drop gets fresh retry count")
    func reEnqueueAfterDrop() {
        var storage = QueueStorage<String>()

        // Enqueue, simulate failures. maxRetries=2 means count <= 2 stays, count > 2 drops.
        // So 3 failures needed to exceed maxRetries=2.
        storage.enqueue("item1")
        for _ in 0..<3 {
            _ = storage.collectCandidates(maxJobs: 1)
            storage.incrementActiveJobs()
            _ = storage.jobCompleted("item1", shouldRetry: true, maxRetries: 2)
        }

        // After exceeding maxRetries, item should be dropped
        #expect(storage.isEmpty)

        // Re-enqueue should succeed with fresh retry count
        let added = storage.enqueue("item1")
        #expect(added == true)
        #expect(storage.retryCount(for: "item1") == 0)
    }

    @Test("collectCandidates respects maxJobs limit")
    func collectRespectsMaxJobs() {
        var storage = QueueStorage<Int>()
        for i in 0..<10 {
            storage.enqueue(i)
        }

        let candidates = storage.collectCandidates(maxJobs: 3)
        #expect(candidates.count == 3)
    }

    @Test("collectCandidates with active jobs fills remaining slots")
    func collectFillsRemainingSlots() {
        var storage = QueueStorage<Int>()
        for i in 0..<10 {
            storage.enqueue(i)
        }

        // Take 2 candidates and mark them active
        let first = storage.collectCandidates(maxJobs: 5)
        #expect(first.count == 5)
        for _ in first {
            storage.incrementActiveJobs()
        }

        // Now activeJobs = 5, maxJobs = 5, should collect 0
        let second = storage.collectCandidates(maxJobs: 5)
        #expect(second.isEmpty)
    }

    @Test("jobCompleted with shouldRetry=false removes item permanently")
    func noRetryRemovesPermanently() {
        var storage = QueueStorage<String>()
        storage.enqueue("item")
        _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()

        let hasMore = storage.jobCompleted("item", shouldRetry: false, maxRetries: 3)
        #expect(hasMore == false)
        #expect(storage.isEmpty)

        // Item is in recentlyCompleted — re-enqueue blocked to prevent churn
        #expect(storage.enqueue("item") == false)
        // After reset, re-enqueue works
        storage.resetRecentlyCompleted()
        #expect(storage.enqueue("item") == true)
    }

    @Test("clearAll removes queue state")
    func clearAllRemovesState() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        storage.enqueue("b")
        storage.enqueue("c")
        _ = storage.collectCandidates(maxJobs: 1)

        storage.clearAll()
        #expect(storage.isEmpty)
        #expect(storage.count == 0)
    }

    @Test("Dedup prevents duplicate enqueue")
    func dedupPrevents() {
        var storage = QueueStorage<String>()
        #expect(storage.enqueue("item") == true)
        #expect(storage.enqueue("item") == false) // Duplicate
        #expect(storage.count == 1)
    }

    @Test("enqueueBatch returns count of new items only")
    func batchReturnsNewCount() {
        var storage = QueueStorage<Int>()
        storage.enqueue(1)
        storage.enqueue(2)

        let added = storage.enqueueBatch([2, 3, 4, 5])
        #expect(added == 3) // 2 was already enqueued
        #expect(storage.count == 5)
    }

    @Test("pendingCount excludes in-flight items")
    func pendingExcludesInFlight() {
        var storage = QueueStorage<Int>()
        for i in 0..<5 {
            storage.enqueue(i)
        }

        let candidates = storage.collectCandidates(maxJobs: 2)
        #expect(candidates.count == 2)
        for _ in candidates {
            storage.incrementActiveJobs()
        }

        #expect(storage.pendingCount == 3) // 5 total - 2 in-flight
    }

    @Test("removeFromQueue clears all tracking for item")
    func removeFromQueueClearsAll() {
        var storage = QueueStorage<String>()
        storage.enqueue("item")

        storage.removeFromQueue("item")
        #expect(storage.isEmpty)
        // Should be able to re-add after explicit removal
        #expect(storage.enqueue("item") == true)
    }

    @Test("FIFO ordering preserved across enqueue/collect cycles")
    func fifoPreserved() {
        var storage = QueueStorage<String>()
        storage.enqueue("first")
        storage.enqueue("second")
        storage.enqueue("third")

        let batch1 = storage.collectCandidates(maxJobs: 1)
        #expect(batch1 == ["first"])
        storage.incrementActiveJobs()

        // Complete first, collect next
        _ = storage.jobCompleted("first", shouldRetry: false, maxRetries: 3)

        let batch2 = storage.collectCandidates(maxJobs: 1)
        #expect(batch2 == ["second"])
    }

    @Test("Retry re-enqueues at end of queue")
    func retryGoesToEnd() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        storage.enqueue("b")
        storage.enqueue("c")

        // Collect "a" and fail it
        let first = storage.collectCandidates(maxJobs: 1)
        #expect(first == ["a"])
        storage.incrementActiveJobs()
        _ = storage.jobCompleted("a", shouldRetry: true, maxRetries: 3)

        // Next collect should get "b" (not "a" again)
        let second = storage.collectCandidates(maxJobs: 1)
        #expect(second == ["b"])
    }

    @Test("Large batch stress test: 1000 items")
    func largeBatchStress() {
        var storage = QueueStorage<Int>()
        let items = Array(0..<1000)
        let added = storage.enqueueBatch(items)
        #expect(added == 1000)
        #expect(storage.count == 1000)

        // Collect all in batches of 50
        var collected = 0
        while storage.pendingCount > 0 {
            let batch = storage.collectCandidates(maxJobs: 50)
            for _ in batch {
                storage.incrementActiveJobs()
            }
            collected += batch.count
            for item in batch {
                _ = storage.jobCompleted(item, shouldRetry: false, maxRetries: 3)
            }
        }
        #expect(collected == 1000)
        #expect(storage.isEmpty)
    }
}
