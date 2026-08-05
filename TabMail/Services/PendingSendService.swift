/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Tracks the single in-flight "undo send" toast. The user taps Send; this
/// service shows a Gmail-style toast ("Sending … Undo") for `outboxUndoHoldSeconds`,
/// then flips to "✓ Message sent" for a brief confirmation, then fades.
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
        let queuedAt: Date       // view computes phase deadlines from this
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
    func present(outboxId: String, draftId: String, instanceEpoch: String, toSummary: String) {
        dismissTask?.cancel()
        undoFailureMessage = nil
        current = Pending(
            id: outboxId,
            draftId: draftId,
            instanceEpoch: instanceEpoch,
            toSummary: toSummary,
            queuedAt: Date())

        // One auto-dismiss Task at the full visible window:
        //   phase 1 (undo):    0 → outboxUndoHoldSeconds
        //   claim buffer:      → + outboxClaimBufferSeconds  (drain claims here)
        //   phase 2 (✓):       → + outboxPostSendConfirmSeconds
        //   fade
        let total = SyncConfig.outboxUndoHoldSeconds
                  + SyncConfig.outboxClaimBufferSeconds
                  + SyncConfig.outboxPostSendConfirmSeconds
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // PendingSendService is @MainActor, so the Task body is already
            // MainActor-isolated — no MainActor.run wrapper needed.
            guard self?.current?.id == outboxId else { return }
            self?.current = nil
        }
    }

    /// User tapped Undo. Only reachable while the toast is in phase 1
    /// (the Undo button is rendered only while `elapsed < outboxUndoHoldSeconds`).
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
            undoFailureMessage = "Try again."
            return nil
        case .mismatchOrAbsent:
            // PROVEN not to be the generation this toast is holding. Cancel the send
            // — the user asked for that and we know it is safe — but reopen nothing.
            guard AccountManager.shared.discardOutboxMessageConfirmed(p.id) else {
                return nil
            }
            dismissTask?.cancel()
            current = nil
            return nil
        case .verified(let authority):
            guard AccountManager.shared.discardOutboxMessageConfirmed(p.id) else {
                return nil
            }
            dismissTask?.cancel()
            current = nil
            return ReopenSnapshot(id: p.id, authority: authority)
        }
    }

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
    /// Declining leaves the send pending and still cancellable — the user can tap
    /// Undo again inside the hold window, and in the worst case the message is
    /// *sent*, which puts the content in Sent where they can reach it. One direction
    /// loses the content; the other keeps it.
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
