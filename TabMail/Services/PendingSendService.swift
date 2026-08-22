/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The destructive action an Outbox row may truthfully offer at an instant.
enum OutboxCancellationAction: Equatable, Sendable {
    case cancelSend
    case discard

    var label: String {
        switch self {
        case .cancelSend: "Cancel Send"
        case .discard: "Discard"
        }
    }

    var systemImage: String {
        switch self {
        case .cancelSend: "xmark.circle"
        case .discard: "trash"
        }
    }
}

/// Converts wall-clock deadline intervals to the nanoseconds accepted by
/// `Task.sleep` without trapping at either numeric boundary.
enum OutboxDeadlineScheduler {
    private static let nanosecondsPerSecond: TimeInterval = 1_000_000_000
    /// `Double(UInt64.max)` rounds up to 2^64 and is not itself convertible.
    /// `nextDown` is the largest representable Double strictly below that trap.
    private static let maxConvertibleNanoseconds = Double(UInt64.max).nextDown

    static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard !interval.isNaN else { return 0 }
        let nanoseconds = max(0, interval) * nanosecondsPerSecond
        return UInt64(min(nanoseconds, maxConvertibleNanoseconds))
    }

    static func nanoseconds(until deadline: Date, at instant: Date) -> UInt64 {
        nanoseconds(for: deadline.timeIntervalSince(instant))
    }
}

/// One policy shared by every UI affordance over the Outbox send hold.
enum OutboxCancellationPolicy {
    /// The last instant at which cancellation may be offered. The full claim
    /// buffer remains after this deadline for the synchronous confirmed discard
    /// to commit before the drain becomes eligible to claim the row.
    static func undoDeadline(for holdUntil: Date?) -> Date {
        guard let holdUntil else { return .distantPast }
        return holdUntil.addingTimeInterval(-SyncConfig.outboxClaimBufferSeconds)
    }

    /// Resolve from durable row state at a caller-supplied instant. A queued row
    /// loses its cancellation affordance at the SAME buffered deadline as the
    /// compose toast. After that boundary a queued row may still offer the
    /// lower-guarantee Discard action so an offline/stuck send retains user
    /// agency, but it must not still call that action "Cancel Send". Failed rows
    /// remain discardable and sending rows offer no destructive action.
    static func action(
        status: OutboxStatus,
        sentAt: Date?,
        holdUntil: Date?,
        at instant: Date
    ) -> OutboxCancellationAction? {
        // `sentAt` is the double-send firewall. Regardless of a stale status,
        // once provider success is stamped this row belongs only to Sent-append
        // recovery and no destructive send affordance can truthfully execute.
        guard sentAt == nil else { return nil }
        switch status {
        case .queued:
            return instant < undoDeadline(for: holdUntil) ? .cancelSend : .discard
        case .sending:
            return nil
        case .failed:
            return .discard
        }
    }
}

/// Which face the undo-send toast must show at a given instant.
///
/// Deliberately a free function of three `Date`s rather than a method that reads
/// the clock, so BOTH halves of the decision are evaluable at instants a test
/// chooses — the same reason `AccountManager.wakeUpDelay(for:at:)` takes `at:`
/// (`Companion/Memory/Current/100-…`). A decision that reads `Date()` internally
/// can only ever be pinned by a replica of itself, and a replica cannot go red on
/// a defect in the original.
enum PendingSendToastPhase: Equatable, Sendable {
    /// The Undo affordance is offered. `progress` drains 1 → 0 across the
    /// visible window.
    case undoable(progress: Double)
    /// "✓ Message queued" — durable admission acknowledged, with no claim
    /// that SMTP has completed.
    case queuedAcknowledgement

    /// 🚨 THE INVARIANT THIS FUNCTION EXISTS TO HOLD: `.undoable` is returned
    /// ONLY for an instant strictly before `undoDeadline`, and `undoDeadline` is
    /// derived from the row's DURABLE `OutboxMessage.holdUntil` — never from when
    /// the toast happened to appear. The affordance therefore cannot outlive the
    /// hold that backs it, whatever the persist latency was.
    static func resolve(
        at instant: Date,
        presentedAt: Date,
        undoDeadline: Date
    ) -> PendingSendToastPhase {
        guard instant < undoDeadline else { return .queuedAcknowledgement }
        // Drain the bar across whatever window actually remains. A slow persist
        // shortens the VISIBLE window; it never moves the deadline.
        let window = undoDeadline.timeIntervalSince(presentedAt)
        guard window > 0 else { return .queuedAcknowledgement }
        let remaining = undoDeadline.timeIntervalSince(instant) / window
        return .undoable(progress: max(0, min(1, remaining)))
    }
}

