/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Unit tests for `IntentionJournal` (ADR-IOS-058): append ordering,
/// fold-coverage bookkeeping, connected-component consume, the derived
/// overlay (merge semantics + in-flight display hold), receipts, and
/// read-error reinsertion. Each test uses its OWN journal instance — the
/// class is plain Mutex-guarded state, no shared singleton involved.
@Suite("IntentionJournal (ADR-IOS-058)")
struct IntentionJournalTests {

    private func append(
        _ journal: IntentionJournal,
        ids: [String],
        kind: Intention.Kind = .isRead(true),
        displays: [String: AccountManager.PendingMutation] = [:]
    ) -> (record: Intention, needsFold: Bool) {
        journal.append(ids: ids, kind: kind, displays: displays, origin: .gesture)
    }

    // MARK: - Append / coverage

    @Test("appends assign monotonic seqs in call order")
    func appendsAssignMonotonicSeqs() {
        let journal = IntentionJournal()
        let a = append(journal, ids: ["m1"]).record
        let b = append(journal, ids: ["m2"]).record
        let c = append(journal, ids: ["m1"]).record
        #expect(a.seq < b.seq && b.seq < c.seq)
        #expect(journal.recordsForTesting().map(\.seq) == [a.seq, b.seq, c.seq])
    }

    @Test("first record for an id needs a fold; a joiner on the same id does not")
    func firstRecordNeedsFoldJoinerDoesNot() {
        let journal = IntentionJournal()
        #expect(append(journal, ids: ["m1"]).needsFold == true)
        #expect(append(journal, ids: ["m1"]).needsFold == false)
        #expect(append(journal, ids: ["m2"]).needsFold == true, "disjoint id starts its own fold")
    }

    @Test("batch overlap is covered: [A] queued, then [A,B] covered, then [B] covered via the batch")
    func batchOverlapIsCovered() {
        let journal = IntentionJournal()
        #expect(append(journal, ids: ["A"]).needsFold == true)
        #expect(append(journal, ids: ["A", "B"]).needsFold == false, "shares A with the queued fold")
        #expect(append(journal, ids: ["B"]).needsFold == false, "B was marked covered by the batch append")
    }

    // MARK: - Consume

    @Test("consumeComponent unions transitively across batch records and leaves disjoint records")
    func consumeComponentUnionsAcrossBatches() {
        let journal = IntentionJournal()
        let a = append(journal, ids: ["A"]).record
        _ = append(journal, ids: ["C"])
        let ab = append(journal, ids: ["A", "B"]).record
        let b = append(journal, ids: ["B"]).record

        let consumed = journal.consumeComponent(triggerId: "A")
        #expect(consumed.map(\.seq) == [a.seq, ab.seq, b.seq], "component {A,B} in seq order")
        #expect(journal.recordsForTesting().map(\.ids) == [["C"]], "disjoint C remains")
    }

    @Test("consume clears coverage so a later append starts a fresh fold")
    func consumeClearsCoverage() {
        let journal = IntentionJournal()
        _ = append(journal, ids: ["m1"])
        _ = journal.consumeComponent(triggerId: "m1")
        #expect(append(journal, ids: ["m1"]).needsFold == true)
    }

    @Test("empty consume clears the trigger's coverage (sibling component already swallowed it)")
    func emptyConsumeClearsTrigger() {
        let journal = IntentionJournal()
        _ = append(journal, ids: ["A"])
        _ = append(journal, ids: ["A", "B"])
        // A's fold consumes the whole component, including B's coverage.
        _ = journal.consumeComponent(triggerId: "A")
        // B's (never-enqueued) fold would find nothing; an explicit consume
        // for B must clear its residual coverage so appends aren't stranded.
        let empty = journal.consumeComponent(triggerId: "B")
        #expect(empty.isEmpty)
        #expect(append(journal, ids: ["B"]).needsFold == true)
    }

    // MARK: - Derived overlay

