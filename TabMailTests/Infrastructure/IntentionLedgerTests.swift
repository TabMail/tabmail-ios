/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// T0.3 — the checker's own contract tests.
///
/// `IntentionLedger` is the mechanized form of "Never Drop User Intention": it
/// exists so a suite can PROVE every intention it issued reached exactly one
/// honest terminal state. Two properties therefore matter more than any other,
/// and this suite pins both:
///
/// 1. **An op dropped because its provider id space reset settles cleanly.**
///    That is a correct, intended settlement — the id the op carries stopped
///    naming anything once the generation turned over — so it must NOT be
///    reported as a dropped intention.
/// 2. **The checker can still fail.** An intention that reaches none of the
///    accepted dispositions settles `.unaccounted` AND escalates. A checker
///    that cannot fail is worse than no checker.
///
/// **Red-first evidence (recorded 2026-07-30).** Three independent inversions of
/// `IntentionLedger`, each run against this suite; every inversion was reverted
/// afterwards and both files re-verified byte-identical by md5.
///
/// *Inversion A — `settle()`'s `if let witness = intention.idResetDrop` branch
/// deleted, so an id-reset-labeled intention falls through to the generic path
/// (the shape this file exists to change).* 4 of 11 tests fail, 11 issues.
/// `idResetDropSettlesAndIsNotUnaccounted` observes
/// `UNACCOUNTED (stillQueued=false endStateAchieved=false durableIdentity=4021
/// reportIdentity=4021 reportedIds=[])` where `ACCEPTED-ID-RESET-DROP` is
/// expected, and the ledger escalates `1/1 intention(s) UNACCOUNTED FOR
/// (never-drop violation)` for a settlement that was correct.
/// `settleReportsEveryIntentionAndNamesFailures` observes `3` failures where `2`
/// are expected. `idResetDropWithoutEpochChangeIsUnaccounted` and
/// `idResetDropStillQueuedIsUnaccounted` still fail, on their detail strings —
/// the generic path cannot say WHY. This is the headline proof: without the
/// branch, a correct id-reset settlement is reported as a dropped intention.
///
/// *Inversion B — `IdResetDropWitness.diverged` returns `true`
/// unconditionally, i.e. the caller's `idResetDrop` label is believed instead
/// of checked.* `idResetDropWithoutEpochChangeIsUnaccounted` observes
/// `ACCEPTED-ID-RESET-DROP` where `UNACCOUNTED` is expected and
/// `recorder.messages.count` is `0` where `1` is expected — an op that vanished
/// with epoch 11 at both ends is waved through. All five unwitnessable epoch
/// pairs (`nil`/`0` at either end) and the throwing witness are likewise
/// accepted. An unchecked label is an escape hatch through the whole checker.
///
/// *Inversion C — `settle()`'s final fall-through appends `.executed` instead
/// of `.unaccounted`, i.e. the ledger loses its ability to fail.*
/// `vanishedOpWithNoDispositionIsUnaccounted` observes `EXECUTED` for an
/// intention with no queued op, no end state and no report;
/// `opStuckInQueueIsUnaccounted` observes `EXECUTED` for an op still sitting in
/// `pendingOperation`; the cross-id-space half of
/// `reportedRefusalMatchesReportIdentity` observes `EXECUTED`. In each case
/// `recorder.messages.count` is `0` where `1` is expected.
@Suite("T0.3 — IntentionLedger settles every intention or fails")
struct IntentionLedgerTests {

    // MARK: - Fixtures

