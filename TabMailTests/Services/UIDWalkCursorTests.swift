/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("UIDWalkCursor - Range Generation")
struct UIDWalkCursorRangeTests {

    @Test("Generates correct ranges walking backward")
    func walkBackward() async {
        let cursor = UIDWalkCursor(startCursor: 100, chunkSize: 30)

        let r1 = await cursor.nextRange()
        #expect(r1?.from == 71)
        #expect(r1?.to == 100)

        let r2 = await cursor.nextRange()
        #expect(r2?.from == 41)
        #expect(r2?.to == 70)

        let r3 = await cursor.nextRange()
        #expect(r3?.from == 11)
        #expect(r3?.to == 40)

        let r4 = await cursor.nextRange()
        #expect(r4?.from == 1)
        #expect(r4?.to == 10)

        // Confirm all ranges
        await cursor.confirmRange(from: 71, to: 100)
        await cursor.confirmRange(from: 41, to: 70)
        await cursor.confirmRange(from: 11, to: 40)
        await cursor.confirmRange(from: 1, to: 10)

        let r5 = await cursor.nextRange()
        #expect(r5 == nil, "Should be nil when walk is complete")
        #expect(await cursor.isComplete == true)
    }

    @Test("Clamps to UID 1 on final range")
    func clampsToOne() async {
        let cursor = UIDWalkCursor(startCursor: 5, chunkSize: 10)
        let range = await cursor.nextRange()
        #expect(range?.from == 1)
        #expect(range?.to == 5)
    }

    @Test("Single UID cursor")
    func singleUID() async {
        let cursor = UIDWalkCursor(startCursor: 1, chunkSize: 100)
        let range = await cursor.nextRange()
        #expect(range?.from == 1)
        #expect(range?.to == 1)
        await cursor.confirmRange(from: 1, to: 1)
        #expect(await cursor.nextRange() == nil)
        #expect(await cursor.isComplete == true)
    }
}

@Suite("UIDWalkCursor - Claim/Confirm Robustness")
struct UIDWalkCursorRobustnessTests {

    @Test("Confirmed cursor only advances past confirmed ranges")
    func confirmedCursorAdvancement() async {
        let cursor = UIDWalkCursor(startCursor: 100, chunkSize: 50)

        let r1 = await cursor.nextRange()  // 51..100
        let r2 = await cursor.nextRange()  // 1..50
        guard let r1, let r2 else {
            Issue.record("Expected two ranges from nextRange()")
            return
        }

        // Cursor should NOT advance until confirmed
        #expect(await cursor.currentCursor == 100, "Should not advance before any confirmation")

        // Confirm r1 (top range) — cursor should advance to 50
        await cursor.confirmRange(from: r1.from, to: r1.to)
        #expect(await cursor.currentCursor == 50, "Should advance past top confirmed range")

        // Confirm r2 — cursor should advance to 0 (complete)
        await cursor.confirmRange(from: r2.from, to: r2.to)
        #expect(await cursor.currentCursor < 1, "Should be complete after all confirmed")
        #expect(await cursor.isComplete == true)
    }

    @Test("Failed ranges are retried before new ranges")
    func failedRangesRetried() async {
        let cursor = UIDWalkCursor(startCursor: 100, chunkSize: 50)

        let r1 = await cursor.nextRange()  // 51..100
        #expect(r1?.from == 51)
        guard let r1 else {
            Issue.record("Expected initial range from nextRange()")
            return
        }

        // Fail the range
        await cursor.failRange(from: r1.from, to: r1.to)

        // Next call should return the failed range, not a new one
        let retry = await cursor.nextRange()
        #expect(retry?.from == 51, "Should retry failed range")
        #expect(retry?.to == 100)
        guard let retry else {
            Issue.record("Expected retry range from nextRange()")
            return
        }

        // Confirm it this time
        await cursor.confirmRange(from: retry.from, to: retry.to)
        #expect(await cursor.currentCursor == 50)
    }

    @Test("Not complete when ranges are in-flight")
    func notCompleteWithInFlight() async {
        let cursor = UIDWalkCursor(startCursor: 10, chunkSize: 10)

        let r1 = await cursor.nextRange()  // 1..10
        #expect(r1 != nil)
        guard let r1 else { return }

        // No more new ranges, but r1 is still in-flight
        let r2 = await cursor.nextRange()
        #expect(r2 == nil, "No more new ranges")
        #expect(await cursor.isComplete == false, "Should NOT be complete with in-flight range")

        // Confirm it
        await cursor.confirmRange(from: r1.from, to: r1.to)
        #expect(await cursor.isComplete == true, "Should be complete after confirmation")
    }

