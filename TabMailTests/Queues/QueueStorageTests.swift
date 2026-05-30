/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("QueueStorage")
struct QueueStorageTests {

    // MARK: - Enqueue

    @Test("enqueue adds item to queue")
    func enqueueAdds() {
        var storage = QueueStorage<String>()
        let added = storage.enqueue("item1")
        #expect(added == true)
        #expect(storage.count == 1)
        #expect(!storage.isEmpty)
    }

    @Test("enqueue deduplicates same item")
    func enqueueDedups() {
        var storage = QueueStorage<String>()
        let first = storage.enqueue("item1")
        let second = storage.enqueue("item1")
        #expect(first == true)
        #expect(second == false)
        #expect(storage.count == 1)
    }

    @Test("enqueueBatch adds multiple items, deduped")
    func enqueueBatch() {
        var storage = QueueStorage<String>()
        let count = storage.enqueueBatch(["a", "b", "a", "c", "b"])
        #expect(count == 3)
        #expect(storage.count == 3)
    }

    @Test("enqueueBatch deduplicates against existing items")
    func enqueueBatchDedupExisting() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        let count = storage.enqueueBatch(["a", "b", "c"])
        #expect(count == 2) // b and c are new
        #expect(storage.count == 3)
    }

    // MARK: - collectCandidates

    @Test("collectCandidates returns up to maxJobs items")
    func collectCandidatesLimit() {
        var storage = QueueStorage<String>()
        storage.enqueueBatch(["a", "b", "c", "d", "e"])
        let candidates = storage.collectCandidates(maxJobs: 3)
        #expect(candidates.count == 3)
    }

    @Test("collectCandidates respects activeJobs ceiling")
    func collectCandidatesActiveJobsCeiling() {
        var storage = QueueStorage<String>()
        storage.enqueueBatch(["a", "b", "c"])
        storage.incrementActiveJobs()
        storage.incrementActiveJobs()
        let candidates = storage.collectCandidates(maxJobs: 3)
        #expect(candidates.count == 1) // maxJobs(3) - activeJobs(2) = 1
    }

    @Test("collectCandidates skips in-flight items")
    func collectCandidatesSkipsInFlight() {
        var storage = QueueStorage<String>()
        storage.enqueueBatch(["a", "b", "c"])
        // First collect puts items in-flight
        _ = storage.collectCandidates(maxJobs: 2)
        // Second collect should skip those 2 in-flight items
        let candidates2 = storage.collectCandidates(maxJobs: 5)
        #expect(candidates2.count == 1) // only "c" remains
    }

    @Test("collectCandidates moves dispatched items to back of queue")
    func collectCandidatesMoveToBack() {
        var storage = QueueStorage<String>()
        storage.enqueueBatch(["a", "b", "c"])
        let first = storage.collectCandidates(maxJobs: 2) // dispatches a, b
        #expect(first == ["a", "b"])
        // After moving to back: queue = [c, a, b], a and b in-flight
        // Complete a to clear it from in-flight
        _ = storage.jobCompleted("a", shouldRetry: false, maxRetries: 3)
        _ = storage.jobCompleted("b", shouldRetry: false, maxRetries: 3)
        // Now collect should get c first (it's at front)
        let second = storage.collectCandidates(maxJobs: 5)
        #expect(second.first == "c")
    }

    @Test("collectCandidates returns FIFO order")
    func collectCandidatesFIFO() {
        var storage = QueueStorage<String>()
        storage.enqueue("first")
        storage.enqueue("second")
        storage.enqueue("third")
        let candidates = storage.collectCandidates(maxJobs: 3)
        #expect(candidates == ["first", "second", "third"])
    }

    @Test("collectCandidates returns empty when all in-flight")
    func collectCandidatesAllInFlight() {
        var storage = QueueStorage<String>()
        storage.enqueueBatch(["a", "b"])
        _ = storage.collectCandidates(maxJobs: 5) // all in-flight now
        let candidates = storage.collectCandidates(maxJobs: 5)
        #expect(candidates.isEmpty)
    }

    // MARK: - incrementActiveJobs

    @Test("incrementActiveJobs tracks concurrency")
    func incrementActiveJobs() {
        var storage = QueueStorage<String>()
        #expect(storage.activeJobs == 0)
        storage.incrementActiveJobs()
        #expect(storage.activeJobs == 1)
        storage.incrementActiveJobs()
        #expect(storage.activeJobs == 2)
    }

    // MARK: - jobCompleted

    @Test("jobCompleted decrements activeJobs and clears inFlight")
    func jobCompletedBasic() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()
        #expect(storage.activeJobs == 1)
        _ = storage.jobCompleted("a", shouldRetry: false, maxRetries: 3)
        #expect(storage.activeJobs == 0)
    }

    @Test("jobCompleted with shouldRetry=true keeps item in queue")
    func jobCompletedRetry() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()
        let hasMore = storage.jobCompleted("a", shouldRetry: true, maxRetries: 3)
        #expect(hasMore == true) // item still in queue
        #expect(storage.retryCount(for: "a") == 1)
        #expect(storage.count == 1) // still there
    }

    @Test("jobCompleted with shouldRetry=true exceeding maxRetries drops item")
    func jobCompletedMaxRetries() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        // maxRetries=3 means up to 3 retries allowed (count <= 3 stays, count > 3 drops)
        // So we need 4 failures to exceed maxRetries
        for _ in 0..<4 {
            _ = storage.collectCandidates(maxJobs: 1)
            storage.incrementActiveJobs()
            _ = storage.jobCompleted("a", shouldRetry: true, maxRetries: 3)
        }
        #expect(storage.count == 0)
    }

    @Test("jobCompleted with shouldRetry=false removes item completely")
    func jobCompletedSuccess() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()
        _ = storage.jobCompleted("a", shouldRetry: false, maxRetries: 3)
        #expect(storage.count == 0)
        #expect(storage.isEmpty)
        // Item is in recentlyCompleted — re-enqueue blocked to prevent churn
        let blocked = storage.enqueue("a")
        #expect(blocked == false)
        // After reset, re-enqueue works
        storage.resetRecentlyCompleted()
        let added = storage.enqueue("a")
        #expect(added == true)
    }

    @Test("jobCompleted returns hasMore correctly")
    func jobCompletedHasMore() {
        var storage = QueueStorage<String>()
        storage.enqueueBatch(["a", "b"])
        _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()
        let hasMore = storage.jobCompleted("a", shouldRetry: false, maxRetries: 3)
        #expect(hasMore == true) // "b" still in queue
    }

    @Test("jobCompleted returns false when queue empty after completion")
    func jobCompletedNoMore() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()
        let hasMore = storage.jobCompleted("a", shouldRetry: false, maxRetries: 3)
        #expect(hasMore == false)
    }

    // MARK: - releaseInFlight

    @Test("releaseInFlight does NOT decrement activeJobs")
    func releaseInFlightNoActiveJobsDecrement() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        _ = storage.collectCandidates(maxJobs: 1)
        // Note: NOT calling incrementActiveJobs — simulates pre-launch failure
        #expect(storage.activeJobs == 0)
        _ = storage.releaseInFlight("a", shouldRetry: true, maxRetries: 3)
        #expect(storage.activeJobs == 0) // unchanged
        #expect(storage.count == 1) // item back in queue
    }

    @Test("releaseInFlight with retry exceeding maxRetries drops item")
    func releaseInFlightMaxRetries() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        // maxRetries=3: count <= 3 stays, count > 3 drops → need 4 failures
        for _ in 0..<4 {
            _ = storage.collectCandidates(maxJobs: 1)
            _ = storage.releaseInFlight("a", shouldRetry: true, maxRetries: 3)
        }
        #expect(storage.count == 0)
    }

    // MARK: - removeFromQueue

    @Test("removeFromQueue cleans all tracking sets")
    func removeFromQueue() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        _ = storage.collectCandidates(maxJobs: 1) // puts in inFlight
        storage.removeFromQueue("a")
        #expect(storage.count == 0)
        #expect(storage.isEmpty)
        // Can re-enqueue
        let added = storage.enqueue("a")
        #expect(added == true)
    }

    // MARK: - clearAll

    @Test("clearAll resets queue, inFlight, enqueued, retryCount")
    func clearAll() {
        var storage = QueueStorage<String>()
        storage.enqueueBatch(["a", "b", "c"])
        _ = storage.collectCandidates(maxJobs: 2)
        storage.clearAll()
        #expect(storage.isEmpty)
        #expect(storage.count == 0)
        #expect(storage.pendingCount == 0)
    }

    // MARK: - pendingCount

    @Test("pendingCount = count - inFlight.count")
    func pendingCount() {
        var storage = QueueStorage<String>()
        storage.enqueueBatch(["a", "b", "c", "d", "e"])
        _ = storage.collectCandidates(maxJobs: 2) // 2 in-flight
        #expect(storage.pendingCount == 3) // 5 - 2
    }

    // MARK: - retryCount

    @Test("retryCount returns 0 for new items")
    func retryCountZero() {
        let storage = QueueStorage<String>()
        #expect(storage.retryCount(for: "nonexistent") == 0)
    }

    @Test("retryCount increments across retries")
    func retryCountIncrements() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()
        _ = storage.jobCompleted("a", shouldRetry: true, maxRetries: 10)
        #expect(storage.retryCount(for: "a") == 1)
        _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()
        _ = storage.jobCompleted("a", shouldRetry: true, maxRetries: 10)
        #expect(storage.retryCount(for: "a") == 2)
    }

    // MARK: - Re-enqueue after removal

    @Test("Re-enqueue after removal is allowed")
    func reEnqueueAfterRemoval() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        storage.removeFromQueue("a")
        let added = storage.enqueue("a")
        #expect(added == true)
        #expect(storage.count == 1)
    }
}
