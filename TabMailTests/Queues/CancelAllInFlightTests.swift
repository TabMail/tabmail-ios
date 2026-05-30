/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("QueueStorage cancelAllInFlight")
struct CancelAllInFlightTests {

    @Test("cancelAllInFlight resets all state")
    func resetsAllState() {
        var storage = QueueStorage<String>()
        storage.enqueueBatch(["a", "b", "c"])
        _ = storage.collectCandidates(maxJobs: 2) // a, b in-flight
        storage.incrementActiveJobs()
        storage.incrementActiveJobs()

        #expect(storage.inFlight.count == 2)
        #expect(storage.activeJobs == 2)
        #expect(storage.count == 3)

        storage.cancelAllInFlight()

        #expect(storage.inFlight.isEmpty)
        #expect(storage.activeJobs == 0)
        #expect(storage.count == 0)
        #expect(storage.isEmpty)
    }

    @Test("cancelAllInFlight clears enqueued set so repopulate can re-add")
    func clearsEnqueuedForRepopulate() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()

        // Before cancel: can't re-enqueue (dedup)
        #expect(storage.enqueue("a") == false)

        storage.cancelAllInFlight()

        // After cancel: can re-enqueue
        #expect(storage.enqueue("a") == true)
        #expect(storage.count == 1)
    }

    @Test("cancelAllInFlight clears recentlyCompleted to prevent semaphore race")
    func clearsRecentlyCompleted() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()
        // Complete the job — moves to recentlyCompleted
        _ = storage.jobCompleted("a", shouldRetry: false, maxRetries: 3)
        #expect(storage.enqueue("a") == false) // blocked by recentlyCompleted

        storage.cancelAllInFlight()

        // recentlyCompleted cleared — re-enqueue succeeds
        #expect(storage.enqueue("a") == true)
    }

    @Test("cancelAllInFlight with no in-flight items is safe no-op")
    func emptyQueueSafe() {
        var storage = QueueStorage<String>()
        storage.cancelAllInFlight()
        #expect(storage.isEmpty)
        #expect(storage.activeJobs == 0)
    }

    @Test("cancelAllInFlight clears retry counts")
    func clearsRetryCounts() {
        var storage = QueueStorage<String>()
        storage.enqueue("a")
        _ = storage.collectCandidates(maxJobs: 1)
        storage.incrementActiveJobs()
        _ = storage.jobCompleted("a", shouldRetry: true, maxRetries: 3)
        #expect(storage.retryCount(for: "a") == 1)

        storage.cancelAllInFlight()

        // Re-enqueue and check retry count is reset
        storage.enqueue("a")
        #expect(storage.retryCount(for: "a") == 0)
    }
}
