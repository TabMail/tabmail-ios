/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The bottom of a chat, where the user's own words show (ADR-IOS-114 decision 10): the sends whose
/// email the chat does not show yet (`ChatSendBubbles`); the bubble held while its compose card is up, which turns into the newest
/// of them as the hold ends; else the user's message while the field's Send writes its email; else
/// the chat's own last row (a thread's AI Suggestion); then the gap above the field. A thread and a
/// new email's chat both show their sends through these rows, so a send looks the same in both:
/// the same bubbles, the same spacing, the same gap above the field.
///
/// The rows go straight into the chat's stack, which spaces them as its other rows.
struct ChatOutgoingRows<Last: View>: View {
    /// The chat's sends to show, oldest first (`ChatSendBubbles`): those still in the outbox, and
    /// those filed whose email the chat does not show yet.
    let unsentReplies: [ChatUnsentReply]
    /// The ghost tapped open, or the user's message the field sent, held while its card is up.
    let heldGhost: ChatHeldGhost?
    /// The user's message while the field's Send writes its email.
    let fieldMessage: ChatFieldMessage?
    /// The namespace the held bubble and the newest outbox bubble share.
    let morph: Namespace.ID
    /// The screen showing the bubbles, which a compose reopened by their Undo records.
    let undoScreen: ComposeScreen
    /// The chat's own last row, when nothing is held and the field writes nothing.
    @ViewBuilder let last: () -> Last

    var body: some View {
        // The sends the chat does not show as emails yet. Not while a bubble is held: the reply its card sent shows as
        // the hold ends, the held bubble turning into its bubble.
        if heldGhost == nil {
            ForEach(unsentReplies) { reply in
                ChatUnsentReplyBubble(reply: reply, retry: { reply.retry() }, delete: { reply.delete() },
                                      undo: { reply.undo(on: undoScreen) })
                    .matchedGeometryEffect(id: ChatOutgoing.sentMorphId(reply, newest: unsentReplies.last), in: morph)
            }
        }
        // The ghost tapped open, or the user's own message the field sent, stays while its card is
        // up, in the ghost's look or the message's.
        if let held = heldGhost {
            Group {
                if held.isMessage {
                    ChatFieldMessageBubble(text: held.text, pulses: false)
                } else {
                    ChatSuggestionBubble(text: held.text) {}
                }
            }
            .matchedGeometryEffect(id: ChatOutgoing.heldGhostMorphId, in: morph)
            .transition(.opacity)
        } else if let message = fieldMessage {
            // The field's Send: the user's own message, up at once in the AI Suggestion's place,
            // pulsing while its email is written, with "Writing your email" under it where "Sent"
            // goes.
            ChatFieldMessageBubble(text: message.text, pulses: message.pulses,
                                   status: ChatReplyField.writingStatus)
                .transition(.opacity)
        } else {
            last()
        }
        // The bottom bar's inset keeps the field's room; only the gap is added here.
        Color.clear.frame(height: ChatViewLayout.pillGap).id(ChatOutgoing.bottomId)
    }
}

/// The user's sends a chat shows as bubbles (`ChatOutgoingRows`), each with where its email is now
/// (`MailPointer`): its outbox item while the row waits and sends, then the Sent copy the send filed
/// it as, then the server's copy that replaced that one. The chat follows the posted moves every
/// holder of an email follows (`.mailPointersMoved`, the send's filing included), so the bubble is one
/// pointer that moves, with no follow code of its own.
///
/// The send's cleanup can delete the row a moment after the filing, before the chat shows the copy
/// (at once when the provider files the copy itself). A bubble the filing moved therefore stays, with
/// the user's words, "Sent", until the chat shows its email: in a thread, until the copy is one of
/// its rows, hidden in the same pass that shows it; in a new email's chat, until the chat becomes the
/// sent email's thread. A thread reads its emails again on the filing itself (`follow` says when), so
/// the copy comes in only once the bubble points at it, and the words are neither off the screen nor
/// there twice. With no Sent copy written it stays "Sent". A row that goes with no move (Undo, a
/// discard) ends its bubble. Display state only: nothing here reads or writes the database.
struct ChatSendBubbles {
    private struct Bubble {
        /// The send, as its row was last read.
        var reply: ChatUnsentReply
        /// Where its email is now: its outbox item until the send filed it, then its Sent copy, or
        /// nil when the send wrote none.
        var pointer: MailPointer?
        /// Its row was read in the last read.
        var rowShown = true

