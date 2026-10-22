/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The chat input during the guided tutorial (owner 2026-10-21), laid out like
/// the real one (`DynamicIslandChat.expandedInputBar`): microphone, field,
/// send. The step's words are filled in and cannot be edited, and a tooltip
/// over the microphone says that in real use you speak or type. Chats with
/// nothing to send here (a message's or a draft's) show a dimmed bar.
struct TutorialChatInputBar: View {
    let prompt: TutorialCoordinator.ChatPrompt?
    let isWorking: Bool
    let send: (TutorialCoordinator.ChatPrompt) -> Void

    /// The prompt whose tooltip was closed (by sending it or tapping it), so
    /// the tooltip never covers the answer that follows.
    @State private var tooltipClosedFor: TutorialCoordinator.ChatPrompt?

    private var showsTooltip: Bool {
        prompt != nil && tooltipClosedFor != prompt && !isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsTooltip {
                // Stacked above the bar, never over it, so it cannot catch
                // the Send tap.
                TutorialInputTooltip {
                    tooltipClosedFor = prompt
                }
                .transition(.opacity)
            }
            inputRow
        }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic")
                .font(.title3)
                .foregroundStyle(prompt == nil ? AnyShapeStyle(.secondary.opacity(0.3)) : AnyShapeStyle(Theme.accent))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            Text(prompt?.rawValue ?? "Chat follows the tutorial steps")
                .foregroundStyle(prompt == nil ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1...6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("tutorial-chat-input")

            Button {
                guard let prompt else { return }
                tooltipClosedFor = prompt
                send(prompt)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(prompt == nil || isWorking ? AnyShapeStyle(.secondary.opacity(0.3)) : AnyShapeStyle(Theme.accent))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(prompt == nil || isWorking)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("tutorial-chat-send")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// A tooltip bubble with its arrow pointing down at the input bar's microphone.
private struct TutorialInputTooltip: View {
    let close: () -> Void

    /// The arrow's center sits over the microphone: the bar's leading padding
    /// plus half the microphone's frame, less the bubble's own inset.
    private let arrowCenterX: CGFloat = 14 + 14 - 8
    private let arrowSize = CGSize(width: 16, height: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("In your own inbox, you speak or type anything here. For this tutorial, it’s filled in.")
                .font(.subheadline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.accent)
                )
            TooltipArrow()
                .fill(Theme.accent)
                .frame(width: arrowSize.width, height: arrowSize.height)
                .padding(.leading, arrowCenterX - arrowSize.width / 2)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
        .accessibilityIdentifier("tutorial-input-tooltip")
    }
}

private struct TooltipArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
