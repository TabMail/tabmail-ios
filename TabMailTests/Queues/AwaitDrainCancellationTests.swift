/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("awaitDrain cancellation")
struct AwaitDrainCancellationTests {

    @Test("awaitDrain exits promptly when Task is cancelled")
    func exitOnCancellation() async {
        // Enqueue items to ActiveAIQueue so it's NOT idle
        // (can't actually process without providers, but that's fine —
        // we just need isIdle == false to test that drain doesn't hang)
        await ActiveAIQueue.shared.enqueueUnboundForCancellationTest(
            headerId: "test:INBOX:1", accountId: "test")

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

        // Clean up
        await ActiveAIQueue.shared.cancelAllInFlight()
    }
}
