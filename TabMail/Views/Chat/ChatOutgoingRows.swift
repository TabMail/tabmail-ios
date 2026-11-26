/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The bottom of a chat, where the user's own words show (ADR-IOS-114 decision 10): the replies
/// still in the outbox; the bubble held while its compose card is up, which turns into the newest
/// of them as the hold ends; else the user's message while the field's Send writes its email; else
/// the chat's own last row (a thread's AI Suggestion); then the gap above the field. A thread and a
/// new email's chat both show their sends through these rows, so a send looks the same in both:
/// the same bubbles, the same spacing, the same gap above the field.
///
/// The rows go straight into the chat's stack, which spaces them as its other rows.
struct ChatOutgoingRows<Last: View>: View {
    /// The chat's replies still in the outbox, oldest first.
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
        // Replies still in the outbox. Not while a bubble is held: the reply its card sent shows as
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
