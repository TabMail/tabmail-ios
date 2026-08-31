/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Invariant test layer — mechanizes the "Never Drop User Intention" law
/// (`CLAUDE.md`, "Core Philosophy") as an assertable contract instead of a
/// per-test hand-check.
///
/// Motivating history: a quarantine gate whose `return nil` swallowed a whole
/// write closure — including the `PendingOperation` admission it was supposed
/// to leave alone — stayed green under its own unit tests, because those tests
/// only asserted the guard's new SCOPE (does the header insert get skipped) and
/// never the PROPERTY that every user intention terminates SOMEWHERE.
/// `IntentionLedger` is that missing property, made mechanical: `record()`
/// captures what a test's gesture SHOULD produce, `settle()` asserts every
/// recorded intention resolved into exactly one honest terminal state.
///
/// The ledger is deliberately **agnostic about the identity space** its
/// callers key by. It compares the strings it was handed against
/// `PendingOperation.messageIds` and against the caller-supplied set of
/// reported ids; it never classifies, normalizes, or reshapes an identity.
/// See `record(label:durableIdentity:…)` for why.
///
/// Written to be the invariant checker for the provider-id queue fuzzers and
/// the id-reset disposition matrix. Neither has landed yet, so this file's own
/// test suite is currently its only consumer.
final class IntentionLedger: Sendable {
    /// One user-authored intention a test performed.
    private struct Intention: Sendable {
        /// Human-readable label for failure dumps (e.g. "archive uid=42").
        let label: String
        /// The identity this intention's durable op carries in
        /// `PendingOperation.messageIds`. Whatever the producer under test
        /// actually queues — the ledger takes it verbatim and never
        /// reinterprets it.
        let durableIdentity: String
        /// The identity to match against the caller-supplied set of reported
        /// (announced-as-refused) ids. Defaults to `durableIdentity`, which is
        /// correct whenever a refusal is reported under the same key the
        /// durable op carries; a harness whose refusal channel reports in a
        /// DIFFERENT id space (e.g. `MessageHeader.id`, which is
        /// `accountId:folderPath:messageId`) passes it explicitly.
        let reportIdentity: String
        /// True when the caller determined, BEFORE performing the gesture,
        /// that the target end-state already matched (a redundant toggle,
        /// etc.) — PROVABLE-NOOP, asserted without further evaluation.
        let provableNoopAtGestureTime: Bool
        /// Non-nil when the caller claims this intention was dropped because
        /// the provider id space it was addressed in was reset underneath it.
        /// The witness is what makes that claim CHECKABLE — see
        /// `IdResetDropWitness`.
        let idResetDrop: IdResetDropWitness?
        /// Evaluated at `settle()` time against a fresh GRDB read: true when
        /// this intention's target end-state has been achieved.
        let endStateAchieved: @Sendable (Database) throws -> Bool
    }

    /// Evidence that an intention's provider id space really did reset under
    /// it, supplied by the caller at `record()` time and completed at
    /// `settle()` time.
    ///
    /// **Why this type exists.** A durable op keyed by a native provider id
    /// (an IMAP UID, which is only meaningful within one UIDVALIDITY
    /// generation) has no addressing mechanism left once that generation
    /// turns over: the id it holds either names nothing or names a DIFFERENT
    /// message. Dropping it is the correct, intended settlement — the
    /// intention's own precondition (a stable, identifiable target) became
    /// false, exactly as it does when another client deletes the message
    /// first. That is an accepted terminal state, not a never-drop violation.
    ///
    /// But "the epoch changed under it" is a *premise*, and a checker that
    /// accepts the premise on the caller's word is a checker that waves
    /// through every real silent drop as the accepted exception. So the
    /// caller must show the two epochs and `settle()` decides: a drop is only
    /// accepted when the epoch at gesture time and the epoch at settle time
    /// are both KNOWN and DIFFERENT. Anything else — either epoch unknown, or
    /// the two equal — settles `.unaccounted`.
    struct IdResetDropWitness: Sendable {
        /// A real UIDVALIDITY is non-zero, so `0` carries no generation
        /// information — it is the same "the server did not report a value"
        /// sentinel `Folder.lastKnownUidValidity`'s doc comment describes, and
        /// that column never stores it. An unknown epoch cannot witness a
        /// divergence.
        private static let absentEpoch = 0

        /// The id-space generation the gesture was issued against, as the
        /// caller observed it. `nil` (or `0`) means "not observed" — an
        /// honest value, and one that cannot justify a drop.
        let epochAtGesture: Int?

