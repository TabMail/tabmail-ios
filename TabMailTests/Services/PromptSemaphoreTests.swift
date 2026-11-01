/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The prompt store's one semaphore (DS-SEMAPHORE): never an infinite block. A hold is released on every
/// exit (DS-SEMAPHORE), a hold past its lease loses it and its write is refused (DS-LEASE), a nested call
/// is refused at once (DS-NESTED), and a waiting caller waits in one first-in-first-out queue for a capped time (DS-SEMAPHORE, request order).
@MainActor
@Suite("Prompt semaphore", .serialized)
struct PromptSemaphoreTests {
    private struct Failure: Error {}

    /// Short waits, so a busy refusal comes within milliseconds.
    private static let fast = PromptSemaphore.Config(leaseSeconds: 15, acquireWaitSeconds: 0.05)

    /// Holds `semaphore` from another task until `end()`.
    @MainActor
    private final class Holder {
        private let task: Task<Void, Error>
        private let release: AsyncStream<Void>.Continuation
        private(set) var token: UUID?

        init(_ semaphore: PromptSemaphore) async {
            let (released, release) = AsyncStream<Void>.makeStream()
            let (taken, took) = AsyncStream<UUID>.makeStream()
            self.release = release
            task = Task { @MainActor in
                defer { took.finish() }
                try await semaphore.hold("test holder") { hold in
                    took.yield(hold.token)
                    for await _ in released { break }
                }
            }
            for await token in taken {
                self.token = token
                break
            }
        }

        func end() async throws {
            release.yield()
            try await task.value
        }
    }

    /// Whether a new hold is taken at once (nothing holds the semaphore).
    private func free(_ semaphore: PromptSemaphore) async -> Bool {
        let config = semaphore.config
        semaphore.config = PromptSemaphore.Config(leaseSeconds: config.leaseSeconds, acquireWaitSeconds: 0)
        defer { semaphore.config = config }
        return (try? await semaphore.hold("probe") { _ in true }) == true
    }

    @Test("A holder past its lease has no write authority even when the lease timer has not run yet (DS-LEASE)")
    func overdueHolderIsNotTheHolderBeforeItsTimerRuns() async throws {
        let semaphore = PromptSemaphore(config: PromptSemaphore.Config(leaseSeconds: 0.03, acquireWaitSeconds: 0.05))
        try await semaphore.hold("overdue") { hold in
            #expect(hold.isHolder, "positive control: inside its lease it is the holder")
            // A synchronous MainActor delay past the lease: the lease timer cannot run during it.
            let end = ContinuousClock.now + .milliseconds(100)
            while ContinuousClock.now < end {}
            #expect(!hold.isHolder, "past its lease it is not, whether or not the timer has run")
            #expect(throws: PromptRefusal.self) { try hold.requireUnchanged(since: semaphore.counter) }
        }
    }

    @Test("A hold is released when its body returns, throws, or is cancelled")
    func releasedOnEveryExit() async throws {
        let semaphore = PromptSemaphore(config: Self.fast)

        #expect(try await semaphore.hold("returns") { _ in 1 } == 1)
        #expect(await free(semaphore))

        await #expect(throws: Failure.self) {
            try await semaphore.hold("throws") { _ in throw Failure() }
        }
        #expect(await free(semaphore))

        let cancelled = Task { @MainActor in
            try await semaphore.hold("cancelled") { _ in
                try await Task.sleep(for: .seconds(60))
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        _ = await cancelled.result
        #expect(await free(semaphore))
    }

    @Test("A hold past its lease loses the semaphore: its write check fails, and the counter does not move")
    func leaseExpiry() async throws {
        let semaphore = PromptSemaphore(config: PromptSemaphore.Config(leaseSeconds: 0.05, acquireWaitSeconds: 0))
        let counter = semaphore.counter
        let (heldAtStart, heldAfter, refused) = try await semaphore.hold("slow") { hold in
            let start = hold.isHolder
            let read = hold.counter
            try await Task.sleep(for: .milliseconds(300))
            var refusal: PromptRefusal?
            do { try hold.requireUnchanged(since: read) } catch let error as PromptRefusal { refusal = error }
            return (start, hold.isHolder, refusal)
        }
        #expect(heldAtStart)
        #expect(!heldAfter)
        #expect(refused == .changed)
        // DS-COUNTER: lease expiry does not renew the counter.
        #expect(semaphore.counter == counter)
        #expect(await free(semaphore))
    }

    @Test("A call made inside a hold is refused as busy at once, never waiting on itself")
    func nestedCallRefusedAtOnce() async throws {
        // Long waits: a nested call that waited would take seconds.
        let semaphore = PromptSemaphore(config: PromptSemaphore.Config(leaseSeconds: 15, acquireWaitSeconds: 1))
        let started = ContinuousClock.now
        try await semaphore.hold("outer") { _ in
            await #expect(throws: PromptRefusal.busy) {
                try await semaphore.hold("inner") { _ in }
            }
            // Also from a task it starts, which inherits the holding task's mark (MIS-IOS-028).
            let child = Task { @MainActor in try await semaphore.hold("child") { _ in } }
            await #expect(throws: PromptRefusal.busy) { try await child.value }
        }
        #expect(ContinuousClock.now - started < .milliseconds(900))
        // Positive control: the same call outside a hold runs.
        #expect(try await semaphore.hold("after") { _ in true })
    }

