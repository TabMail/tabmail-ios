/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Undo send on the chat's "Sending" bubble (replaces the undo-send toast for a reply the chat
/// shows). The deadline is the outbox row's own, read from the database through
/// `OutboxCancellationPolicy`, so every bubble counts down from its own send and a chat opened
/// again shows the time that is actually left. Nothing here starts a timer of its own or adds time.
extension ChatUnsentReply {
    /// The last instant Undo may be offered: the row's durable hold less the claim buffer.
    var undoDeadline: Date {
        OutboxCancellationPolicy.undoDeadline(for: holdUntil)
    }

    /// Whole seconds of Undo left at `instant`, or nil when Undo is not offered: the shared policy
    /// does not answer Cancel Send (the deadline has passed, the row is sending, failed or sent), or
    /// the row names no draft to reopen.
    func undoSecondsLeft(at instant: Date) -> Int? {
        guard draftId != nil, instanceEpoch != nil,
              OutboxCancellationPolicy.action(status: status, sentAt: sentAt, holdUntil: holdUntil, at: instant) == .cancelSend
        else { return nil }
        return Int(undoDeadline.timeIntervalSince(instant).rounded(.up))
    }

    /// Undo on the bubble: the toast's own undo-and-reopen path for this row.
    @MainActor func undo() {
        guard let draftId, let instanceEpoch else { return }
        PendingSendService.shared.undoAndReopen(PendingSendService.Pending(
            id: outboxId, draftId: draftId, instanceEpoch: instanceEpoch, toSummary: "",
            presentedAt: Date(), holdUntil: holdUntil, showsToast: false))
    }
}

/// The instants at which the bubble's seconds change: `start`, then each whole second before the
/// deadline, then the deadline itself; nothing after it.
struct ChatUndoSendSchedule: TimelineSchedule {
    let deadline: Date

    func entries(from start: Date, mode: TimelineScheduleMode) -> [Date] {
        Self.ticks(from: start, deadline: deadline)
    }

    static func ticks(from start: Date, deadline: Date) -> [Date] {
        let left = deadline.timeIntervalSince(start)
        guard left > 0 else { return [start] }
        let whole = Int(left.rounded(.up))
        return [start] + (0..<whole).reversed()
            .map { deadline.addingTimeInterval(-TimeInterval($0)) }
            .filter { $0 > start }
    }
}

/// The status line under a reply still in the outbox. Placeholder look ("Sending · Undo 4s", option 1
/// of the countdown mock); the look is meant to be swapped here without touching the behaviour above.
struct ChatUndoSendStatus: View {
    let reply: ChatUnsentReply
    let undo: () -> Void

    static let undoId = "chat.unsentReply.undo"

    var body: some View {
        TimelineView(ChatUndoSendSchedule(deadline: reply.undoDeadline)) { context in
            if let seconds = reply.undoSecondsLeft(at: context.date) {
                HStack(spacing: 4) {
                    Text("\(reply.caption) ·")
                        .foregroundStyle(Theme.textSecondary)
                    Button(action: undo) {
                        Text("Undo \(seconds)s")
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Undo send")
                    .accessibilityValue("\(seconds) seconds left")
                    .accessibilityIdentifier(Self.undoId)
                }
                .font(.caption2)
            } else {
                Text(reply.caption)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
