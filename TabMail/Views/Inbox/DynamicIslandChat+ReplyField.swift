/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The chat's reply field (`ChatReplyField`): today's Chat pill on the chat's newest email.
extension DynamicIslandChat {
    /// The chat view's reply field (`ChatReplyField`): [mic] [field] [Send] on the newest email.
    /// The field's top line says AI Reply while it holds the ready reply; while the agent
    /// works, the line above says what it is doing and the words pulse.
    /// In the tutorial the field is filled in and read-only, as the inbox chat's input is.
    @ViewBuilder
    func replyFieldBar(_ field: ChatReplyField) -> some View {
        if TutorialCoordinator.shared.isRunning && !(isWorking && fieldSentText != nil) {
            TutorialChatInputBar(
                prompt: Self.tutorialFieldText(field),
                isWorking: isWorking,
                label: field.tutorialMove == .sendReadyReply ? "AI Reply" : nil,
                send: { sendTutorialField(field) })
            .accessibilityIdentifier("chatReplyField")
        } else {
            liveReplyFieldBar(field)
        }
    }

    /// The tutorial's filled-in words in the chat's field: the ready AI Reply, or the request.
    static func tutorialFieldText(_ field: ChatReplyField) -> String? {
        switch field.tutorialMove {
        case .sendReadyReply: return field.readyText
        case .ask(let prompt): return prompt.rawValue
        case nil: return nil
        }
    }

    /// Send in the tutorial's field: the AI Reply goes to its compose card; the request goes to
    /// the script, pulsing in the field as a real request does.
    private func sendTutorialField(_ field: ChatReplyField) {
        switch field.tutorialMove {
        case .sendReadyReply:
            onSendReadyReply?()
        case .ask(let prompt):
            fieldSentText = prompt.rawValue
            onFieldSend?(prompt.rawValue)
            TutorialCoordinator.shared.chatPromptSent(prompt)
            let send = message.map { ChatFieldSend(message: $0, onlyTo: field.onlyTo, isNoReply: field.isNoReply) }
            sendAgentChat(prompt.rawValue, script: prompt, field: send)
        case nil:
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
                    if holdsReadyReply {
                        Text("AI Reply")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                    if isWorking, let sent = fieldSentText {
                        Text(sent)
                            .lineLimit(1...6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(fieldPulse ? ChatViewLayout.fieldPulseOpacity : 1)
                    } else {
                        inputField(placeholder: hasTabMailSession ? field.placeholder : "Sign in to reply or ask")
                    }
                }
                trailingButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The field shows the ready AI Reply, untouched (its top line says AI Reply).
    private var holdsReadyReply: Bool {
        inputText.isEmpty && !fieldText.isEmpty
    }
}
