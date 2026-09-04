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
/// B racing the batch MOVE of B, with the flag lost on EXPUNGE). `buildLanes`
/// fixes this via
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
        folderPath: String = "INBOX",
        destinationPath: String? = nil,
        createdAt: Date
    ) -> PendingOperation {
        var op = PendingOperation(
            type: type, messageIds: messageIds, accountId: accountId,
            folderPath: folderPath, destinationPath: destinationPath)
        op.createdAt = createdAt
        return op
    }

    // MARK: - 1. Batch + single sharing a member id merge into ONE lane

    @Test("batch [A,B,C] + single [B] merge into ONE lane, in createdAt order")
    func batchAndSingleShareMemberMergeIntoOneLane() {
        let now = Date()
        let batchOp = makeOp(type: .move, messageIds: ["A", "B", "C"], createdAt: now)
        let singleOp = makeOp(type: .markFlagged, messageIds: ["B"], createdAt: now.addingTimeInterval(1))

        let lanes = AccountManager.buildLanes([batchOp, singleOp], folderLocalAccountIds: [])

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

        let lanes = AccountManager.buildLanes([opAB, opCD, opBridge], folderLocalAccountIds: [])

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

        let lanes = AccountManager.buildLanes([opX, opY, opEmpty], folderLocalAccountIds: [])

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

        let lanes = AccountManager.buildLanes([opAcc1, opAcc2], folderLocalAccountIds: [])

        #expect(lanes.count == 2)
        let laneIds = lanes.map { $0.map(\.id) }
        #expect(laneIds.contains([opAcc1.id]))
        #expect(laneIds.contains([opAcc2.id]))
    }

    // MARK: - 5. Empty input / multiple disjoint empty-messageIds ops

    @Test("empty input produces no lanes")
    func emptyInputProducesNoLanes() {
        let lanes = AccountManager.buildLanes([], folderLocalAccountIds: [])
        #expect(lanes.isEmpty)
    }

    @Test("multiple empty-messageIds ops each get their own singleton lane (never merge with each other)")
    func multipleEmptyMessageIdsOpsStaySeparate() {
        let now = Date()
        let op1 = makeOp(type: .saveDraft, messageIds: [], createdAt: now)
        let op2 = makeOp(type: .deleteDraft, messageIds: [], createdAt: now.addingTimeInterval(1))

        let lanes = AccountManager.buildLanes([op1, op2], folderLocalAccountIds: [])

        #expect(lanes.count == 2)
        let laneIds = lanes.map { $0.map(\.id) }
        #expect(laneIds.contains([op1.id]))
        #expect(laneIds.contains([op2.id]))
    }

    // MARK: - 6. Address space: stable-id accounts key WITHOUT the folder

    /// THE INVARIANT (`IOS-QUEUE-008`): two queued ops naming the same provider
    /// RESOURCE never execute concurrently and execute in `createdAt` order.
    ///
    /// On Gmail/Graph a message id is folder-INDEPENDENT, and an undo inverse is
    /// by construction stamped with the forward op's DESTINATION as its source:
    /// delete → undo → delete again produces `TRASH→INBOX` at t0 and
    /// `INBOX→TRASH` at t0+1 on ONE message. Folder-qualifying the key put them
    /// in two lanes, `drainPendingQueue` ran the lanes concurrently, the inverse
    /// landed last, and the message the user had just deleted came back.
    @Test("stable-id account: an undo inverse (TRASH→INBOX) and a re-delete (INBOX→TRASH) of the SAME message share ONE lane, in createdAt order")
    func stableIdUndoInverseAndRedeleteShareOneLane() {
        let now = Date()
        let opInverse = makeOp(
            type: .move, messageIds: ["m1"], accountId: "acc-gmail",
            folderPath: "TRASH", destinationPath: "INBOX", createdAt: now)
        let opRedelete = makeOp(
            type: .move, messageIds: ["m1"], accountId: "acc-gmail",
            folderPath: "INBOX", destinationPath: "TRASH",
            createdAt: now.addingTimeInterval(1))

        let lanes = AccountManager.buildLanes(
            [opInverse, opRedelete], folderLocalAccountIds: [])

        #expect(lanes.count == 1,
                "two ops on one Gmail message must serialize — separate lanes race on the wire and the inverse can land last")
        guard lanes.count == 1 else { return }
        #expect(lanes[0].map(\.id) == [opInverse.id, opRedelete.id])
    }

    // MARK: - 7. Address space: folder-local accounts keep the folder in the key

    /// The NEGATIVE case that bounds test 6, and the `IOS-QUEUE-001` guard.
    ///
    /// An IMAP UID is mailbox-local: UID 77 in `INBOX` and UID 77 in `Archive`
    /// are DIFFERENT PHYSICAL MESSAGES. Merging them was a never-drop violation
    /// with a bystander — a lane halts on the first evidence refusal, so an op
    /// permanently wedged on `(INBOX, 77)` starved the unrelated message at
    /// `(Archive, 77)`, and no sync pass recovers a starved intention.
    @Test("folder-local account: the SAME UID in two folders stays in SEPARATE lanes (IOS-QUEUE-001 wedge-with-bystander guard)")
    func imapSameUidInTwoFoldersStaysInSeparateLanes() {
        let now = Date()
        let opInbox = makeOp(
            type: .markRead, messageIds: ["77"], accountId: "acc-imap",
            folderPath: "INBOX", createdAt: now)
        let opArchive = makeOp(
            type: .markFlagged, messageIds: ["77"], accountId: "acc-imap",
            folderPath: "Archive", createdAt: now.addingTimeInterval(1))

        let lanes = AccountManager.buildLanes(
            [opInbox, opArchive], folderLocalAccountIds: ["acc-imap"])

        #expect(lanes.count == 2,
                "UID 77 in INBOX and UID 77 in Archive are different messages — one's wedge must not starve the other")
        let laneIds = lanes.map { $0.map(\.id) }
        #expect(laneIds.contains([opInbox.id]))
        #expect(laneIds.contains([opArchive.id]))
    }

    // MARK: - 8. The two address spaces coexist in ONE call

    /// The key's provenance is the ACCOUNT's address space, decided per op, not
    /// a global mode: the same two-folder shape merges for the stable-id account
    /// and stays split for the folder-local one, in a single `buildLanes` call.
    @Test("one call, two address spaces: the same two-folder shape merges for the stable-id account and stays split for the folder-local one")
    func stableIdOpsInTwoFoldersMergeOnlyForTheStableIdAccount() {
        let now = Date()
        let stableInbox = makeOp(
            type: .move, messageIds: ["shared-99"], accountId: "acc-gmail",
            folderPath: "INBOX", destinationPath: "TRASH", createdAt: now)
        let stableTrash = makeOp(
            type: .move, messageIds: ["shared-99"], accountId: "acc-gmail",
            folderPath: "TRASH", destinationPath: "INBOX",
            createdAt: now.addingTimeInterval(1))
        let imapInbox = makeOp(
            type: .markRead, messageIds: ["shared-99"], accountId: "acc-imap",
            folderPath: "INBOX", createdAt: now.addingTimeInterval(2))
        let imapArchive = makeOp(
            type: .markRead, messageIds: ["shared-99"], accountId: "acc-imap",
            folderPath: "Archive", createdAt: now.addingTimeInterval(3))

        let lanes = AccountManager.buildLanes(
            [stableInbox, stableTrash, imapInbox, imapArchive],
            folderLocalAccountIds: ["acc-imap"])

        #expect(lanes.count == 3,
                "expected one merged stable-id lane plus two folder-local lanes, got \(lanes.map { $0.map(\.id) })")
        let laneIds = lanes.map { $0.map(\.id) }
        #expect(laneIds.contains([stableInbox.id, stableTrash.id]),
                "the stable-id account's two folder paths name ONE resource and must merge, in createdAt order")
        #expect(laneIds.contains([imapInbox.id]))
        #expect(laneIds.contains([imapArchive.id]))
        // No lane may mix accounts — the key is account-qualified in both spaces.
        for lane in lanes {
            #expect(Set(lane.map(\.accountId)).count == 1,
                    "a lane mixed accounts: \(lane.map { "\($0.accountId)/\($0.folderPath)" })")
        }
    }

    // MARK: - 9. The lane diagnostic renders every op, in lane order

    /// `laneDiagnosticSummary` is the formatter `drainPendingQueue` logs right
    /// after `buildLanes` returns, and it is the ONLY artifact that records which
    /// ops shared a lane and in what order. The lane assignment IS the ordering
    /// decision (`IOS-QUEUE-008`: same lane ⇒ serialized, separate lanes ⇒ raced),
    /// so a summary that silently omitted an op, or reordered one, would misreport
    /// the very fact a future investigation reads it for.
    ///
    /// It is deliberately pure — no dates, no clock, no I/O — so it can be pinned
    /// here without a DB, a provider or an actor hop, exactly like `buildLanes`.
    @Test("lane diagnostic names every op with its address, in lane order")
    func laneDiagnosticSummaryNamesEveryOpInLaneOrder() {
        let now = Date()
        // Same two-lane shape the suite uses above: one merged stable-id lane
        // (undo inverse + re-delete of ONE Gmail message) plus a disjoint lane.
        let opInverse = makeOp(
            type: .move, messageIds: ["m1"], accountId: "acc-gmail",
            folderPath: "TRASH", destinationPath: "INBOX", createdAt: now)
        let opRedelete = makeOp(
            type: .move, messageIds: ["m1"], accountId: "acc-gmail",
            folderPath: "INBOX", destinationPath: "TRASH",
            createdAt: now.addingTimeInterval(1))
        let opOther = makeOp(
            type: .markRead, messageIds: ["m2"], accountId: "acc-gmail",
            folderPath: "INBOX", createdAt: now.addingTimeInterval(2))

        let lanes = AccountManager.buildLanes(
            [opInverse, opRedelete, opOther], folderLocalAccountIds: [])
        #expect(lanes.count == 2)
        guard lanes.count == 2 else { return }

        let summary = AccountManager.laneDiagnosticSummary(lanes)

        // Every op is named by the short id the drain's own lines print.
        for op in [opInverse, opRedelete, opOther] {
            #expect(summary.contains(String(op.id.prefix(8))),
                    "op \(op.id.prefix(8)) (\(op.type.rawValue)) missing from: \(summary)")
        }
        // …with its address, which is what makes a move readable at all.
        #expect(summary.contains("TRASH→INBOX"), "missing inverse address in: \(summary)")
        #expect(summary.contains("INBOX→TRASH"), "missing re-delete address in: \(summary)")
        // A non-move has no destination and renders the placeholder, not a crash.
        #expect(summary.contains("INBOX→-"), "missing destination-less address in: \(summary)")
        // Member ids are carried through — the lane key is derived from them.
        #expect(summary.contains("ids=[m1]"))
        #expect(summary.contains("ids=[m2]"))

        // ORDER IS THE POINT: within the merged lane the inverse precedes the
        // re-delete, matching `createdAt` order and therefore wire order.
        guard let inversePos = summary.range(of: String(opInverse.id.prefix(8))),
              let redeletePos = summary.range(of: String(opRedelete.id.prefix(8))) else {
            Issue.record("both merged-lane ops must appear in: \(summary)")
            return
        }
        #expect(inversePos.lowerBound < redeletePos.lowerBound,
                "the inverse must be rendered BEFORE the re-delete it serializes against: \(summary)")
        // Both lanes are labelled and sized, so a reader can tell 2 lanes of (2, 1)
        // from 1 lane of 3 — the difference between serialized and raced.
        #expect(summary.contains("lane0(2)"), "expected a 2-op lane 0 in: \(summary)")
        #expect(summary.contains("lane1(1)"), "expected a 1-op lane 1 in: \(summary)")
    }

    /// The empty case is not decoration: `drainPendingQueue` logs the summary
    /// BEFORE its `guard !lanes.isEmpty else { break }`, so an empty result is a
    /// reachable input on every drain that claimed nothing. It must render a
    /// visible marker rather than an empty string, or the line reads as a missing
    /// log instead of "nothing to drain".
    @Test("lane diagnostic on empty input renders a visible marker, not an empty line")
    func laneDiagnosticSummaryOnEmptyInputIsStable() {
        let summary = AccountManager.laneDiagnosticSummary([])
        #expect(!summary.isEmpty)
        #expect(summary == "<no lanes>")
    }
}