        /// The id-space generation in effect when `settle()` runs. A closure
        /// because the reset happens AFTER `record()`; it takes the same
        /// `Database` handle `endStateAchieved` does, so a caller may read the
        /// stored folder epoch, and may equally ignore the handle and read the
        /// authority it is driving (e.g. the fake server's live UIDVALIDITY).
        let epochAtSettle: @Sendable (Database) throws -> Int?

        init(
            epochAtGesture: Int?,
            epochAtSettle: @escaping @Sendable (Database) throws -> Int?
        ) {
            self.epochAtGesture = epochAtGesture
            self.epochAtSettle = epochAtSettle
        }

        /// True only when both epochs are known and differ.
        static func diverged(gesture: Int?, settle: Int?) -> Bool {
            guard let gesture, gesture != absentEpoch,
                  let settle, settle != absentEpoch else { return false }
            return gesture != settle
        }
    }

    /// One intention's settlement outcome — see the type's doc comment for the
    /// honest terminal states (`.unaccounted` is a ledger FAILURE, never a
    /// further valid state).
    enum Outcome: CustomStringConvertible, Equatable {
        /// A durable op for this identity reached provider success: no
        /// `PendingOperation` referencing it remains queued AND the caller's
        /// end-state predicate is true.
        case executed
        /// This identity appeared in the set of reported ids the caller handed
        /// `settle()` — a REPORTED refusal, never silent.
        case reportedRefused
        /// The target end-state already matched at gesture time — nothing
        /// needed to change, flagged by the caller at `record()` time.
        case provableNoop
        /// The op reached a terminal state (no longer queued) after the
        /// provider id space it was addressed in provably reset — see
        /// `IdResetDropWitness`. An accepted settlement, not a violation.
        case acceptedIdResetDrop
        /// Matched NONE of the above — a never-drop violation. Carries a
        /// diagnostic dump of what WAS observed.
        case unaccounted(String)

        var description: String {
            switch self {
            case .executed: return "EXECUTED"
            case .reportedRefused: return "REPORTED-REFUSED"
            case .provableNoop: return "PROVABLE-NOOP"
            case .acceptedIdResetDrop: return "ACCEPTED-ID-RESET-DROP"
            case .unaccounted(let detail): return "UNACCOUNTED (\(detail))"
            }
        }

        var isFailure: Bool {
            if case .unaccounted = self { return true }
            return false
        }
    }

    private let recorded = Mutex<[Intention]>([])

    /// Where `settle()` escalates a never-drop violation. Defaults to
    /// `Issue.record`, which is what every real consumer wants.
    ///
    /// It is injectable for two test-harness reasons: this ledger's own tests
    /// have to prove that a violation ESCALATES without joining the suite's
    /// known-issue tally, and a fuzzer may need to capture the generic ledger
    /// issue long enough to emit one richer issue with its admission, queue,
    /// server-state and bounded-transcript evidence. The sink never changes
    /// settlement or suppresses a production failure; it only lets the owning
    /// harness choose the single diagnostic that Swift Testing publishes.
    typealias IssueSink = @Sendable (String, Testing.SourceLocation) -> Void

    private let escalate: IssueSink

    init(escalate: @escaping IssueSink = IntentionLedger.recordIssue) {
        self.escalate = escalate
    }

    private static func recordIssue(_ message: String, at sourceLocation: Testing.SourceLocation) {
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    }

    /// Record one user-authored intention. Called by a harness once per
    /// gesture it performs, BEFORE (or immediately after) admitting it —
    /// "capture what the producer looked at", test-scoped and
    /// terminal-state-oriented.
    ///
    /// `durableIdentity` is taken **verbatim**: the ledger asks only whether a
    /// `PendingOperation` still carries that exact string. It deliberately
    /// does not classify the identity's shape. Shape classification would
    /// hard-code one keying scheme into the checker, and this branch is in the
    /// middle of moving durable ops from a Message-ID key to a native
    /// provider-id key — a checker that took a position on which one is
    /// "correct" would go wrong at exactly the commits it exists to police.
    func record(
        label: String,
        durableIdentity: String,
        reportIdentity: String? = nil,
        provableNoopAtGestureTime: Bool = false,
        idResetDrop: IdResetDropWitness? = nil,
        endStateAchieved: @escaping @Sendable (Database) throws -> Bool
    ) {
        recorded.withLock {
            $0.append(Intention(
                label: label,
                durableIdentity: durableIdentity,
                reportIdentity: reportIdentity ?? durableIdentity,
                provableNoopAtGestureTime: provableNoopAtGestureTime,
                idResetDrop: idResetDrop,
                endStateAchieved: endStateAchieved
            ))
        }
    }

