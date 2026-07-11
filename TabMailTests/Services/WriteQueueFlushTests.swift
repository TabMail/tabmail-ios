/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// Pins `AccountManager.awaitWriteQueueDrain()` / `awaitWriteQueueDrainOrTimeout`
/// (F3, PLAN_OVERLAY_CALLSITE_AUDIT.md §6 follow-ups) — the production-grade
/// promotion of the `drainWriteQueue` FIFO-barrier pattern already proven in
/// `InboxGestureActionTests`/`MessageDetailStagedFallbackTests`, now used by
/// `AppDelegate`'s `didEnterBackground` "wal-durability-checkpoint" bracket to
/// flush `AccountManager.writeQueue` (including queued ADR-IOS-057 intent-cycle
/// executors) before the WAL fsync.
///
/// Pure queue mechanics on the `AccountManager.shared` singleton — no
/// `AppDatabase` swap needed (`enqueueWrite`'s closures here never touch GRDB).
///
/// `.serialized`: these tests enqueue closures onto the SAME process-wide
/// `AccountManager.shared.writeQueue` used by other suites (mirrors
/// `InboxGestureActionTests`'s rationale) — serializing our own `@Test`
/// functions avoids two of THIS suite's tests racing each other's order logs.
@Suite("AccountManager write-queue background flush (F3)", .serialized)
struct WriteQueueFlushTests {

    // MARK: - 1. FIFO barrier ordering

    @Test("awaitWriteQueueDrain returns only after every closure enqueued before the call has run, in FIFO order")
    func awaitDrainIsFIFOBarrierInOrder() async throws {
        let order = Mutex<[Int]>([])

        for i in 0..<5 {
            await AccountManager.shared.enqueueWrite {
                order.withLock { $0.append(i) }
            }
        }

        await AccountManager.shared.awaitWriteQueueDrain()

        let result = order.withLock { $0 }
        #expect(result == [0, 1, 2, 3, 4], "closures must have drained in FIFO submission order by the time the barrier returns")
    }

    // MARK: - 2. Multiple concurrent awaiters

    @Test("multiple concurrent awaitWriteQueueDrain callers all resume")
    func concurrentAwaitersAllResume() async throws {
        let workRan = Mutex(false)
        await AccountManager.shared.enqueueWrite {
            workRan.withLock { $0 = true }
        }

        let awaiterCount = 5
        // Each child task returns whether it resumed (rather than mutating a
        // Mutex shared across concurrent `addTask` closures + the enclosing
        // task) — avoids Swift 6's region-based "sending" diagnostic for a
        // local captured across multiple concurrently-executing closures.
        let resumedCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<awaiterCount {
                group.addTask {
                    await AccountManager.shared.awaitWriteQueueDrain()
                    return true
                }
            }
            var count = 0
            for await didResume in group where didResume {
                count += 1
            }
            return count
        }

        #expect(resumedCount == awaiterCount, "every concurrent awaiter must resume")
        #expect(workRan.withLock { $0 } == true, "the antecedent queued write must have run before any awaiter resumed")
    }

    // MARK: - 3. Timeout race shape (the exact code AppDelegate uses)

    /// Verified empirically (probe script, not committed) before writing this:
    /// a naive `withTaskGroup` race of `awaitWriteQueueDrain()` vs a timer
    /// does NOT actually bound the wait — `withTaskGroup` implicitly awaits
    /// every child task before its closure scope returns, even after
    /// `cancelAll()`, and `awaitWriteQueueDrain()`'s bare `CheckedContinuation`
    /// never observes cancellation. `AccountManager.awaitWriteQueueDrainOrTimeout`
    /// therefore races two UNSTRUCTURED `Task`s against one guarded shared
    /// continuation instead — this test exercises that REAL production race
    /// function directly (the same one `AppDelegate` calls), not a copy.
    @Test("timeout race bounds the wait even when the queue is stuck; the stuck closure is never dropped and a later drain still sees it complete")
    func timeoutRaceBoundsWaitAndNeverDropsQueuedWork() async throws {
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        let ran = Mutex(false)

        // Block the queue on a closure that only completes once the gate opens.
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
            ran.withLock { $0 = true }
        }

        let shortTimeoutSeconds = 0.05
        let start = Date()
        await AccountManager.awaitWriteQueueDrainOrTimeout(timeoutSeconds: shortTimeoutSeconds)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 1.0, "race must return near the \(shortTimeoutSeconds)s timeout, not hang on the stuck queue — got \(elapsed)s")
        #expect(ran.withLock { $0 } == false, "gate has not been opened yet — the queued closure must not have run before the race returned")

        // Never-drop: open the gate. The closure abandoned by the timeout
        // still runs once the queue actually drains, and a fresh barrier
        // call (no timeout) proves the queue is healthy afterward.
        gate.finish()
        await AccountManager.shared.awaitWriteQueueDrain()
        #expect(ran.withLock { $0 } == true, "queued closure must still run after being unblocked — never dropped")
    }
}