    @Test("derived overlay merges displays latest-per-field, preserving unset fields")
    func derivedOverlayMergesLatestPerField() {
        let journal = IntentionJournal()
        _ = append(journal, ids: ["m1"], kind: .isRead(true),
                   displays: ["m1": .init(isRead: true)])
        _ = append(journal, ids: ["m1"], kind: .isFlagged(true),
                   displays: ["m1": .init(isFlagged: true)])
        _ = append(journal, ids: ["m1"], kind: .isRead(false),
                   displays: ["m1": .init(isRead: false)])

        let overlay = journal.derivedOverlay()
        #expect(overlay["m1"]?.isRead == false, "latest isRead wins")
        #expect(overlay["m1"]?.isFlagged == true, "earlier isFlagged preserved")
    }

    @Test("derived overlay preserves the .some(nil) tag-clear distinctly from untouched")
    func derivedOverlayTagClear() {
        let journal = IntentionJournal()
        _ = append(journal, ids: ["m1"], kind: .actionTag(target: nil, baseline: .reply),
                   displays: ["m1": .init(actionTag: .some(nil))])
        let overlay = journal.derivedOverlay()
        #expect(overlay["m1"]?.actionTag == .some(ActionTag?.none), "tag CLEAR, not tag-untouched")
    }

    @Test("derived overlay holds consumed displays in flight, drops them after completion")
    func derivedOverlayInFlightHold() {
        let journal = IntentionJournal()
        _ = append(journal, ids: ["m1"], kind: .isRead(true), displays: ["m1": .init(isRead: true)])
        let consumed = journal.consumeComponent(triggerId: "m1")
        #expect(journal.derivedOverlay()["m1"]?.isRead == true, "in-flight hold covers the write window")
        _ = journal.completeExecution(consumed)
        #expect(journal.derivedOverlay()["m1"] == nil, "entry drops when nothing pending or in flight")
        #expect(journal.isFullyDrainedForTesting())
    }

    @Test("completion keeps the entry when a NEW record arrived during execution")
    func completionKeepsEntryForNewRecords() {
        let journal = IntentionJournal()
        _ = append(journal, ids: ["m1"], kind: .isRead(true), displays: ["m1": .init(isRead: true)])
        let consumed = journal.consumeComponent(triggerId: "m1")
        _ = append(journal, ids: ["m1"], kind: .isRead(false), displays: ["m1": .init(isRead: false)])
        _ = journal.completeExecution(consumed)
        #expect(journal.derivedOverlay()["m1"]?.isRead == false, "the new pending record keeps deriving")
        #expect(!journal.isFullyDrainedForTesting())
    }

    // MARK: - Receipts

    /// Bounded two-task race (pattern:
    /// `CoordinatedToolActionTests.recordAndWaitResumesOnVanishedRow`): a
    /// bare `await waiter.value` on a receipt continuation HANGS the whole
    /// test run on regression instead of failing — race the awaiting task
    /// against a 5s timeout task and assert the winner, so a stranded
    /// receipt is one red test. Unstructured `Task { }`s (not
    /// `withTaskGroup`) so a genuine hang can't force the test function
    /// itself to join the slow task at scope exit.
    private actor RaceOutcome {
        private(set) var winner: String?
        func declare(_ w: String) { if winner == nil { winner = w } }
    }