    /// Snapshot count — mostly useful for a setup-sanity `#expect` before
    /// `settle()` (guard the harness itself registered what it meant to).
    var recordedCount: Int {
        recorded.withLock { $0.count }
    }

    /// Settle every recorded intention against DB/queue truth and assert (via
    /// the `escalate` sink — `Issue.record` unless a test injected its own)
    /// that none is `.unaccounted`. Returns the full
    /// per-intention outcome list too, so a caller that wants an additional
    /// `#expect` on the shape (e.g. "every outcome for phase X is
    /// `.executed`") can inspect it directly.
    ///
    /// "Still queued" means *any* `PendingOperation` row still carries the
    /// identity, whatever its `status` — a row that exists has not reached a
    /// terminal state.
    @discardableResult
    func settle(
        pool: DatabasePool,
        reportedIds: Set<String>,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) async -> [(label: String, outcome: Outcome)] {
        let snapshot = recorded.withLock { $0 }
        let allOps = (try? await pool.read { db in try PendingOperation.fetchAll(db) }) ?? []

        var results: [(label: String, outcome: Outcome)] = []
        results.reserveCapacity(snapshot.count)
        for intention in snapshot {
            if intention.provableNoopAtGestureTime {
                results.append((intention.label, .provableNoop))
                continue
            }
            let stillQueued = allOps.contains { $0.messageIds.contains(intention.durableIdentity) }
            if let witness = intention.idResetDrop {
                results.append((
                    intention.label,
                    await Self.settleIdResetDrop(
                        witness: witness,
                        durableIdentity: intention.durableIdentity,
                        stillQueued: stillQueued,
                        pool: pool
                    )
                ))
                continue
            }
            let endStateOk: Bool
            do {
                endStateOk = try await pool.read { db in try intention.endStateAchieved(db) }
            } catch {
                endStateOk = false
            }
            if !stillQueued, endStateOk {
                results.append((intention.label, .executed))
                continue
            }
            if reportedIds.contains(intention.reportIdentity) {
                results.append((intention.label, .reportedRefused))
                continue
            }
            results.append((
                intention.label,
                .unaccounted("stillQueued=\(stillQueued) endStateAchieved=\(endStateOk) durableIdentity=\(intention.durableIdentity) reportIdentity=\(intention.reportIdentity) reportedIds=\(reportedIds.sorted())")
            ))
        }

        let failures = results.filter(\.outcome.isFailure)
        if !failures.isEmpty {
            let dump = failures.map { "  - \($0.label): \($0.outcome)" }.joined(separator: "\n")
            escalate(
                "IntentionLedger: \(failures.count)/\(results.count) intention(s) UNACCOUNTED FOR (never-drop violation):\n\(dump)",
                sourceLocation
            )
        }
        return results
    }

    /// The id-reset branch of `settle()`. Two independent things must hold:
    /// the op reached SOME terminal state, and the id space really did reset.
    /// Claiming an id-reset drop only asserts termination — proving nothing
    /// was mutated at the recycled id is the wire oracle's job, not this
    /// ledger's.
    private static func settleIdResetDrop(
        witness: IdResetDropWitness,
        durableIdentity: String,
        stillQueued: Bool,
        pool: DatabasePool
    ) async -> Outcome {
        if stillQueued {
            return .unaccounted(
                "id-reset-drop op NEVER reached a terminal state — still queued, durableIdentity=\(durableIdentity)"
            )
        }
        let epochAtSettle: Int?
        do {
            epochAtSettle = try await pool.read { db in try witness.epochAtSettle(db) }
        } catch {
            epochAtSettle = nil
        }
        guard IdResetDropWitness.diverged(gesture: witness.epochAtGesture, settle: epochAtSettle) else {
            return .unaccounted(
                "labeled an id-reset drop, but the id space never provably reset: epochAtGesture=\(String(describing: witness.epochAtGesture)) epochAtSettle=\(String(describing: epochAtSettle)) durableIdentity=\(durableIdentity) — a drop with no witnessed epoch change is a SILENT DROP"
            )
        }
        return .acceptedIdResetDrop
    }
}
