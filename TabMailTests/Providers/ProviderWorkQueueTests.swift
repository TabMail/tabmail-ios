/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ProviderWorkQueue - Concurrency Control")
struct ProviderWorkQueueConcurrencyTests {

    @Test("Concurrent operations limited to maxConcurrency")
    func concurrencyLimit() async {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 2)

        // Track concurrent operations
        let tracker = ConcurrencyTracker()

        // Launch 5 tasks that each hold a slot for 100ms
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try? await queue.execute(priority: .bodyFetch) {
                        await tracker.enter()
                        try? await Task.sleep(for: .milliseconds(100))
                        await tracker.exit()
                    }
                }
            }
        }

        let maxSeen = await tracker.maxConcurrent
        #expect(maxSeen <= 2, "Max concurrent should not exceed maxConcurrency=2, got \(maxSeen)")
        #expect(maxSeen == 2, "Should reach maxConcurrency when enough work available")
    }

    @Test("Single concurrency serializes operations")
    func singleConcurrency() async {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 1)

        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try? await queue.execute(priority: .bodyFetch) {
                        await tracker.enter()
                        try? await Task.sleep(for: .milliseconds(50))
                        await tracker.exit()
                    }
                }
            }
        }

        let maxSeen = await tracker.maxConcurrent
        #expect(maxSeen == 1, "Single concurrency should serialize, got max=\(maxSeen)")
    }

    @Test("Execute returns result from work closure")
    func executeReturnsResult() async throws {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 2)

        let result = try await queue.execute(priority: .bodyFetch) {
            42
        }
        #expect(result == 42)
    }

    @Test("Execute propagates errors from work closure")
    func executePropagatesErrors() async {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 2)

        do {
            let _: Int = try await queue.execute(priority: .bodyFetch) {
                throw TestError.intentional
            }
            Issue.record("Should have thrown")
        } catch {
            #expect(error is TestError)
        }
    }

    @Test("Slot released on error so other work can proceed")
    func slotReleasedOnError() async throws {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 1)

        // First op throws
        do {
            let _: Void = try await queue.execute(priority: .bodyFetch) {
                throw TestError.intentional
            }
        } catch {}

        // Second op should still execute (slot was released)
        let result = try await queue.execute(priority: .bodyFetch) {
            "success"
        }
        #expect(result == "success")
    }
}

@Suite("ProviderWorkQueue - Priority Tiers")
struct ProviderWorkQueuePriorityTests {

    @Test("User actions execute before header fetch and body fetch")
    func userActionPriority() async throws {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 1)

        let order = OrderTracker()

        // Fill the single slot
        let blocker = Task {
            try? await queue.execute(priority: .bodyFetch) {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        // Give the blocker time to acquire the slot
        try await Task.sleep(for: .milliseconds(50))

        // Queue work at different priorities — all will wait for the blocker
        let body = Task { try? await queue.execute(priority: .bodyFetch) { await order.record("body") } }
        let header = Task { try? await queue.execute(priority: .headerFetch) { await order.record("header") } }
        let user = Task { try? await queue.execute(priority: .userAction) { await order.record("user") } }

        // Give tasks time to enqueue
        try await Task.sleep(for: .milliseconds(50))

        await blocker.value
        await body.value
        await header.value
        await user.value

        let sequence = await order.sequence
        #expect(sequence == ["user", "header", "body"], "Expected user > header > body, got \(sequence)")
    }

    @Test("Same-tier operations are FIFO")
    func sameTierFIFO() async throws {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 1)

        let order = OrderTracker()

        // Fill the single slot
        let blocker = Task {
            try? await queue.execute(priority: .bodyFetch) {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        // Queue 3 body-fetch items
        let t1 = Task { try? await queue.execute(priority: .bodyFetch) { await order.record("first") } }
        try await Task.sleep(for: .milliseconds(10))
        let t2 = Task { try? await queue.execute(priority: .bodyFetch) { await order.record("second") } }
        try await Task.sleep(for: .milliseconds(10))
        let t3 = Task { try? await queue.execute(priority: .bodyFetch) { await order.record("third") } }

        await blocker.value
        await t1.value
        await t2.value
        await t3.value

        let sequence = await order.sequence
        #expect(sequence == ["first", "second", "third"], "Same-tier should be FIFO, got \(sequence)")
    }
}

@Suite("ProviderWorkQueue - Provider Access")
struct ProviderWorkQueueProviderTests {

    @Test("Provider reference is accessible via nonisolated let")
    func providerAccessible() {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 2)
        #expect(queue.provider is WorkQueueMockProvider)
    }

    @Test("activeOperations and waitingCount report correctly")
    func counters() async throws {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 1)

        let active = await queue.activeOperations
        let waiting = await queue.waitingCount
        #expect(active == 0)
        #expect(waiting == 0)
    }
}

