/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Pure unit tests for `AccountManager.buildLanes` — the connected-component
/// lane-keying fix (ADR-IOS-018 amendment 2026-07-10, DECISIONS.md). No DB, no provider, no actor hop:
/// `buildLanes` is a `nonisolated static` pure function over `[PendingOperation]`
/// values constructed directly in-memory.
///
/// Background: the OLD lane key was `"accountId:messageIds.first"`, so a batch
/// move `[A,B,C]` landed in a lane keyed by A while a LATER single-id op on B
/// landed in a SEPARATE lane keyed by B — even though B is a member of BOTH
/// ops. Since `ProviderWorkQueue` runs each lane concurrently (bounded
/// concurrency > 1, separate IMAP connections), the two ops could execute out
/// of order relative to each other, causing a real remote race (flag STORE on
/// B racing the batch MOVE of B — flag lost on EXPUNGE, or `uidResolutionFailed`
/// wrongly confirming the flag op stale mid-move). `buildLanes` fixes this via
/// union-find: any two ops sharing ANY member message id land in the same lane
/// (connected component), scoped per-account so unrelated accounts never merge.
@Suite("PendingOperation lane keying (buildLanes)")
struct PendingQueueLaneTests {

    // MARK: - Helpers

    /// Build a PendingOperation with an explicit createdAt so ordering is deterministic.
    private func makeOp(
        type: OperationType = .markRead,
        messageIds: [String],
        accountId: String = "acc1",
        createdAt: Date
    ) -> PendingOperation {
        var op = PendingOperation(type: type, messageIds: messageIds, accountId: accountId, folderPath: "INBOX")
        op.createdAt = createdAt
        return op
    }

    // MARK: - 1. Batch + single sharing a member id merge into ONE lane

    @Test("batch [A,B,C] + single [B] merge into ONE lane, in createdAt order")
    func batchAndSingleShareMemberMergeIntoOneLane() {
        let now = Date()
        let batchOp = makeOp(type: .move, messageIds: ["A", "B", "C"], createdAt: now)
        let singleOp = makeOp(type: .markFlagged, messageIds: ["B"], createdAt: now.addingTimeInterval(1))

        let lanes = AccountManager.buildLanes([batchOp, singleOp])

        #expect(lanes.count == 1)
        guard lanes.count == 1 else { return }
        #expect(lanes[0].map(\.id) == [batchOp.id, singleOp.id])
    }

    // MARK: - 2. Bridge merge across two components via a linking op

    @Test("bridge merge: [A,B] then [C,D] then [B,C] merges into ONE lane of 3, createdAt order")
    func bridgeMergeAcrossComponents() {
        let now = Date()
        let opAB = makeOp(messageIds: ["A", "B"], createdAt: now)
        let opCD = makeOp(messageIds: ["C", "D"], createdAt: now.addingTimeInterval(1))
        let opBridge = makeOp(messageIds: ["B", "C"], createdAt: now.addingTimeInterval(2))

        let lanes = AccountManager.buildLanes([opAB, opCD, opBridge])

        #expect(lanes.count == 1)
        guard lanes.count == 1 else { return }
        #expect(lanes[0].count == 3)
        #expect(lanes[0].map(\.id) == [opAB.id, opCD.id, opBridge.id])
    }

    // MARK: - 3. Disjoint ops stay separate; empty messageIds is a singleton lane

    @Test("disjoint ops land in separate lanes; empty-messageIds op is its own singleton lane")
    func disjointOpsAndEmptyMessageIdsSingleton() {
        let now = Date()
        let opX = makeOp(messageIds: ["X"], createdAt: now)
        let opY = makeOp(messageIds: ["Y"], createdAt: now.addingTimeInterval(1))
        let opEmpty = makeOp(type: .saveDraft, messageIds: [], createdAt: now.addingTimeInterval(2))

        let lanes = AccountManager.buildLanes([opX, opY, opEmpty])

        #expect(lanes.count == 3)
        let laneIds = lanes.map { $0.map(\.id) }
        #expect(laneIds.contains([opX.id]))
        #expect(laneIds.contains([opY.id]))
        #expect(laneIds.contains([opEmpty.id]))
    }

    // MARK: - 4. Same message id across DIFFERENT accounts stays separate

    @Test("same message id on different accounts lands in separate lanes (no cross-account merge)")
    func sameMessageIdDifferentAccountsSeparateLanes() {
        let now = Date()
        let opAcc1 = makeOp(messageIds: ["shared-id"], accountId: "acc1", createdAt: now)
        let opAcc2 = makeOp(messageIds: ["shared-id"], accountId: "acc2", createdAt: now.addingTimeInterval(1))

        let lanes = AccountManager.buildLanes([opAcc1, opAcc2])

        #expect(lanes.count == 2)
        let laneIds = lanes.map { $0.map(\.id) }
        #expect(laneIds.contains([opAcc1.id]))
        #expect(laneIds.contains([opAcc2.id]))
    }

    // MARK: - 5. Empty input / multiple disjoint empty-messageIds ops

    @Test("empty input produces no lanes")
    func emptyInputProducesNoLanes() {
        let lanes = AccountManager.buildLanes([])
        #expect(lanes.isEmpty)
    }

    @Test("multiple empty-messageIds ops each get their own singleton lane (never merge with each other)")
    func multipleEmptyMessageIdsOpsStaySeparate() {
        let now = Date()
        let op1 = makeOp(type: .saveDraft, messageIds: [], createdAt: now)
        let op2 = makeOp(type: .deleteDraft, messageIds: [], createdAt: now.addingTimeInterval(1))

        let lanes = AccountManager.buildLanes([op1, op2])

        #expect(lanes.count == 2)
        let laneIds = lanes.map { $0.map(\.id) }
        #expect(laneIds.contains([op1.id]))
        #expect(laneIds.contains([op2.id]))
    }
}
