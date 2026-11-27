/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Undo send on the chat's "Sending" bubble (replaces the undo-send toast for a reply or forward sent
/// from a compose the chat opened, `PendingSendService.sendHasBubbleUndo`). The deadline is the outbox
/// row's own, read from the database through `OutboxCancellationPolicy`, so every bubble counts
/// down from its own send and a chat opened again shows the time that is actually left. Nothing
/// here starts a timer of its own or adds time.
extension ChatUnsentReply {
    /// The last instant Undo may be offered: the row's durable hold less the claim buffer.
    var undoDeadline: Date {
        OutboxCancellationPolicy.undoDeadline(for: holdUntil)
    }

    /// Whole seconds of Undo left at `instant`, or nil when Undo is not offered: the shared policy
    /// does not answer Cancel Send (the deadline has passed, the row is sending, failed or sent), or
    /// the row names no draft to reopen.
    func undoSecondsLeft(at instant: Date) -> Int? {
        guard !isSent, draftId != nil, instanceEpoch != nil,
              OutboxCancellationPolicy.action(status: status, sentAt: sentAt, holdUntil: holdUntil, at: instant) == .cancelSend
        else { return nil }
        return Int(undoDeadline.timeIntervalSince(instant).rounded(.up))
    }

    /// The row's delivery has settled: the provider took the email, or the send failed (its own
    /// "Not sent" look). A row still queued or sending has not, however long it waits (offline).
    var deliverySettled: Bool {
        sentAt != nil || failed || isSent
    }

    /// How the bubble looks at `instant`: pending while Undo is offered, with the solid blue risen
    /// by the part of the undo window that has passed, then solid. The window is the toast's: the
    /// nominal hold up to the same deadline, so a slow persist starts the fill part-way up and
    /// never moves its end. Under Reduce Motion the fill does not rise, and the look follows
    /// delivery, not Undo: pending (no fill) until the email is sent, then solid. The text
    /// countdown carries the Undo time, so a queued or offline reply never looks sent.
    func undoLook(at instant: Date, reduceMotion: Bool) -> ChatUndoSendLook {
        guard !reduceMotion else { return deliverySettled ? .solid : .pending(fill: 0) }
        guard undoSecondsLeft(at: instant) != nil else { return .solid }
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

    /// `undoLook(at:reduceMotion:)` on the bubble. Under Reduce Motion the look is delivery state
    /// alone, whoever owns the Undo (ownership gates only the button), so a toast-owned reply still
    /// queued looks pending and a hand-over never changes the look. With motion the rising fill is
    /// the Undo countdown, so a bubble without the Undo (the toast owns it) shows no fill: solid.
    func bubbleUndoLook(at instant: Date, reduceMotion: Bool, owner: PendingSendService.UndoOwner?) -> ChatUndoSendLook {
        reduceMotion || Self.bubbleOffersUndo(owner: owner) ? undoLook(at: instant, reduceMotion: reduceMotion) : .solid
    }

    /// Undo on the bubble: the toast's own undo-and-reopen path for this row. `screen`: the screen
    /// showing the bubble, which the reopened compose records (`ReopenSnapshot.openedOn`).
    @MainActor func undo(on screen: ComposeScreen = .chat) {
        let service = PendingSendService.shared
        guard let draftId, let instanceEpoch,
              Self.bubbleOffersUndo(owner: service.undoOwner(for: outboxId)) else { return }
        service.undoAndReopen(PendingSendService.Pending(
            id: outboxId, draftId: draftId, instanceEpoch: instanceEpoch, toSummary: "",
            presentedAt: Date(), holdUntil: holdUntil), bubbleScreen: screen)
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
    /// How often a second the rising fill redraws while it moves.
    static let fillFramesPerSecond = 30
}

/// When the bubble redraws: `start`; each whole second before the deadline, counted back from it
/// (all the countdown needs); while the fill rises (no Reduce Motion), every frame
/// (`ChatUndoSendConfig.fillFramesPerSecond`) inside the fill's window, the last
/// `SyncConfig.outboxUndoHoldSeconds` before the deadline (before it the fill is empty and does
/// not move); then the deadline itself. Nothing is scheduled after the deadline: the sequence
/// closes with `Date.distantFuture`, an instant the timeline never reaches. A TimelineView does not
/// redraw at its schedule's last date, so ending on the deadline left a mounted bubble showing
/// Undo past it.
///
/// The instants are made one at a time, as the timeline asks for them, never laid out in memory:
/// a queued row's durable hold can lie far ahead of the clock (a reply queued while the device's
/// date ran ahead, the date set right before it went out).
struct ChatUndoSendSchedule: TimelineSchedule {
    let deadline: Date
    let animatesFill: Bool

    func entries(from start: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(start: start, deadline: deadline, animatesFill: animatesFill)
    }

    struct Entries: Sequence, IteratorProtocol {
        private let start: Date
        private let deadline: Date
        /// Units a second: frames while the fill rises, else whole seconds.
        private let perSecond: Int
        /// The fill's window in units: every unit inside it is a redraw; above it only whole seconds.
        private let window: Int
        /// The time left before the deadline at the next redraw, in units (0: the deadline itself);
        /// nil once the deadline was given, or when `start` is not before it.
        private var left: Int?
        private var startGiven = false
        /// The closing `Date.distantFuture` was given: the sequence has ended.
        private var closed = false

        init(start: Date, deadline: Date, animatesFill: Bool) {
            self.start = start
            self.deadline = deadline
            perSecond = animatesFill ? ChatUndoSendConfig.fillFramesPerSecond : 1
            window = animatesFill ? Int((SyncConfig.outboxUndoHoldSeconds * Double(perSecond)).rounded(.down)) : 0
            let total = deadline.timeIntervalSince(start)
            // The last unit before `total`, then the redraw at or under it.
            left = total > 0 ? Self.redraw(atOrUnder: Int((total * Double(perSecond)).rounded(.up)) - 1, window: window, perSecond: perSecond) : nil
        }

        /// The redraw at or under `units` left: every unit inside the window, else the whole second
        /// at or under it, but never under the window's first unit.
        private static func redraw(atOrUnder units: Int, window: Int, perSecond: Int) -> Int {
            // `Swift.max`: inside a sequence, a bare `max` names the sequence's own `max()`.
            guard units > window else { return Swift.max(0, units) }
            return Swift.max(units / perSecond * perSecond, window)
        }

        mutating func next() -> Date? {
            if !startGiven {
                startGiven = true
                return start
            }
            while let units = left {
                left = units == 0 ? nil : Self.redraw(atOrUnder: units - 1, window: window, perSecond: perSecond)
                let instant = deadline.addingTimeInterval(-Double(units) / Double(perSecond))
                // Rounding can put the first unit at `start`, which was already given.
                if instant > start { return instant }
            }
            guard !closed else { return nil }
            closed = true
            return .distantFuture
        }
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