    @Test("A task created inside a hold under the cleared mark waits for the hold instead of being refused as nested")
    func taskUnderClearedMarkIsNotNested() async throws {
        let semaphore = PromptSemaphore(config: PromptSemaphore.Config(leaseSeconds: 15, acquireWaitSeconds: 5))
        let later: Task<String, Error> = try await semaphore.hold("outer") { _ in
            PromptSemaphore.$holding.withValue(nil) {
                Task { @MainActor in try await semaphore.hold("later") { _ in "ran" } }
            }
        }
        #expect(try await later.value == "ran")
    }

    @Test("A waiting caller gives up as busy at the end of its wait")
    func cappedWait() async throws {
        let semaphore = PromptSemaphore(config: Self.fast)
        let holder = await Holder(semaphore)
        let started = ContinuousClock.now
        await #expect(throws: PromptRefusal.busy) {
            try await semaphore.hold("waiter") { _ in }
        }
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(45))
        #expect(waited < .seconds(2))
        try await holder.end()
        #expect(await free(semaphore))
    }

    @Test("The standard wait is 6 s in one queue, with a 15 s lease (DS-SEMAPHORE, DS-LEASE)")
    func standardConfig() {
        let standard = PromptSemaphore.Config.standard
        #expect(standard.leaseSeconds == 15)
        #expect(standard.acquireWaitSeconds == 6)
    }

    /// Starts `label` waiting for `semaphore`, appending to `order` when it runs, and returns once it queues.
    private func waiter(_ semaphore: PromptSemaphore, _ label: String, order: OrderLog) async throws -> Task<Void, Error> {
        let task = Task { @MainActor in
            try await semaphore.hold(label) { _ in order.entries.append(label) }
        }
        try await Task.sleep(for: .milliseconds(30))
        return task
    }

    @MainActor
    private final class OrderLog {
        var entries: [String] = []
    }

    @Test("Waiters take the semaphore in the order they asked, whichever way they are scheduled (DS-SEMAPHORE, request order)")
    func firstInFirstOut() async throws {
        let semaphore = PromptSemaphore(config: PromptSemaphore.Config(leaseSeconds: 15, acquireWaitSeconds: 5))
        let order = OrderLog()
        let holder = await Holder(semaphore)
        var tasks: [Task<Void, Error>] = []
        for label in ["first", "second", "third", "fourth"] {
            tasks.append(try await waiter(semaphore, label, order: order))
        }
        try await holder.end()
        for task in tasks { try await task.value }
        #expect(order.entries == ["first", "second", "third", "fourth"])
    }

    @Test("A request made as the holder releases queues behind the waiter instead of taking the semaphore")
    func newcomerNeverJumpsTheQueue() async throws {
        let semaphore = PromptSemaphore(config: PromptSemaphore.Config(leaseSeconds: 15, acquireWaitSeconds: 5))
        let order = OrderLog()
        var newcomer: Task<Void, Error>?
        let early = Task { @MainActor in
            try await semaphore.hold("holder") { _ in
                // A waiter queues behind the holder; a newcomer asks while the holder is still in its body.
                try await Task.sleep(for: .milliseconds(80))
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let older = try await waiter(semaphore, "older", order: order)
        // The holder releases in ~30 ms; ask for the semaphore from a task that runs right after it.
        newcomer = Task { @MainActor in
            try await early.value
            try await semaphore.hold("newcomer") { _ in order.entries.append("newcomer") }
        }
        try await older.value
        try await newcomer?.value
        #expect(order.entries == ["older", "newcomer"])
    }

    @Test("A cancelled waiter is dropped at once and never handed the semaphore; the next waiter is")
    func cancelledWaiterIsDropped() async throws {
        let semaphore = PromptSemaphore(config: PromptSemaphore.Config(leaseSeconds: 15, acquireWaitSeconds: 30))
        let order = OrderLog()
        let holder = await Holder(semaphore)
        let doomed = try await waiter(semaphore, "doomed", order: order)
        let next = try await waiter(semaphore, "next", order: order)
        let started = ContinuousClock.now
        doomed.cancel()
        await #expect(throws: PromptRefusal.busy) { try await doomed.value }
        #expect(ContinuousClock.now - started < .seconds(2), "a cancelled waiter does not wait out its deadline")
        try await holder.end()
        try await next.value
        #expect(order.entries == ["next"])
        #expect(await free(semaphore))
    }

    @Test("A waiter that reaches its deadline is dropped and the ones behind it keep their place")
    func deadlineDropsOnlyThatWaiter() async throws {
        let semaphore = PromptSemaphore(config: PromptSemaphore.Config(leaseSeconds: 15, acquireWaitSeconds: 0.2))
        let order = OrderLog()
        let holder = await Holder(semaphore)
        let early = Task { @MainActor in try await semaphore.hold("early") { _ in order.entries.append("early") } }
        try await Task.sleep(for: .milliseconds(120))
        let late = Task { @MainActor in try await semaphore.hold("late") { _ in order.entries.append("late") } }
        try await Task.sleep(for: .milliseconds(150))
        // The early waiter's 200 ms passed; the late one has about 170 ms left.
        await #expect(throws: PromptRefusal.busy) { try await early.value }
        try await holder.end()
        try await late.value
        #expect(order.entries == ["late"])
    }

    /// Blocks the calling (main) thread, so no timer on it can run.
    private static func blockTheMainActor(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    @Test("A waiter past its deadline is refused at the release even when its timer has not run yet; within its deadline it is granted",
          arguments: [0.03, 5.0])
    func expiredWaiterIsRefusedWhenItsTimerIsLate(wait: Double) async throws {
        let semaphore = PromptSemaphore(config: PromptSemaphore.Config(leaseSeconds: 15, acquireWaitSeconds: wait))
        let order = OrderLog()
        var late: Task<Void, Error>?
        try await semaphore.hold("holder") { _ in
            // Under the cleared mark, so the task queues behind the hold instead of being refused as nested.
            late = PromptSemaphore.$holding.withValue(nil) {
                Task { @MainActor in try await semaphore.hold("late") { _ in order.entries.append("late") } }
            }
            try await Task.sleep(for: .milliseconds(10))
            // The main actor is held past the short wait, so the waiter's timer cannot run before the release below.
            Self.blockTheMainActor(seconds: 0.15)
        }
        let waiting = try #require(late)
        if wait < 1 {
            await #expect(throws: PromptRefusal.busy) { try await waiting.value }
            #expect(order.entries.isEmpty, "a request past its time was handed the semaphore")
        } else {
            try await waiting.value
            #expect(order.entries == ["late"], "control: a request within its time is granted")
        }
        #expect(await free(semaphore))
    }

    @Test("A holder that never releases hands the semaphore on at its lease: the queue never blocks for good (I4)")
    func leaseHandsOver() async throws {
        let semaphore = PromptSemaphore(config: PromptSemaphore.Config(leaseSeconds: 0.1, acquireWaitSeconds: 5))
        let order = OrderLog()
        let holder = await Holder(semaphore)
        let started = ContinuousClock.now
        let next = try await waiter(semaphore, "next", order: order)
        try await next.value
        #expect(order.entries == ["next"])
        #expect(ContinuousClock.now - started < .seconds(2))
        try await holder.end()
    }

    @Test("A waiting caller takes the semaphore once the holder releases it")
    func waiterTakesItAfterRelease() async throws {
        let semaphore = PromptSemaphore(config: PromptSemaphore.Config(leaseSeconds: 15, acquireWaitSeconds: 5))
        let holder = await Holder(semaphore)
        let waiter = Task { @MainActor in try await semaphore.hold("waiter") { _ in "ran" } }
        try await Task.sleep(for: .milliseconds(10))
        try await holder.end()
        #expect(try await waiter.value == "ran")
    }

    @Test("A write carrying the counter it read is refused once the counter was renewed (DS-AI)")
    func counterRefusesAMovedWrite() async throws {
        let semaphore = PromptSemaphore(config: Self.fast)
        let read = try await semaphore.hold("read") { $0.counter }
        // Positive control: nothing changed, the write is allowed.
        try await semaphore.hold("write unchanged") { try $0.requireUnchanged(since: read) }
        semaphore.renewCounter()
        await #expect(throws: PromptRefusal.changed) {
            try await semaphore.hold("write after a change") { try $0.requireUnchanged(since: read) }
        }
        // Nothing is held between the read and the write: another caller runs meanwhile.
        #expect(await free(semaphore))
    }

    @Test("PromptStore.withPromptStore is the semaphore's one way in and refuses a nested call")
    func promptStoreWay() async throws {
        let store = PromptStore.shared
        let outcome: PromptRefusal? = try await store.withPromptStore("outer") { _ in
            do { try await store.withPromptStore("inner") { _ in } } catch let error as PromptRefusal { return error }
            return nil
        }
        #expect(outcome == .busy)
        #expect(try await store.withPromptStore("alone") { _ in true })
    }
}
