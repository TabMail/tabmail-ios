/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Shared, `Sendable` probe for the queue tests. An actor (not a captured
/// `Mutex`) so several concurrent `Task`s can record into it without tripping
/// Swift 6 region isolation.
private actor Recorder {
    private(set) var log: [String] = []
    private(set) var released = false
    private(set) var concurrent = 0
    private(set) var maxConcurrent = 0

    func record(_ s: String) { log.append(s) }
    func release() { released = true }
    func enter() { concurrent += 1; maxConcurrent = max(maxConcurrent, concurrent) }
    func leave() { concurrent -= 1 }
}

/// Coverage for the serial, priority-ordered DB write scheduler. Tests use a
/// FRESH `DatabaseWriteQueue()` (not `.shared`) so they're isolated. Determinism
/// for the ordering assertions comes from polling `isWriting` / `queuedCount`,
/// not fixed sleeps.
@Suite("DatabaseWriteQueue", .serialized)
struct DatabaseWriteQueueTests {

    /// Spin until `n` writes have parked in the queue.
    private func waitUntilQueued(_ q: DatabaseWriteQueue, _ n: Int) async {
        while await q.queuedCount < n { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// Spin until a write holds the single slot.
    private func waitUntilWriting(_ q: DatabaseWriteQueue) async {
        while await q.isWriting == false { try? await Task.sleep(for: .milliseconds(1)) }
    }

    @Test("serial: never more than one write runs at a time")
    func serialOneAtATime() async {
        let q = DatabaseWriteQueue()
        let rec = Recorder()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await q.execute(priority: .background) {
                        await rec.enter()
                        try? await Task.sleep(for: .milliseconds(5))
                        await rec.leave()
                    }
                }
            }
        }
        #expect(await rec.maxConcurrent == 1)   // the single GRDB writer
    }

    @Test("priority jumps ahead of queued normal/background writes (tier order, not FIFO)")
    func priorityJumpsQueued() async {
        let q = DatabaseWriteQueue()
        let rec = Recorder()

        // Occupy the single slot with a background write that holds until released,
        // so everything enqueued next parks behind it.
        let blocker = Task {
            try? await q.execute(priority: .background) {
                while await rec.released == false { try? await Task.sleep(for: .milliseconds(2)) }
                await rec.record("blocker")
            }
        }
        await waitUntilWriting(q)   // blocker holds the slot

        // Enqueue in LOW→HIGH order so FIFO and tier-order differ.
        let bg = Task { try? await q.execute(priority: .background) { await rec.record("bg") } }
        let nrm = Task { try? await q.execute(priority: .normal) { await rec.record("normal") } }
        let prio = Task { try? await q.execute(priority: .priority) { await rec.record("priority") } }
        await waitUntilQueued(q, 3)   // all three parked behind the blocker

        await rec.release()
        await blocker.value; await bg.value; await nrm.value; await prio.value

        // Drained by tier, NOT submission order (which was bg, normal, priority).
        #expect(await rec.log == ["blocker", "priority", "normal", "bg"])
    }

    @Test("privileged section: background parks until exit; priority still runs")
    func privilegedReservesAgainstBackground() async {
        let q = DatabaseWriteQueue()
        let rec = Recorder()
        await q.enterPrivileged()

        let bg = Task { try? await q.execute(priority: .background) { await rec.record("bg") } }
        await waitUntilQueued(q, 1)               // background blocked by the merge section
        #expect(await rec.log.isEmpty)

        // A priority write proceeds DURING the section (the merge's own writes).
        try? await q.execute(priority: .priority) { await rec.record("priority") }
        #expect(await rec.log == ["priority"])    // priority ran, bg still parked

        await q.exitPrivileged()
        await bg.value
        #expect(await rec.log == ["priority", "bg"])   // released once the section ended
    }

    @Test("slot is released on throw (next waiter still runs)")
    func releasesSlotOnThrow() async {
        struct Boom: Error {}
        let q = DatabaseWriteQueue()
        let rec = Recorder()
        await #expect(throws: Boom.self) {
            try await q.execute(priority: .priority) { throw Boom() }
        }
        // The queue must be usable afterward — a following write completes.
        try? await q.execute(priority: .background) { await rec.record("after") }
        #expect(await rec.log == ["after"])
    }
}
