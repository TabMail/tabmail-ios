/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Mutates `ActiveAIQueue.shared` (enqueueBatch / awaitDrain / cancelAllInFlight),
/// so it must hold the process-global-state lock like every other suite touching
/// the shared queue — `WindowExemptAdmissionTests` suppresses dispatch and clears
/// storage on the same singleton, and without mutual exclusion an interleaved
/// clear empties `storage` and lets `awaitDrain` exit at its `storage.isEmpty`
/// check BEFORE the cancellation this test exists to prove (round-1 review
/// finding, 2026-08-19).
@Suite("awaitDrain cancellation", .serialized, .processGlobalState)
struct AwaitDrainCancellationTests {

    @Test("awaitDrain exits promptly when Task is cancelled")
    func exitOnCancellation() async {
        // SUPPRESS dispatch BEFORE enqueuing: `enqueueBatch` schedules
        // `dispatchPending`, which in the sessionless test environment
        // (`canProcessAI == false`) CLEARS the queue itself. Without suppression
        // `awaitDrain` could exit at its `storage.isEmpty` break — proving nothing
        // about cancellation. Suppressed, the item stays pending, so the only way
        // `awaitDrain` returns before the multi-second safety timeout is the
        // cancellation branch this test exists to prove (round-2 review finding).
        await ActiveAIQueue.shared.setDispatchSuppressedForTesting(true)
        await ActiveAIQueue.shared.clearForTesting()
        await ActiveAIQueue.shared.enqueueBatch([
            (headerId: "test:INBOX:1", accountId: "test")
        ])
        #expect(await !ActiveAIQueue.shared.isIdle,
                "the queue must be non-idle so awaitDrain blocks on the queue, not exit via isEmpty")

        let drainTask = Task {
            await ActiveAIQueue.shared.awaitDrain()
        }

        // Cancel after brief delay — drain should exit promptly
        try? await Task.sleep(for: .milliseconds(100))
        drainTask.cancel()

        // Wait for drain to actually exit — should be <500ms after cancel
        let t0 = CFAbsoluteTimeGetCurrent()
        await drainTask.value
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        #expect(elapsed < 1.0, "awaitDrain should exit within 1s of cancellation, took \(elapsed)s")

        // Clean up — the suppressed item never drained, so clear it explicitly and
        // restore dispatch for the next suite.
        await ActiveAIQueue.shared.cancelAllInFlight()
        await ActiveAIQueue.shared.clearForTesting()
        await ActiveAIQueue.shared.setDispatchSuppressedForTesting(false)
    }
}