        var filed: Bool { pointer != .outbox(reply.outboxId) }

        func copyShown(in rowIds: Set<String>) -> Bool {
            guard case .header(let id)? = pointer else { return false }
            return rowIds.contains(id)
        }
    }

    private var bubbles: [Bubble] = []
    /// The sends whose email the chat has shown, by outbox id: their bubbles have ended and never
    /// come back, also when a later read names their row again (the email left the chat while its
    /// row still waits for its Sent append).
    private var ended: Set<String> = []

    /// The rows read now, oldest first. A row that has gone ends its bubble unless the send filed its
    /// email; a new row starts one, unless its send has ended. Returns whether a row of the last read
    /// has gone.
    @discardableResult
    mutating func read(_ rows: [ChatUnsentReply]) -> Bool {
        let byId = Dictionary(rows.map { ($0.outboxId, $0) }, uniquingKeysWith: { first, _ in first })
        var left = false
        var next: [Bubble] = []
        for var bubble in bubbles {
            if let row = byId[bubble.reply.outboxId] {
                bubble.reply = row
                bubble.rowShown = true
                next.append(bubble)
                continue
            }
            if bubble.rowShown { left = true }
            guard bubble.filed else { continue }
            bubble.rowShown = false
            next.append(bubble)
        }
        let known = Set(bubbles.map(\.reply.outboxId)).union(ended)
        next += rows.filter { !known.contains($0.outboxId) }.map { Bubble(reply: $0, pointer: .outbox($0.outboxId)) }
        bubbles = next
        return left
    }

    /// One post of moves: each bubble follows its email. Returns whether a send was filed (a bubble
    /// moved off its outbox item): its email is now stored, and a thread reads its emails again to
    /// show it.
    @discardableResult
    mutating func follow(_ moves: MailPointerMoves) -> Bool {
        var filed = false
        for index in bubbles.indices {
            guard let pointer = bubbles[index].pointer else { continue }
            let next = moves.following(pointer)
            if case .outbox = pointer, next != pointer { filed = true }
            bubbles[index].pointer = next
        }
        return filed
    }

    /// The chat shows the rows `rowIds` (header ids): a bubble whose email is one of them has ended.
    mutating func end(shownIn rowIds: Set<String>) {
        let shown = bubbles.filter { $0.copyShown(in: rowIds) }.map(\.reply.outboxId)
        guard !shown.isEmpty else { return }
        ended.formUnion(shown)
        bubbles.removeAll { ended.contains($0.reply.outboxId) }
    }

    /// The bubbles to show, oldest first, while the chat shows the rows `rowIds`: all but those whose
    /// email it shows. A filed one reads "Sent".
    func replies(showing rowIds: Set<String>) -> [ChatUnsentReply] {
        bubbles.compactMap { bubble in
            guard !bubble.copyShown(in: rowIds) else { return nil }
            var reply = bubble.reply
            reply.isSent = bubble.filed
            return reply
        }
    }
}

/// What `ChatOutgoingRows` names its rows, and how its held bubble ends (a generic view holds no
/// stored statics).
enum ChatOutgoing {
    /// The gap above the field, as a scroll to the chat's bottom finds it.
    static let bottomId = "chat-bottom"
    /// The held bubble's id in the rows' `morph`. The newest outbox bubble takes it too, so the held
    /// bubble turns into the reply its card sent as the hold ends.
    static let heldGhostMorphId = "chat-held-ghost"

    /// An outbox bubble's id in the rows' `morph`: the newest one's is the held bubble's.
    static func sentMorphId(_ reply: ChatUnsentReply, newest: ChatUnsentReply?) -> String {
        reply.id == newest?.id ? heldGhostMorphId : "chat-unsent-\(reply.id)"
    }

    /// The animation that ends a held bubble: after a send the chat shows as its bubble, the held
    /// bubble turns into it (at once under Reduce Motion); otherwise it simply goes, at once.
    static func endAnimation(_ held: ChatHeldGhost, reduceMotion: Bool) -> Animation? {
        guard held.morphs, !reduceMotion else { return nil }
        return .spring(response: ChatSuggestionConfig.sentMorphResponse, dampingFraction: ChatSuggestionConfig.sentMorphDamping)
    }
}
