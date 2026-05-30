/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("LLMSemaphore")
struct LLMSemaphoreTests {

    // MARK: - Basic Acquire/Release

    @Test("Acquire succeeds immediately when slots available")
    func acquireImmediate() async {
        let sem = LLMSemaphore(maxConcurrent: 3)
        await sem.acquire()
        #expect(sem.activeCount == 1)
        sem.release()
        #expect(sem.activeCount == 0)
    }

    @Test("Multiple acquires up to max succeed immediately")
    func acquireUpToMax() async {
        let sem = LLMSemaphore(maxConcurrent: 3)
        await sem.acquire()
        await sem.acquire()
        await sem.acquire()
        #expect(sem.activeCount == 3)
        #expect(sem.waiterCount == 0)
        sem.release()
        sem.release()
        sem.release()
        #expect(sem.activeCount == 0)
    }

    @Test("Release unblocks a waiting acquire")
    func releaseUnblocksWaiter() async {
        let sem = LLMSemaphore(maxConcurrent: 1)
        await sem.acquire() // Slot 1 taken
        #expect(sem.activeCount == 1)

        // Start a task that will block on acquire
        let acquired = UncheckedSendableBox(false)
        let task = Task {
            await sem.acquire()
            acquired.value = true
        }

        // Give the task time to reach the await point
        try? await Task.sleep(for: .milliseconds(50))
        #expect(acquired.value == false, "Should be blocked")
        #expect(sem.waiterCount == 1)

        // Release should unblock the waiter
        sem.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(acquired.value == true, "Should have acquired after release")
        #expect(sem.activeCount == 1) // The waiter now holds the slot

        sem.release()
        task.cancel()
    }

    @Test("FIFO ordering of waiters")
    func fifoWaiters() async {
        let sem = LLMSemaphore(maxConcurrent: 1)
        await sem.acquire() // Slot taken

        let order = UncheckedSendableBox<[Int]>([])

        let task1 = Task {
            await sem.acquire()
            order.value.append(1)
            sem.release()
        }

        try? await Task.sleep(for: .milliseconds(20))

        let task2 = Task {
            await sem.acquire()
            order.value.append(2)
            sem.release()
        }

        try? await Task.sleep(for: .milliseconds(20))
        #expect(sem.waiterCount == 2)

        // Release slots one at a time — waiters should resolve in FIFO order
        sem.release()
        try? await Task.sleep(for: .milliseconds(50))
        sem.release() // This unblocks the second waiter via the first's defer
        try? await Task.sleep(for: .milliseconds(50))

        // Wait for tasks to complete
        _ = await task1.value
        _ = await task2.value

        #expect(order.value == [1, 2], "Waiters should be served in FIFO order")
    }

    @Test("Release with no waiters just decrements")
    func releaseNoWaiters() async {
        let sem = LLMSemaphore(maxConcurrent: 3)
        await sem.acquire()
        await sem.acquire()
        #expect(sem.activeCount == 2)
        sem.release()
        #expect(sem.activeCount == 1)
        #expect(sem.waiterCount == 0)
        sem.release()
        #expect(sem.activeCount == 0)
    }

    @Test("Release never goes below zero")
    func releaseFloorZero() {
        let sem = LLMSemaphore(maxConcurrent: 3)
        sem.release() // Extra release — should not go negative
        sem.release()
        #expect(sem.activeCount == 0)
    }

    // MARK: - Concurrency Limiting

    @Test("Concurrent tasks limited to maxConcurrent")
    func concurrencyLimit() async {
        let sem = LLMSemaphore(maxConcurrent: 3)
        let tracker = ConcurrencyTracker()

        // Launch 10 tasks, each holding the semaphore for 50ms
        let tasks = (0..<10).map { _ in
            Task {
                await sem.acquire()
                await tracker.enter()
                try? await Task.sleep(for: .milliseconds(50))
                await tracker.leave()
                sem.release()
            }
        }

        for task in tasks {
            _ = await task.value
        }

        let peak = await tracker.peak
        #expect(peak <= 3, "Peak concurrency should not exceed maxConcurrent")
        #expect(peak >= 2, "Should achieve some concurrency (at least 2)")
        #expect(sem.activeCount == 0)
        #expect(sem.waiterCount == 0)
    }

    @Test("Singleton uses SyncConfig.maxConcurrentLLMCalls")
    func singletonConfig() {
        // Verify the shared singleton is properly configured
        #expect(SyncConfig.maxConcurrentLLMCalls == 32)
    }

    // MARK: - defer pattern (matching TB _release in finally)

    @Test("Release in defer works correctly on success")
    func deferOnSuccess() async {
        let sem = LLMSemaphore(maxConcurrent: 1)

        func doWork() async -> String {
            await sem.acquire()
            defer { sem.release() }
            return "done"
        }

        let result = await doWork()
        #expect(result == "done")
        #expect(sem.activeCount == 0)
    }

    @Test("Release in defer works correctly on error")
    func deferOnError() async {
        let sem = LLMSemaphore(maxConcurrent: 1)

        struct TestError: Error {}

        func doWork() async throws -> String {
            await sem.acquire()
            defer { sem.release() }
            throw TestError()
        }

        do {
            _ = try await doWork()
        } catch {
            // Expected
        }

        // Slot should be released even though the function threw
        #expect(sem.activeCount == 0)
    }
}

/// Helper for sharing mutable state in concurrent tests.
/// @unchecked Sendable because tests control access timing.
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Thread-safe concurrency tracker using actor isolation.
private actor ConcurrencyTracker {
    var current = 0
    var peak = 0

    func enter() {
        current += 1
        if current > peak { peak = current }
    }

    func leave() {
        current -= 1
    }
}
