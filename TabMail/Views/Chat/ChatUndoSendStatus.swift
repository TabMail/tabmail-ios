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

    /// How the bubble looks at `instant`: pending while Undo is offered, with the solid blue risen
    /// by the part of the undo window that has passed, then solid. The window is the toast's: the
    /// nominal hold up to the same deadline, so a slow persist starts the fill part-way up and
    /// never moves its end. Under Reduce Motion the fill does not rise; the bubble stays pending
    /// until the deadline and the text countdown carries the time.
    func undoLook(at instant: Date, reduceMotion: Bool) -> ChatUndoSendLook {
        guard undoSecondsLeft(at: instant) != nil else { return .solid }
        guard !reduceMotion else { return .pending(fill: 0) }
        let window = SyncConfig.outboxUndoHoldSeconds
        let passed = window - undoDeadline.timeIntervalSince(instant)
        return .pending(fill: max(0, min(1, passed / window)))
    }

    /// Whether the bubble is its send's Undo presenter, by the owner decided at Send
    /// (`PendingSendService.undoOwner`): yes unless the toast owns it.
    ///
    /// No entry means the send was not made in this run of the app (a relaunch, or an owner that
    /// ended with its toast's lifetime after the window). The toast cannot exist then, so for a
    /// chat reply still in its window the bubble is the ONLY possible presenter, not a fallback.
    static func bubbleOffersUndo(owner: PendingSendService.UndoOwner?) -> Bool {
        owner != .toast
    }

    /// `undoSecondsLeft(at:)` on the bubble: nil when the toast owns this send's Undo.
    func bubbleUndoSecondsLeft(at instant: Date, owner: PendingSendService.UndoOwner?) -> Int? {
        Self.bubbleOffersUndo(owner: owner) ? undoSecondsLeft(at: instant) : nil
    }

    /// `undoLook(at:reduceMotion:)` on the bubble: solid when the toast owns this send's Undo.
    func bubbleUndoLook(at instant: Date, reduceMotion: Bool, owner: PendingSendService.UndoOwner?) -> ChatUndoSendLook {
        Self.bubbleOffersUndo(owner: owner) ? undoLook(at: instant, reduceMotion: reduceMotion) : .solid
    }

    /// Undo on the bubble: the toast's own undo-and-reopen path for this row.
    @MainActor func undo() {
        let service = PendingSendService.shared
        guard let draftId, let instanceEpoch,
              Self.bubbleOffersUndo(owner: service.undoOwner(for: outboxId)) else { return }
        service.undoAndReopen(PendingSendService.Pending(
            id: outboxId, draftId: draftId, instanceEpoch: instanceEpoch, toSummary: "",
            presentedAt: Date(), holdUntil: holdUntil))
    }
}

/// The bubble's look over its undo window.
enum ChatUndoSendLook: Equatable {
    /// Undo is offered: the pending tint, with the solid blue risen by `fill` (0 to 1) from the bottom.
    case pending(fill: Double)
    /// No Undo: the ordinary bubble.
    case solid
}

enum ChatUndoSendConfig {
    /// How often the rising fill redraws while it moves.
    static let fillFrameInterval: TimeInterval = 1.0 / 30
}

/// When the bubble redraws: while the fill rises, every `fillFrameInterval`; otherwise (Reduce
/// Motion, or no fill) only when the seconds change: `start`, each whole second before the deadline,
/// then the deadline itself. Nothing is scheduled after the deadline.
struct ChatUndoSendSchedule: TimelineSchedule {
    let deadline: Date
    let animatesFill: Bool

    func entries(from start: Date, mode: TimelineScheduleMode) -> [Date] {
        animatesFill ? Self.frames(from: start, deadline: deadline) : Self.ticks(from: start, deadline: deadline)
    }

    static func ticks(from start: Date, deadline: Date) -> [Date] {
        let left = deadline.timeIntervalSince(start)
        guard left > 0 else { return [start] }
        let whole = Int(left.rounded(.up))
        return [start] + (0..<whole).reversed()
            .map { deadline.addingTimeInterval(-TimeInterval($0)) }
            .filter { $0 > start }
    }

    static func frames(from start: Date, deadline: Date) -> [Date] {
        guard deadline > start else { return [start] }
        return Array(stride(from: start, to: deadline, by: ChatUndoSendConfig.fillFrameInterval)) + [deadline]
    }
}

/// Redraws a reply's bubble and status line over its undo window, on `ChatUndoSendSchedule`, with
/// the system's Reduce Motion setting.
struct ChatUndoSendTimeline<Content: View>: View {
    let reply: ChatUnsentReply
    @ViewBuilder let content: (_ look: ChatUndoSendLook, _ secondsLeft: Int?) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ChatUndoSendTimelineBody(reply: reply, reduceMotion: reduceMotion, content: content)
    }
}

/// `ChatUndoSendTimeline` for a given Reduce Motion setting.
struct ChatUndoSendTimelineBody<Content: View>: View {
    let reply: ChatUnsentReply
    let reduceMotion: Bool
    @ViewBuilder let content: (_ look: ChatUndoSendLook, _ secondsLeft: Int?) -> Content

    var body: some View {
        let owner = PendingSendService.shared.undoOwner(for: reply.outboxId)
        TimelineView(ChatUndoSendSchedule(deadline: reply.undoDeadline, animatesFill: !reduceMotion)) { context in
            content(reply.bubbleUndoLook(at: context.date, reduceMotion: reduceMotion, owner: owner),
                    reply.bubbleUndoSecondsLeft(at: context.date, owner: owner))
        }
    }
}

/// The bubble's fill. Pending: the tint with its own text colour, and over it the solid blue with
/// white text, both copies of the same content, the solid one cut to the risen part so the text
/// switches colour exactly at the fill edge. Only the base copy is read by VoiceOver.
struct ChatUndoSendFill<Content: View>: View {
    let look: ChatUndoSendLook
    @ViewBuilder let content: (_ textColor: Color) -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChatViewLayout.bubbleCornerRadius)
        switch look {
        case .solid:
            content(Color.white)
                .background(shape.fill(Theme.accent))
        case .pending(let fill):
            content(Palette.chatUndoSendPendingText)
                .background(shape.fill(Palette.chatUndoSendPendingTint))
                .overlay {
                    content(Color.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.accent)
                        .mask(alignment: .bottom) {
                            GeometryReader { geometry in
                                Rectangle()
                                    .frame(height: geometry.size.height * fill)
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                        .clipShape(shape)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }
}

/// The status line under a reply still in the outbox: "Sending · Undo 4s" while Undo is offered,
/// otherwise the reply's caption.
struct ChatUndoSendStatus: View {
    let reply: ChatUnsentReply
    let secondsLeft: Int?
    let undo: () -> Void

    static let undoId = "chat.unsentReply.undo"

    var body: some View {
        if let seconds = secondsLeft {
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
