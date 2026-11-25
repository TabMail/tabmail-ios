/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The chat's reply field (`ChatReplyField`): today's Chat pill on the chat's newest email.
extension DynamicIslandChat {
    /// The chat view's reply field (`ChatReplyField`): [mic] [field] [Send] on the newest email.
    /// Empty, the field shows its hint and, under it, the "e.g." line (`ChatReplyField.example`);
    /// while the agent works, the words pulse, and the screen shows what it is doing in a line above
    /// the field (`ChatFieldStatusLine`).
    /// In the tutorial the field is filled in and read-only, as the inbox chat's input is.
    @ViewBuilder
    func replyFieldBar(_ field: ChatReplyField) -> some View {
        if TutorialCoordinator.shared.isRunning && !(isWorking && fieldSentText != nil) {
            TutorialChatInputBar(
                prompt: Self.tutorialFieldText(field),
                isWorking: isWorking,
                send: { sendTutorialField(field) })
            .accessibilityIdentifier("chatReplyField")
        } else {
            liveReplyFieldBar(field)
        }
    }

    /// The tutorial's filled-in words in the chat's field: the request. While the move is a tap on
    /// the AI Suggestion, the field holds nothing (the suggestion is the ghost in the chat).
    static func tutorialFieldText(_ field: ChatReplyField) -> String? {
        switch field.tutorialMove {
        case .ask(let prompt): return prompt.rawValue
        case .tapSuggestion, nil: return nil
        }
    }

    /// Send in the tutorial's field: the request goes to the script, pulsing in the field as a
    /// real request does.
    private func sendTutorialField(_ field: ChatReplyField) {
        switch field.tutorialMove {
        case .ask(let prompt):
            fieldSentText = prompt.rawValue
            onFieldSend?(prompt.rawValue)
            TutorialCoordinator.shared.chatPromptSent(prompt)
            let send = message.map { ChatFieldSend(message: $0, onlyTo: field.onlyTo, suggestion: field.suggestion) }
            sendAgentChat(prompt.rawValue, script: prompt, field: send)
        case .tapSuggestion, nil:
            break
        }
    }

    private func liveReplyFieldBar(_ field: ChatReplyField) -> some View {
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
        // What the agent is doing about a Send goes to the screen, which shows it above the field,
        // outside its glass: the field never grows for it (`ChatFieldStatusLine`).
        .preference(key: ChatFieldStatusKey.self,
                    value: sentWorking ? (workingStatus.isEmpty ? "Thinking..." : workingStatus) : nil)
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

/// What the agent is doing about a Send from the chat's field ("Thinking...", its own reports), from
/// the field to the screen around it; nil while it is not working on one, or while the panel is open.
struct ChatFieldStatusKey: PreferenceKey {
    static let defaultValue: String? = nil

    static func reduce(value: inout String?, nextValue: () -> String?) {
        value = value ?? nextValue()
    }
}

/// The agent's status line above the chat's field, outside its glass, among the field's other
/// notices: the field keeps its size, and the bar the field stands in grows by the line, so the
/// chat moves up for it and back down when it goes. The screen that holds the field shows it.
struct ChatFieldStatusLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(Self.id)
    }

    /// The line, as tests find it.
    static let id = "chatFieldStatus"
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