    /// A real on-disk `DatabasePool` carrying the production schema — the
    /// ledger reads `PendingOperation` rows, so the table has to be the real
    /// one. `DatabasePool` needs WAL, which `:memory:` cannot provide.
    private static func makeFixture() throws -> (pool: DatabasePool, directory: URL, appDb: AppDatabase) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intentionledger_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: config
        )
        let appDb = try AppDatabase(dbPool: pool)
        return (pool, directory, appDb)
    }

    /// Captures what `settle()` escalates instead of letting it reach
    /// `Issue.record` — see `IntentionLedger.IssueSink` for why the seam
    /// exists rather than `withKnownIssue`.
    private final class EscalationRecorder: Sendable {
        private let storage = Mutex<[String]>([])

        var messages: [String] { storage.withLock { $0 } }

        /// Captures `self` (a `Sendable` class), never the `Mutex` itself —
        /// `Mutex` is non-copyable and cannot be captured by an escaping
        /// closure.
        var sink: IntentionLedger.IssueSink {
            { message, _ in self.append(message) }
        }

        private func append(_ message: String) {
            storage.withLock { $0.append(message) }
        }
    }

    /// A `Sendable` box an escaping `@Sendable` closure can flip — same
    /// non-copyable constraint as `EscalationRecorder`.
    private final class EvaluationFlag: Sendable {
        private let storage = Mutex(false)

        var isSet: Bool { storage.withLock { $0 } }

        func set() { storage.withLock { $0 = true } }
    }

    private static func insert(
        _ op: PendingOperation,
        into pool: DatabasePool
    ) throws {
        try pool.writeWithoutTransaction { db in _ = try op.inserted(db) }
    }

    /// Unwraps an `.unaccounted` detail string, failing loudly otherwise.
    private static func unaccountedDetail(
        _ outcome: IntentionLedger.Outcome,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> String? {
        guard case .unaccounted(let detail) = outcome else {
            Issue.record(
                "expected UNACCOUNTED, observed \(outcome)",
                sourceLocation: sourceLocation
            )
            return nil
        }
        return detail
    }

    // MARK: - 1. The headline property: an id-reset drop settles

    @Test("HEADLINE — an op dropped after its id space reset settles ACCEPTED-ID-RESET-DROP, not UNACCOUNTED")
    func idResetDropSettlesAndIsNotUnaccounted() async throws {
        let (pool, directory, appDb) = try Self.makeFixture()
        defer { withExtendedLifetime(appDb) { TestDatabaseTeardown.retire(pool: pool, directory: directory) } }

        let recorder = EscalationRecorder()
        let ledger = IntentionLedger(escalate: recorder.sink)

        // The gesture was admitted under epoch 11 and the op is gone from the
        // queue; by settle time the mailbox is on epoch 22. The archive never
        // happened (end state false) and nothing was reported — under every
        // other disposition this is a dropped intention. It is not: the UID
        // the op carried stopped naming anything at the epoch boundary.
        ledger.record(
            label: "archive uid=4021",
            durableIdentity: "4021",
            idResetDrop: .init(epochAtGesture: 11, epochAtSettle: { _ in 22 })
        ) { _ in false }

        #expect(ledger.recordedCount == 1)

        let outcomes = await ledger.settle(pool: pool, reportedIds: [])

        #expect(outcomes.count == 1)
        guard outcomes.count == 1 else { return }
        #expect(outcomes[0].outcome == .acceptedIdResetDrop)
        #expect(outcomes[0].outcome.isFailure == false)
        #expect(outcomes[0].outcome.description == "ACCEPTED-ID-RESET-DROP")
        #expect(recorder.messages.isEmpty)
    }

    // MARK: - 2. The checker can still fail

    @Test("a vanished op with no accepted disposition settles UNACCOUNTED and escalates")
    func vanishedOpWithNoDispositionIsUnaccounted() async throws {
        let (pool, directory, appDb) = try Self.makeFixture()
        defer { withExtendedLifetime(appDb) { TestDatabaseTeardown.retire(pool: pool, directory: directory) } }

        let recorder = EscalationRecorder()
        let ledger = IntentionLedger(escalate: recorder.sink)

        // No PendingOperation row, end state not achieved, nothing reported,
        // no id-reset witness — the intention simply evaporated.
        ledger.record(label: "archive uid=7", durableIdentity: "7") { _ in false }

        let outcomes = await ledger.settle(pool: pool, reportedIds: [])

        #expect(outcomes.count == 1)
        guard outcomes.count == 1 else { return }
        #expect(outcomes[0].outcome.isFailure)
        let detail = Self.unaccountedDetail(outcomes[0].outcome)
        #expect(detail?.contains("stillQueued=false") == true)
        #expect(detail?.contains("endStateAchieved=false") == true)
        #expect(detail?.contains("durableIdentity=7") == true)
        #expect(recorder.messages.count == 1)
        #expect(recorder.messages.first?.contains("UNACCOUNTED FOR (never-drop violation)") == true)
        #expect(recorder.messages.first?.contains("archive uid=7") == true)
    }

    @Test("an op that never left the queue and never took effect is UNACCOUNTED")
    func opStuckInQueueIsUnaccounted() async throws {
        let (pool, directory, appDb) = try Self.makeFixture()
        defer { withExtendedLifetime(appDb) { TestDatabaseTeardown.retire(pool: pool, directory: directory) } }

        let recorder = EscalationRecorder()
        let ledger = IntentionLedger(escalate: recorder.sink)

        try Self.insert(
            PendingOperation(type: .move, messageIds: ["31"], accountId: "acc1", folderPath: "INBOX"),
            into: pool
        )
        ledger.record(label: "move uid=31", durableIdentity: "31") { _ in false }

        let outcomes = await ledger.settle(pool: pool, reportedIds: [])

        #expect(outcomes.count == 1)
        guard outcomes.count == 1 else { return }
        #expect(outcomes[0].outcome.isFailure)
        #expect(Self.unaccountedDetail(outcomes[0].outcome)?.contains("stillQueued=true") == true)
        #expect(recorder.messages.count == 1)
    }

    // MARK: - 3. The id-reset label is CHECKED, never taken on the caller's word

    @Test("claiming an id-reset drop while the epoch never changed is UNACCOUNTED")
    func idResetDropWithoutEpochChangeIsUnaccounted() async throws {
        let (pool, directory, appDb) = try Self.makeFixture()
        defer { withExtendedLifetime(appDb) { TestDatabaseTeardown.retire(pool: pool, directory: directory) } }

        let recorder = EscalationRecorder()
        let ledger = IntentionLedger(escalate: recorder.sink)

        // Same epoch at both ends: the id space never turned over, so the op's
        // disappearance is an ordinary silent drop wearing the exception's
        // label. Accepting it here is precisely how a never-drop violation
        // would slip past the checker.
        ledger.record(
            label: "archive uid=4021",
            durableIdentity: "4021",
            idResetDrop: .init(epochAtGesture: 11, epochAtSettle: { _ in 11 })
        ) { _ in false }

        let outcomes = await ledger.settle(pool: pool, reportedIds: [])

        #expect(outcomes.count == 1)
        guard outcomes.count == 1 else { return }
        #expect(outcomes[0].outcome.isFailure)
        let detail = Self.unaccountedDetail(outcomes[0].outcome)
        #expect(detail?.contains("never provably reset") == true)
        #expect(detail?.contains("epochAtGesture=Optional(11)") == true)
        #expect(detail?.contains("epochAtSettle=Optional(11)") == true)
        #expect(recorder.messages.count == 1)
    }

    @Test("an id-reset drop whose epoch pair cannot witness a reset is UNACCOUNTED")
    func idResetDropWithUnwitnessableEpochsIsUnaccounted() async throws {
        let (pool, directory, appDb) = try Self.makeFixture()
        defer { withExtendedLifetime(appDb) { TestDatabaseTeardown.retire(pool: pool, directory: directory) } }

        // `nil` is "not observed"; `0` is the same absence in the shape
        // `Folder.lastKnownUidValidity` stores it. Neither can witness a
        // divergence, so neither may license a drop.
        let unwitnessable: [(gesture: Int?, settle: Int?)] = [
            (nil, 22),
            (11, nil),
            (nil, nil),
            (0, 22),
            (11, 0)
        ]

        for pair in unwitnessable {
            let recorder = EscalationRecorder()
            let ledger = IntentionLedger(escalate: recorder.sink)
            ledger.record(
                label: "archive uid=4021 gesture=\(String(describing: pair.gesture)) settle=\(String(describing: pair.settle))",
                durableIdentity: "4021",
                idResetDrop: .init(
                    epochAtGesture: pair.gesture,
                    epochAtSettle: { _ in pair.settle }
                )
            ) { _ in false }

            let outcomes = await ledger.settle(pool: pool, reportedIds: [])
            #expect(outcomes.count == 1)
            guard outcomes.count == 1 else { return }
            #expect(
                outcomes[0].outcome.isFailure,
                "epoch pair \(String(describing: pair)) must not license a drop, observed \(outcomes[0].outcome)"
            )
            #expect(recorder.messages.count == 1)
        }
    }

    @Test("an id-reset-labeled op that is still queued has reached no terminal state — UNACCOUNTED")
    func idResetDropStillQueuedIsUnaccounted() async throws {
        let (pool, directory, appDb) = try Self.makeFixture()
        defer { withExtendedLifetime(appDb) { TestDatabaseTeardown.retire(pool: pool, directory: directory) } }

        let recorder = EscalationRecorder()
        let ledger = IntentionLedger(escalate: recorder.sink)

        try Self.insert(
            PendingOperation(type: .move, messageIds: ["4021"], accountId: "acc1", folderPath: "INBOX"),
            into: pool
        )
        // A genuine epoch change, but the op is still sitting in the queue —
        // "dropped because the id space reset" is a claim about a TERMINAL
        // state, and this one has not reached any.
        ledger.record(
            label: "archive uid=4021",
            durableIdentity: "4021",
            idResetDrop: .init(epochAtGesture: 11, epochAtSettle: { _ in 22 })
        ) { _ in false }

        let outcomes = await ledger.settle(pool: pool, reportedIds: [])

        #expect(outcomes.count == 1)
        guard outcomes.count == 1 else { return }
        #expect(outcomes[0].outcome.isFailure)
        #expect(
            Self.unaccountedDetail(outcomes[0].outcome)?
                .contains("NEVER reached a terminal state") == true
        )
        #expect(recorder.messages.count == 1)
    }

    @Test("a witness that throws cannot license a drop")
    func idResetDropWithThrowingWitnessIsUnaccounted() async throws {
        let (pool, directory, appDb) = try Self.makeFixture()
        defer { withExtendedLifetime(appDb) { TestDatabaseTeardown.retire(pool: pool, directory: directory) } }

        struct WitnessFailure: Error {}

        let recorder = EscalationRecorder()
        let ledger = IntentionLedger(escalate: recorder.sink)
        ledger.record(
            label: "archive uid=4021",
            durableIdentity: "4021",
            idResetDrop: .init(epochAtGesture: 11, epochAtSettle: { _ in throw WitnessFailure() })
        ) { _ in false }

        let outcomes = await ledger.settle(pool: pool, reportedIds: [])

        #expect(outcomes.count == 1)
        guard outcomes.count == 1 else { return }
        #expect(outcomes[0].outcome.isFailure)
        #expect(recorder.messages.count == 1)
    }

    // MARK: - 4. The other accepted dispositions

    @Test("an executed intention settles EXECUTED and escalates nothing (default Issue.record sink)")
    func executedIntentionSettles() async throws {
        let (pool, directory, appDb) = try Self.makeFixture()
        defer { withExtendedLifetime(appDb) { TestDatabaseTeardown.retire(pool: pool, directory: directory) } }

        // Default init — the production sink. If this settled as anything
        // other than EXECUTED the ledger would record a real issue and this
        // test would fail, which is the point of using it here.
        let ledger = IntentionLedger()
        ledger.record(label: "archive uid=9", durableIdentity: "9") { _ in true }

        let outcomes = await ledger.settle(pool: pool, reportedIds: [])

        #expect(outcomes.count == 1)
        guard outcomes.count == 1 else { return }
        #expect(outcomes[0].outcome == .executed)
        #expect(outcomes[0].outcome.description == "EXECUTED")
    }

    @Test("a refusal reported in a different id space settles REPORTED-REFUSED via reportIdentity")
    func reportedRefusalMatchesReportIdentity() async throws {
        let (pool, directory, appDb) = try Self.makeFixture()
        defer { withExtendedLifetime(appDb) { TestDatabaseTeardown.retire(pool: pool, directory: directory) } }

        let headerId = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "9")

        let matched = IntentionLedger(escalate: EscalationRecorder().sink)
        matched.record(
            label: "label-apply uid=9",
            durableIdentity: "9",
            reportIdentity: headerId
        ) { _ in false }
        let matchedOutcomes = await matched.settle(pool: pool, reportedIds: [headerId])
        #expect(matchedOutcomes.count == 1)
        guard matchedOutcomes.count == 1 else { return }
        #expect(matchedOutcomes[0].outcome == .reportedRefused)
        #expect(matchedOutcomes[0].outcome.description == "REPORTED-REFUSED")

        // The two id spaces are matched independently: a report carrying the
        // DURABLE key does not satisfy an intention whose refusal is announced
        // under its header key.
        let recorder = EscalationRecorder()
        let mismatched = IntentionLedger(escalate: recorder.sink)
        mismatched.record(
            label: "label-apply uid=9",
            durableIdentity: "9",
            reportIdentity: headerId
        ) { _ in false }
        let mismatchedOutcomes = await mismatched.settle(pool: pool, reportedIds: ["9"])
        #expect(mismatchedOutcomes.count == 1)
        guard mismatchedOutcomes.count == 1 else { return }
        #expect(mismatchedOutcomes[0].outcome.isFailure)
        #expect(recorder.messages.count == 1)
    }

    @Test("a provable no-op settles without evaluating the end-state predicate")
    func provableNoopSettlesWithoutEvaluation() async throws {
        let (pool, directory, appDb) = try Self.makeFixture()
        defer { withExtendedLifetime(appDb) { TestDatabaseTeardown.retire(pool: pool, directory: directory) } }

        let evaluated = EvaluationFlag()
        let ledger = IntentionLedger(escalate: EscalationRecorder().sink)
        ledger.record(
            label: "mark-read uid=12 (already read)",
            durableIdentity: "12",
            provableNoopAtGestureTime: true
        ) { _ in
            evaluated.set()
            return false
        }

        let outcomes = await ledger.settle(pool: pool, reportedIds: [])

        #expect(outcomes.count == 1)
        guard outcomes.count == 1 else { return }
        #expect(outcomes[0].outcome == .provableNoop)
        #expect(outcomes[0].outcome.description == "PROVABLE-NOOP")
        #expect(evaluated.isSet == false)
    }

    // MARK: - 5. Aggregate reporting

    @Test("settle reports every intention, and escalates once naming each failure")
    func settleReportsEveryIntentionAndNamesFailures() async throws {
        let (pool, directory, appDb) = try Self.makeFixture()
        defer { withExtendedLifetime(appDb) { TestDatabaseTeardown.retire(pool: pool, directory: directory) } }

        let recorder = EscalationRecorder()
        let ledger = IntentionLedger(escalate: recorder.sink)

        ledger.record(label: "executed", durableIdentity: "1") { _ in true }
        ledger.record(label: "noop", durableIdentity: "2", provableNoopAtGestureTime: true) { _ in false }
        ledger.record(
            label: "id-reset",
            durableIdentity: "3",
            idResetDrop: .init(epochAtGesture: 11, epochAtSettle: { _ in 22 })
        ) { _ in false }
        ledger.record(label: "dropped-a", durableIdentity: "4") { _ in false }
        ledger.record(label: "dropped-b", durableIdentity: "5") { _ in false }

        #expect(ledger.recordedCount == 5)

        let outcomes = await ledger.settle(pool: pool, reportedIds: [])

        #expect(outcomes.count == 5)
        guard outcomes.count == 5 else { return }
        #expect(outcomes.map(\.label) == ["executed", "noop", "id-reset", "dropped-a", "dropped-b"])
        #expect(outcomes.filter(\.outcome.isFailure).count == 2)
        #expect(recorder.messages.count == 1)
        let escalation = recorder.messages[0]
        #expect(escalation.contains("2/5 intention(s) UNACCOUNTED FOR"))
        #expect(escalation.contains("- dropped-a:"))
        #expect(escalation.contains("- dropped-b:"))
        // The dump names failures only — the three settled intentions are absent.
        #expect(escalation.contains("- executed:") == false)
        #expect(escalation.contains("- noop:") == false)
        #expect(escalation.contains("- id-reset:") == false)
    }
}
