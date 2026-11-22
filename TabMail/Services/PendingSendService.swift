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
/// - `undoAndReopen()` attempts a confirmed cancellation regardless of whether compose
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

    /// Which presenter offers a send's Undo: the toast, or the chat's "Sending" bubble.
    enum UndoOwner: Sendable, Equatable {
        case toast
        case bubble
    }

    /// Whether the send gets a chat bubble with its own Undo, so its toast is not shown. Every send
    /// keeps exactly one visible Undo. The bubble offers it for a reply (the chat shows a send by its
    /// In-Reply-To, `ChatUnsentReply`) sent with the chat view on (read once at the Send tap) from a
    /// compose the chat opened (`ComposeScreen.chat`, given as the compose opened): that compose
    /// closes back onto the chat that shows the bubble. Every other send keeps the toast: a new
    /// email, and a reply from a compose opened anywhere else (the Drafts list, the inbox, the
    /// compose an Undo reopens), whose screen shows no bubble. A later change that gives new emails
    /// a bubble changes this one rule.
    nonisolated static func sendHasBubbleUndo(
        chatViewActive: Bool, openedOn: ComposeScreen?, inReplyTo: String?
    ) -> Bool {
        chatViewActive && openedOn == .chat && inReplyTo != nil
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
    struct ReopenSnapshot: Identifiable, Sendable, Equatable {
        let id: String  // outboxId — unique identifier for fullScreenCover(item:)
        let authority: RetainedDraftAuthority
        /// Whether the confirmed Undo also saved the kept row back to Drafts.
        /// `false` reopens the compose as unsaved, so Close asks to save it.
        let returnedToDrafts: Bool
    }

    private(set) var current: Pending?

    /// The one presenter of each send's Undo, by outbox row id, decided ONCE at Send from the
    /// send's own settings snapshot (`present(owner:)`). Both presenters honour it, so a chat view
    /// switched on or off during the window applies to the next send only: never two Undos for
    /// one send, never none. The one change: a toast that stops showing a send still in its window
    /// hands that send to its bubble (`releaseToast`). In memory only; an entry ends with its send's toast lifetime. A row
    /// with no entry was not sent in this run of the app (see `ChatUnsentReply.bubbleOffersUndo`).
    private(set) var undoOwners: [String: UndoOwner] = [:]
    private var ownerExpiry: [String: Task<Void, Never>] = [:]

    func undoOwner(for outboxId: String) -> UndoOwner? {
        undoOwners[outboxId]
    }

    #if DEBUG
    /// Test-only: end every send's Undo owner and cancel its expiry, so no owner outlives the
    /// test that made it. Does NOT touch the toast (`dismiss()`).
    func resetUndoOwnersForTesting() {
        ownerExpiry.values.forEach { $0.cancel() }
        ownerExpiry.removeAll()
        undoOwners.removeAll()
    }
    #endif

    /// The toast RootView shows: the current send, only when its Undo belongs to the toast.
    var visibleToast: Pending? {
        guard let current, undoOwners[current.id] == .toast else { return nil }
        return current
    }

    /// A send is waiting out its undo window, on the toast or on a chat bubble.
    var isSending: Bool {
        current != nil || undoOwners.values.contains(.bubble)
    }

    /// The composes to reopen after confirmed Undos, from the toast or a chat bubble alike, oldest
    /// first. RootView presents the first with `UndoReopenCompose` (ADR-IOS-065 owns its close
    /// semantics) and the next once it closes. A queue, so a second Undo before the first compose
    /// opens never replaces the first: every cancelled send keeps its reopen (never drop).
    private(set) var reopenQueue: [ReopenSnapshot] = []

    var reopenSnapshot: ReopenSnapshot? { reopenQueue.first }

    /// Modals open over RootView that can hold a chat, and so a bubble's Undo (the Search sheet,
    /// `chatModalSheet`). RootView is the one presenter of an Undo's outcome, the reopened compose
    /// and the "Couldn't undo" notice, and UIKit cannot present it over another modal. So once an
    /// outcome waits (`outcomeWaits`), those modals close themselves, and RootView presents only
    /// while none is open (`topLevelReopen`, `topLevelUndoFailureMessage`). The head of the queue
    /// is never tried under a modal, so it never stalls there and nothing waits behind it.
    private(set) var openChatModals = 0

    func chatModalOpened() { openChatModals += 1 }

    func chatModalClosed() { openChatModals = max(0, openChatModals - 1) }

    /// An Undo's outcome waits for RootView: a compose to reopen, or the notice that it did not take.
    /// Set only once the outcome is known, never by the tap itself.
    var outcomeWaits: Bool { reopenSnapshot != nil || undoFailureMessage != nil }

    /// The reopen RootView presents now: the queue's head, once no chat modal is open.
    var topLevelReopen: ReopenSnapshot? { openChatModals == 0 ? reopenSnapshot : nil }

    /// The send's undo notice RootView presents now, once no chat modal is open.
    var topLevelUndoFailureMessage: String? { openChatModals == 0 ? undoFailureMessage : nil }

    /// RootView closed the compose of the first reopen; the next one, if any, opens.
    func finishReopen() {
        guard !reopenQueue.isEmpty else { return }
        reopenQueue.removeFirst()
    }

    /// Sends this run of the app has cancelled through Undo. A repeated Undo for one of them (a
    /// second tap before its bubble goes) is a no-op: no second discard and no false notice.
    private var undoneSendIds: Set<String> = []

    /// Non-nil ⇒ the last Undo tap could not be decided, so nothing was cancelled
    /// and the toast was deliberately left up. The view renders this and clears it.
    /// It states only the observed fact and never claims anything about what
    /// happened to the message — at this point we genuinely do not know.
    private(set) var undoFailureMessage: String? {
        didSet {
            BackgroundSyncLogger.logDebug(
                "[UndoNotice] send notice \(oldValue ?? "nil") -> \(undoFailureMessage ?? "nil")")
        }
    }

    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Show the undo-send toast for the given outboxId. Replaces any
    /// previously-displayed pending (the prior message continues draining on
    /// its own schedule; its Undo passes to its bubble, `releaseToast`).
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
        holdUntil: Date?,
        owner: UndoOwner = .toast
    ) {
        let now = Date()
        // The owner is the send's own, decided once. A dedup onto a send already presented
        // (`persistQueuedSend` returns the in-flight row) keeps that send's owner.
        let owner = undoOwners[outboxId] ?? owner
        undoOwners[outboxId] = owner
        let ownerLifetime = max(0, (holdUntil ?? now).timeIntervalSince(now))
                          + SyncConfig.outboxQueuedAcknowledgementSeconds
        ownerExpiry[outboxId]?.cancel()
        ownerExpiry[outboxId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: OutboxDeadlineScheduler.nanoseconds(for: ownerLifetime))
            guard !Task.isCancelled else { return }
            self?.undoOwners[outboxId] = nil
            self?.ownerExpiry[outboxId] = nil
        }
        // A send whose Undo is on its bubble leaves any toast showing untouched: that toast is
        // another send's only Undo.
        guard owner == .toast else { return }
        if current?.id != outboxId { releaseToast(at: now) }
        dismissTask?.cancel()
        undoFailureMessage = nil
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

    /// Undo, then reopen the compose: the one path for the toast's Undo and a chat bubble's.
    /// `pending` is the send to cancel; nil means the toast's `current`. The reopen is admitted to
    /// `reopenQueue` in the same main-actor turn as the cancellation, and the queue takes every
    /// reopen, so no cancelled send can lose its compose to another Undo.
    func undoAndReopen(_ pending: Pending? = nil) {
        guard let p = pending ?? current, !undoneSendIds.contains(p.id) else { return }
        switch undo(p) {
        case .reopen(let snapshot):
            endUndone(p.id)
            reopenQueue.append(snapshot)
        case .cancelled:
            endUndone(p.id)
        case .refused:
            break
        }
    }

    /// A send cancelled by Undo: a repeated Undo for it is a no-op, and it no longer has an Undo
    /// owner, so `isSending` (the tutorial coach card's progress) stops counting it at once rather
    /// than when its owner would have expired.
    private func endUndone(_ outboxId: String) {
        undoneSendIds.insert(outboxId)
        undoOwners[outboxId] = nil
        ownerExpiry[outboxId]?.cancel()
        ownerExpiry[outboxId] = nil
    }

    /// What one Undo did: cancelled the send and has its compose to reopen; cancelled it with
    /// nothing to reopen (the retained draft is provably another generation or gone); or refused,
    /// with nothing cancelled and `undoFailureMessage` set.
    private enum UndoOutcome: Equatable {
        case reopen(ReopenSnapshot)
        case cancelled
        case refused
    }

    /// Undo for any send still in its window, the toast's or a chat bubble's: read exact retained
    /// authority first, then attempt confirmed cancellation. A refused cancellation leaves the toast
    /// in place. Reopen requires both the confirmed cancellation and exact retained authority. The
    /// read's THREE answers are routed separately (see `RetainedAuthorityOutcome`).
    /// Clears the toast only when it is this send's.
    private func undo(_ p: Pending) -> UndoOutcome {
        switch retainedAuthorityOutcome(for: p) {
        case .readFailed:
            // We could not determine anything, so we decide nothing: the Outbox row
            // and the toast are left exactly as they were, and the user is told.
            // Do NOT reach for `discardOutboxMessageConfirmed` here — cancelling on
            // an unknown is the direction that loses the content (see the enum).
            undoFailureMessage = Self.undoNotConfirmedMessage
            return .refused
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
                return .refused
            }
            clearToast(ifShowing: p.id)
            return .cancelled
        case .verified(let authority):
            // The cancellation and the kept draft's return to Drafts commit in one
            // write, in this same synchronous turn (ADR-IOS-065, as superseded on v3).
            let outcome = AccountManager.shared.discardOutboxMessageReturningDraftConfirmed(
                p.id, authority: authority)
            guard outcome.cancelled else {
                // R16-9 — same arm, same reason as `.mismatchOrAbsent` above. This is
                // the arm where the user had a reopenable draft in hand, so a silent
                // `nil` here reads as "Undo did nothing at all".
                undoFailureMessage = Self.undoNotConfirmedMessage
                return .refused
            }
            clearToast(ifShowing: p.id)
            return .reopen(ReopenSnapshot(
                id: p.id, authority: authority, returnedToDrafts: outcome.returnedToDrafts))
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
    /// `undoAndReopen()` leaves an observable end state (a reopen, a cleared toast, or
    /// `undoFailureMessage`), which is what the tests assert.
    ///
    /// ⚠️ **THAT SENTENCE WAS FALSE WHERE IT WAS WRITTEN, FOR TWO OF THE FIVE EXITS
    /// (R16-9, fixed 2026-08-06).** The enum's three cases are not the exits: two of
    /// them contain a `guard discardOutboxMessageConfirmed(…) else { return nil }`,
    /// and BOTH of those inner returns left no snapshot, no cleared toast and no
    /// `undoFailureMessage`. Predicate to re-derive the exit count rather than trust
    /// it: count the exits of `undoAndReopen()` and the `undo(_:)` it calls — **six**. One
    /// per enum case (3) and the two discard-refusal guards in `undo(_:)`, plus
    /// `undoAndReopen()`'s guard return (no toast, or a send already undone), the one exit with
    /// nothing new to observe. (Before 2026-11 the toast called a separate `undo()` whose own
    /// `guard let p = current` was that sixth exit; it was removed when both presenters moved to
    /// `undoAndReopen()`.) The enum is a roster of ANSWERS, never of exits, which
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

    /// Ends the toast after a confirmed Undo, only when it is showing the undone send.
    private func clearToast(ifShowing outboxId: String) {
        guard current?.id == outboxId else { return }
        dismissTask?.cancel()
        current = nil
    }

    /// The user acknowledged the "couldn't undo" alert.
    func dismissUndoFailure() {
        undoFailureMessage = nil
    }

    /// User tapped the × on the toast. Hides the toast but doesn't cancel the
    /// send — the message continues through its normal drain flow.
    func dismiss() {
        releaseToast(at: Date())
        dismissTask?.cancel()
        undoFailureMessage = nil
        current = nil
    }

    /// The toast stops showing `current` (another send's toast replaces it, or the user closed
    /// it). If that send can still be undone, its Undo passes to its chat bubble: a toast-owned
    /// reply (sent with the chat view off) still shows a bubble in its chat, and must keep exactly
    /// one Undo. A send with no bubble (a new email) has none left, as before this change; it
    /// still goes as asked.
    private func releaseToast(at instant: Date) {
        guard let p = current, undoOwners[p.id] == .toast,
              instant < OutboxCancellationPolicy.undoDeadline(for: p.holdUntil) else { return }
        undoOwners[p.id] = .bubble
    }
}