    /// Bounded poll for the race winner — 6s cap comfortably past the 5s
    /// timeout racer, so exactly one of the two tasks always declares.
    private func awaitWinner(_ outcome: RaceOutcome) async -> String? {
        var winner: String?
        for _ in 0..<600 where winner == nil {
            winner = await outcome.winner
            if winner == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        return winner
    }

    @Test("awaitCompletion resumes after completeExecution")
    func receiptResumesOnCompletion() async {
        let journal = IntentionJournal()
        let (record, _) = append(journal, ids: ["m1"])

        let outcome = RaceOutcome()
        Task {
            await journal.awaitCompletion(of: record.seq)
            await outcome.declare("resumed")
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await outcome.declare("timedOut")
        }
        // Let the waiter park (its check-and-store is atomic, so even if it
        // hasn't parked yet the consume/complete below can't strand it).
        await Task.yield()
        let consumed = journal.consumeComponent(triggerId: "m1")
        for receipt in journal.completeExecution(consumed) { receipt.resume() }

        let winner = await awaitWinner(outcome)
        #expect(winner == "resumed", "awaitCompletion must resume once completeExecution ran, not hang for 5s")
    }

    @Test("awaitCompletion on an already-completed seq resumes immediately")
    func receiptAlreadyCompletedResumesImmediately() async {
        let journal = IntentionJournal()
        let (record, _) = append(journal, ids: ["m1"])
        let consumed = journal.consumeComponent(triggerId: "m1")
        for receipt in journal.completeExecution(consumed) { receipt.resume() }

        let outcome = RaceOutcome()
        Task {
            await journal.awaitCompletion(of: record.seq)
            await outcome.declare("resumed")
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await outcome.declare("timedOut")
        }

        let winner = await awaitWinner(outcome)
        #expect(winner == "resumed", "awaitCompletion on an already-completed seq must resume immediately, not hang for 5s")
    }

    @Test("awaitCompletion stored between consume and completion still resumes")
    func receiptStoredWhileInFlight() async {
        let journal = IntentionJournal()
        let (record, _) = append(journal, ids: ["m1"])
        let consumed = journal.consumeComponent(triggerId: "m1")

        let outcome = RaceOutcome()
        Task {
            await journal.awaitCompletion(of: record.seq)
            await outcome.declare("resumed")
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await outcome.declare("timedOut")
        }
        await Task.yield()
        for receipt in journal.completeExecution(consumed) { receipt.resume() }

        let winner = await awaitWinner(outcome)
        #expect(winner == "resumed", "a receipt stored while its record is in flight must resume at completion, not hang for 5s")
    }

    // MARK: - Read-error reinsertion

    @Test("reinsertAfterReadError restores records in seq order and re-marks coverage")
    func reinsertRestoresRecordsAndCoverage() {
        let journal = IntentionJournal()
        let a = append(journal, ids: ["m1"]).record
        let b = append(journal, ids: ["m1"], kind: .isRead(false)).record
        let consumed = journal.consumeComponent(triggerId: "m1")
        #expect(consumed.count == 2)

        journal.reinsertAfterReadError(consumed)
        #expect(journal.recordsForTesting().map(\.seq) == [a.seq, b.seq])
        #expect(append(journal, ids: ["m1"]).needsFold == false, "coverage re-marked — the retry owns the re-enqueue")
        #expect(!journal.isFullyDrainedForTesting())
    }

    @Test("reinsertion interleaves correctly with records appended during the failed resolve")
    func reinsertInterleavesWithInterimAppends() {
        let journal = IntentionJournal()
        let a = append(journal, ids: ["m1"]).record
        let consumed = journal.consumeComponent(triggerId: "m1")
        let interim = append(journal, ids: ["m1"], kind: .isRead(false)).record
        journal.reinsertAfterReadError(consumed)
        #expect(journal.recordsForTesting().map(\.seq) == [a.seq, interim.seq], "seq order restored across the reinsert")
    }

    // MARK: - record() with empty ids (Fix 5)

    /// An empty-`ids` record can never be consumed: `consumeComponent`'s
    /// component search starts from a triggerId and an empty `ids` array can
    /// never match one (`record.ids.contains(where: componentIds.contains)`
    /// is vacuously false), so it would sit in the journal forever —
    /// `isFullyDrained()` false forever, and any `recordAndWait` caller's
    /// `awaitCompletion` hangs forever. All callers currently guard
    /// themselves; `AccountManager.record`/`recordAndWait` must refuse an
    /// empty-ids call BEFORE appending, as defense in depth.
    @Test("AccountManager.record with empty ids is refused before appending — recordAndWait resumes immediately instead of hanging forever")
    func recordWithEmptyIdsIsRefusedBeforeAppending() async {
        let outcome = RaceOutcome()
        Task {
            await AccountManager.shared.recordAndWait(
                ids: [], kind: .isRead(true), displays: [:], origin: .gesture
            )
            await outcome.declare("resumed")
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await outcome.declare("timedOut")
        }

        let winner = await awaitWinner(outcome)
        #expect(winner == "resumed", "record() with empty ids must never append an unconsumable record — recordAndWait must not hang")

        #expect(
            !AccountManager.shared.intentionJournal.recordsForTesting().contains { $0.ids.isEmpty },
            "no journal residue from the refused empty-ids record — no legitimate caller ever appends one"
        )
    }
}
