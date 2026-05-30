/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("QueueStorage Edge Cases")
struct QueueStorageEdgeCaseTests {

    @Test("Enqueue same item twice returns false on second")
    func enqueueDuplicate() {
        var storage = QueueStorage<String>()
        #expect(storage.enqueue("a") == true)
        #expect(storage.enqueue("a") == false)
        #expect(storage.count == 1)
    }

    @Test("enqueueBatch with all duplicates returns 0")
    func enqueueBatchAllDuplicates() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        storage.enqueue("b")
        let added = storage.enqueueBatch(["a", "b"])
        #expect(added == 0)
    }

    @Test("collectCandidates with empty queue returns empty")
    func collectCandidatesEmpty() {
        var storage = QueueStorage<String>()
        let candidates = storage.collectCandidates(maxJobs: 5)
        #expect(candidates.isEmpty)
    }

    @Test("collectCandidates respects maxJobs minus activeJobs")
    func collectCandidatesMaxJobsLimit() {
        var storage = QueueStorage<Int>()
        for i in 0..<10 { storage.enqueue(i) }
        storage.incrementActiveJobs() // 1 active
        storage.incrementActiveJobs() // 2 active
        let candidates = storage.collectCandidates(maxJobs: 5)
        #expect(candidates.count == 3) // 5 - 2 = 3
    }

    @Test("collectCandidates skips in-flight items")
    func collectCandidatesSkipsInFlight() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        storage.enqueue("b")
        storage.enqueue("c")
        // Collect a, b (marks them in-flight)
        _ = storage.collectCandidates(maxJobs: 2)
        // Now collect again — should skip a, b (in-flight) and get c
        let next = storage.collectCandidates(maxJobs: 3)
        #expect(next.count == 1)
        #expect(next[0] == "c")
    }

    @Test("jobCompleted with shouldRetry cycles item to back")
    func jobCompletedRetry() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        storage.enqueue("b")
        let candidates = storage.collectCandidates(maxJobs: 2)
        for _ in candidates { storage.incrementActiveJobs() }

        // Complete "a" with retry
        let hasMore = storage.jobCompleted("a", shouldRetry: true, maxRetries: 3)
        #expect(hasMore == true)
        #expect(storage.count == 2) // "a" still in queue
        #expect(storage.retryCount(for: "a") == 1)
    }

    @Test("jobCompleted exceeding maxRetries removes item")
    func jobCompletedExceedMaxRetries() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        let _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()

        // Exhaust retries
        storage.jobCompleted("a", shouldRetry: true, maxRetries: 0)
        #expect(storage.count == 0) // Removed after exceeding max
    }

    @Test("releaseInFlight does not decrement activeJobs")
    func releaseInFlightNoActiveDecrement() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        storage.enqueue("b")
        let _ = storage.collectCandidates(maxJobs: 2)
        storage.incrementActiveJobs()
        storage.incrementActiveJobs()

        // Release "a" without decrementing active
        storage.releaseInFlight("a", shouldRetry: true, maxRetries: 3)
        #expect(storage.activeJobs == 2) // Not decremented
    }

    @Test("clearAll resets everything")
    func clearAllResetsEverything() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        storage.enqueue("b")
        storage.enqueue("c")
        let _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()

        storage.clearAll()
        #expect(storage.count == 0)
        #expect(storage.isEmpty == true)
        #expect(storage.pendingCount == 0)
    }

    @Test("pendingCount is count minus inFlight")
    func pendingCountCalculation() {
        var storage = QueueStorage<Int>()
        for i in 0..<5 { storage.enqueue(i) }
        #expect(storage.pendingCount == 5)

        let _ = storage.collectCandidates(maxJobs: 2) // 2 in-flight
        #expect(storage.pendingCount == 3) // 5 - 2
    }

    @Test("removeFromQueue clears all tracking for item")
    func removeFromQueueClearsAll() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        let _ = storage.collectCandidates(maxJobs: 1) // mark in-flight
        storage.removeFromQueue("a")

        #expect(storage.count == 0)
        #expect(storage.retryCount(for: "a") == 0)
        // Re-enqueue should work (dedup cleared)
        #expect(storage.enqueue("a") == true)
    }

    @Test("Can re-enqueue after removal")
    func reEnqueueAfterRemoval() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        storage.removeFromQueue("a")
        #expect(storage.enqueue("a") == true)
        #expect(storage.count == 1)
    }

    @Test("FIFO ordering preserved")
    func fifoOrdering() {
        var storage = QueueStorage<Int>()
        for i in 0..<5 { storage.enqueue(i) }
        let candidates = storage.collectCandidates(maxJobs: 5)
        #expect(candidates == [0, 1, 2, 3, 4])
    }

    @Test("retryCount starts at zero")
    func retryCountStartsAtZero() {
        let storage = QueueStorage<String>()
        #expect(storage.retryCount(for: "nonexistent") == 0)
    }
}
