/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@Suite("ActiveBodyQueue retry-exhaustion drain regression")
struct BodyQueueDrainStallRegressionTests {
    private func exhaust(
        _ item: ActiveBodyQueue.Item,
        in queue: ActiveBodyQueue
    ) async {
        for _ in 0...SyncConfig.maxQueueRetries {
            await queue.completeItemForTesting(item, shouldRetry: true)
        }
    }

    private func drainCompletesPromptly(_ queue: ActiveBodyQueue) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await queue.awaitDrain()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(100))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    @Test("one retry-exhausted body cannot resurrect forever or block drain")
    func oneMessageReachesAQuiescentDrain() async {
        let queue = ActiveBodyQueue()
        let item = ActiveBodyQueue.Item(
            headerId: "acc1:INBOX:1",
            accountId: "acc1",
            folderPath: "INBOX",
            messageId: "1",
            isInInbox: true
        )

        #expect(await queue.admit(item))
        await exhaust(item, in: queue)
        #expect(await queue.storageSnapshotForTesting.queueCount == 0)
        #expect(await queue.retryExhaustedHeaderIdsForTesting == [item.headerId])
        #expect(!(await queue.isQueuedOrInFlight(headerId: item.headerId)))

        var resurrectionCount = 0
        for _ in 0..<12 {
            let added = await queue.admitDrainCandidatesForTesting([item])
            resurrectionCount += added
            if added > 0 {
                // Model the provider failing again: the pre-fix queue receives a
                // fresh retry budget after every drain-time rediscovery.
                await exhaust(item, in: queue)
            }
        }
        #expect(resurrectionCount == 0)

        let finalAdded = await queue.admitDrainCandidatesForTesting([item])
        #expect(finalAdded == 0)
        #expect(await drainCompletesPromptly(queue))
    }

    @Test("a different body in the same small inbox remains admissible")
    func freshSmallInboxWorkStillAdmits() async {
        let queue = ActiveBodyQueue()
        let exhausted = ActiveBodyQueue.Item(
            headerId: "acc1:INBOX:1",
            accountId: "acc1",
            folderPath: "INBOX",
            messageId: "1",
            isInInbox: true
        )
        let fresh = ActiveBodyQueue.Item(
            headerId: "acc1:INBOX:2",
            accountId: "acc1",
            folderPath: "INBOX",
            messageId: "2",
            isInInbox: true
        )

        #expect(await queue.admit(exhausted))
        await exhaust(exhausted, in: queue)
        #expect(await queue.admitDrainCandidatesForTesting([fresh]) == 1)
        #expect(await queue.queuedItemsForTesting == [fresh])
    }

    @Test("a later foreground recovery grants one fresh retry budget")
    func externalRecoveryRearmsExhaustedBody() async {
        let queue = ActiveBodyQueue()
        let item = ActiveBodyQueue.Item(
            headerId: "acc1:INBOX:1",
            accountId: "acc1",
            folderPath: "INBOX",
            messageId: "1",
            isInInbox: true
        )

        #expect(await queue.admit(item))
        await exhaust(item, in: queue)
        #expect(!(await queue.admit(item)))

        await queue.cancelAllInFlight()
        #expect(await queue.retryExhaustedHeaderIdsForTesting.isEmpty)
        #expect(await queue.admit(item))
    }
}