// MARK: - Test Helpers

private enum TestError: Error {
    case intentional
}

private actor ConcurrencyTracker {
    private var current = 0
    var maxConcurrent = 0

    func enter() {
        current += 1
        if current > maxConcurrent { maxConcurrent = current }
    }

    func exit() {
        current -= 1
    }
}

private actor OrderTracker {
    var sequence: [String] = []

    func record(_ label: String) {
        sequence.append(label)
    }
}

@Suite("ProviderWorkQueue - Dynamic Concurrency")
struct ProviderWorkQueueDynamicTests {

    @Test("updateMaxConcurrency increases capacity")
    func updateMaxConcurrencyIncreases() async {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 2)

        let tracker = ConcurrencyTracker()

        // Increase to 4
        await queue.updateMaxConcurrency(4)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try? await queue.execute(priority: .bodyFetch) {
                        await tracker.enter()
                        try? await Task.sleep(for: .milliseconds(100))
                        await tracker.exit()
                    }
                }
            }
        }

        let maxSeen = await tracker.maxConcurrent
        #expect(maxSeen <= 4, "Should not exceed updated maxConcurrency=4, got \(maxSeen)")
        #expect(maxSeen >= 3, "Should reach near updated max with enough work, got \(maxSeen)")
    }

    @Test("updateMaxConcurrency ignores lower values")
    func updateMaxConcurrencyIgnoresLower() async {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 4)

        // Try to lower — should be ignored
        await queue.updateMaxConcurrency(2)

        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try? await queue.execute(priority: .bodyFetch) {
                        await tracker.enter()
                        try? await Task.sleep(for: .milliseconds(100))
                        await tracker.exit()
                    }
                }
            }
        }

        let maxSeen = await tracker.maxConcurrent
        #expect(maxSeen <= 4, "Max should stay at 4")
        #expect(maxSeen >= 3, "Should still reach near original max=4")
    }

    @Test("updateMaxConcurrency wakes queued waiters")
    func updateMaxConcurrencyWakesWaiters() async throws {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 1)

        let order = OrderTracker()

        // Fill the single slot with a long-running task
        let blocker = Task {
            try? await queue.execute(priority: .bodyFetch) {
                try? await Task.sleep(for: .milliseconds(300))
                await order.record("blocker")
            }
        }

        // Give blocker time to acquire slot
        try await Task.sleep(for: .milliseconds(50))

        // Queue two more — they'll wait since maxConcurrency=1
        let t1 = Task { try? await queue.execute(priority: .bodyFetch) { await order.record("t1") } }
        let t2 = Task { try? await queue.execute(priority: .bodyFetch) { await order.record("t2") } }

        try await Task.sleep(for: .milliseconds(50))

        // Expand capacity — should wake waiting tasks
        await queue.updateMaxConcurrency(3)

        await blocker.value
        await t1.value
        await t2.value

        let sequence = await order.sequence
        #expect(sequence.count == 3, "All three tasks should complete")
    }
}

@Suite("ProviderWorkQueue - Cancellation")
struct ProviderWorkQueueCancellationTests {

    @Test("Cancelled waiter throws CancellationError without running work")
    func cancelledWaiterThrows() async throws {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 1)

        let order = OrderTracker()

