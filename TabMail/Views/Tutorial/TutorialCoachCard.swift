/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The coach card a native screen shows for the current tutorial step, or
/// nothing. Hosts add it next to their own controls without moving them.
struct TutorialCoachView: View {
    let host: TutorialCoachHost
    /// Extra host handling after a card button ran (the message view closes
    /// itself on "Next").
    var onAction: ((TutorialCoachContent.Action) -> Void)?

    private var tutorial: TutorialCoordinator { TutorialCoordinator.shared }

    var body: some View {
        if let lesson = tutorial.lesson, let step = tutorial.step,
           let content = TutorialCoachContent.make(
            step: step, lesson: lesson, host: host,
            flightsAsked: tutorial.flightsAsked,
            isSending: PendingSendService.shared.current != nil) {
            TutorialCoachCard(
                content: content,
                onAction: { action in
                    perform(action)
                    onAction?(action)
                },
                onSkip: { Task { await tutorial.end() } })
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func perform(_ action: TutorialCoachContent.Action) {
        switch action {
        case .continueToRetag: tutorial.continueToRetag()
        case .nextLesson: tutorial.nextLesson()
        case .finishLater: Task { await tutorial.end() }
        case .showMoreToAsk: tutorial.showMoreToAsk()
        case .showRecap: tutorial.showRecap()
        case .seeTemplate:
            guard let templateId = tutorial.savedTemplateId else { return }
            NotificationCenter.default.post(
                name: .templatePillOpenTapped, object: nil, userInfo: ["templateId": templateId])
        }
    }
}

/// One coach card: progress line with Skip, title, message, then optional
/// examples and buttons, on its own floating surface at the top of the screen.
struct TutorialCoachCard: View {
    let content: TutorialCoachContent
    var onAction: (TutorialCoachContent.Action) -> Void = { _ in }
    var onSkip: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(content.progressLine)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Button("Skip tutorial", action: onSkip)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("tutorial-skip")
            }

            Text(content.title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text(content.message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !content.examples.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("You can also ask TabMail to:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(content.examples, id: \.self) { example in
                        Label(example, systemImage: "checkmark")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            if content.showsProgress {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !content.buttons.isEmpty {
                HStack(spacing: 12) {
                    ForEach(content.buttons, id: \.label) { button in
                        if button.isPrimary {
                            Button(button.label) { onAction(button.action) }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(button.label) { onAction(button.action) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .font(.subheadline)
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Palette.boxBg)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tutorial-coach")
    }
}
