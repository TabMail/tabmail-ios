/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

private func previewCard(
    _ step: TutorialCoordinator.Step, _ lesson: TutorialLesson, _ host: TutorialCoachHost
) -> TutorialCoachContent? {
    TutorialCoachContent.make(step: step, lesson: lesson, host: host, flightsAsked: false)
}

#Preview("Part 1 cards") {
    ScrollView {
        VStack(spacing: 16) {
            ForEach([TutorialCoordinator.Step.archiveReceipt, .receiptArchived, .retagDailyTech, .actOnEmailDone], id: \.self) { step in
                if let content = previewCard(step, .actOnEmail, .inbox) {
                    TutorialCoachCard(content: content)
                }
            }
        }
        .padding(.vertical)
    }
    .background(Palette.previewPaneBg)
}

#Preview("Chat: filled-in input") {
    VStack(spacing: 12) {
        Spacer()
        TutorialChatInputBar(prompt: TutorialCoordinator.ChatPrompt.makeTemplate.rawValue, isWorking: false) {}
    }
    .padding(.vertical)
}

#Preview("Chat with nothing to send") {
    VStack {
        Spacer()
        TutorialChatInputBar(prompt: nil, isWorking: false) {}
    }
    .padding(.vertical)
}

#Preview("Compose") {
    VStack(spacing: 12) {
        if let content = previewCard(.replyToPriya, .reuseReply, .compose(showingSuggestion: true)) {
            TutorialCoachCard(content: content)
        }
        if let content = previewCard(.replyToPriya, .reuseReply, .compose(showingSuggestion: false)) {
            TutorialCoachCard(content: content)
        }
    }
    .padding(.vertical)
    .background(Palette.previewPaneBg)
}
#endif
