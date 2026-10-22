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
/// A dark translucent HUD in both appearances (owner 2026-10-21, mock 2), so it
/// reads as guidance on top of the app rather than part of it.
struct TutorialCoachCard: View {
    let content: TutorialCoachContent
    var onAction: (TutorialCoachContent.Action) -> Void = { _ in }
    var onSkip: () -> Void = {}

    /// The host's appearance: the HUD is near-black over a light app and a
    /// lifted gray over a dark one, so it stands apart from both.
    @Environment(\.colorScheme) private var hostScheme

    private var hudTint: Color {
        hostScheme == .dark ? Color(white: 0.23).opacity(0.72) : Color(white: 0.07).opacity(0.78)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(content.progressLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 8)
                Button("Skip tutorial", action: onSkip)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityIdentifier("tutorial-skip")
            }

            Text(content.title)
                .font(.headline)
                .foregroundStyle(.white)

            Text(content.message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            if !content.examples.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("You can also ask TabMail to:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                    ForEach(content.examples, id: \.self) { example in
                        Label(example, systemImage: "checkmark")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.78))
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
        // Dark controls (spinner, bordered buttons) on the dark HUD.
        .environment(\.colorScheme, .dark)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(RoundedRectangle(cornerRadius: 18).fill(hudTint))
                .shadow(color: .black.opacity(0.25), radius: 15, y: 5)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tutorial-coach")
    }
}
