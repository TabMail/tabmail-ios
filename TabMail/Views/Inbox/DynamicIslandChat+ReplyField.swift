/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The chat's reply field (`ChatReplyField`): today's Chat pill on the chat's newest email.
extension DynamicIslandChat {
    /// The chat view's reply field (`ChatReplyField`): [mic] [field] [Send] on the newest email.
    /// Empty, the field shows its hint, on one line; the other reply that came with the AI
    /// Suggestion is a line under the ghost in the chat (`ChatAlternativeLink`), not here. While its
    /// Send's email is written, the words are up in the chat as the user's bubble, with what is
    /// happening under it ("Writing your email", `ChatFieldMessageBubble`), and the field shows only
    /// its hint.
    /// In the tutorial the field is read-only and sends nothing: its words go to the people, and
    /// the tutorial's requests to TabMail are made in the panel. At part 2's drag-up step it says
    /// so (`tutorialDragHint`), and its drag up, or VoiceOver's "Show TabMail chat", opens the panel.
    @ViewBuilder
    func replyFieldBar(_ field: ChatReplyField) -> some View {
        if TutorialCoordinator.shared.isRunning {
            TutorialChatInputBar(
                prompt: nil,
                isWorking: isWorking,
                dragHint: Self.tutorialDragHint(field),
                showChat: isExpanded ? nil : field.showChat,
                send: {})
            .accessibilityIdentifier("chatReplyField")
        } else {
            liveReplyFieldBar(field)
        }
    }

    /// The tutorial's hint in the chat's field: at part 2's drag-up step, how to ask TabMail;
    /// nil otherwise (while the move is a tap on the AI Suggestion, the suggestion is the ghost in
    /// the chat).
    static func tutorialDragHint(_ field: ChatReplyField) -> String? {
        field.tutorialMove == .dragUp ? tutorialDragHintText : nil
    }

    static let tutorialDragHintText = "Drag up to ask TabMail"

    private func liveReplyFieldBar(_ field: ChatReplyField) -> some View {
        ChatFieldBarRow {
            micButton
        } text: {
            if let attach = field.paperclip {
                // The paperclip sits at the field's end on Send's row: bottom-aligned with the
                // words as the row aligns Send, so it stays level with Send however many lines
                // they take. It stays in its place in every state; while a Send's email is
                // written it is dimmed and not tappable.
                HStack(alignment: .bottom, spacing: ChatViewLayout.fieldTextGap) {
                    fieldText(field)
                    ChatPaperclipButton(attach: attach)
                        .disabled(sentWorking)
                        .opacity(sentWorking ? ChatViewLayout.fieldPaperclipDimmedOpacity : 1)
                }
            } else {
                fieldText(field)
            }
        } send: {
            trailingButton
        }
        // A drag up swells the field itself toward the panel, its top following the finger.
        .modifier(ChatFieldDrag.Swell(model: field.drag, sign: 1))
    }

    /// A Send from the field is being written: its words are up as the user's bubble.
    private var sentWorking: Bool {
        isWorking && fieldSending
    }

    /// The field's text: while a Send's email is written, only the field's hint (the words are the
    /// user's bubble in the chat, and they come back here if the send ends with nothing sent); else
    /// the input.
    private func fieldText(_ field: ChatReplyField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if sentWorking {
                Text(ChatReplyField.writePlaceholder)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The drag stays on while the email is written: so does its VoiceOver action.
                    .showChatAction(field.showChat, isExpanded: isExpanded)
            } else {
                replyInput(field)
            }
        }
    }

    private func replyInput(_ field: ChatReplyField) -> some View {
        inputField(placeholder: hasTabMailSession ? ChatReplyField.writePlaceholder : "Sign in to reply",
                   showChat: field.showChat, focus: .replyField)
    }
}

/// Closing the chat view's open TabMail panel like a sheet: a drag down on its header, or its
/// history pulled down past its top. Let go far enough (`ChatViewLayout.panelCloseDistance`), it
/// closes the panel as Close does: the history and the words in the input stay, and nothing is sent.
enum ChatPanelPull {
    /// How far the history is pulled down past the top of its content; 0 while it is not.
    static func pastTop(offsetY: CGFloat, topInset: CGFloat) -> CGFloat {
        max(0, -(offsetY + topInset))
    }

    /// The history is pulled far enough past its top for a let-go to close the panel.
    static func isPastClose(offsetY: CGFloat, topInset: CGFloat) -> Bool {
        pastTop(offsetY: offsetY, topInset: topInset) >= ChatViewLayout.panelCloseDistance
    }

    /// The finger let go of the history (its scroll left `.interacting`) while pulled past the close
    /// distance.
    static func closesOnLetGo(from old: ScrollPhase, to new: ScrollPhase, pulledPastClose: Bool) -> Bool {
        pulledPastClose && old == .interacting && new != .interacting
    }

    /// A drag down on the header went far enough, or a flick down would have.
    static func headerCloses(translation: CGFloat, predictedEnd: CGFloat) -> Bool {
        max(translation, predictedEnd) >= ChatViewLayout.panelCloseDistance
    }
}

extension View {
    /// The chat reply field's drag up as VoiceOver's "Show TabMail chat"
    /// (`ChatViewConfig.showChatActionName`), on the element VoiceOver focuses: the text field, the
    /// sent words while the agent works, the waveform while dictating. Only while the panel is
    /// closed; nil offers nothing (any other pill, the panel open, the tutorial).
    func showChatAction(_ showChat: (() -> Void)?, isExpanded: Bool) -> some View {
        accessibilityActions {
            if let showChat, !isExpanded {
                Button(ChatViewConfig.showChatActionName) { showChat() }
            }
        }
    }
}
