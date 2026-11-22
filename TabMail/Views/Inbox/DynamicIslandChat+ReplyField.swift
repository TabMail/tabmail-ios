/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The chat's reply field (`ChatReplyField`): today's Chat pill on the chat's newest email.
extension DynamicIslandChat {
    /// The chat view's reply field (`ChatReplyField`): [mic] [field] [Send] on the newest email.
    /// Empty, the field shows its hint and, under it, the "e.g." line (`ChatReplyField.example`);
    /// while the agent works, the line above says what it is doing and the words pulse.
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
            let send = message.map { ChatFieldSend(message: $0, onlyTo: field.onlyTo, isNoReply: field.isNoReply, suggestion: field.suggestion) }
            sendAgentChat(prompt.rawValue, script: prompt, field: send)
        case .tapSuggestion, nil:
            break
        }
    }

    private func liveReplyFieldBar(_ field: ChatReplyField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if isWorking, fieldSentText != nil {
                Text(workingStatus.isEmpty ? "Thinking..." : workingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                micButton
                VStack(alignment: .leading, spacing: 2) {
                    if isWorking, let sent = fieldSentText {
                        Text(sent)
                            .lineLimit(1...6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(fieldPulse ? ChatViewLayout.fieldPulseOpacity : 1)
                    } else {
                        inputField(placeholder: hasTabMailSession ? field.placeholder : "Sign in to reply or ask")
                        if showsExample, let example = field.example {
                            exampleLine(example)
                        }
                    }
                }
                trailingButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