    @Test("Not complete when ranges are in retry queue")
    func notCompleteWithRetryQueue() async {
        let cursor = UIDWalkCursor(startCursor: 10, chunkSize: 10)

        let r1 = await cursor.nextRange()  // 1..10
        guard let r1 else {
            Issue.record("Expected initial range from nextRange()")
            return
        }
        await cursor.failRange(from: r1.from, to: r1.to)

        #expect(await cursor.isComplete == false, "Should NOT be complete with retry queue")
        #expect(await cursor.hasPendingWork == true)
    }

    @Test("Confirmed cursor does not advance past unconfirmed gaps")
    func confirmedCursorGap() async {
        let cursor = UIDWalkCursor(startCursor: 150, chunkSize: 50)

        let r1 = await cursor.nextRange()  // 101..150
        let r2 = await cursor.nextRange()  // 51..100
        let r3 = await cursor.nextRange()  // 1..50
        guard let r1, let r2, let r3 else {
            Issue.record("Expected three ranges from nextRange()")
            return
        }

        // Confirm r3 (bottom) but not r1 or r2 — cursor should NOT advance
        // because r1 (highest pending = 150) is still in-flight at the top
        await cursor.confirmRange(from: r3.from, to: r3.to)
        let cc = await cursor.currentCursor
        #expect(cc == 150, "Cursor should not advance — r1(101..150) still in-flight at top")

        // Confirm r1 (top) — now highest pending is r2.to = 100
        await cursor.confirmRange(from: r1.from, to: r1.to)
        let cc2 = await cursor.currentCursor
        #expect(cc2 == 100, "Should advance to r2's top since r2 is highest pending")

        // Confirm r2 — now everything is done
        await cursor.confirmRange(from: r2.from, to: r2.to)
        #expect(await cursor.isComplete == true)
        #expect(await cursor.currentCursor < 1)
    }
}

@Suite("UIDWalkCursor - Chunk Recovery")
struct UIDWalkCursorChunkRecoveryTests {

    @Test("reduceChunk halves chunk size")
    func reduceChunk() async {
        let cursor = UIDWalkCursor(startCursor: 1000, chunkSize: 200)
        let reduced = await cursor.reduceChunk()
        #expect(reduced == 100)

        let reduced2 = await cursor.reduceChunk()
        #expect(reduced2 == 50)
    }

    @Test("reduceChunk floors at 1")
    func reduceChunkFloor() async {
        let cursor = UIDWalkCursor(startCursor: 1000, chunkSize: 2)
        _ = await cursor.reduceChunk()  // 1
        let floored = await cursor.reduceChunk()  // still 1
        #expect(floored == 1)
    }

    @Test("confirmRange recovers chunk after 5 consecutive successes")
    func recoveryAfterSuccesses() async {
        let cursor = UIDWalkCursor(startCursor: 10000, chunkSize: 500)

        // Reduce chunk: 500 → 250 → 125
        _ = await cursor.reduceChunk()
        _ = await cursor.reduceChunk()
        let reduced = await cursor.currentChunkSize
        #expect(reduced == 125)

        // Grab and confirm 5 ranges to trigger recovery
        for _ in 0..<5 {
            if let r = await cursor.nextRange() {
                await cursor.confirmRange(from: r.from, to: r.to)
            }
        }
        #expect(await cursor.currentChunkSize == 250, "Should double after 5 consecutive successes")

        // 5 more to recover to default
        for _ in 0..<5 {
            if let r = await cursor.nextRange() {
                await cursor.confirmRange(from: r.from, to: r.to)
            }
        }
        #expect(await cursor.currentChunkSize == 500, "Should recover to default")
    }

    @Test("reduceChunk resets success counter")
    func reduceResetsCounter() async {
        let cursor = UIDWalkCursor(startCursor: 10000, chunkSize: 500)
        _ = await cursor.reduceChunk()  // 250

        // 4 confirmations
        for _ in 0..<4 {
            if let r = await cursor.nextRange() {
                await cursor.confirmRange(from: r.from, to: r.to)
            }
        }

        // Reduce again (resets counter): 250 → 125
        _ = await cursor.reduceChunk()
        #expect(await cursor.currentChunkSize == 125)

        // Only 1 confirmation after reduce — counter was reset, need 5 total
        if let r = await cursor.nextRange() {
            await cursor.confirmRange(from: r.from, to: r.to)
        }
        #expect(await cursor.currentChunkSize == 125, "Counter should have reset on reduce")

        // 4 more (total 5 since reduce) — should recover
        for _ in 0..<4 {
            if let r = await cursor.nextRange() {
                await cursor.confirmRange(from: r.from, to: r.to)
            }
        }
        #expect(await cursor.currentChunkSize == 250, "Should recover after 5 successes from reset")
    }
}
