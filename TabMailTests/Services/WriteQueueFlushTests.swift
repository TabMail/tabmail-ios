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
@Suite("AccountManager write-queue background flush (F3)", .serialized, .processGlobalState)
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

    // MARK: - 4. Journal-aware drain (ADR-IOS-058 round-8)

    @Test("awaitWriteQueueDrainOrTimeout waits for a record() whose fold-enqueue Task has not reached the FIFO yet")
    func drainOrTimeoutCoversJustRecordedIntention() async throws {
        // A bare FIFO barrier can land AHEAD of record()'s unstructured
        // fold-enqueue Task (no cross-Task actor-arrival ordering) — the
        // round-8 audit's background-durability hole. The journal-aware loop
        // must keep draining until the journal is fully drained, so the
        // gesture's fold executes BEFORE the barrier resumes.
        let journal = AccountManager.shared.intentionJournal
        journal.resetForTesting()
        defer { journal.resetForTesting() }

        // A single record→flush cycle only catches a reversion to a bare FIFO
        // barrier when the race is actually LOST (the fold-enqueue Task
        // happens to land after the barrier) — repeat the cycle so the pin is
        // near-certain to observe at least one lost race on a regressed
        // implementation. Post-fix each iteration is deterministic and fast.
        for iteration in 0..<25 {
            journal.resetForTesting()
            // record() on a nonexistent id: the fold resolves nothing (vanished)
            // and completes cleanly — we only pin the ORDERING (fold ran before
            // the barrier resumed), not the write itself.
            AccountManager.shared.record(
                ids: ["wqf-round8-nonexistent-\(iteration)"],
                kind: .isRead(true),
                displays: ["wqf-round8-nonexistent-\(iteration)": AccountManager.PendingMutation(isRead: true)],
                origin: .gesture
            )
            // Deliberately NO yield/sleep between record() and the flush call —
            // maximizing the chance the fold-enqueue Task has not landed yet
            // (pre-fix, this cycle flaked; post-fix it is deterministic).
            await AccountManager.awaitWriteQueueDrainOrTimeout(timeoutSeconds: SyncConfig.backgroundWriteQueueFlushTimeoutSeconds)
            #expect(journal.isFullyDrained(), "iteration \(iteration): the flush barrier resumed while the just-recorded intention was still pending — the WAL checkpoint would have missed it")
        }
    }

    @Test("awaitWriteQueueDrainOrTimeout still never blocks past its deadline when the journal cannot drain")
    func drainOrTimeoutStillBoundedWithPendingJournal() async throws {
        let journal = AccountManager.shared.intentionJournal
        journal.resetForTesting()

        // Gate the FIFO so the fold executor cannot run, keeping the journal
        // permanently non-drained for the duration of this test.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        defer {
            gate.finish()
            journal.resetForTesting()
        }
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        AccountManager.shared.record(
            ids: ["wqf-round8-gated"],
            kind: .isRead(true),
            displays: ["wqf-round8-gated": AccountManager.PendingMutation(isRead: true)],
            origin: .gesture
        )

        let start = ContinuousClock.now
        await AccountManager.awaitWriteQueueDrainOrTimeout(timeoutSeconds: 0.5)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(5), "the timeout race must bound the wait even when the journal cannot drain")
        #expect(!journal.isFullyDrained(), "sanity: the gated journal was genuinely non-drained when the deadline fired")
        gate.finish()
        // Drain fully so the gated record cannot escape into a later suite
        // (escaped-write hygiene rule).
        var i = 0
        repeat {
            await AccountManager.shared.awaitWriteQueueDrain()
            i += 1
        } while !journal.isFullyDrained() && i < 200
    }

    // MARK: - 5. Journal-aware flush across the read-error retry window (ADR-IOS-058 round-9)

    /// Round-9 pin (`AccountManager.awaitWriteQueueDrainOrTimeout`'s
    /// no-iteration-cap contract): while a record sits parked in the
    /// primary-resolve read-error retry window
    /// (`SyncConfig.intentionResolveRetryDelaySeconds` = 1s), the idle queue
    /// answers barrier round-trips near-instantly — a defensive iteration cap
    /// on the journal-aware loop exhausts BEFORE the paced retry re-enqueues
    /// the fold, resuming the flush barrier with the reinserted record still
    /// pending (the WAL checkpoint would miss the user's write). The racing
    /// timer is the SOLE bound.
    @Test("awaitWriteQueueDrainOrTimeout waits ACROSS the primary-resolve read-error retry window — no iteration cap resumes it early while the reinserted record is still pending")
    func drainOrTimeoutWaitsAcrossPrimaryResolveRetryWindow() async throws {
        let journal = AccountManager.shared.intentionJournal
        journal.resetForTesting()
        defer {
            AccountManager.simulatePrimaryResolveFailuresForTesting.withLock { $0 = [:] }
            journal.resetForTesting()
        }

        // Arm the one-shot, ID-SCOPED seam with the SAME id the record below
        // carries: the seam fires only when the fold's component CONTAINS the
        // armed id (`allIds.contains`) — a nonexistent id resolves CLEANLY to
        // nothing (vanished-row drop), so arming an id the journal never
        // holds would never make the primary resolve throw. The fold's first
        // attempt throws, `reinsertAfterReadError` puts the record back, and
        // the paced retry re-enqueues the fold, which then resolves cleanly
        // (the id has no row — vanished drop) and completes the record.
        let id = "wqf-round9-retry-window"
        AccountManager.armPrimaryResolveFailuresForTesting(id: id, count: 1)
        AccountManager.shared.record(
            ids: [id],
            kind: .isRead(true),
            displays: [id: AccountManager.PendingMutation(isRead: true)],
            origin: .gesture
        )

        // The PRODUCTION deadline (not a test literal): this pin must exercise
        // the production timeout against the production retry cadence, so a
        // tuning change that shrinks backgroundWriteQueueFlushTimeoutSeconds
        // below the ~1s intentionResolveRetryDelaySeconds window goes red here
        // instead of silently reopening the round-9 gap (test-review round 15).
        await AccountManager.awaitWriteQueueDrainOrTimeout(timeoutSeconds: SyncConfig.backgroundWriteQueueFlushTimeoutSeconds)

        #expect(journal.isFullyDrained(), "the flush barrier resumed inside the read-error retry window with the reinserted record still pending — the round-9 iteration-cap regression")
        #expect(AccountManager.remainingPrimaryResolveFailuresForTesting(id: id) == nil, "the one-shot seam was consumed — the injected primary-resolve failure actually fired")
        // Cross-constant relationship pin (plan §4 invariant 10): the flush
        // deadline must comfortably dominate the resolve-retry cadence, or a
        // gesture parked in the retry window misses the WAL fsync on
        // background. 2x margin: one full retry cycle plus resolve slack.
        #expect(SyncConfig.intentionResolveRetryDelaySeconds * 2 < SyncConfig.backgroundWriteQueueFlushTimeoutSeconds,
                "backgroundWriteQueueFlushTimeoutSeconds must dominate the intention retry cadence — see SyncConfig doc comments")
    }
}