/// Tracks the single in-flight "undo send" toast. The user taps Send; this
/// service offers Undo only until the durable row's buffered cancellation
/// deadline, then acknowledges "✓ Message queued" briefly before fading.
/// That acknowledgement means the Send intention is durably admitted; it is not
/// evidence that SMTP has completed.
///
/// Design:
/// - Only one pending toast at a time (the most recent send). A second
///   `present()` replaces `current`; the previous message's OutboxMessage row
///   continues through its own hold → drain → send flow (its Undo is forfeited).
/// - Toast phase rendering lives in PendingSendToast (TimelineView, wall-clock).
///   This service only stores `current` and an auto-dismiss Task.
/// - `undo()` attempts a confirmed cancellation regardless of whether compose
///   reconstruction succeeds. Reopen is permitted only after that cancellation.
/// - The Draft row is retained and the reopen is bound to its exact generation.
@Observable
@MainActor
final class PendingSendService {
    static let shared = PendingSendService()

    struct Pending: Identifiable, Sendable {
        let id: String           // outboxId (matches OutboxMessage.id)
        let draftId: String
        let instanceEpoch: String
        let toSummary: String    // "To: user@example.com"
        /// When THIS TOAST appeared. Presentation only — the progress bar's span.
        ///
        /// ⚠️ Deliberately NOT called `queuedAt`. The send's `queuedAt` is a
        /// different instant, captured inside `AccountManager.persistQueuedSend`
        /// before its disk write and its awaited `dbPool.write`; this one is that
        /// instant plus the whole persist latency. Two variables with one name is
        /// exactly how the undo affordance came to outlive its hold (issue #76).
        let presentedAt: Date
        /// The DURABLE deadline this toast's Undo is backed by — the
        /// `OutboxMessage.holdUntil` of the row this toast represents. `nil` is a
        /// legacy pre-v49 row with no hold, which the drain treats as claimable
        /// immediately (`(holdUntil ?? .distantPast) <= Date()`).
        let holdUntil: Date?

        /// The last instant at which the Undo affordance may be offered: the
        /// durable hold, less the claim buffer the drain's `atomicClaim` needs.
        /// A `nil` hold yields `.distantPast`, so no Undo is ever offered for a
        /// row the drain may already claim — fail closed, never offer an undo we
        /// cannot honour.
        var undoDeadline: Date {
            OutboxCancellationPolicy.undoDeadline(for: holdUntil)
        }
    }

    struct RetainedDraftAuthority: Sendable, Equatable {
        let draftId: String
        let accountId: String
        let instanceEpoch: String

        func matches(_ draft: Draft) -> Bool {
            draft.id == draftId
                && draft.accountId == accountId
                && draft.instanceEpoch == instanceEpoch
        }
    }

    /// Process-local handoff authority. The retained Draft is the only content
    /// source; no absent-row payload or Outbox attachment fallback is carried.
    struct ReopenSnapshot: Identifiable, Sendable {
        let id: String  // outboxId — unique identifier for fullScreenCover(item:)
        let authority: RetainedDraftAuthority
    }

    private(set) var current: Pending?

