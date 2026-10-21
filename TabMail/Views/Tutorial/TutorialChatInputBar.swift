/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The chat input during the guided tutorial (owner 2026-10-21): the step's
/// words are filled in and cannot be edited, with a note that in real use
/// you speak or type. Chats with nothing to send here (a message's or a
/// draft's) show only the note.
struct TutorialChatInputBar: View {
    let prompt: TutorialCoordinator.ChatPrompt?
    let isWorking: Bool
    let send: (TutorialCoordinator.ChatPrompt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let prompt {
                HStack(spacing: 10) {
                    Text(prompt.rawValue)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("tutorial-chat-input")
                    Button {
                        send(prompt)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isWorking ? .secondary.opacity(0.3) : Theme.accent)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(isWorking)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("tutorial-chat-send")
                }
                Label(
                    "In your own inbox, you speak or type anything here. For this tutorial, it’s filled in.",
                    systemImage: "mic")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Label("In the tutorial, Chat follows the steps.", systemImage: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
