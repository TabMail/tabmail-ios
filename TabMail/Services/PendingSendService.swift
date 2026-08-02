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
    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Show the undo-send toast for the given outboxId. Replaces any
    /// previously-displayed pending (the prior message continues draining on
    /// its own schedule).
    func present(outboxId: String, draftId: String, instanceEpoch: String, toSummary: String) {
        dismissTask?.cancel()
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
    /// Read exact retained authority first, then always attempt confirmed
    /// cancellation. A refused cancellation leaves the toast in place. Reopen
    /// requires both the confirmed cancellation and exact retained authority.
    func undo() -> ReopenSnapshot? {
        guard let p = current else { return nil }
        let authority = retainedAuthority(for: p)
        guard AccountManager.shared.discardOutboxMessageConfirmed(p.id) else {
            return nil
        }
        dismissTask?.cancel()
        current = nil
        return authority.map { ReopenSnapshot(id: p.id, authority: $0) }
    }

    /// Exact owner/generation authority. No legacy generation, content, or
    /// absent-row fallback is accepted.
    private func retainedAuthority(for p: Pending) -> RetainedDraftAuthority? {
        do {
            return try AppDatabase.dbPool.read { db in
                guard let draft = try Draft.fetchOne(db, key: p.draftId),
                      let outbox = try OutboxMessage.fetchOne(db, key: p.id),
                      draft.accountId == outbox.accountId,
                      draft.instanceEpoch == p.instanceEpoch,
                      outbox.draftId == p.draftId,
                      outbox.instanceEpoch == p.instanceEpoch else {
                    return nil
                }
                return RetainedDraftAuthority(
                    draftId: draft.id,
                    accountId: draft.accountId,
                    instanceEpoch: p.instanceEpoch)
            }
        } catch {
            return nil
        }
    }

    /// User tapped the × on the toast. Hides the toast but doesn't cancel the
    /// send — the message continues through its normal drain flow.
    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}