    /// Non-nil ⇒ the last Undo tap could not be decided, so nothing was cancelled
    /// and the toast was deliberately left up. The view renders this and clears it.
    /// It states only the observed fact and never claims anything about what
    /// happened to the message — at this point we genuinely do not know.
    private(set) var undoFailureMessage: String?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Show the undo-send toast for the given outboxId. Replaces any
    /// previously-displayed pending (the prior message continues draining on
    /// its own schedule).
    ///
    /// `holdUntil` is the durable `OutboxMessage.holdUntil` of the row this toast
    /// represents, as returned by `AccountManager.queueSend`. It is REQUIRED, with
    /// no default, because a default would silently reinstate the defect it exists
    /// to close: the Undo affordance must be bounded by the deadline the drain
    /// honours, not by this method's own clock.
    func present(
        outboxId: String,
        draftId: String,
        instanceEpoch: String,
        toSummary: String,
        holdUntil: Date?
    ) {
        dismissTask?.cancel()
        undoFailureMessage = nil
        let now = Date()
        current = Pending(
            id: outboxId,
            draftId: draftId,
            instanceEpoch: instanceEpoch,
            toSummary: toSummary,
            presentedAt: now,
            holdUntil: holdUntil)

        // One auto-dismiss Task whose remaining visible window is anchored on the
        // DURABLE hold rather than on this instant:
        //   phase 1 (undo):     now → holdUntil - outboxClaimBufferSeconds
        //   phase 2 (✓ queued): deadline → holdUntil + queued acknowledgement
        //                       (it includes the claim buffer before SMTP starts)
        //   fade
        //
        // 🚨 `max(0, …)` is load-bearing, not defensive dressing: `holdUntil` can
        // already be in the past here (a long persist, or a dedup onto an older
        // in-flight row), and `UInt64(a negative Double)` is a runtime TRAP in
        // Swift — not a saturating conversion (`Companion/Memory/Current/100-…`).
        let total = max(0, (holdUntil ?? now).timeIntervalSince(now))
                  + SyncConfig.outboxQueuedAcknowledgementSeconds
        dismissTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: OutboxDeadlineScheduler.nanoseconds(for: total))
            guard !Task.isCancelled else { return }
            // PendingSendService is @MainActor, so the Task body is already
            // MainActor-isolated — no MainActor.run wrapper needed.
            guard self?.current?.id == outboxId else { return }
            self?.current = nil
        }
    }

    /// User tapped Undo. Only reachable while the toast is in phase 1 — the Undo
    /// button is rendered only while `PendingSendToastPhase.resolve` answers
    /// `.undoable`, i.e. strictly before `Pending.undoDeadline`, which is the
    /// row's durable `holdUntil` less the drain's claim buffer.
    ///
    /// Read exact retained authority first, then attempt confirmed cancellation.
    /// A refused cancellation leaves the toast in place. Reopen requires both the
    /// confirmed cancellation and exact retained authority.
    ///
    /// The read's THREE answers are routed separately — see
    /// `RetainedAuthorityOutcome` for why collapsing them was the defect.
    func undo() -> ReopenSnapshot? {
        guard let p = current else { return nil }
        switch retainedAuthorityOutcome(for: p) {
        case .readFailed:
            // We could not determine anything, so we decide nothing: the Outbox row
            // and the toast are left exactly as they were, and the user is told.
            // Do NOT reach for `discardOutboxMessageConfirmed` here — cancelling on
            // an unknown is the direction that loses the content (see the enum).
            undoFailureMessage = Self.undoNotConfirmedMessage
            return nil
        case .mismatchOrAbsent:
            // PROVEN not to be the generation this toast is holding. Cancel the send
            // — the user asked for that and we know it is safe — but reopen nothing.
            guard AccountManager.shared.discardOutboxMessageConfirmed(p.id) else {
                // 🚨 R16-9 — THE REFUSAL STAYS; ONLY THE SILENCE GOES.
                // `discardOutboxMessageConfirmed` returning `false` means the row was
                // not provably cancelled (Outbox Rules 3/10 — a `sending` row may
                // already have left the server, and the confirmed read is what keeps
                // this from becoming a double-send or a lost message). That direction
                // is DELIBERATELY HELD and must not become unconditional (`MIS-026`).
                // What was wrong is that this arm returned `nil` with no snapshot, no
                // cleared toast and no `undoFailureMessage` — while the sibling
                // `.readFailed` arm eight lines above sets one for the SAME user
                // experience. Under a suspended GRDB one root cause routed two ways:
                // one spoke, one was silent, and the message went out.
                undoFailureMessage = Self.undoNotConfirmedMessage
                return nil
            }
            dismissTask?.cancel()
            current = nil
            return nil
        case .verified(let authority):
            guard AccountManager.shared.discardOutboxMessageConfirmed(p.id) else {
                // R16-9 — same arm, same reason as `.mismatchOrAbsent` above. This is
                // the arm where the user had a reopenable draft in hand, so a silent
                // `nil` here reads as "Undo did nothing at all".
                undoFailureMessage = Self.undoNotConfirmedMessage
                return nil
            }
            dismissTask?.cancel()
            current = nil
            return ReopenSnapshot(id: p.id, authority: authority)
        }
    }

    /// The ONE string for "the cancellation was not confirmed, so nothing was
    /// changed" (R16-9). Held in one place for the same reason
    /// `DynamicIslandChat.autoSaveDidNotLandWarning` is: **three** exits
    /// surface it and a fourth must not arrive with a fourth wording.
    ///
    /// Predicate, and note the SHAPE — it excludes comment lines
    /// (`--pcre2 '^(?!\s*(///|//))'`) because a naive `rg -c` for the assignment
    /// matches THIS SENTENCE quoting it and returns four. `MIS-033`: a census that
    /// counts its own recording is off by one at the commit that writes it, and
    /// predicate-plus-number cannot catch an observer effect — only an instrument the
    /// sentence cannot enter can:
    ///   `rg --pcre2 -c '^(?!\s*(///|//)).*undoFailureMessage = Self\.undoNotConfirmedMessage'` It says only what was
    /// observed — like `undoFailureMessage`'s own contract, it claims nothing about
    /// what happened to the message, because at this point we do not know.
    private static let undoNotConfirmedMessage =
        "The cancellation wasn't confirmed. The message may already be sending."

    /// The three answers a retained-authority read can give, kept apart because two
    /// of them used to arrive as the same `nil`.
    ///
    /// 🚨 `.readFailed` MUST NOT CANCEL, and the reason is the DIRECTION it is
    /// chosen for, not a property of this code. Cancelling on an unknown destroys
    /// the durable send *and* fails the reopen it promised, and the retained `Draft`
    /// row is not recovery: nothing enumerates `draft` (rows are reachable BY KEY
    /// only), and `send()` mints no Drafts-folder header to supply a key, so a
    /// manually-composed message's authored text is stranded and eventually evicted.
    /// No sync repairs local-only authored content, and retyping is not recovery.
    /// Declining preserves the original durable Send intention exactly; it does
    /// not turn an unconfirmed cancellation request into deletion. No Undo
    /// intention or cancellation promise was accepted, and the queued send stays
    /// on its ordinary durable/retryable Outbox path. One direction silently drops
    /// authored content; the other truthfully leaves the original Send in force.
    ///
    /// ⚠ THE MIRROR IMAGE, stated because the symmetrical fix would be worse than
    /// the bug: `.mismatchOrAbsent` must STILL cancel. Refusing to cancel on every
    /// `nil` would let a generation the user successfully undid go out.
    ///
    /// Shape follows `SearchView.ResultTapOutcome` (`afa7889ee`, `IOS-IMAP-001`) —
    /// and its correction: an enum with no silent case does not by itself prevent a
    /// silent path, so what actually holds the invariant here is that every arm of
    /// `undo()` leaves an observable end state (a snapshot, a cleared toast, or
    /// `undoFailureMessage`), which is what the tests assert.
    ///
    /// ⚠️ **THAT SENTENCE WAS FALSE WHERE IT WAS WRITTEN, FOR TWO OF THE FIVE EXITS
    /// (R16-9, fixed 2026-08-06).** The enum's three cases are not the exits: two of
    /// them contain a `guard discardOutboxMessageConfirmed(…) else { return nil }`,
    /// and BOTH of those inner returns left no snapshot, no cleared toast and no
    /// `undoFailureMessage`. Predicate to re-derive the exit count rather than trust
    /// it: count `return` statements inside `undo()` — **six**. One per enum case
    /// (3), plus the two discard-refusal guards, plus the `guard let p = current`
    /// early return, which is the one exit with nothing to observe because there was
    /// no toast to begin with. The enum is a roster of ANSWERS, never of exits, which
    /// is precisely how a documented invariant went on reading as evidence that the
    /// work was done (`MIS-018`'s tell).
    private enum RetainedAuthorityOutcome {
        /// Both rows read, and this toast's generation matches them exactly.
        case verified(RetainedDraftAuthority)
        /// The rows read, and the identity PROVABLY differs — or the row is absent.
        case mismatchOrAbsent
        /// The read threw. We could not determine the answer.
        case readFailed
    }

    /// Exact owner/generation authority. No legacy generation, content, or
    /// absent-row fallback is accepted.
    private func retainedAuthorityOutcome(for p: Pending) -> RetainedAuthorityOutcome {
        do {
            return try AppDatabase.dbPool.read { db in
                guard let draft = try Draft.fetchOne(db, key: p.draftId),
                      let outbox = try OutboxMessage.fetchOne(db, key: p.id),
                      draft.accountId == outbox.accountId,
                      draft.instanceEpoch == p.instanceEpoch,
                      outbox.draftId == p.draftId,
                      outbox.instanceEpoch == p.instanceEpoch else {
                    return .mismatchOrAbsent
                }
                return .verified(RetainedDraftAuthority(
                    draftId: draft.id,
                    accountId: draft.accountId,
                    instanceEpoch: p.instanceEpoch))
            }
        } catch {
            return .readFailed
        }
    }

    /// The user acknowledged the "couldn't undo" alert.
    func dismissUndoFailure() {
        undoFailureMessage = nil
    }

    /// User tapped the × on the toast. Hides the toast but doesn't cancel the
    /// send — the message continues through its normal drain flow.
    func dismiss() {
        dismissTask?.cancel()
        undoFailureMessage = nil
        current = nil
    }
}