        // Fill the single slot
        let blocker = Task {
            try? await queue.execute(priority: .bodyFetch) {
                try? await Task.sleep(for: .milliseconds(300))
                await order.record("blocker")
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        // Queue a waiter, then cancel it while it waits for a slot.
        // The closure returns a value to force the generic throwing overload —
        // a bare Void closure resolves to the fire-and-forget variant, which is
        // intentionally NOT cancellation-aware.
        let waiter = Task {
            do {
                let _: Int = try await queue.execute(priority: .userAction) {
                    await order.record("waiter-work")
                    return 1
                }
                await order.record("waiter-completed")
            } catch is CancellationError {
                await order.record("waiter-cancelled")
            } catch {
                await order.record("waiter-other-error")
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await waiter.value

        // Cancellation must resolve BEFORE the blocker releases its slot —
        // the waiter never gets a slot and its work never runs.
        let early = await order.sequence
        #expect(early == ["waiter-cancelled"], "Cancelled waiter should throw immediately, got \(early)")

        await blocker.value
        let sequence = await order.sequence
        #expect(!sequence.contains("waiter-work"), "Cancelled waiter's work must not run")
    }

    @Test("Cancelled waiter does not corrupt slot accounting")
    func cancelledWaiterSlotAccounting() async throws {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 1)

        // Fill the single slot
        let blocker = Task {
            try? await queue.execute(priority: .bodyFetch) {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        // Queue and cancel a waiter (typed return forces the throwing overload)
        let waiter = Task {
            let _: Int = try await queue.execute(priority: .userAction) { 1 }
        }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        _ = try? await waiter.value

        await blocker.value

        // Queue must still grant slots normally after the cancelled waiter
        let result = try await queue.execute(priority: .bodyFetch) { "alive" }
        #expect(result == "alive")
        #expect(await queue.activeOperations == 0)
        #expect(await queue.waitingCount == 0)
    }

    @Test("Already-cancelled task throws before acquiring a slot")
    func preCancelledTaskThrows() async throws {
        let provider = WorkQueueMockProvider()
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 2)

        let order = OrderTracker()
        let task = Task {
            // Ensure cancellation lands before execute is reached
            try? await Task.sleep(for: .milliseconds(100))
            do {
                // Typed return forces the generic throwing (cancellation-aware) overload
                let _: Int = try await queue.execute(priority: .userAction) {
                    await order.record("work")
                    return 1
                }
            } catch is CancellationError {
                await order.record("cancelled")
            }
        }
        task.cancel()
        // The Task closure is throwing (queue.execute can rethrow non-cancellation
        // errors past the CancellationError catch), so `.value` must be try'd.
        _ = try? await task.value

        let sequence = await order.sequence
        #expect(sequence == ["cancelled"], "Pre-cancelled task must not run work, got \(sequence)")
    }
}

/// Minimal mock provider for queue tests — no real network operations.
private actor WorkQueueMockProvider: EmailProvider {
    func connect() async throws {}
    func disconnect() async throws {}
    func fetchFolders() async throws -> [FolderInfo] { [] }
    func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo] { [] }
    func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo {
        FullMessageInfo(header: MessageHeaderInfo(
            messageId: id, rfc822MessageId: nil, inReplyTo: nil, references: [], threadId: nil,
            subject: "", from: "", fromAddress: "", to: "", cc: "", bcc: "",
            replyTo: nil, date: Date(), snippet: "", isRead: false, isFlagged: false,
            hasAttachments: false, isReplied: false, isForwarded: false, actionTag: nil
        ), htmlBody: nil, textBody: nil)
    }
    func search(query: String, folder: String, after: Date?, before: Date?, from: String?, to: String?) async throws -> [MessageHeaderInfo] { [] }
    func markRead(ids: [String], folder: String) async throws {}
    func markUnread(ids: [String], folder: String) async throws {}
    func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {}
    func move(ids: [String], from: String, to: String) async throws {}
    func send(draft: DraftMessage) async throws {}
    func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool { true }
    func saveDraft(_ draft: DraftMessage, existingIdentity: DraftDeleteIdentity?, draftsFolderPath: String) async throws -> DraftSaveOutcome { .unaddressable }
    func deleteDraft(identity: DraftDeleteIdentity) async throws {}
    func fetchHistory(since historyId: String) async throws -> HistoryResponse? { nil }
    func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo] { [] }
    func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult] { [] }
}
