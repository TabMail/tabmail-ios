/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The chat's reply field (`ChatReplyField`): today's Chat pill on the chat's newest email.
extension DynamicIslandChat {
    /// The chat view's reply field (`ChatReplyField`): [mic] [field] [Send] on the newest email.
    /// Empty, the field shows its hint and, under it, the "e.g." line (`ChatReplyField.example`);
    /// while the agent works, the line above says what it is doing and the words pulse.
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
        VStack(alignment: .leading, spacing: 4) {
            if isWorking, fieldSentText != nil {
                Text(workingStatus.isEmpty ? "Thinking..." : workingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    // The row pads only itself: the status line keeps the field's padding above it.
                    .padding(.top, ChatViewLayout.fieldVerticalPadding)
                    .transition(.opacity)
            }
            ChatFieldBarRow {
                micButton
            } text: {
                if let attach = field.paperclip {
                    // The paperclip sits at the field's end on Send's row: bottom-aligned with the
                    // words and the "e.g." line as the row aligns Send, so it stays level with Send
                    // whether or not that line shows. It stays in its place in every state; while
                    // the agent works on a Send it is dimmed and not tappable.
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
        }
        // A drag up swells the field itself toward the panel, its top following the finger.
        .modifier(ChatFieldDrag.Swell(model: field.drag, sign: 1))
    }

    /// The agent works on a Send from the field: its words pulse in the field.
    private var sentWorking: Bool {
        isWorking && fieldSentText != nil
    }

    /// The field's text: the sent words pulsing while the agent works on them, else the input with
    /// the "e.g." line under it.
    private func fieldText(_ field: ChatReplyField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if isWorking, let sent = fieldSentText {
                Text(sent)
                    .lineLimit(1...6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(fieldPulse ? ChatViewLayout.fieldPulseOpacity : 1)
                    // The drag stays on while the agent works: so does its VoiceOver action.
                    .showChatAction(field.showChat, isExpanded: isExpanded)
            } else {
                replyInput(field)
                if showsExample, let example = field.example {
                    exampleLine(example)
                }
            }
        }
    }

    private func replyInput(_ field: ChatReplyField) -> some View {
        inputField(placeholder: hasTabMailSession ? field.placeholder : "Sign in to reply",
                   showChat: field.showChat, focus: .replyField)
    }

    /// The "e.g." line shows under the empty field, signed in, while nothing is being said.
    private var showsExample: Bool {
        hasTabMailSession && inputText.isEmpty && !isDictating
    }

    /// The "e.g." line: a tap puts its change in the field, ready to send or edit; it never sends.
    private func exampleLine(_ example: String) -> some View {
        Button { putExample(example) } label: {
            Text(ChatSuggestionConfig.exampleLine(example))
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Puts it in the field")
        .accessibilityIdentifier(Self.exampleLineId)
    }

    /// The "e.g." line, as tests find it.
    static let exampleLineId = "chatExampleLine"
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
