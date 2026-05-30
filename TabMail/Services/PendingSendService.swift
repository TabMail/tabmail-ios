/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

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
/// - `undo()` discards the OutboxMessage row. The 1 s claim buffer between the
///   UI Undo deadline and drain's atomic-claim deadline eliminates the TOCTOU
///   race — by the time undo() runs, drain has not yet claimed.
/// - DraftStore row is NOT deleted by compose at send time (deferred to drain
///   claim); so reopening compose with the same draftId produces the original
///   content.
@Observable
@MainActor
final class PendingSendService {
    static let shared = PendingSendService()

    struct Pending: Identifiable, Sendable {
        let id: String           // outboxId (matches OutboxMessage.id)
        let draftId: String
        let toSummary: String    // "To: user@example.com"
        let queuedAt: Date       // view computes phase deadlines from this
    }

    /// Snapshot of the draft content returned by `undo()` so the caller can
    /// reopen compose with the user's exact contents. The Draft row itself
    /// is deleted by `undo()` — this struct is the only remaining copy of
    /// the content. RootView uses it as the source for a fresh ComposeView
    /// with prefill args (not via `prefillDraftId`, which would reload a
    /// Draft that no longer exists).
    struct ReopenSnapshot: Identifiable, Sendable {
        let id: String  // outboxId — unique identifier for fullScreenCover(item:)
        let accountId: String
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let body: String
        let attachments: [DraftAttachment]
        let replyToId: String?
        let isForward: Bool
    }

    private(set) var current: Pending?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Show the undo-send toast for the given outboxId. Replaces any
    /// previously-displayed pending (the prior message continues draining on
    /// its own schedule).
    func present(outboxId: String, draftId: String, toSummary: String) {
        dismissTask?.cancel()
        current = Pending(id: outboxId, draftId: draftId, toSummary: toSummary, queuedAt: Date())

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
    /// Flow: load the Draft + attachments → discard the outbox row → delete
    /// the Draft row. Returns a snapshot for the caller to reopen compose
    /// with prefill args. The Draft is deleted so that when the user closes
    /// the reopened compose, the existing "save draft?" prompt fires naturally
    /// (treating the prefilled content as unsaved changes).
    ///
    /// Returns nil if there's no pending send or the Draft row is missing.
    /// The 1 s claim buffer between the Undo deadline (5 s) and the drain's
    /// holdUntil (6 s) ensures drain has NOT yet reached atomicClaim when
    /// undo() runs — no TOCTOU race.
    func undo() -> ReopenSnapshot? {
        guard let p = current else { return nil }
        dismissTask?.cancel()
        current = nil

        // Load the Draft (synchronously — DraftStore.load is nonisolated).
        let draft = try? DraftStore.shared.load(id: p.draftId)
        let attachments: [DraftAttachment] = {
            guard let dir = draft?.attachmentsDirName else { return [] }
            return DraftAttachmentStorage.loadAttachments(dirName: dir)
        }()

        // Discard the outbox row. This prevents the drain from ever sending.
        AccountManager.shared.discardOutboxMessage(p.id)

        // Delete the Draft row (and its attachments on disk). The reopened
        // compose will run as a fresh ComposeView with prefill args — no
        // longer tied to a Draft row, so close → Save prompt flows through
        // the existing saveDraftAndDismiss path.
        try? DraftStore.shared.delete(id: p.draftId)

        guard let draft else { return nil }
        return ReopenSnapshot(
            id: p.id,
            accountId: draft.accountId,
            to: draft.toArray,
            cc: draft.ccArray,
            bcc: draft.bccArray,
            subject: draft.subject,
            body: draft.body,
            attachments: attachments,
            replyToId: draft.replyToId,
            isForward: draft.isForward
        )
    }

    /// User tapped the × on the toast. Hides the toast but doesn't cancel the
    /// send — the message continues through its normal drain flow.
    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}
