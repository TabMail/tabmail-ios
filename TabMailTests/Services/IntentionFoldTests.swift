/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// Pure tests for memory-only intention coalescing. These cover ordinary
/// latest-wins field and move folding without specifying durable Undo behavior.
@Suite("IntentionFold memory coalescing")
struct IntentionFoldTests {

    // MARK: - Record helpers

    private func rec(
        _ seq: UInt64,
        ids: [String],
        _ kind: Intention.Kind,
        origin: IntentionOrigin = .gesture
    ) -> Intention {
        Intention(ids: ids, kind: kind, displays: [:], origin: origin, seq: seq)
    }

    private func folderTarget(_ path: String, isInbox: Bool = false) -> IntentionMoveTarget {
        .folder(folderId: "acc1:\(path)", folderPath: path, isInbox: isInbox)
    }

    // MARK: - Deterministic cases

    @Test("latest-wins per field: alternating isRead targets fold to the last")
    func latestWinsPerField() {
        let records = [
            rec(0, ids: ["m1"], .isRead(true)),
            rec(1, ids: ["m1"], .isRead(false)),
            rec(2, ids: ["m1"], .isRead(true)),
        ]
        let folded = IntentionFold.fold(records)
        #expect(folded.perId["m1"]?.isRead == true)
    }

    @Test("independent fields coalesce into one per-id intent")
    func independentFieldsCoalesce() {
        let records = [
            rec(0, ids: ["m1"], .isRead(true)),
            rec(1, ids: ["m1"], .isFlagged(true)),
            rec(2, ids: ["m1"], .actionTag(target: .reply, baseline: nil)),
        ]
        let folded = IntentionFold.fold(records)
        #expect(folded.perId["m1"]?.isRead == true)
        #expect(folded.perId["m1"]?.isFlagged == true)
        #expect(folded.perId["m1"]?.actionTag == .some(.reply))
    }

    @Test("batch record applies to every member id")
    func batchRecordAppliesToAllMembers() {
        let records = [rec(0, ids: ["m1", "m2", "m3"], .isRead(true))]
        let folded = IntentionFold.fold(records)
        #expect(folded.perId.count == 3)
        #expect(folded.perId["m2"]?.isRead == true)
    }

    @Test("move chain folds to the final destination per id (A→B→C ⇒ C)")
    func moveChainFoldsToFinalDestination() {
        let records = [
            rec(0, ids: ["m1"], .move(folderTarget("B"))),
            rec(1, ids: ["m1"], .move(folderTarget("C"))),
        ]
        let folded = IntentionFold.fold(records)
        #expect(folded.perId["m1"]?.moveTarget == folderTarget("C"))
    }

    @Test("divergent batch moves resolve per id: [A,B]→X then [B]→Y leaves A→X, B→Y")
    func divergentBatchMovesResolvePerId() {
        let records = [
            rec(0, ids: ["m1", "m2"], .move(folderTarget("X"))),
            rec(1, ids: ["m2"], .move(folderTarget("Y"))),
        ]
        let folded = IntentionFold.fold(records)
        #expect(folded.perId["m1"]?.moveTarget == folderTarget("X"))
        #expect(folded.perId["m2"]?.moveTarget == folderTarget("Y"))
    }

    @Test("tag baseline is first-touch and survives retags; target is latest")
    func tagBaselineFirstTouchTargetLatest() {
        let records = [
            rec(0, ids: ["m1"], .actionTag(target: .archive, baseline: .reply)),
            rec(1, ids: ["m1"], .actionTag(target: .delete, baseline: .archive)),
        ]
        let folded = IntentionFold.fold(records)
        #expect(folded.perId["m1"]?.actionTag == .some(.delete))
        #expect(folded.perId["m1"]?.actionTagBaseline == .some(.reply))
    }

    @Test("tag gating follows the pending location at the tag sequence")
    func tagGateLocationAtTagSeqAndGatedOffNoOp() {
        // move(Archive) → tag → move(INBOX): the tag was gestured while the
        // pending location was Archive — serial replay drops it as a no-op
        // (ADR-IOS-058 write gate). Round D-0: a move no longer clears the
        // pending tag state either way, so there is nothing left for the
        // later return-to-inbox move to "resurrect" — the gated-off tag
        // record stays a pure no-op regardless of the moves around it.
        let records = [
            rec(0, ids: ["m1"], .move(folderTarget("Archive"))),
            rec(1, ids: ["m1"], .actionTag(target: .delete, baseline: nil)),
            rec(2, ids: ["m1"], .move(folderTarget("INBOX", isInbox: true))),
        ]
        let folded = IntentionFold.fold(records)
        #expect(folded.perId["m1"]?.actionTag == nil, "gated-off tag never becomes an intent")
        #expect(folded.perId["m1"]?.moveTarget == folderTarget("INBOX", isInbox: true))

        // Contrast: tag AFTER the explicit return move applies (gate true).
        let applied = IntentionFold.fold([
            rec(0, ids: ["m1"], .move(folderTarget("Archive"))),
            rec(1, ids: ["m1"], .move(folderTarget("INBOX", isInbox: true))),
            rec(2, ids: ["m1"], .actionTag(target: .delete, baseline: nil)),
        ])
        #expect(applied.perId["m1"]?.actionTag == .some(.delete))
        #expect(applied.perId["m1"]?.actionTagGate == true)
    }

    @Test("Round D-0: move(out) then move(back to inbox) in one in-memory batch, with NO tag record at all, leaves actionTag untouched (defers to row truth) — the tag is retained, not resurrected-then-suppressed")
    func moveOutThenBackInSameBatchLeavesActionTagUntouched() {
        let records = [
            rec(0, ids: ["m1"], .move(folderTarget("Archive"))),
            rec(1, ids: ["m1"], .move(folderTarget("INBOX", isInbox: true))),
        ]
        let folded = IntentionFold.fold(records)
        // Outer optional nil means the field was never touched by this fold —
        // distinct from `.some(nil)` (an explicit clear). Untouched is exactly
        // what lets the executor leave the header's retained `actionTag` alone.
        #expect(folded.perId["m1"]?.actionTag == nil, "no clear synthesized for either leg of the round trip")
        #expect(folded.perId["m1"]?.moveTarget == folderTarget("INBOX", isInbox: true), "latest move wins")
    }

}
